program OverpassRetryTests;
{$mode objfpc}{$H+}
uses Classes, SysUtils, SyncObjs, Osm3dCache, Osm3dCacheHTTPFetcher,
  Osm3dOsmOverpass, Osm3dOsmDirectory, Osm3dGenerationProgress;
const GoodBody='{"version":0.6,"elements":[{"type":"node","id":42,"lat":0,"lon":0}]}';
type
  TWatch=class
    Requests:LongInt;
    Failed:TEvent;
    constructor Create;
    destructor Destroy;override;
    procedure Request(Sender:TObject;const URL,Method:string;BodySize:Integer);
    procedure Error(Sender:TObject;const URL,Message:string;Attempt:Integer;
      PartialSize,ElapsedMs:Int64);
  end;
  TFetchThread=class(TThread)
    Fetcher:THTTPFetcherWithCache;
    URL,Query,Error:string;
    Bytes:TBytes;
    Elapsed:Int64;
    OK:Boolean;
    CancelFlag:PBoolean;
    constructor Create(AFetcher:THTTPFetcherWithCache;const AURL,AQuery:string);
    procedure Execute;override;
  end;
var Base:string;Checks:Integer;
procedure Check(B:Boolean;const Msg:string);
begin Inc(Checks);if not B then raise Exception.Create(Msg);end;
constructor TWatch.Create;
begin inherited;Failed:=TEvent.Create(nil,True,False,'');end;
destructor TWatch.Destroy;
begin Failed.Free;inherited;end;
procedure TWatch.Request(Sender:TObject;const URL,Method:string;BodySize:Integer);
begin InterlockedIncrement(Requests);end;
procedure TWatch.Error(Sender:TObject;const URL,Message:string;Attempt:Integer;
  PartialSize,ElapsedMs:Int64);
begin Failed.SetEvent;end;
constructor TFetchThread.Create(AFetcher:THTTPFetcherWithCache;const AURL,AQuery:string);
begin inherited Create(True);FreeOnTerminate:=False;Fetcher:=AFetcher;URL:=AURL;Query:=AQuery;end;
procedure TFetchThread.Execute;
begin
  GenerationProgressContext.Cancel:=CancelFlag;
  try OK:=OverpassFetchOnEndpoint(Fetcher,URL,Query,Bytes,Elapsed,Error,1000);
  finally GenerationProgressContext.Cancel:=nil;end;
end;
function BodyBytes:TBytes;
begin Result:=nil;SetLength(Result,Length(GoodBody));Move(GoodBody[1],Result[0],Length(GoodBody));end;

procedure RunCase(const Name:string;ExpectedRequests:Integer;ExpectedOK:Boolean);
var F:THTTPFetcherWithCache;W:TWatch;B:TBytes;Elapsed:Int64;Error,URL,Query:string;OK:Boolean;
    Snapshots:TOsmEndpointSnapshots;I:Integer;Found:Boolean;
begin
  F:=THTTPFetcherWithCache.Create(TMemoryCache.Create,True);W:=TWatch.Create;
  try
    F.TimeoutMs:=2000;F.MaxRetries:=5; { must not multiply the Overpass loop }
    F.OnNetworkRequest:=@W.Request;F.OnError:=@W.Error;
    URL:=Base+'/'+Name;Query:='[out:json]; // '+Name;
    if Pos('auto-',Name)=1 then begin
      URL:='auto';OsmEndpointResult(Base+'/auto-first',True);OsmEndpointResult(Base+'/auto-second',True);
    end;
    OK:=OverpassFetchOnEndpoint(F,URL,Query,B,Elapsed,Error,1000);
    Check(OK=ExpectedOK,Name+': wrong result '+Error);
    Check(W.Requests=ExpectedRequests,Name+': request count '+IntToStr(W.Requests));
    Check(OsmRequestStats.Active=0,Name+': request lease leaked');
    if URL<>'auto' then begin
      Snapshots:=OsmEndpointSnapshots(0);Found:=False;
      for I:=0 to High(Snapshots)do if Snapshots[I].URL=URL then begin
        Found:=True;
        Check(Snapshots[I].Active=0,Name+': display still shows active request');
        Check(Snapshots[I].Success=ExpectedOK,Name+': wrong displayed result');
        Check(Snapshots[I].Attempt=ExpectedRequests,Name+': wrong displayed attempt');
        if ExpectedOK then Check((Snapshots[I].StatusCode=200)and(Snapshots[I].Bytes=Length(B)),
          Name+': missing HTTP status/response size');
      end;
      Check(Found,Name+': missing loading display state');
    end;
    if ExpectedOK then begin
      Check(Length(B)>0,Name+': no result body');
      Check(OverpassFetchOnEndpoint(F,URL,Query,B,Elapsed,Error,1000),Name+': cache retry failed');
      Check(W.Requests=ExpectedRequests,Name+': successful tile downloaded again');
    end else begin
      Check(Length(B)=0,Name+': partial/error body escaped');
      Check(not F.GetCachedByKey(URL,OverpassCacheKey(Query)).Success,Name+': failed body cached');
    end;
  finally F.Free;W.Free;end;
end;

procedure CancelOrFillCache(const Mode:Integer);
var F:THTTPFetcherWithCache;W:TWatch;T:TFetchThread;Flag:Boolean;Started:QWord;Query,URL:string;
begin
  F:=THTTPFetcherWithCache.Create(TMemoryCache.Create,True);W:=TWatch.Create;T:=nil;
  try
    F.TimeoutMs:=2000;F.OnNetworkRequest:=@W.Request;F.OnError:=@W.Error;
    Flag:=False;Query:='[out:json]; // cancel-'+IntToStr(Mode);URL:=Base+'/cancel-'+IntToStr(Mode);
    T:=TFetchThread.Create(F,URL,Query);
    if Mode=2 then T.CancelFlag:=@Flag;
    T.Start;Check(W.Failed.WaitFor(3000)=wrSignaled,'first failure not observed');
    Sleep(20);Started:=GetTickCount64;
    case Mode of
      0:F.AbortAllRequests;
      1:T.Terminate;
      2:Flag:=True;
      3:F.Cache.Put(OverpassCacheKey(Query),BodyBytes,TCacheMetadata.Make('application/json'));
    end;
    T.WaitFor;
    Check(GetTickCount64-Started<1000,'backoff cancellation/cache did not finish promptly');
    Check(T.OK=(Mode=3),'cancel/cache returned wrong result');
    if Mode<>3 then Check(T.Error='aborted','cancellation reported as network failure');
    Check(W.Requests=1,'request repeated after cancellation/cache fill');
    Check(OsmRequestStats.Active=0,'lease retained during retry backoff');
  finally T.Free;F.Free;W.Free;end;
end;

procedure SharedCache;
var Cache:TMemoryCache;A,B:THTTPFetcherWithCache;W:TWatch;TA,TB:TFetchThread;
begin
  Cache:=TMemoryCache.Create;A:=THTTPFetcherWithCache.Create(Cache);B:=THTTPFetcherWithCache.Create(Cache);
  W:=TWatch.Create;TA:=nil;TB:=nil;
  try
    A.TimeoutMs:=2000;B.TimeoutMs:=2000;A.OnNetworkRequest:=@W.Request;B.OnNetworkRequest:=@W.Request;
    TA:=TFetchThread.Create(A,Base+'/shared','[out:json]; // shared');
    TB:=TFetchThread.Create(B,Base+'/shared','[out:json]; // shared');
    TA.Start;TB.Start;TA.WaitFor;TB.WaitFor;
    Check(TA.OK and TB.OK,'shared request failed');
    Check(W.Requests=1,'queued duplicate request did not reuse cache');
    Check(OsmRequestStats.Active=0,'shared request lease leaked');
  finally TA.Free;TB.Free;A.Free;B.Free;W.Free;Cache.Free;end;
end;

procedure PreferredWhileQueued;
var A,B:THTTPFetcherWithCache;W:TWatch;T:TFetchThread;Lease,Error:string;
    Data:TBytes;Elapsed:Int64;UntilTick:QWord;URLs:TStringArray;
begin
  A:=THTTPFetcherWithCache.Create(TMemoryCache.Create,True);
  B:=THTTPFetcherWithCache.Create(TMemoryCache.Create,True);
  W:=TWatch.Create;T:=nil;Lease:='';
  SetLength(URLs,2);URLs[0]:=Base+'/auto-first';URLs[1]:=Base+'/auto-second';
  try
    { Clear previous successes without leaving either mirror in cooldown. }
    OsmEndpointResult(URLs[0],False,'reset',503);OsmEndpointResult(URLs[0],True);
    OsmEndpointResult(URLs[1],False,'reset',503);OsmEndpointResult(URLs[1],True);
    Check(OsmTryAcquireRequest(URLs[0],Lease),'cannot reserve first mirror');
    A.TimeoutMs:=2000;B.TimeoutMs:=2000;A.OnNetworkRequest:=@W.Request;
    T:=TFetchThread.Create(A,'auto','[out:json]; // auto-queued');T.Start;Sleep(50);
    Check(W.Requests=0,'queued worker ignored server concurrency limit');
    Check(OverpassFetchOnEndpoint(B,URLs[1],'[out:json]; // prime-preferred',Data,Elapsed,Error),
      'second mirror did not answer');
    UntilTick:=GetTickCount64+2000;
    while not T.Finished and(GetTickCount64<UntilTick)do Sleep(5);
    Check(T.Finished,'queued request did not adopt working mirror');T.WaitFor;
    Check(T.OK and(W.Requests=1),'queued worker used failed mirror first');
    Check(OsmPreferredEndpoint(URLs,[])=1,'successful mirror not preferred');
    OsmEndpointResult(URLs[1],False,'HTTP 503',503);
    Check(OsmPreferredEndpoint(URLs,[])=0,'failed preferred mirror was not demoted');
    { Serving a query from cache must not turn the failed mirror healthy. }
    Check(OverpassFetchOnEndpoint(A,URLs[1],T.Query,Data,Elapsed,Error),'cached query failed');
    Check(OsmPreferredEndpoint(URLs,[])=0,'cache hit promoted failed mirror');
    Check(W.Requests=1,'cache priority check hit network');
  finally
    if T<>nil then begin T.Terminate;T.WaitFor;T.Free;end;
    OsmReleaseRequest(Lease);A.Free;B.Free;W.Free;
  end;
  Check(OsmRequestStats.Active=0,'queued priority test leaked lease');
end;

begin
  Base:=ParamStr(1);Check(Base<>'','local fixture URL required');
  RunCase('transient',3,True);
  RunCase('persistent',3,False);
  RunCase('bad400',1,False);RunCase('bad401',1,False);
  RunCase('bad403',1,False);RunCase('bad404',1,False);
  RunCase('rate',2,True);RunCase('truncated',2,True);
  RunCase('runtime',2,True);RunCase('disconnect',2,True);
  RunCase('empty',1,True);
  RunCase('auto-fallback',2,True);RunCase('auto-preferred',1,True);
  RunCase('auto-recover',3,True);
  CancelOrFillCache(0);CancelOrFillCache(1);CancelOrFillCache(2);CancelOrFillCache(3);
  SharedCache;
  PreferredWhileQueued;
  Writeln('PASS ',Checks,' checks: retry limits, fallback, cache, permanent errors, cancellation, shared requests');
end.
