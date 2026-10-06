unit GameGraphicsBenchmarkScene;

{$mode objfpc}{$H+}

interface

uses Classes, SysUtils, CastleViewport, CastleScene, CastleVectors,
  Osm3dGroundComposite, Osm3dGeomMesh, Osm3dTileX3D, Osm3dRenderGrass,
  Osm3dRenderInstanced, Osm3dProceduralVegetation, Osm3dRiderShadow,
  Osm3dGpuTimer, GameGraphicsOptions, GameScreenFX, Osm3dImpostorCache;

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
    property Ready: Boolean read FReady;
    property ErrorText: string read FError;
    property RenderFrames: QWord read FRenderFrames;
  end;

  TGraphicsBenchmarkData = class
  public
    Atlas: TGroundAtlas;
    Ground, Road: TMesh;
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

implementation

uses Math, CastleCameras, CastleTransform, CastleColors, CastleURIUtils,
  X3DNodes, Osm3dSceneAssembler, Osm3dRoadSurfaceBinding, Osm3dRoadSurface,
  Osm3dRoadMaterial, Osm3dGeomRoads, Osm3dGeomVegetation, TreeModel;

const BenchmarkRoadId = -90627001;

destructor TGraphicsBenchmarkData.Destroy;
begin
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
  RoadUV: Boolean);
var A, B, C, D: Integer;
  function Vertex(X, Z: Single): Integer;
  var UV: TVector2;
  begin
    { Match TRoadBuilder: U crosses the carriageway, V follows cumulative
      centreline length. AttachRoadSurface converts both back to metres. }
    if RoadUV then UV := Vector2((X + 4) / 8, (Z + 48) / ROAD_UV_SCALE_Y_ASPHALT)
    else UV := Vector2(X / 4, Z / 4);
    Result := Mesh.AddVertex(Vector3(X, 0, Z), Vector3(0, 1, 0), UV);
  end;
begin
  A := Vertex(X0, Z0); B := Vertex(X0, Z1);
  C := Vertex(X1, Z1); D := Vertex(X1, Z0);
  Mesh.AddQuad(A, B, C, D);
end;

procedure TGraphicsBenchmarkWorker.Build;
var Layout: TGroundAtlasLayout; Builder: TGroundCompositeBuilder;
    X, Z, N: Integer; R: TTileRoadSeg; T: TTileTreeRec;
    Species: TTreeSpecies;
begin
  FData := TGraphicsBenchmarkData.Create;
  FData.Model := TTileModel.Create;
  FData.Ground := TMesh.Create('benchmark_ground');
  FData.Road := TMesh.Create('benchmark_road');
  FData.Road.CurrentOsmId := BenchmarkRoadId;
  { Four-metre source faces exercise the ordinary grass index without a
    full streamed map. Leave an actual hole for the road, not hidden grass. }
  for Z := -12 to 60 do
    for X := -30 to 29 do
      if (X < -1) or (X >= 1) then
        AddGroundRectangle(FData.Ground, X * 4, Z * 4, X * 4 + 4, Z * 4 + 4, False);
  for Z := -12 to 60 do
    AddGroundRectangle(FData.Road, -4, Z * 4, 4, Z * 4 + 4, True);
  R := Default(TTileRoadSeg);
  R.X0 := 0; R.Z0 := -48; R.X1 := 0; R.Z1 := 244;
  R.Width := 8; R.WayId := BenchmarkRoadId;
  R.Surface.ForwardLanes := 1; R.Surface.BackwardLanes := 1;
  R.Surface.UVMin := 0; R.Surface.UVMax := 1;
  R.Surface.UVScale := ROAD_UV_SCALE_Y_ASPHALT;
  R.Surface.Marked := 1; R.Surface.Asphalt := ROAD_SURFACE_ASPHALT;
  R.Surface.Condition := 3;
  FData.Model.AddRoadSeg(R);
  Builder := TGroundCompositeBuilder.Create;
  try
    Builder.Append(FData.Ground, GROUND_MAT_TERRAIN);
    Builder.Append(FData.Road, GROUND_MAT_ROAD_SECOND);
    FData.Composite := Builder.Finalize;
  finally Builder.Free; end;
  CheckCancelled;
  { Mixed broadleaf/conifers on both sides, extending through the LOD bands.
    Fixed positions are also stable procedural tree identities. }
  SetLength(FData.Trees, 72 + 144);
  N := 0;
  for Z := 0 to 11 do
    for X := 0 to 5 do
    begin
      T := Default(TTileTreeRec);
      if X < 3 then T.X := -13 - X * 24 else T.X := 13 + (X - 3) * 24;
      T.X := T.X + 2.1 * Sin(N * 2.7);
      T.Z := -18 + Z * 21 + 3 * Cos(N * 1.7);
      case N mod 3 of
        0: begin Species := tsPine; T.Seed := 1; end;
        1: begin Species := tsBirch; T.Seed := 4; end;
        else begin Species := tsSpruce; T.Seed := 1; end;
      end;
      T.Scale := 14 + (N mod 5);
      T.Rotation := N * 0.73;
      T.Procedural.TypePlusOne := PackTreeType(Species) + 1;
      FData.Trees[N] := T;
      Inc(N);
    end;
  { A second, denser stretch exercises overlapping conifers and the near
    procedural cache. The first road views alone underestimate forest cost. }
  for Z := 0 to 11 do
    for X := 0 to 11 do
    begin
      T := Default(TTileTreeRec);
      if X < 6 then T.X := -9 - X * 8 else T.X := 9 + (X-6)*8;
      T.X := T.X + 1.7 * Sin(N * 2.7);
      T.Z := 128 + Z * 9 + 2 * Cos(N * 1.7);
      T.Scale := 15 + (N mod 7); T.Rotation := N * 0.73;
      if N mod 3=0 then begin Species:=tsBirch;T.Seed:=4;end
      else if N mod 3=1 then begin Species:=tsSpruce;T.Seed:=1;end
      else begin Species:=tsPine;T.Seed:=1;end;
      T.Procedural.TypePlusOne:=PackTreeType(Species)+1;
      FData.Trees[N]:=T;Inc(N);
    end;
  Layout := DefaultGroundAtlasLayout;
  { Same material data and shader workload; fixed reference texture detail.
    Do not allocate the game's full 8K atlas merely to start Auto. }
  Layout.TilePixels := 256;
  FData.Atlas := TGroundAtlas.Create(Layout);
  FData.Atlas.BuildImage;
  CheckCancelled;
  FData.Atlas.BuildNormalImage;
  CheckCancelled;
  FData.Atlas.BuildMaskImage;
  CheckCancelled;
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
  FValues := GraphicsDefaults;
  FScreenFX.SofteningLevel := FValues[goSoftening];
  SetViewIndex(0);
  FWorker := TGraphicsBenchmarkWorker.Create;
  FWorker.Start;
end;

destructor TGraphicsBenchmarkScene.Destroy;
var Worker: TGraphicsBenchmarkWorker;
begin
  Worker := FWorker; FWorker := nil;
  if Worker <> nil then Worker.Abandon;
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
    Mat: TPhysicalMaterialNode; App: TAppearanceNode;
    Box: TBoxNode; Placement: TTransformNode;
    TriMat: array of Integer; Trees: TTreeInstanceArray;
begin
  Root := TX3DRootNode.Create;
  try
    Shape := TGroundCompositeShape.CreateShapeTiled(FData.Composite, FData.Atlas,
      FSun, nil, nil, nil, nil, nil, GROUND_COMPOSITE_VS, GROUND_COMPOSITE_FS, True, True);
    Root.AddChildren(Shape);
    TAppearanceNode(Shape.Appearance).ShadowCaster := False;
    AttachRoadSurface(TIndexedFaceSetNode(Shape.Geometry), FData.Composite,
      FData.Model, TVector3.Zero, 1, 3);
    AddSceneLights(Root, -FSun, False);
    FGround.Load(Root, True); Root := nil;
  finally Root.Free; end;
  Root := TX3DRootNode.Create;
  try
    for I := 0 to 5 do
    begin
      Placement := TTransformNode.Create;
      Placement.Translation := Vector3(24 + (I mod 2) * 24, 4, 26 + I * 29);
      Shape := TShapeNode.Create;
      Box := TBoxNode.Create; Box.Size := Vector3(10, 8, 14);
      Shape.Geometry := Box;
      App := TAppearanceNode.Create;
      Mat := TPhysicalMaterialNode.Create;
      Mat.BaseColor := Vector3(0.64, 0.57, 0.45); Mat.Roughness := 0.9;
      App.Material := Mat; Shape.Appearance := App;
      MarkWorldShadowCaster(Shape);
      Placement.AddChildren(Shape); Root.AddChildren(Placement);
    end;
    AddSceneLights(Root, -FSun, False);
    FCasters.Load(Root, True); Root := nil;
  finally Root.Free; end;
  SetLength(TriMat, FData.Ground.TriangleCount);
  for I := 0 to High(TriMat) do TriMat[I] := GROUND_MAT_TERRAIN;
  FGrass.AddTile(FData.Ground, TriMat, 0, 96);
  SetLength(Trees, Length(FData.Trees));
  for I := 0 to High(Trees) do
  begin
    Trees[I].X := FData.Trees[I].X; Trees[I].Y := FData.Trees[I].Y;
    Trees[I].Z := FData.Trees[I].Z; Trees[I].Scale := FData.Trees[I].Scale;
    Trees[I].Rotation := FData.Trees[I].Rotation;
    Trees[I].SeedAsTexId := FData.Trees[I].Seed;
  end;
  FTrees.AddTile(Trees, 0, 96, 500);
  FProcedural.AddTile(FData.Trees, 0, 96, nil);
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

procedure TGraphicsBenchmarkScene.SetViewIndex(Index: Integer);
var P, Target: TVector3;
begin
  if Index mod GraphicsBenchmarkViewCount = 2 then
  begin P:=Vector3(0,3.1,144);Target:=Vector3(-9,2.2,212);end
  else if Index mod GraphicsBenchmarkViewCount = 0 then
  begin P := Vector3(-1.5, 3.1, -24); Target := Vector3(1, 1.4, 34); end
  else begin P := Vector3(1.5, 3.4, -21); Target := Vector3(-25, 1.8, 22); end;
  Camera.SetWorldView(P, Target - P, Vector3(0, 1, 0));
  FReady := False; FReadySince := 0; FLastReadinessCheck := 0;
  RestartSamples;
end;

procedure TGraphicsBenchmarkScene.RestartSamples;
begin
  if FTimer <> nil then FTimer.Reset;
  FSampleRead := 0; FSampleCount := 0; FRenderFrames := 0;
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
  if (FStage < 3) or (FError <> '') then Exit;
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
begin
  inherited;
  CheckReadiness;
end;

procedure TGraphicsBenchmarkScene.Render;
var Ns: QWord; Slot: Integer;
begin
  if FError <> '' then Exit;
  try
    PrepareStep;
    if FError <> '' then Exit;
    if FStage < 3 then begin inherited; Exit; end;
    { Query reads stay on the render thread with its context current. The
      controller consumes only these copied numbers during Update. }
    while FTimer.ReadSample(Ns) do
      if FSampleCount < Length(FSamples) then
      begin
        Slot := (FSampleRead + FSampleCount) mod Length(FSamples);
        FSamples[Slot] := Ns / 1000000.0;
        Inc(FSampleCount);
      end;
    FTimer.BeginSample;
    try
      RoadMaterialRender(Camera.WorldTranslation);
      FShadow.Casters.Clear;
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
