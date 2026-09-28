unit GameRiderTraffic;
{$mode objfpc}{$H+}
interface
uses GamePhysicsCommon, GamePhysicalAgent;
function RegisterTrafficAgent(Manager: TLaneManager; Agent: TPhysicalAgent): TLaneRiderHandle;
procedure PlaceTrafficAgent(Manager: TLaneManager; Agent: TPhysicalAgent);
procedure PlaceTrafficStartSlot(Manager:TLaneManager;Agent:TPhysicalAgent;Slot:Integer);
procedure UpdateRiderTraffic(Manager: TLaneManager; Dt: Single);
implementation
uses Math, CastleVectors, GamePath;

procedure PlaceTrafficStartSlot(Manager:TLaneManager;Agent:TPhysicalAgent;Slot:Integer);
var P:TPathPosition;
begin
  if(Manager=nil)or(Agent=nil)or(Agent.Path.PointCount<2)then Exit;
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
  Agent.State.LaneOffsetExternal:=True;
  Agent.State.TrafficTag:=Agent;
  Agent.State.TrafficMoveConstraint:=@Manager.ConstrainMovement;
  Agent.State.TrafficHeadingConstraint:=@Manager.ConstrainHeading;
  Agent.State.TrafficSpeedLimit:=MaxSpeed;
end;

procedure PlaceTrafficAgent(Manager: TLaneManager; Agent: TPhysicalAgent);
var H, Row: Integer; P, Start: TPathPosition; Center, Dir, Right: TVector3;
    Offset, Advance, Width: Single; Found: Boolean;
begin
  if (Manager=nil) or (Agent=nil) or (Agent.Path.PointCount<2) then Exit;
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
    A.State.LaneOffsetExternal:=True;
    A.State.LaneOffset:=Manager.GetSmoothOffset(I,A.Path.RoadWidthAt(A.Path.Position));
    A.State.TrafficSpeedLimit:=Manager.TrafficLimit(I);
  end;
end;
end.
