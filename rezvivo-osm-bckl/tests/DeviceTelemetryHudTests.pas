program DeviceTelemetryHudTests;
{$mode objfpc}{$H+}

{ Inject transport events at the real service boundary, without radio sessions
  or trainer commands. Run with the isolated REZVIVO_TEST_* paths set. }
uses SysUtils, CastleControls, TrainerData, AppSettings, GameDeviceService,
  GameDeviceSensor, GameDeviceTypes, GameBLEHud, GamePhysicalAgent, ANTPlus;

var Checks: Integer;

procedure Check(OK: Boolean; const Message: String);
begin
  Inc(Checks);
  if not OK then raise Exception.Create(Message);
end;

function Device(const Address: String; Transport: TTransportType;
  HeartRate, Trainer: Boolean): TDeviceInfo;
begin
  Result := Default(TDeviceInfo);
  Result.Address := Address;
  Result.Name := 'Telemetry test ' + Address;
  Result.ProviderName := 'test';
  Result.TransportType := Transport;
  Result.SupportsHeartRate := HeartRate;
  Result.SupportsPower := Trainer;
  Result.SupportsCadence := Trainer;
  Result.SupportsControl := Trainer;
end;

procedure Feed(const D: TDeviceInfo; HR, Watts, Cadence: Integer);
var Packet: TTrainerDataRecord;
begin
  Packet := Default(TTrainerDataRecord);
  Packet.Timestamp := Now;
  Packet.HeartRate := HR;
  Packet.InstantPower := Watts;
  Packet.InstantCadence := Cadence;
  DeviceService.Manager.OnDeviceDataReceived(D, Packet);
end;

function Entry(const Address: String): TGameDeviceEntry;
var I: Integer;
begin
  for I := 0 to DeviceService.Devices.Count - 1 do
    if SameText(DeviceService.Devices[I].DeviceInfo.Address, Address) then
      Exit(DeviceService.Devices[I]);
  raise Exception.Create('Test device was not discovered: ' + Address);
end;

procedure Run;
var BleHR, AntHR, BleTrainer, AntTrainer: TDeviceInfo;
  AntEntry: TGameDeviceEntry;
  Hud: TBLEHudUpdater;
  Agent: TPhysicalAgent;
  Labels: THudLabels;

  procedure ExpectHR(Value: Integer; const Context: String);
  begin
    Hud.UpdateInfoLabels(Agent, nil);
    Check(Hud.BLEData.HeartRate = Value, Context + ': recording/telemetry HR');
    if Value > 0 then
      Check(Labels.LabelHeart.Caption = IntToStr(Value), Context + ': HUD HR')
    else Check(Labels.LabelHeart.Caption = '--', Context + ': HUD no signal');
  end;

begin
  Check(GetEnvironmentVariable('REZVIVO_TEST_SETTINGS_FILE') <> '', 'Isolated settings required');
  Check(GetEnvironmentVariable('REZVIVO_TEST_AUTH_FILE') <> '', 'Isolated auth required');
  Check(GetEnvironmentVariable('REZVIVO_TEST_ACCOUNT_DIR') <> '', 'Isolated account required');
  Check(Pos('http://127.0.0.1:',GetEnvironmentVariable('REZVIVO_TEST_API'))=1,
    'Loopback API is required for isolated route/device assignments');
  Settings.SetSimulationEnabled(False);
  RegisterANTUsbBackendClass(nil); { This test must never open/reset a USB stick. }
  DeviceService := TGameDeviceService.Create;
  DeviceService.AutoConnect := False;
  Hud := TBLEHudUpdater.Create;
  Agent := TPhysicalAgent.Create(nil);
  Labels := Default(THudLabels);
  Labels.LabelHeart := TCastleLabel.Create(nil);
  Labels.LabelPower := TCastleLabel.Create(nil);
  Labels.LabelCadence := TCastleLabel.Create(nil);
  try
    Hud.SetLabels(Labels);
    BleHR := Device('BLE:TEST-HR', ttBLE, True, False);
    AntHR := Device('ANT:TEST-HR', ttANTPlus, True, False);
    BleTrainer := Device('BLE:TEST-TRAINER', ttBLE, False, True);
    AntTrainer := Device('ANT:TEST-TRAINER', ttANTPlus, False, True);

    DeviceService.Manager.OnDeviceFound(BleHR);
    DeviceService.Manager.OnDeviceConnectionChanged(BleHR, csConnected, '');
    Feed(BleHR, 121, 0, 0);
    ExpectHR(121, 'Initial BLE HR');
    DeviceService.Manager.OnDeviceFound(BleTrainer);
    DeviceService.Manager.OnDeviceConnectionChanged(BleTrainer, csConnected, '');
    Feed(BleTrainer, 0, 230, 86);

    { Last real ride: a BLE HR sensor was automatically chosen, then the user
      selected an ANT+ HR sensor before its asynchronous connection finished. }
    DeviceService.Manager.OnDeviceFound(AntHR);
    AntEntry := Entry(AntHR.Address);
    DeviceService.AssignSensor(skHeartRate, AntEntry.HRSensor);
    ExpectHR(0, 'Selected ANT+ is still connecting');
    DeviceService.Manager.OnDeviceConnectionChanged(AntHR, csConnected, '');
    Feed(AntHR, 147, 0, 0);
    Check(AntEntry.HRSensor.Instant = 147, 'ANT+ device card receives pulse');
    ExpectHR(147, 'Connected ANT+ HR');
    Check(Labels.LabelPower.Caption = '230', 'BLE power coexists with ANT+ HR');
    Check(Labels.LabelCadence.Caption = '86', 'BLE cadence coexists with ANT+ HR');
    Feed(BleHR, 122, 0, 0);
    ExpectHR(147, 'Unselected BLE cannot overwrite ANT+ HR');

    DeviceService.Manager.OnDeviceConnectionChanged(AntHR, csDisconnected, '');
    ExpectHR(0, 'Disconnected ANT+ HR');
    DeviceService.Manager.OnDeviceConnectionChanged(AntHR, csConnected, '');
    Feed(AntHR, 159, 0, 0);
    ExpectHR(159, 'Reconnected ANT+ HR');

    DeviceService.Manager.OnDeviceFound(AntTrainer);
    DeviceService.SetControlDevice(Entry(AntTrainer.Address));
    DeviceService.Manager.OnDeviceConnectionChanged(AntTrainer, csConnected, '');
    DeviceService.Manager.OnDeviceConnectionChanged(AntTrainer, csDisconnected, '');
    DeviceService.Manager.OnDeviceConnectionChanged(AntTrainer, csConnected, '');
    Check(DeviceService.HasControlDevice, 'Selected ANT+ control reconnects');
    Check(DeviceService.Power.DeviceAddress = BleTrainer.Address, 'Independent BLE power stays selected');

    Settings.SetSimulationEnabled(True);
    Feed(AntHR, 170, 0, 0);
    DeviceService.AutoAssignSensors;
    ExpectHR(0, 'Simulation excludes real sensors');
    Settings.SetSimulationEnabled(False);
    ExpectHR(170, 'Leaving simulation restores selected ANT+ HR');

    DeviceService.ClearSensor(skHeartRate);
    DeviceService.Manager.OnDeviceConnectionChanged(AntHR, csConnected, '');
    Feed(AntHR, 165, 0, 0);
    ExpectHR(0, 'Explicit None survives reconnect');
  finally
    Hud.Free;
    Labels.LabelCadence.Free;
    Labels.LabelPower.Free;
    Labels.LabelHeart.Free;
    Agent.Free;
    FreeAndNil(DeviceService);
  end;
end;

begin
  Run;
  WriteLn('PASS DeviceTelemetryHudTests: ', Checks, ' checks');
end.
