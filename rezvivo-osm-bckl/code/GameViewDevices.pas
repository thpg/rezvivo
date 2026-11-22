unit GameViewDevices;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses Classes,SysUtils,CastleUIControls,CastleControls,GameMenuTile,GameMenuTheme;
type
  TDevicesPage=class(TMenuEmbeddedPage)
  private
    FSettingsScroll:TCastleScrollView;
    FSettingsContent:TCastleUserInterface;
    FPicker:TMenuPanel;
    FPickerScroll:TCastleScrollView;
    FPickerContent:TCastleUserInterface;
    FPickerRows:TComponent;
    FPickerTitle:TCastleLabel;
    FPickerClose:TMenuButton;
    FPickerRider,FPickerRole:Integer;
    FToolbar,FAdapters:TMenuFlow;
    FScroll:TCastleScrollView;
    FContent:TCastleUserInterface;
    FRows:TComponent;
    FStatus,FTitle:TCastleLabel;
    FEmpty:TMenuPanel;
    FEmptyTitle,FEmptyHint:TCastleLabel;
    FPoll,FLastWidth:Single;
    FSignature:String;
    FWheelEdit:TMenuEdit;
    FWheelLabel:TCastleLabel;
    FAdvanced:TCastleUserInterface;
    FSimulation:TMenuPanel;
    FSimCheck:TCastleCheckbox;
    FSimHint,FSimFile:TCastleLabel;
    FSimChoices:TMenuFlow;
    FSimRoute,FSimPick:TMenuButton;
    FRefreshingSimulation,FSimWasEnabled:Boolean;
    FGradePanel:TMenuPanel;
    FGradeTitle,FGradeValue,FGradeHint:TCastleLabel;
    FGradeSlider:TCastleIntegerSlider;
    FGearCheck:TCastleCheckbox;
    FGearStatus:TCastleLabel;
    FGradeSavePending:Boolean;
    FGradeSaveDelay:Single;
    procedure OpenRolePicker(Sender:TObject);
    procedure CloseRolePicker(Sender:TObject);
    procedure ChooseRoleDevice(Sender:TObject);
    procedure BuildPicker;
    procedure BuildRole(RoleParent:TCastleUserInterface;Rider,Role:Integer;RoleWidth:Single;var Y:Single;AllDevices:Boolean);
    procedure GradeChanged(Sender:TObject);
    procedure GearChanged(Sender:TObject);
    procedure RefreshGrade;
    procedure SaveGrade;
    procedure Layout;
    procedure Refresh;
    procedure Rebuild;
    procedure ClickScan(Sender:TObject);
    procedure ClickAdvanced(Sender:TObject);
    procedure WheelChanged(Sender:TObject);
    procedure ToggleAdapter(Sender:TObject);
    procedure ToggleSimulation(Sender:TObject);
    procedure UseRouteFit(Sender:TObject);
    procedure PickSimulationFit(Sender:TObject);
    procedure SimulationFitPicked(const Path:String);
    procedure RefreshSimulation;
  public
    constructor Create(AOwner:TComponent);override;
    destructor Destroy;override;
    function HandleBack:Boolean;override;
    procedure PageShown;override;
    procedure PageHidden;override;
    procedure Resize;override;
    procedure Update(const SecondsPassed:Single;var HandleInput:Boolean);override;
  end;
var ViewDevices:TDevicesPage;
implementation
uses GameRiderPalette,Math,CastleColors,CastleVectors,UiTranslations,GameDeviceService,GameDeviceTypes,
  GameDeviceSensor,GameTransportBase,GameDeviceManager,AppSettings,TrainerData,
  CastleWindow,CastleURIUtils,GameFilePicker,ZwiftControllerProtocol,GameUserData,CastleKeysMouse;

type
  TDevicePickerPanel=class(TMenuPanel)
  public
    OnClose:TNotifyEvent;
    function Press(const Event:TInputPressRelease):Boolean;override;
    function Release(const Event:TInputPressRelease):Boolean;override;
    function Motion(const Event:TInputMotion):Boolean;override;
  end;
  TRiderDeviceButton=class(TMenuButton)
  public
    RiderIndex,Role,Action:Integer;
    Address,Provider:String;
  end;
const RoleTitles:array[0..4]of String=('Trainer','Power meters','Cadence','Heart rate','Steering / buttons');
  RoleGlyphs:array[0..4]of TMenuGlyphKind=(mgTrainer,mgPower,mgCadence,mgHeart,mgSteering);
function TDevicePickerPanel.Press(const Event:TInputPressRelease):Boolean;
begin
  Result:=inherited;
  if not Result and Event.IsKey(keyEscape)and Assigned(OnClose)then OnClose(Self);
  Result:=True;
end;
function TDevicePickerPanel.Release(const Event:TInputPressRelease):Boolean;
begin inherited;Result:=True end;
function TDevicePickerPanel.Motion(const Event:TInputMotion):Boolean;
begin inherited;Result:=True end;
function RoleKind(Role:Integer):TSensorKind;
begin case Role of 1:Result:=skPower;2:Result:=skCadence;3:Result:=skHeartRate;else Result:=skSteering end;end;
function FitsRole(E:TGameDeviceEntry;Role:Integer):Boolean;
begin
  case Role of
    0:Result:=E.IsControllable;
    1:Result:=E.DeviceInfo.SupportsPower or(E.FindSensor(skPower)<>nil);
    2:Result:=E.DeviceInfo.SupportsCadence or(E.FindSensor(skCadence)<>nil);
    3:Result:=E.DeviceInfo.SupportsHeartRate or(E.FindSensor(skHeartRate)<>nil);
    else Result:=E.DeviceInfo.SupportsSteering or E.DeviceInfo.SupportsShifting or IsZwiftControllerName(E.DeviceInfo.Name)or(E.FindSensor(skSteering)<>nil);
  end;
end;
function RoleSelected(C:TGameDeviceService;E:TGameDeviceEntry;Role:Integer):Boolean;
begin
  case Role of
    0:Result:=C.IsControlSelected(E);
    1:Result:=C.IsPowerMeterSelected(E);
    4:Result:=C.IsSensorSelected(skSteering,E)or C.IsSteeringCompanion(E)or C.IsGearController(E);
    else Result:=C.IsSensorSelected(RoleKind(Role),E);
  end;
end;

function VisibleDevice(const E:TGameDeviceEntry):Boolean;
begin
  Result:=(E.DeviceInfo.TransportType<>ttSim)or
    (Settings.GetSimulationEnabled and
      SameFileName(E.DeviceInfo.Address,'sim:'+Settings.EffectiveSimulationFitPath));
end;

constructor TDevicesPage.Create(AOwner:TComponent);
var Bg:TCastleRectangleControl;B:TMenuButton;CB:TCastleCheckbox;I:Integer;P:TTransportProvider;
begin
  inherited;FullSize:=True;Bg:=TCastleRectangleControl.Create(Self);Bg.FullSize:=True;
  Bg.Color:=MenuBackground;InsertBack(Bg);
  FTitle:=TMenuLabel.Create(Self);FTitle.CustomFont:=MenuFont(True);BindUiText(FTitle,'Devices');InsertFront(FTitle);
  FEmpty:=TMenuPanel.Create(Self);FEmpty.Exists:=False;InsertFront(FEmpty);
  FEmptyTitle:=TMenuLabel.Create(Self);FEmptyTitle.CustomFont:=MenuFont(True);BindUiText(FEmptyTitle,'Wake up your trainer');FEmpty.InsertFront(FEmptyTitle);
  FEmptyHint:=TMenuLabel.Create(Self);FEmptyHint.Color:=MenuMuted;
  BindUiText(FEmptyHint,'Turn the pedals to make your trainer discoverable. It will appear here. Heart rate and cadence sensors are optional.');FEmpty.InsertFront(FEmptyHint);
  FToolbar:=TMenuFlow.Create(Self);FToolbar.Spacing:=10;InsertFront(FToolbar);
  B:=TMenuButton.Create(Self);B.Name:='DeviceScan';BindUiText(B,'Search again');B.OnClick:=@ClickScan;FToolbar.InsertFront(B);
  B:=TMenuButton.Create(Self);B.Name:='DeviceAdvanced';BindUiText(B,'Additional settings');B.OnClick:=@ClickAdvanced;FToolbar.InsertFront(B);
  FSimulation:=TMenuPanel.Create(Self);FSimulation.Name:='DeviceSimulation';InsertFront(FSimulation);
  FSimCheck:=TCastleCheckbox.Create(Self);FSimCheck.Name:='SimulationEnabled';
  BindUiText(FSimCheck,'Simulation');FSimCheck.TextColor:=MenuText;FSimCheck.CheckboxColor:=MenuAccent;
  FSimCheck.OnChange:=@ToggleSimulation;FSimulation.InsertFront(FSimCheck);
  FSimHint:=TMenuLabel.Create(Self);FSimHint.Color:=MenuMuted;
  BindUiText(FSimHint,'Ride using a recorded FIT instead of sensors.');FSimulation.InsertFront(FSimHint);
  FSimChoices:=TMenuFlow.Create(Self);FSimChoices.Spacing:=10;FSimulation.InsertFront(FSimChoices);
  FSimRoute:=TMenuButton.Create(Self);FSimRoute.Name:='SimulationRouteFit';
  BindUiText(FSimRoute,'Route FIT');FSimRoute.OnClick:=@UseRouteFit;FSimChoices.InsertFront(FSimRoute);
  FSimPick:=TMenuButton.Create(Self);FSimPick.Name:='SimulationPickFit';
  BindUiText(FSimPick,'Choose another FIT…');FSimPick.OnClick:=@PickSimulationFit;FSimChoices.InsertFront(FSimPick);
  FSimFile:=TMenuLabel.Create(Self);FSimFile.Color:=MenuMuted;FSimulation.InsertFront(FSimFile);
  FGradePanel:=TMenuPanel.Create(Self);FGradePanel.Name:='TrainerGradePanel';InsertFront(FGradePanel);
  FGradeTitle:=TMenuLabel.Create(Self);FGradeTitle.Name:='TrainerGradeTitle';BindUiText(FGradeTitle,'Trainer gradient sensitivity');FGradePanel.InsertFront(FGradeTitle);
  FGradeValue:=TMenuLabel.Create(Self);FGradeValue.Name:='TrainerGradeValue';FGradeValue.Color:=MenuAccent;FGradePanel.InsertFront(FGradeValue);
  FGradeSlider:=TCastleIntegerSlider.Create(Self);FGradeSlider.Name:='TrainerGradeSensitivity';
  FGradeSlider.Min:=0;FGradeSlider.Max:=100;FGradeSlider.Value:=Settings.GetTrainerGradeSensitivity;
  FGradeSlider.DisplayValue:=False;FGradeSlider.OnChange:=@GradeChanged;FGradePanel.InsertFront(FGradeSlider);
  FGradeHint:=TMenuLabel.Create(Self);FGradeHint.Name:='TrainerGradeHint';FGradeHint.Color:=MenuMuted;
  BindUiText(FGradeHint,'100%: full gradient. Below 100%: cap steep slopes at 8%, then scale down. 0%: flat. Ride physics and workout power stay unchanged.');
  FGradePanel.InsertFront(FGradeHint);RefreshGrade;
  FGearCheck:=TCastleCheckbox.Create(Self);FGearCheck.Name:='VirtualGearingEnabled';
  FGearCheck.TextColor:=MenuText;FGearCheck.CheckboxColor:=MenuAccent;
  BindUiText(FGearCheck,'Virtual shifting (Click / Play / Ride)');
  FGearCheck.Checked:=Settings.GetVirtualGearingEnabled;FGearCheck.OnChange:=@GearChanged;
  FGradePanel.InsertFront(FGearCheck);
  FGearStatus:=TMenuLabel.Create(Self);FGearStatus.Color:=MenuMuted;
  FGradePanel.InsertFront(FGearStatus);
  FStatus:=TMenuLabel.Create(Self);FStatus.Color:=MenuMuted;InsertFront(FStatus);
  FAdapters:=TMenuFlow.Create(Self);FAdapters.Spacing:=16;FAdapters.Exists:=False;InsertFront(FAdapters);
  if DeviceService<>nil then for I:=0 to DeviceService.Manager.ProviderCount-1 do begin
    P:=DeviceService.Manager.Provider(I);
    if P.TransportType=ttSim then Continue;
    CB:=TCastleCheckbox.Create(Self);CB.Caption:=P.AdapterDisplayName;CB.TextColor:=MenuText;CB.CheckboxColor:=MenuAccent;CB.Tag:=I;
    CB.Checked:=DeviceService.Manager.IsProviderEnabled(P);
    CB.OnChange:=@ToggleAdapter;FAdapters.InsertFront(CB);
  end;
  FWheelLabel:=TMenuLabel.Create(Self);BindUiText(FWheelLabel,'Wheel circumference (mm)');
  FWheelLabel.Color:=MenuMuted;FAdapters.InsertFront(FWheelLabel);
  FWheelEdit:=TMenuEdit.Create(Self);FWheelEdit.Name:='SensorWheelCircumference';
  FWheelEdit.Width:=100;FWheelEdit.Height:=36;
  FWheelEdit.Text:=IntToStr(Settings.GetWheelCircumferenceMm);
  FWheelEdit.OnChange:=@WheelChanged;FAdapters.InsertFront(FWheelEdit);
  FScroll:=TMenuScrollView.Create(Self);FScroll.FullSize:=True;FScroll.Border.Left:=16;FScroll.Border.Right:=16;FScroll.Border.Bottom:=16;InsertFront(FScroll);
  FContent:=TCastleUserInterface.Create(Self);FScroll.ScrollArea.InsertFront(FContent);
  FAdvanced:=TCastleUserInterface.Create(Self);FAdvanced.FullSize:=True;FAdvanced.Border.Top:=180;
  FAdvanced.Border.Bottom:=10;FAdvanced.Exists:=False;InsertFront(FAdvanced);
  RemoveControl(FSimulation);RemoveControl(FGradePanel);RemoveControl(FAdapters);
  FSettingsScroll:=TMenuScrollView.Create(Self);FSettingsScroll.FullSize:=True;FAdvanced.InsertFront(FSettingsScroll);
  FSettingsContent:=TCastleUserInterface.Create(Self);FSettingsScroll.ScrollArea.InsertFront(FSettingsContent);
  FSettingsContent.InsertFront(FSimulation);FSettingsContent.InsertFront(FGradePanel);FSettingsContent.InsertFront(FAdapters);FAdapters.Exists:=True;
  FPicker:=TDevicePickerPanel.Create(Self);TDevicePickerPanel(FPicker).OnClose:=@CloseRolePicker;FPicker.FullSize:=True;FPicker.Exists:=False;InsertFront(FPicker);
  FPickerTitle:=TMenuLabel.Create(Self);FPickerTitle.CustomFont:=MenuFont(True);FPicker.InsertFront(FPickerTitle);
  FPickerClose:=TMenuButton.Create(Self);BindUiText(FPickerClose,'Back');FPickerClose.OnClick:=@CloseRolePicker;FPicker.InsertFront(FPickerClose);
  FPickerScroll:=TMenuScrollView.Create(Self);FPickerScroll.FullSize:=True;FPickerScroll.Border.Top:=110;FPickerScroll.Border.Left:=16;FPickerScroll.Border.Right:=16;FPickerScroll.Border.Bottom:=16;FPicker.InsertFront(FPickerScroll);
  FPickerContent:=TCastleUserInterface.Create(Self);FPickerScroll.ScrollArea.InsertFront(FPickerContent);
  RefreshSimulation;
end;
destructor TDevicesPage.Destroy;
begin SaveGrade;inherited;end;
procedure TDevicesPage.PageShown;
begin inherited;DeviceService.EnableContinuousScan;FSignature:='#refresh';Refresh;Layout;end;
procedure TDevicesPage.PageHidden;
begin SaveGrade;FPicker.Exists:=False;inherited;end;
procedure TDevicesPage.Resize;
begin inherited;if FAdvanced<>nil then begin Layout;FSignature:='#refresh';end;end;
procedure TDevicesPage.Layout;
var S,Y,H:Single;I:Integer;
begin
  S:=Max(0.65,Min(1,UIScale));FLastWidth:=EffectiveWidth;
  FTitle.FontSize:=30/S;FTitle.Anchor(hpLeft,24/S);FTitle.Anchor(vpTop,-16/S);
  FEmpty.Width:=Min(720/S,EffectiveWidth-48/S);FEmpty.Height:=180/S;
  FEmpty.Anchor(hpLeft,24/S);
  FEmptyTitle.FontSize:=21/S;FEmptyTitle.Anchor(hpLeft,24/S);FEmptyTitle.Anchor(vpTop,-24/S);
  FEmptyHint.FontSize:=15/S;FEmptyHint.MaxWidth:=FEmpty.Width-48/S;
  FEmptyHint.Anchor(hpLeft,24/S);FEmptyHint.Anchor(vpTop,-70/S);
  FToolbar.Width:=EffectiveWidth-32/S;FToolbar.Anchor(hpLeft,16/S);FToolbar.Anchor(vpTop,-78/S);
  for I:=0 to FToolbar.ControlsCount-1 do TCastleButton(FToolbar.Controls[I]).FontSize:=16/S;
  FToolbar.Arrange;
  Y:=0;
  FSimulation.Width:=Max(200,EffectiveWidth-32/S);
  FSimulation.Anchor(hpLeft,0);FSimulation.Anchor(vpTop,-Y);
  FSimCheck.FontSize:=18/S;FSimCheck.Anchor(hpLeft,16/S);FSimCheck.Anchor(vpTop,-12/S);
  FSimHint.FontSize:=14/S;FSimHint.MaxWidth:=FSimulation.Width-32/S;
  FSimHint.Anchor(hpLeft,16/S);FSimHint.Anchor(vpTop,-48/S);
  H:=48/S+FSimHint.EffectiveHeight+12/S;
  if FSimChoices.Exists then begin
    FSimChoices.Width:=FSimulation.Width-32/S;
    FSimChoices.Anchor(hpLeft,16/S);FSimChoices.Anchor(vpTop,-H);
    FSimRoute.FontSize:=15/S;FSimPick.FontSize:=15/S;FSimChoices.Arrange;
    H:=H+FSimChoices.Height+10/S;
    FSimFile.FontSize:=14/S;FSimFile.MaxWidth:=FSimulation.Width-32/S;
    FSimFile.Anchor(hpLeft,16/S);FSimFile.Anchor(vpTop,-H);
    H:=H+FSimFile.EffectiveHeight+16/S;
  end;
  FSimulation.Height:=H;Y:=Y+H+16/S;
  FGradePanel.Width:=FSimulation.Width;FGradePanel.Anchor(hpLeft,0);FGradePanel.Anchor(vpTop,-Y);
  FGradeTitle.FontSize:=17/S;FGradeTitle.MaxWidth:=FGradePanel.Width-115/S;
  FGradeTitle.Anchor(hpLeft,16/S);FGradeTitle.Anchor(vpTop,-12/S);
  FGradeValue.FontSize:=17/S;FGradeValue.Anchor(hpRight,-16/S);FGradeValue.Anchor(vpTop,-12/S);
  H:=Max(24/S,FGradeTitle.EffectiveHeight)+20/S;
  FGradeSlider.Width:=FGradePanel.Width-32/S;FGradeSlider.Height:=26/S;
  FGradeSlider.Anchor(hpLeft,16/S);FGradeSlider.Anchor(vpTop,-H);
  H:=H+34/S;FGradeHint.FontSize:=13/S;FGradeHint.MaxWidth:=FGradePanel.Width-32/S;
  FGradeHint.Anchor(hpLeft,16/S);FGradeHint.Anchor(vpTop,-H);
  H:=H+FGradeHint.EffectiveHeight+12/S;
  FGearCheck.FontSize:=15/S;FGearCheck.Anchor(hpLeft,16/S);FGearCheck.Anchor(vpTop,-H);
  H:=H+30/S;FGearStatus.FontSize:=13/S;FGearStatus.MaxWidth:=FGradePanel.Width-32/S;
  FGearStatus.Anchor(hpLeft,16/S);FGearStatus.Anchor(vpTop,-H);
  FGradePanel.Height:=H+FGearStatus.EffectiveHeight+12/S;Y:=Y+FGradePanel.Height+12/S;
  FStatus.FontSize:=17/S;FStatus.MaxWidth:=EffectiveWidth-32/S;FStatus.Anchor(hpLeft,16/S);FStatus.Anchor(vpTop,-Y);
  FScroll.Border.Top:=Y+FStatus.EffectiveHeight+16/S;
  FEmpty.Anchor(vpTop,-FScroll.Border.Top);
  FAdapters.Width:=EffectiveWidth-32/S;FAdapters.Anchor(hpLeft,0);FAdapters.Anchor(vpTop,-FScroll.Border.Top);FAdapters.Arrange;
  FAdvanced.Border.Top:=FScroll.Border.Top+FAdapters.Height+18/S;
  FAdvanced.Border.Left:=16/S;FAdvanced.Border.Right:=16/S;
  FSettingsContent.Width:=FSimulation.Width;
  FSettingsContent.Height:=FScroll.Border.Top+FAdapters.Height+24/S;
  FSettingsScroll.ScrollArea.Height:=FSettingsContent.Height;
  Y:=FToolbar.Height+94/S;
  FStatus.Anchor(vpTop,-Y);
  FScroll.Border.Top:=Y+FStatus.EffectiveHeight+16/S;
  FAdvanced.Border.Top:=FScroll.Border.Top;
  FPickerTitle.FontSize:=19/S;FPickerTitle.MaxWidth:=EffectiveWidth-32/S;
  FPickerTitle.Anchor(hpLeft,16/S);FPickerTitle.Anchor(vpTop,-12/S);
  FPickerClose.FontSize:=15/S;FPickerClose.Anchor(hpLeft,16/S);FPickerClose.Anchor(vpTop,-Max(62/S,FPickerTitle.EffectiveHeight+24/S));
  FPickerScroll.Border.Top:=Max(110/S,FPickerTitle.EffectiveHeight+72/S);
end;
procedure TDevicesPage.Update(const SecondsPassed:Single;var HandleInput:Boolean);
begin
  inherited;FPoll:=FPoll+SecondsPassed;
  if FGradeSavePending then begin
    FGradeSaveDelay:=FGradeSaveDelay-SecondsPassed;
    if FGradeSaveDelay<=0 then SaveGrade;
  end;
  if Abs(FLastWidth-EffectiveWidth)>1 then begin Layout;FSignature:='#refresh';end;
  if FPoll<0.4 then Exit;FPoll:=0;Refresh;
end;
procedure TDevicesPage.Refresh;
var I,R,Role:Integer;E:TGameDeviceEntry;C:TGameDeviceService;Sig:String;
begin
  if DeviceService=nil then Exit;
  RefreshSimulation;RefreshGrade;Sig:=IntToStr(LocalRiderCount)+UiLanguage;
  for R:=0 to LocalRiderCount-1 do begin
    C:=DeviceService.ForRider(R);Sig:=Sig+'|'+LocalRider(R).Key+LocalRider(R).DisplayName+C.SelectedControlName;
    if LocalRiderCount>1 then Sig:=Sig+'|'+RiderPaletteSignature(R);
    for Role:=1 to 4 do Sig:=Sig+'|'+C.SelectedSensorName(RoleKind(Role));
    for I:=0 to DeviceService.Devices.Count-1 do begin
      E:=DeviceService.Devices[I];Sig:=Sig+'|'+E.DeviceInfo.ProviderName+E.DeviceInfo.Address+IntToStr(Ord(E.ConnectionState))+IntToStr(E.Sensors.Count)+IntToStr(DeviceService.DeviceOwner(E));
      for Role:=0 to 4 do Sig:=Sig+BoolToStr(FitsRole(E,Role),True)+BoolToStr(RoleSelected(C,E,Role),True);
      Sig:=Sig+E.DisplayName+BoolToStr(C.IsSensorSelected(skPower,E),True)+BoolToStr(C.IsSteeringCompanion(E),True)+BoolToStr(C.IsGearController(E),True)+BoolToStr(C.IsSensorSelected(skSteering,E),True);
    end;
  end;
  if Sig<>FSignature then begin FSignature:=Sig;Rebuild;if FPicker.Exists then BuildPicker;end;
  FEmpty.Exists:=False;
  BindUiText(FStatus,'Select devices for each rider. A device belongs to one rider.');
end;

procedure TDevicesPage.BuildRole(RoleParent:TCastleUserInterface;Rider,Role:Integer;RoleWidth:Single;var Y:Single;AllDevices:Boolean);
var I,N,DeviceRider:Integer;E:TGameDeviceEntry;C:TGameDeviceService;Card:TMenuPanel;B:TRiderDeviceButton;
  L:TCastleLabel;Glyph:TMenuGlyph;RowsRoot:TCastleUserInterface;RowsScroll:TMenuScrollView;
  S,RowY,BodyTop:Single;Selected,Compatible:Boolean;Text:String;
  procedure AddChoice(const Caption:String;Action:Integer;Enabled:Boolean=True);
  begin
    B:=TRiderDeviceButton.Create(Card);B.RiderIndex:=Rider;B.Role:=Role;B.Action:=Action;
    if E<>nil then begin B.Address:=E.DeviceInfo.Address;B.Provider:=E.DeviceInfo.ProviderName end;
    B.Name:=Format('Rider%dRole%dAction%dRow%d',[Rider,Role,Action,Round(RowY)]);
    B.Enabled:=Enabled;B.FontSize:=14/S;B.AutoSize:=False;B.Width:=RoleWidth-24/S;
    B.AutoIcon:=False;
    B.Caption:=MenuSummary(Caption,B.Font,Max(40,(B.Width-32/S)*UIScale),2);
    B.Height:=Max(40/S,B.Font.TextHeight(B.Caption)/Max(0.01,UIScale)+16/S);
    B.Anchor(hpLeft,12/S);B.Anchor(vpTop,-RowY);B.OnClick:=@ChooseRoleDevice;RowsRoot.InsertFront(B);
    SelectMenuButton(B,Selected and(Action=0));
    if LocalRiderCount>1 then ApplyRiderMenuButtonPalette(B,Rider,Selected and(Action=0));
    RowY:=RowY+B.Height+6/S;
  end;
begin
  S:=Max(0.65,Min(1,UIScale));C:=DeviceService.ForRider(Rider);E:=nil;Selected:=False;
  if AllDevices then Card:=TMenuPanel.Create(FPickerRows)else Card:=TMenuPanel.Create(FRows);
  if LocalRiderCount>1 then begin
    Card.Color:=RiderPanelPalette(Rider).Surface;Card.Stroke:=RiderPanelPalette(Rider).Border;
  end;
  Card.Width:=RoleWidth;Card.Anchor(vpTop,-Y);RoleParent.InsertFront(Card);
  B:=TRiderDeviceButton.Create(Card);B.RiderIndex:=Rider;B.Role:=Role;B.AutoIcon:=False;
  B.Name:=Format('Rider%dRole%dDevices',[Rider,Role]);
  B.Caption:='';B.FontSize:=17/S;B.AutoSize:=False;B.Width:=RoleWidth-16/S;
  B.Anchor(hpLeft,8/S);B.Anchor(vpTop,-8/S);B.Style:=mbGhost;
  B.OnClick:=@OpenRolePicker;B.Enabled:=not AllDevices;Card.InsertFront(B);
  Glyph:=TMenuGlyph.Create(Card);Glyph.Kind:=RoleGlyphs[Role];Glyph.Color:=MenuAccent;
  if LocalRiderCount>1 then Glyph.Color:=RiderPanelPalette(Rider).Accent;
  Glyph.Width:=32/S;Glyph.Height:=32/S;Glyph.Anchor(hpLeft,8/S);Glyph.Anchor(vpMiddle);
  Glyph.CapturesEvents:=False;B.InsertFront(Glyph);
  L:=TMenuLabel.Create(Card);L.Caption:=UiText(RoleTitles[Role]);L.CustomFont:=MenuFont(True);
  L.FontSize:=17/S;L.MaxWidth:=RoleWidth-90/S;L.CapturesEvents:=False;
  L.Anchor(hpLeft,52/S);L.Anchor(vpMiddle);B.InsertFront(L);
  B.Height:=Max(52/S,L.EffectiveHeight+16/S);BodyTop:=B.Height+20/S;
  RowsScroll:=nil;
  if AllDevices then begin RowsRoot:=Card;RowY:=BodyTop end
  else begin
    RowsScroll:=TMenuScrollView.Create(Card);RowsScroll.Width:=RoleWidth;
    RowsScroll.Anchor(vpTop,-BodyTop);Card.InsertFront(RowsScroll);
    RowsRoot:=TCastleUserInterface.Create(Card);RowsRoot.Width:=RoleWidth;
    RowsRoot.Anchor(vpTop);RowsScroll.ScrollArea.InsertFront(RowsRoot);RowY:=0;
  end;
  if AllDevices then AddChoice(UiText('None'),5);
  if Role=0 then Text:=C.SelectedControlName else Text:=C.SelectedSensorName(RoleKind(Role));
  if Text<>''then begin
    L:=TMenuLabel.Create(Card);L.Caption:=UiText('Selected')+': '+Text;L.FontSize:=13/S;L.Color:=MenuAccent;L.MaxWidth:=RoleWidth-24/S;
    L.Anchor(hpLeft,12/S);L.Anchor(vpTop,-RowY);RowsRoot.InsertFront(L);RowY:=RowY+L.EffectiveHeight+12/S;
  end;
  N:=0;
  for I:=0 to DeviceService.Devices.Count-1 do begin
    E:=DeviceService.Devices[I];if not VisibleDevice(E)then Continue;
    Compatible:=FitsRole(E,Role);if not AllDevices and not Compatible then Continue;
    DeviceRider:=DeviceService.DeviceOwner(E);Selected:=RoleSelected(C,E,Role);Text:=E.DisplayName;
    if Selected then begin
      if(Role=1)and C.IsSensorSelected(skPower,E)then Text:='✓ '+UiText('Primary')+': '+Text else Text:='✓ '+Text;
    end;
    if(DeviceRider>=0)and(DeviceRider<>Rider)then Text:=Text+' / '+Format(UiText('Rider %d'),[DeviceRider+1]);
    if not Compatible then Text:=Text+' / '+UiText('Not compatible')
    else if E.ConnectionState=gdcsConnected then Text:=Text+' / '+UiText('Connected')
    else if E.ConnectionState=gdcsConnecting then Text:=Text+' / '+UiText('Connecting')else Text:=Text+' / '+UiText('Available');
    AddChoice(Text,0,Compatible);Inc(N);
    if Compatible then begin
      if(Role=1)and C.IsPowerMeterSelected(E)and not C.IsSensorSelected(skPower,E)then AddChoice(UiText('Use as primary power'),4);
      if Role=4 then begin
        if C.IsSensorSelected(skSteering,E)then AddChoice(UiText('Center steering'),1);
        if C.CanPairSteering(E)then begin
          if C.IsSteeringCompanion(E)then AddChoice(UiText('Remove from steering pair'),2)else AddChoice(UiText('Add to steering pair'),2);
        end;
        if E.DeviceInfo.SupportsShifting or IsZwiftControllerName(E.DeviceInfo.Name)then begin
          if C.IsGearController(E)then AddChoice(UiText('Stop using for shifting'),3)else AddChoice(UiText('Use for shifting'),3);
        end;
      end;
    end;
  end;
  if N=0 then begin
    L:=TMenuLabel.Create(Card);L.Caption:=UiText('No devices yet. Search again or open the device list.');L.FontSize:=13/S;L.Color:=MenuMuted;L.MaxWidth:=RoleWidth-24/S;
    L.Anchor(hpLeft,12/S);L.Anchor(vpTop,-RowY);RowsRoot.InsertFront(L);RowY:=RowY+L.EffectiveHeight+12/S;
  end;
  if RowsScroll<>nil then begin
    RowsRoot.Height:=RowY;RowsScroll.ScrollArea.Height:=RowY;
    RowsScroll.Height:=Min(220/S,Max(42/S,RowY));
    Card.Height:=Max(168/S,BodyTop+RowsScroll.Height+10/S);
  end else Card.Height:=RowY+8/S;
  Y:=Y+Card.Height+12/S;
end;

procedure TDevicesPage.Rebuild;
var R,Role,Columns,RowColumns,J:Integer;L:TCastleLabel;
  S,W,Y,Gap,TileWidth,TileY,RowHeight:Single;
  Hosts:array[0..2]of TCastleUserInterface;
begin
  FContent.ClearControls;FreeAndNil(FRows);FRows:=TComponent.Create(Self);
  S:=Max(0.65,Min(1,UIScale));W:=Max(180,EffectiveWidth-48/S);Y:=0;
  Gap:=12/S;Columns:=Min(3,Max(1,Floor((W+Gap)/(240/S+Gap))));
  for R:=0 to LocalRiderCount-1 do begin
    L:=TMenuLabel.Create(FRows);L.Caption:=Format(UiText('Rider %d'),[R+1])+' / '+LocalRider(R).DisplayName;
    L.FontSize:=22/S;L.CustomFont:=MenuFont(True);L.MaxWidth:=W;L.Anchor(vpTop,-Y);FContent.InsertFront(L);Y:=Y+L.EffectiveHeight+14/S;
    Role:=0;
    while Role<=4 do begin
      RowColumns:=Min(Columns,5-Role);TileWidth:=(W-(RowColumns-1)*Gap)/RowColumns;RowHeight:=0;
      for J:=0 to RowColumns-1 do begin
        Hosts[J]:=TCastleUserInterface.Create(FRows);Hosts[J].Width:=TileWidth;
        Hosts[J].Anchor(hpLeft,J*(TileWidth+Gap));Hosts[J].Anchor(vpTop,-Y);
        FContent.InsertFront(Hosts[J]);TileY:=0;
        BuildRole(Hosts[J],R,Role+J,TileWidth,TileY,False);
        Hosts[J].Height:=TileY-12/S;RowHeight:=Max(RowHeight,Hosts[J].Height);
      end;
      { Match row heights even when one role has more discovered devices.
        Long lists scroll inside the tile; every matching device stays present. }
      for J:=0 to RowColumns-1 do begin
        Hosts[J].Height:=RowHeight;
        TMenuPanel(Hosts[J].Controls[0]).Height:=RowHeight;
      end;
      Y:=Y+RowHeight+Gap;Inc(Role,RowColumns);
    end;
    Y:=Y+16/S;
  end;
  FContent.Width:=W;FContent.Height:=Max(100,Y);FScroll.ScrollArea.Height:=FContent.Height;
end;
procedure TDevicesPage.OpenRolePicker(Sender:TObject);
var B:TRiderDeviceButton;
begin
  B:=Sender as TRiderDeviceButton;FPickerRider:=B.RiderIndex;FPickerRole:=B.Role;
  FPicker.Exists:=True;BuildPicker;
end;
procedure TDevicesPage.CloseRolePicker(Sender:TObject);
begin FPicker.Exists:=False;end;
function TDevicesPage.HandleBack:Boolean;
begin
  if FPicker.Exists then begin FPicker.Exists:=False;Exit(True)end;
  if FAdvanced.Exists then begin ClickAdvanced(nil);Exit(True)end;
  Result:=inherited HandleBack;
end;
procedure TDevicesPage.BuildPicker;
var Y,W:Single;
begin
  if FPickerRider>=LocalRiderCount then begin FPicker.Exists:=False;Exit end;
  FPickerContent.ClearControls;FreeAndNil(FPickerRows);FPickerRows:=TComponent.Create(Self);
  FPickerTitle.Caption:=Format(UiText('Rider %d'),[FPickerRider+1])+' / '+LocalRider(FPickerRider).DisplayName+' / '+UiText(RoleTitles[FPickerRole]);
  W:=Max(180,EffectiveWidth-48/Max(0.65,Min(1,UIScale)));Y:=0;
  BuildRole(FPickerContent,FPickerRider,FPickerRole,W,Y,True);
  FPickerContent.Width:=W;FPickerContent.Height:=Y;FPickerScroll.ScrollArea.Height:=Y;Layout;
end;
procedure TDevicesPage.ChooseRoleDevice(Sender:TObject);
var B:TRiderDeviceButton;C:TGameDeviceService;E:TGameDeviceEntry;I:Integer;Sensor:TDeviceSensor;
begin
  B:=Sender as TRiderDeviceButton;if B.RiderIndex>=LocalRiderCount then Exit;
  C:=DeviceService.ForRider(B.RiderIndex);
  if B.Action=5 then begin
    case B.Role of
      0:C.SetControlDevice(nil);
      1:C.ClearPowerMeters;
      4:C.ClearSteeringControllers;
      else C.ClearSensor(RoleKind(B.Role));
    end;
    FSignature:='#refresh';Exit;
  end;
  E:=nil;
  for I:=0 to DeviceService.Devices.Count-1 do
    if SameText(DeviceService.Devices[I].DeviceInfo.Address,B.Address)and SameText(DeviceService.Devices[I].DeviceInfo.ProviderName,B.Provider)then begin E:=DeviceService.Devices[I];Break end;
  if(E=nil)or not FitsRole(E,B.Role)then Exit;
  case B.Action of
    1:C.CenterSteering;
    2:if C.IsSteeringCompanion(E)then C.SelectSteeringCompanion(nil)else C.SelectSteeringCompanion(E);
    3:C.SelectGearController(E);
    4:begin Sensor:=E.FindSensor(skPower);if Sensor<>nil then C.AssignSensor(skPower,Sensor)end;
    else case B.Role of
      0:if C.IsControlSelected(E)then C.SetControlDevice(nil)else C.SetControlDevice(E);
      1:C.TogglePowerMeter(E);
      4:begin
        Sensor:=E.FindSensor(skSteering);
        if Sensor<>nil then begin if C.IsSensorSelected(skSteering,E)then C.ClearSensor(skSteering)else C.AssignSensor(skSteering,Sensor)end
        else if E.DeviceInfo.SupportsShifting or IsZwiftControllerName(E.DeviceInfo.Name)then C.SelectGearController(E);
      end;
      else begin
        Sensor:=E.FindSensor(RoleKind(B.Role));
        if Sensor<>nil then begin if C.IsSensorSelected(RoleKind(B.Role),E)then C.ClearSensor(RoleKind(B.Role))else C.AssignSensor(RoleKind(B.Role),Sensor)end;
      end;
    end;
  end;
  if(E.ConnectionState in[gdcsDisconnected,gdcsError])and RoleSelected(C,E,B.Role)then C.ConnectDevice(E);
  FSignature:='#refresh';
end;
procedure TDevicesPage.ClickScan(Sender:TObject);
begin DeviceService.StartScan;end;
procedure TDevicesPage.ClickAdvanced(Sender:TObject);
begin
  FAdvanced.Exists:=not FAdvanced.Exists;FScroll.Exists:=not FAdvanced.Exists;
  FPicker.Exists:=False;Layout;
end;
procedure TDevicesPage.WheelChanged(Sender:TObject);
var V:Integer;
begin
  if not TryStrToInt(Trim(FWheelEdit.Text),V) or (V<500) or (V>4000) then Exit;
  Settings.SetWheelCircumferenceMm(V);
  DeviceService.Manager.RefreshWheelCircumference;
end;

procedure TDevicesPage.ToggleAdapter(Sender:TObject);
var CB:TCastleCheckbox;P:TTransportProvider;
begin
  CB:=Sender as TCastleCheckbox;P:=DeviceService.Manager.Provider(CB.Tag);if P=nil then Exit;
  DeviceService.Manager.SetProviderEnabled(P,CB.Checked);DeviceService.StartScan;
end;

procedure TDevicesPage.RefreshSimulation;
var Enabled:Boolean;Path,Caption:String;
begin
  Enabled:=Settings.GetSimulationEnabled;
  FRefreshingSimulation:=True;
  try FSimCheck.Checked:=Enabled;finally FRefreshingSimulation:=False;end;
  FSimChoices.Exists:=Enabled;FSimFile.Exists:=Enabled;
  SelectMenuButton(FSimRoute,Settings.GetSimulationUseRoute);
  SelectMenuButton(FSimPick,not Settings.GetSimulationUseRoute);
  Path:=Settings.EffectiveSimulationFitPath;
  if Path=''then Caption:=UiText('Select a FIT route in Real World or choose another FIT here.')
  else if not FileExists(Path)then Caption:=UiText('File not found: ')+ExtractFileName(Path)
  else Caption:=ExtractFileName(Path);
  if Caption<>FSimFile.Caption then begin FSimFile.Caption:=Caption;FLastWidth:=-1;end;
  if FSimWasEnabled<>Enabled then begin FSimWasEnabled:=Enabled;FLastWidth:=-1;end;
end;

procedure TDevicesPage.RefreshGrade;
var OldGearStatus:String;
begin
  if not FGradeSavePending then FGradeSlider.Value:=Settings.GetTrainerGradeSensitivity;
  FGradeValue.Caption:=IntToStr(FGradeSlider.Value)+'%';
  if FGearCheck<>nil then begin
    OldGearStatus:=FGearStatus.Caption;
    FGearCheck.Checked:=Settings.GetVirtualGearingEnabled;
    if DeviceService<>nil then case Ord(DeviceService.GearingBackend)of
      0:BindUiText(FGearStatus,'Virtual shifting is off.');
      1:BindUiText(FGearStatus,'Native trainer gears. Left: easier, right: harder. ERG keeps workout power.');
      2:BindUiText(FGearStatus,'Calculated load via target power. A live cadence sensor is required. Trainer response may vary.');
      else BindUiText(FGearStatus,'Connect a controllable trainer. Click V2 and newer Ride firmware may need activation in Zwift.');
    end;
    if FGearStatus.Caption<>OldGearStatus then Layout;
  end;
end;
procedure TDevicesPage.GearChanged(Sender:TObject);
begin
  Settings.SetVirtualGearingEnabled(FGearCheck.Checked);
  RefreshGrade;Layout;
end;

procedure TDevicesPage.GradeChanged(Sender:TObject);
begin
  FGradeSavePending:=True;FGradeSaveDelay:=0.3;
  FGradeValue.Caption:=IntToStr(FGradeSlider.Value)+'%';
end;

procedure TDevicesPage.SaveGrade;
begin
  if FGradeSavePending and (Settings<>nil)then begin
    FGradeSavePending:=False;Settings.SetTrainerGradeSensitivity(FGradeSlider.Value);
  end;
end;

procedure TDevicesPage.ToggleSimulation(Sender:TObject);
begin
  if FRefreshingSimulation then Exit;
  Settings.SetSimulationEnabled(FSimCheck.Checked);
  FSignature:='#refresh';Refresh;Layout;
end;

procedure TDevicesPage.UseRouteFit(Sender:TObject);
begin
  Settings.SetSimulationUseRoute(True);
  FSignature:='#refresh';Refresh;Layout;
end;

procedure TDevicesPage.PickSimulationFit(Sender:TObject);
var Url:String;
begin
  Url:=Settings.GetSimulationFitPath;
  if Url=''then Url:=Settings.EffectiveSimulationFitPath;
  PickGameFile(Self,UiText('Choose FIT file for simulation'),UiText('FIT files (*.fit)|*.fit'),
    @SimulationFitPicked,Url);
end;
procedure TDevicesPage.SimulationFitPicked(const Path:String);
begin
  Settings.SetSimulationFitPath(Path);Settings.SetSimulationUseRoute(False);
  FSignature:='#refresh';Refresh;Layout;
end;
end.
