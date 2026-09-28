unit Osm3dGeoMath;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$codepage UTF8}

interface

uses
  Classes,
  SysUtils,
  Math,
  CastleVectors,
  Osm3dOsmTagUtils
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
;

type
  { WGS-84 geographic point. Lat [-90..90], Lon [-180..180], degrees. }
  TLatLon = record
    Lat: Double;
    Lon: Double;

    class function Make(ALat, ALon: Double): TLatLon; static;

    { Great-circle distance in metres (Haversine). }
    function DistanceTo(const Other: TLatLon): Double;

    { "lat,lon" with 6 decimal places (~11 cm @ equator), locale-independent. }
    function ToString: string;
  end;

  { Rectangle in WGS-84. Convention: Min* < Max*.
    Anti-meridian crossing is not supported. }
  TLatLonBox = record
    MinLat: Double;
    MinLon: Double;
    MaxLat: Double;
    MaxLon: Double;

    class function Make(AMinLat, AMinLon, AMaxLat, AMaxLon: Double): TLatLonBox; static;

    { Sentinel value: IsEmpty returns True; first Include() correctly seeds. }
    class function Empty: TLatLonBox; static;

    function IsEmpty: Boolean;
    function Center: TLatLon;
    function Width:  Double;        { longitude extent, degrees }
    function Height: Double;        { latitude extent, degrees }

    { Expand by N metres in all directions; longitude scales by cos(centre lat). }
    function ExpandMeters(Meters: Double): TLatLonBox;

    { Both return a new value; Self is not modified. }
    function Include(const P: TLatLon): TLatLonBox;
    function Union(const Other: TLatLonBox): TLatLonBox;

    function ToString: string;
  end;

  { AABB in local metres. TVector3 from CastleVectors for compat with TCastleScene. }
  TLocalBox = record
    MinPt: TVector3;
    MaxPt: TVector3;

    class function Make(const AMin, AMax: TVector3): TLocalBox; static;
    class function Empty: TLocalBox; static;

    function IsEmpty: Boolean;
    function Center: TVector3;
    function Size:   TVector3;     { MaxPt - MinPt }
    function Include(const P: TVector3): TLocalBox;
    function Union(const Other: TLocalBox): TLocalBox;
  end;

const
  { Канонический радиус Земли движка (средний, сферическая модель) — все
    метрические пересчёты lat/lon <-> метры идут через него.
    СОЗНАТЕЛЬНЫЕ исключения (НЕ сводить сюда — значения другие по стандарту):
      • Osm3dSlippyMap.EARTH_CIRCUM_M = 40075016.686 = 2π·6378137 — экваториальная
        окружность WGS-84, это СТАНДАРТ веб-меркатора OSM-тайлов; замена на
        2π·EARTH_RADIUS_M сдвинет тайловую сетку (~0.11 %);
      • Osm3dGeoTileGrid.WGS84_A = 6378137 — большая полуось эллипсоида,
        используется только в legacy UTMForward/UTMInverse. }
  EARTH_RADIUS_M = 6371000.0;
  DEG_TO_RAD     = Pi / 180.0;
  RAD_TO_DEG     = 180.0 / Pi;

{ Progress callback used by long-running builders (called every ~5 s). }
type
  TLogProc = procedure(const Msg: string) of object;

const
  { Base directory for landuse + road surface textures. }
  SURFACES_TEX_DIR = 'data/Osm3d/resources/textures/surfaces/';

{ Z-lift stack above terrain to avoid z-fighting between overlay layers.
  Order: terrain -> landuse -> water -> roads -> railway -> intersections.
  BUILDING_FOUNDATION_LIFT_M = plinth above max terrain; LABEL_* = 3D-label billboard offsets. }
  LANDUSE_LIFT_M             = 0.02;
  { Water uses its own translucent material and bypasses the ground-composite VS,
    so u_ground_z_bias does not apply to it. }
  WATER_LIFT_M               = 0.0;
  ROAD_LIFT_M                = 0.08;
  RAILWAY_LIFT_M             = 0.1;
  INTERSECTION_LIFT_M        = 0.01;
  BUILDING_FOUNDATION_LIFT_M = 0.05;
  LABEL_LIFT_M               = 5.0;
  LABEL_BUILDING_LIFT_M      = 8.0;

  { Far-bias Y nudge the ground-composite VS applies; mirrored here so non-composite meshes
    (water etc.) can match it on the CPU via TMesh.LiftForFarBias. MUST match GROUND_COMPOSITE_VS. }
  FAR_BIAS_START_M           = 100.0;
  FAR_BIAS_SLOPE             = 0.0003;

type
  { XZ point in metre coordinate space. }
  TScatterPoint = record
    X, Z: Double;
  end;
  TScatterPointArray = array of TScatterPoint;

  { Polygon ring. Closure (first == last) is not required. }
  TPolygonRing = array of TScatterPoint;

  { Outer ring + zero or more inner rings.
    For multiple disjoint outer rings, use separate records. }
  TPolygonMultipolygon = record
    Outer:  TPolygonRing;
    Inners: array of TPolygonRing;
  end;

{ Normalise winding to CCW in the XZ plane (projection: East→-X, North→+Z).
  If shoelace signed area > 0 (CW), reverses Pts in-place.
  The Heights overload reverses a parallel heights array in lockstep. }
procedure EnsureCCWXZ(var Pts: array of TVector3); overload;
procedure EnsureCCWXZ(var Pts: array of TVector3;
  var Heights: array of Single); overload;

{ Shoelace signed area in XZ. Positive = CCW from above (+Y). 0 when N < 3. }
function PolygonSignedAreaXZ(const F: array of TVector3): Single;

{ Ray-casting point-in-polygon, even-odd rule. Half-open edges handle
  vertices exactly on the horizontal ray correctly. }
function PointInPolygonXZ(const P: TVector3;
  const Polygon: array of TVector3): Boolean;
function PointInRingXZ(PX, PZ: Double; const Ring: TPolygonRing): Boolean;

{ ═══ ПОЛОСА МАСШТАБА МИРА ═══════════════════════════════════════════════
  Возвращает широту, которой следует масштабировать ДОЛГОТУ (cos) во всём
  мире сессии, попавшей на широту ALatDeg. Чистая функция географии — ни
  маршрут, ни origin сессии на результат не влияют сверх самой широты.

  Зачем: равнопромежуточная проекция сжимает долготу одним cos на весь мир
  (иначе рвётся int-решётка и сварка блоков). Если брать cos от широты
  origin, две программы с разными origin (Студия — FRoute[0], игра —
  центроид) получают РАЗНУЮ метрику и один и тот же тайл из общего кэша
  раскладывают со сдвигом. Полоса убирает это: близкие широты дают
  побитно одинаковый масштаб.

  Правило: квантуется НЕ широта, а ln(cos(lat)) с шагом EPS. Тогда
  относительная ошибка метрики = |Δ ln cos| <= EPS/2 — ОДИНАКОВЫЙ потолок
  0.5% на всей планете. Полосы сами подстраиваются: у экватора cos плоский
  → полоса ~900 км, на 60° → 37 км, на 78° → 13 км. Ровно там, где cos
  меняется быстро, полосы у́же.

  ВНИМАНИЕ на края: область шире полосы (у вас 39 км против 37 на 60°)
  накрывает две полосы — заезды с разных краёв получат разную метрику и
  СВОЙ комплект тайлов (щелей не будет: внутри сессии метрика одна).
  Лечится ручным TStudioSettings.WorldScaleLatDeg <> 0 — прибить местность. }
function WorldScaleLatBand(ALatDeg: Double): Double;

type
  TLocalProjection = class
  private
    FOrigin:       TLatLon;
    FCosOriginLat: Double;     { cached cos(lat) for Project() }
    { Per-degree metric factors and reciprocals, set once in Create so Project/Unproject
      use a multiply instead of recomputing the product (or dividing) on every call. }
    FMpdLat, FMpdLon:       Double;   { metres per degree lat / lon }
    FInvMpdLat, FInvMpdLon: Double;   { 1 / the above }
  public
    { AScaleLatDeg overrides the latitude whose cos sets the metres-per-degree-LONGITUDE
      scale; out of [-90,90] or 0 = use AOrigin.Lat. Passing the SESSION latitude lets
      block-LOCAL geometry keep the render frame's east/west scale so tiles weld. Translation
      still comes from AOrigin. }
    constructor Create(const AOrigin: TLatLon; AScaleLatDeg: Double = 0.0);

    { lat/lon degrees + elevation metres → local point. Elevation goes to Y. }
    function Project(const P: TLatLon; Elevation: Double = 0): TVector3; overload;

    { Same, no elevation (Y = 0). }
    function Project(Lat, Lon: Double): TVector3; overload;

    { Local XZ → lat/lon. Y is ignored. }
    function Unproject(const Local: TVector3): TLatLon; overload;
    function Unproject(LocalX, LocalZ: Single): TLatLon; overload; inline;

    property Origin: TLatLon read FOrigin;

    function MetersPerDegreeLat: Double;
    function MetersPerDegreeLon: Double;
  end;

type
  TTileXY = record
    X:    Integer;
    Y:    Integer;
    Zoom: Integer;

    class function Make(AX, AY, AZoom: Integer): TTileXY; static;
    function ToString: string;
  end;
  TTileXYArray = array of TTileXY;

  TTileMath = class
  public
    class function LatLonToTile(const P: TLatLon; Zoom: Integer): TTileXY;

    { Bbox of the tile in WGS-84 (Min/Max are S/N and W/E regardless of
      tile Y convention). }
    class function TileToLatLonBox(const T: TTileXY): TLatLonBox;

    { All tiles at Zoom intersecting Box. Enumerated row-by-row: top row
      first (smallest Y), left-to-right (increasing X). }
    class function TilesCoveringBox(const Box: TLatLonBox; Zoom: Integer): TTileXYArray;

    { Substitute {z}/{x}/{y} in a tile-server URL template. }
    class function FormatTileUrl(const Template: string; const T: TTileXY): string;
  end;

const
  { Web Mercator latitude limit (asinh(tan(lat)) = ±π). }
  WEB_MERCATOR_MAX_LAT = 85.05112878;

type
  { Canonical 2D point in the local (X, Z) ground plane, Double precision.
    Replaces the former TVec2 / TOMBBPoint duplicates. }
  TXZ = record
    X, Z: Double;
  end;
  TXZArray = array of TXZ;

function XZ(X, Z: Double): TXZ; inline;
{ Signed area of triangle (A,B,C); >0 for CCW. Doubles as 2D cross. }
function XZCross(const A, B, C: TXZ): Double; inline;
function XZPointInTriangle(const P, A, B, C: TXZ): Boolean; inline;

{ Перпендикуляр в вершине осевой i: нормированное среднее перпендикуляров
  (до двух) смежных сегментов. БЕЗ миттер-масштаба — смещение остаётся ровно
  |Offset| вдоль этого единичного вектора, поэтому лента чуть сужается на
  изломе, но никогда не «перелетает» и не самопересекается. Знак (Dz,-Dx) —
  ПРАВАЯ сторона (конвенция Osm3dGeomRoadJoints). }
procedure PerpAt(const C: TXZArray; i: Integer; out PX, PZ: Double);

{ Одна смещённая ломаная: каждая вершина сдвинута на |Offset| вдоль своего
  перпендикуляра (см. PerpAt): Offset > 0 — правая сторона, < 0 — левая. }
procedure OffsetPolyline(const C: TXZArray; Offset: Double; out Pts: TXZArray);

{ Мировая координата → пиксель top-down маски (shadow/coverage-растеризаторы):
  общая формула бывших вложенных дублей PixX/PixY. Res — размер маски по оси. }
function MaskPixCoord(const V, Origin, Size: Single; Res: Integer): Single; inline;

type
  { Обратный вызов WalkGridCells; Ctx — пользовательский контекст как есть. }
  TGridCellVisitProc = procedure(AX, AZ: Integer; Ctx: Pointer);

{ Amanatides–Woo обход ячеек целочисленной сетки (Floor-координаты) вдоль
  отрезка (X0,Z0)->(X1,Z1): Visit вызывается по одному разу для каждой
  ячейки, включая стартовую и конечную, в порядке следования луча; при
  равенстве tMax сначала шаг по X. Единая каноническая форма бывших дублей
  (Osm3dGeomTerrain.RasterizeLineCells ↔ Osm3dGeomVegetation.AddLineToRowBounds). }
procedure WalkGridCells(const X0, Z0, X1, Z1: Double;
  Visit: TGridCellVisitProc; Ctx: Pointer);

implementation

function XZ(X, Z: Double): TXZ; inline;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1406);{$ENDIF}
  Result.X := X;
  Result.Z := Z;
end;

function XZCross(const A, B, C: TXZ): Double; inline;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1407);{$ENDIF}
  Result := (A.X - C.X) * (B.Z - C.Z) - (B.X - C.X) * (A.Z - C.Z);
end;

function XZPointInTriangle(const P, A, B, C: TXZ): Boolean; inline;
var
  D1, D2, D3: Double;
  HasNeg, HasPos: Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1408);{$ENDIF}
  D1 := XZCross(P, A, B);
  D2 := XZCross(P, B, C);
  D3 := XZCross(P, C, A);
  HasNeg := (D1 < 0) or (D2 < 0) or (D3 < 0);
  HasPos := (D1 > 0) or (D2 > 0) or (D3 > 0);
  Result := not (HasNeg and HasPos);
end;

procedure PerpAt(const C: TXZArray; i: Integer; out PX, PZ: Double);
var
  n: Integer;
  dx, dz, l: Double;
begin
  PX := 0.0; PZ := 0.0;
  n := High(C);
  if n < 1 then Exit;
  if i < n then                 { сегмент i -> i+1 }
  begin
    dx := C[i+1].X - C[i].X; dz := C[i+1].Z - C[i].Z;
    l := Sqrt(dx*dx + dz*dz);
    if l > 1e-9 then begin PX := PX + dz/l; PZ := PZ - dx/l; end;
  end;
  if i > 0 then                 { сегмент i-1 -> i }
  begin
    dx := C[i].X - C[i-1].X; dz := C[i].Z - C[i-1].Z;
    l := Sqrt(dx*dx + dz*dz);
    if l > 1e-9 then begin PX := PX + dz/l; PZ := PZ - dx/l; end;
  end;
  l := Sqrt(PX*PX + PZ*PZ);
  if l > 1e-9 then begin PX := PX/l; PZ := PZ/l; end
  else begin PX := 0.0; PZ := 0.0; end;
end;

procedure OffsetPolyline(const C: TXZArray; Offset: Double; out Pts: TXZArray);
var
  i: Integer;
  px, pz: Double;
begin
  Pts := nil;                     { out-параметр: явная инициализация перед SetLength }
  SetLength(Pts, Length(C));
  for i := 0 to High(C) do
  begin
    PerpAt(C, i, px, pz);
    Pts[i].X := C[i].X + px * Offset;
    Pts[i].Z := C[i].Z + pz * Offset;
  end;
end;

function MaskPixCoord(const V, Origin, Size: Single; Res: Integer): Single; inline;
begin
  Result := ((V - Origin) / Size) * (Res - 1);
end;

procedure WalkGridCells(const X0, Z0, X1, Z1: Double;
  Visit: TGridCellVisitProc; Ctx: Pointer);
var
  ix, iz, endIx, endIz: Integer;
  stepX, stepZ: Integer;
  toX, toZ, vX, vZ: Double;
  tMaxX, tMaxZ, tDeltaX, tDeltaZ: Double;
  StepsX, StepsZ: Integer;
  CanStepX, CanStepZ: Boolean;
begin
  ix := Floor(X0);
  iz := Floor(Z0);
  endIx := Floor(X1);
  endIz := Floor(Z1);

  Visit(ix, iz, Ctx);

  if (ix = endIx) and (iz = endIz) then Exit;

  if X1 > X0 then stepX := 1
  else if X1 < X0 then stepX := -1
  else stepX := 0;
  if Z1 > Z0 then stepZ := 1
  else if Z1 < Z0 then stepZ := -1
  else stepZ := 0;

  vX := Abs(X1 - X0);
  vZ := Abs(Z1 - Z0);

  if stepX > 0 then toX := (ix + 1) - X0
  else if stepX < 0 then toX := X0 - ix
  else toX := 0;

  if stepZ > 0 then toZ := (iz + 1) - Z0
  else if stepZ < 0 then toZ := Z0 - iz
  else toZ := 0;

  if vX > 0 then
  begin
    tDeltaX := 1 / vX;
    tMaxX := toX / vX;
  end
  else
  begin
    tDeltaX := 1e30;
    tMaxX := 1e30;
  end;
  if vZ > 0 then
  begin
    tDeltaZ := 1 / vZ;
    tMaxZ := toZ / vZ;
  end
  else
  begin
    tDeltaZ := 1e30;
    tMaxZ := 1e30;
  end;

  StepsX := Abs(endIx - ix);
  StepsZ := Abs(endIz - iz);

  while (StepsX > 0) or (StepsZ > 0) do
  begin
    CanStepX := (StepsX > 0);
    CanStepZ := (StepsZ > 0);

    if CanStepX and (not CanStepZ or (tMaxX <= tMaxZ)) then
    begin
      tMaxX := tMaxX + tDeltaX;
      ix := ix + stepX;
      Dec(StepsX);
    end
    else
    begin
      tMaxZ := tMaxZ + tDeltaZ;
      iz := iz + stepZ;
      Dec(StepsZ);
    end;

    Visit(ix, iz, Ctx);
  end;
end;

class function TLatLon.Make(ALat, ALon: Double): TLatLon;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1040);{$ENDIF}
  Result.Lat := ALat;
  Result.Lon := ALon;
end;

function TLatLon.DistanceTo(const Other: TLatLon): Double;
var
  Lat1, Lat2, DLat, DLon, A, C: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(92);{$ENDIF}
  Lat1 := Lat * DEG_TO_RAD;
  Lat2 := Other.Lat * DEG_TO_RAD;
  DLat := (Other.Lat - Lat) * DEG_TO_RAD;
  DLon := (Other.Lon - Lon) * DEG_TO_RAD;

  A := Sin(DLat / 2) * Sin(DLat / 2) +
       Cos(Lat1) * Cos(Lat2) * Sin(DLon / 2) * Sin(DLon / 2);
  C := 2 * ArcTan2(Sqrt(A), Sqrt(1 - A));
  Result := EARTH_RADIUS_M * C;
end;

function TLatLon.ToString: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(93);{$ENDIF}
  Result := FormatFloat('0.000000', Lat, InvariantFmt) + ',' +
            FormatFloat('0.000000', Lon, InvariantFmt);
end;

class function TLatLonBox.Make(AMinLat, AMinLon, AMaxLat, AMaxLon: Double): TLatLonBox;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1041);{$ENDIF}
  Result.MinLat := AMinLat;
  Result.MinLon := AMinLon;
  Result.MaxLat := AMaxLat;
  Result.MaxLon := AMaxLon;
end;

class function TLatLonBox.Empty: TLatLonBox;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1042);{$ENDIF}
  { Sentinel: Min > Max → IsEmpty = True. }
  Result.MinLat :=  1.0e9;
  Result.MinLon :=  1.0e9;
  Result.MaxLat := -1.0e9;
  Result.MaxLon := -1.0e9;
end;

function TLatLonBox.IsEmpty: Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(94);{$ENDIF}
  Result := (MinLat > MaxLat) or (MinLon > MaxLon);
end;

function TLatLonBox.Center: TLatLon;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(95);{$ENDIF}
  Result.Lat := (MinLat + MaxLat) * 0.5;
  Result.Lon := (MinLon + MaxLon) * 0.5;
end;

function TLatLonBox.Width: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(96);{$ENDIF}
  Result := MaxLon - MinLon;
end;

function TLatLonBox.Height: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(97);{$ENDIF}
  Result := MaxLat - MinLat;
end;

function TLatLonBox.ExpandMeters(Meters: Double): TLatLonBox;
var
  CenterLatRad, DLat, DLon, CosLat: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(98);{$ENDIF}
  CenterLatRad := Center.Lat * DEG_TO_RAD;
  DLat := (Meters / EARTH_RADIUS_M) * RAD_TO_DEG;

  CosLat := Cos(CenterLatRad);
  if Abs(CosLat) < 1.0e-9 then
    DLon := DLat                  { near poles: cos→0, skip the division }
  else
    DLon := DLat / CosLat;

  Result.MinLat := MinLat - DLat;
  Result.MaxLat := MaxLat + DLat;
  Result.MinLon := MinLon - DLon;
  Result.MaxLon := MaxLon + DLon;
end;

function TLatLonBox.Include(const P: TLatLon): TLatLonBox;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(99);{$ENDIF}
  if IsEmpty then
  begin
    Result.MinLat := P.Lat;  Result.MaxLat := P.Lat;
    Result.MinLon := P.Lon;  Result.MaxLon := P.Lon;
    Exit;
  end;
  Result.MinLat := Math.Min(MinLat, P.Lat);
  Result.MaxLat := Math.Max(MaxLat, P.Lat);
  Result.MinLon := Math.Min(MinLon, P.Lon);
  Result.MaxLon := Math.Max(MaxLon, P.Lon);
end;

function TLatLonBox.Union(const Other: TLatLonBox): TLatLonBox;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(100);{$ENDIF}
  if IsEmpty       then Exit(Other);
  if Other.IsEmpty then Exit(Self);
  Result.MinLat := Math.Min(MinLat, Other.MinLat);
  Result.MaxLat := Math.Max(MaxLat, Other.MaxLat);
  Result.MinLon := Math.Min(MinLon, Other.MinLon);
  Result.MaxLon := Math.Max(MaxLon, Other.MaxLon);
end;

function TLatLonBox.ToString: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(101);{$ENDIF}
  Result := Format('[%s, %s]–[%s, %s]', [
    FormatFloat('0.000000', MinLat, InvariantFmt),
    FormatFloat('0.000000', MinLon, InvariantFmt),
    FormatFloat('0.000000', MaxLat, InvariantFmt),
    FormatFloat('0.000000', MaxLon, InvariantFmt)
  ]);
end;

class function TLocalBox.Make(const AMin, AMax: TVector3): TLocalBox;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1043);{$ENDIF}
  Result.MinPt := AMin;
  Result.MaxPt := AMax;
end;

class function TLocalBox.Empty: TLocalBox;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1044);{$ENDIF}
  Result.MinPt := Vector3( 1.0e30,  1.0e30,  1.0e30);
  Result.MaxPt := Vector3(-1.0e30, -1.0e30, -1.0e30);
end;

function TLocalBox.IsEmpty: Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(102);{$ENDIF}
  Result := (MinPt.X > MaxPt.X) or
            (MinPt.Y > MaxPt.Y) or
            (MinPt.Z > MaxPt.Z);
end;

function TLocalBox.Center: TVector3;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(103);{$ENDIF}
  Result := (MinPt + MaxPt) * 0.5;
end;

function TLocalBox.Size: TVector3;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(104);{$ENDIF}
  Result := MaxPt - MinPt;
end;

function TLocalBox.Include(const P: TVector3): TLocalBox;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(105);{$ENDIF}
  if IsEmpty then
  begin
    Result.MinPt := P;
    Result.MaxPt := P;
    Exit;
  end;
  Result.MinPt.X := Math.Min(MinPt.X, P.X);
  Result.MinPt.Y := Math.Min(MinPt.Y, P.Y);
  Result.MinPt.Z := Math.Min(MinPt.Z, P.Z);
  Result.MaxPt.X := Math.Max(MaxPt.X, P.X);
  Result.MaxPt.Y := Math.Max(MaxPt.Y, P.Y);
  Result.MaxPt.Z := Math.Max(MaxPt.Z, P.Z);
end;

function TLocalBox.Union(const Other: TLocalBox): TLocalBox;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(106);{$ENDIF}
  if IsEmpty       then Exit(Other);
  if Other.IsEmpty then Exit(Self);
  Result.MinPt.X := Math.Min(MinPt.X, Other.MinPt.X);
  Result.MinPt.Y := Math.Min(MinPt.Y, Other.MinPt.Y);
  Result.MinPt.Z := Math.Min(MinPt.Z, Other.MinPt.Z);
  Result.MaxPt.X := Math.Max(MaxPt.X, Other.MaxPt.X);
  Result.MaxPt.Y := Math.Max(MaxPt.Y, Other.MaxPt.Y);
  Result.MaxPt.Z := Math.Max(MaxPt.Z, Other.MaxPt.Z);
end;

procedure EnsureCCWXZ(var Pts: array of TVector3);
var
  I, N: Integer;
  Tv:   TVector3;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(108);{$ENDIF}
  N := Length(Pts);
  if PolygonSignedAreaXZ(Pts) > 0 then
    for I := 0 to (N div 2) - 1 do
    begin
      Tv := Pts[I];  Pts[I] := Pts[N - 1 - I];  Pts[N - 1 - I] := Tv;
    end;
end;

procedure EnsureCCWXZ(var Pts: array of TVector3;
  var Heights: array of Single);
var
  I, N: Integer;
  Tv:   TVector3;
  Th:   Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1303);{$ENDIF}
  N := Length(Pts);
  if PolygonSignedAreaXZ(Pts) > 0 then
    for I := 0 to (N div 2) - 1 do
    begin
      Tv := Pts[I];  Pts[I] := Pts[N - 1 - I];  Pts[N - 1 - I] := Tv;
      Th := Heights[I];  Heights[I] := Heights[N - 1 - I];  Heights[N - 1 - I] := Th;
    end;
end;

function PolygonSignedAreaXZ(const F: array of TVector3): Single;
var
  I, J, N: Integer;
  S: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(109);{$ENDIF}
  N := Length(F);
  if N < 3 then Exit(0);
  S := 0;
  for I := 0 to N - 1 do
  begin
    J := (I + 1) mod N;
    S := S + (F[I].X * F[J].Z - F[J].X * F[I].Z);
  end;
  Result := Single(S * 0.5);
end;

function PointInPolygonXZ(const P: TVector3;
  const Polygon: array of TVector3): Boolean;
var
  N, I, J: Integer;
  Vi, Vj: TVector3;
  Inside: Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(110);{$ENDIF}
  N := Length(Polygon);
  Result := False;
  if N < 3 then Exit;
  Inside := False;
  J := N - 1;
  for I := 0 to N - 1 do
  begin
    Vi := Polygon[I];
    Vj := Polygon[J];
    if ((Vi.Z > P.Z) <> (Vj.Z > P.Z)) and
       (P.X < (Vj.X - Vi.X) * (P.Z - Vi.Z) / (Vj.Z - Vi.Z) + Vi.X) then
      Inside := not Inside;
    J := I;
  end;
  Result := Inside;
end;

function PointInRingXZ(PX, PZ: Double; const Ring: TPolygonRing): Boolean;
var
  N, I, J: Integer;
  ViX, ViZ, VjX, VjZ: Double;
  Inside: Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(111);{$ENDIF}
  N := Length(Ring);
  Result := False;
  if N < 3 then Exit;
  Inside := False;
  J := N - 1;
  for I := 0 to N - 1 do
  begin
    ViX := Ring[I].X;  ViZ := Ring[I].Z;
    VjX := Ring[J].X;  VjZ := Ring[J].Z;
    if ((ViZ > PZ) <> (VjZ > PZ)) and
       (PX < (VjX - ViX) * (PZ - ViZ) / (VjZ - ViZ) + ViX) then
      Inside := not Inside;
    J := I;
  end;
  Result := Inside;
end;

function WorldScaleLatBand(ALatDeg: Double): Double;
const
  { Шаг квантования по ln(cos): ровно ПОТОЛОК относительной ошибки метрики
    востока = EPS/2 = 0.5% — одинаковый на всей планете. }
  LNCOS_EPS = 0.01;
var
  C, K: Double;
begin
  { Клампы: у полюсов cos→0, ln уходит в -inf; за пределами Меркатора мир
    всё равно не строится (WEB_MERCATOR_MAX_LAT). }
  if ALatDeg >  WEB_MERCATOR_MAX_LAT then ALatDeg :=  WEB_MERCATOR_MAX_LAT;
  if ALatDeg < -WEB_MERCATOR_MAX_LAT then ALatDeg := -WEB_MERCATOR_MAX_LAT;
  C := Cos(ALatDeg * DEG_TO_RAD);
  if C < 1.0e-6 then C := 1.0e-6;
  { Индекс полосы и её представитель (середина в логарифме косинуса).
    Floor, а не Round: полоса — это полуинтервал [k·EPS, (k+1)·EPS), и оба
    полушария дают одну и ту же полосу для |lat| (cos чётен). }
  K := Floor(Ln(C) / LNCOS_EPS);
  C := Exp((K + 0.5) * LNCOS_EPS);
  if C > 1.0 then C := 1.0;
  Result := ArcCos(C) * RAD_TO_DEG;
  { Южное полушарие: cos чётен, метрика та же — знак возвращаем, чтобы
    значение читалось человеком и совпадало с исходной широтой по смыслу.
    На проекцию знак не влияет (Cos(-x) = Cos(x)). }
  if ALatDeg < 0 then Result := -Result;
end;

constructor TLocalProjection.Create(const AOrigin: TLatLon; AScaleLatDeg: Double);
var
  ScaleLat: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1045);{$ENDIF}
  inherited Create;
  FOrigin := AOrigin;
  { Longitude scale is cos(latitude); a valid AScaleLatDeg fixes which latitude (e.g. the
    session lat) independently of the block-local origin. 0 / out of range -> origin's lat. }
  ScaleLat := AScaleLatDeg;
  if (ScaleLat <= -90.0) or (ScaleLat >= 90.0) or (ScaleLat = 0.0) then
    ScaleLat := AOrigin.Lat;
  FCosOriginLat := Cos(ScaleLat * DEG_TO_RAD);
  if Abs(FCosOriginLat) < 1.0e-9 then
    FCosOriginLat := 1.0e-9;     { clamp near poles }
  { Precompute the per-degree metric factors once. }
  FMpdLat    := DEG_TO_RAD * EARTH_RADIUS_M;
  FMpdLon    := FMpdLat * FCosOriginLat;
  FInvMpdLat := 1.0 / FMpdLat;
  FInvMpdLon := 1.0 / FMpdLon;
end;

function TLocalProjection.Project(const P: TLatLon; Elevation: Double): TVector3;
var
  East, North: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(112);{$ENDIF}
  { Equirectangular: east/north in metres relative to Origin. }
  East  := (P.Lon - FOrigin.Lon) * FMpdLon;
  North := (P.Lat - FOrigin.Lat) * FMpdLat;

  Result.X := -East;        { east → −X (matching GpsToLocalEastNorth) }
  Result.Y :=  Elevation;
  Result.Z :=  North;
end;

function TLocalProjection.Project(Lat, Lon: Double): TVector3;
var
  P: TLatLon;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1304);{$ENDIF}
  P.Lat := Lat;
  P.Lon := Lon;
  Result := Project(P, 0);
end;

function TLocalProjection.Unproject(const Local: TVector3): TLatLon;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(113);{$ENDIF}
  Result := Unproject(Local.X, Local.Z);
end;

function TLocalProjection.Unproject(LocalX, LocalZ: Single): TLatLon;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1305);{$ENDIF}
  { East = -LocalX, North = LocalZ; multiply by precomputed reciprocals. }
  Result.Lat := FOrigin.Lat +    LocalZ  * FInvMpdLat;
  Result.Lon := FOrigin.Lon + (-LocalX)  * FInvMpdLon;
end;

function TLocalProjection.MetersPerDegreeLat: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(115);{$ENDIF}
  Result := FMpdLat;
end;

function TLocalProjection.MetersPerDegreeLon: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(116);{$ENDIF}
  Result := FMpdLon;
end;

class function TTileXY.Make(AX, AY, AZoom: Integer): TTileXY;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1046);{$ENDIF}
  Result.X    := AX;
  Result.Y    := AY;
  Result.Zoom := AZoom;
end;

function TTileXY.ToString: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(117);{$ENDIF}
  Result := Format('z%d/%d/%d', [Zoom, X, Y]);
end;

class function TTileMath.LatLonToTile(const P: TLatLon; Zoom: Integer): TTileXY;
var
  N:        Double;
  NInt:     Integer;
  Lat:      Double;
  LatRad:   Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1047);{$ENDIF}
  if Zoom < 0 then Zoom := 0;
  if Zoom > 22 then Zoom := 22;

  Lat := P.Lat;
  if Lat >  WEB_MERCATOR_MAX_LAT then Lat :=  WEB_MERCATOR_MAX_LAT;
  if Lat < -WEB_MERCATOR_MAX_LAT then Lat := -WEB_MERCATOR_MAX_LAT;

  N    := IntPower(2, Zoom);
  NInt := Trunc(N);

  Result.Zoom := Zoom;
  Result.X    := Floor((P.Lon + 180.0) / 360.0 * N);

  LatRad   := Lat * DEG_TO_RAD;
  { Web Mercator Y. asinh(tan(lat)) = ln(tan(lat) + sec(lat)). }
  Result.Y := Floor((1.0 - Ln(Tan(LatRad) + 1.0 / Cos(LatRad)) / Pi) / 2.0 * N);

  if Result.X < 0          then Result.X := 0;
  if Result.Y < 0          then Result.Y := 0;
  if Result.X >= NInt      then Result.X := NInt - 1;
  if Result.Y >= NInt      then Result.Y := NInt - 1;
end;

class function TTileMath.TileToLatLonBox(const T: TTileXY): TLatLonBox;
var
  N: Double;
  LatRadTop, LatRadBot: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1048);{$ENDIF}
  N := IntPower(2, T.Zoom);
  Result.MinLon :=  T.X        / N * 360.0 - 180.0;
  Result.MaxLon := (T.X + 1.0) / N * 360.0 - 180.0;
  { Y grows southward → MaxLat ↔ Y, MinLat ↔ Y+1. }
  LatRadTop := ArcTan(Sinh(Pi * (1.0 - 2.0 *  T.Y          / N)));
  LatRadBot := ArcTan(Sinh(Pi * (1.0 - 2.0 * (T.Y + 1.0)   / N)));
  Result.MaxLat := LatRadTop * RAD_TO_DEG;
  Result.MinLat := LatRadBot * RAD_TO_DEG;
end;

class function TTileMath.TilesCoveringBox(const Box: TLatLonBox; Zoom: Integer): TTileXYArray;
var
  TopLeft, BotRight: TTileXY;
  X, Y, Idx: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1049);{$ENDIF}
  Result := nil;
  if Box.IsEmpty then Exit;

  TopLeft  := LatLonToTile(TLatLon.Make(Box.MaxLat, Box.MinLon), Zoom);
  BotRight := LatLonToTile(TLatLon.Make(Box.MinLat, Box.MaxLon), Zoom);

  SetLength(Result, (BotRight.Y - TopLeft.Y + 1) * (BotRight.X - TopLeft.X + 1));
  Idx := 0;
  for Y := TopLeft.Y to BotRight.Y do
    for X := TopLeft.X to BotRight.X do
    begin
      Result[Idx] := TTileXY.Make(X, Y, Zoom);
      Inc(Idx);
    end;
end;

class function TTileMath.FormatTileUrl(const Template: string; const T: TTileXY): string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1050);{$ENDIF}
  Result := Template;
  Result := StringReplace(Result, '{z}', IntToStr(T.Zoom), [rfReplaceAll]);
  Result := StringReplace(Result, '{x}', IntToStr(T.X),    [rfReplaceAll]);
  Result := StringReplace(Result, '{y}', IntToStr(T.Y),    [rfReplaceAll]);
end;

end.
