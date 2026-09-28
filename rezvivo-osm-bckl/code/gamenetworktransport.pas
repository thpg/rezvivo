unit GameNetworkTransport;

interface

uses
  Classes, SysUtils, Contnrs;

type
  INetworkTransport = interface
    ['{E50D1A79-0C14-4C63-B531-0A8A26B9F9E2}']
    procedure Connect;
    procedure Disconnect;
    function IsConnected: Boolean;

    procedure Send(const AData: String);
    function Receive(out AData: String): Boolean;
  end;

  TLoopbackSharedQueue = class
  private
    FQueue: TStringList;
  public
    constructor Create;
    destructor Destroy; override;

    procedure Push(const S: String);
    function Pop(out S: String): Boolean;
  end;

  TLoopbackTransport = class(TInterfacedObject, INetworkTransport)
  private
    FIncoming: TLoopbackSharedQueue;
    FOutgoing: TLoopbackSharedQueue;
    FConnected: Boolean;
  public
    constructor Create(const AIncoming, AOutgoing: TLoopbackSharedQueue);

    procedure Connect;
    procedure Disconnect;
    function IsConnected: Boolean;

    procedure Send(const AData: String);
    function Receive(out AData: String): Boolean;
  end;

  TLoopbackTransportPair = class
  private
    FClientToServer: TLoopbackSharedQueue;
    FServerToClient: TLoopbackSharedQueue;
  public
    constructor Create;
    destructor Destroy; override;

    function CreateClientTransport: INetworkTransport;
    function CreateServerTransport: INetworkTransport;
  end;

implementation

constructor TLoopbackSharedQueue.Create;
begin
  inherited;
  FQueue := TStringList.Create;
end;

destructor TLoopbackSharedQueue.Destroy;
begin
  FQueue.Free;
  inherited;
end;

procedure TLoopbackSharedQueue.Push(const S: String);
begin
  FQueue.Add(S);
end;

function TLoopbackSharedQueue.Pop(out S: String): Boolean;
begin
  Result := FQueue.Count > 0;
  if not Result then Exit;

  S := FQueue[0];
  FQueue.Delete(0);
end;

constructor TLoopbackTransport.Create(const AIncoming, AOutgoing: TLoopbackSharedQueue);
begin
  inherited Create;
  FIncoming := AIncoming;
  FOutgoing := AOutgoing;
  FConnected := false;
end;

procedure TLoopbackTransport.Connect;
begin
  FConnected := true;
end;

procedure TLoopbackTransport.Disconnect;
begin
  FConnected := false;
end;

function TLoopbackTransport.IsConnected: Boolean;
begin
  Result := FConnected;
end;

procedure TLoopbackTransport.Send(const AData: String);
begin
  if not FConnected then Exit;
  if not Assigned(FOutgoing) then Exit;
  FOutgoing.Push(AData);
end;

function TLoopbackTransport.Receive(out AData: String): Boolean;
begin
  AData := '';
  if not FConnected then Exit(false);
  if not Assigned(FIncoming) then Exit(false);
  Result := FIncoming.Pop(AData);
end;

constructor TLoopbackTransportPair.Create;
begin
  inherited;
  FClientToServer := TLoopbackSharedQueue.Create;
  FServerToClient := TLoopbackSharedQueue.Create;
end;

destructor TLoopbackTransportPair.Destroy;
begin
  FServerToClient.Free;
  FClientToServer.Free;
  inherited;
end;

function TLoopbackTransportPair.CreateClientTransport: INetworkTransport;
begin
  Result := TLoopbackTransport.Create(FServerToClient, FClientToServer);
end;

function TLoopbackTransportPair.CreateServerTransport: INetworkTransport;
begin
  Result := TLoopbackTransport.Create(FClientToServer, FServerToClient);
end;

end.
