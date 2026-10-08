{ GameHttpClient — HTTP с дефолтным прокси, как у браузера.

  Windows: WinHTTP.
    1) настройки IE/WinINET (то, что обычно берёт браузер: PAC/WPAD/ручной прокси);
    2) иначе HTTPS_PROXY / HTTP_PROXY / ALL_PROXY;
    3) иначе WinHTTP autodetect.
  HTTPS через HTTP-прокси идёт CONNECT (это делает WinHTTP).

  Другие ОС: TFPHTTPClient. Прокси из env, только для http://
  (FPC 3.2 не делает CONNECT для https). }
unit GameHttpClient;

{$mode objfpc}{$H+}
{$codepage UTF8}

interface

uses
  Classes, SysUtils, SyncObjs;

type
  { Owned by the worker's owner; keep alive until the worker has joined.
    Cancelling never takes a lock held across network I/O. }
  TGameHttpCancellation = class
  private
    FLock: TCriticalSection;
    FCancelled: Boolean;
    FRequest: Pointer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Cancel;
    procedure Check;
    procedure Attach(Request: Pointer);
    procedure Detach(Request: Pointer);
  end;

{ Выполнить запрос. Транспортные ошибки — exception.
  HTTP 4xx/5xx не exception: код в AStatus, тело в AResponse. }
procedure GameHttpRequest(const AMethod, AUrl: String;
  AHeaders: TStrings; ARequestBody: TStream;
  AConnectTimeoutMs, AIOTimeoutMs: Integer;
  AResponse: TStream; out AStatus: Integer;
  Cancellation: TGameHttpCancellation = nil; ResponseHeaders: TStrings = nil);

function GameHttpGet(const AUrl: String;
  AConnectTimeoutMs, AIOTimeoutMs: Integer): String;
function GameHttpPost(const AUrl, AContentType, ABody: String;
  AHeaders: TStrings;
  AConnectTimeoutMs, AIOTimeoutMs: Integer): String;

implementation

uses
  URIParser,
  {$ifdef MSWINDOWS} Windows, {$endif}
  {$ifndef MSWINDOWS} fphttpclient, {$endif}
  CastleLog, GameBuildInfo;

{$ifdef MSWINDOWS}

const
  winhttp = 'winhttp.dll';
  wininet = 'wininet.dll';

  WINHTTP_ACCESS_TYPE_DEFAULT_PROXY     = 0;
  WINHTTP_ACCESS_TYPE_NO_PROXY          = 1;
  WINHTTP_ACCESS_TYPE_NAMED_PROXY       = 3;
  WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY   = 4;

  WINHTTP_FLAG_SECURE                   = $00800000;
  WINHTTP_QUERY_STATUS_CODE             = 19;
  WINHTTP_QUERY_FLAG_NUMBER             = $20000000;
  WINHTTP_ADDREQ_FLAG_ADD               = $20000000;
  WINHTTP_ADDREQ_FLAG_REPLACE           = $80000000;
  INTERNET_OPTION_PROXY                 = 38;
  INTERNET_OPEN_TYPE_PROXY              = 3;

type
  HINTERNET = Pointer;

  TWinHttpIEProxyConfig = record
    fAutoDetect: BOOL;
    lpszAutoConfigUrl: PWideChar;
    lpszProxy: PWideChar;
    lpszProxyBypass: PWideChar;
  end;

  TInternetProxyInfo = record
    dwAccessType: DWORD;
    lpszProxy: PWideChar;
    lpszProxyBypass: PWideChar;
  end;
  PInternetProxyInfo = ^TInternetProxyInfo;

function WinHttpOpen(pszAgentW: PWideChar; dwAccessType: DWORD;
  pszProxyW, pszProxyBypassW: PWideChar; dwFlags: DWORD): HINTERNET; stdcall;
  external winhttp name 'WinHttpOpen';
function WinHttpConnect(hSession: HINTERNET; pswzServerName: PWideChar;
  nServerPort: Word; dwReserved: DWORD): HINTERNET; stdcall;
  external winhttp name 'WinHttpConnect';
function WinHttpOpenRequest(hConnect: HINTERNET; pwszVerb, pwszObjectName,
  pwszVersion, pwszReferrer: PWideChar; ppwszAcceptTypes: Pointer;
  dwFlags: DWORD): HINTERNET; stdcall;
  external winhttp name 'WinHttpOpenRequest';
function WinHttpAddRequestHeaders(hRequest: HINTERNET; pwszHeaders: PWideChar;
  dwHeadersLength, dwModifiers: DWORD): BOOL; stdcall;
  external winhttp name 'WinHttpAddRequestHeaders';
function WinHttpSendRequest(hRequest: HINTERNET; pwszHeaders: PWideChar;
  dwHeadersLength: DWORD; lpOptional: Pointer; dwOptionalLength,
  dwTotalLength: DWORD; dwContext: PtrUInt): BOOL; stdcall;
  external winhttp name 'WinHttpSendRequest';
function WinHttpWriteData(hRequest: HINTERNET; lpBuffer: Pointer;
  dwBytesToWrite: DWORD; var lpdwWritten: DWORD): BOOL; stdcall;
  external winhttp name 'WinHttpWriteData';
function WinHttpReceiveResponse(hRequest: HINTERNET; lpReserved: Pointer): BOOL;
  stdcall; external winhttp name 'WinHttpReceiveResponse';
function WinHttpQueryHeaders(hRequest: HINTERNET; dwInfoLevel: DWORD;
  pwszName: PWideChar; lpBuffer: Pointer; var lpdwBufferLength: DWORD;
  lpdwIndex: PDWORD): BOOL; stdcall; external winhttp name 'WinHttpQueryHeaders';
function WinHttpQueryDataAvailable(hRequest: HINTERNET;
  var lpdwNumberOfBytesAvailable: DWORD): BOOL; stdcall;
  external winhttp name 'WinHttpQueryDataAvailable';
function WinHttpReadData(hRequest: HINTERNET; lpBuffer: Pointer;
  dwNumberOfBytesToRead: DWORD; var lpdwNumberOfBytesRead: DWORD): BOOL;
  stdcall; external winhttp name 'WinHttpReadData';
function WinHttpCloseHandle(hInternet: HINTERNET): BOOL; stdcall;
  external winhttp name 'WinHttpCloseHandle';
function WinHttpSetTimeouts(hInternet: HINTERNET; nResolve, nConnect,
  nSend, nReceive: Integer): BOOL; stdcall;
  external winhttp name 'WinHttpSetTimeouts';
function WinHttpGetIEProxyConfigForCurrentUser(
  var pProxyConfig: TWinHttpIEProxyConfig): BOOL; stdcall;
  external winhttp name 'WinHttpGetIEProxyConfigForCurrentUser';
function InternetQueryOptionW(hInet: Pointer; dwOption: DWORD; lpBuffer: Pointer;
  var lpdwBufferLength: DWORD): BOOL; stdcall;
  external wininet name 'InternetQueryOptionW';

type
  TProxyKind = (pkDirect, pkNamed, pkAuto);

  TResolvedProxy = record
    Kind:   TProxyKind;
    Named:  String;   { host:port }
    Bypass: String;
    Source: String;
  end;

var
  GProxyResolved: Boolean = False;
  GProxy: TResolvedProxy;
  GProxyLock: TRTLCriticalSection;

function WideFromUtf8(const S: String): WideString;
begin
  Result := UTF8Decode(S);
end;

function Utf8FromWide(const W: PWideChar): String;
begin
  if (W = nil) or (W^ = #0) then
    Result := ''
  else
    Result := UTF8Encode(WideString(W));
end;

procedure StripProxyScheme(var S: String);
var
  L: String;
begin
  L := LowerCase(S);
  if Copy(L, 1, 8) = 'https://' then
    Delete(S, 1, 8)
  else if Copy(L, 1, 7) = 'http://' then
    Delete(S, 1, 7)
  else if Copy(L, 1, 9) = 'socks5://' then
    Delete(S, 1, 9)
  else if Copy(L, 1, 8) = 'socks://' then
    Delete(S, 1, 8);
end;

{ Из «http=h:1;https=h:2» или «h:port» выбирает прокси для https. }
function PickNamedProxy(const Spec: String): String;
var
  Parts: TStringList;
  I, Eq: Integer;
  Name, Val, HttpsVal, HttpVal, Bare: String;
begin
  Result := '';
  Bare := '';
  HttpsVal := '';
  HttpVal := '';
  Parts := TStringList.Create;
  try
    Parts.Delimiter := ';';
    Parts.StrictDelimiter := True;
    Parts.DelimitedText := Spec;
    for I := 0 to Parts.Count - 1 do
    begin
      Val := Trim(Parts[I]);
      if Val = '' then Continue;
      Eq := Pos('=', Val);
      if Eq > 0 then
      begin
        Name := LowerCase(Trim(Copy(Val, 1, Eq - 1)));
        Val := Trim(Copy(Val, Eq + 1, MaxInt));
        if (Name = 'socks') or (Name = 'socks5') then
          Continue;
        if Name = 'https' then
          HttpsVal := Val
        else if Name = 'http' then
          HttpVal := Val;
      end
      else
        Bare := Val;
    end;
  finally
    Parts.Free;
  end;
  if HttpsVal <> '' then
    Result := HttpsVal
  else if Bare <> '' then
    Result := Bare
  else
    Result := HttpVal;
  StripProxyScheme(Result);
  { user:pass@host:port → host:port, auth WinHTTP не ставим из этой строки }
  I := Pos('@', Result);
  if I > 0 then
    Delete(Result, 1, I);
  Result := Trim(Result);
end;

function ParseEnvProxy: String;
  function One(const Name: String): String;
  begin
    Result := Trim(SysUtils.GetEnvironmentVariable(Name));
  end;
begin
  Result := One('HTTPS_PROXY');
  if Result = '' then Result := One('https_proxy');
  if Result = '' then Result := One('HTTP_PROXY');
  if Result = '' then Result := One('http_proxy');
  if Result = '' then Result := One('ALL_PROXY');
  if Result = '' then Result := One('all_proxy');
  Result := PickNamedProxy(Result);
end;

function ResolveProxy: TResolvedProxy;
var
  Cfg: TWinHttpIEProxyConfig;
  Pac, Named, Bypass, Env: String;
  Sz: DWORD;
  Buf: Pointer;
  Info: PInternetProxyInfo;
begin
  Result.Kind := pkAuto;
  Result.Named := '';
  Result.Bypass := 'localhost;127.0.0.1;<local>';
  Result.Source := 'WinHTTP autodetect';

  FillChar(Cfg, SizeOf(Cfg), 0);
  if WinHttpGetIEProxyConfigForCurrentUser(Cfg) then
  begin
    try
      Pac := Utf8FromWide(Cfg.lpszAutoConfigUrl);
      Named := PickNamedProxy(Utf8FromWide(Cfg.lpszProxy));
      Bypass := Utf8FromWide(Cfg.lpszProxyBypass);
      if Bypass <> '' then
        Result.Bypass := Bypass;
      if (Cfg.fAutoDetect <> False) or (Pac <> '') then
      begin
        Result.Kind := pkAuto;
        if Pac <> '' then
          Result.Source := 'IE PAC ' + Pac
        else
          Result.Source := 'IE WPAD';
        Exit;
      end;
      if Named <> '' then
      begin
        Result.Kind := pkNamed;
        Result.Named := Named;
        Result.Source := 'IE/WinINET ' + Named;
        Exit;
      end;
    finally
      if Cfg.lpszAutoConfigUrl <> nil then GlobalFree(HGLOBAL(Cfg.lpszAutoConfigUrl));
      if Cfg.lpszProxy <> nil then GlobalFree(HGLOBAL(Cfg.lpszProxy));
      if Cfg.lpszProxyBypass <> nil then GlobalFree(HGLOBAL(Cfg.lpszProxyBypass));
    end;
  end;

  Sz := 0;
  InternetQueryOptionW(nil, INTERNET_OPTION_PROXY, nil, Sz);
  if Sz >= SizeOf(TInternetProxyInfo) then
  begin
    GetMem(Buf, Sz);
    try
      FillChar(Buf^, Sz, 0);
      if InternetQueryOptionW(nil, INTERNET_OPTION_PROXY, Buf, Sz) then
      begin
        Info := PInternetProxyInfo(Buf);
        if Info^.dwAccessType = INTERNET_OPEN_TYPE_PROXY then
        begin
          Named := PickNamedProxy(Utf8FromWide(Info^.lpszProxy));
          Bypass := Utf8FromWide(Info^.lpszProxyBypass);
          if Bypass <> '' then
            Result.Bypass := Bypass;
          if Named <> '' then
          begin
            Result.Kind := pkNamed;
            Result.Named := Named;
            Result.Source := 'WinINET ' + Named;
            Exit;
          end;
        end;
      end;
    finally
      FreeMem(Buf);
    end;
  end;

  Env := ParseEnvProxy;
  if Env <> '' then
  begin
    Result.Kind := pkNamed;
    Result.Named := Env;
    Result.Source := 'env HTTPS_PROXY ' + Env;
    Exit;
  end;
end;

procedure EnsureProxyResolved;
begin
  EnterCriticalSection(GProxyLock);
  try
    if GProxyResolved then Exit;
    GProxy := ResolveProxy;
    GProxyResolved := True;
    case GProxy.Kind of
      pkNamed:
        WritelnLog('HTTP', 'Proxy: configured');
      pkAuto:
        WritelnLog('HTTP', 'Proxy: autodetect');
      pkDirect:
        WritelnLog('HTTP', 'Proxy: direct');
    end;
  finally
    LeaveCriticalSection(GProxyLock);
  end;
end;

function OpenWinHttpSession: HINTERNET;
var
  Access: DWORD;
  WProxy, WBypass, WAgent: WideString;
  PProxy, PBypass: PWideChar;
begin
  EnsureProxyResolved;
  WAgent := 'REZVIVO';
  PProxy := nil;
  PBypass := nil;
  Access := WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY;
  case GProxy.Kind of
    pkNamed:
      begin
        Access := WINHTTP_ACCESS_TYPE_NAMED_PROXY;
        WProxy := WideFromUtf8(GProxy.Named);
        WBypass := WideFromUtf8(GProxy.Bypass);
        PProxy := PWideChar(WProxy);
        PBypass := PWideChar(WBypass);
      end;
    pkAuto:
      Access := WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY;
    pkDirect:
      Access := WINHTTP_ACCESS_TYPE_NO_PROXY;
  end;
  Result := WinHttpOpen(PWideChar(WAgent), Access, PProxy, PBypass, 0);
  if Result <> nil then Exit;
  { Win7 / если AUTOMATIC_PROXY не поддержан }
  if Access = WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY then
  begin
    Result := WinHttpOpen(PWideChar(WAgent), WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
      nil, nil, 0);
    if Result <> nil then Exit;
    Result := WinHttpOpen(PWideChar(WAgent), WINHTTP_ACCESS_TYPE_NO_PROXY,
      nil, nil, 0);
  end;
  if Result = nil then
    raise Exception.CreateFmt('WinHttpOpen failed (%d)', [GetLastError]);
end;

procedure WinHttpRequest(const AMethod, AUrl: String;
  AHeaders: TStrings; ARequestBody: TStream;
  AConnectTimeoutMs, AIOTimeoutMs: Integer;
  AResponse: TStream; out AStatus: Integer;
  Cancellation: TGameHttpCancellation; ResponseHeaders: TStrings);
var
  URI: TURI;
  Session, Connect, Request: HINTERNET;
  WHost, WPath, WMethod, WHdr: WideString;
  Path, HdrLine, HdrAll: String;
  Port: Word;
  Flags, OptionalLen, TotalLen, Avail, Got, Sz, Modifiers: DWORD;
  Status: DWORD;
  Chunk: array[0..16383] of Byte;
  Optional: Pointer;
  BodyBuf: RawByteString;
  I: Integer;
  Secure: Boolean;
  procedure ReadHeader(const Name: WideString);
  var Count: DWORD; Value: WideString;
  begin
    Count := 0;
    WinHttpQueryHeaders(Request, 65535, PWideChar(Name), nil, Count, nil);
    if (Count = 0) or (Count > 65536) then Exit;
    SetLength(Value, (Count + 1) div 2);
    if WinHttpQueryHeaders(Request, 65535, PWideChar(Name), @Value[1], Count, nil) then
      ResponseHeaders.Add(UTF8Encode(Name) + ': ' + UTF8Encode(WideString(PWideChar(Value))));
  end;
begin
  URI := ParseURI(AUrl, False);
  if (LowerCase(URI.Protocol) <> 'http') and (LowerCase(URI.Protocol) <> 'https') then
    raise Exception.Create('Unsupported URL: ' + AUrl);
  Secure := LowerCase(URI.Protocol) = 'https';
  Port := URI.Port;
  if Port = 0 then
    if Secure then Port := 443 else Port := 80;

  Path := URI.Path;
  if Path = '' then
    Path := '/';
  if (URI.Document <> '') then
  begin
    if (Path <> '') and (Path[Length(Path)] <> '/') then
      Path := Path + '/';
    Path := Path + URI.Document;
  end;
  if Path = '' then Path := '/';
  if URI.Params <> '' then
    Path := Path + '?' + URI.Params;

  Session := OpenWinHttpSession;
  Connect := nil;
  Request := nil;
  AStatus := 0;
  try
    WinHttpSetTimeouts(Session, 5000, AConnectTimeoutMs, AIOTimeoutMs, AIOTimeoutMs);
    WHost := WideFromUtf8(URI.Host);
    Connect := WinHttpConnect(Session, PWideChar(WHost), Port, 0);
    if Connect = nil then
      raise Exception.CreateFmt('WinHttpConnect %s failed (%d)',
        [URI.Host, GetLastError]);

    WMethod := WideFromUtf8(UpperCase(AMethod));
    WPath := WideFromUtf8(Path);
    Flags := 0;
    if Secure then
      Flags := WINHTTP_FLAG_SECURE;
    Request := WinHttpOpenRequest(Connect, PWideChar(WMethod), PWideChar(WPath),
      nil, nil, nil, Flags);
    if Request = nil then
      raise Exception.CreateFmt('WinHttpOpenRequest failed (%d)', [GetLastError]);

    if Cancellation <> nil then Cancellation.Attach(Request);

    WinHttpSetTimeouts(Request, 5000, AConnectTimeoutMs, AIOTimeoutMs, AIOTimeoutMs);

    HdrAll := '';
    if Assigned(AHeaders) then
      for I := 0 to AHeaders.Count - 1 do
      begin
        HdrLine := Trim(AHeaders[I]);
        if HdrLine = '' then Continue;
        if (Pos(':', HdrLine) = 0) then Continue;
        if LowerCase(Copy(HdrLine, 1, 5)) = 'host:' then Continue;
        HdrAll := HdrAll + HdrLine + #13#10;
      end;
    if HdrAll <> '' then
    begin
      WHdr := WideFromUtf8(HdrAll);
      Modifiers := WINHTTP_ADDREQ_FLAG_ADD or WINHTTP_ADDREQ_FLAG_REPLACE;
      if not WinHttpAddRequestHeaders(Request, PWideChar(WHdr), $FFFFFFFF, Modifiers) then
        raise Exception.CreateFmt('WinHttpAddRequestHeaders failed (%d)', [GetLastError]);
    end;

    Optional := nil;
    OptionalLen := 0;
    TotalLen := 0;
    BodyBuf := '';
    if Assigned(ARequestBody) and (ARequestBody.Size > 0) then
    begin
      ARequestBody.Position := 0;
      SetLength(BodyBuf, ARequestBody.Size);
      if Length(BodyBuf) > 0 then
        ARequestBody.ReadBuffer(BodyBuf[1], Length(BodyBuf));
      Optional := Pointer(BodyBuf);
      OptionalLen := Length(BodyBuf);
      TotalLen := OptionalLen;
    end;

    if not WinHttpSendRequest(Request, nil, 0, Optional, OptionalLen, TotalLen, 0) then
      raise Exception.CreateFmt('WinHttpSendRequest failed (%d)', [GetLastError]);
    if not WinHttpReceiveResponse(Request, nil) then
      raise Exception.CreateFmt('WinHttpReceiveResponse failed (%d)', [GetLastError]);

    Status := 0;
    Sz := SizeOf(Status);
    if not WinHttpQueryHeaders(Request,
      WINHTTP_QUERY_STATUS_CODE or WINHTTP_QUERY_FLAG_NUMBER,
      nil, @Status, Sz, nil) then
      raise Exception.CreateFmt('WinHttpQueryHeaders failed (%d)', [GetLastError]);
    AStatus := Integer(Status);
    if ResponseHeaders <> nil then
    begin
      ResponseHeaders.Clear;
      ReadHeader('Content-Range');
      ReadHeader('Content-Length');
      ReadHeader('Content-Type');
      ReadHeader('Content-Encoding');
      ReadHeader('ETag');
    end;

    if Assigned(AResponse) then
    begin
      repeat
        Avail := 0;
        if not WinHttpQueryDataAvailable(Request, Avail) then
          raise Exception.CreateFmt('WinHttpQueryDataAvailable failed (%d)',
            [GetLastError]);
        if Avail = 0 then Break;
        if Avail > SizeOf(Chunk) then
          Avail := SizeOf(Chunk);
        Got := 0;
        if not WinHttpReadData(Request, @Chunk[0], Avail, Got) then
          raise Exception.CreateFmt('WinHttpReadData failed (%d)', [GetLastError]);
        if Got = 0 then Break;
        AResponse.WriteBuffer(Chunk[0], Got);
      until False;
    end;
  finally
    if Request <> nil then
      if Cancellation <> nil then Cancellation.Detach(Request)
      else WinHttpCloseHandle(Request);
    if Connect <> nil then WinHttpCloseHandle(Connect);
    if Session <> nil then WinHttpCloseHandle(Session);
  end;
end;

{$else}

procedure FpcRequest(const AMethod, AUrl: String;
  AHeaders: TStrings; ARequestBody: TStream;
  AConnectTimeoutMs, AIOTimeoutMs: Integer;
  AResponse: TStream; out AStatus: Integer;
  Cancellation: TGameHttpCancellation; ResponseHeaders: TStrings);
var
  Http: TFPHTTPClient;
  ProxySpec, Named: String;
  Colon: Integer;
  I: Integer;
begin
  Http := TFPHTTPClient.Create(nil);
  try
    if Cancellation <> nil then Cancellation.Attach(Http);
    Http.ConnectTimeout := AConnectTimeoutMs;
    Http.IOTimeout := AIOTimeoutMs;
    Http.AllowRedirect := True;
    if Assigned(AHeaders) then
      for I := 0 to AHeaders.Count - 1 do
        if Pos(':', AHeaders[I]) > 0 then
          Http.RequestHeaders.Add(AHeaders[I]);
    if Assigned(ARequestBody) then
    begin
      ARequestBody.Position := 0;
      Http.RequestBody := ARequestBody;
    end;
    ProxySpec := Trim(SysUtils.GetEnvironmentVariable('HTTPS_PROXY'));
    if ProxySpec = '' then
      ProxySpec := Trim(SysUtils.GetEnvironmentVariable('HTTP_PROXY'));
    if (ProxySpec <> '') and (LowerCase(Copy(AUrl, 1, 7)) = 'http://') then
    begin
      Named := ProxySpec;
      if Copy(LowerCase(Named), 1, 7) = 'http://' then
        Delete(Named, 1, 7);
      Colon := RPos(':', Named);
      if Colon > 0 then
      begin
        Http.Proxy.Host := Copy(Named, 1, Colon - 1);
        Http.Proxy.Port := StrToIntDef(Copy(Named, Colon + 1, MaxInt), 80);
      end;
    end;
    try
      Http.HTTPMethod(AMethod, AUrl, AResponse, [200, 201, 202, 204, 206,
        400, 401, 403, 404, 409, 410, 413, 416, 422, 429, 500, 502, 503, 504]);
      AStatus := Http.ResponseStatusCode;
      if ResponseHeaders <> nil then ResponseHeaders.Assign(Http.ResponseHeaders);
    finally
      Http.RequestBody := nil;
    end;
  finally
    if Cancellation <> nil then Cancellation.Detach(Http);
    Http.Free;
  end;
end;

{$endif}

constructor TGameHttpCancellation.Create;
begin
  inherited Create;
  FLock := SyncObjs.TCriticalSection.Create;
end;

destructor TGameHttpCancellation.Destroy;
begin
  FLock.Free;
  inherited;
end;

procedure TGameHttpCancellation.Check;
begin
  FLock.Enter;
  try
    if FCancelled then raise EAbort.Create('HTTP request cancelled');
  finally FLock.Leave end;
end;

procedure TGameHttpCancellation.Cancel;
begin
  FLock.Enter;
  try
    FCancelled := True;
    if FRequest <> nil then
    begin
      {$ifdef MSWINDOWS}
      WinHttpCloseHandle(FRequest);
      FRequest := nil;
      {$else}
      TFPHTTPClient(FRequest).Terminate;
      {$endif}
    end;
  finally FLock.Leave end;
end;

procedure TGameHttpCancellation.Attach(Request: Pointer);
begin
  FLock.Enter;
  try
    { Transfer ownership even when cancellation arrived just before Attach;
      the request's finally block still calls Detach exactly once. }
    FRequest := Request;
    if FCancelled then raise EAbort.Create('HTTP request cancelled');
  finally FLock.Leave end;
end;

procedure TGameHttpCancellation.Detach(Request: Pointer);
begin
  FLock.Enter;
  try
    if FRequest = Request then
    begin
      FRequest := nil;
      {$ifdef MSWINDOWS}WinHttpCloseHandle(Request);{$endif}
    end;
  finally FLock.Leave end;
end;

procedure GameHttpRequest(const AMethod, AUrl: String;
  AHeaders: TStrings; ARequestBody: TStream;
  AConnectTimeoutMs, AIOTimeoutMs: Integer;
  AResponse: TStream; out AStatus: Integer;
  Cancellation: TGameHttpCancellation; ResponseHeaders: TStrings);
var
  VersionHeaders:TStringList;
  RequestHeaders:TStrings;
  Host:String;
{$ifdef REZVIVO_STARTUP_TIMING}
  TimingStart: QWord;
{$endif}
begin
  if Cancellation <> nil then Cancellation.Check;
  if ResponseHeaders <> nil then ResponseHeaders.Clear;
  AStatus := 0;
  VersionHeaders:=nil;RequestHeaders:=AHeaders;
  Host:=LowerCase(ParseURI(AUrl).Host);
  if(Host='rezvivo.com')or(Host='rezvivo.ru')or
    ((SysUtils.GetEnvironmentVariable('REZVIVO_TEST_AUTH_FILE')<>'')and((Host='127.0.0.1')or(Host='localhost')))then begin
    VersionHeaders:=TStringList.Create;
    if AHeaders<>nil then VersionHeaders.Assign(AHeaders);
    VersionHeaders.Add('X-REZVIVO-Build: '+IntToStr(ClientBuild));
    RequestHeaders:=VersionHeaders;
  end;
  try
  {$ifdef REZVIVO_STARTUP_TIMING}
  TimingStart := GetTickCount64;
  WritelnLog('StartupTiming', 'http begin tick=%d thread=%d main=%s method=%s host=%s',
    [TimingStart, QWord(GetCurrentThreadId), BoolToStr(GetCurrentThreadId = MainThreadID, True),
     AMethod, ParseURI(AUrl).Host]);
  try
  {$endif}
  {$ifdef MSWINDOWS}
  WinHttpRequest(AMethod, AUrl, RequestHeaders, ARequestBody,
    AConnectTimeoutMs, AIOTimeoutMs, AResponse, AStatus, Cancellation, ResponseHeaders);
  {$else}
  FpcRequest(AMethod, AUrl, RequestHeaders, ARequestBody,
    AConnectTimeoutMs, AIOTimeoutMs, AResponse, AStatus, Cancellation, ResponseHeaders);
  {$endif}
  if Cancellation <> nil then Cancellation.Check;
  {$ifdef REZVIVO_STARTUP_TIMING}
  finally
    WritelnLog('StartupTiming', 'http end tick=%d thread=%d ms=%d status=%d',
      [TimingStart, QWord(GetCurrentThreadId), GetTickCount64 - TimingStart, AStatus]);
  end;
  {$endif}
  finally VersionHeaders.Free;end;
end;

function GameHttpGet(const AUrl: String;
  AConnectTimeoutMs, AIOTimeoutMs: Integer): String;
var
  Resp: TStringStream;
  Status: Integer;
begin
  Resp := TStringStream.Create('');
  try
    GameHttpRequest('GET', AUrl, nil, nil, AConnectTimeoutMs, AIOTimeoutMs,
      Resp, Status);
    if (Status < 200) or (Status >= 300) then
      raise Exception.CreateFmt('GET %s → %d', [AUrl, Status]);
    Result := Resp.DataString;
  finally
    Resp.Free;
  end;
end;

function GameHttpPost(const AUrl, AContentType, ABody: String;
  AHeaders: TStrings;
  AConnectTimeoutMs, AIOTimeoutMs: Integer): String;
var
  Hdr: TStringList;
  Body, Resp: TStringStream;
  Status: Integer;
  OwnHdr: Boolean;
begin
  OwnHdr := AHeaders = nil;
  if OwnHdr then
  begin
    Hdr := TStringList.Create;
    Hdr.NameValueSeparator := ':';
  end
  else
    Hdr := TStringList(AHeaders);
  Body := TStringStream.Create(ABody);
  Resp := TStringStream.Create('');
  try
    if AContentType <> '' then
      Hdr.Add('Content-Type: ' + AContentType);
    GameHttpRequest('POST', AUrl, Hdr, Body, AConnectTimeoutMs, AIOTimeoutMs,
      Resp, Status);
    if (Status < 200) or (Status >= 300) then
      raise Exception.CreateFmt('POST %s → %d', [AUrl, Status]);
    Result := Resp.DataString;
  finally
    Resp.Free;
    Body.Free;
    if OwnHdr then
      Hdr.Free;
  end;
end;

{$ifdef MSWINDOWS}
initialization
  InitializeCriticalSection(GProxyLock);
finalization
  DeleteCriticalSection(GProxyLock);
{$endif}

end.
