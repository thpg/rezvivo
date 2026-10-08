program TileKnowledgeProbe;
{$mode objfpc}{$H+}{$codepage UTF8}
uses Classes, SysUtils, CastleUtils, fpjson, Osm3dPhotoSources, Osm3dTileKnowledge,
  Osm3dKnowledgeContext, Osm3dKnowledgeRecipe, Osm3dCache, Osm3dGeoMath, Osm3dOsmOverpass, Osm3dCacheHTTPFetcher, Osm3dOsmData,
  Osm3dPhotoRouteScope, Osm3dGeoTileGrid, Osm3dPhotoPipeline,Osm3dLocalStyles;
var Input: TStringList; Request,Reply,Tile: TJSONObject; Store: TTileKnowledgeStore;
  Cache: TFileSystemCache; Data: TBytes; Meta: TCacheMetadata; Tiles: TTileXYArray;
  Box: TLatLonBox; A,Elements: TJSONArray; I,J: Integer; Q,S: string;
  Http: THTTPFetcherWithCache; Overpass: TOverpassClient; Dataset: TOSMDataset; Dump,Part: TJSONObject;
  Scope:TPhotoRouteScope; Grid:TGeoTileGrid; Id:TGeoTileId; NW,SE:TGeoTileId; X,Y:Integer;
begin
  try
    if ParamCount<>2 then raise Exception.Create('Usage: TileKnowledgeProbe request.json cache-root');
    Input:=TStringList.Create;
    try Input.LoadFromFile(ParamStr(1)); Request:=TJSONObject(ParsePhotoJson(Input.Text)) finally Input.Free end;
    Store:=TTileKnowledgeStore.Create(ParamStr(2)); Reply:=nil;
    try
      case Request.Get('action','read') of
        'pipeline': Reply:=PhotoPipelineRequest(ParamStr(2),TJSONObject(Request.Find('request')));
        'infer_styles':Reply:=ProposeKnowledgeLocalStyles(ParamStr(2),Request);
        'scope_tiles': begin
          { Fixture/authoring helper uses the production corridor intersection,
            including segment interiors and tiles touched only by its radius. }
          Scope:=TPhotoRouteScope.Create(Request.Find('route_scope'));
          Grid:=TGeoTileGrid.Create(Request.Get('zoom',13),Request.Get('edge_px',256));
          try
            if not Scope.Enabled then raise Exception.Create('An enabled route scope is required');
            A:=TJSONArray(Request.FindPath('route_scope.points')); Box:=TLatLonBox.Empty;
            for I:=0 to A.Count-1 do Box:=Box.Include(TLatLon.Make(TJSONArray(A[I]).Floats[1],TJSONArray(A[I]).Floats[0]));
            Box:=Box.ExpandMeters(TJSONObject(Request.Find('route_scope')).Get('radius_m',150.0));
            NW:=Grid.TileAt(TLatLon.Make(Box.MaxLat,Box.MinLon)); SE:=Grid.TileAt(TLatLon.Make(Box.MinLat,Box.MaxLon));
            if Int64(SE.TX-NW.TX+1)*(SE.TY-NW.TY+1)>4096 then raise Exception.Create('Scope helper limited to 4096 candidate tiles');
            Reply:=TJSONObject.Create; Elements:=TJSONArray.Create; Reply.Add('tiles',Elements);
            for X:=NW.TX to SE.TX do for Y:=NW.TY to SE.TY do begin
              Id:=NW; Id.TX:=X; Id.TY:=Y;
              if Scope.HitsBox(Grid.TileBox(Id)) then Elements.Add(TJSONObject.Create(['tile_x',X,'tile_y',Y]));
            end;
          finally Grid.Free; Scope.Free end;
        end;
        'read': Reply:=Store.Read(Request,13,256);
        'write': Reply:=Store.Write(Request,13,256);
        'compile': Reply:=CompileKnowledgeRecipe(ParamStr(2),Request);
        'audit': Reply:=AuditKnowledgeEvidence(ParamStr(2),Request);
        'review': Reply:=ReviewKnowledgePhoto(ParamStr(2),Request);
        'capabilities': Reply:=KnowledgeRecipeCapabilities;
        'context': Reply:=CachedKnowledgeContext(ParamStr(2),Request);
        'fetch': begin
          Tile:=KnowledgeTile(Request,13,256); Cache:=TFileSystemCache.Create(ParamStr(2));
          Http:=THTTPFetcherWithCache.Create(Cache,False); Overpass:=nil; Dataset:=nil; Dump:=nil;
          try
            Http.TimeoutMs:=65000;
            Overpass:=TOverpassClient.Create(Http,Request.Get('endpoint','auto'),16); Overpass.TileZoom:=Request.Get('osm_zoom',14);
            A:=TJSONArray(Tile.Find('bbox')); Box:=TLatLonBox.Make(A.Floats[1],A.Floats[0],A.Floats[3],A.Floats[2]);
            Dataset:=Overpass.GetRegion(Box.ExpandMeters(-0.001));
            Reply:=TJSONObject.Create(['nodes',Dataset.Nodes.Count,'ways',Dataset.Ways.Count,'relations',Dataset.Relations.Count]);
            if Request.Get('dump_osm_path','')<>'' then begin
              Dump:=TJSONObject.Create; Elements:=TJSONArray.Create; Dump.Add('elements',Elements);
              Tiles:=TTileMath.TilesCoveringBox(Box.ExpandMeters(-0.001),Overpass.TileZoom);
              for I:=0 to High(Tiles) do begin
                Q:=TOverpassQueryExt.BuildCombinedFull(TTileMath.TileToLatLonBox(Tiles[I]),DefaultFlagsForFullScene,60);
                if not Cache.Get(OverpassCacheKey(Q),Data) then raise Exception.Create('Fetched OSM missing from HTTP cache');
                SetLength(S,Length(Data)); if S<>'' then Move(Data[0],S[1],Length(Data));
                Part:=TJSONObject(ParsePhotoJson(S));
                try A:=TJSONArray(Part.Find('elements')); for J:=0 to A.Count-1 do Elements.Add(A.Items[J].Clone) finally Part.Free end;
              end;
              Input:=TStringList.Create;
              try Input.Text:=Dump.AsJSON; Input.SaveToFile(Request.Get('dump_osm_path','')) finally Input.Free end;
            end;
          finally Dump.Free; Dataset.Free; Overpass.Free; Http.Free; Cache.Free; Tile.Free end;
        end;
        'fixture': begin
          Tile:=KnowledgeTile(Request,13,256); Cache:=TFileSystemCache.Create(ParamStr(2));
          try
            A:=TJSONArray(Tile.Find('bbox')); Box:=TLatLonBox.Make(A.Floats[1],A.Floats[0],A.Floats[3],A.Floats[2]);
            Tiles:=TTileMath.TilesCoveringBox(Box,Request.Get('osm_zoom',14));
            S:=Request.Find('osm').AsJSON; SetLength(Data,Length(S)); if S<>'' then Move(S[1],Data[0],Length(S));
            Meta:=TCacheMetadata.Make('application/json');
            for I:=0 to High(Tiles) do begin
              Q:=TOverpassQueryExt.BuildCombinedFull(TTileMath.TileToLatLonBox(Tiles[I]),DefaultFlagsForFullScene,60);
              Cache.Put(OverpassCacheKey(Q),Data,Meta);
            end;
            Reply:=TJSONObject.Create(['source_tiles',Length(Tiles)]);
          finally Cache.Free; Tile.Free end;
        end;
        'photo_fixture': begin
          Tile:=KnowledgeTile(Request,13,256);Cache:=TFileSystemCache.Create(ParamStr(2));
          try
            S:=Request.Find('catalog').AsJSON;SetLength(Data,Length(S));if S<>'' then Move(S[1],Data[0],Length(S));
            Q:=Format('photo-api/v1/tile-evidence/z%d/e%d/%d/%d',
              [Tile.Get('zoom',13),Tile.Get('edge_px',256),Tile.Get('x',0),Tile.Get('y',0)]);
            Cache.Put(Q,Data,TCacheMetadata.Make('application/json'));
            Reply:=TJSONObject.Create(['saved',True]);
          finally Cache.Free;Tile.Free end;
        end;
        else raise Exception.Create('Unknown action');
      end;
      WriteLn(Reply.AsJSON);
    finally Reply.Free; Store.Free; Request.Free end;
  except on E: Exception do begin
    Reply:=TJSONObject.Create(['error',E.Message]); WriteLn(Reply.AsJSON); Reply.Free; Halt(1);
  end end;
end.
