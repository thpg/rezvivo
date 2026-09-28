unit Osm3dFenceComposite;

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
  CastleRenderOptions,
  X3DNodes,
  X3DFields,
  Osm3dGeoMath,
  Osm3dGeomMesh,
  Osm3dGlslLib,
  Osm3dCompositeAtlas,    { TCompositeAtlasBase / TAtlasLayout — общая база атласов }
  Osm3dGroundComposite,   { TGroundCompositeMesh / Builder reuse }
  Osm3dBuildingTextures   { BUILDING_TEX_ROOT — fence PNGs live beside surfaces/ }
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
;

const
  { Fence material ids = Ord(TFenceMaterial) in Osm3dGeomFences, so builder and atlas
    agree without a translation table. }
  FENCE_MAT_WOOD      = 0;
  FENCE_MAT_CHAINLINK = 1;
  FENCE_MAT_METAL     = 2;
  FENCE_MAT_CONCRETE  = 3;
  FENCE_MAT_HEDGE     = 4;
  FENCE_MAT_STONE     = 5;
  FENCE_MAT_COUNT     = 6;

  { Fence textures live under textures/surfaces/ (wood_fence_*.png, ...). }
  FENCE_TEX_DIR = BUILDING_TEX_ROOT + 'surfaces/';

type
  { Built at runtime (not a const table) to keep paths and per-material constants together. }
  TFenceMaterialDesc = record
    Name:          string;
    DiffusePath:   string;
    NormalPath:    string;
    MaskPath:      string;       { R channel baked into mask atlas as roughness }
    FallbackColor: TVector3;     { used when the diffuse PNG is missing }
    Roughness:     Single;       { constant baked into maskless cells }
    Metallic:      Single;       { per-material LUT }
  end;

{ Resolve the descriptor for a material id 0..5. }
function FenceMaterialDesc(MatId: Integer): TFenceMaterialDesc;

{ Identity clamp — material id already equals Ord(TFenceMaterial). }
function MaterialIdForFence(Material: Integer): Integer; inline;

type
  { Alias of the shared atlas layout record. }
  TFenceAtlasLayout = TAtlasLayout;

function DefaultFenceAtlasLayout: TFenceAtlasLayout;

type
  { 6 fence materials over diffuse/normal/mask (no glow — fences don't reflect sky).
    Diffuse keeps the source PNG alpha (chain-link/railing cutout); the FS discards below
    u_fnc_alpha_cutoff. CreateTextureNode passes image ownership; SaveToCache enables URL sharing. }
  TFenceAtlas = class(TCompositeAtlasBase)
  private
    FFallback: array[0..FENCE_MAT_COUNT - 1] of TVector3;
    FMetallic: array[0..FENCE_MAT_COUNT - 1] of Single;
  protected
    function LogPrefix: string; override;
    function CacheFileName(Ch: TAtlasChannel): string; override;
    function MaterialCount: Integer; override;
    function MaterialInfo(MatId: Integer): TAtlasMaterialInfo; override;
  public
    constructor Create(const ALayout: TFenceAtlasLayout); reintroduce;

    function FallbackColor(MatId: Integer): TVector3;
    function Metallic(MatId: Integer): Single;
  end;

{ Build ONE fence-composite shape from a merged mesh (materialIds 0..5).
  Atlas must already be built; if SaveToCache'd, shareable URL nodes are used, otherwise
  single-use pixel nodes valid only for the FIRST shape. SunDirToward TOWARD the sun
  (zero -> default). nil if empty. }
function BuildFenceCompositeShape(Composite: TGroundCompositeMesh;
  Atlas: TFenceAtlas; const SunDirToward: TVector3;
  LogProc: TLogProc = nil): TShapeNode;

const
  { Vertex effect (mirror of BUILDING_COMPOSITE_VS) }
  FENCE_COMPOSITE_VS =
    'attribute float materialId;' + #10 +
    { TUnlitMaterial makes CGE skip texcoord/normal upload, so UV and normal ride
      dedicated TFloatVertexAttributeNode streams. }
    'attribute vec2  fncUV;' + #10 +
    'attribute vec3  fncNormal;' + #10 +
    '' + #10 +
    'varying float vFncMatId;' + #10 +
    'varying vec2  vFncUV;' + #10 +
    'varying vec3  vFncNormalOS;' + #10 +
    '' + #10 +
    'void PLUG_vertex_object_space(' + #10 +
    '  const in vec4 vertex_object,' + #10 +
    '  const in vec3 normal_object)' + #10 +
    '{' + #10 +
    '    vFncMatId    = materialId;' + #10 +
    '    vFncNormalOS = fncNormal;' + #10 +
    '    vFncUV       = fncUV;' + #10 +
    '}' + #10;

  { Fragment effect (mirror of BUILDING_COMPOSITE_FS, minus the
 glass/glow block, plus the alpha cutout) }
  FENCE_COMPOSITE_FS =
    '#define U_FNC_MAT_COUNT 6' + #10 +
    '#define PI 3.141592653589793' + #10 +
    { Kept equal to the building/ground exposure so fences match daylight level. }
    '#define FNC_EXPOSURE 2.0' + #10 +
    '' + #10 +
    'varying float vFncMatId;' + #10 +
    'varying vec2  vFncUV;' + #10 +
    'varying vec3  vFncNormalOS;' + #10 +
    '' + #10 +
    'uniform sampler2D u_fnc_atlas;' + #10 +
    'uniform sampler2D u_fnc_normal_atlas;' + #10 +
    'uniform sampler2D u_fnc_mask_atlas;' + #10 +
    'uniform int   u_fnc_grid_cols;' + #10 +
    'uniform int   u_fnc_grid_rows;' + #10 +
    { Cell apron inset (gutter_px / tile_px): UV maps into [ins, 1-ins]. Must match FNC_CELL_GUTTER. }
    'uniform float u_fnc_cell_inset;' + #10 +
    'uniform vec3  u_fnc_fallback_rgb[U_FNC_MAT_COUNT];' + #10 +
    'uniform float u_fnc_metallic[U_FNC_MAT_COUNT];' + #10 +
    'uniform float u_fnc_tint_amount;' + #10 +
    { Atlas alpha below this -> fragment discarded (chain-link/railing). Opaque mats = 1.0. }
    'uniform float u_fnc_alpha_cutoff;' + #10 +
    '' + #10 +
    '/* Sun. gc_SunDirToward = direction TOWARD the sun (world). */' + #10 +
    'uniform vec3  gc_SunDirToward;' + #10 +
    '' + #10 +
    GLSL_LOD_UNIFORMS +
    '' + #10 +
    GLSL_SUN_CONSTS +
    '' + #10 +
    '/* World space from castle-shader:/EyeWorldSpace.glsl (attached via' + #10 +
    '   TEffectNode.SetShaderLibraries) — same mechanism the ground/' + #10 +
    '   building effects use. */' + #10 +
    'vec4 position_eye_to_world_space(vec4 position_eye);' + #10 +
    'vec3 gFncCamWorld;' + #10 +
    'vec3 gFncToCamera;' + #10 +
    'void PLUG_fragment_eye_space(const vec4 vertex_eye, inout vec3 normal_eye)' + #10 +
    '{' + #10 +
    '    gFncCamWorld = position_eye_to_world_space(vec4(0.0,0.0,0.0,1.0)).xyz;' + #10 +
    '    gFncToCamera = position_eye_to_world_space(vec4(-vertex_eye.xyz,0.0)).xyz;' + #10 +
    '}' + #10 +
    '' + #10 +
    GLSL_PBR_HELPERS +
    '' + #10 +
    'void PLUG_main_texture_apply(inout vec4 fragment_color, const in vec3 normal)' + #10 +
    '{' + #10 +
    '    int matId = int(floor(vFncMatId + 0.5));' + #10 +
    '    if (matId < 0) matId = 0;' + #10 +
    '    if (matId >= U_FNC_MAT_COUNT) matId = 0;' + #10 +
    '' + #10 +
    '    /* ── LOD far cull (horizontal distance, altitude-scaled). */' + #10 +
    '    float lodDist  = length(gFncToCamera.xz);' + #10 +
    '    float camAbove = max(0.0, gFncCamWorld.y - u_lod_ground_ref_y);' + #10 +
    '    float hScale   = 1.0 + camAbove / u_lod_height_ref;' + #10 +
    '    if (lodDist > u_lod_far_base * hScale) discard;' + #10 +
    '' + #10 +
    '    /* Atlas cell for this matId. */' + #10 +
    '    float colsF = float(u_fnc_grid_cols);' + #10 +
    '    float rowsF = float(u_fnc_grid_rows);' + #10 +
    '    int col = matId - (matId/u_fnc_grid_cols)*u_fnc_grid_cols;' + #10 +
    '    int row = matId / u_fnc_grid_cols;' + #10 +
    '    vec2 cellOrigin = vec2(float(col)/colsF, float(row)/rowsF);' + #10 +
    '    vec2 cellSpan   = vec2(1.0/colsF, 1.0/rowsF);' + #10 +
    '' + #10 +
    '    /* UV is pre-baked on the mesh (lengthAlong/uvWidth, heightFrac).' + #10 +
    '       fract() tiles inside the cell, confined to [ins, 1-ins].' + #10 +
    '       textureGrad with pre-fract derivatives keeps mip selection' + #10 +
    '       from collapsing at the integer wrap. */' + #10 +
    '    vec2  baseUV  = vFncUV;' + #10 +
    '    float ins     = u_fnc_cell_inset;' + #10 +
    '    float ispan   = 1.0 - 2.0 * ins;' + #10 +
    '    vec2  tiledUV = fract(baseUV);' + #10 +
    '    vec2  localUV = vec2(ins) + tiledUV * ispan;' + #10 +
    '    vec2  atlasUV = cellOrigin + localUV * cellSpan;' + #10 +
    '    vec2  gradX = dFdx(baseUV) * cellSpan * ispan;' + #10 +
    '    vec2  gradY = dFdy(baseUV) * cellSpan * ispan;' + #10 +
    '' + #10 +
    '    vec4 diffSample = textureGrad(u_fnc_atlas, atlasUV, gradX, gradY);' + #10 +
    '' + #10 +
    '    /* ── Alpha cutout. Chain-link / railing holes are discarded;' + #10 +
    '       opaque materials carry alpha 1.0 so this never fires. */' + #10 +
    '    if (diffSample.a < u_fnc_alpha_cutoff) discard;' + #10 +
    '' + #10 +
    '    vec3 albedoLin  = gc_SRGBtoLINEAR(diffSample.rgb);' + #10 +
    '    albedoLin = mix(albedoLin,' + #10 +
    '                    gc_SRGBtoLINEAR(u_fnc_fallback_rgb[matId]),' + #10 +
    '                    clamp(u_fnc_tint_amount, 0.0, 1.0));' + #10 +
    '' + #10 +
    '    vec3 nrmSample = textureGrad(u_fnc_normal_atlas, atlasUV, gradX, gradY).rgb;' + #10 +
    '    float perceptualRoughness = clamp(' + #10 +
    '        textureGrad(u_fnc_mask_atlas, atlasUV, gradX, gradY).r, 0.04, 1.0);' + #10 +
    '    float metallic = clamp(u_fnc_metallic[matId], 0.0, 1.0);' + #10 +
    '' + #10 +
    '    /* Tangent-space normal mapping from screen-space derivatives' + #10 +
    '       (no tangent attribute) — same maths as the building FS. */' + #10 +
    '    vec3 dp1 = -dFdx(gFncToCamera);' + #10 +
    '    vec3 dp2 = -dFdy(gFncToCamera);' + #10 +
    '    vec2 du1 = dFdx(vFncUV);' + #10 +
    '    vec2 du2 = dFdy(vFncUV);' + #10 +
    '    vec3 N = normalize(vFncNormalOS);' + #10 +
    GLSL_COTANGENT_FRAME +
    '' + #10 +
    '    /* View vector — true per-fragment world view direction. */' + #10 +
    '    vec3 V = normalize(gFncToCamera);' + #10 +
    '    /* Two-sided: flip the shading normal toward the viewer so the' + #10 +
    '       back face of the fence is lit, not black. */' + #10 +
    '    if (dot(worldN, V) < 0.0) worldN = -worldN;' + #10 +
    '' + #10 +
    '    /* Cook-Torrance GGX directional sun (same maths as building FS). */' + #10 +
    GLSL_COOK_TORRANCE_SUN +
    '' + #10 +
    '    colorLin *= FNC_EXPOSURE;' + #10 +
    '    vec3 colorTM = colorLin / (colorLin + vec3(1.0));' + #10 +
    '    fragment_color.rgb = gc_LINEARtoSRGB(colorTM);' + #10 +
    '    fragment_color.a   = 1.0;' + #10 +
    '}' + #10;

implementation

const
  { Alias of the shared atlas gutter; u_fnc_cell_inset = G/TilePixels below must match it. }
  FNC_CELL_GUTTER = ATLAS_CELL_GUTTER;

function MaterialIdForFence(Material: Integer): Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1393);{$ENDIF}
  if (Material < 0) or (Material >= FENCE_MAT_COUNT) then
    Result := 0
  else
    Result := Material;
end;

const
  { Fallback albedo when the diffuse PNG is missing. }
  FENCE_FALLBACK: array[0..FENCE_MAT_COUNT - 1] of TVector3 = (
    (X:0.55; Y:0.42; Z:0.28),   { wood      — weathered brown }
    (X:0.62; Y:0.64; Z:0.66),   { chainLink — galvanised grey }
    (X:0.40; Y:0.42; Z:0.45),   { metal     — dark steel }
    (X:0.74; Y:0.73; Z:0.70),   { concrete  — light grey }
    (X:0.28; Y:0.40; Z:0.20),   { hedge     — foliage green }
    (X:0.66; Y:0.62; Z:0.55));  { stone     — grey-tan }

  { chain-link + metal read metallic (galvanised steel); the rest dielectric. }
  FENCE_METALLIC: array[0..FENCE_MAT_COUNT - 1] of Single =
    (0.0, 0.55, 0.70, 0.0, 0.0, 0.0);

  { Per-material roughness baked into maskless cells (the FS reads mask.r). }
  FENCE_ROUGHNESS: array[0..FENCE_MAT_COUNT - 1] of Single =
    (0.80, 0.50, 0.40, 0.90, 0.95, 0.85);

  { Base file name (without _diffuse/_normal/_mask.png) per material. }
  FENCE_TEX_BASE: array[0..FENCE_MAT_COUNT - 1] of string = (
    'wood_fence',
    'chainlink_fence',
    'metal_fence',
    'concrete_fence',
    'hedge',
    'stone_wall');

function FenceMaterialDesc(MatId: Integer): TFenceMaterialDesc;
var
  Base: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1394);{$ENDIF}
  if (MatId < 0) or (MatId >= FENCE_MAT_COUNT) then MatId := 0;
  Base := FENCE_TEX_BASE[MatId];
  Result.Name          := 'fence_' + IntToStr(MatId);
  Result.DiffusePath   := FENCE_TEX_DIR + Base + '_diffuse.png';
  Result.NormalPath    := FENCE_TEX_DIR + Base + '_normal.png';
  Result.MaskPath      := FENCE_TEX_DIR + Base + '_mask.png';
  Result.FallbackColor := FENCE_FALLBACK[MatId];
  Result.Roughness     := FENCE_ROUGHNESS[MatId];
  Result.Metallic      := FENCE_METALLIC[MatId];
end;

function DefaultFenceAtlasLayout: TFenceAtlasLayout;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1395);{$ENDIF}
  { 4×2×512 = 2048×1024 (power-of-two), 8 cells, 6 used (0..5). }
  Result.GridCols   := 4;
  Result.GridRows   := 2;
  Result.TilePixels := 512;
end;

constructor TFenceAtlas.Create(const ALayout: TFenceAtlasLayout);
var
  I: Integer;
  D: TFenceMaterialDesc;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1396);{$ENDIF}
  inherited Create(ALayout, [acDiffuse, acNormal, acMask]);
  for I := 0 to FENCE_MAT_COUNT - 1 do
  begin
    D := FenceMaterialDesc(I);
    FFallback[I] := D.FallbackColor;
    FMetallic[I] := D.Metallic;
  end;
end;

function TFenceAtlas.LogPrefix: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1397);{$ENDIF}
  Result := 'FenceAtlas';
end;

function TFenceAtlas.CacheFileName(Ch: TAtlasChannel): string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1398);{$ENDIF}
  { keep these names — existing disk caches depend on them }
  case Ch of
    acDiffuse: Result := 'fnc_atlas_diffuse.png';
    acNormal:  Result := 'fnc_atlas_normal.png';
    acMask:    Result := 'fnc_atlas_mask.png';
  else
    Result := 'fnc_atlas_unknown.png';
  end;
end;

function TFenceAtlas.MaterialCount: Integer;
begin
  Result := FENCE_MAT_COUNT;
end;

function TFenceAtlas.MaterialInfo(MatId: Integer): TAtlasMaterialInfo;
var
  D: TFenceMaterialDesc;
begin
  D := FenceMaterialDesc(MatId);
  Result.Name          := D.Name;
  Result.DiffusePath   := D.DiffusePath;
  Result.NormalPath    := D.NormalPath;
  Result.MaskPath      := D.MaskPath;
  Result.FallbackColor := D.FallbackColor;
  Result.Roughness     := D.Roughness;
end;

function TFenceAtlas.FallbackColor(MatId: Integer): TVector3;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1402);{$ENDIF}
  if (MatId < 0) or (MatId >= FENCE_MAT_COUNT) then MatId := 0;
  Result := FFallback[MatId];
end;

function TFenceAtlas.Metallic(MatId: Integer): Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1403);{$ENDIF}
  if (MatId < 0) or (MatId >= FENCE_MAT_COUNT) then MatId := 0;
  Result := FMetallic[MatId];
end;

{ Merged IFS with the custom per-vertex attributes the fence VS reads
  (materialId / fncUV / fncNormal). Solid=False: fences are two-sided. }
function BuildFenceIFS(Composite: TGroundCompositeMesh): TIndexedFaceSetNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1404);{$ENDIF}
  { Solid=False: fences are two-sided; the FS flips the shading normal toward the viewer. }
  Result := BuildCompositeIFS(Composite, 'fncUV', 'fncNormal', False, False);
end;

function BuildFenceCompositeShape(Composite: TGroundCompositeMesh;
  Atlas: TFenceAtlas; const SunDirToward: TVector3;
  LogProc: TLogProc): TShapeNode;
var
  Geo:        TIndexedFaceSetNode;
  Mat:        TUnlitMaterialNode;
  App:        TAppearanceNode;
  Effect:     TEffectNode;
  PV, PF:     TEffectPartNode;
  UseUrl:     Boolean;
  FallbackArr: array of TVector3;
  MetalArr:   array of Single;
  I:          Integer;
  Sun:        TVector3;
  DiffuseTex, NormalTex, MaskTex: TAbstractTexture2DNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1405);{$ENDIF}
  Result := nil;
  if (Composite = nil) or (Composite.TriangleCount = 0) then Exit;
  if Atlas = nil then
    raise EInvalidOperation.Create('BuildFenceCompositeShape: Atlas is nil');

  Geo := BuildFenceIFS(Composite);
  if Geo = nil then Exit;

  Mat := TUnlitMaterialNode.Create;
  Mat.EmissiveColor := Vector3(1.0, 1.0, 1.0);   { FS-emitted RGB passes through }
  App := TAppearanceNode.Create;
  App.Material := Mat;

  Effect := TEffectNode.Create;
  Effect.Language := slGLSL;
  Effect.SetShaderLibraries(['castle-shader:/EyeWorldSpace.glsl']);

  PV := TEffectPartNode.Create;
  PV.ShaderType := stVertex;
  PV.Contents   := FENCE_COMPOSITE_VS;
  PF := TEffectPartNode.Create;
  PF.ShaderType := stFragment;
  PF.Contents   := FENCE_COMPOSITE_FS;
  Effect.SetParts([PV, PF]);

  { URL nodes (shareable, deduped) once SaveToCache ran; else single-use pixel nodes
    valid only for the FIRST shape. }
  UseUrl := Atlas.DiffuseUrl <> '';
  if UseUrl then
  begin
    DiffuseTex := Atlas.CreateTextureNodeUrl;
    NormalTex  := Atlas.CreateNormalTextureNodeUrl;
    MaskTex    := Atlas.CreateMaskTextureNodeUrl;
  end
  else
  begin
    DiffuseTex := Atlas.CreateTextureNode;
    NormalTex  := Atlas.CreateNormalTextureNode;
    MaskTex    := Atlas.CreateMaskTextureNode;
  end;

  Effect.AddCustomField(TSFNode.Create(Effect, True, 'u_fnc_atlas',
    [TAbstractTexture2DNode], DiffuseTex));
  Effect.AddCustomField(TSFNode.Create(Effect, True, 'u_fnc_normal_atlas',
    [TAbstractTexture2DNode], NormalTex));
  Effect.AddCustomField(TSFNode.Create(Effect, True, 'u_fnc_mask_atlas',
    [TAbstractTexture2DNode], MaskTex));

  Effect.AddCustomField(TSFInt32.Create(Effect, True,
    'u_fnc_grid_cols', Atlas.Layout.GridCols));
  Effect.AddCustomField(TSFInt32.Create(Effect, True,
    'u_fnc_grid_rows', Atlas.Layout.GridRows));
  { '/' is real division here, so e.g. 8/512 = 0.015625 (not integer 0). }
  Effect.AddCustomField(TSFFloat.Create(Effect, True,
    'u_fnc_cell_inset', FNC_CELL_GUTTER / Atlas.Layout.TilePixels));

  SetLength(FallbackArr, FENCE_MAT_COUNT);
  SetLength(MetalArr,    FENCE_MAT_COUNT);
  for I := 0 to FENCE_MAT_COUNT - 1 do
  begin
    FallbackArr[I] := Atlas.FallbackColor(I);
    MetalArr[I]    := Atlas.Metallic(I);
  end;
  Effect.AddCustomField(TMFVec3f.Create(Effect, True,
    'u_fnc_fallback_rgb', FallbackArr));
  Effect.AddCustomField(TMFFloat.Create(Effect, True,
    'u_fnc_metallic', MetalArr));
  Effect.AddCustomField(TSFFloat.Create(Effect, True,
    'u_fnc_tint_amount', 0.0));
  { Alpha cutout threshold — chain-link / railing holes discarded. }
  Effect.AddCustomField(TSFFloat.Create(Effect, True,
    'u_fnc_alpha_cutoff', 0.5));

  Sun := SunDirToward;
  if (Sun.X = 0) and (Sun.Y = 0) and (Sun.Z = 0) then
    Sun := DEFAULT_SUN_TOWARD;
  Effect.AddCustomField(TSFVec3f.Create(Effect, True, 'gc_SunDirToward', Sun));

  { LOD far cull only; the assembler may overwrite these from GlobalLODConfig. }
  Effect.AddCustomField(TSFFloat.Create(Effect, True,
    'u_lod_far_base', 2500.0));
  Effect.AddCustomField(TSFFloat.Create(Effect, True,
    'u_lod_height_ref', 300.0));
  Effect.AddCustomField(TSFFloat.Create(Effect, True,
    'u_lod_ground_ref_y', 0.0));

  App.SetEffects([Effect]);

  Result := TShapeNode.Create;
  Result.Geometry   := Geo;
  Result.Appearance := App;
  CompactTileGeometry(Result);

  if Assigned(LogProc) then
    LogProc(Format('  FenceComposite: 1 merged shape, %d v, %d t, atlas %dx%d (%s nodes)',
      [Composite.VertexCount, Composite.TriangleCount,
       Atlas.Layout.GridCols * Atlas.Layout.TilePixels,
       Atlas.Layout.GridRows * Atlas.Layout.TilePixels,
       BoolToStr(UseUrl, 'URL', 'pixel')]));
end;

end.
