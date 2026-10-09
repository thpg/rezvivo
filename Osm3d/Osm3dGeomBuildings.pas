unit Osm3dGeomBuildings;

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$codepage UTF8}
{ FPC false-positives on managed types / dynamic arrays the runtime
  already zero-fills; W5024 silences unused params on profile-fn
  signatures matching TOMBBProfileHeightFn. }
{$WARN 5036 OFF}
{$WARN 5057 OFF}
{$WARN 5091 OFF}
{$WARN 5092 OFF}
{$WARN 5093 OFF}

interface

uses
  Classes,
  SysUtils,
  StrUtils,
  Math,
  CastleVectors,
  CastleImages,
  Osm3dGeoMath,
  Osm3dGeomMesh, Osm3dFacadeLayout, Osm3dArchitecture, Osm3dCompoundRoof, Osm3dArchitectureVoids,
  Osm3dGeomUtils, Osm3dGroundOpenings,
  Osm3dOsmData, Osm3dBuildingParts,
  Osm3dOsmTagUtils,
  Osm3dHeightmap,
  Osm3dGeomTerrain,
  Osm3dStudioSettings,
  Osm3dSceneMaterials
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
,
  Osm3dWorkerPool;   { ParallelForPool — шардированный BuildAllParallel }

type
  { Footprint + height envelope of one building, used as input to the
    shadow builder. Owned by the caller; the array slot is freed when
    the caller releases the array. }
  TBuildingShadowCaster = record
    GroundOpenings: TBuildingGroundOpenings; { Ground-level passage/niche XZ rings;
      transient like Footprint. Shadows retain the uncut outer silhouette. }
    Footprint: array of TVector3;   { CCW-from-above (OSM3D),
                                      Y unused (Footprint[i].Y may be 0 or BaseY) }
    BaseY:     Single;              { ground attachment level (top of foundation) }
    GroundY:   Single;              { lowest terrain under the footprint — the
                                      level the cast shadow lies on (BaseY can be
                                      well above this: foundation lift + min_height
                                      + uphill corner) }
    MaxY:      Single;              { highest point of building geometry (roof apex) }
    KeepGroundUnder: Boolean;       { НЕ давить землю композита под футпринтом:
                                      здания с внутренним двором (землю двора
                                      видно сверху) и навесы building=roof
                                      (землю видно под крышей). Читается в
                                      BuildHoleNodeMask (Osm3dGeomBuilder). }
  end;
  TBuildingShadowCasters = array of TBuildingShadowCaster;

type

  // Skeleton vertex in XZ plane. T is wavefront time and is later used as roof height.
  TSkeletonVertex = record
    X, Z: Single;
    T:    Single;
  end;
  TSkeletonVertexArray = array of TSkeletonVertex;

  // One skeleton face corresponds to one original outline edge.
  TSkeletonFace = record
    OrigEdgeIndex: Integer;
    VertexIndices: array of Integer;
  end;
  TSkeletonFaceArray = array of TSkeletonFace;

  TStraightSkeleton = record
    Vertices:    TSkeletonVertexArray;
    Faces:       TSkeletonFaceArray;
    Valid:       Boolean;
    MaxTime:     Single;
  end;

// Returns Valid=False for non-CCW, non-convex, or numerically degenerate input.
function ComputeStraightSkeleton(const Outline: array of TVector2): TStraightSkeleton;

type
  { 12 roof types. Names map to OSM roof:shape values + render variants; ParseRoofShape returns the enum. }
  TRoofShape = (
    rsFlat,              { plain horizontal — default fallback }
    rsPyramidal,         { 1 apex над центроидом, для квадрата идеален }
    rsSkillion,          { односкатная — наклон по OMBB long axis }
    rsGabled,            { 2 ската с гребнем по OMBB long axis }
    rsHipped,            { Hipped через straight skeleton }
    rsHalfHipped,        { Hipped с короткими hip-частями }
    rsMansard,           { Hipped с плоской вершиной }
    rsGambrel,           { Gabled с переломом ската (2 угла на каждом скате) }
    rsSaltbox,           { Asymmetric gabled: один скат длиннее другого }
    rsOnion,             { Лук — луковичный купол на цилиндре }
    rsDome,              { Полусфера над центроидом }
    rsRound              { Полуцилиндр вдоль OMBB long axis }
  );

  { Точка skirt'а — XZ позиция + Y относительно EaveY (обычно
    отрицательная: skirt'у висит ниже карниза на skirtDrop). }
  TRoofSkirtPoint = record
    X, Z: Single;        { мировые координаты точки }
    Y:    Single;        { абсолютная высота нижнего края навеса }
  end;
  TRoofSkirtPointArray = array of TRoofSkirtPoint;

  { Skirt — навес. Один сегмент = quad между Edge[i] оригинального
    footprint'а и Edge[i] outer-кромки навеса. Skirt всегда замкнут
    (число точек = число вершин footprint'а). }
  TRoofSkirt = record
    HasSkirt:        Boolean;            { если False — skirt не нужен (flat etc.) }
    OuterEdge:       TRoofSkirtPointArray; { выпускной край навеса }
    InnerEdge:       TRoofSkirtPointArray; { = footprint, сохраняем для удобства WallsBuilder'а }
    DropMeters:      Single;             { насколько навес опущен ниже EaveY }
    OverhangMeters:  Single;             { ширина выступа от стены }
  end;

  { Roof vertex = TMeshVertex (same Position/Normal/UV — no conversion on emit). }
  TRoofVertex      = TMeshVertex;
  TRoofVertexArray = TMeshVertexArray;

  { Треугольник — 3 индекса в Vertices. Winding задаётся builder'ом
    так что normal = up. }
  TRoofTriangle = record
    A, B, C: Integer;
  end;
  TRoofTriangleArray = array of TRoofTriangle;

  { Roof-builder output. Caller adds vertices/triangles to its TMesh; if HasSkirt, it uses
    Skirt.OuterEdge to build the "walls under the overhang". }
  TRoofGeometry = record
    { Vertices/Triangles use a capacity/count split: the arrays may be
      longer than VertexCount/TriangleCount (capacity-doubling growth in
      AppendRoofVertex/AppendRoofTriangle). ALWAYS use the count fields,
      never Length()/High(), to iterate the live elements. }
    Vertices:      TRoofVertexArray;
    VertexCount:   Integer;
    Triangles:     TRoofTriangleArray;
    TriangleCount: Integer;
    Skirt:         TRoofSkirt;
    WallTop:       array of TVector3; { closed footprint walk at the roof surface }
    Valid:         Boolean;    { False если builder не справился (caller fallback на flat) }
  end;

  { Inner rings (courtyards) to cut OUT of a roof. X/Z live in the same world
    space as a footprint; Y is ignored (BuildFlat forces it to EaveY). }
  TRoofHoleRing  = TArchitectureVoidRing;
  TRoofHoleArray = TArchitectureVoidRings;

  { Параметры на вход builder'у. Все builder'ы принимают один и
    тот же тип, чтобы caller мог свободно dispatch'ить по shape. }
  TRoofParams = record
    Footprint:    array of TVector3;     { закрытое кольцо CCW, Y = EaveY везде }
    EaveY:        Single;                { высота карниза (= top стен) }
    RoofHeight:   Single;                { высота гребня над карнизом (RidgeY = EaveY + RoofHeight) }
    Tags:         TOSMTags;              { для парсинга roof:angle, roof:direction, etc. }
    { Inner rings to cut out (courtyards). ONLY BuildFlat honours them — a
      pitched roof over a hole is undefined, so Build forces rsFlat whenever
      this is non-empty. Empty ⇒ a solid roof exactly as before. }
    Holes:        TRoofHoleArray;

    { OMBB precomputed. OMBBLongDir — unit XZ vector ВДОЛЬ длинной
      оси (gabled: вдоль гребня; saltbox: вдоль "коричневого"). Для
      некоторых крыш не используется. Если не заданы (нулевые) —
      builder сам считает. }
    OMBBLongDir:  TVector2;
    OMBBShortDir: TVector2;
    OMBBLength:   Single;
    OMBBWidth:    Single;
    OMBBCenter:   TVector2;

    { Параметры skirt'а. Если SkirtOverhangM > 0 — builder создаёт
      skirt. Default 0 (без skirt'а). Реалистично 0.3-0.6 м. }
    SkirtOverhangM: Single;
    SkirtDropM:     Single;
  end;

{ Парсер тегов: roof:shape → TRoofShape. Дефолт (тег отсутствует) rsFlat.
  Расширен vs Osm3dGeomBuildings.ParseRoofShape — поддерживает все 12 типов.
  Для НЕИЗВЕСТНЫХ shape возвращает rsPyramidal (fallback: лучше показать
  что-то скатное, чем потерять информацию). }
function ParseRoofShape(const Tags: TOSMTags): TRoofShape;

{ Экспортировано для построителя табличек (Osm3dGeomPlates): чтобы высота
  таблички совпадала с фасадом, табличка повторяет ТОЧНО ту же логику числа
  этажей/формы крыши, что и Build. Тела — в implementation. }
function ParseLevels(const Tags: TOSMTags): Integer;
function EstimateLevelsFromArea(Area: Single): Integer;
{ "Area" to feed EstimateLevelsFromArea when there are no height/levels tags —
  NOT the real footprint area, but an area re-derived for NORMAL proportions
  from the OMBB minimum width. A long narrow building (warehouse, wall) has a
  large real area yet is almost always single-storey; capping its effective
  length at LEVELS_MAX_ASPECT × width removes that inflation. Compact footprints
  are unchanged; the result is always ≤ real area, so it can only ever LOWER the
  estimated storey count, never raise it. }
function EffectiveAreaForLevels(const Footprint: array of TVector3): Single;
function EstimateRoofShapeFromArea(Area: Single): TRoofShape;
function RoofShapeIsTagged(const Tags: TOSMTags): Boolean;

{ Default skirt параметры по shape. Возвращает 0,0 для flat/pyramidal
  (без skirt'а), 0.4м/0.2м для скатных. Caller может перебить значениями
  из тегов. }
procedure DefaultSkirtParams(Shape: TRoofShape; out OverhangM, DropM: Single);

{ Удобный constructor пустого RoofGeometry с Valid=False. }
function EmptyRoofGeometry: TRoofGeometry;

{ Утилита: добавить вершину в TRoofGeometry, вернуть индекс. }
function AppendRoofVertex(var Geom: TRoofGeometry;
  const Pos, Norm: TVector3; const UV: TVector2): Integer;

{ Утилита: добавить треугольник. }
procedure AppendRoofTriangle(var Geom: TRoofGeometry; A, B, C: Integer);

{ Создать начальный TRoofParams с разумными defaults. Footprint
  передаётся отдельно через прямое присваивание (он variable-length). }
function MakeRoofParams(EaveY, RoofHeight: Single; Tags: TOSMTags): TRoofParams;

type
  { OMBB basis for a footprint. LongDir — unit vector along the long axis.
    ShortDir — perpendicular (90° CCW). Center — rectangle centre.
    Length, Width — dimensions along the axes.
    Thin wrapper over TOMBBCorners. }
  TFootprintOMBB = record
    Center:      TVector2;
    LongDir:     TVector2;       { unit }
    ShortDir:    TVector2;       { unit, ⊥ LongDir }
    Length:      Single;         { along LongDir }
    Width:       Single;         { along ShortDir }
    Corners:     array[0..3] of TVector2;
                                 { 0 = (-L/2, -W/2), 1 = (+L/2, -W/2),
                                   2 = (+L/2, +W/2), 3 = (-L/2, +W/2)
                                   in local OMBB coords, converted to world. }
  end;

{ Main OMBB function: computes OMBB from a 2D footprint. Footprint —
  vertices of the outer ring in the XZ plane. }
function ComputeFootprintOMBB(const Footprint: array of TVector3): TFootprintOMBB;

{ Упрощённая версия: только основные поля заполняет (Center, LongDir,
  ShortDir, Length, Width) в TRoofParams.OMBB*. }
procedure FillOMBBInRoofParams(var Params: TRoofParams;
  const Footprint: array of TVector3);

{ Центроид (центр массы) полигона в XZ. Для пирамидальных и купольных
  крыш — точка apex. }
function PolygonCentroidXZ(const Footprint: array of TVector3): TVector2;

{ Преобразование точки (X,Z) в локальную OMBB-систему координат
  (U = вдоль LongDir, V = вдоль ShortDir). Origin = Center. }
function WorldToOMBBLocal(const P: TVector2; const O: TFootprintOMBB): TVector2;

{ Generate skirt: per footprint vertex, take the outward bisector, push out by OverhangM
  and down by DropM from EaveY. Called inside the roof builder BEFORE roof geometry, so the
  roof emits along the outer-skirt edge. }
procedure GenerateRoofSkirt(var Geom: TRoofGeometry;
  const Footprint: array of TVector3;
  EaveY, OverhangM, DropM: Single);

{ Sort 2D-polygon vertices by polar angle around the centroid -> CCW walk for convex
  skeleton faces (whose vertices may arrive unordered). N = active count; N<4 is a no-op.
  Bubble sort, N typically 4-8. }
procedure SortByPolarAngle(var Verts: array of TVector2; N: Integer);

{ Emit TRoofGeometry into a TMesh — each TRoofVertex added separately (face normal per
  triangle). FlipWinding inverts triangle winding (CW vs CCW) for the opposite culling convention. }
procedure ApplyRoofGeometryToMesh(const Geom: TRoofGeometry;
  Target: TMesh; FlipWinding: Boolean);

{ Signed perpendicular distance from point to line through (LineA, LineB).
  Sign: positive if point is to the LEFT of line direction A→B.
  This is the streets-gl primitive for hipped/mansard/gabled roof height. }
function SignedDstToLine(const Point, LineA, LineB: TVector2): Single;

type
  TRoofBuilder = class
  public

    class function BuildFlat(const P: TRoofParams): TRoofGeometry;
    class function BuildPyramidal(const P: TRoofParams): TRoofGeometry;
    class function BuildSkillion(const P: TRoofParams): TRoofGeometry;
    class function BuildGabled(const P: TRoofParams): TRoofGeometry;
    class function BuildHipped(const P: TRoofParams): TRoofGeometry;
    class function BuildMansard(const P: TRoofParams): TRoofGeometry;
    class function BuildGambrel(const P: TRoofParams): TRoofGeometry;
    class function BuildSaltbox(const P: TRoofParams): TRoofGeometry;
    class function BuildHalfHipped(const P: TRoofParams): TRoofGeometry;
    class function BuildRound(const P: TRoofParams): TRoofGeometry;
    class function BuildDome(const P: TRoofParams): TRoofGeometry;
    class function BuildOnion(const P: TRoofParams): TRoofGeometry;
  end;

const
  DEFAULT_BUILDING_HEIGHT_M  = 8.0;
  DEFAULT_CHIMNEY_HEIGHT_M   = 30.0;   { man_made=chimney без тега height }
  DEFAULT_CHIMNEY_RADIUS_M   = 2.0;    { половина типового ~4 м диаметра трубы }
  DEFAULT_TOWER_HEIGHT_M     = 25.0;   { man_made=tower без тега height }
  DEFAULT_LEVEL_HEIGHT_M     = 3.0;
  BUILDING_HEIGHT_JITTER     = 0.20;
  DEFAULT_ROOF_HEIGHT_M      = 3.0;
  BUILDING_PALETTE_SIZE      = 10; { 0..5 OSM material/colour; 6..9 hash tints }
  WALL_TILE_M                = 4.0;   { size of one texture "window" }

type
  { Records the triangle/vertex ranges occupied by one building inside
    a (Palette, Walls/Roofs) mesh slot of TBuildingMeshes. The tiled
    scene assembler uses these to keep all geometry of one building
    in the same tile, anchored at the footprint XZ centroid.

    Walls and Roofs ranges are stored separately because they live in
    different meshes (Walls[Palette] vs Roofs[Palette]); they still
    belong to the SAME building and must land in the SAME tile.

    Ranges are half-open: [TriStart, TriEnd) and [VertStart, VertEnd).
    Empty ranges (e.g. a building with no roof tris) have Start = End. }
  TBuildingTileAnchor = record
    Palette:        Integer;
    AnchorX:        Single;     { footprint XZ centroid — tile key source }
    AnchorZ:        Single;
    WallsTriStart:  Integer;
    WallsTriEnd:    Integer;
    WallsVertStart: Integer;
    WallsVertEnd:   Integer;
    RoofsTriStart:  Integer;
    RoofsTriEnd:    Integer;
    RoofsVertStart: Integer;
    RoofsVertEnd:   Integer;
    { True у труб туннелей (Osm3dGeomTunnels): диапазон стен собирается в
      отдельный шейп с ShadowCaster=False — подземная труба не должна
      отбрасывать тень на композит земли. У обычных зданий False. }
    NoShadowCast:   Boolean;
  end;
  TBuildingTileAnchorArray = array of TBuildingTileAnchor;

  { Each building receives a palette index [0..BUILDING_PALETTE_SIZE-1].
    The index maps to walls-mesh[i] / roofs-mesh[i] with its own material kind. }
  TBuildingMeshes = record
    Walls: array[0..BUILDING_PALETTE_SIZE-1] of TMesh;
    Roofs: array[0..BUILDING_PALETTE_SIZE-1] of TMesh;
    { Per-building ranges in the above meshes. Empty (nil) on the
      legacy code path — the scene assembler falls back to centroid-
      based per-triangle tiling when this array is nil. }
    TileAnchors: TBuildingTileAnchorArray;
  end;

  { Utility class — parsing and palette mapping only.
    Building construction is handled by TBuildingBuilderExt (Osm3dGeomBuildingsExt). }
  TBuildingBuilder = class
  public
    { Building height in metres from the height / est_height / building:levels tags.
      If no tags present — Default + deterministic jitter by WayId.
      Default = -1 lets the caller detect the absence of a tag (returns ≤ 0). }
    class function ParseHeight(const Tags: TOSMTags; WayId: Int64;
      const Default: Single = DEFAULT_BUILDING_HEIGHT_M): Single;

    { min_height → metres. 0 if the tag is absent. }
    class function ParseMinHeight(const Tags: TOSMTags): Single;

    { roof:height → metres. DEFAULT_ROOF_HEIGHT_M if the tag is absent. }
    class function ParseRoofHeight(const Tags: TOSMTags): Single;

    { Palette index [0..PALETTE_SIZE-1]. Legacy WayId hash; untagged
      facades go through SelectBuildingPalette (coords + levels). }
    class function PaletteIndex(const Tags: TOSMTags; WayId: Int64): Integer;
  end;

const
  { Aligned to streets-gl defaults. Both projects use 1 floor texture tile
    per level vertically + 1 window-width tile horizontally. }
  WALL_LEVEL_HEIGHT_M  = 4.0;     { ст-gl: levelHeight constant }
  DEFAULT_WINDOW_WIDTH_M  = 4.0;     { ст-gl: facade material window width }
  EDGE_SMOOTH_THRESHOLD_DEG = 30.0;  { angles below this are treated as smooth }

  { Facade texture (brick_window_*) layout: the window assembly occupies the
    middle V band (~0.19..0.81); below it is a tall plain-brick band ending
    at V≈0.19. The foundation/plinth strip samples [0 .. FOUNDATION_BRICK_V]
    so it shows several real brick rows instead of one stretched V=0 row,
    while never reaching the window. }
  FOUNDATION_BRICK_V = 0.18;

type
  TBooleanArray = array of Boolean;

  TWallParams = record
    Footprint:        array of TVector3;     { CCW footprint, Y = BaseY everywhere }
    BaseY:            Single;                { wall base (top of floor) }
    EaveY:            Single;                { eave = top of walls }
    { Foundation bottom — when < BaseY, walls are extended downward
      from BaseY to this Y as a plain "plinth" strip below the windowed
      part.  Used to cover the air gap on the downhill side of a
      building on sloped terrain.  Set equal to BaseY (or any value
      >= BaseY) to skip the foundation strip entirely. }
    FoundationBottomY: Single;
    Levels:           Integer;               { > 0 if building:levels tag is present }
    LevelHeightM:     Single;                { = WALL_LEVEL_HEIGHT_M; can be overridden }
    TargetWindowWM:   Single;                { = DEFAULT_WINDOW_WIDTH_M }
    { When True the facade is rendered windowless (garage/shed/silo/…
      per streets-gl isBuildingHasWindows). The wall UVs collapse to the
      texture's plain V=0 band — the same trick the foundation strip
      below already uses — so no window panes appear. Set by Build. }
    NoWindows:        Boolean;
    FacadeLayouts: TFacadeLayouts;
    Architecture: TArchFacades;
    Skirt:            TRoofSkirt;            { if HasSkirt — sub-walls are added beneath the overhang }
  end;

  TWallsBuilder = class
  public
    { Main entry point. Footprint must be CCW when viewed from above
      on a north-up map — i.e. the same orientation OSM uses for outer
      rings of a building polygon, and the orientation produced by
      Osm3dGeoMath.EnsureCCWXZ. In the engine's X-Z plane this means
      NEGATIVE shoelace area, because the projection uses -X = east
      (see Osm3dGeoMathProjection). The cross-product used below
      (Edge1 × Up) produces outward-pointing normals for that
      orientation. The caller (TBuildingBuilder) already calls
      EnsureCCWXZ before invoking BuildWalls. }
    class procedure BuildWalls(const P: TWallParams; Target: TMesh);

    { Utility: compute window count and actual window width for one
      edge. Window count = round(edgeLen / TargetWindowWM), min 1.
      Actual window width = edgeLen / count (resized slightly to fit
      a whole number of windows). }
    class procedure ComputeWindowGrid(EdgeLenM, TargetWidthM: Single;
      out WindowCount: Integer; out ActualWidthM: Single);

    { Analyses smoothness of each vertex (smooth vs sharp based on
      the angle between adjacent edges). Returns array of N booleans. }
    class function AnalyzeEdgeSmoothness(const Footprint: array of TVector3;
      ThresholdDeg: Single = EDGE_SMOOTH_THRESHOLD_DEG): TBooleanArray;
  end;

{ TBuildingShadowCaster, TBuildingShadowCasters }

const
  SAMPLE_LIMIT = 5;

type

  TBuildingExtStats = record
    Total:            Integer;
    PerShape:         array[TRoofShape] of Integer;
    SkeletonOK:       Integer;
    SkeletonFail:     Integer;
    SkirtsAdded:      Integer;
    LevelsTagged:     Integer;
    AreaEstimated:    Integer;
    Failures:         Integer;
  end;

  TBuildingBuilderExt = class
  public

    { Original entry point: builds wall + roof meshes only.
      No shadow caster output (ground-shadow generation is disabled). }
    class function BuildAll(Dataset: TOSMDataset; HM: THeightmap;
      Projection: TLocalProjection;
      LogProc: TLogProc = nil): TBuildingMeshes; overload;

    { Extended entry: also fills ShadowCasters (one per built building: CCW footprint, base/max Y).
      TerrainSampler, when non-nil, gives ground Y by barycentric interpolation on the actual terrain
      triangles (matching rendered Y); bilinear fallback can underestimate and sink foundations. }
    class function BuildAll(Dataset: TOSMDataset; HM: THeightmap;
      Projection: TLocalProjection;
      out ShadowCasters: TBuildingShadowCasters;
      TerrainSampler: TTerrainSampler = nil;
      LogProc: TLogProc = nil;
      AShard: Integer = 0;
      AShardCount: Integer = 1): TBuildingMeshes; overload;

    { Параллельная версия: категория buildings — крупнейший однопоточный
      кусок ген-фазы (по [gen-cat]: 7–20 с на блок при простаивающем пуле).
      Датасет шардируется детерминированно по Id (way/relation/node mod K),
      каждый шард строит СВОИ 20 мешей + якоря + кастеры полным BuildAll,
      затем шарды сливаются с оффсетами. Dataset/Sampler read-only (уже
      читаются шестью категориями параллельно), лог у шардов отключён —
      сводку пишет вызывающий по merged-результату. Порядок зданий внутри
      мешей меняется (шардовый), сами здания — побитно те же. }
    class function BuildAllParallel(Dataset: TOSMDataset; HM: THeightmap;
      Projection: TLocalProjection;
      out ShadowCasters: TBuildingShadowCasters;
      TerrainSampler: TTerrainSampler = nil;
      LogProc: TLogProc = nil;
      AShards: Integer = 4): TBuildingMeshes;

    class procedure Build(Way: TOSMWay; Dataset: TOSMDataset;
      HM: THeightmap; Projection: TLocalProjection;
      TerrainSampler: TTerrainSampler;
      out PaletteIdx: Integer;
      const AllMeshes: TBuildingMeshes;
      var Stat: TBuildingExtStats;
      LogProc: TLogProc;
      var SampledCount: Integer;
      var CasterOut: TBuildingShadowCaster;
      out HasCaster: Boolean;
      { Inner rings (courtyards) as CLOSED node-ref chains, from a
        multipolygon relation. Resolved into the same quantised XZ space as
        the outer footprint and cut out of a FLAT roof (forces rsFlat). nil
        for a plain building way. }
      const AInnerChains: TInt64ArrayArray;
      out ExtraCasters:TBuildingShadowCasters;
      { Диагностический per-roof лог. Если <> nil, Build дописывает одну
        строку на крышу: адрес дома, форма (задумано→итог), габариты
        эмитированной геометрии крыши против bbox футпринта и маркер
        !!OUTLIER, когда вершина крыши выпадает за пределы. nil — лог не
        ведётся (нулевая стоимость). }
      ADbg: TStrings = nil);
  end;

{ Человекочитаемый адрес дома из тегов: addr:housenumber + addr:street,
  иначе name, иначе building=<type>; всегда с osm id. Для привязки
  «улетевшей» крыши к конкретному дому в диагностическом логе. }
function BuildingAddressStr(const Tags: TOSMTags; Id: Int64): string;

var
  { Глобальный тумблер per-roof диагностического лога. True → BuildAll
    пишет roof_debug_<tick>_<seq>.log в DefaultCacheRoot (как fit_snap).
    Диагностика «улетающих» крыш завершена (коллинеарные кольца
    почищены, ориентация валидируется) — лог выключен. Для повторной
    отладки поставить обратно True. }
  RoofDebugLogEnabled: Boolean = False;

function RoofShapeName(Shape: TRoofShape): string;

implementation

uses Osm3dGenerationProgress, fpjson, jsonparser, Osm3dBuildingMassing;

function SameClosedPhotoRing(const A,B:array of Int64):Boolean;
var I,J:Integer;Found:Boolean;
begin
  Result:=False;if (Length(A)<4) or (Length(A)<>Length(B)) then Exit;
  for I:=0 to High(A)-1 do begin
    Found:=False;for J:=0 to High(B)-1 do if A[I]=B[J] then begin Found:=True;Break end;
    if not Found then Exit;
  end;
  Result:=True;
end;

var
  { Уникализатор имени roof_debug_*.log при параллельной сборке блоков.
    Инкрементится атомарно на каждый BuildAll, пишущий лог. }
  RoofDbgSeq: Integer = 0;

const
  { Minimum sin(altitude) to bother projecting shadows. Below this the
    sun is too close to the horizon — shadows are very long, of
    questionable physical meaning, and clipping cost balloons. }
  MIN_SUN_DOWN_Y      = 0.10;   { ≈ alt > 5.7°  (SunDirection.Y < -MIN_SUN_DOWN_Y) }
  MIN_BUILDING_HEIGHT = 0.5;    { below this we don't generate shadows }

  { Y lift of the shadow above the ground triangle it's clipped against. Must beat depth-buffer
    precision (24-bit, near 0.1, far 100 km -> ~15 mm at 500 m); 2 cm is safe to ~700 m and below
    perceptible parallax. }
  SHADOW_Y_LIFT = 0.02;
  EPS_2D        = 1.0e-6;

{ Signed shoelace area of a polygon in (X, Z). Positive = CCW in
  standard math convention (X right, Z up in plan). }

{ Reverse polygon vertices in-place if its shoelace area is negative,
  so on exit it is always in standard CCW (positive area) orientation. }

function PolygonSignedArea2D(const Outline: array of TVector2): Single; forward;
function PolygonIsConvexCCW(const Outline: array of TVector2): Boolean; forward;
function PolygonIsCCW(const Outline: array of TVector2): Boolean; forward;

const
  // These epsilons are deliberately separated: angle tests, event timing and
  // degenerate geometry fail in different numeric ranges.
  EPS_PARALLEL = 1e-7;
  EPS_TIME     = 1e-6;
  EPS_DEGEN    = 1e-9;
  MAX_ITERATIONS = 10000;

type

  // Moving wavefront vertex. X/Z are stored at BirthTime; actual position at
  // another time is reconstructed from bisector direction and speed.
  TActiveVertex = record
    X, Z:           Single;
    BisX, BisZ:     Single;
    Speed:          Single;
    BirthTime:      Single;
    PrevIdx, NextIdx: Integer;
    Active:         Boolean;
    SkelIdx:        Integer;
    OrigEdgePrev:   Integer;
    OrigEdgeNext:   Integer;
  end;
  TActiveVertexArray = array of TActiveVertex;

  // Edge event: two adjacent active vertices meet and collapse their edge.
  TEdgeEvent = record
    Time:   Single;
    AIdx:   Integer;
    BIdx:   Integer;
    OrigEdgeIdx: Integer;
    Stale:  Boolean;
  end;
  TEdgeEventArray = array of TEdgeEvent;

  // Min-heap of candidate events. Stale events are removed lazily because
  // topology changes invalidate neighboring events often.
  TEventPQ = class
  private
    FEvents: TEdgeEventArray;
    FCount:  Integer;
    procedure SiftUp(I: Integer);
    procedure SiftDown(I: Integer);
  public
    constructor Create;
    procedure Push(const E: TEdgeEvent);
    function  PopMin(out E: TEdgeEvent): Boolean;
    procedure MarkStaleByVertex(VIdx: Integer);
  end;

function PolygonSignedArea2D(const Outline: array of TVector2): Single;
var
  I, J, N: Integer;
  S: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(182);{$ENDIF}
  N := Length(Outline);
  S := 0;
  for I := 0 to N - 1 do
  begin
    J := (I + 1) mod N;
    S := S + (Outline[I].X * Outline[J].Y - Outline[J].X * Outline[I].Y);
  end;
  Result := Single(S * 0.5);
end;

function PolygonIsCCW(const Outline: array of TVector2): Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(184);{$ENDIF}
  Result := PolygonSignedArea2D(Outline) > 0;
end;

function EmptyStraightSkeleton: TStraightSkeleton;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(190);{$ENDIF}
  Result.Valid := False;
  Result.MaxTime := 0;
  SetLength(Result.Vertices, 0);
  SetLength(Result.Faces, 0);
end;

function PolygonIsConvexCCW(const Outline: array of TVector2): Boolean;
var
  N, I: Integer;
  Px, Py, Cx, Cy, Nx, Ny: Single;
  E1x, E1y, E2x, E2y, Cross: Single;
  Negative: Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(183);{$ENDIF}
  Result := False;
  N := Length(Outline);
  if N < 3 then Exit;
  if not PolygonIsCCW(Outline) then Exit;

  Negative := False;
  for I := 0 to N - 1 do
  begin
    Px := Outline[(I + N - 1) mod N].X;
    Py := Outline[(I + N - 1) mod N].Y;
    Cx := Outline[I].X;
    Cy := Outline[I].Y;
    Nx := Outline[(I + 1) mod N].X;
    Ny := Outline[(I + 1) mod N].Y;

    E1x := Cx - Px;  E1y := Cy - Py;
    E2x := Nx - Cx;  E2y := Ny - Cy;
    Cross := E1x * E2y - E1y * E2x;

    // For a CCW convex polygon all turns must be non-negative.
    if Cross < -EPS_PARALLEL then Exit;
    if Cross > EPS_PARALLEL then Negative := True;
  end;
  Result := Negative;
end;

constructor TEventPQ.Create;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1064);{$ENDIF}
  inherited;
  SetLength(FEvents, 65);
  FCount := 0;
end;

procedure TEventPQ.SiftUp(I: Integer);
var
  P: Integer;
  Tmp: TEdgeEvent;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(191);{$ENDIF}
  while I > 1 do
  begin
    P := I shr 1;
    if FEvents[P].Time <= FEvents[I].Time then Break;
    Tmp := FEvents[P];  FEvents[P] := FEvents[I];  FEvents[I] := Tmp;
    I := P;
  end;
end;

procedure TEventPQ.SiftDown(I: Integer);
var
  C: Integer;
  Tmp: TEdgeEvent;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(192);{$ENDIF}
  while True do
  begin
    C := I shl 1;
    if C > FCount then Break;
    if (C + 1 <= FCount) and (FEvents[C + 1].Time < FEvents[C].Time) then
      Inc(C);
    if FEvents[I].Time <= FEvents[C].Time then Break;
    Tmp := FEvents[I];  FEvents[I] := FEvents[C];  FEvents[C] := Tmp;
    I := C;
  end;
end;

procedure TEventPQ.Push(const E: TEdgeEvent);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(193);{$ENDIF}
  Inc(FCount);
  if FCount >= Length(FEvents) then
    SetLength(FEvents, Length(FEvents) * 2);
  FEvents[FCount] := E;
  SiftUp(FCount);
end;

function TEventPQ.PopMin(out E: TEdgeEvent): Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(194);{$ENDIF}
  Result := False;
  while FCount > 0 do
  begin
    E := FEvents[1];

    FEvents[1] := FEvents[FCount];
    Dec(FCount);
    if FCount > 0 then SiftDown(1);

    // Lazy deletion: event times remain heap-ordered even when event payloads
    // become invalid after a collapse.
    if not E.Stale then
    begin
      Result := True;
      Exit;
    end;
  end;
end;

procedure TEventPQ.MarkStaleByVertex(VIdx: Integer);
var I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(195);{$ENDIF}
  for I := 1 to FCount do
    if not FEvents[I].Stale then
      if (FEvents[I].AIdx = VIdx) or (FEvents[I].BIdx = VIdx) then
        FEvents[I].Stale := True;
end;

procedure NormalizeXZ(var X, Z: Single);
var L: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(196);{$ENDIF}
  L := Sqrt(X * X + Z * Z);
  if L > EPS_DEGEN then
  begin
    X := X / L;
    Z := Z / L;
  end
  else
  begin
    X := 0; Z := 0;
  end;
end;

// Computes inward angle bisector and wavefront speed for one convex vertex.
// Speed < 0 is used as an explicit marker for a reflex vertex.
procedure ComputeBisector(
  const PrevX, PrevZ, CurX, CurZ, NextX, NextZ: Single;
  out BisX, BisZ, Speed: Single);
var
  IncX, IncZ, OutX, OutZ: Single;
  PerpInX, PerpInZ, PerpOutX, PerpOutZ: Single;
  Cross, SinHalf: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(197);{$ENDIF}
  IncX := CurX - PrevX;  IncZ := CurZ - PrevZ;
  OutX := NextX - CurX;  OutZ := NextZ - CurZ;
  NormalizeXZ(IncX, IncZ);
  NormalizeXZ(OutX, OutZ);

  // For CCW outline, clockwise edge normals point outside; negating their
  // sum gives the inward bisector.
  PerpInX :=  IncZ;  PerpInZ  := -IncX;
  PerpOutX := OutZ;  PerpOutZ := -OutX;

  BisX := -(PerpInX + PerpOutX);
  BisZ := -(PerpInZ + PerpOutZ);
  if Sqrt(BisX * BisX + BisZ * BisZ) < EPS_PARALLEL then
  begin
    BisX := 0;
    BisZ := 0;
    Speed := 0;
    Exit;
  end;
  NormalizeXZ(BisX, BisZ);

  Cross := IncX * OutZ - IncZ * OutX;
  // Straight skeleton wavefront speed is 1 / sin(half angle).
  SinHalf := Sqrt((1 - (IncX * OutX + IncZ * OutZ)) / 2);
  if SinHalf < 1e-4 then
    Speed := 1e6
  else
    Speed := 1.0 / SinHalf;

  if Cross < -EPS_PARALLEL then
  begin
    BisX := 0;
    BisZ := 0;
    Speed := -1;
  end;
end;

// Position is evaluated lazily so old events can be checked against new time.
procedure ActivePositionAtTime(const V: TActiveVertex; const AtTime: Single;
  out X, Z: Single);
var
  DT: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(198);{$ENDIF}
  DT := AtTime - V.BirthTime;
  X := V.X + V.BisX * V.Speed * DT;
  Z := V.Z + V.BisZ * V.Speed * DT;
end;

procedure MidpointOfActiveVerticesAtTime(const A, B: TActiveVertex;
  const AtTime: Single; out X, Z: Single);
var
  AX, AZ, BX, BZ: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(199);{$ENDIF}
  ActivePositionAtTime(A, AtTime, AX, AZ);
  ActivePositionAtTime(B, AtTime, BX, BZ);
  X := (AX + BX) * 0.5;
  Z := (AZ + BZ) * 0.5;
end;

procedure ComputeInsertedBisectorAtTime(const Active: TActiveVertexArray;
  PrevIdx, NextIdx: Integer; const CurX, CurZ, AtTime: Single;
  out BisX, BisZ, Speed: Single);
var
  PrevX, PrevZ, NextX, NextZ: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(200);{$ENDIF}
  ActivePositionAtTime(Active[PrevIdx], AtTime, PrevX, PrevZ);
  ActivePositionAtTime(Active[NextIdx], AtTime, NextX, NextZ);
  ComputeBisector(PrevX, PrevZ, CurX, CurZ, NextX, NextZ, BisX, BisZ, Speed);
end;

// Returns event time for a still-existing active edge, or -1 if the endpoints
// are not converging to the same point.
function ComputeEdgeEventTime(const A, B: TActiveVertex; const NowTime: Single): Single;
var
  AX, AZ, BX, BZ: Single;
  VAx, VAz, VBx, VBz: Single;
  DX, DZ, DVx, DVz: Single;
  ApproachRate, LenDV2, DistSqAt0, DistSqAtMin, T_min: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(201);{$ENDIF}
  Result := -1;

  ActivePositionAtTime(A, NowTime, AX, AZ);
  ActivePositionAtTime(B, NowTime, BX, BZ);

  DX := BX - AX;
  DZ := BZ - AZ;
  DistSqAt0 := DX * DX + DZ * DZ;
  if DistSqAt0 < EPS_DEGEN * EPS_DEGEN then
  begin
    Result := NowTime;
    Exit;
  end;

  VAx := A.BisX * A.Speed;
  VAz := A.BisZ * A.Speed;
  VBx := B.BisX * B.Speed;
  VBz := B.BisZ * B.Speed;

  DVx := VAx - VBx;
  DVz := VAz - VBz;
  LenDV2 := DVx * DVx + DVz * DVz;
  if LenDV2 < EPS_PARALLEL * EPS_PARALLEL then Exit;

  ApproachRate := DX * DVx + DZ * DVz;
  if ApproachRate <= 0 then Exit;

  T_min := ApproachRate / LenDV2;

  DistSqAtMin := DistSqAt0 - ApproachRate * ApproachRate / LenDV2;
  // Accept a collapse only when the closest approach is close enough to a true
  // meeting point. This tolerates slightly imperfect building corners.
  if DistSqAtMin > 0.01 * DistSqAt0 then Exit;

  Result := NowTime + T_min;
end;

procedure InitEdgeEvent(out Ev: TEdgeEvent; const ATime: Single;
  AIdx, BIdx, OrigEdgeIdx: Integer);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(202);{$ENDIF}
  Ev.Time := ATime;
  Ev.AIdx := AIdx;
  Ev.BIdx := BIdx;
  Ev.OrigEdgeIdx := OrigEdgeIdx;
  Ev.Stale := False;
end;

// Centralizes event creation so all callers apply the same future-time guard.
procedure PushEdgeEventIfFuture(PQ: TEventPQ; const Active: TActiveVertexArray;
  AIdx, BIdx, OrigEdgeIdx: Integer; const NowTime, MinDelta: Single);
var
  Ev: TEdgeEvent;
  EvTime: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(203);{$ENDIF}
  EvTime := ComputeEdgeEventTime(Active[AIdx], Active[BIdx], NowTime);
  if EvTime > NowTime + MinDelta then
  begin
    InitEdgeEvent(Ev, EvTime, AIdx, BIdx, OrigEdgeIdx);
    PQ.Push(Ev);
  end;
end;

function SameSkeletonVertex(const A, B: TSkeletonVertex; const Tolerance: Single): Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(204);{$ENDIF}
  Result := (Abs(A.X - B.X) < Tolerance) and
            (Abs(A.Z - B.Z) < Tolerance) and
            (Abs(A.T - B.T) < Tolerance);
end;

type
  TIntArray = array of Integer;
  TIntArrayArray = array of TIntArray;

// Collapses near-identical skeleton vertices created by simultaneous events and
// remaps temporary face indices to the compact vertex array.
procedure DedupVerticesAndBuildFaces(var Skel: TStraightSkeleton;
  const Faces: TIntArrayArray; N: Integer);
var
  Remap: array of Integer;
  NewVerts: TSkeletonVertexArray;
  I2, J2, NV: Integer;
  DupFound: Boolean;
  NewVertsCount, NewVertsCap: Integer;
  FaceCount, MappedIdx: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(205);{$ENDIF}
  NV := Length(Skel.Vertices);
  SetLength(Remap, NV);
  { Pre-alloc NewVerts upper-bound = NV; track real count, compact at the end (avoids O(N²)). }
  SetLength(NewVerts, NV);
  NewVertsCount := 0;
  NewVertsCap   := NV;
  for I2 := 0 to NV - 1 do
  begin
    DupFound := False;
    for J2 := 0 to NewVertsCount - 1 do
      if SameSkeletonVertex(NewVerts[J2], Skel.Vertices[I2], 0.01) then
      begin
        Remap[I2] := J2;
        DupFound := True;
        Break;
      end;
    if not DupFound then
    begin
      if NewVertsCount >= NewVertsCap then     { defensive — should not trigger }
      begin
        NewVertsCap := NewVertsCap * 2;
        SetLength(NewVerts, NewVertsCap);
      end;
      NewVerts[NewVertsCount] := Skel.Vertices[I2];
      Remap[I2] := NewVertsCount;
      Inc(NewVertsCount);
    end;
  end;
  SetLength(NewVerts, NewVertsCount);
  Skel.Vertices := NewVerts;

  SetLength(Skel.Faces, N);
  for I2 := 0 to N - 1 do
  begin
    Skel.Faces[I2].OrigEdgeIndex := I2;
    { Pre-alloc to upper bound; track FaceCount, compact at the end. }
    SetLength(Skel.Faces[I2].VertexIndices, Length(Faces[I2]));
    FaceCount := 0;
    for J2 := 0 to High(Faces[I2]) do
    begin
      MappedIdx := Remap[Faces[I2][J2]];
      { Skip consecutive duplicates. }
      if (FaceCount > 0) and
         (Skel.Faces[I2].VertexIndices[FaceCount - 1] = MappedIdx) then
        Continue;
      Skel.Faces[I2].VertexIndices[FaceCount] := MappedIdx;
      Inc(FaceCount);
    end;
    SetLength(Skel.Faces[I2].VertexIndices, FaceCount);
  end;
end;

function ComputeStraightSkeleton(const Outline: array of TVector2): TStraightSkeleton;
var
  N, I, Iter: Integer;
  Active: TActiveVertexArray;
  PQ: TEventPQ;
  Skel: TStraightSkeleton;
  Faces: TIntArrayArray;
  Ev: TEdgeEvent;
  ANow: TActiveVertex;
  AIdx, BIdx, NewSkelIdx: Integer;
  PrevIdx, NextIdx: Integer;
  NewX, NewZ: Single;
  T, MaxT: Single;
  ActiveCount: Integer;
  { Capacity/count split for the two arrays grown during the build.
    SkelVCount tracks Skel.Vertices; FaceCount[i] tracks Faces[i].
    Both arrays are capacity-doubled and trimmed back to the real
    count before DedupVerticesAndBuildFaces (which reads Length()). }
  SkelVCount: Integer;
  FaceCount:  array of Integer;

  procedure PushVertexToFace(FaceIdx, SkelVIdx: Integer);
  var L: Integer;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(207);{$ENDIF}
    L := FaceCount[FaceIdx];
    if L >= Length(Faces[FaceIdx]) then
      SetLength(Faces[FaceIdx], L * 2 + 4);
    Faces[FaceIdx][L] := SkelVIdx;
    Inc(FaceCount[FaceIdx]);
  end;

  function AddSkeletonVertex(X, Z, ATime: Single): Integer;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(208);{$ENDIF}
    Result := SkelVCount;
    if Result >= Length(Skel.Vertices) then
      SetLength(Skel.Vertices, Result * 2 + 16);
    Skel.Vertices[Result].X := X;
    Skel.Vertices[Result].Z := Z;
    Skel.Vertices[Result].T := ATime;
    Inc(SkelVCount);
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(206);{$ENDIF}
  Skel := EmptyStraightSkeleton;
  SkelVCount := 0;

  N := Length(Outline);
  if N < 3 then begin Result := Skel; Exit; end;

  if not PolygonIsCCW(Outline) then begin Result := Skel; Exit; end;

  // This implementation intentionally supports convex outlines only.
  if not PolygonIsConvexCCW(Outline) then begin Result := Skel; Exit; end;

  // Initial wavefront: every outline vertex becomes one active vertex.
  SetLength(Active, N);
  for I := 0 to N - 1 do
  begin
    Active[I].X := Outline[I].X;
    Active[I].Z := Outline[I].Y;
    Active[I].PrevIdx := (I + N - 1) mod N;
    Active[I].NextIdx := (I + 1) mod N;
    Active[I].Active := True;
    Active[I].BirthTime := 0;
    Active[I].OrigEdgePrev := (I + N - 1) mod N;
    Active[I].OrigEdgeNext := I;
  end;

  for I := 0 to N - 1 do
  begin
    ComputeBisector(
      Outline[(I + N - 1) mod N].X, Outline[(I + N - 1) mod N].Y,
      Outline[I].X, Outline[I].Y,
      Outline[(I + 1) mod N].X, Outline[(I + 1) mod N].Y,
      Active[I].BisX, Active[I].BisZ, Active[I].Speed);
    if Active[I].Speed < 0 then
    begin
      Result := Skel;
      Exit;
    end;
  end;

  for I := 0 to N - 1 do
    Active[I].SkelIdx := AddSkeletonVertex(Active[I].X, Active[I].Z, 0);

  // Temporary faces start from original edges and receive skeleton vertices as
  // their corresponding wavefront edges collapse.
  SetLength(Faces, N);
  SetLength(FaceCount, N);
  for I := 0 to N - 1 do
  begin
    SetLength(Faces[I], 2);
    Faces[I][0] := Active[I].SkelIdx;
    Faces[I][1] := Active[(I + 1) mod N].SkelIdx;
    FaceCount[I] := 2;   { faces start with their two edge endpoints }
  end;

  PQ := TEventPQ.Create;
  try
    for I := 0 to N - 1 do
      PushEdgeEventIfFuture(PQ, Active, I, (I + 1) mod N, I, 0, 0);

    ActiveCount := N;
    Iter := 0;
    MaxT := 0;

    // Process collapses in chronological order until the wavefront disappears
    // or no reliable future event remains.
    while ActiveCount > 1 do
    begin
      Inc(Iter);
      if Iter > MAX_ITERATIONS then Exit;

      if not PQ.PopMin(Ev) then
      begin
        Break;
      end;

      AIdx := Ev.AIdx;
      BIdx := Ev.BIdx;
      if (not Active[AIdx].Active) or (not Active[BIdx].Active) then Continue;

      // Event is stale if topology changed and A/B are no longer adjacent.
      if Active[AIdx].NextIdx <> BIdx then Continue;

      T := Ev.Time;
      if T > MaxT then MaxT := T;

      MidpointOfActiveVerticesAtTime(Active[AIdx], Active[BIdx], T, NewX, NewZ);

      NewSkelIdx := AddSkeletonVertex(NewX, NewZ, T);

      // The new skeleton point closes the collapsed edge face and touches both
      // neighboring original-edge faces.
      PushVertexToFace(Ev.OrigEdgeIdx, NewSkelIdx);
      PushVertexToFace(Active[AIdx].OrigEdgePrev, NewSkelIdx);
      PushVertexToFace(Active[BIdx].OrigEdgeNext, NewSkelIdx);

      // Replace the collapsed A/B pair with one newly born active vertex.
      PrevIdx := Active[AIdx].PrevIdx;
      NextIdx := Active[BIdx].NextIdx;
      ANow := Active[AIdx];
      ANow.X := NewX;  ANow.Z := NewZ;
      ANow.PrevIdx := PrevIdx;
      ANow.NextIdx := NextIdx;
      ANow.BirthTime := T;
      ANow.SkelIdx := NewSkelIdx;
      ANow.OrigEdgePrev := Active[AIdx].OrigEdgePrev;
      ANow.OrigEdgeNext := Active[BIdx].OrigEdgeNext;
      ANow.Active := True;

      ComputeInsertedBisectorAtTime(Active, PrevIdx, NextIdx, NewX, NewZ, T,
        ANow.BisX, ANow.BisZ, ANow.Speed);

      if ANow.Speed < 0 then
      begin
        SetLength(Skel.Vertices, SkelVCount);   { keep length == count }
        Result := Skel;
        Exit;
      end;

      Active[AIdx] := ANow;
      Active[BIdx].Active := False;
      PQ.MarkStaleByVertex(BIdx);

      Active[PrevIdx].NextIdx := AIdx;
      Active[NextIdx].PrevIdx := AIdx;

      Dec(ActiveCount);

      // Only the two edges adjacent to the inserted vertex need new candidate events.
      PushEdgeEventIfFuture(PQ, Active, PrevIdx, AIdx, Active[PrevIdx].OrigEdgeNext, T, EPS_TIME);
      PushEdgeEventIfFuture(PQ, Active, AIdx, NextIdx, Active[AIdx].OrigEdgeNext, T, EPS_TIME);
    end;
  finally
    PQ.Free;
  end;

  Skel.MaxTime := MaxT;

  { Trim the capacity-doubled arrays to their real counts —
    DedupVerticesAndBuildFaces reads Length(Skel.Vertices) and
    Length(Faces[i]) as the live element counts. }
  SetLength(Skel.Vertices, SkelVCount);
  for I := 0 to N - 1 do
    SetLength(Faces[I], FaceCount[I]);

  DedupVerticesAndBuildFaces(Skel, Faces, N);

  Skel.Valid := True;
  Result := Skel;
end;

function ParseRoofShape(const Tags: TOSMTags): TRoofShape;
var V: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(209);{$ENDIF}
  V := Tags.GetLower('roof:shape');
  if V = '' then Exit(rsFlat);
  if (V = 'flat') or (V = 'flat_roof') then Exit(rsFlat);
  if V = 'pyramidal' then Exit(rsPyramidal);
  if (V = 'skillion') or (V = 'lean_to') or (V = 'mono_pitch') then Exit(rsSkillion);
  if V = 'gabled' then Exit(rsGabled);
  if V = 'hipped' then Exit(rsHipped);
  if (V = 'half-hipped') or (V = 'half_hipped') then Exit(rsHalfHipped);
  if V = 'mansard' then Exit(rsMansard);
  if V = 'gambrel' then Exit(rsGambrel);
  if V = 'saltbox' then Exit(rsSaltbox);
  if V = 'onion' then Exit(rsOnion);
  if V = 'dome' then Exit(rsDome);
  if V = 'round' then Exit(rsRound);
  { Неизвестная форма → fallback на pyramidal (как было в старом ParseRoofShape):
    лучше показать что-то скатное чем потерять информацию. }
  Result := rsPyramidal;
end;

procedure DefaultSkirtParams(Shape: TRoofShape; out OverhangM, DropM: Single);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(211);{$ENDIF}
  case Shape of
    rsFlat, rsPyramidal:
      begin OverhangM := 0; DropM := 0; end;
    rsDome, rsOnion:
      begin OverhangM := 0; DropM := 0; end;     { купола без свеса }
    rsSkillion, rsGabled, rsHipped, rsHalfHipped, rsSaltbox:
      begin OverhangM := 0.40; DropM := 0.20; end;
    rsMansard, rsGambrel:
      begin OverhangM := 0.30; DropM := 0.15; end;
    rsRound:
      begin OverhangM := 0.30; DropM := 0.10; end;
  else
    OverhangM := 0; DropM := 0;
  end;
end;

function EmptyRoofGeometry: TRoofGeometry;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(212);{$ENDIF}
  SetLength(Result.Vertices, 0);
  SetLength(Result.Triangles, 0);
  SetLength(Result.WallTop, 0);
  Result.VertexCount   := 0;
  Result.TriangleCount := 0;
  Result.Valid := False;
  Result.Skirt.HasSkirt := False;
  SetLength(Result.Skirt.OuterEdge, 0);
  SetLength(Result.Skirt.InnerEdge, 0);
  Result.Skirt.DropMeters := 0;
  Result.Skirt.OverhangMeters := 0;
end;

function AppendRoofVertex(var Geom: TRoofGeometry;
  const Pos, Norm: TVector3; const UV: TVector2): Integer;
var V: TRoofVertex;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(213);{$ENDIF}
  Result := Geom.VertexCount;
  { Capacity-doubling — was SetLength(Geom.Vertices, Result+1) per call,
    an O(n^2) reallocation chain over a roof's vertices. }
  if Result >= Length(Geom.Vertices) then
    SetLength(Geom.Vertices, Result * 2 + 16);
  V := Default(TRoofVertex); { source identity is stamped by the owning mesh }
  V.Position := Pos;
  V.Normal   := Norm;
  V.UV       := UV;
  Geom.Vertices[Result] := V;
  Inc(Geom.VertexCount);
end;

procedure AppendRoofTriangle(var Geom: TRoofGeometry; A, B, C: Integer);
var I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(214);{$ENDIF}
  I := Geom.TriangleCount;
  if I >= Length(Geom.Triangles) then
    SetLength(Geom.Triangles, I * 2 + 16);
  Geom.Triangles[I].A := A;
  Geom.Triangles[I].B := B;
  Geom.Triangles[I].C := C;
  Inc(Geom.TriangleCount);
end;

function MakeRoofParams(EaveY, RoofHeight: Single; Tags: TOSMTags): TRoofParams;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(215);{$ENDIF}
  Result.EaveY := EaveY;
  Result.RoofHeight := RoofHeight;
  Result.Tags := Tags;
  Result.OMBBLongDir := Vector2(1, 0);
  Result.OMBBShortDir := Vector2(0, 1);
  Result.OMBBLength := 0;
  Result.OMBBWidth := 0;
  Result.OMBBCenter := Vector2(0, 0);
  Result.SkirtOverhangM := 0;
  Result.SkirtDropM := 0;
  SetLength(Result.Footprint, 0);
end;

function Vec2Length(const V: TVector2): Single; inline;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(217);{$ENDIF}
  Result := Sqrt(V.X * V.X + V.Y * V.Y);
end;

function Vec2Normalize(const V: TVector2): TVector2; inline;
var L: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(218);{$ENDIF}
  L := Vec2Length(V);
  if L > 1e-9 then begin Result.X := V.X / L; Result.Y := V.Y / L end
  else begin Result.X := 0; Result.Y := 0 end;
end;

function Vec2Dot(const A, B: TVector2): Single; inline;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(219);{$ENDIF}
  Result := A.X * B.X + A.Y * B.Y;
end;

function SignedDstToLine(const Point, LineA, LineB: TVector2): Single;
var
  LineX, LineY: Single;
  PointX, PointY: Single;
  Cross, LineLen: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(220);{$ENDIF}
  LineX := LineB.X - LineA.X;
  LineY := LineB.Y - LineA.Y;
  PointX := Point.X - LineA.X;
  PointY := Point.Y - LineA.Y;
  Cross := LineX * PointY - LineY * PointX;
  LineLen := Sqrt(LineX * LineX + LineY * LineY);
  if LineLen < 1e-9 then
    Result := 0
  else
    Result := Cross / LineLen;
end;

function ComputeFootprintOMBB(const Footprint: array of TVector3): TFootprintOMBB;
var
  Pts:    TOMBBPointArray;
  I:      Integer;
  Corn:   TOMBBCorners;
  Ed01, Ed12: TVector2;
  Len01, Len12: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(221);{$ENDIF}
  { Default fallback на случай degenerate'а. }
  Result.Center := Vector2(0, 0);
  Result.LongDir := Vector2(1, 0);
  Result.ShortDir := Vector2(0, 1);
  Result.Length := 0;
  Result.Width := 0;
  for I := 0 to 3 do Result.Corners[I] := Vector2(0, 0);

  if Length(Footprint) < 3 then Exit;

  SetLength(Pts, Length(Footprint));
  for I := 0 to High(Footprint) do
  begin
    Pts[I].X := Footprint[I].X;
    Pts[I].Z := Footprint[I].Z;
  end;

  Corn := TOMBB.Compute(Pts);

  for I := 0 to 3 do
  begin
    Result.Corners[I].X := Corn[I].X;
    Result.Corners[I].Y := Corn[I].Z;
  end;

  { Вычислить axes из 4 углов. По convention TOMBB.Compute:
      Corn[0] → Corn[1]: одна сторона
      Corn[1] → Corn[2]: соседняя сторона
    Длинная — большая по длине. }
  Ed01.X := Corn[1].X - Corn[0].X;
  Ed01.Y := Corn[1].Z - Corn[0].Z;
  Ed12.X := Corn[2].X - Corn[1].X;
  Ed12.Y := Corn[2].Z - Corn[1].Z;
  Len01 := Vec2Length(Ed01);
  Len12 := Vec2Length(Ed12);

  if Len01 >= Len12 then
  begin
    Result.LongDir := Vec2Normalize(Ed01);
    Result.ShortDir := Vec2Normalize(Ed12);
    Result.Length := Len01;
    Result.Width := Len12;
  end
  else
  begin
    Result.LongDir := Vec2Normalize(Ed12);
    Result.ShortDir := Vec2Normalize(Ed01);
    Result.Length := Len12;
    Result.Width := Len01;
  end;

  Result.Center.X := (Corn[0].X + Corn[2].X) * 0.5;
  Result.Center.Y := (Corn[0].Z + Corn[2].Z) * 0.5;
end;

procedure FillOMBBInRoofParams(var Params: TRoofParams;
  const Footprint: array of TVector3);
var O: TFootprintOMBB;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(222);{$ENDIF}
  O := ComputeFootprintOMBB(Footprint);
  Params.OMBBCenter := O.Center;
  Params.OMBBLongDir := O.LongDir;
  Params.OMBBShortDir := O.ShortDir;
  Params.OMBBLength := O.Length;
  Params.OMBBWidth := O.Width;
end;

function WorldToOMBBLocal(const P: TVector2; const O: TFootprintOMBB): TVector2;
var Rel: TVector2;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(223);{$ENDIF}
  Rel.X := P.X - O.Center.X;
  Rel.Y := P.Y - O.Center.Y;
  Result.X := Vec2Dot(Rel, O.LongDir);
  Result.Y := Vec2Dot(Rel, O.ShortDir);
end;

function PolygonCentroidXZ(const Footprint: array of TVector3): TVector2;
var
  I, J, N: Integer;
  Cross, A: Single;
  Cx, Cz: Double;
  TotalA: Double;
  MnX, MxX, MnZ, MxZ: Single;
  MeanX, MeanZ: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(225);{$ENDIF}
  Result := Vector2(0, 0);
  N := Length(Footprint);
  if N < 3 then Exit;

  { bbox + среднее вершин — страховочный fallback (см. ниже). }
  MnX := Footprint[0].X;  MxX := MnX;
  MnZ := Footprint[0].Z;  MxZ := MnZ;
  MeanX := 0;  MeanZ := 0;
  for I := 0 to N - 1 do
  begin
    if Footprint[I].X < MnX then MnX := Footprint[I].X
    else if Footprint[I].X > MxX then MxX := Footprint[I].X;
    if Footprint[I].Z < MnZ then MnZ := Footprint[I].Z
    else if Footprint[I].Z > MxZ then MxZ := Footprint[I].Z;
    MeanX := MeanX + Footprint[I].X;
    MeanZ := MeanZ + Footprint[I].Z;
  end;
  MeanX := MeanX / N;
  MeanZ := MeanZ / N;

  Cx := 0;
  Cz := 0;
  TotalA := 0;
  for I := 0 to N - 1 do
  begin
    J := (I + 1) mod N;
    Cross := Footprint[I].X * Footprint[J].Z - Footprint[J].X * Footprint[I].Z;
    A := Cross * 0.5;
    Cx := Cx + (Footprint[I].X + Footprint[J].X) * A;
    Cz := Cz + (Footprint[I].Z + Footprint[J].Z) * A;
    TotalA := TotalA + A;
  end;

  { Почти нулевая знаковая площадь (вырожденное кольцо или
    самопересечение-«бабочка» с сокращающимися лепестками): деление на
    TotalA разгоняет центроид на километры либо оставляет (0,0) — начало
    координат чанка. Для пирамид/куполов такой апекс отсёк бы
    RoofGeometryWithinBounds, но EmitChimneyShell/EmitCoolingTowerShell
    строят по центроиду В СТЕНЫ без какой-либо проверки — получался конус
    от здания до origin. Fallback: среднее вершин; плюс страховка
    «центроид обязан лежать внутри bbox кольца». }
  if Abs(TotalA) > 1e-6 then
  begin
    Result.X := Cx / (3 * TotalA);
    Result.Y := Cz / (3 * TotalA);
    if (Result.X < MnX) or (Result.X > MxX) or
       (Result.Y < MnZ) or (Result.Y > MxZ) then
    begin
      Result.X := MeanX;
      Result.Y := MeanZ;
    end;
  end
  else
  begin
    Result.X := MeanX;
    Result.Y := MeanZ;
  end;
end;

procedure GenerateRoofSkirt(var Geom: TRoofGeometry;
  const Footprint: array of TVector3;
  EaveY, OverhangM, DropM: Single);
var
  N, I: Integer;
  PrevX, PrevZ, CurX, CurZ, NextX, NextZ: Single;
  IncX, IncZ, OutX, OutZ: Single;
  IncL, OutL: Single;
  PerpInX, PerpInZ, PerpOutX, PerpOutZ: Single;
  BisX, BisZ, BisL: Single;
  CCW: Boolean;
  Sign: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(226);{$ENDIF}
  N := Length(Footprint);
  Geom.Skirt.HasSkirt := False;
  if (N < 3) or (OverhangM <= 0) then Exit;

  { Outward bisector direction зависит от winding. Для CCW вверх-смотрящего
    polygon'а perpendicular = (dy, -dx) — это outward. Для CW — наоборот. }
  CCW := PolygonSignedAreaXZ(Footprint) > 0;
  if CCW then Sign := 1.0 else Sign := -1.0;

  Geom.Skirt.HasSkirt := True;
  Geom.Skirt.OverhangMeters := OverhangM;
  Geom.Skirt.DropMeters := DropM;
  SetLength(Geom.Skirt.OuterEdge, N);
  SetLength(Geom.Skirt.InnerEdge, N);

  for I := 0 to N - 1 do
  begin
    PrevX := Footprint[(I + N - 1) mod N].X;
    PrevZ := Footprint[(I + N - 1) mod N].Z;
    CurX  := Footprint[I].X;
    CurZ  := Footprint[I].Z;
    NextX := Footprint[(I + 1) mod N].X;
    NextZ := Footprint[(I + 1) mod N].Z;

    IncX := CurX - PrevX;  IncZ := CurZ - PrevZ;
    OutX := NextX - CurX;  OutZ := NextZ - CurZ;
    IncL := Sqrt(IncX * IncX + IncZ * IncZ);
    OutL := Sqrt(OutX * OutX + OutZ * OutZ);
    if IncL > 0 then begin IncX := IncX / IncL; IncZ := IncZ / IncL; end;
    if OutL > 0 then begin OutX := OutX / OutL; OutZ := OutZ / OutL; end;

    { Outward perp (для CCW): (dz, -dx) для каждого направленного edge'а. }
    PerpInX  := Sign *  IncZ;  PerpInZ  := Sign * (-IncX);
    PerpOutX := Sign *  OutZ;  PerpOutZ := Sign * (-OutX);

    { Outward bisector = perpIn + perpOut, нормализован. }
    BisX := PerpInX + PerpOutX;
    BisZ := PerpInZ + PerpOutZ;
    BisL := Sqrt(BisX * BisX + BisZ * BisZ);
    if BisL < 1e-6 then
    begin
      { Вырожденный угол (180°) — bisector неопределён; берём perpOut. }
      BisX := PerpOutX;
      BisZ := PerpOutZ;
    end
    else
    begin
      BisX := BisX / BisL;
      BisZ := BisZ / BisL;
    end;

    { Outer skirt point = footprint vertex + unit bisector * OverhangM (a simple approximation;
      exact perpendicular offset would divide by cos(halfAngle), unstable at sharp angles). }
    Geom.Skirt.OuterEdge[I].X := CurX + BisX * OverhangM;
    Geom.Skirt.OuterEdge[I].Z := CurZ + BisZ * OverhangM;
    Geom.Skirt.OuterEdge[I].Y := EaveY - DropM;

    Geom.Skirt.InnerEdge[I].X := CurX;
    Geom.Skirt.InnerEdge[I].Z := CurZ;
    Geom.Skirt.InnerEdge[I].Y := EaveY;
  end;
end;

procedure SortByPolarAngle(var Verts: array of TVector2; N: Integer);
var
  I, J:   Integer;
  Cx, Cy: Single;
  Angles: array of Single;
  TmpV:   TVector2;
  TmpA:   Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(227);{$ENDIF}
  if N < 4 then Exit;

  Cx := 0; Cy := 0;
  for I := 0 to N - 1 do
  begin
    Cx := Cx + Verts[I].X;
    Cy := Cy + Verts[I].Y;
  end;
  Cx := Cx / N;
  Cy := Cy / N;

  SetLength(Angles, N);
  for I := 0 to N - 1 do
    Angles[I] := ArcTan2(Verts[I].Y - Cy, Verts[I].X - Cx);

  { Bubble sort по углу по возрастанию (= CCW от +X в 2D).
    N обычно 4-8 — O(N²) приемлемо. }
  for I := 0 to N - 2 do
    for J := 0 to N - 2 - I do
      if Angles[J] > Angles[J + 1] then
      begin
        TmpA := Angles[J]; Angles[J] := Angles[J + 1]; Angles[J + 1] := TmpA;
        TmpV := Verts[J];  Verts[J]  := Verts[J + 1];  Verts[J + 1]  := TmpV;
      end;
end;

procedure ApplyRoofGeometryToMesh(const Geom: TRoofGeometry;
  Target: TMesh; FlipWinding: Boolean);
var
  Base, I, A, B, C: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(228);{$ENDIF}
  if (Target = nil) or (not Geom.Valid) then Exit;
  if Geom.VertexCount = 0 then Exit;

  Base := Target.VertexCount;
  { TRoofVertex = TMeshVertex — передаём напрямую без распаковки полей. }
  for I := 0 to Geom.VertexCount - 1 do
    Target.AddVertex(Geom.Vertices[I]);

  for I := 0 to Geom.TriangleCount - 1 do
  begin
    A := Base + Geom.Triangles[I].A;
    B := Base + Geom.Triangles[I].B;
    C := Base + Geom.Triangles[I].C;
    if FlipWinding then
      Target.AddTriangle(A, C, B)
    else
      Target.AddTriangle(A, B, C);
  end;
end;

type
  TRoofVector2Array = array of TVector2;
  TRoofVector3Array = array of TVector3;
  TRoofIndexGrid = array of array of Integer;
  TRoofHeightFn = function(NormalizedDst: Single): Single;
  TOMBBProfileHeightFn = function(const P: TRoofParams;
    const OMBB: TFootprintOMBB; const Local: TVector2): Single;

procedure EmitOutwardTriangleXYZ(var Geom: TRoofGeometry;
  const P0, P1, P2: TVector3;
  const UV0, UV1, UV2: TVector2;
  const RefPoint: TVector3);
var
  E1, E2, FN, FC, OD: TVector3;
  Dot: Single;
  PA, PB, PC: TVector3;
  UA, UB, UC: TVector2;
  I0, I1, I2: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(229);{$ENDIF}
  { Face normal = (P1-P0) × (P2-P0). }
  E1.X := P1.X - P0.X; E1.Y := P1.Y - P0.Y; E1.Z := P1.Z - P0.Z;
  E2.X := P2.X - P0.X; E2.Y := P2.Y - P0.Y; E2.Z := P2.Z - P0.Z;
  FN := VecCross(E1, E2);
  if (Abs(FN.X) + Abs(FN.Y) + Abs(FN.Z)) < 1e-9 then Exit;
  FN := VecNormalize(FN);

  FC.X := (P0.X + P1.X + P2.X) / 3.0;
  FC.Y := (P0.Y + P1.Y + P2.Y) / 3.0;
  FC.Z := (P0.Z + P1.Z + P2.Z) / 3.0;

  { Outward direction: from building center to face center. }
  OD.X := FC.X - RefPoint.X;
  OD.Y := FC.Y - RefPoint.Y;
  OD.Z := FC.Z - RefPoint.Z;

  Dot := FN.X * OD.X + FN.Y * OD.Y + FN.Z * OD.Z;

  if Dot < 0 then
  begin
    { Normal points "inward" — flip both normal and winding. }
    FN.X := -FN.X; FN.Y := -FN.Y; FN.Z := -FN.Z;
    PA := P0; PB := P2; PC := P1;
    UA := UV0; UB := UV2; UC := UV1;
  end
  else
  begin
    PA := P0; PB := P1; PC := P2;
    UA := UV0; UB := UV1; UC := UV2;
  end;

  I0 := AppendRoofVertex(Geom, PA, FN, UA);
  I1 := AppendRoofVertex(Geom, PB, FN, UB);
  I2 := AppendRoofVertex(Geom, PC, FN, UC);
  AppendRoofTriangle(Geom, I0, I1, I2);
end;

function RoofUVXZ(const Pos: TVector3): TVector2; inline;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(230);{$ENDIF}
  Result := Vector2(Pos.X / 4.0, Pos.Z / 4.0);
end;

function EmitIndexedRoofXZ(var Geom: TRoofGeometry;
  const Roof: array of TVector3; const Tris: array of Integer;
  const Norm: TVector3): Boolean;
var
  I, Base, Idx: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(231);{$ENDIF}
  Result := False;
  if (Length(Roof) < 3) or (Length(Tris) = 0) then Exit;

  Base := Geom.VertexCount;
  for I := 0 to High(Roof) do
    AppendRoofVertex(Geom, Roof[I], Norm, RoofUVXZ(Roof[I]));

  Idx := 0;
  while Idx + 3 <= Length(Tris) do
  begin
    { Defensive: никогда не индексировать Roof[] вне диапазона — тот же
      guard, что в BuildFlat. Кривой индекс триангулятора при выключенном
      $R- стал бы треугольником в чужую вершину целевого меша, и
      RoofGeometryWithinBounds это НЕ ловит: он проверяет вершины, а не
      индексы треугольников. }
    if (Tris[Idx]     < 0) or (Tris[Idx]     > High(Roof)) or
       (Tris[Idx + 1] < 0) or (Tris[Idx + 1] > High(Roof)) or
       (Tris[Idx + 2] < 0) or (Tris[Idx + 2] > High(Roof)) then
    begin
      Inc(Idx, 3);
      Continue;
    end;
    AppendRoofTriangle(Geom,
      Base + Tris[Idx], Base + Tris[Idx + 2], Base + Tris[Idx + 1]);
    Inc(Idx, 3);
  end;

  Result := True;
end;

procedure InitRoofIndexGrid(out Verts: TRoofIndexGrid; RowCount, ColCount: Integer);
var
  I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(232);{$ENDIF}
  SetLength(Verts, RowCount);
  for I := 0 to RowCount - 1 do
    SetLength(Verts[I], ColCount);
end;

procedure EmitGridTriangles(var Geom: TRoofGeometry;
  const Verts: TRoofIndexGrid; RowCount, ColCount: Integer);
var
  Row, Col: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(233);{$ENDIF}
  for Row := 0 to RowCount - 2 do
    for Col := 0 to ColCount - 2 do
    begin
      AppendRoofTriangle(Geom, Verts[Row][Col], Verts[Row + 1][Col],
        Verts[Row + 1][Col + 1]);
      AppendRoofTriangle(Geom, Verts[Row][Col], Verts[Row + 1][Col + 1],
        Verts[Row][Col + 1]);
    end;
end;

procedure FootprintToOutline2D(const Footprint: array of TVector3;
  out Outline: array of TVector2; out WasReversed: Boolean);
var
  N, I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(234);{$ENDIF}
  N := Length(Footprint);
  WasReversed := False;

  if PolygonSignedAreaXZ(Footprint) > 0 then
  begin
    for I := 0 to N - 1 do
      Outline[I] := Vector2(Footprint[I].X, Footprint[I].Z);
  end
  else
  begin
    WasReversed := True;
    for I := 0 to N - 1 do
      Outline[N - 1 - I] := Vector2(Footprint[I].X, Footprint[I].Z);
  end;
end;

{ Skeleton face vertices in local 2D (X=world.X, Y=world.Z) for earcut.
  IMPORTANT: the skeleton may return them in a self-intersecting ("bowtie") order, which earcuts
  wrong. Skeleton faces are convex, so we reorder by polar angle around the centroid -> correct CCW walk. }
procedure GetSkeletonFaceVertices2D(
  const Skel: TStraightSkeleton; FaceIdx: Integer;
  const Footprint: array of TVector3;
  out Verts2D: array of TVector2);
var
  N, I: Integer;
  V: TSkeletonVertex;
  Origi, StartIdx, EndIdx: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(235);{$ENDIF}
  N := Length(Skel.Faces[FaceIdx].VertexIndices);
  Origi := Skel.Faces[FaceIdx].OrigEdgeIndex;
  StartIdx := Origi;
  EndIdx := (Origi + 1) mod Length(Footprint);

  for I := 0 to N - 1 do
  begin
    V := Skel.Vertices[Skel.Faces[FaceIdx].VertexIndices[I]];
    { For base-edge endpoints (T=0), use the exact footprint coordinates
      to avoid floating-point drift from skeleton computation. For
      interior (apex) vertices, use skeleton's computed XZ.}
    if V.T <= 1e-4 then
    begin
      if I = 0 then
        Verts2D[I] := Vector2(Footprint[StartIdx].X, Footprint[StartIdx].Z)
      else if I = 1 then
        Verts2D[I] := Vector2(Footprint[EndIdx].X, Footprint[EndIdx].Z)
      else
        Verts2D[I] := Vector2(V.X, V.Z);
    end
    else
      Verts2D[I] := Vector2(V.X, V.Z);
  end;

  if N < 4 then Exit;

  { Sort by polar angle around centroid → guaranteed CCW walk. }
  SortByPolarAngle(Verts2D, N);
end;

{ Global max signed distance from any skeleton-face vertex to its base edge.
  Key to robust hipped-roof height: vertex height = dst / maxSkeletonHeight * roofH, purely from
  2D geometry (not skeleton time T, which can be inconsistent on irregular polygons). For a W×L
  rectangle this equals W/2. }
function ComputeSkeletonMaxHeight(const Skel: TStraightSkeleton;
  const Footprint: array of TVector3): Single;
var
  I, J, N: Integer;
  Verts2D: array of TVector2;
  EdgeA, EdgeB: TVector2;
  Origi, StartIdx, EndIdx: Integer;
  Dst: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(236);{$ENDIF}
  Result := 0;
  for I := 0 to High(Skel.Faces) do
  begin
    N := Length(Skel.Faces[I].VertexIndices);
    if N < 3 then Continue;

    Origi := Skel.Faces[I].OrigEdgeIndex;
    StartIdx := Origi;
    EndIdx := (Origi + 1) mod Length(Footprint);
    EdgeA := Vector2(Footprint[StartIdx].X, Footprint[StartIdx].Z);
    EdgeB := Vector2(Footprint[EndIdx].X, Footprint[EndIdx].Z);

    SetLength(Verts2D, N);
    GetSkeletonFaceVertices2D(Skel, I, Footprint, Verts2D);

    for J := 0 to N - 1 do
    begin
      Dst := Abs(SignedDstToLine(Verts2D[J], EdgeA, EdgeB));
      if Dst > Result then Result := Dst;
    end;
  end;
end;

{ Streets-gl style face emit: triangulate via earcut, compute Y from
  2D distance to base edge. Each vertex of each triangle is emitted
  separately (no sharing) with face-flat normal — matches streets-gl
  convention and gives crisp per-face shading for hipped roofs.

  HeightFn: an optional modifier function over normalized distance
  (0..1). For hipped: identity (linear ramp from eave to apex). For
  mansard: piecewise (steep below knee-line, flat above). For half-
  hipped: caps near base edge at full roof height.}
function HippedHeightFn(NormalizedDst: Single): Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(237);{$ENDIF}
  Result := NormalizedDst;
end;

{ Mansard: steep slope from 0..MANSARD_KNEE, then plateau (flat top).
  KNEE = fraction of full height where slope flattens. Streets-gl uses
  similar mapping: full roof reached at 50% distance, then plateau.}
const
  MANSARD_KNEE = 0.5;

function MansardHeightFn(NormalizedDst: Single): Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(238);{$ENDIF}
  if NormalizedDst >= MANSARD_KNEE then
    Result := 1.0
  else
    Result := NormalizedDst / MANSARD_KNEE;
end;

{ Half-hipped: similar to hipped but hip slopes only partway to apex
  (60%); above that, flat shelf. Approximation.}
const
  HALFHIP_HEIGHT_FRAC = 0.85;

function HalfHippedHeightFn(NormalizedDst: Single): Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(239);{$ENDIF}
  if NormalizedDst >= HALFHIP_HEIGHT_FRAC then
    Result := 1.0
  else
    Result := NormalizedDst / HALFHIP_HEIGHT_FRAC;
end;

{ ── Чистка коллинеарных вершин кольца ────────────────────────────────
  OSM-футпринты часто несут 180°-вершины (общий узел с соседним way).
  Straight skeleton на таком кольце порождает фиктивные узлы: раздутый
  MaxSkeletonHeight → сплющенная крыша, кривые полигоны граней →
  перевёрнутые треугольники (culled сверху = «дыра») и длинный тонкий
  «шпиль»-сливер от короткого суб-ребра — ровно картина Фрунзе 34 в
  roof_debug. Вершина выбрасывается, если её перпендикулярное отклонение
  от прямой (prev→next) меньше COLLINEAR_EPS_M; легитимные фасадные
  уступы (0.3+ м) не трогаются. False — если осталось < 3 вершин. }
const
  COLLINEAR_EPS_M = 0.12;

function RemoveCollinearRingVertices(const Src: array of TVector3;
  out Dst: TRoofVector3Array): Boolean;
var
  N, I, K, Keep: Integer;
  Px, Pz, Cx, Cz, Ex, Ez, L, D: Single;
  Mark: array of Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1470);{$ENDIF}
  Result := False;
  N := Length(Src);
  SetLength(Dst, 0);
  if N < 3 then Exit;
  SetLength(Mark, N);
  Keep := N;
  for I := 0 to N - 1 do
  begin
    Px := Src[(I + N - 1) mod N].X;  Pz := Src[(I + N - 1) mod N].Z;
    Cx := Src[I].X;                  Cz := Src[I].Z;
    Ex := Src[(I + 1) mod N].X - Px;
    Ez := Src[(I + 1) mod N].Z - Pz;
    L  := Sqrt(Ex * Ex + Ez * Ez);
    if L < 1e-6 then
      D := 0                    { prev = next (дубль) — вершина лишняя }
    else
      D := Abs((Cx - Px) * Ez - (Cz - Pz) * Ex) / L;
    Mark[I] := D < COLLINEAR_EPS_M;
    if Mark[I] then Dec(Keep);
  end;
  if Keep < 3 then Exit;        { кольцо почти прямая — крыши не будет }
  SetLength(Dst, Keep);
  K := 0;
  for I := 0 to N - 1 do
    if not Mark[I] then
    begin
      Dst[K] := Src[I];
      Inc(K);
    end;
  Result := True;
end;

{ ── Валидация геометрии крыши (скелет / OMBB-хип) ────────────────────
  Дешёвая пост-проверка на порчу, которую bbox-контроль не видит:
  (1) грань с нормалью вниз или строго вертикальный сливер (ny < MIN_NY):
      после MakeWindingMatchNormals winding равняется на authored-нормаль,
      и такая грань culled сверху — «голубая дыра» вместо ската;
  (2) один XZ-узел с разными Y в разных гранях — геометрически
      несогласованный скелет (мятая/сплющенная крыша).
  Провал ⇒ вызывающий откатывается на следующий билдер или flat. }
function RoofGeomOrientationOK(const Geom: TRoofGeometry): Boolean;
const
  MIN_NY = 0.02;
  Y_EPS  = 0.15;
  XZ_EPS = 0.02;
var
  I, J: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1471);{$ENDIF}
  Result := False;
  { per-face эмит: у всех трёх вершин треугольника одна authored-нормаль —
    достаточно проверить вершину A. }
  for I := 0 to Geom.TriangleCount - 1 do
    if Geom.Vertices[Geom.Triangles[I].A].Normal.Y < MIN_NY then Exit;
  for I := 0 to Geom.VertexCount - 1 do
    for J := I + 1 to Geom.VertexCount - 1 do
      if (Abs(Geom.Vertices[I].Position.X - Geom.Vertices[J].Position.X) < XZ_EPS)
      and (Abs(Geom.Vertices[I].Position.Z - Geom.Vertices[J].Position.Z) < XZ_EPS)
      and (Abs(Geom.Vertices[I].Position.Y - Geom.Vertices[J].Position.Y) > Y_EPS) then
        Exit;
  Result := True;
end;

function TryPrepareSkeletonRoof(const P: TRoofParams;
  out Skel: TStraightSkeleton; out ActualFootprint: TRoofVector3Array;
  out MaxSkelHeight: Single): Boolean;
var
  Outline: TRoofVector2Array;
  Reversed: Boolean;
  I, N: Integer;
  CleanFp: TRoofVector3Array;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(240);{$ENDIF}
  Result := False;
  MaxSkelHeight := 0;
  if Length(P.Footprint) < 3 then Exit;

  { Коллинеарные (180°) вершины ломают скелет — чистим кольцо ДО него.
    Скелет, ActualFootprint и все Dst-расчёты граней дальше работают на
    ОДНОМ очищенном кольце (OrigEdgeIndex обязан индексировать его же);
    стены/юбка по-прежнему строятся по полному футпринту — там
    коллинеарная вершина безвредна (два копланарных квада). }
  if not RemoveCollinearRingVertices(P.Footprint, CleanFp) then Exit;
  N := Length(CleanFp);

  SetLength(Outline, N);
  FootprintToOutline2D(CleanFp, Outline, Reversed);
  Skel := ComputeStraightSkeleton(Outline);
  if not Skel.Valid then Exit;

  SetLength(ActualFootprint, N);
  if Reversed then
    for I := 0 to N - 1 do
      ActualFootprint[I] := CleanFp[N - 1 - I]
  else
    for I := 0 to N - 1 do
      ActualFootprint[I] := CleanFp[I];

  MaxSkelHeight := ComputeSkeletonMaxHeight(Skel, ActualFootprint);
  Result := MaxSkelHeight >= 1e-4;
end;

procedure EmitSkeletonFaceToGeom(var Geom: TRoofGeometry;
  const Skel: TStraightSkeleton; FaceIdx: Integer;
  const Footprint: array of TVector3;
  EaveY, RoofH, MaxSkeletonHeight: Single;
  HeightFn: TRoofHeightFn);
var
  N, I: Integer;
  Verts2D: array of TVector2;
  FlatData: array of Double;     { for earcut: [x0,y0, x1,y1, ...] }
  Tris: TIntArray;
  Origi, StartIdx, EndIdx: Integer;
  EdgeA, EdgeB: TVector2;
  Vert2D: TVector2;
  Pos: TVector3;
  Dst: Single;
  P0, P1, P2: TVector3;
  Idx: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(241);{$ENDIF}
  N := Length(Skel.Faces[FaceIdx].VertexIndices);
  if N < 3 then Exit;

  Origi := Skel.Faces[FaceIdx].OrigEdgeIndex;
  StartIdx := Origi;
  EndIdx := (Origi + 1) mod Length(Footprint);
  EdgeA := Vector2(Footprint[StartIdx].X, Footprint[StartIdx].Z);
  EdgeB := Vector2(Footprint[EndIdx].X, Footprint[EndIdx].Z);

  SetLength(Verts2D, N);
  GetSkeletonFaceVertices2D(Skel, FaceIdx, Footprint, Verts2D);

  { Flatten for earcut. }
  SetLength(FlatData, N * 2);
  for I := 0 to N - 1 do
  begin
    FlatData[I * 2]     := Verts2D[I].X;
    FlatData[I * 2 + 1] := Verts2D[I].Y;
  end;

  Tris := TEarcutTriangulator.Triangulate(FlatData, 2);
  if Length(Tris) = 0 then Exit;

  { Compute face Y for each face vertex via 2D distance to base edge.
    streets-gl formula: vertexY = eaveY + roofH * heightFn(dst / maxDst).
    For hipped: linear ramp. Apex (max dst) gets full roofH.}
  if MaxSkeletonHeight < 1e-6 then Exit;

  P0.X := 0; P0.Y := 0; P0.Z := 0;
  for I := 0 to High(Footprint) do
  begin
    P0.X := P0.X + Footprint[I].X;
    P0.Z := P0.Z + Footprint[I].Z;
  end;
  P0.X := P0.X / Length(Footprint);
  P0.Z := P0.Z / Length(Footprint);
  P0.Y := EaveY + RoofH * 0.5;     { mid-roof height — building center for outward check }

  Idx := 0;
  while Idx + 3 <= Length(Tris) do
  begin
    Vert2D := Verts2D[Tris[Idx]];
    Dst := Abs(SignedDstToLine(Vert2D, EdgeA, EdgeB));
    P1.X := Vert2D.X;
    P1.Y := EaveY + RoofH * HeightFn(Dst / MaxSkeletonHeight);
    P1.Z := Vert2D.Y;

    Vert2D := Verts2D[Tris[Idx + 1]];
    Dst := Abs(SignedDstToLine(Vert2D, EdgeA, EdgeB));
    P2.X := Vert2D.X;
    P2.Y := EaveY + RoofH * HeightFn(Dst / MaxSkeletonHeight);
    P2.Z := Vert2D.Y;

    Vert2D := Verts2D[Tris[Idx + 2]];
    Dst := Abs(SignedDstToLine(Vert2D, EdgeA, EdgeB));
    Pos.X := Vert2D.X;
    Pos.Y := EaveY + RoofH * HeightFn(Dst / MaxSkeletonHeight);
    Pos.Z := Vert2D.Y;

    EmitOutwardTriangleXYZ(Geom, P1, P2, Pos,
      RoofUVXZ(P1),
      RoofUVXZ(P2),
      RoofUVXZ(Pos),
      P0);
    Inc(Idx, 3);
  end;
end;

procedure EmitSkeletonRoofFaces(var Geom: TRoofGeometry;
  const Skel: TStraightSkeleton; const ActualFootprint: array of TVector3;
  EaveY, RoofH, MaxSkelHeight: Single; HeightFn: TRoofHeightFn);
var
  I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(242);{$ENDIF}
  for I := 0 to High(Skel.Faces) do
    EmitSkeletonFaceToGeom(Geom, Skel, I, ActualFootprint,
      EaveY, RoofH, MaxSkelHeight, HeightFn);
end;

{ Footprint sanitiser
 Guards every roof builder against a single runaway footprint vertex:
 a NaN/Inf coordinate, or a vertex implausibly far from the rest (an
 OSM node that failed to resolve and collapsed onto the world origin,
 a bad rebase delta, etc.). Left alone, such a vertex turns a flat roof
 into a map-spanning triangle and — because it inflates the building,
 and hence the tile, bounding box — makes the whole tile mis-cull.

 Outliers are detected with a robust component-wise median centre and a
 median-spread threshold (so honest large buildings are never touched),
 then pulled onto the centroid of the sane vertices. The ring keeps its
 vertex count and stays closed; the affected building merely gets a
 pinched corner instead of a monster triangle. Returns False when fewer
 than 3 sane vertices remain — the caller should then skip the roof.
 Overload с BadMask сообщает, КАКИЕ вершины были закламплены, чтобы
 вызывающий пересэмплировал высоту рельефа под их НОВЫМИ позициями. }
function SanitizeFootprintRing(var Ring: array of TVector3;
  out BadMask: TBooleanArray): Boolean; overload;
const
  { Below this distance a vertex is never treated as a runaway, so small
    honest buildings are immune to false positives. }
  OUTLIER_FLOOR_M = 120.0;
  { A vertex this many times past the typical vertex spread is bogus —
    even the largest real buildings stay well under this multiple. }
  OUTLIER_SPREAD_K = 12.0;
  { Absolute ceiling on the threshold: no real building footprint vertex
    sits this far from the building centre, so anything beyond is always
    a runaway regardless of how the relative test scaled. }
  OUTLIER_CAP_M = 800.0;
var
  N, I, J, SaneN: Integer;
  Xs, Zs, Ds: array of Single;
  MedX, MedZ, MedD, T, Thr: Single;
  SumX, SumZ: Double;
  CX, CZ: Single;

  function FiniteV(const V: TVector3): Boolean;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1442);{$ENDIF}
    Result := (not IsNan(V.X)) and (not IsInfinite(V.X)) and
              (not IsNan(V.Z)) and (not IsInfinite(V.Z));
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1443);{$ENDIF}
  Result := False;
  N := Length(Ring);
  SetLength(BadMask, N);   { SetLength зануляет элементы — маска чистая }
  if N < 3 then Exit;

  { Component-wise median centre — robust to a minority of runaways
    (unlike the plain mean, which a single far vertex drags away). }
  SetLength(Xs, N);
  SetLength(Zs, N);
  for I := 0 to N - 1 do
    if FiniteV(Ring[I]) then
    begin
      Xs[I] := Ring[I].X;  Zs[I] := Ring[I].Z;
    end
    else
    begin
      Xs[I] := 0;  Zs[I] := 0;
    end;
  for I := 1 to N - 1 do                  { insertion sort — N is small }
  begin
    T := Xs[I];  J := I - 1;
    while (J >= 0) and (Xs[J] > T) do begin Xs[J + 1] := Xs[J]; Dec(J); end;
    Xs[J + 1] := T;
  end;
  for I := 1 to N - 1 do
  begin
    T := Zs[I];  J := I - 1;
    while (J >= 0) and (Zs[J] > T) do begin Zs[J + 1] := Zs[J]; Dec(J); end;
    Zs[J + 1] := T;
  end;
  MedX := Xs[N div 2];
  MedZ := Zs[N div 2];

  { Median distance to the centre = the typical vertex spread. }
  SetLength(Ds, N);
  for I := 0 to N - 1 do
    if FiniteV(Ring[I]) then
      Ds[I] := Sqrt(Sqr(Ring[I].X - MedX) + Sqr(Ring[I].Z - MedZ))
    else
      Ds[I] := 1.0e30;
  for I := 1 to N - 1 do
  begin
    T := Ds[I];  J := I - 1;
    while (J >= 0) and (Ds[J] > T) do begin Ds[J + 1] := Ds[J]; Dec(J); end;
    Ds[J + 1] := T;
  end;
  MedD := Ds[N div 2];

  Thr := OUTLIER_SPREAD_K * MedD;
  if Thr < OUTLIER_FLOOR_M then Thr := OUTLIER_FLOOR_M;
  if Thr > OUTLIER_CAP_M  then Thr := OUTLIER_CAP_M;

  { Flag outliers; accumulate the sane centroid. }
  SumX := 0;  SumZ := 0;  SaneN := 0;
  for I := 0 to N - 1 do
  begin
    BadMask[I] := (not FiniteV(Ring[I])) or
              (Sqrt(Sqr(Ring[I].X - MedX) + Sqr(Ring[I].Z - MedZ)) > Thr);
    if not BadMask[I] then
    begin
      SumX := SumX + Ring[I].X;
      SumZ := SumZ + Ring[I].Z;
      Inc(SaneN);
    end;
  end;

  if SaneN < 3 then
    Result := False                       { roof geometry not trustworthy }
  else
    Result := True;
  if SaneN = N then Exit;                 { nothing to fix — common path }

  { Clamp every runaway onto a safe point so NO wild coordinate ever
    survives — even when Result is False. Prefer the sane centroid; if
    too few sane vertices remain, fall back to the median centre, which
    is still guaranteed finite and inside the data. }
  if SaneN >= 3 then
  begin
    CX := SumX / SaneN;
    CZ := SumZ / SaneN;
  end
  else
  begin
    CX := MedX;
    CZ := MedZ;
  end;
  { Прищёлкнуть точку клампа к решётке int-first 1/64 м: весь футпринт
    квантован на входе, и заклампленная вершина не должна выпадать из
    фазы композита. }
  CX := Round(CX * 64.0) * (1.0 / 64.0);
  CZ := Round(CZ * 64.0) * (1.0 / 64.0);
  for I := 0 to N - 1 do
    if BadMask[I] then
    begin
      Ring[I].X := CX;
      Ring[I].Z := CZ;
      { Y is left alone — flat roofs overwrite it with EaveY anyway. }
    end;
end;

{ Обёртка без маски — прежняя сигнатура для BuildFlat и прочих мест,
  которым сама маска не нужна. }
function SanitizeFootprintRing(var Ring: array of TVector3): Boolean; overload;
var
  IgnoredMask: TBooleanArray;
begin
  Result := SanitizeFootprintRing(Ring, IgnoredMask);
  IgnoredMask := nil;
end;

{ Validate finished roof geometry: every vertex must be finite and inside the sane envelope
  (XZ within the footprint bbox + overhang margin, Y in [eave-margin, ridge+margin]). A failure
  tells the caller to discard the roof and fall back to flat. }
function RoofGeometryWithinBounds(const Geom: TRoofGeometry;
  const Footprint: array of TVector3;
  EaveY, RoofHeight: Single): Boolean;
const
  XZ_MARGIN_M = 40.0;   { covers any honest roof overhang / skirt }
  Y_MARGIN_M  = 40.0;
var
  I: Integer;
  MinX, MaxX, MinZ, MaxZ, LoY, HiY, PX, PY, PZ: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1444);{$ENDIF}
  Result := True;
  if (Geom.VertexCount = 0) or (Length(Footprint) = 0) then Exit;

  MinX := Footprint[0].X;  MaxX := MinX;
  MinZ := Footprint[0].Z;  MaxZ := MinZ;
  for I := 1 to High(Footprint) do
  begin
    if Footprint[I].X < MinX then MinX := Footprint[I].X;
    if Footprint[I].X > MaxX then MaxX := Footprint[I].X;
    if Footprint[I].Z < MinZ then MinZ := Footprint[I].Z;
    if Footprint[I].Z > MaxZ then MaxZ := Footprint[I].Z;
  end;
  MinX := MinX - XZ_MARGIN_M;  MaxX := MaxX + XZ_MARGIN_M;
  MinZ := MinZ - XZ_MARGIN_M;  MaxZ := MaxZ + XZ_MARGIN_M;
  LoY  := EaveY - Y_MARGIN_M;
  HiY  := EaveY + Max(0.0, RoofHeight) + Y_MARGIN_M;

  for I := 0 to Geom.VertexCount - 1 do
  begin
    PX := Geom.Vertices[I].Position.X;
    PY := Geom.Vertices[I].Position.Y;
    PZ := Geom.Vertices[I].Position.Z;
    if IsNan(PX) or IsInfinite(PX) or
       IsNan(PY) or IsInfinite(PY) or
       IsNan(PZ) or IsInfinite(PZ) then
      Exit(False);
    if (PX < MinX) or (PX > MaxX) or
       (PZ < MinZ) or (PZ > MaxZ) or
       (PY < LoY)  or (PY > HiY) then
      Exit(False);
  end;
  Result := True;
end;

class function TRoofBuilder.BuildFlat(const P: TRoofParams): TRoofGeometry;
var
  Tris: array of Integer;
  Roof: array of TVector3;
  I, Idx: Integer;
  Centroid, RefPt: TVector3;
  UVa, UVb, UVc: TVector2;
  N3: Integer;
  H, K, RingLen: Integer;          { hole loop / running vertex index }
  Flat: array of Double;           { [x0,z0, x1,z1, ...] for earcut }
  HoleIdx: array of Integer;       { vertex index where each hole starts }
  HoleRing: array of TVector3;     { one inner ring, sanitised at EaveY }
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1065);{$ENDIF}
  Result := EmptyRoofGeometry;
  if Length(P.Footprint) < 3 then Exit;

  SetLength(Roof, Length(P.Footprint));
  for I := 0 to High(P.Footprint) do
  begin
    Roof[I] := P.Footprint[I];
    Roof[I].Y := P.EaveY;
  end;

  { Neutralise a runaway footprint vertex before it reaches the
    triangulator — otherwise one bad corner becomes a huge flat
    triangle and corrupts the tile bounding box. }
  if not SanitizeFootprintRing(Roof) then Exit;

  if Length(P.Holes) > 0 then
  begin
    { Courtyard(s): append each sanitised inner ring to Roof, then earcut the
      outer + holes. HoleIdx[i] is the VERTEX index where inner ring i starts
      (outer occupies 0..OuterN-1). Winding is auto-normalised by the earcut
      (outer forced CCW, holes CW), so inner rings pass through as-is. A hole
      that is degenerate/runaway is dropped; if ALL drop we fall back to a
      solid roof. Roof keeps every vertex so the emit loop below (bounds by
      High(Roof)) indexes the whole outer+inner set. }
    K := Length(Roof);
    SetLength(HoleIdx, 0);
    for H := 0 to High(P.Holes) do
    begin
      RingLen := Length(P.Holes[H]);
      if RingLen < 3 then Continue;
      SetLength(HoleRing, RingLen);
      for I := 0 to RingLen - 1 do
      begin
        HoleRing[I]   := P.Holes[H][I];
        HoleRing[I].Y := P.EaveY;
      end;
      if not SanitizeFootprintRing(HoleRing) then Continue;
      SetLength(HoleIdx, Length(HoleIdx) + 1);
      HoleIdx[High(HoleIdx)] := K;
      SetLength(Roof, K + RingLen);
      for I := 0 to RingLen - 1 do
      begin
        Roof[K] := HoleRing[I];
        Inc(K);
      end;
    end;

    if Length(HoleIdx) = 0 then
      Tris := TPolygonTriangulator.TriangulateXZ(Roof)
    else
    begin
      SetLength(Flat, Length(Roof) * 2);
      for I := 0 to High(Roof) do
      begin
        Flat[I * 2]     := Roof[I].X;
        Flat[I * 2 + 1] := Roof[I].Z;
      end;
      Tris := TEarcutTriangulator.Triangulate(Flat, HoleIdx, 2);
    end;
  end
  else
    Tris := TPolygonTriangulator.TriangulateXZ(Roof);
  if Length(Tris) = 0 then Exit;

  Centroid.X := 0; Centroid.Y := 0; Centroid.Z := 0;
  N3 := Length(Roof);
  for I := 0 to N3 - 1 do
  begin
    Centroid.X := Centroid.X + Roof[I].X;
    Centroid.Z := Centroid.Z + Roof[I].Z;
  end;
  RefPt.X := Centroid.X / N3;
  RefPt.Y := P.EaveY - 1.0;
  RefPt.Z := Centroid.Z / N3;

  Idx := 0;
  while Idx + 3 <= Length(Tris) do
  begin
    { Defensive: never index Roof[] out of range. TriangulateXZ should
      only ever emit indices in [0, High(Roof)], but a bad index here
      would read garbage memory and place a vertex anywhere. }
    if (Tris[Idx]     < 0) or (Tris[Idx]     > High(Roof)) or
       (Tris[Idx + 1] < 0) or (Tris[Idx + 1] > High(Roof)) or
       (Tris[Idx + 2] < 0) or (Tris[Idx + 2] > High(Roof)) then
    begin
      Inc(Idx, 3);
      Continue;
    end;
    UVa := RoofUVXZ(Roof[Tris[Idx]]);
    UVb := RoofUVXZ(Roof[Tris[Idx + 1]]);
    UVc := RoofUVXZ(Roof[Tris[Idx + 2]]);
    EmitOutwardTriangleXYZ(Result,
      Roof[Tris[Idx]], Roof[Tris[Idx + 1]], Roof[Tris[Idx + 2]],
      UVa, UVb, UVc, RefPt);
    Inc(Idx, 3);
  end;
  Result.Valid := True;
end;

class function TRoofBuilder.BuildPyramidal(const P: TRoofParams): TRoofGeometry;
var
  Centroid: TVector2;
  Apex, EdgeStart, EdgeEnd, RefPoint: TVector3;
  N, I: Integer;
  Area, Side: Double;
begin
  Result := EmptyRoofGeometry;
  N := Length(P.Footprint);
  if N < 3 then Exit;
  Centroid := PolygonCentroidXZ(P.Footprint);
  Area := PolygonSignedAreaXZ(P.Footprint);
  { A fan is valid only when the apex projects into the polygon kernel.
    An arbitrary concave ring must use the caller's flat fallback. }
  for I := 0 to N - 1 do
  begin
    EdgeStart := P.Footprint[I];
    EdgeEnd := P.Footprint[(I+1) mod N];
    Side := (EdgeEnd.X-EdgeStart.X)*(Centroid.Y-EdgeStart.Z)
          - (EdgeEnd.Z-EdgeStart.Z)*(Centroid.X-EdgeStart.X);
    if Side*Area < -0.0001 then Exit;
  end;
  Apex := Vector3(Centroid.X, P.EaveY + P.RoofHeight, Centroid.Y);
  RefPoint := Vector3(Centroid.X, P.EaveY - 1, Centroid.Y);
  for I := 0 to N - 1 do
  begin
    EdgeStart := P.Footprint[I]; EdgeStart.Y := P.EaveY;
    EdgeEnd := P.Footprint[(I+1) mod N]; EdgeEnd.Y := P.EaveY;
    EmitOutwardTriangleXYZ(Result, EdgeStart, EdgeEnd, Apex,
      Vector2(0,0), Vector2(1,0), Vector2(0.5,1), RefPoint);
  end;
  Result.Valid := Result.TriangleCount > 0;
end;

function BuildHippedRect4(const P: TRoofParams): TRoofGeometry;
var
  OMBB: TFootprintOMBB;
  Local: array[0..3] of TVector2;
  Quad: array[0..3] of TVector3;
  SlotTaken: array[0..3] of Boolean;
  CU, CV: array[0..3] of Single;
  HalfL, HalfW, HalfRidge: Single;
  Apex1, Apex2: TVector3;
  I, J, BestJ: Integer;
  D, BestD: Single;
  RefPt: TVector3;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(243);{$ENDIF}
  Result := EmptyRoofGeometry;
  if Length(P.Footprint) <> 4 then Exit;

  OMBB := ComputeFootprintOMBB(P.Footprint);
  HalfL := OMBB.Length * 0.5;
  HalfW := OMBB.Width * 0.5;
  if (HalfL < 0.5) or (HalfW < 0.5) then Exit;
  HalfRidge := Max(0, HalfL - HalfW);

  { Project 4 footprint vertices to OMBB local coords. }
  for I := 0 to 3 do
    Local[I] := WorldToOMBBLocal(Vector2(P.Footprint[I].X, P.Footprint[I].Z), OMBB);

  { Слоты углов в локальных координатах OMBB:
      0 = (-L/2, -W/2), 1 = (+L/2, -W/2), 2 = (+L/2, +W/2), 3 = (-L/2, +W/2). }
  CU[0] := -HalfL;  CV[0] := -HalfW;
  CU[1] :=  HalfL;  CV[1] := -HalfW;
  CU[2] :=  HalfL;  CV[2] :=  HalfW;
  CU[3] := -HalfL;  CV[3] :=  HalfW;

  { Каждой вершине футпринта — БЛИЖАЙШИЙ угол OMBB, с контролем
    уникальности. Прежняя классификация по знакам (u,v) НЕ была биекцией:
    на скошенном выпуклом четырёхугольнике (трапеция/параллелограмм —
    ~19% сильно скошенных квадов в симуляции) две вершины попадали в один
    слот, а другой слот Quad[] оставался НЕинициализированным стек-мусором
    → треугольники в случайные координаты; «маленький» мусор (остатки
    OMBB-математики этого же здания на стеке) проходит даже
    RoofGeometryWithinBounds. Коллизия теперь = отказ: Valid=False,
    BuildHipped уходит на общий скелетный путь. }
  for J := 0 to 3 do SlotTaken[J] := False;
  for I := 0 to 3 do
  begin
    BestJ := 0;
    BestD := Sqr(Local[I].X - CU[0]) + Sqr(Local[I].Y - CV[0]);
    for J := 1 to 3 do
    begin
      D := Sqr(Local[I].X - CU[J]) + Sqr(Local[I].Y - CV[J]);
      if D < BestD then begin BestD := D; BestJ := J; end;
    end;
    if SlotTaken[BestJ] then Exit;   { двое в один угол — не «почти прямоугольник» }
    SlotTaken[BestJ] := True;
    Quad[BestJ].X := P.Footprint[I].X;
    Quad[BestJ].Y := P.EaveY;
    Quad[BestJ].Z := P.Footprint[I].Z;
  end;

  { Apex points on ridge: at OMBB local (±halfRidge, 0). }
  Apex1.X := OMBB.Center.X + OMBB.LongDir.X * HalfRidge;
  Apex1.Y := P.EaveY + P.RoofHeight;
  Apex1.Z := OMBB.Center.Y + OMBB.LongDir.Y * HalfRidge;

  Apex2.X := OMBB.Center.X - OMBB.LongDir.X * HalfRidge;
  Apex2.Y := P.EaveY + P.RoofHeight;
  Apex2.Z := OMBB.Center.Y - OMBB.LongDir.Y * HalfRidge;

  RefPt.X := OMBB.Center.X;
  RefPt.Y := P.EaveY + P.RoofHeight * 0.5;
  RefPt.Z := OMBB.Center.Y;

  { Front face: BL → BR → Apex1 → Apex2 (trapezoid). }
  EmitOutwardTriangleXYZ(Result, Quad[0], Quad[1], Apex1,
    RoofUVXZ(Quad[0]),
    RoofUVXZ(Quad[1]),
    RoofUVXZ(Apex1),   RefPt);
  EmitOutwardTriangleXYZ(Result, Quad[0], Apex1, Apex2,
    RoofUVXZ(Quad[0]),
    RoofUVXZ(Apex1),
    RoofUVXZ(Apex2),   RefPt);

  EmitOutwardTriangleXYZ(Result, Quad[1], Quad[2], Apex1,
    RoofUVXZ(Quad[1]),
    RoofUVXZ(Quad[2]),
    RoofUVXZ(Apex1),   RefPt);

  { Back face: TR → TL → Apex2 → Apex1 (trapezoid). }
  EmitOutwardTriangleXYZ(Result, Quad[2], Quad[3], Apex2,
    RoofUVXZ(Quad[2]),
    RoofUVXZ(Quad[3]),
    RoofUVXZ(Apex2),   RefPt);
  EmitOutwardTriangleXYZ(Result, Quad[2], Apex2, Apex1,
    RoofUVXZ(Quad[2]),
    RoofUVXZ(Apex2),
    RoofUVXZ(Apex1),   RefPt);

  EmitOutwardTriangleXYZ(Result, Quad[3], Quad[0], Apex2,
    RoofUVXZ(Quad[3]),
    RoofUVXZ(Quad[0]),
    RoofUVXZ(Apex2),   RefPt);

  Result.Valid := True;
end;

{
 BuildHipped — straight skeleton with 4-vertex fast path.
 }

class function TRoofBuilder.BuildHipped(const P: TRoofParams): TRoofGeometry;
var
  Skel: TStraightSkeleton;
  MaxSkelHeight: Single;
  N: Integer;
  ActualFootprint: TRoofVector3Array;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1068);{$ENDIF}
  Result := EmptyRoofGeometry;
  N := Length(P.Footprint);
  if N < 3 then Exit;

  { Fast path: 4-vertex footprint → direct OMBB-based generation,
    bypasses skeleton entirely. Handles 95%+ of real-world buildings
    (rectangular floor plans). Robust to OSM coordinate noise.}
  if N = 4 then
  begin
    Result := BuildHippedRect4(P);
    { OMBB-хип на СКОШЕННОМ 4-угольнике может положить конец конька
      вплотную к наклонному ребру — грань выходит вертикальной или чуть
      вниз (Базстроевская 20 в roof_debug: ny=-0.08). Такой результат не
      выпускаем: кольцо уходит общему скелетному пути ниже, который для
      выпуклого 4-угольника корректен. }
    if Result.Valid and RoofGeomOrientationOK(Result) then Exit;
    Result := EmptyRoofGeometry;
  end;

  { General path: straight skeleton for 5+ vertex convex polygons. }
  if not TryPrepareSkeletonRoof(P, Skel, ActualFootprint, MaxSkelHeight) then Exit;

  EmitSkeletonRoofFaces(Result, Skel, ActualFootprint,
    P.EaveY, P.RoofHeight, MaxSkelHeight, @HippedHeightFn);
  { Пост-валидация: несогласованный скелет (перевёрнутые грани, разные Y
    одного узла) не выпускаем — лучше честный flat-фолбэк, чем дыра+шпиль. }
  Result.Valid := (Result.TriangleCount > 0) and RoofGeomOrientationOK(Result);
end;

class function TRoofBuilder.BuildHalfHipped(const P: TRoofParams): TRoofGeometry;
var
  Skel: TStraightSkeleton;
  MaxSkelHeight: Single;
  N: Integer;
  ActualFootprint: TRoofVector3Array;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1069);{$ENDIF}
  Result := EmptyRoofGeometry;
  N := Length(P.Footprint);
  if N < 3 then Exit;

  if not TryPrepareSkeletonRoof(P, Skel, ActualFootprint, MaxSkelHeight) then
  begin
    Result := BuildGabled(P);
    Exit;
  end;

  EmitSkeletonRoofFaces(Result, Skel, ActualFootprint,
    P.EaveY, P.RoofHeight, MaxSkelHeight, @HalfHippedHeightFn);
  Result.Valid := (Result.TriangleCount > 0) and RoofGeomOrientationOK(Result);
end;

class function TRoofBuilder.BuildMansard(const P: TRoofParams): TRoofGeometry;
var
  Skel: TStraightSkeleton;
  MaxSkelHeight: Single;
  I, J, N: Integer;
  ActualFootprint: TRoofVector3Array;
  TopVerts: array of TVector3;
  TopVerts2D: array of TVector2;
  TopRoof: array of TVector3;
  TopFlat: array of Double;
  TopTris: TIntArray;
  Norm: TVector3;
  TopY: Single;
  EdgeA, EdgeB: TVector2;
  V: TSkeletonVertex;
  Dst, NDst: Single;
  Origi, StartIdx, EndIdx: Integer;
  TopVertsCount, TopVerts2DCount, FaceVertEst: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1070);{$ENDIF}
  Result := EmptyRoofGeometry;
  N := Length(P.Footprint);
  if N < 3 then Exit;

  if not TryPrepareSkeletonRoof(P, Skel, ActualFootprint, MaxSkelHeight) then Exit;

  { Emit slanted faces using mansard height function (steep below knee,
    plateau above). This automatically clamps top portion of roof to
    full height — the visual mansard shape.}
  EmitSkeletonRoofFaces(Result, Skel, ActualFootprint,
    P.EaveY, P.RoofHeight, MaxSkelHeight, @MansardHeightFn);

  { Add flat top: triangulate all skeleton vertices at or beyond the knee distance (shared plateau Y).
    TopVerts is pre-alloced to the total face-vertex count; TopVertsCount tracks the write position. }
  TopY := P.EaveY + P.RoofHeight;
  FaceVertEst := 0;
  for I := 0 to High(Skel.Faces) do
    Inc(FaceVertEst, Length(Skel.Faces[I].VertexIndices));
  SetLength(TopVerts, FaceVertEst);
  TopVertsCount := 0;

  for I := 0 to High(Skel.Faces) do
  begin
    if Length(Skel.Faces[I].VertexIndices) < 3 then Continue;
    Origi := Skel.Faces[I].OrigEdgeIndex;
    StartIdx := Origi;
    EndIdx := (Origi + 1) mod N;
    EdgeA := Vector2(ActualFootprint[StartIdx].X, ActualFootprint[StartIdx].Z);
    EdgeB := Vector2(ActualFootprint[EndIdx].X, ActualFootprint[EndIdx].Z);

    for J := 0 to High(Skel.Faces[I].VertexIndices) do
    begin
      V := Skel.Vertices[Skel.Faces[I].VertexIndices[J]];
      if V.T <= 1e-4 then Continue;
      Dst := Abs(SignedDstToLine(Vector2(V.X, V.Z), EdgeA, EdgeB));
      NDst := Dst / MaxSkelHeight;
      if NDst >= MANSARD_KNEE - 0.01 then
      begin
        { Vertex sits on or above knee — it's on plateau. Dedup later. }
        TopVerts[TopVertsCount] := Vector3(V.X, TopY, V.Z);
        Inc(TopVertsCount);
      end;
    end;
  end;
  SetLength(TopVerts, TopVertsCount);

  if TopVertsCount >= 3 then
  begin
    { Dedup: apex vertices may repeat across faces. Build a unique XZ set, pre-alloced to TopVertsCount. }
    SetLength(TopVerts2D, TopVertsCount);
    TopVerts2DCount := 0;
    for I := 0 to TopVertsCount - 1 do
    begin
      Dst := -1;
      for J := 0 to TopVerts2DCount - 1 do
        if (Abs(TopVerts2D[J].X - TopVerts[I].X) < 0.01) and
           (Abs(TopVerts2D[J].Y - TopVerts[I].Z) < 0.01) then
        begin
          Dst := 1;
          Break;
        end;
      if Dst < 0 then
      begin
        TopVerts2D[TopVerts2DCount] := Vector2(TopVerts[I].X, TopVerts[I].Z);
        Inc(TopVerts2DCount);
      end;
    end;
    SetLength(TopVerts2D, TopVerts2DCount);

    { Вершины плато собраны в порядке обхода граней скелета — как
      «полигон» это зигзаг, и earcut на нём давал мусорную
      перекрывающуюся триангуляцию плоской вершины. Плато выпукло →
      сортировка по полярному углу даёт корректный CCW-обход. }
    SortByPolarAngle(TopVerts2D, TopVerts2DCount);

    if Length(TopVerts2D) >= 3 then
    begin
      SetLength(TopFlat, Length(TopVerts2D) * 2);
      for I := 0 to High(TopVerts2D) do
      begin
        TopFlat[I * 2]     := TopVerts2D[I].X;
        TopFlat[I * 2 + 1] := TopVerts2D[I].Y;
      end;
      TopTris := TEarcutTriangulator.Triangulate(TopFlat, 2);
      if Length(TopTris) > 0 then
      begin
        SetLength(TopRoof, Length(TopVerts2D));
        for I := 0 to High(TopVerts2D) do
          TopRoof[I] := Vector3(TopVerts2D[I].X, TopY, TopVerts2D[I].Y);

        Norm := Vector3(0, 1, 0);
        EmitIndexedRoofXZ(Result, TopRoof, TopTris, Norm);
      end;
    end;
  end;

  Result.Valid := (Result.TriangleCount > 0) and RoofGeomOrientationOK(Result);
end;

function RoofClamp01(Value: Single): Single; inline;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(244);{$ENDIF}
  if Value < 0 then Result := 0
  else if Value > 1 then Result := 1
  else Result := Value;
end;

{ The next three functions match TOMBBProfileHeightFn (P, OMBB, Local).
  P is required by the signature but unused by these particular profiles. }
{$PUSH}{$WARN 5024 OFF}
function GabledProfileFrac(const P: TRoofParams;
  const OMBB: TFootprintOMBB; const Local: TVector2): Single;
var
  HalfWidth: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(245);{$ENDIF}
  HalfWidth := OMBB.Width * 0.5;
  if HalfWidth > 1e-6 then
    Result := 1.0 - Min(1.0, Abs(Local.Y) / HalfWidth)
  else
    Result := 1.0;
end;

function SaltboxProfileFrac(const P: TRoofParams;
  const OMBB: TFootprintOMBB; const Local: TVector2): Single;
var
  HalfWidth, RidgeOffset, Denom: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(246);{$ENDIF}
  HalfWidth := OMBB.Width * 0.5;
  RidgeOffset := HalfWidth * 0.3;
  if Local.Y < RidgeOffset then
    Denom := Abs(-HalfWidth - RidgeOffset)
  else
    Denom := Abs(+HalfWidth - RidgeOffset);

  if Denom > 1e-6 then
    Result := 1.0 - Min(1.0, Abs(Local.Y - RidgeOffset) / Denom)
  else
    Result := 1.0;
end;

function GambrelProfileFrac(const P: TRoofParams;
  const OMBB: TFootprintOMBB; const Local: TVector2): Single;
const
  KNEE_AT_FRAC = 0.4;
  KNEE_HEIGHT_FRAC = 0.4;
var
  HalfWidth, KneeAt, AbsV, Frac: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(247);{$ENDIF}
  HalfWidth := OMBB.Width * 0.5;
  KneeAt := HalfWidth * KNEE_AT_FRAC;
  AbsV := Abs(Local.Y);

  if (HalfWidth < 1e-6) or (KneeAt < 1e-6) then
  begin
    Result := 1.0;
    Exit;
  end;

  if AbsV >= KneeAt then
  begin
    Frac := (HalfWidth - AbsV) / (HalfWidth - KneeAt);
    Result := KNEE_HEIGHT_FRAC * Frac;
  end
  else
  begin
    Frac := (KneeAt - AbsV) / KneeAt;
    Result := KNEE_HEIGHT_FRAC + (1.0 - KNEE_HEIGHT_FRAC) * Frac;
  end;
end;
{$POP}

function BuildOMBBProfileRoof(const P: TRoofParams;
  HeightFn: TOMBBProfileHeightFn; const Knots: array of Single;
  AlongLength: Boolean = False): TRoofGeometry;
type
  TClipPolygon = array[0..7] of TVector3;
var
  OMBB: TFootprintOMBB;
  Axis: TVector2;
  Cuts, Heights: array of Single;
  Tris: TIntArray;
  Poly, Temp, Clipped: TClipPolygon;
  I, J, K, Band, Count, TempCount, ClipCount, WallCount, CutIndex: Integer;
  HalfSpan, QA, QB, T: Single;
  A, B, V, RefPoint: TVector3;

  function Across(const Point: TVector3): Single;
  begin
    Result := (Point.X-OMBB.Center.X)*Axis.X + (Point.Z-OMBB.Center.Y)*Axis.Y;
  end;

  function HeightAt(Q: Single): Single;
  var H: Integer; F: Single;
  begin
    H := 0;
    while (H < High(Cuts)-1) and (Q > Cuts[H+1]) do Inc(H);
    F := EnsureRange((Q-Cuts[H]) / Max(0.000001,Cuts[H+1]-Cuts[H]),0.0,1.0);
    Result := P.EaveY + Heights[H] + (Heights[H+1]-Heights[H])*F;
  end;

  procedure Clip(const Input: TClipPolygon; InputCount: Integer;
    out Output: TClipPolygon; out OutputCount: Integer;
    Boundary: Single; KeepGreater: Boolean);
  var L: Integer; Prev, Cur: TVector3; DP, DC, F: Single; IP, IC: Boolean;
  begin
    OutputCount := 0;
    if InputCount=0 then Exit;
    Prev := Input[InputCount-1]; DP := Across(Prev)-Boundary;
    if not KeepGreater then DP := -DP;
    for L := 0 to InputCount-1 do
    begin
      Cur := Input[L]; DC := Across(Cur)-Boundary;
      if not KeepGreater then DC := -DC;
      IP := DP>=0; IC := DC>=0;
      if IP <> IC then
      begin
        F := DP/(DP-DC);
        Output[OutputCount] := Prev+(Cur-Prev)*F; Inc(OutputCount);
      end;
      if IC then begin Output[OutputCount] := Cur; Inc(OutputCount); end;
      Prev := Cur; DP := DC;
    end;
  end;

  procedure WallPoint(const Point: TVector3);
  var Top: TVector3;
  begin
    Top := Point; Top.Y := HeightAt(Across(Point));
    Result.WallTop[WallCount] := Top; Inc(WallCount);
  end;

begin
  Result := EmptyRoofGeometry;
  if (Length(P.Footprint)<3) or (Length(Knots)<2) then Exit;
  OMBB := ComputeFootprintOMBB(P.Footprint);
  if (OMBB.Length<0.001) or (OMBB.Width<0.001) then Exit;
  if AlongLength then begin Axis:=OMBB.LongDir; HalfSpan:=OMBB.Length*0.5; end
  else begin Axis:=OMBB.ShortDir; HalfSpan:=OMBB.Width*0.5; end;
  SetLength(Cuts,Length(Knots)); SetLength(Heights,Length(Knots));
  for I := 0 to High(Knots) do
  begin
    Cuts[I] := Knots[I]*HalfSpan;
    if AlongLength then
      Heights[I] := P.RoofHeight*RoofClamp01(HeightFn(P,OMBB,Vector2(Cuts[I],0)))
    else
      Heights[I] := P.RoofHeight*RoofClamp01(HeightFn(P,OMBB,Vector2(0,Cuts[I])));
  end;
  Tris := TPolygonTriangulator.TriangulateXZ(P.Footprint);
  { Split each footprint triangle at every ridge/knee. Sampling only the
    original corners loses the ridge completely on a rectangular building.
    Clipping triangles also preserves concave footprints, unlike an OMBB lid. }
  I := 0;
  while I+2 < Length(Tris) do
  begin
    for J := 0 to 2 do Poly[J] := P.Footprint[Tris[I+J]];
    for Band := 0 to High(Cuts)-1 do
    begin
      Count := 3; Temp := Poly; TempCount := Count;
      if Band>0 then Clip(Poly,Count,Temp,TempCount,Cuts[Band],True);
      Clipped := Temp; ClipCount := TempCount;
      if Band<High(Cuts)-1 then Clip(Temp,TempCount,Clipped,ClipCount,Cuts[Band+1],False);
      if ClipCount<3 then Continue;
      for J := 0 to ClipCount-1 do Clipped[J].Y := HeightAt(Across(Clipped[J]));
      for J := 1 to ClipCount-2 do
      begin
        RefPoint := (Clipped[0]+Clipped[J]+Clipped[J+1])*(1/3);
        RefPoint.Y := P.EaveY-1;
        EmitOutwardTriangleXYZ(Result,Clipped[0],Clipped[J],Clipped[J+1],
          RoofUVXZ(Clipped[0]),RoofUVXZ(Clipped[J]),RoofUVXZ(Clipped[J+1]),RefPoint);
      end;
    end;
    Inc(I,3);
  end;
  { The same breakpoints define the top of the facade, so its gables meet
    the roof exactly. Emit them later into the WALL material, without windows. }
  SetLength(Result.WallTop,Length(P.Footprint)*Length(Knots)); WallCount:=0;
  for I := 0 to High(P.Footprint) do
  begin
    A:=P.Footprint[I]; B:=P.Footprint[(I+1) mod Length(P.Footprint)];
    QA:=Across(A); QB:=Across(B); WallPoint(A);
    if Abs(QB-QA)<0.000001 then Continue;
    for K:=1 to High(Cuts)-1 do
    begin
      if QB>QA then CutIndex:=K else CutIndex:=High(Cuts)-K;
      T:=(Cuts[CutIndex]-QA)/(QB-QA);
      if (T>0.000001) and (T<0.999999) then
      begin V:=A+(B-A)*T; WallPoint(V); end;
    end;
  end;
  SetLength(Result.WallTop,WallCount);
  Result.Valid := Result.TriangleCount>0;
end;

procedure ApplyRoofEndWalls(const Geom: TRoofGeometry; EaveY: Single; Target: TMesh);
var I,J,A0,B0,A1,B1: Integer; A,B,N: TVector3; U: Single; Reverse: Boolean;
begin
  if (Target=nil) or (Length(Geom.WallTop)<3) then Exit;
  Reverse := PolygonSignedAreaXZ(Geom.WallTop)>0;
  for I:=0 to High(Geom.WallTop) do
  begin
    J:=(I+1) mod Length(Geom.WallTop); A:=Geom.WallTop[I]; B:=Geom.WallTop[J];
    if Max(A.Y,B.Y)<=EaveY+0.00001 then Continue;
    N:=Vector3(B.X-A.X,0,B.Z-A.Z); U:=N.Length;
    if U<0.000001 then Continue;
    N:=TVector3.CrossProduct(N,Vector3(0,1,0))*(1/U);
    if Reverse then N:=-N;
    A0:=Target.AddVertex(Vector3(A.X,EaveY,A.Z),N,Vector2(0,0));
    B0:=Target.AddVertex(Vector3(B.X,EaveY,B.Z),N,Vector2(U/4,0));
    B1:=Target.AddVertex(B,N,Vector2(U/4,0));
    A1:=Target.AddVertex(A,N,Vector2(0,0));
    if B.Y>EaveY+0.00001 then
      if Reverse then Target.AddTriangle(A0,B1,B0) else Target.AddTriangle(A0,B0,B1);
    if A.Y>EaveY+0.00001 then
      if Reverse then Target.AddTriangle(A0,A1,B1) else Target.AddTriangle(A0,B1,A1);
  end;
end;

class function TRoofBuilder.BuildGabled(const P: TRoofParams): TRoofGeometry;
begin
  Result:=BuildOMBBProfileRoof(P,@GabledProfileFrac,[-1.0,0.0,1.0]);
end;

class function TRoofBuilder.BuildSaltbox(const P: TRoofParams): TRoofGeometry;
begin
  Result:=BuildOMBBProfileRoof(P,@SaltboxProfileFrac,[-1.0,0.3,1.0]);
end;

class function TRoofBuilder.BuildGambrel(const P: TRoofParams): TRoofGeometry;
begin
  Result:=BuildOMBBProfileRoof(P,@GambrelProfileFrac,[-1.0,-0.4,0.0,0.4,1.0]);
end;

function SkillionProfileFrac(const P: TRoofParams;
  const OMBB: TFootprintOMBB; const Local: TVector2): Single;
begin
  Result:=0.5+Local.X/Max(0.000001,OMBB.Length);
end;

class function TRoofBuilder.BuildSkillion(const P: TRoofParams): TRoofGeometry;
begin
  Result:=BuildOMBBProfileRoof(P,@SkillionProfileFrac,[-1.0,1.0],True);
end;

function RoundProfileFrac(const P: TRoofParams;
  const OMBB: TFootprintOMBB; const Local: TVector2): Single;
begin
  Result:=Sqrt(Max(0.0,1.0-Sqr(2*Local.Y/Max(0.000001,OMBB.Width))));
end;

class function TRoofBuilder.BuildRound(const P: TRoofParams): TRoofGeometry;
var Knots: array[0..24] of Single; I:Integer;
begin
  for I:=0 to High(Knots) do Knots[I]:=-Cos(Pi*I/High(Knots));
  Result:=BuildOMBBProfileRoof(P,@RoundProfileFrac,Knots);
end;

class function TRoofBuilder.BuildDome(const P: TRoofParams): TRoofGeometry;
const
  STACKS = 8;
  SLICES = 16;
var
  Centroid: TVector2;
  OMBB: TFootprintOMBB;
  Radius, Phi, Theta: Single;
  X, Y, Z: Single;
  Norm: TVector3;
  Pos: TVector3;
  Verts: TRoofIndexGrid;
  S, T: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1075);{$ENDIF}
  Result := EmptyRoofGeometry;
  if Length(P.Footprint) < 3 then Exit;

  Centroid := PolygonCentroidXZ(P.Footprint);
  OMBB := ComputeFootprintOMBB(P.Footprint);
  Radius := Min(OMBB.Length, OMBB.Width) * 0.5;
  if Radius < 1e-3 then Exit;

  { Tessellate hemisphere: phi = 0..pi/2, theta = 0..2pi. }
  InitRoofIndexGrid(Verts, STACKS + 1, SLICES + 1);

  for S := 0 to STACKS do
  begin
    Phi := (S / STACKS) * (Pi / 2);
    for T := 0 to SLICES do
    begin
      Theta := (T / SLICES) * 2 * Pi;
      X := Centroid.X + Radius * Cos(Phi) * Cos(Theta);
      Y := P.EaveY + P.RoofHeight * Sin(Phi);
      Z := Centroid.Y + Radius * Cos(Phi) * Sin(Theta);
      Pos := Vector3(X, Y, Z);

      Norm.X := X - Centroid.X;
      Norm.Y := Y - P.EaveY;
      Norm.Z := Z - Centroid.Y;
      Norm := VecNormalize(Norm);
      Verts[S][T] := AppendRoofVertex(Result, Pos, Norm,
        Vector2(T / SLICES, S / STACKS));
    end;
  end;

  EmitGridTriangles(Result, Verts, STACKS + 1, SLICES + 1);
  Result.Valid := True;
end;

class function TRoofBuilder.BuildOnion(const P: TRoofParams): TRoofGeometry;
const
  STACKS = 16;
  SLICES = 16;
var
  Centroid: TVector2;
  OMBB: TFootprintOMBB;
  BaseRadius: Single;
  S, T: Integer;
  Frac, Theta: Single;
  R, Y: Single;
  Pos, Norm: TVector3;
  Verts: TRoofIndexGrid;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1076);{$ENDIF}
  Result := EmptyRoofGeometry;
  if Length(P.Footprint) < 3 then Exit;

  Centroid := PolygonCentroidXZ(P.Footprint);
  OMBB := ComputeFootprintOMBB(P.Footprint);
  BaseRadius := Min(OMBB.Length, OMBB.Width) * 0.5;
  if BaseRadius < 1e-3 then Exit;

  InitRoofIndexGrid(Verts, STACKS + 1, SLICES + 1);

  for S := 0 to STACKS do
  begin
    Frac := S / STACKS;

    R := BaseRadius * (1.0 + 0.3 * Sin(Frac * Pi)) * (1.0 - Frac * Frac);
    Y := P.EaveY + P.RoofHeight * Frac;
    for T := 0 to SLICES do
    begin
      Theta := (T / SLICES) * 2 * Pi;
      Pos.X := Centroid.X + R * Cos(Theta);
      Pos.Y := Y;
      Pos.Z := Centroid.Y + R * Sin(Theta);
      Norm.X := Cos(Theta);
      Norm.Y := 0.5;
      Norm.Z := Sin(Theta);
      Norm := VecNormalize(Norm);
      Verts[S][T] := AppendRoofVertex(Result, Pos, Norm,
        Vector2(T / SLICES, Frac));
    end;
  end;

  EmitGridTriangles(Result, Verts, STACKS + 1, SLICES + 1);

  Result.Valid := True;
end;

class function TBuildingBuilder.ParseHeight(const Tags: TOSMTags; WayId: Int64;
  const Default: Single): Single;
var
  S: string;
  Levels: Integer;
  V: Double;
  JitterFrac: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1078);{$ENDIF}
  { 1) height / est_height tag }
  S := Trim(Tags.Get('height'));
  if S = '' then S := Trim(Tags.Get('est_height'));
  if S <> '' then
  begin
    V := ParseOSMMeters(S);
    if V > 0 then Exit(V);
  end;

  { 2) building:levels × 3 m }
  S := Trim(Tags.Get('building:levels'));
  if (S <> '') and TryStrToInt(S, Levels) and (Levels > 0) then
    Exit(Levels * WALL_LEVEL_HEIGHT_M);

  { 3) Default + deterministic jitter by WayId }
  JitterFrac := (HashInt64(WayId) mod 2001 - 1000) / 1000.0;
  Result := Default * (1.0 + JitterFrac * BUILDING_HEIGHT_JITTER);
end;

class function TBuildingBuilder.ParseMinHeight(const Tags: TOSMTags): Single;
var V: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1079);{$ENDIF}
  Result := 0;
  V := ParseOSMMeters(Trim(Tags.Get('min_height')));
  if V >= 0 then Result := V;
end;

class function TBuildingBuilder.ParseRoofHeight(const Tags: TOSMTags): Single;
var V: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1080);{$ENDIF}
  Result := DEFAULT_ROOF_HEIGHT_M;
  V := ParseOSMMeters(Trim(Tags.Get('roof:height')));
  if V > 0 then Result := V;
end;

class function TBuildingBuilder.PaletteIndex(const Tags: TOSMTags;
  WayId: Int64): Integer;
{ Untagged colour is SelectBuildingPalette (coords + storeys). This
  keeps the old WayId hash for any leftover caller. }
{$PUSH}{$WARN 5024 OFF}
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1081);{$ENDIF}
  Result := 5; { white — do not scatter untagged houses across brick/wood }
  if WayId = 0 then Exit;
end;
{$POP}

class procedure TWallsBuilder.ComputeWindowGrid(EdgeLenM, TargetWidthM: Single;
  out WindowCount: Integer; out ActualWidthM: Single);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1082);{$ENDIF}
  if EdgeLenM <= 0 then
  begin
    WindowCount := 1;
    ActualWidthM := TargetWidthM;
    Exit;
  end;
  WindowCount := Round(EdgeLenM / TargetWidthM);
  if WindowCount < 1 then WindowCount := 1;
  ActualWidthM := EdgeLenM / WindowCount;
end;

class function TWallsBuilder.AnalyzeEdgeSmoothness(
  const Footprint: array of TVector3; ThresholdDeg: Single): TBooleanArray;
var
  N, I: Integer;
  PrevDX, PrevDZ, NextDX, NextDZ: Single;
  L1, L2, Dot, AngleDeg: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1083);{$ENDIF}
  N := Length(Footprint);
  SetLength(Result, N);
  for I := 0 to N - 1 do
  begin
    PrevDX := Footprint[I].X - Footprint[(I + N - 1) mod N].X;
    PrevDZ := Footprint[I].Z - Footprint[(I + N - 1) mod N].Z;
    NextDX := Footprint[(I + 1) mod N].X - Footprint[I].X;
    NextDZ := Footprint[(I + 1) mod N].Z - Footprint[I].Z;
    L1 := Sqrt(PrevDX * PrevDX + PrevDZ * PrevDZ);
    L2 := Sqrt(NextDX * NextDX + NextDZ * NextDZ);
    if (L1 < 1e-6) or (L2 < 1e-6) then
    begin
      Result[I] := True;
      Continue;
    end;
    Dot := (PrevDX * NextDX + PrevDZ * NextDZ) / (L1 * L2);
    Dot := Max(-1, Min(1, Dot));
    AngleDeg := ArcCos(Dot) * 180 / Pi;     { 0 = collinear, 90 = right angle }
    Result[I] := AngleDeg < ThresholdDeg;
  end;
end;

class procedure TWallsBuilder.BuildWalls(const P: TWallParams; Target: TMesh);
var
  N, I, Next, V0, V1, V2, V3: Integer;
  Edge1, Edge2, FaceN, Up: TVector3;
  EdgeLen: Single;
  WallH: Single;
  WindowCount: Integer;
  ActualWindowW: Single;
  TilesU, TilesV: Single;
  FoundationTopV: Single;
  Smoothness: TBooleanArray;
  PrevFaceN: TVector3;
  NormA, NormB: TVector3;
  Floor, EavePoly: array of TVector3;
  SkirtY: Single;
  SkirtV0, SkirtV1, SkirtV2, SkirtV3: Integer;
  SkirtTilesV: Single;
  SkirtN: TVector3;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1084);{$ENDIF}
  N := Length(P.Footprint);
  if (N < 3) or (Target = nil) then Exit;

  WallH := P.EaveY - P.BaseY;
  if WallH <= 0 then Exit;

  { Pre-compute floor polygon (= footprint at BaseY) and eave polygon (= footprint at EaveY). }
  SetLength(Floor, N);
  SetLength(EavePoly, N);
  for I := 0 to N - 1 do
  begin
    Floor[I] := P.Footprint[I];     Floor[I].Y := P.BaseY;
    EavePoly[I] := P.Footprint[I];  EavePoly[I].Y := P.EaveY;
  end;

  Smoothness := AnalyzeEdgeSmoothness(P.Footprint);

  Up := Vector3(0, 1, 0);
  Up.Y := 1;     { suppress }

  { Pre-compute face normals for all edges (needed for smoothing). }
  PrevFaceN := Vector3(0, 0, 0);
  if PrevFaceN.X <> 0 then ;     { suppress }

  for I := 0 to N - 1 do
  begin
    Next := (I + 1) mod N;

    Edge1.X := Floor[Next].X - Floor[I].X;
    Edge1.Y := 0;
    Edge1.Z := Floor[Next].Z - Floor[I].Z;
    Edge2 := Vector3(0, 1, 0);
    { Outward normal of a vertical wall whose footprint is CCW-from-above
      in OSM3D coords (-X = east, +Z = north → negative shoelace area).
      With this orientation, Cross(Edge1, Up) points OUTWARD (away from
      the building interior). The opposite order Cross(Up, Edge1) would
      point inward and the lighting on the sun-facing side would be
      inverted — fixed bug, do not swap back. }
    FaceN := VecNormalize(VecCross(Edge1, Edge2));

    EdgeLen := Sqrt(Edge1.X * Edge1.X + Edge1.Z * Edge1.Z);
    if EdgeLen < 1e-6 then Continue;

    { Window grid: choose window width so a whole number of windows
      fits the edge. }
    if P.Levels > 0 then
    begin
      ComputeWindowGrid(EdgeLen, P.TargetWindowWM, WindowCount, ActualWindowW);
      TilesU := WindowCount;
      { V (vertical) — exactly P.Levels tiles, one per floor. }
      TilesV := P.Levels;
    end
    else
    begin
      { No building:levels — legacy style: 4 m tile. }
      TilesU := EdgeLen / 4.0;
      TilesV := WallH / 4.0;
    end;

    { Smoothing: if vertex I (start of this edge) is smooth, use the
      average of this edge's normal and the previous one; same for
      vertex Next. Otherwise keep the per-face normal unchanged. }
    NormA := FaceN;
    NormB := FaceN;

    if Smoothness[I] then
    begin
      { previous edge face normal (same Cross order as the main edge:
        Edge × Up — see comment above the main FaceN computation). }
      PrevFaceN.X := Floor[I].X - Floor[(I + N - 1) mod N].X;
      PrevFaceN.Y := 0;
      PrevFaceN.Z := Floor[I].Z - Floor[(I + N - 1) mod N].Z;
      PrevFaceN := VecNormalize(VecCross(PrevFaceN, Up));
      NormA.X := (FaceN.X + PrevFaceN.X) * 0.5;
      NormA.Y := (FaceN.Y + PrevFaceN.Y) * 0.5;
      NormA.Z := (FaceN.Z + PrevFaceN.Z) * 0.5;
      NormA := VecNormalize(NormA);
    end;

    if Smoothness[Next] then
    begin
      { next-next face normal (same Cross order as the main edge). }
      PrevFaceN.X := Floor[(Next + 1) mod N].X - Floor[Next].X;
      PrevFaceN.Y := 0;
      PrevFaceN.Z := Floor[(Next + 1) mod N].Z - Floor[Next].Z;
      PrevFaceN := VecNormalize(VecCross(PrevFaceN, Up));
      NormB.X := (FaceN.X + PrevFaceN.X) * 0.5;
      NormB.Y := (FaceN.Y + PrevFaceN.Y) * 0.5;
      NormB.Z := (FaceN.Z + PrevFaceN.Z) * 0.5;
      NormB := VecNormalize(NormB);
    end;

    if (Length(P.Architecture)>0) and
      EmitArchitecturalWall(P.Architecture,Floor[I],Floor[Next],FaceN,P.EaveY,Target) then Continue;
    if not P.NoWindows and EmitFacadeWall(P.FacadeLayouts,Floor[I],Floor[Next],FaceN,
      P.EaveY,TilesV,Target) then Continue;

    { 4 quad vertices: bottom-left (vertexA, floor), bottom-right
      (vertexB, floor), top-right (vertexB, eave), top-left (vertexA, eave).
      UV: U = 0..TilesU along the edge; V = 0..TilesV vertically. }
    if P.NoWindows then
    begin
      { Windowless facade: collapse V to the texture's V=0 row (the plain
        wall-colour band). With dV/dY = 0 the GPU stretches that single
        windowless row over the whole wall, so no panes appear. TilesU
        still drives U to keep the seam convention but is cosmetically
        irrelevant on a flat band. }
      V0 := Target.AddVertex(Floor[I],       NormA, MakeUV(0,      0));
      V1 := Target.AddVertex(Floor[Next],    NormB, MakeUV(TilesU, 0));
      V2 := Target.AddVertex(EavePoly[Next], NormB, MakeUV(TilesU, 0));
      V3 := Target.AddVertex(EavePoly[I],    NormA, MakeUV(0,      0));
    end
    else
    begin
      V0 := Target.AddVertex(Floor[I],     NormA, MakeUV(0,       0));
      V1 := Target.AddVertex(Floor[Next],  NormB, MakeUV(TilesU,  0));
      V2 := Target.AddVertex(EavePoly[Next], NormB, MakeUV(TilesU, TilesV));
      V3 := Target.AddVertex(EavePoly[I],    NormA, MakeUV(0,       TilesV));
    end;
    Target.AddQuad(V0, V1, V2, V3);
  end;

  { Foundation skirt: when FoundationBottomY < BaseY, extend each wall edge down one quad to cover
    the air gap on the downhill side. Plinth bottom = V=0, top = FoundationTopV (same vertical texel
    density as the wall, capped at FOUNDATION_BRICK_V so no window panes appear); U unchanged so the
    seam matches the wall above. }
  if P.FoundationBottomY < P.BaseY - 0.001 then
  begin
    { Plinth V-span = plinth height at the wall's vertical density, capped
      at the below-window brick band. Global (not per-edge). }
    if (P.Levels > 0) and (WallH > 1e-6) then
      FoundationTopV := (P.BaseY - P.FoundationBottomY) * P.Levels / WallH
    else
      FoundationTopV := (P.BaseY - P.FoundationBottomY) / 4.0;
    if FoundationTopV > FOUNDATION_BRICK_V then FoundationTopV := FOUNDATION_BRICK_V;
    if FoundationTopV < 0 then FoundationTopV := 0;

    for I := 0 to N - 1 do
    begin
      Next := (I + 1) mod N;
      Edge1.X := Floor[Next].X - Floor[I].X;
      Edge1.Y := 0;
      Edge1.Z := Floor[Next].Z - Floor[I].Z;
      EdgeLen := Sqrt(Edge1.X * Edge1.X + Edge1.Z * Edge1.Z);
      if EdgeLen < 1e-6 then Continue;
      { Outward normal — same convention as the main wall (Edge × Up
        for the OSM3D CCW-from-above footprint convention). }
      FaceN := VecNormalize(VecCross(Edge1, Vector3(0, 1, 0)));

      { Recompute TilesU exactly like the main wall so the foundation
        seam matches.  TilesU only affects U; UV.V spans [0..FoundationTopV]
        within the below-window brick band — no window panes appear. }
      if P.Levels > 0 then
      begin
        ComputeWindowGrid(EdgeLen, P.TargetWindowWM, WindowCount, ActualWindowW);
        TilesU := WindowCount;
      end
      else
        TilesU := EdgeLen / 4.0;

      { Four corners of the foundation quad on this edge.  Smoothing
        is intentionally skipped here — a flat-shaded foundation
        looks more like a real plinth than a smooth-blended one,
        and avoids cross-edge normal averaging that would tint the
        brick-band sampling. }
      { Bottom corners at V=0 (texture-bottom brick row); top corners at
        FoundationTopV so the plinth shows the below-window brick band. }
      V0 := Target.AddVertex(Vector3(Floor[I].X,    P.FoundationBottomY, Floor[I].Z),
                             FaceN, MakeUV(0,      0));
      V1 := Target.AddVertex(Vector3(Floor[Next].X, P.FoundationBottomY, Floor[Next].Z),
                             FaceN, MakeUV(TilesU, 0));
      V2 := Target.AddVertex(Floor[Next], FaceN, MakeUV(TilesU, FoundationTopV));
      V3 := Target.AddVertex(Floor[I],    FaceN, MakeUV(0,      FoundationTopV));
      Target.AddQuad(V0, V1, V2, V3);
    end;
  end;

  if P.Skirt.HasSkirt and (Length(P.Skirt.OuterEdge) = N) and (P.Skirt.DropMeters > 0) then
  begin
    SkirtY := P.EaveY - P.Skirt.DropMeters;
    SkirtTilesV := P.Skirt.DropMeters / 4.0;
    SkirtN := Vector3(0, -1, 0);     { skirt faces DOWN (underside of overhang) — overridden per segment }

    for I := 0 to N - 1 do
    begin
      Next := (I + 1) mod N;
      { skirt outward face — faces outward like a wall }
      Edge1.X := P.Skirt.OuterEdge[Next].X - P.Skirt.OuterEdge[I].X;
      Edge1.Y := 0;
      Edge1.Z := P.Skirt.OuterEdge[Next].Z - P.Skirt.OuterEdge[I].Z;
      { Same Cross order as the main wall — see comment at the main
        FaceN computation. Edge × Up yields an outward-pointing normal
        for a CCW-from-above footprint in OSM3D coords. }
      SkirtN := VecNormalize(VecCross(Edge1, Vector3(0, 1, 0)));

      EdgeLen := Sqrt(Edge1.X * Edge1.X + Edge1.Z * Edge1.Z);
      TilesU := EdgeLen / 4.0;

      { 4 sub-wall quad vertices: from the upper inner edge (at EaveY,
        at the wall face) to the lower outer edge (at EaveY-DropM, at
        the overhang tip). Vertical gap = DropM. Horizontal gap =
        OverhangM. This is a sloped quad. }
      SkirtV0 := Target.AddVertex(Vector3(P.Skirt.InnerEdge[I].X, P.EaveY, P.Skirt.InnerEdge[I].Z),
                                  SkirtN, MakeUV(0, 1));
      SkirtV1 := Target.AddVertex(Vector3(P.Skirt.InnerEdge[Next].X, P.EaveY, P.Skirt.InnerEdge[Next].Z),
                                  SkirtN, MakeUV(TilesU, 1));
      SkirtV2 := Target.AddVertex(Vector3(P.Skirt.OuterEdge[Next].X, SkirtY, P.Skirt.OuterEdge[Next].Z),
                                  SkirtN, MakeUV(TilesU, 1 - SkirtTilesV));
      SkirtV3 := Target.AddVertex(Vector3(P.Skirt.OuterEdge[I].X, SkirtY, P.Skirt.OuterEdge[I].Z),
                                  SkirtN, MakeUV(0, 1 - SkirtTilesV));
      Target.AddQuad(SkirtV0, SkirtV1, SkirtV2, SkirtV3);
    end;
  end;
end;

function RoofShapeName(Shape: TRoofShape): string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(249);{$ENDIF}
  case Shape of
    rsFlat:       Result := 'flat';
    rsPyramidal:  Result := 'pyramidal';
    rsSkillion:   Result := 'skillion';
    rsGabled:     Result := 'gabled';
    rsHipped:     Result := 'hipped';
    rsHalfHipped: Result := 'half-hipped';
    rsMansard:    Result := 'mansard';
    rsGambrel:    Result := 'gambrel';
    rsSaltbox:    Result := 'saltbox';
    rsOnion:      Result := 'onion';
    rsDome:       Result := 'dome';
    rsRound:      Result := 'round';
  else            Result := 'unknown';
  end;
end;

function BuildingAddressStr(const Tags: TOSMTags; Id: Int64): string;
var
  HN, St, Nm, City: string;
begin
  HN := Trim(Tags.Get('addr:housenumber'));
  St := Trim(Tags.Get('addr:street'));
  Nm := Trim(Tags.Get('name'));
  City := Trim(Tags.Get('addr:city'));
  if (St <> '') and (HN <> '') then
    Result := St + ', ' + HN
  else if HN <> '' then
    Result := 'house ' + HN
  else if Nm <> '' then
    Result := Nm
  else
    Result := 'building=' + Tags.GetLower('building');
  if City <> '' then Result := Result + ' (' + City + ')';
  Result := Result + ' [id=' + IntToStr(Id) + ']';
end;

function ParseLevels(const Tags: TOSMTags): Integer;
var S: string; V: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(250);{$ENDIF}
  Result := 0;
  S := Trim(Tags.Get('building:levels'));
  if S = '' then Exit;
  if TryStrToInt(S, V) and (V > 0) then Result := V;
end;

{ Decide whether the facade gets windows or a blank band. Precedence:
    1) explicit window=/windows= (no->False, yes->True)
    2) man_made tanks/chimneys/steles and bridge supports -> False
    3) a blacklist of building=<type> values -> False
    4) otherwise True.
  Sets TWallParams.NoWindows in Build. }
function BuildingHasWindows(const Tags: TOSMTags): Boolean;
const
  NoWindowBuildings: array[0..18] of string = (
    'garage', 'garages', 'greenhouse', 'storage_tank', 'bunker',
    'silo', 'stadium', 'ship', 'castle', 'service', 'digester',
    'water_tower', 'shed', 'ger', 'barn', 'slurry_tank',
    'container', 'carport', 'industrial');
var
  W, MM, B: string;
  I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1445);{$ENDIF}
  { Explicit window / windows tag wins over everything. }
  W := Tags.GetLower('window');
  if W = '' then W := Tags.GetLower('windows');
  if W = 'no'  then Exit(False);
  if W = 'yes' then Exit(True);

  { Structures that never carry windows. }
  MM := Tags.GetLower('man_made');
  if (Tags.GetLower('bridge:support') <> '') or
     (MM = 'storage_tank') or (MM = 'chimney') or (MM = 'stele') then
    Exit(False);

  { building=<type> blacklist. }
  B := Tags.GetLower('building');
  for I := 0 to High(NoWindowBuildings) do
    if B = NoWindowBuildings[I] then Exit(False);

  Result := True;
end;

function ParseFacadeMaterialPalette(const Tags: TOSMTags): Integer;
var
  Mat: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(251);{$ENDIF}
  Result := -1;     { -1 = no material tag, fall through to colour or hash }
  Mat := Tags.GetLower('building:material');
  if Mat = '' then Exit;

  if (Mat = 'brick') then Result := 4
  else if (Mat = 'cement_block') or (Mat = 'block') or
          (Mat = 'glass') or (Mat = 'mirror') then Result := 3
  else if (Mat = 'wood') then Result := 1
  else if (Mat = 'plaster') or (Mat = 'plastered') or
          (Mat = 'concrete') or (Mat = 'hard') then Result := 2
  else
    Result := -1;
end;

{ Decode a 24-bit packed integer into normalised RGB components. }
procedure HexToRGB(H: Integer; out R, G, B: Single);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(252);{$ENDIF}
  R := ((H shr 16) and $FF) / 255.0;
  G := ((H shr 8 ) and $FF) / 255.0;
  B := ( H         and $FF) / 255.0;
end;

{ Parse hex (#RRGGBB / #RGB) or named OSM building:colour value.
  Returns True if successfully parsed, sets R, G, B in [0..1].}
function ParseBuildingColour(const Tags: TOSMTags;
  out R, G, B: Single): Boolean;
const
  { Subset of streets-gl colors.json — most common OSM colour names. }
  NamedColors: array[0..23] of record N: string; H: Integer; end = (
    (N: 'white';     H: $FFFFFF), (N: 'black';     H: $000000),
    (N: 'red';       H: $FF0000), (N: 'green';     H: $008000),
    (N: 'blue';      H: $0000FF), (N: 'yellow';    H: $FFFF00),
    (N: 'orange';    H: $FFA500), (N: 'brown';     H: $A52A2A),
    (N: 'grey';      H: $808080), (N: 'gray';      H: $808080),
    (N: 'silver';    H: $C0C0C0), (N: 'beige';     H: $F5F5DC),
    (N: 'cream';     H: $FFFDD0), (N: 'tan';       H: $D2B48C),
    (N: 'pink';      H: $FFC0CB), (N: 'purple';    H: $800080),
    (N: 'cyan';      H: $00FFFF), (N: 'turquoise'; H: $40E0D0),
    (N: 'maroon';    H: $800000), (N: 'darkgreen'; H: $006400),
    (N: 'olive';     H: $808000), (N: 'salmon';    H: $FA8072),
    (N: 'ivory';     H: $FFFFF0), (N: 'lightgrey'; H: $D3D3D3)
  );
var
  S: string;
  I, H: Integer;
  Code: Integer;
  Rv, Gv, Bv: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(253);{$ENDIF}
  Result := False;
  S := Trim(Tags.Get('building:colour'));
  if S = '' then S := Trim(Tags.Get('building:color'));
  if S = '' then Exit;
  S := NormalizeTagValue(S);

  if (Length(S) > 0) and (S[1] = '#') then
  begin
    if Length(S) = 7 then
    begin
      Val('$' + Copy(S, 2, 6), H, Code);
      if Code = 0 then
      begin
        HexToRGB(H, R, G, B);
        Result := True;
      end;
    end
    else if Length(S) = 4 then
    begin
      Val('$' + S[2] + S[2], Rv, Code); if Code <> 0 then Exit;
      Val('$' + S[3] + S[3], Gv, Code); if Code <> 0 then Exit;
      Val('$' + S[4] + S[4], Bv, Code); if Code <> 0 then Exit;
      R := Rv / 255.0;
      G := Gv / 255.0;
      B := Bv / 255.0;
      Result := True;
    end;
    Exit;
  end;

  for I := 0 to High(NamedColors) do
    if NamedColors[I].N = S then
    begin
      HexToRGB(NamedColors[I].H, R, G, B);
      Result := True;
      Exit;
    end;
end;

{ Given a RGB colour, find palette index whose DiffuseColor is closest
  among the OSM-tagged slots 0..5 (not the hash tints 6..9). }
function NearestWallPaletteIndex(R, G, B: Single): Integer;
var
  I: Integer;
  D, Best: Single;
  DR, DG, DB: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(254);{$ENDIF}
  Result := 0;
  Best := MaxSingle;
  for I := 0 to 5 do
  begin
    DR := BUILDING_WALL_BASE[I].X - R;
    DG := BUILDING_WALL_BASE[I].Y - G;
    DB := BUILDING_WALL_BASE[I].Z - B;
    D := DR * DR + DG * DG + DB * DB;
    if D < Best then
    begin
      Best := D;
      Result := I;
    end;
  end;
end;

{ True for an OSM cooling tower: man_made=tower with tower:type=cooling.
  Such a way is drawn as a concrete cone+cylinder shell (no windows, open
  top) and is admitted to the building pipeline even without a building=*
  tag - see the selection filter in TBuildingBuilderExt.BuildAll. }
function IsCoolingTower(const Tags: TOSMTags): Boolean; inline;
begin
  Result := (Tags.GetLower('man_made') = 'tower') and
            (Tags.GetLower('tower:type') = 'cooling');
end;

{ True for an OSM chimney: man_made=chimney (a standalone NODE or a closed way).
  Drawn as a concrete tapered tube (no windows, open top). Admitted to the
  building pipeline like a cooling tower; standalone chimney NODES are built by
  a dedicated node pass in TBuildingBuilderExt.BuildAll. }
function IsChimney(const Tags: TOSMTags): Boolean; inline;
begin
  Result := Tags.GetLower('man_made') = 'chimney';
end;

{ True for a generic OSM tower (man_made=tower) that is NOT a cooling tower
  (cooling towers keep their own hyperbolic EmitCoolingTowerShell path).
  Includes communication towers (tower:type=communication). Built as a concrete
  tube, exactly like a chimney; standalone tower NODES via the node pass. }
function IsTower(const Tags: TOSMTags): Boolean; inline;
begin
  Result := (Tags.GetLower('man_made') = 'tower') and
            (Tags.GetLower('tower:type') <> 'cooling');
end;

{ Chimney base radius (m): from diameter/2 or width/2, else a default. }
function ParseChimneyRadiusM(const Tags: TOSMTags): Single;
var V: Single;
begin
  Result := DEFAULT_CHIMNEY_RADIUS_M;
  V := ParseOSMMeters(Trim(Tags.Get('diameter')));
  if V > 0 then Exit(V * 0.5);
  V := ParseOSMMeters(Trim(Tags.Get('width')));
  if V > 0 then Exit(V * 0.5);
end;

{ Streets-gl style palette selection for a building:
    1) `building:material` tag → fixed palette index (deterministic).
    2) Otherwise: `building:colour` tag → nearest palette color.
    3) Otherwise: hash of footprint coords. Tall (>6 floors) always white.
       Of the rest, 30% white, 70% architectural blue/green/rose/yellow. }
function HashBuildingCoords(const Verts: array of TVector3): LongWord;
var
  I, N: Integer;
  Cx, Cz: Double;
  Qx, Qz: Int64;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(255);{$ENDIF}
  N := Length(Verts);
  Cx := 0; Cz := 0;
  for I := 0 to N - 1 do
  begin
    Cx := Cx + Verts[I].X;
    Cz := Cz + Verts[I].Z;
  end;
  if N > 0 then
  begin
    Cx := Cx / N;
    Cz := Cz / N;
  end;
  Qx := Round(Cx);
  Qz := Round(Cz);
  Result := HashInt64(Qx xor (Qz * Int64(73856093)) xor (Qx * Int64(19349663)));
end;

function SelectUntaggedFacadePalette(ALevels: Integer; ACoordHash: LongWord): Integer;
begin
  { High-rises stay white plaster. }
  if ALevels > 6 then
    Exit(5);
  { 30% of low houses stay white; the rest pick one of 4 architectural tints. }
  if (ACoordHash mod 10) < 3 then
    Result := 5
  else
    Result := 6 + Integer((ACoordHash div 10) mod 4);
end;

function SelectBuildingPalette(const Tags: TOSMTags; WayId: Int64;
  ALevels: Integer; ACoordHash: LongWord): Integer;
var
  R, G, B: Single;
  Mat: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(255);{$ENDIF}
  if IsCoolingTower(Tags) then Exit(2);   { concrete shell, no windows }
  if IsChimney(Tags)     then Exit(2);   { concrete tube, no windows }
  if IsTower(Tags)       then Exit(2);   { concrete tube, no windows }
  Mat := ParseFacadeMaterialPalette(Tags);
  if Mat >= 0 then
  begin
    Result := Mat;
    Exit;
  end;
  if ParseBuildingColour(Tags, R, G, B) then
  begin
    Result := NearestWallPaletteIndex(R, G, B);
    Exit;
  end;
  Result := SelectUntaggedFacadePalette(ALevels, ACoordHash);
  if WayId = 0 then Exit;
end;

function ShapeUsesSkeleton(Shape: TRoofShape): Boolean; inline;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(256);{$ENDIF}
  Result := Shape in [rsHipped, rsMansard, rsHalfHipped];
end;

function EstimateLevelsFromArea(Area: Single): Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(257);{$ENDIF}
  { Two and five storeys dominate this fallback; 3/4 are narrow transitions.
    Area is aspect-capped: a 12 x 50 m residential block is only 288 m2,
    so the five-storey threshold must fit that effective area, not 600 m2. }
  if Area <= 160 then
    Result := 1
  else if Area <= 240 then
    Result := 2
  else if Area <= 260 then
    Result := 3
  else if Area <= 280 then
    Result := 4
  else
    Result := 5;
end;

const
  { A footprint wider than this aspect (long/short) is treated as if it were
    only LEVELS_MAX_ASPECT:1 for the purpose of storey estimation — the long
    dimension beyond that adds floor plate, not height. 2:1 ≈ the edge of
    ordinary building proportions; beyond it (halls, warehouses, walls) the
    real area over-predicts height. }
  LEVELS_MAX_ASPECT = 2.0;

function EffectiveAreaForLevels(const Footprint: array of TVector3): Single;
var
  O: TFootprintOMBB;
  W, L, EffL: Single;
begin
  O := ComputeFootprintOMBB(Footprint);
  { Don't assume which OMBB field is larger — take min/max explicitly. }
  if O.Width <= O.Length then
  begin W := O.Width;  L := O.Length; end
  else
  begin W := O.Length; L := O.Width;  end;
  if (W <= 0) or (L <= 0) then
  begin
    { OMBB degenerate — fall back to the real signed area. }
    Result := Abs(PolygonSignedAreaXZ(Footprint));
    Exit;
  end;
  { Cap the long side at LEVELS_MAX_ASPECT × width: normal-proportion area.
    EffL ≤ L always ⇒ Result ≤ W·L (real bbox area) ⇒ never raises levels. }
  EffL := L;
  if EffL > W * LEVELS_MAX_ASPECT then EffL := W * LEVELS_MAX_ASPECT;
  Result := W * EffL;
end;

function EstimateRoofShapeFromArea(Area: Single): TRoofShape;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(258);{$ENDIF}
  if (Area > 80) and (Area <= 800) then
    Result := rsHipped
  else
    Result := rsFlat;
end;

function RoofShapeIsTagged(const Tags: TOSMTags): Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(259);{$ENDIF}
  Result := Trim(Tags.Get('roof:shape')) <> '';
end;

{ Extreme terrain mesh Y values inside (or on the boundary of) the
 building footprint — produces both MAX (used to lift the foundation
 TOP above terrain so walls do not get buried) and MIN (used to
 extend a foundation skirt DOWN to terrain so walls do not float
 in air on the downhill side of a slope).

 Why this exists
 Walls are built as horizontal floor+eave bands at a single BaseY.
 If the rendered terrain surface anywhere inside (or on the boundary
 of) the footprint pokes above BaseY, the wall is partially or fully
 buried. Conversely, if terrain drops below BaseY on the downhill
 side, the wall has nothing to stand on and hangs in mid-air. We
 therefore must know the true MAX and MIN of the terrain mesh Y over
 the closed footprint region: MAX feeds BaseY, MIN feeds the
 bottom of a downward-extended foundation skirt.

 Why naive corner sampling is not enough
 The terrain is piecewise-linear on a regular triangulation: every
 cell is split along the NW→SE diagonal into two triangles, each
 linear in (X, Z). Extremes of a piecewise-linear surface over a
 polygon can only be achieved at:

 (a) a polygon corner,
 (b) a triangulation grid node inside the polygon,
 (c) a point on the polygon BOUNDARY where a polygon edge crosses
 a triangulation edge (the cell diagonal or a cell border).

 Caller already feeds us the per-corner extremes via CornerMin/Max
 (case a). Pass 1 below covers (b) by iterating grid nodes inside
 the bbox. Pass 2 covers (c) by walking polygon edges at 0.25 m.

 Inputs:
 Verts — footprint polygon, XZ used, Y ignored. Winding
 does NOT matter.
 CornerMin/Max — seeds = min/max of the per-corner terrain
 samples computed by the caller.
 Projection — used to unproject (X, Z) → (lat, lon) for the
 fallback bilinear sampler.
 TerrainSampler — preferred path. When nil, only the edge-
 sampling pass runs against the heightmap.
 HM — bilinear fallback when TerrainSampler is nil.

 Outputs:
 MinY, MaxY — true extremes over the footprint, in metres. }
procedure InteriorTerrainExtremes(const Verts: array of TVector3;
  CornerMin, CornerMax: Single;
  Projection: TLocalProjection;
  TerrainSampler: TTerrainSampler; HM: THeightmap;
  out MinY, MaxY: Single);
const
  EDGE_SAMPLE_STEP_M = 0.25;
var
  N, I, J: Integer;
  MinX, MaxX, MinZ, MaxZ: Single;
  P: TVector3;
  Y: Single;

  X0, Z0, X1, Z1: Single;
  SpacingX, SpacingZ: Single;
  IxMin, IxMax, IzMin, IzMax: Integer;
  IxLo, IxHi, IzLo, IzHi: Integer;
  IX, IZ: Integer;
  NodeX, NodeZ: Single;

  Dx, Dz, EdgeLen: Single;
  Steps, K: Integer;
  T, X, Z: Single;

  function SampleY(WX, WZ: Single; out OutY: Single): Boolean;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(261);{$ENDIF}
    Result := False;
    if TerrainSampler <> nil then
    begin
      OutY := TerrainSampler.SampleAtXZ(Projection, WX, WZ);
      Result := True;
    end
    else if (HM <> nil) and (Projection <> nil) then
    begin
      OutY := THeightmapSampler.SampleBilinear(HM, Projection.Unproject(WX, WZ));
      Result := True;
    end;
  end;

  procedure Update(YVal: Single); inline;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(262);{$ENDIF}
    if YVal > MaxY then MaxY := YVal;
    if YVal < MinY then MinY := YVal;
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(260);{$ENDIF}
  MinY := CornerMin;
  MaxY := CornerMax;
  N := Length(Verts);
  if N < 3 then Exit;

  { Footprint bbox. }
  MinX := Verts[0].X; MaxX := MinX;
  MinZ := Verts[0].Z; MaxZ := MinZ;
  for I := 1 to N - 1 do
  begin
    if Verts[I].X < MinX then MinX := Verts[I].X
    else if Verts[I].X > MaxX then MaxX := Verts[I].X;
    if Verts[I].Z < MinZ then MinZ := Verts[I].Z
    else if Verts[I].Z > MaxZ then MaxZ := Verts[I].Z;
  end;
  if (MaxX - MinX < 0.001) or (MaxZ - MinZ < 0.001) then Exit;

  if (TerrainSampler <> nil) and
     (TerrainSampler.GridX >= 2) and (TerrainSampler.GridZ >= 2) and
     TerrainSampler.NodePositionXZ(0, 0, X0, Z0) and
     TerrainSampler.NodePositionXZ(TerrainSampler.GridX - 1,
                                   TerrainSampler.GridZ - 1, X1, Z1) then
  begin
    SpacingX := (X1 - X0) / (TerrainSampler.GridX - 1);
    SpacingZ := (Z1 - Z0) / (TerrainSampler.GridZ - 1);
    if (Abs(SpacingX) > 0.001) and (Abs(SpacingZ) > 0.001) then
    begin
      if SpacingX > 0 then
      begin
        IxLo := Floor((MinX - X0) / SpacingX) - 1;
        IxHi := Floor((MaxX - X0) / SpacingX) + 1;
      end
      else
      begin
        IxLo := Floor((MaxX - X0) / SpacingX) - 1;
        IxHi := Floor((MinX - X0) / SpacingX) + 1;
      end;
      if SpacingZ > 0 then
      begin
        IzLo := Floor((MinZ - Z0) / SpacingZ) - 1;
        IzHi := Floor((MaxZ - Z0) / SpacingZ) + 1;
      end
      else
      begin
        IzLo := Floor((MaxZ - Z0) / SpacingZ) - 1;
        IzHi := Floor((MinZ - Z0) / SpacingZ) + 1;
      end;
      IxMin := IxLo;  if IxMin < 0 then IxMin := 0;
      IxMax := IxHi;  if IxMax >= TerrainSampler.GridX then IxMax := TerrainSampler.GridX - 1;
      IzMin := IzLo;  if IzMin < 0 then IzMin := 0;
      IzMax := IzHi;  if IzMax >= TerrainSampler.GridZ then IzMax := TerrainSampler.GridZ - 1;

      P.Y := 0;
      for IZ := IzMin to IzMax do
        for IX := IxMin to IxMax do
          if TerrainSampler.NodePositionXZ(IX, IZ, NodeX, NodeZ) then
          begin
            if (NodeX < MinX) or (NodeX > MaxX) then Continue;
            if (NodeZ < MinZ) or (NodeZ > MaxZ) then Continue;
            P.X := NodeX;
            P.Z := NodeZ;
            if not PointInPolygonXZ(P, Verts) then Continue;
            Y := TerrainSampler.NodeHeight(IX, IZ);
            Update(Y);
          end;
    end;
  end;

  if (TerrainSampler = nil) and ((HM = nil) or (Projection = nil)) then Exit;

  for I := 0 to N - 1 do
  begin
    J := (I + 1) mod N;
    Dx := Verts[J].X - Verts[I].X;
    Dz := Verts[J].Z - Verts[I].Z;
    EdgeLen := Sqrt(Dx * Dx + Dz * Dz);
    if EdgeLen < EDGE_SAMPLE_STEP_M then Continue;
    Steps := Ceil(EdgeLen / EDGE_SAMPLE_STEP_M);
    if Steps < 2 then Steps := 2;
    for K := 1 to Steps - 1 do
    begin
      T := K / Steps;
      X := Verts[I].X + T * Dx;
      Z := Verts[I].Z + T * Dz;
      if SampleY(X, Z, Y) then Update(Y);
    end;
  end;
end;

{ Cooling tower (man_made=tower + tower:type=cooling) - a concrete shell.
  The OSM footprint (usually a decagon) is tapered around its centroid: a
  CONE over the lower 2/3 of the height, narrowing from the full footprint at
  ground level to a throat, then a CYLINDER of throat radius for the upper
  1/3. Open top (no roof), no windows.

  Per-vertex normals are the outward radial direction (with an upward tilt on
  the cone band) so the faceted polygon shades as a smooth round shell;
  TBuildingBuilderExt.BuildAll runs MakeWindingMatchNormals afterwards, which
  fixes face winding from those normals - so the AddQuad order here does not
  matter. UV.V is pinned to 0 (the plain, windowless band of the concrete
  facade), exactly as the windowless-wall path in TWallsBuilder.BuildWalls. }
procedure EmitCoolingTowerShell(const Verts2D: array of TVector3;
  GroundY, FoundationBottomY, TotalHeight: Single; Target: TMesh);
const
  ConeFrac = 2.0 / 3.0;   { lower 2/3 = cone, upper 1/3 = cylinder }
  ThroatS  = 0.62;        { throat radius / base radius }
var
  N, I: Integer;
  C: TVector2;
  cx, cz: Single;
  ThroatY, TopY, HCone, R0: Single;
  DirX, DirZ: array of Single;   { centroid -> vertex offset (X,Z) }
  RadX, RadZ: array of Single;   { unit outward radial per vertex }
  ConeUp:     array of Single;   { vertical normal component on the cone }

  function RingPos(Idx: Integer; Y, S: Single): TVector3;
  begin
    Result.X := cx + DirX[Idx] * S;
    Result.Y := Y;
    Result.Z := cz + DirZ[Idx] * S;
  end;

  function ConeNormal(Idx: Integer): TVector3;
  begin
    Result := VecNormalize(Vector3(RadX[Idx], ConeUp[Idx], RadZ[Idx]));
  end;

  function HorizNormal(Idx: Integer): TVector3;
  begin
    Result := VecNormalize(Vector3(RadX[Idx], 0, RadZ[Idx]));
  end;

  procedure EmitBand(YB, SB, YT, ST: Single; Cone: Boolean);
  var
    I, Nx, V0, V1, V2, V3: Integer;
    NA, NB: TVector3;
    PB0, PB1, PT0, PT1: TVector3;
    U1: Single;
  begin
    for I := 0 to N - 1 do
    begin
      Nx := (I + 1) mod N;
      PB0 := RingPos(I,  YB, SB);
      PB1 := RingPos(Nx, YB, SB);
      PT0 := RingPos(I,  YT, ST);
      PT1 := RingPos(Nx, YT, ST);
      if Cone then
      begin NA := ConeNormal(I);  NB := ConeNormal(Nx);  end
      else
      begin NA := HorizNormal(I); NB := HorizNormal(Nx); end;
      { U ~ one texture tile per 4 m of circumference; V=0 = plain band. }
      U1 := Sqrt(Sqr(PB1.X - PB0.X) + Sqr(PB1.Z - PB0.Z)) / 4.0;
      V0 := Target.AddVertex(PB0, NA, MakeUV(0,  0));
      V1 := Target.AddVertex(PB1, NB, MakeUV(U1, 0));
      V2 := Target.AddVertex(PT1, NB, MakeUV(U1, 0));
      V3 := Target.AddVertex(PT0, NA, MakeUV(0,  0));
      Target.AddQuad(V0, V1, V2, V3);
    end;
  end;

begin
  N := Length(Verts2D);
  if (N < 3) or (Target = nil) or (TotalHeight <= 0) then Exit;

  C := PolygonCentroidXZ(Verts2D);
  cx := C.X;
  cz := C.Y;

  SetLength(DirX, N);  SetLength(DirZ, N);
  SetLength(RadX, N);  SetLength(RadZ, N);
  SetLength(ConeUp, N);

  ThroatY := GroundY + TotalHeight * ConeFrac;
  TopY    := GroundY + TotalHeight;
  HCone   := TotalHeight * ConeFrac;
  if HCone < 1e-3 then HCone := 1e-3;

  for I := 0 to N - 1 do
  begin
    DirX[I] := Verts2D[I].X - cx;
    DirZ[I] := Verts2D[I].Z - cz;
    R0 := Sqrt(Sqr(DirX[I]) + Sqr(DirZ[I]));
    if R0 > 1e-6 then
    begin
      RadX[I] := DirX[I] / R0;
      RadZ[I] := DirZ[I] / R0;
    end
    else
    begin
      RadX[I] := 1.0;   { degenerate vertex on the axis - any outward dir }
      RadZ[I] := 0.0;
    end;
    { cone outward-normal up-component = -dr/dy = R0*(1-ThroatS)/HCone > 0. }
    ConeUp[I] := R0 * (1.0 - ThroatS) / HCone;
  end;

  { Skirt: vertical band from FoundationBottomY up to GroundY at full radius,
    closing the air gap on the downhill side of sloped ground. }
  if FoundationBottomY < GroundY - 0.001 then
    EmitBand(FoundationBottomY, 1.0, GroundY, 1.0, False);

  { Cone - full footprint at the ground tapering to the throat at 2/3 H. }
  EmitBand(GroundY, 1.0, ThroatY, ThroatS, True);

  { Cylinder - constant throat radius for the upper 1/3. Open top. }
  EmitBand(ThroatY, ThroatS, TopY, ThroatS, False);
end;

{ Chimney (man_made=chimney) - a concrete tapered tube. Footprint (a generated
  circle for a node, or the polygon for a way) tapers gently from the full base
  radius to TopS at the top over the FULL height. Open top, no windows. Same
  faceted-round shading as EmitCoolingTowerShell (radial normals with an upward
  tilt on the taper); BuildAll runs MakeWindingMatchNormals afterwards. }
procedure EmitChimneyShell(const Verts2D: array of TVector3;
  GroundY, FoundationBottomY, TotalHeight: Single; Target: TMesh);
const
  TopS = 0.72;            { top radius / base radius - gentle chimney taper }
var
  N, I: Integer;
  C: TVector2;
  cx, cz, TopY, HFull, R0: Single;
  DirX, DirZ: array of Single;
  RadX, RadZ: array of Single;
  ConeUp:     array of Single;

  function RingPos(Idx: Integer; Y, S: Single): TVector3;
  begin
    Result.X := cx + DirX[Idx] * S;
    Result.Y := Y;
    Result.Z := cz + DirZ[Idx] * S;
  end;

  function ConeNormal(Idx: Integer): TVector3;
  begin
    Result := VecNormalize(Vector3(RadX[Idx], ConeUp[Idx], RadZ[Idx]));
  end;

  function HorizNormal(Idx: Integer): TVector3;
  begin
    Result := VecNormalize(Vector3(RadX[Idx], 0, RadZ[Idx]));
  end;

  procedure EmitBand(YB, SB, YT, ST: Single; Cone: Boolean);
  var
    I, Nx, V0, V1, V2, V3: Integer;
    NA, NB: TVector3;
    PB0, PB1, PT0, PT1: TVector3;
    U1: Single;
  begin
    for I := 0 to N - 1 do
    begin
      Nx := (I + 1) mod N;
      PB0 := RingPos(I,  YB, SB);
      PB1 := RingPos(Nx, YB, SB);
      PT0 := RingPos(I,  YT, ST);
      PT1 := RingPos(Nx, YT, ST);
      if Cone then
      begin NA := ConeNormal(I);  NB := ConeNormal(Nx);  end
      else
      begin NA := HorizNormal(I); NB := HorizNormal(Nx); end;
      U1 := Sqrt(Sqr(PB1.X - PB0.X) + Sqr(PB1.Z - PB0.Z)) / 4.0;
      V0 := Target.AddVertex(PB0, NA, MakeUV(0,  0));
      V1 := Target.AddVertex(PB1, NB, MakeUV(U1, 0));
      V2 := Target.AddVertex(PT1, NB, MakeUV(U1, 0));
      V3 := Target.AddVertex(PT0, NA, MakeUV(0,  0));
      Target.AddQuad(V0, V1, V2, V3);
    end;
  end;

begin
  N := Length(Verts2D);
  if (N < 3) or (Target = nil) or (TotalHeight <= 0) then Exit;

  C := PolygonCentroidXZ(Verts2D);
  cx := C.X;  cz := C.Y;

  SetLength(DirX, N);  SetLength(DirZ, N);
  SetLength(RadX, N);  SetLength(RadZ, N);  SetLength(ConeUp, N);

  HFull := TotalHeight;  if HFull < 1e-3 then HFull := 1e-3;
  TopY  := GroundY + TotalHeight;

  for I := 0 to N - 1 do
  begin
    DirX[I] := Verts2D[I].X - cx;
    DirZ[I] := Verts2D[I].Z - cz;
    R0 := Sqrt(Sqr(DirX[I]) + Sqr(DirZ[I]));
    if R0 > 1e-6 then
    begin RadX[I] := DirX[I] / R0;  RadZ[I] := DirZ[I] / R0;  end
    else
    begin RadX[I] := 1.0;           RadZ[I] := 0.0;           end;
    { taper outward-normal up-component = -dr/dy = R0*(1-TopS)/HFull. }
    ConeUp[I] := R0 * (1.0 - TopS) / HFull;
  end;

  { foundation skirt against sloped ground (downhill gap). }
  if FoundationBottomY < GroundY - 0.001 then
    EmitBand(FoundationBottomY, 1.0, GroundY, 1.0, False);

  { single gently-tapered tube, open top. }
  EmitBand(GroundY, 1.0, TopY, TopS, True);
end;

const
  { Watch-список roof_debug: для этих OSM way id пишется ПОЛНЫЙ дамп
    геометрии (футпринт, каждый треугольник крыши с нормалями, стены).
    Сейчас — два визуально битых здания с угла четырёх блоков. }
  ROOF_DBG_WATCH: array[0..1] of Int64 = (202213621, 649668407);

function RoofDbgWatched(AId: Int64): Boolean;
var
  K: Integer;
begin
  Result := False;
  for K := 0 to High(ROOF_DBG_WATCH) do
    if ROOF_DBG_WATCH[K] = AId then Exit(True);
end;

class procedure TBuildingBuilderExt.Build(Way: TOSMWay; Dataset: TOSMDataset;
  HM: THeightmap; Projection: TLocalProjection;
  TerrainSampler: TTerrainSampler;
  out PaletteIdx: Integer;
  const AllMeshes: TBuildingMeshes;
  var Stat: TBuildingExtStats;
  LogProc: TLogProc;
  var SampledCount: Integer;
  var CasterOut: TBuildingShadowCaster;
  out HasCaster: Boolean;
  const AInnerChains: TInt64ArrayArray;
  out ExtraCasters:TBuildingShadowCasters;
  ADbg: TStrings = nil);
var
  Verts2D: array of TVector3;
  Heights: array of Single;
  WallsTarget, RoofsTarget: TMesh;
  N, I: Integer;
  Node: TOSMNode;
  Pos: TVector3;
  GroundY, BaseY, EaveY, RidgeY: Single;
  MaxGroundY, MinGroundY, FoundationBottomY: Single;
  CornerMinH, CornerMaxH: Single;
  TotalHeight, MinH, RoofH: Single;
  ChH: Single;                      { chimney height (way path) }
  Area: Single;
  Footprint: array of TVector3;
  Shape: TRoofShape;
  RoofGeom: TRoofGeometry;
  RoofParams: TRoofParams;
  WallParams: TWallParams;
  Levels: Integer;
  SkirtOverhangM, SkirtDropM: Single;
  FlipWinding: Boolean;
  OnlyRoof: Boolean;
  WasSkeleton: Boolean;
  SkeletonOK: Boolean;
  VertsBefore, TrisBefore: Integer;
  VertsAdded, TrisAdded: Integer;
  { ── Диагностика per-roof (ADbg <> nil) ────────────────────────────
    IntendedShape — форма ДО фолбэков; BuilderValid/RejectedByBounds —
    почему крыша могла деградировать во flat; Rmn*/Rmx* — реальный
    габарит эмитированной геометрии крыши; Fmn*/Fmx* — bbox футпринта;
    Escape — макс. вылет вершины за (bbox+margin) или за Y-коридор. }
  IntendedShape: TRoofShape;
  BuilderValid, RejectedByBounds: Boolean;
  ClampedCount: Integer;
  RmnX, RmxX, RmnY, RmxY, RmnZ, RmxZ: Single;
  FmnX, FmxX, FmnZ, FmxZ: Single;
  Escape, EX, EZ, EY: Single;
  DbgIsOutlier: Boolean;
  { Inner rings (courtyards) resolved into the same quantised XZ space as the
    outer footprint. Cut out of the FLAT roof (Build forces rsFlat when set). }
  InnerRings: TRoofHoleArray;
  InnerRing:  TRoofHoleRing;
  IC, IM, IK: Integer;
  InnerOK: Boolean;
  BadV: TBooleanArray;
  RingClamped: Boolean;
  MassingJSON:TJSONData;
  Architecture:TArchitectureRecipe;
  ArchitectureCasters:TArchCasters;
  CompoundRecipe:TCompoundRoofRecipe;
  CompoundDomain:TMesh;
  HasCompoundRoof,CompoundBuilt:Boolean;
  AC,AK:Integer;
  { ── Диагностика v2 ────────────────────────────────────────────────
    Стены: диапазон эмита + bbox + эскейп (ловит шпиль ВЫШЕ конька и
    улёт юбки вбок — то, что крышный bbox не видит). Крыша: счётчики
    ориентации — authored-нормаль вниз означает culled сверху, т.е.
    «голубую дыру» вместо ската; DegenT — вырожденные треугольники.
    ReflexN — число рефлекс-вершин санированного кольца (классификация
    [builder failed→flat]: reflex=0 при фейле = подозрительно). }
  WVertsBefore, WTrisBefore: Integer;
  WVertsAdded, WTrisAdded: Integer;
  WmnX, WmxX, WmnY, WmxY, WmnZ, WmxZ: Single;
  DownAuth, DownGeo, DegenT, ReflexN: Integer;
  DbgT, DbgTA, DbgTB, DbgTC: Integer;
  DbgE1, DbgE2, DbgFN: TVector3;
  DbgLen, DbgNyGeo, DbgOri, DbgCr: Single;
  DbgPx, DbgPz, DbgCx, DbgCz, DbgNx, DbgNz: Single;
  DbgWatch, DbgDump: Boolean;
  DbgS: string;
  { ── Стены внутреннего двора ── }
  CourtParams: TWallParams;
  CArea: Single;
  FacadeJSON:TJSONData;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1085);{$ENDIF}
  PaletteIdx := 0;
  WallsTarget := nil;
  RoofsTarget := nil;
  HasCaster := False;
  ExtraCasters:=nil;
  CasterOut.Footprint := nil;
  CasterOut.GroundOpenings := nil;
  CasterOut.BaseY := 0;
  CasterOut.GroundY := 0;
  CasterOut.MaxY := 0;
  CasterOut.KeepGroundUnder := False;

  { Tag every vertex this building emits (walls + roof) with the OSM
    way id. AddVertex stamps CurrentOsmId; the id then rides the vertex
    through compositing, merging and tile splitting. Reset on every exit
    path so the next building does not inherit this one's id — done via
    try..finally below. }
  if WallsTarget <> nil then WallsTarget.CurrentOsmId := Way.Id;
  if RoofsTarget <> nil then RoofsTarget.CurrentOsmId := Way.Id;
  try

  N := Length(Way.NodeRefs);
  if Way.IsClosed then Dec(N);
  if N < 3 then Exit;

  SetLength(Verts2D, N);
  SetLength(Heights, N);
  for I := 0 to N - 1 do
  begin
    if not Dataset.Nodes.TryGetValue(Way.NodeRefs[I], Node) then Exit;
    if Dataset.LatticeReady then
    begin
      { int-first: ТОЧНЫЕ решёточные координаты узла (мировая решётка 1/64 м
        минус целый сдвиг блока, PrecomputeLattice). Конверсия I·1/64 точна
        (степень двойки): один и тот же дом в halo разных блоков получает
        ПОБИТНО одинаковый футпринт — класс «угловых» расхождений закрыт
        по построению, float-проекция в плане больше не участвует. }
      Pos.X := Node.LatticeX * (1.0 / 64.0);
      Pos.Y := 0;
      Pos.Z := Node.LatticeZ * (1.0 / 64.0);
    end
    else
    begin
      { fallback (хост без int-обвязки): блок-локальная float-проекция
        с квантом к той же решётке — прежнее поведение. }
      Pos := Projection.Project(Node.Position, 0);
      Pos.X := Round(Pos.X * 64.0) * (1.0 / 64.0);
      Pos.Z := Round(Pos.Z * 64.0) * (1.0 / 64.0);
    end;
    { Use TerrainSampler when available — it performs barycentric
      interpolation on the actual terrain mesh triangles and gives
      exactly the Y the terrain shape renders at.  Falling back to
      SampleBilinear can underestimate the true surface (bilinear ≠
      piecewise-linear), which places the foundation below terrain. }
    if TerrainSampler <> nil then
      Heights[I] := TerrainSampler.SampleAt(Node.Position)
    else
      Heights[I] := THeightmapSampler.SampleBilinear(HM, Node.Position);
    Verts2D[I].X := Pos.X;
    Verts2D[I].Y := 0;
    Verts2D[I].Z := Pos.Z;
  end;

  FlipWinding := False;
  EnsureCCWXZ(Verts2D, Heights);

  { Санация футпринта ДО всего остального. Раньше чистилась только копия
    RoofParams.Footprint, а стены/фундамент/подстенки навеса/shadow-caster
    и InteriorTerrainExtremes ехали на СЫРОМ Verts2D: одна runaway-вершина
    (битый узел, (0,0)-координата, сбой проекции) давала квад стены через
    всю карту, а MaxGroundY подхватывал рельеф за километры — здание
    целиком (вместе с крышей) вставало на чужую высоту; bounds-check
    крыши относителен EaveY и такое принципиально не ловит. Плюс
    edge-sampling шагом 0.25 м вдоль многокилометрового «ребра». Теперь
    ВЕЗДЕ (стены, крыша, тени, рельеф, градирни/трубы) один чистый ring. }
  if not SanitizeFootprintRing(Verts2D, BadV) then Exit;
  RingClamped := False;
  ClampedCount := 0;
  for I := 0 to N - 1 do
    if BadV[I] then
    begin
      RingClamped := True;
      Inc(ClampedCount);
      { Высота под НОВОЙ (заклампленной) позицией — старая была снята с
        runaway-узла и могла прийти с чужого рельефа. }
      if TerrainSampler <> nil then
        Heights[I] := TerrainSampler.SampleAtXZ(Projection,
          Verts2D[I].X, Verts2D[I].Z)
      else
        Heights[I] := THeightmapSampler.SampleBilinear(HM,
          Projection.Unproject(Verts2D[I].X, Verts2D[I].Z));
    end;
  { Клампы теоретически могут поменять знак обхода — восстановить
    конвенцию CCW (реверсит Verts2D и Heights согласованно). }
  if RingClamped then
    EnsureCCWXZ(Verts2D, Heights);

  { Resolve inner rings (multipolygon courtyards) into the SAME quantised XZ
    grid as the outer footprint, so the hole edges land exactly on the 1/64 m
    world grid the composite uses. Each chain is a closed node-ref ring; a ring
    with a missing node or < 3 distinct vertices is dropped. Winding is left
    untouched — the earcut in BuildFlat normalises it. }
  SetLength(InnerRings, 0);
  for IC := 0 to High(AInnerChains) do
  begin
    IM := Length(AInnerChains[IC]);
    if (IM >= 2) and (AInnerChains[IC][0] = AInnerChains[IC][IM - 1]) then
      Dec(IM);                           { drop closing duplicate }
    if IM < 3 then Continue;
    SetLength(InnerRing, IM);
    InnerOK := True;
    for IK := 0 to IM - 1 do
    begin
      if not Dataset.Nodes.TryGetValue(AInnerChains[IC][IK], Node) then
      begin InnerOK := False; Break; end;
      if Dataset.LatticeReady then
      begin
        { int-first: см. комментарий у внешнего кольца }
        Pos.X := Node.LatticeX * (1.0 / 64.0);
        Pos.Y := 0;
        Pos.Z := Node.LatticeZ * (1.0 / 64.0);
      end
      else
      begin
        Pos := Projection.Project(Node.Position, 0);
        Pos.X := Round(Pos.X * 64.0) * (1.0 / 64.0);
        Pos.Z := Round(Pos.Z * 64.0) * (1.0 / 64.0);
      end;
      InnerRing[IK].X := Pos.X;
      InnerRing[IK].Y := 0;
      InnerRing[IK].Z := Pos.Z;
    end;
    if not InnerOK then Continue;
    SetLength(InnerRings, Length(InnerRings) + 1);
    InnerRings[High(InnerRings)] := Copy(InnerRing, 0, IM);
  end;

  { Per-corner extremes — seed for InteriorTerrainExtremes. }
  CornerMaxH := Heights[0];
  CornerMinH := Heights[0];
  for I := 1 to N - 1 do
  begin
    if Heights[I] > CornerMaxH then CornerMaxH := Heights[I];
    if Heights[I] < CornerMinH then CornerMinH := Heights[I];
  end;
  { Find true max/min of the rendered terrain mesh Y over the
    closed footprint region — see InteriorTerrainExtremes rationale
    for the "buildings sunken into a hill" and "walls hanging in
    air on a slope" cases. }
  InteriorTerrainExtremes(Verts2D, CornerMinH, CornerMaxH,
    Projection, TerrainSampler, HM,
    MinGroundY, MaxGroundY);

  { Foundation TOP — the level at which walls start (windows above
    this).  Lifted by BUILDING_FOUNDATION_LIFT_M (5 cm plinth) above
    the highest terrain point under the footprint, so the wall never
    has to share Y with the terrain. }
  GroundY := MaxGroundY + BUILDING_FOUNDATION_LIFT_M;

  { Foundation BOTTOM — extend the wall as a plain skirt DOWN to here
    so that on the downhill side of a slope the wall meets the ground
    instead of hanging in mid-air.  Pushed 10 cm BELOW the lowest
    terrain point so even a slight shader Z-bias on the terrain side
    cannot reveal a sliver of sky under the wall. }
  FoundationBottomY := MinGroundY - 0.10;
  { If the footprint is on near-flat terrain, MinGroundY ≈ MaxGroundY
    and FoundationBottomY ends up slightly above the normal BaseY
    (=GroundY + MinH).  The skirt block in BuildWalls already guards
    against that with an explicit < BaseY check; the few-cm "skirt"
    on flat ground is harmless and invisible. }

  Shape := ParseRoofShape(Way.Tags);
  Levels := ParseLevels(Way.Tags);
  MinH := TBuildingBuilder.ParseMinHeight(Way.Tags);

  { streets-gl `onlyRoof`: building=roof is a roof standing on its own (a
    canopy/awning) — no walls, no foundation. The body is lifted so it
    spans only the roof band (minHeight = height − roofHeight, set below)
    and the walls call is skipped. }
  OnlyRoof := (Way.Tags.GetLower('building') = 'roof');
  HasCompoundRoof:=Way.Tags.Get(COMPOUND_ROOF_TAG)<>'';
  if HasCompoundRoof then begin
    FacadeJSON:=GetJSON(Way.Tags.Get(COMPOUND_ROOF_TAG));
    try CompoundRecipe:=ParseCompoundRoof(FacadeJSON) finally FacadeJSON.Free end;
  end;

  { Explicit height tag (if present). Use ParseHeight with sentinel
    default = -1 so we can detect "missing". ParseHeight returns
    its Default if no tag; we re-detect via comparison.}
  TotalHeight := TBuildingBuilder.ParseHeight(Way.Tags, Way.Id, -1.0);
  if TotalHeight <= 0 then TotalHeight := 0;

  if (TotalHeight <= 0) and (Levels <= 0) then
  begin
    if Way.Tags.GetLower('building') = 'industrial' then
    begin
      { Industrial halls have large footprints but are usually a single
        (tall) storey - the area heuristic would wrongly stack them into
        a multi-storey tower. Default to one storey and keep the tagged
        (or default flat) roof shape instead of estimating from area. }
      Levels := 1;
      Inc(Stat.LevelsTagged);
    end
    else
    begin
      Area := Abs(PolygonSignedAreaXZ(Verts2D));   { real area — roof shape }
      { levels from the NORMAL-proportion area (min width capped), so a long
        narrow footprint isn't estimated as multi-storey. }
      Levels := EstimateLevelsFromArea(EffectiveAreaForLevels(Verts2D));
      if not RoofShapeIsTagged(Way.Tags) then
        Shape := EstimateRoofShapeFromArea(Area);
      Inc(Stat.AreaEstimated);
    end;
  end
  else
    Inc(Stat.LevelsTagged);

  { A courtyard (inner ring) can only be cut into a FLAT roof — a pitched roof
    spanning a hole is undefined. Force flat whenever holes were resolved. }
  if Length(InnerRings) > 0 then Shape := rsFlat;

  if Shape = rsFlat then
  begin
    RoofH := 0;
    { An authored roof assembly can replace the unsupported pitched roof
      around a courtyard. Keep its observed eave datum: flattening the roof
      must not raise the walls by roof:height and bury an eave-anchored gable.
      Unauthored buildings retain the established fallback. }
    if (Length(InnerRings)>0) and (Way.Tags.Get(ARCHITECTURE_TAG)<>'') and
      (ParseRoofShape(Way.Tags)<>rsFlat) then
      RoofH:=TBuildingBuilder.ParseRoofHeight(Way.Tags);
  end
  else
  begin
    RoofH := TBuildingBuilder.ParseRoofHeight(Way.Tags);
    { Bump RoofH for dome/onion/round to ~2 levels per streets-gl. }
    if (Shape = rsDome) or (Shape = rsOnion) or (Shape = rsRound) then
      if RoofH < 6.0 then RoofH := 8.0;
  end;

  if (TotalHeight <= 0) and (Levels > 0) then
  begin
    { Levels was set by tag or by area heuristic — derive TotalHeight. }
    TotalHeight := Levels * WALL_LEVEL_HEIGHT_M + RoofH;
  end
  else if Levels <= 0 then
  begin
    { Only explicit height (rare without levels): derive levels. }
    Levels := Round(Max(1, (TotalHeight - RoofH) / WALL_LEVEL_HEIGHT_M));
  end;

  { Защита от мусорных тегов OSM (вандализм/опечатки: height=12000,
    building:levels=999, min_height > height): выше ~1 км зданий не
    бывает; min_height, съедающий всё здание, давал нулевую плиту,
    парящую на абсурдной высоте — «улёт» по Y, который bounds-check
    крыши (относительный EaveY) не ловит. Кап стоит ДО ветки градирен,
    чтобы прикрыть и их. }
  if TotalHeight > 1000 then TotalHeight := 1000;
  if Levels > 250 then Levels := 250;
  if MinH > TotalHeight then MinH := 0;

  { Cooling tower (man_made=tower + tower:type=cooling): emit a concrete
    cone (lower 2/3) + cylinder (upper 1/3) shell in place of the normal
    walls and roof - no windows, open top. PaletteIdx 2 is the concrete
    slot SelectBuildingPalette returns for this tower, so BuildAlls
    pre-computed mesh slot and range metadata stay consistent. }
  if IsCoolingTower(Way.Tags) then
  begin
    PaletteIdx := 2;
    WallsTarget := AllMeshes.Walls[2];
    WallsTarget.CurrentOsmId := Way.Id;
    EmitCoolingTowerShell(Verts2D, GroundY, FoundationBottomY, TotalHeight,
                          WallsTarget);
    SetLength(CasterOut.Footprint, N);
    for I := 0 to N - 1 do
    begin
      CasterOut.Footprint[I].X := Verts2D[I].X;
      CasterOut.Footprint[I].Y := 0;
      CasterOut.Footprint[I].Z := Verts2D[I].Z;
    end;
    CasterOut.BaseY   := GroundY;
    CasterOut.GroundY := MinGroundY;
    CasterOut.MaxY    := GroundY + TotalHeight;
    HasCaster := True;
    Inc(Stat.Total);
    Exit;
  end;

  { Chimney (man_made=chimney) as a closed WAY: concrete tapered tube (palette 2,
    no windows, open top), same as the node path. Height from the height tag,
    else a chimney default. }
  if IsChimney(Way.Tags) or IsTower(Way.Tags) then
  begin
    PaletteIdx := 2;
    WallsTarget := AllMeshes.Walls[2];
    WallsTarget.CurrentOsmId := Way.Id;
    if IsTower(Way.Tags) then
      ChH := TBuildingBuilder.ParseHeight(Way.Tags, Way.Id, DEFAULT_TOWER_HEIGHT_M)
    else
      ChH := TBuildingBuilder.ParseHeight(Way.Tags, Way.Id, DEFAULT_CHIMNEY_HEIGHT_M);
    if ChH <= 0 then ChH := DEFAULT_CHIMNEY_HEIGHT_M;
    if ChH > 1000 then ChH := 1000;          { мусорный height-тег }
    EmitChimneyShell(Verts2D, GroundY, FoundationBottomY, ChH, WallsTarget);
    SetLength(CasterOut.Footprint, N);
    for I := 0 to N - 1 do
    begin
      CasterOut.Footprint[I].X := Verts2D[I].X;
      CasterOut.Footprint[I].Y := 0;
      CasterOut.Footprint[I].Z := Verts2D[I].Z;
    end;
    CasterOut.BaseY   := GroundY;
    CasterOut.GroundY := MinGroundY;
    CasterOut.MaxY    := GroundY + ChH;
    HasCaster := True;
    Inc(Stat.Total);
    Exit;
  end;

  { onlyRoof: lift the body so the eave coincides with the base of the
    ridge, leaving only the roof above ground (streets-gl
    buildingMinHeight = height − roofHeight). Overrides any min_height. }
  if OnlyRoof then MinH := Max(0, TotalHeight - RoofH);

  { Cap roofH so it doesn't exceed (height - minHeight). Streets-gl does
    `roofHeight = Math.min(roofHeight, height - (minHeight ?? 0))`.}
  if RoofH > TotalHeight - MinH then RoofH := Max(0, TotalHeight - MinH);

  BaseY := GroundY + MinH;
  EaveY := BaseY + (TotalHeight - MinH - RoofH);
  RidgeY := BaseY + (TotalHeight - MinH);
  if EaveY  < BaseY  then EaveY  := BaseY;
  if RidgeY <= EaveY then RidgeY := EaveY;
  if HasCompoundRoof then begin
    { Layout heights share the building base datum; roof:height must never
      be added a second time or raise the observed facade into the gable. }
    EaveY:=BaseY+CompoundRecipe.Eave;
    RidgeY:=BaseY+CompoundRoofMaxHeight(CompoundRecipe);
    RoofH:=RidgeY-EaveY;
    TotalHeight:=RidgeY-GroundY;
  end;

  SetLength(Footprint, N);
  for I := 0 to N - 1 do
  begin
    Footprint[I] := Verts2D[I];
    Footprint[I].Y := EaveY;
  end;

  PaletteIdx := SelectBuildingPalette(Way.Tags, Way.Id, Levels,
    HashBuildingCoords(Verts2D));
  if (PaletteIdx < 0) or (PaletteIdx >= BUILDING_PALETTE_SIZE) then
    PaletteIdx := 5;
  WallsTarget := AllMeshes.Walls[PaletteIdx];
  RoofsTarget := AllMeshes.Roofs[PaletteIdx];
  WallsTarget.CurrentOsmId := Way.Id;
  RoofsTarget.CurrentOsmId := Way.Id;

  if (Way.Tags.Get(BUILDING_MASSING_TAG)<>'') and (Length(InnerRings)=0) then begin
    MassingJSON:=GetJSON(Way.Tags.Get(BUILDING_MASSING_TAG));
    try
      if EmitColonnade(ParseBuildingMassing(MassingJSON),Verts2D,Projection,
        GroundY,FoundationBottomY,TotalHeight,WallsTarget,ExtraCasters) then begin
        Inc(Stat.Total); Inc(Stat.PerShape[rsFlat]); Exit;
      end;
      if Assigned(LogProc) then LogProc(Format('building %d: authored massing does not fit footprint/height; using OSM envelope',[Way.Id]));
    finally MassingJSON.Free end;
  end;

  DefaultSkirtParams(Shape, SkirtOverhangM, SkirtDropM);
  { A floating roof has no walls for an overhang sub-wall to anchor to —
    drop the skirt so the canopy stays clean. }
  if OnlyRoof then begin SkirtOverhangM := 0; SkirtDropM := 0; end;

  RoofParams := MakeRoofParams(EaveY, RoofH, Way.Tags);
  SetLength(RoofParams.Footprint, N);
  for I := 0 to N - 1 do RoofParams.Footprint[I] := Footprint[I];
  RoofParams.SkirtOverhangM := SkirtOverhangM;
  RoofParams.SkirtDropM := SkirtDropM;
  { Courtyards to cut out (only BuildFlat reads these; Shape was forced to
    rsFlat above when non-empty). nil ⇒ solid roof, exactly as before. }
  RoofParams.Holes := InnerRings;
  { Второй рубеж: Verts2D уже санирован на входе Build, так что на чистых
    данных выходим по быстрой ветке SaneN = N. Оставлен на случай, если у
    RoofParams.Footprint когда-нибудь появится иной источник. Идёт перед
    FillOMBBInRoofParams, чтобы OMBB считался по чистым данным. }
  SanitizeFootprintRing(RoofParams.Footprint);
  FillOMBBInRoofParams(RoofParams, RoofParams.Footprint);

  WasSkeleton := (not HasCompoundRoof) and ShapeUsesSkeleton(Shape);
  IntendedShape := Shape;   { форма ДО фолбэков — для диагностического лога }

  { Call individual builder directly (bypassing TRoofBuilder.BuildRoof's
    internal fallback) so we can detect real success/failure for stats.}
  if HasCompoundRoof then RoofGeom:=TRoofBuilder.BuildFlat(RoofParams)
  else case Shape of
    rsFlat:        RoofGeom := TRoofBuilder.BuildFlat(RoofParams);
    rsPyramidal:   RoofGeom := TRoofBuilder.BuildPyramidal(RoofParams);
    rsSkillion:    RoofGeom := TRoofBuilder.BuildSkillion(RoofParams);
    rsGabled:      RoofGeom := TRoofBuilder.BuildGabled(RoofParams);
    rsHipped:      RoofGeom := TRoofBuilder.BuildHipped(RoofParams);
    rsHalfHipped:  RoofGeom := TRoofBuilder.BuildHalfHipped(RoofParams);
    rsMansard:     RoofGeom := TRoofBuilder.BuildMansard(RoofParams);
    rsGambrel:     RoofGeom := TRoofBuilder.BuildGambrel(RoofParams);
    rsSaltbox:     RoofGeom := TRoofBuilder.BuildSaltbox(RoofParams);
    rsRound:       RoofGeom := TRoofBuilder.BuildRound(RoofParams);
    rsDome:        RoofGeom := TRoofBuilder.BuildDome(RoofParams);
    rsOnion:       RoofGeom := TRoofBuilder.BuildOnion(RoofParams);
  else
    RoofGeom := TRoofBuilder.BuildFlat(RoofParams);
  end;

  { Stats track ACTUAL builder success — not after fallback. }
  SkeletonOK := RoofGeom.Valid and WasSkeleton;
  if WasSkeleton then
  begin
    if SkeletonOK then Inc(Stat.SkeletonOK)
    else                Inc(Stat.SkeletonFail);
  end;

  BuilderValid := RoofGeom.Valid;    { успел ли билдер до bounds-check }
  RejectedByBounds := False;

  { Reject a roof whose builder emitted a vertex outside the building's
    sane envelope (degenerate skeleton node, runaway apex, …) — it would
    render as a sky-spanning spike. Fall through to the flat fallback. }
  if RoofGeom.Valid and
     (not RoofGeometryWithinBounds(RoofGeom, RoofParams.Footprint,
                                   EaveY, RoofH)) then
  begin
    RoofGeom.Valid := False;
    RejectedByBounds := True;
  end;

  { Explicit fallback to flat if builder failed (or was rejected above).
    BuildFlat works off the sanitised footprint, so the flat roof is
    always in-bounds. }
  if not RoofGeom.Valid then
    RoofGeom := TRoofBuilder.BuildFlat(RoofParams);

  if (not HasCompoundRoof) and (SkirtOverhangM > 0) and (Shape <> rsFlat) and (Shape <> rsDome) and (Shape <> rsOnion) then
  begin
    { Sanitised footprint — keeps the skirt overhang in-bounds too. }
    GenerateRoofSkirt(RoofGeom, RoofParams.Footprint, EaveY, SkirtOverhangM, SkirtDropM);
    if RoofGeom.Skirt.HasSkirt then Inc(Stat.SkirtsAdded);
  end;

  VertsBefore := RoofsTarget.VertexCount;
  TrisBefore  := RoofsTarget.TriangleCount;
  CompoundBuilt:=False;
  if HasCompoundRoof then begin
    CompoundDomain:=TMesh.Create;
    try
      ApplyRoofGeometryToMesh(RoofGeom,CompoundDomain,False);
      CompoundBuilt:=EmitCompoundRoof(CompoundRecipe,Projection,CompoundDomain,BaseY,WallsTarget);
    finally CompoundDomain.Free end;
    if CompoundBuilt then begin
      { Roof paint uses the architectural material channel in the same
        palette batch. Remove the default deck and end walls completely. }
      RoofGeom:=EmptyRoofGeometry;RoofGeom.Valid:=True;
    end else if Assigned(LogProc) then
      LogProc(Format('building %d: compound roof exceeded bounds/cost; retained clipped flat roof',[Way.Id]));
  end;
  { A circular dome sits on a closed roof deck. A rectangular/irregular
    footprint otherwise leaves the corners open between dome and facade. }
  if (not CompoundBuilt) and (Shape in [rsDome, rsOnion]) and BuilderValid and not RejectedByBounds then
    ApplyRoofGeometryToMesh(TRoofBuilder.BuildFlat(RoofParams), RoofsTarget, FlipWinding);
  ApplyRoofGeometryToMesh(RoofGeom, RoofsTarget, FlipWinding);
  VertsAdded := RoofsTarget.VertexCount - VertsBefore;
  TrisAdded  := RoofsTarget.TriangleCount - TrisBefore;

  WallParams.BaseY := BaseY;
  WallParams.EaveY := EaveY;
  WallParams.FoundationBottomY := FoundationBottomY;
  WallParams.Levels := Levels;
  WallParams.LevelHeightM := WALL_LEVEL_HEIGHT_M;
  WallParams.TargetWindowWM := DEFAULT_WINDOW_WIDTH_M;
  { streets-gl isBuildingHasWindows → blank facade for the listed
    building types (garage/shed/silo/…) and explicit window=no. }
  WallParams.NoWindows := not BuildingHasWindows(Way.Tags);
  WallParams.FacadeLayouts:=nil;
  WallParams.Architecture:=nil;
  if Way.Tags.Get(ARCHITECTURE_TAG)<>'' then begin
    FacadeJSON:=GetJSON(Way.Tags.Get(ARCHITECTURE_TAG));
    try Architecture:=ParseArchitecture(FacadeJSON) finally FacadeJSON.Free end;
    ProjectArchitecture(Architecture,Projection,Verts2D,InnerRings);
    AC:=0;
    for AK:=0 to High(Architecture.Passages) do
      if Architecture.Passages[AK].Bottom+Architecture.Passages[AK].Height<EaveY-BaseY-0.02 then begin
        Architecture.Passages[AC]:=Architecture.Passages[AK];Inc(AC);
      end;
    SetLength(Architecture.Passages,AC);
    WallParams.Architecture:=Architecture.Facades;
  end;
  if Way.Tags.Get(FACADE_LAYOUT_TAG)<>'' then begin
    FacadeJSON:=GetJSON(Way.Tags.Get(FACADE_LAYOUT_TAG));
    try WallParams.FacadeLayouts:=ParseFacadeLayouts(FacadeJSON) finally FacadeJSON.Free end;
    ProjectFacadeLayouts(WallParams.FacadeLayouts,Projection,Way.Id);
  end;
  SetLength(WallParams.Footprint, N);
  for I := 0 to N - 1 do
  begin
    WallParams.Footprint[I] := Verts2D[I];
    WallParams.Footprint[I].Y := BaseY;
  end;
  WallParams.Skirt := RoofGeom.Skirt;
  { Диагностика v2: диапазон эмита стен — всё, что BuildWalls добавит
    (стены + фундамент + подвесные юбочные подстенки), попадает в
    [WVertsBefore..VertexCount) и проверяется на эскейп ниже. }
  WVertsBefore := 0;  WTrisBefore := 0;
  if WallsTarget <> nil then
  begin
    WVertsBefore := WallsTarget.VertexCount;
    WTrisBefore  := WallsTarget.TriangleCount;
  end;
  { onlyRoof (building=roof): emit the roof only. BuildWalls also builds
    the foundation strip and overhang sub-walls, so skipping the whole
    call is what suppresses walls AND foundation together. }
  if not OnlyRoof then
  begin
    TWallsBuilder.BuildWalls(WallParams, WallsTarget);
    ApplyRoofEndWalls(RoofGeom, EaveY, WallsTarget);

    { ── Стены внутреннего двора ────────────────────────────────────────
      Каждое inner-кольцо получает стены ТЕМ ЖЕ билдером — окна, этажная
      UV-сетка, фундамент под уклон и сглаживание рёбер как у внешних.
      Нормаль должна смотреть ВНУТРЬ двора (к центру дома): BuildWalls
      берёт нормаль из winding'а (Cross(Edge, Up)); внешнее кольцо
      нормализовано EnsureCCWXZ к НЕположительному shoelace, значит
      внутреннему нужен ПОЛОЖИТЕЛЬНЫЙ — при отрицательном разворачиваем.
      Юбки (свеса) у двора нет: вырез форсирует плоскую крышу. }
    for IC := 0 to High(InnerRings) do
    begin
      IM := Length(InnerRings[IC]);
      if IM < 3 then Continue;
      CourtParams := WallParams;
      CourtParams.FacadeLayouts:=nil;
      CourtParams.Architecture:=nil;
      SetLength(CourtParams.Footprint, IM);   { copy-on-write: своё кольцо }
      CArea := 0;
      for IK := 0 to IM - 1 do
        CArea := CArea
          + (InnerRings[IC][IK].X * InnerRings[IC][(IK + 1) mod IM].Z
           - InnerRings[IC][(IK + 1) mod IM].X * InnerRings[IC][IK].Z);
      if CArea < 0 then
        for IK := 0 to IM - 1 do
          CourtParams.Footprint[IK] := InnerRings[IC][IM - 1 - IK]
      else
        for IK := 0 to IM - 1 do
          CourtParams.Footprint[IK] := InnerRings[IC][IK];
      for IK := 0 to IM - 1 do
        CourtParams.Footprint[IK].Y := BaseY;
      CourtParams.Skirt.HasSkirt := False;
      SetLength(CourtParams.Skirt.OuterEdge, 0);
      SetLength(CourtParams.Skirt.InnerEdge, 0);
      TWallsBuilder.BuildWalls(CourtParams, WallsTarget);
    end;
  end;
  WVertsAdded := 0;  WTrisAdded := 0;
  if WallsTarget <> nil then
  begin
    WVertsAdded := WallsTarget.VertexCount - WVertsBefore;
    WTrisAdded  := WallsTarget.TriangleCount - WTrisBefore;
  end;

  { Record a shadow caster for this building. Footprint is in CCW-from-above
    (OSM3D negative-shoelace) convention from EnsureCCWXZ; TShadowBuilder
    normalises it internally. MaxY = ridge — roof apex — used as
    conservative top of the shadow envelope, so even pitched-roof
    buildings cast a shadow that fully covers the area they actually
    block (slight over-shoot at the gable side but visually correct). }
  SetLength(CasterOut.Footprint, N);
  for I := 0 to N - 1 do
  begin
    CasterOut.Footprint[I].X := Verts2D[I].X;
    CasterOut.Footprint[I].Y := 0;
    CasterOut.Footprint[I].Z := Verts2D[I].Z;
  end;
  CasterOut.BaseY := BaseY;
  CasterOut.GroundY := MinGroundY;
  CasterOut.MaxY  := RidgeY;
  { Двор/навес: землю под футпринтом дециматору давить нельзя — она видима
    (двор — сверху сквозь вырез, навес — под крышей насквозь). }
  CasterOut.KeepGroundUnder := OnlyRoof or (Length(InnerRings) > 0);
  HasCaster := True;

  Inc(Stat.Total);
  Inc(Stat.PerShape[Shape]);

  { Components are baked into the same palette mesh, retaining picking ids,
    tile clipping and the ordinary shadow/RTX path. No runtime object per part. }
  if (not OnlyRoof) and (Length(Architecture.Facades)>0) then begin
    EmitArchitecturalParts(Architecture,BaseY,EaveY,RidgeY,WallsTarget,ArchitectureCasters);
    SetLength(ExtraCasters,Length(ArchitectureCasters));
    for AC:=0 to High(ArchitectureCasters) do begin
      SetLength(ExtraCasters[AC].Footprint,4);
      for AK:=0 to 3 do ExtraCasters[AC].Footprint[AK]:=ArchitectureCasters[AC].Corners[AK];
      ExtraCasters[AC].BaseY:=ArchitectureCasters[AC].BaseY;
      ExtraCasters[AC].MaxY:=ArchitectureCasters[AC].MaxY;
      ExtraCasters[AC].GroundY:=MinGroundY;
      { Grounded columns/solid parts obstruct route fitting; an overhead
        portico or decorative steps preserve the ground beneath them. }
      ExtraCasters[AC].KeepGroundUnder:=not ArchitectureCasters[AC].BlocksGround;
    end;
  end;

  if (not OnlyRoof) and (Length(Architecture.Passages)>0) then begin
    if not CarveArchitecturePassages(Architecture.Passages,BaseY,EaveY,FoundationBottomY,
      WallsTarget,WVertsBefore,WTrisBefore) then Architecture.Passages:=nil;
    for AC:=0 to High(Architecture.Passages) do if Architecture.Passages[AC].Bottom<0.01 then begin
      AK:=Length(CasterOut.GroundOpenings);SetLength(CasterOut.GroundOpenings,AK+1);
      SetLength(CasterOut.GroundOpenings[AK],4);
      for I:=0 to 3 do CasterOut.GroundOpenings[AK][I]:=PassageGroundCorner(Architecture.Passages[AC],I);
    end;
    { Columns/decor carved by this same void cannot re-introduce a phantom
      obstacle or terrain hole through their coarse component envelopes. }
    for AC:=0 to High(ExtraCasters) do ExtraCasters[AC].GroundOpenings:=CasterOut.GroundOpenings;
    WVertsAdded:=WallsTarget.VertexCount-WVertsBefore;WTrisAdded:=WallsTarget.TriangleCount-WTrisBefore;
  end;

  { ── Per-roof диагностический лог (ADbg <> nil) ─────────────────────
    Считаем РЕАЛЬНЫЙ габарит эмитированной геометрии крыши прямо из
    RoofsTarget по диапазону [VertsBefore..VertexCount) — это то, что
    уйдёт в тайл и отрендерится (уже с навесом и после winding). Сравнение
    с bbox санированного футпринта ловит именно «улетевшую» крышу и
    привязывает её к адресу дома. Escape > 0 ⇒ вершина крыши вне
    (bbox + margin) по XZ или вне Y-коридора [EaveY-2 .. RidgeY+2]. }
  if (ADbg <> nil) and (VertsAdded > 0) then
  begin
    { bbox санированного футпринта. }
    FmnX := RoofParams.Footprint[0].X;  FmxX := FmnX;
    FmnZ := RoofParams.Footprint[0].Z;  FmxZ := FmnZ;
    for I := 1 to High(RoofParams.Footprint) do
    begin
      if RoofParams.Footprint[I].X < FmnX then FmnX := RoofParams.Footprint[I].X
      else if RoofParams.Footprint[I].X > FmxX then FmxX := RoofParams.Footprint[I].X;
      if RoofParams.Footprint[I].Z < FmnZ then FmnZ := RoofParams.Footprint[I].Z
      else if RoofParams.Footprint[I].Z > FmxZ then FmxZ := RoofParams.Footprint[I].Z;
    end;

    { габарит эмитированных вершин крыши. }
    RmnX := RoofsTarget.VertexAt[VertsBefore].Position.X;  RmxX := RmnX;
    RmnY := RoofsTarget.VertexAt[VertsBefore].Position.Y;  RmxY := RmnY;
    RmnZ := RoofsTarget.VertexAt[VertsBefore].Position.Z;  RmxZ := RmnZ;
    Escape := 0;
    for I := VertsBefore to RoofsTarget.VertexCount - 1 do
    begin
      with RoofsTarget.VertexAt[I].Position do
      begin
        if X < RmnX then RmnX := X else if X > RmxX then RmxX := X;
        if Y < RmnY then RmnY := Y else if Y > RmxY then RmxY := Y;
        if Z < RmnZ then RmnZ := Z else if Z > RmxZ then RmxZ := Z;
        { вылет за (bbox футпринта + 40 м) по X/Z и за Y-коридор. }
        EX := 0;
        if X < FmnX - 40.0 then EX := (FmnX - 40.0) - X
        else if X > FmxX + 40.0 then EX := X - (FmxX + 40.0);
        EZ := 0;
        if Z < FmnZ - 40.0 then EZ := (FmnZ - 40.0) - Z
        else if Z > FmxZ + 40.0 then EZ := Z - (FmxZ + 40.0);
        EY := 0;
        if Y < EaveY - 2.0 then EY := (EaveY - 2.0) - Y
        else if Y > RidgeY + 2.0 then EY := Y - (RidgeY + 2.0);
        if EX > Escape then Escape := EX;
        if EZ > Escape then Escape := EZ;
        if EY > Escape then Escape := EY;
      end;
    end;

    { ── стены: bbox + эскейп ─────────────────────────────────────────
      Ловит то, что крышный bbox не видит: шпиль ВЫШЕ конька (Y-эскейп
      вверх), провал ниже фундамента, улёт юбки вбок (за fp bbox + 6 м —
      навес 0.4 м + запас). Диапазон [WVertsBefore..VertexCount) покрывает
      стены + фундамент + юбочные подстенки. }
    WmnX := 0; WmxX := 0; WmnY := 0; WmxY := 0; WmnZ := 0; WmxZ := 0;
    if (WallsTarget <> nil) and (WVertsAdded > 0) then
    begin
      WmnX := WallsTarget.VertexAt[WVertsBefore].Position.X;  WmxX := WmnX;
      WmnY := WallsTarget.VertexAt[WVertsBefore].Position.Y;  WmxY := WmnY;
      WmnZ := WallsTarget.VertexAt[WVertsBefore].Position.Z;  WmxZ := WmnZ;
      for I := WVertsBefore to WallsTarget.VertexCount - 1 do
      begin
        with WallsTarget.VertexAt[I].Position do
        begin
          if X < WmnX then WmnX := X else if X > WmxX then WmxX := X;
          if Y < WmnY then WmnY := Y else if Y > WmxY then WmxY := Y;
          if Z < WmnZ then WmnZ := Z else if Z > WmxZ then WmxZ := Z;
          EX := 0;
          if X < FmnX - 6.0 then EX := (FmnX - 6.0) - X
          else if X > FmxX + 6.0 then EX := X - (FmxX + 6.0);
          EZ := 0;
          if Z < FmnZ - 6.0 then EZ := (FmnZ - 6.0) - Z
          else if Z > FmxZ + 6.0 then EZ := Z - (FmxZ + 6.0);
          EY := 0;
          if Y > RidgeY + 2.0 then EY := Y - (RidgeY + 2.0)
          else if Y < FoundationBottomY - 2.0 then
            EY := (FoundationBottomY - 2.0) - Y;
          if EX > Escape then Escape := EX;
          if EZ > Escape then Escape := EZ;
          if EY > Escape then Escape := EY;
        end;
      end;
    end;

    { ── ориентация треугольников крыши ───────────────────────────────
      Юбка уходит в стены, поэтому в roof-диапазоне легитимных «вниз»-
      граней НЕТ. DownAuth — authored-нормаль вниз: после пост-прохода
      MakeWindingMatchNormals winding равняется на authored, значит грань
      будет culled сверху → «дыра» в крыше. DownGeo — геометрическая
      нормаль текущего winding вниз (информативно). DegenT — вырожденные. }
    DownAuth := 0;  DownGeo := 0;  DegenT := 0;
    for DbgT := TrisBefore to RoofsTarget.TriangleCount - 1 do
    begin
      DbgTA := Integer(RoofsTarget.IndexAt[DbgT*3]);
      DbgTB := Integer(RoofsTarget.IndexAt[DbgT*3 + 1]);
      DbgTC := Integer(RoofsTarget.IndexAt[DbgT*3 + 2]);
      if (DbgTA < 0) or (DbgTB < 0) or (DbgTC < 0)
      or (DbgTA >= RoofsTarget.VertexCount)
      or (DbgTB >= RoofsTarget.VertexCount)
      or (DbgTC >= RoofsTarget.VertexCount) then Continue;
      DbgE1.X := RoofsTarget.VertexAt[DbgTB].Position.X
               - RoofsTarget.VertexAt[DbgTA].Position.X;
      DbgE1.Y := RoofsTarget.VertexAt[DbgTB].Position.Y
               - RoofsTarget.VertexAt[DbgTA].Position.Y;
      DbgE1.Z := RoofsTarget.VertexAt[DbgTB].Position.Z
               - RoofsTarget.VertexAt[DbgTA].Position.Z;
      DbgE2.X := RoofsTarget.VertexAt[DbgTC].Position.X
               - RoofsTarget.VertexAt[DbgTA].Position.X;
      DbgE2.Y := RoofsTarget.VertexAt[DbgTC].Position.Y
               - RoofsTarget.VertexAt[DbgTA].Position.Y;
      DbgE2.Z := RoofsTarget.VertexAt[DbgTC].Position.Z
               - RoofsTarget.VertexAt[DbgTA].Position.Z;
      DbgFN  := VecCross(DbgE1, DbgE2);
      DbgLen := Sqrt(DbgFN.X*DbgFN.X + DbgFN.Y*DbgFN.Y + DbgFN.Z*DbgFN.Z);
      if DbgLen < 1e-6 then
        Inc(DegenT)
      else if (DbgFN.Y / DbgLen) < -0.05 then
        Inc(DownGeo);
      if RoofsTarget.VertexAt[DbgTA].Normal.Y < -0.05 then
        Inc(DownAuth);
    end;

    { ── классификация [builder failed→flat]: рефлекс-вершины кольца ──
      Скелет отказывает на невыпуклых кольцах — reflex>0 при фейле это
      норма; reflex=0 при фейле = выпуклое кольцо отвергнуто = баг билдера. }
    ReflexN := -1;
    if (not BuilderValid) and (IntendedShape <> rsFlat)
       and (not RejectedByBounds) then
    begin
      DbgOri := 0;
      for I := 0 to N - 1 do
      begin
        DbgCx := RoofParams.Footprint[I].X;
        DbgCz := RoofParams.Footprint[I].Z;
        DbgNx := RoofParams.Footprint[(I + 1) mod N].X;
        DbgNz := RoofParams.Footprint[(I + 1) mod N].Z;
        DbgOri := DbgOri + (DbgCx * DbgNz - DbgNx * DbgCz);
      end;
      ReflexN := 0;
      for I := 0 to N - 1 do
      begin
        DbgPx := RoofParams.Footprint[(I + N - 1) mod N].X;
        DbgPz := RoofParams.Footprint[(I + N - 1) mod N].Z;
        DbgCx := RoofParams.Footprint[I].X;
        DbgCz := RoofParams.Footprint[I].Z;
        DbgNx := RoofParams.Footprint[(I + 1) mod N].X;
        DbgNz := RoofParams.Footprint[(I + 1) mod N].Z;
        DbgCr := (DbgCx - DbgPx) * (DbgNz - DbgCz)
               - (DbgCz - DbgPz) * (DbgNx - DbgCx);
        if DbgCr * DbgOri < -1e-6 then Inc(ReflexN);
      end;
    end;

    DbgIsOutlier := Escape > 0.5;
    DbgWatch := RoofDbgWatched(Way.Id);

    DbgS := Format(
      '%s%s | %s | shape %s→%s%s%s%s%s%s | fp=%dv ombb=%.1fx%.1f | ' +
      'eave=%.1f ridge=%.1f roofH=%.1f | roof=%dv/%dt | ' +
      'roofXZ[%.1f..%.1f, %.1f..%.1f] Y[%.1f..%.1f] | ' +
      'fpXZ[%.1f..%.1f, %.1f..%.1f]',
      [ { префикс-маркер: grep '!!' выцепляет все аномалии сразу }
       IfThen(DbgIsOutlier, '!!OUTLIER ',
         IfThen((DownAuth > 0) or (DegenT > 0), '!!ORIENT ', '')),
       BuildingAddressStr(Way.Tags, Way.Id),
       IfThen(OnlyRoof, 'canopy', 'building'),
       RoofShapeName(IntendedShape), RoofShapeName(Shape),
       IfThen(RejectedByBounds, ' [roof rejected→flat]',
         IfThen(BuilderValid or (IntendedShape = rsFlat), '', ' [builder failed→flat]')),
       IfThen(RingClamped, Format(' [ring clamped %dv]', [ClampedCount]), ''),
       IfThen(ReflexN >= 0, Format(' [reflex=%d]', [ReflexN]), ''),
       IfThen((DownAuth > 0) or (DownGeo > 0),
         Format(' [DOWN=%d/%d]', [DownAuth, DownGeo]), ''),
       IfThen(DegenT > 0, Format(' [DEGEN=%d]', [DegenT]), ''),
       N, RoofParams.OMBBLength, RoofParams.OMBBWidth,
       EaveY, RidgeY, RoofH,
       VertsAdded, TrisAdded,
       RmnX, RmxX, RmnZ, RmxZ, RmnY, RmxY,
       FmnX, FmxX, FmnZ, FmxZ]);
    if WVertsAdded > 0 then
      DbgS := DbgS + Format(
        ' | wall=%dv/%dt XZ[%.1f..%.1f, %.1f..%.1f] Y[%.1f..%.1f]',
        [WVertsAdded, WTrisAdded, WmnX, WmxX, WmnZ, WmxZ, WmnY, WmxY])
    else
      DbgS := DbgS + ' | wall=0';
    if DbgIsOutlier then
      DbgS := DbgS + Format('  escape=%.1fm', [Escape]);
    ADbg.Add(DbgS);

    { ── полный дамп геометрии ────────────────────────────────────────
      Для watch-списка — всегда; для аномалий (!!) — пока лог не раздулся.
      Каждый треугольник крыши: 3 позиции, authored-нормаль вершины A и
      Y геометрической нормали текущего winding'а. Стены — кап 60 tris. }
    DbgDump := DbgWatch
      or ((DbgIsOutlier or (DownAuth > 0) or (DegenT > 0))
          and (ADbg.Count < 4000));
    if DbgDump then
    begin
      DbgS := '    fp:';
      for I := 0 to N - 1 do
        DbgS := DbgS + Format(' (%.2f %.2f)',
          [RoofParams.Footprint[I].X, RoofParams.Footprint[I].Z]);
      ADbg.Add(DbgS);
      for DbgT := TrisBefore to RoofsTarget.TriangleCount - 1 do
      begin
        DbgTA := Integer(RoofsTarget.IndexAt[DbgT*3]);
        DbgTB := Integer(RoofsTarget.IndexAt[DbgT*3 + 1]);
        DbgTC := Integer(RoofsTarget.IndexAt[DbgT*3 + 2]);
        if (DbgTA < 0) or (DbgTB < 0) or (DbgTC < 0)
        or (DbgTA >= RoofsTarget.VertexCount)
        or (DbgTB >= RoofsTarget.VertexCount)
        or (DbgTC >= RoofsTarget.VertexCount) then Continue;
        DbgE1.X := RoofsTarget.VertexAt[DbgTB].Position.X
                 - RoofsTarget.VertexAt[DbgTA].Position.X;
        DbgE1.Y := RoofsTarget.VertexAt[DbgTB].Position.Y
                 - RoofsTarget.VertexAt[DbgTA].Position.Y;
        DbgE1.Z := RoofsTarget.VertexAt[DbgTB].Position.Z
                 - RoofsTarget.VertexAt[DbgTA].Position.Z;
        DbgE2.X := RoofsTarget.VertexAt[DbgTC].Position.X
                 - RoofsTarget.VertexAt[DbgTA].Position.X;
        DbgE2.Y := RoofsTarget.VertexAt[DbgTC].Position.Y
                 - RoofsTarget.VertexAt[DbgTA].Position.Y;
        DbgE2.Z := RoofsTarget.VertexAt[DbgTC].Position.Z
                 - RoofsTarget.VertexAt[DbgTA].Position.Z;
        DbgFN  := VecCross(DbgE1, DbgE2);
        DbgLen := Sqrt(DbgFN.X*DbgFN.X + DbgFN.Y*DbgFN.Y + DbgFN.Z*DbgFN.Z);
        DbgNyGeo := 0;
        if DbgLen > 1e-9 then DbgNyGeo := DbgFN.Y / DbgLen;
        ADbg.Add(Format(
          '    R#%d A=(%.2f %.2f %.2f) B=(%.2f %.2f %.2f) C=(%.2f %.2f %.2f)' +
          ' nA=(%.2f %.2f %.2f) nyGeo=%.2f',
          [DbgT - TrisBefore,
           RoofsTarget.VertexAt[DbgTA].Position.X,
           RoofsTarget.VertexAt[DbgTA].Position.Y,
           RoofsTarget.VertexAt[DbgTA].Position.Z,
           RoofsTarget.VertexAt[DbgTB].Position.X,
           RoofsTarget.VertexAt[DbgTB].Position.Y,
           RoofsTarget.VertexAt[DbgTB].Position.Z,
           RoofsTarget.VertexAt[DbgTC].Position.X,
           RoofsTarget.VertexAt[DbgTC].Position.Y,
           RoofsTarget.VertexAt[DbgTC].Position.Z,
           RoofsTarget.VertexAt[DbgTA].Normal.X,
           RoofsTarget.VertexAt[DbgTA].Normal.Y,
           RoofsTarget.VertexAt[DbgTA].Normal.Z,
           DbgNyGeo]));
      end;
      if (WallsTarget <> nil) and (WTrisAdded > 0) then
        for DbgT := WTrisBefore to WallsTarget.TriangleCount - 1 do
        begin
          if DbgT - WTrisBefore >= 60 then Break;
          DbgTA := Integer(WallsTarget.IndexAt[DbgT*3]);
          DbgTB := Integer(WallsTarget.IndexAt[DbgT*3 + 1]);
          DbgTC := Integer(WallsTarget.IndexAt[DbgT*3 + 2]);
          if (DbgTA < 0) or (DbgTB < 0) or (DbgTC < 0)
          or (DbgTA >= WallsTarget.VertexCount)
          or (DbgTB >= WallsTarget.VertexCount)
          or (DbgTC >= WallsTarget.VertexCount) then Continue;
          ADbg.Add(Format(
            '    W#%d A=(%.2f %.2f %.2f) B=(%.2f %.2f %.2f) C=(%.2f %.2f %.2f)',
            [DbgT - WTrisBefore,
             WallsTarget.VertexAt[DbgTA].Position.X,
             WallsTarget.VertexAt[DbgTA].Position.Y,
             WallsTarget.VertexAt[DbgTA].Position.Z,
             WallsTarget.VertexAt[DbgTB].Position.X,
             WallsTarget.VertexAt[DbgTB].Position.Y,
             WallsTarget.VertexAt[DbgTB].Position.Z,
             WallsTarget.VertexAt[DbgTC].Position.X,
             WallsTarget.VertexAt[DbgTC].Position.Y,
             WallsTarget.VertexAt[DbgTC].Position.Z]));
        end;
    end;
  end;

  if Assigned(LogProc) and (Shape <> rsFlat) and (SampledCount < SAMPLE_LIMIT) then
  begin
    Inc(SampledCount);
    LogProc(Format(
      '  sample #%d: wayId=%d shape=%s height=%.1fm roofH=%.1fm levels=%d ' +
      'fp=%dv ombb=%.1fx%.1fm skeleton=%s skirt=%s → roof: %dv %dt',
      [SampledCount, Way.Id, RoofShapeName(Shape),
       TotalHeight, RoofH, Levels,
       N, RoofParams.OMBBLength, RoofParams.OMBBWidth,
       BoolToStr(SkeletonOK, True),
       BoolToStr(RoofGeom.Skirt.HasSkirt, True),
       VertsAdded, TrisAdded]));
  end;

  finally
    { Clear the id so meshes shared across buildings do not tag the
      next building's (or any later non-building) geometry with this
      way id. Covers every Exit above too. }
    if WallsTarget <> nil then WallsTarget.CurrentOsmId := 0;
    if RoofsTarget <> nil then RoofsTarget.CurrentOsmId := 0;
  end;
end;

class function TBuildingBuilderExt.BuildAll(Dataset: TOSMDataset; HM: THeightmap;
  Projection: TLocalProjection;
  LogProc: TLogProc): TBuildingMeshes;
var
  IgnoredCasters: TBuildingShadowCasters;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1086);{$ENDIF}
  { Compat shim: no shadow casters, no terrain sampler. }
  Result := BuildAll(Dataset, HM, Projection, IgnoredCasters, nil, LogProc);
  IgnoredCasters := nil;
end;

class function TBuildingBuilderExt.BuildAll(Dataset: TOSMDataset; HM: THeightmap;
  Projection: TLocalProjection;
  out ShadowCasters: TBuildingShadowCasters;
  TerrainSampler: TTerrainSampler;
  LogProc: TLogProc;
  AShard: Integer;
  AShardCount: Integer): TBuildingMeshes;
var
  Way: TOSMWay;
  I: Integer;
  Stat: TBuildingExtStats;
  Shape: TRoofShape;
  ShapeName: string;
  Cnt, BuildingsInDataset: Integer;
  SampledCount: Integer;
  TotalWallTris, TotalRoofTris: Integer;
  WithShapeTag: Integer;
  CasterCount, CasterCap: Integer;
  AnchorCount, AnchorCap: Integer;
  { Multipolygon building relations. Tags (building=…, height, name) live on
    the RELATION; the outer/inner geometry lives on member ways that carry NO
    building tag — so the way loop never sees them and the whole building is
    silently dropped. We gather the outer-role member ways, stitch them into
    closed node-ref rings, synthesise one closed TOSMWay per ring (relation id
    + relation tags), and feed each through the SAME per-building path as a
    plain way. Inner rings are assigned to their containing outer; the same
    building path cuts courtyards into flat roofs and builds their walls. }
  Rel:          TOSMRelation;
  RelOuterWays: TOSMWayArray;
  RelChains:    TInt64ArrayArray;
  SynthWay:     TOSMWay;
  RelMi, RelCi, RelTi, RelOuterN, RelMPBuilt: Integer;
  RelMemRole:   string;
  RelMemWay:    TOSMWay;
  RelInnerWays: TOSMWayArray;
  RelInnerChains: TInt64ArrayArray;
  RelAssignedInners: TInt64ArrayArray;
  RelOuterRings, RelInnerRings: TPolygonRingArray;
  RelHoleOwners: TIntArray;
  RelHi, RelAssignedCount: Integer;
  RelInnerN:    Integer;
  ChimNode:     TOSMNode;   { standalone man_made=chimney nodes }
  RoofDbg:      TStringList;  { per-roof диагностический лог; nil если выключен }
  RoofDbgPath:  string;
  RoofDbgOutliers: Integer;
  DbgLn: Integer;
  DbgSummaryN: Integer;   { сводных строк (крыш) — без строк дампа/шапки }
  Parts:TBuildingPartSelection;

  { Per-building emit: pre-resolve palette, snapshot per-palette mesh sizes,
    Build(), then shadow-caster + tile-anchor bookkeeping from the emitted
    vertex range. Own try/except so one bad building can't sink the rest.
    Shared by the plain-way loop and the multipolygon-relation loop. }
  procedure ProcessBuildingWay(AWay: TOSMWay;
    const AInnerChains: TInt64ArrayArray);
  var
    PaletteIdx, J, K: Integer;
    Caster: TBuildingShadowCaster;
    HasCaster: Boolean;
    ExtraCasters:TBuildingShadowCasters;
    { Per-building snapshot of mesh sizes before Build() — the diff after
      gives the triangle/vertex range belonging to this one building. }
    PreWallsTri, PreWallsVert: array[0..BUILDING_PALETTE_SIZE - 1] of Integer;
    PreRoofsTri, PreRoofsVert: array[0..BUILDING_PALETTE_SIZE - 1] of Integer;
    AnchorSumX, AnchorSumZ: Double;
    AnchorVertCount: Integer;
  begin
    try
      HasCaster := False;
      { Snapshot every palette slot; Build() picks the index after it
        knows storeys + footprint (hash of coords). }
      for J := 0 to BUILDING_PALETTE_SIZE - 1 do
      begin
        PreWallsTri [J] := Result.Walls[J].TriangleCount;
        PreWallsVert[J] := Result.Walls[J].VertexCount;
        PreRoofsTri [J] := Result.Roofs[J].TriangleCount;
        PreRoofsVert[J] := Result.Roofs[J].VertexCount;
      end;

      TBuildingBuilderExt.Build(AWay, Dataset, HM, Projection, TerrainSampler, PaletteIdx,
            Result,
            Stat, LogProc, SampledCount, Caster, HasCaster, AInnerChains, ExtraCasters, RoofDbg);

      if HasCaster then
      begin
        if CasterCount >= CasterCap then
        begin
          if CasterCap = 0 then CasterCap := 64
          else                  CasterCap := CasterCap * 2;
          SetLength(ShadowCasters, CasterCap);
        end;
        ShadowCasters[CasterCount] := Caster;
        Inc(CasterCount);
      end;

      for K:=0 to High(ExtraCasters) do begin
        if CasterCount>=CasterCap then begin
          CasterCap:=Max(64,CasterCap*2); SetLength(ShadowCasters,CasterCap);
        end;
        ShadowCasters[CasterCount]:=ExtraCasters[K]; Inc(CasterCount);
      end;

      { Anchor lives OUTSIDE the HasCaster gate — Build() can emit walls+roofs
        and still leave HasCaster=False; those buildings still need an anchor
        or the assembler won't render them. Source it from the actually
        emitted vertex range, not Caster.Footprint (empty when HasCaster=False). }
      if (Result.Walls[PaletteIdx].TriangleCount > PreWallsTri[PaletteIdx]) or
         (Result.Roofs[PaletteIdx].TriangleCount > PreRoofsTri[PaletteIdx]) then
      begin
        AnchorSumX := 0;
        AnchorSumZ := 0;
        AnchorVertCount := 0;
        for K := PreWallsVert[PaletteIdx] to Result.Walls[PaletteIdx].VertexCount - 1 do
        begin
          AnchorSumX := AnchorSumX + Result.Walls[PaletteIdx].VertexAt[K].Position.X;
          AnchorSumZ := AnchorSumZ + Result.Walls[PaletteIdx].VertexAt[K].Position.Z;
          Inc(AnchorVertCount);
        end;
        for K := PreRoofsVert[PaletteIdx] to Result.Roofs[PaletteIdx].VertexCount - 1 do
        begin
          AnchorSumX := AnchorSumX + Result.Roofs[PaletteIdx].VertexAt[K].Position.X;
          AnchorSumZ := AnchorSumZ + Result.Roofs[PaletteIdx].VertexAt[K].Position.Z;
          Inc(AnchorVertCount);
        end;
        if AnchorVertCount = 0 then Exit;
        AnchorSumX := AnchorSumX / AnchorVertCount;
        AnchorSumZ := AnchorSumZ / AnchorVertCount;

        if AnchorCount >= AnchorCap then
        begin
          if AnchorCap = 0 then AnchorCap := 64
          else                  AnchorCap := AnchorCap * 2;
          SetLength(Result.TileAnchors, AnchorCap);
        end;
        Result.TileAnchors[AnchorCount].Palette        := PaletteIdx;
        Result.TileAnchors[AnchorCount].AnchorX        := AnchorSumX;
        Result.TileAnchors[AnchorCount].AnchorZ        := AnchorSumZ;
        Result.TileAnchors[AnchorCount].WallsTriStart  := PreWallsTri [PaletteIdx];
        Result.TileAnchors[AnchorCount].WallsTriEnd    := Result.Walls[PaletteIdx].TriangleCount;
        Result.TileAnchors[AnchorCount].WallsVertStart := PreWallsVert[PaletteIdx];
        Result.TileAnchors[AnchorCount].WallsVertEnd   := Result.Walls[PaletteIdx].VertexCount;
        Result.TileAnchors[AnchorCount].RoofsTriStart  := PreRoofsTri [PaletteIdx];
        Result.TileAnchors[AnchorCount].RoofsTriEnd    := Result.Roofs[PaletteIdx].TriangleCount;
        Result.TileAnchors[AnchorCount].NoShadowCast   := False;
        Result.TileAnchors[AnchorCount].RoofsVertStart := PreRoofsVert[PaletteIdx];
        Result.TileAnchors[AnchorCount].RoofsVertEnd   := Result.Roofs[PaletteIdx].VertexCount;
        Inc(AnchorCount);
      end;
    except
      on E: Exception do
      begin
        Inc(Stat.Failures);
        if Assigned(LogProc) then
          LogProc(Format('  ! id=%d build FAILED: %s: %s',
            [AWay.Id, E.ClassName, E.Message]));
      end;
    end;
  end;

  { Standalone chimney node (man_made=chimney as a point): generate a circular
    footprint, sample terrain, emit the concrete tube into Walls[2] with anchor
    and shadow-caster bookkeeping (mirrors ProcessBuildingWay). }
  procedure ProcessStructureNode(ANode: TOSMNode; ADefaultH: Single);
  const
    SEG = 16;
    PALETTE = 2;
  var
    Pos: TVector3;
    cx, cz, gy, r, h, fb, ang: Single;
    Verts2D: array of TVector3;
    K: Integer;
    preWT, preWV, preRT, preRV: Integer;
    Caster: TBuildingShadowCaster;
  begin
    try
      if Dataset.LatticeReady then
      begin
        { int-first: см. комментарий у футпринтов зданий }
        cx := ANode.LatticeX * (1.0 / 64.0);
        cz := ANode.LatticeZ * (1.0 / 64.0);
      end
      else
      begin
        Pos := Projection.Project(ANode.Position, 0);
        cx := Round(Pos.X * 64.0) * (1.0 / 64.0);
        cz := Round(Pos.Z * 64.0) * (1.0 / 64.0);
      end;
      if TerrainSampler <> nil then
        gy := TerrainSampler.SampleAt(ANode.Position)
      else
        gy := THeightmapSampler.SampleBilinear(HM, ANode.Position);
      r := ParseChimneyRadiusM(ANode.Tags);
      if r > 100.0 then r := DEFAULT_CHIMNEY_RADIUS_M;  { мусорный diameter/width }
      h := TBuildingBuilder.ParseHeight(ANode.Tags, ANode.Id, ADefaultH);
      if h <= 0 then h := ADefaultH;
      if h > 1000 then h := 1000;                       { мусорный height }
      fb := gy - 0.30;                        { small skirt vs minor slope }
      gy := gy + BUILDING_FOUNDATION_LIFT_M;  { base slightly above terrain }

      SetLength(Verts2D, SEG);
      for K := 0 to SEG - 1 do
      begin
        ang := 2.0 * Pi * K / SEG;
        Verts2D[K].X := cx + r * Cos(ang);
        Verts2D[K].Y := 0;
        Verts2D[K].Z := cz + r * Sin(ang);
      end;

      preWT := Result.Walls[PALETTE].TriangleCount;
      preWV := Result.Walls[PALETTE].VertexCount;
      preRT := Result.Roofs[PALETTE].TriangleCount;
      preRV := Result.Roofs[PALETTE].VertexCount;

      Result.Walls[PALETTE].CurrentOsmId := ANode.Id;
      EmitChimneyShell(Verts2D, gy, fb, h, Result.Walls[PALETTE]);
      Result.Walls[PALETTE].CurrentOsmId := 0;

      if Result.Walls[PALETTE].TriangleCount <= preWT then Exit;

      { anchor — centroid = node XZ (no roof range). }
      if AnchorCount >= AnchorCap then
      begin
        if AnchorCap = 0 then AnchorCap := 64 else AnchorCap := AnchorCap * 2;
        SetLength(Result.TileAnchors, AnchorCap);
      end;
      Result.TileAnchors[AnchorCount].Palette        := PALETTE;
      Result.TileAnchors[AnchorCount].AnchorX        := cx;
      Result.TileAnchors[AnchorCount].AnchorZ        := cz;
      Result.TileAnchors[AnchorCount].WallsTriStart  := preWT;
      Result.TileAnchors[AnchorCount].WallsTriEnd    := Result.Walls[PALETTE].TriangleCount;
      Result.TileAnchors[AnchorCount].WallsVertStart := preWV;
      Result.TileAnchors[AnchorCount].WallsVertEnd   := Result.Walls[PALETTE].VertexCount;
      Result.TileAnchors[AnchorCount].RoofsTriStart  := preRT;
      Result.TileAnchors[AnchorCount].RoofsTriEnd    := preRT;
      Result.TileAnchors[AnchorCount].RoofsVertStart := preRV;
      Result.TileAnchors[AnchorCount].RoofsVertEnd   := preRV;
      Result.TileAnchors[AnchorCount].NoShadowCast   := False;
      Inc(AnchorCount);

      { shadow caster (tall stack). }
      SetLength(Caster.Footprint, SEG);
      for K := 0 to SEG - 1 do
      begin
        Caster.Footprint[K].X := Verts2D[K].X;
        Caster.Footprint[K].Y := 0;
        Caster.Footprint[K].Z := Verts2D[K].Z;
      end;
      Caster.BaseY   := gy;
      Caster.GroundY := gy - BUILDING_FOUNDATION_LIFT_M;
      Caster.MaxY    := gy + h;
      Caster.GroundOpenings := nil;
      Caster.KeepGroundUnder := False;   { локальный record — поле не обнуляется само }
      if CasterCount >= CasterCap then
      begin
        if CasterCap = 0 then CasterCap := 64 else CasterCap := CasterCap * 2;
        SetLength(ShadowCasters, CasterCap);
      end;
      ShadowCasters[CasterCount] := Caster;
      Inc(CasterCount);

      Inc(Stat.Total);
      if Assigned(LogProc) then
        LogProc(Format('  structure node id=%d: r=%.1fm h=%.1fm gy=%.1f -> %d wall tris (palette %d)',
          [ANode.Id, r, h, gy, Result.Walls[PALETTE].TriangleCount - preWT, PALETTE]));
    except
      on E: Exception do
      begin
        Inc(Stat.Failures);
        if Assigned(LogProc) then
          LogProc(Format('  ! structure node id=%d FAILED: %s: %s',
            [ANode.Id, E.ClassName, E.Message]));
      end;
    end;
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1087);{$ENDIF}
  FillChar(Stat, SizeOf(Stat), 0);
  SampledCount := 0;
  CasterCount := 0;
  CasterCap := 0;
  ShadowCasters := nil;
  AnchorCount := 0;
  AnchorCap   := 0;
  Result.TileAnchors := nil;

  { Per-roof диагностический лог: одна строка на крышу с адресом дома и
    габаритами эмитированной геометрии; строки с !!OUTLIER помечают
    «улетевшие» крыши. Пишется в roof_debug_<tick>_<seq>.log под
    DefaultCacheRoot (как fit_snap_debug). Уникальный seq — на случай
    параллельной сборки блоков в разных потоках. }
  RoofDbg := nil;
  RoofDbgPath := '';
  RoofDbgOutliers := 0;
  if RoofDebugLogEnabled then
  begin
    RoofDbg := TStringList.Create;
    RoofDbg.Add(Format('# roof debug — %s', [DateTimeToStr(Now)]));
    RoofDbg.Add('# формат: [!!OUTLIER|!!ORIENT] адрес | тип | shape задумано→итог ' +
      '[причина фолбэка] [ring clamped] [reflex=N] [DOWN=auth/geo] [DEGEN=N] | ' +
      'fp ombb | eave ridge roofH | roof=Nv/Nt | эмит XZ/Y | fpXZ | ' +
      'wall=Nv/Nt XZ/Y [escape]; отступные строки — полный дамп ' +
      '(fp: кольцо; R#/W# треугольники с нормалями)');
  end;

  for I := 0 to BUILDING_PALETTE_SIZE - 1 do
  begin
    Result.Walls[I] := TMesh.Create(Format('buildings_walls_p%d', [I]));
    Result.Roofs[I] := TMesh.Create(Format('buildings_roofs_p%d', [I]));
  end;

  if Assigned(LogProc) then
  begin

    BuildingsInDataset := 0;
    WithShapeTag := 0;
    for Way in Dataset.Ways.Values do
      if (Way.Tags.HasKey('building') or IsCoolingTower(Way.Tags) or IsChimney(Way.Tags) or IsTower(Way.Tags)) and Way.IsClosed then
      begin
        Inc(BuildingsInDataset);
        if Way.Tags.HasKey('roof:shape') then Inc(WithShapeTag);
      end;
    LogProc(Format(
      'BuildingsExt: %d building ways found (%d with roof:shape tag); ' +
      'using extended pipeline (skeleton + 12 shapes + walls/windows + skirts)',
      [BuildingsInDataset, WithShapeTag]));
  end;

  Parts:=nil;
  try
    Parts:=TBuildingPartSelection.Create(Dataset);
    { plain building ways — the building tag lives on the way itself.
      Шардирование по Id: детерминированное разбиение для BuildAllParallel;
      AShardCount=1 (дефолт) — прежний однопоточный полный проход. }
    for Way in Dataset.Ways.Values do
    begin
      if (GenerationProgressContext.Cancel <> nil) and
         GenerationProgressContext.Cancel^ then Break;
      if (AShardCount <= 1) or (Way.Id mod AShardCount = AShard) then
        if (Way.Tags.HasKey('building') or Parts.PartVisible('way',Way.Id) or IsCoolingTower(Way.Tags) or IsChimney(Way.Tags) or IsTower(Way.Tags)) and Way.IsClosed and
          not Parts.Hidden('way',Way.Id) then
          ProcessBuildingWay(Way, nil);
    end;

    { standalone chimney NODES (man_made=chimney as a point) — the way loop
      only sees ways, so build node chimneys here. }
    if Assigned(LogProc) then
    begin
      I := 0; Cnt := 0;
      for ChimNode in Dataset.Nodes.Values do
        if ChimNode <> nil then
        begin
          Inc(Cnt);
          if IsChimney(ChimNode.Tags) or IsTower(ChimNode.Tags) then Inc(I);
        end;
      LogProc(Format('BuildingsExt: %d chimney/tower node(s) of %d total nodes in dataset', [I, Cnt]));
    end;
    for ChimNode in Dataset.Nodes.Values do
    begin
      if (GenerationProgressContext.Cancel <> nil) and
         GenerationProgressContext.Cancel^ then Break;
      if (ChimNode <> nil)
         and ((AShardCount <= 1) or (ChimNode.Id mod AShardCount = AShard)) then
        if IsChimney(ChimNode.Tags) then
          ProcessStructureNode(ChimNode, DEFAULT_CHIMNEY_HEIGHT_M)
        else if IsTower(ChimNode.Tags) then
          ProcessStructureNode(ChimNode, DEFAULT_TOWER_HEIGHT_M);
    end;

    { building multipolygon relations — the building tag lives on the
      relation, its outer/inner rings on member ways that carry no building
      tag, so the way loop above never sees them. Stitch each outer ring into
      a closed synthetic way (relation id + relation tags) and build it. }
    RelMPBuilt := 0;
    for Rel in Dataset.Relations.Values do
    begin
      if (GenerationProgressContext.Cancel <> nil) and
         GenerationProgressContext.Cancel^ then Break;
      if Rel = nil then Continue;
      if (AShardCount > 1) and (Rel.Id mod AShardCount <> AShard) then Continue;
      if Rel.Tags.GetLower('type') <> 'multipolygon' then Continue;
      if Parts.Hidden('relation',Rel.Id) then Continue;
      if not Rel.Tags.HasKey('building') and not Parts.PartVisible('relation',Rel.Id) then Continue;

      { collect outer-role member ways (empty role defaults to outer). }
      RelOuterN := 0;
      RelOuterWays := nil;
      for RelMi := 0 to Rel.MemberCount - 1 do
      begin
        if Rel.Members[RelMi].Kind <> omkWay then Continue;
        RelMemRole := LowerCase(Rel.Members[RelMi].Role);
        if (RelMemRole <> 'outer') and (RelMemRole <> '') then Continue;
        RelMemWay := Dataset.FindWay(Rel.Members[RelMi].Ref);
        if RelMemWay = nil then Continue;
        if Length(RelMemWay.NodeRefs) < 2 then Continue;
        { A closed outer way that itself carries building/cooling-tower was
          already emitted by the plain-way loop as its own building — skip it
          here so we don't double-build it (open member ways can't collide:
          the way loop's IsClosed check already skips them). }
        if RelMemWay.IsClosed and
           (RelMemWay.Tags.HasKey('building') or Parts.PartVisible('way',RelMemWay.Id) or IsCoolingTower(RelMemWay.Tags) or IsChimney(RelMemWay.Tags) or IsTower(RelMemWay.Tags)) then
          Continue;
        if RelOuterN >= Length(RelOuterWays) then
          SetLength(RelOuterWays, RelOuterN * 2 + 8);
        RelOuterWays[RelOuterN] := RelMemWay;
        Inc(RelOuterN);
      end;
      if RelOuterN = 0 then Continue;
      SetLength(RelOuterWays, RelOuterN);

      { Collect courtyards and assign them by containment, just as for landuse.
        A relation may have several buildings, each with its own courtyards,
        or an incomplete outer outside the downloaded region. }
      RelInnerN := 0;
      RelInnerWays := nil;
      for RelMi := 0 to Rel.MemberCount - 1 do
      begin
        if Rel.Members[RelMi].Kind <> omkWay then Continue;
        if LowerCase(Rel.Members[RelMi].Role) <> 'inner' then Continue;
        RelMemWay := Dataset.FindWay(Rel.Members[RelMi].Ref);
        if RelMemWay = nil then Continue;
        if Length(RelMemWay.NodeRefs) < 2 then Continue;
        if RelInnerN >= Length(RelInnerWays) then
          SetLength(RelInnerWays, RelInnerN * 2 + 8);
        RelInnerWays[RelInnerN] := RelMemWay;
        Inc(RelInnerN);
      end;
      if RelInnerN > 0 then
      begin
        SetLength(RelInnerWays, RelInnerN);
        RelInnerChains := StitchWaysIntoRingChains(RelInnerWays);
      end
      else
        RelInnerChains := nil;

      { one closed ring -> one synthetic building way; multiple disjoint
        outer rings each become their own building, sharing the tags. }
      RelChains := StitchWaysIntoRingChains(RelOuterWays);
      SetLength(RelOuterRings, Length(RelChains));
      for RelCi := 0 to High(RelChains) do
        RelOuterRings[RelCi] := BuildRingFromNodeChain(RelChains[RelCi], Dataset, Projection);
      SetLength(RelInnerRings, Length(RelInnerChains));
      for RelHi := 0 to High(RelInnerChains) do
        RelInnerRings[RelHi] := BuildRingFromNodeChain(RelInnerChains[RelHi], Dataset, Projection);
      RelHoleOwners := AssignInnerRingsToOuters(RelOuterRings, RelInnerRings);
      for RelCi := 0 to High(RelChains) do
      begin
        SynthWay := TOSMWay.Create(Rel.Id);
        try
          { element-copy (NodeRefs is an anonymous `array of Int64`; a whole
            dynarray assign from the named TInt64Array is avoided, matching
            ExtractNodeRefs). Ring is already CLOSED (last = first). }
          SetLength(SynthWay.NodeRefs, Length(RelChains[RelCi]));
          for RelTi := 0 to High(RelChains[RelCi]) do
            SynthWay.NodeRefs[RelTi] := RelChains[RelCi][RelTi];
          for RelTi := 0 to Rel.Tags.Count - 1 do
            SynthWay.Tags.Add(Rel.Tags.Keys[RelTi], Rel.Tags.Values[RelTi]);
          { A confirmed photo may refine a single closed outer ring. Preserve
            the relation's holes and defaults; do not tint every other ring. }
          for RelMi:=0 to High(RelOuterWays) do begin
            RelMemWay:=RelOuterWays[RelMi];
            if not RelMemWay.IsClosed or not RelMemWay.Tags.HasKey('rezvivo:photo_building') or
              (Length(RelMemWay.NodeRefs)<>Length(SynthWay.NodeRefs)) then Continue;
            if not SameClosedPhotoRing(SynthWay.NodeRefs,RelMemWay.NodeRefs) then Continue;
            SynthWay.Id:=RelMemWay.Id;
            for RelTi:=0 to RelMemWay.Tags.Count-1 do
              SynthWay.Tags.Add(RelMemWay.Tags.Keys[RelTi],RelMemWay.Tags.Values[RelTi]);
            Break;
          end;
          if SynthWay.IsClosed then
          begin
            RelAssignedCount := 0;
            SetLength(RelAssignedInners, Length(RelInnerChains));
            for RelHi := 0 to High(RelInnerChains) do
              if RelHoleOwners[RelHi] = RelCi then
              begin
                RelAssignedInners[RelAssignedCount] := RelInnerChains[RelHi];
                Inc(RelAssignedCount);
              end;
            SetLength(RelAssignedInners, RelAssignedCount);
            ProcessBuildingWay(SynthWay, RelAssignedInners);
            Inc(RelMPBuilt);
          end;
        finally
          SynthWay.Free;
        end;
      end;
    end;
    if Assigned(LogProc) and (RelMPBuilt > 0) then
      LogProc(Format('BuildingsExt: +%d multipolygon-relation building ring(s) processed',
        [RelMPBuilt]));
  except
    for I := 0 to BUILDING_PALETTE_SIZE - 1 do
    begin
      Result.Walls[I].Free;
      Result.Roofs[I].Free;
    end;
    Result.TileAnchors := nil;
    ShadowCasters := nil;
    RoofDbg.Free;   { nil-safe }
    Parts.Free;
    raise;
  end;
  Parts.Free;

  SetLength(ShadowCasters, CasterCount);
  SetLength(Result.TileAnchors, AnchorCount);

  { Normalise winding so every wall/roof triangle faces outward; some emission paths wound faces
    inward, forcing Solid=False (~2x fragment cost). Consistent winding lets the shapes be Solid=True.
    Per-triangle and idempotent. }
  for I := 0 to BUILDING_PALETTE_SIZE - 1 do
  begin
    Result.Walls[I].MakeWindingMatchNormals;
    Result.Roofs[I].MakeWindingMatchNormals;
  end;

  if Assigned(LogProc) then
  begin
    LogProc(Format('BuildingsExt: built %d buildings (failures: %d, ' +
      'tag-tagged: %d, area-estimated: %d, skirts: %d, shadow casters: %d, anchors: %d)',
      [Stat.Total, Stat.Failures, Stat.LevelsTagged, Stat.AreaEstimated,
       Stat.SkirtsAdded, CasterCount, AnchorCount]));

    LogProc(Format('  skeleton-based crowns: %d ok, %d failed (→ flat fallback)',
      [Stat.SkeletonOK, Stat.SkeletonFail]));

    LogProc('  roof shape histogram:');
    for Shape := Low(TRoofShape) to High(TRoofShape) do
    begin
      Cnt := Stat.PerShape[Shape];
      if Cnt = 0 then Continue;
      ShapeName := RoofShapeName(Shape);
      LogProc(Format('    %-12s : %d', [ShapeName, Cnt]));
    end;

    TotalWallTris := 0;
    TotalRoofTris := 0;
    for I := 0 to BUILDING_PALETTE_SIZE - 1 do
    begin
      Inc(TotalWallTris, Result.Walls[I].TriangleCount);
      Inc(TotalRoofTris, Result.Roofs[I].TriangleCount);
    end;
    LogProc(Format('  emit totals: %d wall triangles, %d roof triangles',
      [TotalWallTris, TotalRoofTris]));
  end;

  { Сброс per-roof лога в файл. Считаем аномалии для заголовка; путь
    выводим через LogProc, чтобы его было видно в общем логе сборки.
    NB: RoofDbg.Count теперь включает строки полного дампа (fp:/R#/W#),
    так что «крыш залогировано» — это счёт СВОДНЫХ строк (не с отступа). }
  if RoofDbg <> nil then
  try
    RoofDbgOutliers := 0;
    DbgSummaryN := 0;
    for DbgLn := 0 to RoofDbg.Count - 1 do
    begin
      if (Pos('!!OUTLIER', RoofDbg[DbgLn]) = 1)
      or (Pos('!!ORIENT',  RoofDbg[DbgLn]) = 1) then Inc(RoofDbgOutliers);
      if (RoofDbg[DbgLn] <> '') and (RoofDbg[DbgLn][1] <> ' ')
         and (RoofDbg[DbgLn][1] <> '#') then Inc(DbgSummaryN);
    end;
    RoofDbg.Insert(0, Format('# крыш залогировано: %d, аномалий (!!): %d',
      [DbgSummaryN, RoofDbgOutliers]));
    RoofDbgPath := IncludeTrailingPathDelimiter(DefaultCacheRoot) +
      Format('roof_debug_%d_%d.log',
        [GetTickCount64, InterlockedIncrement(RoofDbgSeq)]);
    ForceDirectories(DefaultCacheRoot);
    RoofDbg.SaveToFile(RoofDbgPath);
    if Assigned(LogProc) then
      LogProc(Format('  roof debug log → %s (%d roofs, %d anomalies)',
        [RoofDbgPath, DbgSummaryN, RoofDbgOutliers]));
  except
    { лог диагностики не должен ронять сборку — глотаем любую ошибку записи }
    on E: Exception do
      if Assigned(LogProc) then
        LogProc(Format('  roof debug log write FAILED: %s', [E.Message]));
  end;
  RoofDbg.Free;
end;

{ ── BuildAllParallel: шардированный параллельный запуск ──────────────── }

{ Дозапись всего Src в Dst со сдвигом индексов; возвращает оффсеты, на
  которые сдвигаются якорные диапазоны дозаписанного шарда. }
procedure AppendWholeMesh(Dst, Src: TMesh; out AVOfs, ATOfs: Integer);
var
  SV: TMeshVertexArray;
  SI: TMeshIndexArray;
  R:  Integer;
begin
  AVOfs := 0;
  ATOfs := 0;
  if Dst = nil then Exit;
  AVOfs := Dst.VertexCount;
  ATOfs := Dst.TriangleCount;
  if (Src = nil) or (Src.VertexCount = 0) then Exit;
  SV := Src.Vertices;
  SI := Src.Indices;
  for R := 0 to Src.VertexCount - 1 do
    Dst.AddVertex(SV[R]);
  for R := 0 to Src.TriangleCount - 1 do
    Dst.AddTriangle(
      Integer(SI[R * 3])     + AVOfs,
      Integer(SI[R * 3 + 1]) + AVOfs,
      Integer(SI[R * 3 + 2]) + AVOfs);
end;

type
  { До 16 шардов; реальный кап задаёт BuildAllParallel. }
  TBldShardCtx = record
    Dataset: TOSMDataset;
    HM:      THeightmap;
    Proj:    TLocalProjection;
    Sampler: TTerrainSampler;
    Shards:  Integer;
    Meshes:  array[0..15] of TBuildingMeshes;
    Casters: array[0..15] of TBuildingShadowCasters;
  end;
  PBldShardCtx = ^TBldShardCtx;

procedure RunBldShardRange(Ctx: Pointer; A, B: Integer);
var
  C: PBldShardCtx;
  I: Integer;
begin
  C := PBldShardCtx(Ctx);
  for I := A to B - 1 do
    C^.Meshes[I] := TBuildingBuilderExt.BuildAll(
      C^.Dataset, C^.HM, C^.Proj, C^.Casters[I], C^.Sampler,
      nil,               { лог шардов отключён — сводку пишет вызывающий }
      I, C^.Shards);
end;

class function TBuildingBuilderExt.BuildAllParallel(Dataset: TOSMDataset;
  HM: THeightmap; Projection: TLocalProjection;
  out ShadowCasters: TBuildingShadowCasters;
  TerrainSampler: TTerrainSampler;
  LogProc: TLogProc;
  AShards: Integer): TBuildingMeshes;
var
  Ctx: TBldShardCtx;
  S, P, K, AOfs, COfs, TotA, TotC: Integer;
  WVOfs, WTOfs, RVOfs, RTOfs:
    array[0..BUILDING_PALETTE_SIZE - 1] of Integer;
  A: TBuildingTileAnchor;
begin
  if AShards < 1 then AShards := 1;
  if AShards > 16 then AShards := 16;
  if AShards = 1 then
  begin
    Result := BuildAll(Dataset, HM, Projection, ShadowCasters,
      TerrainSampler, LogProc);
    Exit;
  end;

  Ctx.Dataset := Dataset;
  Ctx.HM      := HM;
  Ctx.Proj    := Projection;
  Ctx.Sampler := TerrainSampler;
  Ctx.Shards  := AShards;
  { шарды независимы по данным: Dataset/Sampler read-only (их уже читают
    шесть категорий пула параллельно), каждый шард пишет в свои меши }
  GenerationParallelFor('Buildings', AShards, @RunBldShardRange, @Ctx, 1);

  { merge: базой служит шард 0, остальные дозаписываются с оффсетами }
  Result        := Ctx.Meshes[0];
  ShadowCasters := Ctx.Casters[0];
  TotA := Length(Result.TileAnchors);
  TotC := Length(ShadowCasters);
  for S := 1 to AShards - 1 do
  begin
    Inc(TotA, Length(Ctx.Meshes[S].TileAnchors));
    Inc(TotC, Length(Ctx.Casters[S]));
  end;
  AOfs := Length(Result.TileAnchors);
  COfs := Length(ShadowCasters);
  SetLength(Result.TileAnchors, TotA);
  SetLength(ShadowCasters, TotC);

  for S := 1 to AShards - 1 do
  begin
    { пер-палитровые оффсеты фиксируются ДО дозаписи шарда }
    for P := 0 to BUILDING_PALETTE_SIZE - 1 do
    begin
      AppendWholeMesh(Result.Walls[P], Ctx.Meshes[S].Walls[P],
        WVOfs[P], WTOfs[P]);
      AppendWholeMesh(Result.Roofs[P], Ctx.Meshes[S].Roofs[P],
        RVOfs[P], RTOfs[P]);
    end;
    for K := 0 to High(Ctx.Meshes[S].TileAnchors) do
    begin
      A := Ctx.Meshes[S].TileAnchors[K];
      P := A.Palette;
      if (P >= 0) and (P < BUILDING_PALETTE_SIZE) then
      begin
        Inc(A.WallsTriStart,  WTOfs[P]);  Inc(A.WallsTriEnd,  WTOfs[P]);
        Inc(A.WallsVertStart, WVOfs[P]);  Inc(A.WallsVertEnd, WVOfs[P]);
        Inc(A.RoofsTriStart,  RTOfs[P]);  Inc(A.RoofsTriEnd,  RTOfs[P]);
        Inc(A.RoofsVertStart, RVOfs[P]);  Inc(A.RoofsVertEnd, RVOfs[P]);
      end;
      Result.TileAnchors[AOfs] := A;
      Inc(AOfs);
    end;
    for K := 0 to High(Ctx.Casters[S]) do
    begin
      ShadowCasters[COfs] := Ctx.Casters[S][K];
      Inc(COfs);
    end;
    { меши шарда слиты в базу — освобождаем оболочки }
    for P := 0 to BUILDING_PALETTE_SIZE - 1 do
    begin
      Ctx.Meshes[S].Walls[P].Free;
      Ctx.Meshes[S].Roofs[P].Free;
    end;
  end;

  if Assigned(LogProc) then
    LogProc(Format(
      'BuildingsExt: %d shards merged — anchors=%d, casters=%d',
      [AShards, TotA, TotC]));
end;

end.
