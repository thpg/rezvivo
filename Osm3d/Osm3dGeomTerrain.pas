unit Osm3dGeomTerrain;

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$codepage UTF8}
{$WARN 5091 OFF}    { FPC false-positives on managed types zeroed by runtime }
{$WARN 5092 OFF}

interface

uses
  Classes,
  SysUtils,
  Math,
  CastleVectors,
  Osm3dGeoMath,
  Osm3dHeightmap,
  Osm3dWaterLevel,
  Osm3dGeomMesh,
  Osm3dGeomUtils,
  Osm3dStudioSettings,       { FAR_DEPRESS_M and other spatial tuning }
  Osm3dFitHeightLayer        { TFitHeightLayer — коррекция высот узла по FIT }
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
;

type
  { The terrain lattice — the SINGLE source of truth shared by the
    terrain mesh and the terrain sampler so both land on the exact same
    nodes. The lattice is the heightmap's pixel grid, decimated by Step
    and phased to the GLOBAL slippy-tile grid: a node (JX,JZ) maps to
    heightmap pixel (JX*Step, JZ*Step), whose global pixel index is
    (GPX0+JX*Step, GPY0+JZ*Step). World position comes from that global
    pixel via the slippy projection (X linear in longitude, Z through
    the Web-Mercator inverse) — a purely global function, identical for
    every block, so adjacent blocks share edge nodes exactly. }
  TTerrainGrid = record
    WorldPx:    Double;     { 256 * 2^zoom — full slippy width in px }
    GPX0, GPY0: Int64;      { global pixel index of heightmap pixel (0,0) }
    HMW, HMH:   Integer;    { heightmap pixel dimensions }
    Step:       Integer;    { heightmap pixels per ORIGINAL lattice node }
    Subdiv:     Integer;    { sub-nodes per original node, per axis (1 = off) }
    PitchPx:    Double;     { heightmap pixels per (sub)node = Step / Subdiv }
    NX, NZ:     Integer;    { lattice node counts (already include Subdiv) }
    Valid:      Boolean;
  end;

  { Build the lattice for a heightmap. Used by both TTerrainBuilder.Build
    and TTerrainSampler so the mesh and the sampler are guaranteed to use
    the identical node set. }
function TerrainGridOf(HM: THeightmap; Projection: TLocalProjection;
  GridStepMeters: Single; HeightmapZoom: Integer;
  Subdiv: Integer = 1): TTerrainGrid;
{ Geo-coordinate of lattice node (JX,JZ). }
function TerrainGridNodeLatLon(const G: TTerrainGrid;
  JX, JZ: Integer): TLatLon;

type
  { Один сегмент маски пролёта моста в МИРОВЫХ XZ (проекция тайла) +
    полуширина. Маска строится из OSM-мостов ДО постройки террейна
    (Osm3dGeomBridges.CollectSpanMask) и передаётся в Build/Create: узлы под
    пролётом берут землю по чистому DEM / нижнему уровню, а не поднимаются к
    настилу (насыпь-двойник под мостом убирается). }
  TBridgeMaskSeg = record
    AX, AZ, BX, BZ: Single;
    MinorWater: Boolean; { road priority applies only to small watercourses }
    HalfW: Single;   { ПОПЕРЕЧНАЯ полуширина коридора (расстояние до ОСИ), м }
    EndM:  Single;   { ПРОДОЛЬНЫЙ запас за концы сегмента, м. Раздельно от HalfW:
                       у мостов коридор должен покрыть насыпь на всю её ширину
                       (HalfW = весь FIT-коридор), но НЕ вытягиваться на столько
                       же за торцы пролёта — иначе вырез длиннее настила (щель).
                       Прямоугольник len+2·EndM × 2·HalfW вместо «стадиона». }
  end;
  TBridgeSpanMask = array of TBridgeMaskSeg;

{ Точка (X,Z) под каким-либо пролётом моста: продольная позиция в пределах
  сегмента ± EndM И поперечное расстояние до оси <= HalfW. Пустая маска → False. }
function BridgeMaskContains(const AMask: TBridgeSpanMask;
  X, Z: Single; WaterLevels: TWaterLevelField = nil): Boolean;

type
  { Коридор маршрута для режима «геометрия только вдоль пути FIT».
    Набор точек маршрута в МИРОВЫХ XZ проекции блока + радиус. Contains(X,Z)
    = точка в пределах радиуса ХОТЯ БЫ ОДНОЙ точки маршрута (полоса =
    объединение дисков вокруг точек). Ускорение — равномерная хэш-сетка по
    точкам (ячейка = радиус): запрос проверяет только 3×3 соседних ячейки,
    без перебора всех точек маршрута. Строится один раз на блок из точек
    маршрута, попавших в halo блока (Osm3dBlockGenerator). Террейн отсекает
    треугольники, у которых ВСЕ вершины вне коридора; земляной композит
    пересобирается по тому же правилу; OSM-фичи фильтруются на этапе датасета. }
  TRouteCorridor = class
  private
    FPtsX, FPtsZ: array of Single;
    FRad, FRad2, FInvCell: Single;
    FMinX, FMinZ: Single;
    FCols, FRows: Integer;
    FHead: array of Integer;   { ячейка -> первая точка (индекс), -1 = пусто }
    FNext: array of Integer;   { связный список точек ячейки }
  public
    { APtsX/APtsZ — параллельные массивы XZ точек маршрута в той же локальной
      системе, что и вершины террейна/композита/фич (Projection.Project с
      origin блока). ARadiusM — радиус коридора (метры). }
    constructor Create(const APtsX, APtsZ: array of Single; ARadiusM: Single);
    { (X,Z) в пределах радиуса хотя бы одной точки маршрута? O(1) в среднем. }
    function Contains(X, Z: Single): Boolean;
    function Count: Integer;
  end;

  TTerrainBuilder = class
  public
    { Builds the terrain mesh with its vertices placed EXACTLY on the
      heightmap's pixel lattice (decimated by GridStepMeters), and that
      lattice phased to the GLOBAL slippy-tile grid of HeightmapZoom.
      Two blocks whose halo heightmaps overlap therefore put vertices in
      the very same geo-points with the very same heights — adjacent
      tiles (same block or neighbouring block) share edge vertices
      bit-for-bit and the inter-block terrain seam disappears.
      HeightmapZoom is the slippy zoom the heightmap tiles were fetched
      at (TStudioSettings.HeightmapZoom). Caller owns the returned mesh.
      AFitLayer (опц.) — второй слой высот: если активен, высота КАЖДОГО
      узла смешивается с FIT (CorrectHeightGeo по гео узла) — на полотне
      точный FIT, за кромкой феатер к DEM. nil = чистый DEM. }
    class function Build(HM: THeightmap; Projection: TLocalProjection;
      GridStepMeters: Single = 10.0;
      HeightmapZoom: Integer = 13;
      Subdiv: Integer = 1;
      AFitLayer: TFitHeightLayer = nil;
      const AMask: TBridgeSpanMask = nil;
      ACorridor: TRouteCorridor = nil;
      AWaterLevels: TWaterLevelField = nil): TMesh;
  end;

  TFarTerrainBuilder = class
  public
    { FarHM is a low-res heightmap covering the extended bbox.
      MainBbox is currently unused (kept for API compatibility) — the
      depressed-mesh approach replaced the bbox-based skip. Returns nil
      or an empty mesh if construction is not possible. }
    class function Build(FarHM: THeightmap; Projection: TLocalProjection;
      const MainBbox: TLatLonBox;
      GridStepMeters: Single = 80.0): TMesh;
  end;

  TTerrainSampler = class
  private
    FBox:    TLatLonBox;
    FGrid:   TTerrainGrid;     { the lattice — shared with the mesh }
    FGridX:  Integer;
    FGridZ:  Integer;
    { Heights at grid nodes, row-major FHeights[Z*GridX + X].
      Typical ~600×600 → 1.4 MB per tile. }
    FHeights: array of Single;
    { Сырой DEM тех же узлов ДО FIT-коррекции (row-major) — доступ к «чистому
      DEM» без коррекции (SampleRawAt/SampleRawAtXZ). Это запрошенный возврат
      чистого DEM из высотного слоя. Строитель мостов его напрямую не
      использует: роль DEM под пролётом выполняет маска в скорректированной
      поверхности (там земля и так = чистый DEM), а на подходах нужен уровень
      насыпи. Accessor оставлен как общая возможность. }
    FHeightsRaw: array of Single;
    { Projected XZ at each node — optional. Without PrecomputeNodePositions
      FNodePosReady=False and accessors return False (caller falls back
      to Projection.Project). Memory: GridX × GridZ × 8 bytes
      (~14 MB on a 1233×1480 grid). }
    FNodeX:  array of Single;
    FNodeZ:  array of Single;
    FNodePosReady: Boolean;
    FCorrectedNodes: Integer;   { диагностика: узлов высоты сдвинул FIT-слой }
    FMaskedNodes: Integer;      { диагностика: узлов под маской пролётов мостов }
    FWaterLevels: TWaterLevelField; { borrowed; applied after interpolation }
  public
    { Builds the sampler on the SAME lattice as TTerrainBuilder.Build
      (via TerrainGridOf): node heights are read straight from the
      heightmap pixels, so SampleAt returns exactly the terrain mesh's
      surface — water, roads and landuse draped through SampleAt sit
      flush on the terrain with no z-fight. HM may be freed afterwards.
      AFitLayer — тот же слой, что у TTerrainBuilder.Build: применяется к
      высоте узла ТЕМ ЖЕ CorrectHeightGeo → сэмплер совпадает с мешем
      бит-в-бит. nil = чистый DEM. }
    constructor Create(HM: THeightmap; Projection: TLocalProjection;
      GridStepMeters: Single; HeightmapZoom: Integer;
      Subdiv: Integer = 1;
      AFitLayer: TFitHeightLayer = nil;
      const AMask: TBridgeSpanMask = nil;
      AWaterLevels: TWaterLevelField = nil);
    destructor Destroy; override;
    property WaterLevels: TWaterLevelField read FWaterLevels;

    { Y at (Lat,Lon) with triangle-barycentric interpolation. P outside
      Box → clamped to the nearest node. }
    function SampleAt(const P: TLatLon): Single;

    { СЫРОЙ DEM в точке (без FIT-коррекции), билинейно по узловой решётке —
      для строителя мостов (пролёт над естественным рельефом, не над насыпью).
      SampleRawAtXZ — то же по мировым XZ (Unproject внутри). }
    function SampleRawAt(const P: TLatLon): Single;
    function SampleRawAtXZ(Projection: TLocalProjection;
      X, Z: Single): Single;

    { Convenience for callers that already have projected (X,Z) — Unprojects internally. Used by
      ribbon builders so the Y at left/right edges matches the terrain AT the edge point (not
      inherited from the centre line, which dips on slopes perpendicular to travel). }
    function SampleAtXZ(Projection: TLocalProjection; X, Z: Single): Single;

    { Smooth (C1) Catmull-Rom height over the SAME node lattice and (X,Z)->node
      mapping as SampleAt. Passes through node heights exactly, so it agrees
      with SampleAt at the nodes and only smooths the in-cell facets. Used by
      the ground drape so a carve run on a coarse lattice still lands on a
      smooth surface (option-b: coarse carve, sub-tessellated bicubic drape). }
    function SampleAtCubic(const P: TLatLon): Single;
    function SampleAtXZCubic(Projection: TLocalProjection; X, Z: Single): Single;

    { Fractional lattice-node coordinate of a geo point — THE single definition of the world->grid
      mapping (lon linear in slippy px, lat through Web-Mercator forward; mirror of
      TerrainGridNodeLatLon). SampleAt and the clipper's cell enumeration BOTH route through here so
      they can never drift (a drifted copy once visited wrong cells and dropped overlay triangles). }
    procedure LatLonToCellFrac(const P: TLatLon; out FX, FZ: Double);

    { World (X,Z) -> fractional lattice node. Unprojects then defers to
      LatLonToCellFrac. Projection = nil yields (0,0) and False. }
    function WorldToCellFrac(Projection: TLocalProjection;
      X, Z: Single; out FX, FZ: Double): Boolean;

    { Direct height at (IX,IZ). Debugging only. }
    function NodeHeight(IX, IZ: Integer): Single;

    { Geo-coordinate of lattice node (IX,IZ) — the EXACT lat/lon of the
      matching terrain-mesh vertex. Callers that drape geometry on the
      terrain node grid must use this (not a box-linear estimate) so
      their vertices land on the terrain surface. }
    function NodeLatLon(IX, IZ: Integer): TLatLon;

    { Fills FNodeX/FNodeZ via Projection.Project for every node. Called
      ONCE per chunk before the clipper-heavy builders run. Idempotent. }
    procedure PrecomputeNodePositions(Projection: TLocalProjection);

    property NodePositionsReady: Boolean read FNodePosReady;

    { O(1) lookup of node projection. False → cache not ready, X/Z are
      uninitialised and caller must fall back to Projection.Project. }
    function NodePositionXZ(IX, IZ: Integer; out X, Z: Single): Boolean; inline;

    { Batched 4-corner accessors for one cell (IX,IZ) — identical results to
      four NodeHeight / NodePositionXZ calls (per-corner edge clamp), but the
      row offset is computed once. Hot path: LoadCellCorners. }
    procedure CellHeights4(IX, IZ: Integer;
      out hNW, hNE, hSE, hSW: Single);
    function CellPositions4(IX, IZ: Integer;
      out pNWx, pNWz, pNEx, pNEz, pSEx, pSEz, pSWx, pSWz: Single): Boolean;

    property Box:   TLatLonBox read FBox;
    property GridX: Integer    read FGridX;
    property GridZ: Integer    read FGridZ;
    { Диагностика: сколько узлов высоты сдвинул FIT-слой при построении
      (0 = слой не активен или блок вне коридора маршрута). }
    property CorrectedNodes: Integer read FCorrectedNodes;
    { Диагностика: сколько узлов попало под маску пролётов мостов (там земля
      берётся по чистому DEM / нижнему уровню). 0 при активной маске и
      ненулевом FitLayer = пролёты мостов не пересекли этот тайл. }
    property MaskedNodes: Integer read FMaskedNodes;
    { The terrain lattice (global slippy phasing: GPX0/GPY0/PitchPx). The
      carve reads it to map a cell (IX,IZ) to its tile. }
    property Grid:  TTerrainGrid read FGrid;
  end;

{ Высота земли по гео-точке: скорректированный сэмплер (SampleAt) — референсная
  поверхность; heightmap SampleBilinear — fallback при Terrain = nil; оба nil -> 0.
  Единый источник (были дословные дубли POIGroundHeight / GroundH в
  Osm3dGeomPOI / Osm3dGeomPlates). }
function SampleTerrainYGeo(Terrain: TTerrainSampler; HM: THeightmap;
  const P: TLatLon): Double;

{ Высота рельефа в проектных (X,Z) с защитой от NaN/Inf и nil-сэмплера.
  БЕЗ heightmap-фолбэка: мостам/туннелям нужна именно скорректированная
  поверхность (маска пролётов), сырой DEM под пролётом не подставляется.
  Единый источник (были побитные дубли SampleY в Osm3dGeomBridges /
  Osm3dGeomTunnels). }
function SampleTerrainYXZ(Sampler: TTerrainSampler; Projection: TLocalProjection;
  X, Z: Single): Single;

type
  TInputTriangle = record
    P:  array[0..2] of TXZ;
    UV: array[0..2] of TVector2;
  end;

  TClipperProgress = record
    LogProc:     TLogProc;
    LastTickMs:  QWord;
    Context:     string;
    PolyIdx:     Integer;
    PolyTotal:   Integer;
    TriIdx:      Integer;
    TriTotal:    Integer;
  end;
  PClipperProgress = ^TClipperProgress;

  PUVTransform = ^TUVTransform;

  TClipperUVMode = (cumNone, cumPlanar, cumInputBary);

  { Affine world→UV map for one source triangle (a ribbon triangle's UV
    parametrisation). In the interface so it can be embedded in the capture
    UV-context below; SetupInputTriBary/ApplyBaryUV remain in the impl. }
  TInputTriBary = record
    Valid:     Boolean;
    AX, AZ:    Double;
    v0X, v0Z:  Double;
    v1X, v1Z:  Double;
    D00, D01, D11: Double;
    InvDenom:  Double;
    UV:        array[0..2] of TVector2;
  end;

  { UV parametrisation of one capture source (one Project* call). The
    carve+emit pass recomputes a carved piece's UV from the source it came
    from: planar (terrain/landuse — pos*InvUV, optional UVTransform) or bary
    (roads — ApplyBaryUV over the source ribbon triangle). A captured piece's
    SourceTag indexes a TUVSourceCtxArray built during capture. }
  TUVSourceMode = (usmNone, usmPlanar, usmBary);
  TUVSourceCtx = record
    Mode:        TUVSourceMode;
    InvUV:       Single;
    UVTransform: PUVTransform;
    Bary:        TInputTriBary;
  end;
  TUVSourceCtxArray = array of TUVSourceCtx;

  { Carve+emit output: one TMesh per material id, appended (mesh, MatId) to the ground-composite
    builder by the caller (which owns/frees them). Returned here, not appended directly, to avoid a
    circular unit dependency. }
  TCarvedMatMesh = record
    MatId: Integer;
    Mesh:  TMesh;
    { Per-triangle tile key (packed TX/TY), parallel to Mesh's triangles.
      TriKeyCount is the used length (== Mesh.TriangleCount); the backing
      array is trimmed to it at the end of the carve. }
    TriTileKeys: array of Int64;
    TriKeyCount: Integer;
  end;
  TCarvedMatMeshArray = array of TCarvedMatMesh;

  { Profiling breakdown for one ground build (int-путь заполняет сам;
    float-клиппер снесён этапом 6).
    Ms* are wall-clock milliseconds accumulated across the per-cell loop via
    a high-resolution counter; the builder writes them to the log. }
  TCarveProfile = record
    TotalCells:    Integer;
    EmptyCells:    Integer;
    CarvedCells:   Integer;
    DecimActive:       Boolean;   { RQT-децимация отработала на этом построении }
    DecimCoarseBlocks: Integer;   { укрупнённых блоков (L>=1) эмитнуто }
    DecimCoarseCells:  Integer;   { ячеек покрыто укрупнёнными блоками }
    EmptyGridVerts:    Integer;   { вершины TerrainMesh после PASS 1 (чистая пустая сетка, до слияния PASS 2) }
    DecimTallyL0:      Integer;   { прямой подсчёт ячеек ALvl=0 (сверка с coarseCells) }
    DecimTallyCoarse:  Integer;   { прямой подсчёт ячеек ALvl>=1 (без двойного счёта) }
    SingleFillCells:   Integer;   { ячеек полностью покрыто ОДНИМ материалом — кандидаты на вырезку из земли }
    SingleFillByMat:   array[0..63] of Integer;   { из них по id материала }
    SharedLanduseCells: Integer;   { ячеек ландюза эмитнуто децимированной сеткой (вырезка из земли) }
    CarvedPieces:  Integer;
    TerrainVerts:  Integer;   { shared grid-node verts (empty-cell terrain) }
    TotalVerts:    Integer;
    TotalTris:     Integer;
    MsNodeNorms:   Double;
    MsSort:        Double;
    MsLoadCorners: Double;
    MsEmptyEmit:   Double;
    MsCarveCell:   Double;
    MsPieceEmit:   Double;
    DCCalls:       Int64;     { DifferenceConvex invocations }
    DCAABBReject:  Int64;     { of those, rejected by the AABB broad phase }
    ItemPeel:      Int64;     { peels in the item-vs-higher phase }
    TerrPeel:      Int64;     { peels in the terrain-remainder phase }
    CellsCovered:  Int64;     { carved cells whose terrain remainder was skipped }
    CapHits:       Int64;     { DifferenceConvexMulti fragmentation-cap hits }
    ItemPeelSame:  Int64;     { item peels where clip shares the subject's material }
    ItemPeelDiff:  Int64;     { item peels across different materials }
    FullCoverSame: Int64;     { same-material peels that removed the subject whole }
  end;

  TRibbonVertex = record
    X, Z:     Single;
    AccumLen: Single;
  end;
  TRibbonVertexArray = array of TRibbonVertex;

  TRibbonEdgePoint = record
    Right, Left: TXZ;
    AccumLen:    Single;
  end;
  TRibbonEdgePointArray = array of TRibbonEdgePoint;

  { Result of TTerrainClipper.DifferenceConvex: a list of convex polygons. }
  TXZPolygonList = array of TXZArray;

  { Named dynamic-Boolean type so the per-piece pool-ownership buffers can be
    swapped (two distinct anonymous `array of Boolean` decls are not
    assignment-compatible in FPC). }
  TBoolArray = array of Boolean;

  TTerrainClipper = class
  public
    class function ProjectTriangle(
      const InTri: TInputTriangle;
      Sampler: TTerrainSampler;
      Projection: TLocalProjection;
      Lift: Single;
      UVMode: TClipperUVMode; UVScale: Single;
      Target: TMesh;
      Progress: PClipperProgress = nil;
      UVTransform: PUVTransform = nil): Integer;

    class function ProjectMultipolygon(
      const MP: TPolygonMultipolygon;
      Sampler: TTerrainSampler;
      Projection: TLocalProjection;
      Lift: Single;
      UVMode: TClipperUVMode; UVScale: Single;
      Target: TMesh;
      Progress: PClipperProgress = nil;
      UVTransform: PUVTransform = nil): Integer;

    class function ProjectRibbonFromEdges(
      const Edges: TRibbonEdgePointArray;
      Sampler: TTerrainSampler;
      Projection: TLocalProjection;
      Lift: Single;
      UVScaleY: Single;
      UVMinX, UVMaxX: Single;
      Target: TMesh;
      Progress: PClipperProgress = nil): Integer;

  end;

procedure ComputeRibbonAccumLen(var Center: TRibbonVertexArray);

procedure InitClipperProgress(out P: TClipperProgress;
  LogProc: TLogProc; const Context: string;
  PolyTotal: Integer);

procedure ReportClipperProgress(var P: TClipperProgress;
  const ExtraMsg: string = '');

implementation

function SampleTerrainYGeo(Terrain: TTerrainSampler; HM: THeightmap;
  const P: TLatLon): Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1451);{$ENDIF}
  if Terrain <> nil then
    Result := Terrain.SampleAt(P)
  else if HM <> nil then
    Result := THeightmapSampler.SampleBilinear(HM, P)
  else
    Result := 0;
end;

function SampleTerrainYXZ(Sampler: TTerrainSampler; Projection: TLocalProjection;
  X, Z: Single): Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1610);{$ENDIF}
  if (Sampler = nil) or (Projection = nil) then Exit(0.0);
  Result := Sampler.SampleAtXZ(Projection, X, Z);
  if IsNan(Result) or IsInfinite(Result) then Result := 0.0;
end;

function TerrainGridOf(HM: THeightmap; Projection: TLocalProjection;
  GridStepMeters: Single; HeightmapZoom: Integer;
  Subdiv: Integer): TTerrainGrid;
var
  Box:       TLatLonBox;
  PixelLonM: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(341);{$ENDIF}
  FillChar(Result, SizeOf(Result), 0);
  Result.Valid := False;
  if (HM = nil) or (Projection = nil) then Exit;

  Box := HM.Box;
  if Box.IsEmpty then Exit;

  Result.HMW := HM.Width;
  Result.HMH := HM.Height;
  if (Result.HMW < 2) or (Result.HMH < 2) then Exit;

  if GridStepMeters < 0.5 then GridStepMeters := 0.5;
  if HeightmapZoom < 0  then HeightmapZoom := 0;
  if HeightmapZoom > 22 then HeightmapZoom := 22;

  { Full slippy-grid width in pixels at this zoom. }
  Result.WorldPx := 256.0 * IntPower(2.0, HeightmapZoom);

  { Global pixel index of the stitch's pixel (0,0). The stitch bounds
    are a union of whole slippy tiles, so MinLon / MaxLat fall exactly
    on tile borders and these round to exact integers — the lattice
    phase is shared by every block. }
  Result.GPX0 := Round((Box.MinLon + 180.0) / 360.0 * Result.WorldPx);
  Result.GPY0 := Round((1.0 - Ln(Tan(Box.MaxLat * DEG_TO_RAD)
                  + 1.0 / Cos(Box.MaxLat * DEG_TO_RAD)) / Pi)
                / 2.0 * Result.WorldPx);

  { Decimation: heightmap pixels per lattice node. }
  PixelLonM := (360.0 / Result.WorldPx) * Projection.MetersPerDegreeLon;
  if PixelLonM < 1.0e-6 then PixelLonM := 1.0e-6;
  Result.Step := Round(GridStepMeters / PixelLonM);
  if Result.Step < 1 then Result.Step := 1;

  { Sub-node oversampling. Subdiv sub-nodes per original node per axis;
    PitchPx (pixels per sub-node) becomes fractional and sub-node heights
    are taken with bicubic sampling (see TTerrainBuilder.Build /
    TTerrainSampler.Create). Subdiv = 1 reproduces the exact old lattice. }
  if Subdiv < 1  then Subdiv := 1;
  if Subdiv > 16 then Subdiv := 16;
  Result.Subdiv  := Subdiv;
  Result.PitchPx := Result.Step / Subdiv;

  { Interior node count = original ((dim-1) div Step) scaled by Subdiv,
    plus the closing node. At Subdiv = 1 this equals the previous formula
    exactly, and the last node still lands on heightmap pixel
    ((dim-1) div Step)*Step, so the lattice extent is unchanged. }
  Result.NX := ((Result.HMW - 1) div Result.Step) * Subdiv + 1;
  Result.NZ := ((Result.HMH - 1) div Result.Step) * Subdiv + 1;
  if Result.NX < 2 then Result.NX := 2;
  if Result.NZ < 2 then Result.NZ := 2;

  Result.Valid := True;
end;

function TerrainGridNodeLatLon(const G: TTerrainGrid;
  JX, JZ: Integer): TLatLon;
var
  LocalX, LocalY: Double;
  GPX, GPY:       Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(342);{$ENDIF}
  { Sub-node position in heightmap pixels (fractional when Subdiv > 1). }
  LocalX := JX * G.PitchPx;
  if LocalX > G.HMW - 1 then LocalX := G.HMW - 1;
  LocalY := JZ * G.PitchPx;
  if LocalY > G.HMH - 1 then LocalY := G.HMH - 1;
  GPX := G.GPX0 + LocalX;
  GPY := G.GPY0 + LocalY;
  { X linear in longitude; Z through the Web-Mercator inverse — both
    purely global functions of the slippy pixel index. }
  Result.Lon := GPX / G.WorldPx * 360.0 - 180.0;
  Result.Lat := ArcTan(Sinh(Pi * (1.0 - 2.0 * GPY / G.WorldPx)))
                * RAD_TO_DEG;
end;

function BridgeMaskContains(const AMask: TBridgeSpanMask;
  X, Z: Single; WaterLevels: TWaterLevelField): Boolean;
var
  I: Integer;
  ax, az, bx, bz, dx, dz, l2, l, along, latd: Double;
  RoadWeight: Single;
  function CoversSurface(Index: Integer): Boolean;
  begin
    if not AMask[Index].MinorWater or (WaterLevels=nil) then Exit(True);
    if RoadWeight<0 then RoadWeight:=WaterLevels.RoadProtectionAt(X,Z);
    Result:=RoadWeight<1;
  end;
begin
  Result := False;
  RoadWeight := -1;
  for I := 0 to High(AMask) do
  begin
    ax := AMask[I].AX; az := AMask[I].AZ;
    bx := AMask[I].BX; bz := AMask[I].BZ;
    dx := bx - ax; dz := bz - az;
    l2 := dx * dx + dz * dz;
    if l2 < 1e-9 then
    begin
      { вырожденный сегмент — прежняя точечная проверка }
      if (Sqr(X - ax) + Sqr(Z - az) <= Sqr(AMask[I].HalfW)) and
         CoversSurface(I) then Exit(True);
      Continue;
    end;
    l := Sqrt(l2);
    { продольная позиция вдоль оси (м) и поперечное расстояние до оси:
      прямоугольник len+2·EndM × 2·HalfW — поперёк кроем всю насыпь,
      за торцы пролёта вытягиваемся лишь на EndM. }
    along := ((X - ax) * dx + (Z - az) * dz) / l;
    if (along < -AMask[I].EndM) or (along > l + AMask[I].EndM) then Continue;
    latd := Abs((X - ax) * dz - (Z - az) * dx) / l;
    if (latd <= AMask[I].HalfW) and CoversSurface(I) then Exit(True);
  end;
end;

constructor TRouteCorridor.Create(const APtsX, APtsZ: array of Single;
  ARadiusM: Single);
var
  I, N, C: Integer;
  MaxX, MaxZ: Single;
begin
  inherited Create;
  N := Length(APtsX);
  if Length(APtsZ) < N then N := Length(APtsZ);
  SetLength(FPtsX, N);
  SetLength(FPtsZ, N);
  for I := 0 to N - 1 do
  begin
    FPtsX[I] := APtsX[I];
    FPtsZ[I] := APtsZ[I];
  end;
  FRad := ARadiusM;
  if FRad < 0.1 then FRad := 0.1;
  FRad2 := FRad * FRad;
  { ячейка сетки = радиус: точка в пределах радиуса лежит в одной из 3×3
    соседних ячеек, поэтому запрос ограничен ими. }
  FInvCell := 1.0 / FRad;
  FCols := 0; FRows := 0;
  FMinX := 0; FMinZ := 0;
  if N = 0 then Exit;

  FMinX := FPtsX[0]; FMinZ := FPtsZ[0];
  MaxX  := FMinX;    MaxZ  := FMinZ;
  for I := 1 to N - 1 do
  begin
    if FPtsX[I] < FMinX then FMinX := FPtsX[I]
    else if FPtsX[I] > MaxX then MaxX := FPtsX[I];
    if FPtsZ[I] < FMinZ then FMinZ := FPtsZ[I]
    else if FPtsZ[I] > MaxZ then MaxZ := FPtsZ[I];
  end;
  FCols := Trunc((MaxX - FMinX) * FInvCell) + 1;  if FCols < 1 then FCols := 1;
  FRows := Trunc((MaxZ - FMinZ) * FInvCell) + 1;  if FRows < 1 then FRows := 1;
  SetLength(FHead, FCols * FRows);
  for I := 0 to High(FHead) do FHead[I] := -1;
  SetLength(FNext, N);
  for I := 0 to N - 1 do
  begin
    { (Pt - Min) >= 0, поэтому Trunc = Floor — корректная ячейка. }
    C := (Trunc((FPtsZ[I] - FMinZ) * FInvCell)) * FCols
       +  Trunc((FPtsX[I] - FMinX) * FInvCell);
    if (C < 0) or (C >= Length(FHead)) then Continue;
    FNext[I] := FHead[C];
    FHead[C] := I;
  end;
end;

function TRouteCorridor.Contains(X, Z: Single): Boolean;
var
  cx, cy, dx, dy, ncx, ncy, C, j: Integer;
  ddx, ddz: Single;
begin
  Result := False;
  if Length(FPtsX) = 0 then Exit;
  { Floor через приведение: запрос может лежать вне bbox (отрицательное
    смещение) — берём floor, чтобы соседняя граничная ячейка попала в 3×3. }
  cx := Floor((X - FMinX) * FInvCell);
  cy := Floor((Z - FMinZ) * FInvCell);
  for dy := -1 to 1 do
    for dx := -1 to 1 do
    begin
      ncx := cx + dx;  ncy := cy + dy;
      if (ncx < 0) or (ncx >= FCols) or (ncy < 0) or (ncy >= FRows) then Continue;
      C := ncy * FCols + ncx;
      j := FHead[C];
      while j <> -1 do
      begin
        ddx := X - FPtsX[j];
        ddz := Z - FPtsZ[j];
        if ddx * ddx + ddz * ddz <= FRad2 then Exit(True);
        j := FNext[j];
      end;
    end;
end;

function TRouteCorridor.Count: Integer;
begin
  Result := Length(FPtsX);
end;

class function TTerrainBuilder.Build(HM: THeightmap; Projection: TLocalProjection;
  GridStepMeters: Single; HeightmapZoom: Integer;
  Subdiv: Integer; AFitLayer: TFitHeightLayer;
  const AMask: TBridgeSpanMask; ACorridor: TRouteCorridor;
  AWaterLevels: TWaterLevelField): TMesh;
{ Vertices sit on the terrain lattice (TerrainGridOf): node (JX,JZ) is
  heightmap pixel (JX*PitchPx, JZ*PitchPx). At Subdiv=1 that pixel is integer
  and the height is read straight from it (bit-identical to the old lattice);
  at Subdiv>1 the sub-node falls between pixels and the height is sampled
  bicubically, giving a smooth C1 surface. The lattice is shared with
  TTerrainSampler (same Subdiv => same heights), so the surface and every
  SampleAt / clipper query agree; and it stays globally phased, so adjacent
  blocks share edge vertices exactly.
  Если AFitLayer активен — высота узла после сэмпла смешивается с FIT по гео
  узла (тот же вызов делает TTerrainSampler.Create → меш и сэмплер совпадают). }
var
  G:          TTerrainGrid;
  JX, JZ:     Integer;
  PxX, PxY:   Integer;
  LL:         TLatLon;
  H:          Single;
  H2:         Single;
  Pos:        TVector3;
  PXZ:        TVector3;
  Heights:    array of Single;
  IndexAt:    array of Integer;
  Stride:     Integer;
  dXL, dXR, dZU, dZD: Single;
  dNodeLon, dNodeLat: Double;
  dLonM, dLatM:       Double;
  Normal:     TVector3;
  I0, I1, I2, I3: Integer;
  NodeIn:     array of Boolean;   { route-only: узел в коридоре маршрута? }
  gNW, gNE, gSE, gSW: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1133);{$ENDIF}
  Result := nil;
  if (HM = nil) or (Projection = nil) then Exit;

  G := TerrainGridOf(HM, Projection, GridStepMeters, HeightmapZoom, Subdiv);
  if not G.Valid then Exit;

  { Degrees / metres between adjacent lattice nodes — for normals. Uses the
    (sub)node pitch so normals stay correct under oversampling. }
  dNodeLon := G.PitchPx * 360.0 / G.WorldPx;
  dNodeLat := (HM.Box.MaxLat - HM.Box.MinLat) * G.PitchPx / (G.HMH - 1);
  dLonM := Projection.MetersPerDegreeLon * dNodeLon;
  dLatM := Projection.MetersPerDegreeLat * dNodeLat;

  Result := TMesh.Create('terrain');
  try
    Result.ReserveVertices(G.NX * G.NZ);
    Result.ReserveIndices((G.NX - 1) * (G.NZ - 1) * 6);

    SetLength(Heights, G.NX * G.NZ);
    SetLength(IndexAt, G.NX * G.NZ);
    if ACorridor <> nil then
      SetLength(NodeIn, G.NX * G.NZ);   { route-only: флаг «узел в коридоре» }

    { Pass 1: one vertex per lattice node. }
    for JZ := 0 to G.NZ - 1 do
    begin
      PxY := JZ * G.Step;
      if PxY > G.HMH - 1 then PxY := G.HMH - 1;
      for JX := 0 to G.NX - 1 do
      begin
        { Height: Subdiv=1 reads the exact pixel (bit-identical to the old
          lattice); Subdiv>1 samples bicubically between pixels. Position
          from the global lattice geo-coordinate either way. }
        if G.Subdiv <= 1 then
        begin
          PxX := JX * G.Step;
          if PxX > G.HMW - 1 then PxX := G.HMW - 1;
          H := HM.Sample[PxX, PxY];
        end
        else
          H := THeightmapSampler.CubicSamplePx(HM,
                 JX * G.PitchPx, JZ * G.PitchPx);
        LL := TerrainGridNodeLatLon(G, JX, JZ);
        { FIT-коррекция высоты узла: НИЖНИЙ уровень FIT, смешанный с DEM (на
          полотне точный FIT, за кромкой феатер к DEM, вне коридора — H).
          Под пролётом моста (маска) земля остаётся на чистом DEM / нижней
          дороге развязки, без насыпи-двойника. Тот же вызов и та же маска в
          TTerrainSampler.Create → меш и сэмплер совпадают бит-в-бит. }
        if (AFitLayer <> nil) and AFitLayer.Active then
        begin
          H2 := AFitLayer.GroundHeightGeo(LL, H, False);   { FIT-земля без маски }
          if (H2 <> H) and (Length(AMask) > 0) then
          begin
            { маску проверяем ТОЛЬКО на FIT-поднятых узлах (перф: водотоков в
              маске много); под маской земля → DEM/нижний уровень. }
            PXZ := Projection.Project(LL, 0);
            if BridgeMaskContains(AMask, PXZ.X, PXZ.Z, AWaterLevels) then
              H2 := AFitLayer.GroundHeightGeo(LL, H, True);
          end;
          H := H2;
        end;

        if AWaterLevels <> nil then H := AWaterLevels.ApplyGeo(LL, H);
        Heights[JZ * G.NX + JX] := H;
        Pos := Projection.Project(LL, H);
        IndexAt[JZ * G.NX + JX] := Result.AddVertex(Pos);
        if ACorridor <> nil then
          NodeIn[JZ * G.NX + JX] := ACorridor.Contains(Pos.X, Pos.Z);
      end;
    end;

    { Pass 2: per-interior-node normal from finite differences.
      Edge nodes keep the (0,1,0) default. }
    Stride := G.NX;
    for JZ := 0 to G.NZ - 1 do
      for JX := 0 to G.NX - 1 do
      begin
        if (JX = 0) or (JX = G.NX - 1) or
           (JZ = 0) or (JZ = G.NZ - 1) then
          Continue;

        dXL := Heights[JZ * Stride + (JX - 1)];
        dXR := Heights[JZ * Stride + (JX + 1)];
        dZU := Heights[(JZ - 1) * Stride + JX];   { northern = lower JZ }
        dZD := Heights[(JZ + 1) * Stride + JX];   { southern = higher JZ }

        Normal.X := (dXR - dXL) * Single(dLatM);
        Normal.Y := Single(dLonM * dLatM);
        Normal.Z := -Single(dLonM) * (dZD - dZU);

        H := Sqrt(Normal.X * Normal.X + Normal.Y * Normal.Y
                + Normal.Z * Normal.Z);
        if H > 1.0e-12 then
        begin
          Normal.X := Normal.X / H;
          Normal.Y := Normal.Y / H;
          Normal.Z := Normal.Z / H;
          Result.SetVertexNormal(IndexAt[JZ * Stride + JX], Normal);
        end;
      end;

    { CCW from above (+Y), normals up. }
    for JZ := 0 to G.NZ - 2 do
      for JX := 0 to G.NX - 2 do
      begin
        I0 := IndexAt[ JZ      * Stride + JX    ];   { NW }
        I1 := IndexAt[ JZ      * Stride + JX + 1];   { NE }
        I2 := IndexAt[(JZ + 1) * Stride + JX + 1];   { SE }
        I3 := IndexAt[(JZ + 1) * Stride + JX    ];   { SW }
        if ACorridor = nil then
        begin
          Result.AddTriangle(I0, I3, I2);
          Result.AddTriangle(I0, I2, I1);
        end
        else
        begin
          { Route-only: оставляем треугольник, только если ХОТЯ БЫ одна его
            вершина в коридоре маршрута (все вершины вне — отбрасываем). }
          gNW := JZ * Stride + JX;         gNE := JZ * Stride + JX + 1;
          gSE := (JZ + 1) * Stride + JX + 1; gSW := (JZ + 1) * Stride + JX;
          if NodeIn[gNW] or NodeIn[gSW] or NodeIn[gSE] then
            Result.AddTriangle(I0, I3, I2);   { NW, SW, SE }
          if NodeIn[gNW] or NodeIn[gSE] or NodeIn[gNE] then
            Result.AddTriangle(I0, I2, I1);   { NW, SE, NE }
        end;
      end;

  except
    Result.Free;
    raise;
  end;
end;

class function TFarTerrainBuilder.Build(FarHM: THeightmap;
  Projection: TLocalProjection; const MainBbox: TLatLonBox;
  GridStepMeters: Single): TMesh;
var
  Box: TLatLonBox;
  CornerSW, CornerNE: TVector3;
  WidthM, DepthM: Single;
  GridX, GridZ: Integer;
  IX, IZ: Integer;
  T: Single;
  P: TLatLon;
  H: Single;
  Pos: TVector3;
  IndexAt: array of array of Integer;
  I0, I1, I2, I3: Integer;
  AnyTri: Boolean;
  { FAR_DEPRESS_M (far-mesh depression below the heightmap, anti
    z-fight vs the distance-discarded composite ring) now lives in
    Osm3dStudioSettings — consolidated spatial tuning. }
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1134);{$ENDIF}
  Result := nil;
  if (FarHM = nil) or (Projection = nil) then Exit;
  { Reference MainBbox to silence H5024 — bbox-skip path superseded
    by the depression approach. }
  if MainBbox.IsEmpty then ;

  Box := FarHM.Box;
  if Box.IsEmpty then Exit;

  CornerSW := Projection.Project(TLatLon.Make(Box.MinLat, Box.MinLon));
  CornerNE := Projection.Project(TLatLon.Make(Box.MaxLat, Box.MaxLon));
  WidthM := Abs(CornerNE.X - CornerSW.X);
  DepthM := Abs(CornerNE.Z - CornerSW.Z);

  if (WidthM < 1) or (DepthM < 1) then Exit;
  if GridStepMeters < 5 then GridStepMeters := 5;

  GridX := Ceil(WidthM / GridStepMeters) + 1;
  GridZ := Ceil(DepthM / GridStepMeters) + 1;
  if GridX < 2 then GridX := 2;
  if GridZ < 2 then GridZ := 2;

  Result := TMesh.Create('far_terrain');
  AnyTri := False;
  try
    SetLength(IndexAt, GridZ);
    for IZ := 0 to GridZ - 1 do
    begin
      SetLength(IndexAt[IZ], GridX);
      for IX := 0 to GridX - 1 do
      begin
        T := IX / (GridX - 1);
        P.Lon := Box.MinLon + T * (Box.MaxLon - Box.MinLon);
        T := IZ / (GridZ - 1);
        P.Lat := Box.MaxLat - T * (Box.MaxLat - Box.MinLat);

        H := THeightmapSampler.SampleBilinear(FarHM, P);
        H := H - FAR_DEPRESS_M;

        Pos := Projection.Project(P, H);
        IndexAt[IZ][IX] := Result.AddVertex(Pos);
      end;
    end;

    for IZ := 0 to GridZ - 2 do
      for IX := 0 to GridX - 2 do
      begin
        I0 := IndexAt[IZ    ][IX    ];   { NW }
        I1 := IndexAt[IZ    ][IX + 1];   { NE }
        I2 := IndexAt[IZ + 1][IX + 1];   { SE }
        I3 := IndexAt[IZ + 1][IX    ];   { SW }
        Result.AddTriangle(I0, I3, I2);
        Result.AddTriangle(I0, I2, I1);
        AnyTri := True;
      end;

    if not AnyTri then
    begin
      Result.Free;
      Exit(nil);
    end;

    Result.ComputeSmoothNormals;
  except
    Result.Free;
    raise;
  end;
end;

constructor TTerrainSampler.Create(HM: THeightmap;
  Projection: TLocalProjection; GridStepMeters: Single;
  HeightmapZoom: Integer; Subdiv: Integer; AFitLayer: TFitHeightLayer;
  const AMask: TBridgeSpanMask; AWaterLevels: TWaterLevelField);
var
  IX, IZ:   Integer;
  PxX, PxY: Integer;
  H, H2:    Single;
  LL:       TLatLon;
  V:        TVector3;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1135);{$ENDIF}
  inherited Create;
  FWaterLevels := AWaterLevels;
  FNodePosReady := False;
  FCorrectedNodes := 0;
  FMaskedNodes := 0;

  { Identical lattice to TTerrainBuilder.Build — same Subdiv, hence the same
    nodes and the same node heights, so SampleAt returns exactly the terrain
    mesh surface. }
  FGrid := TerrainGridOf(HM, Projection, GridStepMeters, HeightmapZoom, Subdiv);
  if not FGrid.Valid then
  begin
    FBox   := TLatLonBox.Empty;
    FGridX := 2;
    FGridZ := 2;
    SetLength(FHeights, FGridX * FGridZ);   { all zeroes }
    SetLength(FHeightsRaw, FGridX * FGridZ);
    Exit;
  end;

  FBox   := HM.Box;
  FGridX := FGrid.NX;
  FGridZ := FGrid.NZ;
  SetLength(FHeights, FGridZ * FGridX);
  SetLength(FHeightsRaw, FGridZ * FGridX);

  { Node height — the very same value TTerrainBuilder.Build puts into the
    matching mesh vertex (same Subdiv => same pitch => same sample). Subdiv=1
    reads the exact pixel; Subdiv>1 samples bicubically between pixels. }
  for IZ := 0 to FGridZ - 1 do
  begin
    PxY := IZ * FGrid.Step;
    if PxY > FGrid.HMH - 1 then PxY := FGrid.HMH - 1;
    for IX := 0 to FGridX - 1 do
    begin
      if FGrid.Subdiv <= 1 then
      begin
        PxX := IX * FGrid.Step;
        if PxX > FGrid.HMW - 1 then PxX := FGrid.HMW - 1;
        H := HM.Sample[PxX, PxY];
      end
      else
        H := THeightmapSampler.CubicSamplePx(HM, IX * FGrid.PitchPx, IZ * FGrid.PitchPx);
      FHeightsRaw[IZ * FGridX + IX] := H;   { сырой DEM ДО коррекции }
      { FIT-коррекция ТЕМ ЖЕ порядком и той же маской, что TTerrainBuilder.Build
        — сэмплер совпадает с мешем бит-в-бит. Маску (пролёты мостов + водотоки)
        проверяем ТОЛЬКО на FIT-поднятых узлах: перф (сегментов много) и смысл
        (на не-FIT узле земля и так = DEM). Под маской земля → DEM/нижний
        уровень: воздух под мостом, вода не под насыпью. }
      if (AFitLayer <> nil) and AFitLayer.Active then
      begin
        LL := TerrainGridNodeLatLon(FGrid, IX, IZ);
        H2 := AFitLayer.GroundHeightGeo(LL, H, False);   { FIT-земля без маски }
        if H2 <> H then
        begin
          Inc(FCorrectedNodes);
          if Length(AMask) > 0 then
          begin
            V := Projection.Project(LL, 0);
            if BridgeMaskContains(AMask, V.X, V.Z, AWaterLevels) then
            begin
              H2 := AFitLayer.GroundHeightGeo(LL, H, True);
              Inc(FMaskedNodes);
            end;
          end;
        end;
        H := H2;
      end;
      FHeights[IZ * FGridX + IX] := H;
    end;
  end;
end;

destructor TTerrainSampler.Destroy;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1136);{$ENDIF}
  FHeights := nil;
  FHeightsRaw := nil;
  FNodeX   := nil;
  FNodeZ   := nil;
  inherited;
end;

function TTerrainSampler.NodeHeight(IX, IZ: Integer): Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(334);{$ENDIF}
  if IX < 0 then IX := 0;
  if IX >= FGridX then IX := FGridX - 1;
  if IZ < 0 then IZ := 0;
  if IZ >= FGridZ then IZ := FGridZ - 1;
  Result := FHeights[IZ * FGridX + IX];
  if FWaterLevels <> nil then
    Result := FWaterLevels.ApplyGeo(NodeLatLon(IX, IZ), Result);
end;

function TTerrainSampler.NodeLatLon(IX, IZ: Integer): TLatLon;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(343);{$ENDIF}
  if IX < 0 then IX := 0;
  if IX >= FGridX then IX := FGridX - 1;
  if IZ < 0 then IZ := 0;
  if IZ >= FGridZ then IZ := FGridZ - 1;
  Result := TerrainGridNodeLatLon(FGrid, IX, IZ);
end;

procedure TTerrainSampler.PrecomputeNodePositions(Projection: TLocalProjection);
var
  IX, IZ, Idx: Integer;
  V: TVector3;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(335);{$ENDIF}
  if FNodePosReady then Exit;       { idempotent }
  if Projection = nil then Exit;
  if (not FGrid.Valid) or (FGridX < 2) or (FGridZ < 2) then Exit;

  SetLength(FNodeX, FGridZ * FGridX);
  SetLength(FNodeZ, FGridZ * FGridX);

  { Each node projected from its lattice geo-coordinate — the exact
    XZ of the matching terrain mesh vertex. }
  for IZ := 0 to FGridZ - 1 do
    for IX := 0 to FGridX - 1 do
    begin
      V := Projection.Project(TerrainGridNodeLatLon(FGrid, IX, IZ), 0);
      Idx := IZ * FGridX + IX;
      FNodeX[Idx] := V.X;
      FNodeZ[Idx] := V.Z;
    end;

  FNodePosReady := True;
end;

function TTerrainSampler.NodePositionXZ(IX, IZ: Integer; out X, Z: Single): Boolean;
var Idx: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(336);{$ENDIF}
  if not FNodePosReady then
  begin
    Result := False;
    Exit;
  end;
  if IX < 0 then IX := 0;
  if IX >= FGridX then IX := FGridX - 1;
  if IZ < 0 then IZ := 0;
  if IZ >= FGridZ then IZ := FGridZ - 1;
  Idx := IZ * FGridX + IX;
  X := FNodeX[Idx];
  Z := FNodeZ[Idx];
  Result := True;
end;

procedure TTerrainSampler.CellHeights4(IX, IZ: Integer;
  out hNW, hNE, hSE, hSW: Single);
var ix0, ix1, iz0, iz1, rz0, rz1: Integer;
begin
  ix0 := IX;     if ix0 < 0 then ix0 := 0 else if ix0 >= FGridX then ix0 := FGridX - 1;
  ix1 := IX + 1; if ix1 < 0 then ix1 := 0 else if ix1 >= FGridX then ix1 := FGridX - 1;
  iz0 := IZ;     if iz0 < 0 then iz0 := 0 else if iz0 >= FGridZ then iz0 := FGridZ - 1;
  iz1 := IZ + 1; if iz1 < 0 then iz1 := 0 else if iz1 >= FGridZ then iz1 := FGridZ - 1;
  rz0 := iz0 * FGridX;
  rz1 := iz1 * FGridX;
  hNW := FHeights[rz0 + ix0];
  hNE := FHeights[rz0 + ix1];
  hSE := FHeights[rz1 + ix1];
  hSW := FHeights[rz1 + ix0];
  if FWaterLevels <> nil then
  begin
    hNW := NodeHeight(ix0, iz0);
    hNE := NodeHeight(ix1, iz0);
    hSE := NodeHeight(ix1, iz1);
    hSW := NodeHeight(ix0, iz1);
  end;
end;

function TTerrainSampler.CellPositions4(IX, IZ: Integer;
  out pNWx, pNWz, pNEx, pNEz, pSEx, pSEz, pSWx, pSWz: Single): Boolean;
var ix0, ix1, iz0, iz1, rz0, rz1: Integer;
begin
  if not FNodePosReady then
  begin
    Result := False;
    Exit;
  end;
  ix0 := IX;     if ix0 < 0 then ix0 := 0 else if ix0 >= FGridX then ix0 := FGridX - 1;
  ix1 := IX + 1; if ix1 < 0 then ix1 := 0 else if ix1 >= FGridX then ix1 := FGridX - 1;
  iz0 := IZ;     if iz0 < 0 then iz0 := 0 else if iz0 >= FGridZ then iz0 := FGridZ - 1;
  iz1 := IZ + 1; if iz1 < 0 then iz1 := 0 else if iz1 >= FGridZ then iz1 := FGridZ - 1;
  rz0 := iz0 * FGridX;
  rz1 := iz1 * FGridX;
  pNWx := FNodeX[rz0 + ix0]; pNWz := FNodeZ[rz0 + ix0];
  pNEx := FNodeX[rz0 + ix1]; pNEz := FNodeZ[rz0 + ix1];
  pSEx := FNodeX[rz1 + ix1]; pSEz := FNodeZ[rz1 + ix1];
  pSWx := FNodeX[rz1 + ix0]; pSWz := FNodeZ[rz1 + ix0];
  Result := True;
end;

function TTerrainSampler.SampleAtXZ(Projection: TLocalProjection;
  X, Z: Single): Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(337);{$ENDIF}
  if Projection = nil then Exit(0);
  Result := SampleAt(Projection.Unproject(X, Z));
end;

function TTerrainSampler.SampleRawAt(const P: TLatLon): Single;
var
  FX, FZ, tx, tz: Double;
  ix0, iz0, ix1, iz1: Integer;
  hNW, hNE, hSE, hSW, hN, hS: Single;
begin
  { Билинейный сэмпл СЫРОГО DEM (FHeightsRaw) по той же решётке и тому же
    world→grid отображению (LatLonToCellFrac), что и остальные сэмплы. }
  if Length(FHeightsRaw) = 0 then Exit(0);
  LatLonToCellFrac(P, FX, FZ);
  if FX < 0 then FX := 0 else if FX > FGridX - 1 then FX := FGridX - 1;
  if FZ < 0 then FZ := 0 else if FZ > FGridZ - 1 then FZ := FGridZ - 1;
  ix0 := Trunc(FX); if ix0 > FGridX - 2 then ix0 := FGridX - 2; if ix0 < 0 then ix0 := 0;
  iz0 := Trunc(FZ); if iz0 > FGridZ - 2 then iz0 := FGridZ - 2; if iz0 < 0 then iz0 := 0;
  ix1 := ix0 + 1; iz1 := iz0 + 1;
  tx := FX - ix0; tz := FZ - iz0;
  if tx < 0 then tx := 0 else if tx > 1 then tx := 1;
  if tz < 0 then tz := 0 else if tz > 1 then tz := 1;
  hNW := FHeightsRaw[iz0 * FGridX + ix0];
  hNE := FHeightsRaw[iz0 * FGridX + ix1];
  hSW := FHeightsRaw[iz1 * FGridX + ix0];
  hSE := FHeightsRaw[iz1 * FGridX + ix1];
  hN := hNW + (hNE - hNW) * Single(tx);
  hS := hSW + (hSE - hSW) * Single(tx);
  Result := hN + (hS - hN) * Single(tz);
end;

function TTerrainSampler.SampleRawAtXZ(Projection: TLocalProjection;
  X, Z: Single): Single;
begin
  if Projection = nil then Exit(0);
  Result := SampleRawAt(Projection.Unproject(X, Z));
end;

procedure TTerrainSampler.LatLonToCellFrac(const P: TLatLon;
  out FX, FZ: Double);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1457);{$ENDIF}
  { Map a geo point to a fractional lattice node the SAME way
    TTerrainBuilder places vertices (TerrainGridNodeLatLon): longitude
    is linear in the global pixel grid, latitude goes through the
    Web-Mercator forward transform. Dividing the global pixel offset by
    Step gives the fractional node. Degenerate grid -> box-linear. }
  if FGrid.Valid then
  begin
    FX := ((P.Lon + 180.0) / 360.0 * FGrid.WorldPx - FGrid.GPX0)
          / FGrid.PitchPx;
    FZ := ((1.0 - Ln(Tan(P.Lat * DEG_TO_RAD)
            + 1.0 / Cos(P.Lat * DEG_TO_RAD)) / Pi)
           / 2.0 * FGrid.WorldPx - FGrid.GPY0)
          / FGrid.PitchPx;
  end
  else
  begin
    if (FBox.MaxLon - FBox.MinLon) > 0 then
      FX := (P.Lon - FBox.MinLon) / (FBox.MaxLon - FBox.MinLon) * (FGridX - 1)
    else
      FX := 0;
    if (FBox.MaxLat - FBox.MinLat) > 0 then
      FZ := (FBox.MaxLat - P.Lat) / (FBox.MaxLat - FBox.MinLat) * (FGridZ - 1)
    else
      FZ := 0;
  end;
end;

function TTerrainSampler.WorldToCellFrac(Projection: TLocalProjection;
  X, Z: Single; out FX, FZ: Double): Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1458);{$ENDIF}
  if Projection = nil then
  begin
    FX := 0; FZ := 0;
    Exit(False);
  end;
  LatLonToCellFrac(Projection.Unproject(X, Z), FX, FZ);
  Result := True;
end;

function TTerrainSampler.SampleAt(const P: TLatLon): Single;
var
  CellFX, CellFZ: Double;
  CellX, CellZ: Integer;
  FX, FZ: Single;
  H_NW, H_NE, H_SE, H_SW: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(338);{$ENDIF}
  if Length(FHeights) = 0 then Exit(0);

  { Single mapping definition — see LatLonToCellFrac. SampleAt and the
    clipper's cell enumeration share it, so a clipped overlay always
    lands on the cells the terrain mesh actually rendered. }
  LatLonToCellFrac(P, CellFX, CellFZ);

  if CellFX < 0 then CellFX := 0;
  if CellFX > FGridX - 1 then CellFX := FGridX - 1;
  if CellFZ < 0 then CellFZ := 0;
  if CellFZ > FGridZ - 1 then CellFZ := FGridZ - 1;

  CellX := Floor(CellFX);
  CellZ := Floor(CellFZ);

  { At the boundary CellFX = GridX-1 → use the previous cell (FX = 1.0). }
  if CellX >= FGridX - 1 then CellX := FGridX - 2;
  if CellZ >= FGridZ - 1 then CellZ := FGridZ - 2;
  if CellX < 0 then CellX := 0;
  if CellZ < 0 then CellZ := 0;

  FX := CellFX - CellX;
  FZ := CellFZ - CellZ;

  { 4 corner heights, layout H[Z*GridX+X]:
      NW=(X,Z) NE=(X+1,Z) SE=(X+1,Z+1) SW=(X,Z+1)
    TTerrainBuilder splits cell along NW→SE diagonal into 2 triangles:
      T1 (NW,SW,SE) where FZ >= FX (below diagonal)
      T2 (NW,SE,NE) where FZ <  FX (above diagonal)
    Barycentric T1: Y = (1-FZ)*HNW + (FZ-FX)*HSW + FX*HSE
    Barycentric T2: Y = (1-FX)*HNW + (FX-FZ)*HNE + FZ*HSE }
  H_NW := FHeights[(CellZ    ) * FGridX + (CellX    )];
  H_NE := FHeights[(CellZ    ) * FGridX + (CellX + 1)];
  H_SE := FHeights[(CellZ + 1) * FGridX + (CellX + 1)];
  H_SW := FHeights[(CellZ + 1) * FGridX + (CellX    )];

  if FZ >= FX then
    Result := (1 - FZ) * H_NW + (FZ - FX) * H_SW + FX * H_SE
  else
    Result := (1 - FX) * H_NW + (FX - FZ) * H_NE + FZ * H_SE;
  { Evaluate after interpolation: even a pond smaller than a DEM cell
    gets one exact level; interpolating corrected nodes would tilt it. }
  if FWaterLevels <> nil then Result := FWaterLevels.ApplyGeo(P, Result);
end;

function TTerrainSampler.SampleAtCubic(const P: TLatLon): Single;
var
  CellFX, CellFZ: Double;
  CellX, CellZ, j: Integer;
  FX, FZ: Single;
  col: array[0..3] of Single;
  cx, cz: array[0..3] of Integer;
  rz, mm: Integer;

  function HAt(IX, IZ: Integer): Single;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1459);{$ENDIF}
    if IX < 0 then IX := 0
    else if IX > FGridX - 1 then IX := FGridX - 1;
    if IZ < 0 then IZ := 0
    else if IZ > FGridZ - 1 then IZ := FGridZ - 1;
    Result := FHeights[IZ * FGridX + IX];
  end;

  { Catmull-Rom through p1,p2 (t in [0,1]); t=0 -> p1, t=1 -> p2. }
  { Approximating cubic B-spline — matches CubicSamplePx in Osm3dHeightmap.
    Smooths the integer-metre source staircase instead of reproducing it, so
    the terrain normals (SmoothCompositeNormals samples this via central
    differences) get no step banding and no overshoot ripple. }
  function CR(p0, p1, p2, p3, t: Single): Single;
  var
    t2, t3, w0, w1, w2, w3: Single;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1460);{$ENDIF}
    t2 := t * t;
    t3 := t2 * t;
    w0 := (1.0 - 3.0*t + 3.0*t2 - t3) / 6.0;
    w1 := (4.0 - 6.0*t2 + 3.0*t3) / 6.0;
    w2 := (1.0 + 3.0*t + 3.0*t2 - 3.0*t3) / 6.0;
    w3 := t3 / 6.0;
    Result := w0*p0 + w1*p1 + w2*p2 + w3*p3;
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1315);{$ENDIF}
  if Length(FHeights) = 0 then Exit(0);

  { Same mapping as SampleAt so node values agree; cubic only smooths
    between nodes. }
  LatLonToCellFrac(P, CellFX, CellFZ);
  if CellFX < 0 then CellFX := 0
  else if CellFX > FGridX - 1 then CellFX := FGridX - 1;
  if CellFZ < 0 then CellFZ := 0
  else if CellFZ > FGridZ - 1 then CellFZ := FGridZ - 1;

  CellX := Floor(CellFX);
  CellZ := Floor(CellFZ);
  if CellX > FGridX - 1 then CellX := FGridX - 1;
  if CellZ > FGridZ - 1 then CellZ := FGridZ - 1;

  FX := CellFX - CellX;
  FZ := CellFZ - CellZ;

  { Precompute the 4 clamped X and 4 clamped Z indices ONCE (identical clamp to
    HAt) and read FHeights directly, replacing 16 HAt calls per sample. }
  for mm := 0 to 3 do
  begin
    cx[mm] := CellX - 1 + mm;
    if cx[mm] < 0 then cx[mm] := 0 else if cx[mm] > FGridX - 1 then cx[mm] := FGridX - 1;
    cz[mm] := CellZ - 1 + mm;
    if cz[mm] < 0 then cz[mm] := 0 else if cz[mm] > FGridZ - 1 then cz[mm] := FGridZ - 1;
  end;

  { 4 rows along Z; each interpolated along X at FX, then the rows along Z. }
  for j := 0 to 3 do
  begin
    rz := cz[j] * FGridX;
    col[j] := CR(FHeights[rz + cx[0]], FHeights[rz + cx[1]],
                 FHeights[rz + cx[2]], FHeights[rz + cx[3]], FX);
  end;
  Result := CR(col[0], col[1], col[2], col[3], FZ);
  if FWaterLevels <> nil then Result := FWaterLevels.ApplyGeo(P, Result);
end;

function TTerrainSampler.SampleAtXZCubic(Projection: TLocalProjection;
  X, Z: Single): Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1461);{$ENDIF}
  if Projection = nil then Exit(0);
  Result := SampleAtCubic(Projection.Unproject(X, Z));
end;

function MakeXZ(X, Z: Double): TXZ; inline;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1462);{$ENDIF}
  Result := XZ(X, Z);
end;

const

  { Порог удвоенной площади (м²·2) для отбраковки треугольников-«иголок»
    в разбиении ленты дороги: |cross| ниже — треугольник вырожден. }
  RIBBON_DEGENERATE_AREA2 = 1e-3;
  PROGRESS_INTERVAL_MS = 5000;

procedure InitClipperProgress(out P: TClipperProgress;
  LogProc: TLogProc; const Context: string;
  PolyTotal: Integer);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(340);{$ENDIF}
  P.LogProc    := LogProc;
  P.LastTickMs := GetTickCount64;
  P.Context    := Context;
  P.PolyIdx    := 0;
  P.PolyTotal  := PolyTotal;
  P.TriIdx     := 0;
  P.TriTotal   := 0;
end;

procedure ReportClipperProgress(var P: TClipperProgress;
  const ExtraMsg: string = '');
var
  Now: QWord;
  Msg: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1316);{$ENDIF}
  if not Assigned(P.LogProc) then Exit;
  Now := GetTickCount64;
  if Now - P.LastTickMs < PROGRESS_INTERVAL_MS then Exit;
  P.LastTickMs := Now;

  Msg := '  ';
  if P.Context <> '' then Msg := Msg + P.Context + ': ';
  if P.PolyTotal > 0 then
    Msg := Msg + Format('poly %d/%d', [P.PolyIdx, P.PolyTotal]);
  if P.TriTotal > 0 then
  begin
    if P.PolyTotal > 0 then Msg := Msg + ', ';
    Msg := Msg + Format('tri %d/%d', [P.TriIdx, P.TriTotal]);
  end;
  if ExtraMsg <> '' then Msg := Msg + ' (' + ExtraMsg + ')';

  P.LogProc(Msg);
end;

function TriAreaSigned(const A, B, C: TXZ): Double; inline;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1463);{$ENDIF}
  Result := XZCross(A, B, C);
end;

function PointInTriangle(const P, A, B, C: TXZ): Boolean; inline;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1464);{$ENDIF}
  Result := XZPointInTriangle(P, A, B, C);
end;

function SegSegIntersection(const A1, A2, B1, B2: TXZ;
  out IP: TXZ): Boolean;
var
  x1, z1, x2, z2, x3, z3, x4, z4, Denom, Ua, Ub: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(344);{$ENDIF}
  Result := False;
  x1 := A1.X; z1 := A1.Z;
  x2 := A2.X; z2 := A2.Z;
  x3 := B1.X; z3 := B1.Z;
  x4 := B2.X; z4 := B2.Z;

  if ((x1 = x2) and (z1 = z2)) or ((x3 = x4) and (z3 = z4)) then Exit;

  Denom := (z4 - z3) * (x2 - x1) - (x4 - x3) * (z2 - z1);
  if Denom = 0 then Exit;

  Ua := ((x4 - x3) * (z1 - z3) - (z4 - z3) * (x1 - x3)) / Denom;
  Ub := ((x2 - x1) * (z1 - z3) - (z2 - z1) * (x1 - x3)) / Denom;
  if (Ua < 0) or (Ua > 1) or (Ub < 0) or (Ub > 1) then Exit;

  IP.X := x1 + Ua * (x2 - x1);
  IP.Z := z1 + Ua * (z2 - z1);
  Result := True;
end;

procedure OrderConvexPolygonPoints(var Pts: TXZArray; N: Integer);
type
  TKey = record P: TXZ; A: Double; end;
var
  Mx, Mz: Double;
  Keys: array[0..63] of TKey;  { stack: sole caller IntersectTriangles emits <=6+9 pts }
  I, J: Integer;
  Tmp: TKey;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(345);{$ENDIF}
  if N <= 2 then Exit;
  Mx := 0;
  Mz := 0;
  for I := 0 to N - 1 do
  begin
    Mx := Mx + Pts[I].X;
    Mz := Mz + Pts[I].Z;
  end;
  Mx := Mx / N;
  Mz := Mz / N;

  for I := 0 to N - 1 do
  begin
    Keys[I].P := Pts[I];
    Keys[I].A := ArcTan2(Pts[I].Z - Mz, Pts[I].X - Mx);
  end;

  for I := 1 to N - 1 do
  begin
    Tmp := Keys[I];
    J := I - 1;
    while (J >= 0) and (Keys[J].A > Tmp.A) do
    begin
      Keys[J + 1] := Keys[J];
      Dec(J);
    end;
    Keys[J + 1] := Tmp;
  end;

  for I := 0 to N - 1 do
    Pts[I] := Keys[I].P;
end;

procedure IntersectTriangles(
  const T1, T2: array of TXZ;
  out OutPts: TXZArray; out OutN: Integer);

  procedure AddPoint(const P: TXZ);
  var K: Integer;
  const EPS = 1e-9;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(347);{$ENDIF}
    for K := 0 to OutN - 1 do
      if (Abs(OutPts[K].X - P.X) < EPS) and (Abs(OutPts[K].Z - P.Z) < EPS) then
        Exit;
    if OutN >= Length(OutPts) then SetLength(OutPts, OutN * 2 + 8);
    OutPts[OutN] := P;
    Inc(OutN);
  end;

var
  I, J: Integer;
  IP: TXZ;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(346);{$ENDIF}
  OutN := 0;
  SetLength(OutPts, 8);

  for I := 0 to 2 do
    if PointInTriangle(T1[I], T2[0], T2[1], T2[2]) then AddPoint(T1[I]);
  for I := 0 to 2 do
    if PointInTriangle(T2[I], T1[0], T1[1], T1[2]) then AddPoint(T2[I]);

  for I := 0 to 2 do
    for J := 0 to 2 do
      if SegSegIntersection(T1[I], T1[(I + 1) mod 3],
                            T2[J], T2[(J + 1) mod 3], IP) then
        AddPoint(IP);

  if OutN >= 3 then
    OrderConvexPolygonPoints(OutPts, OutN);

  SetLength(OutPts, OutN);
end;


function Barycentric(const P, A, B, C: TXZ;
  out U, V, W: Double): Boolean; inline;
var v0x, v0z, v1x, v1z, v2x, v2z, Den: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(348);{$ENDIF}
  v0x := B.X - A.X;  v0z := B.Z - A.Z;
  v1x := C.X - A.X;  v1z := C.Z - A.Z;
  v2x := P.X - A.X;  v2z := P.Z - A.Z;
  Den := v0x * v1z - v1x * v0z;
  if Abs(Den) < 1e-18 then
  begin
    U := 1; V := 0; W := 0;
    Exit(False);
  end;
  V := (v2x * v1z - v1x * v2z) / Den;
  W := (v0x * v2z - v2x * v0z) / Den;
  U := 1 - V - W;
  Result := True;
end;

function YOnTriangle(const P, A, B, C: TXZ;
  hA, hB, hC: Single): Double; inline;
var U, V, W: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(349);{$ENDIF}
  Barycentric(P, A, B, C, U, V, W);
  Result := U * hA + V * hB + W * hC;
end;

{ Smooth normal at P inside triangle A/B/C — barycentric blend of the three
  corner normals with the SAME weights YOnTriangle uses for the height, then
  renormalised. Adjacent cells share corner-node normals, so the result is
  continuous across cell edges (no per-cell faceting). }
function NormalOnTriangle(const P, A, B, C: TXZ;
  const nA, nB, nC: TVector3): TVector3; inline;
var U, V, W: Double; Len: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1479);{$ENDIF}
  Barycentric(P, A, B, C, U, V, W);
  Result.X := U * nA.X + V * nB.X + W * nC.X;
  Result.Y := U * nA.Y + V * nB.Y + W * nC.Y;
  Result.Z := U * nA.Z + V * nB.Z + W * nC.Z;
  Len := Sqrt(Result.X * Result.X + Result.Y * Result.Y + Result.Z * Result.Z);
  if Len > 1e-9 then
  begin
    Result.X := Result.X / Len;
    Result.Y := Result.Y / Len;
    Result.Z := Result.Z / Len;
  end
  else
    Result := Vector3(0, 1, 0);
end;

type
  TCellPos = record IX, IZ: Integer; end;
  TCellPosArray = array of TCellPos;

  { Контекст обхода WalkGridCells для RasterizeLineCells: append в
    caller-буфер с ростом удвоением (без аллокаций на горячем пути). }
  TRasterizeLineCtx = record
    EdgeCells: ^TCellPosArray;
    EdgeN:     ^Integer;
  end;

procedure RasterizeLineVisit(AX, AZ: Integer; Ctx: Pointer);
var
  C: ^TRasterizeLineCtx;
begin
  C := Ctx;
  if C^.EdgeN^ >= Length(C^.EdgeCells^) then
    SetLength(C^.EdgeCells^, C^.EdgeN^ * 2 + 16);
  C^.EdgeCells^[C^.EdgeN^].IX := AX;
  C^.EdgeCells^[C^.EdgeN^].IZ := AZ;
  Inc(C^.EdgeN^);
end;

procedure RasterizeLineCells(
  x0, z0, x1, z1: Double;
  var EdgeCells: TCellPosArray; var EdgeN: Integer);
var
  Ctx: TRasterizeLineCtx;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(350);{$ENDIF}
  Ctx.EdgeCells := @EdgeCells;
  Ctx.EdgeN     := @EdgeN;
  WalkGridCells(x0, z0, x1, z1, @RasterizeLineVisit, @Ctx);
end;

{ Reuse-variant: writes into a caller-supplied buffer (growing it with
  doubling) instead of allocating per call. Used in hot loops. }
procedure CellsUnderTriangleReuse(
  Ax, Az, Bx, Bz, Cx, Cz: Double;
  var Cells: TCellPosArray; out CellsN: Integer);
var
  EdgeCells: TCellPosArray;
  EdgeN: Integer;
  K, IZ, IX, N: Integer;
  minIz, maxIz, minIx, maxIx: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(351);{$ENDIF}
  CellsN := 0;
  EdgeN  := 0;
  SetLength(EdgeCells, 32);

  RasterizeLineCells(Ax, Az, Bx, Bz, EdgeCells, EdgeN);
  RasterizeLineCells(Bx, Bz, Cx, Cz, EdgeCells, EdgeN);
  RasterizeLineCells(Cx, Cz, Ax, Az, EdgeCells, EdgeN);

  if EdgeN = 0 then Exit;

  minIz := EdgeCells[0].IZ;  maxIz := minIz;
  for K := 1 to EdgeN - 1 do
  begin
    if EdgeCells[K].IZ < minIz then minIz := EdgeCells[K].IZ;
    if EdgeCells[K].IZ > maxIz then maxIz := EdgeCells[K].IZ;
  end;

  if Length(Cells) < 16 then SetLength(Cells, 16);
  N := 0;
  for IZ := minIz to maxIz do
  begin
    minIx := MaxInt;  maxIx := -MaxInt;
    for K := 0 to EdgeN - 1 do
      if EdgeCells[K].IZ = IZ then
      begin
        if EdgeCells[K].IX < minIx then minIx := EdgeCells[K].IX;
        if EdgeCells[K].IX > maxIx then maxIx := EdgeCells[K].IX;
      end;
    if minIx > maxIx then Continue;
    for IX := minIx to maxIx do
    begin
      if N >= Length(Cells) then SetLength(Cells, N * 2 + 32);
      Cells[N].IX := IX;
      Cells[N].IZ := IZ;
      Inc(N);
    end;
  end;
  CellsN := N;
end;

type
  TCellEmitCtx = record
    Lift:           Single;
    UVMode:         TClipperUVMode;
    InvUV:          Single;
    UVTransform:    PUVTransform;
    Bary:           TInputTriBary;
    Target:         TMesh;
    { The 3 corner-node SMOOTH normals of the current cell sub-triangle
      (same finite-difference normals the base terrain lattice uses). The
      emit interpolates them per clipped vertex (barycentric, like the
      height), so clipped ground — roads, surface polygons — shades smoothly
      and seamlessly against the base ground instead of faceting per cell. }
    CellN0, CellN1, CellN2: TVector3;

  end;

function SetupInputTriBary(out B: TInputTriBary;
  const InTriXZ: array of TXZ; const InTriUV: array of TVector2): Boolean;
var Denom: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(353);{$ENDIF}
  B.Valid := False;
  Result := False;
  if (Length(InTriXZ) < 3) or (Length(InTriUV) < 3) then Exit;

  B.AX  := InTriXZ[0].X;  B.AZ  := InTriXZ[0].Z;
  B.v0X := InTriXZ[1].X - B.AX;  B.v0Z := InTriXZ[1].Z - B.AZ;
  B.v1X := InTriXZ[2].X - B.AX;  B.v1Z := InTriXZ[2].Z - B.AZ;
  B.D00 := B.v0X * B.v0X + B.v0Z * B.v0Z;
  B.D01 := B.v0X * B.v1X + B.v0Z * B.v1Z;
  B.D11 := B.v1X * B.v1X + B.v1Z * B.v1Z;
  Denom := B.D00 * B.D11 - B.D01 * B.D01;
  if Abs(Denom) < 1e-15 then Exit;

  B.InvDenom := 1.0 / Denom;
  B.UV[0] := InTriUV[0];  B.UV[1] := InTriUV[1];  B.UV[2] := InTriUV[2];
  B.Valid := True;
  Result := True;
end;

procedure ApplyBaryUV(const B: TInputTriBary; PX, PZ: Double; out OutU, OutV: Single);
var
  v2X, v2Z, D20, D21: Double;
  Wa, Wb, Wc: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(354);{$ENDIF}
  v2X := PX - B.AX;  v2Z := PZ - B.AZ;
  D20 := v2X * B.v0X + v2Z * B.v0Z;
  D21 := v2X * B.v1X + v2Z * B.v1Z;
  Wb := (B.D11 * D20 - B.D01 * D21) * B.InvDenom;
  Wc := (B.D00 * D21 - B.D01 * D20) * B.InvDenom;
  Wa := 1.0 - Wb - Wc;
  OutU := Wa * B.UV[0].X + Wb * B.UV[1].X + Wc * B.UV[2].X;
  OutV := Wa * B.UV[0].Y + Wb * B.UV[1].Y + Wc * B.UV[2].Y;
end;

{ Load 4 heights + 4 XZ positions for one cell. Common to ProjectTriangle
  and ProjectMultipolygon. }
procedure LoadCellCorners(Sampler: TTerrainSampler;
  Projection: TLocalProjection; HasNodeCache: Boolean;
  const Box: TLatLonBox; GX, GZ, IX, IZ: Integer;
  out hNW, hNE, hSE, hSW: Single;
  out pNWx, pNWz, pNEx, pNEz, pSEx, pSEz, pSWx, pSWz: Single);
var
  pNW, pNE, pSE, pSW: TVector3;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(356);{$ENDIF}
  Sampler.CellHeights4(IX, IZ, hNW, hNE, hSE, hSW);

  if HasNodeCache then
    Sampler.CellPositions4(IX, IZ,
      pNWx, pNWz, pNEx, pNEz, pSEx, pSEz, pSWx, pSWz)
  else
  begin
    { No-cache fallback — project each node from its Web-Mercator
      lattice geo-coordinate (Sampler.NodeLatLon -> TerrainGridNodeLatLon),
      the EXACT lat/lon of the terrain-mesh vertex. The previous
      box-linear interpolation here assumed the grid was evenly spaced
      in latitude — it is not (slippy grid is even in Mercator-Y), which
      shifted the cell relative to the mesh. Box / GX / GZ are now
      unused but kept for signature stability. }
    pNW := Projection.Project(Sampler.NodeLatLon(IX,     IZ),     0);
    pNE := Projection.Project(Sampler.NodeLatLon(IX + 1, IZ),     0);
    pSE := Projection.Project(Sampler.NodeLatLon(IX + 1, IZ + 1), 0);
    pSW := Projection.Project(Sampler.NodeLatLon(IX,     IZ + 1), 0);
    pNWx := pNW.X; pNWz := pNW.Z;
    pNEx := pNE.X; pNEz := pNE.Z;
    pSEx := pSE.X; pSEz := pSE.Z;
    pSWx := pSW.X; pSWz := pSW.Z;
  end;
end;

{ Smooth slope normal at terrain node (IX,IZ), via central differences of
  neighbour-node heights over their world-XZ spacing (edge-clamped). This is
  the SAME finite-difference normal the base terrain lattice bakes per node,
  recomputed here from the sampler so clipped ground can interpolate it and
  shade like the surrounding ground. }
function NodeNormalWorld(Sampler: TTerrainSampler; Projection: TLocalProjection;
  HasNodeCache: Boolean; IX, IZ, GX, GZ: Integer): TVector3;
var
  xm, xp, zm, zp: Integer;
  hxm, hxp, hzm, hzp: Single;
  axx, axz, bxx, bxz, czx, czz, dzx, dzz: Single;
  dX, dZ, dLonM, dLatM, Len: Single;

  procedure NodeXZ(jx, jz: Integer; out wx, wz: Single);
  var p: TVector3;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1480);{$ENDIF}
    if HasNodeCache then
      Sampler.NodePositionXZ(jx, jz, wx, wz)
    else
    begin
      p := Projection.Project(Sampler.NodeLatLon(jx, jz), 0);
      wx := p.X; wz := p.Z;
    end;
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1481);{$ENDIF}
  xm := IX - 1; if xm < 0 then xm := 0;
  xp := IX + 1; if xp > GX - 1 then xp := GX - 1;
  zm := IZ - 1; if zm < 0 then zm := 0;
  zp := IZ + 1; if zp > GZ - 1 then zp := GZ - 1;

  hxm := Sampler.NodeHeight(xm, IZ);  hxp := Sampler.NodeHeight(xp, IZ);
  hzm := Sampler.NodeHeight(IX, zm);  hzp := Sampler.NodeHeight(IX, zp);
  NodeXZ(xm, IZ, axx, axz);  NodeXZ(xp, IZ, bxx, bxz);
  NodeXZ(IX, zm, czx, czz);  NodeXZ(IX, zp, dzx, dzz);

  { Replicate the base-terrain lattice node-normal formula VERBATIM
    (TTerrainBuilder.Build, Pass 2) so the clipped surface shades identically
    to the surrounding ground — no lighting seam at the road/landuse edge:
        N = ( (dXR-dXL)*dLatM,  dLonM*dLatM,  -dLonM*(dZD-dZU) )
    where dLonM/dLatM are the world metres for ONE node step, and dXR-dXL /
    dZD-dZU are the 2-node-span height deltas (taken at IX±1 / IZ±1, NOT
    divided by the span). That makes the lattice ~2x more tilted than a
    textbook gradient normal; matching it is the whole point — dividing by
    the span (the earlier version) left roads shading ~2x flatter than the
    ground on slopes. dX/dZ are the 2-node spans, so half = one node step. }
  dX := Abs(bxx - axx);  if dX < 1e-6 then dX := 1e-6;
  dZ := Abs(dzz - czz);  if dZ < 1e-6 then dZ := 1e-6;
  dLonM := dX * 0.5;
  dLatM := dZ * 0.5;

  Result.X := (hxp - hxm) * dLatM;
  Result.Y := dLonM * dLatM;
  Result.Z := -dLonM * (hzp - hzm);
  Len := Sqrt(Result.X * Result.X + Result.Y * Result.Y + Result.Z * Result.Z);
  if Len > 1e-9 then
  begin
    Result.X := Result.X / Len;
    Result.Y := Result.Y / Len;
    Result.Z := Result.Z / Len;
  end
  else
    Result := Vector3(0, 1, 0);
end;

function IntersectAndEmitOneTriOneCell(
  const InTriXZ: array of TXZ;
  const CellTri: array of TXZ;
  const CellTriH: array of Single;
  const Ctx: TCellEmitCtx): Integer;
var
  Inter: TXZArray;
  InterN, J: Integer;
  V: TVector3;
  VNorm: TVector3;
  UV: TVector2;
  WrittenIdx: array[0..7] of Integer;
  OUVx, OUVy: Double;
  BaryU, BaryV: Single;
  bcU, bcV, bcW: Double;
  nLen: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(357);{$ENDIF}
  Result := 0;
  IntersectTriangles(InTriXZ, CellTri, Inter, InterN);
  if InterN < 3 then Exit;
  if InterN > High(WrittenIdx) + 1 then InterN := High(WrittenIdx) + 1;

  for J := 0 to InterN - 1 do
  begin
    V.X := Inter[J].X;
    V.Z := Inter[J].Z;
    { barycentric weights computed ONCE and reused for both height and normal }
    Barycentric(Inter[J], CellTri[0], CellTri[1], CellTri[2], bcU, bcV, bcW);
    V.Y := (bcU * CellTriH[0] + bcV * CellTriH[1] + bcW * CellTriH[2]) + Ctx.Lift;
    { smooth per-vertex normal — SAME barycentric weights as the height
      (continuous across cell edges, matching the base ground) }
    VNorm.X := bcU * Ctx.CellN0.X + bcV * Ctx.CellN1.X + bcW * Ctx.CellN2.X;
    VNorm.Y := bcU * Ctx.CellN0.Y + bcV * Ctx.CellN1.Y + bcW * Ctx.CellN2.Y;
    VNorm.Z := bcU * Ctx.CellN0.Z + bcV * Ctx.CellN1.Z + bcW * Ctx.CellN2.Z;
    nLen := Sqrt(VNorm.X * VNorm.X + VNorm.Y * VNorm.Y + VNorm.Z * VNorm.Z);
    if nLen > 1e-9 then
    begin
      VNorm.X := VNorm.X / nLen; VNorm.Y := VNorm.Y / nLen; VNorm.Z := VNorm.Z / nLen;
    end
    else
      VNorm := Vector3(0, 1, 0);

    case Ctx.UVMode of
      cumPlanar:
        begin
          if (Ctx.UVTransform <> nil) and Ctx.UVTransform^.Active then
          begin
            ApplyUVTransform(Ctx.UVTransform^, V.X, V.Z, OUVx, OUVy);
            UV.X := OUVx * Ctx.InvUV;
            UV.Y := OUVy * Ctx.InvUV;
          end
          else
          begin
            UV.X := V.X * Ctx.InvUV;
            UV.Y := V.Z * Ctx.InvUV;
          end;
          WrittenIdx[J] := Ctx.Target.AddVertex(V, VNorm, UV);
        end;
      cumInputBary:
        begin
          if Ctx.Bary.Valid then
          begin
            ApplyBaryUV(Ctx.Bary, V.X, V.Z, BaryU, BaryV);
            UV.X := BaryU;
            UV.Y := BaryV;
          end
          else
          begin
            UV.X := 0;
            UV.Y := 0;
          end;
          WrittenIdx[J] := Ctx.Target.AddVertex(V, VNorm, UV);
        end;
    else
      WrittenIdx[J] := Ctx.Target.AddVertex(V, VNorm);
    end;
  end;

  for J := 2 to InterN - 1 do
  begin
    Ctx.Target.AddTriangle(WrittenIdx[0], WrittenIdx[J], WrittenIdx[J - 1]);
    Inc(Result);
  end;
end;

class function TTerrainClipper.ProjectTriangle(
  const InTri: TInputTriangle;
  Sampler: TTerrainSampler;
  Projection: TLocalProjection;
  Lift: Single;
  UVMode: TClipperUVMode; UVScale: Single;
  Target: TMesh;
  Progress: PClipperProgress = nil;
  UVTransform: PUVTransform = nil): Integer;
var
  Box:    TLatLonBox;
  GX, GZ: Integer;
  IX, IZ: Integer;
  pNWx, pNWz, pNEx, pNEz, pSEx, pSEz, pSWx, pSWz: Single;
  HasNodeCache: Boolean;
  hNW, hNE, hSE, hSW: Single;
  T1, T2: array[0..2] of TXZ;
  T1h, T2h: array[0..2] of Single;
  inTriXZ: array[0..2] of TXZ;
  inTriUV: array[0..2] of TVector2;
  InvUV: Single;
  TriArea: Double;
  fracA, fracB, fracC: TXZ;
  fdX, fdZ: Double;
  Cells: TCellPosArray;
  CellsN, CellIdx: Integer;
  EmitCtx: TCellEmitCtx;
  nNW, nNE, nSE, nSW: TVector3;   { cell corner-node smooth normals }
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1137);{$ENDIF}
  Result := 0;
  if (Sampler = nil) or (Projection = nil) or (Target = nil) then Exit;
  Box := Sampler.Box;
  GX := Sampler.GridX;
  GZ := Sampler.GridZ;
  if (GX < 2) or (GZ < 2) or Box.IsEmpty then Exit;

  Cells  := nil;
  CellsN := 0;

  inTriXZ[0] := MakeXZ(InTri.P[0].X, InTri.P[0].Z);
  inTriXZ[1] := MakeXZ(InTri.P[1].X, InTri.P[1].Z);
  inTriXZ[2] := MakeXZ(InTri.P[2].X, InTri.P[2].Z);
  TriArea := TriAreaSigned(inTriXZ[0], inTriXZ[1], inTriXZ[2]);
  if Abs(TriArea) < 1e-9 then Exit;

  if (UVMode = cumPlanar) and (UVScale > 0) then
    InvUV := 1.0 / UVScale
  else
    InvUV := 0;

  HasNodeCache := Sampler.NodePositionsReady;

  EmitCtx.Lift        := Lift;
  EmitCtx.UVMode      := UVMode;
  EmitCtx.InvUV       := InvUV;
  EmitCtx.UVTransform := UVTransform;
  EmitCtx.Target      := Target;
  EmitCtx.CellN0      := Vector3(0, 1, 0);    { overwritten per cell sub-tri }
  EmitCtx.CellN1      := Vector3(0, 1, 0);
  EmitCtx.CellN2      := Vector3(0, 1, 0);

  if UVMode = cumInputBary then
  begin
    inTriUV[0] := InTri.UV[0];
    inTriUV[1] := InTri.UV[1];
    inTriUV[2] := InTri.UV[2];
    SetupInputTriBary(EmitCtx.Bary, inTriXZ, inTriUV);
  end
  else
    EmitCtx.Bary.Valid := False;

  { Cell-fraction of each triangle corner — via the shared sampler
    mapping (Web-Mercator in Z), so cell enumeration visits exactly the
    cells the terrain mesh rendered. The old affine offset/scale was
    linear in latitude and visited a shifted cell set, dropping the
    overlay area that fell into the un-visited cells. }
  Sampler.WorldToCellFrac(Projection, inTriXZ[0].X, inTriXZ[0].Z, fdX, fdZ);
  fracA.X := fdX;  fracA.Z := fdZ;
  Sampler.WorldToCellFrac(Projection, inTriXZ[1].X, inTriXZ[1].Z, fdX, fdZ);
  fracB.X := fdX;  fracB.Z := fdZ;
  Sampler.WorldToCellFrac(Projection, inTriXZ[2].X, inTriXZ[2].Z, fdX, fdZ);
  fracC.X := fdX;  fracC.Z := fdZ;

  CellsUnderTriangleReuse(
    fracA.X, fracA.Z,
    fracB.X, fracB.Z,
    fracC.X, fracC.Z,
    Cells, CellsN);
  if CellsN = 0 then Exit;

  for CellIdx := 0 to CellsN - 1 do
  begin
    IX := Cells[CellIdx].IX;
    IZ := Cells[CellIdx].IZ;

    if (IX < 0) or (IX > GX - 2) or (IZ < 0) or (IZ > GZ - 2) then Continue;

    if (Progress <> nil) and ((CellIdx and $FFF) = 0) then
      ReportClipperProgress(Progress^,
        Format('cell %d/%d', [CellIdx, CellsN]));

    LoadCellCorners(Sampler, Projection, HasNodeCache, Box, GX, GZ, IX, IZ,
      hNW, hNE, hSE, hSW,
      pNWx, pNWz, pNEx, pNEz, pSEx, pSEz, pSWx, pSWz);
    nNW := NodeNormalWorld(Sampler, Projection, HasNodeCache, IX,     IZ,     GX, GZ);
    nNE := NodeNormalWorld(Sampler, Projection, HasNodeCache, IX + 1, IZ,     GX, GZ);
    nSE := NodeNormalWorld(Sampler, Projection, HasNodeCache, IX + 1, IZ + 1, GX, GZ);
    nSW := NodeNormalWorld(Sampler, Projection, HasNodeCache, IX,     IZ + 1, GX, GZ);

    T1[0] := MakeXZ(pNWx, pNWz); T1h[0] := hNW;
    T1[1] := MakeXZ(pSWx, pSWz); T1h[1] := hSW;
    T1[2] := MakeXZ(pSEx, pSEz); T1h[2] := hSE;
    EmitCtx.CellN0 := nNW; EmitCtx.CellN1 := nSW; EmitCtx.CellN2 := nSE;
    Inc(Result, IntersectAndEmitOneTriOneCell(inTriXZ, T1, T1h, EmitCtx));

    T2[0] := MakeXZ(pNWx, pNWz); T2h[0] := hNW;
    T2[1] := MakeXZ(pSEx, pSEz); T2h[1] := hSE;
    T2[2] := MakeXZ(pNEx, pNEz); T2h[2] := hNE;
    EmitCtx.CellN0 := nNW; EmitCtx.CellN1 := nSE; EmitCtx.CellN2 := nNE;
    Inc(Result, IntersectAndEmitOneTriOneCell(inTriXZ, T2, T2h, EmitCtx));
  end;
end;

class function TTerrainClipper.ProjectMultipolygon(
  const MP: TPolygonMultipolygon;
  Sampler: TTerrainSampler;
  Projection: TLocalProjection;
  Lift: Single;
  UVMode: TClipperUVMode; UVScale: Single;
  Target: TMesh;
  Progress: PClipperProgress = nil;
  UVTransform: PUVTransform = nil): Integer;
var
  { Earcut input. }
  TotalPts, OuterN, InnerCount, I, J, K: Integer;
  EarcutData:   array of Double;
  HoleIndices:  array of Integer;
  Triangles:    TIntArray;
  RingPtr:      ^TPolygonRing;
  AllPts:       array of TXZ;

  NumTris:      Integer;
  InputTrisXZ:  array of array[0..2] of TXZ;
  { Affine cell-frac coordinates per triangle vertex — computed in pass 1
    and reused in passes 2 and 3 (replaces per-triangle TCellPosArray). }
  TriFracsA, TriFracsB, TriFracsC: array of TXZ;
  TriValid:     array of Boolean;
  CellBuf:      TCellPosArray;     { reused across CellsUnderTriangleReuse calls }
  CellBufN:     Integer;

  Box:          TLatLonBox;
  GX, GZ:       Integer;
  PolyMinIX, PolyMaxIX, PolyMinIZ, PolyMaxIZ: Integer;
  BinW, BinH:   Integer;
  CellCounts:   array of Integer;
  CellOffsets:  array of Integer;
  CellWriteCursor: array of Integer;
  TriIdxFlat:   array of Integer;
  TotalPairs:   Integer;

  IX, IZ, GIX, GIZ, BinIdx: Integer;
  pNWx, pNWz, pNEx, pNEz, pSEx, pSEz, pSWx, pSWz: Single;
  hNW, hNE, hSE, hSW: Single;
  T1, T2:       array[0..2] of TXZ;
  T1h, T2h:     array[0..2] of Single;
  HasNodeCache: Boolean;
  InvUV:        Single;
  EmitCtx:      TCellEmitCtx;
  TriIdx, OffsetSlot: Integer;

  fracA, fracB, fracC: TXZ;
  TriArea:      Double;
  fdX, fdZ:     Double;
  nNW, nNE, nSE, nSW: TVector3;   { cell corner-node smooth normals }
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1138);{$ENDIF}
  Result := 0;
  if (Target = nil) or (Sampler = nil) or (Projection = nil) then Exit;
  if Length(MP.Outer) < 3 then Exit;
  Box := Sampler.Box;
  GX  := Sampler.GridX;
  GZ  := Sampler.GridZ;
  if (GX < 2) or (GZ < 2) or Box.IsEmpty then Exit;

  OuterN     := Length(MP.Outer);
  InnerCount := Length(MP.Inners);

  TotalPts := OuterN;
  for I := 0 to InnerCount - 1 do
    Inc(TotalPts, Length(MP.Inners[I]));
  if TotalPts < 3 then Exit;

  SetLength(EarcutData,  TotalPts * 2);
  SetLength(HoleIndices, InnerCount);
  SetLength(AllPts,      TotalPts);

  K := 0;
  for I := 0 to OuterN - 1 do
  begin
    EarcutData[K * 2]     := MP.Outer[I].X;
    EarcutData[K * 2 + 1] := MP.Outer[I].Z;
    AllPts[K].X := MP.Outer[I].X;
    AllPts[K].Z := MP.Outer[I].Z;
    Inc(K);
  end;
  for I := 0 to InnerCount - 1 do
  begin
    HoleIndices[I] := K;
    RingPtr := @MP.Inners[I];
    for J := 0 to Length(RingPtr^) - 1 do
    begin
      EarcutData[K * 2]     := RingPtr^[J].X;
      EarcutData[K * 2 + 1] := RingPtr^[J].Z;
      AllPts[K].X := RingPtr^[J].X;
      AllPts[K].Z := RingPtr^[J].Z;
      Inc(K);
    end;
  end;

  Triangles := TEarcutTriangulator.Triangulate(EarcutData, HoleIndices, 2);
  if Length(Triangles) < 3 then Exit;
  NumTris := Length(Triangles) div 3;
  if NumTris = 0 then Exit;

  SetLength(InputTrisXZ, NumTris);
  for J := 0 to NumTris - 1 do
  begin
    InputTrisXZ[J][0] := AllPts[Triangles[J * 3    ]];
    InputTrisXZ[J][1] := AllPts[Triangles[J * 3 + 1]];
    InputTrisXZ[J][2] := AllPts[Triangles[J * 3 + 2]];
  end;
  AllPts        := nil;
  EarcutData    := nil;
  HoleIndices   := nil;
  Triangles     := nil;

  if (UVMode = cumPlanar) and (UVScale > 0) then
    InvUV := 1.0 / UVScale
  else
    InvUV := 0;
  HasNodeCache  := Sampler.NodePositionsReady;

  EmitCtx.Lift          := Lift;
  EmitCtx.UVMode        := UVMode;
  EmitCtx.InvUV         := InvUV;
  EmitCtx.UVTransform   := UVTransform;
  EmitCtx.Target        := Target;
  EmitCtx.Bary.Valid    := False;
  EmitCtx.CellN0        := Vector3(0, 1, 0);
  EmitCtx.CellN1        := Vector3(0, 1, 0);
  EmitCtx.CellN2        := Vector3(0, 1, 0);

  if Progress <> nil then
  begin
    Progress^.TriTotal := NumTris;
    Progress^.TriIdx   := 0;
  end;

  { Cell-fraction now comes from the shared sampler mapping (see
    TTerrainClipper.ProjectTriangle) — Web-Mercator in Z. The previous
    linear-in-latitude affine made the enumeration miss cells and leave
    holes in the conformed landuse surface. }

  SetLength(TriFracsA, NumTris);
  SetLength(TriFracsB, NumTris);
  SetLength(TriFracsC, NumTris);
  SetLength(TriValid,  NumTris);

  PolyMinIX :=  MaxInt;  PolyMinIZ :=  MaxInt;
  PolyMaxIX := -MaxInt;  PolyMaxIZ := -MaxInt;

  for J := 0 to NumTris - 1 do
  begin
    if Progress <> nil then
    begin
      Progress^.TriIdx := J + 1;
      ReportClipperProgress(Progress^);
    end;

    TriArea := TriAreaSigned(InputTrisXZ[J][0], InputTrisXZ[J][1], InputTrisXZ[J][2]);
    if Abs(TriArea) < 1e-9 then
    begin
      TriValid[J] := False;
      Continue;
    end;
    TriValid[J] := True;

    Sampler.WorldToCellFrac(Projection,
      InputTrisXZ[J][0].X, InputTrisXZ[J][0].Z, fdX, fdZ);
    fracA.X := fdX;  fracA.Z := fdZ;
    Sampler.WorldToCellFrac(Projection,
      InputTrisXZ[J][1].X, InputTrisXZ[J][1].Z, fdX, fdZ);
    fracB.X := fdX;  fracB.Z := fdZ;
    Sampler.WorldToCellFrac(Projection,
      InputTrisXZ[J][2].X, InputTrisXZ[J][2].Z, fdX, fdZ);
    fracC.X := fdX;  fracC.Z := fdZ;
    TriFracsA[J] := fracA;
    TriFracsB[J] := fracB;
    TriFracsC[J] := fracC;

    { Conservative cell-bbox over the three frac-space corners. }
    IX := Max(0, Floor(Min(Min(fracA.X, fracB.X), fracC.X)));
    if IX < PolyMinIX then PolyMinIX := IX;
    IX := Min(GX - 2, Ceil(Max(Max(fracA.X, fracB.X), fracC.X)));
    if IX > PolyMaxIX then PolyMaxIX := IX;
    IZ := Max(0, Floor(Min(Min(fracA.Z, fracB.Z), fracC.Z)));
    if IZ < PolyMinIZ then PolyMinIZ := IZ;
    IZ := Min(GZ - 2, Ceil(Max(Max(fracA.Z, fracB.Z), fracC.Z)));
    if IZ > PolyMaxIZ then PolyMaxIZ := IZ;
  end;

  { Both axes must be guarded: if every triangle was degenerate
    (TriArea below epsilon) Poly*IZ keep their sentinel values and
    BinH would go negative, crashing SetLength. }
  if (PolyMaxIX < PolyMinIX) or (PolyMaxIZ < PolyMinIZ) then Exit;

  BinW := PolyMaxIX - PolyMinIX + 1;
  BinH := PolyMaxIZ - PolyMinIZ + 1;

  SetLength(CellCounts, BinW * BinH);
  CellBuf  := nil;
  CellBufN := 0;
  SetLength(CellBuf, 64);
  TotalPairs := 0;

  for J := 0 to NumTris - 1 do
  begin
    if not TriValid[J] then Continue;
    CellsUnderTriangleReuse(
      TriFracsA[J].X, TriFracsA[J].Z,
      TriFracsB[J].X, TriFracsB[J].Z,
      TriFracsC[J].X, TriFracsC[J].Z,
      CellBuf, CellBufN);
    for K := 0 to CellBufN - 1 do
    begin
      IX := CellBuf[K].IX;
      IZ := CellBuf[K].IZ;
      if (IX < 0) or (IX > GX - 2) or (IZ < 0) or (IZ > GZ - 2) then Continue;
      Inc(CellCounts[(IZ - PolyMinIZ) * BinW + (IX - PolyMinIX)]);
      Inc(TotalPairs);
    end;
  end;

  if TotalPairs = 0 then Exit;

  SetLength(CellOffsets, BinW * BinH + 1);
  CellOffsets[0] := 0;
  for K := 0 to BinW * BinH - 1 do
    CellOffsets[K + 1] := CellOffsets[K] + CellCounts[K];

  SetLength(TriIdxFlat, TotalPairs);
  SetLength(CellWriteCursor, BinW * BinH);
  for K := 0 to BinW * BinH - 1 do
    CellWriteCursor[K] := CellOffsets[K];

  for J := 0 to NumTris - 1 do
  begin
    if not TriValid[J] then Continue;
    CellsUnderTriangleReuse(
      TriFracsA[J].X, TriFracsA[J].Z,
      TriFracsB[J].X, TriFracsB[J].Z,
      TriFracsC[J].X, TriFracsC[J].Z,
      CellBuf, CellBufN);
    for K := 0 to CellBufN - 1 do
    begin
      IX := CellBuf[K].IX;
      IZ := CellBuf[K].IZ;
      if (IX < 0) or (IX > GX - 2) or (IZ < 0) or (IZ > GZ - 2) then Continue;
      BinIdx := (IZ - PolyMinIZ) * BinW + (IX - PolyMinIX);
      TriIdxFlat[CellWriteCursor[BinIdx]] := J;
      Inc(CellWriteCursor[BinIdx]);
    end;
  end;

  CellWriteCursor := nil;
  TriFracsA := nil;  TriFracsB := nil;  TriFracsC := nil;
  TriValid  := nil;  CellBuf   := nil;

  for IZ := 0 to BinH - 1 do
  begin
    GIZ := IZ + PolyMinIZ;

    if (Progress <> nil) and ((IZ and $1F) = 0) then
      ReportClipperProgress(Progress^,
        Format('cell row %d/%d', [IZ, BinH]));

    for IX := 0 to BinW - 1 do
    begin
      BinIdx := IZ * BinW + IX;
      if CellCounts[BinIdx] = 0 then Continue;

      GIX := IX + PolyMinIX;

      LoadCellCorners(Sampler, Projection, HasNodeCache, Box, GX, GZ, GIX, GIZ,
        hNW, hNE, hSE, hSW,
        pNWx, pNWz, pNEx, pNEz, pSEx, pSEz, pSWx, pSWz);
      nNW := NodeNormalWorld(Sampler, Projection, HasNodeCache, GIX,     GIZ,     GX, GZ);
      nNE := NodeNormalWorld(Sampler, Projection, HasNodeCache, GIX + 1, GIZ,     GX, GZ);
      nSE := NodeNormalWorld(Sampler, Projection, HasNodeCache, GIX + 1, GIZ + 1, GX, GZ);
      nSW := NodeNormalWorld(Sampler, Projection, HasNodeCache, GIX,     GIZ + 1, GX, GZ);

      T1[0] := MakeXZ(pNWx, pNWz); T1h[0] := hNW;
      T1[1] := MakeXZ(pSWx, pSWz); T1h[1] := hSW;
      T1[2] := MakeXZ(pSEx, pSEz); T1h[2] := hSE;
      T2[0] := MakeXZ(pNWx, pNWz); T2h[0] := hNW;
      T2[1] := MakeXZ(pSEx, pSEz); T2h[1] := hSE;
      T2[2] := MakeXZ(pNEx, pNEz); T2h[2] := hNE;

      for OffsetSlot := CellOffsets[BinIdx] to CellOffsets[BinIdx + 1] - 1 do
      begin
        TriIdx := TriIdxFlat[OffsetSlot];
        EmitCtx.CellN0 := nNW; EmitCtx.CellN1 := nSW; EmitCtx.CellN2 := nSE;
        Inc(Result, IntersectAndEmitOneTriOneCell(InputTrisXZ[TriIdx], T1, T1h, EmitCtx));
        EmitCtx.CellN0 := nNW; EmitCtx.CellN1 := nSE; EmitCtx.CellN2 := nNE;
        Inc(Result, IntersectAndEmitOneTriOneCell(InputTrisXZ[TriIdx], T2, T2h, EmitCtx));
      end;
    end;
  end;
end;

function EmitRibbonSegmentToTerrain(
  const R0, L0, R1, L1: TXZ;
  VStart, VEnd: Single;
  UseUV: Boolean;
  UVMinX, UVMaxX: Single;
  Sampler: TTerrainSampler;
  Projection: TLocalProjection;
  Lift: Single;
  Target: TMesh;
  Progress: PClipperProgress): Integer;
var
  InTri: TInputTriangle;
  Mode: TClipperUVMode;
  A1, A2: Single;
  CR1, CL1: TXZ;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(358);{$ENDIF}
  Result := 0;
  if UseUV then Mode := cumInputBary else Mode := cumNone;

  { Per-way UVMinX..UVMaxX replaces the hard-coded 0..1 cross-road U
    range. For asphalt roadways UVMinX/UVMaxX come from GetRoadUV —
    they slice out the central N/16 strip of the lane-marked atlas cell.
    For everything else 0..1 (full cell). R edge maps to UVMinX,
    L edge to UVMaxX (mirrors streets-gl minLane=-fwd/maxLane=+bwd). }

  { Защита от вырожденного/перекрученного квада ленты. Редкий исход
    стыковой геометрии: у крутого изгиба/митры одна кромка локально
    пятится назад, и один из двух треугольников разбиения квада
    ВЫВОРАЧИВАЕТСЯ (знак площади в XZ противоположный) — после проекции
    на рельеф он торчит из полотна «шипом». Лечение: треугольник со
    знаком, противоположным доминирующей ориентации квада (знак суммы
    площадей), НЕ эмитим — остаётся крошечная выемка, перекрываемая
    соседними квадами. ВАЖНО: не «чинить» обменом сторон R<->L — обмен
    перекручивает ленту (кромка прыгает через полотно), это рисует
    разрыв с зигзагом кромочной линии. Иголки (площадь ~0) — тоже вон. }
  A1 := (L0.X - R0.X) * (L1.Z - R0.Z) - (L0.Z - R0.Z) * (L1.X - R0.X);
  A2 := (L1.X - R0.X) * (R1.Z - R0.Z) - (L1.Z - R0.Z) * (R1.X - R0.X);
  CR1 := R1;  CL1 := L1;
  if ((A1 > 0) and (A2 < 0)) or ((A1 < 0) and (A2 > 0)) then
  begin
    { вывернутый — тот, чей знак против суммы; глушим его нулём площади }
    if Abs(A1) >= Abs(A2) then A2 := 0 else A1 := 0;
  end;

  if Abs(A1) > RIBBON_DEGENERATE_AREA2 then
  begin
    InTri.P[0].X := R0.X;   InTri.P[0].Z := R0.Z;
    InTri.P[1].X := L0.X;   InTri.P[1].Z := L0.Z;
    InTri.P[2].X := CL1.X;  InTri.P[2].Z := CL1.Z;
    InTri.UV[0]  := Vector2(UVMinX, VStart);
    InTri.UV[1]  := Vector2(UVMaxX, VStart);
    InTri.UV[2]  := Vector2(UVMaxX, VEnd);
    Inc(Result, TTerrainClipper.ProjectTriangle(InTri,
      Sampler, Projection, Lift, Mode, 0, Target, Progress, nil));
  end;

  if Abs(A2) > RIBBON_DEGENERATE_AREA2 then
  begin
    InTri.P[0].X := R0.X;   InTri.P[0].Z := R0.Z;
    InTri.P[1].X := CL1.X;  InTri.P[1].Z := CL1.Z;
    InTri.P[2].X := CR1.X;  InTri.P[2].Z := CR1.Z;
    InTri.UV[0]  := Vector2(UVMinX, VStart);
    InTri.UV[1]  := Vector2(UVMaxX, VEnd);
    InTri.UV[2]  := Vector2(UVMinX, VEnd);
    Inc(Result, TTerrainClipper.ProjectTriangle(InTri,
      Sampler, Projection, Lift, Mode, 0, Target, Progress, nil));
  end;
end;

procedure ComputeRibbonAccumLen(var Center: TRibbonVertexArray);
var
  I: Integer;
  DX, DZ: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(359);{$ENDIF}
  if Length(Center) = 0 then Exit;
  Center[0].AccumLen := 0;
  for I := 1 to High(Center) do
  begin
    DX := Center[I].X - Center[I - 1].X;
    DZ := Center[I].Z - Center[I - 1].Z;
    Center[I].AccumLen := Center[I - 1].AccumLen + Sqrt(DX * DX + DZ * DZ);
  end;
end;

class function TTerrainClipper.ProjectRibbonFromEdges(
  const Edges: TRibbonEdgePointArray;
  Sampler: TTerrainSampler;
  Projection: TLocalProjection;
  Lift: Single;
  UVScaleY: Single;
  UVMinX, UVMaxX: Single;
  Target: TMesh;
  Progress: PClipperProgress = nil): Integer;
var
  I: Integer;
  VStart, VEnd: Single;
  UseUV: Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1140);{$ENDIF}
  Result := 0;
  if (Target = nil) or (Sampler = nil) or (Projection = nil) then Exit;
  if Length(Edges) < 2 then Exit;
  UseUV := UVScaleY > 0;

  for I := 0 to High(Edges) - 1 do
  begin
    if UseUV then
    begin
      VStart := Edges[I    ].AccumLen / UVScaleY;
      VEnd   := Edges[I + 1].AccumLen / UVScaleY;
    end
    else
    begin
      VStart := 0; VEnd := 0;
    end;

    Inc(Result, EmitRibbonSegmentToTerrain(
      Edges[I    ].Right, Edges[I    ].Left,
      Edges[I + 1].Right, Edges[I + 1].Left,
      VStart, VEnd, UseUV,
      UVMinX, UVMaxX,
      Sampler, Projection, Lift, Target, Progress));
  end;
end;

{ PackTileKey: cell -> geo-tile key (жив: int-карв тегирует треугольники). }

{ Pack a tile (TX,TY) into one Int64 (TX high, TY low). Both < 2^24 in practice. }
function PackTileKey(TX, TY: Integer): Int64; inline;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1483);{$ENDIF}
  Result := (Int64(TX) shl 32) or Int64(Cardinal(TY));
end;

{ Append one per-triangle tile key, growing geometrically (amortised O(1)).
  TriKeyCount stays == the mesh's TriangleCount after each piece is fanned. }

end.
