unit Osm3dRiderShadow;

{$mode objfpc}{$H+}

interface

uses X3DNodes, X3DFields, CastleVectors, CastleTransform, CastleViewport, CastleRenderOptions, CastleShapes, Osm3dShadowProbe;

type
  TRiderShadowMatrices = array[0..3] of TMatrix4;

  { Additional viewports share the depth atlas, but use their own receiver
    coordinates. Restore the previous binding for subsequent UI viewports. }
  TRiderShadowViewport = class(TCastleViewport)
  protected
    procedure RenderWithoutScreenEffects; override;
  end;

  { Raw OpenGL receivers borrow the same atlas and shader as CGE ground.
    Uniform locations are cached once per program; no extra shadow image. }
  TGroundShadowGLBinding = class
  private
    FSampler,FStrength,FAtlas,FWorldShadows,FTexel,FBias,FFilter: LongInt;
    FZones: array[0..3] of LongInt;
  public
    constructor Create(const ProgramHandle: Cardinal);
    procedure Bind(const TextureUnit: Cardinal);
  end;

  { One physical depth image owned by the ride, independent of any bike. }
  TRiderShadowAtlas = class
  private
    FMap: TGeneratedShadowMapNode;
    FLight: TDirectionalLightNode;
    FOptions: TCastleRenderOptions;
    FCasters, FSelected, FWorldCasters: TCastleTransformList;
    FProbe: TShadowGroundProbe;
    FProbePoint, FProbeClip: TVector3;
    FProbeEnabled: Boolean;
    FRenderingZone, FProbeZone: Integer;
    FFocus: TVector3;
    FWorldSelected, FRidersSelected: TCastleTransformList;
    FWorldShadows: Boolean;
    FWorldShapeCount: Integer;
    FViewport: TCastleViewport;
    FZoneCasterCount: array[0..3] of Integer;
    FVisibleCasterCount: Integer;
    FSubmitMilliseconds: Double;
    FRenderSerial, FCaptures, FCacheDraws: QWord;
    FAtlasSize, FTileSize, FFilter: Integer;
    FZoneHalfExtent: array[0..3] of Single;
    procedure RenderSelected(const Camera: TRenderingCamera);
    procedure ContextClose(Sender: TObject);
    function AcceptShadowShape(const Shape: TShape): Boolean;
  public
    const
      AtlasSize = 2048;
      TileSize = AtlasSize div 2;
      ZoneHalfExtent: array[0..3] of Single = (4, 10, 40, 160);
    constructor Create;
    destructor Destroy; override;
    procedure Configure(const ASize, AFilter, ADistance: Integer);
    procedure Render(const Viewport: TCastleViewport;
      const Focus, SunDirection: TVector3; const Strength: Single);
    procedure SetGroundProbe(const Point: TVector3; const Enabled: Boolean;
      const ResetOnDisable: Boolean = True);
    function GroundCoverage(const Point: TVector3): Single;
    function TryGroundCoverage(const Point: TVector3; out Value: Single): Boolean;
    function DebugInfo: String;
    property Casters: TCastleTransformList read FCasters;
    property WorldCasters: TCastleTransformList read FWorldCasters;
    property WorldShadows: Boolean read FWorldShadows write FWorldShadows;
  end;

  { One session-wide binding, shared by all streamed ground appearances.
    Instances unregister themselves when their owning atlas/cache is released. }
  TRiderShadowGroundEffect = class(TEffectNode)
  private
    FNext: TRiderShadowGroundEffect;
    FMap: TSFNode;
    FProxy: TShaderTextureNode;
    FMatrix: TSFMatrix4f;
    FMatrices: array[0..3] of TSFMatrix4f;
    FAtlas, FWorldShadowsUniform: TSFFloat;
    FBias: TSFVec4f;
    FTexel, FStrength, FFilter: TSFFloat;
    FFragment: TEffectPartNode;
    FSource: String;
    FEnabled: Boolean;
    FAtlasSource: Boolean;
    procedure Sync(const AllowBindingChanges: Boolean = True);
  public
    constructor Create(const AX3DName: String = ''; const ABaseUrl: String = ''); override;
    destructor Destroy; override;
    procedure SetGroundFragment(const Part: TEffectPartNode);
  end;

{ Call on the render/main thread, after moving/posing the rider.
  Clear before destroying its light. No readback or static-mask rebuild. }
procedure SetGroundRiderShadow(const Map: TGeneratedShadowMapNode;
  const WorldToClip: TMatrix4; const Strength: Single; const AtlasMode: Boolean = False; const WorldShadows: Boolean = False);
{ Keep the compiled sampler binding while the rider's depth pass is disabled. }
procedure HideGroundRiderShadow;
procedure ClearGroundRiderShadow;
procedure SetGroundRiderShadowCamera(const Position: TVector3);
procedure MarkWorldShadowCaster(const Shape: TShapeNode);
function IsWorldShadowCaster(const Shape: TX3DNode): Boolean;

{ Rebase the projector in Double once per zone, before converting its
  translation to GPU Single. Per-fragment world-coordinate subtraction loses
  the millimetres needed by the nearest 1024-texel shadow zone. }
function RelativeShadowMatrix(const WorldToClip:TMatrix4; const Camera:TVector3):TMatrix4;

{ Shared shader implementation for receivers outside CGE's effect pipeline. }
function GroundRiderShadowGLSL: String;


const
  RIDER_SHADOW_GLSL =
    '#ifdef GC_RIDER_SHADOW' + #10 +
    '#ifdef GC_RIDER_ATLAS' + #10 +
    'uniform sampler2D gc_rider_map;' + #10 +
    '#else' + #10 +
    'uniform sampler2DShadow gc_rider_map;' + #10 +
    '#endif' + #10 +
    'uniform mat4 gc_rider_world_to_clip;' + #10 +
    'uniform mat4 gc_rider_zone0, gc_rider_zone1, gc_rider_zone2, gc_rider_zone3;' + #10 +
    'uniform float gc_rider_atlas;' + #10 +
    'uniform float gc_rider_world_shadows;' + #10 +
    'uniform float gc_rider_texel;' + #10 +
    'uniform float gc_rider_strength;' + #10 +
    'uniform float gc_rider_filter;' + #10 +
    'uniform vec4 gc_rider_bias;' + #10 +
    'vec3 gc_zonePosition(int zone, vec3 world) {' + #10 +
    '  vec4 w = vec4(world, 1.0);' + #10 +
    '  vec4 p;' + #10 +
    '  if (zone == 0) p = gc_rider_zone0 * w;' + #10 +
    '  else if (zone == 1) p = gc_rider_zone1 * w;' + #10 +
    '  else if (zone == 2) p = gc_rider_zone2 * w;' + #10 +
    '  else p = gc_rider_zone3 * w;' + #10 +
    '  return p.xyz / p.w * 0.5 + 0.5;' + #10 +
    '}' + #10 +
    'float gc_zoneShadow(int zone, vec3 p) {' + #10 +
    '#ifdef GC_RIDER_ATLAS' + #10 +
    '  int size = textureSize(gc_rider_map, 0).x;' + #10 +
    '  int tile = size / 2;' + #10 +
    '  ivec2 lo = ivec2(zone % 2, zone / 2) * tile;' + #10 +
    '  ivec2 hi = lo + ivec2(tile - 1);' + #10 +
    '  vec2 at = vec2(lo) + p.xy * float(tile) - 0.5;' + #10 +
    '  if (gc_rider_filter < 1.5) {' + #10 +
    '    float d = texelFetch(gc_rider_map, clamp(ivec2(floor(at+0.5)), lo, hi), 0).r;' + #10 +
    '    return p.z-gc_rider_bias[zone] > d ? 1.0 : 0.0;' + #10 +
    '  }' + #10 +
    '  int taps = gc_rider_filter < 4.5 ? 2 : 4;' + #10 +
    '  ivec2 first = ivec2(floor(at)) - ivec2(taps / 2 - 1);' + #10 +
    '  vec2 f = fract(at);' + #10 +
    '  float shadow = 0.0;' + #10 +
    '  for (int y = 0; y < taps; ++y)' + #10 +
    '    for (int x = 0; x < taps; ++x) {' + #10 +
    '      float d = texelFetch(gc_rider_map, clamp(first + ivec2(x,y), lo, hi), 0).r;' + #10 +
    '      float wx = x == 0 ? 1.0-f.x : (x == taps-1 ? f.x : 1.0);' + #10 +
    '      float wy = y == 0 ? 1.0-f.y : (y == taps-1 ? f.y : 1.0);' + #10 +
    '      if (p.z-gc_rider_bias[zone] > d) shadow += wx*wy;' + #10 +
    '    }' + #10 +
    '  return shadow / float((taps-1)*(taps-1));' + #10 +
    '#else' + #10 +
    '  vec2 origin = vec2(float(zone - (zone / 2) * 2), float(zone / 2)) * 0.5;' + #10 +
    '  vec2 uv = origin + p.xy * 0.5;' + #10 +
    '  vec2 lo = origin + vec2(gc_rider_texel * 0.5);' + #10 +
    '  vec2 hi = origin + vec2(0.5 - gc_rider_texel * 0.5);' + #10 +
    '  float visibility = 0.0;' + #10 +
    '  for (int y = -1; y <= 1; ++y)' + #10 +
    '    for (int x = -1; x <= 1; ++x)' + #10 +
    '      visibility += texture(gc_rider_map, vec3(clamp(uv + vec2(float(x), float(y)) * gc_rider_texel, lo, hi), p.z - gc_rider_bias[zone]));' + #10 +
    '  return 1.0 - visibility / 9.0;' + #10 +
    '#endif' + #10 +
    '}' + #10 +
    'bool gc_insideZone(vec3 p) {' + #10 +
    '  return all(greaterThan(p, vec3(0.0))) && all(lessThan(p, vec3(1.0)));' + #10 +
    '}' + #10 +
    '#endif' + #10 +
    'vec3 gc_riderRelativePosition;' + #10 +
    'float gc_staticShadowWeight() {' + #10 +
    '#ifdef GC_RIDER_SHADOW' + #10 +
    '  if (gc_rider_world_shadows > 0.5 && gc_rider_atlas > 0.5 && gc_rider_strength > 0.0) {' + #10 +
    '    vec3 p = gc_zonePosition(3, gc_riderRelativePosition);' + #10 +
    '    if (gc_insideZone(p)) {' + #10 +
    '      float edge = max(abs(p.x * 2.0 - 1.0), abs(p.y * 2.0 - 1.0));' + #10 +
    '      return smoothstep(0.90, 0.99, edge);' + #10 +
    '    }' + #10 +
    '  }' + #10 +
    '#endif' + #10 +
    '  return 1.0;' + #10 +
    '}' + #10 +
    'vec3 gc_riderPosition;' + #10 +
    'float gc_staticCoverage = 0.0;' + #10 +
    'float gc_sampleRiderShadow() {' + #10 +
    '#ifdef GC_RIDER_SHADOW' + #10 +
    '  if (gc_rider_strength <= 0.0) return 0.0;' + #10 +
    '#ifdef GC_RIDER_ATLAS' + #10 +
    '  if (gc_rider_atlas > 0.5) {' + #10 +
    '    for (int zone = 0; zone < 4; ++zone) {' + #10 +
    '      vec3 p = gc_zonePosition(zone, gc_riderRelativePosition);' + #10 +
    '      if (!gc_insideZone(p)) continue;' + #10 +
    '      float edge = max(abs(p.x * 2.0 - 1.0), abs(p.y * 2.0 - 1.0));' + #10 +
    '      float shadow = gc_zoneShadow(zone, p);' + #10 +
    '      if (zone < 3 && edge > 0.85) {' + #10 +
    '        vec3 next = gc_zonePosition(zone + 1, gc_riderRelativePosition);' + #10 +
    '        if (gc_insideZone(next))' + #10 +
    '          shadow = mix(shadow, gc_zoneShadow(zone + 1, next), smoothstep(0.85, 0.98, edge));' + #10 +
    '      }' + #10 +
    '      if (zone == 3) shadow *= 1.0 - smoothstep(0.90, 0.99, edge);' + #10 +
    '      return shadow * gc_rider_strength;' + #10 +
    '    }' + #10 +
    '    return 0.0;' + #10 +
    '  }' + #10 +
    '  return 0.0;' + #10 +
    '#else' + #10 +
    '  vec4 q = gc_rider_world_to_clip * vec4(gc_riderPosition, 1.0);' + #10 +
    '  if (q.w <= 0.0) return 0.0;' + #10 +
    '  vec3 p = q.xyz / q.w * 0.5 + 0.5;' + #10 +
    '  if (!gc_insideZone(p)) return 0.0;' + #10 +
    '  float visibility = 0.0;' + #10 +
    '  for (int y = -1; y <= 1; ++y)' + #10 +
    '    for (int x = -1; x <= 1; ++x)' + #10 +
    '      visibility += texture(gc_rider_map, vec3(p.xy + vec2(float(x), float(y)) * gc_rider_texel, p.z - 0.00015));' + #10 +
    '  return (1.0 - visibility / 9.0) * gc_rider_strength;' + #10 +
    '#endif' + #10 +
    '#else' + #10 +
    '  return 0.0;' + #10 +
    '#endif' + #10 +
    '}' + #10 +
    'void gc_setStaticShadow(float coverage) {' + #10 +
    '  gc_staticCoverage = max(gc_staticCoverage, coverage);' + #10 +
    '}' + #10 +
    'void PLUG_fragment_modify(inout vec4 fragment_color) {' + #10 +
    '  float dynamicShadow = gc_sampleRiderShadow();' + #10 +
    '  float s = max(gc_staticCoverage, dynamicShadow);' + #10 +
    '#ifdef GC_RIDER_SHADOW' + #10 +
    '  if (gc_rider_world_shadows > 0.5 && gc_rider_atlas > 0.5)' + #10 +
    '    s = gc_staticCoverage * gc_staticShadowWeight() + dynamicShadow;' + #10 +
    '#endif' + #10 +
    '  s = clamp(s, 0.0, 1.0);' + #10 +
    '  if (s <= 0.001) return;' + #10 +
    '  vec3 base = fragment_color.rgb;' + #10 +
    '  float l = dot(base, vec3(0.2126, 0.7152, 0.0722));' + #10 +
    '  vec3 cool = mix(base, vec3(l) * vec3(0.82, 0.88, 1.04), 0.55);' + #10 +
    '  fragment_color.rgb = mix(base, cool * vec3(0.42, 0.45, 0.55), s);' + #10 +
    '}' + #10;

implementation

uses SysUtils, Math, CastleBoxes, CastleRectangles, CastleTimeUtils, CastleApplicationProperties,
  CastleSceneCore, CastleInternalRenderer, CastleGL, Osm3dRenderInstanced,
  CastleRendererInternalShader, CastleRendererInternalTextureEnv;

type
  { Each ground scene owns its own X3D node. Only the GPU resource is borrowed. }
  TRiderShadowTextureNode = class(TShaderTextureNode);
  TRiderShadowTextureResource = class(TSingleTextureResource)
  protected
    class function IsClassForTextureNode(ANode: TAbstractTextureNode): Boolean; override;
    procedure PrepareCore(const RenderOptions: TCastleRenderOptions); override;
    procedure UnprepareCore; override;
  public
    function Bind(const TextureUnit: Cardinal): Boolean; override;
    function Enable(const TextureUnit: Cardinal; Shader: TShader;
      const Env: TTextureEnv): Boolean; override;
  end;

var
  Effects: TRiderShadowGroundEffect = nil;
  CurrentMap: TGeneratedShadowMapNode = nil;
  CurrentMatrix: TMatrix4;
  CurrentMatrices: TRiderShadowMatrices;
  CurrentWorldMatrices: TRiderShadowMatrices;
  CurrentReceiverCamera: TVector3;
  CurrentBias: TVector4;
  CurrentAtlas: Boolean = False;
  CurrentWorldShadows: Boolean = False;
  CurrentStrength: Single = 0;
  CurrentFilter: Integer = 16;
  RegistryLock: TRTLCriticalSection;

function RelativeShadowMatrix(const WorldToClip:TMatrix4; const Camera:TVector3):TMatrix4;
var R:Integer;
begin
  Result:=WorldToClip;
  for R:=0 to 3 do
    Result.Data[3,R]:=Double(WorldToClip.Data[0,R])*Camera.X+
      Double(WorldToClip.Data[1,R])*Camera.Y+
      Double(WorldToClip.Data[2,R])*Camera.Z+Double(WorldToClip.Data[3,R]);
end;

function GroundRiderShadowGLSL: String;
begin
  Result := '#define GRASS_SHADOW' + #10 + '#define GC_RIDER_SHADOW' + #10 +
    '#define GC_RIDER_ATLAS' + #10 + RIDER_SHADOW_GLSL;
end;

constructor TGroundShadowGLBinding.Create(const ProgramHandle: Cardinal);
var Zone: Integer;
begin
  inherited Create;
  FSampler := glGetUniformLocation(ProgramHandle, 'gc_rider_map');
  FStrength := glGetUniformLocation(ProgramHandle, 'gc_rider_strength');
  FAtlas := glGetUniformLocation(ProgramHandle, 'gc_rider_atlas');
  FWorldShadows := glGetUniformLocation(ProgramHandle, 'gc_rider_world_shadows');
  FTexel := glGetUniformLocation(ProgramHandle, 'gc_rider_texel');
  FBias := glGetUniformLocation(ProgramHandle, 'gc_rider_bias');
  FFilter := glGetUniformLocation(ProgramHandle, 'gc_rider_filter');
  for Zone := 0 to 3 do
    FZones[Zone] := glGetUniformLocation(ProgramHandle, PChar('gc_rider_zone'+IntToStr(Zone)));
end;

procedure TGroundShadowGLBinding.Bind(const TextureUnit: Cardinal);
var Zone: Integer;
begin
  { Called on the render thread with the receiving program already active.
    Always clear strength: hide/unload must not leave a previous frame's
    shadow active, and a missing map must not alias the grass atlas on unit 0. }
  glUniform1i(FSampler, TextureUnit);
  glUniform1f(FStrength, 0);
  if (CurrentMap = nil) or not CurrentAtlas or (CurrentStrength <= 0) then Exit;
  if not TTextureResources.Bind(CurrentMap, TextureUnit) then Exit;
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_COMPARE_MODE, GL_NONE);
  glUniform1f(FAtlas, 1);
  glUniform1f(FWorldShadows, Ord(CurrentWorldShadows));
  glUniform1f(FTexel, 1.0/CurrentMap.Size);
  glUniform4fv(FBias, 1, @CurrentBias);
  for Zone := 0 to 3 do glUniformMatrix4fv(FZones[Zone], 1, GL_FALSE, @CurrentMatrices[Zone]);
  glUniform1f(FStrength, CurrentStrength);
  glUniform1f(FFilter, CurrentFilter);
end;

class function TRiderShadowTextureResource.IsClassForTextureNode(ANode: TAbstractTextureNode): Boolean;
begin Result := ANode is TRiderShadowTextureNode end;

procedure TRiderShadowTextureResource.PrepareCore(const RenderOptions: TCastleRenderOptions);
begin
  { The original map belongs to the bike rig and is generated there.
    No framebuffer or duplicate depth image is allocated by a proxy. }
  if CurrentMap <> nil then TTextureResources.Prepare(RenderOptions, CurrentMap);
end;

procedure TRiderShadowTextureResource.UnprepareCore;
begin
  { Borrowed resource: only the bike rig releases it. }
end;

function TRiderShadowTextureResource.Bind(const TextureUnit: Cardinal): Boolean;
begin
  Result := TTextureResources.Bind(CurrentMap, TextureUnit);
  { This atlas is sampled only by our ground effect. Raw depth permits the
    shared PCF coverage for all casters; legacy bike maps keep hardware
    comparison for their native CGE receivers. No second texture is made. }
  if Result and CurrentAtlas then
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_COMPARE_MODE, GL_NONE);
end;

function TRiderShadowTextureResource.Enable(const TextureUnit: Cardinal;
  Shader: TShader; const Env: TTextureEnv): Boolean;
begin Result := Bind(TextureUnit) end;

constructor TRiderShadowGroundEffect.Create(const AX3DName, ABaseUrl: String);
var I: Integer;
begin
  inherited;
  UniformMissing := umIgnore; { optional uniforms are optimized out while disconnected }
  FMap := TSFNode.Create(Self, True, 'gc_rider_map', [TShaderTextureNode], nil);
  AddCustomField(FMap);
  FProxy := TRiderShadowTextureNode.Create;
  FProxy.KeepExistingBegin;
  FMatrix := TSFMatrix4f.Create(Self, True, 'gc_rider_world_to_clip', TMatrix4.Identity);
  AddCustomField(FMatrix);
  for I := 0 to 3 do
  begin
    FMatrices[I] := TSFMatrix4f.Create(Self, True, 'gc_rider_zone' + IntToStr(I), TMatrix4.Identity);
    AddCustomField(FMatrices[I]);
  end;
  FAtlas := TSFFloat.Create(Self, True, 'gc_rider_atlas', 0);
  AddCustomField(FAtlas);
  FWorldShadowsUniform := TSFFloat.Create(Self, True, 'gc_rider_world_shadows', 0);
  AddCustomField(FWorldShadowsUniform);
  FBias := TSFVec4f.Create(Self, True, 'gc_rider_bias', Vector4(0, 0, 0, 0));
  AddCustomField(FBias);
  FTexel := TSFFloat.Create(Self, True, 'gc_rider_texel', 1.0 / 1024.0);
  AddCustomField(FTexel);
  FStrength := TSFFloat.Create(Self, True, 'gc_rider_strength', 0);
  AddCustomField(FStrength);
  FFilter := TSFFloat.Create(Self, True, 'gc_rider_filter', 16);
  AddCustomField(FFilter);
  EnterCriticalSection(RegistryLock);
  try
    FNext := Effects;
    Effects := Self;
  finally LeaveCriticalSection(RegistryLock) end;
end;

destructor TRiderShadowGroundEffect.Destroy;
var E: TRiderShadowGroundEffect; Proxy: TShaderTextureNode;
begin
  EnterCriticalSection(RegistryLock);
  try
  if Effects = Self then Effects := FNext else
  begin
    E := Effects;
    while (E <> nil) and (E.FNext <> Self) do E := E.FNext;
    if E <> nil then E.FNext := FNext;
  end;
  Proxy := FProxy;
  { Keep the proxy alive while inherited releases its optional field owner.
    An effect that was never activated never attached that owner at all. }
  inherited;
  Proxy.KeepExistingEnd;
  Proxy.FreeIfUnused;
  finally LeaveCriticalSection(RegistryLock) end;
end;

procedure TRiderShadowGroundEffect.SetGroundFragment(const Part: TEffectPartNode);
begin
  { This runs on the assembly worker. Publish source only; the main
    thread connects textures after Scene.Load has finished. }
  EnterCriticalSection(RegistryLock);
  try
    FFragment := Part;
    FSource := Part.Contents;
  finally LeaveCriticalSection(RegistryLock) end;
end;

procedure TRiderShadowGroundEffect.Sync(const AllowBindingChanges: Boolean);
var HasMap: Boolean; M: TMatrix4; I: Integer;
begin
  HasMap := CurrentMap <> nil;
  if AllowBindingChanges then
  begin
    if HasMap then
    begin
      if FMap.Value <> FProxy then FMap.Send(FProxy);
    end else if FMap.Value <> nil then FMap.Send(nil);
  end;
  if HasMap then
  begin
    M := FMatrix.Value;
    if not CompareMem(@M, @CurrentMatrix, SizeOf(M)) then FMatrix.Send(CurrentMatrix);
    if FTexel.Value <> 1.0 / CurrentMap.Size then FTexel.Send(1.0 / CurrentMap.Size);
    if FStrength.Value <> CurrentStrength then FStrength.Send(CurrentStrength);
    if FFilter.Value <> CurrentFilter then FFilter.Send(CurrentFilter);
    if FAtlas.Value <> Ord(CurrentAtlas) then FAtlas.Send(Ord(CurrentAtlas));
    if FWorldShadowsUniform.Value <> Ord(CurrentWorldShadows) then
      FWorldShadowsUniform.Send(Ord(CurrentWorldShadows));
    if CurrentAtlas then
    begin
      for I := 0 to 3 do
      begin
        M := FMatrices[I].Value;
        if not CompareMem(@M, @CurrentMatrices[I], SizeOf(M)) then FMatrices[I].Send(CurrentMatrices[I]);
      end;
      if not TVector4.Equals(FBias.Value, CurrentBias) then FBias.Send(CurrentBias);
    end;
  end;
  { Omit the sampler entirely when disconnected: a null shadow sampler
    must not alias an ordinary atlas sampler on texture unit zero. }
  if AllowBindingChanges and (FFragment <> nil) and ((FEnabled <> HasMap) or
     (HasMap and (FAtlasSource <> CurrentAtlas))) then
  begin
    FEnabled := HasMap;
    FAtlasSource := CurrentAtlas;
    if HasMap and CurrentAtlas then
      FFragment.Contents := '#define GC_RIDER_SHADOW' + #10 + '#define GC_RIDER_ATLAS' + #10 + FSource
    else if HasMap then FFragment.Contents := '#define GC_RIDER_SHADOW' + #10 + FSource
    else FFragment.Contents := FSource;
  end;
end;

{ Caller holds RegistryLock. Source/sampler changes may rebuild a scene, so
  those must finish before its first shadow or normal PrepareResources. }
procedure SyncGroundRiderShadowEffects(const AllowBindingChanges: Boolean);
var E: TRiderShadowGroundEffect;
begin
  E := Effects;
  while E <> nil do
  begin
    if (E.FMap.Value <> nil) or
       ((E.Scene is TCastleSceneCore) and TCastleSceneCore(E.Scene).Exists) then
      E.Sync(AllowBindingChanges);
    E := E.FNext;
  end;
end;

procedure SetGroundRiderShadow(const Map: TGeneratedShadowMapNode;
  const WorldToClip: TMatrix4; const Strength: Single; const AtlasMode: Boolean; const WorldShadows: Boolean);
var OldMap: TGeneratedShadowMapNode;
begin
  EnterCriticalSection(RegistryLock);
  try
  OldMap := CurrentMap;
  CurrentAtlas := AtlasMode and (Map <> nil);
  CurrentWorldShadows := CurrentAtlas and WorldShadows;
  if (Map <> OldMap) and (Map <> nil) then Map.KeepExistingBegin;
  CurrentMap := Map;
  CurrentMatrix := WorldToClip;
  CurrentStrength := Strength;
  { Exists becomes true on the main thread only after background mounting
    completes. Do not touch a graph while Scene.Load is traversing it. }
  SyncGroundRiderShadowEffects(True);
  if (Map <> OldMap) and (OldMap <> nil) then OldMap.KeepExistingEnd;
  finally LeaveCriticalSection(RegistryLock) end;
end;

procedure HideGroundRiderShadow;
begin
  if CurrentStrength = 0 then Exit;
  SetGroundRiderShadow(CurrentMap, CurrentMatrix, 0, CurrentAtlas, CurrentWorldShadows);
end;

procedure ClearGroundRiderShadow;
begin
  if CurrentMap = nil then Exit;
  SetGroundRiderShadow(nil, TMatrix4.Identity, 0);
end;

procedure SetGroundRiderShadowCamera(const Position: TVector3);
var Zone: Integer; E: TRiderShadowGroundEffect;
begin
  EnterCriticalSection(RegistryLock);
  try
    CurrentReceiverCamera := Position;
    for Zone := 0 to 3 do
      CurrentMatrices[Zone] := RelativeShadowMatrix(CurrentWorldMatrices[Zone], Position);
    E := Effects;
    while E <> nil do
    begin
      if (E.Scene is TCastleSceneCore) and TCastleSceneCore(E.Scene).Exists then E.Sync;
      E := E.FNext;
    end;
  finally LeaveCriticalSection(RegistryLock) end;
end;

procedure TRiderShadowViewport.RenderWithoutScreenEffects;
var Previous, P, D, U: TVector3;
begin
  if (Camera = nil) or (CurrentMap = nil) then
  begin inherited; Exit end;
  Previous := CurrentReceiverCamera;
  Camera.GetWorldView(P, D, U);
  SetGroundRiderShadowCamera(P);
  try inherited;
  finally SetGroundRiderShadowCamera(Previous) end;
end;

procedure MarkWorldShadowCaster(const Shape: TShapeNode);
begin
  if (Shape <> nil) and not IsWorldShadowCaster(Shape) then
    Shape.X3DName := 'WorldCaster_' + Shape.X3DName;
end;

function IsWorldShadowCaster(const Shape: TX3DNode): Boolean;
begin
  Result := (Shape <> nil) and
    ((Pos('AtlasBuilding', Shape.X3DName) = 1) or
     (Pos('DreamCaster_', Shape.X3DName) = 1) or
     (Pos('WorldCaster_', Shape.X3DName) = 1));
end;

constructor TRiderShadowAtlas.Create;
begin
  inherited Create;
  Configure(AtlasSize, 16, 160);
  FProbe := TShadowGroundProbe.Create;
  FWorldSelected := TCastleTransformList.Create(False);
  FRidersSelected := TCastleTransformList.Create(False);
  FCasters := TCastleTransformList.Create(False);
  FSelected := TCastleTransformList.Create(False);
  FWorldCasters := TCastleTransformList.Create(False);
  FOptions := TCastleRenderOptions.Create(nil);
  FLight := TDirectionalLightNode.Create;
  FLight.KeepExistingBegin;
  FMap := TGeneratedShadowMapNode.Create;
  FMap.KeepExistingBegin;
  FMap.X3DName := 'SharedRiderShadowAtlas';
  FMap.Size := AtlasSize;
  FMap.Light := FLight; { weak link: retain light separately }
  FMap.FdScale.Value := 1;
  FMap.FdBias.Value := 1;
  ApplicationProperties.OnGLContextCloseObject.Add(@ContextClose);
end;

procedure TRiderShadowAtlas.Configure(const ASize, AFilter, ADistance: Integer);
begin
  { Only change CPU configuration here. GL resources are resized in Render,
    with the context current, without exposing a freed sampler to receivers. }
  if (ASize = 1024) or (ASize = 2048) or (ASize = 4096) then
    FAtlasSize := ASize else FAtlasSize := AtlasSize;
  FTileSize := FAtlasSize div 2;
  if AFilter in [1, 4, 16] then FFilter := AFilter else FFilter := 16;
  FZoneHalfExtent[0] := 4;
  FZoneHalfExtent[1] := 10;
  FZoneHalfExtent[2] := EnsureRange(ADistance, 60, 160) * 0.25;
  FZoneHalfExtent[3] := EnsureRange(ADistance, 60, 160);
end;

procedure TRiderShadowAtlas.ContextClose(Sender: TObject);
begin
  FProbe.ContextClose;
  { Release before the engine renderer cache. Recreated lazily next Render. }
  TTextureResources.Unprepare(FMap);
end;

destructor TRiderShadowAtlas.Destroy;
begin
  ApplicationProperties.OnGLContextCloseObject.Remove(@ContextClose);
  if CurrentMap = FMap then ClearGroundRiderShadow;
  TTextureResources.Unprepare(FMap);
  FMap.KeepExistingEnd;
  FMap.FreeIfUnused;
  FLight.KeepExistingEnd;
  FLight.FreeIfUnused;
  FProbe.Free;
  FWorldSelected.Free;
  FRidersSelected.Free;
  FOptions.Free;
  FWorldCasters.Free;
  FSelected.Free;
  FCasters.Free;
  inherited;
end;

function TRiderShadowAtlas.AcceptShadowShape(const Shape: TShape): Boolean;
begin
  { Rider scenes are untouched. Tile scenes contain many categories: only
    the building shapes marked during assembly belong in this depth pass. }
  Result := True;
  if (Shape.ParentScene <> nil) and
     (FWorldCasters.IndexOf(TCastleTransform(Shape.ParentScene)) >= 0) then
  begin
    Result := IsWorldShadowCaster(Shape.Node);
    if Result then Inc(FWorldShapeCount);
  end;
end;

procedure TRiderShadowAtlas.SetGroundProbe(const Point: TVector3; const Enabled: Boolean;
  const ResetOnDisable: Boolean);
begin
  FProbePoint := Point;
  FProbeEnabled := Enabled;
  if not Enabled and ResetOnDisable then FProbe.Reset;
end;

function TRiderShadowAtlas.GroundCoverage(const Point: TVector3): Single;
begin
  Result := FProbe.Coverage(Point);
end;

function TRiderShadowAtlas.TryGroundCoverage(const Point: TVector3; out Value: Single): Boolean;
begin
  Result := FProbeEnabled and FWorldShadows and FProbe.TryCoverage(Point, Value);
end;

procedure TRiderShadowAtlas.RenderSelected(const Camera: TRenderingCamera);
var I: Integer;
begin
  if FWorldShadows and FProbeEnabled and (FRenderingZone = FProbeZone) then
  begin
    FWorldSelected.Clear;
    FRidersSelected.Clear;
    for I := 0 to FSelected.Count - 1 do
      if FWorldCasters.IndexOf(FSelected[I]) >= 0 then FWorldSelected.Add(FSelected[I])
      else FRidersSelected.Add(FSelected[I]);
    FViewport.InternalRenderShadowCasters(Camera, FWorldSelected, @AcceptShadowShape);
    if FProbe.SampleDue(FProbePoint) then
      FProbe.Submit(FProbePoint, FProbeClip, FTileSize,
        2 * FZoneHalfExtent[FRenderingZone] / FTileSize);
    { Append riders without clearing the world depth we just sampled. }
    FViewport.InternalRenderShadowCasters(Camera, FRidersSelected, nil, False);
  end else if FWorldShadows then
    FViewport.InternalRenderShadowCasters(Camera, FSelected, @AcceptShadowShape)
  else
    FViewport.InternalRenderShadowCasters(Camera, FSelected);
end;

procedure TRiderShadowAtlas.Render(const Viewport: TCastleViewport;
  const Focus, SunDirection: TVector3; const Strength: Single);
type
  TProjectedBounds = record
    Caster: TCastleTransform;
    MinX, MaxX, MinY, MaxY, MinD, MaxD: Single;
  end;
var
  Bounds: array of TProjectedBounds;
  Box: TBox3D;
  D, Side, Up, UpHint, P, Q, Eye, CameraPosition, CameraDirection, CameraUp: TVector3;
  I, J, Zone, N: Integer;
  X, Y, Z, FocusX, FocusY, CenterX, CenterY, Step, H, Inner: Single;
  MinDepth, MaxDepth, DepthSpan: Single;
  PreviousX, PreviousY: Single;
  Matrices: TRiderShadowMatrices;
  Bias: TVector4;
  Resource: TGeneratedShadowMapResource;
  StartTime: TTimerResult;
  StartCaptures, StartDraws: QWord;
begin
  FWorldShapeCount := 0;
  if FWorldShadows then
    for I := 0 to FWorldCasters.Count - 1 do FCasters.Add(FWorldCasters[I]);
  FillChar(FZoneCasterCount, SizeOf(FZoneCasterCount), 0);
  if (Viewport = nil) or (SunDirection.Length < 1e-6) or (Strength <= 0) then
  begin
    HideGroundRiderShadow;
    Exit;
  end;
  StartTime := Timer;
  StartCaptures := CachedMeshCaptures;
  StartDraws := CachedMeshDraws;
  D := SunDirection.Normalize;
  UpHint := Vector3(0, 1, 0);
  if Abs(D.Y) > 0.99 then UpHint := Vector3(0, 0, 1);
  Side := TVector3.CrossProduct(D, UpHint).Normalize;
  Up := TVector3.CrossProduct(Side, D);
  { Focus is the camera world position. Projection along sunlight preserves light XY,
    naturally moving the ground footprint towards the shadow side. }
  FFocus := Focus;
  FProbeZone := -1;
  FocusX := TVector3.DotProduct(Side, Focus);
  FocusY := TVector3.DotProduct(Up, Focus);
  MinDepth := TVector3.DotProduct(D, Focus) - 110;
  MaxDepth := MinDepth + 220;
  SetLength(Bounds, FCasters.Count);
  N := 0;
  for I := 0 to FCasters.Count - 1 do
    if FCasters[I].ExistsInRoot and FCasters[I].HasWorldTransform then
    begin
      Box := FCasters[I].WorldBoundingBox;
      if Box.IsEmpty then Continue;
      Bounds[N].Caster := FCasters[I];
      Bounds[N].MinX := 1e30; Bounds[N].MinY := 1e30; Bounds[N].MinD := 1e30;
      Bounds[N].MaxX := -1e30; Bounds[N].MaxY := -1e30; Bounds[N].MaxD := -1e30;
      for J := 0 to 7 do
      begin
        P := Vector3(Box.Data[J and 1].X, Box.Data[(J shr 1) and 1].Y,
          Box.Data[(J shr 2) and 1].Z);
        X := TVector3.DotProduct(Side, P);
        Y := TVector3.DotProduct(Up, P);
        Z := TVector3.DotProduct(D, P);
        Bounds[N].MinX := Min(Bounds[N].MinX, X); Bounds[N].MaxX := Max(Bounds[N].MaxX, X);
        Bounds[N].MinY := Min(Bounds[N].MinY, Y); Bounds[N].MaxY := Max(Bounds[N].MaxY, Y);
        Bounds[N].MinD := Min(Bounds[N].MinD, Z); Bounds[N].MaxD := Max(Bounds[N].MaxD, Z);
      end;
      { Cull by projected footprint, not by distance: a distant rider can
        still cast into the receiving region at low sun. }
      if (Bounds[N].MaxX < FocusX - FZoneHalfExtent[3] - 1) or (Bounds[N].MinX > FocusX + FZoneHalfExtent[3] + 1) or
         (Bounds[N].MaxY < FocusY - FZoneHalfExtent[3] - 1) or (Bounds[N].MinY > FocusY + FZoneHalfExtent[3] + 1) then Continue;
      MinDepth := Min(MinDepth, Bounds[N].MinD - 1);
      MaxDepth := Max(MaxDepth, Bounds[N].MaxD + 1);
      Inc(N);
    end;
  FVisibleCasterCount := N;
  DepthSpan := MaxDepth - MinDepth;
  FLight.Direction := D;
  FLight.Up := UpHint;
  FLight.FdProjectionNear.Value := 0.1;
  FLight.FdProjectionFar.Value := DepthSpan;
  if FMap.Size <> FAtlasSize then
  begin
    FProbe.ContextClose;
    TTextureResources.Unprepare(FMap);
    FMap.Size := FAtlasSize;
  end;
  TTextureResources.Prepare(FOptions, FMap);
  Resource := TGeneratedShadowMapResource(TTextureResources.Get(FMap));
  { A newly mounted tile has not connected its receiver effect yet. Do this
    before shadow collection prepares ALL scene shapes (including ground).
    EffectPart.Contents changes call ChangedAll and discard native VBOs.
    Identity (first frame) or previous matrices remain valid until all zones
    below have been rendered;
    shadow depth shaders do not sample their own receiver map. }
  CurrentFilter := FFilter;
  if FWorldShadows then
    SetGroundRiderShadow(FMap, CurrentMatrix, 1, True, True)
  else
    SetGroundRiderShadow(FMap, CurrentMatrix, Strength, True, False);
  FViewport := Viewport;
  PreviousX := 0; PreviousY := 0;
  Viewport.Camera.GetWorldView(CameraPosition,CameraDirection,CameraUp);
  BeginVegetationShadowPass(CameraPosition);
  try
    for Zone := 0 to 3 do
    begin
      FRenderingZone := Zone;
      H := FZoneHalfExtent[Zone];
      Step := 2 * H / FTileSize;
      CenterX := Round(FocusX / Step) * Step;
      CenterY := Round(FocusY / Step) * Step;
      Q := Side * CenterX + Up * CenterY;
      Eye := Q + D * MinDepth;
      FLight.FdProjectionLocation.Value := Eye;
      FLight.FdProjectionRectangle.Value := Vector4(-H, -H, H, H);
      Matrices[Zone] := FLight.GetProjectorMatrix;
      Bias.Data[Zone] := Min(0.03, Step * 0.25) / DepthSpan;
      { The front wheel can be outside the camera's finest zone. Sample
        the first containing tile, before adding riders to its world depth. }
      if FProbeEnabled and (FProbeZone < 0) then
      begin
        FProbeClip := RelativeShadowMatrix(Matrices[Zone], FProbePoint).MultPoint(TVector3.Zero);
        FProbeClip.Z := FProbeClip.Z - 2 * Bias.Data[Zone];
        if (Abs(FProbeClip.X) < Min(0.98, 1 - 0.18 / H)) and
           (Abs(FProbeClip.Y) < Min(0.98, 1 - 0.18 / H)) and
           (Abs(FProbeClip.Z) < 1) then FProbeZone := Zone;
      end;
      FSelected.Clear;
      for I := 0 to N - 1 do
      begin
        if (Bounds[I].MaxX < CenterX - H - Step * 2) or
           (Bounds[I].MinX > CenterX + H + Step * 2) or
           (Bounds[I].MaxY < CenterY - H - Step * 2) or
           (Bounds[I].MinY > CenterY + H + Step * 2) then Continue;
        if Zone > 0 then
        begin
          { The finer zone supplies this interior. Leave a band wider than
            the shader blend and PCF footprint on both sides of the seam. }
          Inner := FZoneHalfExtent[Zone - 1] * 0.80 - Step * 2;
          if (Bounds[I].MinX > PreviousX - Inner) and
             (Bounds[I].MaxX < PreviousX + Inner) and
             (Bounds[I].MinY > PreviousY - Inner) and
             (Bounds[I].MaxY < PreviousY + Inner) then Continue;
        end;
        FSelected.Add(Bounds[I].Caster);
      end;
      FZoneCasterCount[Zone] := FSelected.Count;
      { Clear even an empty tile, otherwise old silhouettes survive motion. }
      Resource.UpdateRegion(@RenderSelected, FLight,
        (Zone and 1) * FTileSize, (Zone shr 1) * FTileSize, FTileSize, FTileSize);
      PreviousX := CenterX; PreviousY := CenterY;
    end;
  finally
    EndVegetationShadowPass;
    FViewport := nil;
    FSelected.Clear;
  end;
  if FProbeEnabled and (FProbeZone < 0) then FProbe.Reset;
  Viewport.Camera.GetWorldView(CameraPosition,CameraDirection,CameraUp);
  CurrentWorldMatrices := Matrices;
  CurrentReceiverCamera := CameraPosition;
  for Zone:=0 to 3 do
    CurrentMatrices[Zone]:=RelativeShadowMatrix(Matrices[Zone],CameraPosition);
  CurrentBias := Bias;
  CurrentMatrix := Matrices[0];
  { Publish the completed image coordinates without graph/source changes:
    the normal pass must reuse the geometry prepared by the shadow pass. }
  EnterCriticalSection(RegistryLock);
  try SyncGroundRiderShadowEffects(False);
  finally LeaveCriticalSection(RegistryLock) end;
  FSubmitMilliseconds := TimerSeconds(Timer, StartTime) * 1000;
  Inc(FRenderSerial);
  FCaptures := CachedMeshCaptures - StartCaptures;
  FCacheDraws := CachedMeshDraws - StartDraws;
end;

function TRiderShadowAtlas.DebugInfo: String;
begin
  Result := Format('size=%d tiles=%d filter=%d extent=%.0f,%.0f,%.0f,%.0f visible=%d casters=%d,%d,%d,%d submit_ms=%.3f frames=%d captures=%d cached_draws=%d world=%d world_sources=%d world_shapes=%d probe=%.3f focus=%.3f,%.3f,%.3f probe_zone=%d',
    [FAtlasSize, FTileSize, FFilter, FZoneHalfExtent[0], FZoneHalfExtent[1], FZoneHalfExtent[2], FZoneHalfExtent[3], FVisibleCasterCount, FZoneCasterCount[0], FZoneCasterCount[1],
     FZoneCasterCount[2], FZoneCasterCount[3], FSubmitMilliseconds,
     FRenderSerial, FCaptures, FCacheDraws, Ord(FWorldShadows), FWorldCasters.Count, FWorldShapeCount, FProbe.Coverage(FProbePoint), FFocus.X, FFocus.Y, FFocus.Z, FProbeZone]);
end;

initialization
  InitCriticalSection(RegistryLock);
  CurrentMatrix := TMatrix4.Identity;
  CurrentWorldMatrices[0] := TMatrix4.Identity;
  CurrentWorldMatrices[1] := TMatrix4.Identity;
  CurrentWorldMatrices[2] := TMatrix4.Identity;
  CurrentWorldMatrices[3] := TMatrix4.Identity;
  CurrentMatrices := CurrentWorldMatrices;
  TTextureResource.RegisterClass(TRiderShadowTextureResource);
{ Views may be freed after this unit finalizes. Keep the registry lock
  alive until process teardown so their effect destructors can unregister. }
end.
