unit GameBotCompanyMotion;
{$mode objfpc}{$H+}

{ Companion behaviour has its own clock, independent of rendering and power
  tactics. Stopping uses the normal cycling brakes, never a path teleport. }
interface
uses GameAgentControllers, GameAgentControl;
type
  TBotWaitMode = (bwmBeforeStart, bwmRiding, bwmApproaching, bwmWaiting);
  TBotWaitState = record
    Mode: TBotWaitMode;
    Seed: Cardinal;
    StopDistance: Double;
    ResumeDelay, StoppedTime, StalledTime: Single;
  end;
  TBotWaitInput = record
    Started, RiderMoving: Boolean;
    Distance: Double;
    Gap, Speed, Mass, GradeDeg: Single;
    RidingPower: Single;
  end;
  TBotWaitControl = record
    Power, BrakeForce: Single;
    Enabled: Boolean;
  end;
  TLocalBotController = class(TPowerController)
  public
    BrakeForce: Single;
    procedure UpdateControl(const SecondsPassed: Single;
      var Input: TAgentControlInput); override;
  end;

procedure ResetBotWait(var State: TBotWaitState; Seed: Cardinal);
function StepBotWait(var State: TBotWaitState; const Input: TBotWaitInput;
  Dt: Single): TBotWaitControl;
function BotWaitModeName(Mode: TBotWaitMode): string;

implementation
uses Math;

function RandomUnit(var Seed: Cardinal): Single;
begin
  Seed:=Cardinal((QWord(Seed)*1664525+1013904223) and $ffffffff);
  Result:=(Seed shr 8)/16777216;
end;

procedure ResetBotWait(var State: TBotWaitState; Seed: Cardinal);
begin
  State:=Default(TBotWaitState);State.Seed:=Seed;
  State.ResumeDelay:=0.2+RandomUnit(State.Seed)*1.4;
end;

function BotWaitModeName(Mode: TBotWaitMode): string;
begin
  case Mode of
    bwmBeforeStart: Result:='before_start';
    bwmRiding: Result:='riding';
    bwmApproaching: Result:='approaching_stop';
    bwmWaiting: Result:='waiting';
  end;
end;

function StepBotWait(var State: TBotWaitState; const Input: TBotWaitInput;
  Dt: Single): TBotWaitControl;
var Remaining, TargetSpeed, Decel: Single;
begin
  Result:=Default(TBotWaitControl);
  if (Dt<=0)or IsNan(Dt)or IsInfinite(Dt) then Exit;
  if not Input.Started then begin
    State.Mode:=bwmBeforeStart;Exit;
  end;
  if Input.RiderMoving then begin
    State.StoppedTime:=0;State.StalledTime:=0;
    if State.Mode<>bwmRiding then begin
      State.ResumeDelay:=Max(0.0,State.ResumeDelay-Dt);
      if State.ResumeDelay<=0 then State.Mode:=bwmRiding;
    end;
  end else begin
    State.StoppedTime:=State.StoppedTime+Dt;
    if (State.Mode=bwmRiding)and(State.StoppedTime>=0.75) then begin
      State.Mode:=bwmApproaching;
      { At least a comfortable braking distance from the bot's current
        point; riders still behind continue past the player before waiting. }
      State.StopDistance:=Max(Input.Distance+Max(7.0,Sqr(Input.Speed)/2.2),
        Input.Distance-Input.Gap+14+RandomUnit(State.Seed)*28);
      State.ResumeDelay:=0.25+RandomUnit(State.Seed)*1.5;
    end;
  end;
  case State.Mode of
    bwmBeforeStart,bwmWaiting: Exit;
    bwmRiding: begin
      Result.Enabled:=True;Result.Power:=Input.RidingPower;
    end;
    bwmApproaching: begin
      Remaining:=State.StopDistance-Input.Distance;
      if Input.Speed<0.18 then State.StalledTime:=State.StalledTime+Dt
      else State.StalledTime:=0;
      { A narrow lane can leave no safe way around the stopped player.
        Wait there instead of pedalling forever against collision avoidance. }
      if State.StalledTime>=3.0 then begin
        State.StopDistance:=Input.Distance;State.Mode:=bwmWaiting;Exit;
      end;
      if (Remaining<0.65)and(Input.Speed<0.18) then begin
        State.Mode:=bwmWaiting;Exit;
      end;
      Result.Enabled:=True;
      TargetSpeed:=Min(7.0,Sqrt(Max(0.0,2*1.1*(Remaining-0.25))));
      { Feedback includes downhill gravity, so waiting also works on slopes.
        Uphill, a little power prevents stopping short of the chosen place. }
      Decel:=(Input.Speed-TargetSpeed)/0.4-9.80665*Sin(DegToRad(Input.GradeDeg));
      if Input.Speed>TargetSpeed-0.15 then
        Result.BrakeForce:=Max(1.0,Input.Mass)*EnsureRange(Decel,0.0,5.0)
      else Result.Power:=Min(Input.RidingPower,Max(50.0,Input.Mass*2));
    end;
  end;
end;

procedure TLocalBotController.UpdateControl(const SecondsPassed: Single;
  var Input: TAgentControlInput);
begin
  inherited;
  Input.BrakeForceN:=Max(0.0,BrakeForce);
end;
end.
