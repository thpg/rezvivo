unit McpPhotoTools;
{$mode objfpc}{$H+}

{ Thin shared transport adapter. The future in-game agent host uses
  Osm3dPhotoJobs directly or this same registry. }
interface
procedure RegisterPhotoMcpTools(const CacheRoot: string; GridZoom, GridEdgePx: Integer;
  OsmZoom: Integer = 14; OsmTimeoutS: Integer = 60);
procedure ShutdownPhotoMcpTools;
implementation
uses Classes, SysUtils, fpjson, McpRegistry, McpCommon, Osm3dPhotoApi, Osm3dPhotoJobs, Osm3dPhotoSources,
  Osm3dVideoSources, Osm3dCache, Osm3dKnowledgeRecipe, Osm3dPhotoView, Osm3dPhotoPipeline;
const MaxRetainedJobs = 8;
var Jobs: TStringList; Root: string; Zoom, Edge, Serial, SourceZoom, SourceTimeout: Integer;

procedure Merge(Dest, Source: TJSONObject);
var I: Integer;
begin
  try for I:=0 to Source.Count-1 do Dest.Add(Source.Names[I],Source.Items[I].Clone)
  finally Source.Free end;
end;

function FindJob(const Params: TJSONObject): TPhotoApiJob;
var I: Integer; Id: string;
begin
  I := Jobs.IndexOf(Params.Get('job_id',''));
  if I < 0 then raise EMcpError.Create('Unknown photo job_id');
  Result := TPhotoApiJob(Jobs.Objects[I]);
  { Retain recently used jobs, so downloading many images cannot evict the
    search that supplies them. Only inactive, least-recently-used handles go. }
  Id := Jobs[I]; Jobs.Delete(I); Jobs.AddObject(Id,Result);
end;

procedure VideoProviders(const Params: TJSONObject; Reply: TJSONObject);
var Config: TPhotoApiConfig; Cache: TFileSystemCache; I: Integer; P: TJSONObject;
begin
  Config:=DefaultPhotoApiConfig;
  Merge(Reply,VideoSourceRegistry(DefaultVideoSourceConfig,Config.Sources.FlickrKey<>''));
  Cache:=TFileSystemCache.Create(Root);
  try
    for I:=0 to High(IndexedVideoProviders) do begin
      P:=TJSONObject(Reply.Find(IndexedVideoProviders[I]));
      P.Add('imported_index_available',Cache.Has(VideoKey('catalog',IndexedVideoProviders[I])));
    end;
  finally Cache.Free end;
  Reply.Add('grid_zoom',Zoom); Reply.Add('grid_edge_px',Edge); Reply.Add('default_providers',AllVideoProviders);
end;

procedure AddJob(Request: TJSONObject; Photo: TJSONObject; Reply: TJSONObject);
var J: TPhotoApiJob; I: Integer; Id: string; Config: TPhotoApiConfig;
begin
  for I:=0 to Jobs.Count-1 do
    if not TPhotoApiJob(Jobs.Objects[I]).Finished then
      raise EMcpError.Create('A photo job is running; use photos.status or photos.cancel');
  Config := DefaultPhotoApiConfig;
  J := TPhotoApiJob.Create(Root,Config,Request,Photo);
  while Jobs.Count >= MaxRetainedJobs do begin Jobs.Objects[0].Free; Jobs.Delete(0) end;
  Inc(Serial); Id := 'photo-'+IntToStr(Serial); Jobs.AddObject(Id,J);
  J.Start; Reply.Add('job_id',Id); Merge(Reply,J.Snapshot);
end;

procedure Search(const Params: TJSONObject; Reply: TJSONObject);
var P: TJSONObject;
begin
  P := TJSONObject(Params.Clone);
  try
    if P.Find('zoom')=nil then P.Add('zoom',Zoom);
    if P.Find('edge_px')=nil then P.Add('edge_px',Edge);
    AddJob(P,nil,Reply);
  finally P.Free end;
end;

procedure Status(const Params: TJSONObject; Reply: TJSONObject);
begin Merge(Reply,FindJob(Params).Snapshot) end;

procedure ResultPage(const Params: TJSONObject; Reply: TJSONObject);
begin Merge(Reply,FindJob(Params).ResultPage(Params.Get('offset',0),Params.Get('limit',25))) end;

procedure Download(const Params: TJSONObject; Reply: TJSONObject);
var Photo: TJSONObject;
begin
  Photo := FindJob(Params).FindPhoto(Params.Get('photo_id',''));
  if Photo=nil then raise EMcpError.Create('Photo is not in the selected search job');
  try AddJob(Params,Photo,Reply) finally Photo.Free end;
end;

procedure Sequence(const Params:TJSONObject; Reply:TJSONObject);
var P:TJSONObject;
begin
  P:=TJSONObject(Params.Clone);
  try P.Strings['action']:='sequence';P.Integers['zoom']:=Zoom;P.Integers['edge_px']:=Edge;
    Download(P,Reply);
  finally P.Free end;
end;

procedure Acquire(const Params:TJSONObject;Reply:TJSONObject);
var P,Photo:TJSONObject;
begin
  P:=TJSONObject(Params.Clone);Photo:=nil;
  try
    P.Strings['action']:='acquire';
    if P.Find('zoom')=nil then P.Integers['zoom']:=Zoom;
    if P.Find('edge_px')=nil then P.Integers['edge_px']:=Edge;
    if Params.Find('photo_id')<>nil then begin
      Photo:=FindJob(Params).FindPhoto(Params.Get('photo_id',''));
      if Photo=nil then raise EMcpError.Create('Photo is not in the selected search job');
      if P.Find('latitude')=nil then P.Floats['latitude']:=Photo.Get('latitude',0.0);
      if P.Find('longitude')=nil then P.Floats['longitude']:=Photo.Get('longitude',0.0);
    end;
    AddJob(P,Photo,Reply);
  finally Photo.Free;P.Free end;
end;

procedure Cancel(const Params: TJSONObject; Reply: TJSONObject);
var J: TPhotoApiJob;
begin J:=FindJob(Params); if not J.Finished then J.Cancel; Merge(Reply,J.Snapshot) end;

procedure Image(const Params: TJSONObject; Reply: TJSONObject);
begin Merge(Reply,FindJob(Params).ReadImage) end;

procedure Providers(const Params: TJSONObject; Reply: TJSONObject);
var Config: TPhotoApiConfig;
begin
  Config := DefaultPhotoApiConfig;
  Merge(Reply,PhotoSourceRegistry(Config.Sources));
  Reply.Add('panoramax',TJSONObject.Create(['configured',True,'api_url',Config.PanoramaxUrl]));
  Reply.Add('mapillary',TJSONObject.Create(['configured',Config.MapillaryToken<>'',
    'api_url',Config.MapillaryUrl,'credential_env','REZVIVO_MAPILLARY_TOKEN_FILE']));
  Reply.Add('kartaview',TJSONObject.Create(['configured',True,'api_url',Config.KartaViewUrl,
    'note','Provider may deny public API access; inspect per-search status.']));
  Reply.Add('cache','existing HTTP file cache'); Reply.Add('grid_zoom',Zoom); Reply.Add('grid_edge_px',Edge);
  Reply.Add('default_providers',AllPhotoProviders);
end;

procedure VideoSearch(const Params: TJSONObject; Reply: TJSONObject);
var P: TJSONObject;
begin
  P:=TJSONObject(Params.Clone);
  try P.Strings['media_type']:='video'; Search(P,Reply) finally P.Free end;
end;

procedure VideoDownload(const Params: TJSONObject; Reply: TJSONObject);
var P,V: TJSONObject;
begin
  V:=FindJob(Params).FindPhoto(Params.Get('video_id',''));
  if V=nil then raise EMcpError.Create('Video is not in the selected search job');
  P:=TJSONObject(Params.Clone);
  try P.Strings['media_type']:='video'; AddJob(P,V,Reply) finally V.Free; P.Free end;
end;

procedure VideoFrame(const Params: TJSONObject; Reply: TJSONObject);
var P: TJSONObject;
begin
  P:=TJSONObject(Params.Clone);
  try P.Strings['action']:='frame'; VideoDownload(P,Reply) finally P.Free end;
end;

procedure VideoImport(const Params: TJSONObject; Reply: TJSONObject);
var P: TJSONObject;
begin
  P:=TJSONObject(Params.Clone);
  try P.Strings['media_type']:='video'; P.Strings['action']:='import'; AddJob(P,nil,Reply) finally P.Free end;
end;

procedure KnowledgeJob(const Params: TJSONObject; Reply: TJSONObject; const Action: string);
var P: TJSONObject;
begin
  P:=TJSONObject(Params.Clone);
  try
    P.Strings['media_type']:='knowledge'; P.Strings['action']:=Action;
    P.Integers['osm_zoom']:=SourceZoom; P.Integers['osm_timeout_s']:=SourceTimeout;
    Search(P,Reply);
  finally P.Free end;
end;

procedure KnowledgeRead(const Params: TJSONObject; Reply: TJSONObject);
begin KnowledgeJob(Params,Reply,'read') end;
procedure PhotoGallery(const Params:TJSONObject; Reply:TJSONObject);
begin KnowledgeJob(Params,Reply,'gallery') end;
procedure PhotoReview(const Params:TJSONObject; Reply:TJSONObject);
begin KnowledgeJob(Params,Reply,'review_photo') end;
procedure KnowledgeAudit(const Params:TJSONObject; Reply:TJSONObject);
begin KnowledgeJob(Params,Reply,'audit') end;
procedure KnowledgeWrite(const Params: TJSONObject; Reply: TJSONObject);
begin KnowledgeJob(Params,Reply,'write') end;
procedure KnowledgeContext(const Params: TJSONObject; Reply: TJSONObject);
begin KnowledgeJob(Params,Reply,'context') end;

procedure KnowledgeCompile(const Params: TJSONObject; Reply: TJSONObject);
begin KnowledgeJob(Params,Reply,'compile') end;
procedure KnowledgeCapabilities(const Params: TJSONObject; Reply: TJSONObject);
begin Merge(Reply,KnowledgeRecipeCapabilities) end;

procedure ViewSolve(const Params:TJSONObject; Reply:TJSONObject);
begin KnowledgeJob(Params,Reply,'view_solve') end;
procedure ViewProject(const Params:TJSONObject; Reply:TJSONObject);
begin
  if not (Params.Find('view') is TJSONObject) then raise EMcpError.Create('view must be an object');
  Merge(Reply,ProjectPhotoView(TJSONObject(Params.Find('view'))));
end;

procedure Pipeline(const Params:TJSONObject;Reply:TJSONObject);
begin Merge(Reply,PhotoPipelineRequest(Root,Params)) end;

procedure InferStyles(const Params:TJSONObject;Reply:TJSONObject);
begin KnowledgeJob(Params,Reply,'infer_styles') end;

procedure RegisterPhotoMcpTools(const CacheRoot: string; GridZoom, GridEdgePx: Integer;
  OsmZoom: Integer; OsmTimeoutS: Integer);
const JobSchema='{"type":"object","required":["job_id"],"properties":{"job_id":{"type":"string"}}}';
  TileProperties='"latitude":{"type":"number"},"longitude":{"type":"number"},"tile_x":{"type":"integer"},"tile_y":{"type":"integer"},"zoom":{"type":"integer"},"edge_px":{"type":"integer"}';
  RouteProperty='"route_scope":{"type":"object","description":"Optional route corridor: enabled (default true), route_id, radius_m (10..1000, default 150), points [[lon,lat],...]. If omitted, uses saved tile processing_scope. enabled=false requests the whole tile."}';
begin
  if Jobs<>nil then Exit;
  Jobs:=TStringList.Create; Root:=CacheRoot; Zoom:=GridZoom; Edge:=GridEdgePx;
  SourceZoom:=OsmZoom; SourceTimeout:=OsmTimeoutS;
  RegisterMcpCommand('photo_pipeline','Durable tile photo-generation job shared with Assistant. Read capabilities first. Stages require concrete verified receipts; downloading never implies review. Revision checks, leases, cancellation/resume, budgets and idempotent per-request usage.',
    '{"type":"object","properties":{"action":{"type":"string"},"job_id":{"type":"string"},"expected_revision":{"type":"integer"},"agent":{"type":"string"},"tiles":{"type":"array"},"budgets":{"type":"object"},"tile_index":{"type":"integer"},"stage":{"type":"string"},"receipt":{"type":"object"},"deferred":{"type":"boolean"},"reason":{"type":"string"},"request_id":{"type":"string"},"usage":{"type":"object"}}}',@Pipeline);
  RegisterMcpCommand('photo_view.project','Project geographic anchors into a saved perspective photo view. UV is relative to its crop; check anchors never influence fitting.',
    '{"type":"object","required":["view"],"properties":{"view":{"type":"object"}}}',@ViewProject);
  RegisterMcpCommand('photo_view.solve','Bounded background camera fit from independent landmarks and optional camera seeds. Does not save, activate geometry or accept photo evidence. Poll knowledge.status/result.',
    '{"type":"object","required":["view"],"properties":{"view":{"type":"object"},"seeds":{"type":"array"},"position_radius_m":{"type":"number"},"angle_radius_deg":{"type":"number"},"fov_radius_deg":{"type":"number"},"max_iterations":{"type":"integer"}}}',@ViewSolve);
  RegisterMcpCommand('knowledge.capabilities','Supported typed procedural properties and activation policy.','',@KnowledgeCapabilities);
  RegisterMcpCommand('knowledge.infer_styles','Propose a knowledge document filling missing material/roof type from at least two independently photographed, agreeing local examples. Requires bounded structured local_styles rules. Does not save or activate; use normal knowledge.write/compile. Never changes explicit OSM, geometry, floor count or directly observed properties.',
    '{"type":"object","properties":{'+TileProperties+'}}',@InferStyles);
  RegisterMcpCommand('knowledge.compile','Compile accepted knowledge against cached original OSM. Preview by default; activate=true publishes for the next map load; deactivate=true removes this tile recipe. Never changes a running scene.',
    '{"type":"object","required":["expected_revision","expected_hash"],"properties":{'+TileProperties+',"expected_revision":{"type":"integer"},"expected_hash":{"type":"string"},"activate":{"type":"boolean"},"deactivate":{"type":"boolean"},"max_objects":{"type":"integer"}}}',@KnowledgeCompile);
  RegisterMcpCommand('knowledge.read','Read persistent tile knowledge, or an empty editable document. Background job; no network.',
    '{"type":"object","properties":{'+TileProperties+'}}',@KnowledgeRead);
  RegisterMcpCommand('knowledge.audit','Audit one tile from cached discovery and downloaded photos through review, observations and active geometry recipe. Metadata alone is never counted as visual review or applied evidence. No network; use knowledge.status/result.',
    '{"type":"object","properties":{'+TileProperties+'}}',@KnowledgeAudit);
  RegisterMcpCommand('knowledge.write','Save a complete knowledge document with revision/hash conflict protection. Retains previous versions, never edits OSM or geometry. Background job.',
    '{"type":"object","required":["document","expected_revision","expected_hash","author","change_note"],"properties":{'+TileProperties+',"document":{"type":"object"},"expected_revision":{"type":"integer"},"expected_hash":{"type":"string"},"author":{"type":"string"},"change_note":{"type":"string"}}}',@KnowledgeWrite);
  RegisterMcpCommand('knowledge.context','Read original OSM IDs, tags, addresses and fingerprints from the existing tile HTTP cache; check saved bindings. No downloads. Background job.',
    '{"type":"object","properties":{'+TileProperties+','+RouteProperty+',"max_objects":{"type":"integer"},"object_ids":{"type":"array","items":{"type":"string"}}}}',@KnowledgeContext);
  RegisterMcpCommand('knowledge.status','Read knowledge job progress.',JobSchema,@Status);
  RegisterMcpCommand('knowledge.result','Read knowledge document/save result or paginated OSM objects (limit <= 100).',
    '{"type":"object","required":["job_id"],"properties":{"job_id":{"type":"string"},"offset":{"type":"integer"},"limit":{"type":"integer"}}}',@ResultPage);
  RegisterMcpCommand('knowledge.cancel','Cancel pending knowledge work. A completed atomic write remains committed.',JobSchema,@Cancel);
  RegisterMcpCommand('photos.providers','Street-photo provider configuration; never returns credentials.','',@Providers);
  RegisterMcpCommand('photos.gallery','Read tile evidence plus already cached discovery photos and sequence frames. No network or knowledge writes. Includes provider diagnostics; discovery candidates are not observations.',
    '{"type":"object","properties":{'+TileProperties+'}}',@PhotoGallery);
  RegisterMcpCommand('photos.review','Persist a single photo review and/or camera view with conflict protection. Rejected photos are excluded from working gallery and evidence; accepted restores a manually verified reference. Updates affected recipe in the background; inspect result for compile errors. No visual review is inferred automatically.',
    '{"type":"object","required":["source","expected_revision","expected_hash"],"properties":{'+TileProperties+',"source":{"type":"object"},"review_status":{"type":"string","enum":["unreviewed","accepted","rejected"]},"review_note":{"type":"string"},"view":{"type":"object"},"expected_revision":{"type":"integer"},"expected_hash":{"type":"string"},"author":{"type":"string"},"change_note":{"type":"string"}}}',@PhotoReview);
  RegisterMcpCommand('photos.sequence','Read capture-ordered Mapillary neighbors around a photo from a search/sequence job. At most 50 each side; metadata and cached images reuse the HTTP cache. Download selected frames with photos.download.',
    '{"type":"object","required":["job_id","photo_id"],"properties":{"job_id":{"type":"string"},"photo_id":{"type":"string"},"before":{"type":"integer"},"after":{"type":"integer"},"max_pages":{"type":"integer"},"offline":{"type":"boolean"},"refresh":{"type":"boolean"}}}',@Sequence);
  RegisterMcpCommand('photos.search','Start asynchronous street-photo search for one world tile. No world changes.',
    '{"type":"object","properties":{'+TileProperties+','+RouteProperty+',"providers":{"type":"string"},"padding_m":{"type":"number"},"max_pages":{"type":"integer"},"max_photos":{"type":"integer"},"complete_discovery":{"type":"boolean"},"offline":{"type":"boolean"},"refresh":{"type":"boolean"}}}',@Search);
  RegisterMcpCommand('photos.acquire','Acquire eligible photo previews through the shared HTTP cache. mode=batch (default) downloads up to24 nearest Mapillary frames (max48); mode=all searches the entire tile for the requested providers, downloads each uncached eligible candidate once and checkpoints progress. Rejected sources are excluded. Check discovery_complete/acquisition_complete/complete and provider failures; a safety limit is not completion. Optional job_id/photo_id selects sequence neighbors. Acquisition does not mark photographs as visually reviewed or used in geometry.',
    '{"type":"object","properties":{'+TileProperties+','+RouteProperty+',"mode":{"type":"string","enum":["batch","all"]},"providers":{"type":"string"},"max_pages":{"type":"integer","minimum":1,"maximum":500},"max_candidates":{"type":"integer","minimum":1,"maximum":50000},"job_id":{"type":"string"},"photo_id":{"type":"string"},"max_downloads":{"type":"integer","minimum":1,"maximum":50000},"before":{"type":"integer","minimum":0,"maximum":20},"after":{"type":"integer","minimum":0,"maximum":20},"offline":{"type":"boolean"},"refresh":{"type":"boolean"}}}',@Acquire);
  RegisterMcpCommand('photos.status','Read asynchronous photo-job progress.',JobSchema,@Status);
  RegisterMcpCommand('photos.result','Read completed job; photo list is paginated (limit <= 100).',
    '{"type":"object","required":["job_id"],"properties":{"job_id":{"type":"string"},"offset":{"type":"integer"},"limit":{"type":"integer"}}}',@ResultPage);
  RegisterMcpCommand('photos.download','Download a photo from a search job through the shared HTTP file cache.',
    '{"type":"object","required":["job_id","photo_id"],"properties":{"job_id":{"type":"string"},"photo_id":{"type":"string"},"size":{"type":"string","enum":["thumbnail","preview","original"]},"offline":{"type":"boolean"}}}',@Download);
  RegisterMcpCommand('photos.image','Return a completed download as MCP image content; cache only.',JobSchema,@Image);
  RegisterMcpCommand('photos.cancel','Cancel photo acquisition without affecting map HTTP requests.',JobSchema,@Cancel);
  RegisterMcpCommand('videos.providers','Video catalogs, regional coverage and required credentials or dataset access.','',@VideoProviders);
  RegisterMcpCommand('videos.search','Search one tile for videos. Regional datasets are skipped before HTTP. City geotags are only candidates, never frame poses.',
    '{"type":"object","properties":{'+TileProperties+','+RouteProperty+',"providers":{"type":"string"},"padding_m":{"type":"number"},"regional_radius_m":{"type":"number"},"max_pages":{"type":"integer"},"max_videos":{"type":"integer"},"offline":{"type":"boolean"},"refresh":{"type":"boolean"}}}',@VideoSearch);
  RegisterMcpCommand('videos.status','Read background video acquisition progress.',JobSchema,@Status);
  RegisterMcpCommand('videos.result','Read video candidates, paginated (limit <= 100).',
    '{"type":"object","required":["job_id"],"properties":{"job_id":{"type":"string"},"offset":{"type":"integer"},"limit":{"type":"integer"}}}',@ResultPage);
  RegisterMcpCommand('videos.download','Cache an authorized direct video file, bounded to 64 MiB. YouTube discovery links are not downloadable.',
    '{"type":"object","required":["job_id","video_id"],"properties":{"job_id":{"type":"string"},"video_id":{"type":"string"},"offline":{"type":"boolean"}}}',@VideoDownload);
  RegisterMcpCommand('videos.frame','Extract a timestamped preview or fetch a sequence frame. Retains actual position precision and source license. Requires FFmpeg for encoded video.',
    '{"type":"object","required":["job_id","video_id"],"properties":{"job_id":{"type":"string"},"video_id":{"type":"string"},"time_s":{"type":"number"},"offline":{"type":"boolean"}}}',@VideoFrame);
  RegisterMcpCommand('videos.image','Read a completed frame job as image content, cache only.',JobSchema,@Image);
  RegisterMcpCommand('videos.cancel','Cancel acquisition or decoding without affecting map workers.',JobSchema,@Cancel);
  RegisterMcpCommand('videos.import','Index an authorized georeferenced dataset manifest. Replaces only that provider catalog; never downloads the video corpus.',
    '{"type":"object","required":["provider"],"properties":{"provider":{"type":"string"},"manifest_url":{"type":"string"},"manifest":{"type":"object"},"offline":{"type":"boolean"},"refresh":{"type":"boolean"}}}',@VideoImport);
end;

procedure ShutdownPhotoMcpTools;
var I: Integer;
begin
  if Jobs=nil then Exit;
  for I:=0 to Jobs.Count-1 do TPhotoApiJob(Jobs.Objects[I]).Cancel;
  for I:=0 to Jobs.Count-1 do Jobs.Objects[I].Free;
  FreeAndNil(Jobs);
end;

end.
