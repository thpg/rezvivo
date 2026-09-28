unit GameLoopbackSession;

interface

uses
  Classes,
  CastleViewport, CastleScene, CastleTransform, CastleThirdPersonNavigation,
  GameWorld, GamePhysicalAgent, GameAgentControllers, GamePhysicsCommon,
  GameNetworkTransport, GameAgentNetwork, GameDebugDualWorldView, GamePath;

type
  TGameLoopbackSession = class
  private
    FOwner: TComponent;

    FPair: TLoopbackTransportPair;

    FServerWorld: TGameWorld;
    FClientWorld: TGameWorld;

    FServerAvatar: TPhysicalAgent;
    FClientAvatar: TPhysicalAgent;
    FClientController: TPlayerAgentController;

    FDebugView: TDualWorldDebugView;

    procedure CreateWorlds;
  public
    constructor Create(AOwner: TComponent; const AViewport: TCastleViewport);
    destructor Destroy; override;

    procedure InitializeAvatarPair(
      const ClientTransform: TCastleTransform;
      const ClientScene: TCastleScene;
      const ClientRigidBody: TCastleRigidBody;
      const ClientViewport: TCastleViewport;
      const ClientNavigation: TCastleThirdPersonNavigation;
      const LevelScene: TCastleScene;
      const ASourcePath: TGamePath
    );

    procedure Update(const SecondsPassed, FixedDelta: Single; const MaxSteps: Integer = 4);
    procedure ToggleVisualMode;

    property ServerWorld: TGameWorld read FServerWorld;
    property ClientWorld: TGameWorld read FClientWorld;
    property ServerAvatar: TPhysicalAgent read FServerAvatar;
    property ClientAvatar: TPhysicalAgent read FClientAvatar;
    property ClientController: TPlayerAgentController read FClientController;
    property DebugView: TDualWorldDebugView read FDebugView;
  end;

implementation

uses
  SysUtils, CastleVectors;

constructor TGameLoopbackSession.Create(AOwner: TComponent; const AViewport: TCastleViewport);
begin
  inherited Create;
  FOwner := AOwner;
  FDebugView := TDualWorldDebugView.Create(AOwner, AViewport);
  CreateWorlds;
end;

destructor TGameLoopbackSession.Destroy;
begin
  FreeAndNil(FClientController);
  FreeAndNil(FClientWorld);
  FreeAndNil(FServerWorld);
  FreeAndNil(FPair);
  FreeAndNil(FDebugView);
  inherited;
end;

procedure TGameLoopbackSession.CreateWorlds;
begin
  FPair := TLoopbackTransportPair.Create;

  FServerWorld := TGameWorld.Create;
  FServerWorld.Name := 'ServerWorld';
  FServerWorld.SetServerMode(FPair.CreateServerTransport);

  FClientWorld := TGameWorld.Create;
  FClientWorld.Name := 'ClientWorld';
  FClientWorld.SetClientMode(FPair.CreateClientTransport);
end;

procedure TGameLoopbackSession.InitializeAvatarPair(
  const ClientTransform: TCastleTransform;
  const ClientScene: TCastleScene;
  const ClientRigidBody: TCastleRigidBody;
  const ClientViewport: TCastleViewport;
  const ClientNavigation: TCastleThirdPersonNavigation;
  const LevelScene: TCastleScene;
  const ASourcePath: TGamePath
);
var
  SharedNetworkId: TAgentNetworkId;
begin
  FDebugView.SetClientVisual(ClientTransform, ClientScene);
  FDebugView.CreateServerVisualFrom(ClientScene);

  FClientController := TPlayerAgentController.Create;

  { server authoritative avatar }
  FServerAvatar := TPhysicalAgent.Create(FOwner);
  FServerAvatar.Name := 'ServerAvatar';
  FServerAvatar.SetupActor(
    FDebugView.ServerTransform,
    FDebugView.ServerScene,
    nil,
    ClientViewport,
    nil,
    LevelScene
  );
  { Путь — копией из общего пути (напрямую из FIT, без INI). }
  if Assigned(ASourcePath) then
    ASourcePath.CopyTo(FServerAvatar.Path);
  FServerAvatar.RecreatePhysics(pmKinematicCurrent);
  FServerAvatar.Initialize;
  FServerAvatar.InitializeAtStart;
  FServerAvatar.NetworkAuthority := naServerAuthoritative;
  FServerWorld.AddAgent(FServerAvatar);
  FServerWorld.Avatar := FServerAvatar;
  SharedNetworkId := FServerWorld.Network.RegisterAgent(FServerAvatar);

  { client predicted avatar }
  FClientAvatar := TPhysicalAgent.Create(FOwner);
  FClientAvatar.Name := 'ClientAvatar';
  FClientAvatar.SetupActor(
    ClientTransform,
    ClientScene,
    ClientRigidBody,
    ClientViewport,
    ClientNavigation,
    LevelScene
  );
  FClientAvatar.SetController(FClientController);
  if Assigned(ASourcePath) then
    ASourcePath.CopyTo(FClientAvatar.Path);
  FClientAvatar.RecreatePhysics(pmKinematicCurrent);
  FClientAvatar.Initialize;
  FClientAvatar.InitializeAtStart;
  FClientAvatar.NetworkAuthority := naClientPredicted;
  FClientAvatar.NetworkId := SharedNetworkId;
  FClientWorld.AddAgent(FClientAvatar);
  FClientWorld.Avatar := FClientAvatar;
end;

procedure TGameLoopbackSession.Update(const SecondsPassed, FixedDelta: Single; const MaxSteps: Integer);
begin
  if Assigned(FClientWorld) then
    FClientWorld.Update(SecondsPassed, FixedDelta, MaxSteps);

  if Assigned(FServerWorld) then
    FServerWorld.Update(SecondsPassed, FixedDelta, MaxSteps);

  if Assigned(FClientWorld) then
    FClientWorld.Network.Update(SecondsPassed);

  if Assigned(FClientAvatar) and Assigned(FServerAvatar) then
  begin
    FDebugView.UpdateClientVisual(
      FClientAvatar.State.WorldPosition,
      FClientAvatar.State.ForwardDir
    );

    FDebugView.UpdateServerVisual(
      FServerAvatar.State.WorldPosition,
      FServerAvatar.State.ForwardDir
    );

    FDebugView.UpdateDistanceMarker(
      FClientAvatar.State.WorldPosition,
      FServerAvatar.State.WorldPosition
    );
  end;
end;

procedure TGameLoopbackSession.ToggleVisualMode;
begin
  if Assigned(FDebugView) then
    FDebugView.ToggleMode;
end;

end.
