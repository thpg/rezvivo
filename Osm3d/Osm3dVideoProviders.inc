{ Included in Osm3dVideoApi. All provider errors are isolated by SearchVideos. }
function TVideoApiClient.SearchRemote(const Provider: string; const Box: TLatLonBox;
  MaxPages, Limit: Integer; Offline, Refresh: Boolean; Videos: TJSONArray): TJSONObject;
var J,Detail,Licenses,P: TJSONObject; Items,L: TJSONArray; V: TJSONData;
  Base,URL,Cursor,LastCursor,Ids,LicenseIds,Id,LicenseName,LicenseURL: string;
  I,K,Page,Added,Pages: Integer; Lat,Lon,Radius: Double; More: Boolean;
  function Read(const QueryURL, Schema: string): TJSONObject;
  var RequestURL: string;
  begin
    FSchema:=Schema; RequestURL:=QueryURL;
    if Provider='flickr' then RequestURL:=RequestURL+'&api_key='+URLParam(FConfig.Sources.FlickrKey)
    else RequestURL:=RequestURL+'&key='+URLParam(FVideoConfig.YouTubeKey);
    Result:=JsonResource(RequestURL,QueryURL,Offline,Refresh);
  end;
begin
  Result:=TJSONObject.Create(['provider',Provider]);
  if not Offline and (((Provider='flickr') and (FConfig.Sources.FlickrKey='')) or
    ((Provider='youtube') and (FVideoConfig.YouTubeKey=''))) then begin Result.Add('status','credentials_required'); Exit end;
  Licenses:=nil; J:=nil; Detail:=nil; Cursor:=''; LastCursor:=''; Added:=0; Pages:=0; More:=False;
  try
    try
      if Provider='flickr' then begin
        Base:=FConfig.Sources.FlickrUrl;
        Licenses:=Read(Base+'?method=flickr.photos.licenses.getInfo&format=json&nojsoncallback=1','licenses.license');
        L:=ArrayAt(Licenses,'licenses.license'); LicenseIds:='';
        for I:=0 to L.Count-1 do
          if PhotoLicenseReusable(PhotoJsonString(L.Items[I],'name'),PhotoJsonString(L.Items[I],'url')) then begin
            if LicenseIds<>'' then LicenseIds:=LicenseIds+','; LicenseIds:=LicenseIds+PhotoJsonString(L.Items[I],'id');
          end;
        if LicenseIds='' then raise Exception.Create('No reusable Flickr license ids');
      end else Base:=FVideoConfig.YouTubeURL;
      for Page:=1 to MaxPages do begin
        if FHttp.Aborted then raise EAbort.Create('cancelled');
        if Provider='flickr' then begin
          URL:=Base+'?method=flickr.photos.search&format=json&nojsoncallback=1&media=videos&has_geo=1'+
            '&min_taken_date=1970-01-01&safe_search=1&license='+URLParam(LicenseIds)+
            '&bbox='+FloatText(Box.MinLon)+','+FloatText(Box.MinLat)+','+FloatText(Box.MaxLon)+','+FloatText(Box.MaxLat)+
            '&per_page=100&page='+IntToStr(Page)+'&extras=license,date_taken,owner_name,geo,o_dims,media,url_t,url_l';
          J:=Read(URL,'photos.photo'); Items:=ArrayAt(J,'photos.photo');
          More:=Page<StrToIntDef(PhotoJsonString(J,'photos.pages'),Page);
        end else begin
          Radius:=Box.Center.DistanceTo(TLatLon.Make(Box.MinLat,Box.MinLon))+10;
          if Radius>1000000 then Radius:=1000000;
          URL:=Base+'/search?part=snippet&type=video&maxResults=50&location='+FloatText(Box.Center.Lat)+','+
            FloatText(Box.Center.Lon)+'&locationRadius='+FloatText(Radius)+'m';
          if Cursor<>'' then URL:=URL+'&pageToken='+URLParam(Cursor);
          J:=Read(URL,'items'); Items:=ArrayAt(J,'items'); Ids:='';
          for I:=0 to Items.Count-1 do begin
            Id:=YouTubeId(PhotoJsonString(Items.Items[I],'id.videoId')); if Id='' then Continue;
            if Ids<>'' then Ids:=Ids+','; Ids:=Ids+Id;
          end;
          LastCursor:=Cursor; Cursor:=J.Get('nextPageToken',''); More:=Cursor<>'';
          if More and (LastCursor=Cursor) then raise Exception.Create('Invalid video pagination');
          if Ids<>'' then begin
            Detail:=Read(Base+'/videos?part=snippet,recordingDetails,contentDetails,status&id='+URLParam(Ids),'items');
            Items:=ArrayAt(Detail,'items');
          end else Items:=nil;
        end;
        Inc(Pages);
        try
          if Items<>nil then for I:=0 to Items.Count-1 do begin
            if Added>=Limit then begin More:=True; Break end;
            V:=Items.Items[I]; P:=nil;
            if Provider='flickr' then begin
              if PhotoJsonString(V,'media')<>'video' then Continue;
              if not Num(V,'latitude',Lat) or not Num(V,'longitude',Lon) then Continue;
              LicenseName:=''; LicenseURL:=''; L:=ArrayAt(Licenses,'licenses.license');
              for K:=0 to L.Count-1 do if PhotoJsonString(L.Items[K],'id')=PhotoJsonString(V,'license') then begin
                LicenseName:=PhotoJsonString(L.Items[K],'name'); LicenseURL:=PhotoJsonString(L.Items[K],'url'); Break;
              end;
              Id:=PhotoJsonString(V,'id');
              P:=TJSONObject.Create(['video_id',Id,'latitude',Lat,'longitude',Lon,'coordinate_role','video_geotag',
                'source_url','https://www.flickr.com/photos/'+PhotoJsonString(V,'owner')+'/'+Id,
                'catalog_url',Base,'author',PhotoJsonString(V,'ownername'),'title',PhotoJsonString(V,'title'),
                'captured_at',PhotoJsonString(V,'datetaken'),'license',LicenseName,'license_url',LicenseURL,
                'preview_url',PhotoJsonString(V,'url_l',PhotoJsonString(V,'url_t'))]);
            end else begin
              if not Num(V,'recordingDetails.location.latitude',Lat) or not Num(V,'recordingDetails.location.longitude',Lon) then Continue;
              Id:=YouTubeId(PhotoJsonString(V,'id')); if Id='' then Continue;
              LicenseName:=PhotoJsonString(V,'status.license','youtube');
              P:=TJSONObject.Create(['video_id',Id,'latitude',Lat,'longitude',Lon,'coordinate_role','video_geotag',
                'source_url','https://www.youtube.com/watch?v='+Id,'catalog_url',Base,
                'author',PhotoJsonString(V,'snippet.channelTitle'),'title',PhotoJsonString(V,'snippet.title'),
                'captured_at',PhotoJsonString(V,'recordingDetails.recordingDate'),'license',LicenseName]);
            end;
            try if Accept(P,Provider,Box,0,Videos) then Inc(Added) finally P.Free end;
          end;
        finally FreeAndNil(J); FreeAndNil(Detail) end;
        if (Added>=Limit) or not More then Break;
      end;
      if More then Result.Add('status','truncated') else Result.Add('status','complete');
      Result.Add('videos',Added); Result.Add('pages',Pages);
    except Result.Free; raise end;
  finally Licenses.Free; J.Free; Detail.Free; FSchema:='' end;
end;

function TVideoApiClient.ImportCatalog(Request: TJSONObject): TJSONObject;
var Manifest,J,P: TJSONObject; Items,Records,A,Shards,Box: TJSONArray; Cells: TJSONObject;
  Provider,URL,Key,K: string; I,N,C,Jj,H: Integer; Lat,Lon: Double; Seen: TStringList;
  procedure IndexPoint(ALat,ALon: Double; RecordNumber: Integer);
  var Name: string; List: TJSONArray;
  begin
    Name:=VideoCell(ALat,ALon); List:=TJSONArray(Cells.Find(Name));
    if List=nil then begin List:=TJSONArray.Create; Cells.Add(Name,List) end;
    if (List.Count=0) or (List.Integers[List.Count-1]<>RecordNumber) then List.Add(RecordNumber);
  end;
begin
  Provider:=LowerCase(Request.Get('provider',''));
  if VideoIndexSlot(Provider)<0 then raise Exception.Create('Provider does not accept dataset manifests');
  URL:=Request.Get('manifest_url',''); Manifest:=nil;
  if URL<>'' then begin
    FSchema:='catalog';
    try Manifest:=JsonResource(URL,URL,Request.Get('offline',False),Request.Get('refresh',False)) finally FSchema:='' end;
  end else if (Request.Find('manifest')<>nil) and (Request.Find('manifest').JSONType=jtObject) then
    Manifest:=TJSONObject(Request.Find('manifest').Clone);
  if Manifest=nil then raise Exception.Create('Supply manifest_url or manifest');
  J:=nil; Seen:=TStringList.Create; Seen.Sorted:=True; Seen.Duplicates:=dupIgnore;
  try
    Items:=ArrayAt(Manifest,'videos'); Shards:=ArrayAt(Manifest,'shards');
    if (Manifest.Get('schema_version',0)<>1) or ((Items=nil) and (Shards=nil)) or
      ((Items<>nil) and (Items.Count>10000)) or ((Shards<>nil) and (Shards.Count>10000)) then
      raise Exception.Create('Invalid video manifest schema or record limit');
    if Items=nil then begin Items:=TJSONArray.Create; Manifest.Add('videos',Items) end;
    Records:=TJSONArray.Create; Cells:=TJSONObject.Create; J:=TJSONObject.Create(['schema_version',1,'provider',Provider]);
    J.Add('records',Records); J.Add('cells',Cells); C:=0;
    if Shards<>nil then begin
      for I:=0 to Shards.Count-1 do begin
        Box:=ArrayAt(Shards.Items[I],'bbox');
        if (Shards.Items[I].JSONType<>jtObject) or not VideoDirectURL(PhotoJsonString(Shards.Items[I],'url')) or
          (Box=nil) or (Box.Count<>4) then raise Exception.Create('Invalid regional shard');
        for H:=0 to 3 do if (Box.Items[H].JSONType<>jtNumber) or IsNan(Box.Floats[H]) or IsInfinite(Box.Floats[H]) then
          raise Exception.Create('Invalid shard bounds');
        if (Box.Floats[0]< -180) or (Box.Floats[2]>180) or (Box.Floats[1]< -90) or (Box.Floats[3]>90) or
          (Box.Floats[0]>=Box.Floats[2]) or (Box.Floats[1]>=Box.Floats[3]) then raise Exception.Create('Invalid shard bounds');
      end;
      J.Add('shards',Shards.Clone);
    end;
    for I:=0 to Items.Count-1 do begin
      if FHttp.Aborted then raise EAbort.Create('cancelled');
      if Items.Items[I].JSONType<>jtObject then begin Inc(C); Continue end;
      P:=TJSONObject(Items.Items[I]);
      if P.Get('catalog_url','')='' then P.Strings['catalog_url']:=URL;
      P:=NormalizeVideoManifestRecord(Provider,P);
      if P=nil then begin Inc(C); Continue end;
      if Seen.IndexOf(P.Get('id',''))>=0 then begin P.Free; Inc(C); Continue end;
      Seen.Add(P.Get('id','')); N:=Records.Count; Records.Add(P);
      if Num(P,'latitude',Lat) and Num(P,'longitude',Lon) then IndexPoint(Lat,Lon,N);
      for Jj:=0 to 1 do begin
        if Jj=0 then K:='track' else K:='frames'; A:=ArrayAt(P,K); if A=nil then Continue;
        for H:=0 to A.Count-1 do
          if Num(A.Items[H],'latitude',Lat) and Num(A.Items[H],'longitude',Lon) then IndexPoint(Lat,Lon,N);
      end;
    end;
    if (Items.Count>0) and (Records.Count=0) then raise Exception.Create('Manifest has no valid georeferenced videos');
    J.Add('source_url',URL); Key:=VideoKey('catalog',Provider);
    { Publish one validated index last. A failed replacement leaves the old one. }
    PutJsonKey(Key,J,URL);
    Result:=TJSONObject.Create(['success',True,'provider',Provider,'videos',Records.Count,
      'rejected',C,'spatial_cells',Cells.Count,'cache_key',Key,'stats',Stats]);
  finally Seen.Free; Manifest.Free; J.Free end;
end;

function TVideoApiClient.SearchCorpus(const Provider: string; const Box: TLatLonBox;
  Limit: Integer; Offline, Refresh: Boolean; Videos: TJSONArray): TJSONObject;
var Index,Req,Imported,P,Shard: TJSONObject; Entries,Numbers,Track,Shards,Bounds,ShardItems: TJSONArray; D: TJSONData;
  R1,R2: TFetchResult; Slot,X,Y,I,J,N,Added,ReadShards: Integer; Key,URL: string; Meta: TCacheMetadata;
  Seen: TStringList; SampleBox,ShardBox: TLatLonBox; Truncated: Boolean;
begin
  Result:=TJSONObject.Create(['provider',Provider]); Key:=VideoKey('catalog',Provider);
  Slot:=VideoIndexSlot(Provider); URL:=FVideoConfig.IndexURLs[Slot]; Added:=0; ReadShards:=0; Truncated:=False;
  try
    if (URL<>'') and not Offline and (Refresh or not FHttp.Cache.GetMetadata(Key,Meta) or
      (Meta.ETag<>MD5Print(MD5String(URL))) or
      ((FConfig.MetadataMaxAgeHours>0) and (Now-Meta.FetchedAt>FConfig.MetadataMaxAgeHours/24))) then begin
      Req:=TJSONObject.Create(['provider',Provider,'manifest_url',URL,'refresh',Refresh]);
      try Imported:=ImportCatalog(Req); Imported.Free finally Req.Free end;
    end;
    Index:=ReadJsonKey(Key); Seen:=TStringList.Create; Seen.Sorted:=True; Seen.Duplicates:=dupIgnore;
    try
      if Index<>nil then begin
        Entries:=ArrayAt(Index,'records'); D:=Index.Find('cells');
        if (Entries=nil) or (D=nil) or (D.JSONType<>jtObject) then raise Exception.Create('Invalid cached video index');
        for X:=Floor(Box.MinLon) to Floor(Box.MaxLon) do for Y:=Floor(Box.MinLat) to Floor(Box.MaxLat) do begin
          Numbers:=TJSONArray(TJSONObject(D).Find(IntToStr(X)+'/'+IntToStr(Y))); if Numbers=nil then Continue;
          for I:=0 to Numbers.Count-1 do begin
            N:=Numbers.Integers[I]; if (N<0) or (N>=Entries.Count) or (Seen.IndexOf(IntToStr(N))>=0) then Continue;
            Seen.Add(IntToStr(N)); if Added>=Limit then Continue;
            if Accept(TJSONObject(Entries.Items[N]),Provider,Box,0,Videos) then Inc(Added);
          end;
        end;
        Shards:=ArrayAt(Index,'shards');
        if Shards<>nil then for I:=0 to Shards.Count-1 do begin
          Bounds:=ArrayAt(Shards.Items[I],'bbox');
          ShardBox:=TLatLonBox.Make(Bounds.Floats[1],Bounds.Floats[0],Bounds.Floats[3],Bounds.Floats[2]);
          if not VideoBoxIntersects(Box,ShardBox) then Continue;
          if (Added>=Limit) or (ReadShards>=8) then begin Truncated:=True; Break end;
          URL:=PhotoJsonString(Shards.Items[I],'url'); FSchema:='videos';
          try Shard:=JsonResource(URL,URL,Offline,Refresh) finally FSchema:='' end;
          Inc(ReadShards);
          try
            ShardItems:=ArrayAt(Shard,'videos');
            if (Shard.Get('schema_version',0)<>1) or (ShardItems.Count>10000) then raise Exception.Create('Invalid catalog shard');
            for J:=0 to ShardItems.Count-1 do begin
              if Added>=Limit then begin Truncated:=True; Break end;
              if ShardItems.Items[J].JSONType<>jtObject then Continue;
              P:=TJSONObject(ShardItems.Items[J]);
              if Accept(P,Provider,Box,0,Videos) then Inc(Added);
            end;
          finally Shard.Free end;
        end;
      end;
    finally Seen.Free; Index.Free end;
    { The public comma2k19 example is a one-minute camera sequence, not the
      complete corpus. Its precise envelope prevents irrelevant sample fetches. }
    if Provider='comma2k19' then begin
      SampleBox:=TLatLonBox.Make(37.72100000,-122.47229910,37.73010274,-122.47181023);
      if (Added<Limit) and VideoBoxIntersects(Box,SampleBox) then begin
        URL:=FVideoConfig.CommaURL;
        R1:=Resource(URL+'global_pose/frame_positions',VideoKey('comma-poses',URL),'npy',Offline,Refresh);
        if not R1.Success then begin Result.Add('status',FailureStatus(R1,Offline)); Exit end;
        R2:=Resource(URL+'global_pose/frame_times',VideoKey('comma-times',URL),'npy',Offline,Refresh);
        if not R2.Success then begin Result.Add('status',FailureStatus(R2,Offline)); Exit end;
        Track:=VideoEcefTrack(R1.Data,R2.Data);
        P:=TJSONObject.Create(['video_id','example-1-40','coordinate_role','camera_track',
          'catalog_url','https://github.com/commaai/comma2k19','source_url','https://github.com/commaai/comma2k19/tree/master/Example_1',
          'title','comma2k19 public example, segment 40','captured_at','2018-08-02',
          'author','comma.ai','license','dataset_media_terms_unconfirmed',
          'license_url','https://github.com/commaai/comma2k19/blob/master/LICENSE',
          'video_url',URL+'video.hevc','preview_url',URL+'preview.png','container','hevc','frame_rate',20.0]);
        P.Add('track',Track);
        try if Accept(P,Provider,Box,0,Videos) then Inc(Added) finally P.Free end;
      end;
      Result.Add('sample_only_without_imported_index',not FHttp.Cache.Has(Key));
    end;
    if (Added>=Limit) or Truncated then Result.Add('status','truncated')
    else if (Added=0) and not FHttp.Cache.Has(Key) and (Provider<>'comma2k19') then Result.Add('status','georeferenced_index_required')
    else Result.Add('status','complete');
    Result.Add('videos',Added);
    Result.Add('regional_shards_read',ReadShards);
  except Result.Free; raise end;
end;

function TVideoApiClient.ResolveFlickrVideo(Video: TJSONObject; Offline, Refresh: Boolean): string;
var URL,RequestURL: string; J: TJSONObject; A: TJSONArray; I: Integer; W,Best: Double;
begin
  Result:='';
  URL:=FConfig.Sources.FlickrUrl+'?method=flickr.photos.getSizes&format=json&nojsoncallback=1&photo_id='+URLParam(Video.Get('video_id',''));
  RequestURL:=URL+'&api_key='+URLParam(FConfig.Sources.FlickrKey); FSchema:='sizes.size';
  try J:=JsonResource(RequestURL,URL,Offline,Refresh) finally FSchema:='' end;
  try
    A:=ArrayAt(J,'sizes.size'); Best:=1e10;
    for I:=0 to A.Count-1 do
      if PhotoJsonString(A.Items[I],'media')='video' then begin
        if not Num(A.Items[I],'width',W) then W:=1280;
        if (Abs(W-1280)<Best) and VideoDirectURL(PhotoJsonString(A.Items[I],'source')) then begin
          Best:=Abs(W-1280); Result:=PhotoJsonString(A.Items[I],'source');
        end;
      end;
  finally J.Free end;
end;
