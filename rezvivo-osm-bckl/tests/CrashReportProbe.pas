program CrashReportProbe;
{$mode objfpc}{$H+}{$codepage UTF8}

{ Native process fixture for CrashReportTests.py. It opens no window or GL
  context. All diagnostic paths must point at the disposable test directory. }
uses Classes, SysUtils, CastleLog, DebugLog, GameMachineInfo, GameCrashReports;

var Mode, First, Line: string; I: Integer; Started: QWord; SR: TSearchRec;
begin
  if (GetEnvironmentVariable('REZVIVO_TEST_AUTH_FILE') = '') or
     (GetEnvironmentVariable('REZVIVO_TEST_SESSION_DIR') = '') then
    raise Exception.Create('Isolated diagnostic paths are required');
  Mode := ParamStr(1);
  LogFileName := ParamStr(2);
  EnsureCgeLog;
  Started := GetTickCount64;
  First := MachineInformation;
  for I := 1 to 10000 do
    if MachineInformation <> First then raise Exception.Create('Hardware cache changed');
  WriteLn('Cached inventory calls (10000), ms: ', GetTickCount64 - Started);
  WriteLn(First);
  StartCrashReports;
  if Mode <> 'early' then begin
    SetMachineGraphicsInformation('Renderer: regression current GPU' + #10 +
      'OpenGL version: regression 4.6' + #10 +
      'Authorization: Bearer synthetic-private-value');
    RefreshCrashDiagnostics;
  end;
  if Mode = 'capture' then begin
    Line := StringOfChar('x', 1000);
    for I := 1 to 1400 do Logger.Info(Line);
    Logger.Info('Authorization: Bearer synthetic-private-value');
    Logger.Info('final safe line');
    try
      raise Exception.Create('regression captured exception');
    except on E: Exception do CaptureCrash(E); end;
  end;
  if Mode = 'upload' then begin
    EnableCrashUpload(ParamStr(3));
    Started := GetTickCount64;
    repeat
      if FindFirst(ClientDiagnosticsDir + '*.report.json', faAnyFile, SR) <> 0 then Break;
      FindClose(SR);
      if GetTickCount64 - Started > 10000 then raise Exception.Create('Upload timed out');
      Sleep(25);
    until False;
  end;
  { Leaving a marker simulates a process that died without orderly shutdown. }
  if (Mode <> 'mark') and (Mode <> 'early') then MarkClientCleanExit;
end.
