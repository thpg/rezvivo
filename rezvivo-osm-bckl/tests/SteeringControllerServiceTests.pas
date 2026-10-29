program SteeringControllerServiceTests;
{$mode objfpc}{$H+}
uses SysUtils, TrainerData, AppSettings, GameDeviceService, GameDeviceTypes,
  GameDeviceSensor, ZwiftControllerProtocol, ANTPlus;
var Checks:Integer;D:TDeviceInfo;P:TZwiftControllerParser;Packet,Combined:TTrainerDataRecord;
  Axis:Single;Turn:Integer;
procedure Check(B:Boolean;const S:String);
begin Inc(Checks);if not B then raise Exception.Create(S) end;
procedure Feed(Plus,Minus:Byte;Coalesce:Boolean=False);
begin
  Check(P.Parse(TBytes.Create($37,$08,Plus,$10,Minus),Packet),'parse click');
  if Coalesce then MergeTrainerData(Combined,Packet)
  else DeviceService.Manager.OnDeviceDataReceived(D,Packet);
end;
begin
  Check(GetEnvironmentVariable('REZVIVO_TEST_AUTH_FILE')<>'','isolated auth required');
  Check(GetEnvironmentVariable('REZVIVO_TEST_SETTINGS_FILE')<>'','isolated settings required');
  Check(GetEnvironmentVariable('REZVIVO_TEST_NO_HARDWARE')='1','no hardware required');
  RegisterANTUsbBackendClass(nil);Settings.SetSimulationEnabled(False);
  Settings.SetVirtualGearingEnabled(False); { explicit legacy +/- steering mode }
  DeviceService:=TGameDeviceService.Create;P:=TZwiftControllerParser.Create;
  try
    DeviceService.AutoConnect:=False;
    D:=Default(TDeviceInfo);D.Address:='test-click';D.Name:='Zwift Click test';
    D.TransportType:=ttBLE;D.ProviderName:='test';D.SupportsSteering:=True;
    DeviceService.Manager.OnDeviceFound(D);
    DeviceService.Manager.OnDeviceConnectionChanged(D,csConnected,'test');
    Feed(1,0,True);Feed(1,1,True);
    DeviceService.Manager.OnDeviceDataReceived(D,Combined);
    Check(DeviceService.ReadSteeringInput(Axis,Turn)and(Axis=0)and(Turn=1),'coalesced tap reached service');
    DeviceService.ReadSteeringInput(Axis,Turn);Check(Turn=0,'coalesced tap repeated');
    Feed(0,1);DeviceService.ReadSteeringInput(Axis,Turn);
    Check((Axis=-1)and(Turn=-1),'right button continuous + edge');
    DeviceService.ReadSteeringInput(Axis,Turn);Check((Axis=-1)and(Turn=0),'held right repeated');
    DeviceService.ResetSteeringInput;
    DeviceService.ReadSteeringInput(Axis,Turn);Check(Turn=0,'resume repeated old turn');
    Check(not DeviceService.CenterSteering,'button controller should not be calibrated');
    Settings.SetSimulationEnabled(True);
    Feed(1,1);Feed(1,0);DeviceService.ReadSteeringInput(Axis,Turn);
    Check((Axis=1)and(Turn=1),'controller during FIT playback');
    DeviceService.Manager.OnDeviceConnectionChanged(D,csDisconnected,'test');
    Check(not DeviceService.ReadSteeringInput(Axis,Turn)and(Axis=0)and(Turn=0),'disconnect stuck controller');
    P.Reset;
    DeviceService.Manager.OnDeviceConnectionChanged(D,csConnected,'test');
    Feed(1,0);DeviceService.ReadSteeringInput(Axis,Turn);Check(Turn=1,'reconnected controller serial restarted');
    DeviceService.ClearSensor(skSteering);
    Feed(1,1);Feed(0,1);
    Check(not DeviceService.ReadSteeringInput(Axis,Turn),'disabled controller still steering');
  finally P.Free;FreeAndNil(DeviceService) end;
  Writeln('PASS SteeringControllerServiceTests: ',Checks,' checks');
end.
