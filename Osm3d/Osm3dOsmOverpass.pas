unit Osm3dOsmOverpass;

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$codepage UTF8}
{$WARN 5091 OFF}
{$modeswitch advancedrecords}

interface

uses
  Classes,
  SysUtils,
  Osm3dGeoMath,
  Osm3dCacheHTTPFetcher,
  Osm3dOsmDirectory,
  Osm3dOsmData,
  Osm3dOsmTagUtils,   { InvariantFmt }
  Osm3dStudioLog,
  SyncObjs,
  Generics.Collections
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
;

const
  OVERPASS_ENDPOINT_DEFAULT = 'https://overpass-api.de/api/interpreter';

  OVERPASS_ENDPOINTS_DEFAULT = OSM_DIRECTORY_MODE;

  OVERPASS_TIMEOUT_DEFAULT   = 60;
  OVERPASS_TILE_ZOOM_DEFAULT = 14;

  OVERPASS_CACHE_PREFIX = 'overpass:';

  UNHEALTHY_THRESHOLD = 3;
  HEALTH_COOLDOWN_SEC = 60;

type
  TOverpassTileEvent = procedure(Sender: TObject; const Tile: TTileXY;
    TileIndex, TileTotal: Integer; Success: Boolean;
    BytesGot: Integer; ElapsedMs: Int64;
    const UsedEndpoint, ErrorMsg: string;
    var Cancel: Boolean) of object;

  { Internal LRU brick — one tile's parsed OSM fragment + bookkeeping. }
  TOverpassFragEntry = class
  public
    Ds:  TOSMDataset;  { owned by this entry; the full-scene fragment of one tile }
    Pin: Integer;      { >0 while an in-flight GetRegion references it }
    Seq: Int64;        { last-touch order for LRU }
    destructor Destroy; override;
  end;

  TOverpassClient = class
  private
    FFetcher:    THTTPFetcherWithCache;
    FEndpoints:  TStringList;
    FHealthFails: array of Integer;
    FHealthSince: array of TDateTime;
    FTimeoutS:   Integer;
    FTileZoom:   Integer;
    FOnTile:     TOverpassTileEvent;
    FPrevValidator:  TResponseValidator;
    FPrevMaxRetries: Integer;
    FLog:            TLogTarget;

    { parsed-fragment cache (shared across blocks/previews) }
    FCacheLock:  TCriticalSection;
    FFrags:      specialize TObjectDictionary<string, TOverpassFragEntry>;
    FLoading:    specialize TDictionary<string, Boolean>;
    FMaxFrags:   Integer;
    FSeq:        Int64;

    function  FragKey(const ATile: TTileXY): string;
    { Cached fragment (pinned) or fetch+parse-once (coalesced). nil only on
      failure. Caller must ReleaseFrag afterwards. }
    function  AcquireFrag(const ATile: TTileXY): TOSMDataset;
    procedure ReleaseFrag(const ATile: TTileXY);
    procedure EvictFragsLocked;
    { deep copy — cached fragments are read-only and must never be handed
      out; GetRegion clones their elements into the fresh result. }
    procedure DeepMergeInto(ADst, ASrc: TOSMDataset);
    procedure ParseEndpointList(const ASource: string);
    procedure ResetHealthArrays;

    function  IsEndpointHealthy(Idx: Integer): Boolean;

    function  StartingEndpointIdx(const T: TTileXY): Integer;
    function  EndpointAt(Idx: Integer): string;

    function ValidateOverpassResponse(Sender: TObject;
      const URL: string; const Bytes: TBytes;
      const ContentType: string): string;

    function FetchOnEndpoint(const Endpoint, Query: string;
      out Bytes: TBytes; out ElapsedMs: Int64;
      out ErrMsg: string): Boolean;

    function FetchWithFallback(StartIdx: Integer; const Query: string;
      out Bytes: TBytes; out ElapsedMs: Int64;
      out UsedEndpoint, ErrMsg: string): Boolean;
  public
    constructor Create(AFetcher: THTTPFetcherWithCache;
      const AEndpointList: string = ''; AMaxFrags: Integer = 256);
    destructor  Destroy; override;

    function FetchAllTilesInto(const Box: TLatLonBox;
      Dataset: TOSMDataset;
      AIncludeBuildings, AIncludeHighways, AIncludeTrees,
      AIncludeLanduse, AIncludeWaterways: Boolean): Integer;

    { Fetch + parse ONE Overpass tile into Dataset (accumulating) — the per-tile work of
      FetchAllTilesInto's loop, exposed so a tile-level cache can dedupe overlapping halo boxes.
      True if bytes were parsed. Fires OnTileProgress once (1/1). }
    function FetchTileInto(const ATile: TTileXY; Dataset: TOSMDataset): Boolean;

    { Fresh dataset for a region, deep-merged from the shared per-tile parsed fragments covering
      ABox at FTileZoom. Caller owns and frees it. Missing/failed tiles are skipped — the result is
      PARTIAL by design (a corner with no OSM is acceptable). Always full-scene per tile (query
      ignores feature flags) so the cache key is z/x/y and fragments are reused by any block. }
    function GetRegion(const ABox: TLatLonBox): TOSMDataset;

    property Fetcher:        THTTPFetcherWithCache read FFetcher;
    property Endpoints:      TStringList           read FEndpoints;
    property TimeoutS:       Integer               read FTimeoutS  write FTimeoutS;
    property TileZoom:       Integer               read FTileZoom  write FTileZoom;
    property OnTileProgress: TOverpassTileEvent    read FOnTile    write FOnTile;

    property Log:            TLogTarget            read FLog       write FLog;
  end;

function OverpassCacheKey(const Body: string): string;

function OverpassFetchOnEndpoint(Fetcher: THTTPFetcherWithCache;
  const Endpoint, Query: string;
  out Bytes: TBytes; out ElapsedMs: Int64; out ErrMsg: string;
  ConnectTimeoutLimitMs: Integer = 0): Boolean;

type
  TOverpassQueryFlags = record
    IncludeBuildings:     Boolean;     { way[building], relation[building] }
    IncludeHighways:      Boolean;     { way[highway] }
    IncludeTrees:         Boolean;     { node[natural=tree] }
    IncludeLanduse:       Boolean;     { way[landuse], way[natural] }
    IncludeWaterways:     Boolean;     { way[waterway], way[natural=water] }

    IncludeLeisure:       Boolean;     { stadium, park, pitch, garden }
    IncludeHistoric:      Boolean;     { monument, memorial, archaeological }
    IncludeTourism:       Boolean;     { artwork, attraction, viewpoint, info }
    IncludeAmenity:       Boolean;     { fountain, bench, place_of_worship, ... }
    IncludePOINodes:      Boolean;     { node shop/office/craft/healthcare/leisure — именованные POI на зданиях (для POI-табличек) }
    IncludeManMade:       Boolean;     { tower, mast, lighthouse, water_tower }
    IncludeEmergency:     Boolean;     { fire_hydrant }
    IncludePublicTransport: Boolean;   { platform, station, stop_position }
    IncludeBusStops:      Boolean;     { node[highway=bus_stop] }
    IncludeRailway:       Boolean;     { rail, tram, subway, narrow_gauge }
    IncludeBarriers:      Boolean;     { fence, wall, hedge, retaining_wall }
    IncludePower:         Boolean;     { way[power=line], node[power=tower] }
    IncludePlaces:        Boolean;     { way[place], node[place] — НП для въездных табличек }
  end;

{ All flags True — recommended default for production. }
function DefaultFlagsForFullScene: TOverpassQueryFlags;

type
  TOverpassQueryExt = class
  public
    { bbox in Overpass syntax: south,west,north,east. }
    class function FormatBboxArg(const Box: TLatLonBox): string;

    { Full extended combined query. Recurse-down (.data >) pulls all
      nested nodes/ways/relations for multipolygons and way references.
      Structure:
        [bbox:...][out:json][timeout:N];
        ( <filters per flags> )->.data;
        .data > ->.dataMembers;
        (.data; .dataMembers;)->.all;
        .all out body qt; }
    class function BuildCombinedFull(const Box: TLatLonBox;
      const Flags: TOverpassQueryFlags;
      ATimeoutS: Integer = OVERPASS_TIMEOUT_DEFAULT): string;

    { Convenience: 5 basic bool flags, rest from DefaultFlagsForFullScene.
      Used by TParallelOverpassRunner.BuildQueryForTile. }
    class function BuildFromBasicFlags(const Box: TLatLonBox;
      AIncludeBuildings, AIncludeHighways, AIncludeTrees,
      AIncludeLanduse, AIncludeWaterways: Boolean;
      ATimeoutS: Integer = OVERPASS_TIMEOUT_DEFAULT): string;
  end;

type
  PTileTask = ^TTileTask;
  TTileTask = record
    Tile:     TTileXY;
    Index:    Integer;
    SkipMask: LongWord;
  end;

  PTileResult = ^TTileResult;
  TTileResult = record
    Tile:      TTileXY;
    Index:     Integer;
    Total:     Integer;
    Success:   Boolean;
    Bytes:     TBytes;
    BytesLen:  Integer;
    ElapsedMs: Int64;
    Endpoint:  string;
    ErrMsg:    string;
    WorkerIdx: Integer;
  end;

  PTileAttempt = ^TTileAttempt;
  TTileAttempt = record
    Tile:      TTileXY;
    Index:     Integer;
    Total:     Integer;
    Success:   Boolean;
    BytesLen:  Integer;
    ElapsedMs: Int64;
    Endpoint:  string;
    ErrMsg:    string;
    WorkerIdx: Integer;
  end;

  TTileWorkQueue = class
  private
    FLock:     TCriticalSection;
    FNotEmpty: TEvent;
    FAllDone:  TEvent;
    FItems:    TList;
    FInFlight: Integer;
    FTotal:    Integer;
    FCanceled: Boolean;
    FClosed:   Boolean;
    procedure CheckAllDoneLocked;
  public
    constructor Create;
    destructor  Destroy; override;
    procedure StartBatch(ATotal: Integer);
    procedure CloseInput;
    procedure Push(ATask: PTileTask);
    function  Take(WorkerBit: LongWord): PTileTask;
    procedure TaskDone(ATask: PTileTask; Success: Boolean;
                       WorkerBit, AllWorkersMask: LongWord;
                       out FinallyClosed: Boolean);
    procedure Cancel;
    function  WaitAllDone(TimeoutMs: Cardinal = INFINITE): Boolean;
    property  Total: Integer read FTotal;
  end;

  TBuildQueryProc = function(const T: TTileXY): string of object;

  TOverpassAttemptEvent = procedure(Sender: TObject;
    WorkerIdx: Integer; const Endpoint: string;
    const Tile: TTileXY; TileIndex, TileTotal: Integer;
    Success: Boolean; BytesGot: Integer; ElapsedMs: Int64;
    const ErrorMsg: string) of object;

  TOverpassWorker = class(TThread)
  private
    FQueue:      TTileWorkQueue;
    FFetcher:    THTTPFetcherWithCache;
    FEndpoint:   string;
    FResolvedEndpoint: string;
    FBit:        LongWord;
    FAllMask:    LongWord;
    FWorkerIdx:  Integer;
    FBuildQuery: TBuildQueryProc;
    FOwner:      TObject;
    FLog:        TLogTarget;
    function DoFetch(const Tile: TTileXY;
                     out Bytes: TBytes; out ElapsedMs: Int64;
                     out ErrMsg: string): Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(AQueue: TTileWorkQueue;
                       AFetcher: THTTPFetcherWithCache;
                       const AEndpoint: string;
                       ABit, AAllMask: LongWord;
                       AWorkerIdx: Integer;
                       ABuildQuery: TBuildQueryProc;
                       AOwner: TObject;
                       ALog: TLogTarget);
  end;

  TParallelOverpassRunner = class(TLogOwner)
  private
    FFetcher:  THTTPFetcherWithCache;
    FOverpass: TOverpassClient;     { reused for BuildCombined + validator }
    FQueue:    TTileWorkQueue;
    FWorkers:  array of TOverpassWorker;
    FOnTile:   TOverpassTileEvent;
    FOnAttempt: TOverpassAttemptEvent;
    FDataset:  TOSMDataset;
    FOkCount:  Integer;

    FResultLock:    TCriticalSection;
    FResultEvent:   TEvent;
    FPendResults:   TList;            { PTileResult, owned by queue }
    FPendAttempts:  TList;            { PTileAttempt, owned by queue }

    FInclBuildings, FInclHighways, FInclTrees,
    FInclLanduse,   FInclWaterways: Boolean;

    function  BuildQueryForTile(const T: TTileXY): string;

    procedure DrainResults;
    procedure FreeOrphanedItems;
  public
    constructor Create(AFetcher: THTTPFetcherWithCache;
                       AOverpass: TOverpassClient;
                       ALog: TLogTarget = nil);
    destructor  Destroy; override;

    function FetchAllTilesParallelInto(const Box: TLatLonBox;
      Dataset: TOSMDataset;
      AIncludeBuildings, AIncludeHighways, AIncludeTrees,
      AIncludeLanduse, AIncludeWaterways: Boolean): Integer;

    procedure Cancel;

    procedure PostResultFromWorker(R: PTileResult);
    procedure PostAttemptFromWorker(A: PTileAttempt);

    property OnTileProgress: TOverpassTileEvent read FOnTile write FOnTile;
    property OnAttempt: TOverpassAttemptEvent read FOnAttempt write FOnAttempt;
  end;

implementation

uses
  StrUtils, Osm3dGenerationProgress,
  MD5;

threadvar
  GResolvedOverpassEndpoint: string;

{ Inspect the JSON envelope without constructing a second, potentially huge,
  JSON tree. An Overpass runtime error can be HTTP 200 with partial elements. }
function OverpassEnvelopeError(const Bytes: TBytes): string;
var I,J,Depth: Integer; Quoted,Escaped,Elements: Boolean; Token: string; C: Char;
begin
  Result:='Invalid or incomplete Overpass JSON';Depth:=0;Quoted:=False;
  Escaped:=False;Elements:=False;Token:='';
  for I:=0 to High(Bytes) do begin
    C:=Char(Bytes[I]);
    if Quoted then begin
      if Escaped then begin Escaped:=False;Continue;end;
      if C='\' then begin Escaped:=True;Continue;end;
      if C='"' then Quoted:=False
      else if (Depth=1) and (Length(Token)<32) then Token:=Token+C;
      Continue;
    end;
    case C of
      '"': begin Quoted:=True;Token:='';end;
      '{','[': begin Inc(Depth);Token:='';end;
      '}',']': begin Dec(Depth);if Depth<0 then Exit;Token:='';end;
      ',': Token:='';
      ':': if Depth=1 then begin
        J:=I+1;while (J<Length(Bytes)) and (Bytes[J]<=32) do Inc(J);
        if Token='elements' then Elements:=(J<Length(Bytes)) and (Bytes[J]=Ord('['));
        if (Token='remark') or (Token='error') then
          if (J+1>=Length(Bytes)) or (Bytes[J]<>Ord('"')) or (Bytes[J+1]<>Ord('"')) then
            Exit('Overpass returned a runtime error or incomplete result');
        Token:='';
      end;
    end;
  end;
  if Elements and not Quoted and (Depth=0) then Result:='';
end;

function OverpassCacheKey(const Body: string): string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(614);{$ENDIF}
  Result := OVERPASS_CACHE_PREFIX +
            LowerCase(MDPrint(MDString(Body, MD_VERSION_5)));
end;

function OverpassFetchOnEndpoint(Fetcher: THTTPFetcherWithCache;
  const Endpoint, Query: string;
  out Bytes: TBytes; out ElapsedMs: Int64; out ErrMsg: string;
  ConnectTimeoutLimitMs: Integer): Boolean;
var
  R: TFetchResult;
  T0: TDateTime;
  Candidates: TStringArray;
  I: Integer;
  AttemptMs: Int64;
  Lease:string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(615);{$ENDIF}
  Bytes     := nil;
  ElapsedMs := 0;
  ErrMsg    := '';
  Result    := False;

  if Fetcher = nil then
  begin
    ErrMsg := 'OverpassFetchOnEndpoint: fetcher = nil';
    Exit;
  end;

  T0 := Now;
  GResolvedOverpassEndpoint := Endpoint;
  if SameText(Trim(Endpoint), OSM_DIRECTORY_MODE) then
  begin
    { Cached map data must not trigger directory or reachability requests. }
    R := Fetcher.GetCachedByKey(OVERPASS_ENDPOINT_DEFAULT, OverpassCacheKey(Query));
    if R.Success and (OverpassEnvelopeError(R.Data) = '') then
    begin
      Bytes := R.Data;
      GResolvedOverpassEndpoint := 'cache';
      Exit(True);
    end;
    if R.Success and (Fetcher.Cache <> nil) then Fetcher.Cache.Delete(OverpassCacheKey(Query));
    if Fetcher.Aborted then begin ErrMsg := 'aborted'; Exit; end;
    Candidates := OsmServerCandidates(Query);
    ErrMsg := 'No reachable OSM servers';
    for I := 0 to High(Candidates) do
    begin
      if Fetcher.Aborted then begin ErrMsg := 'aborted'; Break; end;
      if not OsmEndpointCanTry(Candidates[I]) then Continue;
      Result := OverpassFetchOnEndpoint(Fetcher, Candidates[I], Query, Bytes, AttemptMs, ErrMsg, 3000);
      if not Fetcher.Aborted then OsmEndpointResult(Candidates[I], Result);
      if Result then Break;
    end;
    ElapsedMs := Round((Now-T0)*86400000);
    Exit;
  end;
  { Manual endpoints use the same cache-first path and process-wide budgets
    as automatic routing. Waiting must not hold a shared lock. }
  R:=Fetcher.GetCachedByKey(Endpoint,OverpassCacheKey(Query));
  if R.Success and(OverpassEnvelopeError(R.Data)='')then begin Bytes:=R.Data;Exit(True);end;
  if R.Success and(Fetcher.Cache<>nil)then Fetcher.Cache.Delete(OverpassCacheKey(Query));
  if Fetcher.Aborted then begin ErrMsg:='aborted';Exit;end;
  while not OsmTryAcquireRequest(Endpoint,Lease)do begin
    if Fetcher.Aborted then begin ErrMsg:='aborted';Exit;end;
    Sleep(10);
  end;
  try
    try
      if Fetcher.Aborted then begin ErrMsg:='aborted';Exit;end;
      R := Fetcher.PostString(Endpoint, Query,
                              'text/plain; charset=utf-8',
                              OverpassCacheKey(Query), ConnectTimeoutLimitMs, 1);
    except
      on E: Exception do
      begin
        ErrMsg    := E.ClassName + ': ' + E.Message;
        ElapsedMs := Round((Now - T0) * 86400 * 1000);
        Exit;
      end;
    end;
  finally OsmReleaseRequest(Lease);end;
  ElapsedMs := Round((Now - T0) * 86400 * 1000);

  if R.Success then
  begin
    ErrMsg := OverpassEnvelopeError(R.Data);
    if ErrMsg <> '' then
    begin
      if Fetcher.Cache <> nil then Fetcher.Cache.Delete(OverpassCacheKey(Query));
      Exit(False);
    end;
    Bytes  := R.Data;
    Result := True;
    Exit;
  end;

  ErrMsg := R.ErrorMsg;
end;

constructor TOverpassClient.Create(AFetcher: THTTPFetcherWithCache;
  const AEndpointList: string; AMaxFrags: Integer);
var
  Src: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1213);{$ENDIF}
  inherited Create;
  FFetcher  := AFetcher;
  FTimeoutS := OVERPASS_TIMEOUT_DEFAULT;
  FTileZoom := OVERPASS_TILE_ZOOM_DEFAULT;
  FEndpoints := TStringList.Create;

  if AMaxFrags < 4 then AMaxFrags := 4;
  FMaxFrags  := AMaxFrags;
  FCacheLock := TCriticalSection.Create;
  FFrags     := specialize TObjectDictionary<string, TOverpassFragEntry>.Create([doOwnsValues]);
  FLoading   := specialize TDictionary<string, Boolean>.Create;
  FSeq       := 0;

  Src := AEndpointList;
  if Trim(Src) = '' then
    Src := OVERPASS_ENDPOINTS_DEFAULT;
  ParseEndpointList(Src);

  if FEndpoints.Count = 0 then
    FEndpoints.Add(OVERPASS_ENDPOINT_DEFAULT);

  ResetHealthArrays;

  if FFetcher <> nil then
  begin
    { фетчер ОБЩИЙ: save/mutate/restore его настроек — под процессным
      замком мутаторов (Osm3dCacheHTTPFetcher), иначе два клиента
      переписывают валидатор/ретраи друг друга }
    EnterFetcherConfig;
    try
      FPrevValidator := FFetcher.OnValidateResponse;
      FFetcher.OnValidateResponse := @ValidateOverpassResponse;

      FPrevMaxRetries := FFetcher.MaxRetries;
      FFetcher.MaxRetries := 1;
    finally
      LeaveFetcherConfig;
    end;
  end;
end;

destructor TOverpassClient.Destroy;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1214);{$ENDIF}
  if FFetcher <> nil then
  begin
    EnterFetcherConfig;
    try
      FFetcher.OnValidateResponse := FPrevValidator;
      FFetcher.MaxRetries         := FPrevMaxRetries;
    finally
      LeaveFetcherConfig;
    end;
    { ссылку обнуляем: фетчер нам не принадлежит, повторная запись в него
      (при любом порядке teardown после этого деструктора) недопустима }
    FFetcher := nil;
  end;
  FreeAndNil(FFrags);        { frees every entry and its TOSMDataset }
  FreeAndNil(FLoading);
  FreeAndNil(FCacheLock);
  FreeAndNil(FEndpoints);
  inherited;
end;

procedure TOverpassClient.ParseEndpointList(const ASource: string);
var
  Parts: TStringArray;
  S: string;
  I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(616);{$ENDIF}
  FEndpoints.Clear;
  Parts := ASource.Split([';', #10, #13], TStringSplitOptions.ExcludeEmpty);
  for I := 0 to High(Parts) do
  begin
    S := Trim(Parts[I]);
    if S <> '' then
      FEndpoints.Add(S);
  end;
end;

procedure TOverpassClient.ResetHealthArrays;
var I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(617);{$ENDIF}
  SetLength(FHealthFails, FEndpoints.Count);
  SetLength(FHealthSince, FEndpoints.Count);
  for I := 0 to FEndpoints.Count - 1 do
  begin
    FHealthFails[I] := 0;
    FHealthSince[I] := 0;
  end;
end;

function TOverpassClient.IsEndpointHealthy(Idx: Integer): Boolean;
var
  AgeSec: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(618);{$ENDIF}
  if (Idx < 0) or (Idx >= Length(FHealthFails)) then
    Exit(True);

  if FHealthFails[Idx] < UNHEALTHY_THRESHOLD then
    Exit(True);

  AgeSec := (Now - FHealthSince[Idx]) * 86400;
  if AgeSec > HEALTH_COOLDOWN_SEC then
  begin
    FHealthFails[Idx] := 0;
    Exit(True);
  end;

  Result := False;
end;

{$PUSH}{$WARN 5024 OFF}  // Sender/URL/ContentType required by callback contract
function TOverpassClient.ValidateOverpassResponse(Sender: TObject;
  const URL: string; const Bytes: TBytes;
  const ContentType: string): string;

  function PeekStart(Max: Integer): string;
  var L: Integer;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(620);{$ENDIF}
    L := Length(Bytes);
    if L > Max then L := Max;
    if L = 0 then begin Result := ''; Exit; end;
    SetLength(Result, L);
    Move(Bytes[0], Result[1], L);
  end;

  function LooksLikeHtml(const Head: string): Boolean;
  var T: string;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(621);{$ENDIF}
    T := LowerCase(TrimLeft(Head));
    Result := (Pos('<?xml',     T) = 1) or
              (Pos('<!doctype', T) = 1) or
              (Pos('<html',     T) = 1);
  end;

  function ExtractHtmlErrorText: string;
  var
    Full, Marker: string;
    P, P2: Integer;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(622);{$ENDIF}
    Result := '';
    SetLength(Full, Length(Bytes));
    if Length(Bytes) > 0 then
      Move(Bytes[0], Full[1], Length(Bytes));

    Marker := 'Error</strong>';
    P := Pos(Marker, Full);
    if P = 0 then Exit;
    P := P + Length(Marker);

    while (P <= Length(Full)) and
          ((Full[P] = ':') or (Full[P] = ' ') or (Full[P] = #9) or
           (Full[P] = #10) or (Full[P] = #13)) do
      Inc(P);

    P2 := PosEx('<', Full, P);
    if P2 = 0 then P2 := Length(Full) + 1;
    Result := Trim(Copy(Full, P, P2 - P));

    Result := StringReplace(Result, #13#10, ' ', [rfReplaceAll]);
    Result := StringReplace(Result, #10, ' ', [rfReplaceAll]);
    Result := StringReplace(Result, #9,  ' ', [rfReplaceAll]);
    while Pos('  ', Result) > 0 do
      Result := StringReplace(Result, '  ', ' ', [rfReplaceAll]);
  end;

  function IsTruncatedJson: Boolean;
  var I: Integer;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(623);{$ENDIF}
    Result := True;
    if Length(Bytes) = 0 then Exit;
    I := Length(Bytes) - 1;
    while (I >= 0) and
          ((Bytes[I] = Byte(' ')) or (Bytes[I] = Byte(#9)) or
           (Bytes[I] = Byte(#10)) or (Bytes[I] = Byte(#13))) do
      Dec(I);
    if I < 0 then Exit;
    Result := Bytes[I] <> Byte('}');
  end;

var
  Head, Msg: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(619);{$ENDIF}
  Result := '';

  { CRITICAL: this validator sits on a SHARED fetcher (OnValidateResponse is one global property),
    so terrarium heightmap PNGs fetched concurrently pass through here too. Without a JSON gate
    IsTruncatedJson rejects every PNG ("no closing brace") and FetchInternal DELETES the cached tile
    (cache-thrash). So gate strictly on JSON — a non-JSON body (PNG etc.) is accepted unconditionally. }
  if (ContentType <> '') and
     (Pos('json', LowerCase(ContentType)) = 0) and
     (Pos('text', LowerCase(ContentType)) = 0) then
    Exit;                       { declared non-JSON (e.g. image/png) — not ours }

  if Length(Bytes) = 0 then
  begin
    Result := 'Overpass returned empty body';
    Exit;
  end;

  { Content-type missing/ambiguous → sniff the first non-whitespace byte.
    Overpass JSON starts with a curly-brace open (or a square-bracket open on
    some servers); anything else (PNG magic 0x89, etc.) is not Overpass JSON,
    so leave it alone. }
  if ContentType = '' then
  begin
    Head := PeekStart(8);
    Msg  := TrimLeft(Head);
    if (Msg = '') or ((Msg[1] <> '{') and (Msg[1] <> '[') and
                      (Msg[1] <> '<')) then   { '<' kept so HTML errors below still fire }
      Exit;
  end;

  Head := PeekStart(64);
  if LooksLikeHtml(Head) then
  begin
    Msg := ExtractHtmlErrorText;
    if Msg = '' then
      Result := 'Overpass returned HTML page (server busy?)'
    else
      Result := 'Overpass HTML error: ' + Msg;
    Exit;
  end;

  if IsTruncatedJson then
  begin
    Result := Format(
      'Overpass JSON truncated (got %d bytes, no closing brace)',
      [Length(Bytes)]);
    Exit;
  end;
end;
{$POP}

{ Deterministic per-tile mirror choice: same tile starts on the same
  mirror across runs, preserving cache stability (cache key = URL+body).
  Mixed finalizer prevents diagonal tile rows from collapsing into too
  few buckets when modulo a small endpoint count. }
function TOverpassClient.StartingEndpointIdx(const T: TTileXY): Integer;
var
  H: LongWord;
  Hashed, Tried, Idx: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(624);{$ENDIF}
  if FEndpoints.Count <= 1 then Exit(0);
  H := LongWord(T.X) * 73856093 + LongWord(T.Y) * 19349663;
  H := (H xor (H shr 16)) * $85EBCA6B;
  H := H xor (H shr 13);
  H := H * $C2B2AE35;
  H := H xor (H shr 16);
  Hashed := Integer(H mod LongWord(FEndpoints.Count));

  for Tried := 0 to FEndpoints.Count - 1 do
  begin
    Idx := (Hashed + Tried) mod FEndpoints.Count;
    if IsEndpointHealthy(Idx) then
      Exit(Idx);
  end;

  Result := Hashed;
end;

function TOverpassClient.EndpointAt(Idx: Integer): string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(625);{$ENDIF}
  if FEndpoints.Count = 0 then
    Result := OVERPASS_ENDPOINT_DEFAULT
  else
    Result := FEndpoints[Idx mod FEndpoints.Count];
end;

function TOverpassClient.FetchOnEndpoint(const Endpoint, Query: string;
  out Bytes: TBytes; out ElapsedMs: Int64; out ErrMsg: string): Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(626);{$ENDIF}
  Result := OverpassFetchOnEndpoint(FFetcher, Endpoint, Query,
                                    Bytes, ElapsedMs, ErrMsg);
end;

function TOverpassClient.FetchWithFallback(StartIdx: Integer;
  const Query: string;
  out Bytes: TBytes; out ElapsedMs: Int64;
  out UsedEndpoint, ErrMsg: string): Boolean;
var
  Try_, N: Integer;
  Idx: Integer;
  AttemptElapsed: Int64;
  AttemptErr: string;
  AttemptBytes: TBytes;
  TotalElapsed: Int64;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(627);{$ENDIF}
  Bytes        := nil;
  ElapsedMs    := 0;
  UsedEndpoint := '';
  ErrMsg       := '';
  Result       := False;

  N := FEndpoints.Count;
  if N = 0 then
  begin
    ErrMsg := 'no endpoints configured';
    Exit;
  end;

  TotalElapsed := 0;
  for Try_ := 0 to N - 1 do
  begin
    Idx := (StartIdx + Try_) mod N;
    UsedEndpoint := EndpointAt(Idx);

    if FetchOnEndpoint(UsedEndpoint, Query,
                       AttemptBytes, AttemptElapsed, AttemptErr) then
    begin
      if SameText(UsedEndpoint, OSM_DIRECTORY_MODE) then UsedEndpoint := GResolvedOverpassEndpoint;
      if (Idx >= 0) and (Idx < Length(FHealthFails)) then
        FHealthFails[Idx] := 0;

      Bytes     := AttemptBytes;
      ElapsedMs := TotalElapsed + AttemptElapsed;
      ErrMsg    := '';
      Exit(True);
    end;

    if (Idx >= 0) and (Idx < Length(FHealthFails)) then
    begin
      Inc(FHealthFails[Idx]);
      FHealthSince[Idx] := Now;
    end;

    TotalElapsed := TotalElapsed + AttemptElapsed;
    ErrMsg := AttemptErr;
  end;

  ElapsedMs := TotalElapsed;
end;

function TOverpassClient.FetchAllTilesInto(const Box: TLatLonBox;
  Dataset: TOSMDataset;
  AIncludeBuildings, AIncludeHighways, AIncludeTrees,
  AIncludeLanduse, AIncludeWaterways: Boolean): Integer;
var
  Tiles: TTileXYArray;
  I, OkCount: Integer;
  TileBox: TLatLonBox;
  Query: string;
  Bytes: TBytes;
  Ok: Boolean;
  Used, Err: string;
  Elapsed: Int64;
  GotBytes: Integer;
  Cancel: Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(630);{$ENDIF}
  Result := 0;
  if Dataset = nil then
    raise EOSMError.Create('FetchAllTilesInto: Dataset = nil');
  if FFetcher = nil then
    raise EOSMError.Create('FetchAllTilesInto: fetcher not set');

  if not (AIncludeBuildings or AIncludeHighways or AIncludeTrees or
          AIncludeLanduse or AIncludeWaterways) then
    Exit;

  Tiles := TTileMath.TilesCoveringBox(Box, FTileZoom);
  if Length(Tiles) = 0 then Exit;

  OkCount := 0;
  for I := 0 to High(Tiles) do
  begin
    TileBox := TTileMath.TileToLatLonBox(Tiles[I]);
    Query := TOverpassQueryExt.BuildCombinedFull(TileBox,
               DefaultFlagsForFullScene, FTimeoutS);

    Ok := FetchWithFallback(StartingEndpointIdx(Tiles[I]), Query,
                            Bytes, Elapsed, Used, Err);
    GotBytes := Length(Bytes);

    if Ok and (GotBytes > 0) then
    begin
      try
        TOSMJsonReader.ParseBytes(Bytes, Dataset);
        Inc(OkCount);
      except
        on E: Exception do
        begin
          Err := 'parse error: ' + E.Message;
          Ok  := False;
        end;
      end;
    end;

    Cancel := False;
    if Assigned(FOnTile) then
      FOnTile(Self, Tiles[I], I + 1, Length(Tiles),
              Ok and (GotBytes > 0),
              GotBytes, Elapsed, Used, Err, Cancel);
    if Cancel then Break;
  end;

  Result := OkCount;
end;

function TOverpassClient.FetchTileInto(const ATile: TTileXY;
  Dataset: TOSMDataset): Boolean;
var
  TileBox:  TLatLonBox;
  Query, Used, Err: string;
  Bytes:    TBytes;
  Elapsed:  Int64;
  GotBytes: Integer;
  Cancel:   Boolean;
  Started,ParseStarted,ParseMs:QWord;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1587);{$ENDIF}
  Result := False;
  if Dataset = nil then
    raise EOSMError.Create('FetchTileInto: Dataset = nil');
  if FFetcher = nil then
    raise EOSMError.Create('FetchTileInto: fetcher not set');

  TileBox := TTileMath.TileToLatLonBox(ATile);
  Query   := TOverpassQueryExt.BuildCombinedFull(TileBox,
               DefaultFlagsForFullScene, FTimeoutS);
  Err := '';
  Started:=GetTickCount64;ParseMs:=0;

  if FetchWithFallback(StartingEndpointIdx(ATile), Query,
                       Bytes, Elapsed, Used, Err) then
  begin
    GotBytes := Length(Bytes);
    if GotBytes > 0 then
      try
        ParseStarted:=GetTickCount64;
        TOSMJsonReader.ParseBytes(Bytes, Dataset);
        ParseMs:=GetTickCount64-ParseStarted;
        Result := True;
      except
        on E: Exception do
        begin
          Err    := 'parse error: ' + E.Message;
          Result := False;
        end;
      end;
  end
  else
    GotBytes := Length(Bytes);

  Cancel := False;
  { One summary only on a slow tile; never log query bodies or credentials. }
  if(FLog<>nil)and(GetTickCount64-Started>=2000)then
    FLog.Write(llInfo,Format('OSM source %d/%d/%d: total=%d ms fetch=%d ms parse=%d ms bytes=%d ok=%s cache=%s',
      [ATile.Zoom,ATile.X,ATile.Y,GetTickCount64-Started,Elapsed,ParseMs,GotBytes,BoolToStr(Result,True),BoolToStr(Used='cache',True)]));
  if Assigned(FOnTile) then
    FOnTile(Self, ATile, 1, 1, Result, GotBytes, Elapsed, Used, Err, Cancel);
end;

destructor TOverpassFragEntry.Destroy;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1588);{$ENDIF}
  FreeAndNil(Ds);
  inherited;
end;

{ deep-copy helpers — cached fragments are read-only and shared, so their
  elements are never moved into a result (AddNode/Way/Relation TRANSFER
  ownership); they are cloned. }

procedure CopyOsmTags(ASrc, ADst: TOSMTags);
var
  I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1589);{$ENDIF}
  if (ASrc = nil) or (ADst = nil) then Exit;
  for I := 0 to ASrc.Count - 1 do
    ADst.Add(ASrc.Keys[I], ASrc.Values[I]);
end;

function CloneOsmNode(N: TOSMNode): TOSMNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1590);{$ENDIF}
  Result := TOSMNode.Create(N.Id, N.Position);
  CopyOsmTags(N.Tags, Result.Tags);
end;

function CloneOsmWay(W: TOSMWay): TOSMWay;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1591);{$ENDIF}
  Result := TOSMWay.Create(W.Id);
  Result.NodeRefs := Copy(W.NodeRefs);
  CopyOsmTags(W.Tags, Result.Tags);
end;

function CloneOsmRelation(R: TOSMRelation): TOSMRelation;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1592);{$ENDIF}
  Result := TOSMRelation.Create(R.Id);
  Result.Members := Copy(R.Members);   { record array; Copy handles the string field }
  CopyOsmTags(R.Tags, Result.Tags);
end;

procedure TOverpassClient.DeepMergeInto(ADst, ASrc: TOSMDataset);
var
  N: TOSMNode;
  W: TOSMWay;
  R: TOSMRelation;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1593);{$ENDIF}
  if (ADst = nil) or (ASrc = nil) then Exit;
  { Halo-дубликаты: соседние фрагменты несут ОДНИ и те же элементы
    (перекрытие гало; один сервер, один набор флагов запроса — содержимое
    идентично). Раньше каждый дубликат клонировался заново и AddOrSetValue
    освобождал прежний клон — на швах N-1 лишних клонов каждого элемента.
    Теперь первый вариант побеждает: уже присутствующий id не клонируем. }
  for N in ASrc.Nodes.Values do
    if ADst.FindNode(N.Id) = nil then
      ADst.AddNode(CloneOsmNode(N));      { AddNode takes ownership of the clone }
  for W in ASrc.Ways.Values do
    if ADst.FindWay(W.Id) = nil then
      ADst.AddWay(CloneOsmWay(W));
  for R in ASrc.Relations.Values do
    if ADst.FindRelation(R.Id) = nil then
      ADst.AddRelation(CloneOsmRelation(R));
end;

function TOverpassClient.FragKey(const ATile: TTileXY): string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1594);{$ENDIF}
  Result := Format('%d/%d/%d', [ATile.Zoom, ATile.X, ATile.Y]);
end;

procedure TOverpassClient.EvictFragsLocked;
var
  K, VictimKey: string;
  E, Victim: TOverpassFragEntry;
  Low: Int64;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1595);{$ENDIF}
  while FFrags.Count > FMaxFrags do
  begin
    Victim := nil; VictimKey := ''; Low := High(Int64);
    for K in FFrags.Keys do
    begin
      E := FFrags[K];
      if (E.Pin <= 0) and (E.Seq < Low) then
      begin Low := E.Seq; Victim := E; VictimKey := K; end;
    end;
    if Victim = nil then Break;          { all pinned — over budget briefly }
    FFrags.Remove(VictimKey);            { doOwnsValues -> frees entry+Ds }
  end;
end;

function TOverpassClient.AcquireFrag(const ATile: TTileXY): TOSMDataset;
var
  Key:  string;
  E:    TOverpassFragEntry;
  Frag: TOSMDataset;
  Ok:   Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1596);{$ENDIF}
  Key := FragKey(ATile);

  { Phase 1: claim — cached (pin+return) / become loader / wait for loader. }
  repeat
    CheckGenerationCancelled;
    if(FFetcher<>nil)and FFetcher.Aborted then raise EAbort.Create('OSM preparation cancelled');
    FCacheLock.Enter;
    try
      if FFrags.TryGetValue(Key, E) then
      begin
        Inc(E.Pin); Inc(FSeq); E.Seq := FSeq;
        Exit(E.Ds);
      end;
      if not FLoading.ContainsKey(Key) then
      begin
        FLoading.Add(Key, True);
        Break;                            { we load it }
      end;
    finally
      FCacheLock.Leave;
    end;
    Sleep(1);                             { another thread is fetching it }
  until False;

  { Phase 2: fetch+parse OUTSIDE the lock. A valid-but-empty tile (ocean,
    no features) parses to an empty fragment and IS cached. Only a network/
    parse failure is dropped (and retried later). }
  Frag := TOSMDataset.Create;
  Ok   := False;
  try
    Ok := FetchTileInto(ATile, Frag);
  except
    Ok := False;
  end;
  if not Ok then
    FreeAndNil(Frag);

  { Phase 3: publish (or drop) and release the loader slot. }
  FCacheLock.Enter;
  try
    FLoading.Remove(Key);
    if Frag <> nil then
    begin
      E := TOverpassFragEntry.Create;
      E.Ds := Frag; E.Pin := 1; Inc(FSeq); E.Seq := FSeq;
      FFrags.AddOrSetValue(Key, E);
      EvictFragsLocked;
      Result := Frag;
    end
    else
      Result := nil;
  finally
    FCacheLock.Leave;
  end;
end;

procedure TOverpassClient.ReleaseFrag(const ATile: TTileXY);
var
  E: TOverpassFragEntry;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1597);{$ENDIF}
  FCacheLock.Enter;
  try
    if FFrags.TryGetValue(FragKey(ATile), E) and (E.Pin > 0) then
      Dec(E.Pin);
  finally
    FCacheLock.Leave;
  end;
end;

function TOverpassClient.GetRegion(const ABox: TLatLonBox): TOSMDataset;
var
  Tiles: TTileXYArray;
  I:     Integer;
  Frag:  TOSMDataset;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1598);{$ENDIF}
  Result := TOSMDataset.Create;          { caller-owned; may end up partial/empty }
  try
    Tiles := TTileMath.TilesCoveringBox(ABox, FTileZoom);
    GenerationProgress('OSM tiles', 0, Length(Tiles));
    for I := 0 to High(Tiles) do
    begin
      CheckGenerationCancelled;
      Frag := AcquireFrag(Tiles[I]);      { pinned cache-owned, or nil on failure }
      if Frag <> nil then
        try
          DeepMergeInto(Result, Frag);    { clone elements into the fresh result }
        finally
          ReleaseFrag(Tiles[I]);
        end;
      GenerationProgress('OSM tiles', I + 1, Length(Tiles));
      { failed tile: skipped — region is partial by design (Q2) }
    end;
  except
    FreeAndNil(Result);
    raise;
  end;
end;

function DefaultFlagsForFullScene: TOverpassQueryFlags;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(631);{$ENDIF}
  Result.IncludeBuildings        := True;
  Result.IncludeHighways         := True;
  Result.IncludeTrees            := True;
  Result.IncludeLanduse          := True;
  Result.IncludeWaterways        := True;
  Result.IncludeLeisure          := True;
  Result.IncludeHistoric         := True;
  Result.IncludeTourism          := True;
  Result.IncludeAmenity          := True;
  Result.IncludePOINodes         := True;
  Result.IncludeManMade          := True;
  Result.IncludeEmergency        := True;
  Result.IncludePublicTransport  := True;
  Result.IncludeBusStops         := True;
  Result.IncludeRailway          := True;
  Result.IncludeBarriers         := True;
  Result.IncludePower            := True;
  Result.IncludePlaces           := True;
end;

class function TOverpassQueryExt.BuildCombinedFull(const Box: TLatLonBox;
  const Flags: TOverpassQueryFlags;
  ATimeoutS: Integer): string;
var
  SB:      TStringBuilder;
  BboxArg: string;
  HasAny:  Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1215);{$ENDIF}
  { Курируемое перечисление по категориям (по флагам): тянем ровно то, что рисует сцена (включая
    way["highway"] и все POI), а не «всё» через nwr — последнее перегружало рендер boundary/route-
    релейшнами и роняло дороги. Глобальный [bbox] обязателен для overpass-pg-emu; recurse-down
    (.data > …) добирает узлы way'ев и members релейшнов. }
  HasAny :=
    Flags.IncludeBuildings        or Flags.IncludeHighways or
    Flags.IncludeTrees            or Flags.IncludeLanduse or
    Flags.IncludeWaterways        or Flags.IncludeLeisure or
    Flags.IncludeHistoric         or Flags.IncludeTourism or
    Flags.IncludeAmenity          or Flags.IncludeManMade or
    Flags.IncludeEmergency        or Flags.IncludePublicTransport or
    Flags.IncludeBusStops         or Flags.IncludeRailway or
    Flags.IncludeBarriers         or Flags.IncludePower or
    Flags.IncludePlaces           or Flags.IncludePOINodes;

  BboxArg := TOverpassQueryExt.FormatBboxArg(Box);

  if not HasAny then
  begin
    Result := Format('[bbox:%s][out:json][timeout:%d];out count;',
      [BboxArg, ATimeoutS]);
    Exit;
  end;

  SB := TStringBuilder.Create;
  try
    SB.Append('[bbox:').Append(BboxArg).Append('][out:json][timeout:')
      .Append(IntToStr(ATimeoutS)).AppendLine('];');
    SB.AppendLine('(');

    if Flags.IncludeBuildings then
    begin
      SB.AppendLine('  way["building"];');
      SB.AppendLine('  way["building:part"];');
      SB.AppendLine('  relation["building"];');
      SB.AppendLine('  relation["type"="multipolygon"]["building"];');
      SB.AppendLine('  relation["type"="multipolygon"]["building:part"];');
    end;

    if Flags.IncludeHighways then
      SB.AppendLine('  way["highway"];');

    if Flags.IncludeRailway then
    begin
      SB.AppendLine('  way["railway"];');
      SB.AppendLine('  node["railway"];');
    end;

    if Flags.IncludeTrees then
      SB.AppendLine('  node["natural"~"^(tree|shrub)$"];');

    if Flags.IncludeLanduse then
    begin
      SB.AppendLine('  way["landuse"];');
      SB.AppendLine('  relation["landuse"];');
      SB.AppendLine('  way["natural"];');
      SB.AppendLine('  relation["natural"];');
    end;

    if Flags.IncludeWaterways then
    begin
      SB.AppendLine('  way["waterway"];');
      SB.AppendLine('  way["natural"="water"];');
      SB.AppendLine('  relation["natural"="water"];');
    end;

    if Flags.IncludeLeisure then
    begin
      SB.AppendLine('  way["leisure"];');
      SB.AppendLine('  relation["leisure"];');
    end;

    if Flags.IncludeHistoric then
    begin
      SB.AppendLine('  node["historic"];');
      SB.AppendLine('  way["historic"];');
      SB.AppendLine('  relation["historic"];');
    end;

    if Flags.IncludeTourism then
    begin
      SB.AppendLine('  node["tourism"];');
      SB.AppendLine('  way["tourism"];');
    end;

    if Flags.IncludeAmenity then
    begin
      SB.AppendLine('  node["amenity"];');
      SB.AppendLine('  way["amenity"];');
      SB.AppendLine('  relation["amenity"];');
    end;

    { POI-узлы для табличек: shop/office/craft/healthcare/leisure }
    if Flags.IncludePOINodes then
    begin
      SB.AppendLine('  node["shop"];');
      SB.AppendLine('  node["office"];');
      SB.AppendLine('  node["craft"];');
      SB.AppendLine('  node["healthcare"];');
      SB.AppendLine('  node["leisure"];');
    end;

    if Flags.IncludeManMade then
    begin
      SB.AppendLine('  node["man_made"];');
      SB.AppendLine('  way["man_made"];');
      SB.AppendLine('  relation["man_made"];');
    end;

    if Flags.IncludeEmergency then
      SB.AppendLine('  node["emergency"];');

    if Flags.IncludePublicTransport then
    begin
      SB.AppendLine('  node["public_transport"];');
      SB.AppendLine('  way["public_transport"];');
    end;

    if Flags.IncludeBusStops then
    begin
      SB.AppendLine('  node["highway"="bus_stop"];');
      SB.AppendLine('  node["highway"="platform"];');
    end;

    if Flags.IncludeBarriers then
      SB.AppendLine('  way["barrier"];');

    if Flags.IncludePower then
    begin
      SB.AppendLine('  way["power"];');
      SB.AppendLine('  node["power"];');
    end;

    if Flags.IncludePlaces then
    begin
      SB.AppendLine('  way["place"];');
      SB.AppendLine('  node["place"];');
    end;

    SB.AppendLine(')->.data;');
    SB.AppendLine('.data > ->.dataMembers;');
    SB.AppendLine('(.data; .dataMembers;)->.all;');
    SB.AppendLine('.all out body qt;');

    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

class function TOverpassQueryExt.FormatBboxArg(const Box: TLatLonBox): string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1216);{$ENDIF}
  Result := Format('%.6f,%.6f,%.6f,%.6f',
    [Box.MinLat, Box.MinLon, Box.MaxLat, Box.MaxLon],
    InvariantFmt);
end;

class function TOverpassQueryExt.BuildFromBasicFlags(const Box: TLatLonBox;
  AIncludeBuildings, AIncludeHighways, AIncludeTrees,
  AIncludeLanduse, AIncludeWaterways: Boolean;
  ATimeoutS: Integer): string;
var
  Flags: TOverpassQueryFlags;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1217);{$ENDIF}
  Flags := DefaultFlagsForFullScene;
  Flags.IncludeBuildings := AIncludeBuildings;
  Flags.IncludeHighways  := AIncludeHighways;
  Flags.IncludeTrees     := AIncludeTrees;
  Flags.IncludeLanduse   := AIncludeLanduse;
  Flags.IncludeWaterways := AIncludeWaterways;
  Result := BuildCombinedFull(Box, Flags, ATimeoutS);
end;

constructor TTileWorkQueue.Create;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1218);{$ENDIF}
  inherited Create;
  FLock     := TCriticalSection.Create;
  FNotEmpty := TEvent.Create(nil, True, False, '');
  FAllDone  := TEvent.Create(nil, True, False, '');
  FItems    := TList.Create;
  FClosed   := True;
end;

destructor TTileWorkQueue.Destroy;
var I: Integer; T: PTileTask;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1219);{$ENDIF}
  Cancel;
  if FItems <> nil then
  begin
    for I := 0 to FItems.Count - 1 do
    begin
      T := PTileTask(FItems[I]);
      Dispose(T);
    end;
    FItems.Free;
  end;
  FNotEmpty.Free;
  FAllDone.Free;
  FLock.Free;
  inherited;
end;

procedure TTileWorkQueue.StartBatch(ATotal: Integer);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(632);{$ENDIF}
  FLock.Acquire;
  try
    FTotal    := ATotal;
    FInFlight := 0;
    FCanceled := False;
    FClosed   := False;
    FAllDone.ResetEvent;
    FNotEmpty.ResetEvent;
  finally
    FLock.Release;
  end;
end;

procedure TTileWorkQueue.CloseInput;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(633);{$ENDIF}
  FLock.Acquire;
  try
    FClosed := True;
    CheckAllDoneLocked;
    FNotEmpty.SetEvent;
  finally
    FLock.Release;
  end;
end;

procedure TTileWorkQueue.Push(ATask: PTileTask);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(634);{$ENDIF}
  FLock.Acquire;
  try
    if FCanceled then begin Dispose(ATask); Exit; end;
    FItems.Add(ATask);
    FNotEmpty.SetEvent;
  finally
    FLock.Release;
  end;
end;

function TTileWorkQueue.Take(WorkerBit: LongWord): PTileTask;
var
  I: Integer;
  T: PTileTask;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(635);{$ENDIF}
  Result := nil;
  while True do
  begin
    FLock.Acquire;
    try
      if FCanceled then Exit(nil);

      for I := 0 to FItems.Count - 1 do
      begin
        T := PTileTask(FItems[I]);
        if (T^.SkipMask and WorkerBit) = 0 then
        begin
          FItems.Delete(I);
          Inc(FInFlight);
          if FItems.Count = 0 then FNotEmpty.ResetEvent;
          Exit(T);
        end;
      end;

      if FClosed and (FInFlight = 0) then
      begin
        FAllDone.SetEvent;
        Exit(nil);
      end;

      if FClosed then Exit(nil);

      FNotEmpty.ResetEvent;
    finally
      FLock.Release;
    end;

    if FNotEmpty.WaitFor(INFINITE) <> wrSignaled then Exit(nil);
  end;
end;

procedure TTileWorkQueue.TaskDone(ATask: PTileTask; Success: Boolean;
  WorkerBit, AllWorkersMask: LongWord; out FinallyClosed: Boolean);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(636);{$ENDIF}
  FinallyClosed := False;
  FLock.Acquire;
  try
    Dec(FInFlight);

    if Success then
    begin
      Dispose(ATask);
      FinallyClosed := True;
    end
    else
    begin
      ATask^.SkipMask := ATask^.SkipMask or WorkerBit;
      if (ATask^.SkipMask and AllWorkersMask) = AllWorkersMask then
      begin
        { All workers tried — give up. }
        Dispose(ATask);
        FinallyClosed := True;
      end
      else
      begin
        { Re-queue for a different worker. }
        FItems.Add(ATask);
        FNotEmpty.SetEvent;
      end;
    end;

    CheckAllDoneLocked;
  finally
    FLock.Release;
  end;
end;

procedure TTileWorkQueue.Cancel;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(637);{$ENDIF}
  FLock.Acquire;
  try
    FCanceled := True;
    FClosed   := True;
    FNotEmpty.SetEvent;
    FAllDone.SetEvent;
  finally
    FLock.Release;
  end;
end;

function TTileWorkQueue.WaitAllDone(TimeoutMs: Cardinal): Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(638);{$ENDIF}
  Result := FAllDone.WaitFor(TimeoutMs) = wrSignaled;
end;

procedure TTileWorkQueue.CheckAllDoneLocked;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(639);{$ENDIF}
  if FClosed and (FItems.Count = 0) and (FInFlight = 0) then
    FAllDone.SetEvent;
end;

constructor TOverpassWorker.Create(AQueue: TTileWorkQueue;
  AFetcher: THTTPFetcherWithCache; const AEndpoint: string;
  ABit, AAllMask: LongWord; AWorkerIdx: Integer;
  ABuildQuery: TBuildQueryProc; AOwner: TObject; ALog: TLogTarget);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1220);{$ENDIF}
  FQueue      := AQueue;
  FFetcher    := AFetcher;
  FEndpoint   := AEndpoint;
  FBit        := ABit;
  FAllMask    := AAllMask;
  FWorkerIdx  := AWorkerIdx;
  FBuildQuery := ABuildQuery;
  FOwner      := AOwner;
  FLog        := ALog;
  FreeOnTerminate := False;
  inherited Create(False);
end;

function TOverpassWorker.DoFetch(const Tile: TTileXY;
  out Bytes: TBytes; out ElapsedMs: Int64; out ErrMsg: string): Boolean;
var
  Query: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(640);{$ENDIF}
  Bytes := nil; ElapsedMs := 0; ErrMsg := ''; Result := False;
  Query := FBuildQuery(Tile);
  if Query = '' then begin ErrMsg := 'empty query'; Exit; end;

  Result := OverpassFetchOnEndpoint(FFetcher, FEndpoint, Query,
                                    Bytes, ElapsedMs, ErrMsg);
  FResolvedEndpoint := GResolvedOverpassEndpoint;
end;

procedure TOverpassWorker.Execute;
var
  Task:    PTileTask;
  Bytes:   TBytes;
  Elapsed: Int64;
  Err:     string;
  Ok:      Boolean;
  FinallyClosed: Boolean;
  SnapTile:  TTileXY;
  SnapIndex: Integer;
  R: PTileResult;
  A: PTileAttempt;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(641);{$ENDIF}
  if FLog <> nil then
    FLog.Write(llInfo,
      Format('Worker %d started, endpoint=%s', [FWorkerIdx, FEndpoint]));

  while not Terminated do
  begin
    Task := FQueue.Take(FBit);
    if Task = nil then Break;

    SnapTile  := Task^.Tile;
    SnapIndex := Task^.Index;

    Ok := DoFetch(SnapTile, Bytes, Elapsed, Err);

    { Per-attempt record (every try, success or fail). }
    New(A);
    A^.Tile      := SnapTile;
    A^.Index     := SnapIndex;
    A^.Total     := FQueue.Total;
    A^.Success   := Ok;
    A^.BytesLen  := Length(Bytes);
    A^.ElapsedMs := Elapsed;
    A^.Endpoint  := FResolvedEndpoint;
    A^.ErrMsg    := Err;
    A^.WorkerIdx := FWorkerIdx;
    TParallelOverpassRunner(FOwner).PostAttemptFromWorker(A);

    FQueue.TaskDone(Task, Ok, FBit, FAllMask, FinallyClosed);

    { Final tile result (one per tile — success or all workers exhausted). }
    if FinallyClosed then
    begin
      New(R);
      R^.Tile      := SnapTile;
      R^.Index     := SnapIndex;
      R^.Total     := FQueue.Total;
      R^.Success   := Ok;
      R^.Bytes     := Bytes;
      R^.BytesLen  := Length(Bytes);
      R^.ElapsedMs := Elapsed;
      R^.Endpoint  := FResolvedEndpoint;
      R^.ErrMsg    := Err;
      R^.WorkerIdx := FWorkerIdx;

      TParallelOverpassRunner(FOwner).PostResultFromWorker(R);
    end;
  end;

  if FLog <> nil then
    FLog.Write(llInfo,
      Format('Worker %d (%s) exited.', [FWorkerIdx, FEndpoint]));
end;

constructor TParallelOverpassRunner.Create(AFetcher: THTTPFetcherWithCache;
  AOverpass: TOverpassClient; ALog: TLogTarget);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1221);{$ENDIF}
  inherited Create;
  FFetcher  := AFetcher;
  FOverpass := AOverpass;
  FLog      := ALog;
  FQueue    := TTileWorkQueue.Create;
  FResultLock   := TCriticalSection.Create;
  FResultEvent  := TEvent.Create(nil, True, False, '');
  FPendResults  := TList.Create;
  FPendAttempts := TList.Create;
end;

destructor TParallelOverpassRunner.Destroy;
var I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1222);{$ENDIF}
  Cancel;
  for I := 0 to High(FWorkers) do
    if FWorkers[I] <> nil then
    begin
      FWorkers[I].WaitFor;
      FWorkers[I].Free;
    end;
  FreeOrphanedItems;
  FPendResults.Free;
  FPendAttempts.Free;
  FResultEvent.Free;
  FResultLock.Free;
  FQueue.Free;
  inherited;
end;

procedure TParallelOverpassRunner.FreeOrphanedItems;
var
  I: Integer;
  R: PTileResult;
  A: PTileAttempt;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(642);{$ENDIF}
  if FPendResults <> nil then
  begin
    for I := 0 to FPendResults.Count - 1 do
    begin
      R := PTileResult(FPendResults[I]);
      if R <> nil then Dispose(R);
    end;
    FPendResults.Clear;
  end;
  if FPendAttempts <> nil then
  begin
    for I := 0 to FPendAttempts.Count - 1 do
    begin
      A := PTileAttempt(FPendAttempts[I]);
      if A <> nil then Dispose(A);
    end;
    FPendAttempts.Clear;
  end;
end;

function TParallelOverpassRunner.BuildQueryForTile(const T: TTileXY): string;
var
  Box: TLatLonBox;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(643);{$ENDIF}
  Box := TTileMath.TileToLatLonBox(T);
  Result := TOverpassQueryExt.BuildFromBasicFlags(Box,
    FInclBuildings, FInclHighways, FInclTrees,
    FInclLanduse,   FInclWaterways, FOverpass.TimeoutS);
end;

procedure TParallelOverpassRunner.PostResultFromWorker(R: PTileResult);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(644);{$ENDIF}
  FResultLock.Acquire;
  try
    FPendResults.Add(R);
  finally
    FResultLock.Release;
  end;
  FResultEvent.SetEvent;
end;

procedure TParallelOverpassRunner.PostAttemptFromWorker(A: PTileAttempt);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(645);{$ENDIF}
  FResultLock.Acquire;
  try
    FPendAttempts.Add(A);
  finally
    FResultLock.Release;
  end;
  FResultEvent.SetEvent;
end;

procedure TParallelOverpassRunner.DrainResults;
var
  ResSnap, AttSnap: TList;
  I: Integer;
  R: PTileResult;
  A: PTileAttempt;
  CancelByCallback: Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(646);{$ENDIF}
  ResSnap := nil;
  AttSnap := nil;
  FResultLock.Acquire;
  try
    if FPendAttempts.Count > 0 then
    begin
      AttSnap := TList.Create;
      AttSnap.Assign(FPendAttempts);
      FPendAttempts.Clear;
    end;
    if FPendResults.Count > 0 then
    begin
      ResSnap := TList.Create;
      ResSnap.Assign(FPendResults);
      FPendResults.Clear;
    end;
    FResultEvent.ResetEvent;
  finally
    FResultLock.Release;
  end;

  if AttSnap <> nil then
  try
    for I := 0 to AttSnap.Count - 1 do
    begin
      A := PTileAttempt(AttSnap[I]);
      try
        if Assigned(FOnAttempt) then
          FOnAttempt(Self, A^.WorkerIdx, A^.Endpoint,
                     A^.Tile, A^.Index, A^.Total,
                     A^.Success, A^.BytesLen, A^.ElapsedMs,
                     A^.ErrMsg);
      finally
        Dispose(A);
      end;
    end;
  finally
    AttSnap.Free;
  end;

  if ResSnap <> nil then
  try
    for I := 0 to ResSnap.Count - 1 do
    begin
      R := PTileResult(ResSnap[I]);
      try
        if R^.Success and (R^.BytesLen > 0) and (FDataset <> nil) then
        begin
          try
            TOSMJsonReader.ParseBytes(R^.Bytes, FDataset);
            Inc(FOkCount);
          except
            on E: Exception do
              R^.ErrMsg := 'parse error: ' + E.Message;
          end;
        end;

        CancelByCallback := False;
        if Assigned(FOnTile) then
          FOnTile(Self, R^.Tile, R^.Index, R^.Total,
                  R^.Success, R^.BytesLen, R^.ElapsedMs,
                  R^.Endpoint, R^.ErrMsg, CancelByCallback);
        if CancelByCallback then Self.Cancel;
      finally
        Dispose(R);
      end;
    end;
  finally
    ResSnap.Free;
  end;
end;

function TParallelOverpassRunner.FetchAllTilesParallelInto(
  const Box: TLatLonBox; Dataset: TOSMDataset;
  AIncludeBuildings, AIncludeHighways, AIncludeTrees,
  AIncludeLanduse, AIncludeWaterways: Boolean): Integer;
var
  Tiles:   TTileXYArray;
  I, N:    Integer;
  Task:    PTileTask;
  AllMask: LongWord;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(647);{$ENDIF}
  Result := 0;
  if Dataset = nil then
    raise EOSMError.Create('FetchAllTilesParallelInto: Dataset = nil');
  if FFetcher = nil then
    raise EOSMError.Create('FetchAllTilesParallelInto: fetcher not set');
  if FOverpass = nil then
    raise EOSMError.Create('FetchAllTilesParallelInto: Overpass client not set');
  if not (AIncludeBuildings or AIncludeHighways or AIncludeTrees or
          AIncludeLanduse or AIncludeWaterways) then
  begin
    LogInfo('Parallel fetch: nothing requested, skipping');
    Exit;
  end;

  FInclBuildings := AIncludeBuildings;
  FInclHighways  := AIncludeHighways;
  FInclTrees     := AIncludeTrees;
  FInclLanduse   := AIncludeLanduse;
  FInclWaterways := AIncludeWaterways;
  FDataset       := Dataset;
  FOkCount       := 0;

  Tiles := TTileMath.TilesCoveringBox(Box, FOverpass.TileZoom);
  if Length(Tiles) = 0 then
  begin
    LogWarn('Parallel fetch: no tiles covering box');
    Exit;
  end;

  N := FOverpass.Endpoints.Count;
  if (N = 1) and SameText(FOverpass.Endpoints[0], OSM_DIRECTORY_MODE) then N := 2;
  if N = 0 then
  begin
    LogWarn('Parallel fetch: no endpoints configured');
    Exit;
  end;
  if N > 32 then N := 32;     { AllMask is 32-bit }
  AllMask := (LongWord(1) shl N) - 1;

  LogInfo(Format('Parallel fetch: %d tiles, %d workers (one per endpoint)',
    [Length(Tiles), N]));

  FQueue.StartBatch(Length(Tiles));
  for I := 0 to High(Tiles) do
  begin
    New(Task);
    Task^.Tile     := Tiles[I];
    Task^.Index    := I + 1;
    Task^.SkipMask := 0;
    FQueue.Push(Task);
  end;
  FQueue.CloseInput;

  SetLength(FWorkers, N);
  for I := 0 to N - 1 do
    FWorkers[I] := TOverpassWorker.Create(
      FQueue, FFetcher, FOverpass.Endpoints[I mod FOverpass.Endpoints.Count],
      LongWord(1) shl I, AllMask, I,
      @BuildQueryForTile, Self, FLog);

  LogInfo('Parallel fetch: workers started, awaiting completion...');

  while not FQueue.WaitAllDone(0) do
  begin
    DrainResults;
    FResultEvent.WaitFor(50);
  end;

  LogInfo('Parallel fetch: queue empty, joining workers...');

  for I := 0 to High(FWorkers) do
  begin
    FWorkers[I].WaitFor;
    FreeAndNil(FWorkers[I]);
  end;
  SetLength(FWorkers, 0);

  DrainResults;

  LogInfo(Format('Parallel fetch: done, %d/%d tiles ok',
    [FOkCount, Length(Tiles)]));

  Result := FOkCount;
end;

procedure TParallelOverpassRunner.Cancel;
var I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(648);{$ENDIF}
  LogInfo('Parallel fetch: Cancel requested');
  if FQueue <> nil then FQueue.Cancel;
  for I := 0 to High(FWorkers) do
    if FWorkers[I] <> nil then
      FWorkers[I].Terminate;

  if FResultEvent <> nil then FResultEvent.SetEvent;
end;

end.
