unit RiderMotion;

{$mode objfpc}{$H+}

interface

const
  ANKLE_CURVE_PHASE1=310.0;
  ANKLE_CURVE_PHASE2=250.0;
  ANKLE_CURVE_POS_PEAK=0.992690685;
  ANKLE_CURVE_NEG_PEAK=1.182432177;

type
  TSpineAngles = array[0..4] of Single;
  TShoulderAngles = array[0..1] of Single; { right, left; positive = forward/up }
  TRiderMotionProfile = record
    Standing: Single;   { 0 seated, 1 out of the saddle; blends with the posture }
    SeatedPower: Single; { low, loaded seated posture vs quiet endurance }
    Sprint: Single;      { standing sprint vs the slower climbing transfer }
    Pedalling: Single;  { suppress cyclic motion in dismount / planted-foot poses }
    Breathing: Single;
    AnkleDeg: Single;
  end;
  TRiderMotionFrame = record
    X, Y, Z, Pitch, Yaw, Roll: Single; { metres / degrees, bike frame }
    BikeLean, BikeSteer: Single;
    SpinePitch, SpineYaw, SpineRoll: TSpineAngles;
    ShoulderRound, AnkleDeg: Single;
    ScapulaProtraction, ScapulaElevation: TShoulderAngles;
  end;

function SmoothUnit(X: Single): Single;
function RiderBreathsPerMinute(Load:Single):Single;
procedure AdvanceRiderBreathing(var Load:Single;var Phase:Double;Dt,Effort:Single);
function BicycleAnkleFlexCurve(const CrankDeg,MaxFlexDeg:Double):Double;
function PedalContactsReady(Pedalling, FreeR, FreeL: Single;
  GroundedTarget: Boolean): Boolean;
function AdvancePedalRate(Current, Requested, Dt: Single;
  ContactsReady: Boolean): Single;
function BlendMotionProfile(const A, B: TRiderMotionProfile;
  T: Single): TRiderMotionProfile;
procedure RiderSupportInBikeFrame(var Y, Z: Single; Standing, BikeLeanDeg: Single);
function EvaluateRiderMotion(const Profile: TRiderMotionProfile;
  Phase, BreathPhase: Double; CadenceRpm, Effort, SwayM, BobM: Single): TRiderMotionFrame;

implementation

uses Math;

function RiderBreathsPerMinute(Load:Single):Single;
begin Result:=12+42*SmoothUnit(EnsureRange(Load/1.6,0,1)) end;

procedure AdvanceRiderBreathing(var Load:Single;var Phase:Double;Dt,Effort:Single);
var Response:Single;
begin
  Dt:=EnsureRange(Dt,0,0.25);Effort:=EnsureRange(Effort,0,2.0);
  if Effort>Load then Response:=4.0 else Response:=10.0;
  Load:=Load+(Effort-Load)*(1-Exp(-Dt/Response));
  Phase:=Frac(Phase+Dt*RiderBreathsPerMinute(Load)/60);
end;

function BicycleAnkleFlexCurve(const CrankDeg,MaxFlexDeg:Double):Double;
var A,S:Double;
begin
  A:=CrankDeg-360*Floor(CrankDeg/360);
  S:=Cos(DegToRad(A-ANKLE_CURVE_PHASE1))+0.25*Cos(DegToRad(2*(A-ANKLE_CURVE_PHASE2)));
  if S>=0 then Result:=MaxFlexDeg*S/ANKLE_CURVE_POS_PEAK
  else Result:=MaxFlexDeg*S/ANKLE_CURVE_NEG_PEAK;
end;

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
  Result.SeatedPower := A.SeatedPower + (B.SeatedPower - A.SeatedPower) * T;
  Result.Sprint := A.Sprint + (B.Sprint - A.Sprint) * T;
  Result.Pedalling := A.Pedalling + (B.Pedalling - A.Pedalling) * T;
  Result.Breathing := A.Breathing + (B.Breathing - A.Breathing) * T;
  Result.AnkleDeg := A.AnkleDeg + (B.AnkleDeg - A.AnkleDeg) * T;
end;

procedure RiderSupportInBikeFrame(var Y, Z: Single; Standing, BikeLeanDeg: Single);
var C, S, InverseY, InverseZ, Weight: Single;
begin
  { Seated support follows the saddle. Out of the saddle the support trajectory
    is in the unrolled bicycle frame: the bicycle rocks UNDER the pelvis.
    Inverse-roll the complete anchor, including height, before parent roll.
    Blend the two supports during sit/stand transfers, never after limb IK. }
  Weight := EnsureRange(Standing, 0.0, 1.0);
  if (Weight = 0) or (BikeLeanDeg = 0) then Exit;
  C := Cos(DegToRad(BikeLeanDeg)); S := Sin(DegToRad(BikeLeanDeg));
  InverseY := Y * C + Z * S;
  InverseZ := -Y * S + Z * C;
  Y := Y + (InverseY - Y) * Weight;
  Z := Z + (InverseZ - Z) * Weight;
end;

function EvaluateRiderMotion(const Profile: TRiderMotionProfile;
  Phase, BreathPhase: Double; CadenceRpm, Effort, SwayM, BobM: Single): TRiderMotionFrame;
var
  A, Stroke, DoubleStroke, Torque, Drive, Stand, Power, Sprint, Theta,
  PelvisStroke, WorldRoll, ThoraxRoll, Breath, Chest, ThoraxTwist,
  LumbarTwist, LumbarFlex, ScapularLoad: Single;
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
  Power := (1 - Stand) * EnsureRange(Profile.SeatedPower, 0.0, 1.0);
  Sprint := Stand * EnsureRange(Profile.Sprint, 0.0, 1.0);
  Drive := SmoothUnit(CadenceRpm / 35) * EnsureRange(Profile.Pedalling, 0.0, 1.0);
  Torque := EnsureRange(Effort * 80 / Max(50.0, CadenceRpm), 0.0, 2.0);
  A := Drive * (0.28 + 0.42 * Torque);
  { Phase is the ACTUAL right crank angle, zero forward, in every consumer.
    Shape and phase lag distinguish the four families, not just amplitude.
    The supplied cycling clips guide their character, not calibrated angles.
    Endurance is quiet; seated power firms the pelvis and loads the bars;
    climbing transfers weight broadly; sprinting has a shorter load peak. }
  Theta := Phase * 2 * Pi;
  Stroke := (Cos(Theta) + 0.12 * Sprint * Cos(3 * Theta)) / (1 + 0.12 * Sprint);
  PelvisStroke := Cos(Theta - 0.20 - 0.15 * Stand);
  DoubleStroke := Sin(2 * Theta + 0.30 * Stand + 0.20 * Power);
  Result.Z := SwayM * A * PelvisStroke;
  Result.Y := BobM * A * DoubleStroke;
  Result.X := (0.0005 + 0.001 * Power + 0.004 * Stand + 0.002 * Sprint) * A * Sin(2 * Theta - 0.4);
  Result.Yaw := (0.30 + 0.25 * Power + 0.65 * Stand + 0.25 * Sprint) * A * Cos(Theta - 0.35);
  Result.Pitch := (0.16 + 0.14 * Power + 0.45 * Stand + 0.25 * Sprint) * A * Sin(2 * Theta - 0.35);
  Result.BikeLean := (0.28 + 0.20 * Power + 3.82 * Stand + 1.20 * Sprint) * A * Stroke;
  Result.BikeSteer := -Result.BikeLean * 0.18;
  WorldRoll := (0.32 + 0.20 * Power + 0.85 * Stand + 0.25 * Sprint) * A * Cos(Theta - 0.55);
  ThoraxRoll := (0.20 + 0.18 * Power + 0.60 * Stand + 0.25 * Sprint) * A * Cos(Theta - 1.10);
  Result.Roll := WorldRoll - Result.BikeLean;

  { Breathing has its OWN accumulated phase, independent of crank revolutions
    and frame rate. It remains when coasting/stopped. No mesh scaling, bone
    length change, random frame noise or discontinuity at a crank wrap. }
  Breath := Sin(BreathPhase * 2 * Pi);
  Chest := Profile.Breathing * (0.28 + 0.32 * EnsureRange(Effort, 0.0, 2.0)) * Breath;
  Result.SpinePitch[1] := -0.20 * Result.Pitch - 0.18 * Chest;
  Result.SpinePitch[2] := -0.40 * Result.Pitch - 0.50 * Chest;
  Result.SpinePitch[3] := -0.20 * Result.Pitch - 0.32 * Chest;
  Result.SpinePitch[4] := -0.20 * Result.Pitch + Chest;
  Result.SpineRoll[1] := 0.20 * (ThoraxRoll - WorldRoll);
  Result.SpineRoll[2] := 0.45 * (ThoraxRoll - WorldRoll);
  Result.SpineRoll[3] := 0.35 * (ThoraxRoll - WorldRoll);
  Result.SpineRoll[4] := -ThoraxRoll;
  Result.SpineYaw[1] := -0.20 * Result.Yaw;
  Result.SpineYaw[2] := -0.35 * Result.Yaw;
  Result.SpineYaw[3] := -0.20 * Result.Yaw;
  Result.SpineYaw[4] := -0.25 * Result.Yaw;
  { The lumbar and thoracic regions articulate relative to the pelvis. Most
    axial rotation belongs to the thorax; a small lumbar counter-rotation
    avoids moving the back as one rigid panel. These are rotations only. }
  LumbarTwist := (0.30 + 0.15 * Power + 0.65 * Stand + 0.25 * Sprint) * A * Cos(Theta - 0.45);
  LumbarFlex := (0.16 + 0.35 * Stand) * A * DoubleStroke;
  Result.SpineYaw[0] := LumbarTwist;
  Result.SpineYaw[2] := Result.SpineYaw[2] - 0.45 * LumbarTwist;
  Result.SpineYaw[3] := Result.SpineYaw[3] - 0.55 * LumbarTwist;
  Result.SpinePitch[0] := LumbarFlex;
  Result.SpinePitch[2] := Result.SpinePitch[2] - 0.6 * LumbarFlex;
  Result.SpinePitch[3] := Result.SpinePitch[3] - 0.4 * LumbarFlex;
  ThoraxTwist := (0.55 + 0.70 * Power + 3.0 * Stand + Sprint) * A * Cos(Theta - 0.95);
  Result.SpineYaw[2] := Result.SpineYaw[2] + 0.45 * ThoraxTwist;
  Result.SpineYaw[3] := Result.SpineYaw[3] + 0.55 * ThoraxTwist;
  Result.SpineYaw[4] := Result.SpineYaw[4] - ThoraxTwist;
  Result.ShoulderRound := 0.8 * Chest;
  { Alternating load on the bars glides each shoulder girdle around the rib
    cage, with much less excursion seated. Breathing remains bilateral.
    The clavicles carry this motion before arm IK, not the wrists afterwards. }
  ScapularLoad := A * (0.30 + 0.35 * Power + 1.20 * Stand + 0.40 * Sprint) * Cos(Theta - 0.85);
  Result.ScapulaProtraction[0] := ScapularLoad;
  Result.ScapulaProtraction[1] := -ScapularLoad;
  Result.ScapulaElevation[0] := 0.15 * Chest + 0.30 * ScapularLoad;
  Result.ScapulaElevation[1] := 0.15 * Chest - 0.30 * ScapularLoad;
  Result.AnkleDeg := Profile.AnkleDeg * Drive * (0.75 + 0.20 * Torque);
end;

end.
