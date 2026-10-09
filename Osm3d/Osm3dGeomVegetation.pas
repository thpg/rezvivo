unit Osm3dGeomVegetation;

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
  Osm3dOsmData,
  Osm3dOsmTagUtils,
  Math,
  CastleVectors,
  Osm3dGeoMath,
  Osm3dGeomUtils,
  Osm3dHeightmap,
  Osm3dGeomTerrain,         { TTerrainSampler — эталонный источник высоты }
  Osm3dGeomRoads,
  Osm3dTileX3D,
  Osm3dStudioSettings       { SPLIT_THRESHOLD_M, TILE_SIZE_M, MAX_BBOX_M, ROAD_CLEAR_M }
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
;

type
  { Botanical species. ttUnknown reserved for missing/unrecognised tags
    — the pipeline defaults it to ttGenericBroadleaved. }
  TTreeType = (
    ttUnknown,
    ttBeech,
    ttFir,
    ttLinden,
    ttOak,
    ttGenericBroadleaved,
    ttGenericNeedleleaved
  );

  TTreeTextureIdArray = array of Integer;

  { Used for randomisation in createTree. }
  TTreeHeightRange = record
    MinH, MaxH: Double;
  end;

const
  { Texture2DArray layers: 0 beech, 1 fir, 2 linden0, 3 linden1, 4 oak. }
  TREE_TEXTURE_COUNT = 5;

  { Fallback when species cannot be determined — beech (most generic broadleaved). }
  TREE_DEFAULT_TEXTURE_ID = 0;

{ Species from OSM tags. genus/genus:en first; falls back to leaf_type
  (needleleaved → ttGenericNeedleleaved, otherwise broadleaved). }
function GetTreeTypeFromTags(const Tags: TOSMTags): TTreeType;

{ Tree height from OSM tags. Cascade:
    1. (height || est_height) - min_height
    2. diameter_crown
    3. diameter (default mm) or circumference / π × 23.0 → crown width
    4. If width is plausible (0.5..100 m), height = width × 2.0
  Returns 0 when none of the above yields a usable value. }
function GetTreeHeight(const Tags: TOSMTags): Double;

{ TextureId options for the species. ttLinden has (2,3); generic
  broadleaved has (0,2,3,4); generic needleleaved has (1). One is
  chosen randomly during scatter. Length 1..4. }
function GetTreeTextureIdsFromType(TreeType: TTreeType): TTreeTextureIdArray;

{ Realistic height range (m) for a texture layer. }
function GetTreeHeightRange(TextureId: Integer): TTreeHeightRange;

{ Billboard scale factor — different textures fill the 512×512 canvas
  differently (oak fills almost the whole canvas; fir is narrow). }
function GetTreeTextureScaling(TextureId: Integer): Double;

type
  { CPU instance. The first 24 bytes retain the streets-gl InstancedTree.ts layout:
      0  (12) instancePosition vec3
      12 (4)  instanceScale
      16 (4)  instanceRotation (rad around Y)
      20 (4)  instanceSeed — holds TextureId as Single (read back via int()), per the upstream
              convention; SeedAsTexId is that field. }
  TTreeInstance = packed record
    X, Y, Z:      Single;     { 0..11  instancePosition (vec3) }
    Scale:        Single;     { 12..15 instanceScale }
    Rotation:     Single;     { 16..19 instanceRotation (rad) }
    SeedAsTexId:  Single;     { 20..23 instanceSeed == TextureId as float }
    { CPU-only metadata; the legacy VBO still packs the first 24 bytes. }
    Procedural: TProceduralTreeTag;
  end;
  PTreeInstance = ^TTreeInstance;

  TTreeInstanceArray = array of TTreeInstance;
  TTreeGPUInstance = packed array[0..5] of Single;
  TTreeGPUInstanceArray = array of TTreeGPUInstance;

  { Returns terrain height in metres on the same vertical datum as the
    rest of the scene. nil or NaN result → Y left unchanged (0).
    The pipeline passes a closure over THeightmapSampler. }
  TTerrainHeightFn = function(X, Z: Double): Double of object;

const
  { glVertexAttribPointer stride; matches streets-gl InstancedTree.ts. }
  TREE_INSTANCE_STRIDE = 24;

  TREE_INST_OFFSET_POSITION = 0;
  TREE_INST_OFFSET_SCALE    = 12;
  TREE_INST_OFFSET_ROTATION = 16;
  TREE_INST_OFFSET_SEED     = 20;

{ Scatter trees across a polygon and assign per-instance attributes.
  Y is 0 for every instance; call ApplyTerrainHeights to place them.

  CellSizeMeters — scatter density; typical: forest 30-40 m (default 40),
                   shrubbery 60-80 m (see ScatterShrubs).
  TaggedHeight  — if > 0, fixed height for ALL trees (e.g. OSM forest
                   with height=*); otherwise per-species randomisation. }
function ScatterTrees(const MP: TPolygonMultipolygon;
  Species: TTreeType;
  CellSizeMeters: Double = 40.0;
  TaggedHeight: Double = 0.0): TTreeInstanceArray;

{ Shrub variant. Fixed height range 0.9..1.15 m (streets-gl createShrub);
  species-independent. Returned TextureId is always 0 (shrubs have their
  own texture). }
function ScatterShrubs(const MP: TPolygonMultipolygon;
  CellSizeMeters: Double = 80.0): TTreeInstanceArray;

{ One instance for a single OSM node natural=tree. Species classified
  deterministically from tags; texture layer selected; height read
  from tags if present, otherwise sampled from species range.
  Y already includes terrain. NodeId seeds reproducible random
  rotation / texture selection. }
function MakeSingleTreeInstance(NodeId: Int64; const Pos: TVector3;
  const Tags: TOSMTags): TTreeInstance;

{ Fills Y for all instances via the terrain callback. Safe on nil /
  empty Trees; NaN/Inf from the callback are ignored. }
procedure ApplyTerrainHeights(var Trees: TTreeInstanceArray;
  HeightFn: TTerrainHeightFn);

{ Raw pointer + byte size for glBufferData. nil / 0 on empty. }
procedure GetTreeInstanceBufferRaw(const Trees: TTreeInstanceArray;
  out PackedGPU: TTreeGPUInstanceArray; out Ptr: Pointer; out ByteSize: SizeUInt);

type
  { Per-tile bucket, one per non-empty TileSize cell. Floor(X/TileSize)/Floor(Z/TileSize) matches
    the assembler split so renderer and host distance-culling agree. Within a tile original order is
    kept; empty tiles are omitted. }
  TTreeInstanceTile = record
    CellX, CellZ:     Integer;
    CenterX, CenterZ: Single;
    Instances:        TTreeInstanceArray;
  end;
  TTreeInstanceTileArray = array of TTreeInstanceTile;

type
  TScatterRandom = function: Double of object;

  TPolygonScatter = class
  public
    class function Scatter(const MP: TPolygonMultipolygon;
      CellSizeMeters: Double;
      JitterFraction: Double = 0.5;
      RandomFn: TScatterRandom = nil): TScatterPointArray;
  end;

  TGridCell = record
    CX, CY: Integer;
  end;
  TGridCellArray = array of TGridCell;

type
  TForestBuildResult = record
    Trees:  TTreeInstanceArray;
    Shrubs: TTreeInstanceArray;
  end;

  TForestBuildOptions = record
    CellMetersForest:  Double;
    CellMetersShrubs:  Double;
    SkipShrubs:        Boolean;
    SkipTrees:         Boolean;
    LiftAboveTerrain:  Double;
    class function Defaults: TForestBuildOptions; static;
  end;

  TForestInstanceBuilder = class
  public
    { Terrain — эталонный источник высоты (та же поверхность, что у
      меша земли и зданий). nil → fallback на билинейный heightmap. }
    class function BuildAll(Dataset: TOSMDataset;
      HM: THeightmap; Projection: TLocalProjection;
      const Options: TForestBuildOptions;
      Terrain: TTerrainSampler = nil;
      LogProc: TLogProc = nil): TForestBuildResult;

    class function BuildAllDefaults(Dataset: TOSMDataset;
      HM: THeightmap; Projection: TLocalProjection;
      Terrain: TTerrainSampler = nil;
      LogProc: TLogProc = nil): TForestBuildResult;
  end;

{ ROAD_CLEAR_M (extra tree clearance past a road's half-width) lives in Osm3dStudioSettings. }

type
  TRoadSeg = record
    X0, Z0:    Single;
    DX, DZ:    Single;
    LenSq:     Single;
    HalfW:     Single;        { half-width + ROAD_CLEAR_M }
    HalfW0, HalfW1: Single;
    HalfWSq:   Single;
    { Segment AABB expanded by HalfW — fast candidate filter. }
    BBoxMinX, BBoxMaxX: Single;
    BBoxMinZ, BBoxMaxZ: Single;
  end;

  TRoadSegArray = array of TRoadSeg;

  TRoadExclusionMask = class
  private
    FSegs:    TRoadSegArray;
    FCount:   Integer;
    procedure GrowSegs;
  public
    constructor Create;

    { HalfWidth = nominal half-width (ClassWidth / 2); ROAD_CLEAR_M
      is added internally. }
    procedure AddSegment(X0, Z0, X1, Z1, HalfWidth: Single; HalfWidthEnd:Single=-1);

    procedure BuildFromDataset(Dataset: TOSMDataset; Proj: TLocalProjection);

    { Compact subset whose AABB overlaps the bbox. Cheap linear scan
      O(FCount). When Count = 0 the per-point check can be skipped. }
    procedure CollectCandidates(
      MinX, MinZ, MaxX, MaxZ: Single;
      out Cands: TRoadSegArray; out Count: Integer);

    { True when (X,Z) lies inside any segment in Cands. O(Count) —
      fast when Count is small (0-15 typical). }
    class function IsOnRoad(X, Z: Single;
      const Cands: TRoadSegArray; Count: Integer): Boolean; static;

    property SegmentCount: Integer read FCount;
  end;

function BuildRoadMask(Dataset: TOSMDataset;
                       Proj: TLocalProjection): TRoadExclusionMask;

{ Removes every TTreeInstance whose (X,Z) falls inside the road
  corridor; edits Trees in-place (compact-shift). Uses the per-polygon
  candidate list — call CollectCandidates first. Returns count removed. }
function FilterTreesByRoadCandidates(var Trees: TTreeInstanceArray;
  const Cands: TRoadSegArray; CandCount: Integer): Integer;

{ Convert a TForestBuildResult (geometry-pipeline output) into the flat
  TTileTreeRecArray the geo-tile cache stores and TTileStreamer transports.
  Trees and Shrubs are merged into one array; IsShrub distinguishes them. }
function ForestToTileTrees(
  const Forest: TForestBuildResult): TTileTreeRecArray;

implementation

uses Generics.Collections, Osm3dProceduralTreeData, Osm3dVegetationLayout;

{ Lookup tables (exact port from streets-gl utils.ts) }

const
  { Realistic height ranges (m) per texture layer. }
  HEIGHT_RANGE_MIN: array[0..TREE_TEXTURE_COUNT - 1] of Double =
    (14, 25, 14, 14, 12);
  HEIGHT_RANGE_MAX: array[0..TREE_TEXTURE_COUNT - 1] of Double =
    (18, 35, 18, 18, 15);

  { streets-gl createTreeTexture.ts. }
  TEXTURE_SCALING: array[0..TREE_TEXTURE_COUNT - 1] of Double =
    (1.35, 1.06, 1.19, 1.02, 1.43);

{ String comparison rather than the JS Record map used upstream. }
function GenusStringToTreeType(const Genus: string): TTreeType;
var G: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(418);{$ENDIF}
  G := LowerCase(Trim(Genus));
  if G = 'beech'  then Exit(ttBeech);
  if G = 'fir'    then Exit(ttFir);
  if G = 'linden' then Exit(ttLinden);
  if G = 'oak'    then Exit(ttOak);
  Result := ttUnknown;
end;

function GetTreeTypeFromTags(const Tags: TOSMTags): TTreeType;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(419);{$ENDIF}
  if Tags = nil then Exit(ttGenericBroadleaved);

  Result := GenusStringToTreeType(Tags.Get('genus'));
  if Result <> ttUnknown then Exit;

  Result := GenusStringToTreeType(Tags.Get('genus:en'));
  if Result <> ttUnknown then Exit;

  if Tags.GetLower('leaf_type') = 'needleleaved' then
    Exit(ttGenericNeedleleaved);

  { Default — handles leaf_type=broadleaved/mixed/unknown, or no tag. }
  Result := ttGenericBroadleaved;
end;

function GetTreeHeight(const Tags: TOSMTags): Double;
var
  MinHeight, Height, Width, Diameter, Circumference: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(420);{$ENDIF}
  Result := 0;
  if Tags = nil then Exit;

  MinHeight := ParseOSMMeters(Tags.Get('min_height'));
  if MinHeight < 0 then MinHeight := 0;

  { (height || est_height) - min_height }
  Height := ParseOSMMeters(Tags.Get('height'));
  if Height = 0 then
    Height := ParseOSMMeters(Tags.Get('est_height'));
  if Height > 0 then
    Height := Height - MinHeight;

  if Height > 0 then
  begin
    Result := Height;
    Exit;
  end;

  Width := ParseOSMMeters(Tags.Get('diameter_crown'));

  { OSM convention: diameter without a unit = mm, so DefaultFactor=0.001. }
  if Width = 0 then
  begin
    Diameter := ParseOSMMeters(Tags.Get('diameter'), 0.001);
    if Diameter = 0 then
    begin
      Circumference := ParseOSMMeters(Tags.Get('circumference'));
      if Circumference > 0 then
        Diameter := Circumference / Pi;
    end;
    { 23× — empirical constant from streets-gl. }
    Width := Diameter * 23.0;
  end;

  if (Width > 0.5) and (Width < 100) then
    Result := Width * 2.0;
end;

function GetTreeTextureIdsFromType(TreeType: TTreeType): TTreeTextureIdArray;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(421);{$ENDIF}
  case TreeType of
    ttBeech:               Result := TTreeTextureIdArray.Create(0);
    ttFir:                 Result := TTreeTextureIdArray.Create(1);
    ttLinden:              Result := TTreeTextureIdArray.Create(2, 3);
    ttOak:                 Result := TTreeTextureIdArray.Create(4);
    ttGenericNeedleleaved: Result := TTreeTextureIdArray.Create(1);
    ttGenericBroadleaved,
    ttUnknown:             Result := TTreeTextureIdArray.Create(0, 2, 3, 4);
  else
    Result := TTreeTextureIdArray.Create(TREE_DEFAULT_TEXTURE_ID);
  end;
end;

function GetTreeHeightRange(TextureId: Integer): TTreeHeightRange;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(422);{$ENDIF}
  if (TextureId < 0) or (TextureId >= TREE_TEXTURE_COUNT) then
    TextureId := TREE_DEFAULT_TEXTURE_ID;
  Result.MinH := HEIGHT_RANGE_MIN[TextureId];
  Result.MaxH := HEIGHT_RANGE_MAX[TextureId];
end;

function GetTreeTextureScaling(TextureId: Integer): Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(423);{$ENDIF}
  if (TextureId < 0) or (TextureId >= TREE_TEXTURE_COUNT) then
    TextureId := TREE_DEFAULT_TEXTURE_ID;
  Result := TEXTURE_SCALING[TextureId];
end;

{ SeededRandom — port of Robert Jenkins 32-bit hash from streets-gl.
  Each Generate() runs several hash rounds and returns [0..1).
  Deterministic: same seed → same sequence. }
type
  TSeededRandom = record
    Seed: LongWord;
    function Generate: Double;
  end;

function TSeededRandom.Generate: Double;
{$PUSH}{$WARN 4079 OFF}    { wrapping arithmetic is intentional in this hash }
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(425);{$ENDIF}
  Seed := LongWord(Seed + $7ED55D16) + LongWord(Seed shl 12);
  Seed := LongWord(Seed xor $C761C23C) xor (Seed shr 19);
  Seed := LongWord(Seed + $165667B1) + LongWord(Seed shl 5);
  Seed := LongWord(Seed + $D3A2646C) xor LongWord(Seed shl 9);
  Seed := LongWord(Seed + $FD7046C5) + LongWord(Seed shl 3);
  Seed := LongWord(Seed xor $B55A4F09) xor (Seed shr 16);
  Result := (Seed and $FFFFFFF) / $10000000;
end;
{$POP}

function MakeSeededRandom(InitialSeed: LongWord): TSeededRandom;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(426);{$ENDIF}
  if InitialSeed = 0 then
    Result.Seed := $2F6E2B1   { streets-gl SeededRandom default }
  else
    Result.Seed := InitialSeed;
end;

{ Seed for a scatter point: streets-gl convention Floor(X) + Floor(Z). }
function MakeRngForPoint(const P: TScatterPoint): TSeededRandom; inline;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(427);{$ENDIF}
  Result := MakeSeededRandom(LongWord(Floor(P.X)) + LongWord(Floor(P.Z)));
end;

function ScatterTrees(const MP: TPolygonMultipolygon;
  Species: TTreeType; CellSizeMeters, TaggedHeight: Double): TTreeInstanceArray;
var
  Points:    TScatterPointArray;
  TexIds:    TTreeTextureIdArray;
  HRange:    TTreeHeightRange;
  Rng:       TSeededRandom;
  I:         Integer;
  TexId:     Integer;
  TexScale:  Double;
  Height:    Double;
  Inst:      TTreeInstance;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(428);{$ENDIF}
  Result := nil;
  Points := TPolygonScatter.Scatter(MP, CellSizeMeters);
  if Length(Points) = 0 then Exit;

  TexIds := GetTreeTextureIdsFromType(Species);
  SetLength(Result, Length(Points));

  for I := 0 to High(Points) do
  begin
    Rng := MakeRngForPoint(Points[I]);

    Inst.Procedural := Default(TProceduralTreeTag);
    Inst.Rotation := Rng.Generate * 2 * PI;

    { TextureId randomly chosen from the species list (stored as Single). }
    TexId := TexIds[Floor(Rng.Generate * Length(TexIds))];
    Inst.SeedAsTexId := Single(TexId);

    TexScale := GetTreeTextureScaling(TexId);

    if TaggedHeight > 0 then
      Height := TaggedHeight
    else
    begin
      HRange := GetTreeHeightRange(TexId);
      Height := HRange.MinH + Rng.Generate * (HRange.MaxH - HRange.MinH);
    end;

    Inst.Scale := Single(Height * TexScale);
    Inst.X := Single(Points[I].X);
    Inst.Y := 0;     { ApplyTerrainHeights will fill }
    Inst.Z := Single(Points[I].Z);

    Result[I] := Inst;
  end;
end;

function ScatterShrubs(const MP: TPolygonMultipolygon;
  CellSizeMeters: Double): TTreeInstanceArray;
var
  Points: TScatterPointArray;
  Rng:    TSeededRandom;
  I:      Integer;
  Height: Double;
  Inst:   TTreeInstance;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(429);{$ENDIF}
  Result := nil;
  Points := TPolygonScatter.Scatter(MP, CellSizeMeters);
  if Length(Points) = 0 then Exit;

  SetLength(Result, Length(Points));

  for I := 0 to High(Points) do
  begin
    Rng := MakeRngForPoint(Points[I]);

    { streets-gl createShrub: height = 0.9 + random*0.25 → 0.9..1.15 m. }
    Inst.Procedural := Default(TProceduralTreeTag);
    Height := 0.9 + Rng.Generate * 0.25;

    Inst.Rotation := Rng.Generate * 2 * PI;
    Inst.X := Single(Points[I].X);
    Inst.Y := 0;
    Inst.Z := Single(Points[I].Z);
    Inst.Scale := Single(Height);
    Inst.SeedAsTexId := 0;    { shrubs use their own texture, index 0 }

    Result[I] := Inst;
  end;
end;

procedure ApplyTerrainHeights(var Trees: TTreeInstanceArray;
  HeightFn: TTerrainHeightFn);
var
  I: Integer;
  H: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(430);{$ENDIF}
  if (Trees = nil) or (HeightFn = nil) then Exit;

  for I := 0 to High(Trees) do
  begin
    H := HeightFn(Trees[I].X, Trees[I].Z);
    if not (IsNan(H) or IsInfinite(H)) then
      Trees[I].Y := Single(H);
  end;
end;

function MakeSingleTreeInstance(NodeId: Int64; const Pos: TVector3;
  const Tags: TOSMTags): TTreeInstance;
var
  Species:  TTreeType;
  TexIds:   TTreeTextureIdArray;
  TexId:    Integer;
  TexScale: Double;
  TaggedH:  Double;
  Height:   Double;
  HRange:   TTreeHeightRange;
  Rng:      TSeededRandom;
  SeedHash: LongWord;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(431);{$ENDIF}
  { Fold NodeId to 32 bits via XOR of halves so positive/negative IDs
    produce varied seeds. }
  SeedHash := LongWord(NodeId) xor LongWord(NodeId shr 32);
  if SeedHash = 0 then SeedHash := 1;
  Rng := MakeSeededRandom(SeedHash);

  Species := GetTreeTypeFromTags(Tags);
  TexIds  := GetTreeTextureIdsFromType(Species);
  TexId   := TexIds[Floor(Rng.Generate * Length(TexIds))];
  TexScale := GetTreeTextureScaling(TexId);

  TaggedH := GetTreeHeight(Tags);
  if TaggedH > 0 then
    Height := TaggedH
  else
  begin
    HRange := GetTreeHeightRange(TexId);
    Height := HRange.MinH + Rng.Generate * (HRange.MaxH - HRange.MinH);
  end;

  Result.X           := Pos.X;
  Result.Y           := Pos.Y;
  Result.Z           := Pos.Z;
  Result.Scale       := Single(Height * TexScale);
  Result.Rotation    := Rng.Generate * 2 * PI;
  Result.SeedAsTexId := Single(TexId);
  Result.Procedural := Default(TProceduralTreeTag);
end;

procedure GetTreeInstanceBufferRaw(const Trees: TTreeInstanceArray;
  out PackedGPU: TTreeGPUInstanceArray; out Ptr: Pointer; out ByteSize: SizeUInt);
var I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(432);{$ENDIF}
  if Length(Trees) = 0 then
  begin
    Ptr := nil;
    ByteSize := 0;
    Exit;
  end;
  SetLength(PackedGPU, Length(Trees));
  for I := 0 to High(Trees) do Move(Trees[I].X, PackedGPU[I][0], TREE_INSTANCE_STRIDE);
  Ptr := @PackedGPU[0];
  ByteSize := Length(Trees) * TREE_INSTANCE_STRIDE;
end;

type
  TIntWorkArray = array of Integer;
  TCellKey = QWord;

  TRingBBox = record
    MinX, MaxX: Double;
    MinZ, MaxZ: Double;
  end;
  TRingBBoxArray = array of TRingBBox;

  TCellHashSet = class
  private
    FKeys: array of TCellKey;
    FUsed: array of Byte;
    FCount: Integer;
    FThreshold: Integer;

    procedure InitCapacity(AMinCapacity: Integer);
    procedure Rehash(ANewCapacity: Integer);
  public
    constructor Create(AInitialCapacity: Integer);
    function AddNew(const Key: TCellKey): Boolean; inline;
    property Count: Integer read FCount;
  end;

function SignI(D: Double): Integer; inline;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(439);{$ENDIF}
  if D > 0 then Result := 1
  else if D < 0 then Result := -1
  else Result := 0;
end;

function PackCellKey(const CX, CY: Integer): TCellKey; inline;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(440);{$ENDIF}
  Result := (QWord(LongWord(CX)) shl 32) or QWord(LongWord(CY));
end;

{ Murmur-style hash mix: the 64-bit wrapping multiply is intentional. Disable overflow/range
  checks locally so a build with global {$Q+} doesn't trap the wrap and crash the worker. }
{$push}
{$Q-}{$R-}
function HashCellKey(K: TCellKey): TCellKey; inline;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(441);{$ENDIF}
  K := K xor (K shr 32);
  K := K xor (K shr 16);
  K := K * QWord(2246822519);
  K := K xor (K shr 13);
  K := K * QWord(3266489917);
  K := K xor (K shr 16);
  Result := K;
end;
{$pop}

function EstimateCellCapacity(const B: TRingBBox; CellSizeMeters: Double): Integer;
var
  W, H, Est: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(442);{$ENDIF}
  Result := 4096;
  if CellSizeMeters <= 0 then Exit;

  W := (B.MaxX - B.MinX) / CellSizeMeters + 2.0;
  H := (B.MaxZ - B.MinZ) / CellSizeMeters + 2.0;
  if W < 1.0 then W := 1.0;
  if H < 1.0 then H := 1.0;

  Est := W * H;
  if Est < 4096.0 then Result := 4096
  else if Est > 1048576.0 then Result := 1048576
  else Result := Ceil(Est);
end;

procedure EnsureGridCapacity(var Arr: TGridCellArray; Needed: Integer); inline;
var NewCap: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(443);{$ENDIF}
  if Length(Arr) >= Needed then Exit;
  NewCap := Length(Arr);
  if NewCap < 32 then NewCap := 32;
  { NewCap*2 переполняет Integer при NewCap > MaxInt/2 — растим
    осторожно, с насыщением на MaxInt вместо переполнения. }
  while NewCap < Needed do
  begin
    if NewCap > (MaxInt div 2) then
    begin
      NewCap := MaxInt;
      Break;
    end;
    NewCap := NewCap * 2;
  end;
  SetLength(Arr, NewCap);
end;

procedure PushGridCell(var Arr: TGridCellArray; var Count: Integer;
  CX, CY: Integer); inline;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(444);{$ENDIF}
  EnsureGridCapacity(Arr, Count + 1);
  Arr[Count].CX := CX;
  Arr[Count].CY := CY;
  Inc(Count);
end;

function MakeRingBBox(const R: TPolygonRing): TRingBBox;
var I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(445);{$ENDIF}
  Result.MinX := R[0].X;
  Result.MaxX := R[0].X;
  Result.MinZ := R[0].Z;
  Result.MaxZ := R[0].Z;
  for I := 1 to High(R) do
  begin
    if R[I].X < Result.MinX then Result.MinX := R[I].X;
    if R[I].X > Result.MaxX then Result.MaxX := R[I].X;
    if R[I].Z < Result.MinZ then Result.MinZ := R[I].Z;
    if R[I].Z > Result.MaxZ then Result.MaxZ := R[I].Z;
  end;
end;

function BBoxContainsPoint(const B: TRingBBox;
  const P: TScatterPoint): Boolean; inline;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(446);{$ENDIF}
  Result :=
    (P.X >= B.MinX) and (P.X <= B.MaxX) and
    (P.Z >= B.MinZ) and (P.Z <= B.MaxZ);
end;

procedure TCellHashSet.InitCapacity(AMinCapacity: Integer);
const
  { Жёсткий потолок таблицы ячеек. 2^26 ≈ 67M слотов — заведомо больше,
    чем может понадобиться легальному тайлу леса; служит для защиты
    от переполнения Integer при удвоении (Cap shl 1, Cap*7). }
  MAX_CELL_CAP = 1 shl 26;
var Cap: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(447);{$ENDIF}
  if AMinCapacity < 16 then AMinCapacity := 16;
  if AMinCapacity > MAX_CELL_CAP then AMinCapacity := MAX_CELL_CAP;
  Cap := 16;
  while (Cap < AMinCapacity) and (Cap < MAX_CELL_CAP) do
    Cap := Cap shl 1;

  SetLength(FKeys, Cap);
  SetLength(FUsed, Cap);

  FCount := 0;
  { (Cap*7) div 10 переполнилось бы при больших Cap — считаем в Int64. }
  FThreshold := Integer((Int64(Cap) * 7) div 10);
  if FThreshold < 1 then FThreshold := 1;
end;

procedure TCellHashSet.Rehash(ANewCapacity: Integer);
var
  OldKeys: array of TCellKey;
  OldUsed: array of Byte;
  OldCap, I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(448);{$ENDIF}
  OldKeys := FKeys;
  OldUsed := FUsed;
  OldCap := Length(OldKeys);

  { SetLength preserves the old prefix, including occupied flags. Rehash
    must start with an empty table; otherwise stale entries fill every slot
    while FCount still reports spare capacity and AddNew loops forever. }
  FKeys := nil;
  FUsed := nil;
  InitCapacity(ANewCapacity);
  if Length(FKeys) <= OldCap then
    raise EOutOfMemory.Create('Vegetation scatter cell table capacity exceeded');

  for I := 0 to OldCap - 1 do
    if OldUsed[I] <> 0 then
      AddNew(OldKeys[I]);
end;

constructor TCellHashSet.Create(AInitialCapacity: Integer);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1155);{$ENDIF}
  inherited Create;
  InitCapacity(AInitialCapacity);
end;

function TCellHashSet.AddNew(const Key: TCellKey): Boolean;
var Mask, Idx: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(449);{$ENDIF}
  if FCount >= FThreshold then
    { Length(FKeys)*2 в Int64 — InitCapacity всё равно зажмёт по
      MAX_CELL_CAP, но само умножение не должно переполниться. }
    Rehash(Integer(Math.Min(Int64(Length(FKeys)) * 2, Int64(MaxInt))));

  Mask := Length(FKeys) - 1;
  Idx := Integer(HashCellKey(Key) and QWord(Mask));

  while FUsed[Idx] <> 0 do
  begin
    if FKeys[Idx] = Key then Exit(False);
    Idx := (Idx + 1) and Mask;
  end;

  FUsed[Idx] := 1;
  FKeys[Idx] := Key;
  Inc(FCount);
  Result := True;
end;

procedure TouchRowBounds(CX, CY, MinY: Integer;
  var RowMinX, RowMaxX: TIntWorkArray); inline;
var Idx: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(452);{$ENDIF}
  Idx := CY - MinY;
  if (Idx < 0) or (Idx > High(RowMinX)) then Exit;
  if CX < RowMinX[Idx] then RowMinX[Idx] := CX;
  if CX > RowMaxX[Idx] then RowMaxX[Idx] := CX;
end;

type
  { Контекст обхода WalkGridCells для AddLineToRowBounds. }
  TRowBoundsWalkCtx = record
    MinY:    Integer;
    RowMinX: ^TIntWorkArray;
    RowMaxX: ^TIntWorkArray;
  end;

procedure RowBoundsWalkVisit(AX, AZ: Integer; Ctx: Pointer);
var
  C: ^TRowBoundsWalkCtx;
begin
  C := Ctx;
  TouchRowBounds(AX, AZ, C^.MinY, C^.RowMinX^, C^.RowMaxX^);
end;

procedure AddLineToRowBounds(const A, B: TScatterPoint;
  MinY: Integer;
  var RowMinX, RowMaxX: TIntWorkArray);
var
  Ctx: TRowBoundsWalkCtx;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(453);{$ENDIF}
  Ctx.MinY    := MinY;
  Ctx.RowMinX := @RowMinX;
  Ctx.RowMaxX := @RowMaxX;
  WalkGridCells(A.X, A.Z, B.X, B.Z, @RowBoundsWalkVisit, @Ctx);
end;

procedure GetCellsUnderTriangleReuse(const A, B, C: TScatterPoint;
  ScaleX, ScaleY: Double;
  var Buffer: TGridCellArray;
  var RowMinX, RowMaxX: TIntWorkArray;
  out Count: Integer);
const
  { Degenerate-triangle guard. Earcut on a dirty ring can emit a triangle with a vertex far
    outside the polygon, giving millions of rows -> Integer overflow in EnsureGridCapacity and a
    worker crash. A legal forest-tile triangle at CellSize~15 m spans hundreds of cells per axis. }
  MAX_ROWS_PER_TRIANGLE = 8192;
  MAX_COLS_PER_ROW      = 8192;
var
  PA, PB, PC: TScatterPoint;
  MinY, MaxY, RowCount: Integer;
  I, X, Y: Integer;
  RowLo, RowHi: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(454);{$ENDIF}
  Count := 0;

  PA.X := A.X * ScaleX;  PA.Z := A.Z * ScaleY;
  PB.X := B.X * ScaleX;  PB.Z := B.Z * ScaleY;
  PC.X := C.X * ScaleX;  PC.Z := C.Z * ScaleY;

  MinY := Floor(Math.Min(PA.Z, Math.Min(PB.Z, PC.Z)));
  MaxY := Floor(Math.Max(PA.Z, Math.Max(PB.Z, PC.Z)));
  if MaxY < MinY then Exit;

  RowCount := MaxY - MinY + 1;
  if RowCount <= 0 then Exit;
  { Вырожденный треугольник — пропускаем целиком, не его рассаживаем. }
  if RowCount > MAX_ROWS_PER_TRIANGLE then Exit;

  SetLength(RowMinX, RowCount);
  SetLength(RowMaxX, RowCount);
  for I := 0 to RowCount - 1 do
  begin
    RowMinX[I] := MaxInt;
    RowMaxX[I] := -MaxInt;
  end;

  AddLineToRowBounds(PA, PB, MinY, RowMinX, RowMaxX);
  AddLineToRowBounds(PB, PC, MinY, RowMinX, RowMaxX);
  AddLineToRowBounds(PC, PA, MinY, RowMinX, RowMaxX);

  for I := 0 to RowCount - 1 do
  begin
    RowLo := RowMinX[I];
    RowHi := RowMaxX[I];
    if RowLo > RowHi then Continue;
    { Аномально широкая строка — тот же признак битого треугольника. }
    if (RowHi - RowLo) > MAX_COLS_PER_ROW then Continue;

    Y := MinY + I;
    for X := RowLo to RowHi do
      PushGridCell(Buffer, Count, X, Y);
  end;
end;

procedure FlattenForEarcut(const MP: TPolygonMultipolygon;
  out Data: TDoubleArray; out HoleIndices: TIntArray);
var
  TotalVerts, I, J, DataIdx, HoleIdx, VertIdx: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(456);{$ENDIF}
  TotalVerts := Length(MP.Outer);
  for I := 0 to High(MP.Inners) do
    Inc(TotalVerts, Length(MP.Inners[I]));

  SetLength(Data, TotalVerts * 2);
  SetLength(HoleIndices, Length(MP.Inners));

  DataIdx := 0;
  VertIdx := 0;

  for I := 0 to High(MP.Outer) do
  begin
    Data[DataIdx] := MP.Outer[I].X;
    Data[DataIdx + 1] := MP.Outer[I].Z;
    Inc(DataIdx, 2);
    Inc(VertIdx);
  end;

  HoleIdx := 0;
  for I := 0 to High(MP.Inners) do
  begin
    HoleIndices[HoleIdx] := VertIdx;
    Inc(HoleIdx);

    for J := 0 to High(MP.Inners[I]) do
    begin
      Data[DataIdx] := MP.Inners[I][J].X;
      Data[DataIdx + 1] := MP.Inners[I][J].Z;
      Inc(DataIdx, 2);
      Inc(VertIdx);
    end;
  end;
end;

class function TPolygonScatter.Scatter(const MP: TPolygonMultipolygon;
  CellSizeMeters: Double;
  JitterFraction: Double;
  RandomFn: TScatterRandom): TScatterPointArray;
var
  Data:        TDoubleArray;
  HoleIndices: TIntArray;
  Triangles:   TIntArray;
  ScaleXY:     Double;

  I, J, H:     Integer;
  A, B, C:     TScatterPoint;

  Cells:       TGridCellArray;
  CellCount:   Integer;
  RowMinX:     TIntWorkArray;
  RowMaxX:     TIntWorkArray;

  CellSet:     TCellHashSet;
  Key:         TCellKey;

  Pt:          TScatterPoint;
  RandJ:       Double;
  IsInside:    Boolean;
  CellRng:     TSeededRandom;

  OuterBBox:   TRingBBox;
  InnerBBoxes: TRingBBoxArray;

  ResultCount: Integer;
  ResultCap:   Integer;

  { Jitter seed from the cell indices: the cell grid is anchored to world
    coordinates, so the placement is stable across sessions, tiles and
    thread interleavings (no global Random). }
  function CellJitterSeed(const CX, CY: Integer): LongWord; inline;
  begin
    Result := LongWord(CX) * $9E3779B1 + LongWord(CY) * $85EBCA6B + $27D4EB2F;
  end;

  function NextRand: Double; inline;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(457);{$ENDIF}
    if RandomFn <> nil then
      Result := RandomFn()
    else
      Result := CellRng.Generate;
  end;

  procedure PushPoint(const P: TScatterPoint); inline;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(458);{$ENDIF}
    if ResultCount >= ResultCap then
    begin
      if ResultCap = 0 then ResultCap := 256
      else if ResultCap > (MaxInt div 2) then ResultCap := MaxInt
      else ResultCap := ResultCap * 2;
      SetLength(Result, ResultCap);
    end;
    Result[ResultCount] := P;
    Inc(ResultCount);
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1156);{$ENDIF}
  Result := nil;
  ResultCount := 0;
  ResultCap := 0;

  if Length(MP.Outer) < 3 then Exit;
  if CellSizeMeters <= 0 then Exit;

  { Corrupt-MP guard: an absurd hole count means garbage in MP.Inners; the SetLength below would
    overflow. A legal landuse polygon has at most tens of inner rings. }
  if (Length(MP.Inners) < 0) or (Length(MP.Inners) > 65536) then
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1157);{$ENDIF}
    Exit;
  end;

  ScaleXY := 1.0 / CellSizeMeters;

  OuterBBox := MakeRingBBox(MP.Outer);

  SetLength(InnerBBoxes, Length(MP.Inners));
  for I := 0 to High(MP.Inners) do
    if Length(MP.Inners[I]) >= 3 then
      InnerBBoxes[I] := MakeRingBBox(MP.Inners[I]);

  FlattenForEarcut(MP, Data, HoleIndices);
  Triangles := TEarcutTriangulator.Triangulate(Data, HoleIndices, 2);
  if Length(Triangles) = 0 then Exit;

  Cells := nil;
  RowMinX := nil;
  RowMaxX := nil;

  CellSet := TCellHashSet.Create(EstimateCellCapacity(OuterBBox, CellSizeMeters));
  try
    I := 0;
    while I < Length(Triangles) do
    begin
      A.X := Data[Triangles[I] * 2];
      A.Z := Data[Triangles[I] * 2 + 1];

      B.X := Data[Triangles[I + 1] * 2];
      B.Z := Data[Triangles[I + 1] * 2 + 1];

      C.X := Data[Triangles[I + 2] * 2];
      C.Z := Data[Triangles[I + 2] * 2 + 1];

      GetCellsUnderTriangleReuse(A, B, C, ScaleXY, ScaleXY,
        Cells, RowMinX, RowMaxX, CellCount);

      for J := 0 to CellCount - 1 do
      begin
        Key := PackCellKey(Cells[J].CX, Cells[J].CY);

        if not CellSet.AddNew(Key) then Continue;

        if RandomFn = nil then
          CellRng := MakeSeededRandom(CellJitterSeed(Cells[J].CX, Cells[J].CY));

        RandJ := NextRand * JitterFraction;
        Pt.X := (Cells[J].CX + 0.5 + (JitterFraction / 2) - RandJ) * CellSizeMeters;

        RandJ := NextRand * JitterFraction;
        Pt.Z := (Cells[J].CY + 0.5 + (JitterFraction / 2) - RandJ) * CellSizeMeters;

        if not BBoxContainsPoint(OuterBBox, Pt) then Continue;

        IsInside := PointInRingXZ(Pt.X, Pt.Z, MP.Outer);

        if IsInside then
        begin
          for H := 0 to High(MP.Inners) do
          begin
            if Length(MP.Inners[H]) < 3 then Continue;
            if not BBoxContainsPoint(InnerBBoxes[H], Pt) then Continue;
            if PointInRingXZ(Pt.X, Pt.Z, MP.Inners[H]) then
            begin
              IsInside := False;
              Break;
            end;
          end;
        end;

        if IsInside then PushPoint(Pt);
      end;

      Inc(I, 3);
    end;
  finally
    CellSet.Free;
  end;

  SetLength(Result, ResultCount);
end;

class function TForestBuildOptions.Defaults: TForestBuildOptions;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1318);{$ENDIF}
  Result.CellMetersForest := 15.3;
  Result.CellMetersShrubs := 7.64;
  Result.SkipShrubs       := False;
  Result.SkipTrees        := False;
  Result.LiftAboveTerrain := 0.0;
end;

type
  { Ground-height source for vegetation. TTerrainSampler is the REFERENCE: built on the same
    lattice as the terrain mesh, SampleAt returns exactly the mesh surface (barycentric), so trees
    don't sink. Heightmap SampleBilinear is a DIFFERENT surface (bilinear != mesh-node interp) and
    sank trees on bumps/dips. So: if Terrain is set, height comes ONLY from it; SampleBilinear is
    the fallback for Terrain = nil. }
  THeightSamplerCtx = class
    HM: THeightmap;
    Projection: TLocalProjection;
    Lift: Double;
    Terrain: TTerrainSampler;     { эталонный источник; nil → fallback }
    function HeightAt(X, Z: Double): Double;
    { То же, что HeightAt, но по гео-координате — для одиночных
      деревьев (OSM node natural=tree). НЕ добавляет Lift. }
    function HeightAtGeo(const P: TLatLon): Double;
  end;

function THeightSamplerCtx.HeightAt(X, Z: Double): Double;
var Ll: TLatLon;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(460);{$ENDIF}
  if Terrain <> nil then
    { Та же поверхность, что и у меша земли и у зданий. }
    Result := Terrain.SampleAtXZ(Projection, X, Z)
  else
  begin
    { Fallback: сэмплер не передан — билинейно по heightmap. }
    Ll := Projection.Unproject(X, Z);
    Result := THeightmapSampler.SampleBilinear(HM, Ll);
  end;
  if (not IsNan(Result)) and (not IsInfinite(Result)) then
    Result := Result + Lift;
end;

function THeightSamplerCtx.HeightAtGeo(const P: TLatLon): Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1319);{$ENDIF}
  if Terrain <> nil then
    Result := Terrain.SampleAt(P)
  else
    Result := THeightmapSampler.SampleBilinear(HM, P);
end;

{ Shrub placement on slopes. A shrub is a cross-billboard (width 1.0 x Scale, all base verts at
  y=0); on a slope one footprint edge sits below ground. So shrub Y = MAX of the centre and the
  four footprint corners, so no edge sinks. On flat ground all 5 probes agree. }
procedure ApplyShrubHeights(var Shrubs: TTreeInstanceArray;
  Ctx: THeightSamplerCtx);
var
  I: Integer;
  R, HC, HMax, H: Double;

  procedure Probe(X, Z: Double);
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1498);{$ENDIF}
    H := Ctx.HeightAt(X, Z);
    if (not (IsNan(H) or IsInfinite(H))) and (H > HMax) then
      HMax := H;
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1320);{$ENDIF}
  if (Shrubs = nil) or (Ctx = nil) then Exit;

  for I := 0 to High(Shrubs) do
  begin
    { Полуширина footprint'а: crossquad шириной 1.0, масштаб = Scale. }
    R := 0.5 * Shrubs[I].Scale;

    HC := Ctx.HeightAt(Shrubs[I].X, Shrubs[I].Z);
    if IsNan(HC) or IsInfinite(HC) then Continue;

    HMax := HC;
    Probe(Shrubs[I].X - R, Shrubs[I].Z - R);
    Probe(Shrubs[I].X + R, Shrubs[I].Z - R);
    Probe(Shrubs[I].X - R, Shrubs[I].Z + R);
    Probe(Shrubs[I].X + R, Shrubs[I].Z + R);

    Shrubs[I].Y := Single(HMax);
  end;
end;

function IsForestPolygon(const Tags: TOSMTags): Boolean;
var V: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(461);{$ENDIF}
  if Tags = nil then Exit(False);
  V := Tags.GetLower('natural');
  if (V = 'wood') or (V = 'forest') or (V = 'tree_row') then Exit(True);
  if (V = 'wetland') and ((Tags.GetLower('wetland') = 'mangrove') or
    (Tags.GetLower('wetland') = 'swamp')) then Exit(True);
  V := Tags.GetLower('landuse');
  if (V = 'forest') or (V = 'wood') then Exit(True);
  Result := False;
end;

function IsScrubPolygon(const Tags: TOSMTags): Boolean;
var V: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(462);{$ENDIF}
  if Tags = nil then Exit(False);
  if IsForestPolygon(Tags) then Exit(False);
  V := Tags.GetLower('natural');
  Result := (V = 'scrub') or (V = 'heath') or (V = 'wetland') or
            (V = 'shrub') or (V = 'shrubbery');
end;

{ Dst — ёмкость (Length = capacity), DstCount — фактическое число инстансов;
  вызывающий делает один финальный SetLength(Dst, DstCount). Рост удвоением:
  append на каждый полигон не копирует накопленный массив квадратично. }
procedure AppendInstances(var Dst: TTreeInstanceArray; var DstCount: Integer;
  const Src: TTreeInstanceArray);
var
  Need, NewCap, I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(463);{$ENDIF}
  if Length(Src) = 0 then Exit;
  Need := DstCount + Length(Src);
  if Need > Length(Dst) then
  begin
    NewCap := Length(Dst) * 2;
    if NewCap < 256 then NewCap := 256;
    if NewCap < Need then NewCap := Need;
    SetLength(Dst, NewCap);
  end;
  for I := 0 to High(Src) do
    Dst[DstCount + I] := Src[I];
  DstCount := Need;
end;

procedure AppendPhotoPlants(const MP:TPolygonMultipolygon; const Tags:TOSMTags;
  const Options:TForestBuildOptions; HeightCtx:THeightSamplerCtx;
  RoadMask:TRoadExclusionMask; const TaggedPlants:TScatterPointArray;
  var TreesOut,ShrubsOut:TTreeInstanceArray; var TreesCount,ShrubsCount:Integer);
var Plants:TPhotoPlants; I,J,Count:Integer; Pos:TVector3; PlantTags:TOSMTags;
  One:TTreeInstanceArray; Inside,Duplicate,IsShrub:Boolean; Cands:TRoadSegArray;
  F:TFormatSettings; MinX,MaxX,MinZ,MaxZ:Single;
begin
  Plants:=ReadVegetationLayout(Tags.Get(VEGETATION_LAYOUT_TAG));
  Count:=0;Cands:=nil;
  if RoadMask<>nil then begin
    MultipolygonBBox(MP,MinX,MaxX,MinZ,MaxZ);
    RoadMask.CollectCandidates(MinX,MinZ,MaxX,MaxZ,Cands,Count);
  end;
  PlantTags:=TOSMTags.Create;SetLength(One,1);F:=DefaultFormatSettings;F.DecimalSeparator:='.';
  try
    for I:=0 to High(Plants) do begin
      IsShrub:=Plants[I].Kind='shrub';
      if (IsShrub and Options.SkipShrubs) or (not IsShrub and Options.SkipTrees) then Continue;
      Pos:=HeightCtx.Projection.Project(Plants[I].Position);
      Inside:=PointInRingXZ(Pos.X,Pos.Z,MP.Outer);
      if Inside then for J:=0 to High(MP.Inners) do
        if PointInRingXZ(Pos.X,Pos.Z,MP.Inners[J]) then begin Inside:=False;Break end;
      if not Inside then Continue;
      Duplicate:=False;
      for J:=0 to High(TaggedPlants) do
        if Sqr(TaggedPlants[J].X-Pos.X)+Sqr(TaggedPlants[J].Z-Pos.Z)<1 then begin Duplicate:=True;Break end;
      if Duplicate then Continue; { explicit OSM object owns this plant }
      if (Count>0) and TRoadExclusionMask.IsOnRoad(Pos.X,Pos.Z,Cands,Count) then Continue;
      Pos.Y:=HeightCtx.HeightAtGeo(Plants[I].Position)+HeightCtx.Lift;
      if IsNan(Pos.Y) or IsInfinite(Pos.Y) then Continue;
      PlantTags.Clear;PlantTags.Add('natural',Plants[I].Kind);PlantTags.Add('genus',Plants[I].Genus);
      if Plants[I].LeafType<>'' then PlantTags.Add('leaf_type',Plants[I].LeafType);
      PlantTags.Add('height',FloatToStr(Plants[I].Height,F));
      One[0]:=MakeSingleTreeInstance(PhotoPlantSeed(Plants[I].Id,Plants[I].Position),Pos,PlantTags);
      if IsShrub then begin One[0].Scale:=Plants[I].Height;One[0].SeedAsTexId:=0 end;
      One[0].Procedural:=ClassifyTreeTag(TreeTagJSON(PlantTags),Plants[I].Position,IsShrub);
      if IsShrub then AppendInstances(ShrubsOut,ShrubsCount,One)
      else AppendInstances(TreesOut,TreesCount,One);
    end;
  finally PlantTags.Free end;
end;

procedure ExcludePhotoAreas(var Trees:TTreeInstanceArray; const Masks:TMultipolygonArray;
  const HostMinX,HostMaxX,HostMinZ,HostMaxZ:Single);
var I,J,N:Integer; Keep:Boolean; MinX,MaxX,MinZ,MaxZ:Single;
begin
  if Length(Masks)=0 then Exit;
  for J:=0 to High(Masks) do begin
    if Length(Trees)=0 then Exit;
    MultipolygonBBox(Masks[J],MinX,MaxX,MinZ,MaxZ);
    { A reviewed street must not scan every tree in distant forests. }
    if (MaxX<HostMinX) or (MinX>HostMaxX) or
      (MaxZ<HostMinZ) or (MinZ>HostMaxZ) then Continue;
    N:=0;
    for I:=0 to High(Trees) do begin
      Keep:=(Trees[I].X<MinX) or (Trees[I].X>MaxX) or (Trees[I].Z<MinZ) or (Trees[I].Z>MaxZ);
      if not Keep then Keep:=not PointInRingXZ(Trees[I].X,Trees[I].Z,Masks[J].Outer);
      if Keep then begin Trees[N]:=Trees[I];Inc(N) end;
    end;
    SetLength(Trees,N);
  end;
end;

procedure ProcessOnePolygon(const MP: TPolygonMultipolygon;
  const Tags: TOSMTags; IsForest: Boolean;
  const Options: TForestBuildOptions;
  HeightCtx: THeightSamplerCtx;
  RoadMask: TRoadExclusionMask;
  const TaggedPlants: TScatterPointArray;
  const LocalPhotoMasks:TMultipolygonArray;
  var TreesOut, ShrubsOut: TTreeInstanceArray;
  var TreesCount, ShrubsCount: Integer);
{ SPLIT_THRESHOLD_M / TILE_SIZE_M / MAX_BBOX_M live in Osm3dStudioSettings (SPLIT_THRESHOLD_M =
  one geo-tile edge). }
var
  Species:   TTreeType;
  TaggedH:   Double;
  PhotoSpacing: Double;
  Local:     TTreeInstanceArray;
  MinX, MaxX, MinZ, MaxZ: Single;
  SubMPs:    TMultipolygonArray;
  K:         Integer;
  RoadCands: TRoadSegArray;
  RoadCandCount: Integer;
  TagsJSON: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(464);{$ENDIF}
  if Length(MP.Outer) < 3 then Exit;
  if Tags.HasKey(VEGETATION_LAYOUT_TAG) then begin
    { Consume once, before spatial subdivision. The explicit positions already
      have global identities; splitting must not replicate rows of trees. }
    AppendPhotoPlants(MP,Tags,Options,HeightCtx,RoadMask,TaggedPlants,
      TreesOut,ShrubsOut,TreesCount,ShrubsCount);
    Exit;
  end;

  MultipolygonBBox(MP, MinX, MaxX, MinZ, MaxZ);

  if ((MaxX - MinX) > MAX_BBOX_M) or ((MaxZ - MinZ) > MAX_BBOX_M) then
    Exit;

  if ((MaxX - MinX) > SPLIT_THRESHOLD_M) or
     ((MaxZ - MinZ) > SPLIT_THRESHOLD_M) then
  begin
    SubMPs := SplitMultipolygonIntoTiles(MP, TILE_SIZE_M);
    for K := 0 to High(SubMPs) do
      ProcessOnePolygon(SubMPs[K], Tags, IsForest, Options,
                        HeightCtx, RoadMask, TaggedPlants, LocalPhotoMasks, TreesOut, ShrubsOut,
                        TreesCount, ShrubsCount);
    Exit;
  end;

  { One AABB scan over road segments to collect those that can intersect
    this polygon (~0.01 ms). When RoadCandCount=0 the per-point loop is
    skipped — common for small isolated forest patches. }
  RoadCandCount := 0;
  RoadCands := nil;
  if RoadMask <> nil then
    RoadMask.CollectCandidates(MinX, MinZ, MaxX, MaxZ, RoadCands, RoadCandCount);

  if IsForest and (not Options.SkipTrees) then
  begin
    Species := GetTreeTypeFromTags(Tags);
    TaggedH := GetTreeHeight(Tags);
    PhotoSpacing:=Options.CellMetersForest;
    if Tags.HasKey('rezvivo:plant_spacing') then
      PhotoSpacing:=EnsureRange(ParseOSMMeters(Tags.Get('rezvivo:plant_spacing')),2,60);
    Local := ScatterTrees(MP, Species, PhotoSpacing, TaggedH);
    if not Tags.HasKey('rezvivo:local_photo_object') then
      ExcludePhotoAreas(Local,LocalPhotoMasks,MinX,MaxX,MinZ,MaxZ);
    if Length(Local) > 0 then
    begin
      ApplyTerrainHeights(Local, @HeightCtx.HeightAt);
      if RoadCandCount > 0 then
        FilterTreesByRoadCandidates(Local, RoadCands, RoadCandCount);
      TagsJSON := TreeTagJSON(Tags);
      for K := 0 to High(Local) do
        Local[K].Procedural := ClassifyTreeTag(TagsJSON,
          HeightCtx.Projection.Unproject(Local[K].X, Local[K].Z), False, True, Local[K].Y);
      AppendInstances(TreesOut, TreesCount, Local);
    end;
  end
  else if (not IsForest) and (not Options.SkipShrubs) then
  begin
    PhotoSpacing:=Options.CellMetersShrubs;
    if Tags.HasKey('rezvivo:plant_spacing') then
      PhotoSpacing:=EnsureRange(ParseOSMMeters(Tags.Get('rezvivo:plant_spacing')),2,60);
    Local := ScatterShrubs(MP, PhotoSpacing);
    if not Tags.HasKey('rezvivo:local_photo_object') then
      ExcludePhotoAreas(Local,LocalPhotoMasks,MinX,MaxX,MinZ,MaxZ);
    if Length(Local) > 0 then
    begin
      ApplyShrubHeights(Local, HeightCtx);
      if RoadCandCount > 0 then
        FilterTreesByRoadCandidates(Local, RoadCands, RoadCandCount);
      TagsJSON := TreeTagJSON(Tags);
      for K := 0 to High(Local) do
        Local[K].Procedural := ClassifyTreeTag(TagsJSON,
          HeightCtx.Projection.Unproject(Local[K].X, Local[K].Z), True, True, Local[K].Y);
      AppendInstances(ShrubsOut, ShrubsCount, Local);
    end;
  end;
end;

{ TreesOut — ёмкость (Length = capacity), TreesCount — число инстансов на
  входе и на выходе; финальный SetLength делает вызывающий. }
procedure AppendSingleTreeNodes(Dataset: TOSMDataset;
  HeightCtx: THeightSamplerCtx;
  var TreesOut: TTreeInstanceArray; var TreesCount: Integer);
var
  Node:     TOSMNode;
  TerrainH: Double;
  Pos:      TVector3;
  Inst:     TTreeInstance;
  Added:    Integer;
  OldLen:   Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(465);{$ENDIF}
  if Dataset = nil then Exit;
  Added := 0;
  OldLen := TreesCount;

  for Node in Dataset.Nodes.Values do
  begin
    if Node = nil then Continue;
    if not Node.Tags.HasKeyValue('natural', 'tree') and
       not Node.Tags.HasKeyValue('natural', 'shrub') then Continue;

    TerrainH := HeightCtx.HeightAtGeo(Node.Position);
    if IsNan(TerrainH) or IsInfinite(TerrainH) then TerrainH := 0;

    Pos := NodePlanePos(Dataset, Node, HeightCtx.Projection,
                        TerrainH + HeightCtx.Lift);   { int-first }
    Inst := MakeSingleTreeInstance(Node.Id, Pos, Node.Tags);
    Inst.Procedural := ClassifyTreeTag(TreeTagJSON(Node.Tags), Node.Position, False);

    if OldLen + Added >= Length(TreesOut) then
    begin
      if Length(TreesOut) = 0 then SetLength(TreesOut, 256)
      else SetLength(TreesOut, Length(TreesOut) * 2);
    end;
    TreesOut[OldLen + Added] := Inst;
    Inc(Added);
  end;

  TreesCount := OldLen + Added;
end;

class function TForestInstanceBuilder.BuildAll(Dataset: TOSMDataset;
  HM: THeightmap; Projection: TLocalProjection;
  const Options: TForestBuildOptions;
  Terrain: TTerrainSampler;
  LogProc: TLogProc): TForestBuildResult;
var
  HeightCtx: THeightSamplerCtx;
  RoadMask:  TRoadExclusionMask;
  Way:       TOSMWay;
  Rel:       TOSMRelation;
  MP:        TPolygonMultipolygon;
  RelType:   string;
  IsForest, IsScrub: Boolean;
  Multipolygons: TMultipolygonArray;
  I, J: Integer;
  Member: TOSMRelationMember;
  CoveredWays: specialize TDictionary<Int64, Byte>;
  CoverMask, KindMask: Byte;
  TreesCount, ShrubsCount: Integer;
  ScannedForest, ScannedScrub, ScannedMPs: Integer;

  EffectiveOptions: TForestBuildOptions;
  TaggedPlants: TScatterPointArray;
  TaggedCount: Integer;
  TaggedNode: TOSMNode;
  TaggedPosition: TVector3;
  TaggedPlantsReady: Boolean;
  LocalPhotoMasks:TMultipolygonArray;
  LocalMaskCount:Integer;

  procedure Log(const Msg: string);
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(466);{$ENDIF}
    if LogProc <> nil then LogProc(Msg);
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1158);{$ENDIF}
  Result.Trees := nil;
  Result.Shrubs := nil;
  TreesCount := 0;
  ShrubsCount := 0;

  if (Dataset = nil) or (HM = nil) or (Projection = nil) then Exit;

  EffectiveOptions := Options;

  Log(Format('TForestInstanceBuilder: lat=%0.3f° → ' +
    'cellForest=%0.2f m, cellShrubs=%0.2f m (streets-gl-equivalent: 15.3 / 7.64)',
    [Projection.Origin.Lat,
     EffectiveOptions.CellMetersForest,
     EffectiveOptions.CellMetersShrubs]));

  { Build road mask once: O(ways) to collect segments, each with precomputed
    AABB. Per polygon CollectCandidates does an O(segs) AABB scan
    (~0.01 ms) so per-point checks are O(K)≈0-15 not O(total_segs)≈3000. }
  RoadMask := BuildRoadMask(Dataset, Projection);
  Log(Format('  Road exclusion mask: %d segments (per-polygon candidate filter)',
    [RoadMask.SegmentCount]));

  HeightCtx := THeightSamplerCtx.Create;
  CoveredWays := nil;
  try
    CoveredWays := specialize TDictionary<Int64, Byte>.Create;
    HeightCtx.HM := HM;
    HeightCtx.Projection := Projection;
    HeightCtx.Lift := EffectiveOptions.LiftAboveTerrain;
    HeightCtx.Terrain := Terrain;     { эталонный источник высоты }
    TaggedPlants:=nil;TaggedCount:=0;TaggedPlantsReady:=False;LocalPhotoMasks:=nil;LocalMaskCount:=0;
    if Dataset.HasLocalPhotoVegetation then
      for Way in Dataset.Ways.Values do if Way.IsClosed and
        (Way.Tags.HasKey(VEGETATION_LAYOUT_TAG) or Way.Tags.HasKey('rezvivo:photo_replace_scatter')) then begin
        I:=LocalMaskCount;Inc(LocalMaskCount);
        if LocalMaskCount>Length(LocalPhotoMasks) then
          SetLength(LocalPhotoMasks,Max(16,Length(LocalPhotoMasks)*2));
        LocalPhotoMasks[I]:=BuildMultipolygonFromWay(Way,Dataset,Projection);
      end;

    SetLength(LocalPhotoMasks,LocalMaskCount);
    Log(Format('Scanning %d relations for forest/scrub multipolygons...',
      [Dataset.Relations.Count]));

    { Single summary instead of per-relation log lines: chunks have 200-500 relations and per-line
      logging dominated wall time. }
    ScannedForest := 0;
    ScannedScrub  := 0;
    ScannedMPs    := 0;

    for Rel in Dataset.Relations.Values do
    begin
      if Rel = nil then Continue;

      RelType := Rel.Tags.GetLower('type');
      if RelType <> 'multipolygon' then Continue;

      IsForest := IsForestPolygon(Rel.Tags);
      IsScrub  := IsScrubPolygon(Rel.Tags);
      if (not IsForest) and (not IsScrub) then Continue;

      Multipolygons := BuildMultipolygonsFromRelation(Rel, Dataset, Projection);
      if Length(Multipolygons) = 0 then Continue;

      { The relation owns vegetation on its outer ways, including its holes.
        Keep inner ways and independently tagged vegetation of another kind. }
      if IsForest then KindMask := 1 else KindMask := 2;
      for J := 0 to Rel.MemberCount - 1 do
      begin
        Member := Rel.Members[J];
        if Member.Kind <> omkWay then Continue;
        if (Member.Role <> '') and not SameText(Member.Role, 'outer') then Continue;
        Way := Dataset.FindWay(Member.Ref);
        if (Way = nil) or not Way.IsClosed then Continue;
        CoverMask := 0;
        CoveredWays.TryGetValue(Way.Id, CoverMask);
        CoveredWays.AddOrSetValue(Way.Id, CoverMask or KindMask);
      end;


      if IsForest then Inc(ScannedForest) else Inc(ScannedScrub);
      Inc(ScannedMPs, Length(Multipolygons));

      for I := 0 to High(Multipolygons) do
        ProcessOnePolygon(Multipolygons[I], Rel.Tags, IsForest,
          EffectiveOptions, HeightCtx, RoadMask, TaggedPlants, LocalPhotoMasks, Result.Trees, Result.Shrubs,
          TreesCount, ShrubsCount);
    end;
    Log(Format('  relations processed: %d forest + %d scrub → %d multipolygons',
      [ScannedForest, ScannedScrub, ScannedMPs]));

    Log(Format('Scanning %d ways for forest/scrub polygons...',
      [Dataset.Ways.Count]));

    for Way in Dataset.Ways.Values do
    begin
      if (Way = nil) or (not Way.IsClosed) then Continue;

      IsForest := IsForestPolygon(Way.Tags);
      IsScrub  := IsScrubPolygon(Way.Tags);
      if Way.Tags.HasKey(VEGETATION_LAYOUT_TAG) then begin
        IsForest:=True;
        if not TaggedPlantsReady then begin
          for TaggedNode in Dataset.Nodes.Values do
            if TaggedNode.Tags.HasKeyValue('natural','tree') or TaggedNode.Tags.HasKeyValue('natural','shrub') then begin
              if TaggedCount=Length(TaggedPlants) then SetLength(TaggedPlants,Max(64,TaggedCount*2));
              TaggedPosition:=NodePlanePos(Dataset,TaggedNode,Projection);
              TaggedPlants[TaggedCount].X:=TaggedPosition.X;TaggedPlants[TaggedCount].Z:=TaggedPosition.Z;Inc(TaggedCount);
            end;
          SetLength(TaggedPlants,TaggedCount);
          TaggedPlantsReady:=True;
        end;
      end;
      if (not IsForest) and (not IsScrub) then Continue;
      if IsForest then KindMask := 1 else KindMask := 2;
      if CoveredWays.TryGetValue(Way.Id, CoverMask) and
         ((CoverMask and KindMask) <> 0) then Continue;

      MP := BuildMultipolygonFromWay(Way, Dataset, Projection);
      if Length(MP.Outer) < 3 then Continue;

      ProcessOnePolygon(MP, Way.Tags, IsForest, EffectiveOptions, HeightCtx,
        RoadMask, TaggedPlants, LocalPhotoMasks, Result.Trees, Result.Shrubs, TreesCount, ShrubsCount);
    end;

    if not EffectiveOptions.SkipTrees then
      AppendSingleTreeNodes(Dataset, HeightCtx, Result.Trees, TreesCount);

    { ёмкость → фактический размер результата }
    SetLength(Result.Trees, TreesCount);
    SetLength(Result.Shrubs, ShrubsCount);

    Log(Format('Total: %d tree instances, %d shrub instances',
      [Length(Result.Trees), Length(Result.Shrubs)]));
  finally
    CoveredWays.Free;
    HeightCtx.Free;
    RoadMask.Free;
  end;
end;

class function TForestInstanceBuilder.BuildAllDefaults(Dataset: TOSMDataset;
  HM: THeightmap; Projection: TLocalProjection;
  Terrain: TTerrainSampler;
  LogProc: TLogProc): TForestBuildResult;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1159);{$ENDIF}
  Result := BuildAll(Dataset, HM, Projection,
    TForestBuildOptions.Defaults, Terrain, LogProc);
end;

constructor TRoadExclusionMask.Create;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1160);{$ENDIF}
  inherited Create;
  SetLength(FSegs, 256);
  FCount := 0;
end;

procedure TRoadExclusionMask.GrowSegs;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(467);{$ENDIF}
  SetLength(FSegs, Length(FSegs) * 2);
end;

procedure TRoadExclusionMask.AddSegment(X0, Z0, X1, Z1, HalfWidth,HalfWidthEnd: Single);
var
  S: TRoadSeg;
  HW: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(468);{$ENDIF}
  S.X0 := X0;  S.Z0 := Z0;
  S.DX := X1 - X0;  S.DZ := Z1 - Z0;
  S.LenSq := S.DX * S.DX + S.DZ * S.DZ;
  if S.LenSq < 0.01 then Exit;     { skip degenerate / duplicate-node segments }

  if HalfWidthEnd<0 then HalfWidthEnd:=HalfWidth;
  S.HalfW0:=HalfWidth+ROAD_CLEAR_M;S.HalfW1:=HalfWidthEnd+ROAD_CLEAR_M;
  HW := Max(S.HalfW0,S.HalfW1);
  S.HalfW   := HW;
  S.HalfWSq := HW * HW;

  S.BBoxMinX := Min(X0, X1) - HW;
  S.BBoxMaxX := Max(X0, X1) + HW;
  S.BBoxMinZ := Min(Z0, Z1) - HW;
  S.BBoxMaxZ := Max(Z0, Z1) + HW;

  if FCount >= Length(FSegs) then GrowSegs;
  FSegs[FCount] := S;
  Inc(FCount);
end;

procedure TRoadExclusionMask.BuildFromDataset(Dataset: TOSMDataset;
  Proj: TLocalProjection);
var
  Way:   TOSMWay;
  Kind:  TRoadKind;
  HalfW: Single;
  I:     Integer;
  NA, NB: TOSMNode;
  PA, PB: TVector3;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(469);{$ENDIF}
  if Dataset = nil then Exit;
  for Way in Dataset.Ways.Values do
  begin
    if Way = nil then Continue;
    Kind := TRoadBuilder.ClassifyHighway(Way.Tags);
    if Kind = rkNone then Continue;
    { ClassWidth runs full streets-gl parsing — width includes lanes,
      oneway, width tag, dirt/sand widthScale 1.7. }
    HalfW := TRoadBuilder.ClassWidth(Way.Tags) * 0.5;
    for I := 0 to Length(Way.NodeRefs) - 2 do
    begin
      NA := Dataset.FindNode(Way.NodeRefs[I]);
      NB := Dataset.FindNode(Way.NodeRefs[I + 1]);
      if (NA = nil) or (NB = nil) then Continue;
      PA := NodePlanePos(Dataset, NA, Proj);   { int-first }
      PB := NodePlanePos(Dataset, NB, Proj);
      AddSegment(PA.X, PA.Z, PB.X, PB.Z,
        WayNodeWidth(Way,I,HalfW*2)*0.5,WayNodeWidth(Way,I+1,HalfW*2)*0.5);
    end;
  end;
end;

procedure TRoadExclusionMask.CollectCandidates(
  MinX, MinZ, MaxX, MaxZ: Single;
  out Cands: TRoadSegArray; out Count: Integer);
var
  I, Cap: Integer;
  S: ^TRoadSeg;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(470);{$ENDIF}
  Count := 0;
  Cap := 16;
  SetLength(Cands, Cap);

  for I := 0 to FCount - 1 do
  begin
    S := @FSegs[I];
    if (S^.BBoxMaxX >= MinX) and (S^.BBoxMinX <= MaxX) and
       (S^.BBoxMaxZ >= MinZ) and (S^.BBoxMinZ <= MaxZ) then
    begin
      if Count >= Cap then
      begin
        Cap := Cap * 2;
        SetLength(Cands, Cap);
      end;
      Cands[Count] := S^;
      Inc(Count);
    end;
  end;
end;

class function TRoadExclusionMask.IsOnRoad(X, Z: Single;
  const Cands: TRoadSegArray; Count: Integer): Boolean;
var
  I:     Integer;
  S:     ^TRoadSeg;
  t, Cx, Cz, DSq: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1161);{$ENDIF}
  Result := False;
  for I := 0 to Count - 1 do
  begin
    S := @Cands[I];
    t := ((X - S^.X0) * S^.DX + (Z - S^.Z0) * S^.DZ) / S^.LenSq;
    if t < 0.0 then t := 0.0 else if t > 1.0 then t := 1.0;
    Cx := S^.X0 + t * S^.DX;
    Cz := S^.Z0 + t * S^.DZ;
    DSq := (X - Cx) * (X - Cx) + (Z - Cz) * (Z - Cz);
    if DSq <= Sqr(S^.HalfW0+(S^.HalfW1-S^.HalfW0)*t) then
    begin
      Result := True;
      Exit;
    end;
  end;
end;

function BuildRoadMask(Dataset: TOSMDataset;
  Proj: TLocalProjection): TRoadExclusionMask;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(472);{$ENDIF}
  Result := TRoadExclusionMask.Create;
  if (Dataset <> nil) and (Proj <> nil) then
    Result.BuildFromDataset(Dataset, Proj);
end;

function FilterTreesByRoadCandidates(var Trees: TTreeInstanceArray;
  const Cands: TRoadSegArray; CandCount: Integer): Integer;
var Src, Dst: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(473);{$ENDIF}
  Result := 0;
  if (Trees = nil) or (CandCount = 0) then Exit;
  Dst := 0;
  for Src := 0 to High(Trees) do
    if TRoadExclusionMask.IsOnRoad(Trees[Src].X, Trees[Src].Z, Cands, CandCount) then
      Inc(Result)
    else
    begin
      if Dst <> Src then Trees[Dst] := Trees[Src];
      Inc(Dst);
    end;
  SetLength(Trees, Dst);
end;

function ForestToTileTrees(
  const Forest: TForestBuildResult): TTileTreeRecArray;
var
  I, N: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(474);{$ENDIF}
  N := Length(Forest.Trees) + Length(Forest.Shrubs);
  SetLength(Result, N);
  N := 0;
  for I := 0 to High(Forest.Trees) do
  begin
    Result[N].X        := Forest.Trees[I].X;
    Result[N].Y        := Forest.Trees[I].Y;
    Result[N].Z        := Forest.Trees[I].Z;
    Result[N].Scale    := Forest.Trees[I].Scale;
    Result[N].Rotation := Forest.Trees[I].Rotation;
    Result[N].Seed     := Forest.Trees[I].SeedAsTexId;
    Result[N].IsShrub  := False;
    Result[N].Procedural := Forest.Trees[I].Procedural;
    Inc(N);
  end;
  for I := 0 to High(Forest.Shrubs) do
  begin
    Result[N].X        := Forest.Shrubs[I].X;
    Result[N].Y        := Forest.Shrubs[I].Y;
    Result[N].Z        := Forest.Shrubs[I].Z;
    Result[N].Scale    := Forest.Shrubs[I].Scale;
    Result[N].Rotation := Forest.Shrubs[I].Rotation;
    Result[N].Seed     := Forest.Shrubs[I].SeedAsTexId;
    Result[N].IsShrub  := True;
    Result[N].Procedural := Forest.Shrubs[I].Procedural;
    Inc(N);
  end;
end;

initialization

{ Guard the layout required by the renderer. If TTreeInstance is changed
  without updating TREE_INSTANCE_STRIDE, these assertions fire. }
  Assert(SizeOf(TTreeGPUInstance) = TREE_INSTANCE_STRIDE,
    'TTreeGPUInstance size mismatch — update TREE_INSTANCE_STRIDE');
  Assert(TREE_INSTANCE_STRIDE = 24,
    'streets-gl compatibility requires stride = 24 bytes');

end.
