unit GameTravel;
{$mode objfpc}{$H+}
interface
uses Math, SysUtils;
type
  TTravelMode = (travelWalk, travelBicycle, travelBoat, travelCar,
    travelMotorcycle, travelFlight);
  THeldMovement = record
    Seconds: Double;
    Direction: Integer;
  end;
const
  TravelIds: array[TTravelMode] of string =
    ('walk','bicycle','boat','car','motorcycle','flight');
  TravelTitles: array[TTravelMode] of string =
    ('Walking','Bicycle','Boat','Car','Motorcycle','Flight');
function TravelAvailable(Mode: TTravelMode): Boolean;
function ParseTravel(const Id: string): TTravelMode;
function KeyboardPower(Power, Axis, Dt: Single): Single;
{ Mean speed during this frame. Releasing or reversing restarts the ramp. }
function HeldMovementSpeed(var Held: THeldMovement; Axis, Dt,
  InitialSpeed, MaximumSpeed, RampSeconds: Single): Single;
implementation
function TravelAvailable(Mode: TTravelMode): Boolean;
begin Result:=Mode in [travelWalk,travelBicycle,travelFlight] end;
function ParseTravel(const Id: string): TTravelMode;
var M: TTravelMode;
begin
  for M:=Low(M) to High(M) do if SameText(Id,TravelIds[M]) then begin
    if not TravelAvailable(M) then raise EArgumentException.Create('Transport is not available');
    Exit(M);
  end;
  raise EArgumentException.Create('Unknown transport');
end;
function KeyboardPower(Power, Axis, Dt: Single): Single;
var FastTime: Single;
begin
  Result:=EnsureRange(Power,0,1000);Dt:=EnsureRange(Dt,0,0.25);
  if Axis>0 then begin
    { Reach a useful cruising effort in one second. Further holding is fine
      adjustment; integrate across the threshold independently of frame rate. }
    FastTime:=Min(Dt,Max(0,(250-Result)/250));
    Result:=Result+FastTime*250+(Dt-FastTime)*60;
  end else if Axis<0 then Result:=Result-Dt*300;
  Result:=EnsureRange(Result,0,1000);
end;

function HeldMovementSpeed(var Held: THeldMovement; Axis, Dt,
  InitialSpeed, MaximumSpeed, RampSeconds: Single): Single;
var Direction:Integer; BeforeTime,AfterTime:Double;
  function DistanceAt(T:Double):Double;
  var U:Double;
  begin
    U:=Min(T/RampSeconds,1.0);
    { Integral of smoothstep: equal travel at different frame rates, including
      the frame crossing the end of the ramp. }
    Result:=InitialSpeed*Min(T,RampSeconds)+
      (MaximumSpeed-InitialSpeed)*RampSeconds*(U*U*U-0.5*U*U*U*U)+
      MaximumSpeed*Max(0.0,T-RampSeconds);
  end;
begin
  Result:=0;Axis:=EnsureRange(Axis,-1,1);
  if Abs(Axis)<0.001 then begin Held:=Default(THeldMovement);Exit end;
  Direction:=Sign(Axis);
  if Direction<>Held.Direction then begin Held.Seconds:=0;Held.Direction:=Direction end;
  Dt:=EnsureRange(Dt,0,0.25);if Dt=0 then Exit;
  MaximumSpeed:=Max(0,MaximumSpeed);InitialSpeed:=EnsureRange(InitialSpeed,0,MaximumSpeed);
  if RampSeconds<=0 then Exit(Axis*MaximumSpeed);
  BeforeTime:=Held.Seconds;AfterTime:=BeforeTime+Dt;
  Result:=Axis*(DistanceAt(AfterTime)-DistanceAt(BeforeTime))/Dt;
  Held.Seconds:=Min(AfterTime,RampSeconds);
end;
end.
