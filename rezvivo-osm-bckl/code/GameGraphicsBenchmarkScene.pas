unit GameGraphicsBenchmarkScene;

{$mode objfpc}{$H+}

interface

uses Classes, SysUtils, CastleViewport, CastleScene, CastleVectors,
  Osm3dGroundComposite, Osm3dGeomMesh, Osm3dTileX3D, Osm3dRenderGrass,
  Osm3dRenderInstanced, Osm3dProceduralVegetation, Osm3dRiderShadow,
  Osm3dGpuTimer, GameGraphicsOptions, GameScreenFX, Osm3dImpostorCache,
  Osm3dBuildingComposite, Osm3dWaterShader, GameGraphicsBenchmarkRiders, CastleControls, CastleUIControls, fpjson;

const GraphicsBenchmarkViewCount = 3;

type
  TGraphicsBenchmarkData = class;
  TGraphicsBenchmarkWorker = class;

  { A local, deterministic scene, independent of the selected route and HTTP.
    The controller applies transient graphics globals before ApplyProfile;
    this viewport changes only its own visibility and shadow configuration. }
  TGraphicsBenchmarkScene = class(TOsmImpostorViewport)
  private
    FWorker: TGraphicsBenchmarkWorker;
    FData: TGraphicsBenchmarkData;
    FGround, FCasters: TCastleScene;
    FGrass: TGrassRenderer;
    FTrees: TCastleAbstractTreeRenderer;
    FProcedural: TOsmProceduralVegetation;
    FShadow: TRiderShadowAtlas;
    FRiders: TGraphicsBenchmarkRiders;
    FWater: TWaterCompositeShader;
    FFpsLabel: TCastleLabel;
    FRotate, FAnimate: Boolean;
    FViewIndex: Integer;
    FCameraTime, FSceneTime: Double;
    FFpsTick, FFpsFrames: QWord;
    FFps, FGpuMs: Double;
    FTimer: TAsyncGpuTimer;
    FScreenFX: TScreenFX;
    FValues: TGraphicsValues;
    FSun: TVector3;
    FStage: Integer;
    FError: string;
    FReady: Boolean;
    FReadySince, FLastReadinessCheck, FRenderFrames: QWord;
    FSamples: array[0..127] of Double;
    FSampleRead, FSampleCount: Integer;
    procedure UpdateCamera;
    procedure PrepareStep;
    procedure CheckReadiness;
    procedure BuildScene;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure ApplyProfile(const Values: TGraphicsValues);
    procedure SetViewIndex(Index: Integer);
    procedure RestartSamples;
    function ReadGpuSample(out Ms: Double): Boolean;
    procedure BeforeRender; override;
    procedure Render; override;
    procedure Update(const SecondsPassed: Single; var HandleInput: Boolean); override;
    function Diagnostics:TJSONObject;
    property AnimateScene:Boolean read FAnimate write FAnimate;
    property RotateCamera: Boolean read FRotate write FRotate;
    property SceneFPS: Double read FFps;
    property GpuMs: Double read FGpuMs;
    property Ready: Boolean read FReady;
    property ErrorText: string read FError;
    property RenderFrames: QWord read FRenderFrames;
  end;

  TGraphicsBenchmarkData = class
  public
    Atlas: TGroundAtlas;
    Ground, Road, Water: TMesh;
    Buildings: TGroundCompositeMesh;
    BuildingAtlas: TBuildingAtlas;
    Composite: TGroundCompositeMesh;
    Model: TTileModel;
    Trees: TTileTreeRecArray;
    destructor Destroy; override;
  end;

  { CPU resources only: an abandoned worker can finish and free itself
    without retaining a destroyed viewport or touching a GL context. }
  TGraphicsBenchmarkWorker = class(TThread)
  private
    FLock: TRTLCriticalSection;
    FDone, FAbandoned: Boolean;
    FData: TGraphicsBenchmarkData;
    FError: string;
    procedure CheckCancelled;
    procedure Build;
  protected
    procedure Execute; override;
  public
    constructor Create;
    destructor Destroy; override;
    function Take(out Data: TGraphicsBenchmarkData; out Error: string): Boolean;
    procedure Abandon;
  end;

function ActiveGraphicsBenchmark:TGraphicsBenchmarkScene;

implementation

uses Math, CastleCameras, CastleTransform, CastleColors, CastleURIUtils,
  X3DNodes, Osm3dSceneAssembler, Osm3dRoadSurfaceBinding, Osm3dRoadSurface,
  Osm3dRoadMaterial, Osm3dGeomRoads, Osm3dGeomVegetation, TreeModel,
  Osm3dGeomBuildings, Osm3dWind, X3DFields, CastleRenderOptions, UiTranslations;

const BenchmarkRoadId = -90627001;
var ActiveScene:TGraphicsBenchmarkScene;
function ActiveGraphicsBenchmark:TGraphicsBenchmarkScene;
begin Result:=ActiveScene end;
function TGraphicsBenchmarkScene.Diagnostics:TJSONObject;
var P:TVector3;
begin
  P:=Camera.WorldTranslation;
  Result:=TJSONObject.Create(['ready',FReady,'error',FError,'stage',FStage,
    'fps',FFps,'gpu_ms',FGpuMs,'frames',Int64(FRenderFrames),
    'rotating',FRotate,'animated',FAnimate,'riders',GraphicsBenchmarkRiderCount,
    'buildings',24,'trees',180,'view',FViewIndex]);
  Result.Add('camera',TJSONArray.Create([P.X,P.Y,P.Z]));
end;


destructor TGraphicsBenchmarkData.Destroy;
begin
  Buildings.Free;
  BuildingAtlas.Free;
  Water.Free;
  Composite.Free;
  Ground.Free;
  Road.Free;
  Model.Free;
  Atlas.Free;
  inherited;
end;

constructor TGraphicsBenchmarkWorker.Create;
begin
  inherited Create(True);
  InitCriticalSection(FLock);
end;

destructor TGraphicsBenchmarkWorker.Destroy;
begin
  FData.Free;
  DoneCriticalSection(FLock);
  inherited;
end;

procedure TGraphicsBenchmarkWorker.CheckCancelled;
begin
  if Terminated then raise EAbort.Create('Graphics benchmark cancelled');
end;

procedure AddGroundRectangle(Mesh: TMesh; X0, Z0, X1, Z1: Single;
  RoadUV: Boolean; Y:Single=0);
var A, B, C, D: Integer;
  function Vertex(X, Z: Single): Integer;
  var UV: TVector2;
  begin
    { Match TRoadBuilder: U crosses the carriageway, V follows cumulative
      centreline length. AttachRoadSurface converts both back to metres. }
    if RoadUV then UV := Vector2((X + 4) / 8, (Z + 48) / ROAD_UV_SCALE_Y_ASPHALT)
    else UV := Vector2(X / 4, Z / 4);
    Result := Mesh.AddVertex(Vector3(X, Y, Z), Vector3(0, 1, 0), UV);
  end;
begin
  A := Vertex(X0, Z0); B := Vertex(X0, Z1);
  C := Vertex(X1, Z1); D := Vertex(X1, Z0);
  Mesh.AddQuad(A, B, C, D);
end;

procedure TGraphicsBenchmarkWorker.Build;
var Layout: TGroundAtlasLayout; Builder: TGroundCompositeBuilder;
    X, Z, N, I: Integer; R: TTileRoadSeg; T: TTileTreeRec;
    Species: TTreeSpecies; P: TWallParams; Wall, Roof, Pavement: TMesh;
    BX, BZ, BW, BD: Single;
begin
  FData := TGraphicsBenchmarkData.Create;
  FData.Model := TTileModel.Create;
  FData.Ground := TMesh.Create('benchmark_ground');
  FData.Road := TMesh.Create('benchmark_road');
  FData.Water := TMesh.Create('benchmark_lake');
  FData.Road.CurrentOsmId := BenchmarkRoadId;
  { A 320 m district: urban blocks east, dense mixed forest west, a lake
    at the southern edge. Grass geometry never covers streets or water. }
  for Z := -24 to 59 do
    for X := -40 to 39 do
      if (X < -1) or ((X=1) and (Z>=-2)) then
        AddGroundRectangle(FData.Ground,X*4,Z*4,X*4+4,Z*4+4,False);
  for Z := -24 to 59 do
    AddGroundRectangle(FData.Road,-4,Z*4,4,Z*4+4,True);
  for Z := -24 to -3 do
    for X := 2 to 39 do
      AddGroundRectangle(FData.Water,X*4,Z*4,X*4+4,Z*4+4,False,-0.4);
  R := Default(TTileRoadSeg);
  R.X0:=0;R.Z0:=-96;R.X1:=0;R.Z1:=240;R.Width:=8;R.WayId:=BenchmarkRoadId;
  R.Surface.ForwardLanes:=1;R.Surface.BackwardLanes:=1;
  R.Surface.UVMin:=0;R.Surface.UVMax:=1;R.Surface.UVScale:=ROAD_UV_SCALE_Y_ASPHALT;
  R.Surface.Marked:=1;R.Surface.Asphalt:=ROAD_SURFACE_ASPHALT;R.Surface.Condition:=3;
  FData.Model.AddRoadSeg(R);
  Pavement:=TMesh.Create('benchmark_pavement');
  Builder:=TGroundCompositeBuilder.Create;
  try
    AddGroundRectangle(Pavement,8,-8,160,240,False);
    Builder.Append(FData.Ground,GROUND_MAT_TERRAIN);
    Builder.Append(FData.Road,GROUND_MAT_ROAD_SECOND);
    Builder.Append(Pavement,GROUND_MAT_PAVEMENT);
    FData.Composite:=Builder.Finalize;
  finally Builder.Free;Pavement.Free end;
  CheckCancelled;
  { Use the real wall/window grid builder and merged facade/roof shader. }
  Builder:=TGroundCompositeBuilder.Create('benchmark_buildings',0.999);
  try
    for I:=0 to 23 do begin
      CheckCancelled;
      BX:=13+(I mod 3)*42;BZ:=0+(I div 3)*30;
      BW:=20+(I mod 3)*3;BD:=18+(I mod 2)*3;
      P:=Default(TWallParams);
      P.BaseY:=0;P.FoundationBottomY:=0;P.Levels:=2+(I mod 5);
      P.EaveY:=P.Levels*3;P.LevelHeightM:=3;P.TargetWindowWM:=3;
      SetLength(P.Footprint,4);
      P.Footprint[0]:=Vector3(BX,0,BZ);
      P.Footprint[1]:=Vector3(BX,0,BZ+BD);
      P.Footprint[2]:=Vector3(BX+BW,0,BZ+BD);
      P.Footprint[3]:=Vector3(BX+BW,0,BZ);
      Wall:=TMesh.Create('wall');Roof:=TMesh.Create('roof');
      try
        Wall.CurrentOsmId:=BenchmarkRoadId-I-1;Roof.CurrentOsmId:=Wall.CurrentOsmId;
        TWallsBuilder.BuildWalls(P,Wall);
        AddGroundRectangle(Roof,BX,BZ,BX+BW,BZ+BD,False,P.EaveY);
        Builder.Append(Wall,MaterialIdForBuilding(I mod 6,False));
        Builder.Append(Roof,MaterialIdForBuilding(I mod 6,True));
      finally Wall.Free;Roof.Free end;
    end;
    FData.Buildings:=Builder.Finalize;
  finally Builder.Free end;
  SetLength(FData.Trees,180);
  for N:=0 to High(FData.Trees) do begin
    T:=Default(TTileTreeRec);
    if N<168 then begin
      T.X:=-12-(N mod 12)*11+2.1*Sin(N*2.7);
      T.Z:=-66+(N div 12)*21+3*Cos(N*1.7);
    end else begin T.X:=9;T.Z:=32+(N-168)*17 end;
    { Keep the orbit clear of branches, like a small junction/clearing. }
    if (N<168) and (Sqr(T.X)+Sqr(T.Z-5)<Sqr(25)) then T.X:=T.X-19;
    case N mod 3 of
      0:begin Species:=tsPine;T.Seed:=1 end;
      1:begin Species:=tsBirch;T.Seed:=4 end;
      else begin Species:=tsSpruce;T.Seed:=1 end;
    end;
    T.Scale:=14+(N mod 7);T.Rotation:=N*0.73;
    T.Procedural.TypePlusOne:=PackTreeType(Species)+1;
    FData.Trees[N]:=T;
  end;
  Layout:=DefaultGroundAtlasLayout;Layout.TilePixels:=256;
  FData.Atlas:=TGroundAtlas.Create(Layout);
  FData.Atlas.BuildImage;CheckCancelled;
  FData.Atlas.BuildNormalImage;CheckCancelled;
  FData.Atlas.BuildMaskImage;CheckCancelled;
  Layout:=DefaultBuildingAtlasLayout;Layout.TilePixels:=256;
  FData.BuildingAtlas:=TBuildingAtlas.Create(Layout);
  FData.BuildingAtlas.BuildImage;CheckCancelled;
  FData.BuildingAtlas.BuildNormalImage;CheckCancelled;
  FData.BuildingAtlas.BuildMaskImage;CheckCancelled;
  FData.BuildingAtlas.BuildGlowImage;CheckCancelled;
end;

procedure TGraphicsBenchmarkWorker.Execute;
begin
  try Build;
  except on E: Exception do FError := E.Message; end;
  EnterCriticalSection(FLock);
  try
    if FAbandoned then FreeOnTerminate := True else FDone := True;
  finally LeaveCriticalSection(FLock); end;
end;

function TGraphicsBenchmarkWorker.Take(out Data: TGraphicsBenchmarkData;
  out Error: string): Boolean;
begin
  Data := nil; Error := '';
  EnterCriticalSection(FLock);
  try
    Result := FDone;
    if Result then begin Data := FData; FData := nil; Error := FError; end;
  finally LeaveCriticalSection(FLock); end;
end;

procedure TGraphicsBenchmarkWorker.Abandon;
var Completed: Boolean;
begin
  Terminate;
  EnterCriticalSection(FLock);
  try Completed := FDone; if not Completed then FAbandoned := True;
  finally LeaveCriticalSection(FLock); end;
  if Completed then Free;
end;

constructor TGraphicsBenchmarkScene.Create(AOwner: TComponent);
begin
  inherited;
  FullSize := True;
  AutoCamera := False;
  Items.UseHeadlight := hlOff;
  Camera := TCastleCamera.Create(Self);
  Items.Add(Camera);
  Camera.Perspective.FieldOfView := Pi / 3;
  Camera.ProjectionNear := 0.15;
  Camera.ProjectionFar := 500;
  BackgroundColor := Vector4(0.54, 0.70, 0.81, 1);
  FSun := Vector3(-0.55, 0.75, -0.35).Normalize;
  FGround := TCastleScene.Create(Self);
  FGround.Exists := False;
  FGround.CastShadows := False;
  FGround.ReceiveShadowVolumes := False;
  Items.Add(FGround);
  FCasters := TCastleScene.Create(Self);
  FCasters.Exists := False;
  FCasters.CastShadows := False;
  FCasters.ReceiveShadowVolumes := False;
  Items.Add(FCasters);
  FGrass := TGrassRenderer.Create(Self); FGrass.Exists := False;
  FGrass.SunRayDirection := -FSun; Items.Add(FGrass);
  FTrees := TCastleAbstractTreeRenderer.Create(Self); FTrees.Exists := False;
  FTrees.ProceduralAlternative := True;
  FTrees.SunRayDirection := -FSun; Items.Add(FTrees);
  FProcedural := TOsmProceduralVegetation.Create(Self); FProcedural.Exists := False;
  FProcedural.SunRayDirection := -FSun; Items.Add(FProcedural);
  FShadow := TRiderShadowAtlas.Create;
  FShadow.WorldShadows := True;
  FShadow.WorldCasters.Add(FCasters);
  FShadow.WorldCasters.Add(FGround);
  FShadow.WorldCasters.Add(FTrees);
  FShadow.WorldCasters.Add(FProcedural);
  FTimer := TAsyncGpuTimer.Create;
  FScreenFX := TScreenFX.Create(Self);
  FScreenFX.FogEnabled := False;
  FRiders:=TGraphicsBenchmarkRiders.Create(Self);
  FWater:=TWaterCompositeShader.Create;
  FRotate:=True;FAnimate:=True;ActiveScene:=Self;
  FFpsLabel:=TCastleLabel.Create(Self);
  FFpsLabel.Name:='GraphicsPreviewFPS';FFpsLabel.FontSize:=16;
  FFpsLabel.Color:=White;FFpsLabel.Outline:=2;
  FFpsLabel.Anchor(hpLeft,12);FFpsLabel.Anchor(vpBottom,12);InsertFront(FFpsLabel);
  FValues := GraphicsDefaults;
  FScreenFX.SofteningLevel := FValues[goSoftening];
  SetViewIndex(0);
  FWorker := TGraphicsBenchmarkWorker.Create;
  FWorker.Start;
end;

destructor TGraphicsBenchmarkScene.Destroy;
var Worker: TGraphicsBenchmarkWorker;
begin
  if ActiveScene=Self then ActiveScene:=nil;
  Worker := FWorker; FWorker := nil;
  if Worker <> nil then Worker.Abandon;
  FreeAndNil(FRiders);
  FreeAndNil(FWater);
  FreeAndNil(FScreenFX);
  FreeAndNil(FTimer);
  Rtx:=nil;WorldRoot:=nil;
  FreeAndNil(FShadow);
  { Nodes own the atlas's transferred pixel images. Release the scene first. }
  FreeAndNil(FGround);
  FreeAndNil(FCasters);
  FreeAndNil(FGrass);
  FreeAndNil(FTrees);
  FreeAndNil(FProcedural);
  FreeAndNil(FData);
  inherited;
end;

procedure TGraphicsBenchmarkScene.BuildScene;
var Root: TX3DRootNode; Shape: TShapeNode; I: Integer;
    Mat: TPhysicalMaterialNode; App: TAppearanceNode; Rec:TTileMeshRec;
    TriMat: array of Integer; Trees: TTreeInstanceArray; Values:array of Single;
    Attr:TFloatVertexAttributeNode; E:TEffectNode; Part:TEffectPartNode;
begin
  Root:=TX3DRootNode.Create;
  try
    Shape:=TGroundCompositeShape.CreateShapeTiled(FData.Composite,FData.Atlas,
      FSun,nil,nil,nil,nil,nil,GROUND_COMPOSITE_VS,GROUND_COMPOSITE_FS,True,True);
    Root.AddChildren(Shape);TAppearanceNode(Shape.Appearance).ShadowCaster:=False;
    AttachRoadSurface(TIndexedFaceSetNode(Shape.Geometry),FData.Composite,FData.Model,TVector3.Zero,1,3);
    Shape:=TShapeNode.Create;
    Shape.Geometry:=TMeshToX3D.CreateGeometry(FData.Water,True);
    Mat:=TPhysicalMaterialNode.Create;Mat.BaseColor:=Vector3(0.08,0.28,0.34);Mat.Roughness:=0.18;
    App:=TAppearanceNode.Create;App.Material:=Mat;App.ShadowCaster:=False;Shape.Appearance:=App;
    Root.AddChildren(Shape);FWater.ApplyToShape(Shape);
    Rec:=Default(TTileMeshRec);
    SetLength(Rec.MatIds,FData.Water.VertexCount);SetLength(Rec.WaterScale,Length(Rec.MatIds));
    SetLength(Values,Length(Rec.MatIds));
    for I:=0 to High(Values) do begin Values[I]:=20;Rec.MatIds[I]:=20;Rec.WaterScale[I]:=0.08 end;
    Attr:=TFloatVertexAttributeNode.Create;Attr.NameField:='materialId';Attr.NumComponents:=1;Attr.SetValue(Values);
    TIndexedFaceSetNode(Shape.Geometry).FdAttrib.Add(Attr);
    AttachWaterScale(Shape,Rec,Length(Values),0,0,1);
    E:=TEffectNode.Create;E.Language:=slGLSL;
    Part:=TEffectPartNode.Create;Part.ShaderType:=stFragment;Part.Contents:='// Benchmark sunlight';E.SetParts([Part]);
    E.AddCustomField(TSFVec3f.Create(E,True,'gc_SunDirToward',FSun));App.FdEffects.Add(E);
    AddSceneLights(Root,-FSun,False);FGround.Load(Root,True);Root:=nil;
  finally Root.Free end;
  Root:=TX3DRootNode.Create;
  try
    Shape:=BuildBuildingCompositeShape(FData.Buildings,FData.BuildingAtlas,FSun);
    Root.AddChildren(Shape);MarkWorldShadowCaster(Shape);
    AddSceneLights(Root,-FSun,False);FCasters.Load(Root,True);Root:=nil;
  finally Root.Free end;
  SetLength(TriMat,FData.Ground.TriangleCount);
  for I:=0 to High(TriMat) do TriMat[I]:=GROUND_MAT_TERRAIN;
  FGrass.AddTile(FData.Ground,TriMat,0,64);
  SetLength(Trees,Length(FData.Trees));
  for I:=0 to High(Trees) do begin
    Trees[I].X:=FData.Trees[I].X;Trees[I].Y:=FData.Trees[I].Y;
    Trees[I].Z:=FData.Trees[I].Z;Trees[I].Scale:=FData.Trees[I].Scale;
    Trees[I].Rotation:=FData.Trees[I].Rotation;Trees[I].SeedAsTexId:=FData.Trees[I].Seed;
  end;
  FTrees.AddTile(Trees,0,64,500);FProcedural.AddTile(FData.Trees,0,64,nil);
end;

procedure TGraphicsBenchmarkScene.PrepareStep;
var Data: TGraphicsBenchmarkData; Error: string;
begin
  if FError <> '' then Exit;
  case FStage of
    0: if FWorker.Take(Data, Error) then
      begin
        FreeAndNil(FWorker); FData := Data;
        if Error <> '' then begin FError := Error; Exit; end;
        BuildScene;
        Inc(FStage);
      end;
    1: begin
        FGround.Exists := True;
        PrepareResources(FGround, []);
        Inc(FStage);
      end;
    2: begin
        FCasters.Exists := True;
        PrepareResources(FCasters, []);
        Inc(FStage);
        ApplyProfile(FValues);
      end;
    3:if FRiders.PrepareStep(Self) then Inc(FStage);
  end;
end;

procedure TGraphicsBenchmarkScene.ApplyProfile(const Values: TGraphicsValues);
begin
  FValues := Values;
  FScreenFX.SofteningLevel := Values[goSoftening];
  FShadow.Configure(Values[goShadowSize], Values[goShadowFilter], Values[goShadowDistance]);
  FGrass.Exists := (FStage >= 3) and (Values[goGrass] <> 0);
  FTrees.Exists := FStage >= 3;
  FProcedural.Exists := (FStage >= 3) and (Values[goTrees] <> 0);
  FReady := False; FReadySince := 0; FLastReadinessCheck := 0;
  RestartSamples;
end;

procedure TGraphicsBenchmarkScene.UpdateCamera;
var P, Target:TVector3; A:Single;
begin
  { Identical orbit phase at each timed trial. All three sectors include
    city, forest, water and the same four riders; no random viewpoints. }
  A:=FViewIndex*2*Pi/GraphicsBenchmarkViewCount+FCameraTime*0.11;
  Target:=Vector3(0,1.5,5);
  P:=Target+Vector3(Sin(A)*11,3.2+1.2*Sin(A*0.5),-Cos(A)*11);
  Camera.SetWorldView(P,Target-P,Vector3(0,1,0));
end;

procedure TGraphicsBenchmarkScene.SetViewIndex(Index: Integer);
begin
  FViewIndex:=Index mod GraphicsBenchmarkViewCount;FCameraTime:=0;
  UpdateCamera;
  FReady:=False;FReadySince:=0;FLastReadinessCheck:=0;
  RestartSamples;
end;

procedure TGraphicsBenchmarkScene.RestartSamples;
begin
  if FTimer <> nil then FTimer.Reset;
  FSampleRead := 0; FSampleCount := 0; FRenderFrames := 0;
  FFpsTick:=0;FFpsFrames:=0;
end;

function DiagnosticInteger(const Text, Key: string): Int64;
var P, E: Integer;
begin
  Result := -1;
  P := Pos(Key + '=', Text); if P = 0 then Exit;
  Inc(P, Length(Key) + 1); E := P;
  while (E <= Length(Text)) and (Text[E] in ['0'..'9', '-']) do Inc(E);
  Result := StrToInt64Def(Copy(Text, P, E - P), -1);
end;

function DiagnosticError(const Text: string): string;
var P: Integer;
begin
  P := Pos('error=', Text);
  if P = 0 then Result := '' else Result := Copy(Text, P + 6, MaxInt);
end;

procedure TGraphicsBenchmarkScene.CheckReadiness;
var Tick: QWord; Warm: Boolean; D: string;
begin
  if (FStage < 4) or (FError <> '') then Exit;
  Tick := GetTickCount64;
  if Tick - FLastReadinessCheck < 150 then Exit;
  FLastReadinessCheck := Tick;
  Warm := FRenderFrames >= 6;
  if (FValues[goShadowSize]>0) and FShadow.RtxRequested then
    Warm:=Warm and (FShadow.RtxBackend<>nil) and (FShadow.RtxBackend.Ready or FShadow.RtxBackend.Failed);
  if FGrass.Exists then
  begin
    D := FGrass.DiagString;
    FError := DiagnosticError(D);
    Warm := Warm and (DiagnosticInteger(D, 'patches') > 0);
  end;
  if FProcedural.Exists then
  begin
    D := FProcedural.Diagnostics;
    if FError = '' then FError := DiagnosticError(D);
    Warm := Warm and (DiagnosticInteger(D, 'pending') = 0)
      and (DiagnosticInteger(D, 'waiting') = 0)
      and (DiagnosticInteger(D, 'ready') > 0);
  end;
  if Warm and (FError = '') then
  begin
    if FReadySince = 0 then FReadySince := Tick;
    FReady := Tick - FReadySince >= 600;
  end else begin FReadySince := 0; FReady := False; end;
end;

procedure TGraphicsBenchmarkScene.Update(const SecondsPassed: Single;
  var HandleInput: Boolean);
var Tick:QWord;
begin
  inherited;
  if FStage>=3 then begin
    if FAnimate then begin
      FSceneTime:=FSceneTime+SecondsPassed;
      FRiders.Animate(SecondsPassed);FWater.Tick(SecondsPassed) end;
    if FRotate then begin FCameraTime:=FCameraTime+SecondsPassed;UpdateCamera end;
  end;
  CheckReadiness;
  Tick:=GetTickCount64;
  if Tick-FFpsTick>=750 then begin
    if FFpsTick<>0 then FFps:=(FRenderFrames-FFpsFrames)*1000/Max(QWord(1),Tick-FFpsTick);
    FFpsTick:=Tick;FFpsFrames:=FRenderFrames;
    FFpsLabel.MaxWidth:=Max(100,EffectiveWidth-24);
    if FError<>'' then FFpsLabel.Caption:=UiText('Test scene failed to load.')+#10+FError
    else if not FReady then FFpsLabel.Caption:=UiText('Preparing test scene...')
    else FFpsLabel.Caption:=Format('%.0f FPS  |  GPU %.1f ms',[FFps,FGpuMs]);
  end;
end;

procedure TGraphicsBenchmarkScene.Render;
var Ns: QWord; Slot: Integer; SavedWind:Single;
begin
  if FError <> '' then Exit;
  SavedWind:=WindPlaybackTime;WindSetPlaybackTime(FSceneTime);
  try
  try
    PrepareStep;
    if FError <> '' then Exit;
    if FStage < 3 then begin inherited; Exit; end;
    { Query reads stay on the render thread with its context current. The
      controller consumes only these copied numbers during Update. }
    while FTimer.ReadSample(Ns) do
    begin
      FGpuMs:=Ns/1000000.0;
      if FSampleCount < Length(FSamples) then
      begin
        Slot := (FSampleRead + FSampleCount) mod Length(FSamples);
        FSamples[Slot] := Ns / 1000000.0;
        Inc(FSampleCount);
      end;
    end;
    FTimer.BeginSample;
    try
      RoadMaterialRender(Camera.WorldTranslation);
      FShadow.Casters.Clear;
      FRiders.AddCasters(FShadow.Casters);
      Rtx:=nil;WorldRoot:=Items;
      FShadow.RtxRequested:=FValues[goWorldShadows]<>0;
      FShadow.RtxRasterComparison:=FValues[goWorldShadows]=1;
      FShadow.RtxReflections:=(FValues[goWorldShadows]=2) and (FValues[goRtxReflections]<>0);
      if FValues[goShadowSize] > 0 then begin
        FShadow.Render(Self, Camera.WorldTranslation, -FSun, 0.85);
        Rtx:=FShadow.RtxBackend;
      end
      else HideGroundRiderShadow;
      inherited;
      Inc(FRenderFrames);
    finally FTimer.EndSample; end;
  except on E: Exception do FError := E.ClassName + ': ' + E.Message; end;
  finally WindSetPlaybackTime(SavedWind) end;
end;

procedure TGraphicsBenchmarkScene.BeforeRender;
begin
  if FError <> '' then Exit;
  try inherited;
  except on E: Exception do FError := E.ClassName + ': ' + E.Message; end;
end;

function TGraphicsBenchmarkScene.ReadGpuSample(out Ms: Double): Boolean;
begin
  Result := FSampleCount > 0;
  Ms := 0;
  if not Result then Exit;
  Ms := FSamples[FSampleRead];
  FSampleRead := (FSampleRead + 1) mod Length(FSamples);
  Dec(FSampleCount);
end;

end.
