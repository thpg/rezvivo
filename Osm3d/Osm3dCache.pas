unit Osm3dCache;

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$codepage UTF8}

interface

uses
  Classes,
  SysUtils,
  SyncObjs,
  MD5
  {$IFDEF TILE_MEM_PROFILE}, Osm3dMemCensus{$ENDIF}
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
;

type
  { Cache entry metadata. SizeBytes is filled in by Put. }
  TCacheMetadata = record
    ContentType: string;
    ETag:        string;
    FetchedAt:   TDateTime;  { 0 = not set }
    SizeBytes:   Int64;

    class function Make(const AContentType: string = '';
                        const AETag: string = ''): TCacheMetadata; static;
    class function Empty: TCacheMetadata; static;
  end;

  { Abstract cache base. All methods are thread-safe. }
  TCacheBase = class
  public
    function Has(const Key: string): Boolean; virtual; abstract;

    function Get(const Key: string; out Data: TBytes): Boolean; overload;
    function Get(const Key: string; out Data: TBytes;
                 out Meta: TCacheMetadata): Boolean; overload; virtual; abstract;

    procedure Put(const Key: string; const Data: TBytes); overload;
    procedure Put(const Key: string; const Data: TBytes;
                  const Meta: TCacheMetadata); overload; virtual; abstract;

    procedure Delete(const Key: string); virtual; abstract;
    function  GetMetadata(const Key: string;
                          out Meta: TCacheMetadata): Boolean; virtual; abstract;
    procedure Purge; virtual; abstract;
  end;

  TCacheBaseArray = array of TCacheBase;

{ Metadata serialisation: INI-like "key=value" per line, used by file cache. }
function CacheMetadataToText(const M: TCacheMetadata): string;
function TextToCacheMetadata(const Text: string; out M: TCacheMetadata): Boolean;

function FormatUtcIso8601(const DT: TDateTime): string;
function ParseUtcIso8601(const S: string; out DT: TDateTime): Boolean;

const
  DEFAULT_MEMORY_CACHE_BYTES = 64 * 1024 * 1024;

type
  TMemoryCacheEntry = class
    Key:      string;
    Data:     TBytes;
    Meta:     TCacheMetadata;
    { Intrusive doubly-linked LRU list: FLruHead = most recently used,
      FLruTail = eviction candidate. Maintained under FLock only. }
    LruPrev:  TMemoryCacheEntry;   { towards head (hotter) }
    LruNext:  TMemoryCacheEntry;   { towards tail (colder) }
  end;

  TMemoryCache = class(TCacheBase)
  private
    FEntries:  TStringList;
    FMaxBytes: Int64;
    FCurBytes: Int64;
    FLock:     TCriticalSection;
    FLruHead:  TMemoryCacheEntry;
    FLruTail:  TMemoryCacheEntry;
    procedure LruUnlink(E: TMemoryCacheEntry);
    procedure LruPushFront(E: TMemoryCacheEntry);
    procedure RemoveAt(Index: Integer);
    procedure EvictUntilFits(NeededBytes: Int64);
  public
    constructor Create(MaxBytes: Int64 = DEFAULT_MEMORY_CACHE_BYTES);
    destructor  Destroy; override;

    function  Has(const Key: string): Boolean; override;
    function  Get(const Key: string; out Data: TBytes;
                  out Meta: TCacheMetadata): Boolean; override;
    procedure Put(const Key: string; const Data: TBytes;
                  const Meta: TCacheMetadata); override;
    procedure Delete(const Key: string); override;
    function  GetMetadata(const Key: string;
                          out Meta: TCacheMetadata): Boolean; override;
    procedure Purge; override;

    {$IFDEF TILE_MEM_PROFILE}function MemoryBytes: Int64;{$ENDIF}
    function  Count: Integer;
    property  MaxBytes: Int64 read FMaxBytes;
  end;

  TFileSystemCache = class(TCacheBase)
  private
    FRootDir: string;
    function HashKey(const Key: string): string;
    function DataPath(const HashHex: string): string;
    function MetaPath(const HashHex: string): string;
    function EntryPath(const HashHex: string): string;
    procedure EnsureDirFor(const FullPath: string);
    function ReadAllBytes(const Path: string; out Data: TBytes): Boolean;
    function ReadAllText (const Path: string; out Text: string): Boolean;
    function ReadEntry(const Path: string; const LoadData: Boolean;
      out Data: TBytes; out Meta: TCacheMetadata): Boolean;
    function AtomicWriteEntry(const Path: string; const Data: TBytes;
      const Meta: TCacheMetadata): Boolean;
  public
    constructor Create(const ARootDir: string);
    destructor  Destroy; override;

    function  Has(const Key: string): Boolean; override;
    function  Get(const Key: string; out Data: TBytes;
                  out Meta: TCacheMetadata): Boolean; override;
    procedure Put(const Key: string; const Data: TBytes;
                  const Meta: TCacheMetadata); override;
    procedure Delete(const Key: string); override;
    function  GetMetadata(const Key: string;
                          out Meta: TCacheMetadata): Boolean; override;
    procedure Purge; override;

    property RootDir: string read FRootDir;
  end;

  TCompositeCache = class(TCacheBase)
  private
    FLayers:     TCacheBaseArray;
    FOwnsLayers: Boolean;
  public
    { OwnsLayers=True: composite frees layers in Destroy. }
    constructor Create(const ALayers: array of TCacheBase;
                       AOwnsLayers: Boolean = True);
    destructor  Destroy; override;

    function  Has(const Key: string): Boolean; override;
    function  Get(const Key: string; out Data: TBytes;
                  out Meta: TCacheMetadata): Boolean; override;
    procedure Put(const Key: string; const Data: TBytes;
                  const Meta: TCacheMetadata); override;
    procedure Delete(const Key: string); override;
    function  GetMetadata(const Key: string;
                          out Meta: TCacheMetadata): Boolean; override;
    procedure Purge; override;
    property  OwnsLayers: Boolean read FOwnsLayers write FOwnsLayers;
  end;

implementation

uses
  DateUtils;

class function TCacheMetadata.Make(const AContentType, AETag: string): TCacheMetadata;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1019);{$ENDIF}
  Result.ContentType := AContentType;
  Result.ETag        := AETag;
  Result.FetchedAt   := Now;
  Result.SizeBytes   := 0;
end;

class function TCacheMetadata.Empty: TCacheMetadata;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1020);{$ENDIF}
  Result.ContentType := '';
  Result.ETag        := '';
  Result.FetchedAt   := 0;
  Result.SizeBytes   := 0;
end;

function TCacheBase.Get(const Key: string; out Data: TBytes): Boolean;
var
  DummyMeta: TCacheMetadata;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(15);{$ENDIF}
  Result := Get(Key, Data, DummyMeta);
end;

procedure TCacheBase.Put(const Key: string; const Data: TBytes);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(16);{$ENDIF}
  Put(Key, Data, TCacheMetadata.Make);
end;

function FormatUtcIso8601(const DT: TDateTime): string;
var
  Y, M, D, H, Mn, S, Ms: Word;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(17);{$ENDIF}
  if DT = 0 then Exit('');
  DecodeDateTime(DT, Y, M, D, H, Mn, S, Ms);
  Result := Format('%.4d-%.2d-%.2dT%.2d:%.2d:%.2d.%.3dZ',
    [Y, M, D, H, Mn, S, Ms]);
end;

function ParseUtcIso8601(const S: string; out DT: TDateTime): Boolean;
var
  Y, M, D, H, Mn, Sec, Ms: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(18);{$ENDIF}
  Result := False;
  DT := 0;
  { Accept YYYY-MM-DDTHH:MM:SS[.mmm][Z]. }
  if Length(S) < 19 then Exit;
  if not TryStrToInt(Copy(S,  1, 4), Y)   then Exit;
  if not TryStrToInt(Copy(S,  6, 2), M)   then Exit;
  if not TryStrToInt(Copy(S,  9, 2), D)   then Exit;
  if not TryStrToInt(Copy(S, 12, 2), H)   then Exit;
  if not TryStrToInt(Copy(S, 15, 2), Mn)  then Exit;
  if not TryStrToInt(Copy(S, 18, 2), Sec) then Exit;
  Ms := 0;
  if (Length(S) >= 23) and (S[20] = '.') then
    TryStrToInt(Copy(S, 21, 3), Ms);
  try
    DT := EncodeDateTime(Y, M, D, H, Mn, Sec, Ms);
    Result := True;
  except
    Result := False;
  end;
end;

function CacheMetadataToText(const M: TCacheMetadata): string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(19);{$ENDIF}
  Result :=
    'content_type=' + M.ContentType                + LineEnding +
    'etag='         + M.ETag                       + LineEnding +
    'fetched_at='   + FormatUtcIso8601(M.FetchedAt) + LineEnding +
    'size_bytes='   + IntToStr(M.SizeBytes)        + LineEnding;
end;

function TextToCacheMetadata(const Text: string; out M: TCacheMetadata): Boolean;
var
  Lines: TStringList;
  I, Eq: Integer;
  K, V: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(20);{$ENDIF}
  Result := False;
  M := TCacheMetadata.Empty;

  Lines := TStringList.Create;
  try
    Lines.Text := Text;
    for I := 0 to Lines.Count - 1 do
    begin
      Eq := Pos('=', Lines[I]);
      if Eq < 1 then Continue;
      K := Copy(Lines[I], 1, Eq - 1);
      V := Copy(Lines[I], Eq + 1, MaxInt);
      case K of
        'content_type': M.ContentType := V;
        'etag':         M.ETag := V;
        'fetched_at':   ParseUtcIso8601(V, M.FetchedAt);
        'size_bytes':   M.SizeBytes := StrToInt64Def(V, 0);
      end;
    end;
    Result := True;
  finally
    Lines.Free;
  end;
end;

{$IFDEF TILE_MEM_PROFILE}
function TMemoryCache.MemoryBytes: Int64;
begin
  FLock.Enter;
  try
    Result := FCurBytes;
  finally
    FLock.Leave;
  end;
end;
{$ENDIF}

constructor TMemoryCache.Create(MaxBytes: Int64);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1021);{$ENDIF}
  inherited Create;
  FEntries := TStringList.Create;
  FEntries.CaseSensitive := True;
  FEntries.Sorted := True;
  FEntries.Duplicates := dupError;
  FEntries.OwnsObjects := True;
  FMaxBytes := MaxBytes;
  if FMaxBytes < 0 then FMaxBytes := 0;
  FCurBytes := 0;
  FLock := TCriticalSection.Create;
  FLruHead := nil;
  FLruTail := nil;
  {$IFDEF TILE_MEM_PROFILE}
  MemProbeAdd(Self, 'mem-cache', mkRAM, @MemoryBytes);
  {$ENDIF}
end;

destructor TMemoryCache.Destroy;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1022);{$ENDIF}
  {$IFDEF TILE_MEM_PROFILE}MemProbeRemove(Self);{$ENDIF}
  FLock.Free;
  FEntries.Free;
  inherited;
end;

procedure TMemoryCache.LruUnlink(E: TMemoryCacheEntry);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(21);{$ENDIF}
  if E.LruPrev <> nil then E.LruPrev.LruNext := E.LruNext
  else FLruHead := E.LruNext;
  if E.LruNext <> nil then E.LruNext.LruPrev := E.LruPrev
  else FLruTail := E.LruPrev;
  E.LruPrev := nil;
  E.LruNext := nil;
end;

procedure TMemoryCache.LruPushFront(E: TMemoryCacheEntry);
begin
  E.LruPrev := nil;
  E.LruNext := FLruHead;
  if FLruHead <> nil then FLruHead.LruPrev := E;
  FLruHead := E;
  if FLruTail = nil then FLruTail := E;
end;

procedure TMemoryCache.RemoveAt(Index: Integer);
var
  E: TMemoryCacheEntry;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(21);{$ENDIF}
  E := TMemoryCacheEntry(FEntries.Objects[Index]);
  FCurBytes := FCurBytes - Length(E.Data);
  LruUnlink(E);
  FEntries.Delete(Index);
end;

procedure TMemoryCache.EvictUntilFits(NeededBytes: Int64);
{ LRU eviction: pop the COLD end of the intrusive LRU list until enough
  room. O(log n) per evicted entry (sorted-list index lookup by key)
  instead of the old full LastAccess rescan per eviction — O(n) each,
  O(n²) per burst. }
var
  E: TMemoryCacheEntry;
  Idx: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(22);{$ENDIF}
  while (FCurBytes + NeededBytes > FMaxBytes) and (FLruTail <> nil) do
  begin
    E := FLruTail;
    Idx := FEntries.IndexOf(E.Key);
    if Idx < 0 then
      LruUnlink(E)   { inconsistent state — just detach, never spin }
    else
      RemoveAt(Idx);
  end;
end;

function TMemoryCache.Has(const Key: string): Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(23);{$ENDIF}
  FLock.Enter;
  try
    Result := FEntries.IndexOf(Key) >= 0;
  finally
    FLock.Leave;
  end;
end;

function TMemoryCache.Get(const Key: string; out Data: TBytes;
                          out Meta: TCacheMetadata): Boolean;
var
  Idx: Integer;
  E: TMemoryCacheEntry;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(24);{$ENDIF}
  Result := False;
  Data := nil;
  Meta := TCacheMetadata.Empty;

  FLock.Enter;
  try
    Idx := FEntries.IndexOf(Key);
    if Idx < 0 then Exit;
    E := TMemoryCacheEntry(FEntries.Objects[Idx]);
    { Буфер отдаётся БЕЗ копии: TBytes — счётчик ссылок, данные переживут
      эвикт/обновление записи. Контракт кэша — буферы read-only (fetcher
      скармливает их декодерам и никогда не мутирует). }
    Data := E.Data;
    Meta := E.Meta;
    LruUnlink(E);
    LruPushFront(E);
    Result := True;
  finally
    FLock.Leave;
  end;
end;

procedure TMemoryCache.Put(const Key: string; const Data: TBytes;
                           const Meta: TCacheMetadata);
var
  Idx: Integer;
  E: TMemoryCacheEntry;
  NewSize: Int64;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(25);{$ENDIF}
  NewSize := Length(Data);

  FLock.Enter;
  try
    Idx := FEntries.IndexOf(Key);
    if NewSize > FMaxBytes then
    begin
      { Remove a previous value of this key, but keep unrelated hot entries. }
      if Idx >= 0 then RemoveAt(Idx);
      Exit;
    end;
    if Idx >= 0 then
    begin
      E := TMemoryCacheEntry(FEntries.Objects[Idx]);
      FCurBytes := FCurBytes - Length(E.Data);
      { Ссылка, не копия — контракт read-only (см. Get). }
      E.Data := Data;
      E.Meta := Meta;
      E.Meta.SizeBytes := NewSize;
      LruUnlink(E);
      LruPushFront(E);
      FCurBytes := FCurBytes + NewSize;
      EvictUntilFits(0);
      Exit;
    end;

    EvictUntilFits(NewSize);

    E := TMemoryCacheEntry.Create;
    E.Key  := Key;
    E.Data := Data;
    E.Meta := Meta;
    E.Meta.SizeBytes := NewSize;
    LruPushFront(E);
    FEntries.AddObject(Key, E);
    FCurBytes := FCurBytes + NewSize;
  finally
    FLock.Leave;
  end;
end;

procedure TMemoryCache.Delete(const Key: string);
var
  Idx: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(26);{$ENDIF}
  FLock.Enter;
  try
    Idx := FEntries.IndexOf(Key);
    if Idx < 0 then Exit;
    RemoveAt(Idx);
  finally
    FLock.Leave;
  end;
end;

function TMemoryCache.GetMetadata(const Key: string;
                                  out Meta: TCacheMetadata): Boolean;
var
  Idx: Integer;
  E: TMemoryCacheEntry;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(27);{$ENDIF}
  Result := False;
  Meta := TCacheMetadata.Empty;
  FLock.Enter;
  try
    Idx := FEntries.IndexOf(Key);
    if Idx < 0 then Exit;
    E := TMemoryCacheEntry(FEntries.Objects[Idx]);
    Meta := E.Meta;
    Result := True;
  finally
    FLock.Leave;
  end;
end;

procedure TMemoryCache.Purge;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(28);{$ENDIF}
  FLock.Enter;
  try
    FEntries.Clear;
    FCurBytes := 0;
    FLruHead := nil;
    FLruTail := nil;
  finally
    FLock.Leave;
  end;
end;

function TMemoryCache.Count: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(29);{$ENDIF}
  FLock.Enter;
  try
    Result := FEntries.Count;
  finally
    FLock.Leave;
  end;
end;

constructor TFileSystemCache.Create(const ARootDir: string);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1023);{$ENDIF}
  inherited Create;
  FRootDir := IncludeTrailingPathDelimiter(ARootDir);
  ForceDirectories(FRootDir);
end;

destructor TFileSystemCache.Destroy;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1024);{$ENDIF}
  inherited;
end;

function TFileSystemCache.HashKey(const Key: string): string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(31);{$ENDIF}
  Result := LowerCase(MDPrint(MDString(Key, MD_VERSION_5)));
end;

function TFileSystemCache.DataPath(const HashHex: string): string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(32);{$ENDIF}
  Result := FRootDir +
            Copy(HashHex, 1, 2) + PathDelim +
            Copy(HashHex, 3, MaxInt) + '.bin';
end;

function TFileSystemCache.MetaPath(const HashHex: string): string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(33);{$ENDIF}
  Result := FRootDir +
            Copy(HashHex, 1, 2) + PathDelim +
            Copy(HashHex, 3, MaxInt) + '.meta';
end;

function TFileSystemCache.EntryPath(const HashHex: string): string;
begin
  Result := ChangeFileExt(DataPath(HashHex), '.entry');
end;

procedure TFileSystemCache.EnsureDirFor(const FullPath: string);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(34);{$ENDIF}
  ForceDirectories(ExtractFilePath(FullPath));
end;

function TFileSystemCache.ReadAllBytes(const Path: string; out Data: TBytes): Boolean;
var
  FS: TFileStream;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(35);{$ENDIF}
  Result := False;
  Data := nil;
  if not FileExists(Path) then Exit;
  try
    FS := TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite);
    try
      SetLength(Data, FS.Size);
      if FS.Size > 0 then
        FS.ReadBuffer(Data[0], FS.Size);
      Result := True;
    finally
      FS.Free;
    end;
  except
    Result := False;
    Data := nil;
  end;
end;

function TFileSystemCache.ReadAllText(const Path: string; out Text: string): Boolean;
var
  SL: TStringList;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(36);{$ENDIF}
  Result := False;
  Text := '';
  if not FileExists(Path) then Exit;
  try
    SL := TStringList.Create;
    try
      SL.LoadFromFile(Path);
      Text := SL.Text;
      Result := True;
    finally
      SL.Free;
    end;
  except
    Result := False;
  end;
end;

{ One immutable record contains both metadata and bytes. Readers either see
  a complete old/new record or a cache miss; metadata cannot cross versions. }
function TFileSystemCache.ReadEntry(const Path: string; const LoadData: Boolean;
  out Data: TBytes; out Meta: TCacheMetadata): Boolean;
var
  Stream: TFileStream;
  Magic: array[0..7] of Char;
  MetaSize: Cardinal;
  DataSize: Int64;
  MetaText: string;
begin
  Result := False;
  Data := nil;
  Meta := TCacheMetadata.Empty;
  try
    Stream := TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite);
    try
      if Stream.Size < 20 then Exit;
      Stream.ReadBuffer(Magic, SizeOf(Magic));
      if (Magic <> 'RZCACHE1') then Exit;
      Stream.ReadBuffer(MetaSize, SizeOf(MetaSize));
      Stream.ReadBuffer(DataSize, SizeOf(DataSize));
      if (MetaSize > 1024 * 1024) or (DataSize < 0) or
         (DataSize > High(Integer)) then Exit;
      if Stream.Size - Stream.Position <> Int64(MetaSize) + DataSize then Exit;
      SetLength(MetaText, MetaSize);
      if MetaSize > 0 then Stream.ReadBuffer(MetaText[1], MetaSize);
      if not TextToCacheMetadata(MetaText, Meta) then Exit;
      Meta.SizeBytes := DataSize;
      if LoadData then
      begin
        SetLength(Data, DataSize);
        if DataSize > 0 then Stream.ReadBuffer(Data[0], DataSize);
      end;
      Result := True;
    finally
      Stream.Free;
    end;
  except
    Data := nil;
    Meta := TCacheMetadata.Empty;
  end;
end;

function TFileSystemCache.AtomicWriteEntry(const Path: string; const Data: TBytes;
  const Meta: TCacheMetadata): Boolean;
const
  Magic: array[0..7] of Char = ('R','Z','C','A','C','H','E','1');
var
  Tmp, MetaText: string;
  Stream: TFileStream;
  MetaSize: Cardinal;
  DataSize: Int64;
begin
  Result := False;
  MetaText := CacheMetadataToText(Meta);
  if Length(MetaText) > 1024 * 1024 then Exit;
  MetaSize := Length(MetaText);
  DataSize := Length(Data);
  if DataSize > High(Integer) then Exit;
  EnsureDirFor(Path);
  Tmp := Path + '.' + IntToStr(PtrInt(GetThreadID)) + '.tmp';
  try
    Stream := TFileStream.Create(Tmp, fmCreate);
    try
      Stream.WriteBuffer(Magic, SizeOf(Magic));
      Stream.WriteBuffer(MetaSize, SizeOf(MetaSize));
      Stream.WriteBuffer(DataSize, SizeOf(DataSize));
      if MetaSize > 0 then Stream.WriteBuffer(MetaText[1], MetaSize);
      if DataSize > 0 then Stream.WriteBuffer(Data[0], DataSize);
    finally
      Stream.Free;
    end;
    if FileExists(Path) and not SysUtils.DeleteFile(Path) then
      raise EWriteError.Create('Cannot replace cache entry');
    if not RenameFile(Tmp, Path) then
      raise EWriteError.Create('Cannot publish cache entry');
    Result := True;
  finally
    if FileExists(Tmp) then SysUtils.DeleteFile(Tmp);
  end;
end;

function TFileSystemCache.Has(const Key: string): Boolean;
var
  H: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(39);{$ENDIF}
  H := HashKey(Key);
  Result := FileExists(EntryPath(H)) or FileExists(DataPath(H));
end;

function TFileSystemCache.Get(const Key: string; out Data: TBytes;
                              out Meta: TCacheMetadata): Boolean;
var
  H, MetaText: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(40);{$ENDIF}
  Result := False;
  Data := nil;
  Meta := TCacheMetadata.Empty;
  H := HashKey(Key);

  if FileExists(EntryPath(H)) then
    Exit(ReadEntry(EntryPath(H), True, Data, Meta));
  if not ReadAllBytes(DataPath(H), Data) then Exit;
  if ReadAllText(MetaPath(H), MetaText) then
    TextToCacheMetadata(MetaText, Meta);
  Meta.SizeBytes := Length(Data);
  Result := True;
end;

procedure TFileSystemCache.Put(const Key: string; const Data: TBytes;
                               const Meta: TCacheMetadata);
var
  H: string;
  M: TCacheMetadata;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(41);{$ENDIF}
  H := HashKey(Key);
  M := Meta;
  M.SizeBytes := Length(Data);
  if M.FetchedAt = 0 then M.FetchedAt := Now;

  { Ошибка записи кэша не должна ронять фетч-воркер — проглатываем
    IO-исключения (диск занят/полон, гонка с Purge): промах самолечится
    следующим запросом. }
  try
    if AtomicWriteEntry(EntryPath(H), Data, M) then
    begin
      { Retire legacy files only after a complete replacement is published. }
      if FileExists(DataPath(H)) then SysUtils.DeleteFile(DataPath(H));
      if FileExists(MetaPath(H)) then SysUtils.DeleteFile(MetaPath(H));
    end;
  except
    { non-fatal by design }
  end;
end;

procedure TFileSystemCache.Delete(const Key: string);
var
  H: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(42);{$ENDIF}
  H := HashKey(Key);
  if FileExists(EntryPath(H)) then SysUtils.DeleteFile(EntryPath(H));
  if FileExists(DataPath(H)) then SysUtils.DeleteFile(DataPath(H));
  if FileExists(MetaPath(H)) then SysUtils.DeleteFile(MetaPath(H));
end;

function TFileSystemCache.GetMetadata(const Key: string;
                                      out Meta: TCacheMetadata): Boolean;
var
  H, MetaText: string;
  Data: TBytes;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(43);{$ENDIF}
  Result := False;
  Meta := TCacheMetadata.Empty;
  H := HashKey(Key);
  if FileExists(EntryPath(H)) then
    Exit(ReadEntry(EntryPath(H), False, Data, Meta));
  if not FileExists(DataPath(H)) then Exit;
  if ReadAllText(MetaPath(H), MetaText) then
    TextToCacheMetadata(MetaText, Meta);
  Result := True;
end;

procedure TFileSystemCache.Purge;

  { Collect entries first, then delete: safe against concurrent modification. }
  procedure RemoveContents(const Dir: string);
  var
    Files: TSearchRec;
    ToFiles, ToDirs: TStringList;
    I: Integer;
    Path: string;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(45);{$ENDIF}
    ToFiles := TStringList.Create;
    ToDirs  := TStringList.Create;
    try
      if FindFirst(Dir + '*', faAnyFile, Files) = 0 then
      try
        repeat
          if (Files.Name = '.') or (Files.Name = '..') then Continue;
          Path := Dir + Files.Name;
          if (Files.Attr and faDirectory) <> 0 then
            ToDirs.Add(Path)
          else
            ToFiles.Add(Path);
        until FindNext(Files) <> 0;
      finally
        FindClose(Files);
      end;

      for I := 0 to ToFiles.Count - 1 do
        SysUtils.DeleteFile(ToFiles[I]);
      for I := 0 to ToDirs.Count - 1 do
      begin
        RemoveContents(IncludeTrailingPathDelimiter(ToDirs[I]));
        RemoveDir(ToDirs[I]);
      end;
    finally
      ToFiles.Free;
      ToDirs.Free;
    end;
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(44);{$ENDIF}
  RemoveContents(FRootDir);
end;

constructor TCompositeCache.Create(const ALayers: array of TCacheBase;
                                   AOwnsLayers: Boolean);
var
  I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1025);{$ENDIF}
  inherited Create;
  SetLength(FLayers, Length(ALayers));
  for I := 0 to High(ALayers) do
    FLayers[I] := ALayers[I];
  FOwnsLayers := AOwnsLayers;
end;

destructor TCompositeCache.Destroy;
var
  I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1026);{$ENDIF}
  if FOwnsLayers then
    for I := 0 to High(FLayers) do
      FreeAndNil(FLayers[I]);
  SetLength(FLayers, 0);
  inherited;
end;

function TCompositeCache.Has(const Key: string): Boolean;
var
  I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(46);{$ENDIF}
  for I := 0 to High(FLayers) do
    if FLayers[I].Has(Key) then Exit(True);
  Result := False;
end;

function TCompositeCache.Get(const Key: string; out Data: TBytes;
                             out Meta: TCacheMetadata): Boolean;
var
  I, J: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(47);{$ENDIF}
  Result := False;
  Data := nil;
  Meta := TCacheMetadata.Empty;

  for I := 0 to High(FLayers) do
  begin
    if FLayers[I].Get(Key, Data, Meta) then
    begin
      { Hit promotion: write back into all hotter layers. }
      for J := 0 to I - 1 do
        FLayers[J].Put(Key, Data, Meta);
      Exit(True);
    end;
  end;
end;

procedure TCompositeCache.Put(const Key: string; const Data: TBytes;
                              const Meta: TCacheMetadata);
var
  I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(48);{$ENDIF}
  for I := 0 to High(FLayers) do
    FLayers[I].Put(Key, Data, Meta);
end;

procedure TCompositeCache.Delete(const Key: string);
var
  I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(49);{$ENDIF}
  for I := 0 to High(FLayers) do
    FLayers[I].Delete(Key);
end;

function TCompositeCache.GetMetadata(const Key: string;
                                     out Meta: TCacheMetadata): Boolean;
var
  I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(50);{$ENDIF}
  Result := False;
  Meta := TCacheMetadata.Empty;
  for I := 0 to High(FLayers) do
    if FLayers[I].GetMetadata(Key, Meta) then Exit(True);
end;

procedure TCompositeCache.Purge;
var
  I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(51);{$ENDIF}
  for I := 0 to High(FLayers) do
    FLayers[I].Purge;
end;

end.
