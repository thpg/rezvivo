unit RiderGarmentSupport;
{$mode objfpc}{$H+}
{ Reduced material support: sixteen surface anchors, using the body's CoR
  skinning map. No animated mesh walk, raycasts, solver iterations or clocks. }
interface
uses Math,CastleVectors,TripoRig,RiderPosePreparation;
type
  { Three vertical bands x four sewn sides. Longitudinal stretch, transverse
    stretch, then in-plane shear in an orthonormal REST material frame. }
  TGarmentPanelStretch=array[0..8]of TVector4;
  TGarmentStrainEvent=procedure(const Value:TGarmentPanelStretch)of object;
  TGarmentJointResolver=function(Index:Integer):TMatrix4 of object;
  TRiderGarmentSupport=class
  private
    type TAnchor=record
      P,C:TVector3;Blend:Single;J:array[0..3]of Integer;W:array[0..3]of Single;
      Score:Single;
    end;
    var A:array[0..15]of TAnchor;RestU,RestV:array[0..11]of TVector3;
      Palette:TMatrix4List;Rotations:TVector4List;Used:array of Integer;Ready:Boolean;
    procedure PrepareRotations(const Joints:TMatrix4List);
    function Point(Index:Integer;const Joints:TMatrix4List):TVector3;
  public
    constructor Create;
    destructor Destroy;override;
    procedure BeginBind;
    procedure Consider(const Rig:TTripoRig;Index:Integer;const Canonical:TVector3;const Centre:TVector4);
    procedure EndBind(const Rig:TTripoRig);
    function Evaluate(const Joints:TMatrix4List):TGarmentPanelStretch;
    function EvaluateNative(const Rig:TTripoRig):TGarmentPanelStretch;
    function EvaluateResolved(const Resolve:TGarmentJointResolver):TGarmentPanelStretch;
  end;
function GarmentSurfaceStrain(const RestU,RestV,U,V:TVector3):TVector3;
function RelaxedGarmentStretch:TGarmentPanelStretch;
implementation
const Y:array[0..3]of Single=(1.035,1.155,1.285,1.405);
  X:array[0..3]of Single=(0,0.16,0,-0.16);
  Z:array[0..3]of Single=(0.105,-0.025,-0.13,-0.025);
function RelaxedGarmentStretch:TGarmentPanelStretch;
var I:Integer;
begin
  for I:=0 to 5 do Result[I]:=Vector4(1,1,1,1);
  for I:=6 to 8 do Result[I]:=Vector4(0,0,0,0);
end;
function GarmentSurfaceStrain(const RestU,RestV,U,V:TVector3):TVector3;
var E,F,G,Height:Single;DU,DV:TVector3;
begin
  E:=RestU.LengthSqr;F:=TVector3.DotProduct(RestU,RestV);G:=RestV.LengthSqr;
  Height:=G-F*F/Max(E,1e-12);
  if(E<1e-10)or(Height<1e-10)then Exit(Vector3(1,1,0));
  DU:=U/Sqrt(E);DV:=(V-U*(F/E))/Sqrt(Height);
  Result:=Vector3(EnsureRange(DV.Length,0.55,1.45),
    EnsureRange(DU.Length,0.55,1.45),EnsureRange(TVector3.DotProduct(DU,DV),-0.65,0.65));
end;
procedure PanelBasis(const P:array of TVector3;I,K:Integer;out U,V:TVector3);
var Left,Right:Integer;
begin
  Left:=(K+3)mod 4;Right:=(K+1)mod 4;
  U:=(P[I*4+Right]-P[I*4+Left]+P[(I+1)*4+Right]-P[(I+1)*4+Left])*0.25;
  V:=P[(I+1)*4+K]-P[I*4+K];
end;
constructor TRiderGarmentSupport.Create;
begin inherited;Palette:=TMatrix4List.Create;Rotations:=TVector4List.Create;BeginBind end;
destructor TRiderGarmentSupport.Destroy;
begin Rotations.Free;Palette.Free;inherited end;
procedure TRiderGarmentSupport.BeginBind;
var I:Integer;
begin Ready:=False;SetLength(Used,0);for I:=0 to 15 do A[I].Score:=1e20 end;
procedure TRiderGarmentSupport.Consider(const Rig:TTripoRig;Index:Integer;
  const Canonical:TVector3;const Centre:TVector4);
var I,K:Integer;D:Single;
begin
  if(Canonical.Y<1.0)or(Canonical.Y>1.45)or(Abs(Canonical.X)>0.205)then Exit;
  for I:=0 to 15 do begin
    D:=Sqr(Canonical.X-X[I mod 4])+Sqr(Canonical.Z-Z[I mod 4])+2*Sqr(Canonical.Y-Y[I div 4]);
    if D>=A[I].Score then Continue;
    A[I].Score:=D;A[I].P:=Vector3(Rig.Positions[Index].X,Rig.Positions[Index].Y,Rig.Positions[Index].Z);
    A[I].C:=Vector3(Centre.X,Centre.Y,Centre.Z);A[I].Blend:=Centre.W;
    for K:=0 to 3 do begin A[I].J[K]:=Rig.Joints[Index][K];A[I].W[K]:=Rig.Weights[Index][K]end;
  end;
end;
procedure TRiderGarmentSupport.PrepareRotations(const Joints:TMatrix4List);
var I,J:Integer;
begin
  for I:=0 to High(Used)do begin J:=Used[I];Rotations[J]:=RiderPoseQuaternion(Joints[J]) end;
end;
function TRiderGarmentSupport.Point(Index:Integer;const Joints:TMatrix4List):TVector3;
var I,D:Integer;M:TMatrix4;Q,Ref,QI,H:TVector4;V,Axis,Linear,Centre:TVector3;L:Single;
begin
  D:=0;for I:=1 to 3 do if A[Index].W[I]>A[Index].W[D]then D:=I;
  Ref:=Rotations[A[Index].J[D]];Q:=Vector4(0,0,0,0);
  Linear:=TVector3.Zero;Centre:=TVector3.Zero;
  for I:=0 to 3 do if A[Index].W[I]>0 then begin
    M:=Joints[A[Index].J[I]];
    H:=M*Vector4(A[Index].P.X,A[Index].P.Y,A[Index].P.Z,1);
    Linear+=Vector3(H.X,H.Y,H.Z)*A[Index].W[I];
    H:=M*Vector4(A[Index].C.X,A[Index].C.Y,A[Index].C.Z,1);
    Centre+=Vector3(H.X,H.Y,H.Z)*A[Index].W[I];
    QI:=Rotations[A[Index].J[I]];if TVector4.DotProduct(QI,Ref)<0 then QI:=-QI;
    Q+=QI*A[Index].W[I];
  end;
  L:=Sqrt(TVector4.DotProduct(Q,Q));if L<1e-8 then Exit(Linear);Q:=Q*(1/L);
  V:=A[Index].P-A[Index].C;Axis:=Vector3(Q.X,Q.Y,Q.Z);
  V+=TVector3.CrossProduct(Axis,TVector3.CrossProduct(Axis,V)+V*Q.W)*2;
  Result:=Linear*(1-A[Index].Blend)+(V+Centre)*A[Index].Blend;
end;
procedure TRiderGarmentSupport.EndBind(const Rig:TTripoRig);
var I,K,J,N:Integer;Found:Boolean;M:TTripoMat4;T:TMatrix4;P:array[0..15]of TVector3;
begin
  Ready:=False;
  for I:=0 to 15 do if A[I].Score>0.015 then Exit;
  SetLength(Used,0);
  for I:=0 to 15 do for K:=0 to 3 do if A[I].W[K]>0 then begin
    Found:=False;for J:=0 to High(Used)do if Used[J]=A[I].J[K]then Found:=True;
    if not Found then begin N:=Length(Used);SetLength(Used,N+1);Used[N]:=A[I].J[K]end;
  end;
  Rotations.Count:=Rig.JointCount;
  Palette.Clear;
  for I:=0 to Rig.JointCount-1 do begin
    M:=Mat4Mul(Rig.BindWorld[I],Rig.NativeInvBind[I]);Move(M,T,SizeOf(T));Palette.Add(T);
  end;
  PrepareRotations(Palette);
  for I:=0 to 15 do P[I]:=Point(I,Palette);
  for I:=0 to 2 do for K:=0 to 3 do PanelBasis(P,I,K,RestU[I*4+K],RestV[I*4+K]);
  Ready:=True;
end;
function TRiderGarmentSupport.Evaluate(const Joints:TMatrix4List):TGarmentPanelStretch;
var I,K:Integer;P:array[0..15]of TVector3;U,V,S:TVector3;
begin
  Result:=RelaxedGarmentStretch;
  if not Ready then Exit;
  PrepareRotations(Joints);
  for I:=0 to 15 do P[I]:=Point(I,Joints);
  for I:=0 to 2 do for K:=0 to 3 do begin
    PanelBasis(P,I,K,U,V);S:=GarmentSurfaceStrain(RestU[I*4+K],RestV[I*4+K],U,V);
    Result[I].Data[K]:=S.X;Result[I+3].Data[K]:=S.Y;Result[I+6].Data[K]:=S.Z;
  end;
end;
function TRiderGarmentSupport.EvaluateNative(const Rig:TTripoRig):TGarmentPanelStretch;
var I,J:Integer;M:TTripoMat4;T:TMatrix4;
begin
  for I:=0 to High(Used)do begin
    J:=Used[I];M:=Mat4Mul(Rig.WorldPose[J],Rig.NativeInvBind[J]);Move(M,T,SizeOf(T));
    Palette[J]:=T;
  end;
  Result:=Evaluate(Palette);
end;
function TRiderGarmentSupport.EvaluateResolved(const Resolve:TGarmentJointResolver):TGarmentPanelStretch;
var I,J:Integer;
begin
  { Only the joints used by sixteen cloth anchors. The normal GPU route keeps
    its compact pose palette; it does not need a second full pose solve. }
  for I:=0 to High(Used)do begin J:=Used[I];Palette[J]:=Resolve(J)end;
  Result:=Evaluate(Palette);
end;
end.
