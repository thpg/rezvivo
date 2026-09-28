unit Osm3dOsmAccess;
{$mode objfpc}{$H+}

interface

uses Classes, SysUtils;

type
  TOsmAccessTokenProvider = function: string;
  TOsmAbortCheck = function: Boolean of object;
  TOsmReadProgress = procedure(Received: Int64) of object;

{ Register before starting workers. No secret is stored in this unit or the
  directory cache. Only these exact HTTPS endpoints may receive credentials. }
var OsmAccessTokenProvider: TOsmAccessTokenProvider = nil;

function OsmRequiresAccess(const URL: string): Boolean;
function HeightRequiresAccess(const URL: string): Boolean;
function MapRequiresAccess(const URL: string): Boolean;
function OsmPublicNativeEndpoint(const URL: string): Boolean;
function OsmPublicPost(const URL, Body: string; ConnectMs, ReadMs: Integer;
  Response: TStream; Aborted: TOsmAbortCheck; Progress: TOsmReadProgress): Integer;
function OsmAuthenticatedRequest(const URL, Method, Body, Token: string;
  ConnectMs, ReadMs: Integer; Response: TStream;
  Aborted: TOsmAbortCheck; Progress: TOsmReadProgress): Integer;
function OsmAuthenticatedPost(const URL, Body, Token: string;
  ConnectMs, ReadMs: Integer; Response: TStream;
  Aborted: TOsmAbortCheck; Progress: TOsmReadProgress): Integer;

implementation

uses {$ifdef MSWINDOWS} Windows, SyncObjs, {$endif} URIParser;

function OsmRequiresAccess(const URL: string): Boolean;
begin
  Result := SameText(URL, 'https://rezvivo.com/osm/api/interpreter') or
    SameText(URL, 'https://rezvivo.ru/osm/api/interpreter');
end;

function OsmPublicNativeEndpoint(const URL: string): Boolean;
begin
  {$ifdef MSWINDOWS}
  Result := (URL='https://overpass-api.de/api/interpreter') or
    (URL='https://maps.mail.ru/osm/tools/overpass/api/interpreter') or
    (URL='https://overpass.private.coffee/api/interpreter');
  {$else}Result:=False;{$endif}
end;

function TileRequiresAccess(const URL: string; const Prefixes: array of string;
  MinZoom,MaxZoom:Integer): Boolean;
var I, P, Z, X, Y: Integer; S, Part: string;
  function TakeNumber(out V: Integer): Boolean;
  begin
    P := Pos('/', S);
    if P=0 then P:=Length(S)+1;
    Part:=Copy(S,1,P-1);Delete(S,1,P);
    Result:=TryStrToInt(Part,V);
    if Result then Result:=(V>=0) and (IntToStr(V)=Part);
  end;
begin
  Result:=False;
  for I:=0 to High(Prefixes) do
    if Copy(URL,1,Length(Prefixes[I]))=Prefixes[I] then begin
      S:=Copy(URL,Length(Prefixes[I])+1,MaxInt);
      if Copy(S,Length(S)-3,4)<>'.png' then Exit;
      Delete(S,Length(S)-3,4);
      if not TakeNumber(Z) then Exit;
      if (Z<MinZoom) or (Z>MaxZoom) or (S='') then Exit;
      if not TakeNumber(X) or (S='') then Exit;
      if Pos('/',S)<>0 then Exit;
      if not TakeNumber(Y) then Exit;
      Result:=(X<(1 shl Z)) and (Y<(1 shl Z)) and (S='');
      Exit;
    end;
end;

function HeightRequiresAccess(const URL:string):Boolean;
begin
  Result:=TileRequiresAccess(URL,['https://rezvivo.com/height/cop2021-v1/',
    'https://rezvivo.ru/height/cop2021-v1/',
    'https://rezvivo.com/height/mapzen-geotiff-v1/',
    'https://rezvivo.ru/height/mapzen-geotiff-v1/'],8,15);
end;

function MapRequiresAccess(const URL:string):Boolean;
begin
  Result:=TileRequiresAccess(URL,['https://rezvivo.com/map/world-ne-v1/',
    'https://rezvivo.ru/map/world-ne-v1/'],0,10) or
    TileRequiresAccess(URL,['https://rezvivo.com/map/land-ne-v1/',
    'https://rezvivo.ru/map/land-ne-v1/'],10,10) or
    TileRequiresAccess(URL,['https://rezvivo.com/map/terrain-ne-v1/',
    'https://rezvivo.ru/map/terrain-ne-v1/'],0,7);
end;

{$ifdef MSWINDOWS}
var HeightActiveRequests: LongInt = 0;
const
  WH_ASYNC = $10000000;
  WH_SECURE = $00800000;
  WH_SENT = $00400000;
  WH_HEADERS = $00020000;
  WH_READ = $00080000;
  WH_ERROR = $00200000;
  WH_CLOSING = $00000800;
  WH_CONTEXT = 45;
  WH_REDIRECT_POLICY = 88;
  WH_REDIRECT_NEVER = 0;

type
  TAsyncResult = record Result: PtrUInt; Error: DWORD; end;
  PAsyncResult = ^TAsyncResult;
  TStatusCallback = procedure(H: Pointer; Context: PtrUInt;
    Status: DWORD; Info: Pointer; InfoLength: DWORD); stdcall;
  TOsmRequest = class
    Completed, Closed: TEvent;
    Status, Error, BytesRead: DWORD;
    AbortCheck: TOsmAbortCheck;
    constructor Create(Check: TOsmAbortCheck);
    destructor Destroy; override;
    procedure WaitFor(Expected: DWORD);
  end;

function WinHttpOpen(Agent: PWideChar; Access: DWORD; Proxy, Bypass: PWideChar; Flags: DWORD): Pointer; stdcall; external 'winhttp.dll';
function WinHttpConnect(Session: Pointer; Host: PWideChar; Port: Word; Reserved: DWORD): Pointer; stdcall; external 'winhttp.dll';
function WinHttpOpenRequest(Connection: Pointer; Verb, Path, Version, Referrer: PWideChar; Accept: Pointer; Flags: DWORD): Pointer; stdcall; external 'winhttp.dll';
function WinHttpSetOption(H: Pointer; Option: DWORD; Buffer: Pointer; Length: DWORD): BOOL; stdcall; external 'winhttp.dll';
function WinHttpSetTimeouts(H: Pointer; Resolve, Connect, Send, Receive: Integer): BOOL; stdcall; external 'winhttp.dll';
function WinHttpSetStatusCallback(H: Pointer; Callback: TStatusCallback; Flags: DWORD; Reserved: PtrUInt): Pointer; stdcall; external 'winhttp.dll';
function WinHttpSendRequest(H: Pointer; Headers: PWideChar; HeaderLength: DWORD; Body: Pointer; BodyLength, TotalLength: DWORD; Context: PtrUInt): BOOL; stdcall; external 'winhttp.dll';
function WinHttpReceiveResponse(H, Reserved: Pointer): BOOL; stdcall; external 'winhttp.dll';
function WinHttpQueryHeaders(H: Pointer; Info: DWORD; Name: PWideChar; Buffer: Pointer; var Length: DWORD; Index: Pointer): BOOL; stdcall; external 'winhttp.dll';
function WinHttpReadData(H, Buffer: Pointer; Length: DWORD; Read: Pointer): BOOL; stdcall; external 'winhttp.dll';
function WinHttpCloseHandle(H: Pointer): BOOL; stdcall; external 'winhttp.dll';

constructor TOsmRequest.Create(Check: TOsmAbortCheck);
begin
  inherited Create;
  Completed := TEvent.Create(nil, False, False, '');
  Closed := TEvent.Create(nil, True, False, '');
  AbortCheck := Check;
end;

destructor TOsmRequest.Destroy;
begin
  Closed.Free;
  Completed.Free;
  inherited;
end;

procedure TOsmRequest.WaitFor(Expected: DWORD);
begin
  repeat
    if Assigned(AbortCheck) and AbortCheck() then raise EAbort.Create('aborted');
  until Completed.WaitFor(25) = wrSignaled;
  if Error <> 0 then raise Exception.CreateFmt('OSM HTTPS transport failed (%d)', [Error]);
  if Status <> Expected then raise Exception.Create('Unexpected OSM HTTPS completion');
end;

procedure RequestStatus(H: Pointer; Context: PtrUInt; Status: DWORD;
  Info: Pointer; InfoLength: DWORD); stdcall;
var R: TOsmRequest;
begin
  if Context = 0 then Exit;
  R := TOsmRequest(Context);
  if Status = WH_CLOSING then begin R.Closed.SetEvent; Exit; end;
  if (Status <> WH_SENT) and (Status <> WH_HEADERS) and
    (Status <> WH_READ) and (Status <> WH_ERROR) then Exit;
  R.Status := Status;
  if (Status = WH_ERROR) and (Info <> nil) then R.Error := PAsyncResult(Info)^.Error;
  if Status = WH_READ then R.BytesRead := InfoLength;
  R.Completed.SetEvent;
end;

procedure Checked(OK: BOOL);
begin
  if not OK then raise Exception.CreateFmt('OSM HTTPS transport failed (%d)', [GetLastError]);
end;
{$endif}

function NativeRequest(const URL, Method, Body, Token: string; Authenticated: Boolean;
  ConnectMs, ReadMs: Integer; Response: TStream;
  Aborted: TOsmAbortCheck; Progress: TOsmReadProgress): Integer;
{$ifdef MSWINDOWS}
var
  Session, Connection, Request: Pointer;
  R: TOsmRequest;
  U: TURI;
  Host, Headers, Verb, RequestPath: UnicodeString;
  Context: PtrUInt;
  Policy, Code, Size: DWORD;
  CallbackInstalled: Boolean;
  HeightSlot: Boolean;
  ActiveCount: LongInt;
  Buffer: array[0..16383] of Byte;
{$endif}
begin
  Result := 401;
  if Authenticated then begin
    if not (((Method='POST') and OsmRequiresAccess(URL)) or
            ((Method='GET') and (HeightRequiresAccess(URL) or MapRequiresAccess(URL)))) or (Token = '') or
      (Pos(#13, Token) <> 0) or (Pos(#10, Token) <> 0) then Exit;
  end else if (Method<>'POST') or not OsmPublicNativeEndpoint(URL) or (Token<>'') then Exit;
  {$ifdef MSWINDOWS}
  { OS certificate chain, expiry and hostname validation. No security flags
    are relaxed. Async I/O lets teardown cancel without waiting for HTTP. }
  U := ParseURI(URL, False);
  Host := UTF8Decode(U.Host);
  Verb := UTF8Decode(Method);
  RequestPath := UTF8Decode(U.Path + U.Document);
  Headers := UTF8Decode('Content-Type: text/plain; charset=utf-8' + #13#10);
  if Authenticated then
    Headers:=UTF8Decode('Authorization: Bearer ' + Token + #13#10)+Headers;
  Session := nil; Connection := nil; Request := nil;
  CallbackInstalled := False;
  HeightSlot := False;
  R := TOsmRequest.Create(Aborted);
  try
    if Method='GET' then begin
      { Terrain prefetch can create dozens of tile workers. Keep server/TLS
        concurrency bounded while queued requests remain cancellable. }
      repeat
        if Assigned(Aborted) and Aborted() then raise EAbort.Create('aborted');
        ActiveCount:=InterlockedCompareExchange(HeightActiveRequests,0,0);
        if (ActiveCount<8) and
           (InterlockedCompareExchange(HeightActiveRequests,ActiveCount+1,ActiveCount)=ActiveCount) then begin
          HeightSlot:=True;Break;
        end;
        Sleep(25);
      until False;
    end;
    { Direct connection matches the existing OSM fetcher; endpoint failover
      tests reachability from this machine, independently of browser proxies. }
    Session := WinHttpOpen('REZVIVO/1.0', 1, nil, nil, WH_ASYNC);
    Checked(Session <> nil);
    Checked(WinHttpSetTimeouts(Session, ConnectMs, ConnectMs, ReadMs, ReadMs));
    Connection := WinHttpConnect(Session, PWideChar(Host), 443, 0);
    Checked(Connection <> nil);
    Request := WinHttpOpenRequest(Connection, PWideChar(Verb), PWideChar(RequestPath), nil, nil, nil, WH_SECURE);
    Checked(Request <> nil);
    { WinHTTP negotiates gzip/deflate and delivers decoded bytes. Older
      systems that do not support this optional flag retain plain responses. }
    Policy := 3;
    WinHttpSetOption(Request, 118, @Policy, SizeOf(Policy));
    Policy := WH_REDIRECT_NEVER;
    Checked(WinHttpSetOption(Request, WH_REDIRECT_POLICY, @Policy, SizeOf(Policy)));
    Context := PtrUInt(R);
    Checked(WinHttpSetOption(Request, WH_CONTEXT, @Context, SizeOf(Context)));
    Checked(WinHttpSetStatusCallback(Request, @RequestStatus,
      WH_SENT or WH_HEADERS or WH_READ or WH_ERROR or WH_CLOSING, 0) <> Pointer(-1));
    CallbackInstalled := True;
    if Assigned(Aborted) and Aborted() then raise EAbort.Create('aborted');
    Checked(WinHttpSendRequest(Request, PWideChar(Headers), Length(Headers),
      Pointer(Body), Length(Body), Length(Body), Context));
    R.WaitFor(WH_SENT);
    Checked(WinHttpReceiveResponse(Request, nil));
    R.WaitFor(WH_HEADERS);
    Code := 0; Size := SizeOf(Code);
    Checked(WinHttpQueryHeaders(Request, 19 or $20000000, nil, @Code, Size, nil));
    Result := Code;
    if Result <> 200 then Exit;
    repeat
      Checked(WinHttpReadData(Request, @Buffer[0], SizeOf(Buffer), nil));
      R.WaitFor(WH_READ);
      if R.BytesRead = 0 then Break;
      Response.WriteBuffer(Buffer[0], R.BytesRead);
      if Assigned(Progress) then Progress(Response.Size);
    until False;
  finally
    if Request <> nil then
    begin
      WinHttpCloseHandle(Request);
      { The final callback is the lifetime fence for its context and buffers. }
      if CallbackInstalled then R.Closed.WaitFor(INFINITE);
    end;
    if Connection <> nil then WinHttpCloseHandle(Connection);
    if Session <> nil then WinHttpCloseHandle(Session);
    R.Free;
    if HeightSlot then InterlockedDecrement(HeightActiveRequests);
  end;
  {$else}
  { Never fall back to unverified TLS while carrying an account credential. }
  raise Exception.Create('Authenticated OSM HTTPS transport unavailable on this platform');
  {$endif}
end;

function OsmAuthenticatedRequest(const URL, Method, Body, Token: string;
  ConnectMs, ReadMs: Integer; Response: TStream;
  Aborted: TOsmAbortCheck; Progress: TOsmReadProgress): Integer;
begin
  Result:=NativeRequest(URL,Method,Body,Token,True,ConnectMs,ReadMs,Response,Aborted,Progress);
end;

function OsmPublicPost(const URL, Body: string; ConnectMs, ReadMs: Integer;
  Response: TStream; Aborted: TOsmAbortCheck; Progress: TOsmReadProgress): Integer;
begin
  Result:=NativeRequest(URL,'POST',Body,'',False,ConnectMs,ReadMs,Response,Aborted,Progress);
end;

function OsmAuthenticatedPost(const URL, Body, Token: string;
  ConnectMs, ReadMs: Integer; Response: TStream;
  Aborted: TOsmAbortCheck; Progress: TOsmReadProgress): Integer;
begin
  Result:=OsmAuthenticatedRequest(URL,'POST',Body,Token,ConnectMs,ReadMs,
    Response,Aborted,Progress);
end;

end.
