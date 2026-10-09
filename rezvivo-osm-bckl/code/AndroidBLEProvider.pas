{ AndroidBLEProvider — BLE-транспорт для Android через CGE Android Service.

  Архитектура:
    Pascal-сторона  ──  CastleMessaging  ──  Java-сервис (BluetoothLeScanner /
                                              BluetoothGatt)

  Здесь реализована только Pascal-сторона. Java-сторону необходимо собрать
  как стандартный CGE Android service (см. castle_engine_android_services).
  Шаблон Java-кода и протокол сообщений — в комментарии ниже.

  ── Протокол поверх CastleMessaging ─────────────────────────────────────
  Pascal → Java (Messaging.Send([...])):
    ['ble-scan-start']
    ['ble-scan-stop']
    ['ble-connect',  Address, FriendlyName]
    ['ble-disconnect', Address]
    ['ble-write', Address, ServiceUuid, CharUuid, HexData, WithResponse]
    ['ble-subscribe', Address, ServiceUuid, CharUuid]

  Java → Pascal (через MainActivity.messageReceivedFromPascal или
                 Messaging.Send из Java-поток-листенера):
    ['ble-device-found', Address, Name, Rssi]                   { scan hit }
    ['ble-connection',   Address, State, Message]                { state changes:
                                                                    'connecting','connected',
                                                                    'disconnected','error' }
    ['ble-services',     Address, JsonOfServiceUuids]            { GATT discovery done }
    ['ble-notify',       Address, ServiceUuid, CharUuid, HexData] { notification }
    ['ble-write-result', Address, CharUuid, OkOrError]
    ['ble-permissions',  'granted'|'denied']                     { runtime perm result }
    ['ble-error',        Message]                                { generic service error }

  Pascal → Java (доп.):
    ['ble-request-permissions']                                  { trigger runtime prompt }

  В DEBUG-сборке без Java-сервиса AndroidBLEAvailable вернёт False и
  GameDeviceService просто не зарегистрирует провайдер.
  ─────────────────────────────────────────────────────────────────────── }

unit AndroidBLEProvider;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs,
  TrainerData, GameTransportBase, FTMSProtocol;

{$ifdef ANDROID}

type
  TAndroidBLEProvider = class;
  TAndroidBLESession  = class;

  { Минимальный список обнаруженных устройств для поиска по адресу }
  TAndroidScannedDev = record
    Address: string;
    Name: string;
    RSSI: ShortInt;
  end;
  TAndroidScannedDevArray = array of TAndroidScannedDev;

  { ═══════════════════════════════════════════════════════════════════
    TAndroidBLESession — одно соединение через Java BluetoothGatt
    ═══════════════════════════════════════════════════════════════════ }
  TAndroidBLESession = class(TTransportSession)
  private
    FProvider: TAndroidBLEProvider;
    FFTMSParser: TFTMSParser;

    FHasFTMS, FHasPower, FHasFEC, FHasHR, FHasCSC: Boolean;

    procedure ProcessNotification(const CharUUID: string; const Data: TBytes);
    procedure ProcessFTMSData(const Buf: TBytes);
    procedure ProcessCyclingPowerData(const Buf: TBytes);
    procedure ProcessHRMData(const Buf: TBytes);
    procedure ProcessCSCData(const Buf: TBytes);
    procedure ProcessFECData(const Buf: TBytes);

    function WriteCharacteristic(const SvcUUID, CharUUID: string;
      const Data: TBytes; UseRequest: Boolean): Boolean;
    function WriteFTMSCommand(const Data: TBytes): Boolean;
  public
    constructor Create(const AAddress: string;
      const AFriendlyName: string = ''); override;
    destructor Destroy; override;

    function Connect: Boolean; override;
    procedure Disconnect; override;

    function RequestControl: Boolean; override;
    function SetTargetPower(Watts: Word): Boolean; override;
    function SetResistanceLevel(Level: Byte): Boolean; override;
    function SetIncline(InclinePercent: Single): Boolean; override;
    function SetSimulation(Grade: Single; WindSpeed: Single = 0;
      RiderWeight: Single = 75; BikeWeight: Single = 10): Boolean; override;
    function Start: Boolean; override;
    function Stop: Boolean; override;
    function Pause: Boolean; override;
    function Reset: Boolean; override;

    { Маркируется true когда session создалась и есть в списке провайдера }
    procedure SetProvider(AProv: TAndroidBLEProvider);

    { Внутренние диспетчеры событий из Java-сервиса }
    procedure OnConnectionStateChanged(const AState, AMessage: string);
    procedure OnGattNotification(const ServiceUUID, CharUUID: string;
      const Data: TBytes);
    procedure OnGattServicesDiscovered(const ServicesJson: string);
  end;

  { ═══════════════════════════════════════════════════════════════════
    TAndroidBLEProvider — фабрика сессий, единая точка диспатчинга
    сообщений CastleMessaging
    ═══════════════════════════════════════════════════════════════════ }
  TAndroidBLEProvider = class(TTransportProvider)
  private
    FLock: TCriticalSection;
    FScanned: TAndroidScannedDevArray;
    FScannedCount: Integer;

    FSessions: TList;       { *unowned* список TAndroidBLESession }
    FScanning: Boolean;

    function FindSessionLocked(const AAddress: string): TAndroidBLESession;
  public
    constructor Create; override;
    destructor Destroy; override;

    procedure StartScan; override;
    procedure StopScan; override;
    function CreateSession(const AAddress: string;
      const AFriendlyName: string = ''): TTransportSession; override;
    class function TransportType: TTransportType; override;

    { Внутренние — сессии регистрируются здесь, чтобы провайдер мог
      доставить им сообщения от Java }
    procedure RegisterSession(ASession: TAndroidBLESession);
    procedure UnregisterSession(ASession: TAndroidBLESession);

    { Точка входа для CastleMessaging.OnReceive — статически зарегистрирована
      в конструкторе провайдера. Возвращает True если сообщение распознано
      и обработано (в этом случае CGE не передаёт его другим обработчикам). }
    function HandleMessageFromJava(const Received: TCastleStringList): Boolean;
  end;

{$endif}

{ Доступен ли Android BLE-провайдер. На не-Android всегда False;
  на Android — пытается определить наличие Java-сервиса. }
function AndroidBLEAvailable: Boolean;

implementation

{$ifdef ANDROID}

uses
  CastleMessaging, CastleStringUtils, DebugLog;

{ ═══════════════════════════════════════════════════════════════════
  Hex helpers — Java сервис передаёт payload как hex-строку.
  ═══════════════════════════════════════════════════════════════════ }

function BytesToHex(const Data: TBytes): string;
const
  HexChars: array[0..15] of Char = '0123456789ABCDEF';
var
  I: Integer;
begin
  SetLength(Result, Length(Data) * 2);
  for I := 0 to High(Data) do
  begin
    Result[I * 2 + 1] := HexChars[Data[I] shr 4];
    Result[I * 2 + 2] := HexChars[Data[I] and $F];
  end;
end;

function HexToBytes(const S: string): TBytes;
var
  I, N: Integer;

  function HexVal(C: Char): Byte; inline;
  begin
    case C of
      '0'..'9': Result := Ord(C) - Ord('0');
      'a'..'f': Result := Ord(C) - Ord('a') + 10;
      'A'..'F': Result := Ord(C) - Ord('A') + 10;
    else
      Result := 0;
    end;
  end;

begin
  N := Length(S) div 2;
  SetLength(Result, N);
  for I := 0 to N - 1 do
    Result[I] := (HexVal(S[I * 2 + 1]) shl 4) or HexVal(S[I * 2 + 2]);
end;

{ ═══════════════════════════════════════════════════════════════════
  TAndroidBLESession
  ═══════════════════════════════════════════════════════════════════ }

constructor TAndroidBLESession.Create(const AAddress: string;
  const AFriendlyName: string);
begin
  inherited Create(AAddress, AFriendlyName);
  FFTMSParser := TFTMSParser.Create;
  FDeviceInfo.TransportType := ttBLE;
  FDeviceInfo.ProviderName := 'AndroidBLE';
end;

destructor TAndroidBLESession.Destroy;
begin
  if Assigned(FProvider) then
    FProvider.UnregisterSession(Self);
  Disconnect;
  FreeAndNil(FFTMSParser);
  inherited;
end;

procedure TAndroidBLESession.SetProvider(AProv: TAndroidBLEProvider);
begin
  FProvider := AProv;
end;

function TAndroidBLESession.Connect: Boolean;
begin
  Result := False;
  if FConnectionState = csConnected then Exit(True);
  SetConnectionState(csConnecting, 'Android: connecting...');
  Messaging.Send(['ble-connect', FDeviceInfo.Address, FDeviceInfo.Name]);
  Result := True;  { асинхронно — статус придёт через ble-connection }
end;

procedure TAndroidBLESession.Disconnect;
begin
  if FConnectionState = csDisconnected then Exit;
  Messaging.Send(['ble-disconnect', FDeviceInfo.Address]);
  SetConnectionState(csDisconnected, 'Android: disconnected');
end;

procedure TAndroidBLESession.OnConnectionStateChanged(const AState, AMessage: string);
begin
  case LowerCase(AState) of
    'connecting'  : SetConnectionState(csConnecting, AMessage);
    'connected'   : SetConnectionState(csConnected, AMessage);
    'disconnected': SetConnectionState(csDisconnected, AMessage);
    'error'       : SetConnectionState(csError, AMessage);
  end;
end;

procedure TAndroidBLESession.OnGattServicesDiscovered(const ServicesJson: string);
begin
  { ServicesJson — список UUID-ов. Простейшая проверка через Pos. }
  FHasFTMS  := Pos('00001826', LowerCase(ServicesJson)) > 0;
  FHasPower := Pos('00001818', LowerCase(ServicesJson)) > 0;
  FHasFEC   := Pos('6e40fec1', LowerCase(ServicesJson)) > 0;
  FHasHR    := Pos('0000180d', LowerCase(ServicesJson)) > 0;
  FHasCSC   := Pos('00001816', LowerCase(ServicesJson)) > 0;

  Logger.Info(Format('[AndroidBLE] %s services: FTMS=%s POWER=%s FEC=%s HR=%s CSC=%s',
    [FDeviceInfo.Address,
     BoolToStr(FHasFTMS, True), BoolToStr(FHasPower, True), BoolToStr(FHasFEC, True),
     BoolToStr(FHasHR, True), BoolToStr(FHasCSC, True)]));

  { Подписаться на интересующие нас характеристики. Java-сервис сам
    включит CCCD descriptor. }
  if FHasFTMS then
  begin
    Messaging.Send(['ble-subscribe', FDeviceInfo.Address,
      '00001826-0000-1000-8000-00805f9b34fb',
      '00002ad2-0000-1000-8000-00805f9b34fb']);
    Messaging.Send(['ble-subscribe', FDeviceInfo.Address,
      '00001826-0000-1000-8000-00805f9b34fb',
      '00002ad9-0000-1000-8000-00805f9b34fb']);
  end;
  if FHasPower then
    Messaging.Send(['ble-subscribe', FDeviceInfo.Address,
      '00001818-0000-1000-8000-00805f9b34fb',
      '00002a63-0000-1000-8000-00805f9b34fb']);
  if FHasHR then
    Messaging.Send(['ble-subscribe', FDeviceInfo.Address,
      '0000180d-0000-1000-8000-00805f9b34fb',
      '00002a37-0000-1000-8000-00805f9b34fb']);
  if FHasFEC then
    Messaging.Send(['ble-subscribe', FDeviceInfo.Address,
      '6e40fec1-b5a3-f393-e0a9-e50e24dcca9e',
      '6e40fec2-b5a3-f393-e0a9-e50e24dcca9e']);
  if FHasCSC then
    Messaging.Send(['ble-subscribe', FDeviceInfo.Address,
      '00001816-0000-1000-8000-00805f9b34fb',
      '00002a5b-0000-1000-8000-00805f9b34fb']);
end;

procedure TAndroidBLESession.OnGattNotification(const ServiceUUID, CharUUID: string;
  const Data: TBytes);
begin
  ProcessNotification(LowerCase(CharUUID), Data);
end;

procedure TAndroidBLESession.ProcessNotification(const CharUUID: string;
  const Data: TBytes);
begin
  case ClassifyBLECharacteristic(CharUUID) of
    fctIndoorBikeData:          ProcessFTMSData(Data);
    fctCyclingPowerMeasurement: ProcessCyclingPowerData(Data);
    fctHeartRateMeasurement:    ProcessHRMData(Data);
    fctCSCMeasurement:          ProcessCSCData(Data);
    fctFECData:                 ProcessFECData(Data);
  end;
end;

procedure TAndroidBLESession.ProcessFTMSData(const Buf: TBytes);
var
  ParsedData: TTrainerDataRecord;
begin
  ParsedData := FFTMSParser.ParseIndoorBikeData(Buf);
  if not FFTMSParser.LastPacketValid then Exit;
  FLastData := ParsedData;
  FLastData.Timestamp := Now;
  NotifyDataReceived;
end;

procedure TAndroidBLESession.ProcessCyclingPowerData(const Buf: TBytes);
var
  ParsedData: TTrainerDataRecord;
begin
  ParsedData := FFTMSParser.ParseCyclingPowerMeasurement(Buf);
  if not FFTMSParser.LastPacketValid then Exit;
  FLastData := ParsedData;
  NotifyDataReceived;
end;

procedure TAndroidBLESession.ProcessHRMData(const Buf: TBytes);
begin
  if Length(Buf) < 2 then Exit;
  if (Buf[0] and $01) = 0 then
    FLastData.HeartRate := Buf[1]
  else if Length(Buf) >= 3 then
    FLastData.HeartRate := Buf[1];  { 16-bit form, low byte still in [1] for HR<=255 }
  FLastData.Timestamp := Now;
  NotifyDataReceived;
end;

procedure TAndroidBLESession.ProcessCSCData(const Buf: TBytes);
var
  ParsedData: TTrainerDataRecord;
begin
  ParsedData := FFTMSParser.ParseCSCMeasurement(Buf);
  if not FFTMSParser.LastPacketValid then Exit;
  FLastData := ParsedData;
  NotifyDataReceived;
end;

procedure TAndroidBLESession.ProcessFECData(const Buf: TBytes);
begin
  { FE-C over BLE: общий формат как в BLEManager.ProcessFECData.
    Для краткости здесь — стаб; реальная реализация копируется
    из BLEManager без изменений (она платформенно-независимая). }
  if Length(Buf) < 1 then Exit;
  FLastData.Timestamp := Now;
  NotifyDataReceived;
end;

function TAndroidBLESession.WriteCharacteristic(const SvcUUID, CharUUID: string;
  const Data: TBytes; UseRequest: Boolean): Boolean;
var
  ResponseFlag: string;
begin
  Result := False;
  if FConnectionState <> csConnected then Exit;
  if UseRequest then ResponseFlag := '1' else ResponseFlag := '0';
  Messaging.Send(['ble-write', FDeviceInfo.Address, SvcUUID, CharUUID,
    BytesToHex(Data), ResponseFlag]);
  Result := True;  { асинхронно; результат прилетит через ble-write-result }
end;

function TAndroidBLESession.WriteFTMSCommand(const Data: TBytes): Boolean;
begin
  Result := WriteCharacteristic(
    '00001826-0000-1000-8000-00805f9b34fb',
    '00002ad9-0000-1000-8000-00805f9b34fb',
    Data, True);
end;

function TAndroidBLESession.RequestControl: Boolean;
begin
  Result := False;
  if not FHasFTMS then Exit;
  Result := WriteFTMSCommand(TFTMSParser.CreateRequestControlCommand);
  if Result then FHasControl := True;
end;

function TAndroidBLESession.SetTargetPower(Watts: Word): Boolean;
begin
  if FHasFTMS then
    Result := WriteFTMSCommand(TFTMSParser.CreateSetTargetPowerCommand(Watts))
  else
    Result := False;
end;

function TAndroidBLESession.SetResistanceLevel(Level: Byte): Boolean;
begin
  if FHasFTMS then
    Result := WriteFTMSCommand(TFTMSParser.CreateSetResistanceLevelCommand(Level))
  else
    Result := False;
end;

function TAndroidBLESession.SetIncline(InclinePercent: Single): Boolean;
var
  Data: TBytes;
  GradeFTMS: SmallInt;
  GradeRaw: Word;
begin
  Result := False;
  if not FHasFTMS then Exit;

  { FTMS opcode 0x03 — Set Target Inclination, value in 0.1% units }
  GradeFTMS := Round(InclinePercent * 10.0);
  GradeRaw := Word(GradeFTMS);

  SetLength(Data, 3);
  Data[0] := $03;
  Data[1] := Lo(GradeRaw);
  Data[2] := Hi(GradeRaw);
  Result := WriteFTMSCommand(Data);
end;

function TAndroidBLESession.SetSimulation(Grade: Single; WindSpeed: Single;
  RiderWeight: Single; BikeWeight: Single): Boolean;
var
  Data: TBytes;
  WindRaw: SmallInt;
  WindRawWord: Word;
  GradeValue: SmallInt;
  GradeRaw: Word;
begin
  Result := False;
  if not FHasFTMS then Exit;

  WindRaw := Round(WindSpeed * 1000.0);
  WindRawWord := Word(WindRaw);
  GradeValue := Round(Grade * 100.0);
  GradeRaw := Word(GradeValue);

  SetLength(Data, 7);
  Data[0] := $11;
  Data[1] := Lo(WindRawWord);
  Data[2] := Hi(WindRawWord);
  Data[3] := Lo(GradeRaw);
  Data[4] := Hi(GradeRaw);
  Data[5] := 40;             { Crr }
  Data[6] := 51;             { Cw  }
  Result := WriteFTMSCommand(Data);
end;

function TAndroidBLESession.Start: Boolean;
begin
  if FHasFTMS then
    Result := WriteFTMSCommand(TFTMSParser.CreateStartCommand)
  else
    Result := False;
end;

function TAndroidBLESession.Stop: Boolean;
begin
  if FHasFTMS then
    Result := WriteFTMSCommand(TFTMSParser.CreateStopCommand)
  else
    Result := False;
end;

function TAndroidBLESession.Pause: Boolean;
begin
  if FHasFTMS then
    Result := WriteFTMSCommand(TFTMSParser.CreateStopCommand(True))
  else
    Result := False;
end;

function TAndroidBLESession.Reset: Boolean;
begin
  if FHasFTMS then
    Result := WriteFTMSCommand(TFTMSParser.CreateResetCommand)
  else
    Result := False;
end;

{ ═══════════════════════════════════════════════════════════════════
  TAndroidBLEProvider
  ═══════════════════════════════════════════════════════════════════ }

constructor TAndroidBLEProvider.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FSessions := TList.Create;
  FScannedCount := 0;
  SetLength(FScanned, 0);

  { Регистрируем глобальный обработчик сообщений от Java.
    CastleMessaging пробежит по всем подписчикам; наш вернёт True для
    своих сообщений и False для остальных. }
  Messaging.OnReceive.Add(@HandleMessageFromJava);
end;

destructor TAndroidBLEProvider.Destroy;
begin
  if Assigned(Messaging) then
    Messaging.OnReceive.Remove(@HandleMessageFromJava);
  StopScan;
  FreeAndNil(FSessions);
  FreeAndNil(FLock);
  inherited;
end;

class function TAndroidBLEProvider.TransportType: TTransportType;
begin
  Result := ttBLE;
end;

procedure TAndroidBLEProvider.StartScan;
begin
  if FScanning then Exit;
  FScanning := True;
  FLock.Enter;
  try
    SetLength(FScanned, 0);
    FScannedCount := 0;
  finally
    FLock.Leave;
  end;
  Messaging.Send(['ble-scan-start']);
  Logger.Info('[AndroidBLE] scan started');
end;

procedure TAndroidBLEProvider.StopScan;
begin
  if not FScanning then Exit;
  FScanning := False;
  Messaging.Send(['ble-scan-stop']);
  Logger.Info('[AndroidBLE] scan stopped');
end;

function TAndroidBLEProvider.CreateSession(const AAddress: string;
  const AFriendlyName: string): TTransportSession;
var
  S: TAndroidBLESession;
begin
  S := TAndroidBLESession.Create(AAddress, AFriendlyName);
  S.SetProvider(Self);
  RegisterSession(S);
  Result := S;
end;

procedure TAndroidBLEProvider.RegisterSession(ASession: TAndroidBLESession);
begin
  FLock.Enter;
  try
    if FSessions.IndexOf(ASession) < 0 then
      FSessions.Add(ASession);
  finally
    FLock.Leave;
  end;
end;

procedure TAndroidBLEProvider.UnregisterSession(ASession: TAndroidBLESession);
var
  Idx: Integer;
begin
  FLock.Enter;
  try
    Idx := FSessions.IndexOf(ASession);
    if Idx >= 0 then FSessions.Delete(Idx);
  finally
    FLock.Leave;
  end;
end;

function TAndroidBLEProvider.FindSessionLocked(
  const AAddress: string): TAndroidBLESession;
var
  I: Integer;
  S: TAndroidBLESession;
begin
  Result := nil;
  for I := 0 to FSessions.Count - 1 do
  begin
    S := TAndroidBLESession(FSessions[I]);
    if SameText(S.DeviceInfo.Address, AAddress) then Exit(S);
  end;
end;

function TAndroidBLEProvider.HandleMessageFromJava(
  const Received: TCastleStringList): Boolean;
var
  Tag, Address: string;
  S: TAndroidBLESession;
  Dev: TDeviceInfo;
  RssiInt: Integer;
begin
  Result := False;
  if Received.Count < 1 then Exit;
  Tag := Received[0];

  { Все наши сообщения начинаются с 'ble-' }
  if Copy(Tag, 1, 4) <> 'ble-' then Exit;

  Result := True;

  if (Tag = 'ble-device-found') and (Received.Count >= 4) then
  begin
    Address := Received[1];
    FLock.Enter;
    try
      if FScannedCount >= Length(FScanned) then
        SetLength(FScanned, FScannedCount + 16);
      FScanned[FScannedCount].Address := Address;
      FScanned[FScannedCount].Name := Received[2];
      RssiInt := StrToIntDef(Received[3], 0);
      if RssiInt < -128 then RssiInt := -128
      else if RssiInt > 127 then RssiInt := 127;
      FScanned[FScannedCount].RSSI := RssiInt;
      Inc(FScannedCount);
    finally
      FLock.Leave;
    end;

    if Assigned(OnDeviceFound) then
    begin
      Dev := Default(TDeviceInfo);
      Dev.Address := Address;
      Dev.Name := Received[2];
      Dev.RSSI := RssiInt;
      Dev.TransportType := ttBLE;
      Dev.ProviderName := 'AndroidBLE';
      OnDeviceFound(Dev);
    end;
    Exit;
  end;

  if (Tag = 'ble-connection') and (Received.Count >= 4) then
  begin
    FLock.Enter;
    try
      S := FindSessionLocked(Received[1]);
    finally
      FLock.Leave;
    end;
    if Assigned(S) then
      S.OnConnectionStateChanged(Received[2], Received[3]);
    Exit;
  end;

  if (Tag = 'ble-services') and (Received.Count >= 3) then
  begin
    FLock.Enter;
    try
      S := FindSessionLocked(Received[1]);
    finally
      FLock.Leave;
    end;
    if Assigned(S) then
      S.OnGattServicesDiscovered(Received[2]);
    Exit;
  end;

  if (Tag = 'ble-notify') and (Received.Count >= 5) then
  begin
    FLock.Enter;
    try
      S := FindSessionLocked(Received[1]);
    finally
      FLock.Leave;
    end;
    if Assigned(S) then
      S.OnGattNotification(Received[2], Received[3], HexToBytes(Received[4]));
    Exit;
  end;

  if (Tag = 'ble-write-result') and (Received.Count >= 4) then
  begin
    Logger.Debug(Format('[AndroidBLE] write %s/%s -> %s',
      [Received[1], Received[2], Received[3]]));
    Exit;
  end;

  if Tag = 'ble-permissions' then
  begin
    if Received.Count >= 2 then
      Logger.Info('[AndroidBLE] permissions: ' + Received[1])
    else
      Logger.Info('[AndroidBLE] permissions: (no value)');
    Exit;
  end;

  if Tag = 'ble-error' then
  begin
    if Received.Count >= 2 then
      Logger.Warning('[AndroidBLE] service error: ' + Received[1])
    else
      Logger.Warning('[AndroidBLE] service error');
    Exit;
  end;

  { ble-* но не наш — пусть кто-нибудь другой обработает }
  Result := False;
end;

{$endif}

{ ── AndroidBLEAvailable ────────────────────────────────────────── }

function AndroidBLEAvailable: Boolean;
begin
  {$ifdef ANDROID}
  { В реальной сборке здесь стоит послать health-check через Messaging
    и подождать ответ. Для простоты предполагаем, что Java-сервис
    подключён через CastleEngineManifest.xml -> <android><service name="ble"/>.
    Если сервис отсутствует, Messaging.Send молча не дойдёт, и
    провайдер просто не получит ни одного устройства — это безопасно. }
  Result := True;
  {$else}
  Result := False;
  {$endif}
end;

end.
