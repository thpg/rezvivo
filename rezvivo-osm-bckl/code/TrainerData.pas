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

  TTrainerMetric = (tmPower, tmCadence, tmSpeed, tmHeartRate, tmDistance,
    tmEnergy, tmElapsed, tmResistance, tmIncline, tmTargetPower, tmState, tmSteering);
  TTrainerMetrics = set of TTrainerMetric;

  // Данные с трейнера
  TTrainerDataRecord = record
    Timestamp: TDateTime;
    HasMetricMask: Boolean;
    PresentMetrics, ValidMetrics: TTrainerMetrics;
    MetricTime: array[TTrainerMetric] of TDateTime;
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
    ResistanceLevel: Single;     // Native trainer level (not necessarily percent)
    TargetPower: Word;           // Целевая мощность (ERG режим)
    Incline: SmallInt;           // Уклон в 0.1%
    SteeringAngle: Single;       // Degrees, clockwise positive; never a power source
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
    SupportsSpeed: Boolean;
    SupportsHeartRate: Boolean;
    SupportsSteering: Boolean;
  end;

  // Возможности трейнера (FTMS Features)
  TTrainerFeatures = record
    Known: Boolean;
    PowerRangeKnown, ResistanceRangeKnown, InclineRangeKnown: Boolean;
    SupportsPower, SupportsCadence, SupportsHeartRate: Boolean;
    SupportsResistanceControl: Boolean;
    SupportsPowerControl: Boolean;
    SupportsInclineControl: Boolean;
    SupportsSimulation: Boolean;
    MaxResistance: Word;
    MinResistance10, MaxResistance10: SmallInt;
    InclineIncrement10: Word;
    ResistanceIncrement10: Word;
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

procedure BeginTrainerPacket(var Data: TTrainerDataRecord);
procedure MarkTrainerMetric(var Data: TTrainerDataRecord; Metric: TTrainerMetric;
  Valid: Boolean = True);
procedure MergeTrainerData(var Dest: TTrainerDataRecord; const Source: TTrainerDataRecord);
function LearnTrainerMetrics(var Info: TDeviceInfo; const Data: TTrainerDataRecord): Boolean;

implementation

procedure BeginTrainerPacket(var Data: TTrainerDataRecord);
begin
  Data.HasMetricMask := True;
  Data.PresentMetrics := [];
  Data.ValidMetrics := [];
  Data.Timestamp := Now;
end;

procedure MarkTrainerMetric(var Data: TTrainerDataRecord; Metric: TTrainerMetric;
  Valid: Boolean);
begin
  Data.HasMetricMask := True;
  Include(Data.PresentMetrics, Metric);
  if Valid then Include(Data.ValidMetrics, Metric)
  else Exclude(Data.ValidMetrics, Metric);
  Data.MetricTime[Metric] := Data.Timestamp;
end;

procedure MergeTrainerData(var Dest: TTrainerDataRecord; const Source: TTrainerDataRecord);
var M: TTrainerMetric;
begin
  { Legacy/simulation producers publish complete snapshots. Radio producers
    publish explicit deltas; union the deltas when coalescing a UI frame. }
  if not Source.HasMetricMask then begin Dest := Source; Exit end;
  if not Dest.HasMetricMask then
  begin
    Dest.PresentMetrics := [];
    Dest.ValidMetrics := [];
    FillChar(Dest.MetricTime, SizeOf(Dest.MetricTime), 0);
  end;
  Dest.HasMetricMask := True;
  Dest.Timestamp := Source.Timestamp;
  for M in Source.PresentMetrics do
  begin
    if (Dest.MetricTime[M] > Source.MetricTime[M]) and
      (Source.MetricTime[M] <> 0) then Continue;
    case M of
      tmPower: begin Dest.InstantPower:=Source.InstantPower; Dest.AveragePower:=Source.AveragePower end;
      tmCadence: begin Dest.InstantCadence:=Source.InstantCadence; Dest.AverageCadence:=Source.AverageCadence end;
      tmSpeed: begin Dest.InstantSpeed:=Source.InstantSpeed; Dest.AverageSpeed:=Source.AverageSpeed end;
      tmHeartRate: Dest.HeartRate:=Source.HeartRate;
      tmDistance: Dest.Distance:=Source.Distance;
      tmEnergy: Dest.TotalEnergy:=Source.TotalEnergy;
      tmElapsed: Dest.ElapsedTime:=Source.ElapsedTime;
      tmResistance: Dest.ResistanceLevel:=Source.ResistanceLevel;
      tmIncline: Dest.Incline:=Source.Incline;
      tmTargetPower: Dest.TargetPower:=Source.TargetPower;
      tmSteering: Dest.SteeringAngle:=Source.SteeringAngle;
      tmState: begin Dest.IsMoving:=Source.IsMoving; Dest.IsPaused:=Source.IsPaused end;
    end;
    Include(Dest.PresentMetrics, M);
    if M in Source.ValidMetrics then Include(Dest.ValidMetrics, M)
    else Exclude(Dest.ValidMetrics, M);
    Dest.MetricTime[M] := Source.MetricTime[M];
  end;
  if ((Source.PresentMetrics * [tmPower,tmCadence,tmSpeed])<>[]) and
    not (tmState in Source.PresentMetrics) then
    Dest.IsMoving:=((tmPower in Dest.ValidMetrics) and (Dest.InstantPower>0)) or
      ((tmCadence in Dest.ValidMetrics) and (Dest.InstantCadence>0)) or
      ((tmSpeed in Dest.ValidMetrics) and (Dest.InstantSpeed>0.1));
end;

function LearnTrainerMetrics(var Info: TDeviceInfo; const Data: TTrainerDataRecord): Boolean;
var Before: TTrainerMetrics;
begin
  Result := False;
  if not Data.HasMetricMask then Exit;
  Before := [];
  if Info.SupportsPower then Include(Before,tmPower);
  if Info.SupportsCadence then Include(Before,tmCadence);
  if Info.SupportsSpeed then Include(Before,tmSpeed);
  if Info.SupportsHeartRate then Include(Before,tmHeartRate);
  if Info.SupportsSteering then Include(Before,tmSteering);
  { An invalid sentinel proves the field exists, but not a usable HR bridge. }
  Info.SupportsPower := Info.SupportsPower or (tmPower in Data.PresentMetrics);
  Info.SupportsCadence := Info.SupportsCadence or (tmCadence in Data.PresentMetrics);
  Info.SupportsSpeed := Info.SupportsSpeed or (tmSpeed in Data.PresentMetrics);
  Info.SupportsHeartRate := Info.SupportsHeartRate or
    ((tmHeartRate in Data.PresentMetrics) and (tmHeartRate in Data.ValidMetrics));
  Info.SupportsSteering := Info.SupportsSteering or (tmSteering in Data.PresentMetrics);
  Result := (Info.SupportsPower and not (tmPower in Before)) or
    (Info.SupportsCadence and not (tmCadence in Before)) or
    (Info.SupportsSpeed and not (tmSpeed in Before)) or
    (Info.SupportsHeartRate and not (tmHeartRate in Before)) or
    (Info.SupportsSteering and not (tmSteering in Before));
end;


end.
