unit McpRelayBootstrap;
{$mode objfpc}{$H+}
{ Keep first in the program uses list, before any game/engine initialization. }
interface
implementation
uses SysUtils,McpLocalRelay;
procedure CheckRelayMode;
var I:Integer;
begin
  for I:=1 to ParamCount do if ParamStr(I)='--mcp-connect' then begin
    if I=ParamCount then Halt(RunMcpLocalRelay(''));
    Halt(RunMcpLocalRelay(ParamStr(I+1)));
  end;
end;
initialization
  CheckRelayMode;
end.
