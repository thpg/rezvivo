unit Osm3dBuildingContact;
{$mode objfpc}{$H+}
interface
uses CastleVectors;

const BuildingContactSkin = 0.005;

{ XZ oriented rectangle against a wall segment. Continuous SAT uses three
  axes, so wall crossings and corners cannot slip between sampled points. }
function SweepBuildingEdge(const Center, Move, Forward, A, B:TVector3;
  HalfWidth,HalfLength:Single; out Fraction:Double; out Normal:TVector3):Boolean;
function PushBuildingBox(const Center,Forward:TVector3; HalfWidth,HalfLength:Single;
  const Footprint:array of TVector3; out Correction:TVector3):Boolean;

implementation
uses Math, Osm3dGeoMath;

function SweepBuildingEdge(const Center, Move, Forward, A, B:TVector3;
  HalfWidth,HalfLength:Single; out Fraction:Double; out Normal:TVector3):Boolean;
var EnterT,ExitT,EX,EZ,Len:Double;
  function Clip(NX,NZ:Double):Boolean;
  var Lo,Hi,C,V,R,T0,T1,T,SignN:Double;
  begin
    Lo:=Double(A.X)*NX+Double(A.Z)*NZ;Hi:=Double(B.X)*NX+Double(B.Z)*NZ;
    if Lo>Hi then begin T:=Lo;Lo:=Hi;Hi:=T end;
    R:=Abs(NX*Forward.X+NZ*Forward.Z)*HalfLength+
      Abs(-NX*Forward.Z+NZ*Forward.X)*HalfWidth;
    C:=Double(Center.X)*NX+Double(Center.Z)*NZ;
    V:=Double(Move.X)*NX+Double(Move.Z)*NZ;
    if Abs(V)<1e-12 then Exit((C>=Lo-R)and(C<=Hi+R));
    T0:=(Lo-R-C)/V;T1:=(Hi+R-C)/V;SignN:=-1;
    if T0>T1 then begin T:=T0;T0:=T1;T1:=T;SignN:=1 end;
    if T0>EnterT then begin EnterT:=T0;Normal:=Vector3(NX*SignN,0,NZ*SignN) end;
    ExitT:=Min(ExitT,T1);
    Result:=EnterT<=ExitT;
  end;
begin
  Result:=False;Fraction:=1;Normal:=Vector3(0,0,0);
  EX:=Double(B.X)-A.X;EZ:=Double(B.Z)-A.Z;Len:=Sqrt(EX*EX+EZ*EZ);
  if Len<1e-8 then Exit;
  EnterT:=-1e30;ExitT:=1e30;
  if not Clip(Forward.X,Forward.Z) then Exit;
  if not Clip(-Forward.Z,Forward.X) then Exit;
  if not Clip(EZ/Len,-EX/Len) then Exit;
  if Move.LengthSqr<1e-16 then Exit(True);
  { A tangent or separating contact at t=0 must allow leaving the wall. }
  if (EnterT < -1e-7) or (ExitT<=1e-9) or (EnterT>1) then Exit;
  Fraction:=Max(0,EnterT);Result:=True;
end;

function PushBuildingBox(const Center,Forward:TVector3; HalfWidth,HalfLength:Single;
  const Footprint:array of TVector3; out Correction:TVector3):Boolean;
var I,J,BestI:Integer; Inside,Touches:Boolean; A,B,Q,BestQ,N:TVector3;
  EX,EZ,Len2,T,D2,Best,Area,Dist,R,Fraction,NX,NZ:Double;
begin
  Result:=False;Correction:=Vector3(0,0,0);
  if Length(Footprint)<3 then Exit;
  Inside:=PointInPolygonXZ(Center,Footprint);
  Best:=1e30;BestI:=-1;Area:=0;BestQ:=Center;
  for I:=0 to High(Footprint) do begin
    J:=(I+1) mod Length(Footprint);A:=Footprint[I];B:=Footprint[J];
    Area:=Area+(Double(A.X)-Footprint[0].X)*(Double(B.Z)-Footprint[0].Z)-
      (Double(B.X)-Footprint[0].X)*(Double(A.Z)-Footprint[0].Z);
    Touches:=Inside or SweepBuildingEdge(Center,Vector3(0,0,0),Forward,A,B,
      HalfWidth,HalfLength,Fraction,N);
    if not Touches then Continue;
    EX:=Double(B.X)-A.X;EZ:=Double(B.Z)-A.Z;Len2:=EX*EX+EZ*EZ;
    if Len2<1e-12 then Continue;
    T:=EnsureRange(((Double(Center.X)-A.X)*EX+(Double(Center.Z)-A.Z)*EZ)/Len2,0,1);
    Q:=Vector3(A.X+EX*T,0,A.Z+EZ*T);
    D2:=Sqr(Double(Center.X)-Q.X)+Sqr(Double(Center.Z)-Q.Z);
    if D2<Best then begin Best:=D2;BestQ:=Q;BestI:=I end;
  end;
  if BestI<0 then Exit;
  Dist:=Sqrt(Best);
  if Dist>1e-8 then begin
    NX:=(Double(Center.X)-BestQ.X)/Dist;NZ:=(Double(Center.Z)-BestQ.Z)/Dist;
    if Inside then begin NX:=-NX;NZ:=-NZ end;
  end else begin
    A:=Footprint[BestI];B:=Footprint[(BestI+1) mod Length(Footprint)];
    NX:=Double(B.Z)-A.Z;NZ:=Double(A.X)-B.X;
    if Area<0 then begin NX:=-NX;NZ:=-NZ end;
    Dist:=Sqrt(NX*NX+NZ*NZ);NX:=NX/Dist;NZ:=NZ/Dist;
  end;
  R:=Abs(NX*Forward.X+NZ*Forward.Z)*HalfLength+
    Abs(-NX*Forward.Z+NZ*Forward.X)*HalfWidth+BuildingContactSkin;
  Correction:=Vector3(BestQ.X+NX*R-Center.X,0,BestQ.Z+NZ*R-Center.Z);
  Result:=Correction.LengthSqr>1e-12;
end;
end.
