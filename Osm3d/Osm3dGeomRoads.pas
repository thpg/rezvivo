unit Osm3dGeomRoads;

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$codepage UTF8}
{ Suppress FPC false-positives on dynamic arrays / managed types that
FPC reports as 'not initialized' — these are zeroed by the runtime. }
{$WARN 5091 OFF}
{$modeswitch advancedrecords}

interface

uses
  Classes,
  SysUtils,
  Math,
  CastleVectors,
  Osm3dOsmData, Osm3dRoadSurface,
  Osm3dOsmTagUtils, Osm3dRoadWidth,
  Osm3dGeoMath,
  Osm3dHeightmap,
  Osm3dGeomTerrain,
  Osm3dGeomRoadJoints,
  Osm3dGeomMesh,
  Generics.Collections,
  X3DNodes,
  Osm3dGeomUtils
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
,
  Osm3dCarveGround;

const

  { Косинус порога разворота «туда-обратно» внутри полилинии (~170°):
    круче — полилиния режется на две ленты (см. AppendWayRibbon). }
  ROAD_SPLIT_REVERSAL_COS = -0.985;
  { Квадрат порога сегмента-«перелёта» (32 км): битый узел OSM с
    координатами за десятки/сотни км от трассы — полилиния режется на
    месте прыжка, каждая связная часть рисуется своей лентой. Иначе лента
    превращается в гигантский треугольник через всю карту, а её int-кольцо
    тащит в карв точки в сотнях км (краш/ханги нодера, 21.07.26 Москва). }
  ROAD_RUNAWAY_SEG_M2 = 32768.0 * 32768.0;
  { Vertical priority step between road classes — 5 mm per level.
    Lower-priority road types get lower lift and are overdrawn by
    higher-priority types when their ribbons overlap at intersections.
    Mirrors streets-gl ZIndexMap ordering (DirtRoadway=13 … AsphaltRoadway=20). }
  ROAD_LIFT_STEP = 0.005;

  { UV scale along the road (metres per V tile), per material/kind (streets-gl uvScaleY). }
  ROAD_UV_SCALE_Y_ASPHALT    = 12.0;
  ROAD_UV_SCALE_Y_CONCRETE   = 12.0;
  ROAD_UV_SCALE_Y_COBBLE     = 6.0;
  ROAD_UV_SCALE_Y_WOOD       = 4.0;
  ROAD_UV_SCALE_Y_FOOTWAY    = 10.0;
  ROAD_UV_SCALE_Y_CYCLEWAY   = 8.0;
  ROAD_UV_SCALE_Y_RAILWAY    = 4.0;
  ROAD_UV_SCALE_Y_DIRT       = 6.0;
  ROAD_UV_SCALE_Y_SAND       = 6.0;


type
  { Road surface material (streets-gl pathMaterial). Drives atlas-slot selection at composite-append. }
  TPathMaterial = (
    pmNone,
    pmAsphalt,
    pmConcrete,
    pmCobblestone,
    pmWood,
    pmDirt,
    pmSand
  );

  { Coarse road class — kept ONLY for ZIndex priority and per-class
    output mesh bucketing. Width and material come from TRoadParams. }
  TRoadKind = (
    rkNone,
    rkMajor,        { motorway/trunk/primary + link variants }
    rkSecondary,    { secondary/tertiary + link variants }
    rkMinor,        { residential/unclassified/living_street/road }
    rkService,      { service/busway/raceway }
    rkFootway,      { footway/pedestrian/steps/corridor; path+paved }
    rkCycleway,     { cycleway }
    rkRailway,      { railway=rail/light_rail/tram/subway/... }
    { Unpaved paths — separate kind so ZIndex/lift puts them under
      asphalt at intersections. Material is forced to dirt/sand. }
    rkDirtPath,
    rkSandPath
  );

  { Per-way road params from ParseRoadParams. Kind = coarse class (ZIndex + bucket); Material =
    surface; IsMarked = lane markings visible; Width = final metres (width=* / lanes / default /
    class defaults); LanesForward/Backward = lane counts; UVMinX/UVMaxX = horizontal slice of the
    multi-lane atlas cell this road samples (getRoadUV) so markings don't stretch with width — set
    to 0..1 for non-roadway kinds. }
  TRoadParams = record
    Kind:          TRoadKind;
    Material:      TPathMaterial;
    IsMarked:      Boolean;
    Width:         Single;
    Layout:        TRoadLaneLayout;
    LanesForward:  Integer;
    LanesBackward: Integer;
    UVMinX:        Single;
    UVMaxX:        Single;
  end;

  TRoadMeshes = record
    Major:     TMesh;
    Secondary: TMesh;
    Minor:     TMesh;
    Service:   TMesh;
    Footway:   TMesh;
    Cycleway:  TMesh;
    Railway:   TMesh;
    DirtPath:  TMesh;
    SandPath:  TMesh;
    { int-first вход карва: контур ленты кольцом от источника (джойнты уже
      в Edges), UV-квады (Y=0) — источник аналитической UV для bary-lookup.
      Сам меш ленты на int-пути не строится; перекрёстки покрывает winding
      перекрывающихся колец одного материала. }
    IntRings:  array[TRoadKind] of TLatRingBag;
    UVMesh:    array[TRoadKind] of TMesh;
    { No shoulder mesh: the sandy strip beside roads is produced in the ground composite shader
      from a road-distance field, not as separate geometry. }
  end;

  { Road centerline segment: one node-to-node piece in local XZ + width + way id. BuildAll emits
    these alongside the ribbons; the assembler tiles them into a lightweight layer the route snapper
    reads back. Railways and junk-width ways are skipped (a route never snaps to them). Bridge ways
    ARE emitted (IsBridge=True) so the snapper's road field has no hole over a span — but they exist
    ONLY for that layer: leveling and the proximity map skip them (ground under a deck stays
    untouched), and the ribbon/carve path never sees them at all. }
  { Отсортированные id узлов-развязок (степень прохождения дорожных way
    по узлу >= 3: пересечения и Т-контакты; продолжения end-to-end и изломы
    одиночной дороги — НЕ развязки). Скругление в этих узлах подавляется. }
  TRoadJunctionIdArray = array of Int64;

  TRoadCenterlineSeg = record
    X0, Z0: Single;
    X1, Z1: Single;
    Width:  Single;
    WayId:  Int64;
    { Мостовой сегмент (OsmWayIsBridge/tunnel): существует ТОЛЬКО ради
      снап-слоя маршрута. LevelRoadsInComposite / BuildRoadProximityMap
      такие сегменты пропускают. Флаг копируется в TTileRoadSeg + сайдкар
      O3RS v2 (BRIDGE_SNAP), чтобы снаппер предпочитал настил дороге под
      пролётом. }
    IsBridge: Boolean;
    Surface: TRoadSurfaceProfile;
  end;
  TRoadCenterlineSegArray = array of TRoadCenterlineSeg;

  { Подходной съезд туннеля (Osm3dGeomTunnels): синтетический сегмент с
    ЯВНЫМИ высотами концов — LevelRoadsInComposite тянет по нему выемку
    (траншею) от рельефа до глубины забоя, чтобы полотно ныряло под
    композит ДО портала, а не за ним. В fit-fade/тайловый снап не идёт —
    только в выравнивание композита отдельным параметром. }
  TTunnelApproachSeg = record
    Seg:    TRoadCenterlineSeg;
    H0, H1: Single;   { высоты оси на концах (H0 у X0/Z0, H1 у X1/Z1) }
  end;
  TTunnelApproachSegArray = array of TTunnelApproachSeg;

  TRoadBuilder = class
  public
    { Streets-gl-style classification — returns complete params for a
      single OSM way's tags. Width and material reflect the actual OSM
      data, not just the highway class. }
    class function ParseRoadParams(const Tags: TOSMTags): TRoadParams;

    { Delegate to ParseRoadParams; referenced by name from other modules (road-mask, road-graph,
      shadow builder, ...). ClassWidth returns the final width incl. all lanes/width parsing. }
    class function ClassifyHighway(const Tags: TOSMTags): TRoadKind;
    class function ClassWidth(const Tags: TOSMTags): Single;
    class function ClassLift(Kind: TRoadKind): Single;
    class function ClassUVScaleY(const Params: TRoadParams): Single;

    class procedure AppendWayRibbon(Way: TOSMWay; Dataset: TOSMDataset;
      HM: THeightmap; Projection: TLocalProjection;
      Width, Lift, UVScaleY: Single;
      UVMinX, UVMaxX: Single;
      Target: TMesh;
      Sampler: TTerrainSampler = nil;
      Progress: PClipperProgress = nil;
      ABag: PLatRingBag = nil;
      AUVMesh: TMesh = nil;
      const AJunctionIds: TRoadJunctionIdArray = nil;
      ARawForCarve: Boolean = False;
      const AChainRefs: TRoadJunctionIdArray = nil);

    class function BuildAll(Dataset: TOSMDataset; HM: THeightmap;
      Projection: TLocalProjection;
      out ASegs: TRoadCenterlineSegArray;
      Sampler: TTerrainSampler = nil;
      LogProc: TLogProc = nil;
      ACarveRaw: Boolean = False;
      AIntRings: Boolean = False): TRoadMeshes;
  end;


{ True when a way carries a bridge=* tag with a truthy value (anything other
  than empty / no / false / 0). Single source of truth shared by:
    • TRoadBuilder.BuildAll — a bridge ribbon is NOT emitted into the road
      meshes, so it is never carved into the ground composite and never
      leveled; the deck is built separately (Osm3dGeomBridges) and the
      polygons UNDER the bridge stay un-cut by the road.
    • Osm3dRoadDistField — no sandy halo is rasterised under a bridge.
    • Osm3dGeomBridges — selects the ways it turns into decks + parapets. }
function OsmWayIsBridge(Tags: TOSMTags): Boolean;

{ True when a way carries a tunnel=* tag with a truthy value (anything other
  than empty / no / false / 0). Mirrors OsmWayIsBridge:
    • TRoadBuilder.BuildAll — a tunnel ribbon is NOT emitted into the road
      meshes (like a bridge one): never carved into the ground composite and
      never leveled — the hillside above the bore stays un-cut; the tube
      (lower deck + concrete shell) is built separately (Osm3dGeomTunnels).
    • Osm3dRoadDistField — no sandy halo is rasterised over a tunnel.
    • Osm3dGeomTunnels — selects the ways it turns into tubes. }
function OsmWayIsTunnel(Tags: TOSMTags): Boolean;

type
  TRoadDescriptor = record
    Name:        string;
    TexturePath: string;       { '' = no texture → fallback to flat colour }
    NormalPath:  string;       { '' = no normal map }
  end;

  TRoadTextures = class
  public
    class function GetDescriptor(Kind: TRoadKind): TRoadDescriptor;

    { Create a diffuse texture for a road kind. Returns nil if
      the path is empty or the PNG is not found on disk. The caller
      is responsible for freeing it or attaching it to a Shape. }
    class function CreateForKind(Kind: TRoadKind): TImageTextureNode;
    class function CreateNormalForKind(Kind: TRoadKind): TImageTextureNode;
  end;

const
  ROAD_TEX_DIR = SURFACES_TEX_DIR;   { = SURFACES_TEX_DIR (single source of truth) }

  ROAD_DESCRIPTORS: array[TRoadKind] of TRoadDescriptor = (
    { rkNone     } (Name:'none';
                    TexturePath:'';
                    NormalPath:''),

                    { rkMajor    } (Name:'major';
                                    TexturePath:'';
                                    NormalPath: ''),

                    { rkSecondary} (Name:'secondary';
                                    TexturePath:'';
                                    NormalPath: ''),

    { rkMinor    } (Name:'minor';
                    TexturePath:'';
                    NormalPath: ''),

    { rkService  } (Name:'service';
                    TexturePath:'';
                    NormalPath: ''),

    { rkFootway  } (Name:'footway';
                    TexturePath:ROAD_TEX_DIR+'pavement_diffuse.png';
                    NormalPath: ROAD_TEX_DIR+'pavement_normal.png'),

    { rkCycleway } (Name:'cycleway';
                    TexturePath:'';
                    NormalPath: ''),

    { rkRailway  } (Name:'railway';
                    TexturePath:'';
                    NormalPath:''),

    { rkDirtPath — unpaved track / path / footway. Uses dirt_road
      diffuse with alpha edges so the ribbon fades into surrounding
      terrain (streets-gl DirtRoad). }
    { rkDirtPath } (Name:'dirt_path';
                    TexturePath:ROAD_TEX_DIR+'dirt_road_diffuse.png';
                    NormalPath: ROAD_TEX_DIR+'dirt_road_normal.png'),

    { rkSandPath — desert-style sand path; falls back to the dirt
      atlas slot when no dedicated sand_road PNG is present. }
    { rkSandPath } (Name:'sand_path';
                    TexturePath:ROAD_TEX_DIR+'sand_road_diffuse.png';
                    NormalPath: ROAD_TEX_DIR+'sand_road_normal.png')
  );

implementation

{ Streets-gl materialTable from getPathParamsFromTags.ts:3-21. }
function ParseSurfaceMaterial(const Surface: string): TPathMaterial;
var S: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(305);{$ENDIF}
  S := LowerCase(Surface);
  if (S = 'asphalt') or (S = 'paved') then Exit(pmAsphalt);
  if (S = 'concrete') or (S = 'concrete:plates') or
     (S = 'concrete:lanes') then Exit(pmConcrete);
  if (S = 'paving_stones') or (S = 'sett') or
     (S = 'cobblestone')   or (S = 'pebblestone') then Exit(pmCobblestone);
  if S = 'wood' then Exit(pmWood);
  if S = 'sand' then Exit(pmSand);
  if (S = 'unpaved')   or (S = 'ground')      or (S = 'dirt') or
     (S = 'gravel')    or (S = 'fine_gravel') or
     (S = 'compacted') or (S = 'grass')       or
     (S = 'earth') then Exit(pmDirt);
  Result := pmNone;
end;

{ Streets-gl highwayTable entry as a function with case. }
procedure HighwayDefaults(const Highway: string;
  out HighwayKnown: Boolean;
  out Kind: TRoadKind;
  out DefaultMarked: Boolean;
  out DefaultMaterial: TPathMaterial);
var V: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(306);{$ENDIF}
  HighwayKnown    := True;
  Kind            := rkNone;
  DefaultMarked   := True;
  DefaultMaterial := pmAsphalt;

  V := LowerCase(Highway);

  if (V = 'motorway') or (V = 'trunk') or (V = 'primary') then begin
    Kind := rkMajor; Exit;
  end;
  if (V = 'motorway_link') or (V = 'trunk_link') or (V = 'primary_link') then begin
    Kind := rkMajor; Exit;
  end;
  if (V = 'secondary') or (V = 'tertiary') then begin
    Kind := rkSecondary; Exit;
  end;
  if (V = 'secondary_link') or (V = 'tertiary_link') then begin
    Kind := rkSecondary; Exit;
  end;
  if (V = 'residential') or (V = 'unclassified') or (V = 'road') then begin
    Kind := rkMinor; Exit;
  end;
  if V = 'living_street' then begin
    Kind := rkMinor; DefaultMarked := False; Exit;
  end;
  if V = 'service' then begin
    Kind := rkService; DefaultMarked := False; Exit;
  end;
  if V = 'busway' then begin
    Kind := rkService; Exit;
  end;
  if V = 'raceway' then begin
    Kind := rkService; DefaultMarked := False; Exit;
  end;
  if V = 'track' then begin
    Kind := rkDirtPath; DefaultMarked := False; DefaultMaterial := pmDirt; Exit;
  end;
  if V = 'cycleway' then begin
    Kind := rkCycleway; DefaultMaterial := pmDirt; Exit;
  end;
  if (V = 'footway') or (V = 'steps') or (V = 'corridor') then begin
    Kind := rkFootway; DefaultMaterial := pmDirt; Exit;
  end;
  if V = 'pedestrian' then begin
    Kind := rkFootway; DefaultMaterial := pmDirt; Exit;
  end;
  if (V = 'path') or (V = 'bridleway') then begin
    Kind := rkFootway; DefaultMaterial := pmDirt; Exit;
  end;

  HighwayKnown := False;
end;

{ getRoadUV: the roadway atlas cell is a multi-lane sheet (double-yellow centre at u=0.5); we
  sample only the slice matching this road's lane count, so lane markings keep constant pixel
  width and the centre line lands on the centreline. LANE_MARK_WIDTH insets to avoid bilinear
  bleed at the edges. }
procedure GetRoadUV(LanesForward, LanesBackward: Integer;
  out UVMinX, UVMaxX: Single);
const
  TEX_LANES        = 4;   { lanes across the full texture (2 fwd + 2 bwd), per the authored sheet }
  LANE_WIDTH       = 1.0 / TEX_LANES;
  LANE_MARK_WIDTH  = LANE_WIDTH * 0.05;
var
  Fwd, Bwd: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(310);{$ENDIF}
  Fwd := LanesForward;
  Bwd := LanesBackward;
  { Clamp to lanes-per-SIDE (= TEX_LANES div 2) so the UV slice can never run
    off the cell edge into a neighbour material, even for many-laned ways. }
  if Fwd > TEX_LANES div 2 then Fwd := TEX_LANES div 2;
  if Bwd > TEX_LANES div 2 then Bwd := TEX_LANES div 2;
  if Fwd < 0 then Fwd := 0;
  if Bwd < 0 then Bwd := 0;

  { Forward lanes left of u=0.5, backward right (U increases across the road right kerb -> left,
    matching the InTri UV emission in EmitRibbonSegmentToTerrain). }
  UVMinX := -Fwd * LANE_WIDTH + 0.5 + LANE_MARK_WIDTH;
  UVMaxX :=  Bwd * LANE_WIDTH + 0.5 - LANE_MARK_WIDTH;
end;

class function TRoadBuilder.ParseRoadParams(
  const Tags: TOSMTags): TRoadParams;
var
  RailwayTag, HighwayTag, SurfaceTag: string;
  HighwayKnown: Boolean;
  DefMarked:   Boolean;
  DefMaterial: TPathMaterial;
  SurfaceMat:  TPathMaterial;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1106);{$ENDIF}
  Result := Default(TRoadParams);
  Result.Kind          := rkNone;
  Result.Material      := pmNone;
  Result.IsMarked      := False;
  Result.Width         := 0;
  Result.LanesForward  := 0;
  Result.LanesBackward := 0;
  { UV range default = full atlas cell — used for non-asphalt-roadway
    classes (footway / cycleway / dirt / sand / railway) where the
    texture is a generic tile, not a multi-lane sheet. Overwritten
    below for asphalt/concrete/cobblestone/wood roadways via GetRoadUV. }
  Result.UVMinX        := 0.0;
  Result.UVMaxX        := 1.0;

  { Railway short-circuit — never carries highway-style lane counts. }
  RailwayTag := Tags.GetLower('railway');
  if (RailwayTag = 'rail')     or (RailwayTag = 'light_rail') or
     (RailwayTag = 'tram')     or (RailwayTag = 'subway')     or
     (RailwayTag = 'narrow_gauge') or (RailwayTag = 'monorail') then
  begin
    Result.Kind          := rkRailway;
    Result.Material      := pmNone;
    Result.IsMarked      := False;
    Result.Width         := 4.2;
    Result.LanesForward  := 1;
    Result.LanesBackward := 0;
    Exit;
  end;

  HighwayTag := Tags.GetLower('highway');
  if HighwayTag = '' then Exit;

  HighwayDefaults(HighwayTag, HighwayKnown, Result.Kind,
                  DefMarked, DefMaterial);
  if not HighwayKnown then
  begin
    Result.Kind := rkNone;
    Exit;
  end;

  { Surface tag override — streets-gl getPathParamsFromTags.ts:153.
    materialTable[tags.surface] ?? highwayParams.defaultMaterial — surface
    wins if recognised. }
  SurfaceTag := Tags.GetLower('surface');
  SurfaceMat := ParseSurfaceMaterial(SurfaceTag);
  if SurfaceMat <> pmNone then
    Result.Material := SurfaceMat
  else
    Result.Material := DefMaterial;

  { Highway=path with surface=asphalt/concrete: keep rkFootway but
    promote material to pavement so it renders smooth.
    Highway=path/footway/cycleway with surface=sand: re-route to
    rkSandPath so ZIndex stacks correctly. }
  if (Result.Kind = rkFootway) and (Result.Material = pmSand) then
    Result.Kind := rkSandPath;

  { Track and similar unpaved highways: align bucket with material. }
  if Result.Kind = rkDirtPath then
  begin
    if Result.Material = pmSand then Result.Kind := rkSandPath
    else if Result.Material in [pmNone, pmDirt] then
      Result.Material := pmDirt
    else
      { Surface promotion: highway=track surface=asphalt → keep dirt
        bucket for ZIndex but show material as asphalt? streets-gl
        does this — defaultMaterial is dirt but surface override wins.
        For consistency with streets-gl ZIndexMap, we promote bucket
        to Service so asphalt-on-track sits at AsphaltRoadway height. }
      Result.Kind := rkService;
  end
  else if (Result.Kind in [rkMajor, rkSecondary, rkMinor, rkService])
       and (Result.Material in [pmDirt, pmSand]) then
  begin
    if Result.Material = pmSand then Result.Kind := rkSandPath
    else Result.Kind := rkDirtPath;
  end;

  Result.Width := ResolveRoadWidth(Tags, Result.LanesForward,
    Result.LanesBackward, Result.Layout);
  Result.IsMarked := DefMarked and (Result.Material = pmAsphalt) and
    (Result.Kind in [rkMajor, rkSecondary, rkMinor, rkService]);

  { Streets-gl getRoadUV — pick the horizontal slice of the road atlas
    cell that corresponds to this road's lane count. Only applies to
    asphalt-style ROADWAYS (major / secondary / minor / service) whose
    atlas cell is authored as a 16-lane sheet. For dirt / sand / wood /
    footway / cycleway / railway the cell is a generic tile, so we
    leave the default UVMinX..UVMaxX = 0..1 set at the top. }
  if (Result.Kind in [rkMajor, rkSecondary, rkMinor, rkService])
     and (Result.Material in [pmAsphalt, pmConcrete, pmCobblestone]) then
    GetRoadUV(Result.LanesForward, Result.LanesBackward,
              Result.UVMinX, Result.UVMaxX);
end;

class function TRoadBuilder.ClassifyHighway(
  const Tags: TOSMTags): TRoadKind;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1107);{$ENDIF}
  Result := ParseRoadParams(Tags).Kind;
end;

class function TRoadBuilder.ClassWidth(const Tags: TOSMTags): Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1108);{$ENDIF}
  Result := ParseRoadParams(Tags).Width;
end;

class function TRoadBuilder.ClassLift(Kind: TRoadKind): Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1109);{$ENDIF}
  case Kind of
    rkRailway:   Result := RAILWAY_LIFT_M;
    rkDirtPath:  Result := ROAD_LIFT_M;                       { level 0 }
    rkSandPath:  Result := ROAD_LIFT_M + ROAD_LIFT_STEP;      { 1 }
    rkFootway:   Result := ROAD_LIFT_M + ROAD_LIFT_STEP * 2;  { 2 }
    rkCycleway:  Result := ROAD_LIFT_M + ROAD_LIFT_STEP * 3;  { 3 }
    rkService:   Result := ROAD_LIFT_M + ROAD_LIFT_STEP * 4;  { 4 }
    rkMinor:     Result := ROAD_LIFT_M + ROAD_LIFT_STEP * 5;  { 5 }
    rkSecondary: Result := ROAD_LIFT_M + ROAD_LIFT_STEP * 6;  { 6 }
    rkMajor:     Result := ROAD_LIFT_M + ROAD_LIFT_STEP * 7;  { 7 }
  else
    Result := ROAD_LIFT_M;
  end;
end;

class function TRoadBuilder.ClassUVScaleY(
  const Params: TRoadParams): Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1110);{$ENDIF}
  case Params.Kind of
    rkRailway:  Exit(ROAD_UV_SCALE_Y_RAILWAY);
    rkFootway:  Exit(ROAD_UV_SCALE_Y_FOOTWAY);
    rkCycleway: Exit(ROAD_UV_SCALE_Y_CYCLEWAY);
    rkDirtPath: Exit(ROAD_UV_SCALE_Y_DIRT);
    rkSandPath: Exit(ROAD_UV_SCALE_Y_SAND);
  end;
  case Params.Material of
    pmConcrete:    Result := ROAD_UV_SCALE_Y_CONCRETE;
    pmCobblestone: Result := ROAD_UV_SCALE_Y_COBBLE;
    pmWood:        Result := ROAD_UV_SCALE_Y_WOOD;
    pmDirt:        Result := ROAD_UV_SCALE_Y_DIRT;
    pmSand:        Result := ROAD_UV_SCALE_Y_SAND;
  else
    Result := ROAD_UV_SCALE_Y_ASPHALT;
  end;
end;

procedure SortInt64(var A: array of Int64);
  procedure QS(L, R: Integer);
  var
    I, J: Integer;
    P, T: Int64;
  begin
    while L < R do
    begin
      I := L; J := R; P := A[(L + R) shr 1];
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
        if L < J then QS(L, J);
        L := I;
      end
      else
      begin
        if I < R then QS(I, R);
        R := J;
      end;
    end;
  end;
begin
  if Length(A) > 1 then QS(0, High(A));
end;

{ quicksort индексов Ord по Int64-ключам Keys[Ord[i]]; равные ключи
  упорядочиваются по значению Ord, т.е. вывод совпадает со стабильной
  сортировкой вставками над первоначальным порядком Ord }
procedure SortOrdByInt64(const Keys: array of Int64; var Ord: array of Integer);
  procedure QS(L, R: Integer);
  var
    I, J, T, PO: Integer;
    P: Int64;
  begin
    while L < R do
    begin
      I := L; J := R; PO := Ord[(L + R) shr 1]; P := Keys[PO];
      repeat
        while (Keys[Ord[I]] < P)
           or ((Keys[Ord[I]] = P) and (Ord[I] < PO)) do Inc(I);
        while (Keys[Ord[J]] > P)
           or ((Keys[Ord[J]] = P) and (Ord[J] > PO)) do Dec(J);
        if I <= J then
        begin
          T := Ord[I]; Ord[I] := Ord[J]; Ord[J] := T;
          Inc(I); Dec(J);
        end;
      until I > J;
      if J - L < R - I then
      begin
        if L < J then QS(L, J);
        L := I;
      end
      else
      begin
        if I < R then QS(I, R);
        R := J;
      end;
    end;
  end;
begin
  if Length(Ord) > 1 then QS(0, High(Ord));
end;

class procedure TRoadBuilder.AppendWayRibbon(Way: TOSMWay;
  Dataset: TOSMDataset; HM: THeightmap; Projection: TLocalProjection;
  Width, Lift, UVScaleY: Single;
  UVMinX, UVMaxX: Single;
  Target: TMesh;
  Sampler: TTerrainSampler;
  Progress: PClipperProgress;
  ABag: PLatRingBag;
  AUVMesh: TMesh;
  const AJunctionIds: TRoadJunctionIdArray;
  ARawForCarve: Boolean;
  const AChainRefs: TRoadJunctionIdArray);
var
  N, I: Integer;
  Node: TOSMNode;
  PCenter: TVector3;
  HalfW: Single;
  Center: TRibbonVertexArray;
  SpV1x, SpV1z, SpV2x, SpV2z, SpL1, SpL2: Single;
  Edges: TRibbonEdgePointArray;
  Stats: TPolylineStats;
  NoFillet: TBoolArray;
  Refs: array of Int64;
  SubRefs: TRoadJunctionIdArray;   { типизированный срез для рекурсии резки }
  lo, hi, mid: Integer;

  procedure EmitIntRingAndUV;
  var
    J, n2, a, b, c, d: Integer;
    Ring: array of TScatterPoint;
    up: TVector3;
    V0, V1: Single;
    UseUV: Boolean;
  begin
    n2 := Length(Edges);
    SetLength(Ring, n2 * 2);
    for J := 0 to n2 - 1 do
    begin
      Ring[J].X := Edges[J].Right.X;
      Ring[J].Z := Edges[J].Right.Z;
      Ring[n2 * 2 - 1 - J].X := Edges[J].Left.X;
      Ring[n2 * 2 - 1 - J].Z := Edges[J].Left.Z;
    end;
    BagAddRingWorld(ABag^, Ring, True);
    if AUVMesh <> nil then
    begin
      up := Vector3(0, 1, 0);
      UseUV := UVScaleY > 0;
      AUVMesh.CurrentOsmId := Target.CurrentOsmId;
      for J := 0 to n2 - 2 do
      begin
        if UseUV then
        begin
          V0 := Edges[J    ].AccumLen / UVScaleY;
          V1 := Edges[J + 1].AccumLen / UVScaleY;
        end
        else
        begin
          V0 := 0; V1 := 0;
        end;
        a := AUVMesh.AddVertex(Vector3(Edges[J  ].Right.X, 0, Edges[J  ].Right.Z),
          up, Vector2(UVMinX, V0));
        b := AUVMesh.AddVertex(Vector3(Edges[J  ].Left.X,  0, Edges[J  ].Left.Z),
          up, Vector2(UVMaxX, V0));
        c := AUVMesh.AddVertex(Vector3(Edges[J+1].Left.X,  0, Edges[J+1].Left.Z),
          up, Vector2(UVMaxX, V1));
        d := AUVMesh.AddVertex(Vector3(Edges[J+1].Right.X, 0, Edges[J+1].Right.Z),
          up, Vector2(UVMinX, V1));
        AUVMesh.AddQuad(a, b, c, d);
      end;
      AUVMesh.CurrentOsmId := 0;
    end;
  end;

  { Edge-based flat-quad fallback (no terrain sampler). Mirrors
    EmitRibbonSegmentToTerrain's UV convention (Right → UVMinX,
    Left → UVMaxX, V = AccumLen / UVScaleY), but emits flat quads
    at Y = Lift instead of clipping against the terrain mesh. Used
    when Sampler is nil. }
  procedure EmitFlatQuadsFromEdges;
  var
    J: Integer;
    R0, L0, R1, L1: TVector3;
    A1, A2: Single;
    V0, V1: Single;
    Vi: array[0..3] of Integer;
    HMValid: Boolean;
    UseUV: Boolean;
    Norm: TVector3;

    function SampleEdgeY(X, Z: Single): Single;
    begin
      {$IFDEF IAM_LIVE}IamLiveTrack(312);{$ENDIF}
      if HMValid then
        Result := THeightmapSampler.SampleBilinear(HM,
                    Projection.Unproject(X, Z)) + Lift
      else
        Result := Lift;
    end;

  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(311);{$ENDIF}
    HMValid := HM <> nil;
    UseUV := UVScaleY > 0;
    Norm := Vector3(0, 1, 0);
    for J := 0 to High(Edges) - 1 do
    begin
      R0.X := Edges[J    ].Right.X; R0.Z := Edges[J    ].Right.Z;
      L0.X := Edges[J    ].Left.X;  L0.Z := Edges[J    ].Left.Z;
      R1.X := Edges[J + 1].Right.X; R1.Z := Edges[J + 1].Right.Z;
      L1.X := Edges[J + 1].Left.X;  L1.Z := Edges[J + 1].Left.Z;
      R0.Y := SampleEdgeY(R0.X, R0.Z);
      L0.Y := SampleEdgeY(L0.X, L0.Z);
      R1.Y := SampleEdgeY(R1.X, R1.Z);
      L1.Y := SampleEdgeY(L1.X, L1.Z);

      if UseUV then
      begin
        V0 := Edges[J    ].AccumLen / UVScaleY;
        V1 := Edges[J + 1].AccumLen / UVScaleY;
      end
      else
      begin
        V0 := 0; V1 := 0;
      end;

      { Защита от вывернутого треугольника квада (см.
        EmitRibbonSegmentToTerrain): при локальном заступе кромки назад
        один из двух треугольников меняет знак площади и торчит из
        полотна. Меньшинственный по знаку — НЕ эмитим (обмен сторон
        запрещён: он перекручивает ленту и рвёт кромочную линию). }
      A1 := (L0.X - R0.X) * (L1.Z - R0.Z) - (L0.Z - R0.Z) * (L1.X - R0.X);
      A2 := (L1.X - R0.X) * (R1.Z - R0.Z) - (L1.Z - R0.Z) * (R1.X - R0.X);
      if ((A1 > 0) and (A2 < 0)) or ((A1 < 0) and (A2 > 0)) then
      begin
        if Abs(A1) >= Abs(A2) then A2 := 0 else A1 := 0;
      end;
      if (Abs(A1) <= 1e-3) and (Abs(A2) <= 1e-3) then Continue;

      Vi[0] := Target.AddVertex(R0, Norm, Vector2(UVMinX, V0));
      Vi[1] := Target.AddVertex(L0, Norm, Vector2(UVMaxX, V0));
      Vi[2] := Target.AddVertex(L1, Norm, Vector2(UVMaxX, V1));
      Vi[3] := Target.AddVertex(R1, Norm, Vector2(UVMinX, V1));
      if (Abs(A1) > 1e-3) and (Abs(A2) > 1e-3) then
        Target.AddQuad(Vi[0], Vi[1], Vi[2], Vi[3])
      else if Abs(A1) > 1e-3 then
        Target.AddTriangle(Vi[0], Vi[1], Vi[2])
      else
        Target.AddTriangle(Vi[0], Vi[2], Vi[3]);
    end;
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1111);{$ENDIF}
  if (Way = nil) or (Target = nil) then Exit;
  if AChainRefs <> nil then
    Refs := AChainRefs
  else
    Refs := Way.NodeRefs;
  N := Length(Refs);
  if N < 2 then Exit;
  HalfW := Width * 0.5;

  { Tag the ribbon's vertices with the OSM way id (both emitters go through AddVertex, which stamps
    CurrentOsmId; the id survives the terrain clip since it copies whole vertex records). Reset in
    the finally so the next way isn't mistagged. }
  Target.CurrentOsmId := Way.Id;
  try

  { Load centerline from OSM nodes. AccumLen is computed for the raw
    polyline; SubdivideSmoothRuns refreshes it on the subdivided
    output. }
  SetLength(Center, N);
  for I := 0 to N - 1 do
  begin
    Node := Dataset.FindNode(Refs[I]);
    if Node = nil then Exit;
    PCenter := NodePlanePos(Dataset, Node, Projection);   { int-first }
    Center[I].X := PCenter.X;
    Center[I].Z := PCenter.Z;
  end;
  ComputeRibbonAccumLen(Center);

  { Битый узел OSM (координаты за десятки/сотни км от трассы): режем
    полилинию на сегментах-«перелётах» — иначе лента станет гигантским
    треугольником через всю карту, а её кольцо взорвёт карв. Рекурсия как
    у разворота «туда-обратно» ниже. }
  for I := 1 to N - 1 do
  begin
    SpV1x := Center[I].X - Center[I - 1].X;
    SpV1z := Center[I].Z - Center[I - 1].Z;
    if SpV1x * SpV1x + SpV1z * SpV1z > ROAD_RUNAWAY_SEG_M2 then
    begin
      SetLength(SubRefs, I);
      Move(Refs[0], SubRefs[0], I * SizeOf(Int64));
      AppendWayRibbon(Way, Dataset, HM, Projection, Width, Lift, UVScaleY,
        UVMinX, UVMaxX, Target, Sampler, Progress, ABag, AUVMesh,
        AJunctionIds, ARawForCarve, SubRefs);
      SetLength(SubRefs, N - I);
      Move(Refs[I], SubRefs[0], (N - I) * SizeOf(Int64));
      AppendWayRibbon(Way, Dataset, HM, Projection, Width, Lift, UVScaleY,
        UVMinX, UVMaxX, Target, Sampler, Progress, ABag, AUVMesh,
        AJunctionIds, ARawForCarve, SubRefs);
      Exit;
    end;
  end;

  { Разворот «туда-обратно» внутри одной полилинии: OSM-way легально может
    вернуться по собственным узлам (тупик-«леденец», парковочная петля,
    криво оцифрованный трек). Лента при таком развороте (~180°) складывается
    вдвое и рендерится «языком» с острым кончиком, торчащим из дороги
    (наблюдалось: w390178595, плечо 142 м через реку). Фаска такой угол
    осознанно пропускает (гард tan-взрыва), поэтому лечим ДО конвейера:
    режем полилинию на месте разворота на две независимые ленты — каждая
    рисуется чисто, а их наложение по общей трассе визуально корректно. }
  for I := 1 to N - 2 do
  begin
    SpV1x := Center[I].X - Center[I - 1].X;
    SpV1z := Center[I].Z - Center[I - 1].Z;
    SpV2x := Center[I + 1].X - Center[I].X;
    SpV2z := Center[I + 1].Z - Center[I].Z;
    SpL1 := Sqrt(SpV1x * SpV1x + SpV1z * SpV1z);
    SpL2 := Sqrt(SpV2x * SpV2x + SpV2z * SpV2z);
    if (SpL1 < 1e-6) or (SpL2 < 1e-6) then Continue;
    if (SpV1x * SpV2x + SpV1z * SpV2z) / (SpL1 * SpL2)
       <= ROAD_SPLIT_REVERSAL_COS then
    begin
      SetLength(SubRefs, I + 1);
      Move(Refs[0], SubRefs[0], (I + 1) * SizeOf(Int64));
      AppendWayRibbon(Way, Dataset, HM, Projection, Width, Lift, UVScaleY,
        UVMinX, UVMaxX, Target, Sampler, Progress, ABag, AUVMesh,
        AJunctionIds, ARawForCarve, SubRefs);
      SetLength(SubRefs, N - I);
      Move(Refs[I], SubRefs[0], (N - I) * SizeOf(Int64));
      AppendWayRibbon(Way, Dataset, HM, Projection, Width, Lift, UVScaleY,
        UVMinX, UVMaxX, Target, Sampler, Progress, ABag, AUVMesh,
        AJunctionIds, ARawForCarve, SubRefs);
      Exit;
    end;
  end;

  { маска запрета скругления: узлы-развязки — бинпоиск в отсортированном
    списке; выделяется только при наличии развязок на этом way }
  NoFillet := nil;
  if AJunctionIds <> nil then
    for I := 0 to N - 1 do
    begin
      lo := 0; hi := High(AJunctionIds);
      while lo <= hi do
      begin
        mid := (lo + hi) shr 1;
        if AJunctionIds[mid] < Refs[I] then lo := mid + 1
        else if AJunctionIds[mid] > Refs[I] then hi := mid - 1
        else
        begin
          if NoFillet = nil then SetLength(NoFillet, N);
          NoFillet[I] := True;
          Break;
        end;
      end;
    end;

  { Pipeline: classify centerline -> fillet sharp corners INWARD with inscribed tangent arcs +
    shoulder the gentle bends -> centripetal Catmull-Rom through gentle nodes -> build edge-points
    with mitre/bevel/round joints, then route to ProjectRibbonFromEdges (terrain-clipped) or
    EmitFlatQuadsFromEdges (no-sampler fallback). Smoothing + joint logic lives in Osm3dGeomRoadJoints. }
  BuildSmoothRibbonEdges(Center, HalfW, Edges, Stats,
    CR_DEFAULT_CHORD_ERR_M, NoFillet);

  if Length(Edges) < 2 then Exit;

  { int-first вход карва: контур ленты (джойнты уже разрешены в Edges)
    уходит кольцом от источника — мимо квантованного треугольного супа,
    порождавшего самопересечения на веерах джойнтов («невырезанное под
    дорогой», торчащие треугольники). UV-квады тех же Edges (Y=0, без
    сэмплера) складываются в лёгкий UV-меш материала — источник
    аналитической развёртки от центрлайна для bary-lookup. Сам меш ленты
    не строится: перекрёстки покрывает winding перекрывающихся колец. }
  if ARawForCarve and (ABag <> nil) then
  begin
    EmitIntRingAndUV;
    Exit;
  end;

  { Carve path (ARawForCarve): force flat quads even with a Sampler — the carve re-clips and
    DrapeComposite re-heights anyway, so the terrain pre-clip is duplicated work. UV convention and
    joint-resolved Edges are identical, so shape/joints are unchanged. }
  if (Sampler <> nil) and (not ARawForCarve) then
    TTerrainClipper.ProjectRibbonFromEdges(Edges,
      Sampler, Projection, Lift, UVScaleY, UVMinX, UVMaxX,
      Target, Progress)
  else
    EmitFlatQuadsFromEdges;

  finally
    Target.CurrentOsmId := 0;
  end;
end;

{ Parallel road build: ribbon generation is per-way independent (reads are read-only, writes go to
  the way's own Target mesh), so the loop parallelizes like landuse — collect (way, params) jobs,
  a worker pool builds into per-worker meshes + seg lists, concatenate on the main thread. }
type
  TRoadJob = record
    Way:    TOSMWay;
    Params: TRoadParams;
    { склейка продолжений: узел, где сходятся РОВНО два конца way одного
      класса/ширины почти без излома (< ~30°), соединяет их в одну
      логическую дорогу — сквозной AccumLen (непрерывная разметка/UV),
      один владелец, скругление в узле склейки снова законно. nil =
      использовать Way.NodeRefs. }
    ChainRefs: array of Int64;
  end;
  TRoadJobs = array of TRoadJob;
  PRoadJobs = ^TRoadJobs;

  TRoadWorker = class(TThread)
  private
    FJobs:       PRoadJobs;
    FNextJob:    PLongInt;          { shared atomic job cursor }
    FDataset:    TOSMDataset;
    FHM:         THeightmap;
    FProjection: TLocalProjection;
    FSampler:    TTerrainSampler;
    FIntRings:   Boolean;
    FJunctionIds: TRoadJunctionIdArray;
    FMeshes:     TRoadMeshes;       { thread-local 9 class meshes }
    FSegs:       TRoadCenterlineSegArray;
    FSegCnt:     Integer;
    FException:  string;
    FProcessed:  Integer;
    FCarveRaw:   Boolean;
    procedure PushSeg(const APA, APB: TVector3; AWidth: Single; AWayId: Int64);
  protected
    procedure Execute; override;
  public
    constructor Create(AJobs: PRoadJobs; ANextJob: PLongInt;
      ADataset: TOSMDataset; AHM: THeightmap; AProj: TLocalProjection;
      ASampler: TTerrainSampler; ACarveRaw: Boolean; AIntRings: Boolean;
      const AJunctionIds: TRoadJunctionIdArray);
    destructor Destroy; override;
    property Meshes:      TRoadMeshes read FMeshes;
    property Segs:        TRoadCenterlineSegArray read FSegs;
    property SegCnt:      Integer read FSegCnt;
    property WorkerError: string read FException;
    property Processed:   Integer read FProcessed;
  end;

{ Kind -> the matching field of a TRoadMeshes record (the fields are named, not
  an array). Returns the class instance, so callers both read its counts and
  AppendMesh into it. }
function RoadMeshField(const M: TRoadMeshes; K: TRoadKind): TMesh;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1452);{$ENDIF}
  case K of
    rkMajor:     Result := M.Major;
    rkSecondary: Result := M.Secondary;
    rkMinor:     Result := M.Minor;
    rkService:   Result := M.Service;
    rkFootway:   Result := M.Footway;
    rkCycleway:  Result := M.Cycleway;
    rkRailway:   Result := M.Railway;
    rkDirtPath:  Result := M.DirtPath;
    rkSandPath:  Result := M.SandPath;
  else
    Result := nil;
  end;
end;

constructor TRoadWorker.Create(AJobs: PRoadJobs; ANextJob: PLongInt;
  ADataset: TOSMDataset; AHM: THeightmap; AProj: TLocalProjection;
  ASampler: TTerrainSampler; ACarveRaw: Boolean; AIntRings: Boolean;
  const AJunctionIds: TRoadJunctionIdArray);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1453);{$ENDIF}
  inherited Create(True);    { suspended — Start once fields are set }
  FreeOnTerminate := False;
  FJobs       := AJobs;
  FNextJob    := ANextJob;
  FDataset    := ADataset;
  FHM         := AHM;
  FProjection := AProj;
  FSampler    := ASampler;
  FCarveRaw   := ACarveRaw;
  FIntRings   := AIntRings;
  FJunctionIds := AJunctionIds;
  FException  := '';
  FProcessed  := 0;
  FSegCnt     := 0;
  SetLength(FSegs, 1024);
  FMeshes.Major     := TMesh.Create('roads_major_mt');
  FMeshes.Secondary := TMesh.Create('roads_secondary_mt');
  FMeshes.Minor     := TMesh.Create('roads_minor_mt');
  FMeshes.Service   := TMesh.Create('roads_service_mt');
  FMeshes.Footway   := TMesh.Create('roads_footway_mt');
  FMeshes.Cycleway  := TMesh.Create('roads_cycleway_mt');
  FMeshes.Railway   := TMesh.Create('roads_railway_mt');
  FMeshes.DirtPath  := TMesh.Create('roads_dirt_path_mt');
  FMeshes.SandPath  := TMesh.Create('roads_sand_path_mt');
  begin
    { UV-меши int-пути: по одному на класс (rkNone остаётся nil) }
    FMeshes.UVMesh[rkMajor]     := TMesh.Create('roads_uv_major_mt');
    FMeshes.UVMesh[rkSecondary] := TMesh.Create('roads_uv_secondary_mt');
    FMeshes.UVMesh[rkMinor]     := TMesh.Create('roads_uv_minor_mt');
    FMeshes.UVMesh[rkService]   := TMesh.Create('roads_uv_service_mt');
    FMeshes.UVMesh[rkFootway]   := TMesh.Create('roads_uv_footway_mt');
    FMeshes.UVMesh[rkCycleway]  := TMesh.Create('roads_uv_cycleway_mt');
    FMeshes.UVMesh[rkRailway]   := TMesh.Create('roads_uv_railway_mt');
    FMeshes.UVMesh[rkDirtPath]  := TMesh.Create('roads_uv_dirt_mt');
    FMeshes.UVMesh[rkSandPath]  := TMesh.Create('roads_uv_sand_mt');
  end;
end;

destructor TRoadWorker.Destroy;
var
  KK: TRoadKind;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1454);{$ENDIF}
  FMeshes.Major.Free;     FMeshes.Secondary.Free;
  FMeshes.Minor.Free;     FMeshes.Service.Free;
  FMeshes.Footway.Free;   FMeshes.Cycleway.Free;
  FMeshes.Railway.Free;
  FMeshes.DirtPath.Free;  FMeshes.SandPath.Free;
  for KK := Low(TRoadKind) to High(TRoadKind) do
    FMeshes.UVMesh[KK].Free;
  inherited;
end;

procedure TRoadWorker.PushSeg(const APA, APB: TVector3;
  AWidth: Single; AWayId: Int64);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1455);{$ENDIF}
  if FSegCnt >= Length(FSegs) then SetLength(FSegs, Length(FSegs) * 2);
  FSegs[FSegCnt].X0 := APA.X;  FSegs[FSegCnt].Z0 := APA.Z;
  FSegs[FSegCnt].X1 := APB.X;  FSegs[FSegCnt].Z1 := APB.Z;
  FSegs[FSegCnt].Width := AWidth;
  FSegs[FSegCnt].WayId := AWayId;
  FSegs[FSegCnt].IsBridge := False;   { мостовые эмитит только AppendBridgeSegs (BuildAll) }
  Inc(FSegCnt);
end;

procedure TRoadWorker.Execute;
var
  Idx, NI: Integer;
  Job: TRoadJob;
  Target: TMesh;
  SegRefs: array of Int64;
  NA, NB: TOSMNode;
  PA, PB: TVector3;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1456);{$ENDIF}
  try
    while not Terminated do
    begin
      Idx := InterlockedIncrement(FNextJob^) - 1;
      if Idx >= Length(FJobs^) then Break;
      Job    := FJobs^[Idx];
      Target := RoadMeshField(FMeshes, Job.Params.Kind);
      if Target <> nil then
      begin
        { int-путь единственный: мешки колец и UV-меши передаются всегда;
          AppendWayRibbon сам гейтится по ARawForCarve+ABag }
        TRoadBuilder.AppendWayRibbon(Job.Way, FDataset, FHM, FProjection,
          Job.Params.Width, TRoadBuilder.ClassLift(Job.Params.Kind),
          TRoadBuilder.ClassUVScaleY(Job.Params),
          Job.Params.UVMinX, Job.Params.UVMaxX,
          Target, FSampler, nil,
          @FMeshes.IntRings[Job.Params.Kind],
          FMeshes.UVMesh[Job.Params.Kind],
          FJunctionIds,
          FCarveRaw,
          Job.ChainRefs);

        { centerline segments for the route snapper — same filter as the old
          serial path (skip railways and junk-width ways) }
        if (Job.Params.Kind <> rkRailway) and (Job.Params.Width >= 0.5)
           and (Job.Way <> nil) then
        begin
          if Job.ChainRefs <> nil then
            SegRefs := Job.ChainRefs
          else
            SegRefs := Job.Way.NodeRefs;
          for NI := 0 to High(SegRefs) - 1 do
          begin
            NA := FDataset.FindNode(SegRefs[NI]);
            NB := FDataset.FindNode(SegRefs[NI + 1]);
            if (NA = nil) or (NB = nil) then Continue;
            PA := NodePlanePos(FDataset, NA, FProjection);   { int-first }
            PB := NodePlanePos(FDataset, NB, FProjection);
            PushSeg(PA, PB, Job.Params.Width, Job.Way.Id);
            with FSegs[FSegCnt-1].Surface do
            begin
              Layout := Job.Params.Layout;
              ForwardLanes := Job.Params.LanesForward;
              BackwardLanes := Job.Params.LanesBackward;
              UVMin := Job.Params.UVMinX; UVMax := Job.Params.UVMaxX;
              UVScale := TRoadBuilder.ClassUVScaleY(Job.Params);
              Marked := Ord(Job.Params.IsMarked);
              if Job.Params.Material=pmConcrete then Asphalt:=ROAD_SURFACE_CONCRETE
              else Asphalt := ROAD_SURFACE_ASPHALT + Ord(Job.Params.Material <> pmAsphalt);
              Condition := RoadConditionFromSmoothness(Job.Way.Tags.GetLower('smoothness'));
            end;
          end;
        end;
      end;
      Inc(FProcessed);
    end;
  except
    on E: Exception do
      FException := E.ClassName + ': ' + E.Message;
  end;
end;

class function TRoadBuilder.BuildAll(Dataset: TOSMDataset; HM: THeightmap;
  Projection: TLocalProjection;
  out ASegs: TRoadCenterlineSegArray;
  Sampler: TTerrainSampler;
  LogProc: TLogProc;
  ACarveRaw: Boolean;
  AIntRings: Boolean): TRoadMeshes;
const
  MAX_ROAD_WORKERS = 16;
var
  Way: TOSMWay;
  Params: TRoadParams;
  Jobs: TRoadJobs;
  JobCount: Integer;
  Workers: array of TRoadWorker;
  NumWorkers, W, j: Integer;
  NextJob: LongInt;
  ErrMsg: string;
  TStart: TDateTime;
  K: TRoadKind;
  vsum, isum, segTotal, segPos: Integer;
  KINDS: array[0..8] of TRoadKind;
  M, SrcM: TMesh;
  JunctAll: array of Int64;
  JunctionIds: TRoadJunctionIdArray;
  JunctN, JI, JJ, JK: Integer;
  EndN: array of Int64;
  EndOrd: array of Integer;
  Conn: array of Integer;             { конец (job*2+end) -> связанный конец }
  ChainUsed: array of Boolean;
  ChainCount: Integer;
  { Мостовые и туннельные way (OsmWayIsBridge / OsmWayIsTunnel): в jobs не
    идут (лента/кольца/выравнивание их не видят), но их осевые сегменты нужны
    снап-слою маршрута — копятся здесь и доклеиваются в ASegs после воркеров
    (AppendBridgeSegs). }
  BridgeWays:   array of TOSMWay;
  BridgeWidths: array of Single;
  BridgeN:      Integer;

  { Осевые сегменты мостовых way -> ASegs с IsBridge=True. Без них у
    снаппера дырка над каждым мостом: середина пролёта проецируется на
    подъездные сегменты только клампнутыми торцами и режется узким торцевым
    гейтом — точки длинного моста принципиально не снапятся. Сегменты
    существуют ТОЛЬКО для снап-слоя: DistributeRoadSegments копирует их в
    тайловый RoadSegs без флага (формат тайла/сайдкара не меняется), а
    LevelRoadsInComposite / BuildRoadProximityMap флагованные пропускают.
    Сериально: мостов на блок единицы, FindNode дёшев. }
  procedure AppendBridgeSegs;
  var
    bi, ni, bn, b0: Integer;
    BRefs: array of Int64;
    BNA, BNB: TOSMNode;
    BPA, BPB: TVector3;
    BParams: TRoadParams;
  begin
    if BridgeN = 0 then Exit;
    b0 := Length(ASegs);
    bn := b0;
    for bi := 0 to BridgeN - 1 do
    begin
      BRefs := BridgeWays[bi].NodeRefs;
      BParams := ParseRoadParams(BridgeWays[bi].Tags);
      for ni := 0 to High(BRefs) - 1 do
      begin
        BNA := Dataset.FindNode(BRefs[ni]);
        BNB := Dataset.FindNode(BRefs[ni + 1]);
        if (BNA = nil) or (BNB = nil) then Continue;
        BPA := NodePlanePos(Dataset, BNA, Projection);   { int-first }
        BPB := NodePlanePos(Dataset, BNB, Projection);
        if bn >= Length(ASegs) then SetLength(ASegs, bn * 2 + 16);
        ASegs[bn].X0 := BPA.X;  ASegs[bn].Z0 := BPA.Z;
        ASegs[bn].X1 := BPB.X;  ASegs[bn].Z1 := BPB.Z;
        ASegs[bn].Width    := BridgeWidths[bi];
        ASegs[bn].WayId    := BridgeWays[bi].Id;
        ASegs[bn].IsBridge := True;
        with ASegs[bn].Surface do
        begin
          Layout:=BParams.Layout;
          ForwardLanes:=BParams.LanesForward; BackwardLanes:=BParams.LanesBackward;
          UVMin:=BParams.UVMinX; UVMax:=BParams.UVMaxX;
          UVScale:=ClassUVScaleY(BParams); Marked:=Ord(BParams.IsMarked);
          if BParams.Material=pmConcrete then Asphalt:=ROAD_SURFACE_CONCRETE
          else Asphalt:=ROAD_SURFACE_ASPHALT+Ord(BParams.Material<>pmAsphalt);
          Condition:=RoadConditionFromSmoothness(BridgeWays[bi].Tags.GetLower('smoothness'));
        end;
        Inc(bn);
      end;
    end;
    SetLength(ASegs, bn);
    if Assigned(LogProc) and (bn > b0) then
      LogProc(Format('  roads: +%d bridge centerline segs for the route snapper (%d bridge ways)',
        [bn - b0, BridgeN]));
  end;

  function EndDir(AJob, AEnd: Integer; out DX, DZ: Single): Boolean;
  var
    RefsL: array of Int64;
    NA2, NB2: TOSMNode;
    PA2, PB2: TVector3;
    L2: Single;
  begin
    Result := False;
    RefsL := Jobs[AJob].Way.NodeRefs;
    if Length(RefsL) < 2 then Exit;
    { направление ИЗ полилинии НАРУЖУ через конец AEnd }
    if AEnd = 0 then
    begin
      NA2 := Dataset.FindNode(RefsL[1]);
      NB2 := Dataset.FindNode(RefsL[0]);
    end
    else
    begin
      NA2 := Dataset.FindNode(RefsL[High(RefsL) - 1]);
      NB2 := Dataset.FindNode(RefsL[High(RefsL)]);
    end;
    if (NA2 = nil) or (NB2 = nil) then Exit;
    PA2 := NodePlanePos(Dataset, NA2, Projection);   { int-first }
    PB2 := NodePlanePos(Dataset, NB2, Projection);
    DX := PB2.X - PA2.X; DZ := PB2.Z - PA2.Z;
    L2 := Sqrt(DX * DX + DZ * DZ);
    if L2 < 1e-6 then Exit;
    DX := DX / L2; DZ := DZ / L2;
    Result := True;
  end;

  function CompatParams(ja, jb: Integer): Boolean;
  begin
    with Jobs[ja].Params do
      Result := (Kind = Jobs[jb].Params.Kind)
        and (Material = Jobs[jb].Params.Material)
        and (IsMarked = Jobs[jb].Params.IsMarked)
        and (Abs(Width - Jobs[jb].Params.Width) <= 0.01)
        and (Abs(UVMinX - Jobs[jb].Params.UVMinX) <= 0.001)
        and (Abs(UVMaxX - Jobs[jb].Params.UVMaxX) <= 0.001);
  end;

  { жадное спаривание концов группы одного узла: лучшая встречность
    первой, каждый конец не более чем в одной паре, порог ~30° }
  procedure GreedyPairEnds(AGrpLo, AGrpHi: Integer);
  const
    COS_MERGE = 0.866;
  var
    qa, qb, oa, ob, bestA, bestB: Integer;
    ax, az, bx, bz, c, bestC: Single;
  begin
    repeat
      bestA := -1; bestB := -1; bestC := COS_MERGE;
      for qa := AGrpLo to AGrpHi - 2 do
      begin
        oa := EndOrd[qa];
        if Conn[oa] >= 0 then Continue;
        if not EndDir(oa div 2, oa and 1, ax, az) then Continue;
        for qb := qa + 1 to AGrpHi - 1 do
        begin
          ob := EndOrd[qb];
          if Conn[ob] >= 0 then Continue;
          if (oa div 2) = (ob div 2) then Continue;   { замкнутый way }
          if not CompatParams(oa div 2, ob div 2) then Continue;
          if not EndDir(ob div 2, ob and 1, bx, bz) then Continue;
          c := ax * (-bx) + az * (-bz);
          if c > bestC then
          begin
            bestC := c; bestA := oa; bestB := ob;
          end;
        end;
      end;
      if bestA < 0 then Break;
      Conn[bestA] := bestB;
      Conn[bestB] := bestA;
    until False;
  end;

  procedure BuildChainFrom(AStart, AEnterEnd: Integer);
  var
    cur, enterE, exitE, other, q, rn: Integer;
    RefsL: array of Int64;
    Acc: array of Int64;
  begin
    Acc := nil; rn := 0;
    cur := AStart; enterE := AEnterEnd;
    repeat
      ChainUsed[cur] := True;
      RefsL := Jobs[cur].Way.NodeRefs;
      if enterE = 0 then
        for q := 0 to High(RefsL) do
        begin
          if (rn > 0) and (Acc[rn-1] = RefsL[q]) then Continue;
          if rn >= Length(Acc) then SetLength(Acc, rn * 2 + 16);
          Acc[rn] := RefsL[q]; Inc(rn);
        end
      else
        for q := High(RefsL) downto 0 do
        begin
          if (rn > 0) and (Acc[rn-1] = RefsL[q]) then Continue;
          if rn >= Length(Acc) then SetLength(Acc, rn * 2 + 16);
          Acc[rn] := RefsL[q]; Inc(rn);
        end;
      exitE := 1 - enterE;
      other := Conn[cur * 2 + exitE];
      if other < 0 then Break;
      cur := other div 2;
      enterE := other and 1;
      if ChainUsed[cur] then Break;             { кольцо замкнулось }
    until False;
    Jobs[AStart].ChainRefs := Copy(Acc, 0, rn);
    Inc(ChainCount);
  end;
begin
  JunctAll := nil; JunctN := 0;
  ChainCount := 0;
  BridgeWays := nil; BridgeWidths := nil; BridgeN := 0;
  {$IFDEF IAM_LIVE}IamLiveTrack(1112);{$ENDIF}
  Result.Major     := TMesh.Create('roads_major');
  Result.Secondary := TMesh.Create('roads_secondary');
  Result.Minor     := TMesh.Create('roads_minor');
  Result.Service   := TMesh.Create('roads_service');
  Result.Footway   := TMesh.Create('roads_footway');
  Result.Cycleway  := TMesh.Create('roads_cycleway');
  Result.Railway   := TMesh.Create('roads_railway');
  Result.DirtPath  := TMesh.Create('roads_dirt_path');
  Result.SandPath  := TMesh.Create('roads_sand_path');
  for K := Low(TRoadKind) to High(TRoadKind) do
  begin
    Result.IntRings[K].Rings := nil;
    Result.IntRings[K].N := 0;
    if K <> rkNone then
      Result.UVMesh[K] := TMesh.Create('roads_uv')
    else
      Result.UVMesh[K] := nil;
  end;

  { collect road ways into jobs — ParseRoadParams once per way here (the old
    serial path parsed it twice: once to count, once to build) }
  JobCount := 0;
  SetLength(Jobs, 256);
  for Way in Dataset.Ways.Values do
  begin
    if Way = nil then Continue;
    if Length(Way.NodeRefs) < 2 then Continue;   { way без геометрии: ниже NodeRefs[0]/[High] }
    { area=yes highways are plazas/yards, not linear roads — the landuse
      builder fills them as a surface (TLanduseBuilder.ClassifyTags). A
      ribbon here would just trace the polygon outline (a paved ring around
      an empty middle), so skip them and let landuse own the fill. }
    if Way.Tags.HasKey('area') and (Way.Tags.GetLower('area') = 'yes') then
      Continue;
    Params := ParseRoadParams(Way.Tags);
    if Params.Kind = rkNone then Continue;
    { Bridge ways are excluded from the road meshes entirely: the carve only
      cuts what is in the meshes, so the polygons UNDER the bridge stay un-cut
      and the leveling pass (which works off AInput.RoadSegments, also fed from
      here) never touches them. The horizontal deck + concrete parapets are
      built separately by Osm3dGeomBridges after the composite is carved.
      Tunnel ways — точно так же: земля НАД трубой остаётся некарвленной
      (склон не прорезается полотном), нижнее полотно и бетонная обделка
      строятся отдельно (Osm3dGeomTunnels).
      НО: осевые сегменты моста/туннеля нужны снап-слою маршрута — way копится и
      после воркеров эмитится в ASegs с IsBridge=True (AppendBridgeSegs).
      Фильтры те же, что у PushSeg: рельсы и мусорная ширина мимо. }
    if OsmWayIsBridge(Way.Tags) or OsmWayIsTunnel(Way.Tags) then
    begin
      if (Params.Kind <> rkRailway) and (Params.Width >= 0.5) then
      begin
        if BridgeN >= Length(BridgeWays) then
        begin
          SetLength(BridgeWays,   BridgeN * 2 + 16);
          SetLength(BridgeWidths, BridgeN * 2 + 16);
        end;
        BridgeWays[BridgeN]   := Way;
        BridgeWidths[BridgeN] := Params.Width;
        Inc(BridgeN);
      end;
      Continue;
    end;
    if JobCount >= Length(Jobs) then SetLength(Jobs, Length(Jobs) * 2);
    Jobs[JobCount].Way    := Way;
    Jobs[JobCount].Params := Params;
    Inc(JobCount);
    { вклады узлов для набора развязок: конец way +1, интерьер +2
      (way проходит через узел). Развязка = суммарная степень >= 3. }
    for JI := 0 to High(Way.NodeRefs) do
    begin
      if JunctN >= Length(JunctAll) then
        SetLength(JunctAll, JunctN * 2 + 1024);
      JunctAll[JunctN] := Way.NodeRefs[JI];
      Inc(JunctN);
      if (JI > 0) and (JI < High(Way.NodeRefs)) then
      begin
        if JunctN >= Length(JunctAll) then
          SetLength(JunctAll, JunctN * 2 + 1024);
        JunctAll[JunctN] := Way.NodeRefs[JI];
        Inc(JunctN);
      end;
    end;
  end;
  SetLength(Jobs, JobCount);

  { набор развязок: сортировка вкладов, узлы со степенью >= 3 }
  JunctionIds := nil;
  if JunctN > 1 then
  begin
    SetLength(JunctAll, JunctN);
    SortInt64(JunctAll);
    JI := 0; JK := 0;
    while JI < JunctN do
    begin
      JJ := JI;
      while (JJ < JunctN) and (JunctAll[JJ] = JunctAll[JI]) do Inc(JJ);
      if JJ - JI >= 3 then
      begin
        if JK >= Length(JunctionIds) then
          SetLength(JunctionIds, JK * 2 + 64);
        JunctionIds[JK] := JunctAll[JI];
        Inc(JK);
      end;
      JI := JJ;
    end;
    SetLength(JunctionIds, JK);

    { ── склейка продолжений: way кончается на узле, другой way того же
      класса продолжается с него почти прямо (сплит одной дороги в OSM).
      Условия: на узле РОВНО два конца way и суммарная степень 2 (никто
      не проходит насквозь и не примыкает третьим), параметры совместимы,
      излом < ~30°. Склейка даёт сквозной AccumLen и одного владельца. ── }
    SetLength(EndN, JobCount * 2);
    SetLength(EndOrd, JobCount * 2);
    for JI := 0 to JobCount - 1 do
    begin
      EndN[JI*2]   := Jobs[JI].Way.NodeRefs[0];
      EndN[JI*2+1] := Jobs[JI].Way.NodeRefs[High(Jobs[JI].Way.NodeRefs)];
      EndOrd[JI*2] := JI*2; EndOrd[JI*2+1] := JI*2+1;
    end;
    { сортировка индексов по узлу (quicksort; тай-брейк по индексу даёт
      тот же порядок, что давали стабильные вставки) }
    SortOrdByInt64(EndN, EndOrd);
    SetLength(Conn, JobCount * 2);
    for JI := 0 to JobCount * 2 - 1 do Conn[JI] := -1;
    JI := 0;
    while JI < JobCount * 2 do
    begin
      JJ := JI;
      while (JJ < JobCount * 2)
            and (EndN[EndOrd[JJ]] = EndN[EndOrd[JI]]) do Inc(JJ);
      { продолжение законно и ВНУТРИ развязки: узел с пересечением/
        примыканиями может содержать пару концов одной дороги — жадное
        спаривание совместимых концов по лучшей встречности; X-узел,
        где обе дороги разрезаны, склеивает обе сквозные }
      if JJ - JI >= 2 then
        GreedyPairEnds(JI, JJ);
      JI := JJ;
    end;
    { сборка цепочек: старт со свободного конца; кольца — отдельно }
    SetLength(ChainUsed, JobCount);
    for JI := 0 to JobCount - 1 do ChainUsed[JI] := False;
    for JI := 0 to JobCount - 1 do
      if (not ChainUsed[JI])
         and ((Conn[JI*2] >= 0) or (Conn[JI*2+1] >= 0)) then
      begin
        if (Conn[JI*2] >= 0) and (Conn[JI*2+1] >= 0) then Continue;
        if Conn[JI*2] < 0 then
          BuildChainFrom(JI, 0)
        else
          BuildChainFrom(JI, 1);
      end;
    for JI := 0 to JobCount - 1 do
      if (not ChainUsed[JI]) and (Conn[JI*2] >= 0) then
        BuildChainFrom(JI, 0);      { кольцо: рвём в произвольном месте }
    { сжатие: звенья, поглощённые цепочками, выбрасываются }
    JJ := 0;
    for JI := 0 to JobCount - 1 do
      if not (ChainUsed[JI] and (Jobs[JI].ChainRefs = nil)) then
      begin
        if JJ <> JI then Jobs[JJ] := Jobs[JI];
        Inc(JJ);
      end;
    if JJ <> JobCount then
    begin
      if LogProc <> nil then
        LogProc(Format('  roads: continuation chains merged %d ways into %d chains',
          [JobCount - JJ + ChainCount, ChainCount]));
      JobCount := JJ;
      SetLength(Jobs, JobCount);
    end;
  end;

  SetLength(ASegs, 0);
  if JobCount = 0 then
  begin
    { блок может состоять из ОДНОГО моста (пролёт через реку, подъезды в
      соседних блоках) — снап-сегменты моста нужны и без ленточных jobs }
    AppendBridgeSegs;
    if Assigned(LogProc) then
      LogProc(Format('road centerline segments: %d', [Length(ASegs)]));
    Exit;
  end;

  NumWorkers := Min(MAX_ROAD_WORKERS, Max(1, TThread.ProcessorCount));
  if NumWorkers > JobCount then NumWorkers := JobCount;
  if Assigned(LogProc) and ACarveRaw then
    LogProc('  roads: raw flat-quad mode (carve re-clips + drapes; pre-clip skipped)');
  NextJob := 0;
  TStart  := Now;
  ErrMsg  := '';

  SetLength(Workers, NumWorkers);
  try
    for W := 0 to NumWorkers - 1 do
    begin
      Workers[W] := TRoadWorker.Create(@Jobs, @NextJob, Dataset, HM,
        Projection, Sampler, ACarveRaw, AIntRings, JunctionIds);
      Workers[W].Start;
    end;
    for W := 0 to NumWorkers - 1 do
    begin
      Workers[W].WaitFor;
      if Workers[W].WorkerError <> '' then
      begin
        if ErrMsg <> '' then ErrMsg := ErrMsg + '; ';
        ErrMsg := ErrMsg + Format('worker %d: %s', [W, Workers[W].WorkerError]);
      end;
    end;

    { merge per-class meshes — reserve each Result mesh to its total across all
      workers first (AppendMesh sets capacity to EXACTLY the new size, so without
      this each class mesh reallocs once per contributing worker), then append }
    KINDS[0] := rkMajor;     KINDS[1] := rkSecondary; KINDS[2] := rkMinor;
    KINDS[3] := rkService;   KINDS[4] := rkFootway;   KINDS[5] := rkCycleway;
    KINDS[6] := rkRailway;   KINDS[7] := rkDirtPath;  KINDS[8] := rkSandPath;
    for j := 0 to High(KINDS) do
    begin
      K := KINDS[j];
      M := RoadMeshField(Result, K);
      if M = nil then Continue;
      vsum := 0; isum := 0;
      for W := 0 to NumWorkers - 1 do
      begin
        SrcM := RoadMeshField(Workers[W].Meshes, K);
        Inc(vsum, SrcM.VertexCount);
        Inc(isum, SrcM.TriangleCount);
      end;
      if vsum > 0 then
      begin
        M.ReserveVertices(vsum);
        M.ReserveIndices(isum * 3);
        for W := 0 to NumWorkers - 1 do
        begin
          SrcM := RoadMeshField(Workers[W].Meshes, K);
          if SrcM.VertexCount > 0 then M.AppendMesh(SrcM);
        end;
      end;
      { int-first: слияние колец и UV-мешей воркеров }
      for W := 0 to NumWorkers - 1 do
      begin
        BagAppend(Result.IntRings[K], Workers[W].Meshes.IntRings[K]);
        if (Workers[W].Meshes.UVMesh[K] <> nil)
           and (Workers[W].Meshes.UVMesh[K].VertexCount > 0)
           and (Result.UVMesh[K] <> nil) then
          Result.UVMesh[K].AppendMesh(Workers[W].Meshes.UVMesh[K]);
      end;
    end;

    { concatenate per-worker centerline segments into ASegs }
    segTotal := 0;
    for W := 0 to NumWorkers - 1 do Inc(segTotal, Workers[W].SegCnt);
    SetLength(ASegs, segTotal);
    segPos := 0;
    for W := 0 to NumWorkers - 1 do
      for j := 0 to Workers[W].SegCnt - 1 do
      begin
        ASegs[segPos] := Workers[W].Segs[j];
        Inc(segPos);
      end;

    if Assigned(LogProc) then
      LogProc(Format('road centerline segments: %d (%d jobs, %d workers, %.1f s)',
        [segTotal, JobCount, NumWorkers, (Now - TStart) * 86400]));

    { осевые мостов — только в снап-слой (IsBridge=True) }
    AppendBridgeSegs;
  finally
    for W := 0 to NumWorkers - 1 do
      if Workers[W] <> nil then Workers[W].Free;
  end;

  if ErrMsg <> '' then
  begin
    Result.Major.Free;     Result.Secondary.Free;
    Result.Minor.Free;     Result.Service.Free;
    Result.Footway.Free;   Result.Cycleway.Free;
    Result.Railway.Free;
    Result.DirtPath.Free;  Result.SandPath.Free;
    for K := Low(TRoadKind) to High(TRoadKind) do
      Result.UVMesh[K].Free;
    SetLength(ASegs, 0);
    raise Exception.Create('Road worker error: ' + ErrMsg);
  end;
end;

function OsmWayIsBridge(Tags: TOSMTags): Boolean;
var V: string;
begin
  Result := False;
  if Tags = nil then Exit;
  V := Tags.GetLower('bridge');
  { bridge=yes / viaduct / aqueduct / boardwalk / ... are all bridges; only
    the explicit negatives (and the absent tag) are not. }
  Result := (V <> '') and (V <> 'no') and (V <> 'false') and (V <> '0');
end;

function OsmWayIsTunnel(Tags: TOSMTags): Boolean;
var V: string;
begin
  Result := False;
  if Tags = nil then Exit;
  V := Tags.GetLower('tunnel');
  { tunnel=yes / culvert / building_passage / ... are all tunnels; only
    the explicit negatives (and the absent tag) are not. }
  Result := (V <> '') and (V <> 'no') and (V <> 'false') and (V <> '0');
end;

{ for CreateImageTexture — shared loader }

class function TRoadTextures.GetDescriptor(Kind: TRoadKind): TRoadDescriptor;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1116);{$ENDIF}
  Result := ROAD_DESCRIPTORS[Kind];
end;

class function TRoadTextures.CreateForKind(Kind: TRoadKind): TImageTextureNode;
var
  Desc: TRoadDescriptor;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1117);{$ENDIF}
  Result := nil;
  Desc := ROAD_DESCRIPTORS[Kind];
  if Desc.TexturePath = '' then Exit;
  if not FileExists(Desc.TexturePath) then Exit;
  Result := TSurfaceTextures.CreateImageTexture(Desc.TexturePath, True);
end;

class function TRoadTextures.CreateNormalForKind(Kind: TRoadKind): TImageTextureNode;
var
  Desc: TRoadDescriptor;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1118);{$ENDIF}
  Result := nil;
  Desc := ROAD_DESCRIPTORS[Kind];
  if Desc.NormalPath = '' then Exit;
  if not FileExists(Desc.NormalPath) then Exit;
  Result := TSurfaceTextures.CreateImageTexture(Desc.NormalPath, True);
end;

end.
