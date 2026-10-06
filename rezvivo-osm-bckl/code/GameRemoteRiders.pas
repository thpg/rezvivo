{ TRemoteRidersManager — manages remote rider visuals and physics.

  REFACTORED: Remote riders are now full TPhysicalAgent instances using
  the same physics pipeline as the local avatar. Their power comes from
  the relay server via TRemotePowerController.

  Physics LOD (switched by distance in UpdateDistanceCulling):
    < 50m  → plFull     (identical to avatar: trajectory, turn forces, lean)
    < 250m → plReduced  (path following + acceleration, no trajectory/lean)
    > 250m → hidden     (Transform.Exists := False)

  Build queue and relay client unchanged. }
unit GameRemoteRiders;

interface

uses Classes, SysUtils, Math, CastleVectors, CastleTransform, CastleViewport, CastleScene, CastleURIUtils, CastleTimeUtils, GamePath, GameRideClient, BikeParametric, GameBikeAvatar, TrainerData, GamePhysicalAgent, GamePhysicsCommon, GameAgentControllers, GameAgentNetwork;

type
  TRemoteRiderVisual = record
    RiderId: Integer;
    Transform: TCastleTransform;
    BikeInst: TBikeInstance;

    { TPhysicalAgent — full physics, same pipeline as avatar }
    Agent: TPhysicalAgent;
    Controller: TRemotePowerController;

    { Server-provided data (informational) }
    ServerDistance: Single;
    ServerSpeed: Single;

    LastUpdateTime: Double;
    LastPacketTimestamp:Int64;
    Active: Boolean;
    ConfigLoaded: Boolean;
    Initialized: Boolean;
  end;

  TPendingBuild = record
    VisualIdx: Integer;
    JsonText: string;
  end;

  TRelayProfilingData = record
    RelayNet: Double;
    RelayBuild: Double;
    RelayConfig: Double;
    RelayPos: Double;
    RelayTotal: Double;
    VisibleRiders: Integer;
    RemoteVisualCount: Integer;
    PendingBuildCount: Integer;
  end;

  TProfileLogEvent = procedure(const S: string) of object;

  TRemoteRidersManager = class
  private
    FOwnerForComponents: TComponent;
    FViewport: TCastleViewport;
    { Общее мировое солнце для контактных теней райдеров (см.
      TBikeInstance.ShadowSunWorldDir). Применяется к каждому построенному
      BikeInst; выставляется из ViewPlay после старта стриминговой карты. }
    FShadowSunWorld: TVector3;
    FShadowSunWorldSet: Boolean;
    FShadowMode: TBikeShadowMode;
    FShadowModeSet: Boolean;
    FShadowsVisible: Boolean;
    FAnimationEnabled: Boolean;
    FLevelScene: TCastleScene;
    FAvatarTransform: TCastleTransform;

    FRemoteVisuals: array of TRemoteRiderVisual;
    FRemoteVisualCount: Integer;
    FPendingBuilds: array of TPendingBuild;
    FPendingBuildCount: Integer;
    FPathCumDist: array of Single;
    FPathTotalLength: Single;
    FLocalTime: Double;
    FLocalDistance: Single;

    FVisibleRiders: Integer;
    FRidersVisible: Boolean;   { perf-тумблер: Group.Exists всех BikeInst (вся модель) }

    FRideClient: TRideRelayClient;
    FFallbackBikeJson: string;
    FPathRef: TGamePath;

    FGuestSyncTimer: Single;

    { Lane management — shared manager for all riders }
    FLaneManager: TLaneManager;  { owned externally, set via SetLaneManager }
    FLocalLaneHandle: TLaneRiderHandle;  { handle for local rider in LaneManager }
    FRemoteLaneHandles: array of TLaneRiderHandle;

    FProf_RelayNet: Double;
    FProf_RelayBuild: Double;
    FProf_RelayConfig: Double;
    FProf_RelayPos: Double;

    FOnProfileLog: TProfileLogEvent;

    function FindOrCreateRemoteVisual(ARiderId: Integer): Integer;
    procedure EnqueueBuild(AVisualIdx: Integer; const AJson: string);
    procedure ProcessBuildQueue;
    procedure ProfileLog(const S: string);

    procedure PushGuestStates;
  public
    constructor Create(AOwner: TComponent);
    destructor Destroy; override;

    procedure Setup(
      AViewport: TCastleViewport;
      ALevelScene: TCastleScene;
      AAvatarTransform: TCastleTransform;
      APathRef: TGamePath
    );

    procedure InitPathCumDist;
    procedure RefreshPreparedPath;

    { Задать общее мировое солнце контактных теней: применяется ко всем
      уже построенным удалённым райдерам и к каждому, кто построится позже. }
    procedure SetShadowSunWorld(const ADir: TVector3);

    { Единый режим тени для всех удалённых райдеров (см. TBikeShadowMode):
      капсулы / движковые тени / без тени. Применяется к построенным и
      будущим байкам. Для массовки капсулы обычно предпочтительнее —
      bsmCGE у каждого райдера создаёт СВОЙ теневой источник света. }
    procedure SetShadowMode(AMode: TBikeShadowMode);
    procedure AppendShadowCasters(const List: TCastleTransformList);
    { Показать/скрыть Tripo-райдеров (людей, не байки) всех удалённых
      байков — perf-замеры по MCP. Применяется к построенным и будущим. }
    procedure SetRidersVisible(AVisible: Boolean);
    procedure SetShadowsVisible(AVisible: Boolean);
    procedure SetAnimationEnabled(AEnabled: Boolean);

    procedure StartRelay(const AServerUrl: string;
      const ABikeJsonFileName, AFallbackBikeJsonFileName: string;
      APrivateRoom:Boolean=False;AAccountId:Integer=0;const AName:string='Player');
    procedure StopRelay;

    procedure UpdateRelayClient(const SecondsPassed: Single;
      AActiveAgent: TPhysicalAgent;
      ABLEDataValid: Boolean;
      const ABLEData: TTrainerDataRecord; AHoldPhysics: Boolean = False);
    procedure UpdateDistanceCulling;

    function GetProfilingData: TRelayProfilingData;
    function CountRemoteShapes: Integer;
    procedure GetRemoteRiderShapeInfo(out Lines: string);

    property RideClient: TRideRelayClient read FRideClient;
    property LocalDistance: Single read FLocalDistance write FLocalDistance;
    property LocalTime: Double read FLocalTime;
    property RemoteVisualCount: Integer read FRemoteVisualCount;
    property VisibleRiders: Integer read FVisibleRiders;
    property PathTotalLength: Single read FPathTotalLength;

    { Update animation speed of all remote riders based on cadence from server }
    procedure UpdateRemoteAnimationSpeeds;
    { Per-frame tick — dispatches AnimateFrame to every remote TBikeInstance so
      their rider bones update. Pass SecondsPassed from the view Update. }
    procedure AnimateAllRiders(SecondsPassed: Single);
    procedure GetNearbyRiderPositions(const ACenter: TVector3; ARange: Single;
      var APositions: array of TVector3; out ACount: Integer);
    property OnProfileLog: TProfileLogEvent read FOnProfileLog write FOnProfileLog;

    { Lane management }
    procedure SetLaneManager(ALaneManager: TLaneManager;
      ALocalHandle: TLaneRiderHandle);
    function LaneOffset(ALane: Integer): Single;
    property LaneManager: TLaneManager read FLaneManager;
  end;

implementation


uses
  BikeJSON, fpjson, GameMath, DebugLog, GameRiderTraffic, GameRemoteBikeConfig;

const
  GuestSyncInterval = 5.0;
  FixedTimeStep = 1.0 / 60.0;

  { Distance thresholds for physics LOD }
  LODFullDistSq    = 50.0 * 50.0;    { < 50m  → plFull (identical to avatar) }
  LODReducedDistSq = 250.0 * 250.0;  { < 250m → plReduced (no trajectory/lean) }
  ShadowLODOnDistSq  = 45.0 * 45.0;  { гистерезис shadow LOD: включить тень < 45 м }
  ShadowLODOffDistSq = 55.0 * 55.0;  { гистерезис shadow LOD: выключить > 55 м }
  { > 250m → hidden }

constructor TRemoteRidersManager.Create(AOwner: TComponent);
begin
  FShadowSunWorld := Vector3(0, -1, 0);
  FShadowSunWorldSet := False;
  FShadowMode := bsmCGE;
  //FShadowMode := bsmCapsules;
  FShadowModeSet := False;
  FShadowsVisible := True;
  FAnimationEnabled := True;
  FRidersVisible := True;
  inherited Create;
  FOwnerForComponents := AOwner;
  FRemoteVisualCount := 0;
  FPendingBuildCount := 0;
  FLocalTime := 0;
  FLocalDistance := 0;
  FVisibleRiders := 0;
  FPathTotalLength := 0;
  FGuestSyncTimer := 0;
  FLocalLaneHandle := -1;
end;

destructor TRemoteRidersManager.Destroy;
var
  I: Integer;
begin
  for I := 0 to FRemoteVisualCount - 1 do
  begin
    { BikeInst — plain-class, владельца не имеет: явный Free балансирует
      KeepExistingBegin rig-узлов (как FBikeInstance/FBotBikes в TViewPlay.Stop).
      До Free агента: его Group отцепляется от живой сцены агента; сама
      сцена (owner FreeAtStop) умрёт позже с view. Контроллер не трогаем —
      он IAgentController (интерфейс, счётчик ссылок). }
    if Assigned(FRemoteVisuals[I].BikeInst) then
      FreeAndNil(FRemoteVisuals[I].BikeInst);
    FreeAndNil(FRemoteVisuals[I].Agent);
  end;
  FreeAndNil(FRideClient);
  inherited;
end;

procedure TRemoteRidersManager.ProfileLog(const S: string);
begin
  if Assigned(FOnProfileLog) then FOnProfileLog(S);
end;

procedure TRemoteRidersManager.Setup(
  AViewport: TCastleViewport; ALevelScene: TCastleScene;
  AAvatarTransform: TCastleTransform;
  APathRef: TGamePath);
begin
  FViewport := AViewport;
  FLevelScene := ALevelScene;
  FAvatarTransform := AAvatarTransform;
  FPathRef := APathRef;
end;

{ ── Path ── }

procedure TRemoteRidersManager.InitPathCumDist;
var
  I, Count: Integer;
  Pts: array of TVector3;
begin
  FPathTotalLength := 0;
  { Кумулятивные дистанции считаем по уже загруженному пути аватара
    (FPathRef) — он наполняется напрямую из FIT (без INI) ещё до вызова
    InitPathCumDist. Это убирает повторное чтение файла и держит длину
    трассы в точности согласованной с путём, по которому едет райдер. }
  if not Assigned(FPathRef) then
  begin
    Logger.Info('[Relay] ' + 'InitPathCumDist: FPathRef не назначен');
    Exit;
  end;
  Count := FPathRef.PointCount;
  if Count < 2 then Exit;
  SetLength(Pts, Count);
  for I := 0 to Count - 1 do Pts[I] := FPathRef.GetPathPointWorld(I);
  SetLength(FPathCumDist, Count);
  FPathCumDist[0] := 0;
  for I := 1 to Count - 1 do
    FPathCumDist[I] := FPathCumDist[I - 1] + (Pts[I] - Pts[I - 1]).Length;
  FPathTotalLength := FPathCumDist[Count - 1] + (Pts[0] - Pts[Count - 1]).Length;
  if Assigned(FLaneManager) then FLaneManager.SetPathLength(FPathTotalLength);
  Logger.Info('[Relay] ' + Format('Path ready: %d pts, %.0f m', [Count, FPathTotalLength]));
end;

{ ── Visuals ── }

procedure TRemoteRidersManager.RefreshPreparedPath;
var I: Integer; Ag: TPhysicalAgent; Pos: TPathPosition;
begin
  InitPathCumDist;
  if (FPathRef = nil) or (FPathRef.PointCount < 2) then Exit;
  for I := 0 to FRemoteVisualCount - 1 do
  begin
    Ag := FRemoteVisuals[I].Agent;
    if Ag = nil then Continue;
    FPathRef.CopyTo(Ag.Path);
    Pos.Segment := 0; Pos.T := 0;
    Ag.Path.AdvanceFollow(Pos, WrapDistance(Ag.State.CumulativeDistance, FPathTotalLength));
    Ag.TeleportToPath(Pos);
  end;
end;

function TRemoteRidersManager.FindOrCreateRemoteVisual(ARiderId: Integer): Integer;
var
  I: Integer;
  Ctrl: TRemotePowerController;
  Ag: TPhysicalAgent;
  Tr: TCastleTransform;
  Sc: TCastleScene;
begin
  for I := 0 to FRemoteVisualCount - 1 do
    if FRemoteVisuals[I].RiderId = ARiderId then Exit(I);

  if FRemoteVisualCount >= Length(FRemoteVisuals) then
    SetLength(FRemoteVisuals, FRemoteVisualCount + 8);
  Result := FRemoteVisualCount;
  Inc(FRemoteVisualCount);

  FillChar(FRemoteVisuals[Result], SizeOf(TRemoteRiderVisual), 0);
  FRemoteVisuals[Result].RiderId := ARiderId;
  FRemoteVisuals[Result].LastUpdateTime := FLocalTime;
  FRemoteVisuals[Result].Active := True;

  { Create Transform + empty Scene for the agent }
  Tr := TCastleTransform.Create(FOwnerForComponents);
  Tr.Name := 'RemoteRider_' + IntToStr(ARiderId);
  Tr.Pickable := False;
  Tr.Collides := False;
  FViewport.Items.Add(Tr);

  Sc := TCastleScene.Create(FOwnerForComponents);
  Sc.Name := 'RemoteRiderScene_' + IntToStr(ARiderId);
  Sc.Pickable := False;
  Sc.Collides := False;
  Tr.Add(Sc);

  FRemoteVisuals[Result].Transform := Tr;

  { Create controller }
  Ctrl := TRemotePowerController.Create;
  FRemoteVisuals[Result].Controller := Ctrl;

  { Create full TPhysicalAgent via factory — same physics as avatar }
  Ag := TPhysicalAgent.SpawnOnPath(
    FOwnerForComponents,
    'RemoteAgent_' + IntToStr(ARiderId),
    Tr, Sc, nil,
    FViewport, nil,
    FLevelScene,
    '',                   { путь зададим копией из FPathRef (без INI) }
    pmKinematicCurrent,
    naLocalOnly,
    plFull,               { start at full LOD — adjusted by distance culling }
    Ctrl
  );
  FRemoteVisuals[Result].Agent := Ag;
  if Assigned(Ag) then Ag.State.WheelContactAtOrigin := True;   { байк на колёсах в Y=0 кадра }

  { Путь райдера — из уже загруженного пути аватара (FPathRef), напрямую
    из памяти. В стриминговом режиме road-INI больше нет, а SpawnOnPath
    прочитал бы пустой файл; копируем точки из общего пути. В
    нестриминговом режиме результат идентичен (тот же дорожный файл). }
  if Assigned(FPathRef) and (FPathRef.PointCount >= 2) and Assigned(Ag) then
    FPathRef.CopyTo(Ag.Path);

  { Register with shared lane manager }
  if Result >= Length(FRemoteLaneHandles) then
    SetLength(FRemoteLaneHandles, Result + 8);
  if Assigned(FLaneManager) then
    FRemoteLaneHandles[Result] := RegisterTrafficAgent(FLaneManager,Ag)
  else
    FRemoteLaneHandles[Result] := -1;

  { Queue bike model build }
  if FFallbackBikeJson <> '' then
    EnqueueBuild(Result, FFallbackBikeJson)
  else
    Logger.Info('[Relay] ' + 'No fallback JSON — rider has no model');

  if Assigned(FRideClient) then
    FRideClient.RequestBikeConfig(ARiderId);

  Logger.Info('[Relay] ' + 'Created visual for rider ' + IntToStr(ARiderId));
  ProfileLog('NEW RIDER ' + IntToStr(ARiderId));
end;

procedure TRemoteRidersManager.EnqueueBuild(AVisualIdx: Integer; const AJson: string);
begin
  if FPendingBuildCount >= Length(FPendingBuilds) then
    SetLength(FPendingBuilds, FPendingBuildCount + 8);
  FPendingBuilds[FPendingBuildCount].VisualIdx := AVisualIdx;
  FPendingBuilds[FPendingBuildCount].JsonText := AJson;
  Inc(FPendingBuildCount);
end;

procedure TRemoteRidersManager.ProcessBuildQueue;
var Idx, I: Integer; Inst: TBikeInstance; Ms: QWord; Json,SafeJson,ConfigError: string;
begin
  if FPendingBuildCount = 0 then Exit;
  Idx := FPendingBuilds[0].VisualIdx;
  Json := FPendingBuilds[0].JsonText;
  for I := 1 to FPendingBuildCount - 1 do
    FPendingBuilds[I - 1] := FPendingBuilds[I];
  Dec(FPendingBuildCount);
  FPendingBuilds[FPendingBuildCount].JsonText := '';

  if (Idx < 0) or (Idx >= FRemoteVisualCount) or not FRemoteVisuals[Idx].Active then Exit;
  if not SanitizeRemoteBikeConfig(Json,SafeJson,ConfigError) then
  begin
    Logger.Info('[Relay] Rejected invalid bike config for rider '+IntToStr(FRemoteVisuals[Idx].RiderId));
    Exit; { Keep an already visible fallback instead of removing it first. }
  end;
  Ms := GetTickCount64;
  try
    if Assigned(FRemoteVisuals[Idx].BikeInst) then
    begin
      { Remove from Scene (where we add it below) }
      if Assigned(FRemoteVisuals[Idx].Agent) and
         Assigned(FRemoteVisuals[Idx].Agent.Actor.Scene) then
        FRemoteVisuals[Idx].Agent.Actor.Scene.Remove(
          FRemoteVisuals[Idx].BikeInst.Group);
      FreeAndNil(FRemoteVisuals[Idx].BikeInst);
    end;
    Inst := LoadBikeInstanceFromJSONString(SafeJson, FOwnerForComponents);

    { Add to Scene (FActor.Scene), NOT to Transform directly.
      This way ApplyModelRotation (which sets Scene.Rotation)
      correctly rotates the bike model — same hierarchy as avatar.
      No manual -Pi/2 rotation needed: ApplyModelRotation handles
      ModelBaseYRotation automatically. }
    if Assigned(FRemoteVisuals[Idx].Agent) and
       Assigned(FRemoteVisuals[Idx].Agent.Actor.Scene) then
      FRemoteVisuals[Idx].Agent.Actor.Scene.Add(Inst.Group)
    else
      FRemoteVisuals[Idx].Transform.Add(Inst.Group);

    if FShadowSunWorldSet then
      Inst.ShadowSunWorldDir := FShadowSunWorld;   { общее солнце для тени }
    if FShadowModeSet then
      Inst.ShadowMode := FShadowMode;              { единый режим тени }
    Inst.Group.Exists := FRidersVisible;             { perf-тумблер райдеров (вся модель) }
    Inst.AnimationEnabled := FAnimationEnabled;
    if Inst.ShowShadow <> FShadowsVisible then
      Inst.ShowShadow := FShadowsVisible;

    FRemoteVisuals[Idx].BikeInst := Inst;
    { Колёсные пробы физики удалённого райдера — по реальным осям его байка
      (bbox сцены раздут теневым catcher'ом/rig'ом — пробы были в метрах
      от колёс). }
    if Assigned(FRemoteVisuals[Idx].Agent) and
       Assigned(FRemoteVisuals[Idx].Agent.Physics) then
      FRemoteVisuals[Idx].Agent.Physics.SetWheelProbeHalfSpan(Inst.AxleHalfSpanM);
    Ms := GetTickCount64 - Ms;
    Logger.Info('[Relay] ' + Format('Built rider %d (%d ms)', [FRemoteVisuals[Idx].RiderId, Ms]));
  except
    on E: Exception do
      Logger.Info('[Relay] ' + 'Build failed R' + IntToStr(FRemoteVisuals[Idx].RiderId) + ': ' + E.Message);
  end;
end;

{ ── Lane management ── }

{ WrapDist moved to GameMath as WrapDistance(D, TotalLength).
  Call sites below pass FPathTotalLength explicitly — this also removes
  the implicit dependency on instance state (better testability). }

function TRemoteRidersManager.LaneOffset(ALane: Integer): Single;
begin
  if Assigned(FLaneManager) then
    Result := FLaneManager.GetLaneOffset(ALane)
  else
    Result := 0;
end;

procedure TRemoteRidersManager.SetLaneManager(ALaneManager: TLaneManager;
  ALocalHandle: TLaneRiderHandle);
begin
  FLaneManager := ALaneManager;
  FLocalLaneHandle := ALocalHandle;
end;

{ ── Distance culling + Physics LOD ── }

procedure TRemoteRidersManager.UpdateDistanceCulling;
var
  Pos: TVector3;
  I: Integer;
  DX, DZ, DSq: Single;
  Vis, ShadowNear: Boolean;
  NewLOD: TPhysicsLOD;
begin
  if not Assigned(FAvatarTransform) then Exit;
  Pos := FAvatarTransform.Translation;
  FVisibleRiders := 0;
  for I := 0 to FRemoteVisualCount - 1 do
  begin
    if not FRemoteVisuals[I].Active or not Assigned(FRemoteVisuals[I].Transform) then Continue;
    DX := FRemoteVisuals[I].Transform.Translation.X - Pos.X;
    DZ := FRemoteVisuals[I].Transform.Translation.Z - Pos.Z;
    DSq := DX*DX + DZ*DZ;

    Vis := DSq < LODReducedDistSq;
    FRemoteVisuals[I].Transform.Exists := Vis;
    if Vis then Inc(FVisibleRiders);

    { Set physics LOD based on distance:
      < 50m  → plFull    (identical physics to avatar)
      < 250m → plReduced (no trajectory/lean/turn drag)
      > 250m → hidden    (Transform.Exists = False) }
    if Assigned(FRemoteVisuals[I].Agent) then
    begin
      if DSq < LODFullDistSq then
        NewLOD := plFull
      else
        NewLOD := plReduced;
      FRemoteVisuals[I].Agent.PhysicsLOD := NewLOD;
    end;

    { Shadow LOD: тень (bsmCGE — свой теневой проход на КАЖДОГО райдера)
      только ближе 50 м. Гистерезис 45/55 м по ТЕКУЩЕМУ режиму: без него
      райдер, болтающийся на границе, каждый кадр переключал бы режим, а
      ApplyShadowMode форсит переразметку shadow receivers всей сцены
      (дорого, микрофризы/моргание). Setter идемпотентен — дёшево звать
      каждый кадр. }
    ShadowNear := DSq < LODFullDistSq;
    if Assigned(FRemoteVisuals[I].BikeInst) then
    begin
      if FRemoteVisuals[I].BikeInst.ShadowMode = bsmNone then
        ShadowNear := DSq < ShadowLODOnDistSq
      else
        ShadowNear := DSq < ShadowLODOffDistSq;
      if ShadowNear then
        FRemoteVisuals[I].BikeInst.ShadowMode := FShadowMode
      else
        FRemoteVisuals[I].BikeInst.ShadowMode := bsmNone;
    end;
    if Assigned(FRemoteVisuals[I].Agent) and
       Assigned(FRemoteVisuals[I].Agent.State) then
      FRemoteVisuals[I].Agent.State.ShadowPlaneWanted :=
        ShadowNear and FRidersVisible and FShadowsVisible and (FShadowMode <> bsmNone);
  end;
end;

{ ── Guest sync ── }

procedure TRemoteRidersManager.PushGuestStates;
var
  I: Integer;
  Arr: TJSONArray;
  Obj: TJSONObject;
  Ag: TPhysicalAgent;
begin
  if not Assigned(FRideClient) or not FRideClient.Started or FRideClient.PrivateRoom then Exit;

  Arr := TJSONArray.Create;
  try
    for I := 0 to FRemoteVisualCount - 1 do
    begin
      if not FRemoteVisuals[I].Active then Continue;
      if not FRemoteVisuals[I].Initialized then Continue;
      Ag := FRemoteVisuals[I].Agent;
      if not Assigned(Ag) then Continue;

      Obj := TJSONObject.Create;
      Obj.Add('rider_id', FRemoteVisuals[I].RiderId);
      Obj.Add('distance', TJSONFloatNumber.Create(Ag.State.CumulativeDistance));
      Obj.Add('speed', TJSONFloatNumber.Create(Ag.State.CurrentSpeed));
      Arr.Add(Obj);
    end;

    if Arr.Count > 0 then
    begin
      FRideClient.PushGuestStates(Arr.AsJSON);
      Logger.Info('[Relay] ' + Format('Guest sync: %d riders pushed', [Arr.Count]));
    end;
  finally
    Arr.Free;
  end;
end;

{ ── Main update ── }

procedure TRemoteRidersManager.UpdateRelayClient(const SecondsPassed: Single;
  AActiveAgent: TPhysicalAgent; ABLEDataValid: Boolean;
  const ABLEData: TTrainerDataRecord; AHoldPhysics: Boolean);
var
  Riders: TRiderBroadcastArray;
  I, Idx, J: Integer;
  Power, Cadence, HR: Integer;
  ActiveIds: array of Integer;
  Found, NewDataArrived: Boolean;
  ConfigJson: string;
  TRNet, TRBuild, TRConfig, TRPos, TREnd: TTimerResult;
  Ag: TPhysicalAgent;
  StartPos:TPathPosition;
  Age,ExpectedDistance,TargetSpeed:Single;
begin
  if not Assigned(AActiveAgent) or not Assigned(AActiveAgent.State) then Exit;

  FLocalTime := FLocalTime + SecondsPassed;
  if AActiveAgent.State.AutoMove then
    FLocalDistance := FLocalDistance + AActiveAgent.State.CurrentSpeed * SecondsPassed;

  if not Assigned(FRideClient) or not FRideClient.Started then Exit;
  if FRideClient.PrivateRoom then FLocalDistance:=AActiveAgent.State.CumulativeDistance;

  Power := Round(AActiveAgent.State.AppliedPowerWatts);
  Cadence := 0; HR := 0;
  if ABLEDataValid then begin Cadence := ABLEData.InstantCadence; HR := ABLEData.HeartRate; end;

  FRideClient.PushLocalState(FLocalDistance, AActiveAgent.State.CurrentSpeed,
    Power, Cadence, HR);

  { ── NETWORK ── }
  TRNet := Timer;
  FRideClient.UpdateRemoteRiders;
  NewDataArrived := FRideClient.HasNewData;
  Riders := FRideClient.GetAllRemoteRiders;

  if NewDataArrived then
  begin
    SetLength(ActiveIds, Length(Riders));
    for I := 0 to High(Riders) do
    begin
      ActiveIds[I] := Riders[I].RiderId;
      Idx := FindOrCreateRemoteVisual(Riders[I].RiderId);
      { Polling the same stored packet is not proof that the peer is online. }
      if FRideClient.PrivateRoom and(Riders[I].UpdatedAt>0)and
        (FRemoteVisuals[Idx].LastPacketTimestamp=Riders[I].UpdatedAt)then Continue;
      FRemoteVisuals[Idx].LastPacketTimestamp:=Riders[I].UpdatedAt;

      { Server data — informational }
      FRemoteVisuals[Idx].ServerDistance := Riders[I].Distance;
      FRemoteVisuals[Idx].ServerSpeed := Riders[I].Speed;
      if not FRemoteVisuals[Idx].Active or(FLocalTime-FRemoteVisuals[Idx].LastUpdateTime>5)then
        FRemoteVisuals[Idx].Initialized:=False;
      if FRideClient.PrivateRoom and(FRemoteVisuals[Idx].Agent<>nil)and
        (Abs(Riders[I].Distance-FRemoteVisuals[Idx].Agent.State.CumulativeDistance)>6)then
        FRemoteVisuals[Idx].Initialized:=False;
      FRemoteVisuals[Idx].LastUpdateTime := FLocalTime;
      FRemoteVisuals[Idx].Active := True;

      { Re-activate in lane manager (might have been deactivated) }
      if Assigned(FLaneManager) and (Idx < Length(FRemoteLaneHandles))
         and (FRemoteLaneHandles[Idx] >= 0) then
        FLaneManager.SetRiderActive(FRemoteLaneHandles[Idx], True);

      { Feed power to controller → agent gets it via UpdateControl }
      if Assigned(FRemoteVisuals[Idx].Controller) then
      begin
        if FRideClient.PrivateRoom then
          FRemoteVisuals[Idx].Controller.FeedServerData(Riders[I].Power,Riders[I].Cadence,Riders[I].Speed)
        else FRemoteVisuals[Idx].Controller.FeedServerData(Riders[I].Power, Riders[I].Cadence);
        FRemoteVisuals[Idx].Controller.SetActive(True);
      end;

      { Initial placement — position agent on path at server distance }
      if not FRemoteVisuals[Idx].Initialized then
      begin
        Ag := FRemoteVisuals[Idx].Agent;
        if Assigned(Ag) and (Ag.Path.PointCount >= 2) then
        begin
          { Advance agent's path position to match server distance.

            CRITICAL: the relay server sends an ABSOLUTE / cumulative
            distance (e.g. 15 497 107 m ≈ 15 500 km — the rider's total
            ride distance), while the streamed FIT route the avatar
            follows is only a short segment (~14 km). AdvanceOnPath
            steps 1 metre per iteration, so passing the raw distance
            spun ~15 million iterations on the MAIN THREAD — tens of
            seconds of UI freeze per remote rider.

            The path is cyclic (TGamePath.ClampPathPosition wraps the
            segment index modulo PointCount), so advancing by D and by
            (D mod TotalLength) lands on the SAME point. Wrap first —
            turns 15 million iterations into at most TotalLength/MaxStep
            (~14 000). }
          StartPos.Segment:=0;StartPos.T:=0;
          if FPathTotalLength>0 then Ag.Path.AdvanceFollow(StartPos,WrapDistance(Riders[I].Distance,FPathTotalLength));
          Ag.TeleportToPath(StartPos);
          Ag.State.WorldPosition := Ag.Path.GetSplinePosition(Ag.Path.Position);
          Ag.State.ForwardDir := Ag.Path.GetSplineDirectionXZ(Ag.Path.Position);
          Ag.State.CurrentSpeed := Riders[I].Speed;
          if Assigned(Ag.Actor.Transform) then
          begin
            Ag.Actor.Transform.Translation := Ag.State.WorldPosition;
            Ag.Actor.Transform.Direction := Ag.State.ForwardDir;
          end;
          Ag.State.CumulativeDistance := Riders[I].Distance;
          PlaceTrafficAgent(FLaneManager,Ag);
          if Riders[I].Speed>0.05 then Ag.StartMoving else Ag.StopMoving;
        end;
        FRemoteVisuals[Idx].Initialized := True;
        Logger.Info('[Relay] ' + Format('Rider %d init at %.0f m, %d W',
          [Riders[I].RiderId, Riders[I].Distance, Riders[I].Power]));
      end;
    end;

    { Mark riders no longer in server list as inactive }
    for I := 0 to FRemoteVisualCount - 1 do
    begin
      Found := False;
      for J := 0 to High(ActiveIds) do
        if ActiveIds[J] = FRemoteVisuals[I].RiderId then begin Found := True; Break; end;
      if not Found then
      begin
        FRemoteVisuals[I].Active := False;
        if Assigned(FRemoteVisuals[I].Controller) then
          FRemoteVisuals[I].Controller.SetActive(False);
        { Remove from lane manager — don't block lanes for others }
        if Assigned(FLaneManager) and (I < Length(FRemoteLaneHandles))
           and (FRemoteLaneHandles[I] >= 0) then
          FLaneManager.SetRiderActive(FRemoteLaneHandles[I], False);
      end;
    end;
  end;

  { ── BUILD ── }
  TRBuild := Timer;
  ProcessBuildQueue;

  { ── CONFIG ── }
  TRConfig := Timer;
  if Assigned(FRideClient) then
    for I := 0 to FRemoteVisualCount - 1 do
    begin
      if not FRemoteVisuals[I].Active or FRemoteVisuals[I].ConfigLoaded then Continue;
      if FRideClient.TryGetBikeConfig(FRemoteVisuals[I].RiderId, ConfigJson) then
      begin
        if ConfigJson <> '' then
        begin
          EnqueueBuild(I, ConfigJson);
          ProfileLog('CONFIG QUEUED R' + IntToStr(FRemoteVisuals[I].RiderId));
        end;
        FRemoteVisuals[I].ConfigLoaded := True;
      end;
    end;

  { ── PHYSICS — same pipeline as avatar ── }
  TRPos := Timer;
  for I := 0 to FRemoteVisualCount - 1 do
  begin
    Age:=Max(0,FLocalTime-FRemoteVisuals[I].LastUpdateTime);
    if FRideClient.PrivateRoom and(Age>5)then begin
      FRemoteVisuals[I].Active:=False;
      if FRemoteVisuals[I].Controller<>nil then FRemoteVisuals[I].Controller.SetActive(False);
      if(FLaneManager<>nil)and(I<Length(FRemoteLaneHandles))then FLaneManager.SetRiderActive(FRemoteLaneHandles[I],False);
    end;
    if not FRemoteVisuals[I].Active then
    begin
      if Assigned(FRemoteVisuals[I].Transform) then
        FRemoteVisuals[I].Transform.Exists := False;
      Continue;
    end;
    if not FRemoteVisuals[I].Initialized then Continue;

    Ag := FRemoteVisuals[I].Agent;
    if not Assigned(Ag) then Continue;
    if Assigned(Ag.Actor)then
      Ag.Actor.RiderOwnsLean:=FAnimationEnabled and
        Assigned(FRemoteVisuals[I].BikeInst)and FRemoteVisuals[I].BikeInst.BodyDynamicsEnabled
        and FRemoteVisuals[I].BikeInst.HasTripoRider;
    if FRideClient.PrivateRoom and not AHoldPhysics then begin
      { The owner supplies progress. Correct small mass/slope differences with
        speed, not repeated teleports; retain the usual traffic constraints. }
      ExpectedDistance:=FRemoteVisuals[I].ServerDistance+FRemoteVisuals[I].ServerSpeed*Min(1.0,Age);
      TargetSpeed:=Max(0,FRemoteVisuals[I].ServerSpeed+
        EnsureRange((ExpectedDistance-Ag.State.CumulativeDistance)*0.5,-1.5,1.5));
      Ag.State.CurrentSpeed:=Ag.State.CurrentSpeed+
        (TargetSpeed-Ag.State.CurrentSpeed)*(1-Exp(-3*Max(0,SecondsPassed)));
    end;

    { Run the SAME physics as avatar: UpdateOffline does fixed-step accumulation.
      CumulativeDistance is tracked inside FixedStep — no manual accumulation needed. }
    if not AHoldPhysics then Ag.UpdateOffline(SecondsPassed, FixedTimeStep);


    { Ground placement — same as avatar's render-frame placement }
    if Assigned(Ag.Physics) then
      Ag.Physics.UpdateVisualGroundPlacement(SecondsPassed);
  end;


  { ── GUEST SYNC ── }
  FGuestSyncTimer := FGuestSyncTimer + SecondsPassed;
  if FGuestSyncTimer >= GuestSyncInterval then
  begin
    FGuestSyncTimer := FGuestSyncTimer - GuestSyncInterval;
    PushGuestStates;
  end;

  TREnd := Timer;
  FProf_RelayNet    := TimerSeconds(TRBuild, TRNet) * 1000;
  FProf_RelayBuild  := TimerSeconds(TRConfig, TRBuild) * 1000;
  FProf_RelayConfig := TimerSeconds(TRPos, TRConfig) * 1000;
  FProf_RelayPos    := TimerSeconds(TREnd, TRPos) * 1000;
end;

{ ── Start / Stop ── }

procedure TRemoteRidersManager.SetShadowSunWorld(const ADir: TVector3);
var
  I: Integer;
begin
  if ADir.Length < 1e-6 then Exit;
  FShadowSunWorld := ADir.Normalize;
  FShadowSunWorldSet := True;
  for I := 0 to FRemoteVisualCount - 1 do
    if FRemoteVisuals[I].Active and Assigned(FRemoteVisuals[I].BikeInst) then
      FRemoteVisuals[I].BikeInst.ShadowSunWorldDir := FShadowSunWorld;
end;

procedure TRemoteRidersManager.AppendShadowCasters(const List: TCastleTransformList);
var I: Integer;
begin
  if not FRidersVisible or not FShadowsVisible then Exit;
  for I := 0 to FRemoteVisualCount - 1 do
    if FRemoteVisuals[I].Active and FRemoteVisuals[I].Initialized and
       Assigned(FRemoteVisuals[I].BikeInst) and
       FRemoteVisuals[I].BikeInst.Group.ExistsInRoot then
      List.Add(FRemoteVisuals[I].BikeInst.Group);
end;

procedure TRemoteRidersManager.SetShadowMode(AMode: TBikeShadowMode);
var
  I: Integer;
begin
  FShadowMode := AMode;
  FShadowModeSet := True;
  for I := 0 to FRemoteVisualCount - 1 do
    if FRemoteVisuals[I].Active and Assigned(FRemoteVisuals[I].BikeInst) then
      FRemoteVisuals[I].BikeInst.ShadowMode := AMode;
end;

procedure TRemoteRidersManager.StartRelay(const AServerUrl: string;
  const ABikeJsonFileName, AFallbackBikeJsonFileName: string;
  APrivateRoom:Boolean;AAccountId:Integer;const AName:string);
var SL: TStringList;
begin
  StopRelay;
  FLocalDistance := 0; FLocalTime := 0;
  FRemoteVisualCount := 0; FPendingBuildCount := 0; FGuestSyncTimer := 0;

  try
    SL := TStringList.Create;
    try SL.LoadFromFile(URIToFilenameSafe(AFallbackBikeJsonFileName));
        FFallbackBikeJson := SL.Text;
    finally SL.Free; end;
  except on E: Exception do begin FFallbackBikeJson := ''; end; end;

  FRideClient := TRideRelayClient.Create;
  FRideClient.ServerUrl := AServerUrl;
  FRideClient.PrivateRoom:=APrivateRoom;
  if APrivateRoom then FRideClient.LocalRiderId:=AAccountId
  else FRideClient.LocalRiderId := 1 + Random(9999);
  FRideClient.LocalRiderName := AName;
  FRideClient.Start;
  Logger.Info('[Relay] ' + 'Started, ID=' + IntToStr(FRideClient.LocalRiderId));

  try
    SL := TStringList.Create;
    try SL.LoadFromFile(URIToFilenameSafe(ABikeJsonFileName));
        FRideClient.PushBikeConfig(SL.Text);
    finally SL.Free; end;
  except on E: Exception do
    Logger.Info('[Relay] ' + 'Config push failed: ' + E.Message);
  end;
end;

procedure TRemoteRidersManager.StopRelay;
var I:Integer;Scene:TCastleScene;
begin
  FPendingBuildCount := 0;
  FreeAndNil(FRideClient);
  for I:=0 to FRemoteVisualCount-1 do begin
    if(FLaneManager<>nil)and(I<Length(FRemoteLaneHandles))then
      FLaneManager.UnregisterRider(FRemoteLaneHandles[I]);
    Scene:=nil;
    if FRemoteVisuals[I].Agent<>nil then Scene:=FRemoteVisuals[I].Agent.Actor.Scene;
    FreeAndNil(FRemoteVisuals[I].BikeInst);
    FreeAndNil(FRemoteVisuals[I].Agent);
    Scene.Free;FreeAndNil(FRemoteVisuals[I].Transform);
    FRemoteVisuals[I]:=Default(TRemoteRiderVisual);
  end;
  FRemoteVisualCount:=0;FVisibleRiders:=0;
end;

{ ── Profiling ── }

function TRemoteRidersManager.GetProfilingData: TRelayProfilingData;
begin
  Result.RelayNet := FProf_RelayNet;
  Result.RelayBuild := FProf_RelayBuild;
  Result.RelayConfig := FProf_RelayConfig;
  Result.RelayPos := FProf_RelayPos;
  Result.RelayTotal := FProf_RelayNet + FProf_RelayBuild + FProf_RelayConfig + FProf_RelayPos;
  Result.VisibleRiders := FVisibleRiders;
  Result.RemoteVisualCount := FRemoteVisualCount;
  Result.PendingBuildCount := FPendingBuildCount;
end;

function TRemoteRidersManager.CountRemoteShapes: Integer;
var I: Integer;
begin
  Result := 0;
  for I := 0 to FRemoteVisualCount - 1 do
  begin
    if not FRemoteVisuals[I].Active or not Assigned(FRemoteVisuals[I].BikeInst) then Continue;
    Inc(Result, FRemoteVisuals[I].BikeInst.ActiveShapeCount);
  end;
end;

procedure TRemoteRidersManager.GetRemoteRiderShapeInfo(out Lines: string);
var I, RS: Integer;
begin
  Lines := '';
  for I := 0 to FRemoteVisualCount - 1 do
  begin
    if FRemoteVisuals[I].Active and Assigned(FRemoteVisuals[I].BikeInst) then
    begin
      RS := FRemoteVisuals[I].BikeInst.ActiveShapeCount;
      Lines := Lines + Format('  R%d:%d', [FRemoteVisuals[I].RiderId, RS]);
    end
    else if FRemoteVisuals[I].Active then
      Lines := Lines + Format('  R%d:queued', [FRemoteVisuals[I].RiderId]);
  end;
end;

procedure TRemoteRidersManager.UpdateRemoteAnimationSpeeds;
var
  I: Integer;
  Cad: Integer;
  CrankInt: Single;
begin
  for I := 0 to FRemoteVisualCount - 1 do
  begin
    if not FRemoteVisuals[I].Active then Continue;
    if not Assigned(FRemoteVisuals[I].BikeInst) then Continue;
    if not Assigned(FRemoteVisuals[I].Controller) then Continue;

    Cad := FRemoteVisuals[I].Controller.Cadence;
    if Cad > 0 then
      CrankInt := 60.0 / Cad
    else
      CrankInt := 9999;  { effectively stopped }

    FRemoteVisuals[I].BikeInst.SetAnimationSpeed(CrankInt, CrankInt);
  end;
end;

procedure TRemoteRidersManager.AnimateAllRiders(SecondsPassed: Single);
var
  I: Integer;
  Ag: TPhysicalAgent;
  Bike: TBikeInstance;
  ParentLean: Single;
begin
  for I := 0 to FRemoteVisualCount - 1 do
  begin
    if not FRemoteVisuals[I].Active then Continue;
    if not Assigned(FRemoteVisuals[I].BikeInst) then Continue;
    Bike:=FRemoteVisuals[I].BikeInst;
    Ag:=FRemoteVisuals[I].Agent;
    if Assigned(Ag)and Assigned(Ag.State)then begin
      ParentLean:=0;
      if not Ag.Actor.RiderOwnsLean then ParentLean:=Ag.State.CurrentTurnAngle;
      Bike.SetRiderDynamicsSituation(Ag.State.AppliedPowerWatts,
        Ag.State.CurrentSpeed*Ag.State.CurrentYawRateRad,ParentLean,Ag.State.CurrentModelPitch);
      Bike.SetRiderEffort(Ag.State.AppliedPowerWatts/220);
      Bike.SetWheelSpeedMps(Ag.State.CurrentSpeed);
    end;
    Bike.AnimateFrame(SecondsPassed);
    if Assigned(Ag)and Assigned(Ag.State)and Ag.Actor.RiderOwnsLean then begin
      Ag.State.CurrentTurnAngle:=Bike.RiderTotalLeanDeg;
      Ag.State.TargetTurnAngle:=Ag.State.CurrentTurnAngle;
    end;
  end;
end;

procedure TRemoteRidersManager.SetRidersVisible(AVisible: Boolean);
var
  I: Integer;
begin
  FRidersVisible := AVisible;
  { Exists всего корня BikeParametric (байк+райдер), не TripoShowRider —
    иначе скрывался только человек, а байк продолжал рисоваться. }
  for I := 0 to FRemoteVisualCount - 1 do
    if Assigned(FRemoteVisuals[I].BikeInst) then
      FRemoteVisuals[I].BikeInst.Group.Exists := AVisible;
end;

procedure TRemoteRidersManager.SetAnimationEnabled(AEnabled: Boolean);
var
  I: Integer;
begin
  FAnimationEnabled := AEnabled;
  for I := 0 to FRemoteVisualCount - 1 do
    if Assigned(FRemoteVisuals[I].BikeInst) then
      FRemoteVisuals[I].BikeInst.AnimationEnabled := AEnabled;
end;

procedure TRemoteRidersManager.SetShadowsVisible(AVisible: Boolean);
var
  I: Integer;
begin
  FShadowsVisible := AVisible;
  for I := 0 to FRemoteVisualCount - 1 do
    if Assigned(FRemoteVisuals[I].BikeInst) and
       (FRemoteVisuals[I].BikeInst.ShowShadow <> AVisible) then
      FRemoteVisuals[I].BikeInst.ShowShadow := AVisible;
  UpdateDistanceCulling;
end;

procedure TRemoteRidersManager.GetNearbyRiderPositions(
  const ACenter: TVector3; ARange: Single;
  var APositions: array of TVector3; out ACount: Integer);
var
  I: Integer;
  DX, DZ, DSq, RSq: Single;
begin
  ACount := 0;
  RSq := ARange * ARange;
  for I := 0 to FRemoteVisualCount - 1 do
  begin
    if not FRemoteVisuals[I].Active then Continue;
    if not Assigned(FRemoteVisuals[I].Transform) then Continue;
    DX := FRemoteVisuals[I].Transform.Translation.X - ACenter.X;
    DZ := FRemoteVisuals[I].Transform.Translation.Z - ACenter.Z;
    DSq := DX*DX + DZ*DZ;
    if DSq < RSq then
    begin
      if ACount <= High(APositions) then
      begin
        APositions[ACount] := FRemoteVisuals[I].Transform.Translation;
        Inc(ACount);
      end;
    end;
  end;
end;

end.
