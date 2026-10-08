program KnowledgeEnvironmentProbe;
{$mode objfpc}{$H+}
uses Classes,SysUtils,Math,fpjson,CastleVectors,GamePhysicsCommon,
  Osm3dPhotoSources,Osm3dOsmData,Osm3dGeoMath,Osm3dGeoTileGrid,
  Osm3dTileKnowledge,Osm3dKnowledgeRecipe,Osm3dKnowledgeOsm,Osm3dGeoTileCache,Osm3dTileX3D,
  Osm3dHeightmap,Osm3dGeomRoads,Osm3dGeomVegetation,Osm3dGeomMesh,
  Osm3dRoadSurface,Osm3dRouteSnapper,Osm3dMapUtils,Osm3dTileBinary,Osm3dSceneMaterials,
  Osm3dGeomBuildings,Osm3dGeomPOI;
var Extended:Boolean=False;

function Describe(Model:TTileModel):TJSONObject;
var Roads,Trees,Vertices,Samples:TJSONArray; I,H,J:Integer; Seg:TTileRoadSeg; Tree:TTileTreeRec;
  Lane:TLaneManager;
  V:TMeshVertex;Proj:TLocalProjection;Route,Snapped,Centers:TRouteLatLonArray;
  Widths:TRouteWidthArray;SnapSegs:TSnapSegmentArray;T,LocalWidth:Single;
  Buildings,POIs:TJSONArray;Index:TStringList;Row:TJSONObject;Key:string;N:Integer;Poi:TTilePOIRec;
begin
  Roads:=TJSONArray.Create;Trees:=TJSONArray.Create;Vertices:=TJSONArray.Create;
  Result:=TJSONObject.Create(['roads',Roads,'trees',Trees,'road_vertices',Vertices]);Lane:=TLaneManager.Create;
  Proj:=TLocalProjection.Create(Model.Origin);
  try
    H:=Lane.RegisterRider(nil);
    for I:=0 to Model.RoadSegCount-1 do begin
      Seg:=Model.RoadSegs[I];
      LocalWidth:=RoadWidthAt(Seg.Surface,Seg.Width,0.5);Samples:=TJSONArray.Create;
      if Seg.Surface.WidthStart>0 then begin
        SetLength(SnapSegs,1);SetLength(Route,9);
        if TRouteSnapper.MakeSnapSegment(Seg.X0,Seg.Z0,Seg.X1,Seg.Z1,Seg.Width,Seg.WayId,
          SnapSegs[0],False,Seg.Surface.WidthStart,Seg.Surface.WidthEnd) then begin
          for J:=0 to High(Route) do begin
            T:=0.1+J*0.1;Route[J]:=Proj.Unproject(Seg.X0+(Seg.X1-Seg.X0)*T,Seg.Z0+(Seg.Z1-Seg.Z0)*T);
          end;
          Snapped:=TRouteSnapper.Snap(Route,SnapSegs,Proj,Widths,Centers);
          for J:=0 to High(Widths) do Samples.Add(Widths[J]);
        end;
      end;
      Roads.Add(TJSONObject.Create(['way_id',IntToStr(Seg.WayId),'width_m',Seg.Width,
        'width_start_m',Seg.Surface.WidthStart,'width_end_m',Seg.Surface.WidthEnd,
        'width_mid_m',LocalWidth,'snap_widths',Samples,
        'forward',Seg.Surface.ForwardLanes,'backward',Seg.Surface.BackwardLanes,
        'lanes',Seg.Surface.Layout.Count,'condition',Seg.Surface.Condition,'surface',Seg.Surface.Asphalt,
        'x0',Seg.X0,'z0',Seg.Z0,'x1',Seg.X1,'z1',Seg.Z1,
        'lane_offset_m',Lane.GetSmoothOffset(H,LocalWidth)]));
    end;
    for I:=0 to Model.TreeCount-1 do begin
      Tree:=Model.Trees[I];Trees.Add(TJSONObject.Create(['x',Tree.X,'y',Tree.Y,'z',Tree.Z,
        'scale',Tree.Scale,'seed',Tree.Seed,'shrub',Tree.IsShrub,'type',Tree.Procedural.TypePlusOne,
        'lat_e7',Tree.Procedural.LatE7,'lon_e7',Tree.Procedural.LonE7]));
    end;
    for I:=0 to Model.MeshCount-1 do for V in Model.Meshes[I].Mesh.Vertices do
      Vertices.Add(TJSONArray.Create([IntToStr(V.OsmId),V.Position.X,V.Position.Z]));
    if Extended then begin
      Buildings:=TJSONArray.Create;POIs:=TJSONArray.Create;Result.Add('buildings',Buildings);Result.Add('pois',POIs);
      Index:=TStringList.Create;Index.Sorted:=True;
      try
        for I:=0 to Model.MeshCount-1 do if Pos('building-',Model.Meshes[I].Name)=1 then
          for V in Model.Meshes[I].Mesh.Vertices do begin
            Key:=IntToStr(V.OsmId);N:=Index.IndexOf(Key);
            if N<0 then begin Row:=TJSONObject.Create(['id',Key,'max_y',V.Position.Y,'min_y',V.Position.Y,'vertices',0]);Index.AddObject(Key,Row) end
            else Row:=TJSONObject(Index.Objects[N]);
            Row.Floats['max_y']:=Max(Row.Get('max_y',0.0),V.Position.Y);
            Row.Floats['min_y']:=Min(Row.Get('min_y',0.0),V.Position.Y);Row.Integers['vertices']:=Row.Get('vertices',0)+1;
          end;
        for I:=0 to Index.Count-1 do Buildings.Add(TJSONObject(Index.Objects[I]));
      finally Index.Free end;
      for I:=0 to Model.POICount-1 do begin Poi:=Model.POIs[I];POIs.Add(TJSONObject.Create([
        'kind',Ord(Poi.Kind),'x',Poi.Position.X,'y',Poi.Position.Y,'z',Poi.Position.Z,'rotation',Poi.Rotation]));end;
    end;
  finally Proj.Free;Lane.Free end;
end;

function Generate(Dataset:TOSMDataset; const Box:TLatLonBox):TTileModel;
var HM:THeightmap; Proj:TLocalProjection; Meshes:TRoadMeshes;
  Segs:TRoadCenterlineSegArray; Forest:TForestBuildResult; Kind:TRoadKind;
  I:Integer; Seg:TTileRoadSeg;
  Buildings:TBuildingMeshes;POIs:TPOIInstanceArray;POI:TPOIInstance;
begin
  Result:=nil; HM:=THeightmap.Create(8,8,Box);Proj:=TLocalProjection.Create(Box.Center);
  try
    Meshes:=TRoadBuilder.BuildAll(Dataset,HM,Proj,Segs,nil,nil,True,True);
    try
      Forest:=TForestInstanceBuilder.BuildAllDefaults(Dataset,HM,Proj);
      Result:=TTileModel.Create;Result.Box:=Box;Result.Origin:=Box.Center;
      for Kind:=Low(Kind) to High(Kind) do if (Meshes.UVMesh[Kind]<>nil) and
        (Meshes.UVMesh[Kind].VertexCount>0) then begin
        Result.AddMesh('road-'+IntToStr(Ord(Kind)),smkRoad,Meshes.UVMesh[Kind]);Meshes.UVMesh[Kind]:=nil;
      end;
      Result.SetTrees(ForestToTileTrees(Forest));
      if Extended then begin
        Buildings:=TBuildingBuilderExt.BuildAll(Dataset,HM,Proj);
        for I:=Low(Buildings.Walls) to High(Buildings.Walls) do begin
          if Buildings.Walls[I].VertexCount>0 then Result.AddMesh('building-wall-'+IntToStr(I),smkBuildingWall,Buildings.Walls[I]) else Buildings.Walls[I].Free;
          if Buildings.Roofs[I].VertexCount>0 then Result.AddMesh('building-roof-'+IntToStr(I),smkBuildingRoof,Buildings.Roofs[I]) else Buildings.Roofs[I].Free;
        end;
        POIs:=TPOIBuilderExt.BuildAllInstances(Dataset,HM,Proj);
        for POI in POIs do Result.AddPOI(POI.Kind,POI.Position,POI.Rotation);
      end;
      for I:=0 to High(Segs) do begin
        Seg:=Default(TTileRoadSeg);Seg.X0:=Segs[I].X0;Seg.Z0:=Segs[I].Z0;
        Seg.X1:=Segs[I].X1;Seg.Z1:=Segs[I].Z1;Seg.Width:=Segs[I].Width;
        Seg.WayId:=Segs[I].WayId;Seg.IsBridge:=Segs[I].IsBridge;Seg.Surface:=Segs[I].Surface;
        Result.AddRoadSeg(Seg);
      end;
    finally
      Meshes.Major.Free;Meshes.Secondary.Free;Meshes.Minor.Free;Meshes.Service.Free;
      Meshes.Footway.Free;Meshes.Cycleway.Free;Meshes.Railway.Free;Meshes.DirtPath.Free;Meshes.SandPath.Free;
      for Kind:=Low(Kind) to High(Kind) do Meshes.UVMesh[Kind].Free;
    end;
  finally Proj.Free;HM.Free end;
end;

var Input:TStringList; Request,Reply,Tile:TJSONObject; Cache:TGeoTileCache;
  Dataset:TOSMDataset; Box:TLatLonBox; Model,Loaded:TTileModel; T:TGeoTileId;
  ErrorText,TextPath:string; Grid:TGeoTileGrid; I:Integer; Hashes:TJSONArray;
begin
  Reply:=nil;Request:=nil;Cache:=nil;Dataset:=nil;Tile:=nil;Grid:=nil;
  try
    try
      Input:=TStringList.Create;
      try Input.LoadFromFile(ParamStr(1));Request:=TJSONObject(ParsePhotoJson(Input.Text)) finally Input.Free end;
      Extended:=Request.Get('extended',False);
      Tile:=KnowledgeTile(Request,13,256);Box:=KnowledgeBox(Tile.Find('bbox'));
      Cache:=TGeoTileCache.Create(ParamStr(2),'environment-test',13,256,Box.Center.Lat);
      T:=TGeoTileId.Make(0,True,Tile.Get('x',0),Tile.Get('y',0));
      Dataset:=TOSMDataset.Create;TOSMJsonReader.Parse(Request.Find('osm').AsJSON,Dataset);
      Reply:=TJSONObject.Create(['tile_hash',Cache.Recipes.TileHash(T),'path',Cache.PathFor(T)]);
      Model:=Generate(Dataset,Box);try Reply.Add('before',Describe(Model)) finally Model.Free end;
      ErrorText:='';try Cache.Recipes.Apply(Dataset,Box) except on E:Exception do ErrorText:=E.Message end;
      Reply.Add('apply_error',ErrorText);
      Model:=Generate(Dataset,Box);
      try
        Reply.Add('after',Describe(Model));Cache.Save(T,Model);
        if not Cache.TryLoad(T,Loaded) then raise Exception.Create('binary roundtrip failed');
        try Reply.Add('cached',Describe(Loaded)) finally Loaded.Free end;
        TextPath:=ParamStr(1)+'.x3d';TTileX3D.SaveFile(TextPath,Model);Loaded:=TTileX3D.LoadFile(TextPath);
        try Reply.Add('text_cached',Describe(Loaded)) finally Loaded.Free end;
        Reply.Add('road_fingerprint',Cache.RoadFingerprint(T));
      finally Model.Free end;
      Hashes:=TJSONArray.Create;Reply.Add('neighbor_hashes',Hashes);
      for I:=-1 to 1 do Hashes.Add(Cache.Recipes.TileHash(TGeoTileId.Make(0,True,T.TX+I,T.TY)));
      Writeln(Reply.AsJSON);
    except on E:Exception do begin Reply.Free;Reply:=TJSONObject.Create(['error',E.Message]);Writeln(Reply.AsJSON);ExitCode:=1 end end;
  finally Grid.Free;Reply.Free;Dataset.Free;Cache.Free;Tile.Free;Request.Free end;
end.
