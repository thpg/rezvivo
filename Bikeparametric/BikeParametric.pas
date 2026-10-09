{
  Parametric Bicycle Generator for Castle Game Engine (CGE).

  Component-based architecture:
    TBikeSkeleton      — named 3D joints computed by components
    TBikeBuildContext   — shared rendering helpers (MakeCylinder, MakeSphere, etc.)
    TBikeComponent     — abstract base for pluggable bike parts
    TBikeBuilder       — assembles components into X3D scene graph

  Each component validates its own parameters in ComputeBones / BuildGeometry,
  applying sensible defaults when values are zero or missing.

  Usage:
    Builder := TBikeBuilder.Create(RoadBikeComponents);
    Builder.Preset := 'road'; Builder.DetailLevel := 3;
    Root := Builder.Build;

  License: MIT
}
unit BikeParametric;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, TypInfo, CastleUtils,
  CastleVectors, CastleColors, CastleShaders,
  CastleScene, CastleTransform,
  X3DNodes, X3DFields, Generics.Collections,
  fpjson,
  RiderMotion, RiderDynamics, RiderAttention, RiderHandGrip, AvatarGait,
  RiderTripo, RiderBodyParameters, RiderCorrectiveData, GltfCore,   { authored Tripo rig + CGE native skinning (TTripoRiderScene) }
  BikeGpuSkin,  { GPU-скин райдера: процедурная поза в вершинном шейдере (этап 2) }
  BikeGpuSpin;  { GPU-вращение колёс/шатунов/педалей в шейдере (этап 4) }

{ ═══════════════════════════════════════════════════════════════════
  PARAMETERS
  ═══════════════════════════════════════════════════════════════════ }

type
  TBarType = (btDrop, btFlat);

  { TBikeParams is gone. Its last three fields moved out:
    - Preset and DetailLevel live on TBikeBuilder / TBikeInstance (the
      only readers are PrepareBuildComps / ApplyPreset for Preset, and
      the per-component BuildGeometry for DetailLevel — both now read
      them from the builder directly).
    - SuspensionType was never read by any geometry code; derived from
      the component list where needed. }


{ ═══════════════════════════════════════════════════════════════════
  SKELETON
  ═══════════════════════════════════════════════════════════════════ }

type
  TBikeBone = record
    Name: string;
    Pos: TVector3;
  end;

  TBikeSkeleton = class
  public const
    { MM: millimetres → metres scale. Was a runtime field driven by
      TBikeParams; it never changed from 0.001, so it is now a constant
      read at call sites that previously wrote `Skel.MM`. }
    MM: Single = 0.001;
  private
    FBones: array of TBikeBone;
    FHTDirX, FHTDirY: Single;
    FSeatAngleRad: Single;
    FHeadAngleRad: Single;
    function FindIndex(const AName: string): Integer;
  public
    constructor Create;
    procedure AddBone(const AName: string; const APos: TVector3);
    function GetBone(const AName: string): TVector3;
    { один FindIndex вместо пары HasBone+GetBone (горячий покадровый путь) }
    function TryGetBone(const AName: string; out APos: TVector3): Boolean;
    function HasBone(const AName: string): Boolean;
    function BoneCount: Integer;
    function GetBoneByIndex(AIndex: Integer): TBikeBone;
    property Bone[const AName: string]: TVector3 read GetBone; default;
    property SeatAngleRad: Single read FSeatAngleRad write FSeatAngleRad;
    property HeadAngleRad: Single read FHeadAngleRad write FHeadAngleRad;
    property HTDirX: Single read FHTDirX write FHTDirX;
    property HTDirY: Single read FHTDirY write FHTDirY;
  end;

{ ═══════════════════════════════════════════════════════════════════
  BUILD CONTEXT
  ═══════════════════════════════════════════════════════════════════ }

type
  TBikeColors = record
    Frame, FrameSpec, Chrome, ChromeSpec, Dark, Tire, Seat, Tape, Spoke: TVector3;
    Rim, RimSpec, TireSpec: TVector3;
  end;

  { ── батчинг мелких примитивов (BeginAccum/EndAccum) ─────────────────────
    Между BeginAccum(AParent) и EndAccum MakeX не создают TShapeNode на
    примитив, а дописывают треугольники (с запечённым TRS примитива) в
    аккумуляторы по ключу (материал, creaseAngle). EndAccum создаёт по
    одному TShapeNode на ключ и вешает в AParent. Вне BeginAccum — старое
    поведение (полная совместимость). Именованные/анимированные трансформы
    (RearWheelRot, CranksRot, Pedal*Rot/Foot) остаются нетронутыми —
    батчится только геометрия ВНУТРИ них. }
  TMeshAccumKey = record
    Color, Spec: TVector3;
    Shininess, Crease: Single;
    TexNode: TAbstractTexture2DNode;   { nil = нетекстурный бакет }
  end;

  TMeshAccum = class
    Key: TMeshAccumKey;
    Points: TVector3List;
    TexPoints: TVector2List;   { заполняется только у текстурных бакетов }
    Indices: array of LongInt;
    IdxLen: Integer;
    constructor Create(const AKey: TMeshAccumKey);
    destructor Destroy; override;
    procedure AddIdx(V: LongInt);
  end;

  TAccumSession = class
    Parent: TTransformNode;
    Items: array of TMeshAccum;
    function FindOrAdd(const AKey: TMeshAccumKey): TMeshAccum;
    destructor Destroy; override;
  end;

  TBikeBuildContext = class
  private
    FSkeleton: TBikeSkeleton;
    FColors: TBikeColors;
    FRoot: TTransformNode;
    FSteerRoot: TTransformNode;   { SteerRot when steer enabled }
    FSceneRoot: TX3DRootNode;
    FCenterX: Single;
    FSessions: array of TAccumSession;
    function CurrentSession: TAccumSession;
    function GetDetailLevel: Integer;
  public
    { Set by TBikeBuilder.Build right after construction — gives components
      access to runtime flags (ShowSkeleton) and Preset /
      DetailLevel that live on the Builder.
      Untyped to dodge forward-decl pain; components cast to TBikeBuilder
      at the call site. }
    Builder: TObject;
    constructor Create(ASkel: TBikeSkeleton;
      const AColors: TBikeColors; ARoot: TTransformNode;
      ASceneRoot: TX3DRootNode; ACenterX: Single);
    function O(const P: TVector3): TVector3;
    procedure Add(ANode: TTransformNode);
    { Parent for steered assembly (fork/bars/front wheel).
      BikeDebugDisableSteer: no SteerRot — AddSteered = Add (Vatokat layout). }
    function SteerRoot: TTransformNode;
    procedure AddSteered(ANode: TTransformNode);
    { Nil-safe add to an arbitrary parent: in accum mode the Make*/custom
      builders return nil (the geometry went into the batch), and
      AddChildren(nil) raises EX3DError. }
    procedure AddTo(AParent, ANode: TTransformNode);
    { ── батчинг: см. комментарий у TMeshAccumKey выше ── }
    function AccumActive: Boolean;
    procedure BeginAccum(AParent: TTransformNode);
    procedure EndAccum;
    { Запечь готовую IFS-геометрию (ещё не привязанную к Shape) в батч с
      матрицей M; Geometry+Coord освобождаются после копирования.
      Для кастомных построителей (MakeRimRing и т.п.). }
    procedure EmitBatched(Geometry: TIndexedFaceSetNode;
      Coord: TCoordinateNode; const Color, Spec: TVector3;
      Shininess, Crease: Single; const M: TMatrix4);
    { То же с текстурой и UV: Geometry+Coord+TexCoord освобождаются после
      копирования, TexNode НЕ освобождается (уходит в итоговый Appearance). }
    procedure EmitBatchedTex(Geometry: TIndexedFaceSetNode;
      Coord: TCoordinateNode; TexCoord: TTextureCoordinateNode;
      TexNode: TAbstractTexture2DNode;
      const Color, Spec: TVector3; Shininess, Crease: Single; const M: TMatrix4);
    function MakeCylinder(const P1, P2: TVector3; Radius: Single;
      const Color, Spec: TVector3; Shininess: Single;
      TopRadius: Single = -1): TTransformNode;
    function MakeBox(const Center: TVector3; SX, SY, SZ: Single;
      const Color, Spec: TVector3; Shininess: Single): TTransformNode;
    function MakeSphere(const Center: TVector3; Radius: Single;
      const Color, Spec: TVector3; Shininess: Single): TTransformNode;
    function MakeTorus(const Center: TVector3; MajorR, MinorR: Single;
      const Color, Spec: TVector3; Shininess: Single;
      Segments: Integer = -1; TubeSegments: Integer = -1): TTransformNode;
    function MakeMaterial(const Color, Spec: TVector3;
      Shininess: Single): TAppearanceNode;

    { ── LOD helpers — return segment counts based on DetailLevel ── }
    { 0=Low, 1=Medium, 2=High, 3=Ultra }
    function LOD_TorusSeg: Integer;      { circumferential: 12/20/32/48 }
    function LOD_TorusTubeSeg: Integer;  { tube cross-section: 6/8/12/16 }
    function LOD_RimSeg: Integer;        { rim ring circ segs: 12/20/32/48 }
    function LOD_SpokeDivisor: Integer;  { spoke count /= divisor: 4/2/1/1 }
    function LOD_CylSlices: Integer;     { cylinder lateral slices: 6/10/16/24 }
    function LOD_SphSlices: Integer;     { sphere lat/lon slices: 6/10/16/24 }

    { Flat oriented quad between two points with given half-width }
    function MakeQuad(const P1, P2: TVector3; HalfW: Single;
      const Color, Spec: TVector3; Shininess: Single): TTransformNode;

    property Skeleton: TBikeSkeleton read FSkeleton;
    { DetailLevel: 0..3, read from Builder. Replaces the old
      Ctx.Params.DetailLevel chain — components read Ctx.DetailLevel. }
    property DetailLevel: Integer read GetDetailLevel;
    property Colors: TBikeColors read FColors;
    property Root: TTransformNode read FRoot;
    property SceneRoot: TX3DRootNode read FSceneRoot;
    property CenterX: Single read FCenterX;
  end;

{ ═══════════════════════════════════════════════════════════════════
  COMPONENT BASE
  ═══════════════════════════════════════════════════════════════════ }

type
  { Forward decl so TBikeComponentClass can be declared before
    TBikeComponent's body references it. }
  TBikeComponent = class;
  TBikeComponentClass = class of TBikeComponent;
  TBikeComponentClassArray = array of TBikeComponentClass;

  TBikeComponent = class(TPersistent)
  private
    FBuilder: TObject;  { TBikeBuilder — untyped to avoid forward-decl pain }
  public
    { Virtual so that metaclass instantiation
      (FComponentClasses[I].Create in TBikeBuilder / TBikeInstance) dispatches
      to the derived constructor. Without virtual, metaclass Create calls
      TObject.Create and every field comes out zero — derived Create was
      effectively dead code, and serializing a fresh Builder produced
      all-zero JSON. }
    constructor Create; virtual;
    class function ComponentName: string; virtual; abstract;
    procedure ComputeBones(Skel: TBikeSkeleton); virtual;
    procedure BuildGeometry(Ctx: TBikeBuildContext); virtual; abstract;
    { Lifecycle hooks called by TBikeInstance around (re)builds. Default: no-op.
      SubIdx = BSG_FRAME / BSG_WHEELS / BSG_CRANK / BSG_RIDER for partial
      rebuilds, or -1 for a full build of the whole bike. Animating
      components use these to invalidate / activate their per-frame cache. }
    procedure OnBuildBegin(SubIdx: Integer); virtual;
    procedure OnBuildComplete(SubIdx: Integer); virtual;
    { Per-frame tick, dispatched by TBikeInstance.AnimateFrame. Default:
      no-op. Animating components (e.g. the rider) override. }
    procedure AnimateFrame(ElapsedSec: Double); virtual;

    { Apply preset-specific overrides (e.g. MTB wheels for a TWheelComponent).
      Called by TBikeBuilder.ApplyPreset after EnsureComponents. Default: no-op. }
    procedure ApplyPreset(const APreset: string); virtual;

    { Serialize own params into the shared params JSON object. Default: no-op.
      Components that own fields override and add them to Obj. }
    procedure ParamsToJSON(Obj: TJSONObject); virtual;
    { Deserialize own params from the shared params JSON object. Default: no-op.
      Should tolerate missing fields. }
    procedure ParamsFromJSON(Obj: TJSONObject); virtual;

    { Peer-component lookup. Returns nil if the builder isn't set or the
      requested class isn't in the component list. }
    function FindComponent(AClass: TBikeComponentClass): TBikeComponent;
    procedure SetBuilder(ABuilder: TObject);
    property Builder: TObject read FBuilder;
  end;

{ ═══════════════════════════════════════════════════════════════════
  BUILDER
  ═══════════════════════════════════════════════════════════════════ }

type
  TBikeBuilder = class
  private
    FSkeleton: TBikeSkeleton;
    FColors: TBikeColors;
    FComponentClasses: TBikeComponentClassArray;
    FComponents: array of TBikeComponent;
    FDisabledNames: TStringList;
    FComponentPolyCounts: array of Integer;
    FOwnsComponents: Boolean;
    function GetComponentCount: Integer;
    function GetComponent(Index: Integer): TBikeComponent;
    function GetPolyCount(Index: Integer): Integer;
    { Общая инициализация обоих конструкторов (дефолты + DisabledNames). }
    procedure InitDefaults;
  public
    { ── Top-level rendering parameters (was TBikeParams). Preset is
      serialized into JSON "params.Preset"; DetailLevel is runtime. ── }
    Preset: string;             { 'road' / 'gravel' / 'mtb' / library model name }
    DetailLevel: Integer;       { 0=Low, 1=Medium, 2=High, 3=Ultra }

    { ── Runtime-only flags (not serialized). Moved from TBikeParams. ── }
    ShowSkeleton: Boolean;      { True = draw skeleton as cylinders, hide skin }
    LogGeometry: Boolean;       { True = write rider_bones log on each build }
    { True (default) = Build prepends the standalone-viewer environment
      (Background/NavigationInfo/3 lights/Viewpoint) to the returned root.
      TBikeInstance clears it: it adds the environment once to FMainRoot in
      the constructor, so per-sub / per-LOD builds don't pile up copies. }
    IncludeEnvironment: Boolean;

    property Skeleton: TBikeSkeleton read FSkeleton;
    property Colors: TBikeColors read FColors write FColors;
    property ComponentCount: Integer read GetComponentCount;
    property Components[Index: Integer]: TBikeComponent read GetComponent;
    property ComponentPolyCounts[Index: Integer]: Integer read GetPolyCount;
    property DisabledNames: TStringList read FDisabledNames;
    { Builder creates its own components and frees them on destroy.
      Used for one-shot builds (JSON serialization etc.). }
    constructor Create(const AComponentClasses: array of TBikeComponentClass);
    { Builder uses externally-owned persistent components. Does NOT free
      them on destroy. Used by TBikeInstance so component state (animation
      cache, shader uniform refs etc.) survives across rebuilds. }
    constructor CreateBorrowing(const AComponents: array of TBikeComponent);
    destructor Destroy; override;
    function Build: TX3DRootNode;
    { Look up a component by class, or nil if not in the list. }
    function FindComponent(AClass: TBikeComponentClass): TBikeComponent;
    { Derived bar-type view: btFlat if a FlatBar component is in the list,
      otherwise btDrop. Mirrors TBikeInstance.BarType. }
    function BarType: TBarType;
  end;

{ ═══════════════════════════════════════════════════════════════════
  BIKE INSTANCE — multi-scene LOD model
  ═══════════════════════════════════════════════════════════════════ }

const
  BSG_FRAME  = 0;
  BSG_WHEELS = 1;
  BSG_CRANK  = 2;
  BSG_RIDER  = 3;
  BSG_COUNT  = 4;

type
  TBikeInstance = class;

  { How the bike casts its ground shadow:
      bsmNone     — no shadow at all;
      bsmCapsules — the analytic capsule shadow on the unlit quad (soft,
                    contact-hardened, ~60 uniforms per frame; default);
      bsmCGE      — hand the job to the engine: a per-instance directional
                    sun light (CastGlobalLights) with Shadows := True, the
                    bike scenes as casters, the REAL ground as receiver.
                    Pixel-exact silhouette (spokes, skinned rider) at the
                    engine's price and constraints: the light contributes to
                    world lighting (its Intensity = ShadowStrength), edge
                    softness/quality is whatever the engine's shadow
                    implementation provides, and casters must satisfy its
                    geometry requirements. The host may want to set
                    CastShadows := False on large world scenes (map tiles)
                    so they stay out of the bike's shadow pass. }
  TBikeShadowMode = (bsmNone, bsmCapsules, bsmCGE);

  TSubSceneBuiltEvent = procedure(Sender: TBikeInstance; SubIdx: Integer;
    ABuilder: TBikeBuilder) of object;

  { One bike = TCastleTransform + 4 sub-scenes (Frame, Wheels, Crank, Rider).
    Supports single-LOD and automatic X3D LODNode-based multi-LOD builds. }
  {$M+}  { generate RTTI for the published section of this plain class }
  TBikePlaybackState = record
    Attention: TRiderAttentionFrame;
    BodyDynamics: TRiderDynamicsState;
    BodyDynamicsInput: TRiderDynamicsInput;
    BodyDynamicsEnabled, BodyDynamicsSituation: Boolean;
    SteerAngleDeg, PedalSteerDeg, PedalLeanDeg: Single;
    Pose: TRiderPose;
    Rider: TRiderPoseReplay;
    AnimElapsed: Double;
    TripoPrevElapsed: Double;
    Phase: Single;
    WheelPhase: Single;
    AccumTime: Double;
    PhasePrevElapsed: Double;
    PhaseStarted: Boolean;
    PhaseSynced: Boolean;
    RiderEffort, RiderEffortTarget, MotionCadence: Single;
    PedalRate: Single;
    BreathPhase: Double;
    BreathLoad: Single;
    CrankIntervalCur: Single;
    WheelIntervalCur: Single;
    ForwardSpeedMps: Single;
    HandFromR: Integer;
    HandFromL: Integer;
    HandFromFreeRPos: TVector3;
    HandFromFreeLPos: TVector3;
    HandFromFreeRWave: Single;
    HandFromFreeLWave: Single;
    HandAnchorR, HandAnchorL: TVector3;
    HandAnchorFrameR,HandAnchorFrameL,FrameHandR,FrameHandL:TRiderGripFrame;
    HandAnchorRValid, HandAnchorLValid: Boolean;
    HandAnimElapsed: Single;
    HandAnimDur: Single;
    HandAnimating: Boolean;
    HandSlotR0: Single;
    HandSlotR1: Single;
    HandSlotL0: Single;
    HandSlotL1: Single;
  end;

  TBikeInstance = class
  private
    FOnFoot, FOnFootSavedGpu: Boolean;
    FOnFootPhase: Single;
    FOnFootDynamics: TGaitDynamicsState;
    FOnFootFrame: TGaitFrame;
    FOwner: TComponent;
    FGroup: TCastleTransform;
    { ЕДИНАЯ сцена байка: весь байк (рама/колёса/шатун/райдер) + райдер GLB +
      теневой rig живут в одном графе — требование shadow maps CGE
      (per-scene casters/receivers). FSubGroup[i] — именованные подграфы
      частей внутри FMainRoot. SubScene(i) сохраняет совместимость
      редакторов компонентов и возвращает эту же единую сцену. }
    FBikeScene: TCastleScene;
    FMainRoot: TX3DRootNode;
    FSubGroup: array[0..BSG_COUNT-1] of TTransformNode;
    { Граф Tripo-райдера (GLB) — ОТДЕЛЬНО от FSubGroup: параметрические
      ребилды делают FSubGroup[i].ClearChildren (убивают граф и joint-
      ссылки rig'а), а этот узел чистится только при смене райдера.
      FTripoSwitch — видимость райдера (аналог бывшего Scene.Exists).
      После переворота сцены (MountBikeIntoRider) оба живут в старом
      boot-корне и не используются — оставлены для совместимости. }
    FTripoSwitch: TSwitchNode;
    FTripoGroup: TTransformNode;
    { ПЕРЕВОРОТ единой сцены: рендерится СЦЕНА РАЙДЕРА, байк-части
      (FSubGroup[i], теневой rig) смонтированы в неё через FBikeContainer,
      чья матрица = P^-1 (P — scene-level трансформ райдера, пишется в
      UpdateTripoRider). Так кости трипо живут в родной сцене с внешним
      трансформом — joint-матрицы скиннинга не видят P, двойного применения
      нет (байк — ручная геометрия, её мы компенсируем сами).
      FVisSwitch — видимость райдера в его сцене (обёртка glb-контента). }
    FBikeContainer: TMatrixTransformNode;
    FVisSwitch: TSwitchNode;
    FOnSubSceneBuilt: TSubSceneBuiltEvent;
    FBaseCrankCycle: Single;  { CrankCycleInterval used at build time }
    FBaseWheelCycle: Single;  { период оборота колеса с билда (с/об); TimeSensor'ов нет — действует как дефолт для GPU-фазы }
    { Persistent component instances. Created lazily to match the
      requested class list, reused across rebuilds so animation state on
      each component (shader uniform refs, per-frame caches) survives. }
    FComponents: array of TBikeComponent;
    { Captured from the most recent Build / BuildWithLOD / RebuildSub so
      AnimateFrame can reproduce the call without the caller re-passing
      them. FDisabled is a reference; caller guarantees its lifetime. }
    FColors: TBikeColors;
    FDisabled: TStringList;       { not owned }
    FLastCompClasses: TBikeComponentClassArray;
    { Per-frame time accumulated for AnimateFrame. }
    FAnimElapsed: Double;
    FTripoPrevElapsed: Double;    { last ElapsedSec, to derive a per-frame dt for pose anim }
    { ── GPU-анимация (GPU_ANIM_DESIGN.md, этап 1): CPU-накопители фазы.
      FPhase — шатуны+ноги (0..1 оборота кривошипа), FWheelPhase — колёса,
      FAccumTime — монотонное время (будущий uniform uAccumTime для
      GPU-лерпа поз). Интервалы < 0 = не заданы явно (действуют
      FBaseCrankCycle/FBaseWheelCycle с билда), <= 0.01 = стоп. ── }
    FPhase: Single;
    FWheelPhase: Single;
    FAccumTime: Double;
    FBaseRiderPose: TRiderPose;
    FFrameContacts: array[0..3] of TVector3;
    FFrameContactsValid: Boolean;
    FFrameHandR,FFrameHandL,FHandAnchorFrameR,FHandAnchorFrameL:TRiderGripFrame;
    FRiderEffort, FRiderEffortTarget, FMotionCadence: Single;
    FBodyDynamics: TRiderDynamicsState;
    FBodyDynamicsInput: TRiderDynamicsInput;
    FAttention: TRiderAttentionFrame;
    FBodyDynamicsEnabled, FBodyDynamicsSituation: Boolean;
    procedure SetBodyDynamicsEnabled(Value:Boolean);
    function BodyDynamicsDebugJson:TJSONObject;
  private
    FRiderCrankPhase: Single; { physical right crank angle; derived, not replay state }
    FPedalRate: Single; { actual crank revolutions/s, gated by foot contact }
    FBreathPhase: Double;
    FBreathLoad: Single;
    FPhasePrevElapsed: Double;    { last ElapsedSec для dt накопителя фазы }
    FPhaseStarted: Boolean;       { первый AnimateFrame только берёт отметку времени }
    FPhaseSynced: Boolean;        { одноразовая синхронизация FPhase с CrankTimer }
    FCrankIntervalCur: Single;    { период оборота шатунов, с (SetAnimationSpeed) }
    FWheelIntervalCur: Single;    { период оборота колеса, с (SetWheelSpeedMps) }
    FForwardSpeedMps: Single;
    FGpuAnim: Boolean;            { True = анимация на GPU (этапы 2-5); False = старый CPU-путь }
    FAnimationEnabled, FResumeGpuAnim: Boolean;
    FResumeSkinShaders: Boolean;
    FResumeBikeTimeSpeed, FResumeRiderTimeSpeed: Single;
    FGpuSkin: TGpuRiderSkin;      { GPU-скин райдера (этап 2); nil = ещё не построен }
    FGpuSkinPrimed: Boolean;      { этап 5: разовый posed-проход сделан — skin-чанк движка включён в программу }
    FSteerAngleDeg: Single;
    FPedalSteerDeg: Single;
    FPedalLeanDeg: Single;
    FSteerAngleApplied: Single;
    FPedalLeanApplied: Single;
    FRearTrackApplied: Single;
    FSteerNodesValid: Boolean;
    FBuildDepth: Integer;
    FSteerRots: TList;
    FSteerAxis: TVector3;
    FSteerPivot: TVector3;
    FSteerAxisCached: Boolean;
    FGpuSpin: TGpuBikeSpin;       { GPU-вращение колёс/шатунов/педалей (этап 4); nil = не построен }
    { CPU-путь (GpuAnim=False): кэш именованных spin-трансформов — раньше их
      крутили TimeSensor/ROUTE, теперь пишет DriveSpinNodesCPU из FPhase.
      Списки: LOD-билд дублирует поддеревья, гоняем ВСЕ копии. }
    FSpinNodesValid: Boolean;
    FSpinCranks, FSpinPedalR, FSpinPedalL, FSpinWheelR, FSpinWheelF: TList;
    { ── Tripo rider: authored glb rig, GPU-skinned by CGE. ──
      FBikeSkeleton is a retained copy of the build skeleton (anchors), so
      AnimateFrame can read pedal/grip/saddle positions without a builder. }
    FTripoRider: TTripoRiderScene;
    { ── cloth dye preset: цвета одежды райдера как свойство байк-инстанса.
      Стейджатся в КАЖДОГО загружаемого райдера до запечки текстуры
      (live-запечка на живой GL-сцене глушит рендер CGE — только загрузка). ── }
    FDyePresetMode: TClothDyeMode;
    FDyePresetColor: array[TClothSlot] of TVector3;
    FDyePresetActive: array[TClothSlot] of Boolean;
    { live-перекраска рамы/ободьев: старый->новый цвет для матчей материалов }
    FRecolorOld, FRecolorNew: TVector3;
    FBikeSkeleton: TBikeSkeleton;
    FTripoRiderScale: Single;     { calibrate: rider size in bike units }
    FTripoFitScale: Single;       { cached rig→bike fit; computed once per loaded rig, 0 = recompute }
    FTripoRiderYawDeg: Single;    { calibrate: facing, degrees about +Y }
    FTripoRiderOffset: TVector3;  { calibrate: fine offset of rig origin vs saddle }
    FTripoTorsoLeanDeg: Single;   { forward torso lean (deg); pushed to the rider }
    FTripoPedalDir: Single;       { +1 / -1 pedalling direction }
    FTripoSpineCurve: Single;     { upper-spine curl bias }
    FTripoSpineManual: Boolean;   { manual per-joint spine angles }
    FTripoSpineAngles: array[0..4] of Single;
    FTripoKneeFlare: Single;      { knees out(+)/in(-) }
    FTripoElbowFlare: Single;     { elbows out(+)/in(-) }
    FTripoAnkleFlex: Single;      { foot pitch (toe down +/up -) }
    FTripoArmPronationR, FTripoArmPronationL: Single;   { hand roll, per side }
    FTripoShoulderRound: Single;  { clavicles fwd/together }
    FTripoHandLevel: Single;      { wrist leveling 0..1: 1 = hand parallel to the ground }
    FTripoAnkleOffset: TVector3;  { foot target offset (ball-of-foot on pedal) }
    FTripoStanceHalf: Single;     { optional stance override, mm/side; 0 follows crank + pedal centre }
    FTripoFootYawDeg: Single;     { mirrored foot yaw correction: positive = toes out }
    FTripoHandPosR: Integer;      { which bar grip the right hand uses (1-based) }
    FTripoHandPosL: Integer;      { which bar grip the left hand uses (1-based); 0 = free }
    FTripoHandFreeRPos, FTripoHandFreeLPos: TVector3;  { free hand target when HandPos=0 }
    FTripoHandFreeRWave, FTripoHandFreeLWave: Single;  { free-hand wave amplitude }
    FTripoLegFreeR, FTripoLegFreeL: Single;        { 0 = on pedal, 1 = free static foot }
    FTripoLegFreeRPos, FTripoLegFreeLPos: TVector3;{ free foot target, bike frame }
    FHandFromR, FHandFromL: Integer;   { grip the hand is moving FROM during a transition }
    FHandFromFreeRPos, FHandFromFreeLPos: TVector3;  { free point the hand is moving FROM (idx 0) }
    FHandFromFreeRWave, FHandFromFreeLWave: Single;
    FHandAnchorR, FHandAnchorL: TVector3; { current contact when a transfer is interrupted }
    FHandAnchorRValid, FHandAnchorLValid: Boolean;
    FHandAnimElapsed, FHandAnimDur: Single;
    FHandAnimating: Boolean;
    FHandSlotR0, FHandSlotR1: Single;  { right-hand move time-window (fraction of dur) }
    FHandSlotL0, FHandSlotL1: Single;  { left-hand move time-window — staggered after R }
    FTripoPedalSway: Single;      { lateral body sway amplitude (bike units) }
    FTripoTorsoBobAmp: Single;    { vertical body bob amplitude (bike units) }
    FTripoShowRider: Boolean;     { rider visibility }
    FBodyParameters: TRiderBodyParameters;
    FBodyParametersSet:Boolean;
    FTripoBulk: Single;           { body-shape: overall girth }
    FTripoBelly: Single;          { body-shape: belly bulge }
    FTripoBodyHeight: Single;     { body-shape: overall height scale }
    { skeleton proportion coefficients: DIRECT scale, 1.0 = unchanged.
      0 (unset/default) is also treated as 1.0 inside ApplyLimbLengths. }
    FTripoLegLen: Single;         { skeleton: leg length coefficient }
    FTripoArmLen: Single;         { skeleton: arm length coefficient }
    FTripoShoulderWidth: Single;  { skeleton: clavicle length = shoulder width coefficient }
    FTripoPelvisWidth: Single;    { skeleton: pelvis->hip offsets = pelvis width coefficient }
    FTripoTorsoLen: Single;       { skeleton: spine-chain length = torso length coefficient }
    FTripoInseamUpper: Single;    { torso extra so inseam change keeps standing height }
    FTripoRoughness: Single;      { PBR gloss correction: roughness multiplier, 1 = as authored,
                                    <1 = glossier, >1 = more matte (0 also = 1) }
    FTripoMetallic: Single;       { PBR gloss correction: metallic multiplier, 1 = as authored,
                                    <1 = more dielectric (no metal sheen), >1 = more metallic (0 also = 1) }
    FHelmetColor: string;    { headwear tint as 'RRGGBB' hex; '' / '0' = authored }
    FHelmetPitchX: Single;   { extra helmet nod, deg; + = visor down / forward }
    FHelmetPitchFromJson: Boolean; { True = bike JSON overrides authored extras }
    FTripoRiderPath: string;      { last-loaded rider glb (for JSON save/load) }
    FTripoRiderError: string;     { reason the last LoadTripoRider failed }
    { ── debug: 5 cm contact-marker spheres, built lazily, parented under FGroup.
      Index 0,1 = pedal axles R/L; 2,3 = hand grips R/L; 4 = saddle; 5 = rider seat;
      6,7 = posed shoe cleats R/L (BoatClipse*); 8,9 = posed palms R/L (ArmContact*),
      both pairs = where the IK actually lands the markers. }
    FContactDbgScene: TCastleScene;
    FContactDbgXf: array[0..9] of TTransformNode;
    { ── ground contact shadow: a soft analytic capsule shadow, rendered by a
      fragment shader on an unlit quad at wheel-contact height. The capsule
      set = static bike tubes/wheels (rebaked by every build via
      CaptureSkeleton -> RebuildShadowStatic) + per-frame rider bones and
      crank arms (UpdateShadowDynamic, called from UpdateTripoRider AFTER the
      pose is solved, so the shadow follows pedalling / lean / hand moves in
      lockstep with the skinned mesh). No textures, no extra render passes:
      the per-frame cost is rewriting ~20 vec3 uniforms. ── }
    FShadowScene: TCastleScene;          { owns the quad; child of FGroup }
    FMapDbgScene: TCastleScene;          { ДИАГ: quad с содержимым теневой карты }
    FShadowCoord: TCoordinateNode;       { the 4 quad corners, resized per build }
    FShadowCapA, FShadowCapB: TMFVec3f;  { capsule endpoints, uniform arrays }
    FShadowCapRA, FShadowCapRB: TMFFloat;{ capsule radius at each end (tapered) }
    FShadowCapN: TSFInt32;               { number of capsules in use }
    FShadowGroundU: TSFFloat;            { ground plane Y (quad height) }
    FShadowStrengthU: TSFFloat;          { peak shadow opacity }
    FShadowSunU: TSFVec3f;               { light travel direction (world, Y < 0) }
    FShadowSoftU: TSFFloat;              { penumbra growth per metre of height }
    FShadowHardU: TSFFloat;              { >0.5 = crisp silhouettes (diagnostic) }
    FShadowGroundNU: TSFVec3f;           { ground-plane normal in bike frame }
    FShadowStatA, FShadowStatB: array of TVector3;  { baked static bike capsules }
    FShadowStatRA, FShadowStatRB: array of Single;
    FShadowSendA, FShadowSendB: array of TVector3;  { reusable per-frame Send buffers,
                                                      always SHADOW_MAX_CAPS long }
    FShadowSendRA, FShadowSendRB: array of Single;
    FShadowGroundY: Single;
    FShowShadow: Boolean;
    FEngineShadowVolumes: Boolean;   { bsmCGE: разрешить shadow-volume проход (диагностика цены прохода) }
    FShadowStrength: Single;
    FShadowMode: TBikeShadowMode;        { capsules / engine shadows / none }
    FShadowMapLight: TDirectionalLightNode;  { bsmCGE: the shadow-casting sun }
    FShadowRigNode: TTransformNode;          { bsmCGE: sun + catcher в rig-сцене }
    FShadowRigScene: TCastleScene;           { bsmCGE: отдельная сцена rig'а (ReceiveGlobalLights=False) }
    FShadowRigRoot: TX3DRootNode;            { bsmCGE: корень rig-сцены }
    FShadowCatchCoord: TCoordinateNode;      { bsmCGE: catcher quad corners, sized per build }
    FShadowCatchMat: TMaterialNode;        { bsmCGE: catcher material (lit white, alpha from shader) }
    FShadowCatchApp: TAppearanceNode;      { bsmCGE: catcher appearance (диаг текстуры) }
    FShadowCatchGain: Single;            { bsmCGE: luminance->alpha gain of the catcher shader }
    FShadowCatchStrengthU: TSFFloat;     { bsmCGE: shStrength uniform of the catcher effect }
    FShadowCatchGainU: TSFFloat;         { bsmCGE: shGain uniform of the catcher effect }
    FGroundShadowReceiver: Boolean;  { persistent across lazy catcher creation }
    FShadowCatchShapeNode: TShapeNode;   { bsmCGE: catcher shape node (диаг: поиск TShape) }
    { TEMP-DIAG: EMA-замеры этапов AnimateFrame/UpdateTripoRider, мс/кадр }
    FDiagComps, FDiagUtrd: Double;
    FDiagPoseApply, FDiagIK, FDiagPedals, FDiagContacts, FDiagShadowDyn: Double;
    FDiagGpuSend: Double;   { время SendFrame в GPU-скин и GPU-spin (рассылка uniform-ов) }
    { OPT (pose-7ms): кэш узлов педалей — FindNode по имени каждый кадр
      стоил ~0.65 мс/байк. Инвалидируется из NotifyBuildBegin/MountBikeIntoRider. }
    FPedFootR, FPedFootL: TTransformNode;
    FPedNodesValid: Boolean;
    FShadowSunDir: TVector3;             { (0,-1,0) = straight down (ambient blob) }
    FShadowSunIntensity: Single;         { bsmCGE: BikeShadowSun intensity (1.0 default) }
    FShadowMapTick: Integer;             { bsmCGE: счётчик кадров для троттлинга карты }
    FShadowMapThrottled: Boolean;        { bsmCGE: карта уже переведена в upNone }
    FPosDiagTick: Integer;               { ДИАГ: троттлинг posdiag-лога }
    FShadowSunWorld: TVector3;           { WORLD-frame sun (game mode) }
    FShadowSunUseWorld: Boolean;         { True = re-derive local dir per frame }
    FShadowSoftness: Single;             { 0.15 = crisp .. 0.8 = very diffuse }
    FShadowRiderScale: Single;           { measured rider torso length / reference;
                                           scales all rider capsule radii so the
                                           figure matches models of any size. 0 =
                                           not yet measured. }
    FShadowHardEdge: Boolean;            { diagnostic crisp-silhouette toggle }
    FShadowGroundN: TVector3;            { ground-plane normal (bike frame), tilts the shadow }
    FShadowQMinX, FShadowQMaxX: Single;  { cached capsule-quad extents for re-tilt }
    FShadowQMinZ, FShadowQMaxZ: Single;
    FShadowQGy: Single;
    { Сырые (без sun-shift) extents капсул + Y земли с последнего бейка
      RebuildShadowStatic — позволяют UpdateShadowQuadSize пересчитать квады
      при смене направления солнца без перебейка капсул. }
    FShadowCapsMinX, FShadowCapsMaxX: Single;
    FShadowCapsMinZ, FShadowCapsMaxZ: Single;
    FShadowCapsGy: Single;
    procedure SetShowShadow(const V: Boolean);
    procedure SetShadowStrength(const V: Single);
    procedure SetShadowCatchGain(const V: Single);
    function GetAxleHalfSpanM: Single;
    function GetRiderStanceHalf: Single;
    procedure SetShadowSunDir(const V: TVector3);
    procedure SetShadowSunIntensity(const V: Single);
    procedure SetShadowSunWorldDir(const V: TVector3);
    procedure SetShadowSoftness(const V: Single);
    procedure SetShadowHardEdge(const V: Boolean);
    procedure SetShadowGroundNormal(const V: TVector3);
    procedure RebuildShadowQuadTilt;   { re-place capsule quad corners on the tilted ground plane }
    procedure SetShadowMode(const V: TBikeShadowMode);
    { Reconcile scene state with FShadowMode + FShowShadow: which of the
      capsule quad / engine sun light exists and casts. Idempotent. }
    procedure ApplyShadowMode;
    { bsmCGE: lazily build the per-instance shadow-casting sun — a
      DirectionalLight in its own tiny scene with CastGlobalLights, so the
      real ground under the bike receives the engine shadow. }
    procedure EnsureShadowMapLight;
    { World-sun mode: convert FShadowSunWorld into the bike-group LOCAL frame
      (the frame the shadow quad and its capsules live in) through the live
      WorldInverseTransform, and push it to the shader when it changed. Must
      run per frame — the agent turns along the route under a FIXED world
      sun, so the LOCAL light direction rotates continuously. }
    procedure ApplyWorldSunToShadow;
    { bsmCGE: выставить камеру теневой карты (projectionLocation/near/far)
      из текущего FShadowSunDir — камера должна стоять против направления
      света, иначе байк вне фрустума карты и тень пустая. Вызывать при
      каждой смене направления. }
    procedure UpdateShadowMapProjection;
    { bsmCGE: пересчитать размер/сдвиг catcher-квада под текущее направление
      солнца (база — капсульный квад; расширение под растяжку тени).
      Звать при смене направления и при включении bsmCGE. }
    procedure SizeShadowCatcher;
    { bsmCGE ДИАГ: состояние shadow-map пайплайна одной строкой (для MCP
      property_get instance.ShadowMapDiag): узел карты, её update-режим,
      InternalShadowMaps и light-лист catcher'а. Временная диагностика. }
    function  GetShadowMapDiag: String;
    { MCP-обёртки света райдера для published-свойств ниже (nil-safe). }
    function  GetMcpRiderEnv: Single;
    procedure SetMcpRiderEnv(const V: Single);
    function  GetMcpRiderKey: Single;
    procedure SetMcpRiderKey(const V: Single);
    function  GetMcpRiderFill: Single;
    procedure SetMcpRiderFill(const V: Single);
    function  GetMcpRiderLightDiag: String;
    { TEMP-DIAG: EMA-замеры этапов анимации райдера, мс/кадр (MCP AnimDiag). }
    function  GetAnimDiag: String;
    procedure EnsureShadowQuad;          { build quad + shader once, lazily }
    { ДИАГ: quad с теневой картой над байком (лениво, когда узел карты есть). }
    procedure EnsureMapDebugQuad;
    procedure RebuildShadowStatic;       { bake bike capsules, size the quad }
    { Пересчитать размер/наклон капсульного и catcher квадов из extents
      последнего бейка и текущего направления солнца (без перебейка капсул).
      No-op до первого бейка. }
    procedure UpdateShadowQuadSize;
    procedure SendShadowCapsules(const DynA, DynB: array of TVector3;
      const DynRA, DynRB: array of Single; DynCount: Integer);
    procedure UpdateShadowDynamic(const OBB, PedalR, PedalL: TVector3);
    procedure SetGpuAnim(V: Boolean);
    procedure SetAnimationEnabled(V: Boolean);
    procedure InvalidateGpuRiderSkin; { drop GPU plug; next UpdateTripoRider rebuilds }
    function AdoptLoadedRider(NewRider: TTripoRiderScene;
      const AGlbPath: string): Boolean;
    function  GetTripoSpineAngle(Index: Integer): Single;
    procedure SetTripoSpineAngle(Index: Integer; const V: Single);
    procedure CaptureSkeleton(ASkel: TBikeSkeleton; RebuildShadow: Boolean = True);
    procedure UpdateTripoRider(ElapsedSec: Double);
    { Переворот единой сцены: переносит байк-части в сцену загруженного
      райдера (FBikeContainer) и делает её рендер-сценой в FGroup. }
    procedure MountBikeIntoRider;
    { Узел, под которым живёт теневой rig: отдельная rig-сцена (изоляция
      catcher'а от глобальных свет мира). Раньше — FBikeContainer/FMainRoot
      сцены байка; больше rig при перевороте не переезжает. }
    function  ShadowRigHost: TAbstractGroupingNode;
    { Build (once) and reposition the 5 cm debug contact spheres. Honours
      DebugContacts: when False it hides the markers (no rebuild). All points are
      in FGroup space (the same O()-centred frame the rider/targets live in). }
    procedure UpdateContactDebug(const PedalR, PedalL, GripR, GripL,
      SaddleW, RiderW: TVector3);
    procedure NotifyBuildBegin(SubIdx: Integer; PreserveAnim: Boolean = False);
    procedure NotifyBuildComplete(SubIdx: Integer);
    { Пушит FDyePreset* в свежесозданного райдера ДО его загрузки —
      запечка цветов произойдёт внутри LoadGlb/LoadPrepared. }
    procedure ApplyDyePresetToRider(R: TTripoRiderScene);
    { Enumerate-callback live-перекраски: материалы с DiffuseColor≈FRecolorOld
      получают FRecolorNew. }
    procedure GrabRecolorMat(Node: TX3DNode);
    procedure RecolorMaterialsLive(const OldC, NewC: TVector3);
    { CPU-путь (GpuAnim=False): покадрово пишет вращения в именованные
      spin-трансформы из FPhase/FWheelPhase (замена TimeSensor/ROUTE, этап 4).
      Кэш узлов инвалидируется из NotifyBuildBegin. }
    procedure DriveSpinNodesCPU(const Phase, WheelPhase: Single);
    procedure EnsureSteerAxisCache;
    function TotalSteerAngleDeg: Single;
    { Same angle for SteerRot and SteerPoint (hands); only legacy mode quantizes. }
    function MeshSteerAngleDeg: Single;
    procedure DriveSteerNodes;
    procedure DrivePedalLean;
    function SteerPoint(const P: TVector3): TVector3;
    { Copy runtime flags + Preset/DetailLevel from this instance onto the
      given transient Builder. Called by every Build* method. }
    procedure ApplyRuntimeFlagsToBuilder(Builder: TBikeBuilder);
    { Read CrankCycleInterval from the Animation component (if present),
      falling back to the instance's previous FBaseCrankCycle value. }
    function AnimCrankCycleInterval: Single;
    { Единый список полей позы <-> живые Tripo*-поля (ToPose=True = Build).
      HandPosR/L в список не входят: Apply клампит их и ведёт анимацию
      перехвата — это не простое копирование. }
    procedure SyncRiderPose(var P: TRiderPose; ToPose: Boolean);
  private
    { Backing fields for the published top-level params (were public fields;
      converted for RTTI access). }
    FPreset: string;
    FDetailLevel: Integer;
    FShowSkeleton: Boolean;
    FLogGeometry: Boolean;
    FDebugContacts: Boolean;
    FSkelDbgLogged: Boolean;    { one-shot guard for the [Skel] startup_anim dump }
    FUtrLastError: string;      { last logged UpdateTripoRider exception (dedup, '' = none) }
  public
    function CaptureReplay: TBikePlaybackState;
    procedure RestoreReplay(const Saved: TBikePlaybackState);
  public
    { ── Runtime-only flags (not serialized). Mirror of TBikeBuilder's
      flags — persistent on the instance so GUI edits survive across
      builds; copied onto the transient Builder in every Build/*
      method. Now published properties (see below). ── }

    { ── Body-pose presets (public so the editor UI can call them) ── }
    { Pack the current Tripo* posture fields into a pose record. }
    function GroundShadowMap: TGeneratedShadowMapNode;
    procedure SetGroundShadowReceiver(const Enabled: Boolean);
    procedure SetOnFoot(Value: Boolean);
    procedure AnimateOnFoot(Dt, Speed: Single; Facing: Single = 0; GroundSlope: Single = 0;
      PhaseOverride: Single = -1);
    property OnFoot: Boolean read FOnFoot write SetOnFoot;
    property OnFootFrame: TGaitFrame read FOnFootFrame;
    procedure SetRiderEffort(Intensity: Single);
    procedure SetRiderAttention(const Value: TRiderAttentionFrame);
    procedure SetRiderDynamicsSituation(PowerW,LateralAccel,ExternalLeanDeg:Single;
      RoadPitchDeg:Single=0);
    procedure SampleRiderDynamics;
    function RiderTotalLeanDeg:Single;
    property BodyDynamicsEnabled:Boolean read FBodyDynamicsEnabled write SetBodyDynamicsEnabled;
    property RiderEffortTarget: Single read FRiderEffortTarget;
    function RiderCadenceRpm: Single;
    function RiderMotionDebugJson: TJSONObject;
    function  BuildRiderPose(const AName: string): TRiderPose;
    { Set the Tripo* fields from a pose AND animate the rider to it over Duration
      seconds (default 1; 0 = instant). The grid/state then reflect the new pose. }
    procedure ApplyRiderPose(const P: TRiderPose; Duration: Single = 1.0);

    { Diagnostic: sample the pedal train over one full crank revolution and dump
      every part's position/angle into Lines. Uses the SAME math as UpdateTripoRider
      so the log matches what is rendered. Called from the "Pedal Anim Log" button. }
    procedure LogPedalAnimation(Lines: TStrings; Steps: Integer = 24);

    { Append the bike reach metrics (saddle->BB, saddle->pedal at the bottom of
      the stroke, crank arm length) to Lines and RETURN saddle->pedal@bottom in
      metres (0 if no bike). Used by the Rig Inspector button to compare the bike
      against the rider's leg (seat->cleat). }
    function LogBikeReach(Lines: TStrings): Double;

    constructor Create(AOwner: TComponent);
    destructor Destroy; override;

    { Create / reuse persistent component instances to match AClasses.
      Call this before fetching components via Component(...) to tweak
      their fields between presets and full Build. }
    procedure EnsureComponents(const AClasses: TBikeComponentClassArray);
    { Build all 4 sub-scenes from the instance's Preset / DetailLevel /
      runtime flags, single LOD. }
    procedure Build(const AComps: TBikeComponentClassArray;
      const AColors: TBikeColors;
      ADisabled: TStringList);

    { Build with automatic LOD via X3D LODNode — CGE switches at runtime
      by camera distance. LOD3 = nearest/most detail, LOD0 = farthest. }
    procedure BuildWithLOD(const AComps: TBikeComponentClassArray;
      const AColors: TBikeColors;
      ADisabled: TStringList;
      LOD3Dist, LOD2Dist, LOD1Dist: Single);

    { Clear all sub-scenes }
    procedure Clear;

    { Rebuild a single sub-scene — for fast animation-only updates }
    procedure RebuildSub(Sub: Integer;
      const AComps: TBikeComponentClassArray;
      const AColors: TBikeColors;
      ADisabled: TStringList;
      PreserveAnim: Boolean = False);

    { Colors used by the last Build / BuildWithLOD / RebuildSub. }
    function LastBuildColors: TBikeColors;
    { Rebuild every sub-scene with LOD from the current component fields
      (after an in-place geometry tweak such as Bike Insights apply). }
    procedure RebuildAllWithLOD(LOD3Dist: Single = 15.0;
      LOD2Dist: Single = 40.0;
      LOD1Dist: Single = 80.0);
    { Rebuild one sub-scene from the last component set (fit tweaks).
      PreserveAnim=True keeps GPU spin / crank phase so cadence does not jump. }
    procedure RebuildGroup(Sub: Integer; PreserveAnim: Boolean = False);

    { Adjust animation speed (for copies) }
    procedure SetAnimationSpeed(CrankInterval, WheelInterval: Single);
    { Drive the wheels' spin from ground speed (m/s); stops them at ~zero speed. }
    procedure SetWheelSpeedMps(SpeedMps: Single);
    function IsFixedGear: Boolean;
    function DriveMetresPerCrankRevolution: Single;
    function VisualCadence(SensorCadence, SpeedMps: Single): Single;
    procedure SetSteerAngleDeg(const V: Single);

    { Фазы читаются и игрой для синхронизации. GpuAnim — published. }
    property AnimPhase: Single read FPhase;          { 0..1 оборота шатунов }
    property AnimWheelPhase: Single read FWheelPhase;{ 0..1 оборота колеса }
    property AnimAccumTime: Double read FAccumTime;  { монотонное время, с }
    property AnimationEnabled: Boolean read FAnimationEnabled write SetAnimationEnabled;

    { Диагностика цепочки анимации каденса для MCP (bike.anim_debug):
      все экземпляры CrankTimer/WheelTimer в графе FBikeScene (по одному
      на LOD), их Enabled/Active/CycleInterval/ElapsedTimeInCycle, флаг
      FindNode (тем путём, которым фазу читает райдер) и состояние сцены.
      Владение результатом переходит вызывающему. }
    function AnimDebugJson: TJSONObject;

    { Диагностика «потерянных колёс» для MCP (bike.wheels_debug):
      named spin-трансформы (rotation/scale/translation, число шейпов,
      bbox поддерева, эффекты на appearance'ах), состояние GPU-spin
      эффектов (DebugJson из TGpuBikeSpin), bbox сцены, трансформы
      контейнеров. Владение результатом переходит вызывающему. }
    function WheelsDebugJson: TJSONObject;
    { Current analytic joints / authored anchors in the centred bike frame.
      Used by the low-detail NPC shadow, without CPU mesh skinning. }
    function RiderJointPos(const Nm: string; out P: TVector3): Boolean;
    function RiderClothingSkin(const Name:string;out M:TMatrix4):Boolean;
    function BikeAnchor(const Nm: string; out P: TVector3): Boolean;
    { Loading-time fit against this rider's real joints/cleats. Samples one
      seated revolution without skinning vertices, then rebuilds the seat
      once. Call before resource/shader warm-up, never from frame updates. }
    function FitSaddleToRider(KneeFlexDeg: Single = 35;
      AdjustSetback: Boolean = False): Boolean;
    { Fit the existing cockpit on virtual anchors; rebuild geometry once. }
    function FitCockpitToRider(out FitScore: Single): Boolean;
    { Actual tyre support after steering, bicycle balance and world placement.
      Analytic torus support, independent of wheel spin and tessellation. }
    function WheelSupportPoint(Front:Boolean;const GroundNormal:TVector3;
      out P:TVector3):Boolean;

    { One scene owns bicycle groups and the mounted rider. SubScene remains
      a compatibility accessor for component editors, not an enumeration. }
    property Scene: TCastleScene read FBikeScene;
    function ActiveShapeCount: Integer;
    function SubScene(Idx: Integer): TCastleScene;
    function RiderScene: TCastleScene;

    { ── Load an authored Tripo-rigged glb as the cyclist. ──
      CGE skins it on the GPU; AnimateFrame drives its joints (legs->pedals,
      arms->bars) by IK. Placement is calibrated in-engine via
      TripoRiderScale / TripoRiderYawDeg / TripoRiderOffset.
      Pass ALog to capture the load report. }
    function LoadTripoRider(const AGlbPath: string; ALog: TStrings = nil): Boolean;
    function LoadTripoRiderPrepared(APrep: TTripoGlbPrepared): Boolean;
    { Headless apply of a saved "tripoRider" JSON object: sets every tuning
      field, mounts the glb (via LoadTripoRider) and pushes body-shape, so an
      in-game rider matches exactly what the editor saved. O is the parsed
      "tripoRider" object. Returns True if a rider path was present and loaded. }
    function LoadTripoRiderFromSection(O: TJSONObject; Prepared: TTripoGlbPrepared = nil): Boolean;
    function HasTripoRider: Boolean;
    { Цвета одежды райдера (preset уровня байк-инстанса): запоминаются здесь и
      стейджатся в текущего райдера; видимый результат — после перезагрузки
      райдера (запечка в текстуру при загрузке; live-запечка запрещена).
      Caller на живой сцене должен перезагрузить райдера сам. }
    procedure StageRiderClothColor(Slot: TClothSlot; const C: TVector3);
    procedure ClearRiderClothColor(Slot: TClothSlot);
    procedure SetRiderClothColorLive(Slot: TClothSlot; const C: TVector3; Enabled: Boolean);
    function  RiderClothColor(Slot: TClothSlot): TVector3;
    function  RiderClothColorActive(Slot: TClothSlot): Boolean;
    { cdmShader — эффекты вешаются при LoadGlb (сцена ещё без байка).
      После MountBikeIntoRider RefreshShaderClothDye нельзя: FdEffects это
      chEverything и ChangedAll пересобирает весь байк (фриз nvoglv64). }
    property ClothDyePresetMode: TClothDyeMode read FDyePresetMode write FDyePresetMode;
    { Live-перекраска рамы/ободьев: DiffuseColor существующих материалов
      (совпадающих со старым цветом) меняется на месте — поле материала, не
      замена узлов, живую сцену переживает. Новый цвет пишется и в FColors,
      чтобы Rebuild*/RebrandGroup его не потеряли. }
    procedure SetFrameColorLive(const C: TVector3);
    procedure SetRimColorLive(const C: TVector3);
    { Подмена райдера на заранее собранный в фоне (dye-воркер байкфита):
      публичная обёртка AdoptLoadedRider. Main-thread only. При успехе
      инстанс крадёт NewRider. }
    function AdoptBuiltRider(NewRider: TTripoRiderScene;
      const AGlbPath: string): Boolean;
    { Record-typed and indexed properties cannot be published — they stay
      here; all scalar/string Tripo* properties moved to the published
      section below for RTTI (MCP) access. }
    property TripoRiderOffset: TVector3 read FTripoRiderOffset write FTripoRiderOffset;
    property TripoSpineAngle[Index: Integer]: Single read GetTripoSpineAngle write SetTripoSpineAngle;
    property TripoAnkleOffset: TVector3 read FTripoAnkleOffset write FTripoAnkleOffset;
    procedure ApplyTripoBodyShape;
    procedure SetBodyParameters(const Value: TRiderBodyParameters);
    procedure StageBodyParameters(Section:TJSONObject;const Path:string);
    property BodyParameters: TRiderBodyParameters read FBodyParameters write SetBodyParameters;   { push the shape params into the rider mesh + bones }
    procedure ApplyHelmetTint; { parse HelmetColor hex and tint the helmet }
    procedure SetHeadwearColorLive(const Color:TVector3;Enabled:Boolean);
    procedure SetHelmetPitchX(const V: Single);

    { ── Ground contact shadow (soft capsule shadow under bike + rider).
      Scalar shadow properties moved to the published section below; the
      TVector3 directions/normals cannot be published and stay here. ──
      ShowShadow toggles the quad; ShadowStrength = peak opacity 0..1
      (0.5 default). Both apply live, no rebuild needed. }
    { Direction the sunlight TRAVELS (world frame, Y must be negative;
      normalization not required — only the XZ/Y ratio matters). Default
      (0,-1,0) = straight down (pure ambient blob). Setting e.g.
      (0.4,-1,0.2) skews the whole shadow like a low sun: tall parts (head,
      bars) slide further than the wheels. Applies live — the capsules are
      projected along this direction IN THE SHADER, so neither the static
      bake nor the per-frame update change; only the quad is re-sized (the
      skewed shadow needs room on the downwind side). }
    property ShadowSunDir: TVector3 read FShadowSunDir write SetShadowSunDir;
    { The game's COMMON sun in WORLD coordinates — the same direction that
      drives the streaming map's shadow masks. Unlike ShadowSunDir (a fixed
      LOCAL direction for the editor), this one is re-projected into the
      bike's frame every AnimateFrame, so the bike's shadow stays aligned
      with the world sun while the bike turns along the route. Setting it
      switches the shadow to world mode; setting ShadowSunDir switches back. }
    property ShadowSunWorldDir: TVector3 read FShadowSunWorld write SetShadowSunWorldDir;
    { Terrain slope under the bike, as a normal in the BIKE frame. (0,1,0) =
      flat. The shadow plane tilts to this so it follows uneven ground instead
      of cutting under it; the projection accounts for the tilt so proportions
      stay right. The game feeds this from a downward terrain raycast. }
    property ShadowGroundNormal: TVector3 read FShadowGroundN write SetShadowGroundNormal;
    { diagnostic: is the bsmCGE catcher scene currently existing/rendering? }
    function EngineShadowSceneExists: Boolean;

    { Returns LOD level (0..3) for given distance. }
    class function LODForDistance(Dist, LOD3Dist, LOD2Dist, LOD1Dist: Single): Integer;

    { Assembles component array from a preset name. }
    class function PrepareBuildComps(const APreset: string): TBikeComponentClassArray;

    { Copy per-component state from ASource into this instance's persistent
      components, matched by class. Uses ParamsToJSON/FromJSON round-trip so
      every component that already serializes correctly is handled without
      per-class code here. Call after EnsureComponents and before Build* to
      propagate state from a transient builder (e.g. the one returned by
      BikeJSON.LoadBikeFromJSON) into the persistent components that the
      build will actually use. Silently ignores classes present on one side
      but not the other. }
    procedure AssignComponentStateFrom(ASource: TBikeBuilder);

    { Same dispatch as AssignComponentStateFrom, but straight from the parsed
      "components" object of the bike JSON: each persistent component whose
      ComponentName has a sub-object there gets ParamsFromJSON called with it.
      No transient TBikeBuilder / component set is constructed just to carry
      params. Names absent from the JSON are silently skipped (the component
      keeps its defaults), extra JSON names are ignored — same matching
      semantics as AssignComponentStateFrom. Call after EnsureComponents and
      before Build*. }
    procedure AssignComponentStateFromJSON(AComponents: TJSONObject);

    { Per-frame tick dispatched to every persistent component. Use this
      to drive per-frame bone/shape updates — the rider component will
      pick up its AnimateFrame override here. The DeltaSec overload
      accumulates an internal clock. }
    procedure AnimateFrame(ElapsedSec: Double); overload;
    procedure AnimateFrame(DeltaSec: Single); overload;

    { Look up this bike's persistent component instance by class, or nil
      if the class isn't in the active component list. }
    function Component(AClass: TBikeComponentClass): TBikeComponent; overload;

    { Index-based iteration over persistent components. Lets the host
      dispatch ApplyPreset / other cross-cutting calls without knowing
      the component types. }
    function ComponentCount: Integer;
    function Component(Index: Integer): TBikeComponent; overload;

    { Derived bar-type view: btFlat if a FlatBar component is in the list,
      otherwise btDrop. Mirrors TBikeBuilder.BarType. }
    function BarType: TBarType;

    { Fired after each sub-scene is built; use for FillCompGrid etc. }
    property OnSubSceneBuilt: TSubSceneBuiltEvent read FOnSubSceneBuilt write FOnSubSceneBuilt;

  published
    { ── Top-level params (was TBikeParams). Preset serialises to JSON,
      DetailLevel is runtime. ── }
    property Preset: string read FPreset write FPreset;
    property DetailLevel: Integer read FDetailLevel write FDetailLevel;

    { ── Runtime-only flags (not serialized). Mirror of TBikeBuilder's
      flags — persistent on the instance so GUI edits survive across
      builds; copied onto the transient Builder in every Build/* method. ── }
    property ShowSkeleton: Boolean read FShowSkeleton write FShowSkeleton;
    property LogGeometry: Boolean read FLogGeometry write FLogGeometry;
    property DebugContacts: Boolean read FDebugContacts write FDebugContacts;
      { True = show 5 cm spheres at the contact references
        (pedal axles / hand grips / saddle / rider seat) }

    property Group: TCastleTransform read FGroup;

    { ── Live animation state (read-only, MCP RTTI) ── }
    { Накопленное время анимации (сек), растёт каждый кадр в AnimateFrame.
      Фазы кривошипа/колёс выводятся из него и CrankCycleInterval. }
    property AnimElapsed: Double read FAnimElapsed;
    { False = CPU: покадровый IK (UpdatePose) + скин CGE + кручение
      колёс трансформом. True = GpuSkin/GpuSpin (вершинные TEffect).
      Байкфит-превью держит False: иначе ClothDye fragment + GpuSkin
      vertex на одном appearance не собираются. Езда оставляет True. }
    property GpuAnim: Boolean read FGpuAnim write SetGpuAnim;

    { ── Tripo rider tuning (scalar/string only; vectors stay public) ── }
    property TripoRider: TTripoRiderScene read FTripoRider;
    property TripoRiderScale: Single read FTripoRiderScale write FTripoRiderScale;
    property TripoRiderYawDeg: Single read FTripoRiderYawDeg write FTripoRiderYawDeg;
    property TripoTorsoLeanDeg: Single read FTripoTorsoLeanDeg write FTripoTorsoLeanDeg;
    property TripoPedalDir: Single read FTripoPedalDir write FTripoPedalDir;
    property TripoSpineCurve: Single read FTripoSpineCurve write FTripoSpineCurve;
    property TripoSpineManual: Boolean read FTripoSpineManual write FTripoSpineManual;
    property TripoKneeFlare: Single read FTripoKneeFlare write FTripoKneeFlare;
    property TripoElbowFlare: Single read FTripoElbowFlare write FTripoElbowFlare;
    property TripoAnkleFlex: Single read FTripoAnkleFlex write FTripoAnkleFlex;
    property TripoArmPronationR: Single read FTripoArmPronationR write FTripoArmPronationR;
    property TripoArmPronationL: Single read FTripoArmPronationL write FTripoArmPronationL;
    property TripoShoulderRound: Single read FTripoShoulderRound write FTripoShoulderRound;
    property TripoHandLevel: Single read FTripoHandLevel write FTripoHandLevel;
    property TripoStanceHalf: Single read FTripoStanceHalf write FTripoStanceHalf;
    property RiderStanceHalf: Single read GetRiderStanceHalf;
    property TripoFootYawDeg: Single read FTripoFootYawDeg write FTripoFootYawDeg;
    property TripoPedalSway: Single read FTripoPedalSway write FTripoPedalSway;
    property TripoTorsoBobAmp: Single read FTripoTorsoBobAmp write FTripoTorsoBobAmp;
    property TripoShowRider: Boolean read FTripoShowRider write FTripoShowRider;
    property TripoBulk: Single read FTripoBulk write FTripoBulk;
    property TripoBelly: Single read FTripoBelly write FTripoBelly;
    property TripoBodyHeight: Single read FTripoBodyHeight write FTripoBodyHeight;
    property TripoLegLen: Single read FTripoLegLen write FTripoLegLen;
    property TripoArmLen: Single read FTripoArmLen write FTripoArmLen;
    property TripoShoulderWidth: Single read FTripoShoulderWidth write FTripoShoulderWidth;
    property TripoPelvisWidth: Single read FTripoPelvisWidth write FTripoPelvisWidth;
    property TripoTorsoLen: Single read FTripoTorsoLen write FTripoTorsoLen;
    { Multiplier on torso after HeightK: (H−I)/(RestH−RestI)/HeightK.
      1 = native upper share. BikeFit sets this so inseam keeps stature. }
    property TripoInseamUpper: Single read FTripoInseamUpper write FTripoInseamUpper;
    property TripoRoughness: Single read FTripoRoughness write FTripoRoughness;
    property TripoMetallic: Single read FTripoMetallic write FTripoMetallic;
    property HelmetColor: string read FHelmetColor write FHelmetColor;
    property HelmetPitchX: Single read FHelmetPitchX write SetHelmetPitchX;
    property TripoRiderPath: string read FTripoRiderPath write FTripoRiderPath;
    property TripoRiderError: string read FTripoRiderError;

    { ── Ground contact shadow (scalar part; vectors stay public) ── }
    property ShowShadow: Boolean read FShowShadow write SetShowShadow;
    { bsmCGE: False = свет и catcher остаются, но shadow-volume проход
      выключен (диагностика цены volume-машинерии). Дефолт True. }
    property EngineShadowVolumes: Boolean read FEngineShadowVolumes
      write FEngineShadowVolumes;
    property ShadowStrength: Single read FShadowStrength write SetShadowStrength;
    { bsmCGE: gain luminance->alpha кэtcher'а. Альфа = (1 - lum*gain) *
      strength: при освещённом lum ~0.77+ и gain 1.3 квад полностью
      прозрачен, в тени — тёмный. Крутить, если края квада видны (gain ↓)
      или тень слишком слабая/приёмник исчезает (gain ↑). Applies live. }
    property ShadowCatchGain: Single read FShadowCatchGain write SetShadowCatchGain;
    { bsmCGE: intensity of the BikeShadowSun light. The volume shadow on the
      catcher removes exactly this light's contribution — so the shadow's
      darkness = this sun's share of the catcher's total lighting. Raise it
      when other lights (fill / headlight rig / game world lights) dominate
      and the shadow reads too faint. Applies live. }
    property ShadowSunIntensity: Single read FShadowSunIntensity write SetShadowSunIntensity;
    { Penumbra growth per metre of height above the ground: 0.45 default,
      ~0.15 = crisp, near-hard shadow, ~0.8 = very diffuse ambient blob.
      Applies live. }
    property ShadowSoftness: Single read FShadowSoftness write SetShadowSoftness;
    { DIAGNOSTIC: True = draw crisp capsule silhouettes (no penumbra, no height
      falloff); False = normal soft shadow. Applies live. }
    property ShadowHardEdge: Boolean read FShadowHardEdge write SetShadowHardEdge;
    { Shadow implementation switch — see TBikeShadowMode. Applies live. }
    property ShadowMode: TBikeShadowMode read FShadowMode write SetShadowMode;
    { bsmCGE ДИАГ (временная): read-only дамп состояния shadow-map пайплайна. }
    property ShadowMapDiag: String read GetShadowMapDiag;
    { ── MCP: свет райдера (TTripoRiderScene), applies live ──
      env = IBL-ambient (главный источник pure-IBL лука), key/fill =
      направленные свети сцены райдера. Без райдера чтение даёт 0,
      запись игнорируется. }
    property RiderEnvIntensity: Single read GetMcpRiderEnv write SetMcpRiderEnv;
    property RiderKeyIntensity: Single read GetMcpRiderKey write SetMcpRiderKey;
    property RiderFillIntensity: Single read GetMcpRiderFill write SetMcpRiderFill;
    { ДИАГ: дамп светов поддерева райдера (имя:класс=интенсивность). }
    property RiderLightDiag: String read GetMcpRiderLightDiag;
    { TEMP-DIAG (временная): read-only EMA-замеры этапов анимации райдера. }
    property AnimDiag: String read GetAnimDiag;
    { Y of the ground plane the shadow is cast onto (wheel contact height),
      in the bike-group frame. Valid after the first build. }
    property ShadowGroundY: Single read FShadowGroundY;
    { Реальная полубаза колёс из скелета (м) — для физических проб земли.
      0 — скелет/кости недоступны. НЕ из bbox: bbox модели раздут
      теневым catcher'ом/rig'ом и давал пробы в метрах от колёс. }
    property AxleHalfSpanM: Single read GetAxleHalfSpanM;
    property SteerAngleDeg: Single read FSteerAngleDeg write SetSteerAngleDeg;
  end;
  {$M-}

{ Which sub-scene group does a component belong to? -1 = none, -2 = animation }
function SubSceneForComp(const CompName: string): Integer;

{ Yield CPU to UI during heavy build loops.
  Safe to call from any thread — does nothing if not on the main thread. }
procedure BuildYield; inline;

function DefaultBikeColors: TBikeColors;
function RedBikeColors: TBikeColors;
function BlueBikeColors: TBikeColors;
function BlackBikeColors: TBikeColors;
function WhiteBikeColors: TBikeColors;
function GreenBikeColors: TBikeColors;
function OrangeBikeColors: TBikeColors;

function RoadBikeComponents: TBikeComponentClassArray;
function MTBComponents: TBikeComponentClassArray;
function GravelBikeComponents: TBikeComponentClassArray;

{ Count estimated triangle count in an X3D node subtree }
function CountNodePolygons(Node: TX3DNode): Integer;

var
  { Диагностика bsmCGE: False = catcher белый opaque (виден ли квад в сцене);
    True (бой) = multiply-blending (невидимый, только тень). }
  BikeShadowCatcherBlend: Boolean = True;

  { Диагностика bsmCGE: Global у BikeShadowSun. False (бой) — свет только на
    свой catcher: иначе глобальные теневые солнца всех байков/тайлов
    взаимно заливают чужие catcher'ы светом и тени не видно совсем
    (проверено в smtest2: 2 байка с Global=False — тени у обоих).
    В игре — флаг --nolightsun. }
var
  BikeShadowSunGlobal: Boolean = False;

  { ДИАГ (временная): дополнительный подъём теневых квадов (catcher и
    капсульного) над землёй, м. В игре квады оказались ПОД визуальным
    мешем террейна (тень не видна ни в bsmCGE, ни в bsmCapsules) —
    подъём проверяет «захоронение». Боевое значение подобрать по итогам. }
var
  BikeShadowQuadLift: Single = 0.003;

  { ДИАГ (временная): True — над байком строится unlit-квад 2x2 м с
    GeneratedShadowMap BikeShadowSun как emissive-текстурой: видно, что
    реально рендерится в теневую карту (пустая/байк вне кадра/ок). }
var
  BikeShadowMapDebugQuad: Boolean = False;

{ Full steer off: build without SteerRot + no runtime Drive*/SteerPoint.
  CLI: --nosteer. Default False = steer ON. }
var
  BikeDebugDisableSteer: Boolean = False;
  BikeDebugDisableWheelEcc: Boolean = False;

implementation

uses RiderRuntimeAudit, BikeSeatSurface,
  CastleRenderOptions, RiderPoseCatalog, TripoRig,
  CastleShapes,
  CastleSceneCore,  { SceneLifecycleLog — сборка/освобождение составной сцены райдера }
  CastleTimeUtils,
  CastleBoxes,
  BikeLog,
  BikeGfxUtil,  { BicycleAnkleFlexCurve — анклинг }
  BikeParametric_Frame,
  BikeParametric_Fork,
  BikeParametric_DropBar,
  BikeParametric_FlatBar,
  BikeParametric_Seat,
  BikeParametric_Wheel,
  BikeParametric_Crankset,
  BikeParametric_Drivetrain,
  BikeParametric_Animation
  {$ifdef LCL}, Forms{$endif};

{ ═══════════════════════════ BuildYield ═══════════════════════════ }

procedure BuildYield;
begin
  if GetCurrentThreadId = MainThreadID then
  begin
    { Main thread: process pending Synchronize/Queue callbacks,
      and in LCL also pump the UI message loop. }
    {$ifdef LCL}
    Application.ProcessMessages;
    {$else}
    CheckSynchronize(0);
    {$endif}
  end
  else
    { Background thread: release FPC heap lock so main thread can
      allocate/render. Without this, heavy X3D node creation starves
      the main thread due to FPC's global heap lock.
      Sleep(1) guarantees actual pause; Sleep(0) only yields to
      equal-priority threads which may not include the main thread. }
    Sleep(1);
end;

{ ═══════════════════════════ TBikeSkeleton ═══════════════════════════ }

constructor TBikeSkeleton.Create;
begin
  inherited Create;
  SetLength(FBones, 0);
end;

function TBikeSkeleton.FindIndex(const AName: string): Integer;
var I: Integer;
begin
  for I := 0 to High(FBones) do
    if FBones[I].Name = AName then Exit(I);
  Result := -1;
end;

procedure TBikeSkeleton.AddBone(const AName: string; const APos: TVector3);
var N: Integer;
begin
  N := Length(FBones); SetLength(FBones, N + 1);
  FBones[N].Name := AName; FBones[N].Pos := APos;
end;

function TBikeSkeleton.GetBone(const AName: string): TVector3;
var I: Integer;
begin
  I := FindIndex(AName);
  if I < 0 then raise Exception.CreateFmt('Bone "%s" not found', [AName]);
  Result := FBones[I].Pos;
end;

function TBikeSkeleton.TryGetBone(const AName: string; out APos: TVector3): Boolean;
var I: Integer;
begin
  I := FindIndex(AName);
  Result := I >= 0;
  if Result then APos := FBones[I].Pos else APos := Vector3(0, 0, 0);
end;

function TBikeSkeleton.HasBone(const AName: string): Boolean;
begin Result := FindIndex(AName) >= 0; end;

function TBikeSkeleton.BoneCount: Integer;
begin Result := Length(FBones); end;

function TBikeSkeleton.GetBoneByIndex(AIndex: Integer): TBikeBone;
begin Result := FBones[AIndex]; end;

{ ═══════════════════════════ TBikeBuildContext ═══════════════════════════ }

constructor TBikeBuildContext.Create(ASkel: TBikeSkeleton;
  const AColors: TBikeColors; ARoot: TTransformNode;
  ASceneRoot: TX3DRootNode; ACenterX: Single);
begin
  inherited Create;
  FSkeleton := ASkel; FColors := AColors;
  FRoot := ARoot; FSteerRoot := nil; FSceneRoot := ASceneRoot; FCenterX := ACenterX;
end;

{ ── батчинг мелких примитивов ─────────────────────────────────────────── }

constructor TMeshAccum.Create(const AKey: TMeshAccumKey);
begin
  inherited Create;
  Key := AKey;
  Points := TVector3List.Create;
  TexPoints := TVector2List.Create;
  IdxLen := 0;
end;

destructor TMeshAccum.Destroy;
begin
  FreeAndNil(Points);
  FreeAndNil(TexPoints);
  inherited Destroy;
end;

procedure TMeshAccum.AddIdx(V: LongInt);
begin
  if IdxLen >= Length(Indices) then
    SetLength(Indices, Max(256, Length(Indices) * 2));
  Indices[IdxLen] := V;
  Inc(IdxLen);
end;

function TAccumSession.FindOrAdd(const AKey: TMeshAccumKey): TMeshAccum;
var
  I: Integer;
begin
  for I := 0 to High(Items) do
    if TVector3.PerfectlyEquals(Items[I].Key.Color, AKey.Color) and
       TVector3.PerfectlyEquals(Items[I].Key.Spec, AKey.Spec) and
       (Items[I].Key.Shininess = AKey.Shininess) and
       (Items[I].Key.Crease = AKey.Crease) and
       (Items[I].Key.TexNode = AKey.TexNode) then
      Exit(Items[I]);
  SetLength(Items, Length(Items) + 1);
  Items[High(Items)] := TMeshAccum.Create(AKey);
  Result := Items[High(Items)];
end;

destructor TAccumSession.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(Items) do Items[I].Free;
  inherited Destroy;
end;

function TBikeBuildContext.AccumActive: Boolean;
begin
  Result := Length(FSessions) > 0;
end;

function TBikeBuildContext.CurrentSession: TAccumSession;
begin
  if Length(FSessions) = 0 then
    Result := nil
  else
    Result := FSessions[High(FSessions)];
end;

procedure TBikeBuildContext.BeginAccum(AParent: TTransformNode);
var
  S: TAccumSession;
begin
  S := TAccumSession.Create;
  S.Parent := AParent;
  SetLength(FSessions, Length(FSessions) + 1);
  FSessions[High(FSessions)] := S;
end;

procedure TBikeBuildContext.EndAccum;
var
  S: TAccumSession;
  A: TMeshAccum;
  I, J: Integer;
  Coord: TCoordinateNode;
  TexC: TTextureCoordinateNode;
  IFS: TIndexedFaceSetNode;
  Shape: TShapeNode;
begin
  S := CurrentSession;
  if S = nil then Exit;
  SetLength(FSessions, Length(FSessions) - 1);
  try
    for I := 0 to High(S.Items) do
    begin
      A := S.Items[I];
      if (A.Points.Count = 0) or (A.IdxLen = 0) then Continue;
      Coord := TCoordinateNode.Create;
      for J := 0 to A.Points.Count - 1 do
        Coord.FdPoint.Items.Add(A.Points[J]);
      IFS := TIndexedFaceSetNode.Create;
      IFS.Coord := Coord;
      IFS.Solid := False;
      IFS.CreaseAngle := A.Key.Crease;
      for J := 0 to A.IdxLen - 1 do
        IFS.FdCoordIndex.Items.Add(A.Indices[J]);
      if A.Key.TexNode <> nil then
      begin
        TexC := TTextureCoordinateNode.Create;
        for J := 0 to A.TexPoints.Count - 1 do
          TexC.FdPoint.Items.Add(A.TexPoints[J]);
        IFS.TexCoord := TexC;
        for J := 0 to A.IdxLen - 1 do
          IFS.FdTexCoordIndex.Items.Add(A.Indices[J]);
      end;
      Shape := TShapeNode.Create;
      Shape.Geometry := IFS;
      Shape.Appearance := MakeMaterial(A.Key.Color, A.Key.Spec,
        A.Key.Shininess);
      if A.Key.TexNode <> nil then
        Shape.Appearance.Texture := A.Key.TexNode;
      S.Parent.AddChildren(Shape);
    end;
  finally
    S.Free;
  end;
end;

procedure TBikeBuildContext.EmitBatched(Geometry: TIndexedFaceSetNode;
  Coord: TCoordinateNode; const Color, Spec: TVector3;
  Shininess, Crease: Single; const M: TMatrix4);
begin
  EmitBatchedTex(Geometry, Coord, nil, nil, Color, Spec, Shininess, Crease, M);
end;

procedure TBikeBuildContext.EmitBatchedTex(Geometry: TIndexedFaceSetNode;
  Coord: TCoordinateNode; TexCoord: TTextureCoordinateNode;
  TexNode: TAbstractTexture2DNode;
  const Color, Spec: TVector3; Shininess, Crease: Single; const M: TMatrix4);
var
  S: TAccumSession;
  A: TMeshAccum;
  Key: TMeshAccumKey;
  I, Base: Integer;
begin
  S := CurrentSession;
  if S = nil then
  begin
    { вне BeginAccum — вызывающий код не должен сюда попадать;
      на всякий случай просто освобождаем узлы }
    Geometry.Free;   { Coord/TexCoord умирают каскадом; TexNode НЕ трогаем }
    Exit;
  end;
  Key.Color := Color;
  Key.Spec := Spec;
  Key.Shininess := Shininess;
  Key.Crease := Crease;
  Key.TexNode := TexNode;
  A := S.FindOrAdd(Key);
  Base := A.Points.Count;
  for I := 0 to Coord.FdPoint.Items.Count - 1 do
    A.Points.Add(M.MultPoint(Coord.FdPoint.Items[I]));
  if TexCoord <> nil then
    for I := 0 to TexCoord.FdPoint.Items.Count - 1 do
      A.TexPoints.Add(TexCoord.FdPoint.Items[I]);
  for I := 0 to Geometry.FdCoordIndex.Items.Count - 1 do
  begin
    if Geometry.FdCoordIndex.Items[I] < 0 then
      A.AddIdx(-1)
    else
      A.AddIdx(Base + Geometry.FdCoordIndex.Items[I]);
  end;
  Geometry.Free;   { Coord+TexCoord уничтожаются каскадом вместе с Geometry }
end;

{ Вспомогательное: бокс (8 углов, 6 квадов, flat) в батч — аналог TBoxNode. }
procedure AccumBoxRaw(Ctx: TBikeBuildContext; const Center: TVector3;
  SX, SY, SZ: Single; const Color, Spec: TVector3; Shininess: Single);
const
  FACES: array[0..5, 0..3] of Integer = (
    (0, 1, 2, 3), (4, 6, 5, 7), (0, 4, 5, 1),
    (2, 6, 7, 3), (0, 3, 7, 4), (1, 5, 6, 2));
var
  Coord: TCoordinateNode;
  IFS: TIndexedFaceSetNode;
  HX, HY, HZ: Single;
  I, J: Integer;
begin
  HX := SX / 2; HY := SY / 2; HZ := SZ / 2;
  Coord := TCoordinateNode.Create;
  Coord.FdPoint.Items.Add(Vector3(-HX, -HY, -HZ));  { 0 }
  Coord.FdPoint.Items.Add(Vector3( HX, -HY, -HZ));  { 1 }
  Coord.FdPoint.Items.Add(Vector3( HX,  HY, -HZ));  { 2 }
  Coord.FdPoint.Items.Add(Vector3(-HX,  HY, -HZ));  { 3 }
  Coord.FdPoint.Items.Add(Vector3(-HX, -HY,  HZ));  { 4 }
  Coord.FdPoint.Items.Add(Vector3( HX, -HY,  HZ));  { 5 }
  Coord.FdPoint.Items.Add(Vector3( HX,  HY,  HZ));  { 6 }
  Coord.FdPoint.Items.Add(Vector3(-HX,  HY,  HZ));  { 7 }
  IFS := TIndexedFaceSetNode.Create;
  IFS.Coord := Coord;
  IFS.Solid := False;
  for I := 0 to 5 do
  begin
    for J := 0 to 3 do
      IFS.FdCoordIndex.Items.Add(FACES[I, J]);
    IFS.FdCoordIndex.Items.Add(-1);
  end;
  Ctx.EmitBatched(IFS, Coord, Color, Spec, Shininess, 0.0,
    TranslationMatrix(Center));
end;

function TBikeBuildContext.GetDetailLevel: Integer;
begin
  if Builder = nil then Result := 3
  else Result := TBikeBuilder(Builder).DetailLevel;
end;

function TBikeBuildContext.O(const P: TVector3): TVector3;
begin Result := Vector3(P.X - FCenterX, P.Y, P.Z); end;

procedure TBikeBuildContext.Add(ANode: TTransformNode);
begin
  { nil = геометрия ушла в батч (accum-режим) — пустой плейсхолдер не нужен }
  if ANode <> nil then FRoot.AddChildren(ANode);
end;

function TBikeBuildContext.SteerRoot: TTransformNode;
var
  HTB, HTT, Pivot, Axis: TVector3;
  Len: Single;
begin
  { Full off: no SteerRot node — flat graph like Vatokat. }
  if BikeDebugDisableSteer then
    Exit(FRoot);
  if FSteerRoot = nil then
  begin
    FSteerRoot := TTransformNode.Create;
    FSteerRoot.X3DName := 'SteerRot';
    if FSkeleton.TryGetBone('head_tube_bottom', HTB) then
      Pivot := O(HTB)
    else if FSkeleton.TryGetBone('stem_base', HTB) then
      Pivot := O(HTB)
    else
      Pivot := TVector3.Zero;
    FSteerRoot.Center := Pivot;
    if FSkeleton.TryGetBone('head_tube_bottom', HTB)
       and FSkeleton.TryGetBone('head_tube_top', HTT) then
    begin
      Axis := HTT - HTB;
      Len := Sqrt(Sqr(Axis.X) + Sqr(Axis.Y) + Sqr(Axis.Z));
      if Len > 1e-6 then Axis := Axis / Len else Axis := Vector3(0, 1, 0);
    end
    else if (Abs(FSkeleton.HTDirX) + Abs(FSkeleton.HTDirY)) > 1e-6 then
    begin
      Len := Sqrt(Sqr(FSkeleton.HTDirX) + Sqr(FSkeleton.HTDirY));
      Axis := Vector3(FSkeleton.HTDirX / Len, FSkeleton.HTDirY / Len, 0);
    end
    else
      Axis := Vector3(0, 1, 0);
    FSteerRoot.Rotation := Vector4(Axis.X, Axis.Y, Axis.Z, 0);
    FRoot.AddChildren(FSteerRoot);
  end;
  Result := FSteerRoot;
end;

procedure TBikeBuildContext.AddSteered(ANode: TTransformNode);
begin
  if ANode = nil then Exit;
  if BikeDebugDisableSteer then
    Add(ANode)
  else
    SteerRoot.AddChildren(ANode);
end;

procedure TBikeBuildContext.AddTo(AParent, ANode: TTransformNode);
begin
  if (AParent <> nil) and (ANode <> nil) then AParent.AddChildren(ANode);
end;

function TBikeBuildContext.MakeMaterial(const Color, Spec: TVector3;
  Shininess: Single): TAppearanceNode;
var Mat: TMaterialNode;
begin
  Mat := TMaterialNode.Create;
  Mat.DiffuseColor := Color; Mat.SpecularColor := Spec; Mat.Shininess := Shininess;
  Result := TAppearanceNode.Create; Result.Material := Mat;
end;

function TBikeBuildContext.MakeCylinder(const P1, P2: TVector3; Radius: Single;
  const Color, Spec: TVector3; Shininess: Single; TopRadius: Single): TTransformNode;
var Dir, Mid, Ax: TVector3; H, Dot, Ang, Theta, CT, ST, BotR, TopR: Single;
    IFS: TIndexedFaceSetNode; Coord: TCoordinateNode;
    Shape: TShapeNode;
    Slices, I, NI, BotCenter, TopCenter: Integer;
    M: TMatrix4;
begin
  Dir := P2 - P1; H := Dir.Length;
  if H < 0.0001 then Exit(TTransformNode.Create);
  Dir := Dir / H; Mid := (P1 + P2) / 2;
  if TopRadius < 0 then TopRadius := Radius;
  BotR := Radius; TopR := TopRadius;
  Slices := LOD_CylSlices;

  Coord := TCoordinateNode.Create;
  for I := 0 to Slices - 1 do begin
    Theta := 2 * Pi * I / Slices;
    CT := Cos(Theta); ST := Sin(Theta);
    Coord.FdPoint.Items.Add(Vector3(BotR * CT, -H/2, BotR * ST));
  end;
  for I := 0 to Slices - 1 do begin
    Theta := 2 * Pi * I / Slices;
    CT := Cos(Theta); ST := Sin(Theta);
    Coord.FdPoint.Items.Add(Vector3(TopR * CT, H/2, TopR * ST));
  end;
  BotCenter := 2 * Slices;
  TopCenter := 2 * Slices + 1;
  Coord.FdPoint.Items.Add(Vector3(0, -H/2, 0));
  Coord.FdPoint.Items.Add(Vector3(0,  H/2, 0));

  IFS := TIndexedFaceSetNode.Create;
  IFS.Coord := Coord; IFS.Solid := false; IFS.CreaseAngle := 1.5;
  for I := 0 to Slices - 1 do begin
    NI := (I + 1) mod Slices;
    IFS.FdCoordIndex.Items.Add(I); IFS.FdCoordIndex.Items.Add(NI);
    IFS.FdCoordIndex.Items.Add(Slices + NI); IFS.FdCoordIndex.Items.Add(Slices + I);
    IFS.FdCoordIndex.Items.Add(-1);
  end;
  for I := Slices - 1 downto 0 do begin
    NI := (I + Slices - 1) mod Slices;
    IFS.FdCoordIndex.Items.Add(BotCenter); IFS.FdCoordIndex.Items.Add(I);
    IFS.FdCoordIndex.Items.Add(NI); IFS.FdCoordIndex.Items.Add(-1);
  end;
  for I := 0 to Slices - 1 do begin
    NI := (I + 1) mod Slices;
    IFS.FdCoordIndex.Items.Add(TopCenter); IFS.FdCoordIndex.Items.Add(Slices + I);
    IFS.FdCoordIndex.Items.Add(Slices + NI); IFS.FdCoordIndex.Items.Add(-1);
  end;

  Dot := TVector3.DotProduct(Vector3(0, 1, 0), Dir);

  if AccumActive then
  begin
    { запечённый TRS примитива (translation + выравнивание Y на Dir) —
      считается только здесь; не-batch ветка пишет TRS в поля узла }
    if Abs(Dot - 1.0) < 1e-6 then M := TMatrix4.Identity
    else if Abs(Dot + 1.0) < 1e-6 then M := RotationMatrixRad(Pi, 1, 0, 0)
    else begin
      Ax := TVector3.CrossProduct(Vector3(0, 1, 0), Dir).Normalize;
      Ang := ArcCos(EnsureRange(Dot, -1, 1));
      M := RotationMatrixRad(Ang, Ax.X, Ax.Y, Ax.Z);
    end;
    M := TranslationMatrix(Mid) * M;
    EmitBatched(IFS, Coord, Color, Spec, Shininess, 1.5, M);
    Exit(nil);   { геометрия в батче — пустой плейсхолдер не создаём }
  end;

  Shape := TShapeNode.Create;
  Shape.Geometry := IFS; Shape.Appearance := MakeMaterial(Color, Spec, Shininess);

  Result := TTransformNode.Create; Result.Translation := Mid;
  if Abs(Dot - 1.0) < 1e-6 then { no rotation }
  else if Abs(Dot + 1.0) < 1e-6 then Result.Rotation := Vector4(1, 0, 0, Pi)
  else begin
    Ax := TVector3.CrossProduct(Vector3(0, 1, 0), Dir).Normalize;
    Ang := ArcCos(EnsureRange(Dot, -1, 1));
    Result.Rotation := Vector4(Ax.X, Ax.Y, Ax.Z, Ang);
  end;
  Result.AddChildren(Shape);
end;

function TBikeBuildContext.MakeBox(const Center: TVector3; SX, SY, SZ: Single;
  const Color, Spec: TVector3; Shininess: Single): TTransformNode;
var B: TBoxNode; Shape: TShapeNode;
begin
  if AccumActive then
  begin
    AccumBoxRaw(Self, Center, SX, SY, SZ, Color, Spec, Shininess);
    Exit(nil);
  end;
  B := TBoxNode.Create; B.Size := Vector3(SX, SY, SZ);
  Shape := TShapeNode.Create;
  Shape.Geometry := B; Shape.Appearance := MakeMaterial(Color, Spec, Shininess);
  Result := TTransformNode.Create; Result.Translation := Center;
  Result.AddChildren(Shape);
end;

function TBikeBuildContext.MakeSphere(const Center: TVector3; Radius: Single;
  const Color, Spec: TVector3; Shininess: Single): TTransformNode;
var IFS: TIndexedFaceSetNode; Coord: TCoordinateNode;
    Shape: TShapeNode;
    Slices, Stacks, I, J, NI, NJ, VIdx, TopIdx, BotIdx: Integer;
    Theta, Phi, CT, ST, CP, SP: Single;
begin
  Slices := LOD_SphSlices;
  Stacks := Max(4, Slices div 2);

  Coord := TCoordinateNode.Create;
  for I := 1 to Stacks - 1 do begin
    Phi := Pi * I / Stacks; CP := Cos(Phi); SP := Sin(Phi);
    for J := 0 to Slices - 1 do begin
      Theta := 2 * Pi * J / Slices; CT := Cos(Theta); ST := Sin(Theta);
      Coord.FdPoint.Items.Add(Vector3(Radius*SP*CT, Radius*CP, Radius*SP*ST));
    end;
  end;
  TopIdx := (Stacks - 1) * Slices;
  Coord.FdPoint.Items.Add(Vector3(0, Radius, 0));
  BotIdx := TopIdx + 1;
  Coord.FdPoint.Items.Add(Vector3(0, -Radius, 0));

  IFS := TIndexedFaceSetNode.Create;
  IFS.Coord := Coord; IFS.Solid := false; IFS.CreaseAngle := 1.5;
  for J := 0 to Slices - 1 do begin
    NJ := (J + 1) mod Slices;
    IFS.FdCoordIndex.Items.Add(TopIdx); IFS.FdCoordIndex.Items.Add(NJ);
    IFS.FdCoordIndex.Items.Add(J); IFS.FdCoordIndex.Items.Add(-1);
  end;
  for I := 0 to Stacks - 3 do begin
    NI := I + 1;
    for J := 0 to Slices - 1 do begin
      NJ := (J + 1) mod Slices;
      IFS.FdCoordIndex.Items.Add(I*Slices+J); IFS.FdCoordIndex.Items.Add(I*Slices+NJ);
      IFS.FdCoordIndex.Items.Add(NI*Slices+NJ); IFS.FdCoordIndex.Items.Add(NI*Slices+J);
      IFS.FdCoordIndex.Items.Add(-1);
    end;
  end;
  VIdx := (Stacks - 2) * Slices;
  for J := 0 to Slices - 1 do begin
    NJ := (J + 1) mod Slices;
    IFS.FdCoordIndex.Items.Add(BotIdx); IFS.FdCoordIndex.Items.Add(VIdx + J);
    IFS.FdCoordIndex.Items.Add(VIdx + NJ); IFS.FdCoordIndex.Items.Add(-1);
  end;

  if AccumActive then
  begin
    EmitBatched(IFS, Coord, Color, Spec, Shininess, 1.5,
      TranslationMatrix(Center));
    Exit(nil);
  end;

  Shape := TShapeNode.Create;
  Shape.Geometry := IFS; Shape.Appearance := MakeMaterial(Color, Spec, Shininess);

  Result := TTransformNode.Create; Result.Translation := Center;
  Result.AddChildren(Shape);
end;

function TBikeBuildContext.MakeQuad(const P1, P2: TVector3; HalfW: Single;
  const Color, Spec: TVector3; Shininess: Single): TTransformNode;
var Dir, Up, Side: TVector3;
    IFS: TIndexedFaceSetNode; Coord: TCoordinateNode;
    Shape: TShapeNode;
begin
  Dir := P2 - P1;
  if Dir.Length < 1e-6 then Exit(nil);   { вырожденный квад — узел не нужен }
  if Abs(TVector3.DotProduct(Dir.Normalize, Vector3(0,0,1))) < 0.9 then
    Up := Vector3(0, 0, 1)
  else
    Up := Vector3(0, 1, 0);
  Side := TVector3.CrossProduct(Dir.Normalize, Up).Normalize * HalfW;

  Coord := TCoordinateNode.Create;
  Coord.FdPoint.Items.Add(P1 - Side);
  Coord.FdPoint.Items.Add(P1 + Side);
  Coord.FdPoint.Items.Add(P2 + Side);
  Coord.FdPoint.Items.Add(P2 - Side);

  IFS := TIndexedFaceSetNode.Create;
  IFS.Coord := Coord; IFS.Solid := false;
  { одна сторона: Solid=false уже отключает backface culling, развёрнутая
    копия квада — мёртвый дубль геометрии }
  IFS.FdCoordIndex.Items.Add(0); IFS.FdCoordIndex.Items.Add(1);
  IFS.FdCoordIndex.Items.Add(2); IFS.FdCoordIndex.Items.Add(3); IFS.FdCoordIndex.Items.Add(-1);

  if AccumActive then
  begin
    EmitBatched(IFS, Coord, Color, Spec, Shininess, 0.0, TMatrix4.Identity);
    Exit(nil);
  end;

  Shape := TShapeNode.Create;
  Shape.Geometry := IFS; Shape.Appearance := MakeMaterial(Color, Spec, Shininess);

  Result := TTransformNode.Create;
  Result.AddChildren(Shape);
end;

function TBikeBuildContext.MakeTorus(const Center: TVector3;
  MajorR, MinorR: Single; const Color, Spec: TVector3; Shininess: Single;
  Segments: Integer; TubeSegments: Integer): TTransformNode;
var IFS: TIndexedFaceSetNode; Coord: TCoordinateNode;
    Shape: TShapeNode; Verts: array of TVector3;
    I, J, NI, NJ, A, B, C, D, N: Integer;
    Theta, Phi, CT, ST, CP, SP: Single;
begin
  if Segments < 1 then Segments := LOD_TorusSeg;
  if TubeSegments < 1 then TubeSegments := LOD_TorusTubeSeg;

  N := Segments * TubeSegments; SetLength(Verts, N);
  for I := 0 to Segments - 1 do begin
    Theta := 2 * Pi * I / Segments;
    CT := Cos(Theta); ST := Sin(Theta);
    for J := 0 to TubeSegments - 1 do begin
      Phi := 2 * Pi * J / TubeSegments;
      CP := Cos(Phi); SP := Sin(Phi);
      Verts[I * TubeSegments + J] := Vector3(
        (MajorR + MinorR * CP) * CT,
        (MajorR + MinorR * CP) * ST, MinorR * SP);
    end;
  end;
  Coord := TCoordinateNode.Create;
  for I := 0 to High(Verts) do Coord.FdPoint.Items.Add(Verts[I]);
  IFS := TIndexedFaceSetNode.Create;
  IFS.Coord := Coord; IFS.Solid := false; IFS.CreaseAngle := 1.5;
  for I := 0 to Segments - 1 do begin
    NI := (I + 1) mod Segments;
    for J := 0 to TubeSegments - 1 do begin
      NJ := (J + 1) mod TubeSegments;
      A := I * TubeSegments + J; B := I * TubeSegments + NJ;
      C := NI * TubeSegments + NJ; D := NI * TubeSegments + J;
      IFS.FdCoordIndex.Items.Add(A); IFS.FdCoordIndex.Items.Add(B);
      IFS.FdCoordIndex.Items.Add(C); IFS.FdCoordIndex.Items.Add(D);
      IFS.FdCoordIndex.Items.Add(-1);
    end;
  end;
  if AccumActive then
  begin
    EmitBatched(IFS, Coord, Color, Spec, Shininess, 1.5,
      TranslationMatrix(Center));
    Exit(nil);
  end;

  Shape := TShapeNode.Create;
  Shape.Geometry := IFS; Shape.Appearance := MakeMaterial(Color, Spec, Shininess);
  Result := TTransformNode.Create; Result.Translation := Center;
  Result.AddChildren(Shape);
end;

{ ═══════════════════════════ LOD helpers ═══════════════════════════ }

function TBikeBuildContext.LOD_TorusSeg: Integer;
begin
  case DetailLevel of
    0: Result := 12;
    1: Result := 20;
    2: Result := 32;
  else Result := 48;
  end;
end;

function TBikeBuildContext.LOD_TorusTubeSeg: Integer;
begin
  case DetailLevel of
    0: Result := 6;
    1: Result := 8;
    2: Result := 12;
  else Result := 16;
  end;
end;

function TBikeBuildContext.LOD_RimSeg: Integer;
begin
  Result := LOD_TorusSeg;   { same detail table }
end;

function TBikeBuildContext.LOD_SpokeDivisor: Integer;
begin
  case DetailLevel of
    0: Result := 4;
    1: Result := 2;
  else Result := 1;
  end;
end;

function TBikeBuildContext.LOD_CylSlices: Integer;
begin
  case DetailLevel of
    0: Result := 6;
    1: Result := 10;
    2: Result := 16;
  else Result := 24;
  end;
end;

function TBikeBuildContext.LOD_SphSlices: Integer;
begin
  Result := LOD_CylSlices;   { same detail table }
end;

{ ═══════════════════════════ TBikeComponent ═══════════════════════════ }

constructor TBikeComponent.Create;
begin
  inherited Create;
end;

procedure TBikeComponent.ComputeBones(Skel: TBikeSkeleton);
begin { default: no bones } end;

procedure TBikeComponent.OnBuildBegin(SubIdx: Integer);
begin { default: no-op } end;

procedure TBikeComponent.OnBuildComplete(SubIdx: Integer);
begin { default: no-op } end;

procedure TBikeComponent.AnimateFrame(ElapsedSec: Double);
begin { default: no-op } end;

procedure TBikeComponent.ApplyPreset(const APreset: string);
begin { default: no-op } end;

{ Default ParamsToJSON iterates published properties of the concrete class
  via RTTI and serializes each into the per-component JSON sub-object. This
  mirrors how Lazarus LFM streaming works. Subclasses with fields that RTTI
  can't handle directly (e.g. dynamic arrays of primitives) should override:
  call inherited first, then append the special-cased keys. }
procedure TBikeComponent.ParamsToJSON(Obj: TJSONObject);
var
  PropList: PPropList;
  PropCount, I: Integer;
  PI: PPropInfo;
  Kind: TTypeKind;
  F: Double;
begin
  PropCount := GetPropList(Self, PropList);
  if PropCount = 0 then Exit;
  try
    for I := 0 to PropCount - 1 do
    begin
      PI := PropList^[I];
      Kind := PI^.PropType^.Kind;
      case Kind of
        tkInteger:
          Obj.Add(PI^.Name, GetOrdProp(Self, PI));
        tkInt64, tkQWord:
          Obj.Add(PI^.Name, GetInt64Prop(Self, PI));
        tkFloat:
          begin
            F := GetFloatProp(Self, PI);
            Obj.Add(PI^.Name, CreateJSON(Double(F)));  { registry -> canonical float text }
          end;
        tkBool:
          Obj.Add(PI^.Name, Boolean(GetOrdProp(Self, PI)));
        tkEnumeration:
          Obj.Add(PI^.Name, GetEnumProp(Self, PI));
        tkSString, tkLString, tkAString, tkUString, tkWString:
          Obj.Add(PI^.Name, GetStrProp(Self, PI));
      end;
    end;
  finally
    FreeMem(PropList);
  end;
end;

{ Default ParamsFromJSON reads each published property from the per-component
  JSON sub-object. Missing keys leave the existing value unchanged. }
procedure TBikeComponent.ParamsFromJSON(Obj: TJSONObject);
var
  PropList: PPropList;
  PropCount, I: Integer;
  PI: PPropInfo;
  Kind: TTypeKind;
  D: TJSONData;
begin
  PropCount := GetPropList(Self, PropList);
  if PropCount = 0 then Exit;
  try
    for I := 0 to PropCount - 1 do
    begin
      PI := PropList^[I];
      D := Obj.Find(PI^.Name);
      if D = nil then Continue;
      Kind := PI^.PropType^.Kind;
      case Kind of
        tkInteger:
          SetOrdProp(Self, PI, D.AsInteger);
        tkInt64, tkQWord:
          SetInt64Prop(Self, PI, D.AsInt64);
        tkFloat:
          SetFloatProp(Self, PI, D.AsFloat);
        tkBool:
          SetOrdProp(Self, PI, Ord(D.AsBoolean));
        tkEnumeration:
          SetEnumProp(Self, PI, D.AsString);
        tkSString, tkLString, tkAString, tkUString, tkWString:
          SetStrProp(Self, PI, D.AsString);
      end;
    end;
  finally
    FreeMem(PropList);
  end;
end;

procedure TBikeComponent.SetBuilder(ABuilder: TObject);
begin
  FBuilder := ABuilder;
end;

function TBikeComponent.FindComponent(AClass: TBikeComponentClass): TBikeComponent;
begin
  if FBuilder = nil then Exit(nil);
  Result := TBikeBuilder(FBuilder).FindComponent(AClass);
end;

{ ═══════════════════════════ Color presets ═══════════════════════════ }

function DefaultBikeColors: TBikeColors;
begin
  Result.Frame := Vector3(0.72, 0.08, 0.04);
  Result.FrameSpec := Vector3(0.95, 0.45, 0.35);
  Result.Chrome := Vector3(0.88, 0.90, 0.92);
  Result.ChromeSpec := Vector3(1.0, 1.0, 1.0);
  Result.Dark := Vector3(0.08, 0.08, 0.10);
  Result.Tire := Vector3(0.025, 0.025, 0.030);   { tyre: blacker than the rim }
  Result.Seat := Vector3(0.06, 0.06, 0.07);
  Result.Tape := Vector3(0.06, 0.06, 0.08);
  Result.Spoke := Vector3(0.72, 0.74, 0.76);
  Result.Rim := Vector3(0.10, 0.10, 0.12);       { carbon: dark cool grey, not pure black }
  Result.RimSpec := Vector3(0.45, 0.45, 0.52);   { subtle carbon sheen }
  Result.TireSpec := Vector3(0.10, 0.10, 0.10);  { matte rubber }
end;

function RedBikeColors: TBikeColors;
begin Result := DefaultBikeColors;
  Result.Frame := Vector3(0.78, 0.06, 0.06); Result.FrameSpec := Vector3(0.95, 0.40, 0.35);
end;

function BlueBikeColors: TBikeColors;
begin Result := DefaultBikeColors;
  Result.Frame := Vector3(0.08, 0.20, 0.65); Result.FrameSpec := Vector3(0.35, 0.50, 0.95);
end;

function BlackBikeColors: TBikeColors;
begin Result := DefaultBikeColors;
  Result.Frame := Vector3(0.06, 0.06, 0.08); Result.FrameSpec := Vector3(0.30, 0.30, 0.35);
end;

function WhiteBikeColors: TBikeColors;
begin Result := DefaultBikeColors;
  Result.Frame := Vector3(0.92, 0.92, 0.94); Result.FrameSpec := Vector3(1.0, 1.0, 1.0);
end;

function GreenBikeColors: TBikeColors;
begin Result := DefaultBikeColors;
  Result.Frame := Vector3(0.05, 0.45, 0.18); Result.FrameSpec := Vector3(0.30, 0.80, 0.45);
end;

function OrangeBikeColors: TBikeColors;
begin Result := DefaultBikeColors;
  Result.Frame := Vector3(0.90, 0.45, 0.05); Result.FrameSpec := Vector3(1.0, 0.70, 0.35);
end;

{ ═══════════════════════════ CountNodePolygons ═══════════════════════════ }

function CountNodePolygons(Node: TX3DNode): Integer;
var
  I, J: Integer;
  IFS: TIndexedFaceSetNode;
  VertsInFace: Integer;
begin
  Result := 0;
  if Node = nil then Exit;

  { Geometry leaf nodes — count triangles }
  if Node is TIndexedFaceSetNode then
  begin
    IFS := TIndexedFaceSetNode(Node);
    VertsInFace := 0;
    for J := 0 to IFS.FdCoordIndex.Count - 1 do
    begin
      if IFS.FdCoordIndex.Items[J] = -1 then
      begin
        { N-gon with N vertices = N-2 triangles }
        if VertsInFace >= 3 then
          Result := Result + (VertsInFace - 2);
        VertsInFace := 0;
      end
      else
        Inc(VertsInFace);
    end;
    { last face may not end with -1 }
    if VertsInFace >= 3 then
      Result := Result + (VertsInFace - 2);
    Exit;
  end
  { ПРИБЛИЗИТЕЛЬНЫЕ константы треугольников для примитивов CGE: не зависят от
    реальных slices/segments узла (LOD), т.к. из TX3DNode они не читаются —
    это грубая оценка для диагностического счётчика полигонов компонента,
    а не точный подсчёт. }
  else if Node is TCylinderNode then begin Result := 96; Exit; end
  else if Node is TBoxNode then begin Result := 12; Exit; end
  else if Node is TSphereNode then begin Result := 240; Exit; end;

  { Recurse into grouping nodes }
  if Node is TAbstractGroupingNode then
  begin
    with TAbstractGroupingNode(Node) do
      for I := 0 to FdChildren.Count - 1 do
        Result := Result + CountNodePolygons(FdChildren[I]);
  end
  else if Node is TShapeNode then
    Result := Result + CountNodePolygons(TShapeNode(Node).Geometry);
end;

{ ═══════════════════════════ shared bike-frame helpers ═══════════════════
  UpdateTripoRider + диагностические логи (LogPedalAnimation/LogBikeReach)
  считают одно и то же: центровку геометрии, опорные шатуны, точки хвата,
  позиции педалей по фазе и анклинг. Раньше — 4-5 буквальных копий. ═══ }

{ Wheelbase-midpoint X the geometry is centred on; 0 if the axles are missing. }
function BikeCenterX(Skel: TBikeSkeleton): Single;
var A, B: TVector3;
begin
  if Skel.TryGetBone('rear_axle', A) and Skel.TryGetBone('front_axle', B) then
    Result := (A.X + B.X) / 2
  else
    Result := 0;
end;

{ Rest crank arms relative to BB (fallback: 170 mm arms at ±45°, Q ±70 mm). }
procedure RestCrankArms(Skel: TBikeSkeleton; const BB: TVector3;
  out CrankR, CrankL: TVector3);
var A: TVector3;
begin
  if Skel.TryGetBone('crank_right', A) then CrankR := A - BB
  else CrankR := Vector3(0, -0.170,  0.070);
  if Skel.TryGetBone('crank_left', A)  then CrankL := A - BB
  else CrankL := Vector3(0,  0.170, -0.070);
end;

{ Hand-grip point on the bars with graceful fallback:
  hood_base_<side> -> bar_<side> -> stem_end -> BB. O-centred by CenterX. }
function GripBoneFallback(Skel: TBikeSkeleton; const Side: string;
  CenterX: Single; const BB: TVector3): TVector3;
var P: TVector3;

  function Ox(const V: TVector3): TVector3;
  begin Result := Vector3(V.X - CenterX, V.Y, V.Z); end;

begin
  if Skel.TryGetBone('hood_base_' + Side, P) then Exit(Ox(P));
  if Side = 'r' then
  begin
    if Skel.TryGetBone('bar_right', P) then Exit(Ox(P));
  end
  else
    if Skel.TryGetBone('bar_left', P) then Exit(Ox(P));
  if Skel.TryGetBone('stem_end', P) then Exit(Ox(P));
  Result := Ox(BB);
end;

{ Pedal contact points for crank angle Ang (rad): rest crank arms rotated
  around BB, O-centred, stance Z ±QZ. Shared by UpdateTripoRider and the
  pedal diagnostic logs. }
procedure PedalPositions(const BB: TVector3; CenterX, QZ, Ang: Single;
  const CrankR, CrankL: TVector3; out PedalR, PedalL: TVector3);
var C, Sn: Single; OBB: TVector3;
begin
  C := Cos(Ang); Sn := Sin(Ang);
  OBB := Vector3(BB.X - CenterX, BB.Y, BB.Z);
  PedalR := OBB + Vector3(CrankR.X*C - CrankR.Y*Sn, CrankR.X*Sn + CrankR.Y*C,  QZ);
  PedalL := OBB + Vector3(CrankL.X*C - CrankL.Y*Sn, CrankL.X*Sn + CrankL.Y*C, -QZ);
end;

{ Anatomical ankling pitch (rad) for one crank arm at crank angle Ang (rad). }
function AnklingFootPitch(const Crank: TVector3; Ang, AnkleFlex: Single): Single;
begin
  Result := -DegToRad(BicycleAnkleFlexCurve(
    90.0 - RadToDeg(ArcTan2(Crank.Y, Crank.X) + Ang), AnkleFlex));
end;

{ Shared saddle->pedal reach numbers for the diagnostic logs:
  pedal at the lowest crank point, stance Z included. }
procedure BikeReachMetrics(Skel: TBikeSkeleton; StanceHalf: Single;
  out SaddleW, BB, PedBot: TVector3; out QZ, CrkLen, DistSB, DistSP: Single);
var A, CrankR: TVector3;
begin
  BB := Skel['bb'];
  if Skel.TryGetBone('crank_right', A) then CrankR := A - BB
  else CrankR := Vector3(0, -0.170, 0.070);
  if not Skel.TryGetBone('saddle_contact', SaddleW) then
    if not Skel.TryGetBone('seatpost_top', SaddleW) then SaddleW := BB;
  QZ := StanceHalf * Skel.MM;
  CrkLen := Sqrt(CrankR.X * CrankR.X + CrankR.Y * CrankR.Y);   { crank arm length }
  PedBot := Vector3(BB.X, BB.Y - CrkLen, BB.Z + QZ);           { pedal at lowest point }
  DistSB := (SaddleW - BB).Length;
  DistSP := (SaddleW - PedBot).Length;
end;

{ ═══════════════════════════ TBikeBuilder ═══════════════════════════ }

function TBikeBuilder.GetComponentCount: Integer;
begin
  Result := Length(FComponents);
end;

function TBikeBuilder.GetComponent(Index: Integer): TBikeComponent;
begin
  Result := FComponents[Index];
end;

function TBikeBuilder.GetPolyCount(Index: Integer): Integer;
begin
  if (Index >= 0) and (Index < Length(FComponentPolyCounts)) then
    Result := FComponentPolyCounts[Index]
  else
    Result := 0;
end;

procedure TBikeBuilder.InitDefaults;
begin
  Preset := 'road';
  DetailLevel := 3;
  FColors := DefaultBikeColors;
  ShowSkeleton := False;
  LogGeometry := False;
  IncludeEnvironment := True;
  FDisabledNames := TStringList.Create;
  FDisabledNames.CaseSensitive := False;
end;

constructor TBikeBuilder.Create(
  const AComponentClasses: array of TBikeComponentClass);
var I: Integer;
begin
  inherited Create;
  InitDefaults;
  SetLength(FComponentClasses, Length(AComponentClasses));
  for I := 0 to High(AComponentClasses) do FComponentClasses[I] := AComponentClasses[I];
  FSkeleton := TBikeSkeleton.Create;
  SetLength(FComponents, Length(FComponentClasses));
  SetLength(FComponentPolyCounts, Length(FComponentClasses));
  for I := 0 to High(FComponentClasses) do begin
    FComponents[I] := FComponentClasses[I].Create;
    FComponents[I].SetBuilder(Self);
  end;
  FOwnsComponents := True;
end;

constructor TBikeBuilder.CreateBorrowing(
  const AComponents: array of TBikeComponent);
var I: Integer;
begin
  inherited Create;
  InitDefaults;
  SetLength(FComponents, Length(AComponents));
  SetLength(FComponentClasses, Length(AComponents));
  SetLength(FComponentPolyCounts, Length(AComponents));
  for I := 0 to High(AComponents) do
  begin
    FComponents[I] := AComponents[I];
    FComponents[I].SetBuilder(Self);
    FComponentClasses[I] := TBikeComponentClass(AComponents[I].ClassType);
  end;
  FSkeleton := TBikeSkeleton.Create;
  FOwnsComponents := False;
end;

destructor TBikeBuilder.Destroy;
var I: Integer;
begin
  if FOwnsComponents then
    for I := 0 to High(FComponents) do FComponents[I].Free
  else
    { Components borrowed; just clear their builder back-ref to avoid dangling. }
    for I := 0 to High(FComponents) do
      if FComponents[I] <> nil then FComponents[I].SetBuilder(nil);
  FSkeleton.Free;
  FDisabledNames.Free;
  inherited;
end;

function TBikeBuilder.FindComponent(AClass: TBikeComponentClass): TBikeComponent;
var I: Integer;
begin
  for I := 0 to High(FComponents) do
    if FComponents[I].ClassType = TClass(AClass) then
      Exit(FComponents[I]);
  Result := nil;
end;

{ Derived bar type: btFlat if a FlatBar component is in the list, btDrop
  otherwise. Check by ComponentName to avoid pulling BikeParametric_FlatBar
  into this unit's uses. Shared by TBikeBuilder.BarType / TBikeInstance.BarType. }
function ComponentsBarType(const Comps: array of TBikeComponent): TBarType;
var I: Integer;
begin
  for I := 0 to High(Comps) do
    if SameText(Comps[I].ComponentName, 'FlatBar') then
      Exit(btFlat);
  Result := btDrop;
end;

function TBikeBuilder.BarType: TBarType;
begin
  Result := ComponentsBarType(FComponents);
end;

{ Standalone-viewer environment: background, headlight off, 3-point light rig
  (LightKey/LightFill/LightRim — the editor's TLightFollowCameraUI finds them
  by name), default viewpoint. Added by TBikeBuilder.Build when
  IncludeEnvironment is set (default for raw one-shot builds); TBikeInstance
  instead adds it ONCE to FMainRoot in the constructor, so the per-sub /
  per-LOD builds (4/16 roots into a single shared scene) don't pile up
  duplicate environments. }
procedure AddBikeEnvironment(ARoot: TX3DRootNode);
var BG: TBackgroundNode; Nav: TNavigationInfoNode;
    Light: TDirectionalLightNode; VP: TViewpointNode;
begin
  BG := TBackgroundNode.Create;
  BG.FdSkyColor.Items.Add(Vector3(0.91,0.93,0.96));
  BG.FdGroundColor.Items.Add(Vector3(0.85,0.87,0.90));
  ARoot.AddChildren(BG);
  Nav := TNavigationInfoNode.Create; Nav.Headlight := false;
  ARoot.AddChildren(Nav);

  Light := TDirectionalLightNode.Create;
  Light.X3DName := 'LightKey';
  Light.Direction := Vector3(-0.4,-0.7,-0.5);
  Light.Intensity := 1.0; Light.Color := Vector3(1,0.98,0.95);
  Light.AmbientIntensity := 0.3; ARoot.AddChildren(Light);
  Light := TDirectionalLightNode.Create;
  Light.X3DName := 'LightFill';
  Light.Direction := Vector3(0.5,-0.1,0.7);
  Light.Intensity := 0.55; Light.Color := Vector3(0.85,0.9,1);
  ARoot.AddChildren(Light);
  Light := TDirectionalLightNode.Create;
  Light.X3DName := 'LightRim';
  Light.Direction := Vector3(-0.6,0.4,-0.3);
  Light.Intensity := 0.4; Light.Color := Vector3(1,0.6,0.4);
  ARoot.AddChildren(Light);

  VP := TViewpointNode.Create; VP.Position := Vector3(1.5,0.8,2.0);
  VP.Orientation := Vector4(1,0,0,-0.2); VP.FieldOfView := 0.7;
  ARoot.AddChildren(VP);
end;

function TBikeBuilder.Build: TX3DRootNode;
var
    BikeRoot: TTransformNode; Ctx: TBikeBuildContext;
    I, ChildBefore: Integer; CenterX: Single;
    CompName: string;
    IsDisabled: Boolean;
begin
  { Always compute ALL bones (later components may depend on earlier ones) }
  for I := 0 to High(FComponents) do FComponents[I].ComputeBones(FSkeleton);

  CenterX := BikeCenterX(FSkeleton);

  Result := TX3DRootNode.Create;
  if IncludeEnvironment then
    AddBikeEnvironment(Result);

  BikeRoot := TTransformNode.Create; BikeRoot.X3DName := 'BikeRoot';
  Result.AddChildren(BikeRoot);

  Ctx := TBikeBuildContext.Create(FSkeleton, FColors, BikeRoot, Result, CenterX);
  Ctx.Builder := Self;
  try
    for I := 0 to High(FComponents) do
    begin
      CompName := FComponents[I].ComponentName;
      IsDisabled := FDisabledNames.IndexOf(CompName) >= 0;

      ChildBefore := BikeRoot.FdChildren.Count;

      if not IsDisabled then
        FComponents[I].BuildGeometry(Ctx);

      { Yield after each component — releases FPC heap lock so other
        threads (including main thread for rendering) can allocate. }
      BuildYield;

      { Count polygons in newly added children }
      FComponentPolyCounts[I] := 0;
      if not IsDisabled then
      begin
        while ChildBefore < BikeRoot.FdChildren.Count do
        begin
          FComponentPolyCounts[I] := FComponentPolyCounts[I] +
            CountNodePolygons(BikeRoot.FdChildren[ChildBefore]);
          Inc(ChildBefore);
        end;
      end;
    end;
  finally Ctx.Free; end;
end;

{ ═══════════════════════════ Factory helpers ═══════════════════════════ }

function RoadBikeComponents: TBikeComponentClassArray;
begin
  Result := TBikeComponentClassArray.Create(
    TFrameComponent, TForkComponent, TDropBarComponent,
    TSeatComponent, TWheelComponent, TCranksetComponent,
    TDrivetrainComponent, TAnimationComponent);
end;

function MTBComponents: TBikeComponentClassArray;
begin
  Result := TBikeComponentClassArray.Create(
    TFrameComponent, TForkComponent, TFlatBarComponent,
    TSeatComponent, TWheelComponent, TCranksetComponent,
    TDrivetrainComponent, TAnimationComponent);
end;

function GravelBikeComponents: TBikeComponentClassArray;
begin Result := RoadBikeComponents; end;

{ ═══════════════════════════════ SubSceneForComp ═══════════════════════════════ }

function SubSceneForComp(const CompName: string): Integer;
begin
  if (CompName = 'Frame') or (CompName = 'Fork') or
     (CompName = 'DropBar') or (CompName = 'FlatBar') or
     (CompName = 'Seat') then
    Result := BSG_FRAME
  else if (CompName = 'Wheels') then
    Result := BSG_WHEELS
  else if (CompName = 'Crankset') or (CompName = 'Drivetrain') then
    Result := BSG_CRANK
  else if (CompName = 'Animation') then
    Result := -2   { special: included in wheels, crank, rider }
  else
    Result := -1;   { unknown — include everywhere }
end;

{ Helper: fills DisNames with components NOT in sub-scene group Sub }
procedure BuildDisabledForSub(Sub: Integer;
  const AComps: TBikeComponentClassArray;
  ADisabled, DisNames: TStringList);
var I, CompGroup: Integer;
begin
  DisNames.Clear;
  if ADisabled <> nil then
    DisNames.Assign(ADisabled);
  for I := 0 to High(AComps) do
  begin
    CompGroup := SubSceneForComp(AComps[I].ComponentName);
    if CompGroup = -2 then begin
      if Sub = BSG_FRAME then
        if DisNames.IndexOf(AComps[I].ComponentName) < 0 then
          DisNames.Add(AComps[I].ComponentName);
    end
    else if (CompGroup >= 0) and (CompGroup <> Sub) then
      if DisNames.IndexOf(AComps[I].ComponentName) < 0 then
        DisNames.Add(AComps[I].ComponentName);
  end;
end;

{ ═══════════════════════════════ TBikeInstance ═══════════════════════════════ }

const
  { Capacity of the shader's capsule uniform arrays. Static bike ~52
    (2 wheel rings of 12 chords + chainring 12 + ~16 tubes/fork/cockpit),
    rider bones 23, cranks + pedals 4 => ~79 used. 96 caps * 8 floats = 768
    uniform components — within desktop GL fragment uniform limits.
    The GLSL array/loop sizes below are generated from this constant. }
  SHADOW_MAX_CAPS = 112;
  { fallback wheel radius (m) when no Wheel component is found —
    = DEF_WHEEL_RADIUS (BikeParametric_Wheel) mm -> m }
  WHEEL_RADIUS_FALLBACK_M = DEF_WHEEL_RADIUS * 0.001;

type
  { One rider-bone shadow capsule: joint A -> joint B (B = '' -> a sphere
    at A, for leaf bones: head, hands, feet). RA/RB = radius at each end in
    metres (bike/world frame — endpoints are transformed there, so real
    body thicknesses apply regardless of the rig's native scale). RA <> RB
    gives a tapered (cone) capsule: thighs thin toward the knee, the torso
    toward the neck — the silhouette reads as a body, not sausages. }
  TShadowBoneDef = record
    A, B: string;
    RA, RB: Single;
  end;

const
  SHADOW_RIDER_BONES: array[0..22] of TShadowBoneDef = (
    { spine chain, tapering pelvis -> neck }
    (A:'Pelvis';      B:'Waist';       RA:0.115; RB:0.110),
    (A:'Waist';       B:'Spine';       RA:0.110; RB:0.105),
    (A:'Spine';       B:'Spine01';     RA:0.105; RB:0.100),
    (A:'Spine01';     B:'Spine02';     RA:0.100; RB:0.095),
    (A:'Spine02';     B:'NeckTwist01'; RA:0.095; RB:0.055),
    (A:'NeckTwist01'; B:'Head';        RA:0.050; RB:0.045),
    (A:'Head';        B:'';            RA:0.130; RB:0.130),  { head + helmet, bigger }
    { pelvis width: hip joints stick out of the spine line }
    (A:'Pelvis';      B:'R_Thigh';     RA:0.095; RB:0.085),
    (A:'Pelvis';      B:'L_Thigh';     RA:0.095; RB:0.085),
    { shoulder line }
    (A:'R_Clavicle';  B:'R_Upperarm';  RA:0.060; RB:0.055),
    (A:'L_Clavicle';  B:'L_Upperarm';  RA:0.060; RB:0.055),
    { legs, tapering down }
    (A:'R_Thigh';     B:'R_Calf';      RA:0.085; RB:0.058),
    (A:'L_Thigh';     B:'L_Calf';      RA:0.085; RB:0.058),
    (A:'R_Calf';      B:'R_Foot';      RA:0.058; RB:0.042),
    (A:'L_Calf';      B:'L_Foot';      RA:0.058; RB:0.042),
    (A:'R_Foot';      B:'';            RA:0.050; RB:0.050),  { shoe }
    (A:'L_Foot';      B:'';            RA:0.050; RB:0.050),
    { arms, tapering down }
    (A:'R_Upperarm';  B:'R_Forearm';   RA:0.052; RB:0.042),
    (A:'L_Upperarm';  B:'L_Forearm';   RA:0.052; RB:0.042),
    (A:'R_Forearm';   B:'R_Hand';      RA:0.042; RB:0.034),
    (A:'L_Forearm';   B:'L_Hand';      RA:0.042; RB:0.034),
    (A:'R_Hand';      B:'';            RA:0.040; RB:0.040),
    (A:'L_Hand';      B:'';            RA:0.040; RB:0.040)
  );

function TBikeInstance.CaptureReplay: TBikePlaybackState;
begin
  Result.Attention:=FAttention;
  Result.BodyDynamics:=FBodyDynamics;
  Result.BodyDynamicsInput:=FBodyDynamicsInput;
  Result.BodyDynamicsEnabled:=FBodyDynamicsEnabled;
  Result.BodyDynamicsSituation:=FBodyDynamicsSituation;
  Result.SteerAngleDeg:=FSteerAngleDeg;
  Result.PedalSteerDeg:=FPedalSteerDeg;
  Result.PedalLeanDeg:=FPedalLeanDeg;
  Result.AnimElapsed:=FAnimElapsed;
  Result.TripoPrevElapsed:=FTripoPrevElapsed;
  Result.Phase:=FPhase;
  Result.WheelPhase:=FWheelPhase;
  Result.AccumTime:=FAccumTime;
  Result.RiderEffort:=FRiderEffort;
  Result.RiderEffortTarget:=FRiderEffortTarget;
  Result.MotionCadence:=FMotionCadence;
  Result.PedalRate:=FPedalRate;
  Result.BreathPhase:=FBreathPhase;
  Result.BreathLoad:=FBreathLoad;
  Result.PhasePrevElapsed:=FPhasePrevElapsed;
  Result.PhaseStarted:=FPhaseStarted;
  Result.PhaseSynced:=FPhaseSynced;
  Result.CrankIntervalCur:=FCrankIntervalCur;
  Result.WheelIntervalCur:=FWheelIntervalCur;
  Result.ForwardSpeedMps:=FForwardSpeedMps;
  Result.HandFromR:=FHandFromR;
  Result.HandFromL:=FHandFromL;
  Result.HandFromFreeRPos:=FHandFromFreeRPos;
  Result.HandFromFreeLPos:=FHandFromFreeLPos;
  Result.HandFromFreeRWave:=FHandFromFreeRWave;
  Result.HandFromFreeLWave:=FHandFromFreeLWave;
  Result.HandAnchorR:=FHandAnchorR;Result.HandAnchorL:=FHandAnchorL;
  Result.HandAnchorFrameR:=FHandAnchorFrameR;Result.HandAnchorFrameL:=FHandAnchorFrameL;
  Result.FrameHandR:=FFrameHandR;Result.FrameHandL:=FFrameHandL;
  Result.HandAnchorRValid:=FHandAnchorRValid;Result.HandAnchorLValid:=FHandAnchorLValid;
  Result.HandAnimElapsed:=FHandAnimElapsed;
  Result.HandAnimDur:=FHandAnimDur;
  Result.HandAnimating:=FHandAnimating;
  Result.HandSlotR0:=FHandSlotR0;
  Result.HandSlotR1:=FHandSlotR1;
  Result.HandSlotL0:=FHandSlotL0;
  Result.HandSlotL1:=FHandSlotL1;
  Result.Pose:=BuildRiderPose('');
  Result.Rider:=Default(TRiderPoseReplay);
  if FTripoRider<>nil then Result.Rider:=FTripoRider.CaptureReplay;
end;

procedure TBikeInstance.RestoreReplay(const Saved: TBikePlaybackState);
begin
  FAttention:=Saved.Attention;
  ApplyRiderPose(Saved.Pose,0);
  FSteerAngleDeg:=Saved.SteerAngleDeg;
  FPedalSteerDeg:=Saved.PedalSteerDeg;
  FPedalLeanDeg:=Saved.PedalLeanDeg;
  FSteerAngleApplied:=-9999;
  FPedalLeanApplied:=-9999;
  FAnimElapsed:=Saved.AnimElapsed;
  FTripoPrevElapsed:=Saved.TripoPrevElapsed;
  FPhase:=Saved.Phase;
  FWheelPhase:=Saved.WheelPhase;
  FAccumTime:=Saved.AccumTime;
  FRiderEffort:=Saved.RiderEffort;
  FRiderEffortTarget:=Saved.RiderEffortTarget;
  FMotionCadence:=Saved.MotionCadence;
  FPedalRate:=Saved.PedalRate;
  FBreathPhase:=Saved.BreathPhase;
  FBreathLoad:=Saved.BreathLoad;
  FPhasePrevElapsed:=Saved.PhasePrevElapsed;
  FPhaseStarted:=Saved.PhaseStarted;
  FPhaseSynced:=Saved.PhaseSynced;
  FCrankIntervalCur:=Saved.CrankIntervalCur;
  FWheelIntervalCur:=Saved.WheelIntervalCur;
  FForwardSpeedMps:=Saved.ForwardSpeedMps;
  FHandFromR:=Saved.HandFromR;
  FHandFromL:=Saved.HandFromL;
  FHandFromFreeRPos:=Saved.HandFromFreeRPos;
  FHandFromFreeLPos:=Saved.HandFromFreeLPos;
  FHandFromFreeRWave:=Saved.HandFromFreeRWave;
  FHandFromFreeLWave:=Saved.HandFromFreeLWave;
  FHandAnchorR:=Saved.HandAnchorR;FHandAnchorL:=Saved.HandAnchorL;
  FHandAnchorFrameR:=Saved.HandAnchorFrameR;FHandAnchorFrameL:=Saved.HandAnchorFrameL;
  FFrameHandR:=Saved.FrameHandR;FFrameHandL:=Saved.FrameHandL;
  FHandAnchorRValid:=Saved.HandAnchorRValid;FHandAnchorLValid:=Saved.HandAnchorLValid;
  FHandAnimElapsed:=Saved.HandAnimElapsed;
  FHandAnimDur:=Saved.HandAnimDur;
  FHandAnimating:=Saved.HandAnimating;
  FHandSlotR0:=Saved.HandSlotR0;
  FHandSlotR1:=Saved.HandSlotR1;
  FHandSlotL0:=Saved.HandSlotL0;
  FHandSlotL1:=Saved.HandSlotL1;
  if FTripoRider<>nil then FTripoRider.RestoreReplay(Saved.Rider);
  FBodyDynamics:=Saved.BodyDynamics;
  FBodyDynamicsInput:=Saved.BodyDynamicsInput;
  FBodyDynamicsEnabled:=Saved.BodyDynamicsEnabled;
  FBodyDynamicsSituation:=Saved.BodyDynamicsSituation;
  AnimateFrame(FAnimElapsed);
end;

constructor TBikeInstance.Create(AOwner: TComponent);
var I: Integer;
begin
  FBodyParameters:=DefaultRiderBody;
  inherited Create;
  FBodyDynamicsInput:=DefaultRiderDynamicsInput;
  FBodyDynamicsEnabled:=GetEnvironmentVariable('REZVIVO_RIDER_DYNAMICS')<>'0';
  FOwner := AOwner;
  FGroup := TCastleTransform.Create(AOwner);
  FOnSubSceneBuilt := nil;
  FBaseCrankCycle := DEF_CRANK_CYCLE_INTERVAL;   { BikeParametric_Animation }
  FBaseWheelCycle := 2.00;   { дефолтный период оборота колеса, с/об; TimeSensor'ов
    больше нет (этап 4) — действует, пока игра не задаст SetWheelSpeedMps }
  { GPU-анимация, этап 1: накопители фазы. <0 = "не задано" — действуют
    FBase*Cycle с билда. Флаг GpuAnim по умолчанию ВКЛючён (этап 5 закрыт —
    аналитическая тень есть); False — старый CPU-путь (A/B и фолбэк). }
  FPhase := 0; FWheelPhase := 0; FAccumTime := 0;
  FPhasePrevElapsed := 0; FPhaseStarted := False; FPhaseSynced := False;
  FCrankIntervalCur := -1; FWheelIntervalCur := -1;
  FGpuAnim := True;
  FAnimationEnabled := True;
  FResumeGpuAnim := True;
  FGpuSkin := nil;
  FGpuSkinPrimed := False;
  FGpuSpin := nil;
  FSteerAngleDeg := 0;
  FPedalSteerDeg := 0;
  FPedalLeanDeg := 0;
  FSteerAngleApplied := -9999;
  FPedalLeanApplied := -9999;
  FSteerNodesValid := False;
  FSteerRots := nil;
  FSteerAxis := Vector3(0, 1, 0);
  FSteerPivot := TVector3.Zero;
  FSteerAxisCached := False;
  FSpinNodesValid := False;
  FSpinCranks := nil; FSpinPedalR := nil; FSpinPedalL := nil;
  FSpinWheelR := nil; FSpinWheelF := nil;
  ShowSkeleton := False;
  LogGeometry  := False;
  { Единая сцена: один корень, по именованному Transform-подграфу на часть.
    Графы частей строятся в FSubGroup[i] (см. Build/BuildWithLOD/RebuildSub). }
  FBikeScene := TCastleScene.Create(AOwner);
  { MountBikeIntoRider reparents the bike graph into the rider TCastleScene.
    CGE forbids one TX3DNode in two scenes unless InternalNodeSharing;
    without it ChangedAll spams "X3D node … already part of another
    TCastleScene" (~900 warnings per LOD bike). }
  FBikeScene.InternalNodeSharing := True;
  FBikeScene.ProcessEvents := True;
  { свет BikeShadowSun должен светить на весь байк (иначе его зона — только
    поддерево rig'а, и тени от байка на catcher'е нет) }
  FBikeScene.CastGlobalLights := True;
  FGroup.Add(FBikeScene);
  FMainRoot := TX3DRootNode.Create;
  { Environment ровно один раз на сцену (было: каждый Builder.Build
    в Build/BuildWithLOD/RebuildSub тащил свой комплект Background/Nav/
    3×Light/Viewpoint — 4 и 16 копий в одной сцене). Переживает Clear/Build. }
  AddBikeEnvironment(FMainRoot);
  for I := 0 to BSG_COUNT - 1 do
  begin
    FSubGroup[I] := TTransformNode.Create;
    FSubGroup[I].X3DName := 'BSG_' + IntToStr(I);
    FMainRoot.AddChildren(FSubGroup[I]);
  end;
  FTripoGroup := TTransformNode.Create;
  FTripoGroup.X3DName := 'TripoRider';
  FTripoSwitch := TSwitchNode.Create;
  FTripoSwitch.WhichChoice := 0;
  FTripoSwitch.AddChildren(FTripoGroup);
  FMainRoot.AddChildren(FTripoSwitch);
  { Теневой источник — в графе ДО Scene.Load: ProcessShadowMapsReceivers
    надёжно отрабатывает на загрузке (как у рабочих теней зданий Osm3d),
    а позднее добавление требует ручной переразметки. }
  FShadowRigNode := TTransformNode.Create;
  FShadowRigNode.X3DName := 'BikeShadowRig';
  { Rig (и вся его поддерево: солнце, catcher) удерживаем от FreeIfUnused:
    ApplyShadowMode в режиме bsmCapsules/bsmNone снимает rig с графа
    (RemoveChildren), иначе узлы уничтожаются, а поля FShadowRigNode/
    FShadowMapLight/FShadowCatchCoord становятся висячими -> AV при
    обратном включении bsmCGE. Балансируется KeepExistingEnd в Destroy. }
  FShadowRigNode.KeepExistingBegin;
  FShadowMapLight := TDirectionalLightNode.Create;
  FShadowMapLight.X3DName := 'BikeShadowSun';
  FShadowMapLight.Direction := Vector3(0, -1, 0);   { до первого SetShadowSunDir/WorldDir }
  FShadowMapLight.Color := Vector3(1, 1, 1);
  FShadowMapLight.Intensity := 1.0;
  FShadowMapLight.AmbientIntensity := 0;
  { False (бой): солнце светит только на свой catcher (siblings под rig'ом) —
    глобальные теневые солнца всех байков взаимно заливают чужие catcher'ы,
    и тени не видно совсем. Кастеры карты — весь вьюпорт, от scope света
    не зависят (проверено smtest2). }
  FShadowMapLight.Global := BikeShadowSunGlobal;
  FShadowMapLight.Shadows := True;
  { Явный прямоугольник проекции (автокалькуляция по боксам в нашей сборке
    даёт пустую карту); location/near/far выставляет UpdateShadowMapProjection
    из направления солнца — она же зовётся при каждой смене направления.
    Прямоугольник с запасом: покрывает байк + растяжку тени по земле. }
  FShadowMapLight.FdProjectionRectangle.Value := Vector4(-1.5, -1.5, 1.5, 1.5);
  FShadowRigNode.AddChildren(FShadowMapLight);
  { Rig (солнце + catcher) — в ОТДЕЛЬНОЙ маленькой сцене, а не в сцене байка:
    ReceiveGlobalLights=False изолирует catcher от глобальных солнц мира
    (в игре 6+ солнц Osm3d-тайлов разбавляли luminance-catcher до невидимости;
    байк/райдер при этом остаются на мировом освещении). Кастеры карты —
    весь вьюпорт, от сцены приёмника не зависят. Свет scoped: светит только
    на sibling'ов под rig'ом = catcher. }
  FShadowRigScene := TCastleScene.Create(AOwner);
  FShadowRigScene.InternalNodeSharing := True;
  FShadowRigScene.ProcessEvents := True;
  FShadowRigScene.CastShadows := False;   { сам catcher в карту не попадает }
  FShadowRigScene.RenderOptions.ReceiveGlobalLights := False;
  FShadowRigScene.ShadowMapsDefaultSize := 1024;
  FShadowRigRoot := TX3DRootNode.Create;
  FShadowRigRoot.AddChildren(FShadowRigNode);
  FShadowRigScene.Load(FShadowRigRoot, True);
  FGroup.Add(FShadowRigScene);
  FBikeScene.Load(FMainRoot, True);
  FTripoRider       := nil;
  FDyePresetMode    := cdmTexture;   { запечка при загрузке; без активных слотов — no-op }
  FBikeSkeleton     := nil;
  FContactDbgScene  := nil;
  FShadowScene      := nil;      { built lazily on the first RebuildShadowStatic }
  FMapDbgScene      := nil;
  FShadowCatchShapeNode := nil;
  FShowShadow       := False;
  FEngineShadowVolumes := False;
  FShadowStrength   := 0.5;      { peak shadow opacity under the wheels }
  FShadowCatchGain  := 1.3;      { catcher: lit lum >= ~0.77 -> alpha 0 }
  FShadowSunDir     := Vector3(0, -1, 0);   { straight down until told otherwise }
  UpdateShadowMapProjection;
  FShadowSunIntensity := 1.0;
  FShadowSunWorld   := Vector3(0, -1, 0);
  FShadowSunUseWorld := False;
  FShadowMode       := bsmNone;
  { FShadowMapLight/FShadowRigNode созданы выше (до Scene.Load) — не трогаем }
  FShadowSoftness   := 0.5;      { penumbra growth per metre of height — clearly soft }
  FShadowRiderScale := 0;        { measured on first rider update }
  FShadowHardEdge   := False;     { normal soft shadow (diagnostic crisp mode off) }
  FShadowGroundN    := Vector3(0, 1, 0);   { flat until the game feeds terrain slope }
  FShadowGroundY    := 0;
  DebugContacts     := False;    { contact-marker spheres — дебаг; редактор/игра включают явно }
  FTripoRiderScale  := 1.0;
  FTripoFitScale    := 0.0;      { 0 = compute rig→bike fit on next placement }
  FTripoRiderYawDeg := 0.0;
  FTripoRiderOffset := TVector3.Zero;
  FTripoTorsoLeanDeg := -30.0;   { forward lean }
  FTripoPedalDir     := -1.0;    { corrected pedalling direction }
  FTripoShowRider      := True;
  FTripoAnkleOffset    := TVector3.Zero;
  FTripoStanceHalf     := 0;     { derive both foot targets from the actual pedal centres }
  FTripoFootYawDeg     := 0;     { zero preserves the authored/natural foot orientation }
  { skeleton proportion coefficients: 1.0 = model as authored }
  FTripoLegLen := 1.0; FTripoArmLen := 1.0; FTripoShoulderWidth := 1.0;
  FTripoPelvisWidth := 1.0; FTripoTorsoLen := 1.0;
  FTripoInseamUpper := 1.0;
  FTripoRoughness := 1.0;        { PBR roughness multiplier: 1 = materials as authored }
  FTripoMetallic  := 1.0;        { PBR metallic multiplier: 1 = materials as authored }
  FHelmetColor := '';       { helmet tint off }
  FHelmetPitchX := 0;
  FHelmetPitchFromJson := False;
  FTripoHandPosR := 1; FTripoHandPosL := 1;
  FTripoHandFreeRPos := TVector3.Zero; FTripoHandFreeLPos := TVector3.Zero;
  FTripoHandFreeRWave := 0; FTripoHandFreeLWave := 0;
  FTripoArmPronationR := 0; FTripoArmPronationL := 0;
  FTripoLegFreeR := 0; FTripoLegFreeL := 0;
  FTripoLegFreeRPos := TVector3.Zero; FTripoLegFreeLPos := TVector3.Zero;
  FHandFromR := 1; FHandFromL := 1;
  FHandFromFreeRPos := TVector3.Zero; FHandFromFreeLPos := TVector3.Zero;
  FHandFromFreeRWave := 0; FHandFromFreeLWave := 0;
  FHandAnimating := False; FHandAnimElapsed := 0; FHandAnimDur := 0;
  { posture / motion / seat offset / hands / legs now come from poses; seed the live
    fields from the Default pose (the compiled catalog) }
  FRiderEffort := 0.75; FRiderEffortTarget := 0.75;
  FBreathPhase := Random; FBreathLoad:=0.25;
  ApplyRiderPose(BuiltinRiderPose(0), 0);

  if SceneLifecycleLogEnabled then SceneLifecycleLog(Format(
    'BIKE-ASM Create inst=$%p owner=$%p group=$%p bikescene=$%p rigscene=$%p',
    [Pointer(Self), Pointer(FOwner),
     Pointer(FGroup), Pointer(FBikeScene), Pointer(FShadowRigScene)]));
end;

destructor TBikeInstance.Destroy;
var I: Integer;
begin
  if SceneLifecycleLogEnabled then SceneLifecycleLog(Format(
    'BIKE-FREE begin inst=$%p group=$%p bikescene=$%p rigscene=$%p tripomounted=%s',
    [Pointer(Self), Pointer(FGroup), Pointer(FBikeScene), Pointer(FShadowRigScene),
     BoolToStr(FTripoRider <> nil, True)]));
  for I := 0 to High(FComponents) do
    FComponents[I].Free;
  FComponents := nil;
  if (FTripoRider <> nil) and (FTripoRider.Scene <> nil) then
    FGroup.Remove(FTripoRider.Scene);   { рендер-сцена после переворота }
  FreeAndNil(FGpuSkin);         { эффект умрёт вместе с узлами сцены райдера }
  FGpuSkinPrimed := False;
  FreeAndNil(FGpuSpin);
  FreeAndNil(FSteerRots);         { spin-эффекты умирают вместе с appearance'ами }
  if FSpinCranks <> nil then
  begin
    FSpinCranks.Free; FSpinPedalR.Free; FSpinPedalL.Free;
    FSpinWheelR.Free; FSpinWheelF.Free;
  end;
  if FShadowRigNode <> nil then
  begin
    FShadowRigNode.KeepExistingEnd;   { баланс KeepExistingBegin из Create }
    FShadowRigNode.FreeIfUnused;
    FShadowRigNode := nil;
  end;
  if FBikeContainer <> nil then
  begin
    { MountBikeIntoRider pins the container so it survives rider reloads.
      Release pins while the scene is still alive: node destruction may notify
      its scene. Attached nodes are then freed by the scene's normal teardown.
      A detached container after a failed reload is freed explicitly. }
    FBikeContainer.KeepExistingEnd;
    FBikeContainer.FreeIfUnused;
    FBikeContainer := nil;
  end;
  FreeAndNil(FTripoRider);    { frees its TCastleScene; CGE detaches it from FGroup }
  FreeAndNil(FBikeSkeleton);
  FGroup.Free;
  if SceneLifecycleLogEnabled then
    SceneLifecycleLog(Format('BIKE-FREE done inst=$%p', [Pointer(Self)]));
  inherited;
end;

procedure TBikeInstance.EnsureComponents(const AClasses: TBikeComponentClassArray);
var I: Integer; NeedRebuild: Boolean;
begin
  NeedRebuild := Length(FComponents) <> Length(AClasses);
  if not NeedRebuild then
    for I := 0 to High(AClasses) do
      if FComponents[I].ClassType <> TClass(AClasses[I]) then
      begin
        NeedRebuild := True;
        Break;
      end;
  if not NeedRebuild then Exit;
  for I := 0 to High(FComponents) do
    FComponents[I].Free;
  SetLength(FComponents, Length(AClasses));
  for I := 0 to High(AClasses) do
    FComponents[I] := AClasses[I].Create;
end;

procedure TBikeInstance.NotifyBuildBegin(SubIdx: Integer; PreserveAnim: Boolean);
var I: Integer;
begin
  FFrameContactsValid := False;
  FSteerNodesValid := False;
  if FSteerRots <> nil then FSteerRots.Clear;
  FSteerAxisCached := False;  { stem/spacers move the steer axis }
  if not PreserveAnim then
  begin
    FPedNodesValid := False;
    FSpinNodesValid := False;
    FreeAndNil(FGpuSpin);      { этап 4: spin-эффекты висят на appearance'ах — пересоздать }
    FPhaseSynced := False;     { таймеры пересоздаются билдом — ресинхронизировать фазу }
  end;
  for I := 0 to High(FComponents) do
    FComponents[I].OnBuildBegin(SubIdx);
end;

procedure TBikeInstance.NotifyBuildComplete(SubIdx: Integer);
var I: Integer;
begin
  for I := 0 to High(FComponents) do
    FComponents[I].OnBuildComplete(SubIdx);
end;

procedure TBikeInstance.DriveSpinNodesCPU(const Phase, WheelPhase: Single);

  procedure CollectNamed(N: TX3DNode);
  var I: Integer;
  begin
    if N = nil then Exit;
    if N is TTransformNode then
    begin
      if N.X3DName = 'CranksRot' then FSpinCranks.Add(N);
      if N.X3DName = 'PedalRightRot' then FSpinPedalR.Add(N);
      if N.X3DName = 'PedalLeftRot' then FSpinPedalL.Add(N);
      if N.X3DName = 'RearWheelRot' then FSpinWheelR.Add(N);
      if N.X3DName = 'FrontWheelRot' then FSpinWheelF.Add(N);
    end;
    if N is TAbstractGroupingNode then
      for I := 0 to TAbstractGroupingNode(N).FdChildren.Count - 1 do
        CollectNamed(TAbstractGroupingNode(N).FdChildren[I]);
  end;

var I: Integer;
    CrankAng, PedalAng, WheelAng: Single;
begin
  if not FSpinNodesValid then
  begin
    if FSpinCranks = nil then
    begin
      FSpinCranks := TList.Create; FSpinPedalR := TList.Create;
      FSpinPedalL := TList.Create; FSpinWheelR := TList.Create;
      FSpinWheelF := TList.Create;
    end;
    FSpinCranks.Clear; FSpinPedalR.Clear; FSpinPedalL.Clear;
    FSpinWheelR.Clear; FSpinWheelF.Clear;
    if (FBikeScene <> nil) and (FBikeScene.RootNode <> nil) then
      CollectNamed(FBikeScene.RootNode);
    FSpinNodesValid := True;
  end;
  CrankAng := Phase * 2 * Pi;   { ось (0,0,-1): CrankSpin }
  PedalAng := Phase * 2 * Pi;   { ось (0,0,1): PedalCounterSpin }
  WheelAng := WheelPhase * 2 * Pi;   { ось (0,0,-1): WheelSpin }
  for I := 0 to FSpinCranks.Count - 1 do
    TTransformNode(FSpinCranks[I]).FdRotation.Send(Vector4(0, 0, -1, CrankAng));
  for I := 0 to FSpinPedalR.Count - 1 do
    TTransformNode(FSpinPedalR[I]).FdRotation.Send(Vector4(0, 0, 1, PedalAng));
  for I := 0 to FSpinPedalL.Count - 1 do
    TTransformNode(FSpinPedalL[I]).FdRotation.Send(Vector4(0, 0, 1, PedalAng));
  for I := 0 to FSpinWheelR.Count - 1 do
    TTransformNode(FSpinWheelR[I]).FdRotation.Send(Vector4(0, 0, -1, WheelAng));
  for I := 0 to FSpinWheelF.Count - 1 do
    TTransformNode(FSpinWheelF[I]).FdRotation.Send(Vector4(0, 0, -1, WheelAng));
end;

procedure TBikeInstance.ApplyRuntimeFlagsToBuilder(Builder: TBikeBuilder);
begin
  if Builder = nil then Exit;
  Builder.Preset       := Preset;
  Builder.DetailLevel  := DetailLevel;
  Builder.ShowSkeleton := ShowSkeleton;
  Builder.LogGeometry  := LogGeometry;
  { environment живёт в FMainRoot (конструктор) — пер-билд копии не нужны }
  Builder.IncludeEnvironment := False;
end;

function TBikeInstance.AnimCrankCycleInterval: Single;
var I: Integer;
begin
  for I := 0 to High(FComponents) do
    if FComponents[I] is TAnimationComponent then
      Exit(TAnimationComponent(FComponents[I]).CrankCycleInterval);
  Result := FBaseCrankCycle;
end;

procedure TBikeInstance.SetOnFoot(Value: Boolean);
begin
  if FOnFoot=Value then Exit;
  FOnFoot:=Value;
  FOnFootDynamics:=Default(TGaitDynamicsState);
  ResetRiderDynamics(FBodyDynamics);
  if Value then begin
    FOnFootSavedGpu:=FGpuAnim;SetGpuAnim(False);FOnFootPhase:=0;
    if FTripoRider<>nil then FTripoRider.SetSkinnedAnimationShaders(True);
    if (FTripoRider<>nil) and (FBikeContainer<>nil) then
    begin
      FTripoRider.Scene.RootNode.RemoveChildren(FBikeContainer);
      { This retained graph may outlive the scene when clothing is changed
        on foot. CGE does not unregister nodes detached from an owned root. }
      FBikeContainer.UnregisterScene;
    end;
  end else begin
    if (FTripoRider<>nil) and (FBikeContainer<>nil) then
      FTripoRider.Scene.RootNode.AddChildren(FBikeContainer);
    SetGpuAnim(FOnFootSavedGpu);FPhaseStarted:=False;
  end;
end;

procedure TBikeInstance.AnimateOnFoot(Dt, Speed: Single; Facing,GroundSlope,PhaseOverride: Single);
var Frame: TGaitFrame; Scale, Yaw, Direction, Effort, RunBlend: Single; Offset: TVector3;
begin
  if not HasTripoRider then Exit;
  SetOnFoot(True);
  if not FAnimationEnabled then Exit;
  Dt:=EnsureRange(Dt,0,0.1);Direction:=1;if Speed<0 then Direction:=-1;
  Speed:=EnsureRange(Abs(Speed),0,8);
  Scale:=AvatarGaitScale(FTripoRider.Rig);
  RunBlend:=EnsureRange((Speed/Max(Scale,0.1)-2.0)/1.1,0,1);
  RunBlend:=RunBlend*RunBlend*(3-2*RunBlend);
  FOnFootPhase:=AdvanceGaitPhase(FOnFootPhase,Dt,Direction*Speed,Scale,RunBlend);
  if PhaseOverride>=0 then FOnFootPhase:=Frac(PhaseOverride);
  if FOnFootPhase<0 then FOnFootPhase:=FOnFootPhase+1;
  PoseAvatarGait(FTripoRider.Rig,FOnFootPhase,Speed,Speed>2.5,Frame,RunBlend,GroundSlope);
  Frame.VerticalVelocity:=Frame.VerticalVelocity*Direction;
  FOnFootFrame:=Frame;
  FTripoRider.SyncProceduralPose(Frame.ShoulderProtraction[1],Frame.ShoulderProtraction[0]);
  { The gait uses the authored rig's axes. Convert its forward vector to
    the host's desired horizontal heading, keeping sole contact at Y=0. }
  Yaw:=ArcTan2(Frame.Forward.X,Frame.Forward.Z)-Facing;
  Offset:=RotatePointAroundAxis(Vector4(0,1,0,-Yaw),
    Vector3(Frame.Offset.X,Frame.Offset.Y,Frame.Offset.Z));
  FTripoRider.Scene.Scale:=Vector3(1,1,1);
  FTripoRider.Scene.Rotation:=Vector4(0,1,0,-Yaw);
  FTripoRider.Scene.Translation:=Offset;
  Effort:=EnsureRange(0.15+Speed*0.18,0.15,1.2);
  AdvanceGaitDynamics(FOnFootDynamics,Frame,Effort,FBodyParameters.Composition,Dt);
  if (FTripoRider.Correctives<>nil)and(FTripoRider.Correctives.Body<>nil)then
    FTripoRider.Correctives.Body.SetDynamicsFrame(FOnFootDynamics.Frame,
      TMatrix4.Identity,TVector3.Zero,Default(TSeatSurface),0);
  AdvanceRiderBreathing(FBreathLoad,FBreathPhase,Dt,Effort);
  FTripoRider.UpdateAppearance(Dt,Speed,Effort,FOnFootPhase,FBreathPhase,FBreathLoad);
  ApplyWorldSunToShadow;
  FTripoRider.EnsureNativeSkinReady;
end;

procedure TBikeInstance.AnimateFrame(ElapsedSec: Double);
var I: Integer;
    T0c, T1c: TTimerResult;   { TEMP-DIAG }
    Dt: Double;
    CrankIntv, WheelIntv: Single;
    RequestedRate: Single;
    P: TRiderPose;
begin
  { BuildYield pumps the UI while subgroups are replaced. Do not collect or
    animate nodes from that temporary graph: they may be freed by the next
    build step. Invalidate-on-entry alone cannot protect such cached nodes. }
  if (FBuildDepth > 0) or FOnFoot then Exit;
  CountRiderWork(rwBikeFrame);
  ApplyWorldSunToShadow;   { the agent may have turned since the last frame }
  if not FAnimationEnabled then Exit;
  { ── GPU-анимация, этап 1: фаза крутки на CPU (несколько float-операций
    на кадр). Пока GpuAnim=False потребителей у FPhase/FWheelPhase нет —
    райдер читает FPhase (синхронизированную с CrankTimer один раз),
    меши крутятся TimeSensor'ами. ── }
  if not FPhaseStarted then
  begin
    FPhaseStarted := True;
    FPhasePrevElapsed := ElapsedSec;
  end;
  Dt := ElapsedSec - FPhasePrevElapsed;
  if (Dt < 0) or (Dt > 0.5) then Dt := 0;   { guard resets / long stalls }
  FPhasePrevElapsed := ElapsedSec;
  FAccumTime := FAccumTime + Dt;
  CrankIntv := FCrankIntervalCur; if CrankIntv < 0 then CrankIntv := FBaseCrankCycle;
  WheelIntv := FWheelIntervalCur; if WheelIntv < 0 then WheelIntv := FBaseWheelCycle;
  RequestedRate := 0;
  if (CrankIntv > 0.01) and (CrankIntv < 1000) then RequestedRate := 1 / CrankIntv;
  if (FTripoRider <> nil) and FTripoRider.PoseAnimating then
    P := FTripoRider.CurrentPose
  else P := BuildRiderPose('');
  { A fixed drive cannot coast while a foot is being placed on its pedal.
    Free-foot IK still handles the departure; the crank remains driven. }
  if IsFixedGear then FPedalRate := RequestedRate
  else FPedalRate := AdvancePedalRate(FPedalRate, RequestedRate, Dt,
    PedalContactsReady(P.Motion.Pedalling, P.LegFreeR, P.LegFreeL,
      FBaseRiderPose.Grounded));
  FPhase := Frac(FPhase + Dt * FPedalRate);
  if WheelIntv > 0.01 then FWheelPhase := Frac(FWheelPhase + Dt / WheelIntv);
  { bsmCGE: карта обновляется каждый кадр (колёса/кости двигаются всегда) }
  if (FShadowMode = bsmCGE) and (FShadowMapLight <> nil)
     and (FShadowMapLight.FdDefaultShadowMap.Value is TGeneratedShadowMapNode) then
  begin
    if not FShadowMapThrottled then
    begin
      TGeneratedShadowMapNode(FShadowMapLight.FdDefaultShadowMap.Value)
        .GenTexFunctionality.Update := upAlways;
      FShadowMapThrottled := True;
    end;
  end;
  { ДИАГ: квад с содержимым карты (лениво — узел карты появляется после
    первого ProcessShadowMapsReceivers) }
  if BikeShadowMapDebugQuad and (FMapDbgScene = nil) then
    EnsureMapDebugQuad;
  T0c := Timer;   { TEMP-DIAG }
  for I := 0 to High(FComponents) do
    FComponents[I].AnimateFrame(ElapsedSec);
  T1c := Timer;
  FDiagComps := FDiagComps * 0.95 + TimerSeconds(T1c, T0c) * 1000 * 0.05;
  T0c := Timer;
  if FTripoRider <> nil then
  begin
    UpdateTripoRider(ElapsedSec);
    FTripoRider.UpdateAppearance(Dt,FForwardSpeedMps,FRiderEffort,FRiderCrankPhase,FBreathPhase,FBreathLoad);
  end;
  T1c := Timer;
  FDiagUtrd := FDiagUtrd * 0.95 + TimerSeconds(T1c, T0c) * 1000 * 0.05;
  { Body balance has now produced this frame's steering. Hands and the
    visible steerer must consume it in the same frame. }
  if not BikeDebugDisableSteer then DriveSteerNodes;
end;

function TBikeInstance.GetAnimDiag: String;
begin
  Result := Format(
    'comps=%.2f utrd=%.2f [apply=%.2f gpusend=%.2f ik=%.2f pedals=%.2f contacts=%.2f shdyn=%.2f]',
    [FDiagComps, FDiagUtrd, FDiagPoseApply, FDiagGpuSend, FDiagIK, FDiagPedals,
     FDiagContacts, FDiagShadowDyn]);
end;

procedure TBikeInstance.AnimateFrame(DeltaSec: Single);
begin
  if FAnimationEnabled then FAnimElapsed := FAnimElapsed + DeltaSec;
  { The absolute-time overload updates world light before its pose gate. }
  AnimateFrame(FAnimElapsed);
end;

function TBikeInstance.Component(AClass: TBikeComponentClass): TBikeComponent;
var I: Integer;
begin
  for I := 0 to High(FComponents) do
    if FComponents[I].ClassType = TClass(AClass) then
      Exit(FComponents[I]);
  Result := nil;
end;

function TBikeInstance.ComponentCount: Integer;
begin
  Result := Length(FComponents);
end;

function TBikeInstance.Component(Index: Integer): TBikeComponent;
begin
  if (Index >= 0) and (Index < Length(FComponents)) then
    Result := FComponents[Index]
  else
    Result := nil;
end;

function TBikeInstance.BarType: TBarType;
begin
  Result := ComponentsBarType(FComponents);
end;

procedure TBikeInstance.Build(const AComps: TBikeComponentClassArray;
  const AColors: TBikeColors;
  ADisabled: TStringList);
var
  Builder: TBikeBuilder;
  Root: TX3DRootNode;
  Sub: Integer;
  DisNames: TStringList;
begin
  Inc(FBuildDepth);
  try
  FColors := AColors;
  FDisabled := ADisabled;
  EnsureComponents(AComps);
  { CrankCycleInterval now lives on TAnimationComponent; read after
    EnsureComponents so the component is guaranteed to exist. }
  FBaseCrankCycle := AnimCrankCycleInterval;
  NotifyBuildBegin(-1);
  ResetFrameAnimCache;
  DisNames := TStringList.Create;
  try
    for Sub := 0 to BSG_COUNT - 1 do
    begin
      BuildDisabledForSub(Sub, AComps, ADisabled, DisNames);
      Builder := TBikeBuilder.CreateBorrowing(FComponents);
      try
        ApplyRuntimeFlagsToBuilder(Builder);
        Builder.Colors := AColors;
        Builder.DisabledNames.Assign(DisNames);
        Root := Builder.Build;
        { Скелет не зависит от Sub (Build всегда считает ВСЕ кости, disabled-
          список влияет только на геометрию) — захват + RebuildShadowStatic
          один раз на билд, а не на каждую под-сцену. }
        if Sub = 0 then
          CaptureSkeleton(Builder.Skeleton);   { retain anchors for the Tripo rider }
        FSubGroup[Sub].ClearChildren;
        FSubGroup[Sub].AddChildren(Root);
        if Sub = BSG_FRAME then ActivateFrameAnim;
        if Assigned(FOnSubSceneBuilt) then
          FOnSubSceneBuilt(Self, Sub, Builder);
        BuildYield;
      finally
        Builder.Free;
      end;
    end;
  finally
    DisNames.Free;
  end;
  FLastCompClasses := Copy(AComps);  { snapshot last — see RebuildSub note }
  finally Dec(FBuildDepth) end;
end;

procedure TBikeInstance.BuildWithLOD(const AComps: TBikeComponentClassArray;
  const AColors: TBikeColors;
  ADisabled: TStringList;
  LOD3Dist, LOD2Dist, LOD1Dist: Single);
var
  Builder: TBikeBuilder;
  Root: TX3DRootNode;
  LodNode: TLODNode;
  Sub, LOD, SavedDetail: Integer;
  DisNames: TStringList;
begin
  Inc(FBuildDepth);
  try
  FColors := AColors;
  FDisabled := ADisabled;
  EnsureComponents(AComps);
  FBaseCrankCycle := AnimCrankCycleInterval;
  NotifyBuildBegin(-1);
  ResetFrameAnimCache;
  SavedDetail := DetailLevel;
  DisNames := TStringList.Create;
  try
    for Sub := 0 to BSG_COUNT - 1 do
    begin
      BuildDisabledForSub(Sub, AComps, ADisabled, DisNames);

      { Create X3D LOD node with distance ranges }
      LodNode := TLODNode.Create;
      LodNode.FdRange.Items.Add(LOD3Dist);
      LodNode.FdRange.Items.Add(LOD2Dist);
      LodNode.FdRange.Items.Add(LOD1Dist);

      { Build 4 LOD levels as children (child 0 = nearest/most detail) }
      for LOD := 3 downto 0 do
      begin
        DetailLevel := LOD;
        Builder := TBikeBuilder.CreateBorrowing(FComponents);
        try
          ApplyRuntimeFlagsToBuilder(Builder);
          Builder.Colors := AColors;
          Builder.DisabledNames.Assign(DisNames);
          Root := Builder.Build;
          { как и в Build: скелет от Sub/LOD не зависит — захват один раз }
          if (Sub = 0) and (LOD = 3) then
            CaptureSkeleton(Builder.Skeleton);   { retain anchors for the Tripo rider }
          LodNode.AddChildren(Root);
          if (LOD = 3) and Assigned(FOnSubSceneBuilt) then
            FOnSubSceneBuilt(Self, Sub, Builder);
        finally
          Builder.Free;
        end;
        BuildYield;
      end;

      FSubGroup[Sub].ClearChildren;
      FSubGroup[Sub].AddChildren(LodNode);
      if Sub = BSG_FRAME then ActivateFrameAnim;
      BuildYield;
    end;
  finally
    DetailLevel := SavedDetail;
    DisNames.Free;
  end;
  FLastCompClasses := Copy(AComps);  { snapshot last — see RebuildSub note }
  finally Dec(FBuildDepth) end;
end;

procedure TBikeInstance.RebuildSub(Sub: Integer;
  const AComps: TBikeComponentClassArray;
  const AColors: TBikeColors;
  ADisabled: TStringList;
  PreserveAnim: Boolean);
var
  Builder: TBikeBuilder;
  Root: TX3DRootNode;
  DisNames: TStringList;
begin
  Inc(FBuildDepth);
  try
  FColors := AColors;
  FDisabled := ADisabled;
  EnsureComponents(AComps);
  if Sub = BSG_CRANK then
    FBaseCrankCycle := AnimCrankCycleInterval;
  NotifyBuildBegin(Sub, PreserveAnim);
  if Sub = BSG_FRAME then
    ResetFrameAnimCache;
  DisNames := TStringList.Create;
  try
    BuildDisabledForSub(Sub, AComps, ADisabled, DisNames);
    Builder := TBikeBuilder.CreateBorrowing(FComponents);
    try
      ApplyRuntimeFlagsToBuilder(Builder);
      Builder.Colors := AColors;
      Builder.DisabledNames.Assign(DisNames);
      Root := Builder.Build;
      CaptureSkeleton(Builder.Skeleton, not PreserveAnim);
      FSubGroup[Sub].ClearChildren;
      FSubGroup[Sub].AddChildren(Root);
      NotifyBuildComplete(Sub);
      if Sub = BSG_FRAME then ActivateFrameAnim;
    finally
      Builder.Free;
    end;
  finally
    DisNames.Free;
  end;
  { Snapshot AComps last — if the caller passed FLastCompClasses (e.g.
    via a RebuildSub that reuses the cached classes), updating it earlier
    would drop the last refcount and free the array mid-call, leaving
    AComps dangling through the BuildDisabledForSub / EnsureComponents
    reads above. }
  FLastCompClasses := Copy(AComps);
  finally Dec(FBuildDepth) end;
end;

function TBikeInstance.LastBuildColors: TBikeColors;
begin
  Result := FColors;
end;

{ ── cloth dye preset + live recolor рамы/ободьев ─────────────────────── }

procedure TBikeInstance.ApplyDyePresetToRider(R: TTripoRiderScene);
var
  S: TClothSlot;
begin
  if R = nil then Exit;
  { сеттеры не запекают вне загрузки (FDyeInLoad=False) — просто несём
    состояние; запечёт FinishLoadAfterGraph внутри LoadGlb/LoadPrepared }
  R.ClothDyeMode := FDyePresetMode;
  for S := Low(TClothSlot) to High(TClothSlot) do
  begin
    R.ClothColor[S] := FDyePresetColor[S];
    if FDyePresetActive[S] then
      R.StageClothColor(S, FDyePresetColor[S]);
  end;
end;

procedure TBikeInstance.StageRiderClothColor(Slot: TClothSlot; const C: TVector3);
begin
  FDyePresetColor[Slot] := C;
  FDyePresetActive[Slot] := True;
  if FTripoRider <> nil then
    FTripoRider.StageClothColor(Slot, C);
end;

procedure TBikeInstance.ClearRiderClothColor(Slot: TClothSlot);
begin
  FDyePresetActive[Slot] := False;
  if FTripoRider <> nil then
    FTripoRider.StageClearClothColor(Slot);
end;

procedure TBikeInstance.SetRiderClothColorLive(Slot: TClothSlot;
  const C: TVector3; Enabled: Boolean);
begin
  FDyePresetActive[Slot] := Enabled;
  if Enabled then FDyePresetColor[Slot] := C;
  if FTripoRider = nil then Exit;
  if Enabled then FTripoRider.SetClothColor(Slot, C)
  else FTripoRider.ClearClothColor(Slot);
end;

function TBikeInstance.RiderClothColor(Slot: TClothSlot): TVector3;
begin
  Result := FDyePresetColor[Slot];
end;

function TBikeInstance.RiderClothColorActive(Slot: TClothSlot): Boolean;
begin
  Result := FDyePresetActive[Slot];
end;

procedure TBikeInstance.GrabRecolorMat(Node: TX3DNode);
var
  M: TMaterialNode;
begin
  if not (Node is TMaterialNode) then Exit;
  M := TMaterialNode(Node);
  if (Abs(M.DiffuseColor.X - FRecolorOld.X) < 1e-3) and
     (Abs(M.DiffuseColor.Y - FRecolorOld.Y) < 1e-3) and
     (Abs(M.DiffuseColor.Z - FRecolorOld.Z) < 1e-3) then
    M.DiffuseColor := FRecolorNew;
end;

procedure TBikeInstance.RecolorMaterialsLive(const OldC, NewC: TVector3);
var
  I: Integer;
begin
  { Пешком по всем подграфам байка: FSubGroup — корневые трансформы частей
    (frame/wheels/crank/...). Материалы батчатся по точному цвету, так что
    совпадение по epsilon 1e-3 находит все копии. }
  FRecolorOld := OldC;
  FRecolorNew := NewC;
  for I := 0 to BSG_COUNT - 1 do
    if (FSubGroup[I] <> nil) and (FSubGroup[I] is TAbstractGroupingNode) then
      TAbstractGroupingNode(FSubGroup[I]).EnumerateNodes(
        TMaterialNode, @GrabRecolorMat, False);
end;

procedure TBikeInstance.SetFrameColorLive(const C: TVector3);
var
  Old: TVector3;
begin
  Old := FColors.Frame;
  FColors.Frame := C;   { чтобы Rebuild*/RebuildGroup держали новый цвет }
  if (Abs(Old.X - C.X) < 1e-4) and (Abs(Old.Y - C.Y) < 1e-4) and
     (Abs(Old.Z - C.Z) < 1e-4) then Exit;
  RecolorMaterialsLive(Old, C);
end;

procedure TBikeInstance.SetRimColorLive(const C: TVector3);
var
  Old: TVector3;
begin
  Old := FColors.Rim;
  FColors.Rim := C;
  if (Abs(Old.X - C.X) < 1e-4) and (Abs(Old.Y - C.Y) < 1e-4) and
     (Abs(Old.Z - C.Z) < 1e-4) then Exit;
  RecolorMaterialsLive(Old, C);
end;

function TBikeInstance.AdoptBuiltRider(NewRider: TTripoRiderScene;
  const AGlbPath: string): Boolean;
begin
  Result := AdoptLoadedRider(NewRider, AGlbPath);
end;

procedure TBikeInstance.RebuildAllWithLOD(LOD3Dist, LOD2Dist, LOD1Dist: Single);
var
  Comps: TBikeComponentClassArray;
begin
  if Length(FLastCompClasses) > 0 then
    Comps := FLastCompClasses
  else
    Comps := PrepareBuildComps(FPreset);
  BuildWithLOD(Comps, FColors, FDisabled, LOD3Dist, LOD2Dist, LOD1Dist);
end;

procedure TBikeInstance.RebuildGroup(Sub: Integer; PreserveAnim: Boolean);
begin
  if Length(FLastCompClasses) = 0 then Exit;
  RebuildSub(Sub, FLastCompClasses, FColors, FDisabled, PreserveAnim);
end;

procedure TBikeInstance.Clear;
var I: Integer;
begin
  FSteerNodesValid := False;
  if FSteerRots <> nil then FSteerRots.Clear;
  FSteerAxisCached := False;
  FPedNodesValid := False;
  FSpinNodesValid := False;
  FreeAndNil(FGpuSpin);
  for I := 0 to BSG_COUNT - 1 do
    FSubGroup[I].ClearChildren;
  if FShadowScene <> nil then
    FShadowScene.Exists := False;   { re-enabled by the next RebuildShadowStatic }
  { rig единой сцены (FShadowRigNode) переживает Clear — ApplyShadowMode им
    управляет; графы частей уже почищены выше. }
end;

{ Рекурсивно применить к ВСЕМ TimeSensor'ам с именем AName в подграфе.
  BuildWithLOD создаёт по экземпляру таймера на каждый LOD-уровень
  (4 шт.), и FindNode возвращает только первый (неактивного LOD) —
  активный LOD при этом крутится с дефолтным интервалом, а ноги
  райдера следуют первому найденному — рассинхрон. }
procedure ApplyToNamedTimeSensors(ANode: TX3DNode; const AName: string;
  Interval: Single; Enable: Boolean);
var
  J: Integer;
  TS: TTimeSensorNode;
begin
  if ANode = nil then Exit;
  if (ANode is TTimeSensorNode) and (ANode.X3DName = AName) then
  begin
    TS := TTimeSensorNode(ANode);
    if Enable then
    begin
      { CGE игнорирует запись CycleInterval у АКТИВНОГО TimeSensor'а
        (по X3D-спеке input в cycleInterval подавляется, пока сенсор
        активен — FdCycleInterval.OnInputIgnore = IgnoreWhenActive),
        а Enabled:=False применяется только на следующем каскаде
        событий — синхронно сенсор не выключить. Каденс меняется на
        ходу, а таймер создан Enabled=True и не выключается (игра шлёт
        9999 вместо Enabled=False) — поэтому интервал пишем НАПРЯМУЮ в
        поле, минуя input-игнор: FdCycleInterval.Value молча меняет
        FValue, и следующий SetTime сенсора уже считает фазу по
        новому периоду. Только при реальном изменении. }
      if Abs(TS.CycleInterval - Interval) > 0.001 then
        TS.FdCycleInterval.Value := Interval;
      TS.Enabled := True;
    end
    else
      TS.Enabled := False;
  end;
  if ANode is TAbstractGroupingNode then
    for J := 0 to TAbstractGroupingNode(ANode).FdChildren.Count - 1 do
      ApplyToNamedTimeSensors(TAbstractGroupingNode(ANode).FdChildren.Items[J],
        AName, Interval, Enable);
end;

procedure TBikeInstance.SetGpuAnim(V: Boolean);
var I: Integer;
begin
  if not FAnimationEnabled then
  begin
    FResumeGpuAnim := V;
    Exit;
  end;
  { Переключение GPU/CPU-пути на лету (MCP set_gpu_anim). При выключении
    GPU-пути эффект на шейпах райдера ОБЯЗАН быть отключён — иначе его
    дельта-домножение ляжет поверх живого CPU-скиннинга. При включении
    эффект просто возвращается; юниформы дошлёт ближайший SendFrame. }
  if FGpuAnim = V then Exit;
  FGpuAnim := V;
  if FGpuSkin <> nil then
    FGpuSkin.SetActive(V);
  if FGpuSpin <> nil then
    FGpuSpin.SetActive(V);   { этап 4: на CPU-пути вращают трансформы — эффекты гасим }
  if V then
  begin
    { этап 4: на GPU-пути spin-трансформы обязаны быть identity — их роль
      выполняет шейдер; на CPU-пути следующий DriveSpinNodesCPU сам перепишет. }
    if FSpinNodesValid then
    begin
      for I := 0 to FSpinCranks.Count - 1 do TTransformNode(FSpinCranks[I]).FdRotation.Send(Vector4(0, 0, 1, 0));
      for I := 0 to FSpinPedalR.Count - 1 do TTransformNode(FSpinPedalR[I]).FdRotation.Send(Vector4(0, 0, 1, 0));
      for I := 0 to FSpinPedalL.Count - 1 do TTransformNode(FSpinPedalL[I]).FdRotation.Send(Vector4(0, 0, 1, 0));
      for I := 0 to FSpinWheelR.Count - 1 do TTransformNode(FSpinWheelR[I]).FdRotation.Send(Vector4(0, 0, 1, 0));
      for I := 0 to FSpinWheelF.Count - 1 do TTransformNode(FSpinWheelF[I]).FdRotation.Send(Vector4(0, 0, 1, 0));
    end;
  end;
end;

procedure TBikeInstance.SetAnimationEnabled(V: Boolean);
begin
  if FAnimationEnabled = V then Exit;
  if not V then
  begin
    FResumeGpuAnim := FGpuAnim;
    SetGpuAnim(False);
    { Evaluate and bake the current pose once. While paused, neither the
      procedural IK/spin effects nor native skinning run in vertex shaders. }
    if FTripoRider <> nil then
    begin
      UpdateTripoRider(FTripoPrevElapsed);
      FResumeSkinShaders := FTripoRider.Scene.RenderOptions.SkinnedAnimationShaders;
      FTripoRider.SetSkinnedAnimationShaders(False);
    end;
    if FBikeScene <> nil then
    begin
      FResumeBikeTimeSpeed := FBikeScene.TimePlayingSpeed;
      FBikeScene.TimePlayingSpeed := 0;
    end;
    if (FTripoRider <> nil) and (FTripoRider.Scene <> FBikeScene) then
    begin
      FResumeRiderTimeSpeed := FTripoRider.Scene.TimePlayingSpeed;
      FTripoRider.Scene.TimePlayingSpeed := 0;
    end;
    FAnimationEnabled := False;
    if FBodyDynamicsEnabled then begin
      FPedalLeanDeg:=0;DrivePedalLean;
    end;
  end
  else
  begin
    FAnimationEnabled := True;
    if FBikeScene <> nil then FBikeScene.TimePlayingSpeed := FResumeBikeTimeSpeed;
    if (FTripoRider <> nil) and (FTripoRider.Scene <> FBikeScene) then
      FTripoRider.Scene.TimePlayingSpeed := FResumeRiderTimeSpeed;
    FPhaseStarted := False;
    if FTripoRider <> nil then
      FTripoRider.SetSkinnedAnimationShaders(FResumeSkinShaders);
    SetGpuAnim(FResumeGpuAnim);
  end;
end;

procedure TBikeInstance.SetAnimationSpeed(CrankInterval, WheelInterval: Single);
begin
  { GPU-анимация, этап 1: метод только ЗАПОМИНАЕТ параметры — накопитель
    фазы в AnimateFrame читает их. WheelInterval раньше игнорировался
    (колёса держали встроенные 2.0 с/об); теперь запоминаем и его — для
    GPU-пути. При GpuAnim=False визуально ничего не меняется. }
  FCrankIntervalCur := CrankInterval;
  if WheelInterval > 0.001 then FWheelIntervalCur := WheelInterval;
  if FGpuAnim then Exit;   { TimeSensor'ов нет (этап 4) — больше ничего не нужно }
  { Единая сцена: TimePlayingSpeed больше не делить по подсценам — управляем
    самим CrankTimer'ом (CycleInterval = желаемый период, Enabled = стоп).
    ВСЕМ экземплярам (по одному на LOD-уровень). }
  if (FBikeScene = nil) or (FBikeScene.RootNode = nil) then Exit;
  ApplyToNamedTimeSensors(FBikeScene.RootNode, 'CrankTimer',
    CrankInterval, CrankInterval > 0.01);
end;

function TBikeInstance.IsFixedGear: Boolean;
var D: TDrivetrainComponent;
begin
  D := TDrivetrainComponent(Component(TDrivetrainComponent));
  Result := (D <> nil) and D.FixedGear;
end;

function TBikeInstance.DriveMetresPerCrankRevolution: Single;
var W: TWheelComponent; C: TCranksetComponent; D: TDrivetrainComponent;
  RadiusM: Single;
begin
  Result := 5.5; { preview development for bicycles with selectable gears }
  if not IsFixedGear then Exit;
  C := TCranksetComponent(Component(TCranksetComponent));
  D := TDrivetrainComponent(Component(TDrivetrainComponent));
  if (C = nil) or (C.ChainringTeeth < 1) or (D.CassetteTeeth[0] < 1) then Exit;
  W := TWheelComponent(Component(TWheelComponent));
  RadiusM := WHEEL_RADIUS_FALLBACK_M;
  if (W <> nil) and (W.WheelRadius > 1) then RadiusM := W.WheelRadius / 1000;
  Result := 2 * Pi * RadiusM * C.ChainringTeeth / D.CassetteTeeth[0];
end;

function TBikeInstance.VisualCadence(SensorCadence, SpeedMps: Single): Single;
begin
  Result := Max(0, SensorCadence);
  { Only the visual drive uses this estimate. Never publish it as sensor data. }
  if (Result <= 0) and IsFixedGear then
    Result := Max(0, SpeedMps) * 60 / DriveMetresPerCrankRevolution;
end;

procedure TBikeInstance.SetWheelSpeedMps(SpeedMps: Single);
var
  W: TWheelComponent;
  radiusM, circumM: Single;
begin
  FForwardSpeedMps:=Max(SpeedMps,0);
  { То же для колёс: период одного оборота = длина окружности / скорость.
    ВСЕМ экземплярам WheelTimer (по одному на LOD-уровень). }

  if SpeedMps <= 0.02 then
  begin
    FWheelIntervalCur := 0;   { zero speed -> wheels frozen (GPU-фаза стоит) }
    if (not FGpuAnim) and (FBikeScene <> nil) and (FBikeScene.RootNode <> nil) then
      ApplyToNamedTimeSensors(FBikeScene.RootNode, 'WheelTimer', 0, False);
    Exit;
  end;

  radiusM := WHEEL_RADIUS_FALLBACK_M;      { ~700c fallback if no wheel component found }
  W := TWheelComponent(Component(TWheelComponent));
  if (W <> nil) and (W.WheelRadius > 1.0) then
    radiusM := W.WheelRadius / 1000.0;   { mm -> m }

  circumM := 2.0 * Pi * radiusM;
  if circumM < 1E-3 then Exit;
  FWheelIntervalCur := circumM / SpeedMps;           { seconds per revolution }
  if FGpuAnim then Exit;
  if (FBikeScene = nil) or (FBikeScene.RootNode = nil) then Exit;
  ApplyToNamedTimeSensors(FBikeScene.RootNode, 'WheelTimer',
    FWheelIntervalCur, True);
end;

function TBikeInstance.SubScene(Idx: Integer): TCastleScene;
begin
  if (Idx >= 0) and (Idx < BSG_COUNT) then
    Result := FBikeScene
  else Result := nil;
end;

function TBikeInstance.ActiveShapeCount: Integer;
begin
  Result := 0;
  if (FBikeScene <> nil) and FBikeScene.Exists then
    Result := FBikeScene.ShapesActiveCount;
end;

function TBikeInstance.AnimDebugJson: TJSONObject;

  procedure CollectNamedSensors(ANode: TX3DNode; const AName: string;
    Arr: TJSONArray);
  var
    J: Integer;
    TS: TTimeSensorNode;
    O: TJSONObject;
  begin
    if ANode = nil then Exit;
    if (ANode is TTimeSensorNode) and (ANode.X3DName = AName) then
    begin
      TS := TTimeSensorNode(ANode);
      O := TJSONObject.Create;
      O.Add('enabled', TS.Enabled);
      O.Add('active', TS.IsActive);
      O.Add('cycle_interval', TS.CycleInterval);
      O.Add('elapsed_in_cycle', TS.ElapsedTimeInCycle);
      Arr.Add(O);
    end;
    if ANode is TAbstractGroupingNode then
      for J := 0 to TAbstractGroupingNode(ANode).FdChildren.Count - 1 do
        CollectNamedSensors(TAbstractGroupingNode(ANode).FdChildren.Items[J],
          AName, Arr);
  end;

var
  Arr: TJSONArray;
  T: TTimeSensorNode;
begin
  Result := TJSONObject.Create;
  if FBikeScene = nil then
  begin
    Result.Add('error', 'FBikeScene is nil');
    Exit;
  end;
  Result.Add('scene_exists', FBikeScene.Exists);
  Result.Add('scene_process_events', FBikeScene.ProcessEvents);
  Result.Add('scene_time_playing_speed', FBikeScene.TimePlayingSpeed);
  if FBikeScene.RootNode = nil then
  begin
    Result.Add('error', 'FBikeScene.RootNode is nil');
    Exit;
  end;
  { Тот путь, которым райдер читает фазу (FindNode — первый попавшийся). }
  T := FBikeScene.RootNode.FindNode(TTimeSensorNode, 'CrankTimer',
    [fnNilOnMissing]) as TTimeSensorNode;
  Result.Add('find_node_cranktimer', T <> nil);
  Arr := TJSONArray.Create;
  CollectNamedSensors(FBikeScene.RootNode, 'CrankTimer', Arr);
  Result.Add('crank_timers', Arr);
  Arr := TJSONArray.Create;
  CollectNamedSensors(FBikeScene.RootNode, 'WheelTimer', Arr);
  Result.Add('wheel_timers', Arr);
  Result.Add('phase', FPhase);
  Result.Add('wheel_phase', FWheelPhase);
  Result.Add('accum_time', FAccumTime);
  Result.Add('crank_interval_cur', FCrankIntervalCur);
  Result.Add('wheel_interval_cur', FWheelIntervalCur);
  Result.Add('fixed_gear', IsFixedGear);
  Result.Add('forward_speed_mps', FForwardSpeedMps);
  Result.Add('drive_metres_per_crank_rev', DriveMetresPerCrankRevolution);
  Result.Add('gpu_anim', FGpuAnim);
  Result.Add('animation_enabled', FAnimationEnabled);
  if FTripoRider <> nil then
  begin
    Result.Add('pose_correctives_ready', (FTripoRider.Correctives <> nil) and
      FTripoRider.Correctives.Ready);
    Result.Add('native_skinning_shaders', FTripoRider.Scene.RenderOptions.SkinnedAnimationShaders);
    if FTripoRider.SkinNode <> nil then
      Result.Add('native_skinning_mode', Ord(FTripoRider.SkinNode.InternalMeshCalculation));
  end;
  Result.Add('gpu_skin_active', (FGpuSkin <> nil) and FGpuSkin.Active);
  if FGpuSpin <> nil then
    Result.Add('gpu_spin_active_effects', FGpuSpin.ActiveEffectCount)
  else
    Result.Add('gpu_spin_active_effects', 0);
  Result.Add('gpu_spin_ready', (FGpuSpin <> nil) and FGpuSpin.Ready);
  Result.Add('gpu_skin_built', FGpuSkin <> nil);
  Result.Add('gpu_skin_effect_scene', (FGpuSkin <> nil) and FGpuSkin.EffectSceneAssigned);
  Result.Add('diag', GetAnimDiag);
  Result.Add('timing_ms',TJSONObject.Create(['components',FDiagComps,
    'rider_total',FDiagUtrd,'pose_apply',FDiagPoseApply,'gpu_send',FDiagGpuSend,
    'native_ik',FDiagIK,'pedals',FDiagPedals,'contacts',FDiagContacts,'capsule_shadow',FDiagShadowDyn]));
  { Light steer snapshot (no full scene walk). }
  Result.Add('steer_disable', BikeDebugDisableSteer);
  Result.Add('steer_angle_deg', FSteerAngleDeg);
  Result.Add('steer_mesh_deg', MeshSteerAngleDeg);
  Result.Add('steer_applied_deg', FSteerAngleApplied);
  if FSteerNodesValid and (FSteerRots <> nil) then
    Result.Add('steer_rot_count', FSteerRots.Count)
  else
    Result.Add('steer_rot_count', 0);
  if FSteerNodesValid and (FSteerRots <> nil) and (FSteerRots.Count > 0) and
     (TTransformNode(FSteerRots[0]) <> nil) then
    Result.Add('steer_node0_rot_w_deg',
      RadToDeg(TTransformNode(FSteerRots[0]).Rotation.W));
end;

function TBikeInstance.WheelsDebugJson: TJSONObject;

  function Vec3Str(const V: TVector3): String;
  begin
    Result := Format('%.4f, %.4f, %.4f', [V.X, V.Y, V.Z]);
  end;

  function BoxStr(const BB: TBox3D): String;
  begin
    if BB.IsEmpty then
      Result := 'EMPTY'
    else
      Result := Format('(%.3f,%.3f,%.3f)-(%.3f,%.3f,%.3f)',
        [BB.Data[0].X, BB.Data[0].Y, BB.Data[0].Z,
         BB.Data[1].X, BB.Data[1].Y, BB.Data[1].Z]);
  end;

  { Шейпы поддерева: число + уникальные appearance'ы с их эффектами +
    union bbox геометрии (в координатах геометрии, без трансформов). }
  procedure ShapeInfo(N: TX3DNode; var Count: Integer; Apps: Classes.TList;
    State: TX3DGraphTraverseState; var BB: TBox3D);
  var
    I: Integer;
    Sh: TShapeNode;
  begin
    if N = nil then Exit;
    if N is TShapeNode then
    begin
      Inc(Count);
      Sh := TShapeNode(N);
      if (Sh.Appearance <> nil) and (Apps.IndexOf(Sh.Appearance) < 0) then
        Apps.Add(Sh.Appearance);
      if Sh.Geometry <> nil then
        BB.Include(Sh.Geometry.LocalBoundingBox(State, nil, nil));
    end;
    if N is TAbstractGroupingNode then
      for I := 0 to TAbstractGroupingNode(N).FdChildren.Count - 1 do
        ShapeInfo(TAbstractGroupingNode(N).FdChildren[I], Count, Apps, State, BB);
  end;

  procedure CollectSpin(N: TX3DNode; Arr: TJSONArray);
  var
    I, J, Count: Integer;
    T: TTransformNode;
    O, EO: TJSONObject;
    Apps: Classes.TList;
    EA: TJSONArray;
    App: TAppearanceNode;
    State: TX3DGraphTraverseState;
    BB: TBox3D;
  begin
    if N = nil then Exit;
    if (N is TTransformNode) and
       ((N.X3DName = 'RearWheelRot') or (N.X3DName = 'FrontWheelRot') or
        (N.X3DName = 'CranksRot') or
        (N.X3DName = 'PedalRightRot') or (N.X3DName = 'PedalLeftRot')) then
    begin
      T := TTransformNode(N);
      O := TJSONObject.Create;
      O.Add('name', N.X3DName);
      O.Add('translation', Vec3Str(T.Translation));
      O.Add('rotation', Format('%.3f, %.3f, %.3f, %.4f',
        [T.Rotation.X, T.Rotation.Y, T.Rotation.Z, T.Rotation.W]));
      O.Add('scale', Vec3Str(T.Scale));
      Count := 0;
      BB := TBox3D.Empty;
      Apps := Classes.TList.Create;
      State := TX3DGraphTraverseState.Create;
      try
        ShapeInfo(N, Count, Apps, State, BB);
        O.Add('shape_count', Count);
        O.Add('geometry_bbox', BoxStr(BB));
        EA := TJSONArray.Create;
        for J := 0 to Apps.Count - 1 do
        begin
          App := TAppearanceNode(Apps[J]);
          EO := TJSONObject.Create;
          EO.Add('effects_count', App.FdEffects.Count);
          for I := 0 to App.FdEffects.Count - 1 do
            if App.FdEffects[I] is TEffectNode then
              EO.Add(Format('eff%d', [I]),
                TEffectNode(App.FdEffects[I]).X3DName + ':' +
                BoolToStr(TEffectNode(App.FdEffects[I]).Enabled, True));
          EA.Add(EO);
        end;
        O.Add('appearances', EA);
      finally
        State.Free;
        Apps.Free;
      end;
      Arr.Add(O);
    end;
    if N is TAbstractGroupingNode then
      for I := 0 to TAbstractGroupingNode(N).FdChildren.Count - 1 do
        CollectSpin(TAbstractGroupingNode(N).FdChildren[I], Arr);
  end;

  { Число шейпов с 'WheelRot' в имени в списке (nil-safe). }
  function CountShapesNamed(L: TShapeList): Integer;
  var
    Sh: TShape;
  begin
    Result := 0;
    if L = nil then Exit;
    for Sh in L do
      if Pos('WheelRot', Sh.NiceName) > 0 then
        Inc(Result);
  end;

  { Флаги колёсных шейпов в рендер-листе: Visible/ShadowCaster/bbox. }
  function WheelShapeFlagsJson(L: TShapeList): TJSONArray;
  var
    Sh: TShape;
    O: TJSONObject;
  begin
    Result := TJSONArray.Create;
    if L = nil then Exit;
    for Sh in L do
      if Pos('WheelRot', Sh.NiceName) > 0 then
      begin
        O := TJSONObject.Create;
        O.Add('name', Sh.NiceName);
        if Sh.Node <> nil then
          O.Add('node_visible', Sh.Node.Visible)
        else
          O.Add('node_visible', 'nil');
        O.Add('shadow_caster', Sh.ShadowCaster);
        O.Add('bbox', BoxStr(Sh.BoundingBox));
        Result.Add(O);
      end;
  end;

var
  Arr: TJSONArray;
  I: Integer;
  O: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('gpu_anim', FGpuAnim);
  Result.Add('phase', FPhase);
  Result.Add('wheel_phase', FWheelPhase);
  if FGroup <> nil then
  begin
    Result.Add('group_exists', FGroup.Exists);
    Result.Add('group_translation', Vec3Str(FGroup.Translation));
  end;
  if FBikeContainer <> nil then
    Result.Add('bike_container_translation', Format('%.4f, %.4f, %.4f',
      [FBikeContainer.Matrix[3, 0], FBikeContainer.Matrix[3, 1],
       FBikeContainer.Matrix[3, 2]]));
  if FBikeScene <> nil then
  begin
    Result.Add('scene_exists', FBikeScene.Exists);
    Result.Add('scene_translation', Vec3Str(FBikeScene.Translation));
    Result.Add('scene_scale', Vec3Str(FBikeScene.Scale));
    Result.Add('scene_bbox_local', BoxStr(FBikeScene.BoundingBox));
    Result.Add('scene_bbox_world', BoxStr(FBikeScene.WorldBoundingBox));
    Arr := TJSONArray.Create;
    if FBikeScene.RootNode <> nil then
      CollectSpin(FBikeScene.RootNode, Arr);
    Result.Add('spin_transforms', Arr);
    { Колёсные шейпы в списках рендера: все (false,false) vs
      активные+видимые (true,true) — если в (true,true) пропадают,
      рендер их не итерирует вовсе. }
    Result.Add('shapes_wheel_all', CountShapesNamed(FBikeScene.Shapes.TraverseList(False, False)));
    Result.Add('shapes_wheel_active', CountShapesNamed(FBikeScene.Shapes.TraverseList(True, True)));
    Result.Add('wheel_shape_flags', WheelShapeFlagsJson(FBikeScene.Shapes.TraverseList(True, True)));
  end;
  Result.Add('scene_ptr', Integer(PtrUInt(FBikeScene)));
  if FGpuSpin <> nil then
    Result.Add('gpu_spin', FGpuSpin.DebugJson)
  else
    Result.Add('gpu_spin', 'nil');
end;

function TBikeInstance.RiderScene: TCastleScene;
begin
  Result := FBikeScene;   { единая сцена: райдер внутри общего графа }
end;

procedure TBikeInstance.CaptureSkeleton(ASkel: TBikeSkeleton; RebuildShadow: Boolean);
var I: Integer; B: TBikeBone;
begin
  FreeAndNil(FBikeSkeleton);
  FBikeSkeleton := TBikeSkeleton.Create;
  if ASkel = nil then Exit;
  for I := 0 to ASkel.BoneCount - 1 do
  begin
    B := ASkel.GetBoneByIndex(I);
    FBikeSkeleton.AddBone(B.Name, B.Pos);
  end;
  { every build path (Build / BuildWithLOD / RebuildSub) captures the skeleton
    here, so this is the single hook that keeps the contact shadow matched to
    the current geometry (wheelbase, wheel radius, bar position, ...). }
  if RebuildShadow then
    RebuildShadowStatic;
end;

function TBikeInstance.HasTripoRider: Boolean;
begin
  Result := (FTripoRider <> nil) and FTripoRider.Loaded;
end;

function TBikeInstance.LoadTripoRider(const AGlbPath: string; ALog: TStrings): Boolean;
var
  NewRider: TTripoRiderScene;
begin
  Result := False;
  FTripoRiderError := '';
  NewRider := TTripoRiderScene.Create;
  ApplyDyePresetToRider(NewRider);   { цвета одежды — до запечки при загрузке }
  if not NewRider.LoadGlb(AGlbPath, ALog) then
  begin
    FTripoRiderError := NewRider.LastError;
    NewRider.Free;
    Exit;
  end;
  Result := AdoptLoadedRider(NewRider, AGlbPath);
end;

function TBikeInstance.LoadTripoRiderPrepared(APrep: TTripoGlbPrepared): Boolean;
var
  NewRider: TTripoRiderScene;
begin
  Result := False;
  FTripoRiderError := '';
  if APrep = nil then Exit;
  NewRider := TTripoRiderScene.Create;
  ApplyDyePresetToRider(NewRider);   { цвета одежды — до запечки при загрузке }
  if not NewRider.LoadPrepared(APrep) then
  begin
    FTripoRiderError := NewRider.LastError;
    NewRider.Free;
    Exit;
  end;
  Result := AdoptLoadedRider(NewRider, APrep.Path);
end;

function TBikeInstance.AdoptLoadedRider(NewRider: TTripoRiderScene;
  const AGlbPath: string): Boolean;
var
  TD0: QWord;
begin
  Result := False;
  if (NewRider = nil) or (not NewRider.Loaded) then Exit;
  if FTripoRider <> nil then
  begin
    { Disable GPU plug, drop the wrapper. The TEffectNode stays on the
      old appearances and dies with FreeAndNil(FTripoRider) below. }
    InvalidateGpuRiderSkin;
    { Старая сцена райдера — текущая рендер-сцена: снимаем её с вьюпорта и
      отцепляем байк-контейнер ДО уничтожения — сцена владеет графом и
      убьёт наши FSubGroup[i] вместе с собой. }
    if FTripoRider.Scene <> nil then
    begin
      FGroup.Remove(FTripoRider.Scene);
      if FTripoRider.Scene.RootNode <> nil then
      begin
        if (FBikeContainer <> nil)
           and (FTripoRider.Scene.RootNode.FdChildren.IndexOf(FBikeContainer) >= 0) then
          FTripoRider.Scene.RootNode.RemoveChildren(FBikeContainer);
        if (FVisSwitch <> nil)
           and (FTripoRider.Scene.RootNode.FdChildren.IndexOf(FVisSwitch) >= 0) then
          FTripoRider.Scene.RootNode.RemoveChildren(FVisSwitch);  { умрёт со старым glb-графом }
      end;
    end;
    if FBikeContainer<>nil then FBikeContainer.UnregisterScene;
    FVisSwitch := nil;               { умрёт вместе с графом старой сцены }
    FreeAndNil(FTripoRider);
    FBikeScene := nil;               { висячие до MountBikeIntoRider }
    FMainRoot  := nil;
  end;
  FTripoRider := NewRider;
  FTripoRider.OcclusionJointQuery:=@RiderJointPos;
  FTripoRider.ClothingSkinQuery:=@RiderClothingSkin;
  if (not FBodyParametersSet) and NewRider.HasParametricBody then
    FBodyParameters:=NewRider.BodyParameters;
  FTripoFitScale := 0.0;             { new rig → re-fit size once on next placement }
  FTripoRiderPath := AGlbPath;        { remember for JSON save/load }
  if not FHelmetPitchFromJson then
    FHelmetPitchX := NewRider.HelmetPitchXDeg;
  { ПЕРЕВОРОТ: байк-части переезжают в сцену райдера (FBikeContainer с
    матрицей P^-1), рендерится сцена райдера. Риг работает в родной сцене
    с внешним (scene-level) трансформом — как в двух-сценном коде. }
  TD0 := GetTickCount64;
  MountBikeIntoRider;
  StartupLog(Format('[dye] adopt: MountBikeIntoRider %d ms', [GetTickCount64 - TD0]));
  TD0 := GetTickCount64;
  ApplyTripoBodyShape;               { FIRST: push body-shape + limb lengths onto the
                                       rig; ApplyLimbLengths bakes the contact markers
                                       against the FINAL geometry. Must precede the
                                       first pose so the seat below uses real contacts. }
  StartupLog(Format('[dye] adopt: ApplyTripoBodyShape %d ms', [GetTickCount64 - TD0]));
  TD0 := GetTickCount64;
  UpdateTripoRider(0);               { now seat/pose with contacts at final proportions }
  StartupLog(Format('[dye] adopt: UpdateTripoRider %d ms', [GetTickCount64 - TD0]));

  { if engine shadows are already active, the newly-mounted rider must join
    the caster set (EnsureShadowMapLight only saw the scenes present then) }
  FShadowRiderScale := 0;   { new model -> re-measure capsule scale on next update }

  if (FShadowMode = bsmCGE) and (FShadowMapLight <> nil)
     and (FTripoRider.Scene <> nil) then
  begin
    FTripoRider.Scene.CastShadows := True;
    FTripoRider.Scene.RenderOptions.WholeSceneManifold := True;
  end;

  Result := True;
end;

function TBikeInstance.ShadowRigHost: TAbstractGroupingNode;
begin
  { rig всегда в своей сцене — при перевороте байка в сцену райдера он
    больше не переезжает (это и снимает зависимость от P^-1 контейнера) }
  Result := FShadowRigRoot;
end;

procedure TBikeInstance.MountBikeIntoRider;
var
  I: Integer;
  Root: TX3DRootNode;
  Ch: TAbstractChildNode;
  VisGroup: TGroupNode;
begin
  if (FTripoRider = nil) or (FTripoRider.Scene = nil) then Exit;
  { Both sides of the reparent: CGE checks InternalNodeSharing on Self
    AND on Node.Scene (see TCastleSceneCore.ChangedAllEnumerateCallback). }
  if FBikeScene <> nil then
    FBikeScene.InternalNodeSharing := True;
  FTripoRider.Scene.InternalNodeSharing := True;
  Root := FTripoRider.Scene.RootNode;
  if Root = nil then Exit;

  { Байк-части (FSubGroup[i], теневой rig) и ВЕСЬ контент, добавленный
    приложением в SubScene(i).RootNode после сборки (пол, света и т.п.), —
    из прежнего корня в контейнер. СНАЧАЛА добавить нового родителя, потом
    убрать старого — иначе RemoveChildren оставляет узел без родителей и
    CGE его уничтожает (FreeIfUnused). Legacy-обёртка FTripoSwitch остаётся
    boot-сцене. При перезагрузке райдера FMainRoot = nil: контейнер уже
    собран и просто пересаживается на новый корень. }
  if FBikeContainer = nil then
  begin
    FBikeContainer := TMatrixTransformNode.Create;
    FBikeContainer.X3DName := 'BikeFrame';
    { контейнер переживает смену райдера: на RemoveChildren со старого
      корня узел без родителей CGE уничтожает (FreeIfUnused) }
    FBikeContainer.KeepExistingBegin;
  end;
  if FMainRoot <> nil then
  begin
    I := 0;
    while I < FMainRoot.FdChildren.Count do
    begin
      Ch := FMainRoot.FdChildren.Items[I] as TAbstractChildNode;
      if Ch = FTripoSwitch then Inc(I)
      else
      begin
        FBikeContainer.AddChildren(Ch);
        FMainRoot.RemoveChildren(Ch);
      end;
    end;
  end;

  { Видимость райдера: glb-контент под switch (аналог Scene.Exists).
    ВАЖНО: локальные fill-света (RiderKey/RiderFill*, Global=False) ОСТАЮТСЯ
    прямыми детьми Root. Раньше каждый child Root (включая света) становился
    отдельным choice у TSwitch — активен только WhichChoice=0, поэтому
    света на inactive-слотах не освещали меш → сильное затенение с тёмных
    ракурсов (PBR без ambient, только world-sun). }
  FVisSwitch := TSwitchNode.Create;
  FVisSwitch.X3DName := 'RiderVis';
  if FTripoShowRider then FVisSwitch.WhichChoice := 0
  else FVisSwitch.WhichChoice := -1;
  VisGroup := TGroupNode.Create;
  VisGroup.X3DName := 'RiderVisContent';
  I := 0;
  while I < Root.FdChildren.Count do
  begin
    Ch := Root.FdChildren.Items[I] as TAbstractChildNode;
    if (Ch is TAbstractLightNode) and
       not (Ch is TEnvironmentLightNode) then
      Inc(I)   { keep punctual lights on Root — light siblings of the switch.
                 EnvironmentLight идёт ВМЕСТЕ с контентом райдера: на Root его
                 ambient подсветил бы и catcher-квад (Phong), ослабив тень под
                 байком (catcher конвертирует освещённость в альфу). Внутри
                 RiderVisContent он светит только glb райдера. }
    else
    begin
      VisGroup.AddChildren(Ch);   { сначала новый родитель, потом снять старый }
      Root.RemoveChildren(Ch);
      { do not Inc I: next child slid into this slot }
    end;
  end;
  FVisSwitch.AddChildren(VisGroup);
  Root.AddChildren(FVisSwitch);
  if not FOnFoot then Root.AddChildren(FBikeContainer);

  { Сцена райдера становится рендер-сценой — с теми же настройками, что
    были у конструкторской сцены байка. Collides/Pickable копируем со
    старой сцены: иначе у новой дефолтный Collides=True, рэйкаст колёс
    попадает в геометрию байка и аватар висит в воздухе. }
  if FBikeScene <> nil then
  begin
    FTripoRider.Scene.Collides := FBikeScene.Collides;
    FTripoRider.Scene.Pickable := FBikeScene.Pickable;
    if FBikeScene <> FTripoRider.Scene then
      FGroup.Remove(FBikeScene);
  end;
  FTripoRider.Scene.ProcessEvents := True;
  FTripoRider.Scene.CastGlobalLights := True;
  FTripoRider.Scene.ShadowMapsDefaultSize := 1024;
  FGroup.Add(FTripoRider.Scene);
  if SceneLifecycleLogEnabled then SceneLifecycleLog(Format(
    'BIKE-ASM tripomount inst=$%p riderscene=$%p oldbikescene=$%p groupkids=%d',
    [Pointer(Self), Pointer(FTripoRider.Scene), Pointer(FBikeScene),
     FGroup.Count]));
  FBikeScene := FTripoRider.Scene;
  FPedNodesValid := False;   { OPT: корень сменился — кэш педалей перечитать }
  { SteerRot nodes moved under BikeFrame in the rider scene — old FSteerRots
    pointers / Valid flag are stale (or pointed at the boot scene). Re-collect
    and force a mesh angle write so the avatar's fork actually turns (bots
    that never re-mount kept working). }
  FSteerNodesValid := False;
  FSteerAxisCached := False;
  FSteerAngleApplied := -9999;
  FMainRoot  := Root;
  { rig вернётся в граф под новым хостом, если режим требует }
  ApplyShadowMode;
end;

function TBikeInstance.LoadTripoRiderFromSection(O: TJSONObject; Prepared: TTripoGlbPrepared): Boolean;
var
  D: TJSONData;
  Ang: TJSONArray;
  i: Integer;
  Path: string;
begin
  Result := False;
  if O = nil then Exit;

  { placement / orientation / drive — read by UpdateTripoRider each frame,
    so set BEFORE mounting the glb (LoadTripoRider seats it immediately) }
  TripoRiderScale    := O.Get('scale', Double(1.0));
  TripoRiderYawDeg   := O.Get('yaw', Double(0));
  TripoPedalDir      := O.Get('pedalDir', Double(-1));
  TripoShowRider     := O.Get('showRider', True);
  TripoAnkleOffset   := Vector3(O.Get('ankleOffX', Double(0)),
                                O.Get('ankleOffY', Double(0)),
                                O.Get('ankleOffZ', Double(0)));
  TripoStanceHalf    := O.Get('stanceHalf', Double(0));
  TripoFootYawDeg    := O.Get('footYawDeg', Double(0));
  { NOTE: posture, motion (sway/bob), seat offset, hands and legs now live ONLY in the
    pose presets (RiderPoseCatalog.pas) — they are NOT read from the bike file. The Default
    pose supplies their startup values (see TBikeInstance.Create / the Poses tab). }

  { body shape (mesh) + skeleton proportions. The skeleton values are DIRECT
    scale coefficients (1 = unchanged); 0 in old files is treated as 1. }
  TripoBulk          := O.Get('bulk', Double(0));
  TripoBelly         := O.Get('belly', Double(0));
  TripoBodyHeight    := O.Get('heightScale', Double(0));
  TripoLegLen        := O.Get('legLen', Double(1.0));
  TripoArmLen        := O.Get('armLen', Double(1.0));
  TripoShoulderWidth := O.Get('shoulderWidth', Double(1.0));
  TripoPelvisWidth   := O.Get('pelvisWidth', Double(1.0));
  TripoTorsoLen      := O.Get('torsoLen', Double(1.0));
  TripoRoughness     := O.Get('roughnessK', Double(1.0));
  TripoMetallic      := O.Get('metallicK', Double(1.0));
  HelmetColor   := O.Get('helmetColor', '');
  D := O.Find('helmetPitchX');
  if (D <> nil) and (D.JSONType = jtNumber) then
  begin
    FHelmetPitchX := D.AsFloat;
    FHelmetPitchFromJson := True;
  end
  else
    FHelmetPitchFromJson := False;

  Path := '';
  D := O.Find('path');
  if (D <> nil) and (D.JSONType = jtString) then Path := D.AsString;
  StageBodyParameters(O,Path);
  if Trim(Path) = '' then Exit;   { no rider configured — leave bike riderless }

  if Prepared<>nil then Result:=LoadTripoRiderPrepared(Prepared)
  else Result := LoadTripoRider(Path);

  { The editor stores the glb path exactly as picked on ITS machine — often
    an absolute OS path. A bike JSON that TRAVELS (relay guests receiving
    another player's config, bots built from bundled configs) then fails the
    FileExists check on this machine and the bike silently loses its rider.
    Retry against bundled avatars (MEN.glb / FEM.glb live in data/avatars/). }
  if not Result then
  begin
    StartupLog('[TripoRider] load failed path=' + Path + ' err=' + FTripoRiderError);
    Path := ExtractFileName(StringReplace(Path, '/', PathDelim, [rfReplaceAll]));
    if Path <> '' then
    begin
      Path := ResolveGlbFilesystemPath('castle-data:/avatars/' + Path);
      StartupLog('[TripoRider] retrying bundled: ' + Path);
      Result := LoadTripoRider(Path);
    end;
  end;
end;

procedure TBikeInstance.SetHeadwearColorLive(const Color:TVector3;Enabled:Boolean);
begin
  if Enabled then
    FHelmetColor:=IntToHex(EnsureRange(Round(Color.X*255),0,255),2)+
      IntToHex(EnsureRange(Round(Color.Y*255),0,255),2)+
      IntToHex(EnsureRange(Round(Color.Z*255),0,255),2)
  else FHelmetColor:='';
  ApplyHelmetTint;
end;

procedure TBikeInstance.ApplyHelmetTint;

  function HexDigit(Ch: Char; out V: Integer): Boolean;
  begin
    Result := True;
    case Ch of
      '0'..'9': V := Ord(Ch) - Ord('0');
      'a'..'f': V := Ord(Ch) - Ord('a') + 10;
      'A'..'F': V := Ord(Ch) - Ord('A') + 10;
      else begin V := 0; Result := False; end;
    end;
  end;

  function ParseHexColor(S: string; out C: TVector3): Boolean;
  var Hi, Lo, I: Integer; B: array[0..2] of Integer;
  begin
    Result := False;
    S := Trim(S);
    if (S <> '') and (S[1] in ['#', '$']) then Delete(S, 1, 1);
    if Length(S) <> 6 then Exit;
    for I := 0 to 2 do
    begin
      if not HexDigit(S[1 + I * 2], Hi) then Exit;
      if not HexDigit(S[2 + I * 2], Lo) then Exit;
      B[I] := Hi * 16 + Lo;
    end;
    C := Vector3(B[0] / 255.0, B[1] / 255.0, B[2] / 255.0);
    Result := True;
  end;

var
  C: TVector3;
  Enable: Boolean;
begin
  if FTripoRider = nil then Exit;
  { Empty / '0' means the authored material. White and black are valid
    palette colors, also for a colored hat replacing the white helmet. }
  Enable := ParseHexColor(FHelmetColor, C);
  if not Enable then C := Vector3(1, 1, 1);
  FTripoRider.ApplyHelmetColor(C, Enable);
end;

procedure TBikeInstance.SetHelmetPitchX(const V: Single);
begin
  FHelmetPitchX := V;
  if FTripoRider <> nil then
    FTripoRider.HelmetPitchXDeg := V;
end;

procedure TBikeInstance.InvalidateGpuRiderSkin;
begin
  { Disable the GPU plug so inverse(skinMatrix) stops running on a rest
    mesh that ApplyBodyShape is about to rewrite. Do not Free the
    TEffectNode — it stays on appearances until the rider scene dies
    (LoadTripoRider) or a new Build adds a replacement. Freeing it on a
    live scene races the renderer (intermittent EObjectCheck on avatar
    clicks). }
  if FGpuSkin <> nil then
    FGpuSkin.SetActive(False);
  FreeAndNil(FGpuSkin);
  FGpuSkinPrimed := False;
end;

procedure TBikeInstance.StageBodyParameters(Section:TJSONObject;const Path:string);
var O,Embedded:TJSONObject; Resolved:string;
begin
  O:=ObjOf(Section,'body'); Embedded:=nil;
  try
    Resolved:=ResolveGlbFilesystemPath(Path);
    if (O=nil) and FileExists(Resolved) and
      not SameText(ExtractFileName(Path),'MEN.glb') and
      not SameText(ExtractFileName(Path),'FEM.glb') then begin
      Embedded:=ReadRiderExtra(Resolved,'bodyParameters');O:=Embedded;
    end;
    FBodyParameters:=ReadRiderBody(O,DefaultRiderBody(Ord(Pos('FEM',UpperCase(Path))>0)));
    FBodyParametersSet:=True;
  finally Embedded.Free end;
end;

procedure TBikeInstance.SetBodyParameters(const Value: TRiderBodyParameters);
var P:TRiderBodyParameters;
begin
  P:=NormalizeRiderBody(Value);
  FBodyParametersSet:=True;
  if SameRiderBody(P,FBodyParameters) then Exit;
  FBodyParameters:=P;
  ResetRiderDynamics(FBodyDynamics);
  FTripoFitScale:=0;
  ApplyTripoBodyShape;
end;

procedure TBikeInstance.ApplyTripoBodyShape;
begin
  if FTripoRider = nil then Exit;
  { Height / limb lengths only move joint translations. Do NOT Free the GPU
    effect — destroying TEffectNode on a live scene races the renderer (UI
    freeze on the fit-page height click) and the following Build recompiled
    a giant gskRest if-chain. RefreshBind uploads new uGskRest / uBindT. }
  if FTripoRider.HasParametricBody then
    FTripoRider.ApplyBodyParameters(FBodyParameters)
  else begin
  FTripoRider.ApplyBodyShape(FTripoBulk, FTripoBelly, FTripoBodyHeight);  { mesh: girth/belly; height is skeleton }
  FTripoRider.ApplyLimbLengths(FTripoLegLen, FTripoArmLen, FTripoShoulderWidth,
    FTripoPelvisWidth, FTripoTorsoLen * FTripoInseamUpper,
    1.0 + FTripoBodyHeight);
  end; { skeleton: limbs + height; inseam keeps stature }
  FTripoRider.ApplyGlossCorrection(FTripoRoughness, FTripoMetallic); { PBR: roughness/metallic multipliers, 1 = as authored }
  ApplyHelmetTint;
  FTripoRider.HelmetPitchXDeg := FHelmetPitchX;
  if FGpuAnim then
  begin
    FTripoRider.EnsureNativeSkinReady;
    if FGpuSkin <> nil then
      FGpuSkin.RefreshBind;
  end;
end;

{ BicycleAnkleFlexCurve (анклинг) живёт в BikeGfxUtil — единый источник
  для CPU-пути и GLSL-портов BikeGpuSkin/BikeGpuSpin. }

function TBikeInstance.GetTripoSpineAngle(Index: Integer): Single;
begin
  if (Index >= 0) and (Index <= 4) then Result := FTripoSpineAngles[Index] else Result := 0;
end;
procedure TBikeInstance.SetTripoSpineAngle(Index: Integer; const V: Single);
begin
  if (Index >= 0) and (Index <= 4) then FTripoSpineAngles[Index] := V;
end;

{ Синхронизация полей TRiderPose <-> живые Tripo*-поля инстанса в ОБЕ стороны
  (единый список — добавление поля правится здесь один раз).
  ToPose=True: живые поля -> поза (BuildRiderPose);
  ToPose=False: поза -> живые поля (ApplyRiderPose).
  HandPosR/L сюда НЕ входят: ApplyRiderPose клампит их и ведёт анимацию
  перехвата — там они обрабатываются отдельно. Name тоже снаружи. }
procedure TBikeInstance.SyncRiderPose(var P: TRiderPose; ToPose: Boolean);
var i: Integer; V: TVector3;

  procedure SyncS(var A, B: Single);   { A = поле позы, B = живое Tripo-поле }
  begin if ToPose then A := B else B := A; end;
  procedure SyncB(var A, B: Boolean);
  begin if ToPose then A := B else B := A; end;
  procedure SyncV(var A, B: TVector3);
  begin if ToPose then A := B else B := A; end;

begin
  V := Vector3(P.OffsetX, P.OffsetY, P.OffsetZ);
  SyncV(V, FTripoRiderOffset);
  P.OffsetX := V.X; P.OffsetY := V.Y; P.OffsetZ := V.Z;
  SyncS(P.TorsoLeanDeg, FTripoTorsoLeanDeg);
  SyncS(P.SpineCurve, FTripoSpineCurve);
  SyncB(P.SpineManual, FTripoSpineManual);
  for i := 0 to 4 do SyncS(P.SpineAngles[i], FTripoSpineAngles[i]);
  SyncS(P.KneeFlare, FTripoKneeFlare);
  SyncS(P.ElbowFlare, FTripoElbowFlare);
  SyncS(P.AnkleFlex, FTripoAnkleFlex);
  SyncS(P.ArmPronationR, FTripoArmPronationR);
  SyncS(P.ArmPronationL, FTripoArmPronationL);
  SyncS(P.ShoulderRoundDeg, FTripoShoulderRound);
  SyncS(P.HandLevel, FTripoHandLevel);
  SyncS(P.PedalSway, FTripoPedalSway);
  SyncS(P.TorsoBobAmp, FTripoTorsoBobAmp);
  SyncV(P.HandFreeRPos, FTripoHandFreeRPos);
  SyncV(P.HandFreeLPos, FTripoHandFreeLPos);
  SyncS(P.HandFreeRWave, FTripoHandFreeRWave);
  SyncS(P.HandFreeLWave, FTripoHandFreeLWave);
  SyncS(P.LegFreeR, FTripoLegFreeR);
  SyncS(P.LegFreeL, FTripoLegFreeL);
  SyncV(P.LegFreeRPos, FTripoLegFreeRPos);
  SyncV(P.LegFreeLPos, FTripoLegFreeLPos);
end;

procedure TBikeInstance.SetRiderEffort(Intensity: Single);
begin
  FRiderEffortTarget := EnsureRange(Intensity, 0.0, 3.0);
end;

procedure TBikeInstance.SetBodyDynamicsEnabled(Value:Boolean);
begin
  if FBodyDynamicsEnabled=Value then Exit;
  FBodyDynamicsEnabled:=Value;ResetRiderDynamics(FBodyDynamics);
  if (FTripoRider<>nil)and(FTripoRider.Correctives<>nil)and
    (FTripoRider.Correctives.Body<>nil) then
    FTripoRider.Correctives.Body.UseDynamics:=Value;
end;

function TBikeInstance.RiderTotalLeanDeg:Single;
begin Result:=FBodyDynamics.Frame.TotalLeanDeg end;

procedure TBikeInstance.SetRiderAttention(const Value: TRiderAttentionFrame);
begin
  FAttention:=Value;
end;

procedure TBikeInstance.SetRiderDynamicsSituation(PowerW,LateralAccel,ExternalLeanDeg:Single;
  RoadPitchDeg:Single);
begin
  FBodyDynamicsSituation:=True;
  FBodyDynamicsInput.PowerW:=PowerW;
  FBodyDynamicsInput.LateralAccel:=LateralAccel;
  FBodyDynamicsInput.ExternalLeanDeg:=ExternalLeanDeg;
  FBodyDynamicsInput.RoadPitchRad:=DegToRad(RoadPitchDeg);
end;

procedure TBikeInstance.SampleRiderDynamics;
var U:TRiderDynamicsInput;I:Integer;
begin
  if not FBodyDynamicsEnabled then Exit;
  { Explicit MCP sample only: reconstruct the preceding two seconds at fixed
    inputs. Ordinary updates and replay never do this warm-up work. }
  UpdateTripoRider(FTripoPrevElapsed);
  U:=FBodyDynamicsInput;ResetRiderDynamics(FBodyDynamics);
  for I:=1 to 240 do begin
    U.Phase:=FBodyDynamicsInput.Phase-U.CrankRate*(240-I)*RIDER_DYNAMICS_STEP;
    AdvanceRiderDynamics(FBodyDynamics,U,RIDER_DYNAMICS_STEP);
  end;
  UpdateTripoRider(FTripoPrevElapsed);
  if FTripoRider<>nil then FTripoRider.UpdateAppearance(0,FForwardSpeedMps,
    FRiderEffort,FRiderCrankPhase,FBreathPhase,FBreathLoad);
end;

function TBikeInstance.BodyDynamicsDebugJson:TJSONObject;
var I:Integer;A:TJSONArray;
begin
  Result:=TJSONObject.Create;Result.Add('enabled',FBodyDynamicsEnabled);
  Result.Add('on_foot',FOnFoot);
  if FOnFoot then begin
    Result.Add('phase',FOnFootPhase);
    Result.Add('seat_load_n',TJSONArray.Create([0,0]));
    A:=TJSONArray.Create;Result.Add('muscles',A);
    for I:=0 to RD_MUSCLES-1 do A.Add(FOnFootDynamics.Frame.Muscle[I]);
    A:=TJSONArray.Create;Result.Add('tissue_m',A);
    for I:=0 to 3 do A.Add(FOnFootDynamics.Frame.Tissue[I]);
    Exit;
  end;
  Result.Add('steps',Int64(FBodyDynamics.Steps));Result.Add('time',FBodyDynamics.Time);
  Result.Add('remainder',FBodyDynamics.Remainder);
  Result.Add('total_lean_deg',FBodyDynamics.Frame.TotalLeanDeg);
  Result.Add('rear_track_m',FBodyDynamics.Frame.RearTrackM);
  Result.Add('heading_deg',RadToDeg(FBodyDynamics.Frame.HeadingRad));
  Result.Add('steer_ground_deg',RadToDeg(FBodyDynamics.Frame.SteerRad));
  Result.Add('yaw_rate',FBodyDynamics.Frame.YawRate);
  Result.Add('route_lateral_accel',FBodyDynamicsInput.LateralAccel);
  Result.Add('wheelbase_m',FBodyDynamicsInput.Wheelbase);
  Result.Add('support',TJSONArray.Create([FBodyDynamics.Frame.Motion.X,
    FBodyDynamics.Frame.Motion.Y,FBodyDynamics.Frame.Motion.Z]));
  Result.Add('seat_load_n',TJSONArray.Create([FBodyDynamics.Frame.SeatLoad[0],FBodyDynamics.Frame.SeatLoad[1]]));
  Result.Add('seat_compression_m',TJSONArray.Create([FBodyDynamics.Frame.SeatCompression[0],FBodyDynamics.Frame.SeatCompression[1]]));
  Result.Add('pedal_load_n',TJSONArray.Create([FBodyDynamics.Frame.PedalLoad[0],FBodyDynamics.Frame.PedalLoad[1]]));
  Result.Add('hand_load_n',TJSONArray.Create([FBodyDynamics.Frame.HandLoad[0],FBodyDynamics.Frame.HandLoad[1]]));
  A:=TJSONArray.Create;Result.Add('muscles',A);
  for I:=0 to RD_MUSCLES-1 do A.Add(FBodyDynamics.Frame.Muscle[I]);
  A:=TJSONArray.Create;Result.Add('tissue_m',A);
  for I:=0 to 3 do A.Add(FBodyDynamics.Frame.Tissue[I]);
end;

function TBikeInstance.RiderCadenceRpm: Single;
var Interval: Single;
begin
  Interval := FCrankIntervalCur;
  if Interval < 0 then Interval := FBaseCrankCycle;
  if (Interval > 0.01) and (Interval < 1000) then Result := 60 / Interval
  else Result := 0;
end;

function TBikeInstance.GetRiderStanceHalf: Single;
var Crank: TCranksetComponent;
begin
  if (FTripoStanceHalf > 0) and not IsNan(FTripoStanceHalf) and
    not IsInfinite(FTripoStanceHalf) then Exit(FTripoStanceHalf);
  Crank := TCranksetComponent(Component(TCranksetComponent));
  if Crank <> nil then Result := Crank.PedalStanceHalf
  else Result := ROAD_QFACTOR_HALF + DEFAULT_PEDAL_CENTER_OFFSET;
end;

function TBikeInstance.RiderMotionDebugJson: TJSONObject;
const Names: array[0..20] of string = ('Pelvis', 'Waist', 'Spine', 'Spine01',
  'Spine02', 'NeckTwist01', 'Head', 'R_Thigh', 'R_Calf', 'R_Foot',
  'L_Thigh', 'L_Calf', 'L_Foot', 'R_Upperarm', 'R_Forearm', 'R_Hand', 'L_Hand',
  'L_Upperarm','L_Forearm','R_Clavicle','L_Clavicle');
var I: Integer; V: TVector3; Ok: Boolean; Bones: TJSONObject; Errors,Targets: TJSONArray;
  P: TRiderPose; HF: TJSONArray; H: TJSONObject; J:Integer;
  F,N:TVector3; LF,LN,W:TTripoVec3; Q:TTripoVec4; Prefix:string; Twist:Single;
begin
  Result := TJSONObject.Create;
  Result.Add('phase', FPhase); Result.Add('breath_phase', FBreathPhase);
  Result.Add('dynamics',BodyDynamicsDebugJson);
  Result.Add('crank_phase', FRiderCrankPhase);
  Result.Add('breaths_per_minute',RiderBreathsPerMinute(FBreathLoad)); Result.Add('effort', FRiderEffort); Result.Add('cadence', FMotionCadence);
  Result.Add('gpu', FGpuAnim); Result.Add('last_error', FUtrLastError);
  Result.Add('look_yaw',FAttention.Yaw);
  Result.Add('look_torso_yaw',FAttention.TorsoYaw);
  Result.Add('pose', FBaseRiderPose.Name);
  Result.Add('pedal_rpm', FPedalRate * 60);
  Result.Add('stance_half_mm', GetRiderStanceHalf);
  Result.Add('foot_yaw_deg', FTripoFootYawDeg);
  Result.Add('grounded_target', FBaseRiderPose.Grounded);
  P := BuildRiderPose('');
  if (FTripoRider <> nil) and FTripoRider.PoseAnimating then P := FTripoRider.CurrentPose;
  Result.Add('free_feet', TJSONArray.Create([P.LegFreeR, P.LegFreeL]));
  Result.Add('hand_animating',FHandAnimating);
  Result.Add('hand_elapsed',FHandAnimElapsed);
  Result.Add('hand_duration',FHandAnimDur);
  Targets:=TJSONArray.Create;Result.Add('contact_targets',Targets);
  for I:=0 to 3 do Targets.Add(TJSONArray.Create([
    FFrameContacts[I].X,FFrameContacts[I].Y,FFrameContacts[I].Z]));
  if FTripoRider = nil then Exit;
  Result.Add('bike_lean_deg', FPedalLeanApplied);
  Result.Add('steer_mesh_deg',MeshSteerAngleDeg);
  Result.Add('steer_applied_deg',FSteerAngleApplied);
  if FGroup<>nil then begin
    V:=FGroup.Transform.MultPoint(Vector3(-GetAxleHalfSpanM,0,0));
    Result.Add('rear_track_contact',TJSONArray.Create([V.X,V.Y,V.Z]));
    V:=FGroup.Transform.MultPoint(SteerPoint(Vector3(GetAxleHalfSpanM,0,0)));
    Result.Add('front_track_contact',TJSONArray.Create([V.X,V.Y,V.Z]));
  end;
  HF := TJSONArray.Create;
  Result.Add('authored_spine_deg', HF);
  for I := 0 to 4 do HF.Add(P.SpineAngles[I]);
  HF := TJSONArray.Create;
  Result.Add('applied_spine_deg', HF);
  for I := 0 to 4 do HF.Add(FTripoRider.SpineAngle[I]);
  Bones := TJSONObject.Create; Result.Add('joints', Bones);
  for I := 0 to High(Names) do
  begin
    if FGpuAnim and (FGpuSkin <> nil) then Ok := FGpuSkin.ShadowJoint(Names[I], V)
    else Ok := FTripoRider.PosedJointParent(Names[I], V);
    if Ok then Bones.Add(Names[I], TJSONArray.Create([V.X, V.Y, V.Z]));
  end;
  HF:=TJSONArray.Create;Result.Add('hands',HF);
  for I:=0 to 1 do begin
    if FGpuAnim and (FGpuSkin<>nil) then Ok:=FGpuSkin.ShadowHandFrame(I,F,N,Twist)
    else begin
      if I=0 then Prefix:='R_' else Prefix:='L_';
      Twist:=0;J:=FTripoRider.Rig.JointIndexByName(Prefix+'Hand');Ok:=J>=0;
      if Ok then begin
        RiderHandAxes(FTripoRider.Rig,I,LF,LN);Q:=FTripoRider.Rig.JointWorldRot(J);
        W:=QuatRotateV3(Q,LF);F:=FTripoRider.Scene.Transform.MultDirection(Vector3(W.X,W.Y,W.Z)).Normalize;
        W:=QuatRotateV3(Q,LN);N:=FTripoRider.Scene.Transform.MultDirection(Vector3(W.X,W.Y,W.Z)).Normalize;
      end;
    end;
    H:=TJSONObject.Create;HF.Add(H);
    if Ok then begin
      if FGpuAnim then H.Add('forearm_twist_deg',Twist);
      H.Add('forward',TJSONArray.Create([F.X,F.Y,F.Z]));
      H.Add('palm',TJSONArray.Create([N.X,N.Y,N.Z]));
    end;
    if I=0 then begin
      F:=FFrameHandR.Forward;N:=FFrameHandR.Palm;H.Add('weight',FFrameHandR.Weight);
    end else begin
      F:=FFrameHandL.Forward;N:=FFrameHandL.Palm;H.Add('weight',FFrameHandL.Weight);
    end;
    H.Add('target_forward',TJSONArray.Create([F.X,F.Y,F.Z]));
    H.Add('target_palm',TJSONArray.Create([N.X,N.Y,N.Z]));
  end;
  Errors := TJSONArray.Create; Result.Add('contact_error_m', Errors);
  for I := 0 to 3 do
  begin
    if FGpuAnim and (FGpuSkin <> nil) then Ok := FGpuSkin.ShadowContact(I, V)
    else Ok := FTripoRider.PosedContactParent(I, V);
    if Ok then Errors.Add((V - FFrameContacts[I]).Length) else Errors.Add(-1);
  end;
end;

function TBikeInstance.BuildRiderPose(const AName: string): TRiderPose;
begin
  Result := FBaseRiderPose; { preserve selection metadata and motion profile }
  if AName <> '' then Result.Name := AName;
  SyncRiderPose(Result, True);
  Result.HandPosR := FTripoHandPosR;
  Result.HandPosL := FTripoHandPosL;
end;

procedure TBikeInstance.ApplyRiderPose(const P: TRiderPose; Duration: Single);
var oldR, oldL, newR, newL: Integer; cR, cL, PendingR,PendingL,LeftMoving: Boolean;
    PFields: TRiderPose;
begin
  PendingR:=FHandAnimating and (FHandAnimElapsed<FHandSlotR1*FHandAnimDur) and
    ((FHandFromR<>FTripoHandPosR) or FHandAnchorRValid or
     ((FTripoHandPosR=0) and (((FHandFromFreeRPos-FTripoHandFreeRPos).LengthSqr>1e-10) or
       (Abs(FHandFromFreeRWave-FTripoHandFreeRWave)>1e-6))));
  PendingL:=FHandAnimating and (FHandAnimElapsed<FHandSlotL1*FHandAnimDur) and
    ((FHandFromL<>FTripoHandPosL) or FHandAnchorLValid or
     ((FTripoHandPosL=0) and (((FHandFromFreeLPos-FTripoHandFreeLPos).LengthSqr>1e-10) or
       (Abs(FHandFromFreeLWave-FTripoHandFreeLWave)>1e-6))));
  LeftMoving:=PendingL and (FHandAnimElapsed>FHandSlotL0*FHandAnimDur);
  FHandAnchorRValid:=PendingR and FFrameContactsValid;
  FHandAnchorLValid:=PendingL and FFrameContactsValid;
  if FHandAnchorRValid then begin FHandAnchorR:=FFrameContacts[2];FHandAnchorFrameR:=FFrameHandR;end;
  if FHandAnchorLValid then begin FHandAnchorL:=FFrameContacts[3];FHandAnchorFrameL:=FFrameHandL;end;
  { remember the free point the hand is leaving (for a free->grip / free->free
    move) BEFORE the sync below overwrites the live fields; the transition lerps
    between these fixed endpoints so it starts at the actual handlebar/hand
    position, not from zero }
  FHandFromFreeRPos := FTripoHandFreeRPos; FHandFromFreeLPos := FTripoHandFreeLPos;
  FHandFromFreeRWave := FTripoHandFreeRWave; FHandFromFreeLWave := FTripoHandFreeLWave;
  { mirror the pose into the live tuning fields (incl. the new target free
    points) so the preview grid reflects it and the instant-sync after the
    animation lands on the same values }
  FBaseRiderPose := P;
  if IsFixedGear then FPedalRate := RiderCadenceRpm / 60
  else if P.Grounded or (P.Motion.Pedalling <= 0) then FPedalRate := 0
  else if Duration <= 0 then
  begin
    if PedalContactsReady(P.Motion.Pedalling, P.LegFreeR, P.LegFreeL, False) then
      FPedalRate := RiderCadenceRpm / 60
    else FPedalRate := 0;
  end;
  PFields := P;   { SyncRiderPose needs a var }
  SyncRiderPose(PFields, False);

  { Transfer one hand at a time. On interruption finish the airborne hand
    first, starting at its actual endpoint rather than the previous target. }
  oldR := FTripoHandPosR; oldL := FTripoHandPosL;
  newR := P.HandPosR; if newR < 0 then newR := 0;    { 0 = free hand }
  newL := P.HandPosL; if newL < 0 then newL := 0;
  cR := (newR <> oldR) or PendingR or ((newR=0) and
    (((P.HandFreeRPos-FHandFromFreeRPos).LengthSqr>1e-10) or
     (Abs(P.HandFreeRWave-FHandFromFreeRWave)>1e-6)));
  cL := (newL <> oldL) or PendingL or ((newL=0) and
    (((P.HandFreeLPos-FHandFromFreeLPos).LengthSqr>1e-10) or
     (Abs(P.HandFreeLWave-FHandFromFreeLWave)>1e-6)));
  if (Duration > 0) and (cR or cL) then
  begin
    FHandFromR := oldR; FHandFromL := oldL;
    FHandAnimElapsed := 0; FHandAnimDur := Duration; FHandAnimating := True;
    if cR and cL then
    begin
      if LeftMoving then begin
        FHandSlotL0:=0;FHandSlotL1:=0.5;
        FHandSlotR0:=0.5;FHandSlotR1:=1;
      end else begin
        FHandSlotR0 := 0.0; FHandSlotR1 := 0.5;
        FHandSlotL0 := 0.5; FHandSlotL1 := 1.0;
      end;
    end
    else
    begin
      FHandSlotR0 := 0.0; FHandSlotR1 := 1.0;
      FHandSlotL0 := 0.0; FHandSlotL1 := 1.0;
    end;
  end
  else
  begin
    FHandFromR := newR; FHandFromL := newL; FHandAnimating := False;
    FHandAnchorRValid:=False;FHandAnchorLValid:=False;
  end;
  FTripoHandPosR := newR; FTripoHandPosL := newL;

  if FTripoRider <> nil then FTripoRider.ApplyPose(P, Duration);
end;

procedure TBikeInstance.UpdateTripoRider(ElapsedSec: Double);
var
  RS: TCastleScene;
  CrankTS: TTimeSensorNode;   { было Timer — конфликтовало с CastleTimeUtils.Timer }
  T0u, T1u: TTimerResult;     { TEMP-DIAG }
  Phase, Ang, S, CenterX: Single;
  YawRad, Psx, Psy, Psz, PelvicPitch: Single;
  Sway, Bob, QFH, QZ, Alpha: Single;
  Motion: TRiderMotionFrame;
  RootQ, BodyQ: TTripoVec4;
  SeatV: TTripoVec3;
  FootPitchR, FootPitchL: Single;
  i: Integer;
  BB, CrankR, CrankL, PedalR, PedalL, GripR, GripL, Saddle: TVector3;
  AnkleR, AnkleL, Pelvis, PelvisRot, LiveOffset, Support: TVector3;
  BoneA, BoneB: TVector3;   { scratch для TryGetBone-резолвов }
  Rot4: TVector4;                          { rider orientation (axis+angle), for P^-1 }
  LivePose, GoalPose: TRiderPose;
  GoalTransform: TMatrix4;
  Dt, progHR, progHL, twistDeg, freeR, freeL: Single;
  FromFrameR,FromFrameL:TRiderGripFrame;

  function GripFrame(Idx,Side:Integer):TRiderGripFrame;
  var Origin:TVector3; Bar:TDropBarComponent; Flat:TFlatBarComponent; Sweep:Single;
  begin
    if (Idx>0) and (BarType=btFlat) then begin
      Result:=RiderGripFrame(5,Side);
      Flat:=TFlatBarComponent(Component(TFlatBarComponent));
      if Flat<>nil then begin
        Sweep:=DegToRad(Flat.FlatBarSweep);
        Result.Forward.Z:=Result.Forward.X*Sin(Sweep)*(1-2*Side);
        Result.Forward.X:=Result.Forward.X*Cos(Sweep);
      end;
    end
    else begin
      Bar:=TDropBarComponent(Component(TDropBarComponent));
      if (Idx=1)and(Bar<>nil)and not Bar.ShowHoods then
        Result:=RiderGripFrame(2,Side)
      else Result:=RiderGripFrame(Idx,Side);
    end;
    if Idx>0 then begin
      Origin:=SteerPoint(TVector3.Zero);
      Result.Forward:=(SteerPoint(Result.Forward)-Origin).Normalize;
      Result.Palm:=(SteerPoint(Result.Palm)-Origin).Normalize;
    end;
  end;

  function O(const P: TVector3): TVector3;   { same X-centering the geometry uses }
  begin Result := Vector3(P.X - CenterX, P.Y, P.Z); end;

  { resolve a hand-grip world point by side ('r'/'l') and 1-based index, with
    graceful fallback: place_<side>_<idx> -> place_<side>_1 -> legacy hood/bar/stem.
    TryGetBone — один линейный скан на проверку (HasBone+GetBone сканировали дважды). }
  function GripPlace(const Side: string; Idx: Integer; const FreePos: TVector3; Wave: Single): TVector3;
  var bn: string; BP: TVector3;
  begin
    if Idx <= 0 then     { 0 = free hand: a static bike-frame point (+ wave), not a bar grip }
    begin
      Result := O(FreePos);
      if Side = 'r' then Result.Y := Result.Y + Wave * Sin(Ang)
                    else Result.Y := Result.Y + Wave * Sin(Ang + Pi);
      Exit(Result);
    end;
    bn := 'place_' + Side + '_' + IntToStr(Idx);
    if FBikeSkeleton.TryGetBone(bn, BP) then Exit(O(BP));
    if FBikeSkeleton.TryGetBone('place_' + Side + '_1', BP) then Exit(O(BP));
    Result := GripBoneFallback(FBikeSkeleton, Side, CenterX, BB);
  end;

  function SlotProg(F, T0, T1: Single): Single;   { progress within a time window }
  begin
    if T1 <= T0 then Exit(1);
    Result := (F - T0) / (T1 - T0);
    Result := SmoothUnit(Result);
  end;

  procedure LogBone(const AName: string);
  var Q: TVector3;
  begin
    if FBikeSkeleton.HasBone(AName) then
    begin
      Q := O(FBikeSkeleton[AName]);
      StartupLog(Format('[Skel] %-16s O=(%.4f,%.4f,%.4f)', [AName, Q.X, Q.Y, Q.Z]));
    end
    else
      StartupLog(Format('[Skel] %-16s (missing)', [AName]));
  end;

begin
  try
  if (FTripoRider = nil) or (not FTripoRider.Loaded) then Exit;
  if (FBikeSkeleton = nil) or (not FBikeSkeleton.TryGetBone('bb', BB)) then Exit;

  { geometry is centred on the wheelbase midpoint; match it }
  CenterX := BikeCenterX(FBikeSkeleton);

  { rest crank arms (relative to BB; X-centering cancels in the relative vector) }
  RestCrankArms(FBikeSkeleton, BB, CrankR, CrankL);

  if not FBikeSkeleton.TryGetBone('saddle_contact', Saddle) then
    if not FBikeSkeleton.TryGetBone('seatpost_top', Saddle) then Saddle := BB;

  { One-shot skeleton dump to startup_anim — the positions the FORK, SEATPOST and
    SADDLE/BAR models are built from, in O-centred scene metres. Compare against the
    [FrameAnim] tube endpoints: SEAT.E must equal seat_tube_top, HEAD.S must equal
    head_tube_bottom. Any mismatch IS the непопадание (frame tubes vs skeleton). }
  if not FSkelDbgLogged then
  begin
    FSkelDbgLogged := True;
    StartupLog(Format('[Skel] CenterX=%.4f bb=(%.4f,%.4f,%.4f)',
      [CenterX, O(BB).X, O(BB).Y, O(BB).Z]));
    LogBone('seat_tube_top');
    LogBone('seatpost_top');
    LogBone('saddle_contact');
    LogBone('head_tube_bottom');
    LogBone('head_tube_top');
    LogBone('fork_crown_l');
    LogBone('fork_crown_r');
    LogBone('front_axle');
    LogBone('stem_base');
    LogBone('stem_end');
    LogBone('bar_left');
    LogBone('bar_right');
    LogBone('hood_base_l');
    LogBone('hood_base_r');
  end;

  { ── crank phase: CPU-накопитель FPhase (GPU-анимация, этап 1). Один раз
    после билда синхронизируемся с живым CrankTimer (чтобы ноги/платформы
    совпали с мешем шатунов, который пока крутит таймер), дальше фаза идёт
    своим ходом из Dt — покадрового FindNode/ElapsedTimeInCycle больше нет. ── }
  if not FPhaseSynced then
  begin
    FPhaseSynced := True;
    RS := RiderScene;
    if (RS <> nil) and (RS.RootNode <> nil) then
    begin
      CrankTS := RS.RootNode.FindNode(TTimeSensorNode, 'CrankTimer',
        [fnNilOnMissing]) as TTimeSensorNode;
      if (CrankTS <> nil) and (CrankTS.CycleInterval > 0.01) then
        FPhase := Frac(CrankTS.ElapsedTimeInCycle / CrankTS.CycleInterval);
    end;
  end;
  Phase := FPhase;
  { этап 4: CPU-путь крутит именованные трансформы явно (замена TimeSensor/ROUTE);
    GPU-путь — шейдер из того же FPhase (см. ветку FGpuAnim ниже). }
  if not FGpuAnim then
    DriveSpinNodesCPU(Phase, FWheelPhase);

  { Sway/Bob amplitudes come from the live (animated) pose — evaluated AFTER LivePose
    is resolved below, otherwise they read a zeroed pose and nothing moves. }

  { ── placement: seat the PELVIS joint on the saddle. AUTO-FIT REMOVED — the rider
       is no longer rescaled to make its legs reach the bike, so it renders at its
       native (glb) size and the object scale set in Blender takes effect directly.
       TripoRiderScale is the only size knob (a plain multiplier). ── }
  if FTripoFitScale <= 0 then FTripoFitScale := 1.0;
  S := FTripoFitScale * FTripoRiderScale;

  YawRad := DegToRad(FTripoRiderYawDeg);
  { Orientation comes FROM THE RIG: the rider derives an upright/forward correction
    from its own bind-pose bones (spine + clavicles) and composes the user yaw on top,
    so a glb with a different baked Root/Armature orientation (or an A-pose rest) still
    stands and faces correctly. A rig that is already aligned is left untouched. The
    seat reference (BottomContact bone, else pelvis) is rotated by the SAME rotation so
    it lands exactly on the saddle. }
  { ── pose: the rider OWNS the live posture and animates transitions. While an
       animation is running, advance it; otherwise keep it in instant sync with the
       live Tripo* tuning (so grid edits apply immediately). A preset is applied via
       ApplyRiderPose, which also writes the Tripo* fields so the post-animation
       instant-sync lands on the same values. ── }
  Dt := ElapsedSec - FTripoPrevElapsed;
  if (Dt < 0) or (Dt > 0.5) then begin
    ResetRiderDynamics(FBodyDynamics);
    FBodyDynamicsInput.ForwardAccel:=0;
    FBodyDynamicsInput.RoadNormalAccel:=0;
    FBodyDynamicsInput.SpeedMps:=FForwardSpeedMps;
    Dt:=0;
  end;
  FTripoPrevElapsed := ElapsedSec;
  T0u := Timer;   { TEMP-DIAG: pose apply/advance }
  if FTripoRider.PoseAnimating then FTripoRider.AdvancePose(Dt)
  else FTripoRider.ApplyPose(BuildRiderPose('current'), 0);
  T1u := Timer;
  FDiagPoseApply := FDiagPoseApply * 0.95 + TimerSeconds(T1u, T0u) * 1000 * 0.05;
  LivePose   := FTripoRider.CurrentPose;
  LiveOffset := Vector3(LivePose.OffsetX, LivePose.OffsetY, LivePose.OffsetZ);
  Alpha := 1 - Exp(-Dt / 0.65);
  FRiderEffort := FRiderEffort + (FRiderEffortTarget - FRiderEffort) * Alpha;
  FMotionCadence := FMotionCadence + (FPedalRate * 60 - FMotionCadence) * (1 - Exp(-Dt / 0.25));
  AdvanceRiderBreathing(FBreathLoad,FBreathPhase,Dt,FRiderEffort);
  Ang := FTripoPedalDir * Phase * 2 * Pi;
  FRiderCrankPhase := (ArcTan2(CrankR.Y, CrankR.X) + Ang) / (2 * Pi);
  if FBodyDynamicsEnabled then begin
    FBodyDynamicsInput.Profile:=LivePose.Motion;
    FBodyDynamicsInput.Phase:=FRiderCrankPhase;
    FBodyDynamicsInput.CrankRate:=FTripoPedalDir*FPedalRate;
    FBodyDynamicsInput.BreathPhase:=FBreathPhase;
    FBodyDynamicsInput.Cadence:=FMotionCadence;
    FBodyDynamicsInput.Effort:=FRiderEffort;
    if not FBodyDynamicsSituation then FBodyDynamicsInput.PowerW:=FRiderEffort*220;
    FBodyDynamicsInput.MassKg:=FBodyParameters.WeightKg;
    FBodyDynamicsInput.HeightM:=FBodyParameters.HeightCm*0.01;
    FBodyDynamicsInput.Composition:=FBodyParameters.Composition;
    if (Dt>0)and FBodyDynamicsSituation then
      FBodyDynamicsInput.ForwardAccel:=FBodyDynamicsInput.ForwardAccel+
        (EnsureRange((FForwardSpeedMps-FBodyDynamicsInput.SpeedMps)/Dt,-8.0,8.0)-
        FBodyDynamicsInput.ForwardAccel)*(1-Exp(-Dt/0.12));
    FBodyDynamicsInput.SpeedMps:=FForwardSpeedMps;
    { Standalone previews have cadence but no physical route input. }
    if not FBodyDynamicsSituation then begin
      FBodyDynamicsInput.SpeedMps:=Max(FForwardSpeedMps,6*SmoothUnit(FMotionCadence/35));
      FBodyDynamicsInput.ForwardAccel:=0;
    end;
    FBodyDynamicsInput.Wheelbase:=Max(0.65,2*GetAxleHalfSpanM);
    EnsureSteerAxisCache;
    FBodyDynamicsInput.SteerAxisUp:=Abs(FSteerAxis.Y);
    FBodyDynamicsInput.SeatHeight:=Saddle.Y;
    { Curvature of the support direction, not differences of large world
      coordinates. Discontinuous route corrections cannot act as impacts. }
    if (Dt>0)and FBodyDynamics.Initialized then begin
      Alpha:=FBodyDynamicsInput.RoadPitchRad-FBodyDynamics.LastInput.RoadPitchRad;
      if Abs(Alpha)>0.15 then FBodyDynamicsInput.RoadNormalAccel:=0
      else FBodyDynamicsInput.RoadNormalAccel:=FBodyDynamicsInput.RoadNormalAccel+
        (EnsureRange(FForwardSpeedMps*Alpha/Dt,-8.0,8.0)-FBodyDynamicsInput.RoadNormalAccel)*
        (1-Exp(-Dt/0.08));
    end;
    FBodyDynamicsInput.SeatX:=-LiveOffset.X;
    FBodyDynamicsInput.SeatY:=-LiveOffset.Y;
    FBodyDynamicsInput.SeatZ:=-LiveOffset.Z;
    FBodyDynamicsInput.TorsoLength:=FBodyParameters.HeightCm*0.00292;
    BoneA:=GripPlace('r',LivePose.HandPosR,LivePose.HandFreeRPos,LivePose.HandFreeRWave);
    BoneB:=GripPlace('l',LivePose.HandPosL,LivePose.HandFreeLPos,LivePose.HandFreeLWave);
    FBodyDynamicsInput.BarReach:=(BoneA.X+BoneB.X)*0.5-O(Saddle).X;
    FBodyDynamicsInput.BarWidth:=Abs(BoneA.Z-BoneB.Z);
    FBodyDynamicsInput.CrankRadius:=Sqrt(Sqr(CrankR.X)+Sqr(CrankR.Y));
    FBodyDynamicsInput.CrankX:=BB.X-Saddle.X-LiveOffset.X;
    FBodyDynamicsInput.CrankY:=BB.Y-Saddle.Y-LiveOffset.Y;
    FBodyDynamicsInput.StanceHalf:=GetRiderStanceHalf*FBikeSkeleton.MM;
    FBodyDynamicsInput.FootR:=1-LivePose.LegFreeR;
    FBodyDynamicsInput.FootL:=1-LivePose.LegFreeL;
    FBodyDynamicsInput.HandR:=Ord(LivePose.HandPosR>0);
    FBodyDynamicsInput.HandL:=Ord(LivePose.HandPosL>0);
    if FHandAnimating and(FHandAnimDur>0)then begin
      Alpha:=Min(1.0,(FHandAnimElapsed+Dt)/FHandAnimDur);
      if (FHandFromR<>FTripoHandPosR)or FHandAnchorRValid then
        FBodyDynamicsInput.HandR:=FBodyDynamicsInput.HandR*
          Sqr(Cos(Pi*SlotProg(Alpha,FHandSlotR0,FHandSlotR1)));
      if (FHandFromL<>FTripoHandPosL)or FHandAnchorLValid then
        FBodyDynamicsInput.HandL:=FBodyDynamicsInput.HandL*
          Sqr(Cos(Pi*SlotProg(Alpha,FHandSlotL0,FHandSlotL1)));
    end;
    FBodyDynamicsInput.Grounded:=LivePose.Grounded;
    { The desired support uses the current authored posture. Reading the scene
      transform here would feed last frame's solved motion back into its goal. }
    Support:=TVector3.Zero;
    if LivePose.Motion.Standing>0 then begin
      GoalPose:=FTripoRider.MotionPose(LivePose,Default(TRiderMotionFrame));
      PelvicPitch:=FTripoRider.SplitHipHinge(GoalPose);
      RootQ:=RiderSpineDelta(Vector3(0,0,1),PelvicPitch,0,0);
      Rot4:=FTripoRider.OrientedRotationVec4(YawRad);
      BodyQ:=QuatNormalize(QuatMul(RootQ,QuatFromAxisAngle(Rot4.X,Rot4.Y,Rot4.Z,Rot4.W)));
      GoalTransform:=RotationMatrixRad(2*ArcCos(EnsureRange(BodyQ.W,-1.0,1.0)),
        BodyQ.X,BodyQ.Y,BodyQ.Z)*ScalingMatrix(Vector3(S,S,S));
      Support:=FTripoRider.PedallingSupportAtTransform(O(Saddle)+LiveOffset,O(BB),LiveOffset,
        FBodyDynamicsInput.CrankRadius,0,LivePose.Motion.Standing,S,GoalTransform)-(O(Saddle)+LiveOffset);
    end;
    FBodyDynamicsInput.GoalX:=Support.X;FBodyDynamicsInput.GoalY:=Support.Y;
    FBodyDynamicsInput.GoalZ:=Support.Z;
    AdvanceRiderDynamics(FBodyDynamics,FBodyDynamicsInput,Dt);
    Motion:=FBodyDynamics.Frame.Motion;
  end else
    Motion := EvaluateRiderMotion(LivePose.Motion, FRiderCrankPhase, FBreathPhase,
      FMotionCadence, FRiderEffort, LivePose.PedalSway, LivePose.TorsoBobAmp);
  if BikeDebugDisableSteer then
  begin
    Motion.Roll := Motion.Roll + Motion.BikeLean;
    Motion.BikeLean := 0; Motion.BikeSteer := 0;
  end;
  Sway := Motion.Z; Bob := Motion.Y;
  LiveOffset.X := LiveOffset.X + Motion.X;
  LivePose:=FTripoRider.MotionPose(LivePose,Motion);
  PelvicPitch:=FTripoRider.SplitHipHinge(LivePose);
  FPedalLeanDeg := Motion.BikeLean;
  FPedalSteerDeg := Motion.BikeSteer;
  if BikeDebugDisableSteer then
  begin
    FPedalLeanDeg := 0; FPedalSteerDeg := 0;
  end;
  DrivePedalLean;

  { Трансформ райдера — ТОЛЬКО scene-level (вне графа), как в двух-сценном
    коде 2026-07-23: joint-матрицы скиннинга считаются внутри графа без P,
    меш получает P один раз через ModelView. Байк (ручная геометрия в той
    же сцене) компенсирует P контейнером с матрицей P^-1. }
  { Rotate about the saddle contact, not the model origin. Leg IK receives
    the inverse of this exact transform, so pelvic rotation cannot move cleats. }
  RootQ := RiderSpineDelta(Vector3(0, 0, 1), Motion.Pitch+PelvicPitch, Motion.Yaw, Motion.Roll);
  PelvisRot := FTripoRider.OrientedSeatOffset(YawRad, S);
  SeatV := QuatRotateV3(RootQ, V3(PelvisRot.X, PelvisRot.Y, PelvisRot.Z));
  PelvisRot := Vector3(SeatV.X, SeatV.Y, SeatV.Z);
  Rot4 := FTripoRider.OrientedRotationVec4(YawRad);
  BodyQ := QuatNormalize(QuatMul(RootQ, QuatFromAxisAngle(Rot4.X, Rot4.Y, Rot4.Z, Rot4.W)));
  if Abs(FAttention.Yaw)+Abs(FAttention.Pitch)+Abs(FAttention.TorsoYaw)>0.00001 then begin
    SeatV:=QuatRotateV3(QuatConj(BodyQ),V3(0,1,0));
    LivePose:=RiderAttentionPose(LivePose,FTripoRider.LeanAxis,FAttention,
      Vector3(SeatV.X,SeatV.Y,SeatV.Z));
  end;
  Rot4 := Vector4(BodyQ.X, BodyQ.Y, BodyQ.Z, 2 * ArcCos(EnsureRange(BodyQ.W, -1.0, 1.0)));
  if Abs(Rot4.W) < 1e-6 then Rot4 := Vector4(0, 1, 0, 0);
  FTripoRider.Scene.Scale := Vector3(S, S, S);
  FTripoRider.Scene.Rotation := Rot4;
  Support := O(Saddle) + LiveOffset + Vector3(0, Bob, Sway);
  if not FBodyDynamicsEnabled then
    Support:=FTripoRider.PedallingSupport(Support,O(BB),LiveOffset+Vector3(0,Bob,Sway),
      Sqrt(Sqr(CrankR.X)+Sqr(CrankR.Y)),FPedalLeanApplied,LivePose.Motion.Standing);
  FTripoRider.Scene.Translation := Support - PelvisRot;
  if (FTripoRider.Correctives<>nil)and(FTripoRider.Correctives.Body<>nil)then begin
    FTripoRider.Correctives.Body.UseDynamics:=FBodyDynamicsEnabled;
    if Component(TSeatComponent)<>nil then FTripoRider.Correctives.Body.SetDynamicsFrame(
      FBodyDynamics.Frame,FTripoRider.Scene.Transform,O(Saddle),
      TSeatComponent(Component(TSeatComponent)).ContactSurface,
      (1-LivePose.Motion.Standing)*Ord(not LivePose.Grounded));
  end;
  if FBikeContainer <> nil then
  begin
    { P = T · R · S  =>  P^-1 = S^-1 · R^-1 · T^-1 }
    Rot4 := FTripoRider.Scene.Rotation;
    FBikeContainer.Matrix :=
      ScalingMatrix(Vector3(1 / S, 1 / S, 1 / S)) *
      RotationMatrixRad(-Rot4.W, Rot4.X, Rot4.Y, Rot4.Z) *
      TranslationMatrix(-FTripoRider.Scene.Translation);
  end;
  { видимость райдера — switch-обёртка glb-контента в его сцене }
  if FVisSwitch <> nil then
    if FTripoShowRider then FVisSwitch.WhichChoice := 0
    else FVisSwitch.WhichChoice := -1;

  { the rider's posture (lean / spine / flares / pronation / shoulders) is driven by
    its own pose animation now; the bike only reads back offset/stance/ankle below. }

  { ── pedal CONTACT (ball of foot) = rest crank arms rotated by the crank angle ── }
  Ang := FTripoPedalDir * Phase * 2 * Pi;   { direction tunable (PedalReverse) }
  { Same pedal centre as the rendered crankset, including spindle length.
    An explicit editor fitting override is still available. }
  QFH := GetRiderStanceHalf;
  QZ := QFH * FBikeSkeleton.MM;
  PedalPositions(BB, CenterX, QZ, Ang, CrankR, CrankL, PedalR, PedalL);

  { foot IK target = the raw pedal contact, UNLESS the leg is "free": then the foot
    leaves the pedal and goes to a static bike-frame position (the rest of the leg
    follows by IK). LegFree blends 0..1 so a pose transition lifts the foot off the
    pedal smoothly; the free position is given in the bike frame (X fwd, Y up, Z
    lateral) and X-centred like every other target. The crank mesh keeps turning. }
  freeR := LivePose.LegFreeR; if freeR < 0 then freeR := 0 else if freeR > 1 then freeR := 1;
  freeL := LivePose.LegFreeL; if freeL < 0 then freeL := 0 else if freeL > 1 then freeL := 1;
  AnkleR := PedalR + (O(LivePose.LegFreeRPos) - PedalR) * freeR;
  AnkleL := PedalL + (O(LivePose.LegFreeLPos) - PedalL) * freeL;

  { ── ankle flex (anatomical "ankling"): RiderAnkleFlex is the MAX amplitude; the
       actual flex varies through the stroke via the same curve the old rig used.
       The bike only computes the angle now — the rider folds it into the foot IK
       (SolveLimb) so the cleat stays on the pedal AFTER the roll. A freed foot is
       off the pedal, so its ankling fades out with LegFree. ── }
  FootPitchR := 0; FootPitchL := 0;
  if LivePose.AnkleFlex > 0.001 then
  begin
    FootPitchR := AnklingFootPitch(CrankR, Ang, LivePose.AnkleFlex) * (1 - freeR);
    FootPitchL := AnklingFootPitch(CrankL, Ang, LivePose.AnkleFlex) * (1 - freeL);
  end;
  FTripoRider.FootPitchR := FootPitchR;   { roll the foot bone by the same angle }
  FTripoRider.FootPitchL := FootPitchL;
  FTripoRider.FootYawDeg := FTripoFootYawDeg;

  { hand grips: positions come from the bar's place_*_n bones, chosen by the pose's
    HandPos index. A change moves the hands one after the other (staggered windows
    set in ApplyRiderPose), so they don't both leave the bar at once. }
  if FHandAnimating then
  begin
    FHandAnimElapsed := FHandAnimElapsed + Dt;
    if FHandAnimDur <= 1e-6 then progHR := 1
    else progHR := FHandAnimElapsed / FHandAnimDur;
    if progHR >= 1 then
    begin
      FHandAnimating := False;
      FHandFromR := FTripoHandPosR; FHandFromL := FTripoHandPosL;
      FHandAnchorRValid:=False;FHandAnchorLValid:=False;
      progHR := 1; progHL := 1;
    end
    else
    begin
      progHL := SlotProg(progHR, FHandSlotL0, FHandSlotL1);
      progHR := SlotProg(progHR, FHandSlotR0, FHandSlotR1);
    end;
  end
  else begin progHR := 1; progHL := 1; end;

  { FROM-точка вычисляется один раз на руку (было — дважды в записи From+(To-From)*prog) }
  if FHandAnchorRValid then BoneA:=FHandAnchorR else begin
    BoneA := GripPlace('r', FHandFromR, FHandFromFreeRPos, FHandFromFreeRWave);
    if FHandFromR > 0 then BoneA := SteerPoint(BoneA);
  end;
  GripR := GripPlace('r', FTripoHandPosR, FTripoHandFreeRPos, FTripoHandFreeRWave);
  if FTripoHandPosR > 0 then GripR := SteerPoint(GripR);
  Alpha:=Min(0.025,(GripR-BoneA).Length*0.15);
  GripR := BoneA + (GripR - BoneA) * progHR;
  GripR.Y := GripR.Y + Alpha * Sqr(Sin(Pi * progHR));
  if FHandAnchorLValid then BoneB:=FHandAnchorL else begin
    BoneB := GripPlace('l', FHandFromL, FHandFromFreeLPos, FHandFromFreeLWave);
    if FHandFromL > 0 then BoneB := SteerPoint(BoneB);
  end;
  GripL := GripPlace('l', FTripoHandPosL, FTripoHandFreeLPos, FTripoHandFreeLWave);
  if FTripoHandPosL > 0 then GripL := SteerPoint(GripL);
  Alpha:=Min(0.025,(GripL-BoneB).Length*0.15);
  GripL := BoneB + (GripL - BoneB) * progHL;
  GripL.Y := GripL.Y + Alpha * Sqr(Sin(Pi * progHL));

  if FHandAnchorRValid then FromFrameR:=FHandAnchorFrameR
  else FromFrameR:=GripFrame(FHandFromR,0);
  if FHandAnchorLValid then FromFrameL:=FHandAnchorFrameL
  else FromFrameL:=GripFrame(FHandFromL,1);
  LivePose.HandFrameR:=BlendGripFrame(FromFrameR,GripFrame(FTripoHandPosR,0),progHR);
  LivePose.HandFrameL:=BlendGripFrame(FromFrameL,GripFrame(FTripoHandPosL,1),progHL);
  FFrameHandR:=LivePose.HandFrameR;FFrameHandL:=LivePose.HandFrameL;

  { shoulder twist: when the hands are at different fore-aft positions (e.g. mid-way
    through a staggered hand change — one hand already moved, the other not yet), yaw
    the shoulder line toward the leading hand. Zero when the grips are level (settled
    symmetric pose), so it appears only in the asymmetric intermediate position.
    Gain is deg per metre of fore-aft (X) asymmetry; flip its sign to mirror. }
  twistDeg := (GripR.X - GripL.X) * 220.0;
  if twistDeg >  22.0 then twistDeg :=  22.0;
  if twistDeg < -22.0 then twistDeg := -22.0;
  FTripoRider.AdaptPoseReach(LivePose, GripR, GripL);
  FTripoRider.ApplyFramePose(LivePose);
  FTripoRider.ShoulderTwistDeg := twistDeg;
  FFrameContacts[0] := AnkleR; FFrameContacts[1] := AnkleL;
  FFrameContacts[2] := GripR; FFrameContacts[3] := GripL;
  FFrameContactsValid:=True;

  { ── GPU-аним (этап 2): вся процедурная поза (ноги/спина/руки, LBS) считается
    в вершинном шейдере из uPhase. CPU шлёт только uniform'ы; UpdatePose и всё,
    что читает posed-позу рига (платформенные педали, Posed*-маркеры),
    пропускаем. Платформенные педали (PedalRightFoot/LeftFoot roll) под GpuAnim
    пока не обновляются — вернутся в этапе 4 вместе с байком в шейдере. ── }
  if FGpuAnim then
  begin
    if FGpuSkin = nil then
    begin
      FGpuSkin := TGpuRiderSkin.Create(FTripoRider);
      if not FGpuSkin.Build(nil) then
      begin
        StartupLog('[gpu-skin] build failed — райдер останется в bind-позе');
        FreeAndNil(FGpuSkin);
      end;
    end;
    T0u := Timer;   { TEMP-DIAG: GPU uniform sends (skin + spin) }
    if FGpuSkin <> nil then
    begin
      { этап 5: под GpuAnim UpdatePose не зовётся — joint-ноды не меняются,
        TransformationChanged не срабатывает, InternalUpdateSkin не планируется,
        Skin.InternalJointMatrix остаётся nil и skin-чанк движка НЕ попадает в
        программу (castleinternalrenderer_meshrenderer.inc: EnableSkinnedAnimation
        только при InternalJointMatrix<>nil). Тогда глобальной skinMatrix нашего
        плага не с кем мерджиться — inverse() от мусора взрывал меш (чёрный
        экран при GpuAnim=True со старта; после toggle CPU→GPU posed-кадры уже
        были, поэтому баг не проявлялся). Разовый posed-проход планирует skin-
        update: InternalJointMatrix создаётся и больше не сбрасывается. }
      if not FGpuSkinPrimed then
      begin
        FTripoRider.UpdatePose(AnkleR, AnkleL, GripR, GripL);
        { A glb with 0 animations may leave joints at rest; CGE then skips
          TransformationChanged and InternalJointMatrix stays nil. Force the
          rest/posed matrices now that the scene is mounted. }
        FTripoRider.EnsureNativeSkinReady;
        FGpuSkinPrimed := True;
        StartupLog('[gpu-skin] primed: разовый UpdatePose — skin-чанк движка включён');
      end;
      FGpuSkin.SendFrame(Phase, FTripoRider.Scene.InverseTransform,
        O(BB), CrankR, CrankL, QZ, FTripoPedalDir, GripR, GripL,
        O(LivePose.LegFreeRPos), O(LivePose.LegFreeLPos), LivePose);
    end;
    { этап 4: колёса/шатуны/педали — вращение в шейдере из тех же фаз }
    if FGpuSpin = nil then
    begin
      FGpuSpin := TGpuBikeSpin.Create(FTripoPedalDir);
      if (FBikeScene = nil) or (FBikeScene.RootNode = nil)
         or (not FGpuSpin.Build(FBikeScene.RootNode, FBikeScene, nil)) then
        FreeAndNil(FGpuSpin)
      else
        FBikeScene.ProcessEvents := True;   { Send() uniform'ов до GPU }
    end;
    if FGpuSpin <> nil then
      FGpuSpin.SendFrame(Phase, FWheelPhase, LivePose.AnkleFlex, 1 - freeR, 1 - freeL);
    T1u := Timer;
    FDiagGpuSend := FDiagGpuSend * 0.95 + TimerSeconds(T1u, T0u) * 1000 * 0.05;
    UpdateContactDebug(PedalR, PedalL, GripR, GripL,
      O(Saddle), O(Saddle) + LiveOffset + Vector3(0, Bob, Sway));
    UpdateShadowDynamic(O(BB), PedalR, PedalL);
    FUtrLastError := '';   { чистый кадр — следующее исключение снова залогируется }
    Exit;
  end;

  { the rider bakes each hand-contact marker (ArmContactR/L) to its wrist bone at
    load and lands it on the grip itself, so no pre-shift here. }
  T0u := Timer;   { TEMP-DIAG: IK }
  FTripoRider.UpdatePose(AnkleR, AnkleL, GripR, GripL);
  if not FGpuSkinPrimed then
  begin
    FTripoRider.EnsureNativeSkinReady;
    FGpuSkinPrimed := True;
  end;
  T1u := Timer;
  FDiagIK := FDiagIK * 0.95 + TimerSeconds(T1u, T0u) * 1000 * 0.05;

  { pedal follows the foot — AFTER the pose so the foot is solved. Tilt each pedal
    platform by the foot's FULL sagittal roll (leg-IK orientation + ankling), not
    just the ankling FootPitch, so the platform stays perpendicular to the cleat
    bone (90 deg, as at bind) — i.e. flat against the sole — through the stroke.
    On top of the route-driven level-keeping. Узлы кэшированы (OPT): кэш
    сбрасывается из NotifyBuildBegin/MountBikeIntoRider; no rider => identity
    and the route keeps it level. }
  T0u := Timer;   { TEMP-DIAG: pedals }
  if not FPedNodesValid then
  begin
    FPedFootR := nil; FPedFootL := nil;
    if Assigned(FBikeScene) and (FBikeScene.RootNode <> nil) then
    begin
      FPedFootR := FBikeScene.RootNode.FindNode(TTransformNode, 'PedalRightFoot', [fnNilOnMissing]) as TTransformNode;
      FPedFootL := FBikeScene.RootNode.FindNode(TTransformNode, 'PedalLeftFoot', [fnNilOnMissing]) as TTransformNode;
    end;
    FPedNodesValid := True;
  end;
  if FPedFootR <> nil then FPedFootR.FdRotation.Send(Vector4(0, 0, 1, FTripoRider.FootSagittalRoll(0) * (1 - freeR)));
  if FPedFootL <> nil then FPedFootL.FdRotation.Send(Vector4(0, 0, 1, FTripoRider.FootSagittalRoll(1) * (1 - freeL)));
  T1u := Timer;
  FDiagPedals := FDiagPedals * 0.95 + TimerSeconds(T1u, T0u) * 1000 * 0.05;

  { debug markers at the contact references; rider seat = where the pelvis lands
    (= scene origin + the scaled/yawed pelvis offset = O(Saddle)+offset+bob/sway) }
  T0u := Timer;   { TEMP-DIAG: contacts }
  UpdateContactDebug(PedalR, PedalL, GripR, GripL,
    O(Saddle), O(Saddle) + LiveOffset + Vector3(0, Bob, Sway));
  T1u := Timer;
  FDiagContacts := FDiagContacts * 0.95 + TimerSeconds(T1u, T0u) * 1000 * 0.05;

  { ── contact shadow: rider bones + crank arms. AFTER UpdatePose, so the
    rig's WorldPose (and Scene.Transform set above) are this frame's — the
    shadow pedals, leans and moves hands in sync with the skinned mesh. }
  T0u := Timer;   { TEMP-DIAG: shadow dyn }
  UpdateShadowDynamic(O(BB), PedalR, PedalL);
  T1u := Timer;
  FDiagShadowDyn := FDiagShadowDyn * 0.95 + TimerSeconds(T1u, T0u) * 1000 * 0.05;
  FUtrLastError := '';   { чистый кадр — следующее исключение снова залогируется }
  except
    on E: Exception do
    begin
      { prod-safety: исключение по-прежнему глотается (кадр пропускается), но
        лог идёт один раз на уникальное сообщение — повтор каждый кадр это
        спам, скрывающий остальной лог. Сброс дедуп-гварда — на чистом кадре. }
      if E.ClassName + ': ' + E.Message <> FUtrLastError then
      begin
        FUtrLastError := E.ClassName + ': ' + E.Message;
        StartupLog('[utrdiag] UpdateTripoRider exception: ' + FUtrLastError);
      end;
    end;
  end;
end;

procedure TBikeInstance.UpdateContactDebug(const PedalR, PedalL, GripR, GripL,
  SaddleW, RiderW: TVector3);
const
  DBG_R     = 0.025;   { target markers -> 5 cm diameter }
  DBG_CLEAT = 0.018;   { posed shoe cleats -> smaller, so they nest in the pedal ball }
var
  Root: TX3DRootNode;
  k: Integer;
  ClR, ClL, HnR, HnL: TVector3;

  function Ball(const Col: TVector3; Rad: Single): TTransformNode;
  var Sp: TSphereNode; Sh: TShapeNode; Ap: TAppearanceNode; Mt: TMaterialNode;
  begin
    Sp := TSphereNode.Create; Sp.Radius := Rad;
    Mt := TMaterialNode.Create;
    Mt.DiffuseColor  := Col;
    Mt.EmissiveColor := Vector3(Col.X*0.7, Col.Y*0.7, Col.Z*0.7);   { self-lit }
    Mt.Shininess     := 0.1;
    Ap := TAppearanceNode.Create; Ap.Material := Mt;
    Sh := TShapeNode.Create; Sh.Geometry := Sp; Sh.Appearance := Ap;
    Result := TTransformNode.Create; Result.AddChildren(Sh);
  end;

begin
  if not DebugContacts then
  begin
    if FContactDbgScene <> nil then FContactDbgScene.Exists := False;
    Exit;
  end;

  if FContactDbgScene = nil then
  begin
    Root := TX3DRootNode.Create;
    FContactDbgXf[0] := Ball(Vector3(1.00, 0.10, 0.10), DBG_R);     { pedal axle R — red }
    FContactDbgXf[1] := Ball(Vector3(0.55, 0.00, 0.00), DBG_R);     { pedal axle L — dark red }
    FContactDbgXf[2] := Ball(Vector3(0.15, 0.55, 1.00), DBG_R);     { hand grip  R — blue }
    FContactDbgXf[3] := Ball(Vector3(0.10, 0.90, 0.95), DBG_R);     { hand grip  L — cyan }
    FContactDbgXf[4] := Ball(Vector3(0.20, 1.00, 0.25), DBG_R);     { saddle       — green }
    FContactDbgXf[5] := Ball(Vector3(1.00, 0.85, 0.10), DBG_R);     { rider seat   — yellow }
    FContactDbgXf[6] := Ball(Vector3(1.00, 0.15, 1.00), DBG_CLEAT); { shoe cleat R — magenta }
    FContactDbgXf[7] := Ball(Vector3(0.65, 0.10, 1.00), DBG_CLEAT); { shoe cleat L — purple }
    FContactDbgXf[8] := Ball(Vector3(1.00, 0.50, 0.05), DBG_CLEAT); { palm R — orange }
    FContactDbgXf[9] := Ball(Vector3(1.00, 0.70, 0.30), DBG_CLEAT); { palm L — peach }
    for k := 0 to High(FContactDbgXf) do Root.AddChildren(FContactDbgXf[k]);
    FContactDbgScene := TCastleScene.Create(FOwner);
    FContactDbgScene.ProcessEvents := True;   { allow live FdTranslation.Send updates }
    FContactDbgScene.Load(Root, True);
    FGroup.Add(FContactDbgScene);
  end;

  FContactDbgScene.Exists := True;
  FContactDbgXf[0].FdTranslation.Send(PedalR);
  FContactDbgXf[1].FdTranslation.Send(PedalL);
  FContactDbgXf[2].FdTranslation.Send(GripR);
  FContactDbgXf[3].FdTranslation.Send(GripL);
  FContactDbgXf[4].FdTranslation.Send(SaddleW);
  FContactDbgXf[5].FdTranslation.Send(RiderW);

  { posed cleat markers on the shoes (BoatClipseR/L) — where the foot IK actually
    lands them; fall back to the pedal axle if a rig lacks the marker.
    Под GpuAnim posed-позы на CPU нет (поза в шейдере) — сразу фолбэк. }
  if (not FGpuAnim) and (FTripoRider <> nil) and FTripoRider.PosedContactParent(0, ClR) then
    FContactDbgXf[6].FdTranslation.Send(ClR)
  else FContactDbgXf[6].FdTranslation.Send(PedalR);
  if (not FGpuAnim) and (FTripoRider <> nil) and FTripoRider.PosedContactParent(1, ClL) then
    FContactDbgXf[7].FdTranslation.Send(ClL)
  else FContactDbgXf[7].FdTranslation.Send(PedalL);

  { posed palm markers on the hands (ArmContactR/L) — where the arm IK lands them;
    fall back to the grip if a rig lacks the marker }
  if (not FGpuAnim) and (FTripoRider <> nil) and FTripoRider.PosedContactParent(2, HnR) then
    FContactDbgXf[8].FdTranslation.Send(HnR)
  else FContactDbgXf[8].FdTranslation.Send(GripR);
  if (not FGpuAnim) and (FTripoRider <> nil) and FTripoRider.PosedContactParent(3, HnL) then
    FContactDbgXf[9].FdTranslation.Send(HnL)
  else FContactDbgXf[9].FdTranslation.Send(GripL);
end;

{ ═══════════════ ground contact shadow (analytic capsule shadow) ═══════════════

  A single unlit quad at wheel-contact height, alpha computed per-fragment
  from a set of capsules (A, B, radius) held in uniform arrays:

    - occlusion of each capsule falls off with the XZ distance to its axis
      (smoothstep), softened and attenuated by the capsule's HEIGHT above the
      ground -> "contact hardening": sharp dark shadow under the tires and
      feet, wide faint shadow under the head/bars. Exactly what a soft
      ambient-light shadow looks like, with no shadow maps and no textures.
    - contributions combine as vis *= 1 - o, so overlapping capsules (knee
      over the frame) do not double-darken.

  Static capsules (frame tubes from FBikeSkeleton bones + the two wheels as
  segments 2R long) are rebaked by RebuildShadowStatic on every build.
  Dynamic capsules (rider bones via TTripoRiderScene.PosedJointParent + the
  two crank arms) are rewritten each frame by UpdateShadowDynamic — the same
  pattern as the frame-tube shader: geometry stays put, uniforms move. }

procedure TBikeInstance.SetShowShadow(const V: Boolean);
begin
  FShowShadow := V;
  ApplyShadowMode;
end;

function TBikeInstance.EngineShadowSceneExists: Boolean;
begin
  Result := FShadowMapLight <> nil;
end;

procedure TBikeInstance.SetShadowStrength(const V: Single);
begin
  FShadowStrength := EnsureRange(V, 0.0, 1.0);
  if FShadowStrengthU <> nil then FShadowStrengthU.Send(FShadowStrength);
  { bsmCGE: сила тени — uniform кэtcher-эффекта (альфа из luminance). }
  if FShadowCatchStrengthU <> nil then FShadowCatchStrengthU.Send(FShadowStrength);
end;



procedure TBikeInstance.EnsureSteerAxisCache;
var
  HTB, HTT, Axis: TVector3;
  Len, CenterX: Single;
begin
  if FSteerAxisCached then Exit;
  FSteerAxisCached := True;
  FSteerAxis := Vector3(0, 1, 0);
  FSteerPivot := TVector3.Zero;
  if FBikeSkeleton = nil then Exit;
  CenterX := BikeCenterX(FBikeSkeleton);
  if FBikeSkeleton.TryGetBone('head_tube_bottom', HTB) then
    FSteerPivot := Vector3(HTB.X - CenterX, HTB.Y, HTB.Z)
  else if FBikeSkeleton.TryGetBone('stem_base', HTB) then
    FSteerPivot := Vector3(HTB.X - CenterX, HTB.Y, HTB.Z);
  if FBikeSkeleton.TryGetBone('head_tube_bottom', HTB)
     and FBikeSkeleton.TryGetBone('head_tube_top', HTT) then
  begin
    Axis := HTT - HTB;
    Len := Sqrt(Sqr(Axis.X) + Sqr(Axis.Y) + Sqr(Axis.Z));
    if Len > 1e-6 then
      FSteerAxis := Axis / Len;
  end
  else if (Abs(FBikeSkeleton.HTDirX) + Abs(FBikeSkeleton.HTDirY)) > 1e-6 then
  begin
    Len := Sqrt(Sqr(FBikeSkeleton.HTDirX) + Sqr(FBikeSkeleton.HTDirY));
    FSteerAxis := Vector3(FBikeSkeleton.HTDirX / Len, FBikeSkeleton.HTDirY / Len, 0);
  end;
end;

function TBikeInstance.TotalSteerAngleDeg: Single;
begin
  { One angle for SteerRot and both on-bar hands. The route provides the
    mean curvature; body dynamics supplies the small balance correction. }
  if BikeDebugDisableSteer then Exit(0);
  Result := FSteerAngleDeg;
  if FBodyDynamicsEnabled then Result:=Result+FPedalSteerDeg;
  if Result > 45 then Result := 45
  else if Result < -45 then Result := -45;
end;

function TBikeInstance.MeshSteerAngleDeg: Single;
begin
  { Continuous dynamics steering; the legacy path retains its quantization. }
  if FBodyDynamicsEnabled then Result:=TotalSteerAngleDeg
  else Result := Round(TotalSteerAngleDeg * 4) * 0.25;
end;

procedure TBikeInstance.DriveSteerNodes;

  procedure CollectSteer(N: TX3DNode);
  var I: Integer;
  begin
    if N = nil then Exit;
    if (N is TTransformNode) and (N.X3DName = 'SteerRot') then
      FSteerRots.Add(N);
    if N is TAbstractGroupingNode then
      for I := 0 to TAbstractGroupingNode(N).FdChildren.Count - 1 do
        CollectSteer(TAbstractGroupingNode(N).FdChildren[I]);
  end;

var
  I: Integer;
  Ang, MeshDeg, NodeDeg: Single;
  Ax: TVector3;
  TN: TTransformNode;
  R: TVector4;
  NeedWrite: Boolean;
begin
  if BikeDebugDisableSteer then Exit;
  EnsureSteerAxisCache;
  { Collect once; invalidate on mount/build (FSteerNodesValid := False).
    Full tree walk every frame was a temporary steer-diag cost (~8 SteerRot
    under multi-LOD) and dirtied nothing useful when the list was already good. }
  if (not FSteerNodesValid) or (FSteerRots = nil) then
  begin
    if FSteerRots = nil then
      FSteerRots := TList.Create
    else
      FSteerRots.Clear;
    if (FBikeScene <> nil) and (FBikeScene.RootNode <> nil) then
      CollectSteer(FBikeScene.RootNode);
    FSteerNodesValid := True;
  end;
  if FSteerRots.Count = 0 then Exit;

  MeshDeg := MeshSteerAngleDeg;
  Ang := DegToRad(MeshDeg);
  Ax := FSteerAxis;
  if FBodyDynamicsEnabled then NeedWrite:=Abs(MeshDeg-FSteerAngleApplied)>=0.002
  else NeedWrite := Abs(MeshDeg - FSteerAngleApplied) >= 0.12;
  for I := 0 to FSteerRots.Count - 1 do
  begin
    TN := TTransformNode(FSteerRots[I]);
    if TN = nil then Continue;
    { Detect external reset (LOD switch / reparent / silent field write):
      Applied says 12° but node is back at 0 → must rewrite. }
    R := TN.Rotation;
    NodeDeg := RadToDeg(R.W);
    if Abs(NodeDeg - MeshDeg) > 0.5 then
      NeedWrite := True;
  end;
  if not NeedWrite then Exit;

  FSteerAngleApplied := MeshDeg;
  for I := 0 to FSteerRots.Count - 1 do
  begin
    TN := TTransformNode(FSteerRots[I]);
    if TN = nil then Continue;
    { Prefer property write: after MountBikeIntoRider reparent, FdRotation.Send
      can be silent if Scene/event routing is stale; .Rotation goes through
      the setter and marks the shape tree dirty reliably. }
    TN.Rotation := Vector4(Ax.X, Ax.Y, Ax.Z, Ang);
  end;
end;

procedure TBikeInstance.DrivePedalLean;
var
  Ang,Yaw,RearShift: Single;
  Q:TTripoVec4;
begin
  if FGroup = nil then Exit;
  Yaw:=0;RearShift:=0;
  if FBodyDynamicsEnabled and FAnimationEnabled and not BikeDebugDisableSteer then begin
    Yaw:=FBodyDynamics.Frame.HeadingRad;
    RearShift:=FBodyDynamics.Frame.RearTrackM;
  end;
  { Public Group.Translation is also used to place editor comparison bikes.
    Change only our own previous displacement, preserving their base position. }
  if Abs(RearShift-FRearTrackApplied)>1e-7 then begin
    FGroup.Translation:=FGroup.Translation+Vector3(0,0,RearShift-FRearTrackApplied);
    FRearTrackApplied:=RearShift;
  end;
  FGroup.Center:=Vector3(-GetAxleHalfSpanM,0,0);
  if BikeDebugDisableSteer then
  begin
    FPedalLeanApplied := 0;
    FGroup.Rotation := Vector4(1, 0, 0, 0);
    Exit;
  end;
  FPedalLeanApplied := FPedalLeanDeg;
  Ang := DegToRad(FPedalLeanDeg);
  Q:=QuatNormalize(QuatMul(QuatFromAxisAngle(0,1,0,-Yaw),QuatFromAxisAngle(1,0,0,Ang)));
  Ang:=2*ArcCos(EnsureRange(Q.W,-1.0,1.0));
  if Abs(Ang)<1e-7 then FGroup.Rotation:=Vector4(1,0,0,0)
  else FGroup.Rotation:=Vector4(Q.X,Q.Y,Q.Z,Ang);
end;

function TBikeInstance.SteerPoint(const P: TVector3): TVector3;
var
  Ang: Single;
begin
  if BikeDebugDisableSteer then
    Exit(P);
  EnsureSteerAxisCache;
  { Must match MeshSteerAngleDeg / SteerRot — otherwise hands drift off bars. }
  Ang := DegToRad(MeshSteerAngleDeg);
  if Abs(Ang) < 1e-6 then
    Exit(P);
  Result := RotatePointAroundAxisRad(Ang, P - FSteerPivot, FSteerAxis) + FSteerPivot;
end;

procedure TBikeInstance.SetSteerAngleDeg(const V: Single);
begin
  if V > 45 then FSteerAngleDeg := 45
  else if V < -45 then FSteerAngleDeg := -45
  else FSteerAngleDeg := V;
end;

function TBikeInstance.GetAxleHalfSpanM: Single;
var RA, FA: TVector3;
begin
  { Скелет уже в метрах (см. лог капсульной тени: axle=(±0.4975, ...)). }
  if Assigned(FBikeSkeleton) and FBikeSkeleton.TryGetBone('rear_axle', RA)
     and FBikeSkeleton.TryGetBone('front_axle', FA) then
    Result := Abs(FA.X - RA.X) * 0.5
  else
    Result := 0;
end;

procedure TBikeInstance.SetShadowCatchGain(const V: Single);
begin
  FShadowCatchGain := EnsureRange(V, 0.1, 10.0);
  if FShadowCatchGainU <> nil then FShadowCatchGainU.Send(FShadowCatchGain);
end;

procedure TBikeInstance.SetShadowSunDir(const V: TVector3);
begin
  FShadowSunUseWorld := False;   { explicit LOCAL direction (editor mode) }
  FShadowSunDir := V;
  { must point downward; a horizontal/upward sun would project to infinity }
  if FShadowSunDir.Y > -0.1 then FShadowSunDir.Y := -0.1;
  if FShadowSunU <> nil then FShadowSunU.Send(FShadowSunDir);
  if FShadowMapLight <> nil then FShadowMapLight.Direction := FShadowSunDir;
  UpdateShadowMapProjection;
  SizeShadowCatcher;
  { the skewed shadow slides beyond the old quad — re-size it for the new
    direction из extents последнего бейка, без перебейка капсул }
  UpdateShadowQuadSize;
end;

procedure TBikeInstance.SetShadowSunIntensity(const V: Single);
begin
  FShadowSunIntensity := EnsureRange(V, 0.0, 32.0);
  if FShadowMapLight <> nil then
    FShadowMapLight.Intensity := FShadowSunIntensity;
end;

procedure TBikeInstance.SetShadowSunWorldDir(const V: TVector3);
begin
  if V.Length < 1e-6 then Exit;
  FShadowSunWorld := V.Normalize;
  FShadowSunUseWorld := True;
  { the local skew direction will rotate as the bike turns — re-size the
    quad with symmetric margins (see UpdateShadowQuadSize) }
  UpdateShadowQuadSize;
  ApplyWorldSunToShadow;   { immediate, if the group is already in a viewport }
end;

procedure TBikeInstance.UpdateShadowMapProjection;
const
  EDGE_PAD = 0.15;   { metres: tyre/helmet motion and PCF border }
  DEPTH_PAD = 0.75;  { terrain height variation near the contact plane }
  MAP_SIZE = 1024;
var
  Bounds: TBox3D;
  D, Side, UpHint, Up, C, P, Q, N, Eye: TVector3;
  MinX, MaxX, MinY, MaxY, MinD, MaxD: Single;
  Width, Height, X, Y, Z, Denom, Depth: Single;
  I: Integer;
begin
  if FShadowMapLight = nil then Exit;
  D := FShadowSunDir;
  if D.Length < 1e-6 then Exit;
  D := D.Normalize;
  { Use the rendered bike scene, excluding the separate catcher rig. Its
    cached bounds include the mounted rider and bike in the group frame.
    No skin readback, per-vertex scan or extra CPU IK is needed. }
  Bounds := TBox3D.Empty;
  if FBikeScene <> nil then Bounds := FBikeScene.BoundingBox;
  if Bounds.IsEmpty then
  begin
    Bounds.Include(Vector3(-1.0, 0.0, -0.45));
    Bounds.Include(Vector3(1.0, 2.0, 0.45));
  end;
  C := (Bounds.Data[0] + Bounds.Data[1]) * 0.5;
  UpHint := Vector3(0, 1, 0);
  if Abs(D.Y) > 0.99 then UpHint := Vector3(0, 0, 1);
  Side := TVector3.CrossProduct(D, UpHint).Normalize;
  Up := TVector3.CrossProduct(Side, D);
  FShadowMapLight.Up := UpHint;

  { Centre the footprint on the actual shadow side of the rider. Moving
    along a light ray preserves projected XY, so only a small border is
    needed instead of a symmetric several-metre reserve around the bike. }
  N := FShadowGroundN;
  if N.Length < 0.1 then N := Vector3(0, 1, 0);
  Denom := TVector3.DotProduct(N, D);
  if Abs(Denom) > 0.05 then
    Q := C + D * (N.Y * FShadowGroundY - TVector3.DotProduct(N, C)) / Denom
  else
    Q := C; { grazing light: keep a finite projector }
  MinX := 1e9; MaxX := -1e9; MinY := 1e9; MaxY := -1e9;
  MinD := 0; MaxD := 0;
  for I := 0 to 7 do
  begin
    P := Vector3(Bounds.Data[I and 1].X,
      Bounds.Data[(I shr 1) and 1].Y, Bounds.Data[(I shr 2) and 1].Z);
    P := P - Q;
    X := TVector3.DotProduct(Side, P);
    Y := TVector3.DotProduct(Up, P);
    Z := TVector3.DotProduct(D, P);
    MinX := Min(MinX, X); MaxX := Max(MaxX, X);
    MinY := Min(MinY, Y); MaxY := Max(MaxY, Y);
    MinD := Min(MinD, Z); MaxD := Max(MaxD, Z);
    if Abs(Denom) > 0.05 then
    begin
      { Include the receiver depths too, especially with low sun/slopes. }
      Depth := Z - TVector3.DotProduct(N, P) / Denom;
      MinD := Min(MinD, Depth); MaxD := Max(MaxD, Depth);
    end;
  end;
  { Quantise extents and centre to avoid sub-texel changes from tiny motion. }
  Width := Ceil((MaxX - MinX + 2 * EDGE_PAD) * 16) / 16;
  Height := Ceil((MaxY - MinY + 2 * EDGE_PAD) * 16) / 16;
  X := Round((MinX + MaxX) * 0.5 * MAP_SIZE / Width) * Width / MAP_SIZE;
  Y := Round((MinY + MaxY) * 0.5 * MAP_SIZE / Height) * Height / MAP_SIZE;
  Q := Q + Side * X + Up * Y;
  Eye := Q + D * (MinD - DEPTH_PAD);
  FShadowMapLight.FdProjectionLocation.Value := Eye;
  FShadowMapLight.FdProjectionRectangle.Value :=
    Vector4(-Width * 0.5, -Height * 0.5, Width * 0.5, Height * 0.5);
  FShadowMapLight.FdProjectionNear.Value := 0.1;
  FShadowMapLight.FdProjectionFar.Value := MaxD - MinD + 2 * DEPTH_PAD;
end;

procedure TBikeInstance.ApplyWorldSunToShadow;
var
  L: TVector3;
begin
  if not FShadowSunUseWorld then Exit;
  { Lighting must follow heading even with rider shadows or animation off.
    The rider scene has its own mounting transform, distinct from FGroup. }
  if FTripoRider <> nil then FTripoRider.SetWorldSunDirection(FShadowSunWorld);
  if (FShadowScene = nil) and (FShadowMapLight = nil) then Exit;
  if not FGroup.HasWorldTransform then Exit;   { not attached to a viewport yet }

  { world -> bike-group frame. MultDirection applies the rotation part of the
    parent chain (agent yaw along the route, model reorientation, lean). }
  L := FGroup.WorldInverseTransform.MultDirection(FShadowSunWorld);
  if L.Length < 1e-6 then Exit;
  L := L.Normalize;
  if L.Y > -0.1 then L.Y := -0.1;   { keep the ground projection finite even
                                      if a lean tips the frame extremely }
  if (L - FShadowSunDir).Length > 1e-3 then   { skip redundant uniform sends }
  begin
    FShadowSunDir := L;
    if FShadowSunU <> nil then FShadowSunU.Send(L);
    if FShadowMapLight <> nil then FShadowMapLight.Direction := L;
    UpdateShadowMapProjection;
    SizeShadowCatcher;
  end;
end;

procedure TBikeInstance.SetShadowMode(const V: TBikeShadowMode);
begin
  if FShadowMode = V then Exit;
  FShadowMode := V;
  ApplyShadowMode;
end;

procedure TBikeInstance.ApplyShadowMode;
begin
  StartupLog(Format('[bsmCGE] ApplyShadowMode: mode=%d show=%s rig=%s',
    [Ord(FShadowMode), BoolToStr(FShowShadow, True),
     BoolToStr(FShadowMapLight <> nil, True)]));
  { capsule quad exists only in bsmCapsules (the bake itself is kept — the
    static capsules survive mode round-trips, switching back is instant) }
  if FShadowScene <> nil then
    FShadowScene.Exists := FShowShadow and (FShadowMode = bsmCapsules);

  if FShadowMode = bsmCGE then
  begin
    { rig СНАЧАЛА возвращаем в граф: иначе форс-переразметка
      ProcessShadowMapsReceivers (FdShadows.Send ниже) проходит по сцене
      БЕЗ солнца, помечает UsesShadowMaps=False, и карты больше ни к чему
      не привязываются — теней нет (баг редактора). }
    if FShadowRigNode <> nil then
    begin
      if FShowShadow then
      begin
        if ShadowRigHost.FdChildren.IndexOf(FShadowRigNode) < 0 then
          ShadowRigHost.AddChildren(FShadowRigNode);
      end
      else
        ShadowRigHost.RemoveChildren(FShadowRigNode);
    end;
    EnsureShadowMapLight;
    { переразметка receivers уже с rig в графе — при каждом включении
      bsmCGE (первое создание catcher'а в EnsureShadowMapLight тоже
      форсит, но только один раз, а режим могут переключать туда-сюда) }
    if (FShadowMapLight <> nil) and FShowShadow then
    begin
      FShadowMapLight.FdShadows.Send(False);
      FShadowMapLight.FdShadows.Send(True);
    end;
    SizeShadowCatcher;
  end
  else
  begin
    if (FShadowRigNode <> nil) and
       (ShadowRigHost.FdChildren.IndexOf(FShadowRigNode) >= 0) then
      ShadowRigHost.RemoveChildren(FShadowRigNode);
  end;
end;

procedure TBikeInstance.SizeShadowCatcher;
var
  C: TVector3;
  P: array[0..3] of TVector3;
  I: Integer;
  DX, DZ, HLen, Stretch, SX, SZ: Single;
begin
  { base the catcher on the capsule quad's corners (ground lift + terrain
    tilt), but EXPAND it: the capsule quad is tight around the bike, while
    the map shadow stretches sideways with the sun angle — a tight catcher
    visibly clips the shadow. Guard on a NON-zero Y so we don't clobber a
    good build-time size (Y=0.05) with the capsule quad's pre-build
    placeholder (Y=0). }
  if (FShadowCatchCoord = nil) or (FShadowCoord = nil)
     or (FShadowCoord.FdPoint.Items.Count <> 4)
     or (Abs(FShadowCoord.FdPoint.Items[0].Y) <= 0.001) then Exit;
  C := TVector3.Zero;
  for I := 0 to 3 do
    C := C + FShadowCoord.FdPoint.Items[I];
  C := C * 0.25;
  { сдвиг центра квада туда, куда падает тень: на каждый метр высоты
    caster'а — HLen/|Y| метра смещения; высота байка с райдером ~1.8 м }
  DX := FShadowSunDir.X; DZ := FShadowSunDir.Z;
  HLen := Sqrt(DX * DX + DZ * DZ);
  SX := 0; SZ := 0;
  if HLen > 1e-4 then
  begin
    Stretch := 1.8 * HLen / Max(0.2, Abs(FShadowSunDir.Y));
    SX := DX / HLen * Stretch * 0.5;
    SZ := DZ / HLen * Stretch * 0.5;
  end;
  for I := 0 to 3 do
  begin
    P[I] := C + (FShadowCoord.FdPoint.Items[I] - C) * 2.0
          + Vector3(SX, BikeShadowQuadLift, SZ);   { lift: anti-z-fight + ДИАГ }
    { clamp: капсульный квад в игре может быть огромным (симметричные
      марджины под world-sun) — catcher больше ~±4 м не нужен и вреден }
    if P[I].X - C.X - SX >  4 then P[I].X := C.X + SX + 4;
    if P[I].X - C.X - SX < -4 then P[I].X := C.X + SX - 4;
    if P[I].Z - C.Z - SZ >  4 then P[I].Z := C.Z + SZ + 4;
    if P[I].Z - C.Z - SZ < -4 then P[I].Z := C.Z + SZ - 4;
  end;
  FShadowCatchCoord.FdPoint.Send([P[0], P[1], P[2], P[3]]);
end;

{ ── MCP-обёртки света райдера (published-свойства) ── }

function TBikeInstance.GetMcpRiderEnv: Single;
begin
  if FTripoRider <> nil then
    Result := FTripoRider.RiderEnvIntensity
  else
    Result := 0.0;
end;

procedure TBikeInstance.SetMcpRiderEnv(const V: Single);
begin
  if FTripoRider <> nil then
    FTripoRider.RiderEnvIntensity := V;
end;

function TBikeInstance.GetMcpRiderKey: Single;
begin
  if FTripoRider <> nil then
    Result := FTripoRider.RiderKeyIntensity
  else
    Result := 0.0;
end;

procedure TBikeInstance.SetMcpRiderKey(const V: Single);
begin
  if FTripoRider <> nil then
    FTripoRider.RiderKeyIntensity := V;
end;

function TBikeInstance.GetMcpRiderFill: Single;
begin
  if FTripoRider <> nil then
    Result := FTripoRider.RiderFillIntensity
  else
    Result := 0.0;
end;

procedure TBikeInstance.SetMcpRiderFill(const V: Single);
begin
  if FTripoRider <> nil then
    FTripoRider.RiderFillIntensity := V;
end;

function TBikeInstance.GetMcpRiderLightDiag: String;
begin
  if FTripoRider <> nil then
    Result := FTripoRider.LightDiag
  else
    Result := 'rider=nil';
end;

function TBikeInstance.GroundShadowMap: TGeneratedShadowMapNode;
begin
  { Called after posing: fit once to the current bike/rider bounds. }
  if (FShadowMode = bsmCGE) and FShowShadow then UpdateShadowMapProjection;
  Result := nil;
  if (FShadowMode = bsmCGE) and FShowShadow and
     (FShadowMapLight <> nil) and
     (FShadowMapLight.FdDefaultShadowMap.Value is TGeneratedShadowMapNode) then
    Result := TGeneratedShadowMapNode(FShadowMapLight.FdDefaultShadowMap.Value);
end;

procedure TBikeInstance.SetGroundShadowReceiver(const Enabled: Boolean);
begin
  FGroundShadowReceiver := Enabled;
  if FShadowCatchShapeNode <> nil then
    FShadowCatchShapeNode.Visible := not Enabled;
end;

function TBikeInstance.GetShadowMapDiag: String;
var
  SM: TX3DNode;
  G: TGeneratedShadowMapNode;
  Shapes: TShapeList;
  Sh: TShape;
  I: Integer;
  LNames: String;
  P0, PW: TVector3;
begin
  if FShadowMapLight = nil then Exit('light=nil');
  Result := Format('light(on=%s sh=%s glob=%s int=%.2f dir=%.2f,%.2f,%.2f rig=%s)',
    [BoolToStr(FShadowMapLight.FdOn.Value, True),
     BoolToStr(FShadowMapLight.FdShadows.Value, True),
     BoolToStr(FShadowMapLight.FdGlobal.Value, True),
     FShadowMapLight.FdIntensity.Value,
     FShadowMapLight.Direction.X, FShadowMapLight.Direction.Y,
     FShadowMapLight.Direction.Z,
     BoolToStr((FShadowRigNode <> nil) and
       (ShadowRigHost.FdChildren.IndexOf(FShadowRigNode) >= 0), True)]);
  Result := Result + Format(' proj=(%.3f,%.3f,%.3f,%.3f)',
    [FShadowMapLight.ProjectionRectangle.X, FShadowMapLight.ProjectionRectangle.Y,
     FShadowMapLight.ProjectionRectangle.Z, FShadowMapLight.ProjectionRectangle.W]);
  SM := FShadowMapLight.FdDefaultShadowMap.Value;
  if SM = nil then
    Result := Result + ' mapnode=nil'
  else
  begin
    Result := Result + ' mapnode=' + SM.ClassName;
    if SM is TGeneratedShadowMapNode then
    begin
      G := TGeneratedShadowMapNode(SM);
      Result := Result + Format('(size=%d upd=%d)',
        [G.Size, Ord(G.GenTexFunctionality.Update)]);
    end;
  end;
  if FShadowRigScene <> nil then
    Result := Result + Format(' rigscene(sm=%s gentex=%d)',
      [BoolToStr(FShadowRigScene.ShadowMaps, True),
       FShadowRigScene.InternalGeneratedTextures.Count]);
  { положение квадов: local (bike frame) и world — где catcher/капсульный
    квад относительно террейна }
  Result := Result + Format(' mode=%d show=%s gy=%.3f',
    [Ord(FShadowMode), BoolToStr(FShowShadow, True), FShadowGroundY]);
  if (FShadowCoord <> nil) and (FShadowCoord.FdPoint.Items.Count >= 4) then
    Result := Result + Format(' capq=(%.2f,%.2f,%.2f)',
      [FShadowCoord.FdPoint.Items[0].X, FShadowCoord.FdPoint.Items[0].Y,
       FShadowCoord.FdPoint.Items[0].Z])
  else
    Result := Result + ' capq=nil';
  if (FShadowCatchCoord <> nil) and (FShadowCatchCoord.FdPoint.Items.Count >= 4) then
  begin
    P0 := FShadowCatchCoord.FdPoint.Items[0];
    Result := Result + Format(' catch=(%.2f,%.2f,%.2f)', [P0.X, P0.Y, P0.Z]);
    if FGroup.HasWorldTransform then
    begin
      PW := FGroup.WorldTransform.MultPoint(P0);
      Result := Result + Format(' catchw=(%.2f,%.2f,%.2f)', [PW.X, PW.Y, PW.Z]);
    end;
  end
  else
    Result := Result + ' catch=nil';
  if FGroup.HasWorldTransform then
    Result := Result + Format(' grp=(%.2f,%.2f,%.2f)',
      [FGroup.WorldTransform[3, 0], FGroup.WorldTransform[3, 1],
       FGroup.WorldTransform[3, 2]]);
  if FShadowCatchShapeNode <> nil then
    Result := Result + ' catchvisible=' + BoolToStr(FShadowCatchShapeNode.Visible, True);
  if FShadowCatchShapeNode = nil then
    Result := Result + ' catch=nil'
  else
  begin
    Sh := nil;
    if FShadowRigScene <> nil then
    begin
      Shapes := FShadowRigScene.Shapes.TraverseList(False);
      for I := 0 to Shapes.Count - 1 do
        if Shapes[I].Node = FShadowCatchShapeNode then
        begin
          Sh := Shapes[I];
          Break;
        end;
    end;
    if Sh = nil then
      Result := Result + ' catch=noTShape'
    else
    begin
      if Sh.InternalShadowMaps = nil then
        Result := Result + ' ism=nil'
      else
        Result := Result + Format(' ism=%d', [Sh.InternalShadowMaps.Count]);
      if Sh.State.Lights = nil then
        Result := Result + ' lights=nil'
      else
      begin
        LNames := '';
        for I := 0 to Sh.State.Lights.Count - 1 do
          LNames := LNames + Sh.State.Lights.L[I].Node.X3DName + ',';
        Result := Result + Format(' lights=%d[%s]',
          [Sh.State.Lights.Count, LNames]);
      end;
    end;
  end;
end;

procedure TBikeInstance.EnsureShadowMapLight;
var
  I: Integer;
  S: TCastleScene;
  Shape: TShapeNode;
  IFS: TIndexedFaceSetNode;
  App: TAppearanceNode;
  Blend: TBlendModeNode;
  Effect: TEffectNode;
  PartF: TEffectPartNode;
  Src: string;
begin
  if FShadowCatchCoord <> nil then Exit;

  { ── Engine shadow (shadow MAPS) в ЕДИНОЙ сцене байка. ──
    Источник уже создан в Create (до Scene.Load — см. там комментарий).
    Здесь — только catcher-квад и его эффект. }

  { The catcher: a horizontal quad at ground height (default size — далее
    ApplyShadowMode пересчитывает от капсульного квада с расширением). }
  FShadowCatchCoord := TCoordinateNode.Create;
  FShadowCatchCoord.FdPoint.Items.Add(Vector3(-3, 0, -3));
  FShadowCatchCoord.FdPoint.Items.Add(Vector3( 3, 0, -3));
  FShadowCatchCoord.FdPoint.Items.Add(Vector3( 3, 0,  3));
  FShadowCatchCoord.FdPoint.Items.Add(Vector3(-3, 0,  3));

  IFS := TIndexedFaceSetNode.Create;
  IFS.Coord := FShadowCatchCoord;
  IFS.Solid := False;
  IFS.FdCoordIndex.Items.Add(0);
  IFS.FdCoordIndex.Items.Add(1);
  IFS.FdCoordIndex.Items.Add(2);
  IFS.FdCoordIndex.Items.Add(3);
  IFS.FdCoordIndex.Items.Add(-1);

  { catcher: lit БЕЛЫЙ материал + fragment-эффект, превращающий освещённость
    в альфу: на свету lum≈1 -> alpha 0 (приёмник ПРОЗРАЧНЫЙ), в тени
    lum≈0 -> alpha = strength (чёрная тень). Обычный alpha-blending
    (SRC_ALPHA / ONE_MINUS_SRC_ALPHA). Multiply-подход (DST_COLOR*src)
    давал чёрный непрозрачный квад: освещённый catcher серый (~0.6),
    multiply по светлому фону затемнял его целиком.
    BikeShadowCatcherBlend=False — диагностика: белый opaque квад. }
  FShadowCatchMat := TMaterialNode.Create;
  FShadowCatchMat.DiffuseColor := Vector3(1, 1, 1);
  { чуть >0: иначе шейп идёт в opaque-проход и BlendMode игнорируется.
    ДИАГ: при BikeShadowCatcherBlend=False — честный opaque, проверка
    приёма карты без transparent-прохода. }
  if BikeShadowCatcherBlend then FShadowCatchMat.Transparency := 0.01;

  Blend := TBlendModeNode.Create;
  Blend.SrcFactor := bsSrcAlpha;
  Blend.DestFactor := bdOneMinusSrcAlpha;

  App := TAppearanceNode.Create;
  { CastShadows=False on the scene does not exclude shadow-map casters. }
  App.ShadowCaster := False;
  App.Material := FShadowCatchMat;
  if BikeShadowCatcherBlend then App.BlendMode := Blend;

  { luminance -> alpha. PLUG_fragment_modify вызывается ПОСЛЕ lighting_apply
    (main_shading_phong.fs), поэтому fragment_color уже содержит свет со
    встроенной картой теней — читаем результат напрямую, без доступа к
    castle_shadow_map_N. shGain компенсирует недобор яркости материала. }
  Effect := TEffectNode.Create;
  Effect.Language := slGLSL;
  FShadowCatchStrengthU := TSFFloat.Create(Effect, true, 'shStrength', FShadowStrength);
  Effect.AddCustomField(FShadowCatchStrengthU);
  FShadowCatchGainU := TSFFloat.Create(Effect, true, 'shGain', FShadowCatchGain);
  Effect.AddCustomField(FShadowCatchGainU);
  PartF := TEffectPartNode.Create;
  PartF.FdType.Value := 'FRAGMENT';
  Src := '';
  Src := Src + 'uniform float shStrength;' + LineEnding;
  Src := Src + 'uniform float shGain;' + LineEnding;
  Src := Src + 'void PLUG_fragment_modify(inout vec4 fragment_color){' + LineEnding;
  Src := Src + '  float lum = dot(fragment_color.rgb, vec3(0.299, 0.587, 0.114));' + LineEnding;
  Src := Src + '  float a = clamp(1.0 - lum * shGain, 0.0, 1.0) * shStrength;' + LineEnding;
  Src := Src + '  fragment_color = vec4(0.0, 0.0, 0.0, a);' + LineEnding;
  Src := Src + '}' + LineEnding;
  PartF.Contents := Src;
  Effect.FdParts.Add(PartF);
  if BikeShadowCatcherBlend then App.SetEffects([Effect]);
  FShadowCatchApp := App;   { диаг: доступ к текстуре catcher'а }
  { Явный приём карты от нашего солнца (помимо lights-on-everything). }
  App.FdReceiveShadows.Add(FShadowMapLight);

  Shape := TShapeNode.Create;
  Shape.Geometry := IFS;
  Shape.Appearance := App;
  Shape.Visible := not FGroundShadowReceiver;
  FShadowCatchShapeNode := Shape;   { bsmCGE ДИАГ: GetShadowMapDiag ищет по нему TShape }
  { Rig с источником уже в общем графе (Create) — добавляем только catcher. }
  FShadowRigNode.AddChildren(Shape);
  { Повторный chShadowMaps: переразметка приёмников карты (первый проход
    был на Load, когда шейпов ещё не было). Send с тем же значением может
    быть no-op, поэтому явно false→true. }
  FShadowMapLight.FdShadows.Send(false);
  FShadowMapLight.FdShadows.Send(true);
  StartupLog('[bsmCGE] catcher quad + effect added to unified scene');

  { Casters — вся единая сцена (рама/колёса/шатун/райдер): для карт это
    глубина из источника, дёшево. ReceiveShadowVolumes=False — в volume
    проход (если он где-то есть) байк не входит. }
  S := FBikeScene;
  if S <> nil then
  begin
    S.CastShadows := True;
    S.RenderOptions.WholeSceneManifold := True;
    S.ReceiveShadowVolumes := False;
  end;

  { the capsule quad must never appear in the shadow pass }
  if FShadowScene <> nil then FShadowScene.CastShadows := False;
end;

procedure TBikeInstance.SetShadowSoftness(const V: Single);
begin
  FShadowSoftness := EnsureRange(V, 0.05, 1.5);
  if FShadowSoftU <> nil then FShadowSoftU.Send(FShadowSoftness);
end;

procedure TBikeInstance.SetShadowHardEdge(const V: Boolean);
begin
  FShadowHardEdge := V;
  if FShadowHardU <> nil then
    if V then FShadowHardU.Send(1.0) else FShadowHardU.Send(0.0);
end;

procedure TBikeInstance.RebuildShadowQuadTilt;
const
  LIFT = 0.03;    { ~3 cm above the ground plane, along its normal: stops
                    z-fighting AND helps the quad clear small terrain bumps
                    between the plane-fit sample points (the fitted plane is
                    flat, real terrain wiggles under it) }
var
  N: TVector3;
  invNy, GyL: Single;
  function CornerY(X, Z: Single): Single;
  begin
    { plane through P0=(0,GyL,0), normal N: N.x*x + N.y*(y-GyL) + N.z*z = 0
      -> y = GyL - (N.x*x + N.z*z)/N.y }
    Result := GyL - (N.X * X + N.Z * Z) * invNy;
  end;
begin
  if FShadowCoord = nil then Exit;
  N := FShadowGroundN;
  if Abs(N.Y) < 0.2 then N.Y := 0.2;   { guard (setter already clamps to >=0.77) }
  invNy := 1.0 / N.Y;
  { raise the plane by LIFT measured ALONG the normal: moving the plane a
    distance LIFT in the +N direction shifts its height by LIFT / N.Y in Y }
  GyL := FShadowQGy + LIFT * invNy + BikeShadowQuadLift;   { +ДИАГ-подъём }
  { corners span the cached XZ extents; Y follows the (lifted) tilted plane so
    the quad floats just above the ground slope the shader projects onto }
  FShadowCoord.FdPoint.Send([
    Vector3(FShadowQMinX, CornerY(FShadowQMinX, FShadowQMinZ), FShadowQMinZ),
    Vector3(FShadowQMaxX, CornerY(FShadowQMaxX, FShadowQMinZ), FShadowQMinZ),
    Vector3(FShadowQMaxX, CornerY(FShadowQMaxX, FShadowQMaxZ), FShadowQMaxZ),
    Vector3(FShadowQMinX, CornerY(FShadowQMinX, FShadowQMaxZ), FShadowQMaxZ)]);
  if FShadowGroundN.Y < 0.985 then
    StartupLog(Format('[shadow] quad Y corners: %.3f %.3f %.3f %.3f (Gy=%.3f lifted=%.3f)',
      [CornerY(FShadowQMinX, FShadowQMinZ), CornerY(FShadowQMaxX, FShadowQMinZ),
       CornerY(FShadowQMaxX, FShadowQMaxZ), CornerY(FShadowQMinX, FShadowQMaxZ),
       FShadowQGy, GyL]));
end;

procedure TBikeInstance.SetShadowGroundNormal(const V: TVector3);
var
  N: TVector3;
  LenN: Single;
begin
  N := V;
  LenN := N.Length;
  if LenN < 1e-6 then N := Vector3(0, 1, 0) else N := N / LenN;
  { clamp how far the shadow plane may tilt: past ~40° the flat-plane
    approximation of bumpy ground looks worse than a small mismatch, and a
    near-vertical plane would make the projection explode }
  if N.Y < 0.77 then   { cos 40deg ~ 0.766 }
  begin
    N.Y := 0.77;
    N := N.Normalize;
  end;
  FShadowGroundN := N;

  { the shader gets the normal (it projects capsules onto the tilted plane);
    the quad geometry is re-tilted to the same plane in RebuildShadowStatic /
    here so the painted shadow sits on the slope. We DON'T rotate FShadowScene
    (that would move the quad's object space out of the FGroup frame the
    capsules live in); instead the quad corners carry the tilt directly. }
  if FShadowGroundNU <> nil then FShadowGroundNU.Send(FShadowGroundN);
  RebuildShadowQuadTilt;
  if FShadowGroundN.Y < 0.985 then   { > ~10deg: log so we can verify it fires }
    StartupLog(Format('[shadow] ground normal in=(%.3f,%.3f,%.3f) used=(%.3f,%.3f,%.3f) tilt=%.1fdeg',
      [V.X, V.Y, V.Z, FShadowGroundN.X, FShadowGroundN.Y, FShadowGroundN.Z,
       RadToDeg(ArcCos(EnsureRange(FShadowGroundN.Y, -1.0, 1.0)))]));
end;

procedure TBikeInstance.EnsureShadowQuad;
var
  Root: TX3DRootNode;
  IFS: TIndexedFaceSetNode;
  Shape: TShapeNode;
  App: TAppearanceNode;
  Mat: TUnlitMaterialNode;
  Effect: TEffectNode;
  PartV, PartF: TEffectPartNode;
  Src: string;
  Zeros: array of TVector3;
  ZeroR: array of Single;
begin
  if FShadowScene <> nil then Exit;

  { ── quad geometry: 4 corners, repositioned by RebuildShadowStatic ── }
  FShadowCoord := TCoordinateNode.Create;
  FShadowCoord.FdPoint.Items.Add(Vector3(-1, 0, -1));
  FShadowCoord.FdPoint.Items.Add(Vector3( 1, 0, -1));
  FShadowCoord.FdPoint.Items.Add(Vector3( 1, 0,  1));
  FShadowCoord.FdPoint.Items.Add(Vector3(-1, 0,  1));

  IFS := TIndexedFaceSetNode.Create;
  IFS.Coord := FShadowCoord;
  IFS.Solid := False;                       { visible from below the ground too }
  IFS.FdCoordIndex.Items.Add(0);
  IFS.FdCoordIndex.Items.Add(1);
  IFS.FdCoordIndex.Items.Add(2);
  IFS.FdCoordIndex.Items.Add(3);
  IFS.FdCoordIndex.Items.Add(-1);

  { ── unlit black, base alpha 0: fully transparent unless the shader effect
    writes alpha. Transparency = 1 also switches CGE to blending for this
    shape, and degrades gracefully (invisible quad) if the effect ever fails
    to compile on some GL. ── }
  Mat := TUnlitMaterialNode.Create;
  Mat.EmissiveColor := Vector3(0, 0, 0);
  Mat.Transparency := 1.0;
  App := TAppearanceNode.Create;
  App.Material := Mat;

  { ── capsule uniforms. MF fields map to GLSL uniform arrays; they are kept
    padded to SHADOW_MAX_CAPS so the array size always matches the shader
    declaration — the fragment loop stops at capN. ── }
  Effect := TEffectNode.Create;
  Effect.Language := slGLSL;
  { динамические массивы уже нулевые после SetLength — обнулять не нужно }
  SetLength(Zeros, SHADOW_MAX_CAPS);
  SetLength(ZeroR, SHADOW_MAX_CAPS);
  FShadowCapA := TMFVec3f.Create(Effect, true, 'capA', Zeros);
  Effect.AddCustomField(FShadowCapA);
  FShadowCapB := TMFVec3f.Create(Effect, true, 'capB', Zeros);
  Effect.AddCustomField(FShadowCapB);
  FShadowCapRA := TMFFloat.Create(Effect, true, 'capRA', ZeroR);
  Effect.AddCustomField(FShadowCapRA);
  FShadowCapRB := TMFFloat.Create(Effect, true, 'capRB', ZeroR);
  Effect.AddCustomField(FShadowCapRB);
  FShadowCapN := TSFInt32.Create(Effect, true, 'capN', 0);
  Effect.AddCustomField(FShadowCapN);
  FShadowGroundU := TSFFloat.Create(Effect, true, 'shGroundY', 0.0);
  Effect.AddCustomField(FShadowGroundU);
  FShadowStrengthU := TSFFloat.Create(Effect, true, 'shStrength', FShadowStrength);
  Effect.AddCustomField(FShadowStrengthU);
  FShadowSunU := TSFVec3f.Create(Effect, true, 'shSunDir', FShadowSunDir);
  StartupLog(Format('[shadow] capsule shader sun dir = (%.3f, %.3f, %.3f)',
    [FShadowSunDir.X, FShadowSunDir.Y, FShadowSunDir.Z]));
  Effect.AddCustomField(FShadowSunU);
  FShadowSoftU := TSFFloat.Create(Effect, true, 'shSoftK', FShadowSoftness);
  Effect.AddCustomField(FShadowSoftU);
  { init from the field, not a hardcoded 1.0 (that left the shader stuck in
    crisp mode even though FShadowHardEdge defaults False -> no blur ever) }
  if FShadowHardEdge then
    FShadowHardU := TSFFloat.Create(Effect, true, 'shHardEdge', 1.0)
  else
    FShadowHardU := TSFFloat.Create(Effect, true, 'shHardEdge', 0.0);
  Effect.AddCustomField(FShadowHardU);
  { ground-plane normal (bike frame); (0,1,0) = flat = old behaviour }
  FShadowGroundNU := TSFVec3f.Create(Effect, true, 'shGroundN', FShadowGroundN);
  Effect.AddCustomField(FShadowGroundNU);

  { vertex: pass the object-space position (quad scene has no transforms, so
    object space == the O-centred FGroup frame the capsules live in) }
  PartV := TEffectPartNode.Create;
  PartV.FdType.Value := 'VERTEX';
  Src := '';
  Src := Src + 'varying vec3 shadowPos;' + LineEnding;
  Src := Src + 'void PLUG_vertex_object_space(inout vec4 vertex,inout vec3 normal){' + LineEnding;
  Src := Src + '  shadowPos = vertex.xyz;' + LineEnding;
  Src := Src + '}' + LineEnding;
  PartV.Contents := Src;
  Effect.FdParts.Add(PartV);

  { fragment: per-pixel capsule occlusion with height-based softening }
  PartF := TEffectPartNode.Create;
  PartF.FdType.Value := 'FRAGMENT';
  Src := '';
  Src := Src + 'varying vec3 shadowPos;' + LineEnding;
  Src := Src + 'uniform vec3 capA[' + IntToStr(SHADOW_MAX_CAPS) + '];' + LineEnding;
  Src := Src + 'uniform vec3 capB[' + IntToStr(SHADOW_MAX_CAPS) + '];' + LineEnding;
  Src := Src + 'uniform float capRA[' + IntToStr(SHADOW_MAX_CAPS) + '];' + LineEnding;
  Src := Src + 'uniform float capRB[' + IntToStr(SHADOW_MAX_CAPS) + '];' + LineEnding;
  Src := Src + 'uniform int capN;' + LineEnding;
  Src := Src + 'uniform float shGroundY;' + LineEnding;
  Src := Src + 'uniform float shStrength;' + LineEnding;
  Src := Src + 'uniform vec3 shSunDir;' + LineEnding;
  Src := Src + 'uniform float shSoftK;' + LineEnding;
  Src := Src + 'uniform float shHardEdge;' + LineEnding;  { >0.5 = crisp silhouettes (diagnostic) }
  Src := Src + 'uniform vec3 shGroundN;' + LineEnding;    { ground-plane normal in bike frame (0,1,0)=flat }
  Src := Src + 'void PLUG_fragment_modify(inout vec4 fragment_color){' + LineEnding;
  Src := Src + '  float vis = 1.0;' + LineEnding;
  { The shadow lands on a (possibly tilted) ground plane through the point
    P0 = (0, shGroundY, 0) with normal shGroundN. The fragment shadowPos lies
    ON that plane (the quad is oriented to it). We project each capsule
    endpoint along the sun onto the plane in 3D and measure distance there,
    so proportions follow the slope correctly.
    Plane/ray intersection: for point Q travelling along L (sun), the hit is
    Q + L * t with t = dot(N, P0 - Q) / dot(N, L). }
  Src := Src + '  vec3 N = normalize(shGroundN);' + LineEnding;
  Src := Src + '  vec3 P0 = vec3(0.0, shGroundY, 0.0);' + LineEnding;
  { sun travel direction; clamp so it never grazes the plane (dot(N,L) small
    -> runaway projection). Keep it pointing into the plane (dot(N,L) < 0). }
  Src := Src + '  vec3 L = shSunDir;' + LineEnding;
  Src := Src + '  float nl = dot(N, L);' + LineEnding;
  Src := Src + '  nl = min(nl, -0.35);' + LineEnding;   { steeper floor than -0.1: avoids absurd streaks }
  Src := Src + '  vec3 fp = shadowPos;' + LineEnding;
  Src := Src + '  for (int i = 0; i < ' + IntToStr(SHADOW_MAX_CAPS) + '; i++) {' + LineEnding;
  Src := Src + '    if (i >= capN) break;' + LineEnding;
  { project both capsule endpoints along the sun onto the tilted plane }
  Src := Src + '    float ta = dot(N, P0 - capA[i]) / nl;' + LineEnding;
  Src := Src + '    float tb = dot(N, P0 - capB[i]) / nl;' + LineEnding;
  Src := Src + '    vec3 a = capA[i] + L * ta;' + LineEnding;
  Src := Src + '    vec3 b = capB[i] + L * tb;' + LineEnding;
  Src := Src + '    vec3 ba = b - a;' + LineEnding;
  Src := Src + '    float t = clamp(dot(fp - a, ba) / max(dot(ba, ba), 1e-6), 0.0, 1.0);' + LineEnding;
  Src := Src + '    float d = length(fp - a - ba * t);' + LineEnding;
  { height of the nearest capsule point above the plane (perpendicular
    distance), for contact hardening — bigger height -> softer, weaker }
  Src := Src + '    vec3 capPt = mix(capA[i], capB[i], t);' + LineEnding;
  Src := Src + '    float h = max(dot(N, capPt - P0), 0.0);' + LineEnding;
  Src := Src + '    float r = mix(capRA[i], capRB[i], t);' + LineEnding;  { tapered capsule }
  Src := Src + '    float o;' + LineEnding;
  Src := Src + '    if (shHardEdge > 0.5) {' + LineEnding;
  Src := Src + '      o = 1.0 - step(r, d);' + LineEnding;   { crisp: full inside r, none outside; no penumbra/height falloff }
  Src := Src + '    } else {' + LineEnding;
  Src := Src + '      float soft = 0.9 * r + shSoftK * h + 0.06;' + LineEnding;
  Src := Src + '      o = 1.0 - smoothstep(r * 0.15, r + soft, d);' + LineEnding;
  Src := Src + '      o *= 1.0 / (1.0 + 2.2 * h);' + LineEnding;
  Src := Src + '    }' + LineEnding;
  Src := Src + '    vis *= 1.0 - o;' + LineEnding;
  Src := Src + '  }' + LineEnding;
  Src := Src + '  fragment_color = vec4(0.0, 0.0, 0.0, (1.0 - vis) * shStrength);' + LineEnding;
  Src := Src + '}' + LineEnding;
  PartF.Contents := Src;
  Effect.FdParts.Add(PartF);

  Shape := TShapeNode.Create;
  Shape.Geometry := IFS;
  Shape.Appearance := App;
  App.SetEffects([Effect]);

  Root := TX3DRootNode.Create;
  Root.AddChildren(Shape);

  FShadowScene := TCastleScene.Create(FOwner);
  FShadowScene.ProcessEvents := True;       { live uniform / coord updates }
  FShadowScene.Pickable := False;
  FShadowScene.Load(Root, True);
  FShadowScene.Exists := FShowShadow and (FShadowMode = bsmCapsules);
  FShadowScene.CastShadows := False;   { never a caster in the engine pass }
  FGroup.Add(FShadowScene);
end;

procedure TBikeInstance.EnsureMapDebugQuad;
var
  Root: TX3DRootNode;
  IFS: TIndexedFaceSetNode;
  Shape: TShapeNode;
  App: TAppearanceNode;
  Mat: TUnlitMaterialNode;
begin
  if FMapDbgScene <> nil then Exit;
  if (FShadowMapLight = nil) or
     (not (FShadowMapLight.FdDefaultShadowMap.Value is TGeneratedShadowMapNode)) then Exit;
  { горизонтальный unlit-квад 2x2 м над байком; глубина карты читается как
    яркость (байк ~середина диапазона, фон = far) }
  IFS := TIndexedFaceSetNode.Create;
  IFS.Coord := TCoordinateNode.Create;
  with TCoordinateNode(IFS.Coord).FdPoint do
  begin
    Items.Add(Vector3(-1, 2.2, -1)); Items.Add(Vector3(1, 2.2, -1));
    Items.Add(Vector3(1, 2.2, 1));   Items.Add(Vector3(-1, 2.2, 1));
  end;
  IFS.Solid := False;
  IFS.FdCoordIndex.Items.Add(0);
  IFS.FdCoordIndex.Items.Add(1);
  IFS.FdCoordIndex.Items.Add(2);
  IFS.FdCoordIndex.Items.Add(3);
  IFS.FdCoordIndex.Items.Add(-1);
  Mat := TUnlitMaterialNode.Create;
  Mat.FdEmissiveTexture.Value := FShadowMapLight.FdDefaultShadowMap.Value;
  App := TAppearanceNode.Create;
  App.Material := Mat;
  Shape := TShapeNode.Create;
  Shape.Geometry := IFS;
  Shape.Appearance := App;
  Root := TX3DRootNode.Create;
  Root.AddChildren(Shape);
  FMapDbgScene := TCastleScene.Create(FOwner);
  FMapDbgScene.ProcessEvents := True;
  FMapDbgScene.Pickable := False;
  FMapDbgScene.CastShadows := False;
  FMapDbgScene.Load(Root, True);
  FGroup.Add(FMapDbgScene);
  StartupLog('[bsmCGE-ДИАГ] map debug quad построен');
end;

procedure TBikeInstance.RebuildShadowStatic;
const
  TUBE_R = 0.020;        { generic frame-tube capsule radius, m — the blur
                           makes exact tube radii indistinguishable }
  MARGIN = 1.0;          { quad border beyond the capsule extents, m — room
                           for the tallest penumbra (head at ~1.1 m -> ~0.6 m) }
var
  CenterX, WRm, TireRm, MinX, MaxX, MinZ, MaxZ, Gy: Single;
  W: TWheelComponent;
  N: Integer;
  Ax: TVector3;

  function O(const P: TVector3): TVector3;   { same X-centering the geometry uses }
  begin Result := Vector3(P.X - CenterX, P.Y, P.Z); end;

  procedure AddCap(const A, B: TVector3; RA, RB: Single);
  begin
    if N > High(FShadowStatA) then Exit;
    FShadowStatA[N] := A; FShadowStatB[N] := B;
    FShadowStatRA[N] := RA; FShadowStatRB[N] := RB;
    MinX := Min(MinX, Min(A.X, B.X)); MaxX := Max(MaxX, Max(A.X, B.X));
    MinZ := Min(MinZ, Min(A.Z, B.Z)); MaxZ := Max(MaxZ, Max(A.Z, B.Z));
    Inc(N);
  end;

  procedure AddBonePair(const N1, N2: string; RA, RB: Single);
  begin
    if FBikeSkeleton.HasBone(N1) and FBikeSkeleton.HasBone(N2) then
      AddCap(O(FBikeSkeleton[N1]), O(FBikeSkeleton[N2]), RA, RB);
  end;

  { Full vertical ring of Seg chord capsules on the tire circle, in the
    wheel's XY plane (constant Z at the axle). One vertex sits exactly at the
    ground contact (bottom, -90°) so the contact shadow is pin-sharp (h=0).
    The upper rim is high (2R above ground) and projects far along a low sun;
    lower-rim points are near the ground and barely project. Together their
    projected outline is the wheel's ground ellipse. }
  procedure AddWheelRing(const Axle: TVector3; R, TireR: Single; Seg: Integer);
  var
    K: Integer;
    A0, A1: Single;
  begin
    for K := 0 to Seg - 1 do
    begin
      A0 := -Pi / 2 + 2 * Pi * K / Seg;
      A1 := -Pi / 2 + 2 * Pi * (K + 1) / Seg;
      AddCap(
        Vector3(Axle.X + R * Cos(A0), Axle.Y + R * Sin(A0), Axle.Z),
        Vector3(Axle.X + R * Cos(A1), Axle.Y + R * Sin(A1), Axle.Z),
        TireR, TireR);
    end;
  end;

begin
  if (FBikeSkeleton = nil) or not (FBikeSkeleton.HasBone('rear_axle') and
     FBikeSkeleton.HasBone('front_axle')) then Exit;

  EnsureShadowQuad;

  CenterX := BikeCenterX(FBikeSkeleton);   { обе оси есть — проверено выше }

  { wheel radius / tire width from the wheel component (mm -> m) }
  WRm := WHEEL_RADIUS_FALLBACK_M; TireRm := 0.020;
  W := TWheelComponent(Component(TWheelComponent));
  if (W <> nil) and (W.WheelRadius > 1.0) then
  begin
    WRm := W.WheelRadius * 0.001;
    TireRm := Max(0.018, W.TireWidth * 0.001 * 1.4);   { TireWidth = half-width mm }
  end;

  Gy := Min(O(FBikeSkeleton['rear_axle']).Y, O(FBikeSkeleton['front_axle']).Y) - WRm;
  FShadowGroundY := Gy;

  { рабочая ёмкость статических капсул (2x24 wheels + chainring 12 +
    ~16 frame/cockpit); после заполнения массивы режутся до N. Тот же
    потолок, что у шейдера, — SendShadowCapsules не переполнится. }
  SetLength(FShadowStatA, SHADOW_MAX_CAPS);
  SetLength(FShadowStatB, SHADOW_MAX_CAPS);
  SetLength(FShadowStatRA, SHADOW_MAX_CAPS);
  SetLength(FShadowStatRB, SHADOW_MAX_CAPS);
  MinX := 1e9; MaxX := -1e9; MinZ := 1e9; MaxZ := -1e9;
  N := 0;

  { Each wheel is a VERTICAL RING of chord capsules on the tire circle, at
    their TRUE heights (contact point at the ground, rim top at 2R). This is
    what makes the wheel silhouette respond to the sun: a vertical sun
    projects all chords onto the same line (top-down view — physically
    correct for a vertical disc lit from above), while a low sun slides the
    high chords sideways and the shadow opens into the elliptic wheel
    OUTLINE — sharp at the contact patch, soft at the top. A flat
    ground-level segment (the previous representation) has no height, so it
    could never skew and the wheel shadow stayed a top-down line under any
    sun. 8 chords per wheel: the polygon sagitta (~2.6 cm at 700c) vanishes
    under the capsule radius + penumbra. }
  Ax := O(FBikeSkeleton['rear_axle']);
  AddWheelRing(Ax, WRm, TireRm, 24);
  StartupLog(Format('[shadow] rear wheel capsule axle=(%.4f,%.4f,%.4f)', [Ax.X, Ax.Y, Ax.Z]));
  Ax := O(FBikeSkeleton['front_axle']);
  AddWheelRing(Ax, WRm, TireRm, 24);
  StartupLog(Format('[shadow] front wheel capsule axle=(%.4f,%.4f,%.4f)', [Ax.X, Ax.Y, Ax.Z]));

  { frame / fork / cockpit as thick segments between skeleton bones — after
    the height-softening the difference from true tube geometry is invisible }
  AddBonePair('bb',            'seat_tube_top', 0.024, TUBE_R);   { seat tube }
  AddBonePair('bb',            'head_tube_bottom', 0.026, 0.022); { down tube }
  AddBonePair('seat_tube_top', 'head_tube_top', TUBE_R, TUBE_R);  { top tube }
  AddBonePair('bb',            'rear_axle', 0.022, 0.014);        { chainstays }
  AddBonePair('seat_tube_top', 'rear_axle', 0.016, 0.012);        { seatstays }
  { fork: both real legs when the skeleton has them, else the steering axis }
  if FBikeSkeleton.HasBone('fork_crown_l') and FBikeSkeleton.HasBone('fork_crown_r') then
  begin
    AddBonePair('fork_crown_l', 'front_axle', 0.016, 0.012);
    AddBonePair('fork_crown_r', 'front_axle', 0.016, 0.012);
    AddBonePair('head_tube_bottom', 'fork_crown_l', 0.018, 0.016); { crown }
  end
  else
    AddBonePair('head_tube_top', 'front_axle', TUBE_R, 0.014);
  AddBonePair('seat_tube_top', 'seatpost_top', 0.016, 0.016);     { seatpost }
  { saddle: ~26 cm along X around the seatpost top, nose forward }
  if FBikeSkeleton.HasBone('seatpost_top') then
  begin
    Ax := O(FBikeSkeleton['seatpost_top']);
    { saddle at half size: ~13 cm long, thinner }
    AddCap(Vector3(Ax.X - 0.075, Ax.Y + 0.01, Ax.Z),
           Vector3(Ax.X + 0.055, Ax.Y + 0.01, Ax.Z), 0.028, 0.014);
  end;
  if FBikeSkeleton.HasBone('stem_base') then
    AddBonePair('stem_base',   'stem_end', 0.016, 0.016)          { stem }
  else
    AddBonePair('head_tube_top', 'stem_end', 0.016, 0.016);
  AddBonePair('bar_left',      'bar_right', 0.014, 0.014);        { handlebar }
  AddBonePair('bar_left',      'hood_base_l', 0.014, 0.016);      { drop-bar hoods }
  AddBonePair('bar_right',     'hood_base_r', 0.014, 0.016);
  { chainring: a small vertical disc at the BB (drive side), ~10 cm radius —
    reads as the round chainring in the shadow. Reuses the wheel-ring helper. }
  if FBikeSkeleton.HasBone('bb') then
  begin
    Ax := O(FBikeSkeleton['bb']);
    AddWheelRing(Vector3(Ax.X, Ax.Y, Ax.Z + 0.04), 0.10, 0.008, 12);
  end;

  SetLength(FShadowStatA, N);
  SetLength(FShadowStatB, N);
  SetLength(FShadowStatRA, N);
  SetLength(FShadowStatRB, N);

  { запоминаем сырые extents + Y земли: UpdateShadowQuadSize пересчитывает
    квады при смене направления солнца без перебейка капсул }
  FShadowCapsMinX := MinX;  FShadowCapsMaxX := MaxX;
  FShadowCapsMinZ := MinZ;  FShadowCapsMaxZ := MaxZ;
  FShadowCapsGy := Gy;
  UpdateShadowQuadSize;

  FShadowGroundU.Send(Gy);
  FShadowStrengthU.Send(FShadowStrength);
  FShadowSunU.Send(FShadowSunDir);
  FShadowSoftU.Send(FShadowSoftness);
  ApplyShadowMode;   { quad / engine light existence per the current mode }

  { push static capsules now; the per-frame dynamic set is appended by
    UpdateShadowDynamic (rider loaded) or stays empty (bare bike) }
  SendShadowCapsules([], [], [], [], 0);
end;

procedure TBikeInstance.UpdateShadowQuadSize;
const
  MARGIN = 1.0;   { quad border beyond the capsule extents — as in RebuildShadowStatic }
var
  MinX, MaxX, MinZ, MaxZ, Gy, ShiftX, ShiftZ: Single;
begin
  if FShadowScene = nil then Exit;   { ни одного бейка ещё не было }

  MinX := FShadowCapsMinX;  MaxX := FShadowCapsMaxX;
  MinZ := FShadowCapsMinZ;  MaxZ := FShadowCapsMaxZ;
  Gy := FShadowCapsGy;

  { a tilted sun slides the shadow of tall parts along +sun.xz; give the quad
    room. MAXH ~ head height above the ground (bike + rider). In WORLD-sun
    mode the local skew direction rotates as the bike turns, so extend
    SYMMETRICALLY by the tilt magnitude (rotation-invariant); in local mode
    only the downwind side needs room. }
  if FShadowSunUseWorld then
  begin
    ShiftX := Sqrt(Sqr(FShadowSunWorld.X) + Sqr(FShadowSunWorld.Z))
              / Max(Abs(FShadowSunWorld.Y), 0.1) * 1.6;
    MinX := MinX - ShiftX; MaxX := MaxX + ShiftX;
    MinZ := MinZ - ShiftX; MaxZ := MaxZ + ShiftX;
  end
  else
  begin
    ShiftX := FShadowSunDir.X / Max(Abs(FShadowSunDir.Y), 0.1) * 1.6;
    ShiftZ := FShadowSunDir.Z / Max(Abs(FShadowSunDir.Y), 0.1) * 1.6;
    if ShiftX > 0 then MaxX := MaxX + ShiftX else MinX := MinX + ShiftX;
    if ShiftZ > 0 then MaxZ := MaxZ + ShiftZ else MinZ := MinZ + ShiftZ;
  end;

  { size + drop the quad; a fresh build may have moved the ground plane.
    Cache the extents so the quad can be re-tilted later when the game feeds a
    new terrain normal, then build the (possibly tilted) quad. }
  FShadowQMinX := MinX - MARGIN;  FShadowQMaxX := MaxX + MARGIN;
  FShadowQMinZ := MinZ - MARGIN;  FShadowQMaxZ := MaxZ + MARGIN;
  FShadowQGy := Gy;
  RebuildShadowQuadTilt;

  { the bsmCGE catcher quad (if built) shares the same ground extents so the
    engine shadow has somewhere to land across the bike's whole footprint.
    DIAGNOSTIC: lifted 5 cm so the magenta test quad can't hide inside the
    ground mesh / z-fight into invisibility. Drop back to Gy once confirmed. }
  if FShadowCatchCoord <> nil then
  begin
    FShadowCatchCoord.FdPoint.Send([
      Vector3(MinX - MARGIN, Gy + 0.05, MinZ - MARGIN),
      Vector3(MaxX + MARGIN, Gy + 0.05, MinZ - MARGIN),
      Vector3(MaxX + MARGIN, Gy + 0.05, MaxZ + MARGIN),
      Vector3(MinX - MARGIN, Gy + 0.05, MaxZ + MARGIN)]);
    StartupLog(Format('[bsmCGE] catcher resized on build: X[%.2f..%.2f] Z[%.2f..%.2f] Y=%.3f',
      [MinX - MARGIN, MaxX + MARGIN, MinZ - MARGIN, MaxZ + MARGIN, Gy + 0.05]));
  end;
end;

procedure TBikeInstance.SendShadowCapsules(const DynA, DynB: array of TVector3;
  const DynRA, DynRB: array of Single; DynCount: Integer);
var
  I, StatN, Total: Integer;
begin
  if FShadowScene = nil then Exit;
  StatN := Length(FShadowStatA);
  Total := StatN + DynCount;
  if Total > SHADOW_MAX_CAPS then Total := SHADOW_MAX_CAPS;

  { IMPORTANT: uniforms of an Effect are re-uploaded to the GPU only when the
    field fires its exposed input EVENT — i.e. via Send(), exactly like the
    frame-tube shader does. Writing Items[..] + Changed updates the X3D value
    but the shader program keeps rendering the values captured at link time
    (that bug froze the shadow). The buffers stay padded to SHADOW_MAX_CAPS
    so the sent array always matches the GLSL declaration; the fragment loop
    reads only the first capN entries. }
  if Length(FShadowSendA) <> SHADOW_MAX_CAPS then
  begin
    { свежие массивы нулевые; выполняется один раз (0 -> SHADOW_MAX_CAPS) }
    SetLength(FShadowSendA, SHADOW_MAX_CAPS);
    SetLength(FShadowSendB, SHADOW_MAX_CAPS);
    SetLength(FShadowSendRA, SHADOW_MAX_CAPS);
    SetLength(FShadowSendRB, SHADOW_MAX_CAPS);
  end;
  for I := 0 to Total - 1 do
    if I < StatN then
    begin
      FShadowSendA[I] := FShadowStatA[I];
      FShadowSendB[I] := FShadowStatB[I];
      FShadowSendRA[I] := FShadowStatRA[I];
      FShadowSendRB[I] := FShadowStatRB[I];
    end
    else
    begin
      FShadowSendA[I] := DynA[I - StatN];
      FShadowSendB[I] := DynB[I - StatN];
      FShadowSendRA[I] := DynRA[I - StatN];
      FShadowSendRB[I] := DynRB[I - StatN];
    end;
  FShadowCapA.Send(FShadowSendA);
  FShadowCapB.Send(FShadowSendB);
  FShadowCapRA.Send(FShadowSendRA);
  FShadowCapRB.Send(FShadowSendRB);
  FShadowCapN.Send(Total);
end;

function TBikeInstance.RiderClothingSkin(const Name:string;out M:TMatrix4):Boolean;
var J,C,R:Integer;
begin
  Result:=False;M:=TMatrix4.Identity;
  if(FTripoRider=nil)or(FTripoRider.Rig=nil)then Exit;
  if FGpuAnim and(FGpuSkin<>nil)and FGpuSkin.Ready then
    Exit(FGpuSkin.SpineSkin(Name,M));
  J:=FTripoRider.Rig.JointIndexByName(Name);if J<0 then Exit;
  for C:=0 to 3 do for R:=0 to 3 do M.Data[C,R]:=FTripoRider.Rig.SkinMatrix[J][C*4+R];
  Result:=True;
end;

function TBikeInstance.RiderJointPos(const Nm: string; out P: TVector3): Boolean;
begin
  if not FTripoShowRider or (FTripoRider=nil) then begin P:=TVector3.Zero;Exit(False) end;
  if FGpuAnim and (FGpuSkin<>nil) and FGpuSkin.Ready then
    Result:=FGpuSkin.ShadowJoint(Nm,P)
  else Result:=FTripoRider.PosedJointParent(Nm,P);
end;

function TBikeInstance.BikeAnchor(const Nm:string;out P:TVector3):Boolean;
begin
  P:=TVector3.Zero;
  Result:=(FBikeSkeleton<>nil)and FBikeSkeleton.TryGetBone(Nm,P);
  { Skeleton positions are already in scene metres. Only centre them on
    the wheelbase, exactly as the rendered bicycle geometry. }
  if Result then P.X:=P.X-BikeCenterX(FBikeSkeleton);
end;

function TBikeInstance.FitSaddleToRider(KneeFlexDeg:Single;
  AdjustSetback:Boolean):Boolean;
const
  Sides:array[0..1]of string=('R_','L_');
  LowPostMm=10.0;
var
  Seat:TSeatComponent;Frame:TFrameComponent;Saved:TBikePlaybackState;
  OriginalSaddle,Axis,Hip,Knee,Foot,U,V,BB:TVector3;
  Pass,I,J,SaddleIndex:Integer;
  Lo,Hi,Mid,MinFlex,Flex,Lengths,NewPost:Single;

  function RailOffset(PostMm:Single):Single;
  var Height:Single;
  begin
    Result:=Seat.SaddleOffset;
    if not AdjustSetback then Exit;
    Height:=OriginalSaddle.Y+Axis.Y*(PostMm-Seat.SeatpostExtension)*FBikeSkeleton.MM-BB.Y;
    { Keep the pelvis setback of the reference 74-degree road fit when a
      catalogue frame has a different seat angle. The rails have finite travel. }
    Result:=EnsureRange(Height*(Cot(DegToRad(Frame.SeatTubeAngle))-
      Cot(DegToRad(74)))/FBikeSkeleton.MM,-50,50);
  end;
begin
  Result:=False;
  if (FTripoRider=nil) or not FTripoRider.Loaded or (FBikeSkeleton=nil) then Exit;
  Seat:=TSeatComponent(Component(TSeatComponent));
  Frame:=TFrameComponent(Component(TFrameComponent));
  if (Seat=nil) or (Frame=nil) or
     not FBikeSkeleton.TryGetBone('saddle_contact',OriginalSaddle) or
     not FBikeSkeleton.TryGetBone('bb',BB) then Exit;
  Axis:=Vector3(-Cos(DegToRad(Frame.SeatTubeAngle)),Sin(DegToRad(Frame.SeatTubeAngle)),0);
  SaddleIndex:=FBikeSkeleton.FindIndex('saddle_contact');
  Saved:=CaptureReplay;
  Lo:=LowPostMm;Hi:=400;
  KneeFlexDeg:=EnsureRange(KneeFlexDeg,20,45);
  try
    ApplyRiderPose(BuiltinRiderPose(0),0);
    FBodyDynamicsEnabled:=False;
    FPhaseSynced:=True;FPhaseStarted:=True;
    FPedalRate:=85/60;FMotionCadence:=85;
    FBreathPhase:=0;FBreathLoad:=0.7;
    FRiderEffort:=0.7;FRiderEffortTarget:=0.7;
    FSteerAngleDeg:=0;FPedalSteerDeg:=0;FPedalLeanDeg:=0;
    FTripoPrevElapsed:=FAnimElapsed;
    { The ankle also changes position as the leg extends: foot orientation
      is part of the contact solve. Therefore measure the real IK at each
      candidate, instead of treating the ankle as a fixed point. Ten steps
      resolve the seatpost to 0.4 mm; geometry is rebuilt only at the end. }
    for Pass:=0 to 9 do
    begin
      Mid:=(Lo+Hi)*0.5;
      FBikeSkeleton.FBones[SaddleIndex].Pos:=OriginalSaddle+
        Axis*((Mid-Seat.SeatpostExtension)*FBikeSkeleton.MM);
      FBikeSkeleton.FBones[SaddleIndex].Pos.X:=FBikeSkeleton.FBones[SaddleIndex].Pos.X+
        (RailOffset(Mid)-Seat.SaddleOffset)*FBikeSkeleton.MM;
      MinFlex:=180;
      for I:=0 to 31 do
      begin
        FPhase:=I/32;
        UpdateTripoRider(FAnimElapsed);
        for J:=0 to 1 do
        begin
          if not (RiderJointPos(Sides[J]+'Thigh',Hip) and
            RiderJointPos(Sides[J]+'Calf',Knee) and
            RiderJointPos(Sides[J]+'Foot',Foot)) then Exit;
          U:=Hip-Knee;V:=Foot-Knee;Lengths:=U.Length*V.Length;
          if Lengths<0.01 then Exit;
          Flex:=RadToDeg(ArcCos(EnsureRange(-TVector3.DotProduct(U,V)/Lengths,-1.0,1.0)));
          MinFlex:=Min(MinFlex,Flex);
        end;
      end;
      if MinFlex>KneeFlexDeg then Lo:=Mid else Hi:=Mid;
    end;
  finally
    FBikeSkeleton.FBones[SaddleIndex].Pos:=OriginalSaddle;
    RestoreReplay(Saved);
  end;
  NewPost:=Lo;
  if IsNan(NewPost) or IsInfinite(NewPost) or (NewPost<10) or (NewPost>400) then Exit;
  Seat.SaddleOffset:=RailOffset(NewPost);
  Seat.SeatpostExtension:=NewPost;
  RebuildGroup(BSG_FRAME,True);
  Result:=True;
end;

function TBikeInstance.FitCockpitToRider(out FitScore:Single):Boolean;
const Sides:array[0..1]of string=('R_','L_');
var
  Fork:TForkComponent;Frame:TFrameComponent;Saved:TBikePlaybackState;
  SavedBones:array of TBikeBone;
  H,S,E,W,U,V,Shift,PostAxis,StemAxis:TVector3;
  I,J,Side,StemMm,SpacerMm,MaxStem:Integer;
  OldStem,OldSpacers,BestStem,BestSpacers,Score,Flex,Shoulder,Lengths:Single;
  P:TRiderPose;

  procedure MoveGrips;
  var K:Integer;Name:string;
  begin
    Shift:=PostAxis*((SpacerMm-OldSpacers)*0.001)+
      StemAxis*((StemMm-OldStem)*0.001);
    for K:=0 to High(SavedBones) do begin
      Name:=SavedBones[K].Name;
      if (Name='stem_end') or (Pos('place_',Name)=1) or
         (Pos('hood_',Name)=1) or (Pos('bar_',Name)=1) then
        FBikeSkeleton.FBones[K].Pos:=SavedBones[K].Pos+Shift;
    end;
  end;
begin
  Result:=False;FitScore:=Infinity;
  if not HasTripoRider or (FBikeSkeleton=nil) then Exit;
  Fork:=TForkComponent(Component(TForkComponent));
  Frame:=TFrameComponent(Component(TFrameComponent));
  if (Fork=nil)or(Frame=nil)then Exit;
  OldStem:=Fork.StemLength;OldSpacers:=Fork.HeadsetSpacer;
  BestStem:=OldStem;BestSpacers:=OldSpacers;
  PostAxis:=Vector3(-Cos(DegToRad(Frame.HeadTubeAngle)),Sin(DegToRad(Frame.HeadTubeAngle)),0);
  StemAxis:=Vector3(Cos(DegToRad(Fork.StemAngle)),Sin(DegToRad(Fork.StemAngle)),0);
  SavedBones:=Copy(FBikeSkeleton.FBones);Saved:=CaptureReplay;
  MaxStem:=140;if BarType=btFlat then MaxStem:=110;
  try
    P:=BuiltinRiderPose(0);ApplyRiderPose(P,0);
    FBodyDynamicsEnabled:=False;FPhaseSynced:=True;FPhaseStarted:=True;
    FPedalRate:=85/60;FMotionCadence:=85;FPhase:=0.125;
    FBreathPhase:=0;FBreathLoad:=0.7;
    FRiderEffort:=0.7;FRiderEffortTarget:=0.7;
    FSteerAngleDeg:=0;FPedalSteerDeg:=0;FPedalLeanDeg:=0;
    FTripoPrevElapsed:=FAnimElapsed;
    { Small discrete hardware search, using the same IK as the visible rider.
      No meshes, GLBs, LODs or body parameters are rebuilt in this loop. }
    for I:=0 to 10 do begin
      SpacerMm:=I*5;
      for J:=0 to (MaxStem-60)div 5 do begin
        StemMm:=60+J*5;MoveGrips;UpdateTripoRider(FAnimElapsed);
        Score:=0;
        if FUtrLastError<>'' then Exit;
        for Side:=0 to 1 do begin
          if not (RiderJointPos('Pelvis',H)and
            RiderJointPos(Sides[Side]+'Upperarm',S)and
            RiderJointPos(Sides[Side]+'Forearm',E)and
            RiderJointPos(Sides[Side]+'Hand',W))then Exit;
          U:=S-E;V:=W-E;Lengths:=U.Length*V.Length;
          if Lengths<0.001 then Exit;
          Flex:=RadToDeg(ArcCos(EnsureRange(-TVector3.DotProduct(U,V)/Lengths,-1.0,1.0)));
          U:=H-S;V:=E-S;Lengths:=U.Length*V.Length;
          if Lengths<0.001 then Exit;
          Shoulder:=RadToDeg(ArcCos(EnsureRange(TVector3.DotProduct(U,V)/Lengths,-1.0,1.0)));
          Score:=Score+Sqr((Flex-40)/15)+0.35*Sqr((Shoulder-80)/25);
        end;
        Score:=Score+0.08*Sqr((StemMm-90)/40)+0.08*Sqr((SpacerMm-25)/25);
        if Score<FitScore then begin
          FitScore:=Score;BestStem:=StemMm;BestSpacers:=SpacerMm;
        end;
      end;
    end;
  finally
    FBikeSkeleton.FBones:=SavedBones;
    RestoreReplay(Saved);
  end;
  if IsInfinite(FitScore)or IsNan(FitScore)then Exit;
  Fork.StemLength:=BestStem;Fork.HeadsetSpacer:=BestSpacers;
  RebuildGroup(BSG_FRAME,True);Result:=True;
end;

function TBikeInstance.WheelSupportPoint(Front:Boolean;const GroundNormal:TVector3;
  out P:TVector3):Boolean;
var A,Axis,Normal,Radial:TVector3;W:TWheelComponent;ScaleM:Single;Nm:string;
begin
  Result:=False;P:=TVector3.Zero;
  if (FBikeSkeleton=nil)or(FGroup=nil)or(GroundNormal.Length<0.001)then Exit;
  W:=TWheelComponent(Component(TWheelComponent));if W=nil then Exit;
  if Front then Nm:='front_axle' else Nm:='rear_axle';
  if not FBikeSkeleton.TryGetBone(Nm,A)then Exit;
  { Skeleton anchors, like rendered geometry, are already in metres. }
  A.X:=A.X-BikeCenterX(FBikeSkeleton);Axis:=Vector3(0,0,1);
  if Front then begin Axis:=SteerPoint(A+Axis)-SteerPoint(A);A:=SteerPoint(A) end;
  Axis:=FGroup.LocalToWorldDirection(Axis).Normalize;
  Normal:=GroundNormal.Normalize;
  Radial:=Normal-Axis*TVector3.DotProduct(Normal,Axis);
  if Radial.Length<0.001 then Exit;
  ScaleM:=FGroup.LocalToWorldDirection(Vector3(1,0,0)).Length*0.001;
  P:=FGroup.LocalToWorld(A)-Radial.Normalize*((W.WheelRadius-W.TireWidth)*ScaleM)
    -Normal*(W.TireWidth*ScaleM);
  Result:=True;
end;

procedure TBikeInstance.UpdateShadowDynamic(const OBB, PedalR, PedalL: TVector3);
var
  DynA, DynB: array[0..High(SHADOW_RIDER_BONES) + 5] of TVector3;
  DynRA, DynRB: array[0..High(SHADOW_RIDER_BONES) + 5] of Single;
  N, K: Integer;
  PA, PB: TVector3;

  procedure AddDyn(const A, B: TVector3; RA, RB: Single);
  begin
    DynA[N] := A; DynB[N] := B; DynRA[N] := RA; DynRB[N] := RB; Inc(N);
  end;

begin
  if FShadowScene = nil then Exit;   { no build yet -> nothing to shadow onto }
  if FShadowMode <> bsmCapsules then Exit;   { engine / none: no capsule uniforms }
  N := 0;

  { crank arms (tapering to the pedal spindle) + pedal platforms, following
    the crank angle already computed by the caller }
  AddDyn(OBB, PedalR, 0.026, 0.016);
  AddDyn(OBB, PedalL, 0.026, 0.016);
  AddDyn(PedalR + Vector3(-0.05, 0, 0), PedalR + Vector3(0.05, 0, 0), 0.032, 0.032);
  AddDyn(PedalL + Vector3(-0.05, 0, 0), PedalL + Vector3(0.05, 0, 0), 0.032, 0.032);

  { ── Rider capsules, thicknesses adapted to THIS model's size. ──
    The radii in SHADOW_RIDER_BONES are authored for a reference build whose
    torso (Pelvis->NeckTwist01) is ~0.52 m in the bike frame. A larger or
    smaller Tripo model has a proportionally longer/shorter torso, so we
    measure it and scale every rider radius by that ratio — the shadow
    figure then keeps sane proportions for any model without per-model
    tuning. Этап 5: замер по BIND-позициям (BindJointParent) — работает в
    обоих путях (posed-риг под GpuAnim на CPU не крутится); капсулы
    считаются аналитически и в GPU-, и в CPU-ветке. }
  if FTripoShowRider and HasTripoRider then
  begin
    if FShadowRiderScale <= 0 then
    begin
      if FTripoRider.BindJointParent('Pelvis', PA)
         and FTripoRider.BindJointParent('NeckTwist01', PB) then
        FShadowRiderScale := EnsureRange((PB - PA).Length / 0.52, 0.5, 2.5)
      else
        FShadowRiderScale := 1.0;   { rig lacks the landmarks -> reference size }
      StartupLog(Format('[shadow] rider capsule scale = %.3f (bind-measured)',
        [FShadowRiderScale]));
    end;

    for K := 0 to High(SHADOW_RIDER_BONES) do
      if RiderJointPos(SHADOW_RIDER_BONES[K].A, PA) then
      begin
        if SHADOW_RIDER_BONES[K].B = '' then PB := PA
        else if not RiderJointPos(SHADOW_RIDER_BONES[K].B, PB) then
          PB := PA;
        { The 'Head' joint sits low, near the neck base, so a sphere there
          reads as sitting between the shoulders. Lift the head sphere up
          along the neck->head axis by ~1.2x the neck length so it clears
          the shoulder line. Scales with the model (neck vector length). }
        if SHADOW_RIDER_BONES[K].A = 'Head' then
          if RiderJointPos('NeckTwist01', PB) then
          begin
            PA := PA + (PA - PB) * 1.2;   { push up along the neck axis }
            PB := PA;                      { keep it a sphere }
          end;
        AddDyn(PA, PB,
          SHADOW_RIDER_BONES[K].RA * FShadowRiderScale,
          SHADOW_RIDER_BONES[K].RB * FShadowRiderScale);
      end;
  end;

  SendShadowCapsules(DynA, DynB, DynRA, DynRB, N);
end;

procedure TBikeInstance.LogPedalAnimation(Lines: TStrings; Steps: Integer);
var
  CenterX, QFH, QZ, S, MM: Single;
  Phase, Ang: Single;
  FootPitchR, FootPitchL: Single;
  DistSB, DistSP: Single;
  BB, CrankR, CrankL, PedalR, PedalL, AnkleR, AnkleL: TVector3;
  GripR, GripL: TVector3;            { hand targets, for the actual-pose diagnostic }
  FootBR, FootBL, CleatR, CleatL: TVector3;  { posed foot bone + cleat sphere per frame }
  HasFBR, HasFBL, HasClR, HasClL: Boolean;
  BClipR, BClipL, AOfs: TVector3;
  BakeR, BakeL: TVector3;            { marker offsets baked to the foot bone at load }
  MarkR, MarkL, HasBakeR, HasBakeL: Boolean;
  SaddleW, PedBot: TVector3;         { bike-reach metrics for rider-fit comparison }
  CrkLen: Single;
  k: Integer;

  function Cx(const P: TVector3): TVector3;   { same X-centering the geometry uses }
  begin Result := Vector3(P.X - CenterX, P.Y, P.Z); end;
  function V(const P: TVector3): string;
  begin Result := Format('(%8.4f %8.4f %8.4f)', [P.X, P.Y, P.Z]); end;
  function YN(B: Boolean): string;
  begin if B then Result := 'YES' else Result := 'no'; end;

begin
  Lines.Clear;
  if (FTripoRider = nil) or (not FTripoRider.Loaded) then
  begin Lines.Add('No Tripo rider loaded — load a rider first.'); Exit; end;
  if (FBikeSkeleton = nil) or (not FBikeSkeleton.HasBone('bb')) then
  begin Lines.Add('No bike skeleton (bb bone missing) — build a bike first.'); Exit; end;
  if Steps < 1 then Steps := 24;

  { constants — identical setup to UpdateTripoRider }
  MM := FBikeSkeleton.MM;
  CenterX := BikeCenterX(FBikeSkeleton);
  BB := FBikeSkeleton['bb'];
  RestCrankArms(FBikeSkeleton, BB, CrankR, CrankL);

  QFH := GetRiderStanceHalf;
  QZ  := QFH * MM;
  S   := FTripoFitScale * FTripoRiderScale;

  { cleat offsets — constant over the revolution (computed once, same as the pose) }
  MarkR := FTripoRider.ContactOffsetParent('R_Foot', 'BoatClipseR', BClipR);
  if not MarkR then begin AOfs := FTripoAnkleOffset; BClipR := Vector3(AOfs.X, AOfs.Y,  AOfs.Z); end;
  MarkL := FTripoRider.ContactOffsetParent('L_Foot', 'BoatClipseL', BClipL);
  if not MarkL then begin AOfs := FTripoAnkleOffset; BClipL := Vector3(AOfs.X, AOfs.Y, -AOfs.Z); end;
  HasBakeR := FTripoRider.ContactLocalOffset(0, BakeR);   { baked at load: cleat in foot-bone frame }
  HasBakeL := FTripoRider.ContactLocalOffset(1, BakeL);

  Lines.Add('=========================================================');
  Lines.Add(' PEDAL-TRAIN ANIMATION LOG  -  one full crank revolution');
  Lines.Add('=========================================================');
  Lines.Add(Format('steps           : %d   (every %.1f deg of crank)', [Steps, 360.0/Steps]));
  Lines.Add(Format('PedalDir        : %.0f    AnkleFlexMax: %.1f deg', [FTripoPedalDir, FTripoAnkleFlex]));
  Lines.Add(Format('StanceHalf(foot): %.1f mm  ->  QZ = %.4f m', [QFH, QZ]));
  Lines.Add(Format('FitScale S      : %.4f', [S]));
  Lines.Add('');
  Lines.Add('CONSTANTS (unchanged across the revolution):');
  Lines.Add('  BB (world)    = ' + V(Cx(BB)));
  Lines.Add(Format('  rest crank R  = %s  len=%.4f m', [V(CrankR), Sqrt(CrankR.X*CrankR.X + CrankR.Y*CrankR.Y)]));
  Lines.Add(Format('  rest crank L  = %s  len=%.4f m', [V(CrankL), Sqrt(CrankL.X*CrankL.X + CrankL.Y*CrankL.Y)]));
  Lines.Add(Format('  baked cleat-in-foot-bone R = %s  [BoatClipseR: %s]  (rig units, load-time)', [V(BakeR), YN(HasBakeR)]));
  Lines.Add(Format('  baked cleat-in-foot-bone L = %s  [BoatClipseL: %s]', [V(BakeL), YN(HasBakeL)]));
  Lines.Add(Format('  rest world cleat-off R     = %s   (reference only, old rest-pose offset)', [V(BClipR)]));
  Lines.Add(Format('  rest world cleat-off L     = %s', [V(BClipL)]));
  Lines.Add('');

  { ── bike reach metrics: compare saddle->pedal with the rig LEG seat->cleat ── }
  BikeReachMetrics(FBikeSkeleton, QFH, SaddleW, BB, PedBot, QZ, CrkLen, DistSB, DistSP);
  Lines.Add('BIKE REACH (world metres; compare saddle->pedal with rig LEG seat->cleat):');
  Lines.Add(Format('  saddle (saddle_contact) = %s', [V(SaddleW)]));
  Lines.Add(Format('  BB / crank centre     = %s', [V(BB)]));
  Lines.Add(Format('  crank arm length      = %.4f m', [CrkLen]));
  Lines.Add(Format('  saddle -> BB          = %.4f m', [DistSB]));
  Lines.Add(Format('  saddle -> pedal@bottom= %.4f m   (low point, incl. stance Z=%.4f)',
    [DistSP, QZ]));
  Lines.Add(Format('  pedal@bottom (world)  = %s', [V(PedBot)]));
  Lines.Add('');

  Lines.Add('Pedal axles (PedalR/L) ride the crank circle around BB. The foot IK now aims');
  Lines.Add('the CLEAT (baked to the foot bone above) at the raw pedal axle PedalR, folding');
  Lines.Add('the ankle-flex roll into the solve, so the cleat stays on the axle through the');
  Lines.Add('whole stroke. AnkleR below = the OLD rest-pose ankle target (PedalR + rest off),');
  Lines.Add('shown for reference; it is no longer what the IK aims at. World metres.');
  Lines.Add('');

  Lines.Add('====================== RIGHT ======================');
  Lines.Add('phase crankAng        PedalR axle (x y z)          AnkleR IK (x y z)        FootPit  PedFoot');
  for k := 0 to Steps do
  begin
    Phase := k / Steps;
    Ang := FTripoPedalDir * Phase * 2 * Pi;
    PedalPositions(BB, CenterX, QZ, Ang, CrankR, CrankL, PedalR, PedalL);
    AnkleR := PedalR + BClipR;
    FootPitchR := 0;
    if FTripoAnkleFlex > 0.001 then
      FootPitchR := AnklingFootPitch(CrankR, Ang, FTripoAnkleFlex);
    Lines.Add(Format('%4.2f %7.1f  %s %s %7.1f %7.1f',
      [Phase, RadToDeg(Ang), V(PedalR), V(AnkleR), RadToDeg(FootPitchR), RadToDeg(FootPitchR)]));
  end;
  Lines.Add('');

  Lines.Add('====================== LEFT =======================');
  Lines.Add('phase crankAng        PedalL axle (x y z)          AnkleL IK (x y z)        FootPit  PedFoot');
  for k := 0 to Steps do
  begin
    Phase := k / Steps;
    Ang := FTripoPedalDir * Phase * 2 * Pi;
    PedalPositions(BB, CenterX, QZ, Ang, CrankR, CrankL, PedalR, PedalL);
    AnkleL := PedalL + BClipL;
    FootPitchL := 0;
    if FTripoAnkleFlex > 0.001 then
      FootPitchL := AnklingFootPitch(CrankL, Ang, FTripoAnkleFlex);
    Lines.Add(Format('%4.2f %7.1f  %s %s %7.1f %7.1f',
      [Phase, RadToDeg(Ang), V(PedalL), V(AnkleL), RadToDeg(FootPitchL), RadToDeg(FootPitchL)]));
  end;

  { ===== POSED FOOT BONE (lowest leg joint) + CLEAT SPHERE, per frame ===== }
  Lines.Add('');
  Lines.Add('========= POSED FOOT BONE & CLEAT SPHERE  (one pose per frame) =========');
  Lines.Add('Rider REALLY posed each frame; read back in the bike/parent frame (metres).');
  Lines.Add('footBone   = R_Foot / L_Foot joint origin (the lowest leg bone) in the pose.');
  Lines.Add('cleatSphere= the debug contact sphere (blended skin) = where the cleat marker');
  Lines.Add('             renders on the boot. cleat->pedal = sphere distance to the axle.');
  { grips do not change over the revolution — resolve them once }
  GripR := GripBoneFallback(FBikeSkeleton, 'r', CenterX, BB);
  GripL := GripBoneFallback(FBikeSkeleton, 'l', CenterX, BB);
  Lines.Add('');
  Lines.Add('phase crankAng side  footBone (x y z)           cleatSphere (x y z)        cleat->pedal');
  for k := 0 to Steps do
  begin
    Phase := k / Steps;
    Ang := FTripoPedalDir * Phase * 2 * Pi;
    PedalPositions(BB, CenterX, QZ, Ang, CrankR, CrankL, PedalR, PedalL);
    FootPitchR := 0; FootPitchL := 0;
    if FTripoAnkleFlex > 0.001 then
    begin
      FootPitchR := AnklingFootPitch(CrankR, Ang, FTripoAnkleFlex);
      FootPitchL := AnklingFootPitch(CrankL, Ang, FTripoAnkleFlex);
    end;
    FTripoRider.FootPitchR := FootPitchR;
    FTripoRider.FootPitchL := FootPitchL;
    FTripoRider.UpdatePose(PedalR, PedalL, GripR, GripL);   { real pose for this frame }

    HasFBR := FTripoRider.PosedJointParent('R_Foot', FootBR);
    HasClR := FTripoRider.PosedContactParent(0, CleatR);
    HasFBL := FTripoRider.PosedJointParent('L_Foot', FootBL);
    HasClL := FTripoRider.PosedContactParent(1, CleatL);
    if not HasFBR then FootBR := Vector3(0,0,0);
    if not HasClR then CleatR := PedalR;
    if not HasFBL then FootBL := Vector3(0,0,0);
    if not HasClL then CleatL := PedalL;

    Lines.Add(Format('%4.2f %7.1f  R    %s %s %8.4f',
      [Phase, RadToDeg(Ang), V(FootBR), V(CleatR), (CleatR - PedalR).Length]));
    Lines.Add(Format('%4.2f %7.1f  L    %s %s %8.4f',
      [Phase, RadToDeg(Ang), V(FootBL), V(CleatL), (CleatL - PedalL).Length]));
  end;

  { ===== ACTUAL POSED DIAGNOSTICS — pose the rider for real and read back ===== }
  Lines.Add('');
  Lines.Add('============= ACTUAL POSED CONTACT DIAGNOSTICS =============');
  Lines.Add('The rider is REALLY posed (UpdatePose) with the RAW pedal/grip targets,');
  Lines.Add('then read back in the bike/parent frame. QUAT = where SolveLimb aims the');
  Lines.Add('cleat; SKIN = where the cleat mesh ACTUALLY renders via the GPU skin');
  Lines.Add('matrix. If SKIN misses the target while QUAT lands, the rig carries an');
  Lines.Add('internal scale (see rigScale@joint) that the quaternion solve drops, and');
  Lines.Add('that miss IS the constant float. (Side effect: leaves the rider posed at');
  Lines.Add('the last sample until the next animation frame.)');
  for k := 0 to 3 do
  begin
    Phase := k * 0.25;
    Ang := FTripoPedalDir * Phase * 2 * Pi;
    PedalPositions(BB, CenterX, QZ, Ang, CrankR, CrankL, PedalR, PedalL);
    FootPitchR := 0; FootPitchL := 0;
    if FTripoAnkleFlex > 0.001 then
    begin
      FootPitchR := AnklingFootPitch(CrankR, Ang, FTripoAnkleFlex);
      FootPitchL := AnklingFootPitch(CrankL, Ang, FTripoAnkleFlex);
    end;
    GripR := GripBoneFallback(FBikeSkeleton, 'r', CenterX, BB);
    GripL := GripBoneFallback(FBikeSkeleton, 'l', CenterX, BB);
    FTripoRider.FootPitchR := FootPitchR;
    FTripoRider.FootPitchL := FootPitchL;
    FTripoRider.UpdatePose(PedalR, PedalL, GripR, GripL);
    Lines.Add('');
    Lines.Add(Format('=== phase %.2f  crankAng %.0f deg  footPitch R/L %.1f/%.1f deg ===',
      [Phase, RadToDeg(Ang), RadToDeg(FootPitchR), RadToDeg(FootPitchL)]));
    Lines.Add(Format('    PEDAL angle now = foot sagittal roll R/L %.1f/%.1f deg   (old=ankling footPitch %.1f/%.1f)',
      [RadToDeg(FTripoRider.FootSagittalRoll(0)), RadToDeg(FTripoRider.FootSagittalRoll(1)),
       RadToDeg(FootPitchR), RadToDeg(FootPitchL)]));
    FTripoRider.DiagContactDump(Lines, PedalR, PedalL, GripR, GripL);
  end;
end;

function TBikeInstance.LogBikeReach(Lines: TStrings): Double;
var
  CenterX, QZ, CrkLen, DistSB, DistSP: Single;
  BB, SaddleW, PedBot: TVector3;

  function Cx(const P: TVector3): TVector3;
  begin Result := Vector3(P.X - CenterX, P.Y, P.Z); end;
  function V(const P: TVector3): string;
  begin Result := Format('(%8.4f %8.4f %8.4f)', [P.X, P.Y, P.Z]); end;

begin
  Result := 0;
  if (FBikeSkeleton = nil) or (not FBikeSkeleton.HasBone('bb')) then
  begin Lines.Add('── BIKE REACH ──  no bike skeleton (build a bike first)'); Exit; end;

  CenterX := BikeCenterX(FBikeSkeleton);
  BikeReachMetrics(FBikeSkeleton, GetRiderStanceHalf, SaddleW, BB, PedBot,
    QZ, CrkLen, DistSB, DistSP);

  Lines.Add('── BIKE REACH (world metres) ──');
  Lines.Add(Format('  saddle (saddle_contact) = %s', [V(Cx(SaddleW))]));
  Lines.Add(Format('  BB / crank centre     = %s', [V(Cx(BB))]));
  Lines.Add(Format('  crank arm length      = %.4f m', [CrkLen]));
  Lines.Add(Format('  saddle -> BB          = %.4f m', [DistSB]));
  Lines.Add(Format('  saddle -> pedal@bottom= %.4f m   (low point, incl. stance Z=%.4f)',
    [DistSP, QZ]));
  Lines.Add(Format('  pedal@bottom (world)  = %s', [V(Cx(PedBot))]));
  Result := DistSP;
end;

class function TBikeInstance.LODForDistance(Dist, LOD3Dist, LOD2Dist, LOD1Dist: Single): Integer;
begin
  if Dist < LOD3Dist then Result := 3
  else if Dist < LOD2Dist then Result := 2
  else if Dist < LOD1Dist then Result := 1
  else Result := 0;
end;

class function TBikeInstance.PrepareBuildComps(const APreset: string): TBikeComponentClassArray;
begin
  { Preset name picks the base component list. Bar type is implicit in that
    choice (MTB → flat bar, everything else → drop bar). }
  if SameText(APreset, 'mtb') then
    Result := MTBComponents
  else if SameText(APreset, 'gravel') then
    Result := GravelBikeComponents
  else
    Result := RoadBikeComponents;

  { The cyclist is an authored Tripo-rigged glb driven via
    TBikeInstance.LoadTripoRider, added to the bike Group as a separate
    GPU-skinned scene. No rider component is built here. }
end;

procedure TBikeInstance.AssignComponentStateFrom(ASource: TBikeBuilder);
var I, J: Integer; Obj: TJSONObject;
begin
  if ASource = nil then Exit;
  for I := 0 to ASource.ComponentCount - 1 do
    for J := 0 to High(FComponents) do
      if FComponents[J].ClassType = ASource.Components[I].ClassType then
      begin
        Obj := TJSONObject.Create;
        try
          ASource.Components[I].ParamsToJSON(Obj);
          FComponents[J].ParamsFromJSON(Obj);
        finally
          Obj.Free;
        end;
        Break;
      end;
end;

procedure TBikeInstance.AssignComponentStateFromJSON(AComponents: TJSONObject);
var J: Integer; Obj: TJSONData;
begin
  if AComponents = nil then Exit;
  for J := 0 to High(FComponents) do
  begin
    Obj := AComponents.Find(FComponents[J].ComponentName);
    if (Obj <> nil) and (Obj is TJSONObject) then
      FComponents[J].ParamsFromJSON(TJSONObject(Obj));
  end;
end;

end.
