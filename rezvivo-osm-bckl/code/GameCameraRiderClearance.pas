unit GameCameraRiderClearance;
{$mode objfpc}{$H+}
interface
uses CastleVectors, GameCameraEncounters;
{ Lens and near plane against a conservative moving rider envelope. This is
  CPU geometry, independent of render meshes, pose LOD and GPU readbacks. }
function CameraCrossesRider(const A,B:TVector3;const Rider:TCameraRider;
  Dt:Single):Boolean;
implementation
uses Math;
function CameraCrossesRider(const A,B:TVector3;const Rider:TCameraRider;
  Dt:Single):Boolean;
var F,R,V0,V1,Step:TVector3;Lo,Hi,T0,T1,X,D,H:Single;I:Integer;
begin
  F:=Rider.Direction;F.Y:=0;
  if F.LengthSqr<0.001 then F:=Vector3(0,0,1)else F:=F.Normalize;
  R:=Vector3(-F.Z,0,F.X);
  V0:=A-Rider.Position+F*(Rider.Speed*Max(0,Dt));
  V1:=B-Rider.Position;
  V0:=Vector3(TVector3.DotProduct(V0,R),V0.Y-1.05,TVector3.DotProduct(V0,F));
  V1:=Vector3(TVector3.DotProduct(V1,R),V1.Y-1.05,TVector3.DotProduct(V1,F));
  Step:=V1-V0;Lo:=0;Hi:=1;
  for I:=0 to 2 do begin
    H:=0.7;if I=1 then H:=1.3;
    if I=2 then begin H:=1.25;if Rider.OnFoot then H:=0.7 end;
    X:=V0[I];D:=Step[I];
    if Abs(D)<1e-6 then begin if Abs(X)>H then Exit(False) end
    else begin
      T0:=(-H-X)/D;T1:=(H-X)/D;
      Lo:=Max(Lo,Min(T0,T1));Hi:=Min(Hi,Max(T0,T1));
      if Lo>Hi then Exit(False);
    end;
  end;
  Result:=True;
end;
end.
