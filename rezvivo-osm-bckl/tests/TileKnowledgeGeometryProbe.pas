program TileKnowledgeGeometryProbe;
{$mode objfpc}{$H+}{$codepage UTF8}
uses Classes, SysUtils, Math, fpjson, CastleVectors, Osm3dPhotoSources,
  Osm3dOsmData, Osm3dKnowledgeOsm, Osm3dKnowledgeRecipe, Osm3dTileKnowledge,
  Osm3dGeoMath, Osm3dGeoTileGrid, Osm3dGeoTileCache, Osm3dTileX3D,
  Osm3dHeightmap, Osm3dGeomBuildings, Osm3dGeomMesh;

function Buildings(Dataset: TOSMDataset; const Box: TLatLonBox): TJSONObject;
var HM: THeightmap; Proj: TLocalProjection; M: TBuildingMeshes;
  I,J,Triangles,Vertices: Integer; Top,RoofBottom: Double; Palettes: TJSONArray;
begin
  HM:=THeightmap.Create(4,4,Box); Proj:=TLocalProjection.Create(Box.Center);
  try
    M:=TBuildingBuilderExt.BuildAll(Dataset,HM,Proj);
    Top:=-1e30; RoofBottom:=1e30; Triangles:=0; Vertices:=0; Palettes:=TJSONArray.Create;
    for I:=Low(M.Walls) to High(M.Walls) do begin
      try
        if M.Walls[I]<>nil then begin
          Inc(Triangles,M.Walls[I].TriangleCount); Inc(Vertices,M.Walls[I].VertexCount);
          if M.Walls[I].VertexCount>0 then Palettes.Add(I);
          for J:=0 to M.Walls[I].VertexCount-1 do Top:=Max(Top,M.Walls[I].Vertices[J].Position.Y);
        end;
        if M.Roofs[I]<>nil then begin
          Inc(Triangles,M.Roofs[I].TriangleCount); Inc(Vertices,M.Roofs[I].VertexCount);
          for J:=0 to M.Roofs[I].VertexCount-1 do begin
            Top:=Max(Top,M.Roofs[I].Vertices[J].Position.Y);
            RoofBottom:=Min(RoofBottom,M.Roofs[I].Vertices[J].Position.Y);
          end;
        end;
      finally M.Walls[I].Free; M.Roofs[I].Free end;
    end;
    Result:=TJSONObject.Create(['top_m',Top,'roof_bottom_m',RoofBottom,
      'triangles',Triangles,'vertices',Vertices,'palettes',Palettes]);
  finally Proj.Free; HM.Free end;
end;

var Input: TStringList; Request,Reply,Tile,O,Published: TJSONObject;
  Cache,NewCache: TGeoTileCache; Model: TTileModel; Dataset: TOSMDataset;
  Reader: TKnowledgeOsmReader; Box: TLatLonBox; T,Neighbor: TGeoTileId;
  Id: Int64; Path,ErrorText: string; I: Integer; Arr: TJSONArray;
begin
  Reply:=nil;
  try
    Input:=TStringList.Create;
    try Input.LoadFromFile(ParamStr(1)); Request:=TJSONObject(ParsePhotoJson(Input.Text)) finally Input.Free end;
    Cache:=nil; NewCache:=nil; Dataset:=nil; Reader:=nil; Tile:=nil;
    try
      Tile:=KnowledgeTile(Request,13,256); Box:=KnowledgeBox(Tile.Find('bbox'));
      Cache:=TGeoTileCache.Create(ParamStr(2),'knowledge-test',Tile.Get('zoom',13),Tile.Get('edge_px',256),Box.Center.Lat);
      T:=TGeoTileId.Make(0,True,Tile.Get('x',0),Tile.Get('y',0));
      Reply:=TJSONObject.Create(['path',Cache.PathFor(T),'tile_hash',Cache.Recipes.TileHash(T),
        'catalog_hash',Cache.Recipes.ContentHash,'has',Cache.Has(T),'block_preview',Cache.BlockTexPath(T)]);
      Arr:=TJSONArray.Create; Reply.Add('neighbor_hashes',Arr);
      for I:=-1 to 1 do begin
        Neighbor:=TGeoTileId.Make(0,True,T.TX+I,T.TY);
        Arr.Add(TJSONObject.Create(['x',Neighbor.TX,'y',Neighbor.TY,'hash',Cache.Recipes.TileHash(Neighbor)]));
      end;
      if Request.Find('compile_request')<>nil then begin
        Path:=Cache.PathFor(T);
        Published:=CompileKnowledgeRecipe(ParamStr(2),TJSONObject(Request.Find('compile_request')));
        Reply.Add('published',Published); Reply.Add('old_snapshot_stable',Path=Cache.PathFor(T));
        NewCache:=TGeoTileCache.Create(ParamStr(2),'knowledge-test',Tile.Get('zoom',13),Tile.Get('edge_px',256));
        Reply.Add('new_snapshot_path',NewCache.PathFor(T));
      end;
      if Request.Get('save',False) then begin
        Model:=TTileModel.Create;
        try Model.Box:=Box; Model.Origin:=Box.Center; Cache.Save(T,Model) finally Model.Free end;
      end;
      if Cache.TryLoad(T,Model) then begin Reply.Add('loaded_hash',Model.GenHash); Model.Free end;
      if Request.Find('osm')<>nil then begin
        Dataset:=TOSMDataset.Create; TOSMJsonReader.Parse(Request.Find('osm').AsJSON,Dataset);
        if Request.Get('geometry',False) then Reply.Add('before',Buildings(Dataset,Box));
        ErrorText:='';
        try Cache.Recipes.Apply(Dataset,Box) except on E: Exception do ErrorText:=E.Message end;
        Reply.Add('apply_error',ErrorText);
        if Request.Get('geometry',False) then Reply.Add('after',Buildings(Dataset,Box));
        Reader:=TKnowledgeOsmReader.Create(Dataset);
        Id:=StrToInt64(Request.Get('object_id','1'));
        O:=Reader.ObjectInfo(Request.Get('object_type','way'),Id);
        if O<>nil then Reply.Add('applied_object',O);
      end;
      WriteLn(Reply.AsJSON);
    finally Reader.Free; Dataset.Free; NewCache.Free; Cache.Free; Tile.Free; Reply.Free; Reply:=nil; Request.Free end;
  except on E: Exception do begin
    Reply:=TJSONObject.Create(['error',E.Message]); WriteLn(Reply.AsJSON); Reply.Free; Halt(1);
  end end;
end.
