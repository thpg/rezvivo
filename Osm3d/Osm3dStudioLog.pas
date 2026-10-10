unit Osm3dStudioLog;

{$mode objfpc}{$H+}
{$codepage UTF8}

interface

uses
  Classes,
  SysUtils,
  SyncObjs
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
;

const
  { Master logging switch. False -> every TLogTarget.Write is a no-op (no file I/O, no callback, no
    main-thread marshalling); being a compile-time constant, `if not LOGGING_ENABLED then Exit`
    dead-code-eliminates, so a disabled build pays zero cost per call. Set False to kill all logging
    (e.g. when diagnosing stalls from the per-line synchronous file I/O under GLogFileLock). }
  LOGGING_ENABLED = True;

type
  TLogLevel = (llDebug, llInfo, llWarn, llError);

  TLogLineCallback = procedure(const Line: string) of object;

  TLogTarget = class
  public
    procedure Write(Level: TLogLevel; const Msg: string); virtual; abstract;
  end;

  TConsoleLogTarget = class(TLogTarget)
  private
    FCS:        TCriticalSection;
    FUseColor:  Boolean;
    FMinLevel:  TLogLevel;
  public
    constructor Create(AUseColor: Boolean = False; AMinLevel: TLogLevel = llInfo);
    destructor  Destroy; override;
    procedure   Write(Level: TLogLevel; const Msg: string); override;

    property MinLevel: TLogLevel read FMinLevel write FMinLevel;
    property UseColor: Boolean   read FUseColor write FUseColor;
  end;

  { Calls Callback(Line) for every message (Synchronized when off-thread).
    Also appends every message to LogFile if set. File is opened/closed
    per message so entries survive a crash. }
  TCallbackLogTarget = class(TLogTarget)
  private
    FCS:           TCriticalSection;
    FCallback:     TLogLineCallback;
    FMinLevel:     TLogLevel;
    FQueue:        TStringList;   { lines awaiting the main thread }
    FLogFile:      string;
    FResolvedFile: string;
    procedure   DoMainThreadCall;
    procedure   AppendToFile(const Line: string);
    procedure   ResolveLogFile;
  public
    constructor Create(ACallback: TLogLineCallback; AMinLevel: TLogLevel = llInfo);
    destructor  Destroy; override;
    procedure   Write(Level: TLogLevel; const Msg: string); override;

    property MinLevel: TLogLevel read FMinLevel write FMinLevel;
    property Callback: TLogLineCallback read FCallback write FCallback;

    { Set to '' to disable. }
    property LogFile: string read FLogFile write FLogFile;
    { Actual write path. May differ from LogFile if fallback to %TEMP% was used. }
    property ResolvedLogFile: string read FResolvedFile;
  end;

  TFileLogTarget = class(TLogTarget)
  private
    FCS:           TCriticalSection;
    FMinLevel:     TLogLevel;
    FLogFile:      string;
    FResolvedFile: string;
    procedure ResolveLogFile;
  public
    constructor Create(const ALogFile: string = ''; AMinLevel: TLogLevel = llInfo);
    destructor  Destroy; override;
    procedure   Write(Level: TLogLevel; const Msg: string); override;

    property MinLevel:        TLogLevel read FMinLevel     write FMinLevel;
    property LogFile:         string    read FLogFile      write FLogFile;
    property ResolvedLogFile: string    read FResolvedFile;
  end;

  { Convenience base for any object that owns a TLogTarget — assign FLog
    in the subclass constructor and use LogInfo/Warn/Error/Debug directly. }
  TLogOwner = class
  protected
    FLog: TLogTarget;
    procedure LogInfo (const S: string);
    procedure LogWarn (const S: string);
    procedure LogError(const S: string);
    procedure LogDebug(const S: string);
  end;

function FormatLogLine(Level: TLogLevel; const Msg: string): string;
function DefaultLogFile: string;

{ Если задан — строки идут сюда, файлы osm3d_*.log / osm3d_gen_*.log
  не создаются. Игра ставит это на CastleLog в EnsureCgeLog. }
type
  TExternalLogProc = procedure(Level: TLogLevel; const Msg: string);

var
  ExternalLog: TExternalLogProc = nil;

{ <exe-dir>/log/osm3d_gen_<session-start>.log — ОТДЕЛЬНЫЙ лог ГЕНЕРАЦИИ
  (диагностика дефектов геометрии). Та же папка log/ и тот же штамп времени
  запуска, что и у основного osm3d_<session>.log, поэтому пара файлов легко
  сопоставляется. Свой файловый хэндл (не мешает основному логу). }
function GenDiagLogFile: string;

{ Записать одну строку в ген-лог. Потокобезопасно (пишется и из воркеров
  генерации). Формат строки задаёт вызывающий — здесь добавляется только
  перевод строки. Ничего не делает при GenDiagEnabled=False или
  LOGGING_ENABLED=False. }
procedure GenLog(const Msg: string);

const
  LOG_LEVEL_NAMES: array[TLogLevel] of string =
    ('DEBUG', 'INFO ', 'WARN ', 'ERROR');

var
  { Диагностический ген-лог включён. Ставится в True в initialization; сними,
    чтобы заглушить ген-сообщения без перекомпиляции логики. }
  GenDiagEnabled: Boolean;

implementation
uses AppRuntimePaths;


function FormatLogLine(Level: TLogLevel; const Msg: string): string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(879);{$ENDIF}
  { Millisecond precision: sub-second ordering matters for diagnosing
    per-frame stalls — without zzz, mount/unmount/render events in the
    same second are indistinguishable. }
  Result := Format('[%s %s] %s',
    [LOG_LEVEL_NAMES[Level],
     FormatDateTime('hh:nn:ss.zzz', Now),
     Msg]);
end;

var
  { Session/run start, computed once on the first log-path build (i.e.
    when the first log target is created). Woven into the log filename so
    both the worker (TCallbackLogTarget) and main-thread (TFileLogTarget)
    targets land in the SAME file for this run. }
  GSessionStamp: string = '';

function SessionStamp: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1746);{$ENDIF}
  if GSessionStamp = '' then
    GSessionStamp := FormatDateTime('yyyy-mm-dd_hh-nn-ss', Now);
  Result := GSessionStamp;
end;

function DefaultLogFile: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(880);{$ENDIF}
  { <exe-dir>/log/osm3d_<session-start>.log — own subfolder, and the
    start time woven into the name so every run gets its own file
    instead of overwriting one osm3d.log. The log/ directory is created
    at resolve time (ResolveLogFilePath, before the first write). }
  Result := IncludeTrailingPathDelimiter(AppDirectory)
            + 'log' + PathDelim
            + 'osm3d_' + SessionStamp + '.log';
end;

function GenDiagLogFile: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1748);{$ENDIF}
  { Тот же штамп сессии, что и у DefaultLogFile — пара osm3d_<stamp>.log /
    osm3d_gen_<stamp>.log относится к одному запуску. }
  Result := IncludeTrailingPathDelimiter(AppDirectory)
            + 'log' + PathDelim
            + 'osm3d_gen_' + SessionStamp + '.log';
end;

function CanWriteFile(const FileName: string): Boolean;
{ Проверяем возможность записи. ВАЖНО: существующий файл НЕ открываем пробой —
  это почти всегда наш активный лог, уже открытый постоянным хэндлом
  RawAppendToFile (без share-write). Повторный Append дал бы sharing violation,
  а под $I+ это НЕперехватываемый RunError(216) (try/except его не ловит) —
  именно отсюда падение при втором запуске стрима (открытие FIT → новая сессия →
  новые лог-таргеты → проба уже открытого файла). Поэтому: файл есть → считаем
  записываемым; файла нет → пробуем создать под $I- (ошибки через IOResult,
  без RunError) и удаляем пробный файл, чтобы проба не оставляла следов. }
var
  F: TextFile;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(881);{$ENDIF}
  Result := False;
  if FileExists(FileName) then
  begin
    Result := True;
    Exit;
  end;
  {$PUSH}{$I-}
  AssignFile(F, FileName);
  Rewrite(F);
  if IOResult = 0 then
  begin
    CloseFile(F);
    if IOResult = 0 then
      Result := True;
  end;
  {$POP}
  if Result then
    SysUtils.DeleteFile(FileName);
end;

function ResolveLogFilePath(const Requested: string): string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(882);{$ENDIF}
  Result := Requested;
  if Result = '' then Exit;
  { Create the parent dir (the new log/ subfolder) before the writability
    probe — both CanWriteFile's and RawAppendToFile's Rewrite fail on a
    missing directory, which would otherwise silently drop the whole log. }
  ForceDirectories(ExtractFilePath(Result));
  if CanWriteFile(Result) then Exit;

  { Fallback to %TEMP%/osm3d-log, keeping the timestamped basename. }
  Result := IncludeTrailingPathDelimiter(GetTempDir(False)) +
            'osm3d-log' + PathDelim + ExtractFileName(Requested);
  ForceDirectories(ExtractFilePath(Result));
  if not CanWriteFile(Result) then
    Result := '';
end;

var
  { Serialises ALL RawAppendToFile calls. The log is written from many
    threads (workers + pipeline); without a lock Windows gives sharing
    violations and Linux gives interleaved lines. Locked at this level
    so external callers don't have to know. }
  GLogFileLock: TCriticalSection = nil;
  { Лог-файл держится ОТКРЫТЫМ между строками: open-append-close на
    каждую строку (~0.1-1 мс NTFS, до десятков мс с антивирусом, всё под
    глобальным локом) давал большие фризы при шторме строк. Durability
    сохранена: Flush после каждой записи отдаёт буфер в кэш ОС — данные
    переживают крэш процесса. }
  GLogOpenFile: TextFile;
  GLogOpenName: string = '';
  GLogOpenOK:   Boolean = False;

  { Отдельный постоянный хэндл для ГЕН-лога. Свой файл, но ТОТ ЖЕ GLogFileLock —
    так основной и ген-лог не борются за один хэндл (иначе каждое чередование
    строк основного/ген-лога закрывало-переоткрывало файл = фризы). }
  GGenOpenFile: TextFile;
  GGenOpenName: string = '';
  GGenOpenOK:   Boolean = False;
  GGenResolved: string  = '';    { разрешённый путь ген-лога (кэш) }

procedure RawCloseLogFile;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1747);{$ENDIF}
  {$PUSH}{$I-}
  if GLogOpenOK then
  begin
    CloseFile(GLogOpenFile);
    IOResult;
  end;
  {$POP}
  GLogOpenOK   := False;
  GLogOpenName := '';
end;

procedure RawCloseGenFile;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1749);{$ENDIF}
  {$PUSH}{$I-}
  if GGenOpenOK then
  begin
    CloseFile(GGenOpenFile);
    IOResult;
  end;
  {$POP}
  GGenOpenOK   := False;
  GGenOpenName := '';
end;

procedure RawAppendToFile(const FileName, Line: string);
{ Файл открыт постоянно; переоткрытие — только при смене имени или
  ошибке записи.

  {$I-} is essential here. Without it FPC raises RunError(216) via
  FPC_BREAK_ERROR on I/O errors — a hard-terminate that try/except
  cannot catch in a worker thread without a properly installed handler.
  With {$I-} errors accumulate in IOResult and we check them. }
var
  IoErr: Word;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(883);{$ENDIF}
  if FileName = '' then Exit;
  if GLogFileLock = nil then Exit;       { not initialised / already finalised }

  GLogFileLock.Acquire;
  try
    {$PUSH}{$I-}
    if GLogOpenOK and (GLogOpenName <> FileName) then
      RawCloseLogFile;
    if not GLogOpenOK then
    begin
      AssignFile(GLogOpenFile, FileName);
      if FileExists(FileName) then
        Append(GLogOpenFile)
      else
        Rewrite(GLogOpenFile);
      if IOResult = 0 then
      begin
        GLogOpenOK   := True;
        GLogOpenName := FileName;
      end;
    end;
    if GLogOpenOK then
    begin
      Writeln(GLogOpenFile, Line);
      Flush(GLogOpenFile);
      IoErr := IOResult;
      if IoErr <> 0 then
        RawCloseLogFile;   { диск/права отвалились — попробуем переоткрыть позже }
    end;
    {$POP}
  finally
    GLogFileLock.Release;
  end;
end;

procedure RawAppendToGenFile(const FileName, Line: string);
{ Как RawAppendToFile, но для ГЕН-лога: свой постоянный хэндл GGenOpenFile,
  тот же глобальный лок. Правила {$I-} те же (RunError(216) в воркере
  неперехватываем — ошибки только через IOResult). }
var
  IoErr: Word;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1750);{$ENDIF}
  if FileName = '' then Exit;
  if GLogFileLock = nil then Exit;

  GLogFileLock.Acquire;
  try
    {$PUSH}{$I-}
    if GGenOpenOK and (GGenOpenName <> FileName) then
      RawCloseGenFile;
    if not GGenOpenOK then
    begin
      AssignFile(GGenOpenFile, FileName);
      if FileExists(FileName) then
        Append(GGenOpenFile)
      else
        Rewrite(GGenOpenFile);
      if IOResult = 0 then
      begin
        GGenOpenOK   := True;
        GGenOpenName := FileName;
      end;
    end;
    if GGenOpenOK then
    begin
      Writeln(GGenOpenFile, Line);
      Flush(GGenOpenFile);
      IoErr := IOResult;
      if IoErr <> 0 then
        RawCloseGenFile;
    end;
    {$POP}
  finally
    GLogFileLock.Release;
  end;
end;

procedure GenLog(const Msg: string);
begin
  if not LOGGING_ENABLED then Exit;
  if not GenDiagEnabled then Exit;
  {$IFDEF IAM_LIVE}IamLiveTrack(1751);{$ENDIF}
  if Assigned(ExternalLog) then
  begin
    ExternalLog(llInfo, Msg);
    Exit;
  end;
  { Разрешаем путь один раз (создаёт log/ или уходит в %TEMP%). }
  if GGenResolved = '' then
    GGenResolved := ResolveLogFilePath(GenDiagLogFile);
  RawAppendToGenFile(GGenResolved, Msg);
end;

constructor TConsoleLogTarget.Create(AUseColor: Boolean; AMinLevel: TLogLevel);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1272);{$ENDIF}
  inherited Create;
  FCS       := TCriticalSection.Create;
  FUseColor := AUseColor;
  FMinLevel := AMinLevel;
end;

destructor TConsoleLogTarget.Destroy;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1273);{$ENDIF}
  FreeAndNil(FCS);
  inherited;
end;

procedure TConsoleLogTarget.Write(Level: TLogLevel; const Msg: string);
const
  COLOR_RESET  = #27 + '[0m';
  COLOR_RED    = #27 + '[31m';
  COLOR_YELLOW = #27 + '[33m';
  COLOR_GRAY   = #27 + '[90m';
var
  Line: string;
begin
  if not LOGGING_ENABLED then Exit;
  {$IFDEF IAM_LIVE}IamLiveTrack(884);{$ENDIF}
  if Level < FMinLevel then Exit;
  if FCS = nil then Exit;
  Line := FormatLogLine(Level, Msg);

  FCS.Acquire;
  try
    try
      if FUseColor then
        case Level of
          llDebug: System.WriteLn(COLOR_GRAY,   Line, COLOR_RESET);
          llWarn:  System.WriteLn(COLOR_YELLOW, Line, COLOR_RESET);
          llError: System.WriteLn(COLOR_RED,    Line, COLOR_RESET);
        else
          System.WriteLn(Line);
        end
      else
        System.WriteLn(Line);
    except
      // I/O failure on stdout is not the logger's problem to surface
    end;
  finally
    FCS.Release;
  end;
end;

constructor TCallbackLogTarget.Create(ACallback: TLogLineCallback;
  AMinLevel: TLogLevel);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1274);{$ENDIF}
  inherited Create;
  FCS       := TCriticalSection.Create;
  FQueue    := TStringList.Create;
  FCallback := ACallback;
  FMinLevel := AMinLevel;
  FLogFile  := DefaultLogFile;
  if not Assigned(ExternalLog) then
    ResolveLogFile;
end;

destructor TCallbackLogTarget.Destroy;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1275);{$ENDIF}
  { Cancel any queued main-thread callbacks still referencing this
    object — they must not fire after it is freed. }
  TThread.RemoveQueuedEvents(nil, @DoMainThreadCall);
  FreeAndNil(FQueue);
  FreeAndNil(FCS);
  inherited;
end;

procedure TCallbackLogTarget.ResolveLogFile;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(885);{$ENDIF}
  FResolvedFile := ResolveLogFilePath(FLogFile);
end;

procedure TCallbackLogTarget.AppendToFile(const Line: string);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(886);{$ENDIF}
  if Assigned(ExternalLog) then Exit;
  { Re-resolve if LogFile changed at runtime. }
  if (FLogFile <> '') and (FResolvedFile = '') then
    ResolveLogFile;
  RawAppendToFile(FResolvedFile, Line);
end;

procedure TCallbackLogTarget.DoMainThreadCall;
var
  Lines: array of string;
  I:     Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(887);{$ENDIF}
  { Runs on the main thread. Snapshot + clear the queue under the lock,
    then invoke the callback OUTSIDE the lock — the callback touches the
    UI and must never run while a worker is blocked on FCS. }
  if FCS = nil then Exit;
  FCS.Acquire;
  try
    if (FQueue = nil) or (FQueue.Count = 0) then
    begin
      Lines := nil;
    end
    else
    begin
      SetLength(Lines, FQueue.Count);
      for I := 0 to FQueue.Count - 1 do
        Lines[I] := FQueue[I];
      FQueue.Clear;
    end;
  finally
    FCS.Release;
  end;

  if not Assigned(FCallback) then Exit;
  for I := 0 to High(Lines) do
    try
      FCallback(Lines[I]);
    except
      // callback may throw; do not propagate into the synchronizer
    end;
end;

procedure TCallbackLogTarget.Write(Level: TLogLevel; const Msg: string);
var
  Line: string;
  IsMainThread: Boolean;
begin
  if not LOGGING_ENABLED then Exit;
  {$IFDEF IAM_LIVE}IamLiveTrack(888);{$ENDIF}
  if Level < FMinLevel then Exit;
  if FCS = nil then Exit;

  if Assigned(ExternalLog) then
  begin
    ExternalLog(Level, Msg);
    Exit;
  end;

  Line := FormatLogLine(Level, Msg);

  { Always write to file regardless of callback / thread. }
  AppendToFile(Line);

  Exit;

  if not Assigned(FCallback) then Exit;

  IsMainThread := (MainThreadID = 0) or (GetCurrentThreadID = MainThreadID);

  if IsMainThread then
  begin
    { On the main thread the callback can run directly. Drain any
      lines workers have queued first so ordering is preserved. }
    DoMainThreadCall;
    try FCallback(Line); except end;
  end
  else
  begin
    { Worker thread. Append to the queue under a SHORT lock, then
      release it. The main-thread hand-off (TThread.Queue) happens
      OUTSIDE the lock and is non-blocking — the worker never waits
      for the main thread, and the main thread never waits for FCS
      while a worker holds it. This removes the Synchronize-under-
      lock deadlock that stalled geometry workers for ~46 s. }
    FCS.Acquire;
    try
      if FQueue <> nil then
        FQueue.Add(Line);
    finally
      FCS.Release;
    end;
    try
      TThread.Queue(nil, @DoMainThreadCall);
    except
    end;
  end;
end;

constructor TFileLogTarget.Create(const ALogFile: string; AMinLevel: TLogLevel);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1276);{$ENDIF}
  inherited Create;
  FCS       := TCriticalSection.Create;
  FMinLevel := AMinLevel;
  if ALogFile = '' then
    FLogFile := DefaultLogFile
  else
    FLogFile := ALogFile;
  if not Assigned(ExternalLog) then
    ResolveLogFile;
end;

destructor TFileLogTarget.Destroy;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1277);{$ENDIF}
  FreeAndNil(FCS);
  inherited;
end;

procedure TFileLogTarget.ResolveLogFile;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(889);{$ENDIF}
  FResolvedFile := ResolveLogFilePath(FLogFile);
end;

procedure TFileLogTarget.Write(Level: TLogLevel; const Msg: string);
var
  Line: string;
begin
  if not LOGGING_ENABLED then Exit;
  {$IFDEF IAM_LIVE}IamLiveTrack(890);{$ENDIF}
  if Level < FMinLevel then Exit;
  if FCS = nil then Exit;
  if Assigned(ExternalLog) then
  begin
    ExternalLog(Level, Msg);
    Exit;
  end;
  Line := FormatLogLine(Level, Msg);

  FCS.Acquire;
  try
    if (FLogFile <> '') and (FResolvedFile = '') then
      ResolveLogFile;
    RawAppendToFile(FResolvedFile, Line);
  finally
    FCS.Release;
  end;
end;

procedure TLogOwner.LogInfo(const S: string);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(891);{$ENDIF}
  if FLog <> nil then FLog.Write(llInfo, S);
end;

procedure TLogOwner.LogWarn(const S: string);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(892);{$ENDIF}
  if FLog <> nil then FLog.Write(llWarn, S);
end;

procedure TLogOwner.LogError(const S: string);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(893);{$ENDIF}
  if FLog <> nil then FLog.Write(llError, S);
end;

procedure TLogOwner.LogDebug(const S: string);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(894);{$ENDIF}
  if FLog <> nil then FLog.Write(llDebug, S);
end;

initialization
  GLogFileLock := TCriticalSection.Create;
  GenDiagEnabled := True;

finalization
  { On clean shutdown workers should already be joined. }
  if GLogFileLock <> nil then
  begin
    GLogFileLock.Acquire;
    try
      RawCloseLogFile;
      RawCloseGenFile;
    finally
      GLogFileLock.Release;
    end;
    GLogFileLock.Free;
    GLogFileLock := nil;
  end;

end.
