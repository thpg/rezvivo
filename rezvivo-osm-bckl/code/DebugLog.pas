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
  Osm3dStudioLog, GameMachineInfo;

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

procedure DumpEnvironment;
var
  I: Integer;
  DataPath: string;
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

  WritelnLog('Env', MachineInformation);

  try
    WritelnLog('Env', 'Disk free (exe drive): ' + FormatDiagnosticBytes(DiskFree(0)));
  except
    on E: Exception do
      WritelnWarning('Env', 'DiskFree failed: ' + E.Message);
  end;

  WritelnLog('Env', '========== /environment ==========');
end;

procedure DumpEnvironmentGpu;
var Info: string;
begin
  WritelnLog('GPU', '========== GPU / GL ==========');
  try
    Info := GLInformationString;
    SetMachineGraphicsInformation(Info);
    WritelnLog('GPU', Info);
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
  Name: string;
  function WritableLog(const Dir:string):string;
  var Probe:TFileStream;
  begin
    Result:='';
    try
      if not DirectoryExists(Dir) and not ForceDirectories(Dir) then Exit;
      Result:=IncludeTrailingPathDelimiter(Dir)+Name;
      Probe:=TFileStream.Create(Result,fmCreate or fmShareDenyNone);
      Probe.Free;
    except
      Result:='';
    end;
  end;
begin
  if not GStarted then
  begin
    if LogFileName = '' then
    begin
      Name:=FormatDateTime('yyyy-mm-dd_hh-nn-ss',Now)+'.log';
      LogFileName:=WritableLog(ExtractFilePath(ParamStr(0))+'log');
      { Program Files and other read-only installation folders are valid.
        Check the actual write, not just whether the directory exists. }
      if LogFileName='' then
        LogFileName:=WritableLog(IncludeTrailingPathDelimiter(GetAppConfigDir(False))+'log');
      if LogFileName='' then
        LogFileName:=WritableLog(IncludeTrailingPathDelimiter(GetTempDir(False))+'REZVIVO-log');
    end;
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
