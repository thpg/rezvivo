program ZwiftCryptoProbe;
{$mode objfpc}{$H+}
uses SysUtils,TrainerData,ZwiftControllerProtocol;
function Hex(const S:String):TBytes;
var I:Integer;
begin Result:=nil;SetLength(Result,Length(S)div 2);for I:=0 to High(Result)do Result[I]:=StrToInt('$'+Copy(S,2*I+1,2)) end;
function HexText(const B:TBytes):String;
var X:Byte;
begin Result:='';for X in B do Result:=Result+IntToHex(X,2) end;
var P:TZwiftControllerParser;D:TTrainerDataRecord;S:String;I:Integer;
begin
  P:=TZwiftControllerParser.Create;
  try
    Writeln(HexText(P.StartEncryptedHandshake));Flush(Output);
    Readln(S);if not P.AcceptHandshake(Hex(S))then Halt(2);
    Writeln('READY');Flush(Output);
    for I:=1 to 5 do begin
      Readln(S);
      if P.Parse(Hex(S),D)then Writeln('OK ',D.ControllerSerial)else Writeln('REJECT');
      Flush(Output);
    end;
  finally P.Free end;
end.
