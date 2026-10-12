program SteeringPairServiceTests;
{$mode objfpc}{$H+}
uses SysUtils, TrainerData, AppSettings, GameDeviceService, GameDeviceTypes,
  GameDeviceSensor, ZwiftControllerProtocol, ANTPlus;
var Checks:Integer; Left,Right,Other:TDeviceInfo; L,R,N:TZwiftControllerParser;
  Axis:Single;Turn:Integer;
procedure Check(B:Boolean;const S:String);
begin Inc(Checks);if not B then raise Exception.Create(S) end;
function Entry(const D:TDeviceInfo):TGameDeviceEntry;
var I:Integer;
begin
  Result:=nil;
  for I:=0 to DeviceService.Devices.Count-1 do
    if DeviceService.Devices[I].DeviceInfo.Address=D.Address then Exit(DeviceService.Devices[I]);
end;
procedure Connect(const D:TDeviceInfo);
begin
  DeviceService.Manager.OnDeviceFound(D);
  DeviceService.Manager.OnDeviceConnectionChanged(D,csConnected,'test');
end;
procedure Feed(P:TZwiftControllerParser;const D:TDeviceInfo;Direction:Integer;Tap:Boolean=False);
var Packet,Combined:TTrainerDataRecord;Bytes:TBytes;V:Integer;
begin
  { Original $07 Play format, field 8 is the signed analog steering paddle.
    Each physical controller has its own independent parser and serial. }
  if Direction>0 then V:=199 else if Direction<0 then V:=200 else V:=0;
  Bytes:=TBytes.Create($07,$08,Ord(D.Address=Left.Address),$18,1,$20,1,$40);
  if V>=128 then Bytes:=Concat(Bytes,TBytes.Create(Byte(V or $80),Byte(V shr 7)))
  else Bytes:=Concat(Bytes,TBytes.Create(Byte(V)));
  Check(P.Parse(Bytes,Packet),'parse Play paddle');
  if Tap then begin
    Combined:=Packet;
    Check(P.Parse(TBytes.Create($07,$08,0,$18,1,$20,1,$40,0),Packet),'parse Play release');
    MergeTrainerData(Combined,Packet);Packet:=Combined;
  end;
  DeviceService.Manager.OnDeviceDataReceived(D,Packet);
end;
procedure Read(ExpectedAxis:Single;ExpectedTurn:Integer;const Msg:String);
begin
  Check(DeviceService.ReadSteeringInput(Axis,Turn),Msg+' available');
  Check((Abs(Axis-ExpectedAxis)<0.001)and(Turn=ExpectedTurn),
    Msg+Format(' (axis %.3f turn %d)',[Axis,Turn]));
end;
begin
  Check(GetEnvironmentVariable('REZVIVO_TEST_AUTH_FILE')<>'','isolated auth required');
  Check(GetEnvironmentVariable('REZVIVO_TEST_SETTINGS_FILE')<>'','isolated settings required');
  Check(GetEnvironmentVariable('REZVIVO_TEST_NO_HARDWARE')='1','no hardware required');
  RegisterANTUsbBackendClass(nil);Settings.SetSimulationEnabled(False);
  Left:=Default(TDeviceInfo);Left.Address:='play-left';Left.Name:='Zwift Play left';
  Left.TransportType:=ttBLE;Left.ProviderName:='test';Left.SupportsSteering:=True;
  Right:=Left;Right.Address:='play-right';Right.Name:='Zwift Play right';
  Other:=Left;Other.Address:='neighbour';Other.Name:='Zwift Play other rider';
  L:=TZwiftControllerParser.Create;R:=TZwiftControllerParser.Create;N:=TZwiftControllerParser.Create;
  DeviceService:=TGameDeviceService.Create;
  try
    DeviceService.AutoConnect:=False;
    Connect(Left);Connect(Right);Connect(Other);
    Check(not DeviceService.CanPairSteering(Entry(Left)),'cannot pair device with itself');
    Check(DeviceService.CanPairSteering(Entry(Right)),'second controller is pairable');
    Feed(R,Right,0);Check(not DeviceService.ReadSteeringInput(Axis,Turn),'unselected companion influenced steering');
    Feed(R,Right,0);DeviceService.SelectSteeringCompanion(Entry(Right));
    Check(DeviceService.IsSteeringCompanion(Entry(Right)),'explicit companion not selected');
    Check(DeviceService.IsSensorSelected(skSteering,Entry(Left)),'pair replaced primary');
    L.Reset;R.Reset;
    Feed(L,Left,1,True);Read(0,1,'left coalesced turn');
    Feed(R,Right,-1,True);Read(0,-1,'right serial one independent of left serial one');
    Read(0,0,'pair commands consumed once');
    Feed(N,Other,1);Read(0,0,'neighbour ignored');
    Feed(L,Left,1);Read(1,1,'left continuous');
    Feed(R,Right,-1);Read(0,-1,'opposing paddles cancel continuous steering');
    Read(0,0,'held pair produces no repeated edge');
    DeviceService.ResetSteeringInput;Read(0,0,'resume suppresses both held paddles');
    Feed(L,Left,0);Read(-1,0,'releasing left leaves right held');
    DeviceService.Manager.OnDeviceConnectionChanged(Left,csDisconnected,'test');
    Read(-1,0,'companion survives primary disconnection');
    DeviceService.Manager.OnDeviceConnectionChanged(Right,csDisconnected,'test');
    Check(not DeviceService.ReadSteeringInput(Axis,Turn)and(Axis=0)and(Turn=0),'pair disconnect clears input');
    R.Reset;Connect(Right);Feed(R,Right,-1);Read(-1,-1,'companion reconnect restarts its serial');
    Settings.SetSimulationEnabled(True);DeviceService.ResetSteeringInput;
    Read(-1,0,'companion usable during FIT playback');
    Settings.SetSimulationEnabled(False);
    FreeAndNil(DeviceService);
    DeviceService:=TGameDeviceService.Create;DeviceService.AutoConnect:=False;
    Connect(Other);Connect(Right);
    Check(DeviceService.IsSteeringCompanion(Entry(Right)),'saved companion restored');
    R.Reset;Feed(R,Right,-1);Read(-1,-1,'saved companion works before primary reconnects');
    L.Reset;Connect(Left);Feed(L,Left,0);
    DeviceService.SelectDeviceForRoles(Entry(Left));
    Check(DeviceService.IsSteeringCompanion(Entry(Right)),'reselecting primary discarded pair');
    DeviceService.SelectSteeringCompanion(nil);Read(0,0,'removed companion ignored');
    Feed(R,Right,0);DeviceService.SelectSteeringCompanion(Entry(Right));
    DeviceService.ClearSensor(skSteering);
    Check(not DeviceService.IsSteeringCompanion(Entry(Right)),'steering None retained companion');
    Feed(L,Left,1);Feed(R,Right,-1);
    Check(not DeviceService.ReadSteeringInput(Axis,Turn),'steering None failed to disable pair');
    DeviceService.SelectDeviceForRoles(Entry(Left));
    DeviceService.SelectSteeringCompanion(Entry(Right));
    DeviceService.SelectDeviceForRoles(Entry(Other));
    Check(not DeviceService.IsSteeringCompanion(Entry(Right)),'replacement primary retained old pair');
  finally N.Free;R.Free;L.Free;FreeAndNil(DeviceService) end;
  Writeln('PASS SteeringPairServiceTests: ',Checks,' checks');
end.
