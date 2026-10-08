unit Osm3dVideoApi;
{$mode objfpc}{$H+}{$codepage UTF8}

{ Video discovery and selected frames share the photo transport, worker and
  HTTP cache. No decoder or catalog work occurs in a render/update callback. }
interface
uses Classes, SysUtils, fpjson, Osm3dPhotoApi, Osm3dVideoSources,
  Osm3dGeoMath, Osm3dGeoTileGrid, Osm3dCache, Osm3dCacheHTTPFetcher;
type
  TVideoApiClient = class(TPhotoApiClient)
  private
    FVideoConfig: TVideoSourceConfig;
    FResponseKind, FSchema: string;
    function ReadJsonKey(const Key: string): TJSONObject;
    procedure PutJsonKey(const Key: string; J: TJSONData; const SourceIdentity: string = '');
    function Resource(const URL, Key, Kind: string; Offline, Refresh: Boolean): TFetchResult;
    function JsonResource(const URL, Identity: string; Offline, Refresh: Boolean): TJSONObject;
    function SearchCSV(const Provider: string; const Box: TLatLonBox; RegionalRadiusM: Double;
      Limit: Integer; Offline, Refresh: Boolean; Videos: TJSONArray): TJSONObject;
    function SearchRemote(const Provider: string; const Box: TLatLonBox;
      MaxPages, Limit: Integer; Offline, Refresh: Boolean; Videos: TJSONArray): TJSONObject;
    function SearchCorpus(const Provider: string; const Box: TLatLonBox;
      Limit: Integer; Offline, Refresh: Boolean; Videos: TJSONArray): TJSONObject;
    function Accept(Item: TJSONObject; const Provider: string; const Box: TLatLonBox;
      RegionalRadiusM: Double; Videos: TJSONArray): Boolean;
    function FullRecord(Video: TJSONObject): TJSONObject;
    function FailureStatus(const R: TFetchResult; Offline: Boolean): string;
    function ResolveFlickrVideo(Video: TJSONObject; Offline, Refresh: Boolean): string;
  protected
    function ValidateResponse(Sender: TObject; const URL: string;
      const Bytes: TBytes; const ContentType: string): string; override;
    procedure PrepareResponse(Sender: TObject; const URL: string; var Bytes: TBytes); override;
  public
    constructor Create(Cache: TCacheBase; OwnsCache: Boolean; const PhotoConfig: TPhotoApiConfig;
      const VideoConfig: TVideoSourceConfig);
    function SearchVideos(Grid: TGeoTileGrid; const Tile: TGeoTileId; const Providers: string;
      PaddingM, RegionalRadiusM: Double; MaxPages, MaxVideos: Integer; Offline, Refresh: Boolean): TJSONObject;
    function ImportCatalog(Request: TJSONObject): TJSONObject;
    function DownloadVideo(Video: TJSONObject; Offline: Boolean): TJSONObject;
    function ExtractFrame(Video: TJSONObject; TimeS: Double; Offline: Boolean): TJSONObject;
    function ReadImage(const CacheKey: string): TFetchResult; override;
  end;

implementation
uses Math, MD5, DateUtils, URIParser, Process, Osm3dPhotoSources, Osm3dVideoIndex;

constructor TVideoApiClient.Create(Cache: TCacheBase; OwnsCache: Boolean;
  const PhotoConfig: TPhotoApiConfig; const VideoConfig: TVideoSourceConfig);
begin
  inherited Create(Cache,OwnsCache,PhotoConfig); FVideoConfig:=VideoConfig;
  FResponseKind:='json'; FHttp.UserAgent:='REZVIVOMediaApi/1.0 (+https://rezvivo.com)';
end;

function TVideoApiClient.ReadJsonKey(const Key: string): TJSONObject;
var B: TBytes; S: RawByteString; J: TJSONData;
begin
  Result:=nil; if not FHttp.Cache.Get(Key,B) or (Length(B)=0) then Exit;
  SetString(S,PAnsiChar(@B[0]),Length(B)); J:=nil;
  try J:=ParsePhotoJson(S); if J.JSONType=jtObject then begin Result:=TJSONObject(J); J:=nil; Inc(FCacheHits) end
  except { A derived index is disposable; the source cache remains untouched. } end;
  J.Free;
end;

procedure TVideoApiClient.PutJsonKey(const Key: string; J: TJSONData; const SourceIdentity: string);
var S: RawByteString; B: TBytes; Meta: TCacheMetadata;
begin
  if FHttp.Aborted then raise EAbort.Create('cancelled');
  S:=J.AsJSON; SetLength(B,Length(S)); if S<>'' then Move(S[1],B[0],Length(S));
  Meta:=TCacheMetadata.Make('application/json');
  if SourceIdentity<>'' then Meta.ETag:=MD5Print(MD5String(SourceIdentity));
  FHttp.Cache.Put(Key,B,Meta);
  if not FHttp.Cache.Has(Key) then raise Exception.Create('cache_write_failed');
end;

function TVideoApiClient.ValidateResponse(Sender: TObject; const URL: string;
  const Bytes: TBytes; const ContentType: string): string;
var S: RawByteString; J: TJSONData; L: TStringList; P: Integer;
begin
  if FResponseKind='image' then Exit(inherited ValidateResponse(Sender,URL,Bytes,ContentType));
  Result:='';
  if (Length(Bytes)=0) or (Length(Bytes)>FHttp.MaxResponseBytes) then Exit('Empty or oversized media response');
  if FResponseKind='npy' then begin
    if (Length(Bytes)>12) and (Bytes[0]=$93) and (Bytes[1]=Ord('N')) and (Bytes[2]=Ord('U')) then Exit;
    Exit('Invalid camera pose array');
  end;
  if FResponseKind='media' then begin
    if (Length(Bytes)>=12) and (Bytes[4]=Ord('f')) and (Bytes[5]=Ord('t')) and (Bytes[6]=Ord('y')) and (Bytes[7]=Ord('p')) then Exit;
    if (Length(Bytes)>=12) and (Bytes[0]=$1A) and (Bytes[1]=$45) and (Bytes[2]=$DF) and (Bytes[3]=$A3) then Exit;
    if (Length(Bytes)>=12) and (Bytes[0]=0) and (Bytes[1]=0) and ((Bytes[2]=1) or ((Bytes[2]=0) and (Bytes[3]=1))) then Exit;
    Exit('Expected MP4, WebM or Annex B video');
  end;
  SetString(S,PAnsiChar(@Bytes[0]),Length(Bytes));
  if (FResponseKind='crowd') or (FResponseKind='walking') then begin
    L:=TStringList.Create; P:=1;
    try
      try
        if not VideoCsvRow(S,P,L) then Exit('Empty video CSV');
        if (FResponseKind='crowd') and ((L.IndexOf('lat')<0) or (L.IndexOf('lon')<0) or (L.IndexOf('videos')<0)) then Exit('Invalid video CSV');
        if (FResponseKind='walking') and ((L.IndexOf('lat/lon')<0) or (L.IndexOf('video_url')<0)) then Exit('Invalid video CSV');
      except Exit('Invalid video CSV') end;
    finally L.Free end;
    Exit;
  end;
  J:=nil;
  try
    try
      J:=ParsePhotoJson(S);
      if (J.JSONType<>jtObject) or (J.FindPath('error')<>nil) or (PhotoJsonString(J,'stat')='fail') then Exit('Video API error');
      if FSchema='catalog' then begin
        if (ArrayAt(J,'videos')=nil) and (ArrayAt(J,'shards')=nil) then Exit('Invalid video catalog schema');
      end else if (FSchema<>'') and (ArrayAt(J,FSchema)=nil) then Exit('Invalid video API schema');
    except Result:='Invalid video API JSON' end;
  finally J.Free end;
end;

procedure TVideoApiClient.PrepareResponse(Sender: TObject; const URL: string; var Bytes: TBytes);
var S: RawByteString;
begin
  if (FResponseKind<>'json') or (Length(Bytes)=0) then Exit;
  inherited PrepareResponse(Sender,URL,Bytes);
  if FVideoConfig.YouTubeKey='' then Exit;
  SetString(S,PAnsiChar(@Bytes[0]),Length(Bytes));
  S:=StringReplace(S,FVideoConfig.YouTubeKey,'[redacted]',[rfReplaceAll]);
  S:=StringReplace(S,URLParam(FVideoConfig.YouTubeKey),'[redacted]',[rfReplaceAll]);
  SetLength(Bytes,Length(S)); if S<>'' then Move(S[1],Bytes[0],Length(S));
end;

function TVideoApiClient.Resource(const URL, Key, Kind: string; Offline, Refresh: Boolean): TFetchResult;
begin
  FResponseKind:=Kind;
  if Kind='media' then FHttp.MaxResponseBytes:=FVideoConfig.MediaMaxBytes
  else FHttp.MaxResponseBytes:=32*1024*1024;
  Result:=Fetch(URL,Key,'',Offline,Refresh,(Kind='media') or (Kind='image') or (Kind='npy'));
end;

function TVideoApiClient.FailureStatus(const R: TFetchResult; Offline: Boolean): string;
begin
  if FHttp.Aborted then Result:='cancelled'
  else if Offline then Result:='cache_miss'
  else if (R.StatusCode=401) or (R.StatusCode=403) then Result:='access_denied_or_quota'
  else if R.StatusCode=429 then Result:='rate_limited'
  else if R.StatusCode=200 then Result:='invalid_or_oversized_response'
  else Result:='unavailable';
end;

function TVideoApiClient.JsonResource(const URL, Identity: string; Offline, Refresh: Boolean): TJSONObject;
var R: TFetchResult; S: RawByteString;
begin
  R:=Resource(URL,VideoKey('metadata',Identity),'json',Offline,Refresh);
  if not R.Success then raise Exception.Create(FailureStatus(R,Offline));
  SetString(S,PAnsiChar(@R.Data[0]),Length(R.Data)); Result:=TJSONObject(ParsePhotoJson(S));
end;

function TVideoApiClient.Accept(Item: TJSONObject; const Provider: string;
  const Box: TLatLonBox; RegionalRadiusM: Double; Videos: TJSONArray): Boolean;
var P: TJSONObject; A: TJSONArray; T,Lat,Lon: Double; Key,Id: string; I: Integer; InScope:Boolean;
begin
  Result:=False; P:=NormalizeVideoManifestRecord(Provider,Item); if P=nil then Exit;
  try
    if not VideoRecordMatches(P,Box,RegionalRadiusM,T) then Exit;
    Id:=P.Get('id','');
    for I:=0 to Videos.Count-1 do if PhotoJsonString(Videos.Items[I],'id')=Id then Exit;
    A:=ArrayAt(P,'track'); if A=nil then A:=ArrayAt(P,'frames');
    if FRouteScope.Enabled then begin
      InScope:=False;
      if A<>nil then begin
        for I:=0 to A.Count-1 do
          if Num(A[I],'latitude',Lat) and Num(A[I],'longitude',Lon) and
            (Lat>=Box.MinLat) and (Lat<=Box.MaxLat) and (Lon>=Box.MinLon) and (Lon<=Box.MaxLon) and
            FRouteScope.Contains(Lat,Lon) then begin InScope:=True; Num(A[I],'time_s',T); Break end;
      end else if P.Get('coordinate_role','')='locality' then begin
        { A city-level geotag is only a candidate, never proof of corridor coverage. }
        InScope:=True; P.Add('route_scope_match','regional_candidate_unverified');
      end else if Num(P,'latitude',Lat) and Num(P,'longitude',Lon) then InScope:=FRouteScope.Contains(Lat,Lon);
      if not InScope then Exit;
    end;
    if A<>nil then begin
      Key:=VideoKey('record',P.AsJSON);
      if not FHttp.Cache.Has(Key) then PutJsonKey(Key,P);
      P.Add('record_cache_key',Key); P.Add('camera_sample_count',A.Count); P.Add('matched_time_s',T);
      P.Delete('track'); P.Delete('frames');
    end;
    if P.Get('coordinate_role','')='locality' then P.Add('spatial_match','regional_candidate')
    else if P.Get('coordinate_role','')='camera_track' then P.Add('spatial_match','camera_samples_in_search_area')
    else P.Add('spatial_match','video_geotag_in_search_area');
    { A video geotag / locality is never silently upgraded to a frame pose. }
    P.Add('requires_visual_localization',P.Get('coordinate_role','')<>'camera_track');
    Videos.Add(P); P:=nil; Result:=True;
  finally P.Free end;
end;

function TVideoApiClient.SearchCSV(const Provider: string; const Box: TLatLonBox;
  RegionalRadiusM: Double; Limit: Integer; Offline, Refresh: Boolean; Videos: TJSONArray): TJSONObject;
var URL,Key,IndexKey,S,Id,CellText: string; R: TFetchResult; Index,P: TJSONObject;
  Rows,Header,Times,Ends,A,B,Segments: TJSONArray; Fields,Ids: TStringList;
  I,J,K,Offset,Added,Considered: Integer; Lat,Lon,StartSeconds,EndSeconds: Double; Q: TLatLonBox; D: TJSONData;
  function Field(const Name: string): string;
  var N: Integer;
  begin
    Result:=''; for N:=0 to Header.Count-1 do if Header.Strings[N]=Name then begin
      if N<Fields.Count then Result:=Fields[N]; Exit;
    end;
  end;
  function ArrayField(const Name: string): TJSONArray;
  var V: TJSONData;
  begin
    Result:=nil; V:=nil;
    try V:=ParsePhotoJson(Field(Name)); if V.JSONType=jtArray then begin Result:=TJSONArray(V); V:=nil end
    except { Optional segment timing must not discard an otherwise useful link. } end;
    V.Free;
  end;
begin
  if Provider='crowd' then URL:=FVideoConfig.CrowdURL else URL:=FVideoConfig.WalkingURL;
  Result:=TJSONObject.Create(['provider',Provider]); Key:=VideoKey('csv/'+Provider,URL);
  try
  R:=Resource(URL,Key,Provider,Offline,Refresh);
  if not R.Success then begin Result.Add('status',FailureStatus(R,Offline)); Exit end;
  SetString(S,PAnsiChar(@R.Data[0]),Length(R.Data));
  IndexKey:=VideoKey('csv-index/'+Provider,URL+'/'+MD5Print(MD5String(S)));
  Index:=ReadJsonKey(IndexKey);
  if Index=nil then begin
    Index:=BuildVideoCsvIndex(S,Provider);
    try PutJsonKey(IndexKey,Index) except Index.Free; raise end;
  end;
  Fields:=TStringList.Create; Ids:=TStringList.Create; Rows:=nil;
  Added:=0; Considered:=0;
  try
    Q:=Box.ExpandMeters(RegionalRadiusM); Rows:=VideoIndexRows(Index,Q); Header:=ArrayAt(Index,'header');
    for I:=0 to Rows.Count-1 do begin
      if FHttp.Aborted then raise EAbort.Create('cancelled');
      if Added>=Limit then Break;
      A:=TJSONArray(Rows.Items[I]); Offset:=A.Integers[0]; Lat:=A.Floats[2]; Lon:=A.Floats[3];
      if not VideoPointInside(TLatLon.Make(Lat,Lon),Box) and (Box.Center.DistanceTo(TLatLon.Make(Lat,Lon))>RegionalRadiusM) then Continue;
      VideoCsvRow(S,Offset,Fields); Inc(Considered); Times:=nil; Ends:=nil;
      if Provider='crowd' then begin
        CellText:=Trim(Field('videos')); Ids.StrictDelimiter:=True; Ids.Delimiter:=',';
        if (Length(CellText)>=2) and (CellText[1]='[') and (CellText[Length(CellText)]=']') then
          Ids.DelimitedText:=Copy(CellText,2,Length(CellText)-2) else Ids.Clear;
        Times:=ArrayField('start_time'); Ends:=ArrayField('end_time');
      end else begin Ids.Clear; Ids.Add(Field('video_url')) end;
      try
        for J:=0 to Ids.Count-1 do begin
          if Added>=Limit then Break;
          Id:=YouTubeId(Ids[J]); if Id='' then Continue;
          P:=TJSONObject.Create(['video_id',Id,'source_url','https://www.youtube.com/watch?v='+Id,
            'latitude',Lat,'longitude',Lon,'coordinate_role','locality','catalog_url',URL,
            'license','unknown','title',Field('video_title'),'locality',Field('locality')]);
          try
            Segments:=TJSONArray.Create; P.Add('segments',Segments);
            if (Times<>nil) and (Ends<>nil) and (J<Times.Count) and (J<Ends.Count) and
              (Times.Items[J].JSONType=jtArray) and (Ends.Items[J].JSONType=jtArray) then begin
              A:=TJSONArray(Times.Items[J]); B:=TJSONArray(Ends.Items[J]);
              for K:=0 to Min(A.Count,B.Count)-1 do begin
                D:=TJSONObject.Create; try
                  TJSONObject(D).Add('start',A.Items[K].Clone); TJSONObject(D).Add('end',B.Items[K].Clone);
                  if Num(D,'start',StartSeconds) and Num(D,'end',EndSeconds) and (StartSeconds>=0) and (EndSeconds>StartSeconds) then
                    Segments.Add(TJSONObject.Create(['start_s',StartSeconds,'end_s',EndSeconds]));
                finally D.Free end;
              end;
            end;
            if Accept(P,Provider,Box,RegionalRadiusM,Videos) then Inc(Added);
          finally P.Free end;
        end;
      finally Times.Free; Ends.Free end;
    end;
    if Added>=Limit then Result.Add('status','truncated') else Result.Add('status','complete');
    Result.Add('videos',Added); Result.Add('candidate_localities',Considered);
    Result.Add('index_rows',Index.Get('row_count',0)); Result.Add('metadata_cache_key',Key);
  finally Rows.Free; Fields.Free; Ids.Free; Index.Free end;
  except Result.Free; raise end;
end;

{$I Osm3dVideoProviders.inc}
{$I Osm3dVideoFrames.inc}

function TVideoApiClient.SearchVideos(Grid: TGeoTileGrid; const Tile: TGeoTileId;
  const Providers: string; PaddingM, RegionalRadiusM: Double; MaxPages, MaxVideos: Integer;
  Offline, Refresh: Boolean): TJSONObject;
var Box,Q: TLatLonBox; Boxes: array[0..1] of TLatLonBox; N,I,J,Before,Remaining: Integer;
  Names: TStringList; P,S,Seen: string; Videos,Reports,Parts: TJSONArray; Report,Part: TJSONObject;
begin
  if IsNan(PaddingM) or IsInfinite(PaddingM) or IsNan(RegionalRadiusM) or IsInfinite(RegionalRadiusM) or
    (PaddingM<0) or (PaddingM>500) or (RegionalRadiusM<0) or (RegionalRadiusM>50000) or
    (MaxPages<1) or (MaxPages>10) or (MaxVideos<1) or (MaxVideos>5000) then raise Exception.Create('Invalid video search limits');
  Box:=Grid.TileBox(Tile); Q:=Box.ExpandMeters(PaddingM);
  FRouteScope.LimitTo(Q); Q:=FRouteScope.QueryBox(Q);
  if Q.MinLat< -90 then Q.MinLat:=-90; if Q.MaxLat>90 then Q.MaxLat:=90;
  N:=1; Boxes[0]:=Q;
  if Q.MinLon< -180 then begin N:=2; Boxes[1]:=Q; Boxes[0].MinLon:=-180; Boxes[1].MinLon:=Q.MinLon+360; Boxes[1].MaxLon:=180 end
  else if Q.MaxLon>180 then begin N:=2; Boxes[1]:=Q; Boxes[0].MaxLon:=180; Boxes[1].MinLon:=-180; Boxes[1].MaxLon:=Q.MaxLon-360 end;
  Result:=TJSONObject.Create; Videos:=TJSONArray.Create; Reports:=TJSONArray.Create;
  Result.Add('schema_version',1); Result.Add('tile_id',Tile.ToString);
  Result.Add('tile_bbox',TJSONArray.Create([Box.MinLon,Box.MinLat,Box.MaxLon,Box.MaxLat]));
  Result.Add('grid_zoom',Grid.Zoom); Result.Add('grid_edge_px',Grid.EdgePx);
  Result.Add('videos',Videos); Result.Add('providers',Reports); Result.Add('regional_search_radius_m',RegionalRadiusM);
  Result.Add('route_scope',FRouteScope.Summary);
  if Q.IsEmpty then begin Result.Add('video_count',0); Result.Add('cancelled',False); Result.Add('stats',Stats); Exit end;
  Names:=TStringList.Create;
  try
    try
      S:=LowerCase(Trim(Providers)); if (S='all') or (S='auto') then S:=AllVideoProviders;
      Names.StrictDelimiter:=True; Names.Delimiter:=','; Names.DelimitedText:=S; Seen:=',';
      if Names.Count=0 then raise Exception.Create('At least one video provider is required');
      for I:=0 to Names.Count-1 do begin
        P:=Trim(Names[I]);
        if (P='') or (Pos(','+P+',',','+AllVideoProviders+',')=0) then raise Exception.Create('Unknown video provider');
        if Pos(','+P+',',Seen)>0 then Continue; Seen:=Seen+P+',';
        Report:=TJSONObject.Create(['provider',P]); Reports.Add(Report); Parts:=TJSONArray.Create; Report.Add('parts',Parts);
        S:='outside_coverage'; Before:=Videos.Count; Remaining:=MaxVideos;
        for J:=0 to N-1 do begin
          { Do not touch a regional dataset, its index URL, credentials, or media
            until this cheap coverage test has succeeded. }
          if not VideoProviderApplies(P,Boxes[J]) then Continue;
          if Remaining<=0 then begin S:='truncated'; Break end;
          if Assigned(FOnProgress) then FOnProgress('videos:'+P,I,Names.Count);
          try
            if (P='crowd') or (P='walking') then Part:=SearchCSV(P,Boxes[J],RegionalRadiusM,Remaining,Offline,Refresh,Videos)
            else if (P='flickr') or (P='youtube') then Part:=SearchRemote(P,Boxes[J],Max(1,MaxPages div N),Remaining,Offline,Refresh,Videos)
            else Part:=SearchCorpus(P,Boxes[J],Remaining,Offline,Refresh,Videos);
          except on E: Exception do begin
            if FHttp.Aborted then S:='cancelled'
            else if (E.Message='cache_miss') or (E.Message='credentials_required') or
              (E.Message='access_denied_or_quota') or (E.Message='rate_limited') or
              (E.Message='unavailable') or (E.Message='invalid_or_oversized_response') then S:=E.Message
            else S:='invalid_catalog_or_response';
            Part:=TJSONObject.Create(['status',S]);
          end end;
          Parts.Add(Part);
          if (S='outside_coverage') or (S='complete') then S:=Part.Get('status','unavailable');
          Remaining:=MaxVideos-(Videos.Count-Before);
          if FHttp.Aborted then Break;
        end;
        Report.Add('status',S); Report.Add('videos',Videos.Count-Before);
        if S='outside_coverage' then Report.Add('skipped_before_http',True);
        if FHttp.Aborted then Break;
      end;
      Result.Add('video_count',Videos.Count); Result.Add('cancelled',FHttp.Aborted); Result.Add('stats',Stats);
    except Result.Free; raise end;
  finally Names.Free end;
end;

end.
