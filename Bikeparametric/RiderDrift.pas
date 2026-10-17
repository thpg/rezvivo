unit RiderDrift;

{$mode objfpc}{$H+}

{ Visual cornering support only. This unit never writes sensor, drivetrain
  power or route progress. The same small state is used by all rider models
  and saved with their animation replay. }
interface

const
  RIDER_CORNER_GRIP_FACTOR = 0.85;
  RIDER_CORNER_SPEED_SAFETY = 0.92;
  RIDER_CORNER_ACCEL_LIMIT = 9.80665 * RIDER_CORNER_GRIP_FACTOR *
    RIDER_CORNER_SPEED_SAFETY * RIDER_CORNER_SPEED_SAFETY;

type
  TRiderDriftFrame = record
    Active, HoldCrank: Boolean;
    Blend, SlipRad, Demand, Intensity: Double;
  end;
  TRiderDriftState = record
    Engaged: Boolean;
    Direction: Integer;
    Lateral, EnterTime, ExitTime, Weight, Slip: Double;
    CrankParked: Boolean;
    CrankTarget: Double;
    Frame: TRiderDriftFrame;
  end;

procedure AdvanceRiderDrift(var S:TRiderDriftState;
  Dt,SpeedMps,LateralAccel:Double;Enabled:Boolean);
function DriftLateralAccel(const S:TRiderDriftState;Raw:Double):Double;
function ParkDriftCrank(var S:TRiderDriftState;
  Phase,BasePhase,Direction,RequestedRate,Dt:Double):Double;

implementation

uses Math;

function Smooth(X:Double):Double;inline;
begin X:=EnsureRange(X,0.0,1.0);Result:=X*X*(3-2*X) end;

function Wrap(X:Double):Double;inline;
begin Result:=Frac(X);if Result<0 then Result:=Result+1 end;

procedure AdvanceRiderDrift(var S:TRiderDriftState;
  Dt,SpeedMps,LateralAccel:Double;Enabled:Boolean);
var Demand,Target,Step,GoalSlip:Double;Side:Integer;
begin
  if not Enabled or IsNan(SpeedMps)or IsInfinite(SpeedMps)or
    IsNan(LateralAccel)or IsInfinite(LateralAccel)then begin
    S:=Default(TRiderDriftState);Exit;
  end;
  if IsNan(Dt)or IsInfinite(Dt)or(Dt<0)or(Dt>0.5)then begin
    S:=Default(TRiderDriftState);Exit;
  end;
  if Dt=0 then Exit;
  S.Lateral:=S.Lateral+(EnsureRange(LateralAccel,-30.0,30.0)-S.Lateral)*
    (1-Exp(-Dt/0.08));
  Demand:=Abs(S.Lateral)/RIDER_CORNER_ACCEL_LIMIT;
  Side:=Sign(S.Lateral);
  if S.Engaged then begin
    S.EnterTime:=0;
    if (Demand<0.60)or(SpeedMps<2.2)or(Side<>S.Direction)then
      S.ExitTime:=S.ExitTime+Dt
    else S.ExitTime:=0;
    if (S.ExitTime>=0.28)or(Side<>S.Direction)or(SpeedMps<0.5)then
      S.Engaged:=False;
  end else if S.Weight<=0 then begin
    S.ExitTime:=0;
    if (Demand>=0.82)and(SpeedMps>=3.3)then S.EnterTime:=S.EnterTime+Dt
    else S.EnterTime:=0;
    if S.EnterTime>=0.08 then begin
      S.Engaged:=True;S.Direction:=Side;S.CrankParked:=False;
    end;
  end;
  Target:=0;Step:=Dt/0.55;
  if S.Engaged then begin Target:=1;Step:=Dt/0.30 end;
  S.Weight:=S.Weight+EnsureRange(Target-S.Weight,-Step,Step);
  S.Frame.Blend:=Smooth(S.Weight);
  S.Frame.Intensity:=Smooth((Demand-0.70)/0.65);
  GoalSlip:=0;
  if S.Engaged then
    GoalSlip:=S.Direction*DegToRad(12+15*S.Frame.Intensity)*S.Frame.Blend;
  { No instantaneous side swap in an S-bend; unwind the previous skid first. }
  S.Slip:=S.Slip+EnsureRange((GoalSlip-S.Slip)*(1-Exp(-Dt/0.13)),
    -DegToRad(75)*Dt,DegToRad(75)*Dt);
  if (S.Weight<=0)and(Abs(S.Slip)<0.0005)then begin
    S.Slip:=0;S.Direction:=0;S.CrankParked:=False;
  end;
  S.Frame.SlipRad:=S.Slip;S.Frame.Demand:=Demand;
  S.Frame.Active:=S.Engaged or(S.Weight>0)or(Abs(S.Slip)>0.0005);
  S.Frame.HoldCrank:=S.Engaged or(S.Weight>0.03);
end;

function DriftLateralAccel(const S:TRiderDriftState;Raw:Double):Double;
var Limit:Double;
begin
  Result:=Raw;
  if not S.Frame.Active then Exit;
  { Residual grip rather than an ever larger bank. Body dynamics still
    solves the coupled support, loading and lean from this effective force. }
  Limit:=9.80665*Tan(DegToRad(30-7*S.Frame.Blend));
  Result:=EnsureRange(Raw,-Limit,Limit);
end;

function ParkDriftCrank(var S:TRiderDriftState;
  Phase,BasePhase,Direction,RequestedRate,Dt:Double):Double;
var Physical,Delta,Rate:Double;
begin
  Result:=Phase;
  if not S.Frame.HoldCrank or(Dt<=0)then Exit;
  if not S.CrankParked then begin
    { Both feet keep their pedal contacts. Coast to the next horizontal
      pair, at most half a turn, without reversing or snapping the crank. }
    Physical:=Wrap(BasePhase+Direction*Phase);
    Delta:=Wrap(0.5-Frac(Physical*2)*0.5);
    if Direction<0 then Delta:=Frac(Physical*2)*0.5;
    if Delta>0.4999 then Delta:=0;
    S.CrankTarget:=Wrap(Phase+Delta);S.CrankParked:=True;
  end;
  Delta:=Wrap(S.CrankTarget-Phase);
  if Delta>0.5001 then Exit;
  Rate:=Max(0.55,Min(1.25,RequestedRate));
  Result:=Wrap(Phase+Min(Delta,Min(Rate*Dt,Delta*(1-Exp(-Dt/0.075)))));
  if Delta<0.0002 then Result:=S.CrankTarget;
end;

end.
