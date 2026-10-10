{ GameDeviceTypes — транспорт-агностичные типы для UI-слоя.

  TGameDeviceEntry владеет списком TDeviceSensor.
  Сенсоры хранят собственное состояние (instant, prev, avg, min/max).
  UI читает данные напрямую из сенсоров, без TTrainerDataRecord. }
unit GameDeviceTypes;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils,
  CastleVectors, CastleColors,
  TrainerData, GameDeviceSensor;

type
  TGameDeviceConnectionState = (
    gdcsDisconnected,
    gdcsScanning,
    gdcsConnecting,
    gdcsConnected,
    gdcsError
  );

  TGameDeviceEntry = class
  private
    FSensors: TDeviceSensorList;
  public
    DeviceInfo: TDeviceInfo;
    ConnectionState: TGameDeviceConnectionState;
    LastMessage: String;
    TestedNotFitness: Boolean;  { device was connected, found no fitness services }

    { Время последней реальной смены ConnectionState (TDateTime, локальное).
      Используется CheckStaleConnections для отлова "застрявших"
      gdcsConnecting / gdcsError, у которых давно не приходило новых
      событий от провайдера. Обновляется в TGameDeviceService везде,
      где меняется ConnectionState. }
    LastStateChange: TDateTime;

    { Сырой пакет данных — хранится для полей, ещё не покрытых сенсорами
      (Distance, TotalEnergy, ElapsedTime, ResistanceLevel, TargetPower,
       Incline, IsMoving, IsPaused, Timestamp).
      Новый код должен читать данные из сенсоров, а не отсюда.
      Будет убрано после полной миграции на сенсоры. }
    LastData: TTrainerDataRecord;

    constructor Create(const ADeviceInfo: TDeviceInfo);
    destructor Destroy; override;

    function DisplayName: String;
    function IsTrainerDevice: Boolean;
    function IsControllable: Boolean;
    function IsHeartRateOnlyDevice: Boolean;
    function TransportLabel: String;
    { Базовый цвет «значка» транспорта на карточке устройства.
      Разные транспорты различаются по цвету: BLE — голубой,
      ANT+ — оранжево-красный (бренд ANT+), прочие — серый. }
    function TransportLabelColor: TCastleColor;

    { ─── Сенсоры ─── }

    property Sensors: TDeviceSensorList read FSensors;

    { Прогнать новый пакет данных через все сенсоры И сохранить в LastData.
      Каждый сенсор извлечёт своё и обновит свой стейт. }
    procedure FeedData(const Data: TTrainerDataRecord);
    function DiscoverMetrics(const Data: TTrainerDataRecord): Boolean;

    { Сброс сессионной статистики у всех сенсоров (новая тренировка) }
    procedure ResetAllSensors;

    { Пересоздать список сенсоров (напр. после обновления DeviceInfo) }
    procedure RebuildSensors;

    { ── Поиск ── }

    function FindSensor(AKind: TSensorKind): TDeviceSensor;
    function FindSensorByNetworkId(const ANetworkId: string): TDeviceSensor;
    function FindSensorByNameId(const ANameId: string): TDeviceSensor;
    function ResolveSensor(const ANetworkId, ANameId: string): TDeviceSensor;

    { Типизированные аксессоры }
    function HRSensor: THRSensor;
    function PowerSensor: TPowerSensor;
    function CadenceSensor: TCadenceSensor;
    function SpeedSensor: TSpeedSensor;
  end;

  { Алиасы для обратной совместимости }
  TGameBLEConnectionState = TGameDeviceConnectionState;
  TGameBLEDeviceEntry = TGameDeviceEntry;

const
  gbcsDisconnected = gdcsDisconnected;
  gbcsScanning     = gdcsScanning;
  gbcsConnecting   = gdcsConnecting;
  gbcsConnected    = gdcsConnected;
  gbcsError        = gdcsError;

implementation

{ TGameDeviceEntry }

constructor TGameDeviceEntry.Create(const ADeviceInfo: TDeviceInfo);
begin
  inherited Create;
  DeviceInfo := ADeviceInfo;
  ConnectionState := gdcsDisconnected;
  LastStateChange := Now;
  LastMessage := '';
  FillChar(LastData, SizeOf(LastData), 0);
  FSensors := CreateSensorsForDevice(ADeviceInfo);
end;

destructor TGameDeviceEntry.Destroy;
begin
  FreeAndNil(FSensors);
  inherited;
end;

function TGameDeviceEntry.DisplayName: String;
begin
  Result := Trim(DeviceInfo.Name);
  if Result = '' then
    Result := DeviceInfo.Address;
  if Result = '' then
    Result := 'Device';
  if DeviceInfo.ProviderName <> '' then
    Result := Result + ' (' + DeviceInfo.ProviderName + ')';
end;

function TGameDeviceEntry.IsTrainerDevice: Boolean;
begin
  Result :=
    DeviceInfo.SupportsFTMS or
    DeviceInfo.SupportsPower or
    DeviceInfo.SupportsCadence or DeviceInfo.SupportsSpeed;
end;

function TGameDeviceEntry.IsControllable: Boolean;
begin
  Result := DeviceInfo.SupportsControl;
end;

function TGameDeviceEntry.IsHeartRateOnlyDevice: Boolean;
begin
  Result := DeviceInfo.SupportsHeartRate and (not IsTrainerDevice);
end;

function TGameDeviceEntry.TransportLabel: String;
begin
  Result := TRANSPORT_TYPE_NAMES[DeviceInfo.TransportType];
end;

function TGameDeviceEntry.TransportLabelColor: TCastleColor;
begin
  case DeviceInfo.TransportType of
    ttBLE:     Result := Vector4(0.30, 0.65, 1.00, 1);  // Bluetooth blue
    ttANTPlus: Result := Vector4(0.95, 0.45, 0.20, 1);  // ANT+ brand orange-red
    ttSim:     Result := Vector4(0.70, 0.40, 0.85, 1);  // фиолетовый — заметно «не настоящий»
  else
    Result := Vector4(0.50, 0.50, 0.50, 1);             // нейтральный серый
  end;
end;

{ ─── Данные ─── }

procedure TGameDeviceEntry.FeedData(const Data: TTrainerDataRecord);
var
  I: Integer;
begin
  { Сохраняем сырой пакет для полей, не покрытых сенсорами }
  LastData.PresentMetrics := [];
  MergeTrainerData(LastData, Data);

  { Обновляем все сенсоры }
  if not Assigned(FSensors) then Exit;
  for I := 0 to FSensors.Count - 1 do
    FSensors[I].Update(Data);
end;

function TGameDeviceEntry.DiscoverMetrics(const Data: TTrainerDataRecord): Boolean;
begin
  Result := LearnTrainerMetrics(DeviceInfo, Data);
  if not Result then Exit;
  if FSensors = nil then FSensors := TDeviceSensorList.Create(True);
  if DeviceInfo.SupportsPower and (PowerSensor = nil) then
    FSensors.Add(TPowerSensor.Create(DeviceInfo.Address, DeviceInfo.Name));
  if DeviceInfo.SupportsCadence and (CadenceSensor = nil) then
    FSensors.Add(TCadenceSensor.Create(DeviceInfo.Address, DeviceInfo.Name));
  if DeviceInfo.SupportsSpeed and (SpeedSensor = nil) then
    FSensors.Add(TSpeedSensor.Create(DeviceInfo.Address, DeviceInfo.Name));
  if DeviceInfo.SupportsHeartRate and (HRSensor = nil) then
    FSensors.Add(THRSensor.Create(DeviceInfo.Address, DeviceInfo.Name));
  if DeviceInfo.SupportsSteering and (FindSensor(skSteering) = nil) then
    FSensors.Add(TSteeringSensor.Create(DeviceInfo.Address, DeviceInfo.Name));
  TestedNotFitness := False;
end;

procedure TGameDeviceEntry.ResetAllSensors;
var
  I: Integer;
begin
  if not Assigned(FSensors) then Exit;
  for I := 0 to FSensors.Count - 1 do
    { Steering is an absolute input, independent of workout statistics.
      Keeping a held angle is essential for change-only notifications. }
    if FSensors[I].SensorKind<>skSteering then FSensors[I].ResetSession;
end;

procedure TGameDeviceEntry.RebuildSensors;
begin
  FreeAndNil(FSensors);
  FSensors := CreateSensorsForDevice(DeviceInfo);
end;

{ ─── Поиск ─── }

function TGameDeviceEntry.FindSensor(AKind: TSensorKind): TDeviceSensor;
var
  I: Integer;
begin
  Result := nil;
  if not Assigned(FSensors) then Exit;
  for I := 0 to FSensors.Count - 1 do
    if FSensors[I].SensorKind = AKind then
      Exit(FSensors[I]);
end;

function TGameDeviceEntry.FindSensorByNetworkId(
  const ANetworkId: string): TDeviceSensor;
var
  I: Integer;
begin
  Result := nil;
  if (ANetworkId = '') or not Assigned(FSensors) then Exit;
  for I := 0 to FSensors.Count - 1 do
    if SameText(FSensors[I].NetworkId, ANetworkId) then
      Exit(FSensors[I]);
end;

function TGameDeviceEntry.FindSensorByNameId(
  const ANameId: string): TDeviceSensor;
var
  I: Integer;
begin
  Result := nil;
  if (ANameId = '') or not Assigned(FSensors) then Exit;
  for I := 0 to FSensors.Count - 1 do
    if SameText(FSensors[I].NameId, ANameId) then
      Exit(FSensors[I]);
end;

function TGameDeviceEntry.ResolveSensor(
  const ANetworkId, ANameId: string): TDeviceSensor;
begin
  Result := FindSensorByNetworkId(ANetworkId);
  if not Assigned(Result) then
    Result := FindSensorByNameId(ANameId);
end;

function TGameDeviceEntry.HRSensor: THRSensor;
begin Result := THRSensor(FindSensor(skHeartRate)); end;

function TGameDeviceEntry.PowerSensor: TPowerSensor;
begin Result := TPowerSensor(FindSensor(skPower)); end;

function TGameDeviceEntry.CadenceSensor: TCadenceSensor;
begin Result := TCadenceSensor(FindSensor(skCadence)); end;

function TGameDeviceEntry.SpeedSensor: TSpeedSensor;
begin Result := TSpeedSensor(FindSensor(skSpeed)); end;

end.
