{ RideUploadQueue — фоновая очередь загрузки заездов на VeloSite.

  Пайплайн (полностью офлайн-first):
    1. На запуске + по требованию сканит TSensorLog.SessionDir на
       session_*.csv. Каждый найденный CSV считается ожидающим
       загрузки. Сессии без CSV (только с .fit рядом) — уже загружены,
       в очередь не попадают.
    2. В фоновом потоке берёт первый ожидающий CSV, делает
       TSensorLog.LoadSession + TFitFileWriter.SaveToFile в соседний
       <name>.fit, выводит TVeloSiteRideUpload и POST через
       VeloSite.UploadRide.
    3. Idempotency-Key — детерминированный UUIDv5-подобный хеш от
       имени файла. Это значит: сервер вернёт уже существующий
       ride_id если CSV грузится повторно.
    4. После успешной загрузки CSV удаляется, FIT остаётся как
       локальная копия. При следующем Scan'е этот CSV уже не
       найдётся → сессия не попадёт в очередь повторно.
    5. Стратегия retry — встроена в VeloSiteAPI (401-refresh) +
       exponential backoff поверх для 5xx/сетевых сбоев. CSV до
       успеха остаётся на диске.

  RideUploadQueue.Scan можно дёргать сколько угодно — поток сам
  следит, чтобы не запустить загрузку дважды.

  Использование:
    UploadQueue.Scan;                 // запускает фоновую обработку
    if UploadQueue.PendingCount > 0 then ...

  Singleton создаётся в initialization. На выходе ждёт окончания
  текущей загрузки, чтобы не оборвать недозагруженный заезд. }
unit RideUploadQueue;

{$mode objfpc}{$H+}
{$codepage UTF8}

interface

uses
  Classes, SysUtils, SyncObjs;

type
  TUploadStatus = (usPending, usUploading, usDone, usFailedQuota,
                   usFailedClient, usFailedServer);

  TQueueItem = record
    CsvPath:   String;
    FitPath:   String;     { соседний *.fit, остаётся после загрузки }
    IdemKey:   String;
    Status:    TUploadStatus;
    LastError: String;
    NextTryAt: TDateTime;  { exponential backoff для 5xx }
    Attempts:  Integer;
  end;
  TQueueItemArray = array of TQueueItem;

  TRideUploadThread = class(TThread)
  private
    FLock:        TCriticalSection;
    FItems:       TQueueItemArray;
    FRunning:     Boolean;
    FShutdown:    Boolean;
    FWakeEvent:   TEvent;          { пинок «есть работа» }

    procedure UploadOne(var AItem: TQueueItem);
    function  PickNextPending(out AItem: TQueueItem): Boolean;
    procedure SetItemStatus(const ACsvPath: String; AStatus: TUploadStatus;
      const AError: String);
  protected
    procedure Execute; override;
  public
    constructor Create;
    destructor  Destroy; override;

    procedure RequestShutdown;
    procedure Wake;
    procedure ReplaceItems(const ANewItems: TQueueItemArray);
    function  Snapshot: TQueueItemArray;
  end;

  TRideUploadQueue = class
  private
    FThread: TRideUploadThread;
    function ComputeIdempotencyKey(const ACsvPath: String): String;
  public
    constructor Create;
    destructor  Destroy; override;

    { Перечитать sessions/, обновить очередь, разбудить поток. Вызывать
      на старте приложения и после ViewPlay.Stop. }
    procedure Scan;

    { Сколько заездов ожидает загрузки (включая ретраи). Для UI-индикатора. }
    function PendingCount: Integer;

    { Есть ли последняя ошибка — для красной иконки. }
    function HasErrors: Boolean;

    { Снимок текущих элементов очереди для UI (например, для
      detail-экрана «синхронизация»). }
    function Snapshot: TQueueItemArray;
  end;

var
  UploadQueue: TRideUploadQueue;

implementation


uses
  Generics.Collections, md5, GameSensorLog, FitFile, VeloSiteAPI, DebugLog, GameThreadWatch,GameUserData;

const
  UPLOAD_NAMESPACE = 'velosite.ride.v1:';

function JournalMayUpload(const CsvPath:String):Boolean;
var Owner:TStringList;
begin
  Result:=False;
  if FileExists(CsvPath+'.active')then Exit;
  if not FileExists(CsvPath+'.owner')then Exit(True);
  Owner:=TStringList.Create;
  try
    try
      Owner.LoadFromFile(CsvPath+'.owner');
      Result:=ExcludeTrailingPathDelimiter(Trim(Owner.Text))=
        ExcludeTrailingPathDelimiter(UserDataDir);
    except Result:=False;end;
  finally Owner.Free;end;
end;

{ ══════════════════════════════════════════════════════════════════
  Локальные хелперы
  ══════════════════════════════════════════════════════════════════ }

function FormatUuidLikeFromMd5(const AMd5Hex: String): String;
begin
  { Берём 32 hex и форматируем как UUID 8-4-4-4-12. Это не настоящий
    UUIDv5 (нет SHA1 + namespace правильного), но детерминированно
    выводится из имени файла, что нам и нужно для идемпотентности. }
  if Length(AMd5Hex) < 32 then
  begin
    Result := AMd5Hex;
    Exit;
  end;
  Result := Copy(AMd5Hex, 1, 8) + '-' +
            Copy(AMd5Hex, 9, 4) + '-' +
            Copy(AMd5Hex, 13, 4) + '-' +
            Copy(AMd5Hex, 17, 4) + '-' +
            Copy(AMd5Hex, 21, 12);
end;

function BackoffDelaySec(AAttempts: Integer): Integer;
begin
  case AAttempts of
    0: Result := 5;
    1: Result := 15;
    2: Result := 45;
    3: Result := 120;
  else
    Result := 300;
  end;
end;

{ ══════════════════════════════════════════════════════════════════
  TRideUploadThread
  ══════════════════════════════════════════════════════════════════ }

constructor TRideUploadThread.Create;
begin
  inherited Create(False);     { стартуем сразу }
  FreeOnTerminate := False;
  FLock := TCriticalSection.Create;
  FWakeEvent := TEvent.Create(nil, False, False, '');
  FShutdown := False;
end;

destructor TRideUploadThread.Destroy;
begin
  FLock.Free;
  FWakeEvent.Free;
  inherited;
end;

procedure TRideUploadThread.RequestShutdown;
begin
  FLock.Enter;
  try
    FShutdown := True;
  finally
    FLock.Leave;
  end;
  FWakeEvent.SetEvent;
end;

procedure TRideUploadThread.Wake;
begin
  FWakeEvent.SetEvent;
end;

procedure TRideUploadThread.ReplaceItems(const ANewItems: TQueueItemArray);
var
  I, J: Integer;
  Merged: TQueueItemArray;
  ByPath: specialize TDictionary<String, Integer>;
begin
  Merged := Copy(ANewItems);
  ByPath := specialize TDictionary<String, Integer>.Create;
  try
    FLock.Enter;
    try
      for I := 0 to High(FItems) do
        ByPath.AddOrSetValue(FItems[I].CsvPath, I);
      for I := 0 to High(Merged) do
        if ByPath.TryGetValue(Merged[I].CsvPath, J) then
        begin
          Merged[I].Status := FItems[J].Status;
          Merged[I].LastError := FItems[J].LastError;
          Merged[I].Attempts := FItems[J].Attempts;
          Merged[I].NextTryAt := FItems[J].NextTryAt;
        end;
      FItems := Merged;
    finally
      FLock.Leave;
    end;
  finally
    ByPath.Free;
  end;
end;

function TRideUploadThread.Snapshot: TQueueItemArray;
var
  I: Integer;
begin
  Result := nil;
  FLock.Enter;
  try
    SetLength(Result, Length(FItems));
    for I := 0 to High(FItems) do
      Result[I] := FItems[I];
  finally
    FLock.Leave;
  end;
end;

function TRideUploadThread.PickNextPending(out AItem: TQueueItem): Boolean;
var
  I: Integer;
  N: TDateTime;
begin
  Result := False;
  AItem := Default(TQueueItem);

  { Когда пользователь не авторизован — очередь спит. Иначе мы
    бы дёргали сервер, получали 401, бесполезно прожигали retry-
    счётчик и засыпали отладчик breakpoint'ами на raise.
    После Login очередь сама подхватит работу через Wake. }
  if not VeloSite.IsAuthorized then Exit;

  N := Now;
  FLock.Enter;
  try
    for I := 0 to High(FItems) do
    begin
      if not JournalMayUpload(FItems[I].CsvPath)then Continue;
      if FItems[I].Status = usPending then
      begin
        if (FItems[I].NextTryAt = 0) or (FItems[I].NextTryAt <= N) then
        begin
          FItems[I].Status := usUploading;
          AItem := FItems[I];
          Result := True;
          Exit;
        end;
      end
      else if FItems[I].Status in [usFailedServer] then
      begin
        if FItems[I].NextTryAt <= N then
        begin
          FItems[I].Status := usUploading;
          AItem := FItems[I];
          Result := True;
          Exit;
        end;
      end;
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TRideUploadThread.SetItemStatus(const ACsvPath: String;
  AStatus: TUploadStatus; const AError: String);
var
  AIdx, I: Integer;
begin
  FLock.Enter;
  try
    AIdx := -1;
    for I := 0 to High(FItems) do
      if FItems[I].CsvPath = ACsvPath then
      begin AIdx := I; Break; end;
    if AIdx < 0 then Exit;
    FItems[AIdx].Status := AStatus;
    FItems[AIdx].LastError := AError;
    if AStatus = usFailedServer then
    begin
      Inc(FItems[AIdx].Attempts);
      FItems[AIdx].NextTryAt := Now +
        (BackoffDelaySec(FItems[AIdx].Attempts) / 86400.0);
      { Возвращаем в pending для следующего цикла. }
      FItems[AIdx].Status := usPending;
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TRideUploadThread.UploadOne(var AItem: TQueueItem);
var
  Records: TSensorSessionRecordArray;
  Writer: TFitFileWriter;
  Meta: TVeloSiteRideUpload;
  Result: TVeloSiteRideUploadResult;
begin
  if not VeloSite.IsAuthorized or not JournalMayUpload(AItem.CsvPath)then
  begin AItem.Status:=usPending;Exit;end;
  Logger.Info('[UploadQueue] ' + 'Processing ' + AItem.CsvPath);

  { Читаем CSV → массив записей. }
  Records := TSensorLog.LoadSession(AItem.CsvPath);
  if Length(Records) = 0 then
  begin
    AItem.LastError := 'empty or unreadable CSV';
    AItem.Status := usFailedClient;
    Exit;
  end;

  { CSV → FIT во временный файл. }
  Writer := TFitFileWriter.Create;
  try
    if not Writer.SaveToFile(Records, AItem.FitPath) then
    begin
      AItem.LastError := 'FIT writer failed';
      AItem.Status := usFailedClient;
      Exit;
    end;
  finally
    Writer.Free;
  end;

  { Метаданные. Bike/route/event пока nil — Phase 5 пробросит event_id
    через расширение TQueueItem (не часть Phase 4). }
  Meta := Default(TVeloSiteRideUpload);
  Meta.Source        := 'game';
  Meta.UploadType    := 'free';
  Meta.Kind          := 'fit';
  Meta.StartedAtUnix := Records[0].TimestampUtcUnix;

  try
    { The profile may change while the CSV is converted. }
    if not VeloSite.IsAuthorized or not JournalMayUpload(AItem.CsvPath)then
    begin AItem.Status:=usPending;Exit;end;
    Result := VeloSite.UploadRide(AItem.IdemKey, AItem.FitPath, Meta);

    { Успех: удаляем CSV, оставляем рядом FIT. Для следующего
      Scan'а это значит «уже загружено» — pending выбираются только
      по наличию CSV. Маркер-файл *.uploaded больше не используется. }
    if FileExists(AItem.CsvPath) then DeleteFile(AItem.CsvPath);

    AItem.Status := usDone;
    Logger.Info('[UploadQueue] ' + Format('Uploaded %s → ride_id=%d (%s)',
      [ExtractFileName(AItem.CsvPath), Result.RideId, Result.Status]));
  except
    on E: EVeloSiteError do
    begin
      AItem.LastError := Format('%d %s: %s',
        [E.HttpStatus, E.ErrorCode, E.Message]);
      case E.HttpStatus of
        403:
          if E.ErrorCode = 'daily ride limit reached' then
            AItem.Status := usFailedQuota
          else
            AItem.Status := usFailedClient;
        400, 404, 410, 413, 422:
          { 400 'storage is not configured' — серверная проблема (S3 не
            настроен), не клиентская. Это временно: когда админ настроит
            S3, заезды должны автоматически дозалиться. Поэтому
            оставляем Pending с server-backoff, а не FailedClient. }
          if Pos('storage is not configured', AItem.LastError) > 0 then
            AItem.Status := usFailedServer
          else
            AItem.Status := usFailedClient;
        401:
          { Сессия истекла. Не помечаем как FailedClient (это финальное
            состояние и заезд бы не залился даже после re-login).
            Оставляем Pending — после успешного входа и Wake очередь
            подхватит. PickNextPending всё равно не возьмёт его, пока
            VeloSite.IsAuthorized=False. }
          AItem.Status := usPending;
        500, 502, 503, 0:
          AItem.Status := usFailedServer;
      else
        AItem.Status := usFailedServer;
      end;
    end;
    on E: Exception do
    begin
      AItem.LastError := E.Message;
      AItem.Status := usFailedServer;     { network → ретраим }
    end;
  end;
end;

procedure TRideUploadThread.Execute;
var
  Item: TQueueItem;
begin
  FRunning := True;
  while not FShutdown do
  begin
    if PickNextPending(Item) then
    begin
      UploadOne(Item);
      { Scan may have reordered or removed entries during HTTP. Complete
        the captured file identity, never the previous array position. }
      SetItemStatus(Item.CsvPath, Item.Status, Item.LastError);
    end
    else
    begin
      { Нет работы — ждём пинка от Scan или короткого таймаута для
        проверки backoff'нутых элементов. }
      FWakeEvent.WaitFor(5000);
    end;
  end;
  FRunning := False;
end;

{ ══════════════════════════════════════════════════════════════════
  TRideUploadQueue
  ══════════════════════════════════════════════════════════════════ }

constructor TRideUploadQueue.Create;
begin
  inherited Create;
  FThread := TRideUploadThread.Create;
end;

destructor TRideUploadQueue.Destroy;
begin
  if Assigned(FThread) then
  begin
    FThread.RequestShutdown;
    ThreadWatch('RideUpload WaitFor BEGIN');
    FThread.WaitFor;
    ThreadWatch('RideUpload WaitFor END');
    FThread.Free;
  end;
  inherited;
end;

function TRideUploadQueue.ComputeIdempotencyKey(
  const ACsvPath: String): String;
var
  Source: String;
  Hex: String;
begin
  { Используем имя файла без расширения (чтобы переименование папки
    sessions/ не сбило ключ) + namespace. На MD5 этого хватит для
    дедупа в пределах одного юзера; UUID-формат сделаем для совместимости
    с серверной валидацией Idempotency-Key. }
  Source := UPLOAD_NAMESPACE + ChangeFileExt(ExtractFileName(ACsvPath), '');
  Hex := MD5Print(MD5String(Source));
  Result := FormatUuidLikeFromMd5(LowerCase(Hex));
end;

procedure TRideUploadQueue.Scan;
var
  Dir: String;
  SR: TSearchRec;
  CsvPath: String;
  Items: TQueueItemArray;
  Item: TQueueItem;
  I: Integer;
begin
  Dir := IncludeTrailingPathDelimiter(TSensorLog.SessionDir);
  if (GetEnvironmentVariable('REZVIVO_TEST_AUTH_FILE')<>'') and
     (GetEnvironmentVariable('REZVIVO_TEST_NO_UPLOAD')='1') then Exit;
  if not DirectoryExists(Dir) then Exit;

  Items := nil;
  { Сканируем только CSV-файлы. После успешной загрузки CSV удаляется
    и остаётся только .fit — такие сессии в очередь не попадают,
    потому что мы их уже загрузили. }
  if FindFirst(Dir + 'session_*.csv', faAnyFile, SR) = 0 then
  begin
    repeat
      if (SR.Attr and faDirectory) <> 0 then Continue;
      CsvPath := Dir + SR.Name;
      { A crashed ride remains resumable until its owner explicitly finishes it. }
      if not JournalMayUpload(CsvPath)then Continue;

      Item := Default(TQueueItem);
      Item.CsvPath := CsvPath;
      Item.FitPath := ChangeFileExt(CsvPath, '.fit');
      Item.IdemKey := ComputeIdempotencyKey(CsvPath);
      Item.Status  := usPending;

      I := Length(Items);
      SetLength(Items, I + 1);
      Items[I] := Item;
    until FindNext(SR) <> 0;
    SysUtils.FindClose(SR);
  end;

  FThread.ReplaceItems(Items);
  FThread.Wake;
  Logger.Info('[UploadQueue] ' + Format('Scan: %d sessions, %d pending',
    [Length(Items), PendingCount]));
end;

function TRideUploadQueue.PendingCount: Integer;
var
  Snap: TQueueItemArray;
  I: Integer;
begin
  Result := 0;
  Snap := FThread.Snapshot;
  for I := 0 to High(Snap) do
    if Snap[I].Status in [usPending, usUploading] then
      Inc(Result);
end;

function TRideUploadQueue.HasErrors: Boolean;
var
  Snap: TQueueItemArray;
  I: Integer;
begin
  Result := False;
  Snap := FThread.Snapshot;
  for I := 0 to High(Snap) do
    if Snap[I].Status in [usFailedClient, usFailedQuota] then
      Exit(True);
end;

function TRideUploadQueue.Snapshot: TQueueItemArray;
begin
  Result := FThread.Snapshot;
end;

initialization
  UploadQueue := TRideUploadQueue.Create;

finalization
  FreeAndNil(UploadQueue);

end.
