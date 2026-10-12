program PlatformHttpCacheTests;
{$mode objfpc}{$H+}
uses Classes, SysUtils, Osm3dCache, Osm3dCacheHTTPFetcher, Osm3dPlatformHttp, Osm3dOsmAccess;
type
  TFixtureRequest = class(TOsmPlatformHttpRequest)
    procedure Execute(const Method, Url: String; Headers: TStrings; Body: TStream;
      ConnectMs, ReadMs: Integer; Response: TStream; out Status: Integer;
      ResponseHeaders: TStrings); override;
    procedure Cancel; override;
  end;
var Fetcher: THTTPFetcherWithCache; Calls, Cancels, TemporaryFailures: Integer;
    LastMethod, LastHeaders, LastBody: String; RefuseRedirects: Boolean; Limit: Int64;
    AccountToken: string;
function TokenProvider:string;
begin Result:=AccountToken end;
procedure Check(Value: Boolean; const MessageText: String);
begin if not Value then raise Exception.Create(MessageText) end;
function Factory: TOsmPlatformHttpRequest;
begin Result:=TFixtureRequest.Create end;
procedure TFixtureRequest.Cancel;
begin Inc(Cancels) end;
procedure TFixtureRequest.Execute(const Method, Url: String; Headers: TStrings; Body: TStream;
  ConnectMs, ReadMs: Integer; Response: TStream; out Status: Integer;
  ResponseHeaders: TStrings);
const Data: AnsiString = 'map bytes';
begin
  Inc(Calls); LastMethod:=Method; LastHeaders:=Headers.Text;
  LastBody:=''; RefuseRedirects:=NoRedirects; Limit:=MaxResponseBytes;
  if Body<>nil then begin
    SetLength(LastBody,Body.Size); Body.Position:=0;
    if Length(LastBody)>0 then Body.ReadBuffer(LastBody[1],Length(LastBody));
  end;
  if Pos('/cancel',Url)>0 then begin
    Fetcher.AbortAllRequests;
    raise EAbort.Create('Fixture request cancelled');
  end;
  Status:=200;
  if Pos('/missing',Url)>0 then Status:=404;
  if (Pos('/retry',Url)>0) and (TemporaryFailures=0) then begin
    Inc(TemporaryFailures); Status:=503;
  end;
  ResponseHeaders.Add('Content-Type: application/octet-stream');
  ResponseHeaders.Add('ETag: fixture-v1');
  Response.WriteBuffer(Data[1],Length(Data));
end;
var R: TFetchResult; Previous: Integer;
begin
  OsmPlatformHttpFactory:=@Factory;
  Fetcher:=THTTPFetcherWithCache.Create(TMemoryCache.Create(1024*1024),True);
  try
    Fetcher.MaxRetries:=2; Fetcher.RetryBaseMs:=1; Fetcher.RetryMaxMs:=1;
    Fetcher.MaxResponseBytes:=1024;
    OsmAccessTokenProvider:=@TokenProvider;
    AccountToken:=''; Previous:=Calls;
    R:=Fetcher.GetUrl('https://rezvivo.com/map/world-ne-v1/0/0/0.png');
    Check(not R.Success and (R.StatusCode=401) and (Calls=Previous),'guest used protected map transport');
    AccountToken:='test-account-token';
    R:=Fetcher.GetUrl('https://rezvivo.com/map/world-ne-v1/0/0/0.png');
    Check(R.Success and (Calls=Previous+1) and RefuseRedirects and
      (Pos('Authorization: Bearer test-account-token',LastHeaders)>0),'protected map bypassed platform TLS or lost auth');
    R:=Fetcher.GetUrl('https://fixture.invalid/resource.bin');
    Check(R.Success and not R.FromCache,'native GET failed: '+R.ErrorMsg);
    Check((R.ContentType='application/octet-stream') and (R.ETag='fixture-v1'),'lost native headers');
    Check((LastMethod='GET') and (Limit=1024) and not RefuseRedirects,'lost request constraints');
    Check(Pos('test-account-token',LastHeaders)=0,'account token leaked to public endpoint');
    Previous:=Calls;
    R:=Fetcher.GetUrl('https://fixture.invalid/resource.bin');
    Check(R.Success and R.FromCache and (Calls=Previous),'cache repeated native I/O');
    R:=Fetcher.PostString('https://fixture.invalid/post','query=data');
    Check(R.Success and (LastMethod='POST') and (LastBody='query=data'),'lost POST body');
    R:=Fetcher.GetUrlWithKey('https://fixture.invalid/private','stable-key','fixture-token');
    Check(R.Success and RefuseRedirects and (Pos('fixture-token',LastHeaders)>0),'authenticated GET policy lost');
    R:=Fetcher.GetUrl('https://fixture.invalid/missing');
    Check(not R.Success and (R.StatusCode=404),'native 404 treated as cacheable success');
    Previous:=Calls;
    R:=Fetcher.GetUrl('https://fixture.invalid/retry');
    Check(R.Success and (Calls=Previous+2),'native retry policy changed');
    R:=Fetcher.GetUrl('https://fixture.invalid/cancel');
    Check(not R.Success and (Cancels=1) and Fetcher.Aborted,'native cancellation not forwarded');
    Previous:=Calls;
    R:=Fetcher.GetUrl('https://fixture.invalid/after-cancel');
    Check(not R.Success and (Calls=Previous),'cancelled fetcher started a request');
    Fetcher.ResetAbort;
    R:=Fetcher.GetUrl('https://fixture.invalid/reset');
    Check(R.Success,'fetcher cannot restart after cancellation');
    Writeln('PASS platform HTTP/cache: GET, POST, headers, cache, auth, errors, retries, cancellation');
  finally Fetcher.Free; OsmPlatformHttpFactory:=nil;OsmAccessTokenProvider:=nil end;
end.
