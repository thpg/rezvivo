unit Osm3dTileX3D;

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$codepage UTF8}
{$WARN 5091 OFF}

interface

uses
  Classes,
  SysUtils,
  TypInfo,
  Math,
  CastleVectors, Osm3dShadowReceiver,
  CastleImages, Osm3dManholeData, Osm3dFacadeLayout,
  Osm3dGeoMath, Osm3dRoadSurface,
  Osm3dGeomMesh,
  Osm3dGeoTileGrid,
  Osm3dSceneMaterials,
  Osm3dGeomPOI,
  Osm3dTreeShadow,    { общий набор альфа-масок деревьев + ShadowIntensityFor }
  Osm3dBuildingObstacleIndex  { BUILDING_OBSTACLE: TBuildingObstacleArray on tile }
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
;

const
  GEO_TILE_FORMAT = 1;

type
  ETileX3DError = class(Exception);

  TDblArray = array of Double;
  TTileSingleArray = array of Single;
  TIntArray = array of Integer;
  TInt64Array = array of Int64;

  { Per-vertex aux stream. Length is either 0 (a plain mesh — buildings,
    water, roads) or exactly Mesh.VertexCount (a ground-composite slice,
    which carries one material id per vertex).
    Storing it on the mesh record keeps the codec uniform: the writer
    emits the extra <FloatVertexAttribute>-style stream only when
    present, the reader fills it back. }
  TTileMatIdArray   = array of Integer;
  TTileWaterScaleArray = array of Single;

  { Ground-shadow silhouettes.
 These are the PROJECTED shadow casters of a tile: building wall+roof
 triangles slid onto the ground along the sun, plus tree/shrub cards.
 They are DERIVED (sun-direction + terrain dependent), computed once at
 mount, and are NOT serialised to disk — TTileX3D.SaveFile writes an
 explicit field list and ignores them, which is exactly right because the
 mask they feed depends on the sun and on neighbouring tiles and must be
 rebuilt at mount. }
  TShadowCardKind = (sckTreeTex, sckShrubBlob);

  TProjTri = record
    SourceA, SourceB, SourceC: TVector3;
    SunSlope: TVector2;
    HasSource: Boolean;
    A, B, C: TVector2;
    IA, IB, IC: Byte;   { shadow intensity per vertex (255 darkest at the
                          wall base, fading toward the projected tip) }
    MinX, MinZ, MaxX, MaxZ: Single;
  end;
  TProjTriArray = array of TProjTri;

  TShadowTreeCard = record
    BaseY, SourceHeight: Single;
    SunSlope: TVector2;
    Kind: TShadowCardKind;       { textured tree card vs round shrub blob }
    BaseX, BaseZ: Single;        { world XZ of the foot (tree) / center (shrub) }
    RightX, RightZ: Single;      { unit, perpendicular to sun azimuth }
    SlideX, SlideZ: Single;      { ground slide of the top/center (-sun*h/sy) }
    W: Single;                   { tree: card width = scale; shrub: blob radius }
    TexId: Byte;                 { tree: 0..4 -> TreeShadowAlpha layer }
    MinX, MinZ, MaxX, MaxZ: Single;
  end;
  TShadowTreeCardArray = array of TShadowTreeCard;

  { Raw grayscale ground-shadow mask — one byte of coverage per texel,
    row-major W*H. Lives on TTileModel; the shadow worker rasterises into
    it (pull + neighbour push), the render loop uploads it into the tile's
    GL texture. In-memory only, never serialised. }
  TShadowMaskBytes  = array of Byte;

  { One mesh of a tile. The TTileModel owns Mesh and frees it. }
  TTileMeshRec = record
    Name:     string;
    Material: TSceneMaterialKind;
    Solid:    Boolean;
    Mesh:     TMesh;
    { Composite-only; empty for plain meshes. See TTileMatIdArray. }
    MatIds:   TTileMatIdArray;
    { Индексы граничных вершин (в per-vertex списке Mesh). Заполняется
      нарезчиком только для композита земли; пусто для прочих мешей.
      Сериализуется как <O3DBorderIdx>, при монтаже используется для
      приварки к соседнему тайлу. }
    BorderIdx: TTileMatIdArray;
    { Cached source-water width scale; optional, parallel to Mesh vertices. }
    WaterScale: TTileWaterScaleArray;
  end;
  TTileMeshRecArray = array of TTileMeshRec;

  { One POI — kind + local-metre position + yaw (rad, about +Y). }
  TTilePOIRec = record
    Kind:     TPOIKindExt;
    Position: TVector3;
    Rotation: Single;
  end;
  TTilePOIRecArray = array of TTilePOIRec;

  { One vegetation instance — a structural copy of vegetation's
    TTreeInstance (kept independent so this unit needs no dependency
    on Osm3dGeomVegetation). 6 floats: position, scale, rotation, seed.
    IsShrub selects which renderer it belongs to. }
  TProceduralTreeTag = packed record
    { Zero means an old record. Otherwise the integer GPU type plus one. }
    TypePlusOne: LongWord;
    LatE7, LonE7: LongInt;
  end;
  TTileTreeRec = record
    X, Y, Z:  Single;
    Scale:    Single;
    Rotation: Single;
    Seed:     Single;
    IsShrub:  Boolean;
    Procedural: TProceduralTreeTag;
  end;
  TTileTreeRecArray = array of TTileTreeRec;

  { Road centerline segment — one node-to-node piece of an OSM road
    way, in tile-local XZ. Carries the parsed road width and the way
    id. Stored per tile as a lightweight separate layer (the road
    ribbon meshes are anonymous triangle soup; these segments give the
    route snapper exact centerlines without needing a live TOSMDataset).
    Maps 1:1 onto TRouteSnapper.MakeSnapSegment inputs. }
  TTileRoadSeg = record
    X0, Z0: Single;
    X1, Z1: Single;
    Width:  Single;
    WayId:  Int64;
    { BRIDGE_SNAP: True = bridge/tunnel centerline for route snap only
      (not used for ground leveling). Lets the snapper prefer the deck over
      a ground road stacked under the span. }
    IsBridge: Boolean;
    Surface: TRoadSurfaceProfile;
  end;
  TTileRoadSegArray = array of TTileRoadSeg;

  { Optional decorative model instance, relative to the tile directory.
    Geometry/textures are shared by all instances of the same GLB/X3D file.
    It is deliberately separate from the rideable ground triangles. }
  TTileModelInstance = record
    FileName: string;
    Position,Scale: TVector3;
    Rotation: TVector4;
  end;
  TTileModelInstanceArray = array of TTileModelInstance;

  { In-memory representation of a cached tile. Owns all TMesh objects. }
  TTileModel = class
  private
    FMeshes:    TTileMeshRecArray;
    FMeshCount: Integer;
    FPOIs:      TTilePOIRecArray;
    FPOICount:  Integer;
    FTrees:     TTileTreeRecArray;
    FTreeCount: Integer;
    FRoadSegs:  TTileRoadSegArray;
    FRoadSegCount: Integer;
    function GetMesh(I: Integer): TTileMeshRec;
    function GetPOI(I: Integer): TTilePOIRec;
    function GetTree(I: Integer): TTileTreeRec;
    function GetRoadSeg(I: Integer): TTileRoadSeg;
  public
    TileId:  TGeoTileId;
    FacadeLayouts:TFacadeLayouts;
    BuildingTints:TBuildingTints;
    Origin:  TLatLon;       { local-projection origin for the mesh coords }
    Box:     TLatLonBox;    { geographic bounds of the tile }
    GenHash: string;        { generator / source-data hash }
    ModelInstances: TTileModelInstanceArray;
    Manholes: TManholeArray;

    { Ground-shadow state (TRANSIENT, never serialised)
 Owned/written by the single shadow worker in TTileStreamer; read by
 the worker (pull from this model's neighbours) and by the render loop
 (upload ShadowMask into the GL texture). The silhouettes that other
 tiles pull live right here on the casting tile's model, and the
 streamer's per-id lookup + retention (km radius ≫ the 200 m / one-tile
 shadow reach) is the only bookkeeping needed.

 Lifecycle: at mount the main thread PROJECTS the silhouettes from the
 live meshes (ShadowProjected := True) and asks the streamer to build
 the mask; the worker rasterises ShadowMask (ShadowReady := True) and
 enqueues an upload. A freshly disk-loaded model has none of this set
 (not serialised) — it is reprojected at mount. }
    ShadowProjected: Boolean;            { silhouettes below are valid }
    ShadowReady:     Boolean;            { ShadowMask rasterised, awaiting/uploaded }
    ShadowTris:      TProjTriArray;      { this tile's projected wall/roof silhouettes }
    ShadowTrees:     TShadowTreeCardArray;
    ShadowMinX, ShadowMinZ, ShadowMaxX, ShadowMaxZ: Single;  { silhouette XZ bounds }
    ShadowOX, ShadowOZ, ShadowSX, ShadowSZ: Single;          { mask window: origin + size (object XZ) }
    ShadowMask:      TShadowMaskBytes;   { BUILDINGS: raw grayscale, ShadowMaskW*ShadowMaskH }
    ShadowMaskW, ShadowMaskH: Integer;
    ShadowMaskTree:  TShadowMaskBytes;   { TREES: packed darkness+sway, ShadowMaskTreeW*H }
    ShadowMaskTreeW, ShadowMaskTreeH: Integer;

    { BUILDING_OBSTACLE: solid building footprints for runtime camera/rider
      push-out. Tile-local XZ (same frame as mesh verts after conventional
      rebase). Serialised as <O3DBuildingObs/>. KeepGroundUnder casters are
      not stored (courtyards / roof-only). }
    BuildingObstacles: TBuildingObstacleArray;

    constructor Create;
    destructor Destroy; override;

    { Reset only the transient shadow state (silhouettes + mask). Used when
      the sun direction changes (mask must be rebuilt) without touching the
      geometry. }
    procedure ClearShadow;

    { Takes ownership of Mesh. }
    procedure AddMesh(const AName: string; AMaterial: TSceneMaterialKind;
                      AMesh: TMesh; ASolid: Boolean = True);
    { As AddMesh, plus a per-vertex materialId stream. AMatIds
      must have Length = AMesh.VertexCount (or 0 for none). The
      array is copied by reference (caller must not mutate after). }
    procedure AddCompositeMesh(const AName: string;
                      AMaterial: TSceneMaterialKind; AMesh: TMesh;
                      const AMatIds: TTileMatIdArray;
                      ASolid: Boolean = True);
    procedure AddPOI(AKind: TPOIKindExt; const APos: TVector3;
      ARotation: Single = 0);
    procedure AddTree(const ATree: TTileTreeRec);
    procedure AddRoadSeg(const ASeg: TTileRoadSeg);
    { Bulk cache input. Arrays are adopted by reference; do not mutate them later. }
    procedure SetPOIs(const A: TTilePOIRecArray);
    procedure SetTrees(const A: TTileTreeRecArray);
    procedure SetRoadSegs(const A: TTileRoadSegArray);
    { In-place mutators — used to rebase coordinates after distribution. }
    procedure SetPOI(I: Integer; const ARec: TTilePOIRec);
    procedure SetTree(I: Integer; const ARec: TTileTreeRec);
    procedure SetRoadSeg(I: Integer; const ARec: TTileRoadSeg);
    { Записать индексы граничных вершин меша I (GetMesh отдаёт запись
      по значению, поэтому нужен отдельный сеттер). }
    procedure SetWaterScale(I: Integer; const AScale: TTileWaterScaleArray);
    procedure SetMaterialIds(I: Integer; const AIds: TTileMatIdArray);
    procedure SetBorderIdx(I: Integer; const AIdx: TTileMatIdArray);

    { Frees owned meshes and resets. }
    procedure Clear;

    property MeshCount: Integer read FMeshCount;
    property POICount:  Integer read FPOICount;
    property TreeCount: Integer read FTreeCount;
    property RoadSegCount: Integer read FRoadSegCount;
    property Meshes[I: Integer]: TTileMeshRec read GetMesh;
    property POIs[I: Integer]:   TTilePOIRec  read GetPOI;
    property Trees[I: Integer]:  TTileTreeRec read GetTree;
    property RoadSegs[I: Integer]: TTileRoadSeg read GetRoadSeg;
  end;

  TTileModelArray = array of TTileModel;

  { Stateless hand-written X3D codec for TTileModel. }
  TTileX3D = class
  public
    class procedure SaveStream(Stream: TStream; Model: TTileModel);
    class procedure SaveFile(const FileName: string; Model: TTileModel);

    { Caller owns the returned TTileModel and must Free it. }
    class function LoadStream(Stream: TStream): TTileModel;
    class function LoadFile(const FileName: string): TTileModel;
    { Streaming footprint-only read for route preparation: no mesh decoding. }
    class function LoadBuildingObstacles(const FileName: string;
      out Origin: TLatLon): TBuildingObstacleArray;
  end;

{ Ground-shadow mask engine.
 Rasterises a tile's raw byte mask from its own projected silhouettes plus
 its already-projected neighbours (the casters that reach across the tile
 edge). Operates purely on CPU bytes (TShadowMaskBytes) + TTileModel, so the
 single shadow worker in TTileStreamer can call it off the main thread; the
 only GL object touched anywhere is the tree-alpha source, which is a CPU
 TGrayscaleImage loaded once. }

{ MAIN-THREAD gather: collect every projected silhouette (tris + tree cards)
  from Models that overlaps the given window, into flat snapshot arrays. The
  caller passes [target] + its 1-ring neighbours; the result is a fully
  self-contained snapshot the shadow worker can rasterise with no access to
  any TTileModel. Models must be on the main thread; entries may be nil. }

{ WORKER-THREAD rasterise: build a raw byte mask (W*H) from a self-contained
  silhouette snapshot for the given window, with the soft umbra blur. Returns
  the bytes (caller stores them into TTileModel.ShadowMask + uploads). Touches
  no TTileModel and no GL object (the tree alpha is a CPU image). }
function RasterizeSnapshotMask(const OriginV, SizeV: TVector2; W, H: Integer;
  const Tris: TProjTriArray; const Trees: TShadowTreeCardArray;
  ACancel: PBoolean = nil; Receiver: TShadowReceiverRaster = nil): TShadowMaskBytes;

{ Packed shadow-mask helpers. The mask is rasterised at 2x (supersample) then
  packed at Bits (8/4/2/1) per texel, ROW-packed along X: 8 div Bits logical
  texels per byte, LINEARISED row-major and stored in a POWER-OF-TWO rectangle
  ShadowTexW x ShadowTexH (~square, both POT so CGE does not rescale it under
  texelFetch). Logical side = BaseRes. The ground shader unpacks + bilinears. }
function ShadowTexW(LogRes, Bits: Integer): Integer;
function ShadowTexH(LogRes, Bits: Integer): Integer;
{ TREE mask (2 channels: darkness + sway-weight). R4x2 -> 1 byte/texel (two
  nibbles), R8x2 -> 2 bytes/texel. Byte-linearised into a POT rectangle,
  same as the building mask but bytes-PER-texel instead of texels-per-byte. }
function TreeShadowTexW(LogRes, Bits: Integer): Integer;
function TreeShadowTexH(LogRes, Bits: Integer): Integer;
{ ACancel — необязательный флаг отмены (teardown): проверяется каждые
  ~256 треугольников/деревьев; при взводе возвращает nil досрочно — иначе
  джойн shadow-воркера ждёт дорастеризации плотного тайла (секунды при Stop). }
function RasterizeTreeMaskPacked(const OriginV, SizeV: TVector2;
  BaseRes, Bits: Integer; const Trees: TShadowTreeCardArray;
  ACancel: PBoolean = nil; Receiver: TShadowReceiverRaster = nil): TShadowMaskBytes;
function RasterizeSnapshotMaskPacked(const OriginV, SizeV: TVector2;
  BaseRes, Bits: Integer;
  const Tris: TProjTriArray; const Trees: TShadowTreeCardArray;
  ACancel: PBoolean = nil; Receiver: TShadowReceiverRaster = nil): TShadowMaskBytes;

{ Convert the cached road ribbon's center and perpendicular width together. }
function RoadSegmentToFrame(const S: TTileRoadSeg; const Center: TVector3;
  ScaleX: Double): TTileRoadSeg;

implementation
uses TreeModel, fpjson, jsonparser;

function RoadSegmentToFrame(const S: TTileRoadSeg; const Center: TVector3;
  ScaleX: Double): TTileRoadSeg;
var DX, DZ, Len2, FrameLen2,Factor: Double;
begin
  Result := S;
  Result.X0 := S.X0 * ScaleX + Center.X;
  Result.X1 := S.X1 * ScaleX + Center.X;
  Result.Z0 := S.Z0 + Center.Z;
  Result.Z1 := S.Z1 + Center.Z;
  DX := S.X1 - S.X0; DZ := S.Z1 - S.Z0;
  Len2 := Sqr(DX) + Sqr(DZ);
  FrameLen2 := Sqr(DX * ScaleX) + Sqr(DZ);
  if FrameLen2 > 1e-12 then begin
    Factor:=ScaleX*Sqrt(Len2/FrameLen2);Result.Width:=S.Width*Factor;
    Result.Surface.WidthStart:=S.Surface.WidthStart*Factor;
    Result.Surface.WidthEnd:=S.Surface.WidthEnd*Factor;
  end;
end;

function MaterialName(K: TSceneMaterialKind): string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(986);{$ENDIF}
  Result := GetEnumName(TypeInfo(TSceneMaterialKind), Ord(K));
end;

function MaterialFromName(const S: string): TSceneMaterialKind;
var V: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(987);{$ENDIF}
  V := GetEnumValue(TypeInfo(TSceneMaterialKind), S);
  if V < 0 then
    Result := smkSurface          { forward-compatible fallback }
  else
    Result := TSceneMaterialKind(V);
end;

function POIKindName(K: TPOIKindExt): string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(988);{$ENDIF}
  Result := GetEnumName(TypeInfo(TPOIKindExt), Ord(K));
end;

function POIKindFromName(const S: string): TPOIKindExt;
var V: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(989);{$ENDIF}
  V := GetEnumValue(TypeInfo(TPOIKindExt), S);
  if V < 0 then
    Result := pkxNone
  else
    Result := TPOIKindExt(V);
end;

{ number formatting (locale-independent via Str/Val) }

{ Allocation-free variant of NumTok: formats into a stack ShortString and
  writes the (trailing-zero-trimmed) characters straight into the builder, so
  the per-vertex serialisation no longer creates one heap string per number. }
procedure AppendNum(SB: TStringBuilder; V: Double; Decimals: Integer);
var
  S: ShortString;
  I, DotPos, L: Integer;
begin
  Str(V:0:Decimals, S);
  L := Length(S);
  if Decimals > 0 then
  begin
    DotPos := L - Decimals;
    I := L;
    while (I > DotPos) and (S[I] = '0') do Dec(I);
    if I = DotPos then Dec(I);
    L := I;
  end;
  if (L = 2) and (S[1] = '-') and (S[2] = '0') then
  begin
    SB.Append('0');
    Exit;
  end;
  for I := 1 to L do
    SB.Append(S[I]);
end;

function NumTok(V: Double; Decimals: Integer): string;
var
  I, DotPos: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(990);{$ENDIF}
  Str(V:0:Decimals, Result);
  { Str(:0:Decimals) emits exactly Decimals fractional digits; the '.'
    sits at Length-Decimals. Trim trailing zeros from the known dot
    position instead of scanning with Pos. }
  if Decimals > 0 then
  begin
    DotPos := Length(Result) - Decimals;
    I := Length(Result);
    while (I > DotPos) and (Result[I] = '0') do Dec(I);
    if I = DotPos then Dec(I);
    SetLength(Result, I);
  end;
  if Result = '-0' then Result := '0';
end;

{ XML escaping (only mesh names may contain unsafe chars) }

function XmlEsc(const S: string): string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(991);{$ENDIF}
  Result := StringReplace(S,      '&', '&amp;',  [rfReplaceAll]);
  Result := StringReplace(Result, '<', '&lt;',   [rfReplaceAll]);
  Result := StringReplace(Result, '>', '&gt;',   [rfReplaceAll]);
  Result := StringReplace(Result, '"', '&quot;', [rfReplaceAll]);
end;

function XmlUnesc(const S: string): string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(992);{$ENDIF}
  Result := StringReplace(S,      '&quot;', '"', [rfReplaceAll]);
  Result := StringReplace(Result, '&gt;',   '>', [rfReplaceAll]);
  Result := StringReplace(Result, '&lt;',   '<', [rfReplaceAll]);
  Result := StringReplace(Result, '&amp;',  '&', [rfReplaceAll]);
end;

constructor TTileModel.Create;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1296);{$ENDIF}
  inherited Create;
  FMeshCount := 0;
  FPOICount  := 0;
  FTreeCount := 0;
  FRoadSegCount := 0;
  Origin := TLatLon.Make(0, 0);
  Box    := TLatLonBox.Empty;
end;

destructor TTileModel.Destroy;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1297);{$ENDIF}
  Clear;
  inherited;
end;

procedure TTileModel.Clear;
var I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(993);{$ENDIF}
  for I := 0 to FMeshCount - 1 do
    FreeAndNil(FMeshes[I].Mesh);
  SetLength(FMeshes, 0);
  SetLength(FPOIs, 0);
  SetLength(FTrees, 0);
  SetLength(FRoadSegs, 0);
  ModelInstances:=nil;
  Manholes:=nil;
  FacadeLayouts:=nil;
  BuildingTints:=nil;
  { BUILDING_OBSTACLE }
  SetLength(BuildingObstacles, 0);
  FMeshCount := 0;
  FPOICount  := 0;
  FTreeCount := 0;
  FRoadSegCount := 0;
  ClearShadow;
end;

procedure TTileModel.ClearShadow;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1808);{$ENDIF}
  ShadowProjected := False;
  ShadowReady     := False;
  SetLength(ShadowTris,  0);
  SetLength(ShadowTrees, 0);
  SetLength(ShadowMask,  0);
  ShadowMaskW := 0;
  ShadowMaskH := 0;
  SetLength(ShadowMaskTree, 0);
  ShadowMaskTreeW := 0;
  ShadowMaskTreeH := 0;
  ShadowMinX := 0; ShadowMinZ := 0; ShadowMaxX := 0; ShadowMaxZ := 0;
  ShadowOX := 0; ShadowOZ := 0; ShadowSX := 0; ShadowSZ := 0;
end;

procedure TTileModel.AddMesh(const AName: string;
  AMaterial: TSceneMaterialKind; AMesh: TMesh; ASolid: Boolean);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(994);{$ENDIF}
  AddCompositeMesh(AName, AMaterial, AMesh, nil, ASolid);
end;

procedure TTileModel.AddCompositeMesh(const AName: string;
  AMaterial: TSceneMaterialKind; AMesh: TMesh;
  const AMatIds: TTileMatIdArray;
  ASolid: Boolean);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(995);{$ENDIF}
  if AMesh = nil then Exit;
  if FMeshCount >= Length(FMeshes) then
  begin
    if Length(FMeshes) = 0 then SetLength(FMeshes, 8)
    else SetLength(FMeshes, Length(FMeshes) * 2);
  end;
  FMeshes[FMeshCount].Name     := AName;
  FMeshes[FMeshCount].Material := AMaterial;
  FMeshes[FMeshCount].Solid    := ASolid;
  FMeshes[FMeshCount].Mesh     := AMesh;
  FMeshes[FMeshCount].MatIds   := AMatIds;
  Inc(FMeshCount);
end;

procedure TTileModel.AddPOI(AKind: TPOIKindExt; const APos: TVector3;
  ARotation: Single);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(996);{$ENDIF}
  if FPOICount >= Length(FPOIs) then
  begin
    if Length(FPOIs) = 0 then SetLength(FPOIs, 16)
    else SetLength(FPOIs, Length(FPOIs) * 2);
  end;
  FPOIs[FPOICount].Kind     := AKind;
  FPOIs[FPOICount].Position := APos;
  FPOIs[FPOICount].Rotation := ARotation;
  Inc(FPOICount);
end;

procedure TTileModel.AddTree(const ATree: TTileTreeRec);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(997);{$ENDIF}
  if FTreeCount >= Length(FTrees) then
  begin
    if Length(FTrees) = 0 then SetLength(FTrees, 64)
    else SetLength(FTrees, Length(FTrees) * 2);
  end;
  FTrees[FTreeCount] := ATree;
  Inc(FTreeCount);
end;

procedure TTileModel.SetPOIs(const A: TTilePOIRecArray);
begin
  FPOIs := A; FPOICount := Length(A);
end;

procedure TTileModel.SetTrees(const A: TTileTreeRecArray);
begin
  FTrees := A; FTreeCount := Length(A);
end;

procedure TTileModel.SetRoadSegs(const A: TTileRoadSegArray);
begin
  FRoadSegs := A; FRoadSegCount := Length(A);
end;

function TTileModel.GetMesh(I: Integer): TTileMeshRec;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(998);{$ENDIF}
  if (I < 0) or (I >= FMeshCount) then
    raise ETileX3DError.CreateFmt('Mesh index out of range: %d', [I]);
  Result := FMeshes[I];
end;

function TTileModel.GetPOI(I: Integer): TTilePOIRec;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(999);{$ENDIF}
  if (I < 0) or (I >= FPOICount) then
    raise ETileX3DError.CreateFmt('POI index out of range: %d', [I]);
  Result := FPOIs[I];
end;

function TTileModel.GetTree(I: Integer): TTileTreeRec;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1000);{$ENDIF}
  if (I < 0) or (I >= FTreeCount) then
    raise ETileX3DError.CreateFmt('Tree index out of range: %d', [I]);
  Result := FTrees[I];
end;

procedure TTileModel.SetPOI(I: Integer; const ARec: TTilePOIRec);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1001);{$ENDIF}
  if (I < 0) or (I >= FPOICount) then
    raise ETileX3DError.CreateFmt('POI index out of range: %d', [I]);
  FPOIs[I] := ARec;
end;

procedure TTileModel.SetTree(I: Integer; const ARec: TTileTreeRec);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1002);{$ENDIF}
  if (I < 0) or (I >= FTreeCount) then
    raise ETileX3DError.CreateFmt('Tree index out of range: %d', [I]);
  FTrees[I] := ARec;
end;

function TTileModel.GetRoadSeg(I: Integer): TTileRoadSeg;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1809);{$ENDIF}
  if (I < 0) or (I >= FRoadSegCount) then
    raise ETileX3DError.CreateFmt('RoadSeg index out of range: %d', [I]);
  Result := FRoadSegs[I];
end;

procedure TTileModel.AddRoadSeg(const ASeg: TTileRoadSeg);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1810);{$ENDIF}
  if FRoadSegCount >= Length(FRoadSegs) then
  begin
    if Length(FRoadSegs) = 0 then SetLength(FRoadSegs, 64)
    else SetLength(FRoadSegs, Length(FRoadSegs) * 2);
  end;
  FRoadSegs[FRoadSegCount] := ASeg;
  Inc(FRoadSegCount);
end;

procedure TTileModel.SetRoadSeg(I: Integer; const ARec: TTileRoadSeg);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1811);{$ENDIF}
  if (I < 0) or (I >= FRoadSegCount) then
    raise ETileX3DError.CreateFmt('RoadSeg index out of range: %d', [I]);
  FRoadSegs[I] := ARec;
end;

procedure TTileModel.SetWaterScale(I: Integer; const AScale: TTileWaterScaleArray);
begin
  if (I < 0) or (I >= FMeshCount) then Exit;
  if (Length(AScale) <> 0) and
     (Length(AScale) <> FMeshes[I].Mesh.VertexCount) then
    raise ETileX3DError.Create('Water scale vertex count mismatch');
  FMeshes[I].WaterScale := AScale;
end;

procedure TTileModel.SetMaterialIds(I: Integer; const AIds: TTileMatIdArray);
begin
  if (I < 0) or (I >= FMeshCount) then
    raise ETileX3DError.Create('Material stream mesh index out of range');
  if Length(AIds) <> FMeshes[I].Mesh.VertexCount then
    raise ETileX3DError.Create('Material stream vertex count mismatch');
  FMeshes[I].MatIds := AIds;
end;

procedure TTileModel.SetBorderIdx(I: Integer; const AIdx: TTileMatIdArray);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1812);{$ENDIF}
  if (I < 0) or (I >= FMeshCount) then
    raise ETileX3DError.CreateFmt('Mesh index out of range: %d', [I]);
  FMeshes[I].BorderIdx := AIdx;
end;

{ Считает число разделённых пробелами токенов в S — общий первый проход
  для ParseDoubleArray / ParseIntArray / ParseInt64Array
  (раньше он дублировался во всех трёх). }
function CountWSTokens(const S: string): Integer;
var
  P, Len: Integer;
begin
  Result := 0;
  Len := Length(S);
  P := 1;
  while P <= Len do
  begin
    while (P <= Len) and (S[P] <= ' ') do Inc(P);
    if P > Len then Break;
    Inc(Result);
    while (P <= Len) and (S[P] > ' ') do Inc(P);
  end;
end;

{ Границы следующего токена начиная с P; продвигает P за токен.
  Возвращает False, когда токенов больше нет. }
function NextWSToken(const S: string; var P: Integer;
  out TokStart, TokLen: Integer): Boolean;
var
  Len, Q: Integer;
begin
  Len := Length(S);
  while (P <= Len) and (S[P] <= ' ') do Inc(P);
  if P > Len then begin Result := False; Exit; end;
  Q := P;
  while (Q <= Len) and (S[Q] > ' ') do Inc(Q);
  TokStart := P;
  TokLen   := Q - P;
  P := Q;
  Result := True;
end;

{ Val без heap-аллокации на токен: копируем токен в стековый ShortString
  (FPC берёт fpc_Val_*_ShortStr напрямую) вместо Copy() -> AnsiString. }
procedure TokToShort(const S: string; TS, TL: Integer; out Tmp: ShortString); inline;
begin
  Tmp[0] := Chr(TL);
  Move(S[TS], Tmp[1], TL);
end;

function ParseDoubleArray(const S: string): TDblArray;
var
  N, P, TS, TL, Code: Integer;
  D: Double;
  Tmp: ShortString;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1003);{$ENDIF}
  Result := nil;
  SetLength(Result, CountWSTokens(S));
  N := 0; P := 1;
  while NextWSToken(S, P, TS, TL) do
  begin
    if TL <= High(Tmp) then
    begin
      TokToShort(S, TS, TL, Tmp);
      Val(Tmp, D, Code);
    end
    else
      Val(Copy(S, TS, TL), D, Code);
    if Code = 0 then Result[N] := D else Result[N] := 0;
    Inc(N);
  end;
end;

{ Vertex fields end in Single in TMesh. Parse via the same Double value,
  then narrow once here, without retaining an entire Double-sized copy. }
function ParseSingleArray(const S: string): TTileSingleArray;
var
  N, P, TS, TL, Code: Integer;
  D: Double;
  Tmp: ShortString;
begin
  Result := nil;
  SetLength(Result, CountWSTokens(S));
  N := 0; P := 1;
  while NextWSToken(S, P, TS, TL) do
  begin
    if TL <= High(Tmp) then
    begin
      TokToShort(S, TS, TL, Tmp);
      Val(Tmp, D, Code);
    end
    else
      Val(Copy(S, TS, TL), D, Code);
    if Code = 0 then Result[N] := D else Result[N] := 0;
    Inc(N);
  end;
end;

function ParseIntArray(const S: string): TIntArray;
var
  N, P, TS, TL, Code: Integer;
  V: Integer;
  Tmp: ShortString;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1004);{$ENDIF}
  Result := nil;
  SetLength(Result, CountWSTokens(S));
  N := 0; P := 1;
  while NextWSToken(S, P, TS, TL) do
  begin
    if TL <= High(Tmp) then
    begin
      TokToShort(S, TS, TL, Tmp);
      Val(Tmp, V, Code);
    end
    else
      Val(Copy(S, TS, TL), V, Code);
    if Code = 0 then Result[N] := V else Result[N] := 0;
    Inc(N);
  end;
end;

{ As ParseIntArray, but parses into 64-bit values — OSM ids routinely
  exceed the 32-bit range (node ids passed 2^31 years ago, way ids are
  well over 10^9 and climbing). Used for the <O3DOsmId> stream. }
function ParseInt64Array(const S: string): TInt64Array;
var
  N, P, TS, TL, Code: Integer;
  V: Int64;
  Tmp: ShortString;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1813);{$ENDIF}
  Result := nil;
  SetLength(Result, CountWSTokens(S));
  N := 0; P := 1;
  while NextWSToken(S, P, TS, TL) do
  begin
    if TL <= High(Tmp) then
    begin
      TokToShort(S, TS, TL, Tmp);
      Val(Tmp, V, Code);
    end
    else
      Val(Copy(S, TS, TL), V, Code);
    if Code = 0 then Result[N] := V else Result[N] := 0;
    Inc(N);
  end;
end;

{ Extract  Name="value"  from a line. Search ' Name="' (leading space) so
  e.g. 'name' does not match inside 'o3dName'. Returns '' if absent. }
function GetAttr(const Line, Name: string): string;
var
  P, Q: Integer;
  Needle: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1005);{$ENDIF}
  Result := '';
  Needle := ' ' + Name + '="';
  P := Pos(Needle, Line);
  if P = 0 then Exit;
  P := P + Length(Needle);
  Q := P;
  while (Q <= Length(Line)) and (Line[Q] <> '"') do Inc(Q);
  Result := XmlUnesc(Copy(Line, P, Q - P));
end;

function LineIsTag(const Line, Tag: string): Boolean;
var
  I, LT: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1006);{$ENDIF}
  LT := Length(Tag);
  if Length(Line) < LT then
  begin
    Result := False;
    Exit;
  end;
  for I := 1 to LT do
    if Line[I] <> Tag[I] then
    begin
      Result := False;
      Exit;
    end;
  Result := True;
end;

{ Dedup vertex positions into a shared pool, mirroring the in-memory
  TVertexPool: vertices that share a position collapse to one pool entry.
  Quantises to 0.1 mm (the write precision DEC_POS=4), so two vertices that
  serialise to the same position string merge — which is exactly the set the
  in-memory position-only weld already collapsed (coincident verts are
  bit-identical, distinct pool entries are >=1 mm apart). PoolFirst[p] is a
  representative vertex for pool entry p (used to emit its position+normal);
  PIdx[k] is vertex k's pool index. }
{$push}{$Q-}{$R-}
procedure DedupVertexPositions(const V: TMeshVertexArray;
  out PIdx: TIntArray; out PoolFirst: TIntArray; out NPool: Integer);
var
  NV, Buckets, Mask, K, B, P: Integer;
  HashHead, HashNext: TIntArray;
  qx, qy, qz: Int64;
  h: QWord;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1814);{$ENDIF}
  NV := Length(V);
  SetLength(PIdx, NV);
  SetLength(PoolFirst, NV);   { worst case: all unique }
  NPool := 0;
  if NV = 0 then Exit;

  Buckets := 1 shl 12;
  while Buckets < NV * 2 do Buckets := Buckets shl 1;
  Mask := Buckets - 1;
  SetLength(HashHead, Buckets);
  for K := 0 to Buckets - 1 do HashHead[K] := -1;
  SetLength(HashNext, NV);

  for K := 0 to NV - 1 do
  begin
    qx := Round(V[K].Position.X * 10000.0);
    qy := Round(V[K].Position.Y * 10000.0);
    qz := Round(V[K].Position.Z * 10000.0);
    h := QWord($cbf29ce484222325);
    h := (h xor QWord(qx)) * QWord($100000001b3);
    h := (h xor QWord(qy)) * QWord($100000001b3);
    h := (h xor QWord(qz)) * QWord($100000001b3);
    B := Integer(LongWord(h xor (h shr 32)) and LongWord(Mask));

    P := HashHead[B];
    while P <> -1 do
    begin
      if (Round(V[PoolFirst[P]].Position.X * 10000.0) = qx)
         and (Round(V[PoolFirst[P]].Position.Y * 10000.0) = qy)
         and (Round(V[PoolFirst[P]].Position.Z * 10000.0) = qz) then
        Break;
      P := HashNext[P];
    end;

    if P = -1 then
    begin
      P := NPool;
      PoolFirst[P] := K;
      HashNext[P]  := HashHead[B];
      HashHead[B]  := P;
      Inc(NPool);
    end;
    PIdx[K] := P;
  end;
  SetLength(PoolFirst, NPool);
end;
{$pop}

class procedure TTileX3D.SaveStream(Stream: TStream; Model: TTileModel);
const
  DEC_POS = 4;     { local metres -> 0.1 mm }
  DEC_NRM = 6;     { unit normals }
  DEC_UV  = 6;
  DEC_LL  = 9;     { lat/lon -> ~0.1 mm }
  HemiCh: array[Boolean] of string = ('S', 'N');
var
  SB: TStringBuilder;
  I, J, K, RunN, NRuns: Integer;
  CurWay: Int64;
  RunStr: string;
  NewRun: Boolean;
  Bytes: UTF8String;
  FacadesJSON:TJSONData;

  procedure WriteShape(const R: TTileMeshRec);
  var
    V:   TMeshVertexArray;
    Idx: TMeshIndexArray;
    K, Tri, TriCount: Integer;
    HasOsmId: Boolean;
    PIdx, PoolFirst: TIntArray;
    NPool, NCoord, J: Integer;
    IsComp: Boolean;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1007);{$ENDIF}
    if (R.Mesh = nil) or (R.Mesh.VertexCount = 0)
    or (R.Mesh.TriangleCount = 0) then Exit;

    V   := R.Mesh.Vertices;     { property trims to live count }
    Idx := R.Mesh.Indices;
    TriCount := R.Mesh.TriangleCount;

    SB.Append('<Shape o3dName="');
    SB.Append(XmlEsc(R.Name));
    SB.Append('" o3dMaterial="');
    SB.Append(MaterialName(R.Material));
    SB.Append('">');
    SB.Append(LineEnding);

    { coordIndex — standard X3D: 3 indices + -1 per triangle. }
    SB.Append('<IndexedFaceSet solid="');
    if R.Solid then SB.Append('true') else SB.Append('false');
    SB.Append('" normalPerVertex="true" coordIndex="');
    for Tri := 0 to TriCount - 1 do
    begin
      if Tri > 0 then SB.Append(' ');
      SB.Append(IntToStr(Idx[Tri*3]));     SB.Append(' ');
      SB.Append(IntToStr(Idx[Tri*3 + 1])); SB.Append(' ');
      SB.Append(IntToStr(Idx[Tri*3 + 2])); SB.Append(' -1');
    end;
    SB.Append('">');
    SB.Append(LineEnding);

    IsComp := (Length(R.MatIds) = Length(V)) and (Length(V) > 0);

    { Coordinate + Normal. A composite slice serialises the SHARED position
      pool (unique positions) once and adds a per-vertex pool index
      (<O3DPoolIdx>) — the same indexed structure as the in-memory pooled
      composite. Plain meshes keep the per-vertex form (no cross-material
      sharing to gain). coordIndex above always indexes the per-vertex
      (compVert) list, NOT the Coordinate pool — the loader maps each vertex
      through O3DPoolIdx. }
    if IsComp then
    begin
      DedupVertexPositions(V, PIdx, PoolFirst, NPool);
      NCoord := NPool;
    end
    else
    begin
      PIdx   := nil;
      NCoord := Length(V);
    end;

    SB.Append('<Coordinate point="');
    for K := 0 to NCoord - 1 do
    begin
      if K > 0 then SB.Append(' ');
      if IsComp then J := PoolFirst[K] else J := K;
      AppendNum(SB, V[J].Position.X, DEC_POS); SB.Append(' ');
      AppendNum(SB, V[J].Position.Y, DEC_POS); SB.Append(' ');
      AppendNum(SB, V[J].Position.Z, DEC_POS);
    end;
    SB.Append('"/>');
    SB.Append(LineEnding);

    SB.Append('<Normal vector="');
    for K := 0 to NCoord - 1 do
    begin
      if K > 0 then SB.Append(' ');
      if IsComp then J := PoolFirst[K] else J := K;
      AppendNum(SB, V[J].Normal.X, DEC_NRM); SB.Append(' ');
      AppendNum(SB, V[J].Normal.Y, DEC_NRM); SB.Append(' ');
      AppendNum(SB, V[J].Normal.Z, DEC_NRM);
    end;
    SB.Append('"/>');
    SB.Append(LineEnding);

    { Per-vertex -> pool index. Composite slices only; its presence is the
      loader's signal that Coordinate/Normal are a pool. }
    if IsComp then
    begin
      SB.Append('<O3DPoolIdx index="');
      for K := 0 to High(V) do
      begin
        if K > 0 then SB.Append(' ');
        SB.Append(IntToStr(PIdx[K]));
      end;
      SB.Append('"/>');
      SB.Append(LineEnding);
    end;

    SB.Append('<TextureCoordinate point="');
    for K := 0 to High(V) do
    begin
      if K > 0 then SB.Append(' ');
      AppendNum(SB, V[K].UV.X, DEC_UV); SB.Append(' ');
      AppendNum(SB, V[K].UV.Y, DEC_UV);
    end;
    SB.Append('"/>');
    SB.Append(LineEnding);

    { Composite aux streams — parallel to the per-vertex (compVert) list.
      A standard X3D parser ignores unknown elements; our line scanner reads
      them back by tag name. }
    if IsComp then
    begin
      SB.Append('<O3DMatId values="');
      for K := 0 to High(V) do
      begin
        if K > 0 then SB.Append(' ');
        SB.Append(IntToStr(R.MatIds[K]));
      end;
      SB.Append('"/>');
      SB.Append(LineEnding);
    end;

    if Length(R.WaterScale) = Length(V) then
    begin
      SB.Append('<O3DWaterScale values="');
      for K := 0 to High(V) do
      begin
        if K > 0 then SB.Append(' ');
        AppendNum(SB, R.WaterScale[K], 6);
      end;
      SB.Append('"/>'); SB.Append(LineEnding);
    end;

    { Per-vertex global OSM id stream — parallel to the per-vertex list.
      Written only when at least one vertex carries an id, so terrain and
      other procedural meshes (all ids 0) add no bytes. }
    HasOsmId := False;
    for K := 0 to High(V) do
      if V[K].OsmId <> 0 then
      begin
        HasOsmId := True;
        Break;
      end;
    if HasOsmId then
    begin
      SB.Append('<O3DOsmId values="');
      for K := 0 to High(V) do
      begin
        if K > 0 then SB.Append(' ');
        SB.Append(IntToStr(V[K].OsmId));
      end;
      SB.Append('"/>');
      SB.Append(LineEnding);
    end;

    { Индексы граничных вершин — невидимая служебная структура. Стандартный
      X3D-парсер её игнорирует; наш построчный сканер читает её по имени тега.
      Пишем только если нарезчик что-то отметил. }
    if Length(R.BorderIdx) > 0 then
    begin
      SB.Append('<O3DBorderIdx index="');
      for K := 0 to High(R.BorderIdx) do
      begin
        if K > 0 then SB.Append(' ');
        SB.Append(IntToStr(R.BorderIdx[K]));
      end;
      SB.Append('"/>');
      SB.Append(LineEnding);
    end;

    SB.Append('</IndexedFaceSet>');  SB.Append(LineEnding);
    SB.Append('</Shape>');           SB.Append(LineEnding);
  end;

  procedure WriteMeta(const Name, Content: string);
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1008);{$ENDIF}
    SB.Append('<meta name="');  SB.Append(Name);
    SB.Append('" content="');   SB.Append(XmlEsc(Content));
    SB.Append('"/>');           SB.Append(LineEnding);
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1298);{$ENDIF}
  if Model = nil then
    raise ETileX3DError.Create('SaveStream: Model = nil');

  SB := TStringBuilder.Create;
  try
    SB.Append('<?xml version="1.0" encoding="UTF-8"?>'); SB.Append(LineEnding);
    SB.Append('<X3D profile="Interchange" version="3.3">'); SB.Append(LineEnding);
    SB.Append('<head>'); SB.Append(LineEnding);
    WriteMeta('generator', 'osm3d-studio tile cache');
    WriteMeta('o3d:format', IntToStr(GEO_TILE_FORMAT));
    WriteMeta('o3d:tile', Format('%d %s %d %d',
      [Model.TileId.Zone, HemiCh[Model.TileId.North],
       Int64(Model.TileId.TX), Int64(Model.TileId.TY)]));
    WriteMeta('o3d:origin',
      NumTok(Model.Origin.Lat, DEC_LL) + ' ' +
      NumTok(Model.Origin.Lon, DEC_LL));
    WriteMeta('o3d:bbox',
      NumTok(Model.Box.MinLat, DEC_LL) + ' ' +
      NumTok(Model.Box.MinLon, DEC_LL) + ' ' +
      NumTok(Model.Box.MaxLat, DEC_LL) + ' ' +
      NumTok(Model.Box.MaxLon, DEC_LL));
    WriteMeta('o3d:gen', Model.GenHash);
    SB.Append('</head>'); SB.Append(LineEnding);

    SB.Append('<Scene>'); SB.Append(LineEnding);
    for I := 0 to Model.MeshCount - 1 do
      WriteShape(Model.Meshes[I]);
    for I := 0 to Model.POICount - 1 do
    begin
      SB.Append('<O3DPoi kind="');
      SB.Append(POIKindName(Model.POIs[I].Kind));
      SB.Append('" translation="');
      AppendNum(SB, Model.POIs[I].Position.X, DEC_POS); SB.Append(' ');
      AppendNum(SB, Model.POIs[I].Position.Y, DEC_POS); SB.Append(' ');
      AppendNum(SB, Model.POIs[I].Position.Z, DEC_POS);
      SB.Append('" rotation="');
      AppendNum(SB, Model.POIs[I].Rotation, DEC_UV);
      SB.Append('"/>'); SB.Append(LineEnding);
    end;
    { Vegetation instances — kind flag + 6 floats (pos, scale, rot, seed). }
    for I := 0 to Model.TreeCount - 1 do
    { evaluate Model.Trees[I] (GetTree: bounds-check + record copy) ONCE per
      tree instead of seven times }
    with Model.Trees[I] do
    begin
      SB.Append('<O3DTree kind="');
      if IsShrub then SB.Append('shrub')
      else SB.Append('tree');
      SB.Append('" v="');
      AppendNum(SB, X,        DEC_POS); SB.Append(' ');
      AppendNum(SB, Y,        DEC_POS); SB.Append(' ');
      AppendNum(SB, Z,        DEC_POS); SB.Append(' ');
      AppendNum(SB, Scale,    DEC_UV);  SB.Append(' ');
      AppendNum(SB, Rotation, DEC_UV);  SB.Append(' ');
      AppendNum(SB, Seed,     DEC_UV);
      if Procedural.TypePlusOne <> 0 then
      begin
        SB.Append('" tree_version="2" gpu_type="');
        SB.Append(IntToStr(Procedural.TypePlusOne - 1));
        SB.Append('" lat_e7="'); SB.Append(IntToStr(Procedural.LatE7));
        SB.Append('" lon_e7="'); SB.Append(IntToStr(Procedural.LonE7));
      end;
      SB.Append('"/>'); SB.Append(LineEnding);
    end;
    for I:=0 to High(Model.Manholes) do
    with Model.Manholes[I] do begin
      SB.Append('<O3DManhole kind="');SB.Append(IntToStr(Kind));SB.Append('" v="');
      for J:=0 to 2 do begin AppendNum(SB,Position.Data[J],DEC_POS);SB.Append(' ') end;
      for J:=0 to 2 do begin AppendNum(SB,Normal.Data[J],DEC_UV);SB.Append(' ') end;
      AppendNum(SB,Rotation,DEC_UV);SB.Append('"/>');SB.Append(LineEnding);
    end;
    for I:=0 to High(Model.ModelInstances) do
    with Model.ModelInstances[I] do begin
      if (Pos('"',FileName)>0)or(Pos('&',FileName)>0)or(Pos('<',FileName)>0) then
        raise ETileX3DError.Create('Invalid model file name');
      SB.Append('<O3DModel file="');SB.Append(FileName);SB.Append('" v="');
      for J:=0 to 2 do begin AppendNum(SB,Position.Data[J],DEC_POS);SB.Append(' ');end;
      for J:=0 to 3 do begin AppendNum(SB,Rotation.Data[J],DEC_UV);SB.Append(' ');end;
      for J:=0 to 2 do begin AppendNum(SB,Scale.Data[J],DEC_UV);if J<2 then SB.Append(' ');end;
      SB.Append('"/>');SB.Append(LineEnding);
    end;
    { Road centerlines — one <O3DRoad> per way id: the width once, then the
      chained polyline points in v (shared segment endpoints are not repeated).
      A way normally forms a single run within a tile; if it leaves and
      re-enters it splits into disjoint runs and r lists the point-count of
      each run (r is omitted for a single run). The route snapper rebuilds the
      segments as consecutive point pairs per run, reproducing the old
      per-segment O3DRoadSeg set exactly. Segments of a way arrive contiguous
      and in node order. }
    I := 0;
    while I < Model.RoadSegCount do
    begin
      CurWay := Model.RoadSegs[I].WayId;
      J := I + 1;
      while (J < Model.RoadSegCount) and (Model.RoadSegs[J].WayId = CurWay) and
        (Model.RoadSegs[I].Surface.WidthStart=0) and (Model.RoadSegs[J].Surface.WidthStart=0) do
        Inc(J);
      SB.Append('<O3DRoad id="');
      SB.Append(IntToStr(CurWay));
      SB.Append('" w="');
      AppendNum(SB, Model.RoadSegs[I].Width, DEC_UV);
      if Model.RoadSegs[I].Surface.WidthStart>0 then begin
        SB.Append('" widths="');AppendNum(SB,Model.RoadSegs[I].Surface.WidthStart,6);
        SB.Append(' ');AppendNum(SB,Model.RoadSegs[I].Surface.WidthEnd,6);
      end;
      { BRIDGE_SNAP: flag first seg of way as representative (all segs of
        a bridge way share IsBridge from AppendBridgeSegs). }
      if Model.RoadSegs[I].IsBridge then
        SB.Append('" bridge="1');
      if Model.RoadSegs[I].Surface.UVScale > 0 then
      begin
        SB.Append('" surface="');
        SB.Append(IntToStr(Model.RoadSegs[I].Surface.ForwardLanes)); SB.Append(' ');
        SB.Append(IntToStr(Model.RoadSegs[I].Surface.BackwardLanes)); SB.Append(' ');
        AppendNum(SB, Model.RoadSegs[I].Surface.UVMin, 6); SB.Append(' ');
        AppendNum(SB, Model.RoadSegs[I].Surface.UVMax, 6); SB.Append(' ');
        AppendNum(SB, Model.RoadSegs[I].Surface.UVScale, 6); SB.Append(' ');
        SB.Append(IntToStr(Model.RoadSegs[I].Surface.Marked));
        SB.Append(' '); SB.Append(IntToStr(Model.RoadSegs[I].Surface.Asphalt));
        SB.Append(' '); SB.Append(IntToStr(Model.RoadSegs[I].Surface.Condition));
      end;
      if Model.RoadSegs[I].Surface.Layout.Count>0 then
      with Model.RoadSegs[I].Surface.Layout do
      begin
        SB.Append('" layout="'); SB.Append(IntToStr(Count)); SB.Append(' ');
        SB.Append(IntToStr(BothWays)); SB.Append(' '); AppendNum(SB,Edge,6);
        for K:=0 to Count-1 do begin SB.Append(' '); AppendNum(SB,Widths[K],6) end;
      end;
      SB.Append('" v="');
      RunStr := '';
      RunN   := 0;
      NRuns  := 0;
      for K := I to J - 1 do
      begin
        NewRun := (K = I) or
          (Abs(Model.RoadSegs[K].X0 - Model.RoadSegs[K - 1].X1) > 1e-4) or
          (Abs(Model.RoadSegs[K].Z0 - Model.RoadSegs[K - 1].Z1) > 1e-4);
        if NewRun then
        begin
          if K > I then RunStr := RunStr + IntToStr(RunN) + ' ';
          Inc(NRuns);
          if K > I then SB.Append(' ');
          AppendNum(SB, Model.RoadSegs[K].X0, DEC_POS); SB.Append(' ');
          AppendNum(SB, Model.RoadSegs[K].Z0, DEC_POS);
          RunN := 1;
        end;
        SB.Append(' ');
        AppendNum(SB, Model.RoadSegs[K].X1, DEC_POS); SB.Append(' ');
        AppendNum(SB, Model.RoadSegs[K].Z1, DEC_POS);
        Inc(RunN);
      end;
      RunStr := RunStr + IntToStr(RunN);
      SB.Append('"');
      if NRuns > 1 then
      begin
        SB.Append(' r="');
        SB.Append(RunStr);
        SB.Append('"');
      end;
      SB.Append('/>'); SB.Append(LineEnding);
      I := J;
    end;
    { BUILDING_OBSTACLE: foundation footprints for camera/rider push-out.
      One tag per obstacle: by/my heights + ring="x z x z ...". }
    for I := 0 to High(Model.BuildingObstacles) do
      with Model.BuildingObstacles[I] do
      begin
        if Length(Footprint) < 3 then Continue;
        SB.Append('<O3DBuildingObs by="');
        AppendNum(SB, BaseY, DEC_POS); SB.Append('" my="');
        AppendNum(SB, MaxY, DEC_POS);  SB.Append('" ring="');
        for J := 0 to High(Footprint) do
        begin
          if J > 0 then SB.Append(' ');
          AppendNum(SB, Footprint[J].X, DEC_POS); SB.Append(' ');
          AppendNum(SB, Footprint[J].Z, DEC_POS);
        end;
        SB.Append('"/>'); SB.Append(LineEnding);
      end;
    if Length(Model.FacadeLayouts)>0 then begin
      FacadesJSON:=FacadeLayoutsJSON(Model.FacadeLayouts,True);
      try SB.Append('<O3DFacades data="'); SB.Append(XmlEsc(FacadesJSON.AsJSON));
        SB.Append('"/>'); SB.Append(LineEnding);
      finally FacadesJSON.Free end;
    end;
    if Length(Model.BuildingTints)>0 then begin
      FacadesJSON:=BuildingTintsJSON(Model.BuildingTints);
      try SB.Append('<O3DBuildingTints data="'); SB.Append(XmlEsc(FacadesJSON.AsJSON));
        SB.Append('"/>'); SB.Append(LineEnding);
      finally FacadesJSON.Free end;
    end;
    SB.Append('</Scene>'); SB.Append(LineEnding);
    SB.Append('</X3D>');   SB.Append(LineEnding);

    Bytes := UTF8String(SB.ToString);
    FreeAndNil(SB); { the encoded string now owns the output; release builder capacity }
    if Length(Bytes) > 0 then
      Stream.WriteBuffer(Bytes[1], Length(Bytes));
  finally
    SB.Free;
  end;
end;

class procedure TTileX3D.SaveFile(const FileName: string; Model: TTileModel);
var FS: TFileStream;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1299);{$ENDIF}
  FS := TFileStream.Create(FileName, fmCreate);
  try
    SaveStream(FS, Model);
  finally
    FS.Free;
  end;
end;

function ParseBuildingObstacle(const Line: string; out O: TBuildingObstacle): Boolean;
var P, ByA, MyA: TDblArray; N, J: Integer;
begin
  Result:=False;
    P := ParseDoubleArray(GetAttr(Line, 'ring'));
    N := Length(P) div 2;
    if N < 3 then Exit;
    ByA := ParseDoubleArray(GetAttr(Line, 'by'));
    MyA := ParseDoubleArray(GetAttr(Line, 'my'));
    O := Default(TBuildingObstacle);
    SetLength(O.Footprint, N);
    for J := 0 to N - 1 do
    begin
      O.Footprint[J].X := P[J * 2];
      O.Footprint[J].Y := 0;
      O.Footprint[J].Z := P[J * 2 + 1];
    end;
    if Length(ByA) >= 1 then O.BaseY := ByA[0] else O.BaseY := 0;
    if Length(MyA) >= 1 then O.MaxY  := MyA[0] else O.MaxY  := O.BaseY + 3;
    RebuildObstacleAABB(O);
    O.TileKey := 0;
  Result:=True;
end;

class function TTileX3D.LoadStream(Stream: TStream): TTileModel;
type
  TDocumentState = (dsStart, dsBeforeHead, dsHead, dsBeforeScene,
    dsScene, dsAfterScene, dsDone);
var
  Raw:     UTF8String;
  Lines:   TStringList;
  Model:   TTileModel;
  LineIdx: Integer;
  L:       string;
  DocState: TDocumentState;
  SeenFormat, SeenTile, SeenGen, SeenOrigin, SeenBox: Boolean;
  InFaceSet, SeenFaceSet: Boolean;
  FacadesJSON:TJSONData;

  { current <Shape> accumulator }
  HaveShape: Boolean;
  CurName, CurMat: string;
  CurSolid: Boolean;
  CurIdx:  TIntArray;
  CurPos, CurNrm, CurUV: TTileSingleArray;
  CurMatIds: TIntArray;     { O3DMatId stream — empty for plain meshes }
  CurPoolIdx: TIntArray;    { O3DPoolIdx — per-vertex pool index; empty => Coordinate is per-vertex }
  CurWaterScale: TDblArray;
  CurOsmIds: TInt64Array;   { O3DOsmId stream — empty when no vertex tagged }
  CurBorderIdx: TIntArray;  { O3DBorderIdx — индексы граничных вершин; пусто, если тега нет }

  procedure Require(Condition: Boolean; const Msg: string);
  begin
    if not Condition then
      raise ETileX3DError.CreateFmt('Invalid tile cache at line %d: %s',
        [LineIdx + 1, Msg]);
  end;

  procedure ResetShape;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1009);{$ENDIF}
    HaveShape := False;
    InFaceSet := False;
    SeenFaceSet := False;
    CurName := '';  CurMat := '';  CurSolid := True;
    SetLength(CurIdx, 0);
    SetLength(CurPos, 0);
    SetLength(CurNrm, 0);
    SetLength(CurUV,  0);
    SetLength(CurMatIds, 0);
    SetLength(CurPoolIdx, 0);
    SetLength(CurOsmIds, 0);
    SetLength(CurWaterScale, 0);
    SetLength(CurBorderIdx, 0);
  end;

  procedure FinalizeShape;
  var
    Mesh: TMesh;
    VC, NP, PI, I, NF, T, A, B, C: Integer;
    Vtx:  TMeshVertex;
    Triangle: array[0..2] of Integer;
    MatIds:  TTileMatIdArray;
    WaterScale: TTileWaterScaleArray;
    Pooled: Boolean;
    NB: Integer;                 { счётчик валидных граничных индексов }
    BFilt: TTileMatIdArray;      { отфильтрованные граничные индексы }
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1010);{$ENDIF}
    if not HaveShape then Exit;

    { Pooled (composite) format: Coordinate/Normal hold the shared position
      pool (NP entries) and O3DPoolIdx maps each vertex (compVert) to it, so
      the per-vertex count is the pool-index length. Plain format: Coordinate
      is the per-vertex list directly. }
    Pooled := Length(CurPoolIdx) > 0;
    NP := Length(CurPos) div 3;
    if Pooled then VC := Length(CurPoolIdx)
    else            VC := NP;
    if (VC = 0) or (Length(CurIdx) < 3) then Exit;

    Mesh := TMesh.Create(CurName);
    try
      Mesh.ReserveVertices(VC);
      for I := 0 to VC - 1 do
      begin
        if Pooled then
        begin
          PI := CurPoolIdx[I];
          if (PI >= 0) and (PI < NP) then
            Vtx.Position := Vector3(CurPos[PI*3], CurPos[PI*3+1], CurPos[PI*3+2])
          else
            Vtx.Position := Vector3(0, 0, 0);
          if (PI >= 0) and (Length(CurNrm) >= (PI+1)*3) then
            Vtx.Normal := Vector3(CurNrm[PI*3], CurNrm[PI*3+1], CurNrm[PI*3+2])
          else
            Vtx.Normal := Vector3(0, 1, 0);
        end
        else
        begin
          Vtx.Position := Vector3(CurPos[I*3], CurPos[I*3+1], CurPos[I*3+2]);
          if Length(CurNrm) >= (I+1)*3 then
            Vtx.Normal := Vector3(CurNrm[I*3], CurNrm[I*3+1], CurNrm[I*3+2])
          else
            Vtx.Normal := Vector3(0, 1, 0);
        end;

        if Length(CurUV) >= (I+1)*2 then
          Vtx.UV := Vector2(CurUV[I*2], CurUV[I*2+1])
        else
          Vtx.UV := Vector2(0, 0);
        { Per-vertex OSM id — present only when the tile carried an
          <O3DOsmId> stream covering every vertex; 0 otherwise. }
        if Length(CurOsmIds) = VC then
          Vtx.OsmId := CurOsmIds[I]
        else
          Vtx.OsmId := 0;
        Mesh.AddVertex(Vtx);
      end;

      { coordIndex -> triangles: drop -1 separators, then take 3 at a time
        (the writer only ever emits triangles). Indices are over the
        per-vertex (compVert) list, range VC, in both formats. }
      NF := 0;
      for I := 0 to High(CurIdx) do
        if CurIdx[I] >= 0 then Inc(NF);
      Mesh.ReserveIndices((NF div 3) * 3);
      T := 0;
      for I := 0 to High(CurIdx) do
        if CurIdx[I] >= 0 then
        begin
          Triangle[T] := CurIdx[I];
          Inc(T);
          if T = 3 then
          begin
            A := Triangle[0]; B := Triangle[1]; C := Triangle[2];
            if (A < VC) and (B < VC) and (C < VC) then
              Mesh.AddTriangle(A, B, C);
            T := 0;
          end;
        end;

      { Composite aux stream — kept only when it covers every vertex
        (a ground-composite slice). Otherwise dropped → a plain mesh. }
      SetLength(MatIds, 0);
      if Length(CurMatIds) = VC then
      begin
        SetLength(MatIds, VC);
        for I := 0 to VC - 1 do MatIds[I] := CurMatIds[I];
      end;

      WaterScale := nil;
      if Length(CurWaterScale) <> 0 then
      begin
        Require(Length(CurWaterScale) = VC, 'water scale vertex count');
        SetLength(WaterScale, VC);
        for I := 0 to VC - 1 do
        begin
          Require(not IsNan(CurWaterScale[I]) and not IsInfinite(CurWaterScale[I])
            and (CurWaterScale[I] >= -1) and (CurWaterScale[I] <= 1)
            and ((CurWaterScale[I] >= 0) or (CurWaterScale[I] = -1)), 'water scale range');
          WaterScale[I] := CurWaterScale[I];
        end;
      end;
      Model.AddCompositeMesh(CurName, MaterialFromName(CurMat), Mesh,
                             MatIds, CurSolid);
      Model.SetWaterScale(Model.MeshCount - 1, WaterScale);

      { Граничные индексы — отбрасываем всё вне диапазона [0..VC-1]
        (защита от повреждённого кэша) и кладём в только что добавленный
        меш (Model.MeshCount-1). }
      if Length(CurBorderIdx) > 0 then
      begin
        SetLength(BFilt, Length(CurBorderIdx));
        NB := 0;
        for I := 0 to High(CurBorderIdx) do
          if (CurBorderIdx[I] >= 0) and (CurBorderIdx[I] < VC) then
          begin
            BFilt[NB] := CurBorderIdx[I];
            Inc(NB);
          end;
        SetLength(BFilt, NB);
        if NB > 0 then
          Model.SetBorderIdx(Model.MeshCount - 1, BFilt);
      end;
    except
      Mesh.Free;
      raise;
    end;
  end;

  procedure HandleMeta(const Line: string);
  var
    Name, Content: string;
    P:   TDblArray;
    Tok: array of string;
    N, Pp, Qq, Lc: Integer;
    ZoneValue, XValue, YValue: Int64;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1011);{$ENDIF}
    Name    := GetAttr(Line, 'name');
    Content := GetAttr(Line, 'content');
    if Name = 'o3d:format' then
    begin
      Require(not SeenFormat, 'duplicate format');
      Require(Content = IntToStr(GEO_TILE_FORMAT), 'unsupported format');
      SeenFormat := True;
    end
    else if Name = 'o3d:origin' then
    begin
      Require(not SeenOrigin, 'duplicate origin');
      P := ParseDoubleArray(Content);
      Require(Length(P) = 2, 'invalid origin');
      Model.Origin := TLatLon.Make(P[0], P[1]);
      SeenOrigin := True;
    end
    else if Name = 'o3d:bbox' then
    begin
      Require(not SeenBox, 'duplicate bbox');
      P := ParseDoubleArray(Content);
      Require(Length(P) = 4, 'invalid bbox');
      Model.Box := TLatLonBox.Make(P[0], P[1], P[2], P[3]);
      SeenBox := True;
    end
    else if Name = 'o3d:gen' then
    begin
      Require(not SeenGen, 'duplicate generator');
      Model.GenHash := Content;
      SeenGen := True;
    end
    else if Name = 'o3d:tile' then
    begin
      Require(not SeenTile, 'duplicate tile identity');
      SetLength(Tok, 0);
      N := 0; Pp := 1; Lc := Length(Content);
      while Pp <= Lc do
      begin
        while (Pp <= Lc) and (Content[Pp] <= ' ') do Inc(Pp);
        if Pp > Lc then Break;
        Qq := Pp;
        while (Qq <= Lc) and (Content[Qq] > ' ') do Inc(Qq);
        SetLength(Tok, N + 1);
        Tok[N] := Copy(Content, Pp, Qq - Pp);
        Inc(N);
        Pp := Qq;
      end;
      Require(N = 4, 'invalid tile identity');
      Require(TryStrToInt64(Tok[0], ZoneValue) and (ZoneValue >= 0) and
        (ZoneValue <= High(Byte)), 'invalid tile zone');
      Require((UpperCase(Tok[1]) = 'N') or (UpperCase(Tok[1]) = 'S'), 'invalid hemisphere');
      Require(TryStrToInt64(Tok[2], XValue) and (XValue >= 0) and
        (XValue <= High(Cardinal)), 'invalid tile X');
      Require(TryStrToInt64(Tok[3], YValue) and (YValue >= 0) and
        (YValue <= High(Cardinal)), 'invalid tile Y');
      Model.TileId := TGeoTileId.Make(Byte(ZoneValue), UpperCase(Tok[1]) = 'N',
        Cardinal(XValue), Cardinal(YValue));
      SeenTile := True;
    end;
  end;

  procedure HandlePOI(const Line: string);
  var
    P:   TDblArray;
    Pos: TVector3;
    Rot: TDblArray;
    Yaw: Single;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1012);{$ENDIF}
    P := ParseDoubleArray(GetAttr(Line, 'translation'));
    if Length(P) >= 3 then
      Pos := Vector3(P[0], P[1], P[2])
    else
      Pos := Vector3(0, 0, 0);
    { rotation attribute is optional — older tiles have none ⇒ yaw 0. }
    Rot := ParseDoubleArray(GetAttr(Line, 'rotation'));
    if Length(Rot) >= 1 then Yaw := Rot[0] else Yaw := 0;
    Model.AddPOI(POIKindFromName(GetAttr(Line, 'kind')), Pos, Yaw);
  end;

  procedure HandleTree(const Line: string);
  var
    P: TDblArray;
    R: TTileTreeRec;
    Code, Lat, Lon: Int64;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1013);{$ENDIF}
    P := ParseDoubleArray(GetAttr(Line, 'v'));
    if Length(P) < 6 then Exit;
    R := Default(TTileTreeRec);
    R.X        := P[0];
    R.Y        := P[1];
    R.Z        := P[2];
    R.Scale    := P[3];
    R.Rotation := P[4];
    R.Seed     := P[5];
    R.IsShrub  := GetAttr(Line, 'kind') = 'shrub';
    if GetAttr(Line, 'tree_version') = '2' then
    begin
      Code := StrToInt64Def(GetAttr(Line, 'gpu_type'), -1);
      Lat := StrToInt64Def(GetAttr(Line, 'lat_e7'), High(Int64));
      Lon := StrToInt64Def(GetAttr(Line, 'lon_e7'), High(Int64));
      { Invalid extensions retain the old visual fallback, never abort a tile. }
      if (Code >= 0) and (Code <= TREE_TYPE_USED_MASK) and
         ((Code and 255) <= Ord(High(TTreeSpecies))) and
         (Lat >= -900000000) and (Lat <= 900000000) and
         (Lon >= -1800000000) and (Lon <= 1800000000) then
      begin
        R.Procedural.TypePlusOne := Code + 1;
        R.Procedural.LatE7 := Lat; R.Procedural.LonE7 := Lon;
      end;
    end;
    Model.AddTree(R);
  end;

  procedure HandleManhole(const Line:string);
  var P:TDblArray; R:TManhole; I,N:Integer;
  begin
    P:=ParseDoubleArray(GetAttr(Line,'v'));
    Require(Length(P)=7,'invalid manhole placement');
    for I:=0 to 6 do Require(not IsNan(P[I]) and not IsInfinite(P[I]) and
      (Abs(P[I])<1e7),'non-finite manhole placement');
    R.Kind:=StrToIntDef(GetAttr(Line,'kind'),-1);
    Require((R.Kind>=0)and(R.Kind<MANHOLE_COUNT),'invalid manhole kind');
    R.Position:=Vector3(P[0],P[1],P[2]);R.Normal:=Vector3(P[3],P[4],P[5]);
    Require((R.Normal.Length>0.9)and(R.Normal.Length<1.1)and(R.Normal.Y>0.5),'invalid manhole normal');
    R.Normal:=R.Normal.Normalize;R.Rotation:=P[6];
    N:=Length(Model.Manholes);Require(N<100000,'too many manholes');
    SetLength(Model.Manholes,N+1);Model.Manholes[N]:=R;
  end;

  procedure HandleModel(const Line: string);
  var P:TDblArray;R:TTileModelInstance;I,N:Integer;
  begin
    P:=ParseDoubleArray(GetAttr(Line,'v'));
    Require(Length(P)=10,'invalid model transform');
    for I:=0 to 9 do Require(not IsNan(P[I])and not IsInfinite(P[I])and(Abs(P[I])<1e7),'non-finite model transform');
    R.FileName:=GetAttr(Line,'file');Require(R.FileName<>'','empty model file');
    R.Position:=Vector3(P[0],P[1],P[2]);R.Rotation:=Vector4(P[3],P[4],P[5],P[6]);
    R.Scale:=Vector3(P[7],P[8],P[9]);
    Require((P[7]>0)and(P[8]>0)and(P[9]>0),'invalid model scale');
    Require(Sqr(P[3])+Sqr(P[4])+Sqr(P[5])>1e-12,'invalid model rotation axis');
    N:=Length(Model.ModelInstances);Require(N<100000,'too many model instances');
    SetLength(Model.ModelInstances,N+1);Model.ModelInstances[N]:=R;
  end;

  procedure HandleRoadSeg(const Line: string);
  var
    P:  TDblArray;
    W:  TDblArray;
    Id: TInt64Array;
    R:  TTileRoadSeg;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1815);{$ENDIF}
    P := ParseDoubleArray(GetAttr(Line, 'v'));
    if Length(P) < 4 then Exit;
    R := Default(TTileRoadSeg);
    R.X0 := P[0];  R.Z0 := P[1];
    R.X1 := P[2];  R.Z1 := P[3];
    W := ParseDoubleArray(GetAttr(Line, 'w'));
    if Length(W) >= 1 then R.Width := W[0] else R.Width := 0;
    Id := ParseInt64Array(GetAttr(Line, 'wayId'));
    if Length(Id) >= 1 then R.WayId := Id[0] else R.WayId := 0;
    Model.AddRoadSeg(R);
  end;

  procedure HandleRoad(const Line: string);
  var
    P, W, Rn: TDblArray;
    Id:       TInt64Array;
    R:        TTileRoadSeg;
    np, base, ri, cnt, s: Integer;
    BrAttr: string;
  begin
    P  := ParseDoubleArray(GetAttr(Line, 'v'));
    np := Length(P) div 2;                 { polyline point count }
    if np < 2 then Exit;
    R := Default(TTileRoadSeg);
    W := ParseDoubleArray(GetAttr(Line, 'w'));
    if Length(W) >= 1 then R.Width := W[0] else R.Width := 0;
    Id := ParseInt64Array(GetAttr(Line, 'id'));
    if Length(Id) >= 1 then R.WayId := Id[0] else R.WayId := 0;
    { BRIDGE_SNAP }
    BrAttr := GetAttr(Line, 'bridge');
    R.IsBridge := (BrAttr = '1') or (BrAttr = 'true') or (BrAttr = 'yes');
    W := ParseDoubleArray(GetAttr(Line, 'surface'));
    if Length(W) >= 6 then
    begin
      R.Surface.ForwardLanes := EnsureRange(Round(W[0]), 0, 32);
      R.Surface.BackwardLanes := EnsureRange(Round(W[1]), 0, 32);
      R.Surface.UVMin := W[2]; R.Surface.UVMax := W[3];
      R.Surface.UVScale := W[4]; R.Surface.Marked := Ord(W[5] > 0.5);
      if Length(W)>=7 then R.Surface.Asphalt:=EnsureRange(Round(W[6]),ROAD_SURFACE_UNKNOWN,ROAD_SURFACE_CONCRETE);
      if Length(W)>=8 then R.Surface.Condition:=EnsureRange(Round(W[7]),0,5);
      if (R.Surface.UVMax <= R.Surface.UVMin) or (W[4] <= 0) or (W[4] > 1000) then
        R.Surface := Default(TRoadSurfaceProfile);
    end;
    W := ParseDoubleArray(GetAttr(Line,'layout'));
    if Length(W)>=4 then
    begin
      cnt:=EnsureRange(Round(W[0]),1,ROAD_MAX_LANES);
      if (Length(W)=cnt+3) and (W[2]>=0) and (W[2]<R.Width*0.5) then
      begin
        R.Surface.Layout.Count:=cnt;
        R.Surface.Layout.BothWays:=EnsureRange(Round(W[1]),0,cnt-1);
        R.Surface.Layout.Edge:=W[2];
        for s:=0 to cnt-1 do
        begin
          R.Surface.Layout.Widths[s]:=W[s+3];
          if (W[s+3]<=0) or (W[s+3]>200) then R.Surface.Layout.Count:=0;
          if Abs(W[s+3]-W[3])>0.001 then R.Surface.Layout.Custom:=1;
        end;
      end;
    end;
    W:=ParseDoubleArray(GetAttr(Line,'widths'));
    if (Length(W)=2) and (np=2) then begin
      if (W[0]<0.5) or (W[1]<0.5) or (W[0]>60) or (W[1]>60) then
        raise Exception.Create('Invalid O3DRoad endpoint widths');
      R.Surface.WidthStart:=W[0];R.Surface.WidthEnd:=W[1];
      R.Width:=Max(R.Width,Max(W[0],W[1]));
    end;
    Rn := ParseDoubleArray(GetAttr(Line, 'r'));
    if Length(Rn) = 0 then
    begin
      SetLength(Rn, 1);
      Rn[0] := np;                         { no r -> the whole polyline }
    end;
    base := 0;
    for ri := 0 to High(Rn) do
    begin
      cnt := Round(Rn[ri]);
      if cnt < 0 then cnt := 0;
      if base + cnt > np then cnt := np - base;   { defensive clamp }
      if cnt < 0 then cnt := 0;
      if cnt >= 2 then
        for s := 0 to cnt - 2 do
        begin
          R.X0 := P[(base + s) * 2];       R.Z0 := P[(base + s) * 2 + 1];
          R.X1 := P[(base + s + 1) * 2];   R.Z1 := P[(base + s + 1) * 2 + 1];
          Model.AddRoadSeg(R);
        end;
      Inc(base, cnt);
    end;
  end;

  procedure HandleBuildingObs(const Line: string);
  var O: TBuildingObstacle; K: Integer;
  begin
    if not ParseBuildingObstacle(Line,O) then Exit;
    K:=Length(Model.BuildingObstacles);
    SetLength(Model.BuildingObstacles,K+1); Model.BuildingObstacles[K]:=O;
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1339);{$ENDIF}
  { Large city tiles can exceed 200 MiB. Release text as it is consumed,
    rather than retaining the entire input alongside all decoded meshes. }
  SetLength(Raw, Stream.Size - Stream.Position);
  if Length(Raw) > 0 then
    Stream.ReadBuffer(Raw[1], Length(Raw));

  Model := TTileModel.Create;
  Lines := TStringList.Create;
  try
    Lines.Text := string(Raw);
    Raw := ''; { TStringList owns its lines now }
    ResetShape;
    DocState := dsStart;
    SeenFormat := False; SeenTile := False; SeenGen := False;
    SeenOrigin := False; SeenBox := False;

    for LineIdx := 0 to Lines.Count - 1 do
    begin
      L := Trim(Lines[LineIdx]);
      Lines[LineIdx] := ''; { parsed lines are never revisited }
      if L = '' then Continue;
      Require(DocState <> dsDone, 'data after X3D end');

      if LineIsTag(L, '<X3D ') then
      begin
        Require(DocState = dsStart, 'unexpected X3D start');
        DocState := dsBeforeHead;
      end
      else if L = '<head>' then
      begin
        Require(DocState = dsBeforeHead, 'unexpected head start');
        DocState := dsHead;
      end
      else if L = '</head>' then
      begin
        Require(DocState = dsHead, 'unexpected head end');
        Require(SeenFormat and SeenTile and SeenGen and SeenOrigin and SeenBox,
          'missing required metadata');
        DocState := dsBeforeScene;
      end
      else if L = '<Scene>' then
      begin
        Require(DocState = dsBeforeScene, 'unexpected Scene start');
        DocState := dsScene;
      end
      else if L = '</Scene>' then
      begin
        Require((DocState = dsScene) and (not HaveShape), 'incomplete Scene');
        DocState := dsAfterScene;
      end
      else if L = '</X3D>' then
      begin
        Require(DocState = dsAfterScene, 'incomplete X3D');
        DocState := dsDone;
      end
      else if LineIsTag(L, '<meta ') then
      begin
        Require(DocState = dsHead, 'metadata outside head');
        HandleMeta(L);
      end
      else if LineIsTag(L, '<Shape') then
      begin
        Require((DocState = dsScene) and (not HaveShape), 'unexpected Shape start');
        ResetShape;
        HaveShape := True;
        CurName := GetAttr(L, 'o3dName');
        CurMat  := GetAttr(L, 'o3dMaterial');
      end
      else if LineIsTag(L, '<IndexedFaceSet') then
      begin
        Require(HaveShape and (not SeenFaceSet), 'unexpected IndexedFaceSet start');
        SeenFaceSet := True;
        InFaceSet := True;
        CurSolid := GetAttr(L, 'solid') <> 'false';
        CurIdx   := ParseIntArray(GetAttr(L, 'coordIndex'));
      end
      else if L = '</IndexedFaceSet>' then
      begin
        Require(InFaceSet, 'unexpected IndexedFaceSet end');
        InFaceSet := False;
      end
      else if LineIsTag(L, '<Coordinate') then
        CurPos := ParseSingleArray(GetAttr(L, 'point'))
      else if LineIsTag(L, '<Normal') then
        CurNrm := ParseSingleArray(GetAttr(L, 'vector'))
      else if LineIsTag(L, '<TextureCoordinate') then
        CurUV := ParseSingleArray(GetAttr(L, 'point'))
      else if LineIsTag(L, '<O3DMatId') then
        CurMatIds := ParseIntArray(GetAttr(L, 'values'))
      else if LineIsTag(L, '<O3DWaterScale') then
        CurWaterScale := ParseDoubleArray(GetAttr(L, 'values'))
      else if LineIsTag(L, '<O3DPoolIdx') then
        CurPoolIdx := ParseIntArray(GetAttr(L, 'index'))
      else if LineIsTag(L, '<O3DOsmId') then
        CurOsmIds := ParseInt64Array(GetAttr(L, 'values'))
      else if LineIsTag(L, '<O3DBorderIdx') then
        CurBorderIdx := ParseIntArray(GetAttr(L, 'index'))
      else if L = '</Shape>' then
      begin
        Require(HaveShape and SeenFaceSet and (not InFaceSet), 'incomplete Shape');
        FinalizeShape;
        ResetShape;
      end
      else if LineIsTag(L, '<O3DPoi') then
        HandlePOI(L)
      else if LineIsTag(L, '<O3DManhole') then HandleManhole(L)
      else if LineIsTag(L, '<O3DTree') then
        HandleTree(L)
      else if LineIsTag(L, '<O3DModel') then
        HandleModel(L)
      else if LineIsTag(L, '<O3DRoad ') then
        HandleRoad(L)
      else if LineIsTag(L, '<O3DRoadSeg') then
        HandleRoadSeg(L)
      else if LineIsTag(L, '<O3DBuildingObs') then
        HandleBuildingObs(L)   { BUILDING_OBSTACLE }
      else if LineIsTag(L, '<O3DFacades ') then begin
        Require(Length(Model.FacadeLayouts)=0,'duplicate facade layout');
        FacadesJSON:=GetJSON(GetAttr(L,'data'));
        try Model.FacadeLayouts:=ParseFacadeLayouts(FacadesJSON,True) finally FacadesJSON.Free end;
      end
      else if LineIsTag(L, '<O3DBuildingTints ') then begin
        Require(Length(Model.BuildingTints)=0,'duplicate building tints');
        FacadesJSON:=GetJSON(GetAttr(L,'data'));
        try Model.BuildingTints:=ParseBuildingTints(FacadesJSON) finally FacadesJSON.Free end;
      end;
      { Unknown extensions remain supported inside the document. This
        reader accepts the line-oriented cache format written above. }
    end;

    Require((DocState = dsDone) and (not HaveShape), 'truncated document');
    Result := Model;
  except
    Model.Free;
    Lines.Free;
    raise;
  end;
  Lines.Free;
end;

class function TTileX3D.LoadFile(const FileName: string): TTileModel;
var FS: TFileStream;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1340);{$ENDIF}
  FS := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  try
    Result := LoadStream(FS);
  finally
    FS.Free;
  end;
end;

{ ═══════════════ Ground-shadow mask engine (byte CPU rasteriser) ═════════ }

{ Tree-shadow alpha state + ShadowIntensityFor — в Osm3dTreeShadow. }

{ project one wall/roof triangle (object XZ) into the byte mask, barycentric
  intensity, union (darkest wins). }
class function TTileX3D.LoadBuildingObstacles(const FileName: string;
  out Origin: TLatLon): TBuildingObstacleArray;
var
  F: TFileStream; Buf: array[0..65535] of AnsiChar;
  Pending, Tag, Chunk: AnsiString; P, Q, N, Count: Integer;
  O: TBuildingObstacle; V: TDblArray; HaveOrigin: Boolean;
begin
  Result:=nil; Count:=0; HaveOrigin:=False;
  F:=TFileStream.Create(FileName,fmOpenRead or fmShareDenyWrite);
  try
    Pending:='';
    repeat
      N:=F.Read(Buf,SizeOf(Buf));
      if N=0 then Break;
      SetString(Chunk,PAnsiChar(@Buf[0]),N); Pending:=Pending+Chunk;
      repeat
        P:=Pos('<',Pending);
        if P=0 then begin Pending:=''; Break end;
        if P>1 then Delete(Pending,1,P-1);
        { Mesh attributes can span megabytes. Retain only tags we need. }
        if (Length(Pending)>=16) and
          (Copy(Pending,1,5)<>'<meta') and
          (Copy(Pending,1,16)<>'<O3DBuildingObs ') then
        begin
          Delete(Pending,1,1); Continue;
        end;
        Q:=Pos('>',Pending); if Q=0 then Break;
        Tag:=Copy(Pending,1,Q); Delete(Pending,1,Q);
        if (Copy(Tag,1,5)='<meta') and (GetAttr(Tag,'name')='o3d:origin') then
        begin
          V:=ParseDoubleArray(GetAttr(Tag,'content'));
          if Length(V)<>2 then raise Exception.Create('invalid obstacle tile origin');
          Origin:=TLatLon.Make(V[0],V[1]); HaveOrigin:=True;
        end
        else if (Copy(Tag,1,16)='<O3DBuildingObs ') and ParseBuildingObstacle(Tag,O) then
        begin
          if Count=Length(Result) then SetLength(Result,Max(64,Count*2));
          Result[Count]:=O; Inc(Count);
        end;
      until False;
      if Length(Pending)>=1024*1024 then raise Exception.Create('oversized obstacle tag');
    until False;
    if not HaveOrigin then raise Exception.Create('missing obstacle tile origin');
    SetLength(Result,Count);
  finally F.Free end;
end;

procedure RasterizeTriToMaskB(M: TShadowMaskBytes; MW, MH: Integer;
  const A, B, C, OriginV, SizeV: TVector2; IA, IB, IC: Byte);
var
  x, y, minx, maxx, miny, maxy, inten, idx: Integer;
  ax, ay, bx, by, cx, cy, d, w0, w1, w2: Single;

  function PixX(const VX: Single): Single; inline;
  begin Result := MaskPixCoord(VX, OriginV.X, SizeV.X, MW); end;
  function PixY(const VZ: Single): Single; inline;
  begin Result := MaskPixCoord(VZ, OriginV.Y, SizeV.Y, MH); end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1816);{$ENDIF}
  ax := PixX(A.X); ay := PixY(A.Y);
  bx := PixX(B.X); by := PixY(B.Y);
  cx := PixX(C.X); cy := PixY(C.Y);
  d := (by - cy) * (ax - cx) + (cx - bx) * (ay - cy);
  if Abs(d) < 1e-9 then Exit;
  minx := Max(0,      Floor(Min(ax, Min(bx, cx))));
  maxx := Min(MW - 1, Ceil (Max(ax, Max(bx, cx))));
  miny := Max(0,      Floor(Min(ay, Min(by, cy))));
  maxy := Min(MH - 1, Ceil (Max(ay, Max(by, cy))));
  for y := miny to maxy do
    for x := minx to maxx do
    begin
      w0 := ((by - cy) * (x - cx) + (cx - bx) * (y - cy)) / d;
      w1 := ((cy - ay) * (x - cx) + (ax - cx) * (y - cy)) / d;
      w2 := 1.0 - w0 - w1;
      if (w0 >= -0.001) and (w1 >= -0.001) and (w2 >= -0.001) then
      begin
        inten := Round(w0 * IA + w1 * IB + w2 * IC);
        if inten < 0 then inten := 0 else if inten > 255 then inten := 255;
        idx := y * MW + x;
        if inten > M[idx] then M[idx] := inten;
      end;
    end;
end;

function RasterizeShrubBlobToMaskB(M: TShadowMaskBytes; MW, MH: Integer;
  const CenterXZ: TVector2; R, SlideLen: Single;
  const OriginV, SizeV: TVector2): Boolean;
var
  x, y, minx, maxx, miny, maxy, baseInt, inten, idx: Integer;
  cxp, czp, rxp, rzp, wx, wz, dx, dz, d, f, R2: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1817);{$ENDIF}
  Result := False;
  if R <= 0.01 then Exit;
  R2 := R * R;
  cxp := ((CenterXZ.X - OriginV.X) / SizeV.X) * (MW - 1);
  czp := ((CenterXZ.Y - OriginV.Y) / SizeV.Y) * (MH - 1);
  rxp := (R / SizeV.X) * (MW - 1);
  rzp := (R / SizeV.Y) * (MH - 1);
  minx := Max(0,      Floor(cxp - rxp));
  maxx := Min(MW - 1, Ceil (cxp + rxp));
  miny := Max(0,      Floor(czp - rzp));
  maxy := Min(MH - 1, Ceil (czp + rzp));
  baseInt := ShadowIntensityFor(SlideLen);
  for y := miny to maxy do
    for x := minx to maxx do
    begin
      wx := OriginV.X + (x / (MW - 1)) * SizeV.X;
      wz := OriginV.Y + (y / (MH - 1)) * SizeV.Y;
      dx := wx - CenterXZ.X;  dz := wz - CenterXZ.Y;
      d := dx * dx + dz * dz;
      if d > R2 then Continue;
      d := Sqrt(d);
      f := 1.0;
      if d > 0.6 * R then f := (R - d) / (0.4 * R);
      if f <= 0.0 then Continue;
      inten := 255;   { flat blob shadow (no radial gradient) }
      idx := y * MW + x;
      if inten > M[idx] then M[idx] := inten;
      Result := True;
    end;
end;

function RasterizeTreeCardToMaskB(M: TShadowMaskBytes; MW, MH: Integer;
  Alpha: TGrayscaleImage; const BaseXZ, RightXZ, SlideXZ: TVector2; W: Single;
  const OriginV, SizeV: TVector2): Boolean;
var
  aw, ah, x, y, minx, maxx, miny, maxy, axp, ayp, inten, ap, idx: Integer;
  Ox, Oz, EuX, EuZ, EvX, EvZ, det, wx, wz, dx, dz, ux, vy, sl: Single;
  c0x, c0y, c1x, c1y, c2x, c2y, c3x, c3y: Single;

  function PixX(const VX: Single): Single; inline;
  begin Result := MaskPixCoord(VX, OriginV.X, SizeV.X, MW); end;
  function PixY(const VZ: Single): Single; inline;
  begin Result := MaskPixCoord(VZ, OriginV.Y, SizeV.Y, MH); end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1818);{$ENDIF}
  Result := False;
  if Alpha = nil then Exit;
  aw := Alpha.Width;   ah := Alpha.Height;
  if (aw < 2) or (ah < 2) then Exit;
  EuX := W * RightXZ.X;  EuZ := W * RightXZ.Y;
  EvX := SlideXZ.X;      EvZ := SlideXZ.Y;
  Ox := BaseXZ.X - 0.5 * EuX;  Oz := BaseXZ.Y - 0.5 * EuZ;
  det := EuX * EvZ - EuZ * EvX;
  if Abs(det) < 1e-9 then Exit;
  c0x := PixX(Ox);             c0y := PixY(Oz);
  c1x := PixX(Ox + EuX);       c1y := PixY(Oz + EuZ);
  c2x := PixX(Ox + EvX);       c2y := PixY(Oz + EvZ);
  c3x := PixX(Ox + EuX + EvX); c3y := PixY(Oz + EuZ + EvZ);
  minx := Max(0,      Floor(Min(Min(c0x, c1x), Min(c2x, c3x))));
  maxx := Min(MW - 1, Ceil (Max(Max(c0x, c1x), Max(c2x, c3x))));
  miny := Max(0,      Floor(Min(Min(c0y, c1y), Min(c2y, c3y))));
  maxy := Min(MH - 1, Ceil (Max(Max(c0y, c1y), Max(c2y, c3y))));
  sl := Sqrt(SlideXZ.X * SlideXZ.X + SlideXZ.Y * SlideXZ.Y);
  for y := miny to maxy do
    for x := minx to maxx do
    begin
      wx := OriginV.X + (x / (MW - 1)) * SizeV.X;
      wz := OriginV.Y + (y / (MH - 1)) * SizeV.Y;
      dx := wx - Ox;  dz := wz - Oz;
      ux := ( EvZ * dx - EvX * dz) / det;
      vy := (-EuZ * dx + EuX * dz) / det;
      if (ux < 0.0) or (ux > 1.0) or (vy < 0.0) or (vy > 1.0) then Continue;
      axp := Trunc(ux * (aw - 1));
      ayp := Trunc(vy * (ah - 1));
      if axp < 0 then axp := 0 else if axp > aw - 1 then axp := aw - 1;
      if ayp < 0 then ayp := 0 else if ayp > ah - 1 then ayp := ah - 1;
      ap := PByte(Alpha.PixelPtr(axp, ayp))^;
      if ap < 128 then Continue;
      inten := 255;   { flat crown shadow (no length gradient) }
      idx := y * MW + x;
      if inten > M[idx] then M[idx] := inten;
      Result := True;
    end;
end;

function RasterizeTreeCardRegB(const C: TShadowTreeCard; M: TShadowMaskBytes;
  MW, MH: Integer; const OriginV, SizeV: TVector2): Boolean;
var
  sl: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1819);{$ENDIF}
  if C.Kind = sckShrubBlob then
  begin
    sl := Sqrt(C.SlideX * C.SlideX + C.SlideZ * C.SlideZ);
    Result := RasterizeShrubBlobToMaskB(M, MW, MH,
      Vector2(C.BaseX + C.SlideX, C.BaseZ + C.SlideZ), C.W, sl, OriginV, SizeV);
    Exit;
  end;
  Result := False;
  if (C.TexId > 4) or (TreeShadowAlpha(C.TexId) = nil) then Exit;
  Result := RasterizeTreeCardToMaskB(M, MW, MH, TreeShadowAlpha(C.TexId),
    Vector2(C.BaseX, C.BaseZ), Vector2(C.RightX, C.RightZ),
    Vector2(C.SlideX, C.SlideZ), C.W, OriginV, SizeV);
end;

{ Reusable per-thread scratch: shadow generation runs on the single grid worker,
  so these persist across tiles (grow-only) instead of alloc+free every tile. }
threadvar
  gBlurOrig, gBlurTmp:   TShadowMaskBytes;   { BlurMaskGrayB scratch }
  gBlurSums: array of Integer;
  gTreeDark, gTreeMoti:  TShadowMaskBytes;   { tree darkness + sway buffers }

procedure BlurMaskGrayB(M: TShadowMaskBytes; W, H, Radius: Integer);
var
  x, y, acc, n, hi0, lv, en, bv, ov, rb: Integer;
  Orig, Tmp: TShadowMaskBytes;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1820);{$ENDIF}
  if (Length(M) < W * H) or (Radius < 1) or (W < 1) or (H < 1) then Exit;
  if Length(gBlurOrig) < W * H then SetLength(gBlurOrig, W * H);   { grow only }
  if Length(gBlurTmp)  < W * H then SetLength(gBlurTmp,  W * H);
  Orig := gBlurOrig;  Tmp := gBlurTmp;
  Move(M[0], Orig[0], W * H);
  { horizontal pass -- sliding window (running sum): O(W*H), not O(W*H*Radius) }
  for y := 0 to H - 1 do
  begin
    rb := y * W;
    acc := 0; n := 0;
    hi0 := Radius; if hi0 > W - 1 then hi0 := W - 1;
    for x := 0 to hi0 do begin acc := acc + Orig[rb + x]; Inc(n); end;
    Tmp[rb] := acc div n;
    for x := 1 to W - 1 do
    begin
      lv := x - 1 - Radius;
      if lv >= 0 then begin acc := acc - Orig[rb + lv]; Dec(n); end;
      en := x + Radius;
      if en <= W - 1 then begin acc := acc + Orig[rb + en]; Inc(n); end;
      Tmp[rb + x] := acc div n;
    end;
  end;
  { Vertical running sums, visited by ROW. Column-major traversal of an
    8192-wide mask thrashed the cache/TLB; these are the same integer sums. }
  if Length(gBlurSums)<W then SetLength(gBlurSums,W);
  FillChar(gBlurSums[0],W*SizeOf(Integer),0);
  hi0:=Min(Radius,H-1); n:=hi0+1;
  for y:=0 to hi0 do
    for x:=0 to W-1 do Inc(gBlurSums[x],Tmp[y*W+x]);
  for y:=0 to H-1 do
  begin
    if y>0 then
    begin
      lv:=y-1-Radius; en:=y+Radius;
      if lv>=0 then Dec(n);
      if en<H then Inc(n);
      for x:=0 to W-1 do
      begin
        if lv>=0 then Dec(gBlurSums[x],Tmp[lv*W+x]);
        if en<H then Inc(gBlurSums[x],Tmp[en*W+x]);
      end;
    end;
    rb:=y*W;
    for x:=0 to W-1 do
    begin
      bv:=gBlurSums[x] div n; ov:=Orig[rb+x];
      if ov>bv then bv:=ov;
      M[rb+x]:=bv;
    end;
  end;
end;

function RasterizeSnapshotMask(const OriginV, SizeV: TVector2; W, H: Integer;
  const Tris: TProjTriArray; const Trees: TShadowTreeCardArray;
  ACancel: PBoolean; Receiver: TShadowReceiverRaster): TShadowMaskBytes;
var
  i, rad: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1822);{$ENDIF}
  Result := nil;
  if (W < 2) or (H < 2) or (SizeV.X < 0.01) or (SizeV.Y < 0.01) then Exit;
  EnsureTreeShadowAlpha;
  SetLength(Result, W * H);
  FillChar(Result[0], W * H, 0);
  for i := 0 to High(Tris) do
  begin
    if (i and 255) = 0 then
      if (ACancel <> nil) and ACancel^ then
      begin
        Result := nil;   { teardown: результат всё равно выбрасывается }
        Exit;
      end;
    if (Receiver <> nil) and Tris[i].HasSource then
      Receiver.CastTriangle(Tris[i].SourceA, Tris[i].SourceB, Tris[i].SourceC,
        Tris[i].SunSlope, @Result[0])
    else RasterizeTriToMaskB(Result, W, H, Tris[i].A, Tris[i].B, Tris[i].C,
      OriginV, SizeV, Tris[i].IA, Tris[i].IB, Tris[i].IC);
  end;
  for i := 0 to High(Trees) do
  begin
    if (i and 255) = 0 then
      if (ACancel <> nil) and ACancel^ then
      begin
        Result := nil;
        Exit;
      end;
    RasterizeTreeCardRegB(Trees[i], Result, W, H, OriginV, SizeV);
  end;
  { soft umbra — same texel-per-1.5 m falloff the old phase-2 used }
  rad := Round((W / SizeV.X) * 1.5);
  if rad < 2 then rad := 2 else if rad > 12 then rad := 12;
  BlurMaskGrayB(Result, W, H, rad);
end;

function ShadowMaskNextPow2(x: Int64): Integer;
begin
  { A larger power of two cannot fit in the result. Without this guard,
    shifting an Integer wraps through a negative value to zero forever. }
  if x > (Int64(1) shl 30) then
    raise ERangeError.Create('Shadow texture dimension exceeds Integer capacity');
  Result := 1;
  while Result < x do Result := Result shl 1;
end;

{ Packed bytes = ceil(LogRes^2 / N). CGE rounds every scene texture UP to a
  power of two (ResizeToTextureSize), and our texelFetch uses integer coords
  into the EXACT size -- so we pre-round the packed texture to POT ourselves
  (POT rectangle, ~square) so CGE leaves it untouched and coords line up. }
function ShadowTexW(LogRes, Bits: Integer): Integer;
var N: Integer; nb: Int64;
begin
  if Bits >= 8 then Bits := 8 else if Bits >= 4 then Bits := 4
  else if Bits >= 2 then Bits := 2 else Bits := 1;
  N := 8 div Bits;
  nb := (Int64(LogRes) * LogRes + (N - 1)) div N;
  ShadowTexW := ShadowMaskNextPow2(Ceil64(Sqrt(nb)));   { POT width ~ sqrt(bytes) }
end;

function ShadowTexH(LogRes, Bits: Integer): Integer;
var N, W: Integer; nb: Int64;
begin
  if Bits >= 8 then Bits := 8 else if Bits >= 4 then Bits := 4
  else if Bits >= 2 then Bits := 2 else Bits := 1;
  N := 8 div Bits;
  nb := (Int64(LogRes) * LogRes + (N - 1)) div N;
  W  := ShadowTexW(LogRes, Bits);
  ShadowTexH := ShadowMaskNextPow2(Ceil64(nb / W));   { POT height so W*H >= bytes }
end;

function RasterizeSnapshotMaskPacked(const OriginV, SizeV: TVector2;
  BaseRes, Bits: Integer;
  const Tris: TProjTriArray; const Trees: TShadowTreeCardArray;
  ACancel: PBoolean; Receiver: TShadowReceiverRaster): TShadowMaskBytes;
var
  Logical: TShadowMaskBytes;
  LogRes, N, maxVal, TexW, TexH, ly, lx, sub, q: Integer;
  li, bi: Int64;
begin
  Result := nil;
  if BaseRes < 1 then Exit;
  if Bits >= 8 then Bits := 8 else if Bits >= 4 then Bits := 4
  else if Bits >= 2 then Bits := 2 else Bits := 1;
  LogRes := BaseRes;
  N      := 8 div Bits;
  maxVal := (1 shl Bits) - 1;
  TexW := ShadowTexW(LogRes, Bits);
  TexH := ShadowTexH(LogRes, Bits);
  Logical := RasterizeSnapshotMask(OriginV, SizeV, LogRes, LogRes, Tris, Trees,
    ACancel, Receiver);
  if Logical = nil then Exit;
  SetLength(Result, TexW * TexH);   { POT rect, zero-filled; OR-accumulated below }
  for ly := 0 to LogRes - 1 do
    for lx := 0 to LogRes - 1 do
    begin
      { linearise logical texel (row-major), pack N/byte; byte bi stored at
        (bi mod TexDim, bi div TexDim) in the SQUARE texture. Matches shader. }
      li  := Int64(ly) * LogRes + lx;
      bi  := li div N;
      sub := Integer(li - bi * N);
      q   := (Logical[ly * LogRes + lx] * maxVal + 127) div 255;
      Result[bi] := Byte(Result[bi] or (q shl (sub * Bits)));
    end;
end;

{ ===== Stage 2: two-channel TREE mask (darkness + wind sway-weight) ===== }

function SmoothStep01(e0, e1, x: Single): Single;
var t: Single;
begin
  if e1 <= e0 then begin if x >= e1 then Result := 1.0 else Result := 0.0; Exit; end;
  t := (x - e0) / (e1 - e0);
  if t < 0.0 then t := 0.0 else if t > 1.0 then t := 1.0;
  Result := t * t * (3.0 - 2.0 * t);
end;

{ Sway-weight per shadow texel = leaf * heightTaper * widthTaper -- MIRRORS the
  canopy vertex weight in Osm3dRenderInstanced (BRANCH_TAPER/WIDTH_TAPER=1.5,
  leaf smoothstep 0.45..0.80). Shadow card coords: vy 0=trunk base .. 1=crown
  tip (= canopy 1-uv.y); ux 0..1 with 0.5 = trunk axis (= canopy uv.x). Keep
  these constants in sync with the canopy or the shadow desyncs from the tree. }
function TreeSwayWeight(ux, vy: Single): Single;
var leafM, hT, wT: Single;
begin
  leafM := 1.0 - SmoothStep01(0.45, 0.80, 1.0 - vy);
  hT    := EnsureRange(vy, 0.0, 1.0);                 hT := hT * Sqrt(hT);   { = ^1.5 }
  wT    := EnsureRange(Abs(ux - 0.5) * 2.0, 0.0, 1.0); wT := wT * Sqrt(wT);  { = ^1.5 }
  wT    := wT + (1.0 - wT) * hT;   { mix(wT,1,hT): apex bends, drop trunk-axis stiffness up top }
  Result := EnsureRange(leafM * hT * wT, 0.0, 1.0);
end;

function RasterizeTreeCardToMask2(Dark, Moti: TShadowMaskBytes; MW, MH: Integer;
  Alpha: TGrayscaleImage; const BaseXZ, RightXZ, SlideXZ: TVector2; W: Single;
  const OriginV, SizeV: TVector2): Boolean;
var
  aw, ah, x, y, minx, maxx, miny, maxy, axp, ayp, ap, idx, mB: Integer;
  Ox, Oz, EuX, EuZ, EvX, EvZ, det, wx, wz, dx, dz, ux, vy: Single;
  c0x, c0y, c1x, c1y, c2x, c2y, c3x, c3y: Single;
  function PixX(const VX: Single): Single; inline;
  begin Result := MaskPixCoord(VX, OriginV.X, SizeV.X, MW); end;
  function PixY(const VZ: Single): Single; inline;
  begin Result := MaskPixCoord(VZ, OriginV.Y, SizeV.Y, MH); end;
begin
  Result := False;
  if Alpha = nil then Exit;
  aw := Alpha.Width;   ah := Alpha.Height;
  if (aw < 2) or (ah < 2) then Exit;
  EuX := W * RightXZ.X;  EuZ := W * RightXZ.Y;
  EvX := SlideXZ.X;      EvZ := SlideXZ.Y;
  Ox := BaseXZ.X - 0.5 * EuX;  Oz := BaseXZ.Y - 0.5 * EuZ;
  det := EuX * EvZ - EuZ * EvX;
  if Abs(det) < 1e-9 then Exit;
  c0x := PixX(Ox);             c0y := PixY(Oz);
  c1x := PixX(Ox + EuX);       c1y := PixY(Oz + EuZ);
  c2x := PixX(Ox + EvX);       c2y := PixY(Oz + EvZ);
  c3x := PixX(Ox + EuX + EvX); c3y := PixY(Oz + EuZ + EvZ);
  minx := Max(0,      Floor(Min(Min(c0x, c1x), Min(c2x, c3x))));
  maxx := Min(MW - 1, Ceil (Max(Max(c0x, c1x), Max(c2x, c3x))));
  miny := Max(0,      Floor(Min(Min(c0y, c1y), Min(c2y, c3y))));
  maxy := Min(MH - 1, Ceil (Max(Max(c0y, c1y), Max(c2y, c3y))));
  for y := miny to maxy do
    for x := minx to maxx do
    begin
      wx := OriginV.X + (x / (MW - 1)) * SizeV.X;
      wz := OriginV.Y + (y / (MH - 1)) * SizeV.Y;
      dx := wx - Ox;  dz := wz - Oz;
      ux := ( EvZ * dx - EvX * dz) / det;
      vy := (-EuZ * dx + EuX * dz) / det;
      if (ux < 0.0) or (ux > 1.0) or (vy < 0.0) or (vy > 1.0) then Continue;
      axp := Trunc(ux * (aw - 1));
      ayp := Trunc(vy * (ah - 1));
      if axp < 0 then axp := 0 else if axp > aw - 1 then axp := aw - 1;
      if ayp < 0 then ayp := 0 else if ayp > ah - 1 then ayp := ah - 1;
      ap := PByte(Alpha.PixelPtr(axp, ayp))^;
      if ap < 20 then Continue;   { low gate keeps semi-transparent leaf detail }
      idx := y * MW + x;
      if ap > Dark[idx] then Dark[idx] := ap;   { darkness = card alpha -> dappled }
      mB := Round(TreeSwayWeight(ux, vy) * 255.0); { sway-weight channel }
      if mB > Moti[idx] then Moti[idx] := mB;
      Result := True;
    end;
end;

function RasterizeShrubBlobToMask2(Dark, Moti: TShadowMaskBytes; MW, MH: Integer;
  const CenterXZ: TVector2; R, SlideLen: Single;
  const OriginV, SizeV: TVector2): Boolean;
var
  x, y, minx, maxx, miny, maxy, idx, mB, dv: Integer;
  cxp, czp, rxp, rzp, wx, wz, dx, dz, d, f, R2: Single;
begin
  Result := False;
  if R <= 0.01 then Exit;
  R2 := R * R;
  cxp := ((CenterXZ.X - OriginV.X) / SizeV.X) * (MW - 1);
  czp := ((CenterXZ.Y - OriginV.Y) / SizeV.Y) * (MH - 1);
  rxp := (R / SizeV.X) * (MW - 1);
  rzp := (R / SizeV.Y) * (MH - 1);
  minx := Max(0,      Floor(cxp - rxp));
  maxx := Min(MW - 1, Ceil (cxp + rxp));
  miny := Max(0,      Floor(czp - rzp));
  maxy := Min(MH - 1, Ceil (czp + rzp));
  for y := miny to maxy do
    for x := minx to maxx do
    begin
      wx := OriginV.X + (x / (MW - 1)) * SizeV.X;
      wz := OriginV.Y + (y / (MH - 1)) * SizeV.Y;
      dx := wx - CenterXZ.X;  dz := wz - CenterXZ.Y;
      d := dx * dx + dz * dz;
      if d > R2 then Continue;
      d := Sqrt(d);
      f := 1.0;
      if d > 0.6 * R then f := (R - d) / (0.4 * R);
      if f <= 0.0 then Continue;
      idx := y * MW + x;
      dv := Round(f * 255.0);   { darkness = blob falloff -> gradual, not flat }
      if dv > Dark[idx] then Dark[idx] := dv;
      { shrubs are low -> gentle uniform-ish sway, tapering with the blob }
      mB := Round(EnsureRange(f * 0.4, 0.0, 1.0) * 255.0);
      if mB > Moti[idx] then Moti[idx] := mB;
      Result := True;
    end;
end;

function RasterizeTreeCardReg2(const C: TShadowTreeCard; Dark, Moti: TShadowMaskBytes;
  MW, MH: Integer; const OriginV, SizeV: TVector2): Boolean;
var sl: Single;
begin
  if C.Kind = sckShrubBlob then
  begin
    sl := Sqrt(C.SlideX * C.SlideX + C.SlideZ * C.SlideZ);
    Result := RasterizeShrubBlobToMask2(Dark, Moti, MW, MH,
      Vector2(C.BaseX + C.SlideX, C.BaseZ + C.SlideZ), C.W, sl, OriginV, SizeV);
    Exit;
  end;
  Result := False;
  if (C.TexId > 4) or (TreeShadowAlpha(C.TexId) = nil) then Exit;
  Result := RasterizeTreeCardToMask2(Dark, Moti, MW, MH, TreeShadowAlpha(C.TexId),
    Vector2(C.BaseX, C.BaseZ), Vector2(C.RightX, C.RightZ),
    Vector2(C.SlideX, C.SlideZ), C.W, OriginV, SizeV);
end;

{ Sample a tree/shrub's light-plane silhouette at the receiver's actual Y.
  The card remains the existing alpha approximation; its projection now
  follows slopes, including when caster and receiver belong to different tiles. }
procedure RasterizeTreeOnReceiver(const C: TShadowTreeCard;
  Dark, Moti: TShadowMaskBytes; Res: Integer;
  const OriginV, SizeV: TVector2; Receiver: TShadowReceiverRaster);
var
  Alpha: TGrayscaleImage;
  X,Z,X0,Z0,X1,Z1,Idx,AP,MB,AX,AY: Integer;
  DX0,DX1,DZ0,DZ1,GY,WX,WZ,DX,DZ,U,V,Det,EuX,EuZ,OX,OZ,F,D,LowY,HighY: Single;
begin
  if (Receiver.MinY > Receiver.MaxY) or (C.SourceHeight <= 0.1) then Exit;
  if not Receiver.HeightRange(C.BaseX-C.W,C.BaseZ-C.W,C.BaseX+C.W,C.BaseZ+C.W,
    C.SunSlope,LowY,HighY) then Exit;
  HighY:=Min(HighY,C.BaseY+C.SourceHeight);
  if LowY>HighY then Exit;
  Alpha := nil;
  if C.Kind = sckTreeTex then
  begin
    if C.TexId > 4 then Exit;
    Alpha := TreeShadowAlpha(C.TexId);
    if Alpha = nil then Exit;
  end;
  DX0 := C.SunSlope.X*(LowY-C.BaseY);
  DX1 := C.SunSlope.X*(HighY-C.BaseY);
  DZ0 := C.SunSlope.Y*(LowY-C.BaseY);
  DZ1 := C.SunSlope.Y*(HighY-C.BaseY);
  Receiver.PixelBounds(C.MinX+Min(DX0,DX1),C.MinZ+Min(DZ0,DZ1),
    C.MaxX+Max(DX0,DX1),C.MaxZ+Max(DZ0,DZ1),X0,Z0,X1,Z1);
  EuX := C.W*C.RightX; EuZ := C.W*C.RightZ;
  OX := C.BaseX-0.5*EuX; OZ := C.BaseZ-0.5*EuZ;
  Det := EuX*C.SlideZ-EuZ*C.SlideX;
  if (C.Kind=sckTreeTex) and (Abs(Det)<1e-9) then Exit;
  for Z := Z0 to Z1 do
  begin
    if ((Z and 31)=0) and Receiver.Cancelled then Exit;
    for X := X0 to X1 do
    begin
      Idx := Z*Res+X;
      if not Receiver.GroundAt(Idx,GY) then Continue;
      WX := OriginV.X+X/(Res-1)*SizeV.X-C.SunSlope.X*(GY-C.BaseY);
      WZ := OriginV.Y+Z/(Res-1)*SizeV.Y-C.SunSlope.Y*(GY-C.BaseY);
      if C.Kind=sckShrubBlob then
      begin
        if GY >= C.BaseY+C.SourceHeight then Continue;
        DX := WX-C.BaseX-C.SlideX; DZ := WZ-C.BaseZ-C.SlideZ;
        D := Sqrt(DX*DX+DZ*DZ);
        if D >= C.W then Continue;
        F := Min(1.0,(C.W-D)/(0.4*C.W));
        AP := Round(F*255); MB := Round(F*0.4*255);
      end
      else
      begin
        DX := WX-OX; DZ := WZ-OZ;
        U := (C.SlideZ*DX-C.SlideX*DZ)/Det;
        V := (-EuZ*DX+EuX*DZ)/Det;
        if (U<0) or (U>1) or (V<0) or (V>1) then Continue;
        if C.BaseY+V*C.SourceHeight-GY < 0.01 then Continue;
        AX := Trunc(U*(Alpha.Width-1)); AY := Trunc(V*(Alpha.Height-1));
        AP := PByte(Alpha.PixelPtr(AX,AY))^;
        if AP < 20 then Continue;
        MB := Round(TreeSwayWeight(U,V)*255);
      end;
      if AP > Dark[Idx] then Dark[Idx] := AP;
      if MB > Moti[Idx] then Moti[Idx] := MB;
    end;
  end;
end;

function TreeShadowTexW(LogRes, Bits: Integer): Integer;
var nb: Int64;
begin
  { dimensions are in PIXELS = LogRes^2 (same for R4x2 and R8x2). The per-pixel
    byte count -- 1 (Grayscale) or 2 (GrayscaleAlpha) -- is the image FORMAT, so
    the texture never doubles in width. Bits is kept for signature symmetry. }
  if Bits = 0 then ;
  nb := Int64(LogRes) * LogRes;
  TreeShadowTexW := ShadowMaskNextPow2(Ceil64(Sqrt(nb)));
end;

function TreeShadowTexH(LogRes, Bits: Integer): Integer;
var W: Integer; nb: Int64;
begin
  if Bits = 0 then ;
  nb := Int64(LogRes) * LogRes;
  W  := TreeShadowTexW(LogRes, Bits);
  TreeShadowTexH := ShadowMaskNextPow2(Ceil64(nb / W));
end;

function RasterizeTreeMaskPacked(const OriginV, SizeV: TVector2;
  BaseRes, Bits: Integer; const Trees: TShadowTreeCardArray;
  ACancel: PBoolean; Receiver: TShadowReceiverRaster): TShadowMaskBytes;
var
  Dark, Moti: TShadowMaskBytes;
  LogRes, TexW, TexH, ly, lx, rad, i, dv, mv, bpp: Integer;
  li: Int64;
  Nib: array[0..255] of Byte;   { d(0..255) -> 4-bit nibble, avoids per-texel div }
begin
  Result := nil;
  if BaseRes < 1 then Exit;
  if Bits >= 8 then Bits := 8 else Bits := 4;
  LogRes := BaseRes;
  if (LogRes < 2) or (SizeV.X < 0.01) or (SizeV.Y < 0.01) then Exit;
  TexW := TreeShadowTexW(LogRes, Bits);
  TexH := TreeShadowTexH(LogRes, Bits);
  EnsureTreeShadowAlpha;
  if Length(gTreeDark) < LogRes * LogRes then SetLength(gTreeDark, LogRes * LogRes);
  if Length(gTreeMoti) < LogRes * LogRes then SetLength(gTreeMoti, LogRes * LogRes);
  Dark := gTreeDark;  Moti := gTreeMoti;   { reused (grow-only) }
  FillChar(Dark[0], LogRes * LogRes, 0);
  FillChar(Moti[0], LogRes * LogRes, 0);
  for i := 0 to High(Trees) do
  begin
    if (i and 255) = 0 then
      if (ACancel <> nil) and ACancel^ then Exit;   { Result=nil уже стоит }
    if Receiver <> nil then
      RasterizeTreeOnReceiver(Trees[i], Dark, Moti, LogRes, OriginV, SizeV, Receiver)
    else RasterizeTreeCardReg2(Trees[i], Dark, Moti, LogRes, LogRes, OriginV, SizeV);
  end;
  rad := Round((LogRes / SizeV.X) * 1.5);
  if rad < 2 then rad := 2 else if rad > 12 then rad := 12;
  BlurMaskGrayB(Dark, LogRes, LogRes, rad);   { soft crown edge = the gradient }
  { motility left UNBLURRED: it is a smooth weight already, saves a blur pass }
  if Bits >= 8 then bpp := 2 else bpp := 1;   { R8x2 = 2 bytes/pixel (GL_RG) }
  SetLength(Result, TexW * TexH * bpp);  FillChar(Result[0], TexW * TexH * bpp, 0);
  for i := 0 to 255 do Nib[i] := Byte((i * 15 + 127) div 255);   { built once }
  for ly := 0 to LogRes - 1 do
    for lx := 0 to LogRes - 1 do
    begin
      li := Int64(ly) * LogRes + lx;
      dv := Dark[ly * LogRes + lx];
      mv := Moti[ly * LogRes + lx];
      if Bits = 4 then
        { R4x2: darkness low nibble, sway high nibble, 1 byte at index li }
        Result[li] := Byte(Nib[dv] or (Nib[mv] shl 4))
      else
      begin
        { R8x2: darkness byte at 2*li, sway byte at 2*li+1 }
        Result[2 * li]     := Byte(dv);
        Result[2 * li + 1] := Byte(mv);
      end;
    end;
end;

end.
