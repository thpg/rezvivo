unit TreeRenderer;
{$mode objfpc}{$H+}
{$ifdef ANDROID}{$define OpenGLES}{$endif}
interface
uses SysUtils, TreeMath, TreeModel, TreeLOD, TreeSeason, TreeFoliageLOD, TreeGPUData, {$ifdef OpenGLES}CastleGLES{$else}GL, GLExt{$endif};
type
  TTreeGPUItem = TreeGPUData.TTreeGPUItem;
  TTreeGPUItems = TreeGPUData.TTreeGPUItems;
  TPreparedTreeGPU = TreeGPUData.TPreparedTreeGPU;
  TTreeIndices = array of GLushort;
  TPreparedTreeLOD = record
    Species: TTreeSpecies;
    Key: string;
    Frames: TLODFrames;
    Seasonal, FruitLayer, Relight: Boolean;
    Pixels, NormalPixels: array of Byte;
  end;
  TTreeRenderEnvironment = record
    Enabled, DepthOnly, DirectBranches: Boolean;
    SunDirection, BillboardRight, FogColor: TTreeVec3;
    FogDensity, OutputGamma: Single;
    LeafFraction: Single; { foliage grouping budget; physical blade size stays fixed }
    NeedleDetail: Single; { direct branches: 0 = integrated shoots, 1 = individual needles }
    ViewportHeight, BranchSides, BranchSegments: Integer;
    ShadowPartitions, ShadowPartition: Integer; { optional temporal depth buckets }
  end;
  TTreeRenderStats = record
    DrawCalls, Triangles, Branches, Leaves, Needles, Shoots, Fruits, Proxies, FarTrees, BakedFarTrees: Integer;
    FarMinHeight, FarMaxHeight: Single;
    UploadBytes: Int64;
  end;
  TTreeRenderer = class
  private
    FProgram: GLuint;
    FLeafSprays,FBarkTextures,FBranchFineVAO,FBranchFrameVBO:GLuint;
    FPreparedFrames:Boolean;
    FPreparedFrameBytes:Int64;
    FShared: TTreeRenderer;
    FVAO, FVBO: array[0..5] of GLuint;
    FNeedleVAO: array[0..NEEDLE_DENSITY_GROUPS-1] of GLuint;
    FCardIndices,FNeedleIndices:GLuint;
    FGridIndices:array of record Slices,Segments:Integer;Buffer:GLuint;end;
    FBranchCount,FPrimaryCount,FLeafCount,FCrownCount,FForestCount,FNeedleShootCount,FNeedlesPerFascicle: Integer;
    FSourceLeafCount,FSourceShootCount:Integer;
    FFruitCount,FFruitMembers:Integer;
    FFruitRadius:Single;
    FNeedleGroups:TTreeNeedleGroups;
    FFarMinHeight,FFarMaxHeight: Single;
    FDepthCounts:TTreeDepthCounts;
    FStats: TTreeRenderStats;
    FShadowFingerprint: LongWord;
    FShadowBoundsMin, FShadowBoundsMax: TTreeVec3;
    FReady: Boolean;
    FResolvedValid: Boolean;
    FResolvedInstance: TTreeInstance;
    FResolvedProfile, FResolvedParams: TTreeParams;
    FBatchActive: Boolean;
    FUniformCache: array of record Valid:Boolean;Value:array[0..3]of Single;end;
    UComplexity,UCoverageSamples,UPreparedFrames,UFragmentWorkReuse:GLint;
    UShadowPartitions,UShadowPartition:GLint;
    FEnvironment: TTreeRenderEnvironment;
    USunDirection,UBillboardRight,UFogColor,UFogDensity,UOutputGamma,UDepthOnly,UDirectBranches,ULeafSpray,ULeafBudget,ULeafSprays,UNeedleScale: GLint;
    FLODTextures, FLODNormals: array[TTreeSpecies] of GLuint;
    FLODFrames: array[TTreeSpecies] of TLODFrames;
    FLODKeys: array[TTreeSpecies] of string;
    FBarkDefault:array[TTreeSpecies]of TTreeVec3;
    UBarkTint:GLint;
    { Profile serialization is only needed on a change, never per draw. }
    FCheckedProfiles: array[TTreeSpecies] of TTreeParams;
    FCheckedKeys: array[TTreeSpecies] of string;
    FLODSeasonParts, FLODRelight: array[TTreeSpecies] of Boolean;
    FLODFruitLayer: array[TTreeSpecies] of Boolean;
    FSeason: Single;
    FBakeOutput: Integer;
    FBakePart: Integer; { 0 complete, 1 wood, 2 foliage, 3 fruit }
    USeasonLeaf,ULeafRatio,ULODSeasonParts: GLint;
    UFruitAmount,UFruitMembers,ULODFruitLayer:GLint;
    FBakeMode,FUseBakedLOD: Boolean;
    UBakeMode,UUseBakedLOD,ULODTexture,ULODFrames,ULODNormal,ULODRelight: GLint;
    UProjection,UView,UModel,UKind,USlices,USegments,UQuality,UTime,UWind,
    UProfile,UBark,ULeaf,UEye,USpecies,UDensity,UDebug,UNeedlePairs,UNeedlesPerFascicle,UNeedleVertices,UViewportHeight,UNeedleDetail: GLint;
    procedure SetPassUniforms(const Projection,View:TTreeMat4; const Eye:TTreeVec3; Seconds:Single);
    function UniformChanged(Location:GLint;X,Y,Z,W:Single):Boolean;inline;
    procedure Uniform1i(Location:GLint;Value:Integer);inline;
    procedure Uniform1f(Location:GLint;Value:Single);inline;
    procedure Uniform3f(Location:GLint;X,Y,Z:Single);inline;
    procedure Uniform4f(Location:GLint;X,Y,Z,W:Single);inline;
    procedure Upload(Index: Integer; const Items: TTreeGPUItems);
    function UploadIndices(const Indices:TTreeIndices):GLuint;
    procedure CreateLeafSprays(const ShaderDirectory:string);
    procedure CreateBarkTextures(const ShaderDirectory:string);
    function GridIndices(Slices,Segments:Integer):GLuint;
    function CardIndices:GLuint;
    function NeedleIndices:GLuint;
    procedure Draw(Kind, BufferIndex, Vertices, Count: Integer; VertexArray: GLuint = 0; IndexBuffer:GLuint = 0);
  public
    procedure Initialize(const ShaderDirectory: string; SharedWith: TTreeRenderer = nil);
    procedure Release; { MUST be called while the owning GL context is current }
    procedure UploadTree(const Data: TTreeData);
    procedure UploadPreparedTree(const Prepared:TPreparedTreeGPU);
    { Batch by species/profile. Positions stay in Double until rebased against
      WorldOrigin, then become GPU floats. No detailed generation is performed. }
    procedure UploadDistantTrees(const Instances: array of TTreeInstance;
      const Profile: TTreeParams; const WorldOrigin: TTreeWorldPosition);
    { Identity need not share the render projection (e.g. ECEF versus a local
      map). Resolve size/seed from Instances, rebase only RenderPositions. }
    procedure UploadDistantTreesAt(const Instances: array of TTreeInstance;
      const RenderPositions: array of TTreeWorldPosition;
      const Profile: TTreeParams; const WorldOrigin: TTreeWorldPosition);
    class function PackDistantTreesAt(const Instances: array of TTreeInstance;
      const RenderPositions: array of TTreeWorldPosition;
      const Profile: TTreeParams; const WorldOrigin: TTreeWorldPosition): TTreeGPUItems; static;
    procedure UploadDistantItems(const Items: TTreeGPUItems);
    procedure UpdateDistantItems(First: Integer; const Items: TTreeGPUItems);
    procedure UploadForest(const Center: TTreeInstance; const P: TTreeParams; Count: Integer);
    function VerifyPackedType(Expected: TTreeTypeCode): Boolean; { smoke only; synchronous GPU readback }
    procedure BeginBatch(const Projection,View:TTreeMat4; const Eye:TTreeVec3;
      const Env:TTreeRenderEnvironment; Seconds:Single);
    procedure EndBatch;
    procedure Render(const Instance: TTreeInstance; const P: TTreeParams;
      const Projection,View,Model: TTreeMat4; const Eye: TTreeVec3;
      Quality,Seconds,Wind: Single; Wireframe,Debug,ShowLeaves,ShowGround,ShowForest: Boolean;
      PreserveGLState: Boolean = True);
    procedure LoadLODAtlas(const Directory: string; const Profile: TTreeParams);
    class function PrepareLODAtlas(const Directory: string;
      const Profile: TTreeParams): TPreparedTreeLOD; static;
    procedure UploadLODAtlas(const Prepared: TPreparedTreeLOD);
    function HasLODAtlas(const Profile: TTreeParams): Boolean;
    function HasSeasonLOD(const Profile: TTreeParams): Boolean;
    function LODTextureBytes: Int64;
    function ShadowLOD(const Profile: TTreeParams; out Texture: Cardinal;
      out Frames: TLODFrames; out Seasonal, Fruit: Boolean): Boolean;
    property ShadowFingerprint: LongWord read FShadowFingerprint;
    property ShadowBoundsMin: TTreeVec3 read FShadowBoundsMin;
    property ShadowBoundsMax: TTreeVec3 read FShadowBoundsMax;
    property BakeOutput:Integer read FBakeOutput write FBakeOutput;
    property BakeMode: Boolean read FBakeMode write FBakeMode;
    property UseBakedLOD: Boolean read FUseBakedLOD write FUseBakedLOD;
    property Season: Single read FSeason write FSeason;
    property BakePart: Integer read FBakePart write FBakePart;
    property Ready: Boolean read FReady;
    property Environment: TTreeRenderEnvironment read FEnvironment write FEnvironment;
    property Stats: TTreeRenderStats read FStats;
    property PreparedFrameBytes:Int64 read FPreparedFrameBytes;
  end;
var TreePassBatching:Boolean=True;
    TreeParameterCache:Boolean=True;
    { Runtime A/B switch, available only when the process starts with
      REZVIVO_TREE_PREPARED_FRAMES=1. Default snapshots allocate no frames. }
    TreePreparedFrames:Boolean=False;
    TreePreparedFrameBytes:Int64=0; { live GL buffers, already included in UploadBytes }
    TreeFragmentWorkReuse:Boolean=False;
    TreeParameterCalculations,TreeParameterReuses:QWord;
    TreeRenderComplexity:Integer=3;
    { Explicit performance isolation only: bit = shader uKind. Never changes
      generated data or atlas baking. All draw kinds enabled in normal use. }
    TreeDiagnosticDrawMask:Cardinal=$FFFFFFFF;
implementation
uses Classes, Math, TreeFruits, TreeShaderSource, TreeBark;
function TTreeRenderer.ShadowLOD(const Profile: TTreeParams; out Texture: Cardinal;
  out Frames: TLODFrames; out Seasonal, Fruit: Boolean): Boolean;
begin
  if FShared<>nil then Exit(FShared.ShadowLOD(Profile,Texture,Frames,Seasonal,Fruit));
  Texture:=FLODTextures[Profile.Species];Frames:=FLODFrames[Profile.Species];
  Seasonal:=FLODSeasonParts[Profile.Species];Fruit:=FLODFruitLayer[Profile.Species];
  Result:=(Texture<>0) and HasLODAtlas(Profile);
end;
function CompileShader(Kind: GLenum; const Source: string): GLuint;
var P: PChar; OK,Len: GLint; Log, ShaderText: string;
begin
  ShaderText:=RenderShaderSource(Source, {$ifdef OpenGLES}True{$else}False{$endif});
  Result:=glCreateShader(Kind); P:=PChar(ShaderText); glShaderSource(Result,1,@P,nil); glCompileShader(Result);
  glGetShaderiv(Result,GL_COMPILE_STATUS,@OK);
  if OK=0 then begin
    glGetShaderiv(Result,GL_INFO_LOG_LENGTH,@Len); SetLength(Log,Max(1,Len));
    glGetShaderInfoLog(Result,Len,nil,PChar(Log)); glDeleteShader(Result);
    raise Exception.Create('Tree shader compilation failed: '+Log);
  end;
end;
function ReadText(const Path: string): string;
begin Result:=ReadRenderShader(Path); end;
procedure TTreeRenderer.Initialize(const ShaderDirectory: string; SharedWith: TTreeRenderer);
var VS,FS: GLuint; OK,Len,I,J: GLint; Log: string;S:TTreeSpecies;P:TTreeParams;
begin
  if FReady then Exit;
  FShared:=SharedWith;
  if Assigned(FShared) then begin
    if not FShared.Ready or Assigned(FShared.FShared) then raise Exception.Create('Shared renderer must be a ready resource owner');
  end
  {$ifndef OpenGLES}else if not Load_GL_version_3_3_CORE then raise Exception.Create('OpenGL 3.3 is required'){$endif};
  VS:=0; FS:=0;
  try
    if Assigned(FShared) then FProgram:=FShared.FProgram else begin
    VS:=CompileShader(GL_VERTEX_SHADER,ReadText(IncludeTrailingPathDelimiter(ShaderDirectory)+'tree.vert'));
    FS:=CompileShader(GL_FRAGMENT_SHADER,ReadText(IncludeTrailingPathDelimiter(ShaderDirectory)+'tree.frag'));
    FProgram:=glCreateProgram(); glAttachShader(FProgram,VS); glAttachShader(FProgram,FS); glLinkProgram(FProgram);
    glGetProgramiv(FProgram,GL_LINK_STATUS,@OK);
    if OK=0 then begin
      glGetProgramiv(FProgram,GL_INFO_LOG_LENGTH,@Len); SetLength(Log,Max(1,Len));
      glGetProgramInfoLog(FProgram,Len,nil,PChar(Log)); raise Exception.Create('Tree shader link failed: '+Log);
    end;
    end;
    if FShared<>nil then begin
      UComplexity:=FShared.UComplexity;
      UPreparedFrames:=FShared.UPreparedFrames;
      UFragmentWorkReuse:=FShared.UFragmentWorkReuse;
      UCoverageSamples:=FShared.UCoverageSamples;
      UProjection:=FShared.UProjection;
      UView:=FShared.UView;
      UModel:=FShared.UModel;
      UKind:=FShared.UKind;
      USlices:=FShared.USlices;
      USegments:=FShared.USegments;
      UQuality:=FShared.UQuality;
      UTime:=FShared.UTime;
      UWind:=FShared.UWind;
      UProfile:=FShared.UProfile;
      UBark:=FShared.UBark;
      ULeaf:=FShared.ULeaf;
      UBarkTint:=FShared.UBarkTint;
      UEye:=FShared.UEye;
      USpecies:=FShared.USpecies;
      UDensity:=FShared.UDensity;
      UDebug:=FShared.UDebug;
      UNeedlePairs:=FShared.UNeedlePairs;
      UNeedlesPerFascicle:=FShared.UNeedlesPerFascicle;
      UNeedleVertices:=FShared.UNeedleVertices;
      UViewportHeight:=FShared.UViewportHeight;
      UBakeMode:=FShared.UBakeMode;
      UUseBakedLOD:=FShared.UUseBakedLOD;
      ULODTexture:=FShared.ULODTexture;
      ULODNormal:=FShared.ULODNormal;
      ULODRelight:=FShared.ULODRelight;
      ULODFrames:=FShared.ULODFrames;
      USeasonLeaf:=FShared.USeasonLeaf;
      ULeafRatio:=FShared.ULeafRatio;
      ULODSeasonParts:=FShared.ULODSeasonParts;
      USunDirection:=FShared.USunDirection;
      UBillboardRight:=FShared.UBillboardRight;
      UFogColor:=FShared.UFogColor;
      UFogDensity:=FShared.UFogDensity;
      UOutputGamma:=FShared.UOutputGamma;
      UDepthOnly:=FShared.UDepthOnly;
      UShadowPartitions:=FShared.UShadowPartitions;UShadowPartition:=FShared.UShadowPartition;
      UDirectBranches:=FShared.UDirectBranches;
      ULeafSpray:=FShared.ULeafSpray;
      ULeafBudget:=FShared.ULeafBudget;
      ULeafSprays:=FShared.ULeafSprays;
      UNeedleScale:=FShared.UNeedleScale;
      UNeedleDetail:=FShared.UNeedleDetail;
      UFruitAmount:=FShared.UFruitAmount;
      UFruitMembers:=FShared.UFruitMembers;
      ULODFruitLayer:=FShared.ULODFruitLayer;
      FBarkDefault:=FShared.FBarkDefault;
    end else begin
    UComplexity:=glGetUniformLocation(FProgram,'uComplexity');
    UPreparedFrames:=glGetUniformLocation(FProgram,'uPreparedFrames');
    UFragmentWorkReuse:=glGetUniformLocation(FProgram,'uFragmentWorkReuse');
    UCoverageSamples:=glGetUniformLocation(FProgram,'uCoverageSamples');
    UProjection:=glGetUniformLocation(FProgram,'uProjection'); UView:=glGetUniformLocation(FProgram,'uView');
    UModel:=glGetUniformLocation(FProgram,'uModel'); UKind:=glGetUniformLocation(FProgram,'uKind');
    USlices:=glGetUniformLocation(FProgram,'uSlices'); USegments:=glGetUniformLocation(FProgram,'uSegments');
    UQuality:=glGetUniformLocation(FProgram,'uQuality'); UTime:=glGetUniformLocation(FProgram,'uTime');
    UWind:=glGetUniformLocation(FProgram,'uWind'); UProfile:=glGetUniformLocation(FProgram,'uProfile');
    UBark:=glGetUniformLocation(FProgram,'uBark'); ULeaf:=glGetUniformLocation(FProgram,'uLeaf');
    UBarkTint:=glGetUniformLocation(FProgram,'uBarkTint');
    for S:=Low(S) to High(S) do begin P:=DefaultTreeParams(S);FBarkDefault[S]:=P.BarkColor;end;
    UEye:=glGetUniformLocation(FProgram,'uEye'); USpecies:=glGetUniformLocation(FProgram,'uSpecies');
    UDensity:=glGetUniformLocation(FProgram,'uDensity'); UDebug:=glGetUniformLocation(FProgram,'uDebug');
    UNeedlePairs:=glGetUniformLocation(FProgram,'uNeedlePairs');
    UNeedlesPerFascicle:=glGetUniformLocation(FProgram,'uNeedlesPerFascicle');
    UNeedleVertices:=glGetUniformLocation(FProgram,'uNeedleVertices');
    UViewportHeight:=glGetUniformLocation(FProgram,'uViewportHeight');
    UBakeMode:=glGetUniformLocation(FProgram,'uBakeMode');
    UUseBakedLOD:=glGetUniformLocation(FProgram,'uUseBakedLOD');
    ULODTexture:=glGetUniformLocation(FProgram,'uLODTexture');
    ULODNormal:=glGetUniformLocation(FProgram,'uLODNormal');ULODRelight:=glGetUniformLocation(FProgram,'uLODRelight');
    ULODFrames:=glGetUniformLocation(FProgram,'uLODFrames[0]');
    USeasonLeaf:=glGetUniformLocation(FProgram,'uSeasonLeaf'); ULeafRatio:=glGetUniformLocation(FProgram,'uLeafRatio');
    ULODSeasonParts:=glGetUniformLocation(FProgram,'uLODSeasonParts');
    USunDirection:=glGetUniformLocation(FProgram,'uSunDirection');
    UBillboardRight:=glGetUniformLocation(FProgram,'uBillboardRight');
    UFogColor:=glGetUniformLocation(FProgram,'uFogColor');
    UFogDensity:=glGetUniformLocation(FProgram,'uFogDensity');
    UOutputGamma:=glGetUniformLocation(FProgram,'uOutputGamma');
    UDepthOnly:=glGetUniformLocation(FProgram,'uDepthOnly');
    UShadowPartitions:=glGetUniformLocation(FProgram,'uShadowPartitions');
    UShadowPartition:=glGetUniformLocation(FProgram,'uShadowPartition');
    UDirectBranches:=glGetUniformLocation(FProgram,'uDirectBranches');
    ULeafSpray:=glGetUniformLocation(FProgram,'uLeafSpray');
    ULeafBudget:=glGetUniformLocation(FProgram,'uLeafBudget');
    ULeafSprays:=glGetUniformLocation(FProgram,'uLeafSprays');
    UNeedleScale:=glGetUniformLocation(FProgram,'uNeedleScale');
    UNeedleDetail:=glGetUniformLocation(FProgram,'uNeedleDetail');
    UFruitAmount:=glGetUniformLocation(FProgram,'uFruitAmount');
    UFruitMembers:=glGetUniformLocation(FProgram,'uFruitMembers');
    ULODFruitLayer:=glGetUniformLocation(FProgram,'uLODFruitLayer');
    glGetProgramiv(FProgram,GL_ACTIVE_UNIFORMS,@I);
    { Array elements occupy several locations. Extra space is cheap and
      uncommon/explicit locations fall back to an ordinary upload. }
    SetLength(FUniformCache,I+LOD_AGES+32);
    end;
    FSeason:=TREE_SUMMER;
    FUseBakedLOD:=True;
    glGenVertexArrays(Length(FVAO),@FVAO[0]); glGenBuffers(Length(FVBO),@FVBO[0]);
    glGenVertexArrays(NEEDLE_DENSITY_GROUPS,@FNeedleVAO[0]);
    glGenVertexArrays(1,@FBranchFineVAO);
    for I:=0 to High(FVAO) do begin
      glBindVertexArray(FVAO[I]); glBindBuffer(GL_ARRAY_BUFFER,FVBO[I]);
      for J:=0 to 3 do begin
        glEnableVertexAttribArray(J); glVertexAttribPointer(J,4,GL_FLOAT,GL_FALSE,SizeOf(TTreeGPUItem),Pointer(PtrUInt(J*16)));
        glVertexAttribDivisor(J,1);
      end;
      { The packed code is an integer attribute. Converting it to float would
        silently lose family/age bits for variants above 15. Offset 52 stays
        inside the original 64-byte descriptor. }
      glEnableVertexAttribArray(4);
      glVertexAttribIPointer(4,1,GL_UNSIGNED_INT,SizeOf(TTreeGPUItem),Pointer(PtrUInt(52)));
      glVertexAttribDivisor(4,1);
    end;
    glBindVertexArray(0); glBindBuffer(GL_ARRAY_BUFFER,0);
    if FShared=nil then begin CreateLeafSprays(ShaderDirectory);CreateBarkTextures(ShaderDirectory);end;
    FReady:=True;
  except
    if FLeafSprays<>0 then glDeleteTextures(1,@FLeafSprays);FLeafSprays:=0;
    if FBarkTextures<>0 then glDeleteTextures(1,@FBarkTextures);FBarkTextures:=0;
    glDeleteVertexArrays(1,@FBranchFineVAO);FBranchFineVAO:=0;
    glDeleteBuffers(1,@FBranchFrameVBO);FBranchFrameVBO:=0;
    glDeleteBuffers(Length(FVBO),@FVBO[0]);glDeleteVertexArrays(Length(FVAO),@FVAO[0]);
    glDeleteVertexArrays(NEEDLE_DENSITY_GROUPS,@FNeedleVAO[0]);
    if (FProgram<>0) and not Assigned(FShared) then glDeleteProgram(FProgram); FProgram:=0;
    if VS<>0 then glDeleteShader(VS); if FS<>0 then glDeleteShader(FS); raise;
  end;
  if VS<>0 then glDeleteShader(VS); if FS<>0 then glDeleteShader(FS);
end;
procedure TTreeRenderer.CreateBarkTextures(const ShaderDirectory:string);
var OldTexture:GLint;Layer:Integer;Pixels:TBarkPixels;Directory:string;ErrorCode:GLenum;
begin
  Directory:=ExtractFilePath(ExcludeTrailingPathDelimiter(ShaderDirectory))+'bark/';
  glGetIntegerv(GL_TEXTURE_BINDING_2D_ARRAY,@OldTexture);
  try
    glGenTextures(1,@FBarkTextures);glBindTexture(GL_TEXTURE_2D_ARRAY,FBarkTextures);
    glTexImage3D(GL_TEXTURE_2D_ARRAY,0,GL_RGBA8,BARK_TEXTURE_SIZE,BARK_TEXTURE_SIZE,BARK_TEXTURE_LAYERS,0,GL_RGBA,GL_UNSIGNED_BYTE,nil);
    for Layer:=0 to BARK_TEXTURE_LAYERS-1 do begin
      Pixels:=LoadBarkLayer(Directory,Layer);
      glTexSubImage3D(GL_TEXTURE_2D_ARRAY,0,0,0,Layer,BARK_TEXTURE_SIZE,BARK_TEXTURE_SIZE,1,GL_RGBA,GL_UNSIGNED_BYTE,@Pixels[0]);
    end;
    glTexParameteri(GL_TEXTURE_2D_ARRAY,GL_TEXTURE_MIN_FILTER,GL_LINEAR_MIPMAP_LINEAR);
    glTexParameteri(GL_TEXTURE_2D_ARRAY,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D_ARRAY,GL_TEXTURE_WRAP_S,GL_REPEAT);glTexParameteri(GL_TEXTURE_2D_ARRAY,GL_TEXTURE_WRAP_T,GL_REPEAT);
    glGenerateMipmap(GL_TEXTURE_2D_ARRAY);ErrorCode:=glGetError();
    if ErrorCode<>GL_NO_ERROR then raise Exception.CreateFmt('Cannot upload bark library (GL $%x)',[ErrorCode]);
  finally glBindTexture(GL_TEXTURE_2D_ARRAY,OldTexture);end;
end;
procedure TTreeRenderer.CreateLeafSprays(const ShaderDirectory:string);
const N=256;Variants=8;Layers=9*Variants;
var FBO,VAO,BakeProgram,VS,FS:GLuint;OldDraw,OldRead,OldProgram,OldVAO,OldTexture:GLint;
  OldViewport:array[0..3]of GLint;OldClear:array[0..3]of GLfloat;
  WasDepth,WasBlend,WasCull,WasScissor:GLboolean;OldColorMask:array[0..3]of GLboolean;S:TTreeSpecies;Variant,Layer:Integer;
  BakeSpecies,BakeSpray,BakeTime,OK:GLint;Source:string;
begin
  glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING,@OldDraw);glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING,@OldRead);
  glGetIntegerv(GL_CURRENT_PROGRAM,@OldProgram);glGetIntegerv(GL_VERTEX_ARRAY_BINDING,@OldVAO);
  glGetIntegerv(GL_TEXTURE_BINDING_2D_ARRAY,@OldTexture);glGetIntegerv(GL_VIEWPORT,@OldViewport[0]);
  glGetFloatv(GL_COLOR_CLEAR_VALUE,@OldClear[0]);glGetBooleanv(GL_COLOR_WRITEMASK,@OldColorMask[0]);
  WasDepth:=glIsEnabled(GL_DEPTH_TEST);WasBlend:=glIsEnabled(GL_BLEND);WasCull:=glIsEnabled(GL_CULL_FACE);WasScissor:=glIsEnabled(GL_SCISSOR_TEST);
  FBO:=0;VAO:=0;BakeProgram:=0;VS:=0;FS:=0;
  try
  try
    { Keep the one-time procedural mask generator out of the live shader:
      its search loop otherwise increases register pressure in every tree pass. }
    VS:=CompileShader(GL_VERTEX_SHADER,ReadText(IncludeTrailingPathDelimiter(ShaderDirectory)+'tree.vert'));
    Source:=ReadText(IncludeTrailingPathDelimiter(ShaderDirectory)+'tree.frag');
    Source:=StringReplace(Source,'#version 330 core','#version 330 core'+LineEnding+'#define LEAF_SPRAY_BAKE 1',[]);
    FS:=CompileShader(GL_FRAGMENT_SHADER,Source);
    BakeProgram:=glCreateProgram();glAttachShader(BakeProgram,VS);glAttachShader(BakeProgram,FS);glLinkProgram(BakeProgram);
    glGetProgramiv(BakeProgram,GL_LINK_STATUS,@OK);
    if OK=0 then raise Exception.Create('Leaf spray program link failed');
    BakeSpecies:=glGetUniformLocation(BakeProgram,'uSpecies');BakeSpray:=glGetUniformLocation(BakeProgram,'uLeafSpray');
    BakeTime:=glGetUniformLocation(BakeProgram,'uTime');
    glGenTextures(1,@FLeafSprays);glBindTexture(GL_TEXTURE_2D_ARRAY,FLeafSprays);
    glTexImage3D(GL_TEXTURE_2D_ARRAY,0,GL_RGBA8,N,N,Layers,0,GL_RGBA,GL_UNSIGNED_BYTE,nil);
    glTexParameteri(GL_TEXTURE_2D_ARRAY,GL_TEXTURE_MIN_FILTER,GL_LINEAR_MIPMAP_LINEAR);
    glTexParameteri(GL_TEXTURE_2D_ARRAY,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D_ARRAY,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D_ARRAY,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
    glGenFramebuffers(1,@FBO);glBindFramebuffer(GL_FRAMEBUFFER,FBO);
    glGenVertexArrays(1,@VAO);glBindVertexArray(VAO);glUseProgram(BakeProgram);
    glDisable(GL_DEPTH_TEST);glDisable(GL_BLEND);glDisable(GL_CULL_FACE);glDisable(GL_SCISSOR_TEST);
    glColorMask(GL_TRUE,GL_TRUE,GL_TRUE,GL_TRUE);
    glViewport(0,0,N,N);glClearColor(0,0,0,0);
    glUniform1i(glGetUniformLocation(BakeProgram,'uKind'),9);
    glUniform1f(glGetUniformLocation(BakeProgram,'uQuality'),4);
    for S:=Low(S) to High(S) do if LeafSprayIndex(S)>=0 then begin
      glUniform1i(BakeSpecies,Ord(S));glUniform4f(BakeSpray,LeafSprayRows(S),LeafSprayAspect(S),LeafSprayIndex(S)*Variants,1);
      for Variant:=0 to Variants-1 do begin
        Layer:=LeafSprayIndex(S)*Variants+Variant;
        glFramebufferTextureLayer(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,FLeafSprays,0,Layer);
        if glCheckFramebufferStatus(GL_FRAMEBUFFER)<>GL_FRAMEBUFFER_COMPLETE then raise Exception.Create('Leaf spray target incomplete');
        glClear(GL_COLOR_BUFFER_BIT);glUniform1f(BakeTime,(Variant+0.5)/Variants);
        glDrawArrays(GL_TRIANGLES,0,6);
      end;
    end;
    glBindFramebuffer(GL_FRAMEBUFFER,OldDraw);glGenerateMipmap(GL_TEXTURE_2D_ARRAY);
  except
    if FLeafSprays<>0 then glDeleteTextures(1,@FLeafSprays);FLeafSprays:=0;raise;
  end;
  finally
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER,OldDraw);glBindFramebuffer(GL_READ_FRAMEBUFFER,OldRead);
    if FBO<>0 then glDeleteFramebuffers(1,@FBO);if VAO<>0 then glDeleteVertexArrays(1,@VAO);
    glUseProgram(OldProgram);glBindVertexArray(OldVAO);glBindTexture(GL_TEXTURE_2D_ARRAY,OldTexture);
    if BakeProgram<>0 then glDeleteProgram(BakeProgram);if VS<>0 then glDeleteShader(VS);if FS<>0 then glDeleteShader(FS);
    glViewport(OldViewport[0],OldViewport[1],OldViewport[2],OldViewport[3]);glClearColor(OldClear[0],OldClear[1],OldClear[2],OldClear[3]);
    glColorMask(OldColorMask[0],OldColorMask[1],OldColorMask[2],OldColorMask[3]);
    if WasDepth<>GL_FALSE then glEnable(GL_DEPTH_TEST);if WasBlend<>GL_FALSE then glEnable(GL_BLEND);if WasCull<>GL_FALSE then glEnable(GL_CULL_FACE);if WasScissor<>GL_FALSE then glEnable(GL_SCISSOR_TEST);
  end;
end;
procedure TTreeRenderer.Release;
var S: TTreeSpecies;I:Integer;
begin
  if not FReady then Exit;
  for S:=Low(TTreeSpecies) to High(TTreeSpecies) do begin
    if FLODTextures[S]<>0 then glDeleteTextures(1,@FLODTextures[S]); FLODTextures[S]:=0; FLODKeys[S]:='';
    if FLODNormals[S]<>0 then glDeleteTextures(1,@FLODNormals[S]);FLODNormals[S]:=0;
  end;
  if FLeafSprays<>0 then glDeleteTextures(1,@FLeafSprays);FLeafSprays:=0;
  if FBarkTextures<>0 then glDeleteTextures(1,@FBarkTextures);FBarkTextures:=0;
  glDeleteVertexArrays(1,@FBranchFineVAO);FBranchFineVAO:=0;
  glDeleteBuffers(1,@FBranchFrameVBO);FBranchFrameVBO:=0;FPreparedFrames:=False;
  Dec(TreePreparedFrameBytes,FPreparedFrameBytes);FPreparedFrameBytes:=0;
  glDeleteBuffers(Length(FVBO),@FVBO[0]); glDeleteVertexArrays(Length(FVAO),@FVAO[0]); if not Assigned(FShared) then glDeleteProgram(FProgram);
  glDeleteVertexArrays(NEEDLE_DENSITY_GROUPS,@FNeedleVAO[0]);
  FillChar(FNeedleVAO,SizeOf(FNeedleVAO),0);
  if FCardIndices<>0 then glDeleteBuffers(1,@FCardIndices);
  if FNeedleIndices<>0 then glDeleteBuffers(1,@FNeedleIndices);
  for I:=0 to High(FGridIndices) do glDeleteBuffers(1,@FGridIndices[I].Buffer);
  FCardIndices:=0;FNeedleIndices:=0;FGridIndices:=nil;
  FillChar(FVBO,SizeOf(FVBO),0); FillChar(FVAO,SizeOf(FVAO),0); FProgram:=0; FReady:=False;
end;
function TTreeRenderer.HasLODAtlas(const Profile: TTreeParams): Boolean;
begin
  if Assigned(FShared) then Exit(FShared.HasLODAtlas(Profile));
  if FLODTextures[Profile.Species]=0 then Exit(False);
  if (FCheckedKeys[Profile.Species]='') or
     not CompareMem(@FCheckedProfiles[Profile.Species],@Profile,SizeOf(Profile)) then begin
    FCheckedProfiles[Profile.Species]:=Profile;
    FCheckedKeys[Profile.Species]:=LODProfileKey(Profile);
  end;
  Result:=FLODKeys[Profile.Species]=FCheckedKeys[Profile.Species];
end;
function TTreeRenderer.HasSeasonLOD(const Profile: TTreeParams): Boolean;
begin
  if Assigned(FShared) then Exit(FShared.HasSeasonLOD(Profile));
  Result:=HasLODAtlas(Profile) and FLODSeasonParts[Profile.Species];
end;
function TTreeRenderer.LODTextureBytes:Int64;
var S:TTreeSpecies;Parts,N:Integer;LayerPixels,Bytes:Int64;
begin
  if Assigned(FShared) then Exit(FShared.LODTextureBytes);
  Result:=0;if FLeafSprays<>0 then Result:=Int64(256*256*4*72)*4 div 3;
  if FBarkTextures<>0 then Inc(Result,Int64(BARK_TEXTURE_SIZE)*BARK_TEXTURE_SIZE*BARK_TEXTURE_LAYERS*4*4 div 3);
  for S:=Low(S) to High(S) do if FLODTextures[S]<>0 then begin
    Parts:=1;
    if FLODSeasonParts[S] then Parts:=2+Ord(FLODFruitLayer[S]);
    N:=LOD_SIZE;LayerPixels:=0;
    repeat
      Inc(LayerPixels,Int64(N)*N);N:=N div 2;
    until N=0;
    Bytes:=LayerPixels*4*LOD_VIEWS*LOD_AGES*Parts;
    if FLODNormals[S]<>0 then
      Inc(Bytes,(LayerPixels-Int64(LOD_SIZE)*LOD_SIZE)*4*LOD_VIEWS*LOD_AGES*Parts);
    Inc(Result,Bytes);
  end;
end;
procedure TTreeRenderer.LoadLODAtlas(const Directory: string; const Profile: TTreeParams);
var Prepared: TPreparedTreeLOD;
begin
  if Assigned(FShared) then begin FShared.LoadLODAtlas(Directory,Profile); Exit; end;
  Prepared:=PrepareLODAtlas(Directory,Profile);
  if Length(Prepared.Pixels)>0 then UploadLODAtlas(Prepared);
end;
class function TTreeRenderer.PrepareLODAtlas(const Directory: string;
  const Profile: TTreeParams): TPreparedTreeLOD;
var Path: string; Atlas: TLODPixels;
    G,V,X,Y,C,Src,Dst,Part,Parts,LayerSize,N: Integer;
begin
  Result:=Default(TPreparedTreeLOD); Result.Species:=Profile.Species;
  Path:=IncludeTrailingPathDelimiter(Directory)+SpeciesName(Profile.Species);
  if not ReadLODMetadata(Path+'.json',Profile,Result.Frames) then Exit;
  Result.Key:=LODProfileKey(Profile);
  Result.Seasonal:=ReadLODSeasonMetadata(Path+'.json') and FileExists(Path+'-wood.png') and FileExists(Path+'-foliage.png');
  Result.FruitLayer:=Result.Seasonal and HasTreeFruit(Profile.Species) and FileExists(Path+'-fruit.png');
  Parts:=1; if Result.Seasonal then Parts:=2;
  if Result.FruitLayer then Parts:=3;
  Result.Relight:=ReadLODRelightMetadata(Path+'.json');
  LayerSize:=LOD_SIZE*LOD_SIZE*LOD_VIEWS*LOD_AGES*4; SetLength(Result.Pixels,LayerSize*Parts);
  for Part:=0 to Parts-1 do begin
  if not Result.Seasonal then Atlas:=LoadLODPng(Path+'.png',LOD_SIZE*LOD_VIEWS,LOD_SIZE*LOD_AGES)
  else if Part=0 then Atlas:=LoadLODPng(Path+'-wood.png',LOD_SIZE*LOD_VIEWS,LOD_SIZE*LOD_AGES)
  else if Part=1 then Atlas:=LoadLODPng(Path+'-foliage.png',LOD_SIZE*LOD_VIEWS,LOD_SIZE*LOD_AGES)
  else Atlas:=LoadLODPng(Path+'-fruit.png',LOD_SIZE*LOD_VIEWS,LOD_SIZE*LOD_AGES);
  for G:=0 to LOD_AGES-1 do for V:=0 to LOD_VIEWS-1 do
    for Y:=0 to LOD_SIZE-1 do for X:=0 to LOD_SIZE-1 do begin
      Src:=(((LOD_AGES-1-G)*LOD_SIZE+Y)*LOD_SIZE*LOD_VIEWS+V*LOD_SIZE+X)*4;
      Dst:=Part*LayerSize+(((G*LOD_VIEWS+V)*LOD_SIZE+Y)*LOD_SIZE+X)*4;
      for C:=0 to 3 do Result.Pixels[Dst+C]:=Round(Max(0,Min(1,Atlas[Src+C]))*255);
    end;
  end;
  if Result.Relight then begin
    N:=LOD_SIZE div 2;LayerSize:=N*N*LOD_VIEWS*LOD_AGES*4;SetLength(Result.NormalPixels,LayerSize*Parts);
    for Part:=0 to Parts-1 do begin
      if not Result.Seasonal then Atlas:=LoadLODPng(Path+'-normal.png',N*LOD_VIEWS,N*LOD_AGES)
      else if Part=0 then Atlas:=LoadLODPng(Path+'-wood-normal.png',N*LOD_VIEWS,N*LOD_AGES)
      else if Part=1 then Atlas:=LoadLODPng(Path+'-foliage-normal.png',N*LOD_VIEWS,N*LOD_AGES)
      else Atlas:=LoadLODPng(Path+'-fruit-normal.png',N*LOD_VIEWS,N*LOD_AGES);
      for G:=0 to LOD_AGES-1 do for V:=0 to LOD_VIEWS-1 do
        for Y:=0 to N-1 do for X:=0 to N-1 do begin
          Src:=(((LOD_AGES-1-G)*N+Y)*N*LOD_VIEWS+V*N+X)*4;
          Dst:=Part*LayerSize+(((G*LOD_VIEWS+V)*N+Y)*N+X)*4;
          for C:=0 to 3 do Result.NormalPixels[Dst+C]:=Round(Max(0,Min(1,Atlas[Src+C]))*255);
        end;
    end;
  end;
end;
procedure TTreeRenderer.UploadLODAtlas(const Prepared: TPreparedTreeLOD);
var OldTexture: GLint; Tex, NormalTex, ErrorCode: GLuint; S: TTreeSpecies; Parts: Integer;
begin
  if Assigned(FShared) then begin FShared.UploadLODAtlas(Prepared); Exit; end;
  S:=Prepared.Species; Parts:=1; if Prepared.Seasonal then Parts:=2;
  if Prepared.FruitLayer then Parts:=3;
  if Length(Prepared.Pixels)<>LOD_SIZE*LOD_SIZE*LOD_VIEWS*LOD_AGES*4*Parts then
    raise EArgumentException.Create('Invalid prepared tree atlas');
  { Attribute/texture setup in another renderer can leave a stale GL error.
    Attribute an upload failure only to calls in this operation. }
  while glGetError()<>GL_NO_ERROR do ;
  if Prepared.Relight and (Length(Prepared.NormalPixels)<>Length(Prepared.Pixels) div 4) then
    raise EArgumentException.Create('Invalid prepared normal atlas');
  Tex:=0;NormalTex:=0; glGetIntegerv(GL_TEXTURE_BINDING_2D_ARRAY,@OldTexture);
  try
    glGenTextures(1,@Tex); glBindTexture(GL_TEXTURE_2D_ARRAY,Tex);
    glTexImage3D(GL_TEXTURE_2D_ARRAY,0,GL_RGBA8,LOD_SIZE,LOD_SIZE,LOD_VIEWS*LOD_AGES*Parts,0,GL_RGBA,GL_UNSIGNED_BYTE,@Prepared.Pixels[0]);
    glTexParameteri(GL_TEXTURE_2D_ARRAY,GL_TEXTURE_MIN_FILTER,GL_LINEAR_MIPMAP_LINEAR);
    glTexParameteri(GL_TEXTURE_2D_ARRAY,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D_ARRAY,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D_ARRAY,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
    glGenerateMipmap(GL_TEXTURE_2D_ARRAY);
    ErrorCode:=glGetError();
    if ErrorCode<>GL_NO_ERROR then raise Exception.CreateFmt('Cannot upload LOD texture array (GL $%x)',[ErrorCode]);
    if Prepared.Relight then begin
      glGenTextures(1,@NormalTex);glBindTexture(GL_TEXTURE_2D_ARRAY,NormalTex);
      glTexImage3D(GL_TEXTURE_2D_ARRAY,0,GL_RGBA8,LOD_SIZE div 2,LOD_SIZE div 2,LOD_VIEWS*LOD_AGES*Parts,0,GL_RGBA,GL_UNSIGNED_BYTE,@Prepared.NormalPixels[0]);
      glTexParameteri(GL_TEXTURE_2D_ARRAY,GL_TEXTURE_MIN_FILTER,GL_LINEAR_MIPMAP_LINEAR);
      glTexParameteri(GL_TEXTURE_2D_ARRAY,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
      glTexParameteri(GL_TEXTURE_2D_ARRAY,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);glTexParameteri(GL_TEXTURE_2D_ARRAY,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
      glGenerateMipmap(GL_TEXTURE_2D_ARRAY);ErrorCode:=glGetError();
      if ErrorCode<>GL_NO_ERROR then raise Exception.CreateFmt('Cannot upload LOD normals (GL $%x)',[ErrorCode]);
    end;
    if FLODNormals[S]<>0 then glDeleteTextures(1,@FLODNormals[S]);
    FLODNormals[S]:=NormalTex;NormalTex:=0;FLODRelight[S]:=Prepared.Relight;
    if FLODTextures[S]<>0 then glDeleteTextures(1,@FLODTextures[S]);
    FLODTextures[S]:=Tex; Tex:=0; FLODFrames[S]:=Prepared.Frames; FLODKeys[S]:=Prepared.Key; FLODSeasonParts[S]:=Prepared.Seasonal;
    FLODFruitLayer[S]:=Prepared.FruitLayer;
  finally
    if Tex<>0 then glDeleteTextures(1,@Tex);
    if NormalTex<>0 then glDeleteTextures(1,@NormalTex);
    glBindTexture(GL_TEXTURE_2D_ARRAY,OldTexture);
  end;
end;
procedure TTreeRenderer.Upload(Index: Integer; const Items: TTreeGPUItems);
var P: Pointer; PreviousBuffer: GLint;
begin
  P:=nil; if Length(Items)>0 then P:=@Items[0];
  glGetIntegerv(GL_ARRAY_BUFFER_BINDING,@PreviousBuffer);
  glBindBuffer(GL_ARRAY_BUFFER,FVBO[Index]); glBufferData(GL_ARRAY_BUFFER,Length(Items)*SizeOf(TTreeGPUItem),P,GL_STATIC_DRAW);
  glBindBuffer(GL_ARRAY_BUFFER,PreviousBuffer);
end;
procedure SetVec(var Item: TTreeGPUItem; Offset: Integer; const V: TTreeVec3; W: Single);
begin Item[Offset]:=V.X; Item[Offset+1]:=V.Y; Item[Offset+2]:=V.Z; Item[Offset+3]:=W; end;
procedure SetType(var Item: TTreeGPUItem; const Actual: TTreeParams);
begin
  Move(Actual.TypeCode,Item[13],SizeOf(TTreeTypeCode));
  Item[14]:=Actual.Maturity;
  Item[15]:=Actual.Irregularity;
end;
procedure TTreeRenderer.UploadTree(const Data:TTreeData);
begin UploadPreparedTree(PrepareTreeGPU(Data));end;

procedure TTreeRenderer.UploadPreparedTree(const Prepared:TPreparedTreeGPU);
var I,J,G,Offset:Integer; OldVAO,OldBuffer:GLint;
    Frames:Pointer;
begin
  FShadowFingerprint:=Prepared.Fingerprint;
  FShadowBoundsMin:=Prepared.BoundsMin;
  FShadowBoundsMax:=Prepared.BoundsMax;
  FBranchCount:=Prepared.BranchCount;
  FPrimaryCount:=Prepared.PrimaryCount;
  FLeafCount:=Prepared.LeafCount;
  FSourceLeafCount:=Max(Prepared.LeafCount,Prepared.SourceLeafCount);
  FSourceShootCount:=Max(Prepared.NeedleShootCount,Prepared.SourceShootCount);
  FCrownCount:=Prepared.CrownCount;
  FNeedleShootCount:=Prepared.NeedleShootCount;
  FFruitCount:=Prepared.FruitCount;
  FFruitRadius:=Prepared.FruitRadius;
  FFruitMembers:=Prepared.FruitMembers;
  FNeedlesPerFascicle:=Prepared.NeedlesPerFascicle;
  FDepthCounts:=Prepared.DepthCounts;
  FNeedleGroups:=Prepared.NeedleGroups;
  FStats.UploadBytes:=Prepared.UploadBytes;
  FPreparedFrames:=TreePreparedFramesExperimentEnabled and Prepared.PreparedFrames and
    (Length(Prepared.BranchFrames)=FBranchCount);
  for I:=0 to 5 do if I<>3 then Upload(I,Prepared.Items[I]);
  glGetIntegerv(GL_VERTEX_ARRAY_BINDING,@OldVAO);glGetIntegerv(GL_ARRAY_BUFFER_BINDING,@OldBuffer);
  try
    glBindVertexArray(FBranchFineVAO);glBindBuffer(GL_ARRAY_BUFFER,FVBO[0]);
    Offset:=FPrimaryCount*SizeOf(TTreeGPUItem);
    for J:=0 to 3 do begin
      glEnableVertexAttribArray(J);glVertexAttribPointer(J,4,GL_FLOAT,GL_FALSE,SizeOf(TTreeGPUItem),Pointer(PtrUInt(Offset+J*16)));
      glVertexAttribDivisor(J,1);
    end;
    glEnableVertexAttribArray(4);glVertexAttribIPointer(4,1,GL_UNSIGNED_INT,SizeOf(TTreeGPUItem),Pointer(PtrUInt(Offset+52)));
    glVertexAttribDivisor(4,1);
    Frames:=nil;
    if FPreparedFrames and (Length(Prepared.BranchFrames)>0) then Frames:=@Prepared.BranchFrames[0];
    Dec(TreePreparedFrameBytes,FPreparedFrameBytes);
    FPreparedFrameBytes:=0;
    if Frames<>nil then FPreparedFrameBytes:=Int64(Length(Prepared.BranchFrames))*SizeOf(TTreeBranchFrame);
    Inc(TreePreparedFrameBytes,FPreparedFrameBytes);
    { Charge only frames actually uploaded, even for externally supplied snapshots. }
    FStats.UploadBytes:=Prepared.UploadBytes-Int64(Length(Prepared.BranchFrames))*SizeOf(TTreeBranchFrame)+FPreparedFrameBytes;
    if (Frames<>nil) and (FBranchFrameVBO=0) then glGenBuffers(1,@FBranchFrameVBO);
    if FBranchFrameVBO<>0 then begin
      glBindBuffer(GL_ARRAY_BUFFER,FBranchFrameVBO);
      glBufferData(GL_ARRAY_BUFFER,FPreparedFrameBytes,Frames,GL_STATIC_DRAW);
    end;
    for I:=0 to 1 do begin
      if I=0 then begin glBindVertexArray(FVAO[0]);Offset:=0 end
      else begin glBindVertexArray(FBranchFineVAO);Offset:=FPrimaryCount*SizeOf(TTreeBranchFrame) end;
      if FPreparedFrames and (FBranchCount>0) then begin
        glEnableVertexAttribArray(5);
        glVertexAttribPointer(5,4,GL_FLOAT,GL_FALSE,SizeOf(TTreeBranchFrame),Pointer(PtrUInt(Offset)));
        glVertexAttribDivisor(5,1);
      end else glDisableVertexAttribArray(5);
    end;
  finally glBindVertexArray(OldVAO);glBindBuffer(GL_ARRAY_BUFFER,OldBuffer);end;
  { All density groups share one descriptor buffer. Their offsets are fixed
    until the next upload, so do not mutate attribute layouts on every draw. }
  glGetIntegerv(GL_VERTEX_ARRAY_BINDING,@OldVAO);
  glGetIntegerv(GL_ARRAY_BUFFER_BINDING,@OldBuffer);
  try
    glBindBuffer(GL_ARRAY_BUFFER,FVBO[4]);
    for G:=0 to NEEDLE_DENSITY_GROUPS-1 do begin
      glBindVertexArray(FNeedleVAO[G]);
      Offset:=FNeedleGroups[G].First*SizeOf(TTreeGPUItem);
      for J:=0 to 3 do begin
        glEnableVertexAttribArray(J);
        glVertexAttribPointer(J,4,GL_FLOAT,GL_FALSE,SizeOf(TTreeGPUItem),Pointer(PtrUInt(Offset+J*16)));
        glVertexAttribDivisor(J,1);
      end;
      glEnableVertexAttribArray(4);
      glVertexAttribIPointer(4,1,GL_UNSIGNED_INT,SizeOf(TTreeGPUItem),Pointer(PtrUInt(Offset+52)));
      glVertexAttribDivisor(4,1);
    end;
  finally
    glBindVertexArray(OldVAO);glBindBuffer(GL_ARRAY_BUFFER,OldBuffer);
  end;
end;
procedure TTreeRenderer.UploadForest(const Center: TTreeInstance; const P: TTreeParams; Count: Integer);
var Instances: array of TTreeInstance; I,Side,X,Z: Integer; Inst: TTreeInstance; Pos: TTreeVec3;
begin
  FForestCount:=Max(1,Min(10001,Count)); SetLength(Instances,FForestCount); Side:=Ceil(Sqrt(FForestCount));
  for I:=0 to FForestCount-1 do begin
    Inst:=Center; Pos:=Vec(0,0,0);
    if I>0 then begin
      X:=(I-1) mod Side-Side div 2; Z:=(I-1) div Side-Side div 2;
      Pos:=Vec(X*22+(HashUnit(I,10)-0.5)*12,0,Z*22+(HashUnit(I,11)-0.5)*12);
      { Reserve the inspection area around the selected tree. }
      if Magnitude(Pos)<75 then Pos.Z:=Pos.Z+110;
      Inst.Position.X:=Inst.Position.X+Pos.X; Inst.Position.Z:=Inst.Position.Z+Pos.Z;
    end;
    Instances[I]:=Inst;
  end;
  UploadDistantTrees(Instances,P,Center.Position);
end;
procedure TTreeRenderer.UploadDistantTrees(const Instances: array of TTreeInstance;
  const Profile: TTreeParams; const WorldOrigin: TTreeWorldPosition);
begin
  UploadDistantTreesAt(Instances, [], Profile, WorldOrigin);
end;
procedure TTreeRenderer.UploadDistantTreesAt(const Instances: array of TTreeInstance;
  const RenderPositions: array of TTreeWorldPosition;
  const Profile: TTreeParams; const WorldOrigin: TTreeWorldPosition);
begin
  UploadDistantItems(PackDistantTreesAt(Instances,RenderPositions,Profile,WorldOrigin));
end;
class function TTreeRenderer.PackDistantTreesAt(const Instances: array of TTreeInstance;
  const RenderPositions: array of TTreeWorldPosition;
  const Profile: TTreeParams; const WorldOrigin: TTreeWorldPosition): TTreeGPUItems;
var Items: TTreeGPUItems; I: Integer; Pos: TTreeVec3; Actual: TTreeParams;
begin
  ValidateTreeParams(Profile); SetLength(Items,Length(Instances));
  if (Length(RenderPositions)<>0) and (Length(RenderPositions)<>Length(Instances)) then
    raise EArgumentException.Create('Render positions must match tree instances');
  for I:=0 to High(Instances) do begin
    if Instances[I].Species<>Profile.Species then raise EArgumentException.Create('Distant batch must share one type profile');
    Pos:=Vec(Instances[I].Position.X-WorldOrigin.X,Instances[I].Position.Y-WorldOrigin.Y,Instances[I].Position.Z-WorldOrigin.Z);
    if Length(RenderPositions)<>0 then
      Pos:=Vec(RenderPositions[I].X-WorldOrigin.X,RenderPositions[I].Y-WorldOrigin.Y,RenderPositions[I].Z-WorldOrigin.Z);
    Actual:=ResolveTreeParams(Instances[I],Profile);
    SetVec(Items[I],0,Pos,0); SetVec(Items[I],4,Vec(Actual.Height,Actual.TrunkRadius,Actual.CrownSpread),Actual.CrownStart);
    Items[I][12]:=HashUnit(Actual.Seed,10); SetType(Items[I],Actual);
    Items[I][8]:=Hash32(Actual.Seed) and 3;
  end;
  Result:=Items;
end;
procedure TTreeRenderer.UploadDistantItems(const Items:TTreeGPUItems);
var I:Integer;
begin
  FFarMinHeight:=0;FFarMaxHeight:=0;
  for I:=0 to High(Items) do begin
    if I=0 then FFarMinHeight:=Items[I][4] else FFarMinHeight:=Min(FFarMinHeight,Items[I][4]);
    FFarMaxHeight:=Max(FFarMaxHeight,Items[I][4]);
  end;
  FForestCount:=Length(Items);
  Upload(3,Items);
end;
procedure TTreeRenderer.UpdateDistantItems(First: Integer; const Items: TTreeGPUItems);
var Previous: GLint; Bytes: Int64;
begin
  if Length(Items)=0 then Exit;
  if (First<0) or (First+Length(Items)>FForestCount) then
    raise EArgumentException.Create('Tree instance update outside buffer');
  Bytes:=Int64(Length(Items))*SizeOf(TTreeGPUItem);
  glGetIntegerv(GL_ARRAY_BUFFER_BINDING,@Previous);
  glBindBuffer(GL_ARRAY_BUFFER,FVBO[3]);
  try glBufferSubData(GL_ARRAY_BUFFER,Int64(First)*SizeOf(TTreeGPUItem),Bytes,@Items[0]);
  finally glBindBuffer(GL_ARRAY_BUFFER,Previous) end;
  Inc(FStats.UploadBytes,Bytes);
end;

function TTreeRenderer.UploadIndices(const Indices:TTreeIndices):GLuint;
var PreviousBuffer:GLint;
begin
  glGetIntegerv(GL_ARRAY_BUFFER_BINDING,@PreviousBuffer);
  glGenBuffers(1,@Result);glBindBuffer(GL_ARRAY_BUFFER,Result);
  glBufferData(GL_ARRAY_BUFFER,Length(Indices)*SizeOf(GLushort),@Indices[0],GL_STATIC_DRAW);
  glBindBuffer(GL_ARRAY_BUFFER,PreviousBuffer);
end;
function TTreeRenderer.GridIndices(Slices,Segments:Integer):GLuint;
var Indices:TTreeIndices;I,X,Y,K:Integer;
  function VertexID(VX,VY:Integer):GLushort;
  begin
    { Reuse an existing gl_VertexID with the same grid corner. The shader's
      coordinates, seam normals and triangle order are exactly preserved. }
    if VY<Segments then begin
      if VX<Slices then Result:=(VY*Slices+VX)*6
      else Result:=(VY*Slices+Slices-1)*6+1;
    end else begin
      if VX<Slices then Result:=((Segments-1)*Slices+VX)*6+5
      else Result:=Segments*Slices*6-4;
    end;
  end;
begin
  if Assigned(FShared) then Exit(FShared.GridIndices(Slices,Segments));
  if (Slices<=0) or (Segments<=0) or (Int64(Slices)*Segments*6>65536) then Exit(0);
  for I:=0 to High(FGridIndices) do
    if (FGridIndices[I].Slices=Slices) and (FGridIndices[I].Segments=Segments) then Exit(FGridIndices[I].Buffer);
  SetLength(Indices,Slices*Segments*6);K:=0;
  for Y:=0 to Segments-1 do for X:=0 to Slices-1 do begin
    Indices[K]:=VertexID(X,Y);Indices[K+1]:=VertexID(X+1,Y);Indices[K+2]:=VertexID(X+1,Y+1);
    Indices[K+3]:=Indices[K];Indices[K+4]:=Indices[K+2];Indices[K+5]:=VertexID(X,Y+1);Inc(K,6);
  end;
  Result:=UploadIndices(Indices);I:=Length(FGridIndices);SetLength(FGridIndices,I+1);
  FGridIndices[I].Slices:=Slices;FGridIndices[I].Segments:=Segments;FGridIndices[I].Buffer:=Result;
end;
function TTreeRenderer.CardIndices:GLuint;
var Indices:TTreeIndices;
begin
  if Assigned(FShared) then Exit(FShared.CardIndices);
  if FCardIndices=0 then begin
    Indices:=TTreeIndices.Create(0,1,2,0,2,5);FCardIndices:=UploadIndices(Indices);
  end;
  Result:=FCardIndices;
end;
function TTreeRenderer.NeedleIndices:GLuint;
const Corners:array[0..8]of Integer=(0,1,2,2,1,5,2,5,8);
var Indices:TTreeIndices;I,J:Integer;
begin
  if Assigned(FShared) then Exit(FShared.NeedleIndices);
  if FNeedleIndices=0 then begin
    { Largest density group and fascicle fit in 16-bit IDs. One shared table,
      no needle positions or geometry on the CPU. Prefixes serve every LOD. }
    SetLength(Indices,NEEDLE_GROUP_PAIRS[NEEDLE_DENSITY_GROUPS-1]*8*9);
    for I:=0 to Length(Indices) div 9-1 do for J:=0 to 8 do
      Indices[I*9+J]:=GLushort(I)*9+GLushort(Corners[J]);
    FNeedleIndices:=UploadIndices(Indices);
  end;
  Result:=FNeedleIndices;
end;
procedure TTreeRenderer.Draw(Kind,BufferIndex,Vertices,Count: Integer; VertexArray: GLuint; IndexBuffer:GLuint);
var J: Integer;
begin
  if Count<=0 then Exit;
  if not FBakeMode and ((TreeDiagnosticDrawMask and (Cardinal(1) shl Kind))=0) then Exit;
  glUniform1i(UKind,Kind);
  if VertexArray=0 then VertexArray:=FVAO[BufferIndex];
  glBindVertexArray(VertexArray);
  { Ground uses only gl_VertexID. A scene may have zero forest descriptors;
    never let the driver fetch enabled attributes from that empty buffer. }
  if Kind=4 then for J:=0 to 4 do glDisableVertexAttribArray(J);
  try
    if IndexBuffer<>0 then begin
      glBindBuffer(GL_ELEMENT_ARRAY_BUFFER,IndexBuffer);
      glDrawElementsInstanced(GL_TRIANGLES,Vertices,GL_UNSIGNED_SHORT,nil,Count);
    end else glDrawArraysInstanced(GL_TRIANGLES,0,Vertices,Count);
  finally if Kind=4 then for J:=0 to 4 do glEnableVertexAttribArray(J); end;
  Inc(FStats.DrawCalls); Inc(FStats.Triangles,Vertices div 3*Count);
end;
function TTreeRenderer.VerifyPackedType(Expected: TTreeTypeCode): Boolean;
const GL_VERTEX_ATTRIB_ARRAY_DIVISOR_QUERY = $88FE; { core 3.3; absent in this FPC header }
var OldVAO,OldBuffer,IsInteger,Kind,Divisor: GLint; Code: TTreeTypeCode;
  {$ifdef OpenGLES}Mapped: Pointer;{$endif}
begin
  glGetIntegerv(GL_VERTEX_ARRAY_BINDING,@OldVAO); glGetIntegerv(GL_ARRAY_BUFFER_BINDING,@OldBuffer);
  try
    glBindVertexArray(FVAO[3]); glBindBuffer(GL_ARRAY_BUFFER,FVBO[3]);
    Code:=0;
    {$ifdef OpenGLES}
    Mapped:=glMapBufferRange(GL_ARRAY_BUFFER,52,SizeOf(Code),GL_MAP_READ_BIT);
    if Mapped=nil then Exit(False);
    Move(Mapped^,Code,SizeOf(Code)); glUnmapBuffer(GL_ARRAY_BUFFER);
    {$else}glGetBufferSubData(GL_ARRAY_BUFFER,52,SizeOf(Code),@Code);{$endif}
    glGetVertexAttribiv(4,GL_VERTEX_ATTRIB_ARRAY_INTEGER,@IsInteger);
    glGetVertexAttribiv(4,GL_VERTEX_ATTRIB_ARRAY_TYPE,@Kind);
    glGetVertexAttribiv(4,GL_VERTEX_ATTRIB_ARRAY_DIVISOR_QUERY,@Divisor);
    Result:=(Code=Expected) and (IsInteger=GL_TRUE) and (Kind=GL_UNSIGNED_INT) and (Divisor=1);
  finally glBindVertexArray(OldVAO); glBindBuffer(GL_ARRAY_BUFFER,OldBuffer); end;
end;
procedure TTreeRenderer.SetPassUniforms(const Projection,View:TTreeMat4; const Eye:TTreeVec3; Seconds:Single);
var Samples:GLint;
begin
    glEnable(GL_DEPTH_TEST); glDepthFunc(GL_LEQUAL); glDepthMask(GL_TRUE); glDisable(GL_BLEND); glDisable(GL_CULL_FACE);
    glUseProgram(FProgram);
    glUniform1i(UFragmentWorkReuse,Ord(TreeFragmentWorkReuse));
    if UCoverageSamples>=0 then begin
      { Read the currently bound target once per pass: shadow/atlas FBOs may
        have no MSAA even when the main window has it. No GL state is changed. }
      glGetIntegerv(GL_SAMPLES,@Samples);
      if (Samples<2) or (Samples>32) or ((Samples and (Samples-1))<>0) then Samples:=1;
      {$ifndef OpenGLES}if glIsEnabled(GL_MULTISAMPLE)=GL_FALSE then Samples:=1;{$endif}
      glUniform1i(UCoverageSamples,Samples);
    end;
    if FBakeMode then glUniform1i(UComplexity,3) else glUniform1i(UComplexity,TreeRenderComplexity);
    if FEnvironment.Enabled then begin
      glUniform3fv(USunDirection,1,@FEnvironment.SunDirection);
      glUniform3fv(UBillboardRight,1,@FEnvironment.BillboardRight);
      glUniform3fv(UFogColor,1,@FEnvironment.FogColor);
      glUniform1f(UFogDensity,FEnvironment.FogDensity);
      glUniform1f(UOutputGamma,FEnvironment.OutputGamma);
      glUniform1i(UDepthOnly,Ord(FEnvironment.DepthOnly));
      glUniform1i(UShadowPartitions,FEnvironment.ShadowPartitions);
      glUniform1i(UShadowPartition,FEnvironment.ShadowPartition);
    end else begin
      glUniform3f(USunDirection,-0.5,0.85,0.45);
      glUniform3f(UBillboardRight,View[0],0,View[8]);
      glUniform3f(UFogColor,0.19,0.26,0.27);
      glUniform1f(UFogDensity,0.0014); glUniform1f(UOutputGamma,1/2.2);
      glUniform1i(UDepthOnly,0);
      glUniform1i(UShadowPartitions,0);glUniform1i(UShadowPartition,0);
    end;
    glUniformMatrix4fv(UProjection,1,GL_FALSE,@Projection[0]);
    glUniformMatrix4fv(UView,1,GL_FALSE,@View[0]);
    glUniform3f(UEye,Eye.X,Eye.Y,Eye.Z);glUniform1f(UTime,Seconds);
end;
function TTreeRenderer.UniformChanged(Location:GLint;X,Y,Z,W:Single):Boolean;
begin
  if Location<0 then Exit(False);
  if Location>=Length(FUniformCache) then Exit(True);
  with FUniformCache[Location] do begin
    Result:=not Valid or (Value[0]<>X) or (Value[1]<>Y) or (Value[2]<>Z) or (Value[3]<>W);
    if Result then begin Valid:=True;Value[0]:=X;Value[1]:=Y;Value[2]:=Z;Value[3]:=W;end;
  end;
end;
procedure TTreeRenderer.Uniform1i(Location:GLint;Value:Integer);
begin if UniformChanged(Location,Value,0,0,0) then glUniform1i(Location,Value);end;
procedure TTreeRenderer.Uniform1f(Location:GLint;Value:Single);
begin if UniformChanged(Location,Value,0,0,0) then glUniform1f(Location,Value);end;
procedure TTreeRenderer.Uniform3f(Location:GLint;X,Y,Z:Single);
begin if UniformChanged(Location,X,Y,Z,0) then glUniform3f(Location,X,Y,Z);end;
procedure TTreeRenderer.Uniform4f(Location:GLint;X,Y,Z,W:Single);
begin if UniformChanged(Location,X,Y,Z,W) then glUniform4f(Location,X,Y,Z,W);end;
procedure TTreeRenderer.BeginBatch(const Projection,View:TTreeMat4; const Eye:TTreeVec3;
  const Env:TTreeRenderEnvironment; Seconds:Single);
begin
  if not TreePassBatching then Exit;
  Assert(FShared=nil);
  FEnvironment:=Env;
  if Length(FUniformCache)>0 then FillChar(FUniformCache[0],Length(FUniformCache)*SizeOf(FUniformCache[0]),0);
  SetPassUniforms(Projection,View,Eye,Seconds);
  FBatchActive:=True;
end;
procedure TTreeRenderer.EndBatch;
begin FBatchActive:=False end;
procedure TTreeRenderer.Render(const Instance: TTreeInstance; const P: TTreeParams;
  const Projection,View,Model: TTreeMat4; const Eye: TTreeVec3;
  Quality,Seconds,Wind: Single; Wireframe,Debug,ShowLeaves,ShowGround,ShowForest: Boolean;
  PreserveGLState: Boolean);
var OldProgram,OldVAO,OldBuffer,OldDepthFunc: GLint; OldPolygon: array[0..1] of GLint;
    WasDepth,WasBlend,WasCull,OldDepthMask: GLBoolean; Slices,Segments,Count,D,J: Integer; Bytes: Int64;
    Actual: TTreeParams; Resources: TTreeRenderer; UseAtlas: Boolean; OldActiveTexture,OldTexture,OldNormalTexture: GLint;
    Viewport: array[0..3] of GLint; SeasonState: TTreeSeasonState;
    DirectBranches: Boolean; G,FullPairs,ViewHeight,FruitMembers,WoodSlices,WoodSegments:Integer;NeedleIndexBuffer:GLuint;
    NeedleDetail,RenderWind,FruitAmount,FruitPixels,EyeDistance,LeafGroup,LeafBudget,LeafFade,WoodPixels,CompactMix:Single;
begin
  if not FReady then Exit;
  Bytes:=FStats.UploadBytes; FStats:=Default(TTreeRenderStats); FStats.UploadBytes:=Bytes;
  FStats.FarMinHeight:=FFarMinHeight; FStats.FarMaxHeight:=FFarMaxHeight;
  { Identity and profile are stable across colour/shadow passes. Resolving age,
    growth and dimensions involves exp/power and validation; do it only when
    an input actually changes. Includes every input, also for editor changes. }
  if TreeParameterCache and FResolvedValid and
     CompareMem(@Instance,@FResolvedInstance,SizeOf(Instance)) and
     CompareMem(@P,@FResolvedProfile,SizeOf(P)) then begin
    Actual:=FResolvedParams;Inc(TreeParameterReuses);
  end else begin
    Actual:=ResolveTreeParams(Instance,P);
    FResolvedInstance:=Instance;FResolvedProfile:=P;FResolvedParams:=Actual;
    FResolvedValid:=True;Inc(TreeParameterCalculations);
  end;
  DirectBranches:=(FEnvironment.Enabled and FEnvironment.DirectBranches) or
    (P.Species in [tsBamboo,tsPalm,tsFanPalm,tsCactus,tsPricklyPear]);
  Resources:=Self; if Assigned(FShared) then Resources:=FShared;
  SeasonState:=EvaluateTreeSeason(P.Species,P.LeafColor,Resources.FSeason);
  if FBakeMode then SeasonState:=EvaluateTreeSeason(P.Species,P.LeafColor,TREE_SUMMER);
  FruitAmount:=TreeFruitAmount(P.Species,Resources.FSeason);
  if FBakeMode then FruitAmount:=1;
  { Fully detailed trees do not draw an atlas: avoid two texture binds and
    atlas frame/normal state for every tree in every shadow cascade. }
  UseAtlas:=((Quality<0.95) or (ShowForest and (FForestCount>1))) and
    FUseBakedLOD and not FBakeMode and ShowLeaves and HasLODAtlas(P);
  if UseAtlas and not Resources.FLODSeasonParts[P.Species] and
    (Abs(WrapTreeSeason(Resources.FSeason)-TREE_SUMMER)>0.0001) then UseAtlas:=False;
  if PreserveGLState then begin
  glGetIntegerv(GL_ACTIVE_TEXTURE,@OldActiveTexture); glActiveTexture(GL_TEXTURE0);
  glGetIntegerv(GL_TEXTURE_BINDING_2D_ARRAY,@OldTexture);
  glActiveTexture(GL_TEXTURE1);glGetIntegerv(GL_TEXTURE_BINDING_2D_ARRAY,@OldNormalTexture);glActiveTexture(GL_TEXTURE0);
  glGetIntegerv(GL_CURRENT_PROGRAM,@OldProgram); glGetIntegerv(GL_VERTEX_ARRAY_BINDING,@OldVAO);
  glGetIntegerv(GL_ARRAY_BUFFER_BINDING,@OldBuffer);
  {$ifndef OpenGLES}glGetIntegerv(GL_POLYGON_MODE,@OldPolygon[0]);{$endif}
  glGetIntegerv(GL_DEPTH_FUNC,@OldDepthFunc); glGetBooleanv(GL_DEPTH_WRITEMASK,@OldDepthMask);
  WasDepth:=glIsEnabled(GL_DEPTH_TEST); WasBlend:=glIsEnabled(GL_BLEND); WasCull:=glIsEnabled(GL_CULL_FACE);
  end;
  try
    if PreserveGLState or not Resources.FBatchActive then begin
      SetPassUniforms(Projection,View,Eye,Seconds);
      if Length(Resources.FUniformCache)>0 then
        FillChar(Resources.FUniformCache[0],Length(Resources.FUniformCache)*SizeOf(Resources.FUniformCache[0]),0);
    end;
    if FBakeMode then Resources.Uniform1i(UBakeMode,Max(1,FBakeOutput)) else Resources.Uniform1i(UBakeMode,0); Resources.Uniform1i(UUseBakedLOD,Ord(UseAtlas));
    Resources.Uniform1i(UDirectBranches,Ord(DirectBranches));
    Resources.Uniform1i(UPreparedFrames,Ord(TreePreparedFrames and FPreparedFrames));
    Resources.Uniform4f(ULeafSpray,LeafSprayRows(P.Species),LeafSprayAspect(P.Species),LeafSprayIndex(P.Species)*8,1);
    Resources.Uniform1i(ULeafSprays,0);
    Resources.Uniform1f(UNeedleScale,1);
    NeedleDetail:=1;
    if DirectBranches and not FBakeMode then NeedleDetail:=Clamp(FEnvironment.NeedleDetail,0,1);
    { A retained shoot can represent several neighbouring shoots. Keep its
      integrated foliage until the full close-up descriptors fit the cache;
      otherwise switching to single needles would discard that coverage. }
    CompactMix:=Clamp((FSourceShootCount/Max(1,FNeedleShootCount)-1)*2,0,1);
    NeedleDetail:=NeedleDetail*(1-CompactMix*CompactMix*(3-2*CompactMix));
    if (TreeRenderComplexity<3) and not FBakeMode then NeedleDetail:=0;
    RenderWind:=Wind;
    if FEnvironment.Enabled and FEnvironment.DepthOnly and IsConifer(P.Species) and not FBakeMode then begin
      { Filter sub-texel needle motion in shadows. Wood and foliage share the
        reduced sway, so their shadow silhouettes stay attached. Individual
        needles and their viewer-dependent LOD are only needed in colour. }
      RenderWind:=Wind*0.15;
      if DirectBranches then NeedleDetail:=0;
    end;
    Resources.Uniform1f(UNeedleDetail,NeedleDetail);
    Resources.Uniform1f(USeasonLeaf,SeasonState.LeafAmount);
    Resources.Uniform3f(ULeafRatio,SeasonState.LeafColor.X/Max(0.0001,P.LeafColor.X),
      SeasonState.LeafColor.Y/Max(0.0001,P.LeafColor.Y),SeasonState.LeafColor.Z/Max(0.0001,P.LeafColor.Z));
    Resources.Uniform1i(ULODSeasonParts,Ord(Resources.FLODSeasonParts[P.Species]));
    Resources.Uniform1i(ULODFruitLayer,Ord(Resources.FLODFruitLayer[P.Species]));
    Resources.Uniform1f(UFruitAmount,FruitAmount);Resources.Uniform1i(UFruitMembers,FFruitMembers);
    Resources.Uniform1i(ULODTexture,0);Resources.Uniform1i(ULODNormal,1);Resources.Uniform1i(ULODRelight,Ord(Resources.FLODRelight[P.Species]));
    if UseAtlas then begin
      glActiveTexture(GL_TEXTURE1);glBindTexture(GL_TEXTURE_2D_ARRAY,Resources.FLODNormals[P.Species]);glActiveTexture(GL_TEXTURE0);
      glBindTexture(GL_TEXTURE_2D_ARRAY,Resources.FLODTextures[P.Species]);
      glUniform3fv(ULODFrames,LOD_AGES,@Resources.FLODFrames[P.Species][0].X);
    end;
    glUniformMatrix4fv(UModel,1,GL_FALSE,@Model[0]);Resources.Uniform1f(UWind,RenderWind);
    if FEnvironment.Enabled and (FEnvironment.ViewportHeight>0) then
      ViewHeight:=FEnvironment.ViewportHeight
    else begin glGetIntegerv(GL_VIEWPORT,@Viewport[0]);ViewHeight:=Max(1,Viewport[3]);end;
    Resources.Uniform1f(UViewportHeight,ViewHeight);
    Resources.Uniform4f(UProfile,Actual.Height,Actual.TrunkRadius,Actual.CrownSpread,Actual.CrownStart);
    Resources.Uniform3f(UBark,P.BarkColor.X,P.BarkColor.Y,P.BarkColor.Z);
    Resources.Uniform3f(UBarkTint,P.BarkColor.X/Max(0.001,FBarkDefault[P.Species].X),
      P.BarkColor.Y/Max(0.001,FBarkDefault[P.Species].Y),P.BarkColor.Z/Max(0.001,FBarkDefault[P.Species].Z));
    Resources.Uniform3f(ULeaf,SeasonState.LeafColor.X,SeasonState.LeafColor.Y,SeasonState.LeafColor.Z);
    Resources.Uniform1i(USpecies,Ord(P.Species)); Resources.Uniform1i(UDebug,Ord(Debug));
    Resources.Uniform1f(UDensity,P.LeafDensity*Ord(ShowLeaves));
    Resources.Uniform1f(UQuality,Quality);
    if ShowGround then Draw(4,3,6,1,0,CardIndices);
    {$ifndef OpenGLES}if Wireframe then glPolygonMode(GL_FRONT_AND_BACK,GL_LINE);{$endif}
    if ShowForest and (FForestCount>1) and (Quality<=0.35) then begin
      Resources.Uniform1f(UQuality,0); Draw(3,3,6,FForestCount,0,CardIndices); FStats.FarTrees:=FForestCount;
      Resources.Uniform1f(UQuality,Quality);
    end else if ShowForest and (FForestCount>1) then begin
      Resources.Uniform1f(UQuality,0);
      { The first instance is the selected tree. Offset attributes to skip it. }
      glBindVertexArray(FVAO[3]); glBindBuffer(GL_ARRAY_BUFFER,FVBO[3]);
      for J:=0 to 3 do glVertexAttribPointer(J,4,GL_FLOAT,GL_FALSE,SizeOf(TTreeGPUItem),Pointer(PtrUInt(64+J*16)));
      glVertexAttribIPointer(4,1,GL_UNSIGNED_INT,SizeOf(TTreeGPUItem),Pointer(PtrUInt(64+52)));
      Draw(3,3,6,FForestCount-1,0,CardIndices); FStats.FarTrees:=FForestCount-1;
      for J:=0 to 3 do glVertexAttribPointer(J,4,GL_FLOAT,GL_FALSE,SizeOf(TTreeGPUItem),Pointer(PtrUInt(J*16)));
      glVertexAttribIPointer(4,1,GL_UNSIGNED_INT,SizeOf(TTreeGPUItem),Pointer(PtrUInt(52)));
      Resources.Uniform1f(UQuality,Quality);
    end;
    if (Quality<0.95) and not (ShowForest and (FForestCount>1) and (Quality<=0.35)) then begin
      Draw(3,3,6,Min(1,FForestCount),0,CardIndices); Inc(FStats.FarTrees,Min(1,FForestCount));
    end;
    if Quality>0.35 then begin
      if Quality>2.4 then begin Slices:=9; Segments:=5; end else begin Slices:=5; Segments:=3; end;
      if (P.Species=tsMountainPine) and (Quality>2.4) then Segments:=12;
      if FEnvironment.Enabled then begin
        if FEnvironment.BranchSides>0 then Slices:=FEnvironment.BranchSides;
        if FEnvironment.BranchSegments>0 then Segments:=FEnvironment.BranchSegments;
      end;
      if not FBakeMode then begin
        if TreeRenderComplexity=0 then begin Slices:=3;Segments:=1 end
        else if TreeRenderComplexity=1 then begin Slices:=Min(Slices,4);Segments:=Min(Segments,2) end;
      end;
      if P.Species=tsCactus then begin Slices:=Max(Slices,12);Segments:=Max(Segments,10);end;
      Resources.Uniform1i(USlices,Slices); Resources.Uniform1i(USegments,Segments);
      Count:=FDepthCounts[0];
      for D:=1 to 4 do if DirectBranches or (BranchGrowth(D,Quality)>0) then Inc(Count,FDepthCounts[D]);
      if not FBakeMode or (FBakePart in [0,1]) then begin
        if not (FEnvironment.Enabled and FEnvironment.DepthOnly) then
          glBindTexture(GL_TEXTURE_2D_ARRAY,Resources.FBarkTextures);
        EyeDistance:=Max(0.1,Magnitude(Sub(Eye,Vec(Model[12],Model[13]+Actual.Height*0.25,Model[14]))));
        WoodPixels:=Actual.TrunkRadius*0.5*ViewHeight*Abs(Projection[5])/EyeDistance;
        if ((Ord(P.Species)<14) or (P.Species in [tsEucalyptus,tsAcacia])) and
          (Count>=FPrimaryCount) and (FBakeMode or ((WoodPixels>4) and (TreeRenderComplexity>=2))) then begin
          { Spend vertices on visible structural wood, not thousands of tiny shoots. }
          if FBakeMode or (WoodPixels>14) then begin WoodSlices:=12;WoodSegments:=12 end
          else begin WoodSlices:=8;WoodSegments:=8 end;
          Resources.Uniform1i(USlices,WoodSlices);Resources.Uniform1i(USegments,WoodSegments);
          Draw(0,0,WoodSlices*WoodSegments*6,FPrimaryCount,0,GridIndices(WoodSlices,WoodSegments));
          Slices:=Min(Slices,5);Segments:=Min(Segments,3);
          Resources.Uniform1i(USlices,Slices);Resources.Uniform1i(USegments,Segments);
          Draw(0,0,Slices*Segments*6,Count-FPrimaryCount,FBranchFineVAO,GridIndices(Slices,Segments));
        end else Draw(0,0,Slices*Segments*6,Count,0,GridIndices(Slices,Segments));
        FStats.Branches:=Count;
      end;
      if (P.Species=tsPricklyPear) and (not FBakeMode or (FBakePart in [0,1])) then begin
        Resources.Uniform1i(USlices,8);Resources.Uniform1i(USegments,8);
        Draw(8,1,8*8*6,FLeafCount,0,GridIndices(8,8));FStats.Leaves:=FLeafCount;
      end;
      if ShowLeaves and (P.LeafDensity>0) and (SeasonState.LeafAmount>0.0001) and (not FBakeMode or (FBakePart in [0,2])) then begin
        if (Quality<4) and not DirectBranches then begin
          Resources.Uniform1i(USlices,8); Resources.Uniform1i(USegments,5);
          Draw(2,2,8*5*6,FCrownCount,0,GridIndices(8,5)); FStats.Proxies:=FCrownCount;
        end;
        if DirectBranches or (Quality>3.4) then begin
          if IsConifer(P.Species) then begin
            Resources.Uniform4f(ULeafBudget,0,0,
              Sqrt(FSourceShootCount/Max(1,FNeedleShootCount)),0);
            Resources.Uniform1i(UNeedlesPerFascicle,FNeedlesPerFascicle);
            Resources.Uniform1i(UNeedleVertices,NeedleVertices(P.Species));
            NeedleIndexBuffer:=0;
            if (NeedleDetail>0) and (NeedleVertices(P.Species)=9) then NeedleIndexBuffer:=NeedleIndices;
            for G:=0 to NEEDLE_DENSITY_GROUPS-1 do if FNeedleGroups[G].Count>0 then begin
              FullPairs:=NEEDLE_GROUP_PAIRS[G];Count:=FullPairs;
              if NeedleDetail<1 then begin
                Resources.Uniform1i(UNeedlePairs,FullPairs);
                Draw(6,4,12,FNeedleGroups[G].Count,FNeedleVAO[G],GridIndices(1,2));
                Inc(FStats.Shoots,FNeedleGroups[G].Count);
              end;
              if NeedleDetail<=0 then Continue;
              if DirectBranches then
                Count:=DrawNeedlePairs(FullPairs,FNeedleShootCount,P.Species,
                  FEnvironment.LeafFraction,FEnvironment.NeedleDetail);
              if Count>0 then Resources.Uniform1f(UNeedleScale,FullPairs/Count);
              Resources.Uniform1i(UNeedlePairs,Count);
              Draw(5,4,Count*FNeedlesPerFascicle*NeedleVertices(P.Species),FNeedleGroups[G].Count,FNeedleVAO[G],NeedleIndexBuffer);
              Inc(FStats.Needles,FNeedleGroups[G].Count*Count*FNeedlesPerFascicle);
            end;
          end else begin
            Count:=FLeafCount;LeafBudget:=Count;LeafFade:=0;
            LeafGroup:=Sqrt(FSourceLeafCount/Max(1,FLeafCount));
            if DirectBranches and not FBakeMode and (Count>0) and
               (FEnvironment.LeafFraction>0) then begin
              { Memory compaction and drawing share ONE coverage budget. A
                compressed tree must not lose another 75% of its twigs here. }
              LeafBudget:=Min(Count,FSourceLeafCount*Clamp(FEnvironment.LeafFraction,0.25,1));
              LeafFade:=Min(Count*0.025,(Count-LeafBudget)*0.5);
              Count:=Min(FLeafCount,Max(1,Ceil(LeafBudget+LeafFade*0.5)));
              LeafGroup:=Sqrt(FSourceLeafCount/Max(1,LeafBudget));
            end;
            Resources.Uniform4f(ULeafBudget,LeafBudget,LeafFade,
              Sqrt(FSourceLeafCount/Max(1,FLeafCount)),0);
            { Group subpixel foliage on fewer cards. UVs repeat in world units:
              the card grows, the blades do not. Full geometry stays nearby. }
            Resources.Uniform4f(ULeafSpray,LeafSprayRows(P.Species),LeafSprayAspect(P.Species),LeafSprayIndex(P.Species)*8,LeafGroup);
            if LeafSprayIndex(P.Species)>=0 then glBindTexture(GL_TEXTURE_2D_ARRAY,Resources.FLeafSprays);
            Draw(1,1,6,Count,0,CardIndices);FStats.Leaves:=Count;
          end;
        end;
      end;
      if (FFruitCount>0) and ShowLeaves and (FruitAmount>0.001) and
         (DirectBranches or (Quality>3.4)) and (not FBakeMode or (FBakePart in [0,3])) then begin
        EyeDistance:=Max(0.1,Magnitude(Sub(Eye,
          Vec(Model[12],Model[13]+Actual.Height*0.55,Model[14])))-Actual.Height*0.2);
        FruitPixels:=FFruitRadius*ViewHeight*Abs(Projection[5])/EyeDistance;
        if FBakeMode or (FruitPixels>0.4) then begin
          FruitMembers:=FFruitMembers;
          { A few-pixel bunch is one surface, not dozens of subpixel spheres. }
          if not FBakeMode and ((FruitPixels<10) or
            ((Actual.Species=tsRowan) and (FruitPixels<18))) then FruitMembers:=1;
          Resources.Uniform1i(UFruitMembers,FruitMembers);
          { A rowan bunch contains 36 berries: tessellate individual berries
            finely only in close-up, not when the whole bunch is a few pixels. }
          if FBakeMode or ((FruitPixels>12) and (Actual.Species<>tsRowan)) or
             (FruitPixels>32) then begin Slices:=8;Segments:=5 end
          else begin Slices:=6;Segments:=3 end;
          Resources.Uniform1i(USlices,Slices);Resources.Uniform1i(USegments,Segments);
          Draw(7,5,(Slices*Segments*6+12*Ord(FruitMembers>1))*FruitMembers+24,FFruitCount);
          FStats.Fruits:=FFruitCount*FruitMembers;
        end;
      end;
    end;
    if UseAtlas then FStats.BakedFarTrees:=FStats.FarTrees;
  finally
    if PreserveGLState then begin
    glActiveTexture(GL_TEXTURE1);glBindTexture(GL_TEXTURE_2D_ARRAY,OldNormalTexture);
      glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_2D_ARRAY,OldTexture); glActiveTexture(OldActiveTexture);
    glUseProgram(OldProgram); glBindVertexArray(OldVAO); glBindBuffer(GL_ARRAY_BUFFER,OldBuffer);
    {$ifndef OpenGLES}glPolygonMode(GL_FRONT_AND_BACK,OldPolygon[0]);{$endif}
    glDepthFunc(OldDepthFunc); glDepthMask(OldDepthMask);
    if WasDepth=GL_TRUE then glEnable(GL_DEPTH_TEST) else glDisable(GL_DEPTH_TEST);
    if WasBlend=GL_TRUE then glEnable(GL_BLEND) else glDisable(GL_BLEND);
    if WasCull=GL_TRUE then glEnable(GL_CULL_FACE) else glDisable(GL_CULL_FACE);
    end;
  end;
end;
initialization
  TreePreparedFrames:=TreePreparedFramesExperimentEnabled;
end.
