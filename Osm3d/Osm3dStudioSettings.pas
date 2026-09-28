unit Osm3dStudioSettings;

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$codepage UTF8}

interface

uses
  Classes,
  SysUtils,
  Osm3dWind,                { общий ветер сцены: TWindConfig / GlobalWind }
  Osm3dGeoMath,             { WorldScaleLatBand — полоса масштаба мира }
  Osm3dCache                { DEFAULT_MEMORY_CACHE_BYTES — single source of truth for cache size }
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
;

const
  { Canonical default values
 These back BOTH the module-level "*Active" mirror globals below AND
 the corresponding fields in TStudioSettings.Defaults. Declaring the
 default once here is the whole point: a mirror var initialiser is
 evaluated at unit load, before any settings record exists, so it
 cannot call TStudioSettings.Defaults — without a shared constant the
 two drift apart silently. Change a default here and both sites move together.

 NB: untyped constants (no ': Type ='). A *typed* constant in FPC is
 really an initialised variable and cannot initialise another const
 or var — untyped ones are true compile-time constants and can. }
  DEF_WATER_SHADERS      = True;    { Open Sea Gerstner+FBM water ON by default }
  DEF_WATER_WAVE_SIZE    = 0.55;    { FBM micro frequency (see WaterWaveSize doc) }
  DEF_WATER_LEVEL_LIFT   = 0.02;    { metres — slight lift over carved basin }
  DEF_WATER_SEA_STATE    = 0.45;    { Open Sea intensity 0..1 (~"Sea State 45") }
  DEF_BUILDING_TEXTURES  = True;
  DEF_BUILDING_PBR       = True;
  DEF_GROUND_SHADOWS     = True;   { CPU ground-shadow mask + generation, OFF by default }

  { World geometry / tiling / distances
 Spatial tuning knobs for the whole world scale. This unit is THE
 single edit point — change a value here and every module picks it
 up. All are plain untyped compile-time constants (no const-context
 use), so any module that needs one simply does
 `uses Osm3dStudioSettings`.

 To make this the single source the unit was lifted ABOVE the geo
 primitives in the uses graph: it no longer imports Osm3dGeoTileGrid
 or Osm3dGeoTileBlock, so those primitives now import THIS unit and
 read GEO_TILE_EDGE_M / GEO_BLOCK_SIZE from here.

 NOT collected here, deliberately:
 • Geodetic / projection constants — WGS84_*, UTM_*, EARTH_RADIUS_M,
 DEG_TO_RAD, RAD_TO_DEG, WEB_MERCATOR_MAX_LAT — and the *_LIFT_M
 coplanar z-bias values stay in Osm3dGeoMath / Osm3dGeoTileGrid.
 They are coordinate-system DEFINITIONS, not tuning knobs. }

  { Geo-tile grid — THE definition. The tile lattice is now SLIPPY
    (Web-Mercator pixels at HeightmapZoom), so the edge is defined in
    heightmap PIXELS (GEO_TILE_EDGE_PX), not metres. GEO_TILE_EDGE_M is
    kept only as a nominal metric hint for logs / fallbacks. Edit here and
    nowhere else; geo primitives, cache, streamer and tiler resolve from these. }
  { GEO_TILE_EDGE_M — теперь var (зеркало GlobalLODConfig.GeoTileEdgeM), см. ниже }
  { Tile edge in heightmap pixels at HeightmapZoom. MUST satisfy
    EdgePx | 256 (GPX0 is a multiple of 256 = Terrarium tile border) and
    Step | EdgePx (mesh-node alignment). 16 px ≈ 205 m at Munich/z13; the
    metric size varies with latitude (inherent to Web-Mercator). This is the
    single edit point for tile granularity. }

  { Сшивка границ тайлов (border weld)
 Aligned tiling кладёт общие вершины РОВНО на линию границы, поэтому полоса
 флагирования должна покрывать лишь float-погрешность вокруг неё. 1 м с запасом; можно туже. }
  TILE_BORDER_BAND_M     = 1.0;    { ширина приграничной полосы, м }
  { Радиус совпадения при сварке (XZ, м). Соседняя вершина в пределах
    этого радиуса считается той же точкой и подменяет новую. }
  TILE_BORDER_WELD_EPS_M = 0.30;
  { Master switch for the mount-time border weld (flagging in
    RebaseTileToConventional + the snap in TOsm3dStreamingMap). True (default)
    = weld on, removing the rare 1-ULP straddle on tiles far from the session
    origin. False = no flagging; the weld no-ops (early-out on empty BorderIdx).
    The rebase already stores canonical tile-local (W_vert - W_centre); the weld
    only fixes the sub-ULP straddle the GPU's Single (local+centre) re-introduces
    at large world magnitude. Verify on FAR tiles before setting False. }
  WELD_TILE_BORDERS = True;

  { Generation parameters — NOT view distances
 These size CPU-side generation work, not how far the camera sees,
 so they are deliberately NOT part of the view-distance config (TLODConfig). }

  { Decoded-tile caches inside the long-lived, session-shared providers
    (TTerrariumFetcher / TOverpassClient). Bounded by tile COUNT — the
    bricks are deduped across blocks and previews, so a few hundred
    covers a wide working set without unbounded growth.
      • height: 256 × (256×256×4 B) ≈ 64 MB worst case.
      • overpass: 256 parsed tile fragments (a fraction of that). }
  HEIGHT_TILE_CACHE_MAX   = 256;
  OVERPASS_FRAG_CACHE_MAX = 256;

  { Vegetation polygon dicing + scatter — Osm3dGeomVegetation. }
  { SPLIT_THRESHOLD_M / TILE_SIZE_M — теперь var (зеркало GeoTileEdgeM), см. ниже }
  //TILE_SIZE_M       = 100.0;            { vegetation scatter sub-grid cell }
  MAX_BBOX_M        = 15000.0;           { reject absurdly large polygons }
  ROAD_CLEAR_M      = 2.0;              { extra tree clearance past road half-width }

  { Far terrain — Osm3dGeomTerrain. }
  FAR_DEPRESS_M = 50;         { far mesh sink below composite (anti z-fight) }

  { Ground-carve coarseness (perf vs terrain detail) — Osm3dGeomTerrain
 The carve boolean and material footprints are IDENTICAL at any value here;
 only tessellation density changes. CARVE_CELL_STEP = heightmap grid nodes
 per carve-cell edge: 1 = carve on the full terrain grid (finest, current);
 2/4 = coarser cells, far fewer pieces to clip/weld/stitch. DRAPE_MAX_EDGE_M:
 when draping the flat carved composite, split triangles longer than this
 before sampling height, so terrain detail stays fine even with coarse cells
 (set near the terrain grid step). Tune these to find the speed/quality knee. }
  CARVE_CELL_STEP:  Integer = 1;
  DRAPE_MAX_EDGE_M: Single  = 5.0;

var
  { Master switch for ALL shader profiling (atomic counters AND the
    non-invasive pipeline-statistics queries). When True:
      - AttachCounterEffectFS/VS inject atomicCounterIncrement into the
        FS/VS of every tracked shape (water/houses/shadows) for the
        PER-CATEGORY breakdown; FormatStats reports those counts and the
        readback shows as "sync Nµs" in the FPS overlay.
      - TShaderProfiler's GL_*_SHADER_INVOCATIONS pipeline queries run for
        the 'trees'/'shrubs' vegetation sections (raw instanced draws — the
        only geometry this mechanism can bracket; CGE batches everything
        else, so a query around a tile scene's draw would catch nothing).

    PERFORMANCE WARNING — the ATOMIC half only:
      1. atomicCounterIncrement is a shader side-effect — the GPU cannot
         use early-Z to discard occluded fragments before the FS, so
         every tracked fragment runs even when hidden.
      2. glGetBufferSubData in AdvanceFrame is a pipeline drain. At high
         fragment counts this is 5–15 ms per frame.
    The pipeline-statistics queries have none of these costs (no shader
    edit, early-Z intact, fence-free 1-frame-lagged readback).

    Keep False for production. When False the ENTIRE profiler is inert:
    no glBeginQuery, no readback, no injected effects, FormatStats returns
    empty — zero measurable per-frame cost. }
  EnableShaderAtomicCounters: Boolean = False;

  { Live mirror of TStudioSettings.WaterShaders, driven by
    TOsm3dMapTransform's property setter (same mechanism as
    EnableShaderAtomicCounters above). Read by the geometry builder
    and the scene assembler — both run without a settings handle and
    need to know, at assembly time, whether to keep water OUT of the
    ground composite and emit it as a separate shader-driven shape.
    Initial value is the canonical DEF_* default — same as Defaults. }
  WaterShadersActive: Boolean = DEF_WATER_SHADERS;

  { Live mirror of TStudioSettings.WaterWaveSize — read by the scene
    assembler (no settings handle) when attaching the water effect. }
  WaterWaveSizeActive: Single = DEF_WATER_WAVE_SIZE;

  { Live mirror of TStudioSettings.WaterLevelLift — read by the scene
    assembler to lift shader-driven water above surrounding terrain. }
  WaterLevelLiftActive: Single = DEF_WATER_LEVEL_LIFT;

  { Live mirror of TStudioSettings.WaterSeaState — Open Sea swell intensity. }
  WaterSeaStateActive: Single = DEF_WATER_SEA_STATE;

  { Live mirrors of the building-facade-texture toggles, read by the
    scene assembler (no settings handle). See TStudioSettings. }
  BuildingTexturesActive: Boolean = DEF_BUILDING_TEXTURES;
  BuildingPBRActive:      Boolean = DEF_BUILDING_PBR;

  { Live mirror of TStudioSettings.GenerateGroundShadows — read by the
    scene assembler (no settings handle) to gate ALL ground-shadow work:
    silhouette projection + registry, per-tile mask + overlay effect, and
    the cross-pack PushShadowsForPack. When False, no shadow is generated
    and no mask texture is built or attached. Same mechanism as Water*. }
  GroundShadowsActive:    Boolean = DEF_GROUND_SHADOWS;
  { CPU shadow-mask bit-depth OPTION: 8/4/2/1 bits per texel (R8/R4/R2/R1).
    Lower bits -> less memory + fewer levels; resolution is separate (see
    ShadowMaskRes). Read at shader-build time (BuildShadowMaskEffect) so the
    unpack GLSL is specialised per depth with NO runtime branches. Change the
    default to pick the depth at compile time, or set at runtime before mount. }
  ShadowMaskBitsActive:   Integer = 8;

  { Bit depth of the SEPARATE tree shadow mask (buildings use
    ShadowMaskBitsActive above). The tree mask is TWO channels packed per
    logical texel -- darkness + sway-weight (for wind animation): 4 -> R4x2
    (two nibbles, 1 byte/texel), 8 -> R8x2 (two bytes/texel). Read at
    shader-build time; picks the tree unpack + the packed-byte count. }
  ShadowMaskBitsTree:     Integer = 4;

  { Live mirror of TStudioSettings.BuildingShadows — read by MountAssembled
    (TEST scaffolding) to inject a Global, Shadows:=True sun into each tile
    root so CGE renders a shadow map for it. (Scene.ShadowMaps defaults True;
    the light's Shadows flag marks the caster — the enable lives on the scene,
    not on RenderOptions.) Same live-mirror mechanism as GroundShadowsActive;
    pushed by ApplyStudioSettingsToGlobals. }
  BuildingShadowsActive:  Boolean = False;

  { Live mirrors of the TStudioSettings.Render* visualisation toggles,
    read by the scene assembler (no settings handle) at the top of its
    per-record dispatch loop. When False the matching category's shape /
    effect / GPU state is never created. Base ground + landuse + roads share
    ONE ground composite, so it is the whole ground surface: dropped when
    EITHER road or landuse rendering is off (shown only when both are on).
    Pushed by ApplyStudioSettingsToGlobals. Trees and labels are gated
    where they have a settings handle and need no mirror. }
  RenderBuildingsActive: Boolean = True;
  RenderFencesActive:    Boolean = True;
  RenderRoadsActive:     Boolean = True;
  { RenderTreesActive — mirror kept for symmetry/diagnostics; the vegetation
    gate in TOsm3dStreamingMap reads ASettings.RenderTrees directly at
    construction, so this mirror is informational. }
  RenderTreesActive:     Boolean = True;
  ProceduralVegetationActive: Boolean = True;
  ProceduralTreeDistance: Single = 100; { camera distance, independent of tree size }
  ProceduralVegetationSeason: Single = 0.25; { visual year phase; summer }
  RenderGrassActive:     Boolean = True;
  GrassBladeLodActive:   Boolean = True;
  RenderLanduseActive:   Boolean = True;
  RenderWaterwaysActive: Boolean = True;
  RenderPOIActive:       Boolean = True;
  { Static POI material batches are built once when mounting a tile.
    Process-local diagnostic fallback; unrelated to viewport dynamic batching. }
  RenderPOIBatchingActive: Boolean = True;
  RenderTrafficSignalsActive: Boolean = True;
  AnimateTrafficSignalsActive: Boolean = True;
  TrafficSignalSwitchChanges: QWord = 0;
  RenderPlatesActive:    Boolean = True;

  { DIAGNOSTIC: number of empty drawn scenes to inject (camera-relative, one
    tiny box each, always in frustum so always drawn). Lets us measure the
    pure per-TCastleScene GPU/draw cost in isolation from any content: set to
    e.g. 0 / 200 / 500, compare [GPU frame time]. Flat slope => scene COUNT is
    free and the real cost is per-scene CONTENT (effect/textures/uniforms);
    rising slope => CGE has a real per-scene overhead. 0 = off. }
  DiagEmptyDrawnScenes: Integer = 0;

  { Spatial scene tiling. After CPU polygon generation and before
    TCastleScene.Load, every mesh is partitioned into XZ cells of
    SCENE_TILE_METERS edge length using triangle centroids (no splitting).
    Each non-empty cell is wrapped in an X3D LOD that hides it when the
    camera is farther than the configured ground visibility from the
    cell centre.

    All tiles share one TCastleScene (single Scene.Load), so textures
    are not duplicated (same X3D node instances referenced by every
    tile that uses them: atlas, road-halo dist-field, cached PNGs).

    SCENE_TILE_METERS = 0 disables tiling (single-shape-per-kind legacy path).

    The non-zero default is tied to GEO_TILE_EDGE_M (the geo-tile grid
    edge, defined above): scene tiles and cache tiles must share the
    same physical size, so the edge length is defined in exactly one
    place. Set this to 0, or another literal, only to deliberately
    decouple them. }
  { SCENE_TILE_METERS удалён — в коде не использовался. }

type
  { Distance-LOD parameters shared across rendering layers.

    Formula in every shader:
        hScale   = 1 + max(0, cameraY - GroundReferenceY) / HeightScaleRef
        nearDist = NearBase × hScale  (sub-LOD: drop normal map)
        farDist  = FarBase  × hScale  (hard cull)

    Trees have no FS normal sampling — only FarMeters is used.
    Ground composite never culls terrain (matId=0) or water (matId=20).
    Buildings: single-stage FarMeters only.

    GroundReferenceY: MainForm.SetupCameraAtRouteStart writes the
    ground-sampled Y at the first waypoint so hScale measures "metres
    above local ground", not absolute world Y (otherwise an alpine
    route at 1500 m gives hScale=16 even sitting on the road). }
  { Только растительность + sub-LOD нормал-карты земли; дальние Far-поля воды/зданий/земли — у
    TLODNode тайла (LodPbrM/LodFullM/LodBoxesM в TStudioSettings). }
  { ЕДИНЫЙ рекорд ВСЕХ настроек дальности: собирает GPU-доли, потоковые радиусы и пороги LODNode
    в одном месте. Активные значения (режим по умолчанию = 72 км FULL) по-прежнему живут в *_M-
    константах в начале модуля (compile-time интерфейс для стримера/карты); Defaults переносит их
    сюда. Готовые режимы — в LOD_MODE_* ниже: присвоить GlobalLODConfig := LOD_MODE_2KM и т.п. }
  TLODConfig = record

    HeightScaleRef:     Single;   { реф высоты камеры для LOD — не дистанция }
    { Решётка гео-тайлов — device-tunable (подгоняется под ГПУ). }
    GeoTileEdgeM:       Double;    { номинальные метры (логи/фолбэк) }
    GeoTileEdgePx:      Integer;   { сторона тайла в пикселях хайтмапа }
    GeoBlockSize:       Integer;   { гео-тайлов на сторону кэш-блока }
    TreesNearMeters:    Single;   { суб-LOD деревьев: дальше — 1 билборд лицом к камере вместо 3-крестовины }
    TreesFarMeters:     Single;   { жёсткий cull билбордов деревьев }
    ShrubsNearMeters:   Single;   { суб-LOD кустов (сброс нормал-мапы) }
    ShrubsFarMeters:    Single;   { жёсткий cull билбордов кустов }
    GroundNearMeters:   Single;   { суб-LOD земли (сброс нормал-мапы) }
    GroundReferenceY:   Single;   { рантайм: ставит SetupCameraAtRouteStart }

    GroundVisibilityM:  Single;   { = per-frame draw cull = ручка }

    { Радиусы потокового «замочной скважины» (ДАЛЬ→БЛИЗ) }
    StreamSceneUnloadM: Single;   { сброс загруженных/смонтированных }
    StreamUnloadM:      Single;   { отмена ещё не загруженного префетча }
    StreamForwardM:     Single;   { префетч по ходу движения }
    StreamNearM:        Single;   { изотропное кольцо полной детали }
    StreamUploadM:      Single;   { сборка GL (монтаж) за draw cull }
    StreamGridRadius:   Integer;  { полу-размер резидентной слот-сетки, тайлы }

    { Пороги per-tile LODNode (WrapTileLOD; строго убывают) }
    LodBoxesM:          Single;   { LODNode lvl3 / пустая дальняя группа (D) }
    LodFullM:           Single;   { LODNode lvl2: простые материалы }
    LodPbrM:            Single;   { LODNode lvl0..1: PBR-материалы }
    Preview1x1M:        Single;   { радиус префетча детали (Pump) }

    BboxPaddingM:       Single;   { ореол Overpass bbox }
    MaxShadowLenM:      Single;   { самая длинная тень здания }

    class function Defaults: TLODConfig; static;
  end;

  TStudioSettings = record

    BboxPaddingMeters:     Single;
    HeightmapZoom:         Integer;    { Slippy tile zoom for Terrarium }
    TerrainGridStepMeters: Single;
    TerrainSubdiv:         Integer;    { bicubic terrain oversampling, 1 = off }
    BlurHeightmapSigmaPx:  Single;     { Gaussian low-pass of the stitched
                                         heightmap, in pixels; 0 = off. Removes
                                         the integer-metre source terracing
                                         before the terrain/road sample it. }
    TraceWidthMeters:      Single;     { route ribbon width in preview }

    { Legacy single endpoint, kept for back-compat. Prefer OverpassEndpoints. }
    OverpassEndpoint:    string;

    { ';'-separated pool. Parallel fan-out across mirrors when OverpassParallel. }
    OverpassEndpoints:   string;

    { Zoom for OSM bbox tiling. At z=14 one tile is ~2.5×1.5 km at
      mid-latitudes; a 47 km route → ~30 tiles, each a few seconds —
      more reliable than one query over the whole bbox. }
    OverpassTileZoom:    Integer;

    { Server-side [timeout:N] in Overpass-QL. 60 s default. }
    OverpassTimeoutS:    Integer;

    { True = TParallelOverpassRunner (faster on typical bboxes);
      False = sequential TOverpassClient.FetchAllTilesInto (easier to diagnose). }
    OverpassParallel:    Boolean;

    TerrariumUrlTemplate: string;
    NetworkTimeoutS:     Integer;       { HTTP socket timeout, not Overpass [timeout:N] }

    CacheRoot:        string;
    MemoryCacheBytes: Int64;

    GenerateBuildings: Boolean;
    GenerateFences:    Boolean;
    GenerateRoads:     Boolean;
    GenerateTrees:     Boolean;
    GenerateLanduse:   Boolean;
    GenerateWaterways: Boolean;

    { GeneratePOI: traffic lights, hydrants, towers, fountains. Default on.
      GenerateLabels: street + building name billboards. Default off
      (large 3D text covers the scene). }
    GeneratePOI:       Boolean;
    GenerateLabels:    Boolean;
    { GeneratePlates: house-number plates on building facades. Default on. }
    GeneratePlates:    Boolean;

    { ── Режим «геометрия только вдоль пути FIT» ─────────────────────────────
      Когда True, потоковая карта генерирует ТОЛЬКО тайлы, чей коридор в
      пределах RouteOnlyRadiusM от ломаной СЫРОГО маршрута (FRoute); остальной
      мир не строится вовсе. Весь коридор пути ставится в очередь генерации
      сразу (не по мере движения камеры), результат кладётся в ОТДЕЛЬНЫЙ
      дисковый кэш — хэш имени .fit входит в gen-hash (см. ComputeGenHash),
      поэтому маршрутные тайлы не смешиваются с полным миром и не
      инвалидируют его. Default False — обычный полный мир. }
    GenerateRouteOnly: Boolean;
    { Радиус коридора вокруг пути (метры), в пределах которого строится
      геометрия тайлов в режиме GenerateRouteOnly. Default 200. }
    RouteOnlyRadiusM:  Single;

    RenderBuildings: Boolean;
    RenderFences:    Boolean;
    RenderRoads:     Boolean;
    RenderTrees:     Boolean;
    RenderGrass:     Boolean;
    RenderLanduse:   Boolean;
    RenderWaterways: Boolean;
    RenderPOI:       Boolean;
    RenderLabels:    Boolean;
    RenderPlates:    Boolean;

    { Ground composition: merges all landuse + roads into one X3D Shape
      with a GLSL effect that samples a texture atlas indexed by a
      per-vertex materialId attribute. Replaces ~30 separate Shapes
      (one per landuse / road class) with one batched draw. }
    UseGroundComposition: Boolean;

    { Diagnostic isolators:
        UseGroundCompositionShader=False — merged shape renders with flat
          PBR grey, no atlas sampling. Distinguishes GLSL/driver bugs
          from merged-geometry bugs.
        UseGroundCompositionMaterialIdAttribute=False — the per-vertex
          materialId attribute is omitted; the shader sees zeros and
          renders everything as material 0. Distinguishes custom-vertex-
          attribute driver bugs from the rest.
      Both should be True in production. }
    UseGroundCompositionShader: Boolean;
    UseGroundCompositionMaterialIdAttribute: Boolean;

    { Atlas: 8 × 4 × 512 px = 4096 × 2048 covering 32 slots. }
    GroundAtlasGridCols:   Integer;
    GroundAtlasGridRows:   Integer;
    GroundAtlasTilePixels: Integer;

    { Far terrain — low-poly horizon from the low-res heightmap of the
      expanded bbox; mountain silhouettes behind the main zone. }
    GenerateFarTerrain:        Boolean;
    FarTerrainExpansionMeters: Single;
    FarTerrainZoom:            Integer;
    FarTerrainGridStepM:       Single;

    { Render each GPS waypoint as a small red sphere at terrain height
      + 1.5 m. Sanity check for route coordinate conversion. }
    ShowFitPoints: Boolean;

    { Render the snapped (road-aligned) copy of the route as green
      spheres. Independent of ShowFitPoints so both overlays can be
      shown together. }
    ShowFitPointsSnapped: Boolean;

    { GPU shadow maps via TDirectionalLightNode.Shadows +
      Scene.RenderOptions.ShadowMaps. Requires FBO depth-texture support;
      enable only on hardware where it's confirmed. }
    BuildingShadows: Boolean;

    { CPU-projected shadow mesh on top of terrain/landuse/roads.
      Driver-independent, deterministic, depends only on sun direction
      derived from RouteStartUTC + chunk origin. +50–200 ms / urban tile,
      a few thousand triangles. See Osm3dGeomShadows. }
    GenerateGroundShadows: Boolean;

    { Animated shader-driven water (Open Sea style: Gerstner swell + FBM
      micro-surface + spectral tint). When False, water is a static flat
      surface shaded by the ground composite. Default True. }
    WaterShaders: Boolean;

    { FBM micro-ripple frequency multiplier: 0.55 matches the Open Sea
      reference; smaller values make broader ripples. Both ripple and swell
      also scale with cached source-water width (sea keeps 1x). }
    WaterWaveSize: Single;

    { Vertical lift (metres) applied to shader-driven water surfaces.
      When water is pulled out of the ground composite for the shader
      path it loses the composite's ZIndex z-bias, so terrain edges can
      overlap it. This lift raises the separate water mesh back above
      the surrounding ground. }
    WaterLevelLift: Single;

    { Open Sea swell intensity 0..1 (≈ Sea State / 100). Affects Gerstner
      amplitude and micro-chop strength. Default 0.45. }
    WaterSeaState: Single;

    { Real building-facade textures. When True, building walls/roofs are
      textured from the PNG facade set under buildings/facades and
      buildings/roofs (block/brick/plaster/wood walls + windows, and the
      roof materials), instead of the procedural FillWall pattern. Each
      of the 6 wall / 6 roof palettes maps to one facade material; the
      diffuse + normal channels are loaded. When False, buildings keep
      the procedural look exactly as before. }
    BuildingTextures: Boolean;

    { Full PBR facade set. Requires BuildingTextures. When additionally
      True, the loader also pulls the mask channel (packed
      roughness/metallic/AO) and the *_glow emissive maps, and building
      materials are emitted as physical (metallic-roughness) materials
      so they respond to light with specular highlights / reflections.
      When False (but BuildingTextures True), only diffuse + normal are
      used and materials stay simple. }
    BuildingPBR: Boolean;

    { Все дистанции (пороги тайлового LODNode, потоковые радиусы, GPU-LOD)
      живут в LOD: TLODConfig — единственный рекорд дальности. }
    LOD: TLODConfig;

    { Ветер сцены — общий для травы и деревьев. Тип/поле живут в Osm3dWind,
      рендереры читают Osm3dWind.GlobalWind (его и пишет Apply ниже). }
    Wind: TWindConfig;

    { Дальность тумана (FogRange), м. 0 = туман выключен — правится
      полем ввода в TStudioMainForm (EndpointsHost), применяется напрямую к
      TCastleViewport.Fog там же; не мигрирует через ApplyStudioSettingsToGlobals,
      т.к. это не глобал рендер-юнитов, а свойство самого Viewport. }
    FogDistanceM: Single;

    { Радиус чистой зоны у камеры (FogClearZone), м. 0 = туман от самой
      камеры. Ближе этого радиуса тумана нет, дальше дальность считается
      ОТ ЕГО ГРАНИЦЫ (полное гашение — на FogDistanceM + FogClearZoneM).
      Живёт рядом с FogDistanceM: то же поле ввода, тот же общий файл. }
    FogClearZoneM: Single;

    { Коррекция высот по FIT-заездам (Osm3dFitHeightLayer) — РАНТАЙМ-слой
      для ФИЗИКИ езды: GroundYAt добавляет нивелированный профиль заездов
      (мосты/настил/сглаживание) к высоте рельефного треугольника под
      колесом. True (дефолт) — физика едет по слою; False — строго по
      сырому Terrarium. Меши, тайлы и дисковый кэш слоем НЕ
      корректируются и от списка фитов не зависят (раньше слой запекался
      в геометрию и входил в gen-hash — тот путь снят).

      Читается в Osm3dStreamingLauncher.Create: строит слой синхронно
      (пофайловый CSV-кэш — тёплый старт секунды, холодный один раз
      десятки секунд) и ставит в физический слот карты; заодно гейтит
      построение воркерского слоя (Map.FitLayerBuild).

      Профиль высот САМОГО маршрута (FRouteAltCal — голубые сферы, столбец
      alt_fitcorr_m в CSV) при False остаётся: это данные заезда, а не
      деформация мира. }
    FitHeightCorrection: Boolean;

    { ═══ ШИРОТА МАСШТАБА МИРА (0 = АВТО, обычный режим) ════════════════
      Задаёт cos, которым равнопромежуточная проекция сжимает ДОЛГОТУ, т.е.
      метрику «востока» всего мира. Широта от неё не зависит — оттого
      рассинхрон и вылезал ровно по одной оси.

      0 (дефолт) = АВТО: широта берётся из полосы WorldScaleLatBand(origin)
      — чистой функции географии с потолком ошибки 0.5% в любой точке
      планеты. Настраивать НИЧЕГО не надо, работает и на экваторе, и за
      полярным кругом.

      <> 0 = РУЧНАЯ ФИКСАЦИЯ местности. Нужна ровно в одном случае: область
      катания ШИРЕ полосы (на 60° полоса 37 км, у здешних заездов размах 39
      км) — тогда заезды с разных краёв попадают в РАЗНЫЕ полосы и пекут
      СВОЙ комплект тайлов. Щелей при этом нет (внутри сессии метрика одна),
      но общего кэша между такими заездами тоже нет. Прибив число вручную
      (для здешней местности 59.77 — середина охвата 59.60…59.94, ошибка на
      краях 0.52%), получаем один комплект тайлов на всю область.

      Раньше сюда шла широта origin СЕССИИ (= маршрута): Студия стартует с
      FRoute[0], игра — с центроида, разница 9.9 км → cos отличался на
      0.265% → тайлы из ОДНОГО кэша расходились. Теперь это свойство
      МЕСТНОСТИ.

      ВЫЧИСЛЕННОЕ значение (EffectiveWorldScaleLat) входит в gen-hash — не
      само поле: иначе два авто-режима с разными полосами схлопнулись бы в
      один ключ и тайлы разной метрики перемешались. }
    WorldScaleLatDeg: Double;

    class function Defaults: TStudioSettings; static;
  end;

  { Указатель на живой record настроек (поле TStudioMainForm.FSettings) —
    используется MCP-фасадом (Osm3dMcp) для published-прокси. }
  PStudioSettings = ^TStudioSettings;

const
  { ════════════════════════════════════════════════════════════════
    РЕЖИМЫ ДАЛЬНОСТИ — набор готовых TLODConfig (от 2 км до 72 км)
    ════════════════════════════════════════════════════════════════
    Каждый режим — ПОЛНЫЙ набор всех дистанций. Активный по умолчанию
    (72 км FULL) живёт в *_M-константах + TLODConfig.Defaults. Чтобы
    переключить набор дистанций в рантайме — присвоить
    GlobalLODConfig := LOD_MODE_2KM (и т.п.) до первой сборки сцены.

    Поля шейдерного GPU-LOD (деревья/кусты/земля) применяются сразу.
    Потоковые радиусы и пороги LODNode стример/карта пока читают из
    *_M-констант на этапе компиляции — для полной смены ИХ нужно либо
    пересобрать с другими *_M, либо перевести стример/карту на чтение
    GlobalLODConfig (см. примечание в шапке TLODConfig).
    Порядок полей строго как в объявлении TLODConfig. }

  { 2 КМ: только уровень A, видимо строго до 2 км
 Деталь (LODNode уровень A) до 2 км, дальше ничего. Пер-тайл диапазоны
 (2000,2100,2200): A для d<2000; B/C/D уже за cull (2000) → не видны =
 только A. Суперы: пороги = 2100, чтобы квадродерево измельчало их до
 базовых тайлов В ПРЕДЕЛАХ ~2 км. КРИТИЧНО: при 0 каскад застревает на
 span-64 (d<0 невозможно), базовый уровень не достигается → детальные
 тайлы НЕ получают Exists:=True (их включает квадродерево) → чёрный
 экран. За 2 км span-64 невидим (FFarM=2100), тайлы отсекает cull. }
  LOD_MODE_2KM: TLODConfig = (
    HeightScaleRef:     100.0;
    GeoTileEdgeM:       500.0;
    GeoTileEdgePx:      256;
    GeoBlockSize:       1;
    { Veg-билборды (деревья/кусты) обязаны доезжать минимум до радиуса
      уровня A земли (LodPbrM/GroundVisibilityM=2000): shadow-mask теней
      живёт ТОЛЬКО на уровне A. При 1800<2000 в кольце 1800..2000 м земля
      ещё уровня A (тени видны), а билборды уже отсечены -> "тени без
      деревьев". Радиус cull-а вегетации >= LodPbrM это закрывает. }
    TreesNearMeters:    800.0;
    TreesFarMeters:     2000.0;
    ShrubsNearMeters:   400.0;
    ShrubsFarMeters:    2000.0;
    GroundNearMeters:   1400.0;
    GroundReferenceY:   0.0;
    GroundVisibilityM:  8000.0;
    StreamSceneUnloadM: 15000.0;
    StreamUnloadM:      15000.0;
    StreamForwardM:     3000.0;
    StreamNearM:        2500.0;
    StreamUploadM:      8000.0;
    StreamGridRadius:   3;
    LodBoxesM:          0.0;
    LodFullM:           2100000.0;
    LodPbrM:            2000000.0;
    Preview1x1M:        0.0;
    BboxPaddingM:       500.0;
    MaxShadowLenM:      200.0
  );

  { 16 КМ: LOD включён, суперы до ~16 км (промежуточный) }
  LOD_MODE_16KM: TLODConfig = (
    HeightScaleRef:     100.0;
    GeoTileEdgeM:       500.0;
    GeoTileEdgePx:      256;
    GeoBlockSize:       1;
    TreesNearMeters:    1500.0;
    TreesFarMeters:     3600.0;
    ShrubsNearMeters:   800.0;
    ShrubsFarMeters:    3600.0;
    GroundNearMeters:   1800.0;
    GroundReferenceY:   0.0;
    GroundVisibilityM:  4000.0;
    StreamSceneUnloadM: 10000.0;
    StreamUnloadM:      8000.0;
    StreamForwardM:     6000.0;
    StreamNearM:        5000.0;
    StreamUploadM:      4400.0;
    StreamGridRadius:   21;
    LodBoxesM:          10000.0;
    LodFullM:           8000.0;
    LodPbrM:            3333.0;
    Preview1x1M:        10500.0;
    BboxPaddingM:       500.0;
    MaxShadowLenM:      200.0
  );

  LOD_MODE_72KM_FULL: TLODConfig = (
    HeightScaleRef:     100.0;
    GeoTileEdgeM:       500.0;
    GeoTileEdgePx:      256;
    GeoBlockSize:       1;
    TreesNearMeters:    1100.0;
    TreesFarMeters:     2700.0;
    ShrubsNearMeters:   600.0;
    ShrubsFarMeters:    2700.0;
    GroundNearMeters:   600.0;
    GroundReferenceY:   0.0;
    GroundVisibilityM:  3000.0;
    StreamSceneUnloadM: 7500.0;
    StreamUnloadM:      6000.0;
    StreamForwardM:     4500.0;
    StreamNearM:        3750.0;
    StreamUploadM:      3300.0;
    StreamGridRadius:   16;
    LodBoxesM:          10000.0;
    LodFullM:           6000.0;
    LodPbrM:            2500.0;
    Preview1x1M:        8500.0;
    BboxPaddingM:       500.0;
    MaxShadowLenM:      200.0
  );

var
  { Rendering units read LOD parameters from here. MainForm should
    assign GlobalLODConfig := FSettings.LOD once at startup before the
    first scene assemble. Initialised to TLODConfig.Defaults so direct
    reads never see uninitialised data. }
  GlobalLODConfig: TLODConfig;

  { CLI-переопределение TStudioSettings.FitHeightCorrection (флаг
    --fitcorr игры): выставляется при разборе параметров командной
    строки ДО создания сессий, в ini не сохраняется. Студия его не
    трогает. TStudioSettings.Defaults копирует это значение.
    Дефолт True: физика езды по слою коррекции — штатное поведение;
    флаг оставлен для совместимости скриптов. }
  FitHeightCorrectionCLI: Boolean = True;

  { Решётка гео-тайлов — глобальные ЗЕРКАЛА полей GlobalLODConfig, чтобы все
    существующие использования (аргументы/сравнения/присваивания) работали без
    правок. Обновляются SyncLatticeGlobals после смены GlobalLODConfig.
    Инициализированы литералами = значениям пресетов (до первого синка). }
  GEO_TILE_EDGE_M:   Double  = 500.0;
  GEO_TILE_EDGE_PX:  Integer = 32;
  GEO_BLOCK_SIZE:    Integer = 1;
  SPLIT_THRESHOLD_M: Double  = 500.0;
  TILE_SIZE_M:       Double  = 250.0;

  { Фоновый монтаж тайловых сцен. True (по умолчанию) — наполнение CGE-сцены
    (Scene.Load) выполняется в отдельном потоке: сцена создаётся пустой с
    Exists=False в основном потоке (механизмы CGE инертную сцену не трогают),
    заполняется в фоне, затем активируется (Exists=True) обратно в main. False —
    синхронный монтаж в основном потоке (прежнее поведение). CGE не гарантирует
    потокобезопасность Scene.Load — при нестабильности выключить. }
  GlobalMountInWorker: Boolean = True;
  { Экспериментально: выносить AssembleCachedTiles (сборку X3D-графа тайла) в
    фоновый поток TAssembleWorker. ВКЛЮЧЕНО для теста стриминга; вернуть в False,
    если всплывут гонки при эвикте/teardown. }
  GlobalAssembleInWorker: Boolean = True;

  { ── Децимация земли вдали от дорог (RQT-укрупнение пустых ячеек карв-сетки).
       OFF по умолчанию: путь карва НЕ меняется, пока выключено. Включение —
       присвоить GlobalTerrainDecimate := True (и при отладке путь PGM) до сборки. }
  GlobalTerrainDecimate:         Boolean = True;
  GlobalTerrainDecimateKeepM:    Single  = 20.0;    { дорога + эта полоса = полная детализация }
  GlobalTerrainDecimateRangeM:   Single  = 80.0;   { дальность прогрессивного укрупнения, м }
  GlobalTerrainDecimateMaxLevel: Integer = 3;      { макс. уровень: блок до 2^L ячеек (стейдж 2) }
  GlobalTerrainDecimateDebugPGM: string  = '';     { не пусто → сохранить карту дорог в этот .pgm (стейдж 1) }

function DefaultCacheRoot: string;

{ Широта масштаба мира, ФАКТИЧЕСКАЯ: ручная фиксация, если задана, иначе
  полоса от широты origin (авто). Единственный источник истины — зовут и
  выпечка (Osm3dBlockGenerator), и расстановка (Osm3dStreamingMap,
  Osm3dSceneAssembler), и ключ кэша (ComputeGenHash). Расхождение любых двух
  из них = щель между тайлами, поэтому дублировать логику нельзя. }
function EffectiveWorldScaleLat(const S: TStudioSettings;
  ALatDeg: Double): Double;

{ ═══ Общий канал «дальность тумана» между Студией и игрой ══════════════
  Студия и игра — два НЕЗАВИСИМЫХ процесса без общей памяти; единственная
  связь между ними — диск. Путь ОБЯЗАН совпадать у обоих без какой-либо
  доп. настройки, поэтому строится от DefaultCacheRoot (детерминирован),
  а не от Settings.CacheRoot (тот в каждом приложении можно переопределить
  по отдельности — тогда файлы разъедутся и канал молча оборвётся). }

{ Путь файла. Папка создаётся при сохранении, если её ещё нет (первый
  запуск на машине, где ни студия, ни игра кэш ещё не поднимали). }
function FogConfigPath: string;

{ Прочитать настройки тумана: дальность и радиус чистой зоны, м. Нет файла /
  битое содержимое / отсутствие доступа → 0/0 (тот же смысл, что «туман
  выключен» в поле ввода) — не бросает, оборачивать в try/except не нужно.
  Файл из одной строки (формат до появления чистой зоны) читается как
  раньше: дальность из строки 0, зона = 0.
  Пара, а не две независимые функции: значения лежат в ОДНОМ файле, и
  раздельное сохранение означало бы read-modify-write — запись одного
  затирала бы второе. }
procedure LoadFogSettings(out ADistanceM, AClearZoneM: Single);

{ Сохранить настройки тумана. Ошибки записи (нет прав, диск занят)
  проглатываются — канал вспомогательный, ронять студию из-за него нельзя. }
procedure SaveFogSettings(const ADistanceM, AClearZoneM: Single);

{ Push the values rendering units read from globals (GlobalLODConfig +
  the *Active flags) out of a settings record. Call once at startup and
  whenever settings change, before the next scene assemble. Replaces the
  old TOsm3dMapTransform.PushSettingsToGlobals. SCENE_TILE_* and
  EnableShaderAtomicCounters keep their declared defaults. }
procedure ApplyStudioSettingsToGlobals(const S: TStudioSettings);
{ Зеркалит решётку из GlobalLODConfig в глобальные var. Звать после смены GlobalLODConfig. }
procedure SyncLatticeGlobals;

implementation

function EffectiveWorldScaleLat(const S: TStudioSettings;
  ALatDeg: Double): Double;
begin
  Result := S.WorldScaleLatDeg;
  { Те же границы валидности, что у TLocalProjection.Create: 0 или |lat|>=90
    = «не задано» → авто-полоса. }
  if (Result <= -90.0) or (Result >= 90.0) or (Result = 0.0) then
    Result := WorldScaleLatBand(ALatDeg);
end;

function DefaultCacheRoot: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(944);{$ENDIF}
  { UI tests must never clear the user's map cache. Like the game's other
    test storage overrides, require an isolated authentication file too. }
  if (GetEnvironmentVariable('REZVIVO_TEST_AUTH_FILE') <> '') and
     (GetEnvironmentVariable('REZVIVO_TEST_CACHE_ROOT') <> '') then
    Exit(UTF8Encode(UnicodeString(GetEnvironmentVariable('REZVIVO_TEST_CACHE_ROOT'))));
  Result := IncludeTrailingPathDelimiter(GetUserDir) +
            '.cache' + PathDelim + 'osm3d';
end;

{ Локальный культурно-независимый формат (точка-разделитель, без разряд.
  разделителя) — по образцу CsvFmt в других юнитах проекта (Osm3dFitLayerBuild
  и т.п.): тривиальный хелпер держим локально, а не тянем ради него внешний
  юнит (Osm3dOsmTagUtils.InvariantFmt) в низкоуровневый Settings-юнит, от
  которого сам зависит почти весь проект — циклической зависимости не хотим. }
function FogCfgFmt: TFormatSettings;
begin
  Result := DefaultFormatSettings;
  Result.DecimalSeparator := '.';
  Result.ThousandSeparator := #0;
end;

function FogConfigPath: string;
begin
  Result := DefaultCacheRoot + PathDelim + 'fog-distance.cfg';
end;

procedure LoadFogSettings(out ADistanceM, AClearZoneM: Single);
var
  L: TStringList;
begin
  ADistanceM := 0;
  AClearZoneM := 0;
  if not FileExists(FogConfigPath) then Exit;
  L := TStringList.Create;
  try
    try
      L.LoadFromFile(FogConfigPath);
      { строка 0 — дальность, строка 1 — чистая зона; однострочный файл
        (старый формат) даёт зону 0 = прежнее поведение }
      if L.Count > 0 then
        ADistanceM := StrToFloatDef(Trim(L[0]), 0, FogCfgFmt);
      if L.Count > 1 then
        AClearZoneM := StrToFloatDef(Trim(L[1]), 0, FogCfgFmt);
    except
      { битый файл — как будто тумана нет, не роняем вызывающего }
      ADistanceM := 0;
      AClearZoneM := 0;
    end;
  finally
    L.Free;
  end;
  if ADistanceM < 0 then ADistanceM := 0;
  if AClearZoneM < 0 then AClearZoneM := 0;
end;

procedure SaveFogSettings(const ADistanceM, AClearZoneM: Single);
var
  L: TStringList;
  Dir: string;
begin
  L := TStringList.Create;
  try
    L.Add(FloatToStr(ADistanceM, FogCfgFmt));
    L.Add(FloatToStr(AClearZoneM, FogCfgFmt));
    try
      Dir := ExtractFilePath(FogConfigPath);
      if (Dir <> '') and not DirectoryExists(Dir) then
        ForceDirectories(Dir);
      L.SaveToFile(FogConfigPath);
    except
      { канал вспомогательный: нет прав / диск занят — не критично }
    end;
  finally
    L.Free;
  end;
end;

procedure SyncLatticeGlobals;
begin
  GEO_TILE_EDGE_M   := GlobalLODConfig.GeoTileEdgeM;
  GEO_TILE_EDGE_PX  := GlobalLODConfig.GeoTileEdgePx;
  GEO_BLOCK_SIZE    := GlobalLODConfig.GeoBlockSize;
  SPLIT_THRESHOLD_M := GEO_TILE_EDGE_M;
  TILE_SIZE_M       := GEO_TILE_EDGE_M * 0.5;
end;

procedure ApplyStudioSettingsToGlobals(const S: TStudioSettings);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1762);{$ENDIF}
  GlobalLODConfig        := S.LOD;
  SyncLatticeGlobals;
  GlobalWind             := S.Wind;
  WaterShadersActive     := S.WaterShaders;
  WaterWaveSizeActive    := S.WaterWaveSize;
  WaterLevelLiftActive   := S.WaterLevelLift;
  WaterSeaStateActive    := S.WaterSeaState;
  BuildingTexturesActive := S.BuildingTextures;
  BuildingPBRActive      := S.BuildingPBR;
  GroundShadowsActive    := S.GenerateGroundShadows;
  BuildingShadowsActive  := S.BuildingShadows;
  RenderBuildingsActive  := S.RenderBuildings;
  RenderFencesActive     := S.RenderFences;
  RenderRoadsActive      := S.RenderRoads;
  RenderTreesActive      := S.RenderTrees;
  RenderGrassActive      := S.RenderGrass;
  RenderLanduseActive    := S.RenderLanduse;
  RenderWaterwaysActive  := S.RenderWaterways;
  RenderPOIActive        := S.RenderPOI;
  RenderPlatesActive     := S.RenderPlates;
end;

class function TLODConfig.Defaults: TLODConfig;
{ OSM lattice overrides are process-wide: ride, route warmup and studio
  must agree before any tile resources or workers are created. Dream worlds
  load their own baked tiles and do not use these lattice dimensions. }
var
  TilePx, BlockSize, DefaultPx, DefaultBlock: Integer;
  TileOverride, BlockOverride: String;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1279);{$ENDIF}
  Result := LOD_MODE_2KM;
  TileOverride := GetEnvironmentVariable('REZVIVO_OSM_TILE_PX');
  BlockOverride := GetEnvironmentVariable('REZVIVO_OSM_BLOCK_SIZE');
  if (TileOverride = '') and (BlockOverride = '') then Exit;
  DefaultPx := Result.GeoTileEdgePx;
  TilePx := StrToIntDef(TileOverride, DefaultPx);
  if (TilePx <> 32) and (TilePx <> 64) and (TilePx <> 128) and
     (TilePx <> 256) then TilePx := DefaultPx;
  DefaultBlock := DefaultPx * Result.GeoBlockSize div TilePx;
  if DefaultBlock < 1 then DefaultBlock := 1;
  BlockSize := StrToIntDef(BlockOverride, DefaultBlock);
  if not (BlockSize in [1, 2, 4, 8]) then BlockSize := DefaultBlock;
  if TilePx * BlockSize > 256 then BlockSize := 256 div TilePx;
  Result.StreamGridRadius := (Result.StreamGridRadius * DefaultPx + TilePx - 1) div TilePx;
  Result.GeoTileEdgePx := TilePx;
  Result.GeoBlockSize := BlockSize;
end;

class function TStudioSettings.Defaults: TStudioSettings;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1280);{$ENDIF}
  { Все дистанции — в LOD (единственный рекорд дальности). Заполняем его
    первым, чтобы поля-производные ниже могли на него ссылаться. }
  Result.LOD := TLODConfig.Defaults;
  Result.Wind := TWindConfig.Defaults;
  Result.FogDistanceM := 0;   { выключен по умолчанию }
  Result.FogClearZoneM := 0;  { туман от самой камеры }
  Result.FitHeightCorrection := FitHeightCorrectionCLI;   { дефолт True — физика на слое; --fitcorr для совместимости }
  { 0 = АВТО: полоса ln-cos от широты origin, потолок 0.5% в любой точке
    планеты, настраивать нечего. Прибить местность вручную — см. поле. }
  Result.WorldScaleLatDeg := 0;

  Result.BboxPaddingMeters     := Result.LOD.BboxPaddingM;
  Result.HeightmapZoom         := 13;            { ~19 m/px in Munich }
  Result.TerrainGridStepMeters := 2;
  Result.TerrainSubdiv         := 2;             { 2-3 -> smooth bicubic ground }
  Result.BlurHeightmapSigmaPx  := 1.0;           { ~1 px low-pass kills the
                                                   integer-metre terracing }
  Result.TraceWidthMeters      := 1.5;

  Result.OverpassEndpoint     := 'https://overpass-api.de/api/interpreter';
  { Discover own/region-specific servers through the game API. Availability
    and public fallback are decided on this machine by the fetch workers. }
  Result.OverpassEndpoints := 'auto';

  Result.OverpassTileZoom     := 14;             { ~1.5×2.5 km/tile @ 60° lat }
  Result.OverpassTimeoutS     := 60;
  Result.OverpassParallel     := True;

  Result.TerrariumUrlTemplate := 'auto';
  Result.NetworkTimeoutS      := 25;

  Result.CacheRoot        := DefaultCacheRoot;
  { Same constant the TMemoryCache constructor uses as its own default —
    no second hardcoded 64 MB literal. }
  Result.MemoryCacheBytes := DEFAULT_MEMORY_CACHE_BYTES;

  Result.GenerateBuildings := True;
  Result.GenerateFences    := True;
  Result.GenerateRoads     := True;
  Result.GenerateTrees     := True;
  { GenerateLanduse REQUIRED for the tree pipeline: landuse=forest provides
    the bulk of forest polygons. Disabling it leaves only the rare natural=wood. }
  Result.GenerateLanduse   := True;
  Result.GenerateWaterways := True;

  Result.GeneratePOI       := True;
  Result.GenerateLabels    := True;
  Result.GeneratePlates    := True;

  { Режим «геометрия только вдоль пути FIT» — по умолчанию ВЫКЛ (полный мир).
    Радиус коридора по умолчанию 200 м. }
  Result.GenerateRouteOnly := False;
  Result.RouteOnlyRadiusM  := 50.0;

  { Render visualisation toggles — all on by default (parallel to Generate*). }
  Result.RenderBuildings   := True;
  Result.RenderFences      := True;
  Result.RenderRoads       := True;
  Result.RenderTrees       := True;
  Result.RenderGrass       := True;
  Result.RenderLanduse     := True;
  Result.RenderWaterways   := True;
  Result.RenderPOI         := True;
  Result.RenderLabels      := True;
  Result.RenderPlates      := True;

  Result.UseGroundComposition  := True;
  Result.UseGroundCompositionShader := True;
  Result.UseGroundCompositionMaterialIdAttribute := True;
  Result.GroundAtlasGridCols   := 8;
  Result.GroundAtlasGridRows   := 4;
  Result.GroundAtlasTilePixels := 1024;

  Result.GenerateFarTerrain        := False;
  Result.FarTerrainExpansionMeters := 8000;     { ±8 km → 16×16 km far area }
  Result.FarTerrainZoom            := 10;       { ~150 m/px }
  Result.FarTerrainGridStepM       := 80;

  Result.ShowFitPoints    := True;
  Result.ShowFitPointsSnapped := True;
  Result.BuildingShadows  := False;
  Result.GenerateGroundShadows := DEF_GROUND_SHADOWS;
  { Water + building defaults come from the canonical DEF_* constants,
    so these fields and the *Active mirror globals can never disagree. }
  Result.WaterShaders     := DEF_WATER_SHADERS;
  Result.WaterWaveSize    := DEF_WATER_WAVE_SIZE;
  Result.WaterLevelLift   := DEF_WATER_LEVEL_LIFT;
  Result.WaterSeaState    := DEF_WATER_SEA_STATE;
  Result.BuildingTextures := DEF_BUILDING_TEXTURES;
  Result.BuildingPBR      := DEF_BUILDING_PBR;
end;

initialization
  GlobalLODConfig := TLODConfig.Defaults;
  SyncLatticeGlobals;

end.
