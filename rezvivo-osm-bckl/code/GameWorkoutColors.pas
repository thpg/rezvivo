unit GameWorkoutColors;
{$mode objfpc}{$H+}
interface
uses CastleColors, WorkoutFile;
const WorkoutZone1Upper:Single=0.55;
function WorkoutPowerColor(Power:Single):TCastleColor;
function WorkoutPowerZone(Power:Single):Integer;
function WorkoutSegmentColor(Segment:TWorkoutSegment;Scale:Single):TCastleColor;
implementation
uses CastleVectors;
function WorkoutPowerZone(Power:Single):Integer;
begin
  if Power<0.001 then Result:=0
  else if Power<WorkoutZone1Upper then Result:=1
  else if Power<0.75 then Result:=2
  else if Power<0.90 then Result:=3
  else if Power<1.05 then Result:=4
  else if Power<1.20 then Result:=5
  else Result:=6;
end;
function WorkoutPowerColor(Power:Single):TCastleColor;
begin
  case WorkoutPowerZone(Power)of
    0:Result:=Vector4(0.45,0.45,0.50,1);
    1:Result:=Vector4(0.45,0.50,0.55,1);
    2:Result:=Vector4(0.20,0.45,0.85,1);
    3:Result:=Vector4(0.30,0.70,0.95,1);
    4:Result:=Vector4(0.30,0.78,0.40,1);
    5:Result:=Vector4(0.95,0.60,0.25,1);
    else Result:=Vector4(0.90,0.30,0.30,1);
  end;
end;
function WorkoutSegmentColor(Segment:TWorkoutSegment;Scale:Single):TCastleColor;
var P:Single;
begin
  if (Segment=nil) or (Segment.Kind=wskFreeRide) then Exit(WorkoutPowerColor(0));
  P:=Segment.PowerLow;
  if Segment.Kind in [wskWarmup,wskCooldown,wskRamp] then P:=(P+Segment.PowerHigh)*0.5;
  Result:=WorkoutPowerColor(P*Scale);
end;
end.
