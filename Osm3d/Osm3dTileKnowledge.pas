unit Osm3dTileKnowledge;
{$mode objfpc}{$H+}{$codepage UTF8}

{ Authored, readable tile input. This is NOT a disposable geometry/HTTP cache.
  No renderer, network, or per-frame work. Both agent hosts use this service. }
interface
uses Classes, SysUtils, fpjson, Osm3dGeoTileGrid, Osm3dGeoMath;

const KnowledgeMaxBytes = 2 * 1024 * 1024;
type
  ETileKnowledge = class(Exception);
  TTileKnowledgeStore = class
  private
    FRoot: string;
    function PathFor(Tile: TJSONObject): string;
    function ReadDocument(const Path: string; Tile: TJSONObject;
      out ContentHash: string): TJSONObject;
  public
    constructor Create(const CacheRoot: string);
    function Read(const Request: TJSONObject; DefaultZoom, DefaultEdge: Integer): TJSONObject;
    { Cache-only, at most eight adjacent tiles of exactly the same grid. }
    function ReadPhotoNeighbors(Tile: TJSONObject): TJSONObject;
    function Write(const Request: TJSONObject; DefaultZoom, DefaultEdge: Integer): TJSONObject;
    function ReviewPhoto(const Request:TJSONObject;DefaultZoom,DefaultEdge:Integer):TJSONObject;
    property Root: string read FRoot;
  end;

function KnowledgeTile(const Request: TJSONObject; DefaultZoom, DefaultEdge: Integer): TJSONObject;
procedure ValidateTileKnowledge(Document, Tile: TJSONObject);

{ Shared atomic publication/lock used by knowledge and compiled recipes. }
procedure KnowledgeAtomicText(const Path: string; const S: RawByteString);
function KnowledgeAcquireWriter(const Path: string): THandle;
procedure KnowledgeReleaseWriter(H: THandle);

implementation
uses Math, MD5, DateUtils, Osm3dPhotoSources, Osm3dPhotoView, Osm3dPhotoRouteScope,Osm3dPhotoGallery
  {$IFDEF MSWINDOWS}, Windows{$ELSE}, BaseUnix, Unix{$ENDIF};

function Obj(J: TJSONData; const Name: string; Required: Boolean = True): TJSONObject;
var D: TJSONData;
begin
  Result:=nil; D:=J.FindPath(Name);
  if (D=nil) and not Required then Exit;
  if (D=nil) or (D.JSONType<>jtObject) then raise ETileKnowledge.Create(Name+' must be an object');
  Result:=TJSONObject(D);
end;

function Arr(J: TJSONData; const Name: string; MaxCount: Integer): TJSONArray;
var D: TJSONData;
begin
  D:=J.FindPath(Name);
  if (D=nil) or (D.JSONType<>jtArray) then raise ETileKnowledge.Create(Name+' must be an array');
  Result:=TJSONArray(D);
  if Result.Count>MaxCount then raise ETileKnowledge.Create(Name+' has too many entries');
end;

function Str(J: TJSONData; const Name: string; Required: Boolean = True): string;
var D: TJSONData;
begin
  Result:=''; D:=J.FindPath(Name);
  if (D=nil) and not Required then Exit;
  if (D=nil) or (D.JSONType<>jtString) then raise ETileKnowledge.Create(Name+' must be text');
  Result:=D.AsString;
  if Required and (Trim(Result)='') then raise ETileKnowledge.Create(Name+' must not be empty');
end;

function IntValue(J: TJSONData; const Name: string; MinValue, MaxValue: Int64): Int64;
var D: TJSONData;
begin
  D:=J.FindPath(Name);
  if (D=nil) or (D.JSONType<>jtNumber) or not TryStrToInt64(D.AsString,Result) or
    (Result<MinValue) or (Result>MaxValue) then raise ETileKnowledge.Create('Invalid integer: '+Name);
end;

function Number(J: TJSONData; const Name: string; Lo, Hi: Double): Double;
var D: TJSONData;
begin
  D:=J.FindPath(Name);
  if (D=nil) or (D.JSONType<>jtNumber) then raise ETileKnowledge.Create('Invalid number: '+Name);
  Result:=D.AsFloat;
  if IsNan(Result) or IsInfinite(Result) or (Result<Lo) or (Result>Hi) then
    raise ETileKnowledge.Create('Number outside range: '+Name);
end;

procedure EnumValue(J: TJSONData; const Name, Values: string);
begin
  if Pos('|'+Str(J,Name)+'|','|'+Values+'|')=0 then raise ETileKnowledge.Create('Invalid '+Name);
end;

function KnowledgeTile(const Request: TJSONObject; DefaultZoom, DefaultEdge: Integer): TJSONObject;
var Z,E,X,Y: Integer; G: TGeoTileGrid; T: TGeoTileId; B: TLatLonBox; Lat,Lon: Double;
begin
  Z:=DefaultZoom; E:=DefaultEdge;
  if Request.Find('zoom')<>nil then Z:=IntValue(Request,'zoom',1,18);
  if Request.Find('edge_px')<>nil then E:=IntValue(Request,'edge_px',8,256);
  if (Z<1) or (Z>18) or (E<8) or (E>256) or ((E and (E-1))<>0) then
    raise ETileKnowledge.Create('Invalid tile grid');
  G:=TGeoTileGrid.Create(Z,E);
  try
    if (Request.Find('tile_x')<>nil) or (Request.Find('tile_y')<>nil) then begin
      X:=IntValue(Request,'tile_x',0,Trunc(G.WorldPx/E)-1);
      Y:=IntValue(Request,'tile_y',0,Trunc(G.WorldPx/E)-1);
      T:=TGeoTileId.Make(0,True,X,Y);
    end else begin
      Lat:=Number(Request,'latitude',-WEB_MERCATOR_MAX_LAT,WEB_MERCATOR_MAX_LAT);
      Lon:=Number(Request,'longitude',-180,180); T:=G.TileAt(TLatLon.Make(Lat,Lon));
    end;
    B:=G.TileBox(T);
    Result:=TJSONObject.Create(['world','real','zoom',Z,'edge_px',E,'x',Int64(T.TX),'y',Int64(T.TY),
      'bbox',TJSONArray.Create([B.MinLon,B.MinLat,B.MaxLon,B.MaxLat])]);
  finally G.Free end;
end;

procedure SameTile(A,B: TJSONObject);
begin
  if (Str(A,'world')<>'real') or (IntValue(A,'zoom',1,18)<>B.Get('zoom',0)) or
    (IntValue(A,'edge_px',8,256)<>B.Get('edge_px',0)) or
    (IntValue(A,'x',0,High(Integer))<>B.Get('x',0)) or
    (IntValue(A,'y',0,High(Integer))<>B.Get('y',0)) then
    raise ETileKnowledge.Create('Document belongs to a different tile/grid');
end;

procedure BoundedJson(J: TJSONData; Depth: Integer; var Count: Integer);
var I: Integer;
begin
  Inc(Count);
  if (Depth>24) or (Count>100000) then raise ETileKnowledge.Create('Knowledge document is too complex');
  if (J.JSONType=jtString) and (Length(J.AsString)>32768) then raise ETileKnowledge.Create('Text field exceeds 32 KiB');
  if J.JSONType in [jtObject,jtArray] then
    for I:=0 to J.Count-1 do BoundedJson(J.Items[I],Depth+1,Count);
end;

procedure KnownFields(J: TJSONObject; const Fields: string);
var I,K: Integer;
begin
  for I:=0 to J.Count-1 do begin
    if Pos('|'+J.Names[I]+'|','|'+Fields+'|')=0 then
      raise ETileKnowledge.Create('Unknown knowledge field: '+J.Names[I]);
    for K:=0 to I-1 do if J.Names[K]=J.Names[I] then
      raise ETileKnowledge.Create('Duplicate knowledge field: '+J.Names[I]);
  end;
end;

procedure UniqueId(J: TJSONObject; List: TStringList);
var S: string;
begin
  S:=Str(J,'id');
  if (Length(S)>200) or (List.IndexOf(S)>=0) then raise ETileKnowledge.Create('Duplicate/invalid id: '+S);
  List.Add(S);
end;

procedure References(J: TJSONData; const Field: string; Known: TStringList; Required: Boolean);
var A: TJSONArray; I: Integer; Seen: TStringList; S: string;
begin
  A:=Arr(J,Field,1024);
  if Required and (A.Count=0) then raise ETileKnowledge.Create(Field+' needs evidence');
  Seen:=TStringList.Create; Seen.CaseSensitive:=True;
  try
    for I:=0 to A.Count-1 do begin
      if A.Items[I].JSONType<>jtString then raise ETileKnowledge.Create('Reference must be text');
      S:=A.Strings[I];
      if (Known.IndexOf(S)<0) or (Seen.IndexOf(S)>=0) then raise ETileKnowledge.Create('Unknown/duplicate reference: '+S);
      Seen.Add(S);
    end;
  finally Seen.Free end;
end;

procedure ValidateTileKnowledge(Document, Tile: TJSONObject);
var Sources,Objects,Styles,Problems,Refs,Observations: TJSONArray;
  S,O,R,V: TJSONObject; SourceIds,ObjectIds,StyleIds,ObsIds,RefIds: TStringList;
  I,J,K,Count: Integer; Key,Origin,Id: string; OSMId: Int64; Views,Inventory,Items,Region:TJSONArray; Scope:TPhotoRouteScope;
begin
  Count:=0; BoundedJson(Document,0,Count);
  if Length(Document.AsJSON)>KnowledgeMaxBytes then raise ETileKnowledge.Create('Knowledge exceeds 2 MiB');
  KnownFields(Document,'schema_version|tile|revision|updated_at|updated_by|change_note|summary|osm_basis|sources|objects|local_styles|unresolved|photo_views|processing_scope|image_inventory');
  Scope:=TPhotoRouteScope.Create(Document.Find('processing_scope')); Scope.Free;
  IntValue(Document,'schema_version',1,2); SameTile(Obj(Document,'tile'),Tile);
  if (Document.Find('photo_views')<>nil) and (Document.Get('schema_version',1)<2) then
    raise ETileKnowledge.Create('photo_views requires knowledge schema_version 2');
  Str(Document,'summary',False); Obj(Document,'osm_basis',False);
  Sources:=Arr(Document,'sources',2048); Objects:=Arr(Document,'objects',2048);
  Styles:=Arr(Document,'local_styles',256); Problems:=Arr(Document,'unresolved',2048);
  SourceIds:=TStringList.Create; ObjectIds:=TStringList.Create; StyleIds:=TStringList.Create;
  ObsIds:=TStringList.Create; RefIds:=TStringList.Create;
  SourceIds.CaseSensitive:=True; ObjectIds.CaseSensitive:=True; StyleIds.CaseSensitive:=True;
  ObsIds.CaseSensitive:=True; RefIds.CaseSensitive:=True;
  try
    for I:=0 to Sources.Count-1 do begin
      if Sources.Items[I].JSONType<>jtObject then raise ETileKnowledge.Create('Source must be an object');
      S:=TJSONObject(Sources.Items[I]); UniqueId(S,SourceIds);
      KnownFields(S,'id|kind|provider|media_id|source_url|cache_key|author|license|license_url|captured_at|time_s|coordinate_role|latitude|longitude|uncertainty_m|note|sequence_id|sequence_index|heading_deg|projection|width|height|review_status|review_note|review_reason|review_origin');
      EnumValue(S,'kind','photo|video_frame'); Str(S,'provider'); Str(S,'media_id');
      Key:=Str(S,'source_url');
      if (Pos('https://',LowerCase(Key))<>1) and (Pos('http://',LowerCase(Key))<>1) then
        raise ETileKnowledge.Create('source_url must be a public HTTP(S) reference');
      Str(S,'author',False); Str(S,'license',False);
      if (Str(S,'kind')='video_frame') or (S.Find('time_s')<>nil) then Number(S,'time_s',0,1e8);
      if S.Find('latitude')<>nil then begin Number(S,'latitude',-90,90); Number(S,'longitude',-180,180) end;
      if S.Find('uncertainty_m')<>nil then Number(S,'uncertainty_m',0,2e7);
      if S.Find('sequence_id')<>nil then Str(S,'sequence_id',False);
      if S.Find('sequence_index')<>nil then IntValue(S,'sequence_index',0,10000000);
      if S.Find('heading_deg')<>nil then Number(S,'heading_deg',0,360);
      if S.Find('width')<>nil then IntValue(S,'width',0,100000);
      if S.Find('height')<>nil then IntValue(S,'height',0,100000);
      if S.Find('projection')<>nil then Str(S,'projection',False);
      if S.Find('review_status')<>nil then begin
        EnumValue(S,'review_status','unreviewed|accepted|rejected');
        if S.Get('review_status','')='rejected' then Str(S,'review_note');
      end;
      if S.Find('review_note')<>nil then Str(S,'review_note',False);
      if S.Find('review_reason')<>nil then Str(S,'review_reason');
      if S.Find('review_origin')<>nil then EnumValue(S,'review_origin','automatic|manual');
    end;
    for I:=0 to Objects.Count-1 do begin
      if Objects.Items[I].JSONType<>jtObject then raise ETileKnowledge.Create('World object must be an object');
      UniqueId(TJSONObject(Objects.Items[I]),ObjectIds);
    end;
    for I:=0 to Objects.Count-1 do begin
      O:=TJSONObject(Objects.Items[I]); Id:=Str(O,'id');
      KnownFields(O,'id|category|description|osm_refs|address|location|mapping_status|match_confidence|observations|note');
      EnumValue(O,'category','building|road|sidewalk|vegetation|water|fence|street_furniture|landmark|terrain|other');
      EnumValue(O,'mapping_status','confirmed|ambiguous|unmatched'); Number(O,'match_confidence',0,1);
      Str(O,'description'); Obj(O,'address',False);
      S:=Obj(O,'location',False);
      if S<>nil then begin Number(S,'latitude',-90,90); Number(S,'longitude',-180,180) end;
      Refs:=Arr(O,'osm_refs',32); RefIds.Clear;
      for J:=0 to Refs.Count-1 do begin
        if Refs.Items[J].JSONType<>jtObject then raise ETileKnowledge.Create('OSM reference must be an object');
        R:=TJSONObject(Refs.Items[J]);
        KnownFields(R,'type|id|role|version|timestamp|tags|fingerprint|address');
        EnumValue(R,'type','node|way|relation'); Key:=Str(R,'id');
        if not TryStrToInt64(Key,OSMId) or (OSMId<=0) or (IntToStr(OSMId)<>Key) then
          raise ETileKnowledge.Create('OSM id must be a canonical positive decimal string');
        Key:=Str(R,'type')+'/'+Key;
        if RefIds.IndexOf(Key)>=0 then raise ETileKnowledge.Create('Duplicate OSM reference');
        RefIds.Add(Key); Obj(R,'tags',False); Obj(R,'address',False);
        if R.Find('version')<>nil then IntValue(R,'version',1,High(Integer));
      end;
      if (Pos('local:',Id)<>1) and (RefIds.IndexOf(Id)<0) then
        raise ETileKnowledge.Create('Object id must be type/OSM-id or local:<stable-id>');
      if (Refs.Count=0) and (S=nil) then raise ETileKnowledge.Create('Unmapped object needs a geographic location');
      Observations:=Arr(O,'observations',256);
      for J:=0 to Observations.Count-1 do begin
        if Observations.Items[J].JSONType<>jtObject then raise ETileKnowledge.Create('Observation must be an object');
        V:=TJSONObject(Observations.Items[J]); UniqueId(V,ObsIds);
        KnownFields(V,'id|text|origin|source_ids|confidence|visibility|property|value|unit|uncertainty|decision|note');
        Str(V,'text'); EnumValue(V,'origin','photo_observed|photo_measured|osm_explicit|local_inferred|manual_override');
        EnumValue(V,'visibility','visible|partially_occluded|not_visible|ambiguous'); Number(V,'confidence',0,1);
        EnumValue(V,'decision','unreviewed|accepted|rejected|conflict'); Origin:=Str(V,'origin');
        References(V,'source_ids',SourceIds,(Origin='photo_observed') or (Origin='photo_measured'));
        if (Origin='osm_explicit') and (Refs.Count=0) then raise ETileKnowledge.Create('OSM observation needs an OSM reference');
      end;
    end;
    if Document.Find('image_inventory')<>nil then begin
      Inventory:=Arr(Document,'image_inventory',2048);RefIds.Clear;
      for I:=0 to Inventory.Count-1 do begin
        if not (Inventory[I] is TJSONObject) then raise ETileKnowledge.Create('Image inventory record required');
        R:=TJSONObject(Inventory[I]);KnownFields(R,'source_id|reviewed_at|scope|objects|duplicate_of|adjacent_source_ids|season|note');
        Key:=Str(R,'source_id');if SourceIds.IndexOf(Key)<0 then raise ETileKnowledge.Create('Inventory source not in document');
        if RefIds.IndexOf(Key)>=0 then raise ETileKnowledge.Create('Duplicate image inventory');RefIds.Add(Key);
        if R.Find('duplicate_of')<>nil then begin
          Origin:=Str(R,'duplicate_of');
          if (Origin=Key) or (SourceIds.IndexOf(Origin)<0) then
            raise ETileKnowledge.Create('Duplicate inventory needs a different existing source');
        end;
        EnumValue(R,'scope','context|objects');Str(R,'reviewed_at');
        if R.Find('adjacent_source_ids')<>nil then References(R,'adjacent_source_ids',SourceIds,False);
        if R.Find('season')<>nil then EnumValue(R,'season','unknown|spring|summer|autumn|winter');
        Items:=Arr(R,'objects',128);
        if (R.Get('scope','')='objects') and (Items.Count=0) then raise ETileKnowledge.Create('Object review needs an inventory');
        for J:=0 to Items.Count-1 do begin
          if not (Items[J] is TJSONObject) then raise ETileKnowledge.Create('Inventory object required');
          V:=TJSONObject(Items[J]);KnownFields(V,'category|label|object_ids|status|reason|region|visible_side|occlusion');Str(V,'label');
          if V.Find('visible_side')<>nil then Str(V,'visible_side');
          if V.Find('occlusion')<>nil then EnumValue(V,'occlusion','clear|partial|heavy|unknown');
          EnumValue(V,'category','building|road|sidewalk|vegetation|water|fence|street_furniture|landmark|terrain|other');
          EnumValue(V,'status','bound|context_only|deferred|rejected');References(V,'object_ids',ObjectIds,V.Get('status','')='bound');
          if V.Get('status','')<>'bound' then Str(V,'reason');
          if V.Find('region')<>nil then begin
            Region:=Arr(V,'region',4);if Region.Count<>4 then raise ETileKnowledge.Create('Image region is normalized [left,top,right,bottom]');
            for K:=0 to 3 do if (Region[K].JSONType<>jtNumber) or IsNan(Region[K].AsFloat) or
              IsInfinite(Region[K].AsFloat) or (Region[K].AsFloat<0) or (Region[K].AsFloat>1) then
              raise ETileKnowledge.Create('Image region must be finite and normalized');
            if (Region.Floats[0]>=Region.Floats[2]) or (Region.Floats[1]>=Region.Floats[3]) then
              raise ETileKnowledge.Create('Empty image region');
          end;
        end;
      end;
    end;
    for I:=0 to Styles.Count-1 do begin
      if Styles.Items[I].JSONType<>jtObject then raise ETileKnowledge.Create('Local style must be an object');
      S:=TJSONObject(Styles.Items[I]); UniqueId(S,StyleIds);
      KnownFields(S,'id|description|example_objects|source_ids|applicability|exceptions|confidence|match|fill_properties');
      Str(S,'description'); Str(S,'applicability'); Number(S,'confidence',0,1);
      References(S,'example_objects',ObjectIds,True); References(S,'source_ids',SourceIds,True);
      if S.Find('match')<>nil then begin
        R:=Obj(S,'match');KnownFields(R,'building|within_m|min_bbox_area_m2|max_bbox_area_m2');
        EnumValue(R,'building','yes|apartments|residential|house|detached|terrace|industrial|warehouse|garage|garages');
        Number(R,'within_m',1,500);Number(R,'min_bbox_area_m2',1,1e7);Number(R,'max_bbox_area_m2',1,1e7);
        if R.Get('min_bbox_area_m2',0.0)>R.Get('max_bbox_area_m2',0.0) then raise ETileKnowledge.Create('Inverted local style area range');
        Items:=Arr(S,'fill_properties',2);if Items.Count=0 then raise ETileKnowledge.Create('Style fill_properties required');
        for J:=0 to Items.Count-1 do if (Items[J].AsString<>'facade.material') and (Items[J].AsString<>'roof.shape') then
          raise ETileKnowledge.Create('Local style can fill missing facade.material and roof.shape only');
      end;
    end;
    if Document.Find('photo_views')<>nil then begin
      Views:=Arr(Document,'photo_views',64); RefIds.Clear;
      for I:=0 to Views.Count-1 do begin
        if not (Views.Items[I] is TJSONObject) then raise ETileKnowledge.Create('Photo view must be an object');
        S:=TJSONObject(Views.Items[I]); UniqueId(S,RefIds);
        ValidatePhotoView(S,SourceIds,ObjectIds);
      end;
    end;
    for I:=0 to Problems.Count-1 do begin
      if Problems.Items[I].JSONType<>jtObject then raise ETileKnowledge.Create('Unresolved item must be an object');
      S:=TJSONObject(Problems.Items[I]);
      KnownFields(S,'text|object_ids|source_ids'); Str(S,'text');
      References(S,'object_ids',ObjectIds,False); References(S,'source_ids',SourceIds,False);
    end;
  finally SourceIds.Free; ObjectIds.Free; StyleIds.Free; ObsIds.Free; RefIds.Free end;
end;

function EmptyDocument(Tile: TJSONObject): TJSONObject;
begin
  Result:=TJSONObject.Create(['schema_version',1,'tile',Tile.Clone,'revision',0,'summary','',
    'sources',TJSONArray.Create,'objects',TJSONArray.Create,'local_styles',TJSONArray.Create,'unresolved',TJSONArray.Create]);
end;

constructor TTileKnowledgeStore.Create(const CacheRoot: string);
var Override: string;
begin
  inherited Create;
  Override:=UTF8Encode(UnicodeString(SysUtils.GetEnvironmentVariable('REZVIVO_TILE_KNOWLEDGE_ROOT')));
  if Override<>'' then FRoot:=ExpandFileName(Override)
  else FRoot:=ExcludeTrailingPathDelimiter(ExpandFileName(CacheRoot))+'-knowledge';
  FRoot:=IncludeTrailingPathDelimiter(FRoot);
  if Pos(LowerCase(IncludeTrailingPathDelimiter(ExpandFileName(CacheRoot))),LowerCase(FRoot))=1 then
    raise ETileKnowledge.Create('Knowledge must be outside the disposable map cache');
end;

function TTileKnowledgeStore.PathFor(Tile: TJSONObject): string;
begin
  Result:=FRoot+'real'+PathDelim+'v1'+PathDelim+'z'+IntToStr(Tile.Get('zoom',0))+PathDelim+
    'e'+IntToStr(Tile.Get('edge_px',0))+PathDelim+IntToStr(Tile.Get('x',0))+PathDelim+
    IntToStr(Tile.Get('y',0))+'.knowledge.json';
end;

function TTileKnowledgeStore.ReadDocument(const Path: string; Tile: TJSONObject;
  out ContentHash: string): TJSONObject;
var F: TFileStream; S: RawByteString; J: TJSONData;
begin
  ContentHash:='';
  if not FileExists(Path) then Exit(EmptyDocument(Tile));
  F:=TFileStream.Create(Path,fmOpenRead or fmShareDenyNone);
  try
    if (F.Size<=0) or (F.Size>KnowledgeMaxBytes) then raise ETileKnowledge.Create('Invalid knowledge file size');
    SetLength(S,F.Size); F.ReadBuffer(S[1],Length(S));
  finally F.Free end;
  J:=ParsePhotoJson(S);
  try
    if J.JSONType<>jtObject then raise ETileKnowledge.Create('Knowledge document must be an object');
    ValidateTileKnowledge(TJSONObject(J),Tile); IntValue(J,'revision',1,High(Integer));
    ContentHash:=MD5Print(MD5String(S)); Result:=TJSONObject(J); J:=nil;
  finally J.Free end;
end;

function TTileKnowledgeStore.Read(const Request: TJSONObject; DefaultZoom, DefaultEdge: Integer): TJSONObject;
var Tile,D: TJSONObject; Path,Hash: string;
begin
  Tile:=KnowledgeTile(Request,DefaultZoom,DefaultEdge);
  try
    Path:=PathFor(Tile); D:=ReadDocument(Path,Tile,Hash);
    Result:=TJSONObject.Create(['exists',Hash<>'','path',Path,'content_hash',Hash,'document',D,
      'geometry_applied',False]);
  finally Tile.Free end;
end;

function TTileKnowledgeStore.ReviewPhoto(const Request:TJSONObject;DefaultZoom,DefaultEdge:Integer):TJSONObject;
const Fields:array[0..21] of string=('id','kind','provider','media_id','source_url','cache_key','author',
  'license','license_url','captured_at','time_s','coordinate_role','latitude','longitude','uncertainty_m',
  'note','sequence_id','sequence_index','heading_deg','projection','width','height');
var ReadBack,Doc,Incoming,S,Candidate,Q,V,NewView:TJSONObject;Sources,Views:TJSONArray;
  I,J:Integer;State,Id:string;ChangingReview,AddedSource:Boolean;
begin
  ReadBack:=Read(Request,DefaultZoom,DefaultEdge);Q:=nil;
  try
    Doc:=Obj(ReadBack,'document');Incoming:=Obj(Request,'source');ChangingReview:=Request.Find('review_status')<>nil;
    State:='';if ChangingReview then begin State:=Str(Request,'review_status');EnumValue(Request,'review_status','unreviewed|accepted|rejected') end;
    if not ChangingReview and (Request.Find('view')=nil) then raise ETileKnowledge.Create('Supply review_status or view');
    if (Request.Find('expected_revision')=nil) or (Request.Find('expected_hash')=nil) or
      (Request.Get('expected_revision',-1)<>Doc.Get('revision',0)) or
      (Request.Get('expected_hash','')<>ReadBack.Get('content_hash','')) then
      raise ETileKnowledge.Create('knowledge_revision_conflict: read latest document before reviewing');
    if State='rejected' then Str(Request,'review_note');
    Sources:=Arr(Doc,'sources',2048);S:=nil;Id:=Str(Incoming,'id');AddedSource:=False;
    for I:=0 to Sources.Count-1 do begin
      Candidate:=TJSONObject(Sources[I]);
      if (Candidate.Get('id','')=Id) or
        ((Candidate.Get('kind','')='photo') and (Incoming.Get('kind','')='photo') and
         (Incoming.Get('provider','')<>'') and (Incoming.Get('media_id','')<>'') and
         (Candidate.Get('provider','')=Incoming.Get('provider','')) and
         (Candidate.Get('media_id','')=Incoming.Get('media_id',''))) then begin S:=Candidate;Break end;
    end;
    if S=nil then begin
      if Sources.Count>=2048 then raise ETileKnowledge.Create('Knowledge source limit reached; review existing sources first');
      S:=TJSONObject.Create;
      AddedSource:=True;
      for J:=0 to High(Fields) do if Incoming.Find(Fields[J])<>nil then S.Add(Fields[J],Incoming.Find(Fields[J]).Clone);
      Sources.Add(S);
    end;
    if ChangingReview then begin
      S.Strings['review_status']:=State;S.Strings['review_origin']:='manual';
      S.Strings['review_reason']:=Request.Get('review_reason','manual_review');
      S.Strings['review_note']:=Request.Get('review_note','');
    end else if AddedSource then begin
      { A newly saved view can carry an already explicit review; do not import
        arbitrary fields from the in-memory gallery into the authored file. }
      if S.Find('review_status')=nil then begin
        if Incoming.Find('review_status')<>nil then S.Add('review_status',Incoming.Find('review_status').Clone);
        if Incoming.Find('review_reason')<>nil then S.Add('review_reason',Incoming.Find('review_reason').Clone);
        if Incoming.Find('review_origin')<>nil then S.Add('review_origin',Incoming.Find('review_origin').Clone);
        if Incoming.Find('review_note')<>nil then S.Add('review_note',Incoming.Find('review_note').Clone);
      end;
    end;
    if Request.Find('view')<>nil then begin
      V:=TJSONObject(Obj(Request,'view').Clone);
      try
        V.Strings['source_id']:=S.Get('id','');NewView:=CopyComparisonViewForTile(V,Doc);
      finally V.Free end;
      Doc.Integers['schema_version']:=2;
      if Doc.Find('photo_views')=nil then Doc.Add('photo_views',TJSONArray.Create);
      Views:=TJSONArray(Doc.Find('photo_views'));
      for I:=Views.Count-1 downto 0 do if TJSONObject(Views[I]).Get('id','')=NewView.Get('id','') then Views.Delete(I);
      Views.Add(NewView);
    end;
    Q:=TJSONObject.Create(['document',Doc.Clone,'expected_revision',Doc.Get('revision',0),
      'expected_hash',ReadBack.Get('content_hash',''),'author',Request.Get('author','Photo review'),
      'change_note',Request.Get('change_note','Source photo review updated')]);
    Q.Add('tile_x',Doc.Objects['tile'].Get('x',0));Q.Add('tile_y',Doc.Objects['tile'].Get('y',0));
    Q.Add('zoom',Doc.Objects['tile'].Get('zoom',DefaultZoom));Q.Add('edge_px',Doc.Objects['tile'].Get('edge_px',DefaultEdge));
    Result:=Write(Q,DefaultZoom,DefaultEdge);Result.Add('source_id',S.Get('id',''));
    Result.Add('review_status',S.Get('review_status','unreviewed'));
  finally Q.Free;ReadBack.Free end;
end;

function TTileKnowledgeStore.ReadPhotoNeighbors(Tile: TJSONObject): TJSONObject;
var DX,DY,X,Y,Limit,Failed:Integer; Request,Neighbor,D:TJSONObject;
  Documents:TJSONArray; Path,Hash:string;
begin
  Documents:=TJSONArray.Create;
  Result:=TJSONObject.Create(['documents',Documents,'unreadable_tiles',0]);
  Failed:=0;
  Limit:=(Int64(1) shl Tile.Get('zoom',13))*256 div Tile.Get('edge_px',256);
  for DY:=-1 to 1 do for DX:=-1 to 1 do begin
    if (DX=0) and (DY=0) then Continue;
    X:=(Tile.Get('x',0)+DX+Limit) mod Limit;Y:=Tile.Get('y',0)+DY;
    if (Y<0) or (Y>=Limit) then Continue;
    Request:=TJSONObject.Create(['tile_x',X,'tile_y',Y,'zoom',Tile.Get('zoom',13),
      'edge_px',Tile.Get('edge_px',256)]);
    Neighbor:=nil;
    try
      Neighbor:=KnowledgeTile(Request,13,256);Path:=PathFor(Neighbor);
      if not FileExists(Path) then Continue;
      try
        D:=ReadDocument(Path,Neighbor,Hash);Documents.Add(D);
      except on E:Exception do Inc(Failed) end;
    finally Neighbor.Free;Request.Free end;
  end;
  Result.Integers['unreadable_tiles']:=Failed;
end;

procedure KnowledgeAtomicText(const Path: string; const S: RawByteString);
var Temp: string; G: TGUID; F: TFileStream; OK: Boolean;
begin
  CreateGUID(G); Temp:=Path+'.'+GUIDToString(G)+'.tmp';
  try
    F:=TFileStream.Create(Temp,fmCreate);
    try
      if Length(S)>0 then F.WriteBuffer(S[1],Length(S));
      {$IFDEF MSWINDOWS}
      if not FlushFileBuffers(F.Handle) then raise ETileKnowledge.Create('Knowledge flush failed');
      {$ELSE}
      if fpFsync(F.Handle)<>0 then raise ETileKnowledge.Create('Knowledge flush failed');
      {$ENDIF}
    finally F.Free end;
    {$IFDEF MSWINDOWS}
    OK:=MoveFileExW(PWideChar(UTF8Decode(Temp)),PWideChar(UTF8Decode(Path)),MOVEFILE_REPLACE_EXISTING or $8 { WRITE_THROUGH });
    {$ELSE}
    OK:=RenameFile(Temp,Path);
    {$ENDIF}
    if not OK then raise ETileKnowledge.Create('Cannot publish knowledge file');
  finally if FileExists(Temp) then SysUtils.DeleteFile(Temp) end;
end;

function KnowledgeAcquireWriter(const Path: string): THandle;
begin
  {$IFDEF MSWINDOWS}
  Result:=CreateFileW(PWideChar(UTF8Decode(Path)),GENERIC_READ or GENERIC_WRITE,0,nil,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL,0);
  if Result=INVALID_HANDLE_VALUE then raise ETileKnowledge.Create('Knowledge writer busy or path not writable');
  {$ELSE}
  Result:=fpOpen(Path,O_RDWR or O_CREAT,&600);
  if Result<0 then raise ETileKnowledge.Create('Knowledge path not writable');
  if fpFlock(Result,LOCK_EX or LOCK_NB)<>0 then begin fpClose(Result); raise ETileKnowledge.Create('Knowledge writer busy') end;
  {$ENDIF}
end;

procedure KnowledgeReleaseWriter(H: THandle);
begin
  {$IFDEF MSWINDOWS}CloseHandle(H);{$ELSE}fpClose(H);{$ENDIF}
end;

function TTileKnowledgeStore.Write(const Request: TJSONObject; DefaultZoom, DefaultEdge: Integer): TJSONObject;
var Tile,D,Old: TJSONObject; Path,Hash,ExpectedHash,Author,Note,History: string;
  H: THandle; Revision,ExpectedRevision: Integer; S: RawByteString;
begin
  Tile:=KnowledgeTile(Request,DefaultZoom,DefaultEdge); D:=nil; Old:=nil;
  try
    D:=TJSONObject(Obj(Request,'document').Clone); ValidateTileKnowledge(D,Tile);
    ExpectedRevision:=IntValue(Request,'expected_revision',0,High(Integer)-1);
    if Request.Find('expected_hash')=nil then raise ETileKnowledge.Create('expected_hash is required; read the tile first');
    ExpectedHash:=Str(Request,'expected_hash',False);
    Author:=Str(Request,'author'); Note:=Str(Request,'change_note');
    if (Length(Author)>200) or (Length(Note)>2048) then raise ETileKnowledge.Create('Author/change_note too long');
    Path:=PathFor(Tile);
    if not ForceDirectories(ExtractFilePath(Path)) then raise ETileKnowledge.Create('Cannot create knowledge directory');
    H:=KnowledgeAcquireWriter(Path+'.lock');
    try
      Old:=ReadDocument(Path,Tile,Hash); Revision:=Old.Get('revision',0);
      if (Revision<>ExpectedRevision) or (Hash<>ExpectedHash) then
        raise ETileKnowledge.Create('knowledge_revision_conflict: read latest document and merge before retrying');
      if IntValue(D,'revision',0,High(Integer)-1)<>ExpectedRevision then
        raise ETileKnowledge.Create('Document revision does not match expected_revision');
      D.Delete('tile'); D.Add('tile',Tile.Clone); D.Integers['revision']:=Revision+1;
      D.Strings['updated_at']:=FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"',LocalTimeToUniversal(Now));
      D.Strings['updated_by']:=Author; D.Strings['change_note']:=Note;
      S:=D.FormatJSON([],2);
      if Length(S)>KnowledgeMaxBytes then raise ETileKnowledge.Create('Formatted knowledge exceeds 2 MiB');
      History:=Path+'.history';
      if Hash<>'' then begin
        if not ForceDirectories(History) then raise ETileKnowledge.Create('Cannot preserve knowledge history');
        { Old parsed text is preserved semantically, including manual edits.
          Content hash in the filename identifies the exact old read token. }
        KnowledgeAtomicText(History+PathDelim+IntToStr(Revision)+'-'+Hash+'.json',Old.FormatJSON([],2));
      end;
      KnowledgeAtomicText(Path,S);
      Result:=TJSONObject.Create(['saved',True,'path',Path,'history_path',History,'revision',Revision+1,
        'content_hash',MD5Print(MD5String(S)),'geometry_applied',False,'network_requests',0]);
    finally KnowledgeReleaseWriter(H) end;
  finally Old.Free; D.Free; Tile.Free end;
end;

end.
