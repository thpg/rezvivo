program SteeringTests;
{$mode objfpc}{$H+}
uses SysUtils, Math, fpjson, TrainerData, EliteSterzoProtocol, GameTransportBase,
  WinRTBLEProvider, GameDeviceSensor, GameDeviceTypes, GameDeviceAssignments,
  CastleVectors, GamePhysicsCommon;
var Checks: Integer;
procedure Check(OK: Boolean; const Msg: String);
begin Inc(Checks); if not OK then raise Exception.Create(Msg) end;
function AngleBytes(Angle: Single): TBytes;
begin SetLength(Result,4); Move(Angle,Result[0],4) end;
type TObserver=class
  Count: Integer;
  Packet: TTrainerDataRecord;
  procedure Receive(Session: TTransportSession; const Data: TTrainerDataRecord);
end;
procedure TObserver.Receive(Session: TTransportSession; const Data: TTrainerDataRecord);
begin Inc(Count); Packet:=Data end;

procedure TestPackets;
var D,Combined: TTrainerDataRecord; B:TBytes; V:Single; I:Integer;
  Session:TWinRTBLESession; Observer:TObserver; Entry:TGameDeviceEntry;
begin
  for I:=-340 to 340 do begin
    V:=I/10;Check(ParseSterzoAngle(AngleBytes(V),D),'valid angle rejected');
    Check(Abs(D.SteeringAngle-V)<0.0001,'angle/endian/sign');
    Check(D.PresentMetrics=[tmSteering],'steering contains fitness metrics');
  end;
  Check(not ParseSterzoAngle(TBytes.Create(0,0,0),D),'truncated packet');
  Check(not ParseSterzoAngle(TBytes.Create(0,0,0,0,0),D),'oversized packet');
  Check(not ParseSterzoAngle(TBytes.Create(0,0,$C0,$7F),D),'NaN');
  Check(not ParseSterzoAngle(TBytes.Create(0,0,$80,$FF),D),'infinity');
  Check(not ParseSterzoAngle(AngleBytes(100),D),'out-of-range packet');
  B:=SterzoChallengeResponse(TBytes.Create(3,$10,0,0));
  Check((Length(B)=4) and (B[0]=3) and (B[1]=$11) and (B[2]=$96) and (B[3]=$96),'challenge 0000');
  B:=SterzoChallengeResponse(TBytes.Create(3,$10,0,1));
  Check((B[2]=$96) and (B[3]=$9F),'challenge byte order');
  Check(Length(SterzoChallengeResponse(TBytes.Create(3,$11,$FF,$FF)))=0,'ACK misread as challenge');
  Check(Length(SterzoChallengeResponse(TBytes.Create(3,$10,0)))=0,'truncated challenge');

  Session:=TWinRTBLESession.Create('00:00:00:00:00:01','STERZO test');
  Observer:=TObserver.Create;
  try
    Session.OnDataReceived:=@Observer.Receive;
    Session.ReceiveCharacteristicData('2a63',TBytes.Create(0,0,250,0));
    Combined:=Observer.Packet;
    Entry:=TGameDeviceEntry.Create(Session.DeviceInfo);
    try
      Entry.FeedData(Observer.Packet);
      Session.ReceiveCharacteristicData(SterzoAngleUUID,AngleBytes(-12.3));
      Check(Observer.Count=2,'one event per valid angle');
      Check(Entry.DiscoverMetrics(Observer.Packet),'steering capability discovery');
      Entry.FeedData(Observer.Packet);
      MergeTrainerData(Combined,Observer.Packet);
      Check(Combined.InstantPower=250,'steering overwrites power');
      Check(Entry.PowerSensor.SessionCount=1,'steering duplicates power samples');
      Check(Entry.FindSensor(skSteering).SensorKind=skSteering,'sensor kind');
      Check(Abs(Entry.FindSensor(skSteering).Instant+12.3)<0.001,'sensor angle');
      Session.ReceiveCharacteristicData(SterzoAngleUUID,TBytes.Create(0,0,$C0,$7F));
      Check(Observer.Count=2,'malformed angle published');
      Session.ReceiveCharacteristicData(SterzoChallengeUUID,TBytes.Create(3,$10,0,0));
      Check(Observer.Count=2,'challenge treated as telemetry');
    finally Entry.Free end;
  finally Session.Free;Observer.Free end;
end;

procedure TestInput;
var A,B:Single; I:Integer; Roles,Restored:TDeviceRoleAssignments; J:TJSONObject;
begin
  Check(SteeringAxis(0.5)=0,'center dead zone');
  Check(SteeringAxis(34)=-1,'clockwise must turn right');
  Check(SteeringAxis(-34)=1,'counterclockwise must turn left');
  Check(SteeringAxis(45)=-1,'clamp sensor maximum');
  A:=0;B:=0;
  for I:=1 to 30 do A:=SmoothSteering(A,1,1/30);
  for I:=1 to 144 do B:=SmoothSteering(B,1,1/144);
  Check(Abs(A-B)<0.00001,'smoothing depends on frame rate');
  Roles:=TDeviceRoleAssignments.Create;Restored:=TDeviceRoleAssignments.Create;
  try
    Roles.Select(drPower,'BLE','trainer','Trainer');
    Roles.Select(drControllable,'BLE','trainer','Trainer');
    Roles.Select(drSteering,'BLE','sterzo','STERZO');
    Check(Roles.CenterSteering(3.75),'zero calibration');
    Roles.Select(drSteering,'BLE','sterzo','STERZO');
    Check(Roles.SteeringCenter=3.75,'reconnect cleared zero calibration');
    J:=Roles.ToJSON;
    try Restored.LoadJSON(J) finally J.Free end;
    Check(Restored.Matches(drSteering,'BLE','sterzo'),'steering not saved');
    Check(Restored.SteeringCenter=3.75,'zero calibration not saved');
    Check(Restored.Matches(drPower,'BLE','trainer'),'steering replaced trainer');
    Check(Restored.Matches(drControllable,'BLE','trainer'),'enum changed stored control role');
    Roles.Select(drSteering,'BLE','other-sterzo','Other');
    Check(Roles.SteeringCenter=0,'new steering device inherited old calibration');
  finally Roles.Free;Restored.Free end;
end;

procedure TestLanes;
var M:TLaneManager; A,B,I,StartLane:Integer; O:Single;
begin
  M:=TLaneManager.Create;
  try
    M.SetRoad(8,1000); A:=M.RegisterRider(Pointer(1));
    M.SetRiderPose(A,Vector3(0,0,0),Vector3(0,0,1),8,0,8);
    StartLane:=M.GetLane(A);
    M.SetSteering(A,True,1); M.Update(1/60);
    Check(M.GetLane(A)<StartLane,'left did not request left lane');
    Check(M.GetSmoothOffset(A,8)<M.GetLaneOffset(StartLane),'left moved right');
    M.SetSteering(A,True,0);
    for I:=1 to 120 do M.Update(1/60);
    Check(M.GetLane(A)=StartLane-1,'neutral returned to automatic lane');
    M.SetSteering(A,False,0);M.Update(1/60);
    Check(M.GetLane(A)=M.DefaultLane,'disconnect did not restore automatic lane');
    for I:=1 to 120 do M.Update(1/60);
    B:=M.RegisterRider(Pointer(2));
    O:=M.GetLaneOffset(M.DefaultLane-1);
    M.SetRiderPose(B,Vector3(-O,0,0),Vector3(0,0,1),8,O,8);
    M.SetSteering(A,True,1);M.Update(1/60);
    Check(M.GetLane(A)=M.DefaultLane,'steering entered occupied adjacent lane');
    M.UnregisterRider(B);
    M.SetRiderPose(A,Vector3(0,0,0),Vector3(0,0,1),8,0,0);
    M.Update(1/60);Check(M.GetLane(A)=M.DefaultLane,'stationary rider slides sideways');
  finally M.Free end;
end;
begin
  TestPackets;TestInput;TestLanes;
  Writeln('PASS SteeringTests: ',Checks,' checks');
end.
