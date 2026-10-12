unit RiderAttention;
{$mode objfpc}{$H+}
{ Replayable intentions, evaluated before contact dynamics and arm IK. }
interface
const RiderAttentionNeckYawLimit = 72;
type
  TRiderAttentionAction = (raaNone, raaGlance, raaLookBack, raaRelax, raaRegrip);
  TRiderAttentionFrame = record
    Yaw, Pitch, Roll, TorsoYaw: Single;
    Shoulder: array[0..1] of Single; { preferred scapula protraction, degrees }
    HandRelease, HandSlide: array[0..1] of Single; { fraction / metres }
  end;
  TRiderAttentionState = record
    Seed: Cardinal;
    Initialized, Active, WasWaiting, ForceLook: Boolean;
    Action: TRiderAttentionAction;
    Side: Integer;
    Timer, Duration, NextLook, NextAction, NextRegrip, Remainder: Double;
    GoalYaw, GoalPitch, GoalRoll, Variation: Single;
    Previous, Solved, Frame: TRiderAttentionFrame;
    Events, SmallEvents, Regrips: Cardinal;
  end;
  TRiderAttentionInput = record
    Waiting, TargetValid, Safe, CanRegrip: Boolean;
    TargetYaw, TargetPitch, Effort, SpeedKmh, LateralAccel, RoadYaw: Single;
  end;
procedure ResetRiderAttention(var State: TRiderAttentionState; Seed: Cardinal);
procedure StepRiderAttention(var State: TRiderAttentionState;
  const Input: TRiderAttentionInput; Dt: Single);
function RiderAttentionTorsoYaw(Yaw: Single; Waiting: Boolean): Single;
implementation
uses Math, RiderMotion;
const Step = 1/120;
function RandomUnit(var Seed: Cardinal): Single;
begin
  Seed:=Cardinal((QWord(Seed)*1664525+1013904223) and $ffffffff);
  Result:=(Seed shr 8)/16777216;
end;
procedure ResetRiderAttention(var State: TRiderAttentionState; Seed: Cardinal);
begin State:=Default(TRiderAttentionState);State.Seed:=Seed end;
function RiderAttentionTorsoYaw(Yaw: Single; Waiting: Boolean): Single;
begin
  if Waiting then Result:=EnsureRange(Yaw*0.28,-28.0,28.0)
  else Result:=EnsureRange(Yaw*0.23,-21.0,21.0);
end;
function Follow(Value, Goal, Tau, Rate: Single): Single;
begin Result:=Value+EnsureRange((Goal-Value)*(1-Exp(-Step/Tau)),-Rate*Step,Rate*Step) end;
procedure Initialize(var S:TRiderAttentionState;const U:TRiderAttentionInput);
begin
  if not S.Initialized or(S.WasWaiting<>U.Waiting)then begin
    S.Initialized:=True;S.Active:=False;S.Action:=raaNone;S.WasWaiting:=U.Waiting;
    if U.Waiting then begin
      S.NextLook:=2+RandomUnit(S.Seed)*4;S.NextAction:=0.6+RandomUnit(S.Seed)*2;
    end else begin
      S.NextLook:=12+RandomUnit(S.Seed)*16;S.NextAction:=2+RandomUnit(S.Seed)*4;
    end;
    S.NextRegrip:=6+RandomUnit(S.Seed)*8;
    S.Variation:=0.8+0.4*RandomUnit(S.Seed);
  end;
end;
procedure Tick(var S:TRiderAttentionState;const U:TRiderAttentionInput);
var Goal:TRiderAttentionFrame; Envelope,Ramp,TorsoEnvelope,Relaxed,Choice,
    Pitch,Yaw,Limit,Progress,Amplitude:Single; I:Integer;
    LongSafe,ComfortSafe:Boolean;
begin
  Initialize(S,U);
  { A fast zero-watt descent still needs both hands and forward attention. }
  LongSafe:=U.Safe and(U.Waiting or
    ((U.SpeedKmh<48)and(U.Effort<1.7)and(Abs(U.LateralAccel)<1.4)));
  ComfortSafe:=U.Safe and U.CanRegrip and(U.Waiting or
    ((U.SpeedKmh<38)and(U.Effort<1.15)and(Abs(U.LateralAccel)<0.65)));
  Relaxed:=1-SmoothUnit((U.Effort-0.45)/0.9);
  if U.Waiting then Relaxed:=1;
  if not U.Safe then begin
    S.Active:=False;S.Action:=raaNone;S.ForceLook:=False;
    S.NextAction:=Max(0.8,S.NextAction);S.NextLook:=Max(3.0,S.NextLook);
  end else begin
    if LongSafe then S.NextLook:=S.NextLook-Step;
    S.NextAction:=S.NextAction-Step;S.NextRegrip:=Max(0.0,S.NextRegrip-Step);
    if S.Active and(((S.Action=raaLookBack)and not LongSafe)or
      ((S.Action=raaRegrip)and not ComfortSafe))then begin
      S.Active:=False;S.Action:=raaNone;S.NextAction:=1.5;
    end;
    if S.ForceLook and LongSafe then begin
      S.Active:=False;S.NextLook:=0;S.ForceLook:=False;
    end;
    if not S.Active and(Max(S.Solved.HandRelease[0],S.Solved.HandRelease[1])<0.01)then begin
      if LongSafe and(S.NextLook<=0)then begin
        S.Action:=raaLookBack;Inc(S.Events);
        if U.Waiting then S.Duration:=2.4+RandomUnit(S.Seed)*0.9
        else S.Duration:=1.75+RandomUnit(S.Seed)*0.5;
        if U.TargetValid then begin S.GoalYaw:=U.TargetYaw;S.GoalPitch:=U.TargetPitch end
        else begin
          S.GoalYaw:=90;if RandomUnit(S.Seed)<0.5 then S.GoalYaw:=-90;
          S.GoalPitch:=-2+4*RandomUnit(S.Seed);
        end;
        if U.Waiting then Limit:=100 else Limit:=90;
        S.GoalYaw:=EnsureRange(S.GoalYaw,-Limit,Limit);
        S.GoalPitch:=EnsureRange(S.GoalPitch,-12,14);
        S.GoalRoll:=-Sign(S.GoalYaw)*(1+RandomUnit(S.Seed)*2);
        if U.Waiting then S.NextLook:=7+RandomUnit(S.Seed)*9
        else if U.TargetValid then S.NextLook:=8+RandomUnit(S.Seed)*12
        else S.NextLook:=18+RandomUnit(S.Seed)*22;
      end else if S.NextAction<=0 then begin
        Choice:=RandomUnit(S.Seed);S.Side:=Ord(RandomUnit(S.Seed)>0.5);
        S.Action:=raaGlance;Inc(S.SmallEvents);S.Duration:=1.5+RandomUnit(S.Seed)*1.7;
        Amplitude:=(5+11*Relaxed)*S.Variation;
        S.GoalYaw:=(RandomUnit(S.Seed)*2-1)*Amplitude;
        S.GoalPitch:=(-3+6*RandomUnit(S.Seed))*(0.35+0.65*Relaxed);
        S.GoalRoll:=(-3.2+6.4*RandomUnit(S.Seed))*(0.3+0.7*Relaxed);
        if U.Waiting and(Choice>0.8)then begin
          S.GoalPitch:=-7-RandomUnit(S.Seed)*4;S.GoalYaw:=S.GoalYaw*0.5;
        end;
        if U.TargetValid and(Abs(U.TargetYaw)<45)and(Choice>0.5)then
          S.GoalYaw:=EnsureRange(U.TargetYaw,-25,25);
        if ComfortSafe and(S.NextRegrip<=0)and(Choice<0.3)then begin
          S.Action:=raaRegrip;S.Duration:=2.6+RandomUnit(S.Seed)*0.8;
          S.GoalYaw:=S.GoalYaw*0.3;S.GoalPitch:=-2;
          S.NextRegrip:=16+RandomUnit(S.Seed)*24;Inc(S.Regrips);
        end else if (Choice<0.52)and(Relaxed>0.35)and(Abs(U.LateralAccel)<0.65)then
          S.Action:=raaRelax;
        S.NextAction:=S.Duration+2.8+RandomUnit(S.Seed)*4.5+7*(1-Relaxed);
        if U.Waiting then S.NextAction:=S.Duration+1.8+RandomUnit(S.Seed)*4;
      end;
      if S.Action<>raaNone then begin S.Active:=True;S.Timer:=0 end;
    end;
  end;
  Goal:=Default(TRiderAttentionFrame);
  if U.Safe and not U.Waiting then Goal.Yaw:=EnsureRange(U.RoadYaw,-14,14);
  if S.Active then begin
    S.Timer:=S.Timer+Step;Ramp:=0.55;if U.Waiting then Ramp:=0.7;
    Envelope:=SmoothUnit(S.Timer/Ramp)*SmoothUnit((S.Duration-S.Timer)/Ramp);
    if (S.Action=raaLookBack)and U.TargetValid then begin
      { Keep the chosen side across atan2's rear +/-180 seam. }
      Yaw:=U.TargetYaw;
      while Yaw-S.GoalYaw>180 do Yaw:=Yaw-360;
      while Yaw-S.GoalYaw< -180 do Yaw:=Yaw+360;
      if U.Waiting then Limit:=100 else Limit:=90;
      S.GoalYaw:=Follow(S.GoalYaw,EnsureRange(Yaw,-Limit,Limit),0.3,45);
      S.GoalPitch:=Follow(S.GoalPitch,EnsureRange(U.TargetPitch,-12,14),0.3,20);
    end;
    Yaw:=S.GoalYaw;Pitch:=S.GoalPitch;Amplitude:=1;
    if S.Action<>raaLookBack then begin
      Amplitude:=0.3+0.7*Relaxed;
      if (U.SpeedKmh>45)or(Abs(U.LateralAccel)>1.4)then Amplitude:=Min(Amplitude,0.25);
      Yaw:=Yaw*Amplitude;Pitch:=Pitch*Amplitude;
    end;
    if S.Action=raaLookBack then Goal.Yaw:=Goal.Yaw*(1-Envelope)+Yaw*Envelope
    else Goal.Yaw:=Goal.Yaw+Yaw*Envelope;
    Goal.Pitch:=Pitch*Envelope;Goal.Roll:=S.GoalRoll*Envelope*Amplitude;
    TorsoEnvelope:=SmoothUnit((S.Timer-0.08)/(Ramp+0.12))*
      SmoothUnit((S.Duration-S.Timer)/(Ramp+0.08));
    if S.Action=raaLookBack then
      Goal.TorsoYaw:=RiderAttentionTorsoYaw(Yaw,U.Waiting)*TorsoEnvelope
    else Goal.TorsoYaw:=Yaw*0.10*TorsoEnvelope;
    if S.Action in [raaRelax,raaRegrip]then
      Goal.Shoulder[S.Side]:=-2.5*S.Variation*TorsoEnvelope*Relaxed;
    if S.Action=raaRegrip then begin
      Progress:=S.Timer/S.Duration;
      Goal.HandRelease[S.Side]:=SmoothUnit(Progress/0.20)*SmoothUnit((1-Progress)/0.25);
      Goal.HandSlide[S.Side]:=0.011*S.Variation*
        SmoothUnit((Progress-0.18)/0.25)*SmoothUnit((0.82-Progress)/0.25);
    end;
    if S.Timer>=S.Duration then begin S.Active:=False;S.Action:=raaNone end;
  end;
  S.Solved.Yaw:=Follow(S.Solved.Yaw,Goal.Yaw,0.12,180);
  S.Solved.Pitch:=Follow(S.Solved.Pitch,Goal.Pitch,0.16,50);
  S.Solved.Roll:=Follow(S.Solved.Roll,Goal.Roll,0.20,30);
  S.Solved.TorsoYaw:=Follow(S.Solved.TorsoYaw,Goal.TorsoYaw,0.20,65);
  S.Solved.Yaw:=EnsureRange(S.Solved.Yaw,S.Solved.TorsoYaw-RiderAttentionNeckYawLimit,
    S.Solved.TorsoYaw+RiderAttentionNeckYawLimit);
  for I:=0 to 1 do begin
    S.Solved.Shoulder[I]:=Follow(S.Solved.Shoulder[I],Goal.Shoulder[I],0.25,12);
    S.Solved.HandRelease[I]:=Follow(S.Solved.HandRelease[I],Goal.HandRelease[I],0.09,4);
    S.Solved.HandSlide[I]:=Follow(S.Solved.HandSlide[I],Goal.HandSlide[I],0.09,0.04);
  end;
end;
procedure StepRiderAttention(var State: TRiderAttentionState;
  const Input: TRiderAttentionInput; Dt: Single);
var T:Single;I:Integer;
begin
  if IsNan(Dt)or IsInfinite(Dt)then Exit;
  if Dt<=0 then Exit;
  Initialize(State,Input);
  State.Remainder:=State.Remainder+Min(Dt,0.25);
  while State.Remainder+1e-10>=Step do begin
    State.Previous:=State.Solved;Tick(State,Input);
    State.Remainder:=Max(0.0,State.Remainder-Step);
  end;
  T:=EnsureRange(State.Remainder/Step,0.0,1.0);
  State.Frame.Yaw:=State.Previous.Yaw+(State.Solved.Yaw-State.Previous.Yaw)*T;
  State.Frame.Pitch:=State.Previous.Pitch+(State.Solved.Pitch-State.Previous.Pitch)*T;
  State.Frame.Roll:=State.Previous.Roll+(State.Solved.Roll-State.Previous.Roll)*T;
  State.Frame.TorsoYaw:=State.Previous.TorsoYaw+(State.Solved.TorsoYaw-State.Previous.TorsoYaw)*T;
  for I:=0 to 1 do begin
    State.Frame.Shoulder[I]:=State.Previous.Shoulder[I]+(State.Solved.Shoulder[I]-State.Previous.Shoulder[I])*T;
    State.Frame.HandRelease[I]:=State.Previous.HandRelease[I]+(State.Solved.HandRelease[I]-State.Previous.HandRelease[I])*T;
    State.Frame.HandSlide[I]:=State.Previous.HandSlide[I]+(State.Solved.HandSlide[I]-State.Previous.HandSlide[I])*T;
  end;
end;
end.
