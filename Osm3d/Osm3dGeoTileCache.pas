unit Osm3dGeoTileCache;

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$codepage UTF8}

interface

uses
  Classes,
  SysUtils,
  SyncObjs,
  Generics.Collections,
  Osm3dStudioLog,
  Osm3dGeoMath,
  Osm3dGeoTileGrid,
  Osm3dTileX3D,
  Osm3dBuildingObstacleIndex,
  Osm3dStudioSettings, Osm3dKnowledgeRecipe
  {$IFDEF TILE_MEM_PROFILE}, Osm3dTileMemProfile, Osm3dMemCensus{$ENDIF}
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
;

type
  EGeoTileCacheError = class(Exception);

  TGeoTileCache = class
  private
    FRootDir:   string;       { '<root>/o3dt/v1/<genHash>/E<edge>/' }
    FGenHash:   string;
    FRecipes: TKnowledgeRecipeSnapshot;
    FTextFormat: Boolean;
    FGrid:      TGeoTileGrid;
    FLock:      TCriticalSection;

    { In-memory presence index — set of PathFor() keys known to exist on
      disk. Has() consults this instead of hitting the filesystem every
      call: a streaming Pump tests hundreds of tiles per frame, and a
      FileExists per tile per frame cost 15-47 ms of main-thread time.
      Built lazily on the first Has() by scanning the cache tree once;
      kept current by Save() / Delete(). }
    FIndex:     specialize TDictionary<string, Boolean>;
    FIndexBuilt: Boolean;
    FHasCalls:  Int64;   { diagnostic — total Has() calls this session }

    { Diagnostic log. Touched from worker threads (TryLoad / Save) and
      the main thread (Has) — so the host must hand in a target that
      never Synchronizes (a TFileLogTarget). nil = silent. }
    FLog:       TLogTarget;

    function ZoneDir(const T: TGeoTileId): string;
    function FormatPath(const T: TGeoTileId; TextFormat: Boolean): string;
    function ExpectedHash(const T: TGeoTileId): string;
    procedure EnsureIndex;    { lazy one-time disk scan }
    procedure WriteRoadSidecar(const AX3dPath: string; Model: TTileModel);
    procedure Log(const AMsg: string);
  public
    { Diagnostic log target — set by the host right after Create. Must
      be a non-Synchronizing target (TFileLogTarget): Has runs on the
      main thread, TryLoad/Save on workers. }
    property LogTarget: TLogTarget read FLog write FLog;
    { ARootDir      — base cache directory (created if missing).
      AGenHash      — generator / source-data version key.
      AHeightmapZoom/AEdgePx — slippy lattice; must match the grid that built
                      the tiles (= HeightmapZoom + GEO_TILE_EDGE_PX).
      ARefLatDeg    — latitude for the nominal EdgeMeters (path tag / logs). }
    constructor Create(const ARootDir, AGenHash: string;
                       AHeightmapZoom: Integer; AEdgePx: Integer = 0;
                       ARefLatDeg: Double = 0.0);
    destructor Destroy; override;

    { Preferred output path (.o3dt by default, .x3d in text mode).
      Readers must use TryLoad/TryLoadRoadSegs/TryLoadBuildingObstacles:
      legacy tiles may still exist in the other format. }
    function PathFor(const T: TGeoTileId): string;

    { Путь блок-PNG превью-текстуры. ANWTile — северо-западный тайл блока
      (TX=BX*BlockSize, TY=BY*BlockSize); путь строится по его quadkey, чтобы
      не вводить зависимость от Osm3dGeoTileBlock. Расширение '.ptex.png' —
      не пересекается с .x3d/.prev. }
    function BlockTexPath(const ANWTile: TGeoTileId; BlockSize: Integer = 0): string;

    { True if a cached file for T exists on disk. }
    function Has(const T: TGeoTileId): Boolean;

    { Load tile T. Returns False if absent, unreadable, or its o3d:gen
      does not match this cache's genHash (stale). On True the caller
      owns Model and must Free it. }
    {$IFDEF TILE_MEM_PROFILE}function MemoryBytes: Int64;{$ENDIF}
    function TryLoad(const T: TGeoTileId; out Model: TTileModel): Boolean;

    { Write Model as tile T. Stamps Model.TileId := T and
      Model.GenHash := this cache's hash before writing. Atomic
      (.tmp + rename). Raises EGeoTileCacheError on I/O failure. }
    procedure Save(const T: TGeoTileId; Model: TTileModel);

    { Быстрое чтение ТОЛЬКО дорожных сегментов тайла из сайдкара
      '<tile>.roads', который Save кладёт рядом с x3d. Снап-харвесту не
      нужен полный парсинг x3d (терраин/карв/деревья, ~1 с на тайл) ради
      крошечного списка сегментов: сайдкар читается за миллисекунды.
      AOrigin — гео-origin тайла (сегменты в его локальных координатах).
      False — сайдкара нет (старый кэш) или он битый: зовите TryLoad. }
    function TryLoadRoadSegs(const T: TGeoTileId;
      out ASegs: TTileRoadSegArray; out AOrigin: TLatLon): Boolean;
    function TryLoadBuildingObstacles(const T: TGeoTileId;
      out AObstacles: TBuildingObstacleArray; out AOrigin: TLatLon): Boolean;
    function RoadFingerprint(const T: TGeoTileId): string;

    { Remove a cached tile. No error if it was not present. }
    procedure Delete(const T: TGeoTileId);

    { Grid pass-throughs — so callers need only the cache object. }
    function TileAt(const P: TLatLon): TGeoTileId;
    function TilesCovering(const Box: TLatLonBox): TGeoTileIdArray;

    property Grid:    TGeoTileGrid read FGrid;
    property Recipes: TKnowledgeRecipeSnapshot read FRecipes;
    property GenHash: string       read FGenHash;
    property RootDir: string       read FRootDir;
  end;

implementation

uses Math, md5, Osm3dTileBinary, Osm3dTileCacheSupport;

{$IFDEF MSWINDOWS}
{ MoveFileExW с REPLACE_EXISTING: объявляем сами (паттерн Osm3dWorkerPool),
  НЕ через uses Windows — Windows.TCriticalSection (record) затеняет
  SyncObjs.TCriticalSection (class), которым пользуется этот юнит.
  Именно W-вариант: путь кэша содержит имя пользователя Windows
  (<user-profile>/...), и ANSI-версия (A) с UTF-8 байтами падает с
  ERROR_PATH_NOT_FOUND на любой не-ASCII машине. }
function O3DMoveFileExW(lpExistingFileName, lpNewFileName: PWideChar;
  dwFlags: LongWord): LongBool; stdcall; external 'kernel32' name 'MoveFileExW';
function O3DGetLastError: LongWord; stdcall; external 'kernel32' name 'GetLastError';
const
  O3D_MOVEFILE_REPLACE_EXISTING = LongWord($1);
  O3D_MOVEFILE_COPY_ALLOWED     = LongWord($2);
{$ENDIF}

const
  HemiSeg: array[Boolean] of string = ('S', 'N');

{ Атомарная публикация temp->target. На Windows MoveFileEx с
  MOVEFILE_REPLACE_EXISTING заменяет target ОДНОЙ операцией — без окна
  «файла нет» между DeleteFile и RenameFile (SysUtils.RenameFile
  перезаписать существующий target не умеет). На прочих платформах —
  прежний delete+rename. ALastError — код ошибки ОС при неудаче
  (0 на не-Windows и при успехе). }
function PublishFile(const TmpPath, Path: string;
  out ALastError: LongWord): Boolean;
{$IFDEF MSWINDOWS}
var
  WTmp, WDst: WideString;
{$ENDIF}
begin
  {$IFDEF MSWINDOWS}
  WTmp := TmpPath;   { CP-aware string → UTF-16 (кириллица в пути кэша) }
  WDst := Path;
  Result := O3DMoveFileExW(PWideChar(WTmp), PWideChar(WDst),
    O3D_MOVEFILE_REPLACE_EXISTING or O3D_MOVEFILE_COPY_ALLOWED);
  if Result then
    ALastError := 0
  else
    ALastError := O3DGetLastError;
  {$ELSE}
  ALastError := 0;
  if FileExists(Path) then DeleteFile(Path);
  Result := RenameFile(TmpPath, Path);
  {$ENDIF}
end;

{ Keep a hash usable as a single path segment (defensive — hashes are
  normally hex, but a caller could pass anything). }
function SanitizeSegment(const S: string): string;
var I: Integer; C: Char;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(123);{$ENDIF}
  Result := '';
  for I := 1 to Length(S) do
  begin
    C := S[I];
    if ((C >= '0') and (C <= '9')) or
       ((C >= 'a') and (C <= 'z')) or
       ((C >= 'A') and (C <= 'Z')) or
       (C = '-') or (C = '_') then
      Result := Result + C
    else
      Result := Result + '_';
  end;
  if Result = '' then Result := 'none';
end;

constructor TGeoTileCache.Create(const ARootDir, AGenHash: string;
  AHeightmapZoom: Integer; AEdgePx: Integer = 0;
  ARefLatDeg: Double = 0.0);
var
  EdgeSeg: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1052);{$ENDIF}
  inherited Create;
  FGenHash := AGenHash;
  EnsureTileCacheSupport(ARootDir);
  FTextFormat := TileCacheUsesText(ARootDir);
  FGrid    := TGeoTileGrid.Create(AHeightmapZoom, AEdgePx, ARefLatDeg);
  FLock    := TCriticalSection.Create;
  FIndex      := specialize TDictionary<string, Boolean>.Create;
  FIndexBuilt := False;
  {$IFDEF TILE_MEM_PROFILE}
  MemProbeAdd(Self, 'tile-index', mkRAM, @MemoryBytes);
  {$ENDIF}
  FRecipes := TKnowledgeRecipeSnapshot.Create(ARootDir, FGrid);
  FHasCalls   := 0;
  FLog        := nil;

  { Path tag encodes the slippy lattice (EdgePx @ zoom) so caches at different zoom/EdgePx never
    collide. The 'v3' segment invalidates all 'v2' caches (directory fan-out now keys off the low,
    significant quadkey digits — see ZoneDir). }
  EdgeSeg := Format('PX%dZ%d', [FGrid.EdgePx, FGrid.Zoom]);

  FRootDir :=
    IncludeTrailingPathDelimiter(ARootDir) +
    'o3dt' + PathDelim + 'v3' + PathDelim +
    SanitizeSegment(AGenHash) + PathDelim +
    EdgeSeg + PathDelim;

  if not ForceDirectories(FRootDir) then
    raise EGeoTileCacheError.CreateFmt(
      'Cannot create cache root: %s', [FRootDir]);
end;

destructor TGeoTileCache.Destroy;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1053);{$ENDIF}
  {$IFDEF TILE_MEM_PROFILE}MemProbeRemove(Self);{$ENDIF}
  FIndex.Free;
  FLock.Free;
  FRecipes.Free;
  FGrid.Free;
  inherited;
end;

function TGeoTileCache.ZoneDir(const T: TGeoTileId): string;
var
  QK: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(124);{$ENDIF}
  QK := TGeoTileGrid.QuadKey(T);          { 24 или 32 цифры, со старшего разряда }
  { Каталоги режем по МЛАДШИМ (значащим) цифрам quadkey. Старшие цифры — это
    высокие биты TX/TY: при крупных тайлах (EdgePx=256, z13 -> TX/TY 13 бит)
    верхние 11 цифр всегда '0', и срез по ним давал константные каталоги
    0000/0000/000X без развётвления. Младшие 12 цифр
    хорошо разбрасывают кластерный набор тайлов по каталогам. Полный
    quadkey остаётся в имени файла -> уникальность пути сохраняется. }
  Result := FRootDir +
            'Z' + IntToStr(T.Zone) + PathDelim +
            HemiSeg[T.North]               + PathDelim +
            Copy(QK, Length(QK) - 11, 4)   + PathDelim +
            Copy(QK, Length(QK) - 7, 4)    + PathDelim +
            Copy(QK, Length(QK) - 3, 4)    + PathDelim;
end;

function TGeoTileCache.PathFor(const T: TGeoTileId): string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(125);{$ENDIF}
  Result := FormatPath(T, FTextFormat);
end;

function TGeoTileCache.ExpectedHash(const T: TGeoTileId): string;
var H: string;
begin
  H:=FRecipes.TileHash(T); Result:=FGenHash;
  if H<>'' then Result:=Result+'-k'+H;
end;

function TGeoTileCache.FormatPath(const T: TGeoTileId; TextFormat: Boolean): string;
var H: string;
begin
  Result := ZoneDir(T) + TGeoTileGrid.QuadKey(T);
  H:=FRecipes.TileHash(T); if H<>'' then Result:=Result+'.k'+H;
  if TextFormat then Result := Result + '.x3d' else Result := Result + '.o3dt';
end;

function TGeoTileCache.BlockTexPath(const ANWTile: TGeoTileId; BlockSize: Integer): string;
var H: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1409);{$ENDIF}
  if BlockSize<1 then BlockSize:=GEO_BLOCK_SIZE;
  H:=FRecipes.BlockHash(ANWTile,BlockSize);
  Result := ZoneDir(ANWTile) + TGeoTileGrid.QuadKey(ANWTile);
  if H<>'' then Result:=Result+'.k'+H;
  Result:=Result+'.ptex.png';
end;

procedure TGeoTileCache.Log(const AMsg: string);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(126);{$ENDIF}
  { llDebug, not llInfo: the cache is the single noisiest channel in the log
    (per-tile Has MISS / Save ok / TryLoad — thousands of lines per session)
    and none of it is needed for geometry-build perf analysis. With the default
    target MinLevel = llInfo these collapse to nothing; set MinLevel := llDebug
    to bring the full cache trace back. }
  if FLog <> nil then
    FLog.Write(llDebug, 'cache: ' + AMsg);
end;

procedure TGeoTileCache.EnsureIndex;
{ One-time recursive scan of the cache tree — records every '*.x3d'
  tile file. The directory walk runs WITHOUT FLock (it can take seconds
  on a large cache, and holding FLock that long would stall every
  worker's TryLoad/Save and the main thread's Has — observed as a
  multi-second freeze). Only the short merge into FIndex is locked. }
var
  Found: TStringList;
  T0:    QWord;
  I:     Integer;

  procedure ScanDir(const ADir: string);
  var
    SR:   TSearchRec;
    Full: string;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(128);{$ENDIF}
    if FindFirst(ADir + '*', faAnyFile, SR) = 0 then
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then Continue;
        Full := ADir + SR.Name;
        if (SR.Attr and faDirectory) <> 0 then
          ScanDir(IncludeTrailingPathDelimiter(Full))
        else if SameText(ExtractFileExt(SR.Name), '.x3d')
             or  SameText(ExtractFileExt(SR.Name), '.o3dt')
             or  SameText(ExtractFileExt(SR.Name), '.prev') then
          Found.Add(Full);   { индекс присутствия: и .x3d, и .prev }
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(127);{$ENDIF}
  { Double-checked: a quick locked test, then the expensive scan
    unlocked, then a locked merge. FIndexBuilt only ever goes
    False -> True, so a racing second caller at worst scans twice and
    merges the same paths — harmless. }
  FLock.Enter;
  try
    if FIndexBuilt then Exit;
  finally
    FLock.Leave;
  end;

  T0    := GetTickCount64;
  Found := TStringList.Create;
  try
    if DirectoryExists(FRootDir) then
      ScanDir(IncludeTrailingPathDelimiter(FRootDir));

    FLock.Enter;
    try
      for I := 0 to Found.Count - 1 do
        FIndex.AddOrSetValue(Found[I], True);
      FIndexBuilt := True;
    finally
      FLock.Leave;
    end;
    Log(Format('index built — %d tiles in %d ms',
               [Found.Count, GetTickCount64 - T0]));
  finally
    Found.Free;
  end;
end;

function TGeoTileCache.Has(const T: TGeoTileId): Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(129);{$ENDIF}
  { EnsureIndex does its own (mostly unlocked) work; the lock here only
    guards the dictionary lookup — microseconds, never disk I/O. }
  EnsureIndex;
  FLock.Enter;
  try
    Result := FIndex.ContainsKey(FormatPath(T, False)) or
      FIndex.ContainsKey(FormatPath(T, True));
  finally
    FLock.Leave;
  end;
  { Diagnostic: Has is called hundreds of times per frame, so logging
    every call would flood the file. Log only misses (each one triggers
    a block generation) and a periodic call-count heartbeat. }
  Inc(FHasCalls);
  if not Result then
    Log(Format('Has MISS %s  (call #%d)', [T.ToString, FHasCalls]))
  else if (FHasCalls mod 2000) = 0 then
    Log(Format('Has heartbeat — %d calls so far', [FHasCalls]));
end;

{$IFDEF TILE_MEM_PROFILE}
function TGeoTileCache.MemoryBytes: Int64;
var
  K: string;
begin
  Result := 0;
  FLock.Enter;
  try
    for K in FIndex.Keys do
      Inc(Result, Length(K) + 48);
  finally
    FLock.Leave;
  end;
end;
{$ENDIF}

function TGeoTileCache.TryLoad(const T: TGeoTileId;
  out Model: TTileModel): Boolean;
var Path: string; M: TTileModel; Attempt: Integer; TextFormat: Boolean;
  T0: QWord;
begin
  Result := False; Model := nil; T0 := GetTickCount64;
  for Attempt := 0 to 1 do
  begin
    TextFormat := FTextFormat xor (Attempt = 1);
    Path := FormatPath(T, TextFormat);
    if not FileExists(Path) then Continue;
    M := nil;
    try
      if TextFormat then M := TTileX3D.LoadFile(Path)
      else M := TTileBinary.LoadFile(Path);
      if (M.GenHash <> ExpectedHash(T)) or not M.TileId.Equals(T) then
      begin FreeAndNil(M); Continue end;
    except
      on E: Exception do
      begin
        M.Free; Log('TryLoad FAILED ' + Path + ': ' + E.Message); Continue;
      end;
    end;
    { Migration runs on the existing IO worker, never in Has/the render loop.
      A failed conversion leaves the readable legacy tile intact. }
    if TextFormat and not FTextFormat then
      try Save(T, M) except
        on E: Exception do Log('binary migration deferred: ' + E.Message);
      end;
    Model := M; Result := True;
    {$IFDEF TILE_MEM_PROFILE}
    ProfileTileModel(Model, 'cache', T.ToString, GetTickCount64 - T0, FLog);
    {$ENDIF}
    Exit;
  end;
end;

procedure TGeoTileCache.Save(const T: TGeoTileId; Model: TTileModel);
var
  Path, TmpPath, Dir: string;
  T0: QWord;
  PubErr: LongWord;
  G: TGUID;
  OtherPath: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(131);{$ENDIF}
  if Model = nil then
    raise EGeoTileCacheError.Create('Save: Model = nil');

  { Stamp identity so a file is always self-describing. }
  Model.TileId  := T;
  Model.GenHash := ExpectedHash(T);

  Path := PathFor(T);
  Dir  := ExtractFilePath(Path);

  { File I/O (mkdir, write, rename) runs WITHOUT FLock — the atomic
    .tmp+rename is per-tile independent, and holding the cache lock
    across a disk write would block every Has / TryLoad. The lock is
    taken only for the FIndex update at the end. }
  if not ForceDirectories(Dir) then
    raise EGeoTileCacheError.CreateFmt(
      'Cannot create tile directory: %s', [Dir]);

  T0 := GetTickCount64;
  { A recipe suffix adds 34 characters. Keep the unique temporary name short
    so an otherwise valid cache path does not exceed Windows MAX_PATH. }
  CreateGUID(G); TmpPath := Dir + GUIDToString(G) + '.tmp';
  try
    if FTextFormat then TTileX3D.SaveFile(TmpPath, Model)
    else TTileBinary.SaveFile(TmpPath, Model);
  except
    on E: Exception do
    begin
      if FileExists(TmpPath) then DeleteFile(TmpPath);
      Log('Save FAILED ' + T.ToString + ': ' + E.Message);
      raise EGeoTileCacheError.CreateFmt(
        'Failed writing tile %s: %s', [T.ToString, E.Message]);
    end;
  end;

  { Atomic publish: replace the target in one move (see PublishFile). }
  if not PublishFile(TmpPath, Path, PubErr) then
  begin
    if FileExists(TmpPath) then DeleteFile(TmpPath);
    raise EGeoTileCacheError.CreateFmt(
      'Failed publishing tile %s (gle=%d, tmp="%s")',
      [T.ToString, PubErr, TmpPath]);
  end;

  { Keep the presence index current — the tile now exists. }
  FLock.Enter;
  try
    if FIndexBuilt then
      FIndex.AddOrSetValue(Path, True);
  finally
    FLock.Leave;
  end;

  if FTextFormat then
    try WriteRoadSidecar(Path, Model) except
      on E: Exception do Log('Save: roads sidecar FAILED ' + E.Message);
    end;

  { Only after successful atomic publication remove the superseded format.
    Binary ROAD is authoritative; it needs no separate .roads file. }
  OtherPath := FormatPath(T, not FTextFormat);
  if FileExists(OtherPath) and DeleteFile(OtherPath) then
  begin
    FLock.Enter;
    try FIndex.Remove(OtherPath) finally FLock.Leave end;
  end;
  if not FTextFormat then DeleteFile(OtherPath + '.roads');

  Log(Format('Save ok %s in %d ms', [T.ToString, GetTickCount64 - T0]));
end;

procedure TGeoTileCache.WriteRoadSidecar(const AX3dPath: string;
  Model: TTileModel);
const
  MAGIC: array[0..3] of AnsiChar = 'O3RS';   { Osm3d Road Segments }
  VER = 3;   { v3: + two float32 endpoint widths; v1/v2 still readable }
var
  FS: TFileStream;
  Tmp, Dst: string;
  I, N: Integer;
  V32: LongInt;
  D: Double;
  Seg: TTileRoadSeg;
  PubErr: LongWord;
  BFlag: Byte;
  G: TGUID;
begin
  Dst := AX3dPath + '.roads';
  CreateGUID(G); Tmp := ExtractFilePath(Dst) + GUIDToString(G) + '.tmp';
  FS := TFileStream.Create(Tmp, fmCreate);
  try
    FS.WriteBuffer(MAGIC, SizeOf(MAGIC));
    V32 := VER;                 FS.WriteBuffer(V32, 4);
    D := Model.Origin.Lat;      FS.WriteBuffer(D, 8);
    D := Model.Origin.Lon;      FS.WriteBuffer(D, 8);
    N := Model.RoadSegCount;
    V32 := N;                   FS.WriteBuffer(V32, 4);
    for I := 0 to N - 1 do
    begin
      Seg := Model.RoadSegs[I];
      FS.WriteBuffer(Seg.X0, 4);
      FS.WriteBuffer(Seg.Z0, 4);
      FS.WriteBuffer(Seg.X1, 4);
      FS.WriteBuffer(Seg.Z1, 4);
      FS.WriteBuffer(Seg.Width, 4);
      FS.WriteBuffer(Seg.WayId, 8);
      if Seg.IsBridge then BFlag := 1 else BFlag := 0;
      FS.WriteBuffer(BFlag, 1);   { BRIDGE_SNAP }
      FS.WriteBuffer(Seg.Surface.WidthStart,4);FS.WriteBuffer(Seg.Surface.WidthEnd,4);
    end;
  finally
    FS.Free;
  end;
  if not PublishFile(Tmp, Dst, PubErr) then
  begin
    if FileExists(Tmp) then DeleteFile(Tmp);
    raise EGeoTileCacheError.CreateFmt('sidecar publish failed (gle=%d)',
      [PubErr]);
  end;
end;

function TGeoTileCache.TryLoadRoadSegs(const T: TGeoTileId;
  out ASegs: TTileRoadSegArray; out AOrigin: TLatLon): Boolean;
const
  MAGIC: array[0..3] of AnsiChar = 'O3RS';
var
  FS: TFileStream;
  Path: string;
  Hdr: array[0..3] of AnsiChar;
  V32, N, I: LongInt;
  LatD, LonD: Double;
  Ver: LongInt;
  BFlag: Byte;
  M: TTileModel;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(133);{$ENDIF}
  Result := False;
  SetLength(ASegs, 0);
  AOrigin := TLatLon.Make(0, 0);
  Path := FormatPath(T, False);
  if FileExists(Path) and
    (not FTextFormat or not FileExists(FormatPath(T, True))) then
  try
    M := TTileBinary.LoadFile(Path, [tblRoads]);
    try
      if (M.GenHash <> ExpectedHash(T)) or not M.TileId.Equals(T) then Exit;
      AOrigin := M.Origin; SetLength(ASegs, M.RoadSegCount);
      for I := 0 to High(ASegs) do ASegs[I] := M.RoadSegs[I];
      Exit(True);
    finally M.Free end;
  except
    ASegs := nil; { fall back to the legacy sidecar if still present }
  end;
  Path := FormatPath(T, True) + '.roads';
  if not FileExists(Path) then Exit;   { старый кэш без сайдкара }
  try
    FS := TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite);
    try
      FS.ReadBuffer(Hdr, SizeOf(Hdr));
      if Hdr <> MAGIC then Exit;
      FS.ReadBuffer(V32, 4);
      Ver := V32;
      { v1 = no IsBridge; v2 = +1 byte IsBridge per seg (BRIDGE_SNAP). }
      if (Ver < 1) or (Ver > 3) then Exit;
      FS.ReadBuffer(LatD, 8);
      FS.ReadBuffer(LonD, 8);
      AOrigin := TLatLon.Make(LatD, LonD);
      FS.ReadBuffer(N, 4);
      if (N < 0) or (N > 10 * 1000 * 1000) then Exit;
      if ((Ver = 1) and (FS.Size-FS.Position <> Int64(N)*28)) or
         ((Ver = 2) and (FS.Size-FS.Position <> Int64(N)*29)) or
         ((Ver = 3) and (FS.Size-FS.Position <> Int64(N)*37)) then Exit;
      SetLength(ASegs, N);
      for I := 0 to N - 1 do
      begin
        FS.ReadBuffer(ASegs[I].X0, 4);
        FS.ReadBuffer(ASegs[I].Z0, 4);
        FS.ReadBuffer(ASegs[I].X1, 4);
        FS.ReadBuffer(ASegs[I].Z1, 4);
        FS.ReadBuffer(ASegs[I].Width, 4);
        FS.ReadBuffer(ASegs[I].WayId, 8);
        if Ver >= 2 then
        begin
          FS.ReadBuffer(BFlag, 1);
          ASegs[I].IsBridge := BFlag <> 0;
        end
        else
          ASegs[I].IsBridge := False;
        if Ver>=3 then begin
          FS.ReadBuffer(ASegs[I].Surface.WidthStart,4);FS.ReadBuffer(ASegs[I].Surface.WidthEnd,4);
          if IsNan(ASegs[I].Surface.WidthStart) or IsInfinite(ASegs[I].Surface.WidthStart) or
             IsNan(ASegs[I].Surface.WidthEnd) or IsInfinite(ASegs[I].Surface.WidthEnd) or
             (ASegs[I].Surface.WidthStart<0) or (ASegs[I].Surface.WidthEnd<0) or
             ((ASegs[I].Surface.WidthStart=0) xor (ASegs[I].Surface.WidthEnd=0)) or
             (Max(ASegs[I].Surface.WidthStart,ASegs[I].Surface.WidthEnd)>ASegs[I].Width+0.001) then
            raise EGeoTileCacheError.Create('Invalid road endpoint widths');
        end;
      end;
      Result := True;
    finally
      FS.Free;
    end;
  except
    { битый/недописанный сайдкар — тихий фолбэк на полный TryLoad }
    SetLength(ASegs, 0);
    Result := False;
  end;
end;

function TGeoTileCache.TryLoadBuildingObstacles(const T: TGeoTileId;
  out AObstacles: TBuildingObstacleArray; out AOrigin: TLatLon): Boolean;
var Path: string; M: TTileModel; Attempt: Integer; TextFormat: Boolean;
begin
  Result := False; AObstacles := nil; AOrigin := TLatLon.Make(0, 0);
  for Attempt := 0 to 1 do
  begin
    TextFormat := FTextFormat xor (Attempt = 1);
    Path := FormatPath(T, TextFormat);
    if not FileExists(Path) then Continue;
    try
      if TextFormat then
        AObstacles := TTileX3D.LoadBuildingObstacles(Path, AOrigin)
      else
      begin
        M := TTileBinary.LoadFile(Path, [tblBuildings]);
        try
          if (M.GenHash <> ExpectedHash(T)) or not M.TileId.Equals(T) then Continue;
          AOrigin := M.Origin; AObstacles := M.BuildingObstacles;
        finally M.Free end;
      end;
      Exit(True);
    except AObstacles := nil end;
  end;
end;

function TGeoTileCache.RoadFingerprint(const T: TGeoTileId): string;
var Path: string;
begin
  Result := '';
  Path := FormatPath(T, False);
  if FileExists(Path) and
    (not FTextFormat or not FileExists(FormatPath(T, True))) then
    Exit(TTileBinary.RoadFingerprint(Path));
  Path := FormatPath(T, True);
  if FileExists(Path) and FileExists(Path + '.roads') then
    Result := MD5Print(MD5File(Path + '.roads'));
end;

procedure TGeoTileCache.Delete(const T: TGeoTileId);
var Path: string; TextFormat: Boolean;
begin
  for TextFormat := False to True do
  begin
    Path := FormatPath(T, TextFormat);
    if FileExists(Path) and not DeleteFile(Path) then Continue;
    DeleteFile(Path + '.roads');
    FLock.Enter;
    try FIndex.Remove(Path) finally FLock.Leave end;
  end;
end;

function TGeoTileCache.TileAt(const P: TLatLon): TGeoTileId;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(136);{$ENDIF}
  Result := FGrid.TileAt(P);
end;

function TGeoTileCache.TilesCovering(const Box: TLatLonBox): TGeoTileIdArray;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(137);{$ENDIF}
  Result := FGrid.TilesCovering(Box);
end;

end.
