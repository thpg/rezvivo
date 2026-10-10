{ GameDeviceSensor — иерархия сенсоров, привязанных к устройству.

  Каждый сенсор — полноценный хранитель своих данных:
    - текущее мгновенное значение (Instant)
    - предыдущее мгновенное (PrevInstant) — для дельты/тренда
    - среднее от устройства (DeviceAverage) — если устройство передаёт
    - вычисленное среднее за сессию (SessionAverage)
    - min / max за сессию
    - дельта (Instant - PrevInstant)

  Вызывающий код делает sensor.Update(Data), после чего читает
  sensor.Instant, sensor.FormatInstant и т.д. — без передачи Data.

  ── Два персистентных идентификатора ──

  1) NetworkId — точный, по сетевому адресу:
       a4:c1:38:12:34:56/pwr
  2) NameId — кросс-транспортный, по имени устройства:
       wahoo kickr/pwr

  Конкретные потомки:
    THRSensor       key = 'hr'
    TPowerSensor    key = 'pwr'
    TCadenceSensor  key = 'cad'
    TSpeedSensor    key = 'spd'
}
unit GameDeviceSensor;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fgl,
  TrainerData;

type
  { Тип сенсора }
  TSensorKind = (
    skHeartRate,
    skPower,
    skCadence,
    skSpeed,
    skSteering
  );

  { Forward }
  TDeviceSensor = class;

  TDeviceSensorList = specialize TFPGObjectList<TDeviceSensor>;

  { ─── Базовый класс сенсора ─── }

  TDeviceSensor = class
  private
    FKind: TSensorKind;
    FDeviceAddress: string;
    FDeviceName: string;
    FNetworkId: string;
    FNameId: string;

    { ── Данные ── }
    FInstant: Double;         { текущее мгновенное значение }
    FPrevInstant: Double;     { предыдущее мгновенное значение }
    FDeviceAverage: Double;   { среднее, полученное от устройства }

    { ── Статистика за сессию ── }
    FSessionSum: Double;      { сумма для вычисления среднего }
    FSessionCount: Integer;   { количество ненулевых замеров }
    FSessionMin: Double;      { минимум за сессию }
    FSessionMax: Double;      { максимум за сессию }

    FHasData: Boolean;        { был хотя бы один ненулевой замер }
    FLastUpdate: TDateTime;

    function GetSessionAverage: Double;
    function GetDelta: Double;
  protected
    { Потомки извлекают из Data мгновенное и среднее (от устройства).
      Возвращают True если данные валидны (ненулевые). }
    function DoExtract(const Data: TTrainerDataRecord;
      out AInstant, ADeviceAverage: Double): Boolean; virtual; abstract;

    procedure BuildIds;
  public
    constructor Create(const ADeviceAddress, ADeviceName: string); virtual;

    { ── Основной метод приёма данных ── }
    { Извлекает значения, обновляет всю внутреннюю статистику.
      Возвращает True если данные для этого сенсора присутствуют. }
    function Update(const Data: TTrainerDataRecord): Boolean;

    { Сброс сессионной статистики (новая тренировка) }
    procedure ResetSession;

    { ── Метаинформация (class-level) ── }
    class function SensorName: string; virtual; abstract;
    class function UnitLabel: string; virtual; abstract;
    class function Kind: TSensorKind; virtual; abstract;
    class function SensorKey: string; virtual; abstract;

    { ── Форматирование для UI (без параметров) ── }
    function FormatInstant: string; virtual;
    function FormatDeviceAverage: string; virtual;
    function FormatSessionAverage: string; virtual;
    function FormatMinMax: string; virtual;
    function FormatDelta: string; virtual;

    { ── Персистентные идентификаторы ── }
    property NetworkId: string read FNetworkId;
    property NameId: string read FNameId;
    property DeviceAddress: string read FDeviceAddress;
    property DeviceName: string read FDeviceName;

    { ── Текущие данные ── }
    property Instant: Double read FInstant;
    property PrevInstant: Double read FPrevInstant;
    property DeviceAverage: Double read FDeviceAverage;
    property Delta: Double read GetDelta;

    { ── Статистика за сессию ── }
    property SessionAverage: Double read GetSessionAverage;
    property SessionMin: Double read FSessionMin;
    property SessionMax: Double read FSessionMax;
    property SessionCount: Integer read FSessionCount;

    property HasData: Boolean read FHasData;
    property LastUpdate: TDateTime read FLastUpdate;
    function DataAgeSec: Double;
    property SensorKind: TSensorKind read FKind;
  end;

  TDeviceSensorClass = class of TDeviceSensor;

  { ─── Пульсометр ─── }

  THRSensor = class(TDeviceSensor)
  protected
    function DoExtract(const Data: TTrainerDataRecord;
      out AInstant, ADeviceAverage: Double): Boolean; override;
  public
    constructor Create(const ADeviceAddress, ADeviceName: string); override;
    class function SensorName: string; override;
    class function UnitLabel: string; override;
    class function Kind: TSensorKind; override;
    class function SensorKey: string; override;
  end;

  { ─── Датчик мощности ─── }

  TPowerSensor = class(TDeviceSensor)
  protected
    function DoExtract(const Data: TTrainerDataRecord;
      out AInstant, ADeviceAverage: Double): Boolean; override;
  public
    constructor Create(const ADeviceAddress, ADeviceName: string); override;
    class function SensorName: string; override;
    class function UnitLabel: string; override;
    class function Kind: TSensorKind; override;
    class function SensorKey: string; override;
  end;

  { ─── Датчик каденса ─── }

  TCadenceSensor = class(TDeviceSensor)
  protected
    function DoExtract(const Data: TTrainerDataRecord;
      out AInstant, ADeviceAverage: Double): Boolean; override;
  public
    constructor Create(const ADeviceAddress, ADeviceName: string); override;
    class function SensorName: string; override;
    class function UnitLabel: string; override;
    class function Kind: TSensorKind; override;
    class function SensorKey: string; override;
  end;

  { ─── Датчик скорости ─── }

  TSpeedSensor = class(TDeviceSensor)
  protected
    function DoExtract(const Data: TTrainerDataRecord;
      out AInstant, ADeviceAverage: Double): Boolean; override;
  public
    constructor Create(const ADeviceAddress, ADeviceName: string); override;
    class function SensorName: string; override;
    class function UnitLabel: string; override;
    class function Kind: TSensorKind; override;
    class function SensorKey: string; override;
    function FormatInstant: string; override;
    function FormatDeviceAverage: string; override;
    function FormatSessionAverage: string; override;
    function FormatMinMax: string; override;
  end;

  TSteeringSensor = class(TDeviceSensor)
  protected
    function DoExtract(const Data: TTrainerDataRecord;
      out AInstant, ADeviceAverage: Double): Boolean; override;
  public
    constructor Create(const ADeviceAddress, ADeviceName: string); override;
    class function SensorName: string; override;
    class function UnitLabel: string; override;
    class function Kind: TSensorKind; override;
    class function SensorKey: string; override;
    function FormatInstant: string; override;
  end;

const
  SENSOR_KIND_NAMES: array[TSensorKind] of string = (
    'Heart Rate', 'Power', 'Cadence', 'Speed', 'Steering'
  );

  SENSOR_KIND_KEYS: array[TSensorKind] of string = (
    'hr', 'pwr', 'cad', 'spd', 'steer'
  );

{ ── Утилиты ── }

function CreateSensorsForDevice(const AInfo: TDeviceInfo): TDeviceSensorList;

function BuildNetworkId(const ADeviceAddress: string; AKind: TSensorKind): string;
function BuildNameId(const ADeviceName: string; AKind: TSensorKind): string;
function NormalizeDeviceName(const AName: string): string;
function ParseSensorId(const ASensorId: string;
  out APrefix: string; out AKind: TSensorKind): Boolean;

implementation

{ ═══════════════════════════════════════════════════════════════════
  Утилиты
  ═══════════════════════════════════════════════════════════════════ }

function NormalizeDeviceName(const AName: string): string;
var
  I: Integer;
  PrevSpace: Boolean;
begin
  Result := '';
  PrevSpace := True;
  for I := 1 to Length(AName) do
  begin
    if AName[I] <= ' ' then
    begin
      if not PrevSpace then
      begin
        Result := Result + ' ';
        PrevSpace := True;
      end;
    end
    else
    begin
      Result := Result + AName[I];
      PrevSpace := False;
    end;
  end;
  if (Length(Result) > 0) and (Result[Length(Result)] = ' ') then
    SetLength(Result, Length(Result) - 1);
  Result := LowerCase(Result);
end;

function BuildNetworkId(const ADeviceAddress: string; AKind: TSensorKind): string;
begin
  Result := LowerCase(ADeviceAddress) + '/' + SENSOR_KIND_KEYS[AKind];
end;

function BuildNameId(const ADeviceName: string; AKind: TSensorKind): string;
begin
  Result := NormalizeDeviceName(ADeviceName) + '/' + SENSOR_KIND_KEYS[AKind];
end;

function ParseSensorId(const ASensorId: string;
  out APrefix: string; out AKind: TSensorKind): Boolean;
var
  P: Integer;
  KeyStr: string;
  K: TSensorKind;
begin
  Result := False;
  APrefix := '';
  P := Pos('/', ASensorId);
  if P < 2 then Exit;
  APrefix := Copy(ASensorId, 1, P - 1);
  KeyStr := Copy(ASensorId, P + 1, MaxInt);
  for K := Low(TSensorKind) to High(TSensorKind) do
    if SameText(KeyStr, SENSOR_KIND_KEYS[K]) then
    begin
      AKind := K;
      Result := True;
      Exit;
    end;
  APrefix := '';
end;

function CreateSensorsForDevice(const AInfo: TDeviceInfo): TDeviceSensorList;
begin
  Result := TDeviceSensorList.Create(True);

  if AInfo.SupportsHeartRate then
    Result.Add(THRSensor.Create(AInfo.Address, AInfo.Name));

  if AInfo.SupportsPower then
    Result.Add(TPowerSensor.Create(AInfo.Address, AInfo.Name));

  if AInfo.SupportsCadence then
    Result.Add(TCadenceSensor.Create(AInfo.Address, AInfo.Name));

  if AInfo.SupportsSpeed then
    Result.Add(TSpeedSensor.Create(AInfo.Address, AInfo.Name));
  if AInfo.SupportsSteering then
    Result.Add(TSteeringSensor.Create(AInfo.Address, AInfo.Name));
end;

{ ═══════════════════════════════════════════════════════════════════
  TDeviceSensor
  ═══════════════════════════════════════════════════════════════════ }

constructor TDeviceSensor.Create(const ADeviceAddress, ADeviceName: string);
begin
  inherited Create;
  FDeviceAddress := ADeviceAddress;
  FDeviceName := ADeviceName;
  FInstant := 0;
  FPrevInstant := 0;
  FDeviceAverage := 0;
  FSessionSum := 0;
  FSessionCount := 0;
  FSessionMin := 0;
  FSessionMax := 0;
  FHasData := False;
  FLastUpdate := 0;
end;

procedure TDeviceSensor.BuildIds;
begin
  FNetworkId := BuildNetworkId(FDeviceAddress, FKind);
  FNameId := BuildNameId(FDeviceName, FKind);
end;

function TDeviceSensor.DataAgeSec: Double;
begin
  if FLastUpdate = 0 then
    Result := 1e9  { never received data }
  else
    Result := (Now - FLastUpdate) * 86400.0;
end;

function TDeviceSensor.Update(const Data: TTrainerDataRecord): Boolean;
const Metrics: array[TSensorKind] of TTrainerMetric =
  (tmHeartRate, tmPower, tmCadence, tmSpeed, tmSteering);
var
  NewInstant, NewDevAvg: Double;
  M: TTrainerMetric;
begin
  Result := False;
  M := Metrics[FKind];
  if Data.HasMetricMask then
  begin
    if not (M in Data.PresentMetrics) then Exit;
    if (Data.MetricTime[M]<>0) and (Data.MetricTime[M]<FLastUpdate) then Exit;
    if not (M in Data.ValidMetrics) then
    begin
      FHasData := False;
      FInstant := 0;
      Exit;
    end;
  end;
  Result := DoExtract(Data, NewInstant, NewDevAvg);
  if not Result then Exit;

  { Сдвигаем текущее → предыдущее }
  FPrevInstant := FInstant;
  FInstant := NewInstant;
  FDeviceAverage := NewDevAvg;

  { Статистика за сессию }
  FSessionSum := FSessionSum + NewInstant;
  Inc(FSessionCount);

  if FSessionCount=1 then
  begin
    { Первый замер — инициализируем min/max }
    FSessionMin := NewInstant;
    FSessionMax := NewInstant;
  end
  else
  begin
    if NewInstant < FSessionMin then FSessionMin := NewInstant;
    if NewInstant > FSessionMax then FSessionMax := NewInstant;
  end;

  FHasData := True;
  if Data.HasMetricMask and (Data.MetricTime[M] <> 0) then
    FLastUpdate := Data.MetricTime[M]
  else if Data.Timestamp <> 0 then FLastUpdate := Data.Timestamp
  else FLastUpdate := Now;
end;

procedure TDeviceSensor.ResetSession;
begin
  FLastUpdate := 0;
  FInstant := 0;
  FPrevInstant := 0;
  FDeviceAverage := 0;
  FSessionSum := 0;
  FSessionCount := 0;
  FSessionMin := 0;
  FSessionMax := 0;
  FHasData := False;
end;

function TDeviceSensor.GetSessionAverage: Double;
begin
  if FSessionCount > 0 then
    Result := FSessionSum / FSessionCount
  else
    Result := 0;
end;

function TDeviceSensor.GetDelta: Double;
begin
  Result := FInstant - FPrevInstant;
end;

{ ── Форматирование (базовый — целые числа) ── }

function TDeviceSensor.FormatInstant: string;
begin
  if FHasData then
    Result := IntToStr(Round(FInstant)) + ' ' + UnitLabel
  else
    Result := '--';
end;

function TDeviceSensor.FormatDeviceAverage: string;
begin
  if FHasData then
    Result := IntToStr(Round(FDeviceAverage)) + ' ' + UnitLabel
  else
    Result := '--';
end;

function TDeviceSensor.FormatSessionAverage: string;
begin
  if FSessionCount > 0 then
    Result := IntToStr(Round(SessionAverage)) + ' ' + UnitLabel
  else
    Result := '--';
end;

function TDeviceSensor.FormatMinMax: string;
begin
  if FHasData then
    Result := IntToStr(Round(FSessionMin)) + '/' +
              IntToStr(Round(FSessionMax)) + ' ' + UnitLabel
  else
    Result := '--/--';
end;

function TDeviceSensor.FormatDelta: string;
var
  D: Double;
begin
  if not FHasData then
    Result := '--'
  else
  begin
    D := Delta;
    if D > 0 then
      Result := '+' + IntToStr(Round(D))
    else
      Result := IntToStr(Round(D));
  end;
end;

{ ═══════════════════════════════════════════════════════════════════
  THRSensor
  ═══════════════════════════════════════════════════════════════════ }

constructor THRSensor.Create(const ADeviceAddress, ADeviceName: string);
begin
  inherited Create(ADeviceAddress, ADeviceName);
  FKind := skHeartRate;
  BuildIds;
end;

function THRSensor.DoExtract(const Data: TTrainerDataRecord;
  out AInstant, ADeviceAverage: Double): Boolean;
begin
  AInstant := Data.HeartRate;
  ADeviceAverage := Data.HeartRate; { HRM не передаёт отдельный average }
  Result := Data.HeartRate > 0;
end;

class function THRSensor.SensorName: string;
begin Result := 'Heart Rate'; end;

class function THRSensor.UnitLabel: string;
begin Result := 'bpm'; end;

class function THRSensor.Kind: TSensorKind;
begin Result := skHeartRate; end;

class function THRSensor.SensorKey: string;
begin Result := 'hr'; end;

{ ═══════════════════════════════════════════════════════════════════
  TPowerSensor
  ═══════════════════════════════════════════════════════════════════ }

constructor TPowerSensor.Create(const ADeviceAddress, ADeviceName: string);
begin
  inherited Create(ADeviceAddress, ADeviceName);
  FKind := skPower;
  BuildIds;
end;

function TPowerSensor.DoExtract(const Data: TTrainerDataRecord;
  out AInstant, ADeviceAverage: Double): Boolean;
begin
  AInstant := Data.InstantPower;
  ADeviceAverage := Data.AveragePower;
  { Always accept — device sends 0W when pedaling stops }
  Result := True;
end;

class function TPowerSensor.SensorName: string;
begin Result := 'Power'; end;

class function TPowerSensor.UnitLabel: string;
begin Result := 'W'; end;

class function TPowerSensor.Kind: TSensorKind;
begin Result := skPower; end;

class function TPowerSensor.SensorKey: string;
begin Result := 'pwr'; end;

{ ═══════════════════════════════════════════════════════════════════
  TCadenceSensor
  ═══════════════════════════════════════════════════════════════════ }

constructor TCadenceSensor.Create(const ADeviceAddress, ADeviceName: string);
begin
  inherited Create(ADeviceAddress, ADeviceName);
  FKind := skCadence;
  BuildIds;
end;

function TCadenceSensor.DoExtract(const Data: TTrainerDataRecord;
  out AInstant, ADeviceAverage: Double): Boolean;
begin
  AInstant := Data.InstantCadence;
  ADeviceAverage := Data.AverageCadence;
  { Always accept — device sends 0 rpm when pedaling stops }
  Result := True;
end;

class function TCadenceSensor.SensorName: string;
begin Result := 'Cadence'; end;

class function TCadenceSensor.UnitLabel: string;
begin Result := 'rpm'; end;

class function TCadenceSensor.Kind: TSensorKind;
begin Result := skCadence; end;

class function TCadenceSensor.SensorKey: string;
begin Result := 'cad'; end;

{ ═══════════════════════════════════════════════════════════════════
  TSpeedSensor
  ═══════════════════════════════════════════════════════════════════ }

constructor TSpeedSensor.Create(const ADeviceAddress, ADeviceName: string);
begin
  inherited Create(ADeviceAddress, ADeviceName);
  FKind := skSpeed;
  BuildIds;
end;

function TSpeedSensor.DoExtract(const Data: TTrainerDataRecord;
  out AInstant, ADeviceAverage: Double): Boolean;
begin
  AInstant := Data.InstantSpeed;
  ADeviceAverage := Data.AverageSpeed;
  { Always accept — device sends 0 km/h when stopped }
  Result := True;
end;

class function TSpeedSensor.SensorName: string;
begin Result := 'Speed'; end;

class function TSpeedSensor.UnitLabel: string;
begin Result := 'km/h'; end;

class function TSpeedSensor.Kind: TSensorKind;
begin Result := skSpeed; end;

class function TSpeedSensor.SensorKey: string;
begin Result := 'spd'; end;

function TSpeedSensor.FormatInstant: string;
begin
  if FHasData then
    Result := FormatFloat('0.0', FInstant) + ' ' + UnitLabel
  else
    Result := '--';
end;

function TSpeedSensor.FormatDeviceAverage: string;
begin
  if FHasData then
    Result := FormatFloat('0.0', FDeviceAverage) + ' ' + UnitLabel
  else
    Result := '--';
end;

function TSpeedSensor.FormatSessionAverage: string;
begin
  if FSessionCount > 0 then
    Result := FormatFloat('0.0', SessionAverage) + ' ' + UnitLabel
  else
    Result := '--';
end;

function TSpeedSensor.FormatMinMax: string;
begin
  if FHasData then
    Result := FormatFloat('0.0', FSessionMin) + '/' +
              FormatFloat('0.0', FSessionMax) + ' ' + UnitLabel
  else
    Result := '--/--';
end;

constructor TSteeringSensor.Create(const ADeviceAddress, ADeviceName: string);
begin
  inherited Create(ADeviceAddress, ADeviceName);
  FKind := skSteering;
  BuildIds;
end;

function TSteeringSensor.DoExtract(const Data: TTrainerDataRecord;
  out AInstant, ADeviceAverage: Double): Boolean;
begin
  Result := Data.HasMetricMask and (tmSteering in Data.ValidMetrics);
  AInstant := Data.SteeringAngle; ADeviceAverage := AInstant;
end;
class function TSteeringSensor.SensorName: string;
begin Result := 'Steering' end;
class function TSteeringSensor.UnitLabel: string;
begin Result := 'deg' end;
class function TSteeringSensor.Kind: TSensorKind;
begin Result := skSteering end;
class function TSteeringSensor.SensorKey: string;
begin Result := 'steer' end;
function TSteeringSensor.FormatInstant: string;
begin
  if HasData then Result := FormatFloat('0.0', Instant) + ' ' + UnitLabel
  else Result := '--';
end;

end.
