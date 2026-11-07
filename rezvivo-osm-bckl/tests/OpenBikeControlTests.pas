program OpenBikeControlTests;
{$mode objfpc}{$H+}
uses SysUtils,TrainerData,GameControllerGears,EliteSterzoProtocol,OpenBikeControlProtocol,
  ZwiftControllerProtocol;
var Checks:Integer;
procedure Check(B:Boolean;const S:String);
begin Inc(Checks);if not B then raise Exception.Create(S) end;
function Hex(const S:String):TBytes;
var I:Integer;
begin Result:=nil;SetLength(Result,Length(S)div 2);for I:=0 to High(Result)do Result[I]:=StrToInt('$'+Copy(S,I*2+1,2)) end;
function HexText(const B:TBytes):String;
var X:Byte;
begin Result:='';for X in B do Result:=Result+IntToHex(X,2) end;
procedure TestShifting;
var P:TOpenBikeControlParser;D,M:TTrainerDataRecord;C:TControllerGearCursor;G:Integer;
  procedure Feed(const S:String);
  begin Check(P.Parse(Hex(S),D),'button packet '+S);MergeTrainerData(M,D) end;
begin
  P:=TOpenBikeControlParser.Create;
  try
    M:=Default(TTrainerDataRecord);C:=Default(TControllerGearCursor);
    Feed('010101');Feed('010100');Feed('010101');Feed('010100');
    Check(D.PresentMetrics=[tmController],'shift became steering');
    G:=ConsumeControllerGears(C,M,12,24);Check(G=14,'two fast shift ups were lost to frame coalescing');
    Check(ConsumeControllerGears(C,M,G,24)=14,'release replayed a shift');
    Feed('010201');Feed('010201');Feed('010200');
    Check(ConsumeControllerGears(C,M,G,24)=13,'held or repeated notification shifted twice');
    { Multiple actions per button: Shift Up + Increase Difficulty + Select. }
    Feed('01010130011401');Check(ConsumeControllerGears(C,M,13,24)=14,'combined actions ignored shift');
    Feed('01010030001400');
    Check(not P.Parse(Hex('013001'),D),'unsupported button published');
    Check(not P.Parse(Hex('020101'),D),'device status parsed as buttons');
    Check(not P.Parse(Hex('0101'),D),'truncated packet accepted');
    Check(not P.Parse(Hex('01010130'),D),'odd button pair accepted');
    P.Reset;Feed('010101');
    Check(ConsumeControllerGears(C,M,14,24)=15,'reconnect lost first shift');
  finally P.Free end;
end;
procedure TestSteering;
var P:TOpenBikeControlParser;D:TTrainerDataRecord;Serial:Cardinal;
begin
  P:=TOpenBikeControlParser.Create;
  try
    Check(P.Parse(Hex('011801'),D)and(D.PresentMetrics=[tmSteering]),'steer left metrics');
    Check((D.SteeringTurnDirection=1)and(Abs(SteeringAxis(D.SteeringAngle)-1)<0.001),'steer left convention');
    Serial:=D.SteeringTurnSerial;
    Check(P.Parse(Hex('011801'),D)and(D.SteeringTurnSerial=Serial),'repeated notification turned again');
    Check(P.Parse(Hex('011800'),D)and(D.SteeringAngle=0)and(D.SteeringTurnSerial=Serial),'steer release');
    Check(P.Parse(Hex('011901'),D)and(D.SteeringTurnDirection=-1)and(D.SteeringTurnSerial=Serial+1),'steer right');
    Check(P.Parse(Hex('011900'),D)and(D.SteeringAngle=0),'steer right release');
    { 10 degrees right, angle wins over buttons while available. }
    Check(P.Parse(Hex('011B941801'),D)and(Abs(D.SteeringAngle-10)<0.001),'angle right');
    Check(SteeringAxis(D.SteeringAngle)<0,'angle direction');
    Check(P.Parse(Hex('011B77'),D)and(Abs(D.SteeringAngle+4.5)<0.001),'angle left');
    Check(P.Parse(Hex('011B01'),D)and(Abs(D.SteeringAngle+4.5)<0.001),'no-op angle changed steering');
    Check(P.Parse(Hex('011B00'),D)and(Abs(SteeringAxis(D.SteeringAngle)-1)<0.001),'unavailable angle ignored held button');
    Check(P.Parse(Hex('011800'),D)and(D.SteeringAngle=0),'centre after angle loss');
  finally P.Free end;
end;
procedure TestAppInfo;
var B:TBytes;
begin
  B:=OpenBikeControlAppInfo;
  Check(Copy(HexText(B),1,20)='04010772657A7669766F','app information header');
  Check(HexText(Copy(B,Length(B)-6,6))='05010218191B','app information buttons');
  Check(B[10]=Length(B)-17,'app information version length');
end;
procedure TestMalformed;
var P:TOpenBikeControlParser;D:TTrainerDataRecord;B:TBytes;I,N:Integer;
begin
  P:=TOpenBikeControlParser.Create;
  try
    RandSeed:=4242;
    for I:=1 to 20000 do
    begin
      N:=Random(65);SetLength(B,N);
      for N:=0 to High(B) do B[N]:=Random(256);
      P.Parse(B,D);
    end;
  finally P.Free end;
end;
procedure TestDiscoveryAndSnapshot;
var Info:TDeviceInfo; P:TOpenBikeControlParser; Z:TZwiftControllerParser;
  Data,Initial:TTrainerDataRecord; Cursor:TControllerGearCursor; Gear:Integer;
begin
  Info:=Default(TDeviceInfo);Info.Name:='Arbitrary bridge name';
  DiscoverOpenBikeControl(Info,'0000180d-0000-1000-8000-00805f9b34fb');
  Check(not Info.SupportsShifting,'unrelated service identified as controller');
  DiscoverOpenBikeControl(Info,UpperCase(OpenBikeControlServiceUUID));
  Check(Info.SupportsShifting and Info.SupportsSteering,'controller missing at discovery');
  Check(not Info.SupportsPower and not Info.SupportsControl,'input claimed trainer roles');
  Check(PreferOpenBikeControl(True,False,False),'OBC not selected');
  Check(not PreferOpenBikeControl(True,True,False),'two input protocols selected');
  Check(not PreferOpenBikeControl(True,False,True),'native STERZO displaced');
  Check(not PreferOpenBikeControl(False,False,False),'missing service selected');
  P:=TOpenBikeControlParser.Create;Z:=TZwiftControllerParser.Create;
  try
    Check(P.Parse(Hex('011B94'),Data),'early angle');
    Check(P.Parse(Hex('010101'),Data),'early shift');
    Initial:=P.Snapshot;
    Check(Initial.PresentMetrics=[tmSteering,tmController],'snapshot lost a metric');
    Check(Abs(Initial.SteeringAngle-10)<0.001,'snapshot lost angle');
    Cursor:=Default(TControllerGearCursor);
    Gear:=ConsumeControllerGears(Cursor,Initial,12,24);
    Check(Gear=13,'initial snapshot lost shift');
    Check(ConsumeControllerGears(Cursor,Initial,Gear,24)=13,'snapshot replay duplicated shift');
    Check(Z.Parse(TBytes.Create($37,$08,0,$10,1),Data),'native replacement packet');
    Check(Data.ControllerGeneration<>Initial.ControllerGeneration,'protocol epochs collide');
    Check(ConsumeControllerGears(Cursor,Data,Gear,24)=14,'replacement lost first shift');
    P.Reset;Initial:=P.Snapshot;
    Check(Initial.ValidMetrics=[],'reconnect retained stale state');
    Check(P.Parse(Hex('010101'),Data),'new session first packet');
    Check(ConsumeControllerGears(Cursor,Data,14,24)=15,'new session lost first shift');
    Check(P.Parse(Hex('011BFF'),Data) and (Data.SteeringAngle=0),'reserved angle changed state');
  finally P.Free;Z.Free end;
end;
begin
  TestShifting;TestSteering;TestAppInfo;TestMalformed;TestDiscoveryAndSnapshot;
  Writeln('PASS OpenBikeControlTests: ',Checks,' checks + 20000 malformed packets');
end.
