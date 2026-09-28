unit FTMSProtocol;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, TrainerData,
  GameTransportBase;     { TTransportSession base for TFTMSCapableSession }

const
  // GATT Service UUIDs
  UUID_FITNESS_MACHINE_SERVICE = '00001826-0000-1000-8000-00805f9b34fb';
  UUID_CYCLING_POWER_SERVICE = '00001818-0000-1000-8000-00805f9b34fb';
  UUID_CYCLING_SPEED_CADENCE_SERVICE = '00001816-0000-1000-8000-00805f9b34fb';
  UUID_HEART_RATE_SERVICE = '0000180d-0000-1000-8000-00805f9b34fb';
  UUID_DEVICE_INFORMATION_SERVICE = '0000180a-0000-1000-8000-00805f9b34fb';

  // FTMS Characteristic UUIDs
  UUID_FTMS_FEATURE = '00002acc-0000-1000-8000-00805f9b34fb';
  UUID_INDOOR_BIKE_DATA = '00002ad2-0000-1000-8000-00805f9b34fb';
  UUID_TRAINING_STATUS = '00002ad3-0000-1000-8000-00805f9b34fb';
  UUID_SUPPORTED_RESISTANCE_LEVEL = '00002ad6-0000-1000-8000-00805f9b34fb';
  UUID_SUPPORTED_POWER_RANGE = '00002ad8-0000-1000-8000-00805f9b34fb';
  UUID_FITNESS_MACHINE_CONTROL_POINT = '00002ad9-0000-1000-8000-00805f9b34fb';
  UUID_FITNESS_MACHINE_STATUS = '00002ada-0000-1000-8000-00805f9b34fb';

  // Cycling Power Characteristic UUIDs
  UUID_CYCLING_POWER_MEASUREMENT = '00002a63-0000-1000-8000-00805f9b34fb';
  UUID_CYCLING_POWER_FEATURE = '00002a65-0000-1000-8000-00805f9b34fb';

  // Heart Rate Characteristic UUID
  UUID_HEART_RATE_MEASUREMENT = '00002a37-0000-1000-8000-00805f9b34fb';

  // Cycling Speed & Cadence Characteristic UUID
  UUID_CSC_MEASUREMENT = '00002a5b-0000-1000-8000-00805f9b34fb';

  // FTMS Control Point OpCodes
  FTMS_REQUEST_CONTROL = $00;
  FTMS_RESET = $01;
  FTMS_SET_TARGET_SPEED = $02;
  FTMS_SET_TARGET_INCLINE = $03;
  FTMS_SET_TARGET_RESISTANCE = $04;
  FTMS_SET_TARGET_POWER = $05;
  FTMS_SET_TARGET_HEART_RATE = $06;
  FTMS_START_OR_RESUME = $07;
  FTMS_STOP_OR_PAUSE = $08;
  FTMS_SET_INDOOR_BIKE_SIMULATION = $11;
  FTMS_SPIN_DOWN_CONTROL = $13;
  FTMS_SET_CADENCE = $14;

  // FTMS Response Codes
  FTMS_RESPONSE_SUCCESS = $01;
  FTMS_RESPONSE_NOT_SUPPORTED = $02;
  FTMS_RESPONSE_INVALID_PARAMETER = $03;
  FTMS_RESPONSE_OPERATION_FAILED = $04;
  FTMS_RESPONSE_CONTROL_NOT_PERMITTED = $05;

type
  TFTMSParser = class
  private
    FLastData: TTrainerDataRecord;
    { Crank revolution tracking for cadence calculation }
    FPrevCrankRevs: Word;
    FPrevCrankTime: Word;
    FHasPrevCrank: Boolean;
    FLastPacketValid: Boolean;
    FLastCrankChangeTick: QWord;
    FCrankTimeoutMs: QWord;
    function GetUInt8(const Data: TBytes; var Offset: Integer): Byte;
    function GetUInt16(const Data: TBytes; var Offset: Integer): Word;
    function GetInt16(const Data: TBytes; var Offset: Integer): SmallInt;
    function GetNonnegativePower(const Data: TBytes; var Offset: Integer): Word;
    function GetUInt24(const Data: TBytes; var Offset: Integer): Cardinal;
    function CalcCadenceFromCrank(CrankRevs, CrankTime: Word): Word;
    function CurrentCrankCadence: Word;
  public
    constructor Create;
    property LastPacketValid: Boolean read FLastPacketValid;
    
    // Парсинг данных Indoor Bike Data
    function ParseIndoorBikeData(const Data: TBytes): TTrainerDataRecord;
    
    // Парсинг Cycling Power Measurement
    function ParseCyclingPowerMeasurement(const Data: TBytes): TTrainerDataRecord;
    
    // Парсинг Cycling Speed & Cadence Measurement (0x2A5B)
    function ParseCSCMeasurement(const Data: TBytes): TTrainerDataRecord;

    // Парсинг Heart Rate Measurement
    function ParseHeartRateMeasurement(const Data: TBytes): Byte;
    
    // Парсинг FTMS Features
    function ParseFTMSFeatures(const Data: TBytes): TTrainerFeatures;
    
    // Создание команд управления
    class function CreateRequestControlCommand: TBytes;
    class function CreateSetTargetPowerCommand(PowerWatts: Word): TBytes;
    class function CreateSetResistanceLevelCommand(Level: Byte): TBytes;
    class function CreateSetInclineCommand(Incline: SmallInt): TBytes;
    class function CreateSetSimulationCommand(WindSpeed: SmallInt; 
      Grade: SmallInt; CRR: Byte; CW: Byte): TBytes;
    class function CreateStartCommand: TBytes;
    class function CreateStopCommand(Pause: Boolean = False): TBytes;
    class function CreateResetCommand: TBytes;
  end;

{ ── BLE characteristic classification ─────────────────────────────────── }

type
  { Identifies which kind of FTMS-related characteristic a BLE UUID names.
    Used by transport providers (BLEManager, SimpleBLEProvider,
    AndroidBLEProvider, WinRTBLEProvider) to dispatch incoming notifications
    to the right Process*Data routine without hard-coded magic hex strings. }
  TFTMSCharType = (
    fctUnknown,
    fctIndoorBikeData,           { 0x2AD2 }
    fctCyclingPowerMeasurement,  { 0x2A63 }
    fctHeartRateMeasurement,     { 0x2A37 }
    fctCSCMeasurement,           { 0x2A5B }
    fctFitnessMachineCP,         { 0x2AD9 — control-point response }
    fctFECData                   { 6E40FEC2-… — Tacx FE-C BLE characteristic }
  );

{ Identify a BLE characteristic by its UUID string (case-insensitive,
  matches by 16-bit short UUID where applicable, by 6E40FEC prefix for
  Tacx FE-C). Returns fctUnknown if not recognized. }
function ClassifyBLECharacteristic(const UUID: string): TFTMSCharType;

{ ── TFTMSCapableSession ───────────────────────────────────────────────── }

type
  { Abstract base class for transport sessions that speak FTMS over a
    byte-level write channel (BLE GATT, ANT-over-BLE, or any other
    transport that can deliver an opaque TBytes frame to the trainer).

    Subclasses provide:
      * Connect / Disconnect — transport-specific setup
      * WriteFTMSCommand     — actually push the bytes to the device

    This class implements all the FTMS-level commands (RequestControl,
    SetTargetPower, Set{Resistance,Incline,Simulation}, Start, Stop,
    Pause, Reset) on top of WriteFTMSCommand + TFTMSParser.Create*Command,
    and gates them on (FHasControl and FHasFTMS).

    FHasFTMS must be set by the subclass during connection (after
    discovering whether the device exposes the FTMS Control Point
    characteristic 0x2AD9). Measurement-only devices cannot acquire
    control. Control-point indications must call ReceiveControlPoint. }

  TFTMSCapableSession = class abstract(TTransportSession)
  protected
    FHasFTMS: Boolean;

    { Subclasses implement this to actually send Data over the transport.
      Called only after FHasFTMS / FHasControl / FConnectionState gates
      have already been checked by the methods below. }
    function WriteFTMSCommand(const Data: TBytes): Boolean; virtual; abstract;
  public
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

    property HasFTMS: Boolean read FHasFTMS;
  end;

implementation

constructor TFTMSParser.Create;
begin
  inherited Create;
  FillChar(FLastData, SizeOf(FLastData), 0);
  FPrevCrankRevs := 0;
  FPrevCrankTime := 0;
  FHasPrevCrank := False;
  FCrankTimeoutMs := 3000;
end;

{ ── BLE characteristic classification ─────────────────────────────────── }

function ClassifyBLECharacteristic(const UUID: string): TFTMSCharType;
var
  U: string;
begin
  { Lower-case once, then test by 16-bit short UUID (4 hex chars) — present
    inside the canonical 128-bit form: 0000XXXX-0000-1000-8000-00805f9b34fb.
    For the Tacx FE-C custom service we test the leading 6E40FECx prefix. }
  U := LowerCase(UUID);
  if Pos('2ad2', U) > 0 then
    Result := fctIndoorBikeData
  else if Pos('2a63', U) > 0 then
    Result := fctCyclingPowerMeasurement
  else if Pos('2a37', U) > 0 then
    Result := fctHeartRateMeasurement
  else if Pos('2a5b', U) > 0 then
    Result := fctCSCMeasurement
  else if Pos('2ad9', U) > 0 then
    Result := fctFitnessMachineCP
  else if Pos('6e40fec', U) > 0 then
    Result := fctFECData
  else
    Result := fctUnknown;
end;

{ ── TFTMSCapableSession ───────────────────────────────────────────────── }

function TFTMSCapableSession.RequestControl: Boolean;
begin
  Result := False;
  if FConnectionState <> csConnected then Exit;
  if not FHasFTMS then Exit;
  if FHasControl then Exit(True);
  Result := SendConfirmedFTMS(TFTMSParser.CreateRequestControlCommand, @WriteFTMSCommand);
  FHasControl := Result;
end;

function TFTMSCapableSession.SetTargetPower(Watts: Word): Boolean;
begin
  Result := False;
  if not FHasControl then Exit;
  if FHasFTMS then
    Result := SendConfirmedFTMS(TFTMSParser.CreateSetTargetPowerCommand(Watts), @WriteFTMSCommand);
end;

function TFTMSCapableSession.SetResistanceLevel(Level: Byte): Boolean;
begin
  Result := False;
  if not FHasControl then Exit;
  if FHasFTMS then
    Result := SendConfirmedFTMS(TFTMSParser.CreateSetResistanceLevelCommand(Level), @WriteFTMSCommand);
end;

function TFTMSCapableSession.SetIncline(InclinePercent: Single): Boolean;
var Incline10: SmallInt;
begin
  Result := False;
  if not FHasControl then Exit;
  Incline10 := Round(Max(-3276.8, Min(3276.7, InclinePercent)) * 10);
  if FHasFTMS then
    Result := SendConfirmedFTMS(TFTMSParser.CreateSetInclineCommand(Incline10), @WriteFTMSCommand);
end;

function TFTMSCapableSession.SetSimulation(Grade: Single;
  WindSpeed: Single; RiderWeight: Single; BikeWeight: Single): Boolean;
begin
  Result := False;
  if not FHasControl then Exit;
  if FHasFTMS then
    Result := SendConfirmedFTMS(TFTMSParser.CreateSetSimulationCommand(
      Round(Max(-32.768, Min(32.767, WindSpeed)) * 1000),
      Round(Max(-327.68, Min(327.67, Grade)) * 100),
      Round(0.005 * 10000),  { CRR default }
      Round(0.51 * 100)), @WriteFTMSCommand);   { CW default }
end;

function TFTMSCapableSession.Start: Boolean;
begin
  Result := False;
  if not FHasControl then Exit;
  if FHasFTMS then
    Result := SendConfirmedFTMS(TFTMSParser.CreateStartCommand, @WriteFTMSCommand);
end;

function TFTMSCapableSession.Stop: Boolean;
begin
  Result := False;
  if not FHasControl then Exit;
  if FHasFTMS then
    Result := SendConfirmedFTMS(TFTMSParser.CreateStopCommand(False), @WriteFTMSCommand);
end;

function TFTMSCapableSession.Pause: Boolean;
begin
  Result := False;
  if not FHasControl then Exit;
  if FHasFTMS then
    Result := SendConfirmedFTMS(TFTMSParser.CreateStopCommand(True), @WriteFTMSCommand);
end;

function TFTMSCapableSession.Reset: Boolean;
begin
  Result := False;
  if not FHasControl then Exit;
  if FHasFTMS then
  begin
    Result := SendConfirmedFTMS(TFTMSParser.CreateResetCommand, @WriteFTMSCommand);
    if Result then FHasControl := False;
  end;
end;

{ ── Cadence from cumulative crank revolution data ── }

function TFTMSParser.CalcCadenceFromCrank(CrankRevs, CrankTime: Word): Word;
var
  DeltaRevs: Integer;
  DeltaTime: Integer;
  Cadence: Cardinal;
begin
  Result := 0;
  if not FHasPrevCrank then
  begin
    FPrevCrankRevs := CrankRevs;
    FPrevCrankTime := CrankTime;
    FHasPrevCrank := True;
    FLastCrankChangeTick := GetTickCount64;
    Exit;
  end;

  { Handle uint16 rollover }
  DeltaRevs := (CrankRevs - FPrevCrankRevs) and $FFFF;
  DeltaTime := (CrankTime - FPrevCrankTime) and $FFFF;

  FPrevCrankRevs := CrankRevs;
  FPrevCrankTime := CrankTime;

  { DeltaTime is in 1/1024 seconds. Cadence = deltaRevs / deltaTime * 60 * 1024 }
  if (DeltaTime > 0) and (DeltaRevs > 0) and (DeltaRevs < 20) then
  begin
    Cadence := (DeltaRevs * 1024 * 60) div DeltaTime;
    if Cadence > High(Word) then Exit;
    Result := Cadence;
    FLastCrankChangeTick := GetTickCount64;
    { Allow two expected revolution intervals at low cadence, at least 3 s. }
    FCrankTimeoutMs := (QWord(DeltaTime) * 2000) div (QWord(DeltaRevs) * 1024);
    if FCrankTimeoutMs < 3000 then FCrankTimeoutMs := 3000;
  end
  else
    Result := CurrentCrankCadence;
end;

function TFTMSParser.CurrentCrankCadence: Word;
begin
  Result := FLastData.InstantCadence;
  if FHasPrevCrank and (GetTickCount64 - FLastCrankChangeTick >= FCrankTimeoutMs) then
    Result := 0;
end;

function TFTMSParser.GetUInt8(const Data: TBytes; var Offset: Integer): Byte;
begin
  if Offset < Length(Data) then
  begin
    Result := Data[Offset];
    Inc(Offset);
  end
  else
    Result := 0;
end;

function TFTMSParser.GetUInt16(const Data: TBytes; var Offset: Integer): Word;
begin
  if Offset + 1 < Length(Data) then
  begin
    Result := Data[Offset] or (Data[Offset + 1] shl 8);
    Inc(Offset, 2);
  end
  else
    Result := 0;
end;

function TFTMSParser.GetInt16(const Data: TBytes; var Offset: Integer): SmallInt;
begin
  Result := SmallInt(GetUInt16(Data, Offset));
end;

function TFTMSParser.GetNonnegativePower(const Data: TBytes; var Offset: Integer): Word;
var
  Power: SmallInt;
begin
  Power := GetInt16(Data, Offset);
  if Power < 0 then Result := 0 else Result := Power;
end;

function TFTMSParser.GetUInt24(const Data: TBytes; var Offset: Integer): Cardinal;
begin
  if Offset + 2 < Length(Data) then
  begin
    Result := Data[Offset] or (Data[Offset + 1] shl 8) or (Data[Offset + 2] shl 16);
    Inc(Offset, 3);
  end
  else
    Result := 0;
end;

function TFTMSParser.ParseIndoorBikeData(const Data: TBytes): TTrainerDataRecord;
const
  FieldSizes: array[1..12] of Byte = (2,2,2,3,2,2,2,5,1,1,2,2);
var
  Flags: Word;
  Offset, RequiredSize, Bit: Integer;
begin
  Result := FLastData;
  FLastPacketValid := False;
  
  if Length(Data) < 2 then Exit;
  
  Offset := 0;
  Flags := GetUInt16(Data, Offset);
  RequiredSize := 2;
  if (Flags and 1) = 0 then Inc(RequiredSize, 2);
  for Bit := 1 to 12 do
    if (Flags and (1 shl Bit)) <> 0 then Inc(RequiredSize, FieldSizes[Bit]);
  if Length(Data) < RequiredSize then Exit;
  Result.Timestamp := Now;
  
  // Флаг 0: More Data - игнорируем
  
  // Флаг 1: Average Speed present
  if (Flags and $0001) = 0 then // Instantaneous Speed present when bit is 0
  begin
    Result.InstantSpeed := GetUInt16(Data, Offset) / 100.0; // 0.01 km/h resolution
  end;
  
  if (Flags and $0002) <> 0 then // Average Speed
  begin
    Result.AverageSpeed := GetUInt16(Data, Offset) / 100.0;
  end;
  
  // Флаг 2: Instantaneous Cadence
  if (Flags and $0004) <> 0 then
  begin
    Result.InstantCadence := GetUInt16(Data, Offset) div 2; // 0.5 rpm resolution
  end;
  
  // Флаг 3: Average Cadence
  if (Flags and $0008) <> 0 then
  begin
    Result.AverageCadence := GetUInt16(Data, Offset) div 2;
  end;
  
  // Флаг 4: Total Distance
  if (Flags and $0010) <> 0 then
  begin
    Result.Distance := GetUInt24(Data, Offset); // meters
  end;
  
  // Флаг 5: Resistance Level
  if (Flags and $0020) <> 0 then
  begin
    Result.ResistanceLevel := GetInt16(Data, Offset);
  end;
  
  // Флаг 6: Instantaneous Power
  if (Flags and $0040) <> 0 then
  begin
    Result.InstantPower := GetNonnegativePower(Data, Offset);
  end;
  
  // Флаг 7: Average Power
  if (Flags and $0080) <> 0 then
  begin
    Result.AveragePower := GetNonnegativePower(Data, Offset);
  end;
  
  // Флаг 8: Expended Energy
  if (Flags and $0100) <> 0 then
  begin
    Result.TotalEnergy := GetUInt16(Data, Offset); // kcal
    GetUInt16(Data, Offset); // Energy per hour - skip
    GetUInt8(Data, Offset);  // Energy per minute - skip
  end;
  
  // Флаг 9: Heart Rate
  if (Flags and $0200) <> 0 then
  begin
    Result.HeartRate := GetUInt8(Data, Offset);
  end;
  
  // Флаг 10: Metabolic Equivalent - skip
  if (Flags and $0400) <> 0 then
  begin
    GetUInt8(Data, Offset);
  end;
  
  // Флаг 11: Elapsed Time
  if (Flags and $0800) <> 0 then
  begin
    Result.ElapsedTime := GetUInt16(Data, Offset);
  end;
  
  // Флаг 12: Remaining Time - skip
  if (Flags and $1000) <> 0 then
  begin
    GetUInt16(Data, Offset);
  end;
  
  Result.IsMoving := (Result.InstantSpeed > 0.1) or (Result.InstantCadence > 0);
  FLastData := Result;
  FLastPacketValid := True;
end;

function TFTMSParser.ParseCyclingPowerMeasurement(const Data: TBytes): TTrainerDataRecord;
const
  FieldSizes: array[0..11] of Byte = (1,0,2,0,6,4,4,4,3,2,2,2);
var
  Flags: Word;
  Offset, RequiredSize, Bit: Integer;
  CrankRevs, CrankTime, Cad: Word;
begin
  Result := FLastData;
  FLastPacketValid := False;
  
  if Length(Data) < 4 then Exit;
  
  Offset := 0;
  Flags := GetUInt16(Data, Offset);
  RequiredSize := 4;
  for Bit := 0 to 11 do
    if (Flags and (1 shl Bit)) <> 0 then Inc(RequiredSize, FieldSizes[Bit]);
  if Length(Data) < RequiredSize then Exit;
  Result.Timestamp := Now;
  Result.InstantCadence := CurrentCrankCadence;
  
  // Instantaneous Power всегда присутствует
  Result.InstantPower := GetNonnegativePower(Data, Offset);
  
  // Флаг 0: Pedal Power Balance - skip
  if (Flags and $0001) <> 0 then
  begin
    GetUInt8(Data, Offset);
  end;
  
  // Флаг 2: Accumulated Torque - skip
  if (Flags and $0004) <> 0 then
  begin
    GetUInt16(Data, Offset);
  end;
  
  // Флаг 4: Wheel Revolution Data
  if (Flags and $0010) <> 0 then
  begin
    // Cumulative Wheel Revolutions (uint32) и Last Wheel Event Time (uint16)
    Inc(Offset, 6);
  end;
  
  // Флаг 5: Crank Revolution Data
  if (Flags and $0020) <> 0 then
  begin
    if Offset + 3 < Length(Data) then
    begin
      CrankRevs := GetUInt16(Data, Offset);
      CrankTime := GetUInt16(Data, Offset);
      Cad := CalcCadenceFromCrank(CrankRevs, CrankTime);
      Result.InstantCadence := Cad;
    end
    else
      Inc(Offset, 4);
  end;
  
  Result.IsMoving := Result.InstantPower > 0;
  FLastData := Result;
  FLastPacketValid := True;
end;

{ ── Cycling Speed & Cadence Measurement (0x2A5B) ──
  Flags byte:
    bit 0: Wheel Revolution Data Present (uint32 cumRevs + uint16 lastTime)
    bit 1: Crank Revolution Data Present (uint16 cumRevs + uint16 lastTime)
  Used by standalone speed/cadence sensors (Garmin, Wahoo RPM, etc.) }

function TFTMSParser.ParseCSCMeasurement(const Data: TBytes): TTrainerDataRecord;
var
  Flags: Byte;
  Offset, RequiredSize: Integer;
  WheelRevs: Cardinal;
  WheelTime: Word;
  CrankRevs, CrankTime, Cad: Word;
begin
  Result := FLastData;
  FLastPacketValid := False;

  if Length(Data) < 1 then Exit;

  Offset := 0;
  Flags := GetUInt8(Data, Offset);
  RequiredSize := 1;
  if (Flags and 1) <> 0 then Inc(RequiredSize, 6);
  if (Flags and 2) <> 0 then Inc(RequiredSize, 4);
  if Length(Data) < RequiredSize then Exit;
  Result.Timestamp := Now;
  Result.InstantCadence := CurrentCrankCadence;

  { Wheel Revolution Data (bit 0) — speed }
  if (Flags and $01) <> 0 then
  begin
    if Offset + 5 < Length(Data) then
    begin
      WheelRevs := GetUInt16(Data, Offset) or (Cardinal(GetUInt16(Data, Offset)) shl 16);
      WheelTime := GetUInt16(Data, Offset);
      { Speed calculation would need wheel circumference — skip for now,
        trainers provide speed via other means }
    end
    else
      Inc(Offset, 6);
  end;

  { Crank Revolution Data (bit 1) — cadence }
  if (Flags and $02) <> 0 then
  begin
    if Offset + 3 < Length(Data) then
    begin
      CrankRevs := GetUInt16(Data, Offset);
      CrankTime := GetUInt16(Data, Offset);
      Cad := CalcCadenceFromCrank(CrankRevs, CrankTime);
      Result.InstantCadence := Cad;
    end;
  end;

  Result.IsMoving := Result.InstantCadence > 0;
  FLastData := Result;
  FLastPacketValid := True;
end;

function TFTMSParser.ParseHeartRateMeasurement(const Data: TBytes): Byte;
var
  Flags: Byte;
  Offset: Integer;
begin
  Result := 0;
  if Length(Data) < 2 then Exit;
  
  Offset := 0;
  Flags := GetUInt8(Data, Offset);
  
  // Флаг 0: Heart Rate Value Format
  if (Flags and $01) = 0 then
    Result := GetUInt8(Data, Offset)  // UINT8
  else
    Result := Lo(GetUInt16(Data, Offset)); // UINT16, берём младший байт
end;

function TFTMSParser.ParseFTMSFeatures(const Data: TBytes): TTrainerFeatures;
const
  TARGET_RESISTANCE = Cardinal(1) shl 2;
  TARGET_POWER = Cardinal(1) shl 3;
var
  Features: Cardinal;
  TargetFeatures: Cardinal;
begin
  FillChar(Result, SizeOf(Result), 0);
  
  if Length(Data) < 8 then Exit;
  
  // Первые 4 байта - Fitness Machine Features
  Features := Data[0] or (Data[1] shl 8) or (Data[2] shl 16) or (Data[3] shl 24);
  
  // Следующие 4 байта - Target Setting Features
  TargetFeatures := Data[4] or (Data[5] shl 8) or (Data[6] shl 16) or (Data[7] shl 24);
  
  Result.SupportsResistanceControl := (TargetFeatures and TARGET_RESISTANCE) <> 0;
  Result.SupportsPowerControl := (TargetFeatures and TARGET_POWER) <> 0;
  Result.SupportsInclineControl := (TargetFeatures and $0002) <> 0;    // Inclination Target Setting
  Result.SupportsSimulation := (TargetFeatures and $2000) <> 0;        // Indoor Bike Simulation
end;

class function TFTMSParser.CreateRequestControlCommand: TBytes;
begin
  SetLength(Result, 1);
  Result[0] := FTMS_REQUEST_CONTROL;
end;

class function TFTMSParser.CreateSetTargetPowerCommand(PowerWatts: Word): TBytes;
begin
  SetLength(Result, 3);
  Result[0] := FTMS_SET_TARGET_POWER;
  Result[1] := Lo(PowerWatts);
  Result[2] := Hi(PowerWatts);
end;

class function TFTMSParser.CreateSetResistanceLevelCommand(Level: Byte): TBytes;
begin
  { FTMS target resistance is SINT16 in units of 0.1, not UINT8. }
  SetLength(Result, 3);
  Result[0] := FTMS_SET_TARGET_RESISTANCE;
  Result[1] := Lo(Word(Level * 10));
  Result[2] := Hi(Word(Level * 10));
end;

class function TFTMSParser.CreateSetInclineCommand(Incline: SmallInt): TBytes;
begin
  // Incline в 0.1% (например, 50 = 5.0%)
  SetLength(Result, 3);
  Result[0] := FTMS_SET_TARGET_INCLINE;
  Result[1] := Lo(Word(Incline));
  Result[2] := Hi(Word(Incline));
end;

class function TFTMSParser.CreateSetSimulationCommand(WindSpeed: SmallInt;
  Grade: SmallInt; CRR: Byte; CW: Byte): TBytes;
begin
  // WindSpeed: 0.001 m/s resolution
  // Grade: 0.01% resolution
  // CRR: Coefficient of Rolling Resistance, 0.0001 resolution
  // CW: Wind Resistance Coefficient, 0.01 kg/m resolution
  SetLength(Result, 7);
  Result[0] := FTMS_SET_INDOOR_BIKE_SIMULATION;
  Result[1] := Lo(Word(WindSpeed));
  Result[2] := Hi(Word(WindSpeed));
  Result[3] := Lo(Word(Grade));
  Result[4] := Hi(Word(Grade));
  Result[5] := CRR;
  Result[6] := CW;
end;

class function TFTMSParser.CreateStartCommand: TBytes;
begin
  SetLength(Result, 1);
  Result[0] := FTMS_START_OR_RESUME;
end;

class function TFTMSParser.CreateStopCommand(Pause: Boolean): TBytes;
begin
  SetLength(Result, 2);
  Result[0] := FTMS_STOP_OR_PAUSE;
  if Pause then
    Result[1] := $02  // Pause
  else
    Result[1] := $01; // Stop
end;

class function TFTMSParser.CreateResetCommand: TBytes;
begin
  SetLength(Result, 1);
  Result[0] := FTMS_RESET;
end;

end.
