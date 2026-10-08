unit Osm3dGeomSurface;

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}{$modeswitch advancedrecords}
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
  Osm3dGeomUtils,
  Osm3dSceneMaterials,
  Osm3dOsmData,
  Osm3dOsmTagUtils,
  Osm3dGeomMesh
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
,
  Osm3dCarveGround;

type

  TLanduseKind = (
    lkNone,
    lkForest,
    lkGrass,
    lkWater,
    lkSand,
    lkParking,
    lkConstruction,
    lkFarmland0,
    lkFarmland1,
    lkFarmland2,
    lkIndustrial,
    lkCemetery,
    lkScrub,
    lkManicuredGrass,
    lkGarden,
    lkRock,
    lkGravel,
    lkPavementArea,
    lkAsphaltArea,
    lkCobblestone,
    lkPitchGeneric,
    lkPitchFootball,
    lkPitchBasketball,
    lkPitchTennis,
    lkHelipad
  );

  TForestSeed = record
    Pos:    TVector3;
    Area:   Single;
  end;
  TForestSeedArray = array of TForestSeed;

  TLanduseMeshKind = Succ(lkNone)..High(TLanduseKind);

  TLanduseMeshes = record
    Items:       array[TLanduseMeshKind] of TMesh;
    { int-first вход карва: кольца полигонов от источника (мимо earcut).
      Заполняется при ACarveRaw+AIntRings; ориентированные UV-полигоны
      остаются в мешах (пер-полигонный UV-трансформ в пер-kind слой не
      ложится) и подхватываются мешевым захватом. }
    IntRings:    array[TLanduseMeshKind] of TLatRingBag;
    ForestSeeds: TForestSeedArray;

    procedure CreateAll;
    procedure FreeAll;
  end;

  { Пер-вид масштаб UV ландюза (метров на повтор текстуры); 0 = UV не
    строится. Заполняется ВЫЗЫВАЮЩИМ из GROUND_MATERIALS через
    GROUND_MAT_FOR_LANDUSE (LanduseUVScalesFromMaterials в
    Osm3dGroundComposite) — ЕДИНЫЙ источник истины с терраин-карвом
    (usmPlanar тоже берёт GROUND_MATERIALS[..].UVScale): виды на одном
    материале тайлятся одинаково по построению. Локальной таблицы-зеркала
    больше нет — она разъезжалась (grass 25 против материала). }
  TLanduseUVScales = array[TLanduseMeshKind] of Single;

  TLanduseBuilder = class
  private


    class procedure AppendOutlineMultipolygon(
      const MP: TPolygonMultipolygon;
      HM: THeightmap; Projection: TLocalProjection;
      Target: TMesh; UVScale: Single;
      Sampler: TTerrainSampler;
      UVTransform: PUVTransform = nil;
      Lift: Single = LANDUSE_LIFT_M);

    class procedure AppendMultipolygonToMesh(
      const MP: TPolygonMultipolygon;
      Kind: TLanduseKind;
      HM: THeightmap; Projection: TLocalProjection;
      Target: TMesh; UVScale: Single;
      Sampler: TTerrainSampler;
      Progress: PClipperProgress = nil;
      AOsmId: Int64 = 0;
      ARawForCarve: Boolean = False;
      ABag: PLatRingBag = nil);
  public
    class function ClassifyTags(const Tags: TOSMTags): TLanduseKind;
    class function BuildAll(Dataset: TOSMDataset; HM: THeightmap;
      Projection: TLocalProjection;
      const AUVScales: TLanduseUVScales;
      Sampler: TTerrainSampler = nil;
      LogProc: TLogProc = nil;
      ACarveRaw: Boolean = False;
      AIntRings: Boolean = False): TLanduseMeshes;
  end;

function LanduseKindName(K: TLanduseMeshKind): string;

{ WATER_LIFT_M is in Osm3dGeoMath (shared Z-lift stack). }
const
  WIDTH_RIVER      = 10.0;
  WIDTH_CANAL      = 6.0;
  WIDTH_STREAM     = 3.0;
  WIDTH_DITCH      = 1.5;
  WIDTH_DEFAULT    = 4.0;
  MAX_MITRE_FACTOR = 3.0;       { cap on mitre length at acute angles }

type
  TWaterBuilder = class
  private

    class procedure BuildRibbon(Way: TOSMWay; Dataset: TOSMDataset;
      HM: THeightmap; Projection: TLocalProjection;
      HalfWidth: Single; Target: TMesh;
      Sampler: TTerrainSampler = nil;
      Progress: PClipperProgress = nil;
      ABag: PLatRingBag = nil);
  public
    class function ClassifyWidth(const Tags: TOSMTags): Single;
    class function MinorWaterway(const Tags: TOSMTags): Boolean;
    class function Underground(const Tags: TOSMTags): Boolean;
    { Sampler optional — when nil, Y is from heightmap bilinear directly. }
    class function BuildAll(Dataset: TOSMDataset; HM: THeightmap;
      Projection: TLocalProjection;
      Sampler: TTerrainSampler = nil;
      LogProc: TLogProc = nil;
      ABag: PLatRingBag = nil): TMesh;
  end;

implementation

type
  TLanduseJobItem = record
    MP:      TPolygonMultipolygon;
    Kind:    TLanduseKind;
    UVScale: Single;
    OsmId:   Int64;        { source OSM way / relation id; 0 = none }
  end;
  TLanduseJobs = array of TLanduseJobItem;
  PLanduseJobs = ^TLanduseJobs;

  TLanduseWorker = class(TThread)
  private
    FJobs:       PLanduseJobs;
    FNextJob:    PLongInt;
    FHM:         THeightmap;
    FProjection: TLocalProjection;
    FSampler:    TTerrainSampler;
    FMeshes:     TLanduseMeshes;
    FException:  string;
    FProcessed:  Integer;
    FCarveRaw:   Boolean;
    FIntRings:   Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(AJobs: PLanduseJobs; ANextJob: PLongInt;
      AHM: THeightmap; AProj: TLocalProjection; ASampler: TTerrainSampler;
      ACarveRaw: Boolean; AIntRings: Boolean);
    destructor Destroy; override;
    property Meshes:      TLanduseMeshes read FMeshes;
    property WorkerError: string         read FException;
    property Processed:   Integer        read FProcessed;
  end;

constructor TLanduseWorker.Create(AJobs: PLanduseJobs; ANextJob: PLongInt;
  AHM: THeightmap; AProj: TLocalProjection; ASampler: TTerrainSampler;
  ACarveRaw: Boolean; AIntRings: Boolean);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1122);{$ENDIF}
  inherited Create(True);
  FreeOnTerminate := False;
  FJobs       := AJobs;
  FNextJob    := ANextJob;
  FHM         := AHM;
  FProjection := AProj;
  FSampler    := ASampler;
  FCarveRaw   := ACarveRaw;
  FIntRings   := AIntRings;
  FException  := '';
  FProcessed  := 0;
  FMeshes.CreateAll;
end;

destructor TLanduseWorker.Destroy;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1123);{$ENDIF}
  FMeshes.FreeAll;
  inherited;
end;

procedure TLanduseWorker.Execute;
var
  Idx: LongInt;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(325);{$ENDIF}
  try
    while not Terminated do
    begin
      Idx := InterlockedIncrement(FNextJob^) - 1;
      if Idx >= Length(FJobs^) then Break;

      if FCarveRaw and FIntRings then
        TLanduseBuilder.AppendMultipolygonToMesh(
          FJobs^[Idx].MP, FJobs^[Idx].Kind,
          FHM, FProjection,
          FMeshes.Items[FJobs^[Idx].Kind],
          FJobs^[Idx].UVScale,
          FSampler,
          nil,
          FJobs^[Idx].OsmId,
          FCarveRaw,
          @FMeshes.IntRings[FJobs^[Idx].Kind])
      else
        TLanduseBuilder.AppendMultipolygonToMesh(
          FJobs^[Idx].MP, FJobs^[Idx].Kind,
          FHM, FProjection,
          FMeshes.Items[FJobs^[Idx].Kind],
          FJobs^[Idx].UVScale,
          FSampler,
          nil,
          FJobs^[Idx].OsmId,
          FCarveRaw);

      Inc(FProcessed);
    end;
  except
    on E: Exception do
      FException := E.ClassName + ': ' + E.Message;
  end;
end;

const
  LANDUSE_KIND_NAME: array[TLanduseMeshKind] of string = (
    'forest',          'grass',           'water',           'sand',
    'parking',         'construction',
    'farmland0',       'farmland1',       'farmland2',
    'industrial',      'cemetery',        'scrub',
    'manicured_grass', 'garden',          'rock',            'gravel',
    'pavement_area',   'asphalt_area',    'cobblestone',
    'pitch_generic',   'pitch_football',  'pitch_basketball',
    'pitch_tennis',    'helipad'
  );

function LanduseKindName(K: TLanduseMeshKind): string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(326);{$ENDIF}
  Result := LANDUSE_KIND_NAME[K];
end;

procedure TLanduseMeshes.CreateAll;
var
  K: TLanduseMeshKind;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(327);{$ENDIF}
  for K := Low(TLanduseMeshKind) to High(TLanduseMeshKind) do
    Items[K] := TMesh.Create('landuse_' + LANDUSE_KIND_NAME[K]);
  for K := Low(TLanduseMeshKind) to High(TLanduseMeshKind) do
  begin
    IntRings[K].Rings := nil;
    IntRings[K].N := 0;
  end;
end;

procedure TLanduseMeshes.FreeAll;
var
  K: TLanduseMeshKind;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(328);{$ENDIF}
  for K := Low(TLanduseMeshKind) to High(TLanduseMeshKind) do
    FreeAndNil(Items[K]);
  for K := Low(TLanduseMeshKind) to High(TLanduseMeshKind) do
  begin
    IntRings[K].Rings := nil;
    IntRings[K].N := 0;
  end;
end;

class function TLanduseBuilder.ClassifyTags(const Tags: TOSMTags): TLanduseKind;
var
  V, Sport, Surface: string;
  function AreaSurface(DefaultKind:TLanduseKind):TLanduseKind;
  var S:string;
  begin
    S:=Tags.GetLower('surface');
    if (S='asphalt') or (S='paved') then Exit(lkAsphaltArea);
    if (S='concrete') or (S='concrete:plates') or (S='concrete:lanes') then Exit(lkPavementArea);
    if (S='paving_stones') or (S='sett') or (S='cobblestone') or (S='pebblestone') then Exit(lkCobblestone);
    if (S='gravel') or (S='fine_gravel') or (S='compacted') then Exit(lkGravel);
    if S='sand' then Exit(lkSand);
    Result:=DefaultKind;
  end;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1124);{$ENDIF}
  Result := lkNone;

  { Older OSM river areas carry only waterway=riverbank. }
  if Tags.GetLower('waterway') = 'riverbank' then Exit(lkWater);

  if Tags.HasKey('natural') then
  begin
    V := Tags.GetLower('natural');
    if (V = 'wood') or (V = 'forest') or (V = 'tree_row') then Exit(lkForest);
    if (V = 'grassland') or (V = 'meadow') or (V = 'fell') then Exit(lkGrass);
    if (V = 'scrub') or (V = 'heath') or (V = 'wetland') then Exit(lkScrub);
    if (V = 'water') then Exit(lkWater);
    if (V = 'sand') or (V = 'beach') then Exit(lkSand);
    if (V = 'shingle') then Exit(lkGravel);
    if (V = 'bare_rock') or (V = 'cliff') or (V = 'scree') or
       (V = 'rock') then Exit(lkRock);
  end;

  if Tags.HasKey('golf') then
  begin
    V := Tags.GetLower('golf');
    if (V = 'fairway') or (V = 'green') or (V = 'tee') then Exit(lkManicuredGrass);
    if (V = 'rough') then Exit(lkScrub);
    if (V = 'bunker') then Exit(lkSand);
  end;

  if Tags.HasKey('leisure') then
  begin
    V := Tags.GetLower('leisure');

    if V = 'pitch' then
    begin
      Sport := Tags.GetLower('sport');
      if (Sport = 'soccer') or (Sport = 'football') or
         (Sport = 'american_football') then Exit(lkPitchFootball);
      if Sport = 'basketball' then Exit(lkPitchBasketball);
      if (Sport = 'tennis') or (Sport = 'padel') then Exit(lkPitchTennis);
      Exit(lkPitchGeneric);
    end;

    if (V = 'playground') or (V = 'dog_park') then Exit(lkPitchGeneric);
    if (V = 'garden') then Exit(lkGarden);
    if (V = 'park') or (V = 'common') or (V = 'recreation_ground') or
       (V = 'sports_centre') or (V = 'stadium') or
       (V = 'nature_reserve') then Exit(lkGrass);
    if (V = 'golf_course') then Exit(lkManicuredGrass);
    if (V = 'swimming_pool') then Exit(lkWater);
  end;

  if Tags.HasKey('aeroway') then
  begin
    V := Tags.GetLower('aeroway');
    if V = 'helipad' then Exit(lkHelipad);
    if (V = 'apron') or (V = 'taxiway') then Exit(AreaSurface(lkAsphaltArea));
  end;

  if Tags.HasKey('man_made') then
  begin
    V := Tags.GetLower('man_made');
    if V = 'bridge' then Exit(AreaSurface(lkPavementArea));
    if V = 'pier' then Exit(AreaSurface(lkPavementArea));
  end;
  if Tags.HasKey('area:highway') then
  begin
    V := Tags.GetLower('area:highway');
    if (V = 'footway') or (V = 'pedestrian') or (V = 'path') then
      Exit(AreaSurface(lkPavementArea));
    if (V = 'primary') or (V = 'secondary') or (V = 'tertiary') or
       (V = 'residential') or (V = 'service') or (V = 'unclassified') then
      Exit(AreaSurface(lkAsphaltArea));
  end;

  { Highway areas via highway=* + area=yes (area=yes required so linear paths stay linear — the
    road builder owns those). surface picks the material (mirrors the road builder's map); the
    highway class only chooses the no-surface default (vehicle -> asphalt, foot -> pavement). }
  if (Tags.GetLower('area') = 'yes') and Tags.HasKey('highway') then
  begin
    V       := Tags.GetLower('highway');
    Surface := Tags.GetLower('surface');
    if (Surface = 'paving_stones') or (Surface = 'sett') or
       (Surface = 'cobblestone')   or (Surface = 'pebblestone') then Exit(lkCobblestone);
    if (Surface = 'asphalt') or (Surface = 'paved') then Exit(lkAsphaltArea);
    if (Surface = 'concrete') then Exit(lkPavementArea);
    if (Surface = 'gravel') or (Surface = 'fine_gravel') or
       (Surface = 'compacted') then Exit(lkGravel);
    if (Surface = 'sand') then Exit(lkSand);
    if (V = 'service') or (V = 'track') or (V = 'unclassified') or
       (V = 'residential') or (V = 'living_street') or (V = 'tertiary') or
       (V = 'secondary')  or (V = 'primary') then Exit(lkAsphaltArea);
    Exit(lkPavementArea);   { pedestrian / footway / path / other }
  end;

  if Tags.HasKey('amenity') then
  begin
    V := Tags.GetLower('amenity');
    if (V = 'parking') or (V = 'parking_space') or
       (V = 'bicycle_parking') or (V = 'motorcycle_parking') then
    begin
      Exit(AreaSurface(lkParking));
    end;
  end;

  if Tags.HasKey('landuse') then
  begin
    V := Tags.GetLower('landuse');
    if (V = 'forest') or (V = 'wood') then Exit(lkForest);
    if (V = 'grass') or (V = 'meadow') or
       (V = 'recreation_ground') then Exit(lkGrass);
    if (V = 'village_green') or (V = 'flowerbed') then Exit(lkGarden);
    if (V = 'cemetery') or (V = 'grave_yard') then Exit(lkCemetery);
    if (V = 'farmland') or (V = 'farmyard') or (V = 'allotments') or
       (V = 'orchard') or (V = 'vineyard') or
       (V = 'plant_nursery') then Exit(lkFarmland0);
    if (V = 'reservoir') or (V = 'basin') or (V = 'salt_pond') then Exit(lkWater);
    if (V = 'construction') or (V = 'brownfield') or
       (V = 'greenfield') or (V = 'landfill') then Exit(lkConstruction);
    if (V = 'industrial') or (V = 'commercial') or (V = 'retail') or
       (V = 'depot') or (V = 'port') or (V = 'quarry') then Exit(lkIndustrial);
    if (V = 'residential') then Exit(lkGrass);
  end;

  if Tags.HasKey('surface') then
  begin
    V := Tags.GetLower('surface');
    if V = 'gravel' then Exit(lkGravel);
    if V = 'cobblestone' then Exit(lkCobblestone);
  end;
end;


{ Resolve effective TLanduseKind: distributes lkFarmland* across three
  variants by hash of ObjectId so adjacent fields don't all look identical. }
function ResolveEffectiveKind(Kind: TLanduseKind; ObjectId: Int64): TLanduseKind;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(329);{$ENDIF}
  if Kind in [lkFarmland0, lkFarmland1, lkFarmland2] then
    case Abs(ObjectId) mod 3 of
      0:    Result := lkFarmland0;
      1:    Result := lkFarmland1;
    else    Result := lkFarmland2;
    end
  else
    Result := Kind;
end;

class procedure TLanduseBuilder.AppendOutlineMultipolygon(
  const MP: TPolygonMultipolygon;
  HM: THeightmap; Projection: TLocalProjection;
  Target: TMesh; UVScale: Single;
  Sampler: TTerrainSampler;
  UVTransform: PUVTransform = nil;
  Lift: Single = LANDUSE_LIFT_M);
var
  TotalPts, OuterN, InnerCount: Integer;
  EarcutData:    array of Double;
  HoleIndices:   array of Integer;
  Triangles:     array of Integer;
  Heights:       array of Single;     { Y per vertex (terrain-conformed) }
  WrittenIdx:    array of Integer;
  I, J, K, IdxOut: Integer;
  V: TVector3;
  UV: TVector2;
  UseUV: Boolean;
  HasOrientedUV: Boolean;
  OUVx, OUVy: Double;
  InvUV: Single;
  RingPtr: ^TPolygonRing;

  function SampleY(X, Z: Single): Single; inline;
  var
    Lp: TLatLon;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(330);{$ENDIF}
    Lp := Projection.Unproject(X, Z);
    if Sampler <> nil then
      Result := Sampler.SampleAt(Lp) + Lift
    else
      Result := THeightmapSampler.SampleBilinear(HM, Lp) + Lift;
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1126);{$ENDIF}
  if Target = nil then Exit;
  if (Length(MP.Outer) < 3) or (Projection = nil) then Exit;

  OuterN := Length(MP.Outer);
  InnerCount := Length(MP.Inners);

  TotalPts := OuterN;
  for I := 0 to InnerCount - 1 do
    Inc(TotalPts, Length(MP.Inners[I]));

  if TotalPts < 3 then Exit;

  SetLength(EarcutData, TotalPts * 2);
  SetLength(HoleIndices, InnerCount);
  SetLength(Heights,    TotalPts);
  SetLength(WrittenIdx, TotalPts);

  for I := 0 to OuterN - 1 do
  begin
    EarcutData[I * 2]     := MP.Outer[I].X;
    EarcutData[I * 2 + 1] := MP.Outer[I].Z;
  end;
  K := OuterN;

  for I := 0 to InnerCount - 1 do
  begin
    HoleIndices[I] := K;
    RingPtr := @MP.Inners[I];
    for J := 0 to Length(RingPtr^) - 1 do
    begin
      EarcutData[K * 2]     := RingPtr^[J].X;
      EarcutData[K * 2 + 1] := RingPtr^[J].Z;
      Inc(K);
    end;
  end;

  for I := 0 to TotalPts - 1 do
    Heights[I] := SampleY(EarcutData[I * 2], EarcutData[I * 2 + 1]);

  Triangles := TEarcutTriangulator.Triangulate(EarcutData, HoleIndices, 2);
  if Length(Triangles) < 3 then Exit;

  UseUV := UVScale > 0;
  if UseUV then InvUV := 1.0 / UVScale else InvUV := 0;
  HasOrientedUV := UseUV and (UVTransform <> nil) and UVTransform^.Active;

  for I := 0 to TotalPts - 1 do
  begin
    V.X := EarcutData[I * 2];
    V.Z := EarcutData[I * 2 + 1];
    V.Y := Heights[I];
    if UseUV then
    begin
      if HasOrientedUV then
      begin
        ApplyUVTransform(UVTransform^, V.X, V.Z, OUVx, OUVy);
        UV.X := OUVx * InvUV;
        UV.Y := OUVy * InvUV;
      end
      else
      begin
        UV.X := V.X * InvUV;
        UV.Y := V.Z * InvUV;
      end;
      IdxOut := Target.AddVertex(V, Vector3(0, 1, 0), UV);
    end
    else
      IdxOut := Target.AddVertex(V, Vector3(0, 1, 0));
    WrittenIdx[I] := IdxOut;
  end;

  J := 0;
  while J + 3 <= Length(Triangles) do
  begin
    Target.AddTriangle(
      WrittenIdx[Triangles[J    ]],
      WrittenIdx[Triangles[J + 2]],
      WrittenIdx[Triangles[J + 1]]);
    Inc(J, 3);
  end;
end;

class procedure TLanduseBuilder.AppendMultipolygonToMesh(
  const MP: TPolygonMultipolygon;
  Kind: TLanduseKind;
  HM: THeightmap; Projection: TLocalProjection;
  Target: TMesh; UVScale: Single;
  Sampler: TTerrainSampler;
  Progress: PClipperProgress = nil;
  AOsmId: Int64 = 0;
  ARawForCarve: Boolean = False;
  ABag: PLatRingBag = nil);
var
  Emitted: Integer;
  Desc: TSurfaceDescriptor;
  UVTx: TUVTransform;
  PUVTx: PUVTransform;
  LiftM: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1128);{$ENDIF}
  if Target = nil then Exit;
  if Length(MP.Outer) < 3 then Exit;

  { Tag every vertex with the OSM id (survives the clipper, which copies whole vertex records).
    Each worker owns its target mesh and processes jobs sequentially, so set/reset is race-free. }
  Target.CurrentOsmId := AOsmId;
  try

  PUVTx := nil;
  Desc := TSurfaceTextures.GetDescriptor(Ord(Kind));
  if Desc.IsOriented and (UVScale > 0) then
  begin
    UVTx := BuildOrientedUVTransform(MP, Desc.Orientation, Desc.Stretch);
    if UVTx.Active then
      PUVTx := @UVTx;
  end;

  { int-first вход карва: полигон уходит кольцами напрямую (мимо earcut и
    последующего извлечения границ из треугольного супа — источника
    самопересечений после квантования). Ориентированные (PUVTx) остаются
    на мешевом пути; вода пишет кольца И продолжает строить меш —
    он нужен шейдерному водному шейпу поверх вырезанного ложа. }
  if ARawForCarve and (ABag <> nil) and (PUVTx = nil) then
  begin
    BagAddMultipolygon(ABag^, MP);
    if Kind <> lkWater then Exit;
  end;

  { Water polygons (lakes/ponds) must use WATER_LIFT_M, not LANDUSE_LIFT_M (0.0), or they z-fight
    the terrain. Every other landuse kind keeps LANDUSE_LIFT_M. }
  if Kind = lkWater then
    LiftM := WATER_LIFT_M
  else
    LiftM := LANDUSE_LIFT_M;

  { Raw earcut only for solid landuse on the carve path; lkWater stays on the drape path even
    under ARawForCarve (it's rendered as a separate animated shape, which a flat earcut would change). }
  if (not (ARawForCarve and (Kind <> lkWater))) and
     (Sampler <> nil) and (Projection <> nil) and
     (Sampler.GridX > 1) and (Sampler.GridZ > 1) then
  begin
    if UVScale > 0 then
      Emitted := TTerrainClipper.ProjectMultipolygon(
        MP, Sampler, Projection,
        LiftM,
        cumPlanar, UVScale,
        Target, Progress, PUVTx)
    else
      Emitted := TTerrainClipper.ProjectMultipolygon(
        MP, Sampler, Projection,
        LiftM,
        cumNone, 0,
        Target, Progress, nil);
    if Emitted > 0 then Exit;
  end;

  { Raw earcut polygon — the carve path (ARawForCarve) and the no-Sampler fallback. In carve mode
    the per-cell clip+drape is skipped because the carve re-clips and DrapeComposite sets final
    heights; pre-clipping here would only duplicate that work. }
  AppendOutlineMultipolygon(MP, HM, Projection, Target, UVScale,
    Sampler, PUVTx, LiftM);

  finally
    Target.CurrentOsmId := 0;
  end;
end;

class function TLanduseBuilder.BuildAll(Dataset: TOSMDataset;
  HM: THeightmap; Projection: TLocalProjection;
  const AUVScales: TLanduseUVScales;
  Sampler: TTerrainSampler;
  LogProc: TLogProc;
  ACarveRaw: Boolean;
  AIntRings: Boolean): TLanduseMeshes;
const
  MAX_LANDUSE_WORKERS = 16;
var
  Way: TOSMWay;
  Rel: TOSMRelation;
  Kind, EffKind: TLanduseKind;
  RelType: string;
  MP: TPolygonMultipolygon;
  Multipolygons: TMultipolygonArray;
  I: Integer;

  Jobs:        TLanduseJobs;
  JobCount:    Integer;
  Workers:     array of TLanduseWorker;
  W:           Integer;
  K:           TLanduseMeshKind;
  NumWorkers:  Integer;
  NextJob:     LongInt;
  ErrMsg:      string;
  TStart:      TDateTime;
  TotalProc:   Integer;

  procedure PushJob(const AMP: TPolygonMultipolygon; AKind: TLanduseKind;
    AOsmId: Int64);
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(331);{$ENDIF}
    if Length(AMP.Outer) < 3 then Exit;
    if AKind = lkNone then Exit;
    if Result.Items[AKind] = nil then Exit;
    if JobCount >= Length(Jobs) then SetLength(Jobs, Length(Jobs) * 2);
    Jobs[JobCount].MP      := AMP;
    Jobs[JobCount].Kind    := AKind;
    { Масштаб — из материалов (AUVScales, единый источник с терраином).
      Вытянутые виды (Stretch: BuildOrientedUVTransform кладёт OMBB в
      UV [0,1]x[-1,0]) ОБЯЗАНЫ иметь 1 — один тайл на весь полигон;
      правило по дескриптору покрывает площадки и вертолётку разом. }
    if TSurfaceTextures.GetDescriptor(Ord(AKind)).Stretch then
      Jobs[JobCount].UVScale := 1.0
    else
      Jobs[JobCount].UVScale := AUVScales[AKind];
    Jobs[JobCount].OsmId   := AOsmId;
    Inc(JobCount);
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1129);{$ENDIF}
  Result.CreateAll;
  Result.ForestSeeds := nil;

  JobCount := 0;
  SetLength(Jobs, 64);

  for Way in Dataset.Ways.Values do
  begin
    if (Way = nil) or (not Way.IsClosed) then Continue;
    Kind := ClassifyTags(Way.Tags);
    if Kind = lkNone then Continue;

    EffKind := ResolveEffectiveKind(Kind, Way.Id);
    if (EffKind = lkNone) or (Result.Items[EffKind] = nil) then Continue;

    MP := BuildMultipolygonFromWay(Way, Dataset, Projection);
    PushJob(MP, EffKind, Way.Id);
  end;

  for Rel in Dataset.Relations.Values do
  begin
    if Rel = nil then Continue;
    RelType := Rel.Tags.GetLower('type');
    if (RelType <> 'multipolygon') and (RelType <> 'boundary') then Continue;
    Kind := ClassifyTags(Rel.Tags);
    if Kind = lkNone then Continue;

    EffKind := ResolveEffectiveKind(Kind, Rel.Id);
    if (EffKind = lkNone) or (Result.Items[EffKind] = nil) then Continue;

    Multipolygons := BuildMultipolygonsFromRelation(Rel, Dataset, Projection);
    for I := 0 to High(Multipolygons) do
      PushJob(Multipolygons[I], EffKind, Rel.Id);
  end;

  SetLength(Jobs, JobCount);
  if JobCount = 0 then Exit;

  { Scale to hardware, capped at MAX_LANDUSE_WORKERS. }
  NumWorkers := Min(MAX_LANDUSE_WORKERS, Max(1, TThread.ProcessorCount));
  if NumWorkers > JobCount then NumWorkers := JobCount;

  if LogProc <> nil then
    LogProc(Format('  landuse: %d multipolygon jobs -> %d workers (%d logical CPUs)',
      [JobCount, NumWorkers, TThread.ProcessorCount]));
  if (LogProc <> nil) and ACarveRaw then
    LogProc('  landuse: raw earcut mode (carve re-clips + drapes; pre-clip skipped)');

  NextJob   := 0;
  TStart    := Now;
  ErrMsg    := '';
  TotalProc := 0;

  SetLength(Workers, NumWorkers);
  try
    for W := 0 to NumWorkers - 1 do
    begin
      Workers[W] := TLanduseWorker.Create(@Jobs, @NextJob,
        HM, Projection, Sampler, ACarveRaw, AIntRings);
      Workers[W].Start;
    end;

    { WaitFor blocks until termination — no busy-poll. Workers do all
      jobs in parallel; we collect them serially after they're done. }
    for W := 0 to NumWorkers - 1 do
    begin
      Workers[W].WaitFor;
      if Workers[W].WorkerError <> '' then
      begin
        if ErrMsg <> '' then ErrMsg := ErrMsg + '; ';
        ErrMsg := ErrMsg + Format('worker %d: %s',
          [W, Workers[W].WorkerError]);
      end;
      Inc(TotalProc, Workers[W].Processed);
    end;

    for W := 0 to NumWorkers - 1 do
      for K := Low(TLanduseMeshKind) to High(TLanduseMeshKind) do
      begin
        if (Workers[W].Meshes.Items[K] <> nil) and
           (Workers[W].Meshes.Items[K].VertexCount > 0) and
           (Result.Items[K] <> nil) then
          Result.Items[K].AppendMesh(Workers[W].Meshes.Items[K]);
        BagAppend(Result.IntRings[K], Workers[W].Meshes.IntRings[K]);
      end;

    if LogProc <> nil then
      LogProc(Format('  landuse: %d jobs done across %d workers in %.1f s',
        [TotalProc, NumWorkers, (Now - TStart) * 86400]));
  finally
    for W := 0 to NumWorkers - 1 do
      if Workers[W] <> nil then
        Workers[W].Free;
  end;

  if ErrMsg <> '' then
  begin
    Result.FreeAll;
    raise Exception.Create('Landuse worker error: ' + ErrMsg);
  end;
end;

class function TWaterBuilder.MinorWaterway(const Tags: TOSMTags): Boolean;
var V: string;
begin
  V := Tags.GetLower('waterway');
  if V = '' then V := Tags.GetLower('water');
  Result := (V = 'stream') or (V = 'ditch') or (V = 'drain');
end;

class function TWaterBuilder.Underground(const Tags: TOSMTags): Boolean;
var V: string;
begin
  V := Tags.GetLower('tunnel');
  Result := ((V <> '') and (V <> 'no') and (V <> 'false') and (V <> '0'))
    or (Tags.GetLower('location') = 'underground');
end;

class function TWaterBuilder.ClassifyWidth(const Tags: TOSMTags): Single;
var
  S, V: string;
  W: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1130);{$ENDIF}
  { Explicit width=N (metres) takes priority. }
  S := Trim(Tags.Get('width'));
  if S <> '' then
  begin
    W := ParseOSMMeters(S);
    if (W > 0.5) and (W < 200) then
      Exit(W);
  end;

  V := Tags.GetLower('waterway');
  if V = 'river'  then Exit(WIDTH_RIVER);
  if V = 'canal'  then Exit(WIDTH_CANAL);
  if V = 'stream' then Exit(WIDTH_STREAM);
  if (V = 'ditch') or (V = 'drain') then Exit(WIDTH_DITCH);
  Result := WIDTH_DEFAULT;
end;

class procedure TWaterBuilder.BuildRibbon(Way: TOSMWay; Dataset: TOSMDataset;
  HM: THeightmap; Projection: TLocalProjection;
  HalfWidth: Single; Target: TMesh;
  Sampler: TTerrainSampler;
  Progress: PClipperProgress;
  ABag: PLatRingBag);
{ Mitre-cut ribbon: at each node, a single offset perpendicular to the
  bisector of adjacent segments; length = HalfWidth/sin(angle/2), capped
  at MAX_MITRE_FACTOR×HalfWidth. Endpoints use the single-segment perp. }
var
  IntRing: TScatterPointArray;
  N, I, V0L, V0R, V1L, V1R: Integer;
  Node: TOSMNode;
  Pos: array of TVector3;     { centre-line; Y from heightmap+lift }
  Left, Right: array of TVector3;
  PrevDir, NextDir, Bisector, Perp: TVector3;
  PerpLen, MitreLen, MaxLen: Single;
  CosHalfAngle: Single;
  Y: Single;
  RTmp, LTmp, RNTmp, LNTmp: TVector3;
  Edges: TRibbonEdgePointArray;
  DX, DZ: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1131);{$ENDIF}
  if (Way = nil) or (Target = nil) then Exit;

  N := Length(Way.NodeRefs);
  if N < 2 then Exit;

  { Tag the river ribbon's vertices with the OSM way id (BuildAll runs ribbons sequentially into
    one shared Target, so set/reset is race-free). }
  Target.CurrentOsmId := Way.Id;
  try

  { Truncate at any bad node rather than skipping the whole way (rivers
    are often long). }
  SetLength(Pos, N);
  for I := 0 to N - 1 do
  begin
    Node := Dataset.FindNode(Way.NodeRefs[I]);
    if Node = nil then
    begin
      SetLength(Pos, I);
      Break;
    end;
    Pos[I] := NodePlanePos(Dataset, Node, Projection);   { int-first }
    if Sampler <> nil then
      Y := Sampler.SampleAt(Node.Position) + WATER_LIFT_M
    else
      Y := THeightmapSampler.SampleBilinear(HM, Node.Position) + WATER_LIFT_M;
    Pos[I].Y := Y;
  end;
  N := Length(Pos);
  if N < 2 then Exit;

  SetLength(Left,  N);
  SetLength(Right, N);

  MaxLen := HalfWidth * MAX_MITRE_FACTOR;

  for I := 0 to N - 1 do
  begin
    if I > 0 then
    begin
      PrevDir.X := Pos[I].X - Pos[I-1].X;
      PrevDir.Y := 0;
      PrevDir.Z := Pos[I].Z - Pos[I-1].Z;
      PrevDir := VecNormalize(PrevDir);
    end
    else
      PrevDir := Vector3(0, 0, 0);

    if I < N - 1 then
    begin
      NextDir.X := Pos[I+1].X - Pos[I].X;
      NextDir.Y := 0;
      NextDir.Z := Pos[I+1].Z - Pos[I].Z;
      NextDir := VecNormalize(NextDir);
    end
    else
      NextDir := Vector3(0, 0, 0);

    if (I = 0) then
      Bisector := NextDir
    else if (I = N - 1) then
      Bisector := PrevDir
    else
      Bisector := VecNormalize(PrevDir + NextDir);

    { Right-of-travel perpendicular: (Bisector.Z, 0, -Bisector.X). }
    Perp := Vector3(Bisector.Z, 0, -Bisector.X);
    PerpLen := 1.0;

    { Mitre stretch = 1/cos(half-angle); cap at MAX_MITRE_FACTOR for acute bends. }
    if (I > 0) and (I < N - 1) then
    begin
      CosHalfAngle := Abs(VecDot(NextDir, Bisector));
      if CosHalfAngle > 0.05 then
        PerpLen := 1.0 / CosHalfAngle
      else
        PerpLen := MAX_MITRE_FACTOR;
      MitreLen := HalfWidth * PerpLen;
      if MitreLen > MaxLen then
        MitreLen := MaxLen;
    end
    else
      MitreLen := HalfWidth;

    Right[I] := Pos[I] + Perp * MitreLen;
    Left[I]  := Pos[I] - Perp * MitreLen;
    { Edge Y is left for the clipper / fallback path below. }
  end;

  { int-first вход карва: контур речной ленты кольцом от источника —
    ложе режется кольцами, зигзаг чётности от квантованного треугольного
    супа уходит. Меш строится ДАЛЬШЕ как обычно: в шейдерном режиме он —
    анимированный водный шейп поверх вырезанного ложа. }
  if ABag <> nil then
  begin
    SetLength(IntRing, Length(Pos) * 2);
    for I := 0 to High(Pos) do
    begin
      IntRing[I].X := Right[I].X;
      IntRing[I].Z := Right[I].Z;
      IntRing[Length(Pos) * 2 - 1 - I].X := Left[I].X;
      IntRing[Length(Pos) * 2 - 1 - I].Z := Left[I].Z;
    end;
    BagAddRingWorld(ABag^, IntRing, True);
  end;

  if Sampler <> nil then
  begin
    { AccumLen along the centre-line (not the expanded edges) keeps V
      continuous at joints. }
    SetLength(Edges, N);
    Edges[0].AccumLen := 0;
    Edges[0].Right.X := Right[0].X;  Edges[0].Right.Z := Right[0].Z;
    Edges[0].Left.X  := Left [0].X;  Edges[0].Left.Z  := Left [0].Z;
    for I := 1 to N - 1 do
    begin
      DX := Pos[I].X - Pos[I - 1].X;
      DZ := Pos[I].Z - Pos[I - 1].Z;
      Edges[I].AccumLen := Edges[I - 1].AccumLen + Sqrt(DX * DX + DZ * DZ);
      Edges[I].Right.X := Right[I].X;  Edges[I].Right.Z := Right[I].Z;
      Edges[I].Left.X  := Left [I].X;  Edges[I].Left.Z  := Left [I].Z;
    end;

    { UVScaleY=0 — water rivers have no texture yet. UVMinX=0/MaxX=1 — water uses the full cell;
      the lane-slice mechanism is roadway-only. }
    TTerrainClipper.ProjectRibbonFromEdges(Edges,
      Sampler, Projection, WATER_LIFT_M, 0, 0.0, 1.0, Target, Progress);
  end
  else
  begin
    { Fallback: bilinear-sample Y and emit flat quads. }
    for I := 0 to N - 2 do
    begin
      RTmp := Right[I];
      LTmp := Left [I];
      RNTmp := Right[I+1];
      LNTmp := Left [I+1];
      if HM <> nil then
      begin
        { Bank-edge heights MUST come from the same source as the centreline and the terrain mesh
          (the terrain sampler), or the banks land on a different surface and water z-fights.
          SampleAtXZ does the Unproject internally. }
        if Sampler <> nil then
        begin
          RTmp.Y  := Sampler.SampleAtXZ(Projection, RTmp.X,  RTmp.Z)
                       + WATER_LIFT_M;
          LTmp.Y  := Sampler.SampleAtXZ(Projection, LTmp.X,  LTmp.Z)
                       + WATER_LIFT_M;
          RNTmp.Y := Sampler.SampleAtXZ(Projection, RNTmp.X, RNTmp.Z)
                       + WATER_LIFT_M;
          LNTmp.Y := Sampler.SampleAtXZ(Projection, LNTmp.X, LNTmp.Z)
                       + WATER_LIFT_M;
        end
        else
        begin
          RTmp.Y  := THeightmapSampler.SampleBilinear(HM,
                       Projection.Unproject(RTmp.X, RTmp.Z))  + WATER_LIFT_M;
          LTmp.Y  := THeightmapSampler.SampleBilinear(HM,
                       Projection.Unproject(LTmp.X, LTmp.Z))  + WATER_LIFT_M;
          RNTmp.Y := THeightmapSampler.SampleBilinear(HM,
                       Projection.Unproject(RNTmp.X, RNTmp.Z)) + WATER_LIFT_M;
          LNTmp.Y := THeightmapSampler.SampleBilinear(HM,
                       Projection.Unproject(LNTmp.X, LNTmp.Z)) + WATER_LIFT_M;
        end;
      end
      else
      begin
        RTmp.Y  := WATER_LIFT_M;
        LTmp.Y  := WATER_LIFT_M;
        RNTmp.Y := WATER_LIFT_M;
        LNTmp.Y := WATER_LIFT_M;
      end;
      V0R := Target.AddVertex(RTmp,  Vector3(0, 1, 0));
      V0L := Target.AddVertex(LTmp,  Vector3(0, 1, 0));
      V1L := Target.AddVertex(LNTmp, Vector3(0, 1, 0));
      V1R := Target.AddVertex(RNTmp, Vector3(0, 1, 0));
      Target.AddQuad(V0R, V0L, V1L, V1R);
    end;
  end;

  finally
    Target.CurrentOsmId := 0;
  end;
end;

class function TWaterBuilder.BuildAll(Dataset: TOSMDataset; HM: THeightmap;
  Projection: TLocalProjection;
  Sampler: TTerrainSampler;
  LogProc: TLogProc;
  ABag: PLatRingBag): TMesh;
var
  Way: TOSMWay;
  HalfW: Single;
  Progress: TClipperProgress;
  WayTotal: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1132);{$ENDIF}
  Result := TMesh.Create('water_ways_all');

  WayTotal := 0;
  for Way in Dataset.Ways.Values do
    if (Way <> nil) and Way.Tags.HasKey('waterway') and
       (Way.Tags.GetLower('area') <> 'yes') and (not Way.IsClosed)
       and not Underground(Way.Tags) then
      Inc(WayTotal);
  InitClipperProgress(Progress, LogProc, 'water', WayTotal);

  try
    for Way in Dataset.Ways.Values do
      if Way.Tags.HasKey('waterway') then
      begin
        { Linear features only — area=yes / closed polygons go through the
          landuse builder. }
        if (Way.Tags.GetLower('area') = 'yes') or Way.IsClosed or Underground(Way.Tags) then
          Continue;

        Inc(Progress.PolyIdx);
        ReportClipperProgress(Progress);

        HalfW := ClassifyWidth(Way.Tags) * 0.5;
        BuildRibbon(Way, Dataset, HM, Projection, HalfW, Result, Sampler,
          @Progress, ABag);
      end;
  except
    Result.Free;
    raise;
  end;
end;

end.
