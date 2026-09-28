unit GameWorldAgents;

interface

uses
  Classes, Contnrs, SysUtils,
  GamePhysicalAgent, GameBotAgent, GameAgentNetwork;

type
  TPhysicalAgentList = class
  private
    FList: TObjectList;
    function GetCount: Integer;
    function GetItem(Index: Integer): TPhysicalAgent;
  public
    constructor Create;
    destructor Destroy; override;

    function Add(const AAgent: TPhysicalAgent): Integer;
    procedure Clear;
    function FindByNetworkId(const ANetworkId: TAgentNetworkId): TPhysicalAgent;

    property Count: Integer read GetCount;
    property Items[Index: Integer]: TPhysicalAgent read GetItem; default;
  end;

implementation

constructor TPhysicalAgentList.Create;
begin
  inherited;
  FList := TObjectList.Create(true);
end;

destructor TPhysicalAgentList.Destroy;
begin
  FList.Free;
  inherited;
end;

function TPhysicalAgentList.Add(const AAgent: TPhysicalAgent): Integer;
begin
  Result := FList.Add(AAgent);
end;

procedure TPhysicalAgentList.Clear;
begin
  FList.Clear;
end;

function TPhysicalAgentList.GetCount: Integer;
begin
  Result := FList.Count;
end;

function TPhysicalAgentList.GetItem(Index: Integer): TPhysicalAgent;
begin
  Result := TPhysicalAgent(FList[Index]);
end;

function TPhysicalAgentList.FindByNetworkId(const ANetworkId: TAgentNetworkId): TPhysicalAgent;
var
  I: Integer;
begin
  Result := nil;
  for I := 0 to Count - 1 do
    if Items[I].NetworkId = ANetworkId then
      Exit(Items[I]);
end;

end.
