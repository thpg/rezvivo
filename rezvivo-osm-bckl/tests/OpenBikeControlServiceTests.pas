program OpenBikeControlServiceTests;
{$mode objfpc}{$H+}
uses SysUtils,TrainerData,FTMSProtocol,GameTransportBase,GameDeviceService,
  GameDeviceTypes,GameDeviceSensor,AppSettings,OpenBikeControlProtocol,ANTPlus;
type
  TBridgeSession=class(TFTMSCapableSession)
  private Parser:TOpenBikeControlParser;
  public
    constructor Create(const Address:String;const FriendlyName:String='');override;
    destructor Destroy;override;
    function Connect:Boolean;override;
    procedure Disconnect;override;
    function WriteFTMSCommand(const Data:TBytes):Boolean;override;
    procedure Feed(const Bytes:TBytes);
  end;
  TBridgeProvider=class(TTransportProvider)
  public
    procedure StartScan;override;
    procedure StopScan;override;
    function CreateSession(const Address:String;const FriendlyName:String=''):TTransportSession;override;
    class function TransportType:TTransportType;override;
  end;
var Created,Checks:Integer;Simulation:Boolean;
procedure Check(Condition:Boolean;const Message:String);
begin Inc(Checks);if not Condition then raise Exception.Create(Message) end;
constructor TBridgeSession.Create(const Address:String;const FriendlyName:String);
begin inherited;Parser:=TOpenBikeControlParser.Create end;
destructor TBridgeSession.Destroy;
begin Parser.Free;inherited end;
function TBridgeSession.Connect:Boolean;
var Data:TTrainerDataRecord;
begin
  FDeviceInfo.TransportType:=ttBLE;FDeviceInfo.ProviderName:='test-obc';
  SetConnectionState(csConnecting,'test');Parser.Reset;
  DiscoverOpenBikeControl(FDeviceInfo,OpenBikeControlServiceUUID);
  { A hybrid bridge must not replace simulated power / trainer control. }
  FDeviceInfo.SupportsPower:=True;FDeviceInfo.SupportsControl:=True;
  Parser.Parse(TBytes.Create($01,$1B,$94),Data);
  Parser.Parse(TBytes.Create($01,$01,$01),Data);
  Sleep(60); { notifications before the UI receives Connected }
  SetConnectionState(csConnected,'test');
  PublishMeasurement(Parser.Snapshot);
  Result:=True;
end;
procedure TBridgeSession.Disconnect;
begin SetConnectionState(csDisconnected,'test') end;
function TBridgeSession.WriteFTMSCommand(const Data:TBytes):Boolean;
begin Result:=False end;
procedure TBridgeSession.Feed(const Bytes:TBytes);
var Data:TTrainerDataRecord;
begin if Parser.Parse(Bytes,Data) then PublishMeasurement(Data) end;
procedure TBridgeProvider.StartScan;
var D:TDeviceInfo;
begin
  D:=Default(TDeviceInfo);D.Address:='test:obc';D.Name:='Arbitrary BLE bridge';
  D.TransportType:=ttBLE;D.ProviderName:='test-obc';
  DiscoverOpenBikeControl(D,OpenBikeControlServiceUUID);
  OnDeviceFound(D);
end;
procedure TBridgeProvider.StopScan;begin end;
function TBridgeProvider.CreateSession(const Address:String;const FriendlyName:String):TTransportSession;
begin Inc(Created);Result:=TBridgeSession.Create(Address,FriendlyName) end;
class function TBridgeProvider.TransportType:TTransportType;begin Result:=ttBLE end;
procedure Pump;
var Start:QWord;
begin
  Start:=GetTickCount64;
  repeat DeviceService.Manager.Tick;Sleep(5) until GetTickCount64-Start>250;
end;
var Provider:TBridgeProvider;Entry:TGameDeviceEntry;Session:TBridgeSession;
  Gear:Integer;Degrees:Single;D:TDeviceInfo;Parser:TOpenBikeControlParser;Data:TTrainerDataRecord;
begin
  Check(GetEnvironmentVariable('REZVIVO_TEST_NO_HARDWARE')='1','isolate hardware');
  Check(GetEnvironmentVariable('REZVIVO_TEST_ACCOUNT_DIR')<>'','isolate account');
  Check(GetEnvironmentVariable('REZVIVO_TEST_AUTH_FILE')<>'','isolate auth');
  Check(GetEnvironmentVariable('REZVIVO_TEST_SETTINGS_FILE')<>'','isolate settings');
  Check(Pos('http://127.0.0.1:',GetEnvironmentVariable('REZVIVO_TEST_API'))=1,'isolate API');
  RegisterANTUsbBackendClass(nil);Simulation:=ParamStr(1)='simulation';
  Settings.SetSimulationEnabled(Simulation);Settings.SetVirtualGearingEnabled(True);
  DeviceService:=TGameDeviceService.Create;
  try
    Provider:=TBridgeProvider.Create;DeviceService.RegisterProvider(Provider);
    Provider.StartScan;Pump;
    Check(Created=0,'unselected nearby bridge connected automatically');
    Entry:=DeviceService.Devices[0];Gear:=DeviceService.VirtualGear;
    { Unknown BLE peripherals may be probed before the service UUID arrives. }
    DeviceService.AutoConnect:=False;
    D:=Default(TDeviceInfo);D.Address:='test:late-obc';D.Name:='Late controller';
    D.TransportType:=ttBLE;D.ProviderName:='test-obc';
    DeviceService.Manager.OnDeviceFound(D);
    DiscoverOpenBikeControl(D,OpenBikeControlServiceUUID);
    DeviceService.Manager.OnDeviceConnectionChanged(D,csConnected,'test probe');
    Parser:=TOpenBikeControlParser.Create;
    try
      Parser.Parse(TBytes.Create($01,$01,$01,$1B,$94),Data);
      DeviceService.Manager.OnDeviceDataReceived(D,Data);
    finally Parser.Free end;
    DeviceService.ReadControllerGears;
    Check(DeviceService.VirtualGear=Gear,'discovery probe shifted gear');
    Check(not DeviceService.ReadSteering(Degrees),'discovery probe steered');
    Check(not DeviceService.IsGearController(DeviceService.Devices[1]),'unselected probe assigned');
    DeviceService.AutoConnect:=True;
    DeviceService.SelectDeviceForRoles(Entry);Pump;
    Check(Created=1,'explicit controller connection failed');
    Check(Entry.ConnectionState=gdcsConnected,'connection did not finish');
    Check(DeviceService.IsGearController(Entry),'shifting not assigned');
    Check(DeviceService.ReadSteering(Degrees) and (Abs(Degrees-10)<0.001),'first angle lost');
    DeviceService.ReadControllerGears;
    Check(DeviceService.VirtualGear=Gear+1,'first shift lost');
    Gear:=DeviceService.VirtualGear;
    DeviceService.ReadControllerGears;
    Check(DeviceService.VirtualGear=Gear,'first shift replayed');
    Check(not DeviceService.CenterSteering,'calibrated OBC angle recentered');
    if Simulation then begin
      Check(DeviceService.Power=nil,'OBC replaced FIT power');
      Check(not DeviceService.HasControlDevice,'OBC replaced FIT control');
    end;
    Session:=TBridgeSession(DeviceService.Manager.GetSession(Entry.DeviceInfo.Address));
    Check(Session<>nil,'missing bridge session');
    Session.Feed(TBytes.Create($01,$01,$00));Session.Feed(TBytes.Create($01,$01,$01));
    Session.Feed(TBytes.Create($01,$01,$00));Session.Feed(TBytes.Create($01,$01,$01));
    Pump;DeviceService.ReadControllerGears;
    Check(DeviceService.VirtualGear=Gear+2,'coalesced presses lost');
    Gear:=DeviceService.VirtualGear;
    Settings.SetVirtualGearingEnabled(False);
    Session.Feed(TBytes.Create($01,$01,$00));Session.Feed(TBytes.Create($01,$01,$01));
    Pump;DeviceService.ReadControllerGears;
    Check(DeviceService.VirtualGear=Gear,'disabled virtual shifting changed gear');
    Settings.SetVirtualGearingEnabled(True);DeviceService.ReadControllerGears;
    Check(DeviceService.VirtualGear=Gear,'enabling replayed old press');
    Provider.StartScan;Pump;
    Check(Entry.DeviceInfo.SupportsShifting,'rescan lost capability');
    DeviceService.SelectGearController(Entry);
    Check(not DeviceService.IsGearController(Entry),'cannot unassign OBC');
    Session.Feed(TBytes.Create($01,$02,$01));Pump;DeviceService.ReadControllerGears;
    Check(DeviceService.VirtualGear=Gear,'unassigned controller shifted');
    D:=Entry.DeviceInfo;Session.Disconnect;Pump;
    Check(not DeviceService.ReadSteering(Degrees),'disconnect retained steering');
    FreeAndNil(DeviceService);
    DeviceService:=TGameDeviceService.Create;
    Provider:=TBridgeProvider.Create;DeviceService.RegisterProvider(Provider);
    Provider.StartScan;Pump;
    Check(Created=2,'remembered controller did not reconnect');
    Entry:=DeviceService.Devices[0];
    Check(not DeviceService.IsGearController(Entry),'saved opt-out lost');
    Check(DeviceService.ReadSteering(Degrees),'remembered steering missing');
  finally FreeAndNil(DeviceService) end;
  Writeln('PASS OpenBikeControlServiceTests ',ParamStr(1),': ',Checks,' checks');
end.
