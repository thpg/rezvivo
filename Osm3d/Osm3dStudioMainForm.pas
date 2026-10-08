unit Osm3dStudioMainForm;

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$codepage UTF8}

{$WARN 5024 OFF}

{$DEFINE OSM3D_WITH_FITFILE}

interface

uses UiTranslations,
  fpjson,
  Classes,
  SysUtils,
  Osm3dStudioViewState,
  Osm3dStudioPhotoCompare, Osm3dPhotoViewRender,
  Osm3dVegetationBudget,
  FileUtil,        { DeleteDirectory для --reset-tiles }
  Forms,
  Controls,
  StdCtrls,
  ExtCtrls,
  ComCtrls,
  Dialogs,
  Menus,
  Graphics,
  Generics.Collections,
  SyncObjs,
  Math,
  CastleVectors,
  CastleImages,          { TRGBImage/SaveImage — сохранение кадра GL }
  CastleRectangles,      { Rectangle — rect для SaveScreen }
  CastleScene,
  X3DNodes,              { TX3DRootNode/TBoxNode for the empty-scene diagnostic }
  CastleControl,
  CastleViewport,
  CastleRenderOptions,   { TShapeSort (sort3D) for Viewport.OcclusionSort }
  CastleCameras,
  CastleTransform,
  CastleKeysMouse,
  CastleUIControls,
  CastleControls,
  CastleApplicationProperties,
  CastleLog,
  GameScreenFX,          { TScreenFX: та же FX-дальность тумана, что и в игре
                           (депт-шейдер покрывает и raw-GL растительность —
                           её импортирует и студия, см. Osm3dRenderInstanced) }
  Osm3dGeoMath,
  Osm3dProfiler,
  Osm3dRenderInstanced,
  Osm3dRoadMaterial,
  Osm3dRiderShadow,
  Osm3dImpostorCache, Osm3dSunSky,
  Osm3dMapUtils,
  Osm3dStudioLog,
  Osm3dStudioController,
  Osm3dStudioUtils,
  Osm3dStudioEndpointPanel,
  Osm3dStudioSettings,
  Osm3dStreamingLauncher,
  Osm3dSlippyMap,
  Osm3dCache,
  Osm3dCacheHTTPFetcher,
  Osm3dGeoTileGrid,      { TGeoTileId — тайлы сверки высот }
  Osm3dGeoTileCache,     { TGeoTileCache — чтение тайлов прогрева с диска }
  Osm3dTileX3D,          { TTileModel — меши тайла }
  Osm3dGeomMesh,         { TMesh, TMeshVertexArray — вершины тайла }
  Osm3dSceneMaterials,   { TSceneMaterialKind (smk*) — фильтр ground-мешей }
  RideParamEstimator,    { TRideSampleArray — одометрия FIT }
  FitFile,               { TFitFile — перечитка FIT (одометрия, статистика) }
  GpxFile,               { общий выбор парсера FIT/GPX }
  Osm3dDemProfile,        { высоты из DEM для маршрутов без altitude/ele }
  Osm3dFitCorrection,    { TFitCorrection — клон профиля для фоновой сверки }
  Osm3dGeoLocate,
  Osm3dGeocode,        { TGeoHit — тип в обработчике OnPlacePicked }
  Osm3dSearchWidget    { TOsm3dSearchWidget — виджет поиска места }
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
;

type
  { WASD+EQ flight, arrow rotate, mouse drag rotate, wheel dolly. }
  { Three genuinely distinct render-pacing modes cycled by the V key.
    Without toggling vsync itself, "unlimited" and "limited 60" both
    just hit the driver's 60 Hz vsync cap — indistinguishable. So we
    drive the real OpenGL swap interval via wglSwapIntervalEXT:

      flmVsyncOn     — swap interval 1, no FPS cap. Synced to the
                       display (~60), no tearing. Default.
      flmVsyncOffMax — swap interval 0, no FPS cap. Uncapped; shows
                       the true GPU ceiling, will tear.
      flmVsyncOffLow — swap interval 0, LimitFPS 30. Battery saver
                       for a long ride; CGE sleeps the render thread. }
  TFpsLimitMode = (flmVsyncOn, flmVsyncOffMax, flmVsyncOffLow);

  TFpsModeChangedEvent = procedure(NewMode: TFpsLimitMode) of object;
  { Raised when the user presses L — host writes a timestamped marker
    line into the log so the approximate moment of a visual bug can be
    located afterwards. }
  TLogMarkerEvent = procedure of object;

  { Network/OSM events arrive on worker threads. They're snapshotted by value into TNetEvent
    records, queued, and drained on the main thread via the non-blocking TThread.Queue so the worker
    never waits. (TThread.Synchronize would BLOCK the worker until the main thread runs the handler —
    a busy main thread once stalled a FetchTile ~45 s on a cache-hit callback.) }
  TNetEventKind = (nekRequest, nekProgress, nekSuccess, nekCacheHit,
                   nekError, nekOsmTile, nekOsmAttempt);

  TNetEvent = record
    Kind:       TNetEventKind;
    URL:        string;
    Method:     string;
    Err:        string;
    Endpoint:   string;
    Bytes:      Int64;
    Total:      Int64;
    Elapsed:    Int64;
    BodySize:   Integer;
    StatusCode: Integer;
    Attempt:    Integer;
    Tile:       TTileXY;
    TileIndex:  Integer;
    TileTotal:  Integer;
    Success:    Boolean;
    WorkerIdx:  Integer;
  end;

  { wglSwapIntervalEXT signature. Win64-only project, so a direct WGL
    import is fine. stdcall on Win64 is normalised to the single
    platform convention. }
  TWglSwapIntervalProc = function(Interval: LongInt): LongBool; stdcall;

  TVerticalFlyHandler = class(TCastleUserInterface)
  private
    FCamera:         TCastleCamera;
    FMoveSpeed:      Single;
    FRotateSpeed:    Single;
    FMouseNavActive: Boolean;
    { When True (Flat map mode) the mouse drags the map (pan in the
      ground plane) instead of rotating, and all rotation input is
      ignored — the flat 2D map must never rotate. }
    FFlatMode:       Boolean;
    FFpsMode:        TFpsLimitMode;
    FOnFpsModeChanged: TFpsModeChangedEvent;
    FOnLogMarker:      TLogMarkerEvent;
    { Deferred vsync application. The V key runs in a message handler
      where the GL context is NOT current; wglSwapIntervalEXT requires
      a current context. So the key sets FDesiredSwapInterval +
      FSwapIntervalPending, and Render (context current) applies it. }
    FDesiredSwapInterval: LongInt;
    FSwapIntervalPending: Boolean;
    FWglLoaded:           Boolean;
    FWglSwapInterval:     TWglSwapIntervalProc;
    procedure RotateCamera(const AYaw, APitch: Single);
    { Grab-style pan in the ground plane (Flat mode). Screen pixels →
      world metres, scaled by camera height so the drag tracks the cursor
      at any zoom. Translation only — orientation stays locked top-down. }
    procedure PanCamera(const ADeltaX, ADeltaY: Single);
    procedure CycleFpsMode;
    procedure ApplyFpsMode;
  public
    constructor Create(AOwner: TComponent); override;
    function Press(const Event: TInputPressRelease): Boolean; override;
    function Release(const Event: TInputPressRelease): Boolean; override;
    function Motion(const Event: TInputMotion): Boolean; override;
    procedure Update(const SecondsPassed: Single;
      var HandleInput: Boolean); override;
    procedure Render; override;
    property Camera:      TCastleCamera read FCamera      write FCamera;
    property MoveSpeed:   Single        read FMoveSpeed   write FMoveSpeed;
    property RotateSpeed: Single        read FRotateSpeed write FRotateSpeed;
    { Set by the form when toggling 3D ↔ Flat. }
    property FlatMode:    Boolean       read FFlatMode    write FFlatMode;
    property OnFpsModeChanged: TFpsModeChangedEvent
      read FOnFpsModeChanged write FOnFpsModeChanged;
    property OnLogMarker: TLogMarkerEvent
      read FOnLogMarker write FOnLogMarker;
  end;

  { Prepare the road pages and shadow depth pass before drawing this viewport. }
  TStudioViewport = class(TOsmImpostorViewport)
  public
    OnPrepareScene: TNotifyEvent;
    procedure Render; override;
  end;

  TStudioMainForm = class(TForm)
    MainMenu1:    TMainMenu;
    miFile:       TMenuItem;
    miOpenFit:    TMenuItem;
    miSeparator1: TMenuItem;
    miExit:       TMenuItem;
    miHelp:       TMenuItem;
    miAbout:      TMenuItem;

    LeftPanel:    TPanel;
    btnGenerate:  TButton;
    btnCancel:    TButton;
    btn3D:        TButton;
    btnFlat:      TButton;
    btnViewSource: TButton;
    btnVisible:   TButton;
    btnHeights:   TButton;

    EndpointsHost: TPanel;

    NetMemo:      TMemo;
    SplitterLogs: TSplitter;
    LogMemo:      TMemo;

    StatusBar1:   TStatusBar;
    ProgressBar1: TProgressBar;

    OpenDialog1:  TOpenDialog;

    ViewportHost: TCastleControl;

    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure miOpenFitClick(Sender: TObject);
    procedure btnGenerateClick(Sender: TObject);
    procedure btn3DClick(Sender: TObject);
    procedure btnFlatClick(Sender: TObject);
    procedure btnViewSourceClick(Sender: TObject);
    procedure btnVisibleClick(Sender: TObject);
    procedure btnHeightsClick(Sender: TObject);

  private
    Viewport:     TCastleViewport;
    FShadowAtlas: TRiderShadowAtlas;
    FShadowGroundPosition: TVector3;
    FShadowGroundSample: QWord;
    FVerticalFly: TVerticalFlyHandler;
    FFpsLabel:    TCastleLabel;
    FFpsTimer:    TTimer;
    FHiddenRender: Boolean;
    FHiddenResizing: Boolean;
    FWorldShadowsEnabled: Boolean;

    { Поиск места по имени (CGE-оверлей в левом верхнем углу). Виден только
      в плоском режиме — Exists переключается вместе со slippy-картой. }
    FSearchWidget: TOsm3dSearchWidget;
    FPhotoCompare: TStudioPhotoCompare;
    FPhotoRenderer: TPhotoViewRender;
    FPhotoButton: TButton;
    FPhotoSavedFps, FPhotoSavedSearch: Boolean;
    FPhotoSavedMoveSpeed: Single;
    procedure PhotoCompareClick(Sender:TObject);
    procedure PhotoCompareClosed(Sender:TObject);

  private

    { Loaded route (lat/lon), optional per-point altitude, and the FIT start timestamp. Parsed from
      FIT/CSV by LoadRouteFile and handed to the streaming session at btnGenerateClick. }
    FRoute:         TRouteLatLonArray;
    FRouteAltM:     TRouteAltArray;
    FRouteStartUTC: TDateTime;
    { Полный путь загруженного FIT (пуст для CSV/GPX). Нужен коррекции
      террейна по FIT: папка файла = папка заездов банка, сам файл —
      выбранный заезд (SetRoutesFolder карты в StartStreaming). }
    FRouteFitPath:  string;

    { Сверка высот FIT/мир/дорога — порт ComputeDemComparison страницы
      «Маршруты» игры: по готовности снапа (и лока уровня коррекции)
      один раз пишется <fit>-heights.csv рядом с файлом. Статистика,
      которая в игре идёт в лабелы, здесь ложится в шапку CSV. }
    FHeightsCsvPending: Boolean;  { взводится в StartStreaming }
    FHeightsWaitStart:  QWord;    { старт ожидания, GetTickCount64 }
    { Фоновый поток сверки (THeightsCsvWorker, тип в implementation).
      nil = не идёт. Синхронный вызов держал UI ~40 с (TryLoad ~19
      тайлов с диска в два прохода + хэши сотен тысяч вершин) —
      «freeze OUTSIDE Update» в логе 12.07. }
    FHeightsWorker:     TThread;
    FStreamOrigin:      TLatLon;  { origin текущей сессии — для проекции
                                    тайл-центров, как FWarmProj в игре }

    { Generation settings. Currently the defaults; a settings UI would
      write here. Pushed to the rendering globals at startup
      (ApplyStudioSettingsToGlobals) and passed to the streaming session. }
    FSettings:      TStudioSettings;
    FTreesButton:TButton;
    FViewState:TStudioViewState;
    FRestoreViewPending:Boolean;
    FLoadedRoutePath:string;

    { Background tile-streaming session — created on demand from the
      loaded route (see btnGenerateClick). Owns its own streaming map,
      HTTP fetcher and caches. }
    FStreamSession: TOsm3dStreamingSession;

    { Flat OSM raster ("slippy") map. Created once, added to the viewport,
      kept hidden until the user switches to Flat mode. Streams 2D tiles
      under the camera; its Origin is kept in sync with the 3D map's. }
    FSlippyMap: TOsm3dSlippyMap;
    { Persistent cache-aware fetcher for the flat map's tiles (owns its byte
      cache). Lives as long as the form so the slippy map's byte cache survives
      across sessions and mode switches. Freed AFTER FSlippyMap. }
    FSlippyFetcher: THTTPFetcherWithCache;

    { Background IP geolocation, started at create. Result is applied once (to
      the flat map's origin) iff no route has been loaded — so the map opens
      near the user when there is no FIT/GPX. Polled from the FPS timer. }
    FGeoThread:  TIpLocateThread;
    FGeoApplied: Boolean;
    { CLI-параметры запуска. }
    FCliResetTiles: Boolean;   { --reset-tiles: очистить кэш тайлов на старте }
    FCliFitFile:    string;    { --fit=<path> / позиционный *.fit|*.gpx }
    FCliFitStarted: Boolean;   { одноразовый старт из FIT }
    FCliShotFile:   string;    { --shot=<png>: сохранить кадр 3D-вида }
    FCliShotDelay:  Integer;   { --shot-delay=<сек> от старта стриминга (умолч. 20) }
    FCliShotExit:   Boolean;   { --shot-exit: закрыться после снимка }
    FCliCamAlt:     Double;    { --cam-alt=<м>: высота камеры при старте из FIT (умолч. 300) }
    FShotArmedAt:   QWord;     { GetTickCount64 взвода (старт стриминга), 0 = не взведён }

    { Current mode (3D ↔ Flat). The btn3D/btnFlat controls live in the
      published section so the .lfm can bind them. }
    FFlatMode: Boolean;

    { Camera view saved when entering Flat, restored when returning to 3D,
      so toggling modes doesn't lose the user's 3D vantage point. }
    FSaved3DPos: TVector3;
    FSaved3DDir: TVector3;
    FSaved3DUp:  TVector3;
    FHas3DView:  Boolean;

    { Scratch slots for SafeSync: worker writes here, DoApply* reads on
      main thread (TThread.Synchronize cannot pass parameters). }
    FPendingProgress: TGenerationProgress;
    FPendURL, FPendMethod, FPendErr, FPendEndpoint: string;
    FPendBytes, FPendTotal, FPendElapsed: Int64;
    FPendBodySize, FPendStatusCode, FPendAttempt: Integer;
    FPendTile:       TTileXY;
    FPendTileIndex, FPendTileTotal: Integer;
    FPendSuccess:    Boolean;
    FPendWorkerIdx:  Integer;
    FPendLogLevel:   TLogLevel;
    FPendLogLine:    string;
    FInLogMemoDiag:  Boolean;   { re-entry guard for LogMemoAdd timing diag }
    FCgeShadowLog:   TFileLogTarget;   { DIAGNOSTIC: CGE shadow-map log capture }
    { Non-blocking worker→main network event queue (see TNetEvent). }
    FNetQueue:       specialize TQueue<TNetEvent>;
    FNetCS:          TCriticalSection;
    FNetDrainQueued: Boolean;   { a DrainNetEvents is already posted }

    FEndpointPanels:  specialize TDictionary<string, TEndpointStatusPanel>;
    FOverallProgress: TProgressBar;
    FOverallLabel:    TLabel;
    FTilesDone:       Integer;
    FTilesTotal:      Integer;

    { Поле ввода дальности тумана (EndpointsHost, под Tiles: N/M — см.
      FormCreate). Туман — через TScreenFX (GameScreenFX), ТОТ ЖЕ депт-
      шейдер, что и в gameviewplay, а не CGE-нативный TCastleFog: студия
      тоже рисует raw-GL инстансированную траву/деревья (Osm3dRenderInstanced)
      — TCastleFog их не покрывает (см. шапку GameScreenFX), FX покрывает
      всё, что пишет в буфер глубины. FScreenFX создаётся один раз и живёт
      всё время формы; включается/выключается общим Enabled (см.
      FogEditChange) — единственный потребитель FX в студии, отдельных
      кнопок bloom/tone тут нет, так что дальность тумана заодно решает,
      весь ли пост-пайплайн активен. }
    FFogLabel: TLabel;
    FFogEdit:  TEdit;
    FImpostorCheck: TCheckBox;
    FRtxCheck,FShadowProjectionsCheck,FRtxReflectionsCheck:TCheckBox;
    FRtxCachedRaster:Boolean;
    FShadowModeSync:Boolean;
    FFogClearLabel: TLabel;
    FFogClearEdit:  TEdit;
    FScreenFX: TScreenFX;

    procedure FogEditChange(Sender: TObject);
    procedure TreesButtonClick(Sender:TObject);
    procedure SaveViewState;
    procedure MaybeRestoreView;

    procedure UpdateFps(Sender: TObject);
    procedure FreeEndpointPanels;
    function  FindPanelForUrl(const URL: string): TEndpointStatusPanel;

    procedure UpdateUiState;

    { Store a parsed route (from FIT/CSV) and refresh the UI. }
    procedure SetRouteData(const APts: TRouteLatLonArray;
      AStartUTC: TDateTime; const AAlt: TRouteAltArray);

    procedure HandleFpsModeChanged(NewMode: TFpsLimitMode);
    procedure HandleLogMarker;

    procedure HandleNetRequest(Sender: TObject;
      const URL, Method: string; BodySize: Integer);
    procedure HandleNetProgress(Sender: TObject;
      const URL, Method: string;
      Received, Total: Int64; ElapsedMs: Int64);
    procedure HandleNetSuccess(Sender: TObject;
      const URL, Method: string; StatusCode: Integer;
      ResponseSize: Int64; ElapsedMs: Int64);
    procedure HandleCacheHit(Sender: TObject;
      const URL: string; SizeBytes: Int64);
    procedure HandleNetError(Sender: TObject;
      const URL, ErrorMsg: string; Attempt: Integer;
      PartialSize: Int64; ElapsedMs: Int64);

    procedure EnqueueNetEvent(const AEvent: TNetEvent);
    procedure DrainNetEvents;
    procedure DoApplyNetRequest;
    procedure DoApplyNetProgress;
    procedure DoApplyNetSuccess;
    procedure DoApplyCacheHit;
    procedure DoApplyNetError;
    procedure DoApplyOsmTile;
    procedure DoApplyOsmAttempt;

    procedure LogMemoAdd(const Line: string);

    { Streaming log sink — passed as the TCallbackLogTarget callback to
      the streaming session. TCallbackLogTarget marshals to the main
      thread, so writing to the log memo here is safe. The line arrives
      already formatted (FormatLogLine). }
    procedure HandleStreamLog(const AMsg: string);

    { DIAGNOSTIC: route CGE's CastleLog (shadow-map decisions) to a file. }
    procedure HandleCgeLog(const AMsg: string);

    { CSV → TCsvRouteLoader; FIT → TFitAdapter (via map). }
    procedure LoadRouteFile(const FileName: string);

    { Toggle visibility between the 3D streaming map and the flat slippy map.
      Flat: hide the streaming map, show + enable FSlippyMap.
      3D:   show the streaming map (if any), hide + disable FSlippyMap. }
    procedure SetMapMode(AFlat: Boolean);
    { Keep the slippy map's projection origin aligned with the 3D world's
      (the route centroid). Safe to call repeatedly — no-op if unchanged. }
    procedure SyncSlippyOrigin;
    { Create/restart the 3D streaming session at AOrigin and show it. Shared by
      the Generate button (origin = route centroid) and by the IP-geolocation
      path (origin = user location, empty route). }
    procedure StartStreaming(const AOrigin: TLatLon);
    procedure PrepareSceneRender(Sender: TObject);
    procedure HiddenRenderIdle(Sender: TObject; var Done: Boolean);
    { Поллинг готовности снапа/лока коррекции и завершения фоновой
      сверки (из UpdateFps). Сама сверка — THeightsCsvWorker. }
    procedure MaybeComputeHeightsCsv;
    { If the IP-geolocation lookup has finished and no route is loaded, point
      the flat map at the user's location (once). Safe to call every tick. }
    procedure MaybeApplyInitialLocation;
    { Разбор командной строки: --reset-tiles, --fit=<path> или позиционный
      *.fit / *.gpx, --shot=<png> [--shot-delay=с] [--shot-exit]. }
    procedure ParseCommandLine;
    { --shot: одноразовый автоснимок через FCliShotDelay после взвода. }
    procedure MaybeTakeShot;
    { Кадр GL-буфера ViewportHost в PNG. Читается framebuffer контрола, а НЕ
      экран — чужие окна поверх не мешают (в отличие от PrintScreen). }
    procedure SaveViewportShot(const FileName: string);
    { Меню/F5: скриншот в <exe>\shots\osm3d_shot_<штамп>.png. }
    procedure miSaveShotClick(Sender: TObject);
    { --reset-tiles: удалить папку кэша ТАЙЛОВ (o3dt); http-кэш не трогаем. }
    procedure ResetTileCache;
    { --fit: если задан FIT — грузим маршрут, пропускаем IP, стартуем 3D с его
      позиции (вместо плоской карты). Вызывается из UpdateFps, когда GL готов. }
    procedure MaybeStartFromFit;

    { Виджет поиска места: выбор подсказки → центрируем плоскую карту на
      найденной точке (переустановка origin slippy-карты + обнуление XZ
      камеры — минимальная ошибка проекции при прыжке на любое расстояние). }
    procedure SearchPlacePicked(Sender: TObject; const AHit: TGeoHit);
    { Поднять приоритет местных совпадений: рамка вокруг текущего центра
      плоской карты. False → глобальный поиск без смещения. }
    function  SearchNeedViewBox(Sender: TObject; out ABox: TLatLonBox): Boolean;

    { Pop-up read-only Memo window with the current tile's OSM JSON. }
    procedure ShowOsmSource(const ATileName, AText: string);
    procedure OsmSourceFormClose(Sender: TObject; var CloseAction: TCloseAction);
  protected
    procedure Resize; override;
  public
    procedure InitializeHiddenRender;
    procedure ImpostorCheckClick(Sender:TObject);
    procedure SetWorldImpostorCache(Value:Boolean);
    procedure RtxCheckClick(Sender:TObject);
    procedure RtxReflectionsClick(Sender:TObject);
    procedure SetRtxReflections(Value:Boolean);
    procedure DebugRtxReflections;
    procedure SetWorldRtxShadows(Value:Boolean);
    procedure RtxSnapshot(const J:TJSONObject);
    procedure SetRtxCachedRaster(Value:Boolean);
    procedure ShadowProjectionsClick(Sender:TObject);
    { ── MCP-фасад (юнит Osm3dMcp, активен только при --mcp-stdio) ────────
      Указатель на живой record настроек + обёртки над приватными
      действиями. Исключения не прячутся — MCP-команда вернёт tool error. }
    property McpViewport: TCastleViewport read Viewport;
    property PhotoRenderer: TPhotoViewRender read FPhotoRenderer;
    procedure OpenPhotoComparison;
    procedure ClosePhotoComparison;
    function PhotoComparisonCommand(const Params:TJSONObject):TJSONObject;
    function RenderInfo: string;
    function GetFpsMode: TFpsLimitMode;
    procedure SetFpsMode(Value: TFpsLimitMode);
    property WorldShadowsEnabled:Boolean read FWorldShadowsEnabled write FWorldShadowsEnabled;
    procedure SetProceduralTrees(AValue:Boolean);
    function  SettingsPtr: PStudioSettings;
    function  StreamSession: TOsm3dStreamingSession;
    function  StreamOrigin: TLatLon;
    function  RoutePointCount: Integer;
    function  IsFlatMode: Boolean;
    procedure McpLoadRoute(const FileName: string);
    { AUseOrigin=True — старт с заданного origin; False — с первой точки
      маршрута (ошибка, если маршрут не загружен). }
    procedure McpStartStreaming(const AOrigin: TLatLon; AUseOrigin: Boolean);
    procedure McpSetMapMode(AFlat: Boolean);
    procedure McpScreenshot(const FileName: string);
    procedure McpResetTiles;
    { Центрировать плоскую карту на точке (та же логика, что выбор
      подсказки поиска — SearchPlacePicked). }
    procedure McpJumpToPlace(const ALoc: TLatLon);
  end;

var
  StudioMainForm: TStudioMainForm;

implementation

uses WSControls, Osm3dStreamingMap, McpPhotoViewTools, Osm3dStudioCapture;

{$R *.lfm}

const
  LOG_MEMO_MAX_LINES = 5000;
  TRIM_BATCH         =  500;

{ Direct WGL import for runtime vsync control. wglGetProcAddress is a
  plain export of opengl32.dll; the *extension* function it returns
  (wglSwapIntervalEXT) is what actually toggles the swap interval, and
  both must be invoked with a current GL context. Bound to its own
  Pascal name so it can't clash with any declaration CGE's GL units
  may already pull in. }
function Osm3dWglGetProcAddress(P: PAnsiChar): Pointer; stdcall;
  external 'opengl32.dll' name 'wglGetProcAddress';

const
  { Flat-map (2D) zoom feel. Altitude is changed MULTIPLICATIVELY so a step
    is the same fraction at every height (Google-Maps-style), instead of a
    fixed metre step that crawls when high and lurches near the ground. The
    slippy map derives its tile zoom level from this altitude. }
  FLAT_ZOOM_STEP = 1.25;       { wheel: altitude factor per notch }
  FLAT_ZOOM_RATE = 3.0;        { E/Q held: altitude factor per second }
  FLAT_MIN_Y     = 50.0;       { deepest zoom-in (≈ finest slippy zoom) }
  FLAT_MAX_Y     = 400000.0;   { whole-region zoom-out }

procedure TVerticalFlyHandler.Update(const SecondsPassed: Single;
  var HandleInput: Boolean);
const
  WORLD_UP: TVector3 = (X: 0; Y: 1; Z: 0);
var
  Pos, Dir, Right, FlatDir: TVector3;
  Speed, RotSpeed, FlatLen: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(896);{$ENDIF}
  inherited;
  if (FCamera = nil) or (Container = nil) then Exit;

  Speed    := FMoveSpeed   * SecondsPassed;
  RotSpeed := FRotateSpeed * SecondsPassed;

  Pos := FCamera.Translation;
  Dir := FCamera.Direction;

  if FFlatMode then
  begin
    { Flat map: no rotation at all. WASD pans along world axes
      (North = +Z, East = −X); E/Q change height (zoom). Pan step scales
      with altitude so it feels the same at any zoom; E/Q zoom is
      multiplicative for the same progressive feel as the wheel. }
    Speed := Speed * Max(1.0, Pos.Y * 0.01);
    if Container.Pressed[keyW] then Pos.Z := Pos.Z + Speed;  { north }
    if Container.Pressed[keyS] then Pos.Z := Pos.Z - Speed;  { south }
    if Container.Pressed[keyD] then Pos.X := Pos.X - Speed;  { east  }
    if Container.Pressed[keyA] then Pos.X := Pos.X + Speed;  { west  }
    if Container.Pressed[keyE] then
      Pos.Y := Pos.Y * Power(FLAT_ZOOM_RATE, SecondsPassed);        { zoom out }
    if Container.Pressed[keyQ] then
      Pos.Y := Pos.Y * Power(1.0 / FLAT_ZOOM_RATE, SecondsPassed);  { zoom in  }
    if Pos.Y < FLAT_MIN_Y then Pos.Y := FLAT_MIN_Y;
    if Pos.Y > FLAT_MAX_Y then Pos.Y := FLAT_MAX_Y;
    FCamera.Translation := Pos;
    Exit;                       { skip arrow-key rotation entirely }
  end;

  FlatDir := Vector3(Dir.X, 0, Dir.Z);
  FlatLen := Sqrt(FlatDir.X*FlatDir.X + FlatDir.Z*FlatDir.Z);
  if FlatLen < 1.0e-6 then
    FlatDir := Vector3(0, 0, -1)
  else
    FlatDir := FlatDir * (1.0 / FlatLen);

  Right := TVector3.CrossProduct(FlatDir, WORLD_UP);

  if Container.Pressed[keyW] then Pos := Pos + FlatDir * Speed;
  if Container.Pressed[keyS] then Pos := Pos - FlatDir * Speed;
  if Container.Pressed[keyD] then Pos := Pos + Right   * Speed;
  if Container.Pressed[keyA] then Pos := Pos - Right   * Speed;
  if Container.Pressed[keyE] then Pos.Y := Pos.Y + Speed;
  if Container.Pressed[keyQ] then Pos.Y := Pos.Y - Speed;

  FCamera.Translation := Pos;

  if Container.Pressed[keyArrowLeft]  then RotateCamera( RotSpeed, 0);
  if Container.Pressed[keyArrowRight] then RotateCamera(-RotSpeed, 0);
  if Container.Pressed[keyArrowUp]    then RotateCamera(0,  RotSpeed);
  if Container.Pressed[keyArrowDown]  then RotateCamera(0, -RotSpeed);
end;

function TVerticalFlyHandler.Press(const Event: TInputPressRelease): Boolean;
var
  FlatPos: TVector3;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(897);{$ENDIF}
  Result := inherited Press(Event);
  if Result then Exit;

  if Event.IsKey(keyV) then
  begin
    CycleFpsMode;
    Exit(True);
  end;

  if Event.IsKey(keyL) then
  begin
    if Assigned(FOnLogMarker) then FOnLogMarker;
    Exit(True);
  end;

  if Event.IsMouseButton(buttonLeft) or
     Event.IsMouseButton(buttonRight) or
     Event.IsMouseButton(buttonMiddle) then
  begin
    FMouseNavActive := True;
    Exit(True);
  end;

  if Event.MouseWheel <> mwNone then
  begin
    if FCamera <> nil then
    begin
      if FFlatMode then
      begin
        { Progressive zoom: each notch scales altitude by FLAT_ZOOM_STEP, so
          a notch feels identical at every height. Scroll up (+) → descend
          (zoom in). The slippy map re-derives its tile zoom from the height. }
        FlatPos := FCamera.Translation;
        FlatPos.Y := FlatPos.Y * Power(FLAT_ZOOM_STEP, -Event.MouseWheelScroll);
        if FlatPos.Y < FLAT_MIN_Y then FlatPos.Y := FLAT_MIN_Y;
        if FlatPos.Y > FLAT_MAX_Y then FlatPos.Y := FLAT_MAX_Y;
        FCamera.Translation := FlatPos;
      end
      else
        FCamera.Translation := FCamera.Translation +
          FCamera.Direction * (FMoveSpeed * 0.35 * Event.MouseWheelScroll);
    end;
    Exit(True);
  end;
end;

function TVerticalFlyHandler.Release(const Event: TInputPressRelease): Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(898);{$ENDIF}
  Result := inherited Release(Event);
  if Result then Exit;

  if Event.IsMouseButton(buttonLeft) or
     Event.IsMouseButton(buttonRight) or
     Event.IsMouseButton(buttonMiddle) then
  begin
    FMouseNavActive := False;
    Exit(True);
  end;
end;

function TVerticalFlyHandler.Motion(const Event: TInputMotion): Boolean;
const
  MOUSE_ROTATE_SPEED = 0.006;
var
  Delta: TVector2;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(899);{$ENDIF}
  Result := inherited Motion(Event);
  if Result then Exit;

  if (not FMouseNavActive) and
     not ((buttonLeft   in Event.Pressed) or
          (buttonRight  in Event.Pressed) or
          (buttonMiddle in Event.Pressed)) then
    Exit(False);

  Delta := Event.Position - Event.OldPosition;
  if FFlatMode then
    PanCamera(Delta.X, Delta.Y)        { drag the map, never rotate }
  else
    RotateCamera(-Delta.X * MOUSE_ROTATE_SPEED, -Delta.Y * MOUSE_ROTATE_SPEED);
  Result := True;
end;

procedure TVerticalFlyHandler.RotateCamera(const AYaw, APitch: Single);
const
  WORLD_UP: TVector3 = (X: 0; Y: 1; Z: 0);
var
  Pos, Dir, Right, Up: TVector3;
  Len: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(900);{$ENDIF}
  if FCamera = nil then Exit;

  Pos := FCamera.Translation;
  Dir := FCamera.Direction;

  if Abs(AYaw) > 1.0e-7 then
    Dir := RotatePointAroundAxis(Vector4(WORLD_UP.X, WORLD_UP.Y, WORLD_UP.Z, AYaw), Dir);

  Right := TVector3.CrossProduct(Vector3(Dir.X, 0, Dir.Z), WORLD_UP);
  Len := Sqrt(Right.X*Right.X + Right.Y*Right.Y + Right.Z*Right.Z);
  if Len < 1.0e-6 then
    Right := Vector3(1, 0, 0)
  else
    Right := Right * (1.0 / Len);

  if Abs(APitch) > 1.0e-7 then
    Dir := RotatePointAroundAxis(Vector4(Right.X, Right.Y, Right.Z, APitch), Dir);

  Len := Sqrt(Dir.X*Dir.X + Dir.Y*Dir.Y + Dir.Z*Dir.Z);
  if Len < 1.0e-6 then
    Dir := Vector3(0, 0, -1)
  else
    Dir := Dir * (1.0 / Len);

  Right := TVector3.CrossProduct(Vector3(Dir.X, 0, Dir.Z), WORLD_UP);
  Len := Sqrt(Right.X*Right.X + Right.Y*Right.Y + Right.Z*Right.Z);
  if Len < 1.0e-6 then
    Right := Vector3(1, 0, 0)
  else
    Right := Right * (1.0 / Len);
  Up := TVector3.CrossProduct(Right, Dir);
  Len := Sqrt(Up.X*Up.X + Up.Y*Up.Y + Up.Z*Up.Z);
  if Len < 1.0e-6 then
    Up := WORLD_UP
  else
    Up := Up * (1.0 / Len);

  FCamera.SetView(Pos, Dir, Up);
end;

procedure TVerticalFlyHandler.PanCamera(const ADeltaX, ADeltaY: Single);
var
  Pos:        TVector3;
  H, ViewH, K: Single;
const
  { ≈ 2*tan(vFov/2) for the default perspective FOV — converts the
    altitude-derived world span to roughly one-pixel-per-pixel drag. }
  PAN_GAIN = 1.2;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1748);{$ENDIF}
  if (FCamera = nil) or (Container = nil) then Exit;

  Pos := FCamera.Translation;

  { Metres of ground per screen pixel ≈ (camHeight * PAN_GAIN) / viewport
    height in the same units Event.Position uses (UI units). }
  H := Pos.Y;
  if H < 1.0 then H := 1.0;
  ViewH := Container.Height;
  if ViewH < 1.0 then ViewH := 1.0;
  K := (H / ViewH) * PAN_GAIN;

  { Grab feel with the locked top-down, north-up basis. World axes:
    East = −X, North = +Z (see TLocalProjection). Screen-right = East = −X,
    screen-up = North = +Z. Drag right ⇒ map moves right ⇒ camera moves
    west (+X); drag up (Y grows upward in CGE) ⇒ map moves up ⇒ camera
    moves south (−Z). }
  Pos.X := Pos.X + ADeltaX * K;
  Pos.Z := Pos.Z - ADeltaY * K;

  FCamera.Translation := Pos;     { orientation untouched — no rotation }
end;

constructor TVerticalFlyHandler.Create(AOwner: TComponent);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1278);{$ENDIF}
  inherited;
  FMoveSpeed   := 280.0;
  FRotateSpeed := 1.5;
  FFlatMode    := False;
  FullSize := True;

  { Start with vsync ON — display-synced, no tearing. The actual
    wglSwapIntervalEXT call is deferred to the first Render (needs a
    current GL context); ApplyFpsMode just arms the pending flag. }
  FFpsMode             := flmVsyncOn;
  FWglLoaded           := False;
  FWglSwapInterval     := nil;
  FSwapIntervalPending := False;
  ApplyFpsMode;
end;

procedure TVerticalFlyHandler.ApplyFpsMode;
{ Translates FFpsMode into (1) an Application FPS cap, applied
  immediately — that's thread-safe — and (2) a desired GL swap
  interval, deferred to Render via FSwapIntervalPending because
  wglSwapIntervalEXT needs a current GL context. }
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(901);{$ENDIF}
  case FFpsMode of
    flmVsyncOn:
      begin
        ApplicationProperties.LimitFPS := 0;   { vsync paces it }
        FDesiredSwapInterval := 1;
      end;
    flmVsyncOffMax:
      begin
        ApplicationProperties.LimitFPS := 0;   { uncapped }
        FDesiredSwapInterval := 0;
      end;
    flmVsyncOffLow:
      begin
        ApplicationProperties.LimitFPS := 30;  { battery saver }
        FDesiredSwapInterval := 0;
      end;
  end;
  FSwapIntervalPending := True;
  SetVegetationFrameLimit(ApplicationProperties.LimitFPS,FDesiredSwapInterval<>0);
end;

procedure TVerticalFlyHandler.CycleFpsMode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(902);{$ENDIF}
  case FFpsMode of
    flmVsyncOn:     FFpsMode := flmVsyncOffMax;
    flmVsyncOffMax: FFpsMode := flmVsyncOffLow;
    flmVsyncOffLow: FFpsMode := flmVsyncOn;
  end;
  ApplyFpsMode;
  if Assigned(FOnFpsModeChanged) then
    FOnFpsModeChanged(FFpsMode);
end;

procedure TVerticalFlyHandler.Render;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(903);{$ENDIF}
  inherited;
  { Context is current here — safe to resolve and call the WGL
    extension. Done only when a mode change is pending, so the
    steady-state per-frame cost is a single boolean test. }
  if FSwapIntervalPending then
  begin
    if not FWglLoaded then
    begin
      FWglSwapInterval := TWglSwapIntervalProc(
        Osm3dWglGetProcAddress('wglSwapIntervalEXT'));
      FWglLoaded := True;
    end;
    if Assigned(FWglSwapInterval) then
      FWglSwapInterval(FDesiredSwapInterval);
    FSwapIntervalPending := False;
  end;
end;

{ DIAGNOSTIC: inject N empty drawn scenes to isolate the pure per-TCastleScene
  GPU/draw cost from any content. Each scene is ONE tiny box, parented to the
  camera so it is always inside the frustum and therefore always DRAWN (culled
  scenes do no GPU work — TProfiledScene.LocalRender returns before inherited).
  Sweep Osm3dStudioSettings.DiagEmptyDrawnScenes (0/200/500...) and compare the
  [GPU frame time] line: flat => scene COUNT is free, cost is per-scene CONTENT;
  rising => CGE has a real per-empty-scene overhead. }
procedure InjectDiagEmptyScenes(AOwner: TComponent; ACamera: TCastleCamera;
  ACount: Integer);
var
  I:        Integer;
  DiagRoot: TCastleTransform;
  Sc:       TCastleScene;
  Root:     TX3DRootNode;
  Shape:    TShapeNode;
  Box:      TBoxNode;
begin
  if (ACount <= 0) or (ACamera = nil) then Exit;
  DiagRoot := TCastleTransform.Create(AOwner);
  DiagRoot.Translation := Vector3(0, 0, -10);   { 10 m in front of the camera }
  ACamera.Add(DiagRoot);
  for I := 1 to ACount do
  begin
    Box := TBoxNode.CreateWithShape(Shape);
    Box.Size := Vector3(0.02, 0.02, 0.02);
    Root := TX3DRootNode.Create;
    Root.AddChildren(Shape);
    Sc := TCastleScene.Create(AOwner);
    Sc.Load(Root, True);
    { Spread on a small grid so they don't fully overlap (overlap could let the
      GPU early-Z them away and hide their cost). }
    Sc.Translation := Vector3(((I mod 40) - 20) * 0.05,
                              ((I div 40) mod 40 - 20) * 0.05, 0);
    DiagRoot.Add(Sc);
  end;
end;

procedure TStudioMainForm.FormCreate(Sender: TObject);
var Sky: TCastleBackground;
begin
  LocalizeDesignedUi(Self);
  {$IFDEF IAM_LIVE}IamLiveTrack(904);{$ENDIF}

  { Отдельное окно HTTP-событий (NetMemo) снято: все события, что в нём
    когда-либо появлялись (request/success/cache-hit/error/tile), и так
    дублировались в общий LogMemoAdd (см. DoApplyNet*/DoApplyOsmTile) —
    только два «шумных» события (прогресс закачки, попытка на зеркало)
    никогда не писались текстом никуда, они остаются чисто визуальными
    в панелях EndpointsHost, их эта правка не касается.
    NetMemo/SplitterLogs остаются ОБЪЯВЛЕНЫ в классе и существуют в .lfm
    (файл разметки формы недоступен в этом контексте — удалить компоненты
    из дизайнера отсюда нельзя), поэтому скрываем их: Align+Visible=False
    у LCL не резервирует место, LogMemo ниже займёт освободившуюся полосу
    сам. Чтобы убрать компоненты по-настоящему (а не просто спрятать) —
    удалить NetMemo и SplitterLogs в дизайнере форм Lazarus и следом
    убрать их поля из объявления класса. }
  NetMemo.Visible      := False;
  SplitterLogs.Visible := False;
  ParseCommandLine;
  FWorldShadowsEnabled:=True;
  FEndpointPanels := specialize TDictionary<string, TEndpointStatusPanel>.Create;
  FNetQueue := specialize TQueue<TNetEvent>.Create;
  FNetCS    := TCriticalSection.Create;
  FTilesDone  := 0;
  FTilesTotal := 0;

  FOverallLabel := TLabel.Create(Self);
  FOverallLabel.Parent  := EndpointsHost;
  FOverallLabel.Align   := alTop;
  FOverallLabel.AutoSize := False;
  FOverallLabel.Height  := 18;
  FOverallLabel.BorderSpacing.Around := 4;
  BindUiText(FOverallLabel, 'Tiles: 0 / 0');
  FOverallLabel.Font.Style := [Graphics.fsBold];

  FOverallProgress := TProgressBar.Create(Self);
  FOverallProgress.Parent := EndpointsHost;
  FOverallProgress.Align  := alTop;
  FOverallProgress.Height := 10;
  FOverallProgress.BorderSpacing.Around := 4;
  FOverallProgress.Smooth := True;
  FOverallProgress.Min := 0;
  FOverallProgress.Max := 1;

  Viewport := TStudioViewport.Create(Self);
  FPhotoRenderer:=TPhotoViewRender.Create;
  TStudioViewport(Viewport).OnPrepareScene := @PrepareSceneRender;
  Viewport.FullSize       := True;
  Viewport.Transparent    := False;
  Viewport.BackgroundColor := Vector4(0.45, 0.65, 0.85, 1.0);
  { Match the sky colours used by the building glass/hemisphere lighting.
    A background hemisphere costs one draw and needs no fog or postprocess. }
  Sky:=TCastleBackground.Create(Self);
  Sky.SkyTopColor:=Vector3(0.32,0.52,0.82);
  Sky.SkyEquatorColor:=Vector3(0.74,0.84,0.94);
  Sky.GroundEquatorColor:=Sky.SkyEquatorColor;
  Sky.GroundBottomColor:=Vector3(0.10,0.11,0.12);
  Viewport.Background:=Sky;
  Sky.SetEffects([CreateSunSkyEffect]);
  ViewportHost.Controls.InsertFront(Viewport);
  ViewportHost.AutoFocus := True;

  {$PUSH}{$WARN 5066 OFF}  // legacy viewport helpers — functionally equivalent
  Viewport.AutoCamera := False;
  Viewport.Items.UseHeadlight := hlOff;  { lit only by the sun }
  Viewport.Navigation := nil;
  {$POP}

  { Screen-space ambient occlusion — soft contact darkening at building/
    ground joints and between buildings. The FBO clears to BackgroundColor
    (RenderFromViewEverything), so the flat sky stays blue; SSAO leaves a
    uniform-depth background at ao~1 (a faint horizon halo is expected).
    Shader init is lazy (first render) and self-disables on GPUs that can't
    compile it, so setting the property here is safe before the GL context. }
  Viewport.ScreenSpaceAmbientOcclusion := True;

  { Occlusion culling — skip whole shapes/scenes fully hidden behind others.
    The dense city is the textbook case (camera near ground, tall buildings
    occluding most of the frustum): with culling on, a wall in front can cut
    the rendered shape count dramatically, and sort3D (front-to-back, so the
    queries resolve against the nearest occluders first) cuts it further.
    Runtime-toggleable; works on OpenGL and OpenGLES. }
  Viewport.OcclusionCulling := True;
  { OcclusionSort needs CastleRenderOptions in uses for TShapeSort. If your
    CGE predates OcclusionSort/sort3D, delete THIS line (and the uses entry)
    — OcclusionCulling above still gives most of the win on its own. }
  Viewport.OcclusionSort := sort3D;

  FVerticalFly := TVerticalFlyHandler.Create(Self);
  FVerticalFly.Camera      := Viewport.Camera;
  FVerticalFly.OnFpsModeChanged := @HandleFpsModeChanged;
  FVerticalFly.OnLogMarker      := @HandleLogMarker;
  ViewportHost.Controls.InsertFront(FVerticalFly);

  { Default generation settings. (A settings UI, if added, would write
    into FSettings.) Push the values the rendering units read from globals
    once at startup — formerly done by TOsm3dMapTransform.Create. The
    streaming session, created later, also receives FSettings directly. }
  FSettings := TStudioSettings.Defaults;
  { Same ground renderer as the game: the GPU atlas owns world shadows. }
  FSettings.GenerateGroundShadows := False;
  FSettings.BuildingShadows := False;
  ApplyStudioSettingsToGlobals(FSettings);
  FViewState:=LoadStudioViewState(StudioViewStatePath);
  FRestoreViewPending:=FViewState.HasView and (FCliFitFile='');
  FTreesButton:=TButton.Create(Self);
  FTreesButton.Name:='TreeRendererButton';FTreesButton.Parent:=LeftPanel;
  { Keep this control above the HTTP panels, which may fill/overflow their host. }
  btnHeights.Width:=btn3D.Width;
  FTreesButton.SetBounds(btnHeights.Left+btnHeights.Width,btnHeights.Top,btnFlat.Width,btnHeights.Height);
  FTreesButton.AnchorSideLeft.Control:=btnHeights;FTreesButton.AnchorSideLeft.Side:=asrBottom;
  FTreesButton.AnchorSideTop.Control:=btnHeights;
  FTreesButton.OnClick:=@TreesButtonClick;
  FPhotoButton:=TButton.Create(Self);
  FPhotoButton.Name:='PhotoCompareButton';FPhotoButton.Parent:=LeftPanel;
  FPhotoButton.SetBounds(0,btnHeights.Top+btnHeights.Height+8,
    btn3D.Width+btnFlat.Width,btnHeights.Height);
  FPhotoButton.AnchorSideLeft.Control:=LeftPanel;
  FPhotoButton.AnchorSideTop.Control:=btnHeights;
  FPhotoButton.AnchorSideTop.Side:=asrBottom;FPhotoButton.BorderSpacing.Top:=8;
  BindUiText(FPhotoButton,'Compare with photos');FPhotoButton.OnClick:=@PhotoCompareClick;
  EndpointsHost.BorderSpacing.Top:=EndpointsHost.BorderSpacing.Top+btnHeights.Height+8;
  ProceduralVegetationActive:=FViewState.ProceduralTrees;
  if ProceduralVegetationActive then BindUiText(FTreesButton, 'Trees: procedural')
  else BindUiText(FTreesButton, 'Trees: legacy');

  FImpostorCheck:=TCheckBox.Create(Self);
  FImpostorCheck.Parent:=EndpointsHost;FImpostorCheck.Align:=alTop;
  FImpostorCheck.BorderSpacing.Around:=4;
  BindUiText(FImpostorCheck,'Distant world cache (experimental)');
  FImpostorCheck.Checked:=FViewState.ImpostorCache;
  TStudioViewport(Viewport).ImpostorCache:=FViewState.ImpostorCache;
  FImpostorCheck.OnClick:=@ImpostorCheckClick;
  FRtxCheck:=TCheckBox.Create(Self);
  FRtxCheck.Parent:=EndpointsHost;FRtxCheck.Align:=alTop;FRtxCheck.BorderSpacing.Around:=4;
  BindUiText(FRtxCheck,'RTX shadows (experimental)');
  FRtxCheck.Checked:=FViewState.RtxShadows;FRtxCheck.OnClick:=@RtxCheckClick;
  FShadowProjectionsCheck:=TCheckBox.Create(Self);
  FShadowProjectionsCheck.Parent:=EndpointsHost;FShadowProjectionsCheck.Align:=alTop;FShadowProjectionsCheck.BorderSpacing.Around:=4;
  BindUiText(FShadowProjectionsCheck,'Cached tree shadows');
  FRtxCachedRaster:=FViewState.ShadowProjections;FShadowProjectionsCheck.Checked:=FRtxCachedRaster;
  FShadowProjectionsCheck.OnClick:=@ShadowProjectionsClick;
  FRtxReflectionsCheck:=TCheckBox.Create(Self);
  FRtxReflectionsCheck.Parent:=EndpointsHost;FRtxReflectionsCheck.Align:=alTop;FRtxReflectionsCheck.BorderSpacing.Around:=4;
  BindUiText(FRtxReflectionsCheck,'RTX reflections (experimental)');
  FRtxReflectionsCheck.Checked:=FViewState.RtxReflections;FRtxReflectionsCheck.OnClick:=@RtxReflectionsClick;

  { Поля тумана — сразу под Tiles: N/M (см. FOverallLabel/FOverallProgress
    выше): EndpointsHost такой же контейнер «раскладка сама по alTop», уже
    проверенный на этих двух контролах, без риска наложиться на кнопки
    LeftPanel (те позиционированы в .lfm вручную построчно по 2).
    FScreenFX создаётся сразу с Enabled=False (тот же дефолт, что и в
    gameviewplay) — эффекта нет, пока дальность 0; FogEditChange включает.

    Стартовые значения — ИЗ ОБЩЕГО ФАЙЛА (LoadFogSettings), а не из
    Defaults (там всегда 0/0): иначе первый же запуск студии молча затирал
    бы нулями то, что игрок ранее подобрал и сохранил для игры — поля
    обязаны редактировать уже сохранённое, а не всегда стартовать с
    выключенного.

    OnChange обоим полям назначается ТОЛЬКО после того, как созданы оба:
    обработчик читает их вместе, а присваивание .Text само поднимает
    OnChange — иначе первое поле дёрнуло бы обработчик, пока второго ещё
    нет. }
  LoadFogSettings(FSettings.FogDistanceM, FSettings.FogClearZoneM);

  FFogLabel := TLabel.Create(Self);
  FFogLabel.Parent  := EndpointsHost;
  FFogLabel.Align   := alTop;
  FFogLabel.AutoSize := False;
  FFogLabel.Height  := 18;
  FFogLabel.BorderSpacing.Around := 4;
  BindUiText(FFogLabel, 'Fog range, m (0 = off; also used by the game):');

  FFogEdit := TEdit.Create(Self);
  FFogEdit.Parent := EndpointsHost;
  FFogEdit.Align  := alTop;
  FFogEdit.BorderSpacing.Around := 4;
  FFogEdit.Text   := FloatToStr(FSettings.FogDistanceM);

  FFogClearLabel := TLabel.Create(Self);
  FFogClearLabel.Parent  := EndpointsHost;
  FFogClearLabel.Align   := alTop;
  FFogClearLabel.AutoSize := False;
  FFogClearLabel.Height  := 18;
  FFogClearLabel.BorderSpacing.Around := 4;
  BindUiText(FFogClearLabel, 'Clear range near the camera, m (0 = fog starts at the camera):');

  FFogClearEdit := TEdit.Create(Self);
  FFogClearEdit.Parent := EndpointsHost;
  FFogClearEdit.Align  := alTop;
  FFogClearEdit.BorderSpacing.Around := 4;
  FFogClearEdit.Text   := FloatToStr(FSettings.FogClearZoneM);

  FFogEdit.OnChange := @FogEditChange;
  FFogEdit.OnExit   := @FogEditChange;
  FFogClearEdit.OnChange := @FogEditChange;
  FFogClearEdit.OnExit   := @FogEditChange;

  FScreenFX := TScreenFX.Create(Viewport);
  FScreenFX.Enabled := False;   { как в игре: весь FX-пайплайн выключен, пока дальность = 0 }
  FogEditChange(FFogEdit);   { применить загруженные значения (обычно 0 → выкл) }

  { DIAGNOSTIC: capture CGE's own log (shadow-map setup) into a dedicated file
    next to the osm3d logs. CastleLog must be initialized for CGE's WritelnLog
    to fire; route it only via OnLog (no stdout). HandleCgeLog filters to
    shadow/projection lines. Remove this block once the shadow issue is done. }
  FCgeShadowLog := TFileLogTarget.Create(
    IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)))
    + 'log' + PathDelim + 'osm3d_cge_shadow.log', llInfo);
  LogEnableStandardOutput := False;
  InitializeLog;
  ApplicationProperties.OnLog.Add(@HandleCgeLog);

  { CLI --reset-tiles: очистить кэш тайлов ДО создания сессии/кэша. }
  if FCliResetTiles then ResetTileCache;

  { Network/cache/OSM progress events are wired to the streaming session's
    own HTTP fetcher when a session starts (see btnGenerateClick). }

  { Flat OSM raster map — created once, hidden until Flat mode. Follows
    the camera on its own; Origin synced to the route centroid when a
    session starts (or when switching to Flat). The btn3D / btnFlat
    controls are defined in the .lfm (parented to LeftPanel). }
  FSlippyMap := TOsm3dSlippyMap.Create(Self);
  FSlippyMap.ServerUrl := 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  { Route tile downloads through the project's caching HTTP fetcher (same
    Osm3dCache / THTTPFetcherWithCache used elsewhere). The fetcher owns its
    own memory byte cache, so tiles evicted from the in-memory scene cache are
    served from bytes instead of being re-downloaded. }
  FSlippyFetcher := THTTPFetcherWithCache.Create(
                      TMemoryCache.Create(DEFAULT_MEMORY_CACHE_BYTES), True);
  FSlippyFetcher.UserAgent := 'Osm3dSlippyMap/1.0 (CGE; +https://github.com/local/osm3d)';
  FSlippyMap.Fetcher := FSlippyFetcher;
  Viewport.Items.Add(FSlippyMap);

  { Kick off IP geolocation in the background. If it returns before a route is
    loaded, the flat map opens near the user (applied from the FPS timer poll). }
  FGeoApplied := FRestoreViewPending;
  { --fit: поиск места по IP пропускается — старт по позиции из FIT. }
  if (FCliFitFile = '') and not FRestoreViewPending then
    FGeoThread := TIpLocateThread.Create;

  { Старт на плоской (slippy) карте: 3D-сессия пока не создана, поэтому 3D-карта
    скрыта, показывается растровая плоская. Как только разрешится IP-геолокация
    (MaybeApplyInitialLocation) или загрузится маршрут — мир центрируется там. }
  SetMapMode(True);

  FFpsLabel := TCastleLabel.Create(Self);
  FFpsLabel.Color        := Vector4(1, 1, 0, 1);
  FFpsLabel.Outline      := 1;
  FFpsLabel.OutlineColor := Vector4(0, 0, 0, 0.7);
  FFpsLabel.FontSize     := 16;
  BindUiText(FFpsLabel, '-- FPS');
  FFpsLabel.Anchor(hpRight, -8);
  FFpsLabel.Anchor(vpTop,   -8);
  ViewportHost.Controls.InsertFront(FFpsLabel);

  { Виджет поиска места — левый верхний угол. Свой Update тикает, пока он
    в дереве UI; видимость переключается в SetMapMode (только плоский режим). }
  FSearchWidget := TOsm3dSearchWidget.Create(Self);
  FSearchWidget.Anchor(hpLeft,  10);
  FSearchWidget.Anchor(vpTop,  -10);
  FSearchWidget.AcceptLanguage := UiLanguage + ',en';
  FSearchWidget.OnPlacePicked  := @SearchPlacePicked;
  FSearchWidget.OnNeedViewBox  := @SearchNeedViewBox;
  FSearchWidget.Exists         := False;   { показывается только во Flat }
  ViewportHost.Controls.InsertFront(FSearchWidget);

  FFpsTimer := TTimer.Create(Self);
  FFpsTimer.Interval := 300;
  FFpsTimer.OnTimer  := @UpdateFps;
  FFpsTimer.Enabled  := True;

  { Скриншот 3D-вида: пункт меню вслед за «Open route», шорткат F5 (как
    в игре). Создаём кодом, чтобы не править .lfm; menu-shortcut ловит F5
    на уровне приложения — надёжнее KeyPreview при фокусе на GL-контроле.
    116 = VK_F5; LCLType в uses не берём: он тенит SyncObjs.TCriticalSection
    своим TCriticalSection = PtrUInt (lcltype.pp:70). }
  miFile.Insert(1, NewItem(UiText('Save screenshot (F5)'),
    Menus.ShortCut(116, []), False, True, @miSaveShotClick, 0, ''));

  { Profiler ticks sit on top of the viewport so they run AFTER every
    per-tile renderer's LocalRender. }
  ViewportHost.Controls.InsertFront(TShaderProfilerTick.Create(Self));
  ViewportHost.Controls.InsertFront(TProfiledSceneTick.Create(Self));

  { DIAGNOSTIC empty-scene count test (no-op when DiagEmptyDrawnScenes = 0). }
  InjectDiagEmptyScenes(Self, Viewport.Camera, DiagEmptyDrawnScenes);

  { Enable the (non-invasive) CPU frame profiler: per-section QPC timing +
    drawn-tile geometry, emitted to the main log every window via
    TOsm3dStreamingMap.Update -> TakePending. Unlike EnableShaderAtomicCounters
    this does NOT touch early-Z / shaders, so the FPS shown stays
    representative. Off by default (SetEnabled was never called); turn off
    here if the periodic log block is unwanted. }
  GlobalCpuProfiler.SetEnabled(True);
  GpuFrameProfilingEnabled := FindCmdLineSwitch('gpuprof');

  { Per-category counters. FS = fragments (AttachCounterEffectApp/FS, counts
    in the universal PLUG_fragment_eye_space hook so PBR buildings count too).
    VS = vertices (AttachCounterEffectVS) on their own slots — these show
    non-zero only if this GPU supports vertex-stage atomic counters; if they
    stay 0, that is the hardware telling you it does not. shadows/farterr
    have no shader shape wired yet, so they stay 0. }
  GlobalShaderProfiler.SetAtomicLabel(PROF_COUNTER_GROUND,     'ground FS');
  GlobalShaderProfiler.SetAtomicLabel(PROF_COUNTER_HOUSES,     'houses FS');
  GlobalShaderProfiler.SetAtomicLabel(PROF_COUNTER_SHADOWS,    'shadows FS');
  GlobalShaderProfiler.SetAtomicLabel(PROF_COUNTER_WATER,      'water FS');
  GlobalShaderProfiler.SetAtomicLabel(PROF_COUNTER_FARTERRAIN, 'farterr FS');
  GlobalShaderProfiler.SetAtomicLabel(PROF_COUNTER_GROUND_VS,  'ground VS');
  GlobalShaderProfiler.SetAtomicLabel(PROF_COUNTER_HOUSES_VS,  'houses VS');
  GlobalShaderProfiler.SetAtomicLabel(PROF_COUNTER_WATER_VS,   'water VS');

  { Per-category GPU atomic counters (houses/ground/water/...) stay OFF by
    default (EnableShaderAtomicCounters = False in Osm3dStudioSettings).
    They are an invasive DIAGNOSTIC: atomicCounterIncrement disables early-Z
    on the tracked shapes (so e.g. occluded building fragments run anyway,
    depressing FPS) and the readback adds overhead — so the numbers, and the
    FPS shown while they're on, are NOT representative. To measure shader
    throughput per category temporarily, set the flag True (e.g. here) and
    rebuild; leave it False for normal use. The trees/shrubs VS/FS counters
    are unaffected — those use free pipeline-statistics queries. }

  UpdateUiState;
  StatusBar1.SimpleText := 'Ready. Open a route (FIT / CSV).';
end;

procedure TStudioMainForm.FormDestroy(Sender: TObject);
begin
  if FHiddenRender then Application.OnIdle := nil;
  if FFpsTimer<>nil then FFpsTimer.Enabled:=False;
  ClosePhotoComparison;
  FreeAndNil(FPhotoCompare);
  SaveViewState;
  TStudioViewport(Viewport).OnPrepareScene := nil;
  FreeAndNil(FShadowAtlas);
  {$IFDEF IAM_LIVE}IamLiveTrack(905);{$ENDIF}
  { TScreenFX — обычный класс (не TComponent), Self его не владеет и не
    освободит сам; та же ручная FreeAndNil, что и в gameviewplay (Stop). }
  FreeAndNil(FScreenFX);
  { DIAGNOSTIC: stop CGE log capture. }
  FreeAndNil(FCgeShadowLog);
  { Tear-down order:
      1. FStreamSession first — joins streaming worker threads and frees
         mounted tile scenes while the GL context is still alive.
      2. Shared tree/shrub GL state must die before CGE destroys the GL
         context with the viewport (formerly via
         TOsm3dMapTransform.CleanupSharedRendererGL). }
  FreeAndNil(FSlippyMap);   { joins its HTTP workers, frees tile scenes }
  FreeAndNil(FSlippyFetcher);  { now no worker can touch it; frees its cache }
  if FGeoThread <> nil then
  begin
    FGeoThread.Terminate;     { WaitFor is bounded by the 4 s fetch timeout }
    FreeAndNil(FGeoThread);   { Destroy joins it (no Synchronize → no deadlock) }
  end;
  { Фоновая сверка высот: дождаться и освободить до разбора формы —
    поток самодостаточен (копии данных), но Log читается формой. }
  if FHeightsWorker <> nil then
  begin
    FHeightsWorker.WaitFor;
    FreeAndNil(FHeightsWorker);
  end;
  ResetPhotoViewRenderTools;
  ShutdownPhotoViewRenderTools;
  FreeAndNil(FPhotoRenderer);
  FreeAndNil(FStreamSession);
  TCastleAbstractTreeRenderer.CleanupSharedGL;
  TCastleAbstractShrubRenderer.CleanupSharedGL;

  { Workers are now joined — no more network callbacks can arrive.
    Drop any DrainNetEvents still queued for the main thread, then
    free the queue. }
  TThread.RemoveQueuedEvents(nil, @DrainNetEvents);
  FreeAndNil(FNetQueue);
  FreeAndNil(FNetCS);

  FreeEndpointPanels;
  FreeAndNil(FEndpointPanels);
end;

procedure TStudioMainForm.SetProceduralTrees(AValue:Boolean);
begin
  ProceduralVegetationActive:=AValue;
  if AValue then BindUiText(FTreesButton, 'Trees: procedural')
  else BindUiText(FTreesButton, 'Trees: legacy');
  SaveViewState;
end;

procedure TStudioMainForm.TreesButtonClick(Sender:TObject);
begin
  SetProceduralTrees(not ProceduralVegetationActive);
end;

procedure TStudioMainForm.SaveViewState;
begin
  FViewState.ProceduralTrees:=ProceduralVegetationActive;
  if not FRestoreViewPending and (Viewport<>nil) and (Viewport.Camera<>nil) and (FSlippyMap<>nil) then begin
    FViewState.HasView:=True;FViewState.FlatMode:=FFlatMode;
    FViewState.HasStream:=FStreamSession<>nil;
    FViewState.Origin:=FStreamOrigin;FViewState.FlatOrigin:=FSlippyMap.Origin;
    FViewState.RouteFile:=FLoadedRoutePath;
    FViewState.Position:=Viewport.Camera.Translation;FViewState.Direction:=Viewport.Camera.Direction;FViewState.Up:=Viewport.Camera.Up;
    FViewState.Has3DView:=FHas3DView;FViewState.Position3D:=FSaved3DPos;
    FViewState.Direction3D:=FSaved3DDir;FViewState.Up3D:=FSaved3DUp;
  end;
  try SaveStudioViewState(StudioViewStatePath,FViewState);
  except on E:Exception do LogMemoAdd('Не удалось сохранить вид Studio: '+E.Message);end;
end;

procedure TStudioMainForm.MaybeRestoreView;
begin
  if not FRestoreViewPending then Exit;
  FRestoreViewPending:=False;FGeoApplied:=True;
  try
    if (FViewState.RouteFile<>'') and FileExists(FViewState.RouteFile) then begin
      try LoadRouteFile(FViewState.RouteFile);
      except on E:Exception do LogMemoAdd('Маршрут не восстановлен: '+E.Message);end;
    end;
    SetMapMode(FViewState.FlatMode);
    if FViewState.HasStream then StartStreaming(FViewState.Origin);
    FSlippyMap.Origin:=FViewState.FlatOrigin;
    Viewport.Camera.SetView(FViewState.Position,FViewState.Direction,FViewState.Up);
    FHas3DView:=FViewState.Has3DView;FSaved3DPos:=FViewState.Position3D;
    FSaved3DDir:=FViewState.Direction3D;FSaved3DUp:=FViewState.Up3D;
    LogMemoAdd('Восстановлены место и камера предыдущего запуска.');
  except on E:Exception do LogMemoAdd('Не удалось восстановить вид Studio: '+E.Message);end;
end;

procedure TStudioMainForm.FreeEndpointPanels;
var
  Pair: specialize TPair<string, TEndpointStatusPanel>;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(906);{$ENDIF}
  if FEndpointPanels = nil then Exit;
  for Pair in FEndpointPanels do
    Pair.Value.Free;
  FEndpointPanels.Clear;
end;

function TStudioMainForm.FindPanelForUrl(const URL: string): TEndpointStatusPanel;
var
  Host: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(908);{$ENDIF}
  Result := nil;
  Host := HostFromUrl(URL);
  if Host = '' then Exit;
  if FEndpointPanels = nil then Exit;
  if not FEndpointPanels.TryGetValue(Host, Result) then
    Result := nil;
end;

procedure TStudioMainForm.UpdateUiState;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(909);{$ENDIF}
  if Length(FRoute) >= 2 then
  begin
    btnGenerate.Enabled := True;
    btnCancel.Enabled   := False;
    StatusBar1.SimpleText :=
      Format('Route: %d points, %.1f km',
        [Length(FRoute),
         TRouteSrc.TotalLengthMeters(FRoute) / 1000]);
  end
  else
  begin
    btnGenerate.Enabled := False;
    btnCancel.Enabled   := False;
    StatusBar1.SimpleText := 'Open a route.';
  end;
end;

procedure TStudioMainForm.SetRouteData(const APts: TRouteLatLonArray;
  AStartUTC: TDateTime; const AAlt: TRouteAltArray);
var I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1749);{$ENDIF}
  SetLength(FRoute, Length(APts));
  for I := 0 to High(APts) do FRoute[I] := APts[I];
  FRouteStartUTC := AStartUTC;
  { Keep the altitude track only when it lines up with the route points. }
  if Length(AAlt) = Length(FRoute) then
    FRouteAltM := AAlt
  else
    SetLength(FRouteAltM, 0);

  LogMemoAdd(Format('Route loaded — %d points, %.2f km',
    [Length(FRoute), TRouteSrc.TotalLengthMeters(FRoute) / 1000]));
  if AStartUTC > 0 then
    LogMemoAdd(Format('  Ride start UTC: %s',
      [FormatDateTime('yyyy-mm-dd hh:nn:ss', AStartUTC)]));

  { Push the new track onto the flat map right away (aligns origin + builds the
    overlay) so it shows without waiting for a mode toggle. Harmless in 3D mode:
    FSlippyMap is hidden there. }
  SyncSlippyOrigin;

  { If the 3D stream is already running (manual start or the IP-geolocation
    auto-start), re-origin it onto the new route: restart at FRoute[0] so the
    camera opens at the start, the route overlay is rebuilt, and the flat map
    (same origin) stays aligned. With no active session yet, leave it — the
    user starts via Generate (a loaded route suppresses the auto-start). }
  if FStreamSession <> nil then
    StartStreaming(FRoute[0]);

  UpdateUiState;
end;

procedure TStudioMainForm.HandleLogMarker;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1750);{$ENDIF}
  { L key — write a timestamped marker into osm3d.log so the moment of
    a visual glitch can be located. Runs on the main thread. }
  LogMemoAdd('######## USER MARKER (L key) ########');
end;

{ Поля тумана (дальность + чистая зона) → FSettings → FScreenFX + общий
  файл (FogConfigPath), который на старте читает игра (gameviewplay,
  тем же TScreenFX). Один обработчик на оба поля: значения лежат в одном
  файле и применяются к одному объекту, разделять нечего.
  Механизм в студии ОДИНАКОВ с игрой: депт-
  шейдер GameScreenFX, а не CGE-нативный TCastleFog — студия тоже рисует
  raw-GL инстансированную траву/деревья (Osm3dRenderInstanced), которые
  TCastleFog не берёт (см. шапку GameScreenFX); прошлая версия этого поля
  честно оставляла их резкими на любой дальности, теперь нет расхождения.
  0/пусто/мусор → туман выключен (Enabled:=False — в студии FX больше
  никто не включает, отдельных кнопок bloom/tone тут нет, так что дальность
  тумана — единственный переключатель всего пайплайна); FScreenFX при
  этом НЕ освобождается, следующее включение просто снова ставит Enabled.
  Локаль: ',' допускается как разделитель (как в остальном парсинге тегов
  проекта, см. WaterwayHalfW в Osm3dGeomBridges), реальный ввод формы —
  единственное место, где это вообще нужно. }
procedure TStudioMainForm.FogEditChange(Sender: TObject);

  { ',' допускается как разделитель (как в остальном парсинге проекта, см.
    WaterwayHalfW в Osm3dGeomBridges); мусор/пусто → 0; отрицательное → 0. }
  function EditValue(AEdit: TEdit): Single;
  begin
    Result := StrToFloatDef(
      StringReplace(Trim(AEdit.Text), ',', '.', [rfReplaceAll]), 0);
    if Result < 0 then Result := 0;
  end;

var
  Dist, Clear: Single;
begin
  if (FFogEdit = nil) or (FFogClearEdit = nil) then Exit;
  Dist  := EditValue(FFogEdit);
  Clear := EditValue(FFogClearEdit);
  FSettings.FogDistanceM  := Dist;
  FSettings.FogClearZoneM := Clear;
  { оба значения одной записью — раздельная затирала бы соседнее }
  SaveFogSettings(Dist, Clear);   { игра прочитает при следующем старте сессии }
  if FScreenFX = nil then Exit;   { до FormCreate/после Destroy }
  { Чистая зона ставится ВСЕГДА (в т.ч. при выключенном тумане): она не
    гейт, а параметр — при следующем включении дальности значение уже на
    месте, повторно его дублировать не нужно. }
  FScreenFX.FogClearZone := Clear;
  if Dist > 0 then
  begin
    FScreenFX.FogRange := Dist;
    FScreenFX.Enabled  := True;
  end
  else
    FScreenFX.Enabled := False;
end;

procedure TStudioMainForm.HandleFpsModeChanged(NewMode: TFpsLimitMode);
var S: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(915);{$ENDIF}
  { Runs on the main thread (key input is dispatched there), so we can
    touch the log memo directly. }
  case NewMode of
    flmVsyncOn:
      S := 'vsync ON — synced to display (~60 FPS), no tearing';
    flmVsyncOffMax:
      S := 'vsync OFF — uncapped, max FPS (tearing; shows GPU ceiling)';
    flmVsyncOffLow:
      S := 'vsync OFF + 30 FPS cap — battery saver';
  end;
  LogMemoAdd('[V] ' + S);
end;

procedure TStudioMainForm.EnqueueNetEvent(const AEvent: TNetEvent);
var
  NeedPost: Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1751);{$ENDIF}
  { Called on a worker thread. Snapshot the event into the queue under
    a short lock, then hand off to the main thread with the NON-blocking
    TThread.Queue — the worker never waits for the main thread, so a
    busy main thread can no longer stall network/heightmap fetches.

    COALESCING: a single DrainNetEvents drains the WHOLE queue, so we
    post it only when one is not already pending. Without this, heavy
    streaming (hundreds of events, OnNetworkProgress firing many times
    per download) floods the main thread's TThread.Queue list with
    thousands of redundant DrainNetEvents calls, which starves the
    render loop — the logs showed a 200 s UI stall from exactly this. }
  if (FNetQueue = nil) or (FNetCS = nil) then Exit;
  if (MainThreadID = 0) or (GetCurrentThreadID = MainThreadID) then
  begin
    { Already on the main thread — enqueue and drain inline. }
    FNetCS.Acquire;
    try
      FNetQueue.Enqueue(AEvent);
    finally
      FNetCS.Release;
    end;
    DrainNetEvents;
    Exit;
  end;
  NeedPost := False;
  FNetCS.Acquire;
  try
    { Progress events are cosmetic (a progress bar) and the highest-
      volume kind. If the queue is already backed up, drop them rather
      than let them pile unboundedly — essential events (request,
      success, error, cache, tile) are always kept. }
    if (AEvent.Kind = nekProgress) and (FNetQueue.Count >= 64) then
      Exit;
    FNetQueue.Enqueue(AEvent);
    { Post a drain only if one is not already in flight. }
    NeedPost := not FNetDrainQueued;
    if NeedPost then
      FNetDrainQueued := True;
  finally
    FNetCS.Release;
  end;
  if NeedPost then
    try
      TThread.Queue(nil, @DrainNetEvents);
    except
      FNetCS.Acquire;
      try FNetDrainQueued := False; finally FNetCS.Release; end;
    end;
end;

procedure TStudioMainForm.DrainNetEvents;
var
  Ev:    TNetEvent;
  HaveOne: Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1752);{$ENDIF}
  { Runs on the main thread. Clears the in-flight flag first (under the
    lock) so any event enqueued from now on posts a fresh drain. Then
    pops one event at a time under the lock and applies it OUTSIDE the
    lock (the DoApply* handlers touch the UI and must not run while a
    worker holds FNetCS). The FPend* fields are only ever written here,
    on the main thread, so reusing them to feed the unchanged DoApply*
    bodies is race-free. }
  if (FNetQueue = nil) or (FNetCS = nil) then Exit;
  FNetCS.Acquire;
  try
    FNetDrainQueued := False;
  finally
    FNetCS.Release;
  end;
  repeat
    HaveOne := False;
    FNetCS.Acquire;
    try
      if FNetQueue.Count > 0 then
      begin
        Ev := FNetQueue.Dequeue;
        HaveOne := True;
      end;
    finally
      FNetCS.Release;
    end;
    if not HaveOne then Break;

    { Marshal the snapshot into the scratch fields the DoApply* methods
      read, then dispatch by kind. }
    FPendURL        := Ev.URL;
    FPendMethod     := Ev.Method;
    FPendErr        := Ev.Err;
    FPendEndpoint   := Ev.Endpoint;
    FPendBytes      := Ev.Bytes;
    FPendTotal      := Ev.Total;
    FPendElapsed    := Ev.Elapsed;
    FPendBodySize   := Ev.BodySize;
    FPendStatusCode := Ev.StatusCode;
    FPendAttempt    := Ev.Attempt;
    FPendTile       := Ev.Tile;
    FPendTileIndex  := Ev.TileIndex;
    FPendTileTotal  := Ev.TileTotal;
    FPendSuccess    := Ev.Success;
    FPendWorkerIdx  := Ev.WorkerIdx;

    case Ev.Kind of
      nekRequest:    DoApplyNetRequest;
      nekProgress:   DoApplyNetProgress;
      nekSuccess:    DoApplyNetSuccess;
      nekCacheHit:   DoApplyCacheHit;
      nekError:      DoApplyNetError;
      nekOsmTile:    DoApplyOsmTile;
      nekOsmAttempt: DoApplyOsmAttempt;
    end;
  until False;
end;

procedure TStudioMainForm.LogMemoAdd(const Line: string);
var
  I: Integer;
  T0, TMs: QWord;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(918);{$ENDIF}
  if LogMemo = nil then Exit;
  T0 := GetTickCount64;
  LogMemo.Lines.BeginUpdate;
  try
    LogMemo.Lines.Add(Line);
    if LogMemo.Lines.Count > LOG_MEMO_MAX_LINES then
      for I := 1 to TRIM_BATCH do
        LogMemo.Lines.Delete(0);
  finally
    LogMemo.Lines.EndUpdate;
  end;
  LogMemo.SelStart  := Length(LogMemo.Text);
  LogMemo.SelLength := 0;
  { Diagnostic: updating the log TMemo runs on the MAIN thread. Every
    worker log line is marshalled here via Synchronize, so a slow memo
    stalls the worker AND the frame. A slow line is appended directly
    to the memo (no re-entry through the log pipeline) with a guard so
    the diagnostic itself is never measured / never recurses. }
  TMs := GetTickCount64 - T0;
  if (TMs >= 100) and (not FInLogMemoDiag) then
  begin
    FInLogMemoDiag := True;
    try
      LogMemo.Lines.Add(Format('>>> LogMemoAdd SLOW — %d ms for one line '
        + '(TMemo has %d lines; main-thread UI stall)',
        [TMs, LogMemo.Lines.Count]));
    finally
      FInLogMemoDiag := False;
    end;
  end;
end;

procedure TStudioMainForm.HandleCgeLog(const AMsg: string);
begin
  { CGE's WritelnLog may fire on a worker thread (scene load); TFileLogTarget
    is thread-safe. Keep only shadow-map-relevant lines to stay focused. }
  if FCgeShadowLog = nil then Exit;
  if ((Pos('shader', LowerCase(AMsg)) > 0) and
      (Pos('error', LowerCase(AMsg)) > 0)) or
     (Pos('shadow', LowerCase(AMsg)) > 0) or
     (Pos('projection', LowerCase(AMsg)) > 0) then
    FCgeShadowLog.Write(llInfo, AMsg);
end;

procedure TStudioMainForm.HandleStreamLog(const AMsg: string);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(919);{$ENDIF}
  LogMemoAdd(AMsg);
end;

{ Network / OSM event handlers (worker thread → SafeSync) }

procedure TStudioMainForm.HandleNetRequest(Sender: TObject;
  const URL, Method: string; BodySize: Integer);
var
  Ev: TNetEvent;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(921);{$ENDIF}
  Ev := Default(TNetEvent);
  Ev.Kind     := nekRequest;
  Ev.URL      := URL;
  Ev.Method   := Method;
  Ev.BodySize := BodySize;
  EnqueueNetEvent(Ev);
end;

procedure TStudioMainForm.DoApplyNetRequest;
var
  Panel: TEndpointStatusPanel;
  Line:  string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(922);{$ENDIF}
  Panel := FindPanelForUrl(FPendURL);
  if Panel <> nil then
    Panel.ApplyRequestStarted(ShortenUrl(FPendURL, 60));
  if FPendMethod = 'GET' then
    Line := Format('→ GET %s', [ShortenUrl(FPendURL, 90)])
  else
    Line := Format('→ %s %s (body %s)',
      [FPendMethod, ShortenUrl(FPendURL, 80), FormatBytes(FPendBodySize)]);
  { Route into the common log so network activity is visible in
    osm3d.log alongside everything else. }
  LogMemoAdd(Line);
end;

procedure TStudioMainForm.HandleNetProgress(Sender: TObject;
  const URL, Method: string;
  Received, Total: Int64; ElapsedMs: Int64);
var
  Ev: TNetEvent;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(923);{$ENDIF}
  Ev := Default(TNetEvent);
  Ev.Kind    := nekProgress;
  Ev.URL     := URL;
  Ev.Method  := Method;
  Ev.Bytes   := Received;
  Ev.Total   := Total;
  Ev.Elapsed := ElapsedMs;
  EnqueueNetEvent(Ev);
end;

procedure TStudioMainForm.DoApplyNetProgress;
var
  Panel: TEndpointStatusPanel;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(924);{$ENDIF}
  Panel := FindPanelForUrl(FPendURL);
  if Panel <> nil then
    Panel.ApplyProgress(FPendBytes, FPendTotal, FPendElapsed);
end;

procedure TStudioMainForm.HandleNetSuccess(Sender: TObject;
  const URL, Method: string; StatusCode: Integer;
  ResponseSize: Int64; ElapsedMs: Int64);
var
  Ev: TNetEvent;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(925);{$ENDIF}
  Ev := Default(TNetEvent);
  Ev.Kind       := nekSuccess;
  Ev.URL        := URL;
  Ev.Method     := Method;
  Ev.StatusCode := StatusCode;
  Ev.Bytes      := ResponseSize;
  Ev.Elapsed    := ElapsedMs;
  EnqueueNetEvent(Ev);
end;

procedure TStudioMainForm.DoApplyNetSuccess;
var
  Panel: TEndpointStatusPanel;
  Line:  string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(926);{$ENDIF}
  Panel := FindPanelForUrl(FPendURL);
  if Panel <> nil then
    Panel.ApplyHttpSuccess(FPendStatusCode, FPendBytes, FPendElapsed);
  Line := Format('← %d %s %s (%s, %d ms)',
    [FPendStatusCode, FPendMethod, ShortenUrl(FPendURL, 70),
     FormatBytes(FPendBytes), FPendElapsed]);
  { Completion event into the common log — marks when a download
    actually finished, with status, size and elapsed time. }
  LogMemoAdd(Format('DOWNLOAD COMPLETE — %s', [Line]));
end;

procedure TStudioMainForm.HandleCacheHit(Sender: TObject;
  const URL: string; SizeBytes: Int64);
var
  Ev: TNetEvent;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(927);{$ENDIF}
  Ev := Default(TNetEvent);
  Ev.Kind  := nekCacheHit;
  Ev.URL   := URL;
  Ev.Bytes := SizeBytes;
  EnqueueNetEvent(Ev);
end;

procedure TStudioMainForm.DoApplyCacheHit;
var
  Panel: TEndpointStatusPanel;
  Line:  string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(928);{$ENDIF}
  Panel := FindPanelForUrl(FPendURL);
  if Panel <> nil then
    Panel.ApplyCacheHit(FPendBytes);
  Line := Format('● cache %s (%s)',
    [ShortenUrl(FPendURL, 80), FormatBytes(FPendBytes)]);
  LogMemoAdd(Line);
end;

procedure TStudioMainForm.HandleNetError(Sender: TObject;
  const URL, ErrorMsg: string; Attempt: Integer;
  PartialSize: Int64; ElapsedMs: Int64);
var
  Ev: TNetEvent;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(929);{$ENDIF}
  Ev := Default(TNetEvent);
  Ev.Kind    := nekError;
  Ev.URL     := URL;
  Ev.Err     := ErrorMsg;
  Ev.Attempt := Attempt;
  Ev.Bytes   := PartialSize;
  Ev.Elapsed := ElapsedMs;
  EnqueueNetEvent(Ev);
end;

procedure TStudioMainForm.DoApplyNetError;
var
  Tail:  string;
  Panel: TEndpointStatusPanel;
  Line:  string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(930);{$ENDIF}
  if FPendBytes > 0 then
    Tail := Format(' (got %s in %d ms)', [FormatBytes(FPendBytes), FPendElapsed])
  else if FPendElapsed > 0 then
    Tail := Format(' (after %d ms)', [FPendElapsed])
  else
    Tail := '';
  Panel := FindPanelForUrl(FPendURL);
  if Panel <> nil then
    Panel.ApplyHttpError(FPendErr, FPendElapsed);
  Line := Format('✗ %s [#%d] %s%s',
    [ShortenUrl(FPendURL, 60), FPendAttempt, FPendErr, Tail]);
  { Failure is also a load-ended event — route it into the common log. }
  LogMemoAdd(Format('DOWNLOAD FAILED — %s', [Line]));
end;

procedure TStudioMainForm.DoApplyOsmTile;
var
  Host:  string;
  Panel: TEndpointStatusPanel;
  Line:  string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(932);{$ENDIF}
  Host := HostFromUrl(FPendEndpoint);

  Inc(FTilesDone);
  if FPendTileTotal > 0 then
  begin
    FTilesTotal := FPendTileTotal;
    FOverallProgress.Max := FPendTileTotal;
    FOverallProgress.Position := FPendTileIndex;
  end;
  FOverallLabel.Caption := Format(UiText('OSM tiles: %d / %d'),
    [FPendTileIndex, FPendTileTotal]);

  if (FEndpointPanels <> nil) and FEndpointPanels.TryGetValue(Host, Panel) then
    Panel.ApplyTileFinal(FPendSuccess);

  if FPendSuccess then
    Line := Format('▣ tile %d/%d (%d,%d) ok ← %s  (%s, %d ms)',
      [FPendTileIndex, FPendTileTotal, FPendTile.X, FPendTile.Y, Host,
       FormatBytes(FPendBytes), FPendElapsed])
  else
    Line := Format('▣ tile %d/%d (%d,%d) FAILED on all mirrors — %s',
      [FPendTileIndex, FPendTileTotal, FPendTile.X, FPendTile.Y, FPendErr]);
  { Route tile fetches (heightmap / OSM data) into the common log too —
    these are the network events that overlap geometry building, so
    osm3d.log must show them next to the build steps. }
  LogMemoAdd(Line);
end;

procedure TStudioMainForm.DoApplyOsmAttempt;
var
  Host:    string;
  Panel:   TEndpointStatusPanel;
  TileStr: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(934);{$ENDIF}
  Host := HostFromUrl(FPendEndpoint);
  if (FEndpointPanels <> nil) and FEndpointPanels.TryGetValue(Host, Panel) then
  begin
    TileStr := Format('(%d,%d)', [FPendTile.X, FPendTile.Y]);
    Panel.ApplyOsmAttempt(TileStr, FPendTileIndex, FPendTileTotal,
                          FPendSuccess, FPendBytes, FPendElapsed, FPendErr);
  end;
end;

procedure TStudioMainForm.LoadRouteFile(const FileName: string);
var
  Ext: string;
  FN:  string;
  Pts: TRouteLatLonArray;
  {$IFDEF OSM3D_WITH_FITFILE}
  Alt:      TRouteAltArray;
  Lat, Lon: Double;
  StartUTC: TDateTime;
  {$ENDIF}
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(935);{$ENDIF}
  { Толерантность к пути: если файла нет как задан, пробуем одноимённый в
    подпапке routes\ рядом (стандартное хранилище заездов users\Admin\routes).
    Без этого путь без routes\ падал вводящей в заблуждение ошибкой
    «does not contain enough GPS points» — файл при этом просто не находился. }
  FN := FileName;
  if not FileExists(FN) then
  begin
    if FileExists(IncludeTrailingPathDelimiter(ExtractFilePath(FN)) +
                  'routes' + PathDelim + ExtractFileName(FN)) then
    begin
      FN := IncludeTrailingPathDelimiter(ExtractFilePath(FN)) +
            'routes' + PathDelim + ExtractFileName(FN);
      LogMemoAdd('route: файл не найден как задан, взят из routes\: ' + FN);
    end
    else
      raise Exception.CreateFmt('Route file not found: %s', [FileName]);
  end;
  Ext := LowerCase(ExtractFileExt(FN));
  if Ext = '.csv' then
  begin
    Pts := TCsvRouteLoader.Load(FN);
    if Length(Pts) < 2 then
      raise Exception.Create('CSV route must contain at least 2 points.');
    { CSV — не FIT: банк заездов не построить, коррекция террейна не
      активируется. Сбрасываем ДО SetRouteData (внутри возможен рестарт
      сессии, читающий FRouteFitPath). }
    FRouteFitPath := '';
    SetRouteData(Pts, 0, nil);
  end
  else if (Ext = '.fit') or (Ext = '.gpx') then
  begin
    {$IFDEF OSM3D_WITH_FITFILE}
    { GPX идёт тем же конвейером, что FIT: TFitAdapter через фабрику
      NewRouteParserForFile создаёт TGpxFile, дальше — без различий
      (высоты <ele>, старт-UTC из <time>, банк заездов по папке файла). }
    Pts := TFitAdapter.LoadAsLatLonArray(FN, Lat, Lon, StartUTC, Alt);
    if Length(Pts) < 2 then
      raise Exception.CreateFmt(
        'Route %s does not contain enough GPS points (need >= 2)', [FN]);
    { Запоминаем путь ДО SetRouteData: внутри возможен рестарт сессии
      (StartStreaming), который передаст папку заездов карте. Разворот в
      АБСОЛЮТНЫЙ (ExpandFileName): при запуске через параметр exe путь
      часто относительный / рабочий каталог не тот — иначе
      ExtractFilePath пуст (папка заездов не задаётся) и CSV высот уходит
      в непредсказуемый CWD. OpenDialog и так даёт абсолютный — разворот
      там холостой. }
    FRouteFitPath := ExpandFileName(FN);
    SetRouteData(Pts, StartUTC, Alt);
    {$ELSE}
    raise Exception.Create('FIT support is not included in this build.');
    {$ENDIF}
  end
  else
    raise Exception.Create('Unsupported route format: ' + Ext);
  FLoadedRoutePath:=ExpandFileName(FN);
end;

procedure TStudioMainForm.miOpenFitClick(Sender: TObject);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(936);{$ENDIF}
  BindUiText(OpenDialog1, 'Open route', 'Title');
  OpenDialog1.Filter :=
    'All routes|*.fit;*.csv;*.gpx|FIT|*.fit|CSV|*.csv|GPX|*.gpx';
  if not OpenDialog1.Execute then Exit;
  try
    LoadRouteFile(OpenDialog1.FileName);
  except
    on E: Exception do
      ShowMessage(UiText('Route load error: ') + E.Message);
  end;
end;

procedure TStudioMainForm.btnGenerateClick(Sender: TObject);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(941);{$ENDIF}
  if Length(FRoute) < 2 then
  begin
    ShowMessage(UiText('Load a route first (FIT / CSV).'));
    Exit;
  end;
  { Manual start: origin = the route's first point, so the 3D view opens at the
    beginning of the route (the camera is placed over the origin). }
  StartStreaming(FRoute[0]);
end;

procedure TStudioMainForm.ParseCommandLine;
var
  I: Integer;
  P, PL: string;
  PrevFit: Boolean;
begin
  FCliResetTiles := False;
  FCliFitFile := '';
  FCliFitStarted := False;
  FCliShotFile := '';
  FCliShotDelay := 20;
  FCliShotExit := False;
  FCliCamAlt := 300.0;
  FShotArmedAt := 0;
  PrevFit := False;
  for I := 1 to ParamCount do
  begin
    P  := ParamStr(I);
    PL := LowerCase(P);
    if PrevFit then begin FCliFitFile := P; PrevFit := False; Continue; end;
    if (PL = '--reset-tiles') or (PL = '--reset-cache') or (PL = '--clear-tiles') then
      FCliResetTiles := True
    else if PL = '--fit' then
      PrevFit := True                       { --fit <path> }
    else if Copy(PL, 1, 6) = '--fit=' then
      FCliFitFile := Copy(P, 7, MaxInt)     { --fit=<path> }
    else if Copy(PL, 1, 7) = '--shot=' then
      FCliShotFile := Copy(P, 8, MaxInt)    { --shot=<png> }
    else if Copy(PL, 1, 13) = '--shot-delay=' then
      FCliShotDelay := StrToIntDef(Copy(P, 14, MaxInt), 20)
    else if PL = '--shot-exit' then
      FCliShotExit := True
    else if Copy(PL, 1, 10) = '--cam-alt=' then
      FCliCamAlt := StrToFloatDef(Copy(P, 11, MaxInt), 300.0,
        DefaultFormatSettings)
    else if ((LowerCase(ExtractFileExt(P)) = '.fit') or
             (LowerCase(ExtractFileExt(P)) = '.gpx')) and
            (FileExists(P) or
             FileExists(IncludeTrailingPathDelimiter(ExtractFilePath(P)) +
                        'routes' + PathDelim + ExtractFileName(P))) then
      FCliFitFile := P;                     { позиционный ride.fit / track.gpx
                                                (LoadRouteFile доберёт routes\) }
  end;
end;

procedure TStudioMainForm.ResetTileCache;
var
  TileDir: string;
begin
  { Кэш тайлов — подпапка o3dt под корнем кэша; http-байты лежат прямо в корне,
    поэтому удаляем ТОЛЬКО o3dt. }
  TileDir := IncludeTrailingPathDelimiter(
              TOsm3dStreamingSession.EffectiveCacheRoot(FSettings)) + 'o3dt';
  if DirectoryExists(TileDir) then
  begin
    if DeleteDirectory(TileDir, False) then
      LogMemoAdd('CLI --reset-tiles: кэш тайлов очищен: ' + TileDir)
    else
      LogMemoAdd('CLI --reset-tiles: НЕ удалось очистить: ' + TileDir);
  end
  else
    LogMemoAdd('CLI --reset-tiles: кэш тайлов отсутствует: ' + TileDir);
end;

procedure TStudioMainForm.MaybeStartFromFit;
begin
  if (FCliFitFile = '') or FCliFitStarted then Exit;
  FCliFitStarted := True;
  try
    LoadRouteFile(FCliFitFile);        { .fit -> SetRouteData -> FRoute }
    if Length(FRoute) >= 1 then
    begin
      FFlatMode := False;              { 3D, не плоская карта }
      StartStreaming(FRoute[0]);       { старт с позиции из FIT }
      LogMemoAdd('CLI --fit: 3D-стриминг с позиции FIT: ' + FCliFitFile);
      if FCliCamAlt <> 300.0 then
      begin
        { --cam-alt: опускаем камеру (уровень райдера ~10-20 м). Направление
          чуть более горизонтальное, чтобы в кадр попала дорога впереди. }
        Viewport.Camera.SetView(
          Vector3(0.0, FCliCamAlt, 0.0),
          Vector3(0.25, -0.30, -0.92),
          Vector3(0.0, 1.0, 0.0));
        LogMemoAdd(Format('CLI --cam-alt: камера на %.0f м', [FCliCamAlt]));
      end;
      if FCliShotFile <> '' then
      begin
        FShotArmedAt := GetTickCount64;   { взвод автоснимка --shot }
        LogMemoAdd(Format('CLI --shot: снимок через %d с: %s',
          [FCliShotDelay, FCliShotFile]));
      end;
    end
    else
      LogMemoAdd('CLI --fit: в файле нет точек маршрута: ' + FCliFitFile);
  except
    on E: Exception do
      LogMemoAdd('CLI --fit: ошибка загрузки: ' + E.Message);
  end;
end;

procedure TStudioMainForm.SaveViewportShot(const FileName: string);
var
  Img: TRGBImage;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(937);{$ENDIF}
  if (ViewportHost = nil) or (ViewportHost.Container = nil) then
    raise Exception.Create(UiText('The 3D view is not ready yet'));
  if ExtractFilePath(FileName) <> '' then
    ForceDirectories(ExtractFilePath(FileName));
  { SaveScreen читает framebuffer контрола из GL — окно может быть свёрнуто
    или перекрыто, кадр всё равно полный (в отличие от снимка экрана). }
  Img := ViewportHost.Container.SaveScreen(
    Rectangle(0, 0, ViewportHost.Width, ViewportHost.Height));
  try
    SaveImage(Img, FileName);
  finally
    Img.Free;
  end;
end;

procedure TStudioMainForm.MaybeTakeShot;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(938);{$ENDIF}
  if (FCliShotFile = '') or (FShotArmedAt = 0) then Exit;
  if GetTickCount64 - FShotArmedAt < QWord(FCliShotDelay) * 1000 then Exit;
  FShotArmedAt := 0;                     { одноразово }
  try
    SaveViewportShot(FCliShotFile);
    LogMemoAdd('CLI --shot: кадр сохранён: ' + FCliShotFile);
  except
    on E: Exception do
      LogMemoAdd('CLI --shot: ошибка сохранения: ' + E.Message);
  end;
  if FCliShotExit then Close;
end;

procedure TStudioMainForm.miSaveShotClick(Sender: TObject);
var
  FN: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(939);{$ENDIF}
  FN := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'shots';
  ForceDirectories(FN);
  FN := IncludeTrailingPathDelimiter(FN) +
    'osm3d_shot_' + FormatDateTime('yyyymmdd_hhnnss_zzz', Now) + '.png';
  try
    SaveViewportShot(FN);
    LogMemoAdd('скриншот: ' + FN);
  except
    on E: Exception do
      LogMemoAdd('скриншот: ошибка: ' + E.Message);
  end;
end;

{ Три канала высот вдоль маршрута: FIT (барометр, эталон формы),
  поверхность мира (ближайшая вершина ground-мешей тайла — те же высоты,
  что у красных сфер) и дорога (вершины ИМЕННО снапнутой way — семантика
  зелёных сфер, настил моста несёт id мостовой way). Узловые уклоны,
  коэффициенты K и корреляция — как ComputeDemComparison игры; статистика,
  которая там идёт в лабелы (AddStatRow), здесь пишется в шапку CSV. }

type
  { Фоновая сверка высот и запись <fit>-heights.csv. Все данные — КОПИИ,
    снятые на главном потоке при старте: с формой, сессией и картой поток
    не взаимодействует (корректор — собственный клон через CopyFrom).
    Результат — строки в Log; форма забирает их поллингом Finished из
    UpdateFps и пишет в memo на главном потоке. }
  THeightsCsvWorker = class(TThread)
  private
    FRoute:    TRouteLatLonArray;
    FAltM:     TRouteAltArray;
    FAltCalM:  TRouteAltArray;   { скорректированный (датумный) фит }
    { ЧИСТЫЙ Terrarium под точками маршрута — колонка alt_dem_m.
      Копия Map.RouteDem (снят картой в CaptureRouteDem: GetRegion +
      SampleBilinear, тем же методом и на том же зуме, что Bank[].Dem в
      Osm3dFitBank). Это НЕЗАВИСИМЫЙ референс и одновременно точный вход
      сплайна коррекции: по CSV становится проверяемым само правило
      V(d) = медиана(fit − dem) в окне ±HALF_M.
      Отдельный канал нужен потому, что alt_surf_m независимым не является:
      FIT-слой запекается в геометрию тайла на генерации (сигнатура слоя
      входит в gen-hash), так что меш несёт коррекцию, даже когда
      ApplyToTileModel к нему не применяли. Пусто → колонка пустая; молчаливо
      подставлять меш или фит нельзя — это превратит референс в фикцию. }
    FDemM:     TRouteAltArray;
    FSnapPts:  TRouteLatLonArray;
    FSnapWays: TRouteWayIdArray;
    FFitPath:  string;
    FCacheRoot, FGenHash: string;
    FZoom:     Integer;
    FOrigin:   TLatLon;
    FCorr:     TFitCorrection;   { собственная копия — владеем }
    procedure RunComparison;
  public
    Log: TStringList;            { результат для LogMemoAdd формы }
    constructor Create(const ARoute: TRouteLatLonArray;
      const AAltM, AAltCalM, ADemM: TRouteAltArray;
      const ASnapPts: TRouteLatLonArray;
      const ASnapWays: TRouteWayIdArray; const AFitPath, ACacheRoot,
      AGenHash: string; AZoom: Integer; const AOrigin: TLatLon;
      ACorr: TFitCorrection);
    destructor Destroy; override;
    procedure Execute; override;
  end;

constructor THeightsCsvWorker.Create(const ARoute: TRouteLatLonArray;
  const AAltM, AAltCalM, ADemM: TRouteAltArray;
  const ASnapPts: TRouteLatLonArray;
  const ASnapWays: TRouteWayIdArray; const AFitPath, ACacheRoot,
  AGenHash: string; AZoom: Integer; const AOrigin: TLatLon;
  ACorr: TFitCorrection);
begin
  FRoute    := Copy(ARoute, 0, Length(ARoute));
  FAltM     := Copy(AAltM, 0, Length(AAltM));
  FAltCalM  := Copy(AAltCalM, 0, Length(AAltCalM));
  FDemM     := Copy(ADemM, 0, Length(ADemM));
  FSnapPts  := Copy(ASnapPts, 0, Length(ASnapPts));
  FSnapWays := Copy(ASnapWays, 0, Length(ASnapWays));
  FFitPath  := AFitPath;
  FCacheRoot := ACacheRoot;
  FGenHash  := AGenHash;
  FZoom     := AZoom;
  FOrigin   := AOrigin;
  FCorr     := ACorr;          { владение переходит воркеру }
  Log := TStringList.Create;
  inherited Create(False);
end;

destructor THeightsCsvWorker.Destroy;
begin
  FCorr.Free;
  Log.Free;
  inherited Destroy;
end;

procedure THeightsCsvWorker.Execute;
begin
  try
    RunComparison;
  except
    on E: Exception do
      Log.Add('[heights] ошибка фоновой сверки: ' + E.Message);
  end;
end;

procedure THeightsCsvWorker.RunComparison;
const
  STEP_M = 100.0;
  GRADE_HALF = 2;      { окно уклона: ±2 узла = 5 точек, база 400 м }
  GRADE_MIN  = 0.010;  { |уклон DEM| ниже 1% — рельеф незначим }
var
  I, K, NNodes, I0, I1, NSig: Integer;
  DistAcc: Double;
  DemAll, PathDist: array of Double;
  TileCache: TGeoTileCache;
  Model: TTileModel;
  T, CurTile: TGeoTileId;
  HaveTile, HaveLastY: Boolean;
  CV, WV: TVector3;
  CenX, CenZ, LastY, SurfY: Single;
  Proj: TLocalProjection;
  { пространственный хэш вершин ground-мешей текущего тайла }
  HashX, HashZ, HashY: array of Single;
  HashHead: array of Integer;    { NB×NB голов списков }
  HashNext: array of Integer;
  HMinX, HMinZ, HInv: Single;
  HNB: Integer;
  { way-индекс: вершины с OsmId<>0, отсортированы по id — высота
    зелёного канала берётся с вершин ИМЕННО снапнутой way }
  HashId: array of Int64;
  WayIdx: array of Integer;      { индексы вершин, sort by HashId }
  WayN: Integer;

  { Хэш вершин ground-мешей тайла: ячейки BUCKET_M, связные списки.
    Семантика набора мешей — как у красных сфер (GROUND_MESH_KINDS). }
  procedure BuildGroundHash(AModel: TTileModel; AWithRoad: Boolean = False);
  const
    GROUND_KINDS = [smkTerrain, smkGrass, smkSurface, smkSand,
                    smkFarmland, smkForest];
    ROAD_KINDS = [smkRoad, smkRoadMajor, smkRoadSecondary, smkRoadMinor,
                  smkRoadService, smkRoadFootway, smkRoadCycleway];
    BUCKET_M = 6.0;
  var
    MI, V, NV, GX, GZ, Cell: Integer;
    Msh: TMesh;
    MV: TMeshVertexArray;
    MinX, MaxX, MinZ, MaxZ: Single;
  begin
    HNB := 0;
    SetLength(HashHead, 0);
    { границы и число вершин }
    NV := 0;
    MinX := 0; MaxX := 0; MinZ := 0; MaxZ := 0;
    for MI := 0 to AModel.MeshCount - 1 do
    begin
      if not ((AModel.Meshes[MI].Material in GROUND_KINDS)
           or (AWithRoad and (AModel.Meshes[MI].Material in ROAD_KINDS)))
      then Continue;
      Msh := AModel.Meshes[MI].Mesh;
      if Msh = nil then Continue;
      MV := Msh.Vertices;
      for V := 0 to Msh.VertexCount - 1 do
      begin
        if NV = 0 then
        begin
          MinX := MV[V].Position.X; MaxX := MinX;
          MinZ := MV[V].Position.Z; MaxZ := MinZ;
        end
        else
        begin
          if MV[V].Position.X < MinX then MinX := MV[V].Position.X;
          if MV[V].Position.X > MaxX then MaxX := MV[V].Position.X;
          if MV[V].Position.Z < MinZ then MinZ := MV[V].Position.Z;
          if MV[V].Position.Z > MaxZ then MaxZ := MV[V].Position.Z;
        end;
        Inc(NV);
      end;
    end;
    if NV = 0 then Exit;

    HMinX := MinX;
    HMinZ := MinZ;
    HInv := 1.0 / BUCKET_M;
    HNB := Trunc(Max(MaxX - MinX, MaxZ - MinZ) * HInv) + 2;
    SetLength(HashHead, HNB * HNB);
    for Cell := 0 to HNB * HNB - 1 do HashHead[Cell] := -1;
    SetLength(HashX, NV);
    SetLength(HashZ, NV);
    SetLength(HashY, NV);
    SetLength(HashNext, NV);
    SetLength(HashId, NV);

    NV := 0;
    for MI := 0 to AModel.MeshCount - 1 do
    begin
      if not ((AModel.Meshes[MI].Material in GROUND_KINDS)
           or (AWithRoad and (AModel.Meshes[MI].Material in ROAD_KINDS)))
      then Continue;
      Msh := AModel.Meshes[MI].Mesh;
      if Msh = nil then Continue;
      MV := Msh.Vertices;
      for V := 0 to Msh.VertexCount - 1 do
      begin
        HashX[NV] := MV[V].Position.X;
        HashZ[NV] := MV[V].Position.Z;
        HashY[NV] := MV[V].Position.Y;
        HashId[NV] := MV[V].OsmId;
        GX := Trunc((HashX[NV] - HMinX) * HInv);
        GZ := Trunc((HashZ[NV] - HMinZ) * HInv);
        if GX < 0 then GX := 0; if GX > HNB - 1 then GX := HNB - 1;
        if GZ < 0 then GZ := 0; if GZ > HNB - 1 then GZ := HNB - 1;
        Cell := GZ * HNB + GX;
        HashNext[NV] := HashHead[Cell];
        HashHead[Cell] := NV;
        Inc(NV);
      end;
    end;

    { way-индекс: сбор + shell-sort по HashId }
    SetLength(WayIdx, NV);
    WayN := 0;
    for V := 0 to NV - 1 do
      if HashId[V] <> 0 then
      begin
        WayIdx[WayN] := V;
        Inc(WayN);
      end;
    SetLength(WayIdx, WayN);
    MI := 1;
    while MI < WayN do MI := MI * 3 + 1;
    MI := MI div 3;
    while MI >= 1 do
    begin
      for V := MI to WayN - 1 do
      begin
        GX := WayIdx[V];   { GX как temp }
        Cell := V;
        while (Cell >= MI) and (HashId[WayIdx[Cell - MI]] > HashId[GX]) do
        begin
          WayIdx[Cell] := WayIdx[Cell - MI];
          Dec(Cell, MI);
        end;
        WayIdx[Cell] := GX;
      end;
      MI := MI div 3;
    end;
  end;

  { Ближайшая по XZ вершина (кольца ячеек от точки наружу; первое
    кольцо с кандидатом + одно контрольное — достаточно для nearest). }
  function HashNearestY(LX, LZ: Single; out AY: Single): Boolean;
  var
    CX, CZ, R, GX, GZ, Idx: Integer;
    BestD2, D2: Single;
    FoundRing: Integer;
  begin
    Result := False;
    if HNB = 0 then Exit;
    AY := 0;
    BestD2 := 0;
    FoundRing := -1;
    CX := Trunc((LX - HMinX) * HInv);
    CZ := Trunc((LZ - HMinZ) * HInv);
    for R := 0 to HNB do
    begin
      if (FoundRing >= 0) and (R > FoundRing + 1) then Break;
      for GZ := CZ - R to CZ + R do
        for GX := CX - R to CX + R do
        begin
          if (Abs(GX - CX) <> R) and (Abs(GZ - CZ) <> R) then Continue;
          if (GX < 0) or (GX > HNB - 1) or
             (GZ < 0) or (GZ > HNB - 1) then Continue;
          Idx := HashHead[GZ * HNB + GX];
          while Idx >= 0 do
          begin
            D2 := Sqr(HashX[Idx] - LX) + Sqr(HashZ[Idx] - LZ);
            if (not Result) or (D2 < BestD2) then
            begin
              BestD2 := D2;
              AY := HashY[Idx];
              Result := True;
              if FoundRing < 0 then FoundRing := R;
            end;
            Idx := HashNext[Idx];
          end;
        end;
    end;
  end;

  { Ближайшая по XZ вершина СНАПНУТОЙ way (бинпоиск диапазона id;
    дистанция не гейтится — на плоском пролёте ближайшая вершина
    настила может быть далеко вдоль оси, но её Y корректен). }
  function HashWayY(AWay: Int64; LX, LZ: Single; out AY: Single): Boolean;
  var
    Lo, Hi, Mid, J: Integer;
    BestD2, D2: Single;
  begin
    Result := False;
    if (AWay = 0) or (WayN = 0) then Exit;
    AY := 0;
    Lo := 0;
    Hi := WayN;
    while Lo < Hi do
    begin
      Mid := (Lo + Hi) div 2;
      if HashId[WayIdx[Mid]] < AWay then Lo := Mid + 1 else Hi := Mid;
    end;
    BestD2 := 0;
    J := Lo;
    while (J < WayN) and (HashId[WayIdx[J]] = AWay) do
    begin
      D2 := Sqr(HashX[WayIdx[J]] - LX) + Sqr(HashZ[WayIdx[J]] - LZ);
      if (not Result) or (D2 < BestD2) then
      begin
        BestD2 := D2;
        AY := HashY[WayIdx[J]];
        Result := True;
      end;
      Inc(J);
    end;
  end;

  { Взвешенная медиана отношений AGF/AGB по узлам со значимым |AGB|
    (вес — |AGB|). 1.0 при нехватке значимых узлов (ANSig < 10). }
  function WMedianRatio(const AGF, AGB: array of Double; AN: Integer;
    out ANSig: Integer): Double;
  var
    R, W: array of Double;
    K2, I2: Integer;
    V, VW, SumW, Acc: Double;
  begin
    SetLength(R, AN);
    SetLength(W, AN);
    ANSig := 0;
    for K2 := 0 to AN - 1 do
      if Abs(AGB[K2]) >= GRADE_MIN then
      begin
        R[ANSig] := AGF[K2] / AGB[K2];
        W[ANSig] := Abs(AGB[K2]);
        Inc(ANSig);
      end;
    if ANSig < 10 then Exit(1.0);
    for K2 := 1 to ANSig - 1 do
    begin
      V := R[K2]; VW := W[K2];
      I2 := K2 - 1;
      while (I2 >= 0) and (R[I2] > V) do
      begin
        R[I2 + 1] := R[I2];
        W[I2 + 1] := W[I2];
        Dec(I2);
      end;
      R[I2 + 1] := V; W[I2 + 1] := VW;
    end;
    SumW := 0;
    for K2 := 0 to ANSig - 1 do SumW := SumW + W[K2];
    Acc := 0;
    Result := R[ANSig - 1];
    for K2 := 0 to ANSig - 1 do
    begin
      Acc := Acc + W[K2];
      if Acc >= 0.5 * SumW then Exit(R[K2]);
    end;
  end;

var
  Fit: TFitFile;
  Samples: TRideSampleArray;
  NodeFit, NodeDem: array of Double;
  L, Stats: TStringList;
  FS: TFormatSettings;
  LogPath: String;
  GF, GD, NodeDist: array of Double;
  Sig, SXY, SXX, SYY, SX, SY, SRd, SFc, Coef, AscFit, AscDem, Corr: Double;
  SDem: string;        { alt_dem_m: число или ПУСТО, если DEM не снят }
  DistKm, DurSec, AscTrk, DescTrk: Double;
  NPts: Integer;
  CorrLocked: Boolean;
  Synthetic: Boolean;
  SynDist, SynDem, SynAlt: TDemProfileArr;
  { зелёный канал: снапнутый путь и высота с ленты/настила своей way }
  SnapPts: TRouteLatLonArray;
  SnapWays: TRouteWayIdArray;
  RoadAll, NodeRoad, GR: array of Double;
  HaveRoad: Boolean;
  KRoad: Double;
  NSigRoad: Integer;
begin
  if (FFitPath = '') or (Length(FRoute) < 3) or
     (Length(FAltM) <> Length(FRoute)) then Exit;

  { Одометрия FIT и файловая статистика — перечитываем файл: маршрут
    (FRoute) карта снапила по адаптеру, а дистанция/время живут в
    сэмплах. Путевая параметризация — ОДОМЕТРИЯ FIT (датчик головного
    устройства); GPX использует дистанцию по координатам из общего парсера. }
  Fit := NewRouteParserForFile(FFitPath);
  try
    if not Fit.LoadFromFile(FFitPath) then
    begin
      Log.Add('[heights] маршрут не перечитался — сверка высот пропущена');
      Exit;
    end;
    Samples := Fit.ToRideSamples;
    Synthetic := not Fit.HasAltitude;
  finally
    Fit.Free;
  end;
  if Length(Samples) <> Length(FRoute) then
  begin
    Log.Add(Format('[heights] одометрия не параллельна маршруту '
      + '(%d/%d) — сверка высот пропущена',
      [Length(Samples), Length(FRoute)]));
    Exit;
  end;

  NPts := Length(FRoute);
  SetLength(PathDist, NPts);
  for I := 0 to NPts - 1 do
    PathDist[I] := Samples[I].DistanceM - Samples[0].DistanceM;
  if Synthetic then
  begin
    if Length(FAltCalM) = NPts then
      FAltM := Copy(FAltCalM, 0, NPts)
    else if Length(FDemM) = NPts then
    begin
      SetLength(SynDist, NPts);
      SetLength(SynDem, NPts);
      for I := 0 to NPts - 1 do
      begin
        SynDist[I] := PathDist[I];
        SynDem[I] := FDemM[I];
      end;
      SmoothProfile(SynDist, SynDem, SynAlt);
      for I := 0 to NPts - 1 do FAltM[I] := SynAlt[I];
    end
    else
    begin
      Log.Add('[heights] нет записанных высот и DEM — сверка пропущена');
      Exit;
    end;
    Log.Add('[heights] нет записанных высот — профиль синтезирован из DEM');
  end;
  DistKm := PathDist[NPts - 1] / 1000.0;
  DurSec := Samples[NPts - 1].TimeSec;
  AscTrk := 0;
  DescTrk := 0;
  for I := 1 to NPts - 1 do
    if FAltM[I] > FAltM[I - 1] then
      AscTrk := AscTrk + (FAltM[I] - FAltM[I - 1])
    else
      DescTrk := DescTrk + (FAltM[I - 1] - FAltM[I]);

  CorrLocked := (FCorr <> nil) and FCorr.Active and FCorr.LevelLocked;

  { Высоты поверхности мира — ровно те, на которых сидят КРАСНЫЕ СФЕРЫ:
    ближайшая вершина ground-мешей тайла. Тайлы читаются с диска штатным
    TGeoTileCache по параметрам сессии; координаты вершин тайл-локальны,
    центр тайла = Proj.Project(Grid.TileCenter(T)). Коррекция здесь НЕ
    применяется намеренно: красный канал = состояние рельефа ДО фит-
    коррекции (опорная линия, с которой сравнивается зелёный/дорога и
    FIT). Зелёный канал ниже берётся с корректированного тайла. }
  SetLength(DemAll, NPts);
  Proj := TLocalProjection.Create(FOrigin);
  TileCache := TGeoTileCache.Create(FCacheRoot, FGenHash, FZoom,
    0, FOrigin.Lat);
  Model := nil;
  HaveTile := False;
  LastY := 0;
  HaveLastY := False;
  CenX := 0;
  CenZ := 0;
  try
    for I := 0 to NPts - 1 do
    begin
      T := TileCache.Grid.TileAt(FRoute[I]);
      if (not HaveTile) or (not T.Equals(CurTile)) then
      begin
        FreeAndNil(Model);
        CurTile := T;
        HaveTile := True;
        if not TileCache.TryLoad(T, Model) then
        begin
          Model := nil;
          Log.Add('[heights] нет тайла в кэше: ' + T.ToString);
        end;
        if Model <> nil then
        begin
          CV := Proj.Project(TileCache.Grid.TileCenter(T), 0);
          CenX := CV.X;
          CenZ := CV.Z;
          { НЕ корректируем — рельеф в исходном состоянии }
          BuildGroundHash(Model);
        end;
      end;
      if Model <> nil then
      begin
        WV := Proj.Project(FRoute[I], 0);
        if HashNearestY(WV.X - CenX, WV.Z - CenZ, SurfY) then
        begin
          LastY := SurfY;
          HaveLastY := True;
        end;
      end;
      { нет тайла/вершин — продлеваем последнюю валидную высоту,
        чтобы не дырявить лог; первые точки без опоры возьмут FIT }
      if HaveLastY then
        DemAll[I] := LastY
      else
        DemAll[I] := FAltM[I];
    end;

    { ── Третий канал: дорога (притянутый путь, зелёные сферы) ──
      SnappedRoute параллелен исходному маршруту; высота — с вершин
      ИМЕННО снапнутой way (настил моста несёт её id), фолбэк —
      ближайший рельеф в снапнутой точке. }
    HaveRoad := False;
    SnapPts := FSnapPts;
    SnapWays := FSnapWays;
    if (Length(SnapPts) = NPts) and (Length(SnapWays) = NPts) then
    begin
      SetLength(RoadAll, NPts);
      HaveTile := False;
      HaveLastY := False;
      LastY := 0;
      for I := 0 to NPts - 1 do
      begin
        T := TileCache.Grid.TileAt(SnapPts[I]);
        if (not HaveTile) or (not T.Equals(CurTile)) then
        begin
          FreeAndNil(Model);
          CurTile := T;
          HaveTile := True;
          if not TileCache.TryLoad(T, Model) then
            Model := nil;
          if Model <> nil then
          begin
            CV := Proj.Project(TileCache.Grid.TileCenter(T), 0);
            CenX := CV.X;
            CenZ := CV.Z;
            if CorrLocked then
              FCorr.ApplyToTileModel(Model, CenX, CenZ);
            { канал road сэмплит ПОЛОТНО (жёстко приведённое к голубой),
              а не рельеф — иначе не видно гладкости полотна }
            BuildGroundHash(Model, True);
          end;
        end;
        if Model <> nil then
        begin
          WV := Proj.Project(SnapPts[I], 0);
          if HashWayY(SnapWays[I], WV.X - CenX, WV.Z - CenZ, SurfY) or
             HashNearestY(WV.X - CenX, WV.Z - CenZ, SurfY) then
          begin
            LastY := SurfY;
            HaveLastY := True;
          end;
        end;
        if HaveLastY then
          RoadAll[I] := LastY
        else
          RoadAll[I] := FAltM[I];
      end;
      HaveRoad := True;
    end
    else
      Log.Add(Format('[heights] снап не параллелен маршруту '
        + '(%d/%d/%d) — канал дороги пропущен',
        [Length(SnapPts), Length(SnapWays), NPts]));
  finally
    FreeAndNil(Model);
    TileCache.Free;
    Proj.Free;
  end;

  { Узлы каждые ~STEP_M метров вдоль пути. }
  SetLength(NodeFit, NPts);
  SetLength(NodeDem, NPts);
  SetLength(NodeRoad, NPts);
  SetLength(NodeDist, NPts);
  NNodes := 0;
  DistAcc := -STEP_M;   { первая точка становится узлом сразу }
  for I := 0 to NPts - 1 do
    if PathDist[I] - DistAcc >= STEP_M then
    begin
      DistAcc := PathDist[I];
      NodeFit[NNodes] := FAltM[I];
      NodeDem[NNodes] := DemAll[I];
      if HaveRoad then NodeRoad[NNodes] := RoadAll[I]
      else NodeRoad[NNodes] := DemAll[I];
      NodeDist[NNodes] := PathDist[I];
      Inc(NNodes);
    end;
  if NNodes < 10 then
  begin
    Log.Add('[heights] маршрут слишком короткий (<10 узлов) — '
      + 'сверка высот пропущена');
    Exit;
  end;

  { Локальные уклоны: МНК-наклон по окну из GRADE_HALF·2+1 узлов —
    отдельно для FIT, мира и дороги (семантика игры один в один). }
  SetLength(GF, NNodes);
  SetLength(GD, NNodes);
  SetLength(GR, NNodes);
  for K := 0 to NNodes - 1 do
  begin
    I0 := Max(K - GRADE_HALF, 0);
    I1 := Min(K + GRADE_HALF, NNodes - 1);
    SX := 0; SXX := 0;
    for I := I0 to I1 do
    begin
      SX := SX + I;
      SXX := SXX + I * I;
    end;
    Sig := I1 - I0 + 1;
    SXX := SXX - SX * SX / Sig;
    if SXX < 1e-9 then
    begin
      GF[K] := 0;
      GD[K] := 0;
      GR[K] := 0;
      Continue;
    end;
    SXY := 0; SYY := 0; SRd := 0;
    for I := I0 to I1 do
    begin
      SXY := SXY + (I - SX / Sig) * NodeFit[I];
      SYY := SYY + (I - SX / Sig) * NodeDem[I];
      SRd := SRd + (I - SX / Sig) * NodeRoad[I];
    end;
    GF[K] := SXY / SXX / STEP_M;   { м/м }
    GD[K] := SYY / SXX / STEP_M;
    GR[K] := SRd / SXX / STEP_M;
  end;

  { Наборы — по узловым приращениям. }
  AscFit := 0;
  AscDem := 0;
  for K := 0 to NNodes - 2 do
  begin
    if NodeFit[K + 1] > NodeFit[K] then
      AscFit := AscFit + (NodeFit[K + 1] - NodeFit[K]);
    if NodeDem[K + 1] > NodeDem[K] then
      AscDem := AscDem + (NodeDem[K + 1] - NodeDem[K]);
  end;

  Coef := WMedianRatio(GF, GD, NNodes, NSig);
  if HaveRoad then
    KRoad := WMedianRatio(GF, GR, NNodes, NSigRoad)
  else
  begin
    KRoad := 0;
    NSigRoad := 0;
  end;
  Corr := 0.0;
  if NSig >= 10 then
  begin
    { корреляция уклонов — страховка от рассинхрона трека с рельефом }
    SX := 0; SY := 0; SXX := 0; SYY := 0; SXY := 0;
    for K := 0 to NNodes - 1 do
    begin
      SX := SX + GD[K]; SY := SY + GF[K];
      SXX := SXX + GD[K] * GD[K];
      SYY := SYY + GF[K] * GF[K];
      SXY := SXY + GD[K] * GF[K];
    end;
    SXX := SXX - SX * SX / NNodes;
    SYY := SYY - SY * SY / NNodes;
    SXY := SXY - SX * SY / NNodes;
    if (SXX > 1e-12) and (SYY > 1e-12) then
      Corr := SXY / Sqrt(SXX * SYY);
  end
  else
    Coef := 1.0;

  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';

  { ── Статистика — те же строки, что в игре идут в лабелы страницы
    «Маршруты» (файловые — из OpenAndAnalyzeFit, сверка — из
    ComputeDemComparison), собираются в шапку CSV. }
  Stats := TStringList.Create;
  try
    Stats.Add(Format('# Точек: %d', [NPts]));
    Stats.Add(Format('# Дистанция: %.1f км', [DistKm], FS));
    Stats.Add(Format('# Время: %d:%.2d:%.2d',
      [Trunc(DurSec) div 3600, (Trunc(DurSec) div 60) mod 60,
       Trunc(DurSec) mod 60]));
    Stats.Add(Format('# Набор (FIT): +%.0f м', [AscTrk], FS));
    Stats.Add(Format('# Спуск (FIT): −%.0f м', [DescTrk], FS));
    Stats.Add(Format('# Набор (мир): +%.0f м', [AscDem], FS));
    if NSig >= 10 then
      Stats.Add(Format('# Коэфф. уклонов: %.2f (узлов %d из %d, корр. %.2f)',
        [Coef, NSig, NNodes, Corr], FS))
    else
      Stats.Add('# Коэфф. уклонов: рельеф слишком плоский для сверки');
    if HaveRoad and (NSigRoad >= 10) then
      Stats.Add(Format('# K (дорога): %.2f (узлов %d)',
        [KRoad, NSigRoad], FS));
    if (NSig >= 10) and (Corr < 0.5) then
      Stats.Add('# Внимание: трек плохо согласован с рельефом — '
        + 'коэффициенту не доверять')
    else if (NSig >= 10) and (Coef < 0.7) then
      Stats.Add(Format('# Внимание: уклоны в FIT занижены '
        + '(~%.0f%% крутизны рельефа)', [Coef * 100], FS))
    else if (NSig >= 10) and (Coef > 1.3) then
      Stats.Add('# Внимание: уклоны в FIT круче рельефа (шум высоты?)');

    Log.Add(Format(
      '[heights] сверка: узлов %d, K=%.3f, corr=%.3f, '
      + 'набор FIT +%.0f / мир +%.0f м',
      [NNodes, Coef, Corr, AscFit, AscDem]));

    { ── CSV рядом с FIT (<имя>-heights.csv): шапка = статистика лабелов
      + машинные итоги (формат игры), таблица по всем точкам. }
    LogPath := ChangeFileExt(FFitPath, '') + '-heights.csv';
    L := TStringList.Create;
    try
      L.Add('# heights log: route vs world surface (red-sphere ground, generated tiles)');
      L.Add('# source: ' + ExtractFileName(FFitPath));
      if Synthetic then
        L.Add('# altitude_source: synthetic DEM (no recorded altitude/ele)')
      else
        L.Add('# altitude_source: recorded');
      L.AddStrings(Stats);
      if CorrLocked then
        L.Add('# surf = БЕЗ пост-коррекции (ApplyToTileModel не звался); '
          + 'road = ПОСЛЕ fit-correction (level-locked)');
      { Честная оговорка про surf: «без коррекции» относится только к
        ПОСТ-деформации. Сама геометрия тайла собрана с FIT-слоем фетчера
        (Osm3dBlockGenerator: Builder.FitLayer; сигнатура слоя входит в
        gen-hash), поэтому surf/road несут коррекцию в себе и независимым
        референсом быть не могут. Независим только alt_dem_m. }
      L.Add('# ВНИМАНИЕ: alt_surf_m/alt_road_m — меш тайла, а в него FIT '
        + 'запечён на генерации (FIT-слой фетчера, sig в gen-hash). '
        + 'Независимый референс = alt_dem_m');
      if Length(FDemM) = NPts then
        L.Add(Format('# alt_dem_m = чистый Terrarium, билинейно, zoom=%d — '
          + 'тот же вход, что у сплайна коррекции (Bank[].Dem)', [FZoom]))
      else
        L.Add(Format('# alt_dem_m ПУСТ: карта не сняла чистый DEM (%d из %d) '
          + '— ищите [dem] в логе карты', [Length(FDemM), NPts]));
      L.Add(Format('# K_grade_road=%.3f road_sig=%d', [KRoad, NSigRoad], FS));
      L.Add(Format('# K_grade_median=%.3f grade_corr=%.3f '
        + 'sig_nodes=%d/%d ascent_fit=%.0f ascent_dem=%.0f '
        + 'step_m=%.0f grade_win=%d grade_min=%.3f',
        [Coef, Corr, NSig, NNodes, AscFit, AscDem,
         STEP_M, GRADE_HALF * 2 + 1, GRADE_MIN], FS));
      { alt_dem_m дописан В КОНЕЦ намеренно: порядок прежних колонок не
        меняется, позиционные читатели не ломаются, а Osm3dFitLayerBuild
        и так ищет колонки по имени (CsvColIndex). }
      L.Add('idx;lat;lon;dist_m;alt_fit_m;alt_fitcorr_m;'
        + 'alt_surf_m;alt_road_m;grade_fit;grade_surf;alt_dem_m');
      { узловые уклоны интерполируются на точки по дистанции }
      K := 0;
      for I := 0 to NPts - 1 do
      begin
        while (K < NNodes - 1) and
              (NodeDist[K + 1] <= PathDist[I]) do
          Inc(K);
        if (K < NNodes - 1) and (NodeDist[K + 1] > NodeDist[K]) then
          Sig := (PathDist[I] - NodeDist[K]) /
                 (NodeDist[K + 1] - NodeDist[K])
        else
          Sig := 0;
        if Sig < 0 then Sig := 0;
        if Sig > 1 then Sig := 1;
        if HaveRoad then SRd := RoadAll[I] else SRd := DemAll[I];
        { скорректированный фит: значение или фолбэк на сырой (без чтения
          пустого массива — IfThen читал бы обе ветви) }
        if I <= High(FAltCalM) then
          SFc := FAltCalM[I]
        else
          SFc := FAltM[I];
        { Чистый DEM: значение или ПУСТО. Фолбэка нет сознательно — этот
          канал существует ровно затем, чтобы быть независимым; подстановка
          меша/фита сделала бы его бесполезным и незаметно. }
        if I <= High(FDemM) then
          SDem := Format('%.2f', [FDemM[I]], FS)
        else
          SDem := '';
        L.Add(Format('%d;%.7f;%.7f;%.1f;%.2f;%.2f;%.2f;%.2f;%.4f;%.4f;%s',
          [I, FRoute[I].Lat, FRoute[I].Lon, PathDist[I],
           FAltM[I], SFc, DemAll[I], SRd,
           GF[Min(K, NNodes - 1)] * (1 - Sig)
             + GF[Min(K + 1, NNodes - 1)] * Sig,
           GD[Min(K, NNodes - 1)] * (1 - Sig)
             + GD[Min(K + 1, NNodes - 1)] * Sig,
           SDem], FS));
      end;
      try
        L.SaveToFile(LogPath);
        Log.Add('[heights] лог высот: ' + LogPath);
      except
        on E: Exception do
          Log.Add('[heights] лог высот не записан: ' + E.Message);
      end;
    finally
      L.Free;
    end;
  finally
    Stats.Free;
  end;
end;

{ ── Сверка высот FIT / мир / дорога (порт страницы «Маршруты» игры) ──
  Ждём готовности снапа сессии (снап-воркер к этому моменту сгенерил
  тайлы маршрута на диск) и, если карта построила фит-коррекцию, — лока
  её уровня (лок происходит на первом MountBatch после снапа; без него
  высоты снялись бы с нескорректированных тайлов). Затем один раз пишем
  <fit>-heights.csv. Поллинг из UpdateFps (главный поток, 300 мс). }
procedure TStudioMainForm.MaybeComputeHeightsCsv;
const
  SNAP_WAIT_MAX_MS: QWord = 900000;  { 15 мин — как таймаут прогрева игры }
  LOCK_WAIT_MAX_MS: QWord = 120000;  { доп. ожидание лока уровня коррекции }
var
  W: THeightsCsvWorker;
  I: Integer;
  Corr: TFitCorrection;
begin
  { Завершение фоновой сверки: забрать строки результата в memo,
    дождаться и освободить поток. Поллинг вместо Synchronize/Queue —
    LCL-безопасно и без замыканий на форму из чужого потока. }
  if FHeightsWorker <> nil then
  begin
    if not FHeightsWorker.Finished then Exit;
    W := THeightsCsvWorker(FHeightsWorker);
    for I := 0 to W.Log.Count - 1 do
      LogMemoAdd(W.Log[I]);
    FHeightsWorker.WaitFor;
    FreeAndNil(FHeightsWorker);
    StatusBar1.SimpleText := 'Streaming map — fly with WASD / E,Q.';
    Exit;
  end;

  if not FHeightsCsvPending then Exit;
  if FStreamSession = nil then
  begin
    FHeightsCsvPending := False;
    Exit;
  end;
  if GetTickCount64 - FHeightsWaitStart > SNAP_WAIT_MAX_MS then
  begin
    FHeightsCsvPending := False;
    LogMemoAdd('[heights] снап не завершился за 15 минут — '
      + 'сверка высот пропущена');
    Exit;
  end;
  if not (FStreamSession.Map.SnappedReady and
          (Length(FStreamSession.Map.SnappedRoute) >= 2)) then Exit;
  { Снап завершается раньше фоновой коррекции. Снимаем копии только после
    её публикации, иначе CSV теряет голубой профиль и DEM у FIT и GPX. }
  if not FStreamSession.Map.TryFinishFitCorrection then Exit;
  { Коррекция построена, но уровень ещё не заперт — ждём (по таймауту
    едем без коррекции: шапка CSV тогда без метки AFTER fit-correction).
    Незапёршийся уровень при живом профиле — признак обхода деформации
    (см. '[fitcorr] BYPASS' в логе карты: фоновый ассемблер монтирует
    мимо MountBatch) либо отсутствия перемонтажей после снапа. }
  if (FStreamSession.Map.FitCorrection <> nil) and
     (not FStreamSession.Map.FitCorrection.LevelLocked) then
  begin
    if GetTickCount64 - FHeightsWaitStart <= LOCK_WAIT_MAX_MS then Exit;
    LogMemoAdd(Format('[heights] уровень коррекции НЕ заперт за %d с — '
      + 'сверка высот пойдёт без коррекции (ищите [fitcorr] BYPASS/NOTE '
      + 'в логе карты)', [LOCK_WAIT_MAX_MS div 1000]));
  end;
  FHeightsCsvPending := False;

  { Старт фоновой сверки: все данные копируются ЗДЕСЬ, на главном
    потоке (снап-массивы, корректор — клоном CopyFrom). Прежний
    синхронный вызов держал UI ~40 с. }
  Corr := nil;
  if FStreamSession.Map.FitCorrection <> nil then
  begin
    Corr := TFitCorrection.Create;
    Corr.CopyFrom(FStreamSession.Map.FitCorrection);
  end;
  FHeightsWorker := THeightsCsvWorker.Create(
    FRoute, FRouteAltM, FStreamSession.Map.RouteAltCal,
    FStreamSession.Map.RouteDem,          { чистый Terrarium → alt_dem_m }
    FStreamSession.Map.SnappedRoute,
    FStreamSession.Map.SnappedRouteWays,
    FRouteFitPath,
    FStreamSession.CacheRoot, FStreamSession.GenHash,
    FSettings.HeightmapZoom, FStreamOrigin, Corr);
  StatusBar1.SimpleText := UiText('Sampling surface elevations in the background…');
end;


procedure TStudioViewport.Render;
begin
  AdvanceProbeCamera;
  if Assigned(OnPrepareScene) then OnPrepareScene(Self);
  inherited;
end;

type
  TStudioControlAccess = class(TCastleControl);

procedure TStudioMainForm.InitializeHiddenRender;
begin
  { No Show/Hide cycle: LCL must never map the test form or steal focus.
    Its real WGL context still renders the same pipeline as the visible app. }
  WindowState := wsNormal;
  SetBounds(0,0,1800,1000);
  HandleNeeded;
  Realign;
  ViewportHost.HandleNeeded;
  if not ViewportHost.MakeCurrent then
    raise Exception.Create('Cannot initialize hidden Studio GL context');
  FHiddenRender := True;
  Resize;
  { Paint before the CGE idle handler, which keeps Done=False and performs the
    ordinary update/FPS pacing. Do not perform a second scene update here. }
  Application.OnIdle := @HiddenRenderIdle;
end;

procedure TStudioMainForm.ImpostorCheckClick(Sender:TObject);
begin SetWorldImpostorCache(FImpostorCheck.Checked) end;

procedure TStudioMainForm.RtxCheckClick(Sender:TObject);
begin if not FShadowModeSync then SetWorldRtxShadows(FRtxCheck.Checked);end;

procedure TStudioMainForm.RtxReflectionsClick(Sender:TObject);
begin if not FShadowModeSync then SetRtxReflections(FRtxReflectionsCheck.Checked);end;
procedure TStudioMainForm.SetRtxReflections(Value:Boolean);
begin
  if Value then SetWorldRtxShadows(True);
  FViewState.RtxReflections:=Value;FShadowModeSync:=True;
  try FRtxReflectionsCheck.Checked:=Value;finally FShadowModeSync:=False;end;
end;

procedure TStudioMainForm.SetWorldRtxShadows(Value:Boolean);
begin
  FViewState.RtxShadows:=Value;
  if not Value then FViewState.RtxReflections:=False;
  FViewState.ShadowProjections:=False;FRtxCachedRaster:=False;
  FShadowModeSync:=True;
  try
    if FShadowProjectionsCheck<>nil then FShadowProjectionsCheck.Checked:=False;
    if FRtxCheck<>nil then FRtxCheck.Checked:=Value;
    if FRtxReflectionsCheck<>nil then FRtxReflectionsCheck.Checked:=FViewState.RtxReflections;
  finally FShadowModeSync:=False;end;
  if FShadowAtlas<>nil then FShadowAtlas.RtxRequested:=Value;
  TStudioViewport(Viewport).Invalidate;
end;

procedure TStudioMainForm.SetRtxCachedRaster(Value:Boolean);
begin
  FRtxCachedRaster:=Value;FViewState.ShadowProjections:=Value;
  if Value then begin FViewState.RtxShadows:=False;FViewState.RtxReflections:=False;end;
  FShadowModeSync:=True;
  try
    if FShadowProjectionsCheck<>nil then FShadowProjectionsCheck.Checked:=Value;
    if FRtxCheck<>nil then FRtxCheck.Checked:=FViewState.RtxShadows;
    if FRtxReflectionsCheck<>nil then FRtxReflectionsCheck.Checked:=FViewState.RtxReflections;
  finally FShadowModeSync:=False;end;
  if FShadowAtlas<>nil then FShadowAtlas.RtxRequested:=Value or FViewState.RtxShadows;
  TStudioViewport(Viewport).Invalidate;
end;

procedure TStudioMainForm.ShadowProjectionsClick(Sender:TObject);
begin if not FShadowModeSync then SetRtxCachedRaster(FShadowProjectionsCheck.Checked);end;

procedure TStudioMainForm.RtxSnapshot(const J:TJSONObject);
begin
  if FShadowAtlas<>nil then FShadowAtlas.RtxSnapshot(J)
  else begin J.Add('enabled',FViewState.RtxShadows or FViewState.ShadowProjections);J.Add('active',False);J.Add('failed',False);end;
end;

procedure TStudioMainForm.DebugRtxReflections;
begin
  if (FShadowAtlas<>nil) and (FShadowAtlas.RtxBackend<>nil) then FShadowAtlas.RtxBackend.DebugReflections:=True;
end;

procedure TStudioMainForm.SetWorldImpostorCache(Value:Boolean);
begin
  TStudioViewport(Viewport).ImpostorCache:=Value;
  FViewState.ImpostorCache:=Value;
  if FImpostorCheck<>nil then FImpostorCheck.Checked:=Value;
end;

procedure TStudioMainForm.Resize;
begin
  inherited;
  { LCL postpones alignment of an invisible form. Size its GL child explicitly
    so the test resolution follows the same client area as a visible window. }
  if FHiddenRender and (not FHiddenResizing) and Assigned(ViewportHost) then
  begin
    FHiddenResizing:=True;
    try
      { The native windows are also deferred while the form is invisible.
        Resizing only LCL bounds makes glReadPixels read beyond the old buffer. }
      TWSWinControlClass(WidgetSetClass).SetBounds(Self,Left,Top,Width,Height);
      if (FPhotoCompare<>nil) and FPhotoCompare.Visible then begin
        FPhotoCompare.SetBounds(LeftPanel.Width,0,
          Max(1,ClientWidth-LeftPanel.Width),Max(1,ClientHeight-StatusBar1.Height));
        FPhotoCompare.Arrange;
      end else ViewportHost.SetBounds(LeftPanel.Width,0,
        Max(1,ClientWidth-LeftPanel.Width),Max(1,ClientHeight-StatusBar1.Height));
      TWSWinControlClass(ViewportHost.WidgetSetClass).SetBounds(ViewportHost,
        ViewportHost.Left,ViewportHost.Top,ViewportHost.Width,ViewportHost.Height);
    finally FHiddenResizing:=False end;
  end;
end;

procedure TStudioMainForm.HiddenRenderIdle(Sender: TObject; var Done: Boolean);
begin
  if not (csDestroying in ComponentState) then
    TStudioControlAccess(ViewportHost).Paint;
end;

function TStudioMainForm.RenderInfo: string;
begin
  Result:=Format('fps=%.2f render_ms=%.3f; ',[ViewportHost.Container.Fps.RealFps,
    1000/Max(0.001,ViewportHost.Container.Fps.OnlyRenderFps)])+RoadMaterialDebug;
  if FShadowAtlas <> nil then Result := Result + '; ' + FShadowAtlas.DebugInfo
  else Result := Result + '; atlas: inactive';
end;

function TStudioMainForm.GetFpsMode:TFpsLimitMode;
begin Result:=FVerticalFly.FFpsMode end;

procedure TStudioMainForm.SetFpsMode(Value:TFpsLimitMode);
begin
  FVerticalFly.FFpsMode:=Value;FVerticalFly.ApplyFpsMode;
  HandleFpsModeChanged(Value);
end;

procedure TStudioMainForm.PrepareSceneRender(Sender: TObject);
var
  Focus, Sun: TVector3;
  GroundY: Single;
  B:TCacheBatch;
  T:TCacheTile;
  Revision:QWord;
begin
  TStudioViewport(Viewport).Rtx:=nil;
  if FFlatMode or (FStreamSession = nil) or (Viewport.Camera = nil) then
  begin
    TStudioViewport(Viewport).WorldRoot:=nil;
    HideGroundRiderShadow;
    Exit;
  end;
  TStudioViewport(Viewport).WorldRoot:=FStreamSession.Map;
  Revision:=0;
  if TStudioViewport(Viewport).ImpostorCache or FViewState.RtxShadows or FViewState.ShadowProjections then begin
    { Mounted generations distinguish replacements even if heap addresses are
      reused. Only tile records are inspected; never walk world geometry. }
    Revision:=2166136261;
    for B in FStreamSession.Map.RootBlocks do
      for T in B.Tiles do
        if T.Active then Revision:=(Revision xor T.MountGen)*16777619;
    TStudioViewport(Viewport).WorldRevision(Revision);
  end;
  Focus := Viewport.Camera.WorldTransform.MultPoint(TVector3.Zero);
  RoadMaterialRender(Focus);
  if FStreamSession.Map.SunWorldShadowDir(Sun) then SetSkySun(Sun)
  else SetSkySun(Vector3(0,1,0),False);
  if not FWorldShadowsEnabled then begin HideGroundRiderShadow;Exit end;
  if not FStreamSession.Map.SunWorldShadowDir(Sun) then
  begin
    HideGroundRiderShadow;
    Exit;
  end;
  if FShadowAtlas = nil then FShadowAtlas := TRiderShadowAtlas.Create;
  FShadowAtlas.Casters.Clear;
  FShadowAtlas.WorldCasters.Clear;
  FShadowAtlas.WorldShadows := True;
  FShadowAtlas.RtxRequested:=FViewState.RtxShadows or FViewState.ShadowProjections;
  FShadowAtlas.RtxRasterComparison:=FRtxCachedRaster;
  FShadowAtlas.RtxReflections:=FViewState.RtxReflections and FViewState.RtxShadows;
  FShadowAtlas.RtxRevision:=Revision xor QWord(Ord(RenderTreesActive)) xor
    (QWord(Ord(ProceduralVegetationActive)) shl 1) xor (QWord(Round(ProceduralVegetationSeason*12)) shl 2);
  FStreamSession.Map.AppendWorldShadowCasters(FShadowAtlas.WorldCasters);
  { The editor has no avatar as a height reference. Reuse a slow ground
    sample for aerial coverage; never trace geometry on every render. }
  if (FShadowGroundSample=0) or (GetTickCount64-FShadowGroundSample>=500) then begin
    FShadowGroundSample:=GetTickCount64;
    if FStreamSession.Map.GroundYAt(Focus.X,Focus.Z,GroundY) then
      FShadowGroundPosition:=Vector3(Focus.X,GroundY,Focus.Z);
  end;
  Focus.Y:=FShadowGroundPosition.Y;
  FShadowAtlas.Render(Viewport, Focus, Sun, 0.5);
  TStudioViewport(Viewport).Rtx:=FShadowAtlas.RtxBackend;
end;

procedure TStudioMainForm.StartStreaming(const AOrigin: TLatLon);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(941);{$ENDIF}
  { An explicit location/session must win over a late startup IP lookup
    or a queued restoration of the previous camera. Do not join the
    network worker here; FormDestroy already owns its bounded shutdown. }
  FGeoApplied := True;
  FRestoreViewPending := False;
  ProgressBar1.Position := 0;

  try
    { Start (or restart) the background tile stream. The streaming map
      replaces the one-shot chunk generation: tiles around the camera
      are fetched / generated on worker threads and mounted on demand.
      Origin stays fixed for the session. FRoute/FRouteAltM may be empty
      (e.g. the IP-geolocation start) — then there is simply no route
      overlay; the camera-driven streamer fills tiles around the camera. }
    ClosePhotoComparison;
    FreeAndNil(FShadowAtlas);
    FPhotoRenderer.Reset;
    ResetPhotoViewRenderTools;
    FreeAndNil(FStreamSession);
    { ФИТ-СЛОЙ ВЫСОТ: папку заездов и выбранный файл передаём В Create, а не
      через Map.SetRoutesFolder ПОСЛЕ него. Причина — диагностика лога
      15.07: при постановке папки после Create слой корректированных высот
      строился поздно (только на авто-снапе маршрута), уже ПОСЛЕ того как все
      тайлы испеклись на сыром DEM, а сигнатура набора заездов не попадала в
      gen-hash — все 20 блоков шли «FIT height-layer: OFF … raw DEM» /
      «ABSENT». Передача папки сюда заставляет Create построить слой синхронно
      ДО генерации, поставить его в фетчер высот и включить его сигнатуру в
      ключ дискового кэша тайлов — геометрия консистентна с кэшем. Для CSV /
      IP-старта FRouteFitPath пуст → ExtractFilePath('')/ExtractFileName('')
      дают '' → Create слой не строит (боевой путь без коррекции мешей). }
    FStreamSession := TOsm3dStreamingSession.Create(
      FSettings, AOrigin, @HandleStreamLog, FRouteStartUTC,
      FRoute, FRouteAltM,
      ExtractFilePath(FRouteFitPath), ExtractFileName(FRouteFitPath));

    { Коррекция террейна по FIT — общий путь студии и игры: карта построит
      её сама в OnRouteSnapDone (авто-снап через SNAP_AUTO_DELAY_S) из всей
      папки заездов; выбранный — загруженный файл. Папку заездов Create уже
      передал карте (Map.SetRoutesFolder внутри) вместе с постройкой слоя
      высот — второй раз звать не нужно. Без FIT (CSV / IP-старт) коррекции
      нет. }
    FStreamOrigin := AOrigin;
    FHeightsCsvPending := False;   { рестарт гасит прежнее ожидание }
    if FRouteFitPath <> '' then
    begin
      LogMemoAdd(Format('[fitcorr] routes folder: %s (selected %s)',
        [ExtractFilePath(FRouteFitPath), ExtractFileName(FRouteFitPath)]));
      { Сверка высот FIT/мир/дорога: ждём снапа (тайлы маршрута лягут в
        кэш) и пишем <fit>-heights.csv. Нужен канал высот FIT,
        параллельный маршруту. }
      FHeightsCsvPending := (Length(FRoute) >= 3) and
        (Length(FRouteAltM) = Length(FRoute));
      FHeightsWaitStart := GetTickCount64;
      if not FHeightsCsvPending then
        LogMemoAdd('[heights] в FIT нет высот, параллельных маршруту — '
          + 'сверка высот пропущена');
    end;

    { Keep the flat map aligned to the same projection origin so it lines
      up with the 3D world if the user toggles to Flat. }
    FSlippyMap.Origin := AOrigin;

    { Wire the streaming session's HTTP fetchers to the form's network
      event handlers — otherwise heightmap / Overpass traffic is invisible.
      Streaming terrain/OSM now flows through the per-domain fetchers
      (HttpHeight / HttpOverpass), each over the shared byte cache, so all
      three are wired. These handlers marshal to the main thread via
      SafeSync. }
    FStreamSession.Http.OnNetworkRequest  := @HandleNetRequest;
    FStreamSession.Http.OnNetworkProgress := @HandleNetProgress;
    FStreamSession.Http.OnNetworkSuccess  := @HandleNetSuccess;
    FStreamSession.Http.OnCacheHit        := @HandleCacheHit;
    FStreamSession.Http.OnError           := @HandleNetError;

    FStreamSession.HttpHeight.OnNetworkRequest  := @HandleNetRequest;
    FStreamSession.HttpHeight.OnNetworkProgress := @HandleNetProgress;
    FStreamSession.HttpHeight.OnNetworkSuccess  := @HandleNetSuccess;
    FStreamSession.HttpHeight.OnCacheHit        := @HandleCacheHit;
    FStreamSession.HttpHeight.OnError           := @HandleNetError;

    FStreamSession.HttpOverpass.OnNetworkRequest  := @HandleNetRequest;
    FStreamSession.HttpOverpass.OnNetworkProgress := @HandleNetProgress;
    FStreamSession.HttpOverpass.OnNetworkSuccess  := @HandleNetSuccess;
    FStreamSession.HttpOverpass.OnCacheHit        := @HandleCacheHit;
    FStreamSession.HttpOverpass.OnError           := @HandleNetError;

    Viewport.Items.Add(FStreamSession.Map);
    { Прогрев маршрута: полноэкранная плоская карта с прогрессом тайлов —
      поверх вьюпорта. Показ/скрытие водит сама карта (на время сборки
      тайлов маршрута снап-воркером, до запуска притягивания); при
      FreeAndNil(FStreamSession) оверлей освобождается вместе с картой и
      сам выписывается из Controls. }
    Viewport.InsertFront(FStreamSession.Map.WarmupOverlay);
    { У студии райдера нет — гейт «гашение оверлея только после постановки
      райдера» выключен, иначе оверлей прогрева не погас бы никогда. }
    FStreamSession.Map.WarmupHoldRider := False;
    {$PUSH}{$WARN 5066 OFF}
    Viewport.Items.MainScene := FStreamSession.Map.GlobalScene;
    {$POP}

    { Place the camera over the projection origin (= AOrigin = route start),
      oriented for the CURRENT mode. In 3D: a down-forward eye-height look.
      In Flat: straight down, north up, at plan-view altitude — otherwise a
      restart while in 2D would leave the flat map viewed at a 3D angle. The
      stream then fills tiles around wherever the camera flies. }
    if FFlatMode then
      Viewport.Camera.SetView(
        Vector3(0.0, 1000.0, 0.0),
        Vector3(0.0, -1.0, 0.0),
        Vector3(0.0, 0.0, 1.0))
    else
      Viewport.Camera.SetView(
        Vector3(0.0, 300.0, 0.0),
        Vector3(0.3, -0.55, -0.78),
        Vector3(0.0, 1.0, 0.0));
    if (not FHiddenRender) and ViewportHost.CanFocus then ViewportHost.SetFocus;

    StatusBar1.SimpleText := 'Streaming map — fly with WASD / E,Q.';
    LogMemoAdd(Format('[stream] session started, origin %.5f, %.5f',
      [AOrigin.Lat, AOrigin.Lon]));

    { Honour the current mode: if the user was in Flat, keep the new
      streaming 3D map hidden; if in 3D, keep the slippy map hidden. }
    SetMapMode(FFlatMode);
  except
    on E: Exception do
      ShowMessage(UiText('Streaming start error: ') + E.Message);
  end;
end;

procedure TStudioMainForm.SyncSlippyOrigin;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1753);{$ENDIF}
  { Align the flat map to the same projection origin the 3D world uses
    (the route centroid). Only meaningful once a route is loaded. }
  if (FSlippyMap <> nil) and (Length(FRoute) >= 1) then
  begin
    { Same origin as the 3D session: the route's first point, so flat and 3D
      stay aligned and both open at the start of the route. }
    FSlippyMap.Origin := FRoute[0];
    { draw the loaded track as a translucent line on top of the flat map }
    FSlippyMap.SetRoute(FRoute);
  end;
end;

procedure TStudioMainForm.MaybeApplyInitialLocation;
var
  Done, Ok: Boolean;
  Lat, Lon: Double;
begin
  if FGeoApplied then Exit;

  { A real route always wins: once one is loaded we never override its origin
    with the IP guess, and we stop polling. }
  if Length(FRoute) >= 1 then
  begin
    FGeoApplied := True;
    Exit;
  end;

  if FGeoThread = nil then Exit;
  if not FGeoThread.Poll(Done, Ok, Lat, Lon) then Exit;   { still looking up }

  { Result is in. The thread is a one-shot, so release it now: Poll saw Done,
    hence the WaitFor inside Free returns at once, and there is no Synchronize
    to deadlock on. (FormDestroy still frees it for the not-yet-finished case.) }
  FGeoApplied := True;          { decided — one-shot, success or not }
  FreeAndNil(FGeoThread);

  if not Ok then Exit;          { lookup failed → keep the default origin }

  { Position known and no route loaded → start the 3D streaming world centred
    on the user. StartStreaming also points the flat map at the same origin and
    honours the current 2D/3D mode (3D at startup). }
  LogMemoAdd(Format(
    'Initial location from IP: %.4f, %.4f (no route) — starting 3D stream',
    [Lat, Lon]));
  StartStreaming(TLatLon.Make(Lat, Lon));
end;

procedure TStudioMainForm.SetMapMode(AFlat: Boolean);
const
  STRAIGHT_DOWN: TVector3 = (X: 0; Y: -1; Z: 0);  { look at the ground }
  NORTH_UP:      TVector3 = (X: 0; Y:  0; Z: 1);  { screen-up = north (+Z) }
  WORLD_UP_V:    TVector3 = (X: 0; Y:  1; Z: 0);
  { Fallback 3D vantage when no sane saved view exists — a down-forward look
    at a real eye height (same as the session-start camera). NEVER reuse the
    flat plan-view's altitude/straight-down, or the 3D map renders empty. }
  DEFAULT_3D_DIR: TVector3 = (X: 0.3; Y: -0.55; Z: -0.78);
  DEFAULT_3D_ALT = 300.0;
  MIN_3D_ALT     = 1.0;        { saved 3D Y must be a plausible eye height }
  MAX_3D_ALT     = 20000.0;    { above this it's a leaked flat altitude → default }
var
  WasFlat: Boolean;
  Cam:     TCastleCamera;
  Pos:     TVector3;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1754);{$ENDIF}
  if AFlat then ClosePhotoComparison;
  WasFlat := FFlatMode;
  FFlatMode := AFlat;
  Cam := Viewport.Camera;

  if AFlat then
  begin
    { Genuine 3D → Flat: remember the 3D vantage point, then snap the
      camera to a fixed top-down orientation. The flat map is a plan
      view, so the camera must look straight down and never roll. }
    if (not WasFlat) and (Cam <> nil) then
    begin
      FSaved3DPos := Cam.Translation;
      FSaved3DDir := Cam.Direction;
      FSaved3DUp  := Cam.Up;
      FHas3DView  := True;

      Pos := Cam.Translation;
      if Pos.Y < 200.0 then Pos.Y := 1000.0;   { sane starting altitude }
      { With no route, centre on the slippy origin (= the IP location when one
        was found), so the flat map opens on the user instead of at (0,0). }
      if Length(FRoute) = 0 then
      begin
        Pos.X := 0;
        Pos.Z := 0;
      end;
      Cam.SetView(Pos, STRAIGHT_DOWN, NORTH_UP);
    end;

    { Mouse now pans, WASD pans, rotation is disabled. }
    if FVerticalFly <> nil then
      FVerticalFly.FlatMode := True;

    { Hide the 3D map, show + enable the slippy map. }
    if FStreamSession <> nil then
      FStreamSession.Map.Exists := False;

    SyncSlippyOrigin;
    if FSlippyMap <> nil then
    begin
      FSlippyMap.Enabled := True;     { resume streaming/work }
      FSlippyMap.Exists  := True;
    end;
  end
  else
  begin
    { Restore free rotation. }
    if FVerticalFly <> nil then
      FVerticalFly.FlatMode := False;

    { Genuine Flat → 3D. Mirror of the 3D → Flat snap: there we dropped the
      flat camera straight down over the 3D camera's XZ; here we move the 3D
      vantage to wherever the user panned on the flat map. The horizontal XZ
      follows the flat pan; the altitude + orientation come from the saved 3D
      view when it's sane, else from safe defaults. We ALWAYS set a valid view
      (not gated on FHas3DView): the flat plan-view sits ~1 km up looking
      straight down, and leaving the camera there makes the stream's distance-
      cull drop every tile — the "blue sky / black screen" on switch. }
    if WasFlat and (Cam <> nil) then
    begin
      Pos := Cam.Translation;   { XZ = flat pan location; flat Y is discarded }
      if FHas3DView and (FSaved3DPos.Y >= MIN_3D_ALT)
                    and (FSaved3DPos.Y <= MAX_3D_ALT) then
        Cam.SetView(Vector3(Pos.X, FSaved3DPos.Y, Pos.Z),
                    FSaved3DDir, FSaved3DUp)
      else
        Cam.SetView(Vector3(Pos.X, DEFAULT_3D_ALT, Pos.Z),
                    DEFAULT_3D_DIR, WORLD_UP_V);
    end;

    { Idle + hide the slippy map, show the 3D map. }
    if FSlippyMap <> nil then
    begin
      FSlippyMap.Exists  := False;
      FSlippyMap.Enabled := False;    { stop fetching while hidden }
    end;

    if FStreamSession <> nil then
      FStreamSession.Map.Exists := True;
  end;

  { Reflect the active mode by disabling its own button. }
  if btn3D <> nil then
    btn3D.Enabled := AFlat;
  if btnFlat <> nil then
    btnFlat.Enabled := not AFlat;

  { Поиск места имеет смысл только на плоской карте. nil-guard: SetMapMode(False)
    вызывается из FormCreate ещё до создания виджета. }
  if FSearchWidget <> nil then
    FSearchWidget.Exists := AFlat;
end;

procedure TStudioMainForm.btn3DClick(Sender: TObject);
var
  Cam:   TCastleCamera;
  Proj:  TLocalProjection;
  CenLL: TLatLon;
  W:     TVector3;
  Y:     Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1755);{$ENDIF}
  Cam := Viewport.Camera;

  if (FSlippyMap <> nil) and (Cam <> nil) then
  begin
    { Геоточка, на которую сейчас смотрит плоская карта (в ЕЁ проекции:
      origin slippy + XZ камеры). }
    Proj := TLocalProjection.Create(FSlippyMap.Origin);
    try
      CenLL := Proj.Unproject(Cam.Translation.X, Cam.Translation.Z);
    finally
      Proj.Free;
    end;

    if FStreamSession = nil then
    begin
      { Сессии ещё нет — создаём свежую. Здесь НЕТ освобождения старой сессии,
        значит нет блокирующего WaitFor по воркерам → нет фриза. StartStreaming
        сам выставит режим, origin и камеру; тайлы стримятся в фоне. }
      FFlatMode := False;
      StartStreaming(CenLL);
      if (not FHiddenRender) and ViewportHost.CanFocus then ViewportHost.SetFocus;
      Exit;
    end;

    { Сессия уже есть — НЕ пересоздаём её. Раньше здесь был FreeAndNil + рестарт,
      и деструктор сессии синхронно джойнил воркеров генерации (WaitFor) —
      главный поток замирал на всё время генерации блока ("фриз до тайлов").
      Вместо этого просто переносим камеру в CenLL в системе координат СЕССИИ;
      стример сам до-генерирует тайлы вокруг новой позиции в фоне, не блокируя UI. }
    Y := Cam.Translation.Y;                 { сохранить текущий зум-высоту }
    if (Y < 1.0) or (Y > 20000.0) then Y := 300.0;
    W := FStreamSession.GeoToLocal(CenLL);  { CenLL → мировые XZ кадра сессии }

    SetMapMode(False);                      { показать 3D, спрятать slippy }
    Viewport.Camera.SetView(
      Vector3(W.X, Y, W.Z),
      Vector3(0.3, -0.55, -0.78),
      Vector3(0.0, 1.0, 0.0));
  end
  else
    SetMapMode(False);

  if (not FHiddenRender) and ViewportHost.CanFocus then ViewportHost.SetFocus;
end;

procedure TStudioMainForm.btnFlatClick(Sender: TObject);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1756);{$ENDIF}
  SetMapMode(True);
  if (not FHiddenRender) and ViewportHost.CanFocus then ViewportHost.SetFocus;
end;

procedure TStudioMainForm.SearchPlacePicked(Sender: TObject; const AHit: TGeoHit);
const
  DOWN: TVector3 = (X: 0; Y: -1; Z: 0);   { взгляд вниз — план }
  NUP:  TVector3 = (X: 0; Y:  0; Z: 1);   { север — вверх экрана }
var
  Cam: TCastleCamera;
  Y:   Single;
begin
  { Виджет живёт на плоской карте, но на всякий случай гарантируем режим. }
  if not FFlatMode then SetMapMode(True);

  Cam := Viewport.Camera;
  if Cam = nil then Exit;

  { Сохраняем текущий зум (высоту), но в разумных пределах. }
  Y := Cam.Translation.Y;
  if (Y < 50.0) or (Y > 400000.0) then Y := 1000.0;

  { Плоская карта центрируется через origin slippy-карты: камера в XZ=(0,0)
    = origin. Переустановка origin на найденную точку держит ошибку
    equirectangular-проекции крошечной при прыжке на любое расстояние и сразу
    пере-центрирует стриминг тайлов на новое место. }
  if FSlippyMap <> nil then
  begin
    FSlippyMap.Origin := AHit.Location;
    if Length(FRoute) >= 1 then
      FSlippyMap.SetRoute(FRoute);   { перепроецировать линию маршрута }
  end;

  Cam.SetView(Vector3(0, Y, 0), DOWN, NUP);
  if (not FHiddenRender) and ViewportHost.CanFocus then ViewportHost.SetFocus;
end;

function TStudioMainForm.SearchNeedViewBox(Sender: TObject;
  out ABox: TLatLonBox): Boolean;
var
  C: TLatLon;
begin
  Result := False;
  if FSlippyMap = nil then Exit;
  C := FSlippyMap.Origin;
  { origin не задан (0,0) → без смещения, чисто глобальный поиск. }
  if (Abs(C.Lat) < 1.0e-9) and (Abs(C.Lon) < 1.0e-9) then Exit;
  ABox := TLatLonBox.Make(C.Lat, C.Lon, C.Lat, C.Lon).ExpandMeters(20000);
  Result := True;
end;

procedure TStudioMainForm.btnViewSourceClick(Sender: TObject);
var
  CamPos: TVector3;
  TileNm: string;
  Json:   string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1757);{$ENDIF}
  if FStreamSession = nil then
  begin
    ShowMessage(UiText('No streaming session yet — press Generate first.'));
    Exit;
  end;
  if Viewport.Camera = nil then
  begin
    ShowMessage(UiText('Camera not ready.'));
    Exit;
  end;

  CamPos := Viewport.Camera.WorldTranslation;
  TileNm := FStreamSession.CameraTileName(CamPos.X, CamPos.Z);
  Json   := FStreamSession.CameraTileOsmJson(CamPos.X, CamPos.Z);

  ShowOsmSource(TileNm, Json);
  if (not FHiddenRender) and ViewportHost.CanFocus then ViewportHost.SetFocus;
end;

procedure TStudioMainForm.btnVisibleClick(Sender: TObject);
const
  { CGE's default perspective vertical FOV is 45°; the studio window is
    landscape so that angle maps to the screen's vertical. NEAR/FAR bound
    the depth slab; MARGIN widens the frustum a touch so features right at
    the screen edge are not dropped. Tweak FAR_M for how deep "on screen"
    should reach. }
  FOV_Y_DEG = 45.0;
  NEAR_M    = 1.0;
  FAR_M     = 6000.0;
  MARGIN    = 1.20;
var
  Cam:    TCastleCamera;
  CamPos: TVector3;
  Aspect: Single;
  W, H:   Integer;
  TileNm: string;
  Txt:    string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1758);{$ENDIF}
  if FStreamSession = nil then
  begin
    ShowMessage(UiText('No streaming session yet — press Generate first.'));
    Exit;
  end;
  Cam := Viewport.Camera;
  if Cam = nil then
  begin
    ShowMessage(UiText('Camera not ready.'));
    Exit;
  end;

  W := ViewportHost.Width;   if W <= 0 then W := 1;
  H := ViewportHost.Height;  if H <= 0 then H := 1;
  Aspect := W / H;

  CamPos := Cam.WorldTranslation;
  TileNm := FStreamSession.CameraTileName(CamPos.X, CamPos.Z);
  Txt    := FStreamSession.CameraScreenFeatures(
              CamPos.X, CamPos.Z,
              CamPos, Cam.Direction, Cam.Up,
              Aspect, DegToRad(FOV_Y_DEG), NEAR_M, FAR_M, MARGIN);

  ShowOsmSource('on-screen ' + TileNm, Txt);
  if (not FHiddenRender) and ViewportHost.CanFocus then ViewportHost.SetFocus;
end;

procedure TStudioMainForm.PhotoCompareClick(Sender:TObject);
begin
  if (FStreamSession=nil) or (FStreamSession.Map=nil) then begin
    StatusBar1.SimpleText:=UiText('Load a 3D map before comparing photos');Exit;
  end;
  OpenPhotoComparison;
end;

procedure TStudioMainForm.OpenPhotoComparison;
var LL:TLatLon; P,D,U:TVector3; Request,Stop,Reply:TJSONObject;
begin
  if (FStreamSession=nil) or (FStreamSession.Map=nil) then
    raise Exception.Create(UiText('Load a 3D map before comparing photos'));
  if (FPhotoCompare<>nil) and FPhotoCompare.Visible then Exit;
  if FFlatMode then SetMapMode(False);
  Stop:=TJSONObject.Create(['stop',True]);Reply:=TJSONObject.Create;
  try TStudioViewport(Viewport).ProbeCamera(Stop,Reply) finally Stop.Free;Reply.Free end;
  Viewport.Camera.GetWorldView(P,D,U);LL:=FStreamSession.CameraGeo(P.X,P.Z);
  Request:=TJSONObject.Create(['latitude',LL.Lat,'longitude',LL.Lon,
    'zoom',FSettings.HeightmapZoom,'edge_px',GEO_TILE_EDGE_PX]);
  if FPhotoCompare=nil then begin
    FPhotoCompare:=TStudioPhotoCompare.CreateForHost(Self,ViewportHost,FPhotoRenderer);
    FPhotoCompare.OnClosed:=@PhotoCompareClosed;
  end;
  FPhotoSavedFps:=FFpsLabel.Exists;FPhotoSavedSearch:=FSearchWidget.Exists;
  FPhotoSavedMoveSpeed:=FVerticalFly.MoveSpeed;
  try
    FPhotoCompare.OpenAt(FSettings.CacheRoot,Request,Viewport,FStreamSession);
    FVerticalFly.MoveSpeed:=3;
    FFpsLabel.Exists:=False;FSearchWidget.Exists:=False;
  finally Request.Free end;
end;

procedure TStudioMainForm.ClosePhotoComparison;
begin if FPhotoCompare<>nil then FPhotoCompare.CloseComparison end;

procedure TStudioMainForm.PhotoCompareClosed(Sender:TObject);
begin
  FFpsLabel.Exists:=FPhotoSavedFps;FSearchWidget.Exists:=FPhotoSavedSearch;
  FVerticalFly.MoveSpeed:=FPhotoSavedMoveSpeed;
end;

function TStudioMainForm.PhotoComparisonCommand(const Params:TJSONObject):TJSONObject;
var Operation:string;
begin
  Operation:=Params.Get('action','status');
  if Operation='show' then OpenPhotoComparison
  else if Operation='close' then ClosePhotoComparison
  else if Operation<>'status' then begin
    if (FPhotoCompare=nil) or not FPhotoCompare.Visible then
      raise Exception.Create('Open photo comparison first');
    if Operation='select' then FPhotoCompare.SelectPhoto(Params.Get('index',-1))
    else if Operation='reset' then FPhotoCompare.ResetView
    else if Operation='save' then FPhotoCompare.SaveCurrentView
    else if Operation='capture_controls' then CaptureStudioControls(Self,ViewportHost,Params.Get('path',''))
    else raise Exception.Create('Unknown photo comparison action');
  end;
  if FPhotoCompare=nil then Result:=TJSONObject.Create(['open',False])
  else Result:=FPhotoCompare.Snapshot;
end;

procedure TStudioMainForm.btnHeightsClick(Sender: TObject);
var
  Cam:    TCastleCamera;
  CamPos: TVector3;
  TileNm: string;
  Txt:    string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1759);{$ENDIF}
  if FStreamSession = nil then
  begin
    ShowMessage(UiText('No streaming session yet — press Generate first.'));
    Exit;
  end;
  Cam := Viewport.Camera;
  if Cam = nil then
  begin
    ShowMessage(UiText('Camera not ready.'));
    Exit;
  end;

  CamPos := Cam.WorldTranslation;
  TileNm := FStreamSession.CameraTileName(CamPos.X, CamPos.Z);
  Txt    := FStreamSession.CameraTileHeights(CamPos.X, CamPos.Z);

  ShowOsmSource('heights ' + TileNm, Txt);
  if (not FHiddenRender) and ViewportHost.CanFocus then ViewportHost.SetFocus;
end;

procedure TStudioMainForm.OsmSourceFormClose(Sender: TObject;
  var CloseAction: TCloseAction);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1760);{$ENDIF}
  CloseAction := caFree;   { free on close — no leak when reopened }
end;

procedure TStudioMainForm.ShowOsmSource(const ATileName, AText: string);
var
  F: TForm;
  M: TMemo;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1761);{$ENDIF}
  F := TForm.CreateNew(Application);
  F.Caption  := UiText('OSM source — tile ') + ATileName;
  F.Width    := 960;
  F.Height   := 720;
  F.Position := poScreenCenter;
  F.OnClose  := @OsmSourceFormClose;

  M := TMemo.Create(F);
  M.Parent      := F;
  M.Align       := alClient;
  M.ReadOnly    := True;
  M.ScrollBars  := ssBoth;
  M.WordWrap    := False;
  M.Font.Name   := 'Monospace';
  M.Font.Height := -12;
  M.Lines.Text  := AText;

  F.Show;   { non-modal — keep flying while it's open }
end;

procedure TStudioMainForm.UpdateFps(Sender: TObject);
var
  Fps:     Single;
  { Local `Text` would shadow inherited TControl.Text (Controls.pp);
    FPC raises a duplicate-identifier error, not a warning. Renamed Cap. }
  Cap:     string;
  { Camera geo-position line for the overlay. }
  CamPos:  TVector3;
  CamGeo:  TLatLon;
  Dir:     TVector3;
  Heading: Single;        { degrees clockwise from North }
  CompassPt: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(943);{$ENDIF}
  if (ViewportHost = nil) or (ViewportHost.Container = nil) then Exit;

  MaybeStartFromFit;
  MaybeRestoreView;
  MaybeApplyInitialLocation;
  MaybeComputeHeightsCsv;
  MaybeTakeShot;

  Fps := ViewportHost.Container.Fps.RealFps;
  if Fps > 0 then
    Cap := Format('%.0f FPS', [Fps])
  else
    Cap := '-- FPS';

  if GlobalShaderProfiler <> nil then
  begin
    if GlobalShaderProfiler.FormatStats <> '' then
      Cap := Cap + #10 + GlobalShaderProfiler.FormatStats;
  end;

  { Per-frame scene render counters — class-wide figures published by
    TProfiledScene.FrameBoundary, so they reflect whatever scenes (now
    the streaming map's tiles) rendered this frame. The old per-map
    tile/tree/shrub totals came from TOsm3dMapTransform and are gone. }
  if Viewport.Camera <> nil then
    Cap := Cap + #10 + Format(
      'ent=%d drew=%d distC=%d frustC=%d',
      [TProfiledScene.LastFrameEntered,
       TProfiledScene.LastFrameDrew,
       TProfiledScene.LastFrameDistCulled,
       TProfiledScene.LastFrameFrustCulled]);

  if GlobalShaderProfiler <> nil then
    Cap := Cap + Format('  sync %dµs',
      [GlobalShaderProfiler.LastAdvanceMicros]);

  { Camera geo-position / altitude / heading
 Only on the streaming path (FStreamSession holds the fixed local
 projection). World +Z is North, world -X is East — so the compass
 bearing is atan2(East, North) = atan2(-Dir.X, Dir.Z). }
  if (FStreamSession <> nil) and (Viewport.Camera <> nil) then
  begin
    CamPos := Viewport.Camera.WorldTranslation;
    CamGeo := FStreamSession.CameraGeo(CamPos.X, CamPos.Z);

    Dir := Viewport.Camera.Direction;
    Heading := RadToDeg(ArcTan2(-Dir.X, Dir.Z));
    if Heading < 0 then Heading := Heading + 360.0;

    { 8-point compass. Offset by half a sector (22.5°) before dividing
      so each label is centred on its bearing. }
    case Trunc(Heading / 45.0 + 0.5) mod 8 of
      0: CompassPt := 'N';
      1: CompassPt := 'NE';
      2: CompassPt := 'E';
      3: CompassPt := 'SE';
      4: CompassPt := 'S';
      5: CompassPt := 'SW';
      6: CompassPt := 'W';
    else CompassPt := 'NW';
    end;

    Cap := Cap + #10 + Format(
      'lat %.5f  lon %.5f  alt %.0f m  hdg %.0f° %s',
      [CamGeo.Lat, CamGeo.Lon, CamPos.Y, Heading, CompassPt]);

    Cap := Cap + #10 + 'tile ' + FStreamSession.CameraTileName(CamPos.X, CamPos.Z);
  end;

  FFpsLabel.Caption := Cap;
end;

{ ── MCP-фасад: реализация public-обёрток (юнит Osm3dMcp) ─────────────── }

function TStudioMainForm.SettingsPtr: PStudioSettings;
begin
  { Адрес поля формы стабилен: экземпляр формы живёт весь процесс, сам
    record никуда не перемещается (обновляется целиком по месту). }
  Result := @FSettings;
end;

function TStudioMainForm.StreamSession: TOsm3dStreamingSession;
begin
  Result := FStreamSession;
end;

function TStudioMainForm.StreamOrigin: TLatLon;
begin
  Result := FStreamOrigin;
end;

function TStudioMainForm.RoutePointCount: Integer;
begin
  Result := Length(FRoute);
end;

function TStudioMainForm.IsFlatMode: Boolean;
begin
  Result := FFlatMode;
end;

procedure TStudioMainForm.McpLoadRoute(const FileName: string);
begin
  LoadRouteFile(FileName);   { исключения уходят наверх — в MCP tool error }
end;

procedure TStudioMainForm.McpStartStreaming(const AOrigin: TLatLon;
  AUseOrigin: Boolean);
begin
  if AUseOrigin then
    StartStreaming(AOrigin)
  else if Length(FRoute) >= 1 then
    StartStreaming(FRoute[0])
  else
    raise Exception.Create(
      'osm.start_streaming: маршрут не загружен и lat/lon не заданы');
end;

procedure TStudioMainForm.McpSetMapMode(AFlat: Boolean);
begin
  SetMapMode(AFlat);
end;

procedure TStudioMainForm.McpScreenshot(const FileName: string);
begin
  SaveViewportShot(FileName);
end;

procedure TStudioMainForm.McpResetTiles;
begin
  ResetTileCache;
end;

procedure TStudioMainForm.McpJumpToPlace(const ALoc: TLatLon);
var
  Hit: TGeoHit;
begin
  Hit := Default(TGeoHit);
  Hit.Location := ALoc;
  SearchPlacePicked(Self, Hit);
end;

end.
