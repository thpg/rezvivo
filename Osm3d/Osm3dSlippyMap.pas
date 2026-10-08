unit Osm3dSlippyMap;

{ Как и остальные Osm3d-юниты: воркер-математика отлаживалась с
  выключенными overflow/range проверками. }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$codepage UTF8}

interface

uses
  Classes,
  SysUtils,
  Math,
  SyncObjs,
  Generics.Collections,
  fphttpclient,
  opensslsockets,
  Osm3dCacheHTTPFetcher,
  Osm3dImageCodecLock,   { декод тайлов в потоках фетчера — под общим замком }
  CastleVectors,
  CastleRenderContext,
  CastleImages,
  CastleScene,
  CastleTransform,
  CastleCameras,
  CastleRenderOptions,
  X3DNodes,
  Osm3dGeoMath, Osm3dFlatMap;

type
  { Optional diagnostics snapshot — feed a HUD if you want one. }
  TSlippyStats = record
    Zoom:        Integer;   { zoom requested this frame }
    TilesKnown:  Integer;   { entries in the registry }
    TilesBuilt:  Integer;   { tiles with a live textured scene }
    TilesVisible:Integer;   { built tiles currently shown }
    Queued:      Integer;   { scheduled, not yet downloaded }
    Failed:      Integer;   { last fetch failed (awaiting retry) }
    PendingBuild:Integer;   { downloaded, waiting for main-thread build }
  end;

  TOsm3dSlippyMap = class;

  { worker-thread fetch job / result (records, passed by value) }
  TSlippyJob = record
    Z, X, Y: Integer;
    Detail: Boolean;
    Epoch:   Integer;
    Url:     string;
    { Snapshot of the main-thread projection state, copied by value at
      schedule time so the worker can build geometry without touching FProj
      (which the main thread may swap on SetOrigin). }
    OriginLat:   Double;
    OriginLon:   Double;
    PlaneHeight: Single;
    ZoomYStep:   Single;
  end;

  TSlippyResult = record
    Z, X, Y: Integer;
    Epoch:   Integer;
    Ok:      Boolean;
    { Fully built, detached X3D graph (download + decode + mesh assembly all
      done on the worker). nil when Ok = False. The main thread only wraps it
      in a TCastleScene and adds it — the actual hand-off to the CGE renderer.
      Whoever does not consume it MUST free it (see DrainResults/Clear). }
    Root:    TX3DRootNode;
  end;

  { HTTP worker. Pulls jobs from the host's queue, downloads each tile through
    the owner's cache-aware fetcher (FetchTileBytes), decodes + assembles the
    X3D graph off the main thread, and pushes the result back. The main thread
    only adopts the graph into a scene; this worker knows nothing else of CGE. }
  TSlippyFetchThread = class(TThread)
  private
    FOwner: TOsm3dSlippyMap;
    FMapHttp:THTTPFetcherWithCache;
    procedure Fetch(const AJob: TSlippyJob);
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TOsm3dSlippyMap);
    destructor Destroy;override;
    procedure Cancel;
  end;

  TOsm3dSlippyMap = class(TCastleTransform)
  private type
    TTileState = (tsIdle, tsQueued, tsBuilt, tsFailed);

    TTileEntry = class
      Z, X, Y:          Integer;
      Key:              Int64;
      State:            TTileState;
      Scene:            TCastleScene;     { non-nil iff State = tsBuilt }
      LastWantedFrame:  Int64;
      RetryFrame:       Int64;            { earliest frame to retry a fail }
      destructor Destroy; override;
    end;
  private
    { config }
    FServerUrl:    string;
    FUserAgent:    string;
    FOrigin:       TLatLon;
    FMaxTiles:     Integer;
    FMinZoom:      Integer;
    FMaxZoom:      Integer;
    FPlaneHeight:  Single;
    FZoomYStep:    Single;     { per-zoom Y offset, kills coplanar z-fight }
    FSpanFactor:   Single;     { ground span seen ≈ camHeight * this }
    FAspect:       Single;     { viewport width/height; auto-read each frame,
                                 falls back to this value before first render }
    FTilesAcross:  Single;     { target tiles across the viewport }
    FPrefetchM:    Single;     { extra metres of tiles to prefetch }
    FUploadBudget: Integer;    { tiles built per frame on the main thread }
    FWorkerCount:  Integer;
    FEvictLag:     Integer;    { frames un-wanted before a tile is cold }
    FRetryDelay:   Integer;    { frames before retrying a failed fetch }
    FMinCamHeight: Single;
    FEnabled:      Boolean;

    { Optional shared cache-aware HTTP fetcher (project Osm3dCacheHTTPFetcher).
      Injected by the host, NOT owned here. When set, tile downloads go through
      it (byte cache + retries); when nil, the worker falls back to a direct,
      uncached GET. Set once before enabling; read concurrently by workers. }
    FFetcher:      THTTPFetcherWithCache;

    { state — main thread only }
    FProj:    TLocalProjection;
    FTiles:   specialize TDictionary<Int64, TTileEntry>;
    FFrame:   Int64;
    FLastZoom:Integer;

    { route (FIT/GPX track) overlay — main thread only }
    FRoutePts:        array of TLatLon;
    FRouteScene:      TCastleScene;
    FRouteColor:      TVector3;   { line colour (unlit) }
    FRouteOpacity:    Single;     { 0 = invisible, 1 = solid }
    FRouteWidthFac:   Single;     { line width = this * camera height }
    FRouteLiftFac:    Single;     { line is lifted this * camera height above the
                                    map plane, so its depth never collapses into
                                    the tiles' when the camera is far away }
    FRouteMinWidthM:  Single;     { lower clamp on the world-space width }
    FRouteDirty:      Boolean;    { needs a rebuild }
    FRouteBuiltZoom:  Integer;    { zoom the current ribbon was sized for }
    FLastCamHeight:   Single;     { last camera height seen in Update }

    { scheduling — guarded by FQueueLock }
    FQueueLock: TCriticalSection;
    FQueue:     specialize TList<TSlippyJob>;
    FEpoch:     Integer;

    { results — guarded by FResultLock }
    FResultLock: TCriticalSection;
    FResults:    specialize TQueue<TSlippyResult>;

    { workers }
    FWorkers: array of TSlippyFetchThread;
    FWake:    TEvent;

    procedure SetServerUrl(const AValue: string);
    procedure SetOrigin(const AValue: TLatLon);
    procedure SetEnabled(AValue: Boolean);
    function  FetchTileBytes(const AUrl: string; out AData: TBytes): Boolean;

    function  KeyOf(Z, X, Y: Integer): Int64; inline;
    function  GetOrCreate(Z, X, Y: Integer): TTileEntry;
    function  ChooseZoom(const ACentre: TLatLon; ACamHeight: Single): Integer;
    function  GetCameraView(out ACentre: TLatLon; out ACamHeight: Single): Boolean;
    function  GetViewportAspect: Single;

    procedure Schedule(AEntry: TTileEntry);
    procedure MarkWanted(Z, X, Y: Integer);
    procedure ShowBestAncestor(Z, X, Y: Integer);
    procedure ShowBuiltDescendants(Z, X, Y, ADepth: Integer);
    procedure DrainResults;
    procedure DiscardResult(const AResult: TSlippyResult);
    procedure BuildTile(AEntry: TTileEntry; const AResult: TSlippyResult);
    procedure SweepVisibilityAndEvict;
    procedure FreeEntry(AEntry: TTileEntry);

    function  BuildTileRootNode(AImage: TCastleImage; Z, X, Y: Integer;
                const AOrigin: TLatLon; APlaneHeight, AZoomYStep: Single): TX3DRootNode;
    function  SceneFromRoot(ARoot: TX3DRootNode): TCastleScene;
    function  DecodeImage(const AData: TBytes; const AMime: string): TCastleImage;

    function  RouteY(ACamHeight: Single): Single;
    function  BuildRouteRootNode(AWidthM: Single): TX3DRootNode;
    procedure RebuildRoute(ACamHeight: Single);
  public
    constructor Create(AOwner: TComponent); override;
    destructor  Destroy; override;

    procedure Update(const SecondsPassed: Single; var RemoveMe: TRemoveType); override;

    { Drop every cached tile and bump the epoch so in-flight fetches are
      discarded. Call after changing ServerUrl or Origin at runtime. }
    procedure Clear;

    { Overlay a track (e.g. parsed from a FIT/GPX file) as a translucent
      line drawn on top of the flat map. Pass the route as lat/lon points;
      they are projected through the same Origin as the tiles, so the line
      lines up with the map. Call with an empty array (or ClearRoute) to
      remove it. The line is rebuilt automatically as you zoom. }
    procedure SetRoute(const APoints: array of TLatLon);
    procedure ClearRoute;

    { worker-only entry points (public so TSlippyFetchThread can reach
      them; host code never calls these) }
    function  WorkerPopJob(out AJob: TSlippyJob): Boolean;
    procedure WorkerPushResult(const AResult: TSlippyResult);
    property  WakeEvent: TEvent read FWake;

    { The XYZ tile endpoint, e.g.
      'https://tile.openstreetmap.org/{z}/{x}/{y}.png'. This is the
      "server address" parameter. Changing it clears the cache. }
    property ServerUrl: string read FServerUrl write SetServerUrl;

    { Local-projection origin. Must match the origin the rest of your
      scene uses for the raster map to line up with 3D content. }
    property Origin: TLatLon read FOrigin write SetOrigin;

    { Send a descriptive UA — most public tile servers reject blank/default. }
    property UserAgent: string read FUserAgent write FUserAgent;
    { Shared cache-aware HTTP fetcher. Assign the host's instance (backed by the
      project byte cache) to serve/store tiles through it. Not owned: the host
      frees it — and must do so AFTER this map (Destroy joins the workers). }
    property Fetcher: THTTPFetcherWithCache read FFetcher write FFetcher;

    property Enabled:     Boolean read FEnabled     write SetEnabled;
    property MaxTiles:    Integer read FMaxTiles     write FMaxTiles;
    property MinZoom:     Integer read FMinZoom      write FMinZoom;
    property MaxZoom:     Integer read FMaxZoom      write FMaxZoom;
    property PlaneHeight: Single  read FPlaneHeight  write FPlaneHeight;
    property SpanFactor:  Single  read FSpanFactor   write FSpanFactor;
    { Viewport width/height. Read automatically from the render projection
      each frame; set this only if you want to override the auto value. }
    property Aspect:      Single  read FAspect       write FAspect;
    property TilesAcross: Single  read FTilesAcross  write FTilesAcross;
    property PrefetchMeters: Single read FPrefetchM  write FPrefetchM;
    property UploadBudget: Integer read FUploadBudget write FUploadBudget;

    { Route overlay appearance. RouteColor is the unlit line colour (RGB 0..1).
      RouteOpacity is 0 (invisible) .. 1 (solid); 0.6 reads as translucent.
      The on-screen line thickness ≈ RouteWidthFactor * cameraHeight, never
      thinner than RouteMinWidthMeters in world units, so it stays visible
      from any zoom. Changing any of these takes effect on the next frame. }
    property RouteColor:        TVector3 read FRouteColor     write FRouteColor;
    property RouteOpacity:      Single   read FRouteOpacity   write FRouteOpacity;
    property RouteWidthFactor:  Single   read FRouteWidthFac  write FRouteWidthFac;
    property RouteLiftFactor:   Single   read FRouteLiftFac   write FRouteLiftFac;
    property RouteMinWidthMeters: Single read FRouteMinWidthM write FRouteMinWidthM;
  end;

implementation

const
  { Web-mercator world circumference at the equator (metres) = 2π·6378137
    (экваториальный радиус WGS-84) — СТАНДАРТ тайловой сетки OSM, поэтому
    сознательно НЕ сведено к Osm3dGeoMath.EARTH_RADIUS_M (6371000, средний
    радиус для метрических пересчётов): замена сдвинула бы сетку на ~0.11 %. }
  EARTH_CIRCUM_M = 40075016.686;

  { How many zoom levels deeper to search for already-built tiles to show as a
    temporary fallback while a coarser wanted tile is still downloading (the
    zoom-out case). Recursion only descends into registry-present subtrees, so
    this stays cheap. }
  FallbackDescendantDepth = 4;

{ ── TOsm3dSlippyMap.TTileEntry ────────────────────────────────────── }

destructor TOsm3dSlippyMap.TTileEntry.Destroy;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1669);{$ENDIF}
  { Scene is owned/freed by the component (FreeEntry); not here. }
  inherited Destroy;
end;

{ ── TSlippyFetchThread ────────────────────────────────────────────── }

constructor TSlippyFetchThread.Create(AOwner: TOsm3dSlippyMap);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1670);{$ENDIF}
  FOwner := AOwner;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TSlippyFetchThread.Execute;
var
  Job: TSlippyJob;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1671);{$ENDIF}
  while not Terminated do
  begin
    if FOwner.WorkerPopJob(Job) then
      Fetch(Job)
    else
      FOwner.WakeEvent.WaitFor(200);   { idle: sleep until woken or 200 ms }
  end;
end;

destructor TSlippyFetchThread.Destroy;
begin Cancel;WaitFor;FMapHttp.Free;inherited;end;
procedure TSlippyFetchThread.Cancel;
begin
  Terminate;
  FOwner.FQueueLock.Enter;
  try if FMapHttp<>nil then FMapHttp.AbortAllRequests;
  finally FOwner.FQueueLock.Leave;end;
end;

procedure TSlippyFetchThread.Fetch(const AJob: TSlippyJob);
var
  Res:    TSlippyResult;
  Lower:  string;
  Mime:   string;
  Bytes:  TBytes;
  Img:    TCastleImage;
  NextJob:TSlippyJob;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1672);{$ENDIF}
  Res := Default(TSlippyResult);
  Res.Z := AJob.Z; Res.X := AJob.X; Res.Y := AJob.Y;
  Res.Epoch := AJob.Epoch;
  Res.Ok := False;
  Res.Root := nil;

  if Pos('rezvivo-map://', AJob.Url)=1 then
  begin
    FOwner.FQueueLock.Enter;
    try
      if(FMapHttp=nil)and(FOwner.FFetcher<>nil)and not Terminated then begin
        FMapHttp:=THTTPFetcherWithCache.Create(FOwner.FFetcher.Cache,False);
        FMapHttp.TimeoutMs:=5000;FMapHttp.MaxRetries:=1;
      end;
    finally FOwner.FQueueLock.Leave;end;
    Img:=nil;
    try Img:=FlatMapTile(FMapHttp,AJob.Z,AJob.X,AJob.Y,AJob.Detail,Self);except Img:=nil;end;
    if(not AJob.Detail)and(AJob.Z>=FLAT_MAP_DETAIL_ZOOM)and not Terminated then begin
      NextJob:=AJob;NextJob.Detail:=True;
      FOwner.FQueueLock.Enter;
      try if AJob.Epoch=FOwner.FEpoch then FOwner.FQueue.Insert(0,NextJob);
      finally FOwner.FQueueLock.Leave;end;
      FOwner.FWake.SetEvent;
    end;
    if(Img=nil)and AJob.Detail then Exit;
    if Img=nil then begin FOwner.WorkerPushResult(Res);Exit;end;
    Res.Root:=FOwner.BuildTileRootNode(Img,AJob.Z,AJob.X,AJob.Y,
      TLatLon.Make(AJob.OriginLat,AJob.OriginLon),AJob.PlaneHeight,AJob.ZoomYStep);
    Res.Ok:=Res.Root<>nil;
  end else begin
  { mime from URL extension — tile servers serve png or jpeg }
  Lower := LowerCase(AJob.Url);
  if (Pos('.jpg', Lower) > 0) or (Pos('.jpeg', Lower) > 0) then
    Mime := 'image/jpeg'
  else
    Mime := 'image/png';

  { Download through the owner's byte cache (project HTTP fetcher) when wired,
    else a direct fetch. Cache hits skip the network entirely, so an
    evicted-then-revisited tile is not re-downloaded. }
  Bytes := nil;
  try
    FOwner.FetchTileBytes(AJob.Url, Bytes);
  except
    on E: Exception do
      Bytes := nil;          { network error — host will retry after a delay }
  end;

  { Decode + assemble the whole tile graph here, off the main thread. None of
    this touches OpenGL or the live scene tree, so it is safe in a worker; the
    main thread only wraps the finished node graph in a TCastleScene. The
    projection comes entirely from the per-job snapshot, never from FProj. }
  if Length(Bytes) > 0 then
  begin
    Img := FOwner.DecodeImage(Bytes, Mime);
    if Img <> nil then
    begin
      try
        Res.Root := FOwner.BuildTileRootNode(
                      Img, AJob.Z, AJob.X, AJob.Y,
                      TLatLon.Make(AJob.OriginLat, AJob.OriginLon),
                      AJob.PlaneHeight, AJob.ZoomYStep);
        Res.Ok := Res.Root <> nil;
      except
        on E: Exception do
        begin
          { build failed → don't leak the image/partial graph }
          if Res.Root <> nil then
            FreeAndNil(Res.Root)
          else
            FreeAndNil(Img);
          Res.Ok := False;
        end;
      end;
    end;
  end;

  end;
  FOwner.WorkerPushResult(Res);
end;

{ ── TOsm3dSlippyMap: construction ─────────────────────────────────── }

constructor TOsm3dSlippyMap.Create(AOwner: TComponent);
var
  I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1673);{$ENDIF}
  inherited Create(AOwner);

  FServerUrl    := FLAT_MAP_URL;
  FUserAgent    := 'Osm3dSlippyMap/1.0 (CGE; +https://github.com/local/osm3d)';
  FFetcher      := nil;     { host may inject a shared cache-aware fetcher }
  FOrigin       := TLatLon.Make(0, 0);
  FMaxTiles     := 160;          { ≈ streets-gl's 150 }
  FMinZoom      := 2;
  FMaxZoom      := 19;
  FPlaneHeight  := 0.0;
  FZoomYStep    := 0.5;          { finer zoom sits 0.5 m higher per level }
  FSpanFactor   := 1.2;          { ≈ 2*tan(half-FOV) for a ~60° vertical FOV }
  FAspect       := 16.0 / 9.0;   { widescreen default until first render }
  FTilesAcross  := 4.0;
  FPrefetchM    := 256.0;
  FUploadBudget := 2;
  FWorkerCount  := 4;            { ≈ streets-gl SlippyMapFetchBatchSize }
  FEvictLag     := 30;
  FRetryDelay   := 120;
  FMinCamHeight := 50.0;
  FEnabled      := True;
  FFrame        := 0;
  FEpoch        := 0;
  FLastZoom     := FMinZoom;

  { route overlay defaults: a translucent orange line ~1% of camera height }
  FRouteColor     := Vector3(1.0, 0.30, 0.0);
  FRouteOpacity   := 0.6;
  FRouteWidthFac  := 0.010;
  FRouteLiftFac   := 0.010;
  FRouteMinWidthM := 2.0;
  FRouteDirty     := False;
  FRouteBuiltZoom := -1;
  FRouteScene     := nil;
  FLastCamHeight  := 1000.0;

  { This transform is decoration: it must never block picking or collide
    with the 3D world above it. }
  Pickable := False;
  Collides := False;

  FProj := TLocalProjection.Create(FOrigin);
  FTiles := specialize TDictionary<Int64, TTileEntry>.Create;

  FQueueLock  := TCriticalSection.Create;
  FQueue      := specialize TList<TSlippyJob>.Create;
  FResultLock := TCriticalSection.Create;
  FResults    := specialize TQueue<TSlippyResult>.Create;
  FWake       := TEvent.Create(nil, False, False, '');

  SetLength(FWorkers, FWorkerCount);
  for I := 0 to FWorkerCount - 1 do
    FWorkers[I] := TSlippyFetchThread.Create(Self);
end;

destructor TOsm3dSlippyMap.Destroy;
var
  I:    Integer;
  E:    TTileEntry;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1674);{$ENDIF}
  { stop workers first so no result lands mid-teardown }
  for I := 0 to High(FWorkers) do
    if FWorkers[I] <> nil then
      FWorkers[I].Cancel;
  if FWake <> nil then
    FWake.SetEvent;                  { wake any idle workers so they exit }
  for I := 0 to High(FWorkers) do
    if FWorkers[I] <> nil then
    begin
      FWorkers[I].WaitFor;
      FWorkers[I].Free;
    end;

  { drop leftover results — each may carry a worker-built graph that no scene
    adopted, so free it to avoid leaks at teardown }
  if FResults <> nil then
    while FResults.Count > 0 do
      DiscardResult(FResults.Dequeue);

  { free tile entries (their scenes are owned by Self and freed with it,
    but free them explicitly here for tidiness/order) }
  if FTiles <> nil then
  begin
    for E in FTiles.Values do
    begin
      if E.Scene <> nil then
      begin
        Remove(E.Scene);
        E.Scene.Free;
        E.Scene := nil;
      end;
      E.Free;
    end;
    FTiles.Free;
  end;

  { route overlay }
  if FRouteScene <> nil then
  begin
    Remove(FRouteScene);
    FreeAndNil(FRouteScene);
  end;

  FResults.Free;
  FResultLock.Free;
  FQueue.Free;
  FQueueLock.Free;
  FWake.Free;
  FProj.Free;

  inherited Destroy;
end;

procedure TOsm3dSlippyMap.SetServerUrl(const AValue: string);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1675);{$ENDIF}
  if FServerUrl = AValue then Exit;
  FServerUrl := AValue;
  Clear;          { tiles from the old server are no longer valid }
end;

procedure TOsm3dSlippyMap.SetOrigin(const AValue: TLatLon);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1676);{$ENDIF}
  if (FOrigin.Lat = AValue.Lat) and (FOrigin.Lon = AValue.Lon) then Exit;
  FOrigin := AValue;
  FreeAndNil(FProj);
  FProj := TLocalProjection.Create(FOrigin);
  FRouteDirty := True;   { the route's local coords depend on the origin too }
  Clear;          { every tile's local position depends on the origin }
end;

procedure TOsm3dSlippyMap.SetEnabled(AValue: Boolean);
var
  E: TTileEntry;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1677);{$ENDIF}
  if FEnabled = AValue then Exit;
  FEnabled := AValue;
  if not FEnabled then
    for E in FTiles.Values do
      if E.Scene <> nil then
        E.Scene.Exists := False;
end;

function TOsm3dSlippyMap.KeyOf(Z, X, Y: Integer): Int64;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1678);{$ENDIF}
  { Биективный числовой ключ slippy-тайла: Z в старших битах, затем X, Y
    (по 30 бит — X,Y < 2^Z при любом реальном зуме). Строка 'z/x/y' для
    URL/кэша строится отдельно (TTileMath.FormatTileUrl). }
  Result := (Int64(Z) shl 60) or (Int64(X) shl 30) or Int64(Y);
end;

function TOsm3dSlippyMap.GetOrCreate(Z, X, Y: Integer): TTileEntry;
var
  K: Int64;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1679);{$ENDIF}
  K := KeyOf(Z, X, Y);
  if not FTiles.TryGetValue(K, Result) then
  begin
    Result := TTileEntry.Create;
    Result.Z := Z; Result.X := X; Result.Y := Y;
    Result.Key := K;
    Result.State := tsIdle;
    Result.Scene := nil;
    Result.LastWantedFrame := 0;
    Result.RetryFrame := 0;
    FTiles.Add(K, Result);
  end;
end;

{ Camera height → slippy zoom. The visible ground span is roughly
  camHeight * SpanFactor; pick the zoom whose tile width is span /
  TilesAcross, the slippy equivalent of streets-gl tying zoom to
  log2(distance). }
function TOsm3dSlippyMap.ChooseZoom(const ACentre: TLatLon; ACamHeight: Single): Integer;
var
  LatRad, GroundSpan, TileTarget, WorldM: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1680);{$ENDIF}
  LatRad := DegToRad(ACentre.Lat);
  GroundSpan := ACamHeight * FSpanFactor;
  if GroundSpan < 1.0 then GroundSpan := 1.0;
  TileTarget := GroundSpan / Max(1.0, FTilesAcross);
  WorldM := EARTH_CIRCUM_M * Cos(LatRad);
  if WorldM < 1.0 then WorldM := 1.0;
  Result := Round(Log2(WorldM / TileTarget));
  if Result < FMinZoom then Result := FMinZoom;
  if Result > FMaxZoom then Result := FMaxZoom;
end;

function TOsm3dSlippyMap.GetCameraView(out ACentre: TLatLon;
  out ACamHeight: Single): Boolean;
var
  Cam: TCastleCamera;
  P:   TVector3;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1681);{$ENDIF}
  Result := False;
  if World = nil then Exit;
  Cam := World.MainCamera;
  if Cam = nil then Exit;

  P := Cam.WorldTranslation;
  ACamHeight := P.Y - FPlaneHeight;
  if ACamHeight < FMinCamHeight then ACamHeight := FMinCamHeight;
  ACentre := FProj.Unproject(P.X, P.Z);
  Result := True;
end;

{ Viewport aspect (width/height), derived from the projection matrix the
  viewport set on the last render. For both perspective and orthographic
  projections aspect = m11/m00 (perspective: m00=f/aspect, m11=f; ortho:
  m00=2/W, m11=2/H → m11/m00 = W/H). Before the first render the matrix is
  identity (→1.0) or garbage, so anything outside a sane range falls back to
  FAspect. This is what fixes partial tiles being dropped at the left/right
  screen edges: the wanted box must be widened horizontally by this ratio. }
function TOsm3dSlippyMap.GetViewportAspect: Single;
var
  M:  TMatrix4;
  M00, M11, A: Single;
begin
  Result := FAspect;
  M := RenderContext.ProjectionMatrix;
  M00 := M.Data[0, 0];
  M11 := M.Data[1, 1];
  if Abs(M00) < 1.0e-6 then Exit;
  A := Abs(M11 / M00);
  if (A > 0.2) and (A < 6.0) then
    Result := A;
end;

procedure TOsm3dSlippyMap.Schedule(AEntry: TTileEntry);
var
  Job: TSlippyJob;
  T:   TTileXY;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1682);{$ENDIF}
  T := TTileXY.Make(AEntry.X, AEntry.Y, AEntry.Z);
  Job.Z := AEntry.Z; Job.X := AEntry.X; Job.Y := AEntry.Y;
  Job.Detail := False;
  Job.Epoch := FEpoch;
  Job.Url := TTileMath.FormatTileUrl(FServerUrl, T);
  { snapshot of projection state for off-thread geometry build }
  Job.OriginLat   := FOrigin.Lat;
  Job.OriginLon   := FOrigin.Lon;
  Job.PlaneHeight := FPlaneHeight;
  Job.ZoomYStep   := FZoomYStep;

  AEntry.State := tsQueued;

  FQueueLock.Enter;
  try
    FQueue.Add(Job);
  finally
    FQueueLock.Leave;
  end;
  FWake.SetEvent;
end;

procedure TOsm3dSlippyMap.MarkWanted(Z, X, Y: Integer);
var
  E: TTileEntry;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1683);{$ENDIF}
  E := GetOrCreate(Z, X, Y);
  E.LastWantedFrame := FFrame;

  case E.State of
    tsBuilt:
      begin
        if E.Scene <> nil then
          E.Scene.Exists := True;
        Exit;                          { have it — no fallback needed }
      end;
    tsIdle:
      Schedule(E);
    tsFailed:
      if FFrame >= E.RetryFrame then
        Schedule(E);
    tsQueued:
      ;                                { already in flight }
  end;

  { Not yet built → keep the area covered by whatever IS already on screen:
    the best coarse ancestor (covers zoom-in and steady loading) AND any
    finer descendants that are still built (covers zoom-out — without this
    the previous, finer level is hidden the moment the new coarse level is
    wanted, blanking the screen until it downloads). The per-zoom Y offset
    layers them, so finer draws over coarser wherever both exist. }
  ShowBestAncestor(Z, X, Y);
  ShowBuiltDescendants(Z, X, Y, FallbackDescendantDepth);
end;

procedure TOsm3dSlippyMap.ShowBestAncestor(Z, X, Y: Integer);
var
  PZ, PX, PY: Integer;
  E:          TTileEntry;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1684);{$ENDIF}
  PZ := Z; PX := X; PY := Y;
  while PZ > FMinZoom do
  begin
    PX := PX div 2;
    PY := PY div 2;
    Dec(PZ);
    if FTiles.TryGetValue(KeyOf(PZ, PX, PY), E) then
      if (E.State = tsBuilt) and (E.Scene <> nil) then
      begin
        E.LastWantedFrame := FFrame;   { keep it alive + visible }
        E.Scene.Exists := True;
        Exit;
      end;
  end;
end;

{ Mirror of ShowBestAncestor for the other direction: cover the wanted tile's
  footprint with finer tiles that are already built. Used as a zoom-out
  fallback so the previous (finer) level stays on screen until the coarser
  wanted tile downloads. Recurses only into the four children that actually
  exist in the registry, so it walks the previously-loaded subtree and nothing
  more; where a child is already built it is shown and recursion stops there. }
procedure TOsm3dSlippyMap.ShowBuiltDescendants(Z, X, Y, ADepth: Integer);
var
  NZ, CX, CY: Integer;
  E:          TTileEntry;
begin
  if ADepth <= 0 then Exit;
  NZ := Z + 1;
  if NZ > FMaxZoom then Exit;

  for CY := 2 * Y to 2 * Y + 1 do
    for CX := 2 * X to 2 * X + 1 do
      if FTiles.TryGetValue(KeyOf(NZ, CX, CY), E) then
      begin
        if (E.State = tsBuilt) and (E.Scene <> nil) then
        begin
          E.LastWantedFrame := FFrame;
          E.Scene.Exists := True;        { this quarter is covered }
        end
        else
          { child known but not built yet → look one level finer for coverage }
          ShowBuiltDescendants(NZ, CX, CY, ADepth - 1);
      end;
end;

{ Free a result that no scene will adopt. The worker may have built a full
  X3D graph (with the decoded image inside it); freeing the root frees the
  whole graph and the image. Safe on nil. }
procedure TOsm3dSlippyMap.DiscardResult(const AResult: TSlippyResult);
var
  R: TX3DRootNode;
begin
  R := AResult.Root;
  if R <> nil then
    R.Free;
end;

{ absorb finished downloads (main thread, budgeted) }

procedure TOsm3dSlippyMap.DrainResults;
var
  Built: Integer;
  Res:   TSlippyResult;
  E:     TTileEntry;
  Have:  Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1685);{$ENDIF}
  Built := 0;
  while Built < FUploadBudget do
  begin
    Have := False;
    FResultLock.Enter;
    try
      if FResults.Count > 0 then
      begin
        Res := FResults.Dequeue;
        Have := True;
      end;
    finally
      FResultLock.Leave;
    end;
    if not Have then Break;

    { stale result from before a Clear / server change → drop it (and free the
      graph the worker built, since no scene will adopt it) }
    if Res.Epoch <> FEpoch then
    begin
      DiscardResult(Res);              { stale: free the worker-built graph }
      Continue;
    end;

    if not FTiles.TryGetValue(KeyOf(Res.Z, Res.X, Res.Y), E) then
    begin
      DiscardResult(Res);              { tile evicted while in flight }
      Continue;
    end;

    if not Res.Ok then
    begin
      E.State := tsFailed;
      E.RetryFrame := FFrame + FRetryDelay;
      Continue;
    end;

    BuildTile(E, Res);
    Inc(Built);
  end;
end;

procedure TOsm3dSlippyMap.BuildTile(AEntry: TTileEntry; const AResult: TSlippyResult);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1686);{$ENDIF}
  { The worker already downloaded, decoded and assembled the X3D graph. The
    only thing left for the main thread is the hand-off to the CGE renderer:
    wrap the node graph in a scene and add it to the tree (this is what must
    not run off-thread). }
  if AResult.Root = nil then
  begin
    AEntry.State := tsFailed;
    AEntry.RetryFrame := FFrame + FRetryDelay;
    Exit;
  end;

  if AEntry.Scene<>nil then begin Remove(AEntry.Scene);FreeAndNil(AEntry.Scene);end;
  AEntry.Scene := SceneFromRoot(AResult.Root);   { scene adopts/owns the graph }
  AEntry.State := tsBuilt;
  Add(AEntry.Scene);
  { Shown/hidden by SweepVisibilityAndEvict according to LastWantedFrame. }
  AEntry.Scene.Exists := (AEntry.LastWantedFrame = FFrame);
end;

procedure TOsm3dSlippyMap.SweepVisibilityAndEvict;
var
  E, Victim:  TTileEntry;
  ColdIdle:   specialize TList<TTileEntry>;
  ColdBuilt:  specialize TList<TTileEntry>;
  BuiltCnt:   Integer;
  I, MinIdx:  Integer;
  MinFrame:   Int64;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1687);{$ENDIF}
  ColdIdle  := specialize TList<TTileEntry>.Create;
  ColdBuilt := specialize TList<TTileEntry>.Create;
  try
    BuiltCnt := 0;

    { First pass: set visibility and collect cold tiles. No mutation of
      FTiles here — eviction happens after the enumeration finishes. }
    for E in FTiles.Values do
    begin
      if E.State = tsBuilt then
      begin
        Inc(BuiltCnt);
        { Wanted this frame (directly or as a shown ancestor) stays on. }
        if E.Scene <> nil then
          E.Scene.Exists := (E.LastWantedFrame = FFrame);
      end;

      { A tile is "cold" once it has been un-wanted for EvictLag frames. }
      if (FFrame - E.LastWantedFrame) > FEvictLag then
      begin
        if E.State = tsBuilt then
          ColdBuilt.Add(E)
        else
          ColdIdle.Add(E);            { idle/failed/queued-but-cold }
      end;
    end;

    { Cold entries that hold no scene cost nothing to keep but clutter the
      registry — reclaim them immediately. (A cold tsQueued is rare: its
      in-flight result will be dropped by the epoch/lookup guard.) }
    for I := 0 to ColdIdle.Count - 1 do
      if ColdIdle[I].State <> tsQueued then
        FreeEntry(ColdIdle[I]);

    { Drop the coldest BUILT tiles until under the MaxTiles cap. Linear
      min-find — cheap at these counts and free of any comparer/closure
      dependency. }
    while (BuiltCnt > FMaxTiles) and (ColdBuilt.Count > 0) do
    begin
      MinIdx := 0;
      MinFrame := ColdBuilt[0].LastWantedFrame;
      for I := 1 to ColdBuilt.Count - 1 do
        if ColdBuilt[I].LastWantedFrame < MinFrame then
        begin
          MinFrame := ColdBuilt[I].LastWantedFrame;
          MinIdx := I;
        end;
      Victim := ColdBuilt[MinIdx];
      ColdBuilt.Delete(MinIdx);
      FreeEntry(Victim);
      Dec(BuiltCnt);
    end;
  finally
    ColdIdle.Free;
    ColdBuilt.Free;
  end;
end;

procedure TOsm3dSlippyMap.FreeEntry(AEntry: TTileEntry);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1688);{$ENDIF}
  if AEntry.Scene <> nil then
  begin
    Remove(AEntry.Scene);
    AEntry.Scene.Free;
    AEntry.Scene := nil;
  end;
  FTiles.Remove(AEntry.Key);
  AEntry.Free;
end;

{ Download one tile's bytes. Called from the worker threads. }
function TOsm3dSlippyMap.FetchTileBytes(const AUrl: string;
  out AData: TBytes): Boolean;
var
  R:      TFetchResult;
  Client: TFPHTTPClient;
  Mem:    TMemoryStream;
begin
  Result := False;
  AData := nil;

  { Preferred: the project's caching HTTP fetcher. Serves from the byte cache
    on a hit (an evicted-then-revisited tile is NOT re-downloaded) and
    fetches+stores on a miss. GetUrl is reentrant — it builds its own client
    per call and the cache is thread-safe — so this is safe from any worker. }
  if FFetcher <> nil then
  begin
    R := FFetcher.GetUrl(AUrl);
    if R.Success and (Length(R.Data) > 0) then
    begin
      AData := R.Data;
      Result := True;
    end;
    Exit;
  end;

  { Fallback when no fetcher was injected: direct, uncached GET. }
  Mem := TMemoryStream.Create;
  Client := TFPHTTPClient.Create(nil);
  try
    try
      Client.AllowRedirect := True;
      Client.AddHeader('User-Agent', FUserAgent);
      Client.Get(AUrl, Mem);
      if (Client.ResponseStatusCode = 200) and (Mem.Size > 0) then
      begin
        SetLength(AData, Mem.Size);
        System.Move(Mem.Memory^, AData[0], Mem.Size);
        Result := True;
      end;
    except
      on E: Exception do
        Result := False;
    end;
  finally
    Client.Free;
    Mem.Free;
  end;
end;

function TOsm3dSlippyMap.DecodeImage(const AData: TBytes;
  const AMime: string): TCastleImage;
var
  S: TMemoryStream;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1689);{$ENDIF}
  Result := nil;
  if Length(AData) = 0 then Exit;
  S := TMemoryStream.Create;
  try
    S.WriteBuffer(AData[0], Length(AData));
    S.Position := 0;
    try
      { CGE's stream loader is LoadImage(Stream, MimeType, AllowedClasses);
        [] means "any TCastleImage descendant is fine". Vampyre не
        потокобезопасен, а тайлы декодируют несколько TSlippyFetchThread
        одновременно — декод под общим замком (Osm3dImageCodecLock). }
      EnterImageCodec;
      try
        Result := LoadImage(S, AMime, []);
      finally
        LeaveImageCodec;
      end;
    except
      on E: Exception do
        Result := nil;                 { corrupt / unexpected payload }
    end;
  finally
    S.Free;
  end;
end;

{ One flat textured quad for a tile, positioned in local metres via the
  shared projection. UVs map each geographic corner to its place in the
  raster (image left=west, top=north), so the tile reads upright from
  above; Solid=False makes it double-sided so winding never matters.
  A tiny per-zoom Y offset keeps overlapping zoom levels from z-fighting
  (finer zoom drawn just above coarser — the streets-gl draw-order idea
  expressed as depth instead of sort order). }
{ Worker-side: assemble the tile's X3D graph from the decoded raster. Pure CPU,
  no OpenGL, no access to the live scene or to FProj — the projection is rebuilt
  locally from the per-job origin snapshot so two threads never share it. Takes
  ownership of AImage (via TPixelTextureNode). Returns a detached TX3DRootNode;
  the caller wraps it in a scene (main thread) or frees it (discard path). }
function TOsm3dSlippyMap.BuildTileRootNode(AImage: TCastleImage; Z, X, Y: Integer;
  const AOrigin: TLatLon; APlaneHeight, AZoomYStep: Single): TX3DRootNode;
var
  Box:      TLatLonBox;
  Tile:     TTileXY;
  Proj:     TLocalProjection;
  Shape:    TShapeNode;
  App:      TAppearanceNode;
  Mat:      TUnlitMaterialNode;
  Tex:      TPixelTextureNode;
  Props:    TTexturePropertiesNode;
  Geo:      TIndexedFaceSetNode;
  Coord:    TCoordinateNode;
  TexCoord: TTextureCoordinateNode;
  Pts:      array[0..3] of TVector3;
  UVs:      array[0..3] of TVector2;
  YPos:     Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1690);{$ENDIF}
  Tile := TTileXY.Make(X, Y, Z);
  Box  := TTileMath.TileToLatLonBox(Tile);
  YPos := APlaneHeight + Z * AZoomYStep;

  { Own projection instance, built from the snapshot origin: identical maths to
    the shared FProj (deterministic in the origin) so tiles line up, but no
    cross-thread sharing. }
  Proj := TLocalProjection.Create(AOrigin);
  try
    { Corners projected to local XZ; Y forced to the map plane.
      Order chosen so the texcoords below stay axis-aligned to geography. }
    Pts[0] := Proj.Project(Box.MinLat, Box.MinLon);  { SW }
    Pts[1] := Proj.Project(Box.MinLat, Box.MaxLon);  { SE }
    Pts[2] := Proj.Project(Box.MaxLat, Box.MaxLon);  { NE }
    Pts[3] := Proj.Project(Box.MaxLat, Box.MinLon);  { NW }
  finally
    Proj.Free;
  end;
  Pts[0].Y := YPos; Pts[1].Y := YPos; Pts[2].Y := YPos; Pts[3].Y := YPos;

  { texcoord (0,0)=image bottom-left=south-west; (1,1)=top-right=north-east.
    This mapping is correct for CGE; the apparent 180° spin was the flat
    camera's up vector, fixed in TStudioMainForm.SetMapMode. }
  UVs[0] := Vector2(0, 0);   { SW }
  UVs[1] := Vector2(1, 0);   { SE }
  UVs[2] := Vector2(1, 1);   { NE }
  UVs[3] := Vector2(0, 1);   { NW }

  Coord := TCoordinateNode.Create;
  Coord.SetPoint(Pts);

  TexCoord := TTextureCoordinateNode.Create;
  TexCoord.SetPoint(UVs);

  Geo := TIndexedFaceSetNode.Create;
  Geo.Coord    := Coord;
  Geo.TexCoord := TexCoord;
  Geo.Solid    := False;                          { double-sided }
  Geo.SetCoordIndex([0, 1, 2, 3, -1]);

  { in-memory raster → texture; clamp so neighbouring tiles never bleed }
  Tex := TPixelTextureNode.Create;
  Tex.FdImage.Value := AImage;                    { ownership transferred }
  Tex.RepeatS := False;
  Tex.RepeatT := False;

  { mipmaps + anisotropy: the map is viewed from far above, so it is
    heavily minified — without these it shimmers badly }
  Props := TTexturePropertiesNode.Create;
  Props.MinificationFilter  := minLinearMipmapLinear;
  Props.MagnificationFilter := magLinear;
  Props.AnisotropicDegree   := 8.0;
  Tex.TextureProperties := Props;

  { unlit: show the raster's own colour, untouched by scene lighting }
  Mat := TUnlitMaterialNode.Create;
  Mat.EmissiveColor := Vector3(1, 1, 1);

  App := TAppearanceNode.Create;
  App.Material := Mat;
  App.Texture  := Tex;

  Shape := TShapeNode.Create;
  Shape.Geometry   := Geo;
  Shape.Appearance := App;

  Result := TX3DRootNode.Create;
  Result.AddChildren(Shape);
end;

{ Main-thread: the only step that must stay on the main thread — wrap the
  worker-built graph in a scene and hand it to the CGE renderer. }
function TOsm3dSlippyMap.SceneFromRoot(ARoot: TX3DRootNode): TCastleScene;
begin
  Result := TCastleScene.Create(Self);
  Result.Load(ARoot, True);            { scene owns the X3D graph }
  Result.ProcessEvents := False;
  Result.Pickable := False;
  Result.Collides := False;
  Result.Exists   := False;            { sweep decides visibility }
end;

{ ── route (FIT/GPX) overlay ─────────────────────────────────────────── }

{ Y plane for the route line. Two competing requirements:
  - close up it must sit just above the highest tile plane so it isn't hidden
    by the map, but not so high that top-down parallax visibly offsets it;
  - far away the gap to the tiles must stay large enough to survive depth-buffer
    precision, or the translucent line loses the depth test and vanishes.
  A fixed lift can't satisfy both, so use the larger of a small fixed base and a
  fraction of the camera height. Because the lift is proportional to distance,
  the depth gap stays a constant fraction of the view depth at every zoom, and
  the parallax stays small (the route is near the view centre when zoomed out). }
function TOsm3dSlippyMap.RouteY(ACamHeight: Single): Single;
var
  Base, Lift: Single;
begin
  Base := FPlaneHeight + (FMaxZoom + 1) * FZoomYStep + 0.05;
  Lift := FPlaneHeight + FRouteLiftFac * ACamHeight;
  if Lift > Base then Result := Lift else Result := Base;
end;

{ Build a translucent ribbon (a constant-width line in the map plane) along the
  route polyline, with mitred joints so corners stay continuous. Pure CPU; the
  caller wraps it in a scene. nil if fewer than two distinct points. }
function TOsm3dSlippyMap.BuildRouteRootNode(AWidthM: Single): TX3DRootNode;
const
  MiterLimit = 4.0;
var
  Y, Half: Single;
  P:    array of TVector3;     { cleaned centreline (XZ at Y) }
  NX, NZ: array of Single;     { per-segment unit left-normal }
  Pts:  array of TVector3;     { 2*m offset points: L,R per vertex }
  Idx:  array of LongInt;      { coordIndex (one quad per segment) }
  V:    TVector3;
  m, i, n: Integer;
  ax, az, bx, bz, mx, mz, len, dotv, mscale: Single;
  Coord: TCoordinateNode;
  Geo:   TIndexedFaceSetNode;
  Mat:   TMaterialNode;
  App:   TAppearanceNode;
  Shape: TShapeNode;
begin
  Result := nil;
  if FProj = nil then Exit;
  { Build the ribbon flat at Y=0. The real height is applied as the route
    scene's Translation.Y every frame (see Update), so it can track the camera
    height continuously without rebuilding the geometry. }
  Y    := 0.0;
  Half := AWidthM * 0.5;

  { 1) project, dropping consecutive duplicates (zero-length segments would
       break the normals) }
  SetLength(P, Length(FRoutePts));
  m := 0;
  for i := 0 to High(FRoutePts) do
  begin
    V := FProj.Project(FRoutePts[i].Lat, FRoutePts[i].Lon);
    V.Y := Y;
    if (m = 0) or
       (Abs(V.X - P[m-1].X) > 1.0e-4) or (Abs(V.Z - P[m-1].Z) > 1.0e-4) then
    begin
      P[m] := V; Inc(m);
    end;
  end;
  SetLength(P, m);
  if m < 2 then Exit;

  { 2) unit left-normal of each segment: dir=(dx,dz) → normal=(-dz,dx) }
  SetLength(NX, m - 1); SetLength(NZ, m - 1);
  for i := 0 to m - 2 do
  begin
    ax := P[i+1].X - P[i].X;
    az := P[i+1].Z - P[i].Z;
    len := Sqrt(ax*ax + az*az);
    if len < 1.0e-6 then len := 1.0e-6;
    NX[i] := -az / len;
    NZ[i] :=  ax / len;
  end;

  { 3) left/right offset point per vertex, with mitred joints }
  SetLength(Pts, 2 * m);
  for i := 0 to m - 1 do
  begin
    if i = 0 then
    begin
      mx := NX[0];   mz := NZ[0];   mscale := Half;
    end
    else if i = m - 1 then
    begin
      mx := NX[m-2]; mz := NZ[m-2]; mscale := Half;
    end
    else
    begin
      ax := NX[i-1]; az := NZ[i-1];           { incoming normal }
      bx := NX[i];   bz := NZ[i];             { outgoing normal }
      mx := ax + bx; mz := az + bz;
      len := Sqrt(mx*mx + mz*mz);
      if len < 1.0e-6 then
      begin
        mx := bx; mz := bz; mscale := Half;    { ~180° reversal }
      end
      else
      begin
        mx := mx / len; mz := mz / len;
        dotv := mx*bx + mz*bz;                { = cos(half turn angle) }
        if dotv < 1.0e-3 then dotv := 1.0e-3;
        mscale := Half / dotv;
        if mscale > Half * MiterLimit then mscale := Half * MiterLimit;
      end;
    end;
    Pts[2*i]   := Vector3(P[i].X + mx*mscale, Y, P[i].Z + mz*mscale);  { L }
    Pts[2*i+1] := Vector3(P[i].X - mx*mscale, Y, P[i].Z - mz*mscale);  { R }
  end;

  { 4) one quad per segment: L[i], L[i+1], R[i+1], R[i] }
  SetLength(Idx, (m - 1) * 5);
  n := 0;
  for i := 0 to m - 2 do
  begin
    Idx[n] := 2*i;         Inc(n);
    Idx[n] := 2*(i+1);     Inc(n);
    Idx[n] := 2*(i+1) + 1; Inc(n);
    Idx[n] := 2*i + 1;     Inc(n);
    Idx[n] := -1;          Inc(n);
  end;

  Coord := TCoordinateNode.Create;
  Coord.SetPoint(Pts);

  Geo := TIndexedFaceSetNode.Create;
  Geo.Coord := Coord;
  Geo.Solid := False;                  { visible from both sides }
  Geo.SetCoordIndex(Idx);

  { flat translucent colour: emissive = line colour, diffuse/specular killed so
    scene lighting can't tint it. Transparency>0 makes CGE alpha-blend it. }
  Mat := TMaterialNode.Create;
  Mat.DiffuseColor  := Vector3(0, 0, 0);
  Mat.SpecularColor := Vector3(0, 0, 0);
  Mat.EmissiveColor := FRouteColor;
  Mat.Transparency  := 1.0 - FRouteOpacity;

  App := TAppearanceNode.Create;
  App.Material := Mat;

  Shape := TShapeNode.Create;
  Shape.Geometry   := Geo;
  Shape.Appearance := App;

  Result := TX3DRootNode.Create;
  Result.AddChildren(Shape);
end;

procedure TOsm3dSlippyMap.RebuildRoute(ACamHeight: Single);
var
  Root: TX3DRootNode;
  W:    Single;
begin
  if FRouteScene <> nil then
  begin
    Remove(FRouteScene);
    FreeAndNil(FRouteScene);
  end;
  if Length(FRoutePts) < 2 then Exit;

  W := FRouteWidthFac * ACamHeight;
  if W < FRouteMinWidthM then W := FRouteMinWidthM;

  Root := BuildRouteRootNode(W);
  if Root = nil then Exit;

  FRouteScene := TCastleScene.Create(Self);
  FRouteScene.Load(Root, True);
  FRouteScene.ProcessEvents := False;
  FRouteScene.Pickable := False;
  FRouteScene.Collides := False;
  FRouteScene.Exists := True;
  FRouteScene.Translation := Vector3(0, RouteY(ACamHeight), 0);  { initial lift }
  Add(FRouteScene);
end;

procedure TOsm3dSlippyMap.SetRoute(const APoints: array of TLatLon);
var
  I: Integer;
begin
  SetLength(FRoutePts, Length(APoints));
  for I := 0 to High(APoints) do
    FRoutePts[I] := APoints[I];

  if Length(FRoutePts) < 2 then
  begin
    ClearRoute;
    Exit;
  end;

  { build immediately with the last known camera height; Update will refine the
    width on the next zoom change }
  RebuildRoute(FLastCamHeight);
  FRouteBuiltZoom := FLastZoom;
  FRouteDirty := False;
end;

procedure TOsm3dSlippyMap.ClearRoute;
begin
  SetLength(FRoutePts, 0);
  FRouteDirty := False;
  FRouteBuiltZoom := -1;
  if FRouteScene <> nil then
  begin
    Remove(FRouteScene);
    FreeAndNil(FRouteScene);
  end;
end;

procedure TOsm3dSlippyMap.Update(const SecondsPassed: Single;
  var RemoveMe: TRemoveType);
var
  Centre:    TLatLon;
  CamHeight: Single;
  Zoom:      Integer;
  Box:       TLatLonBox;
  Tiles:     TTileXYArray;
  ViewAspect: Single;
  HalfV, HalfH, Radius, DLat, DLon, CosLat: Double;
  I:         Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1691);{$ENDIF}
  inherited Update(SecondsPassed, RemoveMe);

  if not FEnabled then Exit;

  Inc(FFrame);

  { build whatever finished downloading (cheap if nothing is ready) }
  DrainResults;

  if not GetCameraView(Centre, CamHeight) then Exit;   { no camera yet }

  Zoom := ChooseZoom(Centre, CamHeight);
  FLastZoom := Zoom;
  FLastCamHeight := CamHeight;

  { keep the translucent route overlay in step: rebuild when it changed or when
    the zoom level changed (its width tracks camera height for a roughly
    constant on-screen thickness). Cheap — only on level changes, not per frame. }
  if (Length(FRoutePts) >= 2) and (FRouteDirty or (Zoom <> FRouteBuiltZoom)) then
  begin
    RebuildRoute(CamHeight);
    FRouteBuiltZoom := Zoom;
    FRouteDirty := False;
  end;

  { lift the (flat-built) route to track the camera height every frame, so its
    depth stays separated from the tiles at any altitude and it never vanishes }
  if FRouteScene <> nil then
    FRouteScene.Translation := Vector3(0, RouteY(CamHeight), 0);

  { Viewport footprint as a lat/lon box, plus a prefetch margin. The screen
    is wider than tall, so the horizontal half-extent must be scaled by the
    viewport aspect — otherwise the box is square in metres and the partial
    tiles at the left/right screen edges are never requested. Vertical extent
    is unchanged. Same metres→degrees math as TLatLonBox.ExpandMeters, but
    with independent horizontal/vertical spans. }
  ViewAspect := GetViewportAspect;
  HalfV  := CamHeight * FSpanFactor * 0.5 + FPrefetchM;
  HalfH  := CamHeight * FSpanFactor * 0.5 * ViewAspect + FPrefetchM;

  Radius := EARTH_CIRCUM_M / (2.0 * Pi);
  DLat   := RadToDeg(HalfV / Radius);
  CosLat := Cos(DegToRad(Centre.Lat));
  if Abs(CosLat) < 1.0e-9 then
    DLon := DLat                       { near the poles cos→0: avoid blow-up }
  else
    DLon := RadToDeg(HalfH / Radius) / CosLat;

  Box := TLatLonBox.Make(Centre.Lat - DLat, Centre.Lon - DLon,
                         Centre.Lat + DLat, Centre.Lon + DLon);

  Tiles := TTileMath.TilesCoveringBox(Box, Zoom);
  for I := 0 to High(Tiles) do
    MarkWanted(Tiles[I].Zoom, Tiles[I].X, Tiles[I].Y);

  SweepVisibilityAndEvict;
end;

procedure TOsm3dSlippyMap.Clear;
var
  E: TTileEntry;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1692);{$ENDIF}
  { bump epoch so in-flight results are discarded when they land }
  FQueueLock.Enter;
  try
    Inc(FEpoch);
    FQueue.Clear;
  finally
    FQueueLock.Leave;
  end;

  FResultLock.Enter;
  try
    while FResults.Count > 0 do
      DiscardResult(FResults.Dequeue);   { free any graph the worker built }
  finally
    FResultLock.Leave;
  end;

  for E in FTiles.Values do
  begin
    if E.Scene <> nil then
    begin
      Remove(E.Scene);
      E.Scene.Free;
      E.Scene := nil;
    end;
    E.Free;
  end;
  FTiles.Clear;
end;

function TOsm3dSlippyMap.WorkerPopJob(out AJob: TSlippyJob): Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1694);{$ENDIF}
  Result := False;
  FQueueLock.Enter;
  try
    if FQueue.Count > 0 then
    begin
      { pop the most-recently-queued job: that is the freshest wanted
        tile, so the visible area fills in first }
      AJob := FQueue[FQueue.Count - 1];
      FQueue.Delete(FQueue.Count - 1);
      Result := True;
    end;
  finally
    FQueueLock.Leave;
  end;
end;

procedure TOsm3dSlippyMap.WorkerPushResult(const AResult: TSlippyResult);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1695);{$ENDIF}
  FResultLock.Enter;
  try
    FResults.Enqueue(AResult);
  finally
    FResultLock.Leave;
  end;
end;

end.
