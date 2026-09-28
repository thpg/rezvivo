unit BLEDevice;

{$mode objfpc}{$H+}

interface

uses
  Windows, Classes, SysUtils, syncobjs, WinBluetoothLE, DebugLog;

type
  PBTH_LE_UUID = ^BTH_LE_UUID;
  BTH_LE_UUID = packed record
    IsShortUuid: Byte;
    Reserved: Byte;
    ShortUuid: Word;
    LongUuid: TGUID;
  end;

  PBTH_LE_GATT_CHARACTERISTIC = ^BTH_LE_GATT_CHARACTERISTIC;
  BTH_LE_GATT_CHARACTERISTIC = packed record
    ServiceHandle: Word;
    Reserved: Word;
    CharacteristicUuid: BTH_LE_UUID;
    AttributeHandle: Word;
    CharacteristicValueHandle: Word;
    CharacteristicProperties: Byte;
    Padding: array[0..6] of Byte;
  end;

  TBLEDeviceInfo = record
    DevicePath: string;
    FriendlyName: string;
  end;
  TBLEDeviceInfoArray = array of TBLEDeviceInfo;

  TBLENotificationCallback = procedure(const CharUUID: string; const Data: TBytes) of object;

  TNotificationEntry = record
    CharAttrHandle: Word;
    CharValueHandle: Word;
    CharUUID: string;
    EventHandle: BLUETOOTH_GATT_EVENT_HANDLE;
    ServiceHandle: THandle;
    CallbackToken: Pointer;
    CallbackRoute: TObject;
  end;

  TBLEDevice = class
  private
    FDevicePath: string;
    FFriendlyName: string;
    FDeviceHandle: THandle;
    FConnected: Boolean;
    FLock: TCriticalSection;

    FServices: TBthLeServiceInfoArray;
    FCharacteristics: TBthLeCharInfoArray;
    FNotifications: array of TNotificationEntry;

    FOnNotification: TBLENotificationCallback;

    function FindCharByUUID(const UUID: string): Integer;
    function FindServicePaths: Boolean;
    function OpenServiceHandle(ServiceIndex: Integer): THandle;

  public
    constructor Create;
    destructor Destroy; override;

    function Connect(const ADevicePath: string): Boolean;
    procedure Disconnect;

    function DiscoverServices: Boolean;
    function DiscoverCharacteristics(ServiceIndex: Integer): Boolean;
    function DiscoverAllCharacteristics: Boolean;

    function ReadCharacteristic(const CharUUID: string; out Data: TBytes): Boolean;
    function WriteCharacteristic(const CharUUID: string; const Data: TBytes;
      WithResponse: Boolean = True): Boolean;
    function EnableNotifications(const CharUUID: string): Boolean;

    property DevicePath: string read FDevicePath;
    property FriendlyName: string read FFriendlyName write FFriendlyName;
    property Connected: Boolean read FConnected;
    property Services: TBthLeServiceInfoArray read FServices;
    property Characteristics: TBthLeCharInfoArray read FCharacteristics;
    property OnNotification: TBLENotificationCallback read FOnNotification write FOnNotification;
    property DeviceHandle: THandle read FDeviceHandle;
  end;

  TBLEScanner = class
  private
    FDevices: TBLEDeviceInfoArray;
    function GetDeviceFriendlyName(DevInfoSet: HDEVINFO; var DevInfoData: SP_DEVINFO_DATA): string;
  public
    function Scan: TBLEDeviceInfoArray;
    property Devices: TBLEDeviceInfoArray read FDevices;
  end;

var
  GBLEDeviceInstance: TBLEDevice = nil;

procedure GlobalGATTCallback(EventType: BTH_LE_GATT_EVENT_TYPE;
  EventOutParameter: Pointer; Context: Pointer); stdcall;
function DecodeGATTNotification(EventData: Pointer; out ChangedHandle: Word;
  out Data: TBytes): Boolean;

implementation

uses GameTrainerControl, GameCallbackRegistry;

const
  SERVICE_STRUCT_SIZE = 24;
  CHAR_STRUCT_SIZE = 36;
  DESC_STRUCT_SIZE = 32;

{$push}{$packrecords C}
type
  PBthLeGattCharacteristicValueRaw = ^TBthLeGattCharacteristicValueRaw;
  TBthLeGattCharacteristicValueRaw = record
    DataSize: Cardinal;
    Data: array[0..0] of Byte;
  end;

  PBthLeGattValueChangedEventRaw = ^TBthLeGattValueChangedEventRaw;
  TBthLeGattValueChangedEventRaw = record
    ChangedAttributeHandle: Word;
    CharacteristicValueDataSize: NativeUInt;
    CharacteristicValue: Pointer;
  end;
{$pop}
  TBLENotificationRoute = class
    Callback: TBLENotificationCallback;
    CharUUID: String;
    AttrHandle, ValueHandle: Word;
  end;

function DecodeGATTNotification(EventData: Pointer; out ChangedHandle: Word;
  out Data: TBytes): Boolean;
var Event: PBthLeGattValueChangedEventRaw; Value: PBthLeGattCharacteristicValueRaw;
begin
  Result := False; ChangedHandle := 0; Data := nil;
  if EventData = nil then Exit;
  Event := PBthLeGattValueChangedEventRaw(EventData);
  if (Event^.CharacteristicValue = nil) or
    (Event^.CharacteristicValueDataSize < SizeOf(Cardinal)) then Exit;
  Value := PBthLeGattCharacteristicValueRaw(Event^.CharacteristicValue);
  { Event size includes the ULONG length header; payload size does not. }
  if (Value^.DataSize > 65535) or
    (Value^.DataSize > Event^.CharacteristicValueDataSize - SizeOf(Cardinal)) then Exit;
  ChangedHandle := Event^.ChangedAttributeHandle;
  SetLength(Data, Value^.DataSize);
  if Length(Data) > 0 then Move(Value^.Data[0], Data[0], Length(Data));
  Result := True;
end;
procedure GlobalGATTCallback(EventType: BTH_LE_GATT_EVENT_TYPE;
  EventOutParameter: Pointer; Context: Pointer); stdcall;
var Gate: TTrainerCallbackGate; Target: TObject; Route: TBLENotificationRoute;
  Data: TBytes; ChangedHandle: Word;
begin
  if EventType <> CharacteristicValueChangedEvent then Exit;
  Gate := AcquireCallbackTarget(Context, Target);
  if Gate = nil then Exit;
  try
    try
      Route := TBLENotificationRoute(Target);
      if DecodeGATTNotification(EventOutParameter, ChangedHandle, Data) and
        ((ChangedHandle = Route.AttrHandle) or (ChangedHandle = Route.ValueHandle)) and
        Assigned(Route.Callback) then Route.Callback(Route.CharUUID, Data);
    except
      on E: Exception do Logger.Error('GlobalGATTCallback exception: ' + E.Message);
    end;
  finally Gate.Release end;
end;
{ TBLEDevice }

constructor TBLEDevice.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FDeviceHandle := INVALID_HANDLE_VALUE;
  FConnected := False;
  GBLEDeviceInstance := Self;
end;

destructor TBLEDevice.Destroy;
begin
  Disconnect;
  GBLEDeviceInstance := nil;
  FLock.Free;
  inherited;
end;

function TBLEDevice.Connect(const ADevicePath: string): Boolean;
begin
  Result := False;
  if FConnected then Disconnect;
  FLock.Enter;
  try

    FDevicePath := ADevicePath;
    Logger.Info('Connecting to: ' + ADevicePath);

    FDeviceHandle := CreateFileW(
      PWideChar(WideString(ADevicePath)),
      GENERIC_READ or GENERIC_WRITE,
      FILE_SHARE_READ or FILE_SHARE_WRITE,
      nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);

    if FDeviceHandle = INVALID_HANDLE_VALUE then
    begin
      FDeviceHandle := CreateFileW(
        PWideChar(WideString(ADevicePath)),
        GENERIC_READ,
        FILE_SHARE_READ or FILE_SHARE_WRITE,
        nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
    end;

    if FDeviceHandle = INVALID_HANDLE_VALUE then
    begin
      Logger.Error(Format('Failed to open device: %d', [GetLastError]));
      Exit;
    end;

    Logger.Info(Format('Device opened, handle=%d', [FDeviceHandle]));
    FConnected := True;
    Result := True;

    DiscoverServices;
    FindServicePaths;
  finally
    FLock.Leave;
  end;
end;

procedure TBLEDevice.Disconnect;
var
  I: Integer;
  Retired: array of TNotificationEntry;
begin
  { No OS unregister or callback drain under the device lock. Each callback
    owns a stable UUID/method snapshot and never traverses mutable arrays. }
  FLock.Enter;
  try
    Retired := FNotifications;
    SetLength(FNotifications, 0);
    FConnected := False;
  finally FLock.Leave end;
  for I := 0 to High(Retired) do
  begin
    UnregisterCallbackTarget(Retired[I].CallbackToken);
    if Retired[I].EventHandle <> 0 then
      BluetoothGATTUnregisterEvent(Retired[I].EventHandle, BLUETOOTH_GATT_FLAG_NONE);
    Retired[I].CallbackRoute.Free;
  end;

  FLock.Enter;
  try
    for I := 0 to High(FServices) do
    begin
      if FServices[I].ServiceHandle <> INVALID_HANDLE_VALUE then
      begin
        CloseHandle(FServices[I].ServiceHandle);
        FServices[I].ServiceHandle := INVALID_HANDLE_VALUE;
      end;
    end;

    if FDeviceHandle <> INVALID_HANDLE_VALUE then
    begin
      CloseHandle(FDeviceHandle);
      FDeviceHandle := INVALID_HANDLE_VALUE;
    end;

    FConnected := False;
    SetLength(FServices, 0);
    SetLength(FCharacteristics, 0);
    Logger.Info('Disconnected');
  finally
    FLock.Leave;
  end;
end;

function TBLEDevice.FindServicePaths: Boolean;
var
  DevInfoSet: HDEVINFO;
  DevInterfaceData: SP_DEVICE_INTERFACE_DATA;
  DevInterfaceDetailData: PSP_DEVICE_INTERFACE_DETAIL_DATA_W;
  RequiredSize: DWORD;
  MemberIndex: DWORD;
  ServicePath: string;
  I: Integer;
  DeviceID, DeviceIDShort: string;
  ServiceUUID, PathLower, UUIDLower: string;
  MatchedService: Integer;
  MatchedCount: Integer;
begin
  Result := False;

  I := Pos('dev_', LowerCase(FDevicePath));
  if I > 0 then
  begin
    DeviceID := Copy(FDevicePath, I, 16);
    DeviceIDShort := Copy(DeviceID, 5, 12);
  end
  else
    Exit;

  if DeviceID = '' then Exit;

  Logger.Info('Searching GATT service paths for DeviceID=' + DeviceID);

  DevInfoSet := SetupDiGetClassDevsW(
    @GUID_BLUETOOTH_GATT_SERVICE_DEVICE_INTERFACE,
    nil, 0, DIGCF_PRESENT or DIGCF_DEVICEINTERFACE);

  if DevInfoSet = INVALID_HANDLE_VALUE then Exit;

  try
    MemberIndex := 0;

    while True do
    begin
      FillChar(DevInterfaceData, SizeOf(DevInterfaceData), 0);
      DevInterfaceData.cbSize := SizeOf(SP_DEVICE_INTERFACE_DATA);

      if not SetupDiEnumDeviceInterfaces(DevInfoSet, nil,
           @GUID_BLUETOOTH_GATT_SERVICE_DEVICE_INTERFACE,
           MemberIndex, @DevInterfaceData) then
      begin
        if GetLastError = ERROR_NO_MORE_ITEMS then Break;
        Inc(MemberIndex);
        Continue;
      end;

      RequiredSize := 0;
      SetupDiGetDeviceInterfaceDetailW(DevInfoSet, @DevInterfaceData, nil, 0, @RequiredSize, nil);

      if RequiredSize = 0 then
      begin
        Inc(MemberIndex);
        Continue;
      end;

      GetMem(DevInterfaceDetailData, RequiredSize);
      try
        FillChar(DevInterfaceDetailData^, RequiredSize, 0);
        {$IFDEF CPU64}
        DevInterfaceDetailData^.cbSize := 8;
        {$ELSE}
        DevInterfaceDetailData^.cbSize := 6;
        {$ENDIF}

        if SetupDiGetDeviceInterfaceDetailW(DevInfoSet, @DevInterfaceData,
             DevInterfaceDetailData, RequiredSize, nil, nil) then
        begin
          ServicePath := WideCharToString(@DevInterfaceDetailData^.DevicePath[0]);
          Logger.Debug('Found service path: ' + ServicePath);

          PathLower := LowerCase(ServicePath);

          if (Pos(LowerCase(DeviceID), PathLower) > 0) or
             (Pos(LowerCase(DeviceIDShort), PathLower) > 0) then
          begin
            Logger.Debug('  DeviceID matches, searching for service UUID...');

            MatchedService := -1;

            for I := 0 to High(FServices) do
            begin
              if FServices[I].ServiceDevicePath <> '' then
                Continue;

              ServiceUUID := FServices[I].Uuid.UuidString;
              UUIDLower := LowerCase(ServiceUUID);

              if (Length(UUIDLower) > 0) and (UUIDLower[1] = '{') then
                UUIDLower := Copy(UUIDLower, 2, Length(UUIDLower) - 2);

              if Pos(UUIDLower, PathLower) > 0 then
              begin
                MatchedService := I;
                Break;
              end;
            end;

            if MatchedService >= 0 then
            begin
              FServices[MatchedService].ServiceDevicePath := ServicePath;
              Logger.Info('✅ Matched service ' + FServices[MatchedService].Uuid.UuidString + ' to path');
              Result := True;
            end
            else
              Logger.Debug('  No service UUID found in path');
          end
          else
            Logger.Debug('  DeviceID does not match');
        end;
      finally
        FreeMem(DevInterfaceDetailData);
      end;

      Inc(MemberIndex);
    end;
  finally
    SetupDiDestroyDeviceInfoList(DevInfoSet);
  end;

  MatchedCount := 0;
  for I := 0 to High(FServices) do
    if FServices[I].ServiceDevicePath <> '' then
      Inc(MatchedCount);

  Logger.Info(Format('FindServicePaths result: %d services matched', [MatchedCount]));
end;

function TBLEDevice.OpenServiceHandle(ServiceIndex: Integer): THandle;
begin
  Result := INVALID_HANDLE_VALUE;

  if (ServiceIndex < 0) or (ServiceIndex > High(FServices)) then Exit;

  if FServices[ServiceIndex].ServiceHandle <> INVALID_HANDLE_VALUE then
  begin
    Result := FServices[ServiceIndex].ServiceHandle;
    Exit;
  end;

  if FServices[ServiceIndex].ServiceDevicePath = '' then
  begin
    Logger.Warning('No service path for: ' + FServices[ServiceIndex].Uuid.UuidString);
    Exit;
  end;

  Result := CreateFileW(
    PWideChar(WideString(FServices[ServiceIndex].ServiceDevicePath)),
    GENERIC_READ or GENERIC_WRITE,
    FILE_SHARE_READ or FILE_SHARE_WRITE,
    nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);

  if Result = INVALID_HANDLE_VALUE then
  begin
    Result := CreateFileW(
      PWideChar(WideString(FServices[ServiceIndex].ServiceDevicePath)),
      GENERIC_READ,
      FILE_SHARE_READ or FILE_SHARE_WRITE,
      nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  end;

  if Result <> INVALID_HANDLE_VALUE then
  begin
    FServices[ServiceIndex].ServiceHandle := Result;
    Logger.Debug(Format('Opened service handle=%d for %s', [Result, FServices[ServiceIndex].Uuid.UuidString]));
  end
  else
    Logger.Error(Format('Failed to open service: %d', [GetLastError]));
end;

function TBLEDevice.DiscoverServices: Boolean;
var
  ServiceCount: Word;
  Buffer: PByte;
  BufSize: Integer;
  HR: HRESULT;
  I: Integer;
  RawService: TRawBthLeGattService;
begin
  Result := False;
  if not FConnected then Exit;

  ServiceCount := 0;
  HR := BluetoothGATTGetServices(FDeviceHandle, 0, nil, @ServiceCount, BLUETOOTH_GATT_FLAG_NONE);
  if HR < 0 then
    HR := 0;

  Logger.Debug('GetServices: HR=0x' + IntToHex(Cardinal(HR), 8) +
    Format(', count=%d', [ServiceCount]));

  if ServiceCount = 0 then Exit;

  BufSize := ServiceCount * SERVICE_STRUCT_SIZE;
  GetMem(Buffer, BufSize);
  try
    FillChar(Buffer^, BufSize, 0);
    HR := BluetoothGATTGetServices(FDeviceHandle, ServiceCount, Buffer, @ServiceCount, BLUETOOTH_GATT_FLAG_NONE);

    if FAILED(HR) then
    begin
      Logger.Error('GetServices failed: HR=0x' + IntToHex(Cardinal(HR), 8));
      Exit;
    end;

    SetLength(FServices, ServiceCount);
    for I := 0 to ServiceCount - 1 do
    begin
      Move((Buffer + I * SERVICE_STRUCT_SIZE)^, RawService[0], SizeOf(RawService));
      FServices[I] := ParseBthLeService(RawService);
      FServices[I].ServiceHandle := INVALID_HANDLE_VALUE;
      Logger.Debug(Format('Service %d: %s (handle=%d)', [
        I, FServices[I].Uuid.UuidString, FServices[I].AttributeHandle]));
    end;

    Result := True;
  finally
    FreeMem(Buffer);
  end;
end;

function TBLEDevice.DiscoverCharacteristics(ServiceIndex: Integer): Boolean;
var
  CharCount: Word;
  Buffer: PByte;
  BufSize: Integer;
  HR: HRESULT;
  I, BaseIdx: Integer;
  RawChar: TRawBthLeGattCharacteristic;
  CharInfo: TBthLeCharInfo;
  ServiceHandle: THandle;
begin
  Result := False;
  if not FConnected then Exit;
  if (ServiceIndex < 0) or (ServiceIndex > High(FServices)) then Exit;

  ServiceHandle := OpenServiceHandle(ServiceIndex);
  if ServiceHandle = INVALID_HANDLE_VALUE then
  begin
    Logger.Warning(Format('Cannot open service handle for %s, using device handle',
      [FServices[ServiceIndex].Uuid.UuidString]));
    ServiceHandle := FDeviceHandle;
  end;

  CharCount := 0;
  HR := BluetoothGATTGetCharacteristics(ServiceHandle, @FServices[ServiceIndex].RawData[0],
    0, nil, @CharCount, BLUETOOTH_GATT_FLAG_NONE);

  if CharCount = 0 then Exit;

  BufSize := CharCount * CHAR_STRUCT_SIZE;
  GetMem(Buffer, BufSize);
  try
    FillChar(Buffer^, BufSize, 0);
    HR := BluetoothGATTGetCharacteristics(ServiceHandle, @FServices[ServiceIndex].RawData[0],
      CharCount, Buffer, @CharCount, BLUETOOTH_GATT_FLAG_NONE);

    if FAILED(HR) then
    begin
      Logger.Error('GetCharacteristics failed: HR=0x' + IntToHex(Cardinal(HR), 8));
      Exit;
    end;

    BaseIdx := Length(FCharacteristics);
    SetLength(FCharacteristics, BaseIdx + CharCount);

    for I := 0 to CharCount - 1 do
    begin
      Move((Buffer + I * CHAR_STRUCT_SIZE)^, RawChar[0], SizeOf(RawChar));

      Logger.Debug(Format('  Raw[28-35]: %02X %02X %02X %02X %02X %02X %02X %02X', [
        RawChar[28], RawChar[29], RawChar[30], RawChar[31],
        RawChar[32], RawChar[33], RawChar[34], RawChar[35]]));

      CharInfo := ParseBthLeCharacteristic(RawChar);
      CharInfo.ServiceIndex := ServiceIndex;
      FCharacteristics[BaseIdx + I] := CharInfo;

      Logger.Debug(Format('  Char %d: %s (H=%d, VH=%d, R=%d, W=%d, N=%d, I=%d)', [
        I, CharInfo.Uuid.UuidString, CharInfo.AttributeHandle, CharInfo.ValueHandle,
        Ord(CharInfo.IsReadable), Ord(CharInfo.IsWritable),
        Ord(CharInfo.IsNotifiable), Ord(CharInfo.IsIndicatable)]));
    end;

    Result := True;
  finally
    FreeMem(Buffer);
  end;
end;

function TBLEDevice.DiscoverAllCharacteristics: Boolean;
var
  I: Integer;
begin
  Result := True;
  for I := 0 to High(FServices) do
    if not DiscoverCharacteristics(I) then
      Result := False;

  Logger.Info(Format('Total characteristics: %d', [Length(FCharacteristics)]));
end;

function TBLEDevice.FindCharByUUID(const UUID: string): Integer;
var
  I: Integer;
  SearchUUID: string;
begin
  Result := -1;
  SearchUUID := LowerCase(UUID);

  for I := 0 to High(FCharacteristics) do
  begin
    if Pos(SearchUUID, LowerCase(FCharacteristics[I].Uuid.UuidString)) > 0 then
    begin
      Result := I;
      Exit;
    end;
  end;
end;

function TBLEDevice.ReadCharacteristic(const CharUUID: string; out Data: TBytes): Boolean;
var
  Idx: Integer;
  ValueSize: Word;
  Value: PBTH_LE_GATT_CHARACTERISTIC_VALUE;
  HR: HRESULT;
  BufSize: Integer;
  ReadHandle: THandle;
begin
  Result := False;
  SetLength(Data, 0);

  Idx := FindCharByUUID(CharUUID);
  if Idx < 0 then Exit;

  FLock.Enter;
  try
    ReadHandle := FDeviceHandle;
    if (FCharacteristics[Idx].ServiceIndex >= 0) and
       (FCharacteristics[Idx].ServiceIndex <= High(FServices)) then
    begin
      if FServices[FCharacteristics[Idx].ServiceIndex].ServiceHandle <> INVALID_HANDLE_VALUE then
        ReadHandle := FServices[FCharacteristics[Idx].ServiceIndex].ServiceHandle
      else
      begin
        ReadHandle := OpenServiceHandle(FCharacteristics[Idx].ServiceIndex);
        if ReadHandle = INVALID_HANDLE_VALUE then
          ReadHandle := FDeviceHandle;
      end;
    end;

    ValueSize := 0;
    HR := BluetoothGATTGetCharacteristicValue(ReadHandle, @FCharacteristics[Idx].RawData[0],
      0, nil, @ValueSize, BLUETOOTH_GATT_FLAG_FORCE_READ_FROM_DEVICE);

    Logger.Debug('Read size query: HR=0x' + IntToHex(Cardinal(HR), 8) +
      Format(', size=%d', [ValueSize]));

    if ValueSize = 0 then Exit;

    BufSize := SizeOf(BTH_LE_GATT_CHARACTERISTIC_VALUE) + ValueSize;
    GetMem(Value, BufSize);
    try
      FillChar(Value^, BufSize, 0);
      Value^.DataSize := ValueSize;

      HR := BluetoothGATTGetCharacteristicValue(ReadHandle, @FCharacteristics[Idx].RawData[0],
        BufSize, Value, nil, BLUETOOTH_GATT_FLAG_FORCE_READ_FROM_DEVICE);

      if HR = S_OK then
      begin
        SetLength(Data, Value^.DataSize);
        if Value^.DataSize > 0 then
          Move(Value^.Data[0], Data[0], Value^.DataSize);
        Result := True;
      end;
    finally
      FreeMem(Value);
    end;
  finally
    FLock.Leave;
  end;
end;

function TBLEDevice.WriteCharacteristic(const CharUUID: string; const Data: TBytes; WithResponse: Boolean): Boolean;
var
  Idx: Integer;
  Value: PBTH_LE_GATT_CHARACTERISTIC_VALUE;
  HR: HRESULT;
  BufSize: Integer;
  Flags: ULONG;
  WriteHandle: THandle;
begin
  Result := False;

  Idx := FindCharByUUID(CharUUID);
  if Idx < 0 then
  begin
    Logger.Warning('WriteCharacteristic: not found: ' + CharUUID);
    Exit;
  end;

  if Length(Data) = 0 then Exit;

  FLock.Enter;
  try
    WriteHandle := FDeviceHandle;
    if (FCharacteristics[Idx].ServiceIndex >= 0) and
       (FCharacteristics[Idx].ServiceIndex <= High(FServices)) then
    begin
      if FServices[FCharacteristics[Idx].ServiceIndex].ServiceHandle <> INVALID_HANDLE_VALUE then
        WriteHandle := FServices[FCharacteristics[Idx].ServiceIndex].ServiceHandle
      else
      begin
        WriteHandle := OpenServiceHandle(FCharacteristics[Idx].ServiceIndex);
        if WriteHandle = INVALID_HANDLE_VALUE then
          WriteHandle := FDeviceHandle;
      end;
    end;

    BufSize := SizeOf(BTH_LE_GATT_CHARACTERISTIC_VALUE) + Length(Data);
    GetMem(Value, BufSize);
    try
      FillChar(Value^, BufSize, 0);
      Value^.DataSize := Length(Data);
      Move(Data[0], Value^.Data[0], Length(Data));

      Flags := BLUETOOTH_GATT_FLAG_NONE;
      if not WithResponse then
        Flags := BLUETOOTH_GATT_FLAG_WRITE_WITHOUT_RESPONSE;

      HR := BluetoothGATTSetCharacteristicValue(WriteHandle, @FCharacteristics[Idx].RawData[0],
        Value, 0, Flags);

      Result := SUCCEEDED(HR);
      if Result then
        Logger.Debug(Format('Wrote %d bytes to %s', [Length(Data), CharUUID]))
      else
        Logger.Error('Write failed: HR=0x' + IntToHex(Cardinal(HR), 8));
    finally
      FreeMem(Value);
    end;
  finally
    FLock.Leave;
  end;
end;

function TBLEDevice.EnableNotifications(const CharUUID: string): Boolean;
var
  Idx, ServiceIdx: Integer;
  ServiceHandle: THandle;
  DescCount: Word;
  DescBuffer: PByte;
  DescBufSize: Integer;
  HR: HRESULT;
  I: Integer;
  RawDesc: TRawBthLeGattDescriptor;
  DescInfo: TBthLeDescInfo;
  DescValue: PBTH_LE_GATT_CHARACTERISTIC_VALUE;
  CCCDValue: Word;
  EventHandle: BLUETOOTH_GATT_EVENT_HANDLE;
  NotifEntry: TNotificationEntry;
  CCCDFound: Boolean;

  EventRegBuffer: array[0..255] of Byte;
  EventRegSize: Integer;
  PWordNumChars: PWord;
  PCharData: PByte;
  Route: TBLENotificationRoute;
  Token: Pointer;
begin
  Result := False;
  Route := nil;
  Token := nil;

  Idx := FindCharByUUID(CharUUID);
  if Idx < 0 then
  begin
    Logger.Warning('EnableNotifications: characteristic not found: ' + CharUUID);
    Exit;
  end;

  if not (FCharacteristics[Idx].IsNotifiable or FCharacteristics[Idx].IsIndicatable) then
  begin
    Logger.Warning('EnableNotifications: char does not support notify/indicate: ' + CharUUID);
    Exit;
  end;

  ServiceIdx := FCharacteristics[Idx].ServiceIndex;
  if (ServiceIdx < 0) or (ServiceIdx > High(FServices)) then
  begin
    Logger.Warning('EnableNotifications: invalid service index');
    Exit;
  end;

  FLock.Enter;
  try
    Logger.Debug('EnableNotifications: ' + CharUUID);
    Logger.Debug(Format('  CharHandle=%d, ValueHandle=%d, ServiceAttrHandle=%d',
      [FCharacteristics[Idx].AttributeHandle,
       FCharacteristics[Idx].ValueHandle,
       FServices[ServiceIdx].AttributeHandle]));

    { Уже подписаны? }
    for I := 0 to High(FNotifications) do
    begin
      if (FNotifications[I].CharAttrHandle = FCharacteristics[Idx].AttributeHandle) or
         (FNotifications[I].CharValueHandle = FCharacteristics[Idx].ValueHandle) then
      begin
        Logger.Info('  Already subscribed');
        Result := True;
        Exit;
      end;
    end;

    ServiceHandle := OpenServiceHandle(ServiceIdx);
    if ServiceHandle = INVALID_HANDLE_VALUE then
    begin
      Logger.Warning('Failed to open service handle, trying device handle for CCCD/register');
      ServiceHandle := FDeviceHandle;
    end;

    { --- ШАГ 1: ищем CCCD и записываем notify/indicate --- }
    CCCDFound := False;
    DescCount := 0;

    HR := BluetoothGATTGetDescriptors(ServiceHandle, @FCharacteristics[Idx].RawData[0],
      0, nil, @DescCount, BLUETOOTH_GATT_FLAG_NONE);

    if DescCount > 0 then
    begin
      DescBufSize := DescCount * DESC_STRUCT_SIZE;
      GetMem(DescBuffer, DescBufSize);
      try
        FillChar(DescBuffer^, DescBufSize, 0);

        HR := BluetoothGATTGetDescriptors(ServiceHandle, @FCharacteristics[Idx].RawData[0],
          DescCount, DescBuffer, @DescCount, BLUETOOTH_GATT_FLAG_NONE);

        if SUCCEEDED(HR) then
        begin
          for I := 0 to DescCount - 1 do
          begin
            Move((DescBuffer + I * DESC_STRUCT_SIZE)^, RawDesc[0], SizeOf(RawDesc));
            DescInfo := ParseBthLeDescriptor(RawDesc);

            if DescInfo.Uuid.IsShortUuid and (DescInfo.Uuid.ShortUuid = $2902) then
            begin
              GetMem(DescValue, SizeOf(BTH_LE_GATT_CHARACTERISTIC_VALUE) + 2);
              try
                FillChar(DescValue^, SizeOf(BTH_LE_GATT_CHARACTERISTIC_VALUE) + 2, 0);
                DescValue^.DataSize := 2;

                if FCharacteristics[Idx].IsNotifiable then
                  CCCDValue := $0001
                else
                  CCCDValue := $0002;

                Move(CCCDValue, DescValue^.Data[0], 2);

                HR := BluetoothGATTSetDescriptorValue(ServiceHandle, @RawDesc[0],
                  DescValue, BLUETOOTH_GATT_FLAG_NONE);

                if SUCCEEDED(HR) then
                begin
                  Logger.Debug('  CCCD set OK');
                  CCCDFound := True;
                end
                else
                  Logger.Error('  CCCD write failed: HR=0x' + IntToHex(Cardinal(HR), 8));
              finally
                FreeMem(DescValue);
              end;
              Break;
            end;
          end;
        end
        else
          Logger.Error('  GetDescriptors failed: HR=0x' + IntToHex(Cardinal(HR), 8));
      finally
        FreeMem(DescBuffer);
      end;
    end;

    if not CCCDFound then
      Logger.Warning('  CCCD not found or write failed, but continuing...');

    { --- ШАГ 2: регистрация события ---
      Структура должна быть:
      USHORT NumCharacteristics (2 байта)
      padding/alignment (2 байта)
      BTH_LE_GATT_CHARACTERISTIC (36 байт)
      Итого 40 байт.
    }
    FillChar(EventRegBuffer, SizeOf(EventRegBuffer), 0);

    EventRegSize := 4 + SizeOf(FCharacteristics[Idx].RawData);

    if EventRegSize > SizeOf(EventRegBuffer) then
    begin
      Logger.Error(Format('  Event registration buffer too small: need=%d', [EventRegSize]));
      Exit;
    end;

    PWordNumChars := @EventRegBuffer[0];
    PWordNumChars^ := 1;

    { bytes 2..3 = padding }
    EventRegBuffer[2] := 0;
    EventRegBuffer[3] := 0;

    PCharData := @EventRegBuffer[4];
    Move(FCharacteristics[Idx].RawData[0], PCharData^, SizeOf(FCharacteristics[Idx].RawData));

    Logger.Debug(Format('  Registering: SvcH=%d, AttrH=%d, ValH=%d, RegSize=%d',
      [ServiceHandle,
       FCharacteristics[Idx].AttributeHandle,
       FCharacteristics[Idx].ValueHandle,
       EventRegSize]));

    Route := TBLENotificationRoute.Create;
    Route.Callback := FOnNotification;
    Route.CharUUID := FCharacteristics[Idx].Uuid.UuidString;
    Route.AttrHandle := FCharacteristics[Idx].AttributeHandle;
    Route.ValueHandle := FCharacteristics[Idx].ValueHandle;
    Token := RegisterCallbackTarget(Route);
    EventHandle := 0;
    HR := BluetoothGATTRegisterEvent(
      ServiceHandle,
      CharacteristicValueChangedEvent,
      @EventRegBuffer[0],
      @GlobalGATTCallback,
      Token,
      @EventHandle,
      BLUETOOTH_GATT_FLAG_NONE);

    if SUCCEEDED(HR) then
    begin
      Logger.Info(Format('  Event registered OK, EventHandle=%d', [EventHandle]));

      NotifEntry.CharAttrHandle := FCharacteristics[Idx].AttributeHandle;
      NotifEntry.CharValueHandle := FCharacteristics[Idx].ValueHandle;
      NotifEntry.CharUUID := FCharacteristics[Idx].Uuid.UuidString;
      NotifEntry.EventHandle := EventHandle;
      NotifEntry.ServiceHandle := ServiceHandle;
      NotifEntry.CallbackToken := Token;
      NotifEntry.CallbackRoute := Route;

      SetLength(FNotifications, Length(FNotifications) + 1);
      FNotifications[High(FNotifications)] := NotifEntry;
      Token := nil;
      Route := nil;

      Result := True;
    end
    else
      Logger.Error('  RegisterEvent failed: HR=0x' + IntToHex(Cardinal(HR), 8));
  finally
    UnregisterCallbackTarget(Token);
    Route.Free;
    FLock.Leave;
  end;
end;

{ TBLEScanner }

function TBLEScanner.GetDeviceFriendlyName(DevInfoSet: HDEVINFO; var DevInfoData: SP_DEVINFO_DATA): string;
var
  Buffer: array[0..255] of WideChar;
  RegDataType: DWORD;
  RequiredSize: DWORD;
begin
  Result := '';
  FillChar(Buffer, SizeOf(Buffer), 0);
  if SetupDiGetDeviceRegistryPropertyW(DevInfoSet, @DevInfoData, SPDRP_FRIENDLYNAME,
       @RegDataType, @Buffer[0], SizeOf(Buffer), @RequiredSize) then
    Result := WideCharToString(Buffer);
end;

function TBLEScanner.Scan: TBLEDeviceInfoArray;
var
  DevInfoSet: HDEVINFO;
  DevInfoData: SP_DEVINFO_DATA;
  DevInterfaceData: SP_DEVICE_INTERFACE_DATA;
  DevInterfaceDetailData: PSP_DEVICE_INTERFACE_DETAIL_DATA_W;
  RequiredSize: DWORD;
  MemberIndex: DWORD;
  DevInfo: TBLEDeviceInfo;
begin
  SetLength(Result, 0);
  SetLength(FDevices, 0);

  DevInfoSet := SetupDiGetClassDevsW(@GUID_BLUETOOTHLE_DEVICE_INTERFACE, nil, 0,
    DIGCF_PRESENT or DIGCF_DEVICEINTERFACE);

  if DevInfoSet = INVALID_HANDLE_VALUE then Exit;

  try
    MemberIndex := 0;

    while True do
    begin
      FillChar(DevInterfaceData, SizeOf(DevInterfaceData), 0);
      DevInterfaceData.cbSize := SizeOf(SP_DEVICE_INTERFACE_DATA);

      if not SetupDiEnumDeviceInterfaces(DevInfoSet, nil, @GUID_BLUETOOTHLE_DEVICE_INTERFACE,
           MemberIndex, @DevInterfaceData) then
      begin
        if GetLastError = ERROR_NO_MORE_ITEMS then Break;
        Inc(MemberIndex);
        Continue;
      end;

      RequiredSize := 0;
      SetupDiGetDeviceInterfaceDetailW(DevInfoSet, @DevInterfaceData, nil, 0, @RequiredSize, nil);

      if RequiredSize = 0 then
      begin
        Inc(MemberIndex);
        Continue;
      end;

      GetMem(DevInterfaceDetailData, RequiredSize);
      try
        FillChar(DevInterfaceDetailData^, RequiredSize, 0);
        {$IFDEF CPU64}
        DevInterfaceDetailData^.cbSize := 8;
        {$ELSE}
        DevInterfaceDetailData^.cbSize := 6;
        {$ENDIF}

        FillChar(DevInfoData, SizeOf(DevInfoData), 0);
        DevInfoData.cbSize := SizeOf(SP_DEVINFO_DATA);

        if SetupDiGetDeviceInterfaceDetailW(DevInfoSet, @DevInterfaceData,
             DevInterfaceDetailData, RequiredSize, nil, @DevInfoData) then
        begin
          DevInfo.DevicePath := WideCharToString(@DevInterfaceDetailData^.DevicePath[0]);
          DevInfo.FriendlyName := GetDeviceFriendlyName(DevInfoSet, DevInfoData);
          if DevInfo.FriendlyName = '' then
            DevInfo.FriendlyName := 'BLE Device';

          SetLength(FDevices, Length(FDevices) + 1);
          FDevices[High(FDevices)] := DevInfo;

          Logger.Info(Format('Found: %s', [DevInfo.FriendlyName]));
        end;
      finally
        FreeMem(DevInterfaceDetailData);
      end;

      Inc(MemberIndex);
    end;
  finally
    SetupDiDestroyDeviceInfoList(DevInfoSet);
  end;

  Result := FDevices;
end;

end.
