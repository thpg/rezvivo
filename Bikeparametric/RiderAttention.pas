unit RiderAttention;
{$mode objfpc}{$H+}

{ Small replayable behaviour state. It supplies articulated rotations before
  arm IK, sharing the existing CPU/GPU pose path and preserving the base pose. }
interface
const
  RiderAttentionNeckYawLimit = 72;
type
  TRiderAttentionFrame = record
    Yaw, Pitch, TorsoYaw: Single;
  end;
  TRiderAttentionState = record
    Seed: Cardinal;
    Initialized, Active, WasWaiting: Boolean;
    Timer, Duration, NextLook, GoalYaw, GoalPitch: Single;
    Frame: TRiderAttentionFrame;
    Events: Cardinal;
  end;
  TRiderAttentionInput = record
    Waiting, TargetValid, Safe: Boolean;
    TargetYaw, TargetPitch: Single;
  end;
procedure ResetRiderAttention(var State: TRiderAttentionState; Seed: Cardinal);
procedure StepRiderAttention(var State: TRiderAttentionState;
  const Input: TRiderAttentionInput; Dt: Single);
function RiderAttentionTorsoYaw(Yaw: Single; Waiting: Boolean): Single;

implementation
uses Math, RiderMotion;

function RandomUnit(var Seed: Cardinal): Single;
begin
  Seed:=Cardinal((QWord(Seed)*1664525+1013904223) and $ffffffff);
  Result:=(Seed shr 8)/16777216;
end;

procedure ResetRiderAttention(var State: TRiderAttentionState; Seed: Cardinal);
begin
  State:=Default(TRiderAttentionState);State.Seed:=Seed;
end;

function RiderAttentionTorsoYaw(Yaw: Single; Waiting: Boolean): Single;
begin
  if Waiting then Result:=EnsureRange(Yaw*0.28,-28.0,28.0)
  else Result:=EnsureRange(Yaw*0.23,-21.0,21.0);
end;

procedure StepRiderAttention(var State: TRiderAttentionState;
  const Input: TRiderAttentionInput; Dt: Single);
var Yaw,Pitch,Torso,Envelope,Blend,Limit,Ramp,TorsoEnvelope:Single;
begin
  if (Dt<=0)or IsNan(Dt)or IsInfinite(Dt) then Exit;
  if not State.Initialized or (State.WasWaiting<>Input.Waiting) then begin
    State.Initialized:=True;State.Active:=False;State.WasWaiting:=Input.Waiting;
    if Input.Waiting then State.NextLook:=2+RandomUnit(State.Seed)*4
    else State.NextLook:=12+RandomUnit(State.Seed)*16;
  end;
  if not Input.Safe then begin
    State.Active:=False;State.NextLook:=Max(3.0,State.NextLook);
  end else if not State.Active then begin
    State.NextLook:=State.NextLook-Dt;
    if State.NextLook<=0 then begin
      State.Active:=True;State.Timer:=0;Inc(State.Events);
      if Input.Waiting then State.Duration:=2.4+RandomUnit(State.Seed)*0.9
      else State.Duration:=1.75+RandomUnit(State.Seed)*0.5;
      if Input.TargetValid then begin
        State.GoalYaw:=Input.TargetYaw;State.GoalPitch:=Input.TargetPitch;
      end else begin
        State.GoalYaw:=90;
        if RandomUnit(State.Seed)<0.5 then State.GoalYaw:=-State.GoalYaw;
        State.GoalPitch:=0;
      end;
      if Input.Waiting then Limit:=100 else Limit:=90;
      State.GoalYaw:=EnsureRange(State.GoalYaw,-Limit,Limit);
      State.GoalPitch:=EnsureRange(State.GoalPitch,-12,14);
    end;
  end;
  Yaw:=0;Pitch:=0;Torso:=0;
  if State.Active then begin
    State.Timer:=State.Timer+Dt;
    if Input.Waiting then Ramp:=0.7 else Ramp:=0.55;
    Envelope:=SmoothUnit(State.Timer/Ramp)*SmoothUnit((State.Duration-State.Timer)/Ramp);
    Yaw:=State.GoalYaw*Envelope;Pitch:=State.GoalPitch*Envelope;
    { Head leads slightly; the thorax follows and settles more slowly. These
      are bike-frame turns, not twists about the bent spine's local up axis. }
    TorsoEnvelope:=SmoothUnit((State.Timer-0.08)/(Ramp+0.12))*
      SmoothUnit((State.Duration-State.Timer)/(Ramp+0.08));
    Torso:=RiderAttentionTorsoYaw(State.GoalYaw,Input.Waiting)*TorsoEnvelope;
    if State.Timer>=State.Duration then begin
      State.Active:=False;
      if Input.Waiting then State.NextLook:=7+RandomUnit(State.Seed)*9
      else if Input.TargetValid then State.NextLook:=8+RandomUnit(State.Seed)*12
      else State.NextLook:=18+RandomUnit(State.Seed)*22;
    end;
  end;
  Blend:=1-Exp(-Dt/0.12);
  State.Frame.Yaw:=State.Frame.Yaw+EnsureRange((Yaw-State.Frame.Yaw)*Blend,-180*Dt,180*Dt);
  State.Frame.Pitch:=State.Frame.Pitch+EnsureRange((Pitch-State.Frame.Pitch)*Blend,-50*Dt,50*Dt);
  Blend:=1-Exp(-Dt/0.20);
  State.Frame.TorsoYaw:=State.Frame.TorsoYaw+EnsureRange((Torso-State.Frame.TorsoYaw)*Blend,-65*Dt,65*Dt);
  { During onset/cancellation the shoulders may lag. Never make the neck
    compensate for that lag by turning farther than its full-turn budget. }
  State.Frame.Yaw:=EnsureRange(State.Frame.Yaw,
    State.Frame.TorsoYaw-RiderAttentionNeckYawLimit,
    State.Frame.TorsoYaw+RiderAttentionNeckYawLimit);
end;
end.
