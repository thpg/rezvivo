{ GameAgentControllers — unified controller classes for all rider types.

  TPowerController — universal power + auto-move controller.
    Used for local player (keyboard/BLE power, toggle auto-move)
    and local bots (fixed power, always auto-move).

  TRemotePowerController — power fed from server relay.
    Used for remote/guest riders. Always auto-moves.
    Call FeedServerData each frame with latest server values.

  Legacy aliases:
    TPlayerAgentController = TPowerController
    TBotPathController = TPowerController (SetEnabled → SetAutoMove)
}
unit GameAgentControllers;

interface

uses
  Classes,
  GameAgentControl, GamePhysicsCommon;

type
  { ═══════════════════════════════════════════════════════════════════
    TPowerController — replaces TPlayerAgentController + TBotPathController.
    Stores desired power and auto-move flag, feeds them to the agent.
    ═══════════════════════════════════════════════════════════════════ }
  {$M+}
  TPowerController = class(TCustomAgentController)
  private
    FDesiredPowerWatts: Single;
    FAutoMove: Boolean;
  public
    constructor Create;
    procedure SetDesiredPower(const APower: Single);
    procedure SetAutoMove(const AValue: Boolean);
    procedure ToggleAutoMove;
    function AutoMove: Boolean;
    { Alias for SetAutoMove — backward compat with TBotPathController }
    procedure SetEnabled(const AValue: Boolean);
    procedure UpdateControl(const SecondsPassed: Single; var Input: TAgentControlInput); override;
  published
    { RTTI-доступ (MCP). Имя AutoMove занято методом — свойство
      называется AutoMoveEnabled. }
    property DesiredPowerWatts: Single read FDesiredPowerWatts write SetDesiredPower;
    property AutoMoveEnabled: Boolean read FAutoMove write SetAutoMove;
  end;

  { ═══════════════════════════════════════════════════════════════════
    TRemotePowerController — for server-relayed guest riders.
    Power, cadence, and active state come from relay server.
    Always auto-moves when active.
    ═══════════════════════════════════════════════════════════════════ }
  TRemotePowerController = class(TCustomAgentController)
  private
    FPowerWatts: Single;
    FServerSpeed:Single;
    FCadence: Integer;
    FActive: Boolean;
  public
    constructor Create;

    { Call each frame with latest data from relay server }
    procedure FeedServerData(APower: Single; ACadence: Integer;ASpeed:Single=-1);

    { Deactivate when rider disappears from server }
    procedure SetActive(AValue: Boolean);
    function IsActive: Boolean;

    procedure UpdateControl(const SecondsPassed: Single; var Input: TAgentControlInput); override;
  published
    property PowerWatts: Single read FPowerWatts;
    property Cadence: Integer read FCadence;
    property Active: Boolean read FActive write SetActive;
  end;
  {$M-}

  { ── Backward compatibility aliases ── }
  TPlayerAgentController = TPowerController;
  TBotPathController = TPowerController;

implementation

{ ═══════════════════════════════════════════════════════════════════
  TPowerController
  ═══════════════════════════════════════════════════════════════════ }

constructor TPowerController.Create;
begin
  inherited Create;
  FDesiredPowerWatts := DefaultPower;
  FAutoMove := false;
end;

procedure TPowerController.SetDesiredPower(const APower: Single);
begin
  FDesiredPowerWatts := APower;
end;

procedure TPowerController.SetAutoMove(const AValue: Boolean);
begin
  FAutoMove := AValue;
end;

procedure TPowerController.SetEnabled(const AValue: Boolean);
begin
  FAutoMove := AValue;
end;

procedure TPowerController.ToggleAutoMove;
begin
  FAutoMove := not FAutoMove;
end;

function TPowerController.AutoMove: Boolean;
begin
  Result := FAutoMove;
end;

procedure TPowerController.UpdateControl(const SecondsPassed: Single; var Input: TAgentControlInput);
begin
  Input.Reset;
  Input.DesiredPowerWatts := FDesiredPowerWatts;
  Input.WantsAutoMove := FAutoMove;
end;

{ ═══════════════════════════════════════════════════════════════════
  TRemotePowerController
  ═══════════════════════════════════════════════════════════════════ }

constructor TRemotePowerController.Create;
begin
  inherited Create;
  FPowerWatts := 0;
  FCadence := 0;
  FActive := False;
end;

procedure TRemotePowerController.FeedServerData(APower: Single; ACadence: Integer;ASpeed:Single);
begin
  FPowerWatts := APower;
  FServerSpeed:=ASpeed;
  FCadence := ACadence;
end;

procedure TRemotePowerController.SetActive(AValue: Boolean);
begin
  FActive := AValue;
end;

function TRemotePowerController.IsActive: Boolean;
begin
  Result := FActive;
end;

procedure TRemotePowerController.UpdateControl(const SecondsPassed: Single; var Input: TAgentControlInput);
begin
  Input.Reset;
  Input.DesiredPowerWatts := FPowerWatts;
  Input.WantsAutoMove := FActive and ((FPowerWatts > 0)or(FServerSpeed>0.05));
end;

end.
