{ TBLEHudUpdater — manages BLE telemetry reading,
  trainer slope control, and HUD label updates.
  Extracted from TViewPlay to reduce god-object complexity.

  Uses the selected local rider device context for power, speed, heart rate,
  cadence, trainer control, recording status, and training totals. }
unit GameBLEHud;

interface

uses
  SysUtils, Math,
  CastleControls, CastleLog, GameZoneWheel, GameHudZones, GamePowerAccumulator,
  TrainerData, GamePhysicalAgent, GamePhysicsCommon,
  GameLoopbackSession, GameDeviceService, GameDeviceSensor, DebugLog, GameActivityAccounting;

type
  { Labels structure to avoid passing many individual references }
  THudLabels = record
    LabelRiderName: TCastleLabel;
    LabelPowerComparison: TCastleLabel;
    LabelSpeed: TCastleLabel;
    LabelPower: TCastleLabel;
    LabelWork: TCastleLabel;
    LabelWorkTSS: TCastleLabel;
    LabelCorr: TCastleLabel;   { применённая поправка FIT−меш, п.п. уклона }
    LabelCadence: TCastleLabel;
    LabelHeart: TCastleLabel;
    LabelSlope: TCastleLabel;
    LabelTransmission:TCastleLabel;
    LabelPitch: TCastleLabel;
    LabelInfo: TCastleLabel;
    LabelRecordingStatus:TCastleLabel;
    WheelPower, WheelHeart, WheelCadence: TCastleZoneWheel;
  end;

  TBLEHudUpdater = class
  private
    FProfileIndex:Integer;
    FBLESlopeUpdateTime: Single;
    FLastSentBLESlope: Single;
    FSimulationActive: Boolean;     { True после первой отправки SetSimulation }
    FLastGearing:Boolean;
    FLastGear:Integer;
    FLastControlDevice:Pointer;
    FTrainerGrade: Single;          { инерционный уклон, % — то, что шлём }
    FTrainerTargetGrade: Single;
    FTrainerSensitivity:Integer;
    FTrainerAdjustmentPending:Boolean;
    FTrainerGradeInited: Boolean;
    FLabels: THudLabels;
    FPowerBounds, FHeartBounds, FCadenceBounds: TZoneBounds;
    FFtp: Integer;
    FPowerMetrics: TPowerAccumulator;
    FPowerAvailable: Boolean;
    FNumberFormat: TFormatSettings;
    function RiderDevices:TGameDeviceService;
    procedure UpdateRiderLabels;
    procedure ConfigureWheels;

    { Цель из физики → FTrainerGrade с запаздыванием (тренажёр сам
      инерции не имеет: после спуска на скорости подъём не должен
      сразу вдавить педали). }
    procedure StepTrainerInertia(const ATargetGrade, ASpeedMps, ADt: Single);

    { Хелперы чтения из активных сенсоров }
    function GetPower: Double;
    function GetCadence: Double;
    function GetSpeedKmh: Double;
    function GetHeartRate: Double;
    function HasAnyData: Boolean;
  public
    { Параметры симуляции (используются в SetSimulation) }
    ManualPower:Single; { -1: sensors; keyboard input is display-only, never measured work. }
    ManualCadence:Single;
    UserWeight: Single;   { кг, по умолчанию 75 }
    BikeWeight: Single;   { кг, по умолчанию 10 }

    constructor Create(AProfileIndex:Integer=0);
    destructor Destroy; override;
    function ReadMeasuredPower: TMeasuredPower;
    function ReadSensorPower: TMeasuredPower;
    procedure UpdatePowerMetrics(const SecondsPassed: Single;
      const Accounting: TActivityAccounting; const WallSeconds:Single);

    { Set label references — call once after design is loaded }
    procedure SetLabels(const ALabels: THudLabels);

    { Read current sensor data and apply power to agent.
      Call once per frame. }
    procedure UpdateBLETelemetry(AActiveAgent: TPhysicalAgent);

    { Send slope to trainer if enough time/delta has passed.
      Call once per frame. }
    procedure UpdateBLETrainerControl(AActiveAgent: TPhysicalAgent;
      const SecondsPassed: Single);
    procedure SuspendTrainerControl;

    { Update all HUD labels with current state.
      ALoopbackSession may be nil if not in loopback mode. }
    procedure UpdateInfoLabels(AActiveAgent: TPhysicalAgent;
      ALoopbackSession: TGameLoopbackSession);

    { Query helpers }
    function LastSentBLESlope: Single;
    function PowerZone(Watts:Single;Ftp:Single=-1):Integer;
    function PowerZoneCount:Integer;
    property ProfileIndex:Integer read FProfileIndex;
    property TrainerTargetGrade:Single read FTrainerTargetGrade;
    property TrainerFilteredGrade:Single read FTrainerGrade;

    { Обратная совместимость: собрать TTrainerDataRecord из активных сенсоров.
      Используется SensorLog и RemoteRiders пока они не мигрированы. }
    function BLEDataValid: Boolean;
    function BLEData: TTrainerDataRecord;

    { Reset state — call at Start }
    procedure Reset;
  end;

implementation

uses UiTranslations, VeloSiteAPI, CastleColors, CastleVectors, GameDailyTraining, GameUserData,GameSensorLog,
  AppSettings,GameTrainerGrade,GameVirtualGearing;

function TBLEHudUpdater.RiderDevices:TGameDeviceService;
begin
  if DeviceService=nil then Exit(nil);
  Result:=DeviceService.ForRider(FProfileIndex);
end;

procedure TBLEHudUpdater.UpdateRiderLabels;
var Comparison:String;
begin
  if FLabels.LabelRiderName<>nil then
    FLabels.LabelRiderName.Caption:=LocalRider(FProfileIndex).DisplayName;
  if FLabels.LabelPowerComparison<>nil then begin
    Comparison:='';
    if RiderDevices<>nil then Comparison:=RiderDevices.ComparisonPowerText;
    FLabels.LabelPowerComparison.Caption:=Comparison;
    FLabels.LabelPowerComparison.Exists:=Comparison<>'';
  end;
end;

function TBLEHudUpdater.PowerZone(Watts,Ftp:Single):Integer;
begin
  if Ftp<0 then Ftp:=FFtp;
  if Ftp<=0 then Exit(-1);
  Result:=ZoneAt(Watts*100/Ftp,FPowerBounds);
end;
function TBLEHudUpdater.PowerZoneCount:Integer;
begin Result:=Length(FPowerBounds) end;

constructor TBLEHudUpdater.Create(AProfileIndex:Integer);
begin
  inherited Create;
  if (AProfileIndex<0)or(AProfileIndex>=MaxLocalRiders)then
    raise ERangeError.Create('Local rider index');
  FProfileIndex:=AProfileIndex;
  FPowerMetrics:=TPowerAccumulator.Create;
  FNumberFormat:=DefaultFormatSettings;
  // The platform's one-byte NBSP is not valid UTF-8 for CGE labels.
  FNumberFormat.ThousandSeparator:=' ';
  FNumberFormat.DecimalSeparator:='.';
  Reset;
end;

destructor TBLEHudUpdater.Destroy;
begin
  if FPowerMetrics<>nil then DailyTrainingForRider(FProfileIndex).EndRide;
  FPowerMetrics.Free;
  inherited;
end;

procedure TBLEHudUpdater.UpdatePowerMetrics(const SecondsPassed: Single;
  const Accounting: TActivityAccounting; const WallSeconds:Single);
var RecordingError:String;
begin
  if FLabels.LabelRecordingStatus<>nil then begin
    RecordingError:=SensorLogForRider(FProfileIndex).ErrorText;
    FLabels.LabelRecordingStatus.Exists:=RecordingError<>'';
    if RecordingError<>''then FLabels.LabelRecordingStatus.Caption:=UiText('Recording needs attention: ')+RecordingError;
  end;
  FPowerAvailable:=Accounting.Running and Accounting.Power.Valid;
  FPowerMetrics.Step(Accounting.Power.Watts,SecondsPassed,Accounting.Running,Accounting.Power.Valid);
  FFtp:=EffectiveRiderProfile(FProfileIndex).FtpW;
  DailyTrainingForRider(FProfileIndex).Step(Accounting.Power.Watts,SecondsPassed,WallSeconds,FFtp,
    Accounting.Running,Accounting.Power.Valid,Now);
end;

procedure TBLEHudUpdater.Reset;
begin
  ManualPower:=-1;ManualCadence:=0;
  FPowerMetrics.Reset; FPowerAvailable:=False;
  if FLabels.LabelWork<>nil then begin
    DailyTrainingForRider(FProfileIndex).EndRide;DailyTrainingForRider(FProfileIndex).BeginRide;
    FLabels.LabelWork.Caption:=FormatFloat('#,##0.0',DailyTrainingForRider(FProfileIndex).WorkJoules/1000.0,FNumberFormat);
  end;
  if FLabels.WheelPower<>nil then FLabels.WheelPower.Selected:=-1;
  if FLabels.WheelHeart<>nil then FLabels.WheelHeart.Selected:=-1;
  if FLabels.WheelCadence<>nil then FLabels.WheelCadence.Selected:=-1;
  FBLESlopeUpdateTime := 0;
  FLastSentBLESlope := 9999;
  FSimulationActive := False;
  FLastControlDevice:=nil;FLastGear:=0;FLastGearing:=False;
  FTrainerGrade := 0;
  FTrainerTargetGrade := 0;
  FTrainerSensitivity:=100;
  FTrainerAdjustmentPending:=False;
  FTrainerGradeInited := False;
  UserWeight := 75.0;
  BikeWeight := 10.0;
end;

procedure TBLEHudUpdater.SetLabels(const ALabels: THudLabels);
begin
  FLabels := ALabels;
  UpdateRiderLabels;
  DailyTrainingForRider(FProfileIndex).BeginRide;
  ConfigureWheels;
end;

procedure TBLEHudUpdater.ConfigureWheels;
var P: TVeloSiteProfile; Colors: array of TCastleColor; I,N: Integer;
  procedure Setup(Wheel: TCastleZoneWheel; Count: Integer);
  var K: Integer;
  begin
    if Wheel=nil then Exit;
    SetLength(Colors,Count);
    for K:=0 to Count-1 do Colors[K]:=TrainingZoneColor(K,Count);
    Wheel.Configure(Colors,True);
  end;
begin
  // Read the existing profile cache once per ride. No network calls in HUD.
  P:=EffectiveRiderProfile(FProfileIndex); FFtp:=P.FtpW;
  if P.WeightKg>0 then UserWeight:=P.WeightKg;
  FPowerBounds:=ReadZoneBounds(P.TrainingZonesJSON,'power');
  FHeartBounds:=ReadZoneBounds(P.TrainingZonesJSON,'heart_rate');
  if Length(FPowerBounds)=0 then
  begin
    SetLength(FPowerBounds,7);
    FPowerBounds[0]:=55; FPowerBounds[1]:=75; FPowerBounds[2]:=90;
    FPowerBounds[3]:=105; FPowerBounds[4]:=120; FPowerBounds[5]:=150; FPowerBounds[6]:=0;
  end;
  Setup(FLabels.WheelPower,Length(FPowerBounds));
  if FLabels.WheelPower<>nil then FLabels.WheelPower.ShowNoSignalSector:=True;
  N:=Length(FHeartBounds); if N=0 then N:=5;
  Setup(FLabels.WheelHeart,N);
  SetLength(FCadenceBounds,5);
  FCadenceBounds[0]:=60; FCadenceBounds[1]:=80; FCadenceBounds[2]:=100;
  FCadenceBounds[3]:=120; FCadenceBounds[4]:=0;
  if FLabels.WheelCadence<>nil then
  begin
    SetLength(Colors,5);
    for I:=0 to 4 do Colors[I]:=TrainingZoneColor(I,5);
    Colors[1]:=Vector4(0.18,0.48,0.92,1);
    Colors[2]:=Vector4(0.22,0.78,0.40,1);
    Colors[3]:=Vector4(0.98,0.43,0.15,1);
    FLabels.WheelCadence.Configure(Colors,False);
    FLabels.WheelCadence.ShowNoSignalSector:=True;
    BindUiText(FLabels.WheelCadence, 'Cadence: <60 / 60-79 / 80-99 / 100-119 / 120+ rpm', 'Tooltip');
  end;
  if FLabels.WheelPower<>nil then
    if FFtp>0 then BindUiText(FLabels.WheelPower, 'Power zone: 3-second average (% FTP)', 'Tooltip')
    else BindUiText(FLabels.WheelPower, 'Set FTP in your profile to display power zones', 'Tooltip');
  if FLabels.WheelHeart<>nil then
    if Length(FHeartBounds)>0 then BindUiText(FLabels.WheelHeart, 'Heart rate zone (profile)', 'Tooltip')
    else BindUiText(FLabels.WheelHeart, 'Set heart rate zones in your profile', 'Tooltip');
end;

{ ── Хелперы чтения сенсоров ── }

function TBLEHudUpdater.ReadMeasuredPower: TMeasuredPower;
begin
  { A parked FIT is not work performed while riding with keyboard power. }
  if ManualPower>=0 then Result:=Default(TMeasuredPower)
  else Result:=ReadSensorPower;
end;

function TBLEHudUpdater.ReadSensorPower: TMeasuredPower;
begin
  if (RiderDevices<>nil) and Assigned(RiderDevices.Power) and
     RiderDevices.Power.HasData then
    Result:=MeasuredPower(True,RiderDevices.Power.DataAgeSec,RiderDevices.Power.Instant)
  else Result:=Default(TMeasuredPower);
end;

function TBLEHudUpdater.GetPower: Double;
begin
  Result:=ReadMeasuredPower.Watts;
end;

function TBLEHudUpdater.GetCadence: Double;
begin
  if (RiderDevices<>nil) and Assigned(RiderDevices.Cadence) and
     RiderDevices.Cadence.HasData and (RiderDevices.Cadence.DataAgeSec<=3) then
    Result := RiderDevices.Cadence.Instant
  else
    Result := 0;
end;

function TBLEHudUpdater.GetSpeedKmh: Double;
begin
  if (RiderDevices<>nil) and Assigned(RiderDevices.Speed) and
     RiderDevices.Speed.HasData and (RiderDevices.Speed.DataAgeSec<=3) then
    Result := RiderDevices.Speed.Instant
  else
    Result := 0;
end;

function TBLEHudUpdater.GetHeartRate: Double;
begin
  if (RiderDevices<>nil) and Assigned(RiderDevices.HR) and
     RiderDevices.HR.HasData and (RiderDevices.HR.DataAgeSec<=3) then
    Result := RiderDevices.HR.Instant
  else
    Result := 0;
end;

function TBLEHudUpdater.HasAnyData: Boolean;
begin
  { A steering input alone is not exercise telemetry. }
  Result := (RiderDevices<>nil) and
    (RiderDevices.HasSensor(skHeartRate) or RiderDevices.HasSensor(skPower) or
     RiderDevices.HasSensor(skCadence) or RiderDevices.HasSensor(skSpeed));
end;

function TBLEHudUpdater.LastSentBLESlope: Single;
begin
  Result := FLastSentBLESlope;
end;

{ ── Обратная совместимость ── }

function TBLEHudUpdater.BLEDataValid: Boolean;
begin
  Result := HasAnyData;
end;

function TBLEHudUpdater.BLEData: TTrainerDataRecord;
var
  Raw: TTrainerDataRecord;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.InstantPower := Round(GetPower);
  Result.InstantCadence := Round(GetCadence);
  Result.InstantSpeed := GetSpeedKmh;
  Result.HeartRate := Round(GetHeartRate);
  if (RiderDevices<>nil) then
  begin
    if Assigned(RiderDevices.Power) and RiderDevices.Power.HasData then
      Result.AveragePower := Round(RiderDevices.Power.DeviceAverage);
    if Assigned(RiderDevices.Cadence) and RiderDevices.Cadence.HasData then
      Result.AverageCadence := Round(RiderDevices.Cadence.DeviceAverage);
    if Assigned(RiderDevices.Speed) and RiderDevices.Speed.HasData then
      Result.AverageSpeed := RiderDevices.Speed.DeviceAverage;
    { Distance / ElapsedTime / Incline живут в сыром пакете устройства,
      не в слотах. И sim, и живой FTMS кладут их в LastData. }
    Raw := RiderDevices.LastTrainerData;
    Result.Distance := Raw.Distance;
    Result.ElapsedTime := Raw.ElapsedTime;
    Result.Incline := Raw.Incline;
    Result.TotalEnergy := Raw.TotalEnergy;
    Result.ResistanceLevel := Raw.ResistanceLevel;
  end;
  Result.IsMoving := (Result.InstantCadence > 0) or (Result.InstantPower > 0)
    or (Result.InstantSpeed > 0.1);
  Result.Timestamp := Now;
end;

{ ── BLE telemetry ── }

procedure TBLEHudUpdater.UpdateBLETelemetry(AActiveAgent: TPhysicalAgent);
begin
  if not Assigned(AActiveAgent) then Exit;
  if not Assigned(AActiveAgent.State) then Exit;

  { Cadence is an optional, independently assigned sensor. Its disappearance
    does not invalidate a fresh power-meter measurement. }
  AActiveAgent.State.AppliedPowerWatts:=ReadMeasuredPower.Watts;
end;

procedure TBLEHudUpdater.SuspendTrainerControl;
begin FSimulationActive:=False end;

procedure TBLEHudUpdater.StepTrainerInertia(
  const ATargetGrade, ASpeedMps, ADt: Single);
begin
  if not FTrainerGradeInited then begin
    FTrainerGrade:=ATargetGrade;FTrainerGradeInited:=True;
  end else
    FTrainerGrade:=SmoothTrainerGrade(FTrainerGrade,ATargetGrade,ASpeedMps,ADt);
end;

procedure TBLEHudUpdater.UpdateBLETrainerControl(AActiveAgent: TPhysicalAgent;
  const SecondsPassed: Single);
const
  MinSlopeSendInterval = 0.25;
  MinSlopeDeltaToSend = 0.3;         { в grade%, не в градусах }
var
  AngleDeg: Single;
  TargetGrade: Single;
  HasDevice: Boolean;
  Sensitivity:Integer;
begin
  if not Assigned(AActiveAgent) then Exit;
  if not Assigned(AActiveAgent.State) then Exit;

  AngleDeg := AActiveAgent.State.CurrentSlopeAngle;
  { Apply comfort only to outgoing load. Physics and the HUD retain the
    real grade and the sensor's unmodified measured watts. }
  Sensitivity:=Settings.GetTrainerGradeSensitivity;
  if Sensitivity<>FTrainerSensitivity then begin
    FTrainerSensitivity:=Sensitivity;FTrainerAdjustmentPending:=True;
  end;
  TargetGrade:=GradeForTrainer(SlopeDegToGradePct(AngleDeg),Sensitivity);
  FTrainerTargetGrade:=TargetGrade;
  StepTrainerInertia(TargetGrade, AActiveAgent.State.CurrentSpeed, SecondsPassed);

  HasDevice := (RiderDevices<>nil) and RiderDevices.HasControlDevice;
  if not HasDevice then begin FSimulationActive:=False;FLastControlDevice:=nil;Exit end;
  if FLastControlDevice<>Pointer(RiderDevices.ControlDevice)then begin
    FLastControlDevice:=Pointer(RiderDevices.ControlDevice);FSimulationActive:=False;
  end;

  { При первом вызове — переводим тренажёр в режим симуляции (grade=0).
    Без этого тренажёр может оставаться в ERG/Power режиме.
    Флаг ставим ВСЕГДА: иначе сбой записи (timeout $FFFFFFFF + Format
    range-check) повторяется каждый кадр. }
  if not FSimulationActive then
  begin
    FSimulationActive := True;
    FLastSentBLESlope := 0;
    FBLESlopeUpdateTime := 0;
    FTrainerGrade := 0;
    FTrainerGradeInited := True;
    try
      RiderDevices.RequestControl;
      RiderDevices.SetRideSimulation(0, 0, UserWeight, BikeWeight);
    except
      on E: Exception do
        Logger.Warning('[BLEHud] first SetSimulation: ' + E.ClassName + ': ' + E.Message);
    end;
    Exit;
  end;

  FBLESlopeUpdateTime := FBLESlopeUpdateTime + SecondsPassed;
  if FBLESlopeUpdateTime < MinSlopeSendInterval then Exit;
  if (Abs(FTrainerGrade-FLastSentBLESlope)<MinSlopeDeltaToSend) and
     (FLastGear=RiderDevices.VirtualGear) and
     (FLastGearing=Settings.GetVirtualGearingEnabled) and
     (RiderDevices.GearingBackend<>gbFTMSPower) and
     not ((FTrainerAdjustmentPending or (TargetGrade=0))and
       (FTrainerGrade=TargetGrade)and(Abs(TargetGrade-FLastSentBLESlope)>0.001)) then Exit;

  { В тренажёр — уже инерционный уклон, не сырой из физики. }
  try
    RiderDevices.SetRideSimulation(FTrainerGrade, 0, UserWeight, BikeWeight);
    FLastGear:=RiderDevices.VirtualGear;FLastGearing:=Settings.GetVirtualGearingEnabled;
    FLastSentBLESlope := FTrainerGrade;
    if FTrainerGrade=TargetGrade then FTrainerAdjustmentPending:=False;
  except
    on E: Exception do
      Logger.Warning('[BLEHud] SetSimulation: ' + E.ClassName + ': ' + E.Message);
  end;
  FBLESlopeUpdateTime := 0;
end;

{ ── HUD labels ── }

procedure TBLEHudUpdater.UpdateInfoLabels(AActiveAgent: TPhysicalAgent;
  ALoopbackSession: TGameLoopbackSession);
var
  NL: String;
  S: TPhysicsState;
  DeltaPos, CorrGrade: Single;
  Pwr, Cad, Spd, HRVal: Double;
  DataValid: Boolean;
begin
  UpdateRiderLabels;
  if not Assigned(AActiveAgent) then Exit;
  if not Assigned(AActiveAgent.State) then Exit;

  S := AActiveAgent.State;
  if FLabels.LabelTransmission<>nil then begin
    if(RiderDevices<>nil)and RiderDevices.HasControlDevice and RiderDevices.TrainerErgActive then
      FLabels.LabelTransmission.Caption:='ERG'
    else if(RiderDevices<>nil)and(RiderDevices.GearingBackend in[gbNative,gbFTMSPower])then
      FLabels.LabelTransmission.Caption:=IntToStr(RiderDevices.VirtualGear)
    else FLabels.LabelTransmission.Caption:='--';
  end;
  NL := LineEnding;
  DeltaPos := 0;

  if Assigned(ALoopbackSession) and
     Assigned(ALoopbackSession.ClientAvatar) and
     Assigned(ALoopbackSession.ClientAvatar.State) and
     Assigned(ALoopbackSession.ServerAvatar) and
     Assigned(ALoopbackSession.ServerAvatar.State) then
    DeltaPos := (ALoopbackSession.ClientAvatar.State.WorldPosition -
                 ALoopbackSession.ServerAvatar.State.WorldPosition).Length;

  { Считываем данные сенсоров один раз }
  Pwr := GetPower;
  Cad := GetCadence;
  if ManualPower>=0 then begin Pwr:=ManualPower;Cad:=ManualCadence end;
  Spd := GetSpeedKmh;
  HRVal := GetHeartRate;
  DataValid := HasAnyData;

  // Match the displayed power, including the existing stopped-cadence rule.
  if FLabels.WheelPower<>nil then
    if (ManualPower>=0) and(FFtp>0) then
      FLabels.WheelPower.TargetPosition:=ZonePosition(ManualPower*100/FFtp,FPowerBounds)
    else if (FFtp>0) and FPowerAvailable and (FPowerMetrics.AveragePower>=0.5) then
      FLabels.WheelPower.TargetPosition:=ZonePosition(FPowerMetrics.AveragePower*100.0/FFtp,FPowerBounds)
    else FLabels.WheelPower.Selected:=-1;
  if FLabels.WheelHeart<>nil then
    if (HRVal>0) and (RiderDevices<>nil) and Assigned(RiderDevices.HR) and
       RiderDevices.HR.HasData and (RiderDevices.HR.DataAgeSec<=3) then
      FLabels.WheelHeart.TargetPosition:=ZonePosition(HRVal,FHeartBounds)
    else FLabels.WheelHeart.Selected:=-1;
  if FLabels.WheelCadence<>nil then
    if (ManualPower>=0)and(Cad>0)then
      FLabels.WheelCadence.TargetPosition:=ZonePosition(Cad,FCadenceBounds)
    else if (Cad>0) and (RiderDevices<>nil) and Assigned(RiderDevices.Cadence) and
       RiderDevices.Cadence.HasData and (RiderDevices.Cadence.DataAgeSec<=3) then
      FLabels.WheelCadence.TargetPosition:=ZonePosition(Cad,FCadenceBounds)
    else FLabels.WheelCadence.Selected:=-1;

  if Assigned(FLabels.LabelSlope) then
    FLabels.LabelSlope.Caption :=
      FloatToStrF(SlopeDegToGradePct(S.CurrentSlopeAngle), ffFixed, 7, 1, FNumberFormat) + '%';

  if Assigned(FLabels.LabelPitch) and FLabels.LabelPitch.ExistsInRoot then
    FLabels.LabelPitch.Caption :=
      'Pitch: ' + FloatToStrF(S.CurrentModelPitch, ffFixed, 7, 1) + '°, ' +
      'Roll: ' + FloatToStrF(S.CurrentTurnAngle, ffFixed, 7, 1) + '°, ' +
      'a_lat: ' + FloatToStrF(S.CurrentLateralAccel, ffFixed, 7, 2) + ' m/s², ' +
      'dAng: ' + FloatToStrF(RadToDeg(S.CurrentTurnAngleDeltaRad), ffFixed, 7, 2) + '°';

  if Assigned(FLabels.LabelSpeed) then
    FLabels.LabelSpeed.Caption := FloatToStrF(S.CurrentSpeed * 3.6, ffFixed, 7, 1, FNumberFormat);

  if Assigned(FLabels.LabelPower) then
    if ManualPower>=0 then FLabels.LabelPower.Caption:=IntToStr(Round(ManualPower))
    else if (RiderDevices<>nil) and Assigned(RiderDevices.Power) and RiderDevices.Power.HasData and
       (RiderDevices.Power.DataAgeSec<3) then FLabels.LabelPower.Caption:=IntToStr(Round(Pwr))
    else FLabels.LabelPower.Caption:='--';
  if Assigned(FLabels.LabelWork) then
    FLabels.LabelWork.Caption:=FormatFloat('#,##0.0',DailyTrainingForRider(FProfileIndex).WorkJoules/1000.0,FNumberFormat);
  if Assigned(FLabels.LabelWorkTSS)then
    if (FFtp>0)or(DailyTrainingForRider(FProfileIndex).TSS>0)then
      FLabels.LabelWorkTSS.Caption:=FormatFloat('0.0',DailyTrainingForRider(FProfileIndex).TSS,FNumberFormat)
    else FLabels.LabelWorkTSS.Caption:='--';

  if Assigned(FLabels.LabelCadence) then
  begin
    if Cad > 0 then
      FLabels.LabelCadence.Caption := IntToStr(Round(Cad))
    else
      FLabels.LabelCadence.Caption := '--';
  end;

  { Реально применённая поправка в процентных пунктах уклона.
    Уклон выше уже ВКЛЮЧАЕТ её; это не второй слагаемый для физики.
    tan(угол FIT−угол меша) неверен: вычитаем отдельно оба grade. }
  if Assigned(FLabels.LabelCorr) then
  begin
    if S.CurrentSlopeCorrValid then
    begin
      CorrGrade := SlopeDegToGradePct(S.CurrentSlopeAngle)
        - SlopeDegToGradePct(S.CurrentGroundPitch);
      if Abs(CorrGrade) < 0.05 then CorrGrade := 0;
      if CorrGrade >= 0 then
        FLabels.LabelCorr.Caption := '+' +
          FloatToStrF(CorrGrade, ffFixed, 7, 1, FNumberFormat) + '%'
      else
        FLabels.LabelCorr.Caption := '-' +
          FloatToStrF(Abs(CorrGrade), ffFixed, 7, 1, FNumberFormat) + '%';
    end
    else
      FLabels.LabelCorr.Caption := '--';
  end;

  if Assigned(FLabels.LabelHeart) then
  begin
    if HRVal > 0 then
      FLabels.LabelHeart.Caption := IntToStr(Round(HRVal))
    else
      FLabels.LabelHeart.Caption := '--';
  end;

  if Assigned(FLabels.LabelInfo) and FLabels.LabelInfo.ExistsInRoot then
  begin
    FLabels.LabelInfo.Caption :=
      'Authority: ' + IntToStr(Ord(AActiveAgent.NetworkAuthority)) + NL +
      'Physics mode: ' + IntToStr(Ord(AActiveAgent.PhysicsMode)) + NL +
      'Power: ' + FloatToStrF(S.AppliedPowerWatts, ffFixed, 7, 0) + ' W' + NL +
      'Speed: ' + FloatToStrF(S.CurrentSpeed * 3.6, ffFixed, 7, 1) + ' km/h' + NL +
      'Speed: ' + FloatToStrF(S.CurrentSpeed, ffFixed, 7, 1) + ' m/s' + NL +
      'Applied grade (includes FIT): ' +
        FloatToStrF(SlopeDegToGradePct(S.CurrentSlopeAngle), ffFixed, 7, 1) + '%' + NL +
      'Ground grade: ' +
        FloatToStrF(SlopeDegToGradePct(S.CurrentGroundPitch), ffFixed, 7, 1) + '%' + NL +
      'Model pitch: ' + FloatToStrF(S.CurrentModelPitch, ffFixed, 7, 1) + '°' + NL +
      'Roll: ' + FloatToStrF(S.CurrentTurnAngle, ffFixed, 7, 1) + '°' + NL +
      'Curvature: ' + FloatToStrF(S.CurrentCurvature, ffFixed, 10, 4) + ' 1/m' + NL +
      'Turn radius: ' + FloatToStrF(S.CurrentTurnRadius, ffFixed, 10, 1) + ' m' + NL +
      'Yaw rate: ' + FloatToStrF(S.CurrentYawRateRad, ffFixed, 10, 3) + ' rad/s' + NL +
      'Lateral accel: ' + FloatToStrF(S.CurrentLateralAccel, ffFixed, 10, 2) + ' m/s²' + NL +
      'Turn delta: ' + FloatToStrF(RadToDeg(S.CurrentTurnAngleDeltaRad), ffFixed, 10, 2) + '°' + NL +
      'AutoMove: ' + BoolToStr(S.AutoMove, True) + NL +
      'Sim time: ' + FloatToStrF(S.SimulationTime, ffFixed, 10, 2) + ' s' + NL +
      'Client-Server delta: ' + FloatToStrF(DeltaPos, ffFixed, 10, 3) + ' m';

    if DataValid then
      FLabels.LabelInfo.Caption := FLabels.LabelInfo.Caption + NL +
        'Power: ' + IntToStr(Round(Pwr)) + ' W' + NL +
        'Cadence: ' + IntToStr(Round(Cad)) + ' rpm' + NL +
        'Sensor speed: ' + FloatToStrF(Spd, ffFixed, 7, 1) + ' km/h' + NL +
        'HR: ' + IntToStr(Round(HRVal)) + ' bpm';

    if FLastSentBLESlope < 9990 then
      FLabels.LabelInfo.Caption := FLabels.LabelInfo.Caption + NL +
        'Sim Grade Sent: ' + FloatToStrF(FLastSentBLESlope, ffFixed, 7, 1) + '%';
  end;
end;

end.
