unit Osm3dOsmDirectory;
{$mode objfpc}{$H+}{$codepage UTF8}

interface

uses Classes, SysUtils;

const
  OSM_DIRECTORY_MODE = 'auto';
  OSM_PUBLIC_ENDPOINTS =
    'https://maps.mail.ru/osm/tools/overpass/api/interpreter;' +
    'https://overpass.private.coffee/api/interpreter;' +
    'https://overpass-api.de/api/interpreter';
  HEIGHT_PUBLIC_TEMPLATE =
    'https://s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png';
  HEIGHT_DATASET_REVISION = 'mapzen-geotiff-v1';

type
  TOsmRequestLimits=record
    MinIntervalMs,MaxConcurrent:Integer;
    Group:string;
  end;
  TOsmRequestStats=record Active,Peak:Integer;end;

{ Called from OSM fetch workers, never from constructors/UI initialization. }
function OsmServerCandidates(const Query: string): TStringArray;
function OsmCandidatesFromJSON(const Document, Query: string): TStringArray;
function HeightCandidatesFromJSON(const Document: string;
  const South, West, North, East: Double): TStringArray;
function HeightServerCandidates(const South, West, North, East: Double;
  AllowRefresh: Boolean = True): TStringArray;
function HeightDatasetCacheKey(const URLTemplate: string): string;
function OsmEndpointCanTry(const URL: string): Boolean;
procedure OsmEndpointResult(const URL: string; Success: Boolean; const ErrorText:string='');
function OsmEndpointLastError(const URL:string):string;
{ Nonblocking reservation. The caller waits cancellably outside the lock;
  a lease remembers its group even if discovery changes in flight. }
function OsmTryAcquireRequest(const URL:string;out Lease:string):Boolean;
procedure OsmReleaseRequest(const Lease:string);
function OsmRequestLimits(const URL:string):TOsmRequestLimits;
function OsmRequestStats:TOsmRequestStats;

implementation

uses Math, StrUtils, fpjson, jsonparser, fphttpclient, opensslsockets, URIParser;

type
  TBounds = array[0..3] of Double; { south, west, north, east }
  TPoint = record X, Y: Double; end;
  TRing = record Hole: Boolean; Points: array of TPoint; end;
  TRings = array of TRing;
  TServer = record URL, Kind, Region: string; Bounds: TBounds; Limits:TOsmRequestLimits; end;
  TServers = array of TServer;
  TDirectory = record Servers, HeightServers: TServers; Russia: TRings; TTL: Integer; end;
  TEndpointHealth = record
    URL: string;
    FailedUntil: QWord;
    LastError: string;
  end;
  TRequestBudget=record Key:string;Active:Integer;LastStart:QWord;end;
  TLimitedStream = class(TMemoryStream)
  public
    Started: QWord;
    BudgetMs: QWord;
    function Write(const Buffer; Count: LongInt): LongInt; override;
  end;

var
  GGuard: TRTLCriticalSection;
  GDirectory: TDirectory;
  GNextRefresh: QWord = 0;
  GLoadedAt: TDateTime = 0;
  GRefreshing: Boolean = False;
  GDiskLoaded: Boolean = False;
  GHealth: array of TEndpointHealth;
  GBudgets:array of TRequestBudget;
  GRequestActive,GRequestPeak:Integer;

function DefaultRequestLimits(const URL:string):TOsmRequestLimits;
begin
  Result.MinIntervalMs:=1000;Result.MaxConcurrent:=1;Result.Group:='';
  { Compatible defaults for older cached directories without limit fields. }
  if SameText(URL,'https://rezvivo.com/osm/api/interpreter')or
     SameText(URL,'https://rezvivo.ru/osm/api/interpreter')then begin
    Result.MinIntervalMs:=500;Result.MaxConcurrent:=2;Result.Group:='rezvivo-osm';
  end;
end;

function ParseRequestLimits(O:TJSONObject;const URL:string;out L:TOsmRequestLimits):Boolean;
var N,V:TJSONData;I:Integer;Limits:TJSONObject;
  function ReadInt(const Name:string;Lo,Hi:Integer;var Value:Integer):Boolean;
  begin
    V:=Limits.Find(Name);if V=nil then Exit(True);
    Result:=(V.JSONType=jtNumber)and(V.AsFloat>=Lo)and(V.AsFloat<=Hi)and(Frac(V.AsFloat)=0);
    if Result then Value:=V.AsInteger;
  end;
begin
  L:=DefaultRequestLimits(URL);N:=O.Find('limits');Result:=True;if N=nil then Exit;
  Result:=False;if not(N is TJSONObject)then Exit;Limits:=TJSONObject(N);
  if not ReadInt('min_interval_ms',0,60000,L.MinIntervalMs)or
     not ReadInt('max_concurrent',1,16,L.MaxConcurrent)then Exit;
  V:=Limits.Find('group');
  if V<>nil then begin if V.JSONType<>jtString then Exit;L.Group:=Trim(V.AsString);end;
  if Length(L.Group)>64 then Exit;
  for I:=1 to Length(L.Group)do if not(L.Group[I]in['a'..'z','A'..'Z','0'..'9','_','-'])then Exit;
  Result:=True;
end;

function TLimitedStream.Write(const Buffer; Count: LongInt): LongInt;
begin
  if (Size + Count > 1024*1024) or (GetTickCount64-Started>BudgetMs) then
    raise EStreamError.Create('OSM directory response limit');
  Result:=inherited Write(Buffer,Count);
end;

function ReadHTTP(const URL: string; out Body: string; out Code: Integer;
  TimeoutMs: Integer = 1500): Boolean;
var H: TFPHTTPClient; S: TLimitedStream;
begin
  Result:=False;Body:='';Code:=0;
  H:=TFPHTTPClient.Create(nil);S:=TLimitedStream.Create;
  try
    S.Started:=GetTickCount64;
    S.BudgetMs:=QWord(TimeoutMs)*2+1000;
    H.ConnectTimeout:=Min(TimeoutMs,3000);H.IOTimeout:=TimeoutMs;H.AllowRedirect:=True;H.MaxRedirects:=2;
    H.AddHeader('User-Agent','REZVIVO/1.0 (+https://rezvivo.com)');
    H.AddHeader('Accept','*/*');
    try
      H.HTTPMethod('GET',URL,S,[200,400,404,405,429,500,502,503,504]);
      Code:=H.ResponseStatusCode;
      SetLength(Body,S.Size);
      if S.Size>0 then Move(S.Memory^,Body[1],S.Size);
      Result:=Code=200;
    except
      on E: Exception do Result:=False;
    end;
  finally S.Free;H.Free;end;
end;

function ParseBounds(const Text: string; out B: TBounds): Boolean;
var Parts: TStringArray; I: Integer; F: TFormatSettings;
begin
  Result:=False;Parts:=Text.Split([',']);if Length(Parts)<>4 then Exit;
  F:=DefaultFormatSettings;F.DecimalSeparator:='.';F.ThousandSeparator:=#0;
  for I:=0 to 3 do
    if not TryStrToFloat(Trim(Parts[I]),B[I],F) or IsNan(B[I]) or IsInfinite(B[I]) then Exit;
  Result:=(B[0]>=-90) and (B[2]<=90) and (B[1]>=-180) and (B[3]<=180)
    and (B[0]<B[2]) and (B[1]<B[3]);
end;

function QueryBounds(const Query: string; out B: TBounds): Boolean;
var I,J: Integer;
begin
  Result:=False;I:=Pos('[bbox:',Query);if I=0 then Exit;
  Inc(I,6);J:=I;while (J<=Length(Query)) and (Query[J]<>']') do Inc(J);
  if J>Length(Query) then Exit;
  Result:=ParseBounds(Copy(Query,I,J-I),B);
end;

function ValidURL(const S: string): Boolean;
var U: TURI; I: Integer;
begin
  Result:=False;
  if (Length(S)>512) or (S='') then Exit;
  for I:=1 to Length(S) do if (S[I]<=#32) or (S[I]=';') then Exit;
  U:=ParseURI(S);
  Result:=((U.Protocol='https') or (U.Protocol='http')) and (U.Host<>'')
    and (U.Username='') and (U.Password='') and (U.Params='') and (U.Bookmark='');
end;

function ValidHeightURL(const S: string): Boolean;
const Tokens: array[0..2] of string = ('{z}','{x}','{y}');
var I,P: Integer; Rest: string; U: TURI;
begin
  Result:=False;if not ValidURL(S) then Exit;
  U:=ParseURI(S);Rest:=U.Path+U.Document;
  for I:=0 to High(Tokens) do begin
    P:=Pos(Tokens[I],Rest);
    if (P=0) or (PosEx(Tokens[I],Rest,P+Length(Tokens[I]))<>0) then Exit;
    Rest:=StringReplace(Rest,Tokens[I],'0',[rfReplaceAll]);
  end;
  Result:=(Pos('{',Rest)=0) and (Pos('}',Rest)=0) and EndsText('.png',Rest);
end;

function ParseServers(A: TJSONData; Heights: Boolean): TServers;
var I,C: Integer; N: TJSONData; O: TJSONObject; S: TServer;
begin
  Result:=nil;
  if not (A is TJSONArray) or (A.Count>64) then Exit;
  SetLength(Result,A.Count);C:=0;
  for I:=0 to A.Count-1 do begin
    N:=A.Items[I];if not (N is TJSONObject) then Continue;
    O:=TJSONObject(N);S:=Default(TServer);S.URL:=O.Get('url','');
    S.Kind:=O.Get('kind','');S.Region:=O.Get('region','');
    if not ValidURL(S.URL) or ((S.Kind<>'own') and (S.Kind<>'public')) then Continue;
    if Heights then begin
      if (O.Get('format','')<>'terrarium') or not ValidHeightURL(S.URL) then Continue;
    end else if (Pos('{',S.URL)>0) or (Pos('}',S.URL)>0) then Continue;
    if (S.Region<>'world') and (S.Region<>'ru') and (S.Region<>'bbox') then Continue;
    if (S.Region='bbox') and not ParseBounds(O.Get('bbox',''),S.Bounds) then Continue;
    if not Heights and not ParseRequestLimits(O,S.URL,S.Limits)then Continue;
    Result[C]:=S;Inc(C);
  end;
  SetLength(Result,C);
end;

function ParseDirectory(const Text: string; out D: TDirectory): Boolean;
var J,A,R,P,Point: TJSONData; O: TJSONObject; I,K,L: Integer;
begin
  D:=Default(TDirectory);Result:=False;J:=nil;
  if Length(Text)>1024*1024 then Exit;
  try
    try
      J:=GetJSON(Text);
      if not (J is TJSONObject) then Exit;
      O:=TJSONObject(J);if O.Get('version',0)<>1 then Exit;
      D.TTL:=EnsureRange(O.Get('ttl_seconds',300),60,3600);
      A:=O.Find('servers');if not (A is TJSONArray) or (A.Count>64) then Exit;
      D.Servers:=ParseServers(A,False);
      D.HeightServers:=ParseServers(O.Find('height_servers'),True);
      R:=J.FindPath('regions.ru');
      if R is TJSONArray then begin
        if R.Count>128 then Exit;
        SetLength(D.Russia,R.Count);
        for I:=0 to R.Count-1 do begin
          if not (R.Items[I] is TJSONObject) then Exit;
          O:=TJSONObject(R.Items[I]);D.Russia[I].Hole:=O.Get('hole',False);
          P:=O.Find('points');if not (P is TJSONArray) or (P.Count>20000) then Exit;
          SetLength(D.Russia[I].Points,P.Count);
          for K:=0 to P.Count-1 do begin
            Point:=P.Items[K];if not (Point is TJSONArray) or (Point.Count<>2) then Exit;
            for L:=0 to 1 do if Point.Items[L].JSONType<>jtNumber then Exit;
            D.Russia[I].Points[K].X:=Point.Items[0].AsFloat;
            D.Russia[I].Points[K].Y:=Point.Items[1].AsFloat;
          end;
        end;
      end;
      Result:=True;
    except on E: Exception do Result:=False;end;
  finally J.Free;end;
end;

function InRing(const P: TPoint; const Ring: TRing): Boolean;
var I,J: Integer; A,B: TPoint;
begin
  Result:=False;J:=High(Ring.Points);
  for I:=0 to High(Ring.Points) do begin
    A:=Ring.Points[I];B:=Ring.Points[J];
    if ((A.Y>P.Y)<>(B.Y>P.Y)) and
      (P.X<(B.X-A.X)*(P.Y-A.Y)/(B.Y-A.Y)+A.X) then Result:=not Result;
    J:=I;
  end;
end;

function InRegion(const P: TPoint; const Rings: TRings): Boolean;
var I: Integer;
begin
  Result:=False;
  for I:=0 to High(Rings) do if InRing(P,Rings[I]) then begin
    if Rings[I].Hole then Exit(False);
    Result:=True;
  end;
end;

function SegmentTouchesBox(const A,B: TPoint; const Box: TBounds): Boolean;
var Lo,Hi,D,U,V,T: Double; Axis: Integer; X,Y,MinV,MaxV: Double;
begin
  Lo:=0;Hi:=1;
  for Axis:=0 to 1 do begin
    if Axis=0 then begin X:=A.X;Y:=B.X;MinV:=Box[1];MaxV:=Box[3];end
    else begin X:=A.Y;Y:=B.Y;MinV:=Box[0];MaxV:=Box[2];end;
    D:=Y-X;
    if Abs(D)<1e-12 then begin if (X<MinV) or (X>MaxV) then Exit(False);end
    else begin
      U:=(MinV-X)/D;V:=(MaxV-X)/D;
      if U>V then begin T:=U;U:=V;V:=T;end;
      Lo:=Max(Lo,U);Hi:=Min(Hi,V);if Lo>Hi then Exit(False);
    end;
  end;
  Result:=True;
end;

function RegionContains(const Rings: TRings; const B: TBounds): Boolean;
var I,K,Prev: Integer; P: TPoint;
begin
  Result:=False;
  for I:=0 to 3 do begin
    if I mod 2=0 then P.X:=B[1] else P.X:=B[3];
    if I<2 then P.Y:=B[0] else P.Y:=B[2];
    if not InRegion(P,Rings) then Exit;
  end;
  { Reject boundary crossings AND holes entirely inside a tile. Corner tests
    alone incorrectly classify tiles straddling a concave national border. }
  for I:=0 to High(Rings) do begin
    Prev:=High(Rings[I].Points);
    for K:=0 to High(Rings[I].Points) do begin
      if SegmentTouchesBox(Rings[I].Points[Prev],Rings[I].Points[K],B) then Exit;
      Prev:=K;
    end;
  end;
  Result:=True;
end;

function Candidates(const D: TDirectory; const B: TBounds;
  HasBox, Heights: Boolean): TStringArray;
var Matches,HasPublic: Boolean; I,Pass: Integer;
    S: TServer; Defaults: TStringArray; Servers: TServers;
  procedure Add(const URL: string);
  var K: Integer;
  begin
    for K:=0 to High(Result) do if Result[K]=URL then Exit;
    SetLength(Result,Length(Result)+1);Result[High(Result)]:=URL;
  end;
begin
  Result:=nil;HasPublic:=False;
  if Heights then Servers:=D.HeightServers else Servers:=D.Servers;
  for Pass:=0 to 1 do for I:=0 to High(Servers) do begin
    S:=Servers[I];if (Pass=0)<>(S.Kind='own') then Continue;
    { A cached directory may still advertise the previous DEM during rollout.
      It must not populate the new Mapzen geometry/cache namespace. Explicit
      URL templates remain available for a deliberate Copernicus comparison. }
    if Heights and (Pos('/height/cop2021-v1/', S.URL) > 0) then Continue;
    Matches:=S.Region='world';
    if HasBox and (S.Region='bbox') then
      Matches:=(B[0]>=S.Bounds[0]) and (B[1]>=S.Bounds[1]) and (B[2]<=S.Bounds[2]) and (B[3]<=S.Bounds[3]);
    if HasBox and (S.Region='ru') then Matches:=RegionContains(D.Russia,B);
    if Matches then begin Add(S.URL);HasPublic:=HasPublic or (S.Kind='public');end;
  end;
  if not HasPublic then begin
    if Heights then Add(HEIGHT_PUBLIC_TEMPLATE)
    else begin
      Defaults:=OSM_PUBLIC_ENDPOINTS.Split([';']);for I:=0 to High(Defaults) do Add(Defaults[I]);
    end;
  end;
end;

function HeightDatasetCacheKey(const URLTemplate: string): string;
begin
  if (Trim(URLTemplate)='') or SameText(Trim(URLTemplate),OSM_DIRECTORY_MODE) then
    Result := HEIGHT_DATASET_REVISION+'|auto'
  else
    Result := 'explicit|'+Trim(URLTemplate);
end;

function OsmCandidatesFromJSON(const Document, Query: string): TStringArray;
var D: TDirectory; B: TBounds; HasBox: Boolean;
begin
  if not ParseDirectory(Document,D) then D:=Default(TDirectory);
  HasBox:=QueryBounds(Query,B);
  Result:=Candidates(D,B,HasBox,False);
end;

function HeightCandidatesFromJSON(const Document: string;
  const South, West, North, East: Double): TStringArray;
var D: TDirectory; B: TBounds;
begin
  if not ParseDirectory(Document,D) then D:=Default(TDirectory);
  B[0]:=South;B[1]:=West;B[2]:=North;B[3]:=East;
  Result:=Candidates(D,B,True,True);
end;

function DirectoryCacheFile:string;
var Root:string;
begin
  Root:=GetAppConfigDir(False);
  if (GetEnvironmentVariable('REZVIVO_TEST_AUTH_FILE')<>'') and
    (GetEnvironmentVariable('REZVIVO_TEST_CACHE_ROOT')<>'') then
    Root:=GetEnvironmentVariable('REZVIVO_TEST_CACHE_ROOT');
  Result:=IncludeTrailingPathDelimiter(Root)+'osm-servers.json';
end;

procedure LoadDiskDirectory;
var CacheFile: string; S: TStringList; D: TDirectory; Loaded: TDateTime;
begin
  EnterCriticalSection(GGuard);
  try
    if GDiskLoaded then Exit;
    GDiskLoaded:=True;
    CacheFile:=DirectoryCacheFile;
    S:=TStringList.Create;
    try
      try
        if FileExists(CacheFile) and FileAge(CacheFile,Loaded) and (Now-Loaded<1) then begin
          S.LoadFromFile(CacheFile);
          if ParseDirectory(S.Text,D) then begin
            GDirectory:=D;GLoadedAt:=Loaded;
            if (Now-Loaded)*86400<D.TTL then
              GNextRefresh:=GetTickCount64+QWord(Max(1,D.TTL-Round((Now-Loaded)*86400)))*1000;
          end;
        end;
      except on E: Exception do ;end;
    finally S.Free;end;
  finally LeaveCriticalSection(GGuard);end;
end;

procedure RefreshDirectory;
const Hosts: array[0..1] of string = ('https://rezvivo.com','https://rezvivo.ru');
var D: TDirectory; Body,CacheFile: string; I,Code: Integer; S: TStringList;
    Good: Boolean; Loaded: TDateTime; Deadline: QWord;
begin
  LoadDiskDirectory;
  Deadline:=GetTickCount64+6500;
  repeat
    EnterCriticalSection(GGuard);
    if GetTickCount64<GNextRefresh then begin LeaveCriticalSection(GGuard);Exit;end;
    if not GRefreshing then begin GRefreshing:=True;LeaveCriticalSection(GGuard);Break;end;
    LeaveCriticalSection(GGuard);
    if GetTickCount64>=Deadline then Exit;
    Sleep(20);
  until False;
  Good:=False;Loaded:=0;
  try
    CacheFile:=DirectoryCacheFile;
    for I:=0 to High(Hosts) do
      if ReadHTTP(Hosts[I]+'/api/v1/osm/servers',Body,Code) and ParseDirectory(Body,D) then begin
        Good:=True;Loaded:=Now;
        EnterCriticalSection(GGuard);
        try GDirectory:=D;GLoadedAt:=Loaded;finally LeaveCriticalSection(GGuard);end;
        S:=TStringList.Create;
        try
          try
            ForceDirectories(ExtractFilePath(CacheFile));S.Text:=Body;S.SaveToFile(CacheFile);
          except on E: Exception do ;end;
        finally S.Free;end;
        Break;
      end;
  finally
    EnterCriticalSection(GGuard);
    try
      if Good then GNextRefresh:=GetTickCount64+QWord(Max(1,D.TTL-Round((Now-Loaded)*86400)))*1000
      else GNextRefresh:=GetTickCount64+60000;
      GRefreshing:=False;
    finally LeaveCriticalSection(GGuard);end;
  end;
end;

function OsmServerCandidates(const Query: string): TStringArray;
var D: TDirectory; B: TBounds; HasBox: Boolean;
begin
  RefreshDirectory;
  EnterCriticalSection(GGuard);
  try
    if (GLoadedAt>0) and (Now-GLoadedAt<1) then D:=GDirectory else D:=Default(TDirectory);
  finally LeaveCriticalSection(GGuard);end;
  HasBox:=QueryBounds(Query,B);
  Result:=Candidates(D,B,HasBox,False);
end;

function HeightServerCandidates(const South, West, North, East: Double;
  AllowRefresh: Boolean): TStringArray;
var D: TDirectory; B: TBounds; Fresh: Boolean;
begin
  if AllowRefresh then RefreshDirectory else LoadDiskDirectory;
  EnterCriticalSection(GGuard);
  try
    if (GLoadedAt>0) and (Now-GLoadedAt<1) then D:=GDirectory else D:=Default(TDirectory);
    Fresh:=(GLoadedAt>0) and ((Now-GLoadedAt)*86400<D.TTL);
  finally LeaveCriticalSection(GGuard);end;
  B[0]:=South;B[1]:=West;B[2]:=North;B[3]:=East;
  { Until discovery is known, a cache-only read cannot establish which DEM
    is preferred. Let its worker discover before choosing an old public tile. }
  if not AllowRefresh and ((Length(D.HeightServers)=0) or not Fresh) then Exit(nil);
  Result:=Candidates(D,B,True,True);
end;

function RequestLimitsLocked(const URL:string):TOsmRequestLimits;
var I:Integer;L:TOsmRequestLimits;
begin
  Result:=DefaultRequestLimits(URL);
  for I:=0 to High(GDirectory.Servers)do if GDirectory.Servers[I].URL=URL then begin
    Result:=GDirectory.Servers[I].Limits;Break;
  end;
  if Result.Group='' then Exit;
  for I:=0 to High(GDirectory.Servers)do begin L:=GDirectory.Servers[I].Limits;
    if L.Group=Result.Group then begin
      Result.MinIntervalMs:=Max(Result.MinIntervalMs,L.MinIntervalMs);
      Result.MaxConcurrent:=Min(Result.MaxConcurrent,L.MaxConcurrent);
    end;
  end;
end;

function OsmRequestLimits(const URL:string):TOsmRequestLimits;
begin
  LoadDiskDirectory;
  EnterCriticalSection(GGuard);
  try Result:=RequestLimitsLocked(URL);finally LeaveCriticalSection(GGuard);end;
end;

function OsmTryAcquireRequest(const URL:string;out Lease:string):Boolean;
var L:TOsmRequestLimits;I,K:Integer;Key:string;Tick:QWord;
begin
  Result:=False;Lease:='';LoadDiskDirectory;
  EnterCriticalSection(GGuard);
  try
    L:=RequestLimitsLocked(URL);
    if L.Group='' then Key:='url:'+URL else Key:='group:'+L.Group;
    K:=-1;
    for I:=0 to High(GBudgets)do if GBudgets[I].Key=Key then begin K:=I;Break;end;
    if K<0 then begin K:=Length(GBudgets);SetLength(GBudgets,K+1);GBudgets[K].Key:=Key;end;
    Tick:=GetTickCount64;
    if(GBudgets[K].Active>=L.MaxConcurrent)or
      ((GBudgets[K].LastStart>0)and(Tick-GBudgets[K].LastStart<QWord(L.MinIntervalMs)))then Exit;
    Inc(GBudgets[K].Active);GBudgets[K].LastStart:=Tick;Lease:=Key;Result:=True;
    Inc(GRequestActive);GRequestPeak:=Max(GRequestPeak,GRequestActive);
  finally LeaveCriticalSection(GGuard);end;
end;

procedure OsmReleaseRequest(const Lease:string);
var I:Integer;
begin
  if Lease='' then Exit;
  EnterCriticalSection(GGuard);
  try
    for I:=0 to High(GBudgets)do if GBudgets[I].Key=Lease then begin
      if GBudgets[I].Active>0 then begin Dec(GBudgets[I].Active);Dec(GRequestActive);end;Break;
    end;
  finally LeaveCriticalSection(GGuard);end;
end;

function OsmRequestStats:TOsmRequestStats;
begin
  EnterCriticalSection(GGuard);
  try Result.Active:=GRequestActive;Result.Peak:=GRequestPeak;finally LeaveCriticalSection(GGuard);end;
end;

function HealthIndex(const URL: string): Integer;
var I: Integer;
begin
  for I:=0 to High(GHealth) do if GHealth[I].URL=URL then Exit(I);
  Result:=Length(GHealth);SetLength(GHealth,Result+1);GHealth[Result].URL:=URL;
end;

function OsmEndpointLastError(const URL:string):string;
var I:Integer;
begin
  EnterCriticalSection(GGuard);
  try I:=HealthIndex(URL);Result:=GHealth[I].LastError;
  finally LeaveCriticalSection(GGuard);end;
end;

procedure OsmEndpointResult(const URL: string; Success: Boolean; const ErrorText:string);
var I: Integer;
begin
  EnterCriticalSection(GGuard);
  try
    I:=HealthIndex(URL);
    if Success then begin GHealth[I].FailedUntil:=0;GHealth[I].LastError:='' end
    else begin GHealth[I].FailedUntil:=GetTickCount64+30000;GHealth[I].LastError:=ErrorText end;
  finally LeaveCriticalSection(GGuard);end;
end;

function OsmEndpointCanTry(const URL: string): Boolean;
var I: Integer;
begin
  { The real map request determines reachability. A separate /status request
    can time out or be blocked even when interpreter works, and adds latency. }
  EnterCriticalSection(GGuard);
  try
    I:=HealthIndex(URL);
    Result:=GHealth[I].FailedUntil<=GetTickCount64;
  finally LeaveCriticalSection(GGuard);end;
end;

initialization
  InitCriticalSection(GGuard);
{ The lock remains valid through late game-view teardown, like the HTTP fetcher lock. }
end.
