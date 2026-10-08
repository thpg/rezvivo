unit Osm3dPhotoSources;
{$mode objfpc}{$H+}{$codepage UTF8}

{ Catalog metadata and attribution. Transport and cache belong to PhotoApi. }
interface
uses Classes, SysUtils, fpjson;
type
  TPhotoSourceConfig = record
    CommonsUrl, WikidataUrl, GbifUrl, FlickrUrl, GeographUrl: string;
    FlickrKey, GeographKey, CityLensUrl, CityLensKey, CityLensFrom, CityLensTo: string;
    CyclomediaUrl, CyclomediaRenderUrl, CyclomediaKey, CyclomediaUser, CyclomediaPassword: string;
    CityLensLicense, CyclomediaLicense: string;
  end;
const
  AllPhotoProviders = 'panoramax,commons,wikidata,gbif,mapillary,kartaview,flickr,geograph,citylens,cyclomedia';
function DefaultPhotoSourceConfig: TPhotoSourceConfig;
function PhotoSourceRegistry(const C: TPhotoSourceConfig): TJSONObject;
function PhotoCredential(const Name: string): string;
function PhotoLicenseReusable(const License, LicenseURL: string): Boolean;
function NormalizeCatalogPhoto(const Provider: string; Item: TJSONObject;
  const Catalog, Key: string): TJSONObject;
function ConvertGeographFeed(const Bytes: TBytes): TBytes;
function ParsePhotoJson(const S: RawByteString): TJSONData;

implementation
uses Math, MD5, DOM, XMLRead, jsonparser, Osm3dPhotoRelevance;

{$I ../Mcp/Utf8Json.inc}

function ParsePhotoJson(const S: RawByteString): TJSONData;
begin Result:=ParseUtf8Json(S) end;

function Str(J: TJSONData; const Path: string; const Def: string = ''): string;
var V: TJSONData;
begin
  Result := Def; if J=nil then Exit; V:=J.FindPath(Path);
  if (V<>nil) and (V.JSONType in [jtString,jtNumber,jtBoolean]) then Result:=V.AsString;
end;

function Number(J: TJSONData; const Path: string; out V: Double): Boolean;
var F: TFormatSettings;
begin
  V:=0; F:=DefaultFormatSettings; F.DecimalSeparator:='.'; F.ThousandSeparator:=#0;
  Result:=TryStrToFloat(Str(J,Path),V,F);
  if Result then Result:=not IsNan(V) and not IsInfinite(V);
end;

function PlainText(const S: string): string;
var I: Integer; InTag: Boolean;
begin
  Result:=''; InTag:=False;
  for I:=1 to Length(S) do
    if S[I]='<' then InTag:=True
    else if S[I]='>' then InTag:=False
    else if not InTag then Result:=Result+S[I];
  Result:=StringReplace(Result,'&amp;','&',[rfReplaceAll]);
  Result:=StringReplace(Result,'&quot;','"',[rfReplaceAll]);
  Result:=StringReplace(Result,'&#39;','''',[rfReplaceAll]);
  Result:=Trim(Result);
end;

function PhotoCredential(const Name: string): string;
var P: string; F: TStringList;
begin
  Result:=Trim(GetEnvironmentVariable(Name));
  if Result='' then begin
    P:=GetEnvironmentVariable(Name+'_FILE');
    if P<>'' then begin
      F:=TStringList.Create;
      try
        try F.LoadFromFile(P); Result:=Trim(F.Text) except Result:='' end;
      finally F.Free end;
    end;
  end;
  { A broken credential must not prevent unrelated public providers from running. }
  if (Pos(#10,Result)>0) or (Pos(#13,Result)>0) then Result:='';
end;

function Env(const Name, Default: string): string;
begin Result:=Trim(GetEnvironmentVariable(Name)); if Result='' then Result:=Default end;

function DefaultPhotoSourceConfig: TPhotoSourceConfig;
begin
  Result:=Default(TPhotoSourceConfig);
  Result.CommonsUrl:='https://commons.wikimedia.org/w/api.php';
  Result.WikidataUrl:='https://query.wikidata.org/sparql';
  Result.GbifUrl:='https://api.gbif.org/v1';
  Result.FlickrUrl:='https://api.flickr.com/services/rest/';
  Result.GeographUrl:='https://api.geograph.org.uk/syndicator.php';
  Result.FlickrKey:=PhotoCredential('REZVIVO_FLICKR_KEY');
  Result.GeographKey:=PhotoCredential('REZVIVO_GEOGRAPH_KEY');
  Result.CityLensUrl:=Env('REZVIVO_CITYLENS_URL','');
  Result.CityLensKey:=PhotoCredential('REZVIVO_CITYLENS_KEY');
  Result.CityLensFrom:=Env('REZVIVO_CITYLENS_FROM','');
  Result.CityLensTo:=Env('REZVIVO_CITYLENS_TO','');
  Result.CityLensLicense:=Env('REZVIVO_CITYLENS_LICENSE','');
  Result.CyclomediaUrl:='https://atlasapi.cyclomedia.com/api/recording/wfs';
  Result.CyclomediaRenderUrl:='https://atlasapi.cyclomedia.com/api/PanoramaRendering';
  Result.CyclomediaKey:=PhotoCredential('REZVIVO_CYCLOMEDIA_KEY');
  Result.CyclomediaUser:=PhotoCredential('REZVIVO_CYCLOMEDIA_USER');
  Result.CyclomediaPassword:=PhotoCredential('REZVIVO_CYCLOMEDIA_PASSWORD');
  Result.CyclomediaLicense:=Env('REZVIVO_CYCLOMEDIA_LICENSE','');
end;

function PhotoSourceRegistry(const C: TPhotoSourceConfig): TJSONObject;
  procedure Add(const Name, URL, Coverage, Role, State, Credential: string);
  begin
    Result.Add(Name,TJSONObject.Create(['api_url',URL,'coverage',Coverage,'purpose',Role,
      'configured',State='ready','status',State,'credential_env',Credential]));
  end;
  function Ready(Ok: Boolean): string;
  begin if Ok then Result:='ready' else Result:='credentials_required' end;
begin
  Result:=TJSONObject.Create;
  Add('commons',C.CommonsUrl,'worldwide','place_reference','ready','');
  Add('wikidata',C.WikidataUrl,'worldwide','object_reference','ready','');
  Add('gbif',C.GbifUrl,'worldwide','vegetation_reference','ready','');
  Add('flickr',C.FlickrUrl,'worldwide','place_reference',Ready(C.FlickrKey<>''),'REZVIVO_FLICKR_KEY_FILE');
  Add('geograph',C.GeographUrl,'Great Britain and Ireland','place_reference',Ready(C.GeographKey<>''),'REZVIVO_GEOGRAPH_KEY_FILE');
  Add('citylens',C.CityLensUrl,'licensed company survey','street_reference',Ready((C.CityLensUrl<>'') and
    (C.CityLensKey<>'') and (C.CityLensFrom<>'') and (C.CityLensTo<>'') and (C.CityLensLicense<>'')),
    'REZVIVO_CITYLENS_KEY_FILE');
  Add('cyclomedia',C.CyclomediaUrl,'licensed coverage','street_reference',Ready((C.CyclomediaKey<>'') and
    (C.CyclomediaUser<>'') and (C.CyclomediaPassword<>'') and (C.CyclomediaLicense<>'')),
    'REZVIVO_CYCLOMEDIA_KEY_FILE');
  Result.Add('mapilio',TJSONObject.Create(['configured',False,'status','api_contract_unavailable',
    'note','Public v1 contract has sequence reads but no documented tile/bbox image search and download contract.']));
  Result.Add('google',TJSONObject.Create(['configured',False,'status','usage_incompatible',
    'note','Standard Street View terms do not permit this persistent-cache/content-creation workflow.']));
  Result.Add('mapy',TJSONObject.Create(['configured',False,'status','usage_incompatible',
    'note','Static panorama API does not permit persistent image caching.']));
end;

function PhotoLicenseReusable(const License, LicenseURL: string): Boolean;
var S: string;
begin
  S:=LowerCase(License+' '+LicenseURL);
  if (Pos('-nc',S)>0) or (Pos('-nd',S)>0) or (Pos('noncommercial',S)>0) or
    (Pos('no derivatives',S)>0) then Exit(False);
  Result:=(Pos('creativecommons.org/licenses/by/',S)>0) or
    (Pos('creativecommons.org/licenses/by-sa/',S)>0) or
    (Pos('creativecommons.org/publicdomain/',S)>0) or
    (Pos('cc-by-',S)>0) or (Pos('cc by ',S)>0) or (Pos('cc0',S)>0) or
    (Pos('public domain',S)>0);
end;

function NormalizeCatalogPhoto(const Provider: string; Item: TJSONObject;
  const Catalog, Key: string): TJSONObject;
var Id, Title, Author, Lic, LicURL, Source, Thumb, Preview, Original, Date, Role, Purpose: string;
  Lat, Lon, Heading, V: Double; HasHeading, Reusable: Boolean; W,H: Integer;
  Info, Meta, Coord: TJSONData;
begin
  Result:=nil; Lat:=0; Lon:=0; Heading:=0; HasHeading:=False; W:=0; H:=0;
  Id:=''; Title:=''; Author:=''; Lic:=''; LicURL:=''; Source:=''; Date:='';
  Thumb:=''; Preview:=''; Original:=''; Role:='unknown'; Purpose:='place_reference';
  if Provider='commons' then begin
    Info:=Item.FindPath('imageinfo[0]'); Meta:=nil;
    if Info=nil then Exit; Meta:=Info.FindPath('extmetadata');
    if Pos('image/',Str(Info,'mime'))<>1 then Exit;
    Id:=Str(Item,'pageid'); Title:=Str(Item,'title');
    Coord:=Item.FindPath('coordinates[0]');
    if Number(Item,'_subject_lat',Lat) and Number(Item,'_subject_lon',Lon) then Role:='subject'
    else begin
      if not Number(Coord,'lat',Lat) or not Number(Coord,'lon',Lon) then Exit;
      if Str(Coord,'type')='camera' then Role:='camera';
    end;
    Date:=Str(Meta,'DateTimeOriginal.value'); Author:=PlainText(Str(Meta,'Artist.value'));
    Lic:=PlainText(Str(Meta,'LicenseShortName.value')); LicURL:=Str(Meta,'LicenseUrl.value');
    Original:=Str(Info,'url'); Preview:=Str(Info,'thumburl',Original); Thumb:=Preview;
    Source:=Str(Info,'descriptionurl');
    if Number(Info,'width',V) then W:=Round(V); if Number(Info,'height',V) then H:=Round(V);
  end else if Provider='flickr' then begin
    Id:=Str(Item,'id'); Title:=Str(Item,'title');
    if not Number(Item,'latitude',Lat) or not Number(Item,'longitude',Lon) then Exit;
    Date:=Str(Item,'datetaken'); if Str(Item,'datetakenunknown')='1' then Date:='';
    Author:=Str(Item,'ownername'); Lic:=Str(Item,'_license_name'); LicURL:=Str(Item,'_license_url');
    Thumb:=Str(Item,'url_t'); Preview:=Str(Item,'url_l',Str(Item,'url_z')); Original:=Str(Item,'url_o',Preview);
    Source:='https://www.flickr.com/photos/'+Str(Item,'owner')+'/'+Id;
    if Number(Item,'width_o',V) then W:=Round(V); if Number(Item,'height_o',V) then H:=Round(V);
  end else if Provider='gbif' then begin
    Info:=Item.FindPath('_media'); if Info=nil then Exit;
    if not Number(Item,'decimalLatitude',Lat) or not Number(Item,'decimalLongitude',Lon) then Exit;
    if Str(Info,'type')<>'StillImage' then Exit;
    Original:=Str(Info,'identifier'); if Original='' then Exit;
    Id:=Str(Item,'key')+':'+MD5Print(MD5String(Original));
    Title:=Str(Item,'scientificName'); Author:=Str(Info,'creator',Str(Info,'rightsHolder'));
    Lic:=Str(Info,'license'); LicURL:=Lic; Date:=Str(Info,'created',Str(Item,'eventDate'));
    Source:=Str(Info,'references','https://www.gbif.org/occurrence/'+Str(Item,'key'));
    Preview:=Catalog+'/image/cache/1200x/occurrence/'+Str(Item,'key')+'/media/'+MD5Print(MD5String(Original));
    Thumb:=Catalog+'/image/cache/300x/occurrence/'+Str(Item,'key')+'/media/'+MD5Print(MD5String(Original));
    Role:='observation'; Purpose:='vegetation_reference';
  end else if Provider='geograph' then begin
    Id:=Str(Item,'id'); Title:=Str(Item,'title');
    if not Number(Item,'lat',Lat) or not Number(Item,'lon',Lon) then Exit;
    Role:='subject'; Author:=Str(Item,'author'); Date:=Str(Item,'captured_at');
    Lic:='CC-BY-SA-2.0'; LicURL:='https://creativecommons.org/licenses/by-sa/2.0/';
    Source:=Str(Item,'source_url'); Preview:=Str(Item,'image_url'); Thumb:=Preview;
  end else if Provider='citylens' then begin
    Id:=Str(Item,'id'); if not Number(Item,'lat',Lat) or not Number(Item,'lon',Lon) then Exit;
    HasHeading:=Number(Item,'azimuth',Heading); Date:=Str(Item,'date');
    Role:='camera'; Purpose:='street_reference'; Lic:=Str(Item,'_license');
    Preview:=Str(Item,'_image_url'); Original:=Preview; Thumb:=Preview;
    Source:=Catalog+'/export-api/v1/frames/'+Id+'/image';
  end else if Provider='cyclomedia' then begin
    Id:=Str(Item,'properties.imageId');
    if not Number(Item,'geometry.coordinates[0]',Lon) or not Number(Item,'geometry.coordinates[1]',Lat) then Exit;
    if not SameText(Str(Item,'properties.isAuthorized'),'true') then Exit;
    Date:=Str(Item,'properties.recordedAt'); Author:=Str(Item,'properties.ownerInfo.name','Cyclomedia');
    Role:='camera'; Purpose:='street_reference'; Lic:=Str(Item,'_license');
    Preview:=Str(Item,'_image_url'); Thumb:=Preview; Original:=Preview;
    Source:=Str(Item,'_source_url'); HasHeading:=True; Heading:=0;
  end else Exit;
  if (Id='') or (Lat < -90) or (Lat > 90) or (Lon < -180) or (Lon > 180) then Exit;
  Reusable:=PhotoLicenseReusable(Lic,LicURL) or ((Lic<>'') and ((Provider='citylens') or (Provider='cyclomedia')));
  Result:=TJSONObject.Create(['id',Provider+':'+Id,'provider',Provider,'image_id',Id,
    'title',Title,'sequence_id','','latitude',Lat,'longitude',Lon,'coordinate_role',Role,'purpose',Purpose,
    'captured_at',Date,'author',Author,'license',Lic,'license_url',LicURL,'download_allowed',Reusable,
    'source_url',Source,'detail_url','','catalog_url',Catalog,'metadata_cache_key',Key,'width',W,'height',H,
    'projection','unknown']);
  if HasHeading then Result.Add('heading_deg',Heading-Floor(Heading/360)*360)
  else Result.Add('heading_deg',TJSONNull.Create);
  Result.Add('urls',TJSONObject.Create(['thumbnail',Thumb,'preview',Preview,'original',Original]));
  if Provider='commons' then begin
    Result.Add('description',PlainText(Str(Meta,'ImageDescription.value')));
    Result.Add('categories',Str(Meta,'Categories.value'));
    Result.Add('restrictions',PlainText(Str(Meta,'Restrictions.value')));
    if Str(Item,'_wikidata')<>'' then Result.Add('wikidata_id',Str(Item,'_wikidata'));
  end;
  if Provider='gbif' then begin
    Result.Add('taxon',Str(Item,'scientificName')); Result.Add('taxon_key',Str(Item,'taxonKey'));
    Result.Add('basis_of_record',Str(Item,'basisOfRecord'));
    Result.Add('description',PlainText(Str(Info,'description',Str(Info,'title'))));
    if Number(Item,'coordinateUncertaintyInMeters',V) then Result.Add('coordinate_uncertainty_m',V);
  end;
  ApplyAutomaticPhotoReview(Result);
end;

function ConvertGeographFeed(const Bytes: TBytes): TBytes;
var D: TXMLDocument; Stream: TBytesStream; N,C: TDOMNode; J,P: TJSONObject; A:TJSONArray;
  S, Name, Value, Img: string; I,K: Integer;
begin
  Result:=nil; if Length(Bytes)=0 then Exit;
  { Never resolve external entities or accept a DTD in provider XML. }
  SetString(S,PAnsiChar(@Bytes[0]),Length(Bytes));
  if (Pos('<!DOCTYPE',UpperCase(S))>0) or (Pos('<!ENTITY',UpperCase(S))>0) then
    raise Exception.Create('DTD is not allowed in photo metadata');
  Stream:=TBytesStream.Create(Bytes); D:=nil; J:=TJSONObject.Create;
  try
    ReadXMLFile(D,Stream); N:=D.DocumentElement;
    if (N=nil) or (N.NodeName<>'rss') then raise Exception.Create('Invalid Geograph feed');
    N:=N.FindNode('channel'); if N=nil then raise Exception.Create('Invalid Geograph channel');
    A:=TJSONArray.Create; J.Add('items',A); N:=N.FirstChild;
    while N<>nil do begin
      if N.NodeName='item' then begin
        P:=TJSONObject.Create; A.Add(P); C:=N.FirstChild;
        while C<>nil do begin
          Name:=UTF8Encode(C.NodeName); Value:=UTF8Encode(C.TextContent);
          if Name='title' then P.Strings['title']:=Value
          else if Name='link' then begin
            P.Strings['source_url']:=Value; I:=LastDelimiter('/',Value); P.Strings['id']:=Copy(Value,I+1,MaxInt);
          end else if (Name='dc:creator') or (Name='author') then P.Strings['author']:=Value
          else if Name='georss:point' then begin
            I:=Pos(' ',Trim(Value)); P.Strings['lat']:=Copy(Trim(Value),1,I-1); P.Strings['lon']:=Copy(Trim(Value),I+1,MaxInt);
          end else if Name='geo:lat' then P.Strings['lat']:=Value
          else if Name='geo:long' then P.Strings['lon']:=Value
          else if (Name='media:content') or (Name='media:thumbnail') then begin
            if (C is TDOMElement) and (P.Get('image_url','')='') then P.Strings['image_url']:=UTF8Encode(TDOMElement(C).GetAttribute('url'));
          end else if Name='description' then begin
            { Feed embeds its supplied photograph in escaped HTML. Never follow arbitrary links. }
            I:=Pos('<img',LowerCase(Value)); Img:=Copy(Value,I,MaxInt);
            K:=Pos('src="',LowerCase(Img));
            if (I>0) and (K>0) and (P.Get('image_url','')='') then begin
              Img:=Copy(Img,K+5,MaxInt); I:=Pos('"',Img);
              P.Strings['image_url']:=StringReplace(Copy(Img,1,I-1),'&amp;','&',[rfReplaceAll]);
            end;
          end;
          C:=C.NextSibling;
        end;
      end;
      N:=N.NextSibling;
    end;
    S:=J.AsJSON; SetLength(Result,Length(S)); if S<>'' then Move(S[1],Result[0],Length(S));
  finally D.Free; Stream.Free; J.Free end;
end;
end.
