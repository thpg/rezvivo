unit Osm3dKnowledgeContext;
{$mode objfpc}{$H+}{$codepage UTF8}

{ Read-only source context for knowledge authoring. Uses the exact OSM query
  and disk cache used by the map generator. Missing cache is not empty OSM. }
interface
uses Classes, SysUtils, fpjson,Osm3dOsmData;
type TKnowledgeContextProgress=procedure(const Stage:string; Completed,Total:Integer) of object;
  PKnowledgeDataset=^TOSMDataset;
function CachedKnowledgeContext(const CacheRoot: string; Request: TJSONObject;
  Cancel: TThread = nil; Progress:TKnowledgeContextProgress=nil;
  RetainedDataset:PKnowledgeDataset=nil): TJSONObject;
implementation
uses Math, MD5, Osm3dTileKnowledge, Osm3dGeoMath,
  Osm3dGeoTileGrid, Osm3dOsmOverpass, Osm3dCache, Osm3dPhotoSources, Osm3dKnowledgeOsm, Osm3dPhotoRouteScope;

function CachedKnowledgeContext(const CacheRoot: string; Request: TJSONObject;
  Cancel: TThread; Progress:TKnowledgeContextProgress;RetainedDataset:PKnowledgeDataset): TJSONObject;
var Tile,Source,Item,ReadBack,Doc,O,Ref,Check: TJSONObject;
  Sources,Objects,Bounds,Refs,Checks,SavedObjects,RequestedIds: TJSONArray; J: TJSONData;
  Cache: TFileSystemCache; Dataset: TOSMDataset; Store: TTileKnowledgeStore;
  Tiles: TTileXYArray; Box: TLatLonBox; Data: TBytes; Text,Query,Key,Id,Hash: string;
  Z,TimeoutS,I,K,Found,Missing,Limit: Integer; TotalBytes: Int64; Reader: TKnowledgeOsmReader; All,Wanted: TStringList;
  Node: TOSMNode; Way: TOSMWay; Rel: TOSMRelation; WasTruncated: Boolean;
  Scope:TPhotoRouteScope; Outside:Integer;
  Started,ReadDone:QWord;

  procedure CheckCancelled;
  begin if (Cancel<>nil) and Cancel.CheckTerminated then raise EAbort.Create('cancelled') end;

  procedure AddObject(const Kind: string; Id: Int64; Tags: TOSMTags);
  var O: TJSONObject;
  begin
    CheckCancelled; if (Tags.Count=0) and (Wanted=nil) then Exit;
    if (Wanted<>nil) and (Wanted.IndexOf(Kind+'/'+IntToStr(Id))<0) then Exit;
    O:=Reader.ObjectInfo(Kind,Id,Request.Get('include_geometry',False)); if O=nil then Exit;
    if KnowledgeBoxesIntersect(KnowledgeBox(O.Find('bbox')),Box) then begin
      if Scope.HitsBox(KnowledgeBox(O.Find('bbox'))) then All.AddObject(O.Get('id',''),O)
      else begin Inc(Outside); O.Free end;
    end
    else O.Free;
  end;

begin
  Tile:=KnowledgeTile(Request,13,256); Result:=nil; Cache:=nil; Dataset:=nil; All:=nil; Wanted:=nil; Store:=nil; ReadBack:=nil; Reader:=nil; Scope:=nil; Outside:=0;
  try
   try
    Bounds:=TJSONArray(Tile.Find('bbox')); Box:=TLatLonBox.Make(Bounds.Floats[1],Bounds.Floats[0],Bounds.Floats[3],Bounds.Floats[2]);
    Store:=TTileKnowledgeStore.Create(CacheRoot); ReadBack:=Store.Read(Request,13,256);
    Doc:=TJSONObject(ReadBack.Find('document')); J:=Request.Find('route_scope');
    if J=nil then J:=Doc.Find('processing_scope');
    Scope:=TPhotoRouteScope.Create(J); Scope.LimitTo(Box);
    Z:=Request.Get('osm_zoom',14); TimeoutS:=Request.Get('osm_timeout_s',60); Limit:=Request.Get('max_objects',2000);
    if (Z<1) or (Z>18) or (TimeoutS<1) or (TimeoutS>600) or (Limit<1) or (Limit>10000) then
      raise ETileKnowledge.Create('Invalid OSM context limits');
    if Request.Find('object_ids')<>nil then begin
      J:=Request.Find('object_ids');
      if (J.JSONType<>jtArray) or (J.Count>8192) then raise ETileKnowledge.Create('object_ids must be an array of at most 8192 OSM IDs');
      RequestedIds:=TJSONArray(J); Wanted:=TStringList.Create;
      Wanted.CaseSensitive:=True; Wanted.Sorted:=True; Wanted.Duplicates:=dupIgnore;
      for I:=0 to RequestedIds.Count-1 do begin
        if (RequestedIds.Items[I].JSONType<>jtString) or (Length(RequestedIds.Strings[I])>200) then
          raise ETileKnowledge.Create('object_ids must contain OSM identity strings');
        Wanted.Add(RequestedIds.Strings[I]);
      end;
    end;
    { Count before allocation: a coarse world tile must not scan a continent. }
    if (Box.Width/360*Power(2,Z)>4.01) then raise ETileKnowledge.Create('OSM context is limited to 16 source tiles');
    { The east/south boundary belongs to the next source tile. Avoid claiming
      incomplete coverage merely because an edge-touching neighbor is absent. }
    Tiles:=TTileMath.TilesCoveringBox(Box.ExpandMeters(-0.001),Z);
    if Length(Tiles)>16 then raise ETileKnowledge.Create('OSM context is limited to 16 source tiles');
    Cache:=TFileSystemCache.Create(CacheRoot); Dataset:=TOSMDataset.Create;
    All:=TStringList.Create;
    Result:=TJSONObject.Create(['tile',Tile.Clone,'network_requests',0,'osm_zoom',Z,'filtered',(Wanted<>nil) or Scope.Enabled]);
    Result.Add('route_scope',Scope.Summary);
    Sources:=TJSONArray.Create; Objects:=TJSONArray.Create; Checks:=TJSONArray.Create;
    Result.Add('sources',Sources); Result.Add('objects',Objects); Result.Add('binding_checks',Checks);
    Found:=0; Missing:=0; TotalBytes:=0; Reader:=TKnowledgeOsmReader.Create(Dataset,Cancel);
    Started:=GetTickCount64;
    for I:=0 to High(Tiles) do begin
      CheckCancelled;
      if not Scope.HitsBox(TTileMath.TileToLatLonBox(Tiles[I])) then Continue;
      if Assigned(Progress) then Progress('knowledge:read_osm',I,Length(Tiles));
      Query:=TOverpassQueryExt.BuildCombinedFull(TTileMath.TileToLatLonBox(Tiles[I]),DefaultFlagsForFullScene,TimeoutS);
      Key:=OverpassCacheKey(Query); Source:=TJSONObject.Create(['cache_key',Key]); Sources.Add(Source);
      if not Cache.Get(Key,Data) then begin Inc(Missing); Source.Add('status','cache_miss'); Continue end;
      Inc(TotalBytes,Length(Data));
      if (Length(Data)>32*1024*1024) or (TotalBytes>96*1024*1024) then raise ETileKnowledge.Create('OSM context exceeds byte limit');
      SetLength(Text,Length(Data)); if Text<>'' then Move(Data[0],Text[1],Length(Data));
      { The shared OSM reader already validates root/elements. Do not parse,
        serialize and parse a second copy of a large city response. }
      if Assigned(Progress) then Progress('knowledge:parse_osm',I,Length(Tiles));
      TOSMJsonReader.Parse(Text,Dataset);
      Inc(Found); Source.Add('status','cached'); Source.Add('fingerprint',MD5Print(MD5String(Text)));
    end;
    ReadDone:=GetTickCount64;
    if Assigned(Progress) then Progress('knowledge:filter_objects',0,Dataset.Nodes.Count+Dataset.Ways.Count+Dataset.Relations.Count);
    for Node in Dataset.Nodes.Values do AddObject('node',Node.Id,Node.Tags);
    for Way in Dataset.Ways.Values do AddObject('way',Way.Id,Way.Tags);
    for Rel in Dataset.Relations.Values do AddObject('relation',Rel.Id,Rel.Tags);
    All.Sorted:=True; WasTruncated:=All.Count>Limit;
    for I:=0 to Min(Limit,All.Count)-1 do Objects.Add(TJSONObject(All.Objects[I]).Clone);
    Result.Add('object_count',Objects.Count); Result.Add('matching_object_count',All.Count);
    Result.Add('outside_route_scope',Outside);
    Result.Add('truncated',WasTruncated); Result.Add('cached_source_tiles',Found); Result.Add('missing_source_tiles',Missing);
    Result.Add('source_bytes',TotalBytes);
    Result.Add('source_read_parse_ms',ReadDone-Started); Result.Add('object_filter_ms',GetTickCount64-ReadDone);
    Result.Add('complete',Missing=0); Result.Add('osm_basis',TJSONObject.Create(['fingerprint',MD5Print(MD5String(Sources.AsJSON)),
      'complete',Missing=0,'source_tiles',Sources.Clone]));
    SavedObjects:=TJSONArray(Doc.Find('objects'));
    for I:=0 to SavedObjects.Count-1 do begin
      O:=TJSONObject(SavedObjects.Items[I]); Refs:=TJSONArray(O.Find('osm_refs'));
      for K:=0 to Refs.Count-1 do begin
        Ref:=TJSONObject(Refs.Items[K]); Id:=Ref.Get('type','')+'/'+Ref.Get('id','');
        Check:=TJSONObject.Create(['object_id',O.Get('id',''),'osm_id',Id]); Checks.Add(Check);
        if (Wanted<>nil) and (Wanted.IndexOf(Id)<0) then begin Check.Add('status','not_requested'); Continue end;
        if All.Find(Id,Found) then begin
          Item:=TJSONObject(All.Objects[Found]); Hash:=Item.Get('fingerprint','');
          Check.Add('current_fingerprint',Hash);
          if Ref.Get('fingerprint','')='' then Check.Add('status','no_saved_fingerprint')
          else if Ref.Get('fingerprint','')=Hash then Check.Add('status','unchanged')
          else Check.Add('status','osm_changed');
        end else if Scope.Enabled then Check.Add('status','outside_route_scope_or_unavailable')
        else if Missing>0 then Check.Add('status','context_incomplete')
        else Check.Add('status','not_in_tile_context');
      end;
    end;
    Result.Add('knowledge_revision',Doc.Get('revision',0));
    { The compiler can dry-run all native inputs without parsing OSM twice.
      Ownership transfers only on success; ordinary callers keep no dataset. }
    if RetainedDataset<>nil then begin RetainedDataset^:=Dataset;Dataset:=nil end;
   except FreeAndNil(Result); raise end;
  finally
    Scope.Free; ReadBack.Free; Store.Free;
    if All<>nil then for I:=0 to All.Count-1 do All.Objects[I].Free;
    Wanted.Free; All.Free; Reader.Free; Dataset.Free; Cache.Free; Tile.Free;
  end;
end;

end.
