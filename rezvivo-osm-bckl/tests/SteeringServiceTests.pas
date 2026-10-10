program SteeringServiceTests;
{$mode objfpc}{$H+}
uses SysUtils, TrainerData, AppSettings, GameDeviceService, GameDeviceTypes,
  GameDeviceSensor, ANTPlus;
var Checks:Integer; D,P:TDeviceInfo; Packet:TTrainerDataRecord; Angle:Single;
  S:TDeviceSensor; E:TGameDeviceEntry; I:Integer;
procedure Check(OK:Boolean;const Msg:String);
begin Inc(Checks);if not OK then raise Exception.Create(Msg) end;
procedure FeedAngle(Value:Single);
begin
  Packet:=Default(TTrainerDataRecord);BeginTrainerPacket(Packet);
  Packet.SteeringAngle:=Value;MarkTrainerMetric(Packet,tmSteering);
  { Deliberately old timestamp: stationary STERZO only sends on change. }
  Packet.Timestamp:=Now-1/24;Packet.MetricTime[tmSteering]:=Packet.Timestamp;
  DeviceService.Manager.OnDeviceDataReceived(D,Packet);
end;
begin
  Check(GetEnvironmentVariable('REZVIVO_TEST_AUTH_FILE')<>'','isolated auth required');
  Check(GetEnvironmentVariable('REZVIVO_TEST_SETTINGS_FILE')<>'','isolated settings required');
  Check(GetEnvironmentVariable('REZVIVO_TEST_NO_HARDWARE')='1','no hardware required');
  RegisterANTUsbBackendClass(nil);
  Settings.SetSimulationEnabled(False);
  DeviceService:=TGameDeviceService.Create;
  try
    DeviceService.AutoConnect:=False;
    D:=Default(TDeviceInfo);D.Address:='test-steering';D.Name:='Elite STERZO test';
    D.TransportType:=ttBLE;D.ProviderName:='test';D.SupportsSteering:=True;
    DeviceService.Manager.OnDeviceFound(D);
    DeviceService.Manager.OnDeviceConnectionChanged(D,csConnected,'test');
    FeedAngle(-17);
    Check(DeviceService.ReadSteering(Angle) and (Angle=-17),'old unchanged angle must remain usable');
    Check(not DeviceService.HasControlDevice,'steering became trainer control');
    Check(DeviceService.Power=nil,'steering became power source');
    Check(DeviceService.ActivitySourceFlags=0,'steering started a recorded workout');
    DeviceService.ResetSession;
    Check(DeviceService.ReadSteering(Angle) and (Angle=-17),'ride start reset held steering angle');
    Check(DeviceService.CenterSteering,'calibration failed');
    Check(DeviceService.ReadSteering(Angle) and (Angle=0),'calibration did not center input');
    Settings.SetSimulationEnabled(True);
    Check(DeviceService.ReadSteering(Angle),'simulation removed steering');
    Check(DeviceService.SelectedSensorName(skSteering)=D.Name,'simulation hid steering assignment');
    P:=Default(TDeviceInfo);P.Address:='test-real-power';P.Name:='Test trainer';
    P.TransportType:=ttBLE;P.ProviderName:='test';P.SupportsPower:=True;
    DeviceService.Manager.OnDeviceFound(P);
    DeviceService.Manager.OnDeviceConnectionChanged(P,csConnected,'test');
    Check(DeviceService.Power=nil,'simulation accepted physical power');
    S:=DeviceService.Sensor(skSteering);
    DeviceService.ClearSensor(skSteering);
    DeviceService.AutoAssignSensors;
    Check(not DeviceService.ReadSteering(Angle),'explicit steering None ignored during simulation');
    DeviceService.AssignSensor(skSteering,S);
    Check(DeviceService.ReadSteering(Angle),'manual steering assignment blocked by simulation');
    DeviceService.Manager.OnDeviceConnectionChanged(D,csDisconnected,'test');
    Check(not DeviceService.ReadSteering(Angle) and (Angle=0),'disconnection left a stuck turn');
    DeviceService.Manager.OnDeviceConnectionChanged(D,csConnected,'test');
    Check(not DeviceService.ReadSteering(Angle),'reconnection reused old angle');
    FeedAngle(-17);
    Check(DeviceService.ReadSteering(Angle),'reconnection did not recover input');
    Settings.SetSimulationEnabled(False);
    Check(DeviceService.ReadSteering(Angle),'leaving simulation removed steering');
    DeviceService.ClearSensor(skSteering);
    DeviceService.Manager.OnDeviceConnectionChanged(D,csConnected,'test');FeedAngle(15);
    Check(not DeviceService.ReadSteering(Angle),'disabled steering returned after reconnect');
    E:=nil;
    for I:=0 to DeviceService.Devices.Count-1 do
      if DeviceService.Devices[I].DeviceInfo.Address=D.Address then E:=DeviceService.Devices[I];
    DeviceService.SelectDeviceForRoles(E);
    Check(DeviceService.ReadSteering(Angle),'Use this device did not enable steering');
  finally FreeAndNil(DeviceService) end;
  Writeln('PASS SteeringServiceTests: ',Checks,' checks');
end.
