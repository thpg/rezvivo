program VirtualGearingTests;
{$mode objfpc}{$H+}
uses SysUtils,Math,TrainerData,GameVirtualGearing,GameControllerGears,ZwiftControllerProtocol;
var Checks:Integer;
procedure Check(B:Boolean;const S:String);
begin Inc(Checks);if not B then raise Exception.Create(S) end;
function Hex(const S:String):TBytes;
var I:Integer;
begin Result:=nil;SetLength(Result,Length(S)div 2);for I:=0 to High(Result)do Result[I]:=StrToInt('$'+Copy(S,I*2+1,2)) end;
function HexText(const B:TBytes):String;
var X:Byte;
begin Result:='';for X in B do Result:=Result+IntToHex(X,2) end;
procedure TestJournal;
var P:TZwiftControllerParser;D,M:TTrainerDataRecord;C:TControllerGearCursor;G,I:Integer;
  procedure Feed(const S:String);
  begin Check(P.Parse(Hex(S),D),'controller packet '+S);MergeTrainerData(M,D) end;
begin
  P:=TZwiftControllerParser.Create;
  try
    M:=Default(TTrainerDataRecord);C:=Default(TControllerGearCursor);
    Feed('3708011001');PrimeControllerGears(C,M);
    Feed('3708001001');Feed('3708011001');Feed('3708001001');Feed('3708011001');
    G:=ConsumeControllerGears(C,M,12,24);Check(G=14,'two fast clicks were lost to frame coalescing');
    Check(ConsumeControllerGears(C,M,G,24)=14,'release replayed a click');
    { Boundary ordering matters: harder at 24 then easier must become 23. }
    Feed('3708001001');Feed('3708011001');Feed('3708011000');Feed('3708011001');
    Check(ConsumeControllerGears(C,M,24,24)=23,'lost event order at highest gear');
    Feed('3708001001');for I:=1 to 50 do Feed('3708001001');Feed('3708011001');
    Check(ConsumeControllerGears(C,M,12,24)=13,'held button repeated');
    Feed('3708001000');Feed('3708011001');
    Check(ConsumeControllerGears(C,M,12,24)=12,'opposing buttons shifted');
    P.Reset;M:=Default(TTrainerDataRecord);
    Feed('07080110011801200128013001380140004800');PrimeControllerGears(C,M);
    Feed('07080110011801200128013001380040004800');
    Check(ConsumeControllerGears(C,M,12,24)=11,'legacy Play left shift');
    P.Reset;M:=Default(TTrainerDataRecord);
    Feed('07080010011801200128013001380140004800');PrimeControllerGears(C,M);
    Feed('07080010011801200128013001380040004800');
    Check(ConsumeControllerGears(C,M,12,24)=13,'legacy Play right shift');
    P.Reset;M:=Default(TTrainerDataRecord);
    Feed('2308ffffffff0f');PrimeControllerGears(C,M);
    Feed('2308fffbffff0f');Feed('2308ffffffff0f'); // left paddle
    Check(ConsumeControllerGears(C,M,12,24)=11,'Ride left paddle');
    Feed('2308ffbfffff0f');Feed('2308ffffffff0f'); // Click V2/Play2 right +
    Check(ConsumeControllerGears(C,M,12,24)=13,'Click V2/Play2 right button');
    Check(not(tmPower in M.PresentMetrics),'button became power telemetry');
    Check(not P.Parse(Hex('2308ffffffff1f'),D),'overflow button mask');
    Check(HexText(ZwiftHandshakeRequest('Zwift Click V2'))='526964654F6E0203','Click V2 handshake');
    Check(HexText(ZwiftHandshakeRequest('Zwift Play'))='526964654F6E0104','Play handshake');
    Check(IsZwiftControllerName('Zwift BC2 123'),'BC2 recognition');
    Check(not IsZwiftControllerName('Zwift Hub'),'trainer recognition');
    Check(ZwiftControllerLocked(Hex('ff0500ea05')),'Click V2 lock packet');
    Check(ZwiftControllerLocked(Hex('ff0500fa05')),'Ride lock packet');
    Check(not ZwiftControllerLocked(Hex('ff0500ea')),'truncated lock packet');
    Check(not ZwiftControllerLocked(Hex('3708011001')),'button mistaken for lock packet');
  finally P.Free end;
end;
procedure TestLoad;
var A,B:TGearingLoad;G,C:Integer;Last:Single;
begin
  for C:=30 to 150 do begin
    Last:=0;
    for G:=1 to 24 do begin
      A:=CalculateGearingLoad(G,C,4,0,75,10,2.105);
      Check(A.Watts>=Last,'nonmonotonic gears');Last:=A.Watts;
      Check(Abs(A.Watts-A.CrankTorqueNm*C*2*Pi/60)<0.01,'torque/power units');
    end;
  end;
  A:=CalculateGearingLoad(12,90,0,0,75,10,2.105);
  Check(Abs(A.VirtualSpeedMps-7.578)<0.001,'rpm must be divided by 60');
  Check((A.Watts>150)and(A.Watts<180),'flat-road load order of magnitude');
  B:=CalculateGearingLoad(12,90,5,0,75,10,2.105);Check(B.Watts>A.Watts,'uphill load');
  B:=CalculateGearingLoad(12,90,-20,0,75,10,2.105);Check(B.Watts=0,'downhill trainer cannot drive cranks');
  B:=CalculateGearingLoad(24,0,20,0,75,10,2.105);Check(B.Watts=0,'stopped rider load');
  B:=CalculateGearingLoad(24,NaN,20,0,75,10,2.105);Check(B.Watts=0,'NaN cadence');
  Check(HexText(ZwiftTrainerHandshake)='526964654F6E0100','native handshake');
  { Known protobuf fields with signed grade; compare exact byte layout. }
  Check(HexText(ZwiftSimulationCommand(-0.7,0,75,10,2.4))=
    '04220B0800108B0118EC272090032A0A10C0BB0120E80728CC3A','native ratio/grade/coefficient units');
end;
begin TestJournal;TestLoad;Writeln('PASS VirtualGearingTests: ',Checks,' checks') end.
