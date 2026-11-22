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
  GameDeviceSim, GameSteeringInput, GameAndroidControllerInput,
  AppSettings, DebugLog, GameVirtualGearing, GameControllerGears;

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
    { One physical transport hub; a context per local participant owns only
      bindings, control state and filtering. No duplicate BLE scans/feeds. }
    FLoadingRoster:Boolean;
    FHub: TGameDeviceService;
    FContexts: TList;
    FRiderIndex: Integer;
    function CanUseDevice(Entry:TGameDeviceEntry):Boolean;
    procedure ClaimDevice(Entry:TGameDeviceEntry);
    procedure ReconcileClaims;
    procedure ClearDeviceEverywhere(Entry:TGameDeviceEntry);
    procedure RefreshOtherRiders(Entry:TGameDeviceEntry; Connection:Boolean);
  private
    FSteeringInput, FCompanionInput, FGamepadInput: TSteeringInput;
    FAndroidGamepad: TAndroidControllerInput;
    FGamepadPendingTurn: Integer;
    FSteeringInputSensor: TDeviceSensor;
    FSteeringCompanion: TGameDeviceEntry;
    FSkipGamepadInput: Boolean;
    function ReadGamepadSteering(out Axis: Single): Boolean;
    procedure RefreshSteeringCompanion;
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
    FVirtualGear:Integer;
    FTrainerErgActive:Boolean;
    FGearPrimary,FGearCompanion:String;
    FGearCursor,FGearCompanionCursor:TControllerGearCursor;
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
    function IsTransportEnabledInGame(ATransport: TTransportType; Steering: Boolean = False): Boolean;

    procedure Log(const S: String);
    function MapState(const S: TConnectionState): TGameDeviceConnectionState;
  public
    constructor Create(Hub:TGameDeviceService=nil; RiderIndex:Integer=0);
    destructor Destroy; override;
    function ForRider(Index:Integer):TGameDeviceService;
    function DeviceOwner(Entry:TGameDeviceEntry):Integer;
    procedure TogglePowerMeter(Entry:TGameDeviceEntry);
    procedure ClearPowerMeters;
    procedure ClearSteeringControllers;
    function IsPowerMeterSelected(Entry:TGameDeviceEntry):Boolean;
    function ComparisonPowerText:String;
    function ComparisonPowerLineCount:Integer;
    property RiderIndex:Integer read FRiderIndex;

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
    procedure ConnectDevice(AEntry: TGameDeviceEntry; ExplicitRequest: Boolean = True);
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
    { The second BLE address is explicitly selected and saved per profile.
      No discovery-order pairing: nearby controllers never join a pair. }
    procedure SelectSteeringCompanion(AEntry: TGameDeviceEntry);
    function CanPairSteering(AEntry: TGameDeviceEntry): Boolean;
    function IsSteeringCompanion(AEntry: TGameDeviceEntry): Boolean;
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

    function ReadSteering(out Degrees: Single): Boolean;
    { Main thread, once per ride frame. Axis and Turn use +left / -right.
      Turn is an edge, never repeated while held. The ride owns its expiry. }
    function ReadSteeringInput(out Axis: Single; out Turn: Integer): Boolean;
    procedure ResetSteeringInput;
    procedure ReadControllerGears;
    function IsGearController(Entry:TGameDeviceEntry):Boolean;
    procedure SelectGearController(Entry:TGameDeviceEntry);
    procedure ShiftVirtualGear(Direction:Integer);
    function GearingBackend:TGearingBackend;
    procedure SetRideSimulation(Grade,Wind,RiderKg,BikeKg:Single);
    property VirtualGear:Integer read FVirtualGear;
    property TrainerErgActive:Boolean read FTrainerErgActive;
    function CenterSteering: Boolean;
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

uses Math, CastleGameControllers, CastleKeysMouse, EliteSterzoProtocol, ZwiftControllerProtocol,
  {$ifdef MSWINDOWS}WinRTBLEProvider, ANTPlus,{$endif}
  {$ifdef ANDROID}AndroidBLEProvider,{$endif}
  {$if (defined(LINUX) or defined(DARWIN)) and not defined(ANDROID)}SimpleBLEProvider,{$endif}
  CastleApplicationProperties, fpjson, GameUserData, GameRouteLibraryData, VeloSiteAPI;

{ ═══════════════════════════════════════════════════════════════════
  TGameDeviceService
  ═══════════════════════════════════════════════════════════════════ }

function TGameDeviceService.ForRider(Index:Integer):TGameDeviceService;
var Context:TGameDeviceService;
begin
  if FHub<>nil then Exit(FHub.ForRider(Index));
  if(Index<0)or(Index>=MaxLocalRiders)then raise ERangeError.Create('Device rider index');
  while FContexts.Count<=Index do begin
    Context:=TGameDeviceService.Create(Self,FContexts.Count);
    FContexts.Add(Context);Context.RefreshAssignmentsProfile;
  end;
  Result:=TGameDeviceService(FContexts[Index]);
end;

function TGameDeviceService.DeviceOwner(Entry:TGameDeviceEntry):Integer;
var I:Integer; C:TGameDeviceService;
begin
  if FHub<>nil then Exit(FHub.DeviceOwner(Entry));
  Result:=-1;if Entry=nil then Exit;
  for I:=0 to FContexts.Count-1 do begin
    C:=TGameDeviceService(FContexts[I]);
    if C.FPendingDevice=Entry then Exit(C.FRiderIndex);
    if C.FAssignments.UsesDevice(TRANSPORT_TYPE_NAMES[Entry.DeviceInfo.TransportType],
      Entry.DeviceInfo.Address)then Exit(C.FRiderIndex);
    if(Entry.DeviceInfo.TransportType=ttSim)and(C.FRiderIndex=0)and C.FSimulationEnabled then Exit(0);
  end;
end;

function TGameDeviceService.CanUseDevice(Entry:TGameDeviceEntry):Boolean;
var Owner:Integer;
begin
  Owner:=DeviceOwner(Entry);Result:=(Owner<0)or(Owner=FRiderIndex);
end;

procedure TGameDeviceService.ReconcileClaims;
var Seen:TStringList;Owners:array of Integer;I,J:Integer;R:TDeviceRole;
  C:TGameDeviceService;Changed:Boolean;Sel:TDeviceSelection;
  procedure Check(const Selection:TDeviceSelection);
  var Key:String;At,K:Integer;E:TGameDeviceEntry;
  begin
    if Selection.Mode<>dsmDevice then Exit;
    Key:=LowerCase(Trim(Selection.Transport))+'|'+LowerCase(Trim(Selection.Address));
    At:=Seen.IndexOf(Key);
    if At<0 then begin
      At:=Seen.Add(Key);SetLength(Owners,Seen.Count);Owners[At]:=C.FRiderIndex;
    end else if Owners[At]<>C.FRiderIndex then begin
      Changed:=C.FAssignments.RemoveDevice(Selection.Transport,Selection.Address)or Changed;
      for K:=0 to FDevices.Count-1 do begin
        E:=FDevices[K];
        if SameText(TRANSPORT_TYPE_NAMES[E.DeviceInfo.TransportType],Selection.Transport)and SameText(E.DeviceInfo.Address,Selection.Address)then begin
          C.ClearSensorsOfDevice(E);
          if C.FControlDevice=E then begin FManager.CancelControl(E.DeviceInfo.Address);C.FControlDevice:=nil end;
          if C.FPendingDevice=E then C.FPendingDevice:=nil;
        end;
      end;
    end;
  end;
begin
  if FHub<>nil then begin FHub.ReconcileClaims;Exit end;
  if FLoadingRoster then Exit;
  Seen:=TStringList.Create;
  try
    { A corrupt/copied profile file cannot make two riders share hardware.
      Existing explicit selections use ClaimDevice to move ownership; only
      conflicting restored state needs this deterministic first-rider rule. }
    for I:=0 to FContexts.Count-1 do begin
      C:=TGameDeviceService(FContexts[I]);Changed:=False;
      for R:=Low(TDeviceRole)to High(TDeviceRole)do Check(C.FAssignments.Selection[R]);
      for J:=C.FAssignments.PowerMeterCount-1 downto 0 do begin Sel:=C.FAssignments.PowerMeter(J);Check(Sel)end;
      if Changed then begin C.SaveAssignments;C.RefreshSteeringCompanion;end;
    end;
  finally Seen.Free;end;
end;

procedure TGameDeviceService.ClaimDevice(Entry:TGameDeviceEntry);
var Hub,C:TGameDeviceService;I:Integer;
begin
  if Entry=nil then Exit;
  Hub:=FHub;if Hub=nil then Hub:=Self;
  { Load remembered choices even for temporarily hidden local participants.
    An explicit reassignment removes their offline claim as well. }
  for I:=0 to MaxLocalRiders-1 do Hub.ForRider(I);
  for I:=0 to Hub.FContexts.Count-1 do begin
    C:=TGameDeviceService(Hub.FContexts[I]);if C=Self then Continue;
    if C.FPendingDevice=Entry then C.FPendingDevice:=nil;
    if C.FAssignments.RemoveDevice(TRANSPORT_TYPE_NAMES[Entry.DeviceInfo.TransportType],
      Entry.DeviceInfo.Address)then begin
      if C.FControlDevice=Entry then begin
        C.FManager.CancelControl(Entry.DeviceInfo.Address);
        C.FControlDevice:=nil;C.FTrainerErgActive:=False;
      end;
      if C.FPendingDevice=Entry then C.FPendingDevice:=nil;
      C.ClearSensorsOfDevice(Entry);C.RefreshSteeringCompanion;C.SaveAssignments;
      if Assigned(C.FOnDevicesChanged)then C.FOnDevicesChanged;
    end;
  end;
end;

procedure TGameDeviceService.ClearDeviceEverywhere(Entry:TGameDeviceEntry);
var I:Integer;C:TGameDeviceService;
begin
  if FHub<>nil then begin FHub.ClearDeviceEverywhere(Entry);Exit end;
  for I:=0 to FContexts.Count-1 do begin
    C:=TGameDeviceService(FContexts[I]);C.ClearSensorsOfDevice(Entry);
    if C.FControlDevice=Entry then begin C.FControlDevice:=nil;C.FTrainerErgActive:=False end;
  end;
end;

procedure TGameDeviceService.RefreshOtherRiders(Entry:TGameDeviceEntry;Connection:Boolean);
var I:Integer;K:TSensorKind;C:TGameDeviceService;
begin
  if FHub<>nil then Exit;
  for I:=1 to Min(LocalRiderCount,FContexts.Count)-1 do begin
    C:=TGameDeviceService(FContexts[I]);C.DoAutoAssign;C.RefreshSteeringCompanion;
    if Connection and Assigned(C.FOnConnectionChanged)then C.FOnConnectionChanged(Entry);
    if Connection and Assigned(C.FOnDevicesChanged)then C.FOnDevicesChanged;
    if Assigned(C.FOnSensorDataChanged)and Assigned(Entry.Sensors)then
      for K:=Low(TSensorKind)to High(TSensorKind)do
        if(C.FActiveSensors[K]<>nil)and(Entry.Sensors.IndexOf(C.FActiveSensors[K])>=0)then
          C.FOnSensorDataChanged(K);
  end;
end;

function TGameDeviceService.IsPowerMeterSelected(Entry:TGameDeviceEntry):Boolean;
begin
  Result:=(Entry<>nil)and(IsSensorSelected(skPower,Entry)or
    FAssignments.HasPowerMeter(TRANSPORT_TYPE_NAMES[Entry.DeviceInfo.TransportType],Entry.DeviceInfo.Address));
end;

procedure TGameDeviceService.TogglePowerMeter(Entry:TGameDeviceEntry);
var Transport:String;Next:TDeviceSelection;
begin
  if(Entry=nil)or(FDevices.IndexOf(Entry)<0)or not(Entry.DeviceInfo.SupportsPower or(Entry.FindSensor(skPower)<>nil))then Exit;
  RefreshAssignmentsProfile;
  Transport:=TRANSPORT_TYPE_NAMES[Entry.DeviceInfo.TransportType];
  if not FAssignmentsReady or not AcceptSimulationDevice(Entry.DeviceInfo)or
    (FSimulationEnabled<>(Entry.DeviceInfo.TransportType=ttSim))then Exit;
  if IsSensorSelected(skPower,Entry)then begin
    ClearSensor(skPower);
    if FAssignments.PowerMeterCount>0 then begin
      Next:=FAssignments.PowerMeter(0);
      FAssignments.Select(drPower,Next.Transport,Next.Address,Next.Name);
      DoAutoAssign;SaveAssignments;
    end;
  end
  else if FAssignments.RemovePowerMeter(Transport,Entry.DeviceInfo.Address)then SaveAssignments
  else begin
    if(FAssignments.Selection[drPower].Mode=dsmDevice)and(FAssignments.PowerMeterCount>=16)then Exit;
    ClaimDevice(Entry);
    if FAssignments.Selection[drPower].Mode<>dsmDevice then begin
      FAssignments.Select(drPower,Transport,Entry.DeviceInfo.Address,Entry.DisplayName);
      if Entry.ConnectionState=gdcsConnected then FActiveSensors[skPower]:=Entry.FindSensor(skPower);
    end else FAssignments.AddPowerMeter(Transport,Entry.DeviceInfo.Address,Entry.DisplayName);
    SaveAssignments;
    if Entry.ConnectionState<>gdcsConnected then ConnectDevice(Entry,False);
  end;
  if Assigned(FOnDevicesChanged)then FOnDevicesChanged;
end;

procedure TGameDeviceService.ClearPowerMeters;
begin
  RefreshAssignmentsProfile;if not FAssignmentsReady then Exit;
  FAssignments.ClearPowerMeters;FAssignments.Disable(drPower);FActiveSensors[skPower]:=nil;
  SaveAssignments;if Assigned(FOnDevicesChanged)then FOnDevicesChanged;
end;
procedure TGameDeviceService.ClearSteeringControllers;
begin
  RefreshAssignmentsProfile;if not FAssignmentsReady then Exit;
  FAssignments.Disable(drSteering);FAssignments.Disable(drSteeringCompanion);
  FAssignments.Disable(drShifting);FAssignments.Disable(drShiftingCompanion);
  FActiveSensors[skSteering]:=nil;FSteeringInputSensor:=nil;FSteeringCompanion:=nil;
  FSteeringInput.ForgetBLE;FCompanionInput.ForgetBLE;
  FGearPrimary:='';FGearCompanion:='';FGearCursor:=Default(TControllerGearCursor);FGearCompanionCursor:=Default(TControllerGearCursor);
  SaveAssignments;if Assigned(FOnDevicesChanged)then FOnDevicesChanged;
end;

function TGameDeviceService.ComparisonPowerLineCount:Integer;
begin Result:=FAssignments.PowerMeterCount end;

function TGameDeviceService.ComparisonPowerText:String;
var I,J:Integer;Sel:TDeviceSelection;E:TGameDeviceEntry;S,P:TDeviceSensor;D:Single;
  function CompactName(const Name:String):String;
  var K,Glyphs:Integer;
  begin
    K:=1;Glyphs:=0;
    while(K<=Length(Name))and(Glyphs<16)do begin
      Inc(K);while(K<=Length(Name))and((Ord(Name[K])and $C0)=$80)do Inc(K);
      Inc(Glyphs);
    end;
    Result:=Copy(Name,1,K-1);
  end;
begin
  Result:='';P:=Sensor(skPower);
  for I:=0 to FAssignments.PowerMeterCount-1 do begin
    Sel:=FAssignments.PowerMeter(I);E:=nil;
    for J:=0 to FDevices.Count-1 do
      if SameText(TRANSPORT_TYPE_NAMES[FDevices[J].DeviceInfo.TransportType],Sel.Transport)and
        SameText(FDevices[J].DeviceInfo.Address,Sel.Address)then begin E:=FDevices[J];Break end;
    if(E<>nil)and not CanUseDevice(E)then E:=nil;
    S:=nil;if(E<>nil)and(E.ConnectionState=gdcsConnected)then S:=E.FindSensor(skPower);
    if Result<>'' then Result:=Result+LineEnding;
    Result:=Result+CompactName(Sel.Name)+': ';
    if(S=nil)or not S.HasData or(S.DataAgeSec>=3)then begin Result:=Result+'--';Continue end;
    Result:=Result+IntToStr(Round(S.Instant))+' W';
    if(P<>nil)and P.HasData and(P.DataAgeSec<3)then begin
      D:=S.Instant-P.Instant;
      if D>=0 then Result:=Result+' (+' else Result:=Result+' (';
      Result:=Result+IntToStr(Round(D))+' W';
      if Abs(P.Instant)>=1 then Result:=Result+', '+FormatFloat('0.0',100*D/P.Instant)+'%';
      Result:=Result+')';
    end;
  end;
end;

constructor TGameDeviceService.Create(Hub:TGameDeviceService; RiderIndex:Integer);
var
  K: TSensorKind;
  IsolatedHardware: Boolean;
begin
  inherited Create;
  FHub:=Hub;FRiderIndex:=RiderIndex;
  FAssignments := TDeviceRoleAssignments.Create;
  FSteeringInput := TSteeringInput.Create;
  FCompanionInput := TSteeringInput.Create;
  FGamepadInput := TSteeringInput.Create;
  {$ifdef ANDROID}if FHub=nil then FAndroidGamepad:=TAndroidControllerInput.Create;{$endif}
  FAssignmentProfileId := Low(Int64);
  FVirtualGear:=DefaultVirtualGear;FAutoAssign:=True;FAutoConnect:=True;
  if FHub<>nil then begin
    FManager:=FHub.FManager;FDevices:=FHub.FDevices;
    FSkipGamepadInput:=True;FANTStickPresent:=FHub.FANTStickPresent;
    Exit;
  end;
  FContexts:=TList.Create;FContexts.Add(Self);
  FDevices := TGameDeviceList.Create(True);
  FControlDevice := nil;
  FVirtualGear:=DefaultVirtualGear;
  FAutoAssign := True;
  FAutoConnect := True;

  FAutoScanStarted := False;

  for K := Low(TSensorKind) to High(TSensorKind) do
    FActiveSensors[K] := nil;

  FManager := TDeviceManager.Create;

  IsolatedHardware:=(GetEnvironmentVariable('REZVIVO_TEST_AUTH_FILE')<>'') and
    (GetEnvironmentVariable('REZVIVO_TEST_NO_HARDWARE')='1');
  FSkipGamepadInput:=IsolatedHardware;
  if not IsolatedHardware then begin
  {$ifdef MSWINDOWS}
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
  {$endif}
  {$ifdef ANDROID}
  if AndroidBLEAvailable then
    FManager.RegisterProvider(TAndroidBLEProvider.Create);
  {$endif}
  {$if (defined(LINUX) or defined(DARWIN)) and not defined(ANDROID)}
  if SimpleBLEAvailable then
    FManager.RegisterProvider(TSimpleBLEProvider.Create);
  {$endif}
  end;

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
  FLoadingRoster:=True;
  try
    RefreshAssignmentsProfile;
    ForRider(MaxLocalRiders-1);
  finally FLoadingRoster:=False;end;
  ReconcileClaims;
  SimulationChanged(nil);
  DoAutoAssign;

end;

destructor TGameDeviceService.Destroy;
var
  K: TSensorKind;
  I:Integer;
begin
  if FHub=nil then begin
  if FContexts<>nil then begin
    for I:=FContexts.Count-1 downto 1 do TObject(FContexts[I]).Free;
    FreeAndNil(FContexts);
  end;
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
  end;

  for K := Low(TSensorKind) to High(TSensorKind) do
    FActiveSensors[K] := nil;
  FControlDevice := nil;

  if FHub=nil then begin FreeAndNil(FManager);FreeAndNil(FDevices) end;
  FreeAndNil(FAssignments);
  FreeAndNil(FSteeringInput);
  FreeAndNil(FCompanionInput);
  FreeAndNil(FGamepadInput);
  FreeAndNil(FAndroidGamepad);
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
  ATransport: TTransportType; Steering: Boolean): Boolean;
begin
  { BLE and ANT+ feed the same sensor slots and trainer-control interface.
    Only FIT simulation is exclusive; adapter availability and the saved
    per-role selection are checked by the manager/assignment layer. }
  if FSimulationEnabled then Result := (ATransport = ttSim) or Steering
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
  if FSimulationEnabled and (DeviceOwner(Entry)<=0) and
     (Entry.DeviceInfo.TransportType <> ttSim) and not Entry.DeviceInfo.SupportsSteering then
  begin
    Log(Format('Skip auto-connect %s — simulation mode active',
      [Entry.DisplayName]));
    Exit;
  end;

  { Auto-connect new devices, or reconnect known fitness devices }
  if FAutoConnect and
     ShouldAutoConnect(Entry) and
     (IsTransportEnabledInGame(Entry.DeviceInfo.TransportType, Entry.DeviceInfo.SupportsSteering) or
       ((DeviceOwner(Entry)>0)and(DeviceOwner(Entry)<LocalRiderCount))) and
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

    { A discovery probe may find a controller whose advertisement omitted UUIDs.
      Its queued notifications must not bypass explicit pairing. }
    if Device.SupportsShifting and (Entry.ConnectionState<>gdcsConnected) then Exit;

    if Entry.DiscoverMetrics(Data) then
    begin
      if FAutoAssign then DoAutoAssign;
      RefreshSteeringCompanion;
      if Assigned(FOnDevicesChanged) then FOnDevicesChanged;
    end;
    Entry.FeedData(Data);
    RefreshOtherRiders(Entry,False);

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
      ClearDeviceEverywhere(Entry);
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

  if (State=csConnected) and Device.SupportsShifting and
    not Entry.ControllerPairingRequested and (Entry<>FPendingDevice) and
    (DeviceOwner(Entry)<0) then
  begin
    ClearDeviceEverywhere(Entry);
    Entry.ConnectionState:=gdcsDisconnected;
    Entry.LastMessage:='Select this controller to use it';
    FManager.Disconnect(Device.Address);
    Log('Controller requires explicit pairing: '+Entry.DisplayName);
    if Assigned(FOnDevicesChanged) then FOnDevicesChanged;
    Exit;
  end;

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
      ClearDeviceEverywhere(Entry);
      Entry.RebuildSensors;
      Exclude(Entry.LastData.ValidMetrics,tmController);
      Entry.LastData.ControllerGeneration:=0;Entry.LastData.ControllerSerial:=0;
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
      if FAssignments.Matches(drShifting,TRANSPORT_TYPE_NAMES[Device.TransportType],Device.Address)then begin
        FGearPrimary:=Device.Address;FGearCursor:=Default(TControllerGearCursor);
      end;
      if FAssignments.Matches(drShiftingCompanion,TRANSPORT_TYPE_NAMES[Device.TransportType],Device.Address)then begin
        FGearCompanion:=Device.Address;FGearCompanionCursor:=Default(TControllerGearCursor);
      end;
    end;
    gdcsDisconnected:
    begin
      if (Device.TransportType = ttSim) and (FSimSession <> nil) and
        SameFileName(FSimSession.DeviceInfo.Address, Device.Address) then
        FSimSession := nil;
      Log(TRANSPORT_TYPE_NAMES[Device.TransportType] +
        ' disconnected: ' + Entry.DisplayName);
      ClearDeviceEverywhere(Entry);
      if FControlDevice = Entry then
        FControlDevice := nil;
      { Mark devices that were tested and found to be non-fitness }
      if Pos('Not a fitness', Message) > 0 then
        Entry.TestedNotFitness := True;
    end;
    gdcsError:
    begin
      ClearDeviceEverywhere(Entry);
      if FControlDevice=Entry then FControlDevice:=nil;
      Log(TRANSPORT_TYPE_NAMES[Device.TransportType] +
        ' error: ' + Entry.DisplayName + ' / ' + Message);
    end;
  end;

  RefreshSteeringCompanion;
  RefreshOtherRiders(Entry,True);
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
var Id: Int64; O: TJSONObject; I: Integer; E: TGameDeviceEntry; Api:TVeloSiteAPI;
begin
  if FAssignmentsRefreshing then Exit;
  Api:=RiderApi(FRiderIndex);
  Id := 0;
  if Api.IsAuthorized then
  begin
    Id := Api.CachedProfile.Id;
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
    FAssignments.Reset(not FAssignmentsReady or (FRiderIndex>0));
    if FAssignmentsReady then
    begin
      { The path is bound to this identity, not whichever account happens to
        be current later when a background connection finishes. }
      FAssignmentFile := RiderDataDir(FRiderIndex) + 'device-roles.json';
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
  if ((FHub=nil)and FLoadingRoster)or((FHub<>nil)and FHub.FLoadingRoster)then Exit;
  ReconcileClaims;
  DoAutoAssign;
  if FAutoConnect and FAssignmentsReady and(FRiderIndex<LocalRiderCount)then
    for I := 0 to FDevices.Count - 1 do
    begin
      E := FDevices[I];
      if (E.ConnectionState in [gdcsDisconnected, gdcsError]) and
        not E.TestedNotFitness and IsTransportEnabledInGame(E.DeviceInfo.TransportType, E.DeviceInfo.SupportsSteering) and
        ShouldAutoConnect(E) then ConnectDevice(E,False);
    end;
  if Assigned(FOnDevicesChanged) then FOnDevicesChanged;
end;

procedure TGameDeviceService.SaveAssignments;
var O: TJSONObject;
begin
  if not FAssignmentsReady or (FAssignmentFile = '') then Exit;
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
  if (FHub=nil) and (DeviceOwner(AEntry)>0) then Exit(DeviceOwner(AEntry)<LocalRiderCount);
  if not CanUseDevice(AEntry) then Exit;
  if FSimulationEnabled and not D.SupportsSteering then Exit(D.TransportType = ttSim);
  if D.TransportType = ttSim then Exit;
  if AEntry = FPendingDevice then Exit(True);
  { New controller pairing is explicit. Never claim nearby riders' remotes
    merely because a scan advertises a recognizable controller name. }
  if IsZwiftControllerName(D.Name) or D.SupportsShifting then
    Exit(FAssignments.UsesDevice(TRANSPORT_TYPE_NAMES[D.TransportType],D.Address));
  if not FAssignments.HasRemembered then Exit(True);
  if FAssignments.UsesDevice(TRANSPORT_TYPE_NAMES[D.TransportType], D.Address) then Exit(True);
  { After the first pairing, unknown fitness devices are only useful for an
    as-yet unassigned advertised role. A missing selected trainer is not a gap. }
  Result := (D.SupportsHeartRate and (FAssignments.Selection[drHeartRate].Mode = dsmAutomatic)) or
    (D.SupportsPower and (FAssignments.Selection[drPower].Mode = dsmAutomatic)) or
    (D.SupportsCadence and (FAssignments.Selection[drCadence].Mode = dsmAutomatic)) or
    (D.SupportsSteering and (FAssignments.Selection[drSteering].Mode = dsmAutomatic)) or
    (D.SupportsControl and (FAssignments.Selection[drControllable].Mode = dsmAutomatic));
end;

procedure TGameDeviceService.SelectDeviceForRoles(AEntry: TGameDeviceEntry);
begin
  RefreshAssignmentsProfile;
  if (AEntry = nil)or(FDevices.IndexOf(AEntry)<0)or not FAssignmentsReady or
    ((FSimulationEnabled <> (AEntry.DeviceInfo.TransportType = ttSim)) and not AEntry.DeviceInfo.SupportsSteering) or
    not AcceptSimulationDevice(AEntry.DeviceInfo) then Exit;
  FPendingDevice := AEntry;
  ClaimDevice(AEntry);
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

function TGameDeviceService.CanPairSteering(AEntry: TGameDeviceEntry): Boolean;
var Primary: TDeviceSelection;
begin
  Primary:=FAssignments.Selection[drSteering];
  Result:=(AEntry<>nil) and (Primary.Mode=dsmDevice) and
    IsZwiftControllerName(Primary.Name) and
    IsZwiftControllerName(AEntry.DeviceInfo.Name) and
    (AEntry.DeviceInfo.TransportType=ttBLE) and
    not FAssignments.Matches(drSteering,
      TRANSPORT_TYPE_NAMES[AEntry.DeviceInfo.TransportType],AEntry.DeviceInfo.Address);
end;

function TGameDeviceService.IsSteeringCompanion(AEntry: TGameDeviceEntry): Boolean;
begin
  Result:=(AEntry<>nil) and FAssignments.Matches(drSteeringCompanion,
    TRANSPORT_TYPE_NAMES[AEntry.DeviceInfo.TransportType],AEntry.DeviceInfo.Address);
end;

procedure TGameDeviceService.SelectSteeringCompanion(AEntry: TGameDeviceEntry);
begin
  RefreshAssignmentsProfile;
  if not FAssignmentsReady then Exit;
  if AEntry=nil then FAssignments.Disable(drSteeringCompanion)
  else begin
    if (FDevices.IndexOf(AEntry)<0) or not CanPairSteering(AEntry) then Exit;
    ClaimDevice(AEntry);
    FAssignments.Select(drSteeringCompanion,
      TRANSPORT_TYPE_NAMES[AEntry.DeviceInfo.TransportType],
      AEntry.DeviceInfo.Address,AEntry.DeviceInfo.Name);
  end;
  SaveAssignments;
  RefreshSteeringCompanion;
  if (AEntry<>nil) and (AEntry.ConnectionState in [gdcsDisconnected,gdcsError]) then
    ConnectDevice(AEntry);
  if Assigned(FOnDevicesChanged) then FOnDevicesChanged;
end;

procedure TGameDeviceService.RefreshSteeringCompanion;
var I: Integer; E, Selected: TGameDeviceEntry; S: TDeviceSensor;
begin
  Selected:=nil;
  if FAssignmentsReady and
    (FAssignments.Selection[drSteeringCompanion].Mode=dsmDevice) then
    for I:=0 to FDevices.Count-1 do begin
      E:=FDevices[I];
      if CanUseDevice(E)and IsSteeringCompanion(E) and CanPairSteering(E) and
        (E.ConnectionState=gdcsConnected) and (E.FindSensor(skSteering)<>nil) then
      begin Selected:=E; Break end;
    end;
  if FSteeringCompanion<>Selected then begin
    FSteeringCompanion:=Selected;
    FCompanionInput.ForgetBLE;
    { Selecting an already-connected half must not replay a button pressed
      before the user added it to this pair. Reconnect has no data yet. }
    if Selected<>nil then begin
      S:=Selected.FindSensor(skSteering);
      if S.HasData then FCompanionInput.Reset(SteeringAxis(S.Instant),0,
        Selected.LastData.SteeringTurnSerial);
    end;
  end;
end;

function TGameDeviceService.IsSensorSelected(AKind: TSensorKind;
  AEntry: TGameDeviceEntry): Boolean;
begin
  if AEntry = nil then Exit(False);
  if FSimulationEnabled and (AKind<>skSteering) then Exit((FActiveSensors[AKind] <> nil) and
    (AEntry.FindSensor(AKind) = FActiveSensors[AKind]));
  Result := FAssignments.Matches(TDeviceRole(Ord(AKind)),
    TRANSPORT_TYPE_NAMES[AEntry.DeviceInfo.TransportType], AEntry.DeviceInfo.Address);
end;

function TGameDeviceService.SelectedSensorName(AKind: TSensorKind): String;
var S: TDeviceSelection;
begin
  Result := '';
  if FSimulationEnabled and (AKind<>skSteering) then Exit;
  S := FAssignments.Selection[TDeviceRole(Ord(AKind))];
  if S.Mode <> dsmDevice then Exit;
  Result := S.Name;
  if Result = '' then Result := S.Address;
  if AKind=skSteering then begin
    S:=FAssignments.Selection[drSteeringCompanion];
    if S.Mode=dsmDevice then begin
      if S.Name='' then S.Name:=S.Address;
      Result:=Result+' + '+S.Name;
    end;
  end;
end;

function TGameDeviceService.SensorDisabled(AKind: TSensorKind): Boolean;
begin
  Result := (not FSimulationEnabled or (AKind=skSteering)) and
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
  if AEntry=nil then Exit;
  if FGearPrimary=AEntry.DeviceInfo.Address then begin FGearPrimary:='';FGearCursor:=Default(TControllerGearCursor);end;
  if FGearCompanion=AEntry.DeviceInfo.Address then begin FGearCompanion:='';FGearCompanionCursor:=Default(TControllerGearCursor);end;
  if FControlDevice=AEntry then FTrainerErgActive:=False;
  if not Assigned(AEntry) or not Assigned(AEntry.Sensors) then Exit;
  if FSteeringCompanion=AEntry then begin
    FSteeringCompanion:=nil; FCompanionInput.ForgetBLE;
  end;
  for K := Low(TSensorKind) to High(TSensorKind) do
    if Assigned(FActiveSensors[K]) and
       (AEntry.Sensors.IndexOf(FActiveSensors[K]) >= 0) then
    begin
      FActiveSensors[K] := nil;
      if K=skSteering then begin FSteeringInputSensor:=nil; FSteeringInput.ForgetBLE end;
    end;
end;

procedure TGameDeviceService.DoAutoAssign;
var
  K: TSensorKind;
  Role:TDeviceRole;
  I: Integer;
  Entry: TGameDeviceEntry;
  S: TDeviceSensor;
  Changed: Boolean;
begin
  if FAssignmentsRefreshing or not FAssignmentsReady or(FRiderIndex>=LocalRiderCount)then Exit;
  if ((FHub=nil)and FLoadingRoster)or((FHub<>nil)and FHub.FLoadingRoster)then Exit;
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
      if not CanUseDevice(Entry) then Continue;
      if Entry.ConnectionState <> gdcsConnected then Continue;
      if not IsTransportEnabledInGame(Entry.DeviceInfo.TransportType, Entry.DeviceInfo.SupportsSteering) then Continue;
      if not AcceptSimulationDevice(Entry.DeviceInfo) then Continue;
      if (FSimulationEnabled <> (Entry.DeviceInfo.TransportType=ttSim)) and (K<>skSteering) then Continue;
      if (not FSimulationEnabled or (K=skSteering)) and not FAssignments.Allows(TDeviceRole(Ord(K)),
        TRANSPORT_TYPE_NAMES[Entry.DeviceInfo.TransportType], Entry.DeviceInfo.Address) then Continue;
      S := Entry.FindSensor(K);
      if Assigned(S) then
      begin
        FActiveSensors[K] := S;
        if not FSimulationEnabled or (K=skSteering) then
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
      if not CanUseDevice(Entry) then Continue;
      if (Entry.ConnectionState = gdcsConnected) and
         IsTransportEnabledInGame(Entry.DeviceInfo.TransportType, Entry.DeviceInfo.SupportsSteering) and
         AcceptSimulationDevice(Entry.DeviceInfo) and
         Entry.IsControllable and
         (FSimulationEnabled = (Entry.DeviceInfo.TransportType=ttSim)) and
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
  { Controllers are connected explicitly, but their gear role is independent
    from steering: a STERZO and both Play halves can be used together. }
  for Role in[drShifting,drShiftingCompanion]do
    if FAssignments.Selection[Role].Mode=dsmAutomatic then
      for I:=0 to FDevices.Count-1 do begin
        Entry:=FDevices[I];
        if not CanUseDevice(Entry) then Continue;
        if(Entry.ConnectionState=gdcsConnected)and
          (IsZwiftControllerName(Entry.DeviceInfo.Name)or Entry.DeviceInfo.SupportsShifting)and
          not IsGearController(Entry)then begin
          Changed:=FAssignments.Select(Role,TRANSPORT_TYPE_NAMES[Entry.DeviceInfo.TransportType],
            Entry.DeviceInfo.Address,Entry.DeviceInfo.Name)or Changed;Break;
        end;
      end;
  if Changed then SaveAssignments;
  RefreshSteeringCompanion;
end;

{ ── Публичный API: сканирование и подключение ── }

procedure TGameDeviceService.StartScan;
begin
  if FHub<>nil then begin FHub.StartScan;Exit end;
  Log('Scan started');
  FManager.StartScan;
end;

procedure TGameDeviceService.StopScan;
begin
  if FHub<>nil then Exit;
  Log('Scan stopped');
  FManager.StopScan;
end;

{ ── Автосканирование ── }

procedure TGameDeviceService.OnApplicationUpdate(Sender: TObject);
var I:Integer; Context:TGameDeviceService;
begin
  if FHub<>nil then Exit;
  RefreshAssignmentsProfile;
  for I:=1 to LocalRiderCount-1 do ForRider(I).RefreshAssignmentsProfile;
  for I:=LocalRiderCount to FContexts.Count-1 do begin
    Context:=TGameDeviceService(FContexts[I]);
    if Context.FControlDevice<>nil then FManager.CancelControl(Context.FControlDevice.DeviceInfo.Address);
    Context.FTrainerErgActive:=False;Context.FPendingDevice:=nil;Context.ClearAllSensors;
  end;
  if Assigned(FManager) then
  begin
    FManager.Tick;
    ReadControllerGears;
    for I:=1 to LocalRiderCount-1 do begin
      Context:=ForRider(I);Context.ReadControllerGears;
    end;
    if GetTickCount64-FLastHealthCheck>=1000 then
    begin FLastHealthCheck:=GetTickCount64; CheckStaleConnections end;
  end;
end;

procedure TGameDeviceService.EnableContinuousScan;
begin
  if FHub<>nil then begin FHub.EnableContinuousScan;Exit end;
  if FAutoScanStarted then Exit;
  FAutoScanStarted := True;
  ApplicationProperties.OnUpdate.Add(@OnApplicationUpdate);
  StartScan;
end;

procedure TGameDeviceService.DisableContinuousScan;
begin
  if FHub<>nil then Exit;
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
    ClearDeviceEverywhere(Entry);
    FManager.Disconnect(Entry.DeviceInfo.Address);
    RefreshOtherRiders(Entry,True);
    Changed := True;
    if Assigned(FOnConnectionChanged) then
      FOnConnectionChanged(Entry);
  end;

begin
  if FHub<>nil then Exit;
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

procedure TGameDeviceService.ConnectDevice(AEntry: TGameDeviceEntry; ExplicitRequest: Boolean);
begin
  if not Assigned(AEntry) then Exit;
  if(FHub=nil)and(DeviceOwner(AEntry)>0)then begin
    ForRider(DeviceOwner(AEntry)).ConnectDevice(AEntry,ExplicitRequest);Exit;
  end;
  if not AcceptSimulationDevice(AEntry.DeviceInfo) then Exit;

  { Симуляция: к игре подключаем только sim-устройство. Реальные BLE/ANT
    могут продолжать сканироваться и видеться в списке (пользователь
    может проверить что они доступны), но к сенсорам игры не привязываются.
    Это требование из task-описания: "при симуляции не подключать
    найденные датчики к игре". }
  if FSimulationEnabled
     and (AEntry.DeviceInfo.TransportType <> ttSim) and not AEntry.DeviceInfo.SupportsSteering then
  begin
    Log(Format('Skip connect %s — simulation mode active',
      [AEntry.DisplayName]));
    Exit;
  end;

  if ExplicitRequest then AEntry.ControllerPairingRequested:=True;
  FManager.Connect(AEntry.DeviceInfo.Address,
    AEntry.DisplayName,
    AEntry.DeviceInfo.ProviderName);
end;

procedure TGameDeviceService.DisconnectDevice(AEntry: TGameDeviceEntry);
begin
  if(AEntry=nil)or not CanUseDevice(AEntry)then Exit;
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
var E:TGameDeviceEntry;Changed,PromotingComparison:Boolean;DeviceIndex:Integer;OldPower:TDeviceSelection;
begin
  RefreshAssignmentsProfile;
  if not FAssignmentsReady then Exit;
  E := nil;
  if Assigned(ASensor) then
  begin
    if ASensor.SensorKind <> AKind then Exit;
    if (AKind<>skSteering) and (FSimulationEnabled <> (Pos('sim:', ASensor.DeviceAddress) = 1)) then Exit;
    if FSimulationEnabled and (AKind<>skSteering) and not SameFileName(ASensor.DeviceAddress,FSimAddress) then Exit;
    E:=nil;
    for DeviceIndex:=0 to FDevices.Count-1 do
      if FDevices[DeviceIndex].FindSensor(AKind)=ASensor then begin E:=FDevices[DeviceIndex];Break end;
    if E=nil then Exit;
    ClaimDevice(E);
  end;
  Changed := False;
  OldPower:=FAssignments.Selection[drPower];
  PromotingComparison:=(AKind=skPower)and(E<>nil)and
    FAssignments.HasPowerMeter(TRANSPORT_TYPE_NAMES[E.DeviceInfo.TransportType],E.DeviceInfo.Address);
  { A replacement primary, or None, ends the old logical pair. Re-selecting
    the same primary leaves its companion intact. }
  if (AKind=skSteering) and ((E=nil) or not IsSensorSelected(skSteering,E)) then
    Changed:=FAssignments.Disable(drSteeringCompanion);
  if not FSimulationEnabled or (AKind=skSteering) then
    if E = nil then Changed := FAssignments.Disable(TDeviceRole(Ord(AKind))) or Changed
    else Changed := FAssignments.Select(TDeviceRole(Ord(AKind)),
      TRANSPORT_TYPE_NAMES[E.DeviceInfo.TransportType], E.DeviceInfo.Address, E.DeviceInfo.Name) or Changed;
  if PromotingComparison and(OldPower.Mode=dsmDevice)then
    Changed:=FAssignments.AddPowerMeter(OldPower.Transport,OldPower.Address,OldPower.Name)or Changed;
  if (E <> nil) and (E.ConnectionState = gdcsConnected) then
    FActiveSensors[AKind] := ASensor
  else FActiveSensors[AKind] := nil;
  if AKind=skSteering then RefreshSteeringCompanion;
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
  FTrainerErgActive:=False;
  FSteeringInputSensor:=nil; FSteeringInput.ForgetBLE;
  FSteeringCompanion:=nil; FCompanionInput.ForgetBLE;
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

function TGameDeviceService.ReadSteering(out Degrees: Single): Boolean;
var S: TDeviceSensor; E: TGameDeviceEntry;
begin
  Degrees:=0; S:=FActiveSensors[skSteering];
  { STERZO may notify only on changes. An unmoved handlebar is not signal
    loss: disconnection/health events clear the active slot instead. }
  Result:=(S<>nil) and S.HasData;
  if Result then
  begin
    Degrees:=S.Instant;
    E:=FindDeviceByAddress(S.DeviceAddress);
    if (E=nil) or not E.DeviceInfo.SupportsShifting then
      Degrees:=Degrees-FAssignments.SteeringCenter;
  end;
end;

function TGameDeviceService.CenterSteering: Boolean;
var S:TDeviceSensor; E:TGameDeviceEntry;
begin
  S:=FActiveSensors[skSteering];
  Result:=(S<>nil) and S.HasData;
  if Result then
  begin
    E:=FindDeviceByAddress(S.DeviceAddress);
    { OpenBikeControl angles are calibrated by the controller itself. }
    if (E<>nil) and (IsZwiftControllerName(E.DeviceInfo.Name) or E.DeviceInfo.SupportsShifting) then Exit(False);
  end;
  if Result then Result:=FAssignments.CenterSteering(S.Instant);
  if Result then begin SaveAssignments; ResetSteeringInput end;
end;

function TGameDeviceService.ReadGamepadSteering(out Axis: Single): Boolean;
var I: Integer; C: TGameController; V: Single;
begin
  Axis:=0;
  FGamepadPendingTurn:=0;
  if FSkipGamepadInput then Exit(False);
  if FAndroidGamepad<>nil then Exit(FAndroidGamepad.Read(Axis,FGamepadPendingTurn));
  { CGE owns polling and hotplug; never scan devices on every rendered frame. }
  if not Controllers.Initialized then Controllers.Initialize;
  Result:=Controllers.Count>0;
  for I:=0 to Controllers.Count-1 do
  begin
    C:=Controllers[I];
    V:=GamepadSteeringAxis(C.AxisLeft.X,C.Pressed[gbDPadLeft],C.Pressed[gbDPadRight]);
    if Abs(V)>Abs(Axis) then Axis:=V;
  end;
end;

function TGameDeviceService.ReadSteeringInput(out Axis: Single; out Turn: Integer): Boolean;
var Angle,PadAxis,PrimaryAxis,CompanionAxis,DummyAxis: Single;
  BLE,Pad,Companion: Boolean; E: TGameDeviceEntry; S: TDeviceSensor;
  Serial: Cardinal; Direction,CompanionTurn,PadTurn: Integer;
begin
  BLE:=ReadSteering(Angle);
  Pad:=ReadGamepadSteering(PadAxis);
  Serial:=0; Direction:=0;
  if FSteeringInputSensor<>FActiveSensors[skSteering] then
  begin
    FSteeringInput.ForgetBLE;
    FSteeringInputSensor:=FActiveSensors[skSteering];
  end;
  if BLE then
  begin
    E:=FindDeviceByAddress(FActiveSensors[skSteering].DeviceAddress);
    if E<>nil then
    begin Serial:=E.LastData.SteeringTurnSerial; Direction:=E.LastData.SteeringTurnDirection end;
  end;
  Result:=FSteeringInput.Read(BLE,SteeringAxis(Angle),Serial,Direction,
    False,0,PrimaryAxis,Turn);
  if BLE and(E<>nil)and Settings.GetVirtualGearingEnabled and
    E.LastData.ControllerShiftOnly then begin PrimaryAxis:=0;Turn:=0 end;

  { Old Play controllers advertise separate addresses, and each parser starts
    its own serial at one. Consume them independently before combining axes. }
  Companion:=False; Angle:=0; Serial:=0; Direction:=0;
  if FSteeringCompanion<>nil then begin
    S:=FSteeringCompanion.FindSensor(skSteering);
    Companion:=(S<>nil) and S.HasData;
    if Companion then begin
      Angle:=S.Instant;
      Serial:=FSteeringCompanion.LastData.SteeringTurnSerial;
      Direction:=FSteeringCompanion.LastData.SteeringTurnDirection;
    end;
  end;
  FCompanionInput.Read(Companion,SteeringAxis(Angle),Serial,Direction,
    False,0,CompanionAxis,CompanionTurn);
  if Companion and Settings.GetVirtualGearingEnabled and
    FSteeringCompanion.LastData.ControllerShiftOnly then begin CompanionAxis:=0;CompanionTurn:=0 end;
  FGamepadInput.Read(False,0,0,0,Pad,PadAxis,DummyAxis,PadTurn);
  Axis:=EnsureRange(PrimaryAxis+CompanionAxis,-1,1);
  if Abs(PadAxis)>Abs(Axis) then Axis:=PadAxis;
  if CompanionTurn<>0 then begin
    if (Turn<>0) and (Turn<>CompanionTurn) then Turn:=0
    else Turn:=CompanionTurn;
  end;
  if PadTurn<>0 then Turn:=PadTurn;
  if FGamepadPendingTurn<>0 then Turn:=FGamepadPendingTurn;
  Result:=Result or Companion or Pad;
end;

procedure TGameDeviceService.ResetSteeringInput;
var Angle,PadAxis: Single; E: TGameDeviceEntry; S:TDeviceSensor; Serial: Cardinal;
begin
  ReadSteering(Angle); ReadGamepadSteering(PadAxis); Serial:=0;
  FSteeringInputSensor:=FActiveSensors[skSteering];
  if FSteeringInputSensor<>nil then
  begin
    E:=FindDeviceByAddress(FSteeringInputSensor.DeviceAddress);
    if E<>nil then Serial:=E.LastData.SteeringTurnSerial;
  end;
  FSteeringInput.Reset(SteeringAxis(Angle),0,Serial);
  Angle:=0; Serial:=0;
  if FSteeringCompanion<>nil then begin
    S:=FSteeringCompanion.FindSensor(skSteering);
    if (S<>nil) and S.HasData then begin
      Angle:=S.Instant;
      Serial:=FSteeringCompanion.LastData.SteeringTurnSerial;
    end;
  end;
  FCompanionInput.Reset(SteeringAxis(Angle),0,Serial);
  FGamepadInput.Reset(0,PadAxis,0);
end;

procedure TGameDeviceService.ReadControllerGears;
var E,Other:TGameDeviceEntry;I:Integer;
  procedure Consume(Entry:TGameDeviceEntry;var Address:String;var Cursor:TControllerGearCursor);
  begin
    if(Entry=nil)or(Entry.ConnectionState<>gdcsConnected)then begin Address:='';Exit end;
    if Address<>Entry.DeviceInfo.Address then begin
      Address:=Entry.DeviceInfo.Address;PrimeControllerGears(Cursor,Entry.LastData);Exit;
    end;
    if Settings.GetVirtualGearingEnabled and not FTrainerErgActive then
      FVirtualGear:=ConsumeControllerGears(Cursor,Entry.LastData,FVirtualGear,VirtualGearCount)
    else PrimeControllerGears(Cursor,Entry.LastData);
  end;
begin
  E:=nil;Other:=nil;
  for I:=0 to FDevices.Count-1 do begin
    if not CanUseDevice(FDevices[I])then Continue;
    if FAssignments.Matches(drShifting,TRANSPORT_TYPE_NAMES[FDevices[I].DeviceInfo.TransportType],
      FDevices[I].DeviceInfo.Address)then E:=FDevices[I];
    if FAssignments.Matches(drShiftingCompanion,TRANSPORT_TYPE_NAMES[FDevices[I].DeviceInfo.TransportType],
      FDevices[I].DeviceInfo.Address)then Other:=FDevices[I];
  end;
  Consume(E,FGearPrimary,FGearCursor);
  Consume(Other,FGearCompanion,FGearCompanionCursor);
end;

function TGameDeviceService.IsGearController(Entry:TGameDeviceEntry):Boolean;
begin
  Result:=(Entry<>nil)and(
    FAssignments.Matches(drShifting,TRANSPORT_TYPE_NAMES[Entry.DeviceInfo.TransportType],Entry.DeviceInfo.Address)or
    FAssignments.Matches(drShiftingCompanion,TRANSPORT_TYPE_NAMES[Entry.DeviceInfo.TransportType],Entry.DeviceInfo.Address));
end;

procedure TGameDeviceService.SelectGearController(Entry:TGameDeviceEntry);
var Role:TDeviceRole;Transport:String;
begin
  if(Entry=nil)or(FDevices.IndexOf(Entry)<0)or
    not(IsZwiftControllerName(Entry.DeviceInfo.Name)or Entry.DeviceInfo.SupportsShifting)then Exit;
  RefreshAssignmentsProfile;if not FAssignmentsReady then Exit;
  Transport:=TRANSPORT_TYPE_NAMES[Entry.DeviceInfo.TransportType];
  if IsGearController(Entry)then begin
    for Role in[drShifting,drShiftingCompanion]do
      if FAssignments.Matches(Role,Transport,Entry.DeviceInfo.Address)then FAssignments.Disable(Role);
    for Role in[drShifting,drShiftingCompanion]do
      if FAssignments.Selection[Role].Mode=dsmAutomatic then FAssignments.Disable(Role);
  end else begin
    ClaimDevice(Entry);
    Role:=drShifting;
    if FAssignments.Selection[Role].Mode=dsmDevice then Role:=drShiftingCompanion;
    FAssignments.Select(Role,Transport,Entry.DeviceInfo.Address,Entry.DeviceInfo.Name);
  end;
  SaveAssignments;FGearPrimary:='';FGearCompanion:='';
  if Entry.ConnectionState in[gdcsDisconnected,gdcsError]then ConnectDevice(Entry);
  if Assigned(FOnDevicesChanged)then FOnDevicesChanged;
end;

procedure TGameDeviceService.ShiftVirtualGear(Direction:Integer);
begin
  if Settings.GetVirtualGearingEnabled and not FTrainerErgActive then
    FVirtualGear:=EnsureRange(FVirtualGear+EnsureRange(Direction,-1,1),1,VirtualGearCount);
end;

function TGameDeviceService.GearingBackend:TGearingBackend;
var S:TTransportSession;
begin
  Result:=gbOff;if not Settings.GetVirtualGearingEnabled then Exit;
  Result:=gbUnavailable;
  if not HasControlDevice or IsSimulationActive then Exit;
  S:=FManager.GetSession(FControlDevice.DeviceInfo.Address);if S=nil then Exit;
  if S.TrainerFeatures.SupportsVirtualGearing then Exit(gbNative);
  if S.TrainerFeatures.Known and S.TrainerFeatures.SupportsPowerControl then Result:=gbFTMSPower;
end;

procedure TGameDeviceService.SetRideSimulation(Grade,Wind,RiderKg,BikeKg:Single);
var S:TTransportSession;Load:TGearingLoad;RPM:Single;
begin
  case GearingBackend of
    gbNative: begin
      S:=FManager.GetSession(FControlDevice.DeviceInfo.Address);
      if S<>nil then S.QueueControl(tcGearedSimulation,Grade,Wind,RiderKg,BikeKg,VirtualGearRatio(FVirtualGear));
    end;
    gbFTMSPower: begin
      RPM:=0;
      if(Cadence<>nil)and Cadence.HasData and(Cadence.DataAgeSec<=3)then RPM:=Cadence.Instant;
      Load:=CalculateGearingLoad(FVirtualGear,RPM,Grade,Wind,RiderKg,BikeKg,Settings.GetWheelCircumferenceMm/1000);
      { Stale/absent cadence unloads the trainer. A fixed ERG target would
        otherwise get harder as the rider stops pedalling. }
      SetTargetPower(Round(Load.Watts));
    end;
    else SetSimulation(Grade,Wind,RiderKg,BikeKg);
  end;
  FTrainerErgActive:=False;
end;

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
  if (AEntry <> nil) and ((FDevices.IndexOf(AEntry)<0)or not AEntry.IsControllable) then Exit;
  ClaimDevice(AEntry);
  if (FControlDevice <> nil) and (FControlDevice <> AEntry) then
    FManager.CancelControl(FControlDevice.DeviceInfo.Address);
  Changed := False;
  if not FSimulationEnabled then
    if AEntry = nil then Changed := FAssignments.Disable(drControllable)
    else Changed := FAssignments.Select(drControllable,
      TRANSPORT_TYPE_NAMES[AEntry.DeviceInfo.TransportType], AEntry.DeviceInfo.Address,
      AEntry.DeviceInfo.Name);
  if FControlDevice<>AEntry then FTrainerErgActive:=False;
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
  Result := (FRiderIndex<LocalRiderCount)and Assigned(FControlDevice) and
            CanUseDevice(FControlDevice)and(FControlDevice.ConnectionState = gdcsConnected) and
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
  if not HasControlDevice then begin FTrainerErgActive:=False;Exit end;
  if FManager.SetTargetPower(FControlDevice.DeviceInfo.Address, APower) then
    FTrainerErgActive:=APower>0;
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
  FTrainerErgActive:=False;
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
  FTrainerErgActive:=False;
  if not HasControlDevice then Exit;
  FManager.Stop(FControlDevice.DeviceInfo.Address);
end;

{ ── Сессия ── }

procedure TGameDeviceService.ResetSession;
var I: Integer;
begin
  for I := 0 to FDevices.Count - 1 do
    if DeviceOwner(FDevices[I])=FRiderIndex then FDevices[I].ResetAllSensors;
  Log('Session reset');
end;

end.
