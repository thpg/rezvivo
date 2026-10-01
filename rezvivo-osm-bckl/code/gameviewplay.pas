unit GameViewPlay;

{ ВНИМАНИЕ: файл собран из снапшота проекта. В нём ещё присутствуют ветки
  дефолтного X3D-террейна (текстуры/road-модель). Изменения относительно
  снапшота:
    • CurrentMapJsonUrl → CurrentFitPath (свойство/поле переименованы);
    • ResolveMapPaths упрощён;
    • ApplyCustomTerrainScene грузит FIT напрямую и запускает стриминг,
      как студийный btnGenerateClick (без map.json).
  Если в твоей локальной версии дефолтный террейн уже удалён — сделай diff
  и перенеси только эти три правки, ветки текстур/road-модели не возвращай. }

interface

uses Classes,fpjson,
  CastleComponentSerialize, CastleUIControls, CastleControls,
  CastleKeysMouse, CastleViewport, CastleScene, CastleVectors, CastleCameras,
  CastleTransform, CastleInputs, CastleThirdPersonNavigation, CastleDebugTransform,
  CastleSceneCore, CastleColors, CastleShapes, X3DNodes,
  CastleQuaternions, CastleApplicationProperties,
  GameWorkoutHud, GameWorkoutGates, GameTrainingFocus,GameTrainingWindow,GameUiNavigation,GameEnemy, GamePhysicalAgent, GameBotAgent, GameWorld, GameLoopbackSession,
  GamePhysicsCommon, GameAgentControllers, GameAgentNetwork, GameMotionTrace,
  TrainerData, GameRideClient, BikeParametric, GameBikeAvatar,
  CastleTimeUtils,
  GameRemoteRiders, GameBLEHud, GameCameraControl, PBRTextureUnit,
  GameCinematicCamera, GameFreeCamera, GameScreenFX, GameSimClock, GameSimReplay, GameSimCameraTrack,
  GameOsmStreaming, FitFile, GpxFile, GamePath,
  Osm3dRoadMaterial, Osm3dStudioSettings,   { LoadFogSettings: общий со студией файл настроек тумана }
  GameRiderPoseControl, VeloSiteAPI,
  FreezeDiagLog, Osm3dRiderShadow, GameZoneWheel, Osm3dDreamWorld, GameDreamWorldScene;

type
  { ── Rider card widget: two-line display for one rider ── }
  TRiderCard = class(TCastleUserInterface)
  public
    Bg: TCastleRectangleControl;
    LblTop: TCastleLabel;     { name + distance on route }
    LblBottom: TCastleLabel;  { speed, power, cadence, hr }
    RouteDist: Single;        { absolute distance on route, for sorting }
    IsSelf: Boolean;
    constructor Create(AOwner: TComponent); override;
    procedure SetData(const AName: string; ARouteDist, ASpeed: Single;
      APower, ACadence, AHR: Integer; ASelf: Boolean);
  end;

  { Кольцо режимов камеры, переключаемое клавишей C:
      pcmCinematic   — авто-режим (трансляционная камера);
      pcmThirdPerson — ручной вид от третьего лица (следование за аватаром);
      pcmFree        — свободная облётная камера (WASD+EQ / стрелки / мышь). }
  TPlayCameraMode = (pcmCinematic, pcmThirdPerson, pcmFree);

  TViewPlay = class(TCastleView)
  published
    LabelFps: TCastleLabel;
    LabelSpeed: TCastleLabel;
    LabelPower: TCastleLabel;
    LabelWork: TCastleLabel;
    LabelWorkTSS: TCastleLabel;
    LabelCorr: TCastleLabel;
    LabelCadence: TCastleLabel;
    LabelHeart: TCastleLabel;
    LabelSlope: TCastleLabel;
    LabelPitch: TCastleLabel;
    LabelInfo: TCastleLabel;
    MainViewport: TCastleViewport;
    ThirdPersonNavigation: TCastleThirdPersonNavigation;
    SceneAvatar, SceneLevel, SceneRoadBarrier: TCastleScene;
    AvatarTransform: TCastleTransform;
    AvatarRigidBody: TCastleRigidBody;
    CheckboxCameraFollows: TCastleCheckbox;
    CheckboxAimAvatar: TCastleCheckbox;
    CheckboxDebugAvatarColliders: TCastleCheckbox;
    CheckboxImmediatelyFixBlockedCamera: TCastleCheckbox;
    SliderAirRotationControl: TCastleFloatSlider;
    SliderAirMovementControl: TCastleFloatSlider;
    SliderPower: TCastleFloatSlider;
    VerticalGroup1: TCastleVerticalGroup;
    ButtonChangeTransformationAuto,
    ButtonChangeTransformationDirect,
    ButtonChangeTransformationVelocity,
    ButtonChangeTransformationForce: TCastleButton;
  private
    Enemies: TEnemyList;

    FOfflineWorld: TGameWorld;
    FOfflineAvatar: TPhysicalAgent;
    FOfflineController: TPlayerAgentController;

    FLoopbackSession: TGameLoopbackSession;

    FActiveAvatarAgent: TPhysicalAgent;
    FActivePlayerController: TPlayerAgentController;

    { LOD-based bike instance for the local avatar }
    FBikeInstance: TBikeInstance;
    { Боты, переведённые на ОБЩИЙ пайплайн TBikeInstance (тот же, что у
      аватара и гостей): экземплярам нужен покадровый AnimateFrame, иначе
      Tripo-райдер остаётся в T-позе и не сидит на седле. Список хранит
      ссылки; сами экземпляры следуют жизненному циклу FBikeInstance
      (сцены owned by FreeAtStop). }
    FShadowAtlas: TRiderShadowAtlas;
    FAtlasWorldShadows: Boolean;
    FShadowTestBikes: TList; { local diagnostic objects, never sent to relay }
    FShadowTestRoots: TCastleTransformList;
    FShadowTestZones: Boolean;
    FBotBikes: TList;
    { Параллельный FBotBikes список агентов ботов (тот же порядок, тот же
      жизненный цикл) — нужен для shadow-LOD: State.ShadowPlaneWanted. }
    FBotAgents: TList;
    { Параллельный FBotBikes список TRiderPoseManager (owned): та же
      авто-смена поз, что у аватара. UpdateBotPoseManagers гоняет только
      ботов ближе 100 м и в зоне видимости камеры. }
    FBotPoseManagers: TList;
    FPoseManager: TRiderPoseManager;   { automatic rider-pose selection from telemetry }

    { Extracted managers }
    FRemoteRiders: TRemoteRidersManager;
    { perf-тумблеры для раздельных MCP-замеров стоимости компонентов
      (perf.set); True по умолчанию — поведение игры не меняется }
    FPerfAnim: Boolean;     { False — пропускать AnimateFrame аватара/ботов/remote }
    FPerfRiders: Boolean;   { False — скрыть Tripo-райдеров (людей, не байки) }
    FPerfTerrain: Boolean;  { False — скрыть землю (streaming map / SceneLevel) }
    FPerfShadows: Boolean;  { False — отключить тени всех райдеров }
    FBLEHud: TBLEHudUpdater;
    FWorkoutHud: TWorkoutHud;
    FFocusPanel:TTrainingFocusPanel;
    FFocusButton:TCastleButton;
    FFocusMode:Boolean;
    FKeyboard:TUiKeyboardNavigation;
    procedure ClickTrainingFocus(Sender:TObject);
    procedure SetTrainingFocus(Value:Boolean);
  private
    FWorkoutGates: TWorkoutGates;
    FAudioSampleTimer: Single;
    FCamera: TCameraController;

    { Cinematic camera system }
    FCinematicCam: TCinematicCamera;
    FScreenFX: TScreenFX;   { post-processing: bloom + filmic tonemap (клавиша B) }
    FNearbyBuf: array[0..15] of TVector3;
    FNearbyBufCount: Integer;

    { Free-fly camera (третий слот в кольце режимов клавиши C).
      WASD+EQ — полёт, стрелки/перетаскивание ЛКМ — поворот, колесо — наезд. }
    FFreeCam: TFreeCameraController;
    FCameraMode: TPlayCameraMode;
    FCameraDragging: Boolean;
    FCameraDragButton: TCastleMouseButton;

    { MCP direct chase camera: fixed rear (or offset) view at given distance.
      Overrides cinematic/thirdperson/free while active — each frame places
      MainViewport.Camera behind the avatar along -forward. }
    FChaseCamActive: Boolean;
    FChaseDist: Single;       { meters behind rider along -forward }
    FChaseHeight: Single;     { meters above rider origin }
    FChaseSide: Single;       { meters lateral (+ = rider's right) }
    FChaseAimHeight: Single;  { look-at height on rider }

    { MCP: stationary lean L/R + bar steer (no FIT play / path needed). }
    FLeanTestActive: Boolean;
    FLeanTestPhase: Single;
    FLeanTestPeriodS: Single;
    FLeanTestLeanAmpDeg: Single;
    FLeanTestSteerAmpDeg: Single;
    FLeanTestLastLean: Single;
    FLeanTestLastSteer: Single;

    { PBR road model }

    { Стриминговая карта Osm3d. Заменяет генеренную землю: когда
      назначена кастомная карта, террейн/дорога не запекаются —
      мир стримится вокруг велосипедиста. nil = дефолтная карта. }
    FOsmStreaming: TGameOsmStreaming;

    { Снап маршрута на дорожную сеть OSM завершается асинхронно.
      Когда готов и велосипедист ещё не уехал — путь один раз
      перестраивается на снапнутый трек. Флаг гасит повторную попытку. }
    FOsmSnapApplied: Boolean;
    { Защёлка: один раз после готовности снапа прикрепить OSM-ширины к
      пути и скормить профиль ширины менеджеру полос. Независима от
      свопа позиций (SNAP_SWAP_ENABLED). }
    FOsmWidthsApplied: Boolean;

    { Холд старта заезда на время подготовки маршрута (прогрев тайлов +
      снап), запущенной в ApplyCustomTerrainScene. Пока True — каждый
      кадр гасим AutoMove (иначе BLE/симуляция/клавиша P тронут райдера
      раньше, чем тайлы впереди смонтируются, и он поедет по пустоте).
      Снимается, когда FOsmStreaming.RoutePrepDone И смонтирована земля
      под стартовой точкой (RouteStartGroundY); на снятии райдер встаёт на
      смонтированную землю (InitializeAtStart), оверлей получает
      NotifyRiderPlaced. Экран ожидания — WarmupOverlay карты, он уже
      во вьюпорте. }
    FOsmPrepHold: Boolean;
    { Троттлинг лог-строк ожидания (раз в ~5 с) + флажок «симуляция
      хотела AutoMove, вернуть после снятия холда». }
    FOsmPrepHoldLogTick: QWord;
    FBuildingPushLogTick: QWord; { BUILDING_OBSTACLE rider push log throttle }
    FOsmPrepResumeAutoMove: Boolean;
    { Timer for missing ground AFTER start scene loading. Assembly/mounting
      does not consume this budget. High(QWord) = error already reported;
      placement remains held until a valid ground sample arrives. }
    FOsmPrepGroundSince: QWord;
    { Одноразовый подъём оверлея прогрева на верх UI на первом кадре
      холда: FX-панель тогглов создаётся в Start ПОЗЖЕ пересадки
      оверлея во вью (RaiseWarmupToFront) и иначе рисуется поверх
      списка этапов. False — поднять ещё раз при первом Update холда. }
    FOsmPrepRaised: Boolean;
    { Одноразовая диагностика ПОСЛЕ снятия холда: ~8 с раз в секунду
      пишем AutoMove (контроллер и State), мощность, скорость, позицию
      и число точек пути. Если райдер «крутит педали на месте» — по этим
      строкам сразу видно, какое звено не пускает (флаг/мощность/путь). }
    FOsmPrepDiagUntil: QWord;
    FOsmPrepDiagTick:  QWord;

    { Road texture cycling }

    { Lane management — shared by all riders }
    FLaneManager: TLaneManager;
    FLocalLaneHandle: TLaneRiderHandle;

    { PBR terrain texture processor }
    FTerrainPBR: TPBRTextureProcessor;

    { Terrain texture cycling }
    FTerrainTextureFolders: TStringList;
    FTerrainTextureIndex: Integer;
    FTerrainProcessors: array of TPBRTextureProcessor;
    FTerrainTexSets: array of TPBRTextureSet;
    FTerrainSizeX, FTerrainSizeZ: Single;

    { Rider list display in VerticalGroup1 }
    FRiderScroll: TCastleScrollView;
    FHasOtherRiders: Boolean;
    FAdminLayoutValid, FAdminLayoutShown: Boolean;
    FAdminLayoutHeight: Single;
    FRiderInner: TCastleVerticalGroup;
    FRiderCards: array of TRiderCard;

    { Frame profiling — rolling average over ~60 frames }
    FProf_WorldUpdate: Double;
    FProf_BLE: Double;
    FProf_Relay: Double;
    FProf_Pose: Double;
    { TEMP-DIAG: разложение секции Pose (T4..T5a) по этапам }
    FProf_PoseCam: Double;      { камера (cinematic/thirdperson clamp) }
    FProf_PoseCull: Double;     { distance culling + rider list (каждые 15/30 кадров) }
    FProf_PoseAnimAv: Double;   { FBikeInstance.AnimateFrame (аватар) }
    FProf_PoseAnimBots: Double; { AnimateBotBikes }
    FProf_PoseMgr: Double;      { FPoseManager.Update }
    FProf_PoseAnimRem: Double;  { FRemoteRiders.AnimateAllRiders }
    FProf_Labels: Double;
    FProf_FrameTotal: Double;
    FFrameLastUpdateMs: Double;
    FProf_Render: Double;
    FProf_AvgCount: Integer;
    FProf_Display: string;
    FProf_LastUpdateEnd: TTimerResult;
    FProf_HasLastUpdate: Boolean;
    FFpsBgRect: TCastleRectangleControl;
    FAdminPanelsHidden: Boolean;

    { Detailed profiling log }
    FProfileLog: TStringList;
    FProfileFrameNum: Integer;
    FProfileLogFile: string;

    { FREEZE-DIAG — heart-beat timer. Logged at most every 500 ms from
      TViewPlay.Update; if these lines stop arriving in trainer.log,
      the main thread is stuck. Session-start anchor lets log timings
      be read as elapsed-since-session-start. }
    FFreezeDiagSessionStart: QWord;
    FFreezeDiagLastHeartBeat: QWord;

    { Bot debug panel (top-left, /log only) — sends commands to relay server }
    FBotPanel: TCastleRectangleControl;
    FBotPanelLabel: TCastleLabel;
    FBotAddBtn: TCastleButton;
    FBotRemoveBtn: TCastleButton;
    { FX toggle row on the bot panel: one small toggle button per screen
      effect (fog / bloom / tonemap / posterize / kuwahara / hatch) }
    FFxBtnFog, FFxBtnBloom, FFxBtnTone: TCastleButton;
    FFxBtnPoster, FFxBtnKuwa, FFxBtnHatch: TCastleButton;
    { FX/perf-оверлей в левом верхнем углу — ВСЕГДА виден (не привязан
      к /log, в отличие от FBotPanel). Ряды: 2 ряда FX-тумблеров +
      ряд perf-тумблеров (земля/райдер/анимация/тень). }
    FFxPanel: TCastleRectangleControl;
    FMenuButton: TCastleButton;
    FFxBtnTerr, FFxBtnRidr, FFxBtnAnim, FFxBtnShad, FFxBtnWorldShad, FFxBtnRoad, FFxBtnOcclusion: TCastleButton;
    FFxBtnTrees, FFxBtnTreeSeason: TCastleButton;
    { Ряд 4: FIT path spheres (red raw / green snapped) on streaming map. }
    FFxBtnPath: TCastleButton;

    { Sim-плеер: показывается в нижнем-левом углу когда активен
      sim-провайдер. Включает кнопки пауза/restart, прогресс-бар и
      текст «MM:SS / MM:SS». Всё пере-обновляется в Update. }
    FSimPanel: TCastleRectangleControl;
    FSimBtnPause, FSimBtnReset, FSimBtnFwd, FSimBtnSlow,
      FSimBtnBack, FSimBtnStep: TCastleButton;
    FSimSeek: TCastleFloatSlider;
    FSimTime, FSimRate, FSimStatus: TCastleLabel;
    FSimSeekUpdating: Boolean;
    FSimHistory: TSimReplayHistory;
    FSimCameraReplaying: Boolean;
    FSimCameraShotSerial: Cardinal;
    FSimCameraViewTime: Double;
    FSimLoopSerial: Cardinal;
    FSimAccountedUntil: Double;

    { Кастомная карта: путь к выбранному FIT (пусто = дефолт) и фактический
      путь к INI-файлу точек дороги (для дефолтного пути). }
    FCurrentFitPath: String;
    FRoomStartApplied:Boolean;
    FRoomCheckAt:QWord;
    FDreamWorld,FNextDreamWorld:TDreamWorld;
    FDreamVisual,FNextDreamVisual:TDreamWorldVisual;
    FDefaultSky,FCoastalSky:TCastleBackground;
    FCoastalSkyActive:Boolean;
    procedure SetCoastalSky(Enabled:Boolean);
    procedure UpdateRideAudio(const Seconds:Single;const Advancing:Boolean);
    procedure ResetRideWorld(const AFitPath:String;AWorld:TDreamWorld;AVisual:TDreamWorldVisual);
    function CurrentSun(out Sun:TVector3):Boolean;
  private
    FRoadPointsFileNameLocal: String;

    procedure ScanTerrainTextureFolders;
    procedure PreloadTerrainTextures;
    procedure ApplyTerrainTextureByIndex(AIndex: Integer);
    procedure ProfileLogLine(const S: string);
    procedure ProfileLogFrameDetail;
    procedure ProfileSaveAndShow;

    procedure ChangePower(Sender: TObject);

    procedure InitializeAtStart;
    procedure PlayShootSound;
    procedure CreateDemoBotOffline;
    procedure ArrangeLocalRidersAtStart;
    procedure SpawnBotOffline(APower: Single);
    procedure OnBotAddClick(Sender: TObject);
    procedure OnBotRemoveClick(Sender: TObject);
    procedure ClickMenu(Sender: TObject);
    procedure ClickFinishWorkoutRide(Sender:TObject);
    procedure BeginActivityRecord;
    procedure RestoreActivityRecord;
    procedure SaveActivityCheckpoint;
    procedure OnFxToggleClick(Sender: TObject);
    procedure UpdateFxButtonColors;
    function AdminPanelsVisible: Boolean;
    procedure UpdateAdminPanels;

    procedure SetupOfflineWorld;
    procedure ActivateOfflineMode;

    { Загрузить путь райдера. В стриминговом (FIT) режиме точки берутся
      напрямую из FIT-маршрута через FOsmStreaming — без промежуточного
      INI. Для нестриминговой (дизайнерской) карты читается дорожный
      файл-ассет. }
    procedure LoadAgentPath(APath: TGamePath);
    procedure ActivateLoopbackDualWorld;
    procedure RestartLoopbackDualWorld;
    procedure UpdateRiderList;
    procedure RiderCountChanged(Sender: TObject);
    procedure UpdateRiderListVisibility;
    { Колёсные пробы активного аватара — по реальным осям FBikeInstance.
      Применяется после загрузки байка и после каждого RecreatePhysics
      (который заново мерит bbox, раздутый теневым rig'ом). }
    procedure ApplyWheelProbeFromBike;

    { Sim player widget. BuildSimPlayer создаётся один раз в Start —
      виджет всегда существует, но прячется когда sim не активен.
      RefreshSimPlayer вызывается в Update раз в кадр (дёшево). }
    procedure BuildSimPlayer;
    procedure RefreshSimPlayer;
    procedure ClickSimPause(Sender: TObject);
    procedure ClickSimReset(Sender: TObject);
    procedure ClickSimFwd(Sender: TObject);
    procedure ClickSimSlow(Sender: TObject);
    procedure ClickSimBack(Sender: TObject);
    procedure ClickSimStep(Sender: TObject);
    procedure ChangeSimSeek(Sender: TObject);
    procedure CaptureSimCheckpoint;
    procedure FinishMotionTrace;
    procedure RestoreSimCheckpoint(var Seconds: Double);
    procedure ClearSimReplay;
    procedure CaptureSimCamera;
    procedure ShowSimCameraFrame(const Frame: TSimCameraFrame);
    function ReplaySimCamera(var CameraDt: Single): Boolean;
    procedure FinishSimCameraReplay;
    function AdvanceSimFrame(RealSeconds: Single): Single;
    procedure ApplyTerrainTexture;

    procedure ResolveMapPaths;
    procedure ApplyCustomTerrainScene;
    { Пробросить общее солнце стриминговой карты (то, что направляет её
      теневые маски) в контактную тень велосипеда. No-op, если стрим
      неактивен, время в FIT отсутствует или солнце ниже горизонта. }
    procedure ApplyWorldSunToBikeShadow(ABike: TBikeInstance);
    procedure ApplyTerrainSlopeToBikeShadow;
    { Per-frame Tripo pose for bots on the shared TBikeInstance pipeline. }
    procedure AnimateBotBikes(const SecondsPassed: Single);
    { Shadow LOD ботов: bsmCGE (свой теневой проход) только ближе 50 м
      от аватара; дальше — bsmNone и без проб теневой плоскости. }
  private
    FGroundShadeTarget: Single;
    FGroundShadeAge: Single;
    FGroundShadePoint: TVector3;
    function GetGroundShadeDiag: String;
  published
    property GroundShadeDiag: String read GetGroundShadeDiag;
  private
    procedure UpdateRiderGroundShade(const Dt: Single);
    procedure UpdateGroundRiderShadow;
    procedure UpdateBotShadowLOD;
    { Авто-позы ботов (как FPoseManager у аватара): только <100 м и видимы. }
    procedure UpdateBotPoseManagers(const SecondsPassed: Single);
    { Создать/наполнить pose-manager для только что добавленного BotBike. }
    procedure AttachBotPoseManager(ABike: TBikeInstance);

    { Подключить провайдер высоты стриминговой карты к физике активного
      велосипедиста. No-op, если стриминговая карта не активна. }
    procedure ApplyStreamingGroundQuery;

    { Подключить провайдер высоты стриминговой карты к физике
      произвольного агента (велосипедист, оффлайн-бот). No-op для
      нестриминговых карт. }
    procedure ApplyGroundQueryToAgent(AAgent: TPhysicalAgent);

    { Один раз перестроить путь велосипедиста на снапнутый трект, когда
      асинхронная привязка к дорожной сети OSM завершится. Вызывается
      каждый кадр из Update; срабатывает только пока велосипедист ещё
      не уехал от старта. No-op для нестриминговых карт. }
    procedure CheckOsmRouteSnap;

    { После готовности снапа: прикрепить OSM-ширины к пути аватара (без
      смены позиций) и передать менеджеру полос профиль ширины. Работает
      и при выключенном свопе позиций (SNAP_SWAP_ENABLED=False). Вызывать
      каждый кадр — отрабатывает один раз (FOsmWidthsApplied). }
    procedure ApplySnapWidthsAndLanes;

    function HasActiveState: Boolean;

    { Кольцо режимов камеры (клавиша C): cinematic → third-person → free → … }
    procedure CycleCameraMode;
    { Согласованно настроить кинематик-камеру, follow-навигацию и свободную
      камеру под текущий FCameraMode. }
    procedure ApplyCameraMode;
    { MCP chase: place MainViewport.Camera behind avatar this frame. }
    procedure UpdateShadowTestRiders(const SecondsPassed: Single);
    function UseSharedRiderShadows: Boolean;
    procedure ApplyChaseCameraFrame;
    procedure ApplyLeanSteerTestFrame(const SecondsPassed: Single);
  public
    constructor Create(AOwner: TComponent); override;
    procedure Start; override;
    procedure OpenMenu;
    procedure BikeFitChanged;
    function RideCadence: Single;
    procedure Stop; override;
    procedure Render; override;
    function RiderShadowInfo: String;
    procedure RenderOverChildren;override;
    function PreviewPress(const Event:TInputPressRelease):Boolean;override;
    procedure SetShadowTestRiders(const Count: Integer; const Zones: Boolean);
    procedure Update(const SecondsPassed: Single; var HandleInput: Boolean); override;
    function Press(const Event: TInputPressRelease): Boolean; override;
    function Release(const Event: TInputPressRelease): Boolean; override;
    function Motion(const Event: TInputMotion): Boolean; override;

    { Путь к FIT выбранного маршрута (системный путь или URI). Пусто =
      дефолтный мир без стриминга. Ставится меню перед сменой Container.View. }
    property CurrentFitPath: String
      read FCurrentFitPath write FCurrentFitPath;

    { ── Доступ для MCP/скриптового управления (GameMcpServer) ──
      Read-only ссылки на внутренние менеджеры; nil вне Start..Stop
      (мир/камера/стриминг создаются на входе в view и освобождаются
      на выходе). }
    property World: TGameWorld read FOfflineWorld;
    property Bike: TBikeInstance read FBikeInstance;
    property MenuButton: TCastleButton read FMenuButton;
    property Osm: TGameOsmStreaming read FOsmStreaming;
    property Camera: TCameraController read FCamera;
    property CinematicCam: TCinematicCamera read FCinematicCam;
    property CameraMode: TPlayCameraMode read FCameraMode;
    property WorkoutGates: TWorkoutGates read FWorkoutGates;
    property TrainingFocusMode: Boolean read FFocusMode write SetTrainingFocus;
    { Existing smoothed HUD timings, exposed to the MCP performance sampler. }
    property FrameUpdateMs: Double read FProf_FrameTotal;
    property FrameLastUpdateMs: Double read FFrameLastUpdateMs;
    property FrameAnimMs: Double read FProf_PoseAnimAv;

    { Установить режим камеры (кольцо клавиши C) с полным применением
      состояния — тот же путь, что CycleCameraMode. }
    procedure SetCameraMode(const AMode: TPlayCameraMode);

    { MCP: прямое управление chase-камерой. Active=True каждый кадр ставит
      камеру: pos = rider - forward*Distance + up*Height + side*Side,
      look-at = rider + (0, AimHeight, 0). Defaults match cinematic cmMoto
      (3.0 / 1.3 / 0 / 0.85).
      Distance≈0 → top-down над центром аватара (Direction down, Up=forward
      так виден поворот руля). Active=False — вернуть ring C. }
    procedure SetChaseCamera(AActive: Boolean;
      ADistance: Single = 3.0; AHeight: Single = 1.3;
      ASide: Single = 0; AAimHeight: Single = 0.85);
    function ChaseCameraActive: Boolean;
    function ChaseCameraDistance: Single;
    function ChaseCameraHeight: Single;

    { MCP: on-spot lean L/R (+ optional bar steer). No sim.play needed.
      PeriodS = full L→R→L cycle. Amplitudes in degrees. }
    procedure SetLeanSteerTest(AActive: Boolean;
      ALeanAmpDeg: Single = 25; ASteerAmpDeg: Single = 30;
      APeriodS: Single = 4);
    function LeanSteerTestActive: Boolean;
    function LeanSteerTestLastLeanDeg: Single;
    function LeanSteerTestLastSteerDeg: Single;

    { Старт/стоп движения райдера (AutoMove активного контроллера) —
      то же, что клавиша P по отдельным направлениям. }
    procedure StartMoving;
    procedure StopMoving;

    { True, когда play-сессия жива (ESC-пауза: view приостановлен под
      меню, стриминг/байк/мир НЕ разобраны). }
    function SessionAlive: Boolean;
    procedure ConnectRideRoom;
    function RoomDiagnostics:TJSONObject;
    function TrafficDiagnosticsSnapshot:TLaneReplayState;

    { Дамп данных притяжения райдера в JSON-файл: путь аватара (мировые
      точки), ширины, центры дороги, origin сессии, число точек снапа,
      высота земли под стартом, позиция/дистанция райдера. Для сравнения
      «первый запуск против повторного». }
    procedure DumpRidePath(const AFileName: String);

    { Смена маршрута БЕЗ пересоздания мира: разобрать только стриминговую
      сессию (теперь быстро — teardown отменяемый), поднять новую по
      AFitPath, путь райдера/бота перечитать и поставить их на старт.
      Зовётся из меню («Ехать») и MCP, когда SessionAlive. }
    procedure ResetRideToFit(const AFitPath: String);
    procedure PrepareDreamWorld(AWorld:TDreamWorld;AVisual:TDreamWorldVisual=nil);
    procedure ResetRideToDream(AWorld:TDreamWorld;AVisual:TDreamWorldVisual);
    property DreamWorld:TDreamWorld read FDreamWorld;
    property DreamVisual:TDreamWorldVisual read FDreamVisual;
    property CoastalSkyActive:Boolean read FCoastalSkyActive;

    { ── perf-тумблеры для раздельных MCP-замеров (perf.set/perf.state) ── }
    procedure SetPerfAnim(AOn: Boolean);      { гейт AnimateFrame всех байков }
    procedure SetPerfRiders(AOn: Boolean);    { видимость Tripo-райдеров }
    procedure SetPerfTerrain(AOn: Boolean);   { видимость земли/карты }
    property PerfAnim: Boolean read FPerfAnim;
    property PerfRiders: Boolean read FPerfRiders;
    property PerfTerrain: Boolean read FPerfTerrain;
    property PerfShadows: Boolean read FPerfShadows;
    procedure SetPerfShadows(AOn: Boolean);
    procedure ApplyShadowSettings;
    procedure SetOcclusionCulling(AOn: Boolean; Persist: Boolean = True);
    property AtlasWorldShadows: Boolean read FAtlasWorldShadows;
    procedure SetAtlasWorldShadows(AOn: Boolean);
    { True, когда прогрев streaming-карты завершён (или карты нет). }
    function RoutePrepDone: Boolean;
    property SimHistory: TSimReplayHistory read FSimHistory;
    property SimCameraReplaying: Boolean read FSimCameraReplaying;
    property SimCameraViewTime: Double read FSimCameraViewTime;
  end;

var
  ViewPlay: TViewPlay;

{ Загрузить terrain.x3d в ATargetScene с тем же reset Translation/
  Rotation и DistanceCulling, как делает TViewPlay при старте кастомной
  карты. ATargetScene должна быть существующим TCastleScene.

  Возвращает True если файл загружен успешно. Используется и игрой
  (через ApplyCustomTerrainScene), и редактором карты (для top-view
  превью), чтобы загрузка делалась ровно одинаково. }
function LoadTerrainSceneFromX3D(const ATerrainX3DUrl: String;
  ATargetScene: TCastleScene): Boolean;

{ Управление режимом FPS извне (MCP app.fps_mode): 'vsync' | 'max' | 'low'.
  Тот же путь, что клавиша V (CycleGameFpsMode) — LimitFPS + swap interval. }
procedure SetGameFpsModeStr(const AMode: string);
function GameFpsModeStr: string;
procedure SetGameGraphicsBenchmarkActive(Value: Boolean);
function CreateGameFpsControl(AOwner:TComponent):TCastleUserInterface;

implementation


uses UiTranslations, GameRiderTraffic,GameRideRooms,GameAccountChange,
  SysUtils, Math, jsonparser, CastleSoundEngine, CastleBoxes, CastleURIUtils, GameAudio, Osm3dSoundscape, {$IFDEF MSWINDOWS} Windows, ShellApi, MMSystem, {$ENDIF}
  GameActivityAccounting, GameMenuTheme, GameViewMenu, GameDeviceService, BikeJSON, BikeParametric_Animation, GameSensorLog, DebugLog, RideUploadQueue, GameUserData, GameWorkoutPlayer, GameRideHistory, GameRideRecovery, GameDailyTraining,GameRideCommands,
  Osm3dProfiler, GameMcpServer, AppSettings, GameGraphicsOptions, GameCoastalSky, Osm3dVegetationBudget, Osm3dWind, Osm3dCompositeShader, RiderHair;

const
  MaxPower = 2500.0;
  MinPower = 0.0;
  PowerStep = 10.0;
  FixedTimeStep = 1.0 / 60.0;
  RoadPointsFileName = 'castle-data:/terrain_road.ini';
  EnableRoadBarriers = False;  { set True to show curb barriers along road edges }
  BikeJsonFileName = 'castle-data:/bike_road.json';
  BikeJsonFileName2 = 'castle-data:/bike_road2.json';

  { Relay URL берётся из VeloSite.RelayUrl (rezvivo.com, запасной rezvivo.ru). }

{ ── Режимы FPS по клавише V (как V в Osm3dStudio) ─────────────────────
  V temporarily cycles saved settings → uncapped → 30 → saved settings.
  MCP can also force vsync. wglSwapIntervalEXT требует текущий
  GL-контекст, поэтому применение откладывается в Render невидимого
  контрола-апплаера; ApplicationProperties.LimitFPS ставится сразу. }
type
  TFpsLimitMode = (flmVsyncOn, flmVsyncOffMax, flmVsyncOffLow, flmConfigured);

  TFpsSwapApplier = class(TCastleUserInterface)
  private
    procedure GraphicsChanged(Sender: TObject; Option: TGraphicsOption);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Render; override;
  end;

  {$IFDEF MSWINDOWS}
  TWglSwapIntervalProc = function(Interval: LongInt): LongBool; stdcall;
  {$ENDIF}

var
  GFpsMode:         TFpsLimitMode = flmConfigured;
  GFpsSimFrameHold: Boolean = False;
  GFpsGraphicsBenchmark: Boolean = False;
  GFpsSwapPending:  Boolean = False;
  GFpsDesiredSwap:  LongInt = 1;
  {$IFDEF MSWINDOWS}
  GWglSwapInterval: TWglSwapIntervalProc = nil;
  GWglLoaded:       Boolean = False;
  GFpsTimerPeriodActive: Boolean = False;
  {$ENDIF}

{$IFDEF MSWINDOWS}
function WglGetProcAddress(ProcName: PChar): Pointer; stdcall;
  external 'opengl32.dll' name 'wglGetProcAddress';
{$ENDIF}

procedure ApplyGameFpsMode;
var Limit: Integer;
begin
  case GFpsMode of
    flmVsyncOn:     begin ApplicationProperties.LimitFPS := 0;  GFpsDesiredSwap := 1; end;
    flmVsyncOffMax: begin ApplicationProperties.LimitFPS := 0;  GFpsDesiredSwap := 0; end;
    flmVsyncOffLow: begin ApplicationProperties.LimitFPS := 30; GFpsDesiredSwap := 0; end;
    flmConfigured: begin
      Limit := Settings.GetGraphicsOption(Ord(goFrameLimit));
      ApplicationProperties.LimitFPS := Max(0, Limit);
      GFpsDesiredSwap := Ord(Limit < 0);
    end;
  end;
  if GFpsGraphicsBenchmark then begin
    ApplicationProperties.LimitFPS:=0; GFpsDesiredSwap:=0;
    SetVegetationFrameLimit(0,False);
  end else if GFpsSimFrameHold then begin
    ApplicationProperties.LimitFPS:=1; GFpsDesiredSwap:=0;
    SetVegetationFrameLimit(0,False);
  end else SetVegetationFrameLimit(ApplicationProperties.LimitFPS,GFpsDesiredSwap<>0);
  {$IFDEF MSWINDOWS}
  // CGE subtracts rendering time before Sleep. The default Windows timer
  // quantum can still stretch 33 ms frames to 47 ms (about 21 FPS).
  // Request 1 ms precision only while capped, with one matching release.
  if ApplicationProperties.LimitFPS > 0 then
  begin
    if not GFpsTimerPeriodActive then
      GFpsTimerPeriodActive:=timeBeginPeriod(1)=TIMERR_NOERROR;
  end else if GFpsTimerPeriodActive then
  begin
    timeEndPeriod(1);
    GFpsTimerPeriodActive:=False;
  end;
  {$ENDIF}
  GFpsSwapPending := True;
end;

procedure CycleGameFpsMode;
begin
  case GFpsMode of
    flmVsyncOn:     GFpsMode := flmVsyncOffMax;
    flmVsyncOffMax: GFpsMode := flmVsyncOffLow;
    flmVsyncOffLow: GFpsMode := flmConfigured;
    flmConfigured: GFpsMode := flmVsyncOffMax;
  end;
  ApplyGameFpsMode;
  Logger.Info('[FPS] V: temporary mode=' + GameFpsModeStr);
end;

procedure SetGameFpsModeStr(const AMode: string);
begin
  if AMode = 'max' then GFpsMode := flmVsyncOffMax
  else if AMode = 'low' then GFpsMode := flmVsyncOffLow
  else if AMode = 'settings' then GFpsMode := flmConfigured
  else GFpsMode := flmVsyncOn;
  ApplyGameFpsMode;
  Logger.Info('[FPS] mode=' + GameFpsModeStr + ' (MCP)');
end;

function GameFpsModeStr: string;
var Limit: Integer;
begin
  case GFpsMode of
    flmVsyncOffMax: Result := 'max';
    flmVsyncOffLow: Result := 'low';
    flmConfigured: begin
      Limit := Settings.GetGraphicsOption(Ord(goFrameLimit));
      case Limit of
        -1: Result := 'vsync';
        0: Result := 'max';
        30: Result := 'low';
      else Result := IntToStr(Limit);
      end;
    end;
  else
    Result := 'vsync';
  end;
end;

constructor TFpsSwapApplier.Create(AOwner: TComponent);
begin
  inherited;
  Settings.OnGraphicsChanged := @GraphicsChanged;
  ApplyGameFpsMode;
end;

destructor TFpsSwapApplier.Destroy;
begin
  Settings.OnGraphicsChanged := nil;
  inherited;
end;

procedure TFpsSwapApplier.GraphicsChanged(Sender: TObject; Option: TGraphicsOption);
begin
  if Option = goFrameLimit then
  begin
    GFpsMode := flmConfigured;
    ApplyGameFpsMode;
  end;
  if (Option in [goShadowSize, goShadowFilter, goShadowDistance]) and
     (ViewPlay <> nil) and ViewPlay.HasActiveState then
    ViewPlay.ApplyShadowSettings;
end;

procedure TFpsSwapApplier.Render;
begin
  inherited;
  { Контекст GL здесь текущий — можно звать wglSwapIntervalEXT. }
  if GFpsSwapPending then
  begin
    GFpsSwapPending := False;
    {$IFDEF MSWINDOWS}
    if not GWglLoaded then
    begin
      GWglSwapInterval := TWglSwapIntervalProc(
        WglGetProcAddress('wglSwapIntervalEXT'));
      GWglLoaded := True;
    end;
    if Assigned(GWglSwapInterval) then
      GWglSwapInterval(GFpsDesiredSwap);
    {$ENDIF}
  end;
end;

function CreateGameFpsControl(AOwner:TComponent):TCastleUserInterface;
begin
  { Window-owned, rendered in menus as well as rides. }
  Result:=TFpsSwapApplier.Create(AOwner);
end;

{ CLI: --uncapped (-uncapped, /uncapped) — стартовать в режиме без
  vsync/лимита (замеры максимального FPS). }
function CliFlag(const AName: string): Boolean;
var
  I: Integer;
  S: String;
begin
  Result := False;
  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    if (Length(S) > 0) and (S[1] in ['-', '/']) then
    begin
      while (Length(S) > 0) and (S[1] in ['-', '/']) do Delete(S, 1, 1);
      if SameText(S, AName) then Exit(True);
    end;
  end;
end;

function CliUncapped: Boolean;
begin
  Result := CliFlag('uncapped');
end;

{ ДИАГ: --shadowlift=NN (метры) — подъём теневых квадов над землёй.
  Проверка «захоронения» квадов под визуальным мешем террейна.
  --mapdebug — квад с содержимым теневой карты над байком. }
procedure ParseShadowLiftCli;
var
  I: Integer;
begin
  for I := 1 to ParamCount do
    if Copy(ParamStr(I), 1, 13) = '--shadowlift=' then
    begin
      BikeShadowQuadLift := StrToFloatDef(
        StringReplace(Copy(ParamStr(I), 14, MaxInt), '.',
          DefaultFormatSettings.DecimalSeparator, [rfReplaceAll]), 0.003);
      Logger.Info(Format('[DIAG] --shadowlift: квады теней подняты на %.3f м',
        [BikeShadowQuadLift]));
    end;
  if CliFlag('mapdebug') then
  begin
    BikeShadowMapDebugQuad := True;
    Logger.Info('[DIAG] --mapdebug: квад с содержимым теневой карты над байком');
  end;
end;

{ Диагностические разделители кадра (FPS-бисекция):
  --noshadow — байк без движковой тени (bsmNone, без volume-прохода);
  --nolabels — не обновлять HUD-лейблы каждый кадр;
  --nofx     — выключить ScreenFX (bloom/tonemap). }
var
  GCliNoLabels: Boolean = False;



{ ═══════════════════════════════ TRiderCard ═══════════════════════════════ }

constructor TRiderCard.Create(AOwner: TComponent);
begin
  inherited;
  Width := 260;
  Height := 44;
  AutoSizeToChildren := False;

  Bg := TCastleRectangleControl.Create(Self);
  Bg.FullSize := True;
  Bg.Color := Vector4(0.15, 0.15, 0.2, 0.85);
  InsertFront(Bg);

  LblTop := TCastleLabel.Create(Self);
  LblTop.FontSize := 15;
  LblTop.Color := Vector4(1, 1, 1, 1);
  LblTop.Anchor(vpTop, -2);
  LblTop.Anchor(hpLeft, 6);
  InsertFront(LblTop);

  LblBottom := TCastleLabel.Create(Self);
  LblBottom.FontSize := 13;
  LblBottom.Color := Vector4(0.7, 0.8, 0.9, 1);
  LblBottom.Anchor(vpTop, -22);
  LblBottom.Anchor(hpLeft, 6);
  InsertFront(LblBottom);

  RouteDist := 0;
  IsSelf := False;
end;

procedure TRiderCard.SetData(const AName: string; ARouteDist, ASpeed: Single;
  APower, ACadence, AHR: Integer; ASelf: Boolean);
var DistStr: string;
begin
  IsSelf := ASelf;
  RouteDist := ARouteDist;

  if ASelf then
    DistStr := ''
  else if Abs(ARouteDist) < 1000 then
  begin
    if ARouteDist >= 0 then
      DistStr := Format('+%.0f m', [ARouteDist])
    else
      DistStr := Format('%.0f m', [ARouteDist]);
  end
  else begin
    if ARouteDist >= 0 then
      DistStr := Format(UiText('+%.2f km'), [ARouteDist / 1000])
    else
      DistStr := Format(UiText('%.2f km'), [ARouteDist / 1000]);
  end;

  if ASelf then
  begin
    LblTop.Caption := AName + UiText('  (you)');
    LblTop.Color := Vector4(0.3, 1.0, 0.3, 1);
    Bg.Color := Vector4(0.1, 0.25, 0.1, 0.9);
  end else begin
    LblTop.Caption := AName + '   ' + DistStr;
    LblTop.Color := Vector4(1, 1, 1, 1);
    Bg.Color := Vector4(0.15, 0.15, 0.2, 0.85);
  end;

  LblBottom.Caption := Format(UiText('%.1f km/h   %dW   %drpm   %dbpm'), [
    ASpeed * 3.6, APower, ACadence, AHR]);
end;

{ Apply physics params from the live bike instance to agent's TPhysicsState.
  (Раньше тот же JSON парсился заново через LoadBikeFromJSON ради пяти полей
  TAnimationComponent — лишний полный разбор и набор компонентов на каждый
  холодный старт. Те же параметры уже сидят в компонентах загруженного
  TBikeInstance; nil/отсутствие компонента = дефолты, как при старом
  фолбэке по исключению.) }
procedure ApplyBikePhysicsToAgent(ABike: TBikeInstance; AAgent: TPhysicalAgent;UseLocalRider:Boolean=False);
var
  Anim: TAnimationComponent;
  Mass, Cd, Area, Crr: Single;
begin
  if not Assigned(AAgent) then Exit;
  if not Assigned(AAgent.State) then Exit;
  try
    if ABike <> nil then
      Anim := ABike.Component(TAnimationComponent) as TAnimationComponent
    else
      Anim := nil;

    if (Anim <> nil) and (Anim.RiderWeight > 1.0) then
      Mass := Anim.RiderWeight
    else
      Mass := DefaultMass;
    if UseLocalRider and(EffectiveRiderProfile.WeightKg>0)then Mass:=EffectiveRiderProfile.WeightKg;
    if (Anim <> nil) and (Anim.BikeWeight > 0.1) then
      Mass := Mass + Anim.BikeWeight;

    if (Anim <> nil) and (Anim.DragCoefficient > 0.01) then
      Cd := Anim.DragCoefficient
    else
      Cd := DefaultDragCoefficient;

    if (Anim <> nil) and (Anim.FrontalArea > 0.01) then
      Area := Anim.FrontalArea
    else
      Area := DefaultFrontalArea;

    if (Anim <> nil) and (Anim.RollingResistance > 0.0001) then
      Crr := Anim.RollingResistance
    else
      Crr := DefaultRollingResistance;

    AAgent.State.AvatarMass := Mass;
    AAgent.State.DragCoefficient := Cd;
    AAgent.State.FrontalArea := Area;
    AAgent.State.RollingResistance := Crr;

    Logger.Info('[Physics] ' + Format(
      'Applied to "%s": mass=%.1fkg Cd=%.2f A=%.2fm² Crr=%.4f CdA=%.3f',
      [AAgent.Name, Mass, Cd, Area, Crr, Cd * Area]));
  except
    on E: Exception do
      Logger.Info('[Physics] ' + 'Failed to apply bike params to "' +
        AAgent.Name + '": ' + E.Message);
  end;
end;

{ Kinematic bicycle: tan(δ) ≈ L · κ. Sign: positive curvature (left yaw)
  → negative SteerAngleDeg (front wheel toward −Z / rider's left), matching
  lean (CurrentTurnAngle) visual direction. At near-zero curvature falls
  back to a small lean-proportional angle so slow turns still show bar input. }
procedure ApplySteerFromPhysics(ABike: TBikeInstance; AAgent: TPhysicalAgent);
const
  MaxSteerDeg = 40.0;
  LeanToSteerAtLowSpeed = 0.35;   { δ ≈ 0.35 · lean when path κ is tiny }
var
  WB, Steer, V, G: Single;
  S: TPhysicsState;
begin
  if (ABike = nil) or (AAgent = nil) or (AAgent.State = nil) then Exit;
  S := AAgent.State;
  WB := ABike.AxleHalfSpanM * 2.0;
  if WB < 0.3 then WB := DefaultWheelbase;
  if Abs(S.CurrentCurvature) > 1e-5 then
    Steer := -RadToDeg(ArcTan(WB * S.CurrentCurvature))
  else
  begin
    { Low-speed / straight: couple bars lightly to lean so they don't stay
      glued straight while the bike is banked. }
    V := S.CurrentSpeed;
    if V < 0.5 then V := 0.5;
    G := 9.81;
    if Abs(S.CurrentTurnAngle) > 0.05 then
      Steer := -RadToDeg(ArcTan(
        (WB * G * Tan(DegToRad(S.CurrentTurnAngle))) / Sqr(V)))
    else
      Steer := 0;
    { Soft blend toward lean-proportional when the kinematic estimate is
      large at very low speed (unstable division). }
    if V < 2.0 then
      Steer := Steer * (V / 2.0) +
        (-S.CurrentTurnAngle * LeanToSteerAtLowSpeed) * (1.0 - V / 2.0);
  end;
  if Steer > MaxSteerDeg then Steer := MaxSteerDeg
  else if Steer < -MaxSteerDeg then Steer := -MaxSteerDeg;
  ABike.SteerAngleDeg := Steer;
end;

constructor TViewPlay.Create(AOwner: TComponent);
begin
  inherited;
  FAtlasWorldShadows := True;
  DesignUrl := 'castle-data:/gameviewplay.castle-user-interface';
end;

procedure TViewPlay.LoadAgentPath(APath: TGamePath);
var Widths:array of Single;I:Integer;
begin
  if APath = nil then Exit;
  if FDreamWorld<>nil then begin
    SetLength(Widths,Length(FDreamWorld.Points));
    for I:=0 to High(Widths)do Widths[I]:=FDreamWorld.Width;
    APath.SetLevelScene(nil);APath.LoadFromMemory(FDreamWorld.Points,Widths);Exit;
  end;
  { Стриминговый (FIT) режим: точки пути берём напрямую из FIT-маршрута
    через стриминговую обёртку — без промежуточного road-INI. Для
    нестриминговой карты путь читается из дорожного файла-ассета. }
  if Assigned(FOsmStreaming) and FOsmStreaming.Active then
  begin
    { Точки из LoadAvatarPath — УЖЕ мировые (проекция сессии = проекция
      тайлов). Отвязываем путь от сцены уровня: иначе TGamePath прогонит
      мировые точки через SceneLevel.LocalToWorld (наследие road-INI) и
      любой ненулевой трансформ сцены из дизайна уведёт путь и старт
      райдера в сторону от коридора тайлов. CopyTo переносит nil дальше
      (оффлайн-бот, удалённые райдеры получают ту же отвязку). }
    APath.SetLevelScene(nil);
    FOsmStreaming.LoadAvatarPath(APath, FOsmStreaming.SnapReady);
  end
  else if FCurrentFitPath <> '' then
    { Выбран FIT, но стриминг не поднялся (StartFromFit не удался /
      сессия умерла). Прежний тихий фолбэк на дефолтный road-INI сажал
      райдера на путь дефолтной карты ПОСРЕДИ ПУСТОТЫ (террейн-то уже
      очищен под стриминг) и маскировал реальную ошибку. Теперь путь
      оставляем пустым (PointCount=0 → InitializeAtStart/движение не
      стартуют) и громко пишем в лог. }
    Logger.Info('[ViewPlay] ОШИБКА: выбран FIT (' + FCurrentFitPath
      + '), но стриминг неактивен — путь велосипедиста НЕ загружен '
      + '(фолбэк на road-INI отключён, он маскировал ошибку)')
  else
    APath.LoadRoadPoints(FRoadPointsFileNameLocal);
end;

procedure TViewPlay.SetupOfflineWorld;
begin
  Logger.Info('[ViewPlay] ' + '>>> SetupOfflineWorld START');
  FOfflineController := nil;
  FreeAndNil(FOfflineWorld);

  FOfflineWorld := TGameWorld.Create;
  FOfflineWorld.Name := 'OfflineWorld';
  FOfflineWorld.SetOfflineMode;

  FOfflineController := TPlayerAgentController.Create;

  FOfflineAvatar := TPhysicalAgent.Create(FreeAtStop);
  FOfflineAvatar.Name := 'OfflineAvatar';
  FOfflineAvatar.SetupActor(
    AvatarTransform,
    SceneAvatar,
    AvatarRigidBody,
    MainViewport,
    ThirdPersonNavigation,
    SceneLevel
  );
  FOfflineAvatar.SetController(FOfflineController);
  LoadAgentPath(FOfflineAvatar.Path);
  FOfflineAvatar.RecreatePhysics(pmKinematicCurrent);
  FOfflineAvatar.State.WheelContactAtOrigin := True;   { байк стоит на колёсах в Y=0 своего кадра }
  ApplyBikePhysicsToAgent(FBikeInstance, FOfflineAvatar,True);
  FOfflineAvatar.Initialize;
  FOfflineAvatar.CreateDebugSpheres;
  FOfflineAvatar.NetworkAuthority := naLocalOnly;

  FOfflineWorld.Avatar := FOfflineAvatar;
  FOfflineWorld.AddAgent(FOfflineAvatar);
  FOfflineWorld.RegisterAgentInNetwork(FOfflineAvatar);

  if FOfflineAvatar.Path.PointCount >= 2 then
  begin
    FOfflineAvatar.InitializeAtStart;
    Logger.Info('[Path] ' + 'Loaded ' + IntToStr(FOfflineAvatar.Path.PointCount) + ' points.');
  end;

  Logger.Info('[ViewPlay] ' + '  SetupOfflineWorld: about to call CreateDemoBotOffline');
  CreateDemoBotOffline;
  Logger.Info('[ViewPlay] ' + '<<< SetupOfflineWorld END');
end;

procedure TViewPlay.ApplyGroundQueryToAgent(AAgent: TPhysicalAgent);
begin
  { Стриминговая карта Osm3d: тайлы без коллизий — физике любого
    райдера (велосипедист, оффлайн-бот) нужен прямой провайдер высоты
    вместо raycast-а. No-op для нестриминговых карт. }
  if not Assigned(AAgent) then Exit;
  if not Assigned(AAgent.State) then Exit;
  AAgent.State.GroundQuery := nil;
  AAgent.State.PositionConstraint := nil;
  AAgent.State.SlopeQuery := nil;
  if FDreamWorld<>nil then begin
    AAgent.State.GroundQuery:=@FDreamWorld.GroundNearYAt;
    AAgent.State.SlopeQuery:=@FDreamWorld.GroundNearYAt;Exit;
  end;
  if not Assigned(FOsmStreaming) then Exit;
  if not FOsmStreaming.Active then Exit;

  if AAgent = FActiveAvatarAgent then
    AAgent.State.PositionConstraint := {$ifdef FPC}@{$endif} FOsmStreaming.BuildingPushOutXZ;
  AAgent.State.GroundQuery :=
    {$ifdef FPC}@{$endif} FOsmStreaming.GroundNearYAt;
  { Уклон для ускорений/FTMS — с поправкой FIT-слоя (мосты/настил/
    нивелированный профиль); колёса остаются на видимом меше. }
  AAgent.State.SlopeQuery :=
    {$ifdef FPC}@{$endif} FOsmStreaming.GroundNearYCorrAt;
end;

procedure TViewPlay.ApplyStreamingGroundQuery;
begin
  ApplyGroundQueryToAgent(FActiveAvatarAgent);
  if Assigned(FCinematicCam) then begin
    FCinematicCam.GroundQuery := nil;
    if FDreamWorld<>nil then FCinematicCam.GroundQuery:=@FDreamWorld.GroundNearYAt;
  end;
  { Ground height for cinematic camera (same provider as rider physics).
    BuildingResolve is intentionally NOT wired here: TCinematicCamera has
    only GroundQuery; XZ building push for cam must be designed separately
    so it does not thrash look-at yaw. }
  if Assigned(FCinematicCam) and Assigned(FOsmStreaming)
     and FOsmStreaming.Active then
    FCinematicCam.GroundQuery :=
      {$ifdef FPC}@{$endif} FOsmStreaming.GroundNearYAt;
  if Assigned(FOsmStreaming) and FOsmStreaming.Active then
    Logger.Info('[ViewPlay] ' + 'StreamingMap: провайдер высоты подключён '
      + 'к физике велосипедиста (+ cinematic GroundQuery)');
end;

procedure TViewPlay.CheckOsmRouteSnap;
begin
  { ApplySnapWidthsAndLanes publishes the prepared riding path once, before
    the start hold is released. No independent mid-ride raw/snap swap. }
  if Assigned(FOsmStreaming) and FOsmStreaming.SnapReady then
    FOsmSnapApplied:=True;
end;

procedure TViewPlay.ApplySnapWidthsAndLanes;
var
  Path: TGamePath;
  N, I: Integer;
  WD, WW: array of Single;
  Pts: array of TVector3;
begin
  if FOsmWidthsApplied then Exit;
  if not Assigned(FOsmStreaming) then Exit;
  if not FOsmStreaming.Active then Exit;
  if not FOsmStreaming.SnapReady then Exit;
  if not Assigned(FActiveAvatarAgent) then Exit;
  if not HasActiveState then Exit;

  { Publish the worker-prepared route, including building detours.
    Both legacy purposes use the same safe riding geometry. }
  if PathRoadPriorityPullEnabled then
  begin
    FOsmStreaming.ApplySnappedWidths(FActiveAvatarAgent.Path, aspBridge);
    if Assigned(FOfflineAvatar) and (FOfflineAvatar.Path <> FActiveAvatarAgent.Path) then
      FOsmStreaming.ApplySnappedWidths(FOfflineAvatar.Path, aspBridge);
    Logger.Info('[ViewPlay] ApplySnappedWidths purpose=bridge (road-priority pull ON)');
  end
  else
  begin
    FOsmStreaming.ApplySnappedWidths(FActiveAvatarAgent.Path, aspCamera);
    if Assigned(FOfflineAvatar) and (FOfflineAvatar.Path <> FActiveAvatarAgent.Path) then
      FOsmStreaming.ApplySnappedWidths(FOfflineAvatar.Path, aspCamera);
  end;

  { 2. Профиль ширины для менеджера полос: ось дистанции — кумулятивная
       по мировым точкам пути (та же, что LoopPos у менеджера), значение —
       ширина дороги под точкой. Менеджер будет масштабировать разброс
       полос по реальной ширине. }
  Path := FActiveAvatarAgent.Path;
  { Every participant follows the same prepared centerline, widths and turns.
    Bots created during warmup initially had only the raw FIT coordinates. }
  if FBotAgents <> nil then
    for I := 0 to FBotAgents.Count - 1 do
      Path.CopyTo(TPhysicalAgent(FBotAgents[I]).Path);
  N := Path.PointCount;
  if (N >= 2) and Assigned(FLaneManager) then
  begin
    SetLength(Pts, N);
    for I := 0 to N - 1 do Pts[I] := Path.GetPathPointWorld(I);
    SetLength(WD, N);
    SetLength(WW, N);
    WD[0] := 0.0;
    WW[0] := Path.PointWidth(0);
    for I := 1 to N - 1 do
    begin
      WD[I] := WD[I - 1] + (Pts[I] - Pts[I - 1]).Length;
      WW[I] := Path.PointWidth(I);
    end;
    FLaneManager.SetWidthProfile(WD, WW);
    FLaneManager.SetPathLength(WD[N-1] + (Pts[0] - Pts[N-1]).Length);
    Logger.Info('[ViewPlay] ' + Format(
      'StreamingMap: менеджеру полос передан профиль ширины OSM, точек %d', [N]));
  end;

  if Assigned(FRemoteRiders) then FRemoteRiders.RefreshPreparedPath;
  FOsmWidthsApplied := True;
end;

procedure TViewPlay.ActivateOfflineMode;
begin
  Logger.Info('[ViewPlay] ' + '>>> ActivateOfflineMode');
  FreeAndNil(FLoopbackSession);
  SetupOfflineWorld;

  FActiveAvatarAgent := FOfflineAvatar;
  FActivePlayerController := FOfflineController;

  ApplyStreamingGroundQuery;

  if Assigned(SliderPower) and HasActiveState then
    SliderPower.Value := FActiveAvatarAgent.State.AppliedPowerWatts;
end;

procedure TViewPlay.ActivateLoopbackDualWorld;
begin
  FreeAndNil(FLoopbackSession);
  FLoopbackSession := TGameLoopbackSession.Create(FreeAtStop, MainViewport);
  FLoopbackSession.InitializeAvatarPair(
    AvatarTransform,
    SceneAvatar,
    AvatarRigidBody,
    MainViewport,
    ThirdPersonNavigation,
    SceneLevel,
    FOfflineAvatar.Path
  );

  FActiveAvatarAgent := FLoopbackSession.ClientAvatar;
  FActivePlayerController := FLoopbackSession.ClientController;

  ApplyStreamingGroundQuery;

  if Assigned(SliderPower) and HasActiveState then
    SliderPower.Value := FActiveAvatarAgent.State.AppliedPowerWatts;
end;

procedure TViewPlay.RestartLoopbackDualWorld;
begin
  ActivateLoopbackDualWorld;
end;

{ ═══════════════════════════════════════════════════════════════════
  Profiling log
  ═══════════════════════════════════════════════════════════════════ }

procedure TViewPlay.ProfileLogLine(const S: string);
begin
  if Assigned(FProfileLog) then
    FProfileLog.Add(FormatDateTime('hh:nn:ss.zzz', Now) + '  ' + S);
end;

procedure TViewPlay.ProfileLogFrameDetail;
var
  I, J: Integer;
  S: TCastleScene;
  Line, RemoteInfo: string;
  RiderShapes, TotalShapes, ViewportItems, BarrierCount, LevelShapes: Integer;
  RelayData: TRelayProfilingData;
begin
  if not Assigned(FProfileLog) then Exit;

  Inc(FProfileFrameNum);
  if (FProfileFrameNum mod 60 <> 0) and (FProf_FrameTotal < 70) then Exit;

  TotalShapes := 0;
  RiderShapes := 0;
  if Assigned(FBikeInstance) then
  begin
    for I := 0 to BSG_COUNT - 1 do
      if Assigned(FBikeInstance.SubScene(I)) and FBikeInstance.SubScene(I).Exists then
        RiderShapes := RiderShapes + FBikeInstance.SubScene(I).ShapesActiveCount;
    TotalShapes := TotalShapes + RiderShapes;
  end
  else if Assigned(SceneAvatar) and SceneAvatar.Exists then
  begin
    RiderShapes := SceneAvatar.ShapesActiveCount;
    TotalShapes := TotalShapes + RiderShapes;
  end;

  Line := Format('Frame#%d  FPS:%s  Update:%.1fms(W:%.1f B:%.1f R:%.1f P:%.1f U:%.1f)  Render:%.1fms',
    [FProfileFrameNum,
     Container.Fps.ToString,
     FProf_FrameTotal,
     FProf_WorldUpdate, FProf_BLE, FProf_Relay, FProf_Pose, FProf_Labels,
     FProf_Render]);

  RelayData := FRemoteRiders.GetProfilingData;
  if FProf_Relay > 0.5 then
    Line := Line + Format('  R[net:%.1f bld:%.1f cfg:%.1f pos:%.1f]',
      [RelayData.RelayNet, RelayData.RelayBuild,
       RelayData.RelayConfig, RelayData.RelayPos]);

  Line := Line + Format('  Avatar:%d shapes', [RiderShapes]);

  TotalShapes := TotalShapes + FRemoteRiders.CountRemoteShapes;
  FRemoteRiders.GetRemoteRiderShapeInfo(RemoteInfo);
  Line := Line + RemoteInfo;

  if RelayData.PendingBuildCount > 0 then
    Line := Line + Format('  Queue:%d', [RelayData.PendingBuildCount]);

  ViewportItems := 0;
  BarrierCount := 0;
  LevelShapes := 0;
  if Assigned(MainViewport) then
  begin
    ViewportItems := MainViewport.Items.Count;
    for I := 0 to ViewportItems - 1 do
      if MainViewport.Items[I] is TCastleTransformReference then
        Inc(BarrierCount);
  end;
  if Assigned(SceneLevel) then
    LevelShapes := SceneLevel.ShapesActiveCount;

    Line := Line + Format('  Total:%d shapes  VP:%d items  Riders:%d/%d  Level:%d',
      [TotalShapes, ViewportItems,
       RelayData.VisibleRiders, RelayData.RemoteVisualCount, LevelShapes]);

  FProfileLog.Add(FormatDateTime('hh:nn:ss.zzz', Now) + '  ' + Line);
  if GLogEnabled then
    Logger.Info('[Profile] ' + Line);
end;

procedure TViewPlay.ProfileSaveAndShow;
{$IFDEF MSWINDOWS}
var
  ClipText: string;
  HGlob: THandle;
  P: PChar;
{$ENDIF}
begin
  if not Assigned(FProfileLog) then Exit;
  if FProfileLog.Count = 0 then Exit;

  Logger.Info('[Profile] session dump (' + IntToStr(FProfileLog.Count) + ' lines)');
  if GLogEnabled then
    Logger.Info('[Profile]' + LineEnding + FProfileLog.Text);

  {$IFDEF MSWINDOWS}
  ClipText := FProfileLog.Text;
  if OpenClipboard(0) then
  begin
    EmptyClipboard;
    HGlob := GlobalAlloc(GMEM_MOVEABLE or GMEM_ZEROINIT, Length(ClipText) + 1);
    if HGlob <> 0 then
    begin
      P := GlobalLock(HGlob);
      if P <> nil then
      begin
        Move(ClipText[1], P^, Length(ClipText));
        GlobalUnlock(HGlob);
        SetClipboardData(CF_TEXT, HGlob);
      end;
    end;
    CloseClipboard;
  end;

  // ShellExecute(0, 'open', 'notepad.exe', PChar(FProfileLogFile), nil, SW_SHOWNORMAL);
  {$ENDIF}
end;

const
  TerrainMacroScale = 4.3;     { macro texture repeat in meters (larger = bigger patches) }
  TerrainMacroBlend = 0.95;    { macro blend strength (0 = off, 1 = full modulate) }

procedure TViewPlay.ScanTerrainTextureFolders;
var
  TerrainDir: string;
  SR: TSearchRec;
begin
  FreeAndNil(FTerrainTextureFolders);
  FTerrainTextureFolders := TStringList.Create;
  FTerrainTextureIndex := -1;

  TerrainDir := URIToFilenameSafe('castle-data:/terrain');
  if not DirectoryExists(TerrainDir) then
  begin
    Logger.Info('[Terrain] ' + 'Terrain texture directory not found: ' + TerrainDir);
    Exit;
  end;

  if FindFirst(TerrainDir + DirectorySeparator + '*', faDirectory, SR) = 0 then
  begin
    repeat
      if (SR.Attr and faDirectory) <> 0 then
        if (SR.Name <> '.') and (SR.Name <> '..') then
          FTerrainTextureFolders.Add(TerrainDir + DirectorySeparator + SR.Name);
    until FindNext(SR) <> 0;
    SysUtils.FindClose(SR);
  end;

  FTerrainTextureFolders.Sort;
  Logger.Info('[Terrain] ' + Format('Found %d terrain texture folders in %s',
    [FTerrainTextureFolders.Count, TerrainDir]));
end;

procedure TViewPlay.PreloadTerrainTextures;
var
  I: Integer;
  Proc: TPBRTextureProcessor;
  Textures: TPBRTextureSet;
  BBox: TBox3D;
begin
  if not Assigned(FTerrainTextureFolders) then Exit;
  if FTerrainTextureFolders.Count = 0 then Exit;
  if not Assigned(SceneLevel) then Exit;

  { Compute terrain size once }
  BBox := SceneLevel.BoundingBox;
  if BBox.IsEmpty then
  begin
    FTerrainSizeX := 1000;
    FTerrainSizeZ := 1000;
  end else begin
    FTerrainSizeX := BBox.Data[1].X - BBox.Data[0].X;
    FTerrainSizeZ := BBox.Data[1].Z - BBox.Data[0].Z;
    if FTerrainSizeX < 1 then FTerrainSizeX := 1000;
    if FTerrainSizeZ < 1 then FTerrainSizeZ := 1000;
  end;

  SetLength(FTerrainProcessors, FTerrainTextureFolders.Count);
  SetLength(FTerrainTexSets, FTerrainTextureFolders.Count);

  for I := 0 to FTerrainTextureFolders.Count - 1 do
  begin
    Proc := TPBRTextureProcessor.Create;
    FTerrainProcessors[I] := Proc;

    Textures := TPBRTextureProcessor.FindTextures(FTerrainTextureFolders[I]);

    { Downscale textures based on quality level }
    Proc.DownscaleTextureSet(Textures);

    { Pre-process images based on quality level }
    if (GlobalTextureQuality >= tqMedium) and (Textures.Normal <> '') then
      Textures.Normal := Proc.ConvertNormalDXtoGL(Textures.Normal);
    if (GlobalTextureQuality >= tqHigh) and (Textures.Roughness <> '') then
      Textures.Roughness := Proc.InvertRoughnessToShininess(Textures.Roughness);

    FTerrainTexSets[I] := Textures;
    Logger.Info('[Terrain] ' + Format('Preloaded terrain texture [%d/%d]: %s',
      [I + 1, FTerrainTextureFolders.Count,
       ExtractFileName(FTerrainTextureFolders[I])]));
  end;
end;

procedure TViewPlay.ApplyTerrainTextureByIndex(AIndex: Integer);
var
  Proc: TPBRTextureProcessor;
  Textures: TPBRTextureSet;
  PBRFx: TPBREffects;
  NewAppearance: TAppearanceNode;
  TexTransform: TTextureTransformNode;
  SI: TShapeTreeIterator;
  Shape: TShape;
  MacroTex: TAbstractTexture2DNode;
  GlslEffect: TEffectNode;
  GlslPart: TEffectPartNode;
  TexField: TSFNode;
  FS: TFormatSettings;
begin
  if not Assigned(SceneLevel) then Exit;
  if SceneLevel.RootNode = nil then Exit;
  if (AIndex < 0) or (AIndex >= Length(FTerrainTexSets)) then Exit;

  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';

  Proc := FTerrainProcessors[AIndex];
  Textures := FTerrainTexSets[AIndex];

  PBRFx := MakeEffectsForQuality(GlobalTextureQuality, Textures, False);

  { Safely unprepare GPU resources before modifying nodes }
  SceneLevel.GLContextClose;

  SI := TShapeTreeIterator.Create(SceneLevel.Shapes, true, false);
  try
    while SI.GetNext do
    begin
      Shape := SI.Current;
      if Shape.Node = nil then Continue;

      NewAppearance := Proc.BuildAppearance(Textures, PBRFx, 0.0);

      TexTransform := TTextureTransformNode.Create;
      TexTransform.Scale := Vector2(FTerrainSizeX, FTerrainSizeZ);
      NewAppearance.TextureTransform := TexTransform;

      { Macro-scale blend via GLSL Effect }
      if Textures.BaseColor <> '' then
      begin
        MacroTex := Proc.CreateImageTexture(Textures.BaseColor, True, True);

        GlslEffect := TEffectNode.Create;
        GlslEffect.Language := slGLSL;

        TexField := TSFNode.Create(GlslEffect, true, 'macro_tex', [TImageTextureNode, TPixelTextureNode]);
        TexField.Value := MacroTex;
        GlslEffect.AddCustomField(TexField);

        GlslPart := TEffectPartNode.Create;
        GlslPart.FdType.Send('VERTEX');
        GlslPart.Contents :=
          'varying vec2 macro_uv;' + LineEnding +
          'void PLUG_vertex_object_space(const in vec4 vertex, inout vec3 normal) {' + LineEnding +
          Format('  macro_uv = vertex.xz / %.1f;', [TerrainMacroScale], FS) + LineEnding +
          '}';
        GlslEffect.FdParts.Add(GlslPart);

        GlslPart := TEffectPartNode.Create;
        GlslPart.FdType.Send('FRAGMENT');
        GlslPart.Contents :=
          'uniform sampler2D macro_tex;' + LineEnding +
          'varying vec2 macro_uv;' + LineEnding +
          'void PLUG_texture_apply(inout vec4 fragment_color, const in vec3 normal_eye) {' + LineEnding +
          '  vec3 mc = texture2D(macro_tex, macro_uv).rgb;' + LineEnding +
          Format('  fragment_color.rgb *= mix(vec3(1.0), mc, %.2f);', [TerrainMacroBlend], FS) + LineEnding +
          '}';
        GlslEffect.FdParts.Add(GlslPart);

        NewAppearance.FdEffects.Add(GlslEffect);
      end;

      Shape.Node.Appearance := NewAppearance;
    end;
  finally
    SI.Free;
  end;

  SceneLevel.ChangedAll;
  Logger.Info('[Terrain] ' + Format('Switched terrain texture [%d/%d]: %s',
    [AIndex + 1, Length(FTerrainTexSets),
     ExtractFileName(FTerrainTextureFolders[AIndex])]));
end;

procedure TViewPlay.ApplyTerrainTexture;
var
  TerrainFolder: string;
  Textures: TPBRTextureSet;
  PBRFx: TPBREffects;
  NewAppearance: TAppearanceNode;
  TexTransform: TTextureTransformNode;
  ShapeNodes: TX3DNodeList;
  ShapeIdx: Integer;
  ShapeNode: TShapeNode;
  ShapeName: String;
  BBox: TBox3D;
  TerrainSizeX, TerrainSizeZ: Single;
  { Macro-scale blending }
  MacroTex: TAbstractTexture2DNode;
  GlslEffect: TEffectNode;
  GlslPart: TEffectPartNode;
  TexField: TSFNode;
  FS: TFormatSettings;
  SI: TShapeTreeIterator;
  Shape: TShape;

begin
  if not Assigned(SceneLevel) then Exit;
  if SceneLevel.RootNode = nil then Exit;

  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';

  TerrainFolder := URIToFilenameSafe('castle-data:/terrain/BeachGravel01_MR_1K');
  if not DirectoryExists(TerrainFolder) then
  begin
    Logger.Info('[Terrain] ' + 'PBR folder not found: ' + TerrainFolder);
    Exit;
  end;

  { Terrain size from bounding box — needed for UV scale }
  BBox := SceneLevel.BoundingBox;
  if BBox.IsEmpty then
  begin
    TerrainSizeX := 1000;
    TerrainSizeZ := 1000;
  end else begin
    TerrainSizeX := BBox.Data[1].X - BBox.Data[0].X;
    TerrainSizeZ := BBox.Data[1].Z - BBox.Data[0].Z;
    if TerrainSizeX < 1 then TerrainSizeX := 1000;
    if TerrainSizeZ < 1 then TerrainSizeZ := 1000;
  end;
  Logger.Info('[Terrain] ' + Format('Terrain size: %.1f x %.1f', [TerrainSizeX, TerrainSizeZ]));

  FTerrainPBR := TPBRTextureProcessor.Create;
  Textures := TPBRTextureProcessor.FindTextures(TerrainFolder);
  Logger.Info('[Terrain] ' + 'PBR BaseColor=' + Textures.BaseColor);
  Logger.Info('[Terrain] ' + 'PBR Normal=' + Textures.Normal);
  Logger.Info('[Terrain] ' + 'PBR Roughness=' + Textures.Roughness);

  { Downscale textures based on quality level }
  FTerrainPBR.DownscaleTextureSet(Textures);

  PBRFx := MakeEffectsForQuality(GlobalTextureQuality, Textures, False);

  SI := TShapeTreeIterator.Create(SceneLevel.Shapes, true, false);
  ShapeNodes := TX3DNodeList.Create(False);  { не-владелец, ноды живут в RootNode }
  try
    while SI.GetNext do
    begin
      Shape := SI.Current;
      if (Shape.Node <> nil) and (Shape.Node is TShapeNode) then
        ShapeNodes.Add(Shape.Node);
    end;
  finally
    SI.Free;
  end;

  { Общий Appearance для ВСЕХ чанков. Без этого — на 190 шейпах кастомной
    карты:
      - 190 раз создаётся отдельный TPhysicalMaterialNode + Effect →
        memory blowup;
      - 190 раз грузится с диска один и тот же макро-текстурный файл;
      - каждый ShapeNode.Appearance := X триггерит ChangedAll, который
        обходит все 190 шейпов сцены — O(N²) пересборок.
    Один общий Appearance даёт O(N) однократных присваиваний и одну
    финальную ChangedAll. }
  NewAppearance := FTerrainPBR.BuildAppearance(Textures, PBRFx, 0.0);

  TexTransform := TTextureTransformNode.Create;
  TexTransform.Scale := Vector2(TerrainSizeX, TerrainSizeZ);
  NewAppearance.TextureTransform := TexTransform;

  if Textures.BaseColor <> '' then
  begin
    MacroTex := FTerrainPBR.CreateImageTexture(Textures.BaseColor, True, True);

    GlslEffect := TEffectNode.Create;
    GlslEffect.Language := slGLSL;

    TexField := TSFNode.Create(GlslEffect, true, 'macro_tex', [TImageTextureNode, TPixelTextureNode]);
    TexField.Value := MacroTex;
    GlslEffect.AddCustomField(TexField);

    GlslPart := TEffectPartNode.Create;
    GlslPart.FdType.Send('VERTEX');
    GlslPart.Contents :=
      'varying vec2 macro_uv;' + LineEnding +
      'void PLUG_vertex_object_space(const in vec4 vertex, inout vec3 normal) {' + LineEnding +
      Format('  macro_uv = vertex.xz / %.1f;', [TerrainMacroScale], FS) + LineEnding +
      '}';
    GlslEffect.FdParts.Add(GlslPart);

    GlslPart := TEffectPartNode.Create;
    GlslPart.FdType.Send('FRAGMENT');
    GlslPart.Contents :=
      'uniform sampler2D macro_tex;' + LineEnding +
      'varying vec2 macro_uv;' + LineEnding +
      'void PLUG_texture_apply(inout vec4 fragment_color, const in vec3 normal_eye) {' + LineEnding +
      '  vec3 mc = texture2D(macro_tex, macro_uv).rgb;' + LineEnding +
      Format('  fragment_color.rgb *= mix(vec3(1.0), mc, %.2f);', [TerrainMacroBlend], FS) + LineEnding +
      '}';
    GlslEffect.FdParts.Add(GlslPart);

    NewAppearance.FdEffects.Add(GlslEffect);
  end;

  { Присваиваем общий Appearance всем шейпам. У TX3DNode встроен
    reference-counting, удерживающий узел живым пока на него ссылается
    хоть один родитель — ничего не утечёт и не освободится преждевременно. }
  try
    for ShapeIdx := 0 to ShapeNodes.Count - 1 do
    begin
      ShapeNode := ShapeNodes[ShapeIdx] as TShapeNode;
      if ShapeNode = nil then Continue;
      ShapeName := ShapeNode.X3DName;
      ShapeNode.Appearance := NewAppearance;
    end;
  finally
    ShapeNodes.Free;
  end;

  SceneLevel.ChangedAll;
  Logger.Info('[Terrain] ' + 'Terrain PBR texture applied with macro blending.');
end;

{ Определить актуальный путь к INI с точками дороги (дефолтный путь). }
procedure TViewPlay.ResolveMapPaths;
begin
  { Стриминговый режим (выбран FIT) берёт путь райдера из самого FIT —
    road-INI не используется. Дефолт (FIT не выбран) — стандартный INI. }
  FRoadPointsFileNameLocal := RoadPointsFileName;
end;

{ Прочитать map.json, загрузить рядом лежащий terrain.x3d (нерегулярный
  меш с локальным уплотнением вдоль дороги, собранный в editor) и подставить
  его SceneLevel-у. Из того же JSON взять routePoints + roadTexture и
  написать временный INI для существующих road-loader-ов.

  Точки маршрута и меш ОБА сохранены в editor-е уже нормализованными по
  MinY (низшая точка маршрута = 0), поэтому здесь НЕ применяется никаких
  Translation.Y. Если URL пуст или secции "terrainMesh" нет — выходим,
  оставляя дефолтный X3D-террейн из дизайна. }
function LoadTerrainSceneFromX3D(const ATerrainX3DUrl: String;
  ATargetScene: TCastleScene): Boolean;
var
  TerrainX3DPath: String;
begin
  Result := False;
  if ATargetScene = nil then Exit;
  if ATerrainX3DUrl = '' then Exit;

  TerrainX3DPath := URIToFilenameSafe(ATerrainX3DUrl);
  if (TerrainX3DPath = '') or (not FileExists(TerrainX3DPath)) then
  begin
    Logger.Info('[CustomTerrain] ' + 'LoadTerrainSceneFromX3D: x3d не найден: ' + ATerrainX3DUrl);
    Exit;
  end;

  { Сцена сбрасывается в идентичное состояние (без Translation/Rotation
    из дизайна) — координаты меша мировые. Collider mesh пересоберётся
    автоматически по новому корню сцены. }
  ATargetScene.Translation := Vector3(0, 0, 0);
  ATargetScene.Rotation    := Vector4(0, 1, 0, 0);
  ATargetScene.Load(ATerrainX3DUrl);

  { LOD для чанков земли: CGE сам гасит дальние Shape'ы по DistanceCulling
    (метров до камеры). Frustum culling per-shape работает автоматически
    при нескольких Shape-узлах в сцене. У нас в terrain.x3d по одному
    Shape на чанк, так что оба механизма дают эффект. }
  ATargetScene.DistanceCulling := 1500;

  Result := True;
end;

{ Запуск стриминга по выбранному FIT — прямой аналог студийного
  btnGenerateClick: загрузить FIT → StartFromFit → BeginRouteSnap →
  очистить дефолтный террейн (велосипедист едет по тайлам Osm3d).
  Пусто (FIT не выбран) → выходим, оставляя дефолтный мир. }
procedure TViewPlay.SetCoastalSky(Enabled:Boolean);
begin
  if Enabled then begin
    if FCoastalSky=nil then FCoastalSky:=CreateCoastalSky(FreeAtStop);
    MainViewport.Background:=FCoastalSky;
  end else MainViewport.Background:=FDefaultSky;
  FCoastalSkyActive:=Enabled;
end;

procedure TViewPlay.ApplyCustomTerrainScene;
var
  FitPath: String;
  Fit: TFitFile;
begin
  SetCoastalSky(False);
  if FDreamWorld<>nil then begin
    if FDreamVisual<>nil then begin
      FCoastalSkyActive:=FDreamVisual.CoastalSky<>nil;
      if FCoastalSkyActive then MainViewport.Background:=FDreamVisual.CoastalSky;
    end;
    if SceneLevel=nil then begin SceneLevel:=TCastleScene.Create(FreeAtStop);MainViewport.Items.Add(SceneLevel);end;
    if FDreamVisual=nil then raise Exception.Create('Dream scene is not prepared');
    FDreamVisual.AttachTo(SceneLevel,False);
    if SceneRoadBarrier<>nil then SceneRoadBarrier.Exists:=False;
    FOsmPrepHold:=False;
    Logger.Info('[DreamWorld] Loaded '+FDreamWorld.Id+'; local baked geometry, no OSM requests');Exit;
  end;
  if FCurrentFitPath = '' then Exit;          { FIT не выбран — дефолтный мир }
  if not Assigned(MainViewport) then
  begin
    Logger.Info('[ViewPlay] StreamingMap: MainViewport не назначен, выход');
    Exit;
  end;

  { Принимаем и системный путь, и URI (меню шлёт системный путь). }
  FitPath := URIToFilenameSafe(FCurrentFitPath);
  if (FitPath = '') or (not FileExists(FitPath)) then
    FitPath := FCurrentFitPath;
  if not FileExists(FitPath) then
  begin
    Logger.Info('[ViewPlay] StreamingMap: FIT не найден: ' + FCurrentFitPath);
    Exit;
  end;

  Logger.Info('[ViewPlay] StreamingMap: STAGE 1/3 загрузка маршрута ' + FitPath);
  Fit := NewRouteParserForFile(FitPath);   { .fit или .gpx — по расширению }
  try
    if not Fit.LoadFromFile(FitPath) then
    begin
      Logger.Info('[ViewPlay] StreamingMap: ошибка чтения маршрута: ' + FitPath);
      Exit;
    end;
    if Length(Fit.RouteLatLon) < 2 then
    begin
      Logger.Info('[ViewPlay] StreamingMap: в файле нет валидного GPS-маршрута');
      Exit;
    end;

    Logger.Info('[ViewPlay] StreamingMap: STAGE 2/3 старт стриминга '
      + '(как студийный btnGenerateClick)');
    FOsmStreaming := TGameOsmStreaming.Create;
    { Папка заездов + имя FIT — боевой путь коррекции: FIT-слой высот
      строится в Create сессии, его сигнатура и имя FIT входят в gen-hash.
      РОВНО эти же аргументы передаёт «Полная статистика» страницы
      «Маршруты» — только так её прогрев попадает в кэш игры. }
    if not FOsmStreaming.StartFromFit(Fit.RouteLatLon, Fit.RouteStartUTC,
      MainViewport, '',
      ExtractFilePath(FitPath), ExtractFileName(FitPath)) then
    begin
      Logger.Info('[ViewPlay] StreamingMap: StartFromFit не удался');
      FreeAndNil(FOsmStreaming);
      Exit;
    end;

    { Привязка маршрута к дорожной сети OSM — асинхронно (как студия/оверлей). }
    FOsmStreaming.BeginRouteSnap;

    { Холд старта заезда: прогрев тайлов маршрута + снап обязаны
      завершиться ДО движения. Update каждый кадр гасит AutoMove, пока
      RoutePrepDone не станет True; прогресс юзеру показывает
      WarmupOverlay карты. Без холда райдер обгоняет генерацию тайлов
      и едет по пустоте, а коридор монтируется у него за спиной. }
    FOsmPrepHold := True;
    FOsmPrepHoldLogTick := 0;
    FOsmPrepResumeAutoMove := False;
    FOsmPrepGroundSince := 0;
    FOsmPrepRaised := False;
    Logger.Info('[ViewPlay] StreamingMap: холд старта — ждём прогрев '
      + 'тайлов маршрута и снап (RoutePrepDone)');

    { Дефолтный террейн из дизайна не нужен — велосипедист едет по тайлам
      Osm3d, физика берёт высоту из GroundQuery стриминга. }
    if Assigned(SceneLevel) then
    begin
      SceneLevel.Load(nil, True);
      { КРИТИЧНО: обнулить трансформ сцены уровня. Точки пути в стриминге
        приходят из LoadAvatarPath уже в МИРОВЫХ координатах (проекция
        сессии = проекция тайлов), но TGamePath прогоняет их через
        FLevelScene.LocalToWorld (наследие road-INI, где точки локальные).
        Ненулевой Translation/Rotation/Scale у SceneLevel из дизайна
        сдвигал/поворачивал путь и старт райдера относительно коридора
        тайлов — райдер уезжал мимо коридора в пустоту. Старый JSON-путь
        (LoadTerrainSceneFromX3D) не зря сбрасывал трансформ явно.
        Пояс к подтяжкам: LoadAgentPath в стриминге дополнительно делает
        SetLevelScene(nil) — путь вообще не трогает сцену. Сброс здесь
        нужен остальным потребителям SceneLevel (RemoteRiders и т.п.). }
      SceneLevel.Translation := Vector3(0, 0, 0);
      SceneLevel.Rotation    := Vector4(0, 1, 0, 0);
      SceneLevel.Scale       := Vector3(1, 1, 1);
      Logger.Info('[ViewPlay] StreamingMap: SceneLevel очищен, трансформ '
        + 'сброшен в identity (стриминг заменяет террейн; путь — мировой)');
    end;
  finally
    Fit.Free;
  end;

  if (FOsmStreaming.Session <> nil) and (FOsmStreaming.Session.Map <> nil) then
    FOsmStreaming.Session.Map.Visible := FPerfTerrain;
  Logger.Info('[ViewPlay] StreamingMap: STAGE 3/3 стриминговая карта запущена');
end;

procedure TViewPlay.AnimateBotBikes(const SecondsPassed: Single);
var
  I: Integer;
  BotBike: TBikeInstance;
  Ag: TPhysicalAgent;
begin
  if not Assigned(FBotBikes) then Exit;
  for I := 0 to FBotBikes.Count - 1 do
  begin
    BotBike := TBikeInstance(FBotBikes[I]);
    if FPerfAnim and Assigned(FBotAgents) and (I < FBotAgents.Count) then
    begin
      Ag := TPhysicalAgent(FBotAgents[I]);
      ApplySteerFromPhysics(BotBike, Ag);
    end;
    BotBike.AnimateFrame(SecondsPassed);
  end;
end;

procedure TViewPlay.AttachBotPoseManager(ABike: TBikeInstance);
var PM: TRiderPoseManager;
begin
  if (ABike = nil) or (FBotPoseManagers = nil) then Exit;
  PM := TRiderPoseManager.Create(ABike);
  if Assigned(FPoseManager) then PM.SetPoses(FPoseManager.Poses);
  FBotPoseManagers.Add(PM);
end;

procedure TViewPlay.UpdateBotPoseManagers(const SecondsPassed: Single);
const
  { Pose auto-select only for nearby bots — same idea as shadow LOD. }
  PoseMaxDistM   = 100.0;
  PoseMaxDistSq  = PoseMaxDistM * PoseMaxDistM;
  { Rough FOV gate: reject bots well outside the view cone (~75° half-angle). }
  PoseMinCos     = 0.25;
var
  I: Integer;
  PM: TRiderPoseManager;
  BotBike: TBikeInstance;
  Ag: TPhysicalAgent;
  BotPos, CamPos, CamDir, CamUp, ToBot: TVector3;
  DX, DZ, DSq, Dist, Ahead, CrankInterval: Single;
  Sit: TRiderSituation;
  InView, Near: Boolean;
begin
  if not FPerfAnim then Exit;
  if not Assigned(FBotPoseManagers) then Exit;
  if not Assigned(FBotBikes) then Exit;
  if not Assigned(FBotAgents) then Exit;

  CamPos := Vector3(0, 0, 0);
  CamDir := Vector3(0, 0, 1);
  CamUp  := Vector3(0, 1, 0);
  if Assigned(MainViewport) and Assigned(MainViewport.Camera) then
    MainViewport.Camera.GetView(CamPos, CamDir, CamUp);

  for I := 0 to FBotPoseManagers.Count - 1 do
  begin
    if I >= FBotBikes.Count then Break;
    if I >= FBotAgents.Count then Break;
    PM := TRiderPoseManager(FBotPoseManagers[I]);
    BotBike := TBikeInstance(FBotBikes[I]);
    Ag := TPhysicalAgent(FBotAgents[I]);
    if (PM = nil) or (BotBike = nil) or (Ag = nil) then Continue;
    if not Assigned(Ag.State) then Continue;
    if PM.PoseCount = 0 then Continue;

    { Local bots have power but no cadence sensor. Derive their requested
      cadence from effort, independently of the foot-contact crank lock. }
    Sit.SpeedKmh := Ag.State.CurrentSpeed * 3.6;
    Sit.PowerW := Ag.State.AppliedPowerWatts;
    Sit.CadenceRpm := 0;
    if Ag.State.AutoMove and (Sit.PowerW > 1) then
      Sit.CadenceRpm := EnsureRange(65.0 + Sit.PowerW * 0.10, 65.0, 105.0);
    if Sit.CadenceRpm > 0 then CrankInterval := 60 / Sit.CadenceRpm
    else CrankInterval := 9999;
    BotBike.SetAnimationSpeed(CrankInterval, CrankInterval);
    BotBike.SetWheelSpeedMps(Ag.State.CurrentSpeed);
    Sit.GradePct := SlopeDegToGradePct(Ag.State.CurrentSlopeAngle);
    Sit.LateralAccel := Ag.State.CurrentLateralAccel;
    Sit.FtpW := 0;

    { Support must also be up to date when a bot enters the camera view. }
    if (Abs(Sit.SpeedKmh) < 1.2) or BotBike.BuildRiderPose('').Grounded then
    begin
      PM.Update(SecondsPassed, Sit);
      Continue;
    end;

    { Hidden by perf toggle or scene — not "visible". }
    if (BotBike.Group = nil) or (not BotBike.Group.Exists) then Continue;
    if Assigned(Ag.Actor) and Assigned(Ag.Actor.Transform)
       and (not Ag.Actor.Transform.Exists) then Continue;

    BotPos := Ag.State.WorldPosition;
    Near := True;
    if Assigned(AvatarTransform) then
    begin
      DX := BotPos.X - AvatarTransform.Translation.X;
      DZ := BotPos.Z - AvatarTransform.Translation.Z;
      DSq := DX * DX + DZ * DZ;
      Near := DSq <= PoseMaxDistSq;
    end;
    if not Near then Continue;

    { Visible ≈ in front of camera and inside a wide view cone. }
    ToBot := BotPos - CamPos;
    Ahead := TVector3.DotProduct(ToBot, CamDir);
    if Ahead <= 0 then Continue;   { behind camera }
    Dist := Sqrt(ToBot.X * ToBot.X + ToBot.Y * ToBot.Y + ToBot.Z * ToBot.Z);
    if Dist < 0.01 then
      InView := True
    else
      InView := (Ahead / Dist) >= PoseMinCos;
    if not InView then Continue;

    PM.Update(SecondsPassed, Sit);
  end;
end;

function TViewPlay.GetGroundShadeDiag: String;
var P: TVector3; Level: Single;
begin
  Result := 'front=unavailable';
  if (FActiveAvatarAgent=nil) or (FActiveAvatarAgent.State=nil) then Exit;
  P := FActiveAvatarAgent.State.FrontGroundPoint;
  Level := 0;
  if (FBikeInstance<>nil) and (FBikeInstance.TripoRider<>nil) then
    Level := FBikeInstance.TripoRider.GroundShade;
  Result := Format('front=(%.3f,%.3f,%.3f) valid=%s coverage=%.4f shade=%.4f',
    [P.X,P.Y,P.Z,BoolToStr(FActiveAvatarAgent.State.FrontGroundPointValid,True),
     FGroundShadeTarget,Level]);
end;

procedure TViewPlay.UpdateRiderGroundShade(const Dt: Single);
var Target, Current, Alpha, ResponseTime: Single; P: TVector3; Valid: Boolean;
begin
  if (FBikeInstance=nil) or (FBikeInstance.TripoRider=nil) then Exit;
  Target := FGroundShadeTarget;
  Valid := False;
  if (Assigned(FOsmStreaming)or Assigned(FDreamWorld)) and Assigned(FActiveAvatarAgent) and
    Assigned(FActiveAvatarAgent.State) and FActiveAvatarAgent.State.FrontGroundPointValid then
  begin
    P := FActiveAvatarAgent.State.FrontGroundPoint;
    if FPerfShadows and FPerfTerrain and FPerfRiders and FAtlasWorldShadows and
      not FOsmPrepHold and UseSharedRiderShadows and (FShadowAtlas <> nil) then
      Valid := FShadowAtlas.TryGroundCoverage(P, Target);
    if Valid then begin
      FGroundShadeAge := 0;
      FGroundShadePoint := P;
    end;
  end;
  if not (FPerfShadows and FPerfTerrain and FPerfRiders and FAtlasWorldShadows) or
    FOsmPrepHold or not UseSharedRiderShadows then
  begin
    if FShadowAtlas <> nil then FShadowAtlas.SetGroundProbe(Vector3(0, 0, 0), False);
    FGroundShadeTarget := 0;
    FGroundShadeAge := 0;
    FBikeInstance.TripoRider.GroundShade := 0;
    Exit;
  end;
  { Missing ground/readback is unknown light, not a measured sunny sample.
    Hold briefly through asynchronous misses; never carry shade over a seek. }
  if not Valid then begin
    FGroundShadeAge := FGroundShadeAge + Math.Max(Dt, 0.0);
    Target := FGroundShadeTarget;
    if (FGroundShadeAge > 0.5) or
       (Assigned(FActiveAvatarAgent) and
        ((FActiveAvatarAgent.State.WorldPosition-FGroundShadePoint).Length > 5)) then
      Target := 0;
  end;
  FGroundShadeTarget := Target;
  Current := FBikeInstance.TripoRider.GroundShade;
  { At rest smooth asynchronous GPU coverage over 0.15 s. At speed keep the
    characteristic response distance within 0.35 m, independent of FPS. }
  ResponseTime := 0.15;
  if Assigned(FActiveAvatarAgent) and Assigned(FActiveAvatarAgent.State) then
    ResponseTime := Math.Min(ResponseTime, 0.35 /
      Math.Max(Abs(FActiveAvatarAgent.State.CurrentSpeed), 0.01));
  Alpha := 1-Exp(-Math.Max(Dt,0.0)/ResponseTime);
  Current := Current+(Target-Current)*Alpha;
  if Abs(Current-Target)<0.001 then Current := Target;
  FBikeInstance.TripoRider.GroundShade := Current;
end;

procedure TViewPlay.SetShadowTestRiders(const Count: Integer; const Zones: Boolean);
var I: Integer; B: TBikeInstance; Root: TCastleTransform;
begin
  if (Count < 0) or (Count > 15) then raise Exception.Create('Diagnostic rider count must be 0..15');
  if Assigned(FShadowTestBikes) then
    for I := 0 to FShadowTestBikes.Count - 1 do
    begin
      TObject(FShadowTestBikes[I]).Free;
      FShadowTestRoots[I].Free;
    end;
  FreeAndNil(FShadowTestBikes);
  FreeAndNil(FShadowTestRoots);
  FShadowTestZones := Zones;
  if Count = 0 then Exit;
  if (FBikeInstance = nil) or (MainViewport = nil) then
    raise Exception.Create('Start a ride before creating diagnostic riders');
  FShadowTestBikes := TList.Create;
  FShadowTestRoots := TCastleTransformList.Create(False);
  for I := 0 to Count - 1 do
  begin
    Root := TCastleTransform.Create(FreeAtStop);
    B := nil;
    try
      B := LoadBikeInstanceFromJSON(BikeJsonFileName2, FreeAtStop);
      Root.Add(B.Group);
      MainViewport.Items.Add(Root);
      ApplyWorldSunToBikeShadow(B);
      if UseSharedRiderShadows then B.ShadowMode := bsmNone else B.ShadowMode := bsmCGE;
      FShadowTestBikes.Add(B);
      FShadowTestRoots.Add(Root);
    except
      B.Free;
      Root.Free;
      raise;
    end;
  end;
  UpdateShadowTestRiders(0);
end;

procedure TViewPlay.UpdateShadowTestRiders(const SecondsPassed: Single);
const ZoneDistance: array[0..4] of Single = (2.5, 7, 18, 40, 70);
var I: Integer; B: TBikeInstance; P, D, U, Side, Sun: TVector3;
  Distance, GroundY: Single;
begin
  if (FShadowTestBikes = nil) or (FBikeInstance = nil) then Exit;
  FBikeInstance.Group.Parent.GetWorldView(P, D, U);
  Side := TVector3.CrossProduct(D, U).Normalize;
  if FShadowTestZones and Assigned(FOsmStreaming) and FOsmStreaming.SunWorldDir(Sun) then
    Side := TVector3.CrossProduct(Sun, Vector3(0, 1, 0)).Normalize;
  for I := 0 to FShadowTestBikes.Count - 1 do
  begin
    B := TBikeInstance(FShadowTestBikes[I]);
    if FShadowTestZones then Distance := ZoneDistance[I mod 5]
    else Distance := 2.5 * (1 + I mod 5);
    FShadowTestRoots[I].SetWorldView(P + Side * Distance - D * (I div 5) * 3, D, U);
    if Assigned(FOsmStreaming) and FOsmStreaming.GroundYAt(
      FShadowTestRoots[I].Translation.X, FShadowTestRoots[I].Translation.Z, GroundY) then
      FShadowTestRoots[I].Translation := Vector3(FShadowTestRoots[I].Translation.X,
        GroundY, FShadowTestRoots[I].Translation.Z);
    B.Group.Exists := FPerfRiders;
    B.ShowShadow := FPerfShadows;
    B.AnimationEnabled := FPerfAnim;
    B.AnimateFrame(SecondsPassed); { disabled animation updates only world light }
  end;
end;

function TViewPlay.CurrentSun(out Sun:TVector3):Boolean;
begin
  { CurrentSun returns the ray direction, while the package stores toward sun. }
  if FDreamWorld<>nil then begin Sun:=-FDreamWorld.Sun;Exit(True);end;
  Result:=Assigned(FOsmStreaming)and FOsmStreaming.Active and FOsmStreaming.SunWorldDir(Sun);
end;

function TViewPlay.UseSharedRiderShadows: Boolean;
begin
  Result := (Assigned(FOsmStreaming)or Assigned(FDreamWorld)) and not CliFlag('legacyridershadows') and
    not CliFlag('catchwhite') and not CliFlag('capsules') and not CliFlag('noshadow');
end;

function TViewPlay.RiderShadowInfo: String;
begin
  if not UseSharedRiderShadows then Exit('legacy');
  if FShadowAtlas = nil then Exit('atlas: waiting');
  Result := FShadowAtlas.DebugInfo;
end;

procedure TViewPlay.Render;
var I: Integer; Focus, Sun: TVector3;
begin
  if HasActiveState then FActiveAvatarAgent.TracePosition(mtRenderBegin);
  if Assigned(FOsmStreaming)and Assigned(FOsmStreaming.Session)and
     Assigned(FOsmStreaming.Session.Map) then FOsmStreaming.Session.Map.RenderGpuGround;
  if FFocusMode then begin
    { Wheel contacts remain available; all visual passes and viewport are hidden. }
    MotionTrace.EndFrame;inherited;Exit;
  end;
  if FPerfTerrain and ((FDreamWorld<>nil)or(Assigned(FOsmStreaming)and FOsmStreaming.Active))
     and Assigned(MainViewport.Camera) then
    RoadMaterialRender(MainViewport.Camera.WorldTransform.MultPoint(TVector3.Zero));
  if UseSharedRiderShadows and FPerfShadows and FPerfRiders and FPerfTerrain and
     Assigned(FBikeInstance) and Assigned(MainViewport.Camera) and
     ((FDreamWorld<>nil)or(Assigned(FOsmStreaming)and FOsmStreaming.Active)) then
  begin
    if CurrentSun(Sun) then
    begin
      if FShadowAtlas = nil then
      begin
        FShadowAtlas := TRiderShadowAtlas.Create;
        FShadowAtlas.Configure(Settings.GetGraphicsOption(Ord(goShadowSize)),
          Settings.GetGraphicsOption(Ord(goShadowFilter)),
          Settings.GetGraphicsOption(Ord(goShadowDistance)));
      end;
      FShadowAtlas.Casters.Clear;
      FShadowAtlas.WorldCasters.Clear;
      FShadowAtlas.WorldShadows := FAtlasWorldShadows and not FOsmPrepHold;
      if FShadowAtlas.WorldShadows then begin
        if FDreamWorld<>nil then FDreamVisual.AppendShadowCasters(FShadowAtlas.WorldCasters)
        else if FOsmStreaming.Session<>nil then FOsmStreaming.Session.Map.AppendWorldShadowCasters(FShadowAtlas.WorldCasters);
      end;
      FShadowAtlas.Casters.Add(FBikeInstance.Group);
      if Assigned(FBotBikes) then
        for I := 0 to FBotBikes.Count - 1 do
          FShadowAtlas.Casters.Add(TBikeInstance(FBotBikes[I]).Group);
      if Assigned(FRemoteRiders) then FRemoteRiders.AppendShadowCasters(FShadowAtlas.Casters);
      if Assigned(FShadowTestBikes) then
        for I := 0 to FShadowTestBikes.Count - 1 do
          FShadowAtlas.Casters.Add(TBikeInstance(FShadowTestBikes[I]).Group);
      Focus := MainViewport.Camera.WorldTransform.MultPoint(TVector3.Zero);
      if Assigned(FActiveAvatarAgent) and Assigned(FActiveAvatarAgent.State) then
        FShadowAtlas.SetGroundProbe(FActiveAvatarAgent.State.FrontGroundPoint,
          FShadowAtlas.WorldShadows and FActiveAvatarAgent.State.FrontGroundPointValid, False)
      else FShadowAtlas.SetGroundProbe(Focus, False);
      FShadowAtlas.Render(MainViewport, Focus, Sun, FBikeInstance.ShadowStrength);
    end else HideGroundRiderShadow;
  end;
  if HasActiveState then FActiveAvatarAgent.TracePosition(mtRenderReady);
  MotionTrace.EndFrame;
  inherited;
end;

procedure TViewPlay.RenderOverChildren;
begin inherited;if FKeyboard<>nil then FKeyboard.Render;end;

function TViewPlay.PreviewPress(const Event:TInputPressRelease):Boolean;
begin
  if(FKeyboard<>nil)and FKeyboard.Handle(Event,Self)then Exit(True);
  Result:=inherited;
end;

procedure TViewPlay.ClickTrainingFocus(Sender:TObject);
begin SetTrainingFocus(not FFocusMode);end;

procedure TViewPlay.SetTrainingFocus(Value:Boolean);
begin
  if(Value=FFocusMode)or(Value and(FOsmPrepHold or not HasActiveState))then Exit;
  FFocusMode:=Value;FCameraDragging:=False;
  MainViewport.Exists:=not Value;FFocusPanel.Exists:=Value;
  TCastleUserInterface(DesignedComponent('HorizontalGroup1')).Exists:=not Value;
  FFocusPanel.SyncWindow(Value and(Container.PendingFrontView=Self));
  if FWorkoutHud<>nil then FWorkoutHud.FocusMode:=Value;
  if Value then BindUiText(FFocusButton,'Return to 3D')
  else begin
    BindUiText(FFocusButton,'Training focus');
    if Assigned(FCinematicCam)and FCinematicCam.Enabled then FCinematicCam.ResetAtTarget;
  end;
  if FKeyboard<>nil then FKeyboard.Clear;
  FAdminLayoutValid:=False;UpdateAdminPanels;
end;

procedure TViewPlay.UpdateGroundRiderShadow;
var
  Map: TGeneratedShadowMapNode;
  GroundReceiver: Boolean;
begin
  { Receiver selection belongs to the world, not to temporary map availability.
    Streaming/rebuilding the source must never expose the old transparent quad. }
  GroundReceiver := (Assigned(FOsmStreaming)or(Assigned(FDreamWorld)and UseSharedRiderShadows)) and not CliFlag('catchwhite');
  if Assigned(FBikeInstance) then
    FBikeInstance.SetGroundShadowReceiver(GroundReceiver);
  if not FPerfShadows or not FPerfRiders then
  begin
    HideGroundRiderShadow;
    Exit;
  end;
  if UseSharedRiderShadows then
  begin
    if Assigned(FBikeInstance) then FBikeInstance.ShadowMode := bsmNone;
    if (FDreamWorld=nil)and not FOsmStreaming.Active then HideGroundRiderShadow;
    Exit; { atlas is updated on the render thread after all riders are posed }
  end;
  Map := nil;
  if Assigned(FBikeInstance) and GroundReceiver and FOsmStreaming.Active then
    Map := FBikeInstance.GroundShadowMap;
  if (Map <> nil) and (Map.Light is TAbstractPunctualLightNode) then
    SetGroundRiderShadow(Map,
      TAbstractPunctualLightNode(Map.Light).GetProjectorMatrix, FBikeInstance.ShadowStrength)
  else
    ClearGroundRiderShadow;
end;

procedure TViewPlay.UpdateBotShadowLOD;
const
  ShadowLODOnDistSq  = 45.0 * 45.0;   { гистерезис: включить тень < 45 м }
  ShadowLODOffDistSq = 55.0 * 55.0;   { выключить > 55 м }
var
  I: Integer;
  DX, DZ, DSq: Single;
  Ag: TPhysicalAgent;
  BotBike: TBikeInstance;
  Near: Boolean;
begin
  if (not Assigned(FBotAgents)) or (not Assigned(FBotBikes)) then Exit;
  if not Assigned(AvatarTransform) then Exit;
  for I := 0 to FBotAgents.Count - 1 do
  begin
    Ag := TPhysicalAgent(FBotAgents[I]);
    if not Assigned(Ag.State) then Continue;
    DX := Ag.State.WorldPosition.X - AvatarTransform.Translation.X;
    DZ := Ag.State.WorldPosition.Z - AvatarTransform.Translation.Z;
    DSq := DX * DX + DZ * DZ;
    { Гистерезис 45/55 м по ТЕКУЩЕМУ режиму тени: без него бот на границе
      каждый кадр дёргал бы ApplyShadowMode, а она форсит переразметку
      shadow receivers всей сцены (микрофризы/моргание). }
    BotBike := nil;
    if I < FBotBikes.Count then
      BotBike := TBikeInstance(FBotBikes[I]);
    if (BotBike <> nil) and (BotBike.ShadowMode = bsmNone) then
      Near := DSq < ShadowLODOnDistSq
    else
      Near := DSq < ShadowLODOffDistSq;
    { Плоские пробы теневой плоскости считаем только там, где тень
      вообще рисуется: внутри shadow-LOD и при включённых райдерах. }
    Ag.State.ShadowPlaneWanted := Near and FPerfRiders and FPerfShadows and not UseSharedRiderShadows;
    { Свой теневой проход bsmCGE только у ближних ботов; дальних
      тень не рисуем вообще (bsmNone). Сеттер идемпотентен. }
    if BotBike <> nil then
      if Near and not UseSharedRiderShadows then
        BotBike.ShadowMode := bsmCGE
      else
        BotBike.ShadowMode := bsmNone;
  end;
end;

procedure TViewPlay.ApplyWorldSunToBikeShadow(ABike: TBikeInstance);
var
  SunDir: TVector3;
begin
  if ABike = nil then Exit;
  if not CurrentSun(SunDir) then Exit;
  ABike.ShadowSunWorldDir := SunDir;
  Logger.Info(Format(
    '[ViewPlay] Bike contact shadow: world sun (%.3f, %.3f, %.3f)',
    [SunDir.X, SunDir.Y, SunDir.Z]));
end;

procedure TViewPlay.ApplyTerrainSlopeToBikeShadow;
{ Two jobs:
  1) Feed the physics where the shadow CENTRE is (bike + horizontal sun
     projection of the bike's mid height), so its ground-plane fit samples the
     terrain UNDER THE SHADOW, which a low sun pushes off to one side.
  2) Read back the ground normal the physics captured from the wheel/shadow
     samples and hand it to the capsule shadow.
  The offset feed applies to next frame's fit — fine, the sun pans slowly. }
const
  SHADOW_MID_H = 0.7;   { ~mid height of the bike+rider mass, m — sets how far
                          the shadow centre slides from the bike under a low sun }
var
  WorldN, LocalN, Sun: TVector3;
  invY, offX, offZ: Single;
begin
  if FBikeInstance = nil then Exit;
  if not Assigned(FActiveAvatarAgent) then Exit;
  if not Assigned(FActiveAvatarAgent.State) then Exit;

  { shadow-centre offset from the sun: centre slides opposite the sun's
    horizontal travel by mid_height / tan(elevation) }
  Sun := FBikeInstance.ShadowSunWorldDir;   { light travel, Y < 0 }
  if Sun.Y < -0.05 then
  begin
    invY := 1.0 / (-Sun.Y);
    offX := Sun.X * SHADOW_MID_H * invY;
    offZ := Sun.Z * SHADOW_MID_H * invY;
    { cap so a very low sun doesn't fling the sample patch metres away }
    if offX >  2.5 then offX :=  2.5;  if offX < -2.5 then offX := -2.5;
    if offZ >  2.5 then offZ :=  2.5;  if offZ < -2.5 then offZ := -2.5;
    FActiveAvatarAgent.State.ShadowCenterOffset := Vector3(offX, 0, offZ);
  end
  else
    FActiveAvatarAgent.State.ShadowCenterOffset := Vector3(0, 0, 0);

  if not FActiveAvatarAgent.State.ShadowGroundNormalValid then Exit;
  WorldN := FActiveAvatarAgent.State.ShadowGroundNormal;
  LocalN := FBikeInstance.Group.WorldInverseTransform.MultDirection(WorldN);
  FBikeInstance.ShadowGroundNormal := LocalN;
end;

procedure TViewPlay.Start;
var
  SL: TStringList;
  Labels: THudLabels;
  WorldSun: TVector3;
  FogDistM: Single;
  FogClearM: Single;
  I: Integer;
  function AddZoneWheel(const ValueLabel: TCastleLabel; const WheelName: String): TCastleZoneWheel;
  begin
    Result:=TCastleZoneWheel.Create(FreeAtStop);
    Result.Name:=WheelName; Result.Orientation:=woHorizontal;
    Result.Width:=128; Result.Height:=26; Result.FontSize:=18;
    ValueLabel.Parent.InsertFront(Result);
  end;
  procedure FixMetricWidth(const ValueLabel: TCastleLabel; const AWidth: Single);
  var Column: TCastleVerticalGroup;
  begin
    ValueLabel.AutoSize:=False; ValueLabel.Width:=AWidth; ValueLabel.Height:=58;
    ValueLabel.Alignment:=hpMiddle; ValueLabel.VerticalAlignment:=vpMiddle;
    Column:=ValueLabel.Parent as TCastleVerticalGroup;
    Column.AutoSizeWidth:=False; Column.Width:=AWidth; Column.Spacing:=2;
  end;
  procedure PrepareHudLayout;
  var Top: TCastleHorizontalGroup; K: Integer; C: TCastleUserInterface;
  begin
    BindUiText(DesignedComponent('LabelWorkTitle')as TCastleLabel,'Work today, kJ');
    Top:=DesignedComponent('HorizontalGroup1') as TCastleHorizontalGroup;
    Top.Alignment:=vpTop;
    FixMetricWidth(LabelPower,140); FixMetricWidth(LabelSpeed,140);
    FixMetricWidth(LabelCadence,140); FixMetricWidth(LabelHeart,140);
    FixMetricWidth(LabelSlope,180); FixMetricWidth(LabelWork,180);
    LabelWorkTSS.AutoSize:=False;LabelWorkTSS.Width:=180;LabelWorkTSS.Height:=26;
    LabelWorkTSS.FontSize:=18;LabelWorkTSS.Alignment:=hpMiddle;LabelWorkTSS.VerticalAlignment:=vpMiddle;
    LabelCorr.AutoSize:=False; LabelCorr.Width:=180; LabelCorr.Height:=26;
    LabelCorr.FontSize:=18; LabelCorr.Alignment:=hpMiddle; LabelCorr.VerticalAlignment:=vpMiddle;
    // Reuse the design's spacers, but their width no longer hosts a reel.
    for K:=0 to Top.ControlsCount-1 do
    begin
      C:=Top.Controls[K];
      if C.ClassType=TCastleUserInterface then begin C.Width:=16; C.Height:=1 end;
    end;
    BindUiText(DesignedComponent('Label2') as TCastleLabel, 'Power');
  end;
begin
  if AccountChangePending then
    raise EInvalidOperation.Create(UiText('Account change in progress. Please wait.'));
  inherited;
  LocalizeDesignedUi(Self);
  RiderWindSampler:=@WindVelocityAt;
  SceneLifecycleLog(Format('=== TViewPlay.Start BEGIN (old bike inst=$%p) ===',
    [Pointer(FBikeInstance)]));
  Enemies := TEnemyList.Create(true);
  FBotBikes := TList.Create;
  FBotAgents := TList.Create;
  FBotPoseManagers := TList.Create;

  { Маркер сборки — по нему в trainer_*.log видно, какая версия
    gameviewplay реально собрана. SNAP_SWAP помечен явно. }
  Logger.Info('[ViewPlay] ' + 'BUILD MARKER: gameviewplay rev=osm3d-8 '
    + 'SNAP_SWAP=OFF fit-stream');

  FOsmStreaming := nil;
  FDefaultSky:=MainViewport.Background;FCoastalSky:=nil;FCoastalSkyActive:=False;
  FDreamWorld:=FNextDreamWorld;FNextDreamWorld:=nil;FDreamVisual:=FNextDreamVisual;FNextDreamVisual:=nil;
  FOsmSnapApplied := False;
  { perf-тумблеры (MCP perf.set): по умолчанию всё включено — поведение
    игры не меняется; сбрасываем на каждый Start, чтобы прошлый замер
    не протекал в новый заезд }
  FPerfAnim := True;
  { Pooling bike meshes regenerates coordinates and smooth normals every
    frame, saving only a few draw calls. Keep their prepared geometry. }
  MainViewport.DynamicBatching := False;
  MainViewport.OcclusionCulling := Settings.GetOcclusionCulling;
  for I := 1 to ParamCount do
    if ParamStr(I) = '--no-occlusion' then
      MainViewport.OcclusionCulling := False;
  FPerfRiders := True;
  FPerfTerrain := True;
  FPerfShadows := Settings.GetGraphicsOption(Ord(goShadowSize)) <> 0;
  FLeanTestActive := False;
  FLeanTestPhase := 0;
  FLeanTestPeriodS := 4;
  FLeanTestLeanAmpDeg := 25;
  FLeanTestSteerAmpDeg := 30;
  FLeanTestLastLean := 0;
  FLeanTestLastSteer := 0;
  FChaseCamActive := False;   { MCP chase off each session — no extra cam work }
  { Path wobble off unless CLI re-enables below (must not leak from prior MCP). }
  PathTestWobbleConfigure(False);
  FOsmWidthsApplied := False;
  FGroundShadeTarget := 0;
  FGroundShadeAge := 0;
  FOsmPrepHold := False;            { взводится в ApplyCustomTerrainScene }
  FOsmPrepHoldLogTick := 0;
  FOsmPrepResumeAutoMove := False;
  FOsmPrepGroundSince := 0;
  FOsmPrepDiagUntil := 0;
  FOsmPrepDiagTick := 0;

  { Раннее: определить пути к данным выбранной карты и запустить
    стриминг по FIT до того, как любая логика трогает SceneLevel. }
  ResolveMapPaths;
  ApplyCustomTerrainScene;
  Logger.Info('[ViewPlay] ' + 'Start: после ApplyCustomTerrainScene, '
    + 'продолжаем стандартный Start...');

  { Init profiling log }
  FProfileLog := TStringList.Create;
  FProfileFrameNum := 0;
  FProfileLogFile := GetLogFileName;
  ProfileLogLine('=== Session started ===');

  { FREEZE-DIAG anchors — see TViewPlay.Update. Heart-beat is throttled
    relative to session start so the log reads as ms-since-Start. }
  FFreezeDiagSessionStart  := GetTickCount64;
  FFreezeDiagLastHeartBeat := 0;
  Logger.Info('[FREEZE-DIAG] Session started — heart-beat anchor set');

  { Independent direct-to-disk diagnostic file. Logger.Info buffers
    (we saw 100+ lines arriving as a single burst in trainer.log),
    which makes the moment of a crash invisible — the in-memory buffer
    dies with the process. FreezeDiagLog flushes after every line, so
    the last line we see in freeze_direct_*.log is genuinely the last
    thing the process did. File is written next to the executable. }
  FreezeDiagInit(ExtractFilePath(ParamStr(0)));
  FreezeDiagWrite('TViewPlay.Start: session begun');
  { Start the watchdog AFTER init. Watchdog writes a tick every 200 ms
    regardless of main thread state. If watchdog tics continue but
    main-thread heart-beat goes silent, main thread is deadlocked /
    stuck in native code. If even watchdog stops, the whole process
    was killed (TaskManager, native crash, signal). This is the final
    arbiter between "stalled" and "killed". }
  FreezeDiagStartWatchdog(200);

  { Режимы FPS по V (как в студии) + CLI --uncapped для автозамеров. }
  if CliUncapped then
  begin
    GFpsMode := flmVsyncOffMax;
    ApplyGameFpsMode;
    Logger.Info('[FPS] --uncapped: vsync off, без лимита FPS');
  end;
  { FPS-бисекция: --noshadow / --nolabels / --nofx / --shadowframe / --cpuprof / --nosteer. }
  GCliNoLabels := CliFlag('nolabels');
  BikeShadowFrameOnly := CliFlag('shadowframe');
  BikeShadowNoWheels := CliFlag('shadowfew');
  if CliFlag('nosteer') then
  begin
    BikeDebugDisableSteer := True;
    Logger.Info('[FPS] --nosteer: FULL steer off (no SteerRot build, no lean/point)');
  end;
  if CliFlag('steer') then
  begin
    BikeDebugDisableSteer := False;
    Logger.Info('[FPS] --steer: steer ON (SteerRot + path + pedal lean/grips)');
  end;
  { Test: periodic carrot L/R sway so lean+bars are obvious.
    --path-wobble  |  --path-wobble=2.5  (meters each side, period 8 s)
    --no-path-wobble disables. Live toggle: MCP path.wobble. }
  if CliFlag('no-path-wobble') or CliFlag('nopathwobble') then
  begin
    PathTestWobbleConfigure(False);
    Logger.Info('[PATH] --no-path-wobble: test lateral sway OFF');
  end
  else if CliFlag('path-wobble') or CliFlag('pathwobble') then
  begin
    PathTestWobbleConfigure(True, 2.0, 8.0);
    Logger.Info(Format(
      '[PATH] --path-wobble: ±%.1f m @ %.1f s (periodic carrot L/R)',
      [PathTestWobbleGetAmplitudeM, PathTestWobbleGetPeriodS]));
  end
  else
  begin
    for I := 1 to ParamCount do
      if Copy(ParamStr(I), 1, 14) = '--path-wobble=' then
      begin
        PathTestWobbleConfigure(True,
          StrToFloatDef(StringReplace(Copy(ParamStr(I), 15, MaxInt), '.',
            DefaultFormatSettings.DecimalSeparator, [rfReplaceAll]), 2.0),
          8.0);
        Logger.Info(Format(
          '[PATH] --path-wobble=±%.2f m @ %.1f s',
          [PathTestWobbleGetAmplitudeM, PathTestWobbleGetPeriodS]));
        Break;
      end;
  end;
  { ApplySnappedWidths purpose: camera (default) vs bridge (XZ pull).
    --road-pull / --bridge-path  → aspBridge at ApplySnapWidthsAndLanes
    --no-road-pull / --camera-path → aspCamera (default)
    --no-findpath-fullscan / --findpath-fullscan }
  begin
    if CliFlag('no-road-pull') or CliFlag('noroadpull')
       or CliFlag('camera-path') or CliFlag('camerapath') then
      PathBisectConfigure(False, PathFindFullRescanEnabled)
    else if CliFlag('road-pull') or CliFlag('roadpull')
       or CliFlag('bridge-path') or CliFlag('bridgepath') then
      PathBisectConfigure(True, PathFindFullRescanEnabled);
    if CliFlag('no-findpath-fullscan') or CliFlag('nofindpathfullscan') then
      PathBisectConfigure(PathRoadPriorityPullEnabled, False)
    else if CliFlag('findpath-fullscan') or CliFlag('findpathfullscan') then
      PathBisectConfigure(PathRoadPriorityPullEnabled, True);
    Logger.Info('[PATH] ApplySnapped purpose flags ' + PathBisectFlagsJSON);
  end;
  { WheelEcc off by default (BikeDebugDisableWheelEcc=True). Opt-in: --wheelecc }
  if CliFlag('wheelecc') then
  begin
    BikeDebugDisableWheelEcc := False;
    Logger.Info('[FPS] --wheelecc: WheelEcc correction ON (GPU PLUG + CPU T)');
  end;
  if CliFlag('nowheelecc') then
  begin
    BikeDebugDisableWheelEcc := True;
    Logger.Info('[FPS] --nowheelecc: WheelEcc OFF');
  end;
  if CliFlag('nolightsun') then
  begin
    BikeShadowSunGlobal := False;
    Logger.Info('[FPS] --nolightsun: BikeShadowSun не Global');
  end;
  if CliFlag('cpuprof') then
  begin
    GpuFrameProfilingEnabled := True;
    GlobalCpuProfiler.SetEnabled(True);
    InsertFront(TProfiledSceneTick.Create(FreeAtStop));   { GPU frame timer + счётчики;
      owner=FreeAtStop (раньше — Self): иначе каждый Start добавлял ЕЩЁ один
      тик в UI view'а, и GPU-таймеры дублировались с каждым заездом. }
    Logger.Info('[FPS] --cpuprof: CPU/GPU profiler включён (сводка в osm3d-лог)');
  end;
  if CliFlag('nofx') and Assigned(FScreenFX) then
  begin
    FScreenFX.Enabled := False;
    Logger.Info('[FPS] --nofx: ScreenFX выключен');
  end;

  { FPS-бисекция физики агентов: --nocontrol / --nosteps / --noground. }
  AgentCliNoControl := CliFlag('nocontrol');
  AgentCliNoSteps   := CliFlag('nosteps');
  AgentCliNoGround  := CliFlag('noground');
  if AgentCliNoControl or AgentCliNoSteps or AgentCliNoGround then
    Logger.Info(Format('[FPS] physics bisect: nocontrol=%s nosteps=%s noground=%s',
      [BoolToStr(AgentCliNoControl, True), BoolToStr(AgentCliNoSteps, True),
       BoolToStr(AgentCliNoGround, True)]));

  { ── Camera controller ── }
  FCamera := TCameraController.Create;
  FCamera.Setup(
    ThirdPersonNavigation,
    AvatarTransform,
    FreeAtStop,
    CheckboxCameraFollows, CheckboxAimAvatar,
    CheckboxDebugAvatarColliders, CheckboxImmediatelyFixBlockedCamera,
    SliderAirRotationControl, SliderAirMovementControl,
    ButtonChangeTransformationAuto, ButtonChangeTransformationDirect,
    ButtonChangeTransformationVelocity, ButtonChangeTransformationForce
  );

  { ── BLE HUD updater ── }
  FBLEHud := TBLEHudUpdater.Create;
  FBLEHud.Reset;
  if FWorkoutHud=nil then begin
    FWorkoutHud:=TWorkoutHud.Create(FreeAtStop);FWorkoutHud.OnFinishRide:=@ClickFinishWorkoutRide;
    InsertFront(FWorkoutHud);
  end;
  FFocusMode:=False;
  FFocusPanel:=TTrainingFocusPanel.Create(FreeAtStop);FFocusPanel.Exists:=False;InsertBack(FFocusPanel);
  FKeyboard:=TUiKeyboardNavigation.Create(FreeAtStop);FKeyboard.Exists:=False;InsertFront(FKeyboard);
  BeginActivityRecord;
  Labels.LabelSpeed := LabelSpeed;
  Labels.LabelPower := LabelPower;
  Labels.LabelCorr := LabelCorr;
  Labels.LabelCadence := LabelCadence;
  Labels.LabelHeart := LabelHeart;
  Labels.LabelSlope := LabelSlope;
  Labels.LabelPitch := LabelPitch;
  Labels.LabelInfo := LabelInfo;
  Labels.LabelRecordingStatus:=TCastleLabel.Create(FreeAtStop);
  Labels.LabelRecordingStatus.FontSize:=16;Labels.LabelRecordingStatus.Color:=Vector4(1,0.62,0.22,1);
  Labels.LabelRecordingStatus.Anchor(hpLeft,20);Labels.LabelRecordingStatus.Anchor(vpTop,-160);
  Labels.LabelRecordingStatus.MaxWidth:=700;Labels.LabelRecordingStatus.Exists:=False;
  InsertFront(Labels.LabelRecordingStatus);
  PrepareHudLayout;
  Labels.WheelPower:=AddZoneWheel(LabelPower,'PowerZoneWheel');
  Labels.WheelCadence:=AddZoneWheel(LabelCadence,'CadenceZoneWheel');
  Labels.WheelHeart:=AddZoneWheel(LabelHeart,'HeartZoneWheel');
  Labels.LabelWork:=LabelWork;
  Labels.LabelWorkTSS:=LabelWorkTSS;
  LabelWork.Caption:='0.0';
  FBLEHud.SetLabels(Labels);

  { ── Rider list panel — scrollable card list ── }
  FHasOtherRiders := False;
  FAdminLayoutValid := False;
  if Assigned(VerticalGroup1) then
  begin
    VerticalGroup1.AutoSizeHeight := True;
    VerticalGroup1.HorizontalAnchorParent := hpRight;
    VerticalGroup1.HorizontalAnchorSelf := hpRight;
    VerticalGroup1.Translation := Vector2(-10, -210);

    FRiderScroll := TCastleScrollView.Create(FreeAtStop);
    FRiderScroll.Exists := False;
    FRiderScroll.Width := 270;
    FRiderScroll.Height := 600;
    FRiderScroll.ScrollBarWidth := 8;
    FRiderScroll.EnableDragging := True;
    VerticalGroup1.InsertFront(FRiderScroll);

    FRiderInner := TCastleVerticalGroup.Create(FreeAtStop);
    FRiderInner.Spacing := 3;
    FRiderInner.Padding := 2;
    FRiderScroll.ScrollArea.InsertFront(FRiderInner);
  end;

  Logger.Info('[ViewPlay] ' + '========== START: Loading models ==========');

  { Log SceneAvatar state from design file BEFORE any programmatic loading }
  if Assigned(SceneAvatar) then
  begin
    Logger.Info('[ViewPlay] ' + Format('SceneAvatar BEFORE load: Name="%s" Url="%s" RootNode=$%p Exists=%s',
      [SceneAvatar.Name, SceneAvatar.Url, Pointer(SceneAvatar.RootNode),
       BoolToStr(SceneAvatar.Exists, True)]));
    if not SceneAvatar.BoundingBox.IsEmpty then
      Logger.Info('[ViewPlay] ' + Format('SceneAvatar BEFORE BBox: (%.3f,%.3f,%.3f)-(%.3f,%.3f,%.3f)',
        [SceneAvatar.BoundingBox.Data[0].X, SceneAvatar.BoundingBox.Data[0].Y, SceneAvatar.BoundingBox.Data[0].Z,
         SceneAvatar.BoundingBox.Data[1].X, SceneAvatar.BoundingBox.Data[1].Y, SceneAvatar.BoundingBox.Data[1].Z]))
    else
      Logger.Info('[ViewPlay] ' + 'SceneAvatar BEFORE BBox: EMPTY (ok, not loaded yet)');
  end
  else
    Logger.Info('[ViewPlay] ' + 'WARNING: SceneAvatar is nil!');

  { Load parametric bike+rider as TBikeInstance with 4 LOD levels }
  if Assigned(AvatarTransform) and Assigned(SceneAvatar) then
  begin
    Logger.Info('[ViewPlay] ' + 'Loading AVATAR with LOD (BikeFit selection)');
    try
      { Байкфит: SelectedBikeJson + SelectedRiderGlb из AppSettings }
      FBikeInstance := LoadActiveBikeInstance(FreeAtStop);
    except
      on E: Exception do
      begin
        Logger.Info('[BikeAvatar] ' + 'Failed to load bike instance: ' + E.Message);
        Logger.Info('[ViewPlay] ' + 'Falling back to single-scene load');
        try
          LoadBikeAvatarFromJSON(ResolveActiveBikeJsonUrl, SceneAvatar);
        except
          on E2: Exception do
            Logger.Info('[BikeAvatar] ' + 'Fallback also failed: ' + E2.Message);
        end;
      end;
    end;
    { Пост-настройка уже загруженного инстанса — ОТДЕЛЬНЫЙ try, без фолбэка:
      исключение здесь (тень/пробы/позы) не должно запускать легаси-загрузку —
      она грузила ВТОРОЙ байк поверх живого (баг «удвоенный велосипед
      после стоп→ехать»: легаси-путь — π-разворот и без райдера). }
    if Assigned(FBikeInstance) then
    try
      SceneAvatar.Load(nil, True);
      SceneAvatar.Add(FBikeInstance.Group);
      SceneLifecycleLog(Format(
        'VIEWPLAY avatar loaded: inst=$%p group=$%p sceneavatar=$%p kids=%d',
        [Pointer(FBikeInstance), Pointer(FBikeInstance.Group),
         Pointer(SceneAvatar), SceneAvatar.Count]));
      Logger.Info('[ViewPlay] ' + 'TBikeInstance loaded OK, 4 LOD sub-scenes active');

      { Колёсные пробы физики — по реальным осям байка, а не по bbox сцены:
        bbox включает теневой catcher/rig, и пробы улетали на метры вперёд/
        назад от колёс (эффект «подвески» и провалы под текстуру дороги). }
      if Assigned(FOfflineAvatar) and Assigned(FOfflineAvatar.Physics) then
        FOfflineAvatar.Physics.SetWheelProbeHalfSpan(FBikeInstance.AxleHalfSpanM);
      ApplyWheelProbeFromBike;

      { Общее солнце сессии -> контактная тень аватара. Стриминговая карта
        уже запущена выше (ApplyCustomTerrainScene), её солнце и теневые
        маски считаются из того же route start UTC. }
      ApplyWorldSunToBikeShadow(FBikeInstance);

      { ДИАГ-флаги ДО ShadowMode: EnsureShadowMapLight (создание catcher'а)
        читает BikeShadowCatcherBlend в момент SetShadowMode — после
        назначения режима флаг уже не действовал. }
      ParseShadowLiftCli;
      if CliFlag('catchwhite') then
      begin
        BikeShadowCatcherBlend := False;
        Logger.Info('[DIAG] --catchwhite: catcher белый opaque');
      end;

      { The rig generates the depth map. UpdateGroundRiderShadow samples it
        on the streamed ground and hides the transparent receiver there. }
      FBikeInstance.ShowShadow := True;
      if UseSharedRiderShadows then FBikeInstance.ShadowMode := bsmNone
      else FBikeInstance.ShadowMode := bsmCGE;
      { теневое солнце должно перебивать глобальное солнце карты на catcher'е,
        иначе тень размывается до невидимости. С Global=False (дефолт после
        фикса мульти-солнц) 30.0 светит ТОЛЬКО на catcher — пересвета байка/
        райдера больше нет, а контраст тени максимален. }
      FBikeInstance.ShadowSunIntensity := 30.0;
      if CliFlag('noshadow') then
      begin
        FBikeInstance.ShadowMode := bsmNone;
        Logger.Info('[FPS] --noshadow: байк без движковой тени');
      end;
      if CliFlag('capsules') then
      begin
        FBikeInstance.ShadowMode := bsmCapsules;
        Logger.Info('[FPS] --capsules: байк на капсульной тени (бот остаётся bsmCGE)');
      end;
      if CliFlag('novolshadow') then
      begin
        FBikeInstance.EngineShadowVolumes := False;
        Logger.Info('[FPS] --novolshadow: свет+catcher есть, volume-проход выключен');
      end;

      FPoseManager := TRiderPoseManager.Create(FBikeInstance);
      Logger.Info(Format('[ViewPlay] Compiled rider catalog: %d poses', [FPoseManager.PoseCount]));
      if Settings.FitParamsValid then
      begin
        FPoseManager.OverlayKneeAnkle(Settings.FitKneeFlare, Settings.FitAnkleFlex);
        ApplyFitKneeAnkle(FBikeInstance,
          Settings.FitKneeFlare, Settings.FitAnkleFlex);
        Logger.Info(Format('[ViewPlay] Pose overlay knee=%.2f ankle=%.0f',
          [Settings.FitKneeFlare, Settings.FitAnkleFlex]));
      end;
      Logger.Info('[ViewPlay] ' + FPoseManager.DumpPoses);
    except
      on E: Exception do
        Logger.Info('[ViewPlay] ' + 'Post-load bike setup failed (инстанс живой, едем дальше): '
          + E.ClassName + ': ' + E.Message);
    end;
  end;

  if Assigned(SceneAvatar) then
  begin
    SceneAvatar.Pickable := false;
    SceneAvatar.Collides := false;
  end;

  if Assigned(AvatarTransform) then
  begin
    AvatarTransform.Pickable := false;
    AvatarTransform.Collides := false;
  end;

  if Assigned(AvatarRigidBody) then
    AvatarRigidBody.Exists := false;

  FCamera.InitDefaults;

  FMenuButton := TMenuButton.Create(FreeAtStop);
  FMenuButton.Name:='RideMenu';
  BindUiText(FMenuButton, 'Menu  Esc');
  FMenuButton.AutoSize := False;
  FMenuButton.Width := 136;
  FMenuButton.Height := 44;
  FMenuButton.Anchor(hpLeft, 12);
  FMenuButton.Anchor(vpTop, -278);
  FMenuButton.OnClick := @ClickMenu;
  InsertFront(FMenuButton);
  FFocusButton:=TMenuButton.Create(FreeAtStop);BindUiText(FFocusButton,'Training focus');
  FFocusButton.Name:='RideTrainingFocus';
  FFocusButton.AutoSize:=False;FFocusButton.Width:=180;FFocusButton.Height:=44;FFocusButton.FontSize:=15;
  FFocusButton.Anchor(hpLeft,160);FFocusButton.Anchor(vpTop,-278);
  FFocusButton.OnClick:=@ClickTrainingFocus;InsertFront(FFocusButton);

  ActivateOfflineMode;

  if Assigned(SceneAvatar) then
  begin
    Logger.Info('[ViewPlay] ' + Format('SceneAvatar AFTER ActivateOfflineMode: Url="%s" RootNode=$%p',
      [SceneAvatar.Url, Pointer(SceneAvatar.RootNode)]));
    if not SceneAvatar.BoundingBox.IsEmpty then
      Logger.Info('[ViewPlay] ' + Format('SceneAvatar post-Activate BBox: (%.3f,%.3f,%.3f)-(%.3f,%.3f,%.3f)',
        [SceneAvatar.BoundingBox.Data[0].X, SceneAvatar.BoundingBox.Data[0].Y, SceneAvatar.BoundingBox.Data[0].Z,
         SceneAvatar.BoundingBox.Data[1].X, SceneAvatar.BoundingBox.Data[1].Y, SceneAvatar.BoundingBox.Data[1].Z]));
  end;
  Logger.Info('[ViewPlay] ' + '========== START: Model loading complete ==========');

  { Dark background for FPS/profiler label. Раньше было только при /log —
    оверлей «пропадал» у всех, кто запускает игру без флага; теперь
    виден всегда (тяжёлый профильный лог по-прежнему под /log). }
  if Assigned(LabelFps) and Assigned(LabelFps.Parent) then
  begin
    LabelFps.Exists := True;
    begin
      FFpsBgRect := TCastleRectangleControl.Create(FreeAtStop);
      FFpsBgRect.Color := Vector4(0, 0, 0, 0.70);
      FFpsBgRect.FullSize := false;
      FFpsBgRect.Width := 480;
      FFpsBgRect.Height := 110;
      FFpsBgRect.HorizontalAnchorParent := hpRight;
      FFpsBgRect.HorizontalAnchorSelf := hpRight;
      FFpsBgRect.VerticalAnchorParent := vpTop;
      FFpsBgRect.VerticalAnchorSelf := vpTop;
      FFpsBgRect.Translation := Vector2(-10, -130);
      LabelFps.Parent.InsertBack(FFpsBgRect);
      LabelFps.FontSize := 14;
      LabelFps.Anchor(hpRight, -18);
      LabelFps.Anchor(vpTop, -138);
    end;
  end;

  { ── Bot debug panel (top-left, /log only) ── }
  if GLogEnabled then
  begin
    FBotPanel := TCastleRectangleControl.Create(FreeAtStop);
    FBotPanel.Color := Vector4(0, 0, 0, 0.70);
    FBotPanel.FullSize := false;
    FBotPanel.Width := 190;
    FBotPanel.Height := 76;   { только бот-ряд; FX-тумблеры переехали в FFxPanel }
    FBotPanel.HorizontalAnchorParent := hpLeft;
    FBotPanel.HorizontalAnchorSelf := hpLeft;
    FBotPanel.VerticalAnchorParent := vpTop;
    FBotPanel.VerticalAnchorSelf := vpTop;
    FBotPanel.Translation := Vector2(10, -10);

    FBotPanelLabel := TCastleLabel.Create(FreeAtStop);
    BindUiText(FBotPanelLabel, 'Server Bots');
    FBotPanelLabel.FontSize := 14;
    FBotPanelLabel.Color := Vector4(0.8, 0.9, 1.0, 1);
    FBotPanelLabel.Anchor(hpLeft, 10);
    FBotPanelLabel.Anchor(vpTop, -8);
    FBotPanel.InsertFront(FBotPanelLabel);

    FBotAddBtn := TMenuButton.Create(FreeAtStop);
    BindUiText(FBotAddBtn, '+ Bot');
    FBotAddBtn.FontSize := 13;
    FBotAddBtn.Width := 80;
    FBotAddBtn.Height := 30;
    FBotAddBtn.Anchor(hpLeft, 10);
    FBotAddBtn.Anchor(vpTop, -36);
    FBotAddBtn.OnClick := {$ifdef FPC}@{$endif} OnBotAddClick;
    FBotPanel.InsertFront(FBotAddBtn);

    FBotRemoveBtn := TMenuButton.Create(FreeAtStop);
    BindUiText(FBotRemoveBtn, 'Clear All');
    FBotRemoveBtn.FontSize := 13;
    FBotRemoveBtn.Width := 80;
    FBotRemoveBtn.Height := 30;
    FBotRemoveBtn.Anchor(hpLeft, 100);
    FBotRemoveBtn.Anchor(vpTop, -36);
    FBotRemoveBtn.OnClick := {$ifdef FPC}@{$endif} OnBotRemoveClick;
    FBotPanel.InsertFront(FBotRemoveBtn);

    InsertFront(FBotPanel);
  end;

  { ── FX/perf-оверлей: левый верхний угол, виден ВСЕГДА (не зависит от /log).
    Раньше FX-тумблеры жили внутри FBotPanel и пропадали без флага /log.
    Ряды 1-2 — screen effects (состояние в TScreenFX), ряд 3 — perf-тумблеры
    (земля/райдер/анимация/тень, состояние в FPerf*; те же переключатели, что и
    MCP perf.set). Цвет подписи: зелёный = вкл, серый = выкл. ── }
  FFxPanel := TCastleRectangleControl.Create(FreeAtStop);
  FFxPanel.Color := Vector4(0, 0, 0, 0.70);
  FFxPanel.FullSize := false;
  FFxPanel.Width := 248;
  FFxPanel.Height := 150;   { FX, perf, world shadows, road and culling }
  FFxPanel.HorizontalAnchorParent := hpLeft;
  FFxPanel.HorizontalAnchorSelf := hpLeft;
  FFxPanel.VerticalAnchorParent := vpTop;
  FFxPanel.VerticalAnchorSelf := vpTop;
  if Assigned(FBotPanel) then
    FFxPanel.Translation := Vector2(10, -94)   { под бот-панелью }
  else
    FFxPanel.Translation := Vector2(10, -10);

  FFxBtnFog := TMenuButton.Create(FreeAtStop);
  FFxBtnFog.AutoSize := False;
  FFxBtnFog.PaddingHorizontal := 3;
  FFxBtnFog.PaddingVertical := 2;
  TMenuButton(FFxBtnFog).AutoIcon := False;
  BindUiText(FFxBtnFog, 'Fog');
  FFxBtnFog.FontSize := 11;
  FFxBtnFog.Width := 54; FFxBtnFog.Height := 22;
  FFxBtnFog.CustomTextColorUse := true;   { цвет = индикатор вкл/выкл }
  FFxBtnFog.CustomTextColor := Vector4(0.35, 1.0, 0.45, 1);
  FFxBtnFog.Anchor(hpLeft, 10); FFxBtnFog.Anchor(vpTop, -10);
  FFxBtnFog.OnClick := {$ifdef FPC}@{$endif} OnFxToggleClick;
  FFxPanel.InsertFront(FFxBtnFog);

  FFxBtnBloom := TMenuButton.Create(FreeAtStop);
  FFxBtnBloom.AutoSize := False;
  FFxBtnBloom.PaddingHorizontal := 3;
  FFxBtnBloom.PaddingVertical := 2;
  TMenuButton(FFxBtnBloom).AutoIcon := False;
  BindUiText(FFxBtnBloom, 'Blum');
  FFxBtnBloom.FontSize := 11;
  FFxBtnBloom.Width := 54; FFxBtnBloom.Height := 22;
  FFxBtnBloom.CustomTextColorUse := true;   { цвет = индикатор вкл/выкл }
  FFxBtnBloom.CustomTextColor := Vector4(0.35, 1.0, 0.45, 1);
  FFxBtnBloom.Anchor(hpLeft, 68); FFxBtnBloom.Anchor(vpTop, -10);
  FFxBtnBloom.OnClick := {$ifdef FPC}@{$endif} OnFxToggleClick;
  FFxPanel.InsertFront(FFxBtnBloom);

  FFxBtnTone := TMenuButton.Create(FreeAtStop);
  FFxBtnTone.AutoSize := False;
  FFxBtnTone.PaddingHorizontal := 3;
  FFxBtnTone.PaddingVertical := 2;
  TMenuButton(FFxBtnTone).AutoIcon := False;
  BindUiText(FFxBtnTone, 'Tone');
  FFxBtnTone.FontSize := 11;
  FFxBtnTone.Width := 54; FFxBtnTone.Height := 22;
  FFxBtnTone.CustomTextColorUse := true;   { цвет = индикатор вкл/выкл }
  FFxBtnTone.CustomTextColor := Vector4(0.35, 1.0, 0.45, 1);
  FFxBtnTone.Anchor(hpLeft, 126); FFxBtnTone.Anchor(vpTop, -10);
  FFxBtnTone.OnClick := {$ifdef FPC}@{$endif} OnFxToggleClick;
  FFxPanel.InsertFront(FFxBtnTone);

  FFxBtnPoster := TMenuButton.Create(FreeAtStop);
  FFxBtnPoster.AutoSize := False;
  FFxBtnPoster.PaddingHorizontal := 3;
  FFxBtnPoster.PaddingVertical := 2;
  TMenuButton(FFxBtnPoster).AutoIcon := False;
  BindUiText(FFxBtnPoster, 'Pstr');
  FFxBtnPoster.FontSize := 11;
  FFxBtnPoster.Width := 54; FFxBtnPoster.Height := 22;
  FFxBtnPoster.CustomTextColorUse := true;   { цвет = индикатор вкл/выкл }
  FFxBtnPoster.CustomTextColor := Vector4(0.55, 0.55, 0.55, 1);
  FFxBtnPoster.Anchor(hpLeft, 10); FFxBtnPoster.Anchor(vpTop, -36);
  FFxBtnPoster.OnClick := {$ifdef FPC}@{$endif} OnFxToggleClick;
  FFxPanel.InsertFront(FFxBtnPoster);

  FFxBtnKuwa := TMenuButton.Create(FreeAtStop);
  FFxBtnKuwa.AutoSize := False;
  FFxBtnKuwa.PaddingHorizontal := 3;
  FFxBtnKuwa.PaddingVertical := 2;
  TMenuButton(FFxBtnKuwa).AutoIcon := False;
  BindUiText(FFxBtnKuwa, 'Kuwa');
  FFxBtnKuwa.FontSize := 11;
  FFxBtnKuwa.Width := 54; FFxBtnKuwa.Height := 22;
  FFxBtnKuwa.CustomTextColorUse := true;   { цвет = индикатор вкл/выкл }
  FFxBtnKuwa.CustomTextColor := Vector4(0.55, 0.55, 0.55, 1);
  FFxBtnKuwa.Anchor(hpLeft, 68); FFxBtnKuwa.Anchor(vpTop, -36);
  FFxBtnKuwa.OnClick := {$ifdef FPC}@{$endif} OnFxToggleClick;
  FFxPanel.InsertFront(FFxBtnKuwa);

  FFxBtnHatch := TMenuButton.Create(FreeAtStop);
  FFxBtnHatch.AutoSize := False;
  FFxBtnHatch.PaddingHorizontal := 3;
  FFxBtnHatch.PaddingVertical := 2;
  TMenuButton(FFxBtnHatch).AutoIcon := False;
  BindUiText(FFxBtnHatch, 'Htch');
  FFxBtnHatch.FontSize := 11;
  FFxBtnHatch.Width := 54; FFxBtnHatch.Height := 22;
  FFxBtnHatch.CustomTextColorUse := true;   { цвет = индикатор вкл/выкл }
  FFxBtnHatch.CustomTextColor := Vector4(0.55, 0.55, 0.55, 1);
  FFxBtnHatch.Anchor(hpLeft, 126); FFxBtnHatch.Anchor(vpTop, -36);
  FFxBtnHatch.OnClick := {$ifdef FPC}@{$endif} OnFxToggleClick;
  FFxPanel.InsertFront(FFxBtnHatch);

  { ── ряд 3: perf-тумблеры (земля/райдер/анимация/тень) ── }
  FFxBtnTerr := TMenuButton.Create(FreeAtStop);
  FFxBtnTerr.AutoSize := False;
  FFxBtnTerr.PaddingHorizontal := 3;
  FFxBtnTerr.PaddingVertical := 2;
  TMenuButton(FFxBtnTerr).AutoIcon := False;
  BindUiText(FFxBtnTerr, 'Ground');
  FFxBtnTerr.FontSize := 11;
  FFxBtnTerr.Width := 54; FFxBtnTerr.Height := 22;
  FFxBtnTerr.CustomTextColorUse := true;
  FFxBtnTerr.CustomTextColor := Vector4(0.35, 1.0, 0.45, 1);
  FFxBtnTerr.Anchor(hpLeft, 10); FFxBtnTerr.Anchor(vpTop, -66);
  FFxBtnTerr.OnClick := {$ifdef FPC}@{$endif} OnFxToggleClick;
  FFxPanel.InsertFront(FFxBtnTerr);

  FFxBtnRidr := TMenuButton.Create(FreeAtStop);
  FFxBtnRidr.AutoSize := False;
  FFxBtnRidr.PaddingHorizontal := 3;
  FFxBtnRidr.PaddingVertical := 2;
  TMenuButton(FFxBtnRidr).AutoIcon := False;
  BindUiText(FFxBtnRidr, 'Rider');
  FFxBtnRidr.FontSize := 11;
  FFxBtnRidr.Width := 54; FFxBtnRidr.Height := 22;
  FFxBtnRidr.CustomTextColorUse := true;
  FFxBtnRidr.CustomTextColor := Vector4(0.35, 1.0, 0.45, 1);
  FFxBtnRidr.Anchor(hpLeft, 68); FFxBtnRidr.Anchor(vpTop, -66);
  FFxBtnRidr.OnClick := {$ifdef FPC}@{$endif} OnFxToggleClick;
  FFxPanel.InsertFront(FFxBtnRidr);

  FFxBtnAnim := TMenuButton.Create(FreeAtStop);
  FFxBtnAnim.AutoSize := False;
  FFxBtnAnim.PaddingHorizontal := 3;
  FFxBtnAnim.PaddingVertical := 2;
  TMenuButton(FFxBtnAnim).AutoIcon := False;
  BindUiText(FFxBtnAnim, 'Anim');
  FFxBtnAnim.FontSize := 11;
  FFxBtnAnim.Width := 54; FFxBtnAnim.Height := 22;
  FFxBtnAnim.CustomTextColorUse := true;
  FFxBtnAnim.CustomTextColor := Vector4(0.35, 1.0, 0.45, 1);
  FFxBtnAnim.Anchor(hpLeft, 126); FFxBtnAnim.Anchor(vpTop, -66);
  FFxBtnAnim.OnClick := {$ifdef FPC}@{$endif} OnFxToggleClick;
  FFxPanel.InsertFront(FFxBtnAnim);

  FFxBtnShad := TMenuButton.Create(FreeAtStop);
  FFxBtnShad.AutoSize := False;
  FFxBtnShad.PaddingHorizontal := 3;
  FFxBtnShad.PaddingVertical := 2;
  TMenuButton(FFxBtnShad).AutoIcon := False;
  BindUiText(FFxBtnShad, 'Shadow');
  FFxBtnShad.FontSize := 11;
  FFxBtnShad.Width := 54; FFxBtnShad.Height := 22;
  FFxBtnShad.CustomTextColorUse := true;
  FFxBtnShad.CustomTextColor := Vector4(0.35, 1.0, 0.45, 1);
  FFxBtnShad.Anchor(hpLeft, 184); FFxBtnShad.Anchor(vpTop, -66);
  FFxBtnShad.OnClick := {$ifdef FPC}@{$endif} OnFxToggleClick;
  FFxPanel.InsertFront(FFxBtnShad);

  { ── ряд 4: сферы FIT-пути (красные сырой / зелёные снап) ── }
  FFxBtnPath := TMenuButton.Create(FreeAtStop);
  FFxBtnPath.AutoSize := False;
  FFxBtnPath.PaddingHorizontal := 3;
  FFxBtnPath.PaddingVertical := 2;
  TMenuButton(FFxBtnPath).AutoIcon := False;
  BindUiText(FFxBtnPath, 'Path');
  FFxBtnPath.FontSize := 11;
  FFxBtnPath.Width := 54; FFxBtnPath.Height := 22;
  FFxBtnPath.CustomTextColorUse := true;
  FFxBtnPath.CustomTextColor := Vector4(0.55, 0.55, 0.55, 1); { off by default }
  FFxBtnPath.Anchor(hpLeft, 10); FFxBtnPath.Anchor(vpTop, -92);
  FFxBtnPath.OnClick := {$ifdef FPC}@{$endif} OnFxToggleClick;
  FFxPanel.InsertFront(FFxBtnPath);

  FFxBtnWorldShad := TMenuButton.Create(FreeAtStop);
  FFxBtnWorldShad.AutoSize := False;
  FFxBtnWorldShad.PaddingHorizontal := 3;
  FFxBtnWorldShad.PaddingVertical := 2;
  TMenuButton(FFxBtnWorldShad).AutoIcon := False;
  BindUiText(FFxBtnWorldShad, 'Dynamic world');
  FFxBtnWorldShad.FontSize := 11;
  FFxBtnWorldShad.Width := 112; FFxBtnWorldShad.Height := 22;
  FFxBtnWorldShad.CustomTextColorUse := True;
  FFxBtnWorldShad.Anchor(hpLeft, 68); FFxBtnWorldShad.Anchor(vpTop, -92);
  FFxBtnWorldShad.OnClick := @OnFxToggleClick;
  FFxPanel.InsertFront(FFxBtnWorldShad);
  FFxBtnRoad := TMenuButton.Create(FreeAtStop);
  FFxBtnRoad.AutoSize := False;
  FFxBtnRoad.PaddingHorizontal := 3;
  FFxBtnRoad.PaddingVertical := 2;
  TMenuButton(FFxBtnRoad).AutoIcon := False;
  BindUiText(FFxBtnRoad, 'Road cache');
  FFxBtnRoad.FontSize := 11;
  FFxBtnRoad.Width := 112; FFxBtnRoad.Height := 22;
  FFxBtnRoad.CustomTextColorUse := True;
  FFxBtnRoad.Anchor(hpLeft, 10); FFxBtnRoad.Anchor(vpTop, -118);
  FFxBtnRoad.OnClick := @OnFxToggleClick;
  FFxPanel.InsertFront(FFxBtnRoad);

  FFxBtnOcclusion := TMenuButton.Create(FreeAtStop);
  FFxBtnOcclusion.AutoSize := False;
  FFxBtnOcclusion.PaddingHorizontal := 3;
  FFxBtnOcclusion.PaddingVertical := 2;
  TMenuButton(FFxBtnOcclusion).AutoIcon := False;
  BindUiText(FFxBtnOcclusion, 'Culling');
  FFxBtnOcclusion.FontSize := 11;
  FFxBtnOcclusion.Width := 112; FFxBtnOcclusion.Height := 22;
  FFxBtnOcclusion.CustomTextColorUse := True;
  FFxBtnOcclusion.Anchor(hpLeft, 126); FFxBtnOcclusion.Anchor(vpTop, -118);
  FFxBtnOcclusion.OnClick := @OnFxToggleClick;
  FFxPanel.InsertFront(FFxBtnOcclusion);
  FFxPanel.Height := FFxPanel.Height + 26;
  FFxBtnTrees := TMenuButton.Create(FreeAtStop);
  FFxBtnTrees.AutoSize := False;
  FFxBtnTrees.PaddingHorizontal := 3;
  FFxBtnTrees.PaddingVertical := 2;
  TMenuButton(FFxBtnTrees).AutoIcon := False;
  FFxBtnTrees.FontSize := 11; FFxBtnTrees.Width := 112; FFxBtnTrees.Height := 22;
  FFxBtnTrees.CustomTextColorUse := True;
  FFxBtnTrees.Anchor(hpLeft, 10); FFxBtnTrees.Anchor(vpTop, -144);
  FFxBtnTrees.OnClick := @OnFxToggleClick; FFxPanel.InsertFront(FFxBtnTrees);
  FFxBtnTreeSeason := TMenuButton.Create(FreeAtStop);
  FFxBtnTreeSeason.AutoSize := False;
  FFxBtnTreeSeason.PaddingHorizontal := 3;
  FFxBtnTreeSeason.PaddingVertical := 2;
  TMenuButton(FFxBtnTreeSeason).AutoIcon := False;
  FFxBtnTreeSeason.FontSize := 11; FFxBtnTreeSeason.Width := 112; FFxBtnTreeSeason.Height := 22;
  FFxBtnTreeSeason.CustomTextColorUse := True;
  FFxBtnTreeSeason.Anchor(hpLeft, 126); FFxBtnTreeSeason.Anchor(vpTop, -144);
  FFxBtnTreeSeason.OnClick := @OnFxToggleClick; FFxPanel.InsertFront(FFxBtnTreeSeason);

  InsertFront(FFxPanel);

  { ── Remote riders manager ── }
  FRemoteRiders := TRemoteRidersManager.Create(FreeAtStop);
  FRemoteRiders.OnProfileLog := {$ifdef FPC}@{$endif} ProfileLogLine;
  FRemoteRiders.Setup(
    MainViewport,
    SceneLevel,
    AvatarTransform,
    FOfflineAvatar.Path
  );
  FRemoteRiders.InitPathCumDist;

  { Общее солнце сессии для теней удалённых райдеров — применится и к уже
    построенным, и к каждому построенному позже. }
  if Assigned(FOsmStreaming) and FOsmStreaming.Active
     and FOsmStreaming.SunWorldDir(WorldSun) then
    FRemoteRiders.SetShadowSunWorld(WorldSun);

  { Массовка — капсульные тени: bsmCGE создавал бы отдельный теневой
    источник (и теневой проход) на КАЖДОГО райдера. Капсулы дают силуэт
    за ~60 юниформов на байк. }
  if UseSharedRiderShadows then FRemoteRiders.SetShadowMode(bsmNone)
  else FRemoteRiders.SetShadowMode(bsmCGE);
  //FRemoteRiders.SetShadowMode(bsmCapsules);

  { ── Apply PBR terrain texture ──
    Для стриминга (выбран FIT) пропускаем: террейн стримится из Osm3d.
    Для дефолтной карты — ApplyTerrainTexture по дизайновому SceneLevel. }
  if (FCurrentFitPath = '')and(FDreamWorld=nil) then
    ApplyTerrainTexture
  else
    Logger.Info('[ViewPlay] ' + 'StreamingMap: ApplyTerrainTexture пропущен (террейн стримится)');

  { ── Preload terrain texture variants for ' \ cycling ──
    Для стриминга пропускаем: переключение текстур террейна к тайлам
    Osm3d не применяется. }
  if (FCurrentFitPath = '')and(FDreamWorld=nil) then
  begin
    ScanTerrainTextureFolders;
    PreloadTerrainTextures;
  end
  else
    Logger.Info('[ViewPlay] ' + 'StreamingMap: PreloadTerrainTextures пропущен');

  FRoomStartApplied:=False;ConnectRideRoom;
  if Assigned(FRemoteRiders.RideClient) then
    FRemoteRiders.RideClient.OnRiderCountChanged := @RiderCountChanged;

  { ── Lane manager — shared by all riders ── }
  FLaneManager := TLaneManager.Create;
  if FDreamWorld<>nil then
    FLaneManager.SetRoad(FDreamWorld.Width, FRemoteRiders.PathTotalLength)
  else
    FLaneManager.SetRoad(8.0, FRemoteRiders.PathTotalLength);
  FLocalLaneHandle := FLaneManager.RegisterRider(FActiveAvatarAgent);
  FRemoteRiders.SetLaneManager(FLaneManager, FLocalLaneHandle);

  ArrangeLocalRidersAtStart;

  { ── Cinematic camera ── }
  FCinematicCam := TCinematicCamera.Create;
  FCinematicCam.Setup(MainViewport, AvatarTransform, FOfflineAvatar.Path);
  FCinematicCam.Enabled := True;   { start in AUTO (cinematic) mode; C cycles the ring }
  if Assigned(FOsmStreaming) and FOsmStreaming.Active then
    FCinematicCam.GroundQuery :=
      {$ifdef FPC}@{$endif} FOsmStreaming.GroundNearYAt;

  { ── Free-fly camera (третий режим в кольце клавиши C) ── }
  FFreeCam := TFreeCameraController.Create;
  FFreeCam.Camera := MainViewport.Camera;
  if FDreamWorld<>nil then FCinematicCam.GroundQuery:=@FDreamWorld.GroundNearYAt;
  FCameraMode := pcmCinematic;     { стартуем в кинематик-режиме }
  FChaseCamActive := False;
  FChaseDist := 3.0;
  FChaseHeight := 1.3;
  FChaseSide := 0;
  FChaseAimHeight := 0.85;

  { ── Screen post-processing: bloom + filmic tonemap ──
    Включено по умолчанию; B переключает для сравнения "до/после".
    Настройки (порог/сила блума, экспозиция) — свойства FScreenFX. }
  FScreenFX := TScreenFX.Create(MainViewport);
  FScreenFX.Enabled:=False;

  { Настройки тумана — из общего файла, который пишут поля в студии
    (Osm3dStudioMainForm/FogEditChange). Студия и игра не разделяют память,
    только диск. 0/файла нет → ничего не меняем, FScreenFX.Enabled остаётся
    False как строкой выше — прежнее поведение «весь FX выключен, пока
    игрок не нажмёт кнопку/клавишу». >0 → врубаем ВЕСЬ пост-пайплайн
    (Enabled — общий выключатель на bloom+tone+fog, раздельно их не
    развести без правки GameScreenFX): FogEnabled уже True по умолчанию
    в TScreenFX, тут переопределяем дальность, чистую зону и общий Enabled. }
  LoadFogSettings(FogDistM, FogClearM);
  if FogDistM > 0 then
  begin
    FScreenFX.FogRange     := FogDistM;
    FScreenFX.FogClearZone := FogClearM;
    FScreenFX.Enabled      := True;
    Logger.Info(Format('[ViewPlay] fog: %.0f m, чистая зона %.0f m (из %s)',
      [FogDistM, FogClearM, FogConfigPath]));
  end;

  ApplyShadowSettings;
  UpdateFxButtonColors;   { раскрасить FX-кнопки панели по фактическому состоянию }

  if FRemoteRiders.RideClient<>nil then
    ProfileLogLine('RELAY started, rider_id=' + IntToStr(FRemoteRiders.RideClient.LocalRiderId));

  if Assigned(SliderPower) and HasActiveState then
  begin
    SliderPower.Min := MinPower;
    SliderPower.Max := MaxPower;
    SliderPower.Value := FActiveAvatarAgent.State.AppliedPowerWatts;
    SliderPower.OnChange := {$ifdef FPC}@{$endif} ChangePower;
  end;

  { Если включён dev-режим симуляции — стартуем проигрывание FIT
    только сейчас (после полной инициализации игры), чтобы данные не
    шли пока юзер ещё в меню. См. TGameDeviceService.StartSimPlayback. }
  if Assigned(DeviceService) then
  begin
    if FCurrentFitPath <> '' then Settings.SetSelectedRoutePath(FCurrentFitPath);
    DeviceService.StartSimPlayback;
    { Симулятор стартует на паузе — игрок сам нажимает Play в виджете.
      Также включаем AutoMove чтобы не пришлось жать P отдельно: при
      реальной мощности из FIT-файла авто-движение должно идти.
      Обнуляем начальную мощность: иначе агент стартует с DefaultPower
      (200 Вт из gamephysicscommon) и едет до того как FIT пришлёт
      первый feed. Когда юзер нажмёт Play — FIT перезапишет. }
    if DeviceService.IsSimulationActive then
    begin
      DeviceService.SimRestart;
      DeviceService.SimSetPaused(True);
      { Мощность только из канала датчиков, как у живого тренажёра.
        AutoMove включится, когда FIT пришлёт ватты (sim.play).
        Иначе DefaultPower (200 Вт) трогает аватар до первого пакета. }
      if Assigned(FActivePlayerController) then
        FActivePlayerController.SetDesiredPower(0);
      if HasActiveState then
        FActiveAvatarAgent.State.AppliedPowerWatts := 0;
    end;
  end;

  { In-game плеер для симуляции: создаётся всегда, но виден только
    когда есть активная sim-сессия. }
  FSimHistory:=TSimReplayHistory.Create;
  DeviceService.OnSimSeek:=@RestoreSimCheckpoint;
  FSimLoopSerial:=DeviceService.SimLoopSerial;
  FSimAccountedUntil:=0;
  BuildSimPlayer;
  UpdateAdminPanels;

  { MCP: мир/велосипед/стриминг/камера созданы — публикуем их как
    объекты 'world'/'bike'/'osm'/'camera'. No-op без --mcp-stdio. }
  McpRegisterPlayObjects;
  SceneLifecycleLog('=== TViewPlay.Start END ===');
end;

procedure TViewPlay.Stop;
var
  I: Integer;
begin
  if FFocusMode then SetTrainingFocus(False);
  FFocusPanel:=nil;FFocusButton:=nil;FKeyboard:=nil;
  MotionTrace.Stop;
  if Assigned(DeviceService) then DeviceService.OnSimSeek:=nil;
  ClearSimReplay;
  FreeAndNil(FSimHistory);
  FCameraDragging:=False;
  if Assigned(ThirdPersonNavigation) then ThirdPersonNavigation.MouseLook:=False;
  FreezeDiagWrite('TViewPlay.Stop: BEGIN (clean exit path)');
  SceneLifecycleLog(Format(
    '=== TViewPlay.Stop BEGIN (bike inst=$%p, sceneavatar=$%p) ===',
    [Pointer(FBikeInstance), Pointer(SceneAvatar)]));
  if Assigned(SceneAvatar) then
    SceneLifecycleLog(Format('VIEWPLAY stop: sceneavatar kids=%d',
      [SceneAvatar.Count]));

  { MCP: снимаем объекты 'world'/'bike'/'osm'/'camera' ДО освобождения
    менеджеров ниже — иначе в реестре останутся висячие указатели. }
  McpUnregisterPlayObjects;
  SetShadowTestRiders(0, False);
  FreeAndNil(FShadowAtlas);

  { Останавливаем симулятор сразу при выходе из активной игры,
    чтобы он не крутился вхолостую в меню. }
  if Assigned(DeviceService) then
    DeviceService.StopSimPlayback;

  { Сбрасываем массив указателей на rider-карты: сами карты owned by
    FreeAtStop и будут освобождены автоматически при уничтожении view,
    но FRiderCards остаётся stale между Stop и следующим Start, что
    вызывает access violation в UpdateRiderList следующего захода. }
  SetLength(FRiderCards, 0);
  if Assigned(FRemoteRiders) and Assigned(FRemoteRiders.RideClient) then
    FRemoteRiders.RideClient.OnRiderCountChanged := nil;
  { Экземпляры TBikeInstance — plain-class, владельца не имеют: только
    явный Free балансирует KeepExistingBegin rig-узлов (BikeShadowRig) и
    освобождает сам объект. Их FGroup/FScene (owner FreeAtStop) умерли бы
    и без того, но rig-подграф тогда текал по KeepExisting каждый заезд. }
  { Pose managers BEFORE bikes: managers hold a non-owned bike pointer. }
  if Assigned(FBotPoseManagers) then
    for I := 0 to FBotPoseManagers.Count - 1 do
      TObject(FBotPoseManagers[I]).Free;
  FreeAndNil(FBotPoseManagers);
  if Assigned(FBotBikes) then
    for I := 0 to FBotBikes.Count - 1 do
      TObject(FBotBikes[I]).Free;
  FreeAndNil(FBotBikes);   { только список; экземпляры освобождены выше }
  FreeAndNil(FBotAgents);  { параллельный список агентов ботов }

  ProfileLogLine('=== Session ending ===');
  ProfileSaveAndShow;
  FreeAndNil(FProfileLog);

  RideHistory.Finish;
  if FWorkoutHud<>nil then FWorkoutHud.ReleaseTrainer;
  FreeAndNil(FWorkoutGates);
  if GameSound<>nil then GameSound.StopRide;
  FAudioSampleTimer:=0;
  WorkoutPlayer.Stop;
  if Assigned(DeviceService) and DeviceService.HasControlDevice then
    try DeviceService.StopTrainer;except on E:Exception do Logger.Warning('[Trainer] '+E.Message);end;
  { Close sensor journal }
  if SensorLog.IsOpen then
    SensorLog.Close;

  { Только что записанный CSV-сеанс попадёт в очередь загрузки.
    Скан недорогой — просто пробег по sessions/. На завершении
    приложения unit RideUploadQueue может finalize-нуться раньше
    чем Castle освободит views — поэтому проверяем nil. }
  if Assigned(UploadQueue) then
    UploadQueue.Scan;

  FRemoteRiders.StopRelay;
  FreeAndNil(FRemoteRiders);
  FreeAndNil(FPoseManager);
  { Аватарный TBikeInstance — plain-class, владельца не имеет; явный Free
    балансирует KeepExistingBegin rig-узлов (см. ботов выше). MCP-реестр
    уже снят (McpUnregisterPlayObjects в начале Stop). }
  ClearGroundRiderShadow;
  FreeAndNil(FBikeInstance);
  FreeAndNil(FBLEHud);
  FreeAndNil(FCamera);
  FreeAndNil(FTerrainPBR);
  FreeAndNil(FLaneManager);
  FreeAndNil(FCinematicCam);
  FreeAndNil(FFreeCam);
  FreeAndNil(FScreenFX);
  { Free terrain preloaded processors }
  if Length(FTerrainProcessors) > 0 then
  begin
    for I := 0 to High(FTerrainProcessors) do
      FTerrainProcessors[I].Free;
    SetLength(FTerrainProcessors, 0);
    SetLength(FTerrainTexSets, 0);
  end;
  FreeAndNil(FTerrainTextureFolders);
  FreeAndNil(FLoopbackSession);
  FOfflineController := nil;
  { Поля агентов обнуляем ЯВНО: сами объекты умрут с FreeAtStop (owner)
    ниже в inherited Stop. Иначе на следующем Start висячий FOfflineAvatar
    проходил проверку Assigned() и звал SetWheelProbeHalfSpan на мёртвом
    объекте — EAccessViolation (gamephysicsbase.pas:604) ровно во втором
    заезде, дальше исключение летело в пост-сетап байка (а до фикса — в
    легаси-фолбэк со вторым велосипедом). }
  FOfflineAvatar := nil;
  FActiveAvatarAgent := nil;
  FActivePlayerController := nil;
  FreeAndNil(FOfflineWorld);
  FreeAndNil(Enemies);

  { Стриминговую карту освобождаем ДО inherited: inherited уничтожает
    MainViewport, а сессия владеет картой сама (Owner=nil) и должна
    быть снята с Viewport.Items раньше, чем вьюпорт исчезнет.
    ВАЖНО: освобождать ПОСЛЕ FLoopbackSession / FOfflineWorld — их
    агенты держат указатель TPhysicsState.GroundQuery на метод
    FOsmStreaming.GroundNearYAt; агенты должны умереть первыми, иначе
    указатель повиснет. }
  FreeAndNil(FOsmStreaming);
  FreeAndNil(FDreamVisual);FreeAndNil(FDreamWorld);

  inherited;
  { Dream World creates this optional design component at runtime. Its
    FreeAtStop owner has gone; do not reuse the pointer on the next Start. }
  SceneLevel:=nil;
  FFpsBgRect := nil;
  FBotPanel := nil;
  FFxPanel := nil;
  FSimPanel := nil;
  FMenuButton := nil;
  FWorkoutHud := nil;
  SceneLifecycleLog('=== TViewPlay.Stop END ===');
  FreezeDiagWrite('TViewPlay.Stop: END (clean exit completed)');
end;

procedure TViewPlay.ConnectRideRoom;
var WorldId:string;I:TRideRoomInfo;
begin
  if FRemoteRiders=nil then Exit;
  WorldId:='';if FDreamWorld<>nil then WorldId:=FDreamWorld.Id;
  if not RideRooms.MatchesRide(FCurrentFitPath,WorldId)then begin
    if(FRemoteRiders.RideClient<>nil)and FRemoteRiders.RideClient.PrivateRoom then
      FRemoteRiders.StopRelay;
    Exit;
  end;
  I:=RideRooms.Info;
  if(FRemoteRiders.RideClient<>nil)and FRemoteRiders.RideClient.PrivateRoom and
    (FRemoteRiders.RideClient.ServerUrl=I.RelayUrl)and
    (FRemoteRiders.RideClient.LocalRiderId=I.RiderId)then begin
    RideRooms.RelayError:=FRemoteRiders.RideClient.LastError;Exit;
  end;
  RideRooms.RelayError:='';
  FRemoteRiders.StartRelay(I.RelayUrl,BikeJsonFileName,BikeJsonFileName2,True,I.RiderId,VeloSite.CachedProfile.Nickname);
  if FActiveAvatarAgent<>nil then FRemoteRiders.LocalDistance:=FActiveAvatarAgent.State.CumulativeDistance;
  FRemoteRiders.RideClient.OnRiderCountChanged:=@RiderCountChanged;
end;

function TViewPlay.TrafficDiagnosticsSnapshot:TLaneReplayState;
begin
  if FLaneManager<>nil then Result:=FLaneManager.CaptureReplay else Result:=nil;
end;

function TViewPlay.RoomDiagnostics:TJSONObject;
var I:TRideRoomInfo;Rows:TRiderBroadcastArray;A:TJSONArray;N:Integer;
begin
  RideRooms.Update;I:=RideRooms.Info;
  Result:=TJSONObject.Create(['active',RideRooms.Active,'busy',RideRooms.Busy,
    'error',RideRooms.ErrorText,'code',I.Code,'kind',I.Kind,'world_id',I.WorldId,
    'content_hash',I.ContentHash,'start_slot',I.StartSlot,'account',I.RiderId]);
  Result.Add('relay_error',RideRooms.RelayError);
  if not SessionAlive then Exit;
  if FActiveAvatarAgent<>nil then begin
    Result.Add('distance',FActiveAvatarAgent.State.CumulativeDistance);
    Result.Add('position',TJSONArray.Create([FActiveAvatarAgent.State.WorldPosition.X,
      FActiveAvatarAgent.State.WorldPosition.Y,FActiveAvatarAgent.State.WorldPosition.Z]));
  end;
  if FRemoteRiders=nil then Exit;
  Result.Add('visual_count',FRemoteRiders.RemoteVisualCount);
  Result.Add('relay',FRemoteRiders.RideClient<>nil);
  if FRemoteRiders.RideClient<>nil then begin
    Rows:=FRemoteRiders.RideClient.GetAllRemoteRiders;A:=TJSONArray.Create;Result.Add('peers',A);
    for N:=0 to High(Rows)do A.Add(Rows[N].RiderId);
  end;
end;

procedure TViewPlay.ArrangeLocalRidersAtStart;
var I,H: Integer; A: TPhysicalAgent;WorldId:string;Slot:Integer;
begin
  if (FLaneManager=nil) or (FActiveAvatarAgent=nil) then Exit;
  WorldId:='';if FDreamWorld<>nil then WorldId:=FDreamWorld.Id;
  if not FRoomStartApplied and RideRooms.MatchesRide(FCurrentFitPath,WorldId)and
    (FActiveAvatarAgent.Path.PointCount>1)then begin
    FRoomStartApplied:=True;Slot:=RideRooms.Info.StartSlot;
    PlaceTrafficStartSlot(FLaneManager,FActiveAvatarAgent,Slot);
    if FRemoteRiders<>nil then FRemoteRiders.LocalDistance:=FActiveAvatarAgent.State.CumulativeDistance;
  end;
  { Clear this group's old reservations before assigning its new positions. }
  H:=RegisterTrafficAgent(FLaneManager,FActiveAvatarAgent);
  FLaneManager.InvalidateRiderPose(H);
  if FBotAgents<>nil then
    for I:=0 to FBotAgents.Count-1 do begin
      A:=TPhysicalAgent(FBotAgents[I]); H:=RegisterTrafficAgent(FLaneManager,A);
      FLaneManager.InvalidateRiderPose(H);
    end;
  PlaceTrafficAgent(FLaneManager,FActiveAvatarAgent);
  if FBotAgents<>nil then
    for I:=0 to FBotAgents.Count-1 do
      PlaceTrafficAgent(FLaneManager,TPhysicalAgent(FBotAgents[I]));
end;

procedure TViewPlay.CreateDemoBotOffline;
var
  BotTransform: TCastleTransform;
  BotScene: TCastleScene;
  BotAgent: TBotAgent;
  BotController: TBotPathController;
  BotBike: TBikeInstance;
begin
  Logger.Info('[ViewPlay] ' + '>>> CreateDemoBotOffline START');
  BotBike := nil;   { загрузка ниже в try может не дойти до присвоения }
  if not Assigned(MainViewport) then
  begin
    Logger.Info('[ViewPlay] ' + '  ABORT: MainViewport is nil');
    Exit;
  end;
  if not Assigned(FOfflineWorld) then
  begin
    Logger.Info('[ViewPlay] ' + '  ABORT: FOfflineWorld is nil');
    Exit;
  end;

  BotTransform := TCastleTransform.Create(FreeAtStop);
  BotTransform.Name := 'BotTransform';
  MainViewport.Items.Add(BotTransform);

  BotScene := TCastleScene.Create(FreeAtStop);
  BotScene.Name := 'BotScene';
  Logger.Info('[ViewPlay] ' + '  Loading BOT from: ' + BikeJsonFileName2);
  try
    { ОБЩИЙ пайплайн — тот же, что у аватара и удалённых райдеров:
      TBikeInstance с LOD + монтаж Tripo-райдера из секции tripoRider.
      Легаси LoadBikeAvatarFromJSON после смены принципа райдеров давал
      байк БЕЗ райдера (Tripo монтируется только здесь) и с лишним
      π-поворотом BikeRoot из старой конвенции — бот ехал задом наперёд.
      Group кладём в BotScene (Actor.Scene): ApplyModelRotation вращает
      её так же, как SceneAvatar у аватара — ориентация совпадает по
      построению. }
    BotBike := LoadCompanionBikeInstance(FreeAtStop);
    BotScene.Add(BotBike.Group);
    BotBike.Group.Exists := FPerfRiders;   { perf-тумблер «Райдер» для новых ботов }
    BotBike.AnimationEnabled := FPerfAnim;
    if BotBike.ShowShadow <> FPerfShadows then
      BotBike.ShowShadow := FPerfShadows;
    if Assigned(FBotBikes) then FBotBikes.Add(BotBike);
    { Авто-позы — тот же TRiderPoseManager, что у аватара (гейт 100 м /
      видимость — в UpdateBotPoseManagers). }
    AttachBotPoseManager(BotBike);

    { тень и общее солнце — как у аватара; для ботов капсулы }
    ApplyWorldSunToBikeShadow(BotBike);
    if UseSharedRiderShadows then BotBike.ShadowMode := bsmNone
    else BotBike.ShadowMode := bsmCGE;
    BotBike.ShadowSunIntensity := 3.0;   { как у аватара: перебить солнце карты }

    Logger.Info('[ViewPlay] ' + Format('  Bot TBikeInstance loaded OK: $%p, rider=%s',
      [Pointer(BotBike), BoolToStr(BotBike.HasTripoRider, True)]));
    if not BotScene.BoundingBox.IsEmpty then
      Logger.Info('[ViewPlay] ' + Format('  Bot BBox: (%.3f,%.3f,%.3f)-(%.3f,%.3f,%.3f)',
        [BotScene.BoundingBox.Data[0].X, BotScene.BoundingBox.Data[0].Y, BotScene.BoundingBox.Data[0].Z,
         BotScene.BoundingBox.Data[1].X, BotScene.BoundingBox.Data[1].Y, BotScene.BoundingBox.Data[1].Z]))
    else
      Logger.Info('[ViewPlay] ' + '  WARNING: Bot BBox is EMPTY');
  except
    on E: Exception do
      Logger.Info('[ViewPlay] ' + 'Bot bike load FAILED: ' + E.ClassName + ': ' + E.Message);
  end;
  BotTransform.Add(BotScene);

  Logger.Info('[ViewPlay] ' + Format('  IDENTITY CHECK: BotScene=$%p  SceneAvatar=$%p  same=%s',
    [Pointer(BotScene), Pointer(SceneAvatar),
     BoolToStr(BotScene = SceneAvatar, True)]));

  BotAgent := TBotAgent.Create(FreeAtStop);
  BotAgent.Name := 'Bot1';
  BotAgent.SetupActor(
    BotTransform,
    BotScene,
    nil,
    MainViewport,
    nil,
    SceneLevel
  );

  BotController := TBotPathController.Create;
  BotController.SetDesiredPower(180);
  BotController.SetEnabled(true);
  BotAgent.SetController(BotController);

  LoadAgentPath(BotAgent.Path);
  BotAgent.RecreatePhysics(pmKinematicCurrent);
  BotAgent.State.WheelContactAtOrigin := True;
  ApplyBikePhysicsToAgent(BotBike, BotAgent);
  BotAgent.Initialize;
  BotAgent.InitializeAtStart;
  BotAgent.NetworkAuthority := naLocalOnly;

  { Стриминговая карта: боту тоже нужен провайдер высоты Osm3d. }
  ApplyGroundQueryToAgent(BotAgent);

  FOfflineWorld.AddBot(BotAgent);
  FOfflineWorld.RegisterAgentInNetwork(BotAgent);

  { Параллельный список для UpdateBotShadowLOD. Добавляем только если
    байк этого бота реально попал в FBotBikes — иначе индексы разъедутся
    (байк мог не загрузиться: except выше глотает ошибку). }
  if Assigned(FBotAgents) and Assigned(FBotBikes)
     and (FBotBikes.Count > FBotAgents.Count) then
    FBotAgents.Add(BotAgent);

  Logger.Info('[ViewPlay] ' + '<<< CreateDemoBotOffline END');
end;

procedure TViewPlay.SpawnBotOffline(APower: Single);
begin
  { Legacy — kept for backward compat, now routes to server }
  OnBotAddClick(nil);
end;

procedure TViewPlay.OnBotAddClick(Sender: TObject);
var
  Power, RiderId: Integer;
begin
  if not Assigned(FRemoteRiders) then Exit;
  if not Assigned(FRemoteRiders.RideClient) then Exit;

  Power := 120 + Random(160);
  RiderId := FRemoteRiders.RideClient.CreateBot('Bot', Power);
  Logger.Info('[ViewPlay] ' + Format(
    'Bot create requested (power=%d) → rider_id=%d', [Power, RiderId]));
end;

procedure TViewPlay.OnBotRemoveClick(Sender: TObject);
begin
  if not Assigned(FRemoteRiders) then Exit;
  if not Assigned(FRemoteRiders.RideClient) then Exit;

  FRemoteRiders.RideClient.RemoveAllBots;
  Logger.Info('[ViewPlay] ' + 'Bot remove_all requested');
end;

procedure TViewPlay.OnFxToggleClick(Sender: TObject);
begin
  { Plain buttons: state lives in TScreenFX / FPerf* — a click flips the
    matching switch, the caption color (green/gray) shows the result.
    Perf-кнопки обрабатываем ПЕРВЫМИ: они не зависят от FScreenFX. }
  if Sender = FFxBtnTerr then
    SetPerfTerrain(not FPerfTerrain)
  else if Sender = FFxBtnRidr then
    SetPerfRiders(not FPerfRiders)
  else if Sender = FFxBtnAnim then
    SetPerfAnim(not FPerfAnim)
  else if Sender = FFxBtnShad then
    SetPerfShadows(not FPerfShadows)
  else if Sender = FFxBtnOcclusion then
    SetOcclusionCulling(not MainViewport.OcclusionCulling)
  else if Sender = FFxBtnTrees then
    Settings.SetProceduralTrees(not ProceduralVegetationActive)
  else if Sender = FFxBtnTreeSeason then
    Settings.SetTreeSeason((Round(ProceduralVegetationSeason * 4) + 1) mod 4 * 0.25)
  else if Sender = FFxBtnRoad then
  begin
    if RoadMaterialMode = rmmCached then SetRoadMaterialMode(rmmDirect)
    else SetRoadMaterialMode(rmmCached);
  end
  else if Sender = FFxBtnWorldShad then
    SetAtlasWorldShadows(not FAtlasWorldShadows)
  else if Sender = FFxBtnPath then
  begin
    { FIT path spheres: red raw + green snapped on streaming map. }
    if Assigned(FOsmStreaming) and FOsmStreaming.Active then
      FOsmStreaming.SetFitPointOverlays(not FOsmStreaming.FitPointOverlaysOn)
    else
      Logger.Info('[ViewPlay] Path spheres: no active streaming map');
  end
  else if Assigned(FScreenFX) then
  begin
    if Sender = FFxBtnFog then
      FScreenFX.FogEnabled := not FScreenFX.FogEnabled
    else if Sender = FFxBtnBloom then
      FScreenFX.BloomEnabled := not FScreenFX.BloomEnabled
    else if Sender = FFxBtnTone then
      FScreenFX.ToneEnabled := not FScreenFX.ToneEnabled
    else if Sender = FFxBtnPoster then
      FScreenFX.PosterizeEnabled := not FScreenFX.PosterizeEnabled
    else if Sender = FFxBtnKuwa then
      FScreenFX.KuwaharaEnabled := not FScreenFX.KuwaharaEnabled
    else if Sender = FFxBtnHatch then
      FScreenFX.HatchEnabled := not FScreenFX.HatchEnabled;
  end;
  UpdateFxButtonColors;
end;

procedure TViewPlay.UpdateFxButtonColors;

  procedure Paint(Btn: TCastleButton; const IsOn: Boolean);
  begin
    if Btn = nil then Exit;
    if IsOn then
      Btn.CustomTextColor := Vector4(0.35, 1.0, 0.45, 1)   { green = on }
    else
      Btn.CustomTextColor := Vector4(0.55, 0.55, 0.55, 1); { gray = off }
  end;

begin
  if Assigned(FScreenFX) then
  begin
    Paint(FFxBtnFog,    FScreenFX.FogEnabled);
    Paint(FFxBtnBloom,  FScreenFX.BloomEnabled);
    Paint(FFxBtnTone,   FScreenFX.ToneEnabled);
    Paint(FFxBtnPoster, FScreenFX.PosterizeEnabled);
    Paint(FFxBtnKuwa,   FScreenFX.KuwaharaEnabled);
    Paint(FFxBtnHatch,  FScreenFX.HatchEnabled);
  end;
  { perf-кнопки — всегда, не зависят от FScreenFX }
  Paint(FFxBtnTerr, FPerfTerrain);
  Paint(FFxBtnRidr, FPerfRiders);
  Paint(FFxBtnAnim, FPerfAnim);
  Paint(FFxBtnShad, FPerfShadows);
  Paint(FFxBtnOcclusion, MainViewport.OcclusionCulling);
  Paint(FFxBtnWorldShad, FAtlasWorldShadows);
  Paint(FFxBtnRoad, RoadMaterialMode = rmmCached);
  Paint(FFxBtnTrees, ProceduralVegetationActive);
  if FFxBtnTrees <> nil then
    if ProceduralVegetationActive then BindUiText(FFxBtnTrees, 'Trees: 3D')
    else BindUiText(FFxBtnTrees, 'Trees: legacy');
  Paint(FFxBtnTreeSeason, ProceduralVegetationActive);
  if FFxBtnTreeSeason <> nil then
    case Round(ProceduralVegetationSeason * 4) mod 4 of
      0: BindUiText(FFxBtnTreeSeason, 'Spring');
      1: BindUiText(FFxBtnTreeSeason, 'Summer');
      2: BindUiText(FFxBtnTreeSeason, 'Autumn');
      3: BindUiText(FFxBtnTreeSeason, 'Winter');
    end;
  Paint(FFxBtnPath,
    Assigned(FOsmStreaming) and FOsmStreaming.Active
    and FOsmStreaming.FitPointOverlaysOn);
end;

function TViewPlay.AdminPanelsVisible: Boolean;
begin
  Result := VeloSite.IsAuthorized and VeloSite.HasCachedProfile and
    VeloSite.CachedProfile.IsAdmin and not FAdminPanelsHidden;
end;

procedure TViewPlay.UpdateAdminPanels;
var ShowPanels: Boolean; LayoutHeight,S,MenuTop: Single;
begin
  ShowPanels := AdminPanelsVisible and not FFocusMode;
  LayoutHeight := 0;
  if Container <> nil then LayoutHeight := Container.UnscaledHeight;
  if FAdminLayoutValid and (FAdminLayoutShown = ShowPanels) and
     (FAdminLayoutHeight = LayoutHeight) then Exit;
  FAdminLayoutValid := True;
  FAdminLayoutShown := ShowPanels;
  FAdminLayoutHeight := LayoutHeight;
  if FFxPanel <> nil then FFxPanel.Exists := ShowPanels;
  if FBotPanel <> nil then FBotPanel.Exists := ShowPanels;
  if LabelFps <> nil then LabelFps.Exists := ShowPanels;
  if FFpsBgRect <> nil then FFpsBgRect.Exists := ShowPanels;
  if CheckboxCameraFollows <> nil then CheckboxCameraFollows.Exists := ShowPanels;
  if CheckboxDebugAvatarColliders <> nil then CheckboxDebugAvatarColliders.Exists := ShowPanels;
  { VerticalGroup1 also holds the normal rider list: keep that list visible. }
  if FRiderScroll <> nil then
  begin
    if Container <> nil then
      if ShowPanels then FRiderScroll.Height := Math.Max(80.0, Math.Min(600.0, Container.UnscaledHeight - 350))
      else FRiderScroll.Height := Math.Max(80.0, Math.Min(600.0, Container.UnscaledHeight - 180));
  end;
  if VerticalGroup1 <> nil then
  begin
    if ShowPanels then VerticalGroup1.Translation := Vector2(-10, -250)
    else VerticalGroup1.Translation := Vector2(-10, -138);
  end;
  S:=Math.Max(0.65,Math.Min(1.0,UIScale));MenuTop:=12;
  if FFocusMode then S:=TrainingFocusScale(UIScale);
  if ShowPanels then MenuTop:=278;
  if FMenuButton <> nil then begin
    FMenuButton.Width:=136/S;FMenuButton.Height:=44/S;FMenuButton.FontSize:=16/S;
    FMenuButton.Anchor(hpLeft,12/S);FMenuButton.Anchor(vpTop,-MenuTop/S);
  end;
  if FFocusButton<>nil then begin
    FFocusButton.Width:=180/S;FFocusButton.Height:=44/S;FFocusButton.FontSize:=15/S;
    FFocusButton.Anchor(hpLeft,12/S);FFocusButton.Anchor(vpTop,-(MenuTop+52)/S);
  end;
  if FFocusMode and(FMenuButton<>nil)and(FFocusButton<>nil)then begin
    FMenuButton.Width:=100/S;FMenuButton.Height:=34/S;FMenuButton.FontSize:=13/S;
    FFocusButton.Width:=210/S;FFocusButton.Height:=34/S;FFocusButton.FontSize:=13/S;
    FFocusButton.Anchor(hpRight,-12/S);FFocusButton.Anchor(vpTop,-12/S);
  end;
  UpdateRiderListVisibility;
end;

procedure TViewPlay.UpdateRiderListVisibility;
begin
  if FRiderScroll <> nil then FRiderScroll.Exists := FHasOtherRiders and not FFocusMode;
  if VerticalGroup1 <> nil then
    VerticalGroup1.Exists := (AdminPanelsVisible or FHasOtherRiders)and not FFocusMode;
end;

procedure TViewPlay.RiderCountChanged(Sender: TObject);
begin
  { The relay calls this when publishing a changed count, not every frame.
    FRiderCards is a reusable pool and cannot tell how many riders remain. }
  FHasOtherRiders := TRideRelayClient(Sender).RemoteRiderCount > 0;
  UpdateRiderListVisibility;
  if FHasOtherRiders then UpdateRiderList;
end;

procedure TViewPlay.BeginActivityRecord;
var Title,WorldName:String;
begin
  Title:=ChangeFileExt(ExtractFileName(FCurrentFitPath),'');WorldName:='';
  if FDreamWorld<>nil then begin Title:=FDreamWorld.Title;WorldName:=FDreamWorld.Id;end;
  if Title='' then Title:=UiText('Free ride');
  if WorldName<>'' then RememberRideMap(rmkDream,WorldName)
  else RememberRideMap(rmkReal,FCurrentFitPath);
  RideHistory.BeginRide(Title,FCurrentFitPath,WorldName);
  if HasActiveState then RideHistory.RebaseDistance(FActiveAvatarAgent.State.CumulativeDistance);
  if WorkoutPlayer.Plan<>nil then RideHistory.SetWorkout(WorkoutPlayer.Plan.Name,WorkoutPlayer.Plan.Url);
end;

procedure TViewPlay.RestoreActivityRecord;
var O,R:TJSONObject;Seek:TSimSeekEvent;
begin
  if FOsmPrepHold or not HasActiveState or not RideHistory.RestoreNeeded then Exit;
  O:=RideHistory.TakeResume;
  if O=nil then Exit;
  try
    if O.Get('version',0)<>1 then raise Exception.Create('Unsupported saved ride version');
    R:=O.Objects['rider'];RestoreRidePosition(FActiveAvatarAgent,R);
    WorkoutPlayer.RestoreState(O.Objects['workout']);DailyTraining.RestoreState(O.Objects['daily']);
    if DeviceService.IsSimulationActive and(R.Find('sim_position')<>nil)then begin
      Seek:=DeviceService.OnSimSeek;DeviceService.OnSimSeek:=nil;
      try DeviceService.SimSeekSec(R.Get('sim_position',0.0));DeviceService.SimSetPaused(True);
      finally DeviceService.OnSimSeek:=Seek;end;
      FSimAccountedUntil:=R.Get('sim_accounted',R.Get('sim_position',0.0));
    end;
    if FCinematicCam<>nil then FCinematicCam.ResetAtTarget;
    SetTrainingFocus(R.Get('training_focus',False));
    RideHistory.ResumeApplied;
  except on E:Exception do begin
    Logger.Warning('[RideRecovery] '+E.Message);StopMoving;
    O.Free;
    OpenMenu;ViewMenu.FinishRide;
    raise;
  end;
  end;
  O.Free;
end;

procedure TViewPlay.SaveActivityCheckpoint;
var O:TJSONObject;
begin
  if FOsmPrepHold or not HasActiveState or not RideHistory.CheckpointDue then Exit;
  O:=CaptureRidePosition(FActiveAvatarAgent);
  O.Add('training_focus',FFocusMode);
  if DeviceService.IsSimulationActive then begin
    O.Add('sim_position',DeviceService.SimPositionSec);O.Add('sim_accounted',FSimAccountedUntil);
  end;
  RideHistory.Checkpoint(O);
end;

procedure TViewPlay.ClickFinishWorkoutRide(Sender:TObject);
begin OpenMenu;ViewMenu.FinishRide;end;

procedure TViewPlay.ClickMenu(Sender: TObject);
begin
  OpenMenu;
end;

procedure TViewPlay.OpenMenu;
begin
  if Container.PendingFrontView <> Self then Exit;
  if FFocusPanel<>nil then FFocusPanel.SyncWindow(False);
  FCameraDragging := False;
  Container.ReleaseCapture(Self);
  Container.ReleaseCapture(ThirdPersonNavigation);
  Container.PushView(ViewMenu);
end;

procedure TViewPlay.BikeFitChanged;
begin
  ApplyWheelProbeFromBike;
  ApplyBikePhysicsToAgent(FBikeInstance, FOfflineAvatar,True);
  if FActiveAvatarAgent <> FOfflineAvatar then
    ApplyBikePhysicsToAgent(FBikeInstance, FActiveAvatarAgent,True);
  if Assigned(FPoseManager) and Assigned(FBikeInstance) then
    FPoseManager.OverlayKneeAnkle(FBikeInstance.TripoKneeFlare,
      FBikeInstance.TripoAnkleFlex);
end;

function TViewPlay.RideCadence: Single;
begin
  Result := 0;
  if Assigned(FBLEHud) then Result := FBLEHud.BLEData.InstantCadence;
end;

procedure TViewPlay.ApplyWheelProbeFromBike;
begin
  if Assigned(FBikeInstance) and Assigned(FActiveAvatarAgent)
     and Assigned(FActiveAvatarAgent.Physics) then
    FActiveAvatarAgent.Physics.SetWheelProbeHalfSpan(FBikeInstance.AxleHalfSpanM);
end;

procedure TViewPlay.UpdateRiderList;
var
  Riders: TRiderBroadcastArray;
  I, J, Total, SelfIdx: Integer;
  Card: TRiderCard;
  LocalDist, LocalSpeed, CrankInt: Single;
  LocalPower, LocalCadence, LocalHR: Integer;
  LocalName: string;
  TmpCard: TRiderCard;
  SelfY, ScrollH, ContentH: Single;
begin
  if not Assigned(FRiderInner) then Exit;
  if not Assigned(FRemoteRiders) then Exit;
  if not Assigned(FRemoteRiders.RideClient) then Exit;
  if not FRemoteRiders.RideClient.Started then Exit;

  Riders := FRemoteRiders.RideClient.GetAllRemoteRiders;
  Total := Length(Riders) + 1;
  LocalDist := FRemoteRiders.LocalDistance;

  { Collect local rider data }
  LocalName := FRemoteRiders.RideClient.LocalRiderName;
  if HasActiveState then
  begin
    LocalSpeed := FActiveAvatarAgent.State.CurrentSpeed;
    LocalPower := Round(FActiveAvatarAgent.State.AppliedPowerWatts);
  end else begin
    LocalSpeed := 0; LocalPower := 0;
  end;
  if FBLEHud.BLEDataValid then
  begin
    LocalCadence := FBLEHud.BLEData.InstantCadence;
    LocalHR := FBLEHud.BLEData.HeartRate;
  end else begin
    LocalCadence := 0; LocalHR := 0;
  end;

  { ── Local avatar animation speed from cadence — перенесено в покадровый
    update (там же AnimateFrame): UpdateRiderList gated на RideClient.Started
    и бежит раз в 30 кадров, в соло-заезде аватар без педалирования. ── }

  { ── Remote riders animation speed from cadence ── }
  if FPerfAnim then FRemoteRiders.UpdateRemoteAnimationSpeeds;

  { Create cards on demand }
  while Length(FRiderCards) < Total do
  begin
    Card := TRiderCard.Create(FreeAtStop);
    FRiderInner.InsertFront(Card);
    SetLength(FRiderCards, Length(FRiderCards) + 1);
    FRiderCards[High(FRiderCards)] := Card;
  end;

  { Fill card 0 = self }
  FRiderCards[0].SetData(LocalName, 0, LocalSpeed,
    LocalPower, LocalCadence, LocalHR, True);

  { Fill cards 1..N = remote riders (relative distance from self) }
  for I := 0 to High(Riders) do
    FRiderCards[I + 1].SetData(Riders[I].Name,
      Riders[I].Distance - LocalDist,
      Riders[I].Speed, Riders[I].Power,
      Riders[I].Cadence, Riders[I].HeartRate, False);

  { Hide excess }
  for I := Total to High(FRiderCards) do
    FRiderCards[I].Exists := False;
  for I := 0 to Total - 1 do
    FRiderCards[I].Exists := True;

  { Sort by RouteDist descending: ahead (+) on top, self (0) middle, behind (-) bottom }
  for I := 0 to Total - 2 do
    for J := 0 to Total - 2 - I do
      if FRiderCards[J].RouteDist < FRiderCards[J + 1].RouteDist then
      begin
        TmpCard := FRiderCards[J];
        FRiderCards[J] := FRiderCards[J + 1];
        FRiderCards[J + 1] := TmpCard;
      end;

  { Reorder in UI to match sorted order }
  FRiderInner.ClearControls;
  SelfIdx := 0;
  for I := 0 to Total - 1 do
  begin
    FRiderInner.InsertFront(FRiderCards[I]);
    if FRiderCards[I].IsSelf then SelfIdx := I;
  end;

  { Scroll so self is centered }
  if Assigned(FRiderScroll) then
  begin
    ScrollH := FRiderScroll.Height;
    ContentH := Total * (44 + 3);
    if ContentH > ScrollH then
    begin
      SelfY := SelfIdx * (44 + 3);
      FRiderScroll.Scroll := EnsureRange(SelfY - ScrollH / 2 + 22, 0, ContentH - ScrollH);
    end;
  end;
end;

procedure TViewPlay.InitializeAtStart;
begin
  if HasActiveState then begin
    FActiveAvatarAgent.InitializeAtStart;
    PlaceTrafficAgent(FLaneManager,FActiveAvatarAgent);
  end;
end;

procedure TViewPlay.StartMoving;
begin
  if Assigned(FActivePlayerController) then
    FActivePlayerController.SetAutoMove(true);
end;

procedure TViewPlay.StopMoving;
begin
  if Assigned(FActivePlayerController) then
    FActivePlayerController.SetAutoMove(false);
end;

{ ── ESC-пауза / смена маршрута без пересоздания мира ──────────────────── }

function TViewPlay.SessionAlive: Boolean;
begin
  { Сессия жива, если мир уже поднят (Start отработал и Stop ещё не был).
    По байку надёжнее всего: он создаётся в Start и нилится в Stop. }
  Result := Assigned(FBikeInstance);
end;

procedure TViewPlay.PrepareDreamWorld(AWorld:TDreamWorld;AVisual:TDreamWorldVisual);
begin FreeAndNil(FNextDreamVisual);FreeAndNil(FNextDreamWorld);FNextDreamWorld:=AWorld;FNextDreamVisual:=AVisual;FCurrentFitPath:='';end;
procedure TViewPlay.ResetRideToDream(AWorld:TDreamWorld;AVisual:TDreamWorldVisual);
begin ResetRideWorld('',AWorld,AVisual);end;
procedure TViewPlay.ResetRideToFit(const AFitPath:String);
begin ResetRideWorld(AFitPath,nil,nil);end;
procedure TViewPlay.ResetRideWorld(const AFitPath:String;AWorld:TDreamWorld;AVisual:TDreamWorldVisual);
var
  I: Integer;
  WorldChanged:Boolean;
  procedure DetachGroundQuery(const Agent: TPhysicalAgent);
  begin
    if (Agent = nil) or (Agent.State = nil) then Exit;
    Agent.State.GroundQuery := nil;
    Agent.State.PositionConstraint := nil;
    Agent.State.SlopeQuery := nil;
  end;
begin
  ClearSimReplay;
  RideHistory.Finish;
  if SensorLog.IsOpen then SensorLog.Close;
  if Assigned(UploadQueue) then UploadQueue.Scan;
  if FWorkoutHud<>nil then FWorkoutHud.ReleaseTrainer;
  FreeAndNil(FWorkoutGates);
  if GameSound<>nil then GameSound.StopRide;
  FAudioSampleTimer:=0;
  WorkoutPlayer.Stop;
  WorldChanged:=(FDreamWorld<>nil)or(AWorld<>nil);
  McpUnregisterPlayObjects;
  SceneLifecycleLog(Format('=== TViewPlay.ResetRideToFit: %s (world=%s, bike=$%p) ===',
    [AFitPath, BoolToStr(Assigned(FOfflineWorld), True), Pointer(FBikeInstance)]));

  { Движение и мощность — в ноль: райдер стоит на старте нового маршрута,
    пока юзер не нажмёт Play (как в Start). }
  StopMoving;
  if Assigned(FActivePlayerController) then
  begin
    FActivePlayerController.SetAutoMove(True);
    FActivePlayerController.SetDesiredPower(0);
  end;
  if HasActiveState then
    FActiveAvatarAgent.State.AppliedPowerWatts := 0;

  { Стриминговая сессия — ЕДИНСТВЕННОЕ, что разбирается: teardown теперь
    отменяемый (ACancel по цепочке BuildFitBank/GetRegion) — быстро.
    ВАЖНО: агенты держат method-pointers GroundQuery/SlopeQuery на методы
    старого FOsmStreaming — сразу после подъёма новой сессии перепривязать
    (ниже), иначе висячие указатели. }
  { All borrowed callbacks must be detached before the provider is freed,
    including the camera which survives this route reset. }
  if Assigned(FCinematicCam) then FCinematicCam.GroundQuery := nil;
  DetachGroundQuery(FActiveAvatarAgent);
  if Assigned(FBotAgents) then
    for I := 0 to FBotAgents.Count - 1 do
      DetachGroundQuery(TPhysicalAgent(FBotAgents[I]));
  if Assigned(FOsmStreaming) then
    FreeAndNil(FOsmStreaming);

  FreeAndNil(FDreamVisual);FreeAndNil(FDreamWorld);FDreamWorld:=AWorld;FDreamVisual:=AVisual;
  if AWorld<>nil then begin
    if SceneRoadBarrier<>nil then SceneRoadBarrier.Exists:=False;
  end;
  FCurrentFitPath := AFitPath;
  ResolveMapPaths;
  ApplyCustomTerrainScene;   { новая сессия + BeginRouteSnap + холд прогрева }
  ApplyStreamingGroundQuery;

  { Флаги маршрутного конвейера — как в Start: иначе снап/ширины/постановка
    на старт не отработают для нового маршрута. }
  FOsmSnapApplied   := False;
  FOsmWidthsApplied := False;
  FOsmPrepHoldLogTick := 0;
  FOsmPrepResumeAutoMove := False;
  FOsmPrepGroundSince := 0;
  FOsmPrepRaised    := False;
  FOsmPrepDiagUntil := 0;
  FOsmPrepDiagTick  := 0;

  { Путь райдера из новой сессии (сырой FIT; снап подъедет в Update) +
    перепривязка провайдеров высоты + постановка на старт. }
  if Assigned(FActiveAvatarAgent) then
  begin
    LoadAgentPath(FActiveAvatarAgent.Path);
    ApplyGroundQueryToAgent(FActiveAvatarAgent);
    if FActiveAvatarAgent.Path.PointCount >= 2 then
      FActiveAvatarAgent.InitializeAtStart;
  end;

  { Оффлайн-боты: тот же новый путь/высоты, тоже на старт. }
  if Assigned(FBotAgents) then
    for I := 0 to FBotAgents.Count - 1 do
      if Assigned(FBotAgents[I]) then
      begin
        LoadAgentPath(TPhysicalAgent(FBotAgents[I]).Path);
        ApplyGroundQueryToAgent(TPhysicalAgent(FBotAgents[I]));
        if TPhysicalAgent(FBotAgents[I]).Path.PointCount >= 2 then
          TPhysicalAgent(FBotAgents[I]).InitializeAtStart;
      end;

  { Длины пути для lane-менеджера/удалённых райдеров — как в Start/снап-свапе. }
  if WorldChanged then begin
    FreeAndNil(FRemoteRiders);FreeAndNil(FLaneManager);
    FRemoteRiders:=TRemoteRidersManager.Create(FreeAtStop);
    FRemoteRiders.OnProfileLog:=@ProfileLogLine;
    FRemoteRiders.Setup(MainViewport,SceneLevel,AvatarTransform,FActiveAvatarAgent.Path);
    FRemoteRiders.InitPathCumDist;
    if UseSharedRiderShadows then FRemoteRiders.SetShadowMode(bsmNone);
    FRoomStartApplied:=False;ConnectRideRoom;
    if Assigned(FRemoteRiders.RideClient) then
      FRemoteRiders.RideClient.OnRiderCountChanged := @RiderCountChanged;
    FLaneManager:=TLaneManager.Create;FLaneManager.SetRoad(7.0,FRemoteRiders.PathTotalLength);
    FLocalLaneHandle:=FLaneManager.RegisterRider(FActiveAvatarAgent);
    FRemoteRiders.SetLaneManager(FLaneManager,FLocalLaneHandle);
  end;
  if Assigned(FRemoteRiders) then
  begin
    FRemoteRiders.InitPathCumDist;
    if Assigned(FLaneManager) then
      if FDreamWorld<>nil then FLaneManager.SetRoad(FDreamWorld.Width,FRemoteRiders.PathTotalLength)
      else FLaneManager.SetRoad(8.0, FRemoteRiders.PathTotalLength);
  end;

  ArrangeLocalRidersAtStart;

  { HUD обнуляем; FIT-плеер — с начала и на паузе (как в Start). }
  if Assigned(FBLEHud) then FBLEHud.Reset;
  BeginActivityRecord;
  if Assigned(DeviceService) then
  begin
    if FCurrentFitPath <> '' then Settings.SetSelectedRoutePath(FCurrentFitPath);
    DeviceService.StartSimPlayback;
    if DeviceService.IsSimulationActive then
    begin
      DeviceService.SimRestart;
      DeviceService.SimSetPaused(True);
    end;
  end;

  { Камера — в кинематик-режим по умолчанию (как в Start). }
  FCameraMode := pcmCinematic;
  ApplyCameraMode;

  ProfileLogLine('=== ResetRideToFit: new route armed ===');
  McpRegisterPlayObjects;
  SceneLifecycleLog('=== TViewPlay.ResetRideToFit END ===');
end;

procedure TViewPlay.DumpRidePath(const AFileName: String);
var
  SL: TStringList;
  I, BotI: Integer;
  P, C: TVector3;
  PP: TPathPosition;
  GY: Single;
  Sep: String;
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  SL := TStringList.Create;
  try
    SL.Add('{');
    SL.Add(Format('  "fit": "%s",', [StringToJSONString(FCurrentFitPath)], FS));
    if Assigned(FOsmStreaming) and FOsmStreaming.Active then
    begin
      SL.Add(Format('  "origin": [%.8f, %.8f],',
        [FOsmStreaming.Origin.Lat, FOsmStreaming.Origin.Lon], FS));
      if (FOsmStreaming.Session <> nil) and (FOsmStreaming.Session.Map <> nil) then
        SL.Add(Format('  "snapped_count": %d,',
          [Length(FOsmStreaming.Session.Map.SnappedRoute)], FS));
      if FOsmStreaming.RouteStartGroundY(GY) then
        SL.Add(Format('  "start_ground_y": %.3f,', [GY], FS))
      else
        SL.Add('  "start_ground_y": null,');
    end;
    if HasActiveState then
    begin
      SL.Add(Format('  "rider_pos": [%.3f, %.3f, %.3f],',
        [FActiveAvatarAgent.State.WorldPosition.X,
         FActiveAvatarAgent.State.WorldPosition.Y,
         FActiveAvatarAgent.State.WorldPosition.Z], FS));
      SL.Add(Format('  "cum_dist": %.2f,',
        [FActiveAvatarAgent.State.CumulativeDistance], FS));
      if Assigned(FActiveAvatarAgent.Path) then
      begin
        SL.Add(Format('  "path_count": %d,', [FActiveAvatarAgent.Path.PointCount], FS));
        SL.Add('  "points": [');
        for I := 0 to FActiveAvatarAgent.Path.PointCount - 1 do
        begin
          P := FActiveAvatarAgent.Path.GetPathPointWorld(I);
          PP.Segment := I; PP.T := 0;
          C := FActiveAvatarAgent.Path.RoadCenterAt(PP);
          if I < FActiveAvatarAgent.Path.PointCount - 1 then Sep := ',' else Sep := '';
          SL.Add(Format('    [%.3f,%.3f,%.3f,%.2f,%.3f,%.3f,%.3f]%s',
            [P.X, P.Y, P.Z, FActiveAvatarAgent.Path.PointWidth(I),
             C.X, C.Y, C.Z, Sep], FS));
        end;
        SL.Add('  ],');
      end;
    end;
    if Assigned(FBotAgents) then
      for BotI := 0 to FBotAgents.Count - 1 do
        if Assigned(FBotAgents[BotI]) and Assigned(TPhysicalAgent(FBotAgents[BotI]).Path) then
          SL.Add(Format('  "bot%d_path_count": %d,',
            [BotI, TPhysicalAgent(FBotAgents[BotI]).Path.PointCount], FS));
    SL.Add('  "end": true');
    SL.Add('}');
    SL.SaveToFile(AFileName);
  finally
    SL.Free;
  end;
end;

{ ── perf-тумблеры (MCP perf.set) ─────────────────────────────────────── }

procedure TViewPlay.SetPerfAnim(AOn: Boolean);
var
  I: Integer;
begin
  FPerfAnim := AOn;
  if Assigned(FBikeInstance) then FBikeInstance.AnimationEnabled := AOn;
  if Assigned(FBotBikes) then
    for I := 0 to FBotBikes.Count - 1 do
      TBikeInstance(FBotBikes[I]).AnimationEnabled := AOn;
  if Assigned(FRemoteRiders) then FRemoteRiders.SetAnimationEnabled(AOn);
  UpdateFxButtonColors;   { синхронизация с MCP perf.set }
end;

procedure TViewPlay.SetPerfRiders(AOn: Boolean);
var
  I: Integer;
begin
  FPerfRiders := AOn;
  { Exists всего корня BikeParametric (байк+райдер+тени), а не только
    TripoShowRider — иначе скрывался лишь человек, байк продолжал рисоваться. }
  if Assigned(FBikeInstance) then
    FBikeInstance.Group.Exists := AOn;
  if Assigned(FBotBikes) then
    for I := 0 to FBotBikes.Count - 1 do
      TBikeInstance(FBotBikes[I]).Group.Exists := AOn;
  if Assigned(FRemoteRiders) then
    FRemoteRiders.SetRidersVisible(AOn);
  { Теневая плоскость аватара: при скрытых райдерах пробы не нужны. }
  if Assigned(FActiveAvatarAgent) and Assigned(FActiveAvatarAgent.State) then
    FActiveAvatarAgent.State.ShadowPlaneWanted := AOn and FPerfShadows and not UseSharedRiderShadows;
  UpdateGroundRiderShadow;
  UpdateFxButtonColors;
end;

procedure TViewPlay.SetAtlasWorldShadows(AOn: Boolean);
begin
  if FAtlasWorldShadows = AOn then Exit;
  FAtlasWorldShadows := AOn;
  { The next complete atlas render publishes the new caster set.
    Disabling world casters leaves rider shadows only; CPU masks stay off. }
  HideGroundRiderShadow;
  UpdateFxButtonColors;
end;

procedure TViewPlay.SetOcclusionCulling(AOn: Boolean; Persist: Boolean);
begin
  MainViewport.OcclusionCulling := AOn;
  if Persist then Settings.SetOcclusionCulling(AOn);
  UpdateFxButtonColors;
end;

procedure TViewPlay.ApplyShadowSettings;
begin
  if FShadowAtlas <> nil then
    FShadowAtlas.Configure(Settings.GetGraphicsOption(Ord(goShadowSize)),
      Settings.GetGraphicsOption(Ord(goShadowFilter)),
      Settings.GetGraphicsOption(Ord(goShadowDistance)));
  SetPerfShadows((Settings.GetGraphicsOption(Ord(goShadowSize)) <> 0) and not CliFlag('noshadow'));
end;

procedure TViewPlay.SetPerfShadows(AOn: Boolean);
var
  I: Integer;
  BotBike: TBikeInstance;
begin
  FPerfShadows := AOn;
  if Assigned(FBikeInstance) and (FBikeInstance.ShowShadow <> AOn) then
    FBikeInstance.ShowShadow := AOn;
  if Assigned(FBotBikes) then
    for I := 0 to FBotBikes.Count - 1 do
    begin
      BotBike := TBikeInstance(FBotBikes[I]);
      if BotBike.ShowShadow <> AOn then
        BotBike.ShowShadow := AOn;
    end;
  if Assigned(FRemoteRiders) then
    FRemoteRiders.SetShadowsVisible(AOn);
  if Assigned(FActiveAvatarAgent) and Assigned(FActiveAvatarAgent.State) then
    FActiveAvatarAgent.State.ShadowPlaneWanted := AOn and FPerfRiders and not UseSharedRiderShadows;
  UpdateBotShadowLOD;
  UpdateGroundRiderShadow;
  UpdateFxButtonColors;
end;

procedure TViewPlay.SetPerfTerrain(AOn: Boolean);
begin
  FPerfTerrain := AOn;
  { Hide rendering only. Exists also removes global lights and physics:
    changing the light set forces new shader programs on the remaining riders. }
  if Assigned(FOsmStreaming) and (FOsmStreaming.Session <> nil)
     and (FOsmStreaming.Session.Map <> nil) then
    FOsmStreaming.Session.Map.Visible := AOn
  else if Assigned(SceneLevel) then
    SceneLevel.Visible := AOn;   { дефолтный (нестриминговый) мир }
  UpdateFxButtonColors;
end;

function TViewPlay.RoutePrepDone: Boolean;
begin
  { «Можно стартовать» для UI/MCP: плоская карта прогрева снята и райдер
    уже на реальной земле. Map.RoutePrepDone (снап-воркер) наступает РАНЬШЕ —
    одного его мало: иначе sim.play / камера стартуют при avatarY=0, а потом
    земля монтируется → скачок ~сотни метров. FOsmPrepHold держится до
    RouteStartGroundY + InitializeAtStart + NotifyRiderPlaced. }
  if (not Assigned(FOsmStreaming)) or (not FOsmStreaming.Active) then
    Exit(True);
  Result := not FOsmPrepHold;
end;

function TViewPlay.HasActiveState: Boolean;
begin
  Result := Assigned(FActiveAvatarAgent) and Assigned(FActiveAvatarAgent.State);
end;

procedure TViewPlay.UpdateRideAudio(const Seconds:Single;const Advancing:Boolean);
var Mix:TEnvironmentMix;P:TVector3;
begin
  if GameSound=nil then Exit;
  if not HasActiveState or FOsmPrepHold then begin GameSound.StopRide;Exit;end;
  FAudioSampleTimer:=FAudioSampleTimer-Seconds;
  if FAudioSampleTimer<=0 then begin
    FAudioSampleTimer:=0.5;Mix:=Default(TEnvironmentMix);
    P:=FActiveAvatarAgent.State.WorldPosition;P.Y:=FActiveAvatarAgent.State.LastGroundY;
    if FDreamWorld<>nil then Mix:=FDreamWorld.EnvironmentSoundsAt(P)
    else if(FOsmStreaming<>nil)and(FOsmStreaming.Session<>nil)and
      (FOsmStreaming.Session.Map<>nil)then Mix:=FOsmStreaming.Session.Map.EnvironmentSoundsAt(P);
    GameSound.SetEnvironment(Mix,FActiveAvatarAgent.State.CurrentSpeed);
  end;
  GameSound.StepRide(FActiveAvatarAgent.State,WorkoutPlayer,Advancing,Container.FrontView<>Self);
end;

procedure SetGameGraphicsBenchmarkActive(Value: Boolean);
begin
  GFpsGraphicsBenchmark := Value;
  if not Value and (ViewPlay <> nil) then
    ViewPlay.FFreezeDiagLastHeartBeat := GetTickCount64;
  ApplyGameFpsMode;
end;

procedure TViewPlay.Update(const SecondsPassed: Single; var HandleInput: Boolean);
const
  ProfileBlend = 0.05;
var
  T0, T1, T2, T3, T4, T5, T5a: TTimerResult;
  T4a, T4b, T4c, T4d, T4e: TTimerResult;   { TEMP-DIAG: этапы секции Pose }
  DtWorld, DtBLE, DtRelay, DtPose, DtLabels, DtTotal: Double;
  DtPoseCam, DtPoseCull, DtPoseAnimAv, DtPoseAnimBots, DtPoseMgr, DtPoseAnimRem: Double;
  SceneCount, TotalShapes, ViewportItems, BarrierCount, LevelShapes: Integer;
  I, J: Integer;
  S: TCastleScene;
  ProfileLine: string;
  RelayData: TRelayProfilingData;
  TStart, TAfterInherited, TAfterPhysics, TAfterCheckSync: QWord;
  InheritedMs, PhysicsMs, FrameMs: QWord;
  HeartBeatNow: QWord;
  RiderSit: TRiderSituation;
  CamPosV, CamDirV, CamUpV, CamClampedV: TVector3;   { manual-cam terrain clamp }
  PhysSteps: Integer;
  PhysDt, MetricsDt, CameraDt: Single;
  LocalCadence: Integer;          { каденс аватара → интервал шатуна }
  CrankInt: Single;
  LogRec: TTrainerDataRecord;     { сессия: скорость как на оверлее }
  Accounting:TActivityAccounting;
  AccountingPaused:Boolean;AccountingCurSec,AccountingTotalSec:Integer;
  WuRelease: Boolean;             { холд подготовки маршрута можно снимать }
  WuGroundY: Single;              { высота земли под стартом (RouteStartGroundY) }
  WuPlaceErr: string;             { '' либо текст ошибки постановки на старт }
  FocusRemove:TRemoveType;
begin
  TStart := GetTickCount64;
  if TStart>=FRoomCheckAt then begin
    FRoomCheckAt:=TStart+1000;RideRooms.Update;
    if(FRemoteRiders<>nil)and(FRemoteRiders.RideClient<>nil)and FRemoteRiders.RideClient.PrivateRoom then
      ConnectRideRoom;
  end;

  { The watchdog uses an in-memory heartbeat. Log only a real stall;
    ordinary frames must not pay for periodic file writes. }
  if (FFreezeDiagLastHeartBeat = 0) or
     (TStart - FFreezeDiagLastHeartBeat >= 500) then
  begin
    HeartBeatNow := TStart - FFreezeDiagSessionStart;
    if (FFreezeDiagLastHeartBeat <> 0) and
       (TStart - FFreezeDiagLastHeartBeat >= 1500) then
      Logger.Info(Format('[FREEZE-DIAG] STALL %d ms — main thread blocked (t=%d ms)',
        [TStart - FFreezeDiagLastHeartBeat, HeartBeatNow]));
    { The watchdog reads the in-memory heartbeat. Healthy frames need no
      periodic log line; only a detected stall is written above. }
    FFreezeDiagLastHeartBeat := TStart;
  end;
  { Every Update bumps the alive-marker — even if throttled heart-beat
    line doesn't print, the watchdog still sees us progressing. }
  FreezeDiagMainBeat;

  try
  T0 := Timer;
  if (not Container.Focused) or (Container.FrontView<>Self) or
     (not (FCameraDragButton in Container.MousePressed)) then FCameraDragging:=False;
  if HasActiveState then begin
    if MotionTrace.Requested and (MotionTrace.Target <> Pointer(FActiveAvatarAgent)) then
      MotionTrace.Start(FActiveAvatarAgent);
    MotionTrace.BeginFrame(SecondsPassed);
    FActiveAvatarAgent.TracePosition(mtBegin);
  end;
  PhysDt:=AdvanceSimFrame(SecondsPassed);
  if FFocusPanel<>nil then FFocusPanel.SyncWindow(FFocusMode and(Container.PendingFrontView=Self));
  MotionTrace.Row[3] := PhysDt;
  if SecondsPassed>0 then MainViewport.Items.TimeScale:=PhysDt/SecondsPassed;
  FreezeDiagSetLocation('TViewPlay.Update: before inherited');
  inherited;
  FreezeDiagMainBeat;
  FreezeDiagSetLocation('TViewPlay.Update: after inherited');
  if HasActiveState then FActiveAvatarAgent.TracePosition(mtInherited);
  if FFocusMode then begin
    { The hidden viewport no longer visits scenes, bikes or X3D animation.
      Terrain streaming and shared ride physics still provide valid contact. }
    if Assigned(FOsmStreaming)and Assigned(FOsmStreaming.Session)then begin
      FocusRemove:=rtNone;FOsmStreaming.Session.Map.Update(PhysDt,FocusRemove);
    end;
  end else if FDreamVisual<>nil then FDreamVisual.Update(PhysDt);
  TAfterInherited := GetTickCount64;
  InheritedMs := TAfterInherited - TStart;
  if InheritedMs >= 100 then
    Logger.Info(Format('[FREEZE-DIAG] SLOW inherited Update: %d ms '
      + '(child component Update — incl. TOsm3dStreamingMap.Update)',
      [InheritedMs]));

  CheckSynchronize(0);
  TAfterCheckSync := GetTickCount64;
  if (TAfterCheckSync - TAfterInherited) >= 50 then
    Logger.Info(Format('[FREEZE-DIAG] SLOW CheckSynchronize: %d ms',
      [TAfterCheckSync - TAfterInherited]));

  UpdateAdminPanels;
  RefreshSimPlayer;
  FreezeDiagSetLocation('TViewPlay.Update: after RefreshSimPlayer');

  { 0. Холд подготовки маршрута (стриминг): пока прогрев тайлов + снап,
       запущенные в ApplyCustomTerrainScene, не завершились И земля под
       стартовой точкой не смонтирована — райдер стоит. AutoMove гасим
       КАЖДЫЙ кадр: его норовят включить BLE-фиды, симуляция
       (SetAutoMove(True) в Start) и клавиша P; разовое гашение не
       удержит. Экран ожидания рисует WarmupOverlay карты. Вечного
       ожидания нет: у прогрева есть прерывание по застою, снап-воркер
       завершается и при неуспехе, а у ожидания тайла старта — таймаут
       ~20 с (старт без точной высоты). }
  if FOsmPrepHold then
  begin
    { Плоская карта прогрева остаётся до ПОЛНОЙ готовности старта
      (снап + земля + постановка). Карта стримит вокруг старта независимо
      от камеры; камеру ставим однократно после готовности земли. }

    { Оверлей прогрева — на самый верх UI: пересадка из вьюпорта на
      уровень вью (иначе панель Power/Speed и FX-тогглы закрывают список
      этапов). Только здесь, на кадре ПОСЛЕ Start: во время Start вью ещё
      не в контейнере, и пересадка падает (REGISTERCONTAINER AV). }
    if (not FOsmPrepRaised) and Assigned(FOsmStreaming) then
    begin
      FOsmPrepRaised := True;
      FOsmStreaming.RaiseWarmupToFront(Self);
    end;
    if (not Assigned(FOsmStreaming)) or (not FOsmStreaming.Active) then
    begin
      FOsmPrepHold := False;   { стриминг умер — держать больше нечего }
      Logger.Info('[ViewPlay] StreamingMap: холд снят — стриминг неактивен');
    end
    else
    begin
      { Гейт снятия холда — две фазы:
          1) Map.RoutePrepDone — прогрев тайлов маршрута + снап завершились;
          2) земля под СТАРТОВОЙ точкой смонтирована (RouteStartGroundY):
             только тогда ставим райдера (раньше промежуточный
             InitializeAtStart сажал на Y=0 → скачок камеры).
        Через 20 с после загрузки сцены показываем ошибку поверхности. До появления земли
        движение остаётся на удержании; ESC/меню доступны. }
      WuRelease  := False;
      WuPlaceErr := '';
      if FOsmStreaming.RoutePrepDone and FOsmStreaming.SnapReady then
      begin
        { Ставим райдера только на готовую землю. Таймаут сообщает об
          ошибке, но не разрешает старт в пустоте. }
        if FOsmStreaming.RouteStartGroundY(WuGroundY) then
          WuRelease := True
        else if FOsmPrepGroundSince <> High(QWord) then
        begin
          { A cached route may snap immediately while a large city scene
            still takes tens of seconds to assemble. This is normal loading,
            not a failed surface query. Watch only the start tile, so loading
            unrelated neighbours cannot hide an actual missing surface. }
          if FOsmStreaming.RouteStartGroundLoading then
            FOsmPrepGroundSince := 0
          else if FOsmPrepGroundSince = 0 then
            FOsmPrepGroundSince := GetTickCount64;
          if (FOsmPrepGroundSince <> 0) and
             (GetTickCount64 - FOsmPrepGroundSince >= 20000) then
          begin
            FOsmPrepGroundSince := High(QWord); { report once, still allow recovery }
            WuPlaceErr := UiText('Could not load the ground at the start. ')
              + UiText('Waiting for the map; Esc returns to the menu.');
            if (FOsmStreaming.Session<>nil) and
               (FOsmStreaming.Session.Map<>nil) then
              FOsmStreaming.Session.Map.WarmupFail(5,WuPlaceErr);
            Logger.Info('[ViewPlay] StreamingMap: старт ожидает землю после таймаута');
          end;
        end;
      end;
      if WuRelease then
      begin
        { One decision after initial tile loading, before the ride starts.
          Streaming new tiles or moving the camera never changes this sky. }
        if(FOsmStreaming.Session<>nil)and(FOsmStreaming.Session.Map<>nil)then
          SetCoastalSky(FOsmStreaming.Session.Map.CoastalAtStart);
        ApplySnapWidthsAndLanes;
        FOsmPrepHold := False;
        { Seed the real height before wheel queries: on GPU their first
          answer may arrive later, even though the start tile is ready. }
        if HasActiveState then
          FActiveAvatarAgent.InitializeAtStart(WuGroundY);
        if FBotAgents <> nil then
          for I := 0 to FBotAgents.Count - 1 do
            TPhysicalAgent(FBotAgents[I]).InitializeAtStart(WuGroundY);
        ArrangeLocalRidersAtStart;
        { Transfer streaming back to the camera only after moving it into
          the new world. Normal camera ticks use simulation time and remain
          stopped while the FIT player is paused. }
        if Assigned(FCinematicCam) and FCinematicCam.Enabled then
        begin
          if HasActiveState then
          begin
            FCinematicCam.TargetSpeed := FActiveAvatarAgent.State.CurrentSpeed;
            FCinematicCam.TargetPitchDeg := FActiveAvatarAgent.State.CurrentModelPitch;
          end;
          FCinematicCam.ResetAtTarget;
        end;
        FOsmStreaming.NotifyRiderPlaced(WuPlaceErr);

        if Assigned(FActivePlayerController) and
           (FOsmPrepResumeAutoMove or
            (Assigned(FBLEHud) and FBLEHud.BLEDataValid)) then
          FActivePlayerController.SetAutoMove(True);
        { Симуляция: Start кладёт на паузу; холд тоже держит паузу. После
          прогрева паузу НЕ снимаем сами — Play в UI / MCP sim.play. }
        FOsmPrepDiagUntil := GetTickCount64 + 8000;
        FOsmPrepDiagTick  := 0;
        Logger.Info(Format(
          '[ViewPlay] StreamingMap: можно стартовать — прогрев+снап+земля '
          + 'готовы, райдер Y=%.2f, оверлей снят (AutoMove=%s)',
          [IfThen(HasActiveState,
             FActiveAvatarAgent.State.WorldPosition.Y, 0.0),
           BoolToStr(Assigned(FActivePlayerController)
              and FActivePlayerController.AutoMove, True)]));
      end
      else
      begin
        if Assigned(FActivePlayerController)
           and FActivePlayerController.AutoMove then
          FOsmPrepResumeAutoMove := True;
        StopMoving;
        { Симуляцию не гоняем вперёд, пока плоская карта: cur_sec не
          тикает до «можно стартовать». На снятии холда вернём play,
          если симуляция активна (как AutoMove). }
        if Assigned(DeviceService) and DeviceService.IsSimulationActive then
          DeviceService.SimSetPaused(True);
        if GetTickCount64 >= FOsmPrepHoldLogTick then
        begin
          FOsmPrepHoldLogTick := GetTickCount64 + 5000;
          if FOsmStreaming.RoutePrepDone and FOsmStreaming.SnapReady then
            Logger.Info('[ViewPlay] StreamingMap: плоская карта — '
              + 'ждём землю под стартом (GroundYAt)…')
          else
            Logger.Info('[ViewPlay] StreamingMap: плоская карта — '
              + 'прогрев тайлов + снап… ['
              + FOsmStreaming.RoutePrepStateStr + ']');
        end;
      end;
    end;
  end;

  RestoreActivityRecord;

  { 0b. Пост-релизная диагностика движения (~8 с после снятия холда,
       раз в секунду): если райдер «крутит педали на месте», эти строки
       называют виновника — AutoMove контроллера/State, мощность,
       скорость, позиция, число точек пути. Самоотключается. }
  if FOsmPrepDiagUntil > 0 then
  begin
    if GetTickCount64 >= FOsmPrepDiagUntil then
      FOsmPrepDiagUntil := 0
    else if GetTickCount64 >= FOsmPrepDiagTick then
    begin
      FOsmPrepDiagTick := GetTickCount64 + 1000;
      if HasActiveState then
        Logger.Info(Format('[ViewPlay] StreamingMap: post-hold diag — '
          + 'ctlAuto=%s stAuto=%s power=%.0fW speed=%.2fм/с '
          + 'pos=(%.1f, %.1f, %.1f) pathPts=%d seg=%d t=%.3f',
          [BoolToStr(Assigned(FActivePlayerController)
             and FActivePlayerController.AutoMove, True),
           BoolToStr(FActiveAvatarAgent.State.AutoMove, True),
           FActiveAvatarAgent.State.AppliedPowerWatts,
           FActiveAvatarAgent.State.CurrentSpeed,
           FActiveAvatarAgent.State.WorldPosition.X,
           FActiveAvatarAgent.State.WorldPosition.Y,
           FActiveAvatarAgent.State.WorldPosition.Z,
           FActiveAvatarAgent.Path.PointCount,
           FActiveAvatarAgent.Path.Position.Segment,
           FActiveAvatarAgent.Path.Position.T]))
      else
        Logger.Info('[ViewPlay] StreamingMap: post-hold diag — '
          + 'нет активного агента/State');
    end;
  end;

  { Живой тренажёр / FIT: ватты в контроллер ДО физики.
    Физика читает DesiredPower+AutoMove контроллера, оверлей — сенсоры.
    Раньше push был только у симуляции и стоял ПОСЛЕ физики — аватар
    стоял, а мощность/каденс на HUD уже были. }
  if Assigned(FBLEHud) then
    FBLEHud.UpdateBLETelemetry(FActiveAvatarAgent);
  if Assigned(FActivePlayerController) and HasActiveState then
  begin
    if Assigned(FBLEHud) and FBLEHud.BLEDataValid then
      FActivePlayerController.SetDesiredPower(
        FActiveAvatarAgent.State.AppliedPowerWatts);
    if (not FOsmPrepHold) and Assigned(FBLEHud) and FBLEHud.BLEDataValid and
       (FActiveAvatarAgent.State.AppliedPowerWatts > 0) then
      FActivePlayerController.SetAutoMove(True);
  end;

  { FIT, physical motion and animation share the same playback delta. }
  T1 := Timer;
  FreezeDiagSetLocation('TViewPlay.Update: physics');
  if HasActiveState then FActiveAvatarAgent.TracePosition(mtBeforePhysics);
  PhysSteps := Ceil(PhysDt / FixedTimeStep) + 2;
  if PhysSteps < 4  then PhysSteps := 4;
  if PhysSteps > 64 then PhysSteps := 64;   { верхний предохранитель от спайков }
  try
    if (not FOsmPrepHold) and (PhysDt>0) then
    begin
      UpdateRiderTraffic(FLaneManager,PhysDt);
      if Assigned(FLoopbackSession) then
        FLoopbackSession.Update(PhysDt, FixedTimeStep, PhysSteps)
      else if Assigned(FOfflineWorld) then
        FOfflineWorld.Update(PhysDt, FixedTimeStep, PhysSteps);
    end;
  except
    on E: Exception do
    begin
      FreezeDiagWriteFmt('EXCEPTION in physics: %s — %s',
        [E.ClassName, E.Message]);
      raise;
    end;
  end;
  T2 := Timer;
  FreezeDiagMainBeat;
  FreezeDiagSetLocation('TViewPlay.Update: after physics');
  TAfterPhysics := GetTickCount64;
  PhysicsMs := TAfterPhysics - TAfterCheckSync;
  if PhysicsMs >= 100 then
    Logger.Info(Format('[FREEZE-DIAG] SLOW physics: %d ms', [PhysicsMs]));

  { 1b. Стриминговая карта: один раз перестроить путь на снапнутый
        трек, когда асинхронная привязка к дорожной сети завершится. }
  CheckOsmRouteSnap;
  { 1c. Когда снап готов — прикрепить OSM-ширины к пути и настроить
        менеджер полос на реальную (переменную) ширину дороги. }
  ApplySnapWidthsAndLanes;

  { 2. BLE }
  FBLEHud.UpdateBLETelemetry(FActiveAvatarAgent);
  { Ватты — вход физики; скорость — её результат. Скорость маховика
    тренажёра / запись скорости FIT не учитывает дорогу этой игры.
    Подмешивание её после шага физики гасило ускорение от мощности
    и спуска, а на подъёме могло двигать байк даже без педалирования. }
    if not Assigned(FWorkoutHud) or not FWorkoutHud.ControlsTrainer then
      FBLEHud.UpdateBLETrainerControl(FActiveAvatarAgent, SecondsPassed);

  { Физика читает DesiredPower/AutoMove из контроллера. FIT-сим кормит
    те же слоты сенсоров, что живой тренажёр — отдельных веток нет. }
  if Assigned(FActivePlayerController) and HasActiveState then
  begin
    if FBLEHud.BLEDataValid then
      FActivePlayerController.SetDesiredPower(
        FActiveAvatarAgent.State.AppliedPowerWatts);
    if (not FOsmPrepHold) and FBLEHud.BLEDataValid and
       (FActiveAvatarAgent.State.AppliedPowerWatts > 0) then
      FActivePlayerController.SetAutoMove(True);
  end;


  T3 := Timer;

  { 3. Relay — wrapped in try/except because this is where the freeze
    log obrives: last lines are "Created visual for rider 501" + "No
    config available for rider 501" from RelayThread, immediately
    followed by complete log silence. If an exception during remote-
    rider init is killing the process, this catch will show it. }
  FreezeDiagSetLocation('TViewPlay.Update: Relay UpdateRelayClient');
  try
    FRemoteRiders.UpdateRelayClient(PhysDt,
      FActiveAvatarAgent,
      FBLEHud.BLEDataValid,
      FBLEHud.BLEData, FOsmPrepHold);
  except
    on E: Exception do
    begin
      FreezeDiagWriteFmt('EXCEPTION in Relay: %s — %s',
        [E.ClassName, E.Message]);
      raise;
    end;
  end;
  FreezeDiagMainBeat;
  FreezeDiagSetLocation('TViewPlay.Update: after Relay');


  T4 := Timer;
  if HasActiveState then FActiveAvatarAgent.TracePosition(mtRelay);

  CameraDt:=PhysDt;
  if FFocusMode and HasActiveState then begin
    CamPosV:=FActiveAvatarAgent.State.WorldPosition+Vector3(0,4,-8);
    MainViewport.Camera.SetView(CamPosV,Vector3(0,-0.25,1),Vector3(0,1,0));
  end;
  if not FFocusMode and not ReplaySimCamera(CameraDt) then begin
    { 3a-cam. Camera update by mode (кольцо C: cinematic / third-person / free).
      MCP chase overrides all ring modes while active. }
    if FChaseCamActive then
    begin
      if ThirdPersonNavigation.Avatar <> nil then
        ThirdPersonNavigation.Avatar := nil;
      if Assigned(FCinematicCam) then
        FCinematicCam.Enabled := False;
      ApplyChaseCameraFrame;
    end
    else if FCameraMode = pcmFree then
    begin
      { Свободный полёт: и follow-навигация, и кинематик отсоединены — камерой
        правит клавиатура из FFreeCam.Update; поворот мышью и наезд колесом
        приходят через Motion/Press. }
      if ThirdPersonNavigation.Avatar <> nil then
        ThirdPersonNavigation.Avatar := nil;
      if Assigned(FFreeCam) and Assigned(MainViewport)
         and Assigned(MainViewport.Camera) and Assigned(Container) then
      begin
        FFreeCam.Camera := MainViewport.Camera;
        FFreeCam.Update(Container.Pressed, SecondsPassed);
      end;
    end
    else if Assigned(FCinematicCam) and FCinematicCam.Enabled then
    begin
      { Detach navigation from avatar — prevents it from overriding camera }
      if ThirdPersonNavigation.Avatar <> nil then
        ThirdPersonNavigation.Avatar := nil;
  
      ThirdPersonNavigation.Exists := False;
      FCinematicCam.ClearNearby;
      if Assigned(AvatarTransform) then
      begin
        FRemoteRiders.GetNearbyRiderPositions(
          AvatarTransform.Translation, 30.0, FNearbyBuf, FNearbyBufCount);
        for I := 0 to FNearbyBufCount - 1 do
          FCinematicCam.AddNearby(FNearbyBuf[I]);
      end;
      { Скорость райдера (м/с) — питает сценарий "райдер стоит": ниже ~0.3 м/с
        дольше ~1.5 с камера переключается на медленный облёт (cmOrbit) вместо
        трансляционных ракурсов, которые предполагают движение; поехал — вернётся
        к мото-камере. }
      if Assigned(FActiveAvatarAgent) and Assigned(FActiveAvatarAgent.State) then
      begin
        FCinematicCam.TargetSpeed := FActiveAvatarAgent.State.CurrentSpeed;
        FCinematicCam.TargetPitchDeg := FActiveAvatarAgent.State.CurrentModelPitch;
      end;
      if CameraDt>0 then FCinematicCam.Update(CameraDt);
    end
    else if ThirdPersonNavigation.Avatar = nil then
    begin
      { Re-attach navigation }
      ThirdPersonNavigation.Avatar := SceneAvatar;
      ThirdPersonNavigation.Exists := True;
    end;
  
    { 3a-cam2. Manual (following) camera terrain clamp: the third-person
      navigation orbits the avatar with NO terrain awareness — on a slope the
      "behind + above the rider" point lands INSIDE the hillside. Lift the
      final camera position above the ground under it using the cinematic
      camera's robust floor machinery (seam cross, canopy cap, temporal hold).
      Position-only: the look direction at the avatar is preserved. }
    if (FCameraMode = pcmThirdPerson) and Assigned(FCinematicCam)
       and Assigned(MainViewport) and Assigned(MainViewport.Camera) then
    begin
      MainViewport.Camera.GetView(CamPosV, CamDirV, CamUpV);
      CamClampedV := CamPosV;
      FCinematicCam.ClampCameraAboveGround(CamClampedV);
      { Y lift only (ClampCameraAboveGround) — no XZ building push here. }
      if CamClampedV.Y > CamPosV.Y + 0.001 then
        MainViewport.Camera.SetView(CamClampedV, CamDirV, CamUpV);
    end;
  end;
  CaptureSimCamera;
  if HasActiveState then FActiveAvatarAgent.TracePosition(mtCamera);

  T4a := Timer;   { TEMP-DIAG: конец этапа камеры }

  { 3b. Distance culling — every 15 frames }
  if (FProfileFrameNum mod 15 = 0) then
  begin
    FRemoteRiders.UpdateDistanceCulling;
  end;

  { 3c. Rider list display — every 30 frames }
  if (FProfileFrameNum mod 30 = 0) then
    UpdateRiderList;

  T4b := Timer;   { TEMP-DIAG: конец culling/riderlist }

  { 3d. Per-frame rider bone animation (legs/arms/torso via CPU FK/IK).
    Runs alongside the pedal/crank animation (X3D-route driven by the
    timesensor whose cycle interval is set in UpdateRiderList every 30
    frames). This call must be per-frame — at 30 Hz the rider would
    visibly stutter. AnimateFrame(SecondsPassed) uses the instance's
    captured params and an internal elapsed-time accumulator.
    FPerfAnim=False (MCP perf.set) — весь блок пропускается. }
  if not FFocusMode and (PhysDt>0) and FPerfAnim and Assigned(FBikeInstance) then
  begin
    { Каденс → шатун, скорость → колёса: покадрово и без гейта RideClient —
      иначе в соло-заезде UpdateRiderList не бежит и аватар не педалирует.
      Источник каденса — тот же, что у HUD (DeviceService.Cadence, FIT-сим
      его кормит). БЕЗ гейта BLEDataValid: HasAnySensor может быть ложным
      при живом симе, а BLEData сама даёт 0 при отсутствии данных. }
    LocalCadence := FBLEHud.BLEData.InstantCadence;
    if LocalCadence > 0 then
      CrankInt := 60.0 / LocalCadence
    else
      CrankInt := 9999;  { effectively stopped }
    { BISECT-TEST: сеттеры выключены — проверка, ломают ли они GPU-spin }
    if not CliFlag('nospinset') then
    begin
      FBikeInstance.SetAnimationSpeed(CrankInt, CrankInt);
      if HasActiveState then
        FBikeInstance.SetWheelSpeedMps(FActiveAvatarAgent.State.CurrentSpeed);
    end;
    ApplyTerrainSlopeToBikeShadow;   { tilt contact shadow to the ground under the avatar }
    { Steering angle from path curvature / lean — drives SteerRot + hand IK
      inside AnimateFrame/UpdateTripoRider. Stationary lean-test overrides. }
    if FLeanTestActive then
      ApplyLeanSteerTestFrame(PhysDt)
    else if HasActiveState then
      ApplySteerFromPhysics(FBikeInstance, FActiveAvatarAgent);
    { Select support / departure BEFORE advancing the crank. Use the same
      cadence as the drivetrain: simulation may have data without BLEDataValid. }
    if Assigned(FPoseManager) and HasActiveState then
    begin
      RiderSit.SpeedKmh := FActiveAvatarAgent.State.CurrentSpeed * 3.6;
      RiderSit.PowerW := FActiveAvatarAgent.State.AppliedPowerWatts;
      RiderSit.CadenceRpm := LocalCadence;
      RiderSit.GradePct := SlopeDegToGradePct(FActiveAvatarAgent.State.CurrentSlopeAngle);
      RiderSit.LateralAccel := FActiveAvatarAgent.State.CurrentLateralAccel;
      RiderSit.FtpW := EffectiveRiderProfile.FtpW;
      FPoseManager.Update(PhysDt, RiderSit);
    end;
    FBikeInstance.AnimateFrame(PhysDt);
  end;

  { Frozen poses still move with the physical agent. Keep their sun aligned
    without running IK, deformation or GPU animation updates. }
  if not FFocusMode and (PhysDt>0) and not FPerfAnim and Assigned(FBikeInstance) then
    FBikeInstance.AnimateFrame(Single(0));

  T4c := Timer;   { TEMP-DIAG: конец AnimateFrame аватара }

  { Боты на общем пайплайне: без AnimateFrame их Tripo-райдер не позируется. }
  if not FFocusMode and (PhysDt>0) then
  begin
    UpdateBotPoseManagers(PhysDt);
    AnimateBotBikes(PhysDt);
  end;

  { Shadow LOD ботов: тень (bsmCGE — свой теневой проход) только ближе 50 м. }
  if not FFocusMode then UpdateBotShadowLOD;

  T4d := Timer;   { TEMP-DIAG: конец AnimateBotBikes }



  if not FFocusMode then begin
    if PhysDt>0 then UpdateShadowTestRiders(PhysDt);
    UpdateGroundRiderShadow;
    UpdateRiderGroundShade(PhysDt);
  end;

  T4e := Timer;   { TEMP-DIAG: конец FPoseManager.Update (+ bots) }

  if not FFocusMode and (PhysDt>0) then
    FRemoteRiders.AnimateAllRiders(PhysDt);

  if HasActiveState and FActiveAvatarAgent.State.AutoMove then
    HandleInput := False;

  MetricsDt:=PhysDt;
  if DeviceService.IsSimulationActive then begin
    MetricsDt:=Math.Min(PhysDt,Math.Max(0.0,DeviceService.SimPositionSec-FSimAccountedUntil));
    FSimAccountedUntil:=Math.Max(FSimAccountedUntil,DeviceService.SimPositionSec);
  end;
  SensorLog.RecordingEnabled:=not DeviceService.IsSimulationActive or
    (DeviceService.SimPositionSec>=FSimAccountedUntil);
  SensorLog.UseActivityClock;
  if Assigned(FWorkoutHud) then FWorkoutHud.Step(MetricsDt,not FOsmPrepHold,Container.FrontView=Self);
  Accounting:=Default(TActivityAccounting);
  AccountingPaused:=False;
  if DeviceService.IsSimulationActive then
    DeviceService.SimPlayerInfo(AccountingPaused,AccountingCurSec,AccountingTotalSec);
  if HasActiveState then begin
    { One measured-power snapshot feeds the journal, activity and daily totals.
      A traffic stop does not stop pedalling; cadence is an independent sensor. }
    Accounting:=ActivityAccounting(not FOsmPrepHold and not RideHistory.RestoreNeeded,
      AccountingPaused,WorkoutPlayer.State in[wsReady,wsRunning,wsPaused],
      WorkoutPlayer.State=wsRunning,FActiveAvatarAgent.State.CurrentSpeed,FBLEHud.ReadMeasuredPower);
    SensorLog.SetSessionState(Accounting.Running,WorkoutPlayer.JournalLap,
      EnsureRange(Round(WorkoutPlayer.TargetWatts),0,65535));
    if not FOsmPrepHold and not RideHistory.RestoreNeeded then begin
      LogRec:=FBLEHud.BLEData;
      LogRec.InstantPower:=JournalPower(Accounting.Power);
      LogRec.InstantSpeed:=FActiveAvatarAgent.State.CurrentSpeed*3.6;
      LogRec.Distance:=Round(FActiveAvatarAgent.State.CumulativeDistance);
      SensorLog.LogFrame(LogRec,SlopeDegToGradePct(FActiveAvatarAgent.State.CurrentSlopeAngle),MetricsDt,DeviceService.ActivitySourceFlags);
    end;
  end;
  UpdateRideAudio(SecondsPassed,PhysDt>0);
  if (FWorkoutGates=nil) and (WorkoutPlayer.Plan<>nil) and HasActiveState then
    FWorkoutGates:=TWorkoutGates.Create(FreeAtStop,MainViewport.Items);
  if(FWorkoutGates<>nil)and not FFocusMode then
    FWorkoutGates.Step(WorkoutPlayer,FActiveAvatarAgent,PhysDt,not FOsmPrepHold);
  if HasActiveState then
    RideHistory.Step(MetricsDt,FActiveAvatarAgent.State.CumulativeDistance,
      FActiveAvatarAgent.State.WorldPosition.Y,Accounting.Power.Watts,
      EffectiveRiderProfile.FtpW,Accounting.Running,Accounting.Power.Valid);
  // Integrate once per ride frame even when label rendering is disabled.
  // PhysDt follows FIT playback speed; live trainer time uses speed 1.
  FBLEHud.UpdatePowerMetrics(MetricsDt,Accounting,SecondsPassed);
  SaveActivityCheckpoint;
  CaptureSimCheckpoint;
  FinishMotionTrace;
  { 4. Labels }
  T5a := Timer;
  if not GCliNoLabels then
    FBLEHud.UpdateInfoLabels(FActiveAvatarAgent, FLoopbackSession);
  T5 := Timer;

  { Compute times in ms }
  DtWorld := TimerSeconds(T2, T1) * 1000;
  DtBLE := TimerSeconds(T3, T2) * 1000;
  DtRelay := TimerSeconds(T4, T3) * 1000;
  DtPose  := TimerSeconds(T5a, T4) * 1000;   { боты + позы + райдеры }
  DtLabels := TimerSeconds(T5, T5a) * 1000;  { только HUD-лейблы }
  DtTotal := TimerSeconds(T5, T0) * 1000;
  FFrameLastUpdateMs := DtTotal;

  { TEMP-DIAG: этапы секции Pose }
  DtPoseCam      := TimerSeconds(T4a, T4) * 1000;
  DtPoseCull     := TimerSeconds(T4b, T4a) * 1000;
  DtPoseAnimAv   := TimerSeconds(T4c, T4b) * 1000;
  DtPoseAnimBots := TimerSeconds(T4d, T4c) * 1000;
  DtPoseMgr      := TimerSeconds(T4e, T4d) * 1000;
  DtPoseAnimRem  := TimerSeconds(T5a, T4e) * 1000;

  { Exponential moving average }
  FProf_WorldUpdate := FProf_WorldUpdate * (1 - ProfileBlend) + DtWorld * ProfileBlend;
  FProf_BLE := FProf_BLE * (1 - ProfileBlend) + DtBLE * ProfileBlend;
  FProf_Relay := FProf_Relay * (1 - ProfileBlend) + DtRelay * ProfileBlend;
  FProf_Pose := FProf_Pose * (1 - ProfileBlend) + DtPose * ProfileBlend;
  FProf_PoseCam := FProf_PoseCam * (1 - ProfileBlend) + DtPoseCam * ProfileBlend;
  FProf_PoseCull := FProf_PoseCull * (1 - ProfileBlend) + DtPoseCull * ProfileBlend;
  FProf_PoseAnimAv := FProf_PoseAnimAv * (1 - ProfileBlend) + DtPoseAnimAv * ProfileBlend;
  FProf_PoseAnimBots := FProf_PoseAnimBots * (1 - ProfileBlend) + DtPoseAnimBots * ProfileBlend;
  FProf_PoseMgr := FProf_PoseMgr * (1 - ProfileBlend) + DtPoseMgr * ProfileBlend;
  FProf_PoseAnimRem := FProf_PoseAnimRem * (1 - ProfileBlend) + DtPoseAnimRem * ProfileBlend;
  FProf_Labels := FProf_Labels * (1 - ProfileBlend) + DtLabels * ProfileBlend;
  FProf_FrameTotal := FProf_FrameTotal * (1 - ProfileBlend) + DtTotal * ProfileBlend;

  { TEMP-DIAG PoseDiag stubbed: same FProfileFrameNum=0 trap as PoseMgr —
    3 lines/frame, ~95% of the Castle log. Restore: change False to True. }
  {$if False}
  if (FProfileFrameNum mod 120 = 0) then
  begin
    Logger.Info(Format('[PoseDiag] Pose=%.2f | cam=%.2f cull=%.2f animAv=%.2f bots=%.2f mgr=%.2f animRem=%.2f',
      [FProf_Pose, FProf_PoseCam, FProf_PoseCull, FProf_PoseAnimAv,
       FProf_PoseAnimBots, FProf_PoseMgr, FProf_PoseAnimRem]));
    if Assigned(FBikeInstance) then
      Logger.Info('[PoseDiag] avatar: ' + FBikeInstance.AnimDiag);
    if Assigned(FBotBikes) and (FBotBikes.Count > 0) then
      Logger.Info('[PoseDiag] bot[0]: ' + TBikeInstance(FBotBikes[0]).AnimDiag);
  end;
  {$endif}

  if FProf_HasLastUpdate then
    FProf_Render := FProf_Render * (1 - ProfileBlend) +
      TimerSeconds(T0, FProf_LastUpdateEnd) * 1000 * ProfileBlend;
  FProf_LastUpdateEnd := T5;
  FProf_HasLastUpdate := True;

  { Count active rider scenes }
  SceneCount := 0;
  TotalShapes := 0;
  if Assigned(FBikeInstance) then
  begin
    Inc(SceneCount);
    for I := 0 to BSG_COUNT - 1 do
      if Assigned(FBikeInstance.SubScene(I)) and FBikeInstance.SubScene(I).Exists then
        TotalShapes := TotalShapes + FBikeInstance.SubScene(I).ShapesActiveCount;
  end
  else if Assigned(SceneAvatar) and SceneAvatar.Exists then
  begin
    Inc(SceneCount);
    TotalShapes := TotalShapes + SceneAvatar.ShapesActiveCount;
  end;
  TotalShapes := TotalShapes + FRemoteRiders.CountRemoteShapes;

  RelayData := FRemoteRiders.GetProfilingData;

  ViewportItems := 0;
  BarrierCount := 0;
  LevelShapes := 0;
  if Assigned(MainViewport) then
    ViewportItems := MainViewport.Items.Count;
  if Assigned(SceneLevel) then
    LevelShapes := SceneLevel.ShapesActiveCount;
  for I := 0 to ViewportItems - 1 do
    if MainViewport.Items[I] is TCastleTransformReference then
      Inc(BarrierCount);

  ProfileLine :=
    Format('FPS: %s  Update: %.1fms', [Container.Fps.ToString, FProf_FrameTotal]) + LineEnding +
    Format('World: %.1fms  BLE: %.1fms  Relay: %.1fms  Pose: %.1fms  UI: %.1fms',
      [FProf_WorldUpdate, FProf_BLE, FProf_Relay, FProf_Pose, FProf_Labels]) + LineEnding +
    Format('Riders: %d/%d (%d shapes)  Level: %d shapes',
      [RelayData.VisibleRiders, RelayData.RemoteVisualCount, TotalShapes, LevelShapes]);
    ProfileLine := ProfileLine + LineEnding +
      Format('VP: %d  (streaming map: road in Osm3d tiles)', [ViewportItems]);

  if GLogEnabled then
    ProfileLogFrameDetail;

  { FPS-строка — всегда (оверлей отвязан от /log); детальный
    профильный лог — по-прежнему только под /log. }
  if Assigned(LabelFps) then
    LabelFps.Caption := ProfileLine;

  { FREEZE-DIAG — full-frame timing. If the frame is heavy (>= 250 ms),
    dump the section breakdown straight to trainer.log so we can see WHO
    ate it. Threshold deliberately above normal jitter; in a healthy run
    this line never appears. }
  FrameMs := GetTickCount64 - TStart;
  if FrameMs >= 250 then
    Logger.Info(Format('[FREEZE-DIAG] HEAVY FRAME %d ms — '
      + 'inherited=%d ms physics=%d ms world=%.0f BLE=%.0f relay=%.0f labels=%.0f total=%.0f',
      [FrameMs, InheritedMs, PhysicsMs,
       DtWorld, DtBLE, DtRelay, DtLabels, DtTotal]));
  FreezeDiagSetLocation('TViewPlay.Update: returned (between frames)');
  except
    on E: Exception do
    begin
      { Caught anything bubbling out of Update — physics, stream, BLE.
        Write to the direct file FIRST (immediate FlushFileBuffers, so
        the line survives a process crash), then to Logger.Info, then
        RE-RAISE so the host's default handler sees it and the process
        terminates with its normal crash report. Swallowing would mask
        the bug while leaving the app in a corrupted state. }
      FreezeDiagWriteFmt('EXCEPTION in TViewPlay.Update: %s — %s',
        [E.ClassName, E.Message]);
      try
        Logger.Info(Format('[FREEZE-DIAG] EXCEPTION in TViewPlay.Update: %s — %s',
          [E.ClassName, E.Message]));
      except end;
      raise;
    end;
  end;
end;

procedure TViewPlay.ApplyCameraMode;
begin
  FCameraDragging:=False;
  ThirdPersonNavigation.MouseLook:=False;
  case FCameraMode of
    pcmCinematic:
      begin
        if Assigned(FCinematicCam) then FCinematicCam.Enabled := True;
        { Change ownership immediately: navigation must not write one more
          camera frame before the cinematic controller takes over. }
        ThirdPersonNavigation.Avatar := nil;
        ThirdPersonNavigation.Exists := False;
      end;
    pcmThirdPerson:
      begin
        if Assigned(FCinematicCam) then FCinematicCam.Enabled := False;
        ThirdPersonNavigation.Avatar := SceneAvatar;
        ThirdPersonNavigation.Exists := True;
      end;
    pcmFree:
      begin
        if Assigned(FCinematicCam) then FCinematicCam.Enabled := False;
        { Полностью отключаем follow-навигацию, чтобы она не перехватывала
          WASD и не двигала камеру; камерой правит FFreeCam в Update(). }
        ThirdPersonNavigation.Avatar := nil;
        ThirdPersonNavigation.Exists := False;
        FCameraDragging := False;
        { Заводим свободную камеру из ТЕКУЩЕГО вида — вход в режим без рывка. }
        if Assigned(FFreeCam) and Assigned(MainViewport) then
          FFreeCam.Camera := MainViewport.Camera;
      end;
  end;
end;

procedure TViewPlay.CycleCameraMode;
begin
  case FCameraMode of
    pcmCinematic:   FCameraMode := pcmThirdPerson;
    pcmThirdPerson: FCameraMode := pcmFree;
    pcmFree:        FCameraMode := pcmCinematic;
  end;
  ApplyCameraMode;
end;

procedure TViewPlay.SetCameraMode(const AMode: TPlayCameraMode);
begin
  { Any ring-mode switch drops MCP chase override. }
  FChaseCamActive := False;
  if FCameraMode = AMode then
  begin
    ApplyCameraMode;
    Exit;
  end;
  FCameraMode := AMode;
  ApplyCameraMode;
end;

procedure TViewPlay.SetChaseCamera(AActive: Boolean;
  ADistance: Single; AHeight: Single; ASide: Single; AAimHeight: Single);
begin
  { 0 = top-down over avatar centre (see ApplyChaseCameraFrame). }
  if ADistance < 0 then ADistance := 0;
  if ADistance > 200 then ADistance := 200;
  if AHeight < -20 then AHeight := -20; { diagnostic underside view }
  if AHeight > 80 then AHeight := 80;
  FChaseDist := ADistance;
  FChaseHeight := AHeight;
  FChaseSide := ASide;
  FChaseAimHeight := AAimHeight;
  FChaseCamActive := AActive;
  if AActive then
  begin
    { Detach ring cameras so they don't fight the chase pose. }
    if Assigned(FCinematicCam) then
      FCinematicCam.Enabled := False;
    if Assigned(ThirdPersonNavigation) then
    begin
      ThirdPersonNavigation.Avatar := nil;
      ThirdPersonNavigation.Exists := True;
    end;
    ApplyChaseCameraFrame;
  end
  else
    ApplyCameraMode;   { restore cinematic/thirdperson/free }
end;

function TViewPlay.ChaseCameraActive: Boolean;
begin
  Result := FChaseCamActive;
end;

function TViewPlay.ChaseCameraDistance: Single;
begin
  Result := FChaseDist;
end;

function TViewPlay.ChaseCameraHeight: Single;
begin
  Result := FChaseHeight;
end;

procedure TViewPlay.SetLeanSteerTest(AActive: Boolean;
  ALeanAmpDeg: Single; ASteerAmpDeg: Single; APeriodS: Single);
begin
  FLeanTestActive := AActive;
  if ALeanAmpDeg > 0 then FLeanTestLeanAmpDeg := ALeanAmpDeg;
  if ASteerAmpDeg >= 0 then FLeanTestSteerAmpDeg := ASteerAmpDeg;
  if APeriodS > 0.2 then FLeanTestPeriodS := APeriodS;
  if not AActive then
  begin
    FLeanTestPhase := 0;
    FLeanTestLastLean := 0;
    FLeanTestLastSteer := 0;
    if Assigned(FBikeInstance) then
      FBikeInstance.SteerAngleDeg := 0;
  end;
end;

function TViewPlay.LeanSteerTestActive: Boolean;
begin
  Result := FLeanTestActive;
end;

function TViewPlay.LeanSteerTestLastLeanDeg: Single;
begin
  Result := FLeanTestLastLean;
end;

function TViewPlay.LeanSteerTestLastSteerDeg: Single;
begin
  Result := FLeanTestLastSteer;
end;

procedure TViewPlay.ApplyLeanSteerTestFrame(const SecondsPassed: Single);
var
  Lean, Steer, PitchRad, RollRad: Single;
  BaseRotation, PitchRotation, RollRotation, FinalRotation: TQuaternion;
  AxisAngle: TVector4;
  Sc: TCastleScene;
begin
  if SecondsPassed > 0 then
    FLeanTestPhase := FLeanTestPhase + SecondsPassed;
  if FLeanTestPeriodS > 0.2 then
  begin
    if FLeanTestPhase > FLeanTestPeriodS then
      FLeanTestPhase := FLeanTestPhase - FLeanTestPeriodS
        * Trunc(FLeanTestPhase / FLeanTestPeriodS);
    Lean := FLeanTestLeanAmpDeg
      * Sin(2.0 * Pi * FLeanTestPhase / FLeanTestPeriodS);
    Steer := FLeanTestSteerAmpDeg
      * Sin(2.0 * Pi * FLeanTestPhase / FLeanTestPeriodS);
  end
  else
  begin
    Lean := 0;
    Steer := 0;
  end;
  FLeanTestLastLean := Lean;
  FLeanTestLastSteer := Steer;

  { Bars / SteerRot — same path as ApplySteerFromPhysics. }
  if Assigned(FBikeInstance) then
    FBikeInstance.SteerAngleDeg := Steer;

  { Body roll — force state then re-apply Scene.Rotation (same as
    TCustomActorPhysics.ApplyModelRotation). Physics may have zeroed lean
    this frame because speed/curvature are zero while standing still. }
  if HasActiveState then
  begin
    FActiveAvatarAgent.State.CurrentTurnAngle := Lean;
    FActiveAvatarAgent.State.TargetTurnAngle := Lean;
  end;
  Sc := SceneAvatar;
  if Sc = nil then Exit;
  BaseRotation := QuatFromAxisAngle(Vector3(0, 1, 0), ModelBaseYRotation);
  PitchRad := 0;
  if HasActiveState then
    PitchRad := DegToRad(-FActiveAvatarAgent.State.CurrentModelPitch);
  RollRad := DegToRad(Lean);
  PitchRotation := QuatFromAxisAngle(Vector3(1, 0, 0), PitchRad);
  RollRotation := QuatFromAxisAngle(Vector3(0, 0, 1), RollRad);
  FinalRotation := RollRotation * PitchRotation * BaseRotation;
  AxisAngle := FinalRotation.ToAxisAngle;
  Sc.Rotation := AxisAngle;
end;

procedure TViewPlay.ApplyChaseCameraFrame;
var
  TPos, Fwd, Side, Up, P, LookAt, Dir: TVector3;
  Cam: TCastleCamera;
begin
  if (not FChaseCamActive) or (MainViewport = nil) or (MainViewport.Camera = nil) then
    Exit;
  if AvatarTransform = nil then Exit;
  Cam := MainViewport.Camera;
  TPos := AvatarTransform.Translation;
  Fwd := AvatarTransform.Direction;
  Fwd.Y := 0;
  if Fwd.Length > 0.001 then Fwd := Fwd.Normalize
  else Fwd := Vector3(0, 0, 1);
  Up := Vector3(0, 1, 0);
  Side := TVector3.CrossProduct(Fwd, Up);
  if Side.Length > 0.001 then Side := Side.Normalize
  else Side := Vector3(1, 0, 0);

  if FChaseDist < 0.15 then
  begin
    { Top-down over avatar centre: bars yaw is obvious in plan view.
      Camera Up = rider forward so the bike always points "up" on screen. }
    P := TPos + Up * FChaseHeight + Side * FChaseSide;
    if (FChaseHeight>=0) and Assigned(FCinematicCam) then
      FCinematicCam.ClampCameraAboveGround(P);
    { Aim slightly below the camera so SetView stays well-defined; pure
      -Y look with Up=Fwd keeps north = rider heading. }
    Cam.SetView(P, Vector3(0, -1, 0), Fwd);
    Exit;
  end;

  { Rear chase (cmMoto-style): behind + above (+ optional side). }
  P := TPos - Fwd * FChaseDist + Up * FChaseHeight + Side * FChaseSide;
  if (FChaseHeight>=0) and Assigned(FCinematicCam) then
    FCinematicCam.ClampCameraAboveGround(P);
  LookAt := TPos + Vector3(0, FChaseAimHeight, 0);
  Dir := LookAt - P;
  if Dir.Length < 1e-4 then Dir := Fwd
  else Dir := Dir.Normalize;
  Cam.SetView(P, Dir, Up);
end;

function TViewPlay.Release(const Event: TInputPressRelease): Boolean;
var EndDrag:Boolean;
begin
  // Clear first: UI may consume release after the drag crosses a control.
  EndDrag:=FCameraDragging and Event.IsMouseButton(FCameraDragButton);
  if EndDrag then FCameraDragging:=False;
  Result:=inherited Release(Event) or EndDrag;
end;

function TViewPlay.Motion(const Event: TInputMotion): Boolean;
var Delta:TVector2;
begin
  if not (FCameraDragButton in Event.Pressed) then FCameraDragging:=False;
  Result:=inherited Motion(Event);
  if Result then Exit;
  if not FCameraDragging or (Event.FingerIndex<>0) or not Container.Focused then Exit;
  Delta:=Event.Position-Event.OldPosition;
  if (FCameraMode=pcmFree) and Assigned(FFreeCam) then
    FFreeCam.MouseDragRotate(Delta.X,Delta.Y)
  else if (FCameraMode=pcmThirdPerson) and Assigned(FCamera) then
    FCamera.DragRotate(Delta,FActiveAvatarAgent)
  else Exit;
  Result:=True;
end;

function TViewPlay.Press(const Event: TInputPressRelease): Boolean;
  function AvatarRayCast: TCastleTransform;
  var
    RayResult: TRayCastResult;
  begin
    Result := nil;
    if not Assigned(MainViewport) then Exit;
    if not Assigned(AvatarTransform) then Exit;
    RayResult := MainViewport.Items.PhysicsRayCast(
      AvatarTransform.Translation,
      AvatarTransform.Direction
    );
    Result := RayResult.Transform;
  end;
var
  Hit: TCastleTransform;
  Enemy: TEnemy;
  Command:TRideCommand;
begin
  Result := inherited;
  if Result then Exit;
  if(Container.ForceCaptureInput=nil)and MatchRideCommand(Event,Command)then begin
    if Command=rcFocus then begin ClickTrainingFocus(nil);Exit(True);end;
    if ExecuteRideCommand(Command)then Exit(True);
  end;

  if Event.IsMouseButton(buttonLeft) then
  begin
    if FCameraMode = pcmFree then
    begin
      FCameraDragging := True;
      FCameraDragButton:=buttonLeft;
      Exit(True);
    end;
    PlayShootSound;
    Hit := AvatarRayCast;
    if (Hit <> nil) and (Hit.FindBehavior(TEnemy) <> nil) then
    begin
      Enemy := Hit.FindBehavior(TEnemy) as TEnemy;
      Enemy.Hurt;
    end;
    Exit(true);
  end;

  if Event.IsMouseButton(buttonRight) then
  begin
    if FCameraMode in [pcmThirdPerson,pcmFree] then
    begin FCameraDragging:=True; FCameraDragButton:=buttonRight end;
    Exit(true);
  end;

  { Колесо — наезд/отъезд вдоль взгляда, только в свободном режиме. }
  if (Event.MouseWheel <> mwNone) and (FCameraMode = pcmFree) then
  begin
    if Assigned(FFreeCam) then
      FFreeCam.WheelDolly(Event.MouseWheelScroll);
    Exit(true);
  end;

  if Event.IsKey(keyF5) then
  begin
    Container.SaveScreenToDefaultFile;
    Exit(true);
  end;

  if Event.IsKey(keyEscape) then
  begin
    OpenMenu;
    Exit(True);
  end;

  { Physical L also works with a Russian keyboard layout. UI edit controls
    receive the key first through inherited Press above. }
  if Event.IsKey(keyL) and (Container.CurrentFrontView = Self) and VeloSite.IsAuthorized and
    VeloSite.HasCachedProfile and VeloSite.CachedProfile.IsAdmin then
  begin
    FAdminPanelsHidden := not FAdminPanelsHidden;
    UpdateAdminPanels;
    RefreshSimPlayer;
    Exit(True);
  end;

  { C = следующий режим камеры в кольце: cinematic → third-person → free → … }
  if Event.IsKey(keyC) then
  begin
    CycleCameraMode;
    Exit(true);
  end;

  { V = next cinematic camera mode; когда кинематик не активен —
    цикл режимов FPS (vsync → uncapped → cap 30), как V в Osm3dStudio. }
  if Event.IsKey(keyV) then
  begin
    if Assigned(FCinematicCam) and FCinematicCam.Enabled then
      FCinematicCam.NextMode
    else
      CycleGameFpsMode;
    Exit(true);
  end;

  { B = toggle screen post-processing (bloom + tonemap) — сравнение до/после }
  if Event.IsKey(keyB) then
  begin
    if Assigned(FScreenFX) then
      FScreenFX.Enabled := not FScreenFX.Enabled;
    Exit(true);
  end;

  if Event.IsKey(keyP) then
  begin
    if Assigned(FActivePlayerController) then
      FActivePlayerController.ToggleAutoMove;
    Exit(true);
  end;

  { O = path wobble on/off: periodic L/R carrot sway (meters) so lean+bars
    are obvious while riding. Same live globals as MCP path.wobble / CLI. }
  if Event.IsKey(keyO) then
  begin
    if PathTestWobbleIsEnabled then
    begin
      PathTestWobbleConfigure(False);
      Logger.Info('[PATH] key O: path wobble OFF');
    end
    else
    begin
      PathTestWobbleConfigure(True, 2.5, 6.0);
      Logger.Info(Format(
        '[PATH] key O: path wobble ON (±%.1f m @ %.1f s)',
        [PathTestWobbleGetAmplitudeM, PathTestWobbleGetPeriodS]));
    end;
    Exit(true);
  end;

  if Event.IsKey(keyR) then
  begin
    StopMoving;
    InitializeAtStart;
    Exit(true);
  end;

  if Event.IsKey(keyD) then
  begin
    { В свободном режиме D — это строф вправо (читается покадрово через
      Container.Pressed). Гасим фронт нажатия, чтобы он попутно не
      переключал отладочные коллайдеры. }
    if (FCameraMode <> pcmFree) and HasActiveState then
      FActiveAvatarAgent.ToggleDebugSpheres;
    Exit(true);
  end;

  if Event.IsKey(keyF1) then
  begin
    if HasActiveState then
    begin
      StopMoving;
      FActiveAvatarAgent.RecreatePhysics(pmKinematicCurrent);
      ApplyWheelProbeFromBike;
      FActiveAvatarAgent.Initialize;
      InitializeAtStart;
    end;
    Exit(true);
  end;

  if Event.IsKey(keyF2) then
  begin
    if HasActiveState then
    begin
      StopMoving;
      FActiveAvatarAgent.RecreatePhysics(pmEngineRigidBody);
      ApplyWheelProbeFromBike;
      FActiveAvatarAgent.Initialize;
      InitializeAtStart;
    end;
    Exit(true);
  end;

  if Event.IsKey(keyF9) then
  begin
    ActivateOfflineMode;
    Exit(true);
  end;

  if Event.IsKey(keyF10) then
  begin
    ActivateLoopbackDualWorld;
    Exit(true);
  end;

  if Event.IsKey(keyF11) then
  begin
    RestartLoopbackDualWorld;
    Exit(true);
  end;

  if Event.IsKey(keyF12) then
  begin
    if Assigned(FLoopbackSession) then
      FLoopbackSession.ToggleVisualMode;
    Exit(true);
  end;

  if Event.IsKey(keyNumpadPlus) or Event.IsKey(keyEqual) then
  begin
    if Assigned(DeviceService) and DeviceService.IsSimulationActive then
      Exit(true);
    if Assigned(FActivePlayerController) and HasActiveState then
    begin
      FActiveAvatarAgent.State.AppliedPowerWatts := FActiveAvatarAgent.State.AppliedPowerWatts + PowerStep;
      if FActiveAvatarAgent.State.AppliedPowerWatts > MaxPower then
        FActiveAvatarAgent.State.AppliedPowerWatts := MaxPower;

      FActivePlayerController.SetDesiredPower(FActiveAvatarAgent.State.AppliedPowerWatts);

      if Assigned(SliderPower) then
        SliderPower.Value := FActiveAvatarAgent.State.AppliedPowerWatts;
    end;
    Exit(true);
  end;

  { ── Terrain texture cycling with ' \ ── }
  if Event.IsKey(keyApostrophe) then
  begin
    if Assigned(FTerrainTextureFolders) and (FTerrainTextureFolders.Count > 0) then
    begin
      Dec(FTerrainTextureIndex);
      if FTerrainTextureIndex < -1 then
        FTerrainTextureIndex := FTerrainTextureFolders.Count - 1;
      if FTerrainTextureIndex = -1 then
      begin
        SceneLevel.Exists := False;
        Logger.Info('[Terrain] ' + 'Terrain HIDDEN');
      end else begin
        SceneLevel.Exists := True;
        ApplyTerrainTextureByIndex(FTerrainTextureIndex);
      end;
    end;
    Exit(true);
  end;

  if Event.IsKey(keyBackSlash) then
  begin
    if Assigned(FTerrainTextureFolders) and (FTerrainTextureFolders.Count > 0) then
    begin
      Inc(FTerrainTextureIndex);
      if FTerrainTextureIndex >= FTerrainTextureFolders.Count then
        FTerrainTextureIndex := -1;
      if FTerrainTextureIndex = -1 then
      begin
        SceneLevel.Exists := False;
        Logger.Info('[Terrain] ' + 'Terrain HIDDEN');
      end else begin
        SceneLevel.Exists := True;
        ApplyTerrainTextureByIndex(FTerrainTextureIndex);
      end;
    end;
    Exit(true);
  end;

  if Event.IsKey(keyNumpadMinus) or Event.IsKey(keyMinus) then
  begin
    if Assigned(DeviceService) and DeviceService.IsSimulationActive then
      Exit(true);
    if Assigned(FActivePlayerController) and HasActiveState then
    begin
      FActiveAvatarAgent.State.AppliedPowerWatts := FActiveAvatarAgent.State.AppliedPowerWatts - PowerStep;
      if FActiveAvatarAgent.State.AppliedPowerWatts < MinPower then
        FActiveAvatarAgent.State.AppliedPowerWatts := MinPower;

      FActivePlayerController.SetDesiredPower(FActiveAvatarAgent.State.AppliedPowerWatts);

      if Assigned(SliderPower) then
        SliderPower.Value := FActiveAvatarAgent.State.AppliedPowerWatts;
    end;
    Exit(true);
  end;
end;

procedure TViewPlay.PlayShootSound;
begin
  SoundEngine.Play(SoundEngine.SoundFromName('shoot_sound'));
end;

procedure TViewPlay.ChangePower(Sender: TObject);
begin
  if Assigned(DeviceService) and DeviceService.IsSimulationActive then
    Exit;
  if Assigned(SliderPower) and Assigned(FActivePlayerController) and HasActiveState then
  begin
    FActiveAvatarAgent.State.AppliedPowerWatts := SliderPower.Value;
    FActivePlayerController.SetDesiredPower(SliderPower.Value);
  end;
end;

{ ── Sim player widget ─────────────────────────────────────────────── }

procedure TViewPlay.ClearSimReplay;
begin
  FinishSimCameraReplay;
  FSimCameraShotSerial:=0;
  FSimCameraViewTime:=-1;
  if FSimHistory<>nil then FSimHistory.Clear;
  FSimAccountedUntil:=0;
  if Assigned(DeviceService) then FSimLoopSerial:=DeviceService.SimLoopSerial;
  if Assigned(MainViewport) then MainViewport.Items.TimeScale:=1;
  WindSetPlaybackTime(-1);
  CompositeShaderSetPlaybackTime(-1);
  if GFpsSimFrameHold then begin GFpsSimFrameHold:=False; ApplyGameFpsMode end;
end;

procedure TViewPlay.ShowSimCameraFrame(const Frame: TSimCameraFrame);
begin
  FSimCameraViewTime:=Frame.Seconds;
  FCameraMode:=TPlayCameraMode(Frame.CameraMode);
  FChaseCamActive:=Frame.Chase;
  FCameraDragging:=False;
  ThirdPersonNavigation.MouseLook:=False;
  ThirdPersonNavigation.Avatar:=nil;
  ThirdPersonNavigation.Exists:=False;
  if Assigned(FCinematicCam) then
    FCinematicCam.ShowRecordedView(Frame.Position,Frame.Direction,Frame.Up,
      Frame.CinematicMode,Frame.PendingMode)
  else MainViewport.Camera.SetView(Frame.Position,Frame.Direction,Frame.Up);
  if Frame.FieldOfView>0 then MainViewport.Camera.Perspective.FieldOfView:=Frame.FieldOfView;
end;

procedure TViewPlay.FinishSimCameraReplay;
var Frame: TSimCameraFrame;
begin
  if not FSimCameraReplaying then Exit;
  FSimCameraReplaying:=False;
  if (FSimHistory=nil) or (FSimHistory.CameraTrack.Count=0) then Exit;
  Frame:=FSimHistory.CameraTrack.Last;
  FSimCameraViewTime:=Frame.Seconds;
  FCameraMode:=TPlayCameraMode(Frame.CameraMode);
  FChaseCamActive:=Frame.Chase;
  FChaseDist:=FSimHistory.CameraEndChase.X;
  FChaseHeight:=FSimHistory.CameraEndChase.Y;
  FChaseSide:=FSimHistory.CameraEndChase.Z;
  FChaseAimHeight:=FSimHistory.CameraEndChase.W;
  ApplyCameraMode;
  if Assigned(FCinematicCam) then FCinematicCam.RestoreReplay(FSimHistory.CameraEndState);
  MainViewport.Camera.SetView(Frame.Position,Frame.Direction,Frame.Up);
  if Frame.FieldOfView>0 then MainViewport.Camera.Perspective.FieldOfView:=Frame.FieldOfView;
  FSimCameraShotSerial:=FSimHistory.CameraEndState.ShotSerial;
  RandSeed:=FSimHistory.CameraEndSeed;
end;

function TViewPlay.ReplaySimCamera(var CameraDt: Single): Boolean;
var Frame: TSimCameraFrame; Time: Double;
begin
  Result:=False;
  if not FSimCameraReplaying or (FSimHistory=nil) then Exit;
  Time:=DeviceService.SimPositionSec;
  if DeviceService.IsSimulationActive and FSimHistory.CameraTrack.Sample(Time,Frame) then begin
    ShowSimCameraFrame(Frame); Exit(True);
  end;
  { Cross the recording boundary with only the unrecorded part of this
    frame's delta, continuing the saved shot and its original timer. }
  CameraDt:=Math.Min(CameraDt,Math.Max(0.0,Time-FSimHistory.CameraTrack.Latest));
  FinishSimCameraReplay;
end;

procedure TViewPlay.CaptureSimCamera;
var Frame,Previous: TSimCameraFrame; State: TCameraReplayState; DT: Double;
begin
  if (FSimHistory=nil) or FSimCameraReplaying or FOsmPrepHold or
    not HasActiveState or not DeviceService.IsSimulationActive then Exit;
  Frame:=Default(TSimCameraFrame);
  Frame.Seconds:=DeviceService.SimPositionSec;
  MainViewport.Camera.GetView(Frame.Position,Frame.Direction,Frame.Up);
  Frame.FieldOfView:=MainViewport.Camera.Perspective.FieldOfView;
  Frame.CameraMode:=Ord(FCameraMode); Frame.Chase:=FChaseCamActive;
  Frame.CinematicMode:=-1; Frame.PendingMode:=-1;
  State:=Default(TCameraReplayState);
  if Assigned(FCinematicCam) then begin
    State:=FCinematicCam.CaptureReplay;
    Frame.CinematicMode:=Ord(State.Shot.Mode);
    Frame.PendingMode:=FCinematicCam.PendingMode;
    Frame.CutBefore:=(FCameraMode=pcmCinematic) and (State.ShotSerial<>FSimCameraShotSerial);
  end;
  if FSimHistory.CameraTrack.Count>0 then begin
    Previous:=FSimHistory.CameraTrack.Last;
    DT:=Math.Max(0.0,Frame.Seconds-Previous.Seconds);
    { Explicit teleports in free/chase mode also must not become a fly-through. }
    Frame.CutBefore:=Frame.CutBefore or
      ((Frame.Position-Previous.Position).Length>Math.Max(8.0,DT*80)) or
      (TVector3.DotProduct(Frame.Direction,Previous.Direction)<0.5);
  end;
  if FSimHistory.CameraTrack.Append(Frame) then begin
    FSimCameraViewTime:=Frame.Seconds;
    FSimCameraShotSerial:=State.ShotSerial;
    FSimHistory.CameraEndState:=State;
    FSimHistory.CameraEndChase:=Vector4(FChaseDist,FChaseHeight,FChaseSide,FChaseAimHeight);
    FSimHistory.CameraEndSeed:=RandSeed;
  end;
end;

procedure TViewPlay.FinishMotionTrace;
var S: TPhysicsState; P, D, U, R: TVector3;
begin
  if not HasActiveState or (MotionTrace.Target <> Pointer(FActiveAvatarAgent)) then Exit;
  S := FActiveAvatarAgent.State;
  FActiveAvatarAgent.TracePosition(mtEnd);
  with MotionTrace do begin
    Row[4] := -1;
    if DeviceService.IsSimulationActive then Row[4] := DeviceService.SimPositionSec;
    Row[5] := S.SimulationTime;
    Row[6] := FActiveAvatarAgent.Path.Position.Segment;
    Row[7] := FActiveAvatarAgent.Path.Position.T;
    Row[8] := S.CurrentSpeed; Row[9] := S.CurrentRoadWidth;
    Row[10] := S.LaneOffset;
    Row[11] := FActiveAvatarAgent.Path.LastLaneOffsetM;
    Row[12] := FActiveAvatarAgent.Path.LastWobbleOffsetM;
    Row[13] := S.CumulativeDistance; Row[14] := S.AccumulatedTime;
    Row[15] := S.CurrentYawRad; Row[16] := S.CurrentModelPitch; Row[17] := S.CurrentTurnAngle;
    Row[18] := Ord(FActiveAvatarAgent.NetworkAuthority);
    Row[19] := Ord(FActiveAvatarAgent.PhysicsMode);
    Row[20] := Ord(FCameraMode)*10;
    if FChaseCamActive then Row[20] := 30
    else if Assigned(FCinematicCam) then Row[20] := Row[20]+Ord(FCinematicCam.Mode);
    if Assigned(FCinematicCam) then Row[21] := FCinematicCam.ShotSerial;
    Row[22] := Ord(FSimCameraReplaying);
    Row[28] := S.ForwardDir.X; Row[29] := S.ForwardDir.Y; Row[30] := S.ForwardDir.Z;
    Row[31] := S.MovementVelocity.X; Row[32] := S.MovementVelocity.Y; Row[33] := S.MovementVelocity.Z;
    R := FActiveAvatarAgent.Path.LastCarrotWorld;
    Row[34] := R.X; Row[35] := R.Y; Row[36] := R.Z;
    R := FActiveAvatarAgent.Path.RoadCenterAt(FActiveAvatarAgent.Path.Position);
    Row[37] := R.X; Row[38] := R.Y; Row[39] := R.Z;
    MainViewport.Camera.GetView(P,D,U);
    Row[40] := D.X; Row[41] := D.Y; Row[42] := D.Z;
    Row[43] := U.X; Row[44] := U.Y; Row[45] := U.Z;
    Row[46] := MainViewport.Camera.Perspective.FieldOfView;
    if FActiveAvatarAgent.Actor.Scene <> nil then begin
      R := FActiveAvatarAgent.Actor.Scene.WorldTranslation;
      Row[48] := R.X; Row[49] := R.Y; Row[50] := R.Z;
    end;
    if Assigned(FBikeInstance) and Assigned(FBikeInstance.RiderScene) then begin
      R := FBikeInstance.RiderScene.WorldTranslation;
      Row[51] := R.X; Row[52] := R.Y; Row[53] := R.Z;
    end;
    R := FActiveAvatarAgent.Actor.Transform.Direction;
    Row[54] := R.X; Row[55] := R.Y; Row[56] := R.Z;
    R := FActiveAvatarAgent.Actor.Transform.Up;
    Row[57] := R.X; Row[58] := R.Y; Row[59] := R.Z;
  end;
end;

procedure TViewPlay.CaptureSimCheckpoint;
var C: TSimCheckpoint; I: Integer;
  procedure AddAgent(Ag: TPhysicalAgent);
  var N: Integer;
  begin
    if (Ag=nil) or (Ag.State=nil) or (Ag.Path=nil) then Exit;
    N:=Length(C.Agents); SetLength(C.Agents,N+1);
    C.Agents[N].Agent:=Ag;
    C.Agents[N].NetworkId:=Ag.NetworkId;
    C.Agents[N].PointCount:=Ag.Path.PointCount;
    C.Agents[N].State:=Ag.CaptureReplay;
  end;
begin
  if (FSimHistory=nil) or FOsmPrepHold or (not HasActiveState) or
    (not DeviceService.IsSimulationActive) or (FActiveAvatarAgent.Path.PointCount<2) then Exit;
  if not FSimHistory.NeedsSample(DeviceService.SimPositionSec) then Exit;
  if FSimHistory.Count=0 then begin
    { Place the paused opening frame too: neither pose nor camera has had
      an advancing Update yet. Zero delta does not consume playback time. }
    if Assigned(FBikeInstance) then FBikeInstance.AnimateFrame(Single(0));
    if Assigned(FCinematicCam) then FCinematicCam.Update(0);
  end;
  C:=TSimCheckpoint.Create;
  try
    C.Seconds:=DeviceService.SimPositionSec;
    if Assigned(FLaneManager) then C.Lanes:=FLaneManager.CaptureReplay;
    AddAgent(FActiveAvatarAgent);
    if Assigned(FBotAgents) then
      for I:=0 to FBotAgents.Count-1 do AddAgent(TPhysicalAgent(FBotAgents[I]));
    if Assigned(FBikeInstance) then begin C.HasBike:=True; C.Bike:=FBikeInstance.CaptureReplay end;
    if Assigned(FPoseManager) then begin C.HasPose:=True; C.Pose:=FPoseManager.CaptureReplay end;
    if Assigned(FCinematicCam) then begin C.HasCamera:=True; C.Camera:=FCinematicCam.CaptureReplay end;
    C.CameraMode:=Ord(FCameraMode);
    MainViewport.Camera.GetView(C.CameraPosition,C.CameraDirection,C.CameraUp);
    C.RandomSeed:=RandSeed;
    FSimHistory.Add(C);
  except C.Free; raise end;
end;

procedure TViewPlay.RestoreSimCheckpoint(var Seconds: Double);
var C: TSimCheckpoint; I,J: Integer; Ag: TPhysicalAgent; Frame: TSimCameraFrame;
begin
  if (FSimHistory=nil) or FOsmPrepHold then begin Seconds:=DeviceService.SimPositionSec; Exit end;
  C:=FSimHistory.Find(Seconds);
  if GameSound<>nil then GameSound.ResetContacts;
  FAudioSampleTimer:=0;
  if C=nil then begin Seconds:=0; Exit end;
  { A route replacement invalidates its indices. Do not restore old indices
    into a newly snapped or loaded path. }
  if not HasActiveState or (Length(C.Agents)=0) or
    (C.Agents[0].Agent<>FActiveAvatarAgent) or
    (C.Agents[0].PointCount<>FActiveAvatarAgent.Path.PointCount) then begin
    FSimHistory.Clear; Seconds:=DeviceService.SimPositionSec; Exit;
  end;
  for I:=0 to High(C.Agents) do begin
    Ag:=nil;
    if C.Agents[I].Agent=FActiveAvatarAgent then Ag:=FActiveAvatarAgent
    else if Assigned(FBotAgents) then
      for J:=0 to FBotAgents.Count-1 do
        if C.Agents[I].Agent=TPhysicalAgent(FBotAgents[J]) then begin Ag:=TPhysicalAgent(FBotAgents[J]); Break end;
    if (Ag<>nil) and (Ag.NetworkId=C.Agents[I].NetworkId) and
      (Ag.Path.PointCount=C.Agents[I].PointCount) then Ag.RestoreReplay(C.Agents[I].State);
  end;
  if Assigned(FActivePlayerController) then begin
    FActivePlayerController.SetDesiredPower(FActiveAvatarAgent.State.AppliedPowerWatts);
    FActivePlayerController.SetAutoMove(FActiveAvatarAgent.State.AutoMove);
  end;
  if C.HasPose and Assigned(FPoseManager) then FPoseManager.RestoreReplay(C.Pose);
  if HasActiveState then RideHistory.RebaseDistance(FActiveAvatarAgent.State.CumulativeDistance);
  if Assigned(FLaneManager) then FLaneManager.RestoreReplay(C.Lanes);
  if C.HasBike and Assigned(FBikeInstance) then FBikeInstance.RestoreReplay(C.Bike);
  FCameraMode:=TPlayCameraMode(C.CameraMode);
  ApplyCameraMode;
  if C.HasCamera and Assigned(FCinematicCam) then FCinematicCam.RestoreReplay(C.Camera);
  MainViewport.Camera.SetView(C.CameraPosition,C.CameraDirection,C.CameraUp);
  RandSeed:=C.RandomSeed;
  Seconds:=C.Seconds;
  FSimCameraReplaying:=FSimHistory.CameraTrack.Sample(Seconds,Frame);
  if FSimCameraReplaying then ShowSimCameraFrame(Frame);
  WindSetPlaybackTime(Seconds);
  CompositeShaderSetPlaybackTime(Seconds);
  CompositeShaderTickAll(0);
end;

function TViewPlay.AdvanceSimFrame(RealSeconds: Single): Single;
var SimActive,Paused,HoldFrame: Boolean; CurSec,TotalSec: Integer;
begin
  Result:=RealSeconds;
  SimActive:=Assigned(DeviceService) and DeviceService.IsSimulationActive;
  HoldFrame:=False;
  if SimActive then begin
    if FSimLoopSerial<>DeviceService.SimLoopSerial then ClearSimReplay;
    CaptureSimCheckpoint;
    if FOsmPrepHold then begin Result:=0; DeviceService.SimPublishCurrent end
    else Result:=DeviceService.SimAdvance(RealSeconds);
    if FSimLoopSerial<>DeviceService.SimLoopSerial then ClearSimReplay;
    WindSetPlaybackTime(DeviceService.SimPositionSec);
    CompositeShaderSetPlaybackTime(DeviceService.SimPositionSec);
    DeviceService.SimPlayerInfo(Paused,CurSec,TotalSec);
    HoldFrame:=(DeviceService.SimGetSpeed<=SimFrameSeconds+0.000001) and
      (not Paused) and (not FOsmPrepHold) and (Container.FrontView=Self);
  end else begin
    WindSetPlaybackTime(-1);
    CompositeShaderSetPlaybackTime(-1);
  end;
  if GFpsSimFrameHold<>HoldFrame then begin GFpsSimFrameHold:=HoldFrame; ApplyGameFpsMode end;
end;

procedure TViewPlay.BuildSimPlayer;
  function Button(const AName,Text: String; X,W: Single; Click: TNotifyEvent): TCastleButton;
  begin
    Result:=TMenuButton.Create(FreeAtStop); Result.Name:=AName;
    BindUiText(Result,Text); Result.OnClick:=Click;
    Result.Anchor(hpLeft,X); Result.Anchor(vpTop,-6);
    Result.AutoSize:=False; Result.Width:=W; Result.Height:=32;
    Result.FontSize:=15;
    FSimPanel.InsertFront(Result);
  end;
begin
  FSimPanel:=TCastleRectangleControl.Create(FreeAtStop);
  FSimPanel.Name:='SimPlayer';
  FSimPanel.Color:=Vector4(0.05,0.05,0.10,0.88);
  FSimPanel.FullSize:=False; FSimPanel.Width:=600; FSimPanel.Height:=78;
  FSimPanel.Anchor(hpLeft,12); FSimPanel.Anchor(vpBottom,12);
  FSimPanel.Exists:=False; InsertFront(FSimPanel);
  FSimBtnReset:=Button('SimRestart','|<',6,38,@ClickSimReset);
  FSimBtnBack:=Button('SimBack','-5 s',48,56,@ClickSimBack);
  FSimBtnPause:=Button('SimPause','>',108,38,@ClickSimPause);
  FSimBtnStep:=Button('SimStep','>|',150,38,@ClickSimStep);
  FSimBtnSlow:=Button('SimSlower','<<',200,38,@ClickSimSlow);
  FSimBtnFwd:=Button('SimFaster','>>',332,38,@ClickSimFwd);
  FSimBtnReset.Tooltip:=UiText('Return to the start');
  FSimBtnBack.Tooltip:=UiText('Rewind 5 seconds');
  FSimBtnPause.Tooltip:=UiText('Pause / resume');
  FSimBtnStep.Tooltip:=UiText('Advance one frame (1/60 s)');
  FSimBtnSlow.Tooltip:=UiText('Slower, down to 1 frame/s');
  FSimBtnFwd.Tooltip:=UiText('Faster, up to 8x');
  FSimRate:=TCastleLabel.Create(FreeAtStop); FSimRate.FontSize:=14;
  FSimRate.Color:=Vector4(0.9,0.9,0.9,1);
  FSimRate.Anchor(hpLeft,248); FSimRate.Anchor(vpTop,-15);
  FSimPanel.InsertFront(FSimRate);
  FSimTime:=TCastleLabel.Create(FreeAtStop); FSimTime.FontSize:=14;
  FSimTime.Color:=Vector4(0.9,0.9,0.9,1);
  FSimTime.Anchor(hpRight,-10); FSimTime.Anchor(vpTop,-15);
  FSimPanel.InsertFront(FSimTime);
  FSimSeek:=TCastleFloatSlider.Create(FreeAtStop); FSimSeek.Name:='SimSeek';
  FSimSeek.Min:=0; FSimSeek.Max:=1; FSimSeek.Value:=0;
  FSimSeek.DisplayValue:=False;
  FSimSeek.Tooltip:=UiText('Seek within the recorded ride');
  FSimSeek.Width:=580; FSimSeek.Height:=24;
  FSimSeek.Anchor(hpLeft,10); FSimSeek.Anchor(vpBottom,6);
  FSimSeek.OnChange:=@ChangeSimSeek;
  FSimPanel.InsertFront(FSimSeek);
  FSimStatus:=TCastleLabel.Create(FreeAtStop); FSimStatus.Name:='SimStatus';
  FSimStatus.FontSize:=14; FSimStatus.Color:=Vector4(0.95,0.8,0.5,1);
  FSimStatus.Anchor(hpLeft,10); FSimStatus.Anchor(vpBottom,10);
  BindUiText(FSimStatus,'Simulation unavailable. Choose a valid FIT in Devices.');
  FSimStatus.Exists:=False;
  FSimPanel.InsertFront(FSimStatus);
end;

procedure TViewPlay.RefreshSimPlayer;
  function FmtSec(Seconds: Double): String;
  var MS: Int64;
  begin
    MS:=Max(0,Round(Seconds*1000));
    Result:=Format('%.2d:%.2d.%.3d',[MS div 60000,(MS div 1000) mod 60,MS mod 1000]);
  end;
var SimActive,Paused: Boolean; CurSec,TotalSec: Integer; Rate: Single;
begin
  if FSimPanel=nil then Exit;
  SimActive:=Assigned(DeviceService) and DeviceService.SimPlayerInfo(Paused,CurSec,TotalSec);
  FSimPanel.Exists:=Settings.GetSimulationEnabled and not FFocusMode;
  if not FSimPanel.Exists then Exit;
  if Assigned(FWorkoutHud) and FWorkoutHud.Exists then
    FSimPanel.Anchor(vpBottom,FWorkoutHud.EffectiveHeight+12)
  else FSimPanel.Anchor(vpBottom,12);
  FSimStatus.Exists:=not SimActive;
  FSimTime.Exists:=SimActive; FSimRate.Exists:=SimActive;
  FSimBtnReset.Enabled:=SimActive and not FOsmPrepHold;
  FSimBtnPause.Enabled:=SimActive and not FOsmPrepHold;
  if not SimActive then
  begin
    FSimBtnBack.Enabled:=False; FSimBtnStep.Enabled:=False;
    FSimBtnSlow.Enabled:=False; FSimBtnFwd.Enabled:=False;
    FSimSeek.Exists:=False;
    Exit;
  end;
  if Paused then FSimBtnPause.Caption:='>' else FSimBtnPause.Caption:='II';
  Rate:=DeviceService.SimGetSpeed;
  if Rate<=SimFrameSeconds+0.000001 then FSimRate.Caption:=UiText('1 frame/s')
  else if Rate<1 then FSimRate.Caption:='1/'+IntToStr(Round(1/Rate))+'x'
  else FSimRate.Caption:=Format('%gx',[Rate]);
  FSimBtnSlow.Enabled:=Rate>SimFrameSeconds+0.000001;
  FSimBtnFwd.Enabled:=Rate<8;
  FSimTime.Caption:=FmtSec(DeviceService.SimPositionSec)+' / '+Format('%.2d:%.2d',[TotalSec div 60,TotalSec mod 60]);
  FSimSeekUpdating:=True;
  try
    FSimSeek.Max:=Math.Max(1.0,FSimHistory.Latest);
    FSimSeek.Value:=Math.Min(FSimSeek.Max,DeviceService.SimPositionSec);
    FSimSeek.Exists:=(FSimHistory.Count>1) and not FOsmPrepHold;
  finally FSimSeekUpdating:=False end;
  FSimBtnBack.Enabled:=FSimSeek.Exists;
  FSimBtnStep.Enabled:=not FOsmPrepHold;
end;

procedure TViewPlay.ClickSimPause(Sender: TObject);
begin DeviceService.SimTogglePause end;
procedure TViewPlay.ClickSimReset(Sender: TObject);
begin DeviceService.SimRestart end;
procedure TViewPlay.ClickSimFwd(Sender: TObject);
begin DeviceService.SimCycleSpeed end;
procedure TViewPlay.ClickSimSlow(Sender: TObject);
begin DeviceService.SimCycleSpeed(True) end;
procedure TViewPlay.ClickSimBack(Sender: TObject);
begin DeviceService.SimSeekSec(DeviceService.SimPositionSec-5) end;
procedure TViewPlay.ClickSimStep(Sender: TObject);
begin DeviceService.SimStepFrame end;
procedure TViewPlay.ChangeSimSeek(Sender: TObject);
begin
  if not FSimSeekUpdating then begin
    DeviceService.SimSetPaused(True);
    DeviceService.SimSeekSec(FSimSeek.Value);
  end;
end;


finalization
  {$IFDEF MSWINDOWS}
  if GFpsTimerPeriodActive then timeEndPeriod(1);
  {$ENDIF}
end.
