program DeviceProtocolTests;
{$mode objfpc}{$H+}
uses Classes,SysUtils,Math,TrainerData,FTMSProtocol,CyclingRevolutions,
  CyclingANTProtocol,FECAcknowledgement,GameTrainerControl,GameTransportBase,
  GameDeviceSensor,GameDeviceTypes,GameDeviceAssignments,WinRTBLEProvider,ANTPlus;
var Checks: Integer;
procedure Check(B: Boolean; const S: String);
begin Inc(Checks); if not B then raise Exception.Create(S) end;
procedure Near(A,B: Double; const S: String);
begin Check(Abs(A-B)<0.02,S+Format(' (%f expected %f)',[A,B])) end;
type TObserver=class
  Count: Integer;
  Packet: TTrainerDataRecord;
  procedure Receive(S: TTransportSession; const D: TTrainerDataRecord);
end;
procedure TObserver.Receive(S: TTransportSession; const D: TTrainerDataRecord);
begin Inc(Count); Packet:=D end;

procedure TestBLE;
var S:TWinRTBLESession; O:TObserver; T:TDateTime; E:TGameDeviceEntry;
  PowerPointer:TDeviceSensor; D,Combined:TTrainerDataRecord; B:TBytes;
begin
  S:=TWinRTBLESession.Create('00:00:00:00:00:01','offline'); O:=TObserver.Create;
  try
    S.OnDataReceived:=@O.Receive;
    S.ReceiveCharacteristicData('2a63',TBytes.Create(0,0,250,0));
    Check(O.Count=1,'CPS once'); Check(O.Packet.InstantPower=250,'CPS power');
    E:=TGameDeviceEntry.Create(S.DeviceInfo);
    try
      E.FeedData(O.Packet); PowerPointer:=E.PowerSensor;
      Check(PowerPointer<>nil,'power capability'); T:=PowerPointer.LastUpdate;
      Combined:=O.Packet;
      S.ReceiveCharacteristicData('2a37',TBytes.Create(0,150));
      Check(E.DiscoverMetrics(O.Packet),'bridged HR discovered');
      E.FeedData(O.Packet); MergeTrainerData(Combined,O.Packet);
      Check(E.PowerSensor=PowerPointer,'adding HR preserves sensor pointer');
      Check(PowerPointer.LastUpdate=T,'HR does not refresh power');
      Check(PowerPointer.SessionCount=1,'HR does not duplicate power sample');
      Check(E.HRSensor.Instant=150,'HR available');
      Check((tmPower in Combined.PresentMetrics) and (tmHeartRate in Combined.PresentMetrics),'coalesced packet');
      S.ReceiveCharacteristicData('2a63',TBytes.Create(0,0,240,0));
      Check(O.Packet.HeartRate=150,'CPS preserves cached pulse');
      Check(not (tmHeartRate in O.Packet.PresentMetrics),'CPS not a new HR sample');
      S.ReceiveCharacteristicData('2a37',TBytes.Create(4,150));
      E.FeedData(O.Packet); Check(not E.HRSensor.HasData,'belt no skin contact');
    finally E.Free end;
    S.ApplyCharacteristicRead('2a19',TBytes.Create(77));
    Check(S.BatteryLevel=77,'read-only battery');
    S.ApplyCharacteristicRead('2ad8',TBytes.Create(50,0,244,1,5,0));
    S.ApplyCharacteristicRead('2acc',TBytes.Create(2,68,0,0,12,32,0,0));
    Check(S.TrainerFeatures.PowerRangeKnown,'range survives feature read order');
    Check(S.TrainerFeatures.MinPower=50,'power min');
    Check(S.TrainerFeatures.MaxPower=500,'power max');
    Check(S.TrainerFeatures.SupportsSimulation,'simulation flag');
    Check(S.TrainerFeatures.SupportsPowerControl,'ERG flag');
    Check(not S.TrainerFeatures.SupportsInclineControl,'optional incline absent');
    S.ReceiveCharacteristicData('2ad2',TBytes.Create($41,2,220,0,149));
    Check((O.Packet.HeartRate=149) and (O.Packet.InstantPower=220),'FTMS bridge');
    S.ReceiveCharacteristicData('6e40fec2',TBytes.Create(25,1,$FF,0,0,$FF,$0F,0));
    Check(not (tmPower in O.Packet.ValidMetrics),'BLE FE-C invalid power');
    Check(not (tmCadence in O.Packet.ValidMetrics),'BLE FE-C invalid cadence');
    Check(O.Count=6,'one callback per measurement');
    B:=TBytes.Create(16,25,0,0,$FF,$FF,$FF,0);
    S.ReceiveCharacteristicData('6e40fec2',B);
    Check(not (tmSpeed in O.Packet.ValidMetrics),'BLE FE-C invalid speed');
    Check(O.Packet.InstantSpeed=0,'invalid speed zero');
    D:=O.Packet; S.ReceiveCharacteristicData('2ad2',TBytes.Create(0));
    Check(O.Count=7,'truncated notification ignored');
  finally S.Free; O.Free end;
end;

procedure TestRevolutions;
var P:TFTMSParser; D:TTrainerDataRecord; R:TRevolutionTracker;
begin
  P:=TFTMSParser.Create;
  try
    P.WheelCircumferenceM:=2;
    P.ParseCSCMeasurement(TBytes.Create(1,100,0,0,0,0,0));
    D:=P.ParseCSCMeasurement(TBytes.Create(1,102,0,0,0,0,4));
    Near(D.InstantSpeed,14.4,'CSC wheel speed');
    P.ParseCyclingPowerMeasurement(TBytes.Create($10,0,200,0,1,0,0,0,0,0));
    D:=P.ParseCyclingPowerMeasurement(TBytes.Create($10,0,200,0,3,0,0,0,0,8));
    Near(D.InstantSpeed,14.4,'CPS wheel clock 2048Hz');
    D:=P.ParseCSCMeasurement(TBytes.Create(1,104,0,0,0,0,8));
    Near(D.InstantSpeed,14.4,'CSC/CPS independent counters');
    P.Reset;
    P.ParseCSCMeasurement(TBytes.Create(1,$FF,$FF,$FF,$FF,0,$FC));
    D:=P.ParseCSCMeasurement(TBytes.Create(1,1,0,0,0,0,0));
    Near(D.InstantSpeed,14.4,'32-bit revolution and 16-bit timer rollover');
    D:=P.ParseIndoorBikeData(TBytes.Create(1,$20));
    Check(P.LastPacketValid,'empty more-data packet');
  finally P.Free end;
  R:=Default(TRevolutionTracker);
  RevolutionRate(R,10,1000,1024,True,6,100);
  Near(RevolutionRate(R,12,2024,1024,True,6,1100),2,'cadence rate');
  Near(RevolutionRate(R,12,2024,1024,True,6,4101),0,'stopped crank expires');
  Near(RevolutionRate(R,0,0,1024,True,6,5101),0,'sensor counter reset no spike');
end;

procedure TestANT;
var P:TCyclingANTParser; D:TTrainerDataRecord; B,F,Page:TBytes;
  I:Integer; C:Byte; Id:TANTDeviceId; A:TDeviceRoleAssignments;
begin
  Check((ANTProfilePeriod(121)=8086) and (ANTProfilePeriod(122)=8102) and
    (ANTProfilePeriod(123)=8118),'Nordic BSC profile-specific radio periods');
  P:=TCyclingANTParser.Create;
  try
    Check(P.Parse(17,TBytes.Create(16,25,0,0,$FF,$FF,$FF,0),D),'FE-C page16');
    Check((D.InstantSpeed=0) and not (tmSpeed in D.ValidMetrics),'native invalid speed');
    Check(P.Parse(17,TBytes.Create(25,1,80,0,0,250,0,0),D),'FE-C page25');
    Check((D.InstantPower=250) and (D.InstantCadence=80),'FE-C power/cadence');
    P.Parse(17,TBytes.Create(54,$FF,$FF,$FF,$FF,0,0,3),D);
    Check(P.Features.Known and P.Features.SupportsPowerControl and
      P.Features.SupportsResistanceControl and not P.Features.SupportsSimulation,'FE-C capabilities');
    P.Reset; P.WheelCircumferenceM:=2;
    P.Parse(121,TBytes.Create(0,0,10,0,0,0,100,0),D);
    P.Parse(121,TBytes.Create(0,4,12,0,0,4,102,0),D);
    Check(D.InstantCadence=120,'ANT combined cadence'); Near(D.InstantSpeed,14.4,'ANT combined speed');
    P.Reset; P.Parse(122,TBytes.Create(0,0,0,0,0,0,10,0),D);
    P.Parse(122,TBytes.Create(0,0,0,0,0,4,12,0),D);
    Check(D.InstantCadence=120,'ANT cadence');
    P.Reset; P.Parse(123,TBytes.Create(0,0,0,0,0,0,10,0),D);
    P.Parse(123,TBytes.Create(0,0,0,0,0,4,12,0),D); Near(D.InstantSpeed,14.4,'ANT speed');
    P.Parse(120,TBytes.Create(0,0,0,0,0,0,0,155),D); Check(D.HeartRate=155,'ANT HR');
    P.Parse(11,TBytes.Create($10,1,$FF,90,0,0,44,1),D);
    Check((D.InstantPower=300) and (D.InstantCadence=90),'ANT power-only page');
    P.Reset; P.Parse(11,TBytes.Create($12,1,1,60,0,0,0,0),D);
    P.Parse(11,TBytes.Create($12,2,2,60,0,8,0,4),D);
    Near(D.InstantPower,Round(64*Pi),'ANT crank torque page');
  finally P.Free end;
  Page:=TBytes.Create(25,1,90,0,0,200,0,0);
  Check(DecodeFECFrame(Page,B,C),'raw FEC frame');
  F:=TBytes.Create($A4,9,$4E,0,25,1,90,0,0,200,0,0,0);
  for I:=0 to 11 do F[12]:=F[12] xor F[I];
  Check(DecodeFECFrame(F,B,C) and (B[2]=90),'framed FEC checksum');
  F[12]:=F[12] xor 1; Check(not DecodeFECFrame(F,B,C),'reject bad frame');
  B:=FECUserConfiguration(80,10,2.105);
  Check((B[1]=64) and (B[2]=31),'user weight hundredth kg');
  Check((((B[5] shl 4) or (B[4] shr 4))=200) and (B[7]=0),'bike weight and unknown gear ratio');
  B:=FECWindParameters(5,0.51); Check((B[5]=51) and (B[6]=145) and (B[7]=100),'wind units');
  Check(ParseANTDeviceAddress('ANT:42:120:1',Id),'profile identity parsing');
  Check(ANTDeviceAddress(Id)='ANT:42:120:1','profile identity roundtrip');
  Check(ParseANTDeviceAddress('ANT:42',Id) and (Id.DeviceType=17),'old trainer address');
  A:=TDeviceRoleAssignments.Create;
  try
    A.Reset; A.Select(drHeartRate,'ant','ANT:42','belt');
    Check(A.Matches(drHeartRate,'ant','ANT:42:120:1'),'old HR selection migration');
    Check(not A.Matches(drHeartRate,'ant','ANT:42:17:1'),'same number different profile');
  finally A.Free end;
end;

procedure TestStatus;
var A:TFECAcknowledgement; P:TBytes;
begin
  A:=TFECAcknowledgement.Create;
  try
    P:=TBytes.Create(49,$FF,$FF,$FF,$FF,$FF,$E8,3);
    Check(A.BeginCommand(P),'start status wait');
    A.Receive(TBytes.Create(71,49,1,0,$FF,$FF,$E8,3));
    Check(A.Wait(0)=tcsAccepted,'trainer accepted exact target');
    Check(A.BeginCommand(P),'next command');
    A.Receive(TBytes.Create(71,49,1,0,$FF,$FF,$E8,3));
    Check(A.Wait(0)=tcsSent,'old sequence cannot confirm');
    Check(not A.BeginCommand(P),'no status response backoff');
    A.NewConnection; Check(A.BeginCommand(P),'reconnect clears backoff');
    A.Receive(TBytes.Create(71,49,2,2,0,0,0,0));
    Check(A.Wait(0)=tcsUnsupported,'trainer rejects unsupported mode');
    A.BeginCommand(P); A.Cancel;
    Check(A.Wait(0)=tcsUnavailable,'disconnect cancels wait');
  finally A.Free end;
end;
begin
  TestBLE; TestRevolutions; TestANT; TestStatus;
  Writeln('PASS DeviceProtocolTests ',Checks,' checks');
end.
