unit GamePhysicsCommon;

interface

uses
  Classes,
  CastleVectors, CastleTransform, CastleViewport, CastleScene,
  CastleThirdPersonNavigation, CastleShapes, RiderGroundTurn;

type
  TRiderMoveConstraint = function(Tag: Pointer; const Position, Movement: TVector3;
    Commit: Boolean): TVector3 of object;
  TRiderHeadingConstraint = function(Tag: Pointer;
    const Position, PreviousDir, ProposedDir: TVector3;
    Commit: Boolean): TVector3 of object;

  TTrajectorySample = record
    Position: TVector3;
    TimeStamp: Single;
  end;

  TPhysicsMode = (
    pmKinematicCurrent,
    pmEngineRigidBody
  );

  { Physics level-of-detail.
    plFull    — trajectory sampling, turn forces, lean, full ground placement.
    plReduced — path following + acceleration, skip trajectory/lean/turn drag.
    plMinimal — simple distance-based movement, no ground raycast. }
  TPhysicsLOD = (
    plFull,
    plReduced,
    plMinimal
  );

  TPhysicsActor = class
  public
    Transform: TCastleTransform;
    Scene: TCastleScene;
    RigidBody: TCastleRigidBody;
    Viewport: TCastleViewport;
    Navigation: TCastleThirdPersonNavigation;
    RiderOwnsLean: Boolean; { visual body solver owns the complete bicycle roll }
  end;

  { Опциональный провайдер высоты земли. Заполняется AY мировым Y
    рельефа в точке (X, Z); возвращает True при успехе. Используется
    стриминговой картой Osm3d: её тайлы не имеют коллизий, поэтому
    высота берётся не raycast-ом, а прямым запросом к рельефному мешу.
    Когда не назначен (nil) — физика работает по-старому, через
    PhysicsRayCast. }
  TPositionConstraint = function(const From,Forward,HalfSize:TVector3;
    var Target:TVector3):Boolean of object;

  { ReferenceY is the current contact level; overlapping floors must not
    select an overhead deck or terrain above a tunnel. }
  TGroundQueryFunc = function(WorldX, WorldZ, ReferenceY: Single;
    out AY: Single): Boolean of object;

  { How FindGroundHeightAt resolved a sample (for bridge bounce diagnostics). }
  TGroundHitSource = (
    ghsNone,       { no state }
    ghsMeshQuery,  { GroundQuery hit — direct triangle barycentric Y (NOT ray) }
    ghsHoldLast,   { GroundQuery miss / no tile — kept LastGroundY }
    ghsRaycast,    { PhysicsRayCast hit (only when GroundQuery = nil) }
    ghsRayMiss     { raycast miss — kept LastGroundY }
  );

const
  { Максимум внутренних линий разметки полос в отладке (между краями).
    8 полос → 7 разделителей. }
  DEBUG_MAX_LANE_MARKS = 7;

type
  TPhysicsDebug = class
  public
    DebugSphereFrontWheel: TCastleSphere;
    DebugSphereRearWheel: TCastleSphere;
    DebugSphereFrontGround: TCastleSphere;
    DebugSphereRearGround: TCastleSphere;
    DebugSphereCarrot: TCastleSphere;
    { Отладочные линии поперечного сечения дороги (3 м вдоль движения,
      едут вместе с велосипедом). Геометрия строится по ТЕКУЩЕЙ ширине
      дороги (FState.CurrentRoadWidth — ровно то значение, что считает
      кинематика для полосного смещения; отдельно не пересчитывается).
        Center — осевая дороги (одним цветом);
        EdgeLeft/EdgeRight — края (±W/2, другим цветом);
        Lanes[] — разделители полос (третьим цветом). }
    DebugLineCenter: TCastleBox;
    DebugLineEdgeLeft: TCastleBox;
    DebugLineEdgeRight: TCastleBox;
    DebugLineLanes: array[0..DEBUG_MAX_LANE_MARKS - 1] of TCastleBox;
    DebugSpheresVisible: Boolean;
    constructor Create;
  end;

  TPhysicsReplayState = record
    GroundTurn: TGroundTurnState;
    AutoMove: Boolean;
    WorldPosition: TVector3;
    MovementVelocity: TVector3;
    ForwardDir: TVector3;
    CurrentYawRad: Single;
    PrevWorldPosition: TVector3;
    RealVelocity: TVector3;
    TrajectorySamples: array[0..63] of TTrajectorySample;
    TrajectorySampleCount: Integer;
    TrajectorySampleIndex: Integer;
    SimulationTime: Single;
    AppliedPowerWatts: Single;
    CurrentSpeed: Single;
    CurrentSlopeAngle: Single;
    CurrentGroundPitch: Single;
    CurrentSlopeCorrDeg: Single;
    CurrentSlopeCorrValid: Boolean;
    CurrentModelPitch: Single;
    TargetModelPitch: Single;
    CurrentTurnAngle: Single;
    TargetTurnAngle: Single;
    CurrentYawRateRad: Single;
    CurrentLateralAccel: Single;
    CurrentTurnRadius: Single;
    CurrentCurvature: Single;
    CurrentTurnAngleDeltaRad: Single;
    LastGroundY: Single;
    AccumulatedTime: Single;
    LaneOffset: Single;
    CurrentRoadWidth: Single;
    CumulativeDistance: Single;
    CameraRelativePos: TVector3;
    CameraDirectionSaved: TVector3;
    CameraUpSaved: TVector3;
    CameraStateValid: Boolean;
    FrontGroundPoint: TVector3;
    FrontGroundPointValid: Boolean;
    RearGroundPoint: TVector3;
    RearGroundPointValid: Boolean;
    ShadowGroundNormal: TVector3;
    ShadowGroundNormalValid: Boolean;
    ShadowCenterOffset: TVector3;
  end;

  {$M+}
  TPhysicsState = class
  private
    { Геттеры для published-прокси TVector3-полей (record-типы в published
      недоступны — MCP читает их по компонентам). }
    function GetPosX: Single;
    function GetPosY: Single;
    function GetPosZ: Single;
    function GetVelX: Single;
    function GetVelY: Single;
    function GetVelZ: Single;
  public
    function CaptureReplay: TPhysicsReplayState;
    procedure RestoreReplay(const Saved: TPhysicsReplayState);
  public
    AutoMove: Boolean;

    WorldPosition: TVector3;
    { Physical XZ velocity, excluding collision/route/network corrections. }
    MovementVelocity: TVector3;
    { Open-world controls. The same contact/acceleration pipeline is used,
      with no route carrot, lane pull or endpoint turnaround. }
    FreeTravel, Walking: Boolean;
    TravelSteering, TravelTargetSpeed, TravelBrake: Single;
    GroundTurn: TGroundTurnState;
    PositionConstraint: TPositionConstraint;
    CollisionHalfWidth, CollisionBodyHeight: Single;
    function ConstrainBodyMove(const From:TVector3; var Target:TVector3):Boolean;
  public
    ForwardDir: TVector3;
    CurrentYawRad: Single;
    PrevWorldPosition: TVector3;
    RealVelocity: TVector3;

    TrajectorySamples: array[0..63] of TTrajectorySample;
    TrajectorySampleCount: Integer;
    TrajectorySampleIndex: Integer;
    SimulationTime: Single;

    AppliedPowerWatts: Single;
    AvatarMass: Single;
    DragCoefficient: Single;
    FrontalArea: Single;
    RollingResistance: Single;

    CurrentSpeed: Single;
    CurrentSlopeAngle: Single;
    CurrentGroundPitch: Single;
    { Поправка уклона от FIT-слоя: Δ = уклон со слоем − уклон видимого
      меша (колёса), градусы. Valid=False, когда SlopeQuery не назначен
      или не ответил (нет тайла/слоя) — HUD тогда показывает «—». }
    CurrentSlopeCorrDeg: Single;
    CurrentSlopeCorrValid: Boolean;
    CurrentModelPitch: Single;
    TargetModelPitch: Single;
    CurrentTurnAngle: Single;
    TargetTurnAngle: Single;
    CurrentYawRateRad: Single;
    CurrentLateralAccel: Single;
    CurrentTurnRadius: Single;
    CurrentCurvature: Single;
    CurrentTurnAngleDeltaRad: Single;

    AvatarScale: Single;
    ModelHalfLength: Single;
    ScaledWheelRadius: Single;
    ScaledWheelInset: Single;
    LastGroundY: Single;
    AccumulatedTime: Single;
    ModelLocalMinY: Single;
    ModelHeight: Single;
    { True — модель стоит на колёсах в точке Y=0 СВОЕГО кадра (параметрический
      байк TBikeInstance), и ModelLocalMinY из bbox сцены НЕ используем:
      после переворота единой сцены локальный bbox смешивает кадры
      (glb-локаль райдера + P^-1-контейнер) и даёт мусор — аватар висит. }
    WheelContactAtOrigin: Boolean;
    { Вычисляются автоматически в ComputeGroundContactOffset
      через raycast внутрь геометрии модели.
      Offset = разница между дном bbox и дном шины, × Scale. }
    FrontWheelContactOffset: Single;
    RearWheelContactOffset: Single;
    GroundContactOffset: Single;  { среднее front/rear }

    { Lane offset — perpendicular displacement from path center (meters) }
    LaneOffset: Single;

    { Когда True — боковое смещение (LaneOffset) задаётся ИЗВНЕ (менеджер
      полос), и кинематика его НЕ пересчитывает/не перетирает. False —
      кинематика сама считает offset из ширины дороги (одиночный режим,
      бот). Менеджеру полос подчиняются аватар и удалённые райдеры. }
    LaneOffsetExternal: Boolean;
    TrafficMoveConstraint: TRiderMoveConstraint;
    TrafficHeadingConstraint: TRiderHeadingConstraint;
    TrafficTag: Pointer;
    TrafficSpeedLimit: Single;

    { Ширина дороги под текущей точкой пути (метры, 0 = мимо дорог).
      Записывается кинематикой каждый шаг из RoadWidthAt — то же самое
      значение, по которому считается полосное смещение. Хранится здесь,
      чтобы отладочная визуализация (линии разметки/центра/края) брала
      ровно текущий результат, а не пересчитывала его заново. }
    CurrentRoadWidth: Single;

    { Cumulative distance traveled on path — tracked in FixedStep }
    CumulativeDistance: Single;

    { Physics LOD — controls which effects are computed }
    PhysicsLOD: TPhysicsLOD;

    CameraRelativePos: TVector3;
    CameraDirectionSaved: TVector3;
    CameraUpSaved: TVector3;
    CameraStateValid: Boolean;
    CameraLockActive: Boolean;

    { Опциональный провайдер высоты земли (стриминговая карта Osm3d).
      Когда назначен, FindGroundHeightAt берёт высоту из него вместо
      raycast-а. nil = обычный raycast по сцене. }
    GroundQuery: TGroundQueryFunc;

    { Отдельный провайдер высоты для УКЛОНА (CurrentSlopeAngle → гравитация
      в CalculateAcceleration, инклайн FTMS): земля с поправкой FIT-слоя.
      Колёса/посадка при этом остаются на GroundQuery (видимый меш) — байк
      не тонет/не парит относительно картинки, а физика ускорений чувствует
      нивелированный профиль (мосты, настилы). nil = уклон из той же земли,
      что и колёса. }
    SlopeQuery: TGroundQueryFunc;

    { Ground-plane normal under the bike, captured by UpdateVisualGroundPlacement
      from the SAME wheel-ground samples that place the bike, plus two lateral
      samples toward the shadow. World frame, faces up. Used to tilt the contact
      shadow so it follows the terrain slope. ShadowGroundNormalValid = False
      until the first successful capture (e.g. tiles not yet loaded). }
    FrontGroundPoint: TVector3; { same front-wheel sample used for placement }
    FrontGroundPointValid: Boolean;
    RearGroundPoint: TVector3;
    RearGroundPointValid: Boolean;
    ShadowGroundNormal: TVector3;
    ShadowGroundNormalValid: Boolean;
    { Horizontal offset (world X,Z; Y ignored) from the bike to the CENTRE of
      its cast shadow. Set by the game from the sun azimuth each frame. The
      plane-fit samples are centred here (plus a centre sample) so the shadow
      plane matches the ground UNDER THE SHADOW, which a low sun pushes off to
      one side, not the ground under the bike. Zero = shadow under the bike. }
    ShadowCenterOffset: TVector3;
    { False = теневой плоскости нет (тень скрыта, выключена или райдер
      дальше shadow-LOD) — UpdateVisualGroundPlacement пропускает 5 проб
      земли под её подгон. True по умолчанию (прежнее поведение). }
    ShadowPlaneWanted: Boolean;

    constructor Create;
    procedure ResetDynamic;
  published
    { Read-only RTTI-прокси для MCP (live-телеметрия/состояние аватара).
      Имена отличаются от public-полей, т.к. property не может совпадать
      по имени с полем того же класса. }
    property Speed: Single read CurrentSpeed;
    property Power: Single read AppliedPowerWatts;
    property Mass: Single read AvatarMass;
    property SlopeDeg: Single read CurrentSlopeAngle;
    property SlopeCorrDeg: Single read CurrentSlopeCorrDeg;
    property SlopeCorrValid: Boolean read CurrentSlopeCorrValid;
    property GroundPitchDeg: Single read CurrentGroundPitch;
    property ModelPitchDeg: Single read CurrentModelPitch;
    property TurnAngle: Single read CurrentTurnAngle;
    property YawRateRad: Single read CurrentYawRateRad;
    property LateralAccel: Single read CurrentLateralAccel;
    property TurnRadius: Single read CurrentTurnRadius;
    property Curvature: Single read CurrentCurvature;
    property YawRad: Single read CurrentYawRad;
    property AutoMoveFlag: Boolean read AutoMove;
    property SimTime: Single read SimulationTime;
    property Distance: Single read CumulativeDistance;
    property RoadWidth: Single read CurrentRoadWidth;
    property LaneOffsetM: Single read LaneOffset;
    property GroundY: Single read LastGroundY;
    property PosX: Single read GetPosX;
    property PosY: Single read GetPosY;
    property PosZ: Single read GetPosZ;
    property VelX: Single read GetVelX;
    property VelY: Single read GetVelY;
    property VelZ: Single read GetVelZ;
  end;
  {$M-}

  { Shared ground placement state — used by both main avatar and remote riders }
  TGroundPlacementState = record
    SmoothedY: Single;
    Valid: Boolean;
    LastY: Single;
  end;

const
  { Тропинка / узкая дорожка: на ширине <= этого порога полосное движение
    вырождается — райдеры едут по ЦЕНТРУ, друг за другом. Порог совпадает по
    смыслу с SNAP_WIDE_THRESHOLD_M снаппера маршрута (Osm3dRouteSnapper):
    дорога <= 5 м и там считается однорядной, трек кладётся на осевую.
    Значение продублировано сознательно — тянуть Osm3d-зависимость в
    физический юнит не хочется. }
  PATH_SINGLE_FILE_WIDTH_M = 5.0;

  { Плавный ввод полос обратно с ростом ширины: при ширине
    порог + PATH_CENTER_BLEND_M полосное смещение действует полностью.
    Рампа ПРОСТРАНСТВЕННАЯ (по локальной ширине из профиля), поэтому при
    движении вдоль сужающейся дороги смещение стягивается к центру
    непрерывно, без боковых рывков на границе порога. }
  PATH_CENTER_BLEND_M      = 2.0;

{ Доля полосного смещения по ширине дороги: 0 на тропинке
  (<= PATH_SINGLE_FILE_WIDTH_M), 1 на нормальной дороге (>= порог + BLEND),
  линейная рампа между. ЕДИНАЯ точка правила «на тропинке — по центру»:
  на неё умножают своё боковое смещение и менеджер полос (аватар, удалённые
  райдеры), и одиночная кинематика (соло-режим, боты). }
function LaneCenterFactor(ARoadWidth: Single): Single;

{ Wheel ground-height CSV log (bridge bounce diagnostics).
  Columns written by physics PlaceActorByWheels / UpdateVisualGroundProbes. }
procedure PhysicsGroundLogStart(const AFilePath: string);
procedure PhysicsGroundLogStop;
function PhysicsGroundLogActive: Boolean;
function PhysicsGroundLogPath: string;
procedure PhysicsGroundLogLine(const Line: string);
function GroundHitSourceName(S: TGroundHitSource): string;

type
  { ── Lane management — shared for all rider types ── }

  TLaneRiderHandle = Integer;  { opaque handle returned by Register }

  TLaneRider = record
    Active: Boolean;
    LoopPos: Single;       { current position on loop }
    PrevLoopPos: Single;   { previous frame position }
    Lane: Integer;         { target lane (integer) }
    SmoothLane: Single;    { current smooth lane (float, lerps toward Lane) }
    Tag: Pointer;          { owner data — TPhysicalAgent etc }
    DriftTimer: Single;    { countdown to next random lane drift (seconds) }
    PoseValid: Boolean;
    WorldPosition, ForwardDir: TVector3;
    CollisionDir: TVector3; { actual body heading; ForwardDir is the lane tangent }
    RoadWidth, ActualOffset, Speed: Single;
    PassageKey: QWord;
    PassageForward, PassageInside, PassageExclusive: Boolean;
    PassageDistance, PassageAge: Single;
  end;

  TLaneReplayState = array of TLaneRider;

  {$M+}
  TLaneManager = class
  private
    FRiders: array of TLaneRider;
    FCount: Integer;
    FPathTotalLength: Single;
    FLaneWidth: Single;
    FLaneCount: Integer;
    FDefaultLane: Integer;
    FLastDT: Single;
    { Переменный профиль ширины дороги по дистанции (из снапа к OSM):
      FWidthDist — кумулятивная дистанция (возрастает), FWidthVal —
      ширина дороги (м) в этой точке. Параллельны. Пусто → фиксированная
      ширина FLaneWidth (как было). FNominalWidth — запасная ширина для
      участков мимо дорог / без профиля. }
    FWidthDist: array of Single;
    FWidthVal:  array of Single;
    FNominalWidth: Single;
    function WidthAtLoop(ALoopPos: Single): Single;
    function OffsetForWidth(ALane, ARoadWidth: Single): Single;
    function LaneClear(AHandle, ALane: Integer; Clearance: Single): Boolean;
  public
    constructor Create;

    procedure SetRoad(ARoadWidth, APathLength: Single);
    procedure SetPathLength(APathLength: Single);
    { Передать профиль ширины (дистанция→ширина), чтобы шаг между полосами
      следовал реальной (переменной) ширине дороги после снапа к OSM.
      ADist — по возрастанию, та же длина, что AWidth. Пустые массивы →
      вернуться к фиксированному шагу. }
    procedure SetWidthProfile(const ADist, AWidth: array of Single);
    function RegisterRider(ATag: Pointer): TLaneRiderHandle;
    function FindRider(ATag: Pointer): TLaneRiderHandle;
    function RiderTag(AHandle: TLaneRiderHandle): Pointer;
    procedure SetRiderPose(AHandle: TLaneRiderHandle; const Position, Direction: TVector3;
      RoadWidth, ActualOffset, Speed: Single);
    procedure SetRiderHeading(AHandle: TLaneRiderHandle; const Direction: TVector3);
    procedure InvalidateRiderPose(AHandle: TLaneRiderHandle);
    procedure SetNarrowPassage(AHandle:TLaneRiderHandle;Key:QWord;
      Forward,Inside:Boolean;EntryDistance:Single;Exclusive:Boolean=False);
    function ReservePlacement(AHandle: TLaneRiderHandle; const Center, Direction: TVector3;
      RoadWidth: Single; out Offset: Single): Boolean;
    function ConstrainMovement(Tag: Pointer; const Position, Movement: TVector3;
      Commit: Boolean): TVector3;
    function ConstrainHeading(Tag: Pointer;
      const Position, PreviousDir, ProposedDir: TVector3;
      Commit: Boolean): TVector3;
    function TrafficLimit(AHandle: TLaneRiderHandle): Single;
    procedure UnregisterRider(AHandle: TLaneRiderHandle);
    procedure ReplaceRiderTag(OldTag,NewTag:Pointer);
    procedure SetRiderPos(AHandle: TLaneRiderHandle; ALoopPos: Single);
    procedure SetRiderActive(AHandle: TLaneRiderHandle; AActive: Boolean);
    function GetLane(AHandle: TLaneRiderHandle): Integer;
    function GetLaneOffset(ALane: Integer): Single;
    { Smooth offset — use this for positioning (smooth lane transitions) }
    function GetSmoothOffset(AHandle: TLaneRiderHandle): Single; overload;
    { Width at the physical path cursor, independent of accumulated distance. }
    function GetSmoothOffset(AHandle: TLaneRiderHandle; ARoadWidth: Single): Single; overload;
    procedure Update(const DeltaTime: Single);
    function CaptureReplay: TLaneReplayState;
    procedure RestoreReplay(const Saved: TLaneReplayState);
  published
    property LaneCount: Integer read FLaneCount;
    property DefaultLane: Integer read FDefaultLane;
    property PathTotalLength: Single read FPathTotalLength;
    property RiderCount: Integer read FCount;
  end;
  {$M-}

const
  Gravity = 9.81;
  AirDensity = 1.225;
  DefaultMass = 85.0;          { rider 75 + bike 10 kg }
  DefaultPower = 200.0;
  MaxSpeed = 100.0;
  MaxPropulsionForce = 1600.0;
  DefaultDragCoefficient = 0.88;  { Cd for road cyclist on hoods }
  DefaultFrontalArea = 0.40;      { m², road cyclist on hoods }
  DefaultRollingResistance = 0.005; { Crr, road tires on asphalt }

  PitchSmoothness = 60.0;
  RollSmoothness = 120.0;

  BaseWheelInset = 0.33;
  BaseWheelRadius = 0.33;
  DefaultWheelbase = 1.0;
  ModelBaseYRotation = -Pi / 2;

  MaxTurnSpeed = Pi * 1.0;

  MaxLeanAngle = 45.0;
  TurnLeanMultiplier = 1.95;
  TurnDragFactor = 1.8;
  TurnSpeedSafety = 0.92;
  MaxAllowedLateralAccelFactor = 0.85;
  MinVelocityForTrajectory = 0.10;
  TrajectoryRadiusWindowSeconds = 0.2;
  MaxMeaningfulTurnRadius = 5000.0;

  GroundSmoothTime = 0.015;    { ground Y smoothing time constant }
  NearRiderRangeSq = 50.0 * 50.0; { within 50m use full ground placement }

{ ═══════════════════════════════════════════════════════════════════
  Shared cycling acceleration formula.
  Used by avatar, bots, and remote riders — single source of truth.

  Parameters:
    Power        — applied power in watts
    Speed        — current speed m/s
    Mass         — rider + bike kg
    Cd           — drag coefficient
    Area         — frontal area m²
    Crr          — rolling resistance coefficient
    SlopeDeg     — current slope in degrees (positive = uphill)
    DeltaTime    — actual integration step in seconds
    Curvature    — path curvature 1/m (0 = straight, used for turn drag)
    TurnSpeedLim — max safe speed for current curvature (MaxSpeed if straight)
    BrakeForceN  — nonnegative measured brake force, separate from propulsion

  Returns the average acceleration of an implicit speed step in m/s².
  ═══════════════════════════════════════════════════════════════════ }
function ComputeCyclingAcceleration(
  Power, Speed, Mass, Cd, Area, Crr, SlopeDeg, DeltaTime: Single;
  Curvature: Single = 0;
  TurnSpeedLim: Single = MaxSpeed;
  BrakeForceN: Single = 0): Single;

{ CurrentSlopeAngle / CurrentGroundPitch — ГРАДУСЫ (atan2 Δh/L).
  Тренажёр, FIT grade, позы — ПРОЦЕНТЫ: tan(°)×100.
  5° → 8.75%, 10° → 17.6%. }
function SlopeDegToGradePct(AngleDeg: Single): Single;
function GradePctToSlopeDeg(GradePct: Single): Single;

{ Shared ground raycast — used by main avatar physics and remote riders.
  ASkip = transform to ignore (rider's own model), can be nil.
  Returns ground Y at (X, Z). Falls back to ALastY if no hit. }
function RaycastGroundY(AItems: TCastleAbstractRootTransform;
  X, Z, ALastY: Single; ASkip: TCastleTransform = nil): Single;

{ Shared smooth ground placement. Places ATransform at TargetXZ,
  raycasts for ground Y, smooths result. Call every frame for near riders. }
procedure PlaceOnGroundSmooth(AItems: TCastleAbstractRootTransform;
  ATransform: TCastleTransform; const TargetPos: TVector3;
  var GState: TGroundPlacementState; const DeltaTime: Single;
  ASkip: TCastleTransform = nil);

implementation

uses
  SysUtils, Math, GameTrafficCollision,
  GameMath;     { WrapDistance — replaces former nested WrapFwd helper }

function SlopeDegToGradePct(AngleDeg: Single): Single;
begin
  Result := Tan(DegToRad(AngleDeg)) * 100.0;
end;

function GradePctToSlopeDeg(GradePct: Single): Single;
begin
  Result := RadToDeg(ArcTan(GradePct * 0.01));
end;

{ ═══════════════════════════════════════════════════════════════════
  ComputeCyclingAcceleration — единая формула для всех райдеров
  ═══════════════════════════════════════════════════════════════════ }

function ComputeCyclingAcceleration(
  Power, Speed, Mass, Cd, Area, Crr, SlopeDeg, DeltaTime: Single;
  Curvature: Single;
  TurnSpeedLim, BrakeForceN: Single): Single;
var
  V0,H,P,InvMass,SlopeRad,RollingSlopeFactor:Double;
  ConstantResistance,QuadraticResistance,Lo,Hi,Mid,NextSpeed:Double;
  I:Integer;

  function Residual(V:Double):Double;
  var Force,A:Double;
  begin
    if P<=0 then Force:=0
    else if V<=0 then Force:=MaxPropulsionForce
    else begin
      Force:=P/V;
      if Force>MaxPropulsionForce then Force:=MaxPropulsionForce;
    end;
    A:=(Force-ConstantResistance-QuadraticResistance*V*V)*InvMass;
    if V>TurnSpeedLim then A:=A-(V-TurnSpeedLim)*2.5;
    if A>4.5 then A:=4.5 else if A< -6 then A:=-6;
    Result:=V-V0-H*A;
  end;

begin
  Result:=0;
  if(DeltaTime<=0)or(Mass<=0)or(Speed<0)or(Cd<0)or(Area<0)or(Crr<0)or(BrakeForceN<0)or
    IsNan(DeltaTime)or IsInfinite(DeltaTime)or IsNan(Mass)or IsInfinite(Mass)or
    IsNan(Speed)or IsInfinite(Speed)or IsNan(Power)or IsInfinite(Power)or
    IsNan(Cd)or IsInfinite(Cd)or IsNan(Area)or IsInfinite(Area)or
    IsNan(Crr)or IsInfinite(Crr)or IsNan(SlopeDeg)or IsInfinite(SlopeDeg)or
    IsNan(Curvature)or IsInfinite(Curvature)or IsNan(TurnSpeedLim)or IsInfinite(TurnSpeedLim)or
    IsNan(BrakeForceN)or IsInfinite(BrakeForceN)then Exit;
  V0:=Speed;H:=DeltaTime;P:=Power;if P<0 then P:=0;
  InvMass:=1.0/Mass;SlopeRad:=DegToRad(Double(SlopeDeg));
  RollingSlopeFactor:=Cos(SlopeRad);
  if RollingSlopeFactor<0.2 then RollingSlopeFactor:=0.2;
  ConstantResistance:=Mass*Gravity*(Sin(SlopeRad)+Crr*RollingSlopeFactor)+BrakeForceN;
  QuadraticResistance:=0.5*AirDensity*Cd*Area+TurnDragFactor*Abs(Curvature);
  { Backward Euler evaluates traction, drag and turn braking at the new
    speed. No arbitrary speed floor creates a false uphill starting-power
    threshold. Even tiny positive watts cannot create a finite speed kick.
    The residual is strictly increasing: bounded bisection has one root. }
  Lo:=V0-6*H;if Lo<0 then Lo:=0;
  Hi:=V0+4.5*H;
  if Residual(Lo)>=0 then NextSpeed:=Lo
  else if Residual(Hi)<=0 then NextSpeed:=Hi
  else begin
    for I:=1 to 28 do begin
      Mid:=(Lo+Hi)*0.5;
      if Residual(Mid)>0 then Hi:=Mid else Lo:=Mid;
      if Hi-Lo<=1e-9 then Break;
    end;
    NextSpeed:=(Lo+Hi)*0.5;
  end;
  Result:=(NextSpeed-V0)/H;
  if Result>4.5 then Result:=4.5 else if Result< -6 then Result:=-6;
end;

{ ═══════════════════════════════════════════════════════════════════ }

constructor TPhysicsDebug.Create;
begin
  inherited Create;
  DebugSpheresVisible := false;
end;

{ TPhysicsState — published-прокси геттеры (MCP RTTI) }

function TPhysicsState.GetPosX: Single;
begin
  Result := WorldPosition.X;
end;

function TPhysicsState.GetPosY: Single;
begin
  Result := WorldPosition.Y;
end;

function TPhysicsState.GetPosZ: Single;
begin
  Result := WorldPosition.Z;
end;

function TPhysicsState.GetVelX: Single;
begin
  Result := RealVelocity.X;
end;

function TPhysicsState.GetVelY: Single;
begin
  Result := RealVelocity.Y;
end;

function TPhysicsState.GetVelZ: Single;
begin
  Result := RealVelocity.Z;
end;

function TPhysicsState.CaptureReplay: TPhysicsReplayState;
begin
  Result.AutoMove:=AutoMove;
  Result.GroundTurn:=GroundTurn;
  Result.WorldPosition:=WorldPosition;
  Result.MovementVelocity:=MovementVelocity;
  Result.ForwardDir:=ForwardDir;
  Result.CurrentYawRad:=CurrentYawRad;
  Result.PrevWorldPosition:=PrevWorldPosition;
  Result.RealVelocity:=RealVelocity;
  Result.TrajectorySamples:=TrajectorySamples;
  Result.TrajectorySampleCount:=TrajectorySampleCount;
  Result.TrajectorySampleIndex:=TrajectorySampleIndex;
  Result.SimulationTime:=SimulationTime;
  Result.AppliedPowerWatts:=AppliedPowerWatts;
  Result.CurrentSpeed:=CurrentSpeed;
  Result.CurrentSlopeAngle:=CurrentSlopeAngle;
  Result.CurrentGroundPitch:=CurrentGroundPitch;
  Result.CurrentSlopeCorrDeg:=CurrentSlopeCorrDeg;
  Result.CurrentSlopeCorrValid:=CurrentSlopeCorrValid;
  Result.CurrentModelPitch:=CurrentModelPitch;
  Result.TargetModelPitch:=TargetModelPitch;
  Result.CurrentTurnAngle:=CurrentTurnAngle;
  Result.TargetTurnAngle:=TargetTurnAngle;
  Result.CurrentYawRateRad:=CurrentYawRateRad;
  Result.CurrentLateralAccel:=CurrentLateralAccel;
  Result.CurrentTurnRadius:=CurrentTurnRadius;
  Result.CurrentCurvature:=CurrentCurvature;
  Result.CurrentTurnAngleDeltaRad:=CurrentTurnAngleDeltaRad;
  Result.LastGroundY:=LastGroundY;
  Result.AccumulatedTime:=AccumulatedTime;
  Result.LaneOffset:=LaneOffset;
  Result.CurrentRoadWidth:=CurrentRoadWidth;
  Result.CumulativeDistance:=CumulativeDistance;
  Result.CameraRelativePos:=CameraRelativePos;
  Result.CameraDirectionSaved:=CameraDirectionSaved;
  Result.CameraUpSaved:=CameraUpSaved;
  Result.CameraStateValid:=CameraStateValid;
  Result.FrontGroundPoint:=FrontGroundPoint;
  Result.FrontGroundPointValid:=FrontGroundPointValid;
  Result.RearGroundPoint:=RearGroundPoint;
  Result.RearGroundPointValid:=RearGroundPointValid;
  Result.ShadowGroundNormal:=ShadowGroundNormal;
  Result.ShadowGroundNormalValid:=ShadowGroundNormalValid;
  Result.ShadowCenterOffset:=ShadowCenterOffset;
end;

procedure TPhysicsState.RestoreReplay(const Saved: TPhysicsReplayState);
begin
  AutoMove:=Saved.AutoMove;
  GroundTurn:=Saved.GroundTurn;
  WorldPosition:=Saved.WorldPosition;
  MovementVelocity:=Saved.MovementVelocity;
  ForwardDir:=Saved.ForwardDir;
  CurrentYawRad:=Saved.CurrentYawRad;
  PrevWorldPosition:=Saved.PrevWorldPosition;
  RealVelocity:=Saved.RealVelocity;
  TrajectorySamples:=Saved.TrajectorySamples;
  TrajectorySampleCount:=Saved.TrajectorySampleCount;
  TrajectorySampleIndex:=Saved.TrajectorySampleIndex;
  SimulationTime:=Saved.SimulationTime;
  AppliedPowerWatts:=Saved.AppliedPowerWatts;
  CurrentSpeed:=Saved.CurrentSpeed;
  CurrentSlopeAngle:=Saved.CurrentSlopeAngle;
  CurrentGroundPitch:=Saved.CurrentGroundPitch;
  CurrentSlopeCorrDeg:=Saved.CurrentSlopeCorrDeg;
  CurrentSlopeCorrValid:=Saved.CurrentSlopeCorrValid;
  CurrentModelPitch:=Saved.CurrentModelPitch;
  TargetModelPitch:=Saved.TargetModelPitch;
  CurrentTurnAngle:=Saved.CurrentTurnAngle;
  TargetTurnAngle:=Saved.TargetTurnAngle;
  CurrentYawRateRad:=Saved.CurrentYawRateRad;
  CurrentLateralAccel:=Saved.CurrentLateralAccel;
  CurrentTurnRadius:=Saved.CurrentTurnRadius;
  CurrentCurvature:=Saved.CurrentCurvature;
  CurrentTurnAngleDeltaRad:=Saved.CurrentTurnAngleDeltaRad;
  LastGroundY:=Saved.LastGroundY;
  AccumulatedTime:=Saved.AccumulatedTime;
  LaneOffset:=Saved.LaneOffset;
  CurrentRoadWidth:=Saved.CurrentRoadWidth;
  CumulativeDistance:=Saved.CumulativeDistance;
  CameraRelativePos:=Saved.CameraRelativePos;
  CameraDirectionSaved:=Saved.CameraDirectionSaved;
  CameraUpSaved:=Saved.CameraUpSaved;
  CameraStateValid:=Saved.CameraStateValid;
  FrontGroundPoint:=Saved.FrontGroundPoint;
  FrontGroundPointValid:=Saved.FrontGroundPointValid;
  RearGroundPoint:=Saved.RearGroundPoint;
  RearGroundPointValid:=Saved.RearGroundPointValid;
  ShadowGroundNormal:=Saved.ShadowGroundNormal;
  ShadowGroundNormalValid:=Saved.ShadowGroundNormalValid;
  ShadowCenterOffset:=Saved.ShadowCenterOffset;
end;

constructor TPhysicsState.Create;
begin
  inherited Create;

  AvatarMass := DefaultMass;
  AppliedPowerWatts := DefaultPower;
  DragCoefficient := DefaultDragCoefficient;
  FrontalArea := DefaultFrontalArea;
  RollingResistance := DefaultRollingResistance;
  PhysicsLOD := plFull;

  WorldPosition := Vector3(0, 0, 0);
  ForwardDir := Vector3(0, 0, 1);
  CurrentRoadWidth := 0.0;
  LaneOffsetExternal := False;
  CameraDirectionSaved := Vector3(0, 0, -1);
  CameraUpSaved := Vector3(0, 1, 0);

  GroundQuery := nil;
  SlopeQuery := nil;
  CollisionHalfWidth:=0.36;
  CollisionBodyHeight:=1.78;

  ShadowGroundNormal := Vector3(0, 1, 0);
  ShadowGroundNormalValid := False;
  ShadowCenterOffset := Vector3(0, 0, 0);
  ShadowPlaneWanted := True;   { прежнее поведение: плоскость тени считается }

  ResetDynamic;
end;

function TPhysicsState.ConstrainBodyMove(const From:TVector3; var Target:TVector3):Boolean;
var HalfSize:TVector3;
begin
  Result:=False;if not Assigned(PositionConstraint) then Exit;
  if Walking then HalfSize:=Vector3(CollisionHalfWidth,CollisionBodyHeight*0.5,0.4)
  else HalfSize:=Vector3(CollisionHalfWidth,(CollisionBodyHeight+0.2)*0.5,
    Max(0.85,ModelHalfLength-ScaledWheelInset+ScaledWheelRadius));
  Result:=PositionConstraint(From,ForwardDir,HalfSize,Target);
end;

procedure TPhysicsState.ResetDynamic;
begin
  GroundTurn:=Default(TGroundTurnState);
  AutoMove := false;
  CurrentYawRad := 0;
  PrevWorldPosition := Vector3(0, 0, 0);
  RealVelocity := Vector3(0, 0, 0);
  MovementVelocity := Vector3(0, 0, 0);
  TrajectorySampleCount := 0;
  TrajectorySampleIndex := 0;
  SimulationTime := 0;

  CurrentSpeed := 0;
  CurrentSlopeAngle := 0;
  CurrentGroundPitch := 0;
  CurrentSlopeCorrDeg := 0;
  CurrentSlopeCorrValid := False;
  CurrentModelPitch := 0;
  TargetModelPitch := 0;
  CurrentTurnAngle := 0;
  TargetTurnAngle := 0;
  CurrentYawRateRad := 0;
  CurrentLateralAccel := 0;
  CurrentTurnRadius := 0;
  CurrentCurvature := 0;
  CurrentTurnAngleDeltaRad := 0;

  LastGroundY := 0;
  AccumulatedTime := 0;
  LaneOffset := 0;
  CumulativeDistance := 0;

  CameraRelativePos := Vector3(0, 0, 0);
  CameraStateValid := false;
  CameraLockActive := false;
end;

{ ======================== TLaneManager ======================== }

function LaneCenterFactor(ARoadWidth: Single): Single;
begin
  if ARoadWidth <= PATH_SINGLE_FILE_WIDTH_M then
    Result := 0.0
  else if ARoadWidth >= PATH_SINGLE_FILE_WIDTH_M + PATH_CENTER_BLEND_M then
    Result := 1.0
  else
    Result := (ARoadWidth - PATH_SINGLE_FILE_WIDTH_M) / PATH_CENTER_BLEND_M;
end;

var
  GPhysGroundLogActive: Boolean = False;
  GPhysGroundLogPath: string = '';
  GPhysGroundLog: TextFile;
  GPhysGroundLogOpen: Boolean = False;

function GroundHitSourceName(S: TGroundHitSource): string;
begin
  case S of
    ghsMeshQuery: Result := 'mesh';
    ghsHoldLast:  Result := 'hold';
    ghsRaycast:   Result := 'ray';
    ghsRayMiss:   Result := 'ray_miss';
  else
    Result := 'none';
  end;
end;

procedure PhysicsGroundLogStart(const AFilePath: string);
begin
  PhysicsGroundLogStop;
  if Trim(AFilePath) = '' then Exit;
  GPhysGroundLogPath := AFilePath;
  AssignFile(GPhysGroundLog, GPhysGroundLogPath);
  Rewrite(GPhysGroundLog);
  WriteLn(GPhysGroundLog,
    't_ms,sim_s,tag,has_query,' +
    'fx,fz,fy,fsrc,fhit,rx,rz,ry,rsrc,rhit,' +
    'avg_raw,smooth_y,avatar_y,cum_dist,d_front_rear,d_smooth,' +
    'fwx,fwy,fwz,rwx,rwy,rwz,' +
    'f_off,r_off,wheel_r,wx,wz');
  Flush(GPhysGroundLog);
  GPhysGroundLogOpen := True;
  GPhysGroundLogActive := True;
end;

procedure PhysicsGroundLogStop;
begin
  GPhysGroundLogActive := False;
  if GPhysGroundLogOpen then
  begin
    CloseFile(GPhysGroundLog);
    GPhysGroundLogOpen := False;
  end;
end;

function PhysicsGroundLogActive: Boolean;
begin
  Result := GPhysGroundLogActive and GPhysGroundLogOpen;
end;

function PhysicsGroundLogPath: string;
begin
  Result := GPhysGroundLogPath;
end;

procedure PhysicsGroundLogLine(const Line: string);
begin
  if not PhysicsGroundLogActive then Exit;
  WriteLn(GPhysGroundLog, Line);
  Flush(GPhysGroundLog);
end;

constructor TLaneManager.Create;
begin
  inherited Create;
  FCount := 0;
  FLaneWidth := 0.5;
  FLaneCount := 16;
  FDefaultLane := FLaneCount - 3;
  FPathTotalLength := 0;
  FLastDT := 0;
  FNominalWidth := 8.0;
  SetLength(FWidthDist, 0);
  SetLength(FWidthVal, 0);
end;

function TLaneManager.CaptureReplay: TLaneReplayState;
var I: Integer;
begin
  Result:=nil;
  SetLength(Result,FCount);
  for I:=0 to FCount-1 do Result[I]:=FRiders[I];
end;

procedure TLaneManager.RestoreReplay(const Saved: TLaneReplayState);
var I: Integer;
begin
  for I:=0 to Min(FCount,Length(Saved))-1 do
    if FRiders[I].Active and Saved[I].Active and (FRiders[I].Tag=Saved[I].Tag) then
      FRiders[I]:=Saved[I];
end;

procedure TLaneManager.SetRoad(ARoadWidth, APathLength: Single);
begin
  FLaneWidth := 0.8;
  FLaneCount := Trunc(ARoadWidth / FLaneWidth);
  if FLaneCount < 4 then FLaneCount := 4;
  FDefaultLane := FLaneCount - 3;
  if FDefaultLane < 0 then FDefaultLane := 0;
  FPathTotalLength := APathLength;
  FNominalWidth := ARoadWidth;
  { Профиль сбрасываем — пока он не задан, шаг полос фиксированный. }
  SetLength(FWidthDist, 0);
  SetLength(FWidthVal, 0);
end;

procedure TLaneManager.SetWidthProfile(const ADist, AWidth: array of Single);
var
  I, N: Integer;
begin
  N := Length(ADist);
  if N > Length(AWidth) then N := Length(AWidth);
  if N < 2 then
  begin
    SetLength(FWidthDist, 0);
    SetLength(FWidthVal, 0);
    Exit;
  end;
  SetLength(FWidthDist, N);
  SetLength(FWidthVal, N);
  for I := 0 to N - 1 do
  begin
    FWidthDist[I] := ADist[I];
    FWidthVal[I]  := AWidth[I];
  end;
end;

{ Ширина дороги в точке ALoopPos (м). Бинарный поиск + интерполяция.
  Off-road (0) на одной стороне сегмента → берём ширину соседа (как
  TGamePath.RoadWidthAt), чтобы шаг полос не схлопывался на кромке. }
function TLaneManager.WidthAtLoop(ALoopPos: Single): Single;
var
  Lo, Hi, Mid: Integer;
  T, W0, W1, W: Single;
begin
  if Length(FWidthDist) < 2 then
  begin
    Result := FNominalWidth;
    Exit;
  end;
  if ALoopPos <= FWidthDist[0] then
    W := FWidthVal[0]
  else if ALoopPos >= FWidthDist[High(FWidthDist)] then
    W := FWidthVal[High(FWidthVal)]
  else
  begin
    Lo := 0; Hi := High(FWidthDist);
    while Hi - Lo > 1 do
    begin
      Mid := (Lo + Hi) div 2;
      if FWidthDist[Mid] <= ALoopPos then Lo := Mid else Hi := Mid;
    end;
    W0 := FWidthVal[Lo]; W1 := FWidthVal[Hi];
    if FWidthDist[Hi] > FWidthDist[Lo] then
      T := (ALoopPos - FWidthDist[Lo]) / (FWidthDist[Hi] - FWidthDist[Lo])
    else
      T := 0.0;
    if (W0 > 0.0) and (W1 > 0.0) then W := W0 + (W1 - W0) * T
    else if T < 0.5 then W := W0 else W := W1;
  end;
  { An explicit zero in a prepared profile means no lateral corridor.
    The nominal width applies only when there is no profile at all. }
  Result := Max(0.0,W);
end;

{ Virtual cyclist positions fit the local road, including the rider's width.
  The number of virtual positions is independent of OSM traffic lanes. }
function TLaneManager.OffsetForWidth(ALane, ARoadWidth: Single): Single;
const RIDER_EDGE_MARGIN = 0.4;
var W, HalfSlots, Step, Edge, Base: Single;
begin
  if FLaneCount < 2 then Exit(0);
  W := Max(0.0, ARoadWidth);
  HalfSlots := (FLaneCount - 1) * 0.5;
  Edge := Max(0.0,W*0.5-RIDER_EDGE_MARGIN);
  Step := Min(W / FLaneCount, Edge / HalfSlots);
  Base := (FDefaultLane-HalfSlots)*Step*LaneCenterFactor(W);
  { The usual line remains centered on narrow paths. Passing slots retain
    their physical spacing instead of collapsing all riders onto that line. }
  Result := EnsureRange(Base+(EnsureRange(ALane,0.0,FLaneCount-1.0)-FDefaultLane)*Step,-Edge,Edge);
end;

procedure TLaneManager.SetPathLength(APathLength: Single);
var I: Integer;
begin
  FPathTotalLength := Max(0, APathLength);
  for I := 0 to FCount - 1 do
  begin
    SetRiderPos(I, FRiders[I].LoopPos);
    FRiders[I].PrevLoopPos := FRiders[I].LoopPos;
  end;
end;

function TLaneManager.RegisterRider(ATag: Pointer): TLaneRiderHandle;
var I:Integer;
begin
  Result:=FindRider(ATag);if Result>=0 then Exit;
  Result:=FCount;
  for I:=0 to FCount-1 do if not FRiders[I].Active then begin Result:=I;Break end;
  if Result=FCount then begin
    if FCount>=Length(FRiders)then SetLength(FRiders,FCount+8);
    Inc(FCount);
  end;
  FRiders[Result]:=Default(TLaneRider);
  FRiders[Result].Active:=True;FRiders[Result].Lane:=FDefaultLane;
  FRiders[Result].SmoothLane:=FDefaultLane;FRiders[Result].Tag:=ATag;
  FRiders[Result].DriftTimer:=2.0+Random*6.0;
end;

procedure TLaneManager.ReplaceRiderTag(OldTag,NewTag:Pointer);
var I:Integer;
begin
  if OldTag=nil then Exit;
  for I:=0 to FCount-1 do if FRiders[I].Tag=OldTag then begin
    FRiders[I].Tag:=NewTag;
    if NewTag=nil then UnregisterRider(I);
  end;
end;

procedure TLaneManager.UnregisterRider(AHandle: TLaneRiderHandle);
begin
  if (AHandle >= 0) and (AHandle < FCount) then
  begin
    FRiders[AHandle].Active := False;
    FRiders[AHandle].Tag := nil;
    FRiders[AHandle].PoseValid := False;
    FRiders[AHandle].PassageKey := 0;
    FRiders[AHandle].PassageAge := 0;
  end;
end;

procedure TLaneManager.SetRiderPos(AHandle: TLaneRiderHandle; ALoopPos: Single);
begin
  if (AHandle < 0) or (AHandle >= FCount) then Exit;
  { Wrap to [0..PathTotalLength) }
  if FPathTotalLength > 0 then
  begin
    while ALoopPos >= FPathTotalLength do ALoopPos := ALoopPos - FPathTotalLength;
    while ALoopPos < 0 do ALoopPos := ALoopPos + FPathTotalLength;
  end;
  FRiders[AHandle].LoopPos := ALoopPos;
end;

procedure TLaneManager.SetRiderActive(AHandle: TLaneRiderHandle; AActive: Boolean);
begin
  if (AHandle >= 0) and (AHandle < FCount) then begin
    FRiders[AHandle].Active := AActive;
    if not AActive then begin FRiders[AHandle].PassageKey:=0;FRiders[AHandle].PassageAge:=0 end;
  end;
end;

function TLaneManager.GetLane(AHandle: TLaneRiderHandle): Integer;
begin
  if (AHandle >= 0) and (AHandle < FCount) then
    Result := FRiders[AHandle].Lane
  else
    Result := FDefaultLane;
end;

function TLaneManager.GetLaneOffset(ALane: Integer): Single;
begin
  Result := OffsetForWidth(ALane, FNominalWidth);
end;

function TLaneManager.GetSmoothOffset(AHandle: TLaneRiderHandle): Single;
begin
  if (AHandle>=0) and (AHandle<FCount) then
    Result:=GetSmoothOffset(AHandle,WidthAtLoop(FRiders[AHandle].LoopPos))
  else Result:=GetLaneOffset(FDefaultLane);
end;

function TLaneManager.GetSmoothOffset(AHandle: TLaneRiderHandle; ARoadWidth: Single): Single;
begin
  if (AHandle >= 0) and (AHandle < FCount) then
    Result := OffsetForWidth(FRiders[AHandle].SmoothLane, ARoadWidth)
  else
    Result := OffsetForWidth(FDefaultLane, ARoadWidth);
end;

{$I GameLaneManager.inc}

{ ======================== Shared ground placement ======================== }

function RaycastGroundY(AItems: TCastleAbstractRootTransform;
  X, Z, ALastY: Single; ASkip: TCastleTransform): Single;
var
  RayOriginY: Single;
  RayResult: TRayCastResult;
  Attempts: Integer;
begin
  Result := ALastY;
  if not Assigned(AItems) then Exit;

  RayOriginY := ALastY + 10;
  Attempts := 0;
  while Attempts < 3 do
  begin
    Inc(Attempts);
    RayResult := AItems.PhysicsRayCast(
      Vector3(X, RayOriginY, Z), Vector3(0, -1, 0), 30);
    if not RayResult.Hit then Exit;

    { Skip own transform }
    if Assigned(ASkip) and (RayResult.Transform = ASkip) then
    begin
      RayOriginY := RayOriginY - RayResult.Distance - 0.05;
      Continue;
    end;

    Result := RayOriginY - RayResult.Distance;
    Exit;
  end;
end;

procedure PlaceOnGroundSmooth(AItems: TCastleAbstractRootTransform;
  ATransform: TCastleTransform; const TargetPos: TVector3;
  var GState: TGroundPlacementState; const DeltaTime: Single;
  ASkip: TCastleTransform);
var
  GroundY, SmoothAlpha: Single;
begin
  if not Assigned(ATransform) then Exit;

  GroundY := RaycastGroundY(AItems, TargetPos.X, TargetPos.Z,
    GState.LastY, ASkip);

  if not GState.Valid then
  begin
    GState.SmoothedY := GroundY;
    GState.Valid := True;
  end
  else
  begin
    SmoothAlpha := 1.0 - Exp(-DeltaTime / GroundSmoothTime);
    GState.SmoothedY := GState.SmoothedY +
      (GroundY - GState.SmoothedY) * SmoothAlpha;
  end;
  GState.LastY := GState.SmoothedY;

  ATransform.Translation := Vector3(
    TargetPos.X, GState.SmoothedY, TargetPos.Z);
end;

end.
