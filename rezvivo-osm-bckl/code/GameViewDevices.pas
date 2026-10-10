unit GameViewDevices;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses Classes,SysUtils,CastleUIControls,CastleControls,GameMenuTile,GameMenuTheme;
type
  TDevicesPage=class(TMenuEmbeddedPage)
  private
    FToolbar,FAdapters:TMenuFlow;
    FScroll:TCastleScrollView;
    FContent:TCastleUserInterface;
    FRows:TComponent;
    FValues:array of TCastleLabel;
    FStatus,FTitle:TCastleLabel;
    FEmpty:TMenuPanel;
    FEmptyTitle,FEmptyHint:TCastleLabel;
    FPoll,FLastWidth:Single;
    FSignature:String;
    FWheelEdit:TMenuEdit;
    FWheelLabel:TCastleLabel;
    FAdvanced:TCastleUserInterface;
    FSensorPanel:TObject;
    FSimulation:TMenuPanel;
    FSimCheck:TCastleCheckbox;
    FSimHint,FSimFile:TCastleLabel;
    FSimChoices:TMenuFlow;
    FSimRoute,FSimPick:TMenuButton;
    FRefreshingSimulation,FSimWasEnabled:Boolean;
    FGradePanel:TMenuPanel;
    FGradeTitle,FGradeValue,FGradeHint:TCastleLabel;
    FGradeSlider:TCastleIntegerSlider;
    FGradeSavePending:Boolean;
    FGradeSaveDelay:Single;
    procedure GradeChanged(Sender:TObject);
    procedure RefreshGrade;
    procedure SaveGrade;
    procedure Layout;
    procedure Refresh;
    procedure Rebuild;
    procedure ClickDevice(Sender:TObject);
    procedure ClickDisconnect(Sender:TObject);
    procedure ClickCenterSteering(Sender:TObject);
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
    procedure PageShown;override;
    procedure PageHidden;override;
    procedure Resize;override;
    procedure Update(const SecondsPassed:Single;var HandleInput:Boolean);override;
  end;
var ViewDevices:TDevicesPage;
implementation
uses Math,CastleColors,CastleVectors,UiTranslations,GameDeviceService,GameDeviceTypes,
  GameDeviceSensor,GameTransportBase,GameDeviceManager,GameSensorPanel,AppSettings,TrainerData,
  CastleWindow,CastleURIUtils,GameFilePicker;

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
  FEmpty:=TMenuPanel.Create(Self);InsertFront(FEmpty);
  FEmptyTitle:=TMenuLabel.Create(Self);FEmptyTitle.CustomFont:=MenuFont(True);BindUiText(FEmptyTitle,'Wake up your trainer');FEmpty.InsertFront(FEmptyTitle);
  FEmptyHint:=TMenuLabel.Create(Self);FEmptyHint.Color:=MenuMuted;
  BindUiText(FEmptyHint,'Turn the pedals to make your trainer discoverable. It will appear here. Heart rate and cadence sensors are optional.');FEmpty.InsertFront(FEmptyHint);
  FToolbar:=TMenuFlow.Create(Self);FToolbar.Spacing:=10;InsertFront(FToolbar);
  B:=TMenuButton.Create(Self);B.Name:='DeviceScan';BindUiText(B,'Search again');B.OnClick:=@ClickScan;FToolbar.InsertFront(B);
  B:=TMenuButton.Create(Self);B.Name:='DeviceAdvanced';BindUiText(B,'Additional settings');B.OnClick:=@ClickAdvanced;FToolbar.InsertFront(B);
  FSimulation:=TMenuPanel.Create(Self);FSimulation.Name:='DeviceSimulation';InsertFront(FSimulation);
  FSimCheck:=TCastleCheckbox.Create(Self);FSimCheck.Name:='SimulationEnabled';
  BindUiText(FSimCheck,'Simulation');FSimCheck.TextColor:=White;FSimCheck.CheckboxColor:=White;
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
  FStatus:=TMenuLabel.Create(Self);FStatus.Color:=White;InsertFront(FStatus);
  FAdapters:=TMenuFlow.Create(Self);FAdapters.Spacing:=16;FAdapters.Exists:=False;InsertFront(FAdapters);
  if DeviceService<>nil then for I:=0 to DeviceService.Manager.ProviderCount-1 do begin
    P:=DeviceService.Manager.Provider(I);
    if P.TransportType=ttSim then Continue;
    CB:=TCastleCheckbox.Create(Self);CB.Caption:=P.AdapterDisplayName;CB.TextColor:=White;CB.CheckboxColor:=White;CB.Tag:=I;
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
  RefreshSimulation;
end;
destructor TDevicesPage.Destroy;
begin SaveGrade;FreeAndNil(FSensorPanel);inherited;end;
procedure TDevicesPage.PageShown;
begin inherited;DeviceService.EnableContinuousScan;FSignature:='#refresh';Refresh;Layout;end;
procedure TDevicesPage.PageHidden;
begin SaveGrade;inherited;end;
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
  Y:=FToolbar.Height+94/S;
  FSimulation.Width:=Max(200,EffectiveWidth-32/S);
  FSimulation.Anchor(hpLeft,16/S);FSimulation.Anchor(vpTop,-Y);
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
  FGradePanel.Width:=FSimulation.Width;FGradePanel.Anchor(hpLeft,16/S);FGradePanel.Anchor(vpTop,-Y);
  FGradeTitle.FontSize:=17/S;FGradeTitle.MaxWidth:=FGradePanel.Width-115/S;
  FGradeTitle.Anchor(hpLeft,16/S);FGradeTitle.Anchor(vpTop,-12/S);
  FGradeValue.FontSize:=17/S;FGradeValue.Anchor(hpRight,-16/S);FGradeValue.Anchor(vpTop,-12/S);
  H:=Max(24/S,FGradeTitle.EffectiveHeight)+20/S;
  FGradeSlider.Width:=FGradePanel.Width-32/S;FGradeSlider.Height:=26/S;
  FGradeSlider.Anchor(hpLeft,16/S);FGradeSlider.Anchor(vpTop,-H);
  H:=H+34/S;FGradeHint.FontSize:=13/S;FGradeHint.MaxWidth:=FGradePanel.Width-32/S;
  FGradeHint.Anchor(hpLeft,16/S);FGradeHint.Anchor(vpTop,-H);
  FGradePanel.Height:=H+FGradeHint.EffectiveHeight+12/S;Y:=Y+FGradePanel.Height+12/S;
  FStatus.FontSize:=17/S;FStatus.MaxWidth:=EffectiveWidth-32/S;FStatus.Anchor(hpLeft,16/S);FStatus.Anchor(vpTop,-Y);
  FScroll.Border.Top:=Y+FStatus.EffectiveHeight+16/S;
  FEmpty.Anchor(vpTop,-FScroll.Border.Top);
  FAdapters.Width:=EffectiveWidth-32/S;FAdapters.Anchor(hpLeft,16/S);FAdapters.Anchor(vpTop,-FScroll.Border.Top);FAdapters.Arrange;
  FAdvanced.Border.Top:=FScroll.Border.Top+FAdapters.Height+18/S;
  FAdvanced.Border.Left:=16/S;FAdvanced.Border.Right:=16/S;
  if FSensorPanel<>nil then TSensorPanel(FSensorPanel).Layout;
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
var I,Count:Integer;E:TGameDeviceEntry;Sig,Text:String;K:TSensorKind;Sensor:TDeviceSensor;Angle:Single;
begin
  if DeviceService=nil then Exit;Sig:='';Count:=0;
  RefreshSimulation;
  RefreshGrade;
  if FSensorPanel<>nil then TSensorPanel(FSensorPanel).Refresh;
  for I:=0 to DeviceService.Devices.Count-1 do begin E:=DeviceService.Devices[I];
    if not VisibleDevice(E) then Continue;Inc(Count);
    Sig:=Sig+E.DeviceInfo.Address+IntToStr(Ord(E.ConnectionState))+IntToStr(E.Sensors.Count)+';';end;
  if Sig<>FSignature then begin FSignature:=Sig;Rebuild;end;
  FEmpty.Exists:=(Count=0)and not FAdvanced.Exists and not Settings.GetSimulationEnabled;
  if Settings.GetSimulationEnabled then BindUiText(FStatus,'Simulation is enabled. Sensors are not required.')
  else if Count=0 then BindUiText(FStatus,'Looking for your trainer… Wake it by pedaling.')
  else BindUiText(FStatus,'Choose your trainer once. Heart rate and cadence sensors are optional.');
  for I:=0 to High(FValues)do begin
    if FValues[I]=nil then Continue;
    E:=DeviceService.Devices[I];Text:='';
    if E.ConnectionState=gdcsConnecting then Text:=UiText('Connecting…')
    else if E.ConnectionState=gdcsConnected then begin
      for K:=Low(TSensorKind)to High(TSensorKind)do begin
        Sensor:=E.FindSensor(K);if Sensor=nil then Continue;
        if Text<>''then Text:=Text+'  ·  ';
        if (K=skSteering) and (DeviceService.Sensor(K)=Sensor) and DeviceService.ReadSteering(Angle) then
          Text:=Text+UiText('Steering')+': '+FormatFloat('0.0',Angle)+'°'
        else if Sensor.HasData and((E.DeviceInfo.TransportType=ttSim)or(K=skSteering)or(Sensor.DataAgeSec<3))then Text:=Text+Sensor.FormatInstant
        else Text:=Text+UiText('Waiting for signal');
      end;
      if Text=''then Text:=UiText('Connected');
    end else if(E.DeviceInfo.TransportType=ttSim)and(E.ConnectionState=gdcsError)then
      Text:=UiText('Could not read the simulation FIT. Choose another file.')
    else if E.DeviceInfo.SupportsSteering and(E.ConnectionState=gdcsError)then
      Text:=UiText(E.LastMessage)
    else Text:=UiText('Available');
    FValues[I].Caption:=Text;
  end;
end;
procedure TDevicesPage.Rebuild;
var I:Integer;E:TGameDeviceEntry;Card:TCastleRectangleControl;B:TMenuButton;L:TCastleLabel;S,W,Y:Single;
begin
  FContent.ClearControls;FreeAndNil(FRows);FRows:=TComponent.Create(Self);S:=Max(0.65,Min(1,UIScale));
  W:=Max(200,FScroll.RenderRect.Width/Max(0.01,UIScale)-18/S);Y:=0;SetLength(FValues,DeviceService.Devices.Count);
  for I:=0 to High(FValues)do FValues[I]:=nil;
  for I:=0 to DeviceService.Devices.Count-1 do begin
    E:=DeviceService.Devices[I];if not VisibleDevice(E)then Continue;
    Card:=TMenuPanel.Create(FRows);Card.Width:=W;Card.Height:=124/S;
    Card.Anchor(vpTop,-Y);Card.Color:=MenuSurface;FContent.InsertFront(Card);
    L:=TMenuLabel.Create(Card);L.Caption:=E.DisplayName;L.Color:=White;L.FontSize:=20/S;L.MaxWidth:=W-210/S;
    if E.DeviceInfo.TransportType=ttSim then begin
      L.Caption:=UiText('Simulation')+': '+ExtractFileName(Settings.EffectiveSimulationFitPath);
      L.MaxWidth:=W-28/S;
    end;
    L.Anchor(hpLeft,14/S);L.Anchor(vpTop,-14/S);Card.InsertFront(L);
    FValues[I]:=TMenuLabel.Create(Card);L:=FValues[I];L.Color:=Vector4(0.72,0.85,0.82,1);L.FontSize:=15/S;
    L.MaxWidth:=W-190/S;L.Anchor(hpLeft,14/S);L.Anchor(vpTop,-58/S);Card.InsertFront(L);
    if E.DeviceInfo.TransportType=ttSim then begin
      L.MaxWidth:=W-28/S;Card.Height:=94/S;Y:=Y+108/S;Continue;
    end;
    B:=TMenuButton.Create(Card);B.Name:='ConnectDevice'+IntToStr(I);B.Tag:=I;B.OnClick:=@ClickDevice;
    B.FontSize:=16/S;B.Anchor(hpRight,-14/S);B.Anchor(vpTop,-14/S);
    if E.ConnectionState=gdcsConnected then begin BindUiText(B,'Use this device');end else BindUiText(B,'Connect');
    Card.InsertFront(B);
    if E.ConnectionState=gdcsConnected then begin
      B:=TMenuButton.Create(Card);B.Name:='DisconnectDevice'+IntToStr(I);B.Tag:=I;B.OnClick:=@ClickDisconnect;
      BindUiText(B,'Disconnect');B.FontSize:=14/S;B.Anchor(hpRight,-14/S);B.Anchor(vpBottom,12/S);Card.InsertFront(B);
      if E.DeviceInfo.SupportsSteering then begin
        B:=TMenuButton.Create(Card);B.Name:='CenterSteering'+IntToStr(I);B.Tag:=I;B.OnClick:=@ClickCenterSteering;
        BindUiText(B,'Center steering');B.FontSize:=14/S;B.Anchor(hpLeft,14/S);B.Anchor(vpBottom,12/S);Card.InsertFront(B);
      end;
    end;
    Y:=Y+138/S;
  end;
  FContent.Width:=W;FContent.Height:=Max(100,Y);FScroll.ScrollArea.Height:=FContent.Height;
  if FSensorPanel<>nil then TSensorPanel(FSensorPanel).Rebuild;
end;
procedure TDevicesPage.ClickCenterSteering(Sender:TObject);
var I:Integer;
begin
  I:=TComponent(Sender).Tag;
  if(DeviceService=nil)or(I<0)or(I>=DeviceService.Devices.Count)then Exit;
  DeviceService.SelectDeviceForRoles(DeviceService.Devices[I]);
  DeviceService.CenterSteering;
end;

procedure TDevicesPage.ClickDevice(Sender:TObject);
var I:Integer;E:TGameDeviceEntry;
begin
  I:=TComponent(Sender).Tag;if(I<0)or(I>=DeviceService.Devices.Count)then Exit;E:=DeviceService.Devices[I];
  DeviceService.SelectDeviceForRoles(E);
  FSignature:='#refresh';
end;
procedure TDevicesPage.ClickDisconnect(Sender:TObject);
var I:Integer;
begin I:=TComponent(Sender).Tag;if(I>=0)and(I<DeviceService.Devices.Count)then DeviceService.DisconnectDevice(DeviceService.Devices[I]);end;
procedure TDevicesPage.ClickScan(Sender:TObject);
begin DeviceService.StartScan;end;
procedure TDevicesPage.ClickAdvanced(Sender:TObject);
begin
  FAdvanced.Exists:=not FAdvanced.Exists;FAdapters.Exists:=FAdvanced.Exists;FScroll.Exists:=not FAdvanced.Exists;
  if FAdvanced.Exists and(FSensorPanel=nil)then begin FSensorPanel:=TSensorPanel.Create(Self);TSensorPanel(FSensorPanel).Build(FAdvanced);end;
  Layout;
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
begin
  if not FGradeSavePending then FGradeSlider.Value:=Settings.GetTrainerGradeSensitivity;
  FGradeValue.Caption:=IntToStr(FGradeSlider.Value)+'%';
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
