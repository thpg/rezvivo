unit Osm3dVideoSources;
{$mode objfpc}{$H+}{$codepage UTF8}

{ Coverage is checked BEFORE opening even the metadata of a regional corpus.
  Bounds are conservative discovery envelopes, never promises of coverage. }
interface
uses SysUtils, fpjson, Osm3dGeoMath;
const
  AllVideoProviders = 'crowd,walking,flickr,youtube,comma2k19,zod,yli_geo,robotcar,nuscenes,bdd100k';
  IndexedVideoProviders: array[0..5] of string =
    ('zod','comma2k19','yli_geo','robotcar','nuscenes','bdd100k');
type
  TVideoSourceConfig = record
    CrowdURL, WalkingURL, CommaURL, YouTubeURL, YouTubeKey, FFmpeg: string;
    IndexURLs: array[0..5] of string;
    MediaMaxBytes: Int64;
  end;
function DefaultVideoSourceConfig: TVideoSourceConfig;
function VideoSourceRegistry(const C: TVideoSourceConfig; FlickrConfigured: Boolean): TJSONObject;
function VideoProviderCoverage(const Provider: string): TJSONArray;
function VideoProviderApplies(const Provider: string; const Box: TLatLonBox): Boolean;
function VideoBoxIntersects(const A, B: TLatLonBox): Boolean;
function VideoPointInside(const P: TLatLon; const Box: TLatLonBox): Boolean;
function VideoIndexSlot(const Provider: string): Integer;
function VideoKey(const Kind, Identity: string): string;
function YouTubeId(const S: string): string;
function VideoDirectURL(const S: string): Boolean;

implementation
uses Classes, Math, MD5, URIParser, Osm3dPhotoSources;

function DefaultVideoSourceConfig: TVideoSourceConfig;
var I: Integer;
begin
  Result:=Default(TVideoSourceConfig);
  Result.CrowdURL:='https://raw.githubusercontent.com/crowd-dataset/crowd-city/main/mapping.csv';
  Result.WalkingURL:='https://raw.githubusercontent.com/tifa365/walking-around-the-world/main/walk-the-world-videos.csv';
  Result.CommaURL:='https://raw.githubusercontent.com/commaai/comma2k19/master/Example_1/b0c9d2329ad1606b%7C2018-08-02--08-34-47/40/';
  Result.YouTubeURL:='https://www.googleapis.com/youtube/v3';
  Result.YouTubeKey:=PhotoCredential('REZVIVO_YOUTUBE_KEY');
  Result.FFmpeg:=GetEnvironmentVariable('REZVIVO_FFMPEG');
  Result.MediaMaxBytes:=64*1024*1024;
  for I:=0 to High(IndexedVideoProviders) do
    Result.IndexURLs[I]:=GetEnvironmentVariable('REZVIVO_'+UpperCase(IndexedVideoProviders[I])+'_INDEX_URL');
end;

function VideoBoxIntersects(const A, B: TLatLonBox): Boolean;
begin
  Result:=(A.MinLat<=B.MaxLat) and (A.MaxLat>=B.MinLat) and
    (A.MinLon<=B.MaxLon) and (A.MaxLon>=B.MinLon);
end;

function VideoPointInside(const P: TLatLon; const Box: TLatLonBox): Boolean;
begin
  Result:=(P.Lat>=Box.MinLat) and (P.Lat<=Box.MaxLat) and
    (P.Lon>=Box.MinLon) and (P.Lon<=Box.MaxLon);
end;

function VideoProviderCoverage(const Provider: string): TJSONArray;
begin
  Result:=TJSONArray.Create;
  if Provider='comma2k19' then Result.Add(TJSONArray.Create([-122.56,37.25,-121.75,37.85]))
  else if Provider='zod' then Result.Add(TJSONArray.Create([-12.0,35.0,32.0,72.0]))
  else if Provider='robotcar' then Result.Add(TJSONArray.Create([-1.35,51.68,-1.1,51.85]))
  else if Provider='nuscenes' then begin
    Result.Add(TJSONArray.Create([-71.18,42.22,-70.90,42.43]));
    Result.Add(TJSONArray.Create([103.60,1.16,104.10,1.49]));
  end else if Provider='bdd100k' then Result.Add(TJSONArray.Create([-125.0,24.0,-66.0,50.0]))
  else Result.Add(TJSONArray.Create([-180.0,-90.0,180.0,90.0]));
end;

function VideoProviderApplies(const Provider: string; const Box: TLatLonBox): Boolean;
var A: TJSONArray; I: Integer; B: TLatLonBox;
begin
  Result:=False; A:=VideoProviderCoverage(Provider);
  try
    for I:=0 to A.Count-1 do begin
      B:=TLatLonBox.Make(A.Arrays[I].Floats[1],A.Arrays[I].Floats[0],A.Arrays[I].Floats[3],A.Arrays[I].Floats[2]);
      if VideoBoxIntersects(B,Box) then Exit(True);
    end;
  finally A.Free end;
end;

function VideoIndexSlot(const Provider: string): Integer;
var I: Integer;
begin
  for I:=0 to High(IndexedVideoProviders) do if IndexedVideoProviders[I]=Provider then Exit(I);
  Result:=-1;
end;

function VideoKey(const Kind, Identity: string): string;
begin Result:='video-api/v1/'+Kind+'/'+MD5Print(MD5String(Identity)) end;

function YouTubeId(const S: string): string;
var I,P: Integer;
begin
  Result:=Trim(S);
  for I:=1 to 3 do begin
    case I of 1: P:=Pos('/embed/',Result); 2: P:=Pos('watch?v=',Result); else P:=Pos('youtu.be/',Result) end;
    if P>0 then begin
      case I of 1: Inc(P,7); 2: Inc(P,8); else Inc(P,9) end;
      Result:=Copy(Result,P,11); Break;
    end;
  end;
  if Length(Result)<>11 then Exit('');
  for I:=1 to Length(Result) do if not (Result[I] in ['a'..'z','A'..'Z','0'..'9','-','_']) then Exit('');
end;

function VideoDirectURL(const S: string): Boolean;
var U: TURI; H: string;
begin
  U:=ParseURI(S,False); H:=LowerCase(U.Host);
  Result:=(U.Protocol='https') or (U.Protocol='http');
  Result:=Result and (H<>'') and (U.Username='') and (U.Password='');
  { These adapters discover YouTube links. They never turn them into downloads. }
  if (Pos('youtube.com',H)>0) or (Pos('googlevideo.com',H)>0) or (Pos('youtu.be',H)>0) then Result:=False;
end;

function VideoSourceRegistry(const C: TVideoSourceConfig; FlickrConfigured: Boolean): TJSONObject;
var Names: TStringList; P,S,Env,Mode: string; I,N: Integer; E: TJSONObject;
begin
  Result:=TJSONObject.Create; Names:=TStringList.Create;
  try
    Names.StrictDelimiter:=True; Names.Delimiter:=','; Names.DelimitedText:=AllVideoProviders;
    for I:=0 to Names.Count-1 do begin
      P:=Names[I]; S:='ready'; Mode:='discovery_links'; Env:=''; N:=VideoIndexSlot(P);
      if N>=0 then begin
        Env:='REZVIVO_'+UpperCase(P)+'_INDEX_URL'; Mode:='georeferenced_manifest';
        if C.IndexURLs[N]='' then S:='georeferenced_index_required';
      end;
      if P='comma2k19' then begin S:='public_sample_and_optional_index'; Mode:='per_frame_camera_track' end;
      if (P='flickr') and not FlickrConfigured then begin S:='credentials_required'; Env:='REZVIVO_FLICKR_KEY_FILE' end;
      if (P='youtube') and (C.YouTubeKey='') then begin S:='credentials_required'; Env:='REZVIVO_YOUTUBE_KEY_FILE' end;
      E:=TJSONObject.Create(['status',S,'mode',Mode,'configuration_env',Env]);
      E.Add('coverage_envelopes',VideoProviderCoverage(P));
      if P='zod' then E.Add('access_note','Obtain access from Zenseact; export camera/GNSS to the documented manifest. CC BY-SA; retain the required attribution notice.');
      if P='yli_geo' then E.Add('access_note','AWS media is public, but YLI membership lists have no coordinates. Import authorized YFCC geotags, media hash, creator and individual license.');
      if (P='robotcar') or (P='nuscenes') or (P='bdd100k') then
        E.Add('access_note','Regional research dataset. Standard research/noncommercial terms do not authorize production media ingestion; a reusable license or explicit permission reference is required per record.');
      Result.Add(P,E);
    end;
  finally Names.Free end;
  Result.Add('media_limit_bytes',C.MediaMaxBytes);
  Result.Add('frames','Optional external FFmpeg via REZVIVO_FFMPEG or PATH; JPEG/PNG sequences need no decoder.');
  Result.Add('coverage_filter','Before HTTP; cached indices are sharded by one-degree cells.');
end;

end.
