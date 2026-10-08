unit Osm3dStreamingLauncher;

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$codepage UTF8}

interface

uses
  SysUtils,
  CastleVectors,
  Osm3dGeoMath,
  Osm3dGeoTileGrid,
  Osm3dMapUtils,
  Osm3dCache,
  Osm3dCacheHTTPFetcher,
  Osm3dStudioSettings,
  Osm3dStudioLog,
  Osm3dHeightmap,        { TTerrariumFetcher — shared height provider }
  Osm3dOsmOverpass,      { TOverpassClient — shared OSM provider }
  Osm3dFitHeightLayer,   { TFitHeightLayer — второй слой высот фетчера }
  Osm3dFitLayerBuild,    { BuildFitHeightLayer — сборка слоя из папки заездов }
  Osm3dStreamingMap
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
;

type
  { Owns the full streaming stack for one session. }
  TOsm3dStreamingSession = class
  private
    FMemCache:  TMemoryCache;       { layers are owned by FCache }
    FDiskCache: TFileSystemCache;
    FCache:     TCompositeCache;    { SHARED byte cache — session-owned }
    FHttp:      THTTPFetcherWithCache;   { general fetcher (aux camera queries) }
    FHttpHeight:   THTTPFetcherWithCache;  { terrarium-config fetcher over FCache }
    FHttpOverpass: THTTPFetcherWithCache;  { overpass-config fetcher over FCache }
    FTerrFetcher:  TTerrariumFetcher;      { long-lived shared height provider }
    FOverpass:     TOverpassClient;        { long-lived shared OSM provider }
    FMap:       TOsm3dStreamingMap;
    FLog:       TLogTarget;         { worker-thread target — owned }
    FMainLog:   TLogTarget;         { main-thread target — owned;
                                      TFileLogTarget, never Synchronizes }
    FGenHash:   string;
    FCacheRoot: string;
  public
    { ASettings is the (frozen) configuration; AOrigin is the local
      projection origin — it stays fixed for the session's lifetime.
      ALogCallback, if assigned, receives every formatted log line
      (already marshalled to the main thread by TCallbackLogTarget) —
      wire it to the program's existing log memo.
      AStartUTC is the route's start time (UTC). It drives the sun
      direction the block generator uses for ground shadows; pass the
      route timestamp (e.g. TOsm3dMapTransform.RouteStartUTC). 0 = no
      timestamp — use the world's canonical daytime sun. Real nighttime
      timestamps retain the existing absence of directed shadow atlases.
      ARoute is the FIT route to overlay as marker spheres; each tile
      shows its own slice as it streams in. Empty = no overlay.
      ARoutesFolder/ASelectedFit (опционально): папка заездов и выбранный
      файл. Заданы → FIT-СЛОЙ ВЫСОТ строится ЗДЕСЬ (синхронно, до генерации
      тайлов), ставится в фетчер и его сигнатура входит в gen-hash — так
      корректированная геометрия консистентна с дисковым кэшем. Для боевого
      пути (коррекция мешей) папку НАДО передать сюда. Пусто → слой не
      строится в Create (страница маршрутов ставит его сама, без коррекции
      мешей, через Map.SetRoutesFolder). }
    { Эффективный корень кэша: ASettings.CacheRoot или temp/osm3d-cache.
      Единый источник пути — под ним лежат и кэш тайлов, и байтовый http-кэш. }
    class function EffectiveCacheRoot(const ASettings: TStudioSettings): string;
    constructor Create(const ASettings: TStudioSettings;
                       const AOrigin: TLatLon;
                       ALogCallback: TLogLineCallback = nil;
                       AStartUTC: TDateTime = 0;
                       const ARoute: TRouteLatLonArray = nil;
                       const ARouteAltM: TRouteAltArray = nil;
                       const ARoutesFolder: string = '';
                       const ASelectedFit: string = '');
    destructor Destroy; override;

    { Add this to a CGE viewport: Viewport.Items.Add(Session.Map). }
    property Map:       TOsm3dStreamingMap read FMap;

    { Camera/world XZ -> geographic lat/lon, via the session's fixed
      local projection. Lets the host overlay show camera coordinates
      without importing Osm3dStreamingMap directly. }
    function CameraGeo(LocalX, LocalZ: Single): TLatLon;
    { Гео lat/lon → мировые XZ в системе координат сессии. Позволяет хосту
      перенести камеру в географическую точку без пересоздания сессии. }
    function GeoToLocal(const ALL: TLatLon): TVector3;
    { Tile id covering camera/world XZ as a display string (matches the
      shadow-log tile names). Proxies to the map's pinned tile lattice. }
    function CameraTileName(LocalX, LocalZ: Single): string;
    { Raw Overpass JSON the current camera tile was built from (cache
      only, no network). Proxies to the map. }
    function CameraTileOsmJson(LocalX, LocalZ: Single): string;
    { Parsed + frustum-filtered OSM listing for the current camera tile
      (only what is on screen). Proxies to the map; cache only. }
    function CameraScreenFeatures(LocalX, LocalZ: Single;
      const CamPos, CamDir, CamUp: TVector3;
      AspectWH, FovYRad, NearM, FarM, Margin: Single): string;
    { Text table of the source AWS heights over the camera's current geo-tile.
      Proxies to the map; fetches/stitches terrarium tiles for the tile box
      and samples them on a dense (≈ native-pixel) grid. }
    function CameraTileHeights(LocalX, LocalZ: Single): string;
    { Shared HTTP fetcher — exposed for diagnostics / event hooks.
      Streaming terrain/OSM traffic now flows through the per-domain
      fetchers below (each over the same byte cache, with independent
      timeout/retries/validator), so net-event handlers must subscribe to
      THESE, not Http, to see streaming activity. }
    property Http:         THTTPFetcherWithCache read FHttp;
    property HttpHeight:   THTTPFetcherWithCache read FHttpHeight;
  private
    { валидатор терариум-ответов: только настоящий PNG попадает в кэш }
    function ValidateTerrariumPng(Sender: TObject; const URL: string;
      const Bytes: TBytes; const ContentType: string): string;
  public
    property HttpOverpass: THTTPFetcherWithCache read FHttpOverpass;
    property GenHash:   string read FGenHash;
    property CacheRoot: string read FCacheRoot;
  end;

{ Generator hash for the on-disk tile cache — built from the geo-tile edge and the geometry-
  affecting feature flags. Stable for a config; changes when a geometry-affecting setting changes.
  Bump GEN_CODE_VERSION on any geometry/assembly change. AFitSig — сигнатура набора заездов
  (FIT-слой печётся в геометрию), пусто = без коррекции. }
function ComputeGenHash(const ASettings: TStudioSettings;
                        AEdgeMeters: Double;
                        const AFitSig: string = '';
                        ARouteOnly: Boolean = False;
                        const ARouteName: string = '';
                        ARouteRadiusM: Double = 0): string;

implementation

uses
  md5, TreeForestRegions, Osm3dOsmDirectory; { Osm3dMapUtils is in the interface uses }

{ Ключевая часть метрики востока: маркер авто-режима или число фиксации. }
function WslKey(const ASettings: TStudioSettings): string;
begin
  if (ASettings.WorldScaleLatDeg > -90.0) and (ASettings.WorldScaleLatDeg < 90.0)
     and (ASettings.WorldScaleLatDeg <> 0.0) then
    Result := Format('wsl=%.6f|', [ASettings.WorldScaleLatDeg])
  else
    Result := 'wsl=tile-band|';
end;

function ComputeGenHash(const ASettings: TStudioSettings;
  AEdgeMeters: Double; const AFitSig: string;
  ARouteOnly: Boolean; const ARouteName: string;
  ARouteRadiusM: Double): string;
const
  { Bump GEN_CODE_VERSION whenever a change to the geometry/assembly
    code alters what gets baked into a tile — it invalidates the whole
    on-disk tile cache so stale tiles are not read back. }
  GEO_HASH_SALT   = 'osm3d-geo-tiles/v1';
  GEN_CODE_VERSION = 53;  { 53: complete building-part partitions replace, never overlap, parent outlines. 52: exterior facade alignment from either photo edge direction. 51: initialized roof source IDs; photo parts, areas and shared street details. 50: rowan and typed fruit variants; regional rowan admixture. 49: streams and culverts preserve ground roads; water/FIT masks share road priority. 48: omit crossing speed bumps and their warnings where they overlap another road. 47: compact crossing approaches and board/post clearance. 46: crossing sign UV orientation and junction-safe verge placement. 45: mapped pedestrian crossings, road sign atlas and physical speed bumps. 44: full-size manhole surrounds and exact image aspect. 43: precise manhole placement and pavement alignment. 42: cached sewer manhole placements on finished ground. 41: flat lakes, transverse river profiles and welded banks. 40: метрика востока — от географии САМОГО блока (полоса ln-cos широты его центра; ручная фиксация Settings.WorldScaleLatDeg по-прежнему возможна): тайл — чистая функция id, кэш универсален (сессионные входы из ключа убраны, авто-режим — маркер tile-band); стык соседних полос выравнивает монтирование пер-тайловым масштабом X (Osm3dSceneAssembler, Kx=cos(кадр)/cos(полосы тайла), внутри полосы ровно 1.0). 39: метрика мира = полоса ln-cos от широты (ε=1%, потолок ошибки 0.5% на всей планете) или ручная фиксация Settings.WorldScaleLatDeg; расстановка (Osm3dSceneAssembler.AssembleCachedTiles) получает ту же широту параметром — на 38 она осталась на широте origin и щель вылезла даже в Студии. 38: метрика мира отвязана от маршрута — ScaleLat и якорь int-решётки берутся из Settings.WorldScaleLatDeg и глобальной точки (SLat,0), а не от origin сессии; Студия и игра печут/читают одни тайлы (была щель 1.33 м по востоку на ребре 500 м). 37: откат 36 (отступ выреза не нужен — геометрия у стыка была ровной) + нормали поднятого края дороги у стыка: в проходе нормалей прижим к кромке настила действует и на мостовую сторону, градиентные сэмплы ±EPS не пересекают обрыв выреза — край был с нормалями обрыва (тёмная полоса «как провал»). 36: (отменён) отступ выреза от торцов. 35: FIT-мост сварен с дорогой «одной геометрией» (TDeckJoint). 34: кап-гейт выравнивания. 33: настил следует FIT-профилю заезда }
var
  S: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(827);{$ENDIF}
  { Canonical tile-cache key — every geometry-affecting input that changes
    WHAT gets baked into a tile must appear here. }
  S := GEO_HASH_SALT + '|' +
    Format('gen=%d|', [GEN_CODE_VERSION]) +
    { Набор заездов FIT: коррекция высот печётся в узлы террейна, поэтому
      сгенерированный тайл зависит от него. Смена .fit → смена сигнатуры →
      регенерация корректированных тайлов; пусто = без коррекции. }
    Format('fit=%s|', [AFitSig]) +
    Format('edge=%.1f|', [AEdgeMeters]) +
    { Метрика востока. АВТО ('tile-band'): широта масштаба — полоса ln-cos
      от широты САМОГО БЛОКА, т.е. детерминированная функция id тайла —
      сессионного входа нет, кэш универсален, и в ключе достаточно маркера
      режима. РУЧНАЯ фиксация: число вшито в вершины всех тайлов → в ключ.
      (Origin сессии в ключ НЕ входит и не должен.) }
    WslKey(ASettings) +
    Format('b%d r%d t%d l%d w%d f%d|',
      [Ord(ASettings.GenerateBuildings),
       Ord(ASettings.GenerateRoads),
       Ord(ASettings.GenerateTrees),
       Ord(ASettings.GenerateLanduse),
       Ord(ASettings.GenerateWaterways),
       Ord(ASettings.GenerateFarTerrain)]) +
    { These change WHAT lands in a tile (composite vs separate meshes,
      water folded vs standalone), so they must be part of the key. }
    Format('gc%d gs%d gm%d ws%d|',
      [Ord(ASettings.UseGroundComposition),
       Ord(ASettings.UseGroundCompositionShader),
       Ord(ASettings.UseGroundCompositionMaterialIdAttribute),
       Ord(True)]) +
    { Geometry Z-lift constants (Osm3dGeoMath) — baked into vertex Y,
      so a change must invalidate the tile cache. }
    Format('lift=%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.1f,%.5f',
      [ROAD_LIFT_M, WATER_LIFT_M, RAILWAY_LIFT_M, LANDUSE_LIFT_M,
       INTERSECTION_LIFT_M, BUILDING_FOUNDATION_LIFT_M,
       FAR_BIAS_START_M, FAR_BIAS_SLOPE]);
  { Режим «только коридор пути»: тайлы этого режима держим в ОТДЕЛЬНОМ
    ключевом пространстве дискового кэша (хэш имени .fit + радиус коридора),
    чтобы они не смешивались с тайлами полного мира. Компонент добавляется
    ТОЛЬКО когда режим включён — в выключенном режиме строка ключа байт-в-байт
    прежняя, поэтому существующий кэш не инвалидируется. }
  { rclip = версия отсечения геометрии по коридору ВНУТРИ тайла (террейн/земля
    + фильтр OSM-фич). Бампать при изменении правил отсечения — инвалидирует
    ТОЛЬКО route-only тайлы (полный мир не задет). }
  if ARouteOnly then
    S := S + Format('|routeonly=1|rclip=1|rname=%s|rrad=%.1f',
      [LowerCase(MD5Print(MD5String(ARouteName))), ARouteRadiusM]);
  S := S + '|road-width-profile=2';
  S := S + '|road-smoothness=1'; { persisted asphalt wear profile }
  { Source, sampling resolution and filtering all affect baked terrain. }
  S := S + '|height-source=' + HeightDatasetCacheKey(ASettings.TerrariumUrlTemplate)
    + Format('|height-zoom=%d|height-blur=%.5f',
      [ASettings.HeightmapZoom, ASettings.BlurHeightmapSigmaPx]);
  S := S + '|building-area-levels=3';
  S := S + '|roof-surfaces=2'; { outward faces, clipped ridges and closed gables }
  S := S + '|fence-grounding=1'; { barriers follow leveled roads and tunnel ramps }
  S := S + '|bridge-local-joints=1'; { metric approach sampling and bounded ramps }
  S := S + '|terrain-profile-seams=1'; { preserve mountain grades; geographic border matching }
  S := S + '|water-body-scale=3|coastline-sea=2';
  S := S + '|multipolygon-holes=2'; { shared ownership, including building courtyards }
  S := S + '|vertex-pool-index=2'; { mixed insertion and spatial index invalidation }
  S := S + '|road-join-level=1'; { preserve the outside wedge of connected road bends }
  S := S + '|terrain-decimation-height=1'; { retain relief inside coarse landuse/terrain blocks }
  if ASettings.GenerateTrees then
    S := S + Format('|forest-regions=%d', [FOREST_REGION_VERSION]);
  { Block bounds affect baked terrain, ownership and preview textures.
    EdgePx already separates cache directories; block size must separate
    their hashes as well. Preserve the existing 1x1 cache namespace. }
  if ASettings.LOD.GeoBlockSize <> 1 then
    S := S + Format('|geo-block=%d', [ASettings.LOD.GeoBlockSize]);
  Result := LowerCase(MD5Print(MD5String(S)));
end;

class function TOsm3dStreamingSession.EffectiveCacheRoot(
  const ASettings: TStudioSettings): string;
begin
  Result := Trim(ASettings.CacheRoot);
  if Result = '' then
    Result := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'osm3d-cache';
end;

constructor TOsm3dStreamingSession.Create(const ASettings: TStudioSettings;
  const AOrigin: TLatLon; ALogCallback: TLogLineCallback;
  AStartUTC: TDateTime; const ARoute: TRouteLatLonArray;
  const ARouteAltM: TRouteAltArray;
  const ARoutesFolder: string; const ASelectedFit: string);
var
  FitSig:   string;
  FitLayer: TFitHeightLayer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1263);{$ENDIF}
  inherited Create;

  { Worker-thread log — TCallbackLogTarget formats each line, appends it
    to the log file and forwards it to the callback, marshalling to the
    main thread (TThread.Synchronize) when the write came from a worker.
    nil callback = file only. }
  FLog := TCallbackLogTarget.Create(ALogCallback, llInfo);

  { Main-thread log — TFileLogTarget writes ONLY to the file: no
    callback, no Synchronize, no shared lock that a worker could be
    holding mid-Synchronize. That makes it safe to call from Update,
    where TCallbackLogTarget would risk a deadlock. Empty path -> the
    same osm3d.log; RawAppendToFile serialises both targets through one
    global mutex, so interleaved writes from the two are safe. }
  FMainLog := TFileLogTarget.Create('', llInfo);

  { Resolve the cache root once — the raw byte cache and the geo-tile
    cache both live under it. }
  FCacheRoot := EffectiveCacheRoot(ASettings);

  { Raw byte cache (heightmap PNGs, Overpass responses): a RAM LRU over a
    disk store. This ONE cache is SHARED by every fetcher below (so disk/
    memory dedup is global), but the volatile per-request config
    (TimeoutMs / MaxRetries / OnValidateResponse) is independent per
    fetcher — which removes the cross-domain race where an Overpass
    validator on the shared fetcher rejected concurrent terrarium PNGs and
    thrashed their cache entries. The session owns FCache now (AOwnsCache=
    False on each fetcher). }
  FMemCache  := TMemoryCache.Create(ASettings.MemoryCacheBytes);
  FDiskCache := TFileSystemCache.Create(FCacheRoot);
  FCache     := TCompositeCache.Create([FMemCache, FDiskCache]);

  FHttp         := THTTPFetcherWithCache.Create(FCache, False);  { general / aux }
  FHttpHeight   := THTTPFetcherWithCache.Create(FCache, False);  { terrarium }
  FHttpOverpass := THTTPFetcherWithCache.Create(FCache, False);  { overpass }

  { Height fetcher config: small tiles, short timeout, a couple of retries — permanent and safe
    because nothing else shares this fetcher's config.
    PNG-валидатор обязателен: CDN/прокси/captive portal умеют отдавать 200
    с HTML-заглушкой, а обрыв соединения — огрызок тела. Без проверки такой
    ответ ложился в ОБЩИЙ дисковый кэш под ключ тайла навсегда: все
    последующие запросы били в кэш (сеть не спрашивалась), decode вечно
    падал, GetRegion(z13) возвращал nil — и превью тайла жило на грубом
    z10 при живой сети: вечные ступени высот на швах с z13-соседями.
    Валидатор отсекает мусор ДО записи в кэш, а на битом кэш-хите фетчер
    удаляет запись и уходит в сеть тем же вызовом (см. FetchInternal). }
  FHttpHeight.TimeoutMs  := 5000;
  FHttpHeight.MaxRetries := 2;
  FHttpHeight.OnValidateResponse := @ValidateTerrariumPng;

  { Long-lived, session-shared data providers (the extended fetchers).
    Created ONCE so their decoded-tile / parsed-fragment caches span all
    blocks and previews — a per-block cache would never get a hit. The
    Overpass client installs its JSON validator + retries=1 on its OWN
    fetcher (FHttpOverpass), so terrarium is unaffected. }
  FTerrFetcher := TTerrariumFetcher.Create(FHttpHeight,
                    ASettings.TerrariumUrlTemplate, HEIGHT_TILE_CACHE_MAX);

  FOverpass := TOverpassClient.Create(FHttpOverpass,
                 ASettings.OverpassEndpoints, OVERPASS_FRAG_CACHE_MAX);
  if Trim(ASettings.OverpassEndpoints) = '' then
  begin
    FOverpass.Endpoints.Clear;
    FOverpass.Endpoints.Add(ASettings.OverpassEndpoint);
  end;
  FOverpass.TileZoom := ASettings.OverpassTileZoom;
  FOverpass.TimeoutS := ASettings.OverpassTimeoutS;
  FOverpass.Log      := FLog;

  { ── FIT-слой высот (физика езды, НЕ меши) ─────────────────────────────
    Если папка заездов задана — строим слой СИНХРОННО здесь: пофайловый
    датум + CSV-кэш (первый прогон тянет DEM из сети один раз, дальше
    секунды). Дальше слой идёт ТОЛЬКО в физический слот карты
    (Map.SetFitPhysLayer → GroundYAt физики колёс): это рантайм-поправка
    к высоте земли под райдером. В фетчер (SetFitLayer) слой больше НЕ
    ставится и его сигнатура в gen-hash НЕ входит — меши, тайлы и
    дисковый кэш остаются сырыми и от списка фитов не зависят.

    ASettings.FitHeightCorrection=False → слой не строим вообще, физика
    едет по сырому Terrarium. }
  FitSig := '';   { всегда пусто: слой в хэш тайлов больше не входит }
  FitLayer := nil;
  if (ARoutesFolder <> '') and ASettings.FitHeightCorrection then
  begin
    FitLayer := TFitHeightLayer.Create;
    { Route-only: слой строится ТОЛЬКО из выбранного заезда — коридор идёт по
      текущему FIT без подмеса чужих проходов (см. Osm3dFitLayerBuild). }
    FMainLog.Write(llInfo, '[fitlayer] ' + BuildFitHeightLayer(
      ARoutesFolder, ASelectedFit, FTerrFetcher, ASettings.HeightmapZoom,
      FitLayer, nil, ASettings.GenerateRouteOnly));
  end;

  { Route-only режим: имя выбранного .fit (+радиус коридора) входит в gen-hash,
    поэтому маршрутные тайлы получают отдельный ключ дискового кэша. }
  FGenHash := ComputeGenHash(ASettings, GEO_TILE_EDGE_M, FitSig,
                ASettings.GenerateRouteOnly, ASelectedFit,
                ASettings.RouteOnlyRadiusM);

  { The streaming map builds its own TGeoTileCache (under FCacheRoot),
    TTileStreamer and TOsm3dBlockGenerator. Owner=nil — the session
    owns it and frees it in Destroy. The shared providers are passed in so
    the block generator and the preview builder both use them. }
  FMap := TOsm3dStreamingMap.Create(nil, AOrigin, FCacheRoot, FGenHash,
                                    FHttp, FTerrFetcher, FOverpass,
                                    ASettings, FLog, FMainLog, AStartUTC);

  { Hand the FIT route to the map so each tile materialises its own
    slice of marker spheres as it streams in. The altitude track (if any)
    rides alongside for the blue "original height" spheres. }
  FMap.SetRoute(ARoute, ARouteAltM);

  { Физический слот карты: слой, построенный выше, обслуживает GroundYAt
    физики колёс (владение переходит карте). На тайлы/кэш не влияет. }
  if FitLayer <> nil then
    FMap.SetFitPhysLayer(FitLayer);

  { Папка заездов известна на Create → отдаём её карте, чтобы off-thread
    путь досчитал ГОЛУБЫЕ высоты (FRouteAltCal) для сфер/CSV и, если
    физический слот пуст (FitHeightCorrection=False, но хост разрешил
    построение), поставил туда воркерский слой.

    FitLayerBuild — гейт построения слоя в воркере карты: при
    FitHeightCorrection=False воркерский датум всей папки не нужен
    (слой всё равно никуда не пойдёт) — строим только голубой профиль. }
  FMap.FitLayerBuild := ASettings.FitHeightCorrection;
  if ARoutesFolder <> '' then
    FMap.SetRoutesFolder(ARoutesFolder, ASelectedFit);
end;

destructor TOsm3dStreamingSession.Destroy;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1264);{$ENDIF}
  { Map first: its destructor frees the streamer, which joins every
    worker thread. After that no background code can touch the providers,
    the fetchers, the caches or FLog, so they are safe to free. }
  FreeAndNil(FMap);

  { Providers before their fetchers: TOverpassClient.Destroy restores the
    validator/retries it installed on FHttpOverpass. }
  FreeAndNil(FTerrFetcher);
  FreeAndNil(FOverpass);

  { Fetchers before the cache: none of them owns FCache (AOwnsCache=False),
    so the session frees the shared cache (and its two layers) explicitly. }
  FreeAndNil(FHttp);
  FreeAndNil(FHttpHeight);
  FreeAndNil(FHttpOverpass);
  FreeAndNil(FCache);            { frees FMemCache + FDiskCache }
  FMemCache  := nil;
  FDiskCache := nil;

  { Logs last — only now is it certain neither a worker thread nor the
    map's Update can still write. }
  FreeAndNil(FLog);
  FreeAndNil(FMainLog);

  inherited Destroy;
end;

function TOsm3dStreamingSession.CameraGeo(LocalX, LocalZ: Single): TLatLon;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1696);{$ENDIF}
  Result := FMap.CameraGeo(LocalX, LocalZ);
end;

function TOsm3dStreamingSession.GeoToLocal(const ALL: TLatLon): TVector3;
begin
  Result := FMap.GeoToLocal(ALL);
end;

function TOsm3dStreamingSession.CameraTileName(LocalX, LocalZ: Single): string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1697);{$ENDIF}
  Result := FMap.CameraTileName(LocalX, LocalZ);
end;

function TOsm3dStreamingSession.CameraTileOsmJson(LocalX, LocalZ: Single): string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1698);{$ENDIF}
  Result := FMap.CameraTileOsmJson(LocalX, LocalZ);
end;

function TOsm3dStreamingSession.CameraScreenFeatures(LocalX, LocalZ: Single;
  const CamPos, CamDir, CamUp: TVector3;
  AspectWH, FovYRad, NearM, FarM, Margin: Single): string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1699);{$ENDIF}
  Result := FMap.CameraScreenFeatures(LocalX, LocalZ,
    CamPos, CamDir, CamUp, AspectWH, FovYRad, NearM, FarM, Margin);
end;

function TOsm3dStreamingSession.CameraTileHeights(LocalX, LocalZ: Single): string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1700);{$ENDIF}
  Result := FMap.CameraTileHeights(LocalX, LocalZ);
end;

function TOsm3dStreamingSession.ValidateTerrariumPng(Sender: TObject;
  const URL: string; const Bytes: TBytes;
  const ContentType: string): string;
begin
  { Магические байты PNG — та же дисциплина, что в warm-up overlay:
    Content-Type от CDN не доверяем, смотрим тело. }
  if (Length(Bytes) >= 8)
     and (Bytes[0] = $89) and (Bytes[1] = $50)
     and (Bytes[2] = $4E) and (Bytes[3] = $47)
     and (Bytes[4] = $0D) and (Bytes[5] = $0A)
     and (Bytes[6] = $1A) and (Bytes[7] = $0A) then
    Result := ''
  else
    Result := Format('terrarium: not a PNG (%d bytes, Content-Type=%s)',
      [Length(Bytes), ContentType]);
end;

end.
