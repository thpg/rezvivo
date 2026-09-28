unit Osm3dRouteSnapper;

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$codepage UTF8}

interface

uses
  Classes,
  SysUtils,
  Math,
  Generics.Collections,
  CastleVectors,
  Osm3dGeoMath,
  Osm3dOsmData,
  Osm3dGeomRoads,
  Osm3dMapUtils,
  Osm3dStudioLog
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
;

const
  { Radius around each route point to look up candidate road segments.
    Raised from 12: consumer-GPS bike tracks routinely sit 10-15 m off the
    mapped centerline under tree cover / in urban canyons; wrong roads are
    rejected by the per-candidate gates below, not by this radius. Must stay
    >= every distance gate that leans on the AABB inflation (including
    SNAP_ISLAND_REJOIN_MAX_M). }
  SNAP_SEARCH_RADIUS_M         = 18.0;

  { Maximum |angle(route_tangent, segment_direction)| for a segment to
    be considered parallel. 30° leaves headroom for natural GPS wiggle
    of a bike track and for curved roads (the tangent is a 2-point
    estimate, so it lags real curvature). }
  SNAP_PARALLEL_MAX_ANGLE_DEG  = 30.0;

  { Perpendicular distance from segment line that the point may be
    beyond the polygon edge and still count as "on the road". Raised
    from 3.5 for a stronger pull: tracks with a constant GPS bias now
    still land on the road; wrong parallel ways are filtered by the
    way-stickiness + ambiguity logic instead of by this gate. }
  SNAP_PERP_BEYOND_HALFW_M     = 6.0;

  { РЕАЛЬНОЕ окно поточечного поиска: точка может стоять до этого
    перпендикуляра от осевой и всё ещё притянуться. Раньше эффективный
    порог был HalfW + SNAP_PERP_BEYOND_HALFW_M (≈9 м для 6-метровой
    дороги) — райдер, едущий по обочине в 12 м от осевой длинной прямой,
    выпадал из снапа (наблюдалось на живых FIT: 217 м обочины подряд).
    Теперь гейт = max(HalfW+6, 30): дальняя параллельная дорога ловится
    и поточечно, а не только оконным голосом. От НЕВЕРНЫХ дорог на таком
    радиусе защищают прежние механизмы: угловой гейт (пересекающие),
    гейт неоднозначности (двойники), липкость и голос (перехваты).
    ОБЯЗАН быть <= SNAP_GRID_CELL_M: обход 3x3 ячеек не видит дальше. }
  SNAP_POINT_MAX_PERP_M        = 30.0;

  { Width threshold separating "wide" (a real roadway lane) from
    "narrow" (a single-file cycle/foot path). Wide → keep to the edge,
    narrow → centerline. }
  SNAP_WIDE_THRESHOLD_M        = 5.0;

  { How far INSIDE the polygon edge to place the snapped point on a
    wide road. 1 m matches the user request and keeps the sphere
    visibly off the painted edge. }
  SNAP_WIDE_EDGE_OFFSET_M      = 1.0;

  { Minimum gap (in perpendicular distance) between the best and
    second-best candidate ways for the snap to be considered
    unambiguous. Within this gap → leave the original point. NOTE:
    continuation along the way currently being followed bypasses this
    guard entirely — following IS the disambiguation. }
  SNAP_AMBIG_MIN_GAP_M         = 2.0;

  { Way-stickiness: while the route is following way W, a DIFFERENT way
    steals a point only when its candidate is closer than W's best by
    more than this margin. Raised from 3→7: parallel roads before bridges
    (Турья) were stealing the snap and yanking attraction ~10 m off FIT. }
  SNAP_STICKY_ADVANTAGE_M      = 7.0;

  { BRIDGE_SNAP: prefer a bridge/tunnel centerline over a ground road under
    the same span even when the ground road is this many metres closer in
    XZ. GPS noise + stacked OSM geometries otherwise yank attraction points
    onto the lower road mid-span → rider "jumps off" the bridge. }
  SNAP_BRIDGE_PREFER_M         = 12.0;

  { EXIT_PRIORITY / ROAD_OVER_PATH: prefer a vehicle roadway (Width >
    SNAP_WIDE_THRESHOLD_M ≈ secondary+ with ≥2 lanes) over a footway /
    sidewalk / path that is this many metres closer in XZ.
    Турья #19: snap stuck on sidewalk ways 724761685 / 662456356 (~4 m
    width) while FIT was on secondary «Ленинского Комсомола» + bridge
    67142935; sidewalk is ~10–13 m closer than the road centerline, so
    pure XZ nearest-segment loses the exit ramp. }
  SNAP_ROAD_OVER_PATH_M        = 18.0;

  { After leaving a way (no snap / other way), keep trying that way for this
    many metres of route — holds the deck/exit through the ramp where GPS
    dives under the span and point-snap would drop to way=0 / under-road.
    Exit ramp is the PRIORITY path: hold longer than a short GPS glitch. }
  SNAP_EXIT_HOLD_M             = 120.0;

  { Stickiness memory: after this many metres of route WITHOUT a single
    snap the current way is forgotten, so a long off-road stretch does
    not keep attracting the track to a road left far behind.
    MUST be >= SNAP_EXIT_HOLD_M — otherwise PrevWayId is cleared before
    exit-hold can rejoin the ramp (was 50 m vs hold 120 m → silent no-op). }
  SNAP_STICKY_FORGET_M         = 130.0;

  { SNAP_GAP_FILL: when point-gates leave way=0 but a road centerline is
    within this radius, still snap (no parallel-angle gate). Closes the
    Турья S-exit hole: OSM secondary 291713717 has a 179 m stub right
    under the FIT (d≈1 m) yet angle/ambiguous gates dropped every point
    until the next tile's secondary (1073971082) ~170 m later. }
  SNAP_GAP_FILL_MAX_M          = 30.0;

  { Island post-pass: a run of points snapped onto some OTHER way (or
    not snapped at all), sandwiched on BOTH sides by points of one and
    the same way A and shorter than this along the route, is pulled back
    onto A — the path was following A and keeps following it afterwards,
    so the brief hop onto a crossing/parallel way is a nearest-segment
    artefact, not a real turn. Raised 30→70: bridge exit runs are often
    longer than 30 m of "under" GPS. }
  SNAP_ISLAND_MAX_LEN_M        = 70.0;

  { How far from A's centerline an island point may sit and still be
    re-joined; beyond that A has genuinely diverged — leave the point.
    MUST stay <= SNAP_SEARCH_RADIUS_M (segment AABBs in the grid are
    inflated by exactly that, so a farther A is not even discoverable).
    NOTE: the re-join deliberately has NO parallel-angle gate — inside a
    jittery island the 2-point tangent estimate is meaningless (a 9 m
    GPS spike between 2 m-spaced points reads as a 65° heading), and
    way-membership is already established by the sandwich, the length
    limit and this distance cap. }
  SNAP_ISLAND_REJOIN_MAX_M     = 15.0;

  { ── Path-follow vote ───────────────────────────────────────────────
    The per-point scan above ranks a road by the perpendicular distance to
    its centerline AT ONE POINT. That misreads a road which is geometrically
    correct but laterally SHIFTED in OSM (a routine import/survey offset):
    a narrow shifted way is pushed past SNAP_PERP_BEYOND_HALFW_M and dropped,
    or a nearer crossing/parallel way wins point-by-point. The follow vote
    instead looks a window FORWARD and BACK along the track and asks which
    way the track as a whole runs parallel to and follows — recovering the
    shifted way, because "shifted but correct" shows up as a nearly CONSTANT
    signed offset over the window (low spread), unlike a road the track only
    drifts near (signed offset swings through zero). }

  { Half-length (metres along the route) of the look-ahead/look-back window
    the vote aggregates over. Long enough to out-vote a single crossing,
    short enough not to smear across a real turn. }
  SNAP_FOLLOW_WINDOW_M         = 40.0;

  { A way is a follow candidate only if eligible (parallel, within the search
    radius) on at least this fraction of the window points. Kills crossing /
    branching ways, which only cover a short arc of the window. }
  SNAP_FOLLOW_MIN_COVERAGE     = 0.6;

  { Constant-offset tolerance: max standard deviation of the signed
    perpendicular over the window for a way to read as "followed". A
    shifted-but-correct road holds a near-constant offset (small σ) even
    when that offset is large; a way the track straddles has σ from the
    sign swing. Kept tight so a long genuine turn (a step in signed offset,
    σ≈2 m) does NOT qualify — that case must fall through to stickiness. }
  SNAP_FOLLOW_MAX_SPREAD_M     = 1.5;

  { Max mean heading error (deg) over the window. Averaged over many points,
    so tighter than the per-point parallel gate: a real followed road holds
    its bearing. }
  SNAP_FOLLOW_MAX_HEADING_DEG  = 20.0;

  { The vote COMMITS only when the best way beats the runner-up by at least
    this score margin; otherwise it abstains and the point is left to the
    per-point / stickiness / island logic. This is what keeps a genuine
    turn onto an equally-followed parallel way (no decisive winner) from
    being yanked back. }
  SNAP_FOLLOW_MARGIN           = 0.8;

  { A committed follow may pull the point onto its way from up to this far
    (perpendicular), overriding the normal SNAP_PERP_BEYOND_HALFW_M edge
    gate — the whole point of the feature. FindWayCand scans the 3x3 cell
    neighbourhood, so this (like SNAP_FOLLOW_FAR_M) MUST stay
    <= SNAP_GRID_CELL_M. }
  SNAP_FOLLOW_REJOIN_MAX_M     = 15.0;

  { ── Far band ──
    Extended search radius for the follow vote ONLY, and only as a
    FALLBACK: it enters when the normal band (SNAP_SEARCH_RADIUS_M) holds
    no followable way at all — «когда не найдено иного». Covers roads
    shifted in OSM beyond the normal radius. Ways matched through the far
    band must be LONG matches (see SNAP_FOLLOW_FAR_MIN_COVERAGE); a
    committed far follow may also re-join from up to this distance.
    MUST stay <= SNAP_GRID_CELL_M — the far lookup walks the 3x3 cell
    neighbourhood, which reaches exactly one cell size out. }
  SNAP_FOLLOW_FAR_M            = 30.0;

  { Coverage bar for far-band ways — stricter than the normal
    SNAP_FOLLOW_MIN_COVERAGE: pulling a point 30 m sideways is justified
    only when the track runs along that road for most of the window.
    Effective minimum TRUE overlap length (segment ends are visible up to
    sqrt(FAR^2 - offset^2) along the track past the road tip):
      FAR_MIN_COVERAGE * 2*WINDOW - 2*sqrt(FAR^2 - offset^2)
    ≈ 31 m for a 25 m offset with the defaults — short stray stubs in the
    far band never capture. }
  SNAP_FOLLOW_FAR_MIN_COVERAGE = 0.8;

  { Spatial-hash grid cell size for road segment lookup. ~2× search
    radius minimises the number of cells a point query touches. }
  SNAP_GRID_CELL_M             = 36.0;

  { Hard cap on grid dimension — protects against pathological huge
    chunks. Beyond this the cell size grows. }
  SNAP_GRID_MAX_DIM            = 1024;

type
  { Projected road centerline segment — the snapper's unit of road geometry: XZ endpoints, parsed
    width, way id. Public so a caller can build the segment array from a source other than a live
    TOSMDataset (e.g. the tile cache) and feed the segment-based Snap. The derived fields (DX/DZ/
    LenSq/LenInv/HalfW + search-inflated AABB) are filled by MakeSnapSegment, identically per source. }
  TSnapSegment = record
    X0, Z0:     Single;
    X1, Z1:     Single;
    DX, DZ:     Single;        { (X1-X0, Z1-Z0), NOT normalised }
    LenSq:      Single;        { |DX,DZ|² }
    LenInv:     Single;        { 1 / sqrt(LenSq) }
    HalfW:      Single;
    Width:      Single;
    WayId:      Int64;
    { BRIDGE_SNAP: bridge/tunnel deck centerline. When a ground road sits
      under the same XZ span, prefer this way so attraction points stay on
      the deck instead of the road below. }
    IsBridge:   Boolean;
    BBoxMinX:   Single;
    BBoxMaxX:   Single;
    BBoxMinZ:   Single;
    BBoxMaxZ:   Single;
  end;
  TSnapSegmentArray = array of TSnapSegment;

  TRouteSnapStats = record
    Total:      Integer;
    Unchanged:  Integer;
    Ambiguous:  Integer;
    Center:     Integer;
    Edge:       Integer;
    Sticky:     Integer;   { points held on the current way by stickiness }
    Rejoined:   Integer;   { island points pulled back onto the through way }
    Followed:   Integer;   { points snapped by the windowed path-follow vote }
  end;

  TRouteSnapper = class
  public
    { Fill a TSnapSegment from a raw centerline segment: derives
      DX/DZ/LenSq/LenInv/HalfW and the SNAP_SEARCH_RADIUS_M-inflated
      AABB. Returns False for a degenerate (near-zero-length) segment —
      the caller should skip it. Single point where both the live-
      dataset path and the tile-cache path build the snapper's input,
      so the geometry is derived identically. }
    class function MakeSnapSegment(X0, Z0, X1, Z1, Width: Single;
      WayId: Int64; out Seg: TSnapSegment;
      AIsBridge: Boolean = False): Boolean;

    { Core snap — operates on a pre-built segment array. Length(Result)
      = Length(Route); points that don't qualify are copied through
      unchanged. Both entry points below funnel here, so the scoring /
      ambiguity / snap-target logic exists exactly once.

      Projection is used only to unproject snapped XZ back to lat/lon;
      the segments are already projected.

      AWaysOut <> nil — туда кладётся параллельный маршруту массив way id,
      на которые снапнуты точки (0 = не притянута): потребители высоты
      (маркеры/путь аватара) берут Y с поверхности ИМЕННО этой дороги —
      на мосту это настил, а не рельеф под ним. }
    class function Snap(const Route: TRouteLatLonArray;
                        const Segs: TSnapSegmentArray;
                        Projection: TLocalProjection;
                        out Widths: TRouteWidthArray;
                        out Centers: TRouteLatLonArray;
                        Log: TLogTarget = nil;
                        const ADebugPath: string = '';
                        AProgress: PInteger = nil;
                        AWaysOut: PRouteWayIdArray = nil): TRouteLatLonArray;
                        overload;

    { Convenience: snap against a live TOSMDataset (builds the segment array from its road ways via
      TRoadBuilder.ParseRoadParams, then defers to the core Snap). Widths[i] = width of the road
      point i snapped onto (0 for off-road/unchanged). Centers[i] = the road CENTERLINE foot it was
      snapped toward (= the original point for off-road/unchanged). }
    { ADebugPath <> '' — рядом со снапом пишется ОТДЕЛЬНЫЙ подробный
      лог фита: все дороги в радиусе (по way: сегменты/длина/ширина/
      позиция), сам маршрут из FIT, и по каждой точке — соседние way,
      вердикт оконного голоса и итоговое решение с причиной (голос /
      липкость / поточечный / остров / не притянуто и почему). Файл
      перезаписывается каждым снапом; ошибки записи глотаются — дамп
      никогда не ломает сам снап.

      AProgress <> nil — по ходу главного прохода снаппер пишет туда
      индекс обрабатываемой точки маршрута (0..N, монотонно; N = готово).
      Пишется из потока снапа простым присваиванием выровненного Integer —
      читателю (анимация прогрева) достаточно монотонной свежести. }
    class function Snap(const Route: TRouteLatLonArray;
                        Dataset: TOSMDataset;
                        Projection: TLocalProjection;
                        out Widths: TRouteWidthArray;
                        out Centers: TRouteLatLonArray;
                        Log: TLogTarget = nil;
                        const ADebugPath: string = '';
                        AProgress: PInteger = nil;
                        AWaysOut: PRouteWayIdArray = nil): TRouteLatLonArray;
                        overload;
  end;

implementation

type
  { Compact spatial-hash grid built once per call.
    Per-cell entries are stored in a flat Indices[] array, with
    Starts[K] giving the inclusive start of cell K and Starts[K+1] the
    exclusive end. Built with a classic count-prefix-scatter triple. }
  TSnapGrid = record
    OriginX, OriginZ: Single;
    CellSize:         Single;
    Cols, Rows:       Integer;
    Starts:   array of Integer;
    Indices:  array of Integer;
  end;

  TCellIndexArray = array of Integer;

class function TRouteSnapper.MakeSnapSegment(X0, Z0, X1, Z1, Width: Single;
  WayId: Int64; out Seg: TSnapSegment; AIsBridge: Boolean): Boolean;
var
  Len: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1624);{$ENDIF}
  FillChar(Seg, SizeOf(Seg), 0);
  Seg.X0    := X0;   Seg.Z0    := Z0;
  Seg.X1    := X1;   Seg.Z1    := Z1;
  Seg.DX    := X1 - X0;
  Seg.DZ    := Z1 - Z0;
  Seg.LenSq := Seg.DX * Seg.DX + Seg.DZ * Seg.DZ;
  if Seg.LenSq < 0.01 then Exit(False);     { degenerate / duplicate }
  Len       := Sqrt(Seg.LenSq);
  Seg.LenInv := 1.0 / Len;
  Seg.Width  := Width;
  Seg.HalfW  := Width * 0.5;
  Seg.WayId  := WayId;
  Seg.IsBridge := AIsBridge;   { BRIDGE_SNAP }
  { Inflate AABB by the search radius so any point INSIDE the AABB is a
    valid lookup candidate (drops the AABB re-check in the point loop). }
  Seg.BBoxMinX := Min(X0, X1) - SNAP_SEARCH_RADIUS_M;
  Seg.BBoxMaxX := Max(X0, X1) + SNAP_SEARCH_RADIUS_M;
  Seg.BBoxMinZ := Min(Z0, Z1) - SNAP_SEARCH_RADIUS_M;
  Seg.BBoxMaxZ := Max(Z0, Z1) + SNAP_SEARCH_RADIUS_M;
  Result := True;
end;

{ Clamped cell range a segment's bbox covers. False if it falls fully
  outside the grid (caller should skip it). }
function SnapSegCellRange(const Seg: TSnapSegment; const Grid: TSnapGrid;
  out C0X, C1X, C0Z, C1Z: Integer): Boolean; inline;
begin
  C0X := Trunc((Seg.BBoxMinX - Grid.OriginX) / Grid.CellSize);
  C1X := Trunc((Seg.BBoxMaxX - Grid.OriginX) / Grid.CellSize);
  C0Z := Trunc((Seg.BBoxMinZ - Grid.OriginZ) / Grid.CellSize);
  C1Z := Trunc((Seg.BBoxMaxZ - Grid.OriginZ) / Grid.CellSize);
  if C0X < 0 then C0X := 0;
  if C0Z < 0 then C0Z := 0;
  if C1X >= Grid.Cols then C1X := Grid.Cols - 1;
  if C1Z >= Grid.Rows then C1Z := Grid.Rows - 1;
  Result := not ((C1X < 0) or (C0X >= Grid.Cols) or
                 (C1Z < 0) or (C0Z >= Grid.Rows));
end;

procedure BuildSegmentGrid(const Segs: TSnapSegmentArray;
                           out Grid: TSnapGrid);
var
  MinX, MaxX, MinZ, MaxZ: Single;
  I, CellZ, CellX: Integer;
  C0X, C1X, C0Z, C1Z: Integer;
  CellIdx, NumCells: Integer;
  WriteCursor: array of Integer;
  Span, WantCell: Single;
  Acc, Total: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(734);{$ENDIF}
  FillChar(Grid, SizeOf(Grid), 0);
  if Length(Segs) = 0 then
  begin
    Grid.CellSize := SNAP_GRID_CELL_M;
    Grid.Cols     := 1;
    Grid.Rows     := 1;
    SetLength(Grid.Starts, 2);
    SetLength(Grid.Indices, 0);
    Exit;
  end;

  MinX := Segs[0].BBoxMinX;  MaxX := Segs[0].BBoxMaxX;
  MinZ := Segs[0].BBoxMinZ;  MaxZ := Segs[0].BBoxMaxZ;
  for I := 1 to High(Segs) do
  begin
    if Segs[I].BBoxMinX < MinX then MinX := Segs[I].BBoxMinX;
    if Segs[I].BBoxMaxX > MaxX then MaxX := Segs[I].BBoxMaxX;
    if Segs[I].BBoxMinZ < MinZ then MinZ := Segs[I].BBoxMinZ;
    if Segs[I].BBoxMaxZ > MaxZ then MaxZ := Segs[I].BBoxMaxZ;
  end;

  Grid.OriginX := MinX;
  Grid.OriginZ := MinZ;

  { Pick cell size — start at default; grow if needed to keep
    Cols/Rows under SNAP_GRID_MAX_DIM. }
  WantCell := SNAP_GRID_CELL_M;
  Span := Max(MaxX - MinX, MaxZ - MinZ);
  if Span / WantCell > SNAP_GRID_MAX_DIM then
    WantCell := Span / SNAP_GRID_MAX_DIM;
  Grid.CellSize := WantCell;

  Grid.Cols := Max(1, Ceil((MaxX - MinX) / Grid.CellSize));
  Grid.Rows := Max(1, Ceil((MaxZ - MinZ) / Grid.CellSize));
  if Grid.Cols > SNAP_GRID_MAX_DIM then Grid.Cols := SNAP_GRID_MAX_DIM;
  if Grid.Rows > SNAP_GRID_MAX_DIM then Grid.Rows := SNAP_GRID_MAX_DIM;

  NumCells := Grid.Cols * Grid.Rows;
  SetLength(Grid.Starts, NumCells + 1);
  for I := 0 to NumCells do Grid.Starts[I] := 0;

  { Pass A — count entries per cell into Starts[K+1] (so Starts[K]
    is reserved for the cumulative start of cell K after Pass B). }
  for I := 0 to High(Segs) do
  begin
    if not SnapSegCellRange(Segs[I], Grid, C0X, C1X, C0Z, C1Z) then Continue;
    for CellZ := C0Z to C1Z do
      for CellX := C0X to C1X do
        Inc(Grid.Starts[CellZ * Grid.Cols + CellX + 1]);
  end;

  { Pass B — prefix sum: Starts[K+1] held count of cell K; turn that
    into running totals so Starts[K] = start offset of cell K. }
  Acc := 0;
  for I := 1 to NumCells do
  begin
    Acc := Acc + Grid.Starts[I];
    Grid.Starts[I] := Acc;
  end;
  Total := Grid.Starts[NumCells];

  SetLength(Grid.Indices, Total);
  SetLength(WriteCursor, NumCells);
  for I := 0 to NumCells - 1 do WriteCursor[I] := 0;

  { Pass C — scatter indices using the per-cell write cursor. }
  for I := 0 to High(Segs) do
  begin
    if not SnapSegCellRange(Segs[I], Grid, C0X, C1X, C0Z, C1Z) then Continue;
    for CellZ := C0Z to C1Z do
      for CellX := C0X to C1X do
      begin
        CellIdx := CellZ * Grid.Cols + CellX;
        Grid.Indices[Grid.Starts[CellIdx] + WriteCursor[CellIdx]] := I;
        Inc(WriteCursor[CellIdx]);
      end;
  end;
end;

{ Cell containing (PX, PZ). Out-of-range returns -1. }
function GridCellAt(const Grid: TSnapGrid; PX, PZ: Single): Integer; inline;
var CX, CZ: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(735);{$ENDIF}
  CX := Trunc((PX - Grid.OriginX) / Grid.CellSize);
  CZ := Trunc((PZ - Grid.OriginZ) / Grid.CellSize);
  if (CX < 0) or (CX >= Grid.Cols) or
     (CZ < 0) or (CZ >= Grid.Rows) then
    Result := -1
  else
    Result := CZ * Grid.Cols + CX;
end;

{ Valid cells of the 3x3 neighbourhood around (PX,PZ). A segment is binned
  only into cells its SNAP_SEARCH_RADIUS_M-inflated AABB overlaps, so a
  single-cell lookup sees nothing farther than that radius. Scanning one
  cell ring out reaches every segment within SNAP_GRID_CELL_M of the point
  — this is what makes SNAP_FOLLOW_FAR_M > SNAP_SEARCH_RADIUS_M lookups
  possible (callers must still gate by true distance, not the AABB).
  Floor, не Trunc: точка левее/выше origin должна дать ОТРИЦАТЕЛЬНУЮ
  ячейку (и взять соседей из валидного края), а не прилипнуть к нулевой. }
function GridCellsAround(const Grid: TSnapGrid;
  PX, PZ: Single): TCellIndexArray;
var
  CX, CZ, DXc, DZc, NX, NZ, Cnt: Integer;
begin
  Result := nil;
  if (Grid.Cols <= 0) or (Grid.Rows <= 0) then Exit;
  CX := Floor((PX - Grid.OriginX) / Grid.CellSize);
  CZ := Floor((PZ - Grid.OriginZ) / Grid.CellSize);
  SetLength(Result, 9);
  Cnt := 0;
  for DZc := -1 to 1 do
    for DXc := -1 to 1 do
    begin
      NX := CX + DXc;
      NZ := CZ + DZc;
      if (NX < 0) or (NX >= Grid.Cols) or
         (NZ < 0) or (NZ >= Grid.Rows) then Continue;
      Result[Cnt] := NZ * Grid.Cols + NX;
      Inc(Cnt);
    end;
  SetLength(Result, Cnt);
end;

type
  TCandidate = record
    SegIdx:       Integer;
    PerpDist:     Single;   { absolute perpendicular distance to segment line }
    SignedPerp:   Single;   { signed; +/- selects which side }
    FootX, FootZ: Single;   { closest point on segment to the route point }
    AngleDeg:     Single;   { undirected angle to route tangent, 0..90 }
    WayId:        Int64;
    IsBridge:     Boolean;  { BRIDGE_SNAP: deck/tunnel vs ground road }
    Width:        Single;   { EXIT_PRIORITY: roadway vs footway ranking }
  end;

  { One eligible way at one route point, pre-computed for the follow vote:
    the closest segment of that way (widened perp gate = search radius), its
    signed offset and heading error. Small (usually 1-3 per point). }
  TPtFollowCand = record
    WayId:    Int64;
    VoteIndex: Integer;
    Perp:     Single;
    Signed:   Single;
    AngleDeg: Single;
    Width:    Single;   { EXIT_PRIORITY: prefer wide roadway in follow vote }
  end;
  TPtFollowCandArray = array of TPtFollowCand;

{ True = vehicle roadway (secondary+ / multi-lane), not sidewalk/footway. }
function CandIsRoadway(const C: TCandidate): Boolean; inline;
begin
  Result := C.Width > SNAP_WIDE_THRESHOLD_M;
end;

{ BRIDGE_SNAP + EXIT_PRIORITY: True if A is a better match than B.
  Order: bridge deck > ground; vehicle road > footway/path (within
  SNAP_ROAD_OVER_PATH_M); else nearer perpendicular wins. }
function CandBetterThan(const A, B: TCandidate): Boolean;
var
  ARoad, BRoad: Boolean;
begin
  if A.IsBridge and (not B.IsBridge) then
  begin
    if A.PerpDist <= B.PerpDist + SNAP_BRIDGE_PREFER_M then
      Exit(True);
    Exit(False);
  end;
  if B.IsBridge and (not A.IsBridge) then
  begin
    if B.PerpDist <= A.PerpDist + SNAP_BRIDGE_PREFER_M then
      Exit(False);
  end;
  { EXIT_PRIORITY: secondary/exit ramp beats parallel sidewalk. }
  ARoad := CandIsRoadway(A);
  BRoad := CandIsRoadway(B);
  if ARoad and (not BRoad) then
  begin
    if A.PerpDist <= B.PerpDist + SNAP_ROAD_OVER_PATH_M then
      Exit(True);
    Exit(False);
  end;
  if BRoad and (not ARoad) then
  begin
    if B.PerpDist <= A.PerpDist + SNAP_ROAD_OVER_PATH_M then
      Exit(False);
  end;
  Result := A.PerpDist < B.PerpDist;
end;

{ Undirected angle (0..90°) between vectors (ax,az) and (bx,bz). }
function UndirectedAngleDeg(AX, AZ, BX, BZ: Single): Single;
var Dot, La, Lb, Cos90: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(736);{$ENDIF}
  La := Sqrt(AX * AX + AZ * AZ);
  Lb := Sqrt(BX * BX + BZ * BZ);
  if (La < 1.0e-6) or (Lb < 1.0e-6) then
  begin
    Result := 90;
    Exit;
  end;
  Dot := (AX * BX + AZ * BZ) / (La * Lb);
  { Undirected: |dot| so opposite directions also count as "parallel". }
  Cos90 := Abs(Dot);
  if Cos90 > 1.0 then Cos90 := 1.0;
  if Cos90 < 0.0 then Cos90 := 0.0;
  Result := RadToDeg(ArcCos(Cos90));
end;

{ Tangent at point I in a route array. Falls back to neighbour-segment
  direction at the ends. Returns False if the route is too short or
  consecutive points are coincident. }
function ComputeRouteTangent(const Route: TRouteVector3Array;
                             I: Integer;
                             out TX, TZ: Single): Boolean;
var IA, IB: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(737);{$ENDIF}
  TX := 0; TZ := 0;
  Result := False;
  if Length(Route) < 2 then Exit;
  if I <= 0 then begin IA := 0; IB := 1; end
  else if I >= High(Route) then
    begin IA := High(Route) - 1; IB := High(Route); end
  else
    begin IA := I - 1; IB := I + 1; end;
  TX := Route[IB].X - Route[IA].X;
  TZ := Route[IB].Z - Route[IA].Z;
  Result := (TX * TX + TZ * TZ) > 1.0e-8;
end;

function BuildSegmentList(Dataset: TOSMDataset;
  Projection: TLocalProjection): TSnapSegmentArray;
var
  Way:      TOSMWay;
  Params:   TRoadParams;
  S:        TSnapSegment;
  Cap, Cnt: Integer;
  I:        Integer;
  NA, NB:   TOSMNode;
  PA, PB:   TVector3;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(733);{$ENDIF}
  Result := nil;
  if (Dataset = nil) or (Projection = nil) then Exit;

  Cap := 1024;
  SetLength(Result, Cap);
  Cnt := 0;

  for Way in Dataset.Ways.Values do
  begin
    if Way = nil then Continue;
    Params := TRoadBuilder.ParseRoadParams(Way.Tags);

    { Skip non-road and railway. Railways are off-limits for any
      reasonable GPS track. Foot / cycle / path / asphalt all count. }
    if Params.Kind = rkNone then Continue;
    if Params.Kind = rkRailway then Continue;
    if Params.Width < 0.5 then Continue;     { junk way }

    for I := 0 to High(Way.NodeRefs) - 1 do
    begin
      NA := Dataset.FindNode(Way.NodeRefs[I]);
      NB := Dataset.FindNode(Way.NodeRefs[I + 1]);
      if (NA = nil) or (NB = nil) then Continue;

      PA := Projection.Project(NA.Position, 0);
      PB := Projection.Project(NB.Position, 0);

      { Shared derivation — identical to the tile-cache path.
        BRIDGE_SNAP: mark bridge/tunnel ways so ranking prefers the deck. }
      if not TRouteSnapper.MakeSnapSegment(
               PA.X, PA.Z, PB.X, PB.Z, Params.Width, Way.Id, S,
               OsmWayIsBridge(Way.Tags) or OsmWayIsTunnel(Way.Tags)) then
        Continue;

      if Cnt >= Cap then
      begin
        Cap := Cap * 2;
        SetLength(Result, Cap);
      end;
      Result[Cnt] := S;
      Inc(Cnt);
    end;
  end;

  SetLength(Result, Cnt);
end;

{ Convenience entry point — snap against a live TOSMDataset. }
class function TRouteSnapper.Snap(const Route: TRouteLatLonArray;
  Dataset: TOSMDataset; Projection: TLocalProjection;
  out Widths: TRouteWidthArray;
  out Centers: TRouteLatLonArray;
  Log: TLogTarget; const ADebugPath: string;
  AProgress: PInteger; AWaysOut: PRouteWayIdArray): TRouteLatLonArray;
var
  Segs: TSnapSegmentArray;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1239);{$ENDIF}
  if (Dataset = nil) or (Projection = nil) then
  begin
    SetLength(Result, Length(Route));
    SetLength(Widths, Length(Route));   { all zero — off-road }
    SetLength(Centers, Length(Route));
    if AWaysOut <> nil then
    begin
      AWaysOut^ := nil;
      SetLength(AWaysOut^, Length(Route));   { нули — не притянуто }
    end;
    if Length(Route) > 0 then
    begin
      Move(Route[0], Result[0], Length(Route) * SizeOf(Route[0]));
      Move(Route[0], Centers[0], Length(Route) * SizeOf(Route[0]));
    end;
    if Log <> nil then
      Log.Write(llInfo,
        Format('RouteSnapper: nothing to do (hasDataset=%s, hasProj=%s)',
          [BoolToStr(Dataset <> nil, 'yes', 'no'),
           BoolToStr(Projection <> nil, 'yes', 'no')]));
    Exit;
  end;
  Segs := BuildSegmentList(Dataset, Projection);
  Result := Snap(Route, Segs, Projection, Widths, Centers, Log, ADebugPath,
                 AProgress, AWaysOut);
end;

{ Core snap — segment array in, snapped route out. One walk + a post-pass:
    1) per-point candidate scan through the eligibility gates;
    2) way-stickiness: the way the route is currently following keeps the
       point unless a different way beats it by SNAP_STICKY_ADVANTAGE_M,
       and continuation on the same way bypasses the ambiguity guard;
    3) island post-pass: a short run snapped onto some other way (or not
       snapped at all), sandwiched by one and the same way, is pulled back
       onto it — the path was on that road and stays on it. }
class function TRouteSnapper.Snap(const Route: TRouteLatLonArray;
  const Segs: TSnapSegmentArray; Projection: TLocalProjection;
  out Widths: TRouteWidthArray;
  out Centers: TRouteLatLonArray;
  Log: TLogTarget; const ADebugPath: string;
  AProgress: PInteger; AWaysOut: PRouteWayIdArray): TRouteLatLonArray;
type
  TFollowWindowWay = record
    WayId: Int64;
    Cov, CovN, WideCount, ActiveIndex: Integer;
    SumS, Sum2, SumH, SumSN, Sum2N, SumHN: Double;
  end;
var
  Grid:         TSnapGrid;
  RouteLocal:   TRouteVector3Array;
  CumLen:       array of Single;    { накопленная длина маршрута до точки, м }
  ChosenWay:    array of Int64;     { way, на которую снапнута точка; 0 = нет }
  ChosenSeg:    array of Integer;   { exact segment; -1 for an unmatched point }
  N, I, K, J:   Integer;
  PX, PZ:       Single;
  TX, TZ:       Single;
  HasTangent:   Boolean;
  SegRef:       Integer;
  S:            ^TSnapSegment;
  T, TRaw, Cx, Cz, Dx, Dz, D: Single;
  Best, Second, BestPrev, RC: TCandidate;
  HasBest, HasSecond, HasBestPrev: Boolean;
  Cand:         TCandidate;
  Stats:        TRouteSnapStats;
  PrevWayId:    Int64;
  GapSinceSnapM: Single;
  StickyAdv:    Single;   { BRIDGE_SNAP: raised sticky margin on decks }
  LastWayIdx:   specialize TDictionary<Int64, Integer>;
  IslandLeft:   Integer;
  ProtectedIslandPrefix: array of Integer;
  { path-follow pre-pass state }
  PtCands:      array of TPtFollowCandArray;   { per point: eligible ways }
  FollowWay:    array of Int64;                { per point: voted way, 0=none }
  FollowFar:    array of Boolean;              { per point: голос из дальней полосы }
  FW:           Int64;
  FI, FM, FC:   Integer;
  FCells:       TCellIndexArray;
  FFound:       Boolean;
  FT, FCx, FCz, FDx, FDz, FD, FSigned, FAng, FTX, FTZ, FMaxD: Single;
  { отдельный лог фита (ADebugPath): пер-точечные заметки собираются по
    ходу решений и выгружаются одним файлом в конце — сбор дёшев и
    включается только при непустом пути }
  DbgOn:    Boolean;
  Note:     array of string;   { итог решения по точке + причина }
  VoteNote: array of string;   { вердикт оконного голоса по точке }
  DbgL:     TStringList;
  DLine:    string;
  DP:       TLatLon;           { узел осевой дороги для дампа геометрии }
  DNodes:   Integer;
  WSegs:    specialize TDictionary<Int64, TCellIndexArray>;  { way → индексы её сегментов }
  IdxArr:   TCellIndexArray;
  WPair:    specialize TPair<Int64, TCellIndexArray>;
  VoteIndex: specialize TDictionary<Int64, Integer>;
  VoteWays: array of TFollowWindowWay;
  ActiveWays: array of Integer;
  ActiveCount, WindowLo, WindowHi, VoteWayCount, VI: Integer;

  { Each candidate enters/leaves the window once. Width is only used as
    a threshold in the vote, so counting wide samples replaces a max scan. }
  procedure UpdateVotePoint(PointIndex, Delta: Integer);
  var
    M, W, Slot: Integer;
    C: ^TPtFollowCand;
    V: ^TFollowWindowWay;
  begin
    for M := 0 to High(PtCands[PointIndex]) do
    begin
      C := @PtCands[PointIndex][M];
      W := C^.VoteIndex;
      V := @VoteWays[W];
      if (Delta > 0) and (V^.Cov = 0) then
      begin
        V^.ActiveIndex := ActiveCount;
        ActiveWays[ActiveCount] := W;
        Inc(ActiveCount);
      end;
      Inc(V^.Cov, Delta);
      V^.SumS := V^.SumS + Delta * Double(C^.Signed);
      V^.Sum2 := V^.Sum2 + Delta * Sqr(Double(C^.Signed));
      V^.SumH := V^.SumH + Delta * Double(C^.AngleDeg);
      if C^.Width > SNAP_WIDE_THRESHOLD_M then Inc(V^.WideCount, Delta);
      if C^.Perp <= SNAP_SEARCH_RADIUS_M then
      begin
        Inc(V^.CovN, Delta);
        V^.SumSN := V^.SumSN + Delta * Double(C^.Signed);
        V^.Sum2N := V^.Sum2N + Delta * Sqr(Double(C^.Signed));
        V^.SumHN := V^.SumHN + Delta * Double(C^.AngleDeg);
        if V^.CovN = 0 then
        begin
          V^.SumSN := 0; V^.Sum2N := 0; V^.SumHN := 0;
        end;
      end;
      if V^.Cov = 0 then
      begin
        Slot := V^.ActiveIndex;
        Dec(ActiveCount);
        ActiveWays[Slot] := ActiveWays[ActiveCount];
        VoteWays[ActiveWays[Slot]].ActiveIndex := Slot;
        V^.SumS := 0; V^.Sum2 := 0; V^.SumH := 0;
      end;
    end;
  end;

  { Поставить снап-цель точки Idx по кандидату C: узкая дорога → осевая,
    широкая → полоса с отступом SNAP_WIDE_EDGE_OFFSET_M от кромки, сторона —
    по знаку перпендикуляра исходной точки. ЕДИНСТВЕННОЕ место геометрии
    постановки: им пользуются и основной проход, и остров-rejoin. Счётчики
    Edge/Center здесь не трогаются — они пересчитываются один раз в конце
    по финальному состоянию (rejoin переписывает точки). }
  procedure PlaceSnap(Idx: Integer; const C: TCandidate);
  var
    Sp: ^TSnapSegment;
    HalfWInset, PerpX, PerpZ, Sign, SnapX, SnapZ: Single;
  begin
    Sp := @Segs[C.SegIdx];
    { Point successfully snapped — expose the road's width so the rider
      can be lane-positioned along it. Off-road points keep width 0. }
    Widths[Idx] := Sp^.Width;
    if Sp^.Width > SNAP_WIDE_THRESHOLD_M then
    begin
      { Unit perpendicular (-DZ, DX) * LenInv. }
      PerpX      := -Sp^.DZ * Sp^.LenInv;
      PerpZ      :=  Sp^.DX * Sp^.LenInv;
      HalfWInset := Sp^.HalfW - SNAP_WIDE_EDGE_OFFSET_M;
      if HalfWInset < 0 then HalfWInset := 0;
      if C.SignedPerp >= 0 then Sign := 1 else Sign := -1;
      SnapX := C.FootX + Sign * HalfWInset * PerpX;
      SnapZ := C.FootZ + Sign * HalfWInset * PerpZ;
    end
    else
    begin
      SnapX := C.FootX;
      SnapZ := C.FootZ;
    end;
    Result[Idx] := Projection.Unproject(SnapX, SnapZ);
    { Центр дороги для этой точки — фут на осевой сегмента (к нему
      притягивал снаппер). Для широких дорог снап-цель смещена в полосу,
      но центр — именно осевая. Используется отладкой. }
    Centers[Idx] := Projection.Unproject(C.FootX, C.FootZ);
    ChosenWay[Idx] := C.WayId;
    ChosenSeg[Idx] := C.SegIdx;
  end;

  function SegmentsMeet(const A, B: TSnapSegment): Boolean;
  const EndpointToleranceSq = 0.0025; { 5 cm: shared cached vertex, not a crossing }
  begin
    Result := (Sqr(A.X0-B.X0)+Sqr(A.Z0-B.Z0)<=EndpointToleranceSq) or
      (Sqr(A.X0-B.X1)+Sqr(A.Z0-B.Z1)<=EndpointToleranceSq) or
      (Sqr(A.X1-B.X0)+Sqr(A.Z1-B.Z0)<=EndpointToleranceSq) or
      (Sqr(A.X1-B.X1)+Sqr(A.Z1-B.Z1)<=EndpointToleranceSq);
  end;

  { A central tangent straddles both legs of a junction. It must not reject
    the road under the rider just because the next raw point turns away.
    Only admit the known incoming road, inside its width and connected to
    the preceding chosen segment. Nearby unconnected hairpin arms retain
    the ordinary angle gate. Structures retain their existing policy. }
  function CloseIncomingCorner(Idx, CandidateSeg: Integer; Distance: Single): Boolean;
  var Previous: Integer; SX, SZ: Single;
  begin
    Result := False;
    if Idx<=0 then Exit;
    Previous := ChosenSeg[Idx-1];
    if (Previous<0) or (Segs[CandidateSeg].WayId<>ChosenWay[Idx-1]) or
       Segs[CandidateSeg].IsBridge or Segs[Previous].IsBridge or
       (Distance>Segs[CandidateSeg].HalfW) then Exit;
    if (CandidateSeg<>Previous) and
       not SegmentsMeet(Segs[CandidateSeg],Segs[Previous]) then Exit;
    SX:=RouteLocal[Idx].X-RouteLocal[Idx-1].X;
    SZ:=RouteLocal[Idx].Z-RouteLocal[Idx-1].Z;
    Result := UndirectedAngleDeg(SX,SZ,Segs[CandidateSeg].DX,
      Segs[CandidateSeg].DZ)<=SNAP_PARALLEL_MAX_ANGLE_DEG;
  end;

  { Do not extend an ordinary road's sticky hold beyond a proven turn onto
    its connected outgoing road or path. Both the raw step and the close foot
    must identify that exit; a parallel road, crossing, structure or merely
    distant candidate does not qualify. Evaluate the current candidates,
    since follow/hold may have replaced them earlier in this iteration. }
  function ConnectedRawTurn(Idx: Integer; const NewRoad, OldRoad: TCandidate): Boolean;
  var SX,SZ: Single;
  begin
    Result := False;
    if (Idx<=0) or (NewRoad.WayId=OldRoad.WayId) or
       (ChosenWay[Idx-1]<>OldRoad.WayId) or
       NewRoad.IsBridge or OldRoad.IsBridge or
       (NewRoad.PerpDist>Segs[NewRoad.SegIdx].HalfW) or
       (NewRoad.PerpDist+1.0>=OldRoad.PerpDist) or
       not SegmentsMeet(Segs[NewRoad.SegIdx],Segs[OldRoad.SegIdx]) then Exit;
    SX:=RouteLocal[Idx].X-RouteLocal[Idx-1].X;
    SZ:=RouteLocal[Idx].Z-RouteLocal[Idx-1].Z;
    Result := (UndirectedAngleDeg(SX,SZ,Segs[NewRoad.SegIdx].DX,
      Segs[NewRoad.SegIdx].DZ)<=SNAP_PARALLEL_MAX_ANGLE_DEG) and
      (UndirectedAngleDeg(SX,SZ,Segs[OldRoad.SegIdx].DX,
      Segs[OldRoad.SegIdx].DZ)>SNAP_PARALLEL_MAX_ANGLE_DEG);
  end;

  function PointCandBetter(const A, B: TCandidate): Boolean;
  begin
    { A recorded, connected turn can enter a cycleway/path too. Apply this
      before the broad roadway-over-footpath preference, not just in hold. }
    if ConnectedRawTurn(I,A,B) then Exit(True);
    if ConnectedRawTurn(I,B,A) then Exit(False);
    Result:=CandBetterThan(A,B);
  end;

  procedure ProtectRecordedBranches;
  var First,Last,Q,A,B:Integer; Good,Distinct:Boolean;
    Foot:TVector3; ProtectedPoints:array of Boolean;
  begin
    { A-B-A can be a real recorded branch, not a noisy snap island. Preserve
      the complete accurate non-structure B run and its connected anchors.
      Compute before rejoin mutations. The prefix also protects a nested
      branch from a larger rejoin that would otherwise move its anchors. }
    SetLength(ProtectedPoints,N);SetLength(ProtectedIslandPrefix,N+1);
    First:=0;
    while First<N do begin
      Last:=First;
      while (Last+1<N) and (ChosenWay[Last+1]=ChosenWay[First]) do Inc(Last);
      Good:=(First>0) and (Last<N-1) and (Last>First) and (ChosenWay[First]<>0);
      if Good then begin
        A:=ChosenSeg[First-1];B:=ChosenSeg[Last+1];
        Good:=(ChosenWay[First-1]<>0) and
          (ChosenWay[First-1]=ChosenWay[Last+1]) and (A>=0) and (B>=0) and
          not Segs[A].IsBridge and not Segs[B].IsBridge and
          SegmentsMeet(Segs[A],Segs[ChosenSeg[First]]) and
          SegmentsMeet(Segs[ChosenSeg[Last]],Segs[B]);
      end;
      Distinct:=False;
      if Good then for Q:=First to Last do begin
        Foot:=Projection.Project(Centers[Q]);
        if (ChosenSeg[Q]<0) or Segs[ChosenSeg[Q]].IsBridge or
          (Sqr(Foot.X-RouteLocal[Q].X)+Sqr(Foot.Z-RouteLocal[Q].Z)>
           Sqr(Segs[ChosenSeg[Q]].HalfW)) then begin Good:=False;Break end;
        if Sqr(RouteLocal[Q].X-RouteLocal[First].X)+
          Sqr(RouteLocal[Q].Z-RouteLocal[First].Z)>0.0001 then Distinct:=True;
      end;
      if Good and Distinct then
        for Q:=First-1 to Last+1 do ProtectedPoints[Q]:=True;
      First:=Last+1;
    end;
    for Q:=0 to N-1 do
      ProtectedIslandPrefix[Q+1]:=ProtectedIslandPrefix[Q]+Ord(ProtectedPoints[Q]);
  end;

  { Лучший (минимальный по перпендикуляру) кандидат ИМЕННО way AWay возле
    точки Idx, со своим порогом дистанции. Углового гейта нет намеренно —
    см. комментарий у SNAP_ISLAND_REJOIN_MAX_M. Обходит 3x3 окрестность
    ячеек, поэтому MaxDist обязан быть <= SNAP_GRID_CELL_M. AABB сегментов
    раздуты лишь на SNAP_SEARCH_RADIUS_M — для MaxDist сверх него AABB-тест
    ослабляется на разницу (истинный гейт — дистанция ниже). Используется
    остров-rejoin'ом и притяжением по «следованию». }
  function FindWayCand(Idx: Integer; AWay: Int64;
    MaxDist: Single; out C: TCandidate): Boolean;
  var
    LT, LTRaw, LCx, LCz, LDx, LDz, LD, LSlack: Single;
    LK, LRef, LCi: Integer;
    LCells: TCellIndexArray;
    LS: ^TSnapSegment;
  begin
    Result := False;
    FillChar(C, SizeOf(C), 0);
    LSlack := MaxDist - SNAP_SEARCH_RADIUS_M;
    if LSlack < 0 then LSlack := 0;
    LCells := GridCellsAround(Grid, RouteLocal[Idx].X, RouteLocal[Idx].Z);
    for LCi := 0 to High(LCells) do
    for LK := Grid.Starts[LCells[LCi]] to Grid.Starts[LCells[LCi] + 1] - 1 do
    begin
      LRef := Grid.Indices[LK];
      LS := @Segs[LRef];
      if LS^.WayId <> AWay then Continue;
      { Сегмент может лежать в нескольких соседних ячейках — дубль отсеет
        сравнение LD >= C.PerpDist ниже. }
      if (RouteLocal[Idx].X < LS^.BBoxMinX - LSlack) or
         (RouteLocal[Idx].X > LS^.BBoxMaxX + LSlack) or
         (RouteLocal[Idx].Z < LS^.BBoxMinZ - LSlack) or
         (RouteLocal[Idx].Z > LS^.BBoxMaxZ + LSlack) then
        Continue;
      LT := ((RouteLocal[Idx].X - LS^.X0) * LS^.DX +
             (RouteLocal[Idx].Z - LS^.Z0) * LS^.DZ) / LS^.LenSq;
      LTRaw := LT;
      if LT < 0 then LT := 0
      else if LT > 1 then LT := 1;
      LCx := LS^.X0 + LT * LS^.DX;
      LCz := LS^.Z0 + LT * LS^.DZ;
      LDx := RouteLocal[Idx].X - LCx;
      LDz := RouteLocal[Idx].Z - LCz;
      LD  := Sqrt(LDx * LDx + LDz * LDz);
      if LD > MaxDist then Continue;
      { Keep the same endpoint allowance as the primary candidate pass. }
      if ((LTRaw < 0) or (LTRaw > 1)) and
         (LD > LS^.HalfW + SNAP_PERP_BEYOND_HALFW_M) then Continue;
      if Result and (LD >= C.PerpDist) then Continue;
      C.SegIdx     := LRef;
      C.PerpDist   := LD;
      C.SignedPerp := (LDx * (-LS^.DZ) + LDz * LS^.DX) * LS^.LenInv;
      C.FootX      := LCx;
      C.FootZ      := LCz;
      C.AngleDeg   := 0;
      C.WayId      := AWay;
      C.IsBridge   := LS^.IsBridge;   { BRIDGE_SNAP }
      C.Width      := LS^.Width;      { EXIT_PRIORITY }
      Result       := True;
    end;
  end;

  { SNAP_GAP_FILL: nearest segment within MaxDist with NO angle gate.
    Prefer vehicle roadway (Width > SNAP_WIDE_THRESHOLD_M) so a sidewalk
    1 m closer does not win. Used when point-gates leave a hole over a
    real road (post-bridge exit). }
  function FindNearestRoadCand(Idx: Integer; MaxDist: Single;
    out C: TCandidate): Boolean;
  var
    LT, LTRaw, LCx, LCz, LDx, LDz, LD, LSlack: Single;
    LK, LRef, LCi: Integer;
    LCells: TCellIndexArray;
    LS: ^TSnapSegment;
    Cand: TCandidate;
    HasAny: Boolean;
  begin
    Result := False;
    HasAny := False;
    FillChar(C, SizeOf(C), 0);
    LSlack := MaxDist - SNAP_SEARCH_RADIUS_M;
    if LSlack < 0 then LSlack := 0;
    LCells := GridCellsAround(Grid, RouteLocal[Idx].X, RouteLocal[Idx].Z);
    for LCi := 0 to High(LCells) do
    for LK := Grid.Starts[LCells[LCi]] to Grid.Starts[LCells[LCi] + 1] - 1 do
    begin
      LRef := Grid.Indices[LK];
      LS := @Segs[LRef];
      if (RouteLocal[Idx].X < LS^.BBoxMinX - LSlack) or
         (RouteLocal[Idx].X > LS^.BBoxMaxX + LSlack) or
         (RouteLocal[Idx].Z < LS^.BBoxMinZ - LSlack) or
         (RouteLocal[Idx].Z > LS^.BBoxMaxZ + LSlack) then
        Continue;
      LT := ((RouteLocal[Idx].X - LS^.X0) * LS^.DX +
             (RouteLocal[Idx].Z - LS^.Z0) * LS^.DZ) / LS^.LenSq;
      LTRaw := LT;
      if LT < 0 then LT := 0
      else if LT > 1 then LT := 1;
      LCx := LS^.X0 + LT * LS^.DX;
      LCz := LS^.Z0 + LT * LS^.DZ;
      LDx := RouteLocal[Idx].X - LCx;
      LDz := RouteLocal[Idx].Z - LCz;
      LD  := Sqrt(LDx * LDx + LDz * LDz);
      if LD > MaxDist then Continue;
      { Keep the same endpoint allowance as the primary candidate pass. }
      if ((LTRaw < 0) or (LTRaw > 1)) and
         (LD > LS^.HalfW + SNAP_PERP_BEYOND_HALFW_M) then Continue;
      Cand.SegIdx     := LRef;
      Cand.PerpDist   := LD;
      Cand.SignedPerp := (LDx * (-LS^.DZ) + LDz * LS^.DX) * LS^.LenInv;
      Cand.FootX      := LCx;
      Cand.FootZ      := LCz;
      Cand.AngleDeg   := 0;
      Cand.WayId      := LS^.WayId;
      Cand.IsBridge   := LS^.IsBridge;
      Cand.Width      := LS^.Width;
      if (not HasAny) or CandBetterThan(Cand, C) then
      begin
        C := Cand;
        HasAny := True;
      end;
    end;
    Result := HasAny;
  end;

  { Оконный голос «следования» для точки Idx: по предвычисленным PtCands
    в окне ±SNAP_FOLLOW_WINDOW_M вдоль маршрута накапливает для каждой way
    покрытие, средний знаковый перпендикуляр, его разброс и средний угол.
    Возвращает way, которой трек в целом СЛЕДУЕТ (параллелен и держит
    смещение), или 0, если решительного победителя нет — тогда точку решают
    поточечная логика/липкость/острова. Ключ к «смещённой, но верной»
    дороге: постоянное смещение → малый разброс знака при любой |величине|.

    Две фазы. Фаза 1 — только образцы обычной полосы
    (Perp <= SNAP_SEARCH_RADIUS_M): тот же набор данных и те же пороги, что
    до появления дальней полосы, поведение прежних случаев не меняется.
    Фаза 2 — ТОЛЬКО когда в обычной полосе не нашлось ни одной
    сопровождаемой way («не найдено иного»): в ход идут все образцы вплоть
    до SNAP_FOLLOW_FAR_M, но с планкой покрытия
    SNAP_FOLLOW_FAR_MIN_COVERAGE — захват с 30 м оправдан лишь ДЛИННЫМ
    совпадением. AFar=True у победителя фазы 2: снап получает право тянуть
    точку с SNAP_FOLLOW_FAR_M вместо SNAP_FOLLOW_REJOIN_MAX_M. }
  function WayFollowVote(Idx: Integer; out AFar: Boolean): Int64;
  var
    A, Wj, WinPts: Integer;
    AnyNearStrong: Boolean;
    Mu, Sd, Cover, Head, Par, Score, Best, Second: Double;
    BestWay: Int64;
    VBCov, VBSd, VBHead: Single;   { статистика текущего лидера — для лога }
  begin
    Result := 0;
    AFar   := False;
    { Calls arrive in route order; CumLen is nondecreasing, even at stops. }
    while (WindowHi < N - 1) and
      (CumLen[WindowHi + 1] - CumLen[Idx] <= SNAP_FOLLOW_WINDOW_M) do
    begin
      Inc(WindowHi);
      UpdateVotePoint(WindowHi, 1);
    end;
    while (WindowLo < Idx) and
      (CumLen[Idx] - CumLen[WindowLo] > SNAP_FOLLOW_WINDOW_M) do
    begin
      UpdateVotePoint(WindowLo, -1);
      Inc(WindowLo);
    end;
    WinPts := WindowHi - WindowLo + 1;
    if WinPts < 3 then
    begin
      if DbgOn then VoteNote[Idx] := 'окно<3 точек';
      Exit;
    end;

    { Фаза 1: обычная полоса. Статистика — только по ближним образцам,
      это в точности прежний набор данных и прежние гейты.
      EXIT_PRIORITY: +score for vehicle roadway so follow vote does not
      lock the track onto a parallel sidewalk. }
    AnyNearStrong := False;
    Best := -1.0e30;  Second := -1.0e30;  BestWay := 0;
    for A := 0 to ActiveCount - 1 do
    begin
      Wj := ActiveWays[A];
      if VoteWays[Wj].CovN < 3 then Continue;
      Cover := VoteWays[Wj].CovN / WinPts;
      if Cover < SNAP_FOLLOW_MIN_COVERAGE then Continue;
      Mu := VoteWays[Wj].SumSN / VoteWays[Wj].CovN;
      Sd := VoteWays[Wj].Sum2N / VoteWays[Wj].CovN - Mu * Mu;
      if Sd < 0 then Sd := 0;
      Sd := Sqrt(Sd);
      if Sd > SNAP_FOLLOW_MAX_SPREAD_M then Continue;
      Head := VoteWays[Wj].SumHN / VoteWays[Wj].CovN;
      if Head > SNAP_FOLLOW_MAX_HEADING_DEG then Continue;
      AnyNearStrong := True;
      Par   := 1.0 / (1.0 + Sd);
      Score := 2.0 * Cover + 1.5 * Par +
               1.0 * (1.0 - Head / SNAP_PARALLEL_MAX_ANGLE_DEG) - 0.15 * Sd;
      if VoteWays[Wj].WideCount > 0 then
        Score := Score + 1.25;   { EXIT_PRIORITY: roadway > footway }
      if Score > Best then
        begin
          Second := Best; Best := Score; BestWay := VoteWays[Wj].WayId;
          VBCov := Cover; VBSd := Sd; VBHead := Head;
        end
      else if Score > Second then
        Second := Score;
    end;
    if AnyNearStrong then
    begin
      { В обычной полосе что-то найдено — дальняя полоса не участвует
        вовсе: ни победить, ни размыть отрыв она не может. }
      if (BestWay <> 0) and (Best - Second >= SNAP_FOLLOW_MARGIN) then
      begin
        Result := BestWay;
        if DbgOn then
          VoteNote[Idx] := Format(
            'близ: w%d score=%.2f отрыв=%.2f cov=%.2f σ=%.2fм угол=%.1f°',
            [BestWay, Best, Best - Second, VBCov, VBSd, VBHead]);
      end
      else if DbgOn then
      begin
        if BestWay <> 0 then
          VoteNote[Idx] := Format(
            'близ: воздержался — отрыв %.2f < %.2f (лидер w%d score=%.2f)',
            [Best - Second, SNAP_FOLLOW_MARGIN, BestWay, Best])
        else
          VoteNote[Idx] := 'близ: ни одна way не прошла гейты';
      end;
      Exit;
    end;

    { Фаза 2: в обычной полосе не найдено ничего сопровождаемого —
      расширяем поиск до SNAP_FOLLOW_FAR_M. Требуем ДЛИННОЕ совпадение
      (планка покрытия выше), гейты разброса и курса те же. }
    Best := -1.0e30;  Second := -1.0e30;  BestWay := 0;
    for A := 0 to ActiveCount - 1 do
    begin
      Wj := ActiveWays[A];
      if VoteWays[Wj].Cov < 3 then Continue;
      Cover := VoteWays[Wj].Cov / WinPts;
      if Cover < SNAP_FOLLOW_FAR_MIN_COVERAGE then Continue;
      Mu := VoteWays[Wj].SumS / VoteWays[Wj].Cov;
      Sd := VoteWays[Wj].Sum2 / VoteWays[Wj].Cov - Mu * Mu;
      if Sd < 0 then Sd := 0;
      Sd := Sqrt(Sd);
      if Sd > SNAP_FOLLOW_MAX_SPREAD_M then Continue;
      Head := VoteWays[Wj].SumH / VoteWays[Wj].Cov;
      if Head > SNAP_FOLLOW_MAX_HEADING_DEG then Continue;
      Par   := 1.0 / (1.0 + Sd);
      Score := 2.0 * Cover + 1.5 * Par +
               1.0 * (1.0 - Head / SNAP_PARALLEL_MAX_ANGLE_DEG) - 0.15 * Sd;
      if VoteWays[Wj].WideCount > 0 then
        Score := Score + 1.25;   { EXIT_PRIORITY }
      if Score > Best then
        begin
          Second := Best; Best := Score; BestWay := VoteWays[Wj].WayId;
          VBCov := Cover; VBSd := Sd; VBHead := Head;
        end
      else if Score > Second then
        Second := Score;
    end;
    if (BestWay <> 0) and (Best - Second >= SNAP_FOLLOW_MARGIN) then
    begin
      Result := BestWay;
      AFar   := True;
      if DbgOn then
        VoteNote[Idx] := Format(
          'даль(до %.0fм): w%d score=%.2f отрыв=%.2f cov=%.2f σ=%.2fм угол=%.1f°',
          [SNAP_FOLLOW_FAR_M, BestWay, Best, Best - Second,
           VBCov, VBSd, VBHead]);
    end
    else if DbgOn then
    begin
      if BestWay <> 0 then
        VoteNote[Idx] := Format(
          'даль: воздержался — отрыв %.2f < %.2f (лидер w%d)',
          [Best - Second, SNAP_FOLLOW_MARGIN, BestWay])
      else
        VoteNote[Idx] := 'нет сопровождаемой way (ни близ, ни даль)';
    end;
  end;

  { A confirmed bridge/tunnel traversal may only leave through its connected
    approaches. Nearest-way voting alone can switch through a tunnel wall to
    a parallel surface road. This bounded post-pass runs once during snapping. }
  procedure RepairStructureContinuity;
  type TApproach = record WayId:Int64; X,Z:Single end;
  var ByWay:specialize TDictionary<Int64,TCellIndexArray>;
    Original:array of Int64; Own,Allowed,A:TCellIndexArray;
    Approaches:array of TApproach;
    First,Last,Si,Sj,E,AP,Count,Idx,Step,StopAt,Q:Integer;
    W:Int64; X,Z,OX,OZ,TX0,TZ0,Dot,BestDot,Len,BestDist,LT,
      QX,QZ,DX0,DZ0,Dist,RTx,RTz:Single;
    Inner,Duplicate,Have:Boolean; Pick:TCandidate;

    function CandidateAt(Pt:Integer;out C:TCandidate):Boolean;
    var V,R,M:Integer; S0:^TSnapSegment; NearPortal:Boolean;
    begin
      Result:=False; BestDist:=1e30;
      if not ComputeRouteTangent(RouteLocal,Pt,RTx,RTz) then Exit;
      for V:=0 to High(Allowed) do
      begin
        R:=Allowed[V]; S0:=@Segs[R];
        if UndirectedAngleDeg(RTx,RTz,S0^.DX,S0^.DZ)>45 then Continue;
        LT:=((RouteLocal[Pt].X-S0^.X0)*S0^.DX+
             (RouteLocal[Pt].Z-S0^.Z0)*S0^.DZ)/S0^.LenSq;
        { Cover the small wedge outside a bent shared endpoint. Large
          longitudinal gaps still cannot collapse onto a terminal vertex. }
        if (LT < -5*S0^.LenInv) or (LT > 1+5*S0^.LenInv) then Continue;
        if LT<0 then LT:=0 else if LT>1 then LT:=1;
        QX:=S0^.X0+LT*S0^.DX; QZ:=S0^.Z0+LT*S0^.DZ;
        if S0^.WayId<>W then
        begin
          NearPortal:=False;
          for M:=0 to High(Approaches) do
            if (Approaches[M].WayId=S0^.WayId) and
               (Sqr(QX-Approaches[M].X)+Sqr(QZ-Approaches[M].Z)<=Sqr(80.0)) then
              NearPortal:=True;
          if not NearPortal then Continue;
        end;
        DX0:=RouteLocal[Pt].X-QX; DZ0:=RouteLocal[Pt].Z-QZ;
        Dist:=Sqrt(DX0*DX0+DZ0*DZ0);
        if (Dist>SNAP_POINT_MAX_PERP_M) or (Dist>=BestDist) then Continue;
        BestDist:=Dist; Result:=True; FillChar(C,SizeOf(C),0);
        C.SegIdx:=R; C.WayId:=S0^.WayId; C.IsBridge:=S0^.IsBridge;
        C.FootX:=QX; C.FootZ:=QZ; C.PerpDist:=Dist;
        C.SignedPerp:=(DX0*(-S0^.DZ)+DZ0*S0^.DX)*S0^.LenInv;
      end;
    end;

  begin
    ByWay:=specialize TDictionary<Int64,TCellIndexArray>.Create;
    try
      for Si:=0 to High(Segs) do
      begin
        if not ByWay.TryGetValue(Segs[Si].WayId,A) then A:=nil;
        SetLength(A,Length(A)+1); A[High(A)]:=Si;
        ByWay.AddOrSetValue(Segs[Si].WayId,A);
      end;
      Original:=Copy(ChosenWay); First:=0;
      while First<N do
      begin
        W:=Original[First]; Last:=First;
        while (Last+1<N) and (Original[Last+1]=W) do Inc(Last);
        if (W<>0) and (CumLen[Last]-CumLen[First]>=20) and
           ByWay.TryGetValue(W,Own) and Segs[Own[0]].IsBridge then
        begin
          Allowed:=Copy(Own); Approaches:=nil;
          for Si in Own do for E:=0 to 1 do
          begin
            if E=0 then begin X:=Segs[Si].X0; Z:=Segs[Si].Z0;
              OX:=Segs[Si].X1; OZ:=Segs[Si].Z1 end
            else begin X:=Segs[Si].X1; Z:=Segs[Si].Z1;
              OX:=Segs[Si].X0; OZ:=Segs[Si].Z0 end;
            Inner:=False;
            for Sj in Own do
            begin
              Duplicate:=((Sqr(Segs[Sj].X0-X)+Sqr(Segs[Sj].Z0-Z)<0.01) and
                          (Sqr(Segs[Sj].X1-OX)+Sqr(Segs[Sj].Z1-OZ)<0.01)) or
                         ((Sqr(Segs[Sj].X1-X)+Sqr(Segs[Sj].Z1-Z)<0.01) and
                          (Sqr(Segs[Sj].X0-OX)+Sqr(Segs[Sj].Z0-OZ)<0.01));
              if Duplicate then Continue;
              if (Sqr(Segs[Sj].X0-X)+Sqr(Segs[Sj].Z0-Z)<0.01) or
                 (Sqr(Segs[Sj].X1-X)+Sqr(Segs[Sj].Z1-Z)<0.01) then Inner:=True;
            end;
            if Inner then Continue;
            { Pick the outward connected roadway, never a nearby crossing.
              Requiring a forward continuation avoids branches at junctions. }
            BestDot:=0.7; AP:=-1; Len:=Sqrt(Sqr(X-OX)+Sqr(Z-OZ));
            for Sj:=0 to High(Segs) do
            begin
              if (Segs[Sj].WayId=W) or (Segs[Sj].Width<3) then Continue;
              if Sqr(Segs[Sj].X0-X)+Sqr(Segs[Sj].Z0-Z)<0.01 then
              begin TX0:=Segs[Sj].DX; TZ0:=Segs[Sj].DZ end
              else if Sqr(Segs[Sj].X1-X)+Sqr(Segs[Sj].Z1-Z)<0.01 then
              begin TX0:=-Segs[Sj].DX; TZ0:=-Segs[Sj].DZ end
              else Continue;
              Dot:=((X-OX)*TX0+(Z-OZ)*TZ0)*Segs[Sj].LenInv/Len;
              if Dot>BestDot then begin BestDot:=Dot; AP:=Sj end;
            end;
            if AP<0 then Continue;
            Count:=Length(Approaches); SetLength(Approaches,Count+1);
            Approaches[Count].WayId:=Segs[AP].WayId;
            Approaches[Count].X:=X; Approaches[Count].Z:=Z;
            A:=ByWay[Segs[AP].WayId]; Q:=Length(Allowed);
            SetLength(Allowed,Q+Length(A));
            for Sj:=0 to High(A) do Allowed[Q+Sj]:=A[Sj];
          end;
          for Step:=-1 to 1 do
          begin
            if Step=0 then Continue;
            if Step<0 then begin Idx:=First-1; StopAt:=First end
            else begin Idx:=Last+1; StopAt:=Last end;
            while (Idx>=0) and (Idx<N) and
              (Abs(CumLen[Idx]-CumLen[StopAt])<=150) do
            begin
              Have:=CandidateAt(Idx,Pick);
              if not Have then Break;
              PlaceSnap(Idx,Pick);
              if DbgOn then Note[Idx]:=Note[Idx]+Format(' | connected structure w%d',[W]);
              Inc(Idx,Step);
            end;
          end;
        end;
        First:=Last+1;
      end;
    finally ByWay.Free end;
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1326);{$ENDIF}
  N := Length(Route);
  SetLength(Result, N);
  SetLength(Widths, N);
  SetLength(Centers, N);
  { Default: identity copy — points that fail any check are kept as-is,
    width 0 (off-road → rider follows the raw point). Center defaults to
    the route point too (no road → no separate centerline). }
  for I := 0 to N - 1 do
  begin
    Result[I] := Route[I];
    Widths[I] := 0.0;
    Centers[I] := Route[I];
  end;
  { Пер-точечная way снапа для потребителей высоты: нулевой массив уже
    здесь, чтобы ранние выходы оставляли корректную параллель маршруту. }
  if AWaysOut <> nil then
  begin
    AWaysOut^ := nil;
    SetLength(AWaysOut^, N);
  end;

  if (N < 2) or (Projection = nil) then
  begin
    if Log <> nil then
      Log.Write(llInfo,
        Format('RouteSnapper: nothing to do (N=%d, hasProj=%s)',
          [N, BoolToStr(Projection <> nil, 'yes', 'no')]));
    Exit;
  end;

  if Length(Segs) = 0 then
  begin
    if Log <> nil then
      Log.Write(llInfo,
        'RouteSnapper: no road segments — copy left untouched');
    Exit;
  end;
  BuildSegmentGrid(Segs, Grid);

  DbgOn := ADebugPath <> '';
  if DbgOn then
  begin
    SetLength(Note, N);
    SetLength(VoteNote, N);
  end;

  { Pre-project the route once — used both for nearest-segment search
    and for tangent estimation. }
  RouteLocal := TRouteSrc.ProjectPolyline(Route, Projection);

  { ChosenWay обнуляется самим SetLength; CumLen — накопленная длина
    маршрута (для памяти липкости и лимита длины островка). }
  SetLength(ChosenWay, N);
  SetLength(ChosenSeg, N);
  for I:=0 to N-1 do ChosenSeg[I]:=-1;
  SetLength(CumLen, N);
  CumLen[0] := 0;
  for I := 1 to N - 1 do
    CumLen[I] := CumLen[I - 1] +
      Sqrt(Sqr(RouteLocal[I].X - RouteLocal[I - 1].X) +
           Sqr(RouteLocal[I].Z - RouteLocal[I - 1].Z));

  { Пред-проход «следования»: для каждой точки — по одному кандидату на
    каждую близкую way (ближайший её сегмент), с ПОШИРЕННЫМ перп-гейтом,
    чтобы смещённая дорога всё же попала в голос, хотя поточечный снап-гейт
    её бы отбросил. Гейт — до SNAP_FOLLOW_FAR_M: дальняя полоса
    (SNAP_SEARCH_RADIUS_M..SNAP_FOLLOW_FAR_M) собирается всегда, но голос
    пускает её в ход только когда в обычной полосе не нашлось ничего
    сопровождаемого (см. WayFollowVote). Обход — 3x3 окрестность ячеек:
    одна ячейка не видит дальше раздутия AABB. }
  SetLength(PtCands, N);
  for FI := 0 to N - 1 do
  begin
    PtCands[FI] := nil;
    if not ComputeRouteTangent(RouteLocal, FI, FTX, FTZ) then Continue;
    FCells := GridCellsAround(Grid, RouteLocal[FI].X, RouteLocal[FI].Z);
    for FC := 0 to High(FCells) do
    for FM := Grid.Starts[FCells[FC]] to Grid.Starts[FCells[FC] + 1] - 1 do
    begin
      S := @Segs[Grid.Indices[FM]];
      { AABB раздут лишь на SNAP_SEARCH_RADIUS_M — ослабляем тест на
        разницу до дальнего радиуса; истинный гейт — дистанция ниже. }
      if (RouteLocal[FI].X < S^.BBoxMinX - (SNAP_FOLLOW_FAR_M - SNAP_SEARCH_RADIUS_M)) or
         (RouteLocal[FI].X > S^.BBoxMaxX + (SNAP_FOLLOW_FAR_M - SNAP_SEARCH_RADIUS_M)) or
         (RouteLocal[FI].Z < S^.BBoxMinZ - (SNAP_FOLLOW_FAR_M - SNAP_SEARCH_RADIUS_M)) or
         (RouteLocal[FI].Z > S^.BBoxMaxZ + (SNAP_FOLLOW_FAR_M - SNAP_SEARCH_RADIUS_M)) then
        Continue;
      FT := ((RouteLocal[FI].X - S^.X0) * S^.DX +
             (RouteLocal[FI].Z - S^.Z0) * S^.DZ) / S^.LenSq;
      if FT < 0 then FT := 0 else if FT > 1 then FT := 1;
      FCx := S^.X0 + FT * S^.DX;  FCz := S^.Z0 + FT * S^.DZ;
      FDx := RouteLocal[FI].X - FCx;  FDz := RouteLocal[FI].Z - FCz;
      FD  := Sqrt(FDx * FDx + FDz * FDz);
      if FD > SNAP_FOLLOW_FAR_M then Continue;
      FAng := UndirectedAngleDeg(FTX, FTZ, S^.DX, S^.DZ);
      if FAng > SNAP_PARALLEL_MAX_ANGLE_DEG then Continue;
      FSigned := (FDx * (-S^.DZ) + FDz * S^.DX) * S^.LenInv;

      { keep the closest segment per way }
      FFound := False;
      for K := 0 to High(PtCands[FI]) do
        if PtCands[FI][K].WayId = S^.WayId then
        begin
          FFound := True;
          if FD < PtCands[FI][K].Perp then
          begin
            PtCands[FI][K].Perp     := FD;
            PtCands[FI][K].Signed   := FSigned;
            PtCands[FI][K].AngleDeg := FAng;
            PtCands[FI][K].Width    := S^.Width;   { EXIT_PRIORITY }
          end;
          Break;
        end;
      if not FFound then
      begin
        SetLength(PtCands[FI], Length(PtCands[FI]) + 1);
        with PtCands[FI][High(PtCands[FI])] do
        begin
          WayId    := S^.WayId;
          Perp     := FD;
          Signed   := FSigned;
          AngleDeg := FAng;
          Width    := S^.Width;   { EXIT_PRIORITY }
        end;
      end;
    end;
  end;

  VoteIndex := specialize TDictionary<Int64, Integer>.Create;
  try
    for FI := 0 to N - 1 do
      for FM := 0 to High(PtCands[FI]) do
      begin
        if not VoteIndex.TryGetValue(PtCands[FI][FM].WayId, VI) then
        begin
          VI := VoteIndex.Count;
          VoteIndex.Add(PtCands[FI][FM].WayId, VI);
        end;
        PtCands[FI][FM].VoteIndex := VI;
      end;
    VoteWayCount := VoteIndex.Count;
  finally
    VoteIndex.Free;
  end;
  SetLength(VoteWays, VoteWayCount);
  SetLength(ActiveWays, VoteWayCount);
  for FI := 0 to N - 1 do
    for FM := 0 to High(PtCands[FI]) do
      VoteWays[PtCands[FI][FM].VoteIndex].WayId := PtCands[FI][FM].WayId;
  ActiveCount := 0;
  WindowLo := 0;
  WindowHi := -1;

  SetLength(FollowWay, N);
  SetLength(FollowFar, N);
  for FI := 0 to N - 1 do
    FollowWay[FI] := WayFollowVote(FI, FollowFar[FI]);

  FillChar(Stats, SizeOf(Stats), 0);
  Stats.Total := N;
  PrevWayId := 0;
  GapSinceSnapM := 0;

  for I := 0 to N - 1 do
  begin
    { фронтир прогресса для анимации прогрева: дёшево, раз в 64 точки }
    if (AProgress <> nil) and ((I and 63) = 0) then
      AProgress^ := I;

    PX := RouteLocal[I].X;
    PZ := RouteLocal[I].Z;

    { Память липкости: длинный участок без единого снапа — текущая way
      забывается, чтобы дорога, оставшаяся позади, не тянула к себе трек
      после оффроуд-разрыва. }
    if I > 0 then
      GapSinceSnapM := GapSinceSnapM + (CumLen[I] - CumLen[I - 1]);
    if GapSinceSnapM > SNAP_STICKY_FORGET_M then
      PrevWayId := 0;

    HasTangent := ComputeRouteTangent(RouteLocal, I, TX, TZ);
    if not HasTangent then
    begin
      if DbgOn then Note[I] := 'нет касательной (крайняя/вырожденная точка)';
      Continue;
    end;

    { Обход 3x3 окрестности ячеек, как в пре-пассе и FindWayCand: одна
      ячейка не видит дальше раздутия AABB (18 м), а поточечный гейт
      теперь SNAP_POINT_MAX_PERP_M (30 м). Сегмент может лежать в
      нескольких соседних ячейках — дубль безвреден: у копий одинаковые
      WayId и дистанция, строгие сравнения ниже их не продвигают. }
    FCells := GridCellsAround(Grid, PX, PZ);
    if Length(FCells) = 0 then
    begin
      if DbgOn then Note[I] := 'вне дорожной сетки (нет дорог поблизости)';
      Continue;
    end;

    HasBest := False;  HasSecond := False;  HasBestPrev := False;
    FillChar(Best,     SizeOf(Best),     0);
    FillChar(Second,   SizeOf(Second),   0);
    FillChar(BestPrev, SizeOf(BestPrev), 0);

    for FC := 0 to High(FCells) do
    for K := Grid.Starts[FCells[FC]] to Grid.Starts[FCells[FC] + 1] - 1 do
    begin
      SegRef := Grid.Indices[K];
      S := @Segs[SegRef];

      { AABB sanity — the grid cell can hold a segment whose AABB
        only just brushes the cell on the opposite side from PX,PZ.
        AABB раздуты лишь на SNAP_SEARCH_RADIUS_M — ослабляем тест на
        разницу до поточечного окна; истинный гейт — дистанция ниже. }
      if (PX < S^.BBoxMinX - (SNAP_POINT_MAX_PERP_M - SNAP_SEARCH_RADIUS_M)) or
         (PX > S^.BBoxMaxX + (SNAP_POINT_MAX_PERP_M - SNAP_SEARCH_RADIUS_M)) or
         (PZ < S^.BBoxMinZ - (SNAP_POINT_MAX_PERP_M - SNAP_SEARCH_RADIUS_M)) or
         (PZ > S^.BBoxMaxZ + (SNAP_POINT_MAX_PERP_M - SNAP_SEARCH_RADIUS_M)) then
        Continue;

      { Projection onto segment line, clamp t∈[0,1] to the actual span. }
      TRaw := ((PX - S^.X0) * S^.DX + (PZ - S^.Z0) * S^.DZ) / S^.LenSq;
      T := TRaw;
      if T < 0 then T := 0
      else if T > 1 then T := 1;
      Cx := S^.X0 + T * S^.DX;
      Cz := S^.Z0 + T * S^.DZ;
      Dx := PX - Cx;
      Dz := PZ - Cz;
      D  := Sqrt(Dx * Dx + Dz * Dz);

      { Eligibility filter — distance. Реальное окно поиска расширено до
        SNAP_POINT_MAX_PERP_M, но ТОЛЬКО для истинного перпендикуляра
        (фут внутри сегмента, TRaw∈[0,1]): райдер на обочине длинной
        прямой в 12-25 м от осевой теперь ловится. Для клампованного
        фута (точка за торцом сегмента) остаётся прежний узкий гейт —
        иначе 30-метровое окно магнитило бы к торцу дороги хвост трека,
        честно уехавший с неё (оффроуд-разрыв между дорогами). }
      if D > S^.HalfW + SNAP_PERP_BEYOND_HALFW_M then
        if (TRaw < 0) or (TRaw > 1) or (D > SNAP_POINT_MAX_PERP_M) then
          Continue;

      { Eligibility filter — parallel. }
      Cand.AngleDeg := UndirectedAngleDeg(TX, TZ, S^.DX, S^.DZ);
      if (Cand.AngleDeg > SNAP_PARALLEL_MAX_ANGLE_DEG) and
         not CloseIncomingCorner(I,SegRef,D) then Continue;

      { Signed perpendicular — use the unit left-perp of segment
        direction. N_perp = (-DZ, DX) * LenInv.
        SignedPerp = (Dx, Dz) · N_perp. Sign selects which side of the
        centerline the original point sits on. }
      Cand.SignedPerp := (Dx * (-S^.DZ) + Dz * S^.DX) * S^.LenInv;

      Cand.SegIdx   := SegRef;
      Cand.PerpDist := D;
      Cand.FootX    := Cx;
      Cand.FootZ    := Cz;
      Cand.WayId    := S^.WayId;
      Cand.IsBridge := S^.IsBridge;   { BRIDGE_SNAP }
      Cand.Width    := S^.Width;      { EXIT_PRIORITY / ROAD_OVER_PATH }

      { Rank: closer centerline wins, but a bridge/tunnel deck beats a
        ground road stacked under the span within SNAP_BRIDGE_PREFER_M
        (BRIDGE_SNAP), and a vehicle roadway beats a footway/sidewalk
        within SNAP_ROAD_OVER_PATH_M (EXIT_PRIORITY). Maintain best +
        second-best from DIFFERENT ways. }
      if (not HasBest) or PointCandBetter(Cand, Best) then
      begin
        if HasBest and (Best.WayId <> Cand.WayId) then
        begin
          Second    := Best;
          HasSecond := True;
        end;
        Best    := Cand;
        HasBest := True;
      end
      else if (Cand.WayId <> Best.WayId) and
              ((not HasSecond) or PointCandBetter(Cand, Second)) then
      begin
        Second    := Cand;
        HasSecond := True;
      end;

      { Лучший кандидат ТЕКУЩЕЙ way — сырьё для липкости ниже. }
      if (PrevWayId <> 0) and (Cand.WayId = PrevWayId) and
         ((not HasBestPrev) or CandBetterThan(Cand, BestPrev)) then
      begin
        BestPrev    := Cand;
        HasBestPrev := True;
      end;
    end;

    { Притягивание по «следованию»: оконный голос решил, что этот участок
      идёт по way FW. Снапим на FW, даже если поточечный гейт вообще не
      нашёл кандидата (геометрически верная, но СМЕЩЁННАЯ дорога) или
      предпочёл более близкую пересекающую/параллельную дорогу. Голос
      решителен по построению (порог SNAP_FOLLOW_MARGIN), поэтому следование
      само по себе разрешает неоднозначность — как продолжение по той же way. }
    FW := FollowWay[I];
    if (FW <> 0) and ((not HasBest) or (Best.WayId <> FW)) then
    begin
      { Дальний голос (фаза 2 — в обычной полосе не было ничего) имеет
        право тянуть с SNAP_FOLLOW_FAR_M; обычный — как прежде. }
      if FollowFar[I] then
        FMaxD := SNAP_FOLLOW_FAR_M
      else
        FMaxD := SNAP_FOLLOW_REJOIN_MAX_M;
      if FindWayCand(I, FW, FMaxD, RC) then
      begin
        Best    := RC;
        HasBest := True;
        Inc(Stats.Followed);
        if DbgOn then
        begin
          if FollowFar[I] then
            Note[I] := Format('голос(даль)→w%d d=%.1fм', [FW, RC.PerpDist])
          else
            Note[I] := Format('голос→w%d d=%.1fм', [FW, RC.PerpDist]);
        end;
      end
      else if DbgOn then
        Note[I] := Format('голос w%d: сегмент не найден в %.0fм', [FW, FMaxD]);
    end;

    { EXIT HOLD (priority path = deck/exit ramp): no candidate, or only a
      much worse one — rejoin PrevWay while still in the hold window.
      Rejoin radius uses FAR band so GPS under the span still sees the
      ramp. Prefer PrevWay even when a narrow under/side path is closer
      (SNAP_ROAD_OVER_PATH_M if Prev is a roadway). }
    if (PrevWayId <> 0) and (GapSinceSnapM < SNAP_EXIT_HOLD_M) then
    begin
      if (not HasBest) and FindWayCand(I, PrevWayId, SNAP_FOLLOW_FAR_M, RC) then
      begin
        Best := RC;
        HasBest := True;
        if DbgOn then
          Note[I] := Format('съезд-приоритет: держим w%d d=%.1fм (gap=%.0fм)',
            [PrevWayId, RC.PerpDist, GapSinceSnapM]);
        Inc(Stats.Sticky);
      end
      else if HasBest and (Best.WayId <> PrevWayId)
              and FindWayCand(I, PrevWayId, SNAP_FOLLOW_FAR_M, RC)
              and not ConnectedRawTurn(I,Best,RC) then
      begin
        { Margin: bridge prefer, or full road-over-path when Prev is the
          vehicle exit and Best is a footway/sidewalk. }
        if CandIsRoadway(RC) and (not CandIsRoadway(Best)) then
        begin
          if RC.PerpDist <= Best.PerpDist + SNAP_ROAD_OVER_PATH_M then
          begin
            if DbgOn then
              Note[I] := Format(
                'съезд-приоритет: дорога w%d d=%.1fм > тротуар w%d d=%.1fм',
                [PrevWayId, RC.PerpDist, Best.WayId, Best.PerpDist]);
            Best := RC;
            Inc(Stats.Sticky);
          end;
        end
        else if RC.PerpDist <= Best.PerpDist + SNAP_BRIDGE_PREFER_M then
        begin
          if DbgOn then
            Note[I] := Format(
              'съезд-приоритет: w%d d=%.1fм > низ w%d d=%.1fм',
              [PrevWayId, RC.PerpDist, Best.WayId, Best.PerpDist]);
          Best := RC;
          Inc(Stats.Sticky);
        end;
      end;
    end;

    if not HasBest then
    begin
      { SNAP_GAP_FILL: point gates (esp. parallel angle) left a hole over
        a real road — e.g. secondary stub after bridge #19 Турья. }
      if FindNearestRoadCand(I, SNAP_GAP_FILL_MAX_M, RC) then
      begin
        Best := RC;
        HasBest := True;
        if DbgOn then
          Note[I] := Format(
            'gap-fill: w%d d=%.1fм w=%.1f (без угла)',
            [RC.WayId, RC.PerpDist, RC.Width]);
      end
      else
      begin
        if DbgOn and (Note[I] = '') then
          Note[I] := 'нет кандидатов (поточечные гейты: перпендикуляр/угол)';
        Continue;
      end;
    end;

    if (FW <> 0) and (Best.WayId = FW) then
    begin
      { Голос решителен — ставим снап на выбранную way, минуя липкость и
        гейт неоднозначности. }
      if DbgOn and (Note[I] = '') then
        Note[I] := Format('голос+точечный w%d d=%.1fм', [Best.WayId, Best.PerpDist]);
      PlaceSnap(I, Best);
      PrevWayId     := Best.WayId;
      GapSinceSnapM := 0;
      Continue;
    end;

    { Липкость: пока маршрут идёт по way PrevWayId, чужая way перехватывает
      точку только с решающим преимуществом по перпендикуляру. На мосту
      (BRIDGE_SNAP) порог выше — иначе нижняя дорога срывает точки с
      настила. Без IsBridge в кэше всё равно держим PrevWay сильнее.
      EXIT_PRIORITY: НЕ удерживаем тротуар/path, если Best — проезжая
      часть в пределах SNAP_ROAD_OVER_PATH_M (иначе sticky запирает
      parallel sidewalk на всём подъезде/съезде). }
    StickyAdv := SNAP_STICKY_ADVANTAGE_M;
    if HasBestPrev and BestPrev.IsBridge and (not Best.IsBridge) then
      StickyAdv := SNAP_BRIDGE_PREFER_M
    else if HasBestPrev and CandIsRoadway(BestPrev) and (not CandIsRoadway(Best)) then
      StickyAdv := SNAP_ROAD_OVER_PATH_M
    else if HasBestPrev and (Best.WayId <> PrevWayId)
            and (BestPrev.PerpDist <= SNAP_FOLLOW_REJOIN_MAX_M) then
      StickyAdv := SNAP_STICKY_ADVANTAGE_M;
    if (not HasBestPrev) and (PrevWayId <> 0)
       and (Best.WayId <> PrevWayId)
       and (GapSinceSnapM < SNAP_EXIT_HOLD_M)
       and FindWayCand(I, PrevWayId, SNAP_FOLLOW_REJOIN_MAX_M, RC) then
    begin
      BestPrev := RC;
      HasBestPrev := True;
    end;
    if HasBestPrev and (Best.WayId <> PrevWayId) and
       not ConnectedRawTurn(I,Best,BestPrev) then
    begin
      { Allow vehicle road to steal from sidewalk even if sticky would hold. }
      if CandIsRoadway(Best) and (not CandIsRoadway(BestPrev))
         and (Best.PerpDist <= BestPrev.PerpDist + SNAP_ROAD_OVER_PATH_M) then
      begin
        if DbgOn then
          Note[I] := Format(
            'EXIT_PRIORITY: дорога w%d d=%.1fм срывает тротуар w%d d=%.1fм',
            [Best.WayId, Best.PerpDist, PrevWayId, BestPrev.PerpDist]);
        { keep Best — do not sticky-hold footway }
      end
      else if BestPrev.PerpDist <= Best.PerpDist + StickyAdv then
      begin
        if DbgOn then
        begin
          if BestPrev.IsBridge then
            Note[I] := Format(
              'липкость(мост): держим w%d d=%.1fм (чужая w%d d=%.1fм, порог +%.1fм)',
              [PrevWayId, BestPrev.PerpDist, Best.WayId, Best.PerpDist, StickyAdv])
          else if CandIsRoadway(BestPrev) then
            Note[I] := Format(
              'липкость(дорога/съезд): держим w%d d=%.1fм (чужая w%d d=%.1fм +%.1fм)',
              [PrevWayId, BestPrev.PerpDist, Best.WayId, Best.PerpDist, StickyAdv])
          else
            Note[I] := Format(
              'липкость: держим w%d d=%.1fм (чужая w%d d=%.1fм не решает +%.1fм)',
              [PrevWayId, BestPrev.PerpDist, Best.WayId, Best.PerpDist, StickyAdv]);
        end;
        Best := BestPrev;
        Inc(Stats.Sticky);
      end;
    end;

    { Ambiguity guard — two different ways too close → undecidable. But
      CONTINUATION along the way currently being followed is itself the
      disambiguation — for it the guard does not block.
      BRIDGE_SNAP: bridge vs ground under span is NOT ambiguous — take bridge.
      EXIT_PRIORITY: roadway vs footway is NOT ambiguous — take roadway. }
    if (Best.WayId <> PrevWayId) and HasSecond and
       (Abs(Second.PerpDist - Best.PerpDist) < SNAP_AMBIG_MIN_GAP_M) then
    begin
      if Best.IsBridge xor Second.IsBridge then
      begin
        if Second.IsBridge and (not Best.IsBridge) then
          Best := Second;
        if DbgOn then
          Note[I] := Format(
            'мост>низ: w%d d=%.1fм (отклонили ground/deck двойник w%d)',
            [Best.WayId, Best.PerpDist,
             Second.WayId]);
      end
      else if CandIsRoadway(Best) xor CandIsRoadway(Second) then
      begin
        if CandIsRoadway(Second) and (not CandIsRoadway(Best)) then
          Best := Second;
        if DbgOn then
          Note[I] := Format(
            'дорога>тротуар: w%d d=%.1fм (отклонили path w%d)',
            [Best.WayId, Best.PerpDist, Second.WayId]);
      end
      else if CandIsRoadway(Best) then
      begin
        { SNAP_GAP_FILL: two vehicle roads too close — still take the
          closer one. Leaving way=0 over a secondary (Турья S-exit) is
          worse than a 1 m lateral pick between two roadways. }
        if DbgOn then
          Note[I] := Format(
            'дорога≈дорога: берём ближнюю w%d d=%.1fм (вторая w%d d=%.1fм)',
            [Best.WayId, Best.PerpDist, Second.WayId, Second.PerpDist]);
      end
      else
      begin
        if DbgOn then
          Note[I] := Format(
            'неоднозначно: w%d %.1fм против w%d %.1fм (зазор < %.1fм)',
            [Best.WayId, Best.PerpDist, Second.WayId, Second.PerpDist,
             SNAP_AMBIG_MIN_GAP_M]);
        Inc(Stats.Ambiguous);
        Continue;
      end;
    end;

    if DbgOn and (Note[I] = '') then
      Note[I] := Format('точечный w%d d=%.1fм', [Best.WayId, Best.PerpDist]);
    PlaceSnap(I, Best);
    PrevWayId     := Best.WayId;
    GapSinceSnapM := 0;
  end;

  { Пост-проход «островков»: короткий (<= SNAP_ISLAND_MAX_LEN_M вдоль
    маршрута) бег точек, снятых на ДРУГУЮ way или не снятых вовсе, зажатый
    с обеих сторон точками одной и той же way A, перетягивается на A: путь
    шёл по этой дороге и дальше продолжается по ней, а перескок — артефакт
    локального «ближайшего сегмента» у перекрёстка или параллельной дороги.
    LastWayIdx помнит последний индекс каждой way; запись валидируется по
    ChosenWay (точку мог переписать предыдущий остров). }
  ProtectRecordedBranches;
  LastWayIdx := specialize TDictionary<Int64, Integer>.Create;
  try
    for I := 0 to N - 1 do
    begin
      if ChosenWay[I] = 0 then Continue;
      if LastWayIdx.TryGetValue(ChosenWay[I], IslandLeft) and
         (ChosenWay[IslandLeft] = ChosenWay[I]) and
         (IslandLeft < I - 1) and
         (ProtectedIslandPrefix[I]=ProtectedIslandPrefix[IslandLeft+1]) and
         (CumLen[I] - CumLen[IslandLeft] <= SNAP_ISLAND_MAX_LEN_M) then
        for J := IslandLeft + 1 to I - 1 do
          if (ChosenWay[J] <> ChosenWay[I]) and
             FindWayCand(J, ChosenWay[I], SNAP_ISLAND_REJOIN_MAX_M, RC) then
          begin
            if DbgOn then
              Note[J] := Note[J] + Format(' | остров→w%d d=%.1fм',
                [ChosenWay[I], RC.PerpDist]);
            PlaceSnap(J, RC);
            Inc(Stats.Rejoined);
          end;
      LastWayIdx.AddOrSetValue(ChosenWay[I], I);
    end;
  finally
    LastWayIdx.Free;
  end;

  RepairStructureContinuity;

  if AProgress <> nil then AProgress^ := N;   { обработан весь маршрут }

  { Финальная раскладка счётчиков — по фактическому состоянию: rejoin
    переписывает точки, инкрементальный учёт по веткам расходился бы. }
  Stats.Unchanged := 0;
  Stats.Edge      := 0;
  Stats.Center    := 0;
  for I := 0 to N - 1 do
    if ChosenWay[I] = 0 then
      Inc(Stats.Unchanged)
    else if Widths[I] > SNAP_WIDE_THRESHOLD_M then
      Inc(Stats.Edge)
    else
      Inc(Stats.Center);


  { ── Отдельный лог фита: дороги в радиусе, маршрут, решения. Пишется
    только при ADebugPath <> ''; любая ошибка записи глотается. ── }
  if DbgOn then
  begin
    DbgL := TStringList.Create;
    try
      DbgL.Add('=== FIT SNAP DEBUG === ' +
        FormatDateTime('yyyy-mm-dd hh:nn:ss', Now));
      DbgL.Add(Format('точек=%d  сегментов=%d  сетка=%dx%d ячейка=%.1fм',
        [N, Length(Segs), Grid.Cols, Grid.Rows, Grid.CellSize]));
      DbgL.Add(Format(
        'гейты: точечный<=%.0fм даль=%.0fм угол<=%.0f° липкость=%.1fм ' +
        'зазор-неодн.=%.1fм остров<=%.0fм окно голоса=%.0fм отрыв=%.2f ' +
        'дорога>тротуар=%.0fм съезд-hold=%.0fм forget=%.0fм',
        [SNAP_POINT_MAX_PERP_M, SNAP_FOLLOW_FAR_M, SNAP_PARALLEL_MAX_ANGLE_DEG,
         SNAP_STICKY_ADVANTAGE_M, SNAP_AMBIG_MIN_GAP_M, SNAP_ISLAND_MAX_LEN_M,
         SNAP_FOLLOW_WINDOW_M, SNAP_FOLLOW_MARGIN,
         SNAP_ROAD_OVER_PATH_M, SNAP_EXIT_HOLD_M, SNAP_STICKY_FORGET_M]));
      DbgL.Add('');

      { дороги: ПОЛНАЯ геометрия каждой way — все узлы осевой в lat/lon, а
        не только старт. Так внешний анализ может честно померить
        перпендикуляр трека к дороге (обочина!), а не к одной точке.
        Сегменты одной way идут подряд связной цепочкой
        (X1,Z1 сегмента = X0,Z0 следующего), поэтому осевая = старт
        первого узла + конец каждого сегмента. Формат строки:
          w<id> ширина=<w>м узлов=<n>: lat,lon lat,lon ... }
      DbgL.Add('--- ДОРОГИ (полная осевая каждой way) ---');
      WSegs := specialize TDictionary<Int64, TCellIndexArray>.Create;
      try
        { сгруппировать индексы сегментов по way, сохраняя порядок появления
          (он отражает связную цепочку из BuildSegmentList/тайл-кэша) }
        for I := 0 to High(Segs) do
        begin
          if WSegs.TryGetValue(Segs[I].WayId, IdxArr) then
          begin
            SetLength(IdxArr, Length(IdxArr) + 1);
            IdxArr[High(IdxArr)] := I;
            WSegs.AddOrSetValue(Segs[I].WayId, IdxArr);
          end
          else
          begin
            SetLength(IdxArr, 1);
            IdxArr[0] := I;
            WSegs.Add(Segs[I].WayId, IdxArr);
          end;
        end;
        DbgL.Add(Format('всего way: %d', [WSegs.Count]));
        for WPair in WSegs do
        begin
          IdxArr := WPair.Value;
          if Length(IdxArr) = 0 then Continue;
          { осевая: старт первого сегмента, затем конец каждого сегмента }
          DP := Projection.Unproject(Segs[IdxArr[0]].X0, Segs[IdxArr[0]].Z0);
          DLine := Format('%.6f,%.6f', [DP.Lat, DP.Lon]);
          DNodes := 1;
          for J := 0 to High(IdxArr) do
          begin
            DP := Projection.Unproject(Segs[IdxArr[J]].X1, Segs[IdxArr[J]].Z1);
            DLine := DLine + Format(' %.6f,%.6f', [DP.Lat, DP.Lon]);
            Inc(DNodes);
          end;
          DbgL.Add(Format('w%d ширина=%.1fм узлов=%d: %s',
            [WPair.Key, Segs[IdxArr[0]].Width, DNodes, DLine]));
        end;
      finally
        WSegs.Free;
      end;
      DbgL.Add('');

      { маршрут из фита }
      DbgL.Add('--- МАРШРУТ FIT ---');
      for I := 0 to N - 1 do
        DbgL.Add(Format('%d: %.6f %.6f', [I, Route[I].Lat, Route[I].Lon]));
      DbgL.Add('');

      { решения: соседи + голос + итог }
      DbgL.Add('--- РЕШЕНИЯ (way рядом [перп, м] | голос | итог) ---');
      for I := 0 to N - 1 do
      begin
        DLine := '';
        for J := 0 to High(PtCands[I]) do
        begin
          if DLine <> '' then DLine := DLine + ' ';
          DLine := DLine + Format('w%d:%.1f',
            [PtCands[I][J].WayId, PtCands[I][J].Perp]);
        end;
        if DLine = '' then DLine := 'нет way в ' +
          Format('%.0f', [SNAP_FOLLOW_FAR_M]) + 'м';
        if VoteNote[I] <> '' then
          DLine := DLine + ' | голос: ' + VoteNote[I];
        if Note[I] <> '' then
          DLine := DLine + ' | ' + Note[I]
        else if ChosenWay[I] = 0 then
          DLine := DLine + ' | НЕ ПРИТЯНУТА'
        else
          DLine := DLine + Format(' | w%d', [ChosenWay[I]]);
        { финальное состояние (остров мог переписать) }
        if ChosenWay[I] <> 0 then
          DLine := DLine + Format(' => w%d ширина=%.1fм', [ChosenWay[I], Widths[I]])
        else
          DLine := DLine + ' => не притянута';
        DbgL.Add(Format('%d: ', [I]) + DLine);
      end;
      DbgL.Add('');
      DbgL.Add(Format(
        '--- ИТОГ --- снято: центр=%d кромка=%d | липкость=%d голос=%d ' +
        'остров=%d | неоднозначно=%d не притянуто=%d из %d',
        [Stats.Center, Stats.Edge, Stats.Sticky, Stats.Followed,
         Stats.Rejoined, Stats.Ambiguous, Stats.Unchanged, Stats.Total]));
      try
        DbgL.SaveToFile(ADebugPath);
        if Log <> nil then
          Log.Write(llInfo, Format('RouteSnapper: подробный лог фита → %s (%d строк)',
            [ADebugPath, DbgL.Count]));
      except
        on E: Exception do
          if Log <> nil then
            Log.Write(llInfo, 'RouteSnapper: не смог записать лог фита: ' + E.Message);
      end;
    finally
      DbgL.Free;
    end;
  end;

  { финальное состояние ChosenWay (остров/rejoin уже переписали) — наружу }
  if (AWaysOut <> nil) and (N > 0) then
    Move(ChosenWay[0], AWaysOut^[0], N * SizeOf(Int64));

  if Log <> nil then
    Log.Write(llInfo,
      Format('RouteSnapper: %d pts → %d edge, %d center, %d sticky-held, ' +
             '%d followed, %d re-joined, %d ambiguous, %d unchanged ' +
             '(segments=%d, grid=%d×%d cell=%.1fm)',
        [Stats.Total, Stats.Edge, Stats.Center, Stats.Sticky, Stats.Followed,
         Stats.Rejoined, Stats.Ambiguous, Stats.Unchanged, Length(Segs),
         Grid.Cols, Grid.Rows, Grid.CellSize]));
end;

end.
