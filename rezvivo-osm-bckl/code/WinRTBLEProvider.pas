{ WinRTBLEProvider — Pure Pascal WinRT BLE provider.
  Zero external DLL dependency. Uses WinRT COM APIs via combase.dll.
  Scans BLE without prior pairing. Connects via FromBluetoothAddressAsync → FromIdAsync.
  Attempts pairing for encrypted services. Cached fallback on AccessDenied.
  GATT discovery, notifications via ValueChanged.
  Note: some devices with encrypted GATT (e.g. HR monitors) may require
  WinBLE provider for full access due to WinRT desktop limitations.
}
unit WinRTBLEProvider;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs,
  TrainerData, GameTransportBase, FTMSProtocol;

type
  TScannedDev = record Name, Address: string; RSSI: Int16; end;

  TPairOutcome = (poAlreadyPaired, poPaired, poFailed, poCannotPair);

  TBLESubscription = record
    CharHandle: Pointer;
    TokenValue: Int64;
    UserData: Pointer;  { callback gate, owned by DelegateHandle }
    DelegateHandle: Pointer; { our reference, separate from the event source }
  end;

  TWinRTBLESession = class(TFTMSCapableSession)
  private
    FDevice: Pointer;
    FFTMSParser: TFTMSParser;
    FHasPower, FHasFEC, FHasHR, FHasCSC: Boolean;
    FFTMSCtrlChar: Pointer;
    FFECWriteChar: Pointer;  { FE-C control write (6e40fec3) }
    FFECChannel: Byte;
    FGattSession: Pointer;
    FFactory: Pointer;    { IBluetoothLEDeviceStatics — kept for reconnect }
    FDeviceIdStr: NativeUInt; { HSTRING }
    FHasAccessDenied: Boolean;
    FSubs: array of TBLESubscription;
    FSubCount: Integer;
    FConnStatusToken: Int64;  { ConnectionStatusChanged event token }
    FConnStatusUD: Pointer;   { callback gate, owned by FConnStatusDel }
    FConnStatusDel: Pointer;  { PDelegate, released on disconnect }
    procedure DiscoverAndSubscribe;
    procedure CleanupSubscriptions;
    { IClosable.Close + Release на BLE-объектах. Без Close Windows
      держит GATT-слот радио до перезагрузки (~5–7 коннектов). }
    procedure ReleaseRadioResources;
    function TryPairDevice(Level: Integer): TPairOutcome;
    function TryUnpairDevice: Boolean;
    function ReopenDevice: Boolean;
  protected
    function WriteFTMSCommand(const Data: TBytes): Boolean; override;
  public
    BatteryLevel: Byte;  { 0..100%, updated via Battery Level notification }
    constructor Create(const AAddress: string; const AFriendlyName: string = ''); override;
    destructor Destroy; override;
    function Connect: Boolean; override;
    procedure Disconnect; override;
    function IsConnectionAlive: Boolean; override;
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
  end;

  TWinRTBLEProvider = class(TTransportProvider)
  private
    FScannedLock: TCriticalSection;
    FScanned: array of TScannedDev;
    FScannedCount: Integer;
    FLastReported: Integer;        { index of next device to report during scan }
    FScanStopping: Boolean;
  public
    constructor Create; override;
    destructor Destroy; override;
    procedure StartScan; override;
    procedure StopScan; override;
    function CreateSession(const AAddress: string;
      const AFriendlyName: string = ''): TTransportSession; override;
    class function TransportType: TTransportType; override;
    function AdapterDisplayName: string; override;
    function AdapterKey: string; override;
    procedure AddScanResult(const AName, AAddr: string; ARSSI: Int16);
    function PairDevice(const AAddress: string): Boolean;
  end;

function WinRTBLEAvailable: Boolean;

implementation

{$IFDEF WINDOWS}
uses
  Windows, DynLibs, Math, DebugLog, GameTrainerControl;

{ ═══════════════════════════════════════════════════════════════════
  WinRT COM base types
  ═══════════════════════════════════════════════════════════════════ }
type
  HSTRING = type NativeUInt;
  TEvtToken = record Value: Int64; end;
  PIUnk = Pointer;
  TVtSlots = array[0..63] of Pointer;
  PVtSlots = ^TVtSlots;

  { Vtable call function pointer types }
  TVtRelease = function(S: PIUnk): ULONG; stdcall;
  TVtQI = function(S: PIUnk; const riid: TGUID; out ppv: Pointer): HRESULT; stdcall;
  TVtGetHS = function(S: PIUnk; out V: HSTRING): HRESULT; stdcall;
  TVtGetU32 = function(S: PIUnk; out V: Cardinal): HRESULT; stdcall;
  TVtGetI16 = function(S: PIUnk; out V: Int16): HRESULT; stdcall;
  TVtGetU64 = function(S: PIUnk; out V: UInt64): HRESULT; stdcall;
  TVtGetObj = function(S: PIUnk; out V: PIUnk): HRESULT; stdcall;
  TVtGetGUID = function(S: PIUnk; out V: TGUID): HRESULT; stdcall;
  TVtGetPtr = function(S: PIUnk; out V: PByte): HRESULT; stdcall;
  TVtPutI = function(S: PIUnk; V: Integer): HRESULT; stdcall;
  TVtPutByte = function(S: PIUnk; V: Byte): HRESULT; stdcall;
  TVtGetByte = function(S: PIUnk; out V: Byte): HRESULT; stdcall;
  TVtNoArg = function(S: PIUnk): HRESULT; stdcall;
  TVtFromAddr = function(S: PIUnk; Addr: UInt64; out Op: PIUnk): HRESULT; stdcall;
  TVtFromId = function(S: PIUnk; Id: HSTRING; out Op: PIUnk): HRESULT; stdcall;
  TVtGetAt = function(S: PIUnk; Idx: Cardinal; out V: PIUnk): HRESULT; stdcall;
  TVtCallMode = function(S: PIUnk; Mode: Integer; out Op: PIUnk): HRESULT; stdcall;
  TVtCallMode2 = function(S: PIUnk; Mode1, Mode2: Integer; out Op: PIUnk): HRESULT; stdcall;
  TVtCallOut = function(S: PIUnk; out Op: PIUnk): HRESULT; stdcall;
  TVtWriteCCCD = function(S: PIUnk; Val: Cardinal; out Op: PIUnk): HRESULT; stdcall;
  TVtAddHandler = function(S: PIUnk; H: Pointer; out T: TEvtToken): HRESULT; stdcall;
  TVtRemHandler = function(S: PIUnk; T: TEvtToken): HRESULT; stdcall;
  TVtPutCompleted = function(S: PIUnk; H: PIUnk): HRESULT; stdcall;

  { COM delegate record }
  PDelegate = ^TDelegate;
  PDelegateVtbl = ^TDelegateVtbl;
  TDelegateVtbl = record
    QI, AddRef, Release, Invoke: Pointer;
  end;
  TDelegate = record
    Vtbl: PDelegateVtbl;
    VtblStorage: TDelegateVtbl;
    RefCount: Integer;
    IID: TGUID;
    UserData: Pointer;
    OwnedUserData: TObject;
  end;

  { Callback userdata records }
  PScanUD = ^TScanUD;
  TScanUD = record
    Prov: TWinRTBLEProvider;
  end;

  TNotifyContext = class(TTrainerCallbackGate)
  public
    SvcUUID: ShortString;   { no managed memory — safe for FreeMem }
    CharUUID: ShortString;
  end;

const
  IID_IClosable: TGUID = '{30D5A829-7FA4-4026-83BB-D75BAE4EA99E}';
  IID_IUnknown_: TGUID = '{00000000-0000-0000-C000-000000000046}';
  IID_IAgileObject: TGUID = '{94EA2B94-E9CC-49E0-C0FF-EE64CA8F5B90}';
  IID_IAsyncInfo: TGUID = '{00000036-0000-0000-C000-000000000046}';
  IID_ReceivedHandler: TGUID = '{90EB4ECA-D465-5EA0-A61C-033C8C5ECEF2}';
  IID_ValueChangedHandler: TGUID = '{C1F420F6-6292-5760-A2C9-9DDF98683CFC}';
  IID_IBufferByteAccess: TGUID = '{905A0FEF-BC53-11DF-8C49-001E4FC686DA}';
  IID_IDevice3: TGUID = '{AEE9E493-44AC-40DC-AF33-B2C13C01CA46}';
  IID_IDeviceStatics: TGUID = '{C8CF1A19-F0B6-4BF0-8689-41303DE2D9F4}';
  IID_ISvc3: TGUID = '{B293A950-0C53-437C-A9B3-5C3210C6E569}';
  IID_IGattSession: TGUID = '{D23B5143-E04E-4C24-999C-9C256F9856B1}';
  IID_IGattSessionStatics: TGUID = '{2E65B95C-539F-4DB7-82A8-73BDBBF73EBF}';
  IID_IDevice4: TGUID = '{2B605031-2248-4B2F-ACF0-7CEE36FC5870}';
  IID_ConnStatusHandler: TGUID = '{27F3E14F-1136-532E-8684-4E38081FEED4}'; { TypedEventHandler<BluetoothLEDevice, Object> }
  IID_IBluetoothDeviceIdStatics: TGUID = '{A7884E67-3EFB-4F31-BBC2-810E09977404}';
  IID_IDevice2: TGUID = '{26F062B3-7AEE-4D31-BABA-B1B9775F5916}';
  IID_IDeviceInfo2: TGUID = '{F156A638-7997-48D9-A10C-269D46533F48}';
  IID_IPairing: TGUID = '{2C4769F5-F684-40D5-8469-E8DBAAB70485}';
  IID_IPairing2: TGUID = '{F68612FD-0AEE-4328-85CC-1C742BB1790D}';
  IID_ICustomPairing: TGUID = '{85138C02-4EE6-4914-8370-107A39144C0E}';
  IID_PairingReqHandler: TGUID = '{FA65231F-4178-5DE1-B2CC-03E22D7702B4}';
  IID_IPairingReqArgs: TGUID = '{F717FC56-DE6B-487F-8376-0180ACA69963}';

  { IAsyncOperationCompletedHandler GUIDs }
  IID_CH_Device: TGUID = '{9156B79F-C54A-5277-8F8B-D2CC43C7E004}';
  IID_CH_SvcsResult: TGUID = '{74AB0892-A631-5D6C-B1B4-BD2E1A741A9B}';
  IID_CH_CharsResult: TGUID = '{D6A15475-1E72-5C56-98E8-88F4BC3E0313}';
  IID_CH_CommStatus: TGUID = '{2154117A-978D-59DB-99CF-6B690CB3389B}';

{ ═══════════════════════════════════════════════════════════════════
  combase.dll dynamic imports
  ═══════════════════════════════════════════════════════════════════ }
var
  hCB: TLibHandle = 0;
  _RoInit: function(T: Cardinal): HRESULT; stdcall = nil;
  _RoActivate: function(clsId: HSTRING; out inst: PIUnk): HRESULT; stdcall = nil;
  _RoGetFactory: function(clsId: HSTRING; const iid: TGUID; out fac: PIUnk): HRESULT; stdcall = nil;
  _HCreate: function(src: PWideChar; len: Cardinal; out s: HSTRING): HRESULT; stdcall = nil;
  _HDelete: function(s: HSTRING): HRESULT; stdcall = nil;
  _HGetBuf: function(s: HSTRING; out len: Cardinal): PWideChar; stdcall = nil;

function LoadCB: Boolean;
begin
  if hCB <> 0 then Exit(True);
  hCB := LoadLibrary('combase.dll');
  if hCB = 0 then Exit(False);
  Pointer(_RoInit) := GetProcedureAddress(hCB, 'RoInitialize');
  Pointer(_RoActivate) := GetProcedureAddress(hCB, 'RoActivateInstance');
  Pointer(_RoGetFactory) := GetProcedureAddress(hCB, 'RoGetActivationFactory');
  Pointer(_HCreate) := GetProcedureAddress(hCB, 'WindowsCreateString');
  Pointer(_HDelete) := GetProcedureAddress(hCB, 'WindowsDeleteString');
  Pointer(_HGetBuf) := GetProcedureAddress(hCB, 'WindowsGetStringRawBuffer');
  Result := Assigned(Pointer(_RoInit));
end;

{ ═══════════════════════════════════════════════════════════════════
  Helpers
  ═══════════════════════════════════════════════════════════════════ }

function VT(Obj: PIUnk): PVtSlots; inline;
begin
  Result := PVtSlots(PPointer(Obj)^);
end;

procedure SafeRelease(var P: PIUnk);
begin
  if P <> nil then
  begin
    TVtRelease(VT(P)^[2])(P);
    P := nil;
  end;
end;

function QI(Obj: PIUnk; const IID: TGUID; out R: PIUnk): HRESULT;
begin
  R := nil;
  if Obj = nil then Exit(E_POINTER);
  Result := TVtQI(VT(Obj)^[0])(Obj, IID, R);
end;

{ WinRT IClosable.Close (vtable[6] после IInspectable). Release без Close
  оставляет ACL/GATT сессию в стеке Bluetooth — после нескольких
  подключений радио перестаёт коннектиться до reboot. }
procedure SafeClose(var P: PIUnk);
var
  C: PIUnk;
begin
  if P = nil then Exit;
  C := nil;
  if QI(P, IID_IClosable, C) = S_OK then
  begin
    try
      TVtNoArg(VT(C)^[6])(C);
    except
    end;
    TVtRelease(VT(C)^[2])(C);
  end;
  TVtRelease(VT(P)^[2])(P);
  P := nil;
end;

function HS(const S: UnicodeString): HSTRING;
begin
  Result := 0;
  if S <> '' then _HCreate(PWideChar(S), Length(S), Result);
end;

function HSToStr(h: HSTRING): string;
var
  L: Cardinal;
  P: PWideChar;
begin
  Result := '';
  if (h = 0) or not Assigned(Pointer(_HGetBuf)) then Exit;
  P := _HGetBuf(h, L);
  if (P <> nil) and (L > 0) then
    Result := UTF8Encode(WideString(P));
end;

function MacToStr(A: UInt64): string;
begin
  Result := Format('%.2x:%.2x:%.2x:%.2x:%.2x:%.2x',
    [(A shr 40) and $FF, (A shr 32) and $FF, (A shr 24) and $FF,
     (A shr 16) and $FF, (A shr 8) and $FF, A and $FF]);
end;

function StrToMac(const S: string): UInt64;
var
  Parts: TStringArray;
  I: Integer;
begin
  Result := 0;
  Parts := S.Split([':']);
  if Length(Parts) <> 6 then Exit;
  for I := 0 to 5 do
    Result := (Result shl 8) or (StrToIntDef('$' + Parts[I], 0) and $FF);
end;

function GuidStr(const G: TGUID): string;
begin
  { D1 is Cardinal — values > $7FFFFFFF cause range error with Format(%x).
    Cast to QWord to avoid signed overflow with range checking enabled. }
  Result := LowerCase(Format('%.8x-%.4x-%.4x-%.2x%.2x-%.2x%.2x%.2x%.2x%.2x%.2x',
    [QWord(G.D1), Word(G.D2), Word(G.D3),
     Byte(G.D4[0]), Byte(G.D4[1]), Byte(G.D4[2]), Byte(G.D4[3]),
     Byte(G.D4[4]), Byte(G.D4[5]), Byte(G.D4[6]), Byte(G.D4[7])]));
end;

{ ═══════════════════════════════════════════════════════════════════
  Async wait
  ═══════════════════════════════════════════════════════════════════ }

{ ═══════════════════════════════════════════════════════════════════
  Async wait via put_Completed + Windows Event (proper mechanism)
  ═══════════════════════════════════════════════════════════════════ }

type
  PAsyncWaitData = ^TAsyncWaitData;
  TAsyncWaitData = record
    Event: THandle;
    Status: Cardinal;
  end;

function AsyncCompleted_Invoke(Self: PDelegate;
  AsyncOp: PIUnk; Status: Cardinal): HRESULT; stdcall;
var
  D: PAsyncWaitData;
begin
  Result := S_OK;
  D := PAsyncWaitData(Self^.UserData);
  if D <> nil then
  begin
    D^.Status := Status;
    SetEvent(D^.Event);
  end;
end;


{ ═══════════════════════════════════════════════════════════════════
  COM delegate implementation
  ═══════════════════════════════════════════════════════════════════ }

function Del_QI(Self: PDelegate; const riid: TGUID; out ppv: Pointer): HRESULT; stdcall;
begin
  if IsEqualGUID(riid, Self^.IID) or IsEqualGUID(riid, IID_IUnknown_) or
     IsEqualGUID(riid, IID_IAgileObject) then
  begin
    ppv := Self;
    InterlockedIncrement(Self^.RefCount);
    Result := S_OK;
  end else begin
    ppv := nil;
    Result := E_NOINTERFACE;
  end;
end;

function Del_AddRef(Self: PDelegate): ULONG; stdcall;
begin
  Result := InterlockedIncrement(Self^.RefCount);
end;

function Del_Release(Self: PDelegate): ULONG; stdcall;
begin
  Result := InterlockedDecrement(Self^.RefCount);
  if Result = 0 then
  begin
    Self^.OwnedUserData.Free;
    Dispose(Self);
  end;
end;

function MkDel(const AIID: TGUID; AInvoke, AUserData: Pointer): PDelegate;
begin
  New(Result);
  FillChar(Result^, SizeOf(TDelegate), 0);
  Result^.VtblStorage.QI := @Del_QI;
  Result^.VtblStorage.AddRef := @Del_AddRef;
  Result^.VtblStorage.Release := @Del_Release;
  Result^.VtblStorage.Invoke := AInvoke;
  Result^.Vtbl := @Result^.VtblStorage;
  Result^.RefCount := 1;
  Result^.IID := AIID;
  Result^.UserData := AUserData;
end;


{ Wait for IAsyncOperation<T> using put_Completed callback.
  HandlerIID is the IAsyncOperationCompletedHandler<T> GUID. }
function AsyncWaitObj(Op: PIUnk; const HandlerIID: TGUID; Ms: Integer = 30000): PIUnk;
var
  Info: PIUnk;
  St: Cardinal;
  Elapsed: Integer;
  HR: HRESULT;
begin
  { Poll-based wait — no completion handler, no WaitForSingleObject.
    More reliable across threads: works from any COM apartment. }
  Result := nil;
  if Op = nil then Exit;

  if QI(Op, IID_IAsyncInfo, Info) <> S_OK then
  begin
    Logger.Warning('[WinRT] AsyncWaitObj: QI(IAsyncInfo) failed, falling back to sleep');
    Sleep(Min(Ms, 5000));
    TVtGetObj(VT(Op)^[8])(Op, Result);
    Exit;
  end;

  try
    Elapsed := 0;
    repeat
      St := 0;
      TVtGetU32(VT(Info)^[7])(Info, St); { get_Status }
      if St >= 1 then Break;  { 1=Completed, 2=Canceled, 3=Error }
      Sleep(20);
      Inc(Elapsed, 20);
    until Elapsed >= Ms;

    if St = 1 then { Completed }
    begin
      HR := TVtGetObj(VT(Op)^[8])(Op, Result); { GetResults }
      if HR <> S_OK then
      begin
        Logger.Warning(Format('[WinRT] GetResults failed: $%.8X', [HR]));
        Result := nil;
      end
      else
        Logger.Info(Format('[WinRT] Async completed in %d ms', [Elapsed]));
    end
    else if St >= 2 then
      Logger.Warning(Format('[WinRT] Async finished with status=$%.8X after %d ms',
        [Int64(St), Elapsed]))
    else
      Logger.Warning(Format('[WinRT] Async timeout (%d ms)', [Ms]));
  finally
    SafeRelease(Info);
  end;
end;

function AsyncWaitInt(Op: PIUnk; Ms: Integer = 10000): Cardinal;
var
  Info: PIUnk;
  St: Cardinal;
  E: Integer;
begin
  Result := $FFFFFFFF;
  if Op = nil then Exit;
  if QI(Op, IID_IAsyncInfo, Info) <> S_OK then Exit;
  try
    E := 0;
    repeat
      St := 0;
      TVtGetU32(VT(Info)^[7])(Info, St);
      if St >= 1 then Break; { Completed=1, Canceled=2, Error=3 }
      Sleep(50);
      Inc(E, 50);
    until E >= Ms;
    if St = 1 then { AsyncStatus.Completed }
      TVtGetU32(VT(Op)^[8])(Op, Result);
  finally
    SafeRelease(Info);
  end;
end;

{ Polling-based async wait returning object (for cases without handler IID) }
function AsyncWaitObjPoll(Op: PIUnk; Ms: Integer = 15000): PIUnk;
var
  Info: PIUnk;
  St: Cardinal;
  E: Integer;
begin
  Result := nil;
  if Op = nil then Exit;
  if QI(Op, IID_IAsyncInfo, Info) <> S_OK then Exit;
  try
    E := 0;
    repeat
      St := 0;
      TVtGetU32(VT(Info)^[7])(Info, St);
      if St >= 1 then Break;
      Sleep(100);
      Inc(E, 100);
    until E >= Ms;
    if St = 1 then
      TVtGetObj(VT(Op)^[8])(Op, Result);
  finally
    SafeRelease(Info);
  end;
end;

{ ═══════════════════════════════════════════════════════════════════
  Scan Received handler
  ═══════════════════════════════════════════════════════════════════ }

function Scan_Invoke(Self: PDelegate; Sender, Args: PIUnk): HRESULT; stdcall;
var
  UD: PScanUD;
  Addr: UInt64;
  RSSI: Int16;
  Adv: PIUnk;
  NameH: HSTRING;
  Name, AddrS: string;
begin
  Result := S_OK;
  if (Args = nil) or (Self^.UserData = nil) then Exit;
  UD := PScanUD(Self^.UserData);
  RSSI := 0;
  Addr := 0;
  TVtGetI16(VT(Args)^[6])(Args, RSSI);
  TVtGetU64(VT(Args)^[7])(Args, Addr);
  AddrS := MacToStr(Addr);
  Name := '';
  Adv := nil;
  if TVtGetObj(VT(Args)^[10])(Args, Adv) = S_OK then
  begin
    if Adv <> nil then
    begin
      NameH := 0;
      TVtGetHS(VT(Adv)^[8])(Adv, NameH);
      Name := HSToStr(NameH);
      if NameH <> 0 then _HDelete(NameH);
      SafeRelease(Adv);
    end;
  end;
  try
    UD^.Prov.AddScanResult(Name, AddrS, RSSI);
  except
    on E: Exception do
      Logger.Warning('[WinRT] Scan callback exception: ' + E.Message);
  end;
end;

{ ═══════════════════════════════════════════════════════════════════
  ValueChanged handler
  ═══════════════════════════════════════════════════════════════════ }

{ Parse FE-C ANT-over-BLE notification data }
procedure ParseFECNotification(Sess: TWinRTBLESession; const Data: TBytes);
var
  Page: Byte;
  Ofs: Integer;
  Speed: Word;
  Cadence: Byte;
  InstPower: Word;
begin
  if Length(Data) = 0 then Exit;

  { Determine payload offset: full ANT frame starts with $A4, raw payload doesn't }
  if (Data[0] = $A4) and (Length(Data) >= 13) then
  begin
    { Full ANT frame: A4 09 MsgId Channel Data[8] Checksum }
    if Length(Data) >= 5 then
      Sess.FFECChannel := Data[3];
    Ofs := 4; { payload starts at byte 4 }
  end
  else
  begin
    Ofs := 0; { raw 8-byte payload }
  end;

  if Length(Data) < Ofs + 8 then Exit;
  Page := Data[Ofs];

  case Page of
    16: { General FE Data — speed + HR }
    begin
      Speed := Data[Ofs + 4] or (Data[Ofs + 5] shl 8);
      Sess.FLastData.InstantSpeed := Speed * 0.001 * 3.6;
      if Data[Ofs + 6] <> $FF then
        Sess.FLastData.HeartRate := Data[Ofs + 6];
      Sess.FLastData.Timestamp := Now;
      Sess.NotifyDataReceived;
    end;
    25: { Trainer Specific Data — power + cadence }
    begin
      Cadence := Data[Ofs + 2];
      InstPower := Data[Ofs + 5] or ((Data[Ofs + 6] and $0F) shl 8);
      Sess.FLastData.InstantCadence := Cadence;
      Sess.FLastData.InstantPower := InstPower;
      Sess.FLastData.IsMoving := (Cadence > 0) or (InstPower > 0);
      Sess.FLastData.Timestamp := Now;
      if Sess.FLastData.AveragePower = 0 then
        Sess.FLastData.AveragePower := InstPower
      else
        Sess.FLastData.AveragePower := (Sess.FLastData.AveragePower * 3 + InstPower) div 4;
      Sess.NotifyDataReceived;
    end;
  end;
end;

function Notify_Invoke(Self: PDelegate; Sender, Args: PIUnk): HRESULT; stdcall;
var
  UD: TNotifyContext;
  Target: TObject;
  Buf, Acc: PIUnk;
  Len: Cardinal;
  Ptr: PByte;
  Bytes: TBytes;
  Sess: TWinRTBLESession;
  ParsedMeasurement: Boolean;
  ParsedData: TTrainerDataRecord;
begin
  Result := S_OK;
  if (Args = nil) or (Self^.UserData = nil) then Exit;
  UD := TNotifyContext(Self^.UserData);
  if not UD.Acquire(Target) then Exit;
  try
  Sess := TWinRTBLESession(Target);
  Buf := nil;
  TVtGetObj(VT(Args)^[6])(Args, Buf);
  if Buf = nil then Exit;
  try
    Len := 0;
    TVtGetU32(VT(Buf)^[7])(Buf, Len);
    if Len = 0 then Exit;
    Acc := nil;
    if QI(Buf, IID_IBufferByteAccess, Acc) = S_OK then
    begin
      Ptr := nil;
      TVtGetPtr(VT(Acc)^[3])(Acc, Ptr);
      if (Ptr <> nil) and (Len > 0) then
      begin
        SetLength(Bytes, Len);
        Move(Ptr^, Bytes[0], Len);
        ParsedMeasurement := False;
        if Pos('2ad2', UD.CharUUID) > 0 then
        begin
          ParsedMeasurement := True;
          ParsedData := Sess.FFTMSParser.ParseIndoorBikeData(Bytes);
        end
        else if Pos('2a63', UD.CharUUID) > 0 then
        begin
          ParsedMeasurement := True;
          ParsedData := Sess.FFTMSParser.ParseCyclingPowerMeasurement(Bytes);
        end
        else if Pos('2a5b', UD.CharUUID) > 0 then
        begin
          ParsedMeasurement := True;
          ParsedData := Sess.FFTMSParser.ParseCSCMeasurement(Bytes);
        end
        else if Pos('2a37', UD.CharUUID) > 0 then
        begin
          if Length(Bytes) >= 2 then
          begin
            if (Bytes[0] and 1) = 0 then
              Sess.FLastData.HeartRate := Bytes[1]
            else if Length(Bytes) >= 3 then
            begin
              { 16-bit HR format; clamp to 255 since HeartRate is Byte }
              Sess.FLastData.HeartRate := Math.Min(Bytes[1] or (Bytes[2] shl 8), 255);
            end;
            Sess.FLastData.Timestamp := Now;
          end;
        end
        else if Pos('2ad9', UD.CharUUID) > 0 then
        begin
          Sess.ReceiveControlPoint(Bytes);
          SafeRelease(Acc);
          Exit;
        end
        else if Pos('2a19', UD.CharUUID) > 0 then
        begin
          { Battery Level: single byte 0..100 }
          if Length(Bytes) >= 1 then
            Sess.BatteryLevel := Bytes[0];
        end
        else if Pos('6e40fec2', UD.CharUUID) > 0 then
        begin
          { FE-C data: ANT-over-BLE frame or raw payload }
          ParseFECNotification(Sess, Bytes);
        end;
        if (not ParsedMeasurement) or Sess.FFTMSParser.LastPacketValid then
        begin
          if ParsedMeasurement then Sess.FLastData := ParsedData;
          Sess.NotifyDataReceived;
        end;
      end;
      SafeRelease(Acc);
    end;
  finally
    SafeRelease(Buf);
  end;
  finally
    UD.Release;
  end;
end;

{ ═══════════════════════════════════════════════════════════════════
  IBuffer creation helper (via DataWriter)
  ═══════════════════════════════════════════════════════════════════ }

type
  TVtWriteBytes = function(S: PIUnk; Len: Cardinal; Data: PByte): HRESULT; stdcall;
  TVtWriteValueOpt = function(S: PIUnk; Buf: PIUnk; Option: Integer; out Op: PIUnk): HRESULT; stdcall;

{ Create an IBuffer from a TBytes array using WinRT DataWriter }
function CreateBufferFromBytes(const Data: TBytes): PIUnk;
var
  ClsName: HSTRING;
  Writer: PIUnk;
  HR: HRESULT;
begin
  Result := nil;
  if Length(Data) = 0 then Exit;

  _RoInit(0); { STA — GUI thread is already STA from LCL }

  ClsName := HS('Windows.Storage.Streams.DataWriter');
  Writer := nil;
  HR := _RoActivate(ClsName, Writer);
  _HDelete(ClsName);
  if (HR <> S_OK) or (Writer = nil) then Exit;

  try
    { IDataWriter::WriteBytes — vtable[12]: (Self, arrayLen, arrayPtr) }
    HR := TVtWriteBytes(VT(Writer)^[12])(Writer, Length(Data), @Data[0]);
    if HR <> S_OK then
    begin
      Logger.Error(Format('[WinRT] DataWriter.WriteBytes failed: $%.8X', [HR]));
      Exit;
    end;
    { IDataWriter::DetachBuffer — vtable[31]: (Self, out IBuffer) }
    HR := TVtGetObj(VT(Writer)^[31])(Writer, Result);
    if HR <> S_OK then
    begin
      Logger.Error(Format('[WinRT] DataWriter.DetachBuffer failed: $%.8X', [HR]));
      Result := nil;
    end;
  finally
    SafeRelease(Writer);
  end;
end;

{ Write a command to the FTMS Control Point characteristic.
  Uses WriteValueWithOptionAsync (vtable[17]) with WriteWithResponse=0. }
function WriteFTMSControl(CtrlChar: Pointer; const Cmd: TBytes): Boolean;
var
  Buf, AsyncOp: PIUnk;
  Status: Cardinal;
  HR: HRESULT;
begin
  Result := False;
  if CtrlChar = nil then Exit;
  if Length(Cmd) = 0 then Exit;

  try
    Buf := CreateBufferFromBytes(Cmd);
    if Buf = nil then
    begin
      Logger.Error('[WinRT] WriteFTMSControl: failed to create buffer');
      Exit;
    end;
    try
      AsyncOp := nil;
      { IGattCharacteristic::WriteValueWithOptionAsync — vtable[17]:
        (Self, IBuffer, GattWriteOption, out IAsyncOp<GattCommunicationStatus>) }
      HR := TVtWriteValueOpt(VT(CtrlChar)^[17])(CtrlChar, Buf, 0, AsyncOp); { 0 = WriteWithResponse }
      if (HR <> S_OK) or (AsyncOp = nil) then
      begin
        Logger.Error(Format('[WinRT] WriteValueWithOptionAsync failed: $%.8X', [HR]));
        Exit;
      end;
      Status := AsyncWaitInt(AsyncOp, 5000);
      SafeRelease(AsyncOp);
      Result := (Status = 0); { GattCommunicationStatus.Success = 0 }
      if not Result then
        { Status — Cardinal; timeout = $FFFFFFFF. Format(%d) + range-check
          → ERangeError и падение всего процесса. }
        Logger.Warning(Format('[WinRT] FTMS write status=$%.8X', [Int64(Status)]));
    finally
      SafeRelease(Buf);
    end;
  except
    on E: Exception do
      Logger.Error('[WinRT] WriteFTMSControl: ' + E.ClassName + ': ' + E.Message);
  end;
end;

{ Write an FE-C page via ANT-over-BLE format to the FE-C write characteristic.
  Page8 must be exactly 8 bytes (FE-C data page). }
function WriteFECPage(WriteChar: Pointer; Channel: Byte; const Page8: array of Byte): Boolean;
var
  Pkt: TBytes;
  I: Integer;
  CS: Byte;
begin
  Result := False;
  if (WriteChar = nil) or (Length(Page8) <> 8) then Exit;

  { Build full ANT frame: sync(A4) + len(09) + msgId(4F=acked) + channel + 8 data + checksum }
  SetLength(Pkt, 13);
  Pkt[0] := $A4;
  Pkt[1] := $09;
  Pkt[2] := $4F; { Acknowledged data }
  Pkt[3] := Channel;
  for I := 0 to 7 do
    Pkt[4 + I] := Page8[I];
  CS := 0;
  for I := 0 to 11 do
    CS := CS xor Pkt[I];
  Pkt[12] := CS;

  Result := WriteFTMSControl(WriteChar, Pkt);
end;
 { ═══════════════════════════════════════════════════════════════════ }

constructor TWinRTBLESession.Create(const AAddress: string; const AFriendlyName: string);
begin
  inherited Create(AAddress, AFriendlyName);
  FDevice := nil;
  FFTMSParser := TFTMSParser.Create;
  FFTMSCtrlChar := nil;
  FFECWriteChar := nil;
  FFECChannel := 5;
  FGattSession := nil;
  FFactory := nil;
  FDeviceIdStr := 0;
  FHasAccessDenied := False;
  FSubCount := 0;
  BatteryLevel := 0;
end;

{ ── ConnectionStatusChanged callback ── }

function ConnStatus_Invoke(Self: PDelegate; Sender, Args: PIUnk): HRESULT; stdcall;
var
  UD: TTrainerCallbackGate;
  Target: TObject;
  Sess: TWinRTBLESession;
  Status: Cardinal;
begin
  Result := S_OK;
  Logger.Info('[WinRT] ConnStatus_Invoke called');
  if Self^.UserData = nil then begin Logger.Info('[WinRT] ConnStatus_Invoke: UserData=nil, exit'); Exit; end;
  UD := TTrainerCallbackGate(Self^.UserData);
  if not UD.Acquire(Target) then Exit;
  try
  Sess := TWinRTBLESession(Target);
  if Sess.FDevice = nil then Exit;
  Logger.Info('[WinRT] ConnStatus_Invoke: device=' + Sess.DeviceInfo.Name +
    ' state=' + IntToStr(Ord(Sess.ConnectionState)));
  { Only react if we were already connected — ignore during initial setup }
  if Sess.ConnectionState <> csConnected then
  begin Logger.Info('[WinRT] ConnStatus_Invoke: not csConnected, ignoring'); Exit; end;
  { get_ConnectionStatus: 0=Disconnected, 1=Connected }
  Status := 1;
  TVtGetU32(VT(Sess.FDevice)^[9])(Sess.FDevice, Status);
  Logger.Info('[WinRT] ConnStatus_Invoke: ConnectionStatus=' + IntToStr(Status));
  if Status = 0 then
  begin
    Logger.Info('[WinRT] ConnectionStatusChanged -> Disconnected for ' + Sess.DeviceInfo.Name);
    Sess.SetConnectionState(csDisconnected, 'Device disconnected');
  end;
  finally
    UD.Release;
  end;
end;

destructor TWinRTBLESession.Destroy;
begin
  ShutdownControl;
  Disconnect;
  FFTMSParser.Free;
  inherited;
end;

function TWinRTBLESession.Connect: Boolean;
var
  ClsName: HSTRING;
  Factory, AsyncOp, Dev: PIUnk;
  BgWatcher: PIUnk;
  BgClsName: HSTRING;
  HR: HRESULT;
  Addr: UInt64;
  NameH: HSTRING;
  ConnUD: TTrainerCallbackGate;
  ConnDel: PDelegate;
  ConnToken: TEvtToken;
begin
  Result := False;
  { Повторный Connect без Close старого BluetoothLEDevice копит
    GATT-слоты в драйвере до reboot. }
  ReleaseRadioResources;
  SetConnectionState(csConnecting, 'WinRT connecting...');
  FHasFTMS := False; FHasPower := False; FHasFEC := False;
  FHasHR := False; FHasCSC := False;

  HR := _RoInit(1); { RO_INIT_MULTITHREADED — match async BLE callbacks }
  Logger.Info(Format('[WinRT] RoInitialize(MTA): $%.8X', [HR]));
  Logger.Info(Format('[WinRT] Connecting to %s (%s)...',
    [FDeviceInfo.Name, FDeviceInfo.Address]));

  Addr := StrToMac(FDeviceInfo.Address);
  if Addr = 0 then
  begin SetConnectionState(csError, 'Invalid address'); Exit; end;

  { Get factory — kept for reconnect }
  ClsName := HS('Windows.Devices.Bluetooth.BluetoothLEDevice');
  HR := _RoGetFactory(ClsName, IID_IDeviceStatics, Factory);
  _HDelete(ClsName);
  if (HR <> S_OK) or (Factory = nil) then
  begin SetConnectionState(csError, 'Init failed'); Exit; end;
  FFactory := Factory;

  try
    { Background watcher for BLE cache }
    BgWatcher := nil;
    BgClsName := HS('Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher');
    _RoActivate(BgClsName, BgWatcher);
    _HDelete(BgClsName);
    if BgWatcher <> nil then
    begin
      TVtPutI(VT(BgWatcher)^[12])(BgWatcher, 1);
      TVtNoArg(VT(BgWatcher)^[17])(BgWatcher);
    end;

    { Step 1: FromBluetoothAddressAsync → temp device → get DeviceId }
    AsyncOp := nil;
    TVtFromAddr(VT(Factory)^[7])(Factory, Addr, AsyncOp);
    Dev := AsyncWaitObj(AsyncOp, IID_CH_Device, 30000);
    SafeRelease(AsyncOp);

    if BgWatcher <> nil then
    begin TVtNoArg(VT(BgWatcher)^[18])(BgWatcher); SafeClose(BgWatcher); end;

    if Dev = nil then
    begin SetConnectionState(csError, 'Device not found'); Exit; end;

    { Cache DeviceId string }
    if FDeviceIdStr <> 0 then begin _HDelete(HSTRING(FDeviceIdStr)); FDeviceIdStr := 0; end;
    TVtGetHS(VT(Dev)^[6])(Dev, HSTRING(FDeviceIdStr));
    Logger.Info('[WinRT] DeviceId: ' + HSToStr(HSTRING(FDeviceIdStr)));

    { Use device from FromBluetoothAddressAsync directly — no FromIdAsync!
      BLE Goodies does the same: AdvWatcher → FromAddress → GATT directly. }
    FDevice := Dev;  { take ownership, do NOT release Dev }

    { Read name }
    NameH := 0;
    TVtGetHS(VT(FDevice)^[7])(FDevice, NameH);
    if NameH <> 0 then begin FDeviceInfo.Name := HSToStr(NameH); _HDelete(NameH); end;
    Logger.Info('[WinRT] Device name: ' + FDeviceInfo.Name);

    { Step 3: Discover GATT + subscribe }
    FHasAccessDenied := False;
    Logger.Info('[WinRT] >>> DiscoverAndSubscribe starting...');
    try
      DiscoverAndSubscribe;
    except
      on E: Exception do
        Logger.Error('[WinRT] DiscoverAndSubscribe EXCEPTION: ' + E.ClassName + ': ' + E.Message);
    end;
    Logger.Info('[WinRT] <<< DiscoverAndSubscribe done. SubCount=' + IntToStr(FSubCount) +
      ' FTMS=' + BoolToStr(FHasFTMS,True) + ' Power=' + BoolToStr(FHasPower,True) +
      ' HR=' + BoolToStr(FHasHR,True) + ' CSC=' + BoolToStr(FHasCSC,True) +
      ' FEC=' + BoolToStr(FHasFEC,True));

    if FHasAccessDenied then
      Logger.Warning('[WinRT] AccessDenied on some services');

    FDeviceInfo.TransportType := ttBLE;
    FDeviceInfo.ProviderName := 'WinRT';
    FDeviceInfo.SupportsFTMS := FHasFTMS;
    FDeviceInfo.SupportsControl := (FFTMSCtrlChar <> nil) or (FFECWriteChar <> nil);
    FDeviceInfo.SupportsPower := FHasPower or FHasFEC or FHasFTMS;
    FDeviceInfo.SupportsCadence := FHasFEC or FHasFTMS or FHasCSC or FHasPower;
    FDeviceInfo.SupportsHeartRate := FHasHR;

    Logger.Info(Format('[WinRT] Caps: FTMS=%s Power=%s HR=%s CSC=%s FEC=%s',
      [BoolToStr(FHasFTMS,True), BoolToStr(FHasPower,True),
       BoolToStr(FHasHR,True), BoolToStr(FHasCSC,True),
       BoolToStr(FHasFEC,True)]));

    { Не фитнес-устройство — отключаемся, не засоряем список }
    if (not FHasFTMS) and (not FHasPower) and (not FHasFEC)
       and (not FHasHR) and (not FHasCSC) then
    begin
      Logger.Info('[WinRT] No fitness services — disconnecting');
      Disconnect;
      SetConnectionState(csDisconnected, 'Not a fitness device');
      Exit;
    end;

    if FHasAccessDenied and (FSubCount = 0) then
    begin
      SetConnectionState(csConnected, 'Connected (no subscriptions — AccessDenied)');
      Logger.Warning('[WinRT] Connected but no GATT subscriptions active');
    end
    else if FHasAccessDenied then
    begin
      SetConnectionState(csConnected, 'Connected (partial — some services AccessDenied)');
      Logger.Info(Format('[WinRT] Connected with %d subscriptions (some services inaccessible)', [FSubCount]));
    end
    else
    begin
      SetConnectionState(csConnected, 'Connected');
      Logger.Info(Format('[WinRT] Connected OK — %d subscriptions', [FSubCount]));
    end;

    { Subscribe to disconnect AFTER SetConnectionState(csConnected) }
    try
      ConnUD := TTrainerCallbackGate.Create(Self);
      ConnDel := MkDel(IID_ConnStatusHandler, @ConnStatus_Invoke, Pointer(ConnUD));
      ConnDel^.OwnedUserData := ConnUD;
      ConnToken.Value := 0;
      HR := TVtAddHandler(VT(FDevice)^[16])(FDevice, ConnDel, ConnToken);
      if HR = S_OK then
      begin
        FConnStatusToken := ConnToken.Value;
        FConnStatusUD := Pointer(ConnUD);
        FConnStatusDel := ConnDel;
        Logger.Info('[WinRT] Subscribed to ConnectionStatusChanged OK');
      end
      else
      begin
        Logger.Warning('[WinRT] add_ConnectionStatusChanged failed: HR=' + IntToStr(HR));
        FConnStatusUD := nil;
        Del_Release(ConnDel);
        ConnDel := nil;
      end;
    except
      on E: Exception do
        Logger.Warning('[WinRT] ConnectionStatusChanged subscribe error: ' + E.ClassName + ': ' + E.Message);
    end;
    Result := True;
  finally
    { Factory stays alive in FFactory for reconnect, released in Disconnect }
  end;
end;

{ ── Pairing helper ── }

type
  TPairLogEntry = record
    Called: Boolean;
    Kind: Cardinal;
    AcceptHR: HRESULT;
  end;

var
  GPairLog: TPairLogEntry;

procedure LogPairRequestResult;
begin
  if not GPairLog.Called then
  begin
    Logger.Warning('[WinRT] PairingRequested handler was NOT called');
    Exit;
  end;
  Logger.Info(Format('[WinRT] PairingRequested: Kind=%d (1=Confirm 2=DisplayPin 4=ProvidePin 8=ConfirmPin) Accept HR=$%.8X',
    [GPairLog.Kind, Cardinal(GPairLog.AcceptHR)]));
end;

{ Forward declaration — implemented below in TWinRTBLEProvider section }
function PairingReq_Invoke(Self: PDelegate;
  Sender: PIUnk; Args: PIUnk): HRESULT; stdcall; forward;

function TWinRTBLESession.TryPairDevice(Level: Integer): TPairOutcome;
var
  Dev2, DevInfoObj, DevInfo2, PairingObj, AsyncOp, PairRes: PIUnk;
  Pairing2, CustomPair: PIUnk;
  IsPaired, CanPair, PairStatus: Cardinal;
  Del: PDelegate;
  ReqToken: TEvtToken;
  HR: HRESULT;
begin
  Result := poFailed;
  if FDevice = nil then Exit;

  Dev2 := nil;
  if QI(FDevice, IID_IDevice2, Dev2) <> S_OK then Exit;
  try
    DevInfoObj := nil;
    TVtGetObj(VT(Dev2)^[6])(Dev2, DevInfoObj);
    if DevInfoObj = nil then Exit;
    try
      DevInfo2 := nil;
      if QI(DevInfoObj, IID_IDeviceInfo2, DevInfo2) <> S_OK then Exit;
      try
        PairingObj := nil;
        TVtGetObj(VT(DevInfo2)^[7])(DevInfo2, PairingObj);
        if PairingObj = nil then Exit;
        try
          IsPaired := 0;
          TVtGetU32(VT(PairingObj)^[6])(PairingObj, IsPaired);
          Logger.Info(Format('[WinRT] IsPaired=%d', [IsPaired and $FF]));

          if (IsPaired and $FF) <> 0 then
          begin Result := poAlreadyPaired; Exit; end;

          CanPair := 0;
          TVtGetU32(VT(PairingObj)^[7])(PairingObj, CanPair);
          Logger.Info(Format('[WinRT] CanPair=%d', [CanPair and $FF]));
          if (CanPair and $FF) = 0 then
          begin Result := poCannotPair; Exit; end;

          { Try basic PairAsync first (vtable[8]) }
          Logger.Info('[WinRT] PairAsync (basic)...');
          AsyncOp := nil;
          TVtCallOut(VT(PairingObj)^[8])(PairingObj, AsyncOp);
          if AsyncOp <> nil then
          begin
            PairRes := AsyncWaitObjPoll(AsyncOp, 30000);
            SafeRelease(AsyncOp);
            if PairRes <> nil then
            begin
              PairStatus := $FF;
              TVtGetU32(VT(PairRes)^[6])(PairRes, PairStatus);
              Logger.Info(Format('[WinRT] Basic PairResult=%d (0=Paired 3=AlreadyPaired 19=Failed)', [PairStatus]));
              if (PairStatus = 0) or (PairStatus = 3) then
              begin Result := poPaired; SafeRelease(PairRes); Exit; end;
              SafeRelease(PairRes);
            end;
          end;

          { If basic failed, try with explicit protection level }
          Logger.Info(Format('[WinRT] PairWithProtectionLevelAsync(level=%d)...', [Level]));
          AsyncOp := nil;
          TVtCallMode(VT(PairingObj)^[9])(PairingObj, Level, AsyncOp);
          if AsyncOp <> nil then
          begin
            PairRes := AsyncWaitObjPoll(AsyncOp, 30000);
            SafeRelease(AsyncOp);
            if PairRes <> nil then
            begin
              PairStatus := $FF;
              TVtGetU32(VT(PairRes)^[6])(PairRes, PairStatus);
              Logger.Info(Format('[WinRT] PairResult=%d (0=Paired 11=LevelNotMet 19=Failed)', [PairStatus]));
              if (PairStatus = 0) or (PairStatus = 3) then
              begin Result := poPaired; SafeRelease(PairRes); Exit; end;
              SafeRelease(PairRes);
            end;
          end;

          { If both failed, try Custom pairing with handler (supports all ceremony types) }
          Pairing2 := nil;
          if QI(PairingObj, IID_IPairing2, Pairing2) = S_OK then
          begin
            try
              CustomPair := nil;
              TVtGetObj(VT(Pairing2)^[7])(Pairing2, CustomPair); { get_Custom }
              if CustomPair <> nil then
              begin
                try
                  Del := MkDel(IID_PairingReqHandler, @PairingReq_Invoke, nil);
                  ReqToken.Value := 0;
                  HR := TVtAddHandler(VT(CustomPair)^[9])(CustomPair, Del, ReqToken);
                  if HR <> S_OK then
                    Logger.Warning(Format('[WinRT] add_PairingRequested failed: $%.8X', [HR]));

                  Logger.Info('[WinRT] Custom.PairAsync(AllKinds=$0F, ProtectionLevel=None)...');
                  GPairLog.Called := False;
                  AsyncOp := nil;
                  { vtable[7] = PairAsync(DevicePairingKinds, DevicePairingProtectionLevel) }
                  TVtCallMode2(VT(CustomPair)^[7])(CustomPair, $0F, 0, AsyncOp);
                  if AsyncOp <> nil then
                  begin
                    PairRes := AsyncWaitObjPoll(AsyncOp, 30000);
                    SafeRelease(AsyncOp);
                    LogPairRequestResult;
                    if PairRes <> nil then
                    begin
                      PairStatus := $FF;
                      TVtGetU32(VT(PairRes)^[6])(PairRes, PairStatus);
                      Logger.Info(Format('[WinRT] Custom PairResult=%d (0=Paired 17=RejectedByHandler)', [PairStatus]));
                      if (PairStatus = 0) or (PairStatus = 3) then
                        Result := poPaired;
                      SafeRelease(PairRes);
                    end;
                  end;

                  TVtRemHandler(VT(CustomPair)^[10])(CustomPair, ReqToken);
                  Del^.UserData := nil;
                  Del_Release(Del);
                finally
                  SafeRelease(CustomPair);
                end;
              end;
            finally
              SafeRelease(Pairing2);
            end;
          end;
        finally
          SafeRelease(PairingObj);
        end;
      finally
        SafeRelease(DevInfo2);
      end;
    finally
      SafeRelease(DevInfoObj);
    end;
  finally
    SafeRelease(Dev2);
  end;
end;

{ ── Unpair device (clear stale bond) ── }

function TWinRTBLESession.TryUnpairDevice: Boolean;
var
  Dev2, DevInfoObj, DevInfo2, PairingObj, Pairing2, AsyncOp, UnpairRes: PIUnk;
  UnpairStatus: Cardinal;
begin
  Result := False;
  if FDevice = nil then Exit;

  Dev2 := nil;
  if QI(FDevice, IID_IDevice2, Dev2) <> S_OK then Exit;
  try
    DevInfoObj := nil;
    TVtGetObj(VT(Dev2)^[6])(Dev2, DevInfoObj);
    if DevInfoObj = nil then Exit;
    try
      DevInfo2 := nil;
      if QI(DevInfoObj, IID_IDeviceInfo2, DevInfo2) <> S_OK then Exit;
      try
        PairingObj := nil;
        TVtGetObj(VT(DevInfo2)^[7])(DevInfo2, PairingObj);
        if PairingObj = nil then Exit;
        try
          { QI for IDeviceInformationPairing2 — has UnpairAsync }
          Pairing2 := nil;
          if QI(PairingObj, IID_IPairing2, Pairing2) <> S_OK then
          begin Logger.Warning('[WinRT] IDeviceInformationPairing2 not available'); Exit; end;
          try
            Logger.Info('[WinRT] UnpairAsync...');
            AsyncOp := nil;
            TVtCallOut(VT(Pairing2)^[9])(Pairing2, AsyncOp); { UnpairAsync }
            if AsyncOp <> nil then
            begin
              UnpairRes := AsyncWaitObjPoll(AsyncOp, 15000);
              SafeRelease(AsyncOp);
              if UnpairRes <> nil then
              begin
                UnpairStatus := $FF;
                TVtGetU32(VT(UnpairRes)^[6])(UnpairRes, UnpairStatus);
                Logger.Info(Format('[WinRT] UnpairResult status=%d (0=Unpaired)', [UnpairStatus]));
                Result := UnpairStatus = 0;
                SafeRelease(UnpairRes);
              end;
            end;
          finally
            SafeRelease(Pairing2);
          end;
        finally
          SafeRelease(PairingObj);
        end;
      finally
        SafeRelease(DevInfo2);
      end;
    finally
      SafeRelease(DevInfoObj);
    end;
  finally
    SafeRelease(Dev2);
  end;
end;

{ ── Reopen device via cached DeviceId ── }

function TWinRTBLESession.ReopenDevice: Boolean;
var
  AsyncOp, Old: PIUnk;
  HR: HRESULT;
begin
  Result := False;
  if (FFactory = nil) or (FDeviceIdStr = 0) then Exit;
  if FDevice <> nil then
  begin
    Old := PIUnk(FDevice);
    FDevice := nil;
    SafeClose(Old);
  end;

  AsyncOp := nil;
  HR := TVtFromId(VT(FFactory)^[6])(FFactory, HSTRING(FDeviceIdStr), AsyncOp);
  if (HR <> S_OK) or (AsyncOp = nil) then
  begin Logger.Error(Format('[WinRT] FromIdAsync failed: $%.8X', [HR])); Exit; end;

  Logger.Info('[WinRT] FromIdAsync...');
  FDevice := AsyncWaitObj(AsyncOp, IID_CH_Device, 30000);
  SafeRelease(AsyncOp);
  Result := FDevice <> nil;
  if not Result then
    Logger.Error('[WinRT] FromIdAsync returned nil');
end;

procedure TWinRTBLESession.DiscoverAndSubscribe;
var
  Dev3, AsyncOp, SvcsRes, SvcList, Svc, Svc3: PIUnk;
  CharsRes, CharList, Ch: PIUnk;
  SvcCount, ChCount, Status, Props, SubscribeStatus: Cardinal;
  I, J, Retry: Integer;
  SvcG, ChG: TGUID;
  SvcS, ChS: string;
  Token: TEvtToken;
  ND: TNotifyContext;
  Del: PDelegate;
  { Battery read vars }
  ReadRes, ReadBuf, ReadAcc: PIUnk;
  ReadStatus, ReadLen: Cardinal;
  ReadPtr: PByte;
begin
  if FDevice = nil then begin Logger.Warning('[WinRT] DiscoverAndSubscribe: FDevice=nil'); Exit; end;

  Dev3 := nil;
  if QI(FDevice, IID_IDevice3, Dev3) <> S_OK then
  begin Logger.Warning('[WinRT] DiscoverAndSubscribe: QI(IDevice3) failed'); Exit; end;
  try
    AsyncOp := nil;
    Logger.Info('[WinRT] DiscoverAndSubscribe: GetGattServicesWithCacheModeAsync(Uncached)...');
    TVtCallMode(VT(Dev3)^[9])(Dev3, 1, AsyncOp);
    SvcsRes := AsyncWaitObj(AsyncOp, IID_CH_SvcsResult, 30000);
    SafeRelease(AsyncOp);
    if SvcsRes = nil then
    begin Logger.Error('[WinRT] GetGattServices timeout'); Exit; end;

    try
      Status := $FF;
      TVtGetU32(VT(SvcsRes)^[6])(SvcsRes, Status);
      if Status <> 0 then
      begin Logger.Error(Format('[WinRT] GATT status=%d', [Status])); Exit; end;

      SvcList := nil;
      TVtGetObj(VT(SvcsRes)^[8])(SvcsRes, SvcList);
      if SvcList = nil then Exit;
      try
        SvcCount := 0;
        TVtGetU32(VT(SvcList)^[7])(SvcList, SvcCount);
        Logger.Info(Format('[WinRT] Services: %d', [SvcCount]));

        for I := 0 to Integer(SvcCount) - 1 do
        begin
          Svc := nil;
          TVtGetAt(VT(SvcList)^[6])(SvcList, Cardinal(I), Svc);
          if Svc = nil then Continue;

          SvcG := Default(TGUID);
          TVtGetGUID(VT(Svc)^[9])(Svc, SvcG);
          SvcS := GuidStr(SvcG);
          Logger.Debug(Format('[WinRT]   Svc[%d]: %s', [I, SvcS]));

          if Pos('00001826', SvcS) > 0 then FHasFTMS := True;
          if Pos('00001818', SvcS) > 0 then FHasPower := True;
          if Pos('6e40fec1', SvcS) > 0 then FHasFEC := True;
          if Pos('0000180d', SvcS) > 0 then FHasHR := True;
          if Pos('00001816', SvcS) > 0 then FHasCSC := True;

          Svc3 := nil;
          if QI(Svc, IID_ISvc3, Svc3) = S_OK then
          begin
            try
              { GetCharacteristicsWithCacheModeAsync: try Uncached first, then Cached on AccessDenied }
              CharsRes := nil;
              Status := $FF;
              for Retry := 0 to 2 do
              begin
                AsyncOp := nil;
                if Retry < 2 then
                  TVtCallMode(VT(Svc3)^[12])(Svc3, 1, AsyncOp)  { Uncached=1 }
                else
                  TVtCallMode(VT(Svc3)^[12])(Svc3, 0, AsyncOp); { Cached=0 — fallback }
                CharsRes := AsyncWaitObj(AsyncOp, IID_CH_CharsResult, 15000);
                SafeRelease(AsyncOp);
                if CharsRes <> nil then
                begin
                  Status := $FF;
                  TVtGetU32(VT(CharsRes)^[6])(CharsRes, Status);
                  if Retry = 2 then
                    Logger.Debug(Format('[WinRT]     CharsResult status=%d (Cached fallback)', [Status]))
                  else
                    Logger.Debug(Format('[WinRT]     CharsResult status=%d (Uncached attempt %d)', [Status, Retry]));
                  if Status = 0 then Break; { Success }
                  if (Status = 3) and (Retry = 0) then
                  begin
                    Logger.Info('[WinRT]     Uncached AccessDenied — retrying...');
                    SafeRelease(CharsRes);
                    CharsRes := nil;
                    Sleep(200);
                    Continue;
                  end;
                  if (Status = 3) and (Retry = 1) then
                  begin
                    Logger.Info('[WinRT]     Uncached AccessDenied — trying Cached fallback...');
                    SafeRelease(CharsRes);
                    CharsRes := nil;
                    Continue;
                  end;
                  Break;
                end else
                begin
                  Logger.Warning(Format('[WinRT]     GetChars nil (attempt %d)', [Retry]));
                  if Retry < 2 then begin Sleep(200); Continue; end;
                  Break;
                end;
              end;
              if (CharsRes <> nil) and (Status = 0) then
              begin
                try
                    CharList := nil;
                    TVtGetObj(VT(CharsRes)^[8])(CharsRes, CharList);
                    if CharList <> nil then
                    begin
                      try
                        ChCount := 0;
                        TVtGetU32(VT(CharList)^[7])(CharList, ChCount);
                        Logger.Debug(Format('[WinRT]     CharCount=%d', [ChCount]));
                        for J := 0 to Integer(ChCount) - 1 do
                        begin
                          Ch := nil;
                          TVtGetAt(VT(CharList)^[6])(CharList, Cardinal(J), Ch);
                          if Ch = nil then Continue;

                          ChG := Default(TGUID);
                          TVtGetGUID(VT(Ch)^[11])(Ch, ChG);
                          Props := 0;
                          TVtGetU32(VT(Ch)^[7])(Ch, Props);
                          ChS := GuidStr(ChG);

                          Logger.Debug(Format('[WinRT]     Char[%d]: %s props=$%.2X', [J, ChS, Props]));

                          { Save write chars for trainer control }
                          if Pos('6e40fec3', ChS) > 0 then
                          begin
                            FFECWriteChar := Ch;
                            TVtNoArg(VT(Ch)^[1])(Ch); { IUnknown::AddRef }
                            Logger.Info('[WinRT]     FE-C write char saved');
                          end;

                          if ((Props and $10) <> 0) or ((Props and $20) <> 0) then
                          begin
                            if (Pos('2ad2', ChS) > 0) or (Pos('2a63', ChS) > 0) or
                               (Pos('6e40fec2', ChS) > 0) or (Pos('2a37', ChS) > 0) or
                               (Pos('2a5b', ChS) > 0) or (Pos('2ad9', ChS) > 0) or
                               (Pos('2a19', ChS) > 0) then
                            begin
                              { Don't set ProtectionLevel — let Windows handle encryption transparently }

                              AsyncOp := nil;
                              SubscribeStatus := $FFFFFFFF;
                              if (Pos('2ad9', ChS) > 0) and ((Props and $20) <> 0) then
                                TVtWriteCCCD(VT(Ch)^[19])(Ch, 2, AsyncOp)
                              else if (Props and $10) <> 0 then
                                TVtWriteCCCD(VT(Ch)^[19])(Ch, 1, AsyncOp)
                              else
                                TVtWriteCCCD(VT(Ch)^[19])(Ch, 2, AsyncOp);
                              if AsyncOp <> nil then
                              begin
                                SubscribeStatus := AsyncWaitInt(AsyncOp, 5000);
                                SafeRelease(AsyncOp);
                              end;

                              if SubscribeStatus <> 0 then
                              begin
                                Logger.Warning('[WinRT] Notification subscription failed: ' + ChS);
                                SafeRelease(Ch);
                                Continue;
                              end;

                              ND := TNotifyContext.Create(Self);
                              ND.SvcUUID := SvcS;
                              ND.CharUUID := ChS;
                              Del := MkDel(IID_ValueChangedHandler, @Notify_Invoke, Pointer(ND));
                              Del^.OwnedUserData := ND;
                              Token.Value := 0;
                              if TVtAddHandler(VT(Ch)^[20])(Ch, Del, Token) = S_OK then
                              begin
                                Logger.Info(Format('[WinRT]     Subscribed: %s', [ChS]));
                                { GetAt already owns one character reference; transfer it. }
                                if FSubCount >= Length(FSubs) then
                                  SetLength(FSubs, FSubCount + 4);
                                FSubs[FSubCount].CharHandle := Ch;
                                FSubs[FSubCount].TokenValue := Token.Value;
                                FSubs[FSubCount].UserData := Pointer(ND);
                                FSubs[FSubCount].DelegateHandle := Del;
                                Inc(FSubCount);

                                { Check for FTMS Control Point }
                                if Pos('2ad9', ChS) > 0 then
                                  FFTMSCtrlChar := Ch;

                                { Initial read for Battery Level (notifications are infrequent) }
                                if Pos('2a19', ChS) > 0 then
                                begin
                                  AsyncOp := nil;
                                  { IGattCharacteristic::ReadValueAsync — vtable[14] }
                                  TVtCallOut(VT(Ch)^[14])(Ch, AsyncOp);
                                  if AsyncOp <> nil then
                                  begin
                                    ReadRes := AsyncWaitObjPoll(AsyncOp, 5000);
                                    SafeRelease(AsyncOp);
                                    if ReadRes <> nil then
                                    begin
                                      ReadStatus := $FF;
                                      TVtGetU32(VT(ReadRes)^[6])(ReadRes, ReadStatus);
                                      if ReadStatus = 0 then
                                      begin
                                        ReadBuf := nil;
                                        TVtGetObj(VT(ReadRes)^[7])(ReadRes, ReadBuf);
                                        if ReadBuf <> nil then
                                        begin
                                          ReadLen := 0;
                                          TVtGetU32(VT(ReadBuf)^[7])(ReadBuf, ReadLen);
                                          if ReadLen >= 1 then
                                          begin
                                            ReadAcc := nil;
                                            if QI(ReadBuf, IID_IBufferByteAccess, ReadAcc) = S_OK then
                                            begin
                                              ReadPtr := nil;
                                              TVtGetPtr(VT(ReadAcc)^[3])(ReadAcc, ReadPtr);
                                              if ReadPtr <> nil then
                                              begin
                                                BatteryLevel := ReadPtr^;
                                                Logger.Info(Format('[WinRT]     Battery: %d%%', [BatteryLevel]));
                                              end;
                                              SafeRelease(ReadAcc);
                                            end;
                                          end else
                                            Logger.Warning('[WinRT]     Battery read: buffer empty');
                                          SafeRelease(ReadBuf);
                                        end else
                                          Logger.Warning('[WinRT]     Battery read: get_Value returned nil');
                                      end else
                                        Logger.Warning(Format('[WinRT]     Battery read: status=%d', [ReadStatus]));
                                      SafeRelease(ReadRes);
                                    end else
                                      Logger.Warning('[WinRT]     Battery read: AsyncWaitObjPoll returned nil');
                                  end else
                                    Logger.Warning('[WinRT]     Battery read: ReadValueAsync returned nil op');
                                end;

                                { Skip SafeRelease — char ownership transferred to FSubs }
                                Continue;
                              end
                              else
                              begin
                                Logger.Warning(Format('[WinRT]     Subscribe fail: %s', [ChS]));
                                Del_Release(Del);
                              end;
                            end;
                          end;
                          SafeRelease(Ch);
                        end;
                      finally
                        SafeRelease(CharList);
                      end;
                    end;
                finally
                  SafeRelease(CharsRes);
                end;
              end
              else begin
                if CharsRes <> nil then SafeRelease(CharsRes);
                if Status = 3 then
                begin
                  FHasAccessDenied := True;
                  Logger.Warning(Format('[WinRT]     Svc[%d]: WinRT GATT AccessDenied (may need pairing, stale bond, or WinRT limitation)', [I]));
                end
                else
                  Logger.Warning(Format('[WinRT]     Svc[%d]: GetChars failed (status=%d)', [I, Status]));
              end;
            finally
              SafeRelease(Svc3);
            end;
          end else
            Logger.Debug(Format('[WinRT]     QI for IGattDeviceService3 failed on Svc[%d]', [I]));
          SafeRelease(Svc);
        end;
      finally
        SafeRelease(SvcList);
      end;
    finally
      SafeRelease(SvcsRes);
    end;
  finally
    SafeRelease(Dev3);
  end;
end;

procedure TWinRTBLESession.CleanupSubscriptions;
var
  I: Integer;
  Token: TEvtToken;
  AsyncOp: PIUnk;
begin
  { Fence every source before touching the parser/session. Late COM callbacks
    retain their delegate-owned gate and return without accessing this session. }
  for I := 0 to FSubCount - 1 do
    if FSubs[I].UserData <> nil then
      TTrainerCallbackGate(FSubs[I].UserData).Detach;
  for I := 0 to FSubCount - 1 do
  begin
    if FSubs[I].CharHandle <> nil then
    begin
      { CCCD None — иначе нотификации висят на радио после Release. }
      AsyncOp := nil;
      try
        TVtWriteCCCD(VT(FSubs[I].CharHandle)^[19])(FSubs[I].CharHandle, 0, AsyncOp);
        if AsyncOp <> nil then
        begin
          AsyncWaitInt(AsyncOp, 800);
          SafeRelease(AsyncOp);
        end;
      except
      end;
      Token.Value := FSubs[I].TokenValue;
      try
        TVtRemHandler(VT(FSubs[I].CharHandle)^[21])(FSubs[I].CharHandle, Token);
      except
      end;
    end;
    if FSubs[I].UserData <> nil then
      TTrainerCallbackGate(FSubs[I].UserData).WaitForIdle;
    SafeRelease(PIUnk(FSubs[I].CharHandle));
    if FSubs[I].DelegateHandle <> nil then
      Del_Release(PDelegate(FSubs[I].DelegateHandle));
    FSubs[I].UserData := nil;
    FSubs[I].DelegateHandle := nil;
  end;
  FSubCount := 0;
  SetLength(FSubs, 0);
  FFTMSCtrlChar := nil;
  if FFECWriteChar <> nil then begin SafeRelease(PIUnk(FFECWriteChar)); FFECWriteChar := nil; end;
end;

procedure TWinRTBLESession.ReleaseRadioResources;
var
  Token: TEvtToken;
  Dev, Sess, Fac: PIUnk;
begin
  if FConnStatusUD <> nil then
    TTrainerCallbackGate(FConnStatusUD).Detach;
  if (FDevice <> nil) and (FConnStatusDel <> nil) then
  begin
    Token.Value := FConnStatusToken;
    try
      TVtRemHandler(VT(FDevice)^[17])(FDevice, Token);
    except
    end;
    FConnStatusToken := 0;
  end;
  if FConnStatusUD <> nil then
    TTrainerCallbackGate(FConnStatusUD).WaitForIdle;
  if FConnStatusDel <> nil then
  begin Del_Release(PDelegate(FConnStatusDel)); FConnStatusDel := nil; end;
  FConnStatusUD := nil;

  CleanupSubscriptions;

  { Close ДО Release — иначе слот радио остаётся занятым. }
  if FGattSession <> nil then
  begin
    Sess := PIUnk(FGattSession);
    FGattSession := nil;
    SafeClose(Sess);
  end;
  if FDevice <> nil then
  begin
    Logger.Info('[WinRT] IClosable.Close BluetoothLEDevice');
    Dev := PIUnk(FDevice);
    FDevice := nil;
    SafeClose(Dev);
  end;
  if FFactory <> nil then
  begin
    Fac := PIUnk(FFactory);
    FFactory := nil;
    SafeRelease(Fac);
  end;
  if FDeviceIdStr <> 0 then begin _HDelete(HSTRING(FDeviceIdStr)); FDeviceIdStr := 0; end;
end;

function TWinRTBLESession.IsConnectionAlive: Boolean;
var
  Status: Cardinal;
  HR: HRESULT;
begin
  Result := False;
  if FConnectionState <> csConnected then Exit;
  if FDevice = nil then Exit;

  { IBluetoothLEDevice::get_ConnectionStatus — vtable[9]
    BluetoothConnectionStatus: 0 = Disconnected, 1 = Connected }
  Status := 0;
  HR := TVtGetU32(VT(FDevice)^[9])(FDevice, Status);
  if HR <> S_OK then
  begin
    Logger.Warning(Format('[WinRT] get_ConnectionStatus failed: $%.8X', [HR]));
    Exit;  { assume dead }
  end;

  Result := (Status = 1);
  if not Result then
    Logger.Info(Format('[WinRT] ConnectionStatus=%d for %s — device lost',
      [Status, FDeviceInfo.Name]));
end;

procedure TWinRTBLESession.Disconnect;
begin
  CancelControl;
  Logger.Info('[WinRT] Disconnecting...');
  ReleaseRadioResources;
  SetConnectionState(csDisconnected, 'Disconnected');
end;

function TWinRTBLESession.WriteFTMSCommand(const Data: TBytes): Boolean;
begin
  Result := WriteFTMSControl(FFTMSCtrlChar, Data);
end;

function TWinRTBLESession.RequestControl: Boolean;
begin
  Result := False;
  if FConnectionState <> csConnected then Exit;
  if FHasFEC then begin Result := True; Exit; end; { FE-C: no request needed }
  if not FHasFTMS then Exit;
  Result := inherited RequestControl;
  if Result then
    Logger.Debug('[WinRT] RequestControl OK')
  else
    Logger.Warning('[WinRT] RequestControl failed');
end;

function TWinRTBLESession.SetTargetPower(Watts: Word): Boolean;
var
  Page: array[0..7] of Byte;
  QW: Word;
begin
  Result := False;
  if FConnectionState <> csConnected then Exit;
  if FHasFEC and (FFECWriteChar <> nil) then
  begin
    QW := Min(16383, Watts) * 4;
    Page[0] := 49; { Page 49 = Target Power }
    Page[1] := $FF; Page[2] := $FF; Page[3] := $FF;
    Page[4] := $FF; Page[5] := $FF;
    Page[6] := Lo(QW); Page[7] := Hi(QW);
    Result := WriteFECPage(FFECWriteChar, FFECChannel, Page);
  end
  else if FHasFTMS then
    Result := inherited SetTargetPower(Watts);
  Logger.Debug(Format('[WinRT] SetTargetPower(%d) → %s', [Watts, BoolToStr(Result, True)]));
end;

function TWinRTBLESession.SetResistanceLevel(Level: Byte): Boolean;
var
  Page: array[0..7] of Byte;
begin
  Result := False;
  if FConnectionState <> csConnected then Exit;
  if FHasFEC and (FFECWriteChar <> nil) then
  begin
    Page[0] := 48; { Page 48 = Basic Resistance }
    Page[1] := $FF; Page[2] := $FF; Page[3] := $FF;
    Page[4] := $FF; Page[5] := $FF; Page[6] := $FF;
    Page[7] := Min(100, Level) * 2; { same percent units as other providers }
    Result := WriteFECPage(FFECWriteChar, FFECChannel, Page);
  end
  else if FHasFTMS then
    Result := inherited SetResistanceLevel(Level);
  Logger.Debug(Format('[WinRT] SetResistanceLevel(%d) → %s', [Level, BoolToStr(Result, True)]));
end;

function TWinRTBLESession.SetIncline(InclinePercent: Single): Boolean;
var
  Page: array[0..7] of Byte;
  FECGrade: Integer;
begin
  Result := False;
  if FConnectionState <> csConnected then Exit;
  if FHasFEC and (FFECWriteChar <> nil) then
  begin
    { FE-C Page 51 — same offset encoding as SetSimulation }
    FECGrade := Round((InclinePercent + 200.0) * 100);
    if FECGrade < 0 then FECGrade := 0;
    if FECGrade > 40000 then FECGrade := 40000;
    Page[0] := 51; { Page 51 = Track Resistance }
    Page[1] := $FF; Page[2] := $FF; Page[3] := $FF;
    Page[4] := $FF;
    Page[5] := Lo(Word(FECGrade)); Page[6] := Hi(Word(FECGrade));
    Page[7] := $FF; { CRR = default }
    Result := WriteFECPage(FFECWriteChar, FFECChannel, Page);
  end
  else if FHasFTMS then
    Result := inherited SetIncline(InclinePercent);
  Logger.Debug('[WinRT] SetIncline(' + FormatFloat('0.0', InclinePercent) +
    '%) -> ' + BoolToStr(Result, True));
end;

function TWinRTBLESession.SetSimulation(Grade: Single; WindSpeed: Single;
  RiderWeight: Single; BikeWeight: Single): Boolean;
var
  Page: array[0..7] of Byte;
  FECGrade: Integer;
begin
  Result := False;
  if FConnectionState <> csConnected then Exit;
  try
    if FHasFEC and (FFECWriteChar <> nil) then
    begin
      { FE-C Page 51 — Track Resistance
        Grade: unsigned 16-bit, units 0.01%, offset +200.00%
        Value = (Grade% + 200) * 100; range 0..40000 }
      FECGrade := Round((Grade + 200.0) * 100);
      if FECGrade < 0 then FECGrade := 0;
      if FECGrade > 40000 then FECGrade := 40000;
      Page[0] := 51; { Page 51 = Track Resistance }
      Page[1] := $FF; Page[2] := $FF; Page[3] := $FF;
      Page[4] := $FF;
      Page[5] := Lo(Word(FECGrade)); Page[6] := Hi(Word(FECGrade));
      Page[7] := $FF;
      Result := WriteFECPage(FFECWriteChar, FFECChannel, Page);
    end
    else if FHasFTMS then
      Result := inherited SetSimulation(Grade, WindSpeed, RiderWeight, BikeWeight);
  except
    on E: Exception do
      Logger.Error('[WinRT] SetSimulation: ' + E.ClassName + ': ' + E.Message);
  end;
  Logger.Debug('[WinRT] SetSimulation(grade=' + FormatFloat('0.0', Grade) +
    '% wind=' + FormatFloat('0.0', WindSpeed) + ') -> ' + BoolToStr(Result, True));
end;

function TWinRTBLESession.Start: Boolean;
begin
  Result := False;
  if FConnectionState <> csConnected then Exit;
  if FHasFEC then begin Result := True; Exit; end; { FE-C: always running }
  if not FHasFTMS then Exit;
  Result := inherited Start;
  Logger.Debug(Format('[WinRT] Start → %s', [BoolToStr(Result, True)]));
end;

function TWinRTBLESession.Stop: Boolean;
begin
  Result := False;
  if FConnectionState <> csConnected then Exit;
  if FHasFEC then Exit(SetTargetPower(0));
  if not FHasFTMS then Exit;
  Result := inherited Stop;
  Logger.Debug(Format('[WinRT] Stop → %s', [BoolToStr(Result, True)]));
end;

function TWinRTBLESession.Pause: Boolean;
begin
  Result := False;
  if FConnectionState <> csConnected then Exit;
  if FHasFEC then Exit(SetTargetPower(0));
  if not FHasFTMS then Exit;
  Result := inherited Pause;
  Logger.Debug(Format('[WinRT] Pause → %s', [BoolToStr(Result, True)]));
end;

function TWinRTBLESession.Reset: Boolean;
begin
  Result := False;
  if FConnectionState <> csConnected then Exit;
  if not FHasFTMS then Exit;
  Result := inherited Reset;
  Logger.Debug(Format('[WinRT] Reset → %s', [BoolToStr(Result, True)]));
end;

{ ═══════════════════════════════════════════════════════════════════
  TWinRTBLEProvider
  ═══════════════════════════════════════════════════════════════════ }

constructor TWinRTBLEProvider.Create;
begin
  inherited;
  FScannedCount := 0;
  FScanStopping := False;
  FScannedLock := SyncObjs.TCriticalSection.Create;
end;

destructor TWinRTBLEProvider.Destroy;
begin
  FreeAndNil(FScannedLock);
  inherited;
end;

class function TWinRTBLEProvider.TransportType: TTransportType;
begin
  Result := ttBLE;
end;

function TWinRTBLEProvider.AdapterDisplayName: string;
begin
  // WinRT BLE-stack не даёт удобного API для получения friendly-name
  // локального Bluetooth-радио (это требует SetupAPI/WMI запросов и
  // overhead). Используем generic-имя — этого достаточно для UI label
  // toggle-кнопки, и стабильно между запусками для settings ключа.
  Result := 'Bluetooth';
end;

function TWinRTBLEProvider.AdapterKey: string;
begin
  Result := 'Bluetooth';
end;

procedure TWinRTBLEProvider.AddScanResult(const AName, AAddr: string; ARSSI: Int16);
var
  I: Integer;
begin
  FScannedLock.Enter;
  try
    for I := 0 to FScannedCount - 1 do
      if SameText(FScanned[I].Address, AAddr) then
      begin
        if (AName <> '') and (FScanned[I].Name = '') then
          FScanned[I].Name := AName;
        FScanned[I].RSSI := ARSSI;
        Exit;
      end;
    if FScannedCount >= Length(FScanned) then
      SetLength(FScanned, FScannedCount + 8);
    FScanned[FScannedCount].Name := AName;
    FScanned[FScannedCount].Address := AAddr;
    FScanned[FScannedCount].RSSI := ARSSI;
    Inc(FScannedCount);
  finally
    FScannedLock.Leave;
  end;
end;

procedure TWinRTBLEProvider.StartScan;
var
  Watcher: PIUnk;
  ClsName: HSTRING;
  HR: HRESULT;
  Token: TEvtToken;
  UD: PScanUD;
  Del: PDelegate;
  J, SnapCount, ElapsedMs: Integer;
  DevInfo: TDeviceInfo;
  Snap: array of TScannedDev;
const
  POLL_INTERVAL_MS = 500;
  RESCAN_INTERVAL_MS = 30000; { reset scan state every 30 sec for re-discovery }
begin
  if not WinRTBLEAvailable then Exit;

  _RoInit(1);

  FScannedLock.Enter;
  try FScannedCount := 0; FLastReported := 0; finally FScannedLock.Leave; end;

  ClsName := HS('Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher');
  Watcher := nil;
  HR := _RoActivate(ClsName, Watcher);
  _HDelete(ClsName);
  if (HR <> S_OK) or (Watcher = nil) then
  begin
    Logger.Error(Format('[WinRT] Create watcher failed: $%.8X', [HR]));
    Exit;
  end;

  try
    TVtPutI(VT(Watcher)^[12])(Watcher, 1);

    UD := GetMem(SizeOf(TScanUD));
    UD^.Prov := Self;
    Del := MkDel(IID_ReceivedHandler, @Scan_Invoke, UD);
    Token.Value := 0;
    HR := TVtAddHandler(VT(Watcher)^[19])(Watcher, Del, Token);
    if HR <> S_OK then
      Logger.Warning(Format('[WinRT] add_Received failed: $%.8X', [HR]));

    Logger.Info('[WinRT] === CONTINUOUS SCAN START ===');
    FScanStopping := False;
    FLastReported := 0;
    ElapsedMs := 0;
    TVtNoArg(VT(Watcher)^[17])(Watcher);

    while not FScanStopping do
    begin
      Sleep(POLL_INTERVAL_MS);
      Inc(ElapsedMs, POLL_INTERVAL_MS);

      { Periodic reset: allow re-discovery of lost devices }
      if ElapsedMs >= RESCAN_INTERVAL_MS then
      begin
        Logger.Info('[WinRT] --- scan reset for re-discovery ---');
        FScannedLock.Enter;
        try
          FScannedCount := 0;
          FLastReported := 0;
        finally
          FScannedLock.Leave;
        end;
        ElapsedMs := 0;
      end;

      { Snapshot new entries }
      SnapCount := 0;
      FScannedLock.Enter;
      try
        SnapCount := FScannedCount - FLastReported;
        if SnapCount > 0 then
        begin
          SetLength(Snap, SnapCount);
          for J := 0 to SnapCount - 1 do
            Snap[J] := FScanned[FLastReported + J];
          FLastReported := FScannedCount;
        end;
      finally
        FScannedLock.Leave;
      end;

      { Report all found devices — service layer handles dedup }
      for J := 0 to SnapCount - 1 do
      begin
        DevInfo := Default(TDeviceInfo);
        if Snap[J].Name <> '' then
          DevInfo.Name := Snap[J].Name
        else
          DevInfo.Name := 'BLE ' + Snap[J].Address;
        DevInfo.Address := Snap[J].Address;
        DevInfo.TransportType := ttBLE;
        DevInfo.ProviderName := 'WinRT';
        DevInfo.RSSI := Snap[J].RSSI;

        if Assigned(OnDeviceFound) then
          OnDeviceFound(DevInfo);
      end;
    end;

    TVtNoArg(VT(Watcher)^[18])(Watcher);
    TVtRemHandler(VT(Watcher)^[20])(Watcher, Token);
    Del^.UserData := nil;
    Del_Release(Del);
    FreeMem(UD);

    Logger.Info('[WinRT] === CONTINUOUS SCAN STOP ===');
  finally
    SafeClose(Watcher);
  end;
end;

procedure TWinRTBLEProvider.StopScan;
begin
  FScanStopping := True;
end;

function TWinRTBLEProvider.CreateSession(const AAddress: string;
  const AFriendlyName: string): TTransportSession;
begin
  Result := TWinRTBLESession.Create(AAddress, AFriendlyName);
end;

{ ── PairingRequested handler: auto-accept all ceremony types ──
  Runs on WinRT/RPC thread. No managed types (AnsiString, Format, etc).
  Stores results in GPairLog for the calling thread to read+log. }

function PairingReq_Invoke(Self: PDelegate;
  Sender: PIUnk; Args: PIUnk): HRESULT; stdcall;
var
  HR: HRESULT;
  PairingKind: Cardinal;
  PinHS: HSTRING;
begin
  Result := S_OK;
  if Args = nil then Exit;

  { Use Args directly — it IS IDevicePairingRequestedEventArgs,
    QI may return a different pointer with misaligned vtable. }

  { get_PairingKind — vtable[7] }
  PairingKind := 0;
  TVtGetU32(VT(Args)^[7])(Args, PairingKind);

  HR := S_OK;
  case PairingKind of
    0: HR := TVtNoArg(VT(Args)^[8])(Args);             { None → Accept() anyway }
    1: HR := TVtNoArg(VT(Args)^[8])(Args);             { ConfirmOnly → Accept() }
    2: HR := TVtNoArg(VT(Args)^[8])(Args);             { DisplayPin → Accept() }
    4: begin                                             { ProvidePin → AcceptWithPin }
         PinHS := HS('000000');
         HR := TVtPutCompleted(VT(Args)^[9])(Args, PIUnk(PinHS));
         _HDelete(PinHS);
       end;
    8: HR := TVtNoArg(VT(Args)^[8])(Args);             { ConfirmPinMatch → Accept() }
  else
    HR := TVtNoArg(VT(Args)^[8])(Args);                { Unknown → Accept() }
  end;

  { Store for caller to log (no managed types — thread-safe) }
  GPairLog.Kind := PairingKind;
  GPairLog.AcceptHR := HR;
  GPairLog.Called := True;
end;

function TWinRTBLEProvider.PairDevice(const AAddress: string): Boolean;
var
  Factory, AsyncOp, Dev, Dev2, DevInfoObj, DevInfo2: PIUnk;
  PairingObj, Pairing2, CustomPair, PairRes: PIUnk;
  BgWatcher: PIUnk;
  ClsName, BgClsName: HSTRING;
  HR: HRESULT;
  Addr: UInt64;
  IsPaired, CanPair, PairStatus: Cardinal;
  Del: PDelegate;
  ReqToken: TEvtToken;
begin
  Result := False;
  if not WinRTBLEAvailable then Exit;

  Addr := StrToMac(AAddress);
  if Addr = 0 then Exit;

  Logger.Info(Format('[WinRT] PairDevice: %s', [AAddress]));

  ClsName := HS('Windows.Devices.Bluetooth.BluetoothLEDevice');
  Factory := nil;
  HR := _RoGetFactory(ClsName, IID_IDeviceStatics, Factory);
  _HDelete(ClsName);
  if (HR <> S_OK) or (Factory = nil) then Exit;

  try
    { Background watcher }
    BgWatcher := nil;
    BgClsName := HS('Windows.Devices.Bluetooth.Advertisement.BluetoothLEAdvertisementWatcher');
    _RoActivate(BgClsName, BgWatcher);
    _HDelete(BgClsName);
    if BgWatcher <> nil then
    begin
      TVtPutI(VT(BgWatcher)^[12])(BgWatcher, 1);
      TVtNoArg(VT(BgWatcher)^[17])(BgWatcher);
    end;

    AsyncOp := nil;
    TVtFromAddr(VT(Factory)^[7])(Factory, Addr, AsyncOp);
    Dev := AsyncWaitObj(AsyncOp, IID_CH_Device, 15000);
    SafeRelease(AsyncOp);

    if BgWatcher <> nil then
    begin TVtNoArg(VT(BgWatcher)^[18])(BgWatcher); SafeClose(BgWatcher); end;

    if Dev = nil then
    begin Logger.Warning('[WinRT] PairDevice: device not found'); Exit; end;

    try
      Dev2 := nil;
      if QI(Dev, IID_IDevice2, Dev2) <> S_OK then Exit;
      try
        DevInfoObj := nil;
        TVtGetObj(VT(Dev2)^[6])(Dev2, DevInfoObj);
        if DevInfoObj = nil then Exit;
        try
          DevInfo2 := nil;
          if QI(DevInfoObj, IID_IDeviceInfo2, DevInfo2) <> S_OK then Exit;
          try
            PairingObj := nil;
            TVtGetObj(VT(DevInfo2)^[7])(DevInfo2, PairingObj);
            if PairingObj = nil then Exit;
            try
              { Check if already paired }
              IsPaired := 0;
              TVtGetU32(VT(PairingObj)^[6])(PairingObj, IsPaired);
              if (IsPaired and $FF) <> 0 then
              begin
                Logger.Info('[WinRT] PairDevice: already paired');
                Result := True;
                Exit;
              end;

              CanPair := 0;
              TVtGetU32(VT(PairingObj)^[7])(PairingObj, CanPair);
              if (CanPair and $FF) = 0 then
              begin Logger.Warning('[WinRT] PairDevice: cannot pair'); Exit; end;

              { Get Custom pairing interface }
              Pairing2 := nil;
              if QI(PairingObj, IID_IPairing2, Pairing2) <> S_OK then
              begin Logger.Warning('[WinRT] PairDevice: no IDeviceInformationPairing2'); Exit; end;
              try
                CustomPair := nil;
                TVtGetObj(VT(Pairing2)^[7])(Pairing2, CustomPair); { get_Custom }
                if CustomPair = nil then
                begin Logger.Warning('[WinRT] PairDevice: get_Custom nil'); Exit; end;
                try
                  { Register PairingRequested handler that calls Accept() }
                  Del := MkDel(IID_PairingReqHandler, @PairingReq_Invoke, nil);
                  ReqToken.Value := 0;
                  HR := TVtAddHandler(VT(CustomPair)^[9])(CustomPair, Del, ReqToken);
                  if HR <> S_OK then
                    Logger.Warning(Format('[WinRT] add_PairingRequested failed: $%.8X', [HR]));

                  { Custom.PairAsync(AllKinds, ProtectionLevel=None) }
                  Logger.Info('[WinRT] PairDevice: Custom.PairAsync(AllKinds=$0F, ProtectionLevel=None)...');
                  GPairLog.Called := False;
                  AsyncOp := nil;
                  TVtCallMode2(VT(CustomPair)^[7])(CustomPair, $0F, 0, AsyncOp);
                  if AsyncOp <> nil then
                  begin
                    PairRes := AsyncWaitObjPoll(AsyncOp, 30000);
                    SafeRelease(AsyncOp);
                    LogPairRequestResult;
                    if PairRes <> nil then
                    begin
                      PairStatus := $FF;
                      TVtGetU32(VT(PairRes)^[6])(PairRes, PairStatus);
                      Logger.Info(Format('[WinRT] PairDevice: Custom result=%d (0=Paired)', [PairStatus]));
                      Result := (PairStatus = 0) or (PairStatus = 3);
                      SafeRelease(PairRes);
                    end;
                  end;

                  { Cleanup handler }
                  TVtRemHandler(VT(CustomPair)^[10])(CustomPair, ReqToken);
                  Del^.UserData := nil;
                  Del_Release(Del);
                finally
                  SafeRelease(CustomPair);
                end;
              finally
                SafeRelease(Pairing2);
              end;
            finally
              SafeRelease(PairingObj);
            end;
          finally
            SafeRelease(DevInfo2);
          end;
        finally
          SafeRelease(DevInfoObj);
        end;
      finally
        SafeRelease(Dev2);
      end;
    finally
      SafeClose(Dev);
    end;
  finally
    SafeRelease(Factory);
  end;
end;

{ ═══════════════════════════════════════════════════════════════════ }

var
  GChecked: Boolean = False;
  GAvail: Boolean = False;

function WinRTBLEAvailable: Boolean;
var
  HR: HRESULT;
begin
  if not GChecked then
  begin
    GChecked := True;
    if not LoadCB then
      Logger.Info('[WinRT] combase.dll not available')
    else begin
      HR := _RoInit(1); { RO_INIT_MULTITHREADED }
      { S_OK=0, S_FALSE=1 (already initialized), RPC_E_CHANGED_MODE=$80010106 — all OK }
      if (HR = S_OK) or (HR = 1) or (HR = HRESULT($80010106)) then
      begin
        GAvail := True;
        Logger.Info('[WinRT] Pure Pascal WinRT BLE available');
      end else
        Logger.Warning(Format('[WinRT] RoInitialize failed: $%.8X', [HR]));
    end;
  end;
  Result := GAvail;
end;

{$ELSE}

function WinRTBLEAvailable: Boolean;
begin
  Result := False;
end;

{$ENDIF}

end.
