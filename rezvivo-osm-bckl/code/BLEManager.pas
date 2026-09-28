{ BLEManager — реализация BLE-транспорта для подключения к тренажёрам.

  TBLEConnectionSession — конкретная BLE-реализация TTransportSession.
  TBLETransportProvider — конкретная BLE-реализация TTransportProvider.

  Поддерживает:
  - FE-C over BLE (ANT+ поверх BLE)
  - FTMS (Fitness Machine Service)
  - Cycling Power Service
  - Heart Rate Service
}
unit BLEManager;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fgl, TrainerData, FTMSProtocol, BLEDevice, WinBluetoothLE,
  Math, DebugLog, syncobjs,
  GameTransportBase;

const
  // FE-C over BLE UUIDs
  UUID_FEC_SERVICE = '6e40fec1-b5a3-f393-e0a9-e50e24dcca9e';
  UUID_FEC_READ    = '6e40fec2-b5a3-f393-e0a9-e50e24dcca9e';
  UUID_FEC_WRITE   = '6e40fec3-b5a3-f393-e0a9-e50e24dcca9e';

  // Standard BLE UUIDs
  UUID_CYCLING_POWER_SERVICE     = '00001818-0000-1000-8000-00805f9b34fb';
  UUID_CYCLING_POWER_MEASUREMENT = '00002a63-0000-1000-8000-00805f9b34fb';

  UUID_FTMS_SERVICE       = '00001826-0000-1000-8000-00805f9b34fb';
  UUID_INDOOR_BIKE_DATA   = '00002ad2-0000-1000-8000-00805f9b34fb';
  UUID_FTMS_CONTROL_POINT = '00002ad9-0000-1000-8000-00805f9b34fb';

  UUID_HEART_RATE_SERVICE     = '0000180d-0000-1000-8000-00805f9b34fb';
  UUID_HEART_RATE_MEASUREMENT = '00002a37-0000-1000-8000-00805f9b34fb';

type
  { TBLEConnectionSession — BLE-реализация TTransportSession }

  TBLEConnectionSession = class(TFTMSCapableSession)
  private
    FBLEDevice: TBLEDevice;
    FFTMSParser: TFTMSParser;

    FUseFEC: Boolean;
    FFECChannel: Byte;
    FHasFECChannel: Boolean;

    procedure OnBLENotification(const CharUUID: string; const Data: TBytes);

    function TryExtractANTPayload(const Data: TBytes; out Payload: TBytes;
      out MsgId, Channel: Byte): Boolean;

    procedure ProcessFECData(const Data: TBytes);
    procedure ProcessCyclingPowerData(const Data: TBytes);
    procedure ProcessFTMSData(const Data: TBytes);
    procedure ProcessHRMData(const Data: TBytes);
    procedure ProcessCSCData(const Data: TBytes);

    function BuildANTPacket(MsgId, Channel: Byte;
      const Payload8: array of Byte): TBytes;
    function SendFECPage(const Page8: array of Byte; Acked: Boolean = True): Boolean;

  protected
    function WriteFTMSCommand(const Data: TBytes): Boolean; override;
  public
    constructor Create(const AAddress: string;
      const AFriendlyName: string = ''); override;
    destructor Destroy; override;

    { --- TTransportSession overrides --- }
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

  { TBLETransportProvider — BLE-реализация TTransportProvider }

  TBLETransportProvider = class(TTransportProvider)
  public
    procedure StartScan; override;
    procedure StopScan; override;
    function CreateSession(const AAddress: string;
      const AFriendlyName: string = ''): TTransportSession; override;
    class function TransportType: TTransportType; override;
  end;

implementation


uses GameLocalization;
{ ============================================================================ }
{ TBLEConnectionSession                                                        }
{ ============================================================================ }

constructor TBLEConnectionSession.Create(const AAddress: string;
  const AFriendlyName: string);
begin
  inherited Create(AAddress, AFriendlyName);

  FBLEDevice := TBLEDevice.Create;
  FFTMSParser := TFTMSParser.Create;
  FBLEDevice.OnNotification := @OnBLENotification;

  FUseFEC := False;
  FFECChannel := 0;
  FHasFECChannel := False;
end;

destructor TBLEConnectionSession.Destroy;
begin
  ShutdownControl;
  FDestroying := True;

  if Assigned(FBLEDevice) then
    FBLEDevice.OnNotification := nil;

  Disconnect;

  FreeAndNil(FBLEDevice);
  FreeAndNil(FFTMSParser);

  inherited;
end;

class function TBLEConnectionSession.TransportType: TTransportType;
begin
  Result := ttBLE;
end;

{ --- Notifications --- }

procedure TBLEConnectionSession.OnBLENotification(const CharUUID: string;
  const Data: TBytes);
var
  HexStr: string;
  I: Integer;
  UUIDLower: string;
  ShiftedData: TBytes;
begin
  if FDestroying then Exit;

  UUIDLower := LowerCase(CharUUID);

  HexStr := '';
  for I := 0 to Min(Length(Data) - 1, 31) do
    HexStr := HexStr + IntToHex(Data[I], 2) + ' ';
  Logger.Debug(Format('[%s] Notification %s: %s',
    [FDeviceInfo.Address, Copy(UUIDLower, 1, 8), HexStr]));

  if Pos('6e40fec', UUIDLower) > 0 then
  begin
    { Некоторые FE-C уведомления приходят с BLE-префиксом 00 00,
      а сам ANT frame начинается с A4. Тогда отбрасываем первые 2 байта. }
    if (Length(Data) >= 3) and
       (Data[0] = 0) and
       (Data[1] = 0) and
       (Data[2] = $A4) then
    begin
      SetLength(ShiftedData, Length(Data) - 2);
      Move(Data[2], ShiftedData[0], Length(Data) - 2);
      ProcessFECData(ShiftedData);
    end
    else
      ProcessFECData(Data);
  end
  else if Pos('2a63', UUIDLower) > 0 then
    ProcessCyclingPowerData(Data)
  else if Pos('2ad2', UUIDLower) > 0 then
    ProcessFTMSData(Data)
  else if Pos('2ad9', UUIDLower) > 0 then
    ReceiveControlPoint(Data)
  else if Pos('2a5b', UUIDLower) > 0 then
    ProcessCSCData(Data)
  else if Pos('2a37', UUIDLower) > 0 then
    ProcessHRMData(Data);
end;

{ --- ANT payload extraction --- }

function TBLEConnectionSession.TryExtractANTPayload(const Data: TBytes;
  out Payload: TBytes; out MsgId, Channel: Byte): Boolean;
var
  AntLen: Integer;
  TotalLen: Integer;
  I: Integer;
  Checksum: Byte;
  AvailablePayload: Integer;
begin
  Result := False;
  SetLength(Payload, 0);
  MsgId := 0;
  Channel := 0;

  if Length(Data) = 0 then Exit;

  { Если это не ANT frame, просто возвращаем как есть }
  if Data[0] <> $A4 then
  begin
    SetLength(Payload, Length(Data));
    if Length(Data) > 0 then
      Move(Data[0], Payload[0], Length(Data));
    Result := True;
    Exit;
  end;

  { Минимум: Sync + Len + MsgId + Channel }
  if Length(Data) < 4 then
  begin
    Logger.Warning(Format('[%s] ANT packet too short: got=%d',
      [FDeviceInfo.Address, Length(Data)]));
    Exit;
  end;

  AntLen := Data[1];
  TotalLen := AntLen + 4;

  MsgId := Data[2];
  Channel := Data[3];

  { Вариант 1: полный ANT frame с checksum }
  if Length(Data) >= TotalLen then
  begin
    Checksum := 0;
    for I := 0 to TotalLen - 2 do
      Checksum := Checksum xor Data[I];

    if Checksum = Data[TotalLen - 1] then
    begin
      AvailablePayload := AntLen - 1; { без channel }
      if AvailablePayload < 0 then
        AvailablePayload := 0;
      if AvailablePayload > 8 then
        AvailablePayload := 8;

      SetLength(Payload, 8);
      FillChar(Payload[0], 8, 0);

      if AvailablePayload > 0 then
        Move(Data[4], Payload[0], AvailablePayload);

      Result := True;
      Exit;
    end
    else
      Logger.Warning(Format('[%s] ANT checksum error: calc=%2.2X recv=%2.2X, trying BLE short frame',
        [FDeviceInfo.Address, Checksum, Data[TotalLen - 1]]));
  end;

  { Вариант 2: короткий BLE frame без checksum. }
  AvailablePayload := Length(Data) - 4;
  if AvailablePayload <= 0 then
  begin
    Logger.Warning(Format('[%s] BLE short ANT packet has no payload: len=%d',
      [FDeviceInfo.Address, Length(Data)]));
    Exit;
  end;

  if AvailablePayload > 8 then
    AvailablePayload := 8;

  SetLength(Payload, 8);
  FillChar(Payload[0], 8, 0);
  Move(Data[4], Payload[0], AvailablePayload);

  Logger.Debug(Format('[%s] Using BLE short ANT frame: len=%d, payload_bytes=%d, msg=$%.2X ch=%d',
    [FDeviceInfo.Address, Length(Data), AvailablePayload, MsgId, Channel]));

  Result := True;
end;

{ --- Protocol processing --- }

procedure TBLEConnectionSession.ProcessFECData(const Data: TBytes);
var
  PageData: TBytes;
  Page: Byte;
  MsgId: Byte;
  Channel: Byte;
  InstPower: Word;
  Cadence: Byte;
  Speed: Word;
begin
  if FDestroying then Exit;

  if not TryExtractANTPayload(Data, PageData, MsgId, Channel) then
    Exit;

  FFECChannel := Channel;
  FHasFECChannel := True;

  if Length(PageData) < 8 then
    Exit;

  Page := PageData[0];

  Logger.Debug(Format('[%s] ANT Msg=$%.2X Ch=%d FE-C Page %d',
    [FDeviceInfo.Address, MsgId, Channel, Page]));

  case Page of
    16:
      begin
        Speed := PageData[4] or (PageData[5] shl 8);
        FLastData.InstantSpeed := Speed * 0.001 * 3.6;

        if PageData[6] <> $FF then
          FLastData.HeartRate := PageData[6];

        Logger.Debug(Format('[%s] FE-C Page 16: Speed=%.1f km/h, HR=%d',
          [FDeviceInfo.Address, FLastData.InstantSpeed, FLastData.HeartRate]));

        NotifyDataReceived;
      end;

    25:
      begin
        Cadence := PageData[2];
        InstPower := PageData[5] or ((PageData[6] and $0F) shl 8);

        FLastData.InstantCadence := Cadence;
        FLastData.InstantPower := InstPower;
        FLastData.IsMoving := (Cadence > 0) or (InstPower > 0);
        FLastData.Timestamp := Now;

        if FLastData.AveragePower = 0 then
          FLastData.AveragePower := InstPower
        else
          FLastData.AveragePower := (FLastData.AveragePower * 3 + InstPower) div 4;

        Logger.Debug(Format('[%s] FE-C Page 25: Power=%d W, Cadence=%d rpm',
          [FDeviceInfo.Address, InstPower, Cadence]));

        NotifyDataReceived;
      end;

    54:
      begin
        Logger.Debug(Format('[%s] FE-C Page 54: Capabilities',
          [FDeviceInfo.Address]));
        FTrainerFeatures.SupportsPowerControl := True;
        FTrainerFeatures.SupportsResistanceControl := True;
        FTrainerFeatures.SupportsSimulation := True;
      end;

  else
    Logger.Debug(Format('[%s] FE-C unhandled page %d',
      [FDeviceInfo.Address, Page]));
  end;
end;

procedure TBLEConnectionSession.ProcessCyclingPowerData(const Data: TBytes);
var
  ParsedData: TTrainerDataRecord;
  CPData: TBytes;
begin
  if FDestroying then Exit;
  if Length(Data) < 4 then Exit;

  { Strip 00 00 BLE prefix if present }
  if (Length(Data) >= 6) and (Data[0] = 0) and (Data[1] = 0) then
  begin
    SetLength(CPData, Length(Data) - 2);
    Move(Data[2], CPData[0], Length(Data) - 2);
  end
  else
    CPData := Data;

  if Length(CPData) < 4 then Exit;
  if FFTMSParser = nil then Exit;
  try
    ParsedData := FFTMSParser.ParseCyclingPowerMeasurement(CPData);
    if not FFTMSParser.LastPacketValid then Exit;
    FLastData := ParsedData;
  except
    on E: Exception do
    begin
      Logger.Warning(Format('[%s] CP parse: %s',
        [FDeviceInfo.Address, E.Message]));
      Exit;
    end;
  end;

  Logger.Debug(Format('[%s] Cycling Power: %d W, Cadence=%d rpm',
    [FDeviceInfo.Address, FLastData.InstantPower, FLastData.InstantCadence]));

  NotifyDataReceived;
end;

procedure TBLEConnectionSession.ProcessFTMSData(const Data: TBytes);
var
  ParsedData: TTrainerDataRecord;
  FTData: TBytes;
begin
  if FDestroying then Exit;

  { Strip 00 00 BLE prefix if present }
  if (Length(Data) >= 4) and (Data[0] = 0) and (Data[1] = 0) then
  begin
    SetLength(FTData, Length(Data) - 2);
    Move(Data[2], FTData[0], Length(Data) - 2);
  end
  else
    FTData := Data;

  if FFTMSParser = nil then Exit;
  try
    ParsedData := FFTMSParser.ParseIndoorBikeData(FTData);
    if not FFTMSParser.LastPacketValid then Exit;
    FLastData := ParsedData;
  except
    on E: Exception do
    begin
      Logger.Warning(Format('[%s] FTMS parse: %s',
        [FDeviceInfo.Address, E.Message]));
      Exit;
    end;
  end;

  Logger.Debug(Format('[%s] FTMS: Power=%d W, Cadence=%d rpm, Speed=%.1f km/h',
    [FDeviceInfo.Address, FLastData.InstantPower, FLastData.InstantCadence,
     FLastData.InstantSpeed]));

  NotifyDataReceived;
end;

{ ── Heart Rate Measurement (0x2A37) ──
  Spec: Flags(1) + HR(1 or 2) + [EnergyExpended(2)] + [RR-Interval(2)...]
  Known quirks:
    - Windows BLE stack may prepend 00 00 before real data
    - Polar H7/H10: flags 0x16 (contact + RR)
    - Wahoo TICKR: flags 0x06 (contact, no RR)
    - Garmin HRM-Dual: flags 0x10 (RR), may send extra RR bytes
    - Cheap HRM: flags 0x00, just HR uint8 }

procedure TBLEConnectionSession.ProcessHRMData(const Data: TBytes);
var
  HRM: TBytes;
  Flags: Byte;
  Offset: Integer;
  HR: Word;
  Stripped: Boolean;
begin
  if FDestroying then Exit;
  if Length(Data) < 2 then Exit;

  { Strip 00 00 BLE prefix if present (Windows BLE driver artifact) }
  Stripped := False;
  if (Length(Data) >= 4) and (Data[0] = 0) and (Data[1] = 0) then
  begin
    SetLength(HRM, Length(Data) - 2);
    Move(Data[2], HRM[0], Length(Data) - 2);
    Stripped := True;
  end
  else
    HRM := Data;

  if Length(HRM) < 2 then Exit;

  Offset := 0;
  Flags := HRM[0];
  Inc(Offset);

  { Heart Rate Value }
  if (Flags and $01) = 0 then
  begin
    { uint8 format }
    HR := HRM[Offset];
    Inc(Offset);
  end
  else
  begin
    { uint16 format (little-endian) }
    if Offset + 1 >= Length(HRM) then Exit;
    HR := HRM[Offset] or (HRM[Offset + 1] shl 8);
    Inc(Offset, 2);
  end;

  { Sanity check: valid HR range 20..250 bpm }
  if (HR > 0) and (HR <= 250) then
    FLastData.HeartRate := HR;

  FLastData.Timestamp := Now;

  { Skip Energy Expended if present (bit 3) — 2 bytes }
  if (Flags and $08) <> 0 then
    Inc(Offset, 2);

  { RR-Intervals (bit 4) — array of uint16, resolution 1/1024 s
    Not stored yet, but correctly skipped for future HRV analysis }

  if Stripped then
    Logger.Debug(Format('[%s] HRM (00-00 stripped): HR=%d flags=$%.2X',
      [FDeviceInfo.Address, FLastData.HeartRate, Flags]))
  else
    Logger.Debug(Format('[%s] HRM: HR=%d flags=$%.2X',
      [FDeviceInfo.Address, FLastData.HeartRate, Flags]));

  NotifyDataReceived;
end;

{ ── Cycling Speed & Cadence Measurement (0x2A5B) ── }

procedure TBLEConnectionSession.ProcessCSCData(const Data: TBytes);
var
  ParsedData: TTrainerDataRecord;
  CSCData: TBytes;
begin
  if FDestroying then Exit;
  if Length(Data) < 1 then Exit;

  { Strip 00 00 BLE prefix if present }
  if (Length(Data) >= 3) and (Data[0] = 0) and (Data[1] = 0) then
  begin
    SetLength(CSCData, Length(Data) - 2);
    Move(Data[2], CSCData[0], Length(Data) - 2);
  end
  else
    CSCData := Data;

  if Length(CSCData) < 1 then Exit;

  ParsedData := FFTMSParser.ParseCSCMeasurement(CSCData);
  if not FFTMSParser.LastPacketValid then Exit;
  FLastData := ParsedData;

  Logger.Debug(Format('[%s] CSC: Cadence=%d rpm',
    [FDeviceInfo.Address, FLastData.InstantCadence]));

  NotifyDataReceived;
end;

{ --- ANT packet building --- }

function TBLEConnectionSession.BuildANTPacket(MsgId, Channel: Byte;
  const Payload8: array of Byte): TBytes;
var
  I: Integer;
  CS: Byte;
begin
  if Length(Payload8) <> 8 then
    raise Exception.Create('ANT payload must be exactly 8 bytes');

  SetLength(Result, 13);
  Result[0] := $A4;
  Result[1] := $09;
  Result[2] := MsgId;
  Result[3] := Channel;

  for I := 0 to 7 do
    Result[4 + I] := Payload8[I];

  CS := 0;
  for I := 0 to 11 do
    CS := CS xor Result[I];
  Result[12] := CS;
end;

function TBLEConnectionSession.SendFECPage(const Page8: array of Byte;
  Acked: Boolean): Boolean;
var
  Packet13: TBytes;
  Packet9: TBytes;
  Packet8: TBytes;
  MsgId: Byte;
  Ch: Byte;
  HexStr: string;
  I: Integer;
begin
  Result := False;

  if FDestroying then Exit;

  if Length(Page8) <> 8 then
  begin
    Logger.Error(Format('[%s] SendFECPage: page must be 8 bytes',
      [FDeviceInfo.Address]));
    Exit;
  end;

  if Acked then
    MsgId := $4F
  else
    MsgId := $4E;

  if FHasFECChannel then
    Ch := FFECChannel
  else
  begin
    Ch := 5;
    Logger.Warning(Format('[%s] FEC channel not learned yet, using fallback channel 5',
      [FDeviceInfo.Address]));
  end;

  Packet13 := BuildANTPacket(MsgId, Ch, Page8);

  HexStr := '';
  for I := 0 to High(Packet13) do
    HexStr := HexStr + IntToHex(Packet13[I], 2) + ' ';
  Logger.Debug(Format('[%s] SendFECPage[13/full]: %s',
    [FDeviceInfo.Address, HexStr]));

  Result := FBLEDevice.WriteCharacteristic(UUID_FEC_WRITE, Packet13, True);
  if Result then
  begin
    Logger.Debug(Format('[%s] SendFECPage: full ANT frame accepted',
      [FDeviceInfo.Address]));
    Exit;
  end;

  Logger.Warning(Format('[%s] SendFECPage: full ANT frame rejected, trying 9-byte channel+payload',
    [FDeviceInfo.Address]));

  SetLength(Packet9, 9);
  Packet9[0] := Ch;
  for I := 0 to 7 do
    Packet9[1 + I] := Page8[I];

  HexStr := '';
  for I := 0 to High(Packet9) do
    HexStr := HexStr + IntToHex(Packet9[I], 2) + ' ';
  Logger.Debug(Format('[%s] SendFECPage[9/ch+data]: %s',
    [FDeviceInfo.Address, HexStr]));

  Result := FBLEDevice.WriteCharacteristic(UUID_FEC_WRITE, Packet9, True);
  if Result then
  begin
    Logger.Debug(Format('[%s] SendFECPage: 9-byte channel+payload accepted',
      [FDeviceInfo.Address]));
    Exit;
  end;

  Logger.Warning(Format('[%s] SendFECPage: 9-byte channel+payload rejected, trying raw 8-byte page',
    [FDeviceInfo.Address]));

  SetLength(Packet8, 8);
  for I := 0 to 7 do
    Packet8[I] := Page8[I];

  HexStr := '';
  for I := 0 to High(Packet8) do
    HexStr := HexStr + IntToHex(Packet8[I], 2) + ' ';
  Logger.Debug(Format('[%s] SendFECPage[8/raw]: %s',
    [FDeviceInfo.Address, HexStr]));

  Result := FBLEDevice.WriteCharacteristic(UUID_FEC_WRITE, Packet8, True);
  if Result then
  begin
    Logger.Debug(Format('[%s] SendFECPage: raw 8-byte page accepted',
      [FDeviceInfo.Address]));
    Exit;
  end;

  Logger.Error(Format('[%s] SendFECPage failed in all formats',
    [FDeviceInfo.Address]));
end;

{ --- Connect / Disconnect --- }

function TBLEConnectionSession.Connect: Boolean;
var
  I: Integer;
  HasFEC, HasPower, LocalHasFTMS, HasHR: Boolean;
  HasCSC: Boolean;
  NotifyCharUUID: string;
  ServiceUUID, CharUUID: string;
  NotifySubscribed: Boolean;
begin
  Result := False;
  if FDestroying then Exit;

  if FConnectionState = csConnected then
    Exit(True);

  SetConnectionState(csConnecting, T('Connecting...'));
  Logger.Info('BLESession.Connect: ' + FDeviceInfo.Address);

  if not FBLEDevice.Connect(FDeviceInfo.Address) then
  begin
    SetConnectionState(csError, T('Connection failed'));
    Exit;
  end;

  FBLEDevice.OnNotification := @OnBLENotification;

  FBLEDevice.DiscoverAllCharacteristics;

  HasFEC := False;
  HasPower := False;
  LocalHasFTMS := False;
  HasHR := False;
  HasCSC := False;

  for I := 0 to High(FBLEDevice.Services) do
  begin
    ServiceUUID := LowerCase(FBLEDevice.Services[I].Uuid.UuidString);

    if Pos('6e40fec1', ServiceUUID) > 0 then
      HasFEC := True
    else if Pos('00001818', ServiceUUID) > 0 then
      HasPower := True
    else if Pos('00001826', ServiceUUID) > 0 then
      LocalHasFTMS := True
    else if Pos('0000180d', ServiceUUID) > 0 then
      HasHR := True
    else if Pos('00001816', ServiceUUID) > 0 then
      HasCSC := True;
  end;

  if FBLEDevice.FriendlyName <> '' then
    FDeviceInfo.Name := FBLEDevice.FriendlyName
  else if FDeviceInfo.Name = '' then
    FDeviceInfo.Name := FDeviceInfo.Address;

  FDeviceInfo.TransportType := ttBLE;
  FDeviceInfo.ProviderName := 'WinBLE';
  FDeviceInfo.SupportsFTMS := LocalHasFTMS;
  FHasFTMS := LocalHasFTMS;
  FDeviceInfo.SupportsControl := HasFEC or LocalHasFTMS;
  FDeviceInfo.SupportsPower := HasPower or HasFEC or LocalHasFTMS;
  FDeviceInfo.SupportsCadence := HasFEC or LocalHasFTMS or HasCSC or HasPower;
  FDeviceInfo.SupportsHeartRate := HasHR;

  FUseFEC := HasFEC;
  FHasControl := False;
  FFECChannel := 0;
  FHasFECChannel := False;

  NotifyCharUUID := '';
  NotifySubscribed := False;

  for I := 0 to High(FBLEDevice.Characteristics) do
  begin
    CharUUID := LowerCase(FBLEDevice.Characteristics[I].Uuid.UuidString);

    if HasFEC and FBLEDevice.Characteristics[I].IsNotifiable and
       (Pos('6e40fec2', CharUUID) > 0) then
    begin
      NotifyCharUUID := FBLEDevice.Characteristics[I].Uuid.UuidString;
      Break;
    end
    else if LocalHasFTMS and
            (FBLEDevice.Characteristics[I].IsNotifiable or
             FBLEDevice.Characteristics[I].IsIndicatable) and
            (Pos('2ad2', CharUUID) > 0) then
    begin
      NotifyCharUUID := FBLEDevice.Characteristics[I].Uuid.UuidString;
      Break;
    end
    else if HasPower and FBLEDevice.Characteristics[I].IsNotifiable and
            (Pos('2a63', CharUUID) > 0) then
    begin
      NotifyCharUUID := FBLEDevice.Characteristics[I].Uuid.UuidString;
      Break;
    end;
  end;

  if NotifyCharUUID <> '' then
  begin
    NotifySubscribed := FBLEDevice.EnableNotifications(NotifyCharUUID);
    if NotifySubscribed then
      Sleep(100);
  end;

  if (not NotifySubscribed) and HasPower then
  begin
    for I := 0 to High(FBLEDevice.Characteristics) do
    begin
      CharUUID := LowerCase(FBLEDevice.Characteristics[I].Uuid.UuidString);
      if FBLEDevice.Characteristics[I].IsNotifiable and (Pos('2a63', CharUUID) > 0) then
      begin
        NotifySubscribed := FBLEDevice.EnableNotifications(
          FBLEDevice.Characteristics[I].Uuid.UuidString);
        if NotifySubscribed then
          FUseFEC := False;
        Break;
      end;
    end;
  end;

  if LocalHasFTMS then
  begin
    for I := 0 to High(FBLEDevice.Characteristics) do
    begin
      CharUUID := LowerCase(FBLEDevice.Characteristics[I].Uuid.UuidString);
      if (Pos('2ad9', CharUUID) > 0) and
         (FBLEDevice.Characteristics[I].IsIndicatable or
          FBLEDevice.Characteristics[I].IsNotifiable) then
      begin
        FBLEDevice.EnableNotifications(FBLEDevice.Characteristics[I].Uuid.UuidString);
        Break;
      end;
    end;
  end;

  if HasHR then
  begin
    for I := 0 to High(FBLEDevice.Characteristics) do
    begin
      CharUUID := LowerCase(FBLEDevice.Characteristics[I].Uuid.UuidString);
      if FBLEDevice.Characteristics[I].IsNotifiable and (Pos('2a37', CharUUID) > 0) then
      begin
        FBLEDevice.EnableNotifications(FBLEDevice.Characteristics[I].Uuid.UuidString);
        Break;
      end;
    end;
  end;

  { Subscribe to Cycling Speed & Cadence (0x2A5B) if present }
  if HasCSC then
  begin
    for I := 0 to High(FBLEDevice.Characteristics) do
    begin
      CharUUID := LowerCase(FBLEDevice.Characteristics[I].Uuid.UuidString);
      if FBLEDevice.Characteristics[I].IsNotifiable and (Pos('2a5b', CharUUID) > 0) then
      begin
        FBLEDevice.EnableNotifications(FBLEDevice.Characteristics[I].Uuid.UuidString);
        Logger.Info('CSC Measurement subscribed');
        Break;
      end;
    end;
  end;

  FTrainerFeatures := Default(TTrainerFeatures);
  FTrainerFeatures.SupportsPowerControl := HasFEC or LocalHasFTMS;
  FTrainerFeatures.SupportsResistanceControl := HasFEC or LocalHasFTMS;
  FTrainerFeatures.SupportsInclineControl := HasFEC or LocalHasFTMS;
  FTrainerFeatures.SupportsSimulation := HasFEC or LocalHasFTMS;
  FTrainerFeatures.MinPower := 50;
  FTrainerFeatures.MaxPower := 2000;
  FTrainerFeatures.MaxResistance := 100;
  FTrainerFeatures.MinIncline := -10;
  FTrainerFeatures.MaxIncline := 20;

  SetConnectionState(csConnected, T('Connected: ') + FDeviceInfo.Name);
  Result := True;
end;

procedure TBLEConnectionSession.Disconnect;
begin
  CancelControl;
  if Assigned(FBLEDevice) then
    FBLEDevice.OnNotification := nil;

  if Assigned(FBLEDevice) then
    FBLEDevice.Disconnect;

  FHasControl := False;
  FUseFEC := False;
  FFECChannel := 0;
  FHasFECChannel := False;
  FTrainerFeatures := Default(TTrainerFeatures);
  FLastData := Default(TTrainerDataRecord);

  if not FDestroying then
    SetConnectionState(csDisconnected, T('Disconnected'));
end;

{ --- Trainer control --- }

function TBLEConnectionSession.WriteFTMSCommand(const Data: TBytes): Boolean;
begin
  Result := FBLEDevice.WriteCharacteristic(UUID_FTMS_CONTROL_POINT, Data, True);
end;

function TBLEConnectionSession.RequestControl: Boolean;
begin
  if FUseFEC then Exit(FConnectionState = csConnected);
  Result := inherited RequestControl;
end;

function TBLEConnectionSession.SetTargetPower(Watts: Word): Boolean;
var Page: array[0..7] of Byte; W: Word;
begin
  if not FUseFEC then Exit(inherited SetTargetPower(Watts));
  if FConnectionState <> csConnected then Exit(False);
  FillChar(Page, SizeOf(Page), $FF);
  W := Min(16383, Watts) * 4;
  Page[0] := 49; Page[6] := Lo(W); Page[7] := Hi(W);
  Result := SendFECPage(Page);
end;

function TBLEConnectionSession.SetResistanceLevel(Level: Byte): Boolean;
var Page: array[0..7] of Byte;
begin
  if not FUseFEC then Exit(inherited SetResistanceLevel(Level));
  if FConnectionState <> csConnected then Exit(False);
  FillChar(Page, SizeOf(Page), $FF);
  Page[0] := 48; Page[7] := Min(100, Level) * 2;
  Result := SendFECPage(Page);
end;

function TBLEConnectionSession.SetIncline(InclinePercent: Single): Boolean;
var Page: array[0..7] of Byte; Grade: Word;
begin
  if not FUseFEC then Exit(inherited SetIncline(InclinePercent));
  if FConnectionState <> csConnected then Exit(False);
  FillChar(Page, SizeOf(Page), $FF);
  Grade := Round((EnsureRange(InclinePercent, -200.0, 200.0) + 200) * 100);
  Page[0] := 51; Page[5] := Lo(Grade); Page[6] := Hi(Grade); Page[7] := 50;
  Result := SendFECPage(Page);
end;

function TBLEConnectionSession.SetSimulation(Grade: Single; WindSpeed: Single;
  RiderWeight: Single; BikeWeight: Single): Boolean;
var Page: array[0..7] of Byte;
begin
  if not FUseFEC then Exit(inherited SetSimulation(Grade, WindSpeed, RiderWeight, BikeWeight));
  Result := SetIncline(Grade);
  if not Result then Exit;
  FillChar(Page, SizeOf(Page), $FF);
  Page[0] := 50; Page[4] := 51;
  Page[5] := EnsureRange(Round(WindSpeed * 3.6) + 127, 0, 254);
  Page[6] := 100;
  Result := SendFECPage(Page);
end;

function TBLEConnectionSession.Start: Boolean;
begin
  if FUseFEC then Exit(FConnectionState = csConnected);
  Result := inherited Start;
end;

function TBLEConnectionSession.Stop: Boolean;
begin
  if FUseFEC then Exit(SetTargetPower(0));
  Result := inherited Stop;
end;

function TBLEConnectionSession.Pause: Boolean;
begin
  if FUseFEC then Exit(SetTargetPower(0));
  Result := inherited Pause;
end;

function TBLEConnectionSession.Reset: Boolean;
begin
  if FUseFEC then Exit(SetTargetPower(0));
  Result := inherited Reset;
end;

{ ============================================================================ }
{ TBLETransportProvider                                                        }
{ ============================================================================ }

class function TBLETransportProvider.TransportType: TTransportType;
begin
  Result := ttBLE;
end;

procedure TBLETransportProvider.StartScan;
var
  Scanner: TBLEScanner;
  Devices: TBLEDeviceInfoArray;
  I: Integer;
  DevInfo: TDeviceInfo;
begin
  Scanner := TBLEScanner.Create;
  try
    Devices := Scanner.Scan;
    for I := 0 to High(Devices) do
    begin
      DevInfo := Default(TDeviceInfo);
      DevInfo.Name := Devices[I].FriendlyName;
      DevInfo.Address := Devices[I].DevicePath;
      DevInfo.TransportType := ttBLE;
      DevInfo.ProviderName := 'WinBLE';
      DevInfo.RSSI := 0;
      DevInfo.SupportsFTMS := False;
      DevInfo.SupportsPower := False;
      DevInfo.SupportsCadence := False;
      DevInfo.SupportsHeartRate := False;

      if Assigned(OnDeviceFound) then
        OnDeviceFound(DevInfo);
    end;
  finally
    Scanner.Free;
  end;
end;

procedure TBLETransportProvider.StopScan;
begin
  // пока скан синхронный и останавливать нечего
end;

function TBLETransportProvider.CreateSession(const AAddress: string;
  const AFriendlyName: string): TTransportSession;
begin
  Result := TBLEConnectionSession.Create(AAddress, AFriendlyName);
end;

end.
