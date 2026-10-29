program RoadJunctionTileProbe;
{$mode objfpc}{$H+}{$codepage UTF8}
{ Offline export of the production junction builder. Reads cached OSM and the
  active photo recipe snapshot; never modifies either. Tile-local coordinates
  allow repairing only ground triangles in an already authored tile. }
uses {$IFDEF LCL}LazUTF8,{$ENDIF}SysUtils,Classes,Math,fpjson,CastleVectors,
  Osm3dGeoMath,Osm3dGeomRoads,Osm3dGeomMesh,Osm3dOsmData,
  Osm3dStudioSettings,Osm3dStreamingLauncher,Osm3dBlockGenerator,
  Osm3dCache,Osm3dCacheHTTPFetcher,Osm3dGeoTileCache,Osm3dGeoTileGrid,
  Osm3dTileX3D,Osm3dTileBinary,Osm3dGroundComposite;
var S:TStudioSettings; H:string; Model:TTileModel; Cache:TGeoTileCache;
  Http:THTTPFetcherWithCache; Generator:TOsm3dBlockGenerator; DS:TOSMDataset;
  P:TLocalProjection; Box:TLatLonBox; Roads:TRoadMeshes;
  Segs:TRoadCenterlineSegArray; K:TRoadKind; M:TMesh; I,J,Center:Integer;
  Root,Item:TJSONObject; Patches,Vertices:TJSONArray; V:TMeshVertex;
  Id:TGeoTileId; Output:TStringList;
begin
  SetMultiByteConversionCodePage(CP_UTF8);
  SetMultiByteFileSystemCodePage(CP_UTF8);
  if ParamCount<>3 then raise Exception.Create('Usage: probe old-tile.o3dt cache-root output.json');
  S:=TStudioSettings.Defaults; S.CacheRoot:=ParamStr(2);
  H:=ComputeGenHash(S,GEO_TILE_EDGE_M);
  Model:=TTileBinary.LoadFile(ParamStr(1),[]);
  Cache:=TGeoTileCache.Create(ParamStr(2),H,13,256);
  Http:=THTTPFetcherWithCache.Create(TFileSystemCache.Create(ParamStr(2)),True);
  Generator:=TOsm3dBlockGenerator.Create(Http,nil,nil,S,H,GEO_TILE_EDGE_M);
  P:=TLocalProjection.Create(Model.Origin,WorldScaleLatBand(Model.Origin.Lat));
  DS:=nil;Root:=nil;Output:=nil;
  try
    Box:=Model.Box;
    Box.MinLat-=0.001;Box.MaxLat+=0.001;
    Box.MinLon-=0.002;Box.MaxLon+=0.002;
    DS:=Generator.CachedOsmDatasetForBox(Box);
    if DS=nil then raise Exception.Create('No cached OSM for this tile');
    Cache.Recipes.Apply(DS,Box);
    Roads:=TRoadBuilder.BuildAll(DS,nil,P,Segs,nil,nil,True,True);
    try
      Id:=Model.TileId;
      Root:=TJSONObject.Create(['generator_hash',H,
        'target',Cache.PathFor(Id),'recipe_hash',Cache.Recipes.TileHash(Id),
        'origin',TJSONArray.Create([Model.Origin.Lat,Model.Origin.Lon])]);
      Patches:=TJSONArray.Create;Root.Add('patches',Patches);
      for K:=Low(TRoadKind) to High(TRoadKind) do begin
        M:=Roads.JunctionUV[K];if M=nil then Continue;
        Center:=-1;Vertices:=nil;
        for I:=0 to M.TriangleCount-1 do begin
          J:=M.Indices[I*3];
          if J<>Center then begin
            Center:=J;V:=M.Vertices[Center];
            Vertices:=TJSONArray.Create;
            Item:=TJSONObject.Create(['material',GROUND_MAT_FOR_ROAD[K],
              'way_id',IntToStr(V.OsmId),'vertices',Vertices]);
            Patches.Add(Item);
            Vertices.Add(TJSONArray.Create([V.Position.X,V.Position.Z,V.UV.X,V.UV.Y]));
          end;
          V:=M.Vertices[M.Indices[I*3+1]];
          Vertices.Add(TJSONArray.Create([V.Position.X,V.Position.Z,V.UV.X,V.UV.Y]));
        end;
      end;
      Output:=TStringList.Create;Output.Text:=Root.FormatJSON;
      Output.SaveToFile(ParamStr(3));
      Writeln(Patches.Count,' junctions; hash ',H);
    finally
      Roads.Major.Free;Roads.Secondary.Free;Roads.Minor.Free;Roads.Service.Free;
      Roads.Footway.Free;Roads.Cycleway.Free;Roads.Railway.Free;Roads.DirtPath.Free;Roads.SandPath.Free;
      for K:=Low(TRoadKind) to High(TRoadKind) do begin Roads.UVMesh[K].Free;Roads.JunctionUV[K].Free end;
    end;
  finally Output.Free;Root.Free;DS.Free;P.Free;Generator.Free;Http.Free;Cache.Free;Model.Free end;
end.
