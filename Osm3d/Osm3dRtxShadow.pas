unit Osm3dRtxShadow;
{$ifdef ANDROID}{$define OpenGLES}{$endif}
{$mode objfpc}{$H+}
interface
uses Classes, SysUtils, Dynlibs, Generics.Collections, CastleVectors, CastleBoxes,
  CastleTriangles, CastleShapes, CastleTransform, TreeRenderer, TreeModel,
  fpjson, X3DNodes{$ifndef OpenGLES}, Osm3dRtxDynamic{$endif};
const
  RTX_SCREEN_MAX_RAY_DISTANCE = 1000000;
type
  TRtxCard = packed record Origin,U,V,Spare:TVector4; end;
  TRtxZone = packed record Origin,DU,DV,Ray:TVector4; end;
  TRtxZones = array[0..3] of TRtxZone;
  TRtxSurface=packed record Normal,Color,UV0,UV1,UV2:TVector4;end;
  TRtxReflectionCamera=packed record
    InverseProjection,InverseView:TMatrix4;
    Sun,Horizon,Zenith,DepthRange:TVector4;
  end;
  TRtxDrawReflectors=procedure(const Params:TRenderParams) of object;
  TRtxStats = packed record
    SceneID,Triangles,Cards,Bytes,Frames,Builds:QWord;
    TraceMS,BuildMS:Double;
  end;
  TRtxProjection = record
    Layer:Integer;
    Origin,U,V:TVector3;
    Used:QWord;
  end;
  TRtxShapeFilter = function(const Shape:TShape):Boolean of object;
  { Optional ray-query backend. Static world snapshots are collected in bounded
    steps; screen mode adds posed riders on the GPU. The atlas mode can use
    raster fallback while warming up; the exclusive screen mode cannot. }
  TRtxShadow = class
  private
    FLibrary:TLibHandle;
    FContext:Pointer;
    FInitialized,FStandaloneRaster:Boolean;
    FStandaloneAlpha:Cardinal;
    FCreate:function(Shader:PWideChar;Size,AlphaSize,Layers:Cardinal):Pointer;cdecl;
    FDestroy:procedure(Context:Pointer);cdecl;
    FErrorText:function:PChar;cdecl;
    FDeviceName:function(Context:Pointer):PChar;cdecl;
    FAlphaTexture,FOutputTexture:function(Context:Pointer):Cardinal;cdecl;
    FSetScene:function(Context:Pointer;Vertices:Pointer;Triangles:Cardinal;Cards:Pointer;Count:Cardinal;ID:QWord):LongInt;cdecl;
    FSetSceneMaterials:function(Context:Pointer;Vertices:Pointer;Triangles:Cardinal;Cards:Pointer;Count:Cardinal;ID:QWord;Surfaces:Pointer):LongInt;cdecl;
    FReflectionSize:function(Context:Pointer;Shader:PWideChar;W,H:Cardinal):LongInt;cdecl;
    FReflectionTexture:function(Context:Pointer;Index:LongInt):Cardinal;cdecl;
    FReflect:function(Context:Pointer;Camera:Pointer;Scene:QWord):LongInt;cdecl;
    FReflectionMS:function(Context:Pointer):Double;cdecl;
    FScreenSize:function(Context:Pointer;Shader:PWideChar;W,H:Cardinal):LongInt;cdecl;
    FScreenTexture:function(Context:Pointer;Index:LongInt):Cardinal;cdecl;
    FScreenReuseTexture:function(Context:Pointer):Cardinal;cdecl;
    FScreenTrace:function(Context:Pointer;Camera:Pointer;Scene:QWord):LongInt;cdecl;
    FScreenMS:function(Context:Pointer):Double;cdecl;
    FScreenBytes:function(Context:Pointer):QWord;cdecl;
    FDynamicBuffer:function(Context:Pointer;Triangles:Cardinal):Cardinal;cdecl;
    FDynamicStat:function(Context:Pointer;Field:Cardinal):QWord;cdecl;
    FDynamicCasters:TCastleTransformList;
    {$ifndef OpenGLES}FDynamicMeshes:TRtxDynamicMeshes;{$endif}
    FScreenComposite:Cardinal;
    FScreenStrength:Single;
    FScreenFilter:Integer;
    FScreenCamera:TRtxReflectionCamera;
    FScreenReuseActive:Boolean;
    FScreenRevision,FScreenLastScene:QWord;
    FScreenLastSun:TVector3;
    FScreenLastFilter:Integer;
    FScreenLastSunRadius:Single;
    FScreenLastRayCount:Integer;
    FReflectionRanges:TVector3;
    FTrace:function(Context:Pointer;Zones:Pointer;SceneID:QWord):LongInt;cdecl;
    FReadStats:function(Context:Pointer;Stats:Pointer):LongInt;cdecl;
    FFrameWaits:function(Context:Pointer):QWord;cdecl;
    FGroundTriangles:function(Context:Pointer):Cardinal;cdecl;
    FSlots:specialize TDictionary<string,TRtxProjection>;
    FActiveLayers,FBuildLayers:array[0..1023]of Boolean;
    FVertices:array of TVector3;
    FSurfaces:array of TRtxSurface;
    FSurfaceColor:TVector3;
    FShapeIFS:TIndexedFaceSetNode;
    FGroundShape:Boolean;
    FGroundIndex:Integer;
    FBldUV,FBldMat:TFloatVertexAttributeNode;
    FBuildingAtlas:TAbstractTextureNode;
    FBuildingGrid:TVector2;
    FUploadedAtlas,FRgbaCopyProgram:Cardinal;
    FReflectionFBO:Cardinal;
    FReflections:Boolean;
    FScreenShadows:Boolean;
    FScreenFBO:Cardinal;
    FScreenError:string;
    FScreenFrames:QWord;
    FScreenWidth,FScreenHeight:Integer;
    FReflectionError:string;
    FReflectionFrames,FTraceFallbacks,FReflectionDrops:QWord;
    FDebugReflections:Boolean;
    FDebugReceivers,FDebugHits,FDebugHorizontalReceivers,FDebugHorizontalHits:Integer;
    FDebugTracedReflections,FDebugCachedReflections:Integer;
    FCards:array of TRtxCard;
    FVertexCount,FCardCount,FSource,FShape,FCell,FEntry,FAtlasSize:Integer;
    FBuildOrigin,FActiveOrigin,FLastFocus,FActiveFocus,FSun,FSide,FUp:TVector3;
    FPrefetchOffset:TVector3;
    FRevision,FBuildID,FSubmittedID:QWord;
    FCollectionSerial:QWord;
    FActiveRevision:QWord;
    FActiveSceneID:QWord;
    FObservedTrees,FBuildTrees,FActiveTrees:QWord;
    FDeferredTrees,FActiveDeferredTrees:Integer;
    FBuildNear:Integer;
    FCollecting,FWaiting,FFailed,FActive:Boolean;
    FError,FDevice:string;
    FStats:TRtxStats;
    FTransform:TMatrix4;
    FHalfExtent:Single;
    FDeadline:QWord;
    FBakesThisStep,FBakedTrees,FReusedProjections:Integer;
    FFramebuffer,FVAO,FDepthProgram,FCopyProgram:Cardinal;
    FRasterComparison,FBuiltRasterComparison:Boolean;
    FCardVAO,FCardBuffer,FCardProgram:Cardinal;
    FRasterCards:Integer;
    FLastZones:TRtxZones;
    {$ifndef OpenGLES}
    procedure Initialize(Size:Integer);
    procedure Release;
    procedure Fail(const Msg:string);
    procedure AddTriangle(Shape:TObject;const Triangle,Normal:TTriangle3;
      const TexCoord:TTriangle4;const Face:TFaceIndex);
    function CollectGround:Boolean;
    procedure CopyLOD(const Layer:Integer;Texture:Cardinal;Source:Integer;
      Seasonal,Fruit:Boolean;Leaf,FruitAmount:Single);
    procedure AppendCard(const P:TRtxProjection;const Position:TVector3;Phase:Single);
    procedure UploadCards;
    function AllocateLayer:Integer;
    function AlphaTexture:Cardinal;
    {$endif}
    procedure SetReflections(Value:Boolean);
    procedure SetScreenShadows(Value:Boolean);
    function GetScreenReady:Boolean;
    function GetReflectionsReady:Boolean;
    function ScreenSunRadius:Single;
    function ScreenRayCount:Integer;
  public
    constructor Create;
    destructor Destroy;override;
    procedure Prepare(const Casters:TCastleTransformList;Revision:QWord;
      const Focus,Sun:TVector3;Size:Integer;HalfExtent:Single;Accept:TRtxShapeFilter);
    function Intersects(const Box:TBox3D):Boolean;
    function AddTree(const Instance:TreeModel.TTreeInstance;const Profile:TTreeParams;
      const Position:TVector3;Renderer,Shared:TTreeRenderer;Season:Single):Boolean;
    function TimeAvailable:Boolean;
    procedure DeferTrees(Count:Integer);
    function Trace(const Zones:TRtxZones):Boolean;
    procedure CopyDepth;
    procedure DrawCachedRaster(Zone:Integer);
    procedure Snapshot(const J:TJSONObject);
    procedure DiagnosticDepth(const J:TJSONObject);
    function ScreenImage(Index:Integer):Cardinal;
    procedure RenderReflections(const Params:TRenderParams;Draw:TRtxDrawReflectors);
    procedure RenderScreenShadows(const Params:TRenderParams;Draw:TRtxDrawReflectors);
    procedure CompositeScreenShadows;
    procedure SetDynamicCasters(const Casters:TCastleTransformList);
    { The active screen pass traces toward ToSun; its caster volume extends
      in the opposite direction. False means that callers must not cull. }
    function TryGetScreenCasterRay(out ToSun:TVector3;
      out MaxRayDistance,ConeTangent:Single):Boolean;
    property ScreenStrength:Single read FScreenStrength write FScreenStrength;
    property ScreenFilter:Integer read FScreenFilter write FScreenFilter;
    property Origin:TVector3 read FActiveOrigin;
    property Ready:Boolean read FActive;
    property Failed:Boolean read FFailed;
    property RasterComparison:Boolean read FRasterComparison write FRasterComparison;
    property Reflections:Boolean read FReflections write SetReflections;
    property ReflectionsReady:Boolean read GetReflectionsReady;
    property ScreenShadows:Boolean read FScreenShadows write SetScreenShadows;
    property ScreenReady:Boolean read GetScreenReady;
    property ScreenReuseActive:Boolean read FScreenReuseActive write FScreenReuseActive;
    property ScreenRevision:QWord read FScreenRevision;
    { Camera-depth ranges: live far, refreshed slab near/far. X=0 disables. }
    property ReflectionRanges:TVector3 read FReflectionRanges write FReflectionRanges;
    property DebugReflections:Boolean read FDebugReflections write FDebugReflections;
    property PrefetchOffset:TVector3 read FPrefetchOffset write FPrefetchOffset;
  end;
implementation

{$ifdef OpenGLES}
{$I Osm3dRtxUnavailable.inc}
{$else}
uses Math, {$ifdef OpenGLES}CastleGLES{$else}CastleGL{$endif}, CastleLog, CastleScene, CastleSceneCore,
  CastleUriUtils, TreeMath, TreeLOD, TreeSeason, Osm3dProceduralVegetation,
  Osm3dStudioSettings, Osm3dRenderInstanced, Osm3dRtxMaterials,
  CastleRenderContext, CastleRectangles, CastleRenderOptions, X3DFields,
  CastleInternalRenderer, Osm3dBuildingComposite, Osm3dGroundComposite, Osm3dRtxScreenState;
const
  ALPHA_SIZE=256;
  ALPHA_LAYERS=1024;
  GL_FRAMEBUFFER_SRGB_RTX=$8DB9;
  CARD_COVERAGE_GLSL = 'float threshold(vec2 uv,float phase){vec2 p=floor(uv*256.)+phase*vec2(971.,613.);return max(.003,fract(sin(dot(p,vec2(12.9898,78.233)))*43758.5453));}';
type
  { Every direct GL change is restored: CGE caches these states. }
  TGLState = record
    DrawFBO,ReadFBO,Viewport:array[0..3]of GLint;
    ProgramID,VAO,ActiveTexture,Texture2D,TextureArray,DepthFunc:GLint;
    DepthMask,ColorMask:array[0..3]of GLBoolean;
    ClearColor:array[0..3]of GLfloat;
    DepthRange:array[0..1]of GLdouble;
    Depth,Cull,Blend,Scissor,SRGB:GLBoolean;
  end;
procedure SaveGL(out S:TGLState);
begin
  glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING,@S.DrawFBO[0]);glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING,@S.ReadFBO[0]);
  glGetIntegerv(GL_VIEWPORT,@S.Viewport[0]);glGetIntegerv(GL_CURRENT_PROGRAM,@S.ProgramID);
  glGetIntegerv(GL_VERTEX_ARRAY_BINDING,@S.VAO);glGetIntegerv(GL_ACTIVE_TEXTURE,@S.ActiveTexture);
  glActiveTexture(GL_TEXTURE0);glGetIntegerv(GL_TEXTURE_BINDING_2D,@S.Texture2D);glGetIntegerv(GL_TEXTURE_BINDING_2D_ARRAY,@S.TextureArray);
  glGetIntegerv(GL_DEPTH_FUNC,@S.DepthFunc);glGetBooleanv(GL_DEPTH_WRITEMASK,@S.DepthMask[0]);
  glGetBooleanv(GL_COLOR_WRITEMASK,@S.ColorMask[0]);glGetFloatv(GL_COLOR_CLEAR_VALUE,@S.ClearColor[0]);glGetDoublev(GL_DEPTH_RANGE,@S.DepthRange[0]);
  S.Depth:=glIsEnabled(GL_DEPTH_TEST);S.Cull:=glIsEnabled(GL_CULL_FACE);S.Blend:=glIsEnabled(GL_BLEND);
  S.Scissor:=glIsEnabled(GL_SCISSOR_TEST);S.SRGB:=glIsEnabled(GL_FRAMEBUFFER_SRGB_RTX);
end;
procedure RestoreGL(const S:TGLState);
  procedure Enable(Cap:GLenum;Value:GLBoolean);
  begin if Value=GL_TRUE then glEnable(Cap) else glDisable(Cap);end;
begin
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER,S.DrawFBO[0]);glBindFramebuffer(GL_READ_FRAMEBUFFER,S.ReadFBO[0]);
  glViewport(S.Viewport[0],S.Viewport[1],S.Viewport[2],S.Viewport[3]);glUseProgram(S.ProgramID);glBindVertexArray(S.VAO);
  glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_2D,S.Texture2D);glBindTexture(GL_TEXTURE_2D_ARRAY,S.TextureArray);glActiveTexture(S.ActiveTexture);
  glDepthFunc(S.DepthFunc);glDepthMask(S.DepthMask[0]);glDepthRange(S.DepthRange[0],S.DepthRange[1]);
  glColorMask(S.ColorMask[0],S.ColorMask[1],S.ColorMask[2],S.ColorMask[3]);glClearColor(S.ClearColor[0],S.ClearColor[1],S.ClearColor[2],S.ClearColor[3]);
  Enable(GL_DEPTH_TEST,S.Depth);Enable(GL_CULL_FACE,S.Cull);Enable(GL_BLEND,S.Blend);
  Enable(GL_SCISSOR_TEST,S.Scissor);Enable(GL_FRAMEBUFFER_SRGB_RTX,S.SRGB);
end;
function ProgramFor(const Fragment:string;const Vertex:string='#version 330'#10'out vec2 uv;void main(){vec2 p=vec2((gl_VertexID<<1)&2,gl_VertexID&2);uv=p;gl_Position=vec4(p*2.-1.,0,1);}'):Cardinal;
var V,F:Cardinal;OK,L:GLint;P:PChar;Log:string;
  function Shader(Kind:GLenum;const Source:string):Cardinal;
  begin
    Result:=glCreateShader(Kind);P:=PChar(Source);glShaderSource(Result,1,@P,nil);glCompileShader(Result);glGetShaderiv(Result,GL_COMPILE_STATUS,@OK);
    if OK=0 then begin glGetShaderiv(Result,GL_INFO_LOG_LENGTH,@L);SetLength(Log,Max(1,L));glGetShaderInfoLog(Result,L,nil,PChar(Log));glDeleteShader(Result);raise Exception.Create(Log);end;
  end;
begin
  V:=Shader(GL_VERTEX_SHADER,Vertex);F:=0;Result:=0;
  try
    F:=Shader(GL_FRAGMENT_SHADER,Fragment);Result:=glCreateProgram();glAttachShader(Result,V);glAttachShader(Result,F);glLinkProgram(Result);
    glGetProgramiv(Result,GL_LINK_STATUS,@OK);if OK=0 then begin glDeleteProgram(Result);Result:=0;raise Exception.Create('RTX copy shader link failed');end;
  finally glDeleteShader(V);if F<>0 then glDeleteShader(F);end;
end;
constructor TRtxShadow.Create;
begin
  inherited;FSlots:=specialize TDictionary<string,TRtxProjection>.Create;
  FDynamicCasters:=TCastleTransformList.Create(False);FDynamicMeshes:=TRtxDynamicMeshes.Create;FScreenStrength:=1;FScreenFilter:=16;
end;
procedure TRtxShadow.SetDynamicCasters(const Casters:TCastleTransformList);
var I:Integer;
begin
  FDynamicCasters.Clear;
  if Casters<>nil then for I:=0 to Casters.Count-1 do FDynamicCasters.Add(Casters[I]);
end;
procedure TRtxShadow.SetReflections(Value:Boolean);
begin
  if FReflections=Value then Exit;
  FReflections:=Value;FReflectionError:='';
end;
procedure TRtxShadow.SetScreenShadows(Value:Boolean);
begin
  if FScreenShadows=Value then Exit;
  { The legacy ray-to-depth image is only a 1x1 placeholder in screen mode.
    Recreate on an explicit backend switch, never during ordinary frames. }
  if FInitialized then Release;
  FScreenShadows:=Value;FScreenError:='';FFailed:=False;FError:='';
  ClearRtxScreenShadow;
end;
function TRtxShadow.GetScreenReady:Boolean;
begin Result:=FScreenShadows and FActive and not FFailed and not FStandaloneRaster and (FScreenError='');end;
function TRtxShadow.GetReflectionsReady:Boolean;
begin Result:=FReflections and FActive and not FFailed and not FStandaloneRaster and (FReflectionError='');end;
function TRtxShadow.ScreenSunRadius:Single;
begin
  if RtxScreenSunRadiusOverride>=0 then Exit(RtxScreenSunRadiusOverride);
  case FScreenFilter of 1:Result:=0;4:Result:=0.35;else Result:=0.7;end;
end;
function TRtxShadow.ScreenRayCount:Integer;
begin
  if ScreenSunRadius<=0 then Exit(1);
  if RtxScreenSamplesOverride>0 then Exit(EnsureRange(RtxScreenSamplesOverride,2,8));
  Result:=2; { Neighbouring disk samples are reconstructed spatially. }
end;
destructor TRtxShadow.Destroy;
begin Release;FDynamicMeshes.Free;FDynamicCasters.Free;FSlots.Free;inherited;end;
procedure TRtxShadow.Fail(const Msg:string);
begin
  Release;
  FError:=Msg;FFailed:=True;FActive:=False;FCollecting:=False;FWaiting:=False;
  FVertices:=nil;FCards:=nil;
  if FScreenShadows then WritelnLog('RTX','Screen shadows unavailable: '+Msg)
  else WritelnLog('RTX','Falling back to raster shadows: '+Msg);
end;
procedure TRtxShadow.Initialize(Size:Integer);
var Version:function:Cardinal;cdecl;Shader:UnicodeString;OldTexture:GLint;
  function Proc(const Name:string):Pointer;
  begin Result:=GetProcedureAddress(FLibrary,Name);if Result=nil then raise Exception.Create('Missing RTX entry point '+Name);end;
begin
  FStandaloneRaster:=FRasterComparison;FBuiltRasterComparison:=FRasterComparison;
  if not FStandaloneRaster then begin
  FLibrary:=LoadLibrary(IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)))+'rezvivo_rtx.dll');
  if FLibrary=NilHandle then raise Exception.Create('Optional rezvivo_rtx.dll is not installed');
  Pointer(Version):=Proc('rzrt_version');if Version()<>9 then raise Exception.Create('Incompatible RTX bridge');
  Pointer(FFrameWaits):=Proc('rzrt_frame_waits');Pointer(FGroundTriangles):=Proc('rzrt_ground_triangles');
  Pointer(FCreate):=Proc('rzrt_create');Pointer(FDestroy):=Proc('rzrt_destroy');Pointer(FErrorText):=Proc('rzrt_error');Pointer(FDeviceName):=Proc('rzrt_device');
  Pointer(FAlphaTexture):=Proc('rzrt_alpha');Pointer(FOutputTexture):=Proc('rzrt_output');Pointer(FSetScene):=Proc('rzrt_scene');Pointer(FTrace):=Proc('rzrt_trace');Pointer(FReadStats):=Proc('rzrt_stats');
  Pointer(FSetSceneMaterials):=Proc('rzrt_scene_materials');Pointer(FReflectionSize):=Proc('rzrt_reflection_size');
  Pointer(FReflectionTexture):=Proc('rzrt_reflection_texture');Pointer(FReflect):=Proc('rzrt_reflect');Pointer(FReflectionMS):=Proc('rzrt_reflection_ms');
  Pointer(FScreenSize):=Proc('rzrt_screen_size');Pointer(FScreenTexture):=Proc('rzrt_screen_texture');
  Pointer(FScreenReuseTexture):=Proc('rzrt_screen_reuse_texture');
  Pointer(FScreenTrace):=Proc('rzrt_screen_trace');Pointer(FScreenMS):=Proc('rzrt_screen_ms');Pointer(FScreenBytes):=Proc('rzrt_screen_bytes');
  Pointer(FDynamicBuffer):=Proc('rzrt_dynamic_buffer');Pointer(FDynamicStat):=Proc('rzrt_dynamic_stat');
  Shader:=UTF8Decode(UriToFilenameSafe('castle-data:/shaders/rtx/shadow.spv'));
  FContext:=FCreate(PWideChar(Shader),IfThen(FScreenShadows,1,Size),ALPHA_SIZE,ALPHA_LAYERS);
  if FContext=nil then raise Exception.Create(string(FErrorText()));
  FDevice:=string(FDeviceName(FContext));
  end else begin
    { The silhouette cache is useful without ray-tracing hardware, too. This
      path neither loads the Vulkan DLL nor builds an acceleration structure. }
    glGetIntegerv(GL_TEXTURE_BINDING_2D_ARRAY,@OldTexture);
    try
      glGenTextures(1,@FStandaloneAlpha);glBindTexture(GL_TEXTURE_2D_ARRAY,FStandaloneAlpha);
      glTexImage3D(GL_TEXTURE_2D_ARRAY,0,GL_R8,ALPHA_SIZE,ALPHA_SIZE,ALPHA_LAYERS,0,GL_RED,GL_UNSIGNED_BYTE,nil);
      glTexParameteri(GL_TEXTURE_2D_ARRAY,GL_TEXTURE_MIN_FILTER,GL_NEAREST);glTexParameteri(GL_TEXTURE_2D_ARRAY,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
      glTexParameteri(GL_TEXTURE_2D_ARRAY,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);glTexParameteri(GL_TEXTURE_2D_ARRAY,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
      if glGetError()<>GL_NO_ERROR then raise Exception.Create('Cannot allocate the tree projection cache');
    finally glBindTexture(GL_TEXTURE_2D_ARRAY,OldTexture);end;
    FDevice:='OpenGL (cached silhouettes)';
  end;
  FAtlasSize:=Size;FInitialized:=True;
  glGenFramebuffers(1,@FFramebuffer);glGenVertexArrays(1,@FVAO);
  FDepthProgram:=ProgramFor('#version 330'#10'uniform sampler2D source;void main(){gl_FragDepth=texelFetch(source,ivec2(gl_FragCoord.xy),0).r;}');
  FCopyProgram:=ProgramFor('#version 330'#10'in vec2 uv;out vec4 color;uniform sampler2DArray source;uniform int layer,seasonal,fruit,coverage;uniform float leaf,fruitAmount;'#10+
    'void main(){float a=texture(source,vec3(uv,layer)).a;float c=(coverage!=0?a:smoothstep(.04,.44,a))*leaf;'+
    'if(seasonal!=0){float w=coverage!=0?a:smoothstep(.008,.22,a);float l=texture(source,vec3(uv,layer+12)).a; l=(coverage!=0?l:smoothstep(.04,.44,l))*leaf;c=l+w*(1.-l);'+
    'if(fruit!=0){float f=texture(source,vec3(uv,layer+24)).a*fruitAmount;c=f+c*(1.-f);}}color=vec4(c);}');
  WritelnLog('Shadow cache','Backend: '+FDevice);
end;
function TRtxShadow.AlphaTexture:Cardinal;
begin
  if FStandaloneRaster then Result:=FStandaloneAlpha else Result:=FAlphaTexture(FContext);
end;
procedure TRtxShadow.Release;
begin
  ClearRtxScreenShadow;
  Inc(FScreenRevision);FScreenLastScene:=0;FScreenReuseActive:=False;
  if FScreenComposite<>0 then glDeleteProgram(FScreenComposite);FScreenComposite:=0;
  FreeAndNil(FDynamicMeshes);FDynamicMeshes:=TRtxDynamicMeshes.Create;
  if FScreenFBO<>0 then glDeleteFramebuffers(1,@FScreenFBO);FScreenFBO:=0;
  FScreenError:='';FScreenWidth:=0;FScreenHeight:=0;
  SetRtxMaterialPass(False,0,Vector4(0,0,1,1));
  if FReflectionFBO<>0 then glDeleteFramebuffers(1,@FReflectionFBO);FReflectionFBO:=0;
  FReflectionError:='';FSurfaces:=nil;
  if FBuildingAtlas<>nil then FBuildingAtlas.KeepExistingEnd;FBuildingAtlas:=nil;FUploadedAtlas:=0;
  if FRgbaCopyProgram<>0 then glDeleteProgram(FRgbaCopyProgram);FRgbaCopyProgram:=0;
  if FCardVAO<>0 then glDeleteVertexArrays(1,@FCardVAO);FCardVAO:=0;
  if FCardBuffer<>0 then glDeleteBuffers(1,@FCardBuffer);FCardBuffer:=0;
  if FCardProgram<>0 then glDeleteProgram(FCardProgram);FCardProgram:=0;
  if FFramebuffer<>0 then glDeleteFramebuffers(1,@FFramebuffer);FFramebuffer:=0;
  if FVAO<>0 then glDeleteVertexArrays(1,@FVAO);FVAO:=0;
  if FDepthProgram<>0 then glDeleteProgram(FDepthProgram);FDepthProgram:=0;
  if FCopyProgram<>0 then glDeleteProgram(FCopyProgram);FCopyProgram:=0;
  if FStandaloneAlpha<>0 then glDeleteTextures(1,@FStandaloneAlpha);FStandaloneAlpha:=0;
  if (FContext<>nil) and Assigned(FDestroy) then FDestroy(FContext);FContext:=nil;
  if FLibrary<>NilHandle then UnloadLibrary(FLibrary);FLibrary:=NilHandle;
  FSlots.Clear;FVertices:=nil;FCards:=nil;FActive:=False;FCollecting:=False;FWaiting:=False;
  FillChar(FActiveLayers,SizeOf(FActiveLayers),0);FillChar(FBuildLayers,SizeOf(FBuildLayers),0);
  FStats:=Default(TRtxStats);FSubmittedID:=0;FRevision:=0;
  FDeferredTrees:=0;FActiveDeferredTrees:=0;
  FInitialized:=False;
end;
function TRtxShadow.Intersects(const Box:TBox3D):Boolean;
var I:Integer;P:TVector3;MinX,MaxX,MinY,MaxY,X,Y,H:Single;
begin
  Result:=False;if Box.IsEmpty then Exit;
  if FScreenShadows then Exit(True); { all loaded terrain, including off-screen occluders }
  MinX:=1e30;MaxX:=-1e30;MinY:=1e30;MaxY:=-1e30;
  for I:=0 to 7 do begin
    P:=Vector3(Box.Data[I and 1].X,Box.Data[(I shr 1) and 1].Y,Box.Data[(I shr 2) and 1].Z)-FLastFocus;
    X:=TVector3.DotProduct(P,FSide);Y:=TVector3.DotProduct(P,FUp);
    MinX:=Min(MinX,X);MaxX:=Max(MaxX,X);MinY:=Min(MinY,Y);MaxY:=Max(MaxY,Y);
  end;
  H:=FHalfExtent;if FReflections or FScreenShadows then H:=Max(H,600);
  Result:=(MaxX>=-H-48) and (MinX<=H+48) and (MaxY>=-H-48) and (MinY<=H+48);
end;
procedure TRtxShadow.AddTriangle(Shape:TObject;const Triangle,Normal:TTriangle3;const TexCoord:TTriangle4;const Face:TFaceIndex);
var I,J,Index,Coord,MatID,Matched:Integer;N,Color,C:TVector3;S:TRtxSurface;Desc:TBuildingMaterialDesc;UV:array[0..2]of TVector4;
  P:array[0..2]of TVector3;
begin
  if not Triangle.IsValid then Exit;
  MatID:=0;
  if FGroundShape and (FBldMat<>nil) and (Face.IndexBegin>=0) and
    (Face.IndexBegin<FShapeIFS.FdCoordIndex.Count) then begin
    Coord:=FShapeIFS.FdCoordIndex.Items[Face.IndexBegin];
    if (Coord>=0) and (Coord<FBldMat.FdValue.Count) then MatID:=Round(FBldMat.FdValue.Items[Coord]);
    if MatID=GROUND_MAT_WATER then Exit;
  end;
  for I:=0 to 2 do P[I]:=FTransform.MultPoint(Triangle.Data[I]);
  if FGroundShape and not FScreenShadows then begin
    C:=FLastFocus-FBuildOrigin;
    if (Min(P[0].X,Min(P[1].X,P[2].X))>C.X+620) or
       (Max(P[0].X,Max(P[1].X,P[2].X))<C.X-620) or
       (Min(P[0].Z,Min(P[1].Z,P[2].Z))>C.Z+620) or
       (Max(P[0].Z,Max(P[1].Z,P[2].Z))<C.Z-620) then Exit;
  end;
  if FVertexCount>30000000-3 then raise Exception.Create('RTX snapshot exceeds its triangle budget');
  if FVertexCount+3>Length(FVertices) then SetLength(FVertices,Max(16384,Length(FVertices)*2));
  Index:=FVertexCount div 3;
  for I:=0 to 2 do begin FVertices[FVertexCount]:=P[I];Inc(FVertexCount);end;
  if Index>=Length(FSurfaces) then SetLength(FSurfaces,Max(8192,Length(FSurfaces)*2));
  N:=TVector3.CrossProduct(FVertices[FVertexCount-2]-FVertices[FVertexCount-3],FVertices[FVertexCount-1]-FVertices[FVertexCount-3]).Normalize;
  S:=Default(TRtxSurface);S.Normal:=Vector4(N.X,N.Y,N.Z,0);
  S.Color:=Vector4(FSurfaceColor.X,FSurfaceColor.Y,FSurfaceColor.Z,0);
  if FGroundShape then begin
    Color:=GROUND_MATERIALS[EnsureRange(MatID,0,GROUND_MAT_COUNT-1)].FallbackColor;
    S.Normal.W:=-1-MatID;
    S.Color:=Vector4(Power(Color.X,2.2),Power(Color.Y,2.2),Power(Color.Z,2.2),0);
    FSurfaces[Index]:=S;Exit;
  end;
  if (FBldUV<>nil) and (FBldMat<>nil) and (Face.IndexBegin>=0) and
    (Face.IndexEnd<=FShapeIFS.FdCoordIndex.Count) and (Face.IndexEnd-Face.IndexBegin=3) and
    (FShapeIFS.Coord is TCoordinateNode) then begin
    Matched:=0;FillChar(UV,SizeOf(UV),0);
    for I:=0 to 2 do begin
      Coord:=FShapeIFS.FdCoordIndex.Items[Face.IndexBegin+I];
      if (Coord<0) or (Coord>=TCoordinateNode(FShapeIFS.Coord).FdPoint.Count) or
        (Coord*2+1>=FBldUV.FdValue.Count) or (Coord>=FBldMat.FdValue.Count) then Continue;
      { Match source positions: triangulation may reverse polygon winding. }
      if FShapeIFS.Coord is TCoordinateNode then
        for J:=0 to 2 do
          if TVector3.Equals(TCoordinateNode(FShapeIFS.Coord).FdPoint.Items[Coord],Triangle.Data[J]) then begin
            UV[J]:=Vector4(FBldUV.FdValue.Items[Coord*2],FBldUV.FdValue.Items[Coord*2+1],FBuildingGrid.X,FBuildingGrid.Y);
            Matched:=Matched or (1 shl J);Break;
          end;
    end;
    if Matched=7 then begin
    Coord:=FShapeIFS.FdCoordIndex.Items[Face.IndexBegin];MatID:=Round(FBldMat.FdValue.Items[Coord]);
    Desc:=BuildingMaterialDesc(MatID);S.Normal.W:=MatID+1;
    S.Color:=Vector4(Desc.FallbackColor.X,Desc.FallbackColor.Y,Desc.FallbackColor.Z,Ord(MatID>=12));
    S.UV0:=UV[0];S.UV1:=UV[1];S.UV2:=UV[2];
    end;
  end;
  FSurfaces[Index]:=S;
end;
function TRtxShadow.CollectGround:Boolean;
var Start,I,Coord:Integer;T,N:TTriangle3;UV:TTriangle4;Face:TFaceIndex;
begin
  { Ground composites can contain millions of triangles in one shape. Keep
    their cursor across frames instead of triangulating the entire tile in
    one supposedly 3 ms snapshot step. }
  Result:=False;N:=Default(TTriangle3);UV:=Default(TTriangle4);
  while (FGroundIndex<FShapeIFS.FdCoordIndex.Count) and TimeAvailable do begin
    Start:=FGroundIndex;
    while (FGroundIndex<FShapeIFS.FdCoordIndex.Count) and
      (FShapeIFS.FdCoordIndex.Items[FGroundIndex]>=0) do Inc(FGroundIndex);
    if FGroundIndex-Start=3 then begin
      for I:=0 to 2 do begin
        Coord:=FShapeIFS.FdCoordIndex.Items[Start+I];
        T.Data[I]:=TCoordinateNode(FShapeIFS.Coord).FdPoint.Items[Coord];
      end;
      Face:=Default(TFaceIndex);Face.IndexBegin:=Start;Face.IndexEnd:=FGroundIndex;
      AddTriangle(nil,T,N,UV,Face);
    end;
    Inc(FGroundIndex);
  end;
  Result:=FGroundIndex>=FShapeIFS.FdCoordIndex.Count;
  if Result then FGroundIndex:=0;
end;
function TRtxShadow.TimeAvailable:Boolean;
begin Result:=(GetTickCount64<FDeadline) and (FBakesThisStep<2);end;
procedure TRtxShadow.Prepare(const Casters:TCastleTransformList;Revision:QWord;
  const Focus,Sun:TVector3;Size:Integer;HalfExtent:Single;Accept:TRtxShapeFilter);
var Scene:TCastleScene;Shapes:TShapeList;Shape:TShape;Box:TBox3D;I,K:Integer;
    M,Local:TMatrix4;V:Double;UpHint:TVector3;NativeReady:Boolean;
    TreeRevision:QWord;RefreshTrees:Boolean;SnapshotFocus,Lead:TVector3;
    Attr:TFloatVertexAttributeNode;E:TEffectNode;App:TAppearanceNode;Field:TX3DField;TexNode:TX3DNode;
begin
  if FFailed then begin
    if FRasterComparison=FBuiltRasterComparison then Exit;
    FFailed:=False;FError:='';
  end;
  try
    Lead:=FPrefetchOffset;
    if Lead.Length>16 then Lead:=Lead.Normalize*16;
    SnapshotFocus:=Focus+Lead;
    { Reflection materials travel with the same snapshot. Toggling their use
      must not invalidate a ready shadow BVH or briefly change shadow mode. }
    TreeRevision:=0;
    for I:=0 to Casters.Count-1 do begin
      { Snapshot cursors must not survive an unordered caster-list change. }
      Revision:=(Revision xor QWord(PtrUInt(Casters[I])))*16777619;
      if (FReflections or FScreenShadows) and (Casters[I] is TOsmProceduralVegetation) then
        TreeRevision:=TreeRevision+TOsmProceduralVegetation(Casters[I]).ShadowAtlasRevision;
    end;
    Revision:=Revision xor (QWord(Ord(FReflections)) shl 63);
    Revision:=Revision xor (QWord(Ord(FScreenShadows)) shl 62);
    FObservedTrees:=TreeRevision;
    if FInitialized and ((Size<>FAtlasSize) or ((FSun-Sun.Normalize).Length>0.005) or (FStandaloneRaster<>FRasterComparison)) then Release;
    if not FInitialized then Initialize(Size);
    if not FStandaloneRaster then
      if FReadStats(FContext,@FStats)=0 then raise Exception.Create(string(FErrorText()));
    if FWaiting and (FStats.SceneID=FSubmittedID) then begin
      FActiveOrigin:=FBuildOrigin;FActiveFocus:=FLastFocus;FActiveRevision:=FRevision;FActiveSceneID:=FSubmittedID;FActive:=True;FWaiting:=False;
      FActiveTrees:=FBuildTrees;
      FActiveDeferredTrees:=FDeferredTrees;
      FActiveLayers:=FBuildLayers;
      FVertices:=nil;FCards:=nil;FSurfaces:=nil;
    end;
    if FWaiting then Exit;
    { The in-flight snapshot coalesces atlas uploads naturally. Publish ready
      casters without waiting for the whole atlas stream to become idle. }
    RefreshTrees:=FActive and not FCollecting and (TreeRevision<>FActiveTrees);
    { Receiver extents grow with an aerial view. Keep a padded snapshot when
      the view contracts, and do not restart collection on sub-texel size
      changes. Previously exact size inequality could starve an adaptive map. }
    if RefreshTrees or (Revision<>FRevision) or (HalfExtent>FHalfExtent) or (FRasterComparison<>FBuiltRasterComparison) or
      (not FScreenShadows and not FCollecting and ((SnapshotFocus-FLastFocus).Length>32)) or
      (not FScreenShadows and FCollecting and ((Focus-FLastFocus).Length>FHalfExtent*0.5+32)) or
      (not FActive and not FCollecting) then begin
      { The immutable active snapshot stays usable while collecting its
        replacement. Changing a tile must not switch every material to sky. }
      FCollecting:=True;FRevision:=Revision;FLastFocus:=SnapshotFocus;
      FHalfExtent:=Ceil(HalfExtent/64)*64+32;
      FBuiltRasterComparison:=FRasterComparison;
      Inc(FCollectionSerial);FBuildNear:=0;
      FillChar(FBuildLayers,SizeOf(FBuildLayers),0);
      FBuildTrees:=TreeRevision;
      FDeferredTrees:=0;
      FBuildOrigin:=Vector3(Floor(SnapshotFocus.X/64)*64,Floor(SnapshotFocus.Y/64)*64,Floor(SnapshotFocus.Z/64)*64);
      FSun:=Sun.Normalize;UpHint:=Vector3(0,1,0);if Abs(FSun.Y)>0.99 then UpHint:=Vector3(0,0,1);
      FSide:=TVector3.CrossProduct(FSun,UpHint).Normalize;FUp:=TVector3.CrossProduct(FSide,FSun);
      FVertexCount:=0;FCardCount:=0;FSource:=0;FShape:=0;FCell:=0;FEntry:=0;FGroundIndex:=0;
    end;
    if not FCollecting then Exit;
    FDeadline:=GetTickCount64+3;FBakesThisStep:=0;
    while (FSource<Casters.Count) and TimeAvailable do begin
      if Casters[FSource] is TCastleScene then begin
        if FRasterComparison then begin Inc(FSource);FShape:=0;Continue;end;
        Scene:=TCastleScene(Casters[FSource]);
        if not Scene.ExistsInRoot or not Intersects(Scene.WorldBoundingBox) then begin Inc(FSource);FShape:=0;Continue;end;
        Shapes:=Scene.Shapes.TraverseList(True,True,False);
        while (FShape<Shapes.Count) and TimeAvailable do begin
          Shape:=Shapes[FShape];Inc(FShape);
          { CGE's shape-tree visibility accounts for invisible parents;
            Shape.visible itself is checked separately by its renderer. }
          if (Shape.Node<>nil) and not Shape.Node.Visible then Continue;
          FGroundShape:=IsRtxGround(Shape);
          if not FScreenShadows and not Accept(Shape) and not (FReflections and FGroundShape) then Continue;
          Box:=Shape.BoundingBox.Transform(Scene.WorldTransform);if not Intersects(Box) then Continue;
          M:=Scene.WorldTransform;Local:=Shape.State.Transform;FTransform:=M*Local;
          FSurfaceColor:=Vector3(0.48,0.46,0.43);
          if Shape.State.MaterialInfo<>nil then FSurfaceColor:=Shape.State.MaterialInfo.MainColor;
          FBldUV:=nil;FBldMat:=nil;FShapeIFS:=nil;
          if Shape.Geometry is TIndexedFaceSetNode then begin
            FShapeIFS:=TIndexedFaceSetNode(Shape.Geometry);
            for I:=0 to FShapeIFS.FdAttrib.Count-1 do
              if FShapeIFS.FdAttrib[I] is TFloatVertexAttributeNode then begin
                Attr:=TFloatVertexAttributeNode(FShapeIFS.FdAttrib[I]);
                if Attr.NameField='bldUV' then FBldUV:=Attr;
                if Attr.NameField='materialId' then FBldMat:=Attr;
              end;
          end;
          if (FBldUV<>nil) and (Shape.Node.Appearance is TAppearanceNode) then begin
            App:=TAppearanceNode(Shape.Node.Appearance);
            for I:=0 to App.FdEffects.Count-1 do if App.FdEffects[I] is TEffectNode then begin
              E:=TEffectNode(App.FdEffects[I]);Field:=E.Field('u_bld_atlas');
              if Field is TSFNode then begin
                TexNode:=TSFNode(Field).Value;
                if (FBuildingAtlas=nil) and (TexNode is TAbstractTextureNode) then begin
                  FBuildingAtlas:=TAbstractTextureNode(TexNode);FBuildingAtlas.KeepExistingBegin;
                end;
                FBuildingGrid:=Vector2(4,4);
                Field:=E.Field('u_bld_grid_cols');if Field is TSFInt32 then FBuildingGrid.X:=TSFInt32(Field).Value;
                Field:=E.Field('u_bld_grid_rows');if Field is TSFInt32 then FBuildingGrid.Y:=TSFInt32(Field).Value;
              end;
            end;
          end;
          { Rebase before converting the large translation to Single. }
          for I:=0 to 2 do begin
            V:=Double(M.Data[3,I])-FBuildOrigin.Data[I];
            for K:=0 to 2 do V:=V+Double(M.Data[K,I])*Local.Data[3,K];
            FTransform.Data[3,I]:=V;
          end;
          if FGroundShape and (FShapeIFS<>nil) and (FShapeIFS.Coord is TCoordinateNode) then begin
            if not CollectGround then begin Dec(FShape);Break;end;
          end else Shape.LocalTriangulate(@AddTriangle,False);
        end;
        if FShape<Shapes.Count then Break;
      end else if (Casters[FSource] is TOsmProceduralVegetation) and RenderTreesActive and (FReflections or FScreenShadows) then begin
        NativeReady:=TOsmProceduralVegetation(Casters[FSource]).CollectRtxTrees(Self,FCell,FEntry);
        if not NativeReady then Break;
      end;
      Inc(FSource);FShape:=0;FCell:=0;FEntry:=0;
    end;
    if FSource<Casters.Count then Exit;
    if FRasterComparison then UploadCards
    else begin
      if FCardVAO<>0 then glDeleteVertexArrays(1,@FCardVAO);FCardVAO:=0;
      if FCardBuffer<>0 then glDeleteBuffers(1,@FCardBuffer);FCardBuffer:=0;
    end;
    Inc(FBuildID);FSubmittedID:=FBuildID;
    if FStandaloneRaster then begin
      FActiveOrigin:=FBuildOrigin;FActiveFocus:=FLastFocus;FActiveRevision:=FRevision;FActive:=True;FCollecting:=False;
      FActiveTrees:=FBuildTrees;
      FActiveDeferredTrees:=FDeferredTrees;
      FActiveLayers:=FBuildLayers;
      FStats.SceneID:=FBuildID;FStats.Triangles:=FVertexCount div 3;FStats.Cards:=FCardCount;
      FStats.Bytes:=Int64(ALPHA_SIZE)*ALPHA_SIZE*ALPHA_LAYERS+Int64(FVertexCount)*SizeOf(TVector3)+Int64(FCardCount)*SizeOf(TRtxCard);
      Inc(FStats.Builds);FVertices:=nil;FCards:=nil;Exit;
    end;
    if FSetSceneMaterials(FContext,Pointer(FVertices),FVertexCount div 3,Pointer(FCards),FCardCount,FSubmittedID,Pointer(FSurfaces))=0 then
      raise Exception.Create(string(FErrorText()));
    FCollecting:=False;FWaiting:=True;
  except on E:Exception do Fail(E.Message);end;
end;
function TRtxShadow.AllocateLayer:Integer;
var Pair:specialize TPair<string,TRtxProjection>;Key:string;Oldest:QWord;
begin
  if FSlots.Count<ALPHA_LAYERS then Exit(FSlots.Count);
  Key:='';Oldest:=High(QWord);Result:=-1;
  for Pair in FSlots do
    if not FActiveLayers[Pair.Value.Layer] and not FBuildLayers[Pair.Value.Layer] and (Pair.Value.Used<Oldest) then begin
      Key:=Pair.Key;Oldest:=Pair.Value.Used;Result:=Pair.Value.Layer;
    end;
  if Result<0 then Exit;
  FSlots.Remove(Key);
end;
procedure TRtxShadow.CopyLOD(const Layer:Integer;Texture:Cardinal;Source:Integer;Seasonal,Fruit:Boolean;Leaf,FruitAmount:Single);
var S:TGLState;
begin
  SaveGL(S);
  try
    glBindFramebuffer(GL_FRAMEBUFFER,FFramebuffer);glFramebufferTextureLayer(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,AlphaTexture,0,Layer);
    glDrawBuffer(GL_COLOR_ATTACHMENT0);glReadBuffer(GL_COLOR_ATTACHMENT0);
    if glCheckFramebufferStatus(GL_FRAMEBUFFER)<>GL_FRAMEBUFFER_COMPLETE then raise Exception.Create('RTX LOD framebuffer is incomplete');
    glViewport(0,0,ALPHA_SIZE,ALPHA_SIZE);glDisable(GL_SCISSOR_TEST);glDisable(GL_FRAMEBUFFER_SRGB_RTX);glDisable(GL_DEPTH_TEST);glDisable(GL_CULL_FACE);glDisable(GL_BLEND);
    glColorMask(GL_TRUE,GL_TRUE,GL_TRUE,GL_TRUE);glUseProgram(FCopyProgram);glBindVertexArray(FVAO);glBindTexture(GL_TEXTURE_2D_ARRAY,Texture);
    glUniform1i(glGetUniformLocation(FCopyProgram,'source'),0);glUniform1i(glGetUniformLocation(FCopyProgram,'layer'),Source);
    glUniform1i(glGetUniformLocation(FCopyProgram,'seasonal'),Ord(Seasonal));glUniform1i(glGetUniformLocation(FCopyProgram,'fruit'),Ord(Fruit));
    glUniform1i(glGetUniformLocation(FCopyProgram,'coverage'),Ord(FScreenShadows));
    glUniform1f(glGetUniformLocation(FCopyProgram,'leaf'),Leaf);glUniform1f(glGetUniformLocation(FCopyProgram,'fruitAmount'),FruitAmount);
    glDrawArrays(GL_TRIANGLES,0,3);Inc(FBakesThisStep);
  finally RestoreGL(S);end;
end;
procedure TRtxShadow.AppendCard(const P:TRtxProjection;const Position:TVector3;Phase:Single);
var C:TRtxCard;O:TVector3;
begin
  FBuildLayers[P.Layer]:=True;
  O:=Position-FBuildOrigin+P.Origin;
  C:=Default(TRtxCard);C.Origin:=Vector4(O.X,O.Y,O.Z,P.Layer);C.U:=Vector4(P.U.X,P.U.Y,P.U.Z,0);C.V:=Vector4(P.V.X,P.V.Y,P.V.Z,0);C.Spare.X:=Phase;
  if FCardCount>=Length(FCards) then SetLength(FCards,Max(1024,Length(FCards)*2));
  FCards[FCardCount]:=C;Inc(FCardCount);
end;
function TRtxShadow.AddTree(const Instance:TreeModel.TTreeInstance;const Profile:TTreeParams;
  const Position:TVector3;Renderer,Shared:TTreeRenderer;Season:Single):Boolean;
var Key:string;P:TRtxProjection;Age,View,Source:Integer;
    Phase,Angle:Single;
    Actual:TTreeParams;Frames:TLODFrames;Texture:Cardinal;Seasonal,Fruit:Boolean;
    State:TTreeSeasonState;Right:TVector3;
begin
  Result:=False;if not TimeAvailable then Exit;
  Actual:=ResolveTreeParams(Instance,Profile);Phase:=HashUnit(Actual.Seed,10);
  { Reflection and screen-ray cards share the species/age atlas. The screen
    path preserves mean coverage instead of thresholding an averaged crown. }
  if (Shared=nil) or not Shared.ShadowLOD(Profile,Texture,Frames,Seasonal,Fruit) then Exit;
  if Actual.Maturity<0.55 then Age:=0 else if Actual.Maturity<1.8 then Age:=1 else Age:=2;
  Angle:=ArcTan2(-FSun.X,-FSun.Z)/(2*Pi)+Phase;Angle:=Angle-Floor(Angle);View:=Floor(Angle*4+0.5) mod 4;Source:=Age*4+View;
  Key:='F'+IntToStr(Ord(Profile.Species))+'/'+IntToStr(Source)+'/'+IntToStr(Round(Season*12));
  if not FSlots.TryGetValue(Key,P) then begin
    P:=Default(TRtxProjection);P.Layer:=AllocateLayer;
    if P.Layer<0 then Exit(True);
    State:=EvaluateTreeSeason(Profile.Species,Profile.LeafColor,Season);
    CopyLOD(P.Layer,Texture,Source,Seasonal,Fruit,State.LeafAmount,TreeFruitAmount(Profile.Species,Season));
  end else Inc(FReusedProjections);
  P.Used:=FCollectionSerial;FSlots.AddOrSetValue(Key,P);
  Right:=Vector3(-FSun.Z,0,FSun.X).Normalize;
  P.U:=Right*(Actual.Height*Frames[Age].X);P.V:=Vector3(0,Actual.Height*(Frames[Age].Z-Frames[Age].Y),0);
  P.Origin:=P.U*(-0.5)+Vector3(0,Actual.Height*Frames[Age].Y,0);
  AppendCard(P,Position,Phase);Result:=True;
end;
function TRtxShadow.Trace(const Zones:TRtxZones):Boolean;
var R:LongInt;
begin
  Result:=False;if not FActive or FFailed then Exit;
  FLastZones:=Zones;if FRasterComparison then begin Inc(FStats.Frames);Exit(True);end;
  R:=FTrace(FContext,@Zones[0],FActiveSceneID);
  if R=0 then Inc(FTraceFallbacks);
  if R<0 then Fail(string(FErrorText())) else Result:=R=1;
end;
procedure TRtxShadow.UploadCards;
const Project='uniform vec3 origin,du,dv,ray;uniform float rayLength;vec4 projected(vec3 p){p-=origin;return vec4(2.*dot(p,du)/dot(du,du)-1.,2.*dot(p,dv)/dot(dv,dv)-1.,2.*dot(p,ray)/rayLength-1.,1.);}';
var S:TGLState;OldBuffer:GLint;I:Integer;
begin
  SaveGL(S);glGetIntegerv(GL_ARRAY_BUFFER_BINDING,@OldBuffer);
  try
    if FCardProgram=0 then FCardProgram:=ProgramFor('#version 330'#10'in vec2 uv;flat in vec2 info;uniform sampler2DArray mask;'+CARD_COVERAGE_GLSL+
      'void main(){if(texture(mask,vec3(uv,info.x)).r<threshold(uv,info.y))discard;}',
      '#version 330'#10'layout(location=0)in vec4 base;layout(location=1)in vec4 edgeU;layout(location=2)in vec4 edgeV;layout(location=3)in vec4 spare;out vec2 uv;flat out vec2 info;'+Project+
      'const vec2 corner[6]=vec2[6](vec2(0,0),vec2(1,0),vec2(1,1),vec2(0,0),vec2(1,1),vec2(0,1));void main(){uv=corner[gl_VertexID];info=vec2(base.w,spare.x);gl_Position=projected(base.xyz+uv.x*edgeU.xyz+uv.y*edgeV.xyz);}');
    if FCardVAO=0 then glGenVertexArrays(1,@FCardVAO);
    if FCardBuffer=0 then glGenBuffers(1,@FCardBuffer);
    glBindVertexArray(FCardVAO);glBindBuffer(GL_ARRAY_BUFFER,FCardBuffer);glBufferData(GL_ARRAY_BUFFER,FCardCount*SizeOf(TRtxCard),Pointer(FCards),GL_STATIC_DRAW);
    for I:=0 to 3 do begin glEnableVertexAttribArray(I);glVertexAttribPointer(I,4,GL_FLOAT,GL_FALSE,SizeOf(TRtxCard),Pointer(PtrUInt(I*16)));glVertexAttribDivisor(I,1);end;
    FRasterCards:=FCardCount;
  finally glBindBuffer(GL_ARRAY_BUFFER,OldBuffer);RestoreGL(S);end;
end;
procedure TRtxShadow.DrawCachedRaster(Zone:Integer);
var S:TGLState;Z:TRtxZone;
  procedure Uniforms(ProgramID:Cardinal);
  begin
    glUseProgram(ProgramID);glUniform3fv(glGetUniformLocation(ProgramID,'origin'),1,@Z.Origin.X);
    glUniform3fv(glGetUniformLocation(ProgramID,'du'),1,@Z.DU.X);glUniform3fv(glGetUniformLocation(ProgramID,'dv'),1,@Z.DV.X);
    glUniform3fv(glGetUniformLocation(ProgramID,'ray'),1,@Z.Ray.X);glUniform1f(glGetUniformLocation(ProgramID,'rayLength'),Z.Ray.W);
  end;
begin
  SaveGL(S);Z:=FLastZones[Zone];
  try
    glEnable(GL_DEPTH_TEST);glDepthFunc(GL_LESS);glDepthMask(GL_TRUE);glDepthRange(0,1);
    glDisable(GL_BLEND);glDisable(GL_CULL_FACE);glColorMask(GL_FALSE,GL_FALSE,GL_FALSE,GL_FALSE);
    Uniforms(FCardProgram);glBindVertexArray(FCardVAO);glBindTexture(GL_TEXTURE_2D_ARRAY,AlphaTexture);glUniform1i(glGetUniformLocation(FCardProgram,'mask'),0);
    glDrawArraysInstanced(GL_TRIANGLES,0,6,FRasterCards);
  finally RestoreGL(S);end;
end;
procedure TRtxShadow.CopyDepth;
var S:TGLState;
begin
  SaveGL(S);
  try
    glUseProgram(FDepthProgram);glBindVertexArray(FVAO);glBindTexture(GL_TEXTURE_2D,FOutputTexture(FContext));
    glUniform1i(glGetUniformLocation(FDepthProgram,'source'),0);glEnable(GL_DEPTH_TEST);glDepthFunc(GL_ALWAYS);glDepthMask(GL_TRUE);glDepthRange(0,1);
    glDisable(GL_CULL_FACE);glDisable(GL_BLEND);glColorMask(GL_FALSE,GL_FALSE,GL_FALSE,GL_FALSE);glDrawArrays(GL_TRIANGLES,0,3);
  finally RestoreGL(S);end;
end;
procedure TRtxShadow.Snapshot(const J:TJSONObject);
begin
  J.Add('active',FActive and not FFailed);J.Add('failed',FFailed);J.Add('error',FError);J.Add('device',FDevice);
  J.Add('collecting',FCollecting);J.Add('waiting_bvh',FWaiting);J.Add('sources_done',FSource);
  J.Add('active_scene',Int64(FActiveSceneID));J.Add('submitted_scene',Int64(FSubmittedID));
  J.Add('active_trees',Int64(FActiveTrees));J.Add('observed_trees',Int64(FObservedTrees));
  J.Add('pending_trees',FActiveDeferredTrees);J.Add('collecting_pending_trees',FDeferredTrees);
  J.Add('triangles',FStats.Triangles);J.Add('tree_cards',FStats.Cards);J.Add('gpu_bytes',FStats.Bytes);
  J.Add('trace_ms',FStats.TraceMS);J.Add('build_elapsed_ms',FStats.BuildMS);J.Add('frames',FStats.Frames);J.Add('builds',FStats.Builds);
  J.Add('silhouettes',FSlots.Count);J.Add('individual_tree_bakes',FBakedTrees);J.Add('projection_reuses',FReusedProjections);
  J.Add('cached_raster',FRasterComparison);
  J.Add('vulkan_loaded',FContext<>nil);
  J.Add('trace_fallbacks',FTraceFallbacks);J.Add('reflections',FReflections);
  J.Add('reflection_frames',FReflectionFrames);J.Add('reflection_error',FReflectionError);
  J.Add('reflection_receiver_pixels',FDebugReceivers);J.Add('reflection_hit_pixels',FDebugHits);
  J.Add('reflection_horizontal_pixels',FDebugHorizontalReceivers);J.Add('reflection_horizontal_hits',FDebugHorizontalHits);
  J.Add('reflection_traced_pixels',FDebugTracedReflections);J.Add('reflection_cached_pixels',FDebugCachedReflections);
  J.Add('reflection_drops',FReflectionDrops);
  J.Add('screen_space',FScreenShadows);J.Add('screen_ready',ScreenReady);
  J.Add('screen_frames',FScreenFrames);J.Add('screen_error',FScreenError);
  J.Add('screen_width',FScreenWidth);J.Add('screen_height',FScreenHeight);
  J.Add('screen_cache_reuse',FScreenReuseActive);
  J.Add('reflection_ranges',TJSONArray.Create([FReflectionRanges.X,FReflectionRanges.Y,FReflectionRanges.Z]));
  J.Add('screen_unified',FScreenShadows);J.Add('screen_receiver_limit_m',0);
  J.Add('screen_sun_radius_deg',ScreenSunRadius);J.Add('screen_rays',ScreenRayCount);
  if FDynamicMeshes<>nil then begin
    J.Add('dynamic_posed_shapes',FDynamicMeshes.Posed);
    J.Add('dynamic_skipped_shapes',FDynamicMeshes.Skipped);
    J.Add('dynamic_filtered_shapes',FDynamicMeshes.Filtered);
  end;
  if FContext<>nil then begin
    J.Add('reflection_ms',FReflectionMS(FContext));J.Add('gpu_slot_waits',FFrameWaits(FContext));
    J.Add('ground_triangles',FGroundTriangles(FContext));
    J.Add('screen_ms',FScreenMS(FContext));J.Add('screen_bytes',FScreenBytes(FContext));
    J.Add('dynamic_triangles',FDynamicStat(FContext,0));J.Add('dynamic_builds',FDynamicStat(FContext,1));
    J.Add('dynamic_refits',FDynamicStat(FContext,2));J.Add('dynamic_bytes',FDynamicStat(FContext,3));
  end;
end;
procedure TRtxShadow.DiagnosticDepth(const J:TJSONObject);
var S:TGLState;Pixels:array of Cardinal;I:Integer;Hash:Cardinal;Z:TJSONArray;
  Depth:array of Single;Mask:array of Byte;P:TVector4;X,Y,Visible,FarVisible,FarShadow,Pack:Integer;
  Distance,MaxDistance:Single;Partial,Levels:Integer;Seen:array[0..255]of Boolean;
  Reuse:array of TVector2;Reused,Occluded:Integer;
begin
  if (FContext=nil) or not FActive or FRasterComparison then Exit;
  if FScreenShadows then begin
    if (FScreenWidth=0) or (FScreenHeight=0) then Exit;
    { Explicit MCP diagnostic only, never part of ordinary frames. }
    SetLength(Depth,FScreenWidth*FScreenHeight);SetLength(Mask,Length(Depth));
    SetLength(Reuse,Length(Depth));Reused:=0;Occluded:=0;
    SaveGL(S);glGetIntegerv(GL_PACK_ALIGNMENT,@Pack);
    try
      glPixelStorei(GL_PACK_ALIGNMENT,1);glBindTexture(GL_TEXTURE_2D,FScreenTexture(FContext,0));
      glGetTexImage(GL_TEXTURE_2D,0,GL_DEPTH_COMPONENT,GL_FLOAT,Pointer(Depth));
      glBindTexture(GL_TEXTURE_2D,FScreenTexture(FContext,1));glGetTexImage(GL_TEXTURE_2D,0,GL_RED,GL_UNSIGNED_BYTE,Pointer(Mask));
      glBindTexture(GL_TEXTURE_2D,FScreenReuseTexture(FContext));glGetTexImage(GL_TEXTURE_2D,0,GL_RG,GL_FLOAT,Pointer(Reuse));
    finally glPixelStorei(GL_PACK_ALIGNMENT,Pack);RestoreGL(S);end;
    Visible:=0;FarVisible:=0;FarShadow:=0;MaxDistance:=0;Hash:=0;Partial:=0;Levels:=0;FillChar(Seen,SizeOf(Seen),0);
    for I:=0 to High(Depth) do begin
      Hash:=((Hash shl 5) or (Hash shr 27)) xor Mask[I];
      if not Seen[Mask[I]] then begin Seen[Mask[I]]:=True;Inc(Levels);end;
      if (Mask[I]>16) and (Mask[I]<239) then Inc(Partial);
      if Depth[I]>=1 then Continue;
      if FScreenReuseActive and (Reuse[I].X>=0) then begin
        if Reuse[I].Y=Depth[I] then Inc(Reused) else Inc(Occluded);
      end;
      Inc(Visible);X:=I mod FScreenWidth;Y:=I div FScreenWidth;
      P:=FScreenCamera.InverseProjection*Vector4((X+0.5)/FScreenWidth*2-1,(Y+0.5)/FScreenHeight*2-1,Depth[I]-1,1);
      if Abs(P.W)<1e-12 then Continue;
      Distance:=Sqrt(Sqr(P.X)+Sqr(P.Y)+Sqr(P.Z))/Abs(P.W);MaxDistance:=Max(MaxDistance,Distance);
      if Distance>500 then begin Inc(FarVisible);if Mask[I]>16 then Inc(FarShadow);end;
    end;
    J.Add('screen_mask_hash',IntToHex(Hash,8));J.Add('screen_visible_pixels',Visible);
    J.Add('screen_partial_pixels',Partial);J.Add('screen_coverage_levels',Levels);
    J.Add('screen_far_pixels',FarVisible);J.Add('screen_far_shadow_pixels',FarShadow);
    J.Add('screen_reused_pixels',Reused);J.Add('screen_traced_pixels',Visible-Reused);
    J.Add('screen_live_over_cache_pixels',Occluded);
    J.Add('screen_max_receiver_m',MaxDistance);Exit;
  end;
  SetLength(Pixels,FAtlasSize*FAtlasSize);
  SaveGL(S);
  try
    glBindTexture(GL_TEXTURE_2D,FOutputTexture(FContext));
    glGetTexImage(GL_TEXTURE_2D,0,GL_RED,GL_FLOAT,Pointer(Pixels));
  finally RestoreGL(S);end;
  Hash:=0;
  for I:=0 to High(Pixels) do Hash:=((Hash shl 5) or (Hash shr 27)) xor Pixels[I];
  J.Add('depth_hash',IntToHex(Hash,8));
  Z:=TJSONArray.Create;
  for I:=0 to 3 do begin
    Z.Add(TJSONArray.Create([FLastZones[I].Origin.X,FLastZones[I].Origin.Y,FLastZones[I].Origin.Z,
      FLastZones[I].DU.X,FLastZones[I].DU.Y,FLastZones[I].DU.Z,
      FLastZones[I].DV.X,FLastZones[I].DV.Y,FLastZones[I].DV.Z,
      FLastZones[I].Ray.X,FLastZones[I].Ray.Y,FLastZones[I].Ray.Z,FLastZones[I].Ray.W]));
  end;
  J.Add('zones',Z);
end;
function TRtxShadow.ScreenImage(Index:Integer):Cardinal;
begin
  Result:=0;
  if (FContext=nil) or not ScreenReady or (FScreenWidth=0) then Exit;
  if Index=2 then Result:=FScreenReuseTexture(FContext)
  else if (Index>=0)and(Index<=1) then Result:=FScreenTexture(FContext,Index);
end;

procedure TRtxShadow.RenderScreenShadows(const Params:TRenderParams;Draw:TRtxDrawReflectors);
var S:TGLState;OldView:TRectangle;OldRange:TDepthRange;OldProjection:TMatrix4;
  C:TRtxReflectionCamera;W,H,I:Integer;Shader:UnicodeString;Tex,DynamicTarget:Cardinal;
  Camera,Focus:TVector3;Radius:Single;InverseProjection:TMatrix4Double;
begin
  ClearRtxScreenShadow;
  FScreenReuseActive:=False;
  if not ScreenReady then Exit;
  if (FScreenLastScene<>FActiveSceneID)or((FScreenLastSun-FSun).Length>0.000001)or
    (FScreenLastFilter<>FScreenFilter)or(FScreenLastSunRadius<>ScreenSunRadius)or(FScreenLastRayCount<>ScreenRayCount) then begin
    Inc(FScreenRevision);FScreenLastScene:=FActiveSceneID;FScreenLastSun:=FSun;FScreenLastFilter:=FScreenFilter;
    FScreenLastSunRadius:=ScreenSunRadius;FScreenLastRayCount:=ScreenRayCount;
  end;
  SaveGL(S);OldView:=RenderContext.Viewport;OldRange:=RenderContext.DepthRange;
  OldProjection:=RenderContext.ProjectionMatrix;Tex:=0;
  Radius:=0;Params.RenderingCamera.InverseMatrixNeeded;
  Camera:=Params.RenderingCamera.InverseMatrix.MultPoint(TVector3.Zero);
  try
    try
      W:=Max(1,OldView.Width);H:=Max(1,OldView.Height);
      Shader:=UTF8Decode(UriToFilenameSafe('castle-data:/shaders/rtx/screen_shadow.spv'));
      if FScreenSize(FContext,PWideChar(Shader),W,H)=0 then raise Exception.Create(string(FErrorText()));
      FScreenWidth:=W;FScreenHeight:=H;
      if FScreenFBO=0 then glGenFramebuffers(1,@FScreenFBO);
      glBindFramebuffer(GL_FRAMEBUFFER,FScreenFBO);
      glFramebufferTexture2D(GL_FRAMEBUFFER,GL_DEPTH_ATTACHMENT,GL_TEXTURE_2D,FScreenTexture(FContext,0),0);
      glFramebufferTexture2D(GL_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,FScreenReuseTexture(FContext),0);
      glDrawBuffer(GL_COLOR_ATTACHMENT0);glReadBuffer(GL_NONE);
      if glCheckFramebufferStatus(GL_FRAMEBUFFER)<>GL_FRAMEBUFFER_COMPLETE then raise Exception.Create('Screen shadow depth framebuffer incomplete');
      RenderContext.Viewport:=Rectangle(0,0,W,H);RenderContext.DepthRange:=drFar;
      RenderContext.DepthBufferUpdate:=True;RenderContext.DepthTest:=True;
      glEnable(GL_DEPTH_TEST);glDepthMask(GL_TRUE);glDepthFunc(GL_LEQUAL);
      glDisable(GL_SCISSOR_TEST);glDisable(GL_BLEND);
      glColorMask(GL_TRUE,GL_TRUE,GL_TRUE,GL_TRUE);glClearColor(-1,1,0,0);
      glClearDepth(1);glClear(GL_DEPTH_BUFFER_BIT or GL_COLOR_BUFFER_BIT);
      glColorMask(GL_FALSE,GL_FALSE,GL_FALSE,GL_FALSE);
      { Same camera, alpha tests and posed vertices as the colour pass. A light
        camera's depth-only pass omits non-casting ground and is unsuitable. }
      RtxScreenCapturing:=True;
      try Draw(Params);finally RtxScreenCapturing:=False;end;
      FDynamicMeshes.Collect(FDynamicCasters,FActiveOrigin,Params);
      DynamicTarget:=FDynamicBuffer(FContext,FDynamicMeshes.Triangles);
      if (FDynamicMeshes.Triangles>0) and (DynamicTarget=0) then raise Exception.Create(string(FErrorText()));
      FDynamicMeshes.Upload(DynamicTarget);
      if not Matrix4Double(OldProjection).TryInverse(InverseProjection) then raise Exception.Create('Screen shadow projection is singular');
      { Reconstruct using (windowDepth - 1). Fold drFar into the inverse in
        Double; subtracting near-equal terms per pixel loses distant depth. }
      for I:=0 to 3 do begin
        InverseProjection.Data[3,I]:=InverseProjection.Data[3,I]+InverseProjection.Data[2,I];
        InverseProjection.Data[2,I]:=InverseProjection.Data[2,I]*(2.0/0.9);
      end;
      C.InverseProjection:=Matrix4(InverseProjection);
      Params.RenderingCamera.InverseMatrixNeeded;C.InverseView:=Params.RenderingCamera.InverseMatrix;
      for I:=0 to 2 do C.InverseView.Data[3,I]:=Double(C.InverseView.Data[3,I])-FActiveOrigin.Data[I];
      Focus:=FActiveFocus-FActiveOrigin;
      C.Sun:=Vector4(-FSun.X,-FSun.Y,-FSun.Z,0);C.Horizon:=Vector4(Focus.X,Focus.Y,Focus.Z,0);
      C.Zenith:=Vector4(Tan(DegToRad(ScreenSunRadius)),RTX_SCREEN_MAX_RAY_DISTANCE,ScreenRayCount,0);
      C.DepthRange:=Vector4(0.1,0.9,Ord(RtxScreenReceiverBounds),Ord(FScreenReuseActive));
      FScreenCamera:=C;
      I:=FScreenTrace(FContext,@C,FActiveSceneID);
      if I<>1 then raise Exception.Create('Screen shadow trace unavailable: '+string(FErrorText()));
      Tex:=FScreenTexture(FContext,1);Inc(FScreenFrames);
    except on E:Exception do begin
      Fail(E.Message);FScreenError:=E.Message;WritelnWarning('RTX screen shadows',E.Message);
    end;end;
  finally
    RtxScreenCapturing:=False;
    RenderContext.Viewport:=OldView;RenderContext.DepthRange:=OldRange;RenderContext.ProjectionMatrix:=OldProjection;
    RenderContext.DepthBufferUpdate:=S.DepthMask[0]<>0;RenderContext.DepthTest:=S.Depth<>0;
    RenderContext.DepthFunc:=TDepthFunction(S.DepthFunc);RenderContext.CullFace:=S.Cull<>0;
    RestoreGL(S);
    RtxScreenTexture:=Tex;RtxScreenView:=Vector4(OldView.Left,OldView.Bottom,OldView.Width,OldView.Height);
    Focus:=FActiveFocus-Camera;RtxScreenFocus:=Vector4(Focus.X,Focus.Y,Focus.Z,Radius);
  end;
end;
procedure TRtxShadow.CompositeScreenShadows;
var S:TGLState;BlendState:array[0..5]of GLint;
begin
  if (RtxScreenTexture=0) or not ScreenReady then Exit;
  SaveGL(S);
  glGetIntegerv(GL_BLEND_SRC_RGB,@BlendState[0]);glGetIntegerv(GL_BLEND_DST_RGB,@BlendState[1]);
  glGetIntegerv(GL_BLEND_SRC_ALPHA,@BlendState[2]);glGetIntegerv(GL_BLEND_DST_ALPHA,@BlendState[3]);
  glGetIntegerv(GL_BLEND_EQUATION_RGB,@BlendState[4]);glGetIntegerv(GL_BLEND_EQUATION_ALPHA,@BlendState[5]);
  try
    if FScreenComposite=0 then FScreenComposite:=ProgramFor('#version 330'#10+
      'in vec2 uv;out vec4 color;uniform sampler2D coverage;uniform float strength;'#10+
      'void main(){float s=texture(coverage,uv).r*strength;'#10+
      'color=vec4(mix(vec3(1.),vec3(.42,.45,.55),clamp(s,0.,1.)),1.);}'#10);
    if FVAO=0 then glGenVertexArrays(1,@FVAO);
    glUseProgram(FScreenComposite);glBindVertexArray(FVAO);
    glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_2D,RtxScreenTexture);
    glUniform1i(glGetUniformLocation(FScreenComposite,'coverage'),0);
    glUniform1f(glGetUniformLocation(FScreenComposite,'strength'),FScreenStrength);
    glDisable(GL_DEPTH_TEST);glDepthMask(GL_FALSE);glDisable(GL_CULL_FACE);
    glEnable(GL_BLEND);glBlendEquationSeparate(GL_FUNC_ADD,GL_FUNC_ADD);
    glBlendFuncSeparate(GL_ZERO,GL_SRC_COLOR,GL_ZERO,GL_ONE);
    glColorMask(GL_TRUE,GL_TRUE,GL_TRUE,GL_FALSE);glDrawArrays(GL_TRIANGLES,0,3);
  finally
    glBlendFuncSeparate(BlendState[0],BlendState[1],BlendState[2],BlendState[3]);
    glBlendEquationSeparate(BlendState[4],BlendState[5]);RestoreGL(S);
  end;
end;
procedure TRtxShadow.RenderReflections(const Params:TRenderParams;Draw:TRtxDrawReflectors);
var S:TGLState;OldView:TRectangle;OldRange:TDepthRange;C:TRtxReflectionCamera;
  W,H,I:Integer;Shader:UnicodeString;Tex:Cardinal;R:LongInt;OldProjection:TMatrix4;
  DebugPixels:array of TVector4;DebugHorizontal:array of Boolean;
  DebugDepth:array of Single;Eye:TVector4;Distance:Single;
begin
  if not GetReflectionsReady then begin
    SetRtxMaterialPass(False,0,Vector4(0,0,1,1));Exit;
  end;
  SaveGL(S);OldView:=RenderContext.Viewport;OldRange:=RenderContext.DepthRange;OldProjection:=RenderContext.ProjectionMatrix;
  Tex:=0;
  try
    try
      W:=Max(1,OldView.Width div 2);H:=Max(1,OldView.Height div 2);
      Shader:=UTF8Decode(UriToFilenameSafe('castle-data:/shaders/rtx/reflection.spv'));
      if FReflectionSize(FContext,PWideChar(Shader),W,H)=0 then raise Exception.Create(string(FErrorText()));
      if FReflectionFBO=0 then glGenFramebuffers(1,@FReflectionFBO);
      glBindFramebuffer(GL_DRAW_FRAMEBUFFER,FReflectionFBO);
      if (FUploadedAtlas<>FReflectionTexture(FContext,3)) and (FBuildingAtlas<>nil) then begin
        if FRgbaCopyProgram=0 then FRgbaCopyProgram:=ProgramFor('#version 330'#10'in vec2 uv;out vec4 color;uniform sampler2D source;void main(){color=texture(source,uv);}');
        glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER,GL_DEPTH_ATTACHMENT,GL_TEXTURE_2D,0,0);
        glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,FReflectionTexture(FContext,3),0);
        glViewport(0,0,1024,1024);glDisable(GL_DEPTH_TEST);glDisable(GL_SCISSOR_TEST);glDisable(GL_BLEND);glDisable(GL_CULL_FACE);glColorMask(GL_TRUE,GL_TRUE,GL_TRUE,GL_TRUE);
        if TTextureResources.Bind(FBuildingAtlas,0) then begin
          glUseProgram(FRgbaCopyProgram);glBindVertexArray(FVAO);glUniform1i(glGetUniformLocation(FRgbaCopyProgram,'source'),0);glDrawArrays(GL_TRIANGLES,0,3);
          FUploadedAtlas:=FReflectionTexture(FContext,3);
        end;
        RestoreGL(S);glBindFramebuffer(GL_DRAW_FRAMEBUFFER,FReflectionFBO);
      end;
      glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,FReflectionTexture(FContext,0),0);
      glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER,GL_DEPTH_ATTACHMENT,GL_TEXTURE_2D,FReflectionTexture(FContext,1),0);
      if glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER)<>GL_FRAMEBUFFER_COMPLETE then raise Exception.Create('Reflection framebuffer incomplete');
      RenderContext.Viewport:=Rectangle(0,0,W,H);RenderContext.DepthRange:=drFar;
      RenderContext.DepthBufferUpdate:=True;RenderContext.DepthTest:=True;
      { The atlas upload above uses raw GL. Reassert the depth state even when
        CGE's cache already believes it is enabled. }
      glEnable(GL_DEPTH_TEST);glDepthMask(GL_TRUE);glDepthFunc(GL_LEQUAL);
      glDisable(GL_SCISSOR_TEST);glDisable(GL_BLEND);glColorMask(GL_TRUE,GL_TRUE,GL_TRUE,GL_TRUE);glClearColor(0,0,0,0);glClearDepth(1);glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT);
      SetRtxMaterialPass(True,0,Vector4(0,0,W,H));Draw(Params);
      if not OldProjection.TryInverse(C.InverseProjection) then raise Exception.Create('Reflection camera projection is singular');
      Params.RenderingCamera.InverseMatrixNeeded;C.InverseView:=Params.RenderingCamera.InverseMatrix;
      for I:=0 to 2 do C.InverseView.Data[3,I]:=Double(C.InverseView.Data[3,I])-FActiveOrigin.Data[I];
      C.Sun:=Vector4(-FSun.X,-FSun.Y,-FSun.Z,0);C.Horizon:=Vector4(0.52,0.68,0.82,0);C.Zenith:=Vector4(0.15,0.3,0.5,0);C.DepthRange:=Vector4(0.1,0.9,0,0);
      C.Horizon.W:=FReflectionRanges.X;C.Zenith.W:=FReflectionRanges.Y;C.Sun.W:=FReflectionRanges.Z;
      C.DepthRange.W:=Ord(FReflectionRanges.X>0);
      R:=FReflect(FContext,@C,FActiveSceneID);
      if R<0 then raise Exception.Create(string(FErrorText()));
      if R=1 then begin Tex:=FReflectionTexture(FContext,2);Inc(FReflectionFrames);end
      else Inc(FReflectionDrops);
      if FDebugReflections and (Tex<>0) then begin
        FDebugReflections:=False;SetLength(DebugPixels,W*H);SetLength(DebugHorizontal,W*H);
        FDebugReceivers:=0;FDebugHits:=0;FDebugHorizontalReceivers:=0;FDebugHorizontalHits:=0;
        FDebugTracedReflections:=0;FDebugCachedReflections:=0;SetLength(DebugDepth,W*H);
        glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_2D,FReflectionTexture(FContext,1));
        glGetTexImage(GL_TEXTURE_2D,0,GL_DEPTH_COMPONENT,GL_FLOAT,Pointer(DebugDepth));
        glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_2D,FReflectionTexture(FContext,0));
        glGetTexImage(GL_TEXTURE_2D,0,GL_RGBA,GL_FLOAT,Pointer(DebugPixels));
        for I:=0 to High(DebugPixels) do begin
          DebugHorizontal[I]:=(DebugPixels[I].W>0.005)and(DebugPixels[I].Y>0.98);
          if (DebugPixels[I].W>0.005)and(DebugDepth[I]<0.9999999) then begin
            Inc(FDebugReceivers);
            Eye:=C.InverseProjection*Vector4(((I mod W)+0.5)/W*2-1,((I div W)+0.5)/H*2-1,
              ((DebugDepth[I]-0.1)/0.9)*2-1,1);
            Distance:=-Eye.Z/Eye.W;
            if (FReflectionRanges.X>0)and(Distance>FReflectionRanges.X)and
              ((Distance<FReflectionRanges.Y)or(Distance>FReflectionRanges.Z))then Inc(FDebugCachedReflections)
            else Inc(FDebugTracedReflections);
          end;
          if DebugHorizontal[I]then Inc(FDebugHorizontalReceivers);
        end;
        glBindTexture(GL_TEXTURE_2D,Tex);glGetTexImage(GL_TEXTURE_2D,0,GL_RGBA,GL_FLOAT,Pointer(DebugPixels));
        for I:=0 to High(DebugPixels) do if DebugPixels[I].W>0.005 then begin
          Inc(FDebugHits);if DebugHorizontal[I]then Inc(FDebugHorizontalHits);
        end;
      end;
    except on E:Exception do begin FReflectionError:=E.Message;WritelnWarning('RTX reflections',E.Message);end;end;
  finally
    RenderContext.Viewport:=OldView;RenderContext.DepthRange:=OldRange;RenderContext.ProjectionMatrix:=OldProjection;
    RenderContext.DepthBufferUpdate:=S.DepthMask[0]<>0;RenderContext.DepthTest:=S.Depth<>0;
    RenderContext.DepthFunc:=TDepthFunction(S.DepthFunc);RenderContext.CullFace:=S.Cull<>0;
    RestoreGL(S);
    SetRtxMaterialPass(False,Tex,Vector4(OldView.Left,OldView.Bottom,OldView.Width,OldView.Height));
  end;
end;
{$endif}
function TRtxShadow.TryGetScreenCasterRay(out ToSun:TVector3;
  out MaxRayDistance,ConeTangent:Single):Boolean;
begin
  ToSun:=TVector3.Zero;MaxRayDistance:=0;ConeTangent:=0;
  {$ifdef OpenGLES}
  Result:=False;
  {$else}
  Result:=GetScreenReady and (FSun.Length>0.000001);
  if Result then begin
    ToSun:=-FSun;
    MaxRayDistance:=RTX_SCREEN_MAX_RAY_DISTANCE;
    ConeTangent:=Tan(DegToRad(ScreenSunRadius));
    Result:=(ConeTangent>=0) and not IsInfinite(ConeTangent);
  end;
  {$endif}
end;
procedure TRtxShadow.DeferTrees(Count:Integer);
begin Inc(FDeferredTrees,Count);end;
end.
