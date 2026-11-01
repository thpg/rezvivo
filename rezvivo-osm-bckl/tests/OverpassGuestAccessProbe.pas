program OverpassGuestAccessProbe;
{$mode objfpc}{$H+}
{ Explicit live smoke test: obtain a map guest token, no login or OSM cache.
  Usage: OverpassGuestAccessProbe <protected-interpreter-url|auto>
  Set REZVIVO_TEST_AUTH_FILE and REZVIVO_TEST_CACHE_ROOT to isolated paths. }
uses Classes, SysUtils, fpjson, jsonparser, Osm3dCache, Osm3dCacheHTTPFetcher,
  Osm3dOsmAccess, Osm3dOsmDirectory;
const Query='[out:json][timeout:10][bbox:55.754,37.617,55.756,37.620];way["highway"];out tags center;';
type
  TWatch=class
    Count:Integer;
    procedure Request(Sender:TObject;const URL,Method:string;BodySize:Integer);
  end;
procedure TWatch.Request(Sender:TObject;const URL,Method:string;BodySize:Integer);
begin Inc(Count);Writeln('request ',Method,' ',URL);end;
var F:THTTPFetcherWithCache;R:TFetchResult;W:TWatch;J:TJSONData;
    URL,Body:string;Candidates:TStringArray;Elements:TJSONArray;
begin
  if ParamCount<>1 then raise Exception.Create('Provide a protected URL or auto');
  if Assigned(OsmAccessTokenProvider) then raise Exception.Create('Probe must not have an account provider');
  if (GetEnvironmentVariable('REZVIVO_TEST_AUTH_FILE')='') or
     (GetEnvironmentVariable('REZVIVO_TEST_CACHE_ROOT')='') then
    raise Exception.Create('Use an isolated directory cache');
  URL:=ParamStr(1);
  if URL='auto' then begin
    Candidates:=OsmServerCandidates(Query);
    if Length(Candidates)=0 then raise Exception.Create('No discovered endpoints');
    URL:=Candidates[0];
  end;
  if (URL<>'https://rezvivo.com/osm/api/interpreter') and
     (URL<>'https://rezvivo.ru/osm/api/interpreter') then
    raise Exception.Create('Expected an authenticated REZVIVO endpoint: '+URL);
  if not OsmRequiresAccess(URL) then raise Exception.Create('Map credential gate missing');
  F:=THTTPFetcherWithCache.Create(TMemoryCache.Create,True);W:=TWatch.Create;
  try
    F.MaxRetries:=1;F.TimeoutMs:=15000;F.OnNetworkRequest:=@W.Request;
    R:=F.PostString(URL,Query);
    if not R.Success or (R.StatusCode<>200) or R.FromCache or (W.Count<>1) then
      raise Exception.CreateFmt('Guest request failed: status=%d requests=%d %s',[R.StatusCode,W.Count,R.ErrorMsg]);
    SetLength(Body,Length(R.Data));if Length(R.Data)>0 then Move(R.Data[0],Body[1],Length(R.Data));
    J:=GetJSON(Body);
    try
      if not (J is TJSONObject) then raise Exception.Create('Not an Overpass object');
      if TJSONObject(J).Find('remark')<>nil then raise Exception.Create('Overpass query did not complete');
      Elements:=TJSONObject(J).Arrays['elements'];
      if Elements.Count=0 then raise Exception.Create('No OSM features returned for the reference area');
      Writeln('PASS token-authenticated guest Overpass: status=200 elements=',Elements.Count,' bytes=',Length(R.Data));
    finally J.Free;end;
  finally W.Free;F.Free;end;
end.
