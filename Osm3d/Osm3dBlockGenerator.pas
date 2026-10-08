unit Osm3dBlockGenerator;

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$codepage UTF8}
{$WARN 5024 OFF}    { silence unused-parameter notes on the callback shape }

interface

uses
  Classes,
  SysUtils,
  Generics.Collections,                { фильтр датасета по коридору (route-only) }
  CastleVectors,
  Osm3dGeoMath,
  Osm3dGeoTileGrid,
  Osm3dGeoTileBlock,
  Osm3dCacheHTTPFetcher,
  Osm3dCache,                          { TCacheBase — cache-only OSM JSON readout }
  Osm3dHeightmap,
  Osm3dOsmData,
  Osm3dOsmOverpass,
  Osm3dChunk,
  Osm3dGeomBuilder,
  Osm3dGeomTerrain,                    { TRouteCorridor — коридор маршрута }
  Osm3dGeomVegetation,
  Osm3dGeomSurface,      { TLanduseMeshes — for SceneInput.Landuse.FreeAll }
  Osm3dSceneAssembler,
  Osm3dTileX3D, Osm3dWaterProfile, Osm3dCoastline,
  Osm3dTilePreview,
  Osm3dStudioLog,
  Osm3dStudioSettings,
  Osm3dFitHeightLayer,
  Osm3dTileStreamer, Osm3dKnowledgeRecipe
  {$IFDEF TILE_MEM_PROFILE}, Osm3dTileMemProfile{$ENDIF}
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
;

type
  { Block generation pipeline; one instance shared by worker threads, GenerateBlock is re-entrant. }
  { Колбэк фазы: вызывается из ВОРКЕРА при смене стадии генерации блока. }
  TBlockPhaseEvent = procedure(const ABlock: TBlockId; APhase: TBlockPhase;
    const Stage: string; Completed, Total: Int64) of object;

  TOsm3dBlockGenerator = class
  private
    FHttp:       THTTPFetcherWithCache;   { shared, not owned — aux camera queries }
    FTerrFetcher: TTerrariumFetcher;      { shared height provider, not owned }
    FOverpass:    TOverpassClient;        { shared OSM provider, not owned }
    FSettings:   TStudioSettings;         { frozen snapshot }
    FGenHash:    string;
    FRecipes: TKnowledgeRecipeSnapshot; { borrowed from the cache; immutable }
    FEdgeMeters: Double;
    FBlockSize:  Integer;
    FSunDir:     TVector3;
    FLog:        TLogTarget;              { not owned — supplied by host }
    FOnPhase:    TBlockPhaseEvent;         { not owned — progress sink }
    { Режим «геометрия только вдоль пути FIT». FRoutePts — сырой маршрут
      (lat/lon), ставится один раз главным потоком (SetRouteCorridor) до
      генерации; воркеры читают только на чтение. Для КАЖДОГО блока строится
      локальный TRouteCorridor из точек маршрута в его halo. }
    FRouteOnly:    Boolean;
    FRouteRadiusM: Single;
    FRoutePts:     array of TLatLon;
    { Коридор маршрута для одного блока (nil, если маршрут не задевает блок). }
    function BuildBlockCorridorFor(const ABlockOrigin: TLatLon;
      AScaleLat: Double; const AHaloBox: TLatLonBox): TRouteCorridor;
    { Широта метрики востока (cos) для ЭТОГО БЛОКА. Функция ГЕОГРАФИИ БЛОКА,
      сессия не участвует вовсе: ручная фиксация из настроек, иначе полоса
      ln-cos от широты ЦЕНТРА БЛОКА (WorldScaleLatBand). Тайл — чистая
      функция своего id: кэш универсален, ключу не нужен ни origin, ни
      «мировая широта» сессии. Соседи в одной полосе делят метрику побитно
      (сварка/фаза 1/64 м как раньше); редкий стык полос выравнивает
      монтирование пер-тайловым масштабом X (Osm3dSceneAssembler). }
    function EffScaleLat(const ABlockCenter: TLatLon): Double;
  public
    { AHttp not owned; ASettings copied (frozen). AGenHash/AEdgeMeters/ABlockSize
      must match the streamer's cache hash, grid edge and block size. }
    constructor Create(AHttp: THTTPFetcherWithCache;
      ATerrFetcher: TTerrariumFetcher; AOverpass: TOverpassClient;
      const ASettings: TStudioSettings; const AGenHash: string;
      AEdgeMeters: Double; ABlockSize: Integer = 0);

    { Assign to TTileStreamer.OnGenerateBlock; runs on a worker thread. }
    function GenerateBlock(const ABlock: TBlockId;
      const AHaloBox: TLatLonBox; const AOrigin: TLatLon;
      ACancel: PBoolean): TBlockGenResult;

    { Route-only: задать сырой маршрут (lat/lon) + радиус коридора. Когда
      AEnabled и маршрут непуст, GenerateBlock строит на каждый блок коридор,
      фильтрует OSM-датасет (фичи целиком вне коридора выбрасываются) и режет
      террейн/земляной композит по коридору. Звать до старта генерации
      (главный поток); воркеры читают маршрут только на чтение. }
    procedure SetRouteCorridor(const ARoute: array of TLatLon;
      ARadiusM: Single; AEnabled: Boolean);

    { Raw Overpass JSON for the tiles covering ABox, read from the HTTP cache only
      (never the network), concatenated with per-tile headers. Main-thread safe. }
    function CachedOsmJsonForBox(const ABox: TLatLonBox): string;

    { Cached Overpass JSON covering ABox parsed into a fresh dataset (cache only).
      Caller owns/frees; nil when nothing relevant is cached. }
    function CachedOsmDatasetForBox(const ABox: TLatLonBox): TOSMDataset;

    { Source AWS Terrarium heightmap covering ABox at HeightmapZoom (no leveling/bias).
      Cache-first; on a miss hits S3 with clamped timeout/retries. On success HM is
      set (caller owns/frees) and result is ''; on failure HM is nil + a // note. }
    function FetchSourceHeightmapForBox(const ABox: TLatLonBox;
      out HM: THeightmap): string;

    { Light-travel direction for baked shadows; zero = builder default.
      Set before streaming starts. }
    property SunDirection: TVector3 read FSunDir write FSunDir;

    { Отмена сетевых запросов Overpass (teardown карты): проброс на общий
      фетчер overpass-трафика — GenerateBlock в воркерах вываливается из
      HTTP немедленно, а не через таймаут. Окно ограничено — ResetFetchAbort. }
    procedure AbortFetches;
    procedure ResetFetchAbort;

    { Diagnostic log sink (not owned); also passed to TGeometryBuilder. Written from
      worker threads — TCallbackLogTarget marshals safely. }
    property Recipes: TKnowledgeRecipeSnapshot read FRecipes write FRecipes;
    property LogTarget: TLogTarget read FLog write FLog;
    { Прогресс-колбэк (фазы). Ставит хост (карта) — обновляет фазу в стримере. }
    property OnPhase: TBlockPhaseEvent read FOnPhase write FOnPhase;
  end;

implementation

uses Osm3dGenerationProgress;
type
  TBlockProgressReporter = class
    Owner: TOsm3dBlockGenerator;
    Block: TBlockId;
    Phase: TBlockPhase;
    procedure Report(const Stage: string; Completed, Total: Int64);
  end;

procedure TBlockProgressReporter.Report(const Stage: string; Completed, Total: Int64);
begin
  if Assigned(Owner.FOnPhase) then
    Owner.FOnPhase(Block, Phase, Stage, Completed, Total);
end;

procedure TOsm3dBlockGenerator.AbortFetches;
begin
  if (FOverpass <> nil) and (FOverpass.Fetcher <> nil) then
    FOverpass.Fetcher.AbortAllRequests;
  if FHttp <> nil then FHttp.AbortAllRequests;   { FetchSourceHeightmapForBox }
end;

procedure TOsm3dBlockGenerator.ResetFetchAbort;
begin
  if (FOverpass <> nil) and (FOverpass.Fetcher <> nil) then
    FOverpass.Fetcher.ResetAbort;
  if FHttp <> nil then FHttp.ResetAbort;
end;

constructor TOsm3dBlockGenerator.Create(AHttp: THTTPFetcherWithCache;
  ATerrFetcher: TTerrariumFetcher; AOverpass: TOverpassClient;
  const ASettings: TStudioSettings; const AGenHash: string;
  AEdgeMeters: Double; ABlockSize: Integer);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1018);{$ENDIF}
  inherited Create;
  FHttp     := AHttp;
  FTerrFetcher := ATerrFetcher;
  FOverpass    := AOverpass;
  FSettings := ASettings;
  FGenHash  := AGenHash;
  if AEdgeMeters < 1.0 then AEdgeMeters := GEO_TILE_EDGE_M;
  FEdgeMeters := AEdgeMeters;
  if ABlockSize < 1 then ABlockSize := GEO_BLOCK_SIZE;
  FBlockSize  := ABlockSize;
  FSunDir     := Vector3(0.0, 0.0, 0.0);   { zero -> builder default }
  FLog        := nil;
  FOnPhase    := nil;
  FRouteOnly    := False;
  FRouteRadiusM := 200.0;
  SetLength(FRoutePts, 0);
end;

procedure TOsm3dBlockGenerator.SetRouteCorridor(const ARoute: array of TLatLon;
  ARadiusM: Single; AEnabled: Boolean);
var
  I: Integer;
begin
  FRouteOnly    := AEnabled and (Length(ARoute) > 0);
  FRouteRadiusM := ARadiusM;
  if FRouteRadiusM < 1.0 then FRouteRadiusM := 200.0;
  SetLength(FRoutePts, Length(ARoute));
  for I := 0 to High(ARoute) do
    FRoutePts[I] := ARoute[I];
end;

{ Route-only: коридор маршрута в локальной системе блока (origin = центр halo,
  scaleLat = широта сессии) из точек маршрута, попавших в halo+радиус. nil,
  если ни одна точка не задевает блок. }
function TOsm3dBlockGenerator.EffScaleLat(const ABlockCenter: TLatLon): Double;
begin
  { Ручная фиксация (если задана) или полоса от широты БЛОКА. Ровно эту же
    развилку обязано повторить монтирование (TileBakeScaleLat в
    Osm3dSceneAssembler): разойдутся — тайл испечён в одной метрике,
    масштабирован по другой. }
  Result := FSettings.WorldScaleLatDeg;
  if (Result <= -90.0) or (Result >= 90.0) or (Result = 0.0) then
    Result := WorldScaleLatBand(ABlockCenter.Lat);
end;

function TOsm3dBlockGenerator.BuildBlockCorridorFor(const ABlockOrigin: TLatLon;
  AScaleLat: Double; const AHaloBox: TLatLonBox): TRouteCorridor;
var
  Proj: TLocalProjection;
  RangeBox: TLatLonBox;
  I, N: Integer;
  P: TVector3;
  Xs, Zs: array of Single;
begin
  Result := nil;
  if Length(FRoutePts) = 0 then Exit;
  Proj := TLocalProjection.Create(ABlockOrigin, AScaleLat);
  try
    { Запас охвата — НОМИНАЛЬНАЯ константа, не FEdgeMeters: тот приходит из
      решётки КАДРА сессии (EdgeMetersAt от полосы origin) и гулял бы на ±1%
      между сессиями из разных полос — а охват решает, какие точки маршрута
      попадут в коридор блока, т.е. влияет на геометрию route-only тайла.
      Константа чуть щедрее фактического ребра (500 против ~307 на 60°) —
      безвредно: лишние точки коридора за пределами halo геометрию тайла не
      меняют, детерминизм важнее экономии. }
    RangeBox := AHaloBox.ExpandMeters(FRouteRadiusM + GEO_TILE_EDGE_M);
    SetLength(Xs, Length(FRoutePts));
    SetLength(Zs, Length(FRoutePts));
    N := 0;
    for I := 0 to High(FRoutePts) do
      if (FRoutePts[I].Lat >= RangeBox.MinLat)
         and (FRoutePts[I].Lat <= RangeBox.MaxLat)
         and (FRoutePts[I].Lon >= RangeBox.MinLon)
         and (FRoutePts[I].Lon <= RangeBox.MaxLon) then
      begin
        P := Proj.Project(FRoutePts[I], 0);
        Xs[N] := P.X;  Zs[N] := P.Z;
        Inc(N);
      end;
    SetLength(Xs, N);  SetLength(Zs, N);
    if N > 0 then
      Result := TRouteCorridor.Create(Xs, Zs, FRouteRadiusM);
  finally
    Proj.Free;
  end;
end;

{ Route-only: выбросить из датасета OSM-фичи, целиком лежащие вне коридора.
  Way сохраняем, если хотя бы один его узел ИЛИ семпл вдоль сегмента в
  коридоре. Узлы: держим все, что нужны сохранённым way/отношениям, плюс
  одиночные (POI) в коридоре; остальные удаляем. }
procedure FilterDatasetToCorridor(DS: TOSMDataset; Corridor: TRouteCorridor;
  const AOrig: TLatLon; AScaleLat: Double; ARadiusM: Single);
var
  Proj: TLocalProjection;
  W:    TOSMWay;
  N:    TOSMNode;
  Rel:  TOSMRelation;
  Used: specialize TDictionary<Int64, Boolean>;
  DropW, DropN: specialize TList<Int64>;
  I:  Integer;
  P:  TVector3;
  id: Int64;

  function WayIn(AW: TOSMWay): Boolean;
  var
    k, s, segN: Integer;
    Na, Nb: TOSMNode;
    Pa, Pb: TVector3;
    segLen, t, sx, sz: Single;
  begin
    Result := False;
    for k := 0 to High(AW.NodeRefs) do
    begin
      Na := DS.FindNode(AW.NodeRefs[k]);
      if Na = nil then Continue;
      Pa := Proj.Project(Na.Position, 0);
      if Corridor.Contains(Pa.X, Pa.Z) then Exit(True);
    end;
    { длинные сегменты: оба узла могут быть > радиуса, но ребро пересекает }
    for k := 0 to High(AW.NodeRefs) - 1 do
    begin
      Na := DS.FindNode(AW.NodeRefs[k]);
      Nb := DS.FindNode(AW.NodeRefs[k + 1]);
      if (Na = nil) or (Nb = nil) then Continue;
      Pa := Proj.Project(Na.Position, 0);
      Pb := Proj.Project(Nb.Position, 0);
      segLen := Sqrt(Sqr(Pb.X - Pa.X) + Sqr(Pb.Z - Pa.Z));
      segN := Trunc(segLen / ARadiusM);
      for s := 1 to segN do
      begin
        t  := s / (segN + 1);
        sx := Pa.X + (Pb.X - Pa.X) * t;
        sz := Pa.Z + (Pb.Z - Pa.Z) * t;
        if Corridor.Contains(sx, sz) then Exit(True);
      end;
    end;
  end;

begin
  Proj  := TLocalProjection.Create(AOrig, AScaleLat);
  Used  := specialize TDictionary<Int64, Boolean>.Create;
  DropW := specialize TList<Int64>.Create;
  DropN := specialize TList<Int64>.Create;
  try
    for W in DS.Ways.Values do
      if WayIn(W) then
      begin
        for I := 0 to High(W.NodeRefs) do
          Used.AddOrSetValue(W.NodeRefs[I], True)
      end
      else
        DropW.Add(W.Id);

    { узлы-члены отношений держим (мультиполигоны зданий/лендюза) }
    for Rel in DS.Relations.Values do
      for I := 0 to High(Rel.Members) do
        if Rel.Members[I].Kind = omkNode then
          Used.AddOrSetValue(Rel.Members[I].Ref, True);

    for id in DropW do DS.Ways.Remove(id);

    for N in DS.Nodes.Values do
      if (not Used.ContainsKey(N.Id)) then
      begin
        P := Proj.Project(N.Position, 0);
        if not Corridor.Contains(P.X, P.Z) then DropN.Add(N.Id);
      end;
    for id in DropN do DS.Nodes.Remove(id);
  finally
    Proj.Free;
    Used.Free;
    DropW.Free;
    DropN.Free;
  end;
end;

function TOsm3dBlockGenerator.GenerateBlock(const ABlock: TBlockId;
  const AHaloBox: TLatLonBox; const AOrigin: TLatLon;
  ACancel: PBoolean): TBlockGenResult;
var
  TileHms:  array of THeightmap;
  Stitched: THeightmap;
  Overpass:    TOverpassClient;
  Dataset:     TOSMDataset;
  Chunk:       TOsm3dChunkData;
  BlockOrigin: TLatLon;   { block-LOCAL projection origin (halo centre) }
  SessProj: TLocalProjection;
  SnapD: Double;
  SLat:   Double;         { широта масштаба МИРА (см. EffScaleLat) }
  Anchor: TLatLon;        { глобальный якорь решётки/фазы — НЕ origin сессии }
  Corridor:    TRouteCorridor;   { route-only: коридор блока (nil = обычная генерация) }
  Builder:     TGeometryBuilder;
  SceneInput:  TSceneInput;
  Trees:       TForestBuildResult;
  TreeRecs:    TTileTreeRecArray;
  AllModels:   TTileModelArray;
  KeepSet:     specialize TDictionary<Int64, Boolean>;
  BTiles:      TGeoTileIdArray;
  I, KeptN:    Integer;
  GenBuildings, GenRoads, GenTrees, GenLanduse, GenWaterways: Boolean;
  Reporter: TBlockProgressReporter;
  PreviousProgress: TGenerationProgressContext;

  function Cancelled: Boolean;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1);{$ENDIF}
    Result := (ACancel <> nil) and ACancel^;
  end;

  procedure Log(const AMsg: string);
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(2);{$ENDIF}
    if FLog <> nil then
      FLog.Write(llInfo, 'block ' + ABlock.ToString + ': ' + AMsg);
  end;

  procedure FreeHeightmapTiles;
  var J: Integer;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(3);{$ENDIF}
    for J := 0 to High(TileHms) do
      if TileHms[J] <> nil then
        FreeAndNil(TileHms[J]);
    SetLength(TileHms, 0);
  end;

  { Dispose every heap object in a TSceneInput; FreeAndNil is nil-safe, so a
    partially-built input (Build raised midway) is safe to pass. }
  procedure FreeSceneInput;
  var J: Integer;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(4);{$ENDIF}
    FreeAndNil(SceneInput.Terrain);
    FreeAndNil(SceneInput.FarTerrain);
    FreeAndNil(SceneInput.WaterRivers);
    FreeAndNil(SceneInput.RoadMajor);
    FreeAndNil(SceneInput.RoadSecondary);
    FreeAndNil(SceneInput.RoadMinor);
    FreeAndNil(SceneInput.RoadService);
    FreeAndNil(SceneInput.RoadFootway);
    FreeAndNil(SceneInput.RoadCycleway);
    FreeAndNil(SceneInput.RoadRailway);
    FreeAndNil(SceneInput.RoadDirtPath);
    FreeAndNil(SceneInput.RoadSandPath);
    for J := 0 to High(SceneInput.BuildingWalls) do
    begin
      FreeAndNil(SceneInput.BuildingWalls[J]);
      FreeAndNil(SceneInput.BuildingRoofs[J]);
    end;
    for J := Low(SceneInput.Fences) to High(SceneInput.Fences) do
      FreeAndNil(SceneInput.Fences[J]);
    FreeAndNil(SceneInput.Plates);
    FreeAndNil(SceneInput.RoadFurniture);
    SceneInput.Landuse.FreeAll;
    FreeAndNil(SceneInput.POI);
    FreeAndNil(SceneInput.LabelsRoot);
    FreeAndNil(SceneInput.GroundComposite);
    FreeAndNil(SceneInput.GroundAtlas);
    FreeAndNil(SceneInput.RoadDistField);
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(0);{$ENDIF}
  Result.Success := False;
  Result.Error   := '';
  SetLength(Result.Tiles, 0);
  SetLength(Result.Previews, 0);

  Overpass    := nil;
  Dataset     := nil;
  Chunk       := nil;
  Corridor    := nil;
  Builder     := nil;
  Stitched    := nil;
  KeepSet     := nil;
  SetLength(TileHms,   0);
  SetLength(AllModels, 0);
  { zero the managed fields so success and failure paths start from a defined state }
  FillChar(SceneInput, SizeOf(SceneInput), 0);
  FillChar(Trees,      SizeOf(Trees),      0);
  Reporter := TBlockProgressReporter.Create;
  Reporter.Owner := Self; Reporter.Block := ABlock; Reporter.Phase := bpWait;
  PreviousProgress := GenerationProgressContext;
  GenerationProgressContext.Notify := @Reporter.Report;
  GenerationProgressContext.Cancel := ACancel;

  try
    try
      if Cancelled then Exit;

      { 1. heightmap region — shared TTerrariumFetcher caches/coalesces; returns a
        finished caller-owned stitched map, nil only if a covering tile is unreadable. }
      Log('fetching heightmap region...');
      Reporter.Phase := bpHeightmap;
      GenerationProgress('Height tiles', 0, 0);
      Stitched := FTerrFetcher.GetRegion(AHaloBox, FSettings.HeightmapZoom, ACancel);
      if Stitched = nil then
      begin
        Result.Error := 'heightmap region fetch failed (covering tile unavailable)';
        Exit;
      end;
      if Cancelled then Exit;
      { smooth the integer-metre source staircase once, so every consumer reads it }
      if FSettings.BlurHeightmapSigmaPx > 0 then
        Stitched.BlurGaussian(FSettings.BlurHeightmapSigmaPx);
      Log('heightmap ready');

      if Cancelled then Exit;

      GenBuildings := FSettings.GenerateBuildings;
      GenRoads     := FSettings.GenerateRoads;
      GenTrees     := FSettings.GenerateTrees;
      GenLanduse   := FSettings.GenerateLanduse;
      GenWaterways := FSettings.GenerateWaterways;
      { the tree pipeline needs landuse=forest polygons }
      if GenTrees and (not GenLanduse) then
        GenLanduse := True;

      { 2. Require a complete OSM region before generating persistent geometry.
        Source errors propagate to the streamer's retry path. Skip only when
        no OSM features were requested. }
      Log('fetching OSM data (Overpass)...');
      Reporter.Phase := bpOverpass;
      GenerationProgress('OSM tiles', 0, 0);
      if GenBuildings or GenRoads or GenTrees or GenLanduse or GenWaterways then
        Dataset := FOverpass.GetRegion(AHaloBox)
      else
        Dataset := TOSMDataset.Create;   { nothing requested -> empty set }
      { Photo refinements belong to the source dataset, before every builder
        (terrain, roads, lane graph, plants). Buildings may be disabled. }
      if (FRecipes<>nil) and
        (GenBuildings or GenRoads or GenTrees or GenLanduse or GenWaterways) then
        FRecipes.Apply(Dataset,AHaloBox);
      Log('OSM data ready');

      if Cancelled then Exit;

      { Build in a block-LOCAL frame (origin = halo centre), not the far session origin:
        keeps vertices near 0 so single-precision coords stay above the ground
        composite's 1 mm weld tolerance (far from origin they'd merge into degenerate
        triangles). The split below re-files onto the absolute geo-tile lattice. }
      BlockOrigin := AHaloBox.Center;

      { ШИРОТА МАСШТАБА + ЯКОРЬ — ОТ ГЕОГРАФИИ БЛОКА, НЕ ОТ СЕССИИ. Метрика
        (cos долготы) — полоса ln-cos от широты ЦЕНТРА БЛОКА: тайл = чистая
        функция своего id, кэш универсален (никакой сессионный вход в
        выпечку не попадает). Внутри полосы соседние блоки делят метрику и
        якорь побитно — сварка и глобальная фаза 1/64 м работают как раньше;
        стык блоков из СОСЕДНИХ полос (одна граница на десятки км) получает
        компенсирующий масштаб X при монтировании и допускает волосяную
        фазу до ~1.6 см — осознанная цена универсального кэша.
        Якорь долготы 0 → мировая координата на 60° в.д. ≈ 3340 км = 2.1e8
        единиц решётки 1/64 м: против Int64 пыль, против предела умножения
        e7·K_q32 (±180°, см. шапку Osm3dIntGeo) — четверть диапазона. }
      SLat := EffScaleLat(AHaloBox.Center);   { география блока, НЕ сессии }
      Anchor := TLatLon.Make(SLat, 0.0);

      { ГЛОБАЛЬНАЯ ФАЗА int-решётки: origin блока прищёлкивается к МИРОВОЙ
        решётке 1/64 м (сдвиг <= 8 мм через проекцию якоря туда-обратно).
        Локальный квант карва после этого фазирован не просто внутри сессии,
        а глобально: общие рамочные точки соседних блоков — и соседних
        СЕССИЙ — квантуются в ОДНИ мировые узлы; волосяные (до 1.6 см) щели
        пер-блочной фазы исчезают без правок в самом карве. }
      SessProj := TLocalProjection.Create(Anchor, SLat);
      try
        { Double-арифметика в градусах: Single-проекция на дальних блоках
          (тысячи км от якоря) имеет ulp грубее кванта. Снап по модулю 1/64
          не зависит от знаковой конвенции осей проекции. Величины: 3.3e6 м ·
          64 = 2.1e8 — Round на Double точен (< 2^53). }
        SnapD := (BlockOrigin.Lon - Anchor.Lon) * SessProj.MetersPerDegreeLon;
        SnapD := (Round(SnapD * 64.0) / 64.0) - SnapD;
        BlockOrigin.Lon := BlockOrigin.Lon + SnapD / SessProj.MetersPerDegreeLon;
        SnapD := (BlockOrigin.Lat - Anchor.Lat) * SessProj.MetersPerDegreeLat;
        SnapD := (Round(SnapD * 64.0) / 64.0) - SnapD;
        BlockOrigin.Lat := BlockOrigin.Lat + SnapD / SessProj.MetersPerDegreeLat;
      finally
        SessProj.Free;
      end;

      { Route-only: коридор блока + фильтр датасета ДО постройки Chunk (пока
        Dataset ещё у нас). Коридор в локальной системе блока (BlockOrigin,
        SLat) — совпадает с системой вершин террейна/композита. Фичи
        целиком вне коридора выбрасываются; террейн/композит режет билдер. }
      if FRouteOnly and (Length(FRoutePts) > 0) then
      begin
        Corridor := BuildBlockCorridorFor(BlockOrigin, SLat, AHaloBox);
        if (Corridor <> nil) and (Corridor.Count > 0) then
        begin
          if Dataset <> nil then
            FilterDatasetToCorridor(Dataset, Corridor, BlockOrigin,
              SLat, FRouteRadiusM);
          Log(Format('route-only: corridor %d pts, dataset filtered to %s',
            [Corridor.Count, Dataset.StatsString]));
        end
        else
          { маршрут не задевает блок (не должно происходить: стример генерит
            только тайлы коридора) — режим не режем, строим полный тайл. }
          FreeAndNil(Corridor);
      end;

      Chunk := TOsm3dChunkData.Create;
      Chunk.Origin := BlockOrigin;
      Chunk.ScaleLat := SLat;          { build local, but WORLD lon-scale so tiles weld in ANY session }
      Chunk.SessionOrigin := Anchor;   { якорь мировой int-решётки (Osm3dIntGeo) — глобальный }
      Chunk.Box    := AHaloBox;
      Chunk.SetHeightmap(Stitched);  Stitched := nil;   { chunk owns it }
      Chunk.SetDataset(Dataset);     Dataset  := nil;    { chunk owns it }

      if AddSeaSurfaces(Chunk.Dataset, AHaloBox, BlockOrigin, SLat) < 0 then
        Log('coastline: incomplete topology; marine fill skipped');
      Log('building geometry...');
      Reporter.Phase := bpGeom;
      GenerationProgress('Terrain', 0, 0);
      Builder := TGeometryBuilder.Create(Chunk, FSettings, FLog, nil);
      Builder.SunDirection := FSunDir;
      { FIT-слой высот из общего фетчера: TTerrainBuilder/Sampler смешают DEM с
        FIT на узлах террейна — вся геометрия сядет на корректированную землю.
        nil, если слой не построен (без коррекции). }
      Builder.FitLayer := FTerrFetcher.FitLayer;
      Builder.WaterHeightSource := FTerrFetcher;
      { Route-only: коридор блока — билдер отрежет террейн/земляной композит
        по нему (nil = обычная генерация). }
      Builder.RouteCorridor := Corridor;
      { Диагностика: стоит ли активный FIT-слой в общем фетчере на момент
        генерации этого блока (покажет тайминг установки слоя). }
      if (FTerrFetcher.FitLayer <> nil) and FTerrFetcher.FitLayer.Active then
        Log('fit height-layer present in fetcher (sig='
            + FTerrFetcher.FitLayer.Signature + ')')
      else
        Log('fit height-layer ABSENT in fetcher at gen time');
      if not Builder.Build(SceneInput, Trees) then
      begin
        Result.Error := 'geometry build failed';
        Exit;
      end;
      Log('geometry built');

      if Cancelled then Exit;

      { 5. split into geo-tiles. Same block-local origin as the build; TilingZone
        pins the lattice to the SESSION origin's UTM zone so tile IDs match what the
        streamer requested even across a 6-degree zone meridian. }
      SceneInput.Origin         := BlockOrigin;
      { TilingZone НЕ заполняем: поле рудиментарное (write-only) — слиппи-
        решётка (HeightmapZoom + GEO_TILE_EDGE_PX) давно заменила UTM-зоны,
        см. комментарий у HeightmapZoom в TAssembleSceneInput. Это была
        ПОСЛЕДНЯЯ зависимость выпечки от origin сессии: ZoneOfLon(AOrigin.Lon)
        тянул долготу старта стриминга в путь тайла, хоть её никто не читал. }
      SceneInput.ScaleLat       := SLat;         { world lon-scale (see above) }
      SceneInput.TileEdgeMeters := FEdgeMeters;
      SceneInput.HeightmapZoom  := FSettings.HeightmapZoom;

      BTiles := BlockTiles(ABlock, FBlockSize);
      TreeRecs  := ForestToTileTrees(Trees);
      GenerationProgress('Splitting tiles', 0, 0);
      AllModels := TSceneAssembler.SplitInputToTiles(
        SceneInput, FGenHash, TreeRecs, nil, BTiles);
      Log(Format('split into %d tiles (incl. halo)', [Length(AllModels)]));
      { The selected models own their copies. Drop the much larger source
        meshes before water metadata and previews allocate more buffers. }
      FreeSceneInput;
      SceneInput := Default(TSceneInput);
      TreeRecs := nil;
      Trees := Default(TForestBuildResult);

      { 6. keep only the block's own tiles; discard the halo }
      BTiles  := BlockTiles(ABlock, FBlockSize);
      KeepSet := specialize TDictionary<Int64, Boolean>.Create;
      for I := 0 to High(BTiles) do
        KeepSet.AddOrSetValue(BTiles[I].ToKey, True);

      SetLength(Result.Tiles, Length(AllModels));
      KeptN := 0;
      for I := 0 to High(AllModels) do
      begin
        if AllModels[I] = nil then Continue;
        if KeepSet.ContainsKey(AllModels[I].TileId.ToKey) then
        begin
          Result.Tiles[KeptN] := AllModels[I];
          AllModels[I] := nil;            { ownership moves to Result }
          Inc(KeptN);
        end
        else
          FreeAndNil(AllModels[I]);       { halo tile — discard }
      end;
      SetLength(Result.Tiles, KeptN);
      BakeWaterScales(Chunk.Dataset, BlockOrigin, SLat, Result.Tiles);
      if FRecipes<>nil then
        for I:=0 to KeptN-1 do FRecipes.BakeFacades(Result.Tiles[I],SLat);
      {$IFDEF TILE_MEM_PROFILE}
      for I := 0 to KeptN - 1 do
        if Result.Tiles[I] <> nil then
          ProfileTileModel(Result.Tiles[I], 'gen',
            Result.Tiles[I].TileId.ToString, 0, FLog);
      {$ENDIF}

      { preview LOD (heights from the block heightmap + flat ground texture);
        a preview failure does not fail the block }
      SetLength(Result.Previews, KeptN);
      GenerationProgress('Tile previews', 0, KeptN);
      for I := 0 to KeptN - 1 do
      begin
        try
          Result.Previews[I] := BuildTilePreview(Chunk.Heightmap,
            Result.Tiles[I].Box, SLat, Result.Tiles[I]);
        except
          on E: Exception do
          begin
            Result.Previews[I] := nil;
            Log('preview build failed for '
                + Result.Tiles[I].TileId.ToString + ': ' + E.Message);
          end;
        end;

        GenerationProgress('Tile previews', I + 1, KeptN);
      end;

      if KeptN = 0 then
      begin
        { every tile has terrain, so an empty split is a failure — let the streamer retry }
        Result.Success := False;
        Result.Error   := 'split produced no tiles for the block';
      end
      else
        Result.Success := True;
    except
      on E: Exception do
      begin
        Result.Success := False;
        Result.Error   := E.ClassName + ': ' + E.Message;
        for I := 0 to High(Result.Tiles) do
          if Result.Tiles[I] <> nil then
            FreeAndNil(Result.Tiles[I]);
        SetLength(Result.Tiles, 0);
      end;
    end;
  finally
    GenerationProgressContext := PreviousProgress;
    Reporter.Free;
    { Release everything not transferred into Result. }
    FreeHeightmapTiles;
    for I := 0 to High(AllModels) do
      if AllModels[I] <> nil then
        FreeAndNil(AllModels[I]);
    SetLength(AllModels, 0);
    FreeSceneInput;
    Builder.Free;
    Corridor.Free;     { route-only коридор блока — владеет генератор }
    Chunk.Free;        { frees the heightmap + dataset it took ownership of }
    Stitched.Free;     { nil once moved into the chunk }
    Dataset.Free;      { nil once moved into the chunk }
    Overpass.Free;
    KeepSet.Free;
  end;
end;

function TOsm3dBlockGenerator.CachedOsmJsonForBox(const ABox: TLatLonBox): string;
var
  Tiles:      TTileXYArray;
  I, Zoom, TimeoutS, Found: Integer;
  TileBox:    TLatLonBox;
  Query, Key: string;
  Data:       TBytes;
  SB:         TStringBuilder;

  function BytesToUtf8Str(const B: TBytes): string;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1341);{$ENDIF}
    SetLength(Result, Length(B));
    if Length(B) > 0 then
      Move(B[0], Result[1], Length(B));
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1342);{$ENDIF}
  Result := '';
  if FHttp = nil then
    Exit('// no HTTP fetcher available');

  Zoom := FSettings.OverpassTileZoom;
  if Zoom <= 0 then Zoom := OVERPASS_TILE_ZOOM_DEFAULT;
  TimeoutS := FSettings.OverpassTimeoutS;
  if TimeoutS <= 0 then TimeoutS := OVERPASS_TIMEOUT_DEFAULT;

  Tiles := TTileMath.TilesCoveringBox(ABox, Zoom);
  if Length(Tiles) = 0 then
    Exit('// no Overpass tiles cover this geo-tile');

  SB := TStringBuilder.Create;
  try
    Found := 0;
    SB.AppendLine(Format('// geo-tile covered by %d Overpass z%d tile(s)',
      [Length(Tiles), Zoom]));
    SB.AppendLine('');

    for I := 0 to High(Tiles) do
    begin
      TileBox := TTileMath.TileToLatLonBox(Tiles[I]);
      Query   := TOverpassQueryExt.BuildCombinedFull(
                   TileBox, DefaultFlagsForFullScene, TimeoutS);
      Key     := OverpassCacheKey(Query);

      Data := nil;
      if FHttp.Cache.Get(Key, Data) and (Length(Data) > 0) then
      begin
        Inc(Found);
        SB.AppendLine(Format(
          '// ----- Overpass tile z%d x=%d y=%d  (%d bytes)  %s -----',
          [Tiles[I].Zoom, Tiles[I].X, Tiles[I].Y, Length(Data), Key]));
        SB.AppendLine(BytesToUtf8Str(Data));
      end
      else
        SB.AppendLine(Format(
          '// ----- Overpass tile z%d x=%d y=%d  -- NOT in cache (%s) -----',
          [Tiles[I].Zoom, Tiles[I].X, Tiles[I].Y, Key]));
      SB.AppendLine('');
    end;

    if Found = 0 then
      SB.AppendLine(
        '// nothing cached for this tile -- has it actually been generated yet?');

    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function TOsm3dBlockGenerator.CachedOsmDatasetForBox(
  const ABox: TLatLonBox): TOSMDataset;
var
  Tiles:      TTileXYArray;
  I, Zoom, TimeoutS, Found: Integer;
  TileBox:    TLatLonBox;
  Query, Key: string;
  Data:       TBytes;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1343);{$ENDIF}
  Result := nil;
  if FHttp = nil then Exit;

  Zoom := FSettings.OverpassTileZoom;
  if Zoom <= 0 then Zoom := OVERPASS_TILE_ZOOM_DEFAULT;
  TimeoutS := FSettings.OverpassTimeoutS;
  if TimeoutS <= 0 then TimeoutS := OVERPASS_TIMEOUT_DEFAULT;

  Tiles := TTileMath.TilesCoveringBox(ABox, Zoom);
  if Length(Tiles) = 0 then Exit;

  Result := TOSMDataset.Create;
  Found  := 0;
  for I := 0 to High(Tiles) do
  begin
    TileBox := TTileMath.TileToLatLonBox(Tiles[I]);
    Query   := TOverpassQueryExt.BuildCombinedFull(
                 TileBox, DefaultFlagsForFullScene, TimeoutS);
    Key     := OverpassCacheKey(Query);
    Data    := nil;
    if FHttp.Cache.Get(Key, Data) and (Length(Data) > 0) then
    begin
      try
        TOSMJsonReader.ParseBytes(Data, Result);
        Inc(Found);
      except
        on E: Exception do { skip a corrupt / partial cache blob } ;
      end;
    end;
  end;

  if Found = 0 then
    FreeAndNil(Result);   { nothing cached -> nil }
end;

function TOsm3dBlockGenerator.FetchSourceHeightmapForBox(
  const ABox: TLatLonBox; out HM: THeightmap): string;
var
  Tiles:    TTileXYArray;
  TileHms:  array of THeightmap;
  Fetcher:  TTerrariumFetcher;
  TilesX, TilesY, I: Integer;
  SavedTimeoutMs, SavedMaxRetries: Integer;

  procedure FreeTiles;
  var J: Integer;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1344);{$ENDIF}
    for J := 0 to High(TileHms) do
      if TileHms[J] <> nil then
        FreeAndNil(TileHms[J]);
    SetLength(TileHms, 0);
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1345);{$ENDIF}
  HM     := nil;
  Result := '';
  if FHttp = nil then
    Exit('// no HTTP fetcher available');

  Tiles := TTileMath.TilesCoveringBox(ABox, FSettings.HeightmapZoom);
  if Length(Tiles) = 0 then
    Exit('// no heightmap tiles cover this area');

  Fetcher := nil;
  SetLength(TileHms, Length(Tiles));

  { clamp timeout/retries so one slow/missing tile can't block the main-thread caller.
    FHttp — ОБЩИЙ (shared, not owned): весь save/mutate/use/restore держим
    под процессным замком мутаторов конфигурации (Osm3dCacheHTTPFetcher),
    иначе два параллельных клампа переписывают saved-значения друг друга,
    и фетчер залипает на чужих таймаутах. Замок сериализует только
    мутаторов — обычные fetch'и его не берут. }
  EnterFetcherConfig;
  try
    SavedTimeoutMs  := FHttp.TimeoutMs;
    SavedMaxRetries := FHttp.MaxRetries;
    FHttp.TimeoutMs  := 5000;
    FHttp.MaxRetries := 2;
    try
      Fetcher := TTerrariumFetcher.Create(FHttp, FSettings.TerrariumUrlTemplate);
      for I := 0 to High(Tiles) do
      begin
        TileHms[I] := Fetcher.FetchTile(Tiles[I]);
        if TileHms[I] = nil then
        begin
          FreeTiles;
          Exit(Format('// heightmap tile (%d,%d,%d) fetch failed',
            [Tiles[I].X, Tiles[I].Y, Tiles[I].Zoom]));
        end;
      end;

      { TilesCoveringBox returns the tiles row-major from (minX,minY) to
        (maxX,maxY); the stitcher needs the column/row counts. }
      TilesX := Tiles[High(Tiles)].X - Tiles[0].X + 1;
      TilesY := Tiles[High(Tiles)].Y - Tiles[0].Y + 1;
      HM := THeightmapStitcher.Stitch(TileHms, TilesX, TilesY);
      { same low-pass as the build, so the dump matches the surface actually used }
      if (HM <> nil) and (FSettings.BlurHeightmapSigmaPx > 0) then
        HM.BlurGaussian(FSettings.BlurHeightmapSigmaPx);
    finally
      FHttp.TimeoutMs  := SavedTimeoutMs;
      FHttp.MaxRetries := SavedMaxRetries;
      FreeTiles;          { Stitch has copied the data — tiles no longer needed }
      Fetcher.Free;
    end;
  finally
    LeaveFetcherConfig;
  end;
end;

end.
