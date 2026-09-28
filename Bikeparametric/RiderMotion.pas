unit RiderMotion;

{$mode objfpc}{$H+}

interface

type
  TSpineAngles = array[0..4] of Single;
  TRiderMotionProfile = record
    Standing: Single;   { 0 seated, 1 out of the saddle; blends with the posture }
    Pedalling: Single;  { suppress cyclic motion in dismount / planted-foot poses }
    Breathing: Single;
    AnkleDeg: Single;
  end;
  TRiderMotionFrame = record
    X, Y, Z, Pitch, Yaw, Roll: Single; { metres / degrees, bike frame }
    BikeLean, BikeSteer: Single;
    SpinePitch, SpineYaw, SpineRoll: TSpineAngles;
    ShoulderRound, AnkleDeg: Single;
  end;

function SmoothUnit(X: Single): Single;
function PedalContactsReady(Pedalling, FreeR, FreeL: Single;
  GroundedTarget: Boolean): Boolean;
function AdvancePedalRate(Current, Requested, Dt: Single;
  ContactsReady: Boolean): Single;
function BlendMotionProfile(const A, B: TRiderMotionProfile;
  T: Single): TRiderMotionProfile;
function EvaluateRiderMotion(const Profile: TRiderMotionProfile;
  Phase, BreathPhase: Double; CadenceRpm, Effort, SwayM, BobM: Single): TRiderMotionFrame;

implementation

uses Math;

function SmoothUnit(X: Single): Single;
begin
  X := EnsureRange(X, 0.0, 1.0);
  Result := X * X * X * (X * (X * 6 - 15) + 10);
end;

function PedalContactsReady(Pedalling, FreeR, FreeL: Single;
  GroundedTarget: Boolean): Boolean;
begin
  Result := (not GroundedTarget) and (Pedalling >= 0.999) and
    (FreeR <= 0.0001) and (FreeL <= 0.0001);
end;

function AdvancePedalRate(Current, Requested, Dt: Single;
  ContactsReady: Boolean): Single;
var Step: Single;
begin
  { A planted / transferring foot is a hard interlock, not a slow fade.
    After contact, accelerate the crank smoothly (at most 0.4 s to cadence).
    Wheels are independent: the bicycle may already be rolling. }
  if not ContactsReady then Exit(0);
  Requested := Max(0.0, Requested);
  Step := Max(4.0, Requested / 0.4) * Max(0.0, Dt);
  if Current < Requested then Result := Min(Requested, Current + Step)
  else Result := Max(Requested, Current - Step);
end;

function BlendMotionProfile(const A, B: TRiderMotionProfile;
  T: Single): TRiderMotionProfile;
begin
  Result.Standing := A.Standing + (B.Standing - A.Standing) * T;
  Result.Pedalling := A.Pedalling + (B.Pedalling - A.Pedalling) * T;
  Result.Breathing := A.Breathing + (B.Breathing - A.Breathing) * T;
  Result.AnkleDeg := A.AnkleDeg + (B.AnkleDeg - A.AnkleDeg) * T;
end;

function EvaluateRiderMotion(const Profile: TRiderMotionProfile;
  Phase, BreathPhase: Double; CadenceRpm, Effort, SwayM, BobM: Single): TRiderMotionFrame;
var
  A, Stroke, DoubleStroke, Torque, Drive, Stand, Breath, Chest, ThoraxTwist: Single;
begin
  Result := Default(TRiderMotionFrame);
  { Reference patterns, not a motion-capture reconstruction:
    https://doi.org/10.3390/s24113453 (steady / seated / standing sprint)
    https://doi.org/10.1123/jab.2014-0295 (upper-limb load vs power / position)
    British Cycling: How to climb - 10 top tips for beginners (2018).
    Small seated pelvic excursion, a mobile thorax and soft elbows; larger
    weight transfer standing. The neck counters the trunk, keeping gaze steady.
    Contacts are solved AFTER this layer, never displaced after limb IK. }
  Stand := EnsureRange(Profile.Standing, 0.0, 1.0);
  Drive := SmoothUnit(CadenceRpm / 35) * EnsureRange(Profile.Pedalling, 0.0, 1.0);
  Torque := EnsureRange(Effort * 80 / Max(50.0, CadenceRpm), 0.0, 2.0);
  A := Drive * (0.28 + 0.42 * Torque);
  Stroke := Sin(Phase * 2 * Pi + Pi / 6);
  DoubleStroke := Sin(Phase * 4 * Pi - Pi / 6);
  Result.Z := SwayM * A * Stroke;
  Result.Y := BobM * A * DoubleStroke;
  Result.X := (0.0006 + 0.003 * Stand) * A * DoubleStroke;
  Result.Yaw := (0.35 + 0.85 * Stand) * A * Sin(Phase * 2 * Pi - Pi / 6);
  Result.Pitch := (0.18 + 0.65 * Stand) * A * DoubleStroke;
  Result.BikeLean := (0.35 + 2.65 * Stand) * A * Stroke;
  Result.BikeSteer := -Result.BikeLean * 0.28;
  { The bike rocks UNDER the rider; do not tilt pelvis and bicycle together. }
  Result.Roll := (0.45 + Stand) * A * Stroke - 0.8 * Result.BikeLean;

  { Breathing has its OWN accumulated phase, independent of crank revolutions
    and frame rate. It remains when coasting/stopped. No mesh scaling, bone
    length change, random frame noise or discontinuity at a crank wrap. }
  Breath := Sin(BreathPhase * 2 * Pi);
  Chest := Profile.Breathing * (0.28 + 0.32 * EnsureRange(Effort, 0.0, 2.0)) * Breath;
  Result.SpinePitch[1] := -0.20 * Result.Pitch - 0.18 * Chest;
  Result.SpinePitch[2] := -0.40 * Result.Pitch - 0.50 * Chest;
  Result.SpinePitch[3] := -0.20 * Result.Pitch - 0.32 * Chest;
  Result.SpinePitch[4] := -0.20 * Result.Pitch + Chest;
  Result.SpineRoll[1] := -0.20 * Result.Roll;
  Result.SpineRoll[2] := -0.30 * Result.Roll;
  Result.SpineRoll[3] := -0.20 * Result.Roll;
  Result.SpineRoll[4] := -0.30 * Result.Roll - Result.BikeLean;
  Result.SpineYaw[1] := -0.20 * Result.Yaw;
  Result.SpineYaw[2] := -0.35 * Result.Yaw;
  Result.SpineYaw[3] := -0.20 * Result.Yaw;
  Result.SpineYaw[4] := -0.25 * Result.Yaw;
  ThoraxTwist := (0.55 + 4.0 * Stand) * A * Sin(Phase * 2 * Pi - Pi / 4);
  Result.SpineYaw[2] := Result.SpineYaw[2] + 0.45 * ThoraxTwist;
  Result.SpineYaw[3] := Result.SpineYaw[3] + 0.55 * ThoraxTwist;
  Result.SpineYaw[4] := Result.SpineYaw[4] - ThoraxTwist;
  Result.ShoulderRound := 0.8 * Chest;
  Result.AnkleDeg := Profile.AnkleDeg * Drive * (0.75 + 0.20 * Torque);
end;

end.
