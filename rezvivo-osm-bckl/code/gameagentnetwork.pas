unit GameAgentNetwork;

interface

uses
  CastleVectors;

type
  TNetworkAuthority = (
    naLocalOnly,
    naServerAuthoritative,
    naClientPredicted,
    naRemoteProxy
  );

  TGameNetworkMode = (
    nmOffline,
    nmServer,
    nmClient
  );

  TAgentNetworkId = type UInt64;

  TAgentInputCommand = record
    NetworkId: TAgentNetworkId;
    SequenceId: Cardinal;
    DeltaTime: Single;
    ClientTime: Double;

    MoveForward: Boolean;
    MoveBackward: Boolean;
    TurnLeft: Boolean;
    TurnRight: Boolean;
    Brake: Boolean;

    DesiredPowerWatts: Single;
    WantsAutoMove: Boolean;
  end;

  TAgentNetworkState = record
    NetworkId: TAgentNetworkId;
    SequenceId: Cardinal;
    ServerTime: Double;

    Position: TVector3;
    ForwardDir: TVector3;
    Speed: Single;
    PowerWatts: Single;

    AutoMove: Boolean;
    PhysicsMode: Integer;
  end;

  INetworkReplicable = interface
    ['{FF09B8E9-5BE7-4D75-9A4C-7C5DAD9D9A11}']
    function BuildNetworkState: TAgentNetworkState;
    procedure ApplyNetworkState(const AState: TAgentNetworkState);
  end;

implementation

end.
