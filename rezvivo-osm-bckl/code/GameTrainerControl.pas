{ Bounded, asynchronous trainer commands. No transport or UI dependencies.
  The transport owns the queue and outlives its worker. A successful Post
  means queued, never that the trainer accepted the command. }
unit GameTrainerControl;

{$mode objfpc}{$H+}

interface

uses Classes, SysUtils, SyncObjs;

type
  { A callback context is owned by its external delegate. Detach prevents new
    calls from borrowing Target; the owner then drains existing calls before
    freeing Target. Callbacks only Acquire/Release (or nonblocking Detach),
    never WaitForIdle, and never need the transport/session lock. }
  TTrainerCallbackGate = class
  private
    FLock: TCriticalSection;
    FIdle: TEvent;
    FTarget: TObject;
    FActive: Integer;
  public
    constructor Create(Target: TObject);
    destructor Destroy; override;
    function Acquire(out Target: TObject): Boolean;
    procedure Release;
    procedure Detach;
    procedure WaitForIdle;
  end;

  TTrainerCommandKind = (tcRequest, tcPower, tcResistance, tcIncline,
    tcSimulation, tcStart, tcStop, tcPause, tcReset);
  TTrainerCommand = record
    Kind: TTrainerCommandKind;
    Value, Wind, RiderWeight, BikeWeight: Single;
    Generation: Cardinal;
    Revision: Cardinal;
  end;
  TTrainerControlState = (tcsIdle, tcsPending, tcsAccepted, tcsSent,
    tcsDenied, tcsTimeout, tcsFailed, tcsUnavailable, tcsUnsupported);
  TTrainerControlStatus = record
    State: TTrainerControlState;
    Kind: TTrainerCommandKind;
    Value: Single;
    ChangedAt: QWord;
  end;
  TExecuteTrainerCommand = function(const Command: TTrainerCommand):
    TTrainerControlState of object;

  TTrainerControlQueue = class;
  TTrainerCommandThread = class(TThread)
  private
    FOwner: TTrainerControlQueue;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TTrainerControlQueue);
  end;

  TTrainerControlQueue = class
  private
    FLock: TCriticalSection;
    FWake: TEvent;
    FThread: TTrainerCommandThread;
    FExecute: TExecuteTrainerCommand;
    FItems: array[0..3] of TTrainerCommand;
    FCount: Integer;
    FGeneration: Cardinal;
    FRevision: array[0..2] of Cardinal;
    FStopping: Boolean;
    FStatus: TTrainerControlStatus;
    function Take(out Command: TTrainerCommand): Boolean;
    procedure Complete(const Command: TTrainerCommand; State: TTrainerControlState);
  public
    constructor Create(AExecute: TExecuteTrainerCommand);
    destructor Destroy; override;
    function Post(Kind: TTrainerCommandKind; Value: Single = 0;
      Wind: Single = 0; RiderWeight: Single = 75; BikeWeight: Single = 10): Boolean;
    procedure Cancel;
    procedure Shutdown;
    function Current(Generation: Cardinal): Boolean;
    function IsLatest(const Command: TTrainerCommand): Boolean;
    function Status: TTrainerControlStatus;
    function PendingCount: Integer;
  end;

  { FTMS has an opcode, but no transaction id. After a timeout/cancellation
    of an outstanding procedure, do not reuse the control point until a new
    connection; otherwise a late reply can acknowledge an unrelated target. }
  TFTMSAcknowledgement = class
  private
    FLock: TCriticalSection;
    FEvent: TEvent;
    FPending, FBlocked: Boolean;
    FOpcode, FResult: Byte;
  public
    constructor Create;
    destructor Destroy; override;
    procedure NewConnection;
    function BeginCommand(Opcode: Byte): Boolean;
    procedure Receive(const Data: TBytes);
    function Wait(TimeoutMs: Cardinal): TTrainerControlState;
    procedure Cancel;
  end;

function TrainerControlMessageKey(State: TTrainerControlState): string;

implementation

{$IFDEF WINDOWS}
uses Windows;
function CoInitializeEx(pvReserved: Pointer; dwCoInit: DWORD): HRESULT; stdcall; external 'ole32.dll';
procedure CoUninitialize; stdcall; external 'ole32.dll';
{$ENDIF}

function TrainerControlMessageKey(State: TTrainerControlState): string;
begin
  case State of
    tcsPending: Result := 'Waiting for trainer confirmation';
    tcsAccepted: Result := 'Trainer control confirmed';
    tcsSent: Result := 'Trainer command sent';
    tcsDenied: Result := 'Trainer control denied; check other connected apps';
    tcsTimeout: Result := 'Trainer did not respond; reconnect it';
    tcsFailed: Result := 'Trainer command failed';
    tcsUnavailable: Result := 'Trainer control unavailable';
    tcsUnsupported: Result := 'Trainer does not support this command';
    else Result := 'Trainer ready';
  end;
end;

function CommandGroup(Kind: TTrainerCommandKind): Integer;
begin
  case Kind of
    tcRequest: Result := 0;
    tcPower, tcResistance, tcIncline, tcSimulation: Result := 1;
    else Result := 2;
  end;
end;

constructor TTrainerCommandThread.Create(AOwner: TTrainerControlQueue);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FOwner := AOwner;
end;

procedure TTrainerCommandThread.Execute;
var
  Command: TTrainerCommand;
  State: TTrainerControlState;
  {$IFDEF WINDOWS}ComResult: HRESULT;{$ENDIF}
begin
  {$IFDEF WINDOWS}ComResult := CoInitializeEx(nil, 0);{$ENDIF}
  try
    while not Terminated do
    begin
      FOwner.FWake.WaitFor(1000);
      while (not Terminated) and FOwner.Take(Command) do
      begin
        if not FOwner.Current(Command.Generation) then Continue;
        try
          State := FOwner.FExecute(Command);
        except
          State := tcsFailed;
        end;
        FOwner.Complete(Command, State);
      end;
    end;
  finally
    {$IFDEF WINDOWS}if ComResult >= 0 then CoUninitialize;{$ENDIF}
  end;
end;

constructor TTrainerControlQueue.Create(AExecute: TExecuteTrainerCommand);
begin
  inherited Create;
  FLock := SyncObjs.TCriticalSection.Create;
  FWake := TEvent.Create(nil, False, False, '');
  FExecute := AExecute;
  FGeneration := 1;
  FStatus.State := tcsIdle;
  { Thread is started lazily: HR/cadence sensors never need one. }
end;

destructor TTrainerControlQueue.Destroy;
begin
  Shutdown;
  FWake.Free;
  FLock.Free;
  inherited;
end;

function TTrainerControlQueue.Post(Kind: TTrainerCommandKind; Value: Single;
  Wind: Single; RiderWeight: Single; BikeWeight: Single): Boolean;
var I, Slot: Integer;
begin
  Result := False;
  FLock.Enter;
  try
    if FStopping then Exit;
    if FThread = nil then
    begin
      FThread := TTrainerCommandThread.Create(Self);
      FThread.Start;
    end;
    { Stop/pause/reset invalidate queued load and start requests. They do
      not abort an already transmitted procedure: its ACK must be drained. }
    if Kind in [tcStop, tcPause, tcReset] then
    begin
      FCount := 0;
      Inc(FRevision[1]);
    end;
    Slot := -1;
    for I := 0 to FCount - 1 do
      if CommandGroup(FItems[I].Kind) = CommandGroup(Kind) then Slot := I;
    if Slot < 0 then
    begin
      if FCount = Length(FItems) then Exit;
      Slot := FCount;
      Inc(FCount);
    end;
    FItems[Slot].Kind := Kind;
    FItems[Slot].Value := Value;
    FItems[Slot].Wind := Wind;
    FItems[Slot].RiderWeight := RiderWeight;
    FItems[Slot].BikeWeight := BikeWeight;
    FItems[Slot].Generation := FGeneration;
    Inc(FRevision[CommandGroup(Kind)]);
    FItems[Slot].Revision := FRevision[CommandGroup(Kind)];
    if FStatus.State = tcsIdle then FStatus.State := tcsPending;
    Result := True;
    FWake.SetEvent;
  finally FLock.Leave end;
end;

function TTrainerControlQueue.Take(out Command: TTrainerCommand): Boolean;
var I: Integer;
begin
  FLock.Enter;
  try
    Result := (not FStopping) and (FCount > 0);
    if not Result then Exit;
    Command := FItems[0];
    for I := 1 to FCount - 1 do FItems[I-1] := FItems[I];
    Dec(FCount);
    FStatus.State := tcsPending;
    FStatus.Kind := Command.Kind;
    FStatus.Value := Command.Value;
    FStatus.ChangedAt := GetTickCount64;
  finally FLock.Leave end;
end;

procedure TTrainerControlQueue.Complete(const Command: TTrainerCommand;
  State: TTrainerControlState);
var I, Kept: Integer;
begin
  FLock.Enter;
  try
    if FStopping or (Command.Generation <> FGeneration) or
      (Command.Revision <> FRevision[CommandGroup(Command.Kind)]) then Exit;
    FStatus.State := State;
    FStatus.Kind := Command.Kind;
    FStatus.Value := Command.Value;
    FStatus.ChangedAt := GetTickCount64;
    { A failed control request must not be followed by stale high loads. }
    if State in [tcsDenied, tcsTimeout, tcsFailed, tcsUnavailable, tcsUnsupported] then
    begin
      Kept := 0;
      for I := 0 to FCount - 1 do
        if FItems[I].Kind in [tcStop, tcPause, tcReset] then
        begin
          FItems[Kept] := FItems[I];
          Inc(Kept);
        end;
      FCount := Kept;
    end;
  finally FLock.Leave end;
end;

procedure TTrainerControlQueue.Cancel;
begin
  FLock.Enter;
  try
    Inc(FGeneration);
    FCount := 0;
    FStatus.State := tcsIdle;
    FStatus.ChangedAt := GetTickCount64;
  finally FLock.Leave end;
end;

procedure TTrainerControlQueue.Shutdown;
begin
  FLock.Enter;
  try
    FStopping := True;
    Inc(FGeneration);
    FCount := 0;
    if FThread <> nil then FThread.Terminate;
    FWake.SetEvent;
  finally FLock.Leave end;
  if FThread <> nil then
  begin
    FThread.WaitFor;
    FreeAndNil(FThread);
  end;
end;

function TTrainerControlQueue.Current(Generation: Cardinal): Boolean;
begin
  FLock.Enter;
  try Result := (not FStopping) and (Generation = FGeneration);
  finally FLock.Leave end;
end;

function TTrainerControlQueue.Status: TTrainerControlStatus;
begin
  FLock.Enter;
  try Result := FStatus;
  finally FLock.Leave end;
end;

function TTrainerControlQueue.IsLatest(const Command: TTrainerCommand): Boolean;
begin
  FLock.Enter;
  try
    Result := (not FStopping) and (Command.Generation = FGeneration) and
      (Command.Revision = FRevision[CommandGroup(Command.Kind)]);
  finally FLock.Leave end;
end;

function TTrainerControlQueue.PendingCount: Integer;
begin
  FLock.Enter;
  try Result := FCount;
  finally FLock.Leave end;
end;

constructor TTrainerCallbackGate.Create(Target: TObject);
begin
  inherited Create;
  FLock := SyncObjs.TCriticalSection.Create;
  FIdle := TEvent.Create(nil, True, True, '');
  FTarget := Target;
end;

destructor TTrainerCallbackGate.Destroy;
begin
  Detach;
  WaitForIdle;
  FIdle.Free;
  FLock.Free;
  inherited;
end;

function TTrainerCallbackGate.Acquire(out Target: TObject): Boolean;
begin
  FLock.Enter;
  try
    Target := FTarget;
    Result := Target <> nil;
    if Result then
    begin
      Inc(FActive);
      FIdle.ResetEvent;
    end;
  finally FLock.Leave; end;
end;

procedure TTrainerCallbackGate.Release;
begin
  FLock.Enter;
  try
    Dec(FActive);
    Assert(FActive >= 0);
    if FActive = 0 then FIdle.SetEvent;
  finally FLock.Leave; end;
end;

procedure TTrainerCallbackGate.Detach;
begin
  FLock.Enter;
  try FTarget := nil;
  finally FLock.Leave; end;
end;

procedure TTrainerCallbackGate.WaitForIdle;
begin
  FIdle.WaitFor(High(Cardinal));
end;

constructor TFTMSAcknowledgement.Create;
begin
  inherited;
  FLock := SyncObjs.TCriticalSection.Create;
  FEvent := TEvent.Create(nil, True, False, '');
end;

destructor TFTMSAcknowledgement.Destroy;
begin
  FEvent.Free;
  FLock.Free;
  inherited;
end;

procedure TFTMSAcknowledgement.NewConnection;
begin
  FLock.Enter;
  try
    FPending := False;
    FBlocked := False;
    FResult := 0;
    FEvent.ResetEvent;
  finally FLock.Leave end;
end;

function TFTMSAcknowledgement.BeginCommand(Opcode: Byte): Boolean;
begin
  FLock.Enter;
  try
    Result := not (FPending or FBlocked);
    if not Result then Exit;
    FOpcode := Opcode;
    FResult := 0;
    FPending := True;
    FEvent.ResetEvent;
  finally FLock.Leave end;
end;

procedure TFTMSAcknowledgement.Receive(const Data: TBytes);
begin
  if (Length(Data) <> 3) or (Data[0] <> $80) then Exit;
  FLock.Enter;
  try
    if (not FPending) or FBlocked or (Data[1] <> FOpcode) then Exit;
    if not (Data[2] in [1..5]) then Exit;
    FResult := Data[2];
    FPending := False;
    FEvent.SetEvent;
  finally FLock.Leave end;
end;

function TFTMSAcknowledgement.Wait(TimeoutMs: Cardinal): TTrainerControlState;
begin
  FEvent.WaitFor(TimeoutMs);
  FLock.Enter;
  try
    if FBlocked then Exit(tcsUnavailable);
    case FResult of
      1: Result := tcsAccepted;
      2: Result := tcsUnsupported;
      5: Result := tcsDenied;
      3, 4: Result := tcsFailed;
      else begin Result := tcsTimeout; FBlocked := True end;
    end;
    FPending := False;
  finally FLock.Leave end;
end;

procedure TFTMSAcknowledgement.Cancel;
begin
  FLock.Enter;
  try
    if FPending then FBlocked := True;
    FPending := False;
    FEvent.SetEvent;
  finally FLock.Leave end;
end;

end.
