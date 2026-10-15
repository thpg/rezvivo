unit GameRiderTraffic;
{$mode objfpc}{$H+}
interface
uses GamePhysicsCommon, GamePhysicalAgent, GamePath;
function RegisterTrafficAgent(Manager: TLaneManager; Agent: TPhysicalAgent): TLaneRiderHandle;
procedure PlaceTrafficAgent(Manager: TLaneManager; Agent: TPhysicalAgent);
procedure PlaceTrafficStartSlot(Manager:TLaneManager;Agent:TPhysicalAgent;Slot:Integer);
{ A negative route distance is not necessarily physically behind the rider:
  the loop seam may double back or cross the outgoing branch. Check the
  starting corridor once per spawn, without querying scene geometry. }
function FindCompanionStartBehind(Path:TGamePath;const Start:TPathPosition;
  MaxBehind:Single;out Position:TPathPosition;out Behind:Single):Boolean;
procedure UpdateRiderTraffic(Manager: TLaneManager; Dt: Single);
implementation
uses Math, CastleVectors;

function FindCompanionStartBehind(Path:TGamePath;const Start:TPathPosition;
  MaxBehind:Single;out Position:TPathPosition;out Behind:Single):Boolean;
var Candidate,A,B,V,D:TVector3;Cursor,Next:TPathPosition;
    Step:Integer;T:Single;Clear:Boolean;
begin
  Result:=False;Position:=Start;Behind:=4;
  if (Path=nil)or(Path.PointCount<2)then Exit;
  { The front 12 m must remain free for acceleration and steering. Sampling
    every 1 m with a 2.8 m clearance is conservative even at sharp bends. }
  while Behind<=Min(24,MaxBehind)do begin
    Position:=Start;Path.AdvanceFollow(Position,-Behind);
    Candidate:=Path.RoadCenterAt(Position);Cursor:=Start;Clear:=True;
    for Step:=1 to 12 do begin
      Next:=Cursor;Path.AdvanceFollow(Next,1);
      A:=Path.RoadCenterAt(Cursor);B:=Path.RoadCenterAt(Next);
      V:=B-A;V.Y:=0;D:=Candidate-A;D.Y:=0;
      T:=0;if V.LengthSqr>1e-8 then T:=EnsureRange(TVector3.DotProduct(D,V)/V.LengthSqr,0,1);
      if (D-V*T).LengthSqr<Sqr(2.8)then begin Clear:=False;Break end;
      Cursor:=Next;
    end;
    if Clear then Exit(True);
    Behind:=Behind+4;
  end;
end;

procedure BindTrafficConstraints(Manager:TLaneManager;Agent:TPhysicalAgent);
begin
  Agent.State.LaneOffsetExternal:=True;
  Agent.State.TrafficTag:=Agent;
  Agent.State.TrafficMoveConstraint:=@Manager.ConstrainMovement;
  Agent.State.TrafficHeadingConstraint:=@Manager.ConstrainHeading;
end;

procedure ClearTrafficConstraints(Agent:TPhysicalAgent);
begin
  Agent.State.LaneOffsetExternal:=False;
  Agent.State.TrafficMoveConstraint:=nil;
  Agent.State.TrafficHeadingConstraint:=nil;
  Agent.State.TrafficSpeedLimit:=MaxSpeed;
end;

procedure PlaceTrafficStartSlot(Manager:TLaneManager;Agent:TPhysicalAgent;Slot:Integer);
var P:TPathPosition;
begin
  if(Manager=nil)or(Agent=nil)or(Agent.Path.PointCount<2)then Exit;
  if Agent.State.FreeTravel then begin RegisterTrafficAgent(Manager,Agent);Exit end;
  if(Slot>0)and(Slot<8)and(Agent.State.CumulativeDistance<0.1)then begin
    P:=Agent.Path.Position;Agent.Path.AdvanceFollow(P,Slot*3.0);Agent.TeleportToPath(P);
    Agent.State.CumulativeDistance:=Slot*3.0;
  end;
  PlaceTrafficAgent(Manager,Agent);
end;

function RegisterTrafficAgent(Manager: TLaneManager; Agent: TPhysicalAgent): TLaneRiderHandle;
begin
  Result := -1;
  if (Manager=nil) or (Agent=nil) then Exit;
  Result := Manager.FindRider(Agent);
  if Result<0 then Result:=Manager.RegisterRider(Agent);
  if Agent.State.FreeTravel then begin
    Manager.InvalidateRiderPose(Result);ClearTrafficConstraints(Agent);
  end else BindTrafficConstraints(Manager,Agent);
  Agent.State.TrafficSpeedLimit:=MaxSpeed;
end;

procedure PlaceTrafficAgent(Manager: TLaneManager; Agent: TPhysicalAgent);
var H, Row: Integer; P, Start: TPathPosition; Center, Dir, Right: TVector3;
    Offset, Advance, Width: Single; Found: Boolean;
begin
  if (Manager=nil) or (Agent=nil) or (Agent.Path.PointCount<2) then Exit;
  if Agent.State.FreeTravel then begin RegisterTrafficAgent(Manager,Agent);Exit end;
  H:=RegisterTrafficAgent(Manager,Agent);
  Manager.InvalidateRiderPose(H);
  Start:=Agent.Path.Position; Advance:=0; Found:=False;
  for Row:=0 to Manager.RiderCount do begin
    P:=Start; Agent.Path.AdvanceFollow(P,Advance);
    Center:=Agent.Path.RoadCenterAt(P); Dir:=Agent.Path.FollowDirectionXZ(P);
    Center.Y:=Agent.State.LastGroundY; { preserve the resolved start ground, not raw FIT elevation }
    Width:=Agent.Path.RoadWidthAt(P);
    if Manager.ReservePlacement(H,Center,Dir,Width,Offset) then begin Found:=True;Break end;
    Advance:=Advance+2.5;
  end;
  if not Found then Exit;
  Agent.TeleportToPath(P);
  Right:=Vector3(-Dir.Z,0,Dir.X);
  Agent.State.WorldPosition:=Center+Right*Offset;
  Agent.State.PrevWorldPosition:=Agent.State.WorldPosition;
  Agent.State.LaneOffset:=Offset;
  Agent.State.CumulativeDistance:=Agent.State.CumulativeDistance+Advance;
  if Agent.Actor.Transform<>nil then Agent.Actor.Transform.Translation:=Agent.State.WorldPosition;
  if Agent.Physics<>nil then Agent.Physics.UpdateVisualGroundPlacement(0);
  Manager.SetRiderPose(H,Agent.State.WorldPosition,Dir,Width,Offset,Agent.State.CurrentSpeed);
end;

procedure UpdateRiderTraffic(Manager: TLaneManager; Dt: Single);
var I: Integer; A: TPhysicalAgent; Center, Dir, Right: TVector3; Width: Single;
    Passage:TPathNarrowPassage;
begin
  if Manager=nil then Exit;
  for I:=0 to Manager.RiderCount-1 do begin
    A:=TPhysicalAgent(Manager.RiderTag(I));
    if (A=nil) or (A.Path.PointCount<2) then Continue;
    if A.State.FreeTravel then begin
      Manager.InvalidateRiderPose(I);ClearTrafficConstraints(A);Continue;
    end;
    Center:=A.Path.RoadCenterAt(A.Path.Position); Dir:=A.Path.FollowDirectionXZ(A.Path.Position);
    Right:=Vector3(-Dir.Z,0,Dir.X); Width:=A.Path.RoadWidthAt(A.Path.Position);
    Manager.SetRiderPose(I,A.State.WorldPosition,Dir,Width,
      TVector3.DotProduct(A.State.WorldPosition-Center,Right),A.State.CurrentSpeed);
    Manager.SetRiderHeading(I,A.State.ForwardDir);
    if A.Path.NarrowPassageAt(A.Path.Position,Max(60,Sqr(A.State.CurrentSpeed)/4+12),Passage)then
      Manager.SetNarrowPassage(I,Passage.Key,Passage.Forward,Passage.Inside,Passage.EntryDistance,Passage.Exclusive)
    else Manager.SetNarrowPassage(I,0,False,False,0);
  end;
  Manager.Update(Dt);
  for I:=0 to Manager.RiderCount-1 do begin
    A:=TPhysicalAgent(Manager.RiderTag(I));
    if (A=nil) or (A.Path.PointCount<2) then Continue;
    if A.State.FreeTravel then Continue;
    BindTrafficConstraints(Manager,A);
    A.State.LaneOffset:=Manager.GetSmoothOffset(I,A.Path.RoadWidthAt(A.Path.Position));
    A.State.TrafficSpeedLimit:=Manager.TrafficLimit(I);
  end;
end;
end.
