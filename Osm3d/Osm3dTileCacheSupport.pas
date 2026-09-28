unit Osm3dTileCacheSupport;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
procedure EnsureTileCacheSupport(const Root: string);
function TileCacheUsesText(const Root: string): Boolean;
implementation
uses Classes, SysUtils, SyncObjs;
{$I Osm3dTileCacheSupport.inc}
var SupportLock: TCriticalSection; InstalledRoots: TStringList;

{$IFDEF MSWINDOWS}
function SupportMoveFile(OldName, NewName: PWideChar; Flags: LongWord): LongBool;
  stdcall; external 'kernel32' name 'MoveFileExW';
{$ENDIF}

procedure Install(const Path, Contents: string; OnlyIfAbsent: Boolean = False);
var F: TFileStream; Previous, Temp: string; G: TGUID; OK: Boolean;
begin
  if FileExists(Path) then
  begin
    if OnlyIfAbsent then Exit;
    F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      if F.Size = Length(Contents) then
      begin
        SetLength(Previous, F.Size);
        if Previous <> '' then F.ReadBuffer(Previous[1], Length(Previous));
        if Previous = Contents then Exit;
      end;
    finally F.Free end;
  end;
  CreateGUID(G); Temp := Path + '.' + GUIDToString(G) + '.tmp';
  try
    F := TFileStream.Create(Temp, fmCreate);
    try
      if Contents <> '' then F.WriteBuffer(Contents[1], Length(Contents));
    finally F.Free end;
    {$IFDEF MSWINDOWS}
    OK := SupportMoveFile(PWideChar(UTF8Decode(Temp)), PWideChar(UTF8Decode(Path)), 1);
    {$ELSE}
    OK := RenameFile(Temp, Path);
    {$ENDIF}
    if not OK then raise EInOutError.Create('Cannot install cache support: ' + Path);
  finally if FileExists(Temp) then DeleteFile(Temp) end;
end;

procedure EnsureTileCacheSupport(const Root: string);
var Base: string;
begin
  Base := IncludeTrailingPathDelimiter(ExpandFileName(Root));
  SupportLock.Enter;
  try
    if InstalledRoots.IndexOf(Base) >= 0 then Exit;
    try
      if not ForceDirectories(Base) then Exit;
      Install(Base + 'TILE_CACHE_FORMAT.md', TileCacheFormatDoc);
      Install(Base + 'tile_cache.py', TileCachePythonTool);
      Install(Base + 'tile-cache-format.cfg', 'binary'#10, True);
      InstalledRoots.Add(Base);
    except { Read-only cache remains readable. Retry on the next map load. } end;
  finally SupportLock.Leave end;
end;

function TileCacheUsesText(const Root: string): Boolean;
var Value, Path: string; F: TFileStream;
begin
  Value := LowerCase(Trim(GetEnvironmentVariable('REZVIVO_TILE_CACHE_FORMAT')));
  if Value = '' then
  begin
    Path := IncludeTrailingPathDelimiter(Root) + 'tile-cache-format.cfg';
    try
      if FileExists(Path) then
      begin
        F := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
        try
          if F.Size <= 128 then
          begin
            SetLength(Value, F.Size);
            if Value <> '' then F.ReadBuffer(Value[1], Length(Value));
          end;
        finally F.Free end;
      end;
    except Value := '' end;
  end;
  Result := LowerCase(Trim(Value)) = 'x3d';
end;

initialization
  SupportLock := TCriticalSection.Create;
  InstalledRoots := TStringList.Create;
finalization
  InstalledRoots.Free;
  SupportLock.Free;
end.
