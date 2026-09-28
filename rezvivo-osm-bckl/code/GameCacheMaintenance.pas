unit GameCacheMaintenance;

{$mode objfpc}{$H+}

interface

uses Classes, SysUtils, SyncObjs;

type
  TDiskCacheState = record
    Bytes, Files, DeletedBytes, DeletedFiles: Int64;
    Issues: Integer;
    Done, Cancelled: Boolean;
    Error: string;
  end;

  { Owns no UI. Both enumeration and removal run on this worker. Only known
    cache data directories are visited; configuration in the root survives. }
  TDiskCacheJob = class(TThread)
  private
    FRoot, FShaderRoot: string;
    FClear: Boolean;
    FLock: TCriticalSection;
    FState, FWork: TDiskCacheState;
    FLastPublish: QWord;
    procedure Publish(Force: Boolean = False);
    procedure Visit(const Dir: string; DeleteFiles: Boolean; Depth: Integer);
    procedure VisitRoot(DeleteFiles: Boolean);
  protected
    procedure Execute; override;
  public
    constructor Create(const Root: string; Clear: Boolean; const ShaderRoot: string = '');
    destructor Destroy; override;
    function Snapshot: TDiskCacheState;
    property Clearing: Boolean read FClear;
  end;

implementation

function CacheDataDirectory(const Name: string): Boolean;
var S: string;
begin
  S := LowerCase(Name);
  Result := (S = 'o3dt') or (S = 'atlas') or
    ((Length(S) = 2) and (S[1] in ['0'..'9', 'a'..'f']) and
      (S[2] in ['0'..'9', 'a'..'f']));
end;

constructor TDiskCacheJob.Create(const Root: string; Clear: Boolean; const ShaderRoot: string);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  if Root <> '' then FRoot := IncludeTrailingPathDelimiter(ExpandFileName(Root));
  if ShaderRoot <> '' then FShaderRoot := ExpandFileName(ShaderRoot);
  FClear := Clear;
  FLock := TCriticalSection.Create;
end;

destructor TDiskCacheJob.Destroy;
begin
  Terminate;
  WaitFor;
  FLock.Free;
  inherited;
end;

function TDiskCacheJob.Snapshot: TDiskCacheState;
begin
  FLock.Enter;
  try
    Result := FState;
    { FPC can skip Execute entirely when a newly started worker has already
      been terminated (e.g. immediately leaving the settings page). }
    if Finished and not Result.Done then
    begin Result.Done := True; Result.Cancelled := True end;
  finally FLock.Leave end;
end;

procedure TDiskCacheJob.Publish(Force: Boolean);
var Tick: QWord;
begin
  Tick := GetTickCount64;
  if not Force and (Tick - FLastPublish < 100) then Exit;
  FLock.Enter;
  try FState := FWork;
  finally FLock.Leave end;
  FLastPublish := Tick;
end;

procedure TDiskCacheJob.Visit(const Dir: string; DeleteFiles: Boolean; Depth: Integer);
var SR: TSearchRec; Path: string; Attr, Code: LongInt;
begin
  if Terminated then Exit;
  Attr := FileGetAttr(ExcludeTrailingPathDelimiter(Dir));
  if Attr = -1 then Exit; // Another process may have removed a cache directory.
  { faSymLink also denotes Windows reparse points / directory junctions. }
  if ((Attr and faSymLink) <> 0) or (Depth > 64) then
  begin Inc(FWork.Issues); Exit end;
  Code := FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, SR);
  if Code <> 0 then
  begin
    if not (Code in [2, 3, 18]) then Inc(FWork.Issues);
    Exit;
  end;
  try
    repeat
      if Terminated then Break;
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      Path := IncludeTrailingPathDelimiter(Dir) + SR.Name;
      if (SR.Attr and faSymLink) <> 0 then
      begin Inc(FWork.Issues); Continue end;
      if (SR.Attr and faDirectory) <> 0 then
        Visit(Path, DeleteFiles, Depth + 1)
      else if DeleteFiles then
      begin
        { Do not remove in-flight atomic writes from a second instance / Studio.
          Leave directories in place so ongoing cache writers can finish. }
        if SameText(ExtractFileExt(Path), '.tmp') and
           (FileDateToDateTime(SR.Time) > Now - 1) then
        begin Inc(FWork.Issues); Continue end;
        if SysUtils.DeleteFile(Path) then
        begin
          Inc(FWork.DeletedFiles);
          Inc(FWork.DeletedBytes, SR.Size);
        end else if FileExists(Path) then Inc(FWork.Issues);
      end else
      begin
        Inc(FWork.Files);
        Inc(FWork.Bytes, SR.Size);
      end;
      Publish;
    until FindNext(SR) <> 0;
  finally FindClose(SR) end;
end;

procedure TDiskCacheJob.VisitRoot(DeleteFiles: Boolean);
var SR: TSearchRec; Attr, Code: LongInt;
begin
  if FRoot = '' then raise Exception.Create('Cache directory is not configured');
  Attr := FileGetAttr(ExcludeTrailingPathDelimiter(FRoot));
  if Attr = -1 then Exit; // No cache yet.
  if ((Attr and faDirectory) = 0) or ((Attr and faSymLink) <> 0) then
    raise Exception.Create('Cache directory is not a regular directory');
  Code := FindFirst(FRoot + '*', faAnyFile, SR);
  if Code <> 0 then
  begin
    if not (Code in [2, 3, 18]) then Inc(FWork.Issues);
    Exit;
  end;
  try
    repeat
      if Terminated then Break;
      if ((SR.Attr and faDirectory) <> 0) and CacheDataDirectory(SR.Name) then
        Visit(FRoot + SR.Name, DeleteFiles, 0);
    until FindNext(SR) <> 0;
  finally FindClose(SR) end;
end;

procedure TDiskCacheJob.Execute;
begin
  try
    if FClear then
    begin
      VisitRoot(True);
      if not Terminated and (FShaderRoot <> '') then Visit(FShaderRoot, True, 0);
    end;
    if not Terminated then
    begin
      VisitRoot(False); // Report remaining bytes, not an assumed zero.
      if FShaderRoot <> '' then Visit(FShaderRoot, False, 0);
    end;
  except
    on E: Exception do begin FWork.Error := E.Message; Inc(FWork.Issues) end;
  end;
  FWork.Cancelled := Terminated;
  FWork.Done := True;
  Publish(True);
end;

end.
