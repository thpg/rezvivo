program ActivityAccountingTests;
{$mode objfpc}{$H+}
uses SysUtils,Classes,Math,DateUtils,fpjson,GameActivityAccounting,GameRideHistory,
  GameDailyTraining,GameSensorLog,GameWorkoutPlayer,GameUserData,WorkoutFile,TrainerData;

procedure Check(Value:Boolean;const MessageText:String);
begin if not Value then raise Exception.Create(MessageText);end;
procedure CloseTo(Value,Expected:Double;const MessageText:String);
begin Check(Abs(Value-Expected)<0.001,MessageText+Format(': %.6f <> %.6f',[Value,Expected]));end;

procedure CheckPolicy;
var A:TActivityAccounting;P:TMeasuredPower;Raw,Delta:Double;HasRaw:Boolean;
begin
  P:=MeasuredPower(True,0.1,190);
  A:=ActivityAccounting(True,False,False,False,0,P);
  Check(A.Running and A.Power.Valid,'stationary fresh power must count');
  Check(JournalPower(P)=190,'measured power must not depend on optional cadence');
  A:=ActivityAccounting(True,False,True,False,5,P);
  Check(not A.Running,'ready/paused workout counted despite moving and pedalling');
  A:=ActivityAccounting(True,True,False,False,5,P);Check(not A.Running,'explicit playback pause counted');
  A:=ActivityAccounting(False,False,False,False,5,P);Check(not A.Running,'loading/restoring counted');
  A:=ActivityAccounting(True,False,True,True,0,MeasuredPower(True,0.1,0));
  Check(A.Running,'running recovery interval must keep timer at zero power');
  P:=MeasuredPower(True,3.01,190);Check(not P.Valid and(JournalPower(P)=$FFFF),'held power not unknown');
  A:=ActivityAccounting(True,False,False,False,0,P);Check(not A.Running,'stationary stale power counted');
  A:=ActivityAccounting(True,False,False,False,5,P);Check(A.Running,'coasting timer stopped with lost power');
  Check(not MeasuredPower(False,0,190).Valid,'disconnected sensor remained valid');
  Check(not MeasuredPower(True,0,NaN).Valid,'NaN power counted');
  Check(not MeasuredPower(True,0,Infinity).Valid,'infinite power counted');
  Check(not MeasuredPower(True,0,65535).Valid,'unknown sentinel counted');
  Raw:=100;HasRaw:=True;
  Delta:=ActiveDistanceDelta(110,True,Raw,HasRaw);CloseTo(Delta,10,'active distance');
  Delta:=ActiveDistanceDelta(200,False,Raw,HasRaw);CloseTo(Delta,0,'paused distance');
  Delta:=ActiveDistanceDelta(205,True,Raw,HasRaw);CloseTo(Delta,5,'paused distance charged on resume');
  Delta:=ActiveDistanceDelta(50,False,Raw,HasRaw);CloseTo(Delta,0,'seek baseline');
  Delta:=ActiveDistanceDelta(52,True,Raw,HasRaw);CloseTo(Delta,2,'seek replay distance');
  Writeln('PASS activity policy: stationary watts, cadence-independent power, missing/coasting, pauses, distance');
end;

procedure RecordStep(Seconds,RawDistance:Double;Ready,Running:Boolean;Speed:Double;
  const P:TMeasuredPower);
var A:TActivityAccounting;
begin
  A:=ActivityAccounting(True,False,Ready,Running,Speed,P);
  RideHistory.Step(Seconds,RawDistance,10,A.Power.Watts,220,A.Running,A.Power.Valid);
  DailyTraining.Step(A.Power.Watts,Seconds,Seconds,220,A.Running,A.Power.Valid,Now);
end;

procedure WriteRecovery(const Mode:String);
var W:TWorkoutFile;D:TTrainerDataRecord;I:Integer;Raw,Work:Double;
begin
  RideHistory.BeginRide('accounting-test','accounting.gpx','accounting-world');
  DailyTraining.BeginRide;RideHistory.RebaseDistance(0);
  W:=TWorkoutFile.Create;W.Name:='accounting';
  with W.AddSegment(wskSteady)do begin Duration:=600;PowerLow:=0.9;PowerHigh:=0.9 end;
  WorkoutPlayer.Start(W,220,False,True);W.Free;
  WorkoutPlayer.Step(60,True,True,True);
  for I:=1 to 60 do RecordStep(1,0,True,True,0,MeasuredPower(True,0,190));
  CloseTo(DailyTraining.WorkJoules,11400,'60 seconds stationary daily work');
  WorkoutPlayer.Pause;
  for I:=1 to 10 do RecordStep(1,I*5,True,False,5,MeasuredPower(True,0,190));
  CloseTo(DailyTraining.WorkJoules,11400,'paused pedalling daily work');Raw:=50;Work:=11400;
  if Mode='active' then begin
    WorkoutPlayer.Resume;WorkoutPlayer.Step(10,True,True,True);
    for I:=1 to 10 do RecordStep(1,50+I*2,True,True,2,MeasuredPower(True,0,190));
    Raw:=70;Work:=13300;
  end;
  D:=Default(TTrainerDataRecord);D.InstantPower:=190;D.Distance:=Round(Raw);D.InstantSpeed:=7.2;
  SensorLog.SetSessionState(WorkoutPlayer.State=wsRunning,WorkoutPlayer.JournalLap,198);
  SensorLog.LogData(D,0);
  RideHistory.Checkpoint(TJSONObject.Create(['distance',Raw,'points',6,'segment',1,'t',0.5]));
  SensorLog.Close(False); { synchronously drain, leave the unfinished marker }
  CloseTo(DailyTraining.WorkJoules,Work,'checkpoint daily work');
  Writeln('PASS write ',Mode,' checkpoint, work=',Work:0:0,' J');
  Flush(Output);
  Sleep(30000); { fixture kills this process: Halt still runs FPC finalizers }
  raise Exception.Create('The fixture did not terminate the writer');
end;

procedure ReadRecovery(const Mode:String;Legacy:Boolean);
var O,R,Daily:TJSONObject;Raw,Work,Distance,Seconds,BeforeTSS:Double;OldId,Journal:String;
begin
  O:=RideHistory.LatestUnfinished;Check(O<>nil,'unfinished activity missing');
  try
    Work:=11400;Distance:=0;Seconds:=60;Raw:=50;
    if Mode='active' then begin Work:=13300;Distance:=20;Seconds:=70;Raw:=70 end;
    CloseTo(O.Get('work_j',0.0),Work,'saved work');CloseTo(O.Get('seconds',0.0),Seconds,'saved timer');
    CloseTo(O.Get('distance_m',0.0),Distance,'saved active distance');
    Check(O.Get('last_raw_distance_valid',False),'distance baseline missing');
    CloseTo(O.Get('last_raw_distance',0.0),Raw,'saved raw baseline');
    if Legacy then begin O.Delete('last_raw_distance');O.Delete('last_raw_distance_valid') end;
    OldId:=O.Get('id','');Journal:=O.Get('journal','');
    RideHistory.RequestResume(O);RideHistory.BeginRide('accounting-test','accounting.gpx','accounting-world');
    R:=RideHistory.TakeResume;Check(R<>nil,'resume snapshot missing');
    try
      WorkoutPlayer.RestoreState(R.Objects['workout']);DailyTraining.RestoreState(R.Objects['daily']);
      Check(SensorLog.FileName=Journal,'recovery created another CSV');
      if Mode='paused' then Check(WorkoutPlayer.State=wsPaused,'explicit pause lost')
      else Check(WorkoutPlayer.State=wsReady,'active recovery must wait for pedal');
      CloseTo(DailyTraining.WorkJoules,Work,'restored daily work');BeforeTSS:=DailyTraining.TSS;
      Check(BeforeTSS>0,'fixture needs nonzero TSS');
      DailyTraining.RestoreState(R.Objects['daily']);CloseTo(DailyTraining.WorkJoules,Work,'duplicate daily work');
      CloseTo(DailyTraining.TSS,BeforeTSS,'duplicate TSS');
      RideHistory.ResumeApplied;
    finally R.Free end;
    { Bike motion while pause/ready, then one new measured second. }
    RecordStep(5,Raw+10,True,False,2,MeasuredPower(True,0,190));
    CloseTo(DailyTraining.WorkJoules,Work,'waiting recovery accrued watts');
    WorkoutPlayer.Resume;WorkoutPlayer.Step(1,True,True,True);
    RecordStep(1,Raw+13,True,True,3,MeasuredPower(True,0,190));
    RideHistory.Finish;SensorLog.Close;
    Check(RideHistory.LastResult.Get('id','')=OldId,'activity id changed');
    CloseTo(RideHistory.LastResult.Get('work_j',0.0),Work+190,'resumed work');
    CloseTo(RideHistory.LastResult.Get('seconds',0.0),Seconds+1,'resumed timer');
    CloseTo(RideHistory.LastResult.Get('distance_m',0.0),Distance+3,'paused motion leaked into distance');
    CloseTo(DailyTraining.WorkJoules,Work+190,'resumed daily work');
    Check(not FileExists(Journal+'.active'),'finalized journal remains active');
    Daily:=DailyTraining.SaveState;Daily.Free;
    Writeln('PASS ',Mode,' recovery, legacy=',Legacy,': same CSV/id, work/TSS, paused distance excluded');
  finally O.Free end;
end;

procedure CheckClosingJournal;
var D:TTrainerDataRecord;Name:String;Rows:TSensorSessionRecordArray;
begin
  SensorLog.Close;SensorLog.OwnerKey:=UserDataDir;
  D:=Default(TTrainerDataRecord);D.InstantPower:=190;
  SensorLog.SetSessionState(True,0,0);SensorLog.LogData(D,0);
  D.InstantPower:=$FFFF;SensorLog.SetSessionState(False,0,0);SensorLog.LogData(D,0);
  Name:=SensorLog.FileName;SensorLog.Close;
  Rows:=TSensorLog.LoadSession(Name);Check(Length(Rows)>=2,'signal loss rows missing');
  Check(not Rows[High(Rows)].TimerActive,'signal loss left journal running');
  Check(Rows[High(Rows)].Power=$FFFF,'signal loss kept old watts');
  Writeln('PASS closing journal without live power: stopped timer and unknown watts');
end;

begin
  if GetEnvironmentVariable('REZVIVO_TEST_AUTH_FILE')=''then
    raise Exception.Create('An isolated test profile is required');
  CheckPolicy;
  if ParamStr(1)='write' then WriteRecovery(ParamStr(2))
  else if ParamStr(1)='read' then ReadRecovery(ParamStr(2),ParamStr(3)='legacy')
  else CheckClosingJournal;
end.
