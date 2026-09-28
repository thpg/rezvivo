unit TrainerData;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  // Состояние подключения
  TConnectionState = (csDisconnected, csScanning, csConnecting, csConnected, csError);

  // Тип сопротивления
  TResistanceMode = (rmLevel, rmPower, rmSlope, rmERG);

  // Тип транспорта (дублируется из GameTransportBase для доступности без
  // циклической зависимости; GameTransportBase использует этот же enum)
  TTransportType = (
    ttUnknown,
    ttBLE,
    ttANTPlus,
    ttEthernet,
    ttWiFi,
    ttUSB,
    ttSerial,
    ttSim         { Симулятор: эмулирует трейнер из FIT-файла, dev-only }
  );

  // Данные с трейнера
  TTrainerDataRecord = record
    Timestamp: TDateTime;
    InstantPower: Word;          // Мощность в ваттах
    AveragePower: Word;          // Средняя мощность
    InstantCadence: Word;        // Каденс об/мин
    AverageCadence: Word;        // Средний каденс
    InstantSpeed: Single;        // Скорость км/ч
    AverageSpeed: Single;        // Средняя скорость
    HeartRate: Byte;             // Пульс
    Distance: Cardinal;          // Дистанция в метрах
    TotalEnergy: Word;           // Калории
    ElapsedTime: Cardinal;       // Время в секундах
    ResistanceLevel: Byte;       // Уровень сопротивления 0-100
    TargetPower: Word;           // Целевая мощность (ERG режим)
    Incline: SmallInt;           // Уклон в 0.1%
    IsMoving: Boolean;
    IsPaused: Boolean;
  end;

  // Информация об устройстве
  TDeviceInfo = record
    Name: string;
    Address: string;
    TransportType: TTransportType;
    ProviderName: string;          // 'WinBLE' / 'SimpleBLE' etc.
    RSSI: ShortInt;
    ManufacturerName: string;
    ModelNumber: string;
    SerialNumber: string;
    FirmwareRevision: string;
    SupportsFTMS: Boolean;
    SupportsControl: Boolean;      // writable FTMS/FE-C control, not power telemetry
    SupportsPower: Boolean;
    SupportsCadence: Boolean;
    SupportsHeartRate: Boolean;
  end;

  // Возможности трейнера (FTMS Features)
  TTrainerFeatures = record
    SupportsResistanceControl: Boolean;
    SupportsPowerControl: Boolean;
    SupportsInclineControl: Boolean;
    SupportsSimulation: Boolean;
    MaxResistance: Word;
    MinPower: Word;
    MaxPower: Word;
    MinIncline: SmallInt;
    MaxIncline: SmallInt;
    PowerIncrement: Word;
  end;

  // Callback для событий
  TOnDataReceived = procedure(const Data: TTrainerDataRecord) of object;
  TOnConnectionChanged = procedure(State: TConnectionState; const Message: string) of object;
  TOnDeviceFound = procedure(const Device: TDeviceInfo) of object;

const
  CONNECTION_STATE_NAMES: array[TConnectionState] of string = (
    'Disconnected', 'Scanning', 'Connecting', 'Connected', 'Error'
  );

  RESISTANCE_MODE_NAMES: array[TResistanceMode] of string = (
    'Level', 'Power', 'Gradient', 'ERG'
  );

  TRANSPORT_TYPE_NAMES: array[TTransportType] of string = (
    'Unknown', 'BLE', 'ANT+', 'Ethernet', 'Wi-Fi', 'USB', 'Serial', 'Sim'
  );

implementation


end.
