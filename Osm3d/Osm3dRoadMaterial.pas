unit Osm3dRoadMaterial;
{$ifdef ANDROID}{$define OpenGLES}{$endif}

{$mode objfpc}{$H+}{$Q-}{$R-}

interface

uses SysUtils, Classes, CastleVectors, X3DNodes, X3DFields, Osm3dRiderShadow, Osm3dRoadSurface;

type
  TRoadMaterialMode = (rmmLegacy, rmmDirect, rmmCached);
  TRoadPageRequest = record
    Profile, Block: Integer;
    MinX, MinZ, MaxX, MaxZ: Single;
  end;
  TRoadPageRequests = array of TRoadPageRequest;

  { Lifetime follows geometry, including streamed tile eviction. Workers only
    publish immutable requests; GL work is confined to RoadMaterialRender. }
  TRoadCoordAttribute = class(TFloatVertexAttributeNode)
  private
    FNext: TRoadCoordAttribute;
    FPublished: Boolean;
    FRequests: TRoadPageRequests;
    FMinX,FMinZ,FMaxX,FMaxZ: Single;
  public
    procedure Publish(const Requests: TRoadPageRequests);
    destructor Destroy; override;
  end;

  TRoadGroundEffect = class(TRiderShadowGroundEffect)
  private
    FNextRoad: TRoadGroundEffect;
    FMode: TSFFloat;
  public
    constructor Create(const AX3DName: string = ''; const ABaseUrl: string = ''); override;
    destructor Destroy; override;
  end;

function RoadMaterialGLSL: string;
function RoadMaterialSamplingGLSL: string;
function RoadMaterialRegister(AWay: Int64; AWidth: Single; MotorLanes: Integer; const Layout:TRoadLaneLayout; out Seed: Single; Condition: Integer = 0; Concrete: Boolean = False): Integer;
function RoadMaterialRegisterArea(Row: Integer; Condition: Integer = 0): Integer;
procedure SetRoadMaterialMode(Mode: TRoadMaterialMode; SavePreference: Boolean = True);
function RoadMaterialMode: TRoadMaterialMode;
function RoadMaterialModeName: string;
procedure RoadMaterialRender(const Focus: TVector3);
function RoadMaterialDebug: string;

implementation

uses RenderComplexity, Math, Generics.Collections, IniFiles, {$ifdef OpenGLES}CastleGLES, RenderGLES{$else}CastleGL{$endif}, CastleApplicationProperties,
  CastleTimeUtils, CastleLog, CastleFilesUtils, CastleUriUtils,
  CastleRenderOptions, CastleInternalRenderer, CastleRendererInternalShader,
  CastleRendererInternalTextureEnv, Osm3dRenderInstanced;

const
  AtlasSize = 2048;
  PageSize = 256;
  PageInside = 240;
  PageBorder = 8;
  PageCount = 64;
  PageMeters = 16.0;
  TableSize = 1024;
  BlocksPerRoad = 64;
  AreaDirectorySize = 64*64*6; // one directory per wear level, including legacy
  MaxProfiles = (TableSize*TableSize-AreaDirectorySize) div BlocksPerRoad;
  MaxMip = 4;

type
  TProfile = record Width, Seed, Origin: Single; AreaRow, MotorLanes, Condition: Integer; IsArea, Concrete: Boolean; Layout:TRoadLaneLayout end;
  TPage = record Profile, Block: Integer; LastWanted: QWord; Distance: Single end;
  TRoadTextureNode = class(TShaderTextureNode)
  public Kind: Integer end;
  TRoadTextureResource = class(TSingleTextureResource)
  protected
    class function IsClassForTextureNode(ANode: TAbstractTextureNode): Boolean; override;
    procedure PrepareCore(const RenderOptions: TCastleRenderOptions); override;
    procedure UnprepareCore; override;
  public
    function Bind(const TextureUnit: Cardinal): Boolean; override;
    function Enable(const TextureUnit: Cardinal; Shader: TShader; const Env: TTextureEnv): Boolean; override;
  end;
  TCache = class
  public
    Textures: array[0..3] of GLuint; // albedo, normal/AO, directory, metric height
    FBO, VAO, ProgramId, LayoutTexture: GLuint;
    UploadedLayouts, LayoutColumns, LayoutCapacity: Integer;
    UniPage, UniProfile, UniRoad, UniLayout: GLint;
    Pages: array[0..PageCount-1] of TPage;
    Directory: array of TVector4;
    Frame, Generated, Hits, Misses: QWord;
    RequestCount: Integer;
    Closest: Single;
    FocusPosition: TVector3;
    LastSubmitMs: Double;
    LastScan: TTimerResult;
    Failed: Boolean;
    constructor Create;
    destructor Destroy; override;
    procedure ContextClose(Sender: TObject);
    procedure ReleasePages;
    procedure Ensure;
    procedure UploadLayouts;
    procedure WriteDirectory(Profile, Block, Page: Integer);
    procedure Bake(Page, Profile, Block: Integer);
  end;

var
  Lock: TRTLCriticalSection;
  Profiles: array of TProfile;
  ProfileMap: specialize TDictionary<string,Integer>;
  Attributes: TRoadCoordAttribute = nil;
  Effects: TRoadGroundEffect = nil;
  CurrentMode: TRoadMaterialMode = rmmCached;
  Cache: TCache = nil;

function RoadMaterialGLSL: string;
begin
  Result := {$I shaders/road_material.glsl.inc};
end;

function RoadMaterialSamplingGLSL: string;
begin
  Result := RoadMaterialGLSL +
    'uniform float rp_mode, rz_complexity;' + #10 +
    'uniform sampler2D rp_color, rp_normal, rp_table, rp_height;' + #10 +
    'varying vec4 vRoadCoord, vRoadStyle;' + #10 +
    'vec4 rp_laneLayout(vec4 coord, vec4 style) {' + #10 +
    '  int profile=int(floor(coord.w+0.5));' + #10 +
    '  vec4 meta=rp_laneMeta(profile,style.x+style.y);' + #10 +
    '  vec4 lane=rp_laneInterval(coord.y,coord.z,profile,meta);' + #10 +
    '  float a=lane.x,b=lane.y; int idx=int(lane.z),count=int(lane.w);' + #10 +
    '  float forward=style.x, central=meta.z;' + #10 +
    '  bool twoWay=style.x>0.5 && style.y>0.5;' + #10 +
    '  float left=(idx==0 || (twoWay && count>2 && (abs(float(idx)-forward)<0.1 || abs(float(idx)-forward-central)<0.1))) ? 2.0 : 1.0;' + #10 +
    '  float right=(idx==count-1 || (twoWay && count>2 && (abs(float(idx+1)-forward)<0.1 || abs(float(idx+1)-forward-central)<0.1))) ? 2.0 : 1.0;' + #10 +
    '  return vec4(a,b,left,right);' + #10 +
    '}' + #10 +
    'void rp_sample(vec4 coord, vec4 style, vec2 dx, vec2 dy, vec3 viewTS,' + #10 +
    '               out vec4 color, out vec4 normalData) {' + #10 +
    '  vec2 p=coord.xy;' + #10 +
    '  if (coord.w < -1.5) { rp_curb(p,max(abs(dx),abs(dy))*0.5,color,normalData); return; }' + #10 +
    '  float width=coord.z;' + #10 +
    '  vec2 footprint=max(abs(dx),abs(dy))*0.5;' + #10 +
    '  float block=floor(p.x/16.0);' + #10 +
    '  style=floor(style+vec4(0.5)); coord.w=floor(coord.w+0.5);' + #10 +
    '  bool area=coord.w< -0.5; float row=floor(p.y/16.0);' + #10 +
    '  float condition=floor(mod(style.z,128.0)/16.0);' + #10 +
    '  int address=area ? int(condition)*4096+int(mod(row,64.0))*64+int(mod(block,64.0)) : 24576+int(coord.w)*64+int(mod(block,64.0));' + #10 +
    '  vec4 entry=vec4(0); if(rp_mode>1.5 && (area || coord.w>0.5)) entry=texelFetch(rp_table,ivec2(address%1024,address/1024),0);' + #10 +
    '  bool cached=rp_mode>1.5 && (area || coord.w>0.5) && entry.x>0.5 && abs(entry.y-block)<0.1 && abs(entry.w-condition)<0.1 && (!area || abs(entry.z-row)<0.1);' + #10 +
    '  float surfaceHeight=0.0;' + #10 +
    '  vec2 detailP=p;' + #10 +
    '  float refine=cached ? 1.0-smoothstep(0.012,0.04,max(footprint.x,footprint.y)) : 1.0;' + #10 +
    '  if (cached && rz_complexity<1.5) refine=0.0;' + #10 +
    '  if (cached) {' + #10 +
    '    int page=int(entry.x)-1;' + #10 +
    '    vec2 cell=vec2(float(page%8),float(page/8));' + #10 +
    '    vec2 uv=vec2(p.x/16.0-block,(area ? p.y/16.0-row : p.y/width+0.5));' + #10 +
    '    vec2 at=(cell*256.0+8.0+clamp(uv,vec2(0),vec2(1))*240.0)/2048.0;' + #10 +
    '    vec2 gx=dx/vec2(16.0,width)*(240.0/2048.0);' + #10 +
    '    vec2 gy=dy/vec2(16.0,width)*(240.0/2048.0);' + #10 +
    '    // Two height taps, only where centimeter relief is visible. The' + #10 +
    '    // page apron covers the bounded offset across page boundaries.' + #10 +
    '    float reliefFade=1.0-smoothstep(0.025,0.09,max(footprint.x,footprint.y));' + #10 +
    '    surfaceHeight=textureGrad(rp_height,at,gx,gy).r;' + #10 +
    '    if(reliefFade>0.0 && rz_complexity>2.5) {' + #10 +
    '      vec2 ray=clamp(viewTS.yx/max(abs(viewTS.z),0.25),vec2(-3.0),vec2(3.0))*reliefFade;' + #10 +
    '      vec2 metricToAtlas=vec2(1.0/16.0,1.0/width)*(240.0/2048.0);' + #10 +
    '      vec2 shift=ray*surfaceHeight*metricToAtlas;' + #10 +
    '      surfaceHeight=textureGrad(rp_height,clamp(at+shift,(cell*256.0+0.5)/2048.0,(cell*256.0+255.5)/2048.0),gx,gy).r;' + #10 +
    '      at+=ray*surfaceHeight*metricToAtlas;' + #10 +
    '      detailP+=ray*surfaceHeight;' + #10 +
    '      at=clamp(at,(cell*256.0+0.5)/2048.0,(cell*256.0+255.5)/2048.0);' + #10 +
    '    }' + #10 +
    '    color=textureGrad(rp_color,at,gx,gy);' + #10 +
    '    normalData=textureGrad(rp_normal,at,gx,gy);' + #10 +
    '    refine*=max(smoothstep(0.005,0.08,1.0-normalData.z),smoothstep(0.001,0.004,abs(surfaceHeight)));' + #10 +
    '  } else { color=vec4(0); normalData=vec4(0.5,0.5,1.0,0.0); }' + #10 +
    '  // The page stores centimeters per texel. Resolve subtexel fractures' + #10 +
    '  // at screen resolution nearby, smoothly returning to cached relief.' + #10 +
    '  if(refine>0.0) {' + #10 +
    '    vec3 relief; vec4 detailedColor; vec2 heightGradient;' + #10 +
    '    rp_roadGradient(detailP,style.w,max(footprint.x,footprint.y),vec3(width,max(coord.w,0.0),area ? 0.0 : rp_motorLanes(style)),condition,step(128.0,style.z),detailedColor,relief,heightGradient);' + #10 +
    '    color=mix(color,detailedColor,refine);' + #10 +
    '    normalData.xy=mix(normalData.xy,rp_gradientNormal(heightGradient)*0.5+0.5,refine);' + #10 +
    '    normalData.zw=mix(normalData.zw,vec2(1.0-relief.y,relief.z),refine);' + #10 +
    '  }' + #10 +
    '  if(rz_complexity<0.5)normalData.xy=vec2(0.5);' + #10 +
    '  rp_finish(p,width,style,footprint,rp_laneLayout(coord,style),color,normalData);' + #10 +
    '}' + #10;
end;

function RoadMaterialRegister(AWay: Int64; AWidth: Single; MotorLanes: Integer; const Layout:TRoadLaneLayout; out Seed: Single; Condition: Integer; Concrete: Boolean): Integer;
var Key: string; H: QWord; I:Integer;
begin
  H := QWord(AWay);
  H := (H xor (H shr 30))*QWord($BF58476D1CE4E5B9);
  H := (H xor (H shr 27))*QWord($94D049BB133111EB);
  H := H xor (H shr 31);
  Seed := H and $FFFF;
  Key := IntToStr(AWay)+':'+IntToStr(Round(AWidth*1000))+':'+IntToStr(MotorLanes);
  Condition:=EnsureRange(Condition,0,5);Key:=Key+':wear='+IntToStr(Condition);
  Key:=Key+':concrete='+IntToStr(Ord(Concrete));
  Key:=Key+':'+IntToStr(Layout.Count)+':'+IntToStr(Layout.BothWays)+':'+IntToStr(Round(Layout.Edge*1000));
  for I:=0 to Layout.Count-1 do Key:=Key+':'+IntToStr(Round(Layout.Widths[I]*1000));
  EnterCriticalSection(Lock);
  try
    if ProfileMap.TryGetValue(Key,Result) then Exit;
    Result := Length(Profiles);
    if Result >= MaxProfiles then Exit(0); // direct, never a wrong cache entry
    SetLength(Profiles,Result+1);
    Profiles[Result].Width := AWidth;
    Profiles[Result].Layout := Layout;
    Profiles[Result].MotorLanes := MotorLanes;
    Profiles[Result].Seed := Seed;
    Profiles[Result].Condition := Condition;
    Profiles[Result].Concrete := Concrete;
    ProfileMap.Add(Key,Result);
  finally LeaveCriticalSection(Lock) end;
end;

function RoadMaterialRegisterArea(Row: Integer; Condition: Integer): Integer;
var Key:string;
begin
  Condition:=EnsureRange(Condition,0,5);
  Key:='area:'+IntToStr(Row)+':wear='+IntToStr(Condition);
  EnterCriticalSection(Lock);
  try
    if ProfileMap.TryGetValue(Key,Result) then Exit;
    Result:=Length(Profiles); if Result>=MaxProfiles then Exit(0);
    SetLength(Profiles,Result+1);
    Profiles[Result].Width:=16; Profiles[Result].Seed:=0;
    Profiles[Result].Origin:=(Row+0.5)*16;
    Profiles[Result].AreaRow:=Row; Profiles[Result].IsArea:=True;
    Profiles[Result].Condition:=Condition;
    ProfileMap.Add(Key,Result);
  finally LeaveCriticalSection(Lock) end;
end;

function PageAddress(Profile,Block:Integer):Integer;
begin
  if Profiles[Profile].IsArea then
    Result:=Profiles[Profile].Condition*4096+((Profiles[Profile].AreaRow mod 64)+64) mod 64*64
  else Result:=AreaDirectorySize+Profile*BlocksPerRoad;
  Inc(Result,((Block mod BlocksPerRoad)+BlocksPerRoad) mod BlocksPerRoad);
end;

procedure TRoadCoordAttribute.Publish(const Requests: TRoadPageRequests);
var I:Integer;
begin
  EnterCriticalSection(Lock);
  try
    Assert(not FPublished);
    FRequests := Requests;
    FMinX:=1e20; FMinZ:=1e20; FMaxX:=-1e20; FMaxZ:=-1e20;
    for I:=0 to High(Requests) do
    begin
      FMinX:=Min(FMinX,Requests[I].MinX); FMinZ:=Min(FMinZ,Requests[I].MinZ);
      FMaxX:=Max(FMaxX,Requests[I].MaxX); FMaxZ:=Max(FMaxZ,Requests[I].MaxZ);
    end;
    FNext := Attributes; Attributes := Self; FPublished := True;
  finally LeaveCriticalSection(Lock) end;
end;

destructor TRoadCoordAttribute.Destroy;
var A: TRoadCoordAttribute;
begin
  EnterCriticalSection(Lock);
  try
    if FPublished then
      if Attributes=Self then Attributes:=FNext else
      begin
        A:=Attributes;
        while (A<>nil) and (A.FNext<>Self) do A:=A.FNext;
        if A<>nil then A.FNext:=FNext;
      end;
    inherited;
  finally LeaveCriticalSection(Lock) end;
end;

constructor TRoadGroundEffect.Create(const AX3DName, ABaseUrl: string);
const Names: array[0..4] of string = ('rp_color','rp_normal','rp_table','rp_layout','rp_height');
var N: TRoadTextureNode; I: Integer;
begin
  inherited;
  AttachRenderComplexity(Self,rdWorld);
  FMode := TSFFloat.Create(Self,True,'rp_mode',Ord(CurrentMode));
  AddCustomField(FMode);
  for I:=0 to 4 do
  begin
    N:=TRoadTextureNode.Create; N.Kind:=I;
    AddCustomField(TSFNode.Create(Self,True,Names[I],[TShaderTextureNode],N));
  end;
  EnterCriticalSection(Lock);
  try
    // A worker may have constructed this effect while the UI switched mode.
    FMode.Value:=Ord(CurrentMode);
    FNextRoad:=Effects; Effects:=Self;
  finally LeaveCriticalSection(Lock) end;
end;

destructor TRoadGroundEffect.Destroy;
var E: TRoadGroundEffect;
begin
  EnterCriticalSection(Lock);
  try
    if Effects=Self then Effects:=FNextRoad else
    begin
      E:=Effects;
      while (E<>nil) and (E.FNextRoad<>Self) do E:=E.FNextRoad;
      if E<>nil then E.FNextRoad:=FNextRoad;
    end;
    inherited;
  finally LeaveCriticalSection(Lock) end;
end;

function PreferencePath: string;
begin
  {$ifdef ANDROID}
  Result:=UriToFilenameSafe(ApplicationConfig('road-material.ini'));
  {$else}
  Result:=IncludeTrailingPathDelimiter(GetEnvironmentVariable('LOCALAPPDATA'))+
    'third_person_navigation'+PathDelim+'road-material.ini';
  {$endif}
end;

procedure SetRoadMaterialMode(Mode: TRoadMaterialMode; SavePreference: Boolean);
var E: TRoadGroundEffect; Ini: TIniFile;
begin
  { Compatibility with old preferences/MCP clients. Photographic asphalt is
    no longer distributed; the uncached mode still renders procedural roads. }
  if Mode=rmmLegacy then Mode:=rmmDirect;
  EnterCriticalSection(Lock);
  try
    if (Mode=rmmCached) and (Cache<>nil) and Cache.Failed then Mode:=rmmDirect;
    CurrentMode:=Mode;
    E:=Effects;
    while E<>nil do
    begin
      if E.FMode.Value<>Ord(Mode) then E.FMode.Send(Ord(Mode));
      E:=E.FNextRoad;
    end;
  finally LeaveCriticalSection(Lock) end;
  if SavePreference then
  begin
    ForceDirectories(ExtractFilePath(PreferencePath));
    Ini:=TIniFile.Create(PreferencePath);
    try Ini.WriteInteger('road','mode',Ord(Mode)); finally Ini.Free end;
  end;
end;

function RoadMaterialMode: TRoadMaterialMode;
begin Result:=CurrentMode end;

function RoadMaterialModeName: string;
const Names: array[TRoadMaterialMode] of string = ('legacy','direct','cached');
begin Result:=Names[CurrentMode] end;

class function TRoadTextureResource.IsClassForTextureNode(ANode: TAbstractTextureNode): Boolean;
begin Result:=ANode is TRoadTextureNode end;
procedure TRoadTextureResource.PrepareCore(const RenderOptions: TCastleRenderOptions);
begin end;
procedure TRoadTextureResource.UnprepareCore;
begin end;
function TRoadTextureResource.Bind(const TextureUnit: Cardinal): Boolean;
var K: Integer;
begin
  K:=TRoadTextureNode(TextureNode).Kind;
  glActiveTexture(GL_TEXTURE0+TextureUnit);
  if Cache<>nil then
  begin
    if K=3 then glBindTexture(GL_TEXTURE_2D,Cache.LayoutTexture)
    else if K=4 then glBindTexture(GL_TEXTURE_2D,Cache.Textures[3])
    else glBindTexture(GL_TEXTURE_2D,Cache.Textures[K]);
  end
  else glBindTexture(GL_TEXTURE_2D,0);
  Result:=True;
end;
function TRoadTextureResource.Enable(const TextureUnit: Cardinal; Shader: TShader; const Env: TTextureEnv): Boolean;
begin Result:=Bind(TextureUnit) end;

constructor TCache.Create;
begin
  inherited;
  SetLength(Directory,TableSize*TableSize);
  ApplicationProperties.OnGLContextCloseObject.Add(@ContextClose);
end;
destructor TCache.Destroy;
begin
  ApplicationProperties.OnGLContextCloseObject.Remove(@ContextClose);
  ContextClose(nil);
  inherited;
end;
procedure TCache.ContextClose(Sender: TObject);
begin
  ReleasePages;
  if LayoutTexture<>0 then glDeleteTextures(1,@LayoutTexture);
  LayoutTexture:=0; UploadedLayouts:=0; LayoutColumns:=0; LayoutCapacity:=0;
  Failed:=False;
end;

procedure TCache.ReleasePages;
begin
  if ProgramId<>0 then glDeleteProgram(ProgramId);
  if FBO<>0 then glDeleteFramebuffers(1,@FBO);
  if VAO<>0 then glDeleteVertexArrays(1,@VAO);
  if Textures[0]<>0 then glDeleteTextures(4,@Textures[0]);
  ProgramId:=0; FBO:=0; VAO:=0;
  FillChar(Textures,SizeOf(Textures),0);
  FillChar(Pages,SizeOf(Pages),0);
  if Length(Directory)>0 then FillChar(Directory[0],Length(Directory)*SizeOf(TVector4),0);
end;

procedure TCache.UploadLayouts;
var OldTex,I,J,K,Rows,Columns,Capacity,MaxSize:Integer;
  Data:array of Single; Sum:Single;
begin
  if UploadedLayouts=Length(Profiles) then Exit;
  { Header followed by exact lane boundaries, four per texel. Allocation
    no longer scales with the narrowest lane anywhere in the session. }
  Columns:=1+(ROAD_MAX_LANES+4) div 4;
  Capacity:=Max(256,LayoutCapacity);
  while Capacity<Length(Profiles) do Capacity:=Min(MaxProfiles,Capacity*2);
  glGetIntegerv(GL_MAX_TEXTURE_SIZE,@MaxSize);
  if (Columns>MaxSize) or (Capacity>MaxSize) then
    raise Exception.Create('Road lane table exceeds GL_MAX_TEXTURE_SIZE');
  glGetIntegerv(GL_TEXTURE_BINDING_2D,@OldTex);
  try
    if LayoutTexture=0 then glGenTextures(1,@LayoutTexture);
    glBindTexture(GL_TEXTURE_2D,LayoutTexture);
    if (Columns<>LayoutColumns) or (Capacity<>LayoutCapacity) then
    begin
      glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA32F,Columns,Capacity,0,GL_RGBA,GL_FLOAT,nil);
      glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST);
      glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
      glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAX_LEVEL,0);
      LayoutColumns:=Columns; LayoutCapacity:=Capacity; UploadedLayouts:=0;
    end;
    Rows:=Length(Profiles)-UploadedLayouts; SetLength(Data,Rows*Columns*4);
    for I:=0 to Rows-1 do
    with Profiles[UploadedLayouts+I].Layout do
    begin
      K:=I*Columns*4; Data[K]:=Count; Data[K+1]:=Edge;
      Data[K+2]:=BothWays; Data[K+3]:=Custom;
      if Custom=0 then Continue;
      Sum:=Edge; Data[K+4]:=Sum;
      for J:=0 to Count-1 do begin
        Sum:=Sum+Widths[J];Data[K+5+J]:=Sum;
      end;
    end;
    glTexSubImage2D(GL_TEXTURE_2D,0,0,UploadedLayouts,Columns,Rows,GL_RGBA,GL_FLOAT,@Data[0]);
    UploadedLayouts:=Length(Profiles);
  finally glBindTexture(GL_TEXTURE_2D,OldTex) end;
end;

procedure TCache.Ensure;
var VS,FS: GLuint; I,L: Integer;
begin
  if Textures[0]<>0 then Exit;
  glGenTextures(4,@Textures[0]);
  glGenFramebuffers(1,@FBO);
  {$ifdef OpenGLES}
  { ES 3 guarantees sampling these formats, but float render targets depend
    on the GPU. Probe tiny targets before allocating the full page cache.
    The caller falls back to the same procedural shader without caching. }
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER,FBO);
  for I:=2 to 3 do
  begin
    glBindTexture(GL_TEXTURE_2D,Textures[I]);
    if I=2 then
      glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA32F,1,1,0,GL_RGBA,GL_FLOAT,nil)
    else
      glTexImage2D(GL_TEXTURE_2D,0,GL_R16F,1,1,0,GL_RED,GL_FLOAT,nil);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
    glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,Textures[I],0);
    glDrawBuffer(GL_COLOR_ATTACHMENT0);
    if glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER)<>GL_FRAMEBUFFER_COMPLETE then
      raise Exception.Create('Floating-point road cache is not supported by this GPU');
  end;
  glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,0,0);
  {$endif}
  for I:=0 to 3 do
  begin
    if I=2 then Continue; // directory uses its own size and integer addressing
    glBindTexture(GL_TEXTURE_2D,Textures[I]);
    for L:=0 to MaxMip do
      if I=3 then
        glTexImage2D(GL_TEXTURE_2D,L,GL_R16F,AtlasSize shr L,AtlasSize shr L,0,GL_RED,GL_FLOAT,nil)
      else
        glTexImage2D(GL_TEXTURE_2D,L,GL_RGBA8,AtlasSize shr L,AtlasSize shr L,0,GL_RGBA,GL_UNSIGNED_BYTE,nil);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAX_LEVEL,MaxMip);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR_MIPMAP_LINEAR);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
  end;
  glBindTexture(GL_TEXTURE_2D,Textures[2]);
  glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA32F,TableSize,TableSize,0,GL_RGBA,GL_FLOAT,@Directory[0]);
  glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
  glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAX_LEVEL,0);
  glGenVertexArrays(1,@VAO);
  VS:=CompileShader(GL_VERTEX_SHADER,
    '#version 330 core'+#10+
    'void main(){vec2 p=vec2(float((gl_VertexID<<1)&2),float(gl_VertexID&2));'+
    'gl_Position=vec4(p*2.0-1.0,0.0,1.0);}', 'Road pages VS');
  try
    FS:=CompileShader(GL_FRAGMENT_SHADER,
      '#version 330 core'+#10+RoadMaterialGLSL+
      'uniform vec4 rp_page, rp_profile, rp_road;'+#10+
      'layout(location=0) out vec4 color; layout(location=1) out vec4 normalData; layout(location=2) out float heightData;'+#10+
      'void main(){'+#10+
      ' vec2 uv=((gl_FragCoord.xy-rp_page.xy)/rp_page.z-vec2(0.03125))/0.9375;'+#10+
      ' vec2 p=vec2((rp_profile.x+uv.x)*16.0,(uv.y-0.5)*rp_profile.y+rp_profile.w);'+#10+
      ' vec3 relief; vec2 heightGradient; rp_roadGradient(p,rp_profile.z,max(16.0,rp_profile.y)/(rp_page.z*0.9375)*0.5,rp_road.xyz,rp_road.w,rp_page.w,color,relief,heightGradient);'+#10+
      ' vec2 n=rp_gradientNormal(heightGradient);'+#10+
      ' normalData=vec4(n*0.5+0.5,1.0-relief.y,relief.z); heightData=relief.x;'+#10+
      '}', 'Road pages FS');
    try ProgramId:=LinkProgram(VS,FS,'Road pages'); finally glDeleteShader(FS) end;
  finally glDeleteShader(VS) end;
  UniPage:=glGetUniformLocation(ProgramId,'rp_page');
  UniProfile:=glGetUniformLocation(ProgramId,'rp_profile');
  UniRoad:=glGetUniformLocation(ProgramId,'rp_road');
  UniLayout:=glGetUniformLocation(ProgramId,'rp_layout');
end;

procedure TCache.WriteDirectory(Profile, Block, Page: Integer);
var Address: Integer; V: TVector4;
begin
  if Profile<=0 then Exit;
  Address:=PageAddress(Profile,Block);
  V:=Vector4(Page+1,Block,Profiles[Profile].AreaRow,Profiles[Profile].Condition);
  Directory[Address]:=V;
  // Update the directory on the GPU command stream. TexSubImage on a
  // directory sampled by the preceding frame can serialize the CPU/driver
  // or copy the entire texture for a single changed entry.
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER,FBO);
  glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,Textures[2],0);
  glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER,GL_COLOR_ATTACHMENT1,GL_TEXTURE_2D,0,0);
  glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER,GL_COLOR_ATTACHMENT2,GL_TEXTURE_2D,0,0);
  glDrawBuffer(GL_COLOR_ATTACHMENT0);
  glEnable(GL_SCISSOR_TEST);
  glScissor(Address mod TableSize,Address div TableSize,1,1);
  glClearBufferfv(GL_COLOR,0,@V);
  glDisable(GL_SCISSOR_TEST);
end;

procedure TCache.Bake(Page, Profile, Block: Integer);
const Buffers: array[0..2] of GLenum=(GL_COLOR_ATTACHMENT0,GL_COLOR_ATTACHMENT1,GL_COLOR_ATTACHMENT2);
var L,S,X,Y,OldAddress: Integer; P:TProfile;
begin
  P:=Profiles[Profile];
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER,FBO);
  glDrawBuffers(3,@Buffers[0]);
  glUseProgram(ProgramId); glBindVertexArray(VAO);
  glUniform4f(UniProfile,Block,P.Width,P.Seed,P.Origin);
  glUniform4f(UniRoad,P.Width,Profile,P.MotorLanes,P.Condition);
  // RoadMaterialRender owns/restores texture unit 0 around page generation.
  glBindTexture(GL_TEXTURE_2D,LayoutTexture);
  glUniform1i(UniLayout,0);
  for L:=0 to MaxMip do
  begin
    S:=PageSize shr L; X:=(Page mod 8)*S; Y:=(Page div 8)*S;
    glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,Textures[0],L);
    glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER,GL_COLOR_ATTACHMENT1,GL_TEXTURE_2D,Textures[1],L);
    glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER,GL_COLOR_ATTACHMENT2,GL_TEXTURE_2D,Textures[3],L);
    if glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER)<>GL_FRAMEBUFFER_COMPLETE then
      raise Exception.Create('Road page framebuffer incomplete');
    glViewport(X,Y,S,S);
    glUniform4f(UniPage,X,Y,S,Ord(P.Concrete));
    glDrawArrays(GL_TRIANGLES,0,3);
  end;
  if Pages[Page].Profile<>0 then
  begin
    OldAddress:=PageAddress(Pages[Page].Profile,Pages[Page].Block);
    if (Round(Directory[OldAddress].X)=Page+1) and
       (Abs(Directory[OldAddress].Y-Pages[Page].Block)<0.1) then
      WriteDirectory(Pages[Page].Profile,Pages[Page].Block,-1);
  end;
  Pages[Page].Profile:=Profile; Pages[Page].Block:=Block;
  Pages[Page].LastWanted:=Frame;
  WriteDirectory(Profile,Block,Page);
  Inc(Generated);
end;

procedure RoadMaterialRender(const Focus: TVector3);
var
  A: TRoadCoordAttribute; R: TRoadPageRequest; I,J,Slot,BestP,BestB,Address: Integer;
  Dx,Dz,Dist,BestDist: Single;
  OldProgram,OldVAO,OldFBO,OldTex,OldActive: GLint;
  VP, ScissorBox: array[0..3] of GLint;
  Mask: array[0..3] of GLboolean;
  Depth,Blend,Cull,Scissor,SRGB: GLboolean;
  Started: TTimerResult;
begin
  if CurrentMode=rmmLegacy then Exit;
  EnterCriticalSection(Lock);
  try
    if Attributes=nil then Exit;
    if Cache=nil then Cache:=TCache.Create;
    Cache.UploadLayouts;
    if (CurrentMode<>rmmCached) or Cache.Failed then Exit;
    Inc(Cache.Frame);
    // Bound both scheduling and generation to 40 Hz, independently of the
    // unlimited render FPS. A missing page immediately uses the direct shader.
    if (Cache.Frame>1) and (TimerSeconds(Timer,Cache.LastScan)<0.025) then Exit;
    Cache.LastScan:=Timer;
    BestP:=0; BestB:=0; BestDist:=150*150;
    for I:=0 to PageCount-1 do Cache.Pages[I].Distance:=1e20;
    Cache.RequestCount:=0; Cache.Closest:=1e20; Cache.FocusPosition:=Focus;
    A:=Attributes;
    while A<>nil do
    begin
      Dx:=Max(Max(A.FMinX-Focus.X,Focus.X-A.FMaxX),0.0);
      Dz:=Max(Max(A.FMinZ-Focus.Z,Focus.Z-A.FMaxZ),0.0);
      if Dx*Dx+Dz*Dz>150*150 then begin A:=A.FNext; Continue end;
      for I:=0 to High(A.FRequests) do
      begin
        R:=A.FRequests[I];
        Dx:=Max(Max(R.MinX-Focus.X,Focus.X-R.MaxX),0.0);
        Dz:=Max(Max(R.MinZ-Focus.Z,Focus.Z-R.MaxZ),0.0);
        Dist:=Dx*Dx+Dz*Dz;
        Inc(Cache.RequestCount); Cache.Closest:=Min(Cache.Closest,Sqrt(Dist));
        if Dist>150*150 then Continue;
        Address:=PageAddress(R.Profile,R.Block);
        J:=Round(Cache.Directory[Address].X)-1;
        if (J>=0) and (Abs(Cache.Directory[Address].Y-R.Block)<0.1) and
           (Abs(Cache.Directory[Address].Z-Profiles[R.Profile].AreaRow)<0.1) and
           (Abs(Cache.Directory[Address].W-Profiles[R.Profile].Condition)<0.1) then
        begin Cache.Pages[J].LastWanted:=Cache.Frame; Cache.Pages[J].Distance:=Min(Cache.Pages[J].Distance,Dist); Inc(Cache.Hits) end
        else
        begin
          Inc(Cache.Misses);
          if Dist<BestDist then
          begin BestDist:=Dist; BestP:=R.Profile; BestB:=R.Block end;
        end;
      end;
      A:=A.FNext;
    end;
    if BestP=0 then Exit;
    Slot:=-1;
    for I:=0 to PageCount-1 do
      if Cache.Pages[I].Profile=0 then begin Slot:=I; Break end;
    if Slot<0 then
      for I:=0 to PageCount-1 do
        if (Cache.Pages[I].Distance>BestDist+0.01) and
           ((Slot<0) or (Cache.Pages[I].Distance>Cache.Pages[Slot].Distance)) then Slot:=I;
    if Slot<0 then Exit; // no cache thrashing; missing areas use the direct material
    Started:=Timer;
    glGetIntegerv(GL_CURRENT_PROGRAM,@OldProgram);
    glGetIntegerv(GL_VERTEX_ARRAY_BINDING,@OldVAO);
    glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING,@OldFBO);
    glGetIntegerv(GL_VIEWPORT,@VP[0]);
    glGetIntegerv(GL_SCISSOR_BOX,@ScissorBox[0]);
    glGetIntegerv(GL_ACTIVE_TEXTURE,@OldActive);
    glActiveTexture(GL_TEXTURE0);
    glGetIntegerv(GL_TEXTURE_BINDING_2D,@OldTex);
    glGetBooleanv(GL_COLOR_WRITEMASK,@Mask[0]);
    Depth:=glIsEnabled(GL_DEPTH_TEST); Blend:=glIsEnabled(GL_BLEND);
    Cull:=glIsEnabled(GL_CULL_FACE); Scissor:=glIsEnabled(GL_SCISSOR_TEST);
    {$ifndef OpenGLES}SRGB:=glIsEnabled(GL_FRAMEBUFFER_SRGB);{$endif}
    try
      try
      glDisable(GL_DEPTH_TEST); glDisable(GL_BLEND); glDisable(GL_CULL_FACE);
      glDisable(GL_SCISSOR_TEST); {$ifndef OpenGLES}glDisable(GL_FRAMEBUFFER_SRGB);{$endif}
      glColorMask(GL_TRUE,GL_TRUE,GL_TRUE,GL_TRUE);
      Cache.Ensure;
      Cache.Bake(Slot,BestP,BestB);
      except
        on E:Exception do
        begin
          Cache.ReleasePages;
          Cache.Failed:=True;
          SetRoadMaterialMode(rmmDirect,False);
          WritelnWarning('Road material','Page cache disabled: '+E.Message);
        end;
      end;
    finally
    glUseProgram(OldProgram); glBindVertexArray(OldVAO);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER,OldFBO);
    glViewport(VP[0],VP[1],VP[2],VP[3]);
    glScissor(ScissorBox[0],ScissorBox[1],ScissorBox[2],ScissorBox[3]);
    glBindTexture(GL_TEXTURE_2D,OldTex); glActiveTexture(OldActive);
    glColorMask(Mask[0],Mask[1],Mask[2],Mask[3]);
    if Depth<>GL_FALSE then glEnable(GL_DEPTH_TEST);
    if Blend<>GL_FALSE then glEnable(GL_BLEND);
    if Cull<>GL_FALSE then glEnable(GL_CULL_FACE);
    if Scissor<>GL_FALSE then glEnable(GL_SCISSOR_TEST);
    {$ifndef OpenGLES}if SRGB<>GL_FALSE then glEnable(GL_FRAMEBUFFER_SRGB);{$endif}
    end;
    Cache.LastSubmitMs:=TimerSeconds(Timer,Started)*1000;
  finally LeaveCriticalSection(Lock) end;
end;

function RoadMaterialDebug: string;
begin
  EnterCriticalSection(Lock);
  try
    Result:='mode='+RoadMaterialModeName+' profiles='+IntToStr(Length(Profiles)-1);
    if Cache<>nil then
      Result:=Result+Format(' pages_generated=%d hits=%d misses=%d submit_ms=%.3f failed=%s',
        [Cache.Generated,Cache.Hits,Cache.Misses,Cache.LastSubmitMs,BoolToStr(Cache.Failed,True)])+
        Format(' requests=%d closest=%.1f focus=%.1f,%.1f frame=%d',
        [Cache.RequestCount,Cache.Closest,Cache.FocusPosition.X,Cache.FocusPosition.Z,Cache.Frame]);
  finally LeaveCriticalSection(Lock) end;
end;

procedure LoadPreference;
var Ini:TIniFile; M:Integer;
begin
  Ini:=TIniFile.Create(PreferencePath);
  try
    M:=Ini.ReadInteger('road','mode',Ord(rmmCached));
    if (M>=Ord(Low(TRoadMaterialMode))) and (M<=Ord(High(TRoadMaterialMode))) then
      CurrentMode:=TRoadMaterialMode(M);
    if CurrentMode=rmmLegacy then CurrentMode:=rmmDirect;
  finally Ini.Free end;
end;

initialization
  InitCriticalSection(Lock);
  ProfileMap:=specialize TDictionary<string,Integer>.Create;
  SetLength(Profiles,1);
  {$ifndef ANDROID}LoadPreference;{$endif}
  TTextureResource.RegisterClass(TRoadTextureResource);
finalization
  TTextureResource.UnregisterClass(TRoadTextureResource);
  Cache.Free;
  ProfileMap.Free;
  DoneCriticalSection(Lock);
end.
