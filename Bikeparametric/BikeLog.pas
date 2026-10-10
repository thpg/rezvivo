{ BikeLog — startup diagnostics logger.

  Disabled by default. Define BIKE_STARTUP_LOG explicitly for diagnostics.
  When enabled, StartupLog writes lines to a single per-process log file:
    <exe-dir>/logs/startup_anim_<yyyymmdd_hhnnss>.log
  The timestamp is captured on first call, so every StartupLog issued during
  one run ends up in the same file. Directory is created on demand.
  Thread-safe via a critical section.

  Failures (e.g. read-only directory) are silently ignored — logging is
  best-effort, not a hard dependency.

  License: MIT
}
unit BikeLog;

{$mode objfpc}{$H+}

interface

var
  { True = dump generated shader sources to disk on every build
    (frame_shader.glsl, logs/gpu_skin.vs). Debug aid, off by default —
    the writes sit in the hot build path. }
  BikeDumpShaders: Boolean = False;

procedure StartupLog(const Msg: string);

implementation

{$IFDEF BIKE_STARTUP_LOG}

uses
  AppRuntimePaths, SysUtils, SyncObjs;

var
  FLogFile: TextFile;
  FLogOpen: Boolean = False;
  FLogTried: Boolean = False;
  FLogLock: TCriticalSection = nil;

{ Build full path: <exe-dir>/logs/startup_anim_<TIME>.log
  Timestamp is captured once at first call (static local-like via var init). }
function LogFilePath: string;
const
  FNamePrefix = 'startup_anim_';
  FNameSuffix = '.log';
var
  Dir: string;
begin
  Dir := AppDirectory + 'logs' + PathDelim;
  Result := Dir + FNamePrefix +
    FormatDateTime('yyyymmdd_hhnnss', Now) + FNameSuffix;
end;

{ Lazy open, called from inside the lock. Tries once per process; if the open
  fails we flip FLogTried so subsequent calls become cheap no-ops. }
procedure EnsureOpen;
var
  Path, Dir: string;
begin
  if FLogOpen or FLogTried then Exit;
  FLogTried := True;
  try
    Path := LogFilePath;
    Dir := ExtractFilePath(Path);
    ForceDirectories(Dir);   { creates logs/ if missing; no-op if exists }
    AssignFile(FLogFile, Path);
    Rewrite(FLogFile);
    FLogOpen := True;
  except
    FLogOpen := False;
  end;
end;

procedure StartupLog(const Msg: string);
begin
  if FLogLock = nil then Exit;   { before initialization or after finalization }
  FLogLock.Enter;
  try
    EnsureOpen;
    if not FLogOpen then Exit;
    try
      WriteLn(FLogFile, Msg);
      Flush(FLogFile);
    except
      { Don't let a logging hiccup kill the caller. }
    end;
  finally
    FLogLock.Leave;
  end;
end;

initialization
  FLogLock := TCriticalSection.Create;

finalization
  if FLogLock <> nil then FLogLock.Enter;
  try
    if FLogOpen then
    begin
      try CloseFile(FLogFile); except end;
      FLogOpen := False;
    end;
  finally
    if FLogLock <> nil then FLogLock.Leave;
  end;
  FreeAndNil(FLogLock);

{$ELSE}

procedure StartupLog(const Msg: string);
begin
end;

{$ENDIF}
end.
