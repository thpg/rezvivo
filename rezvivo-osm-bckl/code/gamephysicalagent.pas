unit GamePhysicalAgent;

interface

uses
  Classes, SysUtils, Math, GameMotionTrace,
  CastleVectors, CastleScene, CastleTransform, CastleViewport,
  CastleThirdPersonNavigation, CastleShapes, CastleColors,
  GamePath, GamePhysicsCommon, GamePhysicsBase, castlerenderoptions,
  GameAgentControl, GameAgentNetwork, GameProfiler;

type
  TAgentReplayState = record
    Physics: TPhysicsReplayState;
    Path: TPathReplayState;
    Ground: TGroundTrackingReplay;
    ControlInput: TAgentControlInput;
    LocalClock: Double;
    LastGroundClock: Double;
    PhysicsTranslation: TVector3;
    VisualExtrapolated: Boolean;
    Translation: TVector3;
    Rotation: TVector4;
  end;

  TBufferedSnapshot = record
    State: TAgentNetworkState;
    ReceivedLocalTime: Double;
  end;

  {$M+}
  TPhysicalAgent = class(TInterfacedObject, INetworkReplicable)
  private
    FActor: TPhysicsActor;
    FState: TPhysicsState;
    FPath: TGamePath;
    FDebug: TPhysicsDebug;
    FPhysics: TCustomActorPhysics;
    FPhysicsMode: TPhysicsMode;
    FOwner: TComponent;
    FName: String;

    FController: IAgentController;
    FControlInput: TAgentControlInput;
    FPendingRemoteInput: TAgentInputCommand;
    FHasPendingRemoteInput: Boolean;

    FNetworkId: TAgentNetworkId;
    FNetworkAuthority: TNetworkAuthority;
    FLastAppliedSequenceId: Cardinal;
    FLocalSequenceCounter: Cardinal;

    FLocalClock: Double;
    { Метка последнего запуска UpdateVisualGroundPlacement по FLocalClock;
      < 0 — ещё не было (первый кадр/телепорт — выполнить сразу).
      Троттлинг 30 Гц: на высоком FPS 7 проб земли на КАЖДЫЙ render-кадр
      были единственной значимой ценой «пустого» кадра (~0.22 мс). }
    FLastGroundClock: Double;

    FSnapshotBuffer: array of TBufferedSnapshot;
    FSnapshotCount: Integer;

    FPredictionHardSnapDistance: Single;
    FPredictionSoftSnapDistance: Single;
    FInterpolationBackTime: Double;

    { Визуальная экстраполяция }
    FPhysicsTranslation: TVector3;
    FVisualExtrapolated: Boolean;

    { Диагностика }
    FFrameCounter: Cardinal;
    FProfiler: TFrameProfiler;

    procedure FreePhysics;
    procedure PushSnapshot(const AState: TAgentNetworkState);
    procedure TrimOldSnapshots;
    function TryGetInterpolationStates(const TargetServerTime: Double;
      out AState1, AState2: TAgentNetworkState; out Alpha: Single): Boolean;
    procedure ApplyInterpolatedState(const AState1, AState2: TAgentNetworkState; const Alpha: Single);
    procedure ReconcileWithAuthoritativeState(const AState: TAgentNetworkState);

    procedure RestorePhysicsPosition;
    procedure ExtrapolateVisual;
    procedure FinishVisualUpdate(const SecondsPassed: Single);
  protected
    procedure AfterPhysicsCreated; virtual;
  public
    function CaptureReplay: TAgentReplayState;
    procedure RestoreReplay(const Saved: TAgentReplayState);
  public
    constructor Create(AOwner: TComponent); virtual;
    destructor Destroy; override;

    procedure SetupActor(const ATransform: TCastleTransform;
      const AScene: TCastleScene; const ARigidBody: TCastleRigidBody;
      const AViewport: TCastleViewport; const ANavigation: TCastleThirdPersonNavigation;
      const ALevelScene: TCastleScene);

    procedure SetController(const AController: IAgentController);
    procedure RecreatePhysics(const AMode: TPhysicsMode);

    procedure Initialize;
    procedure InitializeAtStart(const InitialGroundY: Single = NaN);
    procedure TeleportToPath(const Pos: TPathPosition);
    procedure StartMoving;
    procedure StopMoving;
    procedure FixedStep(const FixedDelta: Single);
    procedure TracePosition(Stage: TMotionStage);

    procedure UpdateOffline(const SecondsPassed, FixedDelta: Single; const MaxSteps: Integer = 4); virtual;
    procedure UpdateAsAuthoritativeServer(const SecondsPassed, FixedDelta: Single; const MaxSteps: Integer = 4); virtual;
    procedure UpdateAsRemoteProxy(const SecondsPassed: Single); virtual;
    procedure UpdatePredictedClient(const SecondsPassed, FixedDelta: Single; const MaxSteps: Integer = 4); virtual;

    procedure ApplyRemoteInputCommand(const ACommand: TAgentInputCommand);

    procedure CreateDebugSpheres;
    procedure ToggleDebugSpheres;

    function BuildInputCommand(const ADeltaTime: Single): TAgentInputCommand;
    function BuildNetworkState: TAgentNetworkState;
    procedure ApplyNetworkState(const AState: TAgentNetworkState);

    function ShouldSimulateLocally: Boolean;

    { Set physics LOD — controls which effects are computed.
      plFull: trajectory, turn forces, lean, debug spheres, camera lock.
      plReduced: path following + acceleration, skip trajectory/lean/turn.
      plMinimal: simple movement, no ground raycast. }
    procedure SetPhysicsLOD(ALOD: TPhysicsLOD);
    function GetPhysicsLOD: TPhysicsLOD;

    { Factory: create agent, setup actor, load path, create physics, initialize.
      Reduces the 8-step init sequence to one call.
      Returns the created agent (caller owns it). }
    class function SpawnOnPath(
      AOwner: TComponent;
      const AName: string;
      const ATransform: TCastleTransform;
      const AScene: TCastleScene;
      const ARigidBody: TCastleRigidBody;
      const AViewport: TCastleViewport;
      const ANavigation: TCastleThirdPersonNavigation;
      const ALevelScene: TCastleScene;
      const APathFileName: string;
      APhysicsMode: TPhysicsMode;
      AAuthority: TNetworkAuthority;
      ALOD: TPhysicsLOD = plFull;
      AController: IAgentController = nil): TPhysicalAgent;

    property Actor: TPhysicsActor read FActor;
    property Path: TGamePath read FPath;
    property Debug: TPhysicsDebug read FDebug;
    property Physics: TCustomActorPhysics read FPhysics;
    property Controller: IAgentController read FController;
    property Profiler: TFrameProfiler read FProfiler;
  published
    { Скалярное состояние для RTTI-доступа (MCP). Интерфейсные свойства
      (Controller) остаются public — интерфейсы в published недоступны. }
    property Name: String read FName write FName;
    property PhysicsMode: TPhysicsMode read FPhysicsMode;
    property PhysicsLOD: TPhysicsLOD read GetPhysicsLOD write SetPhysicsLOD;
    property NetworkId: TAgentNetworkId read FNetworkId write FNetworkId;
    property NetworkAuthority: TNetworkAuthority read FNetworkAuthority write FNetworkAuthority;
    property LastAppliedSequenceId: Cardinal read FLastAppliedSequenceId;
    { Live-состояние физики: dotted-доступ вида world.Avatar.State.Speed }
    property State: TPhysicsState read FState;
  end;
  {$M-}

var
  { FPS-бисекция (CLI, стиль --nofx/--noshadow): выключают части
    UpdateOffline для замера доли каждой в кадре. Ставятся из
    gameviewplay.Start через CliFlag. Только для замеров — симуляция
    с ними ломается (агент не едет / висит в воздухе). }
  AgentCliNoControl: Boolean = False;  { --nocontrol: без FController.UpdateControl }
  AgentCliNoSteps:   Boolean = False;  { --nosteps: без фикс-шаговой интеграции }
  AgentCliNoGround:  Boolean = False;  { --noground: без UpdateVisualGroundPlacement (7 запросов земли на кадр) }

implementation

uses
  DebugLog,
  GamePhysicsKinematic,
  GamePhysicsEngineRigidBody;

const
  DebugSphereRadius = 0.05;
  SnapshotBufferMax = 32;
  { Период троттлинга UpdateVisualGroundPlacement (30 Гц). }
  GroundPlacementPeriod = 1.0 / 30.0;
  { Отладочные линии разметки/центра/края: длина вдоль движения и
    толщина бруса-линии (метры). Длина = 3 м по требованию. }
  DebugLineLength    = 3.0;
  DebugLineThickness = 0.08;

function DebugLog_Enabled(Agent: TPhysicalAgent): Boolean; inline;
begin
  Result := False; { D is visual diagnostics only. }
end;

function V3S(const V: TVector3): string;
begin
  Result := Format('(%.4f, %.4f, %.4f)', [V.X, V.Y, V.Z]);
end;

function TPhysicalAgent.CaptureReplay: TAgentReplayState;
begin
  Result.Physics:=FState.CaptureReplay;
  Result.Path:=FPath.CaptureReplay;
  Result.Ground:=FPhysics.CaptureReplay;
  Result.ControlInput:=FControlInput;
  Result.LocalClock:=FLocalClock;
  Result.LastGroundClock:=FLastGroundClock;
  Result.PhysicsTranslation:=FPhysicsTranslation;
  Result.VisualExtrapolated:=FVisualExtrapolated;
  Result.Translation:=FActor.Transform.Translation;
  Result.Rotation:=FActor.Transform.Rotation;
end;

procedure TPhysicalAgent.RestoreReplay(const Saved: TAgentReplayState);
begin
  MotionTrace.Event(Self, meSeek);
  FState.RestoreReplay(Saved.Physics);
  FPath.RestoreReplay(Saved.Path);
  FPhysics.RestoreReplay(Saved.Ground);
  FControlInput:=Saved.ControlInput;
  FLocalClock:=Saved.LocalClock;
  FLastGroundClock:=Saved.LastGroundClock;
  FPhysicsTranslation:=Saved.PhysicsTranslation;
  FVisualExtrapolated:=Saved.VisualExtrapolated;
  FActor.Transform.Translation:=Saved.Translation;
  FActor.Transform.Rotation:=Saved.Rotation;
end;

constructor TPhysicalAgent.Create(AOwner: TComponent);
begin
  inherited Create;
  FOwner := AOwner;
  FActor := TPhysicsActor.Create;
  FState := TPhysicsState.Create;
  FPath := TGamePath.Create;
  FDebug := TPhysicsDebug.Create;
  FControlInput.Reset;
  FHasPendingRemoteInput := false;
  FName := 'Agent';
  FNetworkId := 0;
  FNetworkAuthority := naLocalOnly;
  FLastAppliedSequenceId := 0;
  FLocalSequenceCounter := 0;
  FLocalClock := 0;
  FLastGroundClock := -1;   { первый запуск ground placement — сразу }
  FSnapshotCount := 0;
  SetLength(FSnapshotBuffer, SnapshotBufferMax);
  FPredictionHardSnapDistance := 1.5;
  FPredictionSoftSnapDistance := 0.15;
  FInterpolationBackTime := 0.10;
  FVisualExtrapolated := false;
  FPhysicsTranslation := Vector3(0, 0, 0);
  FFrameCounter := 0;
  FProfiler := TFrameProfiler.Create;
end;

destructor TPhysicalAgent.Destroy;
begin
  FreePhysics;
  FreeAndNil(FProfiler);
  FreeAndNil(FDebug);
  FreeAndNil(FPath);
  FreeAndNil(FState);
  FreeAndNil(FActor);
  inherited;
end;

procedure TPhysicalAgent.FreePhysics;
begin
  FreeAndNil(FPhysics);
end;

procedure TPhysicalAgent.SetupActor(const ATransform: TCastleTransform;
  const AScene: TCastleScene; const ARigidBody: TCastleRigidBody;
  const AViewport: TCastleViewport; const ANavigation: TCastleThirdPersonNavigation;
  const ALevelScene: TCastleScene);
begin
  FActor.Transform := ATransform;
  FActor.Scene := AScene;
  FActor.RigidBody := ARigidBody;
  FActor.Viewport := AViewport;
  FActor.Navigation := ANavigation;
  FPath.SetLevelScene(ALevelScene);
end;

procedure TPhysicalAgent.SetController(const AController: IAgentController);
begin FController := AController; end;

procedure TPhysicalAgent.RecreatePhysics(const AMode: TPhysicsMode);
begin
  FreePhysics;
  FPhysicsMode := AMode;
  case FPhysicsMode of
    pmKinematicCurrent:
      FPhysics := TKinematicActorPhysics.Create(FActor, FState, FPath, FDebug, @FControlInput);
    pmEngineRigidBody:
      FPhysics := TEngineRigidBodyPhysics.Create(FActor, FState, FPath, FDebug, @FControlInput);
  end;
  AfterPhysicsCreated;
end;

procedure TPhysicalAgent.AfterPhysicsCreated;
begin
  if Assigned(FPhysics) then
    FPhysics.Profiler := FProfiler;
end;

procedure TPhysicalAgent.Initialize;
begin
  if Assigned(FPhysics) then FPhysics.Initialize;
end;

procedure TPhysicalAgent.InitializeAtStart(const InitialGroundY: Single);
begin
  MotionTrace.Event(Self, meInitialize);
  FVisualExtrapolated := false;
  FFrameCounter := 0;
  FLastGroundClock := -1;
  if Assigned(FPhysics) then FPhysics.InitializeAtStart(InitialGroundY);
end;

procedure TPhysicalAgent.TeleportToPath(const Pos: TPathPosition);
begin
  MotionTrace.Event(Self, meTeleport);
  FPath.Position := FPath.ClampPathPosition(Pos);
  FState.WorldPosition := FPath.RoadCenterAt(FPath.Position);
  FState.PrevWorldPosition := FState.WorldPosition;
  FState.ForwardDir := FPath.FollowDirectionXZ(FPath.Position);
  FState.CurrentYawRad := ArcTan2(FState.ForwardDir.Z, FState.ForwardDir.X);
  FPath.SmoothedRouteDir := FState.ForwardDir;
  FState.MovementVelocity := Vector3(0, 0, 0);
  FState.AccumulatedTime := 0;
  FState.TrajectorySampleCount := 0;
  FState.TrajectorySampleIndex := 0;
  FVisualExtrapolated := False;
  FLastGroundClock := -1;
  if Assigned(FActor.Transform) then
    FActor.Transform.Translation := FState.WorldPosition;
  if Assigned(FPhysics) then FPhysics.ResetTrackingAfterTeleport;
end;

procedure TPhysicalAgent.StartMoving;
begin
  if Assigned(FPhysics) then FPhysics.StartMoving;
end;

procedure TPhysicalAgent.StopMoving;
begin
  MotionTrace.Event(Self, meStop);
  { Commit the last visible XZ when pausing: no backward fractional step,
    and no stale extrapolation base on resume. }
  if FVisualExtrapolated and Assigned(FActor.Transform) then
  begin
    FState.WorldPosition.X := FActor.Transform.Translation.X;
    FState.WorldPosition.Z := FActor.Transform.Translation.Z;
    FPath.Position := FPath.ProjectFollow(FState.WorldPosition, FPath.Position, 2);
  end;
  FVisualExtrapolated := False;
  if Assigned(FPhysics) then FPhysics.StopMoving;
end;

procedure TPhysicalAgent.TracePosition(Stage: TMotionStage);
var Cam: TVector3;
begin
  if MotionTrace.Target <> Pointer(Self) then Exit;
  if (FState = nil) or (FActor.Transform = nil) then Exit;
  Cam := Vector3(0,0,0);
  if (FActor.Viewport <> nil) and (FActor.Viewport.Camera <> nil) then
    Cam := FActor.Viewport.Camera.Translation;
  MotionTrace.Stage(Self, Stage, FState.WorldPosition, FActor.Transform.Translation, Cam);
end;

procedure TPhysicalAgent.FixedStep(const FixedDelta: Single);
var BeforeTime: Single; BeforePos, Travel: TVector3; Traced: Boolean;
begin
  Traced := MotionTrace.Target = Pointer(Self);
  if Traced then begin BeforeTime := FState.SimulationTime; BeforePos := FState.WorldPosition end;
  if Assigned(FPhysics) then FPhysics.FixedStep(FixedDelta);
  if Traced then begin
    Travel := Vector3(0,0,0);
    if FState.SimulationTime <> BeforeTime then Travel := FState.MovementVelocity * FixedDelta;
    MotionTrace.Step(Self, Travel);
    if Assigned(FState.PositionConstraint) and
      (Sqr(FState.WorldPosition.X-BeforePos.X-Travel.X) +
       Sqr(FState.WorldPosition.Z-BeforePos.Z-Travel.Z) > 0.0001) then
      MotionTrace.Event(Self, meConstraint);
  end;
end;

function TPhysicalAgent.ShouldSimulateLocally: Boolean;
begin
  Result := FNetworkAuthority in [naLocalOnly, naServerAuthoritative, naClientPredicted];
end;

procedure TPhysicalAgent.RestorePhysicsPosition;
begin
  if FPhysicsMode <> pmKinematicCurrent then
  begin
    if FVisualExtrapolated and Assigned(FActor.Transform) then
      FActor.Transform.Translation := FPhysicsTranslation;
    FVisualExtrapolated := False;
    Exit;
  end;
  { State is the physical authority even after a network/teleport correction.
    Preserve the last visual Y until ground placement runs. }
  if Assigned(FActor.Transform) then
    FActor.Transform.Translation := Vector3(FState.WorldPosition.X,
      FActor.Transform.Translation.Y, FState.WorldPosition.Z);
  FVisualExtrapolated := false;
end;

procedure TPhysicalAgent.ExtrapolateVisual;
var
  Remaining: Single;
  ExtraPos: TVector3;
begin
  if not Assigned(FActor.Transform) then Exit;
  if not Assigned(FState) then Exit;
  if not FState.AutoMove then Exit;
  if Abs(FState.CurrentSpeed) < 0.001 then Exit;

  Remaining := FState.AccumulatedTime;
  if Remaining <= 0 then Exit;

  FPhysicsTranslation := FActor.Transform.Translation;
  ExtraPos := FPhysicsTranslation;
  if FPhysicsMode = pmKinematicCurrent then
    ExtraPos := ExtraPos + FState.MovementVelocity * Remaining
  else
    ExtraPos := ExtraPos + FState.ForwardDir * (FState.CurrentSpeed * Remaining);
  if (FPhysicsMode = pmKinematicCurrent) and Assigned(FPhysics) then
    ExtraPos := FPhysicsTranslation + FPhysics.ConstrainGroundMovement(
      FPhysicsTranslation, ExtraPos - FPhysicsTranslation);
  if Assigned(FState.TrafficMoveConstraint) then
    ExtraPos:=FPhysicsTranslation+FState.TrafficMoveConstraint(FState.TrafficTag,
      FPhysicsTranslation,ExtraPos-FPhysicsTranslation,False);
  FActor.Transform.Translation := ExtraPos;
  FVisualExtrapolated := true;
end;

procedure TPhysicalAgent.FinishVisualUpdate(const SecondsPassed: Single);
var
  DtGround: Single;
  Pos: TVector3;
begin
  if Assigned(FState.PositionConstraint) and Assigned(FActor.Transform) then
  begin
    Pos := FActor.Transform.Translation;
    if FState.PositionConstraint(Pos.X, Pos.Z) then
    begin
      FActor.Transform.Translation := Pos;
      MotionTrace.Event(Self, meConstraint);
      if not State.AutoMove then
      begin
        State.WorldPosition.X := Pos.X;
        State.WorldPosition.Z := Pos.Z;
      end;
    end;
  end;
  if (not AgentCliNoGround) and Assigned(FPhysics) then
  begin
    { A bicycle is constrained by two contacts every displayed frame.
      Cached surface reads are cheap; throttling them made curbs and slope
      changes step at 30 Hz even when position/rendering ran faster. }
    if State.WheelContactAtOrigin or
       (FLastGroundClock < 0) or not FPhysics.GroundPlacementValid or
       (FLocalClock - FLastGroundClock >= GroundPlacementPeriod) then
    begin
      if FLastGroundClock < 0 then DtGround := SecondsPassed
      else DtGround := FLocalClock - FLastGroundClock;
      FLastGroundClock := FLocalClock;
      FPhysics.UpdateVisualGroundProbes(DtGround);
    end;
    FPhysics.ApplyVisualGroundPlacement(SecondsPassed);
  end;
  if Assigned(FPhysics) then FPhysics.UpdateVisualDebug;
  TracePosition(mtGround);
end;

{ ======================================================================== }

procedure TPhysicalAgent.UpdateOffline(const SecondsPassed, FixedDelta: Single; const MaxSteps: Integer);
var
  Steps: Integer;
  Log: Boolean;
  TransBefore, TransAfter: TVector3;
  AccBefore: Single;
begin
  if not Assigned(State) then Exit;

  Inc(FFrameCounter);
  Log := DebugLog_Enabled(Self);

  FProfiler.Enabled := Log;
  FProfiler.AgentName := FName;
  FProfiler.BeginFrame;

  FLocalClock := FLocalClock + SecondsPassed;

  if (not AgentCliNoControl) and Assigned(FController) then
    FController.UpdateControl(SecondsPassed, FControlInput);

  if not FControlInput.WantsAutoMove then
  begin
    if State.AutoMove then StopMoving;
    FinishVisualUpdate(SecondsPassed);
    Exit;
  end;

  if not ShouldSimulateLocally then Exit;

  { Запоминаем Transform ДО всех операций }
  if Log and Assigned(FActor.Transform) then
    TransBefore := FActor.Transform.Translation;

  { Отменяем экстраполяцию предыдущего кадра }
  RestorePhysicsPosition;
  TracePosition(mtRestore);
  FProfiler.Mark('restore');

  AccBefore := State.AccumulatedTime;
  State.AccumulatedTime := State.AccumulatedTime + SecondsPassed;
  Steps := 0;

  if not AgentCliNoSteps then
    while (State.AccumulatedTime >= FixedDelta) and (Steps < MaxSteps) do
    begin
      FixedStep(FixedDelta);
      State.AccumulatedTime := State.AccumulatedTime - FixedDelta;
      Inc(Steps);
    end;
  FProfiler.Mark('physics');

  if State.AccumulatedTime > FixedDelta * 2 then begin
    State.AccumulatedTime := 0;
    MotionTrace.Event(Self, meDiscardTime);
  end;
  TracePosition(mtPhysics);

  { Экстраполяция XZ }
  ExtrapolateVisual;
  TracePosition(mtExtrapolate);

  FinishVisualUpdate(SecondsPassed);
  FProfiler.Mark('ground');

  { Запоминаем Transform ПОСЛЕ всех операций }
  if Log and Assigned(FActor.Transform) then
  begin
    TransAfter := FActor.Transform.Translation;
    Logger.Info(Format(
      'FRAME %d | dt=%.5f accBefore=%.5f steps=%d accAfter=%.5f | ' +
      'TrBefore=%s TrAfter=%s delta=(%.5f,%.5f,%.5f) | ' +
      'WorldPos=%s Speed=%.3f Dir=%s | extrap=%s physTr=%s',
      [FFrameCounter,
       SecondsPassed, AccBefore, Steps, State.AccumulatedTime,
       V3S(TransBefore), V3S(TransAfter),
       TransAfter.X - TransBefore.X,
       TransAfter.Y - TransBefore.Y,
       TransAfter.Z - TransBefore.Z,
       V3S(State.WorldPosition),
       State.CurrentSpeed,
       V3S(State.ForwardDir),
       BoolToStr(FVisualExtrapolated, 'Y', 'N'),
       V3S(FPhysicsTranslation)
      ]));
  end;
  FProfiler.Mark('log');
  FProfiler.Flush;
end;

procedure TPhysicalAgent.UpdatePredictedClient(const SecondsPassed, FixedDelta: Single; const MaxSteps: Integer);
begin
  UpdateOffline(SecondsPassed, FixedDelta, MaxSteps);
end;

procedure TPhysicalAgent.UpdateAsAuthoritativeServer(const SecondsPassed, FixedDelta: Single; const MaxSteps: Integer);
var
  Steps: Integer;
begin
  FLocalClock := FLocalClock + SecondsPassed;

  if FHasPendingRemoteInput then
  begin
    FControlInput.MoveForward := FPendingRemoteInput.MoveForward;
    FControlInput.MoveBackward := FPendingRemoteInput.MoveBackward;
    FControlInput.TurnLeft := FPendingRemoteInput.TurnLeft;
    FControlInput.TurnRight := FPendingRemoteInput.TurnRight;
    FControlInput.Brake := FPendingRemoteInput.Brake;
    FControlInput.DesiredPowerWatts := FPendingRemoteInput.DesiredPowerWatts;
    FControlInput.BrakeForceN := 0; { remote protocol does not transmit measured braking }
    FControlInput.WantsAutoMove := FPendingRemoteInput.WantsAutoMove;
    FLastAppliedSequenceId := FPendingRemoteInput.SequenceId;
    FHasPendingRemoteInput := false;
  end
  else
  if Assigned(FController) then
    FController.UpdateControl(SecondsPassed, FControlInput);

  if not FControlInput.WantsAutoMove then
  begin
    if State.AutoMove then StopMoving;
    FinishVisualUpdate(SecondsPassed);
    Exit;
  end;

  if not ShouldSimulateLocally then Exit;

  RestorePhysicsPosition;
  TracePosition(mtRestore);

  State.AccumulatedTime := State.AccumulatedTime + SecondsPassed;
  Steps := 0;

  while (State.AccumulatedTime >= FixedDelta) and (Steps < MaxSteps) do
  begin
    FixedStep(FixedDelta);
    State.AccumulatedTime := State.AccumulatedTime - FixedDelta;
    Inc(Steps);
  end;

  if State.AccumulatedTime > FixedDelta * 2 then begin
    State.AccumulatedTime := 0;
    MotionTrace.Event(Self, meDiscardTime);
  end;
  TracePosition(mtPhysics);

  ExtrapolateVisual;
  TracePosition(mtExtrapolate);

  FinishVisualUpdate(SecondsPassed);
end;

procedure TPhysicalAgent.UpdateAsRemoteProxy(const SecondsPassed: Single);
var
  S1, S2: TAgentNetworkState;
  Alpha: Single;
  TargetServerTime: Double;
begin
  FLocalClock := FLocalClock + SecondsPassed;
  if FSnapshotCount = 0 then Exit;
  { The two agents may have started their clocks at different times.
    Advance from the last received server timestamp using local elapsed time. }
  TargetServerTime := FSnapshotBuffer[FSnapshotCount - 1].State.ServerTime +
    (FLocalClock - FSnapshotBuffer[FSnapshotCount - 1].ReceivedLocalTime) -
    FInterpolationBackTime;

  if TryGetInterpolationStates(TargetServerTime, S1, S2, Alpha) then
    ApplyInterpolatedState(S1, S2, Alpha)
  else
  if FSnapshotCount > 0 then
    ApplyInterpolatedState(FSnapshotBuffer[FSnapshotCount - 1].State,
      FSnapshotBuffer[FSnapshotCount - 1].State, 0);
end;

procedure TPhysicalAgent.ApplyRemoteInputCommand(const ACommand: TAgentInputCommand);
begin
  FPendingRemoteInput := ACommand;
  FHasPendingRemoteInput := true;
end;

procedure TPhysicalAgent.PushSnapshot(const AState: TAgentNetworkState);
begin
  if FSnapshotCount < Length(FSnapshotBuffer) then
  begin
    FSnapshotBuffer[FSnapshotCount].State := AState;
    FSnapshotBuffer[FSnapshotCount].ReceivedLocalTime := FLocalClock;
    Inc(FSnapshotCount);
  end
  else
  begin
    Move(FSnapshotBuffer[1], FSnapshotBuffer[0], SizeOf(TBufferedSnapshot) * (Length(FSnapshotBuffer) - 1));
    FSnapshotBuffer[High(FSnapshotBuffer)].State := AState;
    FSnapshotBuffer[High(FSnapshotBuffer)].ReceivedLocalTime := FLocalClock;
  end;
  TrimOldSnapshots;
end;

procedure TPhysicalAgent.TrimOldSnapshots;
begin
  while FSnapshotCount > 24 do
  begin
    Move(FSnapshotBuffer[1], FSnapshotBuffer[0], SizeOf(TBufferedSnapshot) * (FSnapshotCount - 1));
    Dec(FSnapshotCount);
  end;
end;

function TPhysicalAgent.TryGetInterpolationStates(const TargetServerTime: Double;
  out AState1, AState2: TAgentNetworkState; out Alpha: Single): Boolean;
var I: Integer; T1, T2: Double;
begin
  Result := false; Alpha := 0;
  if FSnapshotCount = 0 then Exit;
  if (FSnapshotCount = 1) or
     (TargetServerTime <= FSnapshotBuffer[0].State.ServerTime) then
  begin
    AState1 := FSnapshotBuffer[0].State; AState2 := AState1; Alpha := 0; Exit(true);
  end;
  for I := 0 to FSnapshotCount - 2 do
  begin
    T1 := FSnapshotBuffer[I].State.ServerTime;
    T2 := FSnapshotBuffer[I + 1].State.ServerTime;
    if (TargetServerTime >= T1) and (TargetServerTime <= T2) then
    begin
      AState1 := FSnapshotBuffer[I].State; AState2 := FSnapshotBuffer[I + 1].State;
      if Abs(T2 - T1) > 0.00001 then Alpha := (TargetServerTime - T1) / (T2 - T1) else Alpha := 0;
      if Alpha < 0 then Alpha := 0; if Alpha > 1 then Alpha := 1;
      Exit(true);
    end;
  end;
  AState1 := FSnapshotBuffer[FSnapshotCount - 1].State; AState2 := AState1; Alpha := 0; Result := true;
end;

procedure TPhysicalAgent.ApplyInterpolatedState(const AState1, AState2: TAgentNetworkState; const Alpha: Single);
var Pos, Dir: TVector3;
begin
  MotionTrace.Event(Self, meNetwork);
  Pos := AState1.Position + (AState2.Position - AState1.Position) * Alpha;
  Dir := AState1.ForwardDir + (AState2.ForwardDir - AState1.ForwardDir) * Alpha;
  if Dir.Length > 0.001 then Dir := Dir.Normalize else Dir := AState2.ForwardDir;
  FState.WorldPosition := Pos; FState.ForwardDir := Dir;
  FState.CurrentSpeed := AState1.Speed + (AState2.Speed - AState1.Speed) * Alpha;
  FState.AppliedPowerWatts := AState2.PowerWatts; FState.AutoMove := AState2.AutoMove;
  if Assigned(FActor.Transform) then
  begin FActor.Transform.Translation := Pos; FActor.Transform.Direction := Dir; end;
end;

procedure TPhysicalAgent.ReconcileWithAuthoritativeState(const AState: TAgentNetworkState);
var Delta, Blend: Single;
begin
  MotionTrace.Event(Self, meNetwork);
  Delta := (FState.WorldPosition - AState.Position).Length;
  if Delta >= FPredictionHardSnapDistance then
  begin
    FState.WorldPosition := AState.Position; FState.ForwardDir := AState.ForwardDir; FState.CurrentSpeed := AState.Speed;
    if Assigned(FActor.Transform) then begin FActor.Transform.Translation := AState.Position; FActor.Transform.Direction := AState.ForwardDir; end;
  end
  else if Delta >= FPredictionSoftSnapDistance then
  begin
    Blend := 0.35;
    FState.WorldPosition := FState.WorldPosition + (AState.Position - FState.WorldPosition) * Blend;
    FState.ForwardDir := FState.ForwardDir + (AState.ForwardDir - FState.ForwardDir) * Blend;
    if FState.ForwardDir.Length > 0.001 then FState.ForwardDir := FState.ForwardDir.Normalize;
    FState.CurrentSpeed := FState.CurrentSpeed + (AState.Speed - FState.CurrentSpeed) * Blend;
    if Assigned(FActor.Transform) then begin FActor.Transform.Translation := FState.WorldPosition; FActor.Transform.Direction := FState.ForwardDir; end;
  end;
  if Delta >= FPredictionSoftSnapDistance then
  begin
    FVisualExtrapolated := False;
    FState.MovementVelocity := Vector3(0, 0, 0);
    FLastGroundClock := -1;
    if Assigned(FPhysics) then FPhysics.InvalidateGroundPlacement;
  end;
end;

procedure TPhysicalAgent.CreateDebugSpheres;
  function CreateSphere(const AColor: TCastleColor; const AName: string): TCastleSphere;
  begin
    Result := TCastleSphere.Create(FOwner); Result.Name := AName; Result.Radius := DebugSphereRadius;
    Result.Color := AColor; Result.Pickable := false; Result.Collides := false; Result.CastShadows := false;
    Result.RenderLayer := TRenderLayer.rlFront;
    Result.Exists := FDebug.DebugSpheresVisible;
    if Assigned(FActor.Viewport) then FActor.Viewport.Items.Add(Result);
  end;
  { Тонкий брус-«линия» длиной 3 м вдоль локального +Z (его потом
    разворачивает рывок по курсу). Параметры рендера — как у сфер:
    поверх геометрии (rlFront), без теней/коллизий. }
  function CreateLine(const AColor: TCastleColor; const AName: string): TCastleBox;
  begin
    Result := TCastleBox.Create(FOwner);
    Result.Name := AName;
    Result.Size := Vector3(DebugLineThickness, DebugLineThickness, DebugLineLength);
    Result.Color := AColor;
    Result.Pickable := false; Result.Collides := false; Result.CastShadows := false;
    Result.RenderLayer := TRenderLayer.rlFront;
    Result.Exists := FDebug.DebugSpheresVisible;
    if Assigned(FActor.Viewport) then FActor.Viewport.Items.Add(Result);
  end;
var
  I: Integer;
begin
  FDebug.DebugSphereFrontWheel := CreateSphere(Red, FName + '_DebugFrontWheel');
  FDebug.DebugSphereRearWheel := CreateSphere(Blue, FName + '_DebugRearWheel');
  FDebug.DebugSphereFrontGround := CreateSphere(Green, FName + '_DebugFrontGround');
  FDebug.DebugSphereRearGround := CreateSphere(Yellow, FName + '_DebugRearGround');
  { Carrot — larger orange sphere showing the path-follow target }
  FDebug.DebugSphereCarrot := CreateSphere(Vector4(1.0, 0.5, 0.0, 1.0), FName + '_DebugCarrot');
  FDebug.DebugSphereCarrot.Radius := 0.15;

  { Линии поперечного сечения дороги — разными цветами:
      осевая  — жёлтая,
      края    — красные,
      разметка полос — белая. }
  FDebug.DebugLineCenter := CreateLine(Yellow, FName + '_DebugRoadCenter');
  FDebug.DebugLineEdgeLeft := CreateLine(Red, FName + '_DebugRoadEdgeL');
  FDebug.DebugLineEdgeRight := CreateLine(Red, FName + '_DebugRoadEdgeR');
  for I := 0 to DEBUG_MAX_LANE_MARKS - 1 do
    FDebug.DebugLineLanes[I] :=
      CreateLine(White, FName + '_DebugLaneMark' + IntToStr(I));
end;

procedure TPhysicalAgent.ToggleDebugSpheres;
var
  I: Integer;
begin
  FDebug.DebugSpheresVisible := not FDebug.DebugSpheresVisible;
  if Assigned(FDebug.DebugSphereFrontWheel) then FDebug.DebugSphereFrontWheel.Exists := FDebug.DebugSpheresVisible;
  if Assigned(FDebug.DebugSphereRearWheel) then FDebug.DebugSphereRearWheel.Exists := FDebug.DebugSpheresVisible;
  if Assigned(FDebug.DebugSphereFrontGround) then FDebug.DebugSphereFrontGround.Exists := FDebug.DebugSpheresVisible;
  if Assigned(FDebug.DebugSphereRearGround) then FDebug.DebugSphereRearGround.Exists := FDebug.DebugSpheresVisible;
  if Assigned(FDebug.DebugSphereCarrot) then FDebug.DebugSphereCarrot.Exists := FDebug.DebugSpheresVisible;
  if Assigned(FDebug.DebugLineCenter) then FDebug.DebugLineCenter.Exists := FDebug.DebugSpheresVisible;
  if Assigned(FDebug.DebugLineEdgeLeft) then FDebug.DebugLineEdgeLeft.Exists := FDebug.DebugSpheresVisible;
  if Assigned(FDebug.DebugLineEdgeRight) then FDebug.DebugLineEdgeRight.Exists := FDebug.DebugSpheresVisible;
  for I := 0 to DEBUG_MAX_LANE_MARKS - 1 do
    if Assigned(FDebug.DebugLineLanes[I]) then
      FDebug.DebugLineLanes[I].Exists := FDebug.DebugSpheresVisible;
end;

function TPhysicalAgent.BuildInputCommand(const ADeltaTime: Single): TAgentInputCommand;
begin
  Inc(FLocalSequenceCounter);
  Result.NetworkId := FNetworkId; Result.SequenceId := FLocalSequenceCounter;
  Result.DeltaTime := ADeltaTime; Result.ClientTime := FLocalClock;
  Result.MoveForward := FControlInput.MoveForward; Result.MoveBackward := FControlInput.MoveBackward;
  Result.TurnLeft := FControlInput.TurnLeft; Result.TurnRight := FControlInput.TurnRight;
  Result.Brake := FControlInput.Brake; Result.DesiredPowerWatts := FControlInput.DesiredPowerWatts;
  Result.WantsAutoMove := FControlInput.WantsAutoMove;
end;

function TPhysicalAgent.BuildNetworkState: TAgentNetworkState;
begin
  Result.NetworkId := FNetworkId; Result.SequenceId := FLastAppliedSequenceId; Result.ServerTime := FLocalClock;
  Result.Position := FState.WorldPosition; Result.ForwardDir := FState.ForwardDir; Result.Speed := FState.CurrentSpeed;
  Result.PowerWatts := FState.AppliedPowerWatts; Result.AutoMove := FState.AutoMove; Result.PhysicsMode := Ord(FPhysicsMode);
end;

procedure TPhysicalAgent.ApplyNetworkState(const AState: TAgentNetworkState);
begin
  MotionTrace.Event(Self, meNetwork);
  FLastAppliedSequenceId := AState.SequenceId;
  case FNetworkAuthority of
    naRemoteProxy: PushSnapshot(AState);
    naClientPredicted: ReconcileWithAuthoritativeState(AState);
  else begin
    FState.WorldPosition := AState.Position; FState.ForwardDir := AState.ForwardDir;
    FState.CurrentSpeed := AState.Speed; FState.AppliedPowerWatts := AState.PowerWatts; FState.AutoMove := AState.AutoMove;
    if Assigned(FActor.Transform) then begin FActor.Transform.Translation := AState.Position; FActor.Transform.Direction := AState.ForwardDir; end;
  end; end;
end;

{ ═══════════════════════════════════════════════════════════════════
  Physics LOD
  ═══════════════════════════════════════════════════════════════════ }

procedure TPhysicalAgent.SetPhysicsLOD(ALOD: TPhysicsLOD);
begin
  if Assigned(FState) then
    FState.PhysicsLOD := ALOD;
end;

function TPhysicalAgent.GetPhysicsLOD: TPhysicsLOD;
begin
  if Assigned(FState) then
    Result := FState.PhysicsLOD
  else
    Result := plFull;
end;

{ ═══════════════════════════════════════════════════════════════════
  SpawnOnPath — factory that replaces the 8-step init boilerplate.
  ═══════════════════════════════════════════════════════════════════ }

class function TPhysicalAgent.SpawnOnPath(
  AOwner: TComponent;
  const AName: string;
  const ATransform: TCastleTransform;
  const AScene: TCastleScene;
  const ARigidBody: TCastleRigidBody;
  const AViewport: TCastleViewport;
  const ANavigation: TCastleThirdPersonNavigation;
  const ALevelScene: TCastleScene;
  const APathFileName: string;
  APhysicsMode: TPhysicsMode;
  AAuthority: TNetworkAuthority;
  ALOD: TPhysicsLOD;
  AController: IAgentController): TPhysicalAgent;
begin
  Result := TPhysicalAgent.Create(AOwner);
  Result.Name := AName;
  Result.SetupActor(ATransform, AScene, ARigidBody,
    AViewport, ANavigation, ALevelScene);
  if Assigned(AController) then
    Result.SetController(AController);
  { Пустое имя файла — путь будет задан вызывающей стороной (например,
    копией из общего пути напрямую из FIT, без INI). }
  if APathFileName <> '' then
    Result.Path.LoadRoadPoints(APathFileName);
  Result.SetPhysicsLOD(ALOD);
  Result.RecreatePhysics(APhysicsMode);
  Result.Initialize;
  Result.InitializeAtStart;
  Result.NetworkAuthority := AAuthority;
end;

end.
