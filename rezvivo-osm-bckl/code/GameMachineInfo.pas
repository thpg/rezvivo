unit GameMachineInfo;
{$mode objfpc}{$H+}{$codepage UTF8}

interface

{ Collected once at startup, before a GL context is required. No WMI, external
  process or network request. Snapshots contain hardware models, not serials. }
function MachineInformation: string;
function MachineDiagnosticsSnapshot: string;
procedure SetMachineGraphicsInformation(const Value: string);
function FormatDiagnosticBytes(N: QWord): string;

implementation

uses Classes, SysUtils
  {$ifdef MSWINDOWS}, Windows, Registry{$endif};

var
  Collected: Boolean = False;
  HardwareInfo, GraphicsInfo: string;

function FormatDiagnosticBytes(N: QWord): string;
begin
  if N >= QWord(1024) * 1024 * 1024 then
    Result := Format('%.1f GiB', [N / (1024.0 * 1024.0 * 1024.0)])
  else if N >= QWord(1024) * 1024 then
    Result := Format('%.1f MiB', [N / (1024.0 * 1024.0)])
  else Result := UIntToStr(N) + ' B';
end;

function CleanValue(const Value: string): string;
var I: Integer;
begin
  Result := Trim(Copy(Value, 1, 512));
  for I := 1 to Length(Result) do
    if Ord(Result[I]) < 32 then Result[I] := ' ';
end;

{$ifdef MSWINDOWS}
type
  TMemoryStatusEx = record
    Length, MemoryLoad: DWORD;
    TotalPhys, AvailPhys, TotalPageFile, AvailPageFile: QWord;
    TotalVirtual, AvailVirtual, AvailExtendedVirtual: QWord;
  end;
  { SP_DEVINFO_DATA: DWORD, GUID, DWORD, ULONG_PTR; 32 bytes on Win64. }
  TDisplayDeviceInfo = record
    Size: DWORD;
    ClassGuid: TGUID;
    DevInst: DWORD;
    Reserved: PtrUInt;
  end;

function ReadMemoryStatus(var Status: TMemoryStatusEx): BOOL; stdcall;
  external 'kernel32.dll' name 'GlobalMemoryStatusEx';
function DisplayDeviceSet(ClassGuid: PGUID; Enumerator: PWideChar;
  Parent: HWND; Flags: DWORD): THandle; stdcall;
  external 'setupapi.dll' name 'SetupDiGetClassDevsW';
function NextDisplayDevice(Devices: THandle; Index: DWORD;
  var Info: TDisplayDeviceInfo): BOOL; stdcall;
  external 'setupapi.dll' name 'SetupDiEnumDeviceInfo';
function DisplayProperty(Devices: THandle; var Info: TDisplayDeviceInfo;
  PropertyId: DWORD; var DataType: DWORD; Buffer: PByte;
  BufferSize: DWORD; var RequiredSize: DWORD): BOOL; stdcall;
  external 'setupapi.dll' name 'SetupDiGetDeviceRegistryPropertyW';
function CloseDisplayDevices(Devices: THandle): BOOL; stdcall;
  external 'setupapi.dll' name 'SetupDiDestroyDeviceInfoList';

function RegistryString(const Key, Name: string): string;
var R: TRegistry;
begin
  Result := '';
  R := TRegistry.Create(KEY_READ or KEY_WOW64_64KEY);
  try
    try
      R.RootKey := HKEY_LOCAL_MACHINE;
      if R.OpenKeyReadOnly(Key) and R.ValueExists(Name) then
        Result := CleanValue(R.ReadString(Name));
    except Result := ''; end;
  finally R.Free; end;
end;

function DevicePropertyText(Devices: THandle; var Info: TDisplayDeviceInfo;
  PropertyId: DWORD): string;
var Buffer: array[0..2047] of WideChar; DataType, Required: DWORD;
begin
  Result := '';
  FillChar(Buffer, SizeOf(Buffer), 0);
  DataType := 0; Required := 0;
  if DisplayProperty(Devices, Info, PropertyId, DataType, PByte(@Buffer[0]),
    SizeOf(Buffer) - SizeOf(WideChar), Required) and
    (DataType in [REG_SZ, REG_EXPAND_SZ, REG_MULTI_SZ]) then
    { First hardware ID is the most specific VEN/DEV/SUBSYS/REV match.
      Do not query device instance IDs, location paths or serial numbers. }
    Result := CleanValue(UTF8Encode(UnicodeString(PWideChar(@Buffer[0]))));
end;

procedure CollectDisplayAdapters(Lines: TStrings);
const
  DisplayClass: TGUID = '{4D36E968-E325-11CE-BFC1-08002BE10318}';
  PresentDevices = $00000002;
  DeviceDescription = $00000000;
  HardwareId = $00000001;
  DriverKey = $00000009;
  FriendlyName = $0000000C;
var Devices: THandle; Info: TDisplayDeviceInfo; Index, Count: Integer;
  Name, Id, Key, Driver, Provider: string;
begin
  Devices := DisplayDeviceSet(@DisplayClass, nil, 0, PresentDevices);
  if Devices = INVALID_HANDLE_VALUE then begin
    Lines.Add('Display adapter enumeration unavailable: Win32 ' + IntToStr(GetLastError));
    Exit;
  end;
  Count := 0;
  try
    { Include present adapters even when they have no monitor attached. }
    for Index := 0 to 31 do begin
      FillChar(Info, SizeOf(Info), 0); Info.Size := SizeOf(Info);
      if not NextDisplayDevice(Devices, Index, Info) then begin
        if GetLastError <> ERROR_NO_MORE_ITEMS then
          Lines.Add('Display adapter enumeration incomplete: Win32 ' + IntToStr(GetLastError));
        Break;
      end;
      Inc(Count);
      Name := DevicePropertyText(Devices, Info, FriendlyName);
      if Name = '' then Name := DevicePropertyText(Devices, Info, DeviceDescription);
      Id := DevicePropertyText(Devices, Info, HardwareId);
      Lines.Add(Format('Display adapter %d: %s', [Index, Name]));
      if Id <> '' then Lines.Add('  Hardware ID: ' + Id);
      Key := DevicePropertyText(Devices, Info, DriverKey);
      if Key <> '' then begin
        Key := 'SYSTEM\CurrentControlSet\Control\Class\' + Key;
        Driver := RegistryString(Key, 'DriverVersion');
        Provider := RegistryString(Key, 'ProviderName');
        if Driver <> '' then Lines.Add('  Driver: ' + Driver + ' (' + Provider + ')');
        Driver := RegistryString(Key, 'DriverDate');
        if Driver <> '' then Lines.Add('  Driver date: ' + Driver);
      end;
    end;
    Lines.Add('Present display adapters: ' + IntToStr(Count));
  finally CloseDisplayDevices(Devices); end;
end;

procedure CollectWindowsInformation(Lines: TStrings);
const VersionKey = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion';
var SI: TSystemInfo; MS: TMemoryStatusEx; Name, Revision: string;
begin
  GetNativeSystemInfo(@SI);
  Name := RegistryString('HARDWARE\DESCRIPTION\System\CentralProcessor\0', 'ProcessorNameString');
  if Name = '' then Name := CleanValue(SysUtils.GetEnvironmentVariable('PROCESSOR_IDENTIFIER'));
  Lines.Add('CPU name: ' + Name);
  Lines.Add('CPU identifier: ' + CleanValue(SysUtils.GetEnvironmentVariable('PROCESSOR_IDENTIFIER')));
  Lines.Add(Format('CPU: %d logical, page=%d', [SI.dwNumberOfProcessors, SI.dwPageSize]));
  Revision := RegistryString(VersionKey, 'DisplayVersion');
  Name := RegistryString(VersionKey, 'CurrentBuildNumber');
  Lines.Add('Windows release: ' + Revision + ', build: ' + Name);
  FillChar(MS, SizeOf(MS), 0); MS.Length := SizeOf(MS);
  if ReadMemoryStatus(MS) then begin
    Lines.Add('RAM total: ' + FormatDiagnosticBytes(MS.TotalPhys) +
      '  avail at startup: ' + FormatDiagnosticBytes(MS.AvailPhys) +
      Format('  load=%d%%', [MS.MemoryLoad]));
    Lines.Add('Pagefile total: ' + FormatDiagnosticBytes(MS.TotalPageFile) +
      '  avail at startup: ' + FormatDiagnosticBytes(MS.AvailPageFile));
  end;
  CollectDisplayAdapters(Lines);
end;
{$endif}

function MachineInformation: string;
var Lines: TStringList;
begin
  if not Collected then begin
    Collected := True;
    Lines := TStringList.Create;
    try
      Lines.Add('Compiler: FPC ' + {$I %FPCVERSION%} + '; target: ' +
        {$I %FPCTARGETCPU%} + '-' + {$I %FPCTARGETOS%});
      try
        {$ifdef MSWINDOWS}CollectWindowsInformation(Lines);
        {$else}Lines.Add('Native hardware inventory unavailable on this platform.');{$endif}
      except
        on E: Exception do Lines.Add('Hardware inventory incomplete: ' + E.ClassName);
      end;
      HardwareInfo := Lines.Text;
    finally Lines.Free; end;
  end;
  Result := HardwareInfo;
end;

procedure SetMachineGraphicsInformation(const Value: string);
begin
  { GLInformationString is collected only while the context is current. Keep a
    bounded copy so crash handling never has to call a driver or query hardware. }
  GraphicsInfo := Copy(Value, 1, 48 * 1024);
  if Length(Value) > Length(GraphicsInfo) then
    GraphicsInfo := GraphicsInfo + LineEnding + '[Graphics information truncated]';
end;

function MachineDiagnosticsSnapshot: string;
begin
  { Ordinary startup populates the cache before installing the crash handler. }
  Result := MachineInformation + LineEnding;
  if GraphicsInfo <> '' then
    Result := Result + 'Active OpenGL context:' + LineEnding + GraphicsInfo
  else Result := Result + 'Active OpenGL context: not initialized';
end;

end.
