unit GameNetworkMessages;

interface

uses
  Classes, Contnrs,
  GameAgentNetwork;

type
  TGameNetworkMessageKind = (
    mkInputCommand,
    mkStateSnapshot
  );

  TGameNetworkMessage = class
  public
    Kind: TGameNetworkMessageKind;
    Input: TAgentInputCommand;
    State: TAgentNetworkState;
  end;

  TGameNetworkMessageQueue = class
  private
    FList: TObjectList;
    function GetCount: Integer;
    function GetItem(Index: Integer): TGameNetworkMessage;
  public
    constructor Create;
    destructor Destroy; override;

    procedure Enqueue(const AMsg: TGameNetworkMessage);
    function Dequeue: TGameNetworkMessage;
    procedure Clear;

    property Count: Integer read GetCount;
    property Items[Index: Integer]: TGameNetworkMessage read GetItem;
  end;

implementation

constructor TGameNetworkMessageQueue.Create;
begin
  inherited;
  FList := TObjectList.Create(true);
end;

destructor TGameNetworkMessageQueue.Destroy;
begin
  FList.Free;
  inherited;
end;

procedure TGameNetworkMessageQueue.Enqueue(const AMsg: TGameNetworkMessage);
begin
  FList.Add(AMsg);
end;

function TGameNetworkMessageQueue.Dequeue: TGameNetworkMessage;
begin
  if FList.Count = 0 then
    Exit(nil);

  Result := TGameNetworkMessage(FList[0]);
  FList.Extract(Result);
end;

procedure TGameNetworkMessageQueue.Clear;
begin
  FList.Clear;
end;

function TGameNetworkMessageQueue.GetCount: Integer;
begin
  Result := FList.Count;
end;

function TGameNetworkMessageQueue.GetItem(Index: Integer): TGameNetworkMessage;
begin
  Result := TGameNetworkMessage(FList[Index]);
end;

end.
