unit GameRideJournalRecovery;
{$mode objfpc}{$H+}
interface
uses fpjson,GameSensorLog;

{ Reconcile the single durable journal with an older checkpoint. No telemetry
  is appended, and the captured rider/camera position is left untouched. }
function RecoverJournalTail(Activity:TJSONObject;
  const Rows:TSensorSessionRecordArray):Boolean;

implementation
uses SysUtils,Math,DateUtils,GameTrainingLoad;

type
  TRecoveryDay=record
    State:TJSONObject;
    Load:TTrainingLoad;
    BaseTSS:Double;
  end;

function RecoverJournalTail(Activity:TJSONObject;
  const Rows:TSensorSessionRecordArray):Boolean;
var
  Resume,Daily,Rider,Workout,O:TJSONObject;
  Days:array of TRecoveryDay;
  DayStates:TJSONArray;
  Load:TTrainingLoad;
  I,J,K,SavedDay,FinalDay:Integer;
  StartClock,EndClock,Dt,FullDt,StartPart,Work,Timer,Distance,PowerSeconds,Ftp:Double;
  StartWall,EndWall,Boundary:TDateTime;
  Fraction,Piece:Double;
  Active,Valid,UnknownDay:Boolean;

  function Running(const R:TSensorSessionRecord):Boolean;
  begin Result:=not R.HasSessionState or R.TimerActive;end;

  function DayIndex(Day:Integer):Integer;
  var N:Integer;
  begin
    for N:=0 to High(Days)do
      if Days[N].State.Get('day',0)=Day then Exit(N);
    N:=Length(Days);SetLength(Days,N+1);
    Days[N].Load:=TTrainingLoad.Create;
    if Day=SavedDay then begin
      Days[N].State:=Daily.Clone as TJSONObject;
      if Daily.Find('load')is TJSONObject then Days[N].Load.RestoreState(Daily.Objects['load']);
      Days[N].BaseTSS:=Max(Double(0),Daily.Get('tss',0.0)-Days[N].Load.TSS);
    end else begin
      Days[N].State:=TJSONObject.Create(['account',Daily.Get('account',''),
        'day',Day,'source','','revision',0,'work',0.0,'tss',0.0,'ftp',Ftp]);
      Days[N].BaseTSS:=0;
    end;
    Days[N].State.Delete('recovered_days');
    Days[N].State.Booleans['recovery_max']:=True;
    Result:=N;
  end;

  procedure AddDay(Day:Integer;Seconds:Double;Power:Word;IsRunning:Boolean);
  var N:Integer;
  begin
    if Day<SavedDay then begin UnknownDay:=True;Exit;end;
    N:=DayIndex(Day);FinalDay:=Max(FinalDay,Day);
    Days[N].Load.Step(Power,Seconds,Ftp,IsRunning,Power<>$FFFF);
    if IsRunning and(Power<>$FFFF)then
      Days[N].State.Floats['work']:=Days[N].State.Get('work',0.0)+Power*Seconds;
    Days[N].State.Floats['tss']:=Days[N].BaseTSS+Days[N].Load.TSS;
  end;

begin
  Result:=False;
  if(Activity=nil)or(Length(Rows)<2)then Exit;
  StartClock:=Activity.Get('journal_elapsed',0.0);
  EndClock:=Rows[High(Rows)].ElapsedSec;
  if IsNan(StartClock)or IsInfinite(StartClock)or(StartClock<0)or
    IsNan(EndClock)or IsInfinite(EndClock)or(EndClock<=StartClock)then Exit;
  { A partial/tail reader must include the checkpoint's preceding sample. }
  if Rows[0].ElapsedSec>StartClock then Exit;
  if not(Activity.Find('resume')is TJSONObject)then Exit;
  Resume:=Activity.Objects['resume'];
  if not(Resume.Find('daily')is TJSONObject)then Exit;
  Daily:=Resume.Objects['daily'];SavedDay:=Daily.Get('day',0);
  if SavedDay<=0 then Exit;
  for I:=1 to High(Rows)do
    if IsNan(Rows[I].ElapsedSec)or IsInfinite(Rows[I].ElapsedSec)or
      (Rows[I].ElapsedSec<Rows[I-1].ElapsedSec)then Exit;
  Load:=TTrainingLoad.Create;DayStates:=nil;
  try
    if Activity.Find('load')is TJSONObject then Load.RestoreState(Activity.Objects['load']);
    Ftp:=Daily.Get('ftp',0.0);
    if IsNan(Ftp)or IsInfinite(Ftp)or(Ftp<0)then Ftp:=0;
    Work:=0;Timer:=0;Distance:=0;PowerSeconds:=0;
    UnknownDay:=False;FinalDay:=SavedDay;
    DayIndex(SavedDay);
    for I:=1 to High(Rows)do begin
      if Rows[I].ElapsedSec<=StartClock then Continue;
      FullDt:=Rows[I].ElapsedSec-Rows[I-1].ElapsedSec;
      StartPart:=Max(StartClock,Rows[I-1].ElapsedSec);
      Dt:=Rows[I].ElapsedSec-StartPart;
      Active:=Running(Rows[I-1]);Valid:=Rows[I-1].Power<>$FFFF;
      Load.Step(Rows[I-1].Power,Dt,Ftp,Active,Valid);
      if Active then begin
        Timer:=Timer+Dt;
        if Valid then begin Work:=Work+Rows[I-1].Power*Dt;PowerSeconds:=PowerSeconds+Dt;end;
        if FullDt>0 then Distance:=Distance+
          Max(Double(0),Double(Rows[I].DistanceM)-Rows[I-1].DistanceM)*(Dt/FullDt);
      end;
      { Legacy hh:mm:ss has no reliable date after a resume on another day.
        Preserve its journal/history but do not guess a daily contribution. }
      if not Rows[I].HasLocalTimestamp or not Rows[I-1].HasLocalTimestamp then begin
        UnknownDay:=True;Continue;
      end;
      StartWall:=Rows[I-1].LocalTimestamp;EndWall:=Rows[I].LocalTimestamp;
      if(FullDt>0)and(EndWall>StartWall)then
        StartWall:=StartWall+(EndWall-StartWall)*((StartPart-Rows[I-1].ElapsedSec)/FullDt);
      if(EndWall<=StartWall)or(Trunc(StartWall)=Trunc(EndWall))then
        AddDay(Trunc(EndWall),Dt,Rows[I-1].Power,Active)
      else begin
        { CSV records carry real wall dates, while Dt remains ride time. }
        while(StartWall<EndWall)and(Dt>0)do begin
          { Mixed integer/real Min overloads can select Single in FPC,
            rounding sub-day dates to midnight and preventing progress. }
          Boundary:=Trunc(StartWall)+1;
          if EndWall<Boundary then Boundary:=EndWall;
          Fraction:=(Boundary-StartWall)/(EndWall-StartWall);
          Piece:=Dt*Fraction;
          AddDay(Trunc(StartWall),Piece,Rows[I-1].Power,Active);
          Dt:=Max(Double(0),Dt-Piece);StartWall:=Boundary;
        end;
      end;
    end;
    I:=High(Rows);
    Load.Step(Rows[I].Power,0,Ftp,Running(Rows[I]),Rows[I].Power<>$FFFF);
    if Rows[I].HasLocalTimestamp then AddDay(Trunc(Rows[I].LocalTimestamp),0,
      Rows[I].Power,Running(Rows[I]));
    Activity.Floats['seconds']:=Activity.Get('seconds',0.0)+Timer;
    Activity.Floats['work_j']:=Activity.Get('work_j',0.0)+Work;
    Activity.Floats['distance_m']:=Activity.Get('distance_m',0.0)+Distance;
    Activity.Floats['power_seconds']:=Activity.Get('power_seconds',0.0)+PowerSeconds;
    Activity.Booleans['has_power']:=Activity.Get('power_seconds',0.0)>0;
    if Activity.Get('power_seconds',0.0)>0 then
      Activity.Floats['avg_power']:=Activity.Get('work_j',0.0)/Activity.Get('power_seconds',0.0);
    Activity.Floats['tss']:=Load.TSS;
    Activity.Delete('load');Activity.Add('load',Load.SaveState);
    Activity.Floats['journal_elapsed']:=EndClock;
    Activity.Booleans['recovered_journal_tail']:=True;
    if UnknownDay then Activity.Booleans['recovery_daily_wall_unknown']:=True;
    DayStates:=TJSONArray.Create;J:=-1;
    for K:=0 to High(Days)do begin
      Days[K].State.Delete('load');Days[K].State.Add('load',Days[K].Load.SaveState);
      if Days[K].State.Get('day',0)=FinalDay then J:=K;
      DayStates.Add(Days[K].State.Clone);
    end;
    O:=Days[J].State.Clone as TJSONObject;O.Add('recovered_days',DayStates);DayStates:=nil;
    Resume.Delete('daily');Resume.Add('daily',O);
    if Resume.Find('rider')is TJSONObject then begin
      Rider:=Resume.Objects['rider'];
      if Rider.Find('sim_position')<>nil then Rider.Floats['sim_accounted']:=
        Rider.Get('sim_accounted',Rider.Get('sim_position',0.0))+(EndClock-StartClock);
    end;
    if Resume.Find('workout')is TJSONObject then begin
      Workout:=Resume.Objects['workout'];
      Workout.Integers['journal_lap']:=Max(Workout.Get('journal_lap',0),Rows[High(Rows)].Lap);
    end;
    Result:=True;
  finally
    DayStates.Free;Load.Free;
    for K:=0 to High(Days)do begin Days[K].State.Free;Days[K].Load.Free;end;
  end;
end;
end.
