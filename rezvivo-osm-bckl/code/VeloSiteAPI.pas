{ VeloSiteAPI — клиент REST-API сайта REZVIVO (https://rezvivo.com,
  запасной хост https://rezvivo.ru).

  Реализует Bearer-авторизацию, авто-refresh access-токена при 401,
  персистенцию токенов в JSON-файле в castle-config:/ (на UNIX
  права 0600). Стратегия retry соответствует таблице из
  game-integration.md: 401 — один refresh+повтор, прочие 4xx —
  без повтора (raise EVeloSiteError), 5xx — без повтора (вызывающий
  код решает, повторять ли через backoff).

  В этой фазе покрыты:
    • аутентификация: login email/password, device flow, refresh, logout;
    • профиль:        GET /me, PATCH /me/profile;
    • подписка:       GET /me/entitlements.

  Загрузка заездов (POST /api/v1/rides) и WebSocket-телеметрия —
  отдельные фазы; они добавятся поверх готового HTTP-фундамента из
  этого юнита.

  Использование (синхронное, вызывать НЕ из главного потока, иначе
  на медленной сети UI зависнет на десятки секунд):

    if not VeloSite.IsAuthorized then
      VeloSite.Login('[email protected]', '...');
    Profile := VeloSite.GetMe;
    WritelnLog('foo', 'Hello, ' + Profile.Nickname);

  Ошибки: все методы могут поднимать EVeloSiteError с HTTP-кодом и
  кодом ошибки из ответа сервера (.ErrorCode). Сетевые сбои
  поднимаются как стандартные исключения fphttpclient (EHttpClient
  и потомки).

  Threading: один экземпляр на приложение (singleton VeloSite,
  создаётся в initialization этого юнита). Чтение/запись токенов
  защищены TCriticalSection, так что фоновый поток загрузки заездов
  из последующих фаз сможет вызывать API параллельно с UI без гонок.

  Безопасность токенов: файл auth.json лежит в %APPDATA%\<app>\
  (Windows) / ~/.config/<app>/ (Linux) / ~/Library/Application Support/<app>/
  (macOS). На UNIX выставляются права 0600 (чтение/запись только владельцу).
  В Фазе 1 шифрования нет — токены лежат в открытом виде. Это можно
  улучшить позже (DPAPI на Windows, libsecret на Linux), не меняя
  публичного API. }
unit VeloSiteAPI;

{$mode objfpc}{$H+}
{$codepage UTF8}

interface

uses UiTranslations,
  Classes, SysUtils, SyncObjs,
  fpjson, GameHttpClient;

type
  EVeloSiteError = class(Exception)
  private
    FHttpStatus: Integer;
    FErrorCode:  String;
    FFields:     TStringList;
  public
    property HttpStatus: Integer     read FHttpStatus;
    property ErrorCode:  String      read FErrorCode;
    property Fields:     TStringList read FFields;

    { AFields принимается с передачей владения — деструктор освободит. }
    constructor Create(AHttpStatus: Integer;
                       const AErrorCode, AMessage: String;
                       AFields: TStringList);
    destructor Destroy; override;
  end;

  TVeloSiteTokens = record
    AccessToken:  String;
    RefreshToken: String;
    ExpiresAt:    Int64;     { Unix-секунды UTC, когда access протухает }
  end;

  TVeloSiteProfile = record
    Id:             Int64;
    Email:          String;
    Nickname:       String;
    WeightKg:       Single;
    FtpW:           Integer;
    TrainingZonesJSON: String;
    IsAdmin:        Boolean;
    EmailVerified:  Boolean;
    CreatedAt:      String;     { ISO 8601 UTC, как пришло с сервера }
    Locale:         String;     { BCP-47, '' если не задан в профиле }
  end;

  { Реальный ответ /api/v1/me/entitlements — сильно проще чем
    обещано в game-integration.md (там обещают plan/features.*,
    в коде сервера — только has_access/source/expires_at). }
  TVeloSiteEntitlements = record
    HasAccess:  Boolean;     { основной флаг: есть ли подписка }
    Source:     String;      { источник (если есть): 'subscription' и т.п. }
    ExpiresAt:  String;      { ISO 8601 UTC, может быть пустой }
  end;

  TVeloSiteDeviceCode = record
    DeviceCode:      String;
    UserCode:        String;     { показывается игроку для ввода в браузере }
    VerificationUrl: String;
    ExpiresIn:       Integer;     { секунды, сколько живёт код }
    Interval:        Integer;     { секунды между poll-вызовами }
  end;

  { Метаданные для POST /api/v1/rides. Все *_Id могут быть 0 — поле
    сериализуется как null. StartedAtUnix=0 → пусть сервер извлекает
    из FIT. Source/Type/Kind не должны быть пустыми. }
  TVeloSiteRideUpload = record
    Source:        String;     { 'game' / 'strava' / 'upload' }
    UploadType:    String;     { 'free' / 'workout' / 'event' }
    Kind:          String;     { 'fit' / 'tcx' / 'gpx' }
    StartedAtUnix: Int64;      { 0 = не присылать }
    BikeId:        Int64;
    RouteId:       Int64;
    EventId:       Int64;
  end;

  TVeloSiteRideUploadResult = record
    RideId:     Int64;
    Idempotent: Boolean;       { true = заезд с таким Idempotency-Key уже был }
    Status:     String;        { 'processing' / 'ready' / 'rejected' }
  end;

  TVeloSiteRideStatus = record
    Id:           Int64;
    Status:       String;
    StartedAt:    String;
    DurationS:    Int64;
    DistanceM:    Int64;
    AvgPowerW:    Int64;
    NpW:          Int64;
    Tss:          Single;
    ElevGainM:    Int64;
    AvgHr:        Int64;
    AvgCadence:   Int64;
    Kj:           Int64;
    RejectReason: String;       { непустая строка только если Status='rejected' }
  end;

  TVeloSiteAPI = class
  private
    FBaseUrl:     String;
    FHostChecked: Boolean;
    FAuthFile:    String;
    FTokens:      TVeloSiteTokens;
    FLock:        TCriticalSection;
    FRefreshLock: TCriticalSection;
    FAsyncLock: TCriticalSection;
    FAsyncWorker: TThread;
    FAsyncCancel: TGameHttpCancellation;
    FShuttingDown: Boolean;
    FAuthGeneration: QWord;

    FHasProfileCache: Boolean;
    FProfileCache:    TVeloSiteProfile;
    FEntitlementsCache: TVeloSiteEntitlements;

    function  GetIsAuthorized: Boolean;
    function GetBaseUrl: String;
    procedure SetBaseUrl(const Value: String);

    function  MakeUrl(const APath: String): String;
    function  NowUnix: Int64;

    procedure LoadTokens;
    procedure SaveTokens;
    procedure ClearTokensFile;

    function  ExtractError(AResponseStatus: Integer;
                           AResponseBody: TStream): EVeloSiteError;

    { Низкоуровневый запрос. ARequestBody может быть nil (для GET).
      AContentType '' — без заголовка Content-Type (для GET).
      AAuth=True — добавить Authorization: Bearer.
      ARetryAuth=True — при 401 один раз вызвать TryRefreshAccess и
        повторить запрос (с ARetryAuth=False, чтобы не зациклиться).
      Возвращает распарсенный JSON ответа (вызывающий обязан Free).
      На non-2xx (включая 4xx после refresh) — raise EVeloSiteError. }
    function  DoRequest(const AMethod, APath, AContentType: String;
                        ARequestBody: TStream;
                        AAuth, ARetryAuth: Boolean): TJSONData;
    function  DoRequestOnce(const AMethod, APath, AContentType: String;
                        ARequestBody: TStream;
                        AAuth, ARetryAuth, AAllowFailover: Boolean): TJSONData;
    function  PingHost(const ABaseUrl: String): Boolean;
    procedure SwitchHost;
    function  RewritePublicUrl(const AUrl: String): String;

    procedure ApplyTokenResponse(AJson: TJSONObject; ANewSession: Boolean = True);
    procedure ClearProfileCacheLocked;
    function  TryRefreshAccess(const OnlyIfExpiring: Boolean = False): Boolean;

    { Multipart-загрузка для POST /api/v1/rides. Собирает тело из
      JSON-метаданных + бинарного файла, добавляет необходимые
      заголовки. Использует тот же 401-refresh-retry, что и DoRequest. }
    function  DoMultipartRideUpload(const AIdempotencyKey, AFitFileName,
      AMetaJson: String): TJSONData;

    function  ParseRideStatus(AObj: TJSONObject): TVeloSiteRideStatus;
    procedure LibraryTransfer(AUserId: Int64; const AMethod, APath,
      AContentType: String; ABody, AResponse: TStream; ATimeoutMS:Integer=20000);
  public
    property BaseUrl:      String  read GetBaseUrl write SetBaseUrl;
    property IsAuthorized: Boolean read GetIsAuthorized;

    { GetAccessToken — для немногих legacy-клиентов (relay/bot endpoints,
      WebSocket-публикатор), которые ходят в API но не через TVeloSiteAPI.DoRequest.
      Возвращает текущий access-токен или '' если не залогинен. }
    function GetAccessToken: String;
    function GetAccessTokenForUser(UserId:Int64):String;
    { Worker-only, refreshes an expiring token under the existing refresh lock. }
    function GetOsmAccessToken: String;

    constructor Create;
    destructor  Destroy; override;

    { Проверяет https://rezvivo.com/healthz; если не отвечает —
      переключается на https://rezvivo.ru. Идемпотентно. }
    procedure EnsureHost;
    { База relay: CurrentBase + '/relay'. Перед этим вызывает EnsureHost. }
    function  RelayUrl: String;

    { ── Аутентификация ───────────────────────────────────────────── }

    procedure Login(const AEmail, APassword: String);

    function  DeviceStart: TVeloSiteDeviceCode;

    { Опросить статус device flow.
      True  — игрок подтвердил, токены сохранены, можно идти в меню;
      False — ещё ждём (status=pending), повторить через Interval сек.
      EVeloSiteError на 410 (код истёк) или 400 (отозван). }
    function  DevicePoll(const ADeviceCode: String): Boolean;

    { Логаут на сервере (инвалидирует refresh) + локальная очистка.
      Локальная очистка происходит даже если сервер недоступен. }
    procedure Logout;

    { Локальная очистка без обращения к серверу. Используется когда
      refresh-токен уже невалиден или нужно «забыть» юзера на этом
      устройстве без сетевого вызова. }
    procedure DropTokens;

    { ── Профиль ──────────────────────────────────────────────────── }

    function  GetMe: TVeloSiteProfile;

    { Все параметры опциональны:
        ANickname  = ''  → не менять;
        AWeightKg  < 0   → не менять;
        AFtpW      < 0   → не менять.
      Если все три «не менять» — никакого запроса не делается. }
    procedure PatchProfile(const ANickname: String;
                           AWeightKg: Single; AFtpW: Integer;
                           const ATrainingZonesJSON: String = '');
    procedure ImportTrainingZones;

    function  GetEntitlements: TVeloSiteEntitlements;

    { ── Кеш профиля и подписки ────────────────────────────────────
      После Login или ручного RefreshProfile эти данные хранятся в
      памяти singleton'а. Потребители (UI, физика, workout-редактор)
      могут читать их без сетевого вызова. CachedProfile возвращает
      пустой record когда HasCachedProfile=False. }

    function  HasCachedProfile: Boolean;
    function  CachedProfile: TVeloSiteProfile;
    function  CachedEntitlements: TVeloSiteEntitlements;

    { Дёрнуть GetMe + GetEntitlements и сохранить в кеш. Вызывается из
      UI после успешного логина и при возврате в главное меню. Может
      бросить EVeloSiteError или сетевое исключение. }
    procedure RefreshProfile;

    { Не-блокирующий вариант: стартует фоновый поток с RefreshProfile,
      возвращается мгновенно. Ошибки просто логируются, тихо
      игнорируются для UI. Вызывается из gameinitialize при старте,
      чтобы профиль (и IsAdmin) подхватились без ожидания первого
      входа на ViewProfile. Если IsAuthorized=False — no-op. }
    procedure RefreshProfileAsync;
    { Starts the host/profile check after the menu exists, also for a local
      profile. Coalesces with RefreshProfileAsync; no HTTP on the caller. }
    procedure InitializeAsync;
    procedure ShutdownAsync;

    { ── Загрузка заездов (Phase 4) ────────────────────────────────

      AIdempotencyKey должен быть уникальным UUID, привязанным к
      конкретной сессии (для одного и того же CSV/FIT — один и тот же
      ключ; так сервер не создаст дубликат при повторной загрузке).
      AFitFileName — путь на диске к готовому .fit (multipart заполнит
      сам). }
    function UploadRide(const AIdempotencyKey, AFitFileName: String;
      const AMeta: TVeloSiteRideUpload): TVeloSiteRideUploadResult;

    function GetRideStatus(ARideId: Int64): TVeloSiteRideStatus;

    { Route requests carry the owner captured when the UI/queue action began.
      Call from a worker thread. Account changes cancel the request/retry. }
    function LibraryRequest(AUserId: Int64; const AMethod, APath,
      ABody: String; ATimeoutMS:Integer=20000): TJSONData;
    function UploadRoute(AUserId: Int64; const AFileName: String): TJSONData;
    procedure DownloadRoute(AUserId, ARouteId: Int64; const ADestination: String);
  end;

const
  VELOSITE_PRIMARY_BASE_URL  = 'https://rezvivo.com';
  VELOSITE_FALLBACK_BASE_URL = 'https://rezvivo.ru';
  VELOSITE_DEFAULT_BASE_URL  = VELOSITE_PRIMARY_BASE_URL;

var
  VeloSite: TVeloSiteAPI;

implementation

uses
  jsonparser,
  CastleFilesUtils, CastleURIUtils, CastleLog,
  {$ifdef FPC} OpenSSLSockets, {$endif}
  {$ifdef UNIX} BaseUnix, {$endif}
  DateUtils, DebugLog, Math;

type
  TRouteResponseStream = class(TMemoryStream)
    function Write(const Buffer; Count: Longint): Longint; override;
  end;

threadvar
  ProfileHttpCancellation: TGameHttpCancellation;

{$ifdef MSWINDOWS}
function AuthMoveFile(ExistingName, NewName: PWideChar; Flags: LongWord): LongBool;
  stdcall; external 'kernel32' name 'MoveFileExW';
{$endif}

function TRouteResponseStream.Write(const Buffer; Count: Longint): Longint;
begin
  if (Count < 0) or (Position + Count > 64*1024*1024) then
    raise Exception.Create(UiText('The route library response is too large'));
  Result := inherited Write(Buffer, Count);
end;

function RouteUrlEncode(const S: String): String;
var I: Integer;
begin
  Result := '';
  for I := 1 to Length(S) do
    if S[I] in ['A'..'Z','a'..'z','0'..'9','-','_','.','~'] then Result := Result + S[I]
    else Result := Result + '%' + IntToHex(Ord(S[I]),2);
end;

procedure TVeloSiteAPI.LibraryTransfer(AUserId: Int64; const AMethod,
  APath, AContentType: String; ABody, AResponse: TStream; ATimeoutMS:Integer);
var H: TStringList; Token: String; Attempt, Status: Integer;
begin
  EnsureHost;
  H := TStringList.Create;
  try
    for Attempt := 0 to 1 do
    begin
      FLock.Enter;
      try
        if (AUserId <= 0) or (not FHasProfileCache) or
          (FProfileCache.Id <> AUserId) or (FTokens.AccessToken = '') then
          raise Exception.Create(UiText('The profile has changed. Reopen the route library.'));
        Token := FTokens.AccessToken;
      finally FLock.Leave; end;
      H.Clear;
      H.Add('Authorization: Bearer ' + Token);
      H.Add('User-Agent: REZVIVO/1.0 (+https://rezvivo.com)');
      H.Add('Accept-Language: ' + UiLanguage);
      if AContentType <> '' then H.Add('Content-Type: ' + AContentType);
      if ABody <> nil then ABody.Position := 0;
      AResponse.Size := 0;
      GameHttpRequest(AMethod, MakeUrl('/api/v1' + APath), H, ABody,
        Min(8000,ATimeoutMS), ATimeoutMS, AResponse, Status);
      if (Status >= 200) and (Status < 300) then
      begin AResponse.Position := 0; Exit; end;
      if (Status = 401) and (Attempt = 0) and
        (CachedProfile.Id = AUserId) and TryRefreshAccess then Continue;
      raise ExtractError(Status, AResponse);
    end;
  finally H.Free; end;
end;

function TVeloSiteAPI.LibraryRequest(AUserId: Int64; const AMethod,
  APath, ABody: String; ATimeoutMS:Integer): TJSONData;
var Body: TStringStream; Response: TRouteResponseStream;
begin
  Body := TStringStream.Create(ABody); Response := TRouteResponseStream.Create;
  try
    LibraryTransfer(AUserId, AMethod, APath, 'application/json', Body, Response,ATimeoutMS);
    if Response.Size > 0 then Result := GetJSON(Response) else Result := TJSONObject.Create;
  finally Response.Free; Body.Free; end;
end;

function TVeloSiteAPI.UploadRoute(AUserId: Int64; const AFileName: String): TJSONData;
var Body: TFileStream; Response: TRouteResponseStream;
begin
  Body := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  Response := TRouteResponseStream.Create;
  try
    if Body.Size > 32*1024*1024 then raise Exception.Create(UiText('The file exceeds 32 MiB'));
    LibraryTransfer(AUserId, 'POST', '/routes?name='+RouteUrlEncode(ExtractFileName(AFileName)),
      'application/octet-stream', Body, Response);
    Result := GetJSON(Response);
  finally Response.Free; Body.Free; end;
end;

procedure TVeloSiteAPI.DownloadRoute(AUserId, ARouteId: Int64; const ADestination: String);
var Response: TRouteResponseStream; F: TFileStream;
begin
  Response := TRouteResponseStream.Create;
  try
    LibraryTransfer(AUserId, 'GET', '/routes/'+IntToStr(ARouteId)+'/file', '', nil, Response);
    if CachedProfile.Id <> AUserId then raise Exception.Create(UiText('The profile has changed'));
    ForceDirectories(ExtractFileDir(ADestination));
    F := TFileStream.Create(ADestination+'.part', fmCreate);
    try F.CopyFrom(Response,0); finally F.Free; end;
    if not RenameFile(ADestination+'.part', ADestination) then
      raise Exception.Create(UiText('Could not save the route'));
  finally Response.Free; end;
end;

const
  AUTH_FILE_NAME = 'auth.json';

{ ── Локальные JSON-хелперы ───────────────────────────────────────── }

function JsonGetStr(O: TJSONObject; const AName: String;
  const ADefault: String): String;
var
  D: TJSONData;
begin
  if O = nil then
  begin
    Result := ADefault;
    Exit;
  end;
  D := O.Find(AName);
  if (D = nil) or (D.JSONType = jtNull) then
    Result := ADefault
  else
    Result := D.AsString;
end;

function JsonGetInt64(O: TJSONObject; const AName: String;
  ADefault: Int64): Int64;
var
  D: TJSONData;
begin
  if O = nil then
  begin
    Result := ADefault;
    Exit;
  end;
  D := O.Find(AName);
  if (D = nil) or (D.JSONType = jtNull) then
    Result := ADefault
  else
    Result := D.AsInt64;
end;

function JsonGetSingle(O: TJSONObject; const AName: String;
  ADefault: Single): Single;
var
  D: TJSONData;
begin
  if O = nil then
  begin
    Result := ADefault;
    Exit;
  end;
  D := O.Find(AName);
  if (D = nil) or (D.JSONType = jtNull) then
    Result := ADefault
  else
    Result := D.AsFloat;
end;

function JsonGetBool(O: TJSONObject; const AName: String;
  ADefault: Boolean): Boolean;
var
  D: TJSONData;
begin
  if O = nil then
  begin
    Result := ADefault;
    Exit;
  end;
  D := O.Find(AName);
  if (D = nil) or (D.JSONType = jtNull) then
    Result := ADefault
  else
    Result := D.AsBoolean;
end;

{ ══════════════════════════════════════════════════════════════════
  EVeloSiteError
  ══════════════════════════════════════════════════════════════════ }

constructor EVeloSiteError.Create(AHttpStatus: Integer;
  const AErrorCode, AMessage: String; AFields: TStringList);
begin
  inherited Create(AMessage);
  FHttpStatus := AHttpStatus;
  FErrorCode  := AErrorCode;
  FFields     := AFields;
end;

destructor EVeloSiteError.Destroy;
begin
  FFields.Free;
  inherited;
end;

{ ══════════════════════════════════════════════════════════════════
  TVeloSiteAPI
  ══════════════════════════════════════════════════════════════════ }

function ProfileFromJson(Obj: TJSONObject): TVeloSiteProfile;
begin
  Result := Default(TVeloSiteProfile);
  Result.Id := JsonGetInt64(Obj, 'id', 0);
  Result.Email := JsonGetStr(Obj, 'email', '');
  Result.Nickname := JsonGetStr(Obj, 'nickname', '');
  Result.WeightKg := JsonGetInt64(Obj, 'weight_g', 0) / 1000.0;
  Result.FtpW := JsonGetInt64(Obj, 'ftp_w', 0);
  if Obj.Find('training_zones') is TJSONObject then
    Result.TrainingZonesJSON := Obj.Find('training_zones').AsJSON;
  Result.IsAdmin := JsonGetBool(Obj, 'is_admin', False);
  Result.EmailVerified := JsonGetBool(Obj, 'email_verified', False);
  Result.CreatedAt := JsonGetStr(Obj, 'created_at', '');
  Result.Locale := JsonGetStr(Obj, 'locale', '');
end;

function ProfileToJson(const P: TVeloSiteProfile): TJSONObject;
begin
  Result := TJSONObject.Create;
  try
    Result.Add('id', P.Id);
    Result.Add('email', P.Email);
    Result.Add('nickname', P.Nickname);
    Result.Add('weight_g', Round(P.WeightKg * 1000));
    Result.Add('ftp_w', P.FtpW);
    if P.TrainingZonesJSON <> '' then
      Result.Add('training_zones', GetJSON(P.TrainingZonesJSON));
    Result.Add('is_admin', P.IsAdmin);
    Result.Add('email_verified', P.EmailVerified);
    Result.Add('created_at', P.CreatedAt);
    Result.Add('locale', P.Locale);
  except Result.Free; raise end;
end;

constructor TVeloSiteAPI.Create;
var
  ConfigUrl, TestBase, TestAuth: String;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FRefreshLock := TCriticalSection.Create;
  FAsyncLock := TCriticalSection.Create;
  FBaseUrl := VELOSITE_PRIMARY_BASE_URL;
  FHostChecked := False;

  { castle-config:/ — современная схема Castle для пер-юзер конфига.
    URIToFilenameSafe конвертирует в нативный путь (Windows: %APPDATA%\<app>\,
    Linux: ~/.config/<app>/, macOS: ~/Library/Application Support/<app>/).
    Папка создаётся автоматически при первой записи. }
  ConfigUrl := 'castle-config:/' + AUTH_FILE_NAME;
  FAuthFile := URIToFilenameSafe(ConfigUrl);
  if FAuthFile = '' then
    FAuthFile := AUTH_FILE_NAME;  { fallback — рабочая директория }

  { Explicit loopback-only regression fixture, with a separate token file.
    Never send the real profile credentials to a test server. }
  TestBase:=GetEnvironmentVariable('REZVIVO_TEST_API');
  TestAuth:=GetEnvironmentVariable('REZVIVO_TEST_AUTH_FILE');
  if (Copy(TestBase,1,17)='http://127.0.0.1:') and (TestAuth<>'') then
  begin FBaseUrl:=ExcludeTrailingPathDelimiter(TestBase);FHostChecked:=True;FAuthFile:=TestAuth;end;

  LoadTokens;

  if FTokens.RefreshToken <> '' then
    WritelnLog('VeloSite', 'Tokens loaded from ' + FAuthFile)
  else
    WritelnLog('VeloSite', 'No saved tokens, login required');
end;

destructor TVeloSiteAPI.Destroy;
begin
  ShutdownAsync;
  FAsyncLock.Free;
  FRefreshLock.Free;
  FLock.Free;
  inherited;
end;

function TVeloSiteAPI.GetBaseUrl: String;
begin
  FLock.Enter;
  try Result := FBaseUrl; finally FLock.Leave end;
end;

procedure TVeloSiteAPI.SetBaseUrl(const Value: String);
begin
  FLock.Enter;
  try FBaseUrl := Value; finally FLock.Leave end;
end;

function TVeloSiteAPI.GetIsAuthorized: Boolean;
begin
  FLock.Enter;
  try
    Result := FTokens.RefreshToken <> '';
  finally
    FLock.Leave;
  end;
end;

function TVeloSiteAPI.GetAccessToken: String;
begin
  FLock.Enter;
  try
    Result := FTokens.AccessToken;
  finally
    FLock.Leave;
  end;
end;

function TVeloSiteAPI.GetAccessTokenForUser(UserId:Int64):String;
begin
  FLock.Enter;
  try
    Result:='';
    if FHasProfileCache and(FProfileCache.Id=UserId)and(FTokens.RefreshToken<>'')then
      Result:=FTokens.AccessToken;
  finally FLock.Leave end;
end;

function TVeloSiteAPI.MakeUrl(const APath: String): String;
var
  Base: String;
begin
  FLock.Enter;
  try
    Base := FBaseUrl;
  finally
    FLock.Leave;
  end;
  if (APath = '') or (APath[1] <> '/') then
    Result := Base + '/' + APath
  else
    Result := Base + APath;
end;

function TVeloSiteAPI.PingHost(const ABaseUrl: String): Boolean;
var
  Resp: TMemoryStream;
  Status: Integer;
begin
  Result := False;
  Resp := TMemoryStream.Create;
  try
    try
      GameHttpRequest('GET', ABaseUrl + '/healthz', nil, nil, 3000, 4000,
        Resp, Status, ProfileHttpCancellation);
      Result := (Status >= 200) and (Status < 300);
    except
      on E: Exception do
      begin
        WritelnLog('VeloSite', 'Ping ' + ABaseUrl + ' failed: ' + E.Message);
        Result := False;
      end;
    end;
  finally
    Resp.Free;
  end;
end;

procedure TVeloSiteAPI.EnsureHost;
var
  Chosen: String;
begin
  if ProfileHttpCancellation <> nil then ProfileHttpCancellation.Check;
  FLock.Enter;
  try
    if FHostChecked then Exit;
  finally
    FLock.Leave;
  end;

  Chosen := VELOSITE_PRIMARY_BASE_URL;
  if PingHost(VELOSITE_PRIMARY_BASE_URL) then
  begin
    Chosen := VELOSITE_PRIMARY_BASE_URL;
    WritelnLog('VeloSite', 'Host OK: ' + Chosen);
  end
  else if PingHost(VELOSITE_FALLBACK_BASE_URL) then
  begin
    Chosen := VELOSITE_FALLBACK_BASE_URL;
    WritelnLog('VeloSite', 'Primary down, using fallback: ' + Chosen);
  end
  else
    WritelnLog('VeloSite',
      'Neither host answered /healthz; keeping ' + Chosen);

  FLock.Enter;
  try
    if not FHostChecked then
    begin
      FBaseUrl := Chosen;
      FHostChecked := True;
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TVeloSiteAPI.SwitchHost;
begin
  FLock.Enter;
  try
    if CompareText(FBaseUrl, VELOSITE_PRIMARY_BASE_URL) = 0 then
      FBaseUrl := VELOSITE_FALLBACK_BASE_URL
    else
      FBaseUrl := VELOSITE_PRIMARY_BASE_URL;
    FHostChecked := True;
    WritelnLog('VeloSite', 'Failover to ' + FBaseUrl);
  finally
    FLock.Leave;
  end;
end;

function TVeloSiteAPI.RelayUrl: String;
begin
  EnsureHost;
  FLock.Enter;
  try
    Result := FBaseUrl + '/relay';
  finally
    FLock.Leave;
  end;
end;

function TVeloSiteAPI.RewritePublicUrl(const AUrl: String): String;
var
  Base: String;
begin
  FLock.Enter;
  try
    Base := FBaseUrl;
  finally
    FLock.Leave;
  end;
  Result := Trim(AUrl);
  if Result = '' then
  begin
    Result := Base + '/link';
    Exit;
  end;
  Result := StringReplace(Result, 'https://rezvivo.com', Base, [rfIgnoreCase]);
  Result := StringReplace(Result, 'http://rezvivo.com', Base, [rfIgnoreCase]);
  Result := StringReplace(Result, 'https://rezvivo.ru', Base, [rfIgnoreCase]);
  Result := StringReplace(Result, 'http://rezvivo.ru', Base, [rfIgnoreCase]);
  Result := StringReplace(Result, 'https://softmetodika.ru/velosite', Base,
    [rfIgnoreCase]);
  Result := StringReplace(Result, 'http://softmetodika.ru/velosite', Base,
    [rfIgnoreCase]);
end;

function TVeloSiteAPI.NowUnix: Int64;
begin
  Result := DateTimeToUnix(LocalTimeToUniversal(Now));
end;

procedure TVeloSiteAPI.LoadTokens;
var
  Stream: TFileStream;
  Json:   TJSONData;
  Obj:    TJSONObject;
begin
  if not FileExists(FAuthFile) then Exit;
  try
    Stream := TFileStream.Create(FAuthFile, fmOpenRead or fmShareDenyWrite);
    try
      if Stream.Size = 0 then Exit;
      Json := GetJSON(Stream);
      try
        if Json is TJSONObject then
        begin
          Obj := TJSONObject(Json);
          FTokens.AccessToken  := JsonGetStr(Obj, 'access_token', '');
          FTokens.RefreshToken := JsonGetStr(Obj, 'refresh_token', '');
          FTokens.ExpiresAt    := JsonGetInt64(Obj, 'expires_at', 0);
          { Kept in the same atomic document as the credentials: a login,
            logout or token refresh cannot leave another account's cache. }
          if (FTokens.RefreshToken <> '') and
             (Obj.Find('profile') is TJSONObject) then
          begin
            FProfileCache := ProfileFromJson(TJSONObject(Obj.Find('profile')));
            FHasProfileCache := FProfileCache.Id > 0;
          end;
        end;
      finally
        Json.Free;
      end;
    finally
      Stream.Free;
    end;
  except
    on E: Exception do
      WritelnLog('VeloSite', 'LoadTokens failed: ' + E.Message);
  end;
end;

procedure TVeloSiteAPI.SaveTokens;
var
  Obj:    TJSONObject;
  Body:   String;
  Stream: TFileStream;
  Dir:    String;
  TempName: String;
  TempId: TGuid;
begin
  Dir := ExtractFilePath(FAuthFile);
  if (Dir <> '') and not DirectoryExists(Dir) then
    ForceDirectories(Dir);

  Obj := TJSONObject.Create;
  try
    Obj.Add('access_token',  FTokens.AccessToken);
    Obj.Add('refresh_token', FTokens.RefreshToken);
    Obj.Add('expires_at',    FTokens.ExpiresAt);
    if FHasProfileCache and (FTokens.RefreshToken <> '') then
      Obj.Add('profile', ProfileToJson(FProfileCache));
    Body := Obj.AsJSON;
  finally
    Obj.Free;
  end;

  try
    if CreateGUID(TempId) <> 0 then raise EWriteError.Create('Cannot create auth temporary name');
    TempName := FAuthFile + '.' + GUIDToString(TempId) + '.tmp';
    try
    Stream := TFileStream.Create(TempName, fmCreate);
    try
      {$ifdef UNIX}FpChmod(TempName, &600);{$endif}
      if Body <> '' then
        Stream.WriteBuffer(Body[1], Length(Body));
      if not FileFlush(Stream.Handle) then raise EWriteError.Create('Cannot flush auth file');
    finally
      Stream.Free;
    end;
    {$ifdef MSWINDOWS}
    if not AuthMoveFile(PWideChar(UTF8Decode(TempName)),
      PWideChar(UTF8Decode(FAuthFile)), $1 or $8) then
    {$else}
    if not RenameFile(TempName, FAuthFile) then
    {$endif}
      raise EWriteError.Create('Cannot replace auth file');
    {$ifdef UNIX}
    { rw для владельца, ничего для остальных. См. рекомендации
      в game-integration.md. }
    FpChmod(FAuthFile, &600);
    {$endif}
    finally
      if FileExists(TempName) then DeleteFile(TempName);
    end;
  except
    on E: Exception do
      WritelnLog('VeloSite', 'SaveTokens failed: ' + E.Message);
  end;
end;

procedure TVeloSiteAPI.ClearTokensFile;
begin
  if FileExists(FAuthFile) then
    DeleteFile(FAuthFile);
end;

function TVeloSiteAPI.ExtractError(AResponseStatus: Integer;
  AResponseBody: TStream): EVeloSiteError;
var
  Json:      TJSONData;
  Obj:       TJSONObject;
  ErrCode:   String;
  ErrMsg:    String;
  Fields:    TStringList;
  FieldsObj: TJSONObject;
  FieldsRaw: TJSONData;
  I:         Integer;
  RawBody:   String;
  FirstByte: Byte;
  LooksLikeJson: Boolean;
begin
  ErrCode := '';
  ErrMsg  := '';
  Fields  := nil;
  RawBody := '';

  if (AResponseBody <> nil) and (AResponseBody.Size > 0) then
  begin
    { Читаем тело сначала как сырой текст — пригодится для лога,
      и для случая когда сервер ответил HTML/text вместо JSON. }
    SetLength(RawBody, AResponseBody.Size);
    AResponseBody.Position := 0;
    AResponseBody.ReadBuffer(RawBody[1], AResponseBody.Size);

    { Пре-проверка: похоже ли тело на JSON-объект или массив? Это
      экономит вызов GetJSON, который при невалидном теле кидает
      EJSONParser, а отладчик с «pause on raise» на этом тормозит.

      Пропускаем ведущие пробелы/CR/LF; первый смысловой байт должен
      быть открывающей фигурной или квадратной скобкой. Иначе
      считаем что сервер вернул HTML или просто текст. }
    LooksLikeJson := False;
    AResponseBody.Position := 0;
    while AResponseBody.Position < AResponseBody.Size do
    begin
      AResponseBody.ReadBuffer(FirstByte, 1);
      if (FirstByte = $20) or (FirstByte = $09) or
         (FirstByte = $0A) or (FirstByte = $0D) then
        Continue;
      LooksLikeJson := (FirstByte = Ord('{')) or (FirstByte = Ord('['));
      Break;
    end;

    if LooksLikeJson then
    begin
      AResponseBody.Position := 0;
      try
        Json := GetJSON(AResponseBody);
        try
          if Json is TJSONObject then
          begin
            Obj := TJSONObject(Json);
            ErrCode := JsonGetStr(Obj, 'error', '');
            ErrMsg  := JsonGetStr(Obj, 'text', '');
            if ErrMsg = '' then
              ErrMsg := JsonGetStr(Obj, 'message', '');
            if ErrMsg = '' then
              ErrMsg := JsonGetStr(Obj, 'detail', '');

            FieldsRaw := Obj.Find('fields');
            if (FieldsRaw <> nil) and (FieldsRaw is TJSONObject) then
            begin
              FieldsObj := TJSONObject(FieldsRaw);
              Fields := TStringList.Create;
              for I := 0 to FieldsObj.Count - 1 do
                Fields.Values[FieldsObj.Names[I]] :=
                  FieldsObj.Items[I].AsString;
            end;
          end;
        finally
          Json.Free;
        end;
      except
        on E: Exception do
          WritelnLog('VeloSite',
            'JSON parse failed despite valid prefix: ' + E.Message);
      end;
    end;

    { Лог тела для диагностики (срезаем длинные ответы — например HTML
      от nginx может быть на десятки килобайт). }
    if Length(RawBody) > 500 then
      WritelnLog('VeloSite', Format('Error body (%d bytes, truncated): %s',
        [Length(RawBody), Copy(RawBody, 1, 500)]))
    else if Length(RawBody) > 0 then
      WritelnLog('VeloSite', 'Error body: ' + RawBody);
  end;

  if ErrCode = '' then
    ErrCode := Format('http_%d', [AResponseStatus]);

  { Сообщение собираем по приоритету: message/detail из JSON →
    краткая выдержка из raw-тела → код HTTP. }
  if ErrMsg = '' then
  begin
    if RawBody <> '' then
    begin
      ErrMsg := Trim(RawBody);
      if Length(ErrMsg) > 200 then
        ErrMsg := Copy(ErrMsg, 1, 200) + '...';
    end
    else
      ErrMsg := Format('HTTP %d', [AResponseStatus]);
  end;

  Result := EVeloSiteError.Create(AResponseStatus, ErrCode,
    Format('VeloSite %d (%s): %s', [AResponseStatus, ErrCode, ErrMsg]),
    Fields);
end;

function TVeloSiteAPI.DoRequest(const AMethod, APath, AContentType: String;
  ARequestBody: TStream; AAuth, ARetryAuth: Boolean): TJSONData;
begin
  EnsureHost;
  Result := DoRequestOnce(AMethod, APath, AContentType, ARequestBody,
    AAuth, ARetryAuth, True);
end;

function TVeloSiteAPI.DoRequestOnce(const AMethod, APath, AContentType: String;
  ARequestBody: TStream; AAuth, ARetryAuth, AAllowFailover: Boolean): TJSONData;
var
  RespStream:  TMemoryStream;
  Hdr:         TStringList;
  Url:         String;
  AccessToken: String;
  Status:      Integer;
  NeedRetry:   Boolean;
  NeedFailOver: Boolean;
begin
  Result := nil;
  NeedRetry := False;
  NeedFailOver := False;

  { nginx + Go на rezvivo.com / .ru принимают PATCH/PUT/DELETE напрямую. }

  Hdr := TStringList.Create;
  Hdr.NameValueSeparator := ':';
  RespStream := TMemoryStream.Create;
  try
    Hdr.Add('Accept: application/json');
    Hdr.Add('Accept-Language: ' + UiLanguage);
    if AContentType <> '' then
      Hdr.Add('Content-Type: ' + AContentType);

    if AAuth then
    begin
      FLock.Enter;
      try
        AccessToken := FTokens.AccessToken;
      finally
        FLock.Leave;
      end;
      if AccessToken = '' then
        raise EVeloSiteError.Create(401, 'unauthorized',
          'No access token; login first', nil);
      Hdr.Add('Authorization: Bearer ' + AccessToken);
    end;

    if Assigned(ARequestBody) then
      ARequestBody.Position := 0;

    Url := MakeUrl(APath);
    try
      GameHttpRequest(AMethod, Url, Hdr, ARequestBody, 10000, 30000,
        RespStream, Status, ProfileHttpCancellation);
    except
      on E: Exception do
      begin
        if ProfileHttpCancellation <> nil then ProfileHttpCancellation.Check;
        if AAllowFailover then
        begin
          WritelnLog('VeloSite', Format('%s %s failed on %s: %s',
            [AMethod, APath, Url, E.Message]));
          NeedFailOver := True;
        end
        else
          raise;
      end;
    end;

    if not NeedFailOver then
    begin
      WritelnLog('VeloSite', Format('%s %s → %d', [AMethod, Url, Status]));

      if AAllowFailover and ((Status = 502) or (Status = 503) or (Status = 504)) then
        NeedFailOver := True
      else if (Status = 401) and AAuth and ARetryAuth then
        NeedRetry := True
      else if (Status >= 200) and (Status < 300) then
      begin
        RespStream.Position := 0;
        if RespStream.Size > 0 then
          Result := GetJSON(RespStream)
        else
          Result := TJSONObject.Create;     { пустое тело — пустой объект }
      end
      else
        raise ExtractError(Status, RespStream);
    end;
  finally
    RespStream.Free;
    Hdr.Free;
  end;

  if NeedFailOver then
  begin
    SwitchHost;
    Result := DoRequestOnce(AMethod, APath, AContentType, ARequestBody,
      AAuth, ARetryAuth, False);
  end
  else if NeedRetry then
  begin
    if TryRefreshAccess then
      Result := DoRequestOnce(AMethod, APath, AContentType, ARequestBody,
        AAuth, False, False)
    else
    begin
      DropTokens;
      raise EVeloSiteError.Create(401, 'session_expired',
        'Refresh failed; full re-login required', nil);
    end;
  end;
end;

procedure TVeloSiteAPI.ClearProfileCacheLocked;
begin
  FHasProfileCache := False;
  FProfileCache := Default(TVeloSiteProfile);
  FEntitlementsCache := Default(TVeloSiteEntitlements);
end;

procedure TVeloSiteAPI.ApplyTokenResponse(AJson: TJSONObject; ANewSession: Boolean);
var
  ExpiresIn: Int64;
  ExpiresAt: Int64;
begin
  ExpiresIn := JsonGetInt64(AJson, 'expires_in', 0);
  ExpiresAt := JsonGetInt64(AJson, 'expires_at', 0);
  if ExpiresAt = 0 then
    ExpiresAt := NowUnix + ExpiresIn;

  FLock.Enter;
  try
    if ANewSession then
    begin
      Inc(FAuthGeneration);
      ClearProfileCacheLocked;
    end;
    FTokens.AccessToken  := JsonGetStr(AJson, 'access_token', '');
    FTokens.RefreshToken := JsonGetStr(AJson, 'refresh_token', '');
    FTokens.ExpiresAt    := ExpiresAt;
    SaveTokens;
  finally
    FLock.Leave;
  end;
end;

function TVeloSiteAPI.GetOsmAccessToken: String;
begin
  Result := '';
  if not IsAuthorized then Exit;
  if not TryRefreshAccess(True) then Exit;
  FLock.Enter;
  try
    if (FTokens.RefreshToken <> '') and (FTokens.ExpiresAt > NowUnix + 5) then
      Result := FTokens.AccessToken;
  finally FLock.Leave end;
end;

function TVeloSiteAPI.TryRefreshAccess(const OnlyIfExpiring: Boolean): Boolean;
var
  Body:         TJSONObject;
  BodyStr:      String;
  RefreshToken: String;
  BodyStream:   TStringStream;
  Resp:         TJSONData;
  Generation: QWord;
begin
  Result := False;
  FRefreshLock.Enter;
  try
    FLock.Enter;
    try
      RefreshToken := FTokens.RefreshToken;
      Generation := FAuthGeneration;
      if OnlyIfExpiring and (RefreshToken <> '') and
        (FTokens.AccessToken <> '') and (FTokens.ExpiresAt > NowUnix + 60) then Exit(True);
    finally
      FLock.Leave;
    end;

    if RefreshToken = '' then Exit;

    Body := TJSONObject.Create;
    try
      Body.Add('refresh_token', RefreshToken);
      BodyStr := Body.AsJSON;
    finally
      Body.Free;
    end;

    BodyStream := TStringStream.Create(BodyStr);
    try
      try
        Resp := DoRequest('POST', '/api/v1/auth/refresh',
          'application/json; charset=utf-8', BodyStream, False, False);
        try
          if Resp is TJSONObject then
          begin
            FLock.Enter;
            try
              if FAuthGeneration <> Generation then
                raise Exception.Create('Account changed during token refresh');
              ApplyTokenResponse(TJSONObject(Resp), False);
              Result := True;
            finally FLock.Leave end;
          end;
        finally
          Resp.Free;
        end;
      except
        on E: EVeloSiteError do
        begin
          FLock.Enter;
          try
            if FAuthGeneration <> Generation then
              raise Exception.Create('Account changed during token refresh');
          finally FLock.Leave end;
          WritelnLog('VeloSite', Format('Refresh failed: %d %s',
            [E.HttpStatus, E.ErrorCode]));
          Result := False;
        end;
      end;
    finally
      BodyStream.Free;
    end;
  finally FRefreshLock.Leave end;
end;

procedure TVeloSiteAPI.Login(const AEmail, APassword: String);
var
  Body:       TJSONObject;
  BodyStr:    String;
  BodyStream: TStringStream;
  Resp:       TJSONData;
begin
  Body := TJSONObject.Create;
  try
    Body.Add('email', AEmail);
    Body.Add('password', APassword);
    BodyStr := Body.AsJSON;
  finally
    Body.Free;
  end;

  BodyStream := TStringStream.Create(BodyStr);
  try
    Resp := DoRequest('POST', '/api/v1/auth/login',
      'application/json; charset=utf-8', BodyStream, False, False);
    try
      if Resp is TJSONObject then
        ApplyTokenResponse(TJSONObject(Resp))
      else
        raise EVeloSiteError.Create(500, 'invalid_response',
          'Login: unexpected response shape', nil);
    finally
      Resp.Free;
    end;
  finally
    BodyStream.Free;
  end;
end;

function TVeloSiteAPI.DeviceStart: TVeloSiteDeviceCode;
var
  BodyStream: TStringStream;
  Resp:       TJSONData;
  Obj:        TJSONObject;
begin
  Result := Default(TVeloSiteDeviceCode);

  BodyStream := TStringStream.Create('{}');
  try
    Resp := DoRequest('POST', '/api/v1/auth/device/start',
      'application/json; charset=utf-8', BodyStream, False, False);
    try
      if not (Resp is TJSONObject) then
        raise EVeloSiteError.Create(500, 'invalid_response',
          'DeviceStart: unexpected response', nil);
      Obj := TJSONObject(Resp);
      Result.DeviceCode      := JsonGetStr(Obj, 'device_code', '');
      Result.UserCode        := JsonGetStr(Obj, 'user_code', '');
      { Сервер возвращает verification_uri, документация (расходящаяся
        с реальностью) обещает verification_url. Поддерживаем оба. }
      Result.VerificationUrl := JsonGetStr(Obj, 'verification_uri', '');
      if Result.VerificationUrl = '' then
        Result.VerificationUrl := JsonGetStr(Obj, 'verification_url', '');
      Result.VerificationUrl := RewritePublicUrl(Result.VerificationUrl);
      Result.ExpiresIn       := JsonGetInt64(Obj, 'expires_in', 0);
      Result.Interval        := JsonGetInt64(Obj, 'interval', 5);
    finally
      Resp.Free;
    end;
  finally
    BodyStream.Free;
  end;
end;

function TVeloSiteAPI.DevicePoll(const ADeviceCode: String): Boolean;
var
  Body:       TJSONObject;
  BodyStr:    String;
  BodyStream: TStringStream;
  Resp:       TJSONData;
begin
  Result := False;

  Body := TJSONObject.Create;
  try
    Body.Add('device_code', ADeviceCode);
    BodyStr := Body.AsJSON;
  finally
    Body.Free;
  end;

  BodyStream := TStringStream.Create(BodyStr);
  try
    Resp := DoRequest('POST', '/api/v1/auth/device/poll',
      'application/json; charset=utf-8', BodyStream, False, False);
    try
      if not (Resp is TJSONObject) then Exit;

      { 200 → есть access_token (success); 202 → status=pending. }
      if JsonGetStr(TJSONObject(Resp), 'access_token', '') <> '' then
      begin
        ApplyTokenResponse(TJSONObject(Resp));
        Result := True;
      end;
    finally
      Resp.Free;
    end;
  finally
    BodyStream.Free;
  end;
end;

procedure TVeloSiteAPI.Logout;
var
  Body:         TJSONObject;
  BodyStr:      String;
  RefreshToken: String;
  BodyStream:   TStringStream;
  Resp:         TJSONData;
begin
  FLock.Enter;
  try
    RefreshToken := FTokens.RefreshToken;
  finally
    FLock.Leave;
  end;

  if IsAuthorized then
  begin
    Body := TJSONObject.Create;
    try
      Body.Add('refresh_token', RefreshToken);
      BodyStr := Body.AsJSON;
    finally
      Body.Free;
    end;
    BodyStream := TStringStream.Create(BodyStr);
    try
      try
        Resp := DoRequest('POST', '/api/v1/auth/logout',
          'application/json; charset=utf-8', BodyStream, True, True);
        Resp.Free;
      except
        on E: Exception do
          WritelnLog('VeloSite',
            'Server logout failed (proceeding locally): ' + E.Message);
      end;
    finally
      BodyStream.Free;
    end;
  end;
  DropTokens;
end;

procedure TVeloSiteAPI.DropTokens;
begin
  FLock.Enter;
  try
    Inc(FAuthGeneration);
    ClearProfileCacheLocked;
    FTokens.AccessToken  := '';
    FTokens.RefreshToken := '';
    FTokens.ExpiresAt    := 0;
    ClearTokensFile;
  finally
    FLock.Leave;
  end;
  WritelnLog('VeloSite', 'Tokens dropped');
end;

function TVeloSiteAPI.GetMe: TVeloSiteProfile;
var
  Resp: TJSONData;
  Obj:  TJSONObject;
begin
  Result := Default(TVeloSiteProfile);
  Resp := DoRequest('GET', '/api/v1/me', '', nil, True, True);
  try
    if not (Resp is TJSONObject) then
      raise EVeloSiteError.Create(500, 'invalid_response',
        'GetMe: unexpected response', nil);
    Obj := TJSONObject(Resp);
    Result := ProfileFromJson(Obj);
  finally
    Resp.Free;
  end;
end;

procedure TVeloSiteAPI.PatchProfile(const ANickname: String;
  AWeightKg: Single; AFtpW: Integer; const ATrainingZonesJSON: String);
var
  Body:       TJSONObject;
  BodyStr:    String;
  BodyStream: TStringStream;
  Resp:       TJSONData;
begin
  Body := TJSONObject.Create;
  try
    if ANickname <> '' then
      Body.Add('nickname', ANickname);
    if AWeightKg >= 0 then
      { weight_g — uint32 граммы. Сервер отвергает дробные значения. }
      Body.Add('weight_g', Round(AWeightKg * 1000));
    if AFtpW >= 0 then
      Body.Add('ftp_w', AFtpW);
    if ATrainingZonesJSON <> '' then
      Body.Add('training_zones', GetJSON(ATrainingZonesJSON));

    if Body.Count = 0 then Exit;     { ничего не меняем — без запроса }

    BodyStr := Body.AsJSON;
  finally
    Body.Free;
  end;

  BodyStream := TStringStream.Create(BodyStr);
  try
    Resp := DoRequest('PATCH', '/api/v1/me/profile',
      'application/json; charset=utf-8', BodyStream, True, True);
    Resp.Free;     { ответ нам тут не нужен }
  finally
    BodyStream.Free;
  end;
end;

procedure TVeloSiteAPI.ImportTrainingZones;
var
  Resp: TJSONData;
begin
  Resp := DoRequest('POST', '/api/v1/connectors/intervals/zones', '', nil, True, True);
  Resp.Free;
end;

function TVeloSiteAPI.GetEntitlements: TVeloSiteEntitlements;
var
  Resp: TJSONData;
  Obj:  TJSONObject;
begin
  Result := Default(TVeloSiteEntitlements);
  Resp := DoRequest('GET', '/api/v1/me/entitlements', '', nil, True, True);
  try
    if not (Resp is TJSONObject) then
      raise EVeloSiteError.Create(500, 'invalid_response',
        'GetEntitlements: unexpected response', nil);
    Obj := TJSONObject(Resp);
    Result.HasAccess := JsonGetBool(Obj, 'has_access', False);
    Result.Source    := JsonGetStr (Obj, 'source',     '');
    Result.ExpiresAt := JsonGetStr (Obj, 'expires_at', '');
  finally
    Resp.Free;
  end;
end;

{ ── Phase 3: cached profile ─────────────────────────────────────── }

function TVeloSiteAPI.HasCachedProfile: Boolean;
begin
  FLock.Enter;
  try
    Result := FHasProfileCache;
  finally
    FLock.Leave;
  end;
end;

function TVeloSiteAPI.CachedProfile: TVeloSiteProfile;
begin
  FLock.Enter;
  try
    if FHasProfileCache then
      Result := FProfileCache
    else
      Result := Default(TVeloSiteProfile);
  finally
    FLock.Leave;
  end;
end;

function TVeloSiteAPI.CachedEntitlements: TVeloSiteEntitlements;
begin
  FLock.Enter;
  try
    if FHasProfileCache then
      Result := FEntitlementsCache
    else
      Result := Default(TVeloSiteEntitlements);
  finally
    FLock.Leave;
  end;
end;

procedure TVeloSiteAPI.RefreshProfile;
var
  P: TVeloSiteProfile;
  E: TVeloSiteEntitlements;
  Generation: QWord;
begin
  FLock.Enter;
  try
    Generation := FAuthGeneration;
    if FTokens.AccessToken = '' then
      raise EVeloSiteError.Create(401, 'unauthorized', 'Login required', nil);
  finally FLock.Leave end;
  P := GetMe;
  FLock.Enter;
  try
    if FAuthGeneration <> Generation then
      raise Exception.Create('Account changed during profile refresh');
    { The profile remains useful offline even when the separate entitlement
      endpoint fails. Do not persist subscription grants or version policy. }
    FProfileCache := P;
    FHasProfileCache := True;
    SaveTokens;
  finally FLock.Leave end;
  E := GetEntitlements;
  FLock.Enter;
  try
    if FAuthGeneration <> Generation then
      raise Exception.Create('Account changed during profile refresh');
    FProfileCache := P;
    FEntitlementsCache := E;
    FHasProfileCache := True;
  finally
    FLock.Leave;
  end;
end;

type
  { Внутренний поток для RefreshProfileAsync. Объявлен в реализации,
    snapshots ссылку на TVeloSiteAPI и саморазрушается после
    завершения. Нужен потому что FPC в objfpc mode не поддерживает
    anonymous procedures (Delphi-only синтаксис). }
  TVeloSiteRefreshThread = class(TThread)
  private
    FApi: TVeloSiteAPI;
  protected
    procedure Execute; override;
  public
    constructor Create(AApi: TVeloSiteAPI);
  end;

constructor TVeloSiteRefreshThread.Create(AApi: TVeloSiteAPI);
begin
  inherited Create(True);
  FApi := AApi;
  FreeOnTerminate := False;
end;

procedure TVeloSiteRefreshThread.Execute;
begin
  ProfileHttpCancellation := FApi.FAsyncCancel;
  try
    try
      FApi.EnsureHost;
      ProfileHttpCancellation.Check;
      if FApi.IsAuthorized then FApi.RefreshProfile;
      Logger.Info('[VeloSite] Background host/profile refresh finished');
    except
      on E: Exception do
        if not Terminated then
          Logger.Warning('[VeloSite] Background refresh: ' + E.Message);
    end;
  finally
    ProfileHttpCancellation := nil;
  end;
end;

procedure TVeloSiteAPI.RefreshProfileAsync;
begin
  if not IsAuthorized then Exit;
  InitializeAsync;
end;

procedure TVeloSiteAPI.InitializeAsync;
begin
  FAsyncLock.Enter;
  try
    if FShuttingDown then Exit;
    if FAsyncWorker <> nil then
    begin
      if not FAsyncWorker.Finished then Exit;
      FreeAndNil(FAsyncWorker);
      FreeAndNil(FAsyncCancel);
    end;
    FAsyncCancel := TGameHttpCancellation.Create;
    try
      FAsyncWorker := TVeloSiteRefreshThread.Create(Self);
      FAsyncWorker.Start;
    except
      FreeAndNil(FAsyncWorker);
      FreeAndNil(FAsyncCancel);
      raise;
    end;
  finally FAsyncLock.Leave end;
end;

procedure TVeloSiteAPI.ShutdownAsync;
begin
  FAsyncLock.Enter;
  try
    FShuttingDown := True;
    if FAsyncWorker <> nil then
    begin
      FAsyncWorker.Terminate;
      FAsyncCancel.Cancel;
      FAsyncWorker.WaitFor;
      FreeAndNil(FAsyncWorker);
    end;
    FreeAndNil(FAsyncCancel);
  finally FAsyncLock.Leave end;
end;

{ ══════════════════════════════════════════════════════════════════
  Phase 4: multipart-загрузка для POST /api/v1/rides

  RFC 7578. Тело собирается в TMemoryStream, IDempotency-Key — в
  заголовке. Использует тот же 401-refresh-retry, что и DoRequest.
  ══════════════════════════════════════════════════════════════════ }

function GenerateBoundary: String;
var
  I: Integer;
begin
  Result := '----velosite';
  for I := 1 to 32 do
    Result := Result + LowerCase(IntToHex(Random(16), 1));
end;

procedure WriteStrToStream(S: TStream; const Text: String);
begin
  if Length(Text) > 0 then
    S.WriteBuffer(Text[1], Length(Text));
end;

function TVeloSiteAPI.DoMultipartRideUpload(
  const AIdempotencyKey, AFitFileName, AMetaJson: String): TJSONData;
var
  Boundary, ContentType: String;
  Body: TMemoryStream;
  FileStream: TFileStream;
  Hdr: TStringList;
  RespStream: TMemoryStream;
  Url, AccessToken: String;
  Status: Integer;
  NeedRetry: Boolean;
begin
  Result := nil;
  NeedRetry := False;

  if not FileExists(AFitFileName) then
    raise EVeloSiteError.Create(0, 'fit_missing',
      'FIT file not found: ' + AFitFileName, nil);

  Boundary := GenerateBoundary;
  ContentType := 'multipart/form-data; boundary=' + Boundary;

  Body := TMemoryStream.Create;
  try
    WriteStrToStream(Body, '--' + Boundary + #13#10);
    WriteStrToStream(Body,
      'Content-Disposition: form-data; name="metadata"' + #13#10);
    WriteStrToStream(Body, 'Content-Type: application/json' + #13#10#13#10);
    WriteStrToStream(Body, AMetaJson + #13#10);

    WriteStrToStream(Body, '--' + Boundary + #13#10);
    WriteStrToStream(Body,
      Format('Content-Disposition: form-data; name="file"; filename="%s"' + #13#10,
        [ExtractFileName(AFitFileName)]));
    WriteStrToStream(Body,
      'Content-Type: application/octet-stream' + #13#10#13#10);

    FileStream := TFileStream.Create(AFitFileName, fmOpenRead or fmShareDenyWrite);
    try
      Body.CopyFrom(FileStream, FileStream.Size);
    finally
      FileStream.Free;
    end;
    WriteStrToStream(Body, #13#10);

    WriteStrToStream(Body, '--' + Boundary + '--' + #13#10);

    Body.Position := 0;

    Hdr := TStringList.Create;
    Hdr.NameValueSeparator := ':';
    RespStream := TMemoryStream.Create;
    try
      Hdr.Add('Accept: application/json');
    Hdr.Add('Accept-Language: ' + UiLanguage);
      Hdr.Add('Content-Type: ' + ContentType);
      Hdr.Add('Idempotency-Key: ' + AIdempotencyKey);

      FLock.Enter;
      try
        AccessToken := FTokens.AccessToken;
      finally
        FLock.Leave;
      end;
      if AccessToken = '' then
        raise EVeloSiteError.Create(401, 'unauthorized',
          'No access token; login first', nil);
      Hdr.Add('Authorization: Bearer ' + AccessToken);

      EnsureHost;
      Url := MakeUrl('/api/v1/rides');
      Body.Position := 0;
      try
        GameHttpRequest('POST', Url, Hdr, Body, 15000, 200000,
          RespStream, Status);
      except
        on E: Exception do
        begin
          WritelnLog('VeloSite', 'POST /api/v1/rides failed on ' + Url
            + ': ' + E.Message);
          SwitchHost;
          Url := MakeUrl('/api/v1/rides');
          Body.Position := 0;
          RespStream.Clear;
          GameHttpRequest('POST', Url, Hdr, Body, 15000, 200000,
            RespStream, Status);
        end;
      end;

      if (Status = 502) or (Status = 503) or (Status = 504) then
      begin
        SwitchHost;
        Url := MakeUrl('/api/v1/rides');
        Body.Position := 0;
        RespStream.Clear;
        GameHttpRequest('POST', Url, Hdr, Body, 15000, 200000,
          RespStream, Status);
      end;
      WritelnLog('VeloSite', Format('POST /api/v1/rides → %d (%d bytes)',
        [Status, Body.Size]));

      if (Status = 401) then
      begin
        NeedRetry := True;
      end
      else if (Status >= 200) and (Status < 300) then
      begin
        RespStream.Position := 0;
        if RespStream.Size > 0 then
          Result := GetJSON(RespStream)
        else
          Result := TJSONObject.Create;
      end
      else
      begin
        raise ExtractError(Status, RespStream);
      end;
    finally
      RespStream.Free;
      Hdr.Free;
    end;
  finally
    Body.Free;
  end;

  if NeedRetry then
  begin
    if TryRefreshAccess then
      Result := DoMultipartRideUpload(AIdempotencyKey, AFitFileName, AMetaJson)
    else
    begin
      DropTokens;
      raise EVeloSiteError.Create(401, 'session_expired',
        'Refresh failed; full re-login required', nil);
    end;
  end;
end;

function TVeloSiteAPI.UploadRide(const AIdempotencyKey, AFitFileName: String;
  const AMeta: TVeloSiteRideUpload): TVeloSiteRideUploadResult;
var
  MetaObj: TJSONObject;
  MetaJson: String;
  Resp: TJSONData;
  RespObj: TJSONObject;

  procedure AddIdOrNull(const AName: String; AValue: Int64);
  begin
    if AValue > 0 then
      MetaObj.Add(AName, AValue)
    else
      MetaObj.Add(AName, TJSONNull.Create);
  end;

begin
  Result := Default(TVeloSiteRideUploadResult);

  MetaObj := TJSONObject.Create;
  try
    MetaObj.Add('source',     AMeta.Source);
    MetaObj.Add('type',       AMeta.UploadType);
    MetaObj.Add('kind',       AMeta.Kind);
    if AMeta.StartedAtUnix > 0 then
      MetaObj.Add('started_at',
        FormatDateTime('yyyy"-"mm"-"dd"T"hh":"nn":"ss"Z"',
          UnixToDateTime(AMeta.StartedAtUnix)));
    AddIdOrNull('bike_id',  AMeta.BikeId);
    AddIdOrNull('route_id', AMeta.RouteId);
    AddIdOrNull('event_id', AMeta.EventId);
    MetaJson := MetaObj.AsJSON;
  finally
    MetaObj.Free;
  end;

  Resp := DoMultipartRideUpload(AIdempotencyKey, AFitFileName, MetaJson);
  try
    if not (Resp is TJSONObject) then
      raise EVeloSiteError.Create(500, 'invalid_response',
        'UploadRide: unexpected response', nil);
    RespObj := TJSONObject(Resp);
    Result.RideId     := JsonGetInt64(RespObj, 'ride_id', 0);
    Result.Idempotent := JsonGetBool(RespObj, 'idempotent', False);
    Result.Status     := JsonGetStr(RespObj, 'status', '');
  finally
    Resp.Free;
  end;
end;

function TVeloSiteAPI.ParseRideStatus(AObj: TJSONObject): TVeloSiteRideStatus;
begin
  Result := Default(TVeloSiteRideStatus);
  Result.Id           := JsonGetInt64(AObj, 'id', 0);
  Result.Status       := JsonGetStr(AObj, 'status', '');
  Result.StartedAt    := JsonGetStr(AObj, 'started_at', '');
  Result.DurationS    := JsonGetInt64(AObj, 'duration_s', 0);
  Result.DistanceM    := JsonGetInt64(AObj, 'distance_m', 0);
  Result.AvgPowerW    := JsonGetInt64(AObj, 'avg_power_w', 0);
  Result.NpW          := JsonGetInt64(AObj, 'np_w', 0);
  Result.Tss          := JsonGetSingle(AObj, 'tss', 0);
  Result.ElevGainM    := JsonGetInt64(AObj, 'elev_gain_m', 0);
  Result.AvgHr        := JsonGetInt64(AObj, 'avg_hr', 0);
  Result.AvgCadence   := JsonGetInt64(AObj, 'avg_cadence', 0);
  Result.Kj           := JsonGetInt64(AObj, 'kj', 0);
  Result.RejectReason := JsonGetStr(AObj, 'reject_reason', '');
end;

function TVeloSiteAPI.GetRideStatus(ARideId: Int64): TVeloSiteRideStatus;
var
  Resp: TJSONData;
begin
  Resp := DoRequest('GET', '/api/v1/rides/' + IntToStr(ARideId),
    '', nil, True, True);
  try
    if not (Resp is TJSONObject) then
      raise EVeloSiteError.Create(500, 'invalid_response',
        'GetRideStatus: unexpected response', nil);
    Result := ParseRideStatus(TJSONObject(Resp));
  finally
    Resp.Free;
  end;
end;

initialization
  VeloSite := TVeloSiteAPI.Create;

finalization
  FreeAndNil(VeloSite);

end.
