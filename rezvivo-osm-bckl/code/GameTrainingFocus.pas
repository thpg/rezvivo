unit GameTrainingFocus;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses Classes,CastleControls,CastleUIControls,GameTrainingWindow;
type
  TTrainingFocusPanel=class(TCastleRectangleControl)
  private
    FPower,FCadence,FHeart,FWork,FHint:TCastleLabel;
    FOnTop:TCastleCheckbox;
    FWindow:TTrainingWindow;
    FRefresh:Single;
    procedure ChangeOnTop(Sender:TObject);
  public
    constructor Create(AOwner:TComponent);override;
    destructor Destroy;override;
    procedure SyncWindow(Active:Boolean);
    procedure Resize;override;
    procedure Update(const SecondsPassed:Single;var HandleInput:Boolean);override;
  end;
implementation
uses Math,SysUtils,CastleVectors,GameMenuTheme,UiTranslations,GameDeviceService,
  GameDailyTraining,GameSensorLog,AppSettings;
constructor TTrainingFocusPanel.Create(AOwner:TComponent);
  function Metric(const N:String):TCastleLabel;
  begin Result:=TMenuLabel.Create(Self);Result.Name:=N;InsertFront(Result);end;
begin
  inherited;FullSize:=True;Color:=MenuBackground;
  FWindow:=TTrainingWindow.Create;
  FWindow.SetOnTop(Settings.GetTrainingFocusOnTop);
  FPower:=Metric('FocusPower');FPower.CustomFont:=MenuFont(True);
  FCadence:=Metric('FocusCadence');FHeart:=Metric('FocusHeart');FWork:=Metric('FocusWork');
  FHint:=Metric('FocusHint');FHint.Color:=MenuMuted;
  FOnTop:=TCastleCheckbox.Create(Self);FOnTop.Name:='TrainingFocusOnTop';
  BindUiText(FOnTop,'Always on top');FOnTop.CustomFont:=MenuFont;
  FOnTop.TextColor:=MenuText;FOnTop.CheckboxColor:=MenuAccent;
  FOnTop.Checked:=Settings.GetTrainingFocusOnTop;FOnTop.OnChange:=@ChangeOnTop;InsertFront(FOnTop);
  Resize;
end;
destructor TTrainingFocusPanel.Destroy;
begin FWindow.Free;inherited;end;
procedure TTrainingFocusPanel.SyncWindow(Active:Boolean);
begin FWindow.SetActive(Active);end;
procedure TTrainingFocusPanel.ChangeOnTop(Sender:TObject);
begin FWindow.SetOnTop(FOnTop.Checked);Settings.SetTrainingFocusOnTop(FOnTop.Checked);end;
procedure TTrainingFocusPanel.Resize;
var S,W:Single;
begin
  inherited;if FOnTop=nil then Exit;S:=TrainingFocusScale(UIScale);W:=EffectiveWidth*S;
  FOnTop.FontSize:=14/S;FOnTop.Anchor(hpLeft,16/S);FOnTop.Anchor(vpTop,-54/S);
  FOnTop.CheckboxSize:=18/S;FOnTop.CaptionMargin:=8/S;
  FPower.FontSize:=48/S;FPower.Anchor(hpMiddle);FPower.Anchor(vpTop,-84/S);
  FCadence.FontSize:=22/S;FCadence.Anchor(hpLeft,20/S);FCadence.Anchor(vpTop,-148/S);
  FHeart.FontSize:=22/S;FHeart.Anchor(hpRight,-20/S);FHeart.Anchor(vpTop,-148/S);
  FWork.FontSize:=13/S;FWork.Anchor(hpMiddle);FWork.Anchor(vpTop,-186/S);
  FHint.FontSize:=12/S;FHint.Anchor(hpLeft,16/S);FHint.Anchor(vpTop,-214/S);FHint.MaxWidth:=Max(100,W-32)/S;
end;
procedure TTrainingFocusPanel.Update(const SecondsPassed:Single;var HandleInput:Boolean);
var P,C,H:String;Fmt:TFormatSettings;
begin
  inherited;FRefresh:=FRefresh-SecondsPassed;if FRefresh>0 then Exit;FRefresh:=0.1;
  P:='—';C:='—';H:='—';
  if DeviceService<>nil then begin
    if(DeviceService.Power<>nil)and DeviceService.Power.HasData and(DeviceService.Power.DataAgeSec<3)then P:=IntToStr(Round(DeviceService.Power.Instant));
    if(DeviceService.Cadence<>nil)and DeviceService.Cadence.HasData and(DeviceService.Cadence.DataAgeSec<3)then C:=IntToStr(Round(DeviceService.Cadence.Instant));
    if(DeviceService.HR<>nil)and DeviceService.HR.HasData and(DeviceService.HR.DataAgeSec<3)then H:=IntToStr(Round(DeviceService.HR.Instant));
  end;
  FPower.Caption:=P+UiText(' W');FCadence.Caption:=C+' '+UiText('rpm');FHeart.Caption:=H+' '+UiText('bpm');
  Fmt:=DefaultFormatSettings;Fmt.DecimalSeparator:='.';
  FWork.Caption:=Format('%.1f kJ  ·  %.1f TSS',[DailyTraining.WorkJoules/1000,DailyTraining.TSS],Fmt);
  FHint.Caption:=SensorLog.ErrorText;
end;
end.
