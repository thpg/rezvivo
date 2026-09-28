{ ANTPlus — поддержка ANT+ для подключения к велотренажёрам по
  профилю FE-C (Fitness Equipment Control, ANT+ device type 17).

  Состав юнита:
  - ANT message framing: encode/decode пакетов вида
        [SYNC=$A4][LEN][MSG_ID][PAYLOAD...][XOR_CHECKSUM].
  - FE-C page handlers: парсеры Page 16 (General FE Data) и
    Page 25 (Specific Trainer Data) → TTrainerDataRecord;
    билдеры команд Page 48/49/50/51.
  - TANTUsbBackend — абстракция над физическим USB-радио.
    Это точка расширения. Без зарегистрированного backend-класса
    провайдер компилируется и интегрируется в GameDeviceManager,
    но ничего не находит — ANTPlusAvailable возвращает False.
  - TANTSession / TANTProvider — наследники TTransportSession /
    TTransportProvider. Полная FE-C логика поверх backend-абстракции.

  Юнит сам по себе кроссплатформенный — зависит только от Classes,
  SysUtils, syncobjs, TrainerData, GameTransportBase, DebugLog. Реальная
  работа возможна там, где есть TANTUsbBackend-реализация (как правило
  Windows: Garmin USB-m / USB-2 стик). Без зарегистрированного backend
  ANTPlusAvailable=False, провайдер scan'a не находит устройств.

  Реализация TANTUsbBackend (отдельным юнитом-расширением):
  - Garmin ANT_DLL.dll через dynamic loading (требует копию DLL
    рядом с exe, см. Garmin ANT SDK)
  - Win32 serial port на \\.\COMx (стик enumerates как USB CDC ACM
    при установленном Dynastream-драйвере)
  - libusb через WinUSB-bindings

  Контракт реализации backend описан над объявлением TANTUsbBackend.
  Регистрация — через RegisterANTUsbBackendClass из секции
  initialization соответствующего юнита.

  Существующий ниже класс TANTManager — legacy-заглушка, оставлен
  для бинарной совместимости и нигде не используется новым кодом
  (Provider/Session). При необходимости можно удалить отдельно. }
unit ANTPlus;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, syncobjs,
  TrainerData, GameTransportBase, DebugLog, GameThreadWatch;

const
  // ─── ANT+ Device Types (профили) ───
  ANT_DEVICE_TYPE_HEART_RATE    = 120;
  ANT_DEVICE_TYPE_SPEED_CADENCE = 121;
  ANT_DEVICE_TYPE_CADENCE       = 122;
  ANT_DEVICE_TYPE_SPEED         = 123;
  ANT_DEVICE_TYPE_POWER         = 11;
  ANT_DEVICE_TYPE_FEC           = 17;  // Fitness Equipment Control

  // ─── ANT message protocol ───

  // SYNC byte начинающий каждый пакет ANT
  ANT_MSG_SYNC = $A4;

  // ANT message IDs (только используемые здесь — полный список см. в
  // ANT Message Protocol and Usage Rev 5.x от Dynastream)
  ANT_MSG_RESET_SYSTEM        = $4A;
  ANT_MSG_NETWORK_KEY         = $46;
  ANT_MSG_ASSIGN_CHANNEL      = $42;
  ANT_MSG_UNASSIGN_CHANNEL    = $41;
  ANT_MSG_CHANNEL_ID          = $51;
  ANT_MSG_CHANNEL_PERIOD      = $43;
  ANT_MSG_CHANNEL_RF_FREQ     = $45;
  ANT_MSG_CHANNEL_SEARCH_TO   = $44;
  ANT_MSG_OPEN_CHANNEL        = $4B;
  ANT_MSG_CLOSE_CHANNEL       = $4C;
  ANT_MSG_BROADCAST_DATA      = $4E;
  ANT_MSG_ACK_DATA            = $4F;
  ANT_MSG_RESPONSE_EVENT      = $40;
  ANT_MSG_REQUEST             = $4D;
  ANT_MSG_STARTUP             = $6F;

  // ─── Channel types ───
  ANT_CHTYPE_BIDIR_SLAVE  = $00;  // FE-C использует bidirectional slave
  ANT_CHTYPE_BIDIR_MASTER = $10;
  ANT_CHTYPE_RX_ONLY      = $40;

  // legacy aliases — preserved for compatibility
  ANT_CHANNEL_TYPE_SLAVE  = ANT_CHTYPE_BIDIR_SLAVE;
  ANT_CHANNEL_TYPE_MASTER = ANT_CHTYPE_BIDIR_MASTER;

  // ─── ANT+ Public Network Key ───
  // Публично документированный ключ для ВСЕХ ANT+ профилей (HR, Power,
  // Cadence, Speed, FE-C). Не требует регистрации в Garmin. Любая ANT+
  // Device Profile документация (ANT+ Common Pages, FE-C, Power Meter)
  // содержит этот ключ.
  ANTPLUS_NETWORK_KEY: array[0..7] of Byte = (
    $B9, $A5, $21, $FB, $BD, $72, $C3, $45);
  ANTPLUS_NETWORK_NUMBER = 0;

  // ─── FE-C profile parameters ───
  // (Согласно ANT+ Device Profile — Fitness Equipment, Rev 5.x)
  ANT_FEC_RF_FREQ        = 57;     // 2400 + 57 = 2457 MHz
  ANT_FEC_CHANNEL_PERIOD = 8192;   // 32768/8192 = 4 Hz broadcast rate
  ANT_FEC_TRANS_TYPE     = 0;      // 0 = pairing wildcard на стороне master

  // ─── FE-C Pages ───
  FEC_PAGE_GENERAL_FE_DATA    = 16;
  FEC_PAGE_GENERAL_SETTINGS   = 17;
  FEC_PAGE_SPECIFIC_TRAINER   = 25;
  FEC_PAGE_FE_CAPABILITIES    = 54;
  FEC_PAGE_USER_CONFIGURATION = 55;
  FEC_PAGE_REQUEST_DATA       = 70;
  FEC_PAGE_COMMAND_STATUS     = 71;
  FEC_PAGE_BASIC_RESISTANCE   = 48;
  FEC_PAGE_TARGET_POWER       = 49;
  FEC_PAGE_WIND_RESISTANCE    = 50;
  FEC_PAGE_TRACK_RESISTANCE   = 51;

  // ─── Provider/session ограничения ───
  // USB-стик имеет 8 каналов. Низкие индексы зарезервированы под параллельные
  // pairing-каналы (по одному на каждый интересующий ANT+ device-type), так
  // как у разных профилей разная channel-period и matching-window — на одном
  // канале их одновременно ловить нельзя. Остальные каналы — под активные
  // сессии (один на подключённое устройство).
  ANT_MAX_CHANNELS    = 8;
  ANT_PAIRING_FEC = 0;
  ANT_PAIRING_HRM = 1;
  ANT_PAIRING_SLOT_COUNT = 2;
  ANT_FIRST_SESSION_CHANNEL = ANT_PAIRING_SLOT_COUNT;  // 2..7 — сессии

  // Адресный префикс для адресов TDeviceInfo — отличает ANT+ устройства
  // от BLE по виду address-строки. Формат: 'ANT:<DeviceNumber>'
  // (DeviceNumber — uint16, выводится как десятичное число).
  ANT_ADDRESS_PREFIX = 'ANT:';

type
  // ─── Existing types preserved ───
  TANTFECData = record
    InstantPower: Word;
    AveragePower: Word;
    InstantCadence: Byte;
    InstantSpeed: Word;       // 0.001 m/s
    Distance: Cardinal;
    HeartRate: Byte;
    ElapsedTime: Word;
    Capabilities: Byte;
    EquipmentState: Byte;
  end;

  TANTDataCallback = procedure(const Data: TANTFECData) of object;

  // ─── ANT message frame (decoded) ───
  // После успешного decode из raw bytes остаются эти поля. PayloadLen —
  // длина MsgId-payload без sync/len/checksum (берётся из length-байта
  // пакета). Для броадкастов и команд данных payload = [Channel] +
  // [Page] + [PageData...] (8 байт суммарно), значит PayloadLen=9.
  TANTMessage = record
    MessageID: Byte;
    PayloadLen: Byte;
    Data: array[0..15] of Byte;
  end;

  // Идентификатор устройства на ANT-эфире (адрес внутри ANT-радиосистемы).
  TANTDeviceId = record
    DeviceNumber: Word;     // 0 = wildcard (pairing scan)
    DeviceType: Byte;       // ANT_DEVICE_TYPE_FEC для тренажёра
    TransmissionType: Byte; // обычно 0
  end;

  // Одна спецификация pairing-слота: какой канал стика, какой ANT+ профиль
  // на нём ищем, с какой channel-period. Все профили живут на ANT+ public
  // network (NETWORK_NUMBER=0) и на одной частоте (RF_FREQ=57 = 2457 MHz),
  // отличаются только period и device-type.
  TANTPairingSlotDef = record
    Channel: Byte;        // индекс канала на стике (0..7)
    DeviceType: Byte;     // ANT+ device-type для матчинга (17=FE-C, 120=HRM, ...)
    Period: Word;         // channel period (8192 для FE-C, 8070 для HRM, ...)
    Name: string;         // человекочитаемое имя для логов ('FE-C', 'HR')
  end;

const
  // Слоты для параллельного pairing-скана. Сейчас FE-C тренажёр и HR-ремень.
  // Можно добавить Power Meter (devType=11, period=8182), Speed/Cadence
  // (devType=121, period=8086), и т.д. — для них нужно ещё каналы и
  // соответствующее увеличение ANT_PAIRING_SLOT_COUNT/ANT_FIRST_SESSION_CHANNEL.
  ANT_PAIRING_SLOTS: array[0..ANT_PAIRING_SLOT_COUNT - 1] of TANTPairingSlotDef = (
    (Channel: ANT_PAIRING_FEC; DeviceType: ANT_DEVICE_TYPE_FEC;
     Period: 8192; Name: 'FE-C'),
    (Channel: ANT_PAIRING_HRM; DeviceType: ANT_DEVICE_TYPE_HEART_RATE;
     Period: 8070; Name: 'HR')
  );

type
  // forward declarations — нужны для cross-references между классами
  TANTUsbBackend = class;
  TANTUsbBackendClass = class of TANTUsbBackend;
  TANTSession = class;
  TANTProvider = class;

  // ─── TANTUsbBackend ───
  // Абстракция над физическим USB-радио. Конкретные реализации:
  // - TANTGarminDllBackend (юнит ANTPlusGarminDll) — обёртка над
  //   Garmin ANT_DLL.dll через dynamic loading. Каждый ANT message
  //   передаётся через ANT_SendBroadcast / ANT_AssignResponseFunction.
  // - TANTSerialBackend (юнит ANTPlusSerial) — Win32 serial port на
  //   \\.\COMx (стик enumerates как USB CDC ACM). Чтение через
  //   overlapped ReadFile с timeout.
  // - TANTLibUsbBackend (юнит ANTPlusLibUsb) — direct USB control
  //   transfers через libusb-1.0.dll.
  //
  // Контракт:
  // - Open: при первом вызове открывает стик. Должен:
  //   1) обнаружить и захватить USB-устройство (Dynastream VID $0FCF,
  //      PID $1008/$1009 для USB-m, $1004 для USB-2);
  //   2) отправить RESET_SYSTEM ($4A) с payload=$00, дождаться
  //      STARTUP ($6F) ответа (до 500мс);
  //   3) отправить NETWORK_KEY ($46) на network 0 с ANTPLUS_NETWORK_KEY;
  //      дождаться RESPONSE_EVENT с RESPONSE_NO_ERROR ($00).
  //   Возврат True, если все три шага успешны. False — если хоть один
  //   провалился; стик закрыть, FOpened=False.
  // - Close: закрыть и отпустить устройство.
  // - WriteMessage: упаковать в bytes через ANTEncodeMessage и отправить.
  //   Должен быть thread-safe (используется из нескольких сессий).
  // - ReadMessage: блокирующее чтение одного полного ANT-пакета с
  //   таймаутом. Должен корректно обрабатывать партlial reads и
  //   восстановление синхронизации после garbage.
  TANTUsbBackend = class
  protected
    FOpened: Boolean;
  public
    property Opened: Boolean read FOpened;

    constructor Create; virtual;
    destructor Destroy; override;

    function Open: Boolean; virtual; abstract;
    procedure Close; virtual; abstract;
    function WriteMessage(const AMsg: TANTMessage): Boolean; virtual; abstract;
    function ReadMessage(out AMsg: TANTMessage; ATimeoutMs: Cardinal): Boolean;
      virtual; abstract;

    // Краткое описание стика для логов (производитель, версия). Может
    // вернуть пустую строку — не критично.
    function ProductDescription: string; virtual;
  end;

  // ─── TANTProvider ───
  // Управляет единственным USB-радио (backend). Раздаёт каналы 1..7
  // активным сессиям, держит канал 0 под pairing scan. Запускает
  // единственный поток-диспетчер, читающий все ANT-пакеты от backend
  // и маршрутизирующий их по channel-byte:
  //   channel 0 → внутренняя scan-логика (репортит OnDeviceFound)
  //   channel 1..7 → соответствующая TANTSession.HandleMessage
  TANTProvider = class(TTransportProvider)
  private
    FBackend: TANTUsbBackend;
    FBackendOwned: Boolean;
    FLock: TCriticalSection;
    FDispatchThread: TThread;
    FDispatchRunning: Boolean;
    // Счётчик вложенных Pause-запросов. Когда > 0 — TANTDispatchThread
    // спит в своём loop'е и не делает bulk_read. Counter (а не bool) нужен
    // чтобы Pause/Resume пары вкладывались: Connect делает outer Pause
    // вокруг Configure (внутри тоже Pause) + ClosePairingChannel (тоже
    // Pause) — все три уровня корректно обрабатываются. Защищено FLock.
    FDispatcherPauseCount: Integer;
    FScanActive: Boolean;
    // Флаг per pairing-slot: «уже запросили CHANNEL_ID на этом слоте после
    // первого broadcast'а». ANT-стик при wildcard-match НЕ шлёт CHANNEL_ID
    // сам — host должен запросить через REQUEST_MESSAGE ($4D с payload
    // [Channel, $51]). Чтобы не спамить запросом на каждый приходящий
    // broadcast от того же мастера — отправляем только один раз. Флаг
    // сбрасывается в ConfigurePairingChannel/ClosePairingChannel и при
    // получении CHANNEL_ID с devNum=0 (wildcard ещё не закрепил мастера).
    FPairingIdRequested: array[0..ANT_PAIRING_SLOT_COUNT - 1] of Boolean;
    FChannelOwners: array[0..ANT_MAX_CHANNELS - 1] of TANTSession;
    FFoundDevices: array of TANTDeviceId;
    FFoundCount: Integer;
    function EnsureBackend: Boolean;
    function EnsureDispatcher: Boolean;
    procedure StopDispatcher;
    function ConfigurePairingChannel(ASlotIndex: Integer): Boolean;
    procedure ClosePairingChannel(ASlotIndex: Integer);
    function PairingSlotByChannel(AChannel: Byte; out ASlotIndex: Integer): Boolean;
    procedure PauseDispatcher;
    procedure ResumeDispatcher;
    function AlreadyFound(ADeviceNumber: Word): Boolean;
    procedure RecordFoundDevice(const ADevId: TANTDeviceId);
    procedure DispatchMessage(const AMsg: TANTMessage);
    procedure OnPairingMessage(const AMsg: TANTMessage);
    procedure NotifyDeviceFound(const ADevId: TANTDeviceId);
    // Заполняет TDeviceInfo (имя, capabilities) исходя из типа устройства.
    // Используется и в NotifyDeviceFound (на этапе scan'а), и в
    // CreateSession (чтобы FDeviceInfo сессии имел те же capability-flags
    // — без них Service.RebuildSensors при Connected даст 0 sensors и
    // карточка пропадёт из колонки HR/Power/Cadence).
    procedure FillDeviceInfoForType(var AInfo: TDeviceInfo;
      const ADevId: TANTDeviceId);
  public
    constructor Create; override;
    destructor Destroy; override;

    procedure StartScan; override;
    procedure StopScan; override;
    function CreateSession(const AAddress: string;
      const AFriendlyName: string = ''): TTransportSession; override;
    class function TransportType: TTransportType; override;
    function AdapterDisplayName: string; override;
    function AdapterKey: string; override;

    // Вызывается TANTSession для выделения/освобождения канала на стике
    // и публикации команды в backend. Все операции потокобезопасны.
    function AcquireChannel(ASession: TANTSession): Integer;
    procedure ReleaseChannel(AChannel: Integer);
    function SendAcknowledged(AChannel: Byte; const APage: array of Byte): Boolean;
  end;

  // ─── TANTSession ───
  // Одно подключение к ANT+ FE-C тренажёру. Bound to конкретный
  // DeviceNumber, использует один канал стика (выделяется провайдером).
  // НЕ владеет backend и не запускает свой read-thread — все приходящие
  // сообщения для этого канала маршрутизируются провайдером через
  // HandleMessage.
  TANTSession = class(TTransportSession)
  private
    FProvider: TANTProvider;
    FDeviceId: TANTDeviceId;
    FChannel: Integer;
    // Сериализует Connect/Disconnect/Configure-операции на одной сессии.
    // Без этого lock'а: если пользователь тапает Disconnect пока Connect
    // ещё в ConfigureFECChannel, второй поток обнуляет FChannel посреди
    // первого → присваивание `-1` в Byte-cell → range error. Lock делает
    // эти ветви взаимно блокирующими: Disconnect ждёт пока Connect
    // закончит свой configure-цикл, и наоборот.
    FOpLock: TCriticalSection;
    FAccumDistance: Cardinal;
    FLastDistanceRaw: Byte;
    FLastDistanceValid: Boolean;
    FFirstPacketLogged: Boolean;
    procedure ParseFECPage16(const APayload: array of Byte);
    procedure ParseFECPage25(const APayload: array of Byte);
    procedure ParseHRPage(const APayload: array of Byte);
    function ConfigureFECChannel: Boolean;
    function CloseFECChannel: Boolean;
    function LogPrefix: string;
  public
    property DeviceId: TANTDeviceId read FDeviceId;

    constructor Create(const AAddress: string; const AFriendlyName: string = ''); override;
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
    class function TransportType: TTransportType; override;

    // Вызывается TANTProvider.CreateSession после установки FDeviceId —
    // обновляет FDeviceInfo (имя + Supports*-флаги) под реальный тип
    // устройства. Внутри класса есть protected-доступ к FDeviceInfo;
    // сделано отдельным методом, чтобы провайдер не дёргал protected-
    // поля напрямую через границу unit'а.
    procedure ApplyCapabilities;

    // Вызывается провайдером из его dispatch-thread когда приходит
    // BROADCAST_DATA или ACK_DATA на канале этой сессии. Должен
    // отрабатывать быстро (без блокировки на I/O).
    procedure HandleMessage(const AMsg: TANTMessage);
  end;

  // Legacy-заглушка, оставлена для совместимости. НЕ используется
  // новым Provider/Session-кодом. При желании удалить — это безопасно.
  TANTManager = class
  private
    FConnected: Boolean;
    FOnData: TANTDataCallback;
  public
    property Connected: Boolean read FConnected;
    property OnData: TANTDataCallback read FOnData write FOnData;

    constructor Create;
    destructor Destroy; override;

    function Initialize: Boolean;
    function OpenChannel(DeviceType: Byte; DeviceNumber: Word): Boolean;
    procedure CloseChannel;

    function SetBasicResistance(Resistance: Byte): Boolean;
    function SetTargetPower(PowerWatts: Word): Boolean;
    function SetTrackResistance(Grade: SmallInt; RollingResistance: Byte): Boolean;
    function SetWindResistance(WindCoeff: Byte; WindSpeed: ShortInt;
      DraftingFactor: Byte): Boolean;
  end;

// ─── ANT framing (pure, testable) ───

// Упаковать TANTMessage в полный пакет [SYNC, LEN, MSG_ID, payload..., XOR_CHECKSUM].
// Гарантирует Result <> nil, Length(Result) >= 4 для допустимого PayloadLen.
// PayloadLen больше Data вызывает EArgumentOutOfRangeException.
function ANTEncodeMessage(const AMsg: TANTMessage): TBytes;

// Извлечь один ANT-пакет из ABytes начиная с AOffset. На выходе:
//   AMsg = распакованное сообщение (если Result=True),
//   ABytesConsumed = сколько байт потреблено от AOffset (включая sync
//                    и checksum), 0 если нужно ждать ещё байт.
// Возможные исходы:
//   Result=False, ABytesConsumed=0   → не хватает данных, ждать
//   Result=False, ABytesConsumed>0   → garbage пропущен (sync mismatch
//                                       или bad checksum), читать дальше
//   Result=True,  ABytesConsumed>0   → один пакет распакован
function ANTDecodeMessage(const ABytes: TBytes; AOffset: Integer;
  out AMsg: TANTMessage; out ABytesConsumed: Integer): Boolean;

// ─── FE-C page builders ───
// Возвращают APage длиной 8 байт с готовой страницей (Page ID в
// APage[0]). Эти 8 байт идут как payload в BROADCAST_DATA / ACK_DATA
// после channel-байта (см. TANTProvider.SendAcknowledged).

procedure ANTBuildPageBasicResistance(ResistanceLevel: Byte; out APage: TBytes);
procedure ANTBuildPageTargetPower(PowerWatts: Word; out APage: TBytes);
procedure ANTBuildPageWindResistance(WindCoeff: Byte; WindSpeedKmh: ShortInt;
  DraftingFactor: Byte; out APage: TBytes);
procedure ANTBuildPageTrackResistance(GradeHundredthsPercent: SmallInt;
  RollingResistance: Byte; out APage: TBytes);

// ─── Backend registration ───
// Зарегистрировать класс backend. После регистрации:
//   ANTPlusAvailable вернёт True если экземпляр AClass успешно
//   откроется (тестовый Open + Close при вызове ANTPlusAvailable).
// Повторная регистрация перезаписывает предыдущий класс.
procedure RegisterANTUsbBackendClass(AClass: TANTUsbBackendClass);

// Создать экземпляр зарегистрированного backend. Returns nil, если
// никто не зарегистрировался. Caller владеет результатом.
function CreateRegisteredANTBackend: TANTUsbBackend;

// Доступен ли ANT+ — есть ли зарегистрированный backend-класс и
// удаётся ли его временный экземпляр открыть. Без зарегистрированного
// backend всегда False.
function ANTPlusAvailable: Boolean;

implementation

// ═══════════════════════════════════════════════════════════════
// Глобальное состояние модуля
// ═══════════════════════════════════════════════════════════════

var
  GRegisteredBackendClass: TANTUsbBackendClass = nil;
  // Кешируем product string последнего успешно открытого backend'а —
  // нужен для UI (label на toggle adapter'а) до того как Provider будет
  // в открытом состоянии. Заполняется в ANTPlusAvailable test, читается
  // в TANTProvider.AdapterDisplayName когда FBackend ещё nil.
  GLastProductDescription: string = '';

// ═══════════════════════════════════════════════════════════════
// ANT framing — pure functions, тестируемые без backend
// ═══════════════════════════════════════════════════════════════

function ANTEncodeMessage(const AMsg: TANTMessage): TBytes;
var
  TotalLen, I: Integer;
  Checksum: Byte;
begin
  Result := nil;
  if AMsg.PayloadLen > Length(AMsg.Data) then
    raise EArgumentOutOfRangeException.CreateFmt(
      'ANT payload length %d exceeds buffer capacity %d',
      [AMsg.PayloadLen, Length(AMsg.Data)]);
  TotalLen := 4 + AMsg.PayloadLen;  // SYNC + LEN + MSG_ID + payload + CHECKSUM

  SetLength(Result, TotalLen);
  Result[0] := ANT_MSG_SYNC;
  Result[1] := AMsg.PayloadLen;
  Result[2] := AMsg.MessageID;
  for I := 0 to AMsg.PayloadLen - 1 do
    Result[3 + I] := AMsg.Data[I];

  Checksum := 0;
  for I := 0 to TotalLen - 2 do
    Checksum := Checksum xor Result[I];
  Result[TotalLen - 1] := Checksum;
end;

function ANTDecodeMessage(const ABytes: TBytes; AOffset: Integer;
  out AMsg: TANTMessage; out ABytesConsumed: Integer): Boolean;
var
  Available, ExpectedLen, I: Integer;
  Checksum: Byte;
begin
  Result := False;
  ABytesConsumed := 0;
  AMsg.MessageID := 0;
  AMsg.PayloadLen := 0;
  FillChar(AMsg.Data, SizeOf(AMsg.Data), 0);

  if (AOffset < 0) or (AOffset >= Length(ABytes)) then Exit;
  Available := Length(ABytes) - AOffset;
  if Available <= 0 then Exit;

  // Найти SYNC. Если первый байт не SYNC — пропускаем его как garbage,
  // возвращаем consumed=1, чтобы caller сдвинулся и пробовал дальше.
  if ABytes[AOffset] <> ANT_MSG_SYNC then
  begin
    ABytesConsumed := 1;
    Exit;
  end;

  // Минимум 4 байта на полный пакет: SYNC + LEN + MSG_ID + CHECKSUM.
  // LEN — это длина PAYLOAD (без MSG_ID и CHECKSUM).
  if Available < 4 then Exit;  // ждём ещё байт

  ExpectedLen := 4 + ABytes[AOffset + 1];  // total = sync+len+msgid+payload+crc
  if Available < ExpectedLen then Exit;     // ждём ещё байт

  // Проверка checksum (XOR всех байт включая SYNC, исключая сам checksum).
  Checksum := 0;
  for I := 0 to ExpectedLen - 2 do
    Checksum := Checksum xor ABytes[AOffset + I];

  if Checksum <> ABytes[AOffset + ExpectedLen - 1] then
  begin
    // Бракованный пакет — пропускаем 1 байт (re-sync), пусть caller
    // попробует с (AOffset+1).
    ABytesConsumed := 1;
    Exit;
  end;

  // Успех — распаковка
  AMsg.PayloadLen := ABytes[AOffset + 1];
  AMsg.MessageID  := ABytes[AOffset + 2];
  if AMsg.PayloadLen > Length(AMsg.Data) then
    AMsg.PayloadLen := Length(AMsg.Data);
  for I := 0 to AMsg.PayloadLen - 1 do
    AMsg.Data[I] := ABytes[AOffset + 3 + I];

  ABytesConsumed := ExpectedLen;
  Result := True;
end;

// ═══════════════════════════════════════════════════════════════
// FE-C page builders
// ═══════════════════════════════════════════════════════════════

procedure ANTBuildPageBasicResistance(ResistanceLevel: Byte; out APage: TBytes);
begin
  // Page 48 — Basic Resistance. Байты 1..6 reserved=$FF.
  // Байт 7 = total resistance, 0..200 (0.5% per unit).
  SetLength(APage, 8);
  APage[0] := FEC_PAGE_BASIC_RESISTANCE;
  APage[1] := $FF; APage[2] := $FF; APage[3] := $FF;
  APage[4] := $FF; APage[5] := $FF; APage[6] := $FF;
  if ResistanceLevel > 200 then ResistanceLevel := 200;
  APage[7] := ResistanceLevel;
end;

procedure ANTBuildPageTargetPower(PowerWatts: Word; out APage: TBytes);
var
  Quarter: Word;
begin
  // Page 49 — Target Power. Байты 1..5 reserved=$FF.
  // Байты 6..7 = target power little-endian, 0.25W/unit (так что
  // фактическое значение = PowerWatts*4).
  SetLength(APage, 8);
  APage[0] := FEC_PAGE_TARGET_POWER;
  APage[1] := $FF; APage[2] := $FF; APage[3] := $FF;
  APage[4] := $FF; APage[5] := $FF;
  Quarter := PowerWatts * 4;
  APage[6] := Lo(Quarter);
  APage[7] := Hi(Quarter);
end;

procedure ANTBuildPageWindResistance(WindCoeff: Byte; WindSpeedKmh: ShortInt;
  DraftingFactor: Byte; out APage: TBytes);
begin
  // Page 50 — Wind Resistance. Байты 1..4 reserved=$FF.
  // Байт 5 = wind resistance coefficient (kg/m, 0.01/unit, default $FF).
  // Байт 6 = wind speed (km/h, signed -127..+127 со смещением +127).
  // Байт 7 = drafting factor (0..100, 0.01/unit).
  SetLength(APage, 8);
  APage[0] := FEC_PAGE_WIND_RESISTANCE;
  APage[1] := $FF; APage[2] := $FF; APage[3] := $FF; APage[4] := $FF;
  APage[5] := WindCoeff;
  APage[6] := Byte(WindSpeedKmh + 127);
  APage[7] := DraftingFactor;
end;

procedure ANTBuildPageTrackResistance(GradeHundredthsPercent: SmallInt;
  RollingResistance: Byte; out APage: TBytes);
var
  GradeUnsigned: Word;
  GradeClamped: Integer;
begin
  // Page 51 — Track Resistance. Байты 1..4 reserved=$FF.
  // Байты 5..6 = grade в сотых долях процента, signed -200.00..+200.00,
  //              со смещением +200% перед записью (т.е. фактическое
  //              значение Grade+20000, диапазон 0..40000).
  // Байт 7 = rolling resistance coefficient, 5e-5 per unit (0..255).
  SetLength(APage, 8);
  APage[0] := FEC_PAGE_TRACK_RESISTANCE;
  APage[1] := $FF; APage[2] := $FF; APage[3] := $FF; APage[4] := $FF;

  GradeClamped := GradeHundredthsPercent;
  if GradeClamped < -20000 then GradeClamped := -20000;
  if GradeClamped >  20000 then GradeClamped :=  20000;
  GradeUnsigned := Word(GradeClamped + 20000);

  APage[5] := Lo(GradeUnsigned);
  APage[6] := Hi(GradeUnsigned);
  APage[7] := RollingResistance;
end;

// ═══════════════════════════════════════════════════════════════
// TANTUsbBackend — abstract base
// ═══════════════════════════════════════════════════════════════

constructor TANTUsbBackend.Create;
begin
  inherited Create;
  FOpened := False;
end;

destructor TANTUsbBackend.Destroy;
begin
  if FOpened then Close;
  inherited;
end;

function TANTUsbBackend.ProductDescription: string;
begin
  Result := '';
end;

// ═══════════════════════════════════════════════════════════════
// Backend registration
// ═══════════════════════════════════════════════════════════════

procedure RegisterANTUsbBackendClass(AClass: TANTUsbBackendClass);
begin
  GRegisteredBackendClass := AClass;
  if Assigned(Logger) then
  begin
    if AClass = nil then
      Logger.Info('[ANTPlus] Backend class unregistered')
    else
      Logger.Info('[ANTPlus] Backend class registered: ' + AClass.ClassName);
  end;
end;

function CreateRegisteredANTBackend: TANTUsbBackend;
begin
  if GRegisteredBackendClass = nil then
    Result := nil
  else
    Result := GRegisteredBackendClass.Create;
end;

// ═══════════════════════════════════════════════════════════════
// TANTProvider
// ═══════════════════════════════════════════════════════════════

type
  // Внутренний поток-диспетчер, читающий ANT-пакеты от backend и
  // передающий их в Provider.DispatchMessage. Один экземпляр на провайдер.
  TANTDispatchThread = class(TThread)
  private
    FProvider: TANTProvider;
  protected
    procedure Execute; override;
  public
    constructor Create(AProvider: TANTProvider);
  end;

constructor TANTDispatchThread.Create(AProvider: TANTProvider);
begin
  FProvider := AProvider;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TANTDispatchThread.Execute;
var
  Msg: TANTMessage;
begin
  while not Terminated do
  begin
    if (FProvider.FBackend = nil) or (not FProvider.FBackend.Opened) then
    begin
      Sleep(50);
      Continue;
    end;
    // Если кто-то запросил эксклюзивный режим записи (Configure/Close
    // session-канала) — спим, не входим в bulk_read. На USBStick2 +
    // libusb-win32 одновременный pending bulk_read и burst bulk_write
    // приводят к десяткам секунд задержек на каждом write. PauseDispatcher
    // ставит FDispatcherPaused и ждёт ~15мс, чтобы текущий цикл закончил
    // свой read и попал сюда. После ResumeDispatcher просыпаемся обратно
    // в loop и читаем накопленные RESPONSE_EVENT'ы и broadcast'ы.
    if FProvider.FDispatcherPauseCount > 0 then
    begin
      Sleep(5);
      Continue;
    end;
    // Короткий timeout — 10мс вместо 100мс. ReadMessage держит FIoLock
    // на время bulk_read; если write-thread (StartScan / SendAcknowledged)
    // ждёт того же lock'а, длинный read-timeout превращается в реальную
    // задержку команд по конвейеру. 10мс — компромисс между CPU usage
    // и responsiveness write-стороны.
    if FProvider.FBackend.ReadMessage(Msg, 10) then
      FProvider.DispatchMessage(Msg);
  end;
end;

constructor TANTProvider.Create;
var
  I: Integer;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FBackend := nil;
  FBackendOwned := False;
  FDispatchThread := nil;
  FDispatchRunning := False;
  FDispatcherPauseCount := 0;
  FScanActive := False;
  for I := 0 to ANT_MAX_CHANNELS - 1 do
    FChannelOwners[I] := nil;
  FFoundCount := 0;
  Logger.Info(Format('[ANTPlus] Provider created (channels=%d, pairing slots=%d)',
    [ANT_MAX_CHANNELS, ANT_PAIRING_SLOT_COUNT]));
end;

destructor TANTProvider.Destroy;
begin
  Logger.Info('[ANTPlus] Provider destroying — stopping scan and dispatcher');
  StopScan;
  StopDispatcher;

  if FBackendOwned and Assigned(FBackend) then
  begin
    Logger.Info('[ANTPlus] Closing owned backend');
    FBackend.Close;
    FBackend.Free;
  end;
  FBackend := nil;

  FreeAndNil(FLock);
  Logger.Info('[ANTPlus] Provider destroyed');
  inherited;
end;

class function TANTProvider.TransportType: TTransportType;
begin
  Result := ttANTPlus;
end;

function TANTProvider.AdapterDisplayName: string;
begin
  // Приоритет: открытый backend → cached product string из ANTPlusAvailable
  // → fallback. Это даёт нам наилучшее имя на любой стадии: UI показывается
  // и до Open (используем cache), и после (используем live product string).
  if (FBackend <> nil) and (FBackend.ProductDescription <> '') then
    Result := FBackend.ProductDescription
  else if GLastProductDescription <> '' then
    Result := GLastProductDescription
  else
    Result := 'ANT+ adapter';
end;

function TANTProvider.AdapterKey: string;
begin
  Result := AdapterDisplayName;
end;

function TANTProvider.EnsureBackend: Boolean;
begin
  Result := False;
  FLock.Enter;
  try
    if FBackend = nil then
    begin
      FBackend := CreateRegisteredANTBackend;
      FBackendOwned := True;
      if FBackend = nil then
      begin
        if Assigned(Logger) then
          Logger.Warning('[ANTPlus] No backend class registered — '
            + 'ANT+ provider cannot scan or connect');
        Exit;
      end;
    end;

    if not FBackend.Opened then
    begin
      if not FBackend.Open then
      begin
        if Assigned(Logger) then
          Logger.Warning('[ANTPlus] Backend.Open failed — no stick or driver issue');
        Exit;
      end;
      if Assigned(Logger) then
        Logger.Info('[ANTPlus] Backend opened: ' + FBackend.ProductDescription);
    end;

    Result := True;
  finally
    FLock.Leave;
  end;
end;

function TANTProvider.EnsureDispatcher: Boolean;
begin
  if FDispatchRunning and Assigned(FDispatchThread) then
    Exit(True);
  if not Assigned(FBackend) then
    Exit(False);
  FDispatchThread := TANTDispatchThread.Create(Self);
  FDispatchRunning := True;
  Logger.Info('[ANTPlus] Dispatch thread started');
  Result := True;
end;

procedure TANTProvider.StopDispatcher;
begin
  if Assigned(FDispatchThread) then
  begin
    Logger.Info('[ANTPlus] Stopping dispatch thread...');
    FDispatchThread.Terminate;
    ThreadWatch('ANTDispatch WaitFor BEGIN');
    FDispatchThread.WaitFor;
    ThreadWatch('ANTDispatch WaitFor END');
    FreeAndNil(FDispatchThread);
    Logger.Info('[ANTPlus] Dispatch thread stopped');
  end;
  FDispatchRunning := False;
end;

procedure TANTProvider.PauseDispatcher;
var
  WasFirst: Boolean;
begin
  // Re-entrant: каждый вызов Inc-ит counter под FLock. Только первый
  // вызов в цепочке делает Sleep(15) — даёт текущему bulk_read (timeout
  // 10мс) вернуться без данных и попасть в следующую iteration где
  // увидит counter > 0 и заснёт. Вложенные Pause просто increment'ят.
  if not FDispatchRunning then Exit;
  FLock.Enter;
  try
    Inc(FDispatcherPauseCount);
    WasFirst := FDispatcherPauseCount = 1;
  finally
    FLock.Leave;
  end;
  if WasFirst then Sleep(15);
end;

procedure TANTProvider.ResumeDispatcher;
begin
  // Dec counter; диспетчер просыпается только когда counter возвращается
  // в 0 — т.е. все вложенные Pause были закрыты соответствующими Resume.
  FLock.Enter;
  try
    if FDispatcherPauseCount > 0 then
      Dec(FDispatcherPauseCount);
  finally
    FLock.Leave;
  end;
end;

function TANTProvider.ConfigurePairingChannel(ASlotIndex: Integer): Boolean;
var
  Msg: TANTMessage;
  Slot: TANTPairingSlotDef;
begin
  Result := False;
  if not Assigned(FBackend) then Exit;
  if (ASlotIndex < 0) or (ASlotIndex >= ANT_PAIRING_SLOT_COUNT) then Exit;
  Slot := ANT_PAIRING_SLOTS[ASlotIndex];

  // Pause/Resume — нужны если configure вызывается с активным dispatcher
  // (например после Disconnect session'а: переоткрываем pairing slot).
  // В StartScan — dispatcher ещё не запущен, Pause просто early-return'ит.
  PauseDispatcher;
  try
    Logger.Info(Format('[ANTPlus] >>> ConfigurePairingChannel ch=%d (%s wildcard scan)',
      [Slot.Channel, Slot.Name]));

    // Сбрасываем флаг этого слота: новая сессия скана — снова разрешено
    // отправить REQUEST_MESSAGE при первом broadcast'е.
    FPairingIdRequested[ASlotIndex] := False;

  // Между командами — короткая пауза (20мс). Старые/слабые ANT-стики
  // (ANT USBStick2) часто не успевают переварить burst команд и могут
  // подвиснуть на bulk_write. Пауза также даёт dispatch thread'у время
  // вычитать ответ (RESPONSE_EVENT) с предыдущей команды и не держать
  // FIoLock через next-write contention.

  // Шаг 1: ASSIGN_CHANNEL — type=BIDIR_SLAVE, network=0
  FillChar(Msg, SizeOf(Msg), 0);
  Msg.MessageID := ANT_MSG_ASSIGN_CHANNEL;
  Msg.PayloadLen := 3;
  Msg.Data[0] := Slot.Channel;
  Msg.Data[1] := ANT_CHTYPE_BIDIR_SLAVE;
  Msg.Data[2] := ANTPLUS_NETWORK_NUMBER;
  if not FBackend.WriteMessage(Msg) then
  begin
    Logger.Warning(Format('[ANTPlus] %s pairing: ASSIGN_CHANNEL write failed', [Slot.Name]));
    Exit;
  end;
  Logger.Info(Format('[ANTPlus] %s pairing: ASSIGN_CHANNEL ok', [Slot.Name]));
  Sleep(20);

  // Шаг 2: SET_CHANNEL_ID — wildcard (devNum=0, devType=Slot.DeviceType, transType=0)
  FillChar(Msg, SizeOf(Msg), 0);
  Msg.MessageID := ANT_MSG_CHANNEL_ID;
  Msg.PayloadLen := 5;
  Msg.Data[0] := Slot.Channel;
  Msg.Data[1] := 0;  // devNum LSB
  Msg.Data[2] := 0;  // devNum MSB
  Msg.Data[3] := Slot.DeviceType;
  Msg.Data[4] := 0;  // transType wildcard
  if not FBackend.WriteMessage(Msg) then
  begin
    Logger.Warning(Format('[ANTPlus] %s pairing: CHANNEL_ID write failed', [Slot.Name]));
    Exit;
  end;
  Logger.Info(Format('[ANTPlus] %s pairing: CHANNEL_ID wildcard devType=%d ok',
    [Slot.Name, Slot.DeviceType]));
  Sleep(20);

  // Шаг 3: CHANNEL_RF_FREQ — все ANT+ профили на 2457 MHz
  FillChar(Msg, SizeOf(Msg), 0);
  Msg.MessageID := ANT_MSG_CHANNEL_RF_FREQ;
  Msg.PayloadLen := 2;
  Msg.Data[0] := Slot.Channel;
  Msg.Data[1] := ANT_FEC_RF_FREQ;
  if not FBackend.WriteMessage(Msg) then
  begin
    Logger.Warning(Format('[ANTPlus] %s pairing: RF_FREQ write failed', [Slot.Name]));
    Exit;
  end;
  Logger.Info(Format('[ANTPlus] %s pairing: RF_FREQ=%d (2400+%dMHz) ok',
    [Slot.Name, ANT_FEC_RF_FREQ, ANT_FEC_RF_FREQ]));
  Sleep(20);

  // Шаг 4: CHANNEL_PERIOD — индивидуальный для каждого профиля
  FillChar(Msg, SizeOf(Msg), 0);
  Msg.MessageID := ANT_MSG_CHANNEL_PERIOD;
  Msg.PayloadLen := 3;
  Msg.Data[0] := Slot.Channel;
  Msg.Data[1] := Lo(Slot.Period);
  Msg.Data[2] := Hi(Slot.Period);
  if not FBackend.WriteMessage(Msg) then
  begin
    Logger.Warning(Format('[ANTPlus] %s pairing: CHANNEL_PERIOD write failed', [Slot.Name]));
    Exit;
  end;
  Logger.Info(Format('[ANTPlus] %s pairing: PERIOD=%d (%.2fHz) ok',
    [Slot.Name, Slot.Period, 32768 / Slot.Period]));
  Sleep(20);

  // Шаг 5: SEARCH_TIMEOUT — поиск без ограничения (0xFF = infinite)
  FillChar(Msg, SizeOf(Msg), 0);
  Msg.MessageID := ANT_MSG_CHANNEL_SEARCH_TO;
  Msg.PayloadLen := 2;
  Msg.Data[0] := Slot.Channel;
  Msg.Data[1] := $FF;
  if not FBackend.WriteMessage(Msg) then
  begin
    Logger.Warning(Format('[ANTPlus] %s pairing: SEARCH_TIMEOUT write failed', [Slot.Name]));
    Exit;
  end;
  Logger.Info(Format('[ANTPlus] %s pairing: SEARCH_TIMEOUT=infinite ok', [Slot.Name]));
  Sleep(20);

  // Шаг 6: OPEN_CHANNEL
  FillChar(Msg, SizeOf(Msg), 0);
  Msg.MessageID := ANT_MSG_OPEN_CHANNEL;
  Msg.PayloadLen := 1;
  Msg.Data[0] := Slot.Channel;
  if not FBackend.WriteMessage(Msg) then
  begin
    Logger.Warning(Format('[ANTPlus] %s pairing: OPEN_CHANNEL write failed', [Slot.Name]));
    Exit;
  end;
  Logger.Info(Format('[ANTPlus] %s pairing: OPEN_CHANNEL ok — channel listening', [Slot.Name]));

  Result := True;
  finally
    ResumeDispatcher;
  end;
end;

procedure TANTProvider.ClosePairingChannel(ASlotIndex: Integer);
var
  Msg: TANTMessage;
  Slot: TANTPairingSlotDef;
begin
  if not Assigned(FBackend) then Exit;
  if not FBackend.Opened then Exit;
  if (ASlotIndex < 0) or (ASlotIndex >= ANT_PAIRING_SLOT_COUNT) then Exit;
  Slot := ANT_PAIRING_SLOTS[ASlotIndex];

  // См. комментарий в ConfigurePairingChannel — Pause/Resume для случая
  // когда close вызывается с активным dispatcher'ом (Connect session
  // закрывает свой pairing slot чтобы освободить эфир от двойного slave).
  PauseDispatcher;
  try
    Logger.Info(Format('[ANTPlus] ClosePairingChannel ch=%d (%s)', [Slot.Channel, Slot.Name]));

    FPairingIdRequested[ASlotIndex] := False;

    FillChar(Msg, SizeOf(Msg), 0);
    Msg.MessageID := ANT_MSG_CLOSE_CHANNEL;
    Msg.PayloadLen := 1;
    Msg.Data[0] := Slot.Channel;
    if not FBackend.WriteMessage(Msg) then
      Logger.Warning(Format('[ANTPlus] %s ClosePairingChannel: CLOSE write failed', [Slot.Name]));

    FillChar(Msg, SizeOf(Msg), 0);
    Msg.MessageID := ANT_MSG_UNASSIGN_CHANNEL;
    Msg.PayloadLen := 1;
    Msg.Data[0] := Slot.Channel;
    if not FBackend.WriteMessage(Msg) then
      Logger.Warning(Format('[ANTPlus] %s ClosePairingChannel: UNASSIGN write failed', [Slot.Name]));
  finally
    ResumeDispatcher;
  end;
end;

function TANTProvider.PairingSlotByChannel(AChannel: Byte; out ASlotIndex: Integer): Boolean;
var
  I: Integer;
begin
  Result := False;
  ASlotIndex := -1;
  for I := 0 to ANT_PAIRING_SLOT_COUNT - 1 do
    if ANT_PAIRING_SLOTS[I].Channel = AChannel then
    begin
      ASlotIndex := I;
      Exit(True);
    end;
end;

procedure TANTProvider.StartScan;
var
  I: Integer;
  AnyOk: Boolean;
begin
  if FScanActive then Exit;

  if not EnsureBackend then
  begin
    if Assigned(Logger) then
      Logger.Info('[ANTPlus] StartScan: backend unavailable, no devices will be reported');
    Exit;
  end;

  // ВАЖНО: dispatch thread стартует ПОСЛЕ всех ConfigurePairingChannel.
  // Если стартовать его раньше, на старом USB Stick2 (libusb-win32) bulk_write
  // следующей команды конфига зависает: видимо driver/firmware не любит
  // одновременного активного pending bulk_read на IN-endpoint и быстрого
  // bulk_write последовательно на OUT-endpoint. Поэтому конфиг делаем
  // sequential-only без активного reader'а: ~6 write'ов на slot, ответы
  // (RESPONSE_EVENT на каждый) накапливаются в pipe-буфере. До OPEN_CHANNEL
  // никаких broadcast'ов не идёт. После всех OPEN_CHANNEL запускаем dispatch
  // thread, и он зачитывает накопленные ответы + дальнейшие broadcast'ы.
  AnyOk := False;
  for I := 0 to ANT_PAIRING_SLOT_COUNT - 1 do
    if ConfigurePairingChannel(I) then
      AnyOk := True
    else if Assigned(Logger) then
      Logger.Warning(Format('[ANTPlus] StartScan: failed to open %s pairing slot',
        [ANT_PAIRING_SLOTS[I].Name]));

  if not AnyOk then
  begin
    if Assigned(Logger) then
      Logger.Warning('[ANTPlus] StartScan: no pairing slot opened — scan aborted');
    Exit;
  end;

  if not EnsureDispatcher then Exit;

  FFoundCount := 0;
  FScanActive := True;
  if Assigned(Logger) then
    Logger.Info(Format('[ANTPlus] StartScan: %d pairing slot(s) open, listening for masters',
      [ANT_PAIRING_SLOT_COUNT]));
end;

procedure TANTProvider.StopScan;
var
  I: Integer;
begin
  if not FScanActive then Exit;
  for I := 0 to ANT_PAIRING_SLOT_COUNT - 1 do
    ClosePairingChannel(I);
  FScanActive := False;
  if Assigned(Logger) then
    Logger.Info('[ANTPlus] StopScan');
end;

function TANTProvider.AlreadyFound(ADeviceNumber: Word): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to FFoundCount - 1 do
    if FFoundDevices[I].DeviceNumber = ADeviceNumber then
      Exit(True);
end;

procedure TANTProvider.RecordFoundDevice(const ADevId: TANTDeviceId);
begin
  if Length(FFoundDevices) <= FFoundCount then
    SetLength(FFoundDevices, FFoundCount + 8);
  FFoundDevices[FFoundCount] := ADevId;
  Inc(FFoundCount);
end;

procedure TANTProvider.FillDeviceInfoForType(var AInfo: TDeviceInfo;
  const ADevId: TANTDeviceId);
begin
  // По device-type определяем человекочитаемое имя и какие сенсорные
  // колонки на UI будет занимать карточка. Без правильных Supports*-
  // флагов Service.RebuildSensors при connected даст 0 сенсоров и
  // плашка пропадёт из любой колонки.
  AInfo.SupportsFTMS := False;
  AInfo.SupportsControl := ADevId.DeviceType = ANT_DEVICE_TYPE_FEC;
  case ADevId.DeviceType of
    ANT_DEVICE_TYPE_FEC:
      begin
        AInfo.Name := Format('ANT+ FE-C Trainer %d', [ADevId.DeviceNumber]);
        AInfo.SupportsPower := True;
        AInfo.SupportsCadence := True;
        // HR в FE-C broadcast — передаётся отдельно через page 16 byte[6].
        // Большинство тренажёров не имеют встроенного HR-датчика и пишут
        // туда $FF (invalid). Не выставляем HeartRate cap по умолчанию.
        AInfo.SupportsHeartRate := False;
      end;
    ANT_DEVICE_TYPE_HEART_RATE:
      begin
        AInfo.Name := Format('ANT+ HR %d', [ADevId.DeviceNumber]);
        AInfo.SupportsPower := False;
        AInfo.SupportsCadence := False;
        AInfo.SupportsHeartRate := True;
      end;
  else
    begin
      AInfo.Name := Format('ANT+ device %d (type=%d)',
        [ADevId.DeviceNumber, ADevId.DeviceType]);
      AInfo.SupportsPower := False;
      AInfo.SupportsCadence := False;
      AInfo.SupportsHeartRate := False;
    end;
  end;
end;

procedure TANTProvider.NotifyDeviceFound(const ADevId: TANTDeviceId);
var
  Info: TDeviceInfo;
begin
  // (этот блок — это та сигнатура которую ожидает TOnDeviceFound,
  //  см. TrainerData.pas — proc(const Device: TDeviceInfo))
  Info := Default(TDeviceInfo);
  Info.Address := ANT_ADDRESS_PREFIX + IntToStr(ADevId.DeviceNumber);
  Info.TransportType := ttANTPlus;
  Info.ProviderName := 'ANTPlus';
  Info.RSSI := 0;
  FillDeviceInfoForType(Info, ADevId);

  if Assigned(OnDeviceFound) then
    OnDeviceFound(Info);
end;

procedure TANTProvider.OnPairingMessage(const AMsg: TANTMessage);
var
  Channel: Byte;
  DevId: TANTDeviceId;
  ReqMsg: TANTMessage;
  SlotIndex: Integer;
  Slot: TANTPairingSlotDef;
begin
  // ─── Случай 1: BROADCAST_DATA / ACK_DATA ─────────────────────────
  // Когда ANT-стик с wildcard-настройками (devNum=0/devType=Slot.DeviceType/
  // transType=0) получает первый broadcast от мастера, стик САМ перезаписывает
  // свой channel ID на реальный ID мастера. Но host-приложению эту информацию
  // не пушит — мы должны её ЗАПРОСИТЬ через REQUEST_MESSAGE ($4D) с
  // payload [Channel, $51]. Стик ответит сообщением CHANNEL_ID ($51) с
  // настоящим devNum/devType/transType мастера, которое мы обработаем
  // ниже в случае 2.
  if (AMsg.MessageID = ANT_MSG_BROADCAST_DATA)
     or (AMsg.MessageID = ANT_MSG_ACK_DATA) then
  begin
    if AMsg.PayloadLen < 1 then Exit;
    Channel := AMsg.Data[0];
    if not PairingSlotByChannel(Channel, SlotIndex) then Exit;
    if FPairingIdRequested[SlotIndex] then Exit;  // уже запросили, ждём ответа
    if FBackend = nil then Exit;

    Slot := ANT_PAIRING_SLOTS[SlotIndex];
    Logger.Info(Format('[ANTPlus] First broadcast on %s pairing slot — requesting CHANNEL_ID',
      [Slot.Name]));
    FPairingIdRequested[SlotIndex] := True;
    FillChar(ReqMsg, SizeOf(ReqMsg), 0);
    ReqMsg.MessageID := ANT_MSG_REQUEST;
    ReqMsg.PayloadLen := 2;
    ReqMsg.Data[0] := Slot.Channel;
    ReqMsg.Data[1] := ANT_MSG_CHANNEL_ID;
    if not FBackend.WriteMessage(ReqMsg) then
    begin
      Logger.Warning(Format('[ANTPlus] %s REQUEST_MESSAGE(CHANNEL_ID) write failed', [Slot.Name]));
      FPairingIdRequested[SlotIndex] := False;  // permit retry
    end;
    Exit;
  end;

  // ─── Случай 2: CHANNEL_ID ($51) ────────────────────────────────────
  // Ответ стика на наш REQUEST_MESSAGE — содержит реальные devNum/devType/
  // transType только что заматчившегося мастера.
  // Формат payload: [Channel][DevNum_LSB][DevNum_MSB][DevType][TransType]
  if AMsg.MessageID = ANT_MSG_CHANNEL_ID then
  begin
    if AMsg.PayloadLen < 5 then Exit;
    Channel := AMsg.Data[0];
    if not PairingSlotByChannel(Channel, SlotIndex) then Exit;
    Slot := ANT_PAIRING_SLOTS[SlotIndex];

    DevId.DeviceNumber := Word(AMsg.Data[1]) or (Word(AMsg.Data[2]) shl 8);
    DevId.DeviceType := AMsg.Data[3];
    DevId.TransmissionType := AMsg.Data[4];

    // devNum=0 — стик ещё не закрепил wildcard на конкретном мастере.
    // Это единственная ситуация, в которой мы хотим повторить REQUEST'ом
    // на следующий broadcast. Сбрасываем флаг — пусть retry будет.
    if DevId.DeviceNumber = 0 then
    begin
      FPairingIdRequested[SlotIndex] := False;
      Exit;
    end;

    // Все остальные ответы — флаг остаётся True. Pairing slot sticky-
    // bound к одному master'у; повторно запрашивать CHANNEL_ID для каждого
    // приходящего broadcast'а от того же устройства бессмысленно (это спам
    // в логе и трафик на стике). Чтобы найти новый — нужен полный
    // re-config slot'а.
    if DevId.DeviceType <> Slot.DeviceType then Exit;
    if AlreadyFound(DevId.DeviceNumber) then Exit;

    RecordFoundDevice(DevId);
    if Assigned(Logger) then
      Logger.Info(Format('[ANTPlus] Found %s device #%d (transType=%d)',
        [Slot.Name, DevId.DeviceNumber, DevId.TransmissionType]));
    NotifyDeviceFound(DevId);
  end;
end;

procedure TANTProvider.DispatchMessage(const AMsg: TANTMessage);
var
  Channel: Byte;
  Owner: TANTSession;
begin
  // BROADCAST_DATA / ACK_DATA: первый байт payload — channel.
  // CHANNEL_ID response: тоже [Channel][...].
  // RESPONSE_EVENT: [Channel][MessageID][EventCode], тоже channel в [0].
  // Если в payload нет смысла channel — игнор.
  if AMsg.PayloadLen < 1 then Exit;
  Channel := AMsg.Data[0];

  // Маршрутизация: канал ∈ {ANT_PAIRING_FEC, ANT_PAIRING_HRM, ...} →
  // OnPairingMessage (он сам по channel выберет нужный slot). Канал ∈
  // {ANT_FIRST_SESSION_CHANNEL..ANT_MAX_CHANNELS-1} → handler сессии.
  if Channel < ANT_FIRST_SESSION_CHANNEL then
  begin
    if FScanActive then OnPairingMessage(AMsg);
    Exit;
  end;

  if (Channel < ANT_MAX_CHANNELS) then
  begin
    FLock.Enter;
    try
      Owner := FChannelOwners[Channel];
    finally
      FLock.Leave;
    end;
    if Assigned(Owner) then
      Owner.HandleMessage(AMsg);
  end;
end;

function TANTProvider.AcquireChannel(ASession: TANTSession): Integer;
var
  I: Integer;
begin
  Result := -1;
  FLock.Enter;
  try
    // Каналы 0..ANT_FIRST_SESSION_CHANNEL-1 заняты pairing-слотами;
    // ANT_FIRST_SESSION_CHANNEL..ANT_MAX_CHANNELS-1 раздаются сессиям.
    for I := ANT_FIRST_SESSION_CHANNEL to ANT_MAX_CHANNELS - 1 do
      if FChannelOwners[I] = nil then
      begin
        FChannelOwners[I] := ASession;
        Logger.Info(Format('[ANTPlus] Channel %d acquired for device #%d',
          [I, ASession.DeviceId.DeviceNumber]));
        Exit(I);
      end;
    Logger.Warning(Format('[ANTPlus] AcquireChannel: no free channels (all %d session slots in use)',
      [ANT_MAX_CHANNELS - ANT_FIRST_SESSION_CHANNEL]));
  finally
    FLock.Leave;
  end;
end;

procedure TANTProvider.ReleaseChannel(AChannel: Integer);
begin
  if (AChannel < ANT_FIRST_SESSION_CHANNEL) or (AChannel >= ANT_MAX_CHANNELS) then Exit;
  FLock.Enter;
  try
    FChannelOwners[AChannel] := nil;
  finally
    FLock.Leave;
  end;
  Logger.Info(Format('[ANTPlus] Channel %d released', [AChannel]));
end;

function TANTProvider.SendAcknowledged(AChannel: Byte;
  const APage: array of Byte): Boolean;
var
  Msg: TANTMessage;
  I: Integer;
begin
  Result := False;
  if not Assigned(FBackend) then Exit;
  if not FBackend.Opened then Exit;
  if Length(APage) <> 8 then Exit;

  FillChar(Msg, SizeOf(Msg), 0);
  Msg.MessageID := ANT_MSG_ACK_DATA;
  Msg.PayloadLen := 9;
  Msg.Data[0] := AChannel;
  for I := 0 to 7 do
    Msg.Data[1 + I] := APage[I];
  Result := FBackend.WriteMessage(Msg);
end;

function TANTProvider.CreateSession(const AAddress: string;
  const AFriendlyName: string): TTransportSession;
var
  Sess: TANTSession;
  I: Integer;
begin
  Sess := TANTSession.Create(AAddress, AFriendlyName);
  Sess.FProvider := Self;

  // Constructor сессии парсит только DeviceNumber из address-строки и
  // дефолтит DeviceType=FE-C, потому что в адресе самой информации о
  // типе нет. Здесь подменяем на реальный TANTDeviceId, который был
  // запомнён на этапе scan'а в FFoundDevices — иначе HR-сессия пыталась
  // бы открыться с FE-C параметрами. После этого сама сессия в Connect
  // применит capabilities в FDeviceInfo через ApplyCapabilities.
  FLock.Enter;
  try
    for I := 0 to FFoundCount - 1 do
      if FFoundDevices[I].DeviceNumber = Sess.FDeviceId.DeviceNumber then
      begin
        Sess.FDeviceId := FFoundDevices[I];
        Break;
      end;
  finally
    FLock.Leave;
  end;

  // Применяем capability-флаги к FDeviceInfo сессии. Базовый
  // TTransportSession.Create обнуляет всю TDeviceInfo, оставляя только
  // Address+Name+TransportType. При подключении DeviceService копирует
  // Sess.DeviceInfo в Entry.DeviceInfo и зовёт RebuildSensors — без
  // правильных флагов получается 0 sensors, и плашка пропадает из
  // колонки HR/Power/Cadence почти сразу после нажатия Connect.
  Sess.ApplyCapabilities;

  Result := Sess;
end;

// ═══════════════════════════════════════════════════════════════
// TANTSession
// ═══════════════════════════════════════════════════════════════

constructor TANTSession.Create(const AAddress: string; const AFriendlyName: string);
var
  NumStr: string;
  Code: Integer;
  Num: Integer;
begin
  inherited Create(AAddress, AFriendlyName);
  FOpLock := TCriticalSection.Create;
  FProvider := nil;
  FChannel := -1;
  FAccumDistance := 0;
  FLastDistanceRaw := 0;
  FLastDistanceValid := False;
  FFirstPacketLogged := False;

  // Парсинг адреса 'ANT:<DeviceNumber>'.
  FDeviceId.DeviceNumber := 0;
  FDeviceId.DeviceType := ANT_DEVICE_TYPE_FEC;
  FDeviceId.TransmissionType := ANT_FEC_TRANS_TYPE;
  if Pos(ANT_ADDRESS_PREFIX, AAddress) = 1 then
  begin
    NumStr := Copy(AAddress, Length(ANT_ADDRESS_PREFIX) + 1, MaxInt);
    Val(NumStr, Num, Code);
    if (Code = 0) and (Num > 0) and (Num < 65536) then
      FDeviceId.DeviceNumber := Num;
  end;

  FTrainerFeatures.SupportsResistanceControl := True;
  FTrainerFeatures.SupportsPowerControl := True;
  FTrainerFeatures.SupportsInclineControl := True;
  FTrainerFeatures.SupportsSimulation := True;

  Logger.Info(Format('%s session created (address=%s, friendlyName="%s")',
    [LogPrefix, AAddress, AFriendlyName]));
end;

destructor TANTSession.Destroy;
begin
  ShutdownControl;
  Logger.Info(Format('%s session destroying', [LogPrefix]));
  Disconnect;
  FreeAndNil(FOpLock);
  inherited;
end;

class function TANTSession.TransportType: TTransportType;
begin
  Result := ttANTPlus;
end;

function TANTSession.LogPrefix: string;
begin
  Result := Format('[ANTPlus #%d]', [FDeviceId.DeviceNumber]);
end;

procedure TANTSession.ApplyCapabilities;
begin
  // FDeviceInfo унаследован protected от TTransportSession — в пределах
  // собственного класса доступ есть. ProviderName + Supports*-флаги +
  // Name (которое FillDeviceInfoForType переустановит на правильное по
  // типу устройства, например "ANT+ HR 24506" вместо переданного UI'ом
  // длинного "ANT+ HR 24506 (ANTPlus)").
  if not Assigned(FProvider) then Exit;
  FDeviceInfo.ProviderName := 'ANTPlus';
  FProvider.FillDeviceInfoForType(FDeviceInfo, FDeviceId);
end;

function TANTSession.ConfigureFECChannel: Boolean;
var
  Msg: TANTMessage;
  Period: Word;
  Channel: Byte;
  I: Integer;
begin
  Result := False;
  if FProvider = nil then Exit;
  if FProvider.FBackend = nil then Exit;
  if not FProvider.FBackend.Opened then Exit;
  // Capture в local Byte. Дальше используем Channel вместо прямого FChannel,
  // чтобы Disconnect-race не положил функцию range error'ом при присвоении
  // -1 в Msg.Data[0]: Byte. Если FOpLock работает — FChannel не изменится
  // в течение Configure, но capture даёт второй слой защиты.
  if (FChannel < 0) or (FChannel > 255) then Exit;
  Channel := Byte(FChannel);

  // Пауза dispatch thread'а на время burst write'ов. На USBStick2 +
  // libusb-win32 одновременный pending bulk_read + burst bulk_write
  // приводят к десяткам секунд задержек на каждый write. Pause снимает
  // pending-read с pipe; ResponseEvent'ы накапливаются в kernel-buffer'е
  // (~42 байта на 6 команд) и читаются после Resume.
  FProvider.PauseDispatcher;
  try

  Logger.Info(Format('%s >>> ConfigureFECChannel ch=%d for device #%d',
    [LogPrefix, FChannel, FDeviceId.DeviceNumber]));

  // ASSIGN_CHANNEL
  FillChar(Msg, SizeOf(Msg), 0);
  Msg.MessageID := ANT_MSG_ASSIGN_CHANNEL;
  Msg.PayloadLen := 3;
  Msg.Data[0] := Channel;
  Msg.Data[1] := ANT_CHTYPE_BIDIR_SLAVE;
  Msg.Data[2] := ANTPLUS_NETWORK_NUMBER;
  if not FProvider.FBackend.WriteMessage(Msg) then
  begin
    Logger.Warning(Format('%s ConfigureFECChannel: ASSIGN_CHANNEL write failed', [LogPrefix]));
    Exit;
  end;
  Logger.Info(Format('%s ASSIGN_CHANNEL ok (slave on net %d)',
    [LogPrefix, ANTPLUS_NETWORK_NUMBER]));
  Sleep(20);

  // CHANNEL_ID — bind to конкретное устройство
  FillChar(Msg, SizeOf(Msg), 0);
  Msg.MessageID := ANT_MSG_CHANNEL_ID;
  Msg.PayloadLen := 5;
  Msg.Data[0] := Channel;
  Msg.Data[1] := Lo(FDeviceId.DeviceNumber);
  Msg.Data[2] := Hi(FDeviceId.DeviceNumber);
  Msg.Data[3] := FDeviceId.DeviceType;
  Msg.Data[4] := FDeviceId.TransmissionType;
  if not FProvider.FBackend.WriteMessage(Msg) then
  begin
    Logger.Warning(Format('%s ConfigureFECChannel: CHANNEL_ID write failed', [LogPrefix]));
    Exit;
  end;
  Logger.Info(Format('%s CHANNEL_ID ok (devNum=%d, devType=%d, transType=%d)',
    [LogPrefix, FDeviceId.DeviceNumber, FDeviceId.DeviceType, FDeviceId.TransmissionType]));
  Sleep(20);

  // RF_FREQ + PERIOD как у FE-C мастера
  FillChar(Msg, SizeOf(Msg), 0);
  Msg.MessageID := ANT_MSG_CHANNEL_RF_FREQ;
  Msg.PayloadLen := 2;
  Msg.Data[0] := Channel;
  Msg.Data[1] := ANT_FEC_RF_FREQ;
  if not FProvider.FBackend.WriteMessage(Msg) then
  begin
    Logger.Warning(Format('%s ConfigureFECChannel: RF_FREQ write failed', [LogPrefix]));
    Exit;
  end;
  Logger.Info(Format('%s RF_FREQ=%d ok', [LogPrefix, ANT_FEC_RF_FREQ]));
  Sleep(20);

  FillChar(Msg, SizeOf(Msg), 0);
  Msg.MessageID := ANT_MSG_CHANNEL_PERIOD;
  Msg.PayloadLen := 3;
  Msg.Data[0] := Channel;
  // Period подбираем по DeviceType (FE-C=8192, HR=8070, ...). Берём из
  // ANT_PAIRING_SLOTS — там уже описаны параметры для каждого типа.
  // Если устройство не в наших известных — fallback на FE-C period.
  Period := ANT_FEC_CHANNEL_PERIOD;
  for I := 0 to ANT_PAIRING_SLOT_COUNT - 1 do
    if ANT_PAIRING_SLOTS[I].DeviceType = FDeviceId.DeviceType then
    begin
      Period := ANT_PAIRING_SLOTS[I].Period;
      Break;
    end;
  Msg.Data[1] := Lo(Period);
  Msg.Data[2] := Hi(Period);
  if not FProvider.FBackend.WriteMessage(Msg) then
  begin
    Logger.Warning(Format('%s ConfigureFECChannel: CHANNEL_PERIOD write failed', [LogPrefix]));
    Exit;
  end;
  Logger.Info(Format('%s PERIOD=%d (%.2fHz) ok',
    [LogPrefix, Period, 32768 / Period]));
  Sleep(20);

  // OPEN
  FillChar(Msg, SizeOf(Msg), 0);
  Msg.MessageID := ANT_MSG_OPEN_CHANNEL;
  Msg.PayloadLen := 1;
  Msg.Data[0] := Channel;
  if not FProvider.FBackend.WriteMessage(Msg) then
  begin
    Logger.Warning(Format('%s ConfigureFECChannel: OPEN_CHANNEL write failed', [LogPrefix]));
    Exit;
  end;
  Logger.Info(Format('%s OPEN_CHANNEL ok — waiting for master broadcasts', [LogPrefix]));

  Result := True;
  finally
    FProvider.ResumeDispatcher;
  end;
end;

function TANTSession.CloseFECChannel: Boolean;
var
  Msg: TANTMessage;
  Channel: Byte;
begin
  Result := False;
  if FProvider = nil then Exit;
  if FProvider.FBackend = nil then Exit;
  if not FProvider.FBackend.Opened then Exit;
  // См. комментарий в ConfigureFECChannel: capture в Byte для защиты
  // от range error при гонке с Disconnect.
  if (FChannel < 0) or (FChannel > 255) then Exit;
  Channel := Byte(FChannel);

  // Пауза dispatch thread'а — см. комментарий в ConfigureFECChannel.
  // Без неё CLOSE_CHANNEL+UNASSIGN_CHANNEL из Disconnect зависают на
  // десятки секунд так же, как configure-write'ы.
  FProvider.PauseDispatcher;
  try
    Logger.Info(Format('%s CloseFECChannel ch=%d', [LogPrefix, Channel]));

  FillChar(Msg, SizeOf(Msg), 0);
  Msg.MessageID := ANT_MSG_CLOSE_CHANNEL;
  Msg.PayloadLen := 1;
  Msg.Data[0] := Channel;
  if not FProvider.FBackend.WriteMessage(Msg) then
    Logger.Warning(Format('%s CloseFECChannel: CLOSE_CHANNEL write failed', [LogPrefix]));

  FillChar(Msg, SizeOf(Msg), 0);
  Msg.MessageID := ANT_MSG_UNASSIGN_CHANNEL;
  Msg.PayloadLen := 1;
  Msg.Data[0] := Channel;
  if not FProvider.FBackend.WriteMessage(Msg) then
    Logger.Warning(Format('%s CloseFECChannel: UNASSIGN_CHANNEL write failed', [LogPrefix]));

  Result := True;
  finally
    FProvider.ResumeDispatcher;
  end;
end;

function TANTSession.Connect: Boolean;
var
  I: Integer;
begin
  Result := False;
  Logger.Info(Format('%s Connect requested (address=%s)',
    [LogPrefix, FDeviceInfo.Address]));

  // Сериализуем Connect/Disconnect — без этого Disconnect, прилетевший
  // посреди Configure, обнуляет FChannel и crash'ит Configure при
  // следующем Msg.Data[0] := FChannel (range error: -1 → Byte cell).
  FOpLock.Enter;
  try
    if FProvider = nil then
    begin
      Logger.Error(Format('%s Connect: no provider bound', [LogPrefix]));
      SetConnectionState(csError, 'No provider bound');
      Exit;
    end;
    if FDeviceId.DeviceNumber = 0 then
    begin
      Logger.Error(Format('%s Connect: invalid device address (DeviceNumber=0)',
        [LogPrefix]));
      SetConnectionState(csError, 'Invalid device address');
      Exit;
    end;

    SetConnectionState(csConnecting);
    if not FProvider.EnsureBackend then
    begin
      Logger.Error(Format('%s Connect: backend not available', [LogPrefix]));
      SetConnectionState(csError, 'No ANT+ USB backend');
      Exit;
    end;
    if not FProvider.EnsureDispatcher then
    begin
      Logger.Error(Format('%s Connect: dispatcher start failed', [LogPrefix]));
      SetConnectionState(csError, 'Dispatcher start failed');
      Exit;
    end;

    FChannel := FProvider.AcquireChannel(Self);
    if FChannel < 0 then
    begin
      Logger.Error(Format('%s Connect: no free channel on stick', [LogPrefix]));
      SetConnectionState(csError, 'No free channel on stick');
      Exit;
    end;

    if not ConfigureFECChannel then
    begin
      Logger.Warning(Format('%s Connect: ConfigureFECChannel failed, releasing channel %d',
        [LogPrefix, FChannel]));
      FProvider.ReleaseChannel(FChannel);
      FChannel := -1;
      SetConnectionState(csError, 'Channel configure failed');
      Exit;
    end;

    // Закрываем pairing-slot, который слушает того же мастера на той же
    // RF/period — иначе у ANT-стика два slave-канала на один источник
    // (pairing-bound + наш session), и broadcast'ы могут уходить в
    // pairing slot, не доходя до session-канала. Симптом — наш канал
    // получает EVENT_RX_SEARCH_TIMEOUT через 30 секунд несмотря на то
    // что мастер в эфире. Pairing slot будет переоткрыт в Disconnect.
    for I := 0 to ANT_PAIRING_SLOT_COUNT - 1 do
      if ANT_PAIRING_SLOTS[I].DeviceType = FDeviceId.DeviceType then
      begin
        FProvider.ClosePairingChannel(I);
        Break;
      end;

    // ANT — асинхронный протокол: реальное «подключено» подтверждается
    // приходом первого BROADCAST_DATA от мастера в HandleMessage.
    // До этого — csConnecting. Чтобы клиентский UI не висел вечно,
    // ставим csConnected сразу после успешного OPEN_CHANNEL — это
    // соответствует «канал открыт, ждём данные». Если master не
    // отвечает 8+ сек, ANT сам сгенерирует EVENT_RX_SEARCH_TIMEOUT
    // (обработка которого — см. HandleMessage).
    SetConnectionState(csConnected);
    FHasControl := True;
    FFirstPacketLogged := False;  // ждём первый пакет
    Logger.Info(Format('%s Connect: channel %d configured, marked csConnected (awaiting first broadcast)',
      [LogPrefix, FChannel]));
    Result := True;
  finally
    FOpLock.Leave;
  end;
end;

procedure TANTSession.Disconnect;
var
  I: Integer;
begin
  Logger.Info(Format('%s Disconnect requested', [LogPrefix]));
  // Сериализация с Connect/ConfigureFECChannel — см. комментарий в Connect.
  // FOpLock может быть nil во время Destroy если deallocate уже произошёл,
  // но Destroy сам зовёт Disconnect ДО Free(FOpLock), так что lock ещё жив.
  if Assigned(FOpLock) then FOpLock.Enter;
  try
    if FChannel >= 0 then
    begin
      CloseFECChannel;
      if Assigned(FProvider) then
        FProvider.ReleaseChannel(FChannel);
      FChannel := -1;
      // Переоткрываем pairing slot для этого DeviceType — он был
      // закрыт в Connect, чтобы освободить эфир для session канала.
      // Теперь, когда session закрыт, scan может снова искать
      // устройства этого типа.
      if Assigned(FProvider) then
        for I := 0 to ANT_PAIRING_SLOT_COUNT - 1 do
          if ANT_PAIRING_SLOTS[I].DeviceType = FDeviceId.DeviceType then
          begin
            FProvider.ConfigurePairingChannel(I);
            Break;
          end;
    end;
    FHasControl := False;
    SetConnectionState(csDisconnected);
    Logger.Info(Format('%s Disconnect complete', [LogPrefix]));
  finally
    if Assigned(FOpLock) then FOpLock.Leave;
  end;
end;

procedure TANTSession.HandleMessage(const AMsg: TANTMessage);
var
  EventCode: Byte;
begin
  // Все приходящие на этот канал сообщения от провайдера.
  case AMsg.MessageID of
    ANT_MSG_BROADCAST_DATA, ANT_MSG_ACK_DATA:
      begin
        // Payload: [Channel][8-byte page]
        if AMsg.PayloadLen < 9 then Exit;

        // Первый пришедший пакет от мастера — логгируем как «реальное
        // подключение установлено» (мимикрия первой ValueChanged-нотификации
        // в BLE-логах).
        if not FFirstPacketLogged then
        begin
          FFirstPacketLogged := True;
          Logger.Info(Format('%s First broadcast received — link is live (page=%d)',
            [LogPrefix, AMsg.Data[1]]));
        end;

        // Парсим payload в зависимости от типа устройства, к которому
        // привязана сессия. FE-C тренажёр шлёт pages 16/25 (+другие),
        // HR-ремень шлёт pages 0..4 — у всех HR-pages в byte[7] лежит
        // computed heart rate в bpm.
        case FDeviceId.DeviceType of
          ANT_DEVICE_TYPE_FEC:
            case AMsg.Data[1] of
              FEC_PAGE_GENERAL_FE_DATA:
                ParseFECPage16([AMsg.Data[1], AMsg.Data[2], AMsg.Data[3],
                  AMsg.Data[4], AMsg.Data[5], AMsg.Data[6], AMsg.Data[7], AMsg.Data[8]]);
              FEC_PAGE_SPECIFIC_TRAINER:
                ParseFECPage25([AMsg.Data[1], AMsg.Data[2], AMsg.Data[3],
                  AMsg.Data[4], AMsg.Data[5], AMsg.Data[6], AMsg.Data[7], AMsg.Data[8]]);
            end;
          ANT_DEVICE_TYPE_HEART_RATE:
            // Все HR pages (0..4) имеют HR в byte[7]; не разбираем
            // под-тип pages — остальное только informational/cumulative.
            ParseHRPage([AMsg.Data[1], AMsg.Data[2], AMsg.Data[3],
              AMsg.Data[4], AMsg.Data[5], AMsg.Data[6], AMsg.Data[7], AMsg.Data[8]]);
        end;
      end;
    ANT_MSG_RESPONSE_EVENT:
      begin
        // Payload: [Channel][MsgID][EventCode]
        if AMsg.PayloadLen < 3 then Exit;
        EventCode := AMsg.Data[2];
        // EVENT_RX_SEARCH_TIMEOUT = 1, EVENT_RX_FAIL = 2, etc.
        // EVENT_CHANNEL_CLOSED = 7 — пришло после CLOSE_CHANNEL
        case EventCode of
          1:
            begin
              Logger.Warning(Format('%s EVENT_RX_SEARCH_TIMEOUT — master never responded',
                [LogPrefix]));
              SetConnectionState(csError, 'RX search timeout (no master response)');
            end;
          2:
            Logger.Warning(Format('%s EVENT_RX_FAIL', [LogPrefix]));
          7:
            Logger.Info(Format('%s EVENT_CHANNEL_CLOSED', [LogPrefix]));
          8:
            Logger.Warning(Format('%s EVENT_RX_FAIL_GO_TO_SEARCH (link lost, re-searching)',
              [LogPrefix]));
        else
          Logger.Info(Format('%s RESPONSE_EVENT msgID=$%.2X event=%d',
            [LogPrefix, AMsg.Data[1], EventCode]));
        end;
      end;
  end;
end;

procedure TANTSession.ParseFECPage16(const APayload: array of Byte);
var
  DistRaw: Byte;
  DistDelta: Byte;
  SpeedRaw: Word;
  ElapsedRaw: Byte;
begin
  // Page 16 — General FE Data:
  //   [0] = page number (16)
  //   [1] = equipment type
  //   [2] = elapsed time, 0.25s/unit (rolls over at 64s)
  //   [3] = distance travelled, 1m/unit (rolls over at 256m)
  //   [4..5] = speed, 0.001 m/s (LE)
  //   [6] = heart rate, bpm (255 = invalid)
  //   [7] = capabilities + state
  if Length(APayload) < 8 then Exit;

  ElapsedRaw := APayload[2];
  // FLastData.ElapsedTime приходит как сумма приращений; при первом
  // вызове просто пишем raw*0.25, дальше можно усреднять — для нашего
  // UI достаточно текущего «грубого» значения.
  FLastData.ElapsedTime := (Cardinal(ElapsedRaw) * 250) div 1000;

  DistRaw := APayload[3];
  if FLastDistanceValid then
  begin
    DistDelta := DistRaw - FLastDistanceRaw;  // wrap-safe
    FAccumDistance := FAccumDistance + DistDelta;
  end;
  FLastDistanceRaw := DistRaw;
  FLastDistanceValid := True;
  FLastData.Distance := FAccumDistance;

  SpeedRaw := Word(APayload[4]) or (Word(APayload[5]) shl 8);
  // 0.001 m/s → km/h: × 3.6 / 1000 = × 0.0036
  FLastData.InstantSpeed := SpeedRaw * 0.0036;

  if APayload[6] <> 255 then
    FLastData.HeartRate := APayload[6]
  else
    FLastData.HeartRate := 0;

  FLastData.Timestamp := Now;
  NotifyDataReceived;
end;

procedure TANTSession.ParseFECPage25(const APayload: array of Byte);
var
  PowerRaw: Word;
  CadenceRaw: Byte;
begin
  // Page 25 — Specific Trainer Data:
  //   [0] = page number (25)
  //   [1] = update event count
  //   [2] = instantaneous cadence, rpm (255 = invalid)
  //   [3..4] = accumulated power, watts (LE) — дельта-counter
  //   [5..6] = instantaneous power LSB + nibble (12-bit value)
  //   [7] = trainer status (lo nibble) + flags
  if Length(APayload) < 8 then Exit;

  CadenceRaw := APayload[2];
  if CadenceRaw <> 255 then
    FLastData.InstantCadence := CadenceRaw
  else
    FLastData.InstantCadence := 0;

  // Instant power: 12 bits — APayload[5] = LSB, APayload[6] low nibble = MSB
  PowerRaw := Word(APayload[5]) or ((Word(APayload[6]) and $0F) shl 8);
  if PowerRaw <> $0FFF then
    FLastData.InstantPower := PowerRaw
  else
    FLastData.InstantPower := 0;

  FLastData.Timestamp := Now;
  NotifyDataReceived;
end;

procedure TANTSession.ParseHRPage(const APayload: array of Byte);
begin
  // ANT+ Heart Rate Profile — pages 0..4. Все pages общие в byte[7]:
  //   [0] = page number (high bit = toggle bit)
  //   [1..4] = page-specific (manufacturer ID, serial #, battery, etc.)
  //   [5..6] = Heart Beat Event Time (1024 Hz LE-counter, для R-R интервалов)
  //   [7] = Computed Heart Rate, bpm
  // 0 в byte[7] означает «нет данных» (например, ремень не на теле).
  if Length(APayload) < 8 then Exit;
  if APayload[7] = 0 then Exit;

  FLastData.HeartRate := APayload[7];
  FLastData.Timestamp := Now;
  NotifyDataReceived;
end;

function TANTSession.RequestControl: Boolean;
begin
  // FE-C не имеет явной операции «запросить управление» — отправка
  // любой command page (48/49/50/51) работает как имплицитный
  // request-control. Возвращаем True.
  FHasControl := True;
  Result := True;
end;

function TANTSession.SetTargetPower(Watts: Word): Boolean;
var
  Page: TBytes;
begin
  Result := False;
  if FConnectionState <> csConnected then
  begin
    Logger.Warning(Format('%s SetTargetPower(%dW): not connected (state=%d), ignored',
      [LogPrefix, Watts, Ord(FConnectionState)]));
    Exit;
  end;
  if FProvider = nil then Exit;
  ANTBuildPageTargetPower(Watts, Page);
  Result := FProvider.SendAcknowledged(FChannel, Page);
  if Result then
    FLastData.TargetPower := Watts;
  Logger.Info(Format('%s SetTargetPower(%dW) -> Page 49 -> %s',
    [LogPrefix, Watts, BoolToStr(Result, True)]));
end;

function TANTSession.SetResistanceLevel(Level: Byte): Boolean;
var
  Page: TBytes;
begin
  Result := False;
  if FConnectionState <> csConnected then
  begin
    Logger.Warning(Format('%s SetResistanceLevel(%d): not connected, ignored',
      [LogPrefix, Level]));
    Exit;
  end;
  if FProvider = nil then Exit;
  // FE-C Page 48: 0..200, 0.5%/unit. Мапим Level (0..100) → 0..200.
  if Level > 100 then Level := 100;
  ANTBuildPageBasicResistance(Level * 2, Page);
  Result := FProvider.SendAcknowledged(FChannel, Page);
  if Result then
    FLastData.ResistanceLevel := Level;
  Logger.Info(Format('%s SetResistanceLevel(%d%%) -> Page 48 raw=%d -> %s',
    [LogPrefix, Level, Level * 2, BoolToStr(Result, True)]));
end;

function TANTSession.SetIncline(InclinePercent: Single): Boolean;
var
  Page: TBytes;
  GradeHundredths: SmallInt;
begin
  Result := False;
  if FConnectionState <> csConnected then
  begin
    Logger.Warning(Format('%s SetIncline(%.2f%%): not connected, ignored',
      [LogPrefix, InclinePercent]));
    Exit;
  end;
  if FProvider = nil then Exit;
  // FE-C Page 51 grade — в сотых долях процента (signed).
  GradeHundredths := Round(InclinePercent * 100);
  // RollingResistance = $FF в маркер «не задано» — оставляем «trainer
  // выбирает по дефолту». 0xFF здесь не специальное значение, просто
  // максимум; фактически на трейнерах часто остаётся trainer-default.
  // Передаём 80 (~0.004 — асфальт) как разумный default.
  ANTBuildPageTrackResistance(GradeHundredths, 80, Page);
  Result := FProvider.SendAcknowledged(FChannel, Page);
  if Result then
    FLastData.Incline := Round(InclinePercent * 10);
  Logger.Info(Format('%s SetIncline(%.2f%%) -> Page 51 grade=%d -> %s',
    [LogPrefix, InclinePercent, GradeHundredths, BoolToStr(Result, True)]));
end;

function TANTSession.SetSimulation(Grade: Single; WindSpeed: Single;
  RiderWeight: Single; BikeWeight: Single): Boolean;
var
  Page: TBytes;
  GradeHundredths: SmallInt;
begin
  Result := False;
  if FConnectionState <> csConnected then
  begin
    Logger.Warning(Format('%s SetSimulation(grade=%.2f%%): not connected, ignored',
      [LogPrefix, Grade]));
    Exit;
  end;
  if FProvider = nil then Exit;

  // ANT+ FE-C SIM: для полной симуляции нужно отправить:
  //  Page 55 (User Configuration) — RiderWeight, BikeWeight (один раз)
  //  Page 50 (Wind Resistance) — WindCoeff, WindSpeed
  //  Page 51 (Track Resistance) — Grade, RollingResistance
  //
  // Здесь упрощённая версия: только Page 51 (grade). Wind/User-config —
  // TODO по необходимости, в большинстве сценариев trainer применяет
  // дефолты (75 кг райдер, 10 кг байк, drag коэффициент 0.51) и
  // результат субъективно адекватен. Параметры WindSpeed/RiderWeight/
  // BikeWeight приняты для совместимости с TTransportSession и пока
  // игнорируются — FPC выдаст лишь note про unused params.
  GradeHundredths := Round(Grade * 100);
  ANTBuildPageTrackResistance(GradeHundredths, 80, Page);
  Result := FProvider.SendAcknowledged(FChannel, Page);
  if Result then
    FLastData.Incline := Round(Grade * 10);
  Logger.Info(Format('%s SetSimulation(grade=%.2f%% wind=%.1fm/s rider=%.0fkg bike=%.0fkg) -> Page 51 -> %s',
    [LogPrefix, Grade, WindSpeed, RiderWeight, BikeWeight, BoolToStr(Result, True)]));
end;

function TANTSession.Start: Boolean;
begin
  // FE-C не имеет команды START/STOP канала на уровне профиля —
  // тренажёр сам решает, броадкастить или нет. Возвращаем True
  // чтобы вызывающий код не считал это ошибкой.
  Result := FConnectionState = csConnected;
end;

function TANTSession.Stop: Boolean;
begin
  Result := FConnectionState = csConnected;
end;

function TANTSession.Pause: Boolean;
begin
  Result := FConnectionState = csConnected;
end;

function TANTSession.Reset: Boolean;
begin
  // Reset accumulated distance — это локальное состояние сессии.
  FAccumDistance := 0;
  FLastDistanceValid := False;
  Result := True;
end;

// ═══════════════════════════════════════════════════════════════
// Legacy TANTManager — preserved as-is, не используется новым кодом
// ═══════════════════════════════════════════════════════════════

constructor TANTManager.Create;
begin
  inherited Create;
  FConnected := False;
end;

destructor TANTManager.Destroy;
begin
  CloseChannel;
  inherited;
end;

function TANTManager.Initialize: Boolean;
begin
  // Legacy stub — оставлен для совместимости. Новый код использует
  // TANTProvider/TANTSession.
  Result := False;
end;

function TANTManager.OpenChannel(DeviceType: Byte; DeviceNumber: Word): Boolean;
begin
  Result := False;
  // Suppress hints
  if DeviceType = 0 then ;
  if DeviceNumber = 0 then ;
end;

procedure TANTManager.CloseChannel;
begin
  FConnected := False;
end;

function TANTManager.SetBasicResistance(Resistance: Byte): Boolean;
begin
  Result := False;
  if not FConnected then Exit;
  if Resistance = 0 then ;
end;

function TANTManager.SetTargetPower(PowerWatts: Word): Boolean;
begin
  Result := False;
  if not FConnected then Exit;
  if PowerWatts = 0 then ;
end;

function TANTManager.SetTrackResistance(Grade: SmallInt;
  RollingResistance: Byte): Boolean;
begin
  Result := False;
  if not FConnected then Exit;
  if Grade = 0 then ;
  if RollingResistance = 0 then ;
end;

function TANTManager.SetWindResistance(WindCoeff: Byte; WindSpeed: ShortInt;
  DraftingFactor: Byte): Boolean;
begin
  Result := False;
  if not FConnected then Exit;
  if WindCoeff = 0 then ;
  if WindSpeed = 0 then ;
  if DraftingFactor = 0 then ;
end;

function ANTPlusAvailable: Boolean;
var
  Backend: TANTUsbBackend;
begin
  Result := False;
  if GRegisteredBackendClass = nil then Exit;
  Backend := GRegisteredBackendClass.Create;
  try
    Result := Backend.Open;
    if Result then
    begin
      // Кэшируем product string чтобы UI/Settings могли использовать его
      // как human-readable имя adapter'а ещё до того как Provider начал
      // работать.
      GLastProductDescription := Backend.ProductDescription;
      Backend.Close;
    end;
  except
    Result := False;
  end;
  Backend.Free;
end;

end.
