{ GameDeviceManager — транспорт-агностичный менеджер устройств.

  Хранит список TTransportProvider-ов (BLE, ANT+, Ethernet, ...),
  управляет сессиями TTransportSession, реализует паттерн
  «активное устройство» для обратной совместимости.

  Использование:
    Manager := TDeviceManager.Create;
    Manager.RegisterProvider(TBLETransportProvider.Create);
    Manager.OnDeviceFound := @MyDeviceFoundHandler;
    Manager.StartScan;            // сканирует через все провайдеры
    Manager.Connect(Address);     // создаёт сессию через подходящий провайдер
}
unit GameDeviceManager;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fgl, syncobjs,
  TrainerData, GameTransportBase, GameTrainerControl;

type
  TTransportProviderList = specialize TFPGObjectList<TTransportProvider>;
  TTransportSessionList  = specialize TFPGObjectList<TTransportSession>;

  TPendingTrainerPacket = record
    Device: TDeviceInfo;
    Data: TTrainerDataRecord;
  end;

  { Колбэки менеджера }
  TOnManagerDeviceDataReceived = procedure(const Device: TDeviceInfo;
    const Data: TTrainerDataRecord) of object;
  TOnManagerConnectionChanged = procedure(const Device: TDeviceInfo;
    State: TConnectionState; const Message: string) of object;

  { TDeviceManager }

  TDeviceProviderEntry = record
    Address: string;
    ProviderIndex: Integer;
  end;

  TDeviceManager = class;

  { Preserve callback provenance without changing the public provider event.
    Two BLE backends may enumerate different peripherals of the same type. }
  TProviderDiscoverySink = class
    Owner: TDeviceManager;
    Provider: TTransportProvider;
    procedure Found(const Device: TDeviceInfo);
  end;

  { Worker thread — executes scan and connect off the main thread }
  TDeviceWorkCmd = (dwcScan, dwcConnect);

  TDeviceWorkItem = record
    Cmd: TDeviceWorkCmd;
    Address: string;
    FriendlyName: string;
    ProviderName: string;
  end;

  TDeviceWorkerThread = class(TThread)
  private
    FOwner: TDeviceManager;
    FQueueLock: TCriticalSection;
    FQueue: array of TDeviceWorkItem;
    FQueueCount: Integer;
    FWakeEvent: PRTLEvent;
  protected
    procedure Execute; override;
    procedure DoScan;
  public
    constructor Create(AOwner: TDeviceManager);
    destructor Destroy; override;
    procedure PostCommand(const AItem: TDeviceWorkItem);
  end;

  { Connect thread — runs a single connection attempt without blocking scan }
  TConnectThread = class(TThread)
  private
    FOwner: TDeviceManager;
    FAddress: string;
    FFriendlyName: string;
    FProviderName: string;
    FDisconnectRequested: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TDeviceManager;
      const AAddress, AFriendlyName, AProviderName: string;
      ADisconnect: Boolean = False);
  end;

  { Scan-start thread — однопроцессный, делает StartScan на одном провайдере
    и сразу самоуничтожается. Используется когда нужно стартовать blocking-
    провайдер не из worker thread (например, при toggle-on из UI). DoScan
    использует другой механизм (см. реализацию). }
  TProviderScanThread = class(TThread)
  private
    FProvider: TTransportProvider;
  protected
    procedure Execute; override;
  public
    constructor Create(AProvider: TTransportProvider);
  end;

  TDeviceManager = class
  private
    FLock: TCriticalSection;
    FProviders: TTransportProviderList;
    FDiscoverySinks: specialize TFPGObjectList<TProviderDiscoverySink>;
    FSessions: TTransportSessionList;
    FDestroying: Boolean;
    FActiveDeviceAddress: string;
    FWorker: TDeviceWorkerThread;
    FConnectThreads: specialize TFPGObjectList<TConnectThread>;
    FScanThreads: specialize TFPGObjectList<TProviderScanThread>;

    { Addresses currently being connected (to prevent duplicate connects) }
    FConnectingLock: TCriticalSection;
    FConnectingAddrs: TStringList;

    { Pending callbacks from worker thread → main thread }
    FPendingDevices: array of TDeviceInfo;
    FPendingDeviceCount: Integer;
    FPendingConnections: array of record
      Device: TDeviceInfo;
      State: TConnectionState;
      Message: string;
    end;
    FPendingConnectionCount: Integer;
    FPendingData: array of TPendingTrainerPacket;
    FPendingDataCount: Integer;


    { Map device address → provider that found it }
    FDeviceProviderMap: array of TDeviceProviderEntry;
    FDeviceProviderCount: Integer;

    { Старый API (совместимость): только активное устройство }
    FOnDataReceived: TOnDataReceived;
    FOnConnectionChanged: TOnConnectionChanged;
    FOnDeviceFound: TOnDeviceFound;

    { Новый API: все устройства }
    FOnDeviceDataReceived: TOnManagerDeviceDataReceived;
    FOnDeviceConnectionChanged: TOnManagerConnectionChanged;

    procedure RegisterDeviceProvider(const AAddress: string; AProvider: TTransportProvider);
    procedure FlushPendingDeviceFound;
    procedure FlushPendingConnectionChanged;
    procedure FlushPendingData;
    function FindSessionIndex(const AAddress: string): Integer;
    function GetActiveSession: TTransportSession;
    function FindProviderForAddress(const AAddress: string): TTransportProvider;

    function GetConnectionState: TConnectionState;
    function GetConnectedDevice: TDeviceInfo;
    function GetTrainerFeatures: TTrainerFeatures;
    function GetHasControl: Boolean;
    function PostControl(const AAddress: string; Kind: TTrainerCommandKind;
      Value: Single = 0; Wind: Single = 0; RiderWeight: Single = 75;
      BikeWeight: Single = 10): Boolean;

    { Колбэки провайдера и сессий }
    procedure HandleProviderDeviceFound(AProvider: TTransportProvider;const Device: TDeviceInfo);
    procedure HandleSessionDataReceived(ASession: TTransportSession;
      const Data: TTrainerDataRecord);
    procedure HandleSessionConnectionChanged(ASession: TTransportSession;
      State: TConnectionState; const Message: string);
  public
    constructor Create;
    destructor Destroy; override;

    { --- Регистрация провайдеров транспорта --- }
    procedure RegisterProvider(AProvider: TTransportProvider);
    function ProviderCount: Integer;
    function Provider(AIndex: Integer): TTransportProvider;

    { --- Включение/выключение adapter'а (физического устройства).
          AKey формируется как "<TransportType>:<Provider.AdapterKey>".
          Состояние сохраняется в Settings и применяется немедленно:
          включение → StartScan на провайдере, выключение → StopScan. --- }
    function IsProviderEnabled(AProvider: TTransportProvider): Boolean;
    procedure SetProviderEnabled(AProvider: TTransportProvider; AEnabled: Boolean);

    { --- Сканирование (через все провайдеры) --- }
    procedure StartScan;
    procedure StopScan;
    function IsSessionAlive(const AAddress: string): Boolean;
    { Sessions remain owned by the manager until shutdown. Used by the main
      thread after a connection notification, including reconnecting a FIT. }
    function GetSession(const AAddress: string): TTransportSession;
    procedure CancelControl(const AAddress: string);
    procedure PollPendingChanges;  { call from main thread Update to flush missed Queue events }

    { --- Подключение/отключение --- }
    procedure Connect(const AAddress: string;
      const AFriendlyName: string = '';
      const AProviderName: string = '');
    procedure Disconnect; overload;
    procedure Disconnect(const AAddress: string); overload;
    procedure DisconnectAll;

    { --- Активное устройство --- }
    procedure SetActiveDevice(const AAddress: string);
    function IsConnected(const AAddress: string): Boolean;
    function ConnectedCount: Integer;

    { --- Получение данных об устройстве --- }
    function GetDeviceInfo(const AAddress: string): TDeviceInfo;
    function GetDeviceTrainerFeatures(const AAddress: string): TTrainerFeatures;
    function GetDeviceLastData(const AAddress: string): TTrainerDataRecord;
    function GetDeviceConnectionState(const AAddress: string): TConnectionState;

    { --- Команды управления (активное устройство) --- }
    function RequestControl: Boolean; overload;
    function SetTargetPower(Watts: Word): Boolean; overload;
    function SetResistanceLevel(Level: Byte): Boolean; overload;
    function SetIncline(InclinePercent: Single): Boolean; overload;
    function SetSimulation(Grade: Single; WindSpeed: Single = 0;
      RiderWeight: Single = 75; BikeWeight: Single = 10): Boolean; overload;
    function Start: Boolean; overload;
    function Stop: Boolean; overload;
    function Pause: Boolean; overload;
    function Reset: Boolean; overload;

    { --- Команды управления (по адресу) --- }
    function RequestControl(const AAddress: string): Boolean; overload;
    function SetTargetPower(const AAddress: string; Watts: Word): Boolean; overload;
    function SetResistanceLevel(const AAddress: string; Level: Byte): Boolean; overload;
    function SetIncline(const AAddress: string; InclinePercent: Single): Boolean; overload;
    function SetSimulation(const AAddress: string; Grade: Single;
      WindSpeed: Single = 0; RiderWeight: Single = 75;
      BikeWeight: Single = 10): Boolean; overload;
    function Start(const AAddress: string): Boolean; overload;
    function Stop(const AAddress: string): Boolean; overload;
    function Pause(const AAddress: string): Boolean; overload;
    function Reset(const AAddress: string): Boolean; overload;

    { --- Свойства --- }
    property ActiveDeviceAddress: string read FActiveDeviceAddress;

    { Старый API: активное устройство }
    property ConnectionState: TConnectionState read GetConnectionState;
    property ConnectedDevice: TDeviceInfo read GetConnectedDevice;
    property TrainerFeatures: TTrainerFeatures read GetTrainerFeatures;
    property HasControl: Boolean read GetHasControl;

    property OnDataReceived: TOnDataReceived
      read FOnDataReceived write FOnDataReceived;
    property OnConnectionChanged: TOnConnectionChanged
      read FOnConnectionChanged write FOnConnectionChanged;
    property OnDeviceFound: TOnDeviceFound
      read FOnDeviceFound write FOnDeviceFound;

    { Новый API: все устройства }
    property OnDeviceDataReceived: TOnManagerDeviceDataReceived
      read FOnDeviceDataReceived write FOnDeviceDataReceived;
    property OnDeviceConnectionChanged: TOnManagerConnectionChanged
      read FOnDeviceConnectionChanged write FOnDeviceConnectionChanged;

    { Tick — должен дёргаться из main thread'а на каждом кадре. Сливает
      отложенные события (DeviceFound, ConnectionChanged) подписчикам.
      В норме этим занимается TThread.Queue + CheckSynchronize, но в
      Castle Engine очередь TThread.Queue не прокручивается стандартным
      механизмом — нужен явный вызов. Owner подписывает Tick на
      ApplicationProperties.OnUpdate. }
    procedure Tick;
  end;

implementation

uses
  {$IFDEF WINDOWS}Windows,{$ENDIF} DebugLog, AppSettings, GameThreadWatch;

{$IFDEF WINDOWS}
function CoInitializeEx(pvReserved: Pointer; dwCoInit: DWORD): HRESULT; stdcall; external 'ole32.dll';
procedure CoUninitialize; stdcall; external 'ole32.dll';
{$ENDIF}

{ TDeviceManager }

procedure TProviderDiscoverySink.Found(const Device: TDeviceInfo);
begin
  Owner.HandleProviderDeviceFound(Provider,Device);
end;

constructor TDeviceManager.Create;
begin
  inherited Create;
  FLock := syncobjs.TCriticalSection.Create;
  FProviders := TTransportProviderList.Create(True);   // owns providers
  FDiscoverySinks := specialize TFPGObjectList<TProviderDiscoverySink>.Create(True);
  FSessions := TTransportSessionList.Create(True);     // owns sessions
  FDestroying := False;
  FActiveDeviceAddress := '';
  FDeviceProviderCount := 0;
  FPendingDeviceCount := 0;
  FPendingConnectionCount := 0;
  FPendingDataCount := 0;

  FConnectThreads := specialize TFPGObjectList<TConnectThread>.Create(True);
  FScanThreads := specialize TFPGObjectList<TProviderScanThread>.Create(True);
  FWorker := TDeviceWorkerThread.Create(Self);
  FConnectingLock := syncobjs.TCriticalSection.Create;
  FConnectingAddrs := TStringList.Create;
  FConnectingAddrs.CaseSensitive := False;
  FConnectingAddrs.Sorted := True;
  FConnectingAddrs.Duplicates := dupIgnore;
end;

destructor TDeviceManager.Destroy;
var I: Integer;
begin
  FDestroying := True;
  StopScan;
  for I := 0 to FConnectThreads.Count - 1 do
    FConnectThreads[I].FDisconnectRequested := True;
  FLock.Enter;
  try
    for I := 0 to FSessions.Count - 1 do FSessions[I].PrepareDisconnect;
  finally FLock.Leave end;
  if Assigned(FWorker) then
  begin
    FWorker.Terminate;
    RTLEventSetEvent(FWorker.FWakeEvent);
    { A scan may have entered StartScan just after the first StopScan. }
    while not FWorker.Finished do
    begin
      StopScan;
      Sleep(20);
    end;
    FWorker.WaitFor;
    FreeAndNil(FWorker);
  end;
  for I := 0 to FScanThreads.Count - 1 do
  begin
    while not FScanThreads[I].Finished do
    begin
      FScanThreads[I].FProvider.StopScan;
      Sleep(20);
    end;
    FScanThreads[I].WaitFor;
  end;
  for I := 0 to FConnectThreads.Count - 1 do FConnectThreads[I].WaitFor;
  FreeAndNil(FScanThreads);
  FreeAndNil(FConnectThreads);
  for I := 0 to FSessions.Count - 1 do FSessions[I].ShutdownControl;
  for I := 0 to FSessions.Count - 1 do FSessions[I].Disconnect;
  FreeAndNil(FSessions);
  FreeAndNil(FProviders);
  { Providers drain their native callbacks before their sinks are destroyed. }
  FreeAndNil(FDiscoverySinks);
  FreeAndNil(FConnectingAddrs);
  FreeAndNil(FConnectingLock);
  FreeAndNil(FLock);
  inherited;
end;

{ --- Регистрация --- }

procedure TDeviceManager.RegisterProvider(AProvider: TTransportProvider);
var Sink:TProviderDiscoverySink;
begin
  if AProvider=nil then Exit;
  Sink:=TProviderDiscoverySink.Create;
  Sink.Owner:=Self;Sink.Provider:=AProvider;
  try
    FLock.Enter;
    try
      FDiscoverySinks.Add(Sink);
      try FProviders.Add(AProvider);
      except FDiscoverySinks.Extract(Sink);raise end;
      AProvider.OnDeviceFound:=@Sink.Found;
      Sink:=nil;
    finally FLock.Leave end;
  finally Sink.Free end;
end;

function TDeviceManager.ProviderCount: Integer;
begin
  Result := FProviders.Count;
end;

function TDeviceManager.Provider(AIndex: Integer): TTransportProvider;
begin
  if (AIndex < 0) or (AIndex >= FProviders.Count) then
    Result := nil
  else
    Result := FProviders[AIndex];
end;

function TDeviceManager.IsProviderEnabled(AProvider: TTransportProvider): Boolean;
var
  Key: string;
begin
  if AProvider = nil then Exit(False);
  if AProvider.TransportType = ttSim then Exit(Settings.GetSimulationEnabled);
  Key := TRANSPORT_TYPE_NAMES[AProvider.TransportType] + ':' + AProvider.AdapterKey;
  Result := Settings.GetAdapterEnabled(Key);
end;

procedure TDeviceManager.SetProviderEnabled(AProvider: TTransportProvider;
  AEnabled: Boolean);
var
  Key: string;
  ScanThread: TProviderScanThread;
begin
  if AProvider = nil then Exit;
  Key := TRANSPORT_TYPE_NAMES[AProvider.TransportType] + ':' + AProvider.AdapterKey;
  Settings.SetAdapterEnabled(Key, AEnabled);

  if AEnabled then
  begin
    // Включение: запустить scan. ANT non-blocking — inline. Прочие
    // (потенциально blocking) — в отдельном thread'е чтобы не блокировать
    // UI thread, из которого вызвалось переключение.
    if AProvider.TransportType = ttANTPlus then
      AProvider.StartScan
    else
    begin
      ScanThread := TProviderScanThread.Create(AProvider);
      FScanThreads.Add(ScanThread);
      ScanThread.Start;
    end;
  end
  else
    AProvider.StopScan;
end;

{ --- Сканирование --- }

procedure TDeviceManager.StartScan;
var
  Item: TDeviceWorkItem;
begin
  if FDestroying then Exit;
  Item.Cmd := dwcScan;
  Item.Address := '';
  Item.FriendlyName := '';
  FWorker.PostCommand(Item);
end;

procedure TDeviceManager.StopScan;
var
  I: Integer;
begin
  for I := 0 to FProviders.Count - 1 do
    FProviders[I].StopScan;
end;

function TDeviceManager.IsSessionAlive(const AAddress: string): Boolean;
var
  S: TTransportSession;
begin
  Result := False;
  FLock.Enter;
  try
    S := GetSession(AAddress);
  finally
    FLock.Leave;
  end;
  { Call IsConnectionAlive OUTSIDE lock — it may do WinRT COM calls }
  if Assigned(S) then
  begin
    { Do not inspect a COM handle while the connection worker releases it,
      and do not make the UI wait behind a GATT write. }
    if not S.TryLockTransport then Exit(S.ConnectionState = csConnected);
    try Result := S.IsConnectionAlive;
    finally S.UnlockTransport end;
  end;
end;

procedure TDeviceManager.PollPendingChanges;
begin
  if FPendingConnectionCount > 0 then
    FlushPendingConnectionChanged;
  if FPendingDataCount > 0 then
    FlushPendingData;
end;

{ --- Поиск провайдера и сессий --- }

function TDeviceManager.FindSessionIndex(const AAddress: string): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to FSessions.Count - 1 do
    if SameText(FSessions[I].DeviceInfo.Address, AAddress) then
      Exit(I);
end;

function TDeviceManager.GetSession(const AAddress: string): TTransportSession;
var Idx: Integer;
begin
  Result := nil;
  if AAddress = '' then Exit;
  FLock.Enter;
  try
    Idx := FindSessionIndex(AAddress);
    if Idx >= 0 then Result := FSessions[Idx];
  finally FLock.Leave end;
end;

function TDeviceManager.GetActiveSession: TTransportSession;
begin
  Result := GetSession(FActiveDeviceAddress);
end;

function TDeviceManager.FindProviderForAddress(
  const AAddress: string): TTransportProvider;
var
  I: Integer;
begin
  Result := nil;
  FLock.Enter;
  try
  if FProviders.Count = 0 then Exit;

  { Look up from scan-time map }
  for I := 0 to FDeviceProviderCount - 1 do
    if SameText(FDeviceProviderMap[I].Address, AAddress) then
    begin
      if FDeviceProviderMap[I].ProviderIndex < FProviders.Count then
        Result := FProviders[FDeviceProviderMap[I].ProviderIndex];
      if Assigned(Result) then Exit;
    end;

  { Fallback: first provider }
  Result := FProviders[0];
  finally FLock.Leave; end;
end;

procedure TDeviceManager.RegisterDeviceProvider(const AAddress: string;
  AProvider: TTransportProvider);
var
  I, ProvIdx: Integer;
begin
  ProvIdx := -1;
  for I := 0 to FProviders.Count - 1 do
    if FProviders[I] = AProvider then begin ProvIdx := I; Break; end;
  if ProvIdx < 0 then Exit;

  { Update existing or add new }
  for I := 0 to FDeviceProviderCount - 1 do
    if SameText(FDeviceProviderMap[I].Address, AAddress) then
    begin
      FDeviceProviderMap[I].ProviderIndex := ProvIdx;
      Exit;
    end;

  if FDeviceProviderCount >= Length(FDeviceProviderMap) then
    SetLength(FDeviceProviderMap, FDeviceProviderCount + 16);
  FDeviceProviderMap[FDeviceProviderCount].Address := AAddress;
  FDeviceProviderMap[FDeviceProviderCount].ProviderIndex := ProvIdx;
  Inc(FDeviceProviderCount);
end;

{ --- Подключение/отключение --- }

procedure TDeviceManager.Connect(const AAddress: string;
  const AFriendlyName: string;
  const AProviderName: string);
var
  S: TTransportSession;
  AlreadyConnecting: Boolean;
  Worker: TConnectThread;
begin
  if FDestroying then Exit;
  if AAddress = '' then Exit;

  { A discovered power/HR sensor must not change the selected controller. }

  { If session already exists and connected — nothing to do }
  S := GetSession(AAddress);
  if Assigned(S) and (S.ConnectionState = csConnected) then Exit;

  { Check if already connecting }
  FConnectingLock.Enter;
  try
    AlreadyConnecting := FConnectingAddrs.IndexOf(AAddress) >= 0;
    if not AlreadyConnecting then
      FConnectingAddrs.Add(AAddress);
  finally
    FConnectingLock.Leave;
  end;

  if AlreadyConnecting then
  begin
    Logger.Debug('[DeviceManager] Connect skipped (already in progress): ' + AAddress);
    Exit;
  end;

  { Spawn a dedicated connect thread — does not block scan }
  Logger.Info('[DeviceManager] Spawning connect thread: ' + AAddress);
  Worker := TConnectThread.Create(Self, AAddress, AFriendlyName, AProviderName);
  FConnectThreads.Add(Worker);
  Worker.Start;
end;

procedure TDeviceManager.CancelControl(const AAddress: string);
var S: TTransportSession;
begin
  S := GetSession(AAddress);
  if S <> nil then S.CancelControl;
end;

procedure TDeviceManager.Disconnect;
begin
  Disconnect(FActiveDeviceAddress);
end;

procedure TDeviceManager.Disconnect(const AAddress: string);
var S: TTransportSession; I: Integer; Worker: TConnectThread;
begin
  if FDestroying then Exit;
  S := GetSession(AAddress);
  if S <> nil then S.PrepareDisconnect;
  for I := 0 to FConnectThreads.Count - 1 do
    if (not FConnectThreads[I].Finished) and
      SameText(FConnectThreads[I].FAddress, AAddress) then
    begin
      FConnectThreads[I].FDisconnectRequested := True;
      Exit;
    end;
  if S = nil then Exit;
  FConnectingLock.Enter;
  try FConnectingAddrs.Add(AAddress);
  finally FConnectingLock.Leave end;
  Worker := TConnectThread.Create(Self, AAddress, '', '', True);
  FConnectThreads.Add(Worker);
  Worker.Start;
end;

procedure TDeviceManager.DisconnectAll;
var I: Integer; Addresses: array of string;
begin
  FLock.Enter;
  try
    SetLength(Addresses, FSessions.Count);
    for I := 0 to FSessions.Count - 1 do Addresses[I] := FSessions[I].DeviceInfo.Address;
  finally FLock.Leave end;
  for I := 0 to High(Addresses) do Disconnect(Addresses[I]);
end;

procedure TDeviceManager.SetActiveDevice(const AAddress: string);
begin
  FActiveDeviceAddress := AAddress;
end;

function TDeviceManager.IsConnected(const AAddress: string): Boolean;
var
  S: TTransportSession;
begin
  S := GetSession(AAddress);
  Result := Assigned(S) and (S.ConnectionState = csConnected);
end;

function TDeviceManager.ConnectedCount: Integer;
var
  I: Integer;
begin
  Result := 0;
  FLock.Enter;
  try
    for I := 0 to FSessions.Count - 1 do
      if FSessions[I].ConnectionState = csConnected then Inc(Result);
  finally FLock.Leave; end;
end;

{ --- Получение данных --- }

function TDeviceManager.GetConnectionState: TConnectionState;
var
  S: TTransportSession;
begin
  S := GetActiveSession;
  if Assigned(S) then
    Result := S.ConnectionState
  else
    Result := csDisconnected;
end;

function TDeviceManager.GetConnectedDevice: TDeviceInfo;
var
  S: TTransportSession;
begin
  S := GetActiveSession;
  if Assigned(S) then
    Result := S.DeviceInfo
  else
    Result := Default(TDeviceInfo);
end;

function TDeviceManager.GetTrainerFeatures: TTrainerFeatures;
var
  S: TTransportSession;
begin
  S := GetActiveSession;
  if Assigned(S) then
    Result := S.TrainerFeatures
  else
    Result := Default(TTrainerFeatures);
end;

function TDeviceManager.GetHasControl: Boolean;
var
  S: TTransportSession;
begin
  S := GetActiveSession;
  Result := Assigned(S) and S.HasControl;
end;

function TDeviceManager.GetDeviceInfo(const AAddress: string): TDeviceInfo;
var
  S: TTransportSession;
begin
  S := GetSession(AAddress);
  if Assigned(S) then
    Result := S.DeviceInfo
  else
    Result := Default(TDeviceInfo);
end;

function TDeviceManager.GetDeviceTrainerFeatures(
  const AAddress: string): TTrainerFeatures;
var
  S: TTransportSession;
begin
  S := GetSession(AAddress);
  if Assigned(S) then
    Result := S.TrainerFeatures
  else
    Result := Default(TTrainerFeatures);
end;

function TDeviceManager.GetDeviceLastData(
  const AAddress: string): TTrainerDataRecord;
var
  S: TTransportSession;
begin
  S := GetSession(AAddress);
  if Assigned(S) then
    Result := S.LastData
  else
    Result := Default(TTrainerDataRecord);
end;

function TDeviceManager.GetDeviceConnectionState(
  const AAddress: string): TConnectionState;
var
  S: TTransportSession;
begin
  S := GetSession(AAddress);
  if Assigned(S) then
    Result := S.ConnectionState
  else
    Result := csDisconnected;
end;

{ --- Колбэки --- }

procedure TDeviceManager.HandleProviderDeviceFound(AProvider:TTransportProvider;const Device:TDeviceInfo);
begin
  if FDestroying then Exit;

  { Bind the address to the actual emitter, not its transport type or label.
    The lock is released before Connect calls the provider's CreateSession. }
  FLock.Enter;
  try
    RegisterDeviceProvider(Device.Address,AProvider);

    { Queue for main thread }
    if FPendingDeviceCount >= Length(FPendingDevices) then
      SetLength(FPendingDevices, FPendingDeviceCount + 8);
    FPendingDevices[FPendingDeviceCount] := Device;
    Inc(FPendingDeviceCount);
  finally
    FLock.Leave;
  end;

end;

procedure TDeviceManager.FlushPendingDeviceFound;
var
  Devices: array of TDeviceInfo;
  Count, I: Integer;
begin
  FLock.Enter;
  try
    Count := FPendingDeviceCount;
    SetLength(Devices, Count);
    for I := 0 to Count - 1 do
      Devices[I] := FPendingDevices[I];
    FPendingDeviceCount := 0;
  finally
    FLock.Leave;
  end;

  for I := 0 to Count - 1 do
    if Assigned(FOnDeviceFound) then
    begin
      Logger.Info('[DeviceManager] FlushDeviceFound[' + IntToStr(I) + ']: ' +
        Devices[I].Name + ' (' + Devices[I].Address + ')');
      FOnDeviceFound(Devices[I]);
    end;

  { Also flush connection changes — TThread.Queue may lose them }
  if FPendingConnectionCount > 0 then
    FlushPendingConnectionChanged;
end;

procedure TDeviceManager.HandleSessionDataReceived(
  ASession: TTransportSession; const Data: TTrainerDataRecord);
var
  I: Integer;
  Dev: TDeviceInfo;
begin
  { BLE/ANT notify приходит с воркера. UI (SensorPanel.Refresh) и
    FDevices нельзя трогать оттуда — первый пакет при поиске падал AV. }
  if FDestroying then Exit;
  if ASession = nil then Exit;
  try
    Dev := ASession.DeviceInfo;
  except
    Exit;
  end;

  FLock.Enter;
  try
    I := 0;
    while I < FPendingDataCount do
    begin
      if SameText(FPendingData[I].Device.Address, Dev.Address) then
        Break;
      Inc(I);
    end;
    if I >= FPendingDataCount then
    begin
      if FPendingDataCount >= Length(FPendingData) then
        SetLength(FPendingData, FPendingDataCount + 8);
      I := FPendingDataCount;
      Inc(FPendingDataCount);
    end;
    FPendingData[I].Device := Dev;
    FPendingData[I].Data := Data;
  finally
    FLock.Leave;
  end;
end;

procedure TDeviceManager.FlushPendingData;
var
  Packets: array of TPendingTrainerPacket;
  Count, I: Integer;
begin
  if FDestroying then Exit;
  FLock.Enter;
  try
    Count := FPendingDataCount;
    SetLength(Packets, Count);
    for I := 0 to Count - 1 do
      Packets[I] := FPendingData[I];
    FPendingDataCount := 0;
  finally
    FLock.Leave;
  end;

  for I := 0 to Count - 1 do
  try
    if Assigned(FOnDeviceDataReceived) then
      FOnDeviceDataReceived(Packets[I].Device, Packets[I].Data);
    if SameText(FActiveDeviceAddress, Packets[I].Device.Address) then
      if Assigned(FOnDataReceived) then
        FOnDataReceived(Packets[I].Data);
  except
    on E: Exception do
      Logger.Warning('[DeviceManager] FlushPendingData: ' + E.ClassName + ': ' + E.Message);
  end;
end;

procedure TDeviceManager.HandleSessionConnectionChanged(
  ASession: TTransportSession; State: TConnectionState; const Message: string);
begin
  if FDestroying then Exit;

  Logger.Info('[DeviceManager] SessionConnChanged: ' + ASession.DeviceInfo.Address +
    ' state=' + IntToStr(Ord(State)) + ' msg=' + Message);

  if (FActiveDeviceAddress = '') and (State = csConnected) then
    FActiveDeviceAddress := ASession.DeviceInfo.Address;

  { Queue for main thread }
  FLock.Enter;
  try
    if FPendingConnectionCount >= Length(FPendingConnections) then
      SetLength(FPendingConnections, FPendingConnectionCount + 4);
    FPendingConnections[FPendingConnectionCount].Device := ASession.DeviceInfo;
    FPendingConnections[FPendingConnectionCount].State := State;
    FPendingConnections[FPendingConnectionCount].Message := Message;
    Inc(FPendingConnectionCount);
  finally
    FLock.Leave;
  end;

end;

procedure TDeviceManager.Tick;
var I: Integer;
begin
  for I := FConnectThreads.Count - 1 downto 0 do
    if FConnectThreads[I].Finished then FConnectThreads.Delete(I);
  for I := FScanThreads.Count - 1 downto 0 do
    if FScanThreads[I].Finished then FScanThreads.Delete(I);
  FlushPendingDeviceFound;
  FlushPendingConnectionChanged;
  FlushPendingData;
end;

procedure TDeviceManager.FlushPendingConnectionChanged;
var
  Conns: array of record Device: TDeviceInfo; State: TConnectionState; Msg: string; end;
  Count, I: Integer;
begin
  FLock.Enter;
  try
    Count := FPendingConnectionCount;
    SetLength(Conns, Count);
    for I := 0 to Count - 1 do
    begin
      Conns[I].Device := FPendingConnections[I].Device;
      Conns[I].State := FPendingConnections[I].State;
      Conns[I].Msg := FPendingConnections[I].Message;
    end;
    FPendingConnectionCount := 0;
  finally
    FLock.Leave;
  end;

  if Count > 0 then
    Logger.Info('[DeviceManager] FlushConnChanged: ' + IntToStr(Count) + ' pending');

  for I := 0 to Count - 1 do
  begin
    Logger.Info('[DeviceManager]   [' + IntToStr(I) + '] ' + Conns[I].Device.Address +
      ' state=' + IntToStr(Ord(Conns[I].State)) +
      ' HasCallback=' + BoolToStr(Assigned(FOnDeviceConnectionChanged), True));
    try
      if Assigned(FOnDeviceConnectionChanged) then
        FOnDeviceConnectionChanged(Conns[I].Device, Conns[I].State, Conns[I].Msg);
      if SameText(FActiveDeviceAddress, Conns[I].Device.Address) then
        if Assigned(FOnConnectionChanged) then
          FOnConnectionChanged(Conns[I].State, Conns[I].Msg);
    except
      on E: Exception do
        Logger.Error('[DeviceManager] FlushConnChanged callback EXCEPTION: ' + E.ClassName + ': ' + E.Message);
    end;
  end;
end;

{ All public manager command entry points are nonblocking. }
function TDeviceManager.PostControl(const AAddress: string; Kind: TTrainerCommandKind;
  Value: Single; Wind: Single; RiderWeight: Single; BikeWeight: Single): Boolean;
var S: TTransportSession;
begin
  S := GetSession(AAddress);
  Result := (not FDestroying) and Assigned(S);
  if Result then Result := S.QueueControl(Kind, Value, Wind, RiderWeight, BikeWeight);
end;

function TDeviceManager.RequestControl: Boolean;
begin
  Result := RequestControl(FActiveDeviceAddress);
end;

function TDeviceManager.RequestControl(const AAddress: string): Boolean;
begin
  Result := PostControl(AAddress, tcRequest);
end;

function TDeviceManager.SetTargetPower(Watts: Word): Boolean;
begin
  Result := SetTargetPower(FActiveDeviceAddress, Watts);
end;

function TDeviceManager.SetTargetPower(const AAddress: string; Watts: Word): Boolean;
begin
  Result := PostControl(AAddress, tcPower, Watts);
end;

function TDeviceManager.SetResistanceLevel(Level: Byte): Boolean;
begin
  Result := SetResistanceLevel(FActiveDeviceAddress, Level);
end;

function TDeviceManager.SetResistanceLevel(const AAddress: string; Level: Byte): Boolean;
begin
  Result := PostControl(AAddress, tcResistance, Level);
end;

function TDeviceManager.SetIncline(InclinePercent: Single): Boolean;
begin
  Result := SetIncline(FActiveDeviceAddress, InclinePercent);
end;

function TDeviceManager.SetIncline(const AAddress: string; InclinePercent: Single): Boolean;
begin
  Result := PostControl(AAddress, tcIncline, InclinePercent);
end;

function TDeviceManager.SetSimulation(Grade: Single; WindSpeed: Single; RiderWeight: Single; BikeWeight: Single): Boolean;
begin
  Result := SetSimulation(FActiveDeviceAddress, Grade, WindSpeed, RiderWeight, BikeWeight);
end;

function TDeviceManager.SetSimulation(const AAddress: string; Grade: Single; WindSpeed: Single; RiderWeight: Single; BikeWeight: Single): Boolean;
begin
  Result := PostControl(AAddress, tcSimulation, Grade, WindSpeed, RiderWeight, BikeWeight);
end;

function TDeviceManager.Start: Boolean;
begin
  Result := Start(FActiveDeviceAddress);
end;

function TDeviceManager.Start(const AAddress: string): Boolean;
begin
  Result := PostControl(AAddress, tcStart);
end;

function TDeviceManager.Stop: Boolean;
begin
  Result := Stop(FActiveDeviceAddress);
end;

function TDeviceManager.Stop(const AAddress: string): Boolean;
begin
  Result := PostControl(AAddress, tcStop);
end;

function TDeviceManager.Pause: Boolean;
begin
  Result := Pause(FActiveDeviceAddress);
end;

function TDeviceManager.Pause(const AAddress: string): Boolean;
begin
  Result := PostControl(AAddress, tcPause);
end;

function TDeviceManager.Reset: Boolean;
begin
  Result := Reset(FActiveDeviceAddress);
end;

function TDeviceManager.Reset(const AAddress: string): Boolean;
begin
  Result := PostControl(AAddress, tcReset);
end;

{ ═══════════════════════════════════════════════════════════════════
  TDeviceWorkerThread
  ═══════════════════════════════════════════════════════════════════ }

constructor TDeviceWorkerThread.Create(AOwner: TDeviceManager);
begin
  FOwner := AOwner;
  FQueueLock := syncobjs.TCriticalSection.Create;
  FQueueCount := 0;
  FWakeEvent := RTLEventCreate;
  FreeOnTerminate := False;
  inherited Create(False);
end;

destructor TDeviceWorkerThread.Destroy;
begin
  inherited Destroy;
  RTLEventDestroy(FWakeEvent);
  FreeAndNil(FQueueLock);
end;

procedure TDeviceWorkerThread.PostCommand(const AItem: TDeviceWorkItem);
begin
  FQueueLock.Enter;
  try
    if FQueueCount >= Length(FQueue) then
      SetLength(FQueue, FQueueCount + 8);
    FQueue[FQueueCount] := AItem;
    Inc(FQueueCount);
  finally
    FQueueLock.Leave;
  end;
  RTLEventSetEvent(FWakeEvent);
end;

procedure TDeviceWorkerThread.Execute;
var
  Item: TDeviceWorkItem;
  HasItem: Boolean;
  QI: Integer;
begin
  { Initialize COM as MTA — required for WinRT async operations }
  {$IFDEF WINDOWS}
  CoInitializeEx(nil, 0); { COINIT_MULTITHREADED = 0 }
  {$ENDIF}
  try

  while not Terminated do
  begin
    RTLEventWaitFor(FWakeEvent);
    RTLEventResetEvent(FWakeEvent);

    while not Terminated do
    begin
      { Dequeue one item }
      HasItem := False;
      FQueueLock.Enter;
      try
        if FQueueCount > 0 then
        begin
          Item := FQueue[0];
          for QI := 1 to FQueueCount - 1 do
            FQueue[QI - 1] := FQueue[QI];
          Dec(FQueueCount);
          FQueue[FQueueCount].Address := '';
          FQueue[FQueueCount].FriendlyName := '';
          HasItem := True;
        end;
      finally
        FQueueLock.Leave;
      end;

      if not HasItem then Break;

      case Item.Cmd of
        dwcScan: DoScan;
        dwcConnect: ; { connects now run in dedicated TConnectThread }
      end;
    end;
  end;

  finally
    {$IFDEF WINDOWS}
    CoUninitialize;
    {$ENDIF}
  end;
end;

procedure TDeviceWorkerThread.DoScan;
var
  I: Integer;
  P: TTransportProvider;
  BlockingProv: TTransportProvider;
begin
  // Стратегия: non-blocking провайдеры (ANT — StartScan возвращается за
  // <500мс, дальше работает в собственном dispatch thread'е) запускаем сразу
  // в worker — это не блокирует. Blocking-провайдер (WinRT BLE с continuous
  // scan-loop'ом) запускаем ПОСЛЕДНИМ, тоже в worker — он держит worker
  // занятым до StopScan, что мешает worker'у параллельно обрабатывать
  // dwcConnect-команды.
  //
  // Зачем так — было обнаружено что параллельный TConnectThread (когда
  // worker свободен и spawn'ит его пока WinRT scan активен) создаёт race
  // condition в WinRT COM-ресурсах: scan-reset через 30с обнуляет device
  // handle, на который активный TConnectThread сидит, → vtable crash в
  // add_ConnectionStatusChanged. Ранее этот race был замаскирован тем, что
  // worker блокировался в WinRT scan-loop'е и не процессил dwcConnect, пока
  // scan не остановится. Восстанавливаем тот invariant.
  //
  // ANT — non-blocking, у него свой dispatch thread, он ничего не race'ит
  // с blocking WinRT. Так что его безопасно запускать первым inline.
  BlockingProv := nil;
  for I := 0 to FOwner.FProviders.Count - 1 do
  begin
    if Terminated then Exit;
    P := FOwner.FProviders[I];
    // Skip провайдеры, которые пользователь выключил в settings.
    if not FOwner.IsProviderEnabled(P) then Continue;
    if P.TransportType in [ttANTPlus, ttSim] then
      P.StartScan
    else
    begin
      // Если несколько blocking-провайдеров — берём последний; предыдущие
      // были бы подавлены (worker может крутить только один blocking-loop).
      // В текущей конфигурации blocking provider только один — WinRT.
      BlockingProv := P;
    end;
  end;
  if (BlockingProv <> nil) and not Terminated then
    BlockingProv.StartScan;  // блокирует worker до StopScan — by design.
end;

{ ═══════════════════════════════════════════════════════════════════
  TProviderScanThread — fire-and-forget thread для StartScan на одном
  провайдере. Используется при toggle-on adapter'а из UI thread когда
  провайдер blocking.
  ═══════════════════════════════════════════════════════════════════ }

constructor TProviderScanThread.Create(AProvider: TTransportProvider);
begin
  inherited Create(True);
  FProvider := AProvider;
  FreeOnTerminate := False;
end;

procedure TProviderScanThread.Execute;
begin
  if FProvider <> nil then
    FProvider.StartScan;
end;

{ ═══════════════════════════════════════════════════════════════════
  TConnectThread — runs a single connection in its own thread
  ═══════════════════════════════════════════════════════════════════ }

constructor TConnectThread.Create(AOwner: TDeviceManager;
  const AAddress, AFriendlyName, AProviderName: string; ADisconnect: Boolean);
begin
  inherited Create(True);
  FDisconnectRequested := ADisconnect;
  FOwner := AOwner;
  FAddress := AAddress;
  FFriendlyName := AFriendlyName;
  FProviderName := AProviderName;
  FreeOnTerminate := False;
end;

procedure TConnectThread.Execute;
var
  S: TTransportSession;
  Provider: TTransportProvider;
  I: Integer;
begin
  {$IFDEF WINDOWS}
  CoInitializeEx(nil, 0);
  {$ENDIF}
  try
    try
      { Check existing session }
      S := FOwner.GetSession(FAddress);
      if Assigned(S) then
      begin
        S.LockTransport;
        try
          if not FDisconnectRequested and not FOwner.FDestroying and
            (S.ConnectionState <> csConnected) then S.Connect;
          if FDisconnectRequested or FOwner.FDestroying then S.Disconnect;
        finally S.UnlockTransport end;
        Exit;
      end;

      if FDisconnectRequested or FOwner.FDestroying then Exit;

      { Find provider }
      Provider := nil;
      if FProviderName <> '' then
      begin
        FOwner.FLock.Enter;
        try
          for I := 0 to FOwner.FProviders.Count - 1 do
          begin
            if (SameText(FProviderName, 'WinRT') and
                (Pos('WinRT', FOwner.FProviders[I].ClassName) > 0)) or
               (SameText(FProviderName, 'WinBLE') and
                (Pos('BLETransport', FOwner.FProviders[I].ClassName) > 0)) or
               (SameText(FProviderName, 'SimpleBLE') and
                (Pos('SimpleBLE', FOwner.FProviders[I].ClassName) > 0)) then
            begin
              Provider := FOwner.FProviders[I];
              Break;
            end;
          end;
        finally
          FOwner.FLock.Leave;
        end;
      end;
      if not Assigned(Provider) then
        Provider := FOwner.FindProviderForAddress(FAddress);
      if not Assigned(Provider) then Exit;

      S := Provider.CreateSession(FAddress, FFriendlyName);
      if not Assigned(S) then Exit;
      S.OnDataReceived := @FOwner.HandleSessionDataReceived;
      S.OnConnectionChanged := @FOwner.HandleSessionConnectionChanged;

      FOwner.FLock.Enter;
      try
        FOwner.FSessions.Add(S);
      finally
        FOwner.FLock.Leave;
      end;

      S.LockTransport;
      try
        if not FDisconnectRequested and not FOwner.FDestroying then S.Connect;
        if FDisconnectRequested or FOwner.FDestroying then S.Disconnect;
      finally S.UnlockTransport end;
    except
      on E: Exception do
        Logger.Warning('[DeviceManager] Connect failed for ' + FAddress +
          ': ' + E.Message);
    end;
  finally
    { Unmark connecting }
    FOwner.FConnectingLock.Enter;
    try
      I := FOwner.FConnectingAddrs.IndexOf(FAddress);
      if I >= 0 then
        FOwner.FConnectingAddrs.Delete(I);
    finally
      FOwner.FConnectingLock.Leave;
    end;
    {$IFDEF WINDOWS}
    CoUninitialize;
    {$ENDIF}
  end;
end;

end.
