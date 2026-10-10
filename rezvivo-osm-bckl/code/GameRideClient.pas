{
  GameRideClient — HTTP relay client for multiplayer ride sessions.

  Connects to the Go relay server (push/pull model).
  Background thread handles HTTP; main thread reads results.

  Usage:
    FClient := TRideRelayClient.Create;
    FClient.ServerUrl := 'https://rezvivo.com/relay';
    FClient.LocalRiderId := 1;
    FClient.LocalRiderName := 'Player';
    FClient.Start;
    ...
    // each frame:
    FClient.PushLocalState(Distance, Speed, Power, Cadence, HR);
    FClient.GetRemoteRiders(List);
    ...
    FClient.Stop;
    FClient.Free;
}
unit GameRideClient;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, SyncObjs, fpjson, jsonparser, GameHttpClient;

type
  TRiderBroadcast = record
    RiderId: Integer;
    Name: string;
    Distance: Single;    { meters along route }
    Speed: Single;       { m/s }
    Power: Integer;      { watts }
    Cadence: Integer;    { rpm }
    HeartRate: Integer;  { bpm }
    UpdatedAt: Int64;    { server timestamp ms }
  end;

  TRiderBroadcastArray = array of TRiderBroadcast;

  { Background thread that does HTTP push/pull + config exchange }
  TRelayThread = class(TThread)
  private
    FServerUrl: string;
    FLock: TCriticalSection;
    FPushData: TRiderBroadcast; { latest state; serialize only when sending }
    FPushReady: Boolean;
    FPullResult: string;     { last pull JSON result }
    FPullReady: Boolean;
    FInterval: Integer;      { ms between cycles }
    FErrorMsg: string;
    FPrivateRoom:Boolean;
    FAuthRiderId:Integer;
    FCancel:TGameHttpCancellation;
    FRefreshAt:QWord;
    { Config push — set once, thread sends it }
    FConfigPushJson: string;
    FConfigPushRiderId: Integer;
    FConfigPushPending: Boolean;
    { Config fetch — queue of rider IDs to fetch }
    FConfigFetchQueue: array of Integer;
    FConfigFetchCount: Integer;
    FConfigRetryAt:QWord;
    { Config results — rider_id → json }
    FConfigResults: array of record
      RiderId: Integer;
      Json: string;
    end;
    FConfigResultCount: Integer;
    { Guest sync — computed positions pushed back to server }
    FGuestSyncData: string;
    function Request(const Method,Path,Body:string):string;
  protected
    procedure Execute; override;
    procedure DoConfigPush;
    procedure DoConfigFetch;
    procedure DoGuestSync;
  public
    constructor Create(const AServerUrl: string; AInterval: Integer;
      APrivateRoom:Boolean=False;AAuthRiderId:Integer=0);
    destructor Destroy; override;
    procedure Cancel;

    procedure SetPushState(const State: TRiderBroadcast);
    procedure SetGuestSyncData(const AJson: string);
    function GetPullResult(out AJson: string): Boolean;
    function GetLastError: string;

    { Config — all thread-safe, non-blocking }
    procedure QueueConfigPush(ARiderId: Integer; const AJson: string);
    procedure QueueConfigFetch(ARiderId: Integer);
    function TryGetConfigResult(ARiderId: Integer; out AJson: string): Boolean;
  end;

  TRideRelayClient = class
  private
    FThread: TRelayThread;
    FServerUrl: string;
    FLocalRiderId: Integer;
    FLocalRiderName: string;
    FRemoteRiders: TRiderBroadcastArray;
    FRemoteLock: TCriticalSection;
    FStarted: Boolean;
    FPrivateRoom:Boolean;
    FAccumDistance: Single;
    FKnownRiders: array of Integer;  { rider IDs we already fetched config for }
    FHasNewData: Boolean;            { true after UpdateRemoteRiders got fresh pull }
    FOnRiderCountChanged: TNotifyEvent; { main thread, membership count only }
    function IsKnownRider(ARiderId: Integer): Boolean;
    procedure MarkRiderKnown(ARiderId: Integer);
    { ApiBotUrl превращает FServerUrl ('https://rezvivo.com/relay') в
      адрес bot-эндпоинта в API ('https://rezvivo.com/api/v1/relay/bot/...').
      Bot endpoints зарегистрированы только в API-группе под Bearer-auth;
      запрос на /relay/bot/... приведёт к HTML 404 (CSRF-страница), что
      ломает JSON-парсер. }
    function ApiBotUrl(const ABotPath: string): string;
  public
    constructor Create;
    destructor Destroy; override;

    procedure Start;
    procedure Stop;

    { Call each frame from main thread }
    procedure PushLocalState(ADistance, ASpeed: Single;
      APower, ACadence, AHeartRate: Integer);

    { Get snapshot of remote riders (thread-safe copy) }
    procedure UpdateRemoteRiders;
    function RemoteRiderCount: Integer;
    function GetRemoteRider(Index: Integer): TRiderBroadcast;
    function GetAllRemoteRiders: TRiderBroadcastArray;
    function LastError:string;

    { Bike config exchange — non-blocking, goes through relay thread }
    procedure PushBikeConfig(const ABikeJson: string);
    procedure RequestBikeConfig(ARiderId: Integer);
    function TryGetBikeConfig(ARiderId: Integer; out ABikeJson: string): Boolean;
    function IsNewRider(ARiderId: Integer): Boolean;

    { Push computed guest state back to server }
    procedure PushGuestState(ARiderId: Integer; ADistance, ASpeed: Single);
    { Push batch of all guest states as JSON array }
    procedure PushGuestStates(const ABatchJson: string);

    { ── Debug-режим: тестовые боты на сервере (включается /log флагом) ──

      Все четыре метода — синхронные блокирующие вызовы к bot-эндпоинтам
      VeloSite API. Используют Bearer-токен из VeloSite.GetAccessToken
      (на сервере зарегистрированы под /api/v1/relay/bot/* в группе
      apiAuthMW; CSRF не нужен, нужен Bearer). Раньше HTTP-логика была
      inline в gameviewplay.pas; Phase 7 интеграции с VeloSite вынесла
      её сюда, чтобы UI-слой не знал про fphttpclient. }
    function CreateBot(const AName: string; APowerW: Integer): Integer;
    procedure RemoveAllBots;
    procedure RemoveBot(ARiderId: Integer);
    procedure SetBotPower(ARiderId, APowerW: Integer);

    property ServerUrl: string read FServerUrl write FServerUrl;
    property LocalRiderId: Integer read FLocalRiderId write FLocalRiderId;
    property LocalRiderName: string read FLocalRiderName write FLocalRiderName;
    property Started: Boolean read FStarted;
    property PrivateRoom:Boolean read FPrivateRoom write FPrivateRoom;
    property AccumDistance: Single read FAccumDistance write FAccumDistance;
    property HasNewData: Boolean read FHasNewData;
    property OnRiderCountChanged: TNotifyEvent read FOnRiderCountChanged write FOnRiderCountChanged;
  end;

implementation


uses
  VeloSiteAPI, DebugLog, GameThreadWatch;

type
  TRelayResponseStream=class(TStringStream)
    function Write(const Buffer;Count:LongInt):LongInt;override;
  end;
function TRideRelayClient.LastError:string;
begin Result:='';if FThread<>nil then Result:=FThread.GetLastError;end;
function TRelayResponseStream.Write(const Buffer;Count:LongInt):LongInt;
begin
  if Position+Count>512*1024 then raise Exception.Create('Relay response exceeds size limit');
  Result:=inherited Write(Buffer,Count);
end;

function AuthHeaders: TStringList;
begin
  Result := TStringList.Create;
  Result.NameValueSeparator := ':';
  Result.Add('Authorization: Bearer ' + VeloSite.GetAccessToken);
end;

{ ═══════════════════════════════════════════════════════════════════
  TRelayThread
  ═══════════════════════════════════════════════════════════════════ }

constructor TRelayThread.Create(const AServerUrl: string; AInterval: Integer;
  APrivateRoom:Boolean;AAuthRiderId:Integer);
begin
  inherited Create(true); { create suspended }
  FreeOnTerminate := false;
  FServerUrl := AServerUrl;
  FInterval := AInterval;
  FLock := TCriticalSection.Create;
  FPrivateRoom:=APrivateRoom;FAuthRiderId:=AAuthRiderId;FCancel:=TGameHttpCancellation.Create;
  FPushData := Default(TRiderBroadcast);
  FPullResult := '';
  FPullReady := false;
  FErrorMsg := '';
  FConfigPushPending := false;
  FConfigFetchCount := 0;
  FConfigResultCount := 0;
end;

destructor TRelayThread.Destroy;
begin
  Cancel;if Suspended then Start;WaitFor;
  FCancel.Free;
  FLock.Free;
  inherited;
end;

procedure TRelayThread.Cancel;
begin Terminate;FCancel.Cancel end;

function TRelayThread.Request(const Method,Path,Body:string):string;
var H:TStringList;Input,Output:TStringStream;Status:Integer;Token:string;
begin
  FCancel.Check;H:=TStringList.Create;Input:=TStringStream.Create(Body);Output:=TRelayResponseStream.Create('');
  try
    if FPrivateRoom then begin
      Token:=VeloSite.GetAccessTokenForUser(FAuthRiderId);
      if Token=''then raise Exception.Create('Room account changed');
      H.Add('Authorization: Bearer '+Token);
    end;
    H.Add('Content-Type: application/json');
    GameHttpRequest(Method,FServerUrl+Path,H,Input,2000,3000,Output,Status,FCancel);
    if(Status<200)or(Status>=300)then begin
      if(Status=401)and FPrivateRoom and(GetTickCount64>=FRefreshAt)then begin
        FRefreshAt:=GetTickCount64+10000;VeloSite.RefreshProfileAsync;
      end;
      raise Exception.CreateFmt('Relay HTTP %d',[Status]);
    end;
    Result:=Output.DataString;
  finally Output.Free;Input.Free;H.Free end;
end;

procedure TRelayThread.SetPushState(const State: TRiderBroadcast);
begin
  FLock.Enter;
  try
    FPushData := State;
    FPushReady := True;
  finally
    FLock.Leave;
  end;
end;

function TRelayThread.GetPullResult(out AJson: string): Boolean;
begin
  FLock.Enter;
  try
    Result := FPullReady;
    if FPullReady then
    begin
      AJson := FPullResult;
      FPullReady := false;
    end;
  finally
    FLock.Leave;
  end;
end;

function TRelayThread.GetLastError: string;
begin
  FLock.Enter;
  try
    Result := FErrorMsg;
  finally
    FLock.Leave;
  end;
end;

procedure TRelayThread.QueueConfigPush(ARiderId: Integer; const AJson: string);
begin
  FLock.Enter;
  try
    FConfigPushRiderId := ARiderId;
    FConfigPushJson := AJson;
    FConfigPushPending := true;
  finally
    FLock.Leave;
  end;
end;

procedure TRelayThread.QueueConfigFetch(ARiderId: Integer);
var N, I: Integer;
    AlreadyQueued: Boolean;
begin
  FLock.Enter;
  try
    AlreadyQueued := False;
    { Don't add duplicates }
    for I := 0 to FConfigFetchCount - 1 do
      if FConfigFetchQueue[I] = ARiderId then begin AlreadyQueued := True; Break; end;
    { Also skip if already have result }
    if not AlreadyQueued then
      for I := 0 to FConfigResultCount - 1 do
        if FConfigResults[I].RiderId = ARiderId then begin AlreadyQueued := True; Break; end;
    if not AlreadyQueued then
    begin
      N := FConfigFetchCount;
      if N >= Length(FConfigFetchQueue) then
        SetLength(FConfigFetchQueue, N + 8);
      FConfigFetchQueue[N] := ARiderId;
      Inc(FConfigFetchCount);
    end;
  finally
    FLock.Leave;
  end;
end;

function TRelayThread.TryGetConfigResult(ARiderId: Integer; out AJson: string): Boolean;
var I: Integer;
begin
  Result := False;
  AJson := '';
  FLock.Enter;
  try
    for I := 0 to FConfigResultCount - 1 do
      if FConfigResults[I].RiderId = ARiderId then
      begin
        AJson := FConfigResults[I].Json;
        Result := AJson <> '';
        Exit;
      end;
  finally
    FLock.Leave;
  end;
end;

procedure TRelayThread.DoConfigPush;
var
  Envelope: TJSONObject;
  PostData: string;
  RId: Integer;
  CJson: string;
begin
  FLock.Enter;
  if not FConfigPushPending then begin FLock.Leave; Exit; end;
  RId := FConfigPushRiderId;
  CJson := FConfigPushJson;
  FConfigPushPending := false;
  FLock.Leave;

  try
    Envelope := TJSONObject.Create;
    try
      Envelope.Add('rider_id', RId);
      Envelope.Add('config', CJson);
      PostData := Envelope.AsJSON;
    finally
      Envelope.Free;
    end;

    Request('POST','/config',PostData);
    Logger.Info('[RelayThread] ' + Format('Config pushed for rider %d (%d bytes)', [RId, Length(CJson)]));
  except
    on E: Exception do
    begin
      FLock.Enter;
      try
        if not FConfigPushPending then begin
          FConfigPushPending:=True;FConfigPushJson:=CJson;FConfigPushRiderId:=RId;
        end;
      finally FLock.Leave end;
      Logger.Info('[RelayThread] ' + 'Config push failed: ' + E.Message);
    end;
  end;
end;

procedure TRelayThread.DoConfigFetch;
var
  RId: Integer;
  Raw, CJson: string;
  JData: TJSONData;
  JObj: TJSONObject;
  N: Integer;
begin
  { Take one rider ID from queue }
  if GetTickCount64<FConfigRetryAt then Exit;
  FLock.Enter;
  if FConfigFetchCount = 0 then begin FLock.Leave; Exit; end;
  RId := FConfigFetchQueue[0];
  if FConfigFetchCount > 1 then
    Move(FConfigFetchQueue[1], FConfigFetchQueue[0],
      SizeOf(Integer) * (FConfigFetchCount - 1));
  Dec(FConfigFetchCount);
  FLock.Leave;

  CJson := '';
  try
    try
      Raw := Request('GET','/config?rider_id='+IntToStr(RId),'');
    except
      on E: Exception do
      begin
        if not FPrivateRoom then Logger.Info('[RelayThread] ' + 'Config HTTP failed for rider ' +
          IntToStr(RId) + ': ' + E.Message);
        Raw := '';
        if FPrivateRoom and not Terminated then begin FConfigRetryAt:=GetTickCount64+5000;QueueConfigFetch(RId);Exit end;
      end;
    end;

    if Raw <> '' then
    begin
      try
        JData := GetJSON(Raw);
        try
          if JData is TJSONObject then
          begin
            JObj := TJSONObject(JData);
            if JObj.Find('config') <> nil then
              CJson := JObj.Get('config', '');
          end;
        finally
          JData.Free;
        end;
      except
        on E: Exception do
          Logger.Info('[RelayThread] ' + 'Config parse failed for rider ' +
            IntToStr(RId) + ': ' + E.Message);
      end;
    end;
  except
    on E: Exception do
      Logger.Info('[RelayThread] ' + 'Config fetch outer error for rider ' +
        IntToStr(RId) + ': ' + E.Message);
  end;

  { A peer can publish its bike just after joining. Retry one queued request
    per successful polling cycle instead of permanently caching absence. }
  if FPrivateRoom and(CJson='')and not Terminated then begin FConfigRetryAt:=GetTickCount64+1000;QueueConfigFetch(RId);Exit end;
  { Legacy public relay may intentionally have riders without a config. }
  FLock.Enter;
  try
    N := FConfigResultCount;
    if N >= Length(FConfigResults) then
      SetLength(FConfigResults, N + 8);
    FConfigResults[N].RiderId := RId;
    FConfigResults[N].Json := CJson;
    Inc(FConfigResultCount);
  finally
    FLock.Leave;
  end;

  if CJson <> '' then
    Logger.Info('[RelayThread] ' + Format('Config fetched for rider %d (%d bytes)', [RId, Length(CJson)]))
  else
    Logger.Info('[RelayThread] ' + 'No config available for rider ' + IntToStr(RId));
end;

procedure TRelayThread.SetGuestSyncData(const AJson: string);
begin
  FLock.Enter;
  try FGuestSyncData := AJson;
  finally FLock.Leave; end;
end;

procedure TRelayThread.DoGuestSync;
var
  Data: string;
begin
  if FPrivateRoom then Exit;
  FLock.Enter;
  Data := FGuestSyncData;
  FGuestSyncData := '';
  FLock.Leave;
  if Data = '' then Exit;

  try
    Request('POST','/guest_sync',Data);
  except
    on E: Exception do
      Logger.Info('[RelayThread] ' + 'Guest sync failed: ' + E.Message);
  end;
end;

procedure TRelayThread.Execute;
var
  PushJson, PullJson: string;
  State: TRiderBroadcast;
  Obj: TJSONObject;
  Delay,Waited:Integer;
  Connected,HasPush:Boolean;
begin
  Delay:=FInterval;
  while not Terminated do
  begin
    Connected:=False;
    try
      { 1. Push rider state }
      FLock.Enter;
      try
        HasPush := FPushReady;
        if HasPush then State := FPushData;
        FPushReady := False;
      finally FLock.Leave end;

      if HasPush then
      begin
        { Rendering can publish hundreds of states between two HTTP sends.
          Only the latest one needs a JSON tree/string, on this worker. }
        Obj := TJSONObject.Create;
        try
          Obj.Add('rider_id', State.RiderId);
          Obj.Add('name', State.Name);
          Obj.Add('distance', TJSONFloatNumber.Create(State.Distance));
          Obj.Add('speed', TJSONFloatNumber.Create(State.Speed));
          Obj.Add('power', State.Power);
          Obj.Add('cadence', State.Cadence);
          Obj.Add('hr', State.HeartRate);
          PushJson := Obj.AsJSON;
        finally Obj.Free end;
        try
          Request('POST','/push',PushJson);
          FLock.Enter;
          FErrorMsg := '';
          FLock.Leave;
        except
          on E: Exception do
          begin
            FLock.Enter;
            FErrorMsg := 'Push: ' + E.Message;
            FLock.Leave;
          end;
        end;
      end;

      { 2. Pull all riders }
      try
        PullJson := Request('GET','/pull','');Connected:=True;
        FLock.Enter;
        FPullResult := PullJson;
        FPullReady := true;
        FErrorMsg := '';
        FLock.Leave;
      except
        on E: Exception do
        begin
          FLock.Enter;
          FErrorMsg := 'Pull: ' + E.Message;
          FLock.Leave;
        end;
      end;

      { 3. Config push (if pending) }
      if Connected then DoConfigPush;

      { 4. Config fetch (one per cycle) }
      if Connected then DoConfigFetch;

      { 5. Guest sync (computed positions) }
      if Connected then DoGuestSync;
    except
      on E: Exception do
      begin
        FLock.Enter;
        FErrorMsg := 'Thread: ' + E.Message;
        FLock.Leave;
      end;
    end;

    if Connected then Delay:=FInterval else Delay:=Min(8000,Max(1000,Delay*2));
    Waited:=0;while(Waited<Delay)and not Terminated do begin Sleep(20);Inc(Waited,20)end;
  end;
end;

{ ═══════════════════════════════════════════════════════════════════
  TRideRelayClient
  ═══════════════════════════════════════════════════════════════════ }

constructor TRideRelayClient.Create;
begin
  inherited Create;
  FServerUrl := 'https://rezvivo.com/relay';
  FLocalRiderId := 1;
  FLocalRiderName := 'Rider';
  FRemoteLock := TCriticalSection.Create;
  FStarted := false;
  FAccumDistance := 0;
end;

destructor TRideRelayClient.Destroy;
begin
  Stop;
  FRemoteLock.Free;
  inherited;
end;

procedure TRideRelayClient.Start;
begin
  if FStarted then Exit;
  FThread := TRelayThread.Create(FServerUrl, 500,FPrivateRoom,FLocalRiderId); { 2 Hz }
  FThread.Start;
  FStarted := true;
end;

procedure TRideRelayClient.Stop;
var HadRiders: Boolean;
begin
  if not FStarted then Exit;
  if Assigned(FThread) then
  begin
    FThread.Cancel;
    ThreadWatch('Relay WaitFor BEGIN');
    FThread.WaitFor;
    ThreadWatch('Relay WaitFor END');
    FreeAndNil(FThread);
  end;
  FStarted := false;
  FKnownRiders:=nil;
  FRemoteLock.Enter;
  try
    HadRiders := Length(FRemoteRiders) > 0;
    FRemoteRiders := nil;
  finally FRemoteLock.Leave end;
  if HadRiders and Assigned(FOnRiderCountChanged) then FOnRiderCountChanged(Self);
end;

procedure TRideRelayClient.PushLocalState(ADistance, ASpeed: Single;
  APower, ACadence, AHeartRate: Integer);
var
  State: TRiderBroadcast;
begin
  if not FStarted then Exit;

  State := Default(TRiderBroadcast);
  State.RiderId := FLocalRiderId;
  State.Name := FLocalRiderName;
  State.Distance := ADistance;
  State.Speed := ASpeed;
  State.Power := APower;
  State.Cadence := ACadence;
  State.HeartRate := AHeartRate;
  FThread.SetPushState(State);
end;

procedure TRideRelayClient.UpdateRemoteRiders;
var
  Json: string;
  JData: TJSONData;
  JArr: TJSONArray;
  JObj: TJSONObject;
  I, Count: Integer;
  R: TRiderBroadcast;
  DistanceValue, SpeedValue: Double;
  Arr: TRiderBroadcastArray;
  CountChanged: Boolean;
begin
  FHasNewData := False;
  if not FStarted then Exit;
  if not FThread.GetPullResult(Json) then Exit;

  try
    JData := GetJSON(Json);
    try
      if not (JData is TJSONArray) then Exit;
      JArr := TJSONArray(JData);
      Count := 0;
      SetLength(Arr, JArr.Count);
      for I := 0 to JArr.Count - 1 do
      begin
        if not (JArr[I] is TJSONObject) then Continue;
        JObj := TJSONObject(JArr[I]);
        R.RiderId := JObj.Get('rider_id', 0);
        { Skip self }
        if R.RiderId = FLocalRiderId then Continue;
        R.Name := JObj.Get('name', '');
        DistanceValue := JObj.Get('distance', 0.0);
        SpeedValue := JObj.Get('speed', 0.0);
        { Validate before narrowing JSON doubles to game-world Singles. }
        if IsNan(DistanceValue) or IsInfinite(DistanceValue) or
           (Abs(DistanceValue) > MaxSingle) or
           IsNan(SpeedValue) or IsInfinite(SpeedValue) or
           (Abs(SpeedValue) > MaxSingle) then Continue;
        R.Distance := DistanceValue;
        R.Speed := SpeedValue;
        R.Power := JObj.Get('power', 0);
        R.Cadence := JObj.Get('cadence', 0);
        R.HeartRate := JObj.Get('hr', 0);
        R.UpdatedAt := JObj.Get('updated_at', Int64(0));
        Arr[Count] := R;
        Inc(Count);
      end;
      SetLength(Arr, Count);
    finally
      JData.Free;
    end;

    FRemoteLock.Enter;
    try
      CountChanged := Length(FRemoteRiders) <> Length(Arr);
      FRemoteRiders := Arr;
    finally
      FRemoteLock.Leave;
    end;
    { A malformed response must not refresh old peer positions/timestamps. }
    FHasNewData := True;
    if CountChanged and Assigned(FOnRiderCountChanged) then FOnRiderCountChanged(Self);
  except
    { ignore parse errors }
  end;
end;

function TRideRelayClient.RemoteRiderCount: Integer;
begin
  FRemoteLock.Enter;
  try
    Result := Length(FRemoteRiders);
  finally
    FRemoteLock.Leave;
  end;
end;

function TRideRelayClient.GetRemoteRider(Index: Integer): TRiderBroadcast;
begin
  FRemoteLock.Enter;
  try
    if (Index >= 0) and (Index < Length(FRemoteRiders)) then
      Result := FRemoteRiders[Index]
    else
      FillChar(Result, SizeOf(Result), 0);
  finally
    FRemoteLock.Leave;
  end;
end;

function TRideRelayClient.GetAllRemoteRiders: TRiderBroadcastArray;
begin
  FRemoteLock.Enter;
  try
    Result := Copy(FRemoteRiders);
  finally
    FRemoteLock.Leave;
  end;
end;

{ ═══════════════════════════════════════════════════════════════════
  Known rider tracking
  ═══════════════════════════════════════════════════════════════════ }

function TRideRelayClient.IsKnownRider(ARiderId: Integer): Boolean;
var I: Integer;
begin
  for I := 0 to High(FKnownRiders) do
    if FKnownRiders[I] = ARiderId then Exit(True);
  Result := False;
end;

procedure TRideRelayClient.MarkRiderKnown(ARiderId: Integer);
var N: Integer;
begin
  if IsKnownRider(ARiderId) then Exit;
  N := Length(FKnownRiders);
  SetLength(FKnownRiders, N + 1);
  FKnownRiders[N] := ARiderId;
end;

function TRideRelayClient.ApiBotUrl(const ABotPath: string): string;
var
  Base, RelaySuffix: string;
  P: Integer;
begin
  { FServerUrl ожидается вида 'https://rezvivo.com/relay'. Отрезаем
    хвост '/relay' и подставляем '/api/v1/relay/bot/...'. Если хвост
    другой (тест/dev) — fallback на конкатенацию. }
  Base := FServerUrl;
  RelaySuffix := '/relay';
  P := Length(Base) - Length(RelaySuffix) + 1;
  if (P > 0) and (Copy(Base, P, Length(RelaySuffix)) = RelaySuffix) then
    Base := Copy(Base, 1, P - 1);
  Result := Base + '/api/v1/relay/bot/' + ABotPath;
end;

function TRideRelayClient.IsNewRider(ARiderId: Integer): Boolean;
begin
  Result := not IsKnownRider(ARiderId);
end;

{ ═══════════════════════════════════════════════════════════════════
  Bike config exchange — non-blocking, delegates to relay thread
  ═══════════════════════════════════════════════════════════════════ }

procedure TRideRelayClient.PushBikeConfig(const ABikeJson: string);
begin
  if not FStarted then Exit;
  Logger.Info('[RelayConfig] ' + Format('PushBikeConfig queued: rider_id=%d, json length=%d',
    [FLocalRiderId, Length(ABikeJson)]));
  FThread.QueueConfigPush(FLocalRiderId, ABikeJson);
end;

procedure TRideRelayClient.RequestBikeConfig(ARiderId: Integer);
begin
  if not FStarted then Exit;
  if IsKnownRider(ARiderId) then Exit;
  Logger.Info('[RelayConfig] ' + 'RequestBikeConfig queued: rider_id=' + IntToStr(ARiderId));
  FThread.QueueConfigFetch(ARiderId);
end;

function TRideRelayClient.TryGetBikeConfig(ARiderId: Integer;
  out ABikeJson: string): Boolean;
begin
  Result := False;
  ABikeJson := '';
  if not FStarted then Exit;
  Result := FThread.TryGetConfigResult(ARiderId, ABikeJson);
  if Result then
  begin
    MarkRiderKnown(ARiderId);
    Logger.Info('[RelayConfig] ' + Format('Config received for rider %d (%d bytes)',
      [ARiderId, Length(ABikeJson)]));
  end;
end;

{ ═══════════════════════════════════════════════════════════════════
  Guest state sync — push computed distance/speed back to server
  Accepts a pre-built JSON array string with all riders.
  ═══════════════════════════════════════════════════════════════════ }

procedure TRideRelayClient.PushGuestState(ARiderId: Integer;
  ADistance, ASpeed: Single);
begin
  { Single-rider convenience — not used in batch mode }
end;

procedure TRideRelayClient.PushGuestStates(const ABatchJson: string);
begin
  if not FStarted or FPrivateRoom then Exit;
  if ABatchJson = '' then Exit;
  FThread.SetGuestSyncData(ABatchJson);
end;

{ ═══════════════════════════════════════════════════════════════════
  Debug-боты на сервере. Все вызовы блокирующие, рассчитанные на
  редкое использование (только из debug-панели в gameviewplay,
  показанной с /log флагом). Тяжёлые ретраи / error UI не нужны —
  просто пишем в лог.
  ═══════════════════════════════════════════════════════════════════ }

function TRideRelayClient.CreateBot(const AName: string;
  APowerW: Integer): Integer;
var
  ReqJson: TJSONObject;
  ReqStr, RespStr: string;
  Hdr: TStringList;
  RespJson: TJSONData;
  RespObj: TJSONObject;
begin
  Result := 0;
  if FServerUrl = '' then Exit;

  Hdr := AuthHeaders;
  try
    ReqJson := TJSONObject.Create;
    try
      ReqJson.Add('name', AName);
      ReqJson.Add('power', APowerW);
      ReqStr := ReqJson.AsJSON;
    finally
      ReqJson.Free;
    end;
    RespStr := GameHttpPost(ApiBotUrl('create'), 'application/json', ReqStr,
      Hdr, 5000, 10000);
    if RespStr <> '' then
    begin
      RespJson := GetJSON(RespStr);
      try
        if RespJson is TJSONObject then
        begin
          RespObj := TJSONObject(RespJson);
          Result := RespObj.Get('rider_id', 0);
        end;
      finally
        RespJson.Free;
      end;
    end;
  except
    on E: Exception do
      Logger.Info('[Bot] ' + 'CreateBot failed: ' + E.Message);
  end;
  Hdr.Free;
end;

procedure TRideRelayClient.RemoveAllBots;
var
  Hdr: TStringList;
begin
  if FServerUrl = '' then Exit;
  Hdr := AuthHeaders;
  try
    GameHttpPost(ApiBotUrl('remove_all'), 'application/json', '{}', Hdr, 5000, 10000);
  except
    on E: Exception do
      Logger.Info('[Bot] ' + 'RemoveAllBots failed: ' + E.Message);
  end;
  Hdr.Free;
end;

procedure TRideRelayClient.RemoveBot(ARiderId: Integer);
var
  ReqJson: TJSONObject;
  ReqStr: string;
  Hdr: TStringList;
begin
  if FServerUrl = '' then Exit;
  Hdr := AuthHeaders;
  try
    ReqJson := TJSONObject.Create;
    try
      ReqJson.Add('rider_id', ARiderId);
      ReqStr := ReqJson.AsJSON;
    finally
      ReqJson.Free;
    end;
    GameHttpPost(ApiBotUrl('remove'), 'application/json', ReqStr, Hdr, 5000, 10000);
  except
    on E: Exception do
      Logger.Info('[Bot] ' + 'RemoveBot failed: ' + E.Message);
  end;
  Hdr.Free;
end;

procedure TRideRelayClient.SetBotPower(ARiderId, APowerW: Integer);
var
  ReqJson: TJSONObject;
  ReqStr: string;
  Hdr: TStringList;
begin
  if FServerUrl = '' then Exit;
  Hdr := AuthHeaders;
  try
    ReqJson := TJSONObject.Create;
    try
      ReqJson.Add('rider_id', ARiderId);
      ReqJson.Add('power', APowerW);
      ReqStr := ReqJson.AsJSON;
    finally
      ReqJson.Free;
    end;
    GameHttpPost(ApiBotUrl('power'), 'application/json', ReqStr, Hdr, 5000, 10000);
  except
    on E: Exception do
      Logger.Info('[Bot] ' + 'SetBotPower failed: ' + E.Message);
  end;
  Hdr.Free;
end;

end.
