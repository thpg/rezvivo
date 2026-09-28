unit GameAudioCues;
{$mode objfpc}{$H+}
interface
uses CastleVectors,GameWorkoutPlayer;
type
  TWorkoutAudioCue=(wacNone,wacCount,wacStart);
  TWorkoutAudioClock=class
  private
    FKnown:Boolean;
    FRevision:QWord;
    FIndex,FBucket:Integer;
    FRunning,FIncoming:Boolean;
  public
    procedure Reset;
    function Step(Player:TWorkoutPlayer;Advancing:Boolean):TWorkoutAudioCue;
  end;
  TWheelAudioContact=record
    Known:Boolean;
    Position:TVector3;
    Grade,Cooldown,Deviation:Single;
  end;
function WheelAudioImpact(var Contact:TWheelAudioContact;const P:TVector3;
  Valid:Boolean;Speed,GradeHint:Single):Single;
implementation
uses Math,WorkoutFile;
procedure TWorkoutAudioClock.Reset;
begin FKnown:=False;FRunning:=False;FIncoming:=False;FBucket:=4;end;
function TWorkoutAudioClock.Step(Player:TWorkoutPlayer;Advancing:Boolean):TWorkoutAudioCue;
var Incoming,Running,ResetClock:Boolean;Bucket:Integer;Current,Next:TWorkoutSegment;
    CurrentPower,NextPower:Double;
begin
  Result:=wacNone;
  if(Player=nil)or(Player.Plan=nil)then begin Reset;Exit;end;
  Running:=(Player.State=wsRunning)and Advancing and not Player.SignalLost;
  Incoming:=False;
  if(Player.Index+1<Player.Plan.Segments.Count)and(Player.Stage<>nil)then begin
    Current:=Player.Stage;Next:=Player.Plan.Segments[Player.Index+1];
    CurrentPower:=Current.PowerLow;
    if Current.Kind in[wskWarmup,wskCooldown,wskRamp]then CurrentPower:=Current.PowerHigh;
    NextPower:=Next.PowerLow;
    Incoming:=(Next.Kind<>wskFreeRide)and(Next.Kind<>wskCooldown)and
      (NextPower>=0.65)and(NextPower>CurrentPower+0.035);
  end;
  Bucket:=Ceil(Player.StageRemaining-1e-6);
  ResetClock:=not FKnown or(FRevision<>Player.Revision);
  if not ResetClock and Running and FRunning then begin
    if(Player.Index=FIndex+1)and FIncoming then Result:=wacStart
    else if(Player.Index=FIndex)and Incoming and(Bucket>=1)and(Bucket<=3)and
      (Bucket<FBucket)then Result:=wacCount;
  end;
  { Rebasing on pause/resume/skip avoids a burst of missed beeps. }
  FKnown:=True;FRevision:=Player.Revision;FIndex:=Player.Index;
  FBucket:=Bucket;FRunning:=Running;FIncoming:=Incoming;
end;
function WheelAudioImpact(var Contact:TWheelAudioContact;const P:TVector3;
  Valid:Boolean;Speed,GradeHint:Single):Single;
var D,DX,DZ,DY,Residual,Alpha:Single;
begin
  Result:=0;
  if not Valid then begin Contact.Known:=False;Exit;end;
  if not Contact.Known then begin
    Contact.Known:=True;Contact.Position:=P;Contact.Grade:=GradeHint;Contact.Cooldown:=0;Contact.Deviation:=0;Exit;
  end;
  DX:=P.X-Contact.Position.X;DZ:=P.Z-Contact.Position.Z;D:=Sqrt(DX*DX+DZ*DZ);
  if D<0.015 then Exit;
  DY:=P.Y-Contact.Position.Y;Contact.Position:=P;
  if(D>Max(1.2,Speed*0.18))or(Abs(DY)>0.5)or(Speed<0.7)then begin
    Contact.Grade:=GradeHint;Contact.Cooldown:=0;Contact.Deviation:=0;Exit;
  end;
  Contact.Cooldown:=Max(0,Contact.Cooldown-D);
  { Integrate a short spatial window: the baked 7.5 cm, 1 m long rounded
    hump must also be heard at low speed, when each sample rises by mm. }
  if Contact.Cooldown=0 then
    Contact.Deviation:=Contact.Deviation*Exp(-D/0.65)+DY-Contact.Grade*D
  else Contact.Deviation:=0;
  Residual:=Abs(Contact.Deviation);
  if(Contact.Cooldown=0)and(Residual>0.026)and(Abs(DY/D-Contact.Grade)>0.065)then begin
    Result:=EnsureRange((Residual-0.018)*6,0.10,1.0)*EnsureRange(Speed/4,0.25,1.0);
    Contact.Cooldown:=1.6;Contact.Deviation:=0;
  end;
  Alpha:=1-Exp(-D/2.0);
  Contact.Grade:=Contact.Grade+(EnsureRange(DY/D,-0.5,0.5)-Contact.Grade)*Alpha;
end;
end.
