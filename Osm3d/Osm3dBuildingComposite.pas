unit Osm3dBuildingComposite;

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$codepage UTF8}

interface

uses Osm3dStaticGeometry,
  Classes,
  SysUtils,
  CastleImages,
  CastleVectors,
  Osm3dSceneMaterials,   { BUILDING_WALL_BASE / BUILDING_ROOF_BASE — единый источник палитр }
  CastleRenderOptions,
  X3DNodes,
  X3DFields,
  Osm3dGeoMath,
  Osm3dGeomMesh,
  Osm3dGlslLib,
  Osm3dCompositeAtlas,    { TCompositeAtlasBase / TAtlasLayout — общая база атласов }
  Osm3dGroundComposite,   { TGroundCompositeMesh / Builder reuse }
  Osm3dBuildingTextures   { FACADE_TEX_DIR / ROOF_TEX_DIR + name helpers }
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
;

const
  { 0..5 walls OSM, 6..11 roofs, 12..15 extra walls (architectural hash tints).
    4×4 atlas, all 16 cells used. }
  BUILDING_MAT_WALL0  = 0;
  BUILDING_MAT_ROOF0  = 6;
  BUILDING_MAT_WALL_TINT0 = 12;
  BUILDING_MAT_COUNT  = 16;

type
  { Built at runtime (not a const table) because paths come from the
    WallMaterialName / RoofMaterialName helpers. }
  TBuildingMaterialDesc = record
    Name:          string;
    DiffusePath:   string;
    NormalPath:    string;
    MaskPath:      string;       { R channel baked into mask atlas as roughness }
    GlowPath:      string;       { '' for roofs; R channel = glass-pane mask }
    FallbackColor: TVector3;     { used when the diffuse PNG is missing }
    Roughness:     Single;       { constant baked into maskless cells }
    Metallic:      Single;       { per-material LUT (mask atlas carries roughness only) }
    IsWall:        Boolean;
  end;

{ Resolve the descriptor for a material id 0..11. }
function BuildingMaterialDesc(MatId: Integer): TBuildingMaterialDesc;

{ (palette 0..9, isRoof) → material id 0..15. Roofs of tint palettes use roof 0. }
function MaterialIdForBuilding(Palette: Integer; IsRoof: Boolean): Integer; inline;

type
  { Alias of the shared atlas layout record (GridCols / GridRows / TilePixels). }
  TBuildingAtlasLayout = TAtlasLayout;

function DefaultBuildingAtlasLayout: TBuildingAtlasLayout;

type
  { 12 building materials over 4 same-layout images: diffuse/normal/mask/glow.
    CreateTextureNode passes image ownership; SaveToCache writes PNGs and enables
    URL nodes for cross-tile sharing (CGE dedupes GPU upload by URL). }
  TBuildingAtlas = class(TCompositeAtlasBase)
  private
    FFallback: array[0..BUILDING_MAT_COUNT - 1] of TVector3;
    FMetallic: array[0..BUILDING_MAT_COUNT - 1] of Single;
  protected
    function LogPrefix: string; override;
    function CacheFileName(Ch: TAtlasChannel): string; override;
    function MaterialCount: Integer; override;
    function MaterialInfo(MatId: Integer): TAtlasMaterialInfo; override;
  public
    constructor Create(const ALayout: TBuildingAtlasLayout); reintroduce;

    procedure BuildGlowImage(LogProc: TLogProc = nil);
    procedure BuildChannelsParallel(LogProc: TLogProc = nil); override;

    function FallbackColor(MatId: Integer): TVector3;
    function Metallic(MatId: Integer): Single;
  end;

{ Build ONE building-composite shape from a merged mesh (materialIds 0..11).
  Atlas must already be built; if SaveToCache'd, shareable URL nodes are used,
  otherwise single-use pixel nodes valid only for the FIRST shape from this atlas.
  SunDirToward = direction TOWARD the sun (zero -> default). nil if empty. }
function BuildBuildingCompositeShape(Composite: TGroundCompositeMesh;
  Atlas: TBuildingAtlas; const SunDirToward: TVector3;
  LogProc: TLogProc = nil): TShapeNode;

const

  BUILDING_COMPOSITE_VS =
    'attribute float materialId;' + #10 +
    { TUnlitMaterial makes CGE skip texcoord/normal upload, so UV and normal
      ride dedicated TFloatVertexAttributeNode streams (as in the ground composite). }
    'attribute vec2  bldUV;' + #10 +
    'attribute vec3  bldNormal;' + #10 +
    '' + #10 +
    'varying float vBldMatId;' + #10 +
    'varying vec2  vBldUV;' + #10 +
    'varying vec3  vBldNormalOS;' + #10 +
    'flat varying vec2 vBldFacadeId;' + #10 +
    '' + #10 +
    'void PLUG_vertex_object_space(' + #10 +
    '  const in vec4 vertex_object,' + #10 +
    '  const in vec3 normal_object)' + #10 +
    '{' + #10 +
    '    vBldMatId    = materialId;' + #10 +
    '    vBldNormalOS = bldNormal;' + #10 +
    '    vec3 facadeId = floor(bldNormal * 64.0 + 0.5);' + #10 +
    '    vBldFacadeId = facadeId.xz * 17.0 + facadeId.y * 5.0;' + #10 +
    '    vBldUV       = bldUV;' + #10 +
    '}' + #10;

  BUILDING_COMPOSITE_FS =
    '#define U_BLD_MAT_COUNT 16' + #10 +
    '#define PI 3.141592653589793' + #10 +
    { Single brightness knob — kept equal to the ground composite''s
      GROUND_EXPOSURE so walls/roofs sit at the same daylight level as the
      ground and the instanced vegetation. }
    '#define BLD_EXPOSURE 2.0' + #10 +
    '' + #10 +
    'varying float vBldMatId;' + #10 +
    'varying vec2  vBldUV;' + #10 +
    'varying vec3  vBldNormalOS;' + #10 +
    'flat varying vec2 vBldFacadeId;' + #10 +
    '' + #10 +
    'uniform sampler2D u_bld_atlas;' + #10 +
    'uniform sampler2D u_bld_normal_atlas;' + #10 +
    'uniform sampler2D u_bld_mask_atlas;' + #10 +
    'uniform sampler2D u_bld_glow_atlas;' + #10 +
    'uniform int   u_bld_grid_cols;' + #10 +
    'uniform int   u_bld_grid_rows;' + #10 +
    { Cell apron inset (gutter_px / tile_px): UV maps into [ins, 1-ins] so sampling
      never reaches the gutter ring. Must match BLD_CELL_GUTTER. }
    'uniform float u_bld_cell_inset;' + #10 +
    'uniform vec3  u_bld_fallback_rgb[U_BLD_MAT_COUNT];' + #10 +
    'uniform float u_bld_metallic[U_BLD_MAT_COUNT];' + #10 +
    'uniform float u_bld_tint_amount[U_BLD_MAT_COUNT];' + #10 +
    '' + #10 +
    '/* Sun + sky. gc_SunDirToward = direction TOWARD the sun (world). */' + #10 +
    'uniform vec3  gc_SunDirToward;' + #10 +
    'uniform vec3  u_sky_zenith;' + #10 +
    'uniform vec3  u_sky_horizon;' + #10 +
    'uniform vec3  u_sky_ground;' + #10 +
    'uniform vec3  u_sun_tint;' + #10 +
    'uniform float u_bld_reflect_strength;' + #10 +
    { Max per-window reflection-normal jitter (rad); fixed tilt per pane so glints
      don't line up across panes. 0 = off. }
    'uniform float u_bld_window_tilt;' + #10 +
    '' + #10 +
    GLSL_LOD_UNIFORMS +
    '' + #10 +
    GLSL_SUN_CONSTS +
    '' + #10 +
    '/* World space from castle-shader:/EyeWorldSpace.glsl (attached via' + #10 +
    '   TEffectNode.SetShaderLibraries) — same mechanism the ground/glass' + #10 +
    '   effects use. Avoids needing a host-pumped u_camera_pos uniform. */' + #10 +
    'vec4 position_eye_to_world_space(vec4 position_eye);' + #10 +
    'vec3 gBldCamWorld;' + #10 +
    'vec3 gBldToCamera;' + #10 +
    'void PLUG_fragment_eye_space(const vec4 vertex_eye, inout vec3 normal_eye)' + #10 +
    '{' + #10 +
    '    gBldCamWorld = position_eye_to_world_space(vec4(0.0,0.0,0.0,1.0)).xyz;' + #10 +
    '    gBldToCamera = position_eye_to_world_space(vec4(-vertex_eye.xyz,0.0)).xyz;' + #10 +
    '}' + #10 +
    '' + #10 +
    GLSL_PBR_HELPERS +
    '' + #10 +
    '/* Dave Hoskins'' "Hash without Sine" (hash22): stable per-cell 2D' + #10 +
    '   pseudo-random in [0,1], no sin() precision artifacts. Used to give' + #10 +
    '   each window pane a fixed small reflection-angle offset. */' + #10 +
    'vec2 bldHash22(vec2 p) {' + #10 +
    '    vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));' + #10 +
    '    p3 += dot(p3, p3.yzx + 33.33);' + #10 +
    '    return fract((p3.xx + p3.yz) * p3.zy);' + #10 +
    '}' + #10 +
    '' + #10 +
    'void PLUG_main_texture_apply(inout vec4 fragment_color, const in vec3 normal)' + #10 +
    '{' + #10 +
    '    int matId = int(floor(vBldMatId + 0.5));' + #10 +
    '    if (matId < 0) matId = 0;' + #10 +
    '    if (matId >= U_BLD_MAT_COUNT) matId = 0;' + #10 +
    '' + #10 +
    '    /* ── LOD far cull (horizontal distance, altitude-scaled). Near' + #10 +
    '       culling is done per-tile on the CPU (UpdateDistanceCulling), so' + #10 +
    '       only the far gate lives here. */' + #10 +
    '    float lodDist  = length(gBldToCamera.xz);' + #10 +
    '    float camAbove = max(0.0, gBldCamWorld.y - u_lod_ground_ref_y);' + #10 +
    '    float hScale   = 1.0 + camAbove / u_lod_height_ref;' + #10 +
    '    if (lodDist > u_lod_far_base * hScale) discard;' + #10 +
    '' + #10 +
    '    /* Atlas cell for this matId. */' + #10 +
    '    float colsF = float(u_bld_grid_cols);' + #10 +
    '    float rowsF = float(u_bld_grid_rows);' + #10 +
    '    int col = matId - (matId/u_bld_grid_cols)*u_bld_grid_cols;' + #10 +
    '    int row = matId / u_bld_grid_cols;' + #10 +
    '    vec2 cellOrigin = vec2(float(col)/colsF, float(row)/rowsF);' + #10 +
    '    vec2 cellSpan   = vec2(1.0/colsF, 1.0/rowsF);' + #10 +
    '' + #10 +
    '    /* UV is pre-baked on the mesh (walls: window×floor tiling; roofs:' + #10 +
    '       planar metres/4). fract() tiles inside the cell, but the sample is' + #10 +
    '       confined to the cell INTERIOR [ins, 1-ins] (the gutter ring is' + #10 +
    '       only for tile-correct mip averaging — see BLD_CELL_GUTTER).' + #10 +
    '       textureGrad with pre-fract derivatives (scaled by the interior' + #10 +
    '       span) keeps mip selection from collapsing at the integer wrap. */' + #10 +
    '    vec2  baseUV  = vBldUV;' + #10 +
    '    float ins     = u_bld_cell_inset;' + #10 +
    '    float ispan   = 1.0 - 2.0 * ins;' + #10 +
    '    vec2  tiledUV = fract(baseUV);' + #10 +
    '    vec2  localUV = vec2(ins) + tiledUV * ispan;' + #10 +
    '    vec2  atlasUV = cellOrigin + localUV * cellSpan;' + #10 +
    '    vec2  gradX = dFdx(baseUV) * cellSpan * ispan;' + #10 +
    '    vec2  gradY = dFdy(baseUV) * cellSpan * ispan;' + #10 +
    '' + #10 +
    '    vec4 diffSample = textureGrad(u_bld_atlas, atlasUV, gradX, gradY);' + #10 +
    '    vec3 albedoLin  = gc_SRGBtoLINEAR(diffSample.rgb);' + #10 +
    '    albedoLin *= mix(vec3(1.0),' + #10 +
    '                     gc_SRGBtoLINEAR(u_bld_fallback_rgb[matId]),' + #10 +
    '                     clamp(u_bld_tint_amount[matId], 0.0, 1.0));' + #10 +
    '' + #10 +
    '    vec3 nrmSample = textureGrad(u_bld_normal_atlas, atlasUV, gradX, gradY).rgb;' + #10 +
    '    float perceptualRoughness = clamp(' + #10 +
    '        textureGrad(u_bld_mask_atlas, atlasUV, gradX, gradY).r, 0.04, 1.0);' + #10 +
    '    float metallic = clamp(u_bld_metallic[matId], 0.0, 1.0);' + #10 +
    '' + #10 +
    '    /* Tangent-space normal mapping from screen-space derivatives' + #10 +
    '       (no tangent attribute). Derivatives computed unconditionally —' + #10 +
    '       branchless to keep them defined across a 2×2 quad. */' + #10 +
    '    vec3 dp1 = -dFdx(gBldToCamera);' + #10 +
    '    vec3 dp2 = -dFdy(gBldToCamera);' + #10 +
    '    vec2 du1 = dFdx(vBldUV);' + #10 +
    '    vec2 du2 = dFdy(vBldUV);' + #10 +
    '    vec3 N = normalize(vBldNormalOS);' + #10 +
    GLSL_COTANGENT_FRAME +
    '' + #10 +
    '    /* View vector — true per-fragment world view direction. */' + #10 +
    '    vec3 V = normalize(gBldToCamera);' + #10 +
    '    if (dot(worldN, V) < 0.0) worldN = -worldN;' + #10 +
    '' + #10 +
    '    /* Cook-Torrance GGX directional sun (same maths as ground FS). */' + #10 +
    GLSL_COOK_TORRANCE_SUN +
    '' + #10 +
    '    /* ── Glass reflection. The glow atlas R channel marks glass panes' + #10 +
    '       (white) vs frame/wall (black); roofs carry an all-black glow cell' + #10 +
    '       so this never fires for them. Procedural 3-stop sky keyed on the' + #10 +
    '       reflected ray Y plus a sharp sun glint — a compact port of the' + #10 +
    '       Osm3dSceneEffects glass FS. (Sky colours are authored sRGB-ish,' + #10 +
    '       converted to linear before mixing into the lit colour.) */' + #10 +
    '    float glass = textureGrad(u_bld_glow_atlas, atlasUV, gradX, gradY).r;' + #10 +
    '    if (glass > 0.5) {' + #10 +
    '        /* Per-window pane id = integer cell of the tiling wall UV (one' + #10 +
    '           window-unit per fract repeat) → constant across the whole' + #10 +
    '           pane. Facade orientation is quantized in the vertex shader' + #10 +
    '           and passed flat. Hashing a smoothly interpolated normal' + #10 +
    '           amplifies its roundoff into stripes within one glass pane. */' + #10 +
    '        vec2 paneId = floor(vBldUV);' + #10 +
    '        vec2 seed   = paneId + vBldFacadeId;' + #10 +
    '        vec2 jitter = (bldHash22(seed) - 0.5) * 2.0 * u_bld_window_tilt;' + #10 +
    '        /* Tilt the reflection normal in the wall tangent frame (small-' + #10 +
    '           angle approx of a rotation). Drives both the sky direction and' + #10 +
    '           the sun glint, so some panes flash and others do not. */' + #10 +
    '        vec3 glassN = normalize(worldN + T * jitter.x + B * jitter.y);' + #10 +
    '        vec3 Rr  = reflect(-V, glassN);' + #10 +
    '        float g2h = smoothstep(-0.05, 0.15, Rr.y);' + #10 +
    '        float h2z = smoothstep( 0.15, 0.55, Rr.y);' + #10 +
    '        vec3 env = mix(u_sky_ground, u_sky_horizon, g2h);' + #10 +
    '        env      = mix(env,          u_sky_zenith,  h2z);' + #10 +
    '        vec3 envLin = gc_SRGBtoLINEAR(env);' + #10 +
    '        float sd    = clamp(dot(Rr, L), 0.0, 1.0);' + #10 +
    '        float glint = pow(sd, 90.0) * 2.0;' + #10 +
    '        float k = clamp(u_bld_reflect_strength, 0.0, 1.0);' + #10 +
    '        vec3 reflected = mix(colorLin, envLin, k) + u_sun_tint * glint;' + #10 +
    '        colorLin = mix(colorLin, reflected, glass);' + #10 +
    '    }' + #10 +
    '' + #10 +
    '    colorLin *= BLD_EXPOSURE;' + #10 +
    '    vec3 colorTM = colorLin / (colorLin + vec3(1.0));' + #10 +
    '    fragment_color.rgb = gc_LINEARtoSRGB(colorTM);' + #10 +
    '    fragment_color.a   = 1.0;' + #10 +
    '}' + #10;

implementation

uses
  Osm3dStudioSettings,   { EnableShaderAtomicCounters gate }
  Osm3dProfiler,         { PROF_COUNTER_HOUSES / _HOUSES_VS slots }
  Osm3dSceneEffects;     { AttachCounterEffectFS / AttachCounterEffectVS }

const
  { Alias of the shared atlas gutter; the shader inset u_bld_cell_inset =
    G/TilePixels below must match the gutter the base bakes into cells. }
  BLD_CELL_GUTTER = ATLAS_CELL_GUTTER;

function MaterialIdForBuilding(Palette: Integer; IsRoof: Boolean): Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1346);{$ENDIF}
  if Palette < 0 then Palette := 0;
  if Palette > 9 then Palette := 5;
  if IsRoof then
  begin
    if Palette > 5 then Palette := 0;
    Result := BUILDING_MAT_ROOF0 + Palette;
  end
  else if Palette <= 5 then
    Result := BUILDING_MAT_WALL0 + Palette
  else
    Result := BUILDING_MAT_WALL_TINT0 + (Palette - 6);
end;

const
  { metal roof (palette 1) reads slightly metallic; everything else dielectric. }
  ROOF_METALLIC: array[0..5] of Single = (0.0, 0.4, 0.0, 0.0, 0.1, 0.0);

function BuildingMaterialDesc(MatId: Integer): TBuildingMaterialDesc;
var
  Pal: Integer;
  Base: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1347);{$ENDIF}
  if (MatId < 0) or (MatId >= BUILDING_MAT_COUNT) then MatId := 0;
  if MatId >= BUILDING_MAT_WALL_TINT0 then
  begin
    Pal := 6 + (MatId - BUILDING_MAT_WALL_TINT0);
    if Pal > 9 then Pal := 6;
    Base := WallMaterialName(Pal) + '_window';
    Result.Name          := 'wall_' + IntToStr(Pal);
    Result.DiffusePath   := FACADE_TEX_DIR + Base + '_diffuse.png';
    Result.NormalPath    := FACADE_TEX_DIR + Base + '_normal.png';
    Result.MaskPath      := FACADE_TEX_DIR + Base + '_mask.png';
    Result.GlowPath      := FACADE_TEX_DIR + WallGlowFile(Pal);
    Result.FallbackColor := BUILDING_WALL_BASE[Pal];
    Result.Roughness     := 0.70;
    Result.Metallic      := 0.0;
    Result.IsWall        := True;
  end
  else if MatId < BUILDING_MAT_ROOF0 then
  begin
    Pal := MatId - BUILDING_MAT_WALL0;
    Base := WallMaterialName(Pal) + '_window';
    Result.Name          := 'wall_' + IntToStr(Pal);
    Result.DiffusePath   := FACADE_TEX_DIR + Base + '_diffuse.png';
    Result.NormalPath    := FACADE_TEX_DIR + Base + '_normal.png';
    Result.MaskPath      := FACADE_TEX_DIR + Base + '_mask.png';
    Result.GlowPath      := FACADE_TEX_DIR + WallGlowFile(Pal);
    Result.FallbackColor := BUILDING_WALL_BASE[Pal];   { единый источник палитр }
    Result.Roughness     := 0.70;
    Result.Metallic      := 0.0;
    Result.IsWall        := True;
  end
  else
  begin
    Pal := MatId - BUILDING_MAT_ROOF0;
    if Pal > 5 then Pal := 0;
    Base := RoofMaterialName(Pal);
    Result.Name          := 'roof_' + IntToStr(Pal);
    Result.DiffusePath   := ROOF_TEX_DIR + Base + '_diffuse.png';
    Result.NormalPath    := ROOF_TEX_DIR + Base + '_normal.png';
    Result.MaskPath      := ROOF_TEX_DIR + Base + '_mask.png';
    Result.GlowPath      := '';
    Result.FallbackColor := BUILDING_ROOF_BASE[Pal];   { единый источник палитр }
    Result.Roughness     := 0.80;
    Result.Metallic      := ROOF_METALLIC[Pal];
    Result.IsWall        := False;
  end;
end;

function DefaultBuildingAtlasLayout: TBuildingAtlasLayout;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1348);{$ENDIF}
  { 4×4×512 = 2048×2048, 16 cells: 0..5 walls, 6..11 roofs, 12..15 tint walls. }
  Result.GridCols   := 4;
  Result.GridRows   := 4;
  Result.TilePixels := 512;
end;

constructor TBuildingAtlas.Create(const ALayout: TBuildingAtlasLayout);
var
  I: Integer;
  D: TBuildingMaterialDesc;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1349);{$ENDIF}
  inherited Create(ALayout, [acDiffuse, acNormal, acMask, acGlow]);
  for I := 0 to BUILDING_MAT_COUNT - 1 do
  begin
    D := BuildingMaterialDesc(I);
    FFallback[I] := D.FallbackColor;
    FMetallic[I] := D.Metallic;
  end;
end;

function TBuildingAtlas.LogPrefix: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1350);{$ENDIF}
  Result := 'BuildingAtlas';
end;

function TBuildingAtlas.CacheFileName(Ch: TAtlasChannel): string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1351);{$ENDIF}
  { keep these names — existing disk caches depend on them }
  case Ch of
    acDiffuse: Result := 'bld_atlas_diffuse.png';
    acNormal:  Result := 'bld_atlas_normal.png';
    acMask:    Result := 'bld_atlas_mask.png';
    acGlow:    Result := 'bld_atlas_glow.png';
  else
    Result := 'bld_atlas_unknown.png';
  end;
end;

function TBuildingAtlas.MaterialCount: Integer;
begin
  Result := BUILDING_MAT_COUNT;
end;

function TBuildingAtlas.MaterialInfo(MatId: Integer): TAtlasMaterialInfo;
var
  D: TBuildingMaterialDesc;
begin
  D := BuildingMaterialDesc(MatId);
  Result.Name          := D.Name;
  Result.DiffusePath   := D.DiffusePath;
  Result.NormalPath    := D.NormalPath;
  Result.MaskPath      := D.MaskPath;
  Result.FallbackColor := D.FallbackColor;
  Result.Roughness     := D.Roughness;
end;


procedure TBuildingAtlas.BuildChannelsParallel(LogProc: TLogProc);
begin
  RunBuildPasses([@BuildImage, @BuildNormalImage, @BuildMaskImage,
                  @BuildGlowImage], LogProc);
end;

procedure TBuildingAtlas.BuildGlowImage(LogProc: TLogProc);
var
  I, Loaded: Integer;
  D: TBuildingMaterialDesc;
  C: TVector4Byte;
  Img: TRGBAlphaImage;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1355);{$ENDIF}
  EnsureChannelImage(acGlow);
  Loaded := 0;
  { all cells start black (no glass) so roofs and missing glow maps never reflect }
  C.X := 0; C.Y := 0; C.Z := 0; C.W := 255;
  for I := 0 to BUILDING_MAT_COUNT - 1 do
  begin
    D := BuildingMaterialDesc(I);
    FillCellSolid(acGlow, I, C);
    if (D.GlowPath <> '') and FillCellFromPNG(acGlow, I, D.GlowPath) then
      Inc(Loaded);
  end;
  Img := ChannelImage(acGlow);
  if Assigned(LogProc) and (Img <> nil) then
    LogProc(Format('  BuildingAtlas: glow %dx%d (%d glass-mask PNG loaded)',
      [Img.Width, Img.Height, Loaded]));
end;

function TBuildingAtlas.FallbackColor(MatId: Integer): TVector3;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1356);{$ENDIF}
  if (MatId < 0) or (MatId >= BUILDING_MAT_COUNT) then MatId := 0;
  Result := FFallback[MatId];
end;

function TBuildingAtlas.Metallic(MatId: Integer): Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1357);{$ENDIF}
  if (MatId < 0) or (MatId >= BUILDING_MAT_COUNT) then MatId := 0;
  Result := FMetallic[MatId];
end;

{ Merged IFS with the custom per-vertex attributes the building VS reads
  (materialId / bldUV / bldNormal). }
function BuildBuildingIFS(Composite: TGroundCompositeMesh): TIndexedFaceSetNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1358);{$ENDIF}
  { Solid=True: building shapes are single-sided (wound outward before the merge). }
  Result := BuildCompositeIFS(Composite, 'bldUV', 'bldNormal', True, Osm3dStudioSettings.BuildingShadowsActive);
end;

function BuildBuildingCompositeShape(Composite: TGroundCompositeMesh;
  Atlas: TBuildingAtlas; const SunDirToward: TVector3;
  LogProc: TLogProc): TShapeNode;
var
  Geo:        TIndexedFaceSetNode;
  Mat:        TUnlitMaterialNode;
  MatP:       TPhysicalMaterialNode;
  App:        TAppearanceNode;
  Effect:     TEffectNode;
  PV, PF:     TEffectPartNode;
  UseUrl:     Boolean;
  FallbackArr: array of TVector3;
  MetalArr:   array of Single;
  TintArr:    array of Single;
  I:          Integer;
  Sun:        TVector3;
  DiffuseTex, NormalTex, MaskTex, GlowTex: TAbstractTexture2DNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1359);{$ENDIF}
  Result := nil;
  if (Composite = nil) or (Composite.TriangleCount = 0) then Exit;
  if Atlas = nil then
    raise EInvalidOperation.Create('BuildBuildingCompositeShape: Atlas is nil');

  Geo := BuildBuildingIFS(Composite);
  if Geo = nil then Exit;

  App := TAppearanceNode.Create;
  { BuildingShadows: hand lighting to CGE. A LIT white matte material makes CGE
    run its own lighting on this shape, applying the sun's shadow via its native
    PLUG_light_scale (no manual shadow-map sampling from us). The FS below then
    outputs plain atlas albedo instead of its own lit colour, so CGE computes
    albedo x (sun x shadow + fills). Flag off: original unlit emissive path. }
  if Osm3dStudioSettings.BuildingShadowsActive then
  begin
    MatP := TPhysicalMaterialNode.Create;
    MatP.BaseColor := Vector3(1.0, 1.0, 1.0);
    MatP.Metallic  := 0.0;
    MatP.Roughness := 0.85;
    App.Material := MatP;
  end
  else
  begin
    Mat := TUnlitMaterialNode.Create;
    Mat.EmissiveColor := Vector3(1.0, 1.0, 1.0);   { FS-emitted RGB passes through }
    App.Material := Mat;
  end;

  Effect := TEffectNode.Create;
  Effect.Language := slGLSL;
  Effect.SetShaderLibraries(['castle-shader:/EyeWorldSpace.glsl']);

  PV := TEffectPartNode.Create;
  PV.ShaderType := stVertex;
  PV.Contents   := BUILDING_COMPOSITE_VS;
  PF := TEffectPartNode.Create;
  PF.ShaderType := stFragment;
  { BuildingShadows on: output plain LINEAR albedo and let CGE's own lighting
    (with its native shadow) multiply it — CGE gamma-corrects afterwards. The
    composite's own GGX/glass/tonemap still compute but their result is unused.
    Flag off: the original self-lit sRGB output. }
  if Osm3dStudioSettings.BuildingShadowsActive then
    PF.Contents := StringReplace(BUILDING_COMPOSITE_FS,
      '    fragment_color.rgb = gc_LINEARtoSRGB(colorTM);',
      '    fragment_color.rgb = albedoLin;', [])
  else
    PF.Contents   := BUILDING_COMPOSITE_FS;
  Effect.SetParts([PV, PF]);

  { Atlas samplers. Prefer URL nodes (shareable across tiles, deduped by
    CGE) once SaveToCache has run; otherwise single-use pixel nodes — valid
    only for the FIRST shape built from this atlas. }
  UseUrl := Atlas.DiffuseUrl <> '';
  if UseUrl then
  begin
    DiffuseTex := Atlas.CreateTextureNodeUrl;
    NormalTex  := Atlas.CreateNormalTextureNodeUrl;
    MaskTex    := Atlas.CreateMaskTextureNodeUrl;
    GlowTex    := Atlas.CreateGlowTextureNodeUrl;
  end
  else
  begin
    DiffuseTex := Atlas.CreateTextureNode;
    NormalTex  := Atlas.CreateNormalTextureNode;
    MaskTex    := Atlas.CreateMaskTextureNode;
    GlowTex    := Atlas.CreateGlowTextureNode;
  end;

  Effect.AddCustomField(TSFNode.Create(Effect, True, 'u_bld_atlas',
    [TAbstractTexture2DNode], DiffuseTex));
  Effect.AddCustomField(TSFNode.Create(Effect, True, 'u_bld_normal_atlas',
    [TAbstractTexture2DNode], NormalTex));
  Effect.AddCustomField(TSFNode.Create(Effect, True, 'u_bld_mask_atlas',
    [TAbstractTexture2DNode], MaskTex));
  Effect.AddCustomField(TSFNode.Create(Effect, True, 'u_bld_glow_atlas',
    [TAbstractTexture2DNode], GlowTex));

  Effect.AddCustomField(TSFInt32.Create(Effect, True,
    'u_bld_grid_cols', Atlas.Layout.GridCols));
  Effect.AddCustomField(TSFInt32.Create(Effect, True,
    'u_bld_grid_rows', Atlas.Layout.GridRows));
  { '/' is real division here, so e.g. 8/512 = 0.015625 (not integer 0). }
  Effect.AddCustomField(TSFFloat.Create(Effect, True,
    'u_bld_cell_inset', BLD_CELL_GUTTER / Atlas.Layout.TilePixels));

  SetLength(FallbackArr, BUILDING_MAT_COUNT);
  SetLength(MetalArr,    BUILDING_MAT_COUNT);
  for I := 0 to BUILDING_MAT_COUNT - 1 do
  begin
    FallbackArr[I] := Atlas.FallbackColor(I);
    MetalArr[I]    := Atlas.Metallic(I);
  end;
  Effect.AddCustomField(TMFVec3f.Create(Effect, True,
    'u_bld_fallback_rgb', FallbackArr));
  Effect.AddCustomField(TMFFloat.Create(Effect, True,
    'u_bld_metallic', MetalArr));
  SetLength(TintArr, BUILDING_MAT_COUNT);
  for I := 0 to BUILDING_MAT_COUNT - 1 do
    if I >= BUILDING_MAT_WALL_TINT0 then TintArr[I] := 0.90
    else TintArr[I] := 0.0;
  Effect.AddCustomField(TMFFloat.Create(Effect, True,
    'u_bld_tint_amount', TintArr));

  Sun := SunDirToward;
  if (Sun.X = 0) and (Sun.Y = 0) and (Sun.Z = 0) then
    Sun := DEFAULT_SUN_TOWARD;
  Effect.AddCustomField(TSFVec3f.Create(Effect, True, 'gc_SunDirToward', Sun));
  Effect.AddCustomField(TSFVec3f.Create(Effect, True,
    'u_sky_zenith',  Vector3(0.32, 0.52, 0.82)));
  Effect.AddCustomField(TSFVec3f.Create(Effect, True,
    'u_sky_horizon', Vector3(0.74, 0.84, 0.94)));
  Effect.AddCustomField(TSFVec3f.Create(Effect, True,
    'u_sky_ground',  Vector3(0.10, 0.11, 0.12)));
  Effect.AddCustomField(TSFVec3f.Create(Effect, True,
    'u_sun_tint',    Vector3(1.0, 0.93, 0.78)));
  Effect.AddCustomField(TSFFloat.Create(Effect, True,
    'u_bld_reflect_strength', 0.85));
  { Per-window reflection jitter: ±2.5° normal tilt (≈ ±5° reflection swing),
    fixed per pane. 0 disables it (all panes reflect identically). }
  Effect.AddCustomField(TSFFloat.Create(Effect, True,
    'u_bld_window_tilt', 0.0436));

  { LOD far cull only; defaults are conservative — the assembler may overwrite
    them from GlobalLODConfig.BuildingsFarMeters etc. }
  Effect.AddCustomField(TSFFloat.Create(Effect, True,
    'u_lod_far_base', 4000.0));
  Effect.AddCustomField(TSFFloat.Create(Effect, True,
    'u_lod_height_ref', 300.0));
  Effect.AddCustomField(TSFFloat.Create(Effect, True,
    'u_lod_ground_ref_y', 0.0));

  App.SetEffects([Effect]);

  Result := TShapeNode.Create;
  Result.Geometry   := Geo;
  Result.Appearance := App;
  CompactTileGeometry(Result);

  { Profiling counters for the merged composite — the shape buildings actually
    render through. Gated; off in production. }
  if EnableShaderAtomicCounters then
  begin
    AttachCounterEffectFS(Result, PROF_COUNTER_HOUSES);
    AttachCounterEffectVS(Result.Appearance as TAppearanceNode,
                          PROF_COUNTER_HOUSES_VS);
  end;

  if Assigned(LogProc) then
    LogProc(Format('  BuildingComposite: 1 merged shape, %d v, %d t, atlas %dx%d (%s nodes)',
      [Composite.VertexCount, Composite.TriangleCount,
       Atlas.Layout.GridCols * Atlas.Layout.TilePixels,
       Atlas.Layout.GridRows * Atlas.Layout.TilePixels,
       BoolToStr(UseUrl, 'URL', 'pixel')]));
end;

end.
