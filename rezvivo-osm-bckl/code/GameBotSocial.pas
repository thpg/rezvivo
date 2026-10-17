unit GameBotSocial;
{$mode objfpc}{$H+}
{ Small, replayable company planner. It proposes effort and a road line;
  the normal power physics and swept rider collision remain authoritative. }
interface
uses CastleVectors;
const SocialRiderCount=8; { avatar + seven companions, no crossing traffic }
type
  TSocialMode=(smSolo,smDraft,smPass,smPull,smYield,smAssist);
  TSocialRider=record
    Present,Moving,HandsAvailable:Boolean;
    Position,Forward:TVector3;
    Speed,Width,Offset,LateralAccel,Effort,Reserve:Single;
  end;
  TSocialRiders=array[0..SocialRiderCount-1]of TSocialRider;
  TSocialIntent=record
    Mode:TSocialMode;
    Partner,LookPartner:Integer;
    Time,Duration,Cooldown,HelpCooldown,Side,Suspended:Single;
    LookDelay,LookTime,LookCooldown,LookRest:Single;
    LookSerial:Cardinal;
    FollowSpeed,LineOffset:Single;
    Control,LineWanted:Boolean;
    Drafts,Changes,Helps,Looks:Cardinal;
  end;
  TBotSocialState=record
    Seed:Cardinal;
    Debt:Double;
    Riders:array[0..SocialRiderCount-1]of TSocialIntent;
    Helper,Recipient:Integer;
    AssistTime,AssistHold,AssistCooldown:Single;
  end;
procedure ResetBotSocial(var S:TBotSocialState;Seed:Cardinal);
procedure StepBotSocial(var S:TBotSocialState;const R:TSocialRiders;Dt:Single);
function SocialModeName(M:TSocialMode):String;
function SocialAssistSafe(const A,B:TSocialRider;Holding:Boolean=False):Boolean;
implementation
uses Math,RiderAttention;
const Tick=0.2;
function Rand(var S:TBotSocialState):Single;
begin
  S.Seed:=Cardinal((QWord(S.Seed)*1664525+1013904223)and $ffffffff);
  Result:=(S.Seed shr 8)/16777216;
end;
function Along(const A,B:TSocialRider):Single;
begin Result:=TVector3.DotProduct(B.Position-A.Position,A.Forward) end;
function Across(const A,B:TSocialRider):Single;
begin Result:=TVector3.DotProduct(B.Position-A.Position,Vector3(-A.Forward.Z,0,A.Forward.X)) end;
function PairNear(const A,B:TSocialRider;Range:Single):Boolean;
begin
  Result:=A.Present and B.Present and
    ((A.Position-B.Position).LengthSqr<Sqr(Range))and
    (Abs(A.Position.Y-B.Position.Y)<1.2)and
    (TVector3.DotProduct(A.Forward,B.Forward)>0.82);
end;
function RideSafe(const R:TSocialRider):Boolean;
begin Result:=R.Moving and(R.Speed>2.5)and(R.Speed<15)and(Abs(R.LateralAccel)<2.6)and(R.Effort<1.9) end;
function SocialAssistSafe(const A,B:TSocialRider;Holding:Boolean):Boolean;
var Gap,Side,H:Single;
begin
  Gap:=Along(A,B);Side:=Abs(Across(A,B));H:=Ord(Holding);
  Result:=PairNear(A,B,2)and RideSafe(A)and RideSafe(B)and
    (TVector3.DotProduct(A.Forward,B.Forward)>0.995-0.005*H)and
    A.HandsAvailable and B.HandsAvailable and(Min(A.Width,B.Width)>2.8)and
    (Max(A.Speed,B.Speed)<10.5)and(Abs(A.Speed-B.Speed)<0.65+0.15*H)and
    (Max(Abs(A.LateralAccel),Abs(B.LateralAccel))<0.65+0.45*H)and
    (Side>=0.94-0.035*H)and(Side<=1.10+0.05*H)and
    (Gap> -0.1-0.25*H)and(Gap<0.40+0.35*H);
end;
procedure ResetBotSocial(var S:TBotSocialState;Seed:Cardinal);
var I:Integer;
begin
  S:=Default(TBotSocialState);S.Seed:=Seed;S.Helper:=-1;S.Recipient:=-1;
  S.AssistCooldown:=12;
  for I:=0 to High(S.Riders)do begin
    S.Riders[I].Partner:=-1;S.Riders[I].LookPartner:=-1;
    S.Riders[I].Cooldown:=3+I*0.8;
    S.Riders[I].LookCooldown:=2+Rand(S)*5;
  end;
end;
procedure SetMode(var S:TBotSocialState;I,J:Integer;NewMode:TSocialMode);
begin
  with S.Riders[I]do begin
    Partner:=J;Mode:=NewMode;
    Time:=0;Duration:=24+Rand(S)*24;
    if Mode=smDraft then Inc(Drafts);
    if Mode=smPull then Inc(Changes);
  end;
end;
procedure Release(var S:TBotSocialState;I:Integer);
begin
  S.Riders[I].Mode:=smSolo;S.Riders[I].Partner:=-1;
  S.Riders[I].Control:=False;S.Riders[I].LineWanted:=False;
  S.Riders[I].Cooldown:=6+Rand(S)*12;
end;
procedure Greet(var S:TBotSocialState;I,J:Integer;Delay:Single;Waiting:Boolean);
var Variation:Single;
begin
  with S.Riders[I]do begin
    { A passing third rider must not restart a glance or chain several
      replies into an uninterrupted stare. Let the head return forward. }
    if(LookTime>0)or(LookRest>0)then Exit;
    Variation:=Rand(S);
    LookPartner:=J;LookDelay:=Delay;
    LookTime:=RiderAttentionLookDuration(Waiting,Variation);
    LookCooldown:=8+Variation*14;LookRest:=1.5;
    Inc(LookSerial);Inc(Looks);
  end;
end;
function PassingSide(const A,B:TSocialRider):Single;
var Offset,Edge:Single;
begin
  Result:=0;Offset:=B.Offset;Edge:=Min(A.Width,B.Width)*0.5-0.48;
  { Continue on the same side if already alongside: never cross the partner. }
  if Abs(Across(A,B))>0.55 then begin
    if Abs(Offset-Sign(Across(A,B))*0.98)<=Edge then Result:=-Sign(Across(A,B));
  end else if Offset-0.98>=-Edge then Result:=-1
  else if Offset+0.98<=Edge then Result:=1;
end;
procedure PlanTick(var S:TBotSocialState;const R:TSocialRiders);
var I,J,K,Best:Integer;Gap,Cost,BestCost,TargetGap,Side,PeerOffset:Single;
    Q:^TSocialIntent;Busy:Boolean;
begin
  S.AssistCooldown:=Max(0,S.AssistCooldown-Tick);
  for I:=0 to High(R)do begin
    Q:=@S.Riders[I];Q^.Control:=False;Q^.LineWanted:=False;
    Q^.Time:=Q^.Time+Tick;Q^.Cooldown:=Max(0,Q^.Cooldown-Tick);
    Q^.HelpCooldown:=Max(0,Q^.HelpCooldown-Tick);
    Q^.LookCooldown:=Max(0,Q^.LookCooldown-Tick);
    if(Q^.LookTime<=0)and(Q^.LookDelay<=0)then
      Q^.LookRest:=Max(0,Q^.LookRest-Tick);
    if Q^.LookDelay>0 then Q^.LookDelay:=Max(0,Q^.LookDelay-Tick)
    else Q^.LookTime:=Max(0,Q^.LookTime-Tick);
    J:=Q^.LookPartner;
    if(J>=0)then if not PairNear(R[I],R[J],22)then Q^.LookTime:=0;
    if not R[I].Present then begin Release(S,I);Q^.LookTime:=0;Continue end;
    { All riders, including the avatar, may return a glance. No avatar power,
      cadence, steering or recorded telemetry is changed by this planner. }
    if(Q^.LookCooldown<=0)and(Q^.LookTime<=0)and(Q^.LookRest<=0)and
      ((not R[I].Moving)or RideSafe(R[I]))then begin
      Best:=-1;BestCost:=1e9;
      for J:=0 to High(R)do if(J<>I)and PairNear(R[I],R[J],16)and
        ((not R[J].Moving)or RideSafe(R[J]))then begin
        Cost:=(R[I].Position-R[J].Position).LengthSqr+Rand(S)*20;
        if Cost<BestCost then begin Best:=J;BestCost:=Cost end;
      end;
      if Best>=0 then begin
        Greet(S,I,Best,0,not R[I].Moving);
        if S.Riders[Best].LookTime<=0 then
          Greet(S,Best,I,0.4+Rand(S)*0.4,not R[Best].Moving);
      end else Q^.LookCooldown:=2;
    end;
    if I=0 then Continue;
    if not RideSafe(R[I])then begin
      Q^.Suspended:=Q^.Suspended+Tick;
      if not R[I].Moving or(Q^.Suspended>4)then
        if Q^.Mode<>smSolo then Release(S,I);
      Continue;
    end;
    Q^.Suspended:=0;
    J:=Q^.Partner;
    if(J>=0)then if not PairNear(R[I],R[J],35)or not R[J].Moving then begin
      Release(S,I);J:=-1;
    end;
    if(Q^.Mode=smSolo)and(Q^.Cooldown<=0)and(R[I].Reserve>0.22)then begin
      Best:=-1;BestCost:=1e9;
      for J:=0 to High(R)do if(J<>I)and PairNear(R[I],R[J],24)and RideSafe(R[J])then begin
        Gap:=Along(R[I],R[J]);
        if(Gap<2.8)or(Gap>22)or(Abs(Across(R[I],R[J]))>3)then Continue;
        { One follower per wheel, no paired passes in opposite directions. }
        Busy:=S.Riders[J].Partner=I;
        for K:=1 to High(R)do if(K<>I)and(S.Riders[K].Partner=J)and
          (S.Riders[K].Mode<>smSolo)then Busy:=True;
        if Busy then Continue;
        Cost:=Gap+Abs(R[I].Speed-R[J].Speed)*5;
        if Cost<BestCost then begin Best:=J;BestCost:=Cost end;
      end;
      if Best>=0 then SetMode(S,I,Best,smDraft);
    end;
    J:=Q^.Partner;if(J<0)or(Q^.Mode=smSolo)then Continue;
    Gap:=Along(R[I],R[J]);PeerOffset:=R[J].Offset;
    if(Q^.Mode=smDraft)and(Q^.Time>Q^.Duration)then begin
      Side:=PassingSide(R[I],R[J]);
      if(Abs(Gap-3.2)<2)and(Side<>0)and(R[I].Reserve>0.45)and
        (Max(Abs(R[I].LateralAccel),Abs(R[J].LateralAccel))<1.0)then begin
        SetMode(S,I,J,smPass);Q^.Side:=Side;Greet(S,I,J,0,False);
      end else if Q^.Time>Q^.Duration+20 then Release(S,I);
    end;
    if Q^.Mode=smPass then begin
      if Gap< -3.3 then begin
        SetMode(S,I,J,smPull);
        if J>0 then SetMode(S,J,I,smDraft);
      end else if Q^.Time>24 then Release(S,I);
    end;
    if(Q^.Mode=smPull)and((Q^.Time>Q^.Duration)or(R[I].Reserve<0.3))then begin
      { A bot follower initiates the change itself. With the avatar, ease
        off beside its line and let the human keep their own effort. }
      if J=0 then begin
        Side:=PassingSide(R[I],R[J]);
        if Side<>0 then begin SetMode(S,I,J,smYield);Q^.Side:=Side end
        else Release(S,I);
      end else if Q^.Time>Q^.Duration+25 then Release(S,I);
    end;
    if Q^.Mode=smYield then begin
      if Gap>3.3 then SetMode(S,I,J,smDraft)
      else if Q^.Time>24 then Release(S,I);
    end;
    if Q^.Mode=smSolo then Continue;
    TargetGap:=3.2;Q^.LineOffset:=PeerOffset;
    case Q^.Mode of
      smPass:begin
        TargetGap:=-4.3;Q^.LineOffset:=PeerOffset+Q^.Side*0.98;
        if(S.AssistCooldown<=0)and(Q^.HelpCooldown<=0)and(Q^.Time<18)then
          TargetGap:=0.18;
      end;
      smPull:begin
        TargetGap:=-4.3;
        { Keep our current lead line. A follower pulling out must not drag
          its leader sideways with it. }
        Q^.LineOffset:=R[I].Offset;
      end;
      smYield:begin TargetGap:=4.0;Q^.LineOffset:=PeerOffset+Q^.Side*0.98 end;
      smAssist:begin TargetGap:=0.18;Q^.LineOffset:=PeerOffset+Q^.Side*0.98 end;
    end;
    Q^.FollowSpeed:=Max(0,R[J].Speed+EnsureRange((Gap-TargetGap)*0.32,-1.0,1.2));
    Q^.Control:=True;Q^.LineWanted:=True;
  end;
  { One contact pair at a time. Its recipient is animated before the helper,
    so the palm tracks the current back rather than a stale pose. }
  if S.Helper>=0 then begin
    I:=S.Helper;J:=S.Recipient;S.AssistTime:=S.AssistTime+Tick;
    if not SocialAssistSafe(R[I],R[J],True)or(S.AssistTime>0.65+S.AssistHold)then begin
      if S.Riders[I].Mode=smAssist then begin
        SetMode(S,I,J,smPass);
      end;
      S.Helper:=-1;S.Recipient:=-1;S.AssistCooldown:=35+Rand(S)*30;
    end;
  end else if S.AssistCooldown<=0 then begin
    for I:=1 to High(R)do begin
      J:=S.Riders[I].Partner;
      if(J<0)or(S.Riders[I].Mode<>smPass)or(S.Riders[I].HelpCooldown>0)then Continue;
      if SocialAssistSafe(R[I],R[J])then begin
        S.Helper:=I;S.Recipient:=J;S.AssistTime:=0;S.AssistHold:=2+Rand(S);
        S.Riders[I].HelpCooldown:=70+Rand(S)*60;Inc(S.Riders[I].Helps);
        SetMode(S,I,J,smAssist);Greet(S,I,J,0,False);Greet(S,J,I,0.5,False);
        Break;
      end;
    end;
  end;
end;
procedure StepBotSocial(var S:TBotSocialState;const R:TSocialRiders;Dt:Single);
begin
  if(Dt<=0)or IsNan(Dt)or IsInfinite(Dt)then Exit;
  S.Debt:=S.Debt+Min(Dt,0.5);
  while S.Debt+1e-7>=Tick do begin S.Debt:=Max(0,S.Debt-Tick);PlanTick(S,R) end;
end;
function SocialModeName(M:TSocialMode):String;
const Names:array[TSocialMode]of String=('solo','draft','pass','pull','yield','help');
begin Result:=Names[M] end;
end.
