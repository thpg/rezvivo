unit RiderBodyDeformation;

{$mode objfpc}{$H+}

{ Shared native/procedural GPU deformation. No animated CPU vertex traversal.
  Bind-space centres are authored offline. Muscle length is measured between
  skeletal attachments; soft contact is bounded and independent of frame time. }
interface
uses Classes, SysUtils, Math, fpjson, CastleUtils, CastleVectors, X3DNodes, X3DFields,
  TripoRig, RiderBodyParameters, RiderDynamics;
type
  TRiderBodyDeformation = class
  private
    type
      TShape = record
        Geometry:TAbstractComposedGeometryNode;
        Attr,ContactAttr: TFloatVertexAttributeNode;
        Gradient: array[0..2] of TFloatVertexAttributeNode;
        First:Integer;
        Centre: array of TVector4;
        Tissue: array of TVector4;
        Delta: array[0..4] of array of TVector3;
      end;
      TMuscle = record
        A,B: TVector3;
        Response: TVector4;
        JA,JB: Integer;
        BroadAttachment: Boolean;
        Channel: Integer;
      end;
    var
      FShapes: array of TShape;
      FMuscles: array of TMuscle;
      FRig: TTripoRig;
      FInfo: TJSONObject;
      FProfile: TVector4;
      FFrame: TVector2;
      FLengths: TSingleList;
      FEffects: array[0..1] of TEffectNode;
      FFrameFields: array[0..1] of TSFVec2f;
      FDynamicFields: array[0..1] of TMFVec4f;
      FDynamicValues: TVector4List;
      FDynamicSent: array[0..1,0..7] of TVector4;
      FDynamicValid: array[0..1] of Boolean;
      FUseDynamics: Boolean;
      FLast: TRiderBodyParameters;
      FApplied: Boolean;
      FSurfaceGradients: Boolean;
    procedure SendConstants;
    procedure RefreshSurfaceGradients;
  public
    destructor Destroy; override;
    function Load(const Path:string; Skin:TSkinNode; Rig:TTripoRig):Boolean;
    procedure AddUniforms(Effect:TEffectNode; Gpu:Boolean);
    procedure DetachGpu;
    procedure SetBodyParameters(const Value:TRiderBodyParameters);
    procedure RefreshBind;
    procedure Update(const Effort:Single; const Phase:Double);
    procedure SetDynamicsFrame(const Frame:TRiderDynamicsFrame;
      const ToBike:TMatrix4;const Saddle:TVector3);
    property UseDynamics:Boolean read FUseDynamics write FUseDynamics;
    procedure SendActiveFrame;
    function ShaderSource(const JointFunction:string):string;
  end;
implementation
uses GltfCore, RiderCorrectiveData, RiderRuntimeAudit;

destructor TRiderBodyDeformation.Destroy;
begin FInfo.Free;FLengths.Free;FDynamicValues.Free;inherited end;

function TRiderBodyDeformation.Load(const Path:string;Skin:TSkinNode;Rig:TTripoRig):Boolean;
var D:TMemoryStream; S,M,R:TJSONArray; O:TJSONObject; I,J,K,V,N,First:Integer;
  Sh:TShapeNode; G:TAbstractComposedGeometryNode; A:TFloatVertexAttributeNode;
  T:TVector4; Name:string;
begin
  Result:=False;D:=OpenRiderEmbeddedData(Path,'riderDeformation',FInfo);
  if D=nil then Exit;
  try
    if FInfo.Get('version',0)<>1 then raise EReadError.Create('Unsupported rider deformation version');
    FRig:=Rig;S:=ArrOf(FInfo,'shapes');M:=ArrOf(FInfo,'muscles');
    { Explicit diagnostic comparison, read once at model load. }
    FSurfaceGradients:=GetEnvironmentVariable('REZVIVO_RIDER_NORMAL_GRADIENTS')<>'0';
    if(S=nil)or(M=nil)or(M.Count>32)or(FInfo.Get('vertices',0)<>Rig.VertexCount)or
      (D.Size<>Int64(Rig.VertexCount)*23*SizeOf(Single))then
      raise EReadError.Create('Invalid rider deformation header');
    FLengths:=TSingleList.Create;SetLength(FMuscles,M.Count);
    FDynamicValues:=TVector4List.Create;
    for I:=0 to 7 do FDynamicValues.Add(Vector4(0,0,0,0));
    for I:=0 to M.Count-1 do begin
      O:=M.Objects[I];FMuscles[I].JA:=ArrOf(O,'joints').Integers[0];
      FMuscles[I].JB:=ArrOf(O,'joints').Integers[1];
      Name:=LowerCase(O.Get('name',''));FMuscles[I].Channel:=-1;
      if Pos('gluteal',Name)>0 then FMuscles[I].Channel:=0
      else if (Pos('quad',Name)>0)or(Pos('rectus',Name)>0)or(Pos('vast',Name)>0)then FMuscles[I].Channel:=1
      else if Pos('ham',Name)>0 then FMuscles[I].Channel:=2
      else if Pos('calf',Name)>0 then FMuscles[I].Channel:=3;
      if (FMuscles[I].Channel>=0)and(Copy(Name,1,2)='l_')then Inc(FMuscles[I].Channel,4);
      { Older embedded bindings identify muscles by name. A broad gluteal
        sheet already has a complete surface envelope, not a fusiform belly
        tapering to two point tendons. Keep those models compatible. }
      FMuscles[I].BroadAttachment:=O.Get('shape','')='broad';
      if O.Find('shape')=nil then
        FMuscles[I].BroadAttachment:=Pos('_gluteal',O.Get('name',''))>0;
      if(FMuscles[I].JA<0)or(FMuscles[I].JB<0)or(FMuscles[I].JA>=Rig.JointCount)or
        (FMuscles[I].JB>=Rig.JointCount)then raise EReadError.Create('Invalid muscle attachment');
      for K:=0 to 2 do begin FMuscles[I].A.Data[K]:=ArrOf(O,'a').Floats[K];FMuscles[I].B.Data[K]:=ArrOf(O,'b').Floats[K] end;
      FMuscles[I].Response:=Vector4(0,0,0.025,0.80);
      R:=ArrOf(O,'response');
      if R<>nil then begin
        if R.Count<>4 then raise EReadError.Create('Invalid muscle response');
        for K:=0 to 3 do FMuscles[I].Response.Data[K]:=R.Floats[K];
      end;
    end;
    SetLength(FShapes,S.Count);First:=0;
    for I:=0 to S.Count-1 do begin
      O:=S.Objects[I];N:=O.Get('vertices',0);Sh:=nil;
      for J:=0 to Skin.FdShapes.Count-1 do
        if(Skin.FdShapes[J] is TShapeNode)and(Skin.FdShapes[J].X3DName=O.Get('name',''))then Sh:=TShapeNode(Skin.FdShapes[J]);
      if(Sh=nil)or not(Sh.Geometry is TAbstractComposedGeometryNode)or(N<=0)or
        (O.Get('first',-1)<>First)then raise EReadError.Create('Invalid body deformation mesh');
      G:=TAbstractComposedGeometryNode(Sh.Geometry);
      FShapes[I].Geometry:=G;
      if not(G.FdCoord.Value is TCoordinateNode)or(TCoordinateNode(G.FdCoord.Value).FdPoint.Count<>N)then
        raise EReadError.Create('Body deformation vertex count mismatch');
      FShapes[I].First:=First;Inc(First,N);SetLength(FShapes[I].Centre,N);
      D.ReadBuffer(FShapes[I].Centre[0],N*SizeOf(TVector4));
      A:=TFloatVertexAttributeNode.Create;A.FdName.Value:='riderCentre';A.NumComponents:=4;
      for V:=0 to N-1 do for K:=0 to 3 do A.FdValue.Items.Add(FShapes[I].Centre[V].Data[K]);
      G.FdAttrib.Add(A);FShapes[I].Attr:=A;
      for K:=0 to 4 do begin
        SetLength(FShapes[I].Delta[K],N);D.ReadBuffer(FShapes[I].Delta[K][0],N*SizeOf(TVector3));
      end;
      A:=TFloatVertexAttributeNode.Create;A.FdName.Value:='riderTissue';A.NumComponents:=4;
      SetLength(FShapes[I].Tissue,N);
      for V:=0 to N-1 do begin
        D.ReadBuffer(T,SizeOf(T));
        FShapes[I].Tissue[V]:=T;
        if(T.X< -1)or(T.X>=M.Count)then raise EReadError.Create('Invalid vertex muscle');
        for K:=0 to 3 do A.FdValue.Items.Add(T.Data[K]);
      end;
      G.FdAttrib.Add(A);
      { xy: neutral contact, zw: surface derivatives of the muscle envelope.
        Reuse the attribute slot; no extra mesh data or animated CPU work. }
      A:=TFloatVertexAttributeNode.Create;A.FdName.Value:='riderContactRest';A.NumComponents:=4;
      for V:=0 to N*4-1 do A.FdValue.Items.Add(0);
      G.FdAttrib.Add(A);FShapes[I].ContactAttr:=A;
      if FSurfaceGradients then for K:=0 to 2 do begin
        A:=TFloatVertexAttributeNode.Create;A.FdName.Value:='riderGradient'+IntToStr(K);A.NumComponents:=4;
        for V:=0 to N*4-1 do A.FdValue.Items.Add(0);
        G.FdAttrib.Add(A);FShapes[I].Gradient[K]:=A;
      end;
    end;
    if(First<>Rig.VertexCount)or(D.Position<>D.Size)then raise EReadError.Create('Incomplete rider deformation');
    SetBodyParameters(DefaultRiderBody(1));RefreshBind;Result:=True;
  finally D.Free end;
end;

procedure TRiderBodyDeformation.AddUniforms(Effect:TEffectNode;Gpu:Boolean);
var F:TMFFloat;A,B,R:TMFVec4f;I:Integer;
begin
  FEffects[Ord(Gpu)]:=Effect;
  Effect.AddCustomField(TSFVec4f.Create(Effect,True,'uBodyProfile',FProfile));
  FFrameFields[Ord(Gpu)]:=TSFVec2f.Create(Effect,True,'uBodyFrame',FFrame);
  Effect.AddCustomField(FFrameFields[Ord(Gpu)]);
  FDynamicFields[Ord(Gpu)]:=TMFVec4f.Create(Effect,True,'uBodyDynamics',[]);
  FDynamicFields[Ord(Gpu)].Items.Assign(FDynamicValues);
  Effect.AddCustomField(FDynamicFields[Ord(Gpu)]);
  FDynamicValid[Ord(Gpu)]:=False;
  F:=TMFFloat.Create(Effect,True,'uMuscleRestLength',[]);F.Items.Assign(FLengths);Effect.AddCustomField(F);
  A:=TMFVec4f.Create(Effect,True,'uMuscleA',[]);B:=TMFVec4f.Create(Effect,True,'uMuscleB',[]);
  R:=TMFVec4f.Create(Effect,True,'uMuscleResponse',[]);
  for I:=0 to High(FMuscles)do begin
    A.Items.Add(Vector4(FMuscles[I].A.X,FMuscles[I].A.Y,FMuscles[I].A.Z,FMuscles[I].JA));
    B.Items.Add(Vector4(FMuscles[I].B.X,FMuscles[I].B.Y,FMuscles[I].B.Z,FMuscles[I].JB));
    R.Items.Add(FMuscles[I].Response);
  end;
  Effect.AddCustomField(A);Effect.AddCustomField(B);Effect.AddCustomField(R);
end;
procedure TRiderBodyDeformation.DetachGpu;
begin FEffects[1]:=nil;FFrameFields[1]:=nil;FDynamicFields[1]:=nil;FDynamicValid[1]:=False end;
procedure TRiderBodyDeformation.SendConstants;
var I:Integer;F:TX3DField;
begin
  for I:=0 to 1 do if FEffects[I]<>nil then begin
    F:=FEffects[I].Field('uBodyProfile',False);if F is TSFVec4f then TSFVec4f(F).Send(FProfile);
    F:=FEffects[I].Field('uMuscleRestLength',False);if F is TMFFloat then TMFFloat(F).Send(FLengths);
  end;
end;
procedure TRiderBodyDeformation.SetBodyParameters(const Value:TRiderBodyParameters);
var P:TRiderBodyParameters;C:array[0..4]of Single;I,V,K,A:Integer;T:TVector4;
begin
  P:=NormalizeRiderBody(Value);if FApplied and SameRiderBody(P,FLast)then Exit;
  C[0]:=1-P.Sex;C[4]:=1-P.HeadShape;RiderBodyShapeWeights(P,C[1],C[2],C[3]);
  FProfile:=Vector4(Max(0,C[1]),Max(0,C[2]),Max(0,C[3]),P.Composition);
  for I:=0 to High(FShapes)do begin
    for V:=0 to High(FShapes[I].Centre)do begin
      T:=FShapes[I].Centre[V];
      for K:=0 to 4 do for A:=0 to 2 do T.Data[A]:=T.Data[A]+FShapes[I].Delta[K][V].Data[A]*C[K];
      for A:=0 to 3 do FShapes[I].Attr.FdValue.Items[V*4+A]:=T.Data[A];
    end;
    FShapes[I].Attr.FdValue.Changed;
  end;
  FLast:=P;FApplied:=True;SendConstants;
end;
procedure TRiderBodyDeformation.RefreshBind;
var I,J,K,V,Index,Side,BellyJ:Integer;A,B,P,Q,C,R,G:TTripoVec3;M,BellyInv:TTripoMat4;
  Palette:array of TTripoMat4;ThighA,ThighB:array[0..1]of TTripoVec3;
  Thighs:TJSONArray;D,L,H,Radius,Depth:Single;
  Metric:TFloatVertexAttributeNode;
begin
  FLengths.Clear;
  SetLength(Palette,FRig.JointCount);
  for J:=0 to FRig.JointCount-1 do Palette[J]:=Mat4Mul(FRig.BindWorld[J],FRig.NativeInvBind[J]);
  for I:=0 to High(FMuscles)do begin
    M:=Mat4Mul(FRig.BindWorld[FMuscles[I].JA],FRig.NativeInvBind[FMuscles[I].JA]);
    A:=Mat4MulPoint(M,V3(FMuscles[I].A.X,FMuscles[I].A.Y,FMuscles[I].A.Z));
    M:=Mat4Mul(FRig.BindWorld[FMuscles[I].JB],FRig.NativeInvBind[FMuscles[I].JB]);
    B:=Mat4MulPoint(M,V3(FMuscles[I].B.X,FMuscles[I].B.Y,FMuscles[I].B.Z));
    FLengths.Add(Max(0.001,V3Len(V3Sub(A,B))));
  end;
  BellyJ:=FInfo.Get('bellyJoint',0);BellyInv:=Mat4Inverse(Palette[BellyJ]);
  C:=V3(ArrOf(FInfo,'bellyCentre').Floats[0],ArrOf(FInfo,'bellyCentre').Floats[1],
    ArrOf(FInfo,'bellyCentre').Floats[2]+0.035*FProfile.X);
  R:=V3(ArrOf(FInfo,'bellyRadii').Floats[0]*(1+0.35*FProfile.X),ArrOf(FInfo,'bellyRadii').Floats[1],
    ArrOf(FInfo,'bellyRadii').Floats[2]*(1+0.65*FProfile.X));
  Radius:=FInfo.Get('thighRadius',0.07)*(1+0.28*FProfile.X+0.24*FProfile.Y);
  Thighs:=ArrOf(FInfo,'thighs');
  for Side:=0 to 1 do begin
    J:=Thighs.Arrays[Side].Integers[0];M:=Mat4Inverse(FRig.NativeInvBind[J]);
    ThighA[Side]:=Mat4MulPoint(Palette[J],V3(M[12],M[13],M[14]));
    J:=Thighs.Arrays[Side].Integers[1];M:=Mat4Inverse(FRig.NativeInvBind[J]);
    ThighB[Side]:=Mat4MulPoint(Palette[J],V3(M[12],M[13],M[14]));
  end;
  { Only a profile/bind edit computes neutral proxy overlap. Animation uploads
    two scalars and evaluates the same contact field entirely on the GPU. }
  for I:=0 to High(FShapes)do begin
    Metric:=nil;
    for K:=0 to FShapes[I].Geometry.FdAttrib.Count-1 do
      if(FShapes[I].Geometry.FdAttrib[K]is TFloatVertexAttributeNode)and
        (TFloatVertexAttributeNode(FShapes[I].Geometry.FdAttrib[K]).NameField='riderFabricMetric')then
        Metric:=TFloatVertexAttributeNode(FShapes[I].Geometry.FdAttrib[K]);
    for V:=0 to High(FShapes[I].Centre)do begin
      if(Metric=nil)and(Abs(FShapes[I].Tissue[V].Z)<0.0001)then Continue;
      Index:=FShapes[I].First+V;P:=V3(0,0,0);
      for K:=0 to 3 do if FRig.Weights[Index][K]>0 then
        P:=V3Add(P,V3Scale(Mat4MulPoint(Palette[FRig.Joints[Index][K]],FRig.Positions[Index]),FRig.Weights[Index][K]));
      if Metric<>nil then begin
        Metric.FdValue.Items[V*3]:=P.X;Metric.FdValue.Items[V*3+1]:=P.Y;Metric.FdValue.Items[V*3+2]:=P.Z;
      end;
      if Abs(FShapes[I].Tissue[V].Z)<0.0001 then Continue;
      for Side:=0 to 1 do begin
        if FShapes[I].Tissue[V].Z<0 then begin
          Q:=V3Sub(Mat4MulPoint(BellyInv,P),C);D:=Sqrt(Sqr(Q.X/R.X)+Sqr(Q.Y/R.Y)+Sqr(Q.Z/R.Z));
          G:=V3(Q.X/Sqr(R.X),Q.Y/Sqr(R.Y),Q.Z/Sqr(R.Z));Depth:=Max(0,1-D)/Max(V3Len(G),0.0001);
        end else begin
          A:=ThighA[Side];B:=V3Sub(ThighB[Side],A);Q:=V3Sub(P,A);
          L:=Sqr(B.X)+Sqr(B.Y)+Sqr(B.Z);H:=EnsureRange((Q.X*B.X+Q.Y*B.Y+Q.Z*B.Z)/Max(L,0.0001),0.12,0.90);
          Depth:=Max(0,Radius-V3Len(V3Sub(P,V3Add(A,V3Scale(B,H)))));
        end;
        FShapes[I].ContactAttr.FdValue.Items[V*4+Side]:=Depth;
      end;
    end;
    FShapes[I].ContactAttr.FdValue.Changed;
    if Metric<>nil then Metric.FdValue.Changed;
  end;
  if FSurfaceGradients then RefreshSurfaceGradients;
  SendConstants;
end;

procedure TRiderBodyDeformation.RefreshSurfaceGradients;
type TGradient=record
  Weight,Centre:array[0..2] of TTripoVec3;
  Muscle:TTripoVec3;
  MuscleArea:Single;
  Area:Single;
end;
var C:array of TTripoVec3; Tissue:array of TVector4;
  Acc:array of TGradient; AliasIndex:array of Integer;
  Keys:TStringList;Key:string;I,J,K,V,N,A,B,D,Corner,Slot,Root:Integer;
  Tri:array[0..2]of Integer; E1,E2,Cross,G1,G2,DC1,DC2,T,U,Normal,Grad:TTripoVec3;
  Area,Den,W0,W1,W2:Single; Values:array[0..11]of Single;
  function WeightAt(Vertex,Joint:Integer):Single;
  var L:Integer;
  begin
    Result:=0;
    for L:=0 to 3 do if FRig.Joints[Vertex][L]=Joint then
      Result:=Result+FRig.Weights[Vertex][L];
  end;
  function Component(const P:TTripoVec3;Index:Integer):Single;
  begin case Index of 0:Result:=P.X;1:Result:=P.Y;else Result:=P.Z end end;
begin
  { Rest-surface derivatives change only with the body profile. The animated
    shader differentiates its actual skin map; rotating a normal alone misses
    weight and rotation-centre gradients at elbows, hips and shoulders. }
  N:=FRig.VertexCount;SetLength(C,N);SetLength(Tissue,N);SetLength(Acc,N);SetLength(AliasIndex,N);
  for I:=0 to High(FShapes)do for V:=0 to High(FShapes[I].Centre)do begin
    J:=FShapes[I].First+V;K:=V*4;
    C[J]:=V3(FShapes[I].Attr.FdValue.Items[K],FShapes[I].Attr.FdValue.Items[K+1],FShapes[I].Attr.FdValue.Items[K+2]);
    Tissue[J]:=FShapes[I].Tissue[V];
  end;
  Keys:=TStringList.Create;
  try
    { Append then sort once. Sorted insertion shifts an O(N) pointer array
      for every vertex and made body-profile edits unnecessarily expensive. }
    for V:=0 to N-1 do begin
      T:=FRig.Positions[V];
      Key:=IntToStr(Round(T.X*1E6))+','+IntToStr(Round(T.Y*1E6))+','+IntToStr(Round(T.Z*1E6));
      for K:=0 to 3 do Key:=Key+','+IntToStr(FRig.Joints[V][K]);
      Keys.AddObject(Key,TObject(PtrUInt(V+1)));
    end;
    Keys.Sort;Key:='';Root:=-1;
    for I:=0 to Keys.Count-1 do begin
      V:=PtrUInt(Keys.Objects[I])-1;
      if(I=0)or(Keys[I]<>Key)then begin Root:=V;Key:=Keys[I] end;
      AliasIndex[V]:=Root;
    end;
    for I:=0 to Length(FRig.Indices)div 3-1 do begin
      for K:=0 to 2 do Tri[K]:=FRig.Indices[I*3+K];
      A:=Tri[0];B:=Tri[1];D:=Tri[2];
      E1:=V3Sub(FRig.Positions[B],FRig.Positions[A]);E2:=V3Sub(FRig.Positions[D],FRig.Positions[A]);
      Cross:=V3Cross(E1,E2);Den:=V3Dot(Cross,Cross);if Den<1E-18 then Continue;
      Area:=Sqrt(Den);G1:=V3Scale(V3Cross(E2,Cross),1/Den);G2:=V3Scale(V3Cross(Cross,E1),1/Den);
      DC1:=V3Sub(C[B],C[A]);DC2:=V3Sub(C[D],C[A]);
      for Corner:=0 to 2 do begin
        V:=Tri[Corner];Root:=AliasIndex[V];Acc[Root].Area:=Acc[Root].Area+Area;
        { Different muscles have different local maps. Estimate an envelope
          within its own connected patch, not across an unrelated tendon. }
        if(Tissue[A].X>=0)and(Tissue[A].X=Tissue[B].X)and(Tissue[A].X=Tissue[D].X)then begin
          Grad:=V3Add(V3Scale(G1,Tissue[B].Y-Tissue[A].Y),V3Scale(G2,Tissue[D].Y-Tissue[A].Y));
          Acc[Root].Muscle:=V3Add(Acc[Root].Muscle,V3Scale(Grad,Area));
          Acc[Root].MuscleArea:=Acc[Root].MuscleArea+Area;
        end;
        for Slot:=0 to 2 do begin
          J:=FRig.Joints[V][Slot];W0:=WeightAt(A,J);W1:=WeightAt(B,J);W2:=WeightAt(D,J);
          Grad:=V3Add(V3Scale(G1,W1-W0),V3Scale(G2,W2-W0));
          Acc[Root].Weight[Slot]:=V3Add(Acc[Root].Weight[Slot],V3Scale(Grad,Area));
          Grad:=V3Add(V3Scale(G1,Component(DC1,Slot)),V3Scale(G2,Component(DC2,Slot)));
          Acc[Root].Centre[Slot]:=V3Add(Acc[Root].Centre[Slot],V3Scale(Grad,Area));
        end;
      end;
    end;
    for I:=0 to High(FShapes)do begin
      for V:=0 to High(FShapes[I].Centre)do begin
        J:=FShapes[I].First+V;Root:=AliasIndex[J];Area:=Max(Acc[Root].Area,1E-12);
        Normal:=V3Norm(FRig.Normals[J]);
        if Abs(Normal.Y)<0.9 then T:=V3Norm(V3Cross(Normal,V3(0,1,0)))
        else T:=V3Norm(V3Cross(Normal,V3(1,0,0)));
        U:=V3Cross(Normal,T);
        for K:=0 to 2 do begin
          Values[K]:=V3Dot(Acc[Root].Weight[K],T)/Area;
          Values[3+K]:=V3Dot(Acc[Root].Weight[K],U)/Area;
          Values[6+K]:=V3Dot(Acc[Root].Centre[K],T)/Area;
          Values[9+K]:=V3Dot(Acc[Root].Centre[K],U)/Area;
        end;
        for K:=0 to 11 do FShapes[I].Gradient[K div 4].FdValue.Items[V*4+K mod 4]:=Values[K];
        Den:=Max(Acc[Root].MuscleArea,1E-12);
        FShapes[I].ContactAttr.FdValue.Items[V*4+2]:=V3Dot(Acc[Root].Muscle,T)/Den;
        FShapes[I].ContactAttr.FdValue.Items[V*4+3]:=V3Dot(Acc[Root].Muscle,U)/Den;
      end;
      for K:=0 to 2 do FShapes[I].Gradient[K].FdValue.Changed;
      FShapes[I].ContactAttr.FdValue.Changed;
    end;
  finally Keys.Free end;
end;
procedure TRiderBodyDeformation.Update(const Effort:Single;const Phase:Double);
begin
  if FUseDynamics then FFrame:=Vector2(EnsureRange(Effort,0,2),0)
  else FFrame:=Vector2(EnsureRange(Effort,0,2),Frac(Phase));
  SendActiveFrame;
end;

procedure TRiderBodyDeformation.SetDynamicsFrame(const Frame:TRiderDynamicsFrame;
  const ToBike:TMatrix4;const Saddle:TVector3);
var X,Y,Z,T:TVector3;Den:Single;
begin
  if FDynamicValues=nil then Exit;
  FDynamicValues[0]:=Vector4(Frame.Muscle[0],Frame.Muscle[1],Frame.Muscle[2],Frame.Muscle[3]);
  FDynamicValues[1]:=Vector4(Frame.Muscle[4],Frame.Muscle[5],Frame.Muscle[6],Frame.Muscle[7]);
  FDynamicValues[2]:=Vector4(Frame.Tissue[0]/0.12,Frame.Tissue[1]/0.12,
    Frame.Tissue[2]/0.10,Frame.Tissue[3]/0.10);
  FDynamicValues[3]:=Vector4(Frame.SeatCompression[0],Frame.SeatCompression[1],
    Ord(Frame.SeatLoad[0]+Frame.SeatLoad[1]>0.1),Ord(FUseDynamics));
  X:=ToBike.MultDirection(Vector3(1,0,0));Y:=ToBike.MultDirection(Vector3(0,1,0));
  Z:=ToBike.MultDirection(Vector3(0,0,1));T:=ToBike.MultPoint(TVector3.Zero)-Saddle;
  FDynamicValues[4]:=Vector4(X.X,Y.X,Z.X,T.X);
  FDynamicValues[5]:=Vector4(X.Y,Y.Y,Z.Y,T.Y);
  FDynamicValues[6]:=Vector4(X.Z,Y.Z,Z.Z,T.Z);
  Den:=Max(1E-8,X.LengthSqr);
  FDynamicValues[7]:=Vector4(X.Y/Den,Y.Y/Den,Z.Y/Den,0);
end;

procedure TRiderBodyDeformation.SendActiveFrame;
var I,J:Integer;Dirty:Boolean;V:TVector4;
begin
  if FDynamicValues<>nil then begin
    V:=FDynamicValues[3];V.W:=Ord(FUseDynamics);FDynamicValues[3]:=V;
  end;
  { Keep the most recent frame in FFrame; an inactive native/GPU program
    consumes no events. Path switches flush it before their next draw. }
  for I:=0 to 1 do
    if (FEffects[I]<>nil) and FEffects[I].Enabled and (FFrameFields[I]<>nil) then
      if (FFrameFields[I].Value.X<>FFrame.X) or (FFrameFields[I].Value.Y<>FFrame.Y) then
      begin
        CountRiderWork(rwBodyFrameSend);
        FFrameFields[I].Send(FFrame);
      end;
  for I:=0 to 1 do
    if (FEffects[I]<>nil)and FEffects[I].Enabled and(FDynamicFields[I]<>nil)then begin
      Dirty:=not FDynamicValid[I];
      for J:=0 to 7 do if not TVector4.Equals(FDynamicSent[I,J],FDynamicValues[J])then Dirty:=True;
      if Dirty then begin
        FDynamicFields[I].Send(FDynamicValues);
        for J:=0 to 7 do FDynamicSent[I,J]:=FDynamicValues[J];
        FDynamicValid[I]:=True;
      end;
    end;
end;

function TRiderBodyDeformation.ShaderSource(const JointFunction:string):string;
var S:TStringList;I:Integer;A:TJSONArray;BroadCondition:string;
  function Num(X:Double):string;
  begin Str(X:0:9,Result) end;
  function Vec(V:TVector3):string;
  begin Result:='vec3('+Num(V.X)+','+Num(V.Y)+','+Num(V.Z)+')' end;
  function JsonVec(Key:string):string;
  var V:TVector3;K:Integer;
  begin for K:=0 to 2 do V.Data[K]:=ArrOf(FInfo,Key).Floats[K];Result:=Vec(V) end;
  function Pivot(J:Integer):string;
  var M:TTripoMat4;
  begin M:=Mat4Inverse(FRig.NativeInvBind[J]);Result:=Vec(Vector3(M[12],M[13],M[14])) end;
begin
  S:=TStringList.Create;
  try
    S.Add('attribute vec4 riderCentre; attribute vec4 riderTissue;attribute vec4 riderContactRest;');
    if FSurfaceGradients then S.Add('#define BODY_NORMAL_GRADIENTS');
    S.Add('#ifdef BODY_NORMAL_GRADIENTS');
    S.Add('attribute vec4 riderGradient0,riderGradient1,riderGradient2;');
    S.Add('#endif');
    S.Add('uniform vec4 uBodyProfile; uniform vec2 uBodyFrame;uniform vec4 uBodyDynamics[8];');
    S.Add('uniform float uMuscleRestLength['+IntToStr(Length(FMuscles))+'];');
    S.Add('uniform vec4 uMuscleA['+IntToStr(Length(FMuscles))+'];uniform vec4 uMuscleB['+IntToStr(Length(FMuscles))+'];');
    S.Add('uniform vec4 uMuscleResponse['+IntToStr(Length(FMuscles))+'];');
    BroadCondition:='false';
    for I:=0 to High(FMuscles)do if FMuscles[I].BroadAttachment then
      BroadCondition:=BroadCondition+' || id=='+IntToStr(I);
    S.Add('bool bodyBroadMuscle(int id){return '+BroadCondition+';}');
    S.Add('int bodyMuscleChannel(int id){');
    for I:=0 to High(FMuscles)do if FMuscles[I].Channel>=0 then
      S.Add('if(id=='+IntToStr(I)+')return '+IntToStr(FMuscles[I].Channel)+';');
    S.Add('return -1;}');
    S.Add('mat4 bodyJoint(int j){return '+JointFunction+'(j);}');
    S.Add('vec4 bodyQuat(mat3 m){');
    S.Add('  vec4 q; float t=m[0][0]+m[1][1]+m[2][2];');
    S.Add('  if(t>0.0){float s=sqrt(t+1.0)*2.0;q=vec4((m[1][2]-m[2][1])/s,(m[2][0]-m[0][2])/s,(m[0][1]-m[1][0])/s,s*.25);}');
    S.Add('  else if(m[0][0]>m[1][1] && m[0][0]>m[2][2]){float s=sqrt(max(1e-8,1.0+m[0][0]-m[1][1]-m[2][2]))*2.0;q=vec4(s*.25,(m[1][0]+m[0][1])/s,(m[2][0]+m[0][2])/s,(m[1][2]-m[2][1])/s);}');
    S.Add('  else if(m[1][1]>m[2][2]){float s=sqrt(max(1e-8,1.0+m[1][1]-m[0][0]-m[2][2]))*2.0;q=vec4((m[1][0]+m[0][1])/s,s*.25,(m[2][1]+m[1][2])/s,(m[2][0]-m[0][2])/s);}');
    S.Add('  else{float s=sqrt(max(1e-8,1.0+m[2][2]-m[0][0]-m[1][1]))*2.0;q=vec4((m[2][0]+m[0][2])/s,(m[2][1]+m[1][2])/s,s*.25,(m[0][1]-m[1][0])/s);}return normalize(q);}');
    S.Add('vec3 bodyRotate(vec4 q,vec3 p){return p+2.0*cross(q.xyz,cross(q.xyz,p)+q.w*p);}');
    S.Add('vec3 bodyRotateDerivative(vec4 q,vec4 d,vec3 p){return 2.0*(cross(d.xyz,cross(q.xyz,p)+q.w*p)+cross(q.xyz,cross(d.xyz,p)+d.w*p));}');
    S.Add('void bodyMuscle(int id,out vec3 a,out vec3 b){vec4 va=uMuscleA[id],vb=uMuscleB[id];a=(bodyJoint(int(va.w+.5))*vec4(va.xyz,1.0)).xyz;b=(bodyJoint(int(vb.w+.5))*vec4(vb.xyz,1.0)).xyz;}');
    { Bones already move the attachment points. Only change the local muscle
      cross-section here; shortening the posed skin again makes hip bulges.
      Normals follow both the longitudinal belly and the transverse envelope.
      Omitting the latter hid contraction at the gluteal/hip transition. }
    S.Add('void bodyMuscleDeform(inout vec3 p,inout vec3 n,vec3 envelopeGradient){');
    S.Add(' if(riderTissue.y<0.0001)return; int id=int(riderTissue.x+0.5);vec3 a,b;bodyMuscle(id,a,b);');
    S.Add(' vec3 axis=b-a;float len=max(length(axis),.001);axis/=len;');
    S.Add(' vec4 response=uMuscleResponse[id];float activation,tissue=0.0;');
    S.Add(' int channel=bodyMuscleChannel(id);if(uBodyDynamics[3].w>.5){');
    S.Add(' if(channel>=0){int side=channel/4,part=channel-4*side;activation=uBodyDynamics[side][part];');
    S.Add(' if(part==0)tissue=uBodyDynamics[2][side];else if(part==1)tissue=uBodyDynamics[2][2+side];}else activation=clamp(uBodyFrame.x*.12,0.0,.35);');
    S.Add(' }else{float wave=max(0.0,cos(6.2831853*(uBodyFrame.y-response.x)));activation=clamp(uBodyFrame.x*.5,0.0,1.0)*mix(1.0,.08+.92*wave*wave,response.y);}');
    S.Add(' float strain=(clamp(sqrt(uMuscleRestLength[id]/len),.90,1.12)-1.0)*response.w+response.z*activation;');
    S.Add(' float share=clamp(.28+.16*uBodyProfile.y-.12*uBodyProfile.x,.10,.52);');
    S.Add(' vec3 d=p-a;float h=dot(d,axis);vec3 radial=d-axis*h;float along=clamp(h/len,0.0,1.0);');
    { The gluteal field spans the posterior pelvis. Reapplying a narrow
      longitudinal taper in posed coordinates suppressed its upper surface
      and made the active area slide as the thigh flexed. Its authored field
      and surface derivative supply the complete broad attachment taper. }
    { The solver's tissue mode is already a physical displacement divided by
      its radius. Do not attenuate it a second time with muscle surface share. }
    S.Add(' bool broad=bodyBroadMuscle(id);float belly=broad?1.0:sin(3.14159265*along),responseScale=strain*share+tissue,k=responseScale*riderTissue.y,s=1.0+k*belly*belly;');
    S.Add(' float ds=broad?0.0:k*3.14159265*sin(6.2831853*along)/len;p+=(s-1.0)*radial;');
    S.Add(' vec3 grad=axis*ds+envelopeGradient*(responseScale*belly*belly);');
    S.Add(' vec3 base=n/s+axis*(dot(n,axis)*(1.0-1.0/s));');
    S.Add(' vec3 dual=grad/s+axis*(dot(grad,axis)*(1.0-1.0/s));float det=1.0+dot(radial,dual);');
    S.Add(' if(abs(det)>1e-4)n=normalize(base-dual*(dot(radial,base)/det));}');
    S.Add('vec3 bodySeatPush(vec3 p){if(uBodyDynamics[3].w<.5||uBodyDynamics[3].z<.5||riderTissue.y<.0001||!bodyBroadMuscle(int(riderTissue.x+.5)))return vec3(0);');
    S.Add(' vec4 v=vec4(p,1);vec3 seat=vec3(dot(uBodyDynamics[4],v),dot(uBodyDynamics[5],v),dot(uBodyDynamics[6],v));');
    S.Add(' float footprint=1.0-smoothstep(.65,1.0,dot(seat.xz/vec2(.14,.078),seat.xz/vec2(.14,.078)));');
    S.Add(' float depth=max(0.0,-seat.y),limit=min(.018,max(uBodyDynamics[3].x,uBodyDynamics[3].y)+.002);');
    S.Add(' return uBodyDynamics[7].xyz*(limit*(1.0-exp(-depth/max(limit,.001)))*footprint); }');
    S.Add('vec3 bodySoftPush(vec3 p){vec3 push=bodySeatPush(p);float w=riderTissue.z;if(abs(w)<.0001)return push;');
    S.Add(' float soft=clamp(.45+.22*uBodyProfile.x-.12*uBodyProfile.y,.25,.8);');
    S.Add(' if(w<0.0){mat4 m=bodyJoint('+IntToStr(FInfo.Get('bellyJoint',0))+');');
    S.Add(' vec3 c='+JsonVec('bellyCentre')+'+vec3(0.0,0.0,.035*uBodyProfile.x);vec3 r='+JsonVec('bellyRadii')+';r*=vec3(1.0+.35*uBodyProfile.x,1.0,1.0+.65*uBodyProfile.x);');
    S.Add(' vec3 local=transpose(mat3(m))*(p-m[3].xyz)-c;float d=length(local/r);if(d<1.0){vec3 grad=mat3(m)*(local/(r*r));float gl=max(length(grad),.0001);float depth=max(0.0,(1.0-d)/gl-riderContactRest.x);float limit=.006*(1.0-soft);push+=grad/gl*(depth/(1.0+depth/max(limit,.001)))*(-w);}');
    S.Add(' }else{');
    A:=ArrOf(FInfo,'thighs');
    for I:=0 to A.Count-1 do begin
      S.Add('{vec3 a=(bodyJoint('+IntToStr(A.Arrays[I].Integers[0])+')*vec4('+Pivot(A.Arrays[I].Integers[0])+',1.0)).xyz;');
      S.Add('vec3 b=(bodyJoint('+IntToStr(A.Arrays[I].Integers[1])+')*vec4('+Pivot(A.Arrays[I].Integers[1])+',1.0)).xyz;');
      S.Add('vec3 ab=b-a;float t=clamp(dot(p-a,ab)/max(dot(ab,ab),.0001),.12,.90);vec3 d=p-(a+t*ab);float l=length(d);float radius='+Num(FInfo.Get('thighRadius',0.07))+'*(1.0+.28*uBodyProfile.x+.24*uBodyProfile.y);float penetration=max(0.0,radius-l-riderContactRest['+IntToStr(I)+']);float limit=.010*soft;push+=d/max(l,.0001)*(penetration/(1.0+penetration/max(limit,.001)))*w;}');
    end;
    S.Add('}return push;}');
    S.Add('void bodyDeform(vec3 p,vec3 n,vec4 w,ivec4 j,out vec3 resultP,out vec3 resultN){');
    S.Add(' if(riderCentre.w<.00001){mat4 m=mat4(0.0);for(int i=0;i<4;i++)if(w[i]>0.0)m+=w[i]*bodyJoint(j[i]);resultP=(m*vec4(p,1.0)).xyz;resultN=normalize(mat3(m)*n);skinMatrix=m;return;}');
    S.Add(' mat4 m=mat4(0.0);vec4 q=vec4(0.0),ref=vec4(0.0);float total=dot(w,vec4(1.0));w/=max(total,.000001);');
    S.Add('#ifdef BODY_NORMAL_GRADIENTS');
    S.Add(' vec4 wu=vec4(riderGradient0.xyz,-dot(riderGradient0.xyz,vec3(1.0)));');
    S.Add(' vec3 gv=vec3(riderGradient0.w,riderGradient1.xy);vec4 wv=vec4(gv,-dot(gv,vec3(1.0)));');
    S.Add(' wu*=step(vec4(1e-8),w);wv*=step(vec4(1e-8),w);wu-=w*dot(wu,vec4(1));wv-=w*dot(wv,vec4(1));');
    S.Add(' vec3 pu=vec3(0),pv=vec3(0),gradientPoint=mix(p,riderCentre.xyz,riderCentre.w);vec4 qu=vec4(0.0),qv=vec4(0.0);');
    S.Add('#endif');
    S.Add(' int dominant=0;for(int i=1;i<4;i++)if(w[i]>w[dominant])dominant=i;');
    S.Add(' mat4 dominantMatrix=bodyJoint(j[dominant]);ref=bodyQuat(mat3(dominantMatrix));');
    S.Add(' for(int i=0;i<4;i++)if(w[i]>0.0){mat4 b=i==dominant?dominantMatrix:bodyJoint(j[i]);m+=w[i]*b;vec4 qi=i==dominant?ref:bodyQuat(mat3(b));if(dot(qi,ref)<0.0)qi=-qi;q+=qi*w[i];');
    S.Add('#ifdef BODY_NORMAL_GRADIENTS');
    S.Add(' vec3 point=(b*vec4(gradientPoint,1)).xyz;pu+=point*wu[i];pv+=point*wv[i];qu+=qi*wu[i];qv+=qi*wv[i];');
    S.Add('#endif');
    S.Add('}float qlen=max(length(q),1e-6);q/=qlen;');
    S.Add('#ifdef BODY_NORMAL_GRADIENTS');
    S.Add(' qu=(qu-q*dot(q,qu))/qlen;qv=(qv-q*dot(q,qv))/qlen;');
    S.Add('#endif');
    S.Add(' vec3 centre=riderCentre.xyz;float blend=riderCentre.w;vec3 linear=(m*vec4(p,1.0)).xyz;');
    S.Add(' resultP=mix(linear,bodyRotate(q,p-centre)+(m*vec4(centre,1.0)).xyz,blend);');
    S.Add(' resultN=normalize(mix(mat3(m)*n,bodyRotate(q,n),blend));');
    S.Add(' vec3 envelopeGradient=vec3(0.0);');
    { Differentiate the same CoR map used for positions. No extra IK calls or
      animated CPU mesh traversal; all matrices above are reused. }
    S.Add('#if defined(BODY_NORMAL_GRADIENTS) && (!defined(CASTLE_SHADOW_DEPTH) || defined(CASTLE_CACHE_DEFORMATION))');
    S.Add(' vec3 baseN=normalize(castle_Normal);vec3 t=normalize(cross(baseN,abs(baseN.y)<.9?vec3(0,1,0):vec3(1,0,0))),v=cross(baseN,t);');
    S.Add(' vec3 cu=vec3(riderGradient1.zw,riderGradient2.x),cv=riderGradient2.yzw;');
    S.Add(' vec3 tu=bodyRotate(q,t)+bodyRotateDerivative(q,qu,p-centre)+mat3(m)*cu-bodyRotate(q,cu);');
    S.Add(' vec3 tv=bodyRotate(q,v)+bodyRotateDerivative(q,qv,p-centre)+mat3(m)*cv-bodyRotate(q,cv);');
    S.Add(' tu=mix(mat3(m)*t,tu,blend)+pu;tv=mix(mat3(m)*v,tv,blend)+pv;');
    S.Add(' vec3 areaNormal=cross(tu,tv);float areaLength=length(areaNormal);');
    S.Add(' if(areaLength>1e-5){vec3 ng=areaNormal/areaLength;vec3 original=normalize(mix(mat3(m)*baseN,bodyRotate(q,baseN),blend));');
    S.Add(' if(dot(ng,original)>.05){vec3 delta=resultN-original;resultN=normalize(ng+delta);}}');
    S.Add(' vec3 dualU=cross(tv,resultN),dualV=cross(resultN,tu);float surfaceDet=dot(tu,dualU);');
    S.Add(' if(abs(surfaceDet)>1e-5)envelopeGradient=(dualU*riderContactRest.z+dualV*riderContactRest.w)/surfaceDet;');
    S.Add('#endif');
    S.Add(' mat3 frame=mat3(m)*(1.0-blend)+mat3(bodyRotate(q,vec3(1,0,0)),bodyRotate(q,vec3(0,1,0)),bodyRotate(q,vec3(0,0,1)))*blend;skinMatrix=mat4(frame);skinMatrix[3]=vec4(resultP-frame*p,1.0);');
    S.Add(' bodyMuscleDeform(resultP,resultN,envelopeGradient);');
    { Contact normal follows the same position function (central differences
      on the tangent plane); no separately sculpted normal correction. }
    S.Add(' if(abs(riderTissue.z)>.0001||(uBodyDynamics[3].w>.5&&bodyBroadMuscle(int(riderTissue.x+.5)))){vec3 push=bodySoftPush(resultP);if(dot(push,push)>1e-16){vec3 t=normalize(cross(resultN,abs(resultN.y)<.9?vec3(0,1,0):vec3(1,0,0)));vec3 b=cross(resultN,t);float e=.0005;');
    S.Add(' vec3 dt=t+(bodySoftPush(resultP+t*e)-bodySoftPush(resultP-t*e))/(2.0*e);vec3 db=b+(bodySoftPush(resultP+b*e)-bodySoftPush(resultP-b*e))/(2.0*e);resultN=normalize(cross(dt,db));resultP+=push;}}');
    S.Add('}');
    Result:=S.Text;
  finally S.Free end;
end;
end.
