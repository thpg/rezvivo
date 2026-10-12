unit GameBotRouteExcursion;
{$mode objfpc}{$H+}

{ Route stations include both branches of an out-and-back. Interception is
  resolved once to cumulative distance, so passing the stop cannot turn it
  into a new lap. These records are also the complete replay state. }
interface
uses CastleVectors, GameBotCompanyMotion;
type
  TBotExcursionTarget = record
    Active: Boolean;
    Station, RequestedStation, Clock: Double;
    Point, RequestedPoint: TVector3;
    Revision: Cardinal;
  end;
  TBotExcursionWait = record
    HasTarget, Waiting: Boolean;
    Revision: Cardinal;
    StopDistance: Double;
  end;

procedure RequestBotExcursion(var Target:TBotExcursionTarget; Active:Boolean;
  Station:Double; const Point:TVector3);
procedure StepBotExcursionTarget(var Target:TBotExcursionTarget; Dt:Single);
function StepBotExcursionWait(var State:TBotExcursionWait;
  const Target:TBotExcursionTarget; BotStation,RouteLength:Double;
  const Input:TBotWaitInput; Dt:Single):TBotWaitControl;

implementation
uses Math;

procedure RequestBotExcursion(var Target:TBotExcursionTarget; Active:Boolean;
  Station:Double; const Point:TVector3);
begin
  Target.RequestedStation:=Station;Target.RequestedPoint:=Point;
  if Target.Active=Active then Exit;
  Target.Active:=Active;Target.Clock:=0;
  Target.Station:=Station;Target.Point:=Point;Inc(Target.Revision);
end;

procedure StepBotExcursionTarget(var Target:TBotExcursionTarget; Dt:Single);
begin
  if not Target.Active or(Dt<=0)or IsNan(Dt)or IsInfinite(Dt)then Exit;
  Target.Clock:=Target.Clock+Dt;
  if Target.Clock<30 then Exit;
  Target.Clock:=Target.Clock-Floor(Target.Clock/30)*30;
  if (Target.RequestedPoint-Target.Point).Length<=15 then Exit;
  Target.Station:=Target.RequestedStation;Target.Point:=Target.RequestedPoint;
  Inc(Target.Revision);
end;

function StepBotExcursionWait(var State:TBotExcursionWait;
  const Target:TBotExcursionTarget; BotStation,RouteLength:Double;
  const Input:TBotWaitInput; Dt:Single):TBotWaitControl;
var Gap,Remaining:Double;TargetSpeed,Decel:Single;
begin
  Result:=Default(TBotWaitControl);
  if not Target.Active or(RouteLength<=0)or(Dt<=0)or IsNan(Dt)or IsInfinite(Dt)then Exit;
  if not State.HasTarget or(State.Revision<>Target.Revision)then begin
    State.HasTarget:=True;State.Revision:=Target.Revision;State.Waiting:=False;
    Gap:=Target.Station-BotStation;
    Gap:=Gap-Floor((Gap+3)/RouteLength)*RouteLength;
    { A point just behind is already reached; other points are approached
      in the existing route direction, including its return branch. }
    State.StopDistance:=Input.Distance+Max(0.0,Gap);
  end;
  Remaining:=State.StopDistance-Input.Distance;
  if(Remaining<=3)and(Input.Speed<0.25)then State.Waiting:=True;
  if State.Waiting then Exit;
  Result.Enabled:=True;
  TargetSpeed:=Min(8.0,Sqrt(Max(0.0,2*1.5*(Remaining-1.5))));
  if Input.Speed>TargetSpeed-0.15 then begin
    { Bound the desired slowing separately from gravity compensation:
      even a steep descent must permit a positive stopping acceleration. }
    Decel:=EnsureRange((Input.Speed-TargetSpeed)/0.4,0.0,3.0)
      -9.80665*Sin(DegToRad(Input.GradeDeg));
    Result.BrakeForce:=Max(1.0,Input.Mass)*Max(0.0,Decel);
  end else Result.Power:=Max(0.0,Input.RidingPower);
end;
end.
