{ SimpleBLEProvider — BLE transport via cross-platform SimpleBLE library.

  Alternative to BLEManager.pas (Windows GATT API).
  Uses simpleble-c.dll / .dylib / .so — works on Windows, macOS, Linux.

  Advantages over Windows BLE API:
    - No '00 00' prefix artifact — clean characteristic values
    - No Windows thread pool callback crashes
    - Cross-platform
    - Simpler connect/notify API

  Usage:
    DeviceService.RegisterProvider(TSimpleBLEProvider.Create);
}
unit SimpleBLEProvider;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs,
  SimpleBle, TrainerData, GameTransportBase, FTMSProtocol;

type
  TSimpleBLESession = class;

  { ── Stored scan result for deferred connect ── }
  TScannedPeripheral = record
    Handle: TSimpleBlePeripheral;
    Address: string;
    Name: string;
  end;
  TScannedPeripheralArray = array of TScannedPeripheral;

  { ═══════════════════════════════════════════════════════════════════
    TSimpleBLESession — one BLE connection via SimpleBLE
    ═══════════════════════════════════════════════════════════════════ }

  TSimpleBLESession = class(TFTMSCapableSession)
  private
    FPeripheral: TSimpleBlePeripheral;
    FOwnsPeripheral: Boolean;
    FFTMSParser: TFTMSParser;

    { FHasFTMS now inherited from TFTMSCapableSession (protected). }
    FHasPower: Boolean;
    FHasFEC: Boolean;
    FHasHR: Boolean;
    FHasCSC: Boolean;

    { Service+Characteristic UUIDs for writing commands }
    FFTMSServiceUUID: TSimpleBleUuid;
    FFTMSControlUUID: TSimpleBleUuid;

    { Opaque registry token, not an address retained by the C library. }
    FCallbackToken: Pointer;
    FSubscriptions: array of record Service, Characteristic: TSimpleBleUuid; end;
    procedure ClearNotifications;

    procedure ProcessNotification(const CharUUID: string;
      Data: PByte; DataLen: NativeUInt);

    procedure ProcessFTMSData(const Buf: TBytes);
    procedure ProcessCyclingPowerData(const Buf: TBytes);
    procedure ProcessHRMData(const Buf: TBytes);
    procedure ProcessCSCData(const Buf: TBytes);

    function WriteCharacteristic(const SvcUUID, CharUUID: TSimpleBleUuid;
      const Data: TBytes; UseRequest: Boolean): Boolean;
  protected
    { Implements TFTMSCapableSession's abstract write — actually pushes
      bytes to the FTMS Control Point characteristic over SimpleBLE. }
    function WriteFTMSCommand(const Data: TBytes): Boolean; override;
  public
    constructor Create(const AAddress: string;
      const AFriendlyName: string = ''); override;
    destructor Destroy; override;

    { Assign peripheral handle obtained from scan }
    procedure SetPeripheral(AHandle: TSimpleBlePeripheral; AOwnsHandle: Boolean);

    function Connect: Boolean; override;
    procedure Disconnect; override;

    { RequestControl, SetTargetPower, SetResistanceLevel, SetIncline,
      SetSimulation, Start, Stop, Pause, Reset are inherited from
      TFTMSCapableSession — no overrides needed. }

    class function TransportType: TTransportType; override;
  end;

  { ═══════════════════════════════════════════════════════════════════
    TSimpleBLEProvider — scan + create sessions via SimpleBLE
    ═══════════════════════════════════════════════════════════════════ }

  TSimpleBLEProvider = class(TTransportProvider)
  private
    FAdapter: TSimpleBleAdapter;
    FAdapterValid: Boolean;
    FScanned: TScannedPeripheralArray;
    FScannedCount: Integer;
    FScanLock: TCriticalSection;
    FCallbackToken: Pointer;
    FStopScan: Boolean;
    procedure EnsureAdapter;
    procedure HandlePeripheralFound(APeripheral: TSimpleBlePeripheral);
    procedure HandlePeripheralUpdated(APeripheral: TSimpleBlePeripheral);
  public
    constructor Create; override;
    destructor Destroy; override;

    procedure StartScan; override;
    procedure StopScan; override;
    function CreateSession(const AAddress: string;
      const AFriendlyName: string = ''): TTransportSession; override;
    class function TransportType: TTransportType; override;
  end;

{ Try to load simpleble-c library. Returns True if available. }
function SimpleBLEAvailable: Boolean;

implementation

uses
  Math, StrUtils, DynLibs, DebugLog, GameTrainerControl, GameCallbackRegistry;

var
  GSimpleBLEChecked: Boolean = False;
  GSimpleBLELoaded: Boolean = False;

function SimpleBLEAvailable: Boolean;
const
  { C API wrapper DLLs (export simpleble_* functions) }
  KnownDLLs: array[0..1] of string = (
    'simplecble.dll', 'simpleble-c.dll'
  );
  { C++ backend DLLs (loaded by wrapper automatically) }
  BackendDLLs: array[0..1] of string = (
    'simpleble.dll', 'fmt.dll'
  );

  function CheckPEBitness(const APath: string): string;
  var
    F: file of Byte;
    PEOffset: Cardinal;
    Machine: Word;
    Buf: array[0..3] of Byte;
  begin
    Result := '?';
    if not FileExists(APath) then Exit;
    try
      AssignFile(F, APath);
      FileMode := fmOpenRead;
      {$I-} Reset(F); {$I+}
      if IOResult <> 0 then Exit;
      try
        if FileSize(F) < 128 then begin Result := 'too small'; Exit; end;
        { Read PE offset at 0x3C }
        Seek(F, $3C);
        BlockRead(F, Buf, 4);
        PEOffset := Buf[0] or (Buf[1] shl 8) or (Buf[2] shl 16) or (Buf[3] shl 24);
        if PEOffset + 6 > FileSize(F) then begin Result := 'bad PE'; Exit; end;
        { Read PE signature + Machine }
        Seek(F, PEOffset);
        BlockRead(F, Buf, 4);
        if (Buf[0] <> Ord('P')) or (Buf[1] <> Ord('E')) then begin Result := 'not PE'; Exit; end;
        BlockRead(F, Buf, 2);
        Machine := Buf[0] or (Buf[1] shl 8);
        case Machine of
          $014C: Result := 'x86 (32-bit)';
          $8664: Result := 'x64 (64-bit)';
          $AA64: Result := 'ARM64';
        else
          Result := Format('machine=$%.4X', [Machine]);
        end;
      finally
        CloseFile(F);
      end;
    except
      Result := 'read error';
    end;
  end;

  function GetFileSize64(const APath: string): Int64;
  var SR: TSearchRec;
  begin
    Result := -1;
    if FindFirst(APath, faAnyFile, SR) = 0 then
    begin
      Result := SR.Size;
      FindClose(SR);
    end;
  end;

var
  ExeDir: string;
  I, MissingFunc: Integer;
  DLLPath, Bitness, ExeBitness: string;
  FSize: Int64;
  FoundDLL: string;
  TestLib: TLibHandle;
  TestProc: Pointer;

  procedure CheckFunc(const Name: string; Ptr: Pointer);
  begin
    if Ptr = nil then
    begin
      Logger.Warning('[SimpleBLE]   MISSING: ' + Name);
      Inc(MissingFunc);
    end;
  end;

begin
  if not GSimpleBLEChecked then
  begin
    GSimpleBLEChecked := True;
    ExeDir := ExtractFilePath(ParamStr(0));

    Logger.Info('[SimpleBLE] ═══════ SimpleBLE availability check ═══════');
    Logger.Info('[SimpleBLE] Exe dir: ' + ExeDir);

    {$IFDEF CPU64}
    ExeBitness := 'x64 (64-bit)';
    {$ELSE}
    ExeBitness := 'x86 (32-bit)';
    {$ENDIF}
    Logger.Info('[SimpleBLE] Exe bitness: ' + ExeBitness);

    { Check for any known SimpleBLE DLL }
    FoundDLL := '';
    for I := 0 to High(KnownDLLs) do
    begin
      DLLPath := ExeDir + KnownDLLs[I];
      if FileExists(DLLPath) then
      begin
        FSize := GetFileSize64(DLLPath);
        Bitness := CheckPEBitness(DLLPath);
        Logger.Info(Format('[SimpleBLE]   %s: found (%d bytes, %s)',
          [KnownDLLs[I], FSize, Bitness]));
        if Bitness <> ExeBitness then
          Logger.Error(Format('[SimpleBLE]   BITNESS MISMATCH: %s is %s but exe is %s!',
            [KnownDLLs[I], Bitness, ExeBitness]));
        if FoundDLL = '' then
          FoundDLL := KnownDLLs[I];
      end;
    end;

    { Check backend DLLs (informational — loaded by C wrapper automatically) }
    for I := 0 to High(BackendDLLs) do
    begin
      DLLPath := ExeDir + BackendDLLs[I];
      if FileExists(DLLPath) then
      begin
        FSize := GetFileSize64(DLLPath);
        Bitness := CheckPEBitness(DLLPath);
        Logger.Info(Format('[SimpleBLE]   %s: found (%d bytes, %s)',
          [BackendDLLs[I], FSize, Bitness]));
      end;
    end;

    if FoundDLL = '' then
    begin
      Logger.Warning('[SimpleBLE] No C API wrapper DLL found — provider disabled');
      Logger.Info('[SimpleBLE] Need: simplecble.dll (new) or simpleble-c.dll (old) + simpleble.dll + fmt.dll');
      Logger.Info('[SimpleBLE] Build: cmake --build . --target simplecble (from github.com/simpleble/simpleble)');
      Logger.Info('[SimpleBLE] Or download old: github.com/eriklins/Pascal-Bindings-For-SimpleBLE-Library/releases');
      Logger.Info('[SimpleBLE] ═══════════════════════════════════════════');
      GSimpleBLELoaded := False;
    end
    else
    begin
      { Probe each C wrapper DLL individually to find one that exports our functions }
      try
        GSimpleBLELoaded := False;

        for I := 0 to High(KnownDLLs) do
        begin
          DLLPath := ExeDir + KnownDLLs[I];
          if not FileExists(DLLPath) then Continue;

          Logger.Info(Format('[SimpleBLE] Probing %s...', [KnownDLLs[I]]));

          TestLib := LoadLibrary(PChar(DLLPath));
          if TestLib = 0 then
          begin
            Logger.Warning(Format('[SimpleBLE]   LoadLibrary failed (error %d)', [GetLastOSError]));
            Continue;
          end;

          { Check for key export }
          TestProc := GetProcedureAddress(TestLib, 'simpleble_adapter_get_count');
          if TestProc <> nil then
          begin
            Logger.Info(Format('[SimpleBLE]   %s exports simpleble_adapter_get_count ✓',
              [KnownDLLs[I]]));
            Logger.Info('[SimpleBLE] Loading all exports manually (lenient)...');

            { Keep TestLib loaded — populate var pointers directly }
            pointer(SimpleBleAdapterIsBluetoothEnabled) := GetProcedureAddress(TestLib, 'simpleble_adapter_is_bluetooth_enabled');
            pointer(SimpleBleAdapterGetCount) := GetProcedureAddress(TestLib, 'simpleble_adapter_get_count');
            pointer(SimpleBleAdapterGetHandle) := GetProcedureAddress(TestLib, 'simpleble_adapter_get_handle');
            pointer(SimpleBleAdapterReleaseHandle) := GetProcedureAddress(TestLib, 'simpleble_adapter_release_handle');
            pointer(SimpleBleAdapterIdentifier) := GetProcedureAddress(TestLib, 'simpleble_adapter_identifier');
            pointer(SimpleBleAdapterAddress) := GetProcedureAddress(TestLib, 'simpleble_adapter_address');
            pointer(SimpleBleAdapterScanStart) := GetProcedureAddress(TestLib, 'simpleble_adapter_scan_start');
            pointer(SimpleBleAdapterScanStop) := GetProcedureAddress(TestLib, 'simpleble_adapter_scan_stop');
            pointer(SimpleBleAdapterScanIsActive) := GetProcedureAddress(TestLib, 'simpleble_adapter_scan_is_active');
            pointer(SimpleBleAdapterScanFor) := GetProcedureAddress(TestLib, 'simpleble_adapter_scan_for');
            pointer(SimpleBleAdapterScanGetResultsCount) := GetProcedureAddress(TestLib, 'simpleble_adapter_scan_get_results_count');
            pointer(SimpleBleAdapterScanGetResultsHandle) := GetProcedureAddress(TestLib, 'simpleble_adapter_scan_get_results_handle');
            pointer(SimpleBleAdapterGetPairedPeripheralsCount) := GetProcedureAddress(TestLib, 'simpleble_adapter_get_paired_peripherals_count');
            pointer(SimpleBleAdapterGetPairedPeripheralsHandle) := GetProcedureAddress(TestLib, 'simpleble_adapter_get_paired_peripherals_handle');
            pointer(SimpleBleAdapterSetCallbackOnScanStart) := GetProcedureAddress(TestLib, 'simpleble_adapter_set_callback_on_scan_start');
            pointer(SimpleBleAdapterSetCallbackOnScanStop) := GetProcedureAddress(TestLib, 'simpleble_adapter_set_callback_on_scan_stop');
            pointer(SimpleBleAdapterSetCallbackOnScanUpdated) := GetProcedureAddress(TestLib, 'simpleble_adapter_set_callback_on_scan_updated');
            pointer(SimpleBleAdapterSetCallbackOnScanFound) := GetProcedureAddress(TestLib, 'simpleble_adapter_set_callback_on_scan_found');
            pointer(SimpleBlePeripheralReleaseHandle) := GetProcedureAddress(TestLib, 'simpleble_peripheral_release_handle');
            pointer(SimpleBlePeripheralIdentifier) := GetProcedureAddress(TestLib, 'simpleble_peripheral_identifier');
            pointer(SimpleBlePeripheralAddress) := GetProcedureAddress(TestLib, 'simpleble_peripheral_address');
            pointer(SimpleBlePeripheralAddressType) := GetProcedureAddress(TestLib, 'simpleble_peripheral_address_type');
            pointer(SimpleBlePeripheralRssi) := GetProcedureAddress(TestLib, 'simpleble_peripheral_rssi');
            pointer(SimpleBlePeripheralTxPower) := GetProcedureAddress(TestLib, 'simpleble_peripheral_tx_power');
            pointer(SimpleBlePeripheralMtu) := GetProcedureAddress(TestLib, 'simpleble_peripheral_mtu');
            pointer(SimpleBlePeripheralConnect) := GetProcedureAddress(TestLib, 'simpleble_peripheral_connect');
            pointer(SimpleBlePeripheralDisconnect) := GetProcedureAddress(TestLib, 'simpleble_peripheral_disconnect');
            pointer(SimpleBlePeripheralIsConnected) := GetProcedureAddress(TestLib, 'simpleble_peripheral_is_connected');
            pointer(SimpleBlePeripheralIsConnectable) := GetProcedureAddress(TestLib, 'simpleble_peripheral_is_connectable');
            pointer(SimpleBlePeripheralIsPaired) := GetProcedureAddress(TestLib, 'simpleble_peripheral_is_paired');
            pointer(SimpleBlePeripheralUnpair) := GetProcedureAddress(TestLib, 'simpleble_peripheral_unpair');
            pointer(SimpleBlePeripheralServicesCount) := GetProcedureAddress(TestLib, 'simpleble_peripheral_services_count');
            pointer(SimpleBlePeripheralServicesGet) := GetProcedureAddress(TestLib, 'simpleble_peripheral_services_get');
            pointer(SimpleBlePeripheralManufacturerDataCount) := GetProcedureAddress(TestLib, 'simpleble_peripheral_manufacturer_data_count');
            pointer(SimpleBlePeripheralManufacturerDataGet) := GetProcedureAddress(TestLib, 'simpleble_peripheral_manufacturer_data_get');
            pointer(SimpleBlePeripheralRead) := GetProcedureAddress(TestLib, 'simpleble_peripheral_read');
            pointer(SimpleBlePeripheralWriteRequest) := GetProcedureAddress(TestLib, 'simpleble_peripheral_write_request');
            pointer(SimpleBlePeripheralWriteCommand) := GetProcedureAddress(TestLib, 'simpleble_peripheral_write_command');
            pointer(SimpleBlePeripheralNotify) := GetProcedureAddress(TestLib, 'simpleble_peripheral_notify');
            pointer(SimpleBlePeripheralIndicate) := GetProcedureAddress(TestLib, 'simpleble_peripheral_indicate');
            pointer(SimpleBlePeripheralUnsubscribe) := GetProcedureAddress(TestLib, 'simpleble_peripheral_unsubscribe');
            pointer(SimpleBlePeripheralReadDescriptor) := GetProcedureAddress(TestLib, 'simpleble_peripheral_read_descriptor');
            pointer(SimpleBlePeripheralWriteDescriptor) := GetProcedureAddress(TestLib, 'simpleble_peripheral_write_descriptor');
            pointer(SimpleBlePeripheralSetCallbackOnConnected) := GetProcedureAddress(TestLib, 'simpleble_peripheral_set_callback_on_connected');
            pointer(SimpleBlePeripheralSetCallbackOnDisconnected) := GetProcedureAddress(TestLib, 'simpleble_peripheral_set_callback_on_disconnected');
            pointer(SimpleBleFree) := GetProcedureAddress(TestLib, 'simpleble_free');
            pointer(SimpleBleLoggingSetLevel) := GetProcedureAddress(TestLib, 'simpleble_logging_set_level');
            pointer(SimpleBleloggingSetCallback) := GetProcedureAddress(TestLib, 'simpleble_logging_set_callback');

            { Check core functions }
            MissingFunc := 0;
            CheckFunc('adapter_get_count', pointer(SimpleBleAdapterGetCount));
            CheckFunc('peripheral_connect', pointer(SimpleBlePeripheralConnect));
            CheckFunc('peripheral_services_get', pointer(SimpleBlePeripheralServicesGet));
            CheckFunc('peripheral_notify', pointer(SimpleBlePeripheralNotify));
            CheckFunc('simpleble_free', pointer(SimpleBleFree));

            if MissingFunc = 0 then
            begin
              GSimpleBLELoaded := True;
              Logger.Info('[SimpleBLE] Library loaded OK — manual lenient load');
            end else
              Logger.Warning(Format('[SimpleBLE] %d core exports missing', [MissingFunc]));
            Break;
          end
          else
          begin
            { Log what IS exported to diagnose }
            Logger.Warning(Format('[SimpleBLE]   %s: simpleble_adapter_get_count NOT found',
              [KnownDLLs[I]]));
            { Try common alternative names }
            TestProc := GetProcedureAddress(TestLib, '_simpleble_adapter_get_count');
            if TestProc <> nil then
              Logger.Info('[SimpleBLE]   Found with underscore prefix: _simpleble_adapter_get_count');
            TestProc := GetProcedureAddress(TestLib, 'simpleble_adapter_get_count@0');
            if TestProc <> nil then
              Logger.Info('[SimpleBLE]   Found with stdcall decoration: simpleble_adapter_get_count@0');
            UnloadLibrary(TestLib);
          end;
        end;

        if not GSimpleBLELoaded then
        begin
          MissingFunc := 0;
          CheckFunc('simpleble_adapter_get_count', pointer(SimpleBleAdapterGetCount));
          CheckFunc('simpleble_peripheral_connect', pointer(SimpleBlePeripheralConnect));
          CheckFunc('simpleble_free', pointer(SimpleBleFree));
          Logger.Warning(Format('[SimpleBLE] No working C API DLL found (%d core exports missing)',
            [MissingFunc]));
          Logger.Info('[SimpleBLE] The DLLs from the release may require matching versions');
        end;
      except
        on E: Exception do
        begin
          GSimpleBLELoaded := False;
          Logger.Error('[SimpleBLE] Load exception: ' + E.ClassName + ': ' + E.Message);
        end;
      end;
      Logger.Info('[SimpleBLE] ═══════════════════════════════════════════');
    end;
  end;
  Result := GSimpleBLELoaded;
end;

{ ── Helper: Pascal string → TSimpleBleUuid ── }

function MakeUUID(const S: string): TSimpleBleUuid;
var I: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  for I := 1 to Length(S) do
    if I < SIMPLEBLE_UUID_STR_LEN then
      Result.Value[I - 1] := S[I];
end;

function UUIDToStr(const U: TSimpleBleUuid): string;
begin
  Result := LowerCase(Trim(StrPas(@U.Value[0])));
end;

function ConsumeSimpleBLEString(P: PChar): string;
begin
  Result := '';
  if P = nil then Exit;
  try
    Result := StrPas(P);
  finally
    { identifier/address return malloc strings owned by the caller. Use the
      library allocator, never Pascal FreeMem or the address of P itself. }
    SimpleBleFree(P);
  end;
end;

procedure ReleaseScanPeripheral(Peripheral: TSimpleBlePeripheral);
begin
  { The C scan callback receives a fresh owned wrapper on every invocation,
    including updates and callbacks already queued when scanning stops. }
  if (Peripheral <> 0) and Assigned(SimpleBlePeripheralReleaseHandle) then
    try SimpleBlePeripheralReleaseHandle(Peripheral); except end;
end;

{ ── Global notification callback (cdecl) ── }

procedure GlobalNotifyCallback(Service: TSimpleBleUuid;
  Characteristic: TSimpleBleUuid; Data: PByte; DataLength: NativeUInt;
  UserData: PPointer); cdecl;
var
  Target:TObject; Gate:TTrainerCallbackGate;
begin
  Gate:=AcquireCallbackTarget(Pointer(UserData),Target);
  if Gate=nil then Exit;
  try
    try TSimpleBLESession(Target).ProcessNotification(UUIDToStr(Characteristic),Data,DataLength);
    except { No Pascal exceptions may cross a C callback. } end;
  finally Gate.Release;end;
end;

{ ═══════════════════════════════════════════════════════════════════
  TSimpleBLESession
  ═══════════════════════════════════════════════════════════════════ }

constructor TSimpleBLESession.Create(const AAddress: string;
  const AFriendlyName: string);
begin
  inherited Create(AAddress, AFriendlyName);
  FPeripheral := 0;
  FOwnsPeripheral := False;
  FFTMSParser := TFTMSParser.Create;
  FHasFTMS := False;
  FHasPower := False;
  FHasFEC := False;
  FHasHR := False;
  FHasCSC := False;
end;

destructor TSimpleBLESession.Destroy;
begin
  ShutdownControl;
  FDestroying := True;
  ClearNotifications;
  if FPeripheral <> 0 then
  begin
    try SimpleBlePeripheralDisconnect(FPeripheral); except end;
    if FOwnsPeripheral then
      SimpleBlePeripheralReleaseHandle(FPeripheral);
  end;
  FreeAndNil(FFTMSParser);
  inherited;
end;

procedure TSimpleBLESession.ClearNotifications;
var I:Integer;
begin
  UnregisterCallbackTarget(FCallbackToken);
  if (FPeripheral<>0) and Assigned(SimpleBlePeripheralUnsubscribe) then
    for I:=0 to High(FSubscriptions) do
      try SimpleBlePeripheralUnsubscribe(FPeripheral,FSubscriptions[I].Service,
        FSubscriptions[I].Characteristic);except end;
  SetLength(FSubscriptions,0);
end;

procedure TSimpleBLESession.SetPeripheral(AHandle: TSimpleBlePeripheral;
  AOwnsHandle: Boolean);
begin
  FPeripheral := AHandle;
  FOwnsPeripheral := AOwnsHandle;
end;

class function TSimpleBLESession.TransportType: TTransportType;
begin
  Result := ttBLE;
end;

{ ── Connect: discover services, subscribe to notifications ── }

function TSimpleBLESession.Connect: Boolean;
var
  SvcCount, ChCount: NativeUInt;
  I, J, N: Integer;
  Svc: TSimpleBleService;
  SvcStr, ChStr: string;
  Err: TSimpleBleErr;
  Props: string;
  DeviceName: string;
  ConnAttempt: Integer;
  HasUsefulService: Boolean;
  ControlReady:Boolean;
begin
  Result := False;
  if FDestroying then Exit;
  ClearNotifications;
  FHasFTMS:=False;FHasPower:=False;FHasFEC:=False;FHasHR:=False;FHasCSC:=False;
  FillChar(FFTMSServiceUUID,SizeOf(FFTMSServiceUUID),0);
  FillChar(FFTMSControlUUID,SizeOf(FFTMSControlUUID),0);
  ControlReady:=False;
  if FPeripheral = 0 then
  begin
    Logger.Error('[SimpleBLE] Connect: peripheral handle is 0');
    Exit;
  end;

  Logger.Info(Format('[SimpleBLE] Connecting to %s (%s)...',
    [FDeviceInfo.Name, FDeviceInfo.Address]));
  SetConnectionState(csConnecting, 'Connecting...');

  { ── Connect with WinRT service cache workaround ──
    WinRT often returns incomplete GATT services on first connect (known issue).
    Workaround: connect → check → if incomplete → disconnect → reconnect.
    Second connect typically discovers all services. }

  HasUsefulService := False;

  for ConnAttempt := 1 to 3 do
  begin
    Logger.Info(Format('[SimpleBLE] Connect attempt %d/3...', [ConnAttempt]));

    Err := SimpleBlePeripheralConnect(FPeripheral);
    if Err <> SIMPLEBLE_SUCCESS then
    begin
      Logger.Error(Format('[SimpleBLE] Connect FAILED (err=%d)', [Ord(Err)]));
      if ConnAttempt = 3 then
      begin
        SetConnectionState(csError, 'Connect failed');
        Exit;
      end;
      Sleep(1000);
      Continue;
    end;

    { Wait for GATT discovery to complete }
    Sleep(1500);

    SvcCount := SimpleBlePeripheralServicesCount(FPeripheral);
    Logger.Info(Format('[SimpleBLE] Attempt %d: found %d services', [ConnAttempt, SvcCount]));

    { Check for useful services }
    for I := 0 to Integer(SvcCount) - 1 do
    begin
      if SimpleBlePeripheralServicesGet(FPeripheral, I, Svc) <> SIMPLEBLE_SUCCESS then Continue;
      SvcStr := LowerCase(UUIDToStr(Svc.Uuid));
      if (Pos('00001826', SvcStr) > 0) or  { FTMS }
         (Pos('00001818', SvcStr) > 0) or  { Cycling Power }
         (Pos('6e40fec1', SvcStr) > 0) or  { FE-C }
         (Pos('0000180d', SvcStr) > 0) or  { Heart Rate }
         (Pos('00001816', SvcStr) > 0) then { CSC }
      begin
        HasUsefulService := True;
        Break;
      end;
    end;

    if HasUsefulService then
    begin
      Logger.Info(Format('[SimpleBLE] Useful services found on attempt %d', [ConnAttempt]));
      Break;
    end;

    { Not found — disconnect and retry (clears WinRT cache) }
    if ConnAttempt < 3 then
    begin
      Logger.Warning('[SimpleBLE] No useful services — disconnecting to clear WinRT cache...');
      SimpleBlePeripheralDisconnect(FPeripheral);
      Sleep(2000);
    end else
      Logger.Warning('[SimpleBLE] No useful services after 3 attempts — proceeding anyway');
  end;

  { Re-read name — may now be available via GATT after connection }
  DeviceName := ConsumeSimpleBLEString(SimpleBlePeripheralIdentifier(FPeripheral));
  if DeviceName <> '' then
  begin
    FDeviceInfo.Name := DeviceName;
    Logger.Info('[SimpleBLE] Device name resolved: ' + FDeviceInfo.Name);
  end;

  { Enumerate all services and subscribe }
  FCallbackToken:=RegisterCallbackTarget(Self);
  Logger.Info(Format('[SimpleBLE] Enumerating %d services...', [SvcCount]));

  for I := 0 to Integer(SvcCount) - 1 do
  begin
    if SimpleBlePeripheralServicesGet(FPeripheral, I, Svc) <> SIMPLEBLE_SUCCESS then
      Continue;

    SvcStr := LowerCase(UUIDToStr(Svc.Uuid));
    Logger.Debug(Format('[SimpleBLE]   Service[%d]: %s (%d chars)',
      [I, SvcStr, Svc.CharacteristicCount]));

    if Pos('00001826', SvcStr) > 0 then begin FHasFTMS := True; Logger.Info('[SimpleBLE]     → FTMS service detected'); end;
    if Pos('00001818', SvcStr) > 0 then begin FHasPower := True; Logger.Info('[SimpleBLE]     → Cycling Power service detected'); end;
    if Pos('6e40fec1', SvcStr) > 0 then begin FHasFEC := True; Logger.Info('[SimpleBLE]     → FE-C over BLE service detected'); end;
    if Pos('0000180d', SvcStr) > 0 then begin FHasHR := True; Logger.Info('[SimpleBLE]     → Heart Rate service detected'); end;
    if Pos('00001816', SvcStr) > 0 then begin FHasCSC := True; Logger.Info('[SimpleBLE]     → Cycling Speed & Cadence service detected'); end;

    { Subscribe to notifiable characteristics }
    ChCount := Svc.CharacteristicCount;
    if ChCount > NativeUInt(Length(Svc.Characteristics)) then
      ChCount := Length(Svc.Characteristics);
    for J := 0 to Integer(ChCount) - 1 do
    begin
      ChStr := LowerCase(UUIDToStr(Svc.Characteristics[J].Uuid));

      Props := '';
      if Svc.Characteristics[J].CanRead then Props := Props + 'R';
      if Svc.Characteristics[J].CanWriteRequest then Props := Props + 'W';
      if Svc.Characteristics[J].CanWriteCommand then Props := Props + 'w';
      if Svc.Characteristics[J].CanNotify then Props := Props + 'N';
      if Svc.Characteristics[J].CanIndicate then Props := Props + 'I';

      Logger.Debug(Format('[SimpleBLE]     Char[%d]: %s [%s]', [J, ChStr, Props]));

      if not Svc.Characteristics[J].CanNotify and
         not Svc.Characteristics[J].CanIndicate then Continue;

      { One subscription path for every supported measurement. In particular,
        FTMS Control Point is normally INDICATE-only, without CanNotify. }
      if not (ClassifyBLECharacteristic(ChStr) in [fctIndoorBikeData,
        fctCyclingPowerMeasurement,fctCSCMeasurement,fctHeartRateMeasurement,
        fctFitnessMachineCP]) then Continue;
      if Svc.Characteristics[J].CanIndicate and
         ((Pos('2ad9',ChStr)>0) or not Svc.Characteristics[J].CanNotify) and
         Assigned(SimpleBlePeripheralIndicate) then
        Err:=SimpleBlePeripheralIndicate(FPeripheral,Svc.Uuid,
          Svc.Characteristics[J].Uuid,TSimpleBleCallbackIndicate(@GlobalNotifyCallback),PPointer(FCallbackToken))
      else if Svc.Characteristics[J].CanNotify then
        Err:=SimpleBlePeripheralNotify(FPeripheral,Svc.Uuid,
          Svc.Characteristics[J].Uuid,TSimpleBleCallbackNotify(@GlobalNotifyCallback),PPointer(FCallbackToken))
      else Continue;
      if Err=SIMPLEBLE_SUCCESS then begin
        N:=Length(FSubscriptions);SetLength(FSubscriptions,N+1);
        FSubscriptions[N].Service:=Svc.Uuid;
        FSubscriptions[N].Characteristic:=Svc.Characteristics[J].Uuid;
        if (Pos('2ad9',ChStr)>0) and Svc.Characteristics[J].CanWriteRequest then begin
          FFTMSServiceUUID:=Svc.Uuid;FFTMSControlUUID:=Svc.Characteristics[J].Uuid;
          ControlReady:=True;
        end;
      end;
      Logger.Debug(Format('[SimpleBLE] Subscribe %s: %s',
        [ChStr,IfThen(Err=SIMPLEBLE_SUCCESS,'OK','FAIL')]));
    end;
  end;

  FDeviceInfo.SupportsFTMS := FHasFTMS;
  FDeviceInfo.SupportsControl := ControlReady;
  FDeviceInfo.SupportsPower := FHasPower or FHasFTMS;
  FDeviceInfo.SupportsCadence := FHasFTMS or FHasCSC or FHasPower;
  FDeviceInfo.SupportsHeartRate := FHasHR;
  FDeviceInfo.TransportType := ttBLE;
  FDeviceInfo.ProviderName := 'SimpleBLE';

  Logger.Info(Format('[SimpleBLE] Device caps: FTMS=%s Power=%s Cadence=%s HR=%s FEC=%s CSC=%s', [
    BoolToStr(FHasFTMS, True), BoolToStr(FDeviceInfo.SupportsPower, True),
    BoolToStr(FDeviceInfo.SupportsCadence, True), BoolToStr(FHasHR, True),
    BoolToStr(FHasFEC, True), BoolToStr(FHasCSC, True)]));

  FTrainerFeatures := Default(TTrainerFeatures);
  FTrainerFeatures.SupportsPowerControl := ControlReady;
  FTrainerFeatures.SupportsResistanceControl := ControlReady;
  FTrainerFeatures.SupportsInclineControl := ControlReady;
  FTrainerFeatures.SupportsSimulation := ControlReady;
  { The inherited command path uses FHasFTMS as writable control capability;
    merely advertising the service is insufficient without its ACK channel. }
  FHasFTMS := ControlReady;

  SetConnectionState(csConnected, 'Connected');
  Logger.Info('[SimpleBLE] Connection complete');
  Result := True;
end;

procedure TSimpleBLESession.Disconnect;
begin
  CancelControl;
  ClearNotifications;
  FHasFTMS := False;
  Logger.Info(Format('[SimpleBLE] Disconnecting %s...', [FDeviceInfo.Name]));
  if FPeripheral <> 0 then
    SimpleBlePeripheralDisconnect(FPeripheral);

  FHasControl := False;
  FLastData := Default(TTrainerDataRecord);
  FTrainerFeatures := Default(TTrainerFeatures);

  if not FDestroying then
    SetConnectionState(csDisconnected, 'Disconnected');
  Logger.Info('[SimpleBLE] Disconnected');
end;

{ ── Notification routing ── }

procedure TSimpleBLESession.ProcessNotification(const CharUUID: string;
  Data: PByte; DataLen: NativeUInt);
var
  Buf: TBytes;
  HexStr: string;
  I: Integer;
begin
  if FDestroying then Exit;
  if (Data = nil) or (DataLen = 0) or (DataLen > 65535) then Exit;

  SetLength(Buf, DataLen);
  Move(Data^, Buf[0], DataLen);

  HexStr := '';
  for I := 0 to Min(Integer(DataLen) - 1, 15) do
    HexStr := HexStr + IntToHex(Buf[I], 2) + ' ';

  Logger.Debug(Format('[SimpleBLE] Notify %s: %d bytes: %s',
    [Copy(CharUUID, 1, 8), DataLen, HexStr]));

  { No '00 00' prefix stripping needed — SimpleBLE returns clean values }

  case ClassifyBLECharacteristic(CharUUID) of
    fctIndoorBikeData:          ProcessFTMSData(Buf);
    fctCyclingPowerMeasurement: ProcessCyclingPowerData(Buf);
    fctCSCMeasurement:          ProcessCSCData(Buf);
    fctHeartRateMeasurement:    ProcessHRMData(Buf);
    fctFitnessMachineCP:
      ReceiveControlPoint(Buf);
  end;
end;

procedure TSimpleBLESession.ProcessFTMSData(const Buf: TBytes);
var
  ParsedData: TTrainerDataRecord;
begin
  ParsedData := FFTMSParser.ParseIndoorBikeData(Buf);
  if not FFTMSParser.LastPacketValid then Exit;
  FLastData := ParsedData;
  Logger.Debug(Format('[SimpleBLE] FTMS: Power=%d Cadence=%d Speed=%.1f',
    [FLastData.InstantPower, FLastData.InstantCadence, FLastData.InstantSpeed]));
  NotifyDataReceived;
end;

procedure TSimpleBLESession.ProcessCyclingPowerData(const Buf: TBytes);
var
  ParsedData: TTrainerDataRecord;
begin
  if Length(Buf) < 4 then Exit;
  ParsedData := FFTMSParser.ParseCyclingPowerMeasurement(Buf);
  if not FFTMSParser.LastPacketValid then Exit;
  FLastData := ParsedData;
  Logger.Debug(Format('[SimpleBLE] CycPwr: Power=%d Cadence=%d',
    [FLastData.InstantPower, FLastData.InstantCadence]));
  NotifyDataReceived;
end;

procedure TSimpleBLESession.ProcessCSCData(const Buf: TBytes);
var
  ParsedData: TTrainerDataRecord;
begin
  if Length(Buf) < 1 then Exit;
  ParsedData := FFTMSParser.ParseCSCMeasurement(Buf);
  if not FFTMSParser.LastPacketValid then Exit;
  FLastData := ParsedData;
  Logger.Debug(Format('[SimpleBLE] CSC: Cadence=%d', [FLastData.InstantCadence]));
  NotifyDataReceived;
end;

procedure TSimpleBLESession.ProcessHRMData(const Buf: TBytes);
var
  Flags: Byte;
  HR: Word;
  Offset: Integer;
begin
  if Length(Buf) < 2 then Exit;

  Offset := 0;
  Flags := Buf[0];
  Inc(Offset);

  if (Flags and $01) = 0 then
  begin
    HR := Buf[Offset];
    Inc(Offset);
  end
  else
  begin
    if Length(Buf) < 3 then Exit;
    HR := Buf[Offset] or (Buf[Offset + 1] shl 8);
    Inc(Offset, 2);
  end;

  if (HR > 0) and (HR <= 250) then
    FLastData.HeartRate := HR;
  FLastData.Timestamp := Now;

  Logger.Debug(Format('[SimpleBLE] HRM: HR=%d flags=$%.2X', [FLastData.HeartRate, Flags]));
  NotifyDataReceived;
end;

{ ── Write helper ── }

function TSimpleBLESession.WriteCharacteristic(
  const SvcUUID, CharUUID: TSimpleBleUuid;
  const Data: TBytes; UseRequest: Boolean): Boolean;
var
  Err: TSimpleBleErr;
begin
  Result := False;
  if FPeripheral = 0 then Exit;
  if Length(Data) = 0 then Exit;

  if UseRequest then
    Err := SimpleBlePeripheralWriteRequest(FPeripheral,
      SvcUUID, CharUUID, @Data[0], Length(Data))
  else
    Err := SimpleBlePeripheralWriteCommand(FPeripheral,
      SvcUUID, CharUUID, @Data[0], Length(Data));

  Result := Err = SIMPLEBLE_SUCCESS;
  Logger.Debug(Format('[SimpleBLE] Write %s %s: %d bytes → %s',
    [IfThen(UseRequest, 'req', 'cmd'),
     Copy(UUIDToStr(CharUUID), 1, 8), Length(Data),
     IfThen(Result, 'OK', 'FAIL')]));
end;

function TSimpleBLESession.WriteFTMSCommand(const Data: TBytes): Boolean;
begin
  Result := WriteCharacteristic(FFTMSServiceUUID, FFTMSControlUUID, Data, True);
end;

{ Trainer control methods (RequestControl, SetTargetPower, SetResistanceLevel,
  SetIncline, SetSimulation, Start, Stop, Pause, Reset) are inherited from
  TFTMSCapableSession in FTMSProtocol.pas — they all dispatch through
  WriteFTMSCommand above. }

{ ═══════════════════════════════════════════════════════════════════
  TSimpleBLEProvider
  ═══════════════════════════════════════════════════════════════════ }

constructor TSimpleBLEProvider.Create;
begin
  inherited;
  FAdapter := 0;
  FAdapterValid := False;
  FScannedCount := 0;
  FScanLock := TCriticalSection.Create;
  FCallbackToken:=RegisterCallbackTarget(Self);
end;

destructor TSimpleBLEProvider.Destroy;
var I: Integer;
begin
  UnregisterCallbackTarget(FCallbackToken);
  StopScan;
  for I := 0 to FScannedCount - 1 do
    if FScanned[I].Handle <> 0 then
      SimpleBlePeripheralReleaseHandle(FScanned[I].Handle);
  SetLength(FScanned, 0);

  if FAdapterValid then
    SimpleBleAdapterReleaseHandle(FAdapter);

  FreeAndNil(FScanLock);
  inherited;
end;

{ ── Global scan callbacks (cdecl, called from SimpleBLE thread) ── }

procedure GlobalScanFoundCallback(Adapter: TSimpleBleAdapter;
  Peripheral: TSimpleBlePeripheral; UserData: PPointer); cdecl;
var Target:TObject;Gate:TTrainerCallbackGate;
begin
  Gate:=AcquireCallbackTarget(Pointer(UserData),Target);
  if Gate=nil then begin ReleaseScanPeripheral(Peripheral);Exit;end;
  try
    try TSimpleBLEProvider(Target).HandlePeripheralFound(Peripheral);except end;
  finally Gate.Release;end;
end;

procedure GlobalScanUpdatedCallback(Adapter: TSimpleBleAdapter;
  Peripheral: TSimpleBlePeripheral; UserData: PPointer); cdecl;
var Target:TObject;Gate:TTrainerCallbackGate;
begin
  Gate:=AcquireCallbackTarget(Pointer(UserData),Target);
  if Gate=nil then begin ReleaseScanPeripheral(Peripheral);Exit;end;
  try
    try TSimpleBLEProvider(Target).HandlePeripheralUpdated(Peripheral);except end;
  finally Gate.Release;end;
end;

{ ── Scan callback handlers ── }

procedure TSimpleBLEProvider.HandlePeripheralFound(APeripheral: TSimpleBlePeripheral);
var
  Name, Addr: string;
  I: Integer;
begin
  try
  Name := ConsumeSimpleBLEString(SimpleBlePeripheralIdentifier(APeripheral));
  Addr := ConsumeSimpleBLEString(SimpleBlePeripheralAddress(APeripheral));
  if Addr = '' then Exit;

  Logger.Debug(Format('[SimpleBLE] ScanFound: "%s" %s', [Name, Addr]));

  { Store in scan list }
  FScanLock.Enter;
  try
    for I := 0 to FScannedCount - 1 do
      if SameText(FScanned[I].Address, Addr) then
      begin
        if Name <> '' then FScanned[I].Name := Name;
        if FScanned[I].Handle = 0 then
        begin
          FScanned[I].Handle := APeripheral;
          APeripheral := 0;
        end;
        Exit;
      end;
    if FScannedCount >= Length(FScanned) then
      SetLength(FScanned, FScannedCount + 8);
    FScanned[FScannedCount].Handle := APeripheral;
    FScanned[FScannedCount].Name := Name;
    FScanned[FScannedCount].Address := Addr;
    Inc(FScannedCount);
    APeripheral := 0; { Ownership transferred to FScanned/CreateSession. }
  finally
    FScanLock.Leave;
  end;
  finally ReleaseScanPeripheral(APeripheral);end;
end;

procedure TSimpleBLEProvider.HandlePeripheralUpdated(APeripheral: TSimpleBlePeripheral);
var
  Name, Addr: string;
  I: Integer;
begin
  try
  Name := ConsumeSimpleBLEString(SimpleBlePeripheralIdentifier(APeripheral));
  Addr := ConsumeSimpleBLEString(SimpleBlePeripheralAddress(APeripheral));

  if Name = '' then Exit;  { no new info }

  Logger.Debug(Format('[SimpleBLE] ScanUpdated: "%s" %s', [Name, Addr]));

  { Update name in existing entry }
  FScanLock.Enter;
  try
    for I := 0 to FScannedCount - 1 do
      if SameText(FScanned[I].Address, Addr) then
      begin
        if FScanned[I].Name = '' then
          Logger.Info(Format('[SimpleBLE] Name resolved via scan response: %s → %s', [Addr, Name]));
        FScanned[I].Name := Name;
        Exit;
      end;
  finally
    FScanLock.Leave;
  end;
  finally ReleaseScanPeripheral(APeripheral);end;
end;

procedure TSimpleBLEProvider.EnsureAdapter;
var
  AdapterCount: NativeUInt;
begin
  if FAdapterValid then Exit;

  AdapterCount := SimpleBleAdapterGetCount();
  Logger.Info(Format('[SimpleBLE] Bluetooth adapters found: %d', [AdapterCount]));

  if AdapterCount = 0 then
  begin
    Logger.Error('[SimpleBLE] No Bluetooth adapter found');
    Exit;
  end;

  FAdapter := SimpleBleAdapterGetHandle(0);
  FAdapterValid := FAdapter <> 0;

  if FAdapterValid then
    Logger.Info(Format('[SimpleBLE] Adapter handle acquired: $%p', [Pointer(FAdapter)]))
  else
    Logger.Error('[SimpleBLE] Failed to get adapter handle');
end;

class function TSimpleBLEProvider.TransportType: TTransportType;
begin
  Result := ttBLE;
end;

procedure TSimpleBLEProvider.StartScan;
var
  I, Reported, Elapsed: Integer;
  DevInfo: TDeviceInfo;
  Connectable: Boolean;
const
  SCAN_WINDOW_MS = 10000;
  POLL_INTERVAL_MS = 500;

  procedure ReportNewDevices;
  var J: Integer;
  begin
    FScanLock.Enter;
    try
      for J := Reported to FScannedCount - 1 do
      begin
        Connectable := False;
        if FScanned[J].Handle <> 0 then
          SimpleBlePeripheralIsConnectable(FScanned[J].Handle, Connectable);
        if not Connectable then Continue;

        DevInfo := Default(TDeviceInfo);
        if FScanned[J].Name <> '' then
          DevInfo.Name := FScanned[J].Name
        else
          DevInfo.Name := 'BLE ' + FScanned[J].Address;
        DevInfo.Address := FScanned[J].Address;
        DevInfo.TransportType := ttBLE;
        DevInfo.ProviderName := 'SimpleBLE';
        DevInfo.RSSI := SimpleBlePeripheralRssi(FScanned[J].Handle);

        if Assigned(OnDeviceFound) then
          OnDeviceFound(DevInfo);
      end;
      Reported := FScannedCount;
    finally
      FScanLock.Leave;
    end;
  end;

begin
  EnsureAdapter;
  if not FAdapterValid then Exit;

  FStopScan := False;

  Logger.Info('[SimpleBLE] === CONTINUOUS SCAN START ===');

  while not FStopScan do
  begin
    FScanLock.Enter;
    try
      for I := 0 to FScannedCount - 1 do
        if FScanned[I].Handle <> 0 then
          SimpleBlePeripheralReleaseHandle(FScanned[I].Handle);
      FScannedCount := 0;
    finally
      FScanLock.Leave;
    end;

    SimpleBleAdapterSetCallbackOnScanFound(FAdapter,
      TSimpleBleCallbackScanFound(@GlobalScanFoundCallback), PPointer(FCallbackToken));
    SimpleBleAdapterSetCallbackOnScanUpdated(FAdapter,
      TSimpleBleCallbackScanUpdated(@GlobalScanUpdatedCallback), PPointer(FCallbackToken));

    SimpleBleAdapterScanStart(FAdapter);

    Reported := 0;
    Elapsed := 0;
    while (Elapsed < SCAN_WINDOW_MS) and (not FStopScan) do
    begin
      Sleep(POLL_INTERVAL_MS);
      Inc(Elapsed, POLL_INTERVAL_MS);
      ReportNewDevices;
    end;

    SimpleBleAdapterScanStop(FAdapter);
    ReportNewDevices;

    if not FStopScan then
      Sleep(1000);
  end;

  Logger.Info('[SimpleBLE] === CONTINUOUS SCAN STOP ===');
end;

procedure TSimpleBLEProvider.StopScan;
begin
  FStopScan := True;
  if FAdapterValid then
    SimpleBleAdapterScanStop(FAdapter);
end;

function TSimpleBLEProvider.CreateSession(const AAddress: string;
  const AFriendlyName: string): TTransportSession;
var
  I: Integer;
  Session: TSimpleBLESession;
begin
  Result := nil;
  Logger.Info(Format('[SimpleBLE] CreateSession: addr=%s name=%s',
    [AAddress, AFriendlyName]));

  Session := TSimpleBLESession.Create(AAddress, AFriendlyName);

  FScanLock.Enter;
  try
    for I:=0 to FScannedCount-1 do
      if (FScanned[I].Handle<>0) and SameText(FScanned[I].Address,AAddress) then begin
        Session.SetPeripheral(FScanned[I].Handle,True);
        FScanned[I].Handle:=0;Result:=Session;Exit;
      end;
  finally FScanLock.Leave;end;

  Logger.Warning('[SimpleBLE] No peripheral found for: ' + AAddress);
  Session.Free;
end;

end.
