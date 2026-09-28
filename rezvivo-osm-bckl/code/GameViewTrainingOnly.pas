unit GameViewTrainingOnly;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses Classes,CastleUIControls,CastleKeysMouse,GameTrainingFocus,GameWorkoutHud,
  GameMenuTheme,GameBLEHud,GameUiNavigation,WorkoutFile;
const TrainingOnlyWorld='training-only';
type
  { A session without a viewport, rider, route, or tile loader. The workout,
    trainer, journal, daily totals and history are the same services as in 3D. }
  TViewTrainingOnly=class(TCastleView)
  private
    FPanel:TTrainingFocusPanel;
    FHud:TWorkoutHud;
    FMenu,FFinish:TMenuButton;
    FKeyboard:TUiKeyboardNavigation;
    FTelemetry:TBLEHudUpdater;
    FPlan:TWorkoutFile;
    FReference,FDistance:Double;
    FAlive,FSimStarted:Boolean;
    FResumeSim,FSimAccountedUntil:Double;
    FResumeSimPaused:Boolean;
    FSimLoop:Cardinal;
    procedure ClickMenu(Sender:TObject);
    procedure ClickFinish(Sender:TObject);
  public
    procedure Prepare(Plan:TWorkoutFile;Reference:Double);
    procedure OpenMenu;
    procedure Start;override;
    procedure Stop;override;
    procedure Resize;override;
    procedure Update(const SecondsPassed:Single;var HandleInput:Boolean);override;
    function Press(const Event:TInputPressRelease):Boolean;override;
    function PreviewPress(const Event:TInputPressRelease):Boolean;override;
    procedure RenderOverChildren;override;
    destructor Destroy;override;
    property SessionAlive:Boolean read FAlive;
  end;
var ViewTrainingOnly:TViewTrainingOnly;
implementation
uses SysUtils,Math,fpjson,CastleVectors,UiTranslations,GameTrainingWindow,
  GameViewMenu,GameDeviceService,GameWorkoutPlayer,GameUserData,GameRideHistory,
  GameDailyTraining,GameSensorLog,GameActivityAccounting,GameRideCommands,
  GameRouteLibraryData,TrainerData,RideUploadQueue,DebugLog;

procedure TViewTrainingOnly.Prepare(Plan:TWorkoutFile;Reference:Double);
begin FreeAndNil(FPlan);if Plan<>nil then FPlan:=Plan.Clone;FReference:=Reference;end;
destructor TViewTrainingOnly.Destroy;
begin FPlan.Free;inherited;end;

procedure TViewTrainingOnly.Start;
var Saved,Rider:TJSONObject;
begin
  inherited;Name:='TrainingOnly';FDistance:=0;FSimStarted:=False;
  FResumeSim:=-1;FSimAccountedUntil:=0;FResumeSimPaused:=False;FSimLoop:=0;
  FPanel:=TTrainingFocusPanel.Create(FreeAtStop);InsertBack(FPanel);
  FHud:=TWorkoutHud.Create(FreeAtStop);FHud.FocusMode:=True;
  FHud.OnFinishRide:=@ClickFinish;InsertFront(FHud);
  FMenu:=TMenuButton.Create(FreeAtStop);FMenu.Name:='TrainingOnlyMenu';
  FMenu.AutoSize:=False;FMenu.AutoIcon:=False;BindUiText(FMenu,'Menu');
  FMenu.OnClick:=@ClickMenu;InsertFront(FMenu);
  FFinish:=TMenuButton.Create(FreeAtStop);FFinish.Name:='TrainingOnlyFinish';
  FFinish.AutoSize:=False;FFinish.AutoIcon:=False;BindUiText(FFinish,'Finish ride');
  FFinish.OnClick:=@ClickFinish;InsertFront(FFinish);
  FKeyboard:=TUiKeyboardNavigation.Create(FreeAtStop);
  FTelemetry:=TBLEHudUpdater.Create;FTelemetry.SetLabels(Default(THudLabels));
  RideHistory.BeginRide(UiText('Training focus'),'',TrainingOnlyWorld);
  Saved:=RideHistory.TakeResume;
  try
    if Saved<>nil then begin
      if Saved.Find('workout')is TJSONObject then WorkoutPlayer.RestoreState(Saved.Objects['workout']);
      if Saved.Find('daily')is TJSONObject then DailyTraining.RestoreState(Saved.Objects['daily']);
      if Saved.Find('rider')is TJSONObject then begin
        Rider:=Saved.Objects['rider'];FDistance:=Rider.Get('distance',0.0);
        FResumeSim:=Rider.Get('sim_position',-1.0);
        FSimAccountedUntil:=Rider.Get('sim_accounted',Max(0,FResumeSim));
        FResumeSimPaused:=Rider.Get('sim_paused',False);
      end;
      RideHistory.ResumeApplied;
    end else if FPlan<>nil then begin
      WorkoutPlayer.Start(FPlan,FReference,FReference>0,FReference>0);
      RideHistory.SetWorkout(FPlan.Name,FPlan.Url);RememberWorkout(FPlan.Url);
    end;
  finally Saved.Free;FreeAndNil(FPlan);end;
  RideHistory.RebaseDistance(FDistance);
  SensorLog.RecordingEnabled:=True;SensorLog.UseActivityClock;
  if DeviceService<>nil then DeviceService.StartSimPlayback;
  FAlive:=True;FPanel.SyncWindow(True);Resize;
  Logger.Info('[TrainingOnly] Started without a 3D world');
end;

procedure TViewTrainingOnly.Stop;
begin
  FAlive:=False;
  if FPanel<>nil then FPanel.SyncWindow(False);
  if FHud<>nil then FHud.ReleaseTrainer;
  RideHistory.Finish;WorkoutPlayer.Stop;
  if DeviceService<>nil then begin
    DeviceService.StopSimPlayback;
    if DeviceService.HasControlDevice then
      try DeviceService.StopTrainer;except on E:Exception do Logger.Warning('[Trainer] '+E.Message);end;
  end;
  if SensorLog.IsOpen then SensorLog.Close;
  if UploadQueue<>nil then UploadQueue.Scan;
  FreeAndNil(FTelemetry);
  inherited;FPanel:=nil;FHud:=nil;FMenu:=nil;FFinish:=nil;FKeyboard:=nil;
end;

procedure TViewTrainingOnly.Resize;
var S:Single;
begin
  inherited;if FMenu=nil then Exit;S:=TrainingFocusScale(UIScale);
  FMenu.Width:=100/S;FMenu.Height:=34/S;FMenu.FontSize:=13/S;
  FMenu.Anchor(hpLeft,12/S);FMenu.Anchor(vpTop,-12/S);
  FFinish.Width:=210/S;FFinish.Height:=34/S;FFinish.FontSize:=13/S;
  FFinish.Anchor(hpRight,-12/S);FFinish.Anchor(vpTop,-12/S);
end;

procedure TViewTrainingOnly.Update(const SecondsPassed:Single;var HandleInput:Boolean);
var Dt,Speed:Double;Accounting:TActivityAccounting;Data:TTrainerDataRecord;
    Paused,Simulation:Boolean;Cur,Total:Integer;Snapshot:TJSONObject;
begin
  if not FAlive then Exit;
  FPanel.SyncWindow(Container.PendingFrontView=Self);
  inherited;
  Dt:=SecondsPassed;Paused:=False;
  Simulation:=(DeviceService<>nil)and DeviceService.IsSimulationActive;
  SensorLog.RecordingEnabled:=True;
  if Simulation then begin
    if not FSimStarted then begin
      if FResumeSim>=0 then DeviceService.SimSeekSec(FResumeSim);
      DeviceService.SimSetPaused(FResumeSimPaused);FResumeSim:=-1;FResumeSimPaused:=False;
      FSimLoop:=DeviceService.SimLoopSerial;FSimStarted:=True;
    end;
    Dt:=DeviceService.SimAdvance(SecondsPassed);DeviceService.SimPlayerInfo(Paused,Cur,Total);
    if FSimLoop<>DeviceService.SimLoopSerial then FSimAccountedUntil:=0;
    FSimLoop:=DeviceService.SimLoopSerial;
    Dt:=Min(Dt,Max(0,DeviceService.SimPositionSec-FSimAccountedUntil));
    FSimAccountedUntil:=Max(FSimAccountedUntil,DeviceService.SimPositionSec);
    SensorLog.RecordingEnabled:=DeviceService.SimPositionSec>=FSimAccountedUntil;
  end else FSimStarted:=False;
  FHud.Step(Dt,True,Container.FrontView=Self);
  Speed:=0;
  if(DeviceService<>nil)and(DeviceService.Speed<>nil)and DeviceService.Speed.HasData and
    (DeviceService.Speed.DataAgeSec<3)then Speed:=Max(0,DeviceService.Speed.Instant)/3.6;
  Accounting:=ActivityAccounting(True,Paused,WorkoutPlayer.State in[wsReady,wsRunning,wsPaused],
    WorkoutPlayer.State=wsRunning,Speed,FTelemetry.ReadMeasuredPower);
  if Accounting.Running then FDistance:=FDistance+Speed*Dt;
  SensorLog.SetSessionState(Accounting.Running,WorkoutPlayer.JournalLap,
    EnsureRange(Round(WorkoutPlayer.TargetWatts),0,65535));
  Data:=FTelemetry.BLEData;Data.InstantPower:=JournalPower(Accounting.Power);
  Data.InstantSpeed:=Speed*3.6;Data.Distance:=Round(FDistance);
  SensorLog.LogFrame(Data,0,Dt);
  RideHistory.Step(Dt,FDistance,0,Accounting.Power.Watts,EffectiveRiderProfile.FtpW,
    Accounting.Running,Accounting.Power.Valid);
  FTelemetry.UpdatePowerMetrics(Dt,Accounting,SecondsPassed);
  if RideHistory.CheckpointDue then begin
    Snapshot:=TJSONObject.Create(['distance',FDistance]);
    if Simulation then begin
      Snapshot.Add('sim_position',DeviceService.SimPositionSec);
      Snapshot.Add('sim_accounted',FSimAccountedUntil);Snapshot.Add('sim_paused',Paused);
    end;
    RideHistory.Checkpoint(Snapshot);
  end;
end;

procedure TViewTrainingOnly.OpenMenu;
begin
  if Container.PendingFrontView<>Self then Exit;
  FPanel.SyncWindow(False);Container.PushView(ViewMenu);
end;
procedure TViewTrainingOnly.ClickMenu(Sender:TObject);
begin OpenMenu;end;
procedure TViewTrainingOnly.ClickFinish(Sender:TObject);
begin OpenMenu;ViewMenu.FinishRide;end;
function TViewTrainingOnly.Press(const Event:TInputPressRelease):Boolean;
var Command:TRideCommand;
begin
  if Event.IsKey(keyEscape)then begin OpenMenu;Exit(True);end;
  if(Container.ForceCaptureInput=nil)and MatchRideCommand(Event,Command)and ExecuteRideCommand(Command)then Exit(True);
  Result:=inherited;
end;
function TViewTrainingOnly.PreviewPress(const Event:TInputPressRelease):Boolean;
begin if(FKeyboard<>nil)and FKeyboard.Handle(Event,Self)then Exit(True);Result:=inherited;end;
procedure TViewTrainingOnly.RenderOverChildren;
begin inherited;if FKeyboard<>nil then FKeyboard.Render;end;
end.
