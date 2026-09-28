unit Osm3dCacheHTTPFetcher;

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$codepage UTF8}

interface

uses
  Classes,
  SysUtils,
  fphttpclient,
  opensslsockets,
  Osm3dCache
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
;

type
  TFetchResult = record
    Success:     Boolean;
    Data:        TBytes;
    ContentType: string;
    ETag:        string;
    StatusCode:  Integer;
    FromCache:   Boolean;
    ErrorMsg:    string;

    class function Failure(const AErr: string;
                           AStatusCode: Integer = 0): TFetchResult; static;
  end;

  TNetworkRequestEvent = procedure(Sender: TObject;
    const URL, Method: string; BodySize: Integer) of object;

  TNetworkProgressEvent = procedure(Sender: TObject;
    const URL, Method: string;
    Received, Total: Int64; ElapsedMs: Int64) of object;

  TNetworkSuccessEvent = procedure(Sender: TObject;
    const URL, Method: string; StatusCode: Integer;
    ResponseSize: Int64; ElapsedMs: Int64) of object;

  TCacheHitEvent       = procedure(Sender: TObject;
    const URL: string; SizeBytes: Int64) of object;

  TFetchErrorEvent     = procedure(Sender: TObject;
    const URL, ErrorMsg: string; Attempt: Integer;
    PartialSize: Int64; ElapsedMs: Int64) of object;

  { Returns '' on success, error message on rejection (will delete cache entry). }
  TResponseValidator = function(Sender: TObject;
    const URL: string; const Bytes: TBytes;
    const ContentType: string): string of object;

  THTTPFetcherWithCache = class
  private
    FCache:           TCacheBase;
    FOwnsCache:       Boolean;
    FUserAgent:       string;
    FMaxRetries:      Integer;
    FRetryBaseMs:     Integer;
    FRetryMaxMs:      Integer;
    FTimeoutMs:       Integer;
    FAbortAll:        Boolean;
    { Живые клиенты DoHttp — для teardown-отмены: из другого потока им
      выставляется Terminated + ужатые таймауты, и застрявшие фазы чтения
      заголовков/подключения заканчиваются за ~250 мс вместо 30 с. }
    FClientsCS:       TRTLCriticalSection;
    FInFlight:        TList;
    FProgressMinBytes:    Int64;
    FProgressMinIntervalMs: Int64;

    FOnNetworkRequest:  TNetworkRequestEvent;
    FOnNetworkProgress: TNetworkProgressEvent;
    FOnNetworkSuccess:  TNetworkSuccessEvent;
    FOnCacheHit:        TCacheHitEvent;
    FOnError:           TFetchErrorEvent;
    FOnValidate:        TResponseValidator;

    function MakeKey(const URL, Method: string; const Body: TBytes;
                     const CacheKeyOverride: string): string;
    function HashBytes(const B: TBytes): string;
    function DoHttp(const URL, Method, ContentType: string;
                    const Body: TBytes; ConnectTimeoutLimitMs, AttemptLimit: Integer): TFetchResult;
    function DoAuthenticatedOSM(const URL, Method: string; const Body: TBytes;
      ConnectTimeoutLimitMs: Integer): TFetchResult;
    function CheckOsmAbort: Boolean;
    procedure AuthenticatedOsmProgress(Received: Int64);
    procedure InternalDataReceived(Sender: TObject;
      const ContentLength, CurrentPos: Int64);

    function FetchInternal(const URL, Method, ContentType: string;
                           const Body: TBytes;
                           const CacheKeyOverride: string;
                           ConnectTimeoutLimitMs: Integer = 0;
                           AttemptLimit: Integer = 0): TFetchResult;
  public
    constructor Create(ACache: TCacheBase; AOwnsCache: Boolean = False);
    destructor  Destroy; override;

    function ComputeBackoffMs(Attempt: Integer): Integer;

    { Отмена всех запросов ЭТОГО инстанса фетчера (он разделяемый): взводится
      при teardown карты — идущие попытки прерываются (EAbort в
      OnDataReceived), ретраи и backoff-ожидания пропускаются, новые попытки
      не стартуют. Окно отмены ограничено: ResetAbort снимается сразу после
      джойна воркеров карты. }
    procedure AbortAllRequests;
    procedure ResetAbort;
    property Aborted: Boolean read FAbortAll;

    function GetUrl(const URL: string; ConnectTimeoutLimitMs: Integer = 0;
      AttemptLimit: Integer = 0): TFetchResult;
    procedure InvalidateGetUrl(const URL: string);
    { Только из кэша, без сети; валидатор чистит битые записи. }
    function GetUrlCachedOnly(const URL: string): TFetchResult;
    function GetCachedByKey(const URL, Key: string): TFetchResult;

    function PostUrl(const URL: string; const Body: TBytes;
                     const ContentType: string =
                       'application/x-www-form-urlencoded';
                     const CacheKeyOverride: string = '';
                     ConnectTimeoutLimitMs: Integer = 0;
                     AttemptLimit: Integer = 0): TFetchResult;
    function PostString(const URL, Body: string;
                        const ContentType: string =
                          'text/plain; charset=utf-8';
                        const CacheKeyOverride: string = '';
                        ConnectTimeoutLimitMs: Integer = 0;
                        AttemptLimit: Integer = 0): TFetchResult;

    property Cache:       TCacheBase read FCache;
    property UserAgent:   string  read FUserAgent  write FUserAgent;
    property MaxRetries:  Integer read FMaxRetries write FMaxRetries;
    property RetryBaseMs: Integer read FRetryBaseMs write FRetryBaseMs;
    property RetryMaxMs:  Integer read FRetryMaxMs  write FRetryMaxMs;
    property TimeoutMs:   Integer read FTimeoutMs  write FTimeoutMs;

    property ProgressMinBytes:      Int64 read FProgressMinBytes      write FProgressMinBytes;
    property ProgressMinIntervalMs: Int64 read FProgressMinIntervalMs write FProgressMinIntervalMs;

    property OnNetworkRequest: TNetworkRequestEvent
      read FOnNetworkRequest write FOnNetworkRequest;
    property OnNetworkProgress: TNetworkProgressEvent
      read FOnNetworkProgress write FOnNetworkProgress;
    property OnNetworkSuccess: TNetworkSuccessEvent
      read FOnNetworkSuccess write FOnNetworkSuccess;
    property OnCacheHit: TCacheHitEvent
      read FOnCacheHit write FOnCacheHit;
    property OnError: TFetchErrorEvent
      read FOnError write FOnError;

    property OnValidateResponse: TResponseValidator
      read FOnValidate write FOnValidate;
  end;

{ Процессный замок на МУТАЦИЮ конфигурации фетчеров (TimeoutMs/MaxRetries/
  OnValidateResponse). Клиенты ОБЩЕГО фетчера временно переписывают его
  настройки по схеме save/mutate/use/restore (TOverpassClient в Create/
  Destroy, TOsm3dBlockGenerator.FetchSourceHeightmapForBox на время
  выборки): два таких блока без замка переплетаются, и фетчер залипает на
  чужих значениях. Замок сериализует ТОЛЬКО мутаторов — сами fetch'и его
  не держат и друг друга не ждут. }
procedure EnterFetcherConfig;
procedure LeaveFetcherConfig;

implementation

uses
  {$ifdef REZVIVO_STARTUP_TIMING} CastleLog, {$endif}
  MD5,
  Osm3dOsmAccess,
  Osm3dNetworkAudit,
  DateUtils;

var
  GFetcherConfigCS: TRTLCriticalSection;

procedure EnterFetcherConfig;
begin
  EnterCriticalSection(GFetcherConfigCS);
end;

procedure LeaveFetcherConfig;
begin
  LeaveCriticalSection(GFetcherConfigCS);
end;

{ Per-thread state for the OnDataReceived callback (TFPHTTPClient gives us
  only Sender + counters, so we stash the URL/timing in TLS). }
threadvar
  TLS_CurURL:             string;
  TLS_CurMethod:          string;
  TLS_CurStartTime:       TDateTime;
  TLS_CurLastReportTime:  TDateTime;
  TLS_CurLastReportBytes: Int64;

class function TFetchResult.Failure(const AErr: string;
                                    AStatusCode: Integer): TFetchResult;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1027);{$ENDIF}
  Result.Success     := False;
  Result.Data        := nil;
  Result.ContentType := '';
  Result.ETag        := '';
  Result.StatusCode  := AStatusCode;
  Result.FromCache   := False;
  Result.ErrorMsg    := AErr;
end;

constructor THTTPFetcherWithCache.Create(ACache: TCacheBase; AOwnsCache: Boolean);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1028);{$ENDIF}
  inherited Create;
  FCache       := ACache;
  FOwnsCache   := AOwnsCache;
  FUserAgent   := 'REZVIVO/1.0 (+https://rezvivo.com)';
  FMaxRetries  := 3;
  FRetryBaseMs := 500;
  FRetryMaxMs  := 15000;
  FTimeoutMs   := 30000;
  FAbortAll    := False;
  FProgressMinBytes      := 256 * 1024;
  FProgressMinIntervalMs := 1000;
  InitCriticalSection(FClientsCS);
  FInFlight    := TList.Create;
end;

procedure THTTPFetcherWithCache.AbortAllRequests;
var
  I: Integer;
begin
  FAbortAll := True;
  { Cooperative cancellation only: the request thread owns its socket.
    Even IOTimeout's setter dereferences FSocket and is unsafe from here.
    A blocked OS call finishes on response or its existing timeout. }
  EnterCriticalSection(FClientsCS);
  try
    for I := 0 to FInFlight.Count - 1 do
    begin
      TFPHTTPClient(FInFlight[I]).Terminate;
    end;
  finally
    LeaveCriticalSection(FClientsCS);
  end;
end;

procedure THTTPFetcherWithCache.ResetAbort;
begin
  FAbortAll := False;
end;

destructor THTTPFetcherWithCache.Destroy;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1029);{$ENDIF}
  if FOwnsCache then
    FreeAndNil(FCache);
  FreeAndNil(FInFlight);
  DoneCriticalSection(FClientsCS);
  inherited;
end;

function THTTPFetcherWithCache.HashBytes(const B: TBytes): string;
var
  Sentinel: Byte;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(53);{$ENDIF}
  if Length(B) = 0 then
  begin
    Sentinel := 0;
    Result := LowerCase(MDPrint(MDBuffer(Sentinel, 0, MD_VERSION_5)));
  end
  else
    Result := LowerCase(MDPrint(MDBuffer(B[0], Length(B), MD_VERSION_5)));
end;

function THTTPFetcherWithCache.MakeKey(const URL, Method: string;
  const Body: TBytes; const CacheKeyOverride: string): string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(54);{$ENDIF}
  if CacheKeyOverride <> '' then
    Result := CacheKeyOverride
  else if Method = 'GET' then
    Result := 'GET ' + URL
  else
    Result := Method + ' ' + URL + ' ' + HashBytes(Body);
end;

function THTTPFetcherWithCache.ComputeBackoffMs(Attempt: Integer): Integer;
{ Exponential backoff with full jitter, capped at FRetryMaxMs. }
var
  BaseMs, Jitter: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(55);{$ENDIF}
  if Attempt < 1 then Attempt := 1;

  if Attempt > 20 then
    BaseMs := FRetryMaxMs
  else
  begin
    BaseMs := FRetryBaseMs * (1 shl (Attempt - 1));
    if (BaseMs <= 0) or (BaseMs > FRetryMaxMs) then
      BaseMs := FRetryMaxMs;
  end;

  if FRetryBaseMs > 0 then
    Jitter := Random(FRetryBaseMs div 2 + 1)
  else
    Jitter := 0;
  Result := BaseMs + Jitter;
end;

{$PUSH}{$WARN 5024 OFF}  // unused parameter Sender — required by callback signature
procedure THTTPFetcherWithCache.InternalDataReceived(Sender: TObject;
  const ContentLength, CurrentPos: Int64);
{ Throttle: emit progress only after FProgressMinBytes OR FProgressMinIntervalMs. }
var
  NowTime: TDateTime;
  BytesSinceLast: Int64;
  MsSinceLast: Int64;
  ElapsedTotalMs: Int64;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(56);{$ENDIF}
  { Отмена по teardown: рвём идущую передачу ближайшим чанком — исключение
    всплывёт в DoHttp и попытка завершится неудачей, ретраи пропустятся. }
  if FAbortAll then
    raise EAbort.Create('fetch aborted (teardown)');
  if not Assigned(FOnNetworkProgress) then Exit;
  if TLS_CurURL = '' then Exit;

  NowTime := Now;
  BytesSinceLast := CurrentPos - TLS_CurLastReportBytes;
  MsSinceLast := MilliSecondsBetween(NowTime, TLS_CurLastReportTime);

  if (BytesSinceLast < FProgressMinBytes) and
     (MsSinceLast < FProgressMinIntervalMs) then
    Exit;

  TLS_CurLastReportBytes := CurrentPos;
  TLS_CurLastReportTime  := NowTime;
  ElapsedTotalMs := MilliSecondsBetween(NowTime, TLS_CurStartTime);

  try
    FOnNetworkProgress(Self, TLS_CurURL, TLS_CurMethod,
      CurrentPos, ContentLength, ElapsedTotalMs);
  except
    // callback failures must not abort the download
  end;
end;
{$POP}

function THTTPFetcherWithCache.CheckOsmAbort: Boolean;
begin
  Result := FAbortAll;
end;

procedure THTTPFetcherWithCache.AuthenticatedOsmProgress(Received: Int64);
begin
  if FAbortAll then raise EAbort.Create('aborted');
  InternalDataReceived(nil, 0, Received);
end;

function THTTPFetcherWithCache.DoAuthenticatedOSM(const URL, Method: string;
  const Body: TBytes; ConnectTimeoutLimitMs: Integer): TFetchResult;
var
  Token, Query: string;
  Response: TBytesStream;
  ConnectMs, Code: Integer;
  Started: TDateTime;
  NeedsAccount: Boolean;
begin
  Result := TFetchResult.Failure('OSM requires an active REZVIVO account', 401);
  if FAbortAll then Exit(TFetchResult.Failure('aborted'));
  NeedsAccount:=OsmRequiresAccess(URL) or HeightRequiresAccess(URL) or MapRequiresAccess(URL);
  if NeedsAccount and not Assigned(OsmAccessTokenProvider) then Exit;
  Response := TBytesStream.Create;
  Started := Now;
  try
    try
      Token := '';
      if NeedsAccount then begin
        Token:=OsmAccessTokenProvider();
        if Token='' then Exit;
      end;
      SetLength(Query, Length(Body));
      if Length(Body) > 0 then Move(Body[0], Query[1], Length(Body));
      ConnectMs := ConnectTimeoutLimitMs;
      if ConnectMs <= 0 then ConnectMs := 3000;
      TLS_CurURL := URL; TLS_CurMethod := Method; TLS_CurStartTime := Started;
      TLS_CurLastReportTime := Started; TLS_CurLastReportBytes := 0;
      if Assigned(FOnNetworkRequest) then FOnNetworkRequest(Self, URL, Method, Length(Body));
      if NeedsAccount then
        Code := OsmAuthenticatedRequest(URL, Method, Query, Token, ConnectMs, FTimeoutMs,
          Response, @CheckOsmAbort, @AuthenticatedOsmProgress)
      else
        Code := OsmPublicPost(URL, Query, ConnectMs, FTimeoutMs,
          Response, @CheckOsmAbort, @AuthenticatedOsmProgress);
      if FAbortAll then Exit(TFetchResult.Failure('aborted'));
      if Code <> 200 then Exit(TFetchResult.Failure('OSM access/request rejected: HTTP ' + IntToStr(Code), Code));
      Result.Success := True; Result.Data := Copy(Response.Bytes, 0, Response.Size);
      Result.StatusCode := 200; Result.ContentType := 'application/json';
      if Method='GET' then Result.ContentType:='image/png';
      Result.ErrorMsg := ''; Result.FromCache := False;
      if Assigned(FOnNetworkSuccess) then FOnNetworkSuccess(Self, URL, Method,
        200, Response.Size, MilliSecondsBetween(Now, Started));
    except
      on E: EAbort do Result := TFetchResult.Failure('aborted');
      on E: Exception do Result := TFetchResult.Failure('OSM authenticated request failed');
    end;
  finally
    Token := '';
    Response.Free;
  end;
end;

function THTTPFetcherWithCache.DoHttp(const URL, Method, ContentType: string;
                                      const Body: TBytes;
                                      ConnectTimeoutLimitMs, AttemptLimit: Integer): TFetchResult;
var
  Client:      TFPHTTPClient;
  Response:    TBytesStream;
  RequestBody: TBytesStream;
  Attempt:     Integer;
  Attempts:    Integer;
  ErrMsg:      string;
  StatusCode:  Integer;
  StartTime:   TDateTime;
  ElapsedMs:   Int64;
  PartialSize: Int64;
  BackoffMs:   Integer;
  {$ifdef REZVIVO_STARTUP_TIMING}
  TimingStart: QWord;
  {$endif}
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(57);{$ENDIF}
  {$ifdef REZVIVO_STARTUP_TIMING}
  TimingStart := GetTickCount64;
  WritelnLog('StartupTiming', 'osm-http begin tick=%d thread=%d main=%s method=%s',
    [TimingStart, QWord(GetCurrentThreadId), BoolToStr(GetCurrentThreadId = MainThreadID, True), Method]);
  {$endif}
  Result := TFetchResult.Failure('not attempted');
  if ((Method = 'POST') and (OsmRequiresAccess(URL) or OsmPublicNativeEndpoint(URL))) or
     ((Method = 'GET') and (HeightRequiresAccess(URL) or MapRequiresAccess(URL))) then
    Exit(DoAuthenticatedOSM(URL, Method, Body, ConnectTimeoutLimitMs));

  Client := TFPHTTPClient.Create(nil);
  EnterCriticalSection(FClientsCS);
  try
    FInFlight.Add(Client);
  finally
    LeaveCriticalSection(FClientsCS);
  end;
  try
    Client.AddHeader('User-Agent', FUserAgent);
    Client.AllowRedirect  := True;
    Client.ConnectTimeout := FTimeoutMs;
    { A per-request cap lets endpoint failover skip a dead connection quickly,
      without shortening query execution/read time or mutating a shared fetcher. }
    if (ConnectTimeoutLimitMs > 0) and
       ((FTimeoutMs <= 0) or (ConnectTimeoutLimitMs < FTimeoutMs)) then
      Client.ConnectTimeout := ConnectTimeoutLimitMs;
    Client.IOTimeout      := FTimeoutMs;
    Client.OnDataReceived := @InternalDataReceived;
    if (Method = 'POST') and (ContentType <> '') then
      Client.AddHeader('Content-Type', ContentType);

    Attempts := FMaxRetries;
    if (AttemptLimit > 0) and (Attempts > AttemptLimit) then Attempts := AttemptLimit;
    for Attempt := 1 to Attempts do
    begin
      { Отмена (teardown карты): новые попытки не стартуют. }
      if FAbortAll then
      begin
        Result := TFetchResult.Failure('aborted');
        Exit;
      end;
      Response := TBytesStream.Create;
      RequestBody := nil;
      try
        if Assigned(FOnNetworkRequest) then
          FOnNetworkRequest(Self, URL, Method, Length(Body));

        StartTime := Now;

        TLS_CurURL              := URL;
        TLS_CurMethod           := Method;
        TLS_CurStartTime        := StartTime;
        TLS_CurLastReportTime   := StartTime;
        TLS_CurLastReportBytes  := 0;

        try
          if Method = 'GET' then
            Client.Get(URL, Response)
          else if Method = 'POST' then
          begin
            RequestBody := TBytesStream.Create(Body);
            Client.RequestBody := RequestBody;
            try
              Client.Post(URL, Response);
            finally
              Client.RequestBody := nil;
            end;
          end
          else
          begin
            Result := TFetchResult.Failure('Unsupported method: ' + Method);
            Exit;
          end;

          { Terminate can make FPC return normally with an incomplete body. }
          if Client.Terminated or FAbortAll then
          begin
            Result := TFetchResult.Failure('aborted');
            Exit;
          end;
          { FPC Post accepts any status unless explicitly checked. A valid
            JSON/PNG error body must never become a successful cache entry. }
          if(Client.ResponseStatusCode<200)or(Client.ResponseStatusCode>=300)then
            raise Exception.CreateFmt('HTTP %d',[Client.ResponseStatusCode]);
          ElapsedMs := MilliSecondsBetween(Now, StartTime);

          Result.Success := True;
          Result.Data := nil;
          if Response.Size > 0 then
          begin
            SetLength(Result.Data, Response.Size);
            Move(Response.Bytes[0], Result.Data[0], Response.Size);
          end;
          Result.StatusCode  := Client.ResponseStatusCode;
          Result.ContentType := Client.ResponseHeaders.Values['Content-Type'];
          Result.ETag        := Client.ResponseHeaders.Values['ETag'];
          Result.FromCache   := False;
          Result.ErrorMsg    := '';

          if Assigned(FOnNetworkSuccess) then
            FOnNetworkSuccess(Self, URL, Method,
              Result.StatusCode, Length(Result.Data), ElapsedMs);

          Exit;
        except
          on E: Exception do
          begin
            if Client.Terminated or FAbortAll then
            begin
              Result := TFetchResult.Failure('aborted');
              Exit;
            end;
            ElapsedMs := MilliSecondsBetween(Now, StartTime);
            PartialSize := 0;
            try
              if Response <> nil then
                PartialSize := Response.Size;
            except
              // defensive: stream may be in an invalid state after failure
            end;

            ErrMsg := E.Message;
            StatusCode := Client.ResponseStatusCode;

            if Assigned(FOnError) then
              FOnError(Self, URL, ErrMsg, Attempt, PartialSize, ElapsedMs);

            Result := TFetchResult.Failure(ErrMsg, StatusCode);

            try
              if (Response <> nil) and (Response.Size > 0) then
              begin
                SetLength(Result.Data, Response.Size);
                Move(Response.Bytes[0], Result.Data[0], Response.Size);
              end;
            except
              // partial body is best-effort
            end;

            { Do not retry on 4xx — client errors won't fix themselves. }
            if (StatusCode >= 400) and (StatusCode < 500) then
              Exit;
            if Attempt < Attempts then
            begin
              BackoffMs := ComputeBackoffMs(Attempt);
              { Backoff прерываемый: teardown карты не ждёт до 15 с сна. }
              while (BackoffMs > 0) and (not FAbortAll) do
              begin
                Sleep(50);
                Dec(BackoffMs, 50);
              end;
            end;
          end;
        end;
      finally
        TLS_CurURL := '';
        TLS_CurMethod := '';
        RequestBody.Free;
        Response.Free;
      end;
    end;
  finally
    EnterCriticalSection(FClientsCS);
    try
      FInFlight.Remove(Client);
    finally
      LeaveCriticalSection(FClientsCS);
    end;
    Client.Free;
    {$ifdef REZVIVO_STARTUP_TIMING}
    WritelnLog('StartupTiming', 'osm-http end tick=%d thread=%d ms=%d success=%s',
      [TimingStart, QWord(GetCurrentThreadId), GetTickCount64 - TimingStart, BoolToStr(Result.Success, True)]);
    {$endif}
  end;
end;

function THTTPFetcherWithCache.FetchInternal(const URL, Method, ContentType: string;
                                             const Body: TBytes;
                                             const CacheKeyOverride: string;
                                            ConnectTimeoutLimitMs: Integer;
                                            AttemptLimit: Integer): TFetchResult;
var
  Key: string;
  Data: TBytes;
  Meta: TCacheMetadata;
  ValidateMsg: string;
  NetworkStarted: QWord;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(58);{$ENDIF}
  Key := MakeKey(URL, Method, Body, CacheKeyOverride);

  { Cache lookup first. Валидная запись возвращается; битая — удаляется,
    и запрос ПРОВАЛИВАЕТСЯ в сетевой путь ниже (самоизлечение в этом же
    вызове). Раньше здесь возвращался отказ: отравленный ключ (например,
    HTML-заглушка CDN с кодом 200 вместо PNG) лечился только со СЛЕДУЮЩЕГО
    обращения, и потребитель до тех пор сидел на своём fallback'е. }
  if (FCache <> nil) and FCache.Get(Key, Data, Meta) then
  begin
    ValidateMsg := '';
    if Assigned(FOnValidate) then
      ValidateMsg := FOnValidate(Self, URL, Data, Meta.ContentType);
    if ValidateMsg = '' then
    begin
      Result.Success     := True;
      Result.Data        := Data;
      Result.ContentType := Meta.ContentType;
      Result.ETag        := Meta.ETag;
      Result.StatusCode  := 200;
      Result.FromCache   := True;
      Result.ErrorMsg    := '';
      if Assigned(FOnCacheHit) then
        FOnCacheHit(Self, URL, Length(Data));
      Exit;
    end;
    FCache.Delete(Key);
    if Assigned(FOnError) then
      FOnError(Self, URL, ValidateMsg, 0, Length(Data), 0);
  end;

  NetworkStarted:=GetTickCount64;
  Result := DoHttp(URL, Method, ContentType, Body, ConnectTimeoutLimitMs, AttemptLimit);
  AuditMapRequest(URL,Method,Result.StatusCode,Length(Result.Data),GetTickCount64-NetworkStarted);
  if not Result.Success then Exit;

  if Assigned(FOnValidate) then
  begin
    ValidateMsg := FOnValidate(Self, URL, Result.Data, Result.ContentType);
    if ValidateMsg <> '' then
    begin
      Result.Success  := False;
      Result.ErrorMsg := ValidateMsg;
      if Assigned(FOnError) then
        FOnError(Self, URL, ValidateMsg, 1, Length(Result.Data), 0);
      Exit;
    end;
  end;

  if FCache <> nil then
  begin
    Meta := TCacheMetadata.Make(Result.ContentType, Result.ETag);
    Meta.SizeBytes := Length(Result.Data);
    FCache.Put(Key, Result.Data, Meta);
  end;
end;

function THTTPFetcherWithCache.GetUrl(const URL: string;
  ConnectTimeoutLimitMs, AttemptLimit: Integer): TFetchResult;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(59);{$ENDIF}
  Result := FetchInternal(URL, 'GET', '', nil, '', ConnectTimeoutLimitMs, AttemptLimit);
end;

procedure THTTPFetcherWithCache.InvalidateGetUrl(const URL: string);
begin
  if FCache <> nil then FCache.Delete(MakeKey(URL,'GET',nil,''));
end;

function THTTPFetcherWithCache.GetUrlCachedOnly(const URL: string): TFetchResult;
begin
  Result := GetCachedByKey(URL, MakeKey(URL, 'GET', nil, ''));
end;

function THTTPFetcherWithCache.GetCachedByKey(const URL, Key: string): TFetchResult;
var
  Data: TBytes;
  Meta: TCacheMetadata;
  ValidateMsg: string;
begin
  { Только кэш, БЕЗ сети: для мгновенных ответов «что есть сейчас»
    (пол/меш заглушки тайла, превью). Валидатор применяется как в
    FetchInternal: битая запись удаляется (перекачает первый же сетевой
    запрос), а вызывающему возвращается промах. }
  Result := TFetchResult.Failure('not in cache');
  if FCache = nil then Exit;
  if not FCache.Get(Key, Data, Meta) then Exit;
  if Assigned(FOnValidate) then
  begin
    ValidateMsg := FOnValidate(Self, URL, Data, Meta.ContentType);
    if ValidateMsg <> '' then
    begin
      FCache.Delete(Key);
      Result.ErrorMsg := ValidateMsg;
      if Assigned(FOnError) then
        FOnError(Self, URL, ValidateMsg, 0, Length(Data), 0);
      Exit;
    end;
  end;
  Result.Success     := True;
  Result.Data        := Data;
  Result.ContentType := Meta.ContentType;
  Result.ETag        := Meta.ETag;
  Result.StatusCode  := 200;
  Result.FromCache   := True;
  Result.ErrorMsg    := '';
end;

function THTTPFetcherWithCache.PostUrl(const URL: string; const Body: TBytes;
                                       const ContentType: string;
                                       const CacheKeyOverride: string;
                                       ConnectTimeoutLimitMs: Integer;
                                       AttemptLimit: Integer): TFetchResult;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(60);{$ENDIF}
  Result := FetchInternal(URL, 'POST', ContentType, Body, CacheKeyOverride, ConnectTimeoutLimitMs, AttemptLimit);
end;

function THTTPFetcherWithCache.PostString(const URL, Body, ContentType: string;
  const CacheKeyOverride: string; ConnectTimeoutLimitMs: Integer; AttemptLimit: Integer): TFetchResult;
var
  BodyBytes: TBytes;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(61);{$ENDIF}
  if Length(Body) = 0 then
    BodyBytes := nil
  else
  begin
    SetLength(BodyBytes, Length(Body));
    Move(Body[1], BodyBytes[0], Length(Body));
  end;
  Result := PostUrl(URL, BodyBytes, ContentType, CacheKeyOverride, ConnectTimeoutLimitMs, AttemptLimit);
end;

initialization
  InitCriticalSection(GFetcherConfigCS);
  Randomize;

{ Намеренно БЕЗ finalization/DoneCriticalSection: при закрытии приложения
  поздние Destroy (остановка view из finalization castle-юнитов) ещё вызывают
  EnterFetcherConfig, а порядок finalization между юнитами нам неподконтролен.
  EnterCriticalSection по уже Done-ной секции падает в ntdll. Замок живёт
  до конца процесса — ОС всё равно всё заберёт. }
end.
