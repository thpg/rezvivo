unit GameObstacleSteering;
{$mode objfpc}{$H+}
interface
uses CastleVectors;
type
  TObstacleMoveQuery=function(const From,Forward,HalfSize:TVector3;
    var Target:TVector3):Boolean of object;
  TObstacleSteeringState=record
    QueryIn,HoldSide,Clearance:Single;
    LastPosition,LastDirection,Normal,Tangent:TVector3;
    Active:Boolean;
  end;

{ Anticipatory control only. The ordinary swept body collision remains the
  final authority for every displacement. Queries use the existing footprint
  grid, never rendered geometry or a GPU readback. }
procedure SteerAroundBuildings(var State:TObstacleSteeringState;
  Query:TObstacleMoveQuery;const Position,Forward,HalfSize:TVector3;
  Dt,Speed,MaximumTurn:Single;var Turn:Single;out SpeedLimit:Single);
implementation
uses Math;

procedure SteerAroundBuildings(var State:TObstacleSteeringState;
  Query:TObstacleMoveQuery;const Position,Forward,HalfSize:TVector3;
  Dt,Speed,MaximumTurn:Single;var Turn:Single;out SpeedLimit:Single);
var MoveDir,Size,Target,Blocked,Tangent,Other,Probe:TVector3;
  V,Look,NormalDistance,IntoWall,AlongWall,Angle,Choice,ClearA,ClearB:Single;
begin
  SpeedLimit:=100;
  if not Assigned(Query)then begin State:=Default(TObstacleSteeringState);Exit end;
  V:=Abs(Speed);MoveDir:=Forward;if Speed<0 then MoveDir:=-MoveDir;
  if V<0.05 then Exit; { no unsolicited turning or queries while standing }
  State.QueryIn:=State.QueryIn-Max(0,Dt);State.HoldSide:=Max(0,State.HoldSide-Dt);
  { Re-evaluate immediately on teleport or a substantial deliberate turn. }
  if((Position-State.LastPosition).LengthSqr>4)or
    (TVector3.DotProduct(MoveDir,State.LastDirection)<0.97)then State.QueryIn:=0;
  if State.QueryIn<=0 then begin
    State.QueryIn:=0.12;State.LastPosition:=Position;State.LastDirection:=MoveDir;
    { At speed, a 90 degree avoidance arc needs v^2/a metres of room.
      Include the query interval and a small clearance for the rider's body. }
    Look:=EnsureRange(2+V*0.5+V*V/5,3,90);
    Size:=HalfSize+Vector3(0.04,0,0.08);
    Target:=Position+MoveDir*Look;Probe:=Target;
    if not Query(Position,MoveDir,Size,Probe)then State.Active:=False
    else begin
      Blocked:=Target-Probe;Blocked.Y:=0;
      if Blocked.Length<0.01 then State.Active:=False
      else begin
        State.Normal:=Blocked.Normalize;State.Active:=True;
        State.Clearance:=Max(0,TVector3.DotProduct(Probe-Position,State.Normal));
        Tangent:=Vector3(-State.Normal.Z,0,State.Normal.X);
        Choice:=TVector3.DotProduct(Tangent,MoveDir);
        { Keep a selected side near a head-on wall; otherwise take the
          tangent requiring the smaller turn. Explicit steering breaks ties. }
        if Abs(Choice)<0.25 then begin
          if(State.HoldSide>0)and(State.Tangent.LengthSqr>0.5)then begin
            if TVector3.DotProduct(Tangent,State.Tangent)<0 then Tangent:=-Tangent;
          end else if Abs(Turn)>0.05 then begin
            if(Tangent.X*MoveDir.Z-Tangent.Z*MoveDir.X)*Turn<0 then Tangent:=-Tangent;
          end else if Tangent.X*MoveDir.Z-Tangent.Z*MoveDir.X>0 then Tangent:=-Tangent;
        end else if Choice<0 then Tangent:=-Tangent;
        { Avoid choosing a tangent into the neighbouring facade / courtyard
          corner. Only obstacles trigger these two additional grid queries. }
        Other:=-Tangent;
        Target:=Position+Tangent*Min(12,Look);Probe:=Target;
        Query(Position,Tangent,Size,Probe);ClearA:=(Probe-Position).Length;
        Target:=Position+Other*Min(12,Look);Probe:=Target;
        Query(Position,Other,Size,Probe);ClearB:=(Probe-Position).Length;
        if(ClearA<Min(12,Look)*0.75)and(ClearB>ClearA+1)then Tangent:=Other;
        State.Tangent:=Tangent;State.HoldSide:=0.8;
      end;
    end;
  end;
  if not State.Active then Exit;
  IntoWall:=TVector3.DotProduct(MoveDir,State.Normal);
  if IntoWall<=0.02 then Exit;
  { A little outward bias leaves a gap instead of repeatedly grazing the
    wall. Rotate the actual bicycle, not its position or route station. }
  Tangent:=(State.Tangent-State.Normal*0.10).Normalize;
  Angle:=ArcTan2(Tangent.X*MoveDir.Z-Tangent.Z*MoveDir.X,
    TVector3.DotProduct(Tangent,MoveDir));
  Turn:=EnsureRange(Angle*2,-MaximumTurn,MaximumTurn);
  { Fresh sweep gives distance available for the turn. Between grid updates
    use the stored contact plane; no per-frame scene queries are necessary. }
  AlongWall:=Abs(TVector3.DotProduct(MoveDir,State.Tangent));
  NormalDistance:=State.Clearance+TVector3.DotProduct(State.LastPosition-Position,State.Normal);
  SpeedLimit:=Sqrt(5*Max(0.01,NormalDistance)/Max(0.08,1-AlongWall));
end;
end.
