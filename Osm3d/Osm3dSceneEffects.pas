unit Osm3dSceneEffects;

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$codepage UTF8}
{$WARN 5091 OFF}

interface

uses
  CastleRenderOptions,
  CastleVectors,
  X3DNodes
  {$IFDEF TEX_SIZE_PROFILE}, Osm3dTexProfile{$ENDIF}
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
;

{ Appearance-level variants of the three building effects. Use these
  when an appearance is SHARED across many shapes (X3D USE) — apply the
  effect once to the appearance instead of once per shape, otherwise
  SetEffects runs N times on the same node and tanks the frame rate. }
procedure AttachCounterEffectApp(App: TAppearanceNode; SlotIndex: Integer);

{ Like AttachCounterEffectApp, but the atomic increment lives in the VERTEX
  shader, so the slot counts VERTICES processed, not fragments. Two payoffs
  over the FS variant: (1) no shader side-effect in the FS means early-Z is
  preserved (occluded fragments are still discarded cheaply — the FS variant
  forces every covered fragment to run), and (2) the counter ticks per-vertex
  (orders of magnitude fewer increments than per-fragment). Used for buildings,
  whose per-fragment cost made the FS counter both misleading and a drag. }
procedure AttachCounterEffectVS(App: TAppearanceNode; SlotIndex: Integer);

procedure ApplyGlassReflectEffectApp(App: TAppearanceNode;
  const SunDirWorld: TVector3; const GlowFile: string);

{ Append a counter-only fragment Effect that CHAINS rather than replaces — both effects compose
  into one linked shader. }
procedure AttachCounterEffectFS(Shape: TShapeNode; SlotIndex: Integer);

implementation

uses
  X3DFields,
  Osm3dStudioSettings,
  Osm3dEffectUtils,
  Osm3dGlslLib,     { DEFAULT_SUN_TOWARD — единый дефолт солнца }
  SysUtils;

{ Общий каркас counter-эффекта: GLSL-эффект с одной шейдерной частью (VS или FS) и заданным
  исходником, подвешенный к Appearance через ChainEffectApp. }
procedure AttachCounterEffect(App: TAppearanceNode; AVertexShader: Boolean;
  const AContents: string);
var
  Effect: TEffectNode;
  Part:   TEffectPartNode;
begin
  if App = nil then Exit;
  Effect := TEffectNode.Create;
  Effect.Language := slGLSL;
  Part := TEffectPartNode.Create;
  if AVertexShader then Part.ShaderType := stVertex
                   else Part.ShaderType := stFragment;
  Part.Contents := AContents;
  Effect.SetParts([Part]);
  ChainEffectApp(App, Effect);
end;

procedure AttachCounterEffectApp(App: TAppearanceNode; SlotIndex: Integer);
var
  ByteOff:  Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(816);{$ENDIF}
  if App = nil then Exit;

  { Each slot is one uint32 = 4 bytes; `layout(offset=N)` is in bytes
    within the binding-0 atomic-counter buffer. }
  ByteOff := SlotIndex * 4;

  { Count in PLUG_fragment_eye_space, NOT PLUG_main_texture_apply. The
    latter is a Phong-era main-texture hook that does not fire in CGE's
    PBR fragment path (TPhysicalMaterialNode) — which is why the building
    counter read 0. PLUG_fragment_eye_space is the universal per-fragment
    hook: CGE emits it for every lit material (PBR, classic) and for the
    ground's unlit custom shader alike, so it fires for ground, water AND
    buildings. Side-effect still disables early-Z on tracked shapes. }
  AttachCounterEffect(App, False,
    '#extension GL_ARB_shader_atomic_counters : enable' + #10 +
    Format('layout(binding=0, offset=%d) uniform atomic_uint c_prof_fs;', [ByteOff]) + #10 +
    '' + #10 +
    'void PLUG_fragment_eye_space(const vec4 vertex_eye,' + #10 +
    '                             inout vec3 normal_eye)' + #10 +
    '{' + #10 +
    '    atomicCounterIncrement(c_prof_fs);' + #10 +
    '}' + #10);
end;

procedure AttachCounterEffectVS(App: TAppearanceNode; SlotIndex: Integer);
var
  ByteOff:  Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1332);{$ENDIF}
  if App = nil then Exit;

  ByteOff := SlotIndex * 4;

  { Increment in the VERTEX shader → counts vertices, not fragments. The
    PLUG_vertex_object_space hook runs once per vertex; the parameters are
    unused here (we only need the per-vertex tick). No FS side-effect, so
    early-Z on the building stays intact. }
  AttachCounterEffect(App, True,
    '#extension GL_ARB_shader_atomic_counters : enable' + #10 +
    Format('layout(binding=0, offset=%d) uniform atomic_uint c_prof_vs;', [ByteOff]) + #10 +
    '' + #10 +
    'void PLUG_vertex_object_space(const in vec4 vertex_object,' + #10 +
    '                              const in vec3 normal_object)' + #10 +
    '{' + #10 +
    '    atomicCounterIncrement(c_prof_vs);' + #10 +
    '}' + #10);
end;

procedure AttachCounterEffectFS(Shape: TShapeNode; SlotIndex: Integer);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(817);{$ENDIF}
  if Shape = nil then Exit;
  if not (Shape.Appearance is TAppearanceNode) then Exit;
  AttachCounterEffectApp(Shape.Appearance as TAppearanceNode, SlotIndex);
end;

{ Glass sky-reflection effect. CGE has no EnvironmentLight/IBL, so PBR glass reads black off-sun;
  this fragment effect reproduces streets-gl's getIBLContribution — build a reflection vector, sample
  a procedural sky, mix it in. World space via castle-shader:/EyeWorldSpace.glsl so the reflection is
  stable as the camera turns. The mechanism (glow-mask gating, viewing-angle gradient, sun glint) is
  documented inline in the GLSL below. }
const
  GLASSREFLECT_FS =
    'uniform vec3  u_sky_zenith;'  + #10 +
    'uniform vec3  u_sky_horizon;' + #10 +
    'uniform vec3  u_sky_ground;'  + #10 +
    'uniform vec3  u_sun_dir;'     + #10 +
    'uniform vec3  u_sun_tint;'    + #10 +
    'uniform float u_reflect_strength;' + #10 +
    'uniform sampler2D u_glow;' + #10 +
    '' + #10 +
    'vec4 position_eye_to_world_space(vec4 position_eye);' + #10 +
    '' + #10 +
    'vec3 gGRVertexWorld;' + #10 +
    'vec3 gGRCamWorld;' + #10 +
    'vec3 gGRNormalWorld;' + #10 +
    'vec2 gGRTexCoord;' + #10 +
    '' + #10 +
    '/* Capture world-space vertex, camera and surface normal for the' + #10 +
    '   reflection ray. */' + #10 +
    'void PLUG_fragment_eye_space(const vec4 vertex_eye,' + #10 +
    '                             inout vec3 normal_eye)' + #10 +
    '{' + #10 +
    '    gGRVertexWorld = position_eye_to_world_space(vertex_eye).xyz;' + #10 +
    '    gGRCamWorld    = position_eye_to_world_space(' + #10 +
    '                       vec4(0.0, 0.0, 0.0, 1.0)).xyz;' + #10 +
    '    /* World-space MESH normal: transform normal_eye by the eye->' + #10 +
    '       world rotation as the difference of two affine-mapped' + #10 +
    '       points (the translation cancels). The mesh normal is a' + #10 +
    '       stable unit-length vector; cross(dFdx,dFdy) is NOT - its' + #10 +
    '       length collapses toward zero when the wall fills the' + #10 +
    '       screen up close, which broke the reflection near the' + #10 +
    '       camera. */' + #10 +
    '    gGRNormalWorld = position_eye_to_world_space(' + #10 +
    '                       vec4(vertex_eye.xyz + normal_eye, 1.0)).xyz' + #10 +
    '                     - gGRVertexWorld;' + #10 +
    '}' + #10 +
    '' + #10 +
    '/* Capture the facade UV so the glow (glass) mask can be sampled' + #10 +
    '   with exactly the same tiling as the diffuse. */' + #10 +
    'void PLUG_texture_coord_shift(inout vec2 tex_coord)' + #10 +
    '{' + #10 +
    '    gGRTexCoord = tex_coord;' + #10 +
    '}' + #10 +
    '' + #10 +
    '/* Viewing-ANGLE reflection gradient for glass on a VERTICAL' + #10 +
    '   facade. Keyed on the elevation angle from the camera to the' + #10 +
    '   fragment - so it reacts both to camera height AND to distance' + #10 +
    '   (walk toward the facade and the reflected horizon slides),' + #10 +
    '   unlike a pure height difference which ignores distance.' + #10 +
    '' + #10 +
    '   The distance used is the PERPENDICULAR distance from the' + #10 +
    '   camera to the wall plane: dot(camera - P, N). For a flat wall' + #10 +
    '   every fragment is coplanar and N is constant, so this value is' + #10 +
    '   identical across the whole wall. That is the key trick: the' + #10 +
    '   metric m = (P.y - cameraY) / perp therefore has iso-lines at' + #10 +
    '   P.y = const -> the reflected horizon stays strictly horizontal' + #10 +
    '   and can only slide vertically, never tilt or rotate. (Using' + #10 +
    '   the true Euclidean distance would vary along the wall and bend' + #10 +
    '   the iso-lines into conic curves = a rotating horizon.)' + #10 +
    '' + #10 +
    '   perp is clamped: nearer than the low bound the shift stops;' + #10 +
    '   beyond the high bound it freezes into a stable height-like' + #10 +
    '   look so distant facades neither collapse nor jitter. */' + #10 +
    'vec3 gr_env(vec3 P, vec3 N)' + #10 +
    '{' + #10 +
    '    /* perpendicular camera->wall-plane distance, constant per' + #10 +
    '       wall. TUNE the clamp [near, far] in metres. */' + #10 +
    '    float perp = clamp(abs(dot(gGRCamWorld - P, N)), 5.0, 45.0);' + #10 +
    '    /* tan of the viewing elevation angle: depends on height AND' + #10 +
    '       distance. m = 0 is exactly eye level. */' + #10 +
    '    float m = (P.y - gGRCamWorld.y) / perp;' + #10 +
    '    /* RAISED horizon: in a city the low sky is blocked by the' + #10 +
    '       surrounding buildings, so the glass mirrors street and' + #10 +
    '       facades well above head height before it sees real sky.' + #10 +
    '       m = 0 (eye level) still reads as ground; sky proper begins' + #10 +
    '       around m = 0.35 (~19 deg above the eye). TUNE the four' + #10 +
    '       smoothstep stops to move / sharpen the horizon. */' + #10 +
    '    float g2h = smoothstep(0.0,  0.35, m); /* ground  -> horizon */' + #10 +
    '    float h2z = smoothstep(0.35, 1.60, m); /* horizon -> zenith  */' + #10 +
    '    vec3 col = mix(u_sky_ground,  u_sky_horizon, g2h);' + #10 +
    '    col      = mix(col,           u_sky_zenith,  h2z);' + #10 +
    '    return col;' + #10 +
    '}' + #10 +
    '' + #10 +
    'void PLUG_main_texture_apply(inout vec4 fragment_color,' + #10 +
    '                             const in vec3 normal)' + #10 +
    '{' + #10 +

    '    /* Glass mask: streets-gl glow texture, white = glass pane,' + #10 +
    '       black = frame / wall. Sampled with the facade UV. */' + #10 +
    '    float glass = texture2D(u_glow, gGRTexCoord).r;' + #10 +
    '    if (glass < 0.5) return;' + #10 +
    '' + #10 +
    '    /* Surface normal = the interpolated MESH normal in world' + #10 +
    '       space. NOT cross(dFdx,dFdy): that derivative normal' + #10 +
    '       shrinks toward a zero-length vector as the wall fills the' + #10 +
    '       screen up close, so the dot(N,N) guard below fired' + #10 +
    '       erratically between the two triangles of a wall quad and' + #10 +
    '       stamped the diagonal into the glass (correct far, broken' + #10 +
    '       near). The mesh normal is always unit length -> stable at' + #10 +
    '       any camera range. */' + #10 +
    '    vec3 N = gGRNormalWorld;' + #10 +
    '    if (dot(N, N) < 0.0000001) return;' + #10 +
    '    N = normalize(N);' + #10 +
    '    vec3 V = normalize(gGRCamWorld - gGRVertexWorld);' + #10 +
    '    if (dot(N, V) < 0.0) N = -N;' + #10 +
    '' + #10 +
    '    vec3 R   = normalize(reflect(-V, N));' + #10 +
    '    vec3 env = gr_env(gGRVertexWorld, N);' + #10 +
    '' + #10 +
    '    /* Sun glint - the ONLY camera-reactive term. A compact bright' + #10 +
    '       spot where the reflected ray meets the sun; it slides over' + #10 +
    '       the panes as the camera moves. Being a localised blob (not' + #10 +
    '       a gradient) it cannot read as a moving horizon line.' + #10 +
    '       View-angle Fresnel was removed deliberately: its strength' + #10 +
    '       varies across the facade along tilted conic contours, so it' + #10 +
    '       swept a bright band that looked exactly like a rotating' + #10 +
    '       horizon. A broad sun bloom was removed for the same reason. */' + #10 +
    '    float sd    = clamp(dot(R, normalize(u_sun_dir)), 0.0, 1.0);' + #10 +
    '    float glint = pow(sd, 90.0) * 2.2;' + #10 +
    '' + #10 +
    '    /* Reflection strength is CONSTANT across the glass: the sky' + #10 +
    '       gradient shows at one intensity everywhere, so no camera-' + #10 +
    '       driven brightness band can sweep the facade. */' + #10 +
    '    float k = clamp(u_reflect_strength, 0.0, 1.0);' + #10 +
    '    vec3 reflected = mix(fragment_color.rgb, env, k)' + #10 +
    '                     + u_sun_tint * glint;' + #10 +
    '    fragment_color.rgb = mix(fragment_color.rgb, reflected, glass);' + #10 +
    '}' + #10;

procedure ApplyGlassReflectEffectApp(App: TAppearanceNode;
  const SunDirWorld: TVector3; const GlowFile: string);
var
  Effect:   TEffectNode;
  Part:     TEffectPartNode;
  SunN:     TVector3;
  GlowTex:  TImageTextureNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(818);{$ENDIF}
  if App = nil then Exit;
  if GlowFile = '' then Exit;

  Effect := TEffectNode.Create;
  Effect.Language := slGLSL;
  Effect.SetShaderLibraries(['castle-shader:/EyeWorldSpace.glsl']);

  Part := TEffectPartNode.Create;
  Part.ShaderType := stFragment;
  Part.Contents   := GLASSREFLECT_FS;
  Effect.SetParts([Part]);

  { Sky palette — matches the viewport background tone. }
  Effect.AddCustomField(TSFVec3f.Create(Effect, True,
    'u_sky_zenith',  Vector3(0.32, 0.52, 0.82)));
  Effect.AddCustomField(TSFVec3f.Create(Effect, True,
    'u_sky_horizon', Vector3(0.74, 0.84, 0.94)));
  Effect.AddCustomField(TSFVec3f.Create(Effect, True,
    'u_sky_ground',  Vector3(0.04, 0.045, 0.05)));

  { Sun direction (world space, points TO the sun). Fall back to a
    default up-ish direction if a zero vector was passed. }
  SunN := SunDirWorld;
  if (SunN.X = 0) and (SunN.Y = 0) and (SunN.Z = 0) then
    SunN := DEFAULT_SUN_TOWARD;
  SunN := SunN.Normalize;
  Effect.AddCustomField(TSFVec3f.Create(Effect, True, 'u_sun_dir', SunN));

  { Warm sun-glow colour — used both for the broad sun-side sky
    brightening and the sharp mirror glint. }
  Effect.AddCustomField(TSFVec3f.Create(Effect, True,
    'u_sun_tint', Vector3(1.0, 0.93, 0.78)));

  Effect.AddCustomField(TSFFloat.Create(Effect, True,
    'u_reflect_strength', 0.85));

  { Glow / glass mask texture, passed as the GLSL `sampler2D u_glow`.
    streets-gl glow map: white = glass pane, black = frame / wall.
    The shader samples it with the facade UV to gate the reflection
    to the glass only. }
  GlowTex := TImageTextureNode.Create;
  GlowTex.SetUrl([GlowFile]);
  {$IFDEF TEX_SIZE_PROFILE}ProfileTexNode(GlowTex, 'glow');{$ENDIF}
  Effect.AddCustomField(TSFNode.Create(Effect, True,
    'u_glow', [TImageTextureNode], GlowTex));

  { Append, not replace — preserve the building LOD effect.
    Same KeepExisting dance as AttachCounterEffectFS. }
  ChainEffectApp(App, Effect);
end;

end.
