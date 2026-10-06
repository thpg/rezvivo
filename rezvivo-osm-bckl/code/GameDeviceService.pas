{ GameDeviceService — транспорт-агностичный сервис для UI-слоя.

  ── Новая модель: слоты активных сенсоров ──

  Вместо одного «выбранного устройства» и мержа TTrainerDataRecord
  сервис оперирует слотами активных сенсоров — по одному на каждый
  TSensorKind (HR, Power, Cadence, Speed).

  Пользователь назначает, какой конкретный датчик (с какого устройства)
  используется для каждого слота. Например:
    HR      ← Polar H10 (отдельный HRM)
    Power   ← Wahoo KICKR (тренажёр)
    Cadence ← Wahoo KICKR
    Speed   ← Wahoo KICKR

  Для управления тренажёром (FTMS-команды: SetTargetPower, SetIncline, ...)
  назначается отдельный ControlDevice.

  UI читает данные напрямую из активных сенсоров:
    DeviceService.Power.Instant        → 245
    DeviceService.Power.FormatInstant   → '245 W'
    DeviceService.HR.SessionAverage     → 152.3

  Глобальная переменная DeviceService — основной способ доступа.
  Алиас BLEService предоставлен для обратной совместимости. }
unit GameDeviceService;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fgl,
  TrainerData, GameTransportBase, GameDeviceManager, GameTrainerControl,
  GameDeviceTypes, GameDeviceSensor, GameDeviceAssignments, GameActivitySource,
  BLEManager, SimpleBLEProvider, WinRTBLEProvider, ANTPlus, GameDeviceSim,
  AppSettings, DebugLog;

type
  TSimSeekEvent = procedure(var Seconds: Double) of object;
  TGameDeviceList = specialize TFPGObjectList<TGameDeviceEntry>;

  TOnDeviceLog = procedure(const Msg: String) of object;
  TOnDevicesChanged = procedure of object;
  TOnSensorDataChanged = procedure(AKind: TSensorKind) of object;
  TOnDeviceConnectionChanged = procedure(AEntry: TGameDeviceEntry) of object;

  { Алиасы для обратной совместимости }
  TGameBLEDeviceList = TGameDeviceList;
  TOnBLELog = TOnDeviceLog;
  TOnBLEDevicesChanged = TOnDevicesChanged;

  { TGameDeviceService }

  TGameDeviceService = class
  private
    FLastHealthCheck: QWord;
    FManager: TDeviceManager;
    FDevices: TGameDeviceList;
    { Discovery and the selected FIT player. Sessions belong to the manager. }
    FSimProvider: TSimTransportProvider;
    FSimSession: TSimTransportSession; { manager-owned, selected on the main thread }
    FSimAddress: String;
    FSimulationEnabled, FSimPlaybackWanted: Boolean;
    FSimGeneration: Cardinal;
    { Last-reason для SimPlayerInfo чтобы лог не захлёбывался — пишем
      только когда статус меняется. }
    FSimLastReason: String;

    { Активные сенсоры — по одному на каждый тип.
      Не owned: принадлежат TGameDeviceEntry.Sensors.
      nil = слот пустой. }
    FActiveSensors: array[TSensorKind] of TDeviceSensor;

    { Устройство для FTMS-команд управления тренажёром }
    FControlDevice: TGameDeviceEntry;
    FAssignments: TDeviceRoleAssignments;
    FAssignmentProfileId: Int64;
    FAssignmentFile: String;
    FAssignmentsReady, FAssignmentsRefreshing: Boolean;
    FPendingDevice: TGameDeviceEntry;
    procedure RefreshAssignmentsProfile;
    procedure SaveAssignments;
    function ShouldAutoConnect(AEntry: TGameDeviceEntry): Boolean;
    procedure ApplyDeviceSelection(AEntry: TGameDeviceEntry);
  private

    { Автоназначение при подключении }
    FAutoAssign: Boolean;

    { Автоподключение при обнаружении }
    FAutoConnect: Boolean;

    FOnLog: TOnDeviceLog;
    FOnDevicesChanged: TOnDevicesChanged;
    FOnSensorDataChanged: TOnSensorDataChanged;
    FOnConnectionChanged: TOnDeviceConnectionChanged;

    FAutoScanStarted: Boolean;
    FANTStickPresent: Boolean;

    procedure SimulationChanged(Sender: TObject);
    function AcceptSimulationDevice(const Device: TDeviceInfo): Boolean;
    function FindDeviceByAddress(const AAddress: String): TGameDeviceEntry;
    function FindDevice(const AAddress, AProvider: String): TGameDeviceEntry;

    { OnApplicationUpdate: подписан на ApplicationProperties.OnUpdate
      пока активен continuous scan. Тикает Manager.Tick — он сливает
      отложенные DeviceFound и ConnectionChanged события подписчикам.
      Без этого TThread.Queue в DeviceManager не прокручивается под
      Castle Engine (CGE не вызывает CheckSynchronize), и события
      auto-connect/auto-assign копятся пока юзер не зайдёт в TViewDevices,
      где Update имеет CheckSynchronize. }
    procedure OnApplicationUpdate(Sender: TObject);

    procedure HandleDeviceFound(const Device: TDeviceInfo);
    procedure HandleDeviceDataReceived(const Device: TDeviceInfo;
      const Data: TTrainerDataRecord);
    procedure HandleDeviceConnectionChanged(const Device: TDeviceInfo;
      State: TConnectionState; const Message: string);

    { Очищает слоты, указывающие на сенсоры данного устройства }
    procedure ClearSensorsOfDevice(AEntry: TGameDeviceEntry);

    { Пробует автоназначить пустые слоты из подключённых устройств }
    procedure DoAutoAssign;

    { Гейт: разрешено ли транспорту участвовать в авто-логике (auto-
      connect, auto-assign, auto-control)? Сейчас отключаем ttANTPlus
      пока не готова интеграция в игровой цикл — устройства видны на
      странице, но не подключаются автоматически и не назначаются
      активными сенсорами. Ручной клик по карточке остаётся доступным. }
    function IsTransportEnabledInGame(ATransport: TTransportType): Boolean;

    procedure Log(const S: String);
    function MapState(const S: TConnectionState): TGameDeviceConnectionState;
  public
    constructor Create;
    destructor Destroy; override;

    { ── Провайдеры ── }
    procedure RegisterProvider(AProvider: TTransportProvider);

    { ── Сканирование ── }
    procedure StartScan;
    procedure StopScan;
    procedure CheckStaleConnections;

    { ── Автосканирование ──
      Запускает StartScan один раз при старте приложения. Звать из
      ApplicationInitialize, чтобы поиск шёл независимо от того,
      какой TCastleView сейчас активен. Идемпотентен. }
    procedure EnableContinuousScan;

    { Останавливает скан. Зовётся автоматически из деструктора. }
    procedure DisableContinuousScan;

    { ── Подключение / отключение конкретного устройства ── }
    procedure ConnectDevice(AEntry: TGameDeviceEntry);
    procedure DisconnectDevice(AEntry: TGameDeviceEntry);

    { Управление симуляцией: вызывается из ViewPlay.Start/Stop, чтобы
      проигрывание FIT шло только во время активной игры (а не пока
      юзер ещё в меню или Devices-вкладке). Если симуляция не
      включена в Settings или sim-устройство не подключено — no-op. }
    procedure StartSimPlayback;
    procedure StopSimPlayback;

    { Управление плеером из UI (in-game player widget). Все методы
      no-op'нутся если симулятор не активен. SimPlayerInfo
      возвращает False если плеер не показывается. }
    procedure SimTogglePause;
    procedure SimSetPaused(APaused: Boolean);
    procedure SimRestart;
    { Playback rates from one 1/60 s frame per real second to 8x.
      The scene, physics and FIT share the delta returned by SimAdvance. }
    procedure SimCycleSpeed(Slower: Boolean = False);
    function SimAdvance(RealSeconds: Single): Single;
    function SimPositionSec: Double;
    function SimLoopSerial: Cardinal;
    procedure SimStepFrame;
    procedure SimPublishCurrent;
  public
    OnSimSeek: TSimSeekEvent;
    function  SimGetSpeed: Single;
    { Shared controls for UI and MCP. Seeking also restores the ride state. }
    procedure SimSetSpeed(AMul: Single);
    procedure SimSeekSec(ASec: Double);
    function  SimPlayerInfo(out APaused: Boolean;
      out ACurrentSec, ATotalSec: Integer): Boolean;

    { IsSimulationActive — True если включена симуляция и есть
      подключённое sim-устройство, реально кормящее игру данными.
      Только плеер/изоляция (пауза, ×N, не цеплять живой BLE).
      Телеметрия идёт тем же каналом сенсоров, что у тренажёра. }
    function IsSimulationActive: Boolean;

    { Последний сырой пакет с control-устройства (Distance, ElapsedTime,
      Incline — поля, которых ещё нет в слотах сенсоров). }
    function LastTrainerData: TTrainerDataRecord;

    { ── Назначение активных сенсоров ── }

    { Назначить конкретный сенсор в слот.
      Пример: AssignSensor(skPower, KickrEntry.PowerSensor) }
    procedure AssignSensor(AKind: TSensorKind; ASensor: TDeviceSensor);
    { Select first, then connect. The request survives leaving the page. }
    procedure SelectDeviceForRoles(AEntry: TGameDeviceEntry);
    function IsSensorSelected(AKind: TSensorKind; AEntry: TGameDeviceEntry): Boolean;
    function SelectedSensorName(AKind: TSensorKind): String;
    function SensorDisabled(AKind: TSensorKind): Boolean;
    function IsControlSelected(AEntry: TGameDeviceEntry): Boolean;
    function SelectedControlName: String;
    function ControlDisabled: Boolean;

    { Очистить слот }
    procedure ClearSensor(AKind: TSensorKind);

    { Очистить все слоты }
    procedure ClearAllSensors;

    { Автоназначение: для каждого пустого слота найти подходящий
      сенсор среди подключённых устройств }
    procedure AutoAssignSensors;

    { Включить/выключить автоназначение при подключении }
    property AutoAssign: Boolean read FAutoAssign write FAutoAssign;

    { Включить/выключить автоподключение при обнаружении устройства }
    property AutoConnect: Boolean read FAutoConnect write FAutoConnect;

    { ── Чтение активных сенсоров ── }

    { Активный сенсор для данного типа. nil если не назначен. }
    function Sensor(AKind: TSensorKind): TDeviceSensor; inline;

    { Типизированные аксессоры. nil если не назначен. }
    function HR: THRSensor; inline;
    function Power: TPowerSensor; inline;
    function Cadence: TCadenceSensor; inline;
    function Speed: TSpeedSensor; inline;

    function HasSensor(AKind: TSensorKind): Boolean; inline;
    function HasAnySensor: Boolean;
    function ActivitySourceFlags: Byte;

    { ── Управление тренажёром (FTMS) ── }

    { Устройство, принимающее команды управления.
      Назначается вручную или автоматически (первый подключённый тренажёр). }
    procedure SetControlDevice(AEntry: TGameDeviceEntry);
    property ControlDevice: TGameDeviceEntry read FControlDevice;
    function HasControlDevice: Boolean;
    function ControlStatus: TTrainerControlStatus;

    procedure RequestControl;
    procedure SetTargetPower(APower: Word);
    procedure SetResistanceLevel(ALevel: Byte);
    procedure SetIncline(AIncline: Single);
    procedure SetSimulation(AGrade, AWindSpeed, AUserWeight, ABikeWeight: Single);
    procedure StartTrainer;
    procedure PauseTrainer;
    procedure StopTrainer;

    { ── Сессия ── }

    { Сброс статистики (min/max/avg) у всех сенсоров всех устройств.
      Вызывается при старте новой тренировки. }
    procedure ResetSession;

    { ── Списки ── }

    property Devices: TGameDeviceList read FDevices;
    property Manager: TDeviceManager read FManager;

    { Стик ANT+ был найден при старте (Open backend удался). Галка на
      вкладке устройств серая, если False. }
    property ANTStickPresent: Boolean read FANTStickPresent;

    { Все известные сенсоры данного типа (со всех устройств).
      Вызывающий владеет списком — нужно вызвать Free. }
    function AllSensorsOfKind(AKind: TSensorKind): TDeviceSensorList;

    { ── Колбэки ── }

    property OnLog: TOnDeviceLog read FOnLog write FOnLog;
    property OnDevicesChanged: TOnDevicesChanged read FOnDevicesChanged write FOnDevicesChanged;
    property OnSensorDataChanged: TOnSensorDataChanged read FOnSensorDataChanged write FOnSensorDataChanged;
    property OnConnectionChanged: TOnDeviceConnectionChanged read FOnConnectionChanged write FOnConnectionChanged;
  end;

  { Алиас класса для обратной совместимости }
  TGameBLEService = TGameDeviceService;

var
  DeviceService: TGameDeviceService;
  BLEService: TGameDeviceService absolute DeviceService;

implementation

uses Math,
  CastleApplicationProperties, fpjson, GameUserData, GameRouteLibraryData, VeloSiteAPI;

{ ═══════════════════════════════════════════════════════════════════
  TGameDeviceService
  ═══════════════════════════════════════════════════════════════════ }

constructor TGameDeviceService.Create;
var
  K: TSensorKind;
begin
  inherited Create;

  FAssignments := TDeviceRoleAssignments.Create;
  FAssignmentProfileId := Low(Int64);
  FDevices := TGameDeviceList.Create(True);
  FControlDevice := nil;
  FAutoAssign := True;
  FAutoConnect := True;

  FAutoScanStarted := False;

  for K := Low(TSensorKind) to High(TSensorKind) do
    FActiveSensors[K] := nil;

  FManager := TDeviceManager.Create;

  if WinRTBLEAvailable then
  begin
    FManager.RegisterProvider(TWinRTBLEProvider.Create);
    Logger.Info('[DeviceService] WinRT BLE provider registered');
  end else
    Logger.Info('[DeviceService] WinRT BLE not available');

  { Провайдер ANT+ всегда в списке — иначе нет галки. Стик проверяем
    один раз: без железа галка серая, скан сам ничего не найдёт. }
  FANTStickPresent := ANTPlusAvailable;
  FManager.RegisterProvider(TANTProvider.Create);
  if FANTStickPresent then
    Logger.Info('[DeviceService] ANT+ provider registered (stick present)')
  else
    Logger.Info('[DeviceService] ANT+ provider registered (no stick)');

  { Sim provider регистрируется всегда — он сам ничего не эмитит,
    пока в Settings не выбран FIT-файл и Settings.SimulationEnabled=True
    (последнее проверяется в самом провайдере). Регистрация дешевая,
    дев-инструмент. Ссылку запоминаем: сессии управляются (Start/Stop
    Playback) через провайдер, минуя менеджер. }
  FSimProvider := TSimTransportProvider.Create;
  FManager.RegisterProvider(FSimProvider);
  Logger.Info('[DeviceService] Sim provider registered');

  FManager.OnDeviceFound := @HandleDeviceFound;
  FManager.OnDeviceDataReceived := @HandleDeviceDataReceived;
  FManager.OnDeviceConnectionChanged := @HandleDeviceConnectionChanged;
  Settings.OnSimulationChanged := @SimulationChanged;
  RefreshAssignmentsProfile;
  SimulationChanged(nil);
end;

destructor TGameDeviceService.Destroy;
var
  K: TSensorKind;
begin
  Settings.OnSimulationChanged := nil;
  { Снимаем подписку на OnUpdate ДО уничтожения менеджера —
    иначе тик после освобождения FManager упадёт с AV. }
  DisableContinuousScan;

  if Assigned(FManager) then
  begin
    FManager.OnDeviceFound := nil;
    FManager.OnDeviceDataReceived := nil;
    FManager.OnDeviceConnectionChanged := nil;
    FManager.DisconnectAll;
  end;

  for K := Low(TSensorKind) to High(TSensorKind) do
    FActiveSensors[K] := nil;
  FControlDevice := nil;

  FreeAndNil(FManager);
  FreeAndNil(FDevices);
  FreeAndNil(FAssignments);
  inherited;
end;

procedure TGameDeviceService.RegisterProvider(AProvider: TTransportProvider);
begin
  FManager.RegisterProvider(AProvider);
end;

procedure TGameDeviceService.Log(const S: String);
begin
  { Дублируем в Logger чтобы сообщения попадали в файл лога даже
    когда никто не подписан на FOnLog (нет UI-консоли). Без этого
    диагностика auto-connect / auto-assign теряется в release-сборке. }
  Logger.Info('[DeviceService] ' + S);
  if Assigned(FOnLog) then FOnLog(S);
end;

function TGameDeviceService.IsTransportEnabledInGame(
  ATransport: TTransportType): Boolean;
begin
  { BLE and ANT+ feed the same sensor slots and trainer-control interface.
    Only FIT simulation is exclusive; adapter availability and the saved
    per-role selection are checked by the manager/assignment layer. }
  if FSimulationEnabled then Result := ATransport = ttSim
  else Result := ATransport <> ttSim;
end;

function TGameDeviceService.AcceptSimulationDevice(const Device: TDeviceInfo): Boolean;
begin
  Result := (Device.TransportType <> ttSim) or
    (FSimulationEnabled and (FSimAddress <> '') and SameFileName(Device.Address, FSimAddress));
end;

procedure TGameDeviceService.SimulationChanged(Sender: TObject);
var Enabled: Boolean; Address, Path: String; I: Integer; E: TGameDeviceEntry;
begin
  Enabled := Settings.GetSimulationEnabled;
  Address := '';
  Path := Settings.EffectiveSimulationFitPath;
  if Enabled and (Path <> '') then Address := 'sim:' + Path;
  if (Enabled = FSimulationEnabled) and (Address = FSimAddress) then Exit;
  FSimulationEnabled := Enabled;
  FSimAddress := Address;
  Inc(FSimGeneration);
  if FSimSession <> nil then FSimSession.StopPlayback;
  FSimSession := nil;
  ClearAllSensors;
  for I := 0 to FDevices.Count-1 do
  begin
    E := FDevices[I];
    if (E.DeviceInfo.TransportType = ttSim) and
      (E.ConnectionState in [gdcsConnected, gdcsConnecting]) then
      FManager.Disconnect(E.DeviceInfo.Address);
  end;
  DoAutoAssign;
  { FIT discovery is non-blocking. Do not wait behind a Bluetooth scan. }
  if Enabled then FSimProvider.StartScan
  else if FAutoScanStarted then FManager.StartScan;
  if Assigned(FOnDevicesChanged) then FOnDevicesChanged;
end;

function TGameDeviceService.MapState(
  const S: TConnectionState): TGameDeviceConnectionState;
begin
  case S of
    csScanning:   Result := gdcsScanning;
    csConnecting: Result := gdcsConnecting;
    csConnected:  Result := gdcsConnected;
    csError:      Result := gdcsError;
  else
    Result := gdcsDisconnected;
  end;
end;

{ ── Поиск устройств ── }

function TGameDeviceService.FindDeviceByAddress(
  const AAddress: String): TGameDeviceEntry;
var I: Integer;
begin
  Result := nil;
  for I := 0 to FDevices.Count - 1 do
    if SameText(FDevices[I].DeviceInfo.Address, AAddress) then
      Exit(FDevices[I]);
end;

function TGameDeviceService.FindDevice(
  const AAddress, AProvider: String): TGameDeviceEntry;
var I: Integer;
begin
  Result := nil;
  for I := 0 to FDevices.Count - 1 do
    if SameText(FDevices[I].DeviceInfo.Address, AAddress) and
       SameText(FDevices[I].DeviceInfo.ProviderName, AProvider) then
      Exit(FDevices[I]);
end;

{ ── Колбэки менеджера ── }

procedure TGameDeviceService.HandleDeviceFound(const Device: TDeviceInfo);
var
  Entry: TGameDeviceEntry;
  IsNew: Boolean;
begin
  if not AcceptSimulationDevice(Device) then Exit;
  Entry := FindDevice(Device.Address, Device.ProviderName);
  if not Assigned(Entry) then
    Entry := FindDeviceByAddress(Device.Address);
  IsNew := not Assigned(Entry);

  { Already connected — just skip, no flood }
  if (not IsNew) and (Entry.ConnectionState = gdcsConnected) then
    Exit;

  if IsNew then
  begin
    Entry := TGameDeviceEntry.Create(Device);
    FDevices.Add(Entry);
    Log('Found: ' + Entry.DisplayName);
  end
  else
    Entry.DeviceInfo := Device;

  if Assigned(FOnDevicesChanged) then
    FOnDevicesChanged;

  { Auto-connect new devices, or reconnect known fitness devices.
    При активной симуляции в игру подключаем только sim-устройство —
    реальные BLE/ANT+ продолжают сканироваться и видеться в списке,
    но в игру не идут (требование dev-режима). Симметрично: вне
    симуляции sim-устройство не появится в списке, потому что
    провайдер ничего не эмитит без Settings.SimulationEnabled. }
  if Settings.GetSimulationEnabled and
     (Entry.DeviceInfo.TransportType <> ttSim) then
  begin
    Log(Format('Skip auto-connect %s — simulation mode active',
      [Entry.DisplayName]));
    Exit;
  end;

  { Auto-connect new devices, or reconnect known fitness devices }
  if FAutoConnect and
     ShouldAutoConnect(Entry) and
     IsTransportEnabledInGame(Entry.DeviceInfo.TransportType) and
     (not Entry.TestedNotFitness) and
     (Entry.ConnectionState in [gdcsDisconnected, gdcsError]) then
  begin
    if IsNew then
      Log('Auto-connecting: ' + Entry.DisplayName)
    else
      Log('Re-connecting: ' + Entry.DisplayName);
    FManager.Connect(Entry.DeviceInfo.Address,
      Entry.DisplayName,
      Entry.DeviceInfo.ProviderName);
  end;
end;

procedure TGameDeviceService.HandleDeviceDataReceived(
  const Device: TDeviceInfo; const Data: TTrainerDataRecord);
var
  Entry: TGameDeviceEntry;
  K: TSensorKind;
begin
  if not AcceptSimulationDevice(Device) then Exit;
  try
    Entry := FindDevice(Device.Address, Device.ProviderName);
    if not Assigned(Entry) then
      Entry := FindDeviceByAddress(Device.Address);
    if not Assigned(Entry) then
    begin
      { Пакет раньше DeviceFound (первый notify при поиске) — не падаем. }
      Exit;
    end;

    if Entry.DiscoverMetrics(Data) then
    begin
      if FAutoAssign then DoAutoAssign;
      if Assigned(FOnDevicesChanged) then FOnDevicesChanged;
    end;
    Entry.FeedData(Data);

    if Assigned(FOnSensorDataChanged) and Assigned(Entry.Sensors) then
      for K := Low(TSensorKind) to High(TSensorKind) do
        if Assigned(FActiveSensors[K]) and
           (Entry.Sensors.IndexOf(FActiveSensors[K]) >= 0) then
          FOnSensorDataChanged(K);
  except
    on E: Exception do
      Logger.Warning('[DeviceService] HandleDeviceDataReceived: ' +
        E.ClassName + ': ' + E.Message);
  end;
end;

procedure TGameDeviceService.HandleDeviceConnectionChanged(
  const Device: TDeviceInfo; State: TConnectionState; const Message: string);
var
  Entry: TGameDeviceEntry;
  MappedState: TGameDeviceConnectionState;
  Session: TTransportSession;
begin
  { A file choice can change while a previous FIT is still loading. Never
    auto-assign that late connection or let it replace the selected player. }
  if not AcceptSimulationDevice(Device) then
  begin
    if State = csConnected then FManager.Disconnect(Device.Address);
    Entry := FindDeviceByAddress(Device.Address);
    if Entry <> nil then
    begin
      ClearSensorsOfDevice(Entry);
      Entry.ConnectionState := gdcsDisconnected;
    end;
    Exit;
  end;
  Log(Format('HandleDeviceConnectionChanged: %s state=%d Power=%s FEC=%s',
    [Device.Address, Ord(State),
     BoolToStr(Device.SupportsPower, True),
     BoolToStr(Device.SupportsCadence, True)]));

  Entry := FindDevice(Device.Address, Device.ProviderName);
  if not Assigned(Entry) then
    Entry := FindDeviceByAddress(Device.Address);
  if not Assigned(Entry) then
  begin
    Entry := TGameDeviceEntry.Create(Device);
    FDevices.Add(Entry);
    Log('  Created new entry');
  end;

  Entry.DeviceInfo := Device;
  MappedState := MapState(State);

  { Запоминаем момент реальной смены состояния — отдельно от
    повторных событий с тем же стейтом. По этому таймстемпу
    CheckStaleConnections выловит "застрявшее" Connecting/Error. }
  if Entry.ConnectionState <> MappedState then
    Entry.LastStateChange := Now;

  Entry.ConnectionState := MappedState;
  Entry.LastMessage := Message;

  case MappedState of
    gdcsConnected:
    begin
      Log(TRANSPORT_TYPE_NAMES[Device.TransportType] +
        ' connected: ' + Entry.DisplayName);
      ClearSensorsOfDevice(Entry);
      Entry.RebuildSensors;
      if Device.TransportType = ttSim then
      begin
        Session := FManager.GetSession(Device.Address);
        if Session is TSimTransportSession then
        begin
          FSimSession := TSimTransportSession(Session);
          FSimSession.SetPaused(True);
          if FSimPlaybackWanted then FSimSession.StartPlayback
          else FSimSession.PublishCurrent;
        end;
      end;
      Log(Format('  RebuildSensors → %d sensors',
        [Entry.Sensors.Count]));
      { A recognized fitness service may not have published optional fields
        yet. The provider explicitly rejects non-fitness peripherals. }
      Entry.TestedNotFitness := False;
      if FAutoAssign then
        DoAutoAssign;
    end;
    gdcsDisconnected:
    begin
      if (Device.TransportType = ttSim) and (FSimSession <> nil) and
        SameFileName(FSimSession.DeviceInfo.Address, Device.Address) then
        FSimSession := nil;
      Log(TRANSPORT_TYPE_NAMES[Device.TransportType] +
        ' disconnected: ' + Entry.DisplayName);
      ClearSensorsOfDevice(Entry);
      if FControlDevice = Entry then
        FControlDevice := nil;
      { Mark devices that were tested and found to be non-fitness }
      if Pos('Not a fitness', Message) > 0 then
        Entry.TestedNotFitness := True;
    end;
    gdcsError:
    begin
      ClearSensorsOfDevice(Entry);
      if FControlDevice=Entry then FControlDevice:=nil;
      Log(TRANSPORT_TYPE_NAMES[Device.TransportType] +
        ' error: ' + Entry.DisplayName + ' / ' + Message);
    end;
  end;

  Log(Format('  Firing callbacks: OnConnChanged=%s OnDevicesChanged=%s',
    [BoolToStr(Assigned(FOnConnectionChanged), True),
     BoolToStr(Assigned(FOnDevicesChanged), True)]));

  if Assigned(FOnConnectionChanged) then
    FOnConnectionChanged(Entry);

  if Assigned(FOnDevicesChanged) then
    FOnDevicesChanged;
end;

{ ── Внутренние хелперы ── }

procedure TGameDeviceService.RefreshAssignmentsProfile;
var Id: Int64; O: TJSONObject; I: Integer; E: TGameDeviceEntry;
begin
  if FAssignmentsRefreshing then Exit;
  Id := 0;
  if VeloSite.IsAuthorized then
  begin
    Id := VeloSite.CachedProfile.Id;
    { Authentication can precede loading the account. Do not borrow local roles. }
    if Id <= 0 then Id := -1;
  end;
  if Id = FAssignmentProfileId then Exit;
  FAssignmentsRefreshing := True;
  try
    ClearAllSensors;
    FPendingDevice := nil;
    FAssignmentProfileId := Id;
    FAssignmentsReady := Id >= 0;
    FAssignmentFile := '';
    FAssignments.Reset(not FAssignmentsReady);
    if FAssignmentsReady then
    begin
      { The path is bound to this identity, not whichever account happens to
        be current later when a background connection finishes. }
      FAssignmentFile := RouteAccountDir(Id) + 'device-roles.json';
      if FileExists(FAssignmentFile) then
      begin
        O := nil;
        try
          try
            O := ReadAccountJSON(FAssignmentFile);
            if O = nil then FAssignments.Reset(True)
            else FAssignments.LoadJSON(O);
          except
            on Ex: Exception do
            begin
              FAssignments.Reset(True);
              Log('Could not restore sensor roles: ' + Ex.Message);
            end;
          end;
        finally O.Free; end;
      end;
    end;
  finally FAssignmentsRefreshing := False; end;
  DoAutoAssign;
  if FAutoConnect and FAssignmentsReady then
    for I := 0 to FDevices.Count - 1 do
    begin
      E := FDevices[I];
      if (E.ConnectionState in [gdcsDisconnected, gdcsError]) and
        not E.TestedNotFitness and IsTransportEnabledInGame(E.DeviceInfo.TransportType) and
        ShouldAutoConnect(E) then ConnectDevice(E);
    end;
  if Assigned(FOnDevicesChanged) then FOnDevicesChanged;
end;

procedure TGameDeviceService.SaveAssignments;
var O: TJSONObject;
begin
  if not FAssignmentsReady or FSimulationEnabled or (FAssignmentFile = '') then Exit;
  O := FAssignments.ToJSON;
  try
    try WriteAccountJSON(FAssignmentFile, O);
    except on E: Exception do Log('Could not save sensor roles: ' + E.Message); end;
  finally O.Free; end;
end;

function TGameDeviceService.ShouldAutoConnect(AEntry: TGameDeviceEntry): Boolean;
var D: TDeviceInfo;
begin
  Result := False;
  if not FAssignmentsReady or (AEntry = nil) then Exit;
  D := AEntry.DeviceInfo;
  if FSimulationEnabled then Exit(AcceptSimulationDevice(D));
  if D.TransportType = ttSim then Exit;
  if AEntry = FPendingDevice then Exit(True);
  if not FAssignments.HasRemembered then Exit(True);
  if FAssignments.UsesDevice(TRANSPORT_TYPE_NAMES[D.TransportType], D.Address) then Exit(True);
  { After the first pairing, unknown fitness devices are only useful for an
    as-yet unassigned advertised role. A missing selected trainer is not a gap. }
  Result := (D.SupportsHeartRate and (FAssignments.Selection[drHeartRate].Mode = dsmAutomatic)) or
    (D.SupportsPower and (FAssignments.Selection[drPower].Mode = dsmAutomatic)) or
    (D.SupportsCadence and (FAssignments.Selection[drCadence].Mode = dsmAutomatic)) or
    (D.SupportsControl and (FAssignments.Selection[drControllable].Mode = dsmAutomatic));
end;

procedure TGameDeviceService.SelectDeviceForRoles(AEntry: TGameDeviceEntry);
begin
  RefreshAssignmentsProfile;
  if (AEntry = nil) or not FAssignmentsReady or
    (FSimulationEnabled <> (AEntry.DeviceInfo.TransportType = ttSim)) or
    not AcceptSimulationDevice(AEntry.DeviceInfo) then Exit;
  FPendingDevice := AEntry;
  if AEntry.ConnectionState = gdcsConnected then
  begin
    FPendingDevice := nil;
    ApplyDeviceSelection(AEntry);
  end
  else if AEntry.ConnectionState in [gdcsDisconnected, gdcsError] then ConnectDevice(AEntry);
end;

procedure TGameDeviceService.ApplyDeviceSelection(AEntry: TGameDeviceEntry);
var K: TSensorKind; S: TDeviceSensor; R: TDeviceRole; Old: TDeviceSelection;
begin
  Old := FAssignments.Selection[drControllable];
  for K := Low(TSensorKind) to High(TSensorKind) do
  begin
    S := AEntry.FindSensor(K);
    if S = nil then Continue;
    R := TDeviceRole(Ord(K));
    { Changing trainers replaces that trainer's roles, while retaining an
      explicitly selected external power meter / HR and an explicit None. }
    if not AEntry.IsControllable or FSimulationEnabled or
      (FAssignments.Selection[R].Mode = dsmAutomatic) or
      FAssignments.Matches(R, Old.Transport, Old.Address) then AssignSensor(K, S);
  end;
  if AEntry.IsControllable then SetControlDevice(AEntry);
end;

function TGameDeviceService.IsSensorSelected(AKind: TSensorKind;
  AEntry: TGameDeviceEntry): Boolean;
begin
  if AEntry = nil then Exit(False);
  if FSimulationEnabled then Exit((FActiveSensors[AKind] <> nil) and
    (AEntry.FindSensor(AKind) = FActiveSensors[AKind]));
  Result := FAssignments.Matches(TDeviceRole(Ord(AKind)),
    TRANSPORT_TYPE_NAMES[AEntry.DeviceInfo.TransportType], AEntry.DeviceInfo.Address);
end;

function TGameDeviceService.SelectedSensorName(AKind: TSensorKind): String;
var S: TDeviceSelection;
begin
  Result := '';
  if FSimulationEnabled then Exit;
  S := FAssignments.Selection[TDeviceRole(Ord(AKind))];
  if S.Mode <> dsmDevice then Exit;
  Result := S.Name;
  if Result = '' then Result := S.Address;
end;

function TGameDeviceService.SensorDisabled(AKind: TSensorKind): Boolean;
begin
  Result := not FSimulationEnabled and
    (FAssignments.Selection[TDeviceRole(Ord(AKind))].Mode = dsmNone);
end;

function TGameDeviceService.IsControlSelected(AEntry: TGameDeviceEntry): Boolean;
begin
  if AEntry = nil then Exit(False);
  if FSimulationEnabled then Exit(FControlDevice = AEntry);
  Result := FAssignments.Matches(drControllable,
    TRANSPORT_TYPE_NAMES[AEntry.DeviceInfo.TransportType], AEntry.DeviceInfo.Address);
end;

function TGameDeviceService.SelectedControlName: String;
var S: TDeviceSelection;
begin
  Result := '';
  if FSimulationEnabled then Exit;
  S := FAssignments.Selection[drControllable];
  if S.Mode <> dsmDevice then Exit;
  Result := S.Name;
  if Result = '' then Result := S.Address;
end;

function TGameDeviceService.ControlDisabled: Boolean;
begin
  Result := not FSimulationEnabled and (FAssignments.Selection[drControllable].Mode = dsmNone);
end;

procedure TGameDeviceService.ClearSensorsOfDevice(AEntry: TGameDeviceEntry);
var
  K: TSensorKind;
begin
  if not Assigned(AEntry) or not Assigned(AEntry.Sensors) then Exit;
  for K := Low(TSensorKind) to High(TSensorKind) do
    if Assigned(FActiveSensors[K]) and
       (AEntry.Sensors.IndexOf(FActiveSensors[K]) >= 0) then
      FActiveSensors[K] := nil;
end;

procedure TGameDeviceService.DoAutoAssign;
var
  K: TSensorKind;
  I: Integer;
  Entry: TGameDeviceEntry;
  S: TDeviceSensor;
  Changed: Boolean;
begin
  if FAssignmentsRefreshing or not FAssignmentsReady then Exit;
  if (FPendingDevice <> nil) and (FPendingDevice.ConnectionState = gdcsConnected) then
  begin
    Entry := FPendingDevice;
    FPendingDevice := nil;
    ApplyDeviceSelection(Entry);
  end;
  Changed := False;
  for K := Low(TSensorKind) to High(TSensorKind) do
  begin
    if Assigned(FActiveSensors[K]) then Continue;

    for I := 0 to FDevices.Count - 1 do
    begin
      Entry := FDevices[I];
      if Entry.ConnectionState <> gdcsConnected then Continue;
      if not IsTransportEnabledInGame(Entry.DeviceInfo.TransportType) then Continue;
      if not AcceptSimulationDevice(Entry.DeviceInfo) then Continue;
      if not FSimulationEnabled and not FAssignments.Allows(TDeviceRole(Ord(K)),
        TRANSPORT_TYPE_NAMES[Entry.DeviceInfo.TransportType], Entry.DeviceInfo.Address) then Continue;
      S := Entry.FindSensor(K);
      if Assigned(S) then
      begin
        FActiveSensors[K] := S;
        if not FSimulationEnabled then
          Changed := FAssignments.Select(TDeviceRole(Ord(K)),
            TRANSPORT_TYPE_NAMES[Entry.DeviceInfo.TransportType], Entry.DeviceInfo.Address,
            Entry.DeviceInfo.Name) or Changed;
        Log('Auto-assigned ' + SENSOR_KIND_NAMES[K] +
          ' <- ' + Entry.DisplayName);
        Break;
      end;
    end;
  end;

  { Автоназначение ControlDevice — первый подключённый тренажёр }
  if not Assigned(FControlDevice) then
    for I := 0 to FDevices.Count - 1 do
    begin
      Entry := FDevices[I];
      if (Entry.ConnectionState = gdcsConnected) and
         IsTransportEnabledInGame(Entry.DeviceInfo.TransportType) and
         AcceptSimulationDevice(Entry.DeviceInfo) and
         Entry.IsControllable and
         (FSimulationEnabled or FAssignments.Allows(drControllable,
           TRANSPORT_TYPE_NAMES[Entry.DeviceInfo.TransportType], Entry.DeviceInfo.Address)) then
      begin
        FControlDevice := Entry;
        if not FSimulationEnabled then
          Changed := FAssignments.Select(drControllable,
            TRANSPORT_TYPE_NAMES[Entry.DeviceInfo.TransportType], Entry.DeviceInfo.Address,
            Entry.DeviceInfo.Name) or Changed;
        Log('Auto-assigned control <- ' + Entry.DisplayName);
        { Pairing only chooses a device. The active ride owns load commands. }
        Break;
      end;
    end;
  if Changed then SaveAssignments;
end;

{ ── Публичный API: сканирование и подключение ── }

procedure TGameDeviceService.StartScan;
begin
  Log('Scan started');
  FManager.StartScan;
end;

procedure TGameDeviceService.StopScan;
begin
  Log('Scan stopped');
  FManager.StopScan;
end;

{ ── Автосканирование ── }

procedure TGameDeviceService.OnApplicationUpdate(Sender: TObject);
begin
  RefreshAssignmentsProfile;
  if Assigned(FManager) then
  begin
    FManager.Tick;
    if GetTickCount64-FLastHealthCheck>=1000 then
    begin FLastHealthCheck:=GetTickCount64; CheckStaleConnections end;
  end;
end;

procedure TGameDeviceService.EnableContinuousScan;
begin
  if FAutoScanStarted then Exit;
  FAutoScanStarted := True;
  ApplicationProperties.OnUpdate.Add(@OnApplicationUpdate);
  StartScan;
end;

procedure TGameDeviceService.DisableContinuousScan;
begin
  if not FAutoScanStarted then Exit;
  FAutoScanStarted := False;
  ApplicationProperties.OnUpdate.Remove(@OnApplicationUpdate);
  StopScan;
end;

procedure TGameDeviceService.CheckStaleConnections;
const
  { GATT discovery may contain several sequential 30-second operations.
    Never race the connect worker or destroy a COM handle it still owns. }
  CONNECTING_TIMEOUT_SEC = 90.0;
  ERROR_TIMEOUT_SEC = 30.0;
var
  I: Integer;
  Entry: TGameDeviceEntry;
  Changed: Boolean;
  AgeSec: Double;

  procedure ForceDisconnect(const AReason: String);
  begin
    Log(Format('%s: %s (was in state=%d for %.1fs)',
      [AReason, Entry.DisplayName, Ord(Entry.ConnectionState), AgeSec]));
    Entry.ConnectionState := gdcsDisconnected;
    Entry.LastStateChange := Now;
    Entry.LastMessage := AReason;
    ClearSensorsOfDevice(Entry);
    FManager.Disconnect(Entry.DeviceInfo.Address);
    Changed := True;
    if Assigned(FOnConnectionChanged) then
      FOnConnectionChanged(Entry);
  end;

begin
  Changed := False;
  for I := 0 to FDevices.Count - 1 do
  begin
    Entry := FDevices[I];
    if Entry.TestedNotFitness then Continue;

    AgeSec := (Now - Entry.LastStateChange) * 86400.0;

    case Entry.ConnectionState of
      gdcsConnected:
        if not FManager.IsSessionAlive(Entry.DeviceInfo.Address) then
          ForceDisconnect('Connection lost (health check)');

      gdcsConnecting:
        if (AgeSec > CONNECTING_TIMEOUT_SEC) and
          not FManager.IsConnecting(Entry.DeviceInfo.Address) then
          ForceDisconnect('Connect timeout');

      gdcsError:
        if AgeSec > ERROR_TIMEOUT_SEC then
          ForceDisconnect('Error state cleared');
    end;
  end;
  if Changed and Assigned(FOnDevicesChanged) then
    FOnDevicesChanged;
end;

procedure TGameDeviceService.ConnectDevice(AEntry: TGameDeviceEntry);
begin
  if not Assigned(AEntry) then Exit;
  if not AcceptSimulationDevice(AEntry.DeviceInfo) then Exit;

  { Симуляция: к игре подключаем только sim-устройство. Реальные BLE/ANT
    могут продолжать сканироваться и видеться в списке (пользователь
    может проверить что они доступны), но к сенсорам игры не привязываются.
    Это требование из task-описания: "при симуляции не подключать
    найденные датчики к игре". }
  if Settings.GetSimulationEnabled
     and (AEntry.DeviceInfo.TransportType <> ttSim) then
  begin
    Log(Format('Skip connect %s — simulation mode active',
      [AEntry.DisplayName]));
    Exit;
  end;

  FManager.Connect(AEntry.DeviceInfo.Address,
    AEntry.DisplayName,
    AEntry.DeviceInfo.ProviderName);
end;

procedure TGameDeviceService.DisconnectDevice(AEntry: TGameDeviceEntry);
begin
  if not Assigned(AEntry) then Exit;
  FManager.Disconnect(AEntry.DeviceInfo.Address);
end;

procedure TGameDeviceService.StartSimPlayback;
var
  Sim: TSimTransportSession;
begin
  FSimPlaybackWanted := True;
  if not Settings.GetSimulationEnabled then Exit;
  if FSimProvider = nil then Exit;
  Sim := FSimSession;
  if Sim = nil then
  begin
    Logger.Warning('[Sim] StartSimPlayback: no sim session connected');
    Exit;
  end;
  Sim.StartPlayback;
end;

procedure TGameDeviceService.StopSimPlayback;
var
  Sim: TSimTransportSession;
begin
  FSimPlaybackWanted := False;
  if FSimProvider = nil then Exit;
  Sim := FSimSession;
  if Sim = nil then Exit;
  Sim.StopPlayback;
end;

procedure TGameDeviceService.SimTogglePause;
var
  Sim: TSimTransportSession;
begin
  if FSimProvider = nil then Exit;
  Sim := FSimSession;
  if Sim = nil then Exit;
  Sim.SetPaused(not Sim.IsPaused);
end;

procedure TGameDeviceService.SimSetPaused(APaused: Boolean);
var
  Sim: TSimTransportSession;
begin
  if FSimProvider = nil then Exit;
  Sim := FSimSession;
  if Sim = nil then Exit;
  Sim.SetPaused(APaused);
end;

procedure TGameDeviceService.SimRestart;
begin SimSeekSec(0); SimSetPaused(False) end;

procedure TGameDeviceService.SimCycleSpeed(Slower: Boolean);
const Rates: array[0..8] of Single = (1/60,1/16,1/8,1/4,1/2,1,2,4,8);
var I: Integer; Rate: Single;
begin
  Rate:=SimGetSpeed;
  if Slower then begin
    for I:=High(Rates) downto 0 do if Rates[I]<Rate-0.000001 then begin SimSetSpeed(Rates[I]); Exit end;
  end else
    for I:=0 to High(Rates) do if Rates[I]>Rate+0.000001 then begin SimSetSpeed(Rates[I]); Exit end;
end;

function TGameDeviceService.SimGetSpeed: Single;
begin
  Result:=1;
  if (FSimProvider<>nil) and (FSimSession<>nil) then Result:=FSimSession.SpeedMul;
end;

procedure TGameDeviceService.SimSetSpeed(AMul: Single);
begin
  if (FSimProvider<>nil) and (FSimSession<>nil) then FSimSession.SetSpeedMul(AMul);
end;

procedure TGameDeviceService.SimSeekSec(ASec: Double);
begin
  if (FSimProvider=nil) or (FSimSession=nil) then Exit;
  if ASec<0 then ASec:=0;
  if Assigned(OnSimSeek) then OnSimSeek(ASec);
  FSimSession.SeekSec(ASec);
end;

function TGameDeviceService.SimAdvance(RealSeconds: Single): Single;
begin
  Result:=0;
  if (FSimProvider<>nil) and (FSimSession<>nil) then
    Result:=FSimSession.AdvancePlayback(RealSeconds);
end;

function TGameDeviceService.SimPositionSec: Double;
begin
  Result:=0;
  if (FSimProvider<>nil) and (FSimSession<>nil) then Result:=FSimSession.PositionSec;
end;

function TGameDeviceService.SimLoopSerial: Cardinal;
begin
  Result:=0;
  if (FSimProvider<>nil) and (FSimSession<>nil) then Result:=FSimSession.LoopSerial;
  Result:=Result xor (FSimGeneration shl 16);
end;

procedure TGameDeviceService.SimStepFrame;
begin
  if (FSimProvider<>nil) and (FSimSession<>nil) then FSimSession.StepFrame;
end;

procedure TGameDeviceService.SimPublishCurrent;
begin
  if (FSimProvider<>nil) and (FSimSession<>nil) then
    FSimSession.PublishCurrent;
end;

function TGameDeviceService.IsSimulationActive: Boolean;
var
  Sim: TSimTransportSession;
begin
  Result := False;
  if not Settings.GetSimulationEnabled then Exit;
  if FSimProvider = nil then Exit;
  Sim := FSimSession;
  if Sim = nil then Exit;
  Result := (Sim.ConnectionState = csConnected) and (Sim.RecordCount > 0);
end;

function TGameDeviceService.LastTrainerData: TTrainerDataRecord;
begin
  FillChar(Result, SizeOf(Result), 0);
  if Assigned(FControlDevice) then
    Result := FControlDevice.LastData;
end;

function TGameDeviceService.SimPlayerInfo(out APaused: Boolean;
  out ACurrentSec, ATotalSec: Integer): Boolean;

  procedure ReportReason(const R: String);
  begin
    if R = FSimLastReason then Exit;
    FSimLastReason := R;
    if R = '' then
      Logger.Info('[Sim] SimPlayerInfo: OK')
    else
      Logger.Warning('[Sim] SimPlayerInfo: ' + R);
  end;

var
  Sim: TSimTransportSession;
begin
  Result := False;
  APaused := False;
  ACurrentSec := 0;
  ATotalSec := 0;
  if not Settings.GetSimulationEnabled then
  begin
    ReportReason('simulation_disabled');
    Exit;
  end;
  if FSimProvider = nil then
  begin
    ReportReason('provider=nil');
    Exit;
  end;
  Sim := FSimSession;
  if Sim = nil then
  begin
    ReportReason('no_session — device not connected');
    Exit;
  end;
  if (Sim.ConnectionState <> csConnected) or (Sim.RecordCount = 0) then
  begin
    ReportReason('zero_records — FIT not loaded');
    Exit;
  end;
  APaused     := Sim.IsPaused;
  ACurrentSec := Trunc(Sim.PositionSec);
  ATotalSec   := Ceil(Sim.DurationSec);
  Result := True;
  ReportReason('');
end;

{ ── Назначение сенсоров ── }

procedure TGameDeviceService.AssignSensor(AKind: TSensorKind;
  ASensor: TDeviceSensor);
var E: TGameDeviceEntry; Changed: Boolean;
begin
  RefreshAssignmentsProfile;
  if not FAssignmentsReady then Exit;
  E := nil;
  if Assigned(ASensor) then
  begin
    if ASensor.SensorKind <> AKind then Exit;
    if FSimulationEnabled <> (Pos('sim:', ASensor.DeviceAddress) = 1) then Exit;
    if FSimulationEnabled and not SameFileName(ASensor.DeviceAddress,FSimAddress) then Exit;
    E := FindDeviceByAddress(ASensor.DeviceAddress);
    if (E = nil) or (E.FindSensor(AKind) <> ASensor) then Exit;
  end;
  Changed := False;
  if not FSimulationEnabled then
    if E = nil then Changed := FAssignments.Disable(TDeviceRole(Ord(AKind)))
    else Changed := FAssignments.Select(TDeviceRole(Ord(AKind)),
      TRANSPORT_TYPE_NAMES[E.DeviceInfo.TransportType], E.DeviceInfo.Address, E.DeviceInfo.Name);
  if (E <> nil) and (E.ConnectionState = gdcsConnected) then
    FActiveSensors[AKind] := ASensor
  else FActiveSensors[AKind] := nil;
  if Changed then SaveAssignments;
  if Assigned(ASensor) then
    Log('Assigned ' + SENSOR_KIND_NAMES[AKind] + ' <- ' +
      ASensor.DeviceName + ' (' + ASensor.DeviceAddress + ')')
  else
    Log('Cleared ' + SENSOR_KIND_NAMES[AKind]);
end;

procedure TGameDeviceService.ClearSensor(AKind: TSensorKind);
begin
  AssignSensor(AKind, nil);
end;

procedure TGameDeviceService.ClearAllSensors;
var K: TSensorKind;
begin
  for K := Low(TSensorKind) to High(TSensorKind) do
    FActiveSensors[K] := nil;
  if (FControlDevice <> nil) and (FManager <> nil) then
    FManager.CancelControl(FControlDevice.DeviceInfo.Address);
  FControlDevice := nil;
end;

procedure TGameDeviceService.AutoAssignSensors;
begin
  DoAutoAssign;
end;

{ ── Чтение активных сенсоров ── }

function TGameDeviceService.Sensor(AKind: TSensorKind): TDeviceSensor;
begin
  Result := FActiveSensors[AKind];
end;

function TGameDeviceService.HR: THRSensor;
begin
  Result := THRSensor(FActiveSensors[skHeartRate]);
end;

function TGameDeviceService.Power: TPowerSensor;
begin
  Result := TPowerSensor(FActiveSensors[skPower]);
end;

function TGameDeviceService.Cadence: TCadenceSensor;
begin
  Result := TCadenceSensor(FActiveSensors[skCadence]);
end;

function TGameDeviceService.Speed: TSpeedSensor;
begin
  Result := TSpeedSensor(FActiveSensors[skSpeed]);
end;

function TGameDeviceService.HasSensor(AKind: TSensorKind): Boolean;
begin
  Result := Assigned(FActiveSensors[AKind]) and
            FActiveSensors[AKind].HasData;
end;

function TGameDeviceService.HasAnySensor: Boolean;
var K: TSensorKind;
begin
  for K := Low(TSensorKind) to High(TSensorKind) do
    if HasSensor(K) then Exit(True);
  Result := False;
end;

function TGameDeviceService.AllSensorsOfKind(
  AKind: TSensorKind): TDeviceSensorList;
var
  I: Integer;
  S: TDeviceSensor;
begin
  Result := TDeviceSensorList.Create(False); { не владеет }
  for I := 0 to FDevices.Count - 1 do
  begin
    S := FDevices[I].FindSensor(AKind);
    if Assigned(S) then
      Result.Add(S);
  end;
end;

{ ── Управление тренажёром ── }

procedure TGameDeviceService.SetControlDevice(AEntry: TGameDeviceEntry);
var Changed: Boolean;
begin
  RefreshAssignmentsProfile;
  if not FAssignmentsReady then Exit;
  if Assigned(AEntry) and ((FSimulationEnabled <> (AEntry.DeviceInfo.TransportType=ttSim)) or
    not AcceptSimulationDevice(AEntry.DeviceInfo)) then Exit;
  if (AEntry <> nil) and not AEntry.IsControllable then Exit;
  if (FControlDevice <> nil) and (FControlDevice <> AEntry) then
    FManager.CancelControl(FControlDevice.DeviceInfo.Address);
  Changed := False;
  if not FSimulationEnabled then
    if AEntry = nil then Changed := FAssignments.Disable(drControllable)
    else Changed := FAssignments.Select(drControllable,
      TRANSPORT_TYPE_NAMES[AEntry.DeviceInfo.TransportType], AEntry.DeviceInfo.Address,
      AEntry.DeviceInfo.Name);
  FControlDevice := AEntry;
  if Changed then SaveAssignments;
  if Assigned(AEntry) then
  begin
    Log('Control device <- ' + AEntry.DisplayName);
  end;
end;

function TGameDeviceService.ActivitySourceFlags:Byte;
var P:TPowerSensor;E:TGameDeviceEntry;
begin
  if FSimulationEnabled then Exit(ActivitySourceSimulation);
  P:=Power;
  if(P=nil)or not P.HasData or(P.DataAgeSec>=3)then Exit(0);
  if Pos('sim:',P.DeviceAddress)=1 then Exit(ActivitySourceSimulation);
  E:=FindDeviceByAddress(P.DeviceAddress);
  if(E=nil)or(E.ConnectionState<>gdcsConnected)then Exit(0);
  if(E.DeviceInfo.TransportType=ttSim)then Exit(ActivitySourceSimulation);
  if E.IsControllable or(HasControlDevice and
    (FControlDevice.DeviceInfo.TransportType<>ttSim))then Exit(ActivitySourceSmartTrainer);
  Result:=ActivitySourceSensors;
end;

function TGameDeviceService.HasControlDevice: Boolean;
begin
  Result := Assigned(FControlDevice) and
            (FControlDevice.ConnectionState = gdcsConnected) and
            FControlDevice.IsControllable;
end;

function TGameDeviceService.ControlStatus: TTrainerControlStatus;
var Session: TTransportSession;
begin
  Result := Default(TTrainerControlStatus);
  Result.State := tcsUnavailable;
  if not HasControlDevice then Exit;
  Session := FManager.GetSession(FControlDevice.DeviceInfo.Address);
  if Session <> nil then Result := Session.ControlStatus;
end;

procedure TGameDeviceService.RequestControl;
begin
  if not HasControlDevice then Exit;
  FManager.RequestControl(FControlDevice.DeviceInfo.Address);
end;

procedure TGameDeviceService.SetTargetPower(APower: Word);
begin
  if not HasControlDevice then Exit;
  FManager.SetTargetPower(FControlDevice.DeviceInfo.Address, APower);
end;

procedure TGameDeviceService.SetResistanceLevel(ALevel: Byte);
begin
  if not HasControlDevice then Exit;
  FManager.SetResistanceLevel(FControlDevice.DeviceInfo.Address, ALevel);
end;

procedure TGameDeviceService.SetIncline(AIncline: Single);
begin
  if not HasControlDevice then Exit;
  FManager.SetIncline(FControlDevice.DeviceInfo.Address, AIncline);
end;

procedure TGameDeviceService.SetSimulation(AGrade, AWindSpeed, AUserWeight, ABikeWeight: Single);
begin
  if not HasControlDevice then Exit;
  FManager.SetSimulation(FControlDevice.DeviceInfo.Address, AGrade, AWindSpeed, AUserWeight, ABikeWeight);
end;

procedure TGameDeviceService.StartTrainer;
begin
  if not HasControlDevice then Exit;
  FManager.Start(FControlDevice.DeviceInfo.Address);
end;

procedure TGameDeviceService.PauseTrainer;
begin
  if not HasControlDevice then Exit;
  FManager.Pause(FControlDevice.DeviceInfo.Address);
end;

procedure TGameDeviceService.StopTrainer;
begin
  if not HasControlDevice then Exit;
  FManager.Stop(FControlDevice.DeviceInfo.Address);
end;

{ ── Сессия ── }

procedure TGameDeviceService.ResetSession;
var I: Integer;
begin
  for I := 0 to FDevices.Count - 1 do
    FDevices[I].ResetAllSensors;
  Log('Session reset');
end;

end.
