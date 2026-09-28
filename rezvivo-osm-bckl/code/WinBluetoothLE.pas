unit WinBluetoothLE;

{$mode objfpc}{$H+}

interface

uses
  Windows, Classes, SysUtils;

const
  BluetoothAPIs = 'BluetoothAPIs.dll';
  SetupAPI = 'setupapi.dll';

  // GUID для BLE устройств
  GUID_BLUETOOTHLE_DEVICE_INTERFACE: TGUID = '{781aee18-7733-4ce4-add0-91f41c67b592}';
  // GUID для GATT сервисов (важно для подписки на уведомления!)
  GUID_BLUETOOTH_GATT_SERVICE_DEVICE_INTERFACE: TGUID = '{6e3bb679-4372-40c8-9eaa-4509df260cd8}';

  DIGCF_PRESENT = $00000002;
  DIGCF_DEVICEINTERFACE = $00000010;

  BLUETOOTH_GATT_FLAG_NONE = $00000000;
  BLUETOOTH_GATT_FLAG_FORCE_READ_FROM_DEVICE = $00000004;
  BLUETOOTH_GATT_FLAG_WRITE_WITHOUT_RESPONSE = $00000020;

  ERROR_MORE_DATA = 234;
  ERROR_NO_MORE_ITEMS = 259;

  GENERIC_READ = DWORD($80000000);
  GENERIC_WRITE = $40000000;
  FILE_SHARE_READ = $00000001;
  FILE_SHARE_WRITE = $00000002;
  OPEN_EXISTING = 3;
  FILE_ATTRIBUTE_NORMAL = $00000080;

  SPDRP_FRIENDLYNAME = $0000000C;

type
  TRawBthLeUuid = array[0..19] of Byte;
  PRawBthLeUuid = ^TRawBthLeUuid;

  TRawBthLeGattService = array[0..23] of Byte;
  PRawBthLeGattService = ^TRawBthLeGattService;

  TRawBthLeGattCharacteristic = array[0..35] of Byte;
  PRawBthLeGattCharacteristic = ^TRawBthLeGattCharacteristic;

  TRawBthLeGattDescriptor = array[0..31] of Byte;
  PRawBthLeGattDescriptor = ^TRawBthLeGattDescriptor;

  BTH_LE_GATT_CHARACTERISTIC_VALUE = packed record
    DataSize: ULONG;
    Data: array[0..0] of Byte;
  end;
  PBTH_LE_GATT_CHARACTERISTIC_VALUE = ^BTH_LE_GATT_CHARACTERISTIC_VALUE;

  BTH_LE_GATT_EVENT_TYPE = LongInt;

const
  CharacteristicValueChangedEvent = 0;

type
  BTH_LE_GATT_VALUE_CHANGED_EVENT = packed record
    ChangedAttributeHandle: Word;
    Reserved: Word; // padding для выравнивания ULONG
    CharacteristicValueDataSize: ULONG;
    CharacteristicValue: PBTH_LE_GATT_CHARACTERISTIC_VALUE;
  end;

  PBTH_LE_GATT_VALUE_CHANGED_EVENT = ^BTH_LE_GATT_VALUE_CHANGED_EVENT;

  PFNBLUETOOTH_GATT_EVENT_CALLBACK = procedure(
    EventType: BTH_LE_GATT_EVENT_TYPE;
    EventOutParameter: Pointer;
    Context: Pointer); stdcall;

  BLUETOOTH_GATT_EVENT_HANDLE = THandle;
  PBLUETOOTH_GATT_EVENT_HANDLE = ^BLUETOOTH_GATT_EVENT_HANDLE;

  SP_DEVICE_INTERFACE_DATA = packed record
    cbSize: DWORD;
    InterfaceClassGuid: TGUID;
    Flags: DWORD;
    Reserved: ULONG_PTR;
  end;
  PSP_DEVICE_INTERFACE_DATA = ^SP_DEVICE_INTERFACE_DATA;

  SP_DEVICE_INTERFACE_DETAIL_DATA_W = packed record
    cbSize: DWORD;
    DevicePath: array[0..0] of WideChar;
  end;
  PSP_DEVICE_INTERFACE_DETAIL_DATA_W = ^SP_DEVICE_INTERFACE_DETAIL_DATA_W;

  SP_DEVINFO_DATA = packed record
    cbSize: DWORD;
    ClassGuid: TGUID;
    DevInst: DWORD;
    Reserved: ULONG_PTR;
  end;
  PSP_DEVINFO_DATA = ^SP_DEVINFO_DATA;

  HDEVINFO = THandle;

function SetupDiGetClassDevsW(ClassGuid: PGUID; Enumerator: PWideChar;
  hwndParent: HWND; Flags: DWORD): HDEVINFO; stdcall; external SetupAPI;
function SetupDiEnumDeviceInterfaces(DeviceInfoSet: HDEVINFO;
  DeviceInfoData: PSP_DEVINFO_DATA; InterfaceClassGuid: PGUID;
  MemberIndex: DWORD; DeviceInterfaceData: PSP_DEVICE_INTERFACE_DATA): BOOL; stdcall; external SetupAPI;
function SetupDiGetDeviceInterfaceDetailW(DeviceInfoSet: HDEVINFO;
  DeviceInterfaceData: PSP_DEVICE_INTERFACE_DATA;
  DeviceInterfaceDetailData: PSP_DEVICE_INTERFACE_DETAIL_DATA_W;
  DeviceInterfaceDetailDataSize: DWORD; RequiredSize: PDWORD;
  DeviceInfoData: PSP_DEVINFO_DATA): BOOL; stdcall; external SetupAPI;
function SetupDiDestroyDeviceInfoList(DeviceInfoSet: HDEVINFO): BOOL; stdcall; external SetupAPI;
function SetupDiGetDeviceRegistryPropertyW(DeviceInfoSet: HDEVINFO;
  DeviceInfoData: PSP_DEVINFO_DATA; Property_: DWORD; PropertyRegDataType: PDWORD;
  PropertyBuffer: PBYTE; PropertyBufferSize: DWORD;
  RequiredSize: PDWORD): BOOL; stdcall; external SetupAPI;

function BluetoothGATTGetServices(hDevice: THandle;
  ServicesBufferCount: Word; ServicesBuffer: Pointer;
  ServicesBufferActual: PWord; Flags: ULONG): HRESULT; stdcall; external BluetoothAPIs;
function BluetoothGATTGetCharacteristics(hDevice: THandle;
  Service: Pointer; CharacteristicsBufferCount: Word;
  CharacteristicsBuffer: Pointer;
  CharacteristicsBufferActual: PWord; Flags: ULONG): HRESULT; stdcall; external BluetoothAPIs;
function BluetoothGATTGetDescriptors(hDevice: THandle;
  Characteristic: Pointer; DescriptorsBufferCount: Word;
  DescriptorsBuffer: Pointer;
  DescriptorsBufferActual: PWord; Flags: ULONG): HRESULT; stdcall; external BluetoothAPIs;
function BluetoothGATTGetCharacteristicValue(hDevice: THandle;
  Characteristic: Pointer;
  CharacteristicValueDataSize: ULONG;
  CharacteristicValue: PBTH_LE_GATT_CHARACTERISTIC_VALUE;
  CharacteristicValueSizeRequired: PWord;
  Flags: ULONG): HRESULT; stdcall; external BluetoothAPIs;
function BluetoothGATTSetCharacteristicValue(hDevice: THandle;
  Characteristic: Pointer;
  CharacteristicValue: PBTH_LE_GATT_CHARACTERISTIC_VALUE;
  ReliableWriteContext: ULONG_PTR;
  Flags: ULONG): HRESULT; stdcall; external BluetoothAPIs;
function BluetoothGATTSetDescriptorValue(hDevice: THandle;
  Descriptor: Pointer;
  DescriptorValue: PBTH_LE_GATT_CHARACTERISTIC_VALUE;
  Flags: ULONG): HRESULT; stdcall; external BluetoothAPIs;
function BluetoothGATTRegisterEvent(hService: THandle;
  EventType: BTH_LE_GATT_EVENT_TYPE;
  EventParameterIn: Pointer;
  Callback: PFNBLUETOOTH_GATT_EVENT_CALLBACK;
  CallbackContext: Pointer;
  pEventHandle: PBLUETOOTH_GATT_EVENT_HANDLE;
  Flags: ULONG): HRESULT; stdcall; external BluetoothAPIs;
function BluetoothGATTUnregisterEvent(EventHandle: BLUETOOTH_GATT_EVENT_HANDLE;
  Flags: ULONG): HRESULT; stdcall; external BluetoothAPIs;

type
  TBthLeUuidInfo = record
    IsShortUuid: Boolean;
    ShortUuid: Word;
    LongUuid: TGUID;
    UuidString: string;
  end;

  TBthLeServiceInfo = record
    Uuid: TBthLeUuidInfo;
    AttributeHandle: Word;
    RawData: TRawBthLeGattService;
    ServiceDevicePath: string;  // Путь к сервису для открытия отдельного handle
    ServiceHandle: THandle;     // Handle сервиса для уведомлений
  end;
  TBthLeServiceInfoArray = array of TBthLeServiceInfo;

  TBthLeCharInfo = record
    ServiceHandle: Word;
    ServiceIndex: Integer;      // Индекс сервиса в массиве
    Uuid: TBthLeUuidInfo;
    AttributeHandle: Word;
    ValueHandle: Word;
    IsBroadcastable: Boolean;
    IsReadable: Boolean;
    IsWritable: Boolean;
    IsWritableWithoutResponse: Boolean;
    IsSignedWritable: Boolean;
    IsNotifiable: Boolean;
    IsIndicatable: Boolean;
    HasExtendedProperties: Boolean;
    RawData: TRawBthLeGattCharacteristic;
  end;
  TBthLeCharInfoArray = array of TBthLeCharInfo;

  TBthLeDescInfo = record
    ServiceHandle: Word;
    CharacteristicHandle: Word;
    DescriptorType: Word;
    Uuid: TBthLeUuidInfo;
    AttributeHandle: Word;
    RawData: TRawBthLeGattDescriptor;
  end;
  TBthLeDescInfoArray = array of TBthLeDescInfo;

function ParseBthLeUuid(const Raw: TRawBthLeUuid): TBthLeUuidInfo;
function ParseBthLeService(const Raw: TRawBthLeGattService): TBthLeServiceInfo;
function ParseBthLeCharacteristic(const Raw: TRawBthLeGattCharacteristic): TBthLeCharInfo;
function ParseBthLeDescriptor(const Raw: TRawBthLeGattDescriptor): TBthLeDescInfo;
function UuidToString(const Uuid: TBthLeUuidInfo): string;

implementation

function ParseBthLeUuid(const Raw: TRawBthLeUuid): TBthLeUuidInfo;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.IsShortUuid := (Raw[0] <> 0);

  if Result.IsShortUuid then
  begin
    Result.ShortUuid := Raw[4] or (Raw[5] shl 8);
    Result.LongUuid.D1 := Result.ShortUuid;
    Result.LongUuid.D2 := $0000;
    Result.LongUuid.D3 := $1000;
    Result.LongUuid.D4[0] := $80;
    Result.LongUuid.D4[1] := $00;
    Result.LongUuid.D4[2] := $00;
    Result.LongUuid.D4[3] := $80;
    Result.LongUuid.D4[4] := $5F;
    Result.LongUuid.D4[5] := $9B;
    Result.LongUuid.D4[6] := $34;
    Result.LongUuid.D4[7] := $FB;
  end
  else
  begin
    Result.LongUuid.D1 := Raw[4] or (Raw[5] shl 8) or (Raw[6] shl 16) or (Raw[7] shl 24);
    Result.LongUuid.D2 := Raw[8] or (Raw[9] shl 8);
    Result.LongUuid.D3 := Raw[10] or (Raw[11] shl 8);
    Move(Raw[12], Result.LongUuid.D4[0], 8);
  end;

  Result.UuidString := UuidToString(Result);
end;

function ParseBthLeService(const Raw: TRawBthLeGattService): TBthLeServiceInfo;
var
  UuidRaw: TRawBthLeUuid;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.RawData := Raw;
  Move(Raw[0], UuidRaw[0], 20);
  Result.Uuid := ParseBthLeUuid(UuidRaw);
  Result.AttributeHandle := Raw[20] or (Raw[21] shl 8);
  Result.ServiceHandle := INVALID_HANDLE_VALUE;
end;

function ParseBthLeCharacteristic(const Raw: TRawBthLeGattCharacteristic): TBthLeCharInfo;
var
  UuidRaw: TRawBthLeUuid;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.RawData := Raw;
  Result.ServiceHandle := Raw[0] or (Raw[1] shl 8);
  Move(Raw[4], UuidRaw[0], 20);
  Result.Uuid := ParseBthLeUuid(UuidRaw);
  Result.AttributeHandle := Raw[24] or (Raw[25] shl 8);
  Result.ValueHandle := Raw[26] or (Raw[27] shl 8);
  Result.IsBroadcastable := (Raw[28] <> 0);
  Result.IsReadable := (Raw[29] <> 0);
  Result.IsWritable := (Raw[30] <> 0);
  Result.IsWritableWithoutResponse := (Raw[31] <> 0);
  Result.IsSignedWritable := (Raw[32] <> 0);
  Result.IsNotifiable := (Raw[33] <> 0);
  Result.IsIndicatable := (Raw[34] <> 0);
  Result.HasExtendedProperties := (Raw[35] <> 0);
  Result.ServiceIndex := -1;
end;

function ParseBthLeDescriptor(const Raw: TRawBthLeGattDescriptor): TBthLeDescInfo;
var
  UuidRaw: TRawBthLeUuid;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.RawData := Raw;
  Result.ServiceHandle := Raw[0] or (Raw[1] shl 8);
  Result.CharacteristicHandle := Raw[2] or (Raw[3] shl 8);
  Result.DescriptorType := Raw[4] or (Raw[5] shl 8);
  Move(Raw[8], UuidRaw[0], 20);
  Result.Uuid := ParseBthLeUuid(UuidRaw);
  Result.AttributeHandle := Raw[28] or (Raw[29] shl 8);
end;

function UuidToString(const Uuid: TBthLeUuidInfo): string;
begin
  with Uuid.LongUuid do
    Result := LowerCase(Format('%.8x-%.4x-%.4x-%.2x%.2x-%.2x%.2x%.2x%.2x%.2x%.2x', [
      D1, D2, D3, D4[0], D4[1], D4[2], D4[3], D4[4], D4[5], D4[6], D4[7]]));
end;

end.
