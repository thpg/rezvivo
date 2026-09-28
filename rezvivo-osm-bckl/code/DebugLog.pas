{ DebugLog — тонкая обёртка над CastleLog.

  Один файл на запуск:  log/YYYY-MM-DD_HH-NN-SS.log  рядом с exe.
  Logger.Info/Warning/Error/Debug → WritelnLog / WritelnWarning.
  GLogEnabled (/log) остаётся только для шумного UI (FPS, трейс кадра). }
unit DebugLog;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  TLogLevel = (llDebug, llInfo, llWarning, llError);

  TOnLogMessage = procedure(const Msg: string) of object;

  { Совместимый фасад: старые вызовы Logger.Info остаются, пишут в CGE. }
  TDebugLogger = class
  private
    FEnabled: Boolean;
    FOnLogMessage: TOnLogMessage;
    FCategory: String;
    procedure Emit(Level: TLogLevel; const Msg: string);
    function GetFileName: string;
  public
    constructor Create(const ACategory: string = '');
    procedure Log(Level: TLogLevel; const Msg: string);
    procedure Debug(const Msg: string);
    procedure Info(const Msg: string);
    procedure Warning(const Msg: string);
    procedure Error(const Msg: string);
    procedure FlushNow;
    property Enabled: Boolean read FEnabled write FEnabled;
    property LogToFile: Boolean read FEnabled write FEnabled;
    property FileName: string read GetFileName;
    property OnLogMessage: TOnLogMessage read FOnLogMessage write FOnLogMessage;
  end;

function GetLogFileName: string;

{ Создаёт папку log/, задаёт LogFileName, InitializeLog, пишет снимок среды
  (без GPU — контекст GL ещё может быть не готов). Идемпотентно. }
procedure EnsureCgeLog;

{ GPU / GL — звать из Application.OnInitialize, когда контекст уже есть. }
procedure DumpEnvironmentGpu;

{ BLE / ANT+ / слоты сенсоров — после создания DeviceService. }
procedure DumpEnvironmentDevices;

var
  GLogEnabled: Boolean = False;
  Logger: TDebugLogger;
  TraceLog: TDebugLogger;

implementation

uses
  CastleLog, CastleApplicationProperties, CastleURIUtils, CastleGLUtils,
  Osm3dStudioLog
  {$ifdef MSWINDOWS}, Windows{$endif};

procedure Osm3dToCge(Level: Osm3dStudioLog.TLogLevel; const Msg: string);
begin
  case Level of
    Osm3dStudioLog.llWarn, Osm3dStudioLog.llError:
      WritelnWarning('Osm3d', Msg);
  else
    WritelnLog('Osm3d', Msg);
  end;
end;

function DetectLogParam: Boolean;
var
  I: Integer;
begin
  for I := 1 to ParamCount do
    if SameText(ParamStr(I), '/log') or
       SameText(ParamStr(I), '-log') or
       SameText(ParamStr(I), '--log') then
      Exit(True);
  Result := False;
end;

function GetLogFileName: string;
begin
  Result := LogFileName;
end;

function BoolYes(B: Boolean): string;
begin
  if B then Result := 'yes' else Result := 'no';
end;

function FormatBytes(N: QWord): string;
begin
  if N >= QWord(1024) * 1024 * 1024 then
    Result := Format('%.1f GiB', [N / (1024.0 * 1024.0 * 1024.0)])
  else if N >= QWord(1024) * 1024 then
    Result := Format('%.1f MiB', [N / (1024.0 * 1024.0)])
  else
    Result := Format('%d B', [N]);
end;

{$ifdef MSWINDOWS}
type
  TMemStatusEx = record
    dwLength: DWORD;
    dwMemoryLoad: DWORD;
    ullTotalPhys: QWord;
    ullAvailPhys: QWord;
    ullTotalPageFile: QWord;
    ullAvailPageFile: QWord;
    ullTotalVirtual: QWord;
    ullAvailVirtual: QWord;
    ullAvailExtendedVirtual: QWord;
  end;

function GlobalMemoryStatusEx(var Buf: TMemStatusEx): BOOL; stdcall;
  external 'kernel32.dll' name 'GlobalMemoryStatusEx';

function ReadCpuName: string;
begin
  Result := Trim(SysUtils.GetEnvironmentVariable('PROCESSOR_IDENTIFIER'));
  if Result = '' then
    Result := Trim(SysUtils.GetEnvironmentVariable('PROCESSOR_ARCHITECTURE'));
end;
{$endif}

procedure DumpEnvironment;
var
  I: Integer;
  DataPath: string;
  {$ifdef MSWINDOWS}
  SI: TSystemInfo;
  MS: TMemStatusEx;
  {$endif}
begin
  WritelnLog('Env', '========== environment ==========');
  WritelnLog('Env', 'App: ' + ApplicationProperties.ApplicationName +
    ' v' + ApplicationProperties.Version);
  WritelnLog('Env', 'Caption: ' + ApplicationProperties.Caption);
  WritelnLog('Env', 'FPC: ' + {$I %FPCVERSION%} + '  target: ' +
    {$I %FPCTARGETCPU%} + '-' + {$I %FPCTARGETOS%});
  WritelnLog('Env', 'Exe: ' + ParamStr(0));
  WritelnLog('Env', 'Cwd: ' + GetCurrentDir);
  DataPath := URIToFilenameSafe('castle-data:/');
  if DataPath = '' then
    DataPath := '(unresolved)';
  WritelnLog('Env', 'Data: ' + DataPath);
  WritelnLog('Env', 'Data exists: ' + BoolYes(DirectoryExists(DataPath)));
  WritelnLog('Env', 'LogFile: ' + LogFileName);
  WritelnLog('Env', 'GLogEnabled (/log): ' + BoolYes(GLogEnabled));

  if ParamCount > 0 then
  begin
    for I := 1 to ParamCount do
      WritelnLog('Env', Format('Arg[%d]: %s', [I, ParamStr(I)]));
  end else
    WritelnLog('Env', 'Args: (none)');

  {$ifdef MSWINDOWS}
  try
    GetSystemInfo(SI);
    WritelnLog('Env', Format('CPU: %d logical, page=%d',
      [SI.dwNumberOfProcessors, SI.dwPageSize]));
    WritelnLog('Env', 'CPU name: ' + ReadCpuName);
    FillChar(MS, SizeOf(MS), 0);
    MS.dwLength := SizeOf(MS);
    if GlobalMemoryStatusEx(MS) then
    begin
      WritelnLog('Env', 'RAM total: ' + FormatBytes(MS.ullTotalPhys) +
        '  avail: ' + FormatBytes(MS.ullAvailPhys) +
        Format('  load=%d%%', [MS.dwMemoryLoad]));
      WritelnLog('Env', 'Pagefile total: ' + FormatBytes(MS.ullTotalPageFile) +
        '  avail: ' + FormatBytes(MS.ullAvailPageFile));
    end;
  except
    on E: Exception do
      WritelnWarning('Env', 'Win32 hardware query failed: ' + E.Message);
  end;
  {$else}
  WritelnLog('Env', 'CPU/RAM: non-Windows, see OS tools');
  {$endif}

  try
    WritelnLog('Env', 'Disk free (exe drive): ' + FormatBytes(DiskFree(0)));
  except
    on E: Exception do
      WritelnWarning('Env', 'DiskFree failed: ' + E.Message);
  end;

  WritelnLog('Env', '========== /environment ==========');
end;

procedure DumpEnvironmentGpu;
begin
  WritelnLog('GPU', '========== GPU / GL ==========');
  try
    WritelnLog('GPU', GLInformationString);
  except
    on E: Exception do
      WritelnWarning('GPU', 'Query failed: ' + E.Message);
  end;
  WritelnLog('GPU', '========== /GPU ==========');
end;

procedure DumpEnvironmentDevices;
begin
  { Реальная регистрация провайдеров логируется из GameDeviceService.
    Здесь только заголовок-маркер, чтобы блок был в одном месте файла. }
  WritelnLog('Devices', '========== BLE / ANT+ (see DeviceService lines) ==========');
end;

var
  GStarted: Boolean = False;

procedure EnsureCgeLog;
var
  Dir: string;
begin
  if not GStarted then
  begin
    Dir := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'log';
    if not DirectoryExists(Dir) then
    begin
      try
        ForceDirectories(Dir);
      except
        Dir := ExtractFilePath(ParamStr(0));
      end;
    end;
    if LogFileName = '' then
      LogFileName := IncludeTrailingPathDelimiter(Dir) +
        FormatDateTime('yyyy-mm-dd_hh-nn-ss', Now) + '.log';
    LogTimePrefix := ltTime;
  end;

  InitializeLog;
  Osm3dStudioLog.ExternalLog := @Osm3dToCge;

  if not GStarted then
  begin
    GStarted := True;
    DumpEnvironment;
  end;
end;

constructor TDebugLogger.Create(const ACategory: string);
begin
  inherited Create;
  FEnabled := True;
  FCategory := ACategory;
end;

function TDebugLogger.GetFileName: string;
begin
  Result := LogFileName;
end;

procedure TDebugLogger.Emit(Level: TLogLevel; const Msg: string);
var
  Cat: string;
begin
  if not FEnabled then Exit;
  Cat := FCategory;
  if Cat = '' then
    Cat := 'App';
  case Level of
    llWarning: WritelnWarning(Cat, Msg);
    llError:   WritelnWarning(Cat, 'ERROR ' + Msg);
  else
    WritelnLog(Cat, Msg);
  end;
  if Assigned(FOnLogMessage) then
    FOnLogMessage(Msg);
end;

procedure TDebugLogger.Log(Level: TLogLevel; const Msg: string);
begin
  Emit(Level, Msg);
end;

procedure TDebugLogger.Debug(const Msg: string);
begin
  Emit(llDebug, Msg);
end;

procedure TDebugLogger.Info(const Msg: string);
begin
  Emit(llInfo, Msg);
end;

procedure TDebugLogger.Warning(const Msg: string);
begin
  Emit(llWarning, Msg);
end;

procedure TDebugLogger.Error(const Msg: string);
begin
  Emit(llError, Msg);
end;

procedure TDebugLogger.FlushNow;
begin
end;

initialization
  GLogEnabled := DetectLogParam;
  Logger := TDebugLogger.Create('');
  Logger.Enabled := True;
  TraceLog := TDebugLogger.Create('Trace');
  TraceLog.Enabled := GLogEnabled;

finalization
  TraceLog.Free;
  Logger.Free;

end.
