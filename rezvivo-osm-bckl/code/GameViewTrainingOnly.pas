unit GameViewTrainingOnly;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses Classes,CastleControls,CastleUIControls,CastleKeysMouse,GameTrainingFocus,GameWorkoutHud,
  GameMenuTheme,GameBLEHud,GameUiNavigation,WorkoutFile,GameRideMetricsHud,GamePowerAccumulator;
const TrainingOnlyWorld='training-only';
type
  TTrainingLocalRide=record
    Owner:TComponent;
    ZonePower:TPowerAccumulator;
    Hud:TWorkoutHud;
    Metrics:TRideMetricsHud;
    Telemetry:TBLEHudUpdater;
    Distance,ResumeSim,SimAccountedUntil:Double;
    SimStarted,ResumeSimPaused:Boolean;
    SimLoop:Cardinal;
  end;
  { A session without a viewport, rider, route, or tile loader. The workout,
    trainer, journal, daily totals and history are the same services as in 3D. }
  TViewTrainingOnly=class(TCastleView)
  private
    FPanel:TTrainingFocusPanel;
    FLocals:array[0..7]of TTrainingLocalRide;
    FParticipantCount,FFocusedIndex:Integer;
    FSeenGridBottom:Single;
    FSelectors:array[0..7]of TMenuButton;
    FGridHost:TCastleUserInterface;
    FContent:TCastleUserInterface;
    FContentScroll:TCastleScrollView;
    FLayoutBusy:Boolean;
    FMenu,FFinish,FAssistant:TMenuButton;
    FKeyboard:TUiKeyboardNavigation;
    FPlan:TWorkoutFile;
    FReference:Double;
    FAlive:Boolean;
    procedure ClickRider(Sender:TObject);
    procedure StepRider(Index:Integer;Seconds:Single);
    procedure StartRiderWorkout(Index:Integer;Plan:TWorkoutFile;Reference:Double);
    procedure ClickMenu(Sender:TObject);
    procedure ClickAssistant(Sender:TObject);
    procedure ClickFinish(Sender:TObject);
  public
    procedure Prepare(Plan:TWorkoutFile;Reference:Double);
    procedure StartWorkoutForAll(Plan:TWorkoutFile;Reference:Double);
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
uses SysUtils,Math,fpjson,CastleVectors,GameRiderPalette,UiTranslations,GameTrainingWindow,
  GameViewMenu,GameAssistantUI,GameDeviceService,GameWorkoutPlayer,GameUserData,GameRideHistory,
  GameDailyTraining,GameSensorLog,GameActivityAccounting,GameRideCommands,
  GameRouteLibraryData,TrainerData,RideUploadQueue,DebugLog;

procedure TViewTrainingOnly.Prepare(Plan:TWorkoutFile;Reference:Double);
begin FreeAndNil(FPlan);if Plan<>nil then FPlan:=Plan.Clone;FReference:=Reference;end;
destructor TViewTrainingOnly.Destroy;
begin FPlan.Free;inherited;end;

procedure TViewTrainingOnly.StartRiderWorkout(Index:Integer;Plan:TWorkoutFile;Reference:Double);
var RiderReference:Double;
begin
  if Plan=nil then Exit;
  RiderReference:=Reference;
  if(Index>0)and(Reference>0)then begin
    RiderReference:=Max(0,EffectiveRiderProfile(Index).FtpW);
    if RiderReference<=0 then RiderReference:=Reference;
  end;
  { Start clones its input, so plan position, pause and intensity are independent. }
  WorkoutPlayerForRider(Index).Start(Plan,RiderReference,RiderReference>0,RiderReference>0);
  RideHistoryForRider(Index).SetWorkout(Plan.Name,Plan.Url);
  SetRiderPreference('last_workout',Plan.Url,Index);
end;

procedure TViewTrainingOnly.StartWorkoutForAll(Plan:TWorkoutFile;Reference:Double);
var I:Integer;
begin
  if Plan=nil then Exit;
  if not FAlive then begin Prepare(Plan,Reference);Exit end;
  for I:=0 to FParticipantCount-1 do StartRiderWorkout(I,Plan,Reference);
end;

procedure TViewTrainingOnly.Start;
var Saved,Rider:TJSONObject;I:Integer;Background:TCastleRectangleControl;
begin
  inherited;Name:='TrainingOnly';FParticipantCount:=LocalRiderCount;FFocusedIndex:=0;
  FillChar(FLocals,SizeOf(FLocals),0);FillChar(FSelectors,SizeOf(FSelectors),0);
  Background:=TCastleRectangleControl.Create(FreeAtStop);Background.FullSize:=True;
  Background.Color:=MenuBackground;InsertBack(Background);
  FPanel:=TTrainingFocusPanel.Create(FreeAtStop);FPanel.Exists:=FParticipantCount=1;InsertFront(FPanel);
  if FParticipantCount>1 then begin
    FContentScroll:=TMenuScrollView.Create(FreeAtStop);
    FContentScroll.Anchor(hpLeft);FContentScroll.Anchor(vpTop,-88);InsertFront(FContentScroll);
    FContent:=TCastleUserInterface.Create(FreeAtStop);
    FContentScroll.ScrollArea.InsertFront(FContent);
    FGridHost:=TCastleUserInterface.Create(FreeAtStop);FGridHost.WidthFraction:=1;
    FGridHost.Anchor(hpLeft);FGridHost.Anchor(vpTop);FContent.InsertFront(FGridHost);
  end else FGridHost:=nil;
  FMenu:=TMenuButton.Create(FreeAtStop);FMenu.Name:='TrainingOnlyMenu';
  FMenu.AutoSize:=False;FMenu.AutoIcon:=False;BindUiText(FMenu,'Menu');
  FMenu.OnClick:=@ClickMenu;InsertFront(FMenu);
  FFinish:=TMenuButton.Create(FreeAtStop);FFinish.Name:='TrainingOnlyFinish';
  FFinish.AutoSize:=False;FFinish.AutoIcon:=False;BindUiText(FFinish,'Finish ride');
  FFinish.OnClick:=@ClickFinish;InsertFront(FFinish);
  FAssistant:=TMenuButton.Create(FreeAtStop);FAssistant.Name:='TrainingOnlyAssistant';
  FAssistant.AutoSize:=False;FAssistant.AutoIcon:=False;BindUiText(FAssistant,'Assistant');
  FAssistant.OnClick:=@ClickAssistant;InsertFront(FAssistant);
  FKeyboard:=TUiKeyboardNavigation.Create(FreeAtStop);
  try
    for I:=0 to FParticipantCount-1 do begin
      FLocals[I].ResumeSim:=-1;
      FLocals[I].Owner:=TComponent.Create(FreeAtStop);
      FLocals[I].Hud:=TWorkoutHud.Create(FLocals[I].Owner);FLocals[I].Hud.ProfileIndex:=I;
      FLocals[I].Hud.FocusMode:=True;FLocals[I].Hud.OnFinishRide:=@ClickFinish;
      FLocals[I].Hud.Exists:=False;
      if FContent<>nil then FContent.InsertFront(FLocals[I].Hud)else InsertFront(FLocals[I].Hud);
      FLocals[I].Telemetry:=TBLEHudUpdater.Create(I);
      if FParticipantCount>1 then begin
        FLocals[I].ZonePower:=TPowerAccumulator.Create;
        FLocals[I].Metrics:=TRideMetricsHud.Create(FLocals[I].Owner);FLocals[I].Metrics.ProfileIndex:=I;
        FGridHost.InsertFront(FLocals[I].Metrics);FLocals[I].Metrics.SetGridSlot(I,FParticipantCount);
        FLocals[I].Telemetry.SetLabels(FLocals[I].Metrics.Labels);
        FSelectors[I]:=TMenuButton.Create(FreeAtStop);FSelectors[I].AutoSize:=False;FSelectors[I].AutoIcon:=False;
        FSelectors[I].Name:='TrainingLocalRider'+IntToStr(I+1);FSelectors[I].Tag:=I;
        FSelectors[I].Caption:=IntToStr(I+1)+'. '+LocalRider(I).DisplayName;
        FSelectors[I].OnClick:=@ClickRider;FContent.InsertFront(FSelectors[I]);
      end else FLocals[I].Telemetry.SetLabels(Default(THudLabels));
      if FPlan<>nil then RideHistoryForRider(I).CancelResume;
      RideHistoryForRider(I).BeginRide(UiText('Training focus'),'',TrainingOnlyWorld);
      Saved:=RideHistoryForRider(I).TakeResume;
      try
        if Saved<>nil then begin
          if Saved.Find('workout')is TJSONObject then WorkoutPlayerForRider(I).RestoreState(Saved.Objects['workout']);
          if Saved.Find('daily')is TJSONObject then DailyTrainingForRider(I).RestoreState(Saved.Objects['daily']);
          if Saved.Find('rider')is TJSONObject then begin
            Rider:=Saved.Objects['rider'];FLocals[I].Distance:=Rider.Get('distance',0.0);
            FLocals[I].ResumeSim:=Rider.Get('sim_position',-1.0);
            FLocals[I].SimAccountedUntil:=Rider.Get('sim_accounted',Max(0,FLocals[I].ResumeSim));
            FLocals[I].ResumeSimPaused:=Rider.Get('sim_paused',False);
          end;
          RideHistoryForRider(I).ResumeApplied;
        end else if FPlan<>nil then StartRiderWorkout(I,FPlan,FReference)
        else if(I>0)and(WorkoutPlayerForRider(0).Plan<>nil)then
          StartRiderWorkout(I,WorkoutPlayerForRider(0).Plan,WorkoutPlayerForRider(0).InitialReferenceWatts);
      finally Saved.Free end;
      RideHistoryForRider(I).RebaseDistance(FLocals[I].Distance);
      SensorLogForRider(I).RecordingEnabled:=True;SensorLogForRider(I).UseActivityClock;
      if DeviceService<>nil then DeviceService.ForRider(I).StartSimPlayback;
    end;
  finally FreeAndNil(FPlan) end;
  FAlive:=True;FPanel.SyncWindow(FParticipantCount=1);Resize;
  Logger.Info('[TrainingOnly] Started '+IntToStr(FParticipantCount)+' local sessions without a 3D world');
end;

procedure TViewTrainingOnly.Stop;
var I:Integer;Devices:TGameDeviceService;
begin
  FAlive:=False;
  if FPanel<>nil then FPanel.SyncWindow(False);
  for I:=0 to FParticipantCount-1 do begin
    if FLocals[I].Hud<>nil then FLocals[I].Hud.ReleaseTrainer;
    RideHistoryForRider(I).Finish;WorkoutPlayerForRider(I).Stop;
    if DeviceService<>nil then begin
      Devices:=DeviceService.ForRider(I);Devices.StopSimPlayback;
      if Devices.HasControlDevice then
        try Devices.StopTrainer;except on E:Exception do Logger.Warning('[Trainer] '+E.Message);end;
    end;
    if SensorLogForRider(I).IsOpen then SensorLogForRider(I).Close;
    if RideUploadQueueForRider(I)<>nil then RideUploadQueueForRider(I).Scan;
    FreeAndNil(FLocals[I].Telemetry);FreeAndNil(FLocals[I].ZonePower);
  end;
  inherited;
  FillChar(FLocals,SizeOf(FLocals),0);FillChar(FSelectors,SizeOf(FSelectors),0);FParticipantCount:=0;
  FPanel:=nil;FGridHost:=nil;FContent:=nil;FContentScroll:=nil;
  FMenu:=nil;FFinish:=nil;FAssistant:=nil;FKeyboard:=nil;
end;

procedure TViewTrainingOnly.Resize;
var S,SelectorY,GridRoom,TileWidth:Single;I,Columns,Rows:Integer;
begin
  if FLayoutBusy then Exit;
  inherited;if FMenu=nil then Exit;S:=TrainingFocusScale(UIScale);
  FLayoutBusy:=True;
  try
  FMenu.Width:=100/S;FMenu.Height:=34/S;FMenu.FontSize:=13/S;
  FMenu.Anchor(hpLeft,12/S);FMenu.Anchor(vpTop,-12/S);
  FFinish.Width:=210/S;FFinish.Height:=34/S;FFinish.FontSize:=13/S;
  FFinish.Anchor(hpRight,-12/S);FFinish.Anchor(vpTop,-12/S);
  FAssistant.Width:=136/S;FAssistant.Height:=28/S;FAssistant.FontSize:=13/S;
  FAssistant.Anchor(hpRight,-12/S);FAssistant.Anchor(vpTop,-52/S);
  if(FGridHost=nil)or(FLocals[FFocusedIndex].Hud=nil)then Exit;
  Columns:=Min(FParticipantCount,Min(4,Max(1,Floor((EffectiveWidth-24/S)/(140/S)))));
  Rows:=(FParticipantCount+Columns-1)div Columns;
  { Keep the live cards legible. On a phone the whole multi-rider training
    content scrolls instead of reducing three dashboards to tiny thumbnails. }
  GridRoom:=Max(1,EffectiveHeight-88/S);
  FContentScroll.Width:=EffectiveWidth;FContentScroll.Height:=GridRoom;
  FContentScroll.Anchor(vpTop,-88/S);FContent.Width:=EffectiveWidth;
  { The inherited resize ran before the scroll content received its new width.
    Reflow every participant, including hidden panels, against that width. }
  for I:=0 to FParticipantCount-1 do
    if FLocals[I].Hud<>nil then FLocals[I].Hud.Resize;
  FGridHost.Height:=Max(320/S,GridRoom);FGridHost.Anchor(vpTop);
  for I:=0 to FParticipantCount-1 do FLocals[I].Metrics.Resize;
  FSeenGridBottom:=FLocals[0].Metrics.GridBottom;
  SelectorY:=FSeenGridBottom+4/S;
  TileWidth:=(EffectiveWidth-24/S-(Columns-1)*6/S)/Columns;
  for I:=0 to FParticipantCount-1 do begin
    FSelectors[I].Width:=TileWidth;FSelectors[I].Height:=34/S;FSelectors[I].FontSize:=12/S;
    FSelectors[I].Anchor(hpLeft,12/S+(I mod Columns)*(TileWidth+6/S));
    FSelectors[I].Anchor(vpTop,-(SelectorY+(I div Columns)*40/S));
    ApplyRiderButtonPalette(FSelectors[I],I,I=FFocusedIndex);
  end;
  FContent.Height:=Max(GridRoom,SelectorY+Rows*40/S+
    FLocals[FFocusedIndex].Hud.EffectiveHeight+16/S);
  FContentScroll.ScrollArea.Height:=FContent.Height;
  finally FLayoutBusy:=False end;
end;

procedure TViewTrainingOnly.ClickRider(Sender:TObject);
var I:Integer;
begin
  FFocusedIndex:=EnsureRange(TComponent(Sender).Tag,0,FParticipantCount-1);
  for I:=0 to FParticipantCount-1 do begin
    FLocals[I].Hud.Exists:=(I=FFocusedIndex)and(WorkoutPlayerForRider(I).State<>wsIdle);
    ApplyRiderButtonPalette(FSelectors[I],I,I=FFocusedIndex);
  end;
  Resize;
end;

procedure TViewTrainingOnly.StepRider(Index:Integer;Seconds:Single);
var Dt,Speed:Double;Accounting:TActivityAccounting;Data:TTrainerDataRecord;
  Paused,Simulation:Boolean;Cur,Total:Integer;Snapshot:TJSONObject;
  Devices:TGameDeviceService;Player:TWorkoutPlayer;
begin
  Devices:=nil;if DeviceService<>nil then Devices:=DeviceService.ForRider(Index);
  Player:=WorkoutPlayerForRider(Index);Dt:=Seconds;Paused:=False;
  if FParticipantCount>1 then begin
    FLocals[Index].Hud.Color:=RiderPanelPalette(Index).DarkSurface;
    ApplyRiderButtonPalette(FSelectors[Index],Index,Index=FFocusedIndex);
  end;
  Simulation:=(Devices<>nil)and Devices.IsSimulationActive;
  SensorLogForRider(Index).RecordingEnabled:=True;
  with FLocals[Index]do begin
    if Simulation then begin
      if not SimStarted then begin
        if ResumeSim>=0 then Devices.SimSeekSec(ResumeSim);
        Devices.SimSetPaused(ResumeSimPaused);ResumeSim:=-1;ResumeSimPaused:=False;
        SimLoop:=Devices.SimLoopSerial;SimStarted:=True;
      end;
      Dt:=Devices.SimAdvance(Seconds);Devices.SimPlayerInfo(Paused,Cur,Total);
      if SimLoop<>Devices.SimLoopSerial then SimAccountedUntil:=0;
      SimLoop:=Devices.SimLoopSerial;
      Dt:=Min(Dt,Max(0,Devices.SimPositionSec-SimAccountedUntil));
      SimAccountedUntil:=Max(SimAccountedUntil,Devices.SimPositionSec);
      SensorLogForRider(Index).RecordingEnabled:=Devices.SimPositionSec>=SimAccountedUntil;
    end else SimStarted:=False;
    Hud.Step(Dt,True,(Index=FFocusedIndex)and(Container.FrontView=Self));
    Speed:=0;
    if(Devices<>nil)and(Devices.Speed<>nil)and Devices.Speed.HasData and
      (Devices.Speed.DataAgeSec<3)then Speed:=Max(0,Devices.Speed.Instant)/3.6;
    Accounting:=ActivityAccounting(True,Paused,Player.State in[wsReady,wsRunning,wsPaused],
      Player.State=wsRunning,Speed,Telemetry.ReadMeasuredPower);
    if Accounting.Running then Distance:=Distance+Speed*Dt;
    SensorLogForRider(Index).SetSessionState(Accounting.Running,Player.JournalLap,
      EnsureRange(Round(Player.TargetWatts),0,65535));
    Data:=Telemetry.BLEData;Data.InstantPower:=JournalPower(Accounting.Power);
    Data.InstantSpeed:=Speed*3.6;Data.Distance:=Round(Distance);
    if Devices<>nil then SensorLogForRider(Index).LogFrame(Data,0,Dt,Devices.ActivitySourceFlags)
    else SensorLogForRider(Index).LogFrame(Data,0,Dt,0);
    RideHistoryForRider(Index).Step(Dt,Distance,0,Accounting.Power.Watts,EffectiveRiderProfile(Index).FtpW,
      Accounting.Running,Accounting.Power.Valid);
    Telemetry.UpdatePowerMetrics(Dt,Accounting,Seconds);
    if Metrics<>nil then begin
      Metrics.Labels.LabelRiderName.Caption:=LocalRider(Index).DisplayName;
      ZonePower.Step(Accounting.Power.Watts,Dt,Accounting.Running,Accounting.Power.Valid);
      if Accounting.Power.Valid then Metrics.Labels.LabelPower.Caption:=IntToStr(Round(Data.InstantPower))
      else Metrics.Labels.LabelPower.Caption:='--';
      if Accounting.Running and Accounting.Power.Valid then
        Metrics.Labels.WheelPower.Selected:=Telemetry.PowerZone(ZonePower.AveragePower)
      else Metrics.Labels.WheelPower.Selected:=-1;
      Metrics.Labels.LabelCadence.Caption:=IntToStr(Data.InstantCadence);
      Metrics.Labels.LabelHeart.Caption:=IntToStr(Data.HeartRate);
      Metrics.Labels.LabelSpeed.Caption:=FormatFloat('0.0',Speed*3.6);
      Metrics.Labels.LabelWork.Caption:=FormatFloat('0.0',DailyTrainingForRider(Index).WorkJoules/1000);
      Metrics.Labels.LabelWorkTSS.Caption:=FormatFloat('0.0',DailyTrainingForRider(Index).TSS);
      if Devices<>nil then Metrics.Labels.LabelPowerComparison.Caption:=Devices.ComparisonPowerText;
    end;
    if RideHistoryForRider(Index).CheckpointDue then begin
      Snapshot:=TJSONObject.Create(['distance',Distance]);
      if Simulation then begin
        Snapshot.Add('sim_position',Devices.SimPositionSec);
        Snapshot.Add('sim_accounted',SimAccountedUntil);Snapshot.Add('sim_paused',Paused);
      end;
      RideHistoryForRider(Index).Checkpoint(Snapshot);
    end;
  end;
end;

procedure TViewTrainingOnly.Update(const SecondsPassed:Single;var HandleInput:Boolean);
var I:Integer;
begin
  if not FAlive then Exit;
  FPanel.SyncWindow((FParticipantCount=1)and(Container.PendingFrontView=Self)and not AssistantVisible(Container));
  inherited;
  if(FParticipantCount>1)and(Abs(FSeenGridBottom-FLocals[0].Metrics.GridBottom)>0.1)then Resize;
  for I:=0 to FParticipantCount-1 do begin
    StepRider(I,SecondsPassed);
    if FSelectors[I]<>nil then FSelectors[I].Caption:=IntToStr(I+1)+'. '+LocalRider(I).DisplayName;
  end;
end;

procedure TViewTrainingOnly.OpenMenu;
begin
  if Container.PendingFrontView<>Self then Exit;
  FPanel.SyncWindow(False);Container.PushView(ViewMenu);
end;
procedure TViewTrainingOnly.ClickMenu(Sender:TObject);
begin OpenMenu;end;
procedure TViewTrainingOnly.ClickAssistant(Sender:TObject);
begin
  if Container.PendingFrontView<>Self then Exit;
  FPanel.SyncWindow(False);ShowAssistant(Container);
end;
procedure TViewTrainingOnly.ClickFinish(Sender:TObject);
begin OpenMenu;ViewMenu.FinishRide;end;
function TViewTrainingOnly.Press(const Event:TInputPressRelease):Boolean;
var Command:TRideCommand;
begin
  if Event.IsKey(keyEscape)then begin OpenMenu;Exit(True);end;
  if(Container.ForceCaptureInput=nil)and MatchRideCommand(Event,Command)and ExecuteRideCommand(Command,FFocusedIndex)then Exit(True);
  Result:=inherited;
end;
function TViewTrainingOnly.PreviewPress(const Event:TInputPressRelease):Boolean;
begin if(FKeyboard<>nil)and FKeyboard.Handle(Event,Self)then Exit(True);Result:=inherited;end;
procedure TViewTrainingOnly.RenderOverChildren;
begin inherited;if FKeyboard<>nil then FKeyboard.Render;end;
end.
