unit Osm3dPhotoApi;

{$mode objfpc}{$H+}{$codepage UTF8}

{ Street imagery acquisition only. No inference or scene mutation.
  Each client belongs to one worker. All bytes use the existing HTTP cache;
  the cache may be shared with map workers, the fetcher configuration is not. }
interface

uses Classes, SysUtils, fpjson, Osm3dCache, Osm3dCacheHTTPFetcher,
  Osm3dGeoMath, Osm3dGeoTileGrid, Osm3dPhotoSources, Osm3dPhotoRouteScope, GameHttpClient;

type
  TPhotoApiConfig = record
    PanoramaxUrl, MapillaryUrl, MapillaryCoverageUrl, KartaViewUrl, MapillaryToken: string;
    Sources: TPhotoSourceConfig;
    TimeoutMs, MinRequestIntervalMs, MetadataMaxAgeHours: Integer;
  end;
  TPhotoApiProgress = procedure(const Stage: string; Completed, Total: Integer) of object;

  TPhotoApiClient = class
  protected
    FHttp: THTTPFetcherWithCache;
    FConfig: TPhotoApiConfig;
    FImageResponse: Boolean;
    FCoverageResponse:Boolean;
    FLastMetadataStatus:Integer;
    FMetadataProvider: string;
    FLastRequest: QWord;
    FNetworkRequests, FCacheHits: Integer;
    FOnProgress: TPhotoApiProgress;
    FRouteScope:TPhotoRouteScope;
    FPhotoReviews:TJSONArray;
    FFullPhotoDiscovery:Boolean;
    FSystemCancellation:TGameHttpCancellation;
    function SystemPublicImage(const URL:string;ConnectMs,ReadMs:Integer;
      Response:TStream;ResponseHeaders:TStrings;out Status:Integer):Boolean;
    function ValidateResponse(Sender: TObject; const URL: string;
      const Bytes: TBytes; const ContentType: string): string; virtual;
    procedure PrepareResponse(Sender: TObject; const URL: string; var Bytes: TBytes); virtual;
    procedure NetworkRequest(Sender: TObject; const URL, Method: string; BodySize: Integer);
    procedure CacheHit(Sender: TObject; const URL: string; SizeBytes: Int64);
    function Fetch(const URL, Key, Auth: string; Offline, Refresh, IsImage: Boolean;
      const AuthHeader: string = 'Authorization'): TFetchResult;
    function FetchJson(const URL, Key, Auth: string; Offline, Refresh: Boolean;
      out Json: TJSONObject; out Failure: TFetchResult): Boolean;
    function SearchProvider(const Provider: string; const Box: TLatLonBox;
      MaxPages, MaxPhotos: Integer; Offline, Refresh: Boolean; Photos: TJSONArray): TJSONObject;
    function SearchCatalog(const Provider: string; const Box: TLatLonBox;
      MaxPages, MaxPhotos: Integer; Offline, Refresh: Boolean; Photos: TJSONArray): TJSONObject;
    function LoadDetail(const Photo: TJSONObject; Offline, Refresh: Boolean): TJSONObject;
    function SearchMapillaryCoverage(const Box:TLatLonBox; MaxTiles,MaxPhotos:Integer;
      Offline,Refresh:Boolean;Photos:TJSONArray):TJSONObject;
    procedure RememberTileCatalog(Grid:TGeoTileGrid; const Tile:TGeoTileId; Catalog:TJSONObject);
    function LockTileCatalog(const Key:string):THandle;
    procedure UnlockTileCatalog(Handle:THandle);
  public
    constructor Create(Cache: TCacheBase; OwnsCache: Boolean; const Config: TPhotoApiConfig);
    destructor Destroy; override;
    procedure Cancel;
    procedure SetRouteScope(Value:TJSONData);
    procedure SetPhotoReviews(Value:TJSONArray);
    function SearchTile(Grid: TGeoTileGrid; const Tile: TGeoTileId;
      const Providers: string = 'all';
      PaddingM: Double = 80; MaxPages: Integer = 5; MaxPhotos: Integer = 500;
      Offline: Boolean = False; Refresh: Boolean = False;
      CompleteDiscovery:Boolean=False): TJSONObject;
    { Returned JSON owns a refreshed normalized photo, but never image bytes.
      Call ReadImage with its cache_key for MCP image content / preview. }
    function Download(const Photo: TJSONObject; const Size: string = 'preview';
      Offline: Boolean = False): TJSONObject;
    function ReadImage(const CacheKey: string): TFetchResult; virtual;
    function HasCachedImage(const CacheKey:string):Boolean;
    function CachedImageKey(Photo:TJSONObject):string;
    function CachedTileCatalog(Grid:TGeoTileGrid; const Tile:TGeoTileId):TJSONObject;
    function SequenceNeighbors(Photo:TJSONObject; BeforeCount,AfterCount,MaxPages:Integer;
      Offline,Refresh:Boolean; Grid:TGeoTileGrid=nil):TJSONObject;
    function AcquireMapillary(Grid:TGeoTileGrid;const Tile:TGeoTileId;
      const Focus:TLatLon;Photo:TJSONObject;MaxDownloads,BeforeCount,AfterCount:Integer;
      Offline,Refresh:Boolean):TJSONObject;
    function AcquireTile(Grid:TGeoTileGrid;const Tile:TGeoTileId;
      const Focus:TLatLon;Photo:TJSONObject;MaxDownloads,BeforeCount,AfterCount:Integer;
      Offline,Refresh:Boolean;const Mode,Providers:string;
      MaxPages,MaxCandidates:Integer):TJSONObject;
    function Stats: TJSONObject;
    property OnProgress: TPhotoApiProgress read FOnProgress write FOnProgress;
  end;

function DefaultPhotoApiConfig: TPhotoApiConfig;
function NormalizeStreetPhoto(const Provider: string; Item: TJSONObject;
  const CatalogUrl, MetadataKey: string): TJSONObject;
function PhotoJsonString(J: TJSONData; const Path: string; const Default: string = ''): string;
{ Shared with video acquisition; transport, cancellation and counters remain
  in the same client implementation. }
function Num(J: TJSONData; const Path: string; out Value: Double): Boolean;
function FloatText(V: Double): string;
function URLParam(const S: string): string;
function HttpURL(const S: string): Boolean;
function ArrayAt(J: TJSONData; const Path: string): TJSONArray;

implementation

uses {$IFDEF MSWINDOWS}Windows,{$ENDIF} Math, DateUtils, jsonparser, URIParser, MD5, Base64,Osm3dMapillaryCoverage,
  Osm3dPhotoRelevance;

var PhotoCatalogCriticalSection:TRTLCriticalSection;

const
  { Graph Image fields, not MVT properties. is_pano belongs to coverage tiles;
    requesting it from Graph can reject the entire metadata request.
    https://mapillary.github.io/mapillary-python-sdk/docs/mapillary.config.api/mapillary.config.api.entities/ }
  MAPILLARY_IMAGE_FIELDS = 'id,geometry,computed_geometry,compass_angle,computed_compass_angle,captured_at,camera_type,width,height,sequence,creator,thumb_256_url,thumb_2048_url,thumb_original_url';

function PhotoJsonString(J: TJSONData; const Path: string; const Default: string): string;
var V: TJSONData;
begin
  Result := Default;
  if J = nil then Exit;
  V := J.FindPath(Path);
  if (V <> nil) and (V.JSONType in [jtString, jtNumber, jtBoolean]) then Result := V.AsString;
end;

function Num(J: TJSONData; const Path: string; out Value: Double): Boolean;
var V: TJSONData; F: TFormatSettings;
begin
  Result := False; Value := 0;
  if J = nil then Exit;
  V := J.FindPath(Path);
  if (V = nil) or not (V.JSONType in [jtNumber, jtString]) then Exit;
  F := DefaultFormatSettings; F.DecimalSeparator := '.'; F.ThousandSeparator := #0;
  Result := TryStrToFloat(V.AsString, Value, F);
  if Result then Result := not IsNan(Value) and not IsInfinite(Value);
end;

function FloatText(V: Double): string;
var F: TFormatSettings;
begin
  F := DefaultFormatSettings; F.DecimalSeparator := '.'; F.ThousandSeparator := #0;
  Result := FormatFloat('0.00000000', V, F);
end;

function URLParam(const S: string): string;
const Hex: string = '0123456789ABCDEF';
var I: Integer; C: Byte;
begin
  Result := '';
  for I := 1 to Length(S) do
  begin
    C := Ord(S[I]);
    if S[I] in ['a'..'z','A'..'Z','0'..'9','-','_','.','~'] then Result := Result + S[I]
    else Result := Result + '%' + Hex[(C shr 4)+1] + Hex[(C and 15)+1];
  end;
end;

function HttpURL(const S: string): Boolean;
var U: TURI;
begin
  U := ParseURI(S, False);
  Result := (SameText(U.Protocol, 'https') or SameText(U.Protocol, 'http')) and
    (U.Host <> '') and (U.Username = '') and (U.Password = '');
end;

function DecodeURLElement(const S: string): string;
var I,V: Integer;
begin
  Result:=''; I:=1;
  while I<=Length(S) do begin
    if (S[I]='%') and (I+2<=Length(S)) and TryStrToInt('$'+Copy(S,I+1,2),V) then
    begin Result:=Result+Chr(V); Inc(I,3) end
    else begin Result:=Result+S[I]; Inc(I) end;
  end;
end;

function SameOrigin(const A, B: string): Boolean;
var U, V: TURI;
begin
  U := ParseURI(A, False); V := ParseURI(B, False);
  Result := HttpURL(B) and SameText(U.Protocol, V.Protocol) and
    SameText(U.Host, V.Host) and (U.Port = V.Port);
end;

function KeyFor(const Kind, URL: string): string;
begin
  Result := 'photo-api/v1/' + Kind + '/' + MD5Print(MD5String(URL));
end;

function Link(J: TJSONData; const Rel: string): string;
var A, E: TJSONData; I: Integer;
begin
  Result := ''; if J = nil then Exit;
  A := J.FindPath('links');
  if (A = nil) or (A.JSONType <> jtArray) then Exit;
  for I := 0 to A.Count-1 do
  begin
    E := A.Items[I];
    if PhotoJsonString(E, 'rel') = Rel then Exit(PhotoJsonString(E, 'href'));
  end;
end;

function ArrayAt(J: TJSONData; const Path: string): TJSONArray;
var V: TJSONData;
begin
  Result := nil; if J = nil then Exit;
  V := J.FindPath(Path);
  if (V <> nil) and (V.JSONType = jtArray) then Result := TJSONArray(V);
end;

function DefaultPhotoApiConfig: TPhotoApiConfig;
begin
  Result := Default(TPhotoApiConfig);
  Result.PanoramaxUrl := 'https://api.panoramax.xyz/api';
  Result.MapillaryUrl := 'https://graph.mapillary.com';
  Result.MapillaryCoverageUrl := 'https://tiles.mapillary.com/maps/vtp/mly1_public/2';
  Result.KartaViewUrl := 'https://api.openstreetcam.org/2.0';
  Result.Sources := DefaultPhotoSourceConfig;
  Result.TimeoutMs := 15000;
  Result.MinRequestIntervalMs := 400;
  Result.MetadataMaxAgeHours := 168;
  Result.MapillaryToken := PhotoCredential('REZVIVO_MAPILLARY_TOKEN');
end;

function NormalizeStreetPhoto(const Provider: string; Item: TJSONObject;
  const CatalogUrl, MetadataKey: string): TJSONObject;
var Id, Seq, Date, Author, License, LicenseURL, Detail, Page, Projection: string;
  Thumb, Preview, Original: string;
  Lat, Lon, Heading, V: Double; HasHeading: Boolean;
  W, H: Integer; A: TJSONArray; P: TJSONData; D: TDateTime;
begin
  Result := nil; W := 0; H := 0; HasHeading := False; Heading := 0;
  Projection := 'unknown'; LicenseURL := ''; Detail := ''; Page := '';
  if Provider = 'panoramax' then
  begin
    Id := PhotoJsonString(Item, 'id'); Seq := PhotoJsonString(Item, 'collection');
    if not Num(Item, 'geometry.coordinates[0]', Lon) or
       not Num(Item, 'geometry.coordinates[1]', Lat) then Exit;
    Date := PhotoJsonString(Item, 'properties.datetime');
    Author := PhotoJsonString(Item, 'properties.geovisio:producer');
    A := ArrayAt(Item, 'providers');
    if (Author = '') and (A <> nil) and (A.Count > 0) then Author := PhotoJsonString(A.Items[0], 'name');
    License := PhotoJsonString(Item, 'properties.license'); LicenseURL := Link(Item, 'license');
    HasHeading := Num(Item, 'properties.view:azimuth', Heading);
    Thumb := PhotoJsonString(Item, 'assets.thumb.href');
    Preview := PhotoJsonString(Item, 'assets.sd.href');
    Original := PhotoJsonString(Item, 'assets.hd.href');
    Detail := Link(Item, 'self');
    Page := 'https://panoramax.fr/?pic=' + URLParam(Id);
    if Num(Item, 'properties.pers:interior_orientation.sensor_array_dimensions[0]', V) then W := Round(V);
    if Num(Item, 'properties.pers:interior_orientation.sensor_array_dimensions[1]', V) then H := Round(V);
    Projection := LowerCase(PhotoJsonString(Item, 'properties.pers:interior_orientation.camera_type'));
    if Projection = '' then begin
      P := Item.FindPath('properties.exif');
      if (P <> nil) and (P.JSONType = jtObject) then
        Projection := LowerCase(TJSONObject(P).Get('Exif.GPano.ProjectionType', ''));
    end;
    { Size ratio alone is not sufficient evidence of an equirectangular panorama. }
    if Projection = '' then Projection := 'unknown';
  end else if Provider = 'mapillary' then
  begin
    Id := PhotoJsonString(Item, 'id'); Seq := PhotoJsonString(Item, 'sequence');
    if not Num(Item, 'computed_geometry.coordinates[0]', Lon) or
       not Num(Item, 'computed_geometry.coordinates[1]', Lat) then
      if not Num(Item, 'geometry.coordinates[0]', Lon) or
         not Num(Item, 'geometry.coordinates[1]', Lat) then Exit;
    Date := '';
    if Num(Item, 'captured_at', V) and (V > 0) then
    begin D := UnixToDateTime(Trunc(V / 1000), True); Date := FormatUtcIso8601(D) end;
    Author := PhotoJsonString(Item, 'creator.username');
    License := 'CC-BY-SA-4.0'; LicenseURL := 'https://creativecommons.org/licenses/by-sa/4.0/';
    HasHeading := Num(Item, 'computed_compass_angle', Heading);
    if not HasHeading then HasHeading := Num(Item, 'compass_angle', Heading);
    Thumb := PhotoJsonString(Item, 'thumb_256_url'); Preview := PhotoJsonString(Item, 'thumb_2048_url');
    Original := PhotoJsonString(Item, 'thumb_original_url');
    Detail := CatalogUrl + '/' + URLParam(Id);
    Page := 'https://www.mapillary.com/app/?pKey=' + URLParam(Id) + '&focus=photo';
    if Num(Item, 'width', V) then W := Round(V);
    if Num(Item, 'height', V) then H := Round(V);
    P := Item.Find('is_pano');
    if (P <> nil) and (P.JSONType = jtBoolean) then
      if P.AsBoolean then Projection := 'equirectangular' else Projection := 'perspective';
    if Projection = 'unknown' then begin
      Projection := LowerCase(PhotoJsonString(Item, 'camera_type', 'unknown'));
      if Projection = 'spherical' then Projection := 'equirectangular';
    end;
  end else if Provider = 'kartaview' then
  begin
    Id := PhotoJsonString(Item, 'id'); Seq := PhotoJsonString(Item, 'sequenceId');
    if not Num(Item, 'lat', Lat) or not Num(Item, 'lng', Lon) then Exit;
    Date := PhotoJsonString(Item, 'dateAdded');
    Author := PhotoJsonString(Item, 'username');
    License := PhotoJsonString(Item, 'license'); { Do not invent missing attribution metadata. }
    HasHeading := Num(Item, 'heading', Heading);
    Thumb := PhotoJsonString(Item, 'fileurlThumb');
    Preview := PhotoJsonString(Item, 'fileurlLTh'); Original := PhotoJsonString(Item, 'fileurl');
    Detail := CatalogUrl + '/photo/' + URLParam(Id);
    Page := 'https://kartaview.org/details/' + URLParam(Seq) + '/' + PhotoJsonString(Item, 'sequenceIndex', '0');
  end else Exit;
  if (Id = '') or (Lat < -90) or (Lat > 90) or (Lon < -180) or (Lon > 180) then Exit;
  if not HttpURL(Thumb) then Thumb := '';
  if not HttpURL(Preview) then Preview := '';
  if not HttpURL(Original) then Original := '';
  if Preview = '' then Preview := Original;
  if Thumb = '' then Thumb := Preview;
  if not HttpURL(Detail) then Detail := '';
  Result := TJSONObject.Create;
  Result.Add('id', Provider + ':' + Id); Result.Add('provider', Provider); Result.Add('image_id', Id);
  Result.Add('sequence_id', Seq); Result.Add('latitude', Lat); Result.Add('longitude', Lon);
  if HasHeading then begin
    Heading := Heading - Floor(Heading / 360) * 360;
    Result.Add('heading_deg', Heading);
  end else Result.Add('heading_deg', TJSONNull.Create);
  Result.Add('projection', Projection); Result.Add('captured_at', Date); Result.Add('author', Author);
  Result.Add('license', License); Result.Add('license_url', LicenseURL);
  Result.Add('source_url', Page); Result.Add('detail_url', Detail); Result.Add('catalog_url', CatalogUrl);
  Result.Add('metadata_cache_key', MetadataKey);
  Result.Add('width', W); Result.Add('height', H);
  Result.Add('coordinate_role','camera'); Result.Add('purpose','street_reference');
  Result.Add('urls', TJSONObject.Create(['thumbnail', Thumb, 'preview', Preview, 'original', Original]));
  { Keep additional camera data in the cached source, without copying huge EXIF
    blocks into every MCP response. Missing orientation is explicitly unknown. }
end;

constructor TPhotoApiClient.Create(Cache: TCacheBase; OwnsCache: Boolean; const Config: TPhotoApiConfig);
begin
  inherited Create; FConfig := Config;
  FRouteScope:=TPhotoRouteScope.Create(nil);
  FSystemCancellation:=TGameHttpCancellation.Create;
  FHttp := THTTPFetcherWithCache.Create(Cache, OwnsCache);
  FHttp.TimeoutMs := Config.TimeoutMs; FHttp.MaxRetries := 2;
  FHttp.UserAgent := 'REZVIVOPhotoApi/1.0 (+https://rezvivo.com)';
  FHttp.MaxResponseBytes := 32 * 1024 * 1024;
  FHttp.OnValidateResponse := @ValidateResponse;
  FHttp.OnPrepareResponse := @PrepareResponse;
  FHttp.OnNetworkRequest := @NetworkRequest; FHttp.OnCacheHit := @CacheHit;
  FHttp.PublicGetTransport:=@SystemPublicImage;
end;

destructor TPhotoApiClient.Destroy;
begin FPhotoReviews.Free;FRouteScope.Free; FHttp.Free;FSystemCancellation.Free; inherited end;

function TPhotoApiClient.SystemPublicImage(const URL:string;ConnectMs,ReadMs:Integer;
  Response:TStream;ResponseHeaders:TStrings;out Status:Integer):Boolean;
begin
  Result:=FImageResponse;Status:=0;if not Result then Exit;
  { Shared game transport respects configured system/env proxy and HTTPS
    CONNECT on Windows; other platforms retain its existing FPC fallback.
    Public images carry no API Authorization header. The common fetcher
    still owns bounds, retries, cache keys and JPEG/PNG validation. }
  GameHttpRequest('GET',URL,nil,nil,ConnectMs,ReadMs,Response,Status,
    FSystemCancellation,ResponseHeaders);
end;

procedure TPhotoApiClient.SetRouteScope(Value:TJSONData);
var Scope:TPhotoRouteScope;
begin
  Scope:=TPhotoRouteScope.Create(Value); FRouteScope.Free; FRouteScope:=Scope;
end;

procedure TPhotoApiClient.Cancel;
begin FHttp.AbortAllRequests;FSystemCancellation.Cancel end;

procedure TPhotoApiClient.SetPhotoReviews(Value:TJSONArray);
begin
  FreeAndNil(FPhotoReviews);
  if Value<>nil then FPhotoReviews:=TJSONArray(Value.Clone);
end;

procedure TPhotoApiClient.NetworkRequest(Sender: TObject; const URL, Method: string; BodySize: Integer);
begin
  while (FLastRequest <> 0) and (GetTickCount64 - FLastRequest < QWord(Max(0, FConfig.MinRequestIntervalMs))) do
  begin if FHttp.Aborted then raise EAbort.Create('cancelled'); Sleep(20) end;
  FLastRequest := GetTickCount64; Inc(FNetworkRequests);
end;

procedure TPhotoApiClient.CacheHit(Sender: TObject; const URL: string; SizeBytes: Int64);
begin Inc(FCacheHits) end;

function TPhotoApiClient.ValidateResponse(Sender: TObject; const URL: string;
  const Bytes: TBytes; const ContentType: string): string;
var J: TJSONData; S: RawByteString; U: TURI; N: Double;
begin
  Result := '';
  if FCoverageResponse then begin
    if (Length(Bytes)>32*1024*1024) or ((Length(Bytes)>0) and (Bytes[0]=Ord('{'))) then
      Exit('Invalid Mapillary coverage response');
    Exit;
  end;
  if (Length(Bytes) = 0) or (Length(Bytes) > FHttp.MaxResponseBytes) then Exit('Empty or oversized photo API response');
  if FImageResponse then
  begin
    if (Length(Bytes) >= 20) and (Bytes[0] = $FF) and (Bytes[1] = $D8) and (Bytes[2] = $FF) and
      (Bytes[High(Bytes)-1] = $FF) and (Bytes[High(Bytes)] = $D9) then Exit;
    if (Length(Bytes) >= 45) and (Bytes[0] = $89) and (Bytes[1] = $50) and
      (Bytes[2] = $4E) and (Bytes[3] = $47) and
      (Bytes[Length(Bytes)-8] = Ord('I')) and (Bytes[Length(Bytes)-7] = Ord('E')) and
      (Bytes[Length(Bytes)-6] = Ord('N')) and (Bytes[Length(Bytes)-5] = Ord('D')) then Exit;
    Exit('Expected a JPEG or PNG image, not an HTML/error response');
  end;
  SetString(S, PAnsiChar(@Bytes[0]), Length(Bytes));
  try
    J := ParsePhotoJson(S);
    try
      if J.JSONType <> jtObject then Exit('Expected a photo API JSON object');
      if J.FindPath('error') <> nil then Exit('Photo API returned an error object');
      if (FMetadataProvider='flickr') and (PhotoJsonString(J,'stat')<>'ok') then Exit('Photo provider denied access');
      if (FMetadataProvider='flickr') and (Pos('method=flickr.photos.search',URL)>0) and
        (ArrayAt(J,'photos.photo')=nil) then Exit('Invalid photo search response schema');
      if (FMetadataProvider='flickr') and (Pos('method=flickr.photos.licenses.getInfo',URL)>0) and
        (ArrayAt(J,'licenses.license')=nil) then Exit('Invalid photo license response schema');
      if (FMetadataProvider='commons') and (ArrayAt(J,'query.pages')=nil) and
        ((J.FindPath('batchcomplete')=nil) or (J.FindPath('query')<>nil)) then Exit('Invalid photo search response schema');
      if (FMetadataProvider='wikidata') and (ArrayAt(J,'results.bindings')=nil) then Exit('Invalid photo search response schema');
      if (FMetadataProvider='gbif') and (ArrayAt(J,'results')=nil) then Exit('Invalid photo search response schema');
      if (FMetadataProvider='geograph') and (ArrayAt(J,'items')=nil) then Exit('Invalid photo search response schema');
      if (FMetadataProvider='citylens') and (ArrayAt(J,'frames')=nil) then Exit('Invalid photo search response schema');
      if (FMetadataProvider='cyclomedia') and (ArrayAt(J,'features')=nil) then Exit('Invalid photo search response schema');
      U := ParseURI(URL,False);
      if (SameOrigin(FConfig.PanoramaxUrl,URL) and (U.Document='search') and (ArrayAt(J,'features')=nil)) or
        (SameOrigin(FConfig.MapillaryUrl,URL) and (U.Document='images') and (ArrayAt(J,'data')=nil)) then
        Exit('Invalid photo search response schema');
      if SameOrigin(FConfig.KartaViewUrl,URL) and Num(J,'status.apiCode',N) and (N>=400) then
        Exit('Photo provider denied access');
      if (Pos(FConfig.KartaViewUrl+'/photo/',URL)=1) and (ArrayAt(J,'result.data')=nil) then
        Exit('Invalid photo search response schema');
    finally J.Free end;
  except on E: Exception do Result := 'Invalid photo API JSON' end;
end;

procedure TPhotoApiClient.PrepareResponse(Sender: TObject; const URL: string; var Bytes: TBytes);
var S: RawByteString; J, Paging: TJSONData;
  procedure Redact(const Secret: string);
  begin
    if Secret='' then Exit;
    S:=StringReplace(S,Secret,'[redacted]',[rfReplaceAll]);
    S:=StringReplace(S,URLParam(Secret),'[redacted]',[rfReplaceAll]);
  end;
begin
  if FImageResponse or FCoverageResponse or (Length(Bytes) = 0) then Exit;
  if FMetadataProvider='geograph' then begin
    try Bytes:=ConvertGeographFeed(Bytes) except { Validator rejects non-JSON. } end;
  end;
  SetString(S, PAnsiChar(@Bytes[0]), Length(Bytes));
  J := nil;
  try
    J := ParsePhotoJson(S); Paging := J.FindPath('paging');
    if (Paging <> nil) and (Paging.JSONType = jtObject) then
    begin
      { Only the fact that a next page exists is needed. Build its URL from
        the cursor ourselves; Graph may echo access_token in paging links. }
      if PhotoJsonString(Paging, 'next') <> '' then TJSONObject(Paging).Strings['next'] := 'available';
      TJSONObject(Paging).Delete('previous');
    end;
    S := J.AsJSON;
    Redact(FConfig.MapillaryToken); Redact(FConfig.Sources.FlickrKey);
    Redact(FConfig.Sources.GeographKey); Redact(FConfig.Sources.CityLensKey);
    Redact(FConfig.Sources.CyclomediaKey); Redact(FConfig.Sources.CyclomediaPassword);
    SetLength(Bytes, Length(S)); if S <> '' then Move(S[1], Bytes[0], Length(S));
  except { The validator reports malformed JSON. }
  end;
  J.Free;
end;

function TPhotoApiClient.Fetch(const URL, Key, Auth: string; Offline, Refresh, IsImage: Boolean;
  const AuthHeader: string): TFetchResult;
var Meta: TCacheMetadata; Bypass: Boolean;
begin
  FImageResponse := IsImage;
  FHttp.AuthenticationHeaderName := AuthHeader;
  if FHttp.Aborted then Exit(TFetchResult.Failure('cancelled'));
  if not HttpURL(URL) then Exit(TFetchResult.Failure('Invalid photo resource URL'));
  if Offline then begin
    Result := FHttp.GetCachedByKey(URL, Key);
    if Result.Success then Inc(FCacheHits);
    Exit;
  end;
  Bypass := Refresh;
  if not IsImage and (FHttp.Cache <> nil) then
    Bypass := Bypass or ((FConfig.MetadataMaxAgeHours > 0) and FHttp.Cache.GetMetadata(Key, Meta) and
      (Meta.FetchedAt > 0) and (Now - Meta.FetchedAt > FConfig.MetadataMaxAgeHours / 24));
  { A failed/cancelled refresh keeps the last validated cache entry. }
  Result := FHttp.GetUrlWithKey(URL, Key, Auth, Min(8000, FConfig.TimeoutMs), 0, Bypass);
end;

function TPhotoApiClient.FetchJson(const URL, Key, Auth: string; Offline, Refresh: Boolean;
  out Json: TJSONObject; out Failure: TFetchResult): Boolean;
var S: RawByteString;
begin
  Json := nil; Failure := Fetch(URL, Key, Auth, Offline, Refresh, False);
  Result := Failure.Success; if not Result then Exit;
  SetString(S, PAnsiChar(@Failure.Data[0]), Length(Failure.Data));
  Json := TJSONObject(ParsePhotoJson(S));
end;

{$I Osm3dPhotoCatalogs.inc}

function TPhotoApiClient.SearchProvider(const Provider: string; const Box: TLatLonBox;
  MaxPages, MaxPhotos: Integer; Offline, Refresh: Boolean; Photos: TJSONArray): TJSONObject;
const Fields = MAPILLARY_IMAGE_FIELDS;
var Base, URL, NextURL, ResolvedURL, Auth, Key, Cursor, Id, State: string;
  J, P,Coverage: TJSONObject; Items: TJSONArray; I, Page, Added, Rejected: Integer;
  R: TFetchResult; Seen, Pages: TStringList; More,GraphSample,LimitHit: Boolean; X, Y: Double;
begin
  FMetadataProvider:='';
  if Pos(','+Provider+',',',panoramax,mapillary,kartaview,')=0 then
    Exit(SearchCatalog(Provider,Box,MaxPages,MaxPhotos,Offline,Refresh,Photos));
  Result := TJSONObject.Create(['provider', Provider]);
  Base := ''; Auth := ''; State := 'complete'; Added := 0; Rejected := 0; Page := 0; More := False;
  GraphSample:=False;
  if Provider = 'panoramax' then Base := FConfig.PanoramaxUrl
  else if Provider = 'mapillary' then begin
    Base := FConfig.MapillaryUrl;
    if FConfig.MapillaryToken <> '' then Auth := 'OAuth ' + FConfig.MapillaryToken
    else if not Offline then begin Result.Add('status','credentials_required'); Result.Add('complete',False); Exit end;
  end else if Provider = 'kartaview' then Base := FConfig.KartaViewUrl
  else raise Exception.Create('Unknown photo provider');
  if Provider = 'panoramax' then URL := Base + '/search?bbox=' + FloatText(Box.MinLon)+','+
    FloatText(Box.MinLat)+','+FloatText(Box.MaxLon)+','+FloatText(Box.MaxLat)+'&limit=100'
  else if Provider = 'mapillary' then URL := Base + '/images?fields=' + Fields + '&bbox=' +
    FloatText(Box.MinLon)+','+FloatText(Box.MinLat)+','+FloatText(Box.MaxLon)+','+FloatText(Box.MaxLat)+'&limit=100'
  else URL := Base + '/photo/?bbTopLeft=' + FloatText(Box.MaxLat)+','+FloatText(Box.MinLon)+
    '&bbBottomRight='+FloatText(Box.MinLat)+','+FloatText(Box.MaxLon)+'&ipp=100&page=1';
  Seen := TStringList.Create; Pages := TStringList.Create;
  Seen.Sorted := True; Seen.Duplicates := dupIgnore;
  try
    for I := 0 to Photos.Count-1 do Seen.Add(PhotoJsonString(Photos.Items[I], 'id'));
    while (URL <> '') and (Page < MaxPages) and (Added < MaxPhotos) do
    begin
      if FHttp.Aborted then begin State := 'cancelled'; Break end;
      if Pages.IndexOf(URL) >= 0 then begin State := 'invalid_pagination'; Break end;
      Pages.Add(URL); Key := KeyFor(Provider + '/search', URL);
      if not FetchJson(URL, Key, Auth, Offline, Refresh, J, R) then
      begin
        if FHttp.Aborted then State := 'cancelled'
        else if Offline then State := 'cache_miss'
        else if R.StatusCode = 429 then State := 'rate_limited'
        else if R.ErrorMsg = 'Photo provider denied access' then State := 'access_denied'
        { Mapillary code100/HTTP400 also covers bad fields, unavailable objects
          and invalid requests. It cannot establish the token's Read scope. }
        else if (Provider = 'mapillary') and (R.StatusCode = 400) then State := 'request_rejected'
        else if (R.StatusCode = 400) or (R.StatusCode = 401) or (R.StatusCode = 403) then State := 'access_denied'
        else if R.StatusCode = 200 then State := 'invalid_response'
        else State := 'unavailable';
        Result.Add('http_status', R.StatusCode);
        { Exception text can contain signed URLs or provider details. Return
          stable diagnostics; preserve no tokens in logs or manifests. }
        Result.Add('error', State);
        Break;
      end;
      Inc(Page); NextURL := ''; Cursor := '';
      try
        if Provider = 'panoramax' then Items := ArrayAt(J, 'features')
        else if Provider = 'mapillary' then Items := ArrayAt(J, 'data')
        else Items := ArrayAt(J, 'result.data');
        if Items = nil then
        begin
          State := 'invalid_response';
          if FHttp.Cache <> nil then FHttp.Cache.Delete(Key);
          Break;
        end;
        for I := 0 to Items.Count-1 do
        begin
          if Items.Items[I].JSONType <> jtObject then begin Inc(Rejected); Continue end;
          P := NormalizeStreetPhoto(Provider, TJSONObject(Items.Items[I]), Base, Key);
          if P = nil then begin Inc(Rejected); Continue end;
          Id := P.Strings['id']; X := P.Floats['longitude']; Y := P.Floats['latitude'];
          if (X < Box.MinLon) or (X > Box.MaxLon) or (Y < Box.MinLat) or (Y > Box.MaxLat) then
          begin P.Free; Inc(Rejected); Continue end;
          if not FRouteScope.Contains(Y,X) then begin P.Free; Inc(Rejected); Continue end;
          if Seen.IndexOf(Id) >= 0 then begin P.Free; Continue end;
          if Added >= MaxPhotos then begin P.Free; More := True; Break end;
          Seen.Add(Id); Photos.Add(P); Inc(Added);
        end;
        if Provider = 'panoramax' then NextURL := Link(J, 'next')
        else if Provider = 'mapillary' then
        begin
          if PhotoJsonString(J, 'paging.next') <> '' then Cursor := PhotoJsonString(J, 'paging.cursors.after');
          if (PhotoJsonString(J, 'paging.next') <> '') and (Cursor = '') then
          begin State := 'invalid_pagination'; Break end;
          if Cursor <> '' then NextURL := Base + '/images?fields=' + Fields + '&bbox=' +
            FloatText(Box.MinLon)+','+FloatText(Box.MinLat)+','+FloatText(Box.MaxLon)+','+FloatText(Box.MaxLat)+
            '&limit=100&after='+URLParam(Cursor);
        end else if Items.Count >= 100 then
          NextURL := Base + '/photo/?bbTopLeft='+FloatText(Box.MaxLat)+','+FloatText(Box.MinLon)+
            '&bbBottomRight='+FloatText(Box.MinLat)+','+FloatText(Box.MaxLon)+'&ipp=100&page='+IntToStr(Page+1);
        if NextURL <> '' then
        begin
          if not ResolveRelativeURI(URL, NextURL, ResolvedURL) then begin State := 'invalid_pagination'; Break end;
          NextURL := ResolvedURL;
          if not SameOrigin(Base, NextURL) then begin State := 'invalid_pagination'; Break end;
        end;
        { Spatial Graph searches may return exactly the requested limit with
          no cursor. That is a sample, not evidence that the tile is exhausted. }
        if (Provider='mapillary') and (Items.Count>=100) and (NextURL='') then GraphSample:=True;
      finally J.Free end;
      URL := NextURL;
      if Assigned(FOnProgress) then FOnProgress('search:' + Provider, Page, MaxPages);
    end;
    { A URL remains set after a failed request too. Only an otherwise valid
      traversal stopped by our caps establishes a local discovery limit. }
    More := More or ((URL <> '') and (State='complete'));
    LimitHit:=(State='complete') and More;
    if (State = 'complete') and More then State := 'truncated';
    if (State='complete') and GraphSample then State:='sample_limited';
    Result.Add('status', State); Result.Add('complete', State = 'complete');
    Result.Add('pages', Page); Result.Add('photos', Added); Result.Add('rejected', Rejected);
    Result.Add('has_more', More or GraphSample);
    Result.Add('limit_reached',LimitHit);
    if Provider='mapillary' then Result.Add('graph_sample_limited',GraphSample);
    Result.Add('discovery_complete',State='complete');
    if (Provider='mapillary') and (FFullPhotoDiscovery or (Added=0)) and
      ((State='complete') or (State='cache_miss') or
       (FFullPhotoDiscovery and ((State='truncated') or (State='sample_limited')))) then begin
      Coverage:=SearchMapillaryCoverage(Box,Min(4096,MaxPages),Max(0,MaxPhotos-Added),Offline,Refresh,Photos);
      Result.Strings['status']:=Coverage.Get('status','unavailable');Result.Booleans['complete']:=False;
      Result.Integers['photos']:=Added+Coverage.Get('photos',0);Result.Add('graph_status',State);
      Result.Booleans['discovery_complete']:=Coverage.Get('complete',False) and
        ((State='complete') or (State='cache_miss') or (State='sample_limited'));
      Result.Add('coverage',Coverage);
      Result.Booleans['has_more']:=More or Coverage.Get('has_more',False);
      Result.Booleans['limit_reached']:=LimitHit or Coverage.Get('limit_reached',False);
      if (Coverage.Get('status','')='coverage_empty') and (Added=0) then Result.Booleans['complete']:=True;
      if (Coverage.Get('status','')='coverage_empty') and (Added>0) then begin
        Result.Strings['status']:=State;Result.Booleans['complete']:=State='complete';
      end;
    end;
  finally Pages.Free; Seen.Free end;
end;

function TPhotoApiClient.SearchTile(Grid: TGeoTileGrid; const Tile: TGeoTileId;
  const Providers: string; PaddingM: Double; MaxPages, MaxPhotos: Integer;
  Offline, Refresh, CompleteDiscovery: Boolean): TJSONObject;
var Box, SearchBox: TLatLonBox; Photos, Reports, Parts: TJSONArray; L: TStringList;
  I,K,N,PagesLeft,PhotosLeft,PartPages: Integer; P,Part: TJSONObject; Seen,Selection,State: string;
  Boxes: array[0..1] of TLatLonBox; Inside: Boolean;
begin
  if (Grid = nil) or (PaddingM < 0) or (PaddingM > 500) or IsNan(PaddingM) or IsInfinite(PaddingM) then
    raise Exception.Create('Invalid photo search tile or padding (0..500 m)');
  if (MaxPages < 1) or (MaxPages > 500) or (MaxPhotos < 1) or (MaxPhotos > 50000) then
    raise Exception.Create('Photo search limits: 1..500 pages, 1..50000 photos per provider');
  FFullPhotoDiscovery:=CompleteDiscovery;
  Box := Grid.TileBox(Tile); SearchBox := Box.ExpandMeters(PaddingM);
  FRouteScope.LimitTo(SearchBox); SearchBox:=FRouteScope.QueryBox(SearchBox);
  { Keep doubles unchanged for ordinary tiles, including their persistent
    request keys. CGE's overloads can select single-precision Min/Max. }
  if SearchBox.MinLat < -90 then SearchBox.MinLat:=-90;
  if SearchBox.MaxLat > 90 then SearchBox.MaxLat:=90;
  N:=1; Boxes[0]:=SearchBox;
  if SearchBox.MaxLon-SearchBox.MinLon>=360 then begin Boxes[0].MinLon:=-180; Boxes[0].MaxLon:=180 end
  else if SearchBox.MinLon < -180 then begin
    N:=2; Boxes[1]:=SearchBox; Boxes[0].MinLon:=-180;
    Boxes[1].MinLon:=SearchBox.MinLon+360; Boxes[1].MaxLon:=180;
  end else if SearchBox.MaxLon>180 then begin
    N:=2; Boxes[1]:=SearchBox; Boxes[0].MaxLon:=180;
    Boxes[1].MinLon:=-180; Boxes[1].MaxLon:=SearchBox.MaxLon-360;
  end;
  Result := TJSONObject.Create;
  Photos := TJSONArray.Create; Reports := TJSONArray.Create;
  Result.Add('schema_version', 1); Result.Add('tile_id', Tile.ToString);
  Result.Add('grid_zoom', Grid.Zoom); Result.Add('grid_edge_px', Grid.EdgePx);
  Result.Add('tile_bbox', TJSONArray.Create([Box.MinLon, Box.MinLat, Box.MaxLon, Box.MaxLat]));
  if SearchBox.IsEmpty then Result.Add('search_bbox',TJSONNull.Create)
  else Result.Add('search_bbox', TJSONArray.Create([SearchBox.MinLon, SearchBox.MinLat, SearchBox.MaxLon, SearchBox.MaxLat]));
  Result.Add('photos', Photos); Result.Add('providers', Reports);
  Result.Add('route_scope',FRouteScope.Summary);
  if SearchBox.IsEmpty then begin
    Result.Add('photo_count',0); Result.Add('cancelled',False); Result.Add('stats',Stats); Exit;
  end;
  L := TStringList.Create;
  try
    try
      Selection:=LowerCase(Trim(Providers)); if (Selection='all') or (Selection='auto') then Selection:=AllPhotoProviders;
      L.StrictDelimiter := True; L.Delimiter := ','; L.DelimitedText := Selection; Seen := ',';
      if L.Count = 0 then raise Exception.Create('At least one photo provider is required');
      for I := 0 to L.Count-1 do
      begin
        L[I] := Trim(L[I]);
        if (L[I]='') or (Pos(','+L[I]+',', ','+AllPhotoProviders+',mapilio,google,mapy,') = 0) then raise Exception.Create('Unknown photo provider');
        if Pos(','+L[I]+',', Seen) > 0 then Continue;
        Seen := Seen + L[I] + ',';
        if N=1 then Reports.Add(SearchProvider(L[I],Boxes[0],MaxPages,MaxPhotos,Offline,Refresh,Photos))
        else begin
          P:=TJSONObject.Create(['provider',L[I]]); Reports.Add(P); Parts:=TJSONArray.Create; P.Add('parts',Parts);
          PagesLeft:=MaxPages; PhotosLeft:=MaxPhotos; State:='complete';
          for K:=0 to N-1 do begin
            if (PagesLeft<=0) or (PhotosLeft<=0) then begin State:='truncated'; Break end;
            PartPages:=Max(1,PagesLeft div (N-K));
            Part:=SearchProvider(L[I],Boxes[K],PartPages,PhotosLeft,Offline,Refresh,Photos); Parts.Add(Part);
            Dec(PagesLeft,Max(1,Part.Get('pages',0))); Dec(PhotosLeft,Part.Get('photos',0));
            if Part.Get('status','')<>'complete' then State:=Part.Get('status','unavailable');
          end;
          P.Add('status',State); P.Add('complete',State='complete'); P.Add('photos',MaxPhotos-PhotosLeft);
        end;
        if FHttp.Aborted then Break;
      end;
      for I := 0 to Photos.Count-1 do
      begin
        P := TJSONObject(Photos.Items[I]);
        Inside:= (P.Floats['latitude'] >= Box.MinLat) and
          (P.Floats['latitude'] <= Box.MaxLat) and (P.Floats['longitude'] >= Box.MinLon) and
          (P.Floats['longitude'] <= Box.MaxLon);
        P.Add('location_inside_tile',Inside);
        if P.Get('coordinate_role','unknown')='camera' then P.Add('camera_inside_tile',Inside)
        else P.Add('camera_inside_tile',TJSONNull.Create);
      end;
      Result.Add('photo_count', Photos.Count); Result.Add('cancelled', FHttp.Aborted); Result.Add('stats', Stats);
      if not FHttp.Aborted then RememberTileCatalog(Grid,Tile,Result);
    except Result.Free; raise end;
  finally L.Free end;
end;

function TPhotoApiClient.LoadDetail(const Photo: TJSONObject; Offline, Refresh: Boolean): TJSONObject;
const Fields = MAPILLARY_IMAGE_FIELDS;
var Provider, URL, Base, Key, Auth: string; J: TJSONObject; R: TFetchResult;
begin
  Result := nil;FLastMetadataStatus:=0; Provider := PhotoJsonString(Photo, 'provider'); Auth := '';
  if Provider = 'panoramax' then begin Base := FConfig.PanoramaxUrl; URL := PhotoJsonString(Photo, 'detail_url') end
  else if Provider = 'mapillary' then begin
    Base := FConfig.MapillaryUrl;
    URL := Base + '/' + URLParam(PhotoJsonString(Photo, 'image_id')) + '?fields=' + Fields;
    if (FConfig.MapillaryToken = '') and not Offline then Exit;
    if FConfig.MapillaryToken <> '' then Auth := 'OAuth ' + FConfig.MapillaryToken;
  end else Exit;
  if not SameOrigin(Base, URL) then Exit;
  Key := KeyFor(Provider + '/detail', URL);
  if not FetchJson(URL, Key, Auth, Offline, Refresh, J, R) then begin FLastMetadataStatus:=R.StatusCode;Exit end;
  try Result := NormalizeStreetPhoto(Provider, J, Base, Key) finally J.Free end;
  if (Result <> nil) and (Result.Strings['id'] <> PhotoJsonString(Photo, 'id')) then FreeAndNil(Result);
end;

function TPhotoApiClient.Download(const Photo: TJSONObject; const Size: string; Offline: Boolean): TJSONObject;
var P, NewP: TJSONObject; Provider, Id, URL, Key, Auth, Header: string; R: TFetchResult;
begin
  if (Size <> 'thumbnail') and (Size <> 'preview') and (Size <> 'original') then
    raise Exception.Create('Photo size must be thumbnail, preview or original');
  Provider := PhotoJsonString(Photo, 'provider'); Id := PhotoJsonString(Photo, 'image_id');
  if (Id = '') or (PhotoJsonString(Photo, 'id') <> Provider+':'+Id) then raise Exception.Create('Invalid normalized photo');
  P := TJSONObject(Photo.Clone);
  Result := TJSONObject.Create;
  try
    ApplyPhotoReviews(P,FPhotoReviews);
    if PhotoSourceRejected(P) then begin
      Result.Add('success',False);Result.Add('error','photo_rejected');
      Result.Add('id',Provider+':'+Id);Result.Add('photo',P);P:=nil;Exit;
    end;
    if (P.Find('download_allowed')<>nil) and not P.Get('download_allowed',False) then begin
      Result.Add('success',False); Result.Add('error','license_review_required');
      Result.Add('id',Provider+':'+Id); Result.Add('photo',P); P:=nil; Exit;
    end;
    URL := PhotoJsonString(P, 'urls.' + Size);
    Auth:=''; Header:='Authorization';
    if Provider='citylens' then begin
      if not SameOrigin(FConfig.Sources.CityLensUrl,URL) then raise Exception.Create('Invalid CityLens image origin');
      Auth:=FConfig.Sources.CityLensKey; Header:='X-API-Key';
    end else if Provider='cyclomedia' then begin
      if not SameOrigin(FConfig.Sources.CyclomediaRenderUrl,URL) then raise Exception.Create('Invalid Cyclomedia image origin');
      Auth:='Basic '+EncodeStringBase64(FConfig.Sources.CyclomediaUser+':'+FConfig.Sources.CyclomediaPassword);
      URL:=URL+'&apiKey='+URLParam(FConfig.Sources.CyclomediaKey);
    end;
    Key := KeyFor(Provider + '/image/' + Size, PhotoJsonString(P, 'catalog_url') + '/' + Id);
    FImageResponse := True;
    R := FHttp.GetCachedByKey(URL, Key);
    if R.Success then Inc(FCacheHits);
    if not R.Success and not Offline then
    begin
      if URL = '' then
      begin
        NewP := LoadDetail(P, False, False);
        if NewP <> nil then begin P.Free; P := NewP; URL := PhotoJsonString(P, 'urls.' + Size) end;
      end;
      if URL='' then R:=TFetchResult.Failure('metadata_unavailable',FLastMetadataStatus)
      else R := Fetch(URL, Key, Auth, False, False, True,Header);
      if not R.Success and ((R.StatusCode = 401) or (R.StatusCode = 403) or
        (R.StatusCode = 404)) and (URL<>'') and not FHttp.Aborted then
      begin
        { Signed image URLs expire. Refresh only this image's metadata once;
          successful bytes remain keyed by provider/id/size, not the signature. }
        NewP := LoadDetail(P, False, True);
        if NewP <> nil then
        begin
          P.Free; P := NewP; URL := PhotoJsonString(P, 'urls.' + Size);
          R := Fetch(URL, Key, '', False, False, True);
        end;
      end;
    end;
    if R.Success and ((FHttp.Cache = nil) or not FHttp.Cache.Has(Key)) then
      R := TFetchResult.Failure('cache_write_failed');
    Result.Add('success', R.Success); Result.Add('id', Provider+':'+Id); Result.Add('size', Size);
    Result.Add('cache_key', Key); Result.Add('from_cache', R.FromCache); Result.Add('http_status', R.StatusCode);
    Result.Add('bytes', Length(R.Data)); Result.Add('content_type', R.ContentType);
    if not R.Success then
      if FHttp.Aborted then Result.Add('error', 'cancelled')
      else if R.ErrorMsg = 'cache_write_failed' then Result.Add('error', R.ErrorMsg)
      else if R.ErrorMsg = 'metadata_unavailable' then Result.Add('error',R.ErrorMsg)
      else if Offline then Result.Add('error', 'cache_miss')
      else Result.Add('error', 'image_unavailable_or_invalid');
    Result.Add('photo', P); P := nil; Result.Add('stats', Stats);
  except P.Free; Result.Free; raise
  end;
  P.Free;
end;

function TPhotoApiClient.ReadImage(const CacheKey: string): TFetchResult;
begin
  if Pos('photo-api/v1/', CacheKey) <> 1 then Exit(TFetchResult.Failure('Not a photo cache key'));
  FImageResponse := True;
  Result := FHttp.GetCachedByKey('', CacheKey);
end;

function TPhotoApiClient.HasCachedImage(const CacheKey:string):Boolean;
begin
  Result:=(Pos('photo-api/v1/',CacheKey)=1) and (FHttp.Cache<>nil) and FHttp.Cache.Has(CacheKey);
end;

{$I Osm3dPhotoEvidence.inc}
{$I Osm3dPhotoAcquire.inc}

function TPhotoApiClient.Stats: TJSONObject;
begin
  Result := TJSONObject.Create(['network_requests', FNetworkRequests, 'cache_hits', FCacheHits]);
end;

initialization
  InitCriticalSection(PhotoCatalogCriticalSection);
finalization
  DoneCriticalSection(PhotoCatalogCriticalSection);
end.
