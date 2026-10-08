program PhotoHouseCostProbe;
{$mode objfpc}{$H+}{$codepage UTF8}
{ Isolated, single-building CPU generation. Flat terrain intentionally separates
  mesh generation from HTTP, DEM, world assembly and OpenGL preparation. }
uses Classes, SysUtils, Math, fpjson, CastleTimeUtils,
  Osm3dPhotoSources, Osm3dOsmData, Osm3dKnowledgeOsm, Osm3dKnowledgeRecipe, Osm3dTileKnowledge,
  Osm3dGeoMath, Osm3dGeoTileCache, Osm3dHeightmap,
  Osm3dGeomBuildings, Osm3dGeomMesh;

var Input:TStringList; R,Tile,Reply,Sample:TJSONObject; Samples:TJSONArray;
  Recipes:TKnowledgeRecipeSnapshot; Data:TOSMDataset; HM:THeightmap; Proj:TLocalProjection;
  Box:TLatLonBox; Meshes:TBuildingMeshes; I,J,Triangles,Vertices:Integer;
  T:TTimerResult; Ms:Double;
begin
  try
    Input:=TStringList.Create;
    try Input.LoadFromFile(ParamStr(1)); R:=TJSONObject(ParsePhotoJson(Input.Text)) finally Input.Free end;
    Tile:=nil; Recipes:=nil; Data:=nil; HM:=nil; Proj:=nil; Reply:=nil;
    try
      Tile:=KnowledgeTile(R,13,256); Box:=KnowledgeBox(Tile.Find('bbox'));
      Recipes:=TKnowledgeRecipeSnapshot.FromCatalog(TJSONObject(R.Find('catalog')),nil);
      Data:=TOSMDataset.Create; TOSMJsonReader.Parse(R.Find('osm').AsJSON,Data);
      Recipes.Apply(Data,Box);
      HM:=THeightmap.Create(4,4,Box); Proj:=TLocalProjection.Create(Box.Center);
      Samples:=TJSONArray.Create;
      Reply:=TJSONObject.Create(['object_id',R.Get('object_id',''),
        'method','BuildAll, one building plus OSM member/node closure, flat terrain, no GL/HTTP',
        'recipe_catalog_hash',Recipes.ContentHash,'samples',Samples]);
      for J:=0 to 4 do begin
        T:=Timer; Meshes:=TBuildingBuilderExt.BuildAll(Data,HM,Proj);
        Ms:=TimerSeconds(Timer,T)*1000;
        Triangles:=0; Vertices:=0;
        for I:=Low(Meshes.Walls) to High(Meshes.Walls) do begin
          if Meshes.Walls[I]<>nil then begin
            Inc(Triangles,Meshes.Walls[I].TriangleCount);Inc(Vertices,Meshes.Walls[I].VertexCount)
          end;
          if Meshes.Roofs[I]<>nil then begin
            Inc(Triangles,Meshes.Roofs[I].TriangleCount);Inc(Vertices,Meshes.Roofs[I].VertexCount)
          end;
          Meshes.Walls[I].Free;Meshes.Roofs[I].Free;
        end;
        Sample:=TJSONObject.Create(['ms',Ms,'triangles',Triangles,'vertices',Vertices]);
        Samples.Add(Sample);
      end;
      WriteLn(Reply.AsJSON);
    finally Reply.Free;Proj.Free;HM.Free;Data.Free;Recipes.Free;Tile.Free;R.Free end;
  except on E:Exception do begin
    Reply:=TJSONObject.Create(['error',E.Message]);WriteLn(Reply.AsJSON);Reply.Free;Halt(1)
  end end;
end.
