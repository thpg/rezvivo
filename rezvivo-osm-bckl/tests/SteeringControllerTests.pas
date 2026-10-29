program SteeringControllerTests;
{$mode objfpc}{$H+}
uses SysUtils, Math, TrainerData, GameSteeringInput, ZwiftControllerProtocol,
  EliteSterzoProtocol, GameTransportBase, WinRTBLEProvider, SimpleBLEProvider;
var Checks:Integer;
procedure Check(B:Boolean;const S:String);
begin Inc(Checks);if not B then raise Exception.Create(S) end;
function Hex(const S:String):TBytes;
var I:Integer;
begin
  Result:=nil;SetLength(Result,Length(S) div 2);
  for I:=0 to High(Result) do Result[I]:=StrToInt('$'+Copy(S,I*2+1,2));
end;
procedure TestEdges;
var E:TSteeringEdge; S:TSteeringInput; Axis:Single; Turn,I:Integer;
begin
  E.Reset;
  Check(E.Update(0.2)=0,'small analog movement selected a turn');
  Check(E.Update(0.4)=1,'analog left edge');
  for I:=1 to 1000 do Check(E.Update(0.4)=0,'held input repeated');
  Check(E.Update(0.25)=0,'threshold noise released latch');
  Check(E.Update(0.4)=0,'threshold noise repeated turn');
  Check(E.Update(-0.4)=-1,'direct opposite turn');
  E.Update(0);Check(E.Update(-0.4)=-1,'release should re-arm');
  Check(GamepadSteeringAxis(0.12,False,False)=0,'stick drift');
  Check(GamepadSteeringAxis(-1,False,False)=1,'stick left convention');
  Check(GamepadSteeringAxis(1,False,False)=-1,'stick right convention');
  Check(GamepadSteeringAxis(0,True,True)=0,'opposing D-pad buttons');
  Check(GamepadSteeringAxis(1,True,False)=1,'D-pad overrides stick');
  S:=TSteeringInput.Create;
  try
    Check(S.Read(True,0,1,1,False,0,Axis,Turn) and (Axis=0) and (Turn=1),'brief BLE tap lost');
    S.Read(True,0,1,1,False,0,Axis,Turn);Check(Turn=0,'serial consumed twice');
    S.Read(True,0,2,-1,False,0,Axis,Turn);Check(Turn=-1,'second edge missed');
    S.Reset(1,1,2);
    S.Read(True,1,2,-1,True,1,Axis,Turn);Check((Turn=0)and(Axis=1),'resume repeated held input');
    S.ForgetBLE;
    S.Read(False,0,0,0,True,1,Axis,Turn);Check(Turn=0,'BLE disconnect repeated gamepad turn');
    S.Read(False,0,0,0,False,0,Axis,Turn);Check((Axis=0)and(Turn=0),'disconnect stuck turn');
    Check(not S.Read(False,0,0,0,False,0,Axis,Turn),'absent device reported');
    S.Read(False,0,0,0,True,-1,Axis,Turn);Check((Axis=-1)and(Turn=-1),'gamepad after reconnect');
  finally S.Free end;
end;
procedure TestPackets;
var P:TZwiftControllerParser; D,M:TTrainerDataRecord; B:TBytes; I,N:Integer;
  Serial:Cardinal;
begin
  Check(IsZwiftControllerName('Zwift Play'),'Play scan identity');
  Check(IsZwiftControllerName('Zwift SF2'),'Ride scan identity');
  Check(not IsZwiftControllerName('Zwift Hub'),'trainer mistaken for controller');
  Check(ZwiftHandshakeReply(ZwiftHandshakeRequest)=zhPlaintext,'plaintext handshake');
  B:=ZwiftHandshakeRequest;SetLength(B,72);
  Check(ZwiftHandshakeReply(B)=zhEncrypted,'encrypted handshake misclassified');
  P:=TZwiftControllerParser.Create;
  try
    { Captured-format Play packet: left pad, left arrow pressed. }
    B:=Hex('07080110011800200128013001380140004800');
    Check(P.Parse(B,D),'Play left button');
    Check((D.PresentMetrics=[tmSteering,tmController])and(D.SteeringTurnDirection=1),'Play metrics/direction');
    Check(Abs(SteeringAxis(D.SteeringAngle)-1)<0.001,'Play continuous left');
    Serial:=D.SteeringTurnSerial;
    Check(P.Parse(B,D)and(D.SteeringTurnSerial=Serial),'repeated radio notification');
    M:=D;
    Check(P.Parse(Hex('07080110011801200128013001380140004800'),D),'Play release');
    MergeTrainerData(M,D);
    Check((M.SteeringAngle=0)and(M.SteeringTurnSerial=Serial)and
      (M.SteeringTurnDirection=1),'coalescing erased short button tap');
    Check(P.Parse(Hex('070800100118012001280130013801406b4800'),D),'Play analog zigzag');
    Check(Abs(SteeringAxis(D.SteeringAngle)-0.54)<0.001,'Play analog direction/value');
    { Right-pad A/Z are not left/right navigation buttons. }
    Check(P.Parse(Hex('07080010011800200028013001380140004800'),D)and
      (D.SteeringAngle=0),'face buttons triggered steering');
    Check(P.Parse(Hex('2308feffffff0f12180a04080010000a04080110000a04080210000a0408031000'),D),'original Ride format');
    Check(D.SteeringTurnDirection=1,'Ride left bitmap');
    Check(P.Parse(Hex('2308ffffffff0f1a04080010001a0408011000'),D)and
      (D.SteeringAngle=0),'new Ride/Play2 release');
    Check(P.Parse(Hex('2308fbffffff0f'),D)and(D.SteeringTurnDirection=-1),'Ride right bitmap');
    Check(P.Parse(Hex('3708011000'),D)and(D.SteeringTurnDirection=1),'Click minus left');
    Check(P.Parse(Hex('3708001001'),D)and(D.SteeringTurnDirection=-1),'Click plus right');
    Check(not P.Parse(Hex('2308ffffffff1f'),D),'overflow uint32 accepted');
    Check(not P.Parse(Hex('230a12'),D),'length packet interpreted as turn');
    Check(not P.Parse(Hex('2312ffffffff0f'),D),'oversized submessage accepted');
    Check(not P.Parse(Hex('07080140ffff03'),D),'out-of-range analog accepted');
    Check(not P.Parse(Hex('150800'),D),'keepalive overwrote button state');
    Check(not P.Parse(Hex('2308'),D),'truncated varint');
    Check(not P.Parse(Hex('370800'),D),'truncated Click status');
    { Deterministic malformed corpus: parser must never read out of bounds. }
    RandSeed:=754321;
    for I:=1 to 20000 do
    begin
      N:=Random(65);SetLength(B,N);
      for N:=0 to High(B) do B[N]:=Random(256);
      P.Parse(B,D);
    end;
  finally P.Free end;
end;
type TObserver=class
  Count:Integer; Packet:TTrainerDataRecord;
  procedure Receive(S:TTransportSession;const D:TTrainerDataRecord);
end;
procedure TObserver.Receive(S:TTransportSession;const D:TTrainerDataRecord);
begin Inc(Count);MergeTrainerData(Packet,D) end;
procedure TestWinRTDispatch;
var S:TWinRTBLESession;O:TObserver;B:TBytes;
begin
  S:=TWinRTBLESession.Create('00:00:00:00:00:01','Zwift Play');O:=TObserver.Create;
  try
    S.OnDataReceived:=@O.Receive;
    S.ReceiveCharacteristicData(ZwiftResponseUUID,ZwiftHandshakeRequest);
    Check(O.Count=0,'handshake became telemetry');
    S.ReceiveCharacteristicData(ZwiftNotifyUUID,Hex('3708011000'));
    S.ReceiveCharacteristicData(ZwiftNotifyUUID,Hex('3708011001'));
    Check((O.Count=2)and(O.Packet.SteeringAngle=0)and
      (O.Packet.SteeringTurnSerial=1),'native dispatch lost tap');
    Check(S.DeviceInfo.SupportsSteering,'native steering capability not learned');
    Check(not S.DeviceInfo.SupportsPower and not S.DeviceInfo.SupportsControl,'controller became trainer');
    B:=ZwiftHandshakeRequest;SetLength(B,72);
    S.ReceiveCharacteristicData(ZwiftResponseUUID,B);
    S.ReceiveCharacteristicData(ZwiftNotifyUUID,Hex('3708001001'));
    Check(O.Count=2,'encrypted connection accepted fake plaintext');
  finally S.Free;O.Free end;
end;
begin
  TestEdges;TestPackets;TestWinRTDispatch;
  Writeln('PASS SteeringControllerTests: ',Checks,' checks + 20000 malformed packets');
end.
