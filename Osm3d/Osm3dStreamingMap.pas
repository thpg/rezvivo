unit Osm3dStreamingMap;

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$codepage UTF8}
{$WARN 5024 OFF}

interface

uses UiTranslations,
  Classes, fpjson,
  SysUtils,
  Math,
  crc,               { crc32 — подписи кромок гридов заглушек в диагностике }
  Generics.Collections,
  CastleVectors,
  CastleTransform,
  CastleScene,
  CastleCameras,
  CastleImages,
  X3DNodes,
  X3DFields,
  Osm3dGeoMath,
  Osm3dOsmData,
  Osm3dGeoTileGrid, Osm3dRouteCoverage,
  Osm3dGeoTileCache,
  Osm3dGeoTileBlock,
  Osm3dPrevTexFetcher,   { превью-текстуры по блокам (.ptex.png) }
  Osm3dWarmupOverlay,    { плоский прогрев маршрута — общий для студии и игры }
  Osm3dHeightmap,        { THeightmap / THeightmapSampler — source-height dump }
  Osm3dTileX3D, Osm3dSoundscape,
  Osm3dTilePreview,
  CastleRenderOptions,   { stVertex / stFragment для TEffectPartNode.ShaderType }
  Osm3dEffectUtils,   { ChainEffectApp — навесить блендинг-эффект на меш земли }
  Osm3dOsmOverpass,
  Osm3dMemBudget,
  {$IFDEF TILE_MEM_PROFILE}Osm3dMemCensus,{$ENDIF}
  Osm3dTreeShadow,       { SetTreeShadowDir — общий набор альфа-масок деревьев }
  Osm3dGeomMesh,
  Osm3dSceneMaterials,
  Osm3dGroundComposite,  { GROUND_MAT_* — id-ы grass-материалов в композите земли }
  Osm3dRenderGrass,
  Osm3dSceneAssembler, Osm3dRoadCurbs, Osm3dGpuGround,
  Osm3dAccessoryAtlas,
  Osm3dWind,
  Osm3dCacheHTTPFetcher,
  Osm3dStudioSettings,
  Osm3dStudioLog,
  Osm3dProfiler,
  Osm3dRenderInstanced,
  Osm3dGeomVegetation,
  Osm3dProceduralVegetation,
  Osm3dTileStreamer,
  Osm3dLodTree,
  Osm3dLodCells,
  CastleSceneCore,   { SceneLifecycleLog — трасса этапов Destroy }
  Osm3dBlockGenerator,
  Osm3dMapUtils,
  Osm3dRouteSnapper,
  Osm3dWaterShader
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF},
  Osm3dFitCorrection,
  Osm3dFitBank,
  Osm3dFitHeightLayer,     { TFitHeightLayer — второй слой высот фетчера }
  Osm3dFitLayerBuild,      { BuildFitHeightLayer — сборка слоя из папки }
  Osm3dBuildingObstacleIndex, Osm3dRouteBuildings, { BUILDING_OBSTACLE: camera/rider push-out }
  Osm3dGlslLib;            { DEFAULT_SUN_RAY_DIR — единый дефолт солнца }

type
  TCacheBatch = class;

  { One assembled tile — a leaf of the cache tree.

    Scene  — the tile's TProfiledScene; a CGE child of Batch.Owner.
             Assembled ONCE, Load'ed ONCE, never re-Load'ed. Freed only
             by EvictBatch (whole batch at once) or TeardownAll, never
             one tile while a sibling of the same batch still renders.
    Batch  — the owning batch node.
    Tile   — the geo-tile this scene represents.
    Active — True while the tile's scene is visible; mirrors
             Scene.Exists.
    CenterX, CenterZ — the tile's positioning centre (the projected
             geo-tile centre it was placed at). Distance culling measures
             from THIS stable point, not from the scene bounding box —
             a runaway building vertex inflates the bbox and would
             otherwise drag the cull centre, culling the tile early. }
  { Мировые координаты граничных вершин тайла (X/Z — мировые, Y абсолютный),
    посчитанные ровно так же, как их печёт ассемблер: Single(local)+Single(centre).
    По ним при монтаже соседний тайл приваривается к уже загруженному. }
  { Canonical geographic metres (unscaled longitude), independent of the
    session origin and latitude. Double avoids rounding distant tile seams. }
  TBorderWorldPoint = record
    X, Z: Double;
    Y: Single;
  end;
  TBorderWorldArray = array of TBorderWorldPoint;
  TBorderWorldMap   = specialize TDictionary<string, TBorderWorldArray>;

  { Плейсхолдер загрузки: сцена-коробка + billboard-текст на месте тайла,
    пока реальный тайл грузится/генерируется. Живёт в FLoadOwner, снимается
    когда тайл смонтирован или ячейка отпущена. }
  TLoadTile = class
    Id:    TGeoTileId;
    Scene: TCastleScene;
    Text:  TTextNode;      { живой узел — обновляем SetText }
    Last:  string;
    CX, CZ: Single;        { мировой центр (для перестановки Y пола) }
    BoxH:  Single;         { высота коробки }
    BoxT:  TTransformNode; { transform коробки — двигаем Y при появлении высоты }
    TxtT:  TTransformNode; { transform надписи }
    BoxMat: TMaterialNode; { материал коробки — зеленим, когда тайл готов }
    GreenDone: Boolean;    { уже позеленел }
    FloorDone: Boolean;    { высота пола установлена из кэша }
    NextFloor: QWord;      { тик следующей перепроверки высоты }
    MeshDone:  Boolean;    { коробка заменена мешем земли }
    NextMesh:  QWord;      { тик следующей проверки высот }
    { морф высот меша к более детальным по мере фоновой загрузки (без пересборки) }
    Coord:     TCoordinateNode;  { живой узел координат меша }
    Interp:    TCoordinateInterpolatorNode;  { X3D-морф высот }
    Timer:     TTimeSensorNode;
    MeshN:     Integer;          { сторона сетки }
    MeshSizeX,                    { размеры меша в метрах: X — по долготе, }
    MeshSizeZ: Single;            { Z — по широте (меркаторный тайл не квадрат) }
    HCur:      THeightArray;     { текущие высоты меша }
    MeshDetail: Boolean;         { детальные высоты уже применены -> не проверять }
  end;

  TCacheTile = class
    Scene:  TProfiledScene;
    Batch:  TCacheBatch;
    Tile:   TGeoTileId;
    Active: Boolean;
    { Monotonic mount generation, assigned from TOsm3dStreamingMap.FShadowGen
      each time this tile object is mounted. Stamped into its shadow-mask
      registry slot and into every shadow gen job, so a mask upload produced
      for a PRIOR mount of the same geo-tile is rejected on drain (the
      re-mount has a higher generation). This is what makes the off-thread
      shadow path safe against TCacheTile heap-address reuse. }
    MountGen: QWord;
    { Hash of the silhouette set (own + neighbour casters) that produced the
      tile's last-enqueued shadow mask. A re-enqueue whose snapshot hashes the
      same is skipped — it would rasterise an identical mask. 0 = none yet. }
    ShadowHash: QWord;
    CenterX, CenterZ: Single;
    HasMarineWater: Boolean; { captured before the source model is released }
    Soundscape: TSoundscapeField;
    { Set once the snapped-route (green) cluster has been parented to
      this tile — guards against the completion sweep and a later
      MountBatch both mounting it. }
    GreenMounted: Boolean;
    { Wheel contacts use the same indexed surface as the rendered road.
      GroundBin lists triangle IDs intersecting each XZ cell. Positions are
      stored once per source vertex, including the baked curb mesh. }
    GpuGround:TGpuGroundTile;
    GpuOwner:TOsmGpuGround;
    destructor Destroy; override;
  public
    GroundCurbFirst: Integer; { triangle index; curbs share GroundVertices/GroundIndices/GroundBin }
    GroundHasField: Boolean;
    GroundMinX, GroundMaxX: Single;   { tile-local XZ extent }
    GroundMinZ, GroundMaxZ: Single;
    GroundVertices: array of TVector3; { tile-local positions }
    GroundIndices: array of Cardinal; { source triangle order }
    { GroundGridN*GroundGridN ячеек; каждая — динамический массив
      индексов треугольников (индекс i → GroundVertices[GroundIndices[i*3..i*3+2]]). }
    GroundBin:  array of array of Integer;
    { Мировые координаты граничных вершин композита этого тайла (после
      сварки). Сосед, монтируемый позже, ищет в них совпадения и
      подменяет ими свои граничные вершины — щель исчезает. }
    BorderWorld: TBorderWorldArray;
    { Accessory (traffic-light) blink state — advanced only while this is the
      current tile (Update calls AnimateAccessories on it). }
    AccTimer: Single;
    AccPhase: Integer;   { traffic-light phase: 0=green, 1=yellow, 2=red }
    { Advance this tile's batch accessory sprites one frame (traffic-light
      blink: toggles the atlas cell of every registered TextureTransform). }
    function SampleGround(const LX,LZ,ReferenceY:Single; out AY:Single):Boolean;
    procedure AnimateAccessories(SecondsPassed: Single);
  end;

  TCacheTileList = specialize TList<TCacheTile>;

  { A batch node — the unit of assembly and of X3D-graph ownership, and
    a root block of the cache tree.

    Owner       — a TCastleTransform, a CGE child of the map scene; its
                  Exists gates the whole batch in one test.
    Assembled   — the TAssembledScenes whose roots the tile scenes were
                  Load'ed from with OwnsRootNode=False. The graph is
                  USE-shared between this batch's tiles, so it is owned
                  as a whole here and released exactly once.
    Tiles       — the TCacheTile leaves.
    ActiveCount — how many of them are Active; drives Owner.Exists.
    CX, CZ      — batch centroid in world XZ, for PurgeFarBatches. }
  TCacheBatch = class
    Owner:       TCastleTransform;
    Assembled:   TAssembledScenes;
    Tiles:       TCacheTileList;
    ActiveCount: Integer;
    CX, CZ:      Single;
    constructor Create;
    destructor  Destroy; override;
  end;

  TCacheBatchList = specialize TList<TCacheBatch>;

  { Задание фонового монтажа: пустую инертную сцену Scene (Exists=False, уже
    добавленную в граф) наполняет Scene.Load(Root) в TMountWorker. }
  TMountJob = record
    Scene: TProfiledScene;
    Root:  TX3DRootNode;
  end;

  TTilePreviewDataArray = array of TTilePreviewData;

  { Задание фон-ассемблера: превращает модели (владеет ими) в X3D-граф.
    Владение: Models/Previews/BatchBorder — job; Previews освобождает воркер
    после сборки; BatchBorder/Assembled — MountAssembled; Models — DrainAssembled. }
  TAssembleJob = record
    Ids:         TGeoTileIdArray;
    Models:      TTileModelArray;
    Previews:    TTilePreviewDataArray;
    BatchBorder: TBorderWorldMap;
    Assembled:   TAssembledScenes;
    Trees:       TTileTreeRecArray;
    TAsm0:       QWord;
    TAsmMs:      QWord;
    Failed:      Boolean;
  end;

  TOsm3dStreamingMap = class(TCastleScene)
  private
    FGpuGround:TOsmGpuGround;
    FProj:      TLocalProjection;
    { Коррекция высот по нивелированному FIT (в памяти, на лету). }
    FFitCorr:   TFitCorrection;
    { Папка заездов *.fit для нивелирования датума (сеть всех заездов).
      Пустая — коррекция не строится. Задаётся SetRoutesFolder. }
    FRoutesFolder: String;
    { Имя выбранного *.fit (какой заезд правит террейн). }
    FSelectedFit:  String;
    FOrigin:    TLatLon;
    FSunDir:    TVector3;
    FSunShadowsAllowed: Boolean;
    FCache:     TGeoTileCache;
    FStreamer:  TTileStreamer;
    FBlockGen:  TOsm3dBlockGenerator;
    FEdge:      Double;
    { Широта метрики КАДРА сессии (EffectiveWorldScaleLat: ручная фиксация
      или полоса от широты origin) — для FProj и решётки кэша. Выпечка от
      неё больше НЕ зависит: каждый тайл печётся в метрике своей полосы
      (география тайла); сведе́ние — пер-тайловый Kx в ассемблере. }
    FWorldScaleLat: Double;
    { Сырая ручная фиксация из настроек (0 = авто/полосы) — уходит в
      AssembleCachedTiles: ассемблер сам повторяет развилку выпечки для
      КАЖДОГО тайла (TileBakeScaleLat), передавать ему вычисленную широту
      кадра нельзя — потерялся бы признак «авто». }
    FManualScaleLat: Double;
    FHeightmapZoom: Integer;
    FGenerateFarTerrain: Boolean;      { False → дальняя земля вообще не строится }
    FHmFetcher: TTerrariumFetcher;     { общий terrarium, НЕ владеем (B/C-высоты) }
    FPrevTex:   TPrevTexFetcher;        { владеем; превью-текстуры по блокам }

    { the map scene's own graph: shared resources + lights }
    FWorldRoot: TX3DRootNode;

    { the secondary cache: tree of batch nodes + a flat tile index }
    FBatchList: TCacheBatchList;                              { root blocks }
    FTileIndex: specialize TDictionary<Int64, TCacheTile>;  { ключ = Tile.ToKey }
    { Строковое зеркало FTileIndex — только для путей, где ключ приходит
      строкой извне (теневые очереди стримера: PeekShadowUpload, FShadowReReq).
      Мутируется строго вместе с FTileIndex (Add/Remove/Clear). }
    FTileIndexStr: specialize TDictionary<string, TCacheTile>;
    { Far-ground: ОДНА постоянная камера-центрированная сцена фиксированной
      топологии. При пересечении ячейки высоты не пересобираются, а плавно
      морфятся (Retarget + покадровый Animate) — без фриза от пересбора. }
    FFarGround:    TOsm3dFarGround;
    FFarHasCenter: Boolean;
    FFarLogLast:  QWord;        { гейт бёрст-лога [far] (раз в ~2 c) }
    FFarLogBurst: Boolean;
    FFarClipLog:  string;       { последняя сводка клипа — лог по изменению }
    FFarClipDirty: Boolean;
    FFarClipUnloadM: Single;
    FFarCenterX, FFarCenterZ: Single;

    FZone:      Byte;
    FNorth:     Boolean;

    FLodTree:    TLodTree;
    FLodCb:      TLodHostCallbacks;
    { Base cells the ring currently shows; SwapGreenToDetail uses it to light
      a tile the moment the streamer mounts it. }
    FTreeWantBase: specialize TDictionary<string, Boolean>;
    { Плейсхолдеры загрузки (ключ = tile.ToString). }
    FLoadOwner: TCastleTransform;
    FLoadTiles: specialize TDictionary<string, TLoadTile>;

    { Vegetation owner — a CGE child of the map. }
    FVegOwner:  TCastleTransform;

    FAsmCache:  TCachedAssemblyResources;

    FWindTimeFields: array of TSFFloat;   { per-tile uWindTime (every-frame push) }
    FWindBaseFields: array of TSFFloat;
    FWindGustFields: array of TSFFloat;

    { FIT route in lat/lon. The host sets it once (SetRoute) before the
      first tile streams in. As each tile is mounted, the route points
      that fall inside that geo-tile are materialised as a small cluster
      of marker spheres parented under the tile scene — so they stream,
      cull and free together with their tile (the whole-scene one-shot
      overlay of the chunk pipeline has no equivalent here). Empty =
      no overlay. }
    FRoute: TRouteLatLonArray;

    { Original FIT altitude per raw-route point (absolute metres), parallel
      to FRoute. Set by SetRoute. Drives the blue "original height" marker
      spheres (Y straight from the track instead of sampled off terrain).
      Empty when the route carried no altitude. }
    FRouteAltM: TRouteAltArray;
    { Высота рельефа под каждой точкой маршрута, снятая ДО фит-коррекции
      (красные сферы = опорный рельеф). Заполняется CaptureRawGroundY в
      обоих путях монтажа перед ApplyToTileModel; красный overlay садится
      на неё через UseTrackY — как синий на FRouteAltM. }
    FRouteGroundRaw: TRouteAltArray;

    { ЧИСТЫЙ DEM (сырой Terrarium, билинейно) под точками FRoute — НОВЫЙ
      независимый канал сверки (колонка alt_dem_m студийного CSV).
      Зачем. FIT-коррекция высот ПЕЧЁТСЯ в геометрию на этапе генерации тайла
      (FIT-слой фетчера → Osm3dBlockGenerator: Builder.FitLayer, сигнатура
      слоя входит в gen-hash — геометрия зависит от FIT по построению).
      Поэтому FRouteGroundRaw (меш тайла) — уже скорректированная земля, и
      сверкой «голубой↔красный» коррекцию проверяли по поверхности, в которой
      она сама и сидит: замкнутый круг, коэффициент уклонов льстит.
      Источник и метод здесь те же, что у Bank[].Dem в Osm3dFitBank
      (GetRegion + SampleBilinear на FHeightmapZoom) — то есть РОВНО тот вход,
      который потребляет BuildDriftCorrected. По CSV становится проверяемым
      само правило V(d) = медиана(fit − dem) в окне ±HALF_M.
      КРАСНЫЙ КАНАЛ НЕ ТРОГАЕМ: сферы слота 0 и колонка alt_surf_m
      по-прежнему идут с FRouteGroundRaw (меш тайла) — это отдельный,
      сложившийся канал. Здесь ДОБАВЛЕН независимый: студийный CSV пишет его
      колонкой alt_dem_m (см. Osm3dStudioMainForm.THeightsCsvWorker).
      Снимается off-thread (CaptureRouteDem), публикуется на главном потоке
      (PublishFitCorrection). }
    FRouteDem:        TRouteAltArray;
    FPendingRouteDem: TRouteAltArray;
    FRouteDemPending: Boolean;
    { Скорректированный (датумный) FIT на точку маршрута — голубые сферы
      и столбец CSV. Считается off-thread (ComputeFitCorrectionOffThread)
      в FPendingRouteAltCal, публикуется сюда PublishFitCorrection из
      Bank[Sel].AltCal; пусто, пока коррекция не построена. }
    FRouteAltCal: TRouteAltArray;

    { Snapped copy of FRoute — the route pulled onto the road network,
      shown as green marker spheres beside the raw red ones. Produced
      off-thread by TRouteSnapWorker (route bbox → cached/generated
      tiles' road segments → TRouteSnapper), публикуется на главном
      потоке из FPendingSnapped в OnRouteSnapDone (воркер сам это поле
      НЕ пишет). FSnappedReady flips true
      when the worker finishes; from then on MountBatch mounts the green
      cluster too, and the completion sweep retro-fits already-mounted
      tiles. }
    FRouteSnapped: TRouteLatLonArray;
    FRouteRide, FPendingRide: TRouteLatLonArray;
    FRouteRideWidths, FPendingRideWidths: TRouteWidthArray;
    FRouteRideSource, FPendingRideSource: TRouteSourceArray;
    { Per-snapped-point road width (metres); 0 = off-road. Parallel to
      FRouteSnapped. Produced by the route snapper, consumed by the
      avatar-road INI writer for lane positioning. }
    FRouteWidths: TRouteWidthArray;
    { Per-snapped-point road CENTERLINE position (foot on the segment
      centerline the point was snapped toward). Parallel to FRouteSnapped.
      For wide roads the snap target is lane-inset, but this is the true
      centerline — consumed by the avatar-path debug overlay. }
    FRouteCenters: TRouteLatLonArray;
    { Per-snapped-point OSM way id (0 = off-road). Parallel to
      FRouteSnapped. Produced by the route snapper. The green marker
      overlay uses it to take Y from the surface of exactly that way:
      on bridges the deck vertices carry the bridge way id, so markers
      ride the deck instead of the terrain (river) underneath. }
    FRouteWays: TRouteWayIdArray;
    FSnappedReady: Boolean;
    FBotCrossings,FPendingBotCrossings:TBotCrossingArray;
    { Результаты снапа ДО публикации: воркер складывает сюда свои локальные
      массивы (каждый — одним присваиванием уже после возврата Snap), а
      главный поток забирает их в OnRouteSnapDone (Queue даёт границу
      happens-before) и переносит в FRouteSnapped/FRouteWidths/FRouteCenters/
      FRouteWays. Так main никогда не читает массивы, которые воркер ещё
      заполняет, а прежние массивы освобождаются только на главном потоке. }
    FPendingSnapped: TRouteLatLonArray;
    FPendingWidths:  TRouteWidthArray;
    FPendingCenters: TRouteLatLonArray;
    FPendingWays:    TRouteWayIdArray;
    { When True, OnRouteSnapDone deferred the green-overlay retro-fit of
      already-mounted tiles to a per-frame budgeted pass
      (RetrofitGreenBudget) instead of doing every tile in one
      main-thread call — that one-shot loop froze the whole UI. }
    FGreenRetrofit: Boolean;
    { Зелёные сферы: высота настила/дороги/рельефа под СНАПНУТОЙ точкой,
      снимается инкрементально (CaptureRouteGroundY) по мере монтажа тайлов
      и резидентным добором (RetrofitGreenBudget). SPHERE_Y_NONE = ещё не
      снята — бакер такую точку пропускает (не висит в воздухе). }
    FRouteSnappedY: TRouteAltArray;
    { Max deck-slab Y seen while capturing route ground (bridge-way verts /
      verts near IsBridge segs). Capture is one tile at a time; approaches
      on the previous tile need this max on a second pass (refresh_y /
      SetFitPointOverlays). SPHERE_Y_NONE = not yet known. }
    FBridgeDeckYMax: Single;
    { Отладочные сферы FIT запечены в ОДИН меш на цвет (а не кластер сфер на
      тайл): 0=красный сырой рельеф, 1=синий исходная высота, 2=голубой
      фит-коррекция, 3=зелёный снап. Один draw-call на цвет — FPS не зависит
      от числа точек в кадре. Пересобираются лениво по FSphereDirty с
      троттлингом (SPHERE_REBUILD_MS), удерживаются на карте (Add), сами
      освобождаются в Destroy (FreeSphereScenes). }
    FSphereScene:       array[0..3] of TCastleScene;
    FSphereDirty:       array[0..3] of Boolean;
    FSphereRebuildTick: QWord;
    FSphTplV:           array of TVector3;  { шаблон низкополиг. сферы (R=FIT_SPHERE_RADIUS_M) }
    FSphTplIdx:         array of LongInt;   { грани шаблона: квады, -1-терминатор }

    { Режим «геометрия только вдоль пути FIT» (ASettings.GenerateRouteOnly):
      строить ТОЛЬКО тайлы коридора вокруг сырого маршрута FRoute в радиусе
      FRouteOnlyRadiusM. Набор коридора считается один раз (BuildRouteCorridor).
        • FCorridorSet — членство тайла в коридоре; предикат CorridorWantFilter
          отдаётся стримеру (keyhole пропускает всё вне коридора).
        • FCorridorTiles — список всех тайлов коридора для префетча ВСЕГО
          коридора на диск (PregenTile, по бюджету за кадр).
        • FCorridorLatched — тайлы, уже запрошенные на префетч (латч).
        • FCorridorPregenIdx — курсор бюджетного префетча по FCorridorTiles. }
    FRouteOnlyGeom:     Boolean;
    FRouteOnlyRadiusM:  Single;
    FCorridorSet:       specialize TDictionary<string, Boolean>;
    FCorridorTiles:     TGeoTileIdArray;
    FCorridorLatched:   specialize TDictionary<string, Boolean>;
    FCorridorPregenIdx: Integer;
    { Построенный off-thread FIT-слой высот (по всей папке заездов). Главный
      поток забирает его в PublishFitCorrection и ставит в ФИЗИЧЕСКИЙ слот
      FFitPhysLayer (не в фетчер — меши/тайлы/кэш слоем больше не
      корректируются). }
    FPendingFitLayer:    TFitHeightLayer;
    FPendingRouteAltCal: TRouteAltArray;
    FFitCorrPending:     Boolean;
    { Рабочий FIT-слой ФИЗИКИ езды: GroundYAt добавляет его поправку к
      высоте рельефного треугольника (мосты/настил/нивелированный профиль).
      Чисто рантайм-данные: в gen-hash и в геометрию тайлов не входит,
      читается только главным потоком (физика колёс, снап-запросы).
      Владеет карта; ставится из Session.Create или из PublishFitCorrection. }
    FFitPhysLayer:       TFitHeightLayer;
    { BUILDING_OBSTACLE: session grid of solid building footprints from
      mounted tiles. Camera / rider query this instead of mesh colliders. }
    FBuildingObstacles:  TBuildingObstacleIndex;
    { Строить ли FIT-слой в снап/light-воркере (датум всей папки заездов —
      десятки секунд на холодном CSV-кэше). Деф. True (игра/статистика).
      Хост может выключить (лёгкий путь страницы маршрутов — простой клик):
      тогда воркер считает только голубой профиль высот выбранного заезда,
      а физический слот остаётся как установлен из Session.Create. }
    FFitLayerBuild:      Boolean;
    FSnapWorker:   TThread;
    { Воркер «только коррекция» — строит голубой профиль высот из DEM
      (ComputeFitCorrectionOffThread) БЕЗ снапа/тайлов и публикует его
      (Queue → PublishFitCorrection). Для лёгкого пути страницы маршрутов:
      простой клик даёт голубые высоты, тайлы не грузятся. }
    FFitCorrWorker: TThread;
    { Фоновый монтаж сцен (GlobalMountInWorker). FMountWorker наполняет
      Scene.Load в фоне инертные (Exists=False) сцены из FMountQueue; main
      активирует их (Exists=True) по готовности (Scene.MountLoaded). Перед
      освобождением любой сцены (EvictBatch/TeardownAll/destructor) main делает
      FlushMountWorker — ждёт, пока поток не отпустит все сцены. }
    FMountWorker:  TThread;
    FMountQueue:   specialize TQueue<TMountJob>;
    FMountLock:    TRTLCriticalSection;
    FMountWake:    PRTLEvent;
    FMountPending: Integer;
    { Фон-ассемблер (GlobalAssembleInWorker) — nil, если выключен. }
    FAssembleWorker: TThread;
    FAsmQueue:       specialize TQueue<TAssembleJob>;
    FAsmDoneQueue:   specialize TQueue<TAssembleJob>;
    FAsmLock:        TRTLCriticalSection;
    FAsmWake:        PRTLEvent;
    FAsmPending:     Integer;
    FSnapCancel:   Boolean;
    { Route-snap tile hold. The worker publishes the route's tiles and
      raises FSnapHoldEviction; the main-thread Update then WantTiles them
      every frame and freezes streamer eviction until the worker lowers the
      flag (after it has harvested the segments from the ready tiles). }
    FSnapForceTiles:  TGeoTileIdArray;
    FSnapHoldEviction: Boolean;
    { Оверлей прогрева маршрута: полноэкранная плоская карта с прогрессом
      каждого тайла, видимая пока держится FSnapHoldEviction. Владеем как
      компонентом; в UI-дерево его вставляет хост
      (Viewport.InsertFront(Map.WarmupOverlay)). }
    FWarmup:          TOsm3dWarmupOverlay;
    FAuxHttp:         THTTPFetcherWithCache;  { фетчер сессии — растровая подложка прогрева }
    FWarmupShown:     Boolean;
    FWarmupDone:      array of Boolean;       { параллельно FSnapForceTiles; защёлки готовности }
    FWarmupNextDiskChk: QWord;                { троттлинг FCache.Has (диск) }
    { Фронтир прогресса снаппера (индекс точки маршрута, 0..N): пишет
      поток снапа простым присваиванием, читает Update для анимации
      перекраски маршрута на экране прогрева. }
    FSnapProgressPt:  Integer;
    { Прогресс harvest (загрузка дорог из тайлов): FSnapHarvestN — сколько
      тайлов уже прогружено (0..M), FSnapHarvesting — идёт ли фаза harvest.
      Пишет поток снапа простыми присваиваниями, читает Update для
      зелёной анимации клеток. Индекс тайла в harvest совпадает с
      FSnapForceTiles (Tiles := Copy оттуда). }
    FSnapHarvestN:    Integer;
    FSnapHarvesting:  Boolean;
    { Холд гашения оверлея прогрева до постановки райдера (см. публичное
      поле WarmupHoldRider ниже): пока режим включён, Update НЕ прячет
      оверлей по обычному условию, пока хост не вызвал NotifyRiderPlaced.
      До подтверждения стримим вокруг старта, независимо от камеры. }
    FWarmupHoldRider:   Boolean;
    FWarmupRiderPlaced: Boolean;
    FPointWarmup: Boolean;
    FPointWarmupGeo: TLatLon;
    FPointWarmupTile: TGeoTileId;
    FPointWarmupNextUpdate: QWord;
    { Ошибка прогрева для оверлея: снап-воркер пишет строку ОДИН раз до
      завершения (обрыв ожидания по застою / исключение), main читает в
      Update и показывает через SetError + этап → wssError. Строка пишется
      одним присваиванием и дальше воркером не трогается (refcount в FPC
      интерlocked — гонки записи нет). FSnapErrorStage — этап (0..5)
      для wssError, −1 = не задан. }
    FSnapError:      string;
    FSnapErrorStage: Integer;
    FSnapErrorShown: Boolean;
    { Прогресс фонового построения FIT-коррекции (BuildFitBank): текущий
      заезд из M. Пишет fitcorr-поток простым присваиванием через
      указатели, отданные в BuildFitBank; читает main для этапа оверлея
      «Коррекция высот». }
    FFitCorrProgCur:   Integer;
    FFitCorrProgTotal: Integer;
    { Этап «Коррекция высот» запущен снап-путём: Update водит его
      состояние (active «N / M» → done) по FFitCorrWorker.Finished.
      Взводит снап-воркер перед запуском fitcorr-потока. }
    FFitCorrStageRun:  Boolean;
    { Защёлки этапов, помеченных ошибкой (WarmupFail): NotifyRiderPlaced
      и финальные wssDone не перекрывают wssError. }
    FWuStageErr: array[0..WARMUP_STAGE_COUNT - 1] of Boolean;
    { Map-life accumulator; once it passes SNAP_AUTO_DELAY_S the route
      snap auto-fires once (FSnapAutoDone latches it). }
    FLifeSeconds:  Single;
    FSnapAutoDone: Boolean;

    { Whether to materialise the FIT route as debug marker spheres (one
      baked mesh per colour — see RebuildSphereScene). Mirrors
      TStudioSettings.ShowFitPoints / ShowFitPointsSnapped, captured at
      construction. The in-game trainer passes False (the avatar itself
      indicates the route) and skips the height capture + bake entirely.
      The route still flows through SetRoute so the snap worker runs —
      only the visual overlay is suppressed. }
    FShowFitPoints:        Boolean;
    FShowFitPointsSnapped: Boolean;

    FTreeRenderer:  TCastleAbstractTreeRenderer;
    FShrubRenderer: TCastleAbstractShrubRenderer;
    FProceduralRenderer: TOsmProceduralVegetation;
    FGrassRenderer: TGrassRenderer;
    FGenerateTrees: Boolean;

    FLog:       TLogTarget;
    FMainLog:   TLogTarget;

    FDestroying: Boolean;

    { diagnostics }
    FLastFrameTick: QWord;
    FDiagTick:      QWord;
    FDiagFrames:    Integer;
    FDiagMounted:   Integer;
    { Monotonic source for TCacheTile.MountGen. Incremented once per tile
      mount (never reset), so every mount — including a re-mount of a tile
      that just evicted — gets a unique generation. Used to fence stale
      off-thread shadow uploads (see TCacheTile.MountGen). }
    FShadowGen:     QWord;
    { Tiles a pack push pass skipped because they still had an in-flight
      (pre-caster) shadow job. Drained in Update once each tile's job
      clears — one corrective re-gen from the now-current registry, so a
      receiver mounted BEFORE its caster does not keep the caster-less
      mask and the shadow does cross the shared edge. Main-thread only. }
    FShadowReReq:   specialize TDictionary<string, Byte>;
    FWaterDiagAccum: Single;   { аккумулятор для периодического WATER DIAG }
    FActiveTiles:   Integer;

    procedure BuildWorldGraph;
    procedure LogMain(const AMsg: string);
    { Как LogMain, но дополнительно прокидывает строку в callback хоста
      (игровой Logger). Для диагностики, видимой в общем логе игры. }
    procedure LogCallback(const AMsg: string);
    function  GetGlobalScene: TCastleScene;

    { cache helpers }
    procedure EnqueueMount(Sc: TProfiledScene; Root: TX3DRootNode);
    procedure FlushMountWorker;
    procedure SyncMountedExists;
    function TileSceneReady(const AId: TGeoTileId): Boolean;
    procedure ActivateTile(ATile: TCacheTile);
    procedure DeactivateTile(ATile: TCacheTile);

    { per-frame distance cut — toggles Scene.Exists on slot-active tiles
      by camera distance to the tile positioning centre. }

    { Re-collect every live batch's per-tile wind uniform fields
      (uWindTime/uWindBase/uWindGustSpeed). Called after any change to the
      resident set (mount / evict / teardown) so the per-frame wind push
      never .Sends into a freed field. }
    procedure RefreshGroundWindFields;

    { Build + enqueue one resident tile's shadow-mask gen job from the
      current registry snapshot. True if a job was issued (tile has a live
      mask node and at least one silhouette reaches its window). Shared by
      the pack push pass and the deferred re-request drain. }
    function EnqueueTileShadow(ACT: TCacheTile): Boolean;

    { assemble + cache a pack of delivered tile models }
    procedure MountBatch(const AIds: array of TGeoTileId;
      const AModels: array of TTileModel);
    { Общий пролог MountBatch / EnqueueAssembleBatch: красные сферы высот
      (CaptureRawGroundY), превью земли для LOD B/C (BuildHeightPreview),
      сшивка границ с соседями (SyncTileBorders — ошибка сварки не срывает
      монтаж) и прогрев альфа-масок деревьев (SetTreeShadowDir). }
    procedure PrepareBatchForAssemble(const AIds: array of TGeoTileId;
      const AModels: array of TTileModel;
      out APreviews: TTilePreviewDataArray; out ABorder: TBorderWorldMap);
    procedure MountAssembled(Assembled: TAssembledScenes;
      const Trees: TTileTreeRecArray; BatchBorder: TBorderWorldMap;
      const AModels: array of TTileModel; const AIds: array of TGeoTileId;
      TAsmMs: QWord);
    procedure EnqueueAssembleBatch(const AIds: array of TGeoTileId;
      const AModels: array of TTileModel);
    procedure DrainAssembled;
    procedure FreeAssembleJob(const J: TAssembleJob);
    procedure FreeRemainingAssembleJobs;
    procedure MountTileTrees(const ACenter: TVector3;
      const ATrees: TTileTreeRecArray);
    procedure MountTileGrass(ACT: TCacheTile; AModel: TTileModel);

    { Отладочные FIT-сферы — ОДИН запечённый меш на цвет (замена кластеров
      на тайл: тысячи TShapeNode давали тысячи draw-call и роняли FPS).
      BuildSphereTemplate строит один низкополиг. шаблон сферы; каждая точка
      маршрута штампует его вершины со смещением в свою мировую позицию, всё
      сливается в ЕДИНЫЙ TIndexedFaceSet → одна сцена, один draw-call.
      RebuildSphereScene пересобирает сцену цвета; UpdateDirtySphereScenes
      делает это лениво и с троттлингом по FSphereDirty. }
    procedure BuildSphereTemplate;
    procedure RebuildSphereScene(AIdx: Integer;
      const ARoute: TRouteLatLonArray; const AYArr: TRouteAltArray;
      const AColor: TVector3; const ALabel: string);
    procedure FreeSphereSlot(AIdx: Integer);
    procedure FreeSphereScenes;
    procedure MarkSphereDirty(AIdx: Integer);
    procedure UpdateDirtySphereScenes;

    { Route-only geometry (ASettings.GenerateRouteOnly). }
    { Построить набор тайлов коридора из сырого FRoute (радиус
      FRouteOnlyRadiusM) и поставить предикат-фильтр keyhole стримера. }
    function TileScaleX(const AId: TGeoTileId): Double;
    procedure BuildRouteCorridor;
    { Предикат стримера: тайл принадлежит коридору маршрута? (главный поток). }
    function  CorridorWantFilter(const AId: TGeoTileId): Boolean;
    { Per-frame: поставить в очередь генерации порцию тайлов коридора (весь
      коридор печётся на диск, бюджет на кадр; уже лежащие на диске пропускаем). }
    procedure PumpRouteCorridorPregen;
    { Снять высоту под точками маршрута с моделей батча (var AYArr, параллельно
      ARoute). Мосты: только для точек «путь по мосту» (way IsBridge / parallel
      near deck / продолжение заезда·съезда вдоль маршрута) Y берётся с
      настила; поперечная дорога ПОД пролётом не поднимается (не parallel).
      Не снятые точки остаются SPHERE_Y_NONE.
      Красный: FRoute + FRouteWays; зелёный: FRouteSnapped + FRouteWays. }
    procedure CaptureRouteGroundY(const AModels: array of TTileModel;
      const AIds: array of TGeoTileId; const ARoute: TRouteLatLonArray;
      const AWays: TRouteWayIdArray; var AYArr: TRouteAltArray);
    { After full-corridor Y capture: raise approach holes toward deck
      plateau ahead along the route (+1.5..+20 m, forward only). }
    procedure LiftBridgeApproachY(const ARoute: TRouteLatLonArray;
      var AYArr: TRouteAltArray);
    { Снять опорные высоты для красных (и, если снап готов, зелёных) сфер с
      моделей батча и пометить их сцены на пересборку. Вызывается из обоих
      путей монтажа. }
    { Снять ЧИСТЫЙ DEM под точками маршрута. Тяжёлое: GetRegion может уйти
      на диск или в сеть — звать ТОЛЬКО из воркера, никогда с главного
      потока. Фетчер потокобезопасен (см. ComputeFitCorrectionOffThread). }
    procedure CaptureRouteDem;
    procedure CaptureRawGroundY(const AModels: array of TTileModel;
      const AIds: array of TGeoTileId);

    { Build a tile's coarse terrain heightfield (tile-local frame) from
      the source TTileModel before the streamer frees the model. Only
      ground/terrain-class meshes feed it — buildings, roads, water are
      skipped (their Y is not ground). Feeds GroundYAt. }
    procedure BuildGroundField(ACT: TCacheTile; AModel: TTileModel;
      const Curbs: TCurbMesh);

    { Приварка граничных вершин делегатных моделей к уже загруженным
      соседям ДО сборки сцены. Для каждой модели пачки, у которой ещё нет
      резидентного тайла, граничные вершины композита подменяются мировыми
      точками 8 соседей (резидентных из FTileIndex и более ранних из этой
      же пачки), если те ближе TILE_BORDER_WELD_EPS_M. Всегда меняем
      НОВУЮ вершину на СТАРУЮ. Мировые границы каждой модели кладёт в
      ABatchBorder (ключ = TileId.ToString) — оттуда их берёт CT.BorderWorld. }
    procedure SyncTileBorders(const AModels: array of TTileModel;
      ABatchBorder: TBorderWorldMap);

    { Completion handler — runs on the main thread (Queue'd from the
      snap worker). Publishes FRouteSnapped and arms FGreenRetrofit; the
      actual green-cluster mounting of already-resident tiles is then
      done a few tiles per frame by RetrofitGreenBudget. }
    procedure OnRouteSnapDone;

    { Per-frame budgeted green-overlay retro-fit. Mounts the snapped
      route's sphere cluster onto up to GREEN_RETROFIT_PER_FRAME
      already-resident tiles, then yields; resumes next frame until
      every resident tile is done. Replaces the one-shot all-tiles loop
      that loaded + built geometry for hundreds of tiles in a single
      main-thread call and froze the UI. }
    procedure RetrofitGreenBudget;
    { Far-ground clipmap: height-grid callback (TFarHeightGridFunc) + rebuild
      centred on the camera. }
    function  FarHeights(const ABox: TLatLonBox; AGrid: Integer): THeightArray;
    procedure RebuildFarGround(const ACamPos: TVector3);
    procedure UpdateFarClip;
    procedure LogFarClip(const ARadii: array of Single);

    { base-tile ring host (TLodHostCallbacks targets) }
    function  CellGeoId(const AId: TLodCellId): TGeoTileId;
    function  LodFactory(const AId: TLodCellId): TLodCell;
    procedure HostShowBase(const AId: TLodCellId; AOn: Boolean);
    procedure HostReleaseBase(const AId: TLodCellId);
    { Прогресс-плейсхолдеры загрузки тайлов. }
    procedure HandleBlockPhase(const ABlock: TBlockId; APhase: TBlockPhase;
      const Stage: string; Completed, Total: Int64);
    { Общая billboard-надпись прогресса загрузки (пустой текст — заполняется
      позже через ATextNode): BuildLoadingScene / BuildGroundLoadingScene. }
    function  MakeLoadingLabel(Root: TX3DRootNode; const APos: TVector3;
      AFontSize: Single; out ATextNode: TTextNode): TTransformNode;
    function  BuildLoadingScene(const ACenter: TVector3;
      ASizeXZ, ABoxH, AFloorY: Single; out ATextNode: TTextNode;
      out ABoxT, ATxtT: TTransformNode;
      out ABoxMat: TMaterialNode): TCastleScene;
    function  LoadPhaseText(const AId: TGeoTileId): string;
    procedure UpdatePointWarmup;
    { Стадия+процент фазы тайла — общий источник и для 3D-плейсхолдера
      (LoadPhaseText), и для 2D-столбиков прогрева: текст гарантированно
      одинаковый. False = нет активной фазы (очередь/кэш/готов). }
    function  LoadPhaseInfo(const AId: TGeoTileId;
      out AStage: string; out APct: Integer): Boolean;
    procedure EnsureLoadTile(const AId: TGeoTileId);
    procedure RemoveLoadTile(const AKey: string);
    procedure UpdateLoadTiles;
    function  BuildLoadBlendEffect(GR, GG, GB, FR, FG, FB: Single): TEffectNode;
    function  BuildGroundLoadingScene(const ACenter: TVector3;
      ASizeX, ASizeZ: Single;
      const AHeights: THeightArray; AN: Integer; out ATextNode: TTextNode;
      out ACoord: TCoordinateNode;
      out AInterp: TCoordinateInterpolatorNode;
      out ATimer: TTimeSensorNode): TCastleScene;
    { Тяжёлая постройка коррекции террейна по FIT — зовётся ИЗ воркера
      (off-thread, TFitCorrOnlyWorker / лёгкий путь): грузит банк
      FIT+DEM, строит дрейф-профиль, кладёт в FPendingFitLayer/
      FPendingRouteAltCal/FPendingRouteDem. Прогресс по заездам банка
      пишет в FFitCorrProgCur/FFitCorrProgTotal. НЕ трогает
      FFitCorr/FBatchList/FRouteSnapped. }
    procedure ComputeFitCorrectionOffThread;
    { Публикация готовых результатов фит-воркера на ГЛАВНОМ потоке (из
      OnRouteSnapDone): FRouteAltCal/FRouteDem + FIT-слой физики. }
    procedure PublishFitCorrection;
    procedure SwapToGroundMesh(ALt: TLoadTile; const AHeights: THeightArray);
    procedure StartMeshMorph(ALt: TLoadTile; const AHeights: THeightArray);
    function  HeightsDiffer(const A, B: THeightArray): Boolean;
    procedure FreeAllLoadTiles;
    procedure SwapGreenToDetail(const AId: TGeoTileId);

    { eviction — detach shared nodes, then full release (per-batch) }
    procedure EvictBatch(ABatch: TCacheBatch);
    procedure PurgeFarBatches(const ACamPos: TVector3);

    { full teardown WITH release — Destroy only }
    procedure TeardownAll;
  public
    UploadsPerFrame:  Integer;
    TileCullDistance: Single;

    constructor Create(AOwner: TComponent; const AOrigin: TLatLon;
      const ACacheRoot, AGenHash: string;
      AHttp: THTTPFetcherWithCache;
      ATerrFetcher: TTerrariumFetcher;
      AOverpass: TOverpassClient;
      const ASettings: TStudioSettings;
      ALog: TLogTarget = nil;
      AMainLog: TLogTarget = nil; AStartUTC: TDateTime = 0); reintroduce;
    destructor Destroy; override;
    { Retiring detached map: signal on main, wait on a reaper, then Destroy
      on main. Neither phase frees Castle/GL objects. }
    procedure RequestBackgroundStop;
    procedure JoinBackgroundStop;

    procedure Update(const SecondsPassed: Single;
      var RemoveMe: TRemoveType); override;

    procedure RenderGpuGround;
    function GpuGroundInfo:string;
    function GrassDiagnostics:string;
    procedure ProbeGpuGround(X,Z,ReferenceY:Single; out CpuY,GpuY:Single;
      out CpuHit,GpuHit:Boolean;QueueGpu:Boolean=True);
    procedure SetSunDirection(const ADir: TVector3; AShadowsAllowed: Boolean = True);
    property SunDirection: TVector3 read FSunDir;
    { Same map direction and route-time policy for game and Studio atlases. }
    function SunWorldShadowDir(out ADir: TVector3): Boolean;
    { Called once by the host, before releasing the ride startup hold. }
    function CoastalAtStart(const RadiusM:Double=8000):Boolean;
    function EnvironmentSoundsAt(const P:TVector3):TEnvironmentMix;
    { Borrowed, fully mounted sources. The atlas filters building shapes and
      light-space bounds; no terrain or grass is a caster in this experiment. }
    procedure AppendWorldShadowCasters(const AList: TCastleTransformList);

    { Hand the streaming map the FIT route to overlay. Call once before
      streaming begins; tiles mounted afterwards pick up their slice of
      the route automatically. Safe to pass an empty array (no overlay). }
    procedure SetRoute(const ARoute: TRouteLatLonArray;
      const AAlt: TRouteAltArray = nil);

    { Kick off the off-thread route-snapping pass: route bbox → ensure
      its tiles are cached (load or generate) → collect their road
      centerline segments → TRouteSnapper → green snapped overlay.
      No-op if the route is empty or a snap is already running. The
      worker reads/generates the disk tile cache independently of the
      camera-driven streamer, so it can be called any time after
      SetRoute. }
    procedure BeginRouteSnap;
    { Тайлы маршрута для прогрева/снапа: bbox трека + маржа, отфильтрованные
      «трек реально пересекает тайл». Вызывается с главного потока из
      BeginRouteSnap (нужна для немедленного показа оверлея прогрева);
      воркер пользуется готовым FSnapForceTiles. }
    function ComputeSnapTiles: TGeoTileIdArray;
    { Лёгкий путь: построить ТОЛЬКО голубой профиль высот по FIT из DEM
      (без снапа и без загрузки/генерации тайлов) и опубликовать. Нужен
      SetRoute + SetRoutesFolder; FitLayerBuild обычно False (страница
      маршрутов). No-op, если папка/файл не заданы или уже идёт проход. }
    procedure BeginFitCorrectionOnly;
    { Показать плоскую 2D-карту (растровая подложка OSM + линия маршрута)
      БЕЗ прогрева 3D-тайлов и без 3D-вьюпорта: оверлей ведёт растр из
      своего Update. Нужен SetRoute. Для лёгкого пути страницы. }
    procedure ShowFlatMap;
    { Задать/снять коррекцию высот по FIT; владение переходит карте. }
    procedure SetFitCorrection(ACorr: TFitCorrection);
    { Текущая коррекция (nil если не построена) — для съёма высот
      страницей анализа с тех же скорректированных моделей. }
    property FitCorrection: TFitCorrection read FFitCorr;
    { Физический FIT-слой (nil если не построен): поправка к высоте земли
      для физики езды (GroundYAt). Только чтение; владеет карта. }
    property FitPhysLayer: TFitHeightLayer read FFitPhysLayer;
    { Поставить FIT-слой высот в ФИЗИЧЕСКИЙ слот (GroundYAt физики езды).
      Владение переходит карте. Меши/тайлы/кэш слоем не корректируются —
      это чисто рантайм-поправка к высоте земли для колёс. }
    procedure SetFitPhysLayer(ALayer: TFitHeightLayer);
    { Папка *.fit + выбранный файл для авто-коррекции террейна на снапе.
      Общий путь студии и игры: коррекция строится в OnRouteSnapDone. }
    procedure SetRoutesFolder(const AFolder, ASelectedFit: String);

    { Оверлей прогрева маршрута (плоская карта с прогрессом тайлов).
      Хост один раз вставляет его в UI ПОВЕРХ вьюпорта:
        Viewport.InsertFront(Map.WarmupOverlay);
      Показ/скрытие и состояния тайлов карта водит сама (на время
      удержания тайлов снап-воркером — то есть ровно на прогрев,
      до запуска притягивания). }
    property WarmupOverlay: TOsm3dWarmupOverlay read FWarmup;
    { Free exploration uses the same flat map, waiting for just the start tile. }
    procedure BeginPointWarmup(const Geo: TLatLon);

    { Режим «гейт до постановки райдера» (default True): пока включён,
      оверлей прогрева НЕ гасится по обычному условию (снап+волна), пока
      хост не вызвал NotifyRiderPlaced. Хосты БЕЗ райдера (студия) обязаны
      выключить его при создании сессии — иначе их оверлей не погаснет. }
    property WarmupHoldRider: Boolean
      read FWarmupHoldRider write FWarmupHoldRider;

    { Хост подтверждает: райдер поставлен на старт. Этап «Постановка на
      старт» → done (если не помечен ошибкой через WarmupFail), оверлею
      разрешается гаснуть. Звать из главного потока после финальной
      постановки райдера на землю. }
    procedure NotifyRiderPlaced;
    { Пометить этап прогрева AStage (0..WARMUP_STAGE_COUNT-1) ошибкой
      (wssError + деталь) и показать красную плашку SetError. Езда при
      этом не блокируется — деградация как раньше. Только главный поток. }
    procedure WarmupFail(AStage: Integer; const AMsg: string);

    { True once the off-thread route snap has finished and FRouteSnapped
      holds the route pulled onto the OSM road network. Polled by the
      host to switch the avatar path from the raw FIT track to the
      snapped one. }
    property SnappedReady: Boolean read FSnappedReady;
    { True, когда запущенная BeginRouteSnap подготовка маршрута функционально
      завершена: прогревной холд снят (тайлы маршрута собраны/на диске) и
      снап-воркер закончил Execute (успехом ИЛИ неуспехом — таймаут/отмена/
      исключение тоже «завершение», вечного ожидания нет: у прогрева есть
      прерывание по застою). Экран прогрева НЕ учитывается: его зелёная
      волна — косметика, она доигрывает и прячется сама и не должна
      держать старт заезда. До первого BeginRouteSnap — всегда False.
      Игра держит райдера на месте, пока здесь не станет True
      (см. TViewPlay: FOsmPrepHold). }
    function RoutePrepDone: Boolean;
    { Только главный поток: False, пока считается профиль; по завершении
      публикует его перед чтением RouteAltCal/RouteDem (например, CSV). }
    function TryFinishFitCorrection: Boolean;
    { Диагностика подготовки: 'worker=none|running|finished hold=0|1
      overlay=0|1 snapped=0|1'. Печатается игрой в строке ожидания холда —
      по логу сразу видно, какая фаза не завершилась. }
    function RoutePrepStateStr: string;
    { The snapped route (route pulled onto the road network). Valid only
      when SnappedReady is True; empty otherwise. }
    property SnappedRoute: TRouteLatLonArray read FRouteSnapped;
    property BotCrossings:TBotCrossingArray read FBotCrossings;
    property RideRoute: TRouteLatLonArray read FRouteRide;
    property RideRouteWidths: TRouteWidthArray read FRouteRideWidths;
    property RideRouteSource: TRouteSourceArray read FRouteRideSource;
    { Per-point road width for the snapped route (metres; 0 = off-road).
      Parallel to SnappedRoute. }
    property SnappedRouteWidths: TRouteWidthArray read FRouteWidths;
    { Per-point road centerline position (foot on the segment centerline).
      Parallel to SnappedRoute. Used by the avatar-path debug overlay so
      the road-center line sits on the actual road, not the raw track. }
    property SnappedRouteCenters: TRouteLatLonArray read FRouteCenters;
    { Per-point OSM way id the point snapped onto (0 = off-road). Parallel
      to SnappedRoute. Lets a consumer put the path on the actual road
      SURFACE — including bridge decks — instead of sampling terrain under
      the point (which dives under every bridge). }
    property SnappedRouteWays: TRouteWayIdArray read FRouteWays;
    { Per-point green-sphere Y (road/deck surface under snapped point).
      SPHERE_Y_NONE (~-1e30) = not sampled yet. Parallel to SnappedRoute. }
    property SnappedRouteY: TRouteAltArray read FRouteSnappedY;
    { Raw FIT route (same index space as snap when snap succeeded). }
    property Route: TRouteLatLonArray read FRoute;
    { Скорректированный (датумный) FIT на точку маршрута — для CSV. }
    property RouteAltCal: TRouteAltArray read FRouteAltCal;

    { MCP / debug: JSON report of green-path vs bridges.
      Detects bridge-like spans (green Y >> ground), approach/exit dips
      under the deck, missing green Y (disappearing spheres), way flips.
      Optionally refreshes Y from resident tiles first. }
    function AnalyzeSnapPathJSON(ARefreshY: Boolean = True;
      ABridgeClearM: Single = 1.5): string;
    { Full parallel dump of raw vs snapped arrays (+ Y channels) for MCP.
      AMaxPts caps file size (0 = all). Writes JSON string. }
    function DumpRouteArraysJSON(ARefreshY: Boolean = True;
      AMaxPts: Integer = 0; AStep: Integer = 1): string;

    { Чистый DEM под точками маршрута — красный канал и красная колонка CSV.
      Пусто, пока воркер не снял и не опубликовал. Параллелен Route. }
    property RouteDem: TRouteAltArray read FRouteDem;

    property Streamer: TTileStreamer read FStreamer;
    property GlobalScene: TCastleScene read GetGlobalScene;

    { Convert a camera/world XZ position to geographic lat/lon using the
      session's fixed local projection. Used by the diagnostic overlay. }
    function CameraGeo(LocalX, LocalZ: Single): TLatLon;
    property WorldScaleLatitude: Double read FWorldScaleLat;
    function KnowledgeRecipeHash: string;

    { Обратное к CameraGeo: гео lat/lon → мировые XZ в системе координат
      (фиксированной проекции) этой сессии. Нужно, чтобы перенести камеру в
      заданную географическую точку БЕЗ пересоздания сессии (Y игнорируется). }
    function GeoToLocal(const ALL: TLatLon): TVector3;

    { Tile id covering a camera/world XZ position, as a display string
      (e.g. 'Z41N/1708/33144'). Uses the same pinned-zone tile lattice as
      the streamer, so it matches the shadow-log tile names. }
    function CameraTileName(LocalX, LocalZ: Single): string;

    { Raw Overpass JSON the camera tile was built from (cache only, no
      network). Resolves the covering geo-tile, then reads the source
      from the shared HTTP cache. }
    function CameraTileOsmJson(LocalX, LocalZ: Single): string;

    { Parses the current camera tile's cached OSM, computes each feature's
      world-XZ geometry and keeps only what falls inside the camera frustum
      (the current screen), returning a formatted listing. The frustum is
      built from the passed camera basis + projection params — no network,
      cache only. Sign-symmetric test, so handedness of the basis is
      irrelevant. }
    function CameraScreenFeatures(LocalX, LocalZ: Single;
      const CamPos, CamDir, CamUp: TVector3;
      AspectWH, FovYRad, NearM, FarM, Margin: Single): string;

    { Text table of the SOURCE AWS Terrarium ground heights over the geo-tile
      that currently contains the camera. The tile box's terrarium tiles are
      fetched + stitched (FetchSourceHeightmapForBox) and sampled on a dense
      grid (step ≈ one native terrarium pixel) so road-scale undulation is
      resolved. Heights are the decoded source elevation (SampleBilinear),
      before any geometry leveling. Returns a monospaced north-up / west-left
      matrix with axis labels and min/max/mean. }
    function CameraTileHeights(LocalX, LocalZ: Single): string;

    { Ground height query for the host (the game avatar physics).
      Finds the resident tile covering world XZ and nearest-vertex
      samples its retained terrain mesh. Returns True and sets AY to the
      world-space ground Y when a terrain sample is available; returns
      False when no tile covers XZ yet (not streamed in) or the tile has
      no terrain mesh — the caller should then keep its previous Y.
      Cheap: one dictionary lookup + a nearest-vertex scan of one tile's
      terrain vertices. No collision octree needed. }
    function GroundNearYAt(WorldX,WorldZ,ReferenceY:Single; out AY:Single):Boolean;
    function GroundNearYCorrAt(WorldX,WorldZ,ReferenceY:Single; out AY:Single):Boolean;
    function NearestCurbPoint(WorldX,WorldZ:Single; out P:TVector3):Boolean;
    function GroundShadowAt(WorldX, WorldZ: Single): Single;
    function GroundYAt(WorldX, WorldZ: Single; out AY: Single): Boolean;
    { CPU assembly and scene mounting must finish before a missing GPU
      surface sample can be treated as a placement failure. }
    function GroundSceneReadyAt(WorldX, WorldZ: Single): Boolean;
    function GroundLoadStatusAt(WorldX, WorldZ: Single; out ErrorText: string;
      Diagnostics: TJSONObject = nil): string;

    { Та же высота земли, но с поправкой физического FIT-слоя
      (CorrectHeightGeo поверх сырого треугольника). Для уклона физики
      езды (SlopeQuery): физика ускорений чувствует нивелированный
      профиль заездов, а колёса стоят на видимом меше (GroundYAt). }
    function GroundYCorrAt(WorldX, WorldZ: Single; out AY: Single): Boolean;

    { BUILDING_OBSTACLE: True if world XZ is inside a solid building. }
    function BuildingQuery(WorldX, WorldZ: Single;
      out ABaseY, AMaxY: Single): Boolean;
    function BuildingFootprintsNear(WorldX, WorldZ, Radius: Single): TBuildingObstacleArray;
    { BUILDING_OBSTACLE: soft XZ push out of building footprint. }
    function BuildingPushOutXZ(var WorldX, WorldZ: Single;
      out ABaseY, AMaxY: Single): Boolean;
    { BUILDING_OBSTACLE: camera push-out + soft roof lift. }
    function BuildingBodyMove(const From,Forward,HalfSize:TVector3;
      var Target:TVector3):Boolean;
    function ResolveCameraBuilding(var Cam: TVector3): Boolean;

    { The cache tree's root blocks — the list of batch nodes, exposed so
      callers have something to iterate (for B in Map.RootBlocks do ...). }
    {$IFDEF TILE_MEM_PROFILE}
    function  MemBytesTileAuxCPU: Int64;
    function  MemBytesTileX3DEst: Int64;
    function  MemBytesTileVBOEst: Int64;
    procedure SumResidentSceneGeom(out AVerts, ATris: Int64);
    {$ENDIF}
    property RootBlocks: TCacheBatchList read FBatchList;
    function PendingTileWork: Integer;

    { Toggle the FIT route marker-sphere overlays. Captured from
      TStudioSettings.ShowFitPoints / ShowFitPointsSnapped at Create.
      Writable so the host can flip them at runtime: changes affect
      tiles mounted from now on (already-mounted clusters stay until
      their tile evicts). The game sets both False — the avatar itself
      indicates the route and sphere clusters are pure overhead. }
    property ShowFitPoints: Boolean
      read FShowFitPoints write FShowFitPoints;
    property ShowFitPointsSnapped: Boolean
      read FShowFitPointsSnapped write FShowFitPointsSnapped;
    { Runtime toggle for both raw + snapped FIT path spheres (debug UI).
      AOn=True: sample Y from resident tiles and rebuild overlays.
      AOn=False: free sphere scenes immediately. }
    procedure SetFitPointOverlays(AOn: Boolean);
    function FitPointOverlaysOn: Boolean;
    { Строить FIT-слой высот в снап/light-воркере (физика + голубой профиль).
      Страница маршрутов на простом клике ставит False: только голубые
      высоты выбранного заезда, датум всей папки не гоняем. }
    property FitLayerBuild: Boolean
      read FFitLayerBuild write FFitLayerBuild;
  end;

  { Off-thread route snapper. Walks the FIT route's bounding box, makes
    sure each covered tile is on disk (loads it, or generates its whole
    block via TOsm3dBlockGenerator and saves it), harvests the tiles'
    road centerline segments, runs TRouteSnapper, then Synchronize's
    back to publish the result and mount the green overlay. Owns nothing
    of the map — it only reads the map's cache / block generator /
    projection (all thread-safe for concurrent reads) and writes the
    snapped route into the map under the main thread via Synchronize. }
  { Фоновый монтаж: берёт задания из FMap.FMountQueue и наполняет инертные
    сцены Scene.Load в фоне. Создание/Add сцены и финальный GPU-аплоад (через
    Exists=True) остаются в основном потоке — здесь только CPU-разбор графа. }
  TMountWorker = class(TThread)
  private
    FMap: TOsm3dStreamingMap;
  protected
    procedure Execute; override;
  public
    constructor Create(AMap: TOsm3dStreamingMap);
  end;

  { Фон-ассемблер X3D-графа тайла (см. GlobalAssembleInWorker). Мирроринг
    TMountWorker: сериализованная очередь заданий из FAsmQueue -> FAsmDoneQueue. }
  TAssembleWorker = class(TThread)
  private
    FMap: TOsm3dStreamingMap;
  protected
    procedure Execute; override;
  public
    constructor Create(AMap: TOsm3dStreamingMap);
  end;

  TRouteSnapWorker = class(TThread)
  private
    FMap: TOsm3dStreamingMap;
  protected
    procedure Execute; override;
  public
    constructor Create(AMap: TOsm3dStreamingMap);
  end;

  { Воркер построения FIT-коррекции: считает голубой профиль высот из DEM
    (ComputeFitCorrectionOffThread) и публикует (Queue →
    PublishFitCorrection). Два применения:
      1) лёгкий путь страницы маршрутов — ни снапа, ни тайлов;
      2) снап-путь — запускается снап-воркером ПАРАЛЛЕЛЬНО публикации
         снапа, чтобы BuildFitBank (~40 с) не держал гейт старта езды
         (RoutePrepDone ждёт только FSnapWorker). }
  TFitCorrOnlyWorker = class(TThread)
  private
    FMap: TOsm3dStreamingMap;
  protected
    procedure Execute; override;
  public
    constructor Create(AMap: TOsm3dStreamingMap);
  end;

implementation

uses Osm3dRouteSnapCache,Osm3dCoastline,Osm3dWaterProfile;

{ Off by default: per-frame diagnostics (DIAG ~1 s, FRAME GAP, the SH drn /
  SH drn2 shadow traces, WATER DIAG) are render-loop chatter — thousands of
  lines per session and noise for geometry-build perf analysis. Flip to True to
  restore them. Per-tile lifecycle / build markers go through other calls and
  are NOT affected. }
var
  STREAM_DIAG_VERBOSE: Boolean = False;

  { Аккумулятор троттлинга для GRASS-BLADES diag (лог раз в ~2 c). }
  GrassShaderDiagAccum: Single = 0.0;

  { HOLE-DIAG master switch. When True the map enables extra cut diagnostics to
    LogMain and emits the host-side mount/show/evict markers below. All of it
    goes file-only to osm3d.log (main-thread-safe). Set False to silence once
    the missing-tile cause is found. Greppable tags: LODCUT, HOLE, STUB, SWAP,
    PREV, RELEASE, purge. }
  LOD_HOLE_DIAG: Boolean = False;

  { Диагностика пропажи леса на «обратной дороге». Тег TREEDIAG. Пишет в
    основной лог (LogMain). Поставить False, когда причина найдена. }
  TREE_DIAG: Boolean = False;

const
  TREE_TEXTURES_PATH  = 'data/Osm3d/resources/models/tree/';
  SHRUB_TEXTURES_PATH = 'data/Osm3d/resources/models/shrubbery/';

  { Радиус слот-сетки и cull стримящихся тайлов теперь в TLODConfig
    (GlobalLODConfig.StreamGridRadius / .GroundVisibilityM) — единая
    точка правки дистанций. }

  { FIT route marker spheres. Radius / lift mirror the chunk pipeline's
    overlay (TOsm3dMapTransform.BuildFitPointsOverlayScenes) so the two
    paths look identical. Colour is the same red as the chunk path's
    raw-track overlay. }
  FIT_SPHERE_RADIUS_M = 0.2;
  { Плейсхолдер загрузки тайла. }
  LOAD_BOX_HEIGHT_M     = 60.0;   { высота коробки (XZ = размер тайла) }
  LOAD_TEXT_FACTOR      = 0.16;   { размер шрифта = доля стороны тайла }
  LOAD_FLOOR_RECHECK_MS = 3000;   { период перепроверки высоты пола из кэша }
  { Грубый зум для СРЕДНЕЙ высоты «пола»: один terrarium-тайл покрывает всё
    видимое окно -> один запрос на всех вместо потока запросов на деталь-зуме. }
  LOAD_FLOOR_ZOOM       = 10;
  { Простой меш земли вместо коробки, когда карта высот готова. }
  LOAD_MESH_GRID        = 17;      { сетка меша NxN }
  { Классификация «по мосту»: превышение приведённой высоты FIT над
    поверхностью мира, м. Выше — едем по настилу (правим настил),
    ниже — правим землю (в т.ч. проезд под мостом). }
  BRIDGE_DECK_RISE_M    = 5.0;
  LOAD_MORPH_S          = 0.6;     { длительность X3D-морфа высот, сек }
  LOAD_BLEND_NEAR_M     = 200.0;   { ближе — цвет травы }
  LOAD_BLEND_FAR_M      = 3000.0;  { дальше — цвет дальней земли }
  FIT_SPHERE_LIFT_M   = 1.2;
  { Marker-sphere tessellation. Markers are tiny dots, so a coarse sphere
    is visually indistinguishable from a smooth one while costing a small
    fraction of the triangles. 8×6 ≈ 84 tris vs CGE's default (hundreds). }
  FIT_SPHERE_SLICES   = 8;
  FIT_SPHERE_STACKS   = 6;
  { Запечённые сферы: троттлинг пересборки меша (мс) — гасит всплеск при
    заполнении высот в монтажном берсте, в покое пересборки нет. }
  SPHERE_REBUILD_MS   = 350;
  { Часовой «высота ещё не снята»: бакер такие точки пропускает. Ниже любого
    реального рельефа Земли на много порядков. }
  SPHERE_Y_NONE       = -1.0e30;

  { Resolution of the per-tile terrain heightfield used by GroundYAt.
    64×64 over a ~1.5×2.5 km tile ≈ 25–40 m/cell — finer than the
    avatar needs for smooth following, and the field is 64*64*4 ≈ 16 KB
    per tile. Built once at mount; queried O(1) by bilinear lookup. }
  GroundGridN = 64;

  { Route-snap pipeline. The route bbox is expanded by this margin so a
    road running just outside the track is still a snap candidate. }
  { Halo for block generation in the snap worker — kept equal to the
    streamer's halo so a block the snap worker bakes is byte-identical
    to one the streamer would have baked. }
  SNAP_BLOCK_HALO_M   = 220.0;

  { Route snapper now forces the route's tiles through the normal streamer
    pipeline (so the carve/build runs once and is reused) instead of baking
    its own copy. SNAP_FORCE_PRIORITY is the WantTile priority for those
    tiles (lower = sooner in TakeBestGen). SNAP_STALL_TIMEOUT_MS ниже
    страхует воркер от вечной блокировки, если конвейер застрял. }
  SNAP_FORCE_PRIORITY  = -1.0;      { lower than camera (0) -> built first }
  { Ожидание прогрева перед снапом прерывается ТОЛЬКО по застою: если за
    это время в кэш не лёг НИ ОДИН новый тайл — конвейер застрял (сеть,
    Overpass). Пока тайлы докладываются, ждём сколько нужно: полный
    прогрев холодного кэша на длинном (50+ км) маршруте занимает десятки
    минут, и оверлей прогрева показывает процесс. Прежний фиксированный
    потолок SNAP_WAIT_TIMEOUT_MS=2мин («route is a few blocks») на таких
    маршрутах гарантированно рвал прогрев и снапил по огрызку кэша:
    дороги в наборе обрывались там, куда генерация успела дойти за 2
    минуты, и трек «ехал по обочине» дорог, которых снап не видел. }
  SNAP_STALL_TIMEOUT_MS = 180000;   { 3 мин без единого нового тайла }

  { Seconds of map life before the route snap auto-fires once — lets the
    camera streamer establish its first paint, and lets it cache part of
    the route so the worker has fewer blocks left to generate. }
  SNAP_AUTO_DELAY_S   = 12.0;

  { Green-overlay retro-fit budget — resident tiles greened per frame
    after a snap finishes. Each tile costs one cache disk-load plus a
    sphere-cluster build, both on the main thread, so this is kept low:
    a few hundred resident tiles clear in 1-3 s with no visible hitch,
    instead of the old single-call sweep that froze the UI outright. }
  GREEN_RETROFIT_PER_FRAME = 3;

constructor TCacheBatch.Create;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1701);{$ENDIF}
  inherited Create;
  Owner       := nil;
  Assembled   := nil;
  Tiles       := TCacheTileList.Create;
  ActiveCount := 0;
  CX          := 0.0;
  CZ          := 0.0;
end;

{ Traffic-light cycle: advance every registered accessory Switch through
  green(0) -> yellow(1) -> red(2) (each held for its own duration) by flipping
  WhichChoice. The switches belong to this tile's batch (USE-shared); driving
  them from the current tile only keeps the per-frame work to the batch the
  camera sits in. FdWhichChoice.Send sets the value AND notifies CGE -> live. }
procedure TCacheTile.AnimateAccessories(SecondsPassed: Single);
var
  I:   Integer;
  Dur: Single;
  Sws: array of TSwitchNode;
begin
  if not AnimateTrafficSignalsActive then Exit;
  if (Batch = nil) or (Batch.Assembled = nil) then Exit;
  Sws := Batch.Assembled.AccessorySwitches;
  if Length(Sws) = 0 then Exit;

  { hold the current phase for its own duration }
  case AccPhase of
    0: Dur := ACCESSORY_TL_GREEN_S;
    1: Dur := ACCESSORY_TL_YELLOW_S;
  else Dur := ACCESSORY_TL_RED_S;
  end;

  AccTimer := AccTimer + SecondsPassed;
  if AccTimer < Dur then Exit;
  AccTimer := 0;

  { advance the cycle and show it — Switch child index == phase }
  AccPhase := (AccPhase + 1) mod 3;
  for I := 0 to High(Sws) do
    if Sws[I] <> nil then
    begin
      Sws[I].FdWhichChoice.Send(AccPhase);
      Inc(TrafficSignalSwitchChanges);
    end;
end;

destructor TCacheBatch.Destroy;
var
  CT: TCacheTile;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1702);{$ENDIF}
  { Frees only the lightweight wrappers — TCacheTile records and the
    list. The CGE objects (tile scenes, Owner transform, Assembled
    graph) are released by the caller (EvictBatch / TeardownAll) before
    this runs. }
  if Tiles <> nil then
  begin
    for CT in Tiles do
      CT.Free;
    Tiles.Free;
  end;
  inherited Destroy;
end;

{$IFDEF TILE_MEM_PROFILE}
{ Резидентная геометрия тайлов — то, что байтовые зонды подсистем не видели.
  Обходим дерево батчей FBatchList -> Batch.Tiles. Три статьи:
   tile-aux-cpu : ТОЧНО — наши CPU-массивы на тайл (GroundVertices/GroundIndices доминирует +
                  GroundBin + BorderWorld) для сэмплинга высоты и сварки границ;
   tile-x3d~    : ОЦЕНКА графа X3D в CGE (узлы Coordinate/Normal/TexCoord);
   tile-vbo~    : ОЦЕНКА GPU-VBO смонтированных сцен.
  Оценки — из CGE VerticesCount/TrianglesCount (как профайлер сцены в
  LocalRender). Зовутся из главного потока (DIAG-тик в Update). }
procedure TOsm3dStreamingMap.SumResidentSceneGeom(out AVerts, ATris: Int64);
var
  Bi, Ti: Integer;
  Bn: TCacheBatch;
  CT: TCacheTile;
begin
  AVerts := 0; ATris := 0;
  if FBatchList = nil then Exit;
  for Bi := 0 to FBatchList.Count - 1 do
  begin
    Bn := FBatchList[Bi];
    if (Bn = nil) or (Bn.Tiles = nil) then Continue;
    for Ti := 0 to Bn.Tiles.Count - 1 do
    begin
      CT := Bn.Tiles[Ti];
      if (CT = nil) or (CT.Scene = nil) then Continue;
      { считаем ВСЕ резидентные тайлы, не только видимые: невидимые держат
        VBO/граф на GPU/в RAM до выселения (tile-vbo~ — верхняя оценка, т.к.
        CGE может освобождать GL невидимых сцен; tile-x3d~ — точно резидентен) }
      Inc(AVerts, Int64(CT.Scene.VerticesCount));
      Inc(ATris,  Int64(CT.Scene.TrianglesCount));
    end;
  end;
end;

function TOsm3dStreamingMap.MemBytesTileAuxCPU: Int64;
var
  Bi, Ti, Ci: Integer;
  Bn: TCacheBatch;
  CT: TCacheTile;
begin
  Result := 0;
  if FBatchList = nil then Exit;
  for Bi := 0 to FBatchList.Count - 1 do
  begin
    Bn := FBatchList[Bi];
    if (Bn = nil) or (Bn.Tiles = nil) then Continue;
    for Ti := 0 to Bn.Tiles.Count - 1 do
    begin
      CT := Bn.Tiles[Ti];
      if CT = nil then Continue;
      Inc(Result, Int64(Length(CT.GroundVertices)) * SizeOf(TVector3) +
        Int64(Length(CT.GroundIndices)) * SizeOf(Cardinal));
      Inc(Result, Int64(Length(CT.BorderWorld)) * SizeOf(TBorderWorldPoint));
      Inc(Result, Int64(Length(CT.GroundBin))   * SizeOf(Pointer));
      for Ci := 0 to High(CT.GroundBin) do
        Inc(Result, Int64(Length(CT.GroundBin[Ci])) * SizeOf(Integer));
    end;
  end;
end;

function TOsm3dStreamingMap.MemBytesTileX3DEst: Int64;
var v, t: Int64;
begin
  SumResidentSceneGeom(v, t);
  Result := v * 40 + t * 12;
end;

function TOsm3dStreamingMap.MemBytesTileVBOEst: Int64;
var v, t: Int64;
begin
  SumResidentSceneGeom(v, t);
  Result := v * 32 + t * 12;
end;
{$ENDIF}

function TOsm3dStreamingMap.PendingTileWork: Integer;
begin
  Result := InterlockedCompareExchange(FMountPending, 0, 0) +
    InterlockedCompareExchange(FAsmPending, 0, 0);
  if FStreamer <> nil then Inc(Result, FStreamer.PendingVisibleTiles);
  if FAsmDoneQueue <> nil then
  begin
    EnterCriticalSection(FAsmLock);
    try
      Inc(Result, FAsmDoneQueue.Count);
    finally
      LeaveCriticalSection(FAsmLock);
    end;
  end;
end;

constructor TOsm3dStreamingMap.Create(AOwner: TComponent;
  const AOrigin: TLatLon; const ACacheRoot, AGenHash: string;
  AHttp: THTTPFetcherWithCache;
  ATerrFetcher: TTerrariumFetcher; AOverpass: TOverpassClient;
  const ASettings: TStudioSettings;
  ALog: TLogTarget; AMainLog: TLogTarget; AStartUTC: TDateTime);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1265);{$ENDIF}
  inherited Create(AOwner);

  if GpuGroundMode<>ggCpu then FGpuGround:=TOsmGpuGround.Create;
  UploadsPerFrame  := 1;
  { Streamed-tile draw cull — теперь в TLODConfig. Это реальный per-tile
    Exists-отсев (UpdateDistanceCulling); правь GroundVisibilityM, чтобы
    видеть дальше. Держи <= GlobalLODConfig.StreamUploadM (радиус монтажа). }
  TileCullDistance := GlobalLODConfig.GroundVisibilityM;

  FOrigin     := AOrigin;
  { Single scene sun. Default kept at a HIGH elevation so the ground
    composite (lit by -FSunDir, no abs) keeps a strong N·L on flat terrain.
    The canonical default lives in Osm3dGlslLib.DEFAULT_SUN_RAY_DIR and is
    shared by all fallback paths (ground/building composite, instanced
    vegetation, sky effects, light rig). Resolve before shared materials and
    the light rig are built, so all consumers use the same session sun. }
  FSunShadowsAllowed := TSunCalc.ResolveRouteSun(AOrigin.Lat, AOrigin.Lon,
    AStartUTC, FSunDir);
  FLog        := ALog;
  FMainLog    := AMainLog;
  FDestroying := False;
  FSnappedReady := False;FBotCrossings:=nil;FPendingBotCrossings:=nil;
  FGreenRetrofit := False;
  FBridgeDeckYMax := SPHERE_Y_NONE;
  FSnapWorker   := nil;
  FFitCorrWorker := nil;
  FSnapCancel   := False;
  FSnapHoldEviction := False;
  FLifeSeconds  := 0.0;
  FSnapAutoDone := False;
  FWaterDiagAccum := 0.0;

  { FIT marker overlays — mirror the session settings. The game disables
    both (TGameOsmStreaming.BuildSettings); Osm3dStudio leaves them on.
    Without this guard MountBatch / RetrofitGreenBudget run the heavy
    per-tile sphere build even when the host wants no overlay. }
  FShowFitPoints        := ASettings.ShowFitPoints;
  FShowFitPointsSnapped := ASettings.ShowFitPointsSnapped;
  FFitLayerBuild        := True;   { хост может выключить (страница маршрутов) }
  FFitPhysLayer         := nil;    { слой физики ставится из Create/publish }

  { Route-only geometry: строить только коридор пути (радиус по умолчанию 200 м).
    Набор коридора строит BuildRouteCorridor из SetRoute; WantFilter стримера
    ставится там же. Игра держит GenerateRouteOnly=False → полный мир. }
  FRouteOnlyGeom     := ASettings.GenerateRouteOnly;
  FRouteOnlyRadiusM  := ASettings.RouteOnlyRadiusM;
  if FRouteOnlyRadiusM < 1.0 then FRouteOnlyRadiusM := 200.0;
  FCorridorSet       := specialize TDictionary<string, Boolean>.Create;
  FCorridorLatched   := specialize TDictionary<string, Boolean>.Create;
  FCorridorPregenIdx := 0;

  { Метрика РАССТАНОВКИ обязана совпасть с метрикой ВЫПЕЧКИ (Osm3dBlockGenerator:
    Chunk.ScaleLat) до бита, иначе рассинхрон просто переезжает сюда: тайл
    испечён в одном cos долготы, а разложен в другом. Раньше здесь был
    Create(AOrigin) = масштаб от широты origin СЕССИИ — Студия (FRoute[0]) и
    игра (центроид) расходились по востоку. }
  FWorldScaleLat  := EffectiveWorldScaleLat(ASettings, AOrigin.Lat);
  FManualScaleLat := ASettings.WorldScaleLatDeg;
  FProj  := TLocalProjection.Create(AOrigin, FWorldScaleLat);
  FHeightmapZoom := ASettings.HeightmapZoom;
  FGenerateFarTerrain := ASettings.GenerateFarTerrain;
  { RefLat решётки задаёт номинальный EdgeMeters (→ FEdge → радиусы стрима и
    AEdgeMeters генератора). От широты origin он тоже зависеть не должен. }
  FCache := TGeoTileCache.Create(ACacheRoot, AGenHash,
                                 FHeightmapZoom, GEO_TILE_EDGE_PX, FWorldScaleLat);
  FCache.LogTarget := FMainLog;
  { Slippy lattice — no UTM zone to pin (PinZone removed). }

  FEdge := FCache.Grid.EdgeMeters;
  if FEdge < 1.0 then FEdge := GEO_TILE_EDGE_M;

  FBlockGen := TOsm3dBlockGenerator.Create(
                 AHttp, ATerrFetcher, AOverpass,
                 ASettings, AGenHash, FEdge, GEO_BLOCK_SIZE);
  FBlockGen.Recipes := FCache.Recipes;
  FBlockGen.LogTarget := FLog;
  SetSunDirection(FSunDir, FSunShadowsAllowed);

  { Прогрев маршрута: оверлей создаётся скрытым; в UI-дерево его вставляет
    хост. Фетчер сессии нужен ему для растровой подложки. }
  FAuxHttp := AHttp;
  FWarmup  := TOsm3dWarmupOverlay.Create(Self);
  FWarmupShown := False;
  FWarmupNextDiskChk := 0;
  { Гейт до постановки райдера — включён по умолчанию (игра); хосты без
    райдера (студия) выключают: Map.WarmupHoldRider := False. }
  FWarmupHoldRider   := True;
  FWarmupRiderPlaced := False;
  FSnapError       := '';
  FSnapErrorStage  := -1;
  FSnapErrorShown  := False;
  FFitCorrProgCur   := 0;
  FFitCorrProgTotal := 0;
  FFitCorrStageRun  := False;
  FillChar(FWuStageErr, SizeOf(FWuStageErr), 0);

  { Фоновый монтаж сцен (см. GlobalMountInWorker). }
  FMountQueue := specialize TQueue<TMountJob>.Create;
  InitCriticalSection(FMountLock);
  FMountWake := RTLEventCreate;
  FMountPending := 0;
  if GlobalMountInWorker then
    FMountWorker := TMountWorker.Create(Self);

  { Фон-ассемблер: создаём только если включён (иначе путь синхронный). }
  FAsmQueue := nil; FAsmDoneQueue := nil; FAssembleWorker := nil; FAsmPending := 0;
  if GlobalAssembleInWorker then
  begin
    FAsmQueue     := specialize TQueue<TAssembleJob>.Create;
    FAsmDoneQueue := specialize TQueue<TAssembleJob>.Create;
    InitCriticalSection(FAsmLock);
    FAsmWake      := RTLEventCreate;
    FAssembleWorker := TAssembleWorker.Create(Self);
  end;

  FStreamer := TTileStreamer.Create(FCache, AOrigin,
                 GEO_BLOCK_SIZE, 220.0,
                 3,    { AIOWorkers  }
                 2);   { AGenWorkers — carve/clip scratch is threadvar (per-
                         thread), block generation is reentrant. Each worker's
                         carve still uses an internal ProcessorCount pool, so a
                         2nd worker mainly fills the cores left idle during the
                         serial phases (fetch, weld, stitch, tjunction) of the
                         other block. Raise carefully: N workers ≈ N× the carve
                         thread pool (mild oversubscription). }
  FStreamer.OnGenerateBlock := @FBlockGen.GenerateBlock;
  { Прогресс блоков: генератор сообщает фазу -> обновляем стример. }
  FBlockGen.OnPhase := @HandleBlockPhase;
  FStreamer.LogTarget       := FLog;
  FStreamer.SetHeightPreviewSource(ATerrFetcher, ASettings.HeightmapZoom,
                                   ASettings.FarTerrainZoom);
  { Превью-текстуры по блокам генерации (.ptex.png) — владеем. Общий terrarium
    держим ссылкой для B/C-высот в WrapTileLOD. БЕЗ источника текстур стример
    оставил бы зелёные превью; БЕЗ дальнего zoom GetSuperHeights тянул бы
    тысячи terrarium-PNG вместо ~43 на zoom 10. }
  FHmFetcher := ATerrFetcher;
  FPrevTex   := TPrevTexFetcher.Create(FCache, GEO_BLOCK_SIZE);
  FStreamer.SetPrevTexSource(FPrevTex);
  { Session UTM zone / hemisphere — a route stays inside one zone. }
  with FCache.Grid.TileAt(FOrigin) do
  begin
    FZone  := Zone;
    FNorth := North;
  end;

  { Base-tile visibility ring (level 0). Factory + host callbacks below;
    the streamer's keyhole still loads and bounds the near detail. }
  FLodCb.ShowBase    := @HostShowBase;
  FLodCb.ReleaseBase := @HostReleaseBase;
  FLodTree := TLodTree.Create(@LodFactory, GlobalLODConfig.StreamGridRadius);

  { The secondary cache. }
  FBatchList := TCacheBatchList.Create;
  {$IFDEF TILE_MEM_PROFILE}
  MemProbeAdd(Self, 'tile-aux-cpu', mkRAM,  @MemBytesTileAuxCPU);
  MemProbeAdd(Self, 'tile-x3d~',    mkRAM,  @MemBytesTileX3DEst);
  MemProbeAdd(Self, 'tile-vbo~',    mkVRAM, @MemBytesTileVBOEst);
  {$ENDIF}
  FTileIndex := specialize TDictionary<Int64, TCacheTile>.Create;
  FTileIndexStr := specialize TDictionary<string, TCacheTile>.Create;
  FFarGround    := nil;
  FFarHasCenter := False;
  FTreeWantBase := specialize TDictionary<string, Boolean>.Create;
  FLoadOwner := TCastleTransform.Create(Self);
  Add(FLoadOwner);
  FLoadTiles := specialize TDictionary<string, TLoadTile>.Create;
  MemBudgetInit;
  FShadowReReq := specialize TDictionary<string, Byte>.Create;

  FAsmCache := TCachedAssemblyResources.Create;
  FAsmCache.LogSink := @LogMain;
  {$IFDEF TILE_MEM_PROFILE}
  MemProbeAdd(FAsmCache, 'shadow-mask~', mkVRAM, @FAsmCache.ShadowMaskBytes);
  {$ENDIF}
  { Variant-1 atlas ownership: write the composed atlas to PNG once under
    the session cache root and load it by URL, so CGE's URL texture cache
    owns the GPU texture and the atlas needs no KeepExisting pinning. Empty
    string would force the inline-pixel fallback. }
  FAsmCache.AtlasCacheDir := IncludeTrailingPathDelimiter(ACacheRoot) + 'atlas';

  { Build the map scene's own graph: warm the shared resources into
    FAsmCache (which pins them) and Load the light rig as this scene's
    root. }
  BuildWorldGraph;

  { Global directional lights live in this scene's graph; CastGlobalLights
    makes them light the child tile scenes too. }
  CastGlobalLights := True;

  { Water subsystem — mirror the session water settings into the global
    Active vars the scene assembler reads (Osm3dStudioSettings.Water*
    Active). The legacy Osm3dMapTransform path did this; the streaming
    path did not, so the assembler always saw the unit-default lift /
    wave size and an enable flag that never followed this session.
    Without this, water never gets the configured lift (terrain z-fight
    that no UI lift value could fix) and the wave size is stuck. }
  Osm3dStudioSettings.WaterShadersActive   := ASettings.WaterShaders;
  Osm3dStudioSettings.WaterWaveSizeActive  := ASettings.WaterWaveSize;
  Osm3dStudioSettings.WaterLevelLiftActive := ASettings.WaterLevelLift;
  { BUILDING_OBSTACLE: session spatial index (empty until first tile mount). }
  FBuildingObstacles := TBuildingObstacleIndex.Create;
  { Ground shadows — same mirror, so the assembler gates shadow generation
    and the mask on this session's setting (default OFF). }
  Osm3dStudioSettings.GroundShadowsActive  := ASettings.GenerateGroundShadows;
  { Vegetation renderers — children of FVegOwner, itself a child of the
    map scene. }
  FGenerateTrees := ASettings.GenerateTrees;
  FVegOwner := TCastleTransform.Create(Self);
  Add(FVegOwner);
  { RenderTrees: when off, the vegetation renderers are never created, so no
    veg shader is built and nothing is drawn — trees are still GENERATED.
    Downstream draw paths short-circuit on the nil renderers. }
  if FGenerateTrees and ASettings.RenderTrees then
  begin
    FTreeRenderer := TCastleAbstractTreeRenderer.Create(Self);
    FTreeRenderer.ProceduralAlternative := True;
    FVegOwner.Add(FTreeRenderer);
    FShrubRenderer := TCastleAbstractShrubRenderer.Create(Self);
    FShrubRenderer.ProceduralAlternative := True;
    FVegOwner.Add(FShrubRenderer);
    FProceduralRenderer := TOsmProceduralVegetation.Create(Self);
    FVegOwner.Add(FProceduralRenderer);
  end;
  if ASettings.RenderGrass then
  begin
    FGrassRenderer := TGrassRenderer.Create(Self);
    FVegOwner.Add(FGrassRenderer);
  end;
end;

procedure TOsm3dStreamingMap.RequestBackgroundStop;
begin
  FDestroying:=True;FSnapCancel:=True;
  if FStreamer<>nil then FStreamer.RequestStop;
  if FHmFetcher<>nil then FHmFetcher.RequestBackgroundStop;
  if FBlockGen<>nil then FBlockGen.AbortFetches;
  if FAssembleWorker<>nil then begin FAssembleWorker.Terminate;RTLEventSetEvent(FAsmWake)end;
  if FMountWorker<>nil then begin FMountWorker.Terminate;RTLEventSetEvent(FMountWake)end;
  if FSnapWorker<>nil then FSnapWorker.Terminate;
  if FFitCorrWorker<>nil then FFitCorrWorker.Terminate;
  if FWarmup<>nil then FWarmup.HideWarmup;
end;

procedure TOsm3dStreamingMap.JoinBackgroundStop;
begin
  if FAssembleWorker<>nil then FAssembleWorker.WaitFor;
  if FMountWorker<>nil then FMountWorker.WaitFor;
  if FSnapWorker<>nil then FSnapWorker.WaitFor;
  if FFitCorrWorker<>nil then FFitCorrWorker.WaitFor;
  if FHmFetcher<>nil then FHmFetcher.JoinBackgroundStop;
  if FWarmup<>nil then FWarmup.JoinBackgroundStop;
  { Disk flushing is last: a filesystem error must not skip a provider join. }
  if FStreamer<>nil then FStreamer.JoinStoppedWorkers;
end;

destructor TOsm3dStreamingMap.Destroy;
begin
  SceneLifecycleLog('OSM-DESTROY step 0: begin');
  { Stop producing tiles before waiting for the current assembly/mount job.
    Their models stay owned by the streamer until the readers have joined. }
  FDestroying := True;
  FSnapCancel := True;
  if FStreamer <> nil then FStreamer.RequestStop;
  { Быстрая остановка воркеров при Stop: рвём все идущие HTTP общего
    фетчера (DEM/тайлы — до 30 с на запрос) и спин-ожидания тайлов.
    Воркеры вываливаются из сети немедленно, join'ы ниже — секунды, а не
    десятки секунд. Сброс — после джойна стримера (шаг 8b). }
  if FHmFetcher <> nil then FHmFetcher.AbortFetches;
  if FBlockGen <> nil then FBlockGen.AbortFetches;   { overpass-трафик }
  FreeAndNil(FFitCorr);
  {$IFDEF IAM_LIVE}IamLiveTrack(1266);{$ENDIF}

  { Запечённые сцены сфер (Owner=nil) — снять с карты и освободить сами,
    пока карта-трансформ ещё жива. }
  FreeSphereScenes;
  SceneLifecycleLog('OSM-DESTROY step 1: sphere scenes freed');

  { Завершить растровый поток до разборки карты и внешнего HTTP-фетчера.
    Уничтожение компонента также выпишет оверлей из UI-дерева хоста. }
  FreeAndNil(FWarmup);
  FWarmupShown := False;
  SceneLifecycleLog('OSM-DESTROY step 2: warmup hidden');

  { Фон-ассемблер — остановить ДО монтажника и до FAsmCache: он держит
    Models и читает FAsmCache/FOrigin/FSunDir. Terminate ПЕРВЫМ: воркер
    доёт текущее задание и выходит по флагу, НЕ разбирая всю очередь —
    прежний дрейн до Terminate мог висеть на закрытии минутами. Остатки
    обеих очередей освобождаются ниже (FreeRemainingAssembleJobs). }
  if FAssembleWorker <> nil then
  begin
    SceneLifecycleLog('OSM-DESTROY step 3a: assemble worker terminate...');
    FAssembleWorker.Terminate;
    RTLEventSetEvent(FAsmWake);
    FAssembleWorker.WaitFor;
    SceneLifecycleLog('OSM-DESTROY step 3b: assemble worker joined');
    FreeAndNil(FAssembleWorker);
    FreeRemainingAssembleJobs;
    FreeAndNil(FAsmQueue);
    FreeAndNil(FAsmDoneQueue);
    RTLEventDestroy(FAsmWake); FAsmWake := nil;
    DoneCriticalSection(FAsmLock);
  end else
    SceneLifecycleLog('OSM-DESTROY step 3: no assemble worker');

  { Фоновый монтаж — Terminate ПЕРВЫМ по той же причине: поток держит
    ссылки на сцены, которые ниже освобождаются (TeardownAll / FBatchList);
    после WaitFor он их гарантированно отпустил. }
  if FMountWorker <> nil then
  begin
    SceneLifecycleLog('OSM-DESTROY step 4a: mount worker terminate...');
    FMountWorker.Terminate;
    RTLEventSetEvent(FMountWake);   { разбудить из WaitFor, чтобы увидел Terminated }
    FMountWorker.WaitFor;
    SceneLifecycleLog('OSM-DESTROY step 4b: mount worker joined');
    FreeAndNil(FMountWorker);
  end else
    SceneLifecycleLog('OSM-DESTROY step 4: no mount worker');
  if FMountQueue <> nil then FreeAndNil(FMountQueue);
  if FMountWake <> nil then
  begin
    RTLEventDestroy(FMountWake);
    FMountWake := nil;
  end;
  DoneCriticalSection(FMountLock);

  { Snap worker first — it reads FCache / FBlockGen / FProj, so it must
    be fully stopped before any of those are freed. Cancel flag short-
    circuits its block generation; WaitFor (inside Free) joins it. }
  if FSnapWorker <> nil then
  begin
    SceneLifecycleLog('OSM-DESTROY step 5a: snap worker terminate...');
    FSnapCancel := True;
    FSnapWorker.Terminate;
    FSnapWorker.WaitFor;
    SceneLifecycleLog('OSM-DESTROY step 5b: snap worker joined');
    FreeAndNil(FSnapWorker);
  end else
    SceneLifecycleLog('OSM-DESTROY step 5: no snap worker');
  { Лёгкий воркер коррекции — тоже присоединить до освобождения FProj/
    FHmFetcher (он их читает). }
  if FFitCorrWorker <> nil then
  begin
    SceneLifecycleLog('OSM-DESTROY step 6a: fitcorr worker terminate...');
    FSnapCancel := True;
    FFitCorrWorker.Terminate;
    FFitCorrWorker.WaitFor;
    SceneLifecycleLog('OSM-DESTROY step 6b: fitcorr worker joined');
    FreeAndNil(FFitCorrWorker);
  end else
    SceneLifecycleLog('OSM-DESTROY step 6: no fitcorr worker');
  { Drop any OnRouteSnapDone the worker queued but the main thread has
    not run yet — it would otherwise fire on a half-destroyed map. }
  TThread.RemoveQueuedEvents(TThreadMethod(@OnRouteSnapDone));
  { И PublishFitCorrection, которую мог заквьюить лёгкий воркер. }
  TThread.RemoveQueuedEvents(TThreadMethod(@PublishFitCorrection));
  FreeAndNil(FPendingFitLayer);   { построенный, но не опубликованный слой }
  FreeAndNil(FFitPhysLayer);      { физический слот (GroundYAt) — наш }
  FreeAndNil(FBuildingObstacles); { BUILDING_OBSTACLE }
  SceneLifecycleLog('OSM-DESTROY step 7: fit layers freed');

  { Streamer next — its destructor joins every worker thread. }
  SceneLifecycleLog('OSM-DESTROY step 8a: freeing streamer...');
  FreeAndNil(FStreamer);
  SceneLifecycleLog('OSM-DESTROY step 8b: streamer freed');
  { Все читатели высот/тайлов присоединены — отмену HTTP снимаем
    (фетчеры общие, переживают карту). }
  if FHmFetcher <> nil then FHmFetcher.ResetFetchAbort;
  if FBlockGen <> nil then FBlockGen.ResetFetchAbort;
  { Коридор route-only: словарей больше никто не читает (Pump/WantFilter в
    стримере, уже освобождённом). }
  FreeAndNil(FCorridorSet);
  FreeAndNil(FCorridorLatched);
  FreeAndNil(FPrevTex);    { после стримера: воркеры присоединены; FCache ещё жив }
  FreeAndNil(FBlockGen);
  FreeAndNil(FCache);
  FreeAndNil(FProj);
  SceneLifecycleLog('OSM-DESTROY step 9: cache/proj freed');

  { Base-tile ring — cells' Release is FDestroying-guarded; scenes map-owned. }
  FreeAndNil(FLodTree);
  FreeAllLoadTiles;
  FreeAndNil(FTreeWantBase);
  SceneLifecycleLog('OSM-DESTROY step 10: lod tree freed');

  { Full cache teardown WITH release — safe here, nothing renders. }
  TeardownAll;
  FreeAndNil(FGpuGround);
  {$IFDEF TILE_MEM_PROFILE}MemProbeRemove(Self);{$ENDIF}
  FreeAndNil(FBatchList);
  FreeAndNil(FTileIndex);
  FreeAndNil(FTileIndexStr);
  FreeAndNil(FShadowReReq);
  SceneLifecycleLog('OSM-DESTROY step 11: teardown all done');

  if FProceduralRenderer <> nil then
  begin
    if FVegOwner <> nil then FVegOwner.Remove(FProceduralRenderer);
    FreeAndNil(FProceduralRenderer);
  end;

  if FTreeRenderer <> nil then
  begin
    if FVegOwner <> nil then FVegOwner.Remove(FTreeRenderer);
    FreeAndNil(FTreeRenderer);
  end;
  if FShrubRenderer <> nil then
  begin
    if FVegOwner <> nil then FVegOwner.Remove(FShrubRenderer);
    FreeAndNil(FShrubRenderer);
  end;
  if FGrassRenderer <> nil then
  begin
    if FVegOwner <> nil then FVegOwner.Remove(FGrassRenderer);
    FreeAndNil(FGrassRenderer);
  end;
  TGrassRenderer.CleanupSharedGL;
  if FVegOwner <> nil then
  begin
    Remove(FVegOwner);
    FreeAndNil(FVegOwner);
  end;
  SceneLifecycleLog('OSM-DESTROY step 12: vegetation freed');

  {$IFDEF TILE_MEM_PROFILE}MemProbeRemove(FAsmCache);{$ENDIF}
  FreeAndNil(FAsmCache);
  SceneLifecycleLog('OSM-DESTROY step 13: asm cache freed');

  { Дальняя земля — обычный объект; его FScene принадлежит карте по AOwner и
    освобождается ниже в inherited, поэтому здесь — только сам объект. }
  FreeAndNil(FFarGround);
  SceneLifecycleLog('OSM-DESTROY step 14: far ground freed, calling inherited');

  { inherited frees FWorldRoot (Load was OwnsRootNode=True): the
    directional-light rig. The shared resources were pinned in
    FAsmCache and released by FreeAndNil(FAsmCache) just above. }
  inherited Destroy;
  SceneLifecycleLog('OSM-DESTROY step 15: inherited done — DESTROY COMPLETE');
end;

procedure TOsm3dStreamingMap.BuildWorldGraph;

  procedure AddLight(const ADir: TVector3;
    AIntensity, AAmbient: Single; const AColor: TVector3);
  var
    L: TDirectionalLightNode;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(829);{$ENDIF}
    L := TDirectionalLightNode.Create;
    L.Direction        := ADir;
    L.Intensity        := AIntensity;
    L.AmbientIntensity := AAmbient;
    L.Color            := AColor;
    L.Global           := True;
    FWorldRoot.AddChildren(L);
  end;

var
  NoModels: TTileModelArray;
  NoTrees:  TTileTreeRecArray;
  NoPreviews: array of TTilePreviewData;
  Warm:     TAssembledScenes;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(828);{$ENDIF}

  { Build every shared resource ONCE — one warm-up AssembleCachedTiles
    call with no tiles builds the atlas, the ground-composite effect,
    all surface textures and the building PBR appearances into FAsmCache.
    FAsmCache pins each of them with KeepExistingBegin, so they survive
    for the whole session no matter how tiles come and go — they need no
    anchor parent in any scene graph. }
  NoModels := nil;
  NoTrees  := nil;
  NoPreviews := nil;
  { LogProc = @LogMain (was nil): this warm-up is the ONE call that builds
    the atlas, so its per-material texture report (GroundAtlas SET / RAW
    files / FindTextures matched) only ever fires here. Routing it through
    LogMain -> FMainLog lands it in osm3d_<session>.log, right above the
    "owner scene built" line. Runs on the main thread, so the file-only
    LogMain target is safe (no Synchronize). }
  Warm := TSceneAssembler.AssembleCachedTiles(
    NoModels, FOrigin, FHeightmapZoom, FSunDir, NoTrees, NoPreviews, @LogMain, FAsmCache,
    True, FManualScaleLat);
  Warm.Free;

  { The map scene's own graph carries ONLY the global directional-light
    rig. The shared atlas / surface / PBR / ground-effect nodes are kept
    alive by FAsmCache's KeepExisting pins, not by this graph. }
  FWorldRoot := TX3DRootNode.Create;

  { TEST: with BuildingShadows on, the per-tile shadow-sun (see MountAssembled)
    is the directional key. Drop THIS rig sun's directional punch (Intensity 0)
    so it can't re-light shadowed areas and wash the test out; keep its ambient
    floor. Revert together with the rest of the BuildingShadows scaffolding. }
  if Osm3dStudioSettings.BuildingShadowsActive then
    AddLight(FSunDir, 0.0, 0.35,
             Vector3(1.00, 0.97, 0.90))
  else
    AddLight(FSunDir, 1.10, 0.35,
             Vector3(1.00, 0.97, 0.90));
  AddLight(Vector3(-0.408, -0.816, -0.408), 0.45, 0.0,
           Vector3(0.65, 0.79, 1.00));
  AddLight(Vector3(0.408, -0.816, 0.408), 0.35, 0.0,
           Vector3(0.68, 0.80, 1.00));
  AddLight(Vector3(0.0, 1.0, 0.0), 0.18, 0.0,
           Vector3(0.88, 0.84, 0.70));

  { Load the graph as this scene's root (OwnsRootNode=True). }
  Load(FWorldRoot, True);

  LogMain('streaming map: owner scene built — own graph carries the '
    + 'light rig; shared resources pinned in FAsmCache; tiles are '
    + 'cached batch children');
end;

procedure TOsm3dStreamingMap.LogMain(const AMsg: string);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(833);{$ENDIF}
  if FMainLog <> nil then
    FMainLog.Write(llInfo, AMsg);
end;

procedure TOsm3dStreamingMap.LogCallback(const AMsg: string);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1703);{$ENDIF}
  { Лог через FLog (TCallbackLogTarget): строка идёт и в osm3d.log, и в
    callback хоста (игровой Logger → trainer_*.log). FLog.Write при
    вызове из main-потока зовёт callback напрямую, без Synchronize —
    дедлока, ради которого LogMain сделан file-only, здесь нет.
    Используется для диагностики, которую нужно видеть в общем логе
    игры (например WATER DIAG). }
  if FLog <> nil then
    FLog.Write(llInfo, AMsg)
  else if FMainLog <> nil then
    FMainLog.Write(llInfo, AMsg);
end;

procedure TOsm3dStreamingMap.AppendWorldShadowCasters(const AList: TCastleTransformList);
var Tile: TCacheTile;
begin
  for Tile in FTileIndex.Values do
    if (Tile.Scene <> nil) and
       (InterlockedCompareExchange(Tile.Scene.MountFinished, 0, 0) <> 0) and
       Tile.Scene.MountLoaded and Tile.Scene.ExistsInRoot then
      AList.Add(Tile.Scene);
  if (FTreeRenderer <> nil) and FTreeRenderer.ExistsInRoot then
    AList.Add(FTreeRenderer);
  if (FShrubRenderer <> nil) and FShrubRenderer.ExistsInRoot then
    AList.Add(FShrubRenderer);
  if (FProceduralRenderer <> nil) and FProceduralRenderer.ExistsInRoot then
    AList.Add(FProceduralRenderer);
end;

function TOsm3dStreamingMap.GetGlobalScene: TCastleScene;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1704);{$ENDIF}
  Result := Self;
end;

function TOsm3dStreamingMap.CameraGeo(LocalX, LocalZ: Single): TLatLon;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1705);{$ENDIF}
  { FProj is the session's fixed local projection; Unproject maps a
    local XZ point back to lat/lon (Y / elevation is ignored). }
  Result := FProj.Unproject(LocalX, LocalZ);
end;

function TOsm3dStreamingMap.KnowledgeRecipeHash: string;
begin
  if (FCache<>nil) and (FCache.Recipes<>nil) then Result:=FCache.Recipes.ContentHash else Result:='';
end;

function TOsm3dStreamingMap.TileScaleX(const AId: TGeoTileId): Double;
begin
  Result := TileFrameScaleX(AId, FCache.Grid, FWorldScaleLat, FManualScaleLat);
end;

function TOsm3dStreamingMap.GeoToLocal(const ALL: TLatLon): TVector3;
begin
  { Та же фиксированная проекция, что и у CameraGeo, в прямом направлении. }
  Result := FProj.Project(ALL, 0);
end;

function TOsm3dStreamingMap.CameraTileName(LocalX, LocalZ: Single): string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1706);{$ENDIF}
  Result := FCache.Grid.TileAt(FProj.Unproject(LocalX, LocalZ)).ToString;
end;

function TOsm3dStreamingMap.CameraTileOsmJson(LocalX, LocalZ: Single): string;
var
  T: TGeoTileId;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1707);{$ENDIF}
  if FBlockGen = nil then Exit('// block generator not available');
  T := FCache.Grid.TileAt(FProj.Unproject(LocalX, LocalZ));
  Result := FBlockGen.CachedOsmJsonForBox(FCache.Grid.TileBox(T));
end;

function TOsm3dStreamingMap.CameraScreenFeatures(LocalX, LocalZ: Single;
  const CamPos, CamDir, CamUp: TVector3;
  AspectWH, FovYRad, NearM, FarM, Margin: Single): string;
var
  T:    TGeoTileId;
  DS:   TOSMDataset;
  SB:   TStringBuilder;
  Fmt:  TFormatSettings;
  Fwd, Rgt, Upv: TVector3;
  TanHalf: Single;
  VisNodes, VisWays, VisRels, TotNodes, TotWays, TotRels: Integer;
  OsmNd: TOSMNode;
  OsmWy: TOSMWay;
  OsmRl: TOSMRelation;
  OsmMb: TOSMRelationMember;
  OsmMW: TOSMWay;
  OsmMN: TOSMNode;
  WPt:   TVector3;
  PtN, OnS: Integer;
  MnX, MnZ, MxX, MxZ: Single;
  RelVisible: Boolean;
  ClosedStr: string;

  function Norm3(const V: TVector3): TVector3;
  var L: Single;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1708);{$ENDIF}
    L := Sqrt(V.X * V.X + V.Y * V.Y + V.Z * V.Z);
    if L > 1e-9 then
      Result := Vector3(V.X / L, V.Y / L, V.Z / L)
    else
      Result := V;
  end;

  function Cross3(const A, B: TVector3): TVector3;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1709);{$ENDIF}
    Result := Vector3(A.Y * B.Z - A.Z * B.Y,
                      A.Z * B.X - A.X * B.Z,
                      A.X * B.Y - A.Y * B.X);
  end;

  { World point Q inside the current camera frustum? Symmetric test.
    Дальность зажата DUMP_MAX_DIST_M: On-Screen OSM — инструмент разбора
    артефактов ВБЛИЗИ камеры; штатный far (6 км) тянул в дамп полгорода. }
  function PointVisible(const Q: TVector3): Boolean;
  const
    DUMP_MAX_DIST_M = 250.0;
  var dx, dy, dz, zc, xc, yc, hY, hX, FarEff: Single;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1710);{$ENDIF}
    FarEff := FarM;
    if FarEff > DUMP_MAX_DIST_M then FarEff := DUMP_MAX_DIST_M;
    dx := Q.X - CamPos.X;
    dy := Q.Y - CamPos.Y;
    dz := Q.Z - CamPos.Z;
    zc := dx * Fwd.X + dy * Fwd.Y + dz * Fwd.Z;
    if (zc < NearM) or (zc > FarEff) then Exit(False);
    xc := dx * Rgt.X + dy * Rgt.Y + dz * Rgt.Z;
    yc := dx * Upv.X + dy * Upv.Y + dz * Upv.Z;
    hY := zc * TanHalf * Margin;
    hX := hY * AspectWH;
    Result := (Abs(xc) <= hX) and (Abs(yc) <= hY);
  end;

  function TagSummary(Tags: TOSMTags; MaxKeys: Integer): string;
  var i: Integer;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1711);{$ENDIF}
    Result := '';
    if Tags = nil then Exit;
    for i := 0 to Tags.Count - 1 do
    begin
      if i >= MaxKeys then begin Result := Result + ' ...'; Break; end;
      if Result <> '' then Result := Result + ' ';
      Result := Result + Tags.Keys[i] + '=' + Tags.Values[i];
    end;
  end;

  { Resolve a way's nodes to world XZ: visible-vertex count + XZ bbox. }
  procedure WayGeom(AWy: TOSMWay; out APtCount, AOnScreen: Integer;
    out AMinX, AMinZ, AMaxX, AMaxZ: Single);
  var
    k:  Integer;
    Nd: TOSMNode;
    Wp: TVector3;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1712);{$ENDIF}
    APtCount := 0; AOnScreen := 0;
    AMinX := 1e30; AMinZ := 1e30; AMaxX := -1e30; AMaxZ := -1e30;
    for k := 0 to High(AWy.NodeRefs) do
    begin
      Nd := DS.FindNode(AWy.NodeRefs[k]);
      if Nd = nil then Continue;
      Wp := FProj.Project(Nd.Position);
      Inc(APtCount);
      if Wp.X < AMinX then AMinX := Wp.X;
      if Wp.Z < AMinZ then AMinZ := Wp.Z;
      if Wp.X > AMaxX then AMaxX := Wp.X;
      if Wp.Z > AMaxZ then AMaxZ := Wp.Z;
      if PointVisible(Wp) then Inc(AOnScreen);
    end;
  end;

  function FF(V: Single): string;
  begin Result := FormatFloat('0.0', V, Fmt); end;

  { Линейный (не площадной) way, чья геометрия нужна в дампе целиком. }
  function IsLinearWay(AWy: TOSMWay): Boolean;
  begin
    Result := (AWy.Tags <> nil) and
      (AWy.Tags.HasKey('highway') or AWy.Tags.HasKey('barrier') or
       AWy.Tags.HasKey('railway') or AWy.Tags.HasKey('waterway'));
  end;

  { Все узлы way в мировых XZ: '(x,z)(x,z)...'. Точность 0.1 м. }
  function WayPolyline(AWy: TOSMWay): string;
  var
    k: Integer;
    Nd: TOSMNode;
    Wp: TVector3;
  begin
    Result := '';
    for k := 0 to High(AWy.NodeRefs) do
    begin
      Nd := DS.FindNode(AWy.NodeRefs[k]);
      if Nd = nil then begin Result := Result + '(?)'; Continue; end;
      Wp := FProj.Project(Nd.Position);
      Result := Result + '(' + FF(Wp.X) + ',' + FF(Wp.Z) + ')';
    end;
  end;

  function FLL(V: Double): string;
  begin Result := FormatFloat('0.000000', V, Fmt); end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1713);{$ENDIF}
  Result := '';
  if FBlockGen = nil then Exit('// block generator not available');

  Fmt := DefaultFormatSettings;
  Fmt.DecimalSeparator := '.';

  if FovYRad < 0.01 then FovYRad := 0.7854;   { ~45 deg fallback }
  Fwd := Norm3(CamDir);
  Rgt := Norm3(Cross3(Fwd, CamUp));
  Upv := Cross3(Rgt, Fwd);                     { orthonormal true up }
  TanHalf := Tan(FovYRad * 0.5);

  T  := FCache.Grid.TileAt(FProj.Unproject(LocalX, LocalZ));
  DS := FBlockGen.CachedOsmDatasetForBox(FCache.Grid.TileBox(T));
  if DS = nil then
    Exit('// nothing cached for this tile -- has it been generated yet?');

  SB := TStringBuilder.Create;
  try
    VisNodes := 0; VisWays := 0; VisRels := 0;
    TotNodes := 0; TotWays := 0; TotRels := 0;

    { tagged nodes only — untagged nodes are just way geometry }
    SB.AppendLine('// ===== TAGGED NODES on screen =====');
    for OsmNd in DS.Nodes.Values do
    begin
      if OsmNd.Tags.Count = 0 then Continue;
      Inc(TotNodes);
      WPt := FProj.Project(OsmNd.Position);
      if not PointVisible(WPt) then Continue;
      Inc(VisNodes);
      SB.AppendLine(Format('NODE %d  %s  @ %s,%s  xz=(%s, %s)',
        [OsmNd.Id, TagSummary(OsmNd.Tags, 6),
         FLL(OsmNd.Position.Lat), FLL(OsmNd.Position.Lon),
         FF(WPt.X), FF(WPt.Z)]));
    end;

    SB.AppendLine('');
    SB.AppendLine('// ===== WAYS on screen =====');
    for OsmWy in DS.Ways.Values do
    begin
      Inc(TotWays);
      WayGeom(OsmWy, PtN, OnS, MnX, MnZ, MxX, MxZ);
      if OnS = 0 then Continue;
      Inc(VisWays);
      if OsmWy.IsClosed then ClosedStr := 'closed, ' else ClosedStr := '';
      SB.AppendLine(Format(
        'WAY  %d  [%s%d pts, %d on-screen]  %s  bbox xz=(%s,%s)..(%s,%s)',
        [OsmWy.Id, ClosedStr, PtN, OnS, TagSummary(OsmWy.Tags, 6),
         FF(MnX), FF(MnZ), FF(MxX), FF(MxZ)]));
      { ЛИНЕЙНЫЕ way (дороги, тротуары, заборы, рельсы, ручьи) — печатаем
        ПОЛНУЮ полилинию узлов в мировых XZ: ради разбора геометрических
        артефактов дамп и существует, а bbox для этого бесполезен.
        Площадные (здания/landuse) не раздуваем — им хватает bbox. }
      if IsLinearWay(OsmWy) then
        SB.AppendLine('   v= ' + WayPolyline(OsmWy));
    end;

    SB.AppendLine('');
    SB.AppendLine('// ===== RELATIONS on screen (by member) =====');
    for OsmRl in DS.Relations.Values do
    begin
      Inc(TotRels);
      RelVisible := False;
      for OsmMb in OsmRl.Members do
      begin
        if OsmMb.Kind = omkWay then
        begin
          OsmMW := DS.FindWay(OsmMb.Ref);
          if OsmMW <> nil then
          begin
            WayGeom(OsmMW, PtN, OnS, MnX, MnZ, MxX, MxZ);
            if OnS > 0 then begin RelVisible := True; Break; end;
          end;
        end
        else if OsmMb.Kind = omkNode then
        begin
          OsmMN := DS.FindNode(OsmMb.Ref);
          if (OsmMN <> nil) and PointVisible(FProj.Project(OsmMN.Position)) then
          begin RelVisible := True; Break; end;
        end;
      end;
      if not RelVisible then Continue;
      Inc(VisRels);
      SB.AppendLine(Format('REL  %d  %s  (%d members)',
        [OsmRl.Id, TagSummary(OsmRl.Tags, 6), OsmRl.MemberCount]));
    end;

    Result :=
      Format('// on-screen OSM for tile %s'#10 +
             '// tagged nodes %d/%d  ways %d/%d  relations %d/%d'#10 +
             '// camera fovY=%s rad  aspect=%s  far=%s m  margin=%s'#10#10,
        [T.ToString,
         VisNodes, TotNodes, VisWays, TotWays, VisRels, TotRels,
         FF(FovYRad), FF(AspectWH), FF(FarM), FF(Margin)])
      + SB.ToString;
  finally
    SB.Free;
    DS.Free;
  end;
end;

function TOsm3dStreamingMap.CameraTileHeights(LocalX, LocalZ: Single): string;
const
  { Sample step ≈ one native terrarium pixel at z13 mid-latitude, so the dump
    resolves features down to road scale (a 30–60 m undulation gets 4–8
    samples). Column/row counts are clamped to keep the table readable. }
  TARGET_STEP_M = 8.0;
  MIN_N = 8;
  MAX_N = 48;
var
  T:    TGeoTileId;
  Box:  TLatLonBox;
  HM:   THeightmap;
  Note: string;
  CenLat, MetPerDegLat, MetPerDegLon, WMeters, HMeters, StepMW, StepMH: Double;
  NCols, NRows, R, C: Integer;
  Lat, Lon, Hgt:    Double;
  HMin, HMax, HSum: Double;
  SB:   TStringBuilder;
  Fmt:  TFormatSettings;
  Line: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1714);{$ENDIF}
  Result := '';
  if FBlockGen = nil then Exit('// block generator not available');

  Fmt := DefaultFormatSettings;
  Fmt.DecimalSeparator := '.';

  { current camera tile and its lat/lon box on the pinned lattice }
  T   := FCache.Grid.TileAt(FProj.Unproject(LocalX, LocalZ));
  Box := FCache.Grid.TileBox(T);

  { source heightmap for exactly this tile box (same terrarium data the
    geometry was built from — just sampled densely here) }
  HM   := nil;
  Note := FBlockGen.FetchSourceHeightmapForBox(Box, HM);
  if HM = nil then
  begin
    if Note = '' then Note := '// no source heightmap available';
    Exit(Note);
  end;

  CenLat       := Box.Center.Lat;
  MetPerDegLat := EARTH_RADIUS_M * DEG_TO_RAD;
  MetPerDegLon := MetPerDegLat * Cos(CenLat * DEG_TO_RAD);
  WMeters      := (Box.MaxLon - Box.MinLon) * MetPerDegLon;
  HMeters      := (Box.MaxLat - Box.MinLat) * MetPerDegLat;

  NCols := Round(WMeters / TARGET_STEP_M);
  if NCols < MIN_N then NCols := MIN_N;
  if NCols > MAX_N then NCols := MAX_N;
  NRows := Round(HMeters / TARGET_STEP_M);
  if NRows < MIN_N then NRows := MIN_N;
  if NRows > MAX_N then NRows := MAX_N;

  StepMW := WMeters / Max(1, NCols - 1);
  StepMH := HMeters / Max(1, NRows - 1);

  SB := TStringBuilder.Create;
  try
    HMin := 1e30; HMax := -1e30; HSum := 0;

    SB.AppendLine('// ===== SOURCE AWS Terrarium heights — tile '
      + T.ToString + ' =====');
    SB.AppendLine(Format('// tile box lat %s..%s  lon %s..%s  (~%s x %s m)',
      [FormatFloat('0.000000', Box.MinLat, Fmt),
       FormatFloat('0.000000', Box.MaxLat, Fmt),
       FormatFloat('0.000000', Box.MinLon, Fmt),
       FormatFloat('0.000000', Box.MaxLon, Fmt),
       FormatFloat('0', WMeters, Fmt), FormatFloat('0', HMeters, Fmt)]));
    SB.AppendLine(Format(
      '// heightmap zoom %d   stitched %dx%d px   source range %d..%d m',
      [FHeightmapZoom, HM.Width, HM.Height,
       Round(HM.MinHeight), Round(HM.MaxHeight)]));

    { pre-scan for tile min/max/mean }
    for R := 0 to NRows - 1 do
    begin
      Lat := Box.MaxLat - (Box.MaxLat - Box.MinLat) * (R / Max(1, NRows - 1));
      for C := 0 to NCols - 1 do
      begin
        Lon := Box.MinLon + (Box.MaxLon - Box.MinLon) * (C / Max(1, NCols - 1));
        Hgt := THeightmapSampler.SampleBilinear(HM, TLatLon.Make(Lat, Lon));
        if Hgt < HMin then HMin := Hgt;
        if Hgt > HMax then HMax := Hgt;
        HSum := HSum + Hgt;
      end;
    end;

    SB.AppendLine(Format(
      '// grid %d x %d   step ~ %s m (W) x %s m (H)   tile min %d  max %d  mean %d m',
      [NCols, NRows, FormatFloat('0.0', StepMW, Fmt),
       FormatFloat('0.0', StepMH, Fmt),
       Round(HMin), Round(HMax), Round(HSum / Max(1, NCols * NRows))]));
    SB.AppendLine('// rows N->S (top=north), cols W->E (left=west); metres');
    SB.AppendLine('');

    for R := 0 to NRows - 1 do
    begin
      Lat := Box.MaxLat - (Box.MaxLat - Box.MinLat) * (R / Max(1, NRows - 1));
      Line := Format('%9s |', [FormatFloat('0.0000', Lat, Fmt)]);
      for C := 0 to NCols - 1 do
      begin
        Lon := Box.MinLon + (Box.MaxLon - Box.MinLon) * (C / Max(1, NCols - 1));
        Hgt := THeightmapSampler.SampleBilinear(HM, TLatLon.Make(Lat, Lon));
        Line := Line + Format('%6d', [Round(Hgt)]);
      end;
      SB.AppendLine(Line);
    end;

    Result := SB.ToString;
  finally
    SB.Free;
    HM.Free;          { we own the stitched heightmap }
  end;
end;

{ Make a cached tile visible. Exists is cascaded up to the batch node:
  the first active tile of a batch turns the batch Exists on. }
procedure TOsm3dStreamingMap.ActivateTile(ATile: TCacheTile);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(840);{$ENDIF}
  if (ATile = nil) or ATile.Active then Exit;
  ATile.Active := True;
  FFarClipDirty := True;
  if ATile.Scene <> nil then
    { Активируем (Exists=True) только когда сцена уже наполнена фоновым потоком.
      Если монтаж ещё не закончил — оставляем инертной; SyncMountedExists в
      Update включит её, как только MountLoaded станет True. }
    ATile.Scene.Exists :=
      (InterlockedCompareExchange(ATile.Scene.MountFinished, 0, 0) <> 0) and
      ATile.Scene.MountLoaded;
  Inc(FActiveTiles);
  if ATile.Batch <> nil then
  begin
    Inc(ATile.Batch.ActiveCount);
    if (ATile.Batch.ActiveCount = 1) and (ATile.Batch.Owner <> nil) then
      ATile.Batch.Owner.Exists := True;
  end;
end;

{ Hide a cached tile. The last active tile of a batch turns the batch
  node Exists off — the renderer then skips the whole batch in one test.
  Deactivation only HIDES: the tile scene and its graph stay allocated,
  ready for a cost-free re-activation. Physical release happens in
  EvictBatch (batch purged) or TeardownAll (shutdown). }
procedure TOsm3dStreamingMap.DeactivateTile(ATile: TCacheTile);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(841);{$ENDIF}
  if (ATile = nil) or (not ATile.Active) then Exit;
  ATile.Active := False;
  FFarClipDirty := True;
  if ATile.Scene <> nil then
    ATile.Scene.Exists := False;
  Dec(FActiveTiles);
  if ATile.Batch <> nil then
  begin
    Dec(ATile.Batch.ActiveCount);
    if (ATile.Batch.ActiveCount <= 0) and (ATile.Batch.Owner <> nil) then
      ATile.Batch.Owner.Exists := False;
  end;
end;

{ Per-frame distance culling. The base-tile ring owns coarse visibility
  (CT.Active); within that this trims tiles whose
  positioning centre is farther than TileCullDistance from the camera.
  Measuring from CT.CenterX/CenterZ — a fixed point set at assembly —
  means a corrupt building bounding box can no longer pull the cull
  centre off the tile and make it vanish before its neighbours. }
{ Дальний срез делает пустой LOD-уровень D внутри сцены тайла (WrapTileLOD) — покадровый
  distance-culling проход не нужен. }

{ Re-collect the per-tile wind uniform fields of the currently resident
  tiles.

  Each ground tile carries its OWN effect, so its OWN uWindTime/uWindBase/
  uWindGustSpeed fields; the assembler collected them per batch into
  TAssembledScenes.GroundWind*Fields. Here we rebuild the flat arrays from
  every live batch. Rebuilding wholesale (rather than incrementally
  add/remove) guarantees we can never hold a pointer to a field whose
  effect was just freed — the rebuild runs synchronously at the end of
  MountBatch / EvictBatch / TeardownAll, before the next Update push. }
procedure TOsm3dStreamingMap.RefreshGroundWindFields;
var
  B: TCacheBatch;
  I, gwCnt: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(845);{$ENDIF}
  SetLength(FWindTimeFields, 0);
  if FBatchList = nil then Exit;
  { size the wind arrays once (Length is O(1) per batch), then fill by index }
  gwCnt := 0;
  for B in FBatchList do
    if (B <> nil) and (B.Assembled <> nil) then
      gwCnt := gwCnt + Length(B.Assembled.GroundWindTimeFields);
  SetLength(FWindTimeFields, gwCnt);
  SetLength(FWindBaseFields, gwCnt);
  SetLength(FWindGustFields, gwCnt);
  gwCnt := 0;
  for B in FBatchList do
  begin
    if (B = nil) or (B.Assembled = nil) then Continue;
    for I := 0 to High(B.Assembled.GroundWindTimeFields) do
    begin
      FWindTimeFields[gwCnt] := B.Assembled.GroundWindTimeFields[I];
      FWindBaseFields[gwCnt] := B.Assembled.GroundWindBaseFields[I];
      FWindGustFields[gwCnt] := B.Assembled.GroundWindGustFields[I];
      Inc(gwCnt);
    end;
  end;
end;

function SilhouetteHash(const ATris: TProjTriArray;
  const ATrees: TShadowTreeCardArray): QWord;
const
  FNV_OFF = QWord($CBF29CE484222325);
  FNV_PRM = QWord($00000100000001B3);
var
  P: PByte;
  N, I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1716);{$ENDIF}
  Result := FNV_OFF;
  if Length(ATris) > 0 then
  begin
    P := PByte(@ATris[0]);  N := Length(ATris) * SizeOf(TProjTri);
    for I := 0 to N - 1 do Result := (Result xor P[I]) * FNV_PRM;
  end;
  if Length(ATrees) > 0 then
  begin
    P := PByte(@ATrees[0]);  N := Length(ATrees) * SizeOf(TShadowTreeCard);
    for I := 0 to N - 1 do Result := (Result xor P[I]) * FNV_PRM;
  end;
end;

function TOsm3dStreamingMap.EnqueueTileShadow(ACT: TCacheTile): Boolean;
var
  ShJob: TShadowGenJob;
  H:     QWord;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1717);{$ENDIF}
  Result := False;
  if ACT = nil then Exit;
  { A receiver can only be re-uploaded into an EXISTING mask node; a tile
    whose node was detached (hidden / evicted) has none, so skip it. }
  if FAsmCache.GetTileMaskTexByKey(ACT.Tile.ToString) = nil then Exit;
  if not FAsmCache.CollectTileSnapshot(ACT.Tile,
       ShJob.OX, ShJob.OZ, ShJob.SX, ShJob.SZ, ShJob.W, ShJob.H,
       ShJob.Tris, ShJob.Trees, ShJob.Ground) then Exit;
  if (Length(ShJob.Tris) = 0) and (Length(ShJob.Trees) = 0) then Exit;
  { Skip re-enqueue when the silhouette set is unchanged — a neighbour mount
    that adds no caster within this window yields the same mask. This is what
    stops a tile near the streaming front being regenerated once per adjacent
    pack mount (the same mask rasterised and re-uploaded many times). }
  H := SilhouetteHash(ShJob.Tris, ShJob.Trees);
  if (ACT.ShadowHash <> 0) and (ACT.ShadowHash = H) then Exit;
  { Tag the slot with this live tile + its mount generation so the upload
    drain verifies the node is still ours before swapping. A re-mounted
    tile carries a higher generation; an in-flight upload with the old one
    is then rejected even if the new TCacheTile reuses the heap address. }
  FAsmCache.StampTileMaskOwner(ACT.Tile, Pointer(ACT), ACT.MountGen);
  ShJob.Key := ACT.Tile.ToString;
  ShJob.Gen := ACT.MountGen;
  FStreamer.EnqueueShadowGen(ShJob);
  ACT.ShadowHash := H;
  if STREAM_DIAG_VERBOSE then
    LogMain(Format('SH enq key=%s g=%d ct=%x node=%x',
      [ShJob.Key, ShJob.Gen, PtrUInt(ACT),
       PtrUInt(FAsmCache.GetTileMaskTexByKey(ACT.Tile.ToString))]));
  Result := True;
end;

procedure TOsm3dStreamingMap.SyncTileBorders(
  const AModels: array of TTileModel; ABatchBorder: TBorderWorldMap);
var
  Mi, K, V, Ni, BestI, OutN: Integer;
  M:        TTileModel;
  Tid:      TGeoTileId;
  OriginX, OriginZ, BakeCos: Double;
  Rec:      TTileMeshRec;
  VRef:     TMeshVertexArray;
  Nbr, OutW: TBorderWorldArray;
  ResCT:    TCacheTile;
  Eps2, BestD2, D2, dxw, dzw, wx, wz, lx, lz: Double;
  NewLocal: TVector3;

  { Собрать в Nbr мировые точки границ всех 8 соседей ATid: из резидентных
    тайлов (FTileIndex — «старше всех») и из уже обработанных моделей пачки. }
  procedure GatherNeighbours(const ATid: TGeoTileId);
  var
    ddx, ddy, j, base, cnt: Integer;
    nb:  TGeoTileId;
    arr: TBorderWorldArray;
    key: string;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1718);{$ENDIF}
    cnt := 0;
    SetLength(Nbr, 0);
    for ddx := -1 to 1 do
      for ddy := -1 to 1 do
      begin
        if (ddx = 0) and (ddy = 0) then Continue;
        { TX/TY — Cardinal: не уходим в обёртку на краю мира. }
        if (ddx < 0) and (ATid.TX = 0) then Continue;
        if (ddy < 0) and (ATid.TY = 0) then Continue;
        nb := TGeoTileId.Make(ATid.Zone, ATid.North,
                Cardinal(Integer(ATid.TX) + ddx),
                Cardinal(Integer(ATid.TY) + ddy));
        arr := nil;
        if FTileIndex.TryGetValue(nb.ToKey, ResCT) and (ResCT <> nil) then
          arr := ResCT.BorderWorld          { резидентный сосед }
        else
        begin
          key := nb.ToString;
          if not ABatchBorder.TryGetValue(key, arr) then
            arr := nil;                      { сосед из этой же пачки }
        end;

        if Length(arr) = 0 then Continue;
        base := cnt;
        SetLength(Nbr, cnt + Length(arr));
        for j := 0 to High(arr) do
          Nbr[base + j] := arr[j];
        cnt := cnt + Length(arr);
      end;
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1719);{$ENDIF}
  if ABatchBorder = nil then Exit;
  Eps2 := TILE_BORDER_WELD_EPS_M * TILE_BORDER_WELD_EPS_M;

  for Mi := 0 to High(AModels) do
  begin
    M := AModels[Mi];
    if M = nil then Continue;
    Tid := M.TileId;
    { Уже резидентный тайл — эталон, его не трогаем. }
    if FTileIndex.ContainsKey(Tid.ToKey) then Continue;

    { Cached X uses the latitude band of THIS tile, not the session. Keep
      the seam registry in one geographic frame for all tiles and sessions. }
    if (FManualScaleLat <> 0) and (Abs(FManualScaleLat) < 90) then
      BakeCos := Cos(FManualScaleLat * DEG_TO_RAD)
    else
      BakeCos := Cos(WorldScaleLatBand(BlockHaloBox(
        BlockOf(Tid), FCache.Grid, 0).Center.Lat) * DEG_TO_RAD);
    OriginX := -M.Origin.Lon * (DEG_TO_RAD * EARTH_RADIUS_M);
    OriginZ :=  M.Origin.Lat * (DEG_TO_RAD * EARTH_RADIUS_M);
    GatherNeighbours(Tid);

    { сварка: только если есть к чему привариваться }
    if Length(Nbr) > 0 then
      for K := 0 to M.MeshCount - 1 do
      begin
        Rec := M.Meshes[K];
        if Rec.Mesh = nil then Continue;
        { только композит земли (как и при флагировании) }
        if Length(Rec.MatIds) <> Rec.Mesh.VertexCount then Continue;
        if Length(Rec.BorderIdx) = 0 then Continue;

        VRef := Rec.Mesh.Vertices;
        for V := 0 to High(Rec.BorderIdx) do
        begin
          if (Rec.BorderIdx[V] < 0) or (Rec.BorderIdx[V] >= Length(VRef)) then
            Continue;
          lx := VRef[Rec.BorderIdx[V]].Position.X;
          lz := VRef[Rec.BorderIdx[V]].Position.Z;
          { Единая географическая система, без масштаба и начала сессии.
            Долготу переводим обратно в метры ниже при сравнении расстояния. }
          wx := OriginX + lx / BakeCos;
          wz := OriginZ + lz;

          BestI := -1;  BestD2 := Eps2;
          for Ni := 0 to High(Nbr) do
          begin
            dxw := (Nbr[Ni].X - wx) * BakeCos;
            dzw := Nbr[Ni].Z - wz;
            D2  := dxw*dxw + dzw*dzw;
            if D2 <= BestD2 then
            begin
              BestD2 := D2;
              BestI  := Ni;
            end;
          end;

          if BestI >= 0 then
          begin
            { Возвращаем общую точку в собственную метрику нового тайла.
              Большие координаты вычитаются в Double до записи в меш. }
            NewLocal.X := (Nbr[BestI].X - OriginX) * BakeCos;
            NewLocal.Y := Nbr[BestI].Y;          { Y абсолютный, копируем }
            NewLocal.Z := Nbr[BestI].Z - OriginZ;
            Rec.Mesh.SetVertexPosition(Rec.BorderIdx[V], NewLocal);
          end;
        end;
      end;

    { Сохраняем границы в общей географической системе для следующих соседей. }
    OutN := 0;
    SetLength(OutW, 0);
    for K := 0 to M.MeshCount - 1 do
    begin
      Rec := M.Meshes[K];
      if Rec.Mesh = nil then Continue;
      if Length(Rec.MatIds) <> Rec.Mesh.VertexCount then Continue;
      if Length(Rec.BorderIdx) = 0 then Continue;
      VRef := Rec.Mesh.Vertices;
      SetLength(OutW, OutN + Length(Rec.BorderIdx));
      for V := 0 to High(Rec.BorderIdx) do
      begin
        if (Rec.BorderIdx[V] < 0) or (Rec.BorderIdx[V] >= Length(VRef)) then
        begin
          OutW[OutN].X := 0; OutW[OutN].Y := 0; OutW[OutN].Z := 0;
          Inc(OutN);
          Continue;
        end;
        OutW[OutN].X := OriginX + VRef[Rec.BorderIdx[V]].Position.X / BakeCos;
        OutW[OutN].Y := VRef[Rec.BorderIdx[V]].Position.Y;
        OutW[OutN].Z := OriginZ + VRef[Rec.BorderIdx[V]].Position.Z;
        Inc(OutN);
      end;
    end;
    SetLength(OutW, OutN);
    ABatchBorder.AddOrSetValue(Tid.ToString, OutW);
  end;
end;

{ Монтаж уже собранного пакета (граф X3D готов): обёртка в TCacheBatch,
  пер-тайл сцены (Scene.Load уже уходит в фон-монтажник), трава/деревья, тени.
  Только главный поток (мутация графа). Владеет и освобождает Assembled и
  BatchBorder; AModels НЕ освобождает (вызывающий). }
procedure TOsm3dStreamingMap.MountAssembled(Assembled: TAssembledScenes;
  const Trees: TTileTreeRecArray; BatchBorder: TBorderWorldMap;
  const AModels: array of TTileModel; const AIds: array of TGeoTileId;
  TAsmMs: QWord);
var
  Batch:     TCacheBatch;
  Root:      TX3DRootNode;
  Scene:     TProfiledScene;
  CT:        TCacheTile;
  Key:       string;
  N, I, J:   Integer;
  TAsm0, TLoadMs: QWord;
  MountProfile: Boolean;
  TreePartitionStarted: QWord;
  TreeBuckets: array of TTileTreeRecArray;
  BucketN:     array of Integer;
  TreeTid:     TGeoTileId;
  Bi:          Integer;
  TileLL:    TLatLon;
  SumX, SumZ: Double;
  Centre:    TVector3;
  PackTX, PackTY: array of Integer;
  nPk:       Integer;
  ShAffected: Boolean;
  BWArr:       TBorderWorldArray;
  TestSun:   TDirectionalLightNode;   { TEST: per-tile shadow-casting sun }
begin
  N := Length(AModels);
  if (Assembled = nil) or (Length(Assembled.Tiles) = 0) then
  begin
    LogMain(Format('batch of %d produced no geometry', [N]));
    FreeAndNil(Assembled);
    FreeAndNil(BatchBorder);
    Exit;
  end;

  { wrap the assembled pack in a cache batch (a root block) }
  Batch := TCacheBatch.Create;
  Batch.Assembled := Assembled;
  Batch.Owner     := TCastleTransform.Create(Self);
  Batch.Owner.Exists := False;          { hidden until a tile activates }
  Add(Batch.Owner);
  FBatchList.Add(Batch);

  TAsm0  := GetTickCount64;
  SumX   := 0.0;
  SumZ   := 0.0;
  for I := 0 to High(Assembled.Tiles) do
  begin
    Root := Assembled.Tiles[I].Root;
    if Root = nil then Continue;
    if not Assembled.Tiles[I].HasTileId then Continue;
    Key := Assembled.Tiles[I].TileId.ToString;

    { A tile already cached from an earlier batch — skip; the cache
      keeps the first copy.

      UAF FIX: this batch's assembly (AssembleCachedTiles) already built a
      redundant mask node for this geo-tile AND claimed the shared shadow
      registry slot for it via SetTileMaskTexture — the slot is keyed by
      geo-tile, not by batch, so it OVERWRITES whatever the resident copy
      registered. That redundant node lives only in THIS batch's Assembled
      graph; it is never mounted, and it is freed by ABatch.Assembled.Free
      when this batch is evicted. But EvictBatch only detaches registry slots
      for tiles in Batch.Tiles, and a skipped tile is never added there — so
      the slot would be left pointing at a freed node. The owner+generation
      gate (re-stamped onto the resident tile by StampTileMaskOwner, whose
      gen never changes) then hands that dangling node to the shadow-upload
      apply -> use-after-free (the 'val=<garbage>' crash). Detach the slot
      now, before skipping, so the redundant node is never referenced. The
      resident copy's mask was already displaced by this assembly's
      SetTileMaskTexture, so nulling here loses nothing that overwrite had
      not already taken; a later genuine (re)mount re-registers the slot. }
    if FTileIndex.ContainsKey(Assembled.Tiles[I].TileId.ToKey) then
    begin
      if FAsmCache <> nil then
        FAsmCache.DetachTileMaskTexture(Assembled.Tiles[I].TileId);
      Continue;
    end;

    Scene := TProfiledScene.Create(Self);
    { bsmCGE (теневой источник байка, Global): в его shadow-volume проход
      попадают ВСЕ сцены с CastShadows=True. Тайловые сцены — миллионы
      вершин, silhouette-экстракция по ним вешает main thread навсегда
      (фриз первого кадра после монтажа первого батча). Документированное
      требование BikeParametric: «set CastShadows := False on large world
      scenes (map tiles)». Тени CGE на тайлы всё равно не нужны — земля
      освещается своими масками. }
    Scene.CastShadows := False;
    { И как ПРИЁМНИКИ тайлы в volume-проходе не нужны: с активным
      volume-источником CGE рендерит receivers дважды (проход «в тени» +
      lit-проход по трафарету) — +37 мс/кадр на 3M вершин. Тень байка
      ловит его catcher-квад (FShadowLightScene, ReceiveShadowVolumes
      остаётся True). }
    Scene.ReceiveShadowVolumes := False;
    { --- BuildingShadows TEST scaffolding ---------------------------------
      The illuminating rig (BuildWorldGraph -> FWorldRoot) sits in the MAP's
      own scene, a DIFFERENT TCastleScene from this tile's geometry, so its
      shadow map never sees the tile shapes. Put a shadow-casting sun in THIS
      tile root — the same shape tree as the tile ground+buildings — so CGE
      can render a shadow map for it. Global=True so it lights ALL shapes of
      this tile (matches the known-working AddSceneLights rig; a local light
      failed to shadow the PBR walls). It does NOT leak to other tiles: tile
      scenes keep CastGlobalLights=False, so only the map scene exports its
      rig. Added before Scene.Load below, so the loaded graph includes it.
      NB: ground uses a custom composite shader that lights itself via
      gc_SunDirToward and likely ignores the shadow map; PBR buildings go
      through CGE's pipeline and are the surfaces to watch. }
    if Osm3dStudioSettings.BuildingShadowsActive then
    begin
      TestSun := TDirectionalLightNode.Create;
      TestSun.Direction        := FSunDir;
      TestSun.Intensity        := 1.10;
      TestSun.AmbientIntensity := 0.35;
      TestSun.Color            := Vector3(1.00, 0.97, 0.90);
      TestSun.Global           := True;
      TestSun.Shadows          := True;
      Root.AddChildren(TestSun);
      { Scene.ShadowMaps defaults True, so no scene toggle needed; the light's
        Shadows flag marks it as caster. ChangedAll (run by Scene.Load) then
        calls ProcessShadowMapsReceivers, which logs ".. is using shadow maps"
        when it wires this up — grep the CGE log for that to confirm. }
      LogMain(Format('BuildingShadows TEST: shadow-sun (Shadows=True) '
        + 'injected into tile %s', [Key]));
    end;
    if GlobalMountInWorker then
    begin
      { отложенный фоновый монтаж: сцену НЕ наполняем здесь. Сначала main
        завершит всю работу со сценой (свойства ниже, Exists=False, Add в граф),
        и лишь потом отдаём её фоновому потоку (EnqueueMount после Add). }
      Scene.MountLoaded := False;
      Scene.MountFailed := False;
    end
    else
    begin
      Scene.MountGraph(Root);
    end;
    { CGE's native DistanceCulling measures from the scene bounding-box
      centre, which a single runaway vertex can drag far off the tile.
      Disabled here (0) — UpdateDistanceCulling does the cut per frame
      from the stable tile positioning centre instead. }
    Scene.DistanceCulling := 0;
    { Streamed tiles take no part in any ray/collision query. The host's
      avatar physics gets ground height from GroundYAt (a direct mesh
      sample), not from a raycast — and the third-person camera's
      "blocked camera" probe must not hit a tile, otherwise the tile's
      kilometre-wide bounding box swallows the camera and collapses the
      follow distance to zero. }
    Scene.Collides := False;
    Scene.Pickable := False;
    Scene.Exists := False;              { the base-tile ring turns it on }
    Batch.Owner.Add(Scene);
    { Сцена создана, настроена, инертна (Exists=False) и добавлена в граф — main
      с её ГРАФОМ закончил (дальше только CT.Scene := Scene и работа с моделью).
      Теперь фоновый поток наполняет её Scene.Load; активирует обратно main по
      готовности (SyncMountedExists в Update). }
    if GlobalMountInWorker then
      EnqueueMount(Scene, Root);

    CT := TCacheTile.Create;
    CT.Scene  := Scene;
    CT.Soundscape:=Assembled.Tiles[I].Soundscape;
    Assembled.Tiles[I].Soundscape:=nil;
    CT.GpuGround:=Assembled.Tiles[I].GpuGround;
    Assembled.Tiles[I].GpuGround:=nil;
    if (FGpuGround<>nil) and (CT.GpuGround<>nil) then begin
      CT.GpuOwner:=FGpuGround;FGpuGround.AddTile(CT.GpuGround,Scene);
    end;
    CT.Batch  := Batch;
    CT.Tile   := Assembled.Tiles[I].TileId;
    CT.Active := False;
    Inc(FShadowGen);             { unique per-mount generation (see MountGen) }
    CT.MountGen := FShadowGen;
    CT.CenterX := Assembled.Tiles[I].CenterX;
    CT.CenterZ := Assembled.Tiles[I].CenterZ;
    { Мировые границы этого тайла (после сварки) — чтобы соседи,
      смонтированные позже, приварились к нам. }
    if (BatchBorder <> nil) and BatchBorder.TryGetValue(Key, BWArr) then
      CT.BorderWorld := BWArr;
    Batch.Tiles.Add(CT);
    FTileIndex.AddOrSetValue(Assembled.Tiles[I].TileId.ToKey, CT);
    FTileIndexStr.AddOrSetValue(Key, CT);   { строковое зеркало — синхронно }
    LogMain(Format('TILE mount %s at world (%.1f, %.1f)',
      [Key, CT.CenterX, CT.CenterZ]));

    { Find the source TTileModel for this geo-tile: copy its terrain
      vertices into the cache tile (for GroundYAt). Отладочные FIT-сферы
      больше НЕ монтируются на тайл — они запечены в единый меш на цвет;
      опорные высоты под точками этого батча снимает CaptureRawGroundY
      ниже, а сцены цвета пересобирает UpdateDirtySphereScenes. }
    for J := 0 to N - 1 do
      if (AModels[J] <> nil) and
         AModels[J].TileId.Equals(CT.Tile) then
      begin
        BuildGroundField(CT, AModels[J], Assembled.Tiles[I].CurbVertices);
        Assembled.Tiles[I].CurbVertices:=Default(TCurbMesh);
        MountTileGrass(CT, AModels[J]);

        { BUILDING_OBSTACLE: register tile-local footprints in world space
          (offset by tile centre). Key = geo-tile ToKey for RemoveTile. }
        if (FBuildingObstacles <> nil)
           and (Length(AModels[J].BuildingObstacles) > 0) then
          FBuildingObstacles.AddObstacles(
            OffsetObstaclesXZ(AModels[J].BuildingObstacles,
              CT.CenterX, CT.CenterZ, TileScaleX(CT.Tile)),
            CT.Tile.ToKey);

        { Латч зелёного: тайл учтён, если оверлей выключен (снимать нечего)
          или снап уже готов — тогда CaptureRawGroundY(этот батч) снимет
          высоту настила/дороги под его снапнутыми точками. Если оверлей
          включён, но снап ещё не готов — оставляем False: резидентный
          тайл добёрет RetrofitGreenBudget после снапа. }
        if (not FShowFitPointsSnapped) or FSnappedReady then
          CT.GreenMounted := True;
        Break;
      end;

    SumX := SumX + Assembled.Tiles[I].CenterX;
    SumZ := SumZ + Assembled.Tiles[I].CenterZ;

  end;
  { Мировые границы пачки уже разложены по CT.BorderWorld. }
  FreeAndNil(BatchBorder);
  TLoadMs := GetTickCount64 - TAsm0;

  { Cross-pack shadows are NOT applied synchronously here. The off-thread
    pass below enqueues a mask snapshot for every tile this pack affects —
    the pack tiles (pull) and their already-mounted 1-ring neighbours
    (push, the reverse-order case where a caster arrives after its
    receiver). The worker rasterises off-thread and Update uploads one
    finished mask per frame, so neighbour shadows update without a
    MountBatch stall or a flicker. }

  { Batch centroid — used by PurgeFarBatches. }
  if Batch.Tiles.Count > 0 then
  begin
    Batch.CX := SumX / Batch.Tiles.Count;
    Batch.CZ := SumZ / Batch.Tiles.Count;
  end;

  { vegetation — partition the flat tree array back per geo-tile
 Each tree's geo-tile is derived ONCE (Unproject + TileAt, a UTM forward projection) and dropped
 straight into that tile's bucket — O(trees) projections plus a cheap 4-field Equals match against
 the <=UploadsPerFrame batch tiles (not O(tiles*trees)). }
  { TREEDIAG: сколько деревьев пришло из сборки для каждого тайла батча —
    логируем ДО gate'а (иначе при Length(Trees)=0 не увидим «лес не пришёл»). }
  if TREE_DIAG then
    for I := 0 to High(Assembled.Tiles) do
      if Assembled.Tiles[I].HasTileId then
        LogMain(Format('TREEDIAG arrive %d,%d c=(%.0f,%.0f) genTrees=%d ATrees=%d',
          [Integer(Assembled.Tiles[I].TileId.TX), Integer(Assembled.Tiles[I].TileId.TY),
           Assembled.Tiles[I].CenterX, Assembled.Tiles[I].CenterZ,
           Ord(FGenerateTrees), Length(Trees)]));

  if FGenerateTrees and (Length(Trees) > 0) then
  begin
    MountProfile := GetEnvironmentVariable('REZVIVO_TILE_MOUNT_PROFILE') = '1';
    if MountProfile then TreePartitionStarted := GetTickCount64;
    SetLength(TreeBuckets, Length(Assembled.Tiles));
    SetLength(BucketN,     Length(Assembled.Tiles));
    for I := 0 to High(Assembled.Tiles) do
      BucketN[I] := 0;

    for J := 0 to High(Trees) do
    begin
      TileLL  := FProj.Unproject(Trees[J].X, Trees[J].Z);
      TreeTid := FCache.Grid.TileAt(TileLL);
      Bi := -1;
      for I := 0 to High(Assembled.Tiles) do
        if Assembled.Tiles[I].HasTileId
           and TreeTid.Equals(Assembled.Tiles[I].TileId) then
        begin Bi := I; Break; end;
      if Bi < 0 then Continue;          { tree outside this batch's tiles }
      { Capacity-doubling — never SetLength per matching tree (O(n^2)). }
      if BucketN[Bi] >= Length(TreeBuckets[Bi]) then
        SetLength(TreeBuckets[Bi], BucketN[Bi] * 2 + 16);
      TreeBuckets[Bi][BucketN[Bi]] := Trees[J];
      Inc(BucketN[Bi]);
    end;

    if MountProfile then
      LogMain(Format('TILE_MOUNT_PROFILE partition trees=%d tiles=%d ms=%d',
        [Length(Trees), Length(Assembled.Tiles), GetTickCount64 - TreePartitionStarted]));

    for I := 0 to High(Assembled.Tiles) do
    begin
      if TREE_DIAG and Assembled.Tiles[I].HasTileId then
        LogMain(Format('TREEDIAG bucket %d,%d = %d trees (of %d in batch)',
          [Integer(Assembled.Tiles[I].TileId.TX), Integer(Assembled.Tiles[I].TileId.TY),
           BucketN[I], Length(Trees)]));
      if BucketN[I] = 0 then Continue;
      { Деревья монтируем ТОЛЬКО для тайлов, смонтированных ИМЕННО этим батчем.
        Пропущенный (уже резидентный в другом батче) тайл обслуживается тем
        батчем и уже имеет деревья: иначе добавим дубль, а EvictBatch пустого
        батча снесёт деревья резидентной копии по совпадению центра — баг
        «на обратной дороге тайл без леса». }
      if not (Assembled.Tiles[I].HasTileId
              and FTileIndex.TryGetValue(Assembled.Tiles[I].TileId.ToKey, CT)
              and (CT.Batch = Batch)) then Continue;
      SetLength(TreeBuckets[I], BucketN[I]);   { trim — MountTileTrees uses Length() }
      Centre := Vector3(Assembled.Tiles[I].CenterX, 0.0,
                        Assembled.Tiles[I].CenterZ);
      MountTileTrees(Centre, TreeBuckets[I]);
    end;
  end;

  { A batch that produced no tile leaves — nothing references the graph;
    evict it right away (full release of its assembled graph + owner). }
  if Batch.Tiles.Count = 0 then
  begin
    { SPAM-SILENCED: LogMain(Format('batch of %d produced empty tile set', [N])); }
    EvictBatch(Batch);
    Exit;
  end;

  if TAsmMs + TLoadMs >= 20 then
    LogMain(Format('batch of %d cached: assemble %d ms, load %d ms '
      + '(%d tiles, %d batches)',
      [N, TAsmMs, TLoadMs, FTileIndex.Count, FBatchList.Count]));

  { Off-thread ground shadows
 Enqueue every resident tile this pack AFFECTS: the pack tiles themselves
 (pull — distance 0) and their already-mounted 1-ring neighbours (push —
 distance 1, the cross-pack reverse-load case where a caster arrives after
 its receiver). Each gets a self-contained silhouette snapshot from the
 persistent registry; the streamer's worker rasterises it and Update
 uploads the result one mask per frame. No rasterisation on this thread —
 this is what removes the MountBatch stall. }
  if Osm3dStudioSettings.GroundShadowsActive then
  begin
    SetLength(PackTX, Length(Assembled.Tiles));
    SetLength(PackTY, Length(Assembled.Tiles));
    nPk := 0;
    for I := 0 to High(Assembled.Tiles) do
      if Assembled.Tiles[I].HasTileId then
      begin
        PackTX[nPk] := Integer(Assembled.Tiles[I].TileId.TX);
        PackTY[nPk] := Integer(Assembled.Tiles[I].TileId.TY);
        Inc(nPk);
      end;
    for CT in FTileIndex.Values do
    begin
      if CT = nil then Continue;
      ShAffected := False;            { within the 1-ring of any pack tile? }
      for J := 0 to nPk - 1 do
        if (Abs(Integer(CT.Tile.TX) - PackTX[J]) <= 1)
           and (Abs(Integer(CT.Tile.TY) - PackTY[J]) <= 1) then
        begin ShAffected := True; Break; end;
      if not ShAffected then Continue;
      if FAsmCache.GetTileMaskTexByKey(CT.Tile.ToString) = nil then Continue;
      { Dedupe: at most ONE shadow job per tile in flight. Without it a tile
        near the moving streaming front is re-enqueued by EVERY adjacent pack
        mount, piling up identical jobs that drain one-per-frame, each firing
        a ChangedAll that momentarily releases the shared building textures ->
        flicker.

        BUT a tile already pending may carry a snapshot taken BEFORE this
        pack's caster registered — the reverse-order cross-pack case, where a
        receiver was mounted before its caster. Dropping it outright left that
        receiver with the caster-less mask forever (the shadow never crossed
        the edge). So REMEMBER it instead: once its in-flight job drains, the
        per-frame re-request pass in Update re-enqueues it from the now-
        current registry (which holds the caster). Coalesced to one entry per
        tile -> no pile-up, one corrective re-gen. }
      if FStreamer.HasPendingShadow(CT.Tile.ToString) then
      begin
        FShadowReReq.AddOrSetValue(CT.Tile.ToString, 0);
        Continue;
      end;
      EnqueueTileShadow(CT);
    end;
  end;

  { Resident set grew — re-collect the per-tile wind uniform fields. }
  RefreshGroundWindFields;
end;

procedure TOsm3dStreamingMap.PrepareBatchForAssemble(
  const AIds: array of TGeoTileId; const AModels: array of TTileModel;
  out APreviews: TTilePreviewDataArray; out ABorder: TBorderWorldMap);
var
  I, N: Integer;
begin
  N := Length(AModels);
  { Красные сферы (CaptureRawGroundY) = опорная поверхность для сверки
    высот; FIT-коррекция печётся в геометрию при генерации тайла, поэтому
    пост-деформации смонтированных мешей тут нет. }
  CaptureRawGroundY(AModels, AIds);

  { Превью-меш земли для уровней B/C LOD: строим из тех же источников, что
    стример для дальних превью — высоты из terrarium (кэш, как правило уже
    прогрет генерацией тайла), текстура из блочного .ptex.png. nil (нет
    высот/сети) -> WrapTileLOD оставит композит. }
  SetLength(APreviews, N);
  for I := 0 to N - 1 do
  begin
    APreviews[I] := nil;
    if (I <= High(AIds)) and (FStreamer <> nil) then
      APreviews[I] := FStreamer.BuildHeightPreview(AIds[I]);
  end;

  { Сшивка границ: приварить граничные вершины НОВЫХ тайлов к уже
    загруженным соседям ДО сборки сцены. Делаем на моделях (до пула и до
    выпечки узлов), результат — мировые границы каждой модели в ABorder.
    Ошибка сварки не должна срывать монтаж. }
  ABorder := TBorderWorldMap.Create;
  try
    SyncTileBorders(AModels, ABorder);
  except
    on E: Exception do
      LogMain('border weld skipped: ' + E.Message);
  end;

  { Let the shadow pass project tree billboard textures (same path the
    tree renderer uses). Один общий набор альфа-масок (Osm3dTreeShadow)
    на ассемблер и теневой воркер; SetTreeShadowDir грузит их жадно на
    этом (главном) потоке до постановки первой mask-джобы. }
  SetTreeShadowDir(TREE_TEXTURES_PATH);
end;

procedure TOsm3dStreamingMap.MountBatch(const AIds: array of TGeoTileId;
  const AModels: array of TTileModel);
var
  Models:    TTileModelArray;
  Trees:     TTileTreeRecArray;
  Assembled: TAssembledScenes;
  Batch:     TCacheBatch;
  Root:      TX3DRootNode;
  Scene:     TProfiledScene;
  CT:        TCacheTile;
  Key:       string;
  N, I, J:   Integer;
  TAsm0, TAsmMs, TLoadMs: QWord;
  TreeBuckets: array of TTileTreeRecArray;  { one tree bucket per Assembled.Tiles entry }
  BucketN:     array of Integer;            { fill count per bucket }
  Previews:    TTilePreviewDataArray;   { per-tile превью для меша земли B/C }
  TreeTid:     TGeoTileId;
  Bi:          Integer;
  TileLL:    TLatLon;
  SumX, SumZ: Double;
  Centre:    TVector3;
  PackTX, PackTY: array of Integer;
  nPk:       Integer;
  ShAffected: Boolean;
  BatchBorder: TBorderWorldMap;   { мировые границы моделей этой пачки }
  BWArr:       TBorderWorldArray;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(834);{$ENDIF}
  N := Length(AModels);
  if N = 0 then Exit;

  Assembled := nil;
  Trees     := nil;
  BatchBorder := nil;

  { assemble the whole pack in one call (atlas built once) }
  TAsm0 := GetTickCount64;
  try
    SetLength(Models, N);
    for I := 0 to N - 1 do
      Models[I] := AModels[I];

    { Общий с EnqueueAssembleBatch пролог: красные сферы, превью земли,
      сшивка границ, альфа-маски деревьев. }
    PrepareBatchForAssemble(AIds, Models, Previews, BatchBorder);

    Assembled := TSceneAssembler.AssembleCachedTiles(
      Models, FOrigin, FHeightmapZoom, FSunDir, Trees, Previews, nil, FAsmCache,
      False, FManualScaleLat);
  except
    on E: Exception do
    begin
      LogMain('batch assemble FAILED: ' + E.Message);
      for I := 0 to High(Previews) do FreeAndNil(Previews[I]);
      FreeAndNil(Assembled);
      FreeAndNil(BatchBorder);
      Exit;
    end;
  end;
  for I := 0 to High(Previews) do FreeAndNil(Previews[I]);
  TAsmMs := GetTickCount64 - TAsm0;

  MountAssembled(Assembled, Trees, BatchBorder, AModels, AIds, TAsmMs);
end;

procedure TOsm3dStreamingMap.MountTileTrees(const ACenter: TVector3;
  const ATrees: TTileTreeRecArray);
var
  TreeArr, ShrubArr: TTreeInstanceArray;
  NT, NS, I:         Integer;
  TTex0:             QWord;
  MountProfile: Boolean;
  ProfileStarted, ProfileProceduralMs, ProfileSplitMs, ProfileLegacyMs: QWord;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(835);{$ENDIF}
  { RenderTrees off: never touch the GPU for vegetation — no shared-texture
    upload (below), no per-tile instance VBO, and therefore no EnsureSharedGL
    shader-program build. Authoritative hard gate on the live global. }
  if not Osm3dStudioSettings.RenderTreesActive then Exit;
  if (not FGenerateTrees) or (Length(ATrees) = 0) then Exit;
  if (FTreeRenderer = nil) or (FShrubRenderer = nil) then Exit;
  MountProfile := GetEnvironmentVariable('REZVIVO_TILE_MOUNT_PROFILE') = '1';
  if MountProfile then ProfileStarted := GetTickCount64;
  if FProceduralRenderer <> nil then
    FProceduralRenderer.AddTile(ATrees, ACenter.X, ACenter.Z, FProj);
  if MountProfile then
  begin
    ProfileProceduralMs := GetTickCount64 - ProfileStarted;
    ProfileStarted := GetTickCount64;
  end;

  if not ProceduralVegetationActive and not TCastleAbstractTreeRenderer.AreSharedTexturesLoaded then
  begin
    TTex0 := GetTickCount64;
    try
      TCastleAbstractTreeRenderer.LoadSharedTextures(TREE_TEXTURES_PATH);
      LogMain(Format('tree textures loaded in %d ms',
                     [GetTickCount64 - TTex0]));
    except
      on E: Exception do
        LogMain('tree textures load FAILED: ' + E.Message);
    end;
  end;
  if not ProceduralVegetationActive and not TCastleAbstractShrubRenderer.AreSharedTexturesLoaded then
  begin
    TTex0 := GetTickCount64;
    try
      TCastleAbstractShrubRenderer.LoadSharedTextures(SHRUB_TEXTURES_PATH);
      LogMain(Format('shrub textures loaded in %d ms',
                     [GetTickCount64 - TTex0]));
    except
      on E: Exception do
        LogMain('shrub textures load FAILED: ' + E.Message);
    end;
  end;

  NT := 0;  NS := 0;
  for I := 0 to High(ATrees) do
    if ATrees[I].IsShrub then Inc(NS) else Inc(NT);
  SetLength(TreeArr,  NT);
  SetLength(ShrubArr, NS);
  NT := 0;  NS := 0;
  for I := 0 to High(ATrees) do
    if ATrees[I].IsShrub then
    begin
      ShrubArr[NS].X           := ATrees[I].X;
      ShrubArr[NS].Y           := ATrees[I].Y;
      ShrubArr[NS].Z           := ATrees[I].Z;
      ShrubArr[NS].Scale       := ATrees[I].Scale;
      ShrubArr[NS].Rotation    := ATrees[I].Rotation;
      ShrubArr[NS].SeedAsTexId := ATrees[I].Seed;
      Inc(NS);
    end
    else
    begin
      TreeArr[NT].X           := ATrees[I].X;
      TreeArr[NT].Y           := ATrees[I].Y;
      TreeArr[NT].Z           := ATrees[I].Z;
      TreeArr[NT].Scale       := ATrees[I].Scale;
      TreeArr[NT].Rotation    := ATrees[I].Rotation;
      TreeArr[NT].SeedAsTexId := ATrees[I].Seed;
      Inc(NT);
    end;

  { Vegetation cull radius is its OWN LOD knob — TreesFarMeters /
    ShrubsFarMeters — NOT TileCullDistance. TileCullDistance is the
    ground-tile streaming cull (GlobalLODConfig.GroundVisibilityM, ~3 km);
    feeding it here made every billboard draw out to the streaming horizon.
    LocalRender's per-tile FCullDistance test is the hard cull for
    trees/shrubs, and these two fields are exactly what set it. }
  if MountProfile then
  begin
    ProfileSplitMs := GetTickCount64 - ProfileStarted;
    ProfileStarted := GetTickCount64;
  end;
  if TREE_DIAG then
    LogMain(Format('TREEDIAG add c=(%.0f,%.0f) trees=%d shrubs=%d',
      [ACenter.X, ACenter.Z, NT, NS]));
  if NT > 0 then
    FTreeRenderer.AddTile(TreeArr, ACenter.X, ACenter.Z,
      GlobalLODConfig.TreesFarMeters);
  if NS > 0 then
    FShrubRenderer.AddTile(ShrubArr, ACenter.X, ACenter.Z,
      GlobalLODConfig.ShrubsFarMeters);
  if MountProfile then
  begin
    ProfileLegacyMs := GetTickCount64 - ProfileStarted;
    LogMain(Format('TILE_MOUNT_PROFILE trees c=(%.1f,%.1f) count=%d procedural=%d split_and_textures=%d legacy=%d ms',
      [ACenter.X, ACenter.Z, Length(ATrees), ProfileProceduralMs,
       ProfileSplitMs, ProfileLegacyMs]));
  end;
end;

{ true, если materialId — травяной (в id-пространстве композита земли).
  Whitelist задаёт ПЕРИМЕТР (какие материалы в принципе могут нести траву),
  а конфиг GROUND_MATERIALS[..].Grasses — включатель: пустой (в т.ч.
  закомментированный) Grasses гасит траву материала уже здесь, на
  экстракции — ни подмешей, ни джобов разброса. Включить траву материалу
  ВНЕ периметра конфигом нельзя — расширяйте whitelist осознанно. }
function GrassMatIsGrass(Id: Integer): Boolean;
begin
  Result := ((Id = GROUND_MAT_TERRAIN) or
             (Id = GROUND_MAT_FOREST_FLOOR) or
             (Id = GROUND_MAT_GRASS) or (Id = GROUND_MAT_MANIC_GRASS) or
             (Id = GROUND_MAT_GARDEN) or (Id = GROUND_MAT_PITCH_GENERIC) or
             (Id = GROUND_MAT_PITCH_FOOT))
            and (GrassMatDensity(Id) > 0.0);
end;

{ Extract grass in the same world frame as the rendered ground and roads:
  X = tile-local X * TileFrameScaleX + center X; Z = local Z + center Z.
  Y is already an absolute elevation. The latitude scale matters when the
  camera travels away from the session origin. Empty MatIds denotes a
  legacy smkGrass mesh; otherwise all three vertices must be grass. }
function ExtractGrassMeshWorld(Src: TMesh; const MatIds: TTileMatIdArray;
  OffX, OffZ: Single; ScaleX: Double; out TriMat: TTileMatIdArray;
  LegacyMaterial: Integer = GROUND_MAT_GRASS): TMesh;
var
  Verts: TMeshVertexArray;
  Idx:   TMeshIndexArray;
  I, TriCount, a, b, c, na, nb, nc, outN: Integer;
  V: TMeshVertex;
  Legacy: Boolean;
begin
  Result := TMesh.Create('grass-sub');
  TriMat := nil;
  TriCount := Src.TriangleCount;
  if TriCount = 0 then Exit;
  Verts := Src.Vertices;
  Idx   := Src.Indices;
  Legacy := Length(MatIds) = 0;
  SetLength(TriMat, TriCount);   { максимум; ужмём в конце }
  outN := 0;
  for I := 0 to TriCount - 1 do
  begin
    a := Idx[I * 3 + 0]; b := Idx[I * 3 + 1]; c := Idx[I * 3 + 2];
    if Legacy or (GrassMatIsGrass(MatIds[a]) and GrassMatIsGrass(MatIds[b]) and
       GrassMatIsGrass(MatIds[c])) then
    begin
      V := Verts[a]; V.Position.X := V.Position.X * ScaleX + OffX;
                     V.Position.Z := V.Position.Z + OffZ; na := Result.AddVertex(V);
      V := Verts[b]; V.Position.X := V.Position.X * ScaleX + OffX;
                     V.Position.Z := V.Position.Z + OffZ; nb := Result.AddVertex(V);
      V := Verts[c]; V.Position.X := V.Position.X * ScaleX + OffX;
                     V.Position.Z := V.Position.Z + OffZ; nc := Result.AddVertex(V);
      Result.AddTriangle(na, nb, nc);
      { материал треугольника = материал его 1-й вершины (все три травяные) —
        по нему рендер выберет вид/ячейку атласа и плотность }
      if Legacy then TriMat[outN] := LegacyMaterial
      else TriMat[outN] := MatIds[a];
      Inc(outN);
    end;
  end;
  SetLength(TriMat, outN);
end;

var
  CARVE_DIAG: Boolean = False;  { диагностика карва: подсветка ЛЮБЫХ перекрытий наземного композита }

{ имя материала для лога ('' -> 'matN') }
function CarveMatName(Id: Integer): string;
begin
  if (Id >= 0) and (Id < GROUND_MAT_COUNT) and (GROUND_MATERIALS[Id].Name <> '') then
    Result := GROUND_MATERIALS[Id].Name
  else
    Result := 'mat' + IntToStr(Id);
end;

function CarvePopCount32(M: LongWord): Integer;
begin
  Result := 0;
  while M <> 0 do begin Inc(Result, Integer(M and 1)); M := M shr 1; end;
end;

{ Проверка корректности карва наземного композита: ищет пятна XZ, накрытые
  БОЛЕЕ ЧЕМ ОДНИМ треугольником, НЕЗАВИСИМО от материала. Отличие от прежней
  версии — суб-семплинг SSxSS внутри каждой ячейки: считается РЕАЛЬНАЯ
  наложенная площадь (число подвыборок с покрытием>=2 * площадь подвыборки),
  а не факт «центр ячейки задет». Это отделяет настоящий двойной слой от слегка
  задетого края / погрешности округления: касание даёт ~1 подвыборку из SS*SS
  (площадь near-zero), реальное наложение — почти все. Вердикт и разбивка по
  материалам — по площади (m^2), поэтому слайверы/округление вырождаются в шум.
  Классификация same/cross-mat — по объединению материалов в ячейке (огрублённо:
  чужой материал, лишь касающийся ячейки, может пометить её cross-mat, но его
  площадь near-zero). Возвращает многострочный отчёт ('' если считать нечего). }
function CompositeCarveDiag(Src: TMesh; const MatIds: TTileMatIdArray;
  CenterX, CenterZ: Single): string;
const
  MAX_CELLS = 1000000;
  SS   = 4;            { подвыборок на ось -> SS*SS на ячейку }
  SUBN = SS * SS;
var
  Verts: TMeshVertexArray;
  Idx:   TMeshIndexArray;
  TriCount, I, m, nx, nz, cix, ciz, cix0, cix1, ciz0, ciz1, sx, sy, sub, cb, c: Integer;
  Cell, minX, minZ, maxX, maxZ: Single;
  ax, az, bx, bz, gx, gz, e1x, e1y, e1z, e2x, e2y, e2z, crx, cry, crz, area3: Single;
  tMinX, tMaxX, tMinZ, tMaxZ, pX, pZ, d1, d2, d3: Single;
  SubCov: array of Byte;        { покрытий на подвыборку }
  Mask:   array of LongWord;    { материалы, присутствующие в ячейке }
  MatArea:     array[0 .. GROUND_MAT_COUNT - 1] of Double;
  SameMatArea: array[0 .. GROUND_MAT_COUNT - 1] of Double;
  pairArea:    array[0 .. GROUND_MAT_COUNT - 1, 0 .. GROUND_MAT_COUNT - 1] of Double;
  coveredCells, overlapCells, solidCells, maxStack, gi, gj, cellBase: Integer;
  cellCov1, cellCov2, cellMax: Integer;
  coveredSub, overlapSub, sumSubCov: Int64;
  cmask: LongWord;
  totArea3, cellArea, subCellArea, footprint, realOverlapArea, rawOverlapArea: Double;
  projWithMult, triRatio, meanStack, slopeFactor, realCellOvArea, sameTot, crossTot: Double;
  verdict: string;
begin
  Result := '';
  if Src = nil then Exit;
  TriCount := Src.TriangleCount;
  if (TriCount = 0) or (Length(MatIds) <> Src.VertexCount) then Exit;
  Verts := Src.Vertices;  Idx := Src.Indices;

  for I := 0 to GROUND_MAT_COUNT - 1 do begin MatArea[I] := 0.0; SameMatArea[I] := 0.0; end;
  for gi := 0 to GROUND_MAT_COUNT - 1 do
    for gj := 0 to GROUND_MAT_COUNT - 1 do pairArea[gi, gj] := 0.0;

  minX := 1e30; minZ := 1e30; maxX := -1e30; maxZ := -1e30;
  for I := 0 to Src.VertexCount - 1 do
  begin
    pX := Verts[I].Position.X;  pZ := Verts[I].Position.Z;
    if pX < minX then minX := pX;  if pX > maxX then maxX := pX;
    if pZ < minZ then minZ := pZ;  if pZ > maxZ then maxZ := pZ;
  end;
  if (maxX <= minX) or (maxZ <= minZ) then Exit;

  Cell := 1.0;
  while True do
  begin
    nx := Trunc((maxX - minX) / Cell) + 2;
    nz := Trunc((maxZ - minZ) / Cell) + 2;
    if (Int64(nx) * nz <= MAX_CELLS) or (Cell >= 128.0) then Break;
    Cell := Cell * 2.0;
  end;
  if Int64(nx) * nz > MAX_CELLS then Exit;
  cellArea    := Cell * Cell;
  subCellArea := cellArea / SUBN;

  SetLength(SubCov, (nx * nz) * SUBN);   { FPC обнуляет память при SetLength }
  SetLength(Mask,   nx * nz);

  totArea3 := 0.0;
  for I := 0 to TriCount - 1 do
  begin
    m := MatIds[Idx[I * 3]];   { регионы не сварены -> треугольник одноматериальный }
    if (m < 0) or (m >= GROUND_MAT_COUNT) then Continue;

    ax := Verts[Idx[I*3  ]].Position.X;  az := Verts[Idx[I*3  ]].Position.Z;
    bx := Verts[Idx[I*3+1]].Position.X;  bz := Verts[Idx[I*3+1]].Position.Z;
    gx := Verts[Idx[I*3+2]].Position.X;  gz := Verts[Idx[I*3+2]].Position.Z;

    e1x := bx - ax;
    e1y := Verts[Idx[I*3+1]].Position.Y - Verts[Idx[I*3]].Position.Y;
    e1z := bz - az;
    e2x := gx - ax;
    e2y := Verts[Idx[I*3+2]].Position.Y - Verts[Idx[I*3]].Position.Y;
    e2z := gz - az;
    crx := e1y*e2z - e1z*e2y;  cry := e1z*e2x - e1x*e2z;  crz := e1x*e2y - e1y*e2x;
    area3 := 0.5 * Sqrt(crx*crx + cry*cry + crz*crz);
    if area3 <= 0.0 then Continue;
    MatArea[m] := MatArea[m] + area3;
    totArea3   := totArea3 + area3;

    tMinX := ax; if bx < tMinX then tMinX := bx; if gx < tMinX then tMinX := gx;
    tMaxX := ax; if bx > tMaxX then tMaxX := bx; if gx > tMaxX then tMaxX := gx;
    tMinZ := az; if bz < tMinZ then tMinZ := bz; if gz < tMinZ then tMinZ := gz;
    tMaxZ := az; if bz > tMaxZ then tMaxZ := bz; if gz > tMaxZ then tMaxZ := gz;
    cix0 := Trunc((tMinX - minX) / Cell);  cix1 := Trunc((tMaxX - minX) / Cell);
    ciz0 := Trunc((tMinZ - minZ) / Cell);  ciz1 := Trunc((tMaxZ - minZ) / Cell);
    if cix0 < 0 then cix0 := 0;  if cix1 > nx - 1 then cix1 := nx - 1;
    if ciz0 < 0 then ciz0 := 0;  if ciz1 > nz - 1 then ciz1 := nz - 1;

    for ciz := ciz0 to ciz1 do
      for cix := cix0 to cix1 do
      begin
        cellBase := ciz * nx + cix;
        for sy := 0 to SS - 1 do
          for sx := 0 to SS - 1 do
          begin
            pX := minX + (cix + (sx + 0.5) / SS) * Cell;
            pZ := minZ + (ciz + (sy + 0.5) / SS) * Cell;
            d1 := (pX - bx) * (az - bz) - (ax - bx) * (pZ - bz);
            d2 := (pX - gx) * (bz - gz) - (bx - gx) * (pZ - gz);
            d3 := (pX - ax) * (gz - az) - (gx - ax) * (pZ - az);
            { строго внутри -> подвыборка лежит ровно в одном треугольнике
              корректной триангуляции; наложение -> покрытие>=2 }
            if ((d1 > 0) and (d2 > 0) and (d3 > 0)) or
               ((d1 < 0) and (d2 < 0) and (d3 < 0)) then
            begin
              sub := cellBase * SUBN + (sy * SS + sx);
              if SubCov[sub] < High(Byte) then Inc(SubCov[sub]);
              Mask[cellBase] := Mask[cellBase] or (LongWord(1) shl m);
            end;
          end;
      end;
  end;

  coveredCells := 0; overlapCells := 0; solidCells := 0; maxStack := 0;
  coveredSub := 0; overlapSub := 0; sumSubCov := 0;
  sameTot := 0.0; crossTot := 0.0;
  for cb := 0 to (nx * nz) - 1 do
  begin
    cellCov1 := 0; cellCov2 := 0; cellMax := 0;
    for sub := 0 to SUBN - 1 do
    begin
      c := SubCov[cb * SUBN + sub];
      if c = 0 then Continue;
      Inc(cellCov1);
      sumSubCov := sumSubCov + c;
      if c > cellMax then cellMax := c;
      if c >= 2 then Inc(cellCov2);
    end;
    if cellCov1 = 0 then Continue;
    Inc(coveredCells);
    coveredSub := coveredSub + cellCov1;
    if cellMax > maxStack then maxStack := cellMax;
    if cellCov2 > 0 then
    begin
      Inc(overlapCells);
      overlapSub := overlapSub + cellCov2;
      realCellOvArea := cellCov2 * subCellArea;
      cmask := Mask[cb];
      if CarvePopCount32(cmask) >= 2 then
      begin
        crossTot := crossTot + realCellOvArea;
        for gi := 0 to GROUND_MAT_COUNT - 1 do
          if (cmask and (LongWord(1) shl gi)) <> 0 then
            for gj := gi + 1 to GROUND_MAT_COUNT - 1 do
              if (cmask and (LongWord(1) shl gj)) <> 0 then
                pairArea[gi, gj] := pairArea[gi, gj] + realCellOvArea;
      end
      else
      begin
        sameTot := sameTot + realCellOvArea;
        for gi := 0 to GROUND_MAT_COUNT - 1 do
          if (cmask and (LongWord(1) shl gi)) <> 0 then
          begin SameMatArea[gi] := SameMatArea[gi] + realCellOvArea; Break; end;
      end;
      if cellCov2 * 2 >= SUBN then Inc(solidCells);   { ячейка >=50% двойного слоя }
    end;
  end;

  footprint       := coveredSub * subCellArea;
  realOverlapArea := overlapSub * subCellArea;
  rawOverlapArea  := overlapCells * cellArea;
  projWithMult    := sumSubCov * subCellArea;
  if footprint > 0    then triRatio  := totArea3 / footprint     else triRatio  := 0.0;
  if coveredSub > 0   then meanStack := sumSubCov / coveredSub    else meanStack := 0.0;
  if projWithMult > 0 then slopeFactor := totArea3 / projWithMult else slopeFactor := 0.0;
  { по построению triRatio = meanStack * slopeFactor }

  if overlapSub = 0 then
    verdict := 'карв OK: перекрытий нет'
  else if realOverlapArea < 0.01 * footprint then
    verdict := Format('карв OK: только касания/округление (real %.1f m^2 < 1%% площади)', [realOverlapArea])
  else
    verdict := Format('ВНИМАНИЕ: реальный двойной слой %.0f m^2 (%.1f%% площади) — карв не срезал перекрытие',
                      [realOverlapArea, 100.0 * realOverlapArea / footprint]);

  Result :=
    Format('CARVE-OVERLAP tile(%.0f,%.0f) cell=%.1fm sub=%dx%d  cells: covered=%d overlap=%d solid>=50%%=%d (maxStack=%d meanStack=x%.2f)',
      [CenterX, CenterZ, Cell, SS, SS, coveredCells, overlapCells, solidCells, maxStack, meanStack]) + #10 +
    Format('  множитель плотности x%.3f = перекрытие x%.2f * наклон x%.2f  | footprint=%.0f m^2  tri-area-3D=%.0f m^2',
      [triRatio, meanStack, slopeFactor, footprint, totArea3]) + #10 +
    Format('  overlap area: real=%.0f m^2 (sub %.2fm)  raw-cell=%.0f m^2  -> касания/округление ~%.0f m^2',
      [realOverlapArea, Cell / SS, rawOverlapArea, rawOverlapArea - realOverlapArea]);
  if sameTot > 0 then
  begin
    Result := Result + #10 + '  same-mat overlap area (m^2):';
    for gi := 0 to GROUND_MAT_COUNT - 1 do
      if SameMatArea[gi] > 0 then
        Result := Result + Format(' %s(id%d)=%.0f', [CarveMatName(gi), gi, SameMatArea[gi]]);
  end;
  if crossTot > 0 then
  begin
    Result := Result + #10 + '  cross-mat overlap area (m^2):';
    for gi := 0 to GROUND_MAT_COUNT - 1 do
      for gj := gi + 1 to GROUND_MAT_COUNT - 1 do
        if pairArea[gi, gj] > 0 then
          Result := Result + Format(' %s(id%d)+%s(id%d)=%.0f',
            [CarveMatName(gi), gi, CarveMatName(gj), gj, pairArea[gi, gj]]);
  end;
  Result := Result + #10 + '  area m^2:';
  for gi := 0 to GROUND_MAT_COUNT - 1 do
    if MatArea[gi] > 0 then
      Result := Result + Format(' %s=%.0f', [CarveMatName(gi), MatArea[gi]]);
  Result := Result + #10 + '  => ' + verdict;
end;

procedure TOsm3dStreamingMap.MountTileGrass(ACT: TCacheTile; AModel: TTileModel);
var
  MeshI, LegacyMaterial: Integer;
  Rec:   TTileMeshRec;
  GrassMesh: TMesh;
  GrassTriMat: TTileMatIdArray;
  Kx: Double;
begin
  if FGrassRenderer = nil then Exit;
  if (ACT = nil) or (AModel = nil) then Exit;
  if not Osm3dStudioSettings.RenderGrassActive then Exit;   { свой тумблер травы }

  { идемпотентность ре-монтажа: сначала снять прежние записи этого центра }
  FGrassRenderer.RemoveTile(ACT.CenterX, ACT.CenterZ);
  Kx := TileScaleX(AModel.TileId);

  for MeshI := 0 to AModel.MeshCount - 1 do
  begin
    Rec := AModel.Meshes[MeshI];   { GetMesh отдаёт запись по значению; Mesh/MatIds — ссылки }
    if Rec.Mesh = nil then Continue;

    { (1) Земля — композитный меш smkSurface с per-vertex MatIds: травинки
      сажаем на травяные треугольники (id из MatIds), смещённые в мир. }
    if (Rec.Material = smkSurface) and (Rec.Mesh.TriangleCount > 0) and
       (Length(Rec.MatIds) = Rec.Mesh.VertexCount) then
    begin
      if CARVE_DIAG then
        LogMain(CompositeCarveDiag(Rec.Mesh, Rec.MatIds, ACT.CenterX, ACT.CenterZ));
      GrassMesh := ExtractGrassMeshWorld(Rec.Mesh, Rec.MatIds,
        ACT.CenterX, ACT.CenterZ, Kx, GrassTriMat);
      { Разброс — в фоне: ExtractGrassMeshWorld отдал САМОСТОЯТЕЛЬНЫЙ меш (копия
        треугольников, не связан с AModel), поэтому владение можно передать
        воркеру. EnqueueTile сам освободит меш (после разброса или сразу, если
        треугольников нет). НИКАКОГО free здесь — иначе use-after-free в воркере. }
      FGrassRenderer.EnqueueTile(GrassMesh, GrassTriMat, ACT.CenterX, ACT.CenterZ);
    end
    { Legacy grass and undergrowth still share the same world transform. }
    else if (Rec.Material in [smkGrass, smkForest, smkScrub]) and
      (Rec.Mesh.TriangleCount > 0) then
    begin
      if Rec.Material = smkGrass then LegacyMaterial := GROUND_MAT_GRASS
      else LegacyMaterial := GROUND_MAT_FOREST_FLOOR;
      GrassMesh := ExtractGrassMeshWorld(Rec.Mesh, [],
        ACT.CenterX, ACT.CenterZ, Kx, GrassTriMat, LegacyMaterial);
      FGrassRenderer.EnqueueTile(GrassMesh, GrassTriMat, ACT.CenterX, ACT.CenterZ);
    end;
  end;
end;

procedure TOsm3dStreamingMap.BuildGroundField(ACT: TCacheTile;
  AModel: TTileModel; const Curbs: TCurbMesh);
const
  GROUND_MESH_KINDS = [smkTerrain, smkGrass, smkSurface, smkSand,
                       smkFarmland, smkForest];
var
  MeshI, T, K, GX, GZ, N, Idx: Integer;
  Msh: TMesh;
  A, B, C: TVector3;
  MinX, MaxX, MinZ, MaxZ: Single;
  HaveAny: Boolean;
  CellW, CellH: Single;
  TriCount, OutTri, VertexCount, OutVertex: Integer;
  TMinX, TMaxX, TMinZ, TMaxZ: Single;
  Gx0, Gx1, Gz0, Gz1: Integer;
  BinCount: array of Integer;   { фактическое число индексов в ячейке; Length() — ёмкость }
  Idxs: TMeshIndexArray;
  Verts: TMeshVertexArray;
  Kx: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1720);{$ENDIF}
  if ACT = nil then Exit;
  ACT.GroundHasField := False;
  if AModel = nil then Exit;

  { 1) Tile-local XZ bounds + общее число треугольников терраина. }
  ACT.HasMarineWater:=TileHasMarineWater(AModel);
  if (GpuGroundMode=ggGpu) and (ACT.GpuGround<>nil) then begin
    ACT.GroundHasField:=True;Exit;
  end;
  Kx := TileScaleX(AModel.TileId);
  HaveAny := False;
  MinX := 0; MaxX := 0; MinZ := 0; MaxZ := 0;
  TriCount := 0;
  VertexCount := 0;
  for MeshI := 0 to AModel.MeshCount - 1 do
  begin
    if not (AModel.Meshes[MeshI].Material in GROUND_MESH_KINDS) then Continue;
    Msh := AModel.Meshes[MeshI].Mesh;
    if Msh = nil then Continue;
    Inc(TriCount, Msh.TriangleCount);
    Inc(VertexCount, Msh.VertexCount);
    Verts := Msh.Vertices;
    for K := 0 to Msh.VertexCount - 1 do
    begin
      A := Verts[K].Position;
      A.X := A.X * Kx;
      if not HaveAny then
      begin
        MinX := A.X; MaxX := A.X; MinZ := A.Z; MaxZ := A.Z;
        HaveAny := True;
      end
      else
      begin
        if A.X < MinX then MinX := A.X;
        if A.X > MaxX then MaxX := A.X;
        if A.Z < MinZ then MinZ := A.Z;
        if A.Z > MaxZ then MaxZ := A.Z;
      end;
    end;
  end;
  if (not HaveAny) or (TriCount = 0)
     or (MaxX - MinX < 1.0) or (MaxZ - MinZ < 1.0) then Exit;

  { Preserve source indices: adjacent triangles share their positions.
    The triangle sequence and all coordinates remain unchanged. }
  SetLength(ACT.GroundVertices, VertexCount + Length(Curbs.Positions));
  SetLength(ACT.GroundIndices, TriCount * 3 + Length(Curbs.Indices));
  OutTri := 0;
  OutVertex := 0;
  for MeshI := 0 to AModel.MeshCount - 1 do
  begin
    if not (AModel.Meshes[MeshI].Material in GROUND_MESH_KINDS) then Continue;
    Msh := AModel.Meshes[MeshI].Mesh;
    if Msh = nil then Continue;
    Idxs := Msh.Indices;
    Verts := Msh.Vertices;
    for K := 0 to Msh.VertexCount - 1 do
    begin
      A := Verts[K].Position; A.X := A.X * Kx;
      ACT.GroundVertices[OutVertex + K] := A;
    end;
    for K := 0 to Msh.TriangleCount * 3 - 1 do
      ACT.GroundIndices[OutTri * 3 + K] := OutVertex + Idxs[K];
    Inc(OutVertex, Msh.VertexCount);
    Inc(OutTri, Msh.TriangleCount);
  end;
  ACT.GroundCurbFirst := OutTri;
  for K := 0 to High(Curbs.Positions) do
  begin
    A := Curbs.Positions[K];
    ACT.GroundVertices[OutVertex + K] := A;
    MinX:=Min(MinX,A.X); MaxX:=Max(MaxX,A.X);
    MinZ:=Min(MinZ,A.Z); MaxZ:=Max(MaxZ,A.Z);
  end;
  for K := 0 to High(Curbs.Indices) do
    ACT.GroundIndices[OutTri * 3 + K] := OutVertex + Curbs.Indices[K];
  TriCount := OutTri + Length(Curbs.Indices) div 3;

  { 3) Bin-сетка GroundGridN x GroundGridN: треугольник попадает во все
       ячейки, которые пересекает его XZ-AABB. GroundYAt перебирает
       только треугольники своей ячейки. }
  N := GroundGridN;
  SetLength(ACT.GroundBin, N * N);
  SetLength(BinCount, N * N);   { нули — ячейки пусты }
  CellW := (MaxX - MinX) / N;
  CellH := (MaxZ - MinZ) / N;
  if CellW <= 0 then CellW := 1.0;
  if CellH <= 0 then CellH := 1.0;

  for T := 0 to TriCount - 1 do
  begin
    A := ACT.GroundVertices[ACT.GroundIndices[T * 3    ]];
    B := ACT.GroundVertices[ACT.GroundIndices[T * 3 + 1]];
    C := ACT.GroundVertices[ACT.GroundIndices[T * 3 + 2]];
    TMinX := A.X; if B.X < TMinX then TMinX := B.X; if C.X < TMinX then TMinX := C.X;
    TMaxX := A.X; if B.X > TMaxX then TMaxX := B.X; if C.X > TMaxX then TMaxX := C.X;
    TMinZ := A.Z; if B.Z < TMinZ then TMinZ := B.Z; if C.Z < TMinZ then TMinZ := C.Z;
    TMaxZ := A.Z; if B.Z > TMaxZ then TMaxZ := B.Z; if C.Z > TMaxZ then TMaxZ := C.Z;

    Gx0 := Trunc((TMinX - MinX) / CellW);
    Gx1 := Trunc((TMaxX - MinX) / CellW);
    Gz0 := Trunc((TMinZ - MinZ) / CellH);
    Gz1 := Trunc((TMaxZ - MinZ) / CellH);
    if Gx0 < 0 then Gx0 := 0; if Gx1 > N - 1 then Gx1 := N - 1;
    if Gz0 < 0 then Gz0 := 0; if Gz1 > N - 1 then Gz1 := N - 1;

    for GZ := Gz0 to Gz1 do
      for GX := Gx0 to Gx1 do
      begin
        Idx := GZ * N + GX;
        { Capacity-doubling — не SetLength на каждый треугольник (O(n^2)
          реаллокаций на ячейку). Length() ячейки здесь — ёмкость,
          BinCount — фактическое число индексов. }
        if BinCount[Idx] >= Length(ACT.GroundBin[Idx]) then
          SetLength(ACT.GroundBin[Idx], BinCount[Idx] * 2 + 16);
        ACT.GroundBin[Idx][BinCount[Idx]] := T;
        Inc(BinCount[Idx]);
      end;
  end;

  { Обрезать ёмкости до фактических счётчиков — GroundYAt итерирует Length(). }
  for Idx := 0 to N * N - 1 do
    if Length(ACT.GroundBin[Idx]) <> BinCount[Idx] then
      SetLength(ACT.GroundBin[Idx], BinCount[Idx]);

  ACT.GroundMinX := MinX;
  ACT.GroundMaxX := MaxX;
  ACT.GroundMinZ := MinZ;
  ACT.GroundMaxZ := MaxZ;
  ACT.GroundHasField := True;
end;

function TOsm3dStreamingMap.NearestCurbPoint(WorldX,WorldZ:Single; out P:TVector3):Boolean;
var CT:TCacheTile; I:Integer; V,A,B,C,Normal:TVector3; D,Best:Single;
begin
  Result:=False; P:=Vector3(0,0,0); Best:=Sqr(100.0);
  if FTileIndex=nil then Exit;
  // Diagnostic only: scan the same baked faces used by GroundYAt.
  for CT in FTileIndex.Values do
    if (CT<>nil) and CT.GroundHasField then
      for I:=CT.GroundCurbFirst to Length(CT.GroundIndices) div 3-1 do
      begin
        A:=CT.GroundVertices[CT.GroundIndices[I*3]]; B:=CT.GroundVertices[CT.GroundIndices[I*3+1]]; C:=CT.GroundVertices[CT.GroundIndices[I*3+2]];
        Normal:=TVector3.CrossProduct(B-A,C-A);
        if (Normal.LengthSqr<1e-12) or (Abs(Normal.Y)<0.5*Normal.Length) then Continue;
        V:=(A+B+C)/3;
        V.X:=V.X+CT.CenterX; V.Z:=V.Z+CT.CenterZ;
        D:=Sqr(V.X-WorldX)+Sqr(V.Z-WorldZ);
        if D<Best then begin Best:=D; P:=V; Result:=True end;
      end;
end;

function TOsm3dStreamingMap.CoastalAtStart(const RadiusM:Double):Boolean;
var P,Q:TLatLon;CT:TCacheTile;Box:TLatLonBox;
begin
  P:=FOrigin;if Length(FRoute)>0 then P:=FRoute[0];
  { Exact marine marker survives tile mounting; broad lakes use +1, sea -1. }
  for CT in FTileIndex.Values do if CT.HasMarineWater then begin
    Box:=FCache.Grid.TileBox(CT.Tile);
    Q:=TLatLon.Make(EnsureRange(P.Lat,Box.MinLat,Box.MaxLat),
      EnsureRange(P.Lon,Box.MinLon,Box.MaxLon));
    if P.DistanceTo(Q)<=RadiusM then Exit(True);
  end;
  { Already shipped land mask, also covers coasts outside the loaded ring. }
  Result:=CoarseOceanNear(P,RadiusM);
end;

function TOsm3dStreamingMap.GroundShadowAt(WorldX, WorldZ: Single): Single;
var CT: TCacheTile; Id: TGeoTileId;
begin
  Result := 0;
  if not GroundShadowsActive or (FProj=nil) or (FCache=nil) or
    (FCache.Grid=nil) or (FTileIndex=nil) or (FAsmCache=nil) then Exit;
  Id := FCache.Grid.TileAt(FProj.Unproject(WorldX,WorldZ));
  if not FTileIndex.TryGetValue(Id.ToKey,CT) then Exit;
  if (CT=nil) or (CT.Scene=nil) or not CT.Scene.Exists then Exit;
  Result := FAsmCache.SampleTileGroundShadow(Pointer(CT),CT.MountGen,
    WorldX,WorldZ); { mask window and rendered vertices are in session space }
end;

function TOsm3dStreamingMap.EnvironmentSoundsAt(const P:TVector3):TEnvironmentMix;
var CT:TCacheTile;Mix:TEnvironmentMix;
begin
  Result:=Default(TEnvironmentMix);
  for CT in FTileIndex.Values do if CT.Soundscape<>nil then begin
    Mix:=CT.Soundscape.Sample(P.X-CT.CenterX,P.Y,P.Z-CT.CenterZ);
    MergeEnvironment(Result,Mix);
  end;
end;

destructor TCacheTile.Destroy;
begin
  if (GpuOwner<>nil)and(GpuGround<>nil) then GpuOwner.RemoveTile(GpuGround);
  FreeAndNil(Soundscape);FreeAndNil(GpuGround);inherited;
end;

procedure TOsm3dStreamingMap.RenderGpuGround;
var CT:TCacheTile;
begin
  if FGpuGround=nil then Exit;
  for CT in FTileIndex.Values do if CT.GpuGround<>nil then
    CT.GpuGround.SceneReady:=TileSceneReady(CT.Tile);
  FGpuGround.Render;
end;
function TOsm3dStreamingMap.GrassDiagnostics:string;
begin
  if FGrassRenderer=nil then Result:='grass: unavailable'
  else Result:=FGrassRenderer.DiagString;
end;

function TOsm3dStreamingMap.GpuGroundInfo:string;
begin
  if FGpuGround<>nil then Result:=FGpuGround.Info else Result:='mode=cpu';
end;

procedure TOsm3dStreamingMap.ProbeGpuGround(X,Z,ReferenceY:Single;
  out CpuY,GpuY:Single;out CpuHit,GpuHit:Boolean;QueueGpu:Boolean);
var Id:TGeoTileId;CT:TCacheTile;
begin
  CpuHit:=False;GpuHit:=False;CpuY:=0;GpuY:=0;
  if(FCache=nil)or(FProj=nil)then Exit;
  Id:=FCache.Grid.TileAt(FProj.Unproject(X,Z));
  if not FTileIndex.TryGetValue(Id.ToKey,CT)then Exit;
  if not CT.GroundHasField then Exit;
  if CT.GpuGround<>nil then
    CpuHit:=CT.GpuGround.SampleGeometry(X-CT.CenterX,Z-CT.CenterZ,ReferenceY,CurbContactsEnabled,CpuY)
  else CpuHit:=CT.SampleGround(X-CT.CenterX,Z-CT.CenterZ,ReferenceY,CpuY);
  if QueueGpu and(FGpuGround<>nil) then GpuHit:=FGpuGround.Sample(CT.GpuGround,
    X-CT.CenterX,Z-CT.CenterZ,ReferenceY,CurbContactsEnabled,GpuY,False);
end;

function TOsm3dStreamingMap.GroundLoadStatusAt(WorldX, WorldZ: Single;
  out ErrorText: string; Diagnostics: TJSONObject): string;
var Id:TGeoTileId;CT:TCacheTile;
begin
  Result:='';ErrorText:='';
  if (FProj=nil) or (FCache=nil) or (FCache.Grid=nil) then Exit;
  Id:=FCache.Grid.TileAt(FProj.Unproject(WorldX,WorldZ));
  if FStreamer<>nil then ErrorText:=FStreamer.BlockErrorForTile(Id);
  if (FTileIndex<>nil) and FTileIndex.TryGetValue(Id.ToKey,CT) and
    (CT<>nil) and (CT.Scene<>nil) and CT.Scene.MountFailed then
    ErrorText:=CT.Scene.MountError;
  Result:=LoadPhaseText(Id);
  if Diagnostics<>nil then begin
    Diagnostics.Add('flat_map_visible',(FWarmup<>nil) and FWarmup.Showing);
    if (FWarmup<>nil) and FWarmup.Showing then
      Diagnostics.Add('warmup_tiles',FWarmup.TileCount)
    else Diagnostics.Add('warmup_tiles',0);
    Diagnostics.Add('tile',Id.ToString);
    Diagnostics.Add('pending',PendingTileWork);
    Diagnostics.Add('assembling',InterlockedCompareExchange(FAsmPending,0,0));
    Diagnostics.Add('mounting',InterlockedCompareExchange(FMountPending,0,0));
    Diagnostics.Add('resident',FTileIndex.Count);
    Diagnostics.Add('scene_ready',TileSceneReady(Id));
    if FStreamer<>nil then Diagnostics.Add('streamer',FStreamer.DescribeTile(Id));
    if FTileIndex.TryGetValue(Id.ToKey,CT) and (CT<>nil) then
      Diagnostics.Add('ground_field',CT.GroundHasField);
  end;
end;

function TOsm3dStreamingMap.GroundSceneReadyAt(WorldX, WorldZ: Single): Boolean;
begin
  Result := (FProj <> nil) and (FCache <> nil) and (FCache.Grid <> nil) and
    (FTileIndex <> nil);
  if Result then
    Result := TileSceneReady(FCache.Grid.TileAt(FProj.Unproject(WorldX, WorldZ)));
end;

function TOsm3dStreamingMap.GroundYAt(WorldX, WorldZ: Single;
  out AY: Single): Boolean;
begin
  Result:=GroundNearYAt(WorldX,WorldZ,1e20,AY); { explicit top-surface query }
end;

function TOsm3dStreamingMap.GroundNearYAt(WorldX,WorldZ,ReferenceY:Single;
  out AY:Single):Boolean;
var TileId:TGeoTileId; CT:TCacheTile; GY:Single; GHit:Boolean;
begin
  Result:=False; AY:=0;
  if (FProj=nil) or (FCache=nil) or (FCache.Grid=nil) or (FTileIndex=nil) then Exit;
  TileId:=FCache.Grid.TileAt(FProj.Unproject(WorldX,WorldZ));
  if not FTileIndex.TryGetValue(TileId.ToKey,CT) then Exit;
  if (CT=nil) or not CT.GroundHasField then Exit;
  if (FGpuGround<>nil) and (CT.GpuGround<>nil) then begin
    GHit:=FGpuGround.Sample(CT.GpuGround,WorldX-CT.CenterX,WorldZ-CT.CenterZ,
      ReferenceY,CurbContactsEnabled,GY,GpuGroundMode=ggGpu);
    if GpuGroundMode=ggGpu then begin AY:=GY;Exit(GHit) end;
  end else GHit:=False;
  Result:=CT.SampleGround(WorldX-CT.CenterX,WorldZ-CT.CenterZ,ReferenceY,AY);
  if Result and GHit then FGpuGround.Compare(AY,GY);
end;

function TCacheTile.SampleGround(const LX,LZ,ReferenceY:Single; out AY:Single):Boolean;
var N,GX,GZ,Idx,K,Tri:Integer; A,B,C:TVector3;
  Det,W0,W1,W2,BestY,Tolerance,SampleY,LowestY:Single;
  Found,AnySurface:Boolean;
begin
  Result:=False; AY:=0;
  if (GroundMaxX - GroundMinX < 1.0) or
     (GroundMaxZ - GroundMinZ < 1.0) then Exit;

  N  := GroundGridN;
  GX := Trunc((LX - GroundMinX) / (GroundMaxX - GroundMinX) * N);
  GZ := Trunc((LZ - GroundMinZ) / (GroundMaxZ - GroundMinZ) * N);
  if (GX < 0) or (GX > N - 1) or (GZ < 0) or (GZ > N - 1) then Exit;
  Idx := GZ * N + GX;
  if Idx >= Length(GroundBin) then Exit;

  { Перебрать треугольники ячейки: точка-в-треугольнике в XZ +
    барицентрический Y — ровно та поверхность, по которой проложена
    дорога. На стыках берём ВЕРХНИЙ (максимальный) Y: колёса стоят на
    верхней поверхности и не проваливаются в перекрывающие
    треугольники соседних мешей. }
  Found := False;
  BestY := 0.0;
  LowestY:=1e30; AnySurface:=False;
  for K := 0 to Length(GroundBin[Idx]) - 1 do
  begin
    Tri := GroundBin[Idx][K];
    if (Tri < 0) or (Tri * 3 + 2 >= Length(GroundIndices)) then Continue;
    if (Tri>=GroundCurbFirst) and not CurbContactsEnabled then Continue;
    A := GroundVertices[GroundIndices[Tri * 3    ]];
    B := GroundVertices[GroundIndices[Tri * 3 + 1]];
    C := GroundVertices[GroundIndices[Tri * 3 + 2]];

    { Барицентрические веса в плоскости XZ. }
    Det := (B.Z - C.Z) * (A.X - C.X) + (C.X - B.X) * (A.Z - C.Z);
    if Abs(Det) < 1e-9 then Continue;     { вырожденный треугольник }
    W0 := ((B.Z - C.Z) * (LX - C.X) + (C.X - B.X) * (LZ - C.Z)) / Det;
    W1 := ((C.Z - A.Z) * (LX - C.X) + (A.X - C.X) * (LZ - C.Z)) / Det;
    W2 := 1.0 - W0 - W1;

    { Точка вне треугольника — небольшой допуск на швы. }
    if Tri>=GroundCurbFirst then Tolerance:=0.00001 else Tolerance:=0.001;
    if (W0 < -Tolerance) or (W1 < -Tolerance) or (W2 < -Tolerance) then Continue;

    SampleY:=A.Y*W0+B.Y*W1+C.Y*W2;
    if (not AnySurface) or (SampleY<LowestY) then LowestY:=SampleY;
    AnySurface:=True;
    // Highest reachable floor: curbs remain solid, upper decks/terrain do
    // not steal contact from a rider already travelling underneath them.
    if (SampleY<=ReferenceY+0.75) and ((not Found) or (SampleY>BestY)) then
    begin BestY:=SampleY; Found:=True end;
  end;

  if not AnySurface then Exit;
  if Found then AY:=BestY else AY:=LowestY;
  Result:=True;
end;

function TOsm3dStreamingMap.GroundNearYCorrAt(WorldX,WorldZ,ReferenceY:Single;
  out AY:Single):Boolean;
var LL:TLatLon;
begin
  Result:=GroundNearYAt(WorldX,WorldZ,ReferenceY,AY);
  if Result and (FFitPhysLayer<>nil) and FFitPhysLayer.Active then
  begin
    LL:=FProj.Unproject(WorldX,WorldZ);
    AY:=FFitPhysLayer.CorrectHeightGeo(LL,AY);
  end;
end;

function TOsm3dStreamingMap.GroundYCorrAt(WorldX,WorldZ:Single; out AY:Single):Boolean;
begin
  Result:=GroundNearYCorrAt(WorldX,WorldZ,1e20,AY);
end;

{ BUILDING_OBSTACLE ─────────────────────────────────────────────────────── }

function TOsm3dStreamingMap.BuildingFootprintsNear(WorldX, WorldZ, Radius: Single): TBuildingObstacleArray;
begin
  Result:=nil;
  if FBuildingObstacles<>nil then Result:=FBuildingObstacles.SnapshotNear(WorldX,WorldZ,Radius);
end;

function TOsm3dStreamingMap.BuildingQuery(WorldX, WorldZ: Single;
  out ABaseY, AMaxY: Single): Boolean;
begin
  ABaseY := 0; AMaxY := 0;
  if FBuildingObstacles = nil then Exit(False);
  Result := FBuildingObstacles.TryQuery(WorldX, WorldZ, ABaseY, AMaxY);
end;

function TOsm3dStreamingMap.BuildingPushOutXZ(var WorldX, WorldZ: Single;
  out ABaseY, AMaxY: Single): Boolean;
begin
  ABaseY := 0; AMaxY := 0;
  if FBuildingObstacles = nil then Exit(False);
  Result := FBuildingObstacles.TryPushOutXZ(WorldX, WorldZ, ABaseY, AMaxY);
end;

function TOsm3dStreamingMap.BuildingBodyMove(const From,Forward,HalfSize:TVector3;
  var Target:TVector3):Boolean;
begin
  if FBuildingObstacles=nil then Exit(False);
  Result:=FBuildingObstacles.ConstrainBoxMove(From,Forward,HalfSize,Target);
end;

function TOsm3dStreamingMap.ResolveCameraBuilding(var Cam: TVector3): Boolean;
begin
  if FBuildingObstacles = nil then Exit(False);
  Result := FBuildingObstacles.ResolveCamera(Cam);
end;

procedure TOsm3dStreamingMap.CaptureRouteGroundY(
  const AModels: array of TTileModel; const AIds: array of TGeoTileId;
  const ARoute: TRouteLatLonArray; const AWays: TRouteWayIdArray;
  var AYArr: TRouteAltArray);
const
  GROUND_KINDS = [smkTerrain, smkGrass, smkSurface, smkSand,
                  smkFarmland, smkForest];
  ROAD_KINDS = [smkRoad, smkRoadMajor, smkRoadSecondary, smkRoadMinor,
                smkRoadService, smkRoadFootway, smkRoadCycleway];
  { Normal (non-bridge-path): short radius, prefer nearest surface so a
    cross-road UNDER the span is not lifted onto the deck above. }
  LOCAL_R2 = 12.0 * 12.0;
  { Bridge-path only: reach deck / ramps from offset GPS. }
  ROAD_R2  = 30.0 * 30.0;
  WAY_R2   = 48.0 * 48.0;
  { Sample deck at bridge centerline foot — approaches sit low on ground
    mesh while deck slab is only ~10–50 m ahead; pull Y up to that slab. }
  FOOT_R2  = 28.0 * 28.0;
  BRIDGE_CLEAR_M = 1.5;
  { Path-on-bridge mask: near centerline + parallel heading, or IsBridge
    way, then dilate along route for approaches/exits. Cross under-road
    is near but NOT parallel → stays off the mask. }
  BRIDGE_NEAR_M        = 22.0;
  BRIDGE_PARALLEL_DEG  = 40.0;
  BRIDGE_PATH_HOLD_M   = 120.0;
var
  I, J, MeshI, V, TI, SS, K: Integer;
  Ctr, WP: TVector3;
  Kx: Double;
  Msh: TMesh;
  MV: TMeshVertexArray;
  D2, D2f, LX, LZ, FLX, FLZ: Single;
  TerrainY, RoadY, WayY, DeckY, FootY, BestY, NearD: Single;
  DeckTileMax, BlendY, W: Single;
  HaveTerrain, HaveRoad, HaveWay, HaveDeck, HaveFoot, UseWay: Boolean;
  HaveDeckTile: Boolean;
  WantWay: Int64;
  Mat: TSceneMaterialKind;
  IsGround, IsRoad, OnBridgePath: Boolean;
  OnBridge: array of Boolean;
  Core: array of Boolean;
  Cum: array of Single;
  BrWays: specialize TDictionary<Int64, Boolean>;
  BrWayIds: array of Int64;
  BrX0, BrZ0, BrX1, BrZ1: array of Single;
  BrN, BrCap, BrWayN: Integer;
  PX, PZ, TX, TZ, BDX, BDZ, LenB, Dist, Tt, Qx, Qz, La, Lb, CosA, Ang: Single;
  Near, Parallel, WayIsBr, IsBrWayVert: Boolean;
  SSegs: TTileRoadSegArray;
  SOrigin: TLatLon;
  MM: TTileModel;
  HoldL, HoldR: Single;
  BestD2: Single;
  ClosestY: Single;
  HaveClosest: Boolean;
  Pair: specialize TPair<Int64, Boolean>;
  FootX, FootZ, BestBrDist: Single;
  HaveFootXZ: Boolean;

  procedure AddBrSeg(AX0, AZ0, AX1, AZ1: Single; AWay: Int64; AIsBr: Boolean);
  begin
    if AIsBr then
    begin
      if BrN >= BrCap then
      begin
        BrCap := BrCap * 2 + 32;
        SetLength(BrX0, BrCap); SetLength(BrZ0, BrCap);
        SetLength(BrX1, BrCap); SetLength(BrZ1, BrCap);
      end;
      BrX0[BrN] := AX0; BrZ0[BrN] := AZ0;
      BrX1[BrN] := AX1; BrZ1[BrN] := AZ1;
      Inc(BrN);
    end;
    if AIsBr and (AWay <> 0) then
      BrWays.AddOrSetValue(AWay, True);
  end;

  function OsmIdIsBridgeWay(AId: Int64): Boolean;
  var
    Bi: Integer;
  begin
    Result := False;
    if AId = 0 then Exit;
    for Bi := 0 to BrWayN - 1 do
      if BrWayIds[Bi] = AId then Exit(True);
  end;

  procedure HarvestBridgeFromTile(const Tid: TGeoTileId);
  var
    CtrW: TVector3;
    Si: Integer;
    RS: TTileRoadSeg;
    ScaleX: Double;
  begin
    SSegs := nil;
    ScaleX := TileScaleX(Tid);
    if FCache.TryLoadRoadSegs(Tid, SSegs, SOrigin) then
    begin
      CtrW := FProj.Project(SOrigin, 0);
      for Si := 0 to High(SSegs) do
      begin
        RS := RoadSegmentToFrame(SSegs[Si], CtrW, ScaleX);
        AddBrSeg(RS.X0, RS.Z0, RS.X1, RS.Z1, RS.WayId, RS.IsBridge);
      end;
      Exit;
    end;
    MM := nil;
    if not (FCache.TryLoad(Tid, MM) and (MM <> nil)) then Exit;
    try
      CtrW := FProj.Project(MM.Origin, 0);
      for Si := 0 to MM.RoadSegCount - 1 do
      begin
        RS := RoadSegmentToFrame(MM.RoadSegs[Si], CtrW, ScaleX);
        AddBrSeg(RS.X0, RS.Z0, RS.X1, RS.Z1, RS.WayId, RS.IsBridge);
      end;
    finally
      MM.Free;
    end;
  end;

  function UndirAngDeg(AX, AZ, BX, BZ: Single): Single;
  begin
    La := Sqrt(AX * AX + AZ * AZ);
    Lb := Sqrt(BX * BX + BZ * BZ);
    if (La < 1e-6) or (Lb < 1e-6) then Exit(90);
    CosA := (AX * BX + AZ * BZ) / (La * Lb);
    if CosA < 0 then CosA := -CosA;
    if CosA > 1 then CosA := 1;
    Result := RadToDeg(ArcCos(CosA));
  end;

begin
  if Length(ARoute) = 0 then Exit;
  if Length(AYArr) <> Length(ARoute) then
  begin
    SetLength(AYArr, Length(ARoute));
    for I := 0 to High(AYArr) do AYArr[I] := SPHERE_Y_NONE;
  end;
  UseWay := Length(AWays) = Length(ARoute);

  { ── Mask: which route points are ON the bridge path (not under-cross) ── }
  SetLength(OnBridge, Length(ARoute));
  SetLength(Core, Length(ARoute));
  SetLength(Cum, Length(ARoute));
  for I := 0 to High(ARoute) do
  begin
    OnBridge[I] := False;
    Core[I] := False;
  end;
  Cum[0] := 0;
  for I := 1 to High(ARoute) do
  begin
    WP := FProj.Project(ARoute[I], 0);
    Ctr := FProj.Project(ARoute[I - 1], 0);
    Cum[I] := Cum[I - 1] + Sqrt(Sqr(WP.X - Ctr.X) + Sqr(WP.Z - Ctr.Z));
  end;

  BrWays := specialize TDictionary<Int64, Boolean>.Create;
  BrN := 0; BrCap := 0;
  try
    if Length(FSnapForceTiles) > 0 then
      for TI := 0 to High(FSnapForceTiles) do
        HarvestBridgeFromTile(FSnapForceTiles[TI])
    else
      for TI := 0 to High(AIds) do
        HarvestBridgeFromTile(AIds[TI]);

    for I := 0 to High(ARoute) do
    begin
      WP := FProj.Project(ARoute[I], 0);
      PX := WP.X; PZ := WP.Z;
      { Route tangent (2-point). }
      if I < High(ARoute) then
      begin
        Ctr := FProj.Project(ARoute[I + 1], 0);
        TX := Ctr.X - PX; TZ := Ctr.Z - PZ;
      end
      else if I > 0 then
      begin
        Ctr := FProj.Project(ARoute[I - 1], 0);
        TX := PX - Ctr.X; TZ := PZ - Ctr.Z;
      end
      else
      begin
        TX := 0; TZ := 1;
      end;

      Near := False; Parallel := False; NearD := 1e9;
      for K := 0 to BrN - 1 do
      begin
        BDX := BrX1[K] - BrX0[K]; BDZ := BrZ1[K] - BrZ0[K];
        LenB := BDX * BDX + BDZ * BDZ;
        if LenB < 1e-4 then Continue;
        Tt := ((PX - BrX0[K]) * BDX + (PZ - BrZ0[K]) * BDZ) / LenB;
        if Tt < 0 then Tt := 0 else if Tt > 1 then Tt := 1;
        Qx := BrX0[K] + Tt * BDX; Qz := BrZ0[K] + Tt * BDZ;
        Dist := Sqrt(Sqr(PX - Qx) + Sqr(PZ - Qz));
        if Dist < NearD then
        begin
          NearD := Dist;
          Ang := UndirAngDeg(TX, TZ, BDX, BDZ);
          Near := Dist <= BRIDGE_NEAR_M;
          Parallel := Ang <= BRIDGE_PARALLEL_DEG;
        end
        else if Dist <= BRIDGE_NEAR_M then
        begin
          Near := True;
          if UndirAngDeg(TX, TZ, BDX, BDZ) <= BRIDGE_PARALLEL_DEG then
            Parallel := True;
        end;
      end;

      WayIsBr := False;
      if UseWay and (AWays[I] <> 0) then
        WayIsBr := BrWays.ContainsKey(AWays[I]);

      { Core: on deck way, or near deck centerline with parallel heading.
        Cross under-road: near but NOT parallel → Core=False. }
      Core[I] := WayIsBr or (Near and Parallel);
    end;

    { Dilate along route: approaches / exits continue the bridge path. }
    for I := 0 to High(ARoute) do
      if Core[I] then
      begin
        OnBridge[I] := True;
        HoldL := Cum[I] - BRIDGE_PATH_HOLD_M;
        HoldR := Cum[I] + BRIDGE_PATH_HOLD_M;
        for J := I - 1 downto 0 do
        begin
          if Cum[J] < HoldL then Break;
          OnBridge[J] := True;
        end;
        for J := I + 1 to High(ARoute) do
        begin
          if Cum[J] > HoldR then Break;
          OnBridge[J] := True;
        end;
      end;

    { Freeze bridge way ids for mesh OsmId tests (dict freed below). }
    BrWayN := BrWays.Count;
    SetLength(BrWayIds, BrWayN);
    K := 0;
    for Pair in BrWays do
    begin
      if K < BrWayN then
      begin
        BrWayIds[K] := Pair.Key;
        Inc(K);
      end;
    end;
    BrWayN := K;
  finally
    BrWays.Free;
  end;

  { ── Sample mesh heights per tile / point ──
    Deck max for approach blend comes from (a) local tile mesh and
    (b) FBridgeDeckYMax accumulated across one-tile-at-a-time captures.
    Callers that need approaches correct must run Capture twice after the
    deck tile has been seen (DumpRouteArraysJSON / SetFitPointOverlays). }
  for J := 0 to High(AModels) do
  begin
    if AModels[J] = nil then Continue;
    Ctr := FProj.Project(FCache.Grid.TileCenter(AIds[J]), 0);
    Kx := TileScaleX(AModels[J].TileId);

    { Max deck slab Y in this tile → also feeds FBridgeDeckYMax. }
    DeckTileMax := SPHERE_Y_NONE;
    HaveDeckTile := False;
    for MeshI := 0 to AModels[J].MeshCount - 1 do
    begin
      Mat := AModels[J].Meshes[MeshI].Material;
      if not (Mat in ROAD_KINDS) then Continue;
      Msh := AModels[J].Meshes[MeshI].Mesh;
      if Msh = nil then Continue;
      MV := Msh.Vertices;
      for V := 0 to Msh.VertexCount - 1 do
      begin
        if OsmIdIsBridgeWay(MV[V].OsmId) then
        begin
          if (not HaveDeckTile) or (MV[V].Position.Y > DeckTileMax) then
          begin
            DeckTileMax := MV[V].Position.Y;
            HaveDeckTile := True;
          end;
          Continue;
        end;
        if BrN > 0 then
        begin
          PX := MV[V].Position.X * Kx + Ctr.X;
          PZ := MV[V].Position.Z + Ctr.Z;
          for K := 0 to BrN - 1 do
          begin
            BDX := BrX1[K] - BrX0[K]; BDZ := BrZ1[K] - BrZ0[K];
            LenB := BDX * BDX + BDZ * BDZ;
            if LenB < 1e-4 then Continue;
            Tt := ((PX - BrX0[K]) * BDX + (PZ - BrZ0[K]) * BDZ) / LenB;
            if Tt < 0 then Tt := 0 else if Tt > 1 then Tt := 1;
            Qx := BrX0[K] + Tt * BDX; Qz := BrZ0[K] + Tt * BDZ;
            if Sqr(PX - Qx) + Sqr(PZ - Qz) <= Sqr(18.0) then
            begin
              if (not HaveDeckTile) or (MV[V].Position.Y > DeckTileMax) then
              begin
                DeckTileMax := MV[V].Position.Y;
                HaveDeckTile := True;
              end;
              Break;
            end;
          end;
        end;
      end;
    end;
    if HaveDeckTile then
    begin
      if (FBridgeDeckYMax = SPHERE_Y_NONE) or (DeckTileMax > FBridgeDeckYMax) then
        FBridgeDeckYMax := DeckTileMax;
    end;
    { Prefer corridor-wide max so approach tiles can blend on pass 2. }
    if (FBridgeDeckYMax <> SPHERE_Y_NONE) and
       ((not HaveDeckTile) or (FBridgeDeckYMax > DeckTileMax)) then
    begin
      DeckTileMax := FBridgeDeckYMax;
      HaveDeckTile := True;
    end;

    for I := 0 to High(ARoute) do
    begin
      if not FCache.Grid.TileAt(ARoute[I]).Equals(AIds[J]) then Continue;
      WP := FProj.Project(ARoute[I], 0);
      LX := WP.X - Ctr.X;
      LZ := WP.Z - Ctr.Z;
      OnBridgePath := OnBridge[I];
      HaveTerrain := False; TerrainY := 0;
      HaveRoad    := False; RoadY    := 0;
      HaveWay     := False; WayY     := 0;
      HaveDeck    := False; DeckY    := 0;
      HaveFoot    := False; FootY    := 0;
      HaveClosest := False; ClosestY := 0; BestD2 := 1e30;
      WantWay := 0;
      if UseWay then WantWay := AWays[I];

      { Nearest bridge centerline foot (world → tile-local) for ramp Y. }
      HaveFootXZ := False; FootX := 0; FootZ := 0; BestBrDist := 1e9;
      if OnBridgePath and (BrN > 0) then
      begin
        PX := WP.X; PZ := WP.Z;
        for K := 0 to BrN - 1 do
        begin
          BDX := BrX1[K] - BrX0[K]; BDZ := BrZ1[K] - BrZ0[K];
          LenB := BDX * BDX + BDZ * BDZ;
          if LenB < 1e-4 then Continue;
          Tt := ((PX - BrX0[K]) * BDX + (PZ - BrZ0[K]) * BDZ) / LenB;
          if Tt < 0 then Tt := 0 else if Tt > 1 then Tt := 1;
          Qx := BrX0[K] + Tt * BDX; Qz := BrZ0[K] + Tt * BDZ;
          Dist := Sqrt(Sqr(PX - Qx) + Sqr(PZ - Qz));
          if Dist < BestBrDist then
          begin
            BestBrDist := Dist;
            FootX := Qx; FootZ := Qz;
            HaveFootXZ := True;
          end;
        end;
        if HaveFootXZ then
        begin
          FLX := FootX - Ctr.X;
          FLZ := FootZ - Ctr.Z;
        end;
      end;

      for MeshI := 0 to AModels[J].MeshCount - 1 do
      begin
        Mat := AModels[J].Meshes[MeshI].Material;
        IsGround := Mat in GROUND_KINDS;
        IsRoad   := Mat in ROAD_KINDS;
        if (not IsGround) and (not IsRoad) then Continue;
        Msh := AModels[J].Meshes[MeshI].Mesh;
        if Msh = nil then Continue;
        MV := Msh.Vertices;
        for V := 0 to Msh.VertexCount - 1 do
        begin
          D2 := Sqr(MV[V].Position.X * Kx - LX) + Sqr(MV[V].Position.Z - LZ);

          { Closest surface (any ground/road) — used for under-cross path. }
          if D2 <= LOCAL_R2 then
            if (not HaveClosest) or (D2 < BestD2) then
            begin
              BestD2 := D2;
              ClosestY := MV[V].Position.Y;
              HaveClosest := True;
            end;

          if IsGround and (D2 <= LOCAL_R2) then
            if (not HaveTerrain) or (MV[V].Position.Y > TerrainY) then
            begin
              TerrainY := MV[V].Position.Y;
              HaveTerrain := True;
            end;

          if IsRoad and (D2 <= LOCAL_R2) then
            if (not HaveTerrain) or (MV[V].Position.Y > TerrainY) then
            begin
              TerrainY := MV[V].Position.Y;
              HaveTerrain := True;
            end;

          if OnBridgePath and IsRoad and (D2 <= ROAD_R2) then
            if (not HaveRoad) or (MV[V].Position.Y > RoadY) then
            begin
              RoadY := MV[V].Position.Y;
              HaveRoad := True;
            end;

          if (WantWay <> 0) and (MV[V].OsmId = WantWay) then
          begin
            if OnBridgePath and (D2 <= WAY_R2) then
            begin
              if (not HaveWay) or (MV[V].Position.Y > WayY) then
              begin
                WayY := MV[V].Position.Y;
                HaveWay := True;
              end;
            end
            else if (not OnBridgePath) and (D2 <= LOCAL_R2) then
            begin
              if (not HaveWay) or (MV[V].Position.Y > WayY) then
              begin
                WayY := MV[V].Position.Y;
                HaveWay := True;
              end;
            end;
          end;

          { Bridge-way OsmId near path point → deck/ramp sample. }
          if OnBridgePath and IsRoad and (D2 <= WAY_R2) then
          begin
            IsBrWayVert := OsmIdIsBridgeWay(MV[V].OsmId);
            if IsBrWayVert then
              if (not HaveDeck) or (MV[V].Position.Y > DeckY) then
              begin
                DeckY := MV[V].Position.Y;
                HaveDeck := True;
              end;
          end;

          { APPROACH/EXIT: max Y of road/deck mesh near the *bridge foot*
            (not only near GPS). Fixes spheres stuck on ground under ramps
            while the slab is 10–40 m ahead on the same path. }
          if OnBridgePath and HaveFootXZ and IsRoad then
          begin
            D2f := Sqr(MV[V].Position.X * Kx - FLX) + Sqr(MV[V].Position.Z - FLZ);
            if D2f <= FOOT_R2 then
              if (not HaveFoot) or (MV[V].Position.Y > FootY) then
              begin
                FootY := MV[V].Position.Y;
                HaveFoot := True;
              end;
          end;
        end;
      end;

      if OnBridgePath then
      begin
        { Path on bridge / approach / exit: prefer elevated deck & foot
          slab over ground under the ramp. }
        BestY := SPHERE_Y_NONE;
        if HaveWay then BestY := WayY;
        if HaveDeck and ((BestY = SPHERE_Y_NONE) or (DeckY > BestY)) then
          BestY := DeckY;
        if HaveFoot and ((BestY = SPHERE_Y_NONE) or (FootY > BestY)) then
          BestY := FootY;
        if HaveRoad and ((BestY = SPHERE_Y_NONE) or (RoadY > BestY)) then
          BestY := RoadY;
        if HaveTerrain then
        begin
          if not (HaveRoad and (RoadY >= TerrainY + BRIDGE_CLEAR_M)) and
             not (HaveDeck and (DeckY >= TerrainY + BRIDGE_CLEAR_M)) and
             not (HaveFoot and (FootY >= TerrainY + BRIDGE_CLEAR_M)) and
             not (HaveWay and (WayY >= TerrainY + BRIDGE_CLEAR_M)) then
            if (BestY = SPHERE_Y_NONE) or (TerrainY > BestY) then
              BestY := TerrainY;
        end;
        { Approach holes are fixed after full-corridor capture by
          LiftBridgeApproachY (needs deck samples already in AYArr). }
        if BestY <> SPHERE_Y_NONE then
          AYArr[I] := BestY;
      end
      else
      begin
        { Not bridge-path (incl. cross-road under span): stay on the
          path surface — prefer snapped way / closest vertex, never
          max-elevate onto the deck above. }
        if HaveWay then
          AYArr[I] := WayY
        else if HaveClosest then
          AYArr[I] := ClosestY
        else if HaveTerrain then
          AYArr[I] := TerrainY;
      end;
    end;
  end;
end;

procedure TOsm3dStreamingMap.LiftBridgeApproachY(
  const ARoute: TRouteLatLonArray; var AYArr: TRouteAltArray);
{ One-shot after full-corridor capture: raise approach/EXIT holes toward
  the nearest flat elevated plateau (bridge deck).
  - Ahead: N-ramp into the span.
  - Behind: S-exit off the span (was left at ground ~167–169).
  First plateau with ≥3 samples within 0.5 m wins; +1.5..+20 m only. }
const
  HOLD_M = 120.0;
  CLEAR_M = 1.5;
  MAX_LIFT_M = 20.0;
  HARD_M = 80.0;
  PLATEAU_EPS = 0.5;
  PLATEAU_MIN = 3;
var
  I, J, K, N, PlateauN: Integer;
  Cum: array of Single;
  OrigY: array of Single;
  WP, Ctr: TVector3;
  BestY, ElevY, DistElev, BlendY, W, CandY, D: Single;

  procedure TryRaiseToward(AElev, ADist: Single);
  begin
    if AElev < BestY + CLEAR_M then Exit;
    if ADist >= HOLD_M then Exit;
    { Prefer higher plateau (deck 173 over undulation 170); tie → nearer. }
    if (ElevY < BestY + CLEAR_M) or (AElev > ElevY + PLATEAU_EPS) or
       ((Abs(AElev - ElevY) <= PLATEAU_EPS) and (ADist < DistElev)) then
    begin
      ElevY := AElev;
      DistElev := ADist;
    end;
  end;

begin
  N := Length(ARoute);
  if (N = 0) or (Length(AYArr) < N) then Exit;
  { Snapshot mesh Y so lifts do not cascade along the exit. }
  SetLength(OrigY, N);
  for I := 0 to N - 1 do
    OrigY[I] := AYArr[I];
  SetLength(Cum, N);
  Cum[0] := 0;
  for I := 1 to N - 1 do
  begin
    WP := FProj.Project(ARoute[I], 0);
    Ctr := FProj.Project(ARoute[I - 1], 0);
    Cum[I] := Cum[I - 1] + Sqrt(Sqr(WP.X - Ctr.X) + Sqr(WP.Z - Ctr.Z));
  end;
  for I := 0 to N - 1 do
  begin
    if OrigY[I] = SPHERE_Y_NONE then Continue;
    BestY := OrigY[I];
    ElevY := BestY;
    DistElev := 1e9;

    { ── AHEAD: approach into deck ── }
    for J := I + 1 to N - 1 do
    begin
      D := Cum[J] - Cum[I];
      if D > HOLD_M then Break;
      if OrigY[J] = SPHERE_Y_NONE then Continue;
      CandY := OrigY[J];
      if (CandY < BestY + CLEAR_M) or (CandY > BestY + MAX_LIFT_M) then
        Continue;
      PlateauN := 0;
      for K := I + 1 to N - 1 do
      begin
        if Cum[K] - Cum[I] > HOLD_M then Break;
        if OrigY[K] = SPHERE_Y_NONE then Continue;
        if Abs(OrigY[K] - CandY) <= PLATEAU_EPS then
          Inc(PlateauN);
      end;
      if PlateauN < PLATEAU_MIN then Continue;
      TryRaiseToward(CandY, D);
    end;

    { ── BEHIND: exit off deck ── }
    for J := I - 1 downto 0 do
    begin
      D := Cum[I] - Cum[J];
      if D > HOLD_M then Break;
      if OrigY[J] = SPHERE_Y_NONE then Continue;
      CandY := OrigY[J];
      if (CandY < BestY + CLEAR_M) or (CandY > BestY + MAX_LIFT_M) then
        Continue;
      PlateauN := 0;
      for K := I - 1 downto 0 do
      begin
        if Cum[I] - Cum[K] > HOLD_M then Break;
        if OrigY[K] = SPHERE_Y_NONE then Continue;
        if Abs(OrigY[K] - CandY) <= PLATEAU_EPS then
          Inc(PlateauN);
      end;
      if PlateauN < PLATEAU_MIN then Continue;
      TryRaiseToward(CandY, D);
    end;

    if ElevY < BestY + CLEAR_M then Continue;
    if DistElev >= HOLD_M then Continue;
    if DistElev <= HARD_M then
      AYArr[I] := ElevY
    else
    begin
      W := 1.0 - DistElev / HOLD_M;
      if W < 0 then W := 0 else if W > 1 then W := 1;
      BlendY := BestY * (1.0 - W) + ElevY * W;
      if BlendY > BestY then
        AYArr[I] := BlendY;
    end;
  end;
end;

procedure TOsm3dStreamingMap.CaptureRawGroundY(
  const AModels: array of TTileModel; const AIds: array of TGeoTileId);
var
  RedWays: TRouteWayIdArray;
begin
  { Красные: сырой FIT XZ, но Y — с мостов/заездов/съездов (не река под
    пролётом). Если снап готов, AWays=FRouteWays даёт OsmId настила. }
  if FShowFitPoints and (Length(FRoute) > 0) then
  begin
    RedWays := nil;
    if FSnappedReady and (Length(FRouteWays) = Length(FRoute)) then
      RedWays := FRouteWays;
    CaptureRouteGroundY(AModels, AIds, FRoute, RedWays, FRouteGroundRaw);
    MarkSphereDirty(0);
  end;
  { Зелёные «снап» — высота настила/дороги под снапнутой точкой, как только
    снап готов и зелёный оверлей включён. Тот же инкрементальный захват. }
  if FShowFitPointsSnapped and FSnappedReady and (Length(FRouteSnapped) > 0) then
  begin
    CaptureRouteGroundY(AModels, AIds, FRouteSnapped, FRouteWays, FRouteSnappedY);
    MarkSphereDirty(3);
  end;
end;

procedure TOsm3dStreamingMap.BuildSphereTemplate;
{ Один низкополигональный шаблон сферы (радиус FIT_SPHERE_RADIUS_M), из
  которого штампуются ВСЕ маркеры. Сетка (Stacks+1)×(Slices+1) вершин,
  квадные грани (-1-терминатор) как у меша земли; вырожденные квады у
  полюсов безвредны (нулевая площадь). Строится один раз (ленивый гард). }
var
  St, Sl, Vi, K, Nst, Nsl: Integer;
  Phi, Theta, Yy, Rr: Single;
begin
  if Length(FSphTplV) > 0 then Exit;
  Nst := FIT_SPHERE_STACKS;   { широтные пояса }
  Nsl := FIT_SPHERE_SLICES;   { долготные сегменты }
  SetLength(FSphTplV, (Nst + 1) * (Nsl + 1));
  for St := 0 to Nst do
  begin
    Phi := Pi * St / Nst;                        { 0 (сев. полюс)..Pi (юж.) }
    Yy  := FIT_SPHERE_RADIUS_M * Cos(Phi);
    Rr  := FIT_SPHERE_RADIUS_M * Sin(Phi);
    for Sl := 0 to Nsl do
    begin
      Theta := 2.0 * Pi * Sl / Nsl;
      FSphTplV[St * (Nsl + 1) + Sl] :=
        Vector3(Rr * Cos(Theta), Yy, Rr * Sin(Theta));
    end;
  end;
  SetLength(FSphTplIdx, Nst * Nsl * 5);
  K := 0;
  for St := 0 to Nst - 1 do
    for Sl := 0 to Nsl - 1 do
    begin
      Vi := St * (Nsl + 1) + Sl;
      FSphTplIdx[K]     := Vi;
      FSphTplIdx[K + 1] := Vi + 1;
      FSphTplIdx[K + 2] := Vi + (Nsl + 1) + 1;
      FSphTplIdx[K + 3] := Vi + (Nsl + 1);
      FSphTplIdx[K + 4] := -1;
      Inc(K, 5);
    end;
end;

procedure TOsm3dStreamingMap.FreeSphereSlot(AIdx: Integer);
begin
  if (AIdx < 0) or (AIdx > High(FSphereScene)) then Exit;
  if FSphereScene[AIdx] <> nil then
  begin
    Remove(FSphereScene[AIdx]);          { снять с карты-трансформа }
    FreeAndNil(FSphereScene[AIdx]);      { Owner=nil — освобождаем сами }
  end;
end;

procedure TOsm3dStreamingMap.FreeSphereScenes;
var I: Integer;
begin
  for I := 0 to High(FSphereScene) do FreeSphereSlot(I);
end;

procedure TOsm3dStreamingMap.MarkSphereDirty(AIdx: Integer);
begin
  if (AIdx >= 0) and (AIdx <= High(FSphereDirty)) then
    FSphereDirty[AIdx] := True;
end;

function TOsm3dStreamingMap.FitPointOverlaysOn: Boolean;
begin
  Result := FShowFitPoints or FShowFitPointsSnapped;
end;

procedure TOsm3dStreamingMap.SetFitPointOverlays(AOn: Boolean);
{ Debug toggle: show/hide red/blue/cyan/green FIT path spheres.
  When enabling late, re-sample Y from every resident tile (one hitch OK
  for a debug control) so spheres appear without remounting the map. }
var
  B, I: Integer;
  CT: TCacheTile;
  M: TTileModel;
  MArr: array[0..0] of TTileModel;
  IArr: array[0..0] of TGeoTileId;
begin
  if FDestroying then Exit;
  FShowFitPoints        := AOn;
  FShowFitPointsSnapped := AOn;
  if not AOn then
  begin
    FGreenRetrofit := False;
    FreeSphereScenes;
    Exit;
  end;

  { Capture heights for the WHOLE snap corridor (disk cache), not only
    tiles currently resident near the camera — otherwise Path spheres
    only appear near the avatar. }
  if Length(FSnapForceTiles) > 0 then
  begin
    for I := 0 to High(FSnapForceTiles) do
    begin
      M := nil;
      if FCache.TryLoad(FSnapForceTiles[I], M) and (M <> nil) then
      try
        MArr[0] := M;
        IArr[0] := FSnapForceTiles[I];
        if Length(FRoute) > 0 then
        begin
          if FSnappedReady and (Length(FRouteWays) = Length(FRoute)) then
            CaptureRouteGroundY(MArr, IArr, FRoute, FRouteWays, FRouteGroundRaw)
          else
            CaptureRouteGroundY(MArr, IArr, FRoute, nil, FRouteGroundRaw);
        end;
        if FSnappedReady and (Length(FRouteSnapped) > 0) then
          CaptureRouteGroundY(MArr, IArr, FRouteSnapped, FRouteWays,
            FRouteSnappedY);
      finally
        M.Free;
      end;
    end;
  end
  else
  begin
    for B := 0 to FBatchList.Count - 1 do
    begin
      if (FBatchList[B] = nil) or (FBatchList[B].Tiles = nil) then Continue;
      for I := 0 to FBatchList[B].Tiles.Count - 1 do
      begin
        CT := FBatchList[B].Tiles[I];
        if CT = nil then Continue;
        M := nil;
        if FCache.TryLoad(CT.Tile, M) and (M <> nil) then
        try
          MArr[0] := M;
          IArr[0] := CT.Tile;
          if Length(FRoute) > 0 then
          begin
            if FSnappedReady and (Length(FRouteWays) = Length(FRoute)) then
              CaptureRouteGroundY(MArr, IArr, FRoute, FRouteWays, FRouteGroundRaw)
            else
              CaptureRouteGroundY(MArr, IArr, FRoute, nil, FRouteGroundRaw);
          end;
          if FSnappedReady and (Length(FRouteSnapped) > 0) then
          begin
            CaptureRouteGroundY(MArr, IArr, FRouteSnapped, FRouteWays,
              FRouteSnappedY);
            CT.GreenMounted := True;
          end;
        finally
          M.Free;
        end;
      end;
    end;
  end;
  if Length(FRouteSnapped) > 0 then
    LiftBridgeApproachY(FRouteSnapped, FRouteSnappedY);
  if Length(FRoute) > 0 then
    LiftBridgeApproachY(FRoute, FRouteGroundRaw);
  FGreenRetrofit := False;
  MarkSphereDirty(0);
  MarkSphereDirty(1);
  MarkSphereDirty(2);
  MarkSphereDirty(3);
end;

function TOsm3dStreamingMap.AnalyzeSnapPathJSON(ARefreshY: Boolean;
  ABridgeClearM: Single): string;
{ MCP path.snap_analyze: green spheres vs bridges / approaches.
  Keeps JSON small (summary + issue samples only) for MCP timeout. }
const
  MISSING_Y = SPHERE_Y_NONE * 0.5;
  BRIDGE_SEG_NEAR_M = 25.0;
  MAX_SAMPLES = 80;
type
  TBrSeg = record
    X0, Z0, X1, Z1: Single;
  end;
var
  SB: TStringBuilder;
  I, N, MissY, UnderSurf, WayFlip, BridgeLike, NearBridgeSeg, Issues: Integer;
  HaveYCnt, SampleN: Integer;
  GX, GY, Clearance, Cum, DLat, DLon, BestSegD, Dist: Single;
  W, PrevW: Int64;
  WP: TVector3;
  HaveG, OnBridgeSeg, FirstSample, NeedSample: Boolean;
  B, TI, S, BrN: Integer;
  CT: TCacheTile;
  M: TTileModel;
  MArr: array[0..0] of TTileModel;
  IArr: array[0..0] of TGeoTileId;
  SideSegs: TTileRoadSegArray;
  SideOrigin: TLatLon;
  HCtr: TVector3;
  BrSegs: array of TBrSeg;
  FS: TFormatSettings;
  LoadedTiles: Integer;

  function ValidY(Y: Single): Boolean;
  begin
    Result := Y > MISSING_Y;
  end;

  function JBool(B: Boolean): string;
  begin
    if B then Result := 'true' else Result := 'false';
  end;

  function DistToSegXZ(PX, PZ, AX, AZ, BX, BZ: Single): Single;
  var
    ABx, ABz, APx, APz, Len2, Tt, Qx, Qz: Single;
  begin
    ABx := BX - AX; ABz := BZ - AZ;
    Len2 := ABx * ABx + ABz * ABz;
    if Len2 < 1e-6 then
      Exit(Sqrt(Sqr(PX - AX) + Sqr(PZ - AZ)));
    APx := PX - AX; APz := PZ - AZ;
    Tt := (APx * ABx + APz * ABz) / Len2;
    if Tt < 0 then Tt := 0 else if Tt > 1 then Tt := 1;
    Qx := AX + Tt * ABx; Qz := AZ + Tt * ABz;
    Result := Sqrt(Sqr(PX - Qx) + Sqr(PZ - Qz));
  end;

  procedure AddBridgeSegsFromTile(const Tid: TGeoTileId);
  var
    SS: Integer;
    MM: TTileModel;
    SSegs: TTileRoadSegArray;
    SOrigin: TLatLon;
    Ctr: TVector3;
    RS: TTileRoadSeg;
    ScaleX: Double;
  begin
    SSegs := nil;
    ScaleX := TileScaleX(Tid);
    if FCache.TryLoadRoadSegs(Tid, SSegs, SOrigin) then
      Ctr := FProj.Project(SOrigin, 0)
    else
    begin
      MM := nil;
      if not (FCache.TryLoad(Tid, MM) and (MM <> nil)) then Exit;
      try
        Ctr := FProj.Project(MM.Origin, 0);
        SetLength(SSegs, MM.RoadSegCount);
        for SS := 0 to MM.RoadSegCount - 1 do
          SSegs[SS] := MM.RoadSegs[SS];
      finally
        MM.Free;
      end;
    end;
    for SS := 0 to High(SSegs) do
    begin
      if not SSegs[SS].IsBridge then Continue;
      if BrN >= Length(BrSegs) then
        SetLength(BrSegs, BrN * 2 + 64);
      RS := RoadSegmentToFrame(SSegs[SS], Ctr, ScaleX);
      BrSegs[BrN].X0 := RS.X0;
      BrSegs[BrN].Z0 := RS.Z0;
      BrSegs[BrN].X1 := RS.X1;
      BrSegs[BrN].Z1 := RS.Z1;
      Inc(BrN);
    end;
  end;

  procedure HarvestTileY(const Tid: TGeoTileId);
  var
    MM: TTileModel;
  begin
    MM := nil;
    if not (FCache.TryLoad(Tid, MM) and (MM <> nil)) then Exit;
    try
      MArr[0] := MM;
      IArr[0] := Tid;
      CaptureRouteGroundY(MArr, IArr, FRouteSnapped, FRouteWays, FRouteSnappedY);
      Inc(LoadedTiles);
    finally
      MM.Free;
    end;
  end;

begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  if ABridgeClearM < 0.5 then ABridgeClearM := 0.5;
  LoadedTiles := 0;
  BrN := 0;
  SetLength(BrSegs, 0);

  { One-time harvest of IsBridge segs + optional Y refresh from corridor tiles. }
  if Length(FSnapForceTiles) > 0 then
  begin
    for TI := 0 to High(FSnapForceTiles) do
      AddBridgeSegsFromTile(FSnapForceTiles[TI]);
    if ARefreshY and FSnappedReady and (Length(FRouteSnapped) > 0) then
    begin
      for TI := 0 to High(FSnapForceTiles) do
        HarvestTileY(FSnapForceTiles[TI]);
      LiftBridgeApproachY(FRouteSnapped, FRouteSnappedY);
    end;
  end
  else
  begin
    for B := 0 to FBatchList.Count - 1 do
    begin
      if (FBatchList[B] = nil) or (FBatchList[B].Tiles = nil) then Continue;
      for TI := 0 to FBatchList[B].Tiles.Count - 1 do
      begin
        CT := FBatchList[B].Tiles[TI];
        if CT = nil then Continue;
        AddBridgeSegsFromTile(CT.Tile);
        if ARefreshY and FSnappedReady and (Length(FRouteSnapped) > 0) then
          HarvestTileY(CT.Tile);
      end;
    end;
    if ARefreshY and FSnappedReady and (Length(FRouteSnapped) > 0) then
      LiftBridgeApproachY(FRouteSnapped, FRouteSnappedY);
  end;
  SetLength(BrSegs, BrN);

  N := Length(FRouteSnapped);
  MissY := 0; UnderSurf := 0; WayFlip := 0; BridgeLike := 0;
  NearBridgeSeg := 0; HaveYCnt := 0; SampleN := 0;
  SB := TStringBuilder.Create;
  try
    SB.Append('{');
    SB.Append(Format('"snapped_ready":%s,', [JBool(FSnappedReady)]));
    SB.Append(Format('"snapped_count":%d,', [N]));
    SB.Append(Format('"raw_count":%d,', [Length(FRoute)]));
    SB.Append(Format('"ways_count":%d,', [Length(FRouteWays)]));
    SB.Append(Format('"green_y_count":%d,', [Length(FRouteSnappedY)]));
    SB.Append(Format('"bridge_segs":%d,', [BrN]));
    SB.Append(Format('"y_tiles_loaded":%d,', [LoadedTiles]));
    SB.Append(Format('"bridge_clear_m":%.2f,', [ABridgeClearM], FS));
    SB.Append(Format('"fit_overlay_on":%s,',
      [JBool(FShowFitPoints or FShowFitPointsSnapped)]));
    SB.Append('"samples":[');

    PrevW := 0;
    Cum := 0;
    FirstSample := True;
    for I := 0 to N - 1 do
    begin
      WP := FProj.Project(FRouteSnapped[I], 0);
      if I > 0 then
      begin
        DLat := (FRouteSnapped[I].Lat - FRouteSnapped[I - 1].Lat) * 111320.0;
        DLon := (FRouteSnapped[I].Lon - FRouteSnapped[I - 1].Lon) *
          111320.0 * Cos(DegToRad(FRouteSnapped[I].Lat));
        Cum := Cum + Sqrt(DLat * DLat + DLon * DLon);
      end;
      W := 0;
      if I <= High(FRouteWays) then W := FRouteWays[I];
      GY := SPHERE_Y_NONE;
      if I <= High(FRouteSnappedY) then GY := FRouteSnappedY[I];
      if ValidY(GY) then Inc(HaveYCnt) else Inc(MissY);
      HaveG := GroundYAt(WP.X, WP.Z, GX);
      Clearance := 0;
      if HaveG and ValidY(GY) then Clearance := GY - GX;
      if ValidY(GY) and HaveG and (Clearance >= ABridgeClearM) then Inc(BridgeLike);
      if ValidY(GY) and HaveG and (GY < GX - 0.35) then Inc(UnderSurf);
      if (I > 0) and (PrevW <> 0) and (W <> 0) and (W <> PrevW) then Inc(WayFlip);

      OnBridgeSeg := False;
      BestSegD := 1e30;
      for S := 0 to High(BrSegs) do
      begin
        Dist := DistToSegXZ(WP.X, WP.Z,
          BrSegs[S].X0, BrSegs[S].Z0, BrSegs[S].X1, BrSegs[S].Z1);
        if Dist < BestSegD then BestSegD := Dist;
        if Dist <= BRIDGE_SEG_NEAR_M then OnBridgeSeg := True;
      end;
      if OnBridgeSeg then Inc(NearBridgeSeg);

      { Samples: only bridge vicinity + real issues (cap MAX_SAMPLES). }
      NeedSample := (SampleN < MAX_SAMPLES) and (
        OnBridgeSeg
        or (ValidY(GY) and HaveG and (GY < GX - 0.35))
        or ((not ValidY(GY)) and OnBridgeSeg)
        or (ValidY(GY) and HaveG and (Clearance >= ABridgeClearM)));
      if NeedSample then
      begin
        if not FirstSample then SB.Append(',');
        FirstSample := False;
        Inc(SampleN);
        SB.Append('{');
        SB.Append(Format('"i":%d,"dist_m":%.1f,', [I, Cum], FS));
        SB.Append(Format('"lat":%.7f,"lon":%.7f,',
          [FRouteSnapped[I].Lat, FRouteSnapped[I].Lon], FS));
        SB.Append(Format('"wx":%.2f,"wz":%.2f,', [WP.X, WP.Z], FS));
        SB.Append(Format('"way_id":%d,', [W]));
        if ValidY(GY) then
          SB.Append(Format('"green_y":%.3f,', [GY], FS))
        else
          SB.Append('"green_y":null,');
        if HaveG then
          SB.Append(Format('"ground_y":%.3f,"clear_m":%.3f,', [GX, Clearance], FS))
        else
          SB.Append('"ground_y":null,"clear_m":null,');
        SB.Append(Format('"near_bridge_seg":%s,', [JBool(OnBridgeSeg)]));
        if BestSegD < 1e20 then
          SB.Append(Format('"bridge_seg_dist_m":%.2f,', [BestSegD], FS))
        else
          SB.Append('"bridge_seg_dist_m":null,');
        SB.Append(Format('"bridge_like":%s,',
          [JBool(HaveG and ValidY(GY) and (Clearance >= ABridgeClearM))]));
        SB.Append(Format('"missing_y":%s,', [JBool(not ValidY(GY))]));
        SB.Append(Format('"under_surface":%s',
          [JBool(HaveG and ValidY(GY) and (GY < GX - 0.35))]));
        SB.Append('}');
      end;
      PrevW := W;
    end;
    SB.Append('],');

    Issues := UnderSurf;
    { missing_y far from camera is normal without full-corridor Y; flag only
      missing on bridge segs if we can measure. }
    SB.Append('"summary":{');
    SB.Append(Format('"missing_green_y":%d,', [MissY]));
    SB.Append(Format('"have_green_y":%d,', [HaveYCnt]));
    SB.Append(Format('"under_surface":%d,', [UnderSurf]));
    SB.Append(Format('"way_flips":%d,', [WayFlip]));
    SB.Append(Format('"bridge_like_pts":%d,', [BridgeLike]));
    SB.Append(Format('"near_bridge_seg_pts":%d,', [NearBridgeSeg]));
    SB.Append(Format('"bridge_segs":%d,', [BrN]));
    SB.Append(Format('"y_tiles_loaded":%d,', [LoadedTiles]));
    SB.Append(Format('"issue_count":%d,', [Issues]));
    SB.Append(Format('"ok":%s',
      [JBool(FSnappedReady and (N > 0) and (UnderSurf = 0)
        and ((BrN = 0) or (NearBridgeSeg = 0) or (HaveYCnt > 0)))]));
    SB.Append('},');
    SB.Append('"notes":[');
    SB.Append('"green_y=SnappedRouteY (deck/road for green spheres)",');
    SB.Append('"ground_y=GroundYAt needs RESIDENT tile; null off-camera is OK",');
    SB.Append('"clear_m=green_y-ground_y; bridge-like if >= bridge_clear_m",');
    SB.Append('"near_bridge_seg=within 25m of IsBridge centerline (needs O3RS v2 cache)",');
    SB.Append('"missing_y=no deck/road sample in cache for that point",');
    SB.Append('"under_surface=green below GroundYAt (approach bug)",');
    SB.Append('"bridge_segs=0 => regenerate tiles for IsBridge flags"');
    SB.Append(']');
    SB.Append('}');
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function TOsm3dStreamingMap.DumpRouteArraysJSON(ARefreshY: Boolean;
  AMaxPts: Integer; AStep: Integer): string;
{ Parallel arrays: raw FIT vs snapped (+ Y channels) for MCP compare. }
const
  MISSING_Y = SPHERE_Y_NONE * 0.5;
var
  SB: TStringBuilder;
  I, N, Step, FirstGap, GapRun, MaxGapRun, MaxGapStart: Integer;
  First: Boolean;
  GY, RY, AY, CY, Cum, DLat, DLon: Single;
  W: Int64;
  WR, WS: TVector3;
  FS: TFormatSettings;
  TI, Pass: Integer;
  M: TTileModel;
  MArr: array[0..0] of TTileModel;
  IArr: array[0..0] of TGeoTileId;
  MissGreen, HaveGreen: Integer;
  MaxLateral, LatHere: Single;
  MaxLatI: Integer;

  function ValidY(Y: Single): Boolean;
  begin
    Result := Y > MISSING_Y;
  end;

  function JBool(B: Boolean): string;
  begin
    if B then Result := 'true' else Result := 'false';
  end;

  function Jy(Y: Single): string;
  begin
    if ValidY(Y) then
      Result := Format('%.3f', [Y], FS)
    else
      Result := 'null';
  end;

begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  if AStep < 1 then AStep := 1;
  Step := AStep;

  if ARefreshY and FSnappedReady and (Length(FRouteSnapped) > 0) then
  begin
    FBridgeDeckYMax := SPHERE_Y_NONE;
    if Length(FSnapForceTiles) > 0 then
    begin
      for TI := 0 to High(FSnapForceTiles) do
      begin
        M := nil;
        if FCache.TryLoad(FSnapForceTiles[TI], M) and (M <> nil) then
        try
          MArr[0] := M; IArr[0] := FSnapForceTiles[TI];
          CaptureRouteGroundY(MArr, IArr, FRouteSnapped, FRouteWays, FRouteSnappedY);
          if Length(FRoute) > 0 then
          begin
            if Length(FRouteWays) = Length(FRoute) then
              CaptureRouteGroundY(MArr, IArr, FRoute, FRouteWays, FRouteGroundRaw)
            else
              CaptureRouteGroundY(MArr, IArr, FRoute, nil, FRouteGroundRaw);
          end;
        finally
          M.Free;
        end;
      end;
      LiftBridgeApproachY(FRouteSnapped, FRouteSnappedY);
      if Length(FRoute) > 0 then
        LiftBridgeApproachY(FRoute, FRouteGroundRaw);
    end;
  end;

  N := Length(FRouteSnapped);
  if Length(FRoute) < N then N := Length(FRoute);
  if (AMaxPts > 0) and (N > AMaxPts) then N := AMaxPts;

  MissGreen := 0; HaveGreen := 0;
  MaxLateral := 0; MaxLatI := -1;
  FirstGap := -1; GapRun := 0; MaxGapRun := 0; MaxGapStart := -1;

  SB := TStringBuilder.Create;
  try
    SB.Append('{');
    SB.Append(Format('"snapped_ready":%s,', [JBool(FSnappedReady)]));
    SB.Append(Format('"n":%d,"step":%d,', [N, Step]));
    SB.Append(Format('"len_raw":%d,"len_snap":%d,"len_ways":%d,"len_green_y":%d,',
      [Length(FRoute), Length(FRouteSnapped), Length(FRouteWays),
       Length(FRouteSnappedY)]));
    SB.Append(Format('"len_raw_ground_y":%d,"len_alt_m":%d,"len_alt_cal":%d,',
      [Length(FRouteGroundRaw), Length(FRouteAltM), Length(FRouteAltCal)]));
    SB.Append('"cols":["i","dist_m","raw_lat","raw_lon","snap_lat","snap_lon",');
    SB.Append('"lateral_m","way_id","green_y","raw_ground_y","alt_m","alt_cal",');
    SB.Append('"wx_raw","wz_raw","wx_snap","wz_snap"],');
    SB.Append('"rows":[');

    Cum := 0;
    First := True;
    for I := 0 to N - 1 do
    begin
      if I > 0 then
      begin
        DLat := (FRoute[I].Lat - FRoute[I - 1].Lat) * 111320.0;
        DLon := (FRoute[I].Lon - FRoute[I - 1].Lon) *
          111320.0 * Cos(DegToRad(FRoute[I].Lat));
        Cum := Cum + Sqrt(DLat * DLat + DLon * DLon);
      end;

      WR := FProj.Project(FRoute[I], 0);
      WS := FProj.Project(FRouteSnapped[I], 0);
      LatHere := Sqrt(Sqr(WR.X - WS.X) + Sqr(WR.Z - WS.Z));
      if LatHere > MaxLateral then
      begin
        MaxLateral := LatHere;
        MaxLatI := I;
      end;

      W := 0;
      if I <= High(FRouteWays) then W := FRouteWays[I];
      GY := SPHERE_Y_NONE;
      if I <= High(FRouteSnappedY) then GY := FRouteSnappedY[I];
      RY := SPHERE_Y_NONE;
      if I <= High(FRouteGroundRaw) then RY := FRouteGroundRaw[I];
      AY := SPHERE_Y_NONE;
      if I <= High(FRouteAltM) then AY := FRouteAltM[I];
      CY := SPHERE_Y_NONE;
      if I <= High(FRouteAltCal) then CY := FRouteAltCal[I];

      if ValidY(GY) then
      begin
        Inc(HaveGreen);
        GapRun := 0;
      end
      else
      begin
        Inc(MissGreen);
        if GapRun = 0 then
        begin
          if FirstGap < 0 then FirstGap := I;
        end;
        Inc(GapRun);
        if GapRun > MaxGapRun then
        begin
          MaxGapRun := GapRun;
          MaxGapStart := I - GapRun + 1;
        end;
      end;

      if (I mod Step = 0) or (not ValidY(GY)) or (LatHere > 8.0) then
      begin
        if not First then SB.Append(',');
        First := False;
        SB.Append('[');
        SB.Append(Format('%d,%.1f,', [I, Cum], FS));
        SB.Append(Format('%.7f,%.7f,', [FRoute[I].Lat, FRoute[I].Lon], FS));
        SB.Append(Format('%.7f,%.7f,',
          [FRouteSnapped[I].Lat, FRouteSnapped[I].Lon], FS));
        SB.Append(Format('%.2f,%d,', [LatHere, W], FS));
        SB.Append(Jy(GY)); SB.Append(',');
        SB.Append(Jy(RY)); SB.Append(',');
        SB.Append(Jy(AY)); SB.Append(',');
        SB.Append(Jy(CY)); SB.Append(',');
        SB.Append(Format('%.2f,%.2f,%.2f,%.2f',
          [WR.X, WR.Z, WS.X, WS.Z], FS));
        SB.Append(']');
      end;
    end;
    SB.Append('],');
    SB.Append('"summary":{');
    SB.Append(Format('"have_green_y":%d,"missing_green_y":%d,', [HaveGreen, MissGreen]));
    SB.Append(Format('"first_green_gap_i":%d,"max_green_gap_run":%d,"max_green_gap_start_i":%d,',
      [FirstGap, MaxGapRun, MaxGapStart]));
    SB.Append(Format('"max_lateral_m":%.2f,"max_lateral_i":%d,', [MaxLateral, MaxLatI], FS));
    SB.Append(Format('"ok":%s', [JBool((MissGreen = 0) and (N > 0))]));
    SB.Append('},');
    SB.Append('"legend":{');
    SB.Append(string('"green_y":"SnappedRouteY = green spheres",'));
    SB.Append(string('"raw_ground_y":"FRouteGroundRaw = red spheres",'));
    SB.Append(string('"alt_m":"FRouteAltM = blue spheres",'));
    SB.Append(string('"alt_cal":"FRouteAltCal = cyan spheres",'));
    SB.Append(string('"lateral_m":"XZ distance raw FIT vs snapped"'));
    SB.Append('}');
    SB.Append('}');
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

procedure TOsm3dStreamingMap.RebuildSphereScene(AIdx: Integer;
  const ARoute: TRouteLatLonArray; const AYArr: TRouteAltArray;
  const AColor: TVector3; const ALabel: string);
{ Запечь ВСЕ точки маршрута одного цвета в ЕДИНЫЙ TIndexedFaceSet: шаблон
  сферы штампуется в мировую позицию каждой точки (XZ = проекция, Y = AYArr
  + лифт). Одна сцена, один draw-call — число точек не влияет на FPS.
  Точки с ещё не снятой высотой (SPHERE_Y_NONE) пропускаются. }
var
  Root:  TX3DRootNode;
  Geo:   TIndexedFaceSetNode;
  Coord: TCoordinateNode;
  Mat:   TUnlitMaterialNode;
  App:   TAppearanceNode;
  Shape: TShapeNode;
  Sc:    TCastleScene;
  Pts:   array of TVector3;
  Idx:   array of LongInt;
  I, T, K, Base, VpS, IpS, NPts, PV, PIx: Integer;
  WP:    TVector3;
  Yc:    Single;
begin
  if FDestroying then Exit;
  FreeSphereSlot(AIdx);              { снять прошлый меш этого цвета }
  if Length(ARoute) = 0 then Exit;

  BuildSphereTemplate;
  VpS := Length(FSphTplV);
  IpS := Length(FSphTplIdx);

  { Сколько точек реально запечём (снята высота, есть индекс в AYArr). }
  NPts := 0;
  for I := 0 to High(ARoute) do
  begin
    if I > High(AYArr) then Break;
    if AYArr[I] < (SPHERE_Y_NONE * 0.5) then Continue;   { ещё не снята }
    Inc(NPts);
  end;
  if NPts = 0 then Exit;

  SetLength(Pts, NPts * VpS);
  SetLength(Idx, NPts * IpS);
  PV := 0; PIx := 0;
  for I := 0 to High(ARoute) do
  begin
    if I > High(AYArr) then Break;
    if AYArr[I] < (SPHERE_Y_NONE * 0.5) then Continue;
    WP   := FProj.Project(ARoute[I], 0);
    Yc   := AYArr[I] + FIT_SPHERE_LIFT_M;
    Base := PV;
    for T := 0 to VpS - 1 do
      Pts[PV + T] := Vector3(WP.X + FSphTplV[T].X,
                             Yc  + FSphTplV[T].Y,
                             WP.Z + FSphTplV[T].Z);
    Inc(PV, VpS);
    for K := 0 to IpS - 1 do
      if FSphTplIdx[K] < 0 then Idx[PIx + K] := -1
      else                     Idx[PIx + K] := FSphTplIdx[K] + Base;
    Inc(PIx, IpS);
  end;

  Coord := TCoordinateNode.Create; Coord.SetPoint(Pts);
  Geo := TIndexedFaceSetNode.Create;
  Geo.Coord := Coord; Geo.Solid := False; Geo.SetCoordIndex(Idx);
  Mat := TUnlitMaterialNode.Create; Mat.EmissiveColor := AColor;
  App := TAppearanceNode.Create; App.Material := Mat;
  Shape := TShapeNode.Create; Shape.Geometry := Geo; Shape.Appearance := App;
  Root := TX3DRootNode.Create; Root.AddChildren(Shape);

  Sc := TCastleScene.Create(nil);   { Owner=nil — управляем сами (FreeSphereSlot) }
  Sc.Load(Root, True);              { OwnsRootNode — X3D-дерево живёт на сцене }
  Sc.Collides := False;
  Sc.Pickable := False;
  Sc.DistanceCulling := 0;
  Sc.ReceiveShadowVolumes := False;  { в volume-проход тени байка не входим }
  FSphereScene[AIdx] := Sc;
  Add(Sc);                          { карта — TCastleTransform }

  LogMain(Format('FIT overlay [%s]: baked %d sphere(s) -> 1 draw call',
    [ALabel, NPts]));
end;

procedure TOsm3dStreamingMap.UpdateDirtySphereScenes;
{ Ленивая пересборка помеченных сцен с троттлингом: в берсте монтажа
  высоты дозаполняются, но меш пересобираем не чаще SPHERE_REBUILD_MS;
  в покое (нет грязных) — мгновенный выход. }
var
  Tk: QWord;
begin
  if FDestroying then Exit;
  if not (FSphereDirty[0] or FSphereDirty[1] or
          FSphereDirty[2] or FSphereDirty[3]) then Exit;
  Tk := GetTickCount64;
  if (FSphereRebuildTick <> 0) and
     (Tk - FSphereRebuildTick < SPHERE_REBUILD_MS) then Exit;
  FSphereRebuildTick := Tk;

  { 0 — красный «сырой рельеф». }
  if FSphereDirty[0] then
  begin
    FSphereDirty[0] := False;
    if FShowFitPoints and (Length(FRoute) > 0) then
      RebuildSphereScene(0, FRoute, FRouteGroundRaw,
        Vector3(1.0, 0.0, 0.0), 'raw')
    else FreeSphereSlot(0);
  end;
  { 1 — синий «исходная высота» (высота трека, без рельефа). }
  if FSphereDirty[1] then
  begin
    FSphereDirty[1] := False;
    if FShowFitPoints and (Length(FRoute) > 0)
       and (Length(FRouteAltM) = Length(FRoute)) then
      RebuildSphereScene(1, FRoute, FRouteAltM,
        Vector3(0.0, 0.0, 1.0), 'original')
    else FreeSphereSlot(1);
  end;
  { 2 — голубой «фит-коррекция» (датумный AltCal). }
  if FSphereDirty[2] then
  begin
    FSphereDirty[2] := False;
    if FShowFitPoints and (Length(FRoute) > 0)
       and (Length(FRouteAltCal) = Length(FRoute)) then
      RebuildSphereScene(2, FRoute, FRouteAltCal,
        Vector3(0.0, 1.0, 1.0), 'fitcorr')
    else FreeSphereSlot(2);
  end;
  { 3 — зелёный «снап» (высота настила/дороги под снапнутой точкой). }
  if FSphereDirty[3] then
  begin
    FSphereDirty[3] := False;
    if FShowFitPointsSnapped and FSnappedReady
       and (Length(FRouteSnapped) > 0) then
      RebuildSphereScene(3, FRouteSnapped, FRouteSnappedY,
        Vector3(0.0, 1.0, 0.0), 'snapped')
    else FreeSphereSlot(3);
  end;
end;

{ ── Route-only geometry (ASettings.GenerateRouteOnly) ─────────────────────
  Строить ТОЛЬКО тайлы коридора вокруг сырого маршрута FRoute. Коридор —
  множество тайлов, чей ЦЕНТР ближе (RouteOnlyRadiusM + пол-диагонали тайла)
  к ломаной маршрута (штампуем по шагам вдоль сегментов; объединение ≈ полоса
  радиуса вокруг линии, с запасом наружу — коридор непрерывный, без дыр).
  Всё в глобальных slippy-пикселях грида (инвариант к широте); радиус в метрах
  переводим в пиксели по метрам-на-пиксель на средней широте маршрута. }
procedure TOsm3dStreamingMap.BuildRouteCorridor;
var
  Grid:       TGeoTileGrid;
  EdgePx:     Integer;
  RPxX, RPxY: array of Double;
  MeanLat, MPerPx, RadiusPx, HalfDiagPx, StepPx: Double;
  P0x, P0y, P1x, P1y, SegLen, Sx, Sy, Cxp, Cyp: Double;
  I, S, NSteps, Dx, Dy, Ctx, Cty, Tx, Ty, Neigh: Integer;
  Tile: TGeoTileId;
  Key:  string;
begin
  FCorridorSet.Clear;
  FCorridorLatched.Clear;
  FCorridorPregenIdx := 0;
  SetLength(FCorridorTiles, 0);
  if FStreamer <> nil then FStreamer.WantFilter := nil;   { пока коридор пуст — без фильтра }
  if (not FRouteOnlyGeom) or (Length(FRoute) < 1) or (FCache = nil) then Exit;

  Grid   := FCache.Grid;
  EdgePx := Grid.EdgePx;
  if EdgePx < 1 then Exit;

  { Точки маршрута в глобальных slippy-пикселях + средняя широта. }
  SetLength(RPxX, Length(FRoute));
  SetLength(RPxY, Length(FRoute));
  MeanLat := 0.0;
  for I := 0 to High(FRoute) do
  begin
    Grid.PixelOf(FRoute[I], P0x, P0y);
    RPxX[I] := P0x; RPxY[I] := P0y;
    MeanLat := MeanLat + FRoute[I].Lat;
  end;
  MeanLat := MeanLat / Length(FRoute);

  MPerPx := Grid.EdgeMetersAt(MeanLat) / EdgePx;
  if MPerPx < 1.0e-6 then MPerPx := 1.0;
  RadiusPx   := FRouteOnlyRadiusM / MPerPx;
  HalfDiagPx := EdgePx * 0.70710678;              { пол-диагонали тайла, px }
  Neigh      := Ceil((RadiusPx + HalfDiagPx) / EdgePx) + 1;
  StepPx     := RadiusPx * 0.5;
  if StepPx < EdgePx * 0.5 then StepPx := EdgePx * 0.5;
  if StepPx < 1.0 then StepPx := 1.0;

  { Штамповка коридора: идём по каждому сегменту с шагом StepPx и добавляем
    тайлы, чей центр в пределах RadiusPx+HalfDiagPx от точки-сэмпла. }
  for I := 0 to High(FRoute) do
  begin
    P0x := RPxX[I];  P0y := RPxY[I];
    if I < High(FRoute) then
    begin P1x := RPxX[I + 1]; P1y := RPxY[I + 1]; end
    else
    begin P1x := P0x; P1y := P0y; end;      { последняя точка — одиночный штамп }

    SegLen := Sqrt(Sqr(P1x - P0x) + Sqr(P1y - P0y));
    NSteps := Ceil(SegLen / StepPx);
    if NSteps < 1 then NSteps := 1;

    for S := 0 to NSteps do
    begin
      Sx := P0x + (P1x - P0x) * S / NSteps;
      Sy := P0y + (P1y - P0y) * S / NSteps;
      Ctx := Floor(Sx / EdgePx);
      Cty := Floor(Sy / EdgePx);
      for Dy := -Neigh to Neigh do
        for Dx := -Neigh to Neigh do
        begin
          Tx := Ctx + Dx;  Ty := Cty + Dy;
          if (Tx < 0) or (Ty < 0) then Continue;
          Cxp := (Tx + 0.5) * EdgePx;
          Cyp := (Ty + 0.5) * EdgePx;
          if Sqrt(Sqr(Cxp - Sx) + Sqr(Cyp - Sy)) <= RadiusPx + HalfDiagPx then
          begin
            Tile := TGeoTileId.Make(0, True, Cardinal(Tx), Cardinal(Ty));
            Key  := Tile.ToString;
            if not FCorridorSet.ContainsKey(Key) then
            begin
              FCorridorSet.Add(Key, True);
              SetLength(FCorridorTiles, Length(FCorridorTiles) + 1);
              FCorridorTiles[High(FCorridorTiles)] := Tile;
            end;
          end;
        end;
    end;
  end;

  if (FCorridorSet.Count > 0) and (FStreamer <> nil) then
  begin
    FStreamer.WantFilter := @CorridorWantFilter;   { keyhole теперь только коридор }
    LogMain(Format('[route-only] коридор: %d тайл(ов) в радиусе %.0f м от '
      + 'маршрута (%d точек); весь коридор ставится на префетч',
      [FCorridorSet.Count, FRouteOnlyRadiusM, Length(FRoute)]));
  end
  else
    LogMain('[route-only] коридор ПУСТ (маршрут короткий?) — фильтр не ставлю');
end;

function TOsm3dStreamingMap.CorridorWantFilter(const AId: TGeoTileId): Boolean;
begin
  { Главный поток (зовётся из FStreamer.Pump). Тайл строим только если он в
    коридоре маршрута. }
  Result := FCorridorSet.ContainsKey(AId.ToString);
end;

procedure TOsm3dStreamingMap.PumpRouteCorridorPregen;
const
  ROUTE_PREGEN_PER_FRAME = 48;   { тайлов-латчей за кадр (гасит стартовый всплеск) }
var
  Budget: Integer;
  Tile:   TGeoTileId;
  Key:    string;
begin
  if (not FRouteOnlyGeom) or (FStreamer = nil) then Exit;
  if FCorridorPregenIdx >= Length(FCorridorTiles) then Exit;   { весь коридор уже запрошен }
  Budget := 0;
  while (FCorridorPregenIdx < Length(FCorridorTiles))
        and (Budget < ROUTE_PREGEN_PER_FRAME) do
  begin
    Tile := FCorridorTiles[FCorridorPregenIdx];
    Inc(FCorridorPregenIdx);
    Key := Tile.ToString;
    if FCorridorLatched.ContainsKey(Key) then Continue;
    FCorridorLatched.Add(Key, True);
    { Уже на диске (та же gen-hash, прошлая сессия) — не трогаем. Иначе —
      генерируем блок на диск без монтажа и без удержания модели в RAM
      (PregenTile → RequestBlockGen; по готовности блока ApplyBlockDone
      сохранит тайл и освободит). Ближние тайлы коридора монтирует камерный
      keyhole. Приоритет НИЖЕ ближних (большое число = хуже). }
    if not FCache.Has(Tile) then
      FStreamer.PregenTile(Tile, 1.0e9 + FCorridorPregenIdx);
    Inc(Budget);
  end;
end;

{ Height-grid callback for the far-ground mesh: coarse terrarium heights per
  octave box (cached/stitched; nil when not yet fetched -> vertices stay flat
  and catch up on a later retarget).
  Зум выбирается ПО РАЗМЕРУ БОКСА: большие (внешние) октавы берут грубее, чтобы
  бокс покрывал ~1 тайл. Иначе GetRegion сшивает регион в десятки тайлов
  (многомегабайтная аллокация+копия КАЖДОЕ пересечение → фриз). Дальние октавы
  грубые (незаметно), ближние малые — до детального FHeightmapZoom (как тайлы),
  поэтому без грубых z10-артефактов и со стыком к детали без шва. }
function TOsm3dStreamingMap.FarHeights(const ABox: TLatLonBox;
  AGrid: Integer): THeightArray;
const
  MIN_FAR_ZOOM = 4;
  SPIKE_DELTA  = 200.0;    { м: клетка выше ВСЕХ 4 соседей на столько → ложная гора }
  ABS_MAX      = 9000.0;   { м: явный мусор (выше любой реальной горы) }
var
  BoxSpanM, Ratio, Worst, D, NMax, Hh, BadLat, BadLon: Double;
  Z, IX, IZ, BadX, BadZ: Integer;
begin
  BoxSpanM := (ABox.MaxLat - ABox.MinLat) * DEG_TO_RAD * EARTH_RADIUS_M;
  if BoxSpanM < 1.0 then
    Z := FHeightmapZoom
  else
  begin
    Ratio := (2.0 * Pi * EARTH_RADIUS_M) / BoxSpanM;   { 2^Z тайлов по окружности }
    Z := Trunc(Ln(Ratio) / Ln(2.0));                   { tile >= box → ~1–2 тайла }
    if Z > FHeightmapZoom then Z := FHeightmapZoom;     { ближние малые октавы → детальный зум (как тайлы): нет грубых z10-артефактов, стык с деталью бесшовный }
    if Z < MIN_FAR_ZOOM then Z := MIN_FAR_ZOOM;
  end;
  if FFarLogBurst then
    LogMain(Format(
      '[far] octave box=%.6f..%.6f / %.6f..%.6f span=%.0fm -> z=%d n=%d',
      [ABox.MinLat, ABox.MaxLat, ABox.MinLon, ABox.MaxLon, BoxSpanM, Z, AGrid]));
  Result := FHmFetcher.GetSuperHeights(ABox, AGrid, Z);

  { ЛОВУШКА на ложную гору: ищем худшую клетку, что выше ВСЕХ 4 соседей на
 > SPIKE_DELTA (или абсолютный мусор > ABS_MAX), и пишем её гео-координату
 в лог — поймать, ОТКУДА берётся несуществующая вершина. Сравни
 залогированную lat/lon с тем, где гора видна: сдвиг по широте укажет на
 линейный (не меркаторный) маппинг выборки грубых октав. Диагностика —
 убрать после поимки. }
  if (Result <> nil) and (AGrid >= 3) and (Z >= 11) then
  begin
    Worst := 0.0; BadX := -1; BadZ := -1;
    for IZ := 1 to AGrid - 2 do
      for IX := 1 to AGrid - 2 do
      begin
        Hh   := Result[IZ * AGrid + IX];
        NMax := Result[IZ * AGrid + (IX - 1)];
        if Result[IZ * AGrid + (IX + 1)] > NMax then NMax := Result[IZ * AGrid + (IX + 1)];
        if Result[(IZ - 1) * AGrid + IX] > NMax then NMax := Result[(IZ - 1) * AGrid + IX];
        if Result[(IZ + 1) * AGrid + IX] > NMax then NMax := Result[(IZ + 1) * AGrid + IX];
        D := Hh - NMax;
        if (D > Worst) and ((D > SPIKE_DELTA) or (Hh > ABS_MAX)) then
        begin
          Worst := D; BadX := IX; BadZ := IZ;
        end;
      end;
    if BadX >= 0 then
    begin
      BadLon := ABox.MinLon + (ABox.MaxLon - ABox.MinLon) * BadX / (AGrid - 1);
      BadLat := ABox.MaxLat - (ABox.MaxLat - ABox.MinLat) * BadZ / (AGrid - 1);
      LogCallback(Format(
        '[FARSPIKE] z=%d lat=%.6f lon=%.6f h=%.1f d=%.1f cell=%d,%d grid=%d',
        [Z, BadLat, BadLon, Result[BadZ * AGrid + BadX], Worst, BadX, BadZ, AGrid]));
    end;
  end;
end;

{ (Пере)нацелить камера-центрированную дальнюю землю на текущую позицию камеры.
  Вызывается при пересечении ~ячейки (см. Update). Первый раз — строит ОДНУ
  постоянную сцену; далее НЕ пересобирает, а перенацеливает высоты (Retarget),
  которые затем плавно доводит покадровый Animate — поэтому без фриза.
  Translation остаётся гео-привязанным (ставится здесь, не покадрово):
  морфятся именно высоты, параллакс/стык с деталью не меняются. }
procedure TOsm3dStreamingMap.RebuildFarGround(const ACamPos: TVector3);
const
  FAR_INNER_HALF_M = 1024.0;   { радиус дыры < зоны детали — меш подныривает, закрывает просветы }
  FAR_LEVELS       = 7;        { октав радиуса; внешний край = 1024·2^7 = ±131 км }
  FAR_SECTORS      = 128;      { угловых секторов окружности (круглость силуэта) }
  FAR_BIAS_DOWN_M  = 3.0;      { сдвиг вниз — деталь выигрывает depth }
var
  CamGeo: TLatLon;
begin
  CamGeo := FProj.Unproject(ACamPos.X, ACamPos.Z);
  { бёрст-гейт диагностики [far]: одна пачка строк раз в ~2 с }
  FFarLogBurst := GetTickCount64 - FFarLogLast > 2000;
  if FFarLogBurst then
  begin
    FFarLogLast := GetTickCount64;
    LogMain(Format(
      '[far] center world=(%.1f, %.1f) inner=%.0fm levels=%d sectors=%d bias=-%.1fm '
      + 'octave halves(m)=1024*2^L',
      [ACamPos.X, ACamPos.Z, FAR_INNER_HALF_M, FAR_LEVELS, FAR_SECTORS,
       FAR_BIAS_DOWN_M]));
  end;
  if FFarGround = nil then
  begin
    FFarGround := TOsm3dFarGround.Create(Self, CamGeo, FAR_INNER_HALF_M, FAR_LEVELS,
      FAR_SECTORS, FAR_BIAS_DOWN_M,
      { цветовые параметры конструктором ИГНОРИРУЮТСЯ с перехода дальней
        земли на константную дымку (FAR_GROUND_* в Osm3dTilePreview);
        передаём превью-зелень MAT_RGB[0] вместо прежней литеральной копии }
      MAT_RGB[0][0], MAT_RGB[0][1], MAT_RGB[0][2], @FarHeights);
    Add(FFarGround.Scene);
  end
  else
    FFarGround.Retarget(CamGeo, @FarHeights);   { анимированный морф высот, без пересбора }

  FFarGround.Scene.Translation := Vector3(ACamPos.X, 0, ACamPos.Z);
  FFarCenterX := ACamPos.X;
  FFarCenterZ := ACamPos.Z;
  FFarHasCenter := True;
  FFarClipDirty := True;
end;

{ Посекторное покрытие показанным грунтом лучом из центра дальней земли.
  ВАЖНО: наземный per-tile LODNode НЕ имеет пустого дальнего уровня — любой
  смонтированный тайл рисует землю на ЛЮБОЙ дистанции (A→B→C, C — грубый
  супертайл-грунт). Поэтому покрытие = просто "тайл смонтирован"
  (FTileIndex/Active/Exists), БЕЗ кэпа по дистанции. Грунт кончается там, где
  тайлы выгружаются (StreamSceneUnloadM); первая дыра луча ловит эту кромку.
  R_cover = ПОСЛЕДНЯЯ покрытая точка (а не первая дыра) — тогда дальняя земля
  заходит чуть ПОД деталь (перекрытие), а не оставляет щель. Нет тайла у центра
  → 0 (до внутреннего кольца). SetClip перестраивает индекс только при изменении. }
procedure TOsm3dStreamingMap.UpdateFarClip;
var
  S, Sj, Steps, k: Integer;
  Theta, DirX, DirZ, Rho, RhoMax, StepM, WX, WZ: Double;
  Radii: array of Single;
  CT: TCacheTile;
  Shown: Boolean;
begin
  if (FFarGround = nil) or (not FFarHasCenter) then Exit;
  { Coverage depends on the far-ground centre and mounted tile visibility,
    not the camera's position inside the current cell. Keep the last clip
    until one of those inputs (or the unload distance) actually changes. }
  if not FFarClipDirty and
     (FFarClipUnloadM = GlobalLODConfig.StreamSceneUnloadM) then Exit;
  S := FFarGround.Sectors;
  if S < 1 then Exit;
  SetLength(Radii, S);
  RhoMax := GlobalLODConfig.StreamSceneUnloadM + FEdge;  { кромка выгрузки + запас на отставание центра от камеры }
  if RhoMax < FEdge then RhoMax := FEdge;
  StepM := FEdge * 0.5;
  if StepM < 1.0 then StepM := 1.0;
  Steps := Trunc(RhoMax / StepM) + 1;
  for Sj := 0 to S - 1 do
  begin
    Theta := 2.0 * Pi * Sj / S;
    DirX  := Cos(Theta);
    DirZ  := Sin(Theta);
    Radii[Sj] := 0.0;                    { нет покрытия → до внутреннего кольца }
    Rho := StepM * 0.5;
    for k := 0 to Steps - 1 do
    begin
      WX := FFarCenterX + Rho * DirX;
      WZ := FFarCenterZ + Rho * DirZ;
      { Числовой ключ тайла: луч делает ~10^3 проб на кадр, строковый
        ToString здесь давал ~10^3 аллокаций на кадр. }
      Shown := FTileIndex.TryGetValue(
                 FCache.Grid.TileAt(FProj.Unproject(WX, WZ)).ToKey, CT)
               and (CT <> nil)
               and CT.Active and (CT.Scene <> nil) and CT.Scene.Exists;
      if not Shown then Break;            { первая дыра — стоп }
      Radii[Sj] := Rho;                   { последняя ПОКРЫТАЯ точка → перекрытие, не щель }
      Rho := Rho + StepM;
    end;
  end;
  LogFarClip(Radii);
  FFarGround.SetClip(Radii);
  FFarClipUnloadM := GlobalLODConfig.StreamSceneUnloadM;
  FFarClipDirty := False;
end;

{ Сводка радиусов внутренней кромки дальней земли; лог только по изменению.
  Кромка режется КОЛЬЦАМИ по секторам, покрытие меряется лучом с шагом
  FEdge/2 — на углах покрытия возможны клин-вырезы, не перекрытые деталью:
  min/медиана/max радиусов и число секторов без покрытия дают картину. }
procedure TOsm3dStreamingMap.LogFarClip(const ARadii: array of Single);
var
  Srt: array of Single;
  I, J, Zero: Integer;
  T: Single;
  Msg: string;
begin
  if Length(ARadii) = 0 then Exit;
  SetLength(Srt, Length(ARadii));
  for I := 0 to High(ARadii) do Srt[I] := ARadii[I];
  { простая вставка — 128 значений }
  for I := 1 to High(Srt) do
  begin
    T := Srt[I]; J := I - 1;
    while (J >= 0) and (Srt[J] > T) do
    begin
      Srt[J + 1] := Srt[J]; Dec(J);
    end;
    Srt[J + 1] := T;
  end;
  Zero := 0;
  for I := 0 to High(ARadii) do
    if ARadii[I] <= 0.0 then Inc(Zero);
  Msg := Format(
    '[far] clip radii m: min=%.0f med=%.0f max=%.0f zero-sectors=%d/%d',
    [Srt[0], Srt[Length(Srt) div 2], Srt[High(Srt)], Zero, Length(ARadii)]);
  if Msg = FFarClipLog then Exit;
  FFarClipLog := Msg;
  LogMain(Msg);
end;

{ base-tile ring host (visibility callbacks; Update each frame) }

function TOsm3dStreamingMap.CellGeoId(const AId: TLodCellId): TGeoTileId;
begin
  Result := TGeoTileId.Make(0, True, Cardinal(AId.CX), Cardinal(AId.CY));
end;

function TOsm3dStreamingMap.LodFactory(const AId: TLodCellId): TLodCell;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1727);{$ENDIF}
  Result := MakeLodCell(AId, FLodCb);
end;

{ ВНИМАНИЕ (CGE/GLSL): эффект по образцу WaterShader. Проверить плаги
  PLUG_vertex_eye_space / PLUG_fragment_modify и stVertex/stFragment у себя. }
function TOsm3dStreamingMap.BuildLoadBlendEffect(GR, GG, GB, FR, FG, FB: Single): TEffectNode;
begin
  { тот же общий блендинг, что и у дальней земли }
  Result := BuildGroundBlendEffect(GR, GG, GB, FR, FG, FB, LOAD_BLEND_NEAR_M, LOAD_BLEND_FAR_M);
end;

function TOsm3dStreamingMap.BuildGroundLoadingScene(const ACenter: TVector3;
  ASizeX, ASizeZ: Single; const AHeights: THeightArray; AN: Integer;
  out ATextNode: TTextNode; out ACoord: TCoordinateNode;
  out AInterp: TCoordinateInterpolatorNode; out ATimer: TTimeSensorNode): TCastleScene;
var
  Root: TX3DRootNode; Geo: TIndexedFaceSetNode;
  Mat: TMaterialNode; App: TAppearanceNode; Shape: TShapeNode;
  Pts: array of TVector3; Idx: array of LongInt;
  IX, IZ, VI, K: Integer; StepX, StepZ, OX, OZ, CenterY, GR, GG, GB: Single;
  Sc: TCastleScene;
  RtA, RtB: TX3DRoute;
begin
  { Раздельные размеры по осям: меркаторный геотайл в equirect-кадре сессии
    НЕ квадрат (высота ряда тайлов убывает к северу). Прежний общий SizeXZ
    по широте центра давал у соседей по вертикали кромки на разных Z —
    планарные щели строго вдоль W-E границ («N-S соединены, W-E порваны»),
    сквозь которые виден тёмный фон. }
  StepX := ASizeX / (AN - 1);
  StepZ := ASizeZ / (AN - 1);
  OX := ACenter.X - ASizeX * 0.5;  OZ := ACenter.Z - ASizeZ * 0.5;
  SetLength(Pts, AN * AN);
  { ОРИЕНТАЦИЯ. Проекция: X := -East (запад = +X, восток = -X), Z := North.
    Грид высот: столбец IX=0 = ЗАПАД (MinLon), строка IZ=0 = ЮГ (MinLat).
    OX — минимальный X, т.е. ВОСТОЧНЫЙ край: столбцы кладутся зеркально
    (AN-1-IX), иначе рельеф каждой заглушки отражён по X — данные кромок
    у соседей равны, а на стыке рендерится западная колонка одного против
    восточной другого: ступени на каждом N-S шве и рельеф, не совпадающий
    с деталью по форме. Z прямой: строка юга (IZ=0) у минимального Z. }
  for IZ := 0 to AN - 1 do
    for IX := 0 to AN - 1 do
      Pts[IZ * AN + (AN - 1 - IX)] :=
        Vector3(OX + (AN - 1 - IX) * StepX, AHeights[IZ * AN + IX],
                OZ + IZ * StepZ);
  SetLength(Idx, (AN - 1) * (AN - 1) * 5);
  K := 0;
  for IZ := 0 to AN - 2 do
    for IX := 0 to AN - 2 do
    begin
      VI := IZ * AN + IX;
      Idx[K] := VI;            Idx[K+1] := VI + 1;
      Idx[K+2] := VI + AN + 1; Idx[K+3] := VI + AN;  Idx[K+4] := -1;
      Inc(K, 5);
    end;
  ACoord := TCoordinateNode.Create; ACoord.SetPoint(Pts);
  Geo := TIndexedFaceSetNode.Create;
  Geo.Coord := ACoord; Geo.Solid := False; Geo.SetCoordIndex(Idx);
  { базовый цвет = трава (fallback); эффект перекрывает по расстоянию }
  GR := MAT_RGB[0][0] / 255; GG := MAT_RGB[0][1] / 255; GB := MAT_RGB[0][2] / 255;
  if (GR = 0) and (GG = 0) and (GB = 0) then begin GR := 0.35; GG := 0.50; GB := 0.28; end;
  Mat := TMaterialNode.Create;
  Mat.DiffuseColor := Vector3(0, 0, 0);
  Mat.EmissiveColor := Vector3(GR, GG, GB);
  Mat.AmbientIntensity := 0.0;
  Mat.Transparency := 0.0;      { меш земли — непрозрачный }
  App := TAppearanceNode.Create; App.Material := Mat;
  ChainEffectApp(App, BuildLoadBlendEffect(GR, GG, GB,
    FAR_GROUND_R / 255, FAR_GROUND_G / 255, FAR_GROUND_B / 255));
  Shape := TShapeNode.Create; Shape.Geometry := Geo; Shape.Appearance := App;
  Root := TX3DRootNode.Create; Root.AddChildren(Shape);
  { надпись прогресса над центром меша }
  CenterY := AHeights[(AN div 2) * AN + (AN div 2)];
  MakeLoadingLabel(Root, Vector3(ACenter.X, CenterY + LOAD_BOX_HEIGHT_M, ACenter.Z),
    ASizeX * LOAD_TEXT_FACTOR, ATextNode);
  { X3D-морф высот: CoordinateInterpolator + TimeSensor + routes. Проигрывается ОДИН
    раз при подгрузке детали (StartMeshMorph). Enabled=False -> без авто-старта при
    загрузке сцены (иначе морф гонит Coord.set_point на каждом меше = нагрузка). }
  AInterp := TCoordinateInterpolatorNode.Create;
  AInterp.FdKey.Items.Add(0.0);
  AInterp.FdKey.Items.Add(1.0);
  for K := 0 to AN*AN - 1 do AInterp.FdKeyValue.Items.Add(Pts[K]);
  for K := 0 to AN*AN - 1 do AInterp.FdKeyValue.Items.Add(Pts[K]);
  Root.AddChildren(AInterp);
  ATimer := TTimeSensorNode.Create;
  ATimer.CycleInterval := LOAD_MORPH_S;
  ATimer.Loop := False;
  ATimer.Enabled := False;
  Root.AddChildren(ATimer);
  RtA := TX3DRoute.Create;
  RtA.SetSourceDirectly(ATimer.EventFraction_changed);
  RtA.SetDestinationDirectly(AInterp.EventSet_fraction);
  Root.AddRoute(RtA);
  RtB := TX3DRoute.Create;
  RtB.SetSourceDirectly(AInterp.EventValue_changed);
  RtB.SetDestinationDirectly(ACoord.FdPoint.EventIn);
  Root.AddRoute(RtB);
  Sc := TCastleScene.Create(Self);
  Sc.Load(Root, True);
  Sc.ProcessEvents := True;
  Sc.Collides := False; Sc.Pickable := False; Sc.Exists := True;
  Sc.ReceiveShadowVolumes := False;  { в volume-проход тени байка не входим }
  Result := Sc;
end;

procedure TOsm3dStreamingMap.SetRoutesFolder(
  const AFolder, ASelectedFit: String);
begin
  FRoutesFolder := AFolder;
  FSelectedFit := ASelectedFit;
end;

{ Построить коррекцию террейна из папки заездов: нивелировать сеть
  (Osm3dFitBank), спроецировать приведённые высоты выбранного заезда в
  мировые метры карты (FProj), классифицировать мосты по снапнутым way,
  и отдать профиль в FFitCorr. Вызывается на снапе (OnRouteSnapDone) —
  общий путь студии и игры. }
procedure TOsm3dStreamingMap.CaptureRouteDem;
var
  Box: TLatLonBox;
  Hm:  THeightmap;
  I:   Integer;
begin
  FRouteDemPending := False;
  SetLength(FPendingRouteDem, 0);
  if Length(FRoute) = 0 then Exit;
  if FHmFetcher = nil then
  begin
    LogMain('[dem] красный канал: фетчер не задан — чистый DEM не снят');
    Exit;
  end;
  { Бокс маршрута + запас, как в Osm3dFitBank: тот же метод даёт те же
    числа, что уходят в датум/сплайн. GetRegion спускается до дискового
    кэша (после прогрева маршрута в сеть не идёт) и НЕ применяет FIT-слой:
    слой фетчер только хранит, читает его генератор тайлов. }
  Box := TLatLonBox.Empty;
  for I := 0 to High(FRoute) do
    Box := Box.Include(FRoute[I]);
  Box := Box.ExpandMeters(50.0);
  { ACancel=@FSnapCancel: зовём из фонового fitcorr-воркера; деструктор
    взводит флаг и ждёт поток — без отмены целый регион маршрута
    (сотни тайлов × HTTP до 30 с) держал бы Stop несколько секунд. }
  Hm := FHmFetcher.GetRegion(Box, FHeightmapZoom, @FSnapCancel);
  if FSnapCancel then
  begin
    if Hm <> nil then Hm.Free;
    Exit;
  end;
  if Hm = nil then
  begin
    LogMain('[dem] красный канал: регион Terrarium не поднялся — DEM не снят');
    Exit;
  end;
  try
    SetLength(FPendingRouteDem, Length(FRoute));
    for I := 0 to High(FRoute) do
      FPendingRouteDem[I] := THeightmapSampler.SampleBilinear(Hm, FRoute[I]);
  finally
    Hm.Free;              { GetRegion отдаёт свежий стич — владеет вызывающий }
  end;
  FRouteDemPending := True;
  LogMain(Format('[dem] красный канал: чистый DEM снят под %d точками, zoom %d',
    [Length(FPendingRouteDem), FHeightmapZoom]));
end;

procedure TOsm3dStreamingMap.ComputeFitCorrectionOffThread;
const
  { Высота устройства над дорогой, вычитаемая из цели грунта. Сплайн
    дрейфа (медиана fit−Dem) уже вбирает постоянный подъём устройства,
    а визуальный лифт сфер сокращается в разнице красный↔голубой —
    поэтому 0. Тюнинг: поднять, если наблюдается систематический
    подъём грунта на фикс. величину. }
  CORR_DEVICE_LIFT_M = 0.0;
var
  Bank: TFitBankRideArray;
  Sel, R, DeckN: Integer;
  BankStat: String;
  FitT0: QWord;
  Pts: TFitCorrPointArray;
  I, N, J: Integer;
  Wp: TVector3;
  IsDeck: Boolean;
  MedR: array of Double;
  MedMin, MedMax, V: Double;
  ConfF: array of Double;
  DriftCorr, DriftR: array of Double;

  { Быстрая сортировка (Хоар, опора — середина отрезка) первых ACount
    элементов. Для медиан/робастных сигм: порядок равных элементов не важен.
    Рекурсия всегда в меньший отрезок — глубина стека O(log n). }
  procedure SortDoubles(var A: array of Double; ACount: Integer);
    procedure QSort(L, R: Integer);
    var
      I, J: Integer;
      P, T: Double;
    begin
      while L < R do
      begin
        I := L; J := R;
        P := A[(L + R) div 2];
        repeat
          while A[I] < P do Inc(I);
          while A[J] > P do Dec(J);
          if I <= J then
          begin
            T := A[I]; A[I] := A[J]; A[J] := T;
            Inc(I); Dec(J);
          end;
        until I > J;
        if J - L < R - I then
        begin
          if L < J then QSort(L, J);
          L := I;
        end
        else
        begin
          if I < R then QSort(I, R);
          R := J;
        end;
      end;
    end;
  begin
    if ACount > 1 then QSort(0, ACount - 1);
  end;

  { Медиана (AltCal − Dem) одного заезда — quicksort копии. }
  function MedianAltDem(const AAlt, ADem: array of Double): Double;
  var
    A: array of Double;
    I2: Integer;
  begin
    if Length(AAlt) = 0 then Exit(0.0);
    SetLength(A, Length(AAlt));
    for I2 := 0 to High(AAlt) do A[I2] := AAlt[I2] - ADem[I2];
    SortDoubles(A, Length(A));
    Result := A[Length(A) div 2];
  end;

  { Доверие по пройденному ПУТИ от старта движения (не по времени!):
    барометр калибруется движением/высотой, а на стоянке до старта он
    дрейфует, GPS таскает точку — время идёт, а данные врут (наблюдали
    950 стояночных точек с dist=0 и выбросом +44 м). Косинус 0→1 на
    первых FIT_WARMUP_M метрах ХОДА. Точки без перемещения (стоянки,
    светофоры) глушатся отдельно (нулевой шаг → Conf=0). }
  function WarmupConf(ADist: Double): Double;
  const
    FIT_WARMUP_M = 1200.0;   { ~первый км хода — прогрев барометра }
  begin
    if ADist >= FIT_WARMUP_M then Exit(1.0);
    if ADist <= 0 then Exit(0.0);
    Result := 0.5 * (1.0 - Cos(Pi * ADist / FIT_WARMUP_M));
  end;

  { Доверие каждой точке заезда: прогрев по пройденному пути + глушение
    стоянок. Путь копится в проекции (X,Z уже в метрах); в накопление
    идут только шаги > STOP_STEP_M — так GPS-джиттер на месте не
    «прогревает» и стоянка до старта остаётся с нулевым доверием. Точка,
    чей шаг к предыдущей мал (стоянка/светофор), глушится (Conf=0) — её
    некалиброванная высота не должна резать мир; место покроют соседние
    точки-движения через продольное окно. }
  procedure BuildConf(const ALat, ALon: array of Double;
    out AConf: array of Double);
  const
    STOP_STEP_M = 0.7;       { ниже — стоянка/джиттер, не движение }
  var
    K2: Integer;
    Pp, Pc: TVector3;
    Step, Moved: Double;
    Moving: Boolean;
  begin
    if Length(ALat) = 0 then Exit;
    Moved := 0;
    Pp := FProj.Project(ALat[0], ALon[0]);
    AConf[0] := 0;           { самый старт — всегда недоверенный }
    for K2 := 1 to High(ALat) do
    begin
      Pc := FProj.Project(ALat[K2], ALon[K2]);
      Step := Sqrt(Sqr(Pc.X - Pp.X) + Sqr(Pc.Z - Pp.Z));
      Moving := Step > STOP_STEP_M;
      if Moving then Moved := Moved + Step;
      if Moving then
        AConf[K2] := WarmupConf(Moved)
      else
        AConf[K2] := 0;      { стоянка/джиттер — глушим }
      Pp := Pc;
    end;
  end;

  { Кривая дрейфа барометра b(t) — РОБАСТНЫЙ сглаживающий сплайн ПО ВРЕМЕНИ.
    Голубые сферы/цели грунта: fitcorr = fit − b(t).

    Принцип (универсальный, для ЛЮБОГО маршрута):
      fit(t)   = h(полотно) + b(t)   — b: дрейф баро, длинная волна ПО ВРЕМЕНИ;
      dem(мст) = h(земля)   + e(мст) — e: ошибка DEM, функция МЕСТА.
    Вход алгоритма — ТОЛЬКО fit + dem + время. Никакого ОСМ (мосты не
    классифицируем — их глушит робастность), никаких самоперекрытий
    маршрута (возвратность — частный случай данных; перекрытия — только
    ОФЛАЙН-референс успешности, см. цифры ниже, в расчёте не участвуют).

    Модель: b(t) кусочно-линейна на узлах через NODE_SEC (~4 мин — длина
    волны дрейфа, как DATUM_NODE_SEC датума). МНК: данные (fit−dem) на
    каждой точке с весом Conf×Хубер + гладкость (вторая разность узлов)
    с весом SMOOTH_W. IRLS: невязки > HUBER_K·σ (настилы развязок, лес,
    GPS-глюки) глушатся весом Хубера — статистикой, без классификации.
    Conf = прогрев барометра по пройденному пути + стоянки в ноль
    (BuildConf): некалиброванный старт и стояночный дрейф не голосуют.
    Время (не дистанция!) как параметр: дрейф — физика барометра, он
    течёт и на стоянке, а у окон по дистанции стоянка схлопывается в
    точку и излом дрейфа за стоянку рвал бы сплайн.

    Почему не прежняя схема (узлы 3 км по дистанции, медиана (fit−dem)
    в окне ±1.5 км). Короткое окно применяет DEM на среднем масштабе,
    где e(место) ещё не усреднилась, и КОПИРУЕТ её в «дрейф» — качки
    узлов ±3 м на 3 км, физически невозможные для баро. Замер на
    возвратном заезде 67 км (пары «одно место — два проезда» как
    независимый референс, алгоритму недоступный):
                                 медиана|Δ| пары   утечка DEM   замыкание
      узлы 3 км (медиана):            1.16 м         0.40 м       +0.03
      этот сплайн (λ=30 + Conf):      0.81 м         0.07 м       −0.09
      потолок при известных парах:    0.57 м         0.09 м       +0.10
    «Утечка DEM» — среднемасштабная (≤2.5 км) энергия снятой кривой:
    прямое измерение подмены дрейфа ошибкой DEM. Разница 0.81 против
    потолка 0.57 — цена универсальности: без перекрытий эту часть дрейфа
    из fit+dem не восстановить принципиально. SMOOTH_W калиброван на этом
    заезде; плато λ=30…100 широкое, выбор не острый. }
  procedure BuildDriftCorrected(const ALat, ALon, AAlt, ADem,
    ATimeSec: array of Double; out AOut: array of Double);
  const
    NODE_SEC     = 240.0;  { шаг узлов b(t) — как DATUM_NODE_SEC датума }
    SMOOTH_W     = 30.0;   { вес гладкости (вторая разность узлов)      }
    HUBER_K      = 2.0;    { порог Хубера, в робастных сигмах           }
    IRLS_PASSES  = 3;
    RIDGE        = 1e-9;   { численный якорь диагонали                  }
  var
    NP, NN, I2, J2, K2, Pass, Pv, Rw, Cl: Integer;
    T0, F, Wp, W2, Sg, MxA, Fac, Acc: Double;
    Dlt, Conf, WPt, Res, AbsR: array of Double;
    NodeB: array of Double;          { решение: значения узлов b        }
    M: array of Double;              { нормальная система NN×(NN+1)     }
    function NodeRef(AT: Double; out AF: Double): Integer;
    begin
      Result := Trunc((AT - T0) / NODE_SEC);
      if Result < 0 then Result := 0;
      if Result > NN - 2 then Result := NN - 2;
      AF := (AT - T0) / NODE_SEC - Result;
      if AF < 0 then AF := 0 else if AF > 1 then AF := 1;
    end;
    { медиана |Res| по точкам с весом — робастная сигма IRLS }
    function RobustSigma: Double;
    var
      Cn, I3: Integer;
    begin
      Cn := 0;
      for I3 := 0 to NP - 1 do
        if Conf[I3] > 0 then
        begin
          AbsR[Cn] := Abs(Res[I3]);
          Inc(Cn);
        end;
      if Cn = 0 then Exit(1.0);
      SortDoubles(AbsR, Cn);
      Result := 1.4826 * AbsR[Cn div 2];
      if Result < 1e-6 then Result := 1.0;
    end;
  begin
    NP := Length(AAlt);
    { фолбэк на сырой фит: коррекция не строится — не портим }
    for I2 := 0 to NP - 1 do AOut[I2] := AAlt[I2];
    if (NP < 2) or (Length(ATimeSec) <> NP) then Exit;
    T0 := ATimeSec[0];
    NN := Trunc((ATimeSec[NP - 1] - T0) / NODE_SEC) + 2;
    if NN < 3 then NN := 3;

    SetLength(Dlt, NP);
    SetLength(Conf, NP);
    SetLength(WPt, NP);
    SetLength(Res, NP);
    SetLength(AbsR, NP);
    for I2 := 0 to NP - 1 do Dlt[I2] := AAlt[I2] - ADem[I2];
    BuildConf(ALat, ALon, Conf);
    Acc := 0;
    for I2 := 0 to NP - 1 do
    begin
      WPt[I2] := 1.0;
      Acc := Acc + Conf[I2];
    end;
    if Acc < 3.0 then Exit;  { весь заезд — стоянка/прогрев: правды нет }

    SetLength(NodeB, NN);
    SetLength(M, NN * (NN + 1));
    for Pass := 1 to IRLS_PASSES do
    begin
      if FSnapCancel then Exit;   { teardown карты: не доезжаем итерации }
      for I2 := 0 to NN * (NN + 1) - 1 do M[I2] := 0;
      { данные: (1−F)·b[k] + F·b[k+1] = fit−dem, вес Conf×Хубер }
      for I2 := 0 to NP - 1 do
      begin
        Wp := Conf[I2] * WPt[I2];
        if Wp <= 0 then Continue;
        W2 := Wp * Wp;
        K2 := NodeRef(ATimeSec[I2], F);
        M[K2 * (NN + 1) + K2]           := M[K2 * (NN + 1) + K2]           + W2 * (1 - F) * (1 - F);
        M[K2 * (NN + 1) + K2 + 1]       := M[K2 * (NN + 1) + K2 + 1]       + W2 * (1 - F) * F;
        M[(K2 + 1) * (NN + 1) + K2]     := M[(K2 + 1) * (NN + 1) + K2]     + W2 * F * (1 - F);
        M[(K2 + 1) * (NN + 1) + K2 + 1] := M[(K2 + 1) * (NN + 1) + K2 + 1] + W2 * F * F;
        M[K2 * (NN + 1) + NN]           := M[K2 * (NN + 1) + NN]           + W2 * (1 - F) * Dlt[I2];
        M[(K2 + 1) * (NN + 1) + NN]     := M[(K2 + 1) * (NN + 1) + NN]     + W2 * F * Dlt[I2];
      end;
      { гладкость: b[j−1] − 2b[j] + b[j+1] = 0, вес SMOOTH_W }
      W2 := SMOOTH_W * SMOOTH_W;
      for J2 := 1 to NN - 2 do
      begin
        M[(J2 - 1) * (NN + 1) + J2 - 1] := M[(J2 - 1) * (NN + 1) + J2 - 1] + W2;
        M[(J2 - 1) * (NN + 1) + J2]     := M[(J2 - 1) * (NN + 1) + J2]     - 2 * W2;
        M[(J2 - 1) * (NN + 1) + J2 + 1] := M[(J2 - 1) * (NN + 1) + J2 + 1] + W2;
        M[J2 * (NN + 1) + J2 - 1]       := M[J2 * (NN + 1) + J2 - 1]       - 2 * W2;
        M[J2 * (NN + 1) + J2]           := M[J2 * (NN + 1) + J2]           + 4 * W2;
        M[J2 * (NN + 1) + J2 + 1]       := M[J2 * (NN + 1) + J2 + 1]       - 2 * W2;
        M[(J2 + 1) * (NN + 1) + J2 - 1] := M[(J2 + 1) * (NN + 1) + J2 - 1] + W2;
        M[(J2 + 1) * (NN + 1) + J2]     := M[(J2 + 1) * (NN + 1) + J2]     - 2 * W2;
        M[(J2 + 1) * (NN + 1) + J2 + 1] := M[(J2 + 1) * (NN + 1) + J2 + 1] + W2;
      end;
      for I2 := 0 to NN - 1 do
        M[I2 * (NN + 1) + I2] := M[I2 * (NN + 1) + I2] + RIDGE;
      { Гаусс с частичным выбором главного элемента (NN ~ десятки) }
      for I2 := 0 to NN - 1 do
      begin
        Pv := I2; MxA := Abs(M[I2 * (NN + 1) + I2]);
        for Rw := I2 + 1 to NN - 1 do
          if Abs(M[Rw * (NN + 1) + I2]) > MxA then
          begin Pv := Rw; MxA := Abs(M[Rw * (NN + 1) + I2]); end;
        if Pv <> I2 then
          for Cl := I2 to NN do
          begin
            F := M[I2 * (NN + 1) + Cl];
            M[I2 * (NN + 1) + Cl] := M[Pv * (NN + 1) + Cl];
            M[Pv * (NN + 1) + Cl] := F;
          end;
        if Abs(M[I2 * (NN + 1) + I2]) < 1e-30 then Continue;
        for Rw := I2 + 1 to NN - 1 do
        begin
          Fac := M[Rw * (NN + 1) + I2] / M[I2 * (NN + 1) + I2];
          if Fac = 0 then Continue;
          for Cl := I2 to NN do
            M[Rw * (NN + 1) + Cl] := M[Rw * (NN + 1) + Cl]
                                     - Fac * M[I2 * (NN + 1) + Cl];
        end;
      end;
      for I2 := NN - 1 downto 0 do
      begin
        Acc := M[I2 * (NN + 1) + NN];
        for Cl := I2 + 1 to NN - 1 do
          Acc := Acc - M[I2 * (NN + 1) + Cl] * NodeB[Cl];
        if Abs(M[I2 * (NN + 1) + I2]) > 1e-30 then
          NodeB[I2] := Acc / M[I2 * (NN + 1) + I2]
        else
          NodeB[I2] := 0;
      end;
      { невязки → веса Хубера следующего прохода }
      for I2 := 0 to NP - 1 do
      begin
        K2 := NodeRef(ATimeSec[I2], F);
        Res[I2] := Dlt[I2] - (NodeB[K2] * (1 - F) + NodeB[K2 + 1] * F);
      end;
      if Pass < IRLS_PASSES then
      begin
        Sg := RobustSigma;
        for I2 := 0 to NP - 1 do
          if Abs(Res[I2]) <= HUBER_K * Sg then
            WPt[I2] := 1.0
          else
            WPt[I2] := HUBER_K * Sg / Abs(Res[I2]);
      end;
    end;
    for I2 := 0 to NP - 1 do
    begin
      K2 := NodeRef(ATimeSec[I2], F);
      AOut[I2] := AAlt[I2] - (NodeB[K2] * (1 - F) + NodeB[K2 + 1] * F);
    end;
  end;

begin
  { Красный канал снимаем ВСЕГДА и ПЕРВЫМ — до всех проверок: чистый DEM
    это независимый референс, а не производная коррекции, и папка заездов
    ему не нужна. }
  CaptureRouteDem;

  if (FRoutesFolder = '') or (FSelectedFit = '') then Exit;
  FitT0 := GetTickCount64;
  { ACancel=@FSnapCancel: деструктор карты взводит флаг и ждёт воркер —
    без досрочного выхода из банка Stop висел бы на WaitFor минутами
    (30+ файлов × GetRegion с HTTP до 30 с/тайл на холодном кэше). }
  BankStat := BuildFitBank(FRoutesFolder, FSelectedFit, FHmFetcher,
    FHeightmapZoom, Bank, Sel, @FFitCorrProgCur, @FFitCorrProgTotal,
    @FSnapCancel);
  if FSnapCancel then Exit;
  LogMain(Format('[fitcorr] bank: %s, %d ms',
    [BankStat, GetTickCount64 - FitT0]));
  if BankStat = '' then Exit;
  if (Sel < 0) or (Sel > High(Bank)) then Exit;
  FitT0 := GetTickCount64;

  { ПЕР-ФАЙЛОВАЯ нормировка уровня. Датум сажает на DEM ОБЩУЮ медиану
    банка, но пер-файловые уровни могут разъехаться (наблюдали −8.9 м у
    выбранного против ≈ +0.6 у остальных — дефект нивелирования,
    п. 4.2 сводки). Пока датум разъезжается, смешивать точки файлов в
    одном профиле нельзя: у КАЖДОГО файла вычитаем его СОБСТВЕННУЮ
    медиану (AltCal − Dem) — и из классификации настила, и из высот,
    укладываемых в профиль. Все точки приводятся к единому
    DEM-относительному уровню; абсолютный уровень ставит batch-lock по
    вершинам боевого меша (как и задуман). Прежний единый сдвиг
    (медиана выбранного, применённая к чужим) загонял почти все чужие
    точки в «настил» и смешивал в way-целях два уровня с разницей ~9 м
    — дельты усреднялись в кашу, полотно не резалось. }
  SetLength(MedR, Length(Bank));
  MedMin := 1e30;
  MedMax := -1e30;
  for R := 0 to High(Bank) do
  begin
    MedR[R] := MedianAltDem(Bank[R].AltCal, Bank[R].Dem);
    if R <> Sel then
    begin
      if MedR[R] < MedMin then MedMin := MedR[R];
      if MedR[R] > MedMax then MedMax := MedR[R];
    end;
  end;
  LogMain(Format(
    '[fitcorr] altcal-dem per-file med: selected=%.2f m, others %.2f..%.2f m',
    [MedR[Sel], MedMin, MedMax]));
  if (MedMax - MedR[Sel] > 4.0) or (MedR[Sel] - MedMin > 4.0) then
    LogMain('[fitcorr] WARNING — датум разъехался по файлам (>4 м); '
      + 'уровни нормированы пер-файлово, но форму дрейфа стоит '
      + 'проверить (п. 4.2)');

  { Наземные точки — только выбранный заезд (его профиль правит землю);
    настильные (превышение над DEM) — из ВСЕХ файлов банка: если выбранный
    прошёл ПОД мостом, настил корректируется чужим проездом ПО нему —
    датум общий, высоты сопоставимы. }
  N := 0;
  SetLength(Pts, Length(Bank[Sel].AltFit));
  SetLength(ConfF, Length(Bank[Sel].AltFit));
  SetLength(DriftCorr, Length(Bank[Sel].AltFit));
  if Bank[Sel].Synthetic then
    DriftCorr := Copy(Bank[Sel].AltCal, 0, Length(Bank[Sel].AltCal))
  else
    BuildDriftCorrected(Bank[Sel].Lat, Bank[Sel].Lon,
      Bank[Sel].AltFit, Bank[Sel].Dem, Bank[Sel].TimeSec, DriftCorr);
  BuildConf(Bank[Sel].Lat, Bank[Sel].Lon, ConfF);
  for I := 0 to High(Bank[Sel].AltFit) do
  begin
    Wp := FProj.Project(Bank[Sel].Lat[I], Bank[Sel].Lon[I]);
    Pts[N].X := Wp.X;
    Pts[N].Z := Wp.Z;
    { Цель грунта = ГОЛУБОЙ (сырой баро, снесённый сплайном дрейфа) минус
      высота устройства над дорогой. Грунт режется на «голубой − красный»:
      delta = DriftCorr − рельеф. Дрейф барометра снят сплайном; постоянные
      ~1 м «устройство над дорогой» сплайн уже вобрал (медиана fit−Dem), а
      визуальный лифт сфер сокращается в разнице красный↔голубой — поэтому
      CORR_DEVICE_LIFT_M по умолчанию 0 (вычитать метр ещё раз — увести
      грунт вниз). Константа оставлена тюнингом, если высота устройства
      реально иная.
      ВАЖНО: цель АБСОЛЮТНАЯ — Osm3dFitCorrection.LockLevel держит
      FLevelOffset = 0 и режет прямо на неё. Если здесь снова появится
      DEM-относительный профиль (baseline/датум), лок в FitCorrection надо
      возвращать вместе с ним — иначе уровень не с чем свести. }
    Pts[N].AltCal := DriftCorr[I] - CORR_DEVICE_LIFT_M;
    { «Настил моста» — по превышению голубого над рельефом: DriftCorr−Dem
      = локальное отклонение над сплайном; мост даёт большой плюс (едем ПО
      настилу, землю под ним не трогаем), лес/насыпь — минус/малое (земля). }
    IsDeck := (not Bank[Sel].Synthetic) and
      ((DriftCorr[I] - Bank[Sel].Dem[I]) > BRIDGE_DECK_RISE_M);
    Pts[N].BridgeDeck := IsDeck;
    Pts[N].Conf := ConfF[I];
    Inc(N);
  end;
  for R := 0 to High(Bank) do
  begin
    if FSnapCancel then Exit;
    if R = Sel then Continue;
    if Bank[R].Synthetic then Continue; { DEM не даёт высоту настила }
    SetLength(ConfF, Length(Bank[R].AltFit));
    SetLength(DriftR, Length(Bank[R].AltFit));
    BuildDriftCorrected(Bank[R].Lat, Bank[R].Lon,
      Bank[R].AltFit, Bank[R].Dem, Bank[R].TimeSec, DriftR);
    BuildConf(Bank[R].Lat, Bank[R].Lon, ConfF);
    for I := 0 to High(Bank[R].AltFit) do
      if (DriftR[I] - Bank[R].Dem[I]) > BRIDGE_DECK_RISE_M then
      begin
        if N = Length(Pts) then SetLength(Pts, N * 2 + 64);
        Wp := FProj.Project(Bank[R].Lat[I], Bank[R].Lon[I]);
        Pts[N].X := Wp.X;
        Pts[N].Z := Wp.Z;
        Pts[N].AltCal := DriftR[I] - CORR_DEVICE_LIFT_M;
        Pts[N].BridgeDeck := True;
        Pts[N].Conf := ConfF[I];
        Inc(N);
      end;
  end;
  SetLength(Pts, N);

  { Голубые сферы и столбец CSV — тот же DriftCorr выбранного заезда,
    что и цель грунта (голубой = ровно то, к чему режем землю). Привязка
    к точкам МАРШРУТА: Bank[Sel] и FRoute — один .fit; при равной длине
    по индексу, иначе ближайшая по гео (защита от разной фильтрации точек
    в загрузчиках). }
  SetLength(FPendingRouteAltCal, Length(FRoute));
  if Length(DriftCorr) = Length(FRoute) then
  begin
    for I := 0 to High(FRoute) do
      FPendingRouteAltCal[I] := DriftCorr[I]
  end
  else
    for I := 0 to High(FRoute) do
    begin
      if FSnapCancel then Exit;
      DeckN := -1;               { переиспользуем как индекс лучшего }
      V := 1e30;                 { мин. дист² (V: Double уже объявлен) }
      for J := 0 to High(Bank[Sel].Lat) do
      begin
        Wp.X := Bank[Sel].Lat[J] - FRoute[I].Lat;
        Wp.Z := Bank[Sel].Lon[J] - FRoute[I].Lon;
        if Sqr(Wp.X) + Sqr(Wp.Z) < V then
        begin
          V := Sqr(Wp.X) + Sqr(Wp.Z);
          DeckN := J;
        end;
      end;
      if (DeckN >= 0) and (DeckN <= High(DriftCorr)) then
        FPendingRouteAltCal[I] := DriftCorr[DeckN]
      else if I <= High(FRouteAltM) then
        FPendingRouteAltCal[I] := FRouteAltM[I]
      else
        FPendingRouteAltCal[I] := 0;
    end;

  DeckN := 0;
  for I := 0 to N - 1 do
    if Pts[I].BridgeDeck then Inc(DeckN);
  { Старый TFitCorrection больше НЕ строим (деформация мешей отключена).
    FIT-СЛОЙ строим ТОЛЬКО когда хост разрешил его построение
    (FFitLayerBuild): иначе датум всей папки заездов (+ чтение 30+
    CSV-кэшей) уйдёт впустую (лёгкий путь страницы маршрутов слой не
    использует — ему хватает голубого профиля выбранного заезда).
    Слой — чисто рантайм-данные физики (GroundYAt): в gen-hash и в
    геометрию тайлов он не входит ни в одном из путей, дисковый кэш
    от списка фитов не зависит. Pts выше остаётся для диагностики
    (deck/warmup). }
  if FFitLayerBuild and (FFitPhysLayer = nil) then
  begin
    { Слот физики уже заполнен из Session.Create — не строим второй
      экземпляр (PublishFitCorrection всё равно бы его выбросила; под
      нагрузкой генерации тайлов построение занимало до 2 мин CPU). }
    FreeAndNil(FPendingFitLayer);
    FPendingFitLayer := TFitHeightLayer.Create;
    LogMain('[fitlayer] ' + BuildFitHeightLayer(FRoutesFolder, FSelectedFit,
      FHmFetcher, FHeightmapZoom, FPendingFitLayer, nil));
  end;
  R := 0;
  for I := 0 to N - 1 do
    if Pts[I].Conf < 0.999 then Inc(R);
  LogMain(Format(
    '[fitcorr] profile: %d pts (%d deck, %d warmup-attenuated) '
    + 'from %s, %d ms (off-thread)',
    [N, DeckN, R, FSelectedFit, GetTickCount64 - FitT0]));
  FFitCorrPending := True;   { PublishFitCorrection довершит на main }
end;

{ Публикация готовых результатов фит-воркера на ГЛАВНОМ потоке (Queue из
  TFitCorrOnlyWorker; OnRouteSnapDone тоже дёргает её — no-op, пока флаги
  готовности не взведены): голубой профиль высот (FRouteAltCal), красный
  DEM (FRouteDem) и FIT-слой физики (FFitPhysLayer). Пусто, если воркер
  ничего не построил (нет папки/файла) — тогда no-op. }
procedure TOsm3dStreamingMap.PublishFitCorrection;
begin
  if FDestroying then Exit;
  { Красный канал публикуем ДО гейта FFitCorrPending: DEM снимается и без
    папки заездов, а FFitCorrPending взводится только когда коррекция реально
    построена. }
  if FRouteDemPending then
  begin
    FRouteDemPending := False;
    FRouteDem := FPendingRouteDem;
    FPendingRouteDem := nil;
    MarkSphereDirty(0);
  end;

  if not FFitCorrPending then Exit;
  FFitCorrPending := False;

  { Голубые сферы/CSV — высоты маршрута из выбранного заезда. Публикуем
    ВСЕГДА (это профиль высот, а не деформация мешей). }
  FRouteAltCal := FPendingRouteAltCal;
  FPendingRouteAltCal := nil;
  MarkSphereDirty(2);   { голубой — фит-коррекция готова, пересобрать сцену }

  { FIT-слой — рантайм-данные ФИЗИКИ (GroundYAt), в меши и gen-hash не идёт.
    Ставим воркерский слой в физический слот, только если он пуст: боевой
    путь ставит слой раньше, в Session.Create. Заменять занятый слот нельзя
    заодно и по гонке: GroundYAt читает его без блокировки (главный поток,
    но free под ним недопустим). Лишний экземпляр просто выбрасываем. }
  if FPendingFitLayer <> nil then
  begin
    if FFitPhysLayer = nil then
      FFitPhysLayer := FPendingFitLayer
    else
      FreeAndNil(FPendingFitLayer);
    FPendingFitLayer := nil;
  end;
end;

procedure TOsm3dStreamingMap.SetFitCorrection(ACorr: TFitCorrection);
begin
  if FFitCorr = ACorr then Exit;
  FFitCorr.Free;
  FFitCorr := ACorr;
end;

procedure TOsm3dStreamingMap.SetFitPhysLayer(ALayer: TFitHeightLayer);
begin
  if FFitPhysLayer = ALayer then Exit;
  FFitPhysLayer.Free;
  FFitPhysLayer := ALayer;
end;

procedure TOsm3dStreamingMap.SwapToGroundMesh(ALt: TLoadTile; const AHeights: THeightArray);
var W, P0, P1: TVector3; SizeX, SizeZ: Single; LL: TLatLon; Box: TLatLonBox;
  CorrH: THeightArray;
  NewSc: TCastleScene;
  NewTxt: TTextNode; NewCoord: TCoordinateNode;
  NewInterp: TCoordinateInterpolatorNode; NewTimer: TTimeSensorNode;
begin
  if ALt = nil then Exit;
  { Размеры и центр — из СПРОЕЦИРОВАННОГО бокса тайла: общая кромка соседей
    (один lat/lon) проецируется в одну мировую координату, кромки совпадают
    побитно. Квадрат EdgeMetersAt(центральной широты) давал у вертикальных
    соседей разные размеры (меркатор) — планарные щели вдоль W-E границ. }
  Box := FCache.Grid.TileBox(ALt.Id);
  LL.Lat := Box.MinLat;  LL.Lon := Box.MinLon;
  P0 := FProj.Project(LL);
  LL.Lat := Box.MaxLat;  LL.Lon := Box.MaxLon;
  P1 := FProj.Project(LL);
  W  := Vector3((P0.X + P1.X) * 0.5, 0.0, (P0.Z + P1.Z) * 0.5);
  SizeX := Abs(P1.X - P0.X);
  SizeZ := Abs(P1.Z - P0.Z);
  ALt.CX := W.X;  ALt.CZ := W.Z;   { центр меша = середина бокса (не TileCenter) }
  { диагностика швов: мировые координаты краёв. Сверять с соседями: X-края
    у (X±1,Y), Z-края у (X,Y±1) — общая кромка обязана совпасть побитно. }
  LogMain(Format(
    '[stub] %d:%d mesh world X=%.4f..%.4f Z=%.4f..%.4f (SizeX=%.4f SizeZ=%.4f)',
    [ALt.Id.TX, ALt.Id.TY,
     W.X - SizeX * 0.5, W.X + SizeX * 0.5,
     W.Z - SizeZ * 0.5, W.Z + SizeZ * 0.5, SizeX, SizeZ]));
  { СТАРАЯ FIT-коррекция высот загрузочного меша УДАЛЕНА — FIT печётся в
    геометрию тайла (FIT-слой фетчера). Плейсхолдер строится на сыром DEM и
    мгновенно заменяется готовым скорректированным тайлом. AHeights const → копия. }
  CorrH := Copy(AHeights, 0, Length(AHeights));
  NewSc := BuildGroundLoadingScene(W, SizeX, SizeZ, CorrH,
                                   LOAD_MESH_GRID, NewTxt, NewCoord, NewInterp, NewTimer);
  FLoadOwner.Add(NewSc);
  if ALt.Scene <> nil then begin FLoadOwner.Remove(ALt.Scene); ALt.Scene.Free; end;
  ALt.Scene := NewSc;  ALt.Text := NewTxt;
  ALt.BoxT := nil; ALt.TxtT := nil; ALt.BoxMat := nil;   { узлы коробки освобождены }
  ALt.FloorDone := True;  ALt.Last := '';
  { состояние морфа: текущие высоты = цель, анимации нет }
  ALt.Coord := NewCoord;  ALt.Interp := NewInterp;  ALt.Timer := NewTimer;
  ALt.MeshN := LOAD_MESH_GRID;
  ALt.MeshSizeX := SizeX;  ALt.MeshSizeZ := SizeZ;
  ALt.HCur := Copy(CorrH, 0, Length(CorrH));
  ALt.MeshDetail := False;
end;

function TOsm3dStreamingMap.HeightsDiffer(const A, B: THeightArray): Boolean;
var I: Integer;
begin
  Result := True;
  if Length(A) <> Length(B) then Exit;
  for I := 0 to High(A) do
    if Abs(A[I] - B[I]) > 0.01 then Exit;
  Result := False;
end;

{ Запуск X3D-морфа высот к новым (детальным): кейфреймы интерполятора (key0=текущие,
  key1=новые) + старт TimeSensor. CGE интерполирует координаты в event-графе. }
procedure TOsm3dStreamingMap.StartMeshMorph(ALt: TLoadTile; const AHeights: THeightArray);
var KV: array of TVector3; StepX, StepZ, OX, OZ: Single; IX, IZ, N: Integer;
  MorphH: THeightArray;
begin
  MorphH := Copy(AHeights, 0, Length(AHeights));
  { СТАРАЯ FIT-коррекция высот морф-меша УДАЛЕНА — FIT печётся в геометрию. }
  if (ALt = nil) or (ALt.Interp = nil) or (ALt.Timer = nil) or (ALt.MeshN < 2) then Exit;
  N := ALt.MeshN;
  if (Length(ALt.HCur) <> N*N) or (Length(AHeights) <> N*N) then Exit;
  StepX := ALt.MeshSizeX / (N - 1);
  StepZ := ALt.MeshSizeZ / (N - 1);
  OX := ALt.CX - ALt.MeshSizeX * 0.5;
  OZ := ALt.CZ - ALt.MeshSizeZ * 0.5;
  SetLength(KV, 2 * N * N);
  for IZ := 0 to N - 1 do
    for IX := 0 to N - 1 do
    begin
      { зеркалирование X — 1:1 с BuildGroundLoadingScene (запад = +X) }
      KV[IZ*N + (N - 1 - IX)] :=
        Vector3(OX + (N - 1 - IX)*StepX, ALt.HCur[IZ*N + IX], OZ + IZ*StepZ);
      KV[N*N + IZ*N + (N - 1 - IX)] :=
        Vector3(OX + (N - 1 - IX)*StepX, MorphH[IZ*N + IX], OZ + IZ*StepZ);
    end;
  ALt.Interp.FdKeyValue.Send(KV);
  ALt.Timer.Enabled := True;
  ALt.Timer.Start(False);   { проиграть морф один раз }
end;

procedure TOsm3dStreamingMap.HandleBlockPhase(const ABlock: TBlockId;
  APhase: TBlockPhase; const Stage: string; Completed, Total: Int64);
begin
  { Вызывается из ВОРКЕРА генерации. При teardown не трогаем стример. }
  if FDestroying or (FStreamer = nil) then Exit;
  FStreamer.SetBlockPhase(ABlock, APhase, Stage, Completed, Total);
end;

{ ВНИМАНИЕ (CGE): узлы box/text/billboard тут собраны по X3D-паттерну
  (как RebuildSphereScene). Проверить у себя имена: TMaterialNode.Transparency,
  TTextNode.SetText / .FontStyle, TFontStyleNode.Size, TBillboardNode.AxisOfRotation. }
function TOsm3dStreamingMap.MakeLoadingLabel(Root: TX3DRootNode;
  const APos: TVector3; AFontSize: Single;
  out ATextNode: TTextNode): TTransformNode;
var
  Font: TFontStyleNode;
  TxtMat: TMaterialNode;
  TxtApp: TAppearanceNode;
  TxtShape: TShapeNode;
  Bill: TBillboardNode;
begin
  ATextNode := TTextNode.Create;
  ATextNode.SetText(['']);
  Font := TFontStyleNode.Create;
  Font.Size := AFontSize;                    { шрифт пропорционален тайлу }
  { по центру по ширине -> надпись центрируется на точке привязки (и не
    «уплывает» при повороте billboard) }
  Font.Justify := fjMiddle;
  ATextNode.FontStyle := Font;
  TxtMat := TMaterialNode.Create;
  TxtMat.EmissiveColor := Vector3(1, 1, 1);
  TxtApp := TAppearanceNode.Create;
  TxtApp.Material := TxtMat;
  TxtShape := TShapeNode.Create;
  TxtShape.Geometry := ATextNode;
  TxtShape.Appearance := TxtApp;
  Bill := TBillboardNode.Create;
  Bill.AxisOfRotation := Vector3(0, 0, 0);
  Bill.AddChildren(TxtShape);
  Result := TTransformNode.Create;
  Result.Translation := APos;
  Result.AddChildren(Bill);
  Root.AddChildren(Result);
end;

function TOsm3dStreamingMap.BuildLoadingScene(const ACenter: TVector3;
  ASizeXZ, ABoxH, AFloorY: Single; out ATextNode: TTextNode;
  out ABoxT, ATxtT: TTransformNode;
  out ABoxMat: TMaterialNode): TCastleScene;
var
  Root: TX3DRootNode;
  BoxGeom: TBoxNode;
  BoxApp: TAppearanceNode;
  BoxShape: TShapeNode;
  Sc: TCastleScene;
  CY: Single;
begin
  Root := TX3DRootNode.Create;
  CY := AFloorY + ABoxH * 0.5;                 { центр коробки по Y }

  { полупрозрачная коробка размером С ТАЙЛ }
  BoxGeom := TBoxNode.Create;
  BoxGeom.Size := Vector3(ASizeXZ, ABoxH, ASizeXZ);
  ABoxMat := TMaterialNode.Create;
  ABoxMat.EmissiveColor := Vector3(0.15, 0.45, 0.90);   { грузится — синий }
  ABoxMat.Transparency  := 0.65;                { надпись внутри видна сквозь }
  BoxApp := TAppearanceNode.Create;  BoxApp.Material := ABoxMat;
  BoxShape := TShapeNode.Create;
  BoxShape.Geometry := BoxGeom;  BoxShape.Appearance := BoxApp;
  ABoxT := TTransformNode.Create;
  ABoxT.Translation := Vector3(ACenter.X, CY, ACenter.Z);
  ABoxT.AddChildren(BoxShape);
  Root.AddChildren(ABoxT);

  { КРУПНАЯ надпись ВНУТРИ коробки (в центре), billboard — лицом к камере }
  ATxtT := MakeLoadingLabel(Root, Vector3(ACenter.X, CY, ACenter.Z),
    ASizeXZ * LOAD_TEXT_FACTOR, ATextNode);

  Sc := TCastleScene.Create(Self);
  Sc.Load(Root, True);
  Sc.Collides := False;
  Sc.Pickable := False;
  Sc.Exists   := True;
  Sc.ReceiveShadowVolumes := False;  { в volume-проход тени байка не входим }
  Result := Sc;
end;

function TOsm3dStreamingMap.LoadPhaseInfo(const AId: TGeoTileId;
  out AStage: string; out APct: Integer): Boolean;
var Progress: TBlockPhaseRec;
begin
  AStage := ''; APct := -1; Result := False;
  if (FStreamer = nil) or not FStreamer.BlockProgressForTile(AId, Progress) then Exit;
  if Progress.Phase = bpWait then Exit;
  AStage := UiText(Progress.Stage);
  if Progress.Total > 0 then
    APct := EnsureRange(Integer(Progress.Completed * 100 div Progress.Total), 0, 100);
  Result := AStage <> '';
end;

function TOsm3dStreamingMap.LoadPhaseText(const AId: TGeoTileId): string;
var Stage: string; Pct: Integer;
begin
  Result := '';
  if LoadPhaseInfo(AId, Stage, Pct) then
  begin
    Result := Stage;
    if Pct >= 0 then Result := Format('%s %d%%', [Stage, Pct]);
  end;
end;

procedure TOsm3dStreamingMap.EnsureLoadTile(const AId: TGeoTileId);
var
  Key: string;
  Lt:  TLoadTile;
  LL:  TLatLon;
  W:   TVector3;
  Sc:  TCastleScene;
  Txt: TTextNode;
  BoxT, TxtT: TTransformNode;
  BoxMat: TMaterialNode;
  SizeXZ, FloorY: Single;
  HaveFloor: Boolean;
begin
  if (FLoadTiles = nil) or (FLoadOwner = nil) then Exit;
  Key := AId.ToString;
  if FLoadTiles.ContainsKey(Key) then Exit;
  if TileSceneReady(AId) then Exit;
  LL := FCache.Grid.TileCenter(AId);
  W  := FProj.Project(LL);
  SizeXZ := FCache.Grid.EdgeMetersAt(LL.Lat);        { сторона тайла в метрах }

  { пол — из кэша высот (без HTTP). Пусто -> фоново подгрузить, перепроверим в Update. }
  FloorY := 0.0;  HaveFloor := False;
  if FHmFetcher <> nil then
  begin
    HaveFloor := FHmFetcher.TryHeightCached(LL, LOAD_FLOOR_ZOOM, FloorY);
    if not HaveFloor then FHmFetcher.RequestHeightLoad(LL, LOAD_FLOOR_ZOOM);
    { весь регион тайла на z10 — в фон: первый грид меша соберётся из кэша
      на ближайшем тике, а не «когда повезёт с соседями» }
    FHmFetcher.RequestRegionLoad(FCache.Grid.TileBox(AId), LOAD_FLOOR_ZOOM);
  end;

  Sc := BuildLoadingScene(Vector3(W.X, 0.0, W.Z), SizeXZ, LOAD_BOX_HEIGHT_M,
                          FloorY, Txt, BoxT, TxtT, BoxMat);
  FLoadOwner.Add(Sc);
  Lt := TLoadTile.Create;
  Lt.Id := AId;  Lt.Scene := Sc;  Lt.Text := Txt;  Lt.Last := '';
  Lt.CX := W.X;  Lt.CZ := W.Z;  Lt.BoxH := LOAD_BOX_HEIGHT_M;
  Lt.BoxT := BoxT;  Lt.TxtT := TxtT;  Lt.BoxMat := BoxMat;  Lt.GreenDone := False;
  Lt.FloorDone := HaveFloor;
  Lt.NextFloor := GetTickCount64 + LOAD_FLOOR_RECHECK_MS;
  Lt.MeshDone := False;
  Lt.NextMesh := GetTickCount64 + LOAD_FLOOR_RECHECK_MS;
  FLoadTiles.AddOrSetValue(Key, Lt);
end;

procedure TOsm3dStreamingMap.RemoveLoadTile(const AKey: string);
var Lt: TLoadTile;
begin
  if (FLoadTiles = nil) or (not FLoadTiles.TryGetValue(AKey, Lt)) then Exit;
  FLoadTiles.Remove(AKey);
  if Lt.Scene <> nil then
  begin
    if FLoadOwner <> nil then FLoadOwner.Remove(Lt.Scene);
    Lt.Scene.Free;
  end;
  Lt.Free;
end;

procedure TOsm3dStreamingMap.FreeAllLoadTiles;
var Lt: TLoadTile;
begin
  if FLoadTiles = nil then Exit;
  for Lt in FLoadTiles.Values do Lt.Free;   { сцены освобождает Self (Owner) }
  FreeAndNil(FLoadTiles);
end;

procedure TOsm3dStreamingMap.UpdateLoadTiles;
var
  Key: string;
  Lt:  TLoadTile;
  Txt: string;
  Gone: TStringList;
  I:   Integer;
  Now64: QWord;
  LL:  TLatLon;
  CY:  Single;
  GridH: THeightArray;
  ZReq, GridZ: Integer;

  { подпись кромки грида заглушки: строка 0 = юг (MinLat), столбец 0 = запад }
  function StubEdgeSig(const H: THeightArray; N: Integer; AEdge: Char): string;
  var
    I: Integer;
    Row: array of Single;
  begin
    SetLength(Row, N);
    for I := 0 to N - 1 do
      case AEdge of
        'S': Row[I] := H[I];
        'N': Row[I] := H[(N - 1) * N + I];
        'W': Row[I] := H[I * N];
      else
        Row[I] := H[I * N + (N - 1)];   { 'E' }
      end;
    Result := Format('%s(%.3f,%.3f,%.3f|%.8x)',
      [AEdge, Row[0], Row[N div 2], Row[N - 1],
       crc32(0, PByte(@Row[0]), N * SizeOf(Single))]);
  end;

begin
  if (FLoadTiles = nil) or (FLoadTiles.Count = 0) then Exit;
  Now64 := GetTickCount64;
  Gone := TStringList.Create;
  try
    for Key in FLoadTiles.Keys do
    begin
      Lt  := FLoadTiles[Key];
      if TileSceneReady(Lt.Id) then begin Gone.Add(Key); Continue; end;  { смонтирован }
      { текст прогресса }
      Txt := LoadPhaseText(Lt.Id);
      if (Txt <> Lt.Last) and (Lt.Text <> nil) then
      begin
        Lt.Last := Txt;
        Lt.Text.SetText([Txt]);
      end;
      { готов к показу (модель в RAM, ждёт монтажа) -> коробка зеленеет }
      if (not Lt.GreenDone) and (not Lt.MeshDone) and (Lt.BoxMat <> nil)
         and (FStreamer <> nil) and FStreamer.TileReadyToShow(Lt.Id) then
      begin
        Lt.GreenDone := True;
        Lt.BoxMat.EmissiveColor := Vector3(0.15, 0.85, 0.25);   { готов — зелёный }
      end;
      { пол — раз в 3с перепроверяем кэш высот, пока не установлен; когда высота
        появилась (её подгрузил gen или RequestHeightLoad) — ставим коробку на неё }
      if (not Lt.FloorDone) and (Now64 >= Lt.NextFloor) then
      begin
        Lt.NextFloor := Now64 + LOAD_FLOOR_RECHECK_MS;
        if FHmFetcher <> nil then
        begin
          LL := FCache.Grid.TileCenter(Lt.Id);
          if FHmFetcher.TryHeightCached(LL, LOAD_FLOOR_ZOOM, CY) then
          begin
            Lt.FloorDone := True;
            if Lt.BoxT <> nil then
              Lt.BoxT.Translation := Vector3(Lt.CX, CY + Lt.BoxH * 0.5, Lt.CZ);
            if Lt.TxtT <> nil then
              Lt.TxtT.Translation := Vector3(Lt.CX, CY + Lt.BoxH * 0.5, Lt.CZ);
          end;
        end;
      end;
      { высоты считаются в ФОНЕ (фетчер). На main — только запрос грида и
        применение готового массива. Тяжёлое сэмплирование не блокирует main.

        Тракт двухфазный, как и задумано:
          фаза 1 (до MeshDone): грид на грубом LOAD_FLOOR_ZOOM — z10 почти
            всегда в кэше (суперы/предыдущие сессии), меш встаёт мгновенно
            «из того, что есть»;
          фаза 2 (после MeshDone, до MeshDetail): грид на детальном
            FHeightmapZoom — тайлы z13 догружаются фоном (RequestRegionLoad,
            дедуп внутри), воркер собирает сетку строго из кэша, и по
            готовности StartMeshMorph анимирует меш к детальным высотам.
        Раньше ОБЕ фазы просили LOAD_FLOOR_ZOOM: детальный запрос не
        апался никогда, ветка морфа была мертва — заглушка так и жила на
        z10 до монтажа настоящего тайла. }
      if FHmFetcher <> nil then
      begin
        if (not Lt.MeshDetail) and (Now64 >= Lt.NextMesh) then
        begin
          Lt.NextMesh := Now64 + LOAD_FLOOR_RECHECK_MS;
          if not Lt.MeshDone then
            ZReq := LOAD_FLOOR_ZOOM
          else
            ZReq := FHeightmapZoom;   { деталь после первого меша }
          FHmFetcher.RequestRegionLoad(FCache.Grid.TileBox(Lt.Id), ZReq);
          FHmFetcher.RequestHeightGrid(Lt.Id.ToString, FCache.Grid.TileBox(Lt.Id),
            LOAD_MESH_GRID, ZReq);
        end;
        { забрать готовый грид и применить }
        if FHmFetcher.TryTakeHeightGrid(Lt.Id.ToString, GridH, GridZ) then
        begin
          { диагностика швов: фактический зум выдачи + подписи кромок
            (первая/средняя/последняя высота + CRC32 ребра). Сетка грида:
            строка 0 = ЮГ (MinLat). Сверять: S тайла (X,Y) с N тайла
            (X,Y+1) — TY растёт на юг; E тайла (X,Y) с W тайла (X+1,Y). }
          LogMain(Format('[stub] %d:%d grid z=%d n=%d edges %s %s %s %s',
            [Lt.Id.TX, Lt.Id.TY, GridZ, LOAD_MESH_GRID,
             StubEdgeSig(GridH, LOAD_MESH_GRID, 'N'),
             StubEdgeSig(GridH, LOAD_MESH_GRID, 'S'),
             StubEdgeSig(GridH, LOAD_MESH_GRID, 'W'),
             StubEdgeSig(GridH, LOAD_MESH_GRID, 'E')]));
          if not Lt.MeshDone then
          begin
            SwapToGroundMesh(Lt, GridH);
            Lt.MeshDone := True;
          end
          else if (not Lt.MeshDetail) and HeightsDiffer(GridH, Lt.HCur) then
          begin
            LogMain(Format('[stub] %d:%d morph start -> z=%d',
              [Lt.Id.TX, Lt.Id.TY, GridZ]));
            StartMeshMorph(Lt, GridH);   { X3D-морф к детальным }
            Lt.HCur := Copy(GridH, 0, Length(GridH));
            Lt.MeshDetail := True;
          end;
        end;
      end;
    end;
    for I := 0 to Gone.Count - 1 do RemoveLoadTile(Gone[I]);
  finally
    Gone.Free;
  end;
end;

procedure TOsm3dStreamingMap.HostShowBase(const AId: TLodCellId; AOn: Boolean);
var
  Key: string;
  CT:  TCacheTile;
begin
  Key := CellGeoId(AId).ToString;
  if AOn then FTreeWantBase.AddOrSetValue(Key, True)
         else FTreeWantBase.Remove(Key);
  { Detail is only ever mounted by the streamer's keyhole; light it when the
    ring shows this cell and the tile is resident. Cells with no mounted
    detail render nothing — the far-ground clipmap covers them. }
  if FTileIndex.TryGetValue(CellGeoId(AId).ToKey, CT) then
    if AOn then ActivateTile(CT) else DeactivateTile(CT)
  else if AOn then
    EnsureLoadTile(CellGeoId(AId));   { тайл затребован, но ещё не смонтирован }
  if not AOn then RemoveLoadTile(Key);
end;

procedure TOsm3dStreamingMap.HostReleaseBase(const AId: TLodCellId);
var
  Key: string;
  CT:  TCacheTile;
begin
  if FDestroying then Exit;     { teardown frees the scenes }
  Key := CellGeoId(AId).ToString;
  FTreeWantBase.Remove(Key);
  RemoveLoadTile(Key);
  if FTileIndex.TryGetValue(CellGeoId(AId).ToKey, CT) then
    DeactivateTile(CT);          { detail stays resident in the cache }
end;

{ Detail just mounted for a base tile (streamer keyhole). If the ring shows
  this cell, light the real tile now — HostShowBase won't re-fire on its own
  (the cell's visibility hasn't changed). }
function TOsm3dStreamingMap.TileSceneReady(const AId: TGeoTileId): Boolean;
var CT: TCacheTile;
begin
  Result := FTileIndex.TryGetValue(AId.ToKey, CT) and (CT.Scene <> nil) and
    (InterlockedCompareExchange(CT.Scene.MountFinished, 0, 0) <> 0) and
    CT.Scene.MountLoaded;
end;

procedure TOsm3dStreamingMap.SwapGreenToDetail(const AId: TGeoTileId);
var
  Key: string;
  CT:  TCacheTile;
begin
  if not TileSceneReady(AId) then Exit;
  Key := AId.ToString;
  if FTileIndex.TryGetValue(AId.ToKey, CT) and FTreeWantBase.ContainsKey(Key) then
    ActivateTile(CT);
end;

{ eviction — detach shared nodes, then full release }

{ Take a batch fully out of the cache and the scene tree and release
  every object it owns. Order matters:

    1. detach the batch subtree from the map, un-cascade + de-index
       every tile, drop the batch from the live list — nothing renders
       or culls it from here on;
    2. strip every reference to a pinned FAsmCache node out of the
       batch's X3D graph (DetachSharedFrom on each root). This is the
       key step: afterwards the graph reaches only tile-UNIQUE nodes;
    3. free the tile scenes — Load'ed OwnsRootNode=False, so this frees
       the TCastleScene and its owned FIT clusters, runs UnregisterScene
       / resource-unprepare over the now tile-unique graph ONLY, and
       does NOT free the X3D nodes;
    4. free Assembled — owns and frees the tile-unique X3D graph;
    5. free the Owner transform and the wrappers.

  Because step 2 removed the shared atlas / effect / appearance / surface
  nodes from the graph, steps 3-4 never touch them — the shared nodes
  and the still-resident sibling tiles that USE them are untouched, so
  no missing-texture flicker. KeepExistingBegin already guarantees the
  shared node objects themselves survive. }
procedure TOsm3dStreamingMap.EvictBatch(ABatch: TCacheBatch);
var
  CT: TCacheTile;
  I:  Integer;
  RetiredTileKeys: array of Int64;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1333);{$ENDIF}
  if ABatch = nil then Exit;

  { DEFER eviction while ANY tile in this batch still has shadow work in
    flight — a gen job queued or being rasterised, or a finished mask waiting
    to be applied. Freeing the tile now would free its mask texture node
    while the worker / drain still references it -> use-after-free (the swap
    in Update would touch freed memory). The batch is left FULLY intact in
    FBatchList; the next purge pass retries it. A far batch (the only kind
    purged) gets no new shadow jobs, so its queue drains within a few frames
    and it evicts cleanly then. Empty batches have no tiles, so this is a
    no-op for the produced-no-tiles fast path. }
  if FStreamer <> nil then
    for CT in ABatch.Tiles do
      if FStreamer.HasPendingShadow(CT.Tile.ToString) then Exit;

  { То же — отложить, если сцена тайла ещё наполняется mount-воркером: освободить
    её сейчас значило бы дёрнуть сцену в момент Scene.Load. Дальний батч новых
    задач монтажа не получает, поэтому воркер добьёт её за кадр-два, и тогда батч
    выгрузится чисто. НЕблокирующая замена прежнему FlushMountWorker (см. ниже). }
  for CT in ABatch.Tiles do
    if (CT.Scene <> nil) and
       (InterlockedCompareExchange(CT.Scene.MountFinished, 0, 0) = 0) then
      Exit;

  { 1 — out of the render tree and the live set. }
  if ABatch.Owner <> nil then
    Remove(ABatch.Owner);
  for CT in ABatch.Tiles do
  begin
    if STREAM_DIAG_VERBOSE and (FAsmCache <> nil)
       and (FAsmCache.GetTileMaskTexByKey(CT.Tile.ToString) <> nil) then
      LogMain(Format('SH evict key=%s ct=%x g=%d node=%x',
        [CT.Tile.ToString, PtrUInt(CT), CT.MountGen,
         PtrUInt(FAsmCache.GetTileMaskTexByKey(CT.Tile.ToString))]));
    DeactivateTile(CT);                     { Exists := False + cascade }
    FTileIndex.Remove(CT.Tile.ToKey);       { out of the cache index }
    FTileIndexStr.Remove(CT.Tile.ToString); { строковое зеркало — синхронно }
    if FAsmCache <> nil then
      FAsmCache.DetachTileMaskTexture(CT.Tile);  { keep silhouettes, drop live tex }
    if FStreamer <> nil then
    begin
      FStreamer.DropTileShadow(CT.Tile.ToString); { cancel any pending gen/upload }
      FStreamer.NotifySceneEvicted(CT.Tile);      { слот -> консистентно "выгружен" }
    end;
  end;

  { vegetation: trees/shrubs were AddTile'd per tile centre in MountBatch.
    Drop them with the ground — else the freed tile leaves its trees drawn
    over the green-stub fallback ("trees, no ground"), and re-streaming the
    tile AddTile's them a second time (doubling up). }
  { ВАЖНО: снимаем растительность ТОЛЬКО для тайлов, которыми батч реально
    ВЛАДЕЕТ (ABatch.Tiles), а НЕ для всех Assembled.Tiles. RemoveTile ключуется
    по центру и удаляет ВСЕ записи с этим центром; у избыточного (пустого) батча
    центры Assembled.Tiles совпадают с резидентной копией, и снятие снесло бы её
    деревья. Батч, смонтировавший 0 тайлов, снимает 0. }
  if FTreeRenderer <> nil then
    for CT in ABatch.Tiles do
    begin
      if TREE_DIAG then
        LogMain(Format('TREEDIAG remove c=(%.0f,%.0f)', [CT.CenterX, CT.CenterZ]));
      FTreeRenderer.RemoveTile(CT.CenterX, CT.CenterZ);
      if FProceduralRenderer <> nil then
        FProceduralRenderer.RemoveTile(CT.CenterX, CT.CenterZ);
      if FShrubRenderer <> nil then
        FShrubRenderer.RemoveTile(CT.CenterX, CT.CenterZ);
    end;

  if FGrassRenderer <> nil then
    for CT in ABatch.Tiles do
      FGrassRenderer.RemoveTile(CT.CenterX, CT.CenterZ);

  { BUILDING_OBSTACLE: drop footprints with the tile (same ToKey as mount). }
  if FBuildingObstacles <> nil then
  begin
    SetLength(RetiredTileKeys, ABatch.Tiles.Count);
    for I := 0 to ABatch.Tiles.Count - 1 do
      RetiredTileKeys[I] := ABatch.Tiles[I].Tile.ToKey;
    FBuildingObstacles.RemoveTiles(RetiredTileKeys);
  end;

  FBatchList.Remove(ABatch);

  { 2 — unlink every shared FAsmCache node from this batch's graph, so
    the frees below cannot touch a node a sibling tile still USE-shares. }
  if (FAsmCache <> nil) and (ABatch.Assembled <> nil) then
  begin
    for I := 0 to High(ABatch.Assembled.Tiles) do
      FAsmCache.DetachSharedFrom(ABatch.Assembled.Tiles[I].Root);
    FAsmCache.DetachSharedFrom(ABatch.Assembled.GlobalRoot);
  end;

  { 3 — free the tile scenes (tile-unique graph only now). Батч с незавершённым
    монтажом уже отложен выше (defer), как и с тенями — здесь сцены гарантированно
    не на лету, блокирующий flush не нужен (он остался только в TeardownAll и
    деструкторе, где defer недопустим). }
  for CT in ABatch.Tiles do
    if CT.Scene <> nil then
    begin
      if ABatch.Owner <> nil then
        ABatch.Owner.Remove(CT.Scene);
      CT.Scene.Free;                        { + owned FIT clusters }
      CT.Scene := nil;
    end;

  { 4 — free the assembled graph (tile-unique nodes), AFTER the scenes
    that referenced it are gone. }
  if ABatch.Assembled <> nil then
  begin
    ABatch.Assembled.Free;
    ABatch.Assembled := nil;
  end;

  { 5 — Owner transform + lightweight wrappers. }
  if ABatch.Owner <> nil then
  begin
    ABatch.Owner.Free;
    ABatch.Owner := nil;
  end;
  ABatch.Free;

  { Resident set shrank and this batch's effects (with their wind fields)
    are freed — rebuild the wind arrays from the remaining live batches.
    ABatch is already out of FBatchList (step 1), so the rebuild skips it. }
  RefreshGroundWindFields;
end;

{ Evict batches that have drifted far behind and hold no active tile.
  A batch with ActiveCount > 0 has visible tiles and is NEVER evicted —
  the resident window is protected. }
procedure TOsm3dStreamingMap.PurgeFarBatches(const ACamPos: TVector3);
var
  I, J: Integer;
  B:    TCacheBatch;
  Dist, D1, D2: Single;
  Far:  TCacheBatchList;
  Pressure: Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(846);{$ENDIF}
  Pressure := MemOverBudget;
  Far := TCacheBatchList.Create;
  try
    for I := 0 to FBatchList.Count - 1 do
    begin
      B := FBatchList[I];
      { Has a visible tile -> protected, never a purge candidate. }
      if B.ActiveCount > 0 then Continue;
      Dist := Hypot(ACamPos.X - B.CX, ACamPos.Z - B.CZ);
      if Dist > FStreamer.SceneUnloadRadius then
        Far.Add(B);
    end;
    { Давление памяти: дополнительно даунгрейдим до 2 САМЫХ ДАЛЬНИХ
      неактивных батчей за проход (их тайлы вернутся превью-сценами). }
    if Pressure then
    begin
      D1 := 0;
      for J := 1 to 2 do
      begin
        B := nil; D1 := -1;
        for I := 0 to FBatchList.Count - 1 do
        begin
          if FBatchList[I].ActiveCount > 0 then Continue;
          if Far.IndexOf(FBatchList[I]) >= 0 then Continue;
          D2 := Hypot(ACamPos.X - FBatchList[I].CX,
                      ACamPos.Z - FBatchList[I].CZ);
          if D2 > D1 then begin D1 := D2; B := FBatchList[I]; end;
        end;
        if B = nil then Break;
        Far.Add(B);
        { ближайший из эвиктнутых задаёт кламп радиуса загрузки:
          минус полудиагональ батча с запасом — чтобы скан не вернул
          его тайлы немедленно }
        FStreamer.ClampLoadRadius(D1 - 2500.0);
      end;
      LogMain(Format('mem pressure: RSS %d MB > budget %d MB — evicting %d batches',
        [ProcessRSSBytes div (1024*1024), MemBudgetBytes div (1024*1024),
         Far.Count]));
    end;
    { HOLE-DIAG: ordinary radius-driven eviction (no memory pressure) was
      previously silent. A far batch dropping out can read as a missing tile
      near the unload edge, so record how many went and the resident count.
      Note EvictBatch may DEFER a batch with shadow work in flight, so the
      'evicted' figure is the candidate set, not necessarily freed this pass. }
    if (not Pressure) and (Far.Count > 0) and LOD_HOLE_DIAG then
      LogMain(Format('purge: %d far batches (cam %.0f,%.0f, unloadR %.0f) '
        + 'resident=%d',
        [Far.Count, ACamPos.X, ACamPos.Z, FStreamer.SceneUnloadRadius,
         FBatchList.Count]));
    for I := 0 to Far.Count - 1 do
      EvictBatch(Far[I]);
  finally
    Far.Free;
  end;
end;

{ Full teardown WITH release — Destroy only. Nothing is being rendered,
  so freeing tile scenes (each UnregisterScene's its shared USE-nodes)
  cannot corrupt a live sibling, and FAsmCache (freed straight after, in
  Destroy) still holds the pinned shared nodes alive via KeepExisting.
  Order: free tile scenes, then the assembled graphs, then the batch
  nodes. No DetachSharedFrom needed here — that is only to make a
  SINGLE batch's eviction safe while siblings still render. }
procedure TOsm3dStreamingMap.TeardownAll;
var
  B:  TCacheBatch;
  CT: TCacheTile;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(847);{$ENDIF}
  if FBatchList = nil then Exit;

  FlushMountWorker;   { дождаться фонового монтажа перед освобождением сцен }
  for B in FBatchList do
  begin
    for CT in B.Tiles do
    begin
      if (B.Owner <> nil) and (CT.Scene <> nil) then
        B.Owner.Remove(CT.Scene);
      if CT.Scene <> nil then
        CT.Scene.Free;
      CT.Scene := nil;
    end;
    if B.Owner <> nil then
    begin
      Remove(B.Owner);
      B.Owner.Free;
      B.Owner := nil;
    end;
    if B.Assembled <> nil then
    begin
      B.Assembled.Free;
      B.Assembled := nil;
    end;
    B.Free;   { wrapper + TCacheTile wrappers }
  end;
  FBatchList.Clear;
  if FTileIndex <> nil then
  begin
    FTileIndex.Clear;
    FTileIndexStr.Clear;
  end;
  FActiveTiles := 0;
end;

procedure TOsm3dStreamingMap.Update(const SecondsPassed: Single;
  var RemoveMe: TRemoveType);
var
  Cam:    TCastleCamera;
  StreamPos: TVector3;
  StreamLL:  TLatLon;
  StreamTile: TGeoTileId;
  CurCT:   TCacheTile;   { current tile — gets accessory (blink) animation }
  Id:     TGeoTileId;
  Model:  TTileModel;
  Budget: Integer;
  TPump0, TPumpMs: QWord;
  TFrame0, TInherited0: QWord;
  InterFrameMs: QWord;
  BatchIds:    array of TGeoTileId;
  BatchModels: array of TTileModel;
  BatchN, I:   Integer;
  WTimeNow, WBaseNow: Single;   { current wind values, pushed to all tiles }
  ShKey:   string;            { tile key whose finished mask is uploaded this frame }
  ShGen:   QWord;             { mount generation the upload was tagged with }
  ShBytes: TShadowMaskBytes;
  ShTex:   TPixelTextureNode;
  ShImg:   TGrayscaleImage;
  ShBytesTree: TShadowMaskBytes;   { TREES mask bytes for this frame }
  ShTexTree:   TPixelTextureNode;
  ShImgTree:   TCastleImage;   { Grayscale (R4x2) or GrayscaleAlpha (R8x2) }
  ShRes:   Integer;
  ShCT:    TCacheTile;
  ReReqKeys: array of string;  { snapshot of FShadowReReq for safe iteration }
  RK:      string;
  LProfMsg: string;            { drained CPU-profiler per-window summary -> main log }
  WuStage:  string;            { прогрев: стадия/процент/счётчики }
  WuPct:    Integer;
  WuDoneN:  Integer;
  WuDiskChk: Boolean;
  WuSnapDone: Boolean;         { снап завершён/оборван — можно прятать экран }
  WuPending: TGeoTileIdArray;  { недоделанные тайлы прогрева — WantTile/пины только им }
  WuPendN:  Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(837);{$ENDIF}
  TFrame0 := GetTickCount64;
  if FWarmup <> nil then FWarmup.CollectFinishedRaster;

  if FLastFrameTick <> 0 then
  begin
    InterFrameMs := TFrame0 - FLastFrameTick;
    if InterFrameMs >= 1000 then
      LogMain(Format('INTER-FRAME STALL — %d ms between Update starts '
        + '(includes previous Update and render)', [InterFrameMs]));
  end;
  FLastFrameTick := TFrame0;
  if STREAM_DIAG_VERBOSE and (SecondsPassed > 0.10) then
    LogMain(Format('FRAME GAP — %d ms since previous frame',
      [Round(SecondsPassed * 1000)]));

  { Advance the animated-water shader clock. Each cached water tile
    registered a 'time' uniform with Osm3dWaterShader; WaterShaderTick
    pushes the shared clock into all of them. The legacy map transform
    ticked this in its Update; the streaming path never did, so water
    was assembled with the effect attached but frozen at time=0. }
  WaterShaderTick(SecondsPassed);

  { ДИАГНОСТИКА 3D-травинок (раз в ~2 c) — throttle общий. }
  GrassShaderDiagAccum := GrassShaderDiagAccum + SecondsPassed;
  if STREAM_DIAG_VERBOSE and (GrassShaderDiagAccum >= 2.0) then
  begin
    GrassShaderDiagAccum := 0.0;
    { Блейд-рендерер (3D-травинки) — отдельная диагностика: tiles/instances/
      program/tex/visible/drawn. visible=0 при tiles>0 → отсекается; program=0
      или tex=0 → шейдер/атлас не загрузились; tiles=0 → не находит smkGrass. }
    if FGrassRenderer <> nil then
    begin
      LogMain('GRASS-BLADES diag: ' + FGrassRenderer.DiagString);
      LogMain('GRASS-BLADES diag: ' + FGrassRenderer.OverlapReport);
    end
    else
      LogMain('GRASS-BLADES diag: renderer=nil (RenderGrass выключен в настройках?)');
  end;

  { Диагностика воды: раз ~2 с логируем число зарегистрированных
    time-полей и значение часов. count=0 → эффект воды не прицепился
    (WaterShaders в настройках / ветка smkWater); count>0, но clock не
    растёт → тик не доходит. }
  FWaterDiagAccum := FWaterDiagAccum + SecondsPassed;
  if FWaterDiagAccum >= 30.0 then   { was 2.0 — much less frequent now }
  begin
    FWaterDiagAccum := 0.0;
    if STREAM_DIAG_VERBOSE then
      LogCallback(Format('WATER DIAG — registered time fields=%d, clock=%.2f',
        [WaterShaderFieldCount, WaterShaderClock]));
  end;

  { One-shot route-snap auto-trigger. Fires once, a few seconds into the
    map's life, so the camera streamer establishes itself first and a
    chunk of the route is already cached by the time the snap worker
    harvests road segments. }
  if (not FSnapAutoDone) and (FSnapWorker = nil)
     and (Length(FRoute) >= 2) and (not FDestroying) then
  begin
    FLifeSeconds := FLifeSeconds + SecondsPassed;
    if FLifeSeconds >= SNAP_AUTO_DELAY_S then
    begin
      FSnapAutoDone := True;
      LogMain(Format('route snap: auto-trigger at %.1f s of map life',
        [FLifeSeconds]));
      BeginRouteSnap;
    end;
  end;

  if World <> nil then
  begin
    Cam := World.MainCamera;
    if Cam <> nil then
    begin
      StreamPos := Cam.WorldTranslation;
      StreamLL := FProj.Unproject(StreamPos.X, StreamPos.Z);
      { A paused camera may still belong to the previous ride. Load and keep
        the start resident until the host places the rider AND camera there.
        Use the published ride path as soon as snapping finishes, including
        starts moved across a tile boundary. Studio has no rider hold. }
      if FPointWarmup then
      begin
        StreamLL := FPointWarmupGeo;
        StreamPos := FProj.Project(StreamLL, 0);
      end
      else if FWarmupHoldRider and (not FWarmupRiderPlaced) and
         (Length(FRoute) > 0) then
      begin
        if FSnappedReady and (Length(FRouteRide) > 0) then
          StreamLL := FRouteRide[0]
        else
          StreamLL := FRoute[0];
        StreamPos := FProj.Project(StreamLL, 0);
      end;
      StreamTile := FCache.Grid.TileAt(StreamLL);

      { Accessory sprites (traffic-light blink) — animate the CURRENT tile only,
        so per-frame node updates stay where the camera is. }
      if FTileIndex.TryGetValue(StreamTile.ToKey, CurCT) and (CurCT <> nil) then
        CurCT.AnimateAccessories(SecondsPassed);

      { Wind uniforms track WindNow every frame -> push un-rate-limited to
        every resident tile's shadow effect, in phase with the 3D canopy. }
      WTimeNow := WindNow;
      WBaseNow := WindCurrentBaseSpeed;
      for I := 0 to High(FWindTimeFields) do
      begin
        if FWindTimeFields[I] <> nil then FWindTimeFields[I].Send(WTimeNow);
        if FWindBaseFields[I] <> nil then FWindBaseFields[I].Send(WBaseNow);
        if FWindGustFields[I] <> nil then FWindGustFields[I].Send(WBaseNow);
      end;

      { Off-thread shadows: apply at most ONE finished mask this frame. The
        worker rasterised it from the snapshot enqueued at mount; here we copy
        the bytes into the tile's existing mask image IN PLACE and force a GPU
        re-upload, then re-prepare the scene so the effect sampler picks it up.

        Why copy-in-place instead of swapping FdImage.Value: the mask image is
        created per-tile at FULL resolution at assembly (TGrayscaleImage smRes
        x smRes) and the worker always produces that same resolution, so the
        existing image always fits. Swapping the node's image was the bug — the
        SFImage setter freed the OLD image while the node still tracked it as
        its uploaded texture, so the next IsTextureLoaded := False decref'd a
        freed image (the crash). By overwriting pixels in place the image
        object is never freed or replaced, so the texture-cache reference (and
        every decref) always targets a LIVE image.

        The upload is PEEKED (left in the queue) for the whole operation, then
        COMMITTED in the finally — so it stays visible to HasPendingShadow and
        EvictBatch won't free this tile underneath us. The registry lookup is
        owner+generation-gated: it yields the node ONLY if this exact live
        mount still owns the slot (a re-mount or sibling mount of the same key
        fails the gate -> nil). }
      { SH-TRACE: outer trap — catches the access violation on the .Value
        cast below so the run survives and the log keeps flowing. Diagnostic
        only; it masks the fault, it does not fix it. }
      try
        if FStreamer.PeekShadowUpload(ShKey, ShGen, ShBytes, ShBytesTree) then
        try
          if FTileIndexStr.TryGetValue(ShKey, ShCT)
             and (ShCT <> nil) and (ShCT.Scene <> nil) then
          begin
            ShTex := FAsmCache.GetTileMaskTexByOwner(ShKey, Pointer(ShCT), ShGen);
            { SH-TRACE: ShCT is non-nil here. 'uq' = current upload-queue depth
              (confirms whether a backlog is draining). Logged before any deref
              of ShTex. }
            if STREAM_DIAG_VERBOSE then
            LogMain(Format('SH drn key=%s g=%d ct=%x ctg=%d tex=%x uq=%d',
              [ShKey, ShGen, PtrUInt(ShCT), ShCT.MountGen, PtrUInt(ShTex),
               FStreamer.UploadQueueDepth]));
            if (ShTex <> nil) and (ShTex.FdImage <> nil) then
            begin
              { SH-TRACE: 'val' is the .Value pointer read WITHOUT dereferencing
                the image object (Pointer() of a field read — safe even if the
                image was freed); 'loaded' is the texture upload state. Logged
                on its own line right before the 'is' cast that faults. If the
                fault lands after this line, 'val' tells us whether .Value is a
                sane-looking-but-freed heap address (use-after-free) or garbage
                (the node object itself is corrupt). }
              if STREAM_DIAG_VERBOSE then
              LogMain(Format('SH drn2 key=%s val=%x loaded=%d',
                [ShKey, PtrUInt(Pointer(ShTex.FdImage.Value)),
                 Ord(ShTex.IsTextureLoaded)]));
              if (ShTex.FdImage.Value is TGrayscaleImage)
                 and (Length(ShBytes) > 0) then
              begin
                ShImg := TGrayscaleImage(ShTex.FdImage.Value);  { EXISTING — never freed }
                { dimension-agnostic: packed mask can be NON-square (R4/R1),
                  so match raw byte count to the image W*H, not a Sqrt. }
                if Integer(ShImg.Width) * Integer(ShImg.Height) = Length(ShBytes) then
                begin
                  System.Move(ShBytes[0], ShImg.RawPixels^, Length(ShBytes));
                  ShTex.IsTextureLoaded := False;   { decref the SAME live image,
                                                      force re-upload of new pixels }
                  ShCT.Scene.ChangedAll;
                end;
              end;
            end;
            { TREES: same tile+gen, own texture node. Independent lookup so a
              missing tree mask never blocks the building upload. }
            ShTexTree := FAsmCache.GetTileMaskTexTreeByOwner(ShKey, Pointer(ShCT), ShGen);
            if (ShTexTree <> nil) and (ShTexTree.FdImage <> nil)
               and (ShTexTree.FdImage.Value is TCastleImage)
               and (Length(ShBytesTree) > 0) then
            begin
              ShImgTree := TCastleImage(ShTexTree.FdImage.Value);
              { byte count = W*H*PixelSize (1 for Grayscale, 2 for GrayscaleAlpha) }
              if Integer(ShImgTree.Width) * Integer(ShImgTree.Height) * Integer(ShImgTree.PixelSize) = Length(ShBytesTree) then
              begin
                System.Move(ShBytesTree[0], ShImgTree.RawPixels^, Length(ShBytesTree));
                ShTexTree.IsTextureLoaded := False;
                ShCT.Scene.ChangedAll;
              end;
            end;
          end;
        finally
          FStreamer.CommitShadowUpload;   { remove AFTER processing/skip }
        end;
      except
        on E: Exception do
          LogMain('SH-TRACE Except: ' + E.Message);
      end;

      { deferred shadow re-requests
 Tiles the pack push pass skipped because they still had an in-flight
 (pre-caster) job. The registry now holds the late caster, so re-
 enqueue each whose previous job has drained — one corrective gen,
 then it leaves the set. Tiles evicted meanwhile are dropped. This is
 what makes a shadow cross onto a neighbour that was mounted before
 its caster arrived (the reverse-order cross-pack case). At most one
 corrective job per tile, so no pile-up / flicker. }
      if (FShadowReReq.Count > 0) and Osm3dStudioSettings.GroundShadowsActive then
      begin
        SetLength(ReReqKeys, FShadowReReq.Count);
        I := 0;
        for RK in FShadowReReq.Keys do begin ReReqKeys[I] := RK; Inc(I); end;
        for I := 0 to High(ReReqKeys) do
        begin
          RK := ReReqKeys[I];
          if not FTileIndexStr.TryGetValue(RK, ShCT) then
          begin FShadowReReq.Remove(RK); Continue; end;     { evicted — drop }
          if FStreamer.HasPendingShadow(RK) then Continue;  { still draining — next frame }
          EnqueueTileShadow(ShCT);                          { corrective re-gen }
          FShadowReReq.Remove(RK);
        end;
      end;

      { Visibility: the base-tile ring toggles Exists on cached scenes. }
      FLodTree.Update(Integer(StreamTile.TX) + 0.5, Integer(StreamTile.TY) + 0.5);

      { Drain the CPU profiler's per-window summary (CPU sections, drawn-tile
        geometry, scene-visit counts, wall-clock) to the main log. It is built
        inside paint (EmitAndReset) but must not be written there; this
        non-paint world tick is the safe flush point. Self-gated: no-op until
        a ~window has elapsed. TProfiledSceneTick.Render closes frames in
        both the game and Studio; Update only drains completed summaries. }
      if GlobalCpuProfiler.TakePending(LProfMsg) then
        LogMain(LProfMsg);

      { Route-snap hold: while the snap worker is assembling the route's
        tiles, keep WantTile'ing them (so the streamer builds them through
        its normal pipeline — one carve, later reused) and PIN them so they
        are not evicted before the worker has harvested them. Only these
        tiles are held; all other eviction proceeds normally (no global
        freeze, no RELEASE burst). The worker lowers FSnapHoldEviction when
        done, and we clear the pins. }
      if FPointWarmup then
        UpdatePointWarmup
      else if FSnapHoldEviction then
      begin
        { ── Прогрев маршрута. Порядок важен: сначала защёлки готовности,
          потом WantTile/пины ТОЛЬКО для недоделанных тайлов. Готовый
          тайл лежит на диске, а снап-харвест читает диск
          (FCache.TryLoad) — его RAM-модель не нужна вовсе. Если хотеть
          все тайлы каждый кадр (как раньше), WantTile у кэшированных
          делает EnqueueIO (модель грузится в RAM), у сгенерированных
          ApplyBlock оставляет модель в RAM как wanted, и до конца
          прогрева ничто не эвиктится: на длинном маршруте это сотни
          моделей в памяти разом. Теперь пик RAM ограничен тайлами в
          работе (пара генерируемых блоков), готовые отпускаются по
          ходу и эвиктятся обычным порядком. }
        if not FWarmupShown then
        begin
          SetLength(FWarmupDone, Length(FSnapForceTiles));
          for I := 0 to High(FWarmupDone) do FWarmupDone[I] := False;
          FWarmupNextDiskChk := 0;
          FSnapProgressPt := 0;   { прошлый снап не должен мигнуть зелёным }
          FSnapHarvestN   := 0;
          FSnapHarvesting := False;
          if (FWarmup <> nil) and (not FDestroying) then
          begin
            FWarmup.ShowWarmup(FCache.Grid, FSnapForceTiles, FRoute, FAuxHttp, FCache.Recipes);
            { Этап 0 «Профиль высот маршрута»: фит-слой строится в
              Session.Create, ДО показа оверлея, — сразу done. }
            FWarmup.SetStageState(0, wssDone);
          end;
          FWarmupShown := True;
        end;
        { FCache.Has ходит на диск — троттлим; смонтированность и
          готовность в RAM проверяем каждый кадр (дёшево). Готовность —
          защёлка: генерация назад не откатывается, а файлы тайлов с
          диска в этом конвейере никто не удаляет. }
        WuDiskChk := GetTickCount64 >= FWarmupNextDiskChk;
        if WuDiskChk then FWarmupNextDiskChk := GetTickCount64 + 300;
        WuDoneN := 0;
        for I := 0 to High(FSnapForceTiles) do
        begin
          if (I <= High(FWarmupDone)) and (not FWarmupDone[I]) then
            if TileSceneReady(FSnapForceTiles[I])
               or FStreamer.TileReadyToShow(FSnapForceTiles[I])
               or (WuDiskChk and FCache.Has(FSnapForceTiles[I])) then
              FWarmupDone[I] := True;
          if (I <= High(FWarmupDone)) and FWarmupDone[I] then Inc(WuDoneN);
        end;
        { хотим и пиним только то, что ещё в работе }
        SetLength(WuPending, Length(FSnapForceTiles));
        WuPendN := 0;
        for I := 0 to High(FSnapForceTiles) do
          if (I > High(FWarmupDone)) or (not FWarmupDone[I]) then
          begin
            WuPending[WuPendN] := FSnapForceTiles[I];
            Inc(WuPendN);
            FStreamer.WantTile(FSnapForceTiles[I], SNAP_FORCE_PRIORITY, False);
          end;
        SetLength(WuPending, WuPendN);
        FStreamer.SetPinnedTiles(WuPending);
        { оверлей: состояния клеток + заголовок. Текст стадий — из того
          же LoadPhaseInfo, что у 3D-плейсхолдеров. }
        if (FWarmup <> nil) and (not FDestroying) then
        begin
          if FSnapHarvesting then
          begin
            { Фаза harvest: тайлы генерации готовы (жёлтые), теперь грузим
              из них дороги — красим клетки ЗЕЛЁНЫМ по мере загрузки.
              FSnapHarvestN — сколько тайлов уже прогружено. }
            for I := 0 to High(FSnapForceTiles) do
              if I < FSnapHarvestN then
                FWarmup.SetTileHarvest(I, 100, True)
              else if I = FSnapHarvestN then
                FWarmup.SetTileHarvest(I, -1, False)
              else
                FWarmup.SetTileHarvest(I, 0, False);
            FWarmup.SetHeader(Format(UiText('Loading roads  %d / %d'),
              [FSnapHarvestN, Length(FSnapForceTiles)]));
            { Этап 1 закрыт, этап 2 «Загрузка дорог» — active со счётчиком. }
            if not FWuStageErr[1] then FWarmup.SetStageState(1, wssDone);
            FWarmup.SetStageState(2, wssActive, Format('%d / %d',
              [FSnapHarvestN, Length(FSnapForceTiles)]));
          end
          else
          begin
            for I := 0 to High(FSnapForceTiles) do
            begin
              if (I <= High(FWarmupDone)) and FWarmupDone[I] then
                FWarmup.SetTileState(I, '', 100, True)
              else if LoadPhaseInfo(FSnapForceTiles[I], WuStage, WuPct) then
                FWarmup.SetTileState(I, WuStage, WuPct, False)
              else
                FWarmup.SetTileState(I, '', 0, False);   { очередь — как пустой текст в 3D }
            end;
            FWarmup.SetHeader(Format(UiText('Preloading route tiles  %d / %d'),
              [WuDoneN, Length(FSnapForceTiles)]));
            { Этап 1 «Прогрев тайлов» — active со счётчиком (done — при
              переходе в harvest и при снятии холда, ниже). }
            if not FWuStageErr[1] then
              FWarmup.SetStageState(1, wssActive, Format('%d / %d',
                [WuDoneN, Length(FSnapForceTiles)]));
          end;
        end;
      end
      else
      begin
        FStreamer.SetPinnedTiles([]);   { no pins held — clear (cheap) }
        { Холд снят — тайлы в кэше, но сам расчёт фит-пути (TRouteSnapper
          в воркере) ещё может идти. Держим экран прогрева до конца
          расчёта: прячем его по готовности снапа или по завершению
          воркера (это покрывает и неуспех — таймаут/отмену/исключение,
          когда OnRouteSnapDone не зовётся). }
        if FWarmupShown then
        begin
          { Показ фронтира снапа продолжаем всегда, пока экран открыт —
            и после готовности снаппера, чтобы зелёная волна доиграла
            (на кэшированных тайлах снаппер мгновенный). Прячем экран,
            когда снап завершён/оборван И анимация волны дошла до конца
            И (при включённом гейте постановки) хост подтвердил постановку
            райдера — NotifyRiderPlaced. }
          if FWarmup <> nil then
          begin
            FWarmup.SetSnapProgress(FSnapProgressPt, Length(FRoute));
            { Прогрев и харвест позади — этапы 1-2 закрываем (идемпотентно:
              SetStageState с тем же состоянием — no-op). }
            if not FWuStageErr[1] then FWarmup.SetStageState(1, wssDone);
            if not FWuStageErr[2] then FWarmup.SetStageState(2, wssDone);
          end;
          WuSnapDone := FSnappedReady or (FSnapWorker = nil)
                        or FSnapWorker.Finished;
          if WuSnapDone and ((FWarmup = nil) or FWarmup.IsSnapAnimDone)
             and ((not FWarmupHoldRider) or FWarmupRiderPlaced) then
          begin
            FWarmupShown := False;
            if FWarmup <> nil then
            begin
              if not FWuStageErr[3] then FWarmup.SetStageState(3, wssDone);
              if not FWuStageErr[5] then FWarmup.SetStageState(5, wssDone);
              FWarmup.HideWarmup;
            end;
          end
          else if FWarmup <> nil then
          begin
            if not (WuSnapDone and FWarmup.IsSnapAnimDone) then
            begin
              FWarmup.SetHeader(UiText('Snapping route to roads…'));
              { Этап 3 «Притягивание маршрута» — идёт расчёт/волна. }
              FWarmup.SetStageState(3, wssActive);
            end
            else if FWarmupHoldRider and (not FWarmupRiderPlaced)
                    and (not FWuStageErr[5]) then
            begin
              FWarmup.SetHeader(UiText('Placing rider at the start…'));
              { Волна доиграла — ждём постановку райдера (этап 5). }
              FWarmup.SetStageState(5, wssActive);
            end;
          end;
        end;
      end;

      { Фоновая FIT-коррекция — этап 4 «Коррекция высот»: active со
        счётчиком «N / M» заездов банка, done по завершении потока. Гейт
        старта её больше не ждёт — оверлей может быть уже скрыт;
        SetStageState на скрытый оверлей безвреден (подписи вне экрана). }
      if FFitCorrStageRun then
      begin
        if (FFitCorrWorker <> nil) and FFitCorrWorker.Finished then
        begin
          FFitCorrStageRun := False;
          if FWarmup <> nil then FWarmup.SetStageState(4, wssDone);
        end
        else if FWarmup <> nil then
          FWarmup.SetStageState(4, wssActive, Format('%d / %d',
            [FFitCorrProgCur, FFitCorrProgTotal]));
      end;

      { Ошибки снап-воркера (обрыв ожидания по застою / исключение) —
        красной плашкой + этап → wssError. Езда при этом НЕ блокируется:
        пайплайн деградирует, как раньше (только лог). }
      if (FSnapError <> '') and (not FSnapErrorShown) then
      begin
        FSnapErrorShown := True;
        LogMain('route snap: ошибка показана на оверлее — ' + FSnapError);
        WarmupFail(FSnapErrorStage, FSnapError);
      end;

      { Background work — disk loads + block generation on workers. }
      TPump0 := GetTickCount64;
      FStreamer.Pump(StreamLL, SecondsPassed);
      { Route-only: печём ВЕСЬ коридор пути на диск (порция за кадр). Камерный
        keyhole (ограниченный коридором WantFilter'ом) монтирует ближние тайлы. }
      if FRouteOnlyGeom then PumpRouteCorridorPregen;
      TPumpMs := GetTickCount64 - TPump0;
      if TPumpMs >= 30 then   { was 4 — only log real stalls now, not routine 15-16ms }
        LogMain(Format('Pump %d ms', [TPumpMs]));

      { Фоновый монтаж: включить Exists у активных тайлов, чьи сцены поток уже
        наполнил, и держать скрытыми ещё не готовые (дёшево — тайлов единицы). }
      SyncMountedExists;

      { Drain up to UploadsPerFrame ready tile models into one pack and
        assemble + cache them with a single AssembleCachedTiles call.
        Во время прогрева (под оверлеем фризы не видны) бюджет ×4 — тайлы
        маршрута нужны смонтированными к постановке райдера. }
      Budget := UploadsPerFrame;
      if FWarmupShown then Budget := Budget * 4;
      if Budget < 1 then Budget := 1;
      { Most frames have nothing to upload. Allocate the owned batch only
        after the first ready model has actually been taken from the queue. }
      if FStreamer.NextUpload(Id, Model) then
      begin
        SetLength(BatchIds,    Budget);
        SetLength(BatchModels, Budget);
        BatchIds[0] := Id;
        BatchModels[0] := Model;
        BatchN := 1;
        while (BatchN < Budget) and FStreamer.NextUpload(Id, Model) do
        begin
          BatchIds[BatchN]    := Id;
          BatchModels[BatchN] := Model;
          Inc(BatchN);
        end;
        SetLength(BatchIds,    BatchN);
        SetLength(BatchModels, BatchN);
        if GlobalAssembleInWorker then
          { владение моделями забирается внутри; монтаж отложен до DrainAssembled }
          EnqueueAssembleBatch(BatchIds, BatchModels)
        else
        begin
          MountBatch(BatchIds, BatchModels);
          for I := 0 to BatchN - 1 do
            FStreamer.MarkUploaded(BatchIds[I]);
          Inc(FDiagMounted, BatchN);
          for I := 0 to BatchN - 1 do
            SwapGreenToDetail(BatchIds[I]);
        end;
      end;
      { смонтировать пакеты, которые фон-ассемблер уже собрал (при выкл. флаге — нет) }
      if GlobalAssembleInWorker then DrainAssembled;

      { Far-ground: перенацеливаем на камеру при пересечении ~ячейки (256 м) —
        высоты не пересобираются, а морфятся; покадрово двигаем морф. При
        GenerateFarTerrain=False дальняя земля не строится вовсе. }
      if FGenerateFarTerrain then
      begin
        if (not FFarHasCenter) or
           (Sqr(StreamPos.X - FFarCenterX) + Sqr(StreamPos.Z - FFarCenterZ)
               > 256.0 * 256.0) then
          RebuildFarGround(StreamPos);
        if FFarGround <> nil then
        begin
          FFarGround.Animate(SecondsPassed);
          UpdateFarClip;   { посекторный клип под силуэт показанных тайлов }
        end;
      end;

      { Cache eviction — far, inactive batches are fully released.
        Constants of un-loading (SceneUnloadRadius) drive this. }
      PurgeFarBatches(StreamPos);

      { Плейсхолдеры загрузки: снять смонтированные, обновить прогресс. }
      UpdateLoadTiles;

      { Green-overlay retro-fit — снять высоту настила под снапнутыми
        точками с нескольких резидентных тайлов за кадр (без фриза). }
      RetrofitGreenBudget;

      { Пересобрать помеченные запечённые сцены сфер (троттлинг внутри):
        высоты дозаполнились монтажом/снапом — обновляем единый меш цвета. }
      UpdateDirtySphereScenes;

      { The base-tile ring owns visibility; drain the streamer's evict queue
        so it does not back up. }
      while FStreamer.NextEvict(Id) do
        ;

      Inc(FDiagFrames);
      if FDiagTick = 0 then FDiagTick := TFrame0;
      if (TFrame0 - FDiagTick) >= 1000 then
      begin
        {$IFDEF TILE_MEM_PROFILE}
        MemCensusReportThrottled(FLog, 1000);
        {$ENDIF}
        if STREAM_DIAG_VERBOSE then
        LogMain(Format('DIAG — activeTiles=%d cachedTiles=%d batches=%d '
          + 'mounted+%d frames=%d instVeg v=%d d=%d',
          [FActiveTiles, FTileIndex.Count, FBatchList.Count,
           FDiagMounted, FDiagFrames,
           ProfInstancedVisited, ProfInstancedDrawn]));
        FDiagTick    := TFrame0;
        FDiagFrames  := 0;
        FDiagMounted := 0;
      end;
    end;
  end;

  TInherited0 := GetTickCount64;
  inherited Update(SecondsPassed, RemoveMe);
  if (GetTickCount64 - TInherited0) >= 50 then
    LogMain(Format('SLOW inherited Update — %d ms',
      [GetTickCount64 - TInherited0]));
  if (GetTickCount64 - TFrame0) >= 50 then
    LogMain(Format('SLOW Update total — %d ms', [GetTickCount64 - TFrame0]));
end;

procedure TOsm3dStreamingMap.SetSunDirection(const ADir: TVector3;
  AShadowsAllowed: Boolean);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(838);{$ENDIF}
  { ONE sun feeds all three render paths from here:
      buildings — AddSceneLights(ADir)     at assemble time
      ground    — gc_SunDirToward := -ADir at assemble time (Scene Load)
      vegetation— lightDir := ADir         every frame (below) }
  FSunDir := ADir;
  FSunShadowsAllowed := AShadowsAllowed;
  FBlockGen.SunDirection := ADir;
  Osm3dRenderInstanced.SetInstancedSunDir(ADir);
  Osm3dRenderGrass.SetGrassSunDir(ADir);
end;

function TOsm3dStreamingMap.SunWorldShadowDir(out ADir: TVector3): Boolean;
begin
  Result := False;
  ADir := FSunDir;
  if not FSunShadowsAllowed or (ADir.Length < 1e-6) then Exit;
  ADir := ADir.Normalize;
  Result := ADir.Y < -0.0349; { same ~2 degree directional-shadow cutoff }
end;

procedure TOsm3dStreamingMap.SetRoute(const ARoute: TRouteLatLonArray;
  const AAlt: TRouteAltArray);
var
  I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1738);{$ENDIF}
  { Copy by value — the host's array may be freed or reused. Tiles
    already mounted are not retro-fitted; in practice SetRoute is
    called before the first tile streams in (the route is known at
    session start — it is what the origin is derived from). }
  SetLength(FRoute, Length(ARoute));
  for I := 0 to High(ARoute) do
    FRoute[I] := ARoute[I];
  { Altitude track for the blue spheres — kept only when it is parallel
    to the route (defensive: same length), otherwise dropped so the blue
    pass simply stays off. }
  if Length(AAlt) = Length(ARoute) then
  begin
    SetLength(FRouteAltM, Length(AAlt));
    for I := 0 to High(AAlt) do
      FRouteAltM[I] := AAlt[I];
  end
  else
    SetLength(FRouteAltM, 0);
  { Новый маршрут — прежние снятые высоты рельефа/настила недействительны
    (перезаполнятся монтажом). Синяя сцена (высота трека) готова сразу,
    красную/зелёную бакер отрисует по мере захвата (SPHERE_Y_NONE
    пропускается). }
  SetLength(FRouteGroundRaw, 0);
  SetLength(FRouteDem, 0);
  SetLength(FPendingRouteDem, 0);
  FRouteDemPending := False;
  SetLength(FRouteSnappedY, 0);
  MarkSphereDirty(0);   { красный — сырой рельеф }
  MarkSphereDirty(1);   { синий — исходная высота трека }
  { Route-only: пересчитать коридор из нового маршрута — (пере)поставить фильтр
    keyhole стримера И отдать сырой маршрут генератору блоков (он режет
    геометрию ВНУТРИ тайла по коридору: террейн/земля + фильтр OSM-фич). }
  if FRouteOnlyGeom then BuildRouteCorridor;
  if FBlockGen <> nil then
    FBlockGen.SetRouteCorridor(FRoute, FRouteOnlyRadiusM, FRouteOnlyGeom);
  { NOTE: snapping is NOT auto-started here. BeginRouteSnap kicks off a
    worker that may regenerate a large part of the route's tiles via
    Overpass; firing that at session-creation time floods the same
    endpoints the camera-driven streamer needs and starves it of tiles.
    The host calls BeginRouteSnap explicitly once the map is up. }
end;

procedure TOsm3dStreamingMap.BeginRouteSnap;
var
  I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1739);{$ENDIF}
  if FDestroying then Exit;
  if Length(FRoute) < 2 then
  begin
    LogMain('route snap: BeginRouteSnap ignored — no route');
    Exit;
  end;
  if FSnapWorker <> nil then
  begin
    LogMain('route snap: BeginRouteSnap ignored — already running');
    Exit;                                 { one pass at a time }
  end;
  LogMain(Format('route snap: BeginRouteSnap — spawning worker (%d pts)',
    [Length(FRoute)]));
  FSnapCancel := False;
  { Новый проход — сброс постановки райдера и ошибок/защёлок этапов:
    оверлей снова ждёт NotifyRiderPlaced (если холд включён). }
  FWarmupRiderPlaced := False;
  FSnapError      := '';
  FSnapErrorStage := -1;
  FSnapErrorShown := False;
  for I := 0 to WARMUP_STAGE_COUNT - 1 do FWuStageErr[I] := False;
  { Тайлы маршрута и экран прогрева — СРАЗУ, на главном потоке. Раньше
    показ зависел от окна FSnapHoldEviction в Update: на горячем кэше
    весь снап укладывался в ~0.3 с, стартовые стойлы кадра (создание
    сессии, первый маунт) это окно пропускали, и плоская карта не
    появлялась вообще — под ней был виден райдер на Y=0. }
  FSnapForceTiles := ComputeSnapTiles;
  if not FWarmupShown then
  begin
    SetLength(FWarmupDone, Length(FSnapForceTiles));
    for I := 0 to High(FWarmupDone) do FWarmupDone[I] := False;
    FWarmupNextDiskChk := 0;
    FSnapProgressPt := 0;   { прошлый снап не должен мигнуть зелёным }
    FSnapHarvestN   := 0;
    FSnapHarvesting := False;
    if (FWarmup <> nil) and (not FDestroying) then
    begin
      FWarmup.ShowWarmup(FCache.Grid, FSnapForceTiles, FRoute, FAuxHttp, FCache.Recipes);
      { Этап 0 «Профиль высот маршрута»: фит-слой строится в
        Session.Create, ДО показа оверлея, — сразу done. }
      FWarmup.SetStageState(0, wssDone);
    end;
    FWarmupShown := True;
  end;
  FSnapWorker := TRouteSnapWorker.Create(Self);
end;

function TOsm3dStreamingMap.TryFinishFitCorrection: Boolean;
begin
  Result := (FFitCorrWorker = nil) or FFitCorrWorker.Finished;
  if Result then PublishFitCorrection;
end;

function TOsm3dStreamingMap.RoutePrepDone: Boolean;
begin
  { Условия отражают ФУНКЦИОНАЛЬНЫЕ фазы подготовки:
      1) FSnapWorker <> nil    — BeginRouteSnap вообще запускался;
      2) FSnapWorker.Finished  — Execute воркера завершился: прогрев-
                                 ожидание, харвест и снап позади (или
                                 оборваны по застою/отмене/исключению —
                                 обе ветки «завершение», зависание
                                 невозможно). FIT-коррекция сюда НЕ входит:
                                 она считается отдельным фоновым потоком
                                 (TFitCorrOnlyWorker) параллельно публикации
                                 снапа и гейт старта больше не держит;
      3) not FSnapHoldEviction — прогревной холд снят (страховка: воркер
                                 снимает его в finally ещё до снапа).
    Экран прогрева (FWarmupShown) СОЗНАТЕЛЬНО не в условии: его зелёная
    волна — анимация, она доигрывает и прячет оверлей сама; держать ею
    старт заезда нельзя. }
  Result := (FSnapWorker <> nil) and FSnapWorker.Finished
            and (not FSnapHoldEviction);
end;

function TOsm3dStreamingMap.RoutePrepStateStr: string;
var
  W: string;
begin
  if FSnapWorker = nil then
    W := 'none'
  else if FSnapWorker.Finished then
    W := 'finished'
  else
    W := 'running';
  Result := Format('worker=%s hold=%d overlay=%d snapped=%d',
    [W, Ord(FSnapHoldEviction), Ord(FWarmupShown), Ord(FSnappedReady)]);
end;

procedure TOsm3dStreamingMap.WarmupFail(AStage: Integer; const AMsg: string);
begin
  { Пометить этап ошибкой и показать красную плашку. Оверлей может быть
    уже скрыт — вызовы на нём безвредны (ошибка в любом случае в логе).
    Защёлка FWuStageErr не даёт поздним wssDone (NotifyRiderPlaced,
    гашение оверлея) перекрыть wssError. }
  if (AStage >= 0) and (AStage < WARMUP_STAGE_COUNT) then
  begin
    FWuStageErr[AStage] := True;
    if FWarmup <> nil then
      FWarmup.SetStageState(AStage, wssError, AMsg);
  end;
  if FWarmup <> nil then
    FWarmup.SetError(AMsg);
end;

procedure TOsm3dStreamingMap.BeginPointWarmup(const Geo: TLatLon);
var Tiles:TGeoTileIdArray; Points:Osm3dWarmupOverlay.TRouteLatLonArray; I:Integer;
begin
  if FDestroying or (FCache=nil) or (FWarmup=nil) then Exit;
  FPointWarmup:=True;FPointWarmupGeo:=Geo;
  FPointWarmupTile:=FCache.Grid.TileAt(Geo);
  FPointWarmupNextUpdate:=0;
  FWarmupRiderPlaced:=False;FWarmupHoldRider:=True;
  for I:=0 to WARMUP_STAGE_COUNT-1 do FWuStageErr[I]:=False;
  SetLength(Tiles,1);Tiles[0]:=FPointWarmupTile;
  SetLength(Points,1);Points[0]:=Geo;
  FWarmup.ShowWarmup(FCache.Grid,Tiles,Points,FAuxHttp,FCache.Recipes,True);
  FWarmupShown:=True;
  UpdatePointWarmup;
end;

procedure TOsm3dStreamingMap.UpdatePointWarmup;
var Stage,ErrorText:string; Pct:Integer; P:TVector3; Ready:Boolean;
begin
  if not FPointWarmup or FDestroying then Exit;
  if FWarmupRiderPlaced then
  begin
    FPointWarmup:=False;FWarmupShown:=False;
    FStreamer.SetPinnedTiles([]);
    FWarmup.HideWarmup;
    Exit;
  end;
  { No disk polling or JSON allocation per frame. Progress comes from the
    normal streaming pipeline, including cached scene assembly and retries. }
  if GetTickCount64<FPointWarmupNextUpdate then Exit;
  FPointWarmupNextUpdate:=GetTickCount64+200;
  FStreamer.WantTile(FPointWarmupTile,SNAP_FORCE_PRIORITY,True);
  FStreamer.SetPinnedTiles([FPointWarmupTile]);
  P:=FProj.Project(FPointWarmupGeo,0);
  GroundLoadStatusAt(P.X,P.Z,ErrorText);
  Ready:=TileSceneReady(FPointWarmupTile);
  if not LoadPhaseInfo(FPointWarmupTile,Stage,Pct) then
  begin Stage:=UiText('Preparing tile');Pct:=-1 end;
  FWarmup.SetTileState(0,Stage,Pct,Ready);
  if ErrorText<>'' then
  begin
    FWarmup.SetStageState(1,wssError);
    FWarmup.SetError(UiText('Map loading failed. Retrying automatically; Esc opens the menu.')+
      LineEnding+ErrorText);
  end
  else
  begin
    if not FWuStageErr[5] then FWarmup.SetError('');
    if Ready then FWarmup.SetStageState(1,wssDone)
    else FWarmup.SetStageState(1,wssActive);
  end;
  if Ready then
  begin
    FWarmup.SetHeader(UiText('Placing rider at the start…'));
    if not FWuStageErr[5] then FWarmup.SetStageState(5,wssActive);
  end
  else FWarmup.SetHeader(UiText('Loading starting tile…'));
end;

procedure TOsm3dStreamingMap.NotifyRiderPlaced;
begin
  { Райдер поставлен на старт — оверлею можно гаснуть (условие гашения
    в Update проверяет FWarmupRiderPlaced при включённом FWarmupHoldRider).
    Этап «Постановка на старт» → done, если он не был помечен ошибкой
    (старт без точной высоты по таймауту — WarmupFail раньше). }
  FWarmupRiderPlaced := True;
  if (FWarmup <> nil) and (not FWuStageErr[5]) then
    FWarmup.SetStageState(5, wssDone);
  if FPointWarmup then UpdatePointWarmup;
end;

procedure TOsm3dStreamingMap.BeginFitCorrectionOnly;
begin
  if FDestroying then Exit;
  if (FRoutesFolder = '') or (FSelectedFit = '') then
  begin
    LogMain('[fitcorr] BeginFitCorrectionOnly ignored — routes folder/file not set');
    Exit;
  end;
  if FFitCorrWorker <> nil then
  begin
    if FFitCorrWorker.Finished then
      FreeAndNil(FFitCorrWorker)     { прошлый проход закончил — снимаем }
    else
    begin
      LogMain('[fitcorr] BeginFitCorrectionOnly ignored — already running');
      Exit;
    end;
  end;
  FSnapCancel := False;
  LogMain('[fitcorr] BeginFitCorrectionOnly — spawning worker (DEM only, no tiles)');
  FFitCorrWorker := TFitCorrOnlyWorker.Create(Self);
end;

procedure TOsm3dStreamingMap.ShowFlatMap;
begin
  if FDestroying or (FWarmup = nil) then Exit;
  if Length(FRoute) < 2 then Exit;
  { Пустой список тайлов → ни жёлтых столбиков прогрева, ни зелёной волны
    снапа: оверлей рисует только растровую подложку и линию маршрута.
    Растр качает свой фоновый поток оверлея, декодит его собственный
    Update (оверлей в UI-дереве) — карте 3D-вьюпорт не нужен, тайлы не
    генерятся. }
  FWarmup.ShowWarmup(FCache.Grid, nil, FRoute, FAuxHttp);
end;

procedure TOsm3dStreamingMap.OnRouteSnapDone;
begin
  if FDestroying then Exit;
  {$IFDEF IAM_LIVE}IamLiveTrack(1740);{$ENDIF}
  { Runs on the main thread (Queue'd from the worker). Публикация
    результатов: воркер сложил массивы снапа в FPending* (последняя запись
    до Queue — видна здесь по happens-before), переносим в рабочие поля
    ЗДЕСЬ — единственная точка, где они меняются; прежние массивы при этом
    освобождаются на главном потоке, а читатели (зелёный оверлей,
    CaptureRouteGroundY, свойства Snapped*) никогда не видят
    полузаполненные данные. Flip the ready flag so any tile mounted
    from now on gets its green cluster in MountBatch, then arm the
    per-frame retro-fit for tiles that are ALREADY resident — doing them
    all here, in one Queue'd call, loaded + built geometry for every
    resident tile and froze the whole UI for the duration. }
  FRouteRide:=FPendingRide; FPendingRide:=nil;
  FRouteRideWidths:=FPendingRideWidths; FPendingRideWidths:=nil;
  FRouteRideSource:=FPendingRideSource; FPendingRideSource:=nil;
  FRouteSnapped := FPendingSnapped;
  FRouteWidths  := FPendingWidths;
  FRouteCenters := FPendingCenters;
  FRouteWays    := FPendingWays;
  FPendingSnapped := nil;
  FPendingWidths  := nil;
  FPendingCenters := nil;
  FPendingWays    := nil;
  FBotCrossings:=FPendingBotCrossings;FPendingBotCrossings:=nil;
  FSnappedReady := True;
  LogMain(Format('route snap: OnRouteSnapDone — %d snapped points',
    [Length(FRouteSnapped)]));

  { Коррекцию террейна строит ОТДЕЛЬНЫЙ фоновый поток (TFitCorrOnlyWorker,
    запущен снап-воркером перед Queue(OnRouteSnapDone)) — здесь только
    пытаемся опубликовать результат на главном потоке. Поток ещё считает —
    FFitCorrPending/FRouteDemPending не взведены и это no-op; когда он
    кончит, он сам заквьюет PublishFitCorrection. Никакого BuildFitBank/
    сплайна на main — UI не морозится. }
  if (FRoutesFolder <> '') and (FSelectedFit <> '') then
    PublishFitCorrection
  else
    { Громкая диагностика: хост не задал папку заездов (SetRoutesFolder) —
      коррекция террейна по FIT пропущена. Молчаливый пропуск уже стоил
      сессии отладки («правки не применились»). }
    LogMain('[fitcorr] SKIPPED — routes folder not set by host '
      + '(SetRoutesFolder)');
  if FDestroying or (Length(FRouteSnapped) = 0) then
  begin
    if Length(FRouteSnapped) = 0 then
      LogMain('route snap: snapped route is empty — no green overlay');
    Exit;
  end;
  { Overlay disabled by the host — publish FSnappedReady (the host still
    reads SnappedRoute for path snapping) but don't arm the retro-fit;
    it would reload tile models from disk just to sample Y nobody renders. }
  if not FShowFitPointsSnapped then
  begin
    LogMain('route snap: green overlay disabled — retro-fit skipped');
    Exit;
  end;
  { Резидентные тайлы, смонтированные ДО снапа, добираем по кадру
    (RetrofitGreenBudget снимает высоту настила/дороги в FRouteSnappedY);
    сразу помечаем зелёную сцену грязной, чтобы она пересобралась по мере
    заполнения высот. }
  FGreenRetrofit := True;
  MarkSphereDirty(3);
end;

procedure TOsm3dStreamingMap.RetrofitGreenBudget;
var
  B, I, Done: Integer;
  CT:         TCacheTile;
  M:          TTileModel;
  MArr:       array[0..0] of TTileModel;
  IArr:       array[0..0] of TGeoTileId;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1741);{$ENDIF}
  if FDestroying or (not FGreenRetrofit) then Exit;
  { Defence in depth — OnRouteSnapDone already gates this, but the host
    can flip ShowFitPointsSnapped at runtime. }
  if not FShowFitPointsSnapped then
  begin
    FGreenRetrofit := False;
    Exit;
  end;
  if Length(FRouteSnapped) = 0 then
  begin
    FGreenRetrofit := False;
    Exit;
  end;

  Done := 0;
  for B := 0 to FBatchList.Count - 1 do
  begin
    if (FBatchList[B] = nil) or (FBatchList[B].Tiles = nil) then Continue;
    for I := 0 to FBatchList[B].Tiles.Count - 1 do
    begin
      CT := FBatchList[B].Tiles[I];
      if (CT = nil) or CT.GreenMounted then Continue;

      { Модель тайла больше не удерживается — грузим из кэша ТОЛЬКО чтобы
        снять высоту настила/дороги под снапнутыми точками в FRouteSnappedY
        (одна запечённая зелёная сцена пересоберётся из неё). Геометрию на
        тайл больше НЕ строим — потому бюджет на кадр можно не жалеть. }
      M := nil;
      if FCache.TryLoad(CT.Tile, M) and (M <> nil) then
      begin
        try
          MArr[0] := M; IArr[0] := CT.Tile;
          CaptureRouteGroundY(MArr, IArr, FRouteSnapped, FRouteWays,
            FRouteSnappedY);
          MarkSphereDirty(3);
        finally
          M.Free;
        end;
      end;
      { Mark done even if the load failed — never retry the same tile
        every frame forever. }
      CT.GreenMounted := True;
      Inc(Done);
      if Done >= GREEN_RETROFIT_PER_FRAME then
        Exit;          { budget spent — resume next frame }
    end;
  end;

  { Прошли весь резидентный набор — высоты сняты со всех; тайлы,
    смонтированные позже, добирает CaptureRawGroundY в MountBatch. }
  FGreenRetrofit := False;
  LogMain('route snap: green Y capture retro-fit complete');
end;

{ Фит-ретрофит: перемонтаж батчей, смонтированных до постройки коррекции.
  По ОДНОМУ батчу за кадр: EvictBatch снимает тайлы с резидентности и
  сообщает стримеру (NotifySceneEvicted) — per-frame перезапрос вернёт их
  из тёплого диск-кэша уже через путь с деформацией (MountBatch либо
  EnqueueAssembleBatch — коррекция теперь в обоих). EvictBatch может
  отложить выгрузку (тени/монтаж в полёте) — тогда батч остаётся в
  очереди и пробуется следующим кадром. Ссылки очереди без владения:
  перед разыменованием сверяем с живым FBatchList. }
constructor TAssembleWorker.Create(AMap: TOsm3dStreamingMap);
begin
  FMap := AMap;
  inherited Create(False);
end;

procedure TAssembleWorker.Execute;
var
  Job: TAssembleJob;
  Got: Boolean;
  k:   Integer;
begin
  while not Terminated do
  begin
    RTLEventWaitFor(FMap.FAsmWake, 200);
    if Terminated then Break;
    repeat
      Got := False;
      EnterCriticalSection(FMap.FAsmLock);
      try
        if FMap.FAsmQueue.Count > 0 then
        begin Job := FMap.FAsmQueue.Dequeue; Got := True; end;
      finally
        LeaveCriticalSection(FMap.FAsmLock);
      end;
      if not Got then Break;
      { тяжёлая сборка X3D-графа — вне главного потока. Реестр теней (FAsmCache)
        потокобезопасен (критсекция), атласы прогреты и только читаются. }
      Job.Failed := False;
      try
        Job.Assembled := TSceneAssembler.AssembleCachedTiles(
          Job.Models, FMap.FOrigin, FMap.FHeightmapZoom, FMap.FSunDir,
          Job.Trees, Job.Previews, nil, FMap.FAsmCache,
          False, FMap.FManualScaleLat);
      except
        on E: Exception do
        begin
          Job.Failed := True;
          FMap.LogMain('async assemble FAILED: ' + E.Message);
        end;
      end;
      { превью потреблены сборкой — освобождаем здесь }
      for k := 0 to High(Job.Previews) do
        if Job.Previews[k] <> nil then FreeAndNil(Job.Previews[k]);
      SetLength(Job.Previews, 0);
      Job.TAsmMs := GetTickCount64 - Job.TAsm0;
      EnterCriticalSection(FMap.FAsmLock);
      try
        FMap.FAsmDoneQueue.Enqueue(Job);
      finally
        LeaveCriticalSection(FMap.FAsmLock);
      end;
      InterLockedDecrement(FMap.FAsmPending);
    until Terminated;
  end;
end;

procedure TOsm3dStreamingMap.FreeAssembleJob(const J: TAssembleJob);
var k: Integer;
begin
  for k := 0 to High(J.Models) do
    if J.Models[k] <> nil then J.Models[k].Free;
  for k := 0 to High(J.Previews) do
    if J.Previews[k] <> nil then J.Previews[k].Free;
  if J.BatchBorder <> nil then J.BatchBorder.Free;
  if J.Assembled <> nil then J.Assembled.Free;
end;

procedure TOsm3dStreamingMap.FreeRemainingAssembleJobs;
var Job: TAssembleJob;
begin
  if FAsmQueue <> nil then
    while FAsmQueue.Count > 0 do begin Job := FAsmQueue.Dequeue; FreeAssembleJob(Job); end;
  if FAsmDoneQueue <> nil then
    while FAsmDoneQueue.Count > 0 do begin Job := FAsmDoneQueue.Dequeue; FreeAssembleJob(Job); end;
end;

procedure TOsm3dStreamingMap.EnqueueAssembleBatch(const AIds: array of TGeoTileId;
  const AModels: array of TTileModel);
var
  Job: TAssembleJob;
  N, I: Integer;
  Previews: TTilePreviewDataArray;
  Border:   TBorderWorldMap;
begin
  N := Length(AModels);
  if N = 0 then Exit;
  { Общий с MountBatch пролог: красные сферы, превью земли, сшивка границ,
    альфа-маски деревьев. }
  PrepareBatchForAssemble(AIds, AModels, Previews, Border);
  SetLength(Job.Ids, N); SetLength(Job.Models, N); SetLength(Job.Previews, N);
  for I := 0 to N - 1 do
  begin
    Job.Ids[I]    := AIds[I];
    Job.Models[I] := AModels[I];        { владение забираем ниже }
    Job.Previews[I] := Previews[I];
  end;
  Job.BatchBorder := Border;
  Job.Assembled := nil; SetLength(Job.Trees, 0);
  Job.TAsm0 := GetTickCount64; Job.TAsmMs := 0; Job.Failed := False;
  { забрать владение моделями у стримера — чтобы эвикт/перезагрузка не тронули
    их, пока воркер читает (модель теперь живёт в job). }
  for I := 0 to N - 1 do
    FStreamer.ReleaseUploadOwnership(AIds[I]);
  EnterCriticalSection(FAsmLock);
  try
    FAsmQueue.Enqueue(Job);
  finally
    LeaveCriticalSection(FAsmLock);
  end;
  InterLockedIncrement(FAsmPending);
  RTLEventSetEvent(FAsmWake);
end;

procedure TOsm3dStreamingMap.DrainAssembled;
var Job: TAssembleJob; Got: Boolean; I, Budget: Integer;
begin
  if FAsmDoneQueue = nil then Exit;
  { не монтировать несколько тяжёлых load-фаз за один кадр — тот же бюджет,
    что и у синхронного дренажа, иначе фризы стакаются. Во время прогрева
    (под оверлеем фризы не видны) — ×4, как в Update. }
  Budget := UploadsPerFrame;
  if FWarmupShown then Budget := Budget * 4;
  if Budget < 1 then Budget := 1;
  while Budget > 0 do
  begin
    Got := False;
    EnterCriticalSection(FAsmLock);
    try
      if FAsmDoneQueue.Count > 0 then
      begin Job := FAsmDoneQueue.Dequeue; Got := True; end;
    finally
      LeaveCriticalSection(FAsmLock);
    end;
    if not Got then Break;
    if not Job.Failed then
      { MountAssembled владеет и освобождает Assembled + BatchBorder }
      MountAssembled(Job.Assembled, Job.Trees, Job.BatchBorder,
                     Job.Models, Job.Ids, Job.TAsmMs)
    else
    begin
      if Job.BatchBorder <> nil then Job.BatchBorder.Free;
      if Job.Assembled  <> nil then Job.Assembled.Free;
    end;
    { Модели MountAssembled не освобождает. Обычно отдаём их в
      фон-сохранение (монтаж закончил, модель стабильна). НО прогревный
      тайл уже записан в кэш сразу при генерации (ждущий тайл) —
      повторно писать не нужно, спрашиваем стример и просто освобождаем. }
    for I := 0 to High(Job.Models) do
      if Job.Models[I] <> nil then
        if FStreamer.AlreadyOnDisk(Job.Ids[I]) then
          Job.Models[I].Free            { уже на диске — не переписываем }
        else
          FStreamer.EnqueueSave(Job.Ids[I], Job.Models[I]);
    for I := 0 to High(Job.Ids) do
      SwapGreenToDetail(Job.Ids[I]);
    Inc(FDiagMounted, Length(Job.Ids));
    Dec(Budget);
  end;
end;

constructor TMountWorker.Create(AMap: TOsm3dStreamingMap);
begin
  FMap := AMap;
  inherited Create(False);    { стартуем сразу }
end;

procedure TMountWorker.Execute;
var
  Job: TMountJob;
  Got: Boolean;
begin
  while not Terminated do
  begin
    RTLEventWaitFor(FMap.FMountWake, 200);
    if Terminated then Break;
    repeat
      Got := False;
      EnterCriticalSection(FMap.FMountLock);
      try
        if FMap.FMountQueue.Count > 0 then
        begin
          Job := FMap.FMountQueue.Dequeue;
          Got := True;
        end;
      finally
        LeaveCriticalSection(FMap.FMountLock);
      end;
      if not Got then Break;

      { MountGraph publishes the complete result after exception cleanup.
        The batch retains its root for one bounded retry. }
      if Job.Scene <> nil then Job.Scene.MountGraph(Job.Root);
      InterLockedDecrement(FMap.FMountPending);
    until Terminated;
  end;
end;

procedure TOsm3dStreamingMap.EnqueueMount(Sc: TProfiledScene;
  Root: TX3DRootNode);
var
  Job: TMountJob;
begin
  if Sc = nil then Exit;
  if Sc.Exists then FFarClipDirty := True;
  Sc.Exists := False;
  Sc.MountRoot := Root; Sc.MountErrorHandled := False;
  Sc.MountLoaded := False; Sc.MountFailed := False;
  InterlockedExchange(Sc.MountFinished, 0);
  if FMountWorker = nil then
  begin
    { поток не создан — синхронный монтаж тут же }
    Sc.MountGraph(Root);
    Exit;
  end;
  Job.Scene := Sc;
  Job.Root  := Root;
  EnterCriticalSection(FMountLock);
  try
    InterLockedIncrement(FMountPending);
    FMountQueue.Enqueue(Job);
  finally
    LeaveCriticalSection(FMountLock);
  end;
  RTLEventSetEvent(FMountWake);
end;

procedure TOsm3dStreamingMap.FlushMountWorker;
var
  Spins: Integer;
begin
  if FMountWorker = nil then Exit;
  Spins := 0;
  { Ждём, пока фоновый поток не отпустит все сцены (FMountPending=0). Лимит —
    предохранитель от вечного цикла; в норме очередь разбирается за миллисекунды
    (Scene.Load одного тайла), а выгрузка случается редко. Спин дольше ~5 с
    логируем: молчаливое минутное ожидание на главном потоке не отличить от
    зависания. }
  while (FMountPending > 0) and (Spins < 200000) do
  begin
    RTLEventSetEvent(FMountWake);
    Sleep(1);
    Inc(Spins);
    if Spins mod 5000 = 0 then
      LogMain(Format('FlushMountWorker: still waiting, pending=%d (%d s)',
        [FMountPending, Spins div 1000]));
  end;
  if FMountPending > 0 then
    LogMain(Format('FlushMountWorker: TIMEOUT with pending=%d — scenes may still be in use',
      [FMountPending]));
end;

{ Покадровая синхронизация видимости сцен фонового монтажа. Сцена видима ровно
  когда тайл активен И уже наполнен фоновым потоком (MountLoaded). Это «догоняет»
  активацию после завершения фоновой загрузки (ActivateTile мог сработать, пока
  MountLoaded был ещё False) и держит инертной незагруженную сцену (в т.ч.
  MountFailed — она так и остаётся скрытой). }
procedure TOsm3dStreamingMap.SyncMountedExists;
var
  Bi, Ti: Integer;
  Bn: TCacheBatch;
  CT: TCacheTile;
  Sc: TProfiledScene;
  Want: Boolean;
begin
  if FBatchList = nil then Exit;
  for Bi := 0 to FBatchList.Count - 1 do
  begin
    Bn := FBatchList[Bi];
    if (Bn = nil) or (Bn.Tiles = nil) then Continue;
    for Ti := 0 to Bn.Tiles.Count - 1 do
    begin
      CT := Bn.Tiles[Ti];
      if (CT = nil) or (CT.Scene = nil) then Continue;
      Sc := CT.Scene;
      if InterlockedCompareExchange(Sc.MountFinished, 0, 0) = 0 then Continue;
      if Sc.MountFailed and not Sc.MountErrorHandled then
      begin
        Sc.MountErrorHandled := True;
        LogMain(Format('[mount] tile=%s attempt=%d failed: %s',
          [CT.Tile.ToString, Sc.MountAttempts, Sc.MountError]));
        EnsureLoadTile(CT.Tile);
        if Sc.MountAttempts < 2 then
        begin
          EnqueueMount(Sc, Sc.MountRoot);
          Continue;
        end;
        if FWarmupShown then WarmupFail(2,
          CT.Tile.ToString + ': ' + Sc.MountError);
      end;
      if Sc.MountLoaded and not Sc.MountActivated then
      begin
        Sc.MountActivated := True;
        SwapGreenToDetail(CT.Tile);
      end;
      Want := CT.Active and Sc.MountLoaded;
      if Sc.Exists <> Want then
      begin
        Sc.Exists := Want;
        FFarClipDirty := True;
      end;
      if Sc.MountLoaded and (FAsmPending = 0) and (FMountPending = 0) then
        Sc.ReleasePreparedTextureImages;
    end;
  end;
end;

constructor TRouteSnapWorker.Create(AMap: TOsm3dStreamingMap);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1742);{$ENDIF}
  { Suspended — Execute must not start until FMap is assigned. }
  inherited Create(True);
  FreeOnTerminate := False;         { the map joins + frees it }
  FMap := AMap;
  Start;
end;

constructor TFitCorrOnlyWorker.Create(AMap: TOsm3dStreamingMap);
begin
  inherited Create(True);           { suspended до присвоения FMap }
  FreeOnTerminate := False;         { карта джойнит + освобождает }
  FMap := AMap;
  Start;
end;

procedure TFitCorrOnlyWorker.Execute;
begin
  try
    if not (Terminated or FMap.FSnapCancel) then
    begin
      { Тяжёлое (BuildFitBank+DEM+сплайн) — off-thread; публикация голубых
        высот — на главном потоке (Queue). Тайлы/меши не трогаем: при
        FitLayerBuild=False PublishFitCorrection только ставит FRouteAltCal. }
      FMap.ComputeFitCorrectionOffThread;
      Queue(@FMap.PublishFitCorrection);
    end;
  except
    on E: Exception do
      FMap.LogMain('fit-corr-only worker failed: ' + E.Message);
  end;
end;

{ Пересекает ли отрезок трека P0-P1 гео-бокс B (оси-выровненный, в
  градусах). Лианг–Барски: клип параметра t по четырём границам. Нужен
  фильтру тайлов снап-воркера: bbox маршрута — прямоугольник, а трек
  реально проходит лишь через часть его тайлов. }
function TOsm3dStreamingMap.ComputeSnapTiles: TGeoTileIdArray;
begin
  Result := RouteCoverageTiles(FCache.Grid, FRoute, ROUTE_SNAP_MARGIN_M);
  LogMain(Format('route snap: %d tiles on the track', [Length(Result)]));
end;

procedure TRouteSnapWorker.Execute;
var
  Tiles:      TGeoTileIdArray;
  I:          Integer;
  ObstacleIndex: TBuildingObstacleIndex;
  Footprints: TBuildingObstacleArray;
  FootOrigin: TLatLon;
  FootCenter: TVector3;
  Ride: TRouteLatLonArray; RideWidths: TRouteWidthArray;
  RideSource: TRouteSourceArray;
  DetourCount: Integer; PrepStart: QWord;
  Model:      TTileModel;
  Segs:       TSnapSegmentArray;
  SegCap, SegN: Integer;
  CachedTiles, MissingTiles: Integer;
  WaitDeadline: QWord;          { скользящий дедлайн застоя прогрева }
  SideSegs: TTileRoadSegArray;  { сайдкар-путь харвеста }
  SideOrigin: TLatLon;
  LastCachedN, CachedNowN: Integer;
  LastWorkTick, WorkTick: QWord;
  { локальные результаты снапа: публикуются в FMap.FPending* одним
    присваиванием каждый ПОСЛЕ возврата Snap (main заберёт в OnRouteSnapDone) }
  CachePath: String;
  CacheHit, HarvestComplete: Boolean;
  SnapRes:     TRouteLatLonArray;
  SnapWidths:  TRouteWidthArray;
  SnapCenters: TRouteLatLonArray;
  SnapWays:    TRouteWayIdArray;

  procedure PushSeg(const ASeg: TSnapSegment);
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1743);{$ENDIF}
    if SegN >= SegCap then
    begin
      SegCap := SegCap * 2;
      SetLength(Segs, SegCap);
    end;
    Segs[SegN] := ASeg;
    Inc(SegN);
  end;

  { Harvest one tile's road centerline segments (tile-local) into the
    snapper's world-frame segment array. Общая часть (маппинг координат):
    tile-local → chunk/world XZ — add the tile centre; FProj maps it the
    same way the route is mapped, so segments and route share one frame. }
  procedure PushWorldSeg(const HRS: TTileRoadSeg; const HCtr: TVector3;
    HKx: Double);
  var
    HSeg: TSnapSegment;
    WorldSeg: TTileRoadSeg;
  begin
    WorldSeg := RoadSegmentToFrame(HRS, HCtr, HKx);
    { BRIDGE_SNAP: pass IsBridge so snap prefers deck over under-road. }
    if TRouteSnapper.MakeSnapSegment(
         WorldSeg.X0, WorldSeg.Z0, WorldSeg.X1, WorldSeg.Z1,
         WorldSeg.Width, WorldSeg.WayId, HSeg, WorldSeg.IsBridge,
         WorldSeg.Surface.WidthStart,WorldSeg.Surface.WidthEnd) then
      PushSeg(HSeg);
  end;

  { Харвест из сайдкара '.roads' (без полного парсинга x3d). }
  procedure HarvestSegs(const ASegs: TTileRoadSegArray;
    const AOrigin: TLatLon; const AId: TGeoTileId);
  var
    HK:   Integer;
    HCtr: TVector3;
    HKx: Double;
  begin
    if Length(ASegs) = 0 then Exit;
    HCtr := FMap.FProj.Project(AOrigin);
    HKx := FMap.TileScaleX(AId);
    for HK := 0 to High(ASegs) do
      PushWorldSeg(ASegs[HK], HCtr, HKx);
  end;

  { Фолбэк-харвест из полного x3d (старый кэш без сайдкара). }
  procedure HarvestTile(M: TTileModel);
  var
    HK:   Integer;
    HCtr: TVector3;
    HKx: Double;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1744);{$ENDIF}
    if (M = nil) or (M.RoadSegCount = 0) then Exit;
    HCtr := FMap.FProj.Project(M.Origin);
    HKx := FMap.TileScaleX(M.TileId);
    for HK := 0 to M.RoadSegCount - 1 do
      PushWorldSeg(M.RoadSegs[HK], HCtr, HKx);
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1745);{$ENDIF}
  Segs   := nil;
  Tiles  := nil;
  CachedTiles  := 0;
  MissingTiles := 0;
  try
    FMap.LogMain(Format('route snap: starting — %d route points',
      [Length(FMap.FRoute)]));
    if Length(FMap.FRoute) < 2 then
    begin
      FMap.LogMain('route snap: route too short — aborted');
      Exit;
    end;

    { Тайлы маршрута посчитаны на главном потоке в BeginRouteSnap
      (ComputeSnapTiles — там же показан оверлей прогрева). }
    Tiles := FMap.FSnapForceTiles;
    if Length(Tiles) = 0 then
    begin
      FMap.LogMain('route snap: no tiles on track — aborted');
      Exit;
    end;

    CachePath := RouteSnapCachePath(FMap.FCache,Tiles,FMap.FRoute,
      FMap.FOrigin,FMap.FWorldScaleLat);
    if Terminated or FMap.FSnapCancel then Exit;
    CacheHit := LoadRouteSnapCache(CachePath,Length(FMap.FRoute),
      SnapRes,SnapCenters,SnapWidths,SnapWays);
    if CacheHit then
    begin
      FMap.FSnapProgressPt := Length(FMap.FRoute);
      FMap.LogMain(Format('route snap cache: hit (%d points), skipping harvest and snap',
        [Length(SnapRes)]));
    end else
    begin
    FMap.LogMain('route snap cache: miss');
    HarvestComplete := True;
    SegCap := 4096;
    SetLength(Segs, SegCap);
    SegN := 0;

    { 2. force the route's tiles through the normal streamer pipeline
 The tile list is already published (FSnapForceTiles, BeginRouteSnap);
 raise the hold flag. The main-thread Update then WantTiles every tile
 each frame and freezes streamer eviction, so the streamer builds
 (carves) each block ONCE via its own gen workers and persists it
 (DoOneGenJob -> FCache.Save). We reuse that result — nothing is
 built/carved separately here. }
    FMap.FSnapHoldEviction := True;
    try
      { Wait for route tiles. A finished work range/stage advances the
        watchdog even before the first whole tile can be cached. Repeated
        identical notifications do not keep a stalled generator alive. }
      WaitDeadline := GetTickCount64 + SNAP_STALL_TIMEOUT_MS;
      LastCachedN  := -1;
      LastWorkTick := 0;
      repeat
        if Terminated or FMap.FSnapCancel then Exit;
        CachedNowN := 0;
        for I := 0 to High(Tiles) do
          if FMap.FCache.Has(Tiles[I]) then
            Inc(CachedNowN);
        if CachedNowN = Length(Tiles) then Break;
        WorkTick := FMap.FStreamer.LastProgressTickForTiles(Tiles);
        if (CachedNowN > LastCachedN) or (WorkTick > LastWorkTick) then
        begin
          LastCachedN  := CachedNowN;
          LastWorkTick := WorkTick;
          WaitDeadline := GetTickCount64 + SNAP_STALL_TIMEOUT_MS;
        end;
        if GetTickCount64 > WaitDeadline then
        begin
          FMap.LogMain(Format('route snap: no completed work for %d s '
            + '(%d/%d cached) — pipeline stalled, '
            + 'harvesting whatever is cached so far',
            [SNAP_STALL_TIMEOUT_MS div 1000, CachedNowN, Length(Tiles)]));
          { Предупреждение на оверлей прогрева: пайплайн деградирует
            (харвестим что есть), езда не блокируется — main покажет
            красную плашку и пометит этап «Прогрев тайлов». }
          FMap.FSnapError := Format(
            UiText('not all tiles loaded: %d/%d — route partially snapped'),
            [CachedNowN, Length(Tiles)]);
          FMap.FSnapErrorStage := 1;
          Break;
        end;
        Sleep(50);
      until False;

      if Terminated or FMap.FSnapCancel then Exit;

      { 4. harvest road segments straight from the ready (cached) tiles —
 nothing is generated here, the streamer already built and cached them.
 Публикуем прогресс harvest по тайлам: экран прогрева красит клетки
 зелёным (FSnapForceTiles совпадает с Tiles по индексу). }
      { Fingerprint the exact road inputs BEFORE harvesting. If they change
        during the calculation, the result is not reusable. }
      CachePath := RouteSnapCachePath(FMap.FCache,Tiles,FMap.FRoute,
        FMap.FOrigin,FMap.FWorldScaleLat);
      FMap.FSnapHarvestN   := 0;
      FMap.FSnapHarvesting := True;
      for I := 0 to High(Tiles) do
      begin
        Model := nil;
        if FMap.FCache.Has(Tiles[I]) then
        begin
          Inc(CachedTiles);
          { Быстрый путь: сайдкар '.roads' (миллисекунды). Полный парсинг
            x3d (~1 с/тайл; 25 с на маршруте) — только фолбэк для тайлов
            старого кэша без сайдкара. }
          if FMap.FCache.TryLoadRoadSegs(Tiles[I], SideSegs, SideOrigin) then
            HarvestSegs(SideSegs, SideOrigin, Tiles[I])
          else if FMap.FCache.TryLoad(Tiles[I], Model) and (Model <> nil) then
          begin
            try
              HarvestTile(Model);
            finally
              Model.Free;
            end;
          end
          else
          begin
            HarvestComplete := False;
            FMap.LogMain('route snap: tile ' + Tiles[I].ToString
              + ' present but failed to load');
          end;
        end
        else
          Inc(MissingTiles);
        FMap.FSnapHarvestN := I + 1;   { тайл I прогружен }
      end;
      FMap.FSnapHarvesting := False;
    finally
      { release the hold so the streamer resumes eviction — even on
        cancel / timeout / exception }
      FMap.FSnapHoldEviction := False;
    end;

    SetLength(Segs, SegN);
    FMap.LogMain(Format(
      'route snap: harvested %d road segments — %d tiles cached, %d tiles missing',
      [SegN, CachedTiles, MissingTiles]));

    if SegN = 0 then
      FMap.LogMain('route snap: NO road segments found — '
        + 'either route tiles are not cached yet, or cached tiles '
        + 'predate the road-segment cache format (regenerate)');

    if Terminated or FMap.FSnapCancel then Exit;

    FMap.FSnapProgressPt := 0;
    SnapRes := TRouteSnapper.Snap(
      FMap.FRoute, Segs, FMap.FProj, SnapWidths, SnapCenters,
      FMap.FMainLog,
      { Подробный дамп фита ВЫКЛЮЧЕН (''): он писал ~20 тыс. строк на
        каждый снап и был нужен для отладки снаппера. Чтобы включить
        обратно, передайте сюда путь, например
        FMap.FCache.RootDir + 'fit_snap_debug.log'. }
      '',
      { фронтир для анимации перекраски маршрута на экране прогрева }
      @FMap.FSnapProgressPt,
      { пер-точечные way id снапа — для высоты зелёных маркеров/пути
        (на мосту Y берётся с настила, вершины которого несут id мостовой
        way, а не с рельефа под пролётом) }
      @SnapWays);
    FMap.LogMain(Format('route snap: snapper returned %d points',
      [Length(SnapRes)]));
    if not (Terminated or FMap.FSnapCancel) and HarvestComplete and
      (MissingTiles=0) and (CachedTiles=Length(Tiles)) and (SegN>0) and
      (FMap.FSnapError='') and (Length(SnapRes)=Length(FMap.FRoute)) and
      (CachePath<>'') and (CachePath=RouteSnapCachePath(FMap.FCache,Tiles,
        FMap.FRoute,FMap.FOrigin,FMap.FWorldScaleLat)) then
      if SaveRouteSnapCache(CachePath,SnapRes,SnapCenters,SnapWidths,SnapWays) then
        FMap.LogMain(Format('route snap cache: saved (%d points)',[Length(SnapRes)]))
      else FMap.LogMain('route snap cache: write failed, using calculated route');
    end; { cache miss }
    if Terminated or FMap.FSnapCancel then Exit;


    { Публикация результатов: FPending* заполняются одним присваиванием
      каждый, ДО Queue — главный поток перенесёт их в FRouteSnapped/
      FRouteWidths/FRouteCenters/FRouteWays в OnRouteSnapDone. }
    { Private worker index from all route tiles, including unloaded tiles.
      No access to the live index, no geometry decoding and no GL work. }
    PrepStart:=GetTickCount64;
    ObstacleIndex:=TBuildingObstacleIndex.Create;
    try
      for I:=0 to High(Tiles) do
      begin
        if Terminated or FMap.FSnapCancel then Exit;
        if not FMap.FCache.Has(Tiles[I]) then Continue;
        if not FMap.FCache.TryLoadBuildingObstacles(Tiles[I],Footprints,FootOrigin) then Continue;
        FootCenter:=FMap.FProj.Project(FootOrigin);
        Footprints:=OffsetObstaclesXZ(Footprints,FootCenter.X,FootCenter.Z,
          FMap.TileScaleX(Tiles[I]));
        ObstacleIndex.AddObstacles(Footprints,Tiles[I].ToKey);
        Footprints:=nil;
      end;
      PrepareBuildingSafeRoute(SnapCenters,SnapWidths,FMap.FProj,ObstacleIndex,
        Ride,RideWidths,DetourCount,@RideSource);
      if RouteNeedsTurnarounds(SnapCenters) then
        FMap.LogMain(Format('route mode: out-and-back, endpoint gap %.1f m, no closing edge',
          [SnapCenters[0].DistanceTo(SnapCenters[High(SnapCenters)])]));
      FMap.LogMain(Format('route buildings: %d obstacles, %d detours, %d ride points, %d ms',
        [ObstacleIndex.Count,DetourCount,Length(Ride),GetTickCount64-PrepStart]));
    finally ObstacleIndex.Free end;
    if Terminated or FMap.FSnapCancel then Exit;
    { A snap cache hit skips road harvesting. Read only its small sidecars
      for cross traffic; never reparse tile geometry or rerun the snapper. }
    if CacheHit then begin
      SegCap:=4096;SegN:=0;SetLength(Segs,SegCap);
      for I:=0 to High(Tiles)do begin
        if Terminated or FMap.FSnapCancel then Exit;
        if FMap.FCache.TryLoadRoadSegs(Tiles[I],SideSegs,SideOrigin)then
          HarvestSegs(SideSegs,SideOrigin,Tiles[I]);
      end;
      SetLength(Segs,SegN);
    end;
    FMap.FPendingBotCrossings:=TRouteSnapper.BotCrossings(SnapCenters,Segs,FMap.FProj,SnapWays);
    FMap.LogMain(Format('route cross traffic: %d junction routes',[Length(FMap.FPendingBotCrossings)]));
    FMap.FPendingRide:=Ride;
    FMap.FPendingRideWidths:=RideWidths;
    FMap.FPendingRideSource:=RideSource;
    FMap.FPendingSnapped := SnapRes;
    FMap.FPendingWidths  := SnapWidths;
    FMap.FPendingCenters := SnapCenters;
    FMap.FPendingWays    := SnapWays;

    { 5. publish + mount green on the main thread
 Queue (not Synchronize): the worker must not block on the main
 thread, or TThread.WaitFor in the map's destructor would deadlock
 against a worker parked inside Synchronize. Queue is serviced by
 the main thread's CheckSynchronize on its own schedule. }
    if not (Terminated or FMap.FSnapCancel) then
    begin
      { Коррекцию террейна по FIT строит ОТДЕЛЬНЫЙ фоновый поток,
        ПАРАЛЛЕЛЬНО публикации снапа. Раньше ComputeFitCorrectionOffThread
        шёл ЗДЕСЬ, до Queue(OnRouteSnapDone), — и BuildFitBank (~40 с)
        целиком входил в гейт старта езды (RoutePrepDone ждёт
        FSnapWorker.Finished). Владение/гонки: коррекция читает только
        иммутабельные на снапе данные (FRoute/FProj/FHmFetcher/
        FRoutesFolder/FSelectedFit), пишет FPending*-поля и счётчики
        FFitCorrProg*; FRouteSnapped ей НЕ нужен (проверено по коду —
        ни чтения, ни записи). Публикация — только main
        (Queue → PublishFitCorrection внутри TFitCorrOnlyWorker). }
      FMap.FFitCorrProgCur   := 0;
      FMap.FFitCorrProgTotal := 0;
      FMap.FFitCorrStageRun  := True;   { Update поведёт этап «Коррекция высот» }
      if FMap.FFitCorrWorker <> nil then
      begin
        FMap.FFitCorrWorker.WaitFor;    { прошлый проход (лёгкий путь) }
        FreeAndNil(FMap.FFitCorrWorker);
      end;
      FMap.FFitCorrWorker := TFitCorrOnlyWorker.Create(FMap);
      Queue(@FMap.OnRouteSnapDone);
    end;
  except
    on E: Exception do
    begin
      FMap.LogMain('route snap worker failed: ' + E.Message);
      { Ошибку — на оверлей прогрева (main покажет красную плашку и
        пометит этап «Притягивание маршрута»). Езда не блокируется:
        RoutePrepDone считает воркер завершённым и при исключении. }
      FMap.FSnapError      := 'притягивание маршрута: ' + E.Message;
      FMap.FSnapErrorStage := 3;
    end;
  end;
end;

end.
