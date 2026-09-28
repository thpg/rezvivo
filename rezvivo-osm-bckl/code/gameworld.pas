unit GameWorld;

interface

uses
  Classes,
  GamePhysicalAgent, GameBotAgent, GameWorldAgents, GameNetworkSystem,
  GameAgentNetwork, GameNetworkTransport;

type
  {$M+}
  TGameWorld = class
  private
    FAgents: TPhysicalAgentList;
    FNetwork: TGameNetworkSystem;
    FAvatar: TPhysicalAgent;
    FName: String;
  public
    constructor Create;
    destructor Destroy; override;

    procedure SetOfflineMode;
    procedure SetServerMode(const ATransport: INetworkTransport = nil);
    procedure SetClientMode(const ATransport: INetworkTransport = nil);

    function AddAgent(const AAgent: TPhysicalAgent): Integer;
    function AddBot(const ABot: TBotAgent): Integer;
    procedure RegisterAgentInNetwork(const AAgent: TPhysicalAgent);

    procedure Update(const SecondsPassed, FixedDelta: Single; const MaxSteps: Integer = 4);

    property Agents: TPhysicalAgentList read FAgents;
    property Network: TGameNetworkSystem read FNetwork;
  published
    property Name: String read FName write FName;
    property Avatar: TPhysicalAgent read FAvatar write FAvatar;
  end;
  {$M-}

implementation

constructor TGameWorld.Create;
begin
  inherited;
  FAgents := TPhysicalAgentList.Create;
  FNetwork := TGameNetworkSystem.Create;
  FNetwork.SetAgents(FAgents);
  FNetwork.SetOfflineMode;
  FName := 'World';
end;

destructor TGameWorld.Destroy;
begin
  FNetwork.Free;
  FAgents.Free;
  inherited;
end;

procedure TGameWorld.SetOfflineMode;
begin
  FNetwork.SetOfflineMode;
end;

procedure TGameWorld.SetServerMode(const ATransport: INetworkTransport);
begin
  FNetwork.SetServerMode(ATransport);
end;

procedure TGameWorld.SetClientMode(const ATransport: INetworkTransport);
begin
  FNetwork.SetClientMode(ATransport);
end;

function TGameWorld.AddAgent(const AAgent: TPhysicalAgent): Integer;
begin
  Result := FAgents.Add(AAgent);
end;

function TGameWorld.AddBot(const ABot: TBotAgent): Integer;
begin
  Result := FAgents.Add(ABot);
end;

procedure TGameWorld.RegisterAgentInNetwork(const AAgent: TPhysicalAgent);
begin
  if Assigned(AAgent) then
    FNetwork.RegisterAgent(AAgent);
end;

procedure TGameWorld.Update(const SecondsPassed, FixedDelta: Single; const MaxSteps: Integer);
var
  I: Integer;
  Agent: TPhysicalAgent;
begin
  case FNetwork.Mode of
    nmOffline:
      begin
        for I := 0 to FAgents.Count - 1 do
          FAgents[I].UpdateOffline(SecondsPassed, FixedDelta, MaxSteps);
      end;

    nmServer:
      begin
        FNetwork.Update(SecondsPassed);

        for I := 0 to FAgents.Count - 1 do
        begin
          Agent := FAgents[I];
          Agent.UpdateAsAuthoritativeServer(SecondsPassed, FixedDelta, MaxSteps);
          FNetwork.QueueOutgoingState(Agent.BuildNetworkState);
        end;

        FNetwork.Update(SecondsPassed);
      end;

    nmClient:
      begin
        for I := 0 to FAgents.Count - 1 do
        begin
          Agent := FAgents[I];

          case Agent.NetworkAuthority of
            naClientPredicted:
              begin
                Agent.UpdatePredictedClient(SecondsPassed, FixedDelta, MaxSteps);
                FNetwork.QueueOutgoingInput(Agent.BuildInputCommand(SecondsPassed));
              end;

            naRemoteProxy:
              Agent.UpdateAsRemoteProxy(SecondsPassed);
          end;
        end;

        FNetwork.Update(SecondsPassed);
      end;
  end;
end;

end.
