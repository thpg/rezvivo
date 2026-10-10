{ Elite STERZO Smart GATT protocol. Angle packets are little-endian float32,
  clockwise positive. Old firmware needs a 16-bit challenge response before
  enabling measurements; newer firmware can notify immediately.
  Protocol reference: github.com/zacharyedwardbull/pycycling (MIT). }
unit EliteSterzoProtocol;
{$mode objfpc}{$H+}
interface
uses SysUtils, TrainerData;
const
  SterzoServiceUUID = '347b0001-7635-408b-8918-8ff3949ce592';
  SterzoAngleUUID = '347b0030-7635-408b-8918-8ff3949ce592';
  SterzoControlUUID = '347b0031-7635-408b-8918-8ff3949ce592';
  SterzoChallengeUUID = '347b0032-7635-408b-8918-8ff3949ce592';
  SterzoRangeDegrees = 34.0;
function IsSterzoName(const Name: String): Boolean;
function ParseSterzoAngle(const Bytes: TBytes; out Data: TTrainerDataRecord): Boolean;
function SterzoChallengeResponse(const Bytes: TBytes): TBytes;
{ Same convention as keyboard steering: positive turns left. }
function SteeringAxis(Degrees: Single): Single;
function SmoothSteering(Current, Target, Dt: Single): Single;
implementation
uses Math;
{$I EliteSterzoChallenge.inc}

function IsSterzoName(const Name: String): Boolean;
begin Result := Pos('STERZO', UpperCase(Name)) > 0 end;

function ParseSterzoAngle(const Bytes: TBytes; out Data: TTrainerDataRecord): Boolean;
var Bits: Cardinal; Angle: Single;
begin
  Result := False; Data := Default(TTrainerDataRecord);
  if Length(Bytes) <> 4 then Exit;
  Bits := Cardinal(Bytes[0]) or (Cardinal(Bytes[1]) shl 8) or
    (Cardinal(Bytes[2]) shl 16) or (Cardinal(Bytes[3]) shl 24);
  { Reject NaN/Inf before floating-point operations (FPC traps invalid ops). }
  if (Bits and $7F800000) = $7F800000 then Exit;
  Move(Bits, Angle, SizeOf(Angle));
  if Abs(Angle) > 90 then Exit;
  BeginTrainerPacket(Data);
  Data.SteeringAngle := Angle;
  MarkTrainerMetric(Data, tmSteering);
  Result := True;
end;

function SterzoChallengeResponse(const Bytes: TBytes): TBytes;
var Index: Cardinal;
begin
  Result := nil;
  if (Length(Bytes) <> 4) or (Bytes[0] <> $03) or (Bytes[1] <> $10) then Exit;
  Index := (Cardinal(Bytes[2]) shl 8) or Bytes[3];
  Result := TBytes.Create($03, $11, SterzoChallengeCodes[Index * 2],
    SterzoChallengeCodes[Index * 2 + 1]);
end;

function SteeringAxis(Degrees: Single): Single;
const DeadZone = 0.6;
begin
  if Abs(Degrees) <= DeadZone then Exit(0);
  Result := -Sign(Degrees) * Min(1, (Abs(Degrees)-DeadZone) /
    (SterzoRangeDegrees-DeadZone));
end;

function SmoothSteering(Current, Target, Dt: Single): Single;
begin Result := Current + (Target-Current) * (1-Exp(-Max(0,Dt)/0.08)) end;
end.
