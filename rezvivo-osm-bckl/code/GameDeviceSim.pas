{ GameDeviceSim — синтетический транспорт-провайдер для воспроизведения
  ранее записанного FIT-файла как если бы это был настоящий трейнер.

  Зачем: разработчику нужно тестировать игру (физика, физическая модель,
  HUD, логирование, отправка на сервер) без подключения реальных
  устройств — особенно когда нет тренажёра под рукой или нужно
  воспроизвести конкретный сценарий повторяемо.

  Архитектурно симулятор — обычный TTransportProvider (как BLE, ANT+).
  Регистрируется в DeviceService рядом с ними. В UI устройства ничем не
  отличается от реальных — кроме фиолетовой плашки "Sim" и имени файла
  в названии. Остальная игра (физика, HUD, отправка) ничего не знает
  про симуляцию: получает обычные TTrainerDataRecord через стандартный
  callback OnDataReceived.

  Поведение:
    • Скан возвращает ровно одно "устройство" — путь к выбранному в
      Settings FIT-файлу. Если файл не задан или не существует — нет
      устройств, поведение нейтральное.
    • Connect загружает FIT. Во время заезда главный поток передаёт
      один шаг часов плеера физике, анимации и телеметрии. Пакеты
      датчиков обновляются также на паузе, сохраняя текущие значения.
    • На конце файла — loop с самого начала. Это документированное
      поведение для удобства долгих тестовых сессий.
    • Команды управления (SetTargetPower, SetSimulation и т.д.) принимаются,
      но игнорируются. Логируются для отладки. }
unit GameDeviceSim;

{$mode objfpc}{$H+}{$codepage UTF8}

interface

uses
  Classes, SysUtils, syncobjs, fgl,
  TrainerData, GameTransportBase, GameSensorLog, GameSimClock;

type
  TSimTransportSession = class;

  { TSimTransportProvider — публикует одно sim-устройство (тот FIT,
    что выбран в Settings.SimulationFitPath). При повторных скан'ах
    устройство переэмитится — так консистентно с BLE/ANT+ поведением. }
  TSimTransportProvider = class(TTransportProvider)
  public
    procedure StartScan; override;
    procedure StopScan; override;
    function CreateSession(const AAddress: string;
      const AFriendlyName: string = ''): TTransportSession; override;

    class function TransportType: TTransportType; override;
    function AdapterDisplayName: string; override;
    function AdapterKey: string; override;

  end;

  { FIT playback on the ride clock; all playback controls run on the main thread. }
  TSimTransportSession = class(TTransportSession)
  private
    FFitPath: string;
    FRecords: TSensorSessionRecordArray;
    FLoadedCount: Integer;
    FClock: TSimPlaybackClock;
    FCurrentIdx: Integer;
    FLastEmitTick: QWord;
    procedure ReadFitRecord(const ARecord: TSensorSessionRecord);
    procedure LoadFit;
  public
    constructor Create(const AAddress: string; const AFriendlyName: string = ''); override;
    destructor Destroy; override;

    { Deliver telemetry through the normal sensor pipeline. }
    procedure FeedSimData(const Data: TTrainerDataRecord);

    { Запуск/остановка проигрывания FIT. Connect (выше) только грузит
      файл; реальный поток данных стартует только когда игра вошла
      в активное состояние (TViewPlay.Start), и останавливается на Stop.
      Это даёт каждой тестовой сессии детерминированный старт от
      первой записи. }
    procedure StartPlayback;
    procedure StopPlayback;

    { UI-управление плеером. Pause/Resume — без сброса позиции.
      Restart — перемотать в начало файла, продолжить играть.
      Все команды выполняются на главном потоке игры. }
    procedure SetPaused(APaused: Boolean);
    procedure RestartPlayback;
    function  IsPaused: Boolean;
    procedure SeekSec(Seconds: Double);
    function AdvancePlayback(RealSeconds: Single): Single;
    procedure StepFrame;
    procedure PublishCurrent;
    function PositionSec: Double;
    function DurationSec: Double;
    function LoopSerial: Cardinal;

    { 1/60 = one simulation frame per real second; other rates scale ride time. }
    procedure SetSpeedMul(AMul: Single);
    function  SpeedMul: Single;

    { Record indices are diagnostics only: FIT can contain gaps in time. }
    function  RecordCount: Integer;
    function  CurrentIdx: Integer;

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
  end;

implementation

uses
  AppSettings, DebugLog, Math, FitFile;

{ ─── TSimTransportProvider ─── }

procedure TSimTransportProvider.StartScan;
var
  Path: string;
  DevInfo: TDeviceInfo;
begin
  { Sim-устройство появляется только когда выполнены ОБА условия:
      • в Settings выбран существующий FIT-файл,
      • галка симуляции включена.
    Без этого провайдер пуст — никакого устройства в списке. Это
    важно, иначе sim-устройство попадает в auto-connect даже когда
    юзер не просит симуляцию (раздражает в обычной игре). }
  if not Settings.GetSimulationEnabled then
  begin
    Logger.Info('[Sim] StartScan: simulation disabled — no devices');
    Exit;
  end;
  Path := Settings.EffectiveSimulationFitPath;
  if (Path = '') or (not FileExists(Path)) then
  begin
    Logger.Info('[Sim] StartScan: no FIT path or file missing — no devices');
    Exit;
  end;

  DevInfo := Default(TDeviceInfo);
  DevInfo.Name := 'Sim: ' + ExtractFileName(Path);
  DevInfo.Address := 'sim:' + Path;
  DevInfo.TransportType := ttSim;
  DevInfo.ProviderName := 'Sim';
  DevInfo.SupportsFTMS := True;
  DevInfo.SupportsControl := True;
  DevInfo.SupportsPower := True;
  DevInfo.SupportsCadence := True;
  DevInfo.SupportsSpeed := True;
  DevInfo.SupportsHeartRate := True;

  if Assigned(OnDeviceFound) then
    OnDeviceFound(DevInfo);

  Logger.Info('[Sim] ' + 'StartScan emitted device for ' + Path);
end;

procedure TSimTransportProvider.StopScan;
begin
  { No-op: скан не ведётся в фоне, StartScan однократно эмитит. }
end;

function TSimTransportProvider.CreateSession(const AAddress: string;
  const AFriendlyName: string): TTransportSession;
begin
  Result := TSimTransportSession.Create(AAddress, AFriendlyName);
end;

class function TSimTransportProvider.TransportType: TTransportType;
begin
  Result := ttSim;
end;

function TSimTransportProvider.AdapterDisplayName: string;
begin
  Result := 'Simulation';
end;

function TSimTransportProvider.AdapterKey: string;
begin
  Result := 'Simulation';
end;

{ ─── TSimTransportSession ─── }

constructor TSimTransportSession.Create(const AAddress: string;
  const AFriendlyName: string);
begin
  inherited Create(AAddress, AFriendlyName);
  FFitPath := '';
  FRecords := nil;
  FClock := TSimPlaybackClock.Create;
  FCurrentIdx := 0;

  FDeviceInfo.Name := AFriendlyName;
  FDeviceInfo.Address := AAddress;
  FDeviceInfo.TransportType := ttSim;
  FDeviceInfo.ProviderName := 'Sim';
  FDeviceInfo.SupportsFTMS := True;
  FDeviceInfo.SupportsControl := True;
  FDeviceInfo.SupportsPower := True;
  FDeviceInfo.SupportsCadence := True;
  FDeviceInfo.SupportsSpeed := True;
  FDeviceInfo.SupportsHeartRate := True;

  { Адрес имеет вид "sim:<path>" — извлекаем путь. }
  if Pos('sim:', AAddress) = 1 then
    FFitPath := Copy(AAddress, 5, MaxInt);

  { Как FTMS-тренажёр: команды принимаем (и глушим), чтобы исходящий
    SetSimulation/SetIncline из HUD шёл тем же путём, что на железе. }
  FTrainerFeatures.SupportsPowerControl := True;
  FTrainerFeatures.SupportsResistanceControl := True;
  FTrainerFeatures.SupportsInclineControl := True;
  FTrainerFeatures.SupportsSimulation := True;
end;

destructor TSimTransportSession.Destroy;
begin
  ShutdownControl;
  Disconnect;
  FClock.Free;
  inherited Destroy;
end;

procedure TSimTransportSession.FeedSimData(const Data: TTrainerDataRecord);
begin
  FLock.Enter;
  try
    FLastData := Data;
  finally
    FLock.Leave;
  end;
  if not Assigned(OnDataReceived) then
    Logger.Warning('[Sim] FeedSimData: OnDataReceived NOT assigned — data lost');
  NotifyDataReceived;
end;

procedure TSimTransportSession.ReadFitRecord(const ARecord: TSensorSessionRecord);
begin
  if FLoadedCount = Length(FRecords) then
    SetLength(FRecords, Max(1024, FLoadedCount * 2));
  FRecords[FLoadedCount] := ARecord;
  if FLoadedCount > 0 then
    FRecords[FLoadedCount].ElapsedSec := Max(FRecords[FLoadedCount - 1].ElapsedSec,
      ARecord.TimestampUtcUnix - FRecords[0].TimestampUtcUnix);
  Inc(FLoadedCount);
end;

procedure TSimTransportSession.LoadFit;
var Fit: TFitFile;
begin
  FRecords := nil;
  FLoadedCount := 0;
  Fit := TFitFile.Create;
  try
    Fit.OnSensorRecord := @ReadFitRecord;
    { One FIT decoder for routes and playback: endianness, compressed
      timestamps, developer fields, enhanced speed and CRC validation.
      Telemetry is delivered even when a record has no GPS coordinates. }
    if not Fit.LoadFromFile(FFitPath) then FLoadedCount := 0;
  finally
    Fit.Free;
    SetLength(FRecords, FLoadedCount);
  end;
  Logger.Info(Format('[Sim] LoadFit: parsed %d records from %s',
    [Length(FRecords), FFitPath]));
end;

function TSimTransportSession.Connect: Boolean;
begin
  Result := False;
  Logger.Info('[Sim] Session.Connect: ' + FFitPath +
              ' OnDataReceived=' + BoolToStr(Assigned(OnDataReceived), True));
  if FFitPath = '' then
  begin
    SetConnectionState(csError, 'No FIT path');
    Exit;
  end;

  SetConnectionState(csConnecting, '');
  LoadFit;
  if Length(FRecords) = 0 then
  begin
    SetConnectionState(csError, 'FIT load failed or empty');
    Exit;
  end;

  { Connect только грузит FIT — плеер стартует позже, при входе в игру
    (через StartPlayback). Это даёт детерминированный старт каждой
    тестовой сессии: симулятор не "набегает" пока юзер ещё в меню. }
  FClock.Duration := FRecords[High(FRecords)].ElapsedSec + 1;
  FClock.Seek(0);
  SetConnectionState(csConnected, 'Sim ready');
  Logger.Info(Format('[Sim] Session.Connect OK, %d records loaded (player not started)',
    [Length(FRecords)]));
  Result := True;
end;

procedure TSimTransportSession.StartPlayback;
begin
  if FClock.Playing or (Length(FRecords)=0) then Exit;
  FClock.Start;
  PublishCurrent;
  Logger.Info(Format('[Sim] Playback started (%d records)',[Length(FRecords)]));
end;

procedure TSimTransportSession.StopPlayback;
begin FClock.Stop end;

procedure TSimTransportSession.SetPaused(APaused: Boolean);
begin
  if FClock.Paused=APaused then Exit;
  FClock.Paused:=APaused;
  { A paused frame retains its telemetry, rather than replacing it by zeros. }
  PublishCurrent;
  Logger.Info('[Sim] Paused = '+BoolToStr(APaused,True));
end;

function TSimTransportSession.IsPaused: Boolean;
begin Result:=FClock.Paused end;

procedure TSimTransportSession.SetSpeedMul(AMul: Single);
begin FClock.Rate:=AMul; Logger.Info(Format('[Sim] SpeedMul = %.6fx',[FClock.Rate])) end;

function TSimTransportSession.SpeedMul: Single;
begin Result:=FClock.Rate end;

procedure TSimTransportSession.SeekSec(Seconds: Double);
begin FClock.Seek(Seconds); PublishCurrent end;

procedure TSimTransportSession.StepFrame;
begin FClock.Step end;

function TSimTransportSession.PositionSec: Double;
begin Result:=FClock.Position end;

function TSimTransportSession.DurationSec: Double;
begin Result:=FClock.Duration end;

function TSimTransportSession.LoopSerial: Cardinal;
begin Result:=FClock.Loop end;

procedure TSimTransportSession.PublishCurrent;
var Lo,Hi,Mid: Integer; Data: TTrainerDataRecord;
begin
  if Length(FRecords)=0 then Exit;
  { FIT timestamps need not be contiguous or sampled exactly once a second. }
  Lo:=0; Hi:=High(FRecords);
  while Lo<Hi do begin
    Mid:=(Lo+Hi+1) div 2;
    if FRecords[Mid].ElapsedSec<=FClock.Position then Lo:=Mid else Hi:=Mid-1;
  end;
  FCurrentIdx:=Lo;
  Data:=Default(TTrainerDataRecord);
  Data.Timestamp:=Now;
  Data.InstantPower:=FRecords[Lo].Power;
  Data.InstantCadence:=FRecords[Lo].Cadence;
  Data.HeartRate:=FRecords[Lo].HeartRate;
  Data.InstantSpeed:=FRecords[Lo].SpeedKmh;
  Data.Distance:=FRecords[Lo].DistanceM;
  Data.ElapsedTime:=Trunc(FClock.Position);
  Data.Incline:=Round(FRecords[Lo].SlopePct*10);
  Data.IsMoving:=(Data.InstantPower>0) or (Data.InstantCadence>0) or (Data.InstantSpeed>0.1);
  FLastEmitTick:=GetTickCount64;
  FeedSimData(Data);
end;

function TSimTransportSession.AdvancePlayback(RealSeconds: Single): Single;
var Before: Integer;
begin
  Before:=Trunc(FClock.Position);
  Result:=FClock.Advance(RealSeconds,GetTickCount64);
  if (Trunc(FClock.Position)<>Before) or (GetTickCount64-FLastEmitTick>=250) then PublishCurrent;
end;

procedure TSimTransportSession.RestartPlayback;
begin SeekSec(0); FClock.Paused:=False; FClock.Start end;

function TSimTransportSession.RecordCount: Integer;
begin Result:=Length(FRecords) end;

function TSimTransportSession.CurrentIdx: Integer;
begin Result:=FCurrentIdx end;

procedure TSimTransportSession.Disconnect;
begin
  StopPlayback;
  SetConnectionState(csDisconnected, '');
end;

function TSimTransportSession.RequestControl: Boolean;
begin
  Result := True;
  FHasControl := True;
end;

function TSimTransportSession.SetTargetPower(Watts: Word): Boolean;
begin
  Logger.Debug(Format('[Sim] SetTargetPower(%d) — ignored in sim', [Watts]));
  Result := True;
end;

function TSimTransportSession.SetResistanceLevel(Level: Byte): Boolean;
begin
  Logger.Debug(Format('[Sim] SetResistanceLevel(%d) — ignored in sim', [Level]));
  Result := True;
end;

function TSimTransportSession.SetIncline(InclinePercent: Single): Boolean;
begin
  Logger.Debug(Format('[Sim] SetIncline(%.1f%%) — ignored in sim', [InclinePercent]));
  Result := True;
end;

function TSimTransportSession.SetSimulation(Grade: Single; WindSpeed: Single;
  RiderWeight: Single; BikeWeight: Single): Boolean;
begin
  Logger.Debug(Format('[Sim] SetSimulation(grade=%.1f) — ignored in sim', [Grade]));
  Result := True;
end;

function TSimTransportSession.Start: Boolean;
begin
  Result := True;
end;

function TSimTransportSession.Stop: Boolean;
begin
  Result := True;
end;

function TSimTransportSession.Pause: Boolean;
begin
  Result := True;
end;

function TSimTransportSession.Reset: Boolean;
begin
  Result := True;
end;

class function TSimTransportSession.TransportType: TTransportType;
begin
  Result := ttSim;
end;

end.
