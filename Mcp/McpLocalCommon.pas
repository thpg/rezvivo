unit McpLocalCommon;
{$mode objfpc}{$H+}
interface
uses SysUtils{$ifdef MSWINDOWS},Windows{$endif};
const MCP_LOCAL_MAX_LINE=16*1024*1024;
function ValidMcpLocalEndpoint(const Endpoint:string):Boolean;
{$ifdef MSWINDOWS}
function McpCancelSynchronousIo(Thread:THandle):BOOL;stdcall;external 'kernel32.dll' name 'CancelSynchronousIo';
{$endif}
implementation
function ValidMcpLocalEndpoint(const Endpoint:string):Boolean;
var I,Split:Integer;Pid:QWord;
begin
  Result:=False;if (Length(Endpoint)<42) or (Length(Endpoint)>51) or
    (Copy(Endpoint,1,8)<>'rezvivo-') then Exit;
  Split:=Length(Endpoint)-32;if Endpoint[Split]<>'-' then Exit;
  for I:=9 to Split-1 do if not(Endpoint[I] in ['0'..'9']) then Exit;
  if not TryStrToQWord(Copy(Endpoint,9,Split-9),Pid) or (Pid=0) or (Pid>High(LongWord)) then Exit;
  for I:=Split+1 to Length(Endpoint) do if not(Endpoint[I] in ['0'..'9','a'..'f']) then Exit;
  Result:=True;
end;
end.
