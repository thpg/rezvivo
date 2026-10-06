unit GameWorkoutHud;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses Classes,SysUtils,CastleUIControls,CastleControls,GameMenuTheme,GameWorkoutPreview;
type
  TWorkoutHud=class(TCastleRectangleControl)
  private
    FTitle,FStep,FNext,FReference,FTrainerState:TCastleLabel;
    FChart:TWorkoutPreview;
    FPause,FMinus,FPlus,FSkip,FRestart,FContinue,FFinish:TMenuButton;
    FWattsMinus,FWattsPlus:TMenuButton;
    FLastTarget:Integer;
    FLastDevice:Pointer;
    FLastSend:QWord;
    FHadControl:Boolean;
    FFocusMode:Boolean;
    procedure SetFocusMode(Value:Boolean);
    procedure ClickPause(Sender:TObject);
    procedure ClickIntensity(Sender:TObject);
    procedure ClickReference(Sender:TObject);
    procedure ClickSkip(Sender:TObject);
    procedure ClickRestart(Sender:TObject);
    procedure ClickContinue(Sender:TObject);
    procedure ClickFinish(Sender:TObject);
    procedure RefreshControls;
  public
    OnFinishRide:TNotifyEvent;
    procedure ReleaseTrainer;
    constructor Create(AOwner:TComponent);override;
    destructor Destroy;override;
    procedure Resize;override;
    procedure Step(Seconds:Single;WorldReady:Boolean;ShowHud:Boolean=True);
    function ControlsTrainer:Boolean;
    property FocusMode:Boolean read FFocusMode write SetFocusMode;
  end;
implementation
uses Math,CastleVectors,CastleColors,UiTranslations,WorkoutFile,GameWorkoutPlayer,
  GameDeviceService,GameDeviceSensor,GameDeviceTypes,GameUserData,DebugLog,
  GameTrainerControl,GameRideCommands,GameWorkoutColors,GameTrainingWindow;

function RiderWeight:Single;
begin Result:=EffectiveRiderProfile.WeightKg;if Result<=0 then Result:=75;end;

constructor TWorkoutHud.Create(AOwner:TComponent);
  function LabelControl(const N:String):TCastleLabel;
  begin Result:=TCastleLabel.Create(Self);Result.Name:=N;Result.Color:=White;InsertFront(Result);end;
  function Button(const N,Caption:String;Click:TNotifyEvent):TMenuButton;
  begin
    Result:=TMenuButton.Create(Self);Result.Name:=N;Result.AutoIcon:=False;
    Result.AutoSize:=False;BindUiText(Result,Caption);Result.OnClick:=Click;InsertFront(Result);
  end;
begin
  inherited;Name:='WorkoutHud';WidthFraction:=1;Color:=Vector4(0.025,0.045,0.065,0.95);
  Anchor(hpLeft);Anchor(vpBottom);Exists:=False;FLastTarget:=-1;
  FTitle:=LabelControl('WorkoutTitle');FStep:=LabelControl('WorkoutStep');FNext:=LabelControl('WorkoutNext');
  FReference:=LabelControl('WorkoutReference');FReference.Color:=MenuText;
  FTrainerState:=LabelControl('WorkoutTrainerState');FTrainerState.Color:=MenuText;
  FChart:=TWorkoutPreview.Create(Self);FChart.Name:='WorkoutChart';FChart.ShowGrid:=True;
  InsertFront(FChart);
  FPause:=Button('WorkoutPause','Pause',@ClickPause);
  FMinus:=Button('WorkoutEasier','−5%',@ClickIntensity);FMinus.Tag:=-1;
  FPlus:=Button('WorkoutHarder','+5%',@ClickIntensity);FPlus.Tag:=1;
  FWattsMinus:=Button('WorkoutPowerDown','−5 W',@ClickReference);FWattsMinus.Tag:=-1;
  FWattsPlus:=Button('WorkoutPowerUp','+5 W',@ClickReference);FWattsPlus.Tag:=1;
  FSkip:=Button('WorkoutSkip','Skip interval',@ClickSkip);
  FRestart:=Button('WorkoutRestart','Restart workout',@ClickRestart);
  FContinue:=Button('WorkoutContinue','Continue riding',@ClickContinue);
  FFinish:=Button('WorkoutFinish','Finish ride',@ClickFinish);
  RefreshControls;Resize;
end;

destructor TWorkoutHud.Destroy;
begin ReleaseTrainer;inherited;end;

procedure TWorkoutHud.ReleaseTrainer;
begin
  if FHadControl and Assigned(DeviceService)and DeviceService.HasControlDevice then
    try DeviceService.SetSimulation(0,0,RiderWeight,10);
    except on E:Exception do Logger.Warning('[Workout] '+E.Message);end;
  FHadControl:=False;FLastTarget:=-1;FLastDevice:=nil;
end;

procedure TWorkoutHud.Resize;
var S,W,LeftX,ButtonY,ChartY,ButtonHeight,ChartHeight:Single;
  procedure Place(B:TMenuButton;X,Y,ButtonWidth:Single);
  begin
    B.Width:=ButtonWidth/S;B.Height:=ButtonHeight/S;
    if FFocusMode then B.FontSize:=12/S else B.FontSize:=15/S;
    B.Anchor(hpLeft,X/S);B.Anchor(vpBottom,Y/S);
  end;
  procedure Reserve(NeededWidth:Single);
  begin
    if (LeftX>16) and (LeftX+NeededWidth>W-16) then begin
      LeftX:=16;ButtonY:=ButtonY+ButtonHeight+8;
    end;
  end;
  procedure Append(B:TMenuButton;ButtonWidth:Single);
  begin
    if not B.Exists then Exit;
    Reserve(ButtonWidth);
    Place(B,LeftX,ButtonY,ButtonWidth);LeftX:=LeftX+ButtonWidth+8;
  end;
begin
  inherited;
  if FFinish=nil then Exit;
  if FFocusMode then begin
    S:=TrainingFocusScale(UIScale);W:=EffectiveWidth*S;ButtonHeight:=30;
    Height:=408/S;
    Place(FContinue,12,10,(W-32)/2);Place(FFinish,(W+8)/2,10,(W-32)/2);
    Place(FRestart,12,46,W-160);Place(FMinus,W-140,46,60);Place(FPlus,W-72,46,60);
    Place(FWattsMinus,12,82,68);Place(FWattsPlus,W-80,82,68);
    FReference.FontSize:=13/S;FReference.Anchor(hpMiddle);FReference.Anchor(vpBottom,90/S);
    Place(FPause,12,118,(W-32)/2);Place(FSkip,(W+8)/2,118,(W-32)/2);
    FTrainerState.FontSize:=12/S;FTrainerState.MaxWidth:=(W-24)/S;
    FTrainerState.Anchor(hpLeft,12/S);FTrainerState.Anchor(vpTop,-218/S);
    FNext.FontSize:=12/S;FNext.MaxWidth:=(W-24)/S;
    FNext.Anchor(hpLeft,12/S);FNext.Anchor(vpTop,-184/S);
    FChart.Width:=(W-24)/S;FChart.Height:=64/S;
    FChart.Anchor(hpLeft,12/S);FChart.Anchor(vpBottom,232/S);
    FTitle.FontSize:=13/S;FTitle.MaxWidth:=(W-24)/S;
    FTitle.Anchor(hpLeft,12/S);FTitle.Anchor(vpTop,-10/S);
    FStep.FontSize:=15/S;FStep.MaxWidth:=(W-24)/S;
    FStep.Anchor(hpLeft,12/S);FStep.Anchor(vpTop,-50/S);
    Exit;
  end;
  S:=Max(0.65,Min(1,UIScale));W:=EffectiveWidth*S;
  ButtonHeight:=44;ChartHeight:=76;
  if FFocusMode then begin ButtonHeight:=52;ChartHeight:=150;end;
  { Keep every action directly on the panel. Wrap complete power-control groups
    when the window is narrow, and grow the panel to contain every hit target. }
  LeftX:=16;ButtonY:=12;
  Append(FPause,140);Append(FSkip,170);Append(FRestart,250);
  Append(FContinue,200);Append(FFinish,190);
  if FReference.Exists then begin
    Reserve(300);
    Append(FWattsMinus,82);
    FReference.FontSize:=14/S;
    FReference.Anchor(hpLeft,(LeftX+6)/S);
    FReference.Anchor(vpBottom,(ButtonY+10)/S);
    LeftX:=LeftX+120;
    Append(FWattsPlus,82);
  end;
  if FMinus.Exists then Reserve(140);
  Append(FMinus,66);Append(FPlus,66);
  FNext.FontSize:=13/S;FNext.MaxWidth:=Max(100,(W-32)/S);
  FNext.Anchor(hpLeft,16/S);FNext.Anchor(vpBottom,(ButtonY+ButtonHeight+10)/S);
  FTrainerState.FontSize:=13/S;FTrainerState.MaxWidth:=Max(100,(W-32)/S);
  FTrainerState.Anchor(hpLeft,16/S);FTrainerState.Anchor(vpBottom,(ButtonY+ButtonHeight+31)/S);
  ChartY:=ButtonY+ButtonHeight+62;
  Height:=(68+ChartHeight+ChartY)/S;
  FTitle.FontSize:=14/S;FTitle.MaxWidth:=Max(100,(W-32)/S);
  FTitle.Anchor(hpLeft,16/S);FTitle.Anchor(vpTop,-10/S);
  if W<1000 then FStep.FontSize:=18/S else FStep.FontSize:=24/S;
  if FFocusMode then FStep.FontSize:=28/S;
  FStep.MaxWidth:=Max(100,(W-32)/S);
  FStep.Anchor(hpLeft,16/S);FStep.Anchor(vpTop,-34/S);
  FChart.Width:=Max(20,(W-32)/S);FChart.Height:=ChartHeight/S;
  FChart.Anchor(hpLeft,16/S);FChart.Anchor(vpBottom,ChartY/S);
end;

procedure TWorkoutHud.SetFocusMode(Value:Boolean);
begin if FFocusMode=Value then Exit;FFocusMode:=Value;Resize;end;

procedure TWorkoutHud.RefreshControls;
var Done,Power:Boolean;
begin
  Done:=WorkoutPlayer.State=wsFinished;
  Power:=not Done and (WorkoutPlayer.ReferenceWatts>0);
  FPause.Exists:=not Done;FSkip.Exists:=not Done;
  FWattsMinus.Exists:=Power;FWattsPlus.Exists:=Power;FReference.Exists:=Power;
  FMinus.Exists:=Power;FPlus.Exists:=Power;
  FRestart.Exists:=True;FContinue.Exists:=True;FFinish.Exists:=True;
  if WorkoutPlayer.State=wsPaused then BindUiText(FPause,'Resume') else BindUiText(FPause,'Pause');
  FMinus.Enabled:=WorkoutPlayer.Intensity>0.25001;
  FPlus.Enabled:=WorkoutPlayer.Intensity<1.49999;
  FWattsMinus.Enabled:=WorkoutPlayer.ReferenceWatts>1;
  FWattsPlus.Enabled:=WorkoutPlayer.ReferenceWatts<2000;
end;

procedure TWorkoutHud.ClickPause(Sender:TObject);
begin
  ExecuteRideCommand(rcPause);
end;
procedure TWorkoutHud.ClickIntensity(Sender:TObject);
begin WorkoutPlayer.ChangeIntensity(TComponent(Sender).Tag*0.05);end;
procedure TWorkoutHud.ClickReference(Sender:TObject);
begin if TComponent(Sender).Tag<0 then ExecuteRideCommand(rcPowerDown)else ExecuteRideCommand(rcPowerUp);end;
procedure TWorkoutHud.ClickSkip(Sender:TObject);
begin ExecuteRideCommand(rcSkip);RefreshControls;Resize;end;
procedure TWorkoutHud.ClickRestart(Sender:TObject);
begin WorkoutPlayer.Restart;RefreshControls;Resize;end;
procedure TWorkoutHud.ClickContinue(Sender:TObject);
begin ReleaseTrainer;FChart.LoadWorkout(nil);WorkoutPlayer.Stop;Exists:=False;end;
procedure TWorkoutHud.ClickFinish(Sender:TObject);
begin if Assigned(OnFinishRide)then OnFinishRide(Self);end;

function TWorkoutHud.ControlsTrainer:Boolean;
begin Result:=WorkoutPlayer.NeedsTrainerControl;end;

procedure TWorkoutHud.Step(Seconds:Single;WorldReady:Boolean;ShowHud:Boolean);
var Fresh,CadenceFresh,Pedaling,Done:Boolean;P,C:Double;Target:Integer;NowTick:QWord;S,Next:TWorkoutSegment;
    Status,Goal,Message:String;Device:Pointer;WasDone:Boolean;
    TrainerState:TTrainerControlStatus;
begin
  Exists:=(WorkoutPlayer.State<>wsIdle)and ShowHud;
  { An overlay only hides the controls; elapsed time and trainer commands
    continue while the live ride is behind the menu. }
  if WorkoutPlayer.State=wsIdle then begin
    if FHadControl then ReleaseTrainer;
    if FChart.Workout<>nil then FChart.LoadWorkout(nil);
    Exit;
  end;
  if FChart.Workout<>WorkoutPlayer.Plan then begin
    FChart.LoadWorkout(WorkoutPlayer.Plan);
    FChart.FtpWatts:=Round(WorkoutPlayer.InitialReferenceWatts);
    RefreshControls;Resize;
  end;
  Fresh:=Assigned(DeviceService)and Assigned(DeviceService.Power)and
    DeviceService.Power.HasData and(DeviceService.Power.DataAgeSec<3);
  P:=0;if Fresh then P:=DeviceService.Power.Instant;
  CadenceFresh:=Assigned(DeviceService)and Assigned(DeviceService.Cadence)and
    DeviceService.Cadence.HasData and(DeviceService.Cadence.DataAgeSec<3);
  C:=0;if CadenceFresh then C:=DeviceService.Cadence.Instant;
  Pedaling:=WorkoutPedaling(Fresh,CadenceFresh,P,C);
  WasDone:=WorkoutPlayer.State=wsFinished;
  WorkoutPlayer.Step(Seconds,WorldReady,Pedaling,Fresh);
  Done:=WorkoutPlayer.State=wsFinished;S:=WorkoutPlayer.Stage;
  FTitle.Caption:=WorkoutPlayer.Plan.Name+'  ·  '+Format(UiText('%s elapsed · %s remaining'),
    [FormatWorkoutDuration(WorkoutPlayer.Elapsed),
     FormatWorkoutDuration(Max(0,WorkoutPlayer.Plan.TotalDuration-WorkoutPlayer.Position))]);
  if FFocusMode then FTitle.Caption:=MenuEllipsis(UiText(WorkoutPlayer.Plan.Name),FTitle.Font,
    FTitle.MaxWidth*UIScale)+LineEnding+Format(UiText('%s elapsed · %s remaining'),
    [FormatWorkoutDuration(WorkoutPlayer.Elapsed),FormatWorkoutDuration(Max(0,WorkoutPlayer.Plan.TotalDuration-WorkoutPlayer.Position))]);
  FChart.SetPlayback(WorkoutPlayer.Index,WorkoutPlayer.StageTime,WorkoutPlayer.VisualPowerScale);
  FReference.Caption:=Format(UiText('Base: %d W'),[Round(WorkoutPlayer.ReferenceWatts)]);
  if Done then Status:=UiText('Workout complete')
  else if WorkoutPlayer.State=wsPaused then Status:=UiText('Paused')+' · '+UiText('Start pedaling')
  else if WorkoutPlayer.SignalLost then Status:=UiText('Waiting for the power signal')
  else if not WorldReady then Status:=UiText('Preparing the ride…')
  else if WorkoutPlayer.State=wsReady then Status:=UiText('Start pedaling')
  else if S<>nil then Status:=UiText(WorkoutSegmentKindName(S.Kind)) else Status:='';
  Goal:=UiText('Timed intervals');
  if WorkoutPlayer.ReferenceWatts>0 then
    Goal:=IntToStr(Round(WorkoutPlayer.TargetWatts))+UiText(' W')+'  ·  '+
      IntToStr(Round(100*WorkoutPlayer.Intensity))+'%';
  if (S<>nil)and(S.Kind=wskFreeRide)then Goal:=UiText('Free effort');
  if(S<>nil)and(S.Kind<>wskFreeRide)and(WorkoutPlayer.InitialReferenceWatts>0)then
    Goal:=Goal+'  ·  '+Format(UiText('Zone %d'),[
      WorkoutPowerZone(WorkoutPlayer.TargetWatts/WorkoutPlayer.InitialReferenceWatts)]);
  FStep.Caption:=Status;
  if not Done then FStep.Caption:=IntToStr(WorkoutPlayer.Index+1)+'/'+
    IntToStr(WorkoutPlayer.Plan.Segments.Count)+'  ·  '+FStep.Caption+'  ·  '+Goal+'  ·  '+
    FormatWorkoutDuration(Ceil(WorkoutPlayer.StageRemaining));
  if FFocusMode and not Done then FStep.Caption:=IntToStr(WorkoutPlayer.Index+1)+'/'+
    IntToStr(WorkoutPlayer.Plan.Segments.Count)+' · '+Status+LineEnding+Goal+' · '+
    FormatWorkoutDuration(Ceil(WorkoutPlayer.StageRemaining));
  FNext.Caption:='';
  if(S<>nil)and(WorkoutPlayer.Index+1<WorkoutPlayer.Plan.Segments.Count)then begin
    Next:=WorkoutPlayer.Plan.Segments[WorkoutPlayer.Index+1];
    FNext.Caption:=UiText('Next: ')+UiText(WorkoutSegmentKindName(Next.Kind))+'  '+FormatWorkoutDuration(Next.Duration);
  end;
  Message:=WorkoutPlayer.TextMessage;if Message<>'' then FNext.Caption:=Message;
  if Done then BindUiText(FNext,'Your ride is still being recorded');
  FTrainerState.Caption:='';
  if Assigned(DeviceService) and not DeviceService.IsSimulationActive then begin
    TrainerState:=DeviceService.ControlStatus;
    FTrainerState.Caption:=UiText(TrainerControlMessageKey(TrainerState.State));
    if TrainerState.State in [tcsDenied,tcsTimeout,tcsFailed,tcsUnavailable,tcsUnsupported] then
      FTrainerState.Color:=Vector4(1,0.65,0.35,1)
    else FTrainerState.Color:=MenuText;
  end;
  RefreshControls;
  if Done<>WasDone then Resize;
  if not ControlsTrainer or not Assigned(DeviceService)or not DeviceService.HasControlDevice then Exit;
  Target:=0;
  if WorldReady and(WorkoutPlayer.State=wsRunning)and(S<>nil)and(S.Kind<>wskFreeRide)then
    Target:=EnsureRange(Round(WorkoutPlayer.TargetWatts),0,2000);
  Device:=Pointer(DeviceService.ControlDevice);NowTick:=GetTickCount64;
  if(NowTick-FLastSend>=500)and((Device<>FLastDevice)or(Target<>FLastTarget)or(NowTick-FLastSend>=2000))then
  begin
    try
      if not FHadControl or(Device<>FLastDevice)then DeviceService.StartTrainer;
      if Target>0 then DeviceService.SetTargetPower(Target)
      else DeviceService.SetSimulation(0,0,RiderWeight,10);
      FHadControl:=True;FLastTarget:=Target;FLastDevice:=Device;FLastSend:=NowTick;
    except on E:Exception do begin FLastSend:=NowTick;Logger.Warning('[Workout] '+E.Message);end;end;
  end;
end;
end.
