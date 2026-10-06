unit GameDreamWorldScene;
{$mode objfpc}{$H+}
interface
uses Classes,CastleScene,CastleViewport,CastleTransform,fpjson,X3DNodes,Osm3dDreamWorld,Osm3dWaterShader,
  Osm3dRenderGrass,Osm3dRenderInstanced,Osm3dProceduralVegetation;
type
  { Same material and vegetation renderers as Real World; local baked data. }
  TDreamWorldVisual = class
  private
    FScene,FCasterScene:TCastleScene;
    FParent:TCastleTransform;
    FCancel:TThread;
    FGLReady,FChunkPrimed:Boolean;
    FChunks,FCasterChunks,FChunkParents,FChunkRoots,FTextureBindings,FChunkTextures:TList;
    FSurfaceRoot,FStaticCasterRoot:TX3DRootNode;
    FMaxDrawMs:QWord;
    FMaxDrawChunk:string;
    FUploaded,FGLStage,FSkyStep,FTextureStep:Integer;
    FWater:TWaterCompositeShader;
    FSky:TCastleBackground;
    FCoastal:Boolean;
    FTrees:TCastleAbstractTreeRenderer;
    FShrubs:TCastleAbstractShrubRenderer;
    FProcedural:TOsmProceduralVegetation;
    FGrass:TGrassRenderer;
    FModelFiles,FModelInstances,FSerial:Integer;
    FTimings:TJSONObject;
    procedure CheckCancelled;
    procedure PreloadTexture(Node:TX3DNode);
    procedure CollectChunkTexture(Node:TX3DNode);
    procedure QueueChunks(Root:TX3DRootNode;Parent:TCastleScene);
    procedure PrepareModelShape(Node:TX3DNode);
  public
    constructor Create;
    procedure Build(World:TDreamWorld;Cancel:TThread);
    procedure AttachTo(Parent:TCastleTransform;Preview:Boolean);
    procedure Detach;
    procedure PrepareGL(Viewport:TCastleViewport);
    procedure RecordRender(Ms:QWord);
    function Ready:Boolean;
    function CoastalSky:TCastleBackground;
    destructor Destroy;override;
    procedure Update(Seconds:Single);
    procedure AppendShadowCasters(List:TCastleTransformList);
    procedure AppendReflectionSurfaces(List:TCastleTransformList);
    function Diagnostics:TJSONObject;
  end;
  { The loader hands over its prepared visual. Preview -> ride moves the same
    scene (including GPU resources), never reparses GLB or rebuilds the ground. }
  TDreamVisualTask = class(TDreamWorldTask)
  private
    FVisual:TDreamWorldVisual;
    FBuildingWorld:TDreamWorld;
  protected
    function LoadWorld:TDreamWorld;override;
  public
    constructor Create(const FileName:string);
    destructor Destroy;override;
    function TakeVisual:TDreamWorldVisual;
  end;
implementation
uses SysUtils,Math,Generics.Collections,CastleVectors,CastleRenderOptions,CastleURIUtils,CastleImages,X3DLoad,X3DFields,CastleInternalRenderer,
  Osm3dTileX3D,Osm3dSceneAssembler,Osm3dRiderShadow,Osm3dGeomMesh,
  Osm3dGroundComposite,Osm3dRoadSurfaceBinding,Osm3dGeomVegetation,Osm3dStudioSettings,Osm3dImageCodecLock,GameCoastalSky,
  Osm3dBuildingComposite,Osm3dFenceComposite;

var NextVisualSerial:Integer;
type
  TThreadAccess=class(TThread);
  TTextureBinding=class
    Node:TImageTextureNode;
    Image:TCastleImage;
    Url:string;
    destructor Destroy;override;
  end;
destructor TTextureBinding.Destroy;
begin Image.Free;inherited;end;
procedure TDreamWorldVisual.CheckCancelled;
begin
  if (FCancel<>nil) and TThreadAccess(FCancel).Terminated then
    raise EAbort.Create('World loading cancelled');
end;
procedure TDreamWorldVisual.PreloadTexture(Node:TX3DNode);
var Tex:TImageTextureNode;Img:TCastleImage;Url:string;Binding:TTextureBinding;
begin
  CheckCancelled;Tex:=TImageTextureNode(Node);
  if Tex.IsTextureLoaded or (Tex.FdUrl.Count=0) then Exit;
  { Detached nodes only. Decode locally rather than entering CGE's global,
    unsynchronised X3D image cache from the worker. Keep URL for GPU dedup. }
  Url:=Tex.PathFromBaseUrl(Tex.FdUrl.Items[0]);
  EnterImageCodec;
  try Img:=LoadImage(Url);finally LeaveImageCodec;end;
  if Tex.FlipVertically then Img.FlipVertical;
  if Tex.Scene<>nil then begin
    { Sky already has a private CGE scene. Decode on CPU, publish its node
      fields on main to avoid invoking scene/GL notifications in this worker. }
    Binding:=TTextureBinding.Create;Binding.Node:=Tex;Binding.Image:=Img;Binding.Url:=Url;FTextureBindings.Add(Binding);
  end else Tex.LoadFromImage(Img,True,Url);
end;
procedure TDreamWorldVisual.CollectChunkTexture(Node:TX3DNode);
begin
  if ((Node is TImageTextureNode)or(Node is TPixelTextureNode))and
    (FChunkTextures.IndexOf(Node)<0)then FChunkTextures.Add(Node);
end;
constructor TDreamVisualTask.Create(const FileName:string);
begin
  inherited Create(FileName);FVisual:=TDreamWorldVisual.Create;
end;
function TDreamVisualTask.LoadWorld:TDreamWorld;
begin
  FBuildingWorld:=inherited LoadWorld;
  { Failed/cancelled CGE objects must also be destroyed on main. Even a
    never-rendered Scene destructor closes GL resources/state. Keep ownership
    in the job until the UI reaps it; never use a throwing constructor here. }
  FVisual.Build(FBuildingWorld,Self);
  Result:=FBuildingWorld;FBuildingWorld:=nil;
end;
destructor TDreamVisualTask.Destroy;
begin
  JoinWithoutEvents;FreeAndNil(FVisual);FreeAndNil(FBuildingWorld);inherited;
end;
function TDreamVisualTask.TakeVisual:TDreamWorldVisual;
begin
  if not Done then Exit(nil);Result:=FVisual;FVisual:=nil;
end;

procedure AttachShadow(App:TAppearanceNode;const Material:TDreamMaterial);
var Shadow:TRiderShadowGroundEffect;P:TEffectPartNode;
begin
  Shadow:=TRiderShadowGroundEffect.Create;Shadow.Language:=slGLSL;
  App.FdEffects.Add(Shadow);
  Shadow.SetShaderLibraries(['castle-shader:/EyeWorldSpace.glsl']);
  Shadow.AddCustomField(TSFVec3f.Create(Shadow,True,'dream_base',Material.Color));
  Shadow.AddCustomField(TSFFloat.Create(Shadow,True,'dream_metal',Material.Metallic));
  Shadow.AddCustomField(TSFFloat.Create(Shadow,True,'dream_rough',Material.Roughness));
  P:=TEffectPartNode.Create;P.ShaderType:=stFragment;
  P.Contents:=RIDER_SHADOW_GLSL+#10+
    'vec4 position_eye_to_world_space(vec4 p);'+#10+
    'vec3 direction_eye_to_world_space(vec3 d);'+#10+
    'uniform vec3 dream_base; uniform float dream_metal, dream_rough;'+#10+
    'vec3 dream_normal, dream_view, dream_albedo;'+#10+
    'void PLUG_main_texture_apply(inout vec4 color,const vec3 normal) {'+#10+
    ' dream_albedo=color.rgb;'+#10+'}'+#10+
    'void PLUG_fragment_eye_space(const vec4 p,inout vec3 n) {'+#10+
    ' dream_normal=normalize(direction_eye_to_world_space(n));'+#10+
    ' dream_view=normalize(direction_eye_to_world_space(-p.xyz));'+#10+
    ' gc_riderPosition=position_eye_to_world_space(p).xyz;'+#10+
    ' gc_riderRelativePosition=position_eye_to_world_space(vec4(p.xyz,0.0)).xyz;'+#10+'}'+#10+
    { Analytical outdoor environment: diffuse sky/ground irradiance plus a
      broad reflection for metals. PBR ignores light AmbientIntensity; extra
      directional lights alone leave directions and metal reflections black.
      Evaluated in world space, independent of camera rotation and still
      attenuated by the shared shadow receiver in fragment_modify. }
    'void PLUG_material_occlusion(inout vec4 color) {'+#10+
    ' vec3 sky=vec3(0.20,0.24,0.30), ground=vec3(0.095,0.085,0.065);'+#10+
    ' vec3 diffuse=mix(ground,sky,dream_normal.y*0.5+0.5);'+#10+
    ' vec3 reflected=reflect(-dream_view,dream_normal);'+#10+
    ' float h=mix(smoothstep(-0.3,0.6,reflected.y),0.5,dream_rough*dream_rough);'+#10+
    ' vec3 environment=mix(ground,sky,h);'+#10+
    ' color.rgb+=dream_albedo*diffuse*(1.0-dream_metal)'+#10+
    '   +mix(vec3(0.04),dream_albedo,dream_metal)*environment;'+#10+'}';
  Shadow.SetParts([P]);Shadow.SetGroundFragment(P);
end;

function GrassCopy(Source:TMesh;const Offset:TVector3):TMesh;
var I:Integer;V:TMeshVertexArray;Idx:TMeshIndexArray;P:TMeshVertex;
begin
  Result:=TMesh.Create('dream_grass');V:=Source.Vertices;Idx:=Source.Indices;
  for I:=0 to High(V)do begin P:=V[I];P.Position:=P.Position+Offset;Result.AddVertex(P);end;
  for I:=0 to Source.TriangleCount-1 do Result.AddTriangle(Idx[I*3],Idx[I*3+1],Idx[I*3+2]);
end;

procedure TDreamWorldVisual.PrepareModelShape(Node:TX3DNode);
var App:TAppearanceNode;Mat:TPhysicalMaterialNode;M:TDreamMaterial;
begin
  if not(Node is TShapeNode)then Exit;
  if not(TShapeNode(Node).Appearance is TAppearanceNode)then Exit;
  App:=TAppearanceNode(TShapeNode(Node).Appearance);
  if not(App.Material is TPhysicalMaterialNode)then Exit;
  Mat:=TPhysicalMaterialNode(App.Material);M:=Default(TDreamMaterial);
  M.Color:=Mat.BaseColor;M.Roughness:=Mat.Roughness;M.Metallic:=Mat.Metallic;
  { Transparent lantern panes receive light but should not make an opaque
    silhouette. Opaque imported meshes join the same caster contract as tiles. }
  if App.ShadowCaster and (Mat.Transparency < 0.5) then
    MarkWorldShadowCaster(TShapeNode(Node));
  AttachShadow(App,M);
end;

procedure AddVegetationCells(Renderer:TInstancedBillboardRenderer;const Instances:TTreeInstanceArray;Cull:Single);
type TCells=specialize TDictionary<Int64,TTreeInstanceArray>;
var Cells:TCells;Pair:specialize TPair<Int64,TTreeInstanceArray>;A:TTreeInstanceArray;
    I,X,Z,N:Integer;Key:Int64;
begin
  Cells:=TCells.Create;
  try
    for I:=0 to High(Instances)do begin
      X:=Floor(Instances[I].X/128);Z:=Floor(Instances[I].Z/128);
      Key:=(Int64(X) shl 32)or Int64(LongWord(Z));
      if not Cells.TryGetValue(Key,A)then A:=nil;
      N:=Length(A);SetLength(A,N+1);A[N]:=Instances[I];Cells.AddOrSetValue(Key,A);
    end;
    for Pair in Cells do begin
      A:=Pair.Value;X:=Floor(A[0].X/128);Z:=Floor(A[0].Z/128);
      Renderer.AddTile(A,(X+0.5)*128,(Z+0.5)*128,Cull);
    end;
  finally Cells.Free;end;
end;

procedure TDreamWorldVisual.QueueChunks(Root:TX3DRootNode;Parent:TCastleScene);
var I:Integer;Group,Wrapper:TTransformNode;Node:TAbstractChildNode;ChunkRoot:TX3DRootNode;
  procedure MountNode(Source:TAbstractGroupingNode;Child:TAbstractChildNode;const Offset:TVector3);
  begin
    CheckCancelled;ChunkRoot:=TX3DRootNode.Create;
    Wrapper:=TTransformNode.Create;Wrapper.Translation:=Offset;ChunkRoot.AddChildren(Wrapper);
    Child.KeepExistingBegin;
    Source.RemoveChildren(Child);Wrapper.AddChildren(Child);Child.KeepExistingEnd;
    FChunks.Add(nil);FChunkRoots.Add(ChunkRoot);FChunkParents.Add(Parent);ChunkRoot.X3DName:=Child.X3DName;
  end;
begin
  for I:=Root.FdChildren.Count-1 downto 0 do begin
    if not(Root.FdChildren[I] is TTransformNode)then Continue;
    Group:=TTransformNode(Root.FdChildren[I]);
    if Group.X3DName='DreamModelInstances' then MountNode(Root,Group,TVector3.Zero)
    else while Group.FdChildren.Count>0 do begin
      Node:=TAbstractChildNode(Group.FdChildren[0]);MountNode(Group,Node,Group.Translation);
    end;
  end;
end;

constructor TDreamWorldVisual.Create;
begin
  inherited Create;Inc(NextVisualSerial);FSerial:=NextVisualSerial;
  FChunks:=TList.Create;FCasterChunks:=TList.Create;FChunkParents:=TList.Create;
  FChunkRoots:=TList.Create;FTextureBindings:=TList.Create;FChunkTextures:=TList.Create;FTimings:=TJSONObject.Create;
  FScene:=TCastleScene.Create(nil);FScene.Exists:=False;FWater:=TWaterCompositeShader.Create;
  FSky:=CreateCoastalSky(nil);
  FGrass:=TGrassRenderer.Create(nil);FScene.Add(FGrass);FGrass.Exists:=False;
  FCasterScene:=TCastleScene.Create(nil);FCasterScene.Exists:=False;FCasterScene.ProcessEvents:=True;
  FCasterScene.Collides:=False;FScene.Add(FCasterScene);
  FTrees:=TCastleAbstractTreeRenderer.Create(nil);FScene.Add(FTrees);FTrees.Exists:=False;
  FShrubs:=TCastleAbstractShrubRenderer.Create(nil);FScene.Add(FShrubs);FShrubs.Exists:=False;
  FTrees.ProceduralAlternative:=True;FShrubs.ProceduralAlternative:=True;
  FProcedural:=TOsmProceduralVegetation.Create(nil);FScene.Add(FProcedural);FProcedural.Exists:=False;
  FScene.Collides:=False;FScene.Pickable:=True;FScene.CastGlobalLights:=True;FScene.ProcessEvents:=True;
  { Same settings as Real World tiles: only the shared atlas casts shadows. }
  FScene.CastShadows:=False;FScene.ReceiveShadowVolumes:=False;
  FCasterScene.CastShadows:=False;FCasterScene.ReceiveShadowVolumes:=False;
end;

procedure TDreamWorldVisual.Build(World:TDreamWorld;Cancel:TThread);
var Root,CasterRoot:TX3DRootNode;Group,CastGroup:TTransformNode;Shape:TShapeNode;App:TAppearanceNode;
  Mat:TPhysicalMaterialNode;R:TTileMeshRec;M:TDreamMaterial;I,J,K,NT,NS:Integer;
  E:TEffectNode;P:TEffectPartNode;A:TFloatVertexAttributeNode;Values:array of Single;
  Builder,CastBuilder,BuildingBuilder,FenceBuilder:TGroundCompositeBuilder;Grass:TMesh;
  SampleComposite:TGroundCompositeMesh;
  GrassMats:array of Integer;TreeArr,ShrubArr:TTreeInstanceArray;Tr:TTileTreeRec;
  ModelRoots:specialize TDictionary<string,TX3DRootNode>;ModelRoot:TX3DRootNode;
  ModelGroups:specialize TDictionary<string,TTransformNode>;ModelGroup:TTransformNode;
  Instance:TTileModelInstance;Placement:TTransformNode;FileName:string;TreeCull,ShrubCull:Single;
  Tick:QWord;ProceduralTrees:TTileTreeRecArray;
  procedure Mark(const Name:string);
  begin FTimings.Add(Name,GetTickCount64-Tick);Tick:=GetTickCount64;end;
  procedure AddGround(B:TGroundCompositeBuilder;Parent:TTransformNode;Casts:Boolean);
  var Comp:TGroundCompositeMesh;S:TShapeNode;Effect:TEffectNode;Part:TEffectPartNode;N:Integer;
  begin
    Comp:=B.Finalize;
    try
      if Comp.TriangleCount=0 then Exit;
      S:=TGroundCompositeShape.CreateShapeTiled(Comp,World.GroundAtlas,World.Sun,
        nil,nil,nil,nil,nil,GROUND_COMPOSITE_VS,GROUND_COMPOSITE_FS,True,True);
      Parent.AddChildren(S);
      if Casts then S.X3DName:='DreamGroundCaster' else S.X3DName:='DreamGround';
      if Casts then MarkWorldShadowCaster(S);
      TAppearanceNode(S.Appearance).ShadowCaster:=Casts;
      { Page priorities use world space; CGE geometry remains tile-local. }
      for N:=0 to Comp.Pool.Count-1 do
        Comp.Pool.SetPosition(N,Comp.Pool.PositionOf(N)+World.Tiles[I].Offset);
      AttachRoadSurface(TIndexedFaceSetNode(S.Geometry),Comp,World.Tiles[I].Model,World.Tiles[I].Offset,1,World.RoadCondition);
      Effect:=TEffectNode.Create;Effect.Language:=slGLSL;
      Part:=TEffectPartNode.Create;Part.ShaderType:=stVertex;Part.Contents:='// Dream ground local origin';Effect.SetParts([Part]);
      Effect.AddCustomField(TSFVec3f.Create(Effect,True,'gc_ground_origin',World.Tiles[I].Offset));
      TAppearanceNode(S.Appearance).FdEffects.Add(Effect);
    finally Comp.Free;end;
  end;
begin
  Tick:=GetTickCount64;FCancel:=Cancel;
  Root:=TX3DRootNode.Create;CasterRoot:=TX3DRootNode.Create;
  ModelRoots:=specialize TDictionary<string,TX3DRootNode>.Create;
  ModelGroups:=specialize TDictionary<string,TTransformNode>.Create;
  try
    CheckCancelled;
    FGrass.SunRayDirection:=-World.Sun;FTrees.SunRayDirection:=-World.Sun;FShrubs.SunRayDirection:=-World.Sun;
    FProcedural.SunRayDirection:=-World.Sun;
    Mark('vegetation_setup_ms');
    for I:=0 to High(World.Tiles)do begin
      CheckCancelled;
      Group:=TTransformNode.Create;Group.Translation:=World.Tiles[I].Offset;Root.AddChildren(Group);
      CastGroup:=TTransformNode.Create;CastGroup.Translation:=World.Tiles[I].Offset;CasterRoot.AddChildren(CastGroup);
      for J:=0 to High(World.Tiles[I].Model.ModelInstances)do begin
        CheckCancelled;Instance:=World.Tiles[I].Model.ModelInstances[J];FileName:=World.ModelFile(I,J);
        Placement:=TTransformNode.Create;Placement.Translation:=Instance.Position+World.Tiles[I].Offset;
        Placement.Rotation:=Instance.Rotation;Placement.Scale:=Instance.Scale;
        if not ModelRoots.TryGetValue(FileName,ModelRoot)then begin
          ModelGroup:=TTransformNode.Create;ModelGroup.X3DName:='DreamModelInstances';
          CasterRoot.AddChildren(ModelGroup);ModelGroups.Add(FileName,ModelGroup);
          ModelRoot:=LoadNode(FilenameToURISafe(FileName));
          Placement.AddChildren(ModelRoot);ModelRoots.Add(FileName,ModelRoot);Inc(FModelFiles);
          ModelRoot.EnumerateNodes(TShapeNode,@PrepareModelShape,False);
        end else begin Placement.AddChildren(ModelRoot);ModelGroup:=ModelGroups[FileName];end;
        ModelGroup.AddChildren(Placement);Inc(FModelInstances);
      end;
      Mark('models_'+IntToStr(I)+'_ms');
      Builder:=TGroundCompositeBuilder.Create;CastBuilder:=TGroundCompositeBuilder.Create;
      BuildingBuilder:=TGroundCompositeBuilder.Create;FenceBuilder:=TGroundCompositeBuilder.Create;
      try
        for J:=0 to World.Tiles[I].Model.MeshCount-1 do begin
          CheckCancelled;R:=World.Tiles[I].Model.Meshes[J];M:=World.Material(R.Name);
          if(M.GrassMaterial>=0)or(M.GrassKind>=0)then begin
            Grass:=GrassCopy(R.Mesh,World.Tiles[I].Offset);
            SetLength(GrassMats,Grass.TriangleCount);
            for K:=0 to High(GrassMats)do
              if M.GrassKind>=0 then GrassMats[K]:=GROUND_MAT_COUNT+M.GrassKind
              else GrassMats[K]:=M.GrassMaterial;
            FGrass.EnqueueTile(Grass,GrassMats,World.Tiles[I].Offset.X+J*0.01,World.Tiles[I].Offset.Z);
          end;
          if M.BuildingMaterial>=0 then begin BuildingBuilder.Append(R.Mesh,M.BuildingMaterial);Continue;end;
          if M.FenceMaterial>=0 then begin FenceBuilder.Append(R.Mesh,M.FenceMaterial);Continue;end;
          if M.GroundMaterial>=0 then begin
            if M.CastShadow then CastBuilder.Append(R.Mesh,M.GroundMaterial)
            else Builder.Append(R.Mesh,M.GroundMaterial);
            Continue;
          end;
          Shape:=TShapeNode.Create;
          if M.CastShadow then begin
            Shape.X3DName:='DreamCaster_'+R.Name;CastGroup.AddChildren(Shape);
          end else begin Shape.X3DName:='DreamSurface_'+R.Name;Group.AddChildren(Shape);end;
          Shape.Geometry:=TMeshToX3D.CreateGeometry(R.Mesh,R.Solid);
          Mat:=TPhysicalMaterialNode.Create;Mat.BaseColor:=M.Color;
          Mat.Roughness:=M.Roughness;Mat.Metallic:=M.Metallic;
          App:=TAppearanceNode.Create;App.Material:=Mat;App.ShadowCaster:=M.CastShadow;
          Shape.Appearance:=App;
          if M.Water then begin
            FWater.ApplyToShape(Shape);
            SetLength(Values,R.Mesh.VertexCount);
            SetLength(R.MatIds,R.Mesh.VertexCount);SetLength(R.WaterScale,R.Mesh.VertexCount);
            for K:=0 to High(Values)do begin
              Values[K]:=20;R.MatIds[K]:=20;
              if M.WaterScale>=0 then R.WaterScale[K]:=M.WaterScale
              else if R.Name='ocean'then R.WaterScale[K]:=1 else R.WaterScale[K]:=0.015;
            end;
            A:=TFloatVertexAttributeNode.Create;A.NameField:='materialId';A.NumComponents:=1;A.SetValue(Values);
            TIndexedFaceSetNode(Shape.Geometry).FdAttrib.Add(A);
            AttachWaterScale(Shape,R,R.Mesh.VertexCount,World.Tiles[I].Offset.X,World.Tiles[I].Offset.Z,1);
            E:=TEffectNode.Create;E.Language:=slGLSL;
            P:=TEffectPartNode.Create;P.ShaderType:=stFragment;P.Contents:='// Dream World sunlight';E.SetParts([P]);
            E.AddCustomField(TSFVec3f.Create(E,True,'gc_SunDirToward',World.Sun));App.FdEffects.Add(E);
          end else AttachShadow(App,M);
        end;
        AddGround(Builder,Group,False);
        AddGround(CastBuilder,CastGroup,True);
        SampleComposite:=BuildingBuilder.Finalize;
        try
          if SampleComposite.TriangleCount>0 then begin
            Shape:=BuildBuildingCompositeShape(SampleComposite,World.BuildingAtlas,World.Sun);
            CastGroup.AddChildren(Shape);MarkWorldShadowCaster(Shape);
          end;
        finally SampleComposite.Free;end;
        SampleComposite:=FenceBuilder.Finalize;
        try
          if SampleComposite.TriangleCount>0 then begin
            Shape:=BuildFenceCompositeShape(SampleComposite,World.FenceAtlas,World.Sun);
            CastGroup.AddChildren(Shape);MarkWorldShadowCaster(Shape);
          end;
        finally SampleComposite.Free;end;
      finally FenceBuilder.Free;BuildingBuilder.Free;CastBuilder.Free;Builder.Free;end;
      Mark('geometry_'+IntToStr(I)+'_ms');
      SetLength(TreeArr,World.Tiles[I].Model.TreeCount);SetLength(ShrubArr,Length(TreeArr));NT:=0;NS:=0;
      SetLength(ProceduralTrees,World.Tiles[I].Model.TreeCount);
      for J:=0 to World.Tiles[I].Model.TreeCount-1 do begin
        Tr:=World.Tiles[I].Model.Trees[J];
        Tr.X:=Tr.X+World.Tiles[I].Offset.X;Tr.Y:=Tr.Y+World.Tiles[I].Offset.Y;Tr.Z:=Tr.Z+World.Tiles[I].Offset.Z;
        ProceduralTrees[J]:=Tr;
        if Tr.IsShrub then begin
          ShrubArr[NS].X:=Tr.X;ShrubArr[NS].Y:=Tr.Y;ShrubArr[NS].Z:=Tr.Z;
          ShrubArr[NS].Scale:=Tr.Scale;ShrubArr[NS].Rotation:=Tr.Rotation;ShrubArr[NS].SeedAsTexId:=Tr.Seed;Inc(NS);
        end else begin
          TreeArr[NT].X:=Tr.X;TreeArr[NT].Y:=Tr.Y;TreeArr[NT].Z:=Tr.Z;
          TreeArr[NT].Scale:=Tr.Scale;TreeArr[NT].Rotation:=Tr.Rotation;TreeArr[NT].SeedAsTexId:=Tr.Seed;Inc(NT);
        end;
      end;
      SetLength(TreeArr,NT);SetLength(ShrubArr,NS);
      TreeCull:=GlobalLODConfig.TreesFarMeters;ShrubCull:=GlobalLODConfig.ShrubsFarMeters;

      if NT>0 then AddVegetationCells(FTrees,TreeArr,TreeCull);
      if NS>0 then AddVegetationCells(FShrubs,ShrubArr,ShrubCull);
      FProcedural.AddTile(ProceduralTrees,World.Tiles[I].Offset.X,World.Tiles[I].Offset.Z,nil);
    end;
    Mark('vegetation_ms');
    AddSceneLights(Root,-World.Sun,False);
    FCoastal:=World.Coastal;
    if FCoastal then FSky.InternalBackgroundRenderer.InternalRootNode.EnumerateNodes(TImageTextureNode,@PreloadTexture,False);
    Root.EnumerateNodes(TImageTextureNode,@PreloadTexture,False);
    CasterRoot.EnumerateNodes(TImageTextureNode,@PreloadTexture,False);
    Mark('texture_decode_ms');CheckCancelled;
    { Establish the atlas before ground shaders are first compiled. }
    QueueChunks(CasterRoot,FCasterScene);QueueChunks(Root,FScene);
    FSurfaceRoot:=Root;Root:=nil;
    FStaticCasterRoot:=CasterRoot;CasterRoot:=nil;Mark('scene_load_ms');FCancel:=nil;
  finally ModelGroups.Free;ModelRoots.Free;CasterRoot.Free;Root.Free;end;
end;

destructor TDreamWorldVisual.Destroy;
var I:Integer;
begin
  Detach;
  if FScene<>nil then begin
    if FGrass<>nil then FScene.Remove(FGrass);
    if FTrees<>nil then FScene.Remove(FTrees);
    if FShrubs<>nil then FScene.Remove(FShrubs);
    if FProcedural<>nil then FScene.Remove(FProcedural);
    if FCasterScene<>nil then FScene.Remove(FCasterScene);
  end;
  if FChunks<>nil then for I:=FChunks.Count-1 downto 0 do TObject(FChunks[I]).Free;
  if FChunkRoots<>nil then for I:=0 to FChunkRoots.Count-1 do TObject(FChunkRoots[I]).Free;
  if FTextureBindings<>nil then for I:=0 to FTextureBindings.Count-1 do TObject(FTextureBindings[I]).Free;
  FChunkTextures.Free;FTextureBindings.Free;FSurfaceRoot.Free;FStaticCasterRoot.Free;FChunkRoots.Free;
  FChunkParents.Free;FCasterChunks.Free;FChunks.Free;FGrass.Free;FTrees.Free;FShrubs.Free;FProcedural.Free;FCasterScene.Free;
  FreeAndNil(FScene);FreeAndNil(FSky);
  if FWater<>nil then begin FWater.Clear;FWater.Free;end;
  FTimings.Free;inherited;
end;
procedure TDreamWorldVisual.Detach;
begin
  if FParent<>nil then FParent.Remove(FScene);FParent:=nil;
end;
procedure TDreamWorldVisual.AttachTo(Parent:TCastleTransform;Preview:Boolean);
begin
  Detach;FParent:=Parent;FParent.Add(FScene);FScene.Exists:=True;FCasterScene.Exists:=True;
  if Preview then begin FTrees.CullDistance:=0;FShrubs.CullDistance:=0;end
  else begin
    FTrees.CullDistance:=GlobalLODConfig.TreesFarMeters;
    FShrubs.CullDistance:=GlobalLODConfig.ShrubsFarMeters;
  end;
end;
function TDreamWorldVisual.CoastalSky:TCastleBackground;
begin if FCoastal and(FGLStage>1)then Result:=FSky else Result:=nil;end;
function TDreamWorldVisual.Ready:Boolean;
begin Result:=FGLReady;end;
procedure TDreamWorldVisual.PrepareGL(Viewport:TCastleViewport);
var Tick:QWord;I:Integer;Binding:TTextureBinding;Chunk:TCastleScene;ChunkRoot:TX3DRootNode;
begin
  if FGLReady then Exit;Tick:=GetTickCount64;
  { Called once per rendered frame, not Update: a newly visible chunk must
    actually render before the next one can be published. GL stays on main. }
  case FGLStage of
    0:begin
      FScene.Load(FSurfaceRoot,True);FSurfaceRoot:=nil;
      FCasterScene.Load(FStaticCasterRoot,True);FStaticCasterRoot:=nil;
      for I:=0 to FTextureBindings.Count-1 do begin
        Binding:=TTextureBinding(FTextureBindings[I]);Binding.Node.LoadFromImage(Binding.Image,True,Binding.Url);Binding.Image:=nil;Binding.Free;
      end;
      FTextureBindings.Clear;
      if not ProceduralVegetationActive and not TCastleAbstractTreeRenderer.AreSharedTexturesLoaded then
        TCastleAbstractTreeRenderer.LoadSharedTextures(URIToFilenameSafe('castle-data:/Osm3d/resources/models/tree/'));
    end;
    1:begin
      if FCoastal and not FSky.InternalBackgroundRenderer.PrepareTexturesStep(FSkyStep)then Exit;
      if not ProceduralVegetationActive and not TCastleAbstractShrubRenderer.AreSharedTexturesLoaded then
        TCastleAbstractShrubRenderer.LoadSharedTextures(URIToFilenameSafe('castle-data:/Osm3d/resources/models/shrubbery/'));
    end;
    2:begin
      if FUploaded<FChunks.Count then begin
        Chunk:=TCastleScene(FChunks[FUploaded]);
        if Chunk=nil then begin
          Chunk:=TCastleScene.Create(nil);FChunks[FUploaded]:=Chunk;Chunk.Exists:=False;
          Chunk.Collides:=False;Chunk.CastShadows:=False;Chunk.ReceiveShadowVolumes:=False;
          ChunkRoot:=TX3DRootNode(FChunkRoots[FUploaded]);FChunkRoots[FUploaded]:=nil;
          Chunk.Load(ChunkRoot,True);
          FChunkTextures.Clear;FTextureStep:=0;
          Chunk.RootNode.EnumerateNodes(TAbstractTextureNode,@CollectChunkTexture,False);
          { Not mounted yet. Allow the main-thread atlas registry to bind the
            final shader variant before texture preparation on the next frame. }
          Chunk.Exists:=True;FChunkPrimed:=False;Exit;
        end;
        if FTextureStep<FChunkTextures.Count then begin
          { Use CGE's existing texture cache, one image per frame. Scene
            preparation below reuses these resources; nodes own their lifetime. }
          TTextureResources.Prepare(Chunk.RenderOptions,TAbstractTextureNode(FChunkTextures[FTextureStep]));
          Inc(FTextureStep);Exit;
        end;
        if not FChunkPrimed then begin
          Viewport.PrepareResources(Chunk,[]);FChunkPrimed:=True;Exit;
        end;
        TCastleScene(FChunkParents[FUploaded]).Add(Chunk);
        if FChunkParents[FUploaded]=Pointer(FCasterScene) then FCasterChunks.Add(Chunk);
        Chunk.Exists:=True;Inc(FUploaded);Exit;
      end;
      FTrees.Exists:=True;
      FProcedural.Exists:=True;
    end;
    3:FShrubs.Exists:=True;
    4:FGrass.Exists:=True;
    5:FGLReady:=True;
  end;
  FTimings.Add('gl_step_'+IntToStr(FGLStage)+'_ms',GetTickCount64-Tick);
  Inc(FGLStage);
end;
procedure TDreamWorldVisual.RecordRender(Ms:QWord);
begin
  if Ms<=FMaxDrawMs then Exit;FMaxDrawMs:=Ms;
  FMaxDrawChunk:='stage '+IntToStr(FGLStage)+' chunk '+IntToStr(FUploaded);
  if FUploaded>0 then FMaxDrawChunk:=FMaxDrawChunk+' '+TCastleScene(FChunks[FUploaded-1]).RootNode.X3DName;
end;
procedure TDreamWorldVisual.Update(Seconds:Single);
begin FWater.Tick(Seconds);end;
procedure TDreamWorldVisual.AppendShadowCasters(List:TCastleTransformList);
var I:Integer;
begin
  for I:=0 to FCasterChunks.Count-1 do
    if TCastleScene(FCasterChunks[I]).Exists then List.Add(TCastleScene(FCasterChunks[I]));
  if FTrees.Exists then List.Add(FTrees);if FShrubs.Exists then List.Add(FShrubs);
  if FProcedural.Exists then List.Add(FProcedural);
end;
procedure TDreamWorldVisual.AppendReflectionSurfaces(List:TCastleTransformList);
var I:Integer;Chunk:TCastleScene;
begin
  for I:=0 to FChunks.Count-1 do begin
    Chunk:=TCastleScene(FChunks[I]);
    if (Chunk<>nil) and Chunk.Exists and (List.IndexOf(Chunk)<0) then List.Add(Chunk);
  end;
end;
function TDreamWorldVisual.Diagnostics:TJSONObject;
begin Result:=TJSONObject.Create(['visual_id',FSerial,'grass',FGrass.DiagString,'tree_tiles',FTrees.TileCount,'shrub_tiles',FShrubs.TileCount,
  'model_files',FModelFiles,'model_instances',FModelInstances,'chunks',FChunks.Count,'uploaded',FUploaded,'ready',Ready,'max_draw_ms',Int64(FMaxDrawMs),'max_draw_chunk',FMaxDrawChunk]);Result.Add('load_timings',FTimings.Clone);end;
end.
