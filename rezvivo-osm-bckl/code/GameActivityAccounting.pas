unit GameActivityAccounting;
{$mode objfpc}{$H+}
interface
type
  TMeasuredPower = record
    Watts: Double;
    Valid: Boolean;
  end;
  TActivityAccounting = record
    Running: Boolean;
    Power: TMeasuredPower;
  end;

function MeasuredPower(HasData: Boolean; AgeSeconds, Watts: Double): TMeasuredPower;
function ActivityAccounting(RideReady, ExplicitPaused, HasWorkout, WorkoutRunning: Boolean;
  SpeedMps: Double; const Power: TMeasuredPower): TActivityAccounting;
function JournalPower(const Power: TMeasuredPower): Word;
function ActiveDistanceDelta(RawDistance: Double; Active: Boolean;
  var LastRawDistance: Double; var LastRawValid: Boolean): Double;

implementation
uses Math;

function MeasuredPower(HasData: Boolean; AgeSeconds, Watts: Double): TMeasuredPower;
begin
  Result:=Default(TMeasuredPower);
  Result.Valid:=HasData and not IsNan(AgeSeconds) and not IsInfinite(AgeSeconds) and
    (AgeSeconds>=0) and (AgeSeconds<=3) and not IsNan(Watts) and not IsInfinite(Watts) and
    (Watts>=0) and (Watts<65535);
  if Result.Valid then Result.Watts:=Watts;
end;

function ActivityAccounting(RideReady, ExplicitPaused, HasWorkout, WorkoutRunning: Boolean;
  SpeedMps: Double; const Power: TMeasuredPower): TActivityAccounting;
begin
  Result.Power:=Power;
  Result.Running:=RideReady and not ExplicitPaused;
  if HasWorkout then Result.Running:=Result.Running and WorkoutRunning
  else Result.Running:=Result.Running and
    ((not IsNan(SpeedMps) and not IsInfinite(SpeedMps) and (SpeedMps>0.1)) or
     (Power.Valid and (Power.Watts>0)));
end;

function JournalPower(const Power: TMeasuredPower): Word;
begin
  if Power.Valid then Result:=EnsureRange(Round(Power.Watts),0,65534)
  else Result:=$FFFF;
end;

function ActiveDistanceDelta(RawDistance: Double; Active: Boolean;
  var LastRawDistance: Double; var LastRawValid: Boolean): Double;
begin
  Result:=0;
  if IsNan(RawDistance) or IsInfinite(RawDistance) or (RawDistance<0) then Exit;
  if Active and LastRawValid then Result:=Max(0,RawDistance-LastRawDistance);
  { Consume paused travel without adding it later when the timer restarts.
    Backward odometer changes add nothing; explicit seeks rebase separately. }
  LastRawDistance:=RawDistance;LastRawValid:=True;
end;
end.
