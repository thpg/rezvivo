unit GameNetworkSystem;

interface

uses
  Classes, SysUtils,
  GameAgentNetwork, GamePhysicalAgent, GameWorldAgents,
  GameNetworkMessages, GameNetworkSerializer, GameNetworkTransport;

type
  TGameNetworkSystem = class
  private
    FMode: TGameNetworkMode;
    FEnabled: Boolean;
    FAgents: TPhysicalAgentList;

    FIncoming: TGameNetworkMessageQueue;
    FOutgoing: TGameNetworkMessageQueue;

    FNextNetworkId: TAgentNetworkId;

    FTransport: INetworkTransport;
    FSerializer: INetworkSerializer;

    procedure FlushOutgoingToTransport;
    procedure PollIncomingFromTransport;
    procedure ProcessIncomingMessages;
  public
    constructor Create;
    destructor Destroy; override;

    procedure SetAgents(const AAgents: TPhysicalAgentList);

    procedure SetOfflineMode;
    procedure SetServerMode(const ATransport: INetworkTransport = nil);
    procedure SetClientMode(const ATransport: INetworkTransport = nil);

    procedure SetTransport(const ATransport: INetworkTransport);
    procedure SetSerializer(const ASerializer: INetworkSerializer);

    function RegisterAgent(const AAgent: TPhysicalAgent): TAgentNetworkId;

    procedure QueueOutgoingInput(const AInput: TAgentInputCommand);
    procedure QueueOutgoingState(const AState: TAgentNetworkState);

    procedure InjectIncomingInput(const AInput: TAgentInputCommand);
    procedure InjectIncomingState(const AState: TAgentNetworkState);

    procedure Update(const SecondsPassed: Single);

    property Enabled: Boolean read FEnabled;
    property Mode: TGameNetworkMode read FMode;
    property Transport: INetworkTransport read FTransport;
    property Serializer: INetworkSerializer read FSerializer;
  end;

implementation

constructor TGameNetworkSystem.Create;
begin
  inherited;
  FIncoming := TGameNetworkMessageQueue.Create;
  FOutgoing := TGameNetworkMessageQueue.Create;
  FMode := nmOffline;
  FEnabled := false;
  FNextNetworkId := 1;
  FSerializer := TJsonNetworkSerializer.Create;
end;

destructor TGameNetworkSystem.Destroy;
begin
  FOutgoing.Free;
  FIncoming.Free;
  inherited;
end;

procedure TGameNetworkSystem.SetAgents(const AAgents: TPhysicalAgentList);
begin
  FAgents := AAgents;
end;

procedure TGameNetworkSystem.SetOfflineMode;
begin
  FMode := nmOffline;
  FEnabled := false;

  if Assigned(FTransport) and FTransport.IsConnected then
    FTransport.Disconnect;

  FIncoming.Clear;
  FOutgoing.Clear;
end;

procedure TGameNetworkSystem.SetServerMode(const ATransport: INetworkTransport);
begin
  FMode := nmServer;
  FEnabled := true;
  if Assigned(ATransport) then
    SetTransport(ATransport);
  if Assigned(FTransport) then
    FTransport.Connect;
end;

procedure TGameNetworkSystem.SetClientMode(const ATransport: INetworkTransport);
begin
  FMode := nmClient;
  FEnabled := true;
  if Assigned(ATransport) then
    SetTransport(ATransport);
  if Assigned(FTransport) then
    FTransport.Connect;
end;

procedure TGameNetworkSystem.SetTransport(const ATransport: INetworkTransport);
begin
  FTransport := ATransport;
end;

procedure TGameNetworkSystem.SetSerializer(const ASerializer: INetworkSerializer);
begin
  FSerializer := ASerializer;
end;

function TGameNetworkSystem.RegisterAgent(const AAgent: TPhysicalAgent): TAgentNetworkId;
begin
  Result := FNextNetworkId;
  Inc(FNextNetworkId);
  AAgent.NetworkId := Result;
end;

procedure TGameNetworkSystem.QueueOutgoingInput(const AInput: TAgentInputCommand);
var
  Msg: TGameNetworkMessage;
begin
  if not FEnabled then Exit;

  Msg := TGameNetworkMessage.Create;
  Msg.Kind := mkInputCommand;
  Msg.Input := AInput;
  FOutgoing.Enqueue(Msg);
end;

procedure TGameNetworkSystem.QueueOutgoingState(const AState: TAgentNetworkState);
var
  Msg: TGameNetworkMessage;
begin
  if not FEnabled then Exit;

  Msg := TGameNetworkMessage.Create;
  Msg.Kind := mkStateSnapshot;
  Msg.State := AState;
  FOutgoing.Enqueue(Msg);
end;

procedure TGameNetworkSystem.InjectIncomingInput(const AInput: TAgentInputCommand);
var
  Msg: TGameNetworkMessage;
begin
  Msg := TGameNetworkMessage.Create;
  Msg.Kind := mkInputCommand;
  Msg.Input := AInput;
  FIncoming.Enqueue(Msg);
end;

procedure TGameNetworkSystem.InjectIncomingState(const AState: TAgentNetworkState);
var
  Msg: TGameNetworkMessage;
begin
  Msg := TGameNetworkMessage.Create;
  Msg.Kind := mkStateSnapshot;
  Msg.State := AState;
  FIncoming.Enqueue(Msg);
end;

procedure TGameNetworkSystem.FlushOutgoingToTransport;
var
  Msg: TGameNetworkMessage;
  Data: String;
begin
  if not FEnabled then Exit;
  if not Assigned(FTransport) then Exit;
  if not FTransport.IsConnected then Exit;
  if not Assigned(FSerializer) then Exit;

  while FOutgoing.Count > 0 do
  begin
    Msg := FOutgoing.Dequeue;
    try
      Data := FSerializer.SerializeMessage(Msg);
      FTransport.Send(Data);
    finally
      Msg.Free;
    end;
  end;
end;

procedure TGameNetworkSystem.PollIncomingFromTransport;
var
  Data: String;
  Msg: TGameNetworkMessage;
begin
  if not FEnabled then Exit;
  if not Assigned(FTransport) then Exit;
  if not FTransport.IsConnected then Exit;
  if not Assigned(FSerializer) then Exit;

  while FTransport.Receive(Data) do
  begin
    Msg := FSerializer.DeserializeMessage(Data);
    if Assigned(Msg) then
      FIncoming.Enqueue(Msg);
  end;
end;

procedure TGameNetworkSystem.ProcessIncomingMessages;
var
  Msg: TGameNetworkMessage;
  Agent: TPhysicalAgent;
begin
  if not Assigned(FAgents) then Exit;

  while FIncoming.Count > 0 do
  begin
    Msg := FIncoming.Dequeue;
    try
      case Msg.Kind of
        mkInputCommand:
          begin
            if FMode = nmServer then
            begin
              Agent := FAgents.FindByNetworkId(Msg.Input.NetworkId);
              if Assigned(Agent) then
                Agent.ApplyRemoteInputCommand(Msg.Input);
            end;
          end;

        mkStateSnapshot:
          begin
            if FMode = nmClient then
            begin
              Agent := FAgents.FindByNetworkId(Msg.State.NetworkId);
              if Assigned(Agent) then
                Agent.ApplyNetworkState(Msg.State);
            end;
          end;
      end;
    finally
      Msg.Free;
    end;
  end;
end;

procedure TGameNetworkSystem.Update(const SecondsPassed: Single);
begin
  if not FEnabled then Exit;

  FlushOutgoingToTransport;
  PollIncomingFromTransport;
  ProcessIncomingMessages;
end;

end.
