{ Transport-independent steering. Game coordinates: positive turns left.
  A held button/axis produces one junction command until released; hysteresis
  prevents noisy analog inputs from selecting successive junctions. }
unit GameSteeringInput;
{$mode objfpc}{$H+}{$modeswitch advancedrecords}
interface
type
  TSteeringEdge = record
  private
    FHeld: Integer;
  public
    procedure Reset;
    procedure Prime(Axis: Single);
    function Update(Axis: Single): Integer;
  end;
  TSteeringInput = class
  private
    FBLEEdge, FGamepadEdge: TSteeringEdge;
    FLastSerial: Cardinal;
  public
    procedure Reset(BLEAxis, GamepadAxis: Single; Serial: Cardinal);
    procedure ForgetBLE;
    function Read(BLEAvailable: Boolean; BLEAxis: Single;
      Serial: Cardinal; SerialDirection: Integer;
      GamepadAvailable: Boolean; GamepadAxis: Single;
      out Axis: Single; out Turn: Integer): Boolean;
  end;
function GamepadSteeringAxis(RawX: Single; Left, Right: Boolean): Single;
implementation
uses Math;
function SafeAxis(Axis: Single): Single;
var Bits: Cardinal;
begin
  Move(Axis,Bits,SizeOf(Bits));
  if (Bits and $7F800000)=$7F800000 then Exit(0);
  Result:=EnsureRange(Axis,-1,1);
end;
procedure TSteeringEdge.Reset;
begin FHeld:=0 end;
procedure TSteeringEdge.Prime(Axis: Single);
begin FHeld:=0; Update(Axis) end;
function TSteeringEdge.Update(Axis: Single): Integer;
var Direction: Integer;
begin
  Result:=0; Axis:=SafeAxis(Axis);
  if Abs(Axis)<=0.12 then begin FHeld:=0; Exit end;
  if Abs(Axis)<0.30 then Exit;
  Direction:=Sign(Axis);
  if Direction<>FHeld then begin FHeld:=Direction; Result:=Direction end;
end;
function GamepadSteeringAxis(RawX: Single; Left, Right: Boolean): Single;
const DeadZone=0.16;
begin
  if Left or Right then Exit(Ord(Left)-Ord(Right));
  RawX:=SafeAxis(RawX);
  if Abs(RawX)<=DeadZone then Exit(0);
  Result:=-Sign(RawX)*(Abs(RawX)-DeadZone)/(1-DeadZone);
end;
procedure TSteeringInput.Reset(BLEAxis, GamepadAxis: Single; Serial: Cardinal);
begin
  FBLEEdge.Prime(BLEAxis); FGamepadEdge.Prime(GamepadAxis);
  FLastSerial:=Serial;
end;
procedure TSteeringInput.ForgetBLE;
begin FBLEEdge.Reset; FLastSerial:=0 end;
function TSteeringInput.Read(BLEAvailable: Boolean; BLEAxis: Single;
  Serial: Cardinal; SerialDirection: Integer;
  GamepadAvailable: Boolean; GamepadAxis: Single;
  out Axis: Single; out Turn: Integer): Boolean;
var PadTurn: Integer;
begin
  if not BLEAvailable then begin BLEAxis:=0; Serial:=0 end;
  if not GamepadAvailable then GamepadAxis:=0;
  BLEAxis:=SafeAxis(BLEAxis); GamepadAxis:=SafeAxis(GamepadAxis);
  Turn:=FBLEEdge.Update(BLEAxis);
  { A radio button can be pressed AND released between UI frames. Its serial
    survives coalescing even though the latest continuous angle is zero. }
  if Serial<>0 then
  begin
    Turn:=0;
    if (Serial<>FLastSerial) and (Abs(SerialDirection)=1) then Turn:=SerialDirection;
  end;
  FLastSerial:=Serial;
  PadTurn:=FGamepadEdge.Update(GamepadAxis);
  if PadTurn<>0 then Turn:=PadTurn;
  Axis:=BLEAxis;
  if Abs(GamepadAxis)>Abs(Axis) then Axis:=GamepadAxis;
  Result:=BLEAvailable or GamepadAvailable;
end;
end.
