unit Osm3dGeomPOI;

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$codepage UTF8}
{$WARN 5091 OFF}

interface

uses
  Classes,
  SysUtils,
  Math,
  CastleVectors,
  Osm3dGeoMath,
  Osm3dHeightmap,
  Osm3dGeomTerrain,
  Osm3dOsmData,
  Osm3dGeomMesh,
  X3DNodes
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
,
  Osm3dOsmIndex;      { TOsmRoadIndex — единый пер-блочный индекс дорог }

type
  TPOIKind = (
    pkNone,
    pkTrafficSignal,
    pkHydrant,
    pkTower,
    pkFountain,
    pkPole
  );

  TPOIBuilder = class
  public
    class function ClassifyNode(const Tags: TOSMTags): TPOIKind;

    class function BuildAll(Dataset: TOSMDataset; HM: THeightmap;
      Projection: TLocalProjection;
      Terrain: TTerrainSampler = nil): TMesh;

    class procedure AppendTrafficSignal(Target: TMesh; const At: TVector3);
    class procedure AppendHydrant(Target: TMesh; const At: TVector3);
    class procedure AppendTower(Target: TMesh; const At: TVector3);
    class procedure AppendFountain(Target: TMesh; const At: TVector3);
    class procedure AppendPole(Target: TMesh; const At: TVector3;
      Height: Single);
  end;

const
  MIN_BUILDING_LABEL_AREA  = 400.0;   { m², ~20×20 m minimum }
  MAX_LABELS               = 300;


type
  { Extended enum. First 5 values match TPOIKind for fall-through delegation. }
  TPOIKindExt = (
    pkxNone,
    pkxTrafficSignal,
    pkxHydrant,
    pkxTower,
    pkxFountain,
    pkxPole,
    pkxMonument,
    pkxBusStop,
    pkxBench,
    pkxPlaceOfWorship,
    pkxInfoBoard,
    pkxBin
  );

  { Compact POI placement for the tiled cache. The assembler bakes templates
    into static material batches; the diagnostic fallback uses shared X3D
    shapes under individual transforms. }
  TPOIInstance = record
    Kind:     TPOIKindExt;
    Position: TVector3;
    Rotation: Single;     { yaw about +Y (rad); bus stops face the road, else 0 }
  end;
  TPOIInstanceArray = array of TPOIInstance;

  TPOIBuilderExt = class
  public
    { Returns kind or pkxNone. Checks tags in specificity order
      (e.g. highway=bus_stop wins over highway=traffic_signals). }
    class function ClassifyNode(const Tags: TOSMTags): TPOIKindExt;

    { One TMesh with all POIs at heightmap-resolved Y (BuildAllInstances + per-instance Append*).
      Kept for the legacy non-tiled Assemble path; the tiled path uses BuildAllInstances directly. }
    class function BuildAll(Dataset: TOSMDataset; HM: THeightmap;
      Projection: TLocalProjection;
      Terrain: TTerrainSampler = nil): TMesh;

    { Flat placement list for the tiled assembler. Y from the heightmap
      when HM <> nil, else 0. }
    class function BuildAllInstances(Dataset: TOSMDataset; HM: THeightmap;
      Projection: TLocalProjection;
      Terrain: TTerrainSampler = nil;
      ARoadIdx: TOsmRoadIndex = nil): TPOIInstanceArray;

    { Placement for a bus stop / platform: finds the nearest vehicular road,
      moves the model to the roadside (keeping the OSM node's side, pushed out
      to a minimum clearance only if it sits on the carriageway), and returns
      the yaw about +Y that turns the model's front (+Z) to face the road. When
      no road is near, returns NodeP unchanged with Yaw=0. Shared by the POI
      builder (the model) and the plate builder (the name plate) so both align.
      NodeP is the already-projected node position (metres); Y is preserved. }
    class function ComputeStopPlacement(Dataset: TOSMDataset;
      Projection: TLocalProjection; const NodeP: TVector3;
      out Yaw: Single): TVector3;

    { True when Node is a public_transport=stop_position "point on the road" made
      redundant by a nearby highway=bus_stop / public_transport=platform POI (the
      POI is placed more precisely). The model builder and the plate builder both
      skip such nodes, so a stop mapped as both platform + stop_position is drawn
      once, at the platform. A lone stop_position (no nearby POI) is kept. }
    class function IsRedundantStopPositionNode(Dataset: TOSMDataset;
      Projection: TLocalProjection; Node: TOSMNode): Boolean;

    { Быстрые версии по общему пер-блочному индексу (Osm3dOsmIndex):
      O(окрестности) вместо O(датасета) на остановку. }
    class function ComputeStopPlacement(AIdx: TOsmRoadIndex;
      const NodeP: TVector3; out Yaw: Single): TVector3; overload;
    class function IsRedundantStopPositionNode(AIdx: TOsmRoadIndex;
      Dataset: TOSMDataset; Projection: TLocalProjection;
      Node: TOSMNode): Boolean; overload;

    { Small TMesh for one kind, built at origin; caller owns and frees it. nil for pkxNone/unknown. }
    class function BuildKindMesh(Kind: TPOIKindExt): TMesh;

    { Bake one placed template into a static material batch. Rotation matches
      the X3D +Y axis-angle transform; normals rotate, UVs stay unchanged. }
    class procedure AppendInstance(Target, Template: TMesh;
      const Position: TVector3; Yaw: Single);

    { Traffic signal split into pole + head box so the assembler can texture the
      box (traffic_light.png) while the pole keeps the plain POI material. Both
      built at origin; caller owns and frees. }
    class function BuildTrafficSignalPoleMesh: TMesh;
    class function BuildTrafficSignalBoxSidesMeshXZ(AXU0, AXU1, AZU0, AZU1: Single): TMesh;
    class function BuildTrafficSignalBoxCapsMesh: TMesh;

    class procedure AppendMonument(Target: TMesh; const At: TVector3);
    class procedure AppendBusStop(Target: TMesh; const At: TVector3);
    class procedure AppendBench(Target: TMesh; const At: TVector3);
    class procedure AppendBin(Target: TMesh; const At: TVector3);
    class procedure AppendPlaceOfWorship(Target: TMesh; const At: TVector3);
    class procedure AppendInfoBoard(Target: TMesh; const At: TVector3);
  end;

type
  TLabelBuilder = class
  public
    { Returns a TGroupNode owning all label billboards, or nil. }
    class function BuildAll(Dataset: TOSMDataset; HM: THeightmap;
      Projection: TLocalProjection;
      Terrain: TTerrainSampler = nil): TGroupNode;
  end;

implementation

uses Osm3dOsmTagUtils;

{ Ground height for POI/labels — общий SampleTerrainYGeo в Osm3dGeomTerrain
  (sampler SampleAt -> heightmap SampleBilinear -> 0). }

{ Geometric primitives (used by both TPOIBuilder and TPOIBuilderExt) }

{ Low-poly cylinder with ring-shared vertices (smooth side shading). }
procedure AppendCylinder(Target: TMesh; const Center: TVector3;
  Radius, Height: Single; Sides: Integer);
var
  I, INext: Integer;
  Ang: Single;
  Cx, Cz: Single;
  RingBot, RingTop: array of Integer;
  CenterBot, CenterTop: Integer;
  P, N: TVector3;
  Y0, Y1: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(288);{$ENDIF}
  if Sides < 3 then Sides := 8;
  Y0 := Center.Y;
  Y1 := Center.Y + Height;

  SetLength(RingBot, Sides);
  SetLength(RingTop, Sides);
  for I := 0 to Sides - 1 do
  begin
    Ang := I * 2 * Pi / Sides;
    Cx := Cos(Ang);  Cz := Sin(Ang);
    P := Vector3(Center.X + Cx * Radius, Y0, Center.Z + Cz * Radius);
    N := Vector3(Cx, 0, Cz);
    RingBot[I] := Target.AddVertex(P, N);
    P.Y := Y1;
    RingTop[I] := Target.AddVertex(P, N);
  end;
  CenterBot := Target.AddVertex(Vector3(Center.X, Y0, Center.Z), Vector3(0, -1, 0));
  CenterTop := Target.AddVertex(Vector3(Center.X, Y1, Center.Z), Vector3(0,  1, 0));

  for I := 0 to Sides - 1 do
  begin
    INext := (I + 1) mod Sides;
    Target.AddQuad(RingBot[I], RingBot[INext], RingTop[INext], RingTop[I]);
  end;
  { Bottom cap (CW from above → CCW from below). }
  for I := 0 to Sides - 1 do
  begin
    INext := (I + 1) mod Sides;
    Target.AddTriangle(CenterBot, RingBot[INext], RingBot[I]);
  end;
  for I := 0 to Sides - 1 do
  begin
    INext := (I + 1) mod Sides;
    Target.AddTriangle(CenterTop, RingTop[I], RingTop[INext]);
  end;
end;

{ Axis-aligned box: 24 vertices (4 per face) so every face carries its OWN
  outward normal (the old version shared one (0,1,0) normal for all 8 corners,
  which lit the sides and bottom as if they faced up). Each face gets the full
  UV square (0,0)-(1,1) so a texture maps once per side. Winding is CCW seen
  from outside → correct with Solid=True (back-face culling on). }
procedure AppendBox(Target: TMesh; const Center: TVector3;
  W, H, D: Single; ASides: Boolean = True; ACaps: Boolean = True;
  AUMin: Single = 0.0; AUMax: Single = 1.0);
var
  HW, HH, HD, cx, cy, cz: Single;

  procedure Face(const Nx, Ny, Nz: Single;
    const x0,y0,z0, x1,y1,z1, x2,y2,z2, x3,y3,z3: Single);
  var N: TVector3; a, b, c, d: Integer;
  begin
    N := Vector3(Nx, Ny, Nz);
    a := Target.AddVertex(Vector3(x0, y0, z0), N, MakeUV(AUMin, 0));
    b := Target.AddVertex(Vector3(x1, y1, z1), N, MakeUV(AUMax, 0));
    c := Target.AddVertex(Vector3(x2, y2, z2), N, MakeUV(AUMax, 1));
    d := Target.AddVertex(Vector3(x3, y3, z3), N, MakeUV(AUMin, 1));
    Target.AddQuad(a, b, c, d);
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(289);{$ENDIF}
  HW := W * 0.5;  HH := H * 0.5;  HD := D * 0.5;
  cx := Center.X;  cy := Center.Y;  cz := Center.Z;

  if ASides then
  begin
    { +X }  Face( 1, 0, 0,
      cx+HW, cy-HH, cz+HD,  cx+HW, cy-HH, cz-HD,  cx+HW, cy+HH, cz-HD,  cx+HW, cy+HH, cz+HD);
    { -X }  Face(-1, 0, 0,
      cx-HW, cy-HH, cz-HD,  cx-HW, cy-HH, cz+HD,  cx-HW, cy+HH, cz+HD,  cx-HW, cy+HH, cz-HD);
    { +Z }  Face( 0, 0, 1,
      cx-HW, cy-HH, cz+HD,  cx+HW, cy-HH, cz+HD,  cx+HW, cy+HH, cz+HD,  cx-HW, cy+HH, cz+HD);
    { -Z }  Face( 0, 0,-1,
      cx+HW, cy-HH, cz-HD,  cx-HW, cy-HH, cz-HD,  cx-HW, cy+HH, cz-HD,  cx+HW, cy+HH, cz-HD);
  end;

  if ACaps then
  begin
    { +Y }  Face( 0, 1, 0,
      cx-HW, cy+HH, cz+HD,  cx+HW, cy+HH, cz+HD,  cx+HW, cy+HH, cz-HD,  cx-HW, cy+HH, cz-HD);
    { -Y }  Face( 0,-1, 0,
      cx-HW, cy-HH, cz-HD,  cx+HW, cy-HH, cz-HD,  cx+HW, cy-HH, cz+HD,  cx-HW, cy-HH, cz+HD);
  end;
end;

{ The 4 side faces of a box with SEPARATE U ranges per axis: the +/-X pair maps
  atlas U [XU0..XU1], the +/-Z pair maps [ZU0..ZU1]. Lets a traffic light show
  perpendicular directions the opposite signal. Per-face outward normals, V=[0,1]. }
procedure AppendBoxSidesXZ(Target: TMesh; const Center: TVector3;
  W, H, D: Single; XU0, XU1, ZU0, ZU1: Single);
var
  HW, HH, HD, cx, cy, cz: Single;

  procedure Face(const Nx, Ny, Nz: Single;
    const x0,y0,z0, x1,y1,z1, x2,y2,z2, x3,y3,z3: Single;
    const U0, U1: Single);
  var N: TVector3; a, b, c, d: Integer;
  begin
    N := Vector3(Nx, Ny, Nz);
    { The supplied sprites have green at the image top and red at the bottom.
      Reverse V on these signal faces so red is above yellow, green below. }
    a := Target.AddVertex(Vector3(x0, y0, z0), N, MakeUV(U0, 1));
    b := Target.AddVertex(Vector3(x1, y1, z1), N, MakeUV(U1, 1));
    c := Target.AddVertex(Vector3(x2, y2, z2), N, MakeUV(U1, 0));
    d := Target.AddVertex(Vector3(x3, y3, z3), N, MakeUV(U0, 0));
    Target.AddQuad(a, b, c, d);
  end;

begin
  HW := W * 0.5;  HH := H * 0.5;  HD := D * 0.5;
  cx := Center.X;  cy := Center.Y;  cz := Center.Z;

  { +/-X faces -> XU range }
  { +X }  Face( 1, 0, 0,
    cx+HW, cy-HH, cz+HD,  cx+HW, cy-HH, cz-HD,  cx+HW, cy+HH, cz-HD,  cx+HW, cy+HH, cz+HD, XU0, XU1);
  { -X }  Face(-1, 0, 0,
    cx-HW, cy-HH, cz-HD,  cx-HW, cy-HH, cz+HD,  cx-HW, cy+HH, cz+HD,  cx-HW, cy+HH, cz-HD, XU0, XU1);

  { +/-Z faces -> ZU range }
  { +Z }  Face( 0, 0, 1,
    cx-HW, cy-HH, cz+HD,  cx+HW, cy-HH, cz+HD,  cx+HW, cy+HH, cz+HD,  cx-HW, cy+HH, cz+HD, ZU0, ZU1);
  { -Z }  Face( 0, 0,-1,
    cx+HW, cy-HH, cz-HD,  cx-HW, cy-HH, cz-HD,  cx-HW, cy+HH, cz-HD,  cx+HW, cy+HH, cz-HD, ZU0, ZU1);
end;

class function TPOIBuilder.ClassifyNode(const Tags: TOSMTags): TPOIKind;
var V: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1089);{$ENDIF}
  Result := pkNone;
  V := Tags.GetLower('highway');
  if V = 'traffic_signals' then Exit(pkTrafficSignal);
  if V = 'street_lamp' then Exit(pkPole);

  V := Tags.GetLower('emergency');
  if V = 'fire_hydrant' then Exit(pkHydrant);

  V := Tags.GetLower('man_made');
  { man_made=tower теперь строится как тайловая геометрия здания (труба),
    а не POI-инстанс — точки POI некорректны при тайлинге. }
  if (V = 'water_tower') or
     (V = 'communications_tower') then Exit(pkTower);
  if (V = 'mast') or (V = 'flagpole') or
     (V = 'utility_pole') or (V = 'lighthouse') then Exit(pkPole);

  V := Tags.GetLower('amenity');
  if V = 'fountain' then Exit(pkFountain);
end;

class procedure TPOIBuilder.AppendTrafficSignal(Target: TMesh;
  const At: TVector3);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1090);{$ENDIF}
  AppendCylinder(Target, At, 0.07, 3.5, 6);
  AppendBox(Target,
    Vector3(At.X, At.Y + 3.7, At.Z), 0.30, 0.80, 0.30);
end;

class procedure TPOIBuilder.AppendHydrant(Target: TMesh; const At: TVector3);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1091);{$ENDIF}
  AppendCylinder(Target, At, 0.15, 0.60, 6);
  AppendBox(Target,
    Vector3(At.X, At.Y + 0.65, At.Z), 0.40, 0.10, 0.40);
end;

class procedure TPOIBuilder.AppendTower(Target: TMesh; const At: TVector3);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1092);{$ENDIF}
  { 25 m tube, 4 m diameter at base. }
  AppendCylinder(Target, At, 2.0, 25.0, 8);
end;

class procedure TPOIBuilder.AppendFountain(Target: TMesh; const At: TVector3);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1093);{$ENDIF}
  AppendCylinder(Target, At, 2.0, 0.60, 12);
  AppendCylinder(Target,
    Vector3(At.X, At.Y + 0.6, At.Z), 0.30, 1.50, 8);
end;

class procedure TPOIBuilder.AppendPole(Target: TMesh; const At: TVector3;
  Height: Single);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1094);{$ENDIF}
  AppendCylinder(Target, At, 0.10, Height, 6);
end;

class function TPOIBuilder.BuildAll(Dataset: TOSMDataset; HM: THeightmap;
  Projection: TLocalProjection;
  Terrain: TTerrainSampler): TMesh;
var
  Node: TOSMNode;
  Kind: TPOIKind;
  Pos: TVector3;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1095);{$ENDIF}
  Result := TMesh.Create('poi_instances');
  try
    for Node in Dataset.Nodes.Values do
    begin
      { подавляющее большинство узлов — безтеговые вершины геометрии:
        отсев до строковых map-lookup'ов ClassifyNode }
      if Node.Tags.Count = 0 then Continue;
      Kind := ClassifyNode(Node.Tags);
      if Kind = pkNone then Continue;

      Pos := NodePlanePos(Dataset, Node, Projection,
        SampleTerrainYGeo(Terrain, HM, Node.Position));   { int-first }
      case Kind of
        pkTrafficSignal: AppendTrafficSignal(Result, Pos);
        pkHydrant:       AppendHydrant(Result, Pos);
        pkTower:         AppendTower(Result, Pos);
        pkFountain:      AppendFountain(Result, Pos);
        pkPole:          AppendPole(Result, Pos, 6.0);
      end;
    end;
  except
    Result.Free;
    raise;
  end;
end;

class function TPOIBuilderExt.ClassifyNode(const Tags: TOSMTags): TPOIKindExt;
var V: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1096);{$ENDIF}
  Result := pkxNone;

  V := Tags.GetLower('historic');
  if (V = 'monument') or (V = 'memorial') or (V = 'statue') or
     (V = 'tomb') or (V = 'wayside_cross') or (V = 'wayside_shrine') or
     (V = 'archaeological_site') then Exit(pkxMonument);

  V := Tags.GetLower('tourism');
  if V = 'artwork' then Exit(pkxMonument);
  if V = 'information' then Exit(pkxInfoBoard);
  if (V = 'viewpoint') or (V = 'attraction') then Exit(pkxInfoBoard);

  V := Tags.GetLower('highway');
  if V = 'bus_stop' then Exit(pkxBusStop);
  if V = 'platform' then Exit(pkxBusStop);
  if V = 'traffic_signals' then Exit(pkxTrafficSignal);
  if V = 'street_lamp' then Exit(pkxPole);

  V := Tags.GetLower('public_transport');
  if (V = 'platform') or (V = 'stop_position') or (V = 'station') then
    Exit(pkxBusStop);

  V := Tags.GetLower('amenity');
  if V = 'bench' then Exit(pkxBench);
  if V = 'waste_basket' then Exit(pkxBin);
  if V = 'fountain' then Exit(pkxFountain);
  if V = 'place_of_worship' then Exit(pkxPlaceOfWorship);

  V := Tags.GetLower('emergency');
  if V = 'fire_hydrant' then Exit(pkxHydrant);

  V := Tags.GetLower('man_made');
  { man_made=tower теперь строится как тайловая геометрия здания (труба). }
  if (V = 'water_tower') or
     (V = 'communications_tower') or (V = 'lighthouse') then Exit(pkxTower);
  if (V = 'mast') or (V = 'flagpole') or
     (V = 'utility_pole') or (V = 'monitoring_station') then Exit(pkxPole);
  if V = 'obelisk' then Exit(pkxMonument);
end;

class procedure TPOIBuilderExt.AppendMonument(Target: TMesh; const At: TVector3);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1097);{$ENDIF}
  { Pedestal 1.4 × 0.5 × 1.4 m. }
  AppendBox(Target,
    Vector3(At.X, At.Y + 0.25, At.Z),
    1.4, 0.5, 1.4);
  { Stele: octagonal column r=0.3, h=2.5. }
  AppendCylinder(Target,
    Vector3(At.X, At.Y + 0.5, At.Z),
    0.30, 2.5, 8);
  { Cap 0.5 × 0.4 × 0.5. }
  AppendBox(Target,
    Vector3(At.X, At.Y + 3.2, At.Z),
    0.5, 0.4, 0.5);
end;

class procedure TPOIBuilderExt.AppendBusStop(Target: TMesh; const At: TVector3);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1098);{$ENDIF}
  { Platform 3 × 0.1 × 1.5 m, kerb at 0.15 m. }
  AppendBox(Target,
    Vector3(At.X, At.Y + 0.15, At.Z),
    3.0, 0.10, 1.5);
  { Two support posts. }
  AppendCylinder(Target,
    Vector3(At.X - 1.2, At.Y + 0.2, At.Z - 0.5),
    0.05, 2.3, 6);
  AppendCylinder(Target,
    Vector3(At.X + 1.2, At.Y + 0.2, At.Z - 0.5),
    0.05, 2.3, 6);
  { Flat canopy over posts. }
  AppendBox(Target,
    Vector3(At.X, At.Y + 2.55, At.Z - 0.5),
    3.0, 0.08, 1.2);
end;

class procedure TPOIBuilderExt.AppendBin(Target: TMesh; const At: TVector3);
begin
  AppendCylinder(Target,At,0.22,0.65,8);
  AppendBox(Target,Vector3(At.X,At.Y+0.72,At.Z),0.48,0.08,0.48);
end;

class procedure TPOIBuilderExt.AppendBench(Target: TMesh; const At: TVector3);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1099);{$ENDIF}
  { Seat 1.6 × 0.06 × 0.4 m at 0.45 m. }
  AppendBox(Target,
    Vector3(At.X, At.Y + 0.45, At.Z),
    1.6, 0.06, 0.40);
  AppendBox(Target,
    Vector3(At.X - 0.6, At.Y + 0.22, At.Z),
    0.08, 0.44, 0.30);
  AppendBox(Target,
    Vector3(At.X + 0.6, At.Y + 0.22, At.Z),
    0.08, 0.44, 0.30);
end;

class procedure TPOIBuilderExt.AppendPlaceOfWorship(Target: TMesh; const At: TVector3);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1100);{$ENDIF}
  { Placeholder body 6 × 8 × 5 m for amenity=place_of_worship without building=yes. }
  AppendBox(Target,
    Vector3(At.X, At.Y + 4.0, At.Z),
    6.0, 8.0, 5.0);
  { Bell tower 1.5 × 12 × 1.5 m. }
  AppendBox(Target,
    Vector3(At.X - 2.5, At.Y + 6.0, At.Z + 1.5),
    1.5, 12.0, 1.5);
  { Spire (simplified as thin box). }
  AppendBox(Target,
    Vector3(At.X - 2.5, At.Y + 13.0, At.Z + 1.5),
    0.4, 2.0, 0.4);
end;

class procedure TPOIBuilderExt.AppendInfoBoard(Target: TMesh; const At: TVector3);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1101);{$ENDIF}
  AppendCylinder(Target,
    Vector3(At.X, At.Y, At.Z),
    0.06, 1.8, 6);
  AppendBox(Target,
    Vector3(At.X, At.Y + 1.5, At.Z),
    0.8, 0.6, 0.05);
end;

class function TPOIBuilderExt.ComputeStopPlacement(Dataset: TOSMDataset;
  Projection: TLocalProjection; const NodeP: TVector3;
  out Yaw: Single): TVector3;
const
  MIN_CLEARANCE = 3.0;    { keep the model >= this far from the road centreline }
  MAX_SEARCH    = 40.0;   { ignore roads further than this from the stop }
var
  Way: TOSMWay;
  I: Integer;
  PrevOK, Found: Boolean;
  Nd: TOSMNode;
  PB: TVector3;
  Ax, Az, Bx, Bz, ex, ez, len2, t, qx, qz, dx, dz, d2: Single;
  bestD2, bQx, bQz, bEx, bEz: Single;
  Px, Pz, nx, nz, dist, nlen, place: Single;
  Hwy: string;
begin
  Yaw := 0;
  Result := NodeP;
  if (Dataset = nil) or (Projection = nil) then Exit;
  Px := NodeP.X; Pz := NodeP.Z;

  Found := False;
  bestD2 := MAX_SEARCH * MAX_SEARCH;
  Ax := 0; Az := 0;
  bQx := 0; bQz := 0; bEx := 0; bEz := 0;

  for Way in Dataset.Ways.Values do
  begin
    Hwy := Way.Tags.GetLower('highway');
    if Hwy = '' then Continue;
    { vehicular roads only — a bus faces the carriageway, not a path/platform }
    if (Hwy = 'footway') or (Hwy = 'path') or (Hwy = 'cycleway') or
       (Hwy = 'steps') or (Hwy = 'pedestrian') or (Hwy = 'bridleway') or
       (Hwy = 'corridor') or (Hwy = 'platform') or (Hwy = 'track') then Continue;
    if Length(Way.NodeRefs) < 2 then Continue;

    PrevOK := False;
    for I := 0 to High(Way.NodeRefs) do
    begin
      Nd := Dataset.FindNode(Way.NodeRefs[I]);
      if Nd = nil then
      begin PrevOK := False; Continue; end;
      PB := NodePlanePos(Dataset, Nd, Projection);   { int-first }
      Bx := PB.X; Bz := PB.Z;
      if PrevOK then
      begin
        ex := Bx - Ax; ez := Bz - Az;
        len2 := ex * ex + ez * ez;
        if len2 > 1.0e-9 then
        begin
          t := ((Px - Ax) * ex + (Pz - Az) * ez) / len2;
          if t < 0 then t := 0 else if t > 1 then t := 1;
          qx := Ax + ex * t; qz := Az + ez * t;
          dx := Px - qx; dz := Pz - qz;
          d2 := dx * dx + dz * dz;
          if d2 < bestD2 then
          begin
            bestD2 := d2; Found := True;
            bQx := qx; bQz := qz; bEx := ex; bEz := ez;
          end;
        end;
      end;
      Ax := Bx; Az := Bz; PrevOK := True;
    end;
  end;

  if not Found then Exit;   { no road nearby — leave the node as placed, Yaw=0 }

  { N = unit vector from the road toward the stop = the side the stop is on. }
  nx := Px - bQx; nz := Pz - bQz;
  dist := Sqrt(nx * nx + nz * nz);
  if dist > 1.0e-3 then
  begin
    nx := nx / dist; nz := nz / dist;
  end
  else
  begin
    { stop sits on the centreline — fall back to the road's left normal. }
    nlen := Sqrt(bEx * bEx + bEz * bEz);
    if nlen < 1.0e-6 then Exit;
    nx := -bEz / nlen; nz := bEx / nlen;
    dist := 0;
  end;

  { Sit on the stop's side, at >= MIN_CLEARANCE from the centreline. When the
    node is already clear, place == dist ⇒ model stays exactly on the node. }
  place := dist;
  if place < MIN_CLEARANCE then place := MIN_CLEARANCE;
  Result.X := bQx + nx * place;
  Result.Z := bQz + nz * place;
  Result.Y := NodeP.Y;

  { Face the road: the model's front (+Z) must point from the model toward the
    road, i.e. along -N. Rotation about +Y takes +Z(0,0,1) -> (sinθ,cosθ). }
  Yaw := ArcTan2(-nx, -nz);
end;

{ ---- bus-stop de-duplication: stop_position (on road) vs platform/bus_stop (POI) ---- }

const
  STOP_DEDUP_RADIUS_M = 50.0;   { a stop_position within this of a POI stop is its duplicate }

{ POI side of a bus stop: the physical platform/shelter beside the road. }
function BusStopIsPoiNode(const Tags: TOSMTags): Boolean;
var V: string;
begin
  if Tags.GetLower('highway') = 'bus_stop' then Exit(True);
  if Tags.GetLower('highway') = 'platform' then Exit(True);
  V := Tags.GetLower('public_transport');
  Result := (V = 'platform') or (V = 'station');
end;

{ The "point on the road": public_transport=stop_position that is not itself a POI. }
function BusStopIsRoadPoint(const Tags: TOSMTags): Boolean;
begin
  Result := (Tags.GetLower('public_transport') = 'stop_position')
            and not BusStopIsPoiNode(Tags);
end;

class function TPOIBuilderExt.IsRedundantStopPositionNode(Dataset: TOSMDataset;
  Projection: TLocalProjection; Node: TOSMNode): Boolean;
var
  Other: TOSMNode;
  P, Q: TVector3;
  dx, dz: Single;
begin
  Result := False;
  if (Dataset = nil) or (Projection = nil) or (Node = nil) then Exit;
  if not BusStopIsRoadPoint(Node.Tags) then Exit;
  P := NodePlanePos(Dataset, Node, Projection);   { int-first }
  for Other in Dataset.Nodes.Values do
  begin
    if (Other = nil) or (Other = Node) then Continue;
    if not BusStopIsPoiNode(Other.Tags) then Continue;
    Q := NodePlanePos(Dataset, Other, Projection);   { int-first }
    dx := Q.X - P.X;  dz := Q.Z - P.Z;
    if dx * dx + dz * dz <= STOP_DEDUP_RADIUS_M * STOP_DEDUP_RADIUS_M then
      Exit(True);
  end;
end;

class function TPOIBuilderExt.ComputeStopPlacement(AIdx: TOsmRoadIndex;
  const NodeP: TVector3; out Yaw: Single): TVector3;
const
  MIN_CLEARANCE = 3.0;
  MAX_SEARCH    = 40.0;
var
  bQx, bQz, bEx, bEz: Single;
  Px, Pz, nx, nz, dist, nlen, place: Single;
begin
  Yaw := 0;
  Result := NodeP;
  if AIdx = nil then Exit;
  Px := NodeP.X; Pz := NodeP.Z;
  if not AIdx.NearestVehicularSeg(Px, Pz, MAX_SEARCH,
       bQx, bQz, bEx, bEz) then Exit;

  { дальше — математика 1:1 с медленной версией }
  nx := Px - bQx; nz := Pz - bQz;
  dist := Sqrt(nx * nx + nz * nz);
  if dist > 1.0e-3 then
  begin
    nx := nx / dist; nz := nz / dist;
  end
  else
  begin
    nlen := Sqrt(bEx * bEx + bEz * bEz);
    if nlen < 1.0e-6 then Exit;
    nx := -bEz / nlen; nz := bEx / nlen;
    dist := 0;
  end;

  place := dist;
  if place < MIN_CLEARANCE then place := MIN_CLEARANCE;
  Result.X := bQx + nx * place;
  Result.Z := bQz + nz * place;
  Result.Y := NodeP.Y;
  Yaw := ArcTan2(-nx, -nz);
end;

class function TPOIBuilderExt.IsRedundantStopPositionNode(
  AIdx: TOsmRoadIndex; Dataset: TOSMDataset;
  Projection: TLocalProjection; Node: TOSMNode): Boolean;
var
  P: TVector3;
begin
  Result := False;
  if (Node = nil) or (AIdx = nil) or (AIdx.PoiStopCount = 0) then Exit;
  if not BusStopIsRoadPoint(Node.Tags) then Exit;
  P := NodePlanePos(Dataset, Node, Projection);
  Result := AIdx.HasPoiStopWithin(P.X, P.Z, STOP_DEDUP_RADIUS_M);
end;

class function TPOIBuilderExt.BuildAllInstances(Dataset: TOSMDataset;
  HM: THeightmap; Projection: TLocalProjection;
  Terrain: TTerrainSampler;
  ARoadIdx: TOsmRoadIndex): TPOIInstanceArray;
{ One pass over Dataset.Nodes (classify, project, sample ground) -> flat (Kind, Position) list,
  the source of truth for both BuildAll and the tiled assembler. }
var
  Node: TOSMNode;
  Kind: TPOIKindExt;
  Pos:  TVector3;
  Y:    Single;
  Yaw:  Single;
  N, Cap: Integer;  OwnIdx: Boolean;                 { индекс построен здесь (хост без общего) }
begin
  OwnIdx := False;
  {$IFDEF IAM_LIVE}IamLiveTrack(1102);{$ENDIF}
  Result := nil;
  if (Dataset = nil) or (Projection = nil) then Exit;

  N   := 0;
  Cap := 64;
  SetLength(Result, Cap);

  try
    for Node in Dataset.Nodes.Values do
    begin
    Kind := ClassifyNode(Node.Tags);
    if Kind = pkxNone then Continue;

    { De-dup: a stop_position "point on road" is skipped when a platform/bus_stop
      POI already covers this stop (POI is more precise; avoids doubled shelters).
      Индекс строится лениво один раз — старый путь обходил весь датасет
      на КАЖДУЮ остановку. }
    if Kind = pkxBusStop then
    begin
      if ARoadIdx = nil then
      begin
        { хост без общего индекса (GeomBuilder его строит и передаёт) —
          строим свой один раз }
        ARoadIdx := TOsmRoadIndex.Build(Dataset, Projection);
        OwnIdx := True;
      end;
      if IsRedundantStopPositionNode(ARoadIdx, Dataset, Projection, Node) then
        Continue;
    end;

    Pos := NodePlanePos(Dataset, Node, Projection);   { int-first }
    Yaw := 0;
    if Node.Tags.HasKey('rezvivo:local_photo_object') and Node.Tags.HasKey('direction') then
      Yaw:=-DegToRad(ParseOSMMeters(Node.Tags.Get('direction'))); { geographic east is -X }

    { Bus stops / platforms: move to the roadside and turn to face the road,
      then re-sample the ground at the moved position. }
    if Kind = pkxBusStop then
    begin
      Pos := ComputeStopPlacement(ARoadIdx, Pos, Yaw);
      Y := SampleTerrainYGeo(Terrain, HM, Projection.Unproject(Pos.X, Pos.Z));
    end
    else
      Y := SampleTerrainYGeo(Terrain, HM, Node.Position);
    Pos.Y := Y;

    if N >= Cap then
    begin
      Cap := Cap * 2;
      SetLength(Result, Cap);
    end;
    Result[N].Kind     := Kind;
    Result[N].Position := Pos;
    Result[N].Rotation := Yaw;
    Inc(N);
    end;
  finally
    if OwnIdx then ARoadIdx.Free;   { свой индекс — наш; и на error-путях }
  end;
  SetLength(Result, N);
end;

class function TPOIBuilderExt.BuildTrafficSignalPoleMesh: TMesh;
begin
  Result := TMesh.Create('ts_pole');
  AppendCylinder(Result, Vector3(0, 0, 0), 0.07, 3.5, 6);
end;

class function TPOIBuilderExt.BuildTrafficSignalBoxSidesMeshXZ(
  AXU0, AXU1, AZU0, AZU1: Single): TMesh;
begin
  { The 4 side faces of the head (0.30 x 0.80 x 0.30 at Y=3.7). The +/-Z pair
    maps atlas cell [AZU0..AZU1] (the primary signal), the +/-X pair maps
    [AXU0..AXU1] (the perpendicular signal). No TextureTransform. }
  Result := TMesh.Create('ts_box_sides');
  AppendBoxSidesXZ(Result, Vector3(0, 3.7, 0), 0.30, 0.80, 0.30,
    AXU0, AXU1, AZU0, AZU1);
end;

class function TPOIBuilderExt.BuildTrafficSignalBoxCapsMesh: TMesh;
begin
  { Top + bottom caps only — plain material, no signal texture on top. }
  Result := TMesh.Create('ts_box_caps');
  AppendBox(Result, Vector3(0, 3.7, 0), 0.30, 0.80, 0.30, False, True);
end;

class function TPOIBuilderExt.BuildKindMesh(Kind: TPOIKindExt): TMesh;
{ Geometry for one kind at the origin. Static batches bake its placement;
  the diagnostic instance path keeps a shared shape and transforms. }
const
  ZERO: TVector3 = (X: 0; Y: 0; Z: 0);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1103);{$ENDIF}
  Result := nil;
  if Kind = pkxNone then Exit;

  Result := TMesh.Create('poi_template');
  try
    case Kind of
      pkxTrafficSignal:  TPOIBuilder.AppendTrafficSignal(Result, ZERO);
      pkxHydrant:        TPOIBuilder.AppendHydrant(Result, ZERO);
      pkxTower:          TPOIBuilder.AppendTower(Result, ZERO);
      pkxFountain:       TPOIBuilder.AppendFountain(Result, ZERO);
      pkxPole:           TPOIBuilder.AppendPole(Result, ZERO, 6.0);
      pkxMonument:       AppendMonument(Result, ZERO);
      pkxBusStop:        AppendBusStop(Result, ZERO);
      pkxBench:          AppendBench(Result, ZERO);
      pkxPlaceOfWorship: AppendPlaceOfWorship(Result, ZERO);
      pkxInfoBoard:      AppendInfoBoard(Result, ZERO);
      pkxBin:            AppendBin(Result, ZERO);
    end;
  except
    Result.Free;
    raise;
  end;
end;

class procedure TPOIBuilderExt.AppendInstance(Target, Template: TMesh;
  const Position: TVector3; Yaw: Single);
var
  Vertices: TMeshVertexArray;
  Indices: TMeshIndexArray;
  V: TMeshVertex;
  I, Base: Integer;
  S, C, X, Z: Single;
begin
  if (Template = nil) or (Template.TriangleCount = 0) then Exit;
  Base := Target.VertexCount;
  Vertices := Template.Vertices;
  Indices := Template.Indices;
  SinCos(Yaw, S, C);
  for I := 0 to High(Vertices) do
  begin
    V := Vertices[I];
    X := V.Position.X; Z := V.Position.Z;
    V.Position := Vector3(C * X + S * Z + Position.X,
      V.Position.Y + Position.Y, -S * X + C * Z + Position.Z);
    X := V.Normal.X; Z := V.Normal.Z;
    V.Normal := Vector3(C * X + S * Z, V.Normal.Y, -S * X + C * Z);
    Target.AddVertex(V);
  end;
  for I := 0 to Template.TriangleCount - 1 do
    Target.AddTriangle(Base + Indices[I * 3],
      Base + Indices[I * 3 + 1], Base + Indices[I * 3 + 2]);
end;

class function TPOIBuilderExt.BuildAll(Dataset: TOSMDataset; HM: THeightmap;
  Projection: TLocalProjection;
  Terrain: TTerrainSampler): TMesh;
var
  Instances: TPOIInstanceArray;
  I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1104);{$ENDIF}
  Result := TMesh.Create('poi_ext');
  if (Dataset = nil) or (Projection = nil) then Exit;

  Instances := BuildAllInstances(Dataset, HM, Projection, Terrain);
  for I := 0 to High(Instances) do
    case Instances[I].Kind of
      pkxTrafficSignal:  TPOIBuilder.AppendTrafficSignal(Result, Instances[I].Position);
      pkxHydrant:        TPOIBuilder.AppendHydrant(Result, Instances[I].Position);
      pkxTower:          TPOIBuilder.AppendTower(Result, Instances[I].Position);
      pkxFountain:       TPOIBuilder.AppendFountain(Result, Instances[I].Position);
      pkxPole:           TPOIBuilder.AppendPole(Result, Instances[I].Position, 6.0);
      pkxMonument:       AppendMonument(Result, Instances[I].Position);
      pkxBusStop:        AppendBusStop(Result, Instances[I].Position);
      pkxBench:          AppendBench(Result, Instances[I].Position);
      pkxPlaceOfWorship: AppendPlaceOfWorship(Result, Instances[I].Position);
      pkxInfoBoard:      AppendInfoBoard(Result, Instances[I].Position);
      pkxBin:            AppendBin(Result, Instances[I].Position);
    end;
end;

type
  TLabelKind = (lblNone, lblHwyPrimary, lblHwySecondary, lblHwyTertiary,
                lblHwyResidential, lblBuilding);

  TLabelCandidate = record
    Kind:  TLabelKind;
    Pos:   TVector3;
    Text:  string;
    Size:  Single;            { font height in metres }
  end;

const
  { Font size in METRES (3D object). Streets.gl uses 3-5 m for street
    labels: readable from 50-100 m, fading to thin strips at km range. }
  LABEL_SIZE_M: array[TLabelKind] of Single = (
    0,    { lblNone }
    5,    { lblHwyPrimary }
    4,    { lblHwySecondary }
    3.5,  { lblHwyTertiary }
    3,    { lblHwyResidential }
    4     { lblBuilding }
  );

  { Higher = more important. Used to cap total count. }
  LABEL_PRIORITY: array[TLabelKind] of Integer = (
    0, 100, 80, 60, 30, 50
  );

function ClassifyHighway(const Tags: TOSMTags): TLabelKind;
var V: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(290);{$ENDIF}
  Result := lblNone;
  V := Tags.GetLower('highway');
  if V = 'primary'     then Exit(lblHwyPrimary);
  if V = 'secondary'   then Exit(lblHwySecondary);
  if V = 'tertiary'    then Exit(lblHwyTertiary);
  if (V = 'residential') or (V = 'unclassified') or (V = 'living_street') then
    Exit(lblHwyResidential);
end;

function PolygonAreaXZ(Way: TOSMWay; Dataset: TOSMDataset;
  Projection: TLocalProjection): Single;
var
  N, I: Integer;
  V: array of TVector3;
  Node: TOSMNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(291);{$ENDIF}
  Result := 0;
  N := Length(Way.NodeRefs) - 1;
  if N < 3 then Exit;
  SetLength(V, N);
  for I := 0 to N - 1 do
  begin
    Node := Dataset.FindNode(Way.NodeRefs[I]);
    if Node = nil then Exit;
    V[I] := NodePlanePos(Dataset, Node, Projection);   { int-first }
  end;
  Result := Abs(PolygonSignedAreaXZ(V));
end;

{ Mid-point of a way by arc length. }
function HighwayMidpoint(Way: TOSMWay; Dataset: TOSMDataset;
  HM: THeightmap; Projection: TLocalProjection;
  Terrain: TTerrainSampler;
  out Pos: TVector3): Boolean;
var
  N, I: Integer;
  Node: TOSMNode;
  XZ: array of TVector3;
  Lengths: array of Single;
  D, Total, HalfTotal, Acc, T: Single;
  MidIdx: Integer;
  Y: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(292);{$ENDIF}
  Result := False;
  N := Length(Way.NodeRefs);
  if N < 2 then Exit;
  SetLength(XZ, N);
  for I := 0 to N - 1 do
  begin
    Node := Dataset.FindNode(Way.NodeRefs[I]);
    if Node = nil then Exit;
    XZ[I] := NodePlanePos(Dataset, Node, Projection);   { int-first }
  end;

  SetLength(Lengths, N - 1);
  Total := 0;
  for I := 0 to N - 2 do
  begin
    D := Sqrt(Sqr(XZ[I+1].X - XZ[I].X) + Sqr(XZ[I+1].Z - XZ[I].Z));
    Lengths[I] := D;
    Total := Total + D;
  end;
  if Total < 1.0 then Exit;     { too short to label }

  HalfTotal := Total * 0.5;
  Acc := 0;
  MidIdx := 0;
  for I := 0 to N - 2 do
  begin
    if Acc + Lengths[I] >= HalfTotal then
    begin
      MidIdx := I;
      Break;
    end;
    Acc := Acc + Lengths[I];
  end;

  if Lengths[MidIdx] > 1e-9 then
    T := (HalfTotal - Acc) / Lengths[MidIdx]
  else
    T := 0;   { нулевой сегмент: берём его начало }
  if T < 0 then T := 0;
  if T > 1 then T := 1;
  Pos.X := XZ[MidIdx].X + T * (XZ[MidIdx+1].X - XZ[MidIdx].X);
  Pos.Z := XZ[MidIdx].Z + T * (XZ[MidIdx+1].Z - XZ[MidIdx].Z);

  { Approximate Y from the nearest node — projecting the midpoint exactly
    would be slightly more accurate but cost more. }
  Node := Dataset.FindNode(Way.NodeRefs[MidIdx]);
  if Node = nil then Exit;
  Y := SampleTerrainYGeo(Terrain, HM, Node.Position) + LABEL_LIFT_M;
  Pos.Y := Y;
  Result := True;
end;

procedure AddLabelBillboard(Group: TGroupNode; const C: TLabelCandidate);
{ Billboard has no Translation — wrap in TTransformNode for positioning.
  AxisOfRotation=(0,1,0): rotates around Y only so text stays vertical when
  the camera tilts down. (0,0,0) would lay it flat. }
var
  Tr:    TTransformNode;
  Bb:    TBillboardNode;
  Shape: TShapeNode;
  Text:  TTextNode;
  Style: TFontStyleNode;
  Mat:   TMaterialNode;
  App:   TAppearanceNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(293);{$ENDIF}
  Tr := TTransformNode.Create;
  Tr.Translation := C.Pos;

  Bb := TBillboardNode.Create;
  Bb.AxisOfRotation := Vector3(0, 1, 0);

  Style := TFontStyleNode.Create;
  Style.Family := ffSans;
  Style.Bold := True;
  Style.Justify := fjMiddle;
  Style.JustifyMinor := fjMiddle;
  Style.Size := C.Size;

  Text := TTextNode.Create;
  Text.FontStyle := Style;
  Text.FdString.Send([C.Text]);

  Mat := TMaterialNode.Create;
  Mat.DiffuseColor  := Vector3(1, 1, 1);
  Mat.EmissiveColor := Vector3(0.95, 0.95, 0.85);   { warm off-white }
  Mat.AmbientIntensity := 0.0;     { lighting-independent }

  App := TAppearanceNode.Create;
  App.Material := Mat;

  Shape := TShapeNode.Create;
  Shape.Geometry := Text;
  Shape.Appearance := App;

  Bb.AddChildren(Shape);
  Tr.AddChildren(Bb);
  Group.AddChildren(Tr);
end;

class function TLabelBuilder.BuildAll(Dataset: TOSMDataset; HM: THeightmap;
  Projection: TLocalProjection;
  Terrain: TTerrainSampler): TGroupNode;
var
  Cands: array of TLabelCandidate;
  Count, I, J: Integer;
  Way: TOSMWay;
  Kind: TLabelKind;
  WayName: string;
  MidPos: TVector3;
  Area: Single;
  CenterLatLon: TLatLon;
  Node: TOSMNode;
  CenterY: Single;
  Tmp: TLabelCandidate;
  PriorityI, PriorityJ: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1105);{$ENDIF}
  Result := nil;
  Count := 0;
  SetLength(Cands, 256);

  { Highway labels. }
  for Way in Dataset.Ways.Values do
  begin
    Kind := ClassifyHighway(Way.Tags);
    if Kind = lblNone then Continue;
    WayName := Trim(Way.Tags.Get('name'));
    if WayName = '' then Continue;
    if not HighwayMidpoint(Way, Dataset, HM, Projection, Terrain, MidPos) then
      Continue;

    if Count >= Length(Cands) then SetLength(Cands, Length(Cands) * 2);
    Cands[Count].Kind := Kind;
    Cands[Count].Pos  := MidPos;
    Cands[Count].Text := WayName;
    Cands[Count].Size := LABEL_SIZE_M[Kind];
    Inc(Count);
  end;

  { Building labels. }
  for Way in Dataset.Ways.Values do
  begin
    if not Way.Tags.HasKey('building') then Continue;
    if not Way.IsClosed then Continue;
    WayName := Trim(Way.Tags.Get('name'));
    if WayName = '' then Continue;

    Area := PolygonAreaXZ(Way, Dataset, Projection);
    if Area < MIN_BUILDING_LABEL_AREA then Continue;

    { Rough centre — midpoint of first node and middle-of-array node. }
    if Length(Way.NodeRefs) < 2 then Continue;
    Node := Dataset.FindNode(Way.NodeRefs[0]);
    if Node = nil then Continue;
    CenterLatLon := Node.Position;
    Node := Dataset.FindNode(Way.NodeRefs[Length(Way.NodeRefs) div 2]);
    if Node <> nil then
    begin
      CenterLatLon.Lat := (CenterLatLon.Lat + Node.Position.Lat) * 0.5;
      CenterLatLon.Lon := (CenterLatLon.Lon + Node.Position.Lon) * 0.5;
    end;
    MidPos := Projection.Project(CenterLatLon, 0);
    CenterY := SampleTerrainYGeo(Terrain, HM, CenterLatLon)
               + LABEL_BUILDING_LIFT_M;
    MidPos.Y := CenterY;

    if Count >= Length(Cands) then SetLength(Cands, Length(Cands) * 2);
    Cands[Count].Kind := lblBuilding;
    Cands[Count].Pos  := MidPos;
    Cands[Count].Text := WayName;
    Cands[Count].Size := LABEL_SIZE_M[lblBuilding];
    Inc(Count);
  end;

  if Count = 0 then Exit;
  SetLength(Cands, Count);

  { Cap to MAX_LABELS via insertion sort by priority then truncate.
    OK for Count < 1000. }
  if Count > MAX_LABELS then
  begin
    for I := 1 to Count - 1 do
    begin
      Tmp := Cands[I];
      PriorityI := LABEL_PRIORITY[Tmp.Kind];
      J := I - 1;
      while (J >= 0) do
      begin
        PriorityJ := LABEL_PRIORITY[Cands[J].Kind];
        if PriorityJ >= PriorityI then Break;
        Cands[J + 1] := Cands[J];
        Dec(J);
      end;
      Cands[J + 1] := Tmp;
    end;
    Count := MAX_LABELS;
  end;

  Result := TGroupNode.Create;
  try
    for I := 0 to Count - 1 do
      AddLabelBillboard(Result, Cands[I]);
  except
    Result.Free;
    raise;
  end;
end;

end.
