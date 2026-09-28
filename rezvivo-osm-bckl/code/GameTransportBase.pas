{ GameTransportBase — абстрактный предок для различных видов транспорта
  подключения к тренажёрам: BLE, ANT+, Ethernet, Wi-Fi и др.

  TTransportSession — абстрактная сессия подключения к одному устройству.
  TTransportProvider — абстрактная фабрика: скан + создание сессий.
}
unit GameTransportBase;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, syncobjs, TrainerData, GameTrainerControl;

type
  TTransportSession = class;
  TWriteTrainerBytes = function(const Data: TBytes): Boolean of object;

  { Колбэки сессии — вызываются сессией при получении данных / смене состояния }
  TOnSessionDataReceived = procedure(ASession: TTransportSession;
    const Data: TTrainerDataRecord) of object;
  TOnSessionConnectionChanged = procedure(ASession: TTransportSession;
    State: TConnectionState; const Message: string) of object;

  { TTransportSession — абстрактная сессия подключения к одному устройству.
    Потомки реализуют Connect/Disconnect и команды управления трейнером
    для конкретного транспорта (BLE, ANT+, Ethernet, ...). }

  TTransportSession = class
  private
    FOnDataReceived: TOnSessionDataReceived;
    FOnConnectionChanged: TOnSessionConnectionChanged;
    FControlQueue: TTrainerControlQueue;
    FControlIO: TCriticalSection;
    FControlAck: TFTMSAcknowledgement;
    FExecutingGeneration: Cardinal;
    FCommandResult: TTrainerControlState;
    FLastControlFailure: QWord;
    FDisconnecting: Boolean;
    function ExecuteControl(const Command: TTrainerCommand): TTrainerControlState;
  protected
    FLock: TCriticalSection;
    FConnectionState: TConnectionState;
    FDeviceInfo: TDeviceInfo;
    FTrainerFeatures: TTrainerFeatures;
    FLastData: TTrainerDataRecord;
    FHasControl: Boolean;
    FDestroying: Boolean;

    procedure SetConnectionState(AState: TConnectionState;
      const AMessage: string = ''); virtual;
    procedure NotifyDataReceived; virtual;
    function SendConfirmedFTMS(const Data: TBytes;
      Writer: TWriteTrainerBytes): Boolean;
  public
    constructor Create(const AAddress: string; const AFriendlyName: string = ''); virtual;
    destructor Destroy; override;

    { Commands are posted from UI; only the owned worker calls the synchronous
      transport methods below. Connect/disconnect share the I/O lock. }
    function QueueControl(Kind: TTrainerCommandKind; Value: Single = 0;
      Wind: Single = 0; RiderWeight: Single = 75; BikeWeight: Single = 10): Boolean;
    procedure CancelControl;
    procedure PrepareDisconnect;
    procedure ShutdownControl;
    procedure LockTransport;
    function TryLockTransport: Boolean;
    procedure UnlockTransport;
    function ControlStatus: TTrainerControlStatus;
    procedure ReceiveControlPoint(const Data: TBytes);

    { --- Управление подключением --- }
    function Connect: Boolean; virtual; abstract;
    procedure Disconnect; virtual; abstract;
    function IsConnectionAlive: Boolean; virtual;

    { --- Управление трейнером --- }
    function RequestControl: Boolean; virtual; abstract;
    function SetTargetPower(Watts: Word): Boolean; virtual; abstract;
    function SetResistanceLevel(Level: Byte): Boolean; virtual; abstract;
    function SetIncline(InclinePercent: Single): Boolean; virtual; abstract;
    function SetSimulation(Grade: Single; WindSpeed: Single = 0;
      RiderWeight: Single = 75; BikeWeight: Single = 10): Boolean; virtual; abstract;
    function Start: Boolean; virtual; abstract;
    function Stop: Boolean; virtual; abstract;
    function Pause: Boolean; virtual; abstract;
    function Reset: Boolean; virtual; abstract;

    { --- Тип транспорта --- }
    class function TransportType: TTransportType; virtual;
    class function TransportName: string;

    { --- Свойства --- }
    property ConnectionState: TConnectionState read FConnectionState;
    property DeviceInfo: TDeviceInfo read FDeviceInfo;
    property TrainerFeatures: TTrainerFeatures read FTrainerFeatures;
    property LastData: TTrainerDataRecord read FLastData;
    property HasControl: Boolean read FHasControl;

    property OnDataReceived: TOnSessionDataReceived
      read FOnDataReceived write FOnDataReceived;
    property OnConnectionChanged: TOnSessionConnectionChanged
      read FOnConnectionChanged write FOnConnectionChanged;
  end;

  TTransportSessionClass = class of TTransportSession;

  { TTransportProvider — абстрактная фабрика для конкретного транспорта.
    Отвечает за скан устройств и создание сессий. }

  TTransportProvider = class
  private
    FOnDeviceFound: TOnDeviceFound;
  public
    constructor Create; virtual;
    destructor Destroy; override;

    { Запустить / остановить сканирование }
    procedure StartScan; virtual; abstract;
    procedure StopScan; virtual; abstract;

    { Создать сессию для данного адреса }
    function CreateSession(const AAddress: string;
      const AFriendlyName: string = ''): TTransportSession; virtual; abstract;

    { Тип транспорта, обслуживаемый этим провайдером }
    class function TransportType: TTransportType; virtual;

    { Информация для UI: отображаемое имя (и стабильный ключ для settings)
      физического adapter'а, который этот провайдер представляет. Default —
      имя транспорта (BLE / ANT+). Override в конкретных провайдерах:
      WinRT BLE → "Bluetooth" (имя локального radio).
      ANT+ → product string из USB descriptor (например "ANT USBStick2").
      AdapterKey должен быть стабильным между запусками — он используется
      как ключ в settings.json для запоминания включён ли этот adapter. }
    function AdapterDisplayName: string; virtual;
    function AdapterKey: string; virtual;

    property OnDeviceFound: TOnDeviceFound read FOnDeviceFound write FOnDeviceFound;
  end;

implementation

{ TTransportSession }

constructor TTransportSession.Create(const AAddress: string;
  const AFriendlyName: string);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FControlIO := TCriticalSection.Create;
  FControlAck := TFTMSAcknowledgement.Create;
  FControlQueue := TTrainerControlQueue.Create(@ExecuteControl);
  FConnectionState := csDisconnected;

  FDeviceInfo := Default(TDeviceInfo);
  FDeviceInfo.Address := AAddress;
  FDeviceInfo.Name := AFriendlyName;
  FDeviceInfo.TransportType := TransportType;

  FTrainerFeatures := Default(TTrainerFeatures);
  FLastData := Default(TTrainerDataRecord);
  FHasControl := False;
  FDestroying := False;
end;

destructor TTransportSession.Destroy;
begin
  FDestroying := True;
  ShutdownControl;
  FreeAndNil(FControlQueue);
  FreeAndNil(FControlAck);
  FreeAndNil(FControlIO);
  FOnDataReceived := nil;
  FOnConnectionChanged := nil;
  FreeAndNil(FLock);
  inherited;
end;

procedure TTransportSession.SetConnectionState(AState: TConnectionState;
  const AMessage: string);
begin
  if FDestroying then Exit;

  if AState <> csConnected then CancelControl
  else if FConnectionState <> csConnected then
  begin
    FDisconnecting := False;
    FControlAck.NewConnection;
    FHasControl := False;
    FLastControlFailure := 0;
  end;

  FLock.Enter;
  try
    FConnectionState := AState;
  finally
    FLock.Leave;
  end;

  if Assigned(FOnConnectionChanged) then
    FOnConnectionChanged(Self, AState, AMessage);
end;

function TTransportSession.QueueControl(Kind: TTrainerCommandKind; Value: Single;
  Wind: Single; RiderWeight: Single; BikeWeight: Single): Boolean;
begin
  Result := (not FDestroying) and (not FDisconnecting) and (FConnectionState = csConnected);
  if Result then Result := FControlQueue.Post(Kind, Value, Wind, RiderWeight, BikeWeight);
end;

procedure TTransportSession.CancelControl;
begin
  FControlQueue.Cancel;
  FControlAck.Cancel;
  FHasControl := False;
end;

procedure TTransportSession.PrepareDisconnect;
begin
  FDisconnecting := True;
  CancelControl;
end;

procedure TTransportSession.ShutdownControl;
begin
  CancelControl;
  FControlQueue.Shutdown;
end;

procedure TTransportSession.LockTransport;
begin
  FControlIO.Enter;
end;

function TTransportSession.TryLockTransport: Boolean;
begin
  Result := FControlIO.TryEnter;
end;

procedure TTransportSession.UnlockTransport;
begin
  FControlIO.Leave;
end;

function TTransportSession.ControlStatus: TTrainerControlStatus;
begin
  Result := FControlQueue.Status;
  if FConnectionState <> csConnected then Result.State := tcsUnavailable;
end;

procedure TTransportSession.ReceiveControlPoint(const Data: TBytes);
begin
  FControlAck.Receive(Data);
end;

function TTransportSession.SendConfirmedFTMS(const Data: TBytes;
  Writer: TWriteTrainerBytes): Boolean;
begin
  Result := False;
  if (Length(Data) = 0) or (FConnectionState <> csConnected) or
    (not FControlQueue.Current(FExecutingGeneration)) then Exit;
  if not FControlAck.BeginCommand(Data[0]) then
  begin
    FCommandResult := tcsTimeout;
    Exit;
  end;
  try
    if not Writer(Data) then
    begin
      FControlAck.Cancel;
      FCommandResult := tcsFailed;
      Exit;
    end;
    { FTMS procedure response is distinct from the GATT write response.
      Wait on the worker, interruptibly, for at most the ATT timeout. }
    FCommandResult := FControlAck.Wait(30000);
    Result := (FCommandResult = tcsAccepted) and
      FControlQueue.Current(FExecutingGeneration);
    if not Result then FHasControl := False;
  except
    FControlAck.Cancel;
    FCommandResult := tcsFailed;
    FHasControl := False;
  end;
end;

function TTransportSession.ExecuteControl(const Command: TTrainerCommand): TTrainerControlState;
var Success: Boolean;
begin
  Result := tcsUnavailable;
  FControlIO.Enter;
  try
    if FDestroying or FDisconnecting or (FConnectionState <> csConnected) or
      (not FControlQueue.Current(Command.Generation)) then Exit;
    if not (Command.Kind in [tcStop, tcPause, tcReset]) and
      (FLastControlFailure <> 0) and (GetTickCount64 - FLastControlFailure < 2000) then
      Exit(FCommandResult);
    FExecutingGeneration := Command.Generation;
    FCommandResult := tcsSent;
    { Only acquire control once per connection, and only after the peer ACK. }
    if not FHasControl then
    begin
      if not RequestControl then
      begin
        if FCommandResult = tcsSent then FCommandResult := tcsUnsupported;
        FLastControlFailure := GetTickCount64;
        Exit(FCommandResult);
      end;
      if not FControlQueue.Current(Command.Generation) then Exit;
      FHasControl := True;
    end;
    if not FControlQueue.IsLatest(Command) then Exit;
    Success := False;
    case Command.Kind of
      tcRequest: Success := True;
      tcPower: Success := SetTargetPower(Round(Command.Value));
      tcResistance: Success := SetResistanceLevel(Round(Command.Value));
      tcIncline: Success := SetIncline(Command.Value);
      tcSimulation: Success := SetSimulation(Command.Value, Command.Wind,
        Command.RiderWeight, Command.BikeWeight);
      tcStart: Success := Start;
      tcStop: Success := Stop;
      tcPause: Success := Pause;
      tcReset: Success := Reset;
    end;
    if not FControlQueue.Current(Command.Generation) then Exit;
    if not Success then
    begin
      if FCommandResult in [tcsSent, tcsAccepted] then FCommandResult := tcsFailed;
      FLastControlFailure := GetTickCount64;
    end
    else FLastControlFailure := 0;
    Result := FCommandResult;
  finally FControlIO.Leave end;
end;

procedure TTransportSession.NotifyDataReceived;
begin
  if FDestroying then Exit;
  if Assigned(FOnDataReceived) then
    FOnDataReceived(Self, FLastData);
end;

function TTransportSession.IsConnectionAlive: Boolean;
begin
  Result := FConnectionState = csConnected;
end;

class function TTransportSession.TransportType: TTransportType;
begin
  Result := ttUnknown;
end;

class function TTransportSession.TransportName: string;
begin
  Result := TRANSPORT_TYPE_NAMES[TransportType];
end;

{ TTransportProvider }

constructor TTransportProvider.Create;
begin
  inherited Create;
end;

destructor TTransportProvider.Destroy;
begin
  FOnDeviceFound := nil;
  inherited;
end;

class function TTransportProvider.TransportType: TTransportType;
begin
  Result := ttUnknown;
end;

function TTransportProvider.AdapterDisplayName: string;
begin
  // Дефолт — имя транспорта (BLE / ANT+ / ...). Конкретные провайдеры
  // могут возвращать имя физического adapter'а, например product string.
  Result := TRANSPORT_TYPE_NAMES[TransportType];
end;

function TTransportProvider.AdapterKey: string;
begin
  // Дефолт = display name. Если у провайдера потенциально несколько
  // adapter'ов — переопределить, чтобы каждый имел стабильный ID.
  Result := AdapterDisplayName;
end;

end.
