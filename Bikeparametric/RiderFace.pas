unit RiderFace;
{$mode objfpc}{$H+}
interface
uses X3DNodes,X3DFields,CastleVectors,CastleScene,CastleTransform,TripoRig,fpjson;
const
  RiderFaceJointCount=15;
  RiderFaceNames:array[0..RiderFaceJointCount-1]of String=(
    'Face_Jaw','Face_LipUpper','Face_LipLower','Face_CornerL','Face_CornerR',
    'Face_CheekL','Face_CheekR','Face_BrowL','Face_BrowR',
    'Face_UpperLidL','Face_LowerLidL','Face_UpperLidR','Face_LowerLidR','Face_EyeL','Face_EyeR');
type
  TRiderFaceReplay=record
    Valid,Manual:Boolean;
    Visibility:Single;
    Requested:TVector3;
  end;
  TRiderFace=class
  private
    FScene:TCastleScene;
    FPreviousFilter:TRenderShapeFilter;
    FRig:TTripoRig;
    FNodes:array[0..RiderFaceJointCount-1]of TTransformNode;
    FRestT:array[0..RiderFaceJointCount-1]of TVector3;
    FRestR:array[0..RiderFaceJointCount-1]of TVector4;
    FParentInv:array[0..RiderFaceJointCount-1]of TMatrix4;
    FFirst,FCount:Integer;
    FScale,FVisibility,FTargetVisibility,FDistance,FFacing,FPixels:Single;
    FRestPivot:array[0..RiderFaceJointCount-1]of TTripoVec3;
    FHeadDelta:TMatrix4;
    FValid,FGpu,FOverride,FWasActive,FSuspended:Boolean;
    FRequested,FControls,FEyeControls:TVector3;
    FMatrices:TMatrix4List;
    FPalette:TMFMatrix4f;
    FActive:TSFFloat;
    FEvaluations,FUploads:QWord;
    FHeadShape:TAbstractShapeNode;
    FLastSeen:QWord;
    function FilterShape(const Shape:TAbstractShapeNode;const Params:TRenderParams):Boolean;
    procedure ResetNodes;
    procedure Evaluate;
    procedure SetGpu(Value:Boolean);
  public
    constructor Create(Scene:TCastleScene;Rig:TTripoRig;Height:Single;const JointNodes:array of TTransformNode);
    destructor Destroy;override;
    procedure Update(Dt,Effort:Single;BreathPhase:Double;BreathLoad:Single;FaceTime:Double=0);
    procedure Follow(const HeadDelta:TMatrix4);
    procedure AttachGpu(Effect:TEffectNode);
    procedure DetachGpu;
    function ShaderSource:String;
    procedure SetExpression(Manual:Boolean;Jaw,Smile,Strain:Single);
    function CaptureReplay:TRiderFaceReplay;
    procedure RestoreReplay(const Saved:TRiderFaceReplay);
    procedure DebugJson(Result:TJSONObject);
    property Valid:Boolean read FValid;
    property Visibility:Single read FVisibility;
    property Gpu:Boolean read FGpu write SetGpu;
    property Suspended:Boolean read FSuspended write FSuspended;
    property Controls:TVector3 read FControls;
    property EyeControls:TVector3 read FEyeControls;
    function GeometricEyes:Boolean;
  end;
function RiderFaceVisibility(Distance,Facing,Pixels:Single):Single;
function RiderFaceStrain(Effort:Single):Single;
function RiderFaceBlink(Time:Double):Single;
implementation
uses Math,SysUtils,CastleRenderOptions,CastleRenderContext,CastleQuaternions;
function Ramp(A,B,X:Single):Single;
begin Result:=EnsureRange((X-A)/(B-A),0,1);Result:=Result*Result*(3-2*Result) end;
function RiderFaceBlink(Time:Double):Single;
begin
  Result:=EnsureRange(1-Abs(Frac(Time/5.7)*5.7-1.85)/0.105,0,1);
  Result:=Result*Result*(3-2*Result);
end;
function TRiderFace.GeometricEyes:Boolean;
begin Result:=FValid and(FCount=RiderFaceJointCount) end;
function RiderFaceVisibility(Distance,Facing,Pixels:Single):Single;
begin Result:=(1-Ramp(7,16,Distance))*Ramp(-0.40,-0.05,Facing)*Ramp(18,55,Pixels) end;
function RiderFaceStrain(Effort:Single):Single;
begin
  { Effort is relative to FTP. Make threshold work
    readable at FTP, while recovery and easy spinning stay relaxed. }
  Result:=Ramp(0.55,1.50,Effort);
end;
constructor TRiderFace.Create(Scene:TCastleScene;Rig:TTripoRig;Height:Single;const JointNodes:array of TTransformNode);
var I,C,R,J,Idx:Integer;B:TTripoMat4;
begin
  inherited Create;FScene:=Scene;FRig:=Rig;FScale:=Height/1.8;FHeadDelta:=TMatrix4.Identity;
  FCount:=9;if Rig.JointIndexByName(RiderFaceNames[9])>=0 then FCount:=RiderFaceJointCount;
  FMatrices:=TMatrix4List.Create;for I:=0 to FCount-1 do FMatrices.Add(TMatrix4.Identity);
  FFirst:=Rig.JointIndexByName(RiderFaceNames[0]);FValid:=FFirst>=0;
  for I:=0 to FCount-1 do begin
    if Rig.JointIndexByName(RiderFaceNames[I])<>FFirst+I then FValid:=False;
    Idx:=Rig.JointIndexByName(RiderFaceNames[I]);
    if(Idx>=0)and(Idx<Length(JointNodes))and(JointNodes[Idx]<>nil)then begin
      FNodes[I]:=JointNodes[Idx];FRestT[I]:=FNodes[I].Translation;FRestR[I]:=FNodes[I].Rotation;
    end else FValid:=False;
    if Rig.JointIndexByName(RiderFaceNames[I])>=0 then begin
      J:=Rig.JointParent[Rig.JointIndexByName(RiderFaceNames[I])];
      FParentInv[I]:=TMatrix4.Identity;
      if J>=0 then for C:=0 to 3 do for R:=0 to 3 do FParentInv[I].Data[C,R]:=Rig.NativeInvBind[J][C*4+R];
    end;
  end;
  if FValid then begin
    for I:=0 to FCount-1 do begin
      B:=Mat4Inverse(Rig.NativeInvBind[FFirst+I]);FRestPivot[I]:=V3(B[12],B[13],B[14]);
    end;
    FPreviousFilter:=Scene.OnRenderShapeFilter;Scene.OnRenderShapeFilter:=@FilterShape;
  end;
end;
destructor TRiderFace.Destroy;
begin
  if(FScene<>nil)and(TMethod(FScene.OnRenderShapeFilter).Data=Pointer(Self))then
    FScene.OnRenderShapeFilter:=FPreviousFilter;
  FMatrices.Free;inherited;
end;
function TRiderFace.FilterShape(const Shape:TAbstractShapeNode;const Params:TRenderParams):Boolean;
var M:TMatrix4;P,F:TVector3;Clip:TVector4;
begin
  Result:=True;if Assigned(FPreviousFilter)then Result:=FPreviousFilter(Shape,Params);
  if not Result or not FValid or(Params.RenderingCamera.Target in [rtShadowMap,rtVarianceShadowMap])then Exit;
  if Pos('Face_OralCavity',Shape.X3DName)=1 then Exit(FVisibility>0);
  if FHeadShape=nil then begin
    if Pos('Head_Neck',Shape.X3DName)=0 then Exit;FHeadShape:=Shape;
  end;
  if Shape<>FHeadShape then Exit;
  M:=Params.RenderingCamera.Matrix*Params.Transformation^.Transform*FHeadDelta;
  P:=M.MultPoint(Vector3(0,1.65*FScale,0.045*FScale));FDistance:=P.Length;
  F:=M.MultDirection(Vector3(0,0,1)).Normalize;
  FFacing:=TVector3.DotProduct(F,-P.Normalize);
  Clip:=Params.RenderingCamera.Projection*Vector4(P.X,P.Y,P.Z,1);
  FPixels:=0.19*FScale*0.5*Abs(Params.RenderingCamera.Projection.Data[1,1])*
    RenderContext.Viewport.Height/Max(Abs(Clip.W),0.1);
  FTargetVisibility:=RiderFaceVisibility(FDistance,FFacing,FPixels);
  if(Clip.W<=0)or(Abs(Clip.X)>Clip.W*1.15)or(Abs(Clip.Y)>Clip.W*1.15)then FTargetVisibility:=0;
  FLastSeen:=GetTickCount64;
end;
procedure TRiderFace.Follow(const HeadDelta:TMatrix4);
begin FHeadDelta:=HeadDelta end;
procedure TRiderFace.ResetNodes;
var I:Integer;
begin
  if not FValid then Exit;
  for I:=0 to FCount-1 do begin
    FNodes[I].Translation:=FRestT[I];FNodes[I].Rotation:=FRestR[I];
  end;
end;
procedure TRiderFace.SetGpu(Value:Boolean);
begin
  if FGpu=Value then Exit;FGpu:=Value;ResetNodes;
  if FValid then Evaluate;
end;
procedure TRiderFace.AttachGpu(Effect:TEffectNode);
begin
  DetachGpu;if not FValid then Exit;
  FPalette:=TMFMatrix4f.Create(Effect,True,'uRiderFaceDelta',[]);FPalette.Items.Assign(FMatrices);
  Effect.AddCustomField(FPalette);
  FActive:=TSFFloat.Create(Effect,True,'uRiderFaceActive',Ord(FVisibility>0));Effect.AddCustomField(FActive);
end;
procedure TRiderFace.DetachGpu;
begin FPalette:=nil;FActive:=nil end;
function TRiderFace.ShaderSource:String;
begin
  if not FValid then Exit('mat4 riderFaceDelta(int j){return mat4(1.0);}'+#10);
  Result:='uniform mat4 uRiderFaceDelta['+IntToStr(FCount)+'];uniform float uRiderFaceActive;'+#10+
    'mat4 riderFaceDelta(int j){if(uRiderFaceActive<0.5 || j<'+IntToStr(FFirst)+
    ' || j>='+IntToStr(FFirst+FCount)+')return mat4(1.0);return uRiderFaceDelta[j-'+IntToStr(FFirst)+'];}'+#10;
end;
procedure TRiderFace.Evaluate;
var I,C,R:Integer;Shift:array[0..RiderFaceJointCount-1]of TVector3;
  A,BrowAngle,LidAngle,Smile,Strain,Sign:Single;Jaw,D,Turn:TTripoMat4;Pivot:TTripoVec3;M:TMatrix4;Q,Rotation:TQuaternion;
begin
  if not FValid then Exit;
  Inc(FEvaluations);A:=DegToRad(16)*FControls.X;Smile:=FControls.Y;Strain:=FControls.Z;
  for I:=0 to RiderFaceJointCount-1 do Shift[I]:=TVector3.Zero;
  Shift[1]:=Vector3(0,0.0008*Smile-0.0010*Strain,0.0004*Smile-0.0008*Strain)*FScale;
  Shift[2]:=Vector3(0,-0.001*Smile+0.0020*Strain,0.0005*Smile-0.0008*Strain)*FScale;
  for I:=0 to 1 do begin
    Sign:=1-2*I;
    Shift[3+I]:=Vector3(Sign*(0.006*Smile+0.0005*Strain),0.006*Smile-0.0060*Strain,-0.001*Smile-0.0012*Strain)*FScale;
    Shift[5+I]:=Vector3(Sign*(0.001*Smile-0.0008*Strain),0.004*Smile+0.0035*Strain,0.001*Smile+0.0015*Strain)*FScale;
    Shift[7+I]:=Vector3(-Sign*0.0025*Strain,-0.0060*Strain,0.0010*Strain)*FScale;
  end;
  Pivot:=FRestPivot[0];
  Jaw:=Mat4FromQuat(TripoRig.QuatFromAxisAngle(1,0,0,A));
  D:=Mat4Identity;D[12]:=-Pivot.X;D[13]:=-Pivot.Y;D[14]:=-Pivot.Z;
  Jaw:=Mat4Mul(Jaw,D);Jaw[12]:=Jaw[12]+Pivot.X;Jaw[13]:=Jaw[13]+Pivot.Y;Jaw[14]:=Jaw[14]+Pivot.Z;
  for I:=0 to FCount-1 do begin
    D:=Mat4Identity;D[12]:=Shift[I].X;D[13]:=Shift[I].Y;D[14]:=Shift[I].Z;
    if I in [0,2]then D:=Mat4Mul(Jaw,D);
    BrowAngle:=0;LidAngle:=0;Rotation:=CastleQuaternions.QuatFromAxisAngle(Vector3(1,0,0),0,True);
    if I in [7,8]then begin
      { Corrugation lowers the inner brow more than the outer end. The
        mirrored rotations use the same bind-space pivots in CPU and GPU. }
      BrowAngle:=DegToRad(12)*Strain*(15-2*I);Pivot:=FRestPivot[I];
      Turn:=Mat4FromQuat(TripoRig.QuatFromAxisAngle(0,0,1,BrowAngle));
      Turn[12]:=Pivot.X-(Turn[0]*Pivot.X+Turn[4]*Pivot.Y+Turn[8]*Pivot.Z);
      Turn[13]:=Pivot.Y-(Turn[1]*Pivot.X+Turn[5]*Pivot.Y+Turn[9]*Pivot.Z);
      Turn[14]:=Pivot.Z-(Turn[2]*Pivot.X+Turn[6]*Pivot.Y+Turn[10]*Pivot.Z);
      D:=Mat4Mul(D,Turn);
    end;
    if I in [9..14]then begin
      if I in [9,11]then LidAngle:=DegToRad(37)*(FEyeControls.X+(1-FEyeControls.X)*Strain*0.30);
      if I in [10,12]then LidAngle:=-DegToRad(12)*(FEyeControls.X+(1-FEyeControls.X)*Strain*0.65);
      if I<13 then begin
        Turn:=Mat4FromQuat(TripoRig.QuatFromAxisAngle(1,0,0,LidAngle));
        Rotation:=CastleQuaternions.QuatFromAxisAngle(Vector3(1,0,0),LidAngle,True);
      end else begin
        Turn:=Mat4Mul(Mat4FromQuat(TripoRig.QuatFromAxisAngle(0,1,0,FEyeControls.Y)),
          Mat4FromQuat(TripoRig.QuatFromAxisAngle(1,0,0,FEyeControls.Z)));
        Rotation:=CastleQuaternions.QuatFromAxisAngle(Vector3(0,1,0),FEyeControls.Y,True)*
          CastleQuaternions.QuatFromAxisAngle(Vector3(1,0,0),FEyeControls.Z,True);
      end;
      Pivot:=FRestPivot[I];
      Turn[12]:=Pivot.X-(Turn[0]*Pivot.X+Turn[4]*Pivot.Y+Turn[8]*Pivot.Z);
      Turn[13]:=Pivot.Y-(Turn[1]*Pivot.X+Turn[5]*Pivot.Y+Turn[9]*Pivot.Z);
      Turn[14]:=Pivot.Z-(Turn[2]*Pivot.X+Turn[6]*Pivot.Y+Turn[10]*Pivot.Z);
      D:=Mat4Mul(D,Turn);
    end;
    for C:=0 to 3 do for R:=0 to 3 do M.Data[C,R]:=D[C*4+R];FMatrices[I]:=M;
    if not FGpu then begin
      Q:=CastleQuaternions.QuatFromAxisAngle(FRestR[I]);
      FNodes[I].Translation:=FRestT[I]+FParentInv[I].MultDirection(Shift[I]);
      if I=0 then Q:=Q*CastleQuaternions.QuatFromAxisAngle(Vector3(1,0,0),A,True);
      if I in [7,8]then Q:=Q*CastleQuaternions.QuatFromAxisAngle(Vector3(0,0,1),BrowAngle,True);
      if I in [9..14]then Q:=Q*Rotation;
      FNodes[I].Rotation:=Q.ToAxisAngle;
    end;
  end;
  if FGpu and(FPalette<>nil)then begin FPalette.Send(FMatrices);Inc(FUploads) end;
end;
procedure TRiderFace.Update(Dt,Effort:Single;BreathPhase:Double;BreathLoad:Single;FaceTime:Double);
var Target,EyeTarget:TVector3;Jaw,Load,Strain,Step:Single;Active,Reactivated:Boolean;
begin
  if not FValid or FSuspended then Exit;
  if (FLastSeen<>0)and(GetTickCount64-FLastSeen>300)then FTargetVisibility:=0;
  if(FTargetVisibility=0)and(FVisibility=0)and not FWasActive then Exit;
  Step:=1-Exp(-Max(Dt,0)/0.12);if Dt=0 then Step:=1;
  FVisibility:=FVisibility+(FTargetVisibility-FVisibility)*Step;
  if FVisibility<0.001 then FVisibility:=0;
  Active:=FVisibility>0;
  Reactivated:=Active and not FWasActive;
  if not Active and not FWasActive then Exit;
  if FActive<>nil then if Active<>FWasActive then FActive.Send(Ord(Active));
  FWasActive:=Active;
  if not Active then begin FControls:=TVector3.Zero;FEyeControls:=TVector3.Zero;ResetNodes;Exit end;
  if FOverride then Target:=FRequested
  else begin
    Load:=EnsureRange((BreathLoad-0.20)/1.15,0,1);
    Jaw:=Load*(0.25+0.23*(0.5+0.5*Sin(BreathPhase*2*Pi)));
    Strain:=RiderFaceStrain(Effort);
    Target:=Vector3(Jaw,0,Strain);
  end;
  { Expressions follow the existing smoothed breathing/load, visibility alone
    fades at the camera boundary. No independent clock that breaks rewind. }
  Target:=Target*FVisibility;
  EyeTarget:=TVector3.Zero;
  if GeometricEyes then EyeTarget:=Vector3(RiderFaceBlink(FaceTime),
    0.035*Sin(FaceTime*0.31)*Sin(FaceTime*0.73),0.012*Sin(FaceTime*0.43))*FVisibility;
  if not Reactivated and((Target-FControls).LengthSqr<1e-12)and((EyeTarget-FEyeControls).LengthSqr<1e-12)then begin
    { CPU body posing resets joint nodes each frame. Reapply a held facial
      expression there; the GPU palette can remain unchanged. }
    if not FGpu then Evaluate;
    Exit;
  end;
  FControls:=Target;FEyeControls:=EyeTarget;Evaluate;
end;
procedure TRiderFace.SetExpression(Manual:Boolean;Jaw,Smile,Strain:Single);
begin FOverride:=Manual;FRequested:=Vector3(EnsureRange(Jaw,0,1),EnsureRange(Smile,0,1),EnsureRange(Strain,0,1)) end;
function TRiderFace.CaptureReplay:TRiderFaceReplay;
begin
  Result.Valid:=FValid;Result.Manual:=FOverride;Result.Visibility:=FVisibility;Result.Requested:=FRequested;
end;
procedure TRiderFace.RestoreReplay(const Saved:TRiderFaceReplay);
begin
  if not Saved.Valid then Exit;
  FOverride:=Saved.Manual;FRequested:=Saved.Requested;
  FVisibility:=Saved.Visibility;FTargetVisibility:=Saved.Visibility;FLastSeen:=GetTickCount64;
end;
procedure TRiderFace.DebugJson(Result:TJSONObject);
var Q:TQuaternion;
begin
  Result.Add('valid',FValid);Result.Add('gpu',FGpu);Result.Add('visibility',FVisibility);
  Result.Add('target_visibility',FTargetVisibility);Result.Add('distance_m',FDistance);
  Result.Add('facing',FFacing);Result.Add('pixels',FPixels);Result.Add('evaluations',Int64(FEvaluations));
  Result.Add('uploads',Int64(FUploads));Result.Add('jaw',FControls.X);Result.Add('smile',FControls.Y);
  Result.Add('strain',FControls.Z);Result.Add('manual',FOverride);Result.Add('joints',FCount);
  Result.Add('geometric_eyes',GeometricEyes);Result.Add('blink',FEyeControls.X);
  if FValid then begin
    Q:=CastleQuaternions.QuatFromAxisAngle(FRestR[0]).Conjugate*
      CastleQuaternions.QuatFromAxisAngle(FNodes[0].Rotation);
    Result.Add('native_jaw_deg',RadToDeg(2*ArcCos(EnsureRange(Abs(Q.Data.Real),0,1))));
  end;
end;
end.
