unit Osm3dRenderInstanced;
{$ifdef ANDROID}{$define OpenGLES}{$endif}

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}{$modeswitch advancedrecords}
{$codepage UTF8}
{$WARN 5091 OFF}

interface

uses
  Classes,
  SysUtils,
  Osm3dGpuAccount,
  CastleVectors,
  CastleBoxes,
  CastleFrustum,
  CastleTransform,
  CastleRenderOptions,
  CastleGLImages,
  CastleImages,
  CastleRenderContext,
  {$ifdef OpenGLES}CastleGLES, RenderGLES{$else}CastleGL{$endif},
  Osm3dGeomVegetation,
  Osm3dProfiler,
  {$IFDEF TILE_MEM_PROFILE}Osm3dMemCensus,{$ENDIF}
  Osm3dWind,
  Osm3dStudioSettings
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
;

type
  { Shared per-class GL resources. Subclass-specific extensions
    (textures, extra uniforms) live in separate class vars. }
  TInstancedSharedResources = record
    Program_:              GLuint;
    BaseMeshVBO:           GLuint;
    BaseMeshEBO:           GLuint;
    DetailMeshVBO, DetailMeshEBO: GLuint;
    DetailIndexCount: Integer;
    UniDetailPass, UniBranchesEnabled: GLint;
    UniBranchLodDistances: GLint;
    BranchTexture: GLuint;
    UniBranchTexture: GLint;

    { Common uniform locations. -1 means the subclass shader doesn't
      declare this uniform — LocalRender then skips its glUniform call.
      One render skeleton serves shaders with different LOD subsets. }
    UniProjectionMatrix:   GLint;
    UniViewMatrix:         GLint;
    UniModelMatrix:        GLint;
    UniLightDir:           GLint;
    UniDepthOnly:          GLint;
    UniCameraWorldPos:     GLint;
    UniLodNearBase:        GLint;
    UniLodFarBase:         GLint;
    UniLodHeightRef:       GLint;
    UniLodGroundRefY:      GLint;
    { Shared wind uniforms (trees include WIND_GLSL; shrubs leave this zeroed). }
    Wind:                  TWindUniforms;

    Initialized:           Boolean;
    TexturesLoaded:        Boolean;
  end;
  PInstancedSharedResources = ^TInstancedSharedResources;

  { One forest/shrub tile's GPU + CPU state. A tile is a plain record, not its own
    TCastleTransform: a single renderer (one for trees, one for shrubs) holds an array of tiles and
    does its own per-tile distance cull + draw inside one LocalRender, so CGE walks 2 nodes per frame
    instead of 5000-7000 (which scaled with map size and dominated cost on large maps). }
  TBranchCell = record
    First, Count: Integer;
    MinOrigin, MaxOrigin: TVector3;
  end;
  TInstancedTile = record
    Instances:      TTreeInstanceArray;
    InstanceCount:  Integer;
    VAO:            GLuint;
    DetailVAO:      GLuint;
    BranchCells:    array of TBranchCell;
    BranchCellsReady: Boolean; { CPU index survives GL buffer recreation }
    InstanceVBO:    GLuint;
    Initialized:    Boolean;   { VAO + InstanceVBO created }
    InstancesDirty: Boolean;   { CPU instance data not yet uploaded }
    TileCenterX:    Single;
    TileCenterZ:    Single;
    LocalBox:       TBox3D;
  end;
  PInstancedTile = ^TInstancedTile;
  TInstancedTileArray = array of TInstancedTile;

  TInstancedBillboardRenderer = class(TCastleTransform)
  protected
    { All tiles this renderer manages. Trees and shrubs each get ONE
      renderer instance holding the whole map's worth of tiles. }
    FTiles:          TInstancedTileArray;
    FTileCount:      Integer;

    { Union bbox of every tile — returned from LocalBoundingBox so CGE
      frustum-culls the whole renderer as a unit (cheap early-out when
      the entire forest is off-screen). }
    FUnionBox:       TBox3D;

    { World XZ range: coarse tile bounds on CPU, individual origins in shader. }
    FCullDistance:   Single;
    FCullDistanceSq: Single;
    FSunRayDirection:TVector3;
    FProceduralAlternative: Boolean;

  public
    { Per-frame diagnostic counters (class-wide). Visited = tiles examined by the cull loop; Drawn =
      tiles that passed and issued a draw call. Per-tile cost is a couple of float ops, not a CGE
      node walk. }
    class var ThisFrameVisited: Integer;
    class var ThisFrameDrawn:   Integer;
    class var LastFrameVisited: Integer;
    class var LastFrameDrawn:   Integer;
    class var ColorDrawCalls, ShadowDrawCalls: QWord;
    class var BranchDrawCalls, BranchShadowDrawCalls: QWord;
    class var BranchInstancesSubmitted: QWord;
    {$IFDEF TILE_MEM_PROFILE}
    function MemoryBytesGPU: Int64;
    function MemoryBytesCPU: Int64;
    {$ENDIF}
    class procedure FrameBoundary;
  protected
    { Subclass API (abstract) — unchanged, all per-CLASS }

    function  SharedResPtr: PInstancedSharedResources; virtual; abstract;

    { Lazily compile shaders, upload base mesh VBO/EBO, cache uniform
      locations. Idempotent. }
    procedure EnsureSharedGL; virtual; abstract;

    procedure BindShaderTextures; virtual; abstract;
    { Symmetric to BindShaderTextures — unbinds this renderer's textures
      from their units so a later pass that forgets to bind its own
      texture does not sample ours. }
    procedure UnbindShaderTextures; virtual; abstract;
    function  HasSharedTextures: Boolean; virtual; abstract;

    { Base mesh data: 3 pos + 3 normal + 2 uv = 8 floats per vertex. }
    function  GetMeshDataPtr:    Pointer;     virtual; abstract;
    function  GetMeshDataSize:   Integer;     virtual; abstract;
    function  GetMeshIndicesPtr: Pointer;     virtual; abstract;
    function  GetMeshIndexCount: Integer;     virtual; abstract;
    function  GetVertSource:     AnsiString;  virtual; abstract;
    function  GetFragSource:     AnsiString;  virtual; abstract;
    function  GetShaderTag:      string;      virtual; abstract;

    { Bind per-instance attributes onto VAO. Called once per tile with
      that tile's VAO and InstanceVBO bound. Subclass owns locations 3+. }
    procedure SetupInstanceAttribs(const ByteOffset: PtrUInt = 0); virtual; abstract;

    { Default 8 floats (32 b). }
    function  GetVertexStrideBytes: Integer;  virtual;

    function  GetProfilerName: string;        virtual;

    { Default 0 (no LOD). Shrubs override to expose near-LOD radius. }
    procedure GetLODBases(out NearBase, FarBase: Single); virtual;

    { Per-instance bbox shape for ONE tile's instances → into Tile.LocalBox.
      Subclass knows the shape (trees: Y..Y+S cube; shrubs scaled). }
    procedure RecomputeTileBoundingBox(var Tile: TInstancedTile); virtual; abstract;

    { Per-tile GL lifecycle — operate on a specific tile record. }
    procedure InitTileGL(var Tile: TInstancedTile);
    procedure InitDetailGL(var Tile: TInstancedTile);
    procedure BuildBranchCells(var Tile: TInstancedTile);
    procedure EnsureBranchCells(var Tile: TInstancedTile);
    procedure FreeTileGL(var Tile: TInstancedTile);
    procedure UploadTileVBO(var Tile: TInstancedTile);

    procedure LocalRender(const Params: TRenderParams); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor  Destroy; override;

    { Add one tile of instances to this manager. ACullDistance: world XZ
      range from the camera; tile bounds conservatively reject distant tiles.
      All tiles must share the same cull distance (last one wins). }
    procedure AddTile(const Instances: TTreeInstanceArray;
      ATileCenterX, ATileCenterZ, ACullDistance: Single);

    { Drop the tile(s) added at this centre (frees their GL objects). Used
      when a ground tile is evicted, so its trees don't linger or double up
      when the tile re-streams. No-op if no tile sits at that centre. }
    procedure RemoveTile(ATileCenterX, ATileCenterZ: Single);

    { Release every tile's GL objects and clear the tile array. }
    procedure ClearTiles;

    function  LocalBoundingBox: TBox3D; override;

    property  TileCount:    Integer read FTileCount;
    procedure SetCullDistance(const Value:Single);
    property  CullDistance: Single read FCullDistance write SetCullDistance;
    { Zero uses the map default. A preview can have its own sunlight. }
    property SunRayDirection:TVector3 read FSunRayDirection write FSunRayDirection;
    property ProceduralAlternative: Boolean read FProceduralAlternative write FProceduralAlternative;
  end;

{ Helpers used by subclasses' LoadSharedTextures / EnsureSharedGL. }

{ Conservative world-XZ distance to the transformed tile bounds. A camera
  near a large tile's edge must not be rejected because its centre is far
  away. Transform the whole box to retain rotation/nonuniform-scale safety.
  CullDistanceSquared <= 0 disables distance culling. No GL calls. }
function InstancedBoundsWithinRange(const LocalBox: TBox3D;
  const ModelMatrix: TMatrix4; const CameraWorldPos: TVector3;
  const CullDistanceSquared: Single): Boolean;

function  CompileShader(SType: GLenum; const Src: AnsiString;
                        const Tag: string): GLuint;
function  LinkProgram(VS, FS: GLuint; const Tag: string): GLuint;

procedure UploadPngToTextureArrayLayer(const FilePath: string;
  TexArray: GLuint; Layer: Integer; ExpectedW, ExpectedH: Integer);
function  UploadPngToTexture2D(const FilePath: string;
  WrapS: GLenum = GL_CLAMP_TO_EDGE;
  WrapT: GLenum = GL_CLAMP_TO_EDGE): GLuint;

{ Как UploadPngToTexture2D, но из уже загруженного в память изображения
  (не читает файл). Картинку НЕ освобождает — владелец остаётся за вызывающим.
  Нужна, чтобы залить запечённый в RAM атлас (напр. травы) в GL-текстуру без
  промежуточного PNG. LINEAR, без мипов — как у grass-атласа. }
function  UploadImageToTexture2D(Img: TCastleImage;
  WrapS: GLenum = GL_CLAMP_TO_EDGE;
  WrapT: GLenum = GL_CLAMP_TO_EDGE): GLuint;

type
  TCastleAbstractTreeRenderer = class(TInstancedBillboardRenderer)
  strict private
    class var FShared:           TInstancedSharedResources;
    class var FTextureArray:     GLuint;     { GL_TEXTURE_2D_ARRAY: 10 layers }
    class var FVolumeNormalTex:  GLuint;     { GL_TEXTURE_2D }
    class var FUniTextureArray:  GLint;
    class var FUniVolumeNormal:  GLint;

    class procedure DoEnsureSharedGL; static;
  protected
    function  SharedResPtr: PInstancedSharedResources; override;
    procedure EnsureSharedGL;                          override;
    procedure BindShaderTextures;                      override;
    procedure UnbindShaderTextures;                    override;
    function  HasSharedTextures: Boolean;              override;

    function  GetMeshDataPtr:    Pointer;     override;
    function  GetMeshDataSize:   Integer;     override;
    function  GetMeshIndicesPtr: Pointer;     override;
    function  GetMeshIndexCount: Integer;     override;
    function  GetVertSource:     AnsiString;  override;
    function  GetFragSource:     AnsiString;  override;
    function  GetShaderTag:      string;      override;
    procedure SetupInstanceAttribs(const ByteOffset: PtrUInt = 0); override;
    function  GetProfilerName: string;        override;
    procedure GetLODBases(out NearBase, FarBase: Single); override;
    procedure RecomputeTileBoundingBox(var Tile: TInstancedTile); override;
  public
    { Required files (TexturesDir):
        beech_diffuse.png,   beech_normal.png,
        fir_diffuse.png,     fir_normal.png,
        linden0_diffuse.png, linden0_normal.png,
        linden1_diffuse.png, linden1_normal.png,
        oak_diffuse.png,     oak_normal.png,
        tree_volume_normal.png
      All *_diffuse/*_normal must be 512×512 RGBA. Must be called once
      per process before the first renderer is added to a viewport. }
    class procedure LoadSharedTextures(const TexturesDir: string); static;

    class function  AreSharedTexturesLoaded: Boolean; static;

    { Must be called from FormDestroy BEFORE GL context destruction —
      otherwise glDelete* hit a dead context. Safe to call repeatedly. }
    class procedure CleanupSharedGL;                  static;
  end;

  TCastleAbstractShrubRenderer = class(TInstancedBillboardRenderer)
  strict private
    class var FShared:          TInstancedSharedResources;
    class var FDiffuseTex:      GLuint;
    class var FNormalTex:       GLuint;
    class var FUniDiffuse:      GLint;
    class var FUniNormal:       GLint;
    class var FUniHasNormal:    GLint;

    class procedure DoEnsureSharedGL; static;
  protected
    function  SharedResPtr: PInstancedSharedResources; override;
    procedure EnsureSharedGL;                          override;
    procedure BindShaderTextures;                      override;
    procedure UnbindShaderTextures;                    override;
    function  HasSharedTextures: Boolean;              override;

    function  GetMeshDataPtr:    Pointer;     override;
    function  GetMeshDataSize:   Integer;     override;
    function  GetMeshIndicesPtr: Pointer;     override;
    function  GetMeshIndexCount: Integer;     override;
    function  GetVertSource:     AnsiString;  override;
    function  GetFragSource:     AnsiString;  override;
    function  GetShaderTag:      string;      override;
    procedure SetupInstanceAttribs(const ByteOffset: PtrUInt = 0); override;
    function  GetProfilerName: string;        override;
    procedure GetLODBases(out NearBase, FarBase: Single); override;
    procedure RecomputeTileBoundingBox(var Tile: TInstancedTile); override;
  public
    { Required: diffuse.png (any size, RGBA). Optional: normal.png
      (same size; used by the near-LOD branch in FS when present). }
    class procedure LoadSharedTextures(const TexturesDir: string); static;
    class function  AreSharedTexturesLoaded: Boolean; static;
    class procedure CleanupSharedGL;                  static;
  end;

{ Set the single scene sun shared by ALL instanced vegetation (trees +
  shrubs). ARayDir = light RAY direction (FROM sun, travelling toward the
  scene) — the same convention as TSunCalc.ToLightDir and CGE
  TDirectionalLightNode.Direction. The ground shader's gc_SunDirToward is
  the negation of this. Read each frame by LocalRender, so changing it
  relights every already-mounted tree/shrub immediately. }
procedure SetInstancedSunDir(const ARayDir: TVector3);
{ LOD must use the viewing camera during depth rendering too. }
procedure BeginVegetationShadowPass(const Viewer: TVector3);
procedure EndVegetationShadowPass;
function VegetationShadowViewer(out Viewer: TVector3): Boolean;
function InstancedSunRayDirection: TVector3;
var VegetationBranchesEnabled: Boolean = True;

{ Camera world position from a view matrix with orthonormal R:
  V = R * T(-camPos), so camPos = -R^T * t. Cheaper than a full inverse,
  exact for orthonormal R. Единый источник — используется и этим
  рендером, и Osm3dRenderGrass (были дубли). }
function CameraWorldPosFromView(const ViewMat: TMatrix4): TVector3;

implementation

uses TreeShaderSource,
  CastleLog, CastleUriUtils, Math, Generics.Collections,
  Osm3dGlslLib, Osm3dVegetationBranchMesh, Osm3dRtxMaterials;

function CameraWorldPosFromView(const ViewMat: TMatrix4): TVector3;
var
  Tx, Ty, Tz: Single;
begin
  Tx := ViewMat.Data[3, 0]; Ty := ViewMat.Data[3, 1]; Tz := ViewMat.Data[3, 2];
  Result.X := -(ViewMat.Data[0, 0] * Tx + ViewMat.Data[0, 1] * Ty + ViewMat.Data[0, 2] * Tz);
  Result.Y := -(ViewMat.Data[1, 0] * Tx + ViewMat.Data[1, 1] * Ty + ViewMat.Data[1, 2] * Tz);
  Result.Z := -(ViewMat.Data[2, 0] * Tx + ViewMat.Data[2, 1] * Ty + ViewMat.Data[2, 2] * Tz);
end;

{ The one scene sun for all instanced vegetation. Ray direction (from sun
  toward scene). Initialised in the unit's initialization section to the
  same default TSunCalc.ToLightDir uses for night/missing timestamps, so
  vegetation, ground (-this) and the building light rig all agree before
  any FIT-derived value arrives. }
var
  GInstancedSunRayDir:    TVector3;
  GShadowViewer: TVector3;
  GShadowViewerValid: Boolean = False;

procedure BeginVegetationShadowPass(const Viewer: TVector3);
begin GShadowViewer:=Viewer;GShadowViewerValid:=True;end;
procedure EndVegetationShadowPass;
begin GShadowViewerValid:=False;end;
function VegetationShadowViewer(out Viewer: TVector3): Boolean;
begin Viewer:=GShadowViewer;Result:=GShadowViewerValid;end;
function InstancedSunRayDirection: TVector3;
begin Result:=GInstancedSunRayDir;end;

procedure SetInstancedSunDir(const ARayDir: TVector3);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1620);{$ENDIF}
  GInstancedSunRayDir := ARayDir;
end;

function CompileShader(SType: GLenum; const Src: AnsiString;
                       const Tag: string): GLuint;
var
  Status: GLint;
  LogLen: GLint;
  LogBuf: AnsiString;
  PSrc: PAnsiChar;
  SrcLen: GLint;
  PortableSource: AnsiString;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(674);{$ENDIF}
  Result := glCreateShader(SType);
  PortableSource := RenderShaderSource(Src, {$ifdef OpenGLES}True{$else}False{$endif});
  PSrc := PAnsiChar(PortableSource);
  SrcLen := Length(PortableSource);
  glShaderSource(Result, 1, @PSrc, @SrcLen);
  glCompileShader(Result);

  glGetShaderiv(Result, GL_COMPILE_STATUS, @Status);
  if Status = GL_FALSE then
  begin
    glGetShaderiv(Result, GL_INFO_LOG_LENGTH, @LogLen);
    SetLength(LogBuf, LogLen);
    if LogLen > 0 then
      glGetShaderInfoLog(Result, LogLen, nil, PAnsiChar(LogBuf));
    glDeleteShader(Result);
    raise Exception.CreateFmt('%s shader compile failed: %s', [Tag, LogBuf]);
  end;
end;

function LinkProgram(VS, FS: GLuint; const Tag: string): GLuint;
var
  Status, LogLen: GLint;
  LogBuf: AnsiString;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(675);{$ENDIF}
  Result := glCreateProgram();
  glAttachShader(Result, VS);
  glAttachShader(Result, FS);
  glLinkProgram(Result);

  glGetProgramiv(Result, GL_LINK_STATUS, @Status);
  if Status = GL_FALSE then
  begin
    glGetProgramiv(Result, GL_INFO_LOG_LENGTH, @LogLen);
    SetLength(LogBuf, LogLen);
    if LogLen > 0 then
      glGetProgramInfoLog(Result, LogLen, nil, PAnsiChar(LogBuf));
    glDeleteProgram(Result);
    raise Exception.CreateFmt('%s program link failed: %s', [Tag, LogBuf]);
  end;

  glDetachShader(Result, VS);
  glDetachShader(Result, FS);
end;

procedure UploadPngToTextureArrayLayer(const FilePath: string;
  TexArray: GLuint; Layer: Integer; ExpectedW, ExpectedH: Integer);
var
  Img: TCastleImage;
  RgbaImg: TRGBAlphaImage;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(676);{$ENDIF}
  Img := LoadImage(FilePath);
  try
    if Img is TRGBAlphaImage then
      RgbaImg := TRGBAlphaImage(Img)
    else
    begin
      RgbaImg := TRGBAlphaImage.Create(Img.Width, Img.Height);
      RgbaImg.Assign(Img);
    end;
    try
      if (RgbaImg.Width <> ExpectedW) or (RgbaImg.Height <> ExpectedH) then
        WritelnWarning('InstancedRenderer',
          'Texture %s is %dx%d, expected %dx%d',
          [FilePath, RgbaImg.Width, RgbaImg.Height, ExpectedW, ExpectedH]);

      glBindTexture(GL_TEXTURE_2D_ARRAY, TexArray);
      glTexSubImage3D(GL_TEXTURE_2D_ARRAY, 0,
        0, 0, Layer,
        RgbaImg.Width, RgbaImg.Height, 1,
        GL_RGBA, GL_UNSIGNED_BYTE,
        RgbaImg.RawPixels);
    finally
      if RgbaImg <> Img then RgbaImg.Free;
    end;
  finally
    Img.Free;
  end;
end;

function UploadPngToTexture2D(const FilePath: string;
  WrapS, WrapT: GLenum): GLuint;
var
  Img: TCastleImage;
  RgbaImg: TRGBAlphaImage;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(677);{$ENDIF}
  Result := 0;
  AccGenTextures(1, @Result);
  glBindTexture(GL_TEXTURE_2D, Result);

  Img := LoadImage(FilePath);
  try
    if Img is TRGBAlphaImage then
      RgbaImg := TRGBAlphaImage(Img)
    else
    begin
      RgbaImg := TRGBAlphaImage.Create(Img.Width, Img.Height);
      RgbaImg.Assign(Img);
    end;
    try
      glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8,
        RgbaImg.Width, RgbaImg.Height, 0,
        GL_RGBA, GL_UNSIGNED_BYTE, RgbaImg.RawPixels);
    finally
      if RgbaImg <> Img then RgbaImg.Free;
    end;
  finally
    Img.Free;
  end;

  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, WrapS);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, WrapT);
end;

function UploadImageToTexture2D(Img: TCastleImage;
  WrapS, WrapT: GLenum): GLuint;
var
  RgbaImg: TRGBAlphaImage;
begin
  Result := 0;
  if Img = nil then Exit;
  AccGenTextures(1, @Result);
  glBindTexture(GL_TEXTURE_2D, Result);

  if Img is TRGBAlphaImage then
    RgbaImg := TRGBAlphaImage(Img)
  else
  begin
    RgbaImg := TRGBAlphaImage.Create(Img.Width, Img.Height);
    RgbaImg.Assign(Img);
  end;
  try
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8,
      RgbaImg.Width, RgbaImg.Height, 0,
      GL_RGBA, GL_UNSIGNED_BYTE, RgbaImg.RawPixels);
  finally
    if RgbaImg <> Img then RgbaImg.Free;
  end;

  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, WrapS);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, WrapT);
end;

{ Shared by both subclasses: enable a per-instance float attribute. }
procedure EnableInstanceAttrib(Location: GLuint; FloatCount: GLint;
  ByteOffset: PtrUInt; Stride: GLsizei); inline;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(678);{$ENDIF}
  glEnableVertexAttribArray(Location);
  glVertexAttribPointer(Location, FloatCount, GL_FLOAT, GL_FALSE, Stride,
    Pointer(ByteOffset));
  glVertexAttribDivisor(Location, 1);
end;

{ Shared: upload base-mesh VBO + EBO into the supplied Shared record. }
procedure UploadBaseMeshBuffers(var Shared: TInstancedSharedResources;
  MeshDataPtr: Pointer; MeshDataSize: Integer;
  IndicesPtr: Pointer; IndicesSize: Integer);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(679);{$ENDIF}
  AccGenBuffers(1, @Shared.BaseMeshVBO);
  glBindBuffer(GL_ARRAY_BUFFER, Shared.BaseMeshVBO);
  glBufferData(GL_ARRAY_BUFFER, MeshDataSize, MeshDataPtr, GL_STATIC_DRAW);
  glBindBuffer(GL_ARRAY_BUFFER, 0);

  AccGenBuffers(1, @Shared.BaseMeshEBO);
  glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, Shared.BaseMeshEBO);
  glBufferData(GL_ELEMENT_ARRAY_BUFFER, IndicesSize, IndicesPtr, GL_STATIC_DRAW);
  glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, 0);
end;

{ Shared disconnected branch polygons for the near pass. }
procedure UploadDetailMesh(var Shared:TInstancedSharedResources;
  const Data:array of Single;const Indices:array of Word;IsTree:Boolean);
var Vert:TBranchVertices;Idx:TBranchIndices;
begin
  if IsTree then BuildVegetationLayerMesh(Data,Indices,VEGETATION_TREE_LAYERS,0.55,Vert,Idx)
  else BuildVegetationLayerMesh(Data,Indices,VEGETATION_SHRUB_LAYERS,0.60,Vert,Idx);
  Shared.DetailIndexCount:=Length(Idx);
  AccGenBuffers(1,@Shared.DetailMeshVBO);glBindBuffer(GL_ARRAY_BUFFER,Shared.DetailMeshVBO);
  glBufferData(GL_ARRAY_BUFFER,Length(Vert)*SizeOf(TBranchVertex),@Vert[0],GL_STATIC_DRAW);
  AccGenBuffers(1,@Shared.DetailMeshEBO);glBindBuffer(GL_ELEMENT_ARRAY_BUFFER,Shared.DetailMeshEBO);
  glBufferData(GL_ELEMENT_ARRAY_BUFFER,Length(Idx)*SizeOf(Word),@Idx[0],GL_STATIC_DRAW);
  glBindBuffer(GL_ARRAY_BUFFER,0);glBindBuffer(GL_ELEMENT_ARRAY_BUFFER,0);
end;

procedure CompileLinkProgram(var Shared: TInstancedSharedResources;
  const VertSrc, FragSrc: AnsiString; const Tag: string);
var
  VS, FS: GLuint;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(680);{$ENDIF}
  VS := CompileShader(GL_VERTEX_SHADER, VertSrc, Tag);
  try
    FS := CompileShader(GL_FRAGMENT_SHADER, FragSrc, Tag);
    try
      Shared.Program_ := LinkProgram(VS, FS, Tag);
    finally
      glDeleteShader(FS);
    end;
  finally
    glDeleteShader(VS);
  end;
end;

{ Full-canvas layers share the ORIGINAL diffuse/normal maps. A single R8
  ownership map per species encodes their alpha partition (1.5 MiB total).
  Nearest ownership plus original bilinear alpha exactly covers every pixel,
  including layer junctions and transparent neighbours along leaf edges. }
procedure LoadBranchTextures(var Shared:TInstancedSharedResources;
  const Dir:string;const Names:array of string;LayerCount:Integer);
var I,X,Y,Owner:Integer;Img:TCastleImage;Mask:TGrayscaleImage;
    Path:string;Tex:GLuint;
begin
  for I:=0 to High(Names)do begin
    Path:=Dir+'layers/'+Names[I]+'_ownership.png';
    if not FileExists(Path)then begin
      WritelnWarning('Vegetation','Layer ownership missing: %s; using whole plants',[Path]);
      if Shared.BranchTexture<>0 then AccDeleteTextures(1,@Shared.BranchTexture);
      Shared.BranchTexture:=0;Exit;
    end;
  end;
  Tex:=0;Mask:=TGrayscaleImage.Create(512,512);
  try
    AccGenTextures(1,@Tex);glBindTexture(GL_TEXTURE_2D_ARRAY,Tex);
    glTexImage3D(GL_TEXTURE_2D_ARRAY,0,GL_R8,512,512,Length(Names),0,GL_RED,GL_UNSIGNED_BYTE,nil);
    glTexParameteri(GL_TEXTURE_2D_ARRAY,GL_TEXTURE_MIN_FILTER,GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D_ARRAY,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D_ARRAY,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D_ARRAY,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
    for I:=0 to High(Names)do begin
      Path:=Dir+'layers/'+Names[I]+'_ownership.png';Img:=LoadImage(Path);
      try
        if(Img.Width<>512)or(Img.Height<>512)then
          raise Exception.Create('Vegetation ownership must retain its 512x512 canvas: '+Path);
        for Y:=0 to 511 do for X:=0 to 511 do begin
          Owner:=Round(Img.Colors[X,Y,0].X*255);
          if(Owner<0)or(Owner>=LayerCount)then raise Exception.Create('Invalid vegetation layer in '+Path);
          PByte(Mask.PixelPtr(X,Y))^:=Owner;
        end;
        glTexSubImage3D(GL_TEXTURE_2D_ARRAY,0,0,0,I,512,512,1,GL_RED,GL_UNSIGNED_BYTE,Mask.RawPixels);
      finally Img.Free;end;
    end;
    if Shared.BranchTexture<>0 then AccDeleteTextures(1,@Shared.BranchTexture);
    Shared.BranchTexture:=Tex;Tex:=0;
  finally
    if Tex<>0 then AccDeleteTextures(1,@Tex);
    Mask.Free;
  end;
end;

{ Cache the three matrix uniforms + light dir. Returns the program. }
procedure CacheCommonUniforms(var Shared: TInstancedSharedResources);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(681);{$ENDIF}
  Shared.UniProjectionMatrix := glGetUniformLocation(Shared.Program_, 'projectionMatrix');
  Shared.UniViewMatrix       := glGetUniformLocation(Shared.Program_, 'viewMatrix');
  Shared.UniModelMatrix      := glGetUniformLocation(Shared.Program_, 'modelMatrix');
  Shared.UniLightDir         := glGetUniformLocation(Shared.Program_, 'lightDir');
  Shared.UniDepthOnly        := glGetUniformLocation(Shared.Program_, 'depthOnly');
  Shared.UniDetailPass       := glGetUniformLocation(Shared.Program_, 'branchDetailPass');
  Shared.UniBranchesEnabled  := glGetUniformLocation(Shared.Program_, 'branchesEnabled');
  Shared.UniBranchLodDistances := glGetUniformLocation(Shared.Program_, 'branchLodDistances');
  Shared.UniBranchTexture    := glGetUniformLocation(Shared.Program_, 'tBranches');
end;

{$IFDEF TILE_MEM_PROFILE}
function TInstancedBillboardRenderer.MemoryBytesGPU: Int64;
var i: Integer;
begin
  Result := 0;
  for i := 0 to High(FTiles) do
    Inc(Result, Int64(FTiles[i].InstanceCount) * TREE_INSTANCE_STRIDE);
end;

function TInstancedBillboardRenderer.MemoryBytesCPU: Int64;
var i: Integer;
begin
  Result := 0;
  for i := 0 to High(FTiles) do
  begin
    Inc(Result, Int64(Length(FTiles[i].Instances)) * SizeOf(TTreeInstance));
    Inc(Result, Int64(Length(FTiles[i].BranchCells)) * SizeOf(TBranchCell));
  end;
end;
{$ENDIF}

constructor TInstancedBillboardRenderer.Create(AOwner: TComponent);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1226);{$ENDIF}
  inherited Create(AOwner);
  FTiles          := nil;
  FTileCount      := 0;
  FUnionBox       := TBox3D.Empty;
  FCullDistance   := 0;
  FCullDistanceSq := 0;
  {$IFDEF TILE_MEM_PROFILE}
  MemProbeAdd(Self, GetProfilerName + '-gpu', mkVRAM, @MemoryBytesGPU);
  MemProbeAdd(Self, GetProfilerName + '-cpu', mkRAM,  @MemoryBytesCPU);
  {$ENDIF}
end;

destructor TInstancedBillboardRenderer.Destroy;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1227);{$ENDIF}
  {$IFDEF TILE_MEM_PROFILE}MemProbeRemove(Self);{$ENDIF}
  ClearTiles;
  inherited;
end;

function TInstancedBillboardRenderer.GetVertexStrideBytes: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(682);{$ENDIF}
  { pos.xyz + normal.xyz + uv.xy = 8 floats. }
  Result := 8 * SizeOf(GLfloat);
end;

function TInstancedBillboardRenderer.GetProfilerName: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(683);{$ENDIF}
  Result := ClassName;
end;

procedure TInstancedBillboardRenderer.GetLODBases(out NearBase, FarBase: Single);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(684);{$ENDIF}
  NearBase := 0.0;
  FarBase  := 0.0;
end;

procedure TInstancedBillboardRenderer.InitTileGL(var Tile: TInstancedTile);
var
  S: PInstancedSharedResources;
  Stride: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(685);{$ENDIF}
  if Tile.Initialized then Exit;

  EnsureSharedGL;
  S := SharedResPtr;
  Stride := GetVertexStrideBytes;

  AccGenBuffers(1, @Tile.InstanceVBO);

  AccGenVertexArrays(1, @Tile.VAO);
  glBindVertexArray(Tile.VAO);

  { Mesh attribs read from the SHARED base-mesh VBO. VAO captures the
    buffer pointer at glVertexAttribPointer time so later draws may
    rebind GL_ARRAY_BUFFER without affecting these attribs. }
  glBindBuffer(GL_ARRAY_BUFFER, S^.BaseMeshVBO);
  glEnableVertexAttribArray(0);
  glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, Stride, Pointer(0));
  glEnableVertexAttribArray(1);
  glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, Stride,
    Pointer(3 * SizeOf(GLfloat)));
  glEnableVertexAttribArray(2);
  glVertexAttribPointer(2, 2, GL_FLOAT, GL_FALSE, Stride,
    Pointer(6 * SizeOf(GLfloat)));

  { Per-instance attribs read from this tile's OWN VBO; divisor
    captured by VAO. }
  glBindBuffer(GL_ARRAY_BUFFER, Tile.InstanceVBO);
  SetupInstanceAttribs;

  { EBO binding is part of VAO state. }
  glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, S^.BaseMeshEBO);

  glBindVertexArray(0);
  glBindBuffer(GL_ARRAY_BUFFER, 0);
  glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, 0);

  Tile.Initialized := True;
end;

procedure TInstancedBillboardRenderer.FreeTileGL(var Tile: TInstancedTile);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(686);{$ENDIF}
  if not Tile.Initialized then Exit;
  if Tile.VAO         <> 0 then begin AccDeleteVertexArrays(1, @Tile.VAO);         Tile.VAO := 0; end;
  if Tile.DetailVAO   <> 0 then begin AccDeleteVertexArrays(1, @Tile.DetailVAO); Tile.DetailVAO:=0;end;
  if Tile.InstanceVBO <> 0 then begin AccDeleteBuffers(1, @Tile.InstanceVBO);      Tile.InstanceVBO := 0; end;
  Tile.Initialized := False;
  Tile.InstancesDirty := True; { a recreated buffer needs the retained CPU data }
end;

procedure TInstancedBillboardRenderer.InitDetailGL(var Tile:TInstancedTile);
var S:PInstancedSharedResources;
begin
  if Tile.DetailVAO<>0 then Exit;
  S:=SharedResPtr;
  AccGenVertexArrays(1,@Tile.DetailVAO);glBindVertexArray(Tile.DetailVAO);
  glBindBuffer(GL_ARRAY_BUFFER,S^.DetailMeshVBO);
  glEnableVertexAttribArray(0);glVertexAttribPointer(0,3,GL_FLOAT,GL_FALSE,SizeOf(TBranchVertex),Pointer(0));
  glEnableVertexAttribArray(1);glVertexAttribPointer(1,3,GL_FLOAT,GL_FALSE,SizeOf(TBranchVertex),Pointer(12));
  glEnableVertexAttribArray(2);glVertexAttribPointer(2,2,GL_FLOAT,GL_FALSE,SizeOf(TBranchVertex),Pointer(24));
  glEnableVertexAttribArray(7);glVertexAttribPointer(7,4,GL_FLOAT,GL_FALSE,SizeOf(TBranchVertex),Pointer(32));
  glEnableVertexAttribArray(8);glVertexAttribPointer(8,4,GL_FLOAT,GL_FALSE,SizeOf(TBranchVertex),Pointer(48));
  glBindBuffer(GL_ARRAY_BUFFER,Tile.InstanceVBO);SetupInstanceAttribs;
  glBindBuffer(GL_ELEMENT_ARRAY_BUFFER,S^.DetailMeshEBO);
end;

procedure TInstancedBillboardRenderer.BuildBranchCells(var Tile:TInstancedTile);
type TCellMap=specialize TDictionary<Int64,Integer>;
var Map:TCellMap;Keys:array of Integer;Fill:array of Integer;Sorted:TTreeInstanceArray;
    I,J,N,Cursor,CellCount:Integer;Key:Int64;P:TVector3;
begin
  { Sort static instances into 20 m cells once on first legacy use. Both meshes
    share ONE instance VBO; the detailed pass draws only nearby cell ranges. }
  Map:=TCellMap.Create;
  try
    Tile.BranchCells:=nil;SetLength(Keys,Tile.InstanceCount);CellCount:=0;
    for I:=0 to Tile.InstanceCount-1 do begin
      with Tile.Instances[I]do begin
        Key:=Int64(Floor(X/20))*Int64(4294967296)+LongWord(LongInt(Floor(Z/20)));
        P:=Vector3(X,Y,Z);
      end;
      if not Map.TryGetValue(Key,J) then begin
        J:=CellCount;
        if CellCount=Length(Tile.BranchCells) then
          SetLength(Tile.BranchCells,Max(16,CellCount*2));
        Inc(CellCount);Map.Add(Key,J);
        Tile.BranchCells[J].MinOrigin:=P;Tile.BranchCells[J].MaxOrigin:=P;
      end;
      Keys[I]:=J;Inc(Tile.BranchCells[J].Count);
      for N:=0 to 2 do begin
        Tile.BranchCells[J].MinOrigin.Data[N]:=Min(Tile.BranchCells[J].MinOrigin.Data[N],P.Data[N]);
        Tile.BranchCells[J].MaxOrigin.Data[N]:=Max(Tile.BranchCells[J].MaxOrigin.Data[N],P.Data[N]);
      end;
    end;
    SetLength(Tile.BranchCells,CellCount);
    Cursor:=0;SetLength(Fill,Length(Tile.BranchCells));
    for J:=0 to High(Tile.BranchCells)do begin Tile.BranchCells[J].First:=Cursor;Fill[J]:=Cursor;Inc(Cursor,Tile.BranchCells[J].Count);end;
    SetLength(Sorted,Tile.InstanceCount);
    for I:=0 to Tile.InstanceCount-1 do begin J:=Keys[I];Sorted[Fill[J]]:=Tile.Instances[I];Inc(Fill[J]);end;
    Tile.Instances:=Sorted;
  finally Map.Free;end;
end;

procedure TInstancedBillboardRenderer.EnsureBranchCells(var Tile:TInstancedTile);
begin
  if Tile.BranchCellsReady then Exit;
  BuildBranchCells(Tile);
  { Sorting changes the instance order used by First/Count. Prepare before
    the first upload, including when that first visible pass is a shadow. }
  Tile.InstancesDirty:=True;
  Tile.BranchCellsReady:=True;
end;

procedure TInstancedBillboardRenderer.UploadTileVBO(var Tile: TInstancedTile);
var
  ByteSize: SizeUInt;
  Ptr: Pointer;
  PackedGPU: TTreeGPUInstanceArray;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(687);{$ENDIF}
  GetTreeInstanceBufferRaw(Tile.Instances, PackedGPU, Ptr, ByteSize);
  glBindBuffer(GL_ARRAY_BUFFER, Tile.InstanceVBO);
  if ByteSize > 0 then
    glBufferData(GL_ARRAY_BUFFER, ByteSize, Ptr, GL_STATIC_DRAW)
  else
    glBufferData(GL_ARRAY_BUFFER, 0, nil, GL_STATIC_DRAW);
  glBindBuffer(GL_ARRAY_BUFFER, 0);
  Tile.InstancesDirty := False;
end;

procedure TInstancedBillboardRenderer.SetCullDistance(const Value:Single);
begin FCullDistance:=Value;FCullDistanceSq:=Value*Value;end;

procedure TInstancedBillboardRenderer.AddTile(
  const Instances: TTreeInstanceArray;
  ATileCenterX, ATileCenterZ, ACullDistance: Single);
var
  I:   Integer;
  Idx: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(688);{$ENDIF}
  if FTileCount >= Length(FTiles) then
    SetLength(FTiles, FTileCount * 2 + 16);
  Idx := FTileCount;
  Inc(FTileCount);

  SetLength(FTiles[Idx].Instances, Length(Instances));
  for I := 0 to High(Instances) do
    FTiles[Idx].Instances[I] := Instances[I];
  FTiles[Idx].InstanceCount  := Length(Instances);
  FTiles[Idx].InstancesDirty := True;
  FTiles[Idx].Initialized    := False;
  FTiles[Idx].VAO            := 0;
  FTiles[Idx].DetailVAO      := 0;
  FTiles[Idx].InstanceVBO    := 0;
  FTiles[Idx].TileCenterX    := ATileCenterX;
  FTiles[Idx].TileCenterZ    := ATileCenterZ;
  { Retain source instances and bounds for switching from procedural trees.
    Invisible legacy alternatives need no sorted copy or branch-cell index. }
  FTiles[Idx].BranchCells:=nil;
  FTiles[Idx].BranchCellsReady:=False;

  SetCullDistance(ACullDistance);

  RecomputeTileBoundingBox(FTiles[Idx]);

  { Extend the union bbox so CGE can frustum-cull the whole renderer. }
  if FTiles[Idx].InstanceCount > 0 then
  begin
    if FUnionBox.IsEmpty then
      FUnionBox := FTiles[Idx].LocalBox
    else
      FUnionBox := FUnionBox + FTiles[Idx].LocalBox;
  end;
end;

procedure TInstancedBillboardRenderer.RemoveTile(ATileCenterX, ATileCenterZ: Single);
var
  I, Last: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(691);{$ENDIF}
  I := 0;
  while I < FTileCount do
  begin
    if (FTiles[I].TileCenterX = ATileCenterX) and
       (FTiles[I].TileCenterZ = ATileCenterZ) then
    begin
      FreeTileGL(FTiles[I]);
      Last := FTileCount - 1;
      if I < Last then
        FTiles[I] := FTiles[Last];     { tail fills the gap (its GL handles move with it) }
      FTiles[Last].Instances     := nil;  { release the now-duplicate / removed tail slot }
      FTiles[Last].InstanceCount := 0;
      FTiles[Last].Initialized   := False;
      FTiles[Last].VAO           := 0;
      FTiles[Last].DetailVAO     := 0;
      FTiles[Last].BranchCells   := nil;
      FTiles[Last].BranchCellsReady := False;
      FTiles[Last].InstanceVBO   := 0;
      Dec(FTileCount);
      { re-test the entry now sitting at I — do not advance }
    end
    else
      Inc(I);
  end;

  { a tile left the set — rebuild the union bbox CGE frustum-culls against }
  FUnionBox := TBox3D.Empty;
  for I := 0 to FTileCount - 1 do
    if FTiles[I].InstanceCount > 0 then
      if FUnionBox.IsEmpty then
        FUnionBox := FTiles[I].LocalBox
      else
        FUnionBox := FUnionBox + FTiles[I].LocalBox;
end;

procedure TInstancedBillboardRenderer.ClearTiles;
var I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(689);{$ENDIF}
  for I := 0 to FTileCount - 1 do
  begin
    FreeTileGL(FTiles[I]);
    FTiles[I].Instances := nil;
  end;
  FTiles     := nil;
  FTileCount := 0;
  FUnionBox  := TBox3D.Empty;
end;

function TInstancedBillboardRenderer.LocalBoundingBox: TBox3D;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(690);{$ENDIF}
  Result := FUnionBox;
end;

class procedure TInstancedBillboardRenderer.FrameBoundary;
{ Called once per frame (from the profiler's frame tick via the
  OnFrameBoundary hook). Publishes accumulated counts both to the
  class LastFrame* fields and to the profiler's plain vars (the
  profiler unit cannot see this class — reverse dependency), then
  resets for the next frame. }
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1228);{$ENDIF}
  LastFrameVisited := ThisFrameVisited;
  LastFrameDrawn   := ThisFrameDrawn;
  ProfInstancedVisited := ThisFrameVisited;
  ProfInstancedDrawn   := ThisFrameDrawn;
  ThisFrameVisited := 0;
  ThisFrameDrawn   := 0;
end;

function InstancedBoundsWithinRange(const LocalBox: TBox3D;
  const ModelMatrix: TMatrix4; const CameraWorldPos: TVector3;
  const CullDistanceSquared: Single): Boolean;
var
  WorldBox: TBox3D;
  Dx, Dz: Single;
begin
  if LocalBox.IsEmpty then Exit(False);
  if CullDistanceSquared <= 0 then Exit(True);
  WorldBox := LocalBox.Transform(ModelMatrix);
  Dx := Max(Max(WorldBox.Data[0].X - CameraWorldPos.X,
    CameraWorldPos.X - WorldBox.Data[1].X), 0.0);
  Dz := Max(Max(WorldBox.Data[0].Z - CameraWorldPos.Z,
    CameraWorldPos.Z - WorldBox.Data[1].Z), 0.0);
  Result := Dx * Dx + Dz * Dz <= CullDistanceSquared;
end;

procedure TInstancedBillboardRenderer.LocalRender(const Params: TRenderParams);
{ One shader bind for the whole forest, then a CPU distance-cull loop
  over every tile. Tiles that pass get their VAO bound and a draw call.

  This is the core of the "variant A" fix: the per-tile renderers used
  to be 5000-7000 separate TCastleTransform nodes, each walked by CGE's
  Update + Render passes every frame, scaling cost with map size. Now
  CGE sees one node; the tile loop here is plain arithmetic over a flat
  array — its cost scales with map size too, but at ~5 ns/tile instead
  of a full CGE node visit, and the GL state (program, uniforms,
  textures) is set ONCE for all visible tiles instead of once per tile. }
var
  ProjMat, ViewMat, ModelMat: TMatrix4;
  LightDir: TVector3;
  CamWorldPos: TVector3;
  DetailCamera, LocalCamera, Delta:TVector3;
  DetailRange, ModelScale:Single;
  LodNear, LodFar: Single;
  S: PInstancedSharedResources;
  TInst: Int64;
  I,J: Integer;
  AnyVisible: Boolean;
  Frust: TFrustum;
  IsDepth, SavedState: Boolean;
  SavedDepthRange: TDepthRange;
  SavedProgram, SavedVAO, SavedArrayBuffer, SavedActiveTexture, SavedDepthFunc: GLint;
  SavedTexture0, SavedArray0, SavedTexture1, SavedArray2: GLint;
  SavedDepthTest, SavedDepthMask, SavedBlend, SavedCull: GLboolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(692);{$ENDIF}
  if RtxReflectionCaptureActive then Exit;
  if not CheckVisible then Exit;
  if not RenderTreesActive then Exit;
  if FProceduralAlternative and ProceduralVegetationActive then Exit;
  IsDepth := Params.RenderingCamera.Target = rtShadowMap;
  SavedState := False;
  GlobalCpuProfiler.BeginSection(CPSection_InstancedTile, TInst);
  try
    if FTileCount = 0 then Exit;
      { Raw instancing must preserve the state of the surrounding CGE renderer.
        Keep its logical caches intact and restore the actual GL bindings. }
      glGetIntegerv(GL_CURRENT_PROGRAM, @SavedProgram);
      glGetIntegerv(GL_VERTEX_ARRAY_BINDING, @SavedVAO);
      glGetIntegerv(GL_ARRAY_BUFFER_BINDING, @SavedArrayBuffer);
      glGetIntegerv(GL_ACTIVE_TEXTURE, @SavedActiveTexture);
      glGetIntegerv(GL_DEPTH_FUNC, @SavedDepthFunc);
      glGetBooleanv(GL_DEPTH_WRITEMASK, @SavedDepthMask);
      SavedDepthTest := glIsEnabled(GL_DEPTH_TEST);
      SavedBlend := glIsEnabled(GL_BLEND);
      SavedCull := glIsEnabled(GL_CULL_FACE);
      glActiveTexture(GL_TEXTURE0);
      glGetIntegerv(GL_TEXTURE_BINDING_2D, @SavedTexture0);
      glGetIntegerv(GL_TEXTURE_BINDING_2D_ARRAY, @SavedArray0);
      glActiveTexture(GL_TEXTURE1);
      glGetIntegerv(GL_TEXTURE_BINDING_2D, @SavedTexture1);
      glActiveTexture(GL_TEXTURE2);
      glGetIntegerv(GL_TEXTURE_BINDING_2D_ARRAY, @SavedArray2);
      glActiveTexture(GL_TEXTURE0);
      SavedState := True;
      { CGE restores drFar (0.1..1) after drawing ordinary shapes. Raw
        instancing runs before the shape collector, so it must explicitly
        use the same 0..1 mapping as the shadow sampler and CGE casters. }
      SavedDepthRange := RenderContext.DepthRange;
      if IsDepth then RenderContext.DepthRange := drFull;
    if FProceduralAlternative and not HasSharedTextures then
    begin
      if Self is TCastleAbstractTreeRenderer then
        TCastleAbstractTreeRenderer.LoadSharedTextures(URIToFilenameSafe('castle-data:/Osm3d/resources/models/tree/'))
      else if Self is TCastleAbstractShrubRenderer then
        TCastleAbstractShrubRenderer.LoadSharedTextures(URIToFilenameSafe('castle-data:/Osm3d/resources/models/shrubbery/'));
    end;
    if not HasSharedTextures then Exit;

    ViewMat := Params.RenderingCamera.Matrix;
    CamWorldPos := CameraWorldPosFromView(ViewMat);
    DetailCamera:=CamWorldPos;
    if IsDepth and GShadowViewerValid then DetailCamera:=GShadowViewer;

    { View frustum in this renderer's LOCAL space — the space the per-tile
      LocalBox-es and the instance VBOs live in (the shader maps it to clip
      via Proj*View*Model). Tiles whose box is fully outside it are skipped.
      CGE applies this cull to its scenes, but NOT to this raw-GL renderer:
      without it EVERY tile within FCullDistance is drawn no matter where the
      camera looks (distance cull ignores view direction), so looking down /
      away never sheds the vegetation draw-calls. ProjMat/ModelMat are read
      here (not just before the draw) so the AnyVisible pass can early-out on
      a fully off-screen forest, skipping all GL state too. }
    ProjMat  := RenderContext.ProjectionMatrix;
    ModelMat := WorldTransform;
    LocalCamera:=WorldInverseTransform.MultPoint(DetailCamera);
    ModelScale:=Min(ModelMat.MultDirection(Vector3(1,0,0)).Length,
      Min(ModelMat.MultDirection(Vector3(0,1,0)).Length,ModelMat.MultDirection(Vector3(0,0,1)).Length));
    DetailRange:=VEGETATION_BRANCH_FAR_METERS/Max(ModelScale,0.0001);
    Frust.Init(ProjMat * ViewMat * ModelMat);

    { First pass: is ANY tile visible? Avoids binding the shader /
      setting GL state when the whole forest is out of range — and
      lets us count visited tiles for the profiler. }
    AnyVisible := False;
    for I := 0 to FTileCount - 1 do
    begin
      if not IsDepth then Inc(ThisFrameVisited);
      if FTiles[I].InstanceCount = 0 then Continue;
      if (not IsDepth) and (FCullDistance > 0) and
        not InstancedBoundsWithinRange(FTiles[I].LocalBox, ModelMat,
          CamWorldPos, FCullDistanceSq) then Continue;
      if not Frust.Box3DCollisionPossibleSimple(FTiles[I].LocalBox) then Continue;
      AnyVisible := True;
      Break;
    end;
    if not AnyVisible then Exit;

    { Shared GL state — set ONCE for all visible tiles }
    S := SharedResPtr;

    { Single scene sun (set from the FIT file via SetInstancedSunDir). The
      shader normalises (-lightDir) itself; guard only against a zero vector
      so normalize() never produces NaN and blackens the canopy. }
    LightDir := GInstancedSunRayDir;
    if FSunRayDirection.Length>0.001 then LightDir:=FSunRayDirection;
    if LightDir.Length > 1e-5 then
      LightDir := LightDir.Normalize
    else
    begin
      LightDir := DEFAULT_SUN_RAY_DIR;
      LightDir := LightDir.Normalize;
    end;

    glEnable(GL_DEPTH_TEST);
    glDepthFunc(GL_LESS);
    glDepthMask(GL_TRUE);
    glDisable(GL_BLEND);
    glDisable(GL_CULL_FACE);

    glUseProgram(S^.Program_);
    glUniform1i(S^.UniDetailPass,0);
    glUniform1i(S^.UniBranchesEnabled,Ord(VegetationBranchesEnabled and (S^.BranchTexture<>0)));
    glUniform2f(S^.UniBranchLodDistances,VEGETATION_BRANCH_FULL_METERS,VEGETATION_BRANCH_FAR_METERS);
    if S^.UniDepthOnly >= 0 then glUniform1i(S^.UniDepthOnly, Ord(IsDepth));

    glUniformMatrix4fv(S^.UniProjectionMatrix, 1, GL_FALSE, @ProjMat);
    glUniformMatrix4fv(S^.UniViewMatrix,       1, GL_FALSE, @ViewMat);
    glUniformMatrix4fv(S^.UniModelMatrix,      1, GL_FALSE, @ModelMat);
    glUniform3fv(S^.UniLightDir, 1, @LightDir);

    if S^.UniCameraWorldPos >= 0 then
      glUniform3fv(S^.UniCameraWorldPos, 1, @DetailCamera);

    GetLODBases(LodNear, LodFar);
    { Shadow coverage is controlled by the atlas frustum, as before. The
      colour pass uses exactly the same world-XZ radius as the CPU bounds. }
    if IsDepth then LodFar := 0;
    if S^.UniLodNearBase >= 0 then
      glUniform1f(S^.UniLodNearBase, LodNear);
    if S^.UniLodFarBase >= 0 then
      glUniform1f(S^.UniLodFarBase, LodFar);
    if S^.UniLodHeightRef >= 0 then
      glUniform1f(S^.UniLodHeightRef, GlobalLODConfig.HeightScaleRef);
    if S^.UniLodGroundRefY >= 0 then
      glUniform1f(S^.UniLodGroundRefY, GlobalLODConfig.GroundReferenceY);

    { Shared scene wind (Osm3dWind). Trees include WIND_GLSL; shrubs zeroed it
      so every location is -1 and this is a no-op for them. }
    WindSetUniforms(S^.Wind);

    BindShaderTextures;
    glActiveTexture(GL_TEXTURE2);
    glBindTexture(GL_TEXTURE_2D_ARRAY,S^.BranchTexture);
    glUniform1i(S^.UniBranchTexture,2);

    GlobalShaderProfiler.BeginSection(GetProfilerName);
    try
      for I := 0 to FTileCount - 1 do
      begin
        if FTiles[I].InstanceCount = 0 then Continue;
        if (not IsDepth) and (FCullDistance > 0) and
          not InstancedBoundsWithinRange(FTiles[I].LocalBox, ModelMat,
            CamWorldPos, FCullDistanceSq) then Continue;

        { Off-screen tiles cost nothing: skip the VAO bind + instanced draw
          (and the lazy upload) for any tile whose box is outside the view
          frustum. This is the cut that makes looking away/down actually
          drop the vegetation draw-call count instead of holding it flat. }
        if not Frust.Box3DCollisionPossibleSimple(FTiles[I].LocalBox) then Continue;

        { Lazy GL init + upload — only visible tiles ever pay it. }
        EnsureBranchCells(FTiles[I]);
        if not FTiles[I].Initialized then InitTileGL(FTiles[I]);
        if FTiles[I].InstancesDirty   then UploadTileVBO(FTiles[I]);

        glBindVertexArray(FTiles[I].VAO);
        glUniform1i(S^.UniDetailPass,0);
        glDrawElementsInstanced(GL_TRIANGLES, GetMeshIndexCount,
          GL_UNSIGNED_SHORT, nil, FTiles[I].InstanceCount);
        if IsDepth then Inc(ShadowDrawCalls)
        else begin Inc(ThisFrameDrawn); Inc(ColorDrawCalls); end;
        Delta.X:=Max(Max(FTiles[I].LocalBox.Data[0].X-LocalCamera.X,LocalCamera.X-FTiles[I].LocalBox.Data[1].X),0.0);
        Delta.Y:=Max(Max(FTiles[I].LocalBox.Data[0].Y-LocalCamera.Y,LocalCamera.Y-FTiles[I].LocalBox.Data[1].Y),0.0);
        Delta.Z:=Max(Max(FTiles[I].LocalBox.Data[0].Z-LocalCamera.Z,LocalCamera.Z-FTiles[I].LocalBox.Data[1].Z),0.0);
        if VegetationBranchesEnabled and (S^.BranchTexture<>0) and (TVector3.DotProduct(Delta,Delta)<=Sqr(DetailRange)) then
          for J:=0 to High(FTiles[I].BranchCells)do
          with FTiles[I].BranchCells[J]do begin
            Delta.X:=Max(Max(MinOrigin.X-LocalCamera.X,LocalCamera.X-MaxOrigin.X),0.0);
            Delta.Y:=Max(Max(MinOrigin.Y-LocalCamera.Y,LocalCamera.Y-MaxOrigin.Y),0.0);
            Delta.Z:=Max(Max(MinOrigin.Z-LocalCamera.Z,LocalCamera.Z-MaxOrigin.Z),0.0);
            if TVector3.DotProduct(Delta,Delta)>Sqr(DetailRange)then Continue;
            InitDetailGL(FTiles[I]);glBindVertexArray(FTiles[I].DetailVAO);
            glBindBuffer(GL_ARRAY_BUFFER,FTiles[I].InstanceVBO);
            SetupInstanceAttribs(PtrUInt(First)*TREE_INSTANCE_STRIDE);
            glUniform1i(S^.UniDetailPass,1);
            glDrawElementsInstanced(GL_TRIANGLES,S^.DetailIndexCount,GL_UNSIGNED_SHORT,nil,Count);
            if IsDepth then Inc(BranchShadowDrawCalls)
            else begin Inc(BranchDrawCalls);Inc(BranchInstancesSubmitted,Count);end;
          end;
      end;
    finally
      GlobalShaderProfiler.EndSection;
    end;
    glBindVertexArray(0);
    glBindBuffer(GL_ARRAY_BUFFER,0);

    UnbindShaderTextures;
    glActiveTexture(GL_TEXTURE2);
    glBindTexture(GL_TEXTURE_2D_ARRAY,0);
    glUseProgram(0);
    glActiveTexture(GL_TEXTURE0);
  finally
    if SavedState then
    begin
      RenderContext.DepthRange := SavedDepthRange;
      glUseProgram(SavedProgram);
      glBindVertexArray(SavedVAO);
      glBindBuffer(GL_ARRAY_BUFFER, SavedArrayBuffer);
      glDepthFunc(SavedDepthFunc);
      glDepthMask(SavedDepthMask);
      if SavedDepthTest <> GL_FALSE then glEnable(GL_DEPTH_TEST) else glDisable(GL_DEPTH_TEST);
      if SavedBlend <> GL_FALSE then glEnable(GL_BLEND) else glDisable(GL_BLEND);
      if SavedCull <> GL_FALSE then glEnable(GL_CULL_FACE) else glDisable(GL_CULL_FACE);
      glActiveTexture(GL_TEXTURE0);
      glBindTexture(GL_TEXTURE_2D, SavedTexture0);
      glBindTexture(GL_TEXTURE_2D_ARRAY, SavedArray0);
      glActiveTexture(GL_TEXTURE1);
      glBindTexture(GL_TEXTURE_2D, SavedTexture1);
      glActiveTexture(GL_TEXTURE2);
      glBindTexture(GL_TEXTURE_2D_ARRAY, SavedArray2);
      glActiveTexture(SavedActiveTexture);
    end;
    GlobalCpuProfiler.EndSection(CPSection_InstancedTile, TInst);
  end;
end;

{ Two crossed upright quads at 90 degrees around Y (four rays). Each quad is single-sided geometry — the
  fragment shader lights both faces via abs(dot(N,L)) and the draw runs with
  GL_CULL_FACE disabled, so every card is already visible and lit from both
  sides; explicit back faces would be dead (coplanar, GL_LESS-rejected).
  8 vertices, 12 indices = 4 triangles. }
const
  TREE_MESH_VERT_COUNT  = 8;
  TREE_MESH_INDEX_COUNT = 12;
  TREE_VERT_STRIDE_FLOATS = 8;

  TREE_MESH_DATA: array[0..TREE_MESH_VERT_COUNT * TREE_VERT_STRIDE_FLOATS - 1] of GLfloat = (
  { px,     py,   pz,          nx,         ny,   nz,     u,   v }
    { quad 0 — 0 deg (plane z=0) }
   -0.5,    0.0,  0.0,         0.0,        0.0,  1.0,    0.0, 1.0,   {  0 }
    0.5,    0.0,  0.0,         0.0,        0.0,  1.0,    1.0, 1.0,   {  1 }
   -0.5,    1.0,  0.0,         0.0,        0.0,  1.0,    0.0, 0.0,   {  2 }
    0.5,    1.0,  0.0,         0.0,        0.0,  1.0,    1.0, 0.0,   {  3 }
    { quad 1 — 90 deg }
    0.0,    0.0, -0.5,        -1.0,        0.0,  0.0,    0.0, 1.0,   {  4 }
    0.0,    0.0,  0.5,        -1.0,        0.0,  0.0,    1.0, 1.0,   {  5 }
    0.0,    1.0, -0.5,        -1.0,        0.0,  0.0,    0.0, 0.0,   {  6 }
    0.0,    1.0,  0.5,        -1.0,        0.0,  0.0,    1.0, 0.0    {  7 }
  );

  TREE_MESH_INDICES: array[0..TREE_MESH_INDEX_COUNT - 1] of GLushort = (
    0,  1,  3,    0,  3,  2,
    4,  5,  7,    4,  7,  6
  );

{$I Osm3dVegetationBranches.inc}

{ Near branches use disconnected polygons, then the original crossed cards, then
  one camera-facing card. CPU bounds and per-instance shader culls share the
  same world-XZ range. }
const
  TREE_VERT_SOURCE: AnsiString =
'#version 330 core' + LineEnding +
LineEnding +
'layout(location = 0) in vec3 position;' + LineEnding +
'layout(location = 1) in vec3 normal;' + LineEnding +
'layout(location = 2) in vec2 uv;' + LineEnding +
'layout(location = 3) in vec3 instancePosition;' + LineEnding +
'layout(location = 4) in float instanceScale;' + LineEnding +
'layout(location = 5) in float instanceRotation;' + LineEnding +
'layout(location = 6) in float instanceSeed;' + LineEnding +
LineEnding +
'uniform mat4 projectionMatrix;' + LineEnding +
'uniform mat4 viewMatrix;' + LineEnding +
'uniform mat4 modelMatrix;' + LineEnding +
'uniform vec3 cameraWorldPos;  // tree sub-LOD: camera world position' + LineEnding +
'uniform float lodNearBase;    // = GlobalLODConfig.TreesNearMeters; 0 disables' + LineEnding +
'uniform float lodFarBase;     // world XZ range; 0 disables (shadow pass)' + LineEnding +
LineEnding +
'out vec2 vUv;' + LineEnding +
'out vec3 vNormalWorld;' + LineEnding +
'flat out int vTextureId;' + LineEnding +
'flat out vec2 vWorldXZ;' + LineEnding +
'flat out float vCardW;        // card width in world metres (= instanceScale)' + LineEnding +
LineEnding +
'mat2 rotate2d(float a) {' + LineEnding +
'    return mat2(cos(a), -sin(a), sin(a), cos(a));' + LineEnding +
'}' + LineEnding +
LineEnding +
WIND_GLSL + BRANCH_VERTEX_GLSL + TREE_LAYER_PIVOTS_GLSL +
'void main() {' + LineEnding +
'    vUv = uv;' + LineEnding +
'    vTextureId = int(instanceSeed);' + LineEnding +
'    // Instance origin in world XZ — a stable per-tree phase for the' + LineEnding +
'    // fragment-shader leaf rustle (continuous, so neighbours decorrelate).' + LineEnding +
'    vWorldXZ = (modelMatrix * vec4(instancePosition, 1.0)).xz;' + LineEnding +
'    vCardW   = instanceScale;   // mesh is 1 unit wide -> world width = scale' + LineEnding +
LineEnding +
'    // ---- Tree sub-LOD: past lodNearBase, ONE camera-facing card (blade 0),' + LineEnding +
'    //      blade 1 collapsed. Card id = gl_VertexID/4 (mesh: verts 0-3,' + LineEnding +
'    //      4-7). Billboard built in WORLD space (robust to modelMatrix' + LineEnding +
'    //      translation/rotation; uniform model scale from column-0 length). ----' + LineEnding +
'    vec3 instWorld = (modelMatrix * vec4(instancePosition, 1.0)).xyz;' + LineEnding +
'    vec2 farDelta = instWorld.xz - cameraWorldPos.xz;' + LineEnding +
'    if (lodFarBase > 0.0 && dot(farDelta,farDelta) > lodFarBase*lodFarBase) { gl_Position=vec4(2.0,2.0,2.0,1.0); vNormalWorld=vec3(0,1,0); return; }' + LineEnding +
'    if (!branchPassVisible(instWorld)) { gl_Position=vec4(2.0,2.0,2.0,1.0); vNormalWorld=vec3(0,1,0); return; }' + LineEnding +
'    float dxc = instWorld.x - cameraWorldPos.x;' + LineEnding +
'    float dzc = instWorld.z - cameraWorldPos.z;' + LineEnding +
'    if (branchDetailPass == 0 && (lodNearBase > 0.0) && (dxc*dxc + dzc*dzc > lodNearBase*lodNearBase)) {' + LineEnding +
'        int card = gl_VertexID / 4;' + LineEnding +
'        if (card != 0) {                 // collapse blade 1 -> degenerate' + LineEnding +
'            gl_Position  = projectionMatrix * viewMatrix * vec4(instWorld, 1.0);' + LineEnding +
'            vNormalWorld = vec3(0.0, 1.0, 0.0);' + LineEnding +
'            return;' + LineEnding +
'        }' + LineEnding +
'        vec2  dirXZ  = normalize(instWorld.xz - cameraWorldPos.xz);' + LineEnding +
'        vec3  rightW = vec3(-dirXZ.y, 0.0, dirXZ.x);   // horizontal, faces cam' + LineEnding +
'        float sW     = instanceScale * length(modelMatrix[0].xyz);' + LineEnding +
'        vec3  vw = instWorld + sW * position.x * rightW' + LineEnding +
'                             + sW * position.y * vec3(0.0, 1.0, 0.0);' + LineEnding +
'        gl_Position  = projectionMatrix * viewMatrix * vec4(vw, 1.0);' + LineEnding +
'        vNormalWorld = vec3(-dirXZ.x, 0.0, -dirXZ.y); // toward camera' + LineEnding +
'        return;' + LineEnding +
'    }' + LineEnding +
LineEnding +
'    mat2 R = rotate2d(instanceRotation);' + LineEnding +
LineEnding +
'    // Mesh normal → rotated around Y → world space.' + LineEnding +
'    vec3 p=position, n=normal;' + LineEnding +
TREE_BRANCH_PIVOT_GLSL +
BRANCH_VERTEX_TAIL;

  TREE_FRAG_SOURCE: AnsiString =
'#version 330 core' + LineEnding +
LineEnding +
'in vec2  vUv;' + LineEnding +
'in vec3  vNormalWorld;' + LineEnding +
'flat in int  vTextureId;' + LineEnding +
'flat in vec2 vWorldXZ;' + LineEnding +
'flat in float vCardW;' + LineEnding +
LineEnding +
'uniform sampler2DArray tMap;' + LineEnding +
'uniform sampler2D tVolumeNormal;' + LineEnding +
'uniform vec3  lightDir;' + LineEnding +
'uniform int depthOnly;' + LineEnding +
BRANCH_FRAGMENT_GLSL +
WIND_GLSL +
LineEnding +
'out vec4 fragColor;' + LineEnding +
LineEnding +
'// Same constants/colourspace/tonemap as the ground composite shader' + LineEnding +
'// (Osm3dGroundComposite) so canopy and terrain share one exposure.' + LineEnding +
'const vec3  SUN_COLOR      = vec3(1.000, 0.970, 0.920);' + LineEnding +
'const float SUN_INTENSITY  = 8.0;' + LineEnding +
'const float AMBIENT_FACTOR = 0.45;' + LineEnding +
'const float VEG_EXPOSURE   = 0.4;   // canopy brightness knob; <1 darker, 1.0 = match ground' + LineEnding +
'const float PI             = 3.14159265;' + LineEnding +
'// Leaf-rustle knobs — fragment-only, no geometry moves.' + LineEnding +
'const float BOIL_AT_REF = 0.02; // leaf-flutter UV amp at WIND_U_REF: ~2% of canopy tip travel at 10 m/s, x resp(U)' + LineEnding +
'const float LEAN_AT_REF = 0.06; // crown-lean UV amp at WIND_U_REF: ~6% branch-tip deflection at 10 m/s, x resp(U); moves colour+alpha' + LineEnding +
'const float LEAN_EVEN   = 0.5;  // <1 evens lean across the 3 cards (lifts the near-face-on quad); 1 = raw projection' + LineEnding +
'const float BRANCH_TAPER = 1.5; // sway 0 at trunk -> full at crown; >1 = limbs near trunk move much less' + LineEnding +
'const float WIDTH_TAPER  = 1.5; // sway 0 at trunk axis (centre) -> full at canopy rim; thin outer limbs move most' + LineEnding +
'const float RUSTLE_GLINT = 0.18;    // canopy brightness twinkle amount' + LineEnding +
'const float RUSTLE_FREQ  = 9.0;     // spatial frequency of the boil' + LineEnding +
'const float NORMAL_STRENGTH = 1.0;  // leaf normal-map influence (0 = flat, >1 = deeper)' + LineEnding +
'// Leaf light-flutter on the NORMAL map — decoupled from the UV sway above so it' + LineEnding +
'// keeps shimmering in light wind instead of degrading to a slow light wave.' + LineEnding +
'const float NORMAL_WAVE_SPEED = 2.4;   // flutter speed (independent of wind amplitude); kept high = fast micro-shimmer' + LineEnding +
'const float NORMAL_WAVE_AMP   = 0.004; // flutter amplitude (UV); small now that the diffuse warp is the visible motion' + LineEnding +
'vec3 srgbToLin(vec3 c) { return pow(c, vec3(2.2)); }' + LineEnding +
'vec3 linToSrgb(vec3 c) { return pow(c, vec3(1.0/2.2)); }' + LineEnding +
'float n2(vec2 p) { return 0.5*sin(p.x*1.7 + p.y*2.3) + 0.5*sin(p.x*3.1 - p.y*1.3); }' + LineEnding +
LineEnding +
'void main() {' + LineEnding +
'    if(!branchPixelVisible()) discard;' + LineEnding +
'    // Per-tree phase — spatially coherent, like grass keys off base.xz.' + LineEnding +
'    vec2  ph   = vWorldXZ * 0.35;' + LineEnding +
'    // Leaf mask: 1 in the upper canopy, 0 at the trunk base' + LineEnding +
'    // (vUv.y: 0 = top of card, 1 = bottom). Trunk stays still.' + LineEnding +
'    float leaf = 1.0 - smoothstep(0.45, 0.80, vUv.y);' + LineEnding +
'    // Branch-sway weight = height taper * width taper, both 0..1:' + LineEnding +
'    //  - height: 0 at the trunk base, rising to the crown top (cantilever-like);' + LineEnding +
'    //  - width:  0 on the trunk axis (uv.x=0.5), rising to the canopy rim, since' + LineEnding +
'    //    outer limbs are thin/flexible and the central stem is rigid.' + LineEnding +
'    // leaf zeroes the trunk texture; crown top rim (uv.x~0/1, uv.y~0) stays ~1.' + LineEnding +
'    float hTaper = pow(clamp(1.0 - vUv.y, 0.0, 1.0), BRANCH_TAPER);' + LineEnding +
'    float wTaper = pow(clamp(abs(vUv.x - 0.5) * 2.0, 0.0, 1.0), WIDTH_TAPER);' + LineEnding +
'    wTaper = mix(wTaper, 1.0, hTaper); // apex bends: drop trunk-axis stiffness toward top' + LineEnding +
'    float swayW  = leaf * hTaper * wTaper;' + LineEnding +
'    float t    = uWindTime;' + LineEnding +
'    // Shared wind speed (m/s) -> physical bend response, identical to grass,' + LineEnding +
'    // sampled at this tree''s world XZ so gusts roll through the forest.' + LineEnding +
'    float resp = vWindResponse;' + LineEnding +
LineEnding +
'    // Card frame (also reused for the normal mapping below). T is the world' + LineEnding +
'    // direction of increasing uv.x (card width).' + LineEnding +
'    vec3 Nf = normalize(vNormalWorld);' + LineEnding +
'    vec3 T  = cross(vec3(0.0, 1.0, 0.0), Nf);' + LineEnding +
'    T = (length(T) > 1e-4) ? normalize(T) : vec3(1.0, 0.0, 0.0);' + LineEnding +
LineEnding +
'    // ---- layer 1: leaves flutter in place (UV-domain boil) ----' + LineEnding +
'    vec2 flow = vec2(n2(vUv*RUSTLE_FREQ + ph + vec2( t*1.7,  t*1.1)),' + LineEnding +
'                     n2(vUv*RUSTLE_FREQ + ph + vec2(-t*1.3,  t*1.9)));' + LineEnding +
'    // Boil amplitude scales with wind strength: leaves are nearly still in' + LineEnding +
'    // calm air and tremble more as a gust passes (this is the wind reaction).' + LineEnding +
'    // Amplitude is a UV fraction (NOT divided by card width). The earlier' + LineEnding +
'    // metre-scaled warp was sub-pixel on 20-37 m crowns and invisible, while' + LineEnding +
'    // the normal flutter (fixed UV amp) carried all the visible motion. Now' + LineEnding +
'    // the warp shifts the same UV fraction on every tree. Trade-off: motion' + LineEnding +
'    // is no longer size-independent in absolute metres.' + LineEnding +
'    vec2 boil = flow * (BOIL_AT_REF * resp) * swayW;' + LineEnding +
'    // Fade ONLY the boil where a texel grows past a pixel, so distant trees' + LineEnding +
'    // do not fizz/alias. The directional lean below is low-frequency and is' + LineEnding +
'    // left unfaded, so far forests still lean in strong wind.' + LineEnding +
'    boil *= 1.0 - smoothstep(0.01, 0.06, max(fwidth(vUv.x), fwidth(vUv.y)));' + LineEnding +
LineEnding +
'    // ---- layer 2: directional lean toward the wind (same UV mechanism) ----' + LineEnding +
'    // Project the world wind onto the card width T: the crown slides toward' + LineEnding +
'    // the wind, strongest at the top (leaf mask), scaled by wind strength.' + LineEnding +
'    // This is an added UV offset — the "наклон", on top of the boil.' + LineEnding +
'    // (Flip the sign if the lean goes the wrong way.)' + LineEnding +
'    vec3  windDir3 = vec3(uWindDir.x, 0.0, uWindDir.y);' + LineEnding +
'    float alongU   = dot(windDir3, T);              // wind along card width, [-1,1]' + LineEnding +
'    // Even out the per-card spread: raw |alongU| ranges 0..1 across the three' + LineEnding +
'    // cards (the near-face-on quad freezes, the aligned one whips). A power' + LineEnding +
'    // <1 lifts the weak cards toward the strong; sign preserves direction.' + LineEnding +
'    float effU     = sign(alongU) * pow(abs(alongU), LEAN_EVEN);' + LineEnding +
'    vec2  lean     = vec2(-effU * (LEAN_AT_REF * resp) * swayW, 0.0);' + LineEnding +
LineEnding +
'    vec2 uv = vec2(vUv.x, 1.0 - vUv.y) + boil + lean;' + LineEnding +
'    if(!branchLayerVisible(uv,vTextureId)) discard;' + LineEnding +
'    vec4 c=texture(tMap,vec3(uv,float(vTextureId*2)));' + LineEnding +
'    if (c.a < 0.5) discard;' + LineEnding +
'    if (depthOnly != 0) { fragColor = vec4(1.0); return; }' + LineEnding +
LineEnding +
'    vec3 albedoLin = srgbToLin(c.rgb);' + LineEnding +
LineEnding +
'    // ---- canopy shading: real tangent-space normal mapping ----' + LineEnding +
'    // The per-species leaf normal (array layer +1) is used as an actual' + LineEnding +
'    // normal map. Cards stand upright, so the tangent frame is (card-width,' + LineEnding +
'    // world-up, card-facing), built from the face normal with no extra' + LineEnding +
'    // vertex data. Sampled at the warped uv so highlights crawl with the' + LineEnding +
'    // rustle. (If vertical lighting looks inverted the map is DirectX-Y:' + LineEnding +
'    // negate nTex.y.)' + LineEnding +
'    // Independent leaf-light flutter for the normal: its own (fast) speed and' + LineEnding +
'    // steady amplitude, so the shimmer persists when the wind-scaled UV sway is' + LineEnding +
'    // small. Added on top of the warped uv, so it still tracks boil + lean.' + LineEnding +
'    float nt = uWindTime * NORMAL_WAVE_SPEED;' + LineEnding +
'    vec2 nflow = vec2(n2(vUv*RUSTLE_FREQ + ph*1.3 + vec2( nt,      nt*0.7)),' + LineEnding +
'                      n2(vUv*RUSTLE_FREQ + ph*1.3 + vec2(-nt*0.8,  nt*1.2)));' + LineEnding +
'    vec2 nuv = uv + nflow * NORMAL_WAVE_AMP * leaf;' + LineEnding +
'    vec3 nTex=texture(tMap,vec3(nuv,float(vTextureId*2+1))).xyz*2.0-1.0;' + LineEnding +
'    nTex.xy *= NORMAL_STRENGTH;' + LineEnding +
'    vec3 B  = cross(Nf, T);                          // ~ world up (bitangent)' + LineEnding +
'    vec3 N  = normalize(T * nTex.x + B * nTex.y + Nf * nTex.z);' + LineEnding +
'    // abs(): cards are seen from both sides (no cull) -> no black backs.' + LineEnding +
'    float NdotL = abs(dot(N, normalize(-lightDir)));' + LineEnding +
'    // Procedural leaf twinkle on top of the mapped shading.' + LineEnding +
'    NdotL *= 1.0 + RUSTLE_GLINT * leaf' + LineEnding +
'                 * n2(vUv*14.0 + ph*1.7 + vec2(t*2.3, -t*2.0));' + LineEnding +
LineEnding +
'    vec3 colorLin = albedoLin * (SUN_COLOR * (SUN_INTENSITY / PI) * NdotL' + LineEnding +
'                               + vec3(AMBIENT_FACTOR));' + LineEnding +
'    colorLin *= VEG_EXPOSURE;' + LineEnding +
'    vec3 colorTM = colorLin / (colorLin + vec3(1.0));   // Reinhard' + LineEnding +
'    fragColor = vec4(linToSrgb(colorTM), 1.0);' + LineEnding +
'}' + LineEnding;

class procedure TCastleAbstractTreeRenderer.DoEnsureSharedGL;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1229);{$ENDIF}
  if FShared.Initialized then Exit;

  UploadBaseMeshBuffers(FShared,
    @TREE_MESH_DATA[0], SizeOf(TREE_MESH_DATA),
    @TREE_MESH_INDICES[0], SizeOf(TREE_MESH_INDICES));

  UploadDetailMesh(FShared,TREE_MESH_DATA,TREE_MESH_INDICES,True);

  CompileLinkProgram(FShared, TREE_VERT_SOURCE, TREE_FRAG_SOURCE, 'Tree');

  CacheCommonUniforms(FShared);
  { Trees now use the near sub-LOD: cameraWorldPos + lodNearBase drive the
    2-blade -> single camera-facing billboard switch past TreesNearMeters. The
    remaining LOD uniforms stay unused (-1). }
  FShared.UniCameraWorldPos := glGetUniformLocation(FShared.Program_, 'cameraWorldPos');
  FShared.UniLodNearBase    := glGetUniformLocation(FShared.Program_, 'lodNearBase');
  FShared.UniLodFarBase     := glGetUniformLocation(FShared.Program_, 'lodFarBase');
  FShared.UniLodHeightRef   := -1;
  FShared.UniLodGroundRefY  := -1;

  { Shared wind field (Osm3dWind.WIND_GLSL) — trees animate the canopy with it. }
  FShared.Wind := WindCacheUniforms(FShared.Program_);

  FUniTextureArray := glGetUniformLocation(FShared.Program_, 'tMap');
  FUniVolumeNormal := glGetUniformLocation(FShared.Program_, 'tVolumeNormal');

  FShared.Initialized := True;
  ProfilerLog(Format('SHADER trees: program CREATED handle=%d',
    [FShared.Program_]));
end;

class procedure TCastleAbstractTreeRenderer.LoadSharedTextures(
  const TexturesDir: string);
const
  TEXTURE_DIM  = 512;
  ARRAY_LAYERS = 10;
  { Order matches the shader (vTextureId * 2 = diffuse, +1 = normal). }
  LAYER_FILES: array[0..9] of string = (
    'beech_diffuse.png',   'beech_normal.png',
    'fir_diffuse.png',     'fir_normal.png',
    'linden0_diffuse.png', 'linden0_normal.png',
    'linden1_diffuse.png', 'linden1_normal.png',
    'oak_diffuse.png',     'oak_normal.png'
  );
var
  I: Integer;
  Dir: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1230);{$ENDIF}
  DoEnsureSharedGL;

  if FTextureArray = 0 then
  begin
    AccGenTextures(1, @FTextureArray);
    glBindTexture(GL_TEXTURE_2D_ARRAY, FTextureArray);
    glTexImage3D(GL_TEXTURE_2D_ARRAY, 0, GL_RGBA8,
      TEXTURE_DIM, TEXTURE_DIM, ARRAY_LAYERS,
      0, GL_RGBA, GL_UNSIGNED_BYTE, nil);
    glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    ProfilerLog(Format('TEX trees: created GL_TEXTURE_2D_ARRAY handle=%d '
      + '(%d layers, %dx%d)',
      [FTextureArray, ARRAY_LAYERS, TEXTURE_DIM, TEXTURE_DIM]));
  end;

  Dir := IncludeTrailingPathDelimiter(TexturesDir);
  for I := 0 to High(LAYER_FILES) do
    UploadPngToTextureArrayLayer(Dir + LAYER_FILES[I],
      FTextureArray, I, TEXTURE_DIM, TEXTURE_DIM);

  if FVolumeNormalTex <> 0 then
  begin
    ProfilerLog(Format('TEX trees: deleting old volume-normal handle=%d',
      [FVolumeNormalTex]));
    AccDeleteTextures(1, @FVolumeNormalTex);
  end;
  FVolumeNormalTex := UploadPngToTexture2D(Dir + 'tree_volume_normal.png',
    GL_REPEAT, GL_REPEAT);

  LoadBranchTextures(FShared,Dir,['beech','fir','linden0','linden1','oak'],VEGETATION_TREE_LAYERS);

  FShared.TexturesLoaded := True;
  ProfilerLog(Format('TEX trees: shared textures LOADED — array=%d normal=%d',
    [FTextureArray, FVolumeNormalTex]));
end;

class function TCastleAbstractTreeRenderer.AreSharedTexturesLoaded: Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1231);{$ENDIF}
  Result := FShared.TexturesLoaded;
end;

class procedure TCastleAbstractTreeRenderer.CleanupSharedGL;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1232);{$ENDIF}
  ProfilerLog(Format('TEX trees: CleanupSharedGL — DELETING shared GL '
    + '(program=%d texArray=%d volNormal=%d)',
    [FShared.Program_, FTextureArray, FVolumeNormalTex]));
  if FShared.Program_     <> 0 then begin glDeleteProgram(FShared.Program_);     FShared.Program_     := 0; end;
  if FShared.BaseMeshVBO  <> 0 then begin AccDeleteBuffers(1, @FShared.BaseMeshVBO); FShared.BaseMeshVBO := 0; end;
  if FShared.BaseMeshEBO  <> 0 then begin AccDeleteBuffers(1, @FShared.BaseMeshEBO); FShared.BaseMeshEBO := 0; end;
  if FTextureArray        <> 0 then begin AccDeleteTextures(1, @FTextureArray);     FTextureArray       := 0; end;
  if FVolumeNormalTex     <> 0 then begin AccDeleteTextures(1, @FVolumeNormalTex);  FVolumeNormalTex    := 0; end;
  if FShared.DetailMeshVBO<>0 then begin AccDeleteBuffers(1,@FShared.DetailMeshVBO);FShared.DetailMeshVBO:=0;end;
  if FShared.DetailMeshEBO<>0 then begin AccDeleteBuffers(1,@FShared.DetailMeshEBO);FShared.DetailMeshEBO:=0;end;
  if FShared.BranchTexture<>0 then begin AccDeleteTextures(1,@FShared.BranchTexture);FShared.BranchTexture:=0;end;
  FShared.Initialized    := False;
  FShared.TexturesLoaded := False;
end;

function TCastleAbstractTreeRenderer.SharedResPtr: PInstancedSharedResources;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(693);{$ENDIF} Result := @FShared; end;

procedure TCastleAbstractTreeRenderer.EnsureSharedGL;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(694);{$ENDIF} DoEnsureSharedGL; end;

procedure TCastleAbstractTreeRenderer.BindShaderTextures;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(695);{$ENDIF}
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D_ARRAY, FTextureArray);
  glUniform1i(FUniTextureArray, 0);

  if FVolumeNormalTex <> 0 then
  begin
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, FVolumeNormalTex);
    glUniform1i(FUniVolumeNormal, 1);
  end;
end;

procedure TCastleAbstractTreeRenderer.UnbindShaderTextures;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1621);{$ENDIF}
  if FVolumeNormalTex <> 0 then
  begin
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, 0);
  end;
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D_ARRAY, 0);
end;

function TCastleAbstractTreeRenderer.HasSharedTextures: Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(696);{$ENDIF}
  Result := FVolumeNormalTex <> 0;
end;

function TCastleAbstractTreeRenderer.GetMeshDataPtr: Pointer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(697);{$ENDIF} Result := @TREE_MESH_DATA[0]; end;

function TCastleAbstractTreeRenderer.GetMeshDataSize: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(698);{$ENDIF} Result := SizeOf(TREE_MESH_DATA); end;

function TCastleAbstractTreeRenderer.GetMeshIndicesPtr: Pointer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(699);{$ENDIF} Result := @TREE_MESH_INDICES[0]; end;

function TCastleAbstractTreeRenderer.GetMeshIndexCount: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(700);{$ENDIF} Result := TREE_MESH_INDEX_COUNT; end;

function TCastleAbstractTreeRenderer.GetVertSource: AnsiString;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(701);{$ENDIF} Result := TREE_VERT_SOURCE; end;

function TCastleAbstractTreeRenderer.GetFragSource: AnsiString;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(702);{$ENDIF} Result := TREE_FRAG_SOURCE; end;

function TCastleAbstractTreeRenderer.GetShaderTag: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(703);{$ENDIF} Result := 'Tree'; end;

procedure TCastleAbstractTreeRenderer.SetupInstanceAttribs(const ByteOffset:PtrUInt);
{ Locations 3..6: pos (vec3), scale, rot, seed (floats).
  The instance VBO is already bound by InitTileGL. }
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(704);{$ENDIF}
  EnableInstanceAttrib(3, 3, ByteOffset+TREE_INST_OFFSET_POSITION, TREE_INSTANCE_STRIDE);
  EnableInstanceAttrib(4, 1, ByteOffset+TREE_INST_OFFSET_SCALE,    TREE_INSTANCE_STRIDE);
  EnableInstanceAttrib(5, 1, ByteOffset+TREE_INST_OFFSET_ROTATION, TREE_INSTANCE_STRIDE);
  EnableInstanceAttrib(6, 1, ByteOffset+TREE_INST_OFFSET_SEED,     TREE_INSTANCE_STRIDE);
end;

function TCastleAbstractTreeRenderer.GetProfilerName: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(705);{$ENDIF} Result := 'trees'; end;

procedure TCastleAbstractTreeRenderer.GetLODBases(out NearBase, FarBase: Single);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(684);{$ENDIF}
  { NearBase selects one camera-facing card instead of two crossed cards.
    FarBase is the exact world-XZ instance range, without height scaling. }
  NearBase := GlobalLODConfig.TreesNearMeters;
  FarBase  := FCullDistance;
end;

procedure TCastleAbstractTreeRenderer.RecomputeTileBoundingBox(
  var Tile: TInstancedTile);
{ A tree of height H = Scale occupies an H×H×H cube above instance Y. }
var
  I: Integer;
  Inst: TTreeInstance;
  PMin, PMax: TVector3;
  S: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(706);{$ENDIF}
  if Tile.InstanceCount = 0 then
  begin
    Tile.LocalBox := TBox3D.Empty;
    Exit;
  end;

  Inst := Tile.Instances[0];
  S := Inst.Scale;
  PMin := Vector3(Inst.X - S, Inst.Y - 0.02*S, Inst.Z - S);
  PMax := Vector3(Inst.X + S, Inst.Y + 1.06*S, Inst.Z + S);

  for I := 1 to Tile.InstanceCount - 1 do
  begin
    Inst := Tile.Instances[I];
    S := Inst.Scale;
    if Inst.X - S < PMin.X then PMin.X := Inst.X - S;
    if Inst.Z - S < PMin.Z then PMin.Z := Inst.Z - S;
    if Inst.Y - 0.02*S < PMin.Y then PMin.Y := Inst.Y - 0.02*S;
    if Inst.X + S > PMax.X then PMax.X := Inst.X + S;
    if Inst.Z + S > PMax.Z then PMax.Z := Inst.Z + S;
    if Inst.Y + 1.06*S > PMax.Y then PMax.Y := Inst.Y + 1.06*S;
  end;

  Tile.LocalBox := Box3D(PMin, PMax);
end;

const
  SHRUB_MESH_VERT_COUNT  = 108;
  SHRUB_MESH_INDEX_COUNT = 120;
  SHRUB_VERT_STRIDE_FLOATS = 8;

  SHRUB_MESH_DATA: array[0..SHRUB_MESH_VERT_COUNT * SHRUB_VERT_STRIDE_FLOATS - 1] of GLfloat = (

  -2.5000,-0.8314, 0.0000,  0.0000,-0.0000, 1.0000,  0.5047, 0.4941,
   2.5000,-0.8314,-0.0000,  0.0000,-0.0000, 1.0000,  0.9970, 0.4941,
  -2.5000, 1.7325, 0.0000,  0.0000,-0.0000, 1.0000,  0.5047, 0.1497,
   2.5000, 1.7325,-0.0000,  0.0000,-0.0000, 1.0000,  0.9970, 0.1497,
  -2.5000,-0.8314, 0.0000, -0.0000, 0.0000,-1.0000,  0.5047, 0.4941,
   2.5000,-0.8314,-0.0000, -0.0000, 0.0000,-1.0000,  0.9970, 0.4941,
  -2.5000, 1.7325, 0.0000, -0.0000, 0.0000,-1.0000,  0.5047, 0.1497,
   2.5000, 1.7325,-0.0000, -0.0000, 0.0000,-1.0000,  0.9970, 0.1497,
  -0.0000,-0.8314,-2.5000, -1.0000,-0.0000, 0.0000,  0.5047, 0.4941,
  -0.0000,-0.8314,-2.5000, -1.0000,-0.0000, 0.0000,  0.5047, 0.4941,
   0.0000,-0.8314, 2.5000, -1.0000,-0.0000, 0.0000,  0.9970, 0.4941,
  -0.0000, 1.7325,-2.5000, -1.0000,-0.0000, 0.0000,  0.5047, 0.1497,
   0.0000, 1.7325, 2.5000, -1.0000,-0.0000, 0.0000,  0.9970, 0.1497,
   0.0000, 1.7325, 2.5000, -1.0000,-0.0000, 0.0000,  0.9970, 0.1497,
  -0.0000,-0.8314,-2.5000,  1.0000, 0.0000,-0.0000,  0.5047, 0.4941,
  -0.0000,-0.8314,-2.5000,  1.0000, 0.0000,-0.0000,  0.5047, 0.4941,
   0.0000,-0.8314, 2.5000,  1.0000, 0.0000,-0.0000,  0.9970, 0.4941,
  -0.0000, 1.7325,-2.5000,  1.0000, 0.0000,-0.0000,  0.5047, 0.1497,
   0.0000, 1.7325, 2.5000,  1.0000, 0.0000,-0.0000,  0.9970, 0.1497,
   0.0000, 1.7325, 2.5000,  1.0000, 0.0000,-0.0000,  0.9970, 0.1497,
   0.6336,-0.5568, 2.5434,  0.4196, 0.0000, 0.9077,  0.0079, 0.9834,
   0.6336,-0.5568, 2.5434,  0.4196, 0.0000, 0.9077,  0.0079, 0.9834,
   3.6735,-0.5568, 1.1384,  0.4196, 0.0000, 0.9077,  0.5009, 0.9834,
   0.6336, 1.1604, 2.5434,  0.4196, 0.0000, 0.9077,  0.0079, 0.5600,
   3.6735, 1.1604, 1.1384,  0.4196, 0.0000, 0.9077,  0.5009, 0.5600,
   3.6735, 1.1604, 1.1384,  0.4196, 0.0000, 0.9077,  0.5009, 0.5600,
   0.6336,-0.5568, 2.5434, -0.4196, 0.0000,-0.9077,  0.0079, 0.9834,
   0.6336,-0.5568, 2.5434, -0.4196, 0.0000,-0.9077,  0.0079, 0.9834,
   3.6735,-0.5568, 1.1384, -0.4196, 0.0000,-0.9077,  0.5009, 0.9834,
   0.6336, 1.1604, 2.5434, -0.4196, 0.0000,-0.9077,  0.0079, 0.5600,
   3.6735, 1.1604, 1.1384, -0.4196, 0.0000,-0.9077,  0.5009, 0.5600,
   3.6735, 1.1604, 1.1384, -0.4196, 0.0000,-0.9077,  0.5009, 0.5600,
   1.4510,-0.5568, 0.3209, -0.9077,-0.0000, 0.4196,  0.0079, 0.9834,
   1.4510,-0.5568, 0.3209, -0.9077, 0.0000, 0.4196,  0.0079, 0.9834,
   2.8561,-0.5568, 3.3608, -0.9077, 0.0000, 0.4196,  0.5009, 0.9834,
   1.4510, 1.1604, 0.3209, -0.9077,-0.0000, 0.4196,  0.0079, 0.5600,
   2.8561, 1.1604, 3.3608, -0.9077,-0.0000, 0.4196,  0.5009, 0.5600,
   2.8561, 1.1604, 3.3608, -0.9077, 0.0000, 0.4196,  0.5009, 0.5600,
   1.4510,-0.5568, 0.3209,  0.9077, 0.0000,-0.4196,  0.0079, 0.9834,
   1.4510,-0.5568, 0.3209,  0.9077, 0.0000,-0.4196,  0.0079, 0.9834,
   2.8561,-0.5568, 3.3608,  0.9077, 0.0000,-0.4196,  0.5009, 0.9834,
   1.4510, 1.1604, 0.3209,  0.9077, 0.0000,-0.4196,  0.0079, 0.5600,
   2.8561, 1.1604, 3.3608,  0.9077, 0.0000,-0.4196,  0.5009, 0.5600,
   2.8561, 1.1604, 3.3608,  0.9077, 0.0000,-0.4196,  0.5009, 0.5600,
   1.1113,-0.7543,-0.7173,  0.6689, 0.0000, 0.7433,  0.0050, 0.4850,
   3.6007,-0.7543,-2.9574,  0.6689, 0.0000, 0.7433,  0.5021, 0.4850,
   1.1113, 1.5134,-0.7173,  0.6689, 0.0000, 0.7433,  0.0050, 0.0081,
   3.6007, 1.5134,-2.9574,  0.6689, 0.0000, 0.7433,  0.5021, 0.0081,
   1.1113,-0.7543,-0.7173, -0.6689, 0.0000,-0.7433,  0.0050, 0.4850,
   3.6007,-0.7543,-2.9574, -0.6689, 0.0000,-0.7433,  0.5021, 0.4850,
   1.1113, 1.5134,-0.7173, -0.6689, 0.0000,-0.7433,  0.0050, 0.0081,
   3.6007, 1.5134,-2.9574, -0.6689, 0.0000,-0.7433,  0.5021, 0.0081,
   1.2359,-0.7543,-3.0821, -0.7433, 0.0000, 0.6689,  0.0050, 0.4850,
   3.4761,-0.7543,-0.5927, -0.7433, 0.0000, 0.6689,  0.5021, 0.4850,
   1.2359, 1.5134,-3.0821, -0.7433, 0.0000, 0.6689,  0.0050, 0.0081,
   3.4761, 1.5134,-0.5927, -0.7433, 0.0000, 0.6689,  0.5021, 0.0081,
   1.2359,-0.7543,-3.0821,  0.7433, 0.0000,-0.6689,  0.0050, 0.4850,
   3.4761,-0.7543,-0.5927,  0.7433, 0.0000,-0.6689,  0.5021, 0.4850,
   1.2359, 1.5134,-3.0821,  0.7433, 0.0000,-0.6689,  0.0050, 0.0081,
   3.4761, 1.5134,-0.5927,  0.7433, 0.0000,-0.6689,  0.5021, 0.0081,
  -3.5645,-0.5612, 0.3773,  0.8863, 0.0000, 0.4631,  0.5077, 0.4886,
  -3.5645,-0.5612, 0.3773,  0.8863, 0.0000, 0.4631,  0.5077, 0.4886,
  -2.0136,-0.5612,-2.5908,  0.8863, 0.0000, 0.4631,  0.9955, 0.4886,
  -3.5645, 1.2431, 0.3773,  0.8863, 0.0000, 0.4631,  0.5077, 0.1509,
  -2.0136, 1.2431,-2.5908,  0.8863, 0.0000, 0.4631,  0.9955, 0.1509,
  -2.0136, 1.2431,-2.5908,  0.8863, 0.0000, 0.4631,  0.9955, 0.1509,
  -3.5645,-0.5612, 0.3773, -0.8863, 0.0000,-0.4631,  0.5077, 0.4886,
  -3.5645,-0.5612, 0.3773, -0.8863, 0.0000,-0.4631,  0.5077, 0.4886,
  -2.0136,-0.5612,-2.5908, -0.8863, 0.0000,-0.4631,  0.9955, 0.4886,
  -3.5645, 1.2431, 0.3773, -0.8863, 0.0000,-0.4631,  0.5077, 0.1509,
  -2.0136, 1.2431,-2.5908, -0.8863, 0.0000,-0.4631,  0.9955, 0.1509,
  -2.0136, 1.2431,-2.5908, -0.8863, 0.0000,-0.4631,  0.9955, 0.1509,
  -4.2731,-0.5612,-1.8822, -0.4631, 0.0000, 0.8863,  0.5077, 0.4886,
  -4.2731,-0.5612,-1.8822, -0.4631, 0.0000, 0.8863,  0.5077, 0.4886,
  -1.3050,-0.5612,-0.3313, -0.4631, 0.0000, 0.8863,  0.9955, 0.4886,
  -4.2731, 1.2431,-1.8822, -0.4631, 0.0000, 0.8863,  0.5077, 0.1509,
  -1.3050, 1.2431,-0.3313, -0.4631, 0.0000, 0.8863,  0.9955, 0.1509,
  -1.3050, 1.2431,-0.3313, -0.4631, 0.0000, 0.8863,  0.9955, 0.1509,
  -4.2731,-0.5612,-1.8822,  0.4631, 0.0000,-0.8863,  0.5077, 0.4886,
  -4.2731,-0.5612,-1.8822,  0.4631, 0.0000,-0.8863,  0.5077, 0.4886,
  -1.3050,-0.5612,-0.3313,  0.4631, 0.0000,-0.8863,  0.9955, 0.4886,
  -4.2731, 1.2431,-1.8822,  0.4631, 0.0000,-0.8863,  0.5077, 0.1509,
  -1.3050, 1.2431,-0.3313,  0.4631, 0.0000,-0.8863,  0.9955, 0.1509,
  -1.3050, 1.2431,-0.3313,  0.4631, 0.0000,-0.8863,  0.9955, 0.1509,
  -2.2825,-0.9585, 3.8921,  0.8863, 0.0000, 0.4631,  0.5014, 0.9900,
  -2.2825,-0.9585, 3.8921,  0.8863, 0.0000, 0.4631,  0.5014, 0.9900,
  -0.7316,-0.9585, 0.9240,  0.8863, 0.0000, 0.4631,  0.9971, 0.9900,
  -2.2825, 2.0712, 3.8921,  0.8863, 0.0000, 0.4631,  0.5014, 0.6336,
  -0.7316, 2.0712, 0.9240,  0.8863, 0.0000, 0.4631,  0.9971, 0.6336,
  -0.7316, 2.0712, 0.9240,  0.8863, 0.0000, 0.4631,  0.9971, 0.6336,
  -2.2825,-0.9585, 3.8921, -0.8863, 0.0000,-0.4631,  0.5014, 0.9900,
  -2.2825,-0.9585, 3.8921, -0.8863,-0.0000,-0.4631,  0.5014, 0.9900,
  -0.7316,-0.9585, 0.9240, -0.8863,-0.0000,-0.4631,  0.9971, 0.9900,
  -2.2825, 2.0712, 3.8921, -0.8863, 0.0000,-0.4631,  0.5014, 0.6336,
  -0.7316, 2.0712, 0.9240, -0.8863, 0.0000,-0.4631,  0.9971, 0.6336,
  -0.7316, 2.0712, 0.9240, -0.8863,-0.0000,-0.4631,  0.9971, 0.6336,
  -2.9911,-0.9585, 1.6326, -0.4631, 0.0000, 0.8863,  0.5014, 0.9900,
  -2.9911,-0.9585, 1.6326, -0.4631, 0.0000, 0.8863,  0.5014, 0.9900,
  -0.0230,-0.9585, 3.1835, -0.4631, 0.0000, 0.8863,  0.9971, 0.9900,
  -2.9911, 2.0712, 1.6326, -0.4631, 0.0000, 0.8863,  0.5014, 0.6336,
  -0.0230, 2.0712, 3.1835, -0.4631, 0.0000, 0.8863,  0.9971, 0.6336,
  -0.0230, 2.0712, 3.1835, -0.4631, 0.0000, 0.8863,  0.9971, 0.6336,
  -2.9911,-0.9585, 1.6326,  0.4631, 0.0000,-0.8863,  0.5014, 0.9900,
  -2.9911,-0.9585, 1.6326,  0.4631, 0.0000,-0.8863,  0.5014, 0.9900,
  -0.0230,-0.9585, 3.1835,  0.4631, 0.0000,-0.8863,  0.9971, 0.9900,
  -2.9911, 2.0712, 1.6326,  0.4631, 0.0000,-0.8863,  0.5014, 0.6336,
  -0.0230, 2.0712, 3.1835,  0.4631, 0.0000,-0.8863,  0.9971, 0.6336,
  -0.0230, 2.0712, 3.1835,  0.4631, 0.0000,-0.8863,  0.9971, 0.6336
  );

  SHRUB_MESH_INDICES: array[0..SHRUB_MESH_INDEX_COUNT - 1] of GLushort = (
      0,   1,   3,   0,   3,   2,   4,   7,   5,   4,   6,   7,
      8,  10,  12,   9,  13,  11,  15,  19,  16,  14,  17,  18,
     20,  22,  24,  21,  25,  23,  27,  31,  28,  26,  29,  30,
     33,  34,  37,  32,  36,  35,  38,  42,  40,  39,  41,  43,
     44,  45,  47,  44,  47,  46,  48,  51,  49,  48,  50,  51,
     52,  53,  55,  52,  55,  54,  56,  59,  57,  56,  58,  59,
     61,  62,  65,  60,  64,  63,  66,  70,  68,  67,  69,  71,
     72,  74,  76,  73,  77,  75,  79,  83,  80,  78,  81,  82,
     84,  86,  88,  85,  89,  87,  91,  95,  92,  90,  93,  94,
     97,  98, 101,  96, 100,  99, 102, 106, 104, 103, 105, 107
  );

{ Shrubs share the world-XZ instance cutoff; the height-scaled near-LOD
  normal-map drop remains independent of this far range. }
const
  SHRUB_VERT_SOURCE: AnsiString =
'#version 330 core' + LineEnding +
LineEnding +
'layout(location = 0) in vec3 position;' + LineEnding +
'layout(location = 1) in vec3 normal;' + LineEnding +
'layout(location = 2) in vec2 uv;' + LineEnding +
'layout(location = 3) in vec3 instancePosition;' + LineEnding +
'layout(location = 4) in float instanceScale;' + LineEnding +
'layout(location = 5) in float instanceRotation;' + LineEnding +
LineEnding +
'uniform mat4 projectionMatrix;' + LineEnding +
'uniform mat4 viewMatrix;' + LineEnding +
'uniform mat4 modelMatrix;' + LineEnding +
'uniform vec3 cameraWorldPos;' + LineEnding +
'uniform float lodNearBase;     // ShrubsNearMeters' + LineEnding +
'uniform float lodFarBase;      // world XZ range; 0 disables (shadow pass)' + LineEnding +
'uniform float lodHeightRef;    // HeightScaleRef' + LineEnding +
'uniform float lodGroundRefY;   // ground-level Y at route start' + LineEnding +
LineEnding +
'out vec2  vUv;' + LineEnding +
'out vec3  vNormalWorld;' + LineEnding +
'flat out int vUseNormalMap;   // 1 = sample normal, 0 = skip (cheap LOD)' + LineEnding +
'flat out vec2 vWorldXZ;       // instance origin XZ — per-shrub wind phase' + LineEnding +
'out float    vLeanW;          // 0 at card base, 1 at top — wind-lean weight' + LineEnding +
LineEnding +
'mat2 rotate2d(float a) {' + LineEnding +
'    return mat2(cos(a), -sin(a), sin(a), cos(a));' + LineEnding +
'}' + LineEnding +
LineEnding +
WIND_GLSL + BRANCH_VERTEX_GLSL +
'void main() {' + LineEnding +
'    vUv = uv;' + LineEnding +
'    vUseNormalMap = 0;' + LineEnding +
LineEnding +
'    // Near-LOD: drop normal-map sampling past ShrubsNearMeters.' + LineEnding +
'    float camAboveGround = max(0.0, cameraWorldPos.y - lodGroundRefY);' + LineEnding +
'    float hScale   = 1.0 + camAboveGround / lodHeightRef;' + LineEnding +
'    float nearDist = lodNearBase * hScale;' + LineEnding +
'    vec3  instWorld = (modelMatrix * vec4(instancePosition, 1.0)).xyz;' + LineEnding +
'    vec2 farDelta = instWorld.xz - cameraWorldPos.xz;' + LineEnding +
'    if (lodFarBase > 0.0 && dot(farDelta,farDelta) > lodFarBase*lodFarBase) { gl_Position=vec4(2.0,2.0,2.0,1.0); vNormalWorld=vec3(0,1,0); vWorldXZ=instWorld.xz; vLeanW=0.0; return; }' + LineEnding +
'    if (!branchPassVisible(instWorld)) { gl_Position=vec4(2.0,2.0,2.0,1.0); vNormalWorld=vec3(0,1,0); vWorldXZ=instWorld.xz; vLeanW=0.0; return; }' + LineEnding +
'    float dist = length(instWorld - cameraWorldPos);' + LineEnding +
'    if (dist < nearDist) vUseNormalMap = 1;' + LineEnding +
'    vWorldXZ = instWorld.xz;        // per-shrub wind phase (like trees)' + LineEnding +
'    // Wind-lean weight: 0 at card base, 1 at top. Range = SHRUB_MESH_DATA' + LineEnding +
'    // local Y extent [-0.9585 .. 2.0712] (span 3.0297).' + LineEnding +
'    vLeanW = clamp((position.y + 0.9585) / 3.0297, 0.0, 1.0);' + LineEnding +
LineEnding +
'    mat2 R = rotate2d(instanceRotation);' + LineEnding +
LineEnding +
'    vec3 p=position, n=normal;' + LineEnding +
'    vec2 pivot=branchPatch.xy;' + LineEnding +
BRANCH_VERTEX_TAIL;

  SHRUB_FRAG_SOURCE: AnsiString =
'#version 330 core' + LineEnding +
LineEnding +
'in vec2  vUv;' + LineEnding +
'in vec3  vNormalWorld;' + LineEnding +
'flat in int vUseNormalMap;' + LineEnding +
'flat in vec2 vWorldXZ;' + LineEnding +
'in float    vLeanW;' + LineEnding +
LineEnding +
'uniform sampler2D tDiffuse;' + LineEnding +
'uniform sampler2D tNormal;' + LineEnding +
'uniform int       uHasNormal;' + LineEnding +
'uniform vec3  lightDir;' + LineEnding +
'uniform int depthOnly;' + LineEnding +
BRANCH_FRAGMENT_GLSL +
WIND_GLSL +
LineEnding +
'out vec4 fragColor;' + LineEnding +
LineEnding +
'// Same constants/colourspace/tonemap as the ground composite shader' + LineEnding +
'// (Osm3dGroundComposite) so shrubs and terrain share one exposure.' + LineEnding +
'const vec3  SUN_COLOR      = vec3(1.000, 0.970, 0.920);' + LineEnding +
'const float SUN_INTENSITY  = 8.0;' + LineEnding +
'const float AMBIENT_FACTOR = 0.45;' + LineEnding +
'const float VEG_EXPOSURE   = 0.4;   // canopy brightness knob; <1 darker, 1.0 = match ground' + LineEnding +
'const float PI             = 3.14159265;' + LineEnding +
'// Wind UV knobs — same as the tree canopy.' + LineEnding +
'const float RUSTLE_UV     = 0.008;  // UV "boil" amplitude' + LineEnding +
'const float RUSTLE_FREQ   = 9.0;    // boil spatial frequency' + LineEnding +
'const float LEAN_STRENGTH = 0.08;   // lean toward wind (uv.x shift) * strength' + LineEnding +
'float n2(vec2 p) { return 0.5*sin(p.x*1.7 + p.y*2.3) + 0.5*sin(p.x*3.1 - p.y*1.3); }' + LineEnding +
'vec3 srgbToLin(vec3 c) { return pow(c, vec3(2.2)); }' + LineEnding +
'vec3 linToSrgb(vec3 c) { return pow(c, vec3(1.0/2.2)); }' + LineEnding +
LineEnding +
'void main() {' + LineEnding +
'    if(!branchPixelVisible()) discard;' + LineEnding +
'    // ---- wind, same UV mechanism as the tree canopy ----' + LineEnding +
'    float t  = uWindTime;' + LineEnding +
'    float resp = vWindResponse;' + LineEnding +
'    vec2  ph = vWorldXZ * 0.35;' + LineEnding +
'    // Card frame: Tt is the world direction of increasing uv.x (card width).' + LineEnding +
'    vec3 Nf = normalize(vNormalWorld);' + LineEnding +
'    vec3 Tt = cross(vec3(0.0, 1.0, 0.0), Nf);' + LineEnding +
'    Tt = (length(Tt) > 1e-4) ? normalize(Tt) : vec3(1.0, 0.0, 0.0);' + LineEnding +
'    // boil (leaf flutter), faded with distance so far shrubs do not fizz' + LineEnding +
'    vec2 flow = vec2(n2(vUv*RUSTLE_FREQ + ph + vec2( t*1.7,  t*1.1)),' + LineEnding +
'                     n2(vUv*RUSTLE_FREQ + ph + vec2(-t*1.3,  t*1.9)));' + LineEnding +
'    vec2 boil = flow * RUSTLE_UV * vLeanW * resp;  // amplitude tracks wind response' + LineEnding +
'    boil *= 1.0 - smoothstep(0.01, 0.06, max(fwidth(vUv.x), fwidth(vUv.y)));' + LineEnding +
'    // directional lean toward the wind, strongest at the top (vLeanW),' + LineEnding +
'    // scaled by wind strength. (Flip the sign if it leans the wrong way.)' + LineEnding +
'    vec3  windDir3 = vec3(uWindDir.x, 0.0, uWindDir.y);' + LineEnding +
'    float alongU   = dot(windDir3, Tt);' + LineEnding +
'    vec2  lean     = vec2(-alongU * resp * LEAN_STRENGTH * vLeanW, 0.0);' + LineEnding +
LineEnding +
'    vec2 uv = vec2(vUv.x, 1.0 - vUv.y) + boil + lean;' + LineEnding +
LineEnding +
'    if(!branchLayerVisible(uv,0)) discard;' + LineEnding +
'    vec4 c=texture(tDiffuse,uv);' + LineEnding +
'    if (c.a < 0.5) discard;' + LineEnding +
'    if (depthOnly != 0) { fragColor = vec4(1.0); return; }' + LineEnding +
LineEnding +
'    vec3 N = Nf;' + LineEnding +
'    if (uHasNormal == 1 && vUseNormalMap == 1) {' + LineEnding +
'        vec3 nm = texture(tNormal, uv).rgb * 2.0 - 1.0;' + LineEnding +
'        N = normalize(N + 0.5 * nm);' + LineEnding +
'    }' + LineEnding +
'    vec3 albedoLin = srgbToLin(c.rgb);' + LineEnding +
'    // Crossed billboard cards are lit from both faces (abs), no black backs.' + LineEnding +
'    float NdotL = abs(dot(N, normalize(-lightDir)));' + LineEnding +
'    vec3 colorLin = albedoLin * (SUN_COLOR * (SUN_INTENSITY / PI) * NdotL' + LineEnding +
'                               + vec3(AMBIENT_FACTOR));' + LineEnding +
'    colorLin *= VEG_EXPOSURE;' + LineEnding +
'    vec3 colorTM = colorLin / (colorLin + vec3(1.0));   // Reinhard' + LineEnding +
'    fragColor = vec4(linToSrgb(colorTM), 1.0);' + LineEnding +
'}' + LineEnding;

class procedure TCastleAbstractShrubRenderer.DoEnsureSharedGL;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1233);{$ENDIF}
  if FShared.Initialized then Exit;

  UploadBaseMeshBuffers(FShared,
    @SHRUB_MESH_DATA[0], SizeOf(SHRUB_MESH_DATA),
    @SHRUB_MESH_INDICES[0], SizeOf(SHRUB_MESH_INDICES));

  UploadDetailMesh(FShared,SHRUB_MESH_DATA,SHRUB_MESH_INDICES,False);

  CompileLinkProgram(FShared, SHRUB_VERT_SOURCE, SHRUB_FRAG_SOURCE, 'Shrub');

  CacheCommonUniforms(FShared);
  FShared.UniCameraWorldPos := glGetUniformLocation(FShared.Program_, 'cameraWorldPos');
  FShared.UniLodNearBase    := glGetUniformLocation(FShared.Program_, 'lodNearBase');
  FShared.UniLodFarBase     := glGetUniformLocation(FShared.Program_, 'lodFarBase');
  FShared.UniLodHeightRef   := glGetUniformLocation(FShared.Program_, 'lodHeightRef');
  FShared.UniLodGroundRefY  := glGetUniformLocation(FShared.Program_, 'lodGroundRefY');

  { Shrubs now include WIND_GLSL (same canopy wind as trees). }
  FShared.Wind := WindCacheUniforms(FShared.Program_);

  FUniDiffuse   := glGetUniformLocation(FShared.Program_, 'tDiffuse');
  FUniNormal    := glGetUniformLocation(FShared.Program_, 'tNormal');
  FUniHasNormal := glGetUniformLocation(FShared.Program_, 'uHasNormal');

  FShared.Initialized := True;
end;

class procedure TCastleAbstractShrubRenderer.LoadSharedTextures(
  const TexturesDir: string);
var
  Dir, NormalPath: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1234);{$ENDIF}
  DoEnsureSharedGL;

  Dir := IncludeTrailingPathDelimiter(TexturesDir);

  if FDiffuseTex <> 0 then
  begin
    ProfilerLog(Format('TEX shrubs: deleting old diffuse handle=%d',
      [FDiffuseTex]));
    AccDeleteTextures(1, @FDiffuseTex);
  end;
  FDiffuseTex := UploadPngToTexture2D(Dir + 'diffuse.png',
    GL_CLAMP_TO_EDGE, GL_CLAMP_TO_EDGE);

  LoadBranchTextures(FShared,Dir,['shrubbery'],VEGETATION_SHRUB_LAYERS);

  NormalPath := Dir + 'normal.png';
  if FileExists(NormalPath) then
  begin
    if FNormalTex <> 0 then
    begin
      ProfilerLog(Format('TEX shrubs: deleting old normal handle=%d',
        [FNormalTex]));
      AccDeleteTextures(1, @FNormalTex);
    end;
    FNormalTex := UploadPngToTexture2D(NormalPath,
      GL_CLAMP_TO_EDGE, GL_CLAMP_TO_EDGE);
  end;

  FShared.TexturesLoaded := True;
  ProfilerLog(Format('TEX shrubs: shared textures LOADED — diffuse=%d normal=%d',
    [FDiffuseTex, FNormalTex]));
end;

class function TCastleAbstractShrubRenderer.AreSharedTexturesLoaded: Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1235);{$ENDIF}
  Result := FShared.TexturesLoaded;
end;

class procedure TCastleAbstractShrubRenderer.CleanupSharedGL;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1236);{$ENDIF}
  ProfilerLog(Format('TEX shrubs: CleanupSharedGL — DELETING shared GL '
    + '(program=%d diffuse=%d normal=%d)',
    [FShared.Program_, FDiffuseTex, FNormalTex]));
  if FShared.Program_    <> 0 then begin glDeleteProgram(FShared.Program_);     FShared.Program_    := 0; end;
  if FShared.BaseMeshVBO <> 0 then begin AccDeleteBuffers(1, @FShared.BaseMeshVBO); FShared.BaseMeshVBO := 0; end;
  if FShared.BaseMeshEBO <> 0 then begin AccDeleteBuffers(1, @FShared.BaseMeshEBO); FShared.BaseMeshEBO := 0; end;
  if FDiffuseTex         <> 0 then begin AccDeleteTextures(1, @FDiffuseTex);     FDiffuseTex         := 0; end;
  if FNormalTex          <> 0 then begin AccDeleteTextures(1, @FNormalTex);      FNormalTex          := 0; end;
  if FShared.DetailMeshVBO<>0 then begin AccDeleteBuffers(1,@FShared.DetailMeshVBO);FShared.DetailMeshVBO:=0;end;
  if FShared.DetailMeshEBO<>0 then begin AccDeleteBuffers(1,@FShared.DetailMeshEBO);FShared.DetailMeshEBO:=0;end;
  if FShared.BranchTexture<>0 then begin AccDeleteTextures(1,@FShared.BranchTexture);FShared.BranchTexture:=0;end;
  FShared.Initialized    := False;
  FShared.TexturesLoaded := False;
end;

function TCastleAbstractShrubRenderer.SharedResPtr: PInstancedSharedResources;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(707);{$ENDIF} Result := @FShared; end;

procedure TCastleAbstractShrubRenderer.EnsureSharedGL;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(708);{$ENDIF} DoEnsureSharedGL; end;

procedure TCastleAbstractShrubRenderer.BindShaderTextures;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(709);{$ENDIF}
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, FDiffuseTex);
  glUniform1i(FUniDiffuse, 0);

  if FNormalTex <> 0 then
  begin
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, FNormalTex);
    glUniform1i(FUniNormal, 1);
    glUniform1i(FUniHasNormal, 1);
  end
  else
    glUniform1i(FUniHasNormal, 0);
end;

procedure TCastleAbstractShrubRenderer.UnbindShaderTextures;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1622);{$ENDIF}
  if FNormalTex <> 0 then
  begin
    glActiveTexture(GL_TEXTURE1);
    glBindTexture(GL_TEXTURE_2D, 0);
  end;
  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, 0);
end;

function TCastleAbstractShrubRenderer.HasSharedTextures: Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(710);{$ENDIF} Result := FDiffuseTex <> 0; end;

function TCastleAbstractShrubRenderer.GetMeshDataPtr: Pointer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(711);{$ENDIF} Result := @SHRUB_MESH_DATA[0]; end;

function TCastleAbstractShrubRenderer.GetMeshDataSize: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(712);{$ENDIF} Result := SizeOf(SHRUB_MESH_DATA); end;

function TCastleAbstractShrubRenderer.GetMeshIndicesPtr: Pointer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(713);{$ENDIF} Result := @SHRUB_MESH_INDICES[0]; end;

function TCastleAbstractShrubRenderer.GetMeshIndexCount: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(714);{$ENDIF} Result := SHRUB_MESH_INDEX_COUNT; end;

function TCastleAbstractShrubRenderer.GetVertSource: AnsiString;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(715);{$ENDIF} Result := SHRUB_VERT_SOURCE; end;

function TCastleAbstractShrubRenderer.GetFragSource: AnsiString;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(716);{$ENDIF} Result := SHRUB_FRAG_SOURCE; end;

function TCastleAbstractShrubRenderer.GetShaderTag: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(717);{$ENDIF} Result := 'Shrub'; end;

procedure TCastleAbstractShrubRenderer.SetupInstanceAttribs(const ByteOffset:PtrUInt);
{ Locations 3..5: pos, scale, rot. No seed (shrubs share one mesh + atlas). }
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(718);{$ENDIF}
  EnableInstanceAttrib(3, 3, ByteOffset+TREE_INST_OFFSET_POSITION, TREE_INSTANCE_STRIDE);
  EnableInstanceAttrib(4, 1, ByteOffset+TREE_INST_OFFSET_SCALE,    TREE_INSTANCE_STRIDE);
  EnableInstanceAttrib(5, 1, ByteOffset+TREE_INST_OFFSET_ROTATION, TREE_INSTANCE_STRIDE);
end;

function TCastleAbstractShrubRenderer.GetProfilerName: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(719);{$ENDIF} Result := 'shrubs'; end;

procedure TCastleAbstractShrubRenderer.GetLODBases(out NearBase, FarBase: Single);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(720);{$ENDIF}
  { Only the near normal-map drop is height-scaled in the shader. }
  NearBase := GlobalLODConfig.ShrubsNearMeters;
  FarBase  := FCullDistance;
end;

procedure TCastleAbstractShrubRenderer.RecomputeTileBoundingBox(
  var Tile: TInstancedTile);
const
  MESH_RADIUS_XZ = 6.0; { Includes near branches turned around offset card stems. }
  MESH_HEIGHT    = 2.1;
  MESH_BELOW     = 1.0;
var
  I: Integer;
  Inst: TTreeInstance;
  PMin, PMax: TVector3;
  S: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(721);{$ENDIF}
  if Tile.InstanceCount = 0 then
  begin
    Tile.LocalBox := TBox3D.Empty;
    Exit;
  end;

  Inst := Tile.Instances[0];
  S := Inst.Scale;
  PMin := Vector3(Inst.X - MESH_RADIUS_XZ * S,
                  Inst.Y - MESH_BELOW    * S,
                  Inst.Z - MESH_RADIUS_XZ * S);
  PMax := Vector3(Inst.X + MESH_RADIUS_XZ * S,
                  Inst.Y + MESH_HEIGHT   * S,
                  Inst.Z + MESH_RADIUS_XZ * S);

  for I := 1 to Tile.InstanceCount - 1 do
  begin
    Inst := Tile.Instances[I];
    S := Inst.Scale;
    if Inst.X - MESH_RADIUS_XZ * S < PMin.X then PMin.X := Inst.X - MESH_RADIUS_XZ * S;
    if Inst.Z - MESH_RADIUS_XZ * S < PMin.Z then PMin.Z := Inst.Z - MESH_RADIUS_XZ * S;
    if Inst.Y - MESH_BELOW    * S < PMin.Y then PMin.Y := Inst.Y - MESH_BELOW    * S;
    if Inst.X + MESH_RADIUS_XZ * S > PMax.X then PMax.X := Inst.X + MESH_RADIUS_XZ * S;
    if Inst.Z + MESH_RADIUS_XZ * S > PMax.Z then PMax.Z := Inst.Z + MESH_RADIUS_XZ * S;
    if Inst.Y + MESH_HEIGHT   * S > PMax.Y then PMax.Y := Inst.Y + MESH_HEIGHT   * S;
  end;

  Tile.LocalBox := Box3D(PMin, PMax);
end;

{ Plain-procedure wrapper so the class method can be installed into
  the profiler's procedure-typed hook (a class procedure carries an
  implicit Self and isn't assignment-compatible with `procedure`). }
procedure InstancedFrameBoundaryHook;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(722);{$ENDIF}
  TInstancedBillboardRenderer.FrameBoundary;
end;

initialization
  TInstancedBillboardRenderer.ThisFrameVisited := 0;
  TInstancedBillboardRenderer.ThisFrameDrawn   := 0;
  TInstancedBillboardRenderer.LastFrameVisited := 0;
  TInstancedBillboardRenderer.LastFrameDrawn   := 0;
  GInstancedSunRayDir := DEFAULT_SUN_RAY_DIR;
  OnFrameBoundary := @InstancedFrameBoundaryHook;

finalization
  OnFrameBoundary := nil;

end.
