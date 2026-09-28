unit GameAgentControl;

{$mode objfpc}
{$modeswitch advancedrecords}
interface

uses
  Classes,
  GamePhysicsCommon;

type
  TAgentControlInput = record
    MoveForward: Boolean;
    MoveBackward: Boolean;
    TurnLeft: Boolean;
    TurnRight: Boolean;
    Brake: Boolean;

    DesiredPowerWatts: Single;
    BrakeForceN: Single; { measured force; never encode braking as negative watts }
    WantsAutoMove: Boolean;

    procedure Reset;
  end;

  IAgentController = interface
    ['{A2A7B5B1-29B4-4B9A-8B3D-0D6D6C8A4101}']
    procedure UpdateControl(const SecondsPassed: Single; var Input: TAgentControlInput);
  end;

  TCustomAgentController = class(TInterfacedObject, IAgentController)
  public
    procedure UpdateControl(const SecondsPassed: Single; var Input: TAgentControlInput); virtual; abstract;
  end;

implementation

procedure TAgentControlInput.Reset;
begin
  MoveForward := false;
  MoveBackward := false;
  TurnLeft := false;
  TurnRight := false;
  Brake := false;
  DesiredPowerWatts := DefaultPower;
  BrakeForceN := 0;
  WantsAutoMove := false;
end;

end.
