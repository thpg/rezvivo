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
  Osm3dGroundComposite, Osm3dGpuGround, Osm3dFacadeLayout,
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
  LogProc: TLogProc = nil): TShapeNode; overload;
function BuildBuildingCompositeShape(Composite: TGroundCompositeMesh;
  Atlas: TBuildingAtlas; const SunDirToward: TVector3;
  out DetailGroup: TCollisionNode; LogProc: TLogProc;
  Ground:TGpuGroundTile=nil; GroundX:Single=0; GroundZ:Single=0;
  const Layouts:TFacadeLayouts=nil; const Tints:TBuildingTints=nil): TShapeNode; overload;

{ Coarse, conservative batch culling plus collision exclusion for near trims. }
function BuildingDetailGroup(Shape: TShapeNode): TCollisionNode;

const
  BUILDING_COMPOSITE_VS = {$I shaders/building_material.vs.glsl.inc};
  BUILDING_COMPOSITE_FS = '#define PI 3.141592653589793' + #10 +
    GLSL_PBR_HELPERS + {$I shaders/building_material.glsl.inc};
  BUILDING_DETAIL_VS = {$I shaders/building_detail.vs.glsl.inc};
  BUILDING_DETAIL_FS = '#define PI 3.141592653589793' + #10 +
    GLSL_PBR_HELPERS + {$I shaders/building_detail.glsl.inc};

implementation

uses
  Osm3dRiderShadow,
  Osm3dBuildingFacade,
  Osm3dStudioSettings,   { EnableShaderAtomicCounters gate }
  Osm3dProfiler,         { PROF_COUNTER_HOUSES / _HOUSES_VS slots }
  Osm3dRtxMaterials, Osm3dSceneEffects;     { AttachCounterEffectFS / AttachCounterEffectVS }

function BuildingShadowGLSL: String;
begin
  { CGE discovers PLUG names before preprocessing. Rename the ground's final
    colour hook: facades apply visibility to direct lighting themselves. }
  Result := '#define GC_SURFACE_RECEIVER' + #10 +
    StringReplace(RIDER_SHADOW_GLSL, 'PLUG_fragment_modify',
    'bld_unusedGroundTint', [rfReplaceAll]);
end;

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

function BuildBuildingDetailShape(Geo: TIndexedFaceSetNode;
  const SunDirToward: TVector3; SharedApp: TAppearanceNode): TShapeNode;
var
  App: TAppearanceNode;
  Mat: TUnlitMaterialNode;
  MatP: TPhysicalMaterialNode;
  Effect: TEffectNode;
  PV, PF: TEffectPartNode;
  Sun: TVector3;
begin
  Result := nil;
  if Geo = nil then Exit;
  if SharedApp <> nil then
  begin
    Result := TShapeNode.Create; Result.X3DName := 'BuildingNearDetails';
    Result.Geometry := Geo; Result.Appearance := SharedApp;
    CompactTileGeometry(Result);
    Exit;
  end;
  App := TAppearanceNode.Create;
  { These bounded, fading trims do not enter the sun shadow map. The original
    complete wall/roof remains its sole caster, independent of camera distance. }
  App.ShadowCaster := False;
  if Osm3dStudioSettings.BuildingShadowsActive then
  begin
    MatP := TPhysicalMaterialNode.Create;
    MatP.BaseColor := Vector3(1,1,1); MatP.Metallic := 0; MatP.Roughness := 0.8;
    App.Material := MatP;
  end else
  begin
    Mat := TUnlitMaterialNode.Create; Mat.EmissiveColor := Vector3(1,1,1);
    App.Material := Mat;
  end;
  if Osm3dStudioSettings.BuildingShadowsActive then Effect := TEffectNode.Create
  else Effect := TRiderShadowGroundEffect.Create;
  Effect.Language := slGLSL;
  Effect.SetShaderLibraries(['castle-shader:/EyeWorldSpace.glsl']);
  PV := TEffectPartNode.Create; PV.ShaderType := stVertex;
  PV.Contents := BUILDING_DETAIL_VS;
  PF := TEffectPartNode.Create; PF.ShaderType := stFragment;
  if Osm3dStudioSettings.BuildingShadowsActive then
    PF.Contents := '#define BLD_NATIVE_LIGHTING' + #10 + BUILDING_DETAIL_FS +
      {$I shaders/building_detail.native.glsl.inc}
  else PF.Contents := BuildingShadowGLSL + BUILDING_DETAIL_FS;
  Effect.SetParts([PV,PF]);
  if Effect is TRiderShadowGroundEffect then
    TRiderShadowGroundEffect(Effect).SetGroundFragment(PF);
  Sun := SunDirToward;
  if Sun.LengthSqr < 0.001 then Sun := DEFAULT_SUN_TOWARD;
  Effect.AddCustomField(TSFVec3f.Create(Effect, True, 'gc_SunDirToward', Sun));
  Effect.AddCustomField(TSFFloat.Create(Effect, True, 'u_bld_detail_near', BUILDING_DETAIL_NEAR));
  Effect.AddCustomField(TSFFloat.Create(Effect, True, 'u_bld_detail_far', BUILDING_DETAIL_FAR));
  App.SetEffects([Effect]);
  Result := TShapeNode.Create; Result.X3DName := 'BuildingNearDetails';
  Result.Geometry := Geo; Result.Appearance := App;
  CompactTileGeometry(Result);
end;

function BuildingDetailGroup(Shape: TShapeNode): TCollisionNode;
var Coord: TCoordinateNode; Geo:TIndexedFaceSetNode; LOD:TLODNode;
    MinP,MaxP,P:TVector3; I,J:Integer;
begin
  Result:=nil;
  if Shape=nil then Exit;
  Result:=TCollisionNode.Create; Result.Enabled:=False;
  Geo:=Shape.Geometry as TIndexedFaceSetNode;
  Coord:=Geo.Coord as TCoordinateNode;
  MinP:=Vector3(1e30,1e30,1e30); MaxP:=-MinP;
  for I:=0 to Coord.FdPoint.Count-1 do
  begin
    P:=Coord.FdPoint.Items[I];
    for J:=0 to 2 do
    begin
      if P.Data[J]<MinP.Data[J] then MinP.Data[J]:=P.Data[J];
      if P.Data[J]>MaxP.Data[J] then MaxP.Data[J]:=P.Data[J];
    end;
  end;
  LOD:=TLODNode.Create;
  LOD.FdCenter.Send((MinP+MaxP)*0.5);
  { If a box is within 70 m of the camera its batch must still be active.
    Beyond this enclosing sphere even vertex processing/draw submission stops. }
  if Geo.X3DName='BuildingStructure' then
    LOD.FdRange.Send([600+(MaxP-MinP).Length*0.5])
  else LOD.FdRange.Send([BUILDING_DETAIL_FAR+(MaxP-MinP).Length*0.5]);
  LOD.AddChildren(Shape); LOD.AddChildren(TGroupNode.Create);
  Result.AddChildren(LOD);
end;

function BuildBuildingCompositeInternal(Composite: TGroundCompositeMesh;
  Atlas: TBuildingAtlas; const SunDirToward: TVector3;
  out DetailGroup: TCollisionNode; WantDetails: Boolean; LogProc: TLogProc;
  Ground:TGpuGroundTile=nil; GroundX:Single=0; GroundZ:Single=0;
  const Layouts:TFacadeLayouts=nil; const Tints:TBuildingTints=nil): TShapeNode;
var
  Geo:        TIndexedFaceSetNode;
  Facade: TBuildingFacadeData;
  DetailGeos: TBuildingDetailGeometryArray;
  DetailShape: TShapeNode;
  DetailApp: TAppearanceNode;
  Mat:        TUnlitMaterialNode;
  MatP:       TPhysicalMaterialNode;
  App:        TAppearanceNode;
  Effect:     TEffectNode;
  PV, PF:     TEffectPartNode;
  UseUrl:     Boolean;
  FallbackArr: array of TVector3;
  PhotoTints: array of TVector3;
  MetalArr:   array of Single;
  TintArr:    array of Single;
  I:          Integer;
  Sun:        TVector3;
  DiffuseTex, NormalTex, MaskTex, GlowTex: TAbstractTexture2DNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1359);{$ENDIF}
  Result := nil; DetailGroup := nil;
  if (Composite = nil) or (Composite.TriangleCount = 0) then Exit;
  if Atlas = nil then
    raise EInvalidOperation.Create('BuildBuildingCompositeShape: Atlas is nil');

  Facade := TBuildingFacadeData.Create(Composite, WantDetails, Ground, GroundX, GroundZ,Layouts,Tints);
  try
    Geo := BuildBuildingIFS(Composite);
    if Geo = nil then Exit;
    Facade.AttachInfo(Geo);
    PhotoTints:=Facade.PhotoTintColors;
    if WantDetails then
    begin
      DetailGeos := Facade.DetailGeometries;
      DetailApp := nil;
      if Length(DetailGeos)>0 then
      begin
        DetailGroup := TCollisionNode.Create; DetailGroup.Enabled := False;
        for I:=0 to High(DetailGeos) do
        begin
          DetailShape := BuildBuildingDetailShape(DetailGeos[I], SunDirToward, DetailApp);
          DetailApp := DetailShape.Appearance as TAppearanceNode;
          DetailGroup.AddChildren(BuildingDetailGroup(DetailShape));
        end;
      end;
    end;
  finally
    Facade.Free;
  end;

  App := TAppearanceNode.Create;
  { Native CGE light/shadow hooks receive the same complete surface as the
    self-lit composite path: atlas normals, wear roughness and glass interior. }
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

  if Osm3dStudioSettings.BuildingShadowsActive then Effect := TEffectNode.Create
  else Effect := TRiderShadowGroundEffect.Create;
  Effect.Language := slGLSL;
  Effect.SetShaderLibraries(['castle-shader:/EyeWorldSpace.glsl']);

  PV := TEffectPartNode.Create;
  PV.ShaderType := stVertex;
  PV.Contents   := BUILDING_COMPOSITE_VS;
  PF := TEffectPartNode.Create;
  PF.ShaderType := stFragment;
  if Osm3dStudioSettings.BuildingShadowsActive then
    PF.Contents := '#define BLD_NATIVE_LIGHTING' + #10 + BUILDING_COMPOSITE_FS +
      {$I shaders/building_material.native.glsl.inc}
  else
    PF.Contents := BuildingShadowGLSL + BUILDING_COMPOSITE_FS;
  PF.Contents:=RTX_MATERIAL_GLSL+PF.Contents;
  AttachRtxMaterial(Effect);
  Effect.SetParts([PV, PF]);
  if Effect is TRiderShadowGroundEffect then
    TRiderShadowGroundEffect(Effect).SetGroundFragment(PF);

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
  Effect.AddCustomField(TMFVec3f.Create(Effect, True,'u_bld_photo_tints',PhotoTints));

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
  Effect.AddCustomField(TSFFloat.Create(Effect, True,
    'u_bld_reflect_strength', 1.0));
  { Per-window reflection jitter: about ±0.34 degrees of normal tilt,
    fixed per pane. 0 disables it (all panes reflect identically). }
  Effect.AddCustomField(TSFFloat.Create(Effect, True,
    'u_bld_window_tilt', 0.006));

  { Whole-tile CPU distance culling handles the far gate. Avoid a fragment
    discard here: it prevents early depth rejection behind nearby facades. }

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

function BuildBuildingCompositeShape(Composite: TGroundCompositeMesh;
  Atlas: TBuildingAtlas; const SunDirToward: TVector3;
  LogProc: TLogProc): TShapeNode;
var Ignored: TCollisionNode;
begin
  Result := BuildBuildingCompositeInternal(Composite, Atlas, SunDirToward,
    Ignored, False, LogProc);
end;

function BuildBuildingCompositeShape(Composite: TGroundCompositeMesh;
  Atlas: TBuildingAtlas; const SunDirToward: TVector3;
  out DetailGroup: TCollisionNode; LogProc: TLogProc;
  Ground:TGpuGroundTile; GroundX:Single; GroundZ:Single; const Layouts:TFacadeLayouts; const Tints:TBuildingTints): TShapeNode;
begin
  Result := BuildBuildingCompositeInternal(Composite, Atlas, SunDirToward,
    DetailGroup, True, LogProc, Ground, GroundX, GroundZ,Layouts,Tints);
end;

end.
