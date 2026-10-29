program VirtualGearingTrainerTests;
{$mode objfpc}{$H+}{$codepage UTF8}
uses SysUtils,Math,CastleControls,TrainerData,FTMSProtocol,GameTransportBase,
  GameTrainerControl,AppSettings,GameDeviceService,GameVirtualGearing,
  GameBLEHud,GamePhysicalAgent,ANTPlus;
type
  TTestTrainer=class(TFTMSCapableSession)
  public
    LastWatts,NativeResets:Integer;
    Ratio,Grade:Single;
    constructor Create(const Address:String;const FriendlyName:String='');override;
    function Connect:Boolean;override;
    procedure Disconnect;override;
    function WriteFTMSCommand(const Data:TBytes):Boolean;override;
    function SetGearedSimulation(A,B,C,D,R:Single):Boolean;override;
    procedure Native(Enabled:Boolean);
    procedure Telemetry(Cadence:Integer);
  end;
  TTestProvider=class(TTransportProvider)
    procedure StartScan;override;
    procedure StopScan;override;
    function CreateSession(const Address:String;const FriendlyName:String=''):TTransportSession;override;
    class function TransportType:TTransportType;override;
  end;
var Checks:Integer;
procedure Check(V:Boolean;const S:String);
begin Inc(Checks);if not V then raise Exception.Create(S) end;
constructor TTestTrainer.Create(const Address:String;const FriendlyName:String);
begin
  inherited;
  FHasFTMS:=True;FDeviceInfo.TransportType:=ttBLE;
  FDeviceInfo.SupportsPower:=True;FDeviceInfo.SupportsCadence:=True;FDeviceInfo.SupportsControl:=True;
  FTrainerFeatures.Known:=True;FTrainerFeatures.SupportsPowerControl:=True;
  FTrainerFeatures.SupportsSimulation:=True;Native(True);
end;
function TTestTrainer.Connect:Boolean;
begin SetConnectionState(csConnected);Result:=True end;
procedure TTestTrainer.Disconnect;
begin SetConnectionState(csDisconnected) end;
function TTestTrainer.WriteFTMSCommand(const Data:TBytes):Boolean;
begin
  if(Data[0]=$05)and(Length(Data)>=3)then LastWatts:=Data[1]+Data[2]*256;
  ReceiveControlPoint(TBytes.Create($80,Data[0],$01));Result:=True;
end;
function TTestTrainer.SetGearedSimulation(A,B,C,D,R:Single):Boolean;
begin Ratio:=R;Grade:=A;if R=0 then Inc(NativeResets);Result:=True end;
procedure TTestTrainer.Native(Enabled:Boolean);
begin FTrainerFeatures.SupportsVirtualGearing:=Enabled end;
procedure TTestTrainer.Telemetry(Cadence:Integer);
var Data:TTrainerDataRecord;
begin
  Data:=Default(TTrainerDataRecord);BeginTrainerPacket(Data);
  Data.InstantPower:=197;Data.InstantCadence:=Cadence;
  MarkTrainerMetric(Data,tmPower);MarkTrainerMetric(Data,tmCadence);
  PublishMeasurement(Data);
end;
procedure TTestProvider.StartScan;
var D:TDeviceInfo;
begin
  D:=Default(TDeviceInfo);D.Address:='test:gearing-trainer';D.Name:='Test trainer';
  D.TransportType:=ttBLE;D.SupportsPower:=True;D.SupportsCadence:=True;D.SupportsControl:=True;
  OnDeviceFound(D);
end;
procedure TTestProvider.StopScan;begin end;
function TTestProvider.CreateSession(const Address:String;const FriendlyName:String):TTransportSession;
begin Result:=TTestTrainer.Create(Address,FriendlyName) end;
class function TTestProvider.TransportType:TTransportType;begin Result:=ttBLE end;
procedure WaitCommand(Kind:TTrainerCommandKind;Expected:Single=-9999);
var T:QWord;S:TTrainerControlStatus;
begin
  T:=GetTickCount64;
  repeat
    DeviceService.Manager.Tick;S:=DeviceService.ControlStatus;
    if(S.Kind=Kind)and(S.State in[tcsAccepted,tcsSent])and
      ((Expected=-9999)or(Abs(S.Value-Expected)<0.001))then Exit;
    Sleep(5);
  until GetTickCount64-T>3000;
  raise Exception.CreateFmt('Command did not finish: kind %d state %d',[Ord(S.Kind),Ord(S.State)]);
end;
var P:TTestProvider;S:TTestTrainer;T:QWord;Hud:TBLEHudUpdater;
  Agent:TPhysicalAgent;Labels:THudLabels;Gear:Integer;Load:TGearingLoad;
begin
  Check(GetEnvironmentVariable('REZVIVO_TEST_NO_HARDWARE')='1','isolated hardware required');
  Check(GetEnvironmentVariable('REZVIVO_TEST_ACCOUNT_DIR')<>'','isolated account required');
  Check(GetEnvironmentVariable('REZVIVO_TEST_AUTH_FILE')<>'','isolated auth required');
  Check(GetEnvironmentVariable('REZVIVO_TEST_SETTINGS_FILE')<>'','isolated settings required');
  Check(Pos('http://127.0.0.1:',GetEnvironmentVariable('REZVIVO_TEST_API'))=1,'isolated API required');
  RegisterANTUsbBackendClass(nil);Settings.SetSimulationEnabled(False);Settings.SetVirtualGearingEnabled(True);
  DeviceService:=TGameDeviceService.Create;DeviceService.AutoConnect:=False;
  Hud:=TBLEHudUpdater.Create;Agent:=TPhysicalAgent.Create(nil);
  Labels:=Default(THudLabels);Labels.LabelTransmission:=TCastleLabel.Create(nil);Hud.SetLabels(Labels);
  try
    P:=TTestProvider.Create;DeviceService.RegisterProvider(P);P.StartScan;DeviceService.Manager.Tick;
    DeviceService.Manager.Connect('test:gearing-trainer','Test trainer');
    T:=GetTickCount64;
    repeat DeviceService.Manager.Tick;Sleep(5) until DeviceService.HasControlDevice or(GetTickCount64-T>3000);
    Check(DeviceService.HasControlDevice,'test trainer not selected');
    S:=TTestTrainer(DeviceService.Manager.GetSession('test:gearing-trainer'));
    Check(DeviceService.GearingBackend=gbNative,'native capability not selected');
    S.Telemetry(90);DeviceService.Manager.Tick;
    DeviceService.SetRideSimulation(4,0,75,10);WaitCommand(tcGearedSimulation);
    Check(Abs(S.Ratio-2.4)<0.001,'default gear ratio');Check(Abs(S.Grade-4)<0.001,'native grade');
    Hud.UpdateInfoLabels(Agent,nil);Check(Labels.LabelTransmission.Caption='12','HUD gear');
    Check(Hud.BLEData.InstantPower=197,'native target replaced real watts');
    DeviceService.SetTargetPower(220);WaitCommand(tcPower);
    Check(S.NativeResets=1,'native mode not released before ERG');
    Hud.UpdateInfoLabels(Agent,nil);Check(Labels.LabelTransmission.Caption='ERG','HUD ERG');
    Gear:=DeviceService.VirtualGear;DeviceService.ShiftVirtualGear(1);
    Check(DeviceService.VirtualGear=Gear,'shift changed gear in ERG');
    Check(Hud.BLEData.InstantPower=197,'ERG target replaced real watts');
    DeviceService.SetRideSimulation(4,0,75,10);WaitCommand(tcGearedSimulation);
    Hud.UpdateInfoLabels(Agent,nil);Check(Labels.LabelTransmission.Caption='12','ERG did not release HUD');
    Settings.SetVirtualGearingEnabled(False);DeviceService.SetRideSimulation(4,0,75,10);WaitCommand(tcSimulation);
    Check(S.NativeResets=2,'disabling setting did not release native mode');
    Hud.UpdateInfoLabels(Agent,nil);Check(Labels.LabelTransmission.Caption='—','disabled gear still shown');
    S.Native(False);Settings.SetVirtualGearingEnabled(True);
    Check(DeviceService.GearingBackend=gbFTMSPower,'standard fallback not selected');
    S.Telemetry(90);DeviceService.Manager.Tick;
    DeviceService.SetRideSimulation(3,0,75,10);WaitCommand(tcPower);
    Load:=CalculateGearingLoad(12,90,3,0,75,10,Settings.GetWheelCircumferenceMm/1000);
    Check(S.LastWatts=Round(Load.Watts),'fallback target not delivered');
    Hud.UpdateInfoLabels(Agent,nil);Check(Labels.LabelTransmission.Caption='12','fallback mislabelled ERG');
    Check(Hud.BLEData.InstantPower=197,'fallback target replaced real watts');
    S.Telemetry(0);DeviceService.Manager.Tick;DeviceService.SetRideSimulation(3,0,75,10);WaitCommand(tcPower,0);
    Check(S.LastWatts=0,'cadence stop did not unload trainer');
    DeviceService.SetTargetPower(220);WaitCommand(tcPower);
    S.Disconnect;DeviceService.Manager.Tick;
    Hud.UpdateInfoLabels(Agent,nil);Check(Labels.LabelTransmission.Caption='—','disconnect left false ERG');
    Check(not DeviceService.TrainerErgActive,'disconnect left mode latched');
  finally Labels.LabelTransmission.Free;Hud.Free;Agent.Free;FreeAndNil(DeviceService) end;
  Writeln('PASS VirtualGearingTrainerTests: ',Checks,' checks');
end.
