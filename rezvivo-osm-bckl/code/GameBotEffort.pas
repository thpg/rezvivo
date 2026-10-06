unit GameBotEffort;
{$mode objfpc}{$H+}
interface
type
  TBotEffortMode=(bemCruise,bemChase,bemOvertake,bemAttack,bemRecover);
  TBotEffortInput=record
    SustainableWatts,CapacitySeconds,RecoverySeconds,Aggression:Single;
    Gap,Speed,RiderSpeed:Single; { gap positive = ahead of the rider }
    Racing,UnderPressure:Boolean;
  end;
  TBotEffortState=record
    Mode:TBotEffortMode;
    Energy,Fatigue,PowerWatts,ModeTime,ModeDuration,Variation:Single;
    TickDebt:Double;
    RandomState:Cardinal;
    Chases,Overtakes,Attacks,Recoveries:Integer;
  end;
procedure ResetBotEffort(var State:TBotEffortState;Seed:Cardinal;InitialPower:Single);
function StepBotEffort(var State:TBotEffortState;const Input:TBotEffortInput;Dt:Single):Single;
function BotEffortModeName(Mode:TBotEffortMode):String;
implementation
uses Math;
function NextRandom(var State:TBotEffortState):Single;
var R:Cardinal;
begin
  R:=State.RandomState;R:=R xor(R shl 13);R:=R xor(R shr 17);R:=R xor(R shl 5);
  State.RandomState:=R;Result:=(R and $FFFFFF)/16777216.0;
end;
procedure ChangeMode(var S:TBotEffortState;Mode:TBotEffortMode);
begin
  S.Mode:=Mode;S.ModeTime:=0;S.Variation:=0.97+0.06*NextRandom(S);
  case Mode of
    bemCruise:S.ModeDuration:=18+35*NextRandom(S);
    bemChase:begin S.ModeDuration:=55+40*NextRandom(S);Inc(S.Chases) end;
    bemOvertake:begin S.ModeDuration:=18+16*NextRandom(S);Inc(S.Overtakes) end;
    bemAttack:begin S.ModeDuration:=18+18*NextRandom(S);Inc(S.Attacks) end;
    bemRecover:begin S.ModeDuration:=50+50*NextRandom(S);Inc(S.Recoveries) end;
  end;
end;
procedure ResetBotEffort(var State:TBotEffortState;Seed:Cardinal;InitialPower:Single);
begin
  State:=Default(TBotEffortState);State.RandomState:=Seed;
  if State.RandomState=0 then State.RandomState:=1;
  State.Energy:=0.82+0.16*NextRandom(State);
  State.PowerWatts:=Max(0,InitialPower);ChangeMode(State,bemCruise);
end;
procedure EffortTick(var S:TBotEffortState;const V:TBotEffortInput);
const Dt=0.5;
var CP,Target,Ratio,Capacity,Recharge:Single;
begin
  S.ModeTime:=S.ModeTime+Dt;
  CP:=Max(30,V.SustainableWatts)*(1-0.12*S.Fatigue);
  if (S.Energy<0.18)and(S.Mode<>bemRecover)then ChangeMode(S,bemRecover);
  if not V.Racing and(S.Mode in[bemChase,bemOvertake,bemAttack])then ChangeMode(S,bemCruise);
  case S.Mode of
    bemRecover:
      if (S.ModeTime>=S.ModeDuration)and(S.Energy>=0.76)then ChangeMode(S,bemCruise);
    bemChase:
      if (V.Gap>=-18)and(S.Energy>0.38)then ChangeMode(S,bemOvertake)
      else if S.ModeTime>=S.ModeDuration then ChangeMode(S,bemRecover);
    bemOvertake:
      if V.Gap>8 then begin
        if(S.Energy>0.48)and(NextRandom(S)<0.40+0.45*V.Aggression)then ChangeMode(S,bemAttack)
        else ChangeMode(S,bemCruise);
      end else if S.ModeTime>=S.ModeDuration then ChangeMode(S,bemRecover);
    bemAttack:
      if(S.ModeTime>=S.ModeDuration)or(S.Energy<0.28)then ChangeMode(S,bemRecover);
    bemCruise:begin
      if V.Racing and(S.ModeTime>6)and(S.Energy>0.45)and(V.Gap< -14)then ChangeMode(S,bemChase)
      else if S.ModeTime>=S.ModeDuration then begin
        if V.Racing and(S.Energy>0.68)and(Abs(V.Gap)<100)and
           (NextRandom(S)<0.35+0.45*V.Aggression+0.15*Ord(V.UnderPressure))then begin
          if V.Gap<5 then ChangeMode(S,bemOvertake)else ChangeMode(S,bemAttack);
        end else if S.Energy<0.50 then ChangeMode(S,bemRecover)
        else ChangeMode(S,bemCruise);
      end;
    end;
  end;
  case S.Mode of
    bemCruise:begin
      Ratio:=0.89*S.Variation;
      { A rider well clear of the group settles into an easier tempo. Stronger
        riders can still stay away; no velocity or position correction. }
      if V.Racing and(V.Gap>100)then Ratio:=0.78*S.Variation;
    end;
    bemChase:Ratio:=1.16+EnsureRange(-V.Gap/450,Single(0),Single(0.26))+
      EnsureRange((V.RiderSpeed-V.Speed)*0.025,Single(0),Single(0.10));
    bemOvertake:Ratio:=(1.32+0.15*V.Aggression)*S.Variation;
    bemAttack:Ratio:=(1.52+0.22*V.Aggression)*S.Variation;
    bemRecover:begin
      Ratio:=0.61*S.Variation;
      if V.Gap< -120 then Ratio:=0.72*S.Variation;
    end;
  end;
  Target:=Min(CP*Ratio,CP*(1+0.95*Sqrt(Max(0,S.Energy))));
  { Small control cadence, gradual power changes; no per-frame random work. }
  S.PowerWatts:=S.PowerWatts+EnsureRange((Target-S.PowerWatts)*(1-Exp(-Dt/2.5)),Single(-10),Single(10));
  S.PowerWatts:=EnsureRange(S.PowerWatts,Single(0),Single(1000));
  Capacity:=Max(1,V.SustainableWatts*V.CapacitySeconds);
  if S.PowerWatts>CP then S.Energy:=S.Energy-(S.PowerWatts-CP)*Dt/Capacity
  else begin
    Recharge:=EnsureRange((CP-S.PowerWatts)/(CP*0.35),Single(0),Single(1));
    S.Energy:=S.Energy+(1-S.Energy)*(1-Exp(-Dt*Recharge/Max(20,V.RecoverySeconds)));
  end;
  S.Energy:=EnsureRange(S.Energy,Single(0),Single(1));
  Ratio:=S.PowerWatts/Max(30,V.SustainableWatts);
  { Reserve recovers in about a minute; accumulated fatigue lasts longer.
    Repeated attacks must not be erased by a short recovery interval. }
  S.Fatigue:=EnsureRange(S.Fatigue+Dt*(Max(0,Ratio-0.82)/450-
    Max(0,0.82-Ratio)/900),Single(0),Single(1));
end;
function StepBotEffort(var State:TBotEffortState;const Input:TBotEffortInput;Dt:Single):Single;
begin
  if Dt>0 then State.TickDebt:=State.TickDebt+Dt;
  while State.TickDebt+1e-7>=0.5 do begin
    State.TickDebt:=Max(0,State.TickDebt-0.5);EffortTick(State,Input);
  end;
  Result:=State.PowerWatts;
end;
function BotEffortModeName(Mode:TBotEffortMode):String;
const Names:array[TBotEffortMode]of String=('cruise','chase','overtake','attack','recover');
begin Result:=Names[Mode] end;
end.
