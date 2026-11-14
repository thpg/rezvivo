unit GamePedestrianTraffic;
{$mode objfpc}{$H+}
interface
uses CastleVectors, GamePhysicsCommon;
const PedestrianShoulderExtra=1.0;
function PedestrianEdge(Width:Single):Single;
{ Predict from the normal edge line, not the already yielding position. This
  prevents returning into a cyclist as soon as the avoidance starts working. }
function PedestrianConflict(const Position,Direction:TVector3;Speed:Single;
  const PeerPosition,PeerDirection:TVector3;PeerSpeed:Single):Boolean;
function ProbePedestrianShoulder(State:TPhysicsState;const Center,Forward:TVector3;
  Width:Single;out Ready:Boolean):Boolean;
implementation
uses Math;
function PedestrianEdge(Width:Single):Single;
begin Result:=Max(0,Width*0.5-0.36) end;
function PedestrianConflict(const Position,Direction:TVector3;Speed:Single;
  const PeerPosition,PeerDirection:TVector3;PeerSpeed:Single):Boolean;
var D,V,Closest:TVector3;T:Single;
begin
  Result:=False;D:=PeerPosition-Position;
  if(Abs(D.Y)>1.4)or(D.LengthSqr>Sqr(65))then Exit;
  D.Y:=0;V:=PeerDirection*PeerSpeed-Direction*Speed;V.Y:=0;
  if V.LengthSqr<0.04 then Exit(D.LengthSqr<Sqr(1.6));
  T:=-TVector3.DotProduct(D,V)/V.LengthSqr;
  if(T< -0.15)or(T>5)then Exit;
  Closest:=D+V*Max(0,T);
  Result:=Closest.LengthSqr<Sqr(1.5);
end;
function ProbePedestrianShoulder(State:TPhysicsState;const Center,Forward:TVector3;
  Width:Single;out Ready:Boolean):Boolean;
var K:Integer;P,Q,SafeP:TVector3;RoadY,ShoulderY:Single;
begin
  Result:=True;Ready:=True;
  if(State=nil)or not Assigned(State.GroundQuery)then begin Ready:=False;Exit end;
  for K:=0 to 2 do begin
    P:=Center+Forward*(K*3);
    Q:=P+Vector3(-Forward.Z,0,Forward.X)*(PedestrianEdge(Width)+PedestrianShoulderExtra);
    if not State.GroundQuery(P.X,P.Z,P.Y,RoadY)then begin Ready:=False;Continue end;
    if not State.GroundQuery(Q.X,Q.Z,RoadY,ShoulderY)then begin Ready:=False;Continue end;
    if Abs(ShoulderY-RoadY)>0.32 then Exit(False);
    P.Y:=RoadY;Q.Y:=ShoulderY;SafeP:=Q;
    if State.ConstrainBodyMove(P,SafeP)then Exit(False);
  end;
end;
end.
