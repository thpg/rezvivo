unit GameWorkoutPlayer;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses SysUtils, WorkoutFile, fpjson;
type
  TWorkoutState=(wsIdle,wsReady,wsRunning,wsPaused,wsFinished);
  TWorkoutPlayer=class
  private
    FPlan:TWorkoutFile;
    FState:TWorkoutState;
    FIndex:Integer;
    FStageTime,FElapsed,FPosition,FReference,FIntensity:Double;
    FInitialReference,FStageStartElapsed:Double;
    FRevision:QWord;
    FJournalLap:Integer;
    FWaitForPedal,FRequireSignal,FSignalLost:Boolean;
    procedure JournalState;
    procedure Advance;
    function GetStage:TWorkoutSegment;
    function GetTarget:Double;
    function GetRemaining:Double;
    function GetVisualPowerScale:Single;
  public
    destructor Destroy;override;
    procedure Start(Plan:TWorkoutFile;ReferenceWatts:Double;WaitForPedal,RequireSignal:Boolean);
    procedure Stop;
    procedure Step(Seconds:Double;WorldReady,Pedaling,SignalFresh:Boolean);
    procedure Pause;
    procedure Resume;
    procedure Skip;
    procedure Restart;
    procedure ChangeIntensity(Delta:Double);
    procedure ChangeReferenceWatts(Delta:Double);
    function NeedsTrainerControl:Boolean;
    function TextMessage:String;
    function SaveState:TJSONObject;
    procedure RestoreState(O:TJSONObject);
    property Plan:TWorkoutFile read FPlan;
    property State:TWorkoutState read FState;
    property Index:Integer read FIndex;
    property Stage:TWorkoutSegment read GetStage;
    property StageTime:Double read FStageTime;
    property Elapsed:Double read FElapsed;
    { Position in the plan, including skipped time. Elapsed is time actually ridden. }
    property Position:Double read FPosition;
    property StageRemaining:Double read GetRemaining;
    property TargetWatts:Double read GetTarget;
    property ReferenceWatts:Double read FReference;
    property InitialReferenceWatts:Double read FInitialReference;
    property VisualPowerScale:Single read GetVisualPowerScale;
    { Changes only on explicit start/stop/restart/skip, not automatic intervals. }
    property Revision:QWord read FRevision;
    property StageStartElapsed:Double read FStageStartElapsed;
    property Intensity:Double read FIntensity;
    property SignalLost:Boolean read FSignalLost;
    property JournalLap:Integer read FJournalLap;
  end;
var WorkoutPlayer:TWorkoutPlayer;
implementation
uses Math,GameSensorLog;

procedure TWorkoutPlayer.JournalState;
begin
  if FPlan<>nil then SensorLog.SetSessionState(FState=wsRunning,FJournalLap,
    EnsureRange(Round(TargetWatts),0,65535));
end;

function TWorkoutPlayer.SaveState:TJSONObject;
var A,E:TJSONArray;J,X:TJSONObject;I,K:Integer;S:TWorkoutSegment;T:TWorkoutTextEvent;
begin
  Result:=TJSONObject.Create(['version',1,'state',Ord(FState)]);
  if FPlan=nil then Exit;
  Result.Add('name',FPlan.Name);Result.Add('url',FPlan.Url);
  Result.Add('description',FPlan.Description);Result.Add('author',FPlan.Author);
  Result.Add('index',FIndex);Result.Add('stage_time',FStageTime);Result.Add('elapsed',FElapsed);
  Result.Add('position',FPosition);Result.Add('reference',FReference);Result.Add('initial_reference',FInitialReference);
  Result.Add('intensity',FIntensity);Result.Add('stage_start',FStageStartElapsed);
  Result.Add('journal_lap',FJournalLap);
  Result.Add('wait_pedal',FWaitForPedal);Result.Add('require_signal',FRequireSignal);
  A:=TJSONArray.Create;Result.Add('segments',A);
  for I:=0 to FPlan.Segments.Count-1 do begin
    S:=FPlan.Segments[I];J:=TJSONObject.Create(['kind',Ord(S.Kind),'duration',S.Duration,
      'low',S.PowerLow,'high',S.PowerHigh,'group',S.RepeatGroup,'on',S.IsOnPart,
      'cadence',S.Cadence,'cadence_rest',S.CadenceResting,'cadence_low',S.CadenceLow,'cadence_high',S.CadenceHigh]);
    A.Add(J);E:=TJSONArray.Create;J.Add('text',E);
    for K:=0 to S.TextEvents.Count-1 do begin
      T:=S.TextEvents[K];X:=TJSONObject.Create(['time',T.TimeOffset,'duration',T.Duration,'message',T.Message]);E.Add(X);
    end;
  end;
end;

procedure TWorkoutPlayer.RestoreState(O:TJSONObject);
var W:TWorkoutFile;A,E:TJSONData;J,X:TJSONObject;I,K,N,StateValue:Integer;S:TWorkoutSegment;T:TWorkoutTextEvent;
begin
  if(O=nil)or(O.Get('version',0)<>1)then Exit;
  StateValue:=O.Get('state',0);if StateValue=Ord(wsIdle)then begin Stop;Exit;end;
  A:=O.Find('segments');if not(A is TJSONArray)or(A.Count=0)or(A.Count>10000)then
    raise Exception.Create('Invalid saved workout');
  W:=TWorkoutFile.Create;
  try
    W.Name:=O.Get('name','');W.Description:=O.Get('description','');W.Author:=O.Get('author','');
    for I:=0 to A.Count-1 do begin
      if not(A.Items[I] is TJSONObject)then raise Exception.Create('Invalid saved interval');
      J:=TJSONObject(A.Items[I]);N:=J.Get('kind',-1);
      if(N<Ord(Low(TWorkoutSegmentKind)))or(N>Ord(High(TWorkoutSegmentKind)))then raise Exception.Create('Invalid saved interval kind');
      S:=W.AddSegment(TWorkoutSegmentKind(N));S.Duration:=J.Get('duration',0.0);
      if IsNan(S.Duration)or IsInfinite(S.Duration)or(S.Duration<=0)then raise Exception.Create('Invalid saved interval duration');
      S.PowerLow:=J.Get('low',0.0);S.PowerHigh:=J.Get('high',0.0);S.RepeatGroup:=J.Get('group',0);S.IsOnPart:=J.Get('on',False);
      S.Cadence:=J.Get('cadence',0);S.CadenceResting:=J.Get('cadence_rest',0);S.CadenceLow:=J.Get('cadence_low',0);S.CadenceHigh:=J.Get('cadence_high',0);
      E:=J.Find('text');if E is TJSONArray then for K:=0 to E.Count-1 do if E.Items[K] is TJSONObject then begin
        X:=TJSONObject(E.Items[K]);T:=TWorkoutTextEvent.Create;T.TimeOffset:=X.Get('time',0.0);T.Duration:=X.Get('duration',0.0);T.Message:=X.Get('message','');S.TextEvents.Add(T);
      end;
    end;
    N:=O.Get('index',0);if(N<0)or(N>W.Segments.Count)then raise Exception.Create('Invalid saved interval index');
    Start(W,O.Get('reference',0.0),O.Get('wait_pedal',True),O.Get('require_signal',True));
    FIndex:=N;FStageTime:=Max(0,O.Get('stage_time',0.0));FElapsed:=Max(0,O.Get('elapsed',0.0));
    FPosition:=Max(0,O.Get('position',0.0));FInitialReference:=Max(0,O.Get('initial_reference',FReference));
    FIntensity:=EnsureRange(O.Get('intensity',1.0),0.25,1.5);FStageStartElapsed:=Max(0,O.Get('stage_start',0.0));
    if FIndex>=FPlan.Segments.Count then FState:=wsFinished
    else if StateValue=Ord(wsPaused)then FState:=wsPaused else FState:=wsReady;
    if Stage<>nil then FStageTime:=Min(FStageTime,Stage.Duration);
    FJournalLap:=Max(0,O.Get('journal_lap',0));JournalState;
    Inc(FRevision);
  finally W.Free;end;
end;

destructor TWorkoutPlayer.Destroy;
begin FPlan.Free;inherited;end;

procedure TWorkoutPlayer.Start(Plan:TWorkoutFile;ReferenceWatts:Double;WaitForPedal,RequireSignal:Boolean);
var CopyPlan:TWorkoutFile;
begin
  if(Plan=nil)or(Plan.Segments.Count=0)or(Plan.TotalDuration<=0)then
    raise Exception.Create('Workout has no timed steps');
  CopyPlan:=Plan.Clone;
  FreeAndNil(FPlan);FPlan:=CopyPlan;
  FReference:=Max(0,ReferenceWatts);FIntensity:=1;
  FInitialReference:=FReference;
  FWaitForPedal:=WaitForPedal;FRequireSignal:=RequireSignal;
  Restart;
end;

procedure TWorkoutPlayer.Stop;
begin
  FreeAndNil(FPlan);FState:=wsIdle;FSignalLost:=False;
  FIndex:=0;FStageTime:=0;FElapsed:=0;FPosition:=0;
  FStageStartElapsed:=0;Inc(FRevision);
  Inc(FJournalLap);SensorLog.SetSessionState(False,FJournalLap,0);
end;

procedure TWorkoutPlayer.Restart;
begin
  if FPlan=nil then Exit;
  FIndex:=0;FStageTime:=0;FElapsed:=0;FPosition:=0;FSignalLost:=False;FState:=wsReady;
  FStageStartElapsed:=0;Inc(FRevision);
  Inc(FJournalLap);JournalState;
end;

function TWorkoutPlayer.GetStage:TWorkoutSegment;
begin
  Result:=nil;
  if(FPlan<>nil)and(FIndex>=0)and(FIndex<FPlan.Segments.Count)then
    Result:=FPlan.Segments[FIndex];
end;

procedure TWorkoutPlayer.Advance;
begin
  FPosition:=FPosition+StageRemaining;
  Inc(FIndex);FStageTime:=0;
  FStageStartElapsed:=FElapsed;
  if FIndex>=FPlan.Segments.Count then FState:=wsFinished;
  Inc(FJournalLap);JournalState;
end;

procedure TWorkoutPlayer.Step(Seconds:Double;WorldReady,Pedaling,SignalFresh:Boolean);
var D,Left:Double;S:TWorkoutSegment;
begin
  if(FPlan=nil)or(FState in[wsIdle,wsPaused,wsFinished])or not WorldReady then Exit;
  if IsNan(Seconds)or IsInfinite(Seconds)or(Seconds<=0)then Exit;
  FSignalLost:=FRequireSignal and not SignalFresh;
  if FSignalLost then begin FState:=wsReady;JournalState;Exit;end;
  if FState=wsReady then begin
    if FWaitForPedal and not Pedaling then Exit;
    FState:=wsRunning;
  end;
  while(Seconds>0)and(FState=wsRunning)do begin
    S:=Stage;
    if S=nil then begin FState:=wsFinished;Break;end;
    if IsNan(S.Duration)or IsInfinite(S.Duration)or(S.Duration<=0)then begin Advance;Continue;end;
    Left:=Max(0,S.Duration-FStageTime);D:=Min(Left,Seconds);
    FStageTime:=FStageTime+D;FElapsed:=FElapsed+D;FPosition:=FPosition+D;Seconds:=Seconds-D;
    if FStageTime>=S.Duration-1e-7 then Advance else Break;
  end;
  JournalState;
end;

procedure TWorkoutPlayer.Pause;
begin if FState in[wsReady,wsRunning]then begin FState:=wsPaused;JournalState;end;end;
procedure TWorkoutPlayer.Resume;
begin if FState=wsPaused then begin FState:=wsReady;JournalState;end;end;
procedure TWorkoutPlayer.Skip;
begin
  if(FPlan<>nil)and(FState in[wsReady,wsRunning,wsPaused])then begin
    Inc(FRevision);Advance;
  end;
end;
procedure TWorkoutPlayer.ChangeIntensity(Delta:Double);
begin
  if not IsNan(Delta)and not IsInfinite(Delta)then
    FIntensity:=EnsureRange(FIntensity+Delta,0.25,1.5);
  JournalState;
end;
procedure TWorkoutPlayer.ChangeReferenceWatts(Delta:Double);
begin
  if(FReference<=0)or(FPlan=nil)or not(FState in[wsReady,wsRunning,wsPaused])then Exit;
  if not IsNan(Delta)and not IsInfinite(Delta)then
    FReference:=EnsureRange(FReference+Delta,1.0,2000.0);
  JournalState;
end;

function TWorkoutPlayer.GetRemaining:Double;
begin
  Result:=0;
  if(Stage<>nil)and not IsNan(Stage.Duration)and not IsInfinite(Stage.Duration)then
    Result:=Max(0,Stage.Duration-FStageTime);
end;

function TWorkoutPlayer.GetVisualPowerScale:Single;
begin
  Result:=FIntensity;
  if FInitialReference>0 then Result:=Result*FReference/FInitialReference;
end;

function TWorkoutPlayer.GetTarget:Double;
var S:TWorkoutSegment;Fraction,P:Double;
begin
  Result:=0;S:=Stage;
  if(S=nil)or(S.Kind=wskFreeRide)or(FReference<=0)then Exit;
  P:=S.PowerLow;
  if S.Kind in[wskWarmup,wskCooldown,wskRamp]then begin
    Fraction:=0;if S.Duration>0 then Fraction:=EnsureRange(FStageTime/S.Duration,0.0,1.0);
    P:=S.PowerLow+(S.PowerHigh-S.PowerLow)*Fraction;
  end;
  if IsNan(P)or IsInfinite(P)then Exit;
  Result:=Max(0,P*FReference*FIntensity);
end;

function TWorkoutPlayer.NeedsTrainerControl:Boolean;
begin
  Result:=(FPlan<>nil)and(FReference>0)and(FState<>wsIdle);
end;

function TWorkoutPlayer.TextMessage:String;
var I:Integer;E:TWorkoutTextEvent;
begin
  Result:='';if Stage=nil then Exit;
  for I:=0 to Stage.TextEvents.Count-1 do begin
    E:=Stage.TextEvents[I];
    if(FStageTime>=E.TimeOffset)and(FStageTime<E.TimeOffset+Max(6,E.Duration))then
      Result:=E.Message;
  end;
end;
initialization
  WorkoutPlayer:=TWorkoutPlayer.Create;
finalization
  FreeAndNil(WorkoutPlayer);
end.
