program WaterRoadPriorityTests;
{$mode objfpc}{$H+}
uses SysUtils, Math, CastleVectors, Osm3dGeoMath, Osm3dGeoTileGrid,
  Osm3dHeightmap, Osm3dOsmData, Osm3dWaterLevel, Osm3dGeomTerrain,
  Osm3dGeomSurface, Osm3dGeomBridges, Osm3dGeomMesh, Osm3dFitHeightLayer,
  Osm3dChunk, Osm3dGeomBuilder, Osm3dStudioSettings, Osm3dSceneAssembler,
  Osm3dGeomVegetation, Osm3dGroundComposite;

procedure Check(Ok:Boolean;const Msg:string);
begin if not Ok then raise Exception.Create(Msg) end;
procedure Near(A,B:Double;const Msg:string);
begin Check(Abs(A-B)<0.03,Format('%s: %.4f expected %.4f',[Msg,A,B])) end;

procedure TestCrossing(const WaterKind,RoadTag,WaterTag:string;NodeFord,Protect:Boolean);
var Grid:TGeoTileGrid;HM:THeightmap;DS:TOSMDataset;Proj:TLocalProjection;
  Id:TGeoTileId;Box:TLatLonBox;Road,Water:TOSMWay;Levels:TWaterLevelField;
  Mask:TBridgeSpanMask;Sampler:TTerrainSampler;Terrain,WaterMesh:TMesh;
  Fit:TFitHeightLayer;Pts:TFitLayerPointArray;
  X,Z,I,Checked:Integer;P:TVector3;Expected,Last,Value:Single;
  Protected,Underground:Boolean;
  procedure AddNode(N:Int64;NX,NZ:Single);
  begin DS.AddNode(TOSMNode.Create(N,Proj.Unproject(NX,NZ))) end;
begin
  Grid:=TGeoTileGrid.Create(15,256,55.75);
  Id:=Grid.TileAt(TLatLon.Make(55.75,37.6));Box:=Grid.TileBox(Id);
  Proj:=TLocalProjection.Create(Box.Center);
  HM:=THeightmap.Create(256,256,Box);DS:=TOSMDataset.Create;
  Levels:=nil;Sampler:=nil;Terrain:=nil;Fit:=nil;WaterMesh:=nil;
  try
    for Z:=0 to 255 do for X:=0 to 255 do HM[X,Z]:=20;
    AddNode(1,-120,0);AddNode(2,0,0);AddNode(3,120,0);
    AddNode(4,0,-120);AddNode(5,0,120);
    Road:=TOSMWay.Create(10);Road.NodeRefs:=[1,2,3];
    Road.Tags.Add('highway','trunk');Road.Tags.Add('width','12');
    if RoadTag<>'' then Road.Tags.Add(RoadTag,'yes');
    if NodeFord then DS.FindNode(2).Tags.Add('ford','yes');
    DS.AddWay(Road);
    Water:=TOSMWay.Create(11);Water.NodeRefs:=[4,2,5];
    Water.Tags.Add('waterway',WaterKind);Water.Tags.Add('width','3');
    if WaterTag<>'' then Water.Tags.Add('tunnel',WaterTag);
    DS.AddWay(Water);
    Levels:=TWaterLevelField.Create(HM,DS,Proj,15,nil,Protect);
    Mask:=TBridgeBuilder.CollectSpanMask(DS,Proj);
    Underground:=(WaterTag='culvert');
    Protected:=Protect and (RoadTag='') and not NodeFord and (WaterKind<>'river');
    if Protected or Underground then Expected:=100 else Expected:=20;
    Near(Levels.Apply(0,0,100),Expected,'crossing water priority');
    if Underground then begin
      Check(Length(Mask)=0,'culvert must not erase FIT road height');
      WaterMesh:=TWaterBuilder.BuildAll(DS,HM,Proj,nil,nil);
      Check(WaterMesh.TriangleCount=0,'buried culvert must not appear on surface');
    end else begin
      Near(Levels.Apply(0,30,100),20,'stream preserved outside road');
      if RoadTag<>'tunnel' then
        Check(BridgeMaskContains(Mask,0,0,Levels)<>Protected,'FIT mask road priority');
    end;
    if Protected and not Underground then begin
      Near(Levels.Apply(0,5.99,100),100,'explicit road width, entire pavement');
      Last:=100;
      for I:=0 to 120 do begin
        Value:=Levels.Apply(0,I*0.1,100);
        Check(Value<=Last+0.001,'bank blend must be monotone');
        Check(Abs(Value-Last)<3.1,'bank blend continuity');Last:=Value;
      end;
      Near(Last,20,'stream resumes beyond shoulder');
      Fit:=TFitHeightLayer.Create;SetLength(Pts,49);
      for I:=0 to High(Pts) do begin Pts[I].X:=-120+I*5;Pts[I].Z:=0;Pts[I].AltCal:=100;Pts[I].Deck:=False end;
      Fit.SetData(Pts,Proj.Origin,'water-road-regression');
      Sampler:=TTerrainSampler.Create(HM,Proj,2,15,1,Fit,Mask,Levels);
      Near(Sampler.SampleAtXZ(Proj,0,0),100,'FIT + sampler crossing');
      Near(Sampler.SampleAtXZCubic(Proj,0,0),100,'FIT + normal sampler crossing');
      Terrain:=TTerrainBuilder.Build(HM,Proj,2,15,1,Fit,Mask,nil,Levels);
      Checked:=0;
      for I:=0 to Terrain.VertexCount-1 do begin
        P:=Terrain.Vertices[I].Position;
        if (Abs(P.X)<3) and (Abs(P.Z)<5.9) then begin
          Near(P.Y,100,'FIT + generated terrain crossing');Inc(Checked);
        end;
      end;
      Check(Checked>0,'terrain crossing vertices tested');
      Writeln('  terrain crossing vertices=',Checked);
    end;
    Writeln('PASS ',WaterKind,' road=',RoadTag,' water=',WaterTag,
      ' node_ford=',NodeFord,' roads=',Protect);
  finally WaterMesh.Free;Terrain.Free;Sampler.Free;Fit.Free;Levels.Free;DS.Free;HM.Free;Proj.Free;Grid.Free end;
end;

procedure TestLake;
var Grid:TGeoTileGrid;Id:TGeoTileId;Box:TLatLonBox;HM:THeightmap;
  DS:TOSMDataset;Proj:TLocalProjection;Way:TOSMWay;Levels:TWaterLevelField;
  I,J:Integer;
begin
  Grid:=TGeoTileGrid.Create(15,256,55.75);Id:=Grid.TileAt(TLatLon.Make(55.75,37.6));Box:=Grid.TileBox(Id);
  Proj:=TLocalProjection.Create(Box.Center);HM:=THeightmap.Create(256,256,Box);DS:=TOSMDataset.Create;
  Levels:=nil;
  try
    for J:=0 to 255 do for I:=0 to 255 do HM[I,J]:=20;
    DS.AddNode(TOSMNode.Create(1,Proj.Unproject(-100,0)));DS.AddNode(TOSMNode.Create(2,Proj.Unproject(100,0)));
    Way:=TOSMWay.Create(10);Way.NodeRefs:=[1,2];Way.Tags.Add('highway','trunk');DS.AddWay(Way);
    DS.AddNode(TOSMNode.Create(3,Proj.Unproject(-30,-30)));DS.AddNode(TOSMNode.Create(4,Proj.Unproject(30,-30)));
    DS.AddNode(TOSMNode.Create(5,Proj.Unproject(30,30)));DS.AddNode(TOSMNode.Create(6,Proj.Unproject(-30,30)));
    Way:=TOSMWay.Create(11);Way.NodeRefs:=[3,4,5,6,3];Way.Tags.Add('natural','water');Way.Tags.Add('water','lake');DS.AddWay(Way);
    Levels:=TWaterLevelField.Create(HM,DS,Proj,15);
    Near(Levels.Apply(0,0,100),20,'lake keeps its level');
    Writeln('PASS lake level preserved');
  finally Levels.Free;DS.Free;HM.Free;Proj.Free;Grid.Free end;
end;

procedure TestComposite(UseFit:Boolean);
var Grid:TGeoTileGrid;Id:TGeoTileId;Box:TLatLonBox;HM:THeightmap;
  DS:TOSMDataset;Proj:TLocalProjection;Way:TOSMWay;Chunk:TOsm3dChunkData;
  Builder:TGeometryBuilder;Settings:TStudioSettings;Scene:TSceneInput;
  Trees:TForestBuildResult;Fit:TFitHeightLayer;Pts:TFitLayerPointArray;
  X,Z,I,Checked,WaterChecked:Integer;P:TVector3;Expected:Single;
begin
  Grid:=TGeoTileGrid.Create(15,256,55.75);Id:=Grid.TileAt(TLatLon.Make(55.75,37.6));Box:=Grid.TileBox(Id);
  Proj:=TLocalProjection.Create(Box.Center);Chunk:=TOsm3dChunkData.Create;
  Builder:=nil;Fit:=nil;Scene:=Default(TSceneInput);
  try
    HM:=THeightmap.Create(256,256,Box);Chunk.SetHeightmap(HM);
    DS:=TOSMDataset.Create;Chunk.SetDataset(DS);
    Chunk.Origin:=Box.Center;Chunk.Box:=Box;Chunk.SessionOrigin:=Box.Center;
    for Z:=0 to 255 do for X:=0 to 255 do HM[X,Z]:=20;
    DS.AddNode(TOSMNode.Create(1,Proj.Unproject(-120,0)));DS.AddNode(TOSMNode.Create(2,Proj.Unproject(120,0)));
    DS.AddNode(TOSMNode.Create(3,Proj.Unproject(0,-120)));DS.AddNode(TOSMNode.Create(4,Proj.Unproject(0,120)));
    Way:=TOSMWay.Create(10);Way.NodeRefs:=[1,2];Way.Tags.Add('highway','trunk');Way.Tags.Add('width','12');DS.AddWay(Way);
    Way:=TOSMWay.Create(11);Way.NodeRefs:=[3,4];Way.Tags.Add('waterway','stream');Way.Tags.Add('width','3');DS.AddWay(Way);
    Settings:=TStudioSettings.Defaults;
    Settings.HeightmapZoom:=15;Settings.TerrainGridStepMeters:=2;Settings.TerrainSubdiv:=1;
    Settings.GenerateBuildings:=False;Settings.GenerateTrees:=False;Settings.GenerateFences:=False;
    Settings.GeneratePOI:=False;Settings.GenerateLabels:=False;Settings.GeneratePlates:=False;
    Settings.GenerateLanduse:=False;Settings.GenerateFarTerrain:=False;Settings.GenerateGroundShadows:=False;
    Settings.GenerateRoads:=True;Settings.GenerateWaterways:=True;Settings.UseGroundComposition:=True;
    Expected:=20;
    if UseFit then begin
      Fit:=TFitHeightLayer.Create;SetLength(Pts,49);
      for I:=0 to High(Pts) do begin Pts[I].X:=-120+I*5;Pts[I].Z:=0;Pts[I].AltCal:=100;Pts[I].Deck:=False end;
      Fit.SetData(Pts,Proj.Origin,'water-road-composite');Expected:=100;
    end;
    Builder:=TGeometryBuilder.Create(Chunk,Settings,nil);Builder.FitLayer:=Fit;
    Check(Builder.Build(Scene,Trees),'full geometry build');
    Check(Scene.GroundComposite<>nil,'ground composite exists');
    Checked:=0;WaterChecked:=0;
    for I:=0 to Scene.GroundComposite.VertexCount-1 do begin
      P:=Scene.GroundComposite.PositionOf(I);
      if (Abs(P.X)<10) and (Abs(P.Z)<5.9) then begin
        Check(Scene.GroundComposite.MatIdOf(I)<>GROUND_MAT_WATER,'water must not paint over road');
        if Scene.GroundComposite.MatIdOf(I)=GROUND_MAT_ROAD_MAJOR then begin
          Check(Abs(P.Y-Expected)<0.2,Format('finished road height %.4f expected %.4f',[P.Y,Expected]));Inc(Checked);
        end;
      end;
      if (Scene.GroundComposite.MatIdOf(I)=GROUND_MAT_WATER) and
         (Abs(P.Z)>30) and (Abs(P.Z)<100) then begin Near(P.Y,20,'water beyond road');Inc(WaterChecked) end;
    end;
    Check(Checked>0,'finished road crossing checked');Check(WaterChecked>0,'water outside crossing checked');
    Writeln('PASS full composite FIT=',UseFit,' road vertices=',Checked,' water vertices=',WaterChecked);
  finally
    Scene.Terrain.Free;Scene.FarTerrain.Free;Scene.WaterRivers.Free;
    Scene.RoadMajor.Free;Scene.RoadSecondary.Free;Scene.RoadMinor.Free;Scene.RoadService.Free;
    Scene.RoadFootway.Free;Scene.RoadCycleway.Free;Scene.RoadRailway.Free;Scene.RoadDirtPath.Free;Scene.RoadSandPath.Free;
    for I:=0 to High(Scene.BuildingWalls) do begin Scene.BuildingWalls[I].Free;Scene.BuildingRoofs[I].Free end;
    for I:=Low(Scene.Fences) to High(Scene.Fences) do Scene.Fences[I].Free;
    Scene.Plates.Free;Scene.RoadFurniture.Free;Scene.Landuse.FreeAll;Scene.POI.Free;Scene.LabelsRoot.Free;
    Scene.GroundComposite.Free;Scene.GroundAtlas.Free;Scene.RoadDistField.Free;
    Builder.Free;Fit.Free;Chunk.Free;Proj.Free;Grid.Free;
  end;
end;

begin
  TestCrossing('stream','','',False,True);
  TestCrossing('ditch','','',False,True);
  TestCrossing('drain','','no',False,True);
  TestCrossing('stream','bridge','',False,True);
  TestCrossing('stream','tunnel','',False,True);
  TestCrossing('stream','ford','',False,True);
  TestCrossing('stream','','',True,True);
  TestCrossing('stream','','culvert',False,True);
  TestCrossing('stream','','',False,False);
  TestCrossing('river','','',False,True);
  TestLake;
  TestComposite(False);
  TestComposite(True);
end.
