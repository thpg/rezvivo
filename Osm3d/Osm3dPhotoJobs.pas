unit Osm3dPhotoJobs;
{$mode objfpc}{$H+}

{ Common asynchronous API for an in-game agent host and external MCP.
  No UI/GL access, no global fetcher mutation, no independent file cache. }
interface
uses Classes, SysUtils, SyncObjs, fpjson, Osm3dPhotoApi;
type
  TPhotoApiJob = class(TThread)
  private
    FLock: TCriticalSection;
    FRequest, FPhoto, FResult: TJSONObject;
    FClient: TPhotoApiClient;
    FCacheRoot: string;
    FStage, FError: string;
    FCompleted, FTotal: Integer;
    FDone: Boolean;
    FCreatedTick,FStartedTick,FFinishedTick:QWord;
    procedure Progress(const Stage: string; Completed, Total: Integer);
  protected
    procedure Execute; override;
    procedure DoTerminate; override;
  public
    constructor Create(const CacheRoot: string; const Config: TPhotoApiConfig;
      Request: TJSONObject; Photo: TJSONObject = nil);
    destructor Destroy; override;
    procedure Cancel;
    function Snapshot: TJSONObject;
    function ResultPage(Offset, Limit: Integer): TJSONObject;
    function FindPhoto(const Id: string): TJSONObject;
    function ReadImage: TJSONObject;
    function Finished: Boolean;
  end;
implementation
uses Math, base64, Osm3dCache, Osm3dCacheHTTPFetcher, Osm3dGeoMath, Osm3dGeoTileGrid,
  Osm3dVideoApi, Osm3dVideoSources, Osm3dTileKnowledge, Osm3dKnowledgeContext, Osm3dKnowledgeRecipe, Osm3dPhotoView,
  Osm3dPhotoGallery,Osm3dKnowledgeEvidence,Osm3dLocalStyles,Osm3dPhotoPipeline;

constructor TPhotoApiJob.Create(const CacheRoot: string; const Config: TPhotoApiConfig;
  Request: TJSONObject; Photo: TJSONObject);
begin
  inherited Create(True); FreeOnTerminate := False;
  FLock := TCriticalSection.Create;
  FCacheRoot := CacheRoot;
  FRequest := TJSONObject(Request.Clone);
  if Photo <> nil then FPhoto := TJSONObject(Photo.Clone);
  if Request.Get('media_type','')='video' then
    FClient := TVideoApiClient.Create(TFileSystemCache.Create(CacheRoot), True, Config,DefaultVideoSourceConfig)
  else FClient := TPhotoApiClient.Create(TFileSystemCache.Create(CacheRoot), True, Config);
  FClient.OnProgress := @Progress;
  FStage := 'queued';
  FCreatedTick:=GetTickCount64;
end;

destructor TPhotoApiJob.Destroy;
begin
  if FClient <> nil then Cancel;
  { Even an initially suspended cancelled thread must finish its terminal hook
    while FLock/FResult still exist. No worker queues main-thread callbacks. }
  if Suspended then Start;
  WaitFor;
  FClient.Free; FRequest.Free; FPhoto.Free; FResult.Free; FLock.Free;
  inherited;
end;

procedure TPhotoApiJob.Cancel;
begin
  Terminate;FClient.Cancel;
  { FPC skips Execute for a thread terminated before its initial Start.
    Publish a terminal result here as no worker will reach Execute.finally. }
  if Suspended then begin
    FLock.Acquire;
    try
      if not FDone then begin
        FDone:=True;FStage:='cancelled';
        if FResult=nil then FResult:=TJSONObject.Create(['status','cancelled','photo_count',0]);
      end;
    finally FLock.Release end;
  end;
end;

procedure TPhotoApiJob.DoTerminate;
begin
  { FPC may skip Execute after Start if Cancel wins before the worker is
    scheduled. This hook runs in both cases, without UI synchronization. }
  FLock.Acquire;
  try
    if not FDone then begin
      FDone:=True;
      if Terminated then FStage:='cancelled'
      else begin FStage:='failed';FError:='Photo worker ended without a result' end;
      if FResult=nil then FResult:=TJSONObject.Create(['status',FStage,'photo_count',0]);
    end;
  finally FLock.Release end;
  inherited;
end;

procedure TPhotoApiJob.Progress(const Stage: string; Completed, Total: Integer);
begin
  FLock.Acquire;
  try FStage := Stage; FCompleted := Completed; FTotal := Total finally FLock.Release end;
end;

function TPhotoApiJob.Finished: Boolean;
begin FLock.Acquire; try Result := FDone finally FLock.Release end end;

procedure TPhotoApiJob.Execute;
var G: TGeoTileGrid; T: TGeoTileId; R: TJSONObject; Z, Edge, X, Y,I,J,Limit: Integer;
  Lat, Lon: Double; Err, Action,Mode: string; Knowledge: TTileKnowledgeStore; Committed: Boolean;
  Saved,Catalog,Nearby,Recipe,Report:TJSONObject;Reviews,Documents,Sources:TJSONArray;Focus:TLatLon;
begin
  R := nil; Err := '';
  FLock.Acquire;try FStartedTick:=GetTickCount64 finally FLock.Release end;
  try
    if Terminated then raise EAbort.Create('cancelled');
    if FRequest.Get('media_type','')='knowledge' then begin
      Action:=FRequest.Get('action','read'); Progress('knowledge:'+Action,0,1);
      if Action='view_solve' then R:=SolvePhotoView(FRequest,Self)
      else if Action='compile' then R:=CompileKnowledgeRecipe(FCacheRoot,FRequest,Self)
      else if Action='audit' then R:=AuditKnowledgeEvidence(FCacheRoot,FRequest,Self)
      else if Action='infer_styles' then R:=ProposeKnowledgeLocalStyles(FCacheRoot,FRequest,Self)
      else if (Action='review') or (Action='review_photo') then R:=ReviewKnowledgePhoto(FCacheRoot,FRequest,Self)
      else if Action='context' then R:=CachedKnowledgeContext(FCacheRoot,FRequest,Self,@Progress)
      else begin
        Knowledge:=TTileKnowledgeStore.Create(FCacheRoot);
        try
          if Action='write' then R:=Knowledge.Write(FRequest,FRequest.Get('zoom',13),FRequest.Get('edge_px',256))
          else if (Action='read') or (Action='gallery') then begin
            R:=Knowledge.Read(FRequest,FRequest.Get('zoom',13),FRequest.Get('edge_px',256));
            if Action='gallery' then begin
              G:=TGeoTileGrid.Create(FRequest.Get('zoom',13),FRequest.Get('edge_px',256));
              try
                Saved:=TJSONObject(R.Find('document').FindPath('tile'));
                T:=TGeoTileId.Make(0,True,Saved.Get('x',0),Saved.Get('y',0));
                Catalog:=FClient.CachedTileCatalog(G,T);
                Nearby:=nil;
                try
                  Nearby:=Knowledge.ReadPhotoNeighbors(Saved);
                  AppendCachedPhotoSources(TJSONObject(R.Find('document')),Catalog,FClient,
                    ArrayAt(Nearby,'documents'));
                  Recipe:=ReadActiveKnowledgeRecipe(FCacheRoot,Saved);
                  try
                    Report:=BuildKnowledgeEvidenceReport(TJSONObject(R.Find('document')),
                      Catalog,FClient,Recipe,R.Get('content_hash',''));
                    Report.Delete('sources');Report.Delete('observations');
                    R.Add('evidence_report',Report);
                  finally Recipe.Free end;
                  if Catalog.Find('providers')<>nil then R.Add('photo_providers',Catalog.Find('providers').Clone);
                  R.Add('gallery_omitted_capacity',Catalog.Get('gallery_omitted_capacity',0));
                  R.Add('gallery_omitted_rejected',Catalog.Get('gallery_omitted_rejected',0));
                  R.Add('gallery_unreadable_neighbors',Nearby.Get('unreadable_tiles',0));
                  if Catalog.Find('related_photo_views')<>nil then
                    R.Add('related_photo_views',Catalog.Find('related_photo_views').Clone);
                  Report:=PhotoPipelineTileIndex(FCacheRoot,FRequest.Get('zoom',13),FRequest.Get('edge_px',256));
                  try
                    if Report.Find(IntToStr(T.TX)+'/'+IntToStr(T.TY))<>nil then
                      R.Add('photo_workflow',Report.Find(IntToStr(T.TX)+'/'+IntToStr(T.TY)).Clone);
                  finally Report.Free end;
                finally Nearby.Free;Catalog.Free end;
              finally G.Free end;
            end;
          end
          else raise Exception.Create('Unknown knowledge action');
        finally Knowledge.Free end;
      end;
    end else if (FClient is TVideoApiClient) and (FRequest.Get('action','')='import') then
      R:=TVideoApiClient(FClient).ImportCatalog(FRequest)
    else if (FPhoto <> nil) and (FRequest.Get('action','')<>'acquire') then
    begin
      Progress('download', 0, 1);
      if FRequest.Get('action','')='sequence' then begin
        G:=TGeoTileGrid.Create(FRequest.Get('zoom',13),FRequest.Get('edge_px',256));
        try R:=FClient.SequenceNeighbors(FPhoto,FRequest.Get('before',5),FRequest.Get('after',5),
          FRequest.Get('max_pages',20),FRequest.Get('offline',False),FRequest.Get('refresh',False),G)
        finally G.Free end;
      end else if FClient is TVideoApiClient then begin
        if FRequest.Get('action','')='frame' then R:=TVideoApiClient(FClient).ExtractFrame(FPhoto,
          FRequest.Get('time_s',FPhoto.Get('matched_time_s',0.0)),FRequest.Get('offline',False))
        else R:=TVideoApiClient(FClient).DownloadVideo(FPhoto,FRequest.Get('offline',False));
      end else R := FClient.Download(FPhoto, FRequest.Get('size','preview'),FRequest.Get('offline',False));
    end else
    begin
      Progress('search', 0, 0);
      Z := FRequest.Get('zoom',13); Edge := FRequest.Get('edge_px',32);
      if (Z < 1) or (Z > 18) or (Edge < 8) or (Edge > 256) or ((Edge and (Edge-1)) <> 0) then
        raise Exception.Create('Invalid grid: zoom 1..18, edge_px power of two 8..256');
      G := TGeoTileGrid.Create(Z, Edge);
      try
        if (FRequest.Find('tile_x') <> nil) and (FRequest.Find('tile_y') <> nil) then
        begin
          X := FRequest.Get('tile_x',-1); Y := FRequest.Get('tile_y',-1);
          if (X < 0) or (Y < 0) or (X >= G.WorldPx / Edge) or (Y >= G.WorldPx / Edge) then
            raise Exception.Create('Tile coordinates outside the grid');
          T := TGeoTileId.Make(0,True,X,Y);
        end else begin
          if (FRequest.Find('latitude') = nil) or (FRequest.Find('longitude') = nil) then
            raise Exception.Create('Supply tile_x/tile_y or latitude/longitude');
          Lat := FRequest.Get('latitude',0.0); Lon := FRequest.Get('longitude',0.0);
          if IsNan(Lat) or IsInfinite(Lat) or IsNan(Lon) or IsInfinite(Lon) or
            (Abs(Lat) > WEB_MERCATOR_MAX_LAT) or (Abs(Lon) > 180) then
            raise Exception.Create('Invalid geographic coordinates');
          T := G.TileAt(TLatLon.Make(Lat,Lon));
        end;
        Knowledge:=TTileKnowledgeStore.Create(FCacheRoot);
        try
          Saved:=Knowledge.Read(FRequest,Z,Edge);Reviews:=TJSONArray.Create;Nearby:=nil;
          try
            if FRequest.Find('route_scope')<>nil then FClient.SetRouteScope(FRequest.Find('route_scope'))
            else FClient.SetRouteScope(Saved.FindPath('document.processing_scope'));
            Sources:=ArrayAt(Saved,'document.sources');
            if Sources<>nil then for I:=0 to Sources.Count-1 do Reviews.Add(Sources[I].Clone);
            Nearby:=Knowledge.ReadPhotoNeighbors(TJSONObject(Saved.FindPath('document.tile')));
            Documents:=ArrayAt(Nearby,'documents');
            if Documents<>nil then for I:=0 to Documents.Count-1 do begin
              Sources:=ArrayAt(Documents[I],'sources');
              if Sources<>nil then for J:=0 to Sources.Count-1 do Reviews.Add(Sources[J].Clone);
            end;
            FClient.SetPhotoReviews(Reviews);
          finally Nearby.Free;Reviews.Free;Saved.Free end;
        finally Knowledge.Free end;
        if FRequest.Get('action','')='acquire' then begin
          Focus:=G.TileCenter(T);Focus.Lat:=FRequest.Get('latitude',Focus.Lat);Focus.Lon:=FRequest.Get('longitude',Focus.Lon);
          Mode:=FRequest.Get('mode','batch');if Mode='all' then Limit:=50000 else Limit:=24;
          if Mode='all' then
            R:=FClient.AcquireTile(G,T,Focus,FPhoto,FRequest.Get('max_downloads',Limit),
              FRequest.Get('before',5),FRequest.Get('after',5),FRequest.Get('offline',False),
              FRequest.Get('refresh',False),Mode,FRequest.Get('providers','all'),
              FRequest.Get('max_pages',50),FRequest.Get('max_candidates',20000))
          else if Mode='batch' then R:=FClient.AcquireMapillary(G,T,Focus,FPhoto,FRequest.Get('max_downloads',24),
            FRequest.Get('before',5),FRequest.Get('after',5),FRequest.Get('offline',False),FRequest.Get('refresh',False))
          else raise Exception.Create('Acquisition mode: batch or all');
        end else if FClient is TVideoApiClient then
          R:=TVideoApiClient(FClient).SearchVideos(G,T,FRequest.Get('providers','all'),
            FRequest.Get('padding_m',80.0),FRequest.Get('regional_radius_m',25000.0),
            FRequest.Get('max_pages',2),FRequest.Get('max_videos',500),
            FRequest.Get('offline',False),FRequest.Get('refresh',False))
        else R := FClient.SearchTile(G,T,FRequest.Get('providers','all'),
          FRequest.Get('padding_m',80.0),FRequest.Get('max_pages',5),FRequest.Get('max_photos',500),
          FRequest.Get('offline',False),FRequest.Get('refresh',False),FRequest.Get('complete_discovery',False));
      finally G.Free end;
    end;
  except on E: Exception do if not Terminated then Err := E.Message end;
  if Terminated and (R=nil) then
    R:=TJSONObject.Create(['status','cancelled','photo_count',0]);
  { An atomic write already committed cannot be cancelled retroactively. }
  Committed:=(R<>nil) and R.Get('saved',False);
  FLock.Acquire;
  try
    FResult := R; FError := Err; FDone := True;FFinishedTick:=GetTickCount64;
    if Terminated and not Committed then FStage := 'cancelled'
    else if Err <> '' then FStage := 'failed'
    else FStage := 'done';
    if (FPhoto <> nil) and not Terminated and (Err = '') then FCompleted := FTotal;
  finally FLock.Release end;
end;

function TPhotoApiJob.Snapshot: TJSONObject;
var Tick:QWord;
begin
  FLock.Acquire;
  try
    Result := TJSONObject.Create(['stage',FStage,'done',FDone,'completed',FCompleted,'total',FTotal,
      'cancelled',FStage='cancelled','error',FError]);
    Tick:=FFinishedTick;if Tick=0 then Tick:=GetTickCount64;
    Result.Add('elapsed_ms',Int64(Tick-FCreatedTick));
    if FStartedTick>0 then Result.Add('worker_ms',Int64(Tick-FStartedTick));
    if FResult <> nil then
    begin
      Result.Add('photo_count',FResult.Get('photo_count',0));
      if FResult.Find('downloaded_count')<>nil then begin
        Result.Add('downloaded_count',FResult.Get('downloaded_count',0));
        Result.Add('remaining_count',FResult.Get('remaining_count',0));
        Result.Add('result_status',FResult.Get('status',''));
      end;
      if FResult.Find('video_count')<>nil then Result.Add('video_count',FResult.Get('video_count',0));
      if FResult.Find('object_count')<>nil then Result.Add('object_count',FResult.Get('object_count',0));
      if FResult.Find('success') <> nil then Result.Add('success',FResult.Get('success',False));
      if FResult.Find('stats') <> nil then Result.Add('stats',FResult.Find('stats').Clone);
    end;
  finally FLock.Release end;
end;

function TPhotoApiJob.ResultPage(Offset, Limit: Integer): TJSONObject;
var I, J: Integer; A, B: TJSONArray;Paged:Boolean;
begin
  if (Offset < 0) or (Limit < 1) or (Limit > 100) then raise Exception.Create('Result limit: 1..100, offset >= 0');
  FLock.Acquire;
  try
    if not FDone then raise Exception.Create('Photo job is still running');
    if FResult = nil then raise Exception.Create('Photo job failed: '+FError);
    Result := TJSONObject.Create;Paged:=False;
    for I := 0 to FResult.Count-1 do
      if ((FResult.Names[I] = 'photos') or (FResult.Names[I]='videos') or (FResult.Names[I]='objects') or
        (FResult.Names[I]='sources') or (FResult.Names[I]='observations')) and (FResult.Items[I].JSONType=jtArray) then
      begin
        A := TJSONArray(FResult.Items[I]); B := TJSONArray.Create;
        for J := Offset to Min(A.Count,Offset+Limit)-1 do B.Add(A.Items[J].Clone);
        Result.Add(FResult.Names[I],B);
        if not Paged then begin
          Result.Add('offset',Offset);Result.Add('next_offset',Min(A.Count,Offset+Limit));Paged:=True;
        end;
        if (FResult.Names[I]='sources') or (FResult.Names[I]='observations') then
          Result.Add(FResult.Names[I]+'_next_offset',Min(A.Count,Offset+Limit));
      end else Result.Add(FResult.Names[I],FResult.Items[I].Clone);
  finally FLock.Release end;
end;

function TPhotoApiJob.FindPhoto(const Id: string): TJSONObject;
var A: TJSONArray; I: Integer;
begin
  Result := nil; FLock.Acquire;
  try
    if not FDone or (FResult = nil) then Exit;
    A := TJSONArray(FResult.Find('photos'));
    if A=nil then begin
      if (FResult.Find('videos')=nil) or (FResult.Find('videos').JSONType<>jtArray) then Exit;
      A:=TJSONArray(FResult.Find('videos'));
    end;
    if A = nil then Exit;
    for I := 0 to A.Count-1 do
      if PhotoJsonString(A.Items[I],'id') = Id then Exit(TJSONObject(A.Items[I].Clone));
  finally FLock.Release end;
end;

function TPhotoApiJob.ReadImage: TJSONObject;
var Key: string; R: TFetchResult; S: RawByteString;
begin
  FLock.Acquire;
  try
    if not FDone or (FResult = nil) or not FResult.Get('success',False) then
      raise Exception.Create('No downloaded photo in this job');
    Key := FResult.Get('cache_key','');
  finally FLock.Release end;
  R := FClient.ReadImage(Key);
  if not R.Success then raise Exception.Create('Photo was removed from HTTP cache');
  if Length(R.Data) > 8 * 1024 * 1024 then raise Exception.Create('Image too large for inline MCP; use preview size');
  SetString(S,PAnsiChar(@R.Data[0]),Length(R.Data));
  Result := TJSONObject.Create(['cache_key',Key,'bytes',Length(R.Data),
    '_image_base64',EncodeStringBase64(S)]);
  if R.Data[0]=$89 then Result.Add('_image_mime','image/png') else Result.Add('_image_mime','image/jpeg');
end;

end.
