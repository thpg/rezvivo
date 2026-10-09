unit Osm3dWarmupOverlay;

{ Оверлей «прогрева» маршрута — общая фича стримера Osm3d, одинаковая для
  Osm3dStudio и игры.

  Пока снап-воркер стриминговой карты прогоняет ВСЕ тайлы bbox'а
  FIT-маршрута через штатный конвейер (см. FSnapForceTiles /
  FSnapHoldEviction в Osm3dStreamingMap), этот полноэкранный 2D-контрол:

    • закрывает вьюпорт затемнённой плоской картой ОБЛАСТИ маршрута
      (растровые slippy-тайлы OSM, без какой-либо навигации — весь ввод
      проглатывается);
    • рисует линию маршрута;
    • поверх каждого грузящегося гео-тайла — плоский полупрозрачный
      столбик прогресса со стадией и процентом. Текст тот же, что у
      3D-плейсхолдера тайла (LoadPhaseText: «HTTP 37%» / «Gen 82%»),
      готовый тайл подсвечивается зелёным.

  Владелец и водитель — TOsm3dStreamingMap: она создаёт оверлей, кажет его
  на время удержания снапа и толкает состояния тайлов из своего Update.
  Хост-программа лишь вставляет контрол в UI поверх вьюпорта:
      Viewport.InsertFront(Session.Map.WarmupOverlay);
  Больше от хоста ничего не требуется — прогрев начинается вместе со
  снапом (в игре — сразу после BeginRouteSnap, в студии — по авто-триггеру
  карты) и заканчивается перед самим притягиванием. }

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$codepage UTF8}

interface

uses UiTranslations,
  Classes,
  SysUtils,
  Math,
  SyncObjs,
  CastleUIControls,
  CastleControls,
  CastleVectors,
  CastleColors,
  CastleRectangles,
  CastleKeysMouse,
  CastleImages,
  CastleGLImages,
  Osm3dGeoMath,
  Osm3dGeoTileGrid,
  Osm3dCacheHTTPFetcher,
  Osm3dKnowledgeRecipe,
  Osm3dImageCodecLock;

const
  { Растровая подложка. Тот же публичный сервер, что у TOsm3dSlippyMap. }
  WARMUP_RASTER_MAX_TILES = 48;    { потолок числа растровых тайлов подложки }
  WARMUP_RASTER_MIN_ZOOM  = 3;
  WARMUP_RASTER_MAX_ZOOM  = 17;
  WARMUP_DECODE_PER_FRAME = 6;     { GL-загрузок растра на кадр (main); декод в потоке }
  WARMUP_ROUTE_MAX_PTS    = 1024;  { линия маршрута прореживается до этого }
  WARMUP_MIN_LABEL_CELL_PX = 34.0; { уже — текст в столбике не читается, гасим }
  WARMUP_MARGIN   = 24.0;   { поля вокруг панели карты, локальные px }
  WARMUP_HEADER_H = 48.0;   { полоса заголовка сверху }
  { Список этапов загрузки — фиксированные шаги конвейера подготовки
    маршрута; состояния толкаются хостом через SetStageState. Рисуется
    колонкой слева от панели карты (её ширина зарезервирована в
    PanelRectLocal, поэтому список не перекрывает клетки и маршрут). }
  WARMUP_STAGE_COUNT = 6;
  WARMUP_STAGE_NAMES: array[0..WARMUP_STAGE_COUNT - 1] of string = (
    'Route elevation profile',
    'Preloading tiles',
    'Loading roads',
    'Snapping route',
    'Elevation correction',
    'Placing rider at start');
  WARMUP_STAGE_COL_W = 250.0; { ширина колонки этапов, локальные px }
  WARMUP_STAGE_ROW_H = 26.0;  { шаг строки списка этапов }
  WARMUP_STAGE_TOP   = 14.0;  { отступ списка от полосы заголовка }

type
  { Псевдоним из Osm3dMapUtils (array of TLatLon). Объявлен локально,
    чтобы не тянуть Osm3dMapUtils с его тяжёлыми зависимостями
    (Osm3dHeightmap/Osm3dGeomMesh) ради одного имени. Совместим по
    структуре — вызовы ShowWarmup из карты передают тот же массив. }
  TRouteLatLonArray = array of TLatLon;

  { Состояние одного прогреваемого гео-тайла, толкается картой каждый кадр.
    Stage/Pct — РОВНО то, что LoadPhaseInfo даёт 3D-плейсхолдеру. }
  { Фаза клетки на экране прогрева:
      wpQueue   — в очереди (пусто)
      wpGen     — генерация/загрузка тайла: ЖЁЛТЫЙ столбик прогресса
      wpGenDone — тайл готов на диске, ждёт harvest: жёлтая клетка целиком
      wpHarvest — идёт загрузка дорог из тайла (harvest): ЗЕЛЁНЫЙ столбик
      wpDone    — harvest завершён: зелёная клетка целиком }
  TWarmupPhase = (wpQueue, wpGen, wpGenDone, wpHarvest, wpDone);

  { Состояние этапа загрузки в списке слева:
      wssPending — ещё не начат (серый)
      wssActive  — идёт сейчас (жёлтый пульсирующий маркер + деталь)
      wssDone    — завершён (зелёная галочка)
      wssError   — завершился ошибкой (красный крест + деталь) }
  TWarmupStageState = (wssPending, wssActive, wssDone, wssError);

  TWarmupStage = record
    State:  TWarmupStageState;
    Detail: string;    { уточнение рядом с названием ('3 / 20', '12 %') }
  end;

  { Состояние одной клетки тайла, толкается картой каждый кадр.
    Gen-фаза: Stage/Pct — РОВНО то, что LoadPhaseInfo даёт 3D-плейсхолдеру.
    Harvest-фаза: HPct — доля загруженных дорожных тайлов. }
  TWarmupTileState = record
    Phase: TWarmupPhase;
    Stage: string;    { текст gen-стадии ('' = в очереди) }
    Pct:   Integer;   { % gen-стадии }
    HPct:  Integer;   { % harvest }
    Done:  Boolean;   { gen готов (тайл на диске) }
  end;

  { Нормализованные веб-меркаторные координаты (slippy): x,y в [0..1],
    y растёт К ЮГУ (экранный «вниз» карты). }
  TMercPt = record
    X, Y: Double;
  end;

  TWarmupTile = record
    Id:    TGeoTileId;
    M0:    TMercPt;            { северо-западный угол (min merc) }
    M1:    TMercPt;            { юго-восточный угол (max merc) }
    State: TWarmupTileState;
    BarHeight: Single;        { measured label plus padding, local UI pixels }
    LabelDirty: Boolean;
    PhotoSummary: string;
  end;

  TRasterTile = record
    Z, X, Y: Integer;
    Img:     TDrawableImage;   { nil, пока не декодирован }
  end;

  TOsm3dWarmupOverlay = class;

  { Один фоновый поток качает растровые тайлы подложки через общий
    HTTP-фетчер с байтовым кэшем (GetUrl синхронный и потокобезопасный —
    им же пользуются gen-воркеры стримера). Результаты складываются под
    замком; декодирует их main thread в Update. }
  TWarmupRasterThread = class(TThread)
  private
    FOwner: TOsm3dWarmupOverlay;
    FMapHttp:THTTPFetcherWithCache;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TOsm3dWarmupOverlay);
    destructor Destroy;override;
    procedure Cancel;
  end;

  TOsm3dWarmupOverlay = class(TCastleUserInterface)
  private
    FShowing:    Boolean;
    FPointStart: Boolean;
    FTiles:      array of TWarmupTile;
    FRouteMerc:  array of TMercPt;
    FMercMin:    TMercPt;          { общий bbox тайлов в меркаторе }
    FMercMax:    TMercPt;
    FHttp:       THTTPFetcherWithCache;   { не владеем }

    { растровая подложка }
    FRaster:      array of TRasterTile;
    FRasterZ:     Integer;
    FRasterTh:    TWarmupRasterThread;
    FRasterLock:  TCriticalSection;
    { Раньше поток складывал СЫРЫЕ байты, а декод (LoadImage) делал main в
      DrainRasterDecodes — тяжело, морозило кадр. Теперь декод в потоке;
      сюда кладётся уже ДЕКОДИРОВАННАЯ картинка, main делает только
      GL-загрузку (TDrawableImage). }
    FRasterImg:   array of TCastleImage;  { параллельно FRaster; декодировано в потоке }
    FRasterHave:  array of Boolean;  { картинка готова, ждёт GL-загрузки }

    { анимация снапа: маршрут перекрашивается по мере обработки }
    FRouteStep:  Integer;   { шаг прореживания FRouteMerc (ориг.точек на 1) }
    FSnapTarget: Integer;   { целевой фронтир от снаппера (индекс FRouteMerc) }
    FSnapFront:  Integer;   { округлённый экранный фронтир; <0 = снапа нет }

    { подписи }
    FHeader:     TCastleLabel;
    FBarLabels:  array of TCastleLabel;
    FLayoutW:    Single;             { EffectiveWidth/Height последней раскладки }
    FLayoutH:    Single;
    FLabelsDirty: Boolean;

    { список этапов загрузки (колонка слева): текст — дочерние
      TCastleLabel, маркеры состояния рисуются в Render }
    FStages:      array[0..WARMUP_STAGE_COUNT - 1] of TWarmupStage;
    FStageLabels: array[0..WARMUP_STAGE_COUNT - 1] of TCastleLabel;
    FStagePulse:  Single;            { фаза пульса маркера активного этапа }

    { красная плашка ошибки поверх карты (SetError) }
    FErrorMsg:    string;
    FErrorLabel:  TCastleLabel;

    function  MercOf(const P: TLatLon): TMercPt;
    { Прямоугольник панели карты в ЛОКАЛЬНЫХ (немасштабированных)
      координатах контрола: bbox вписан с сохранением пропорций;
      слева зарезервирована колонка списка этапов. }
    function  PanelRectLocal: TFloatRectangle;
    function  MercToLocal(const M: TMercPt; const Panel: TFloatRectangle): TVector2;
    procedure PickRasterZoom;
    procedure RelayoutLabels;
    procedure DrainRasterDecodes;
    procedure FreeRaster;
    procedure UpdateStageLabel(AIndex: Integer);
    function StageRow(AIndex: Integer): Integer;
    function GetTileCount: Integer;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    { Показать прогрев: сетка гео-тайлов, список прогреваемых тайлов (тот
      же массив и порядок, что у карты в FSnapForceTiles — состояния
      толкаются по индексу), маршрут для линии, HTTP-фетчер подложки
      (nil = без растра, останется тёмный фон). }
    procedure ShowWarmup(AGrid: TGeoTileGrid; const ATiles: TGeoTileIdArray;
      const ARoute: TRouteLatLonArray; AHttp: THTTPFetcherWithCache;
      ARecipes:TKnowledgeRecipeSnapshot=nil; APointStart:Boolean=False);
    procedure HideWarmup;
    { CPU join only, after HideWarmup on the main thread; no UI/GL disposal. }
    procedure JoinBackgroundStop;
    { Вызывать из Update владельца: скрытый UI сам Update не получает.
      Освобождает растр только после завершения фонового запроса. }
    procedure CollectFinishedRaster;

    { Толкнуть состояние тайла AIndex (индекс в ATiles из ShowWarmup).
      AStage/APct — из LoadPhaseInfo (тот же текст, что в 3D). }
    procedure SetTileState(AIndex: Integer; const AStage: string;
      APct: Integer; ADone: Boolean);

    { Фаза harvest клетки: тайл загружается для сбора дорог. AHPct — %
      (0..100), ADone=True — harvest клетки завершён (зелёная целиком).
      Рисуется ЗЕЛЁНЫМ, поверх жёлтой gen-фазы. }
    procedure SetTileHarvest(AIndex: Integer; AHPct: Integer; ADone: Boolean);
    procedure SetHeader(const ACaption: string);

    { Состояние этапа загрузки AIndex (0..WARMUP_STAGE_COUNT-1, названия —
      const-массив WARMUP_STAGE_NAMES). Деталь ADetail рисуется рядом с
      названием (для active/error — например '3 / 20' или '12 %'). }
    procedure SetStageState(AIndex: Integer; AState: TWarmupStageState;
      const ADetail: string = '');

    { Красная полупрозрачная плашка с текстом ошибки поверх карты внизу
      (длинный текст переносится). Карту и список этапов не скрывает.
      Повторный вызов заменяет текст; SetError('') — убрать плашку. }
    procedure SetError(const AMsg: string);

    { Анимация притягивания: точки маршрута [0..AFrontIdx) уже обработаны
      снаппером — их отрезок линии перекрашивается в зелёный, у фронтира
      рисуется яркая «голова». AFrontIdx — в ИСХОДНЫХ индексах маршрута
      (0..ATotal); внутри пересчитывается в прореженную линию.
      AFrontIdx <= 0 возвращает маршрут в исходный красный. }
    procedure SetSnapProgress(AFrontIdx, ATotal: Integer);

    { Волна снапа дошла до конца маршрута? Хост держит экран прогрева
      открытым, пока False — чтобы анимация доиграла, даже если снаппер
      уже завершился (на кэше он мгновенный). }
    function IsSnapAnimDone: Boolean;

    procedure Render; override;
    procedure Update(const SecondsPassed: Single;
      var HandleInput: Boolean); override;

    { «Без навигации»: пока оверлей виден, весь ввод проглатывается —
      WASD студии и клики не доходят до вьюпорта под ним. }
    function Press(const Event: TInputPressRelease): Boolean; override;
    function Release(const Event: TInputPressRelease): Boolean; override;
    function Motion(const Event: TInputMotion): Boolean; override;

    property Showing: Boolean read FShowing;
    property TileCount: Integer read GetTileCount;
  end;

implementation

uses
  StrUtils, Osm3dFlatMap, CastleGLUtils, Osm3dPhotoStatusText;

{ ── TWarmupRasterThread ───────────────────────────────────────────── }

constructor TWarmupRasterThread.Create(AOwner: TOsm3dWarmupOverlay);
begin
  FOwner := AOwner;
  FreeOnTerminate := False;
  FMapHttp:=THTTPFetcherWithCache.Create(AOwner.FHttp.Cache,False);
  FMapHttp.TimeoutMs:=5000;FMapHttp.MaxRetries:=1;
  inherited Create(False);
end;

destructor TWarmupRasterThread.Destroy;
begin Cancel;WaitFor;FMapHttp.Free;inherited;end;
procedure TWarmupRasterThread.Cancel;
begin Terminate;FMapHttp.AbortAllRequests;end;

procedure TWarmupRasterThread.Execute;
var I,Pass:Integer;Img:TCastleImage;
begin
  for Pass:=0 to 1 do for I:=0 to High(FOwner.FRaster)do begin
    if Terminated then Exit;
    if(Pass=1)and(FOwner.FRaster[I].Z<FLAT_MAP_DETAIL_ZOOM)then Continue;
    Img:=nil;
    try Img:=FlatMapTile(FMapHttp,FOwner.FRaster[I].Z,FOwner.FRaster[I].X,
      FOwner.FRaster[I].Y,Pass=1,Self);except Img:=nil;end;
    if Img=nil then Continue;
    if Terminated then begin Img.Free;Exit;end;
    FOwner.FRasterLock.Acquire;
    try
      FOwner.FRasterImg[I].Free;
      FOwner.FRasterImg[I]:=Img;FOwner.FRasterHave[I]:=True;
    finally FOwner.FRasterLock.Release;end;
  end;
end;

{ ── TOsm3dWarmupOverlay ───────────────────────────────────────────── }

constructor TOsm3dWarmupOverlay.Create(AOwner: TComponent);
var
  I: Integer;
  L: TCastleLabel;
begin
  inherited Create(AOwner);
  FullSize := True;
  Exists   := False;
  FShowing := False;
  FRasterLock := TCriticalSection.Create;

  L:=TCastleLabel.Create(Self);
  L.Caption:='© OpenStreetMap contributors · Natural Earth · Copernicus DEM';
  L.FontScale:=0.55;L.Color:=Vector4(0.45,0.50,0.52,1);
  L.Anchor(hpRight,-8);L.Anchor(vpBottom,4);InsertFront(L);

  FHeader := TCastleLabel.Create(Self);
  FHeader.Color := Vector4(1, 1, 1, 0.95);
  FHeader.FontScale := 1.25;
  FHeader.Anchor(hpMiddle);
  FHeader.Anchor(vpTop, -14);
  InsertFront(FHeader);

  { строки списка этапов: создаются один раз (их фиксированное число),
    текст/цвет обновляет UpdateStageLabel; маркеры рисует Render }
  for I := 0 to WARMUP_STAGE_COUNT - 1 do
  begin
    FStages[I].State  := wssPending;
    FStages[I].Detail := '';
    L := TCastleLabel.Create(Self);
    L.FontScale := 0.8;                     { ~16 px при базовых 20 }
    BindUiText(L, WARMUP_STAGE_NAMES[I]);
    L.Color := Vector4(0.55, 0.55, 0.55, 0.85);
    L.Anchor(hpLeft, WARMUP_MARGIN + 20);
    L.Anchor(vpTop, -(WARMUP_HEADER_H + WARMUP_STAGE_TOP +
      I * WARMUP_STAGE_ROW_H + 4));
    InsertFront(L);
    FStageLabels[I] := L;
  end;
  FStagePulse := 0;

  FErrorMsg := '';
  FErrorLabel := TCastleLabel.Create(Self);
  FErrorLabel.Color := Vector4(1, 1, 1, 0.97);
  FErrorLabel.FontScale := 0.9;
  FErrorLabel.Alignment := hpMiddle;
  FErrorLabel.Anchor(hpMiddle);
  FErrorLabel.Anchor(vpBottom, 14 + 8);
  FErrorLabel.Exists := False;
  InsertFront(FErrorLabel);
end;

destructor TOsm3dWarmupOverlay.Destroy;
begin
  HideWarmup;
  FreeRaster;                       { join до освобождения полей владельца }
  FreeAndNil(FRasterLock);
  inherited Destroy;
end;

function TOsm3dWarmupOverlay.MercOf(const P: TLatLon): TMercPt;
var
  LatR: Double;
begin
  LatR := Max(-85.05112878, Min(85.05112878, P.Lat)) * Pi / 180.0;
  Result.X := (P.Lon + 180.0) / 360.0;
  Result.Y := (1.0 - Ln(Tan(LatR) + 1.0 / Cos(LatR)) / Pi) / 2.0;
end;

procedure TOsm3dWarmupOverlay.PickRasterZoom;
var
  Z, NX, NY, X0, X1, Y0, Y1: Integer;
  Best: Integer;
begin
  { Максимальный зум, при котором подложка bbox'а помещается в потолок
    числа тайлов — самая детальная карта из «дешёвых». }
  Best := WARMUP_RASTER_MIN_ZOOM;
  for Z := WARMUP_RASTER_MIN_ZOOM to WARMUP_RASTER_MAX_ZOOM do
  begin
    X0 := Floor(FMercMin.X * (1 shl Z));  X1 := Floor(FMercMax.X * (1 shl Z));
    Y0 := Floor(FMercMin.Y * (1 shl Z));  Y1 := Floor(FMercMax.Y * (1 shl Z));
    NX := X1 - X0 + 1;  NY := Y1 - Y0 + 1;
    if NX * NY <= WARMUP_RASTER_MAX_TILES then Best := Z else Break;
  end;
  FRasterZ := Best;
end;

procedure TOsm3dWarmupOverlay.ShowWarmup(AGrid: TGeoTileGrid;
  const ATiles: TGeoTileIdArray; const ARoute: TRouteLatLonArray;
  AHttp: THTTPFetcherWithCache;ARecipes:TKnowledgeRecipeSnapshot;APointStart:Boolean);
var
  I, K, N, Step, X0, X1, Y0, Y1, RX, RY: Integer;
  MX, MY: Double;
  Box: TLatLonBox;
  L: TCastleLabel;
  Coverage:TPhotoTileCoverage;
  WorkflowText:string;
begin
  HideWarmup;
  FreeRaster;                       { прежний поток не должен видеть новый растр }
  { Плоская карта без 3D-тайлов (ShowFlatMap): показываем растр+маршрут по
    ARoute. Выходим только если показывать вообще нечего. }
  if (Length(ATiles) = 0) and (Length(ARoute) < 2) then Exit;
  if (Length(ATiles) > 0) and (AGrid = nil) then Exit;
  FHttp := AHttp;
  FPointStart := APointStart;

  { тайлы: гео-бокс -> меркатор, общий bbox }
  SetLength(FTiles, Length(ATiles));
  for I := 0 to High(ATiles) do
  begin
    FTiles[I].Id := ATiles[I];
    Box := AGrid.TileBox(ATiles[I]);
    { меркаторный Y растёт к югу: северо-запад = (MinLon, MaxLat) }
    FTiles[I].M0 := MercOf(TLatLon.Make(Box.MaxLat, Box.MinLon));
    FTiles[I].M1 := MercOf(TLatLon.Make(Box.MinLat, Box.MaxLon));
    FTiles[I].State.Phase := wpQueue;
    FTiles[I].State.Stage := '';
    FTiles[I].State.Pct   := 0;
    FTiles[I].State.HPct  := 0;
    FTiles[I].State.Done  := False;
    FTiles[I].PhotoSummary:='';
    if ARecipes<>nil then begin
      Coverage:=ARecipes.TileCoverage(ATiles[I]);
      if Coverage.Buildings+Coverage.Roads+Coverage.Plants+Coverage.Details>0 then
        FTiles[I].PhotoSummary:=Format(UiText('Photo: buildings %d, roads %d, plants %d, details %d'),
          [Coverage.Buildings,Coverage.Roads,Coverage.Plants,Coverage.Details]);
      WorkflowText:=PhotoWorkflowCaption(ARecipes.TileWorkflow(ATiles[I]));
      if WorkflowText<>'' then begin
        if FTiles[I].PhotoSummary<>'' then FTiles[I].PhotoSummary+=LineEnding;
        FTiles[I].PhotoSummary+=WorkflowText;
      end;
    end;
    if I = 0 then
    begin
      FMercMin := FTiles[I].M0;
      FMercMax := FTiles[I].M1;
    end
    else
    begin
      FMercMin.X := Min(FMercMin.X, FTiles[I].M0.X);
      FMercMin.Y := Min(FMercMin.Y, FTiles[I].M0.Y);
      FMercMax.X := Max(FMercMax.X, FTiles[I].M1.X);
      FMercMax.Y := Max(FMercMax.Y, FTiles[I].M1.Y);
    end;
  end;

  { маршрут: прореживание до WARMUP_ROUTE_MAX_PTS точек }
  FSnapFront  := -1;
  FSnapTarget := -1;
  FRouteStep  := 1;
  N := Length(ARoute);
  if N > 0 then
  begin
    Step := (N + WARMUP_ROUTE_MAX_PTS - 1) div WARMUP_ROUTE_MAX_PTS;
    if Step < 1 then Step := 1;
    FRouteStep := Step;
    SetLength(FRouteMerc, (N + Step - 1) div Step + 1);
    K := 0;
    I := 0;
    while I < N do
    begin
      FRouteMerc[K] := MercOf(ARoute[I]);
      Inc(K);
      Inc(I, Step);
    end;
    if (N > 1) and ((N - 1) mod Step <> 0) then
    begin
      FRouteMerc[K] := MercOf(ARoute[N - 1]);   { хвост маршрута не теряем }
      Inc(K);
    end;
    SetLength(FRouteMerc, K);
  end
  else
    SetLength(FRouteMerc, 0);

  { Нет 3D-тайлов (плоская карта): bbox растра — по маршруту (иначе
    PickRasterZoom получит неинициализированный bbox от тайлов). Запас
    ~8% размаха, чтобы линия не липла к краю. }
  if (Length(ATiles) = 0) and (Length(FRouteMerc) > 0) then
  begin
    FMercMin := FRouteMerc[0]; FMercMax := FRouteMerc[0];
    for I := 1 to High(FRouteMerc) do
    begin
      FMercMin.X := Min(FMercMin.X, FRouteMerc[I].X);
      FMercMin.Y := Min(FMercMin.Y, FRouteMerc[I].Y);
      FMercMax.X := Max(FMercMax.X, FRouteMerc[I].X);
      FMercMax.Y := Max(FMercMax.Y, FRouteMerc[I].Y);
    end;
    MX := 0.08 * (FMercMax.X - FMercMin.X);
    MY := 0.08 * (FMercMax.Y - FMercMin.Y);
    if MX > 0 then begin FMercMin.X := FMercMin.X - MX; FMercMax.X := FMercMax.X + MX; end;
    if MY > 0 then begin FMercMin.Y := FMercMin.Y - MY; FMercMax.Y := FMercMax.Y + MY; end;
  end;

  { подписи столбиков — по одной на тайл; текст/позиции в RelayoutLabels }
  SetLength(FBarLabels, Length(FTiles));
  for I := 0 to High(FTiles) do
  begin
    L := TCastleLabel.Create(Self);
    L.Color := Vector4(1, 1, 1, 0.95);
    L.Caption := FTiles[I].PhotoSummary;
    L.Alignment := hpMiddle;
    L.LineSpacing := 1;
    L.Anchor(hpMiddle);
    L.Anchor(vpMiddle);
    L.Exists := False;
    InsertFront(L);
    FBarLabels[I] := L;
  end;
  FLayoutW := -1;                    { форс первой раскладки }
  FLayoutH := -1;

  { растровая подложка }
  SetLength(FRaster, 0);
  if FHttp <> nil then
  begin
    PickRasterZoom;
    X0 := Floor(FMercMin.X * (1 shl FRasterZ));
    X1 := Floor(FMercMax.X * (1 shl FRasterZ));
    Y0 := Floor(FMercMin.Y * (1 shl FRasterZ));
    Y1 := Floor(FMercMax.Y * (1 shl FRasterZ));
    { защита: если даже минимальный зум не влез в кап (аномальный bbox) —
      живём без растровой подложки, останется тёмный фон }
    if (X1 - X0 + 1) * (Y1 - Y0 + 1) > WARMUP_RASTER_MAX_TILES * 2 then
    begin
      SetLength(FRaster, 0);
    end
    else
    begin
    SetLength(FRaster, (X1 - X0 + 1) * (Y1 - Y0 + 1));
    K := 0;
    for RY := Y0 to Y1 do
      for RX := X0 to X1 do
      begin
        FRaster[K].Z := FRasterZ;
        FRaster[K].X := RX;
        FRaster[K].Y := RY;
        FRaster[K].Img := nil;
        Inc(K);
      end;
    SetLength(FRasterImg,  Length(FRaster));
    SetLength(FRasterHave,  Length(FRaster));
    for I := 0 to High(FRaster) do FRasterHave[I] := False;
    FRasterTh := TWarmupRasterThread.Create(Self);
    end;
  end;

  FHeader.Caption := '';
  { список этапов и плашка ошибки — в исходное состояние }
  for I := 0 to WARMUP_STAGE_COUNT - 1 do
  begin
    FStages[I].State  := wssPending;
    FStages[I].Detail := '';
    UpdateStageLabel(I);
  end;
  FStagePulse := 0;
  SetError('');
  FShowing := True;
  Exists   := True;
end;

procedure TOsm3dWarmupOverlay.FreeRaster;
var
  I: Integer;
begin
  if FRasterTh <> nil then
  begin
    FRasterTh.Cancel;
    FRasterTh.WaitFor;
    FreeAndNil(FRasterTh);
  end;
  for I := 0 to High(FRaster) do
    FreeAndNil(FRaster[I].Img);
  { Декодированные потоком, но ещё не загруженные в GL — освободить
    (поток уже присоединён выше, писать в массив некому). }
  for I := 0 to High(FRasterImg) do
    FreeAndNil(FRasterImg[I]);
  SetLength(FRaster, 0);
  SetLength(FRasterImg, 0);
  SetLength(FRasterHave, 0);
  FHttp := nil;
end;

procedure TOsm3dWarmupOverlay.CollectFinishedRaster;
begin
  if FShowing then Exit;
  if (FRasterTh <> nil) and (not FRasterTh.Finished) then Exit;
  if (FRasterTh <> nil) or (Length(FRaster) <> 0) then FreeRaster;
end;

procedure TOsm3dWarmupOverlay.HideWarmup;
var
  I: Integer;
begin
  if FRasterTh <> nil then FRasterTh.Cancel;
  for I := 0 to High(FBarLabels) do
    FreeAndNil(FBarLabels[I]);
  SetLength(FBarLabels, 0);
  SetLength(FTiles, 0);
  SetLength(FRouteMerc, 0);
  FShowing := False;
  Exists   := False;
  CollectFinishedRaster;
end;

procedure TOsm3dWarmupOverlay.SetTileState(AIndex: Integer;
  const AStage: string; APct: Integer; ADone: Boolean);
var
  L: TCastleLabel;
  Txt: string;
begin
  if (AIndex < 0) or (AIndex > High(FTiles)) then Exit;
  if (FTiles[AIndex].State.Stage = AStage)
     and (FTiles[AIndex].State.Pct = APct)
     and (FTiles[AIndex].State.Done = ADone) then Exit;
  FTiles[AIndex].State.Stage := AStage;
  FTiles[AIndex].State.Pct   := APct;
  FTiles[AIndex].State.Done  := ADone;
  { фаза gen: готов → ждёт harvest (жёлтая клетка), иначе идёт (жёлтый бар),
    пусто → очередь. Harvest-фазу не трогаем — её ставит SetTileHarvest. }
  if FTiles[AIndex].State.Phase <= wpGenDone then
    if ADone then
      FTiles[AIndex].State.Phase := wpGenDone
    else if AStage <> '' then
      FTiles[AIndex].State.Phase := wpGen
    else
      FTiles[AIndex].State.Phase := wpQueue;

  if AIndex > High(FBarLabels) then Exit;
  L := FBarLabels[AIndex];
  if L = nil then Exit;
  { Текст 1:1 с 3D-плейсхолдером (LoadPhaseText): '<стадия> <pct>%',
    очередь — пусто, готовый — '100%'. }
  if ADone then
    Txt := '100%'
  else if AStage <> '' then
  begin
    Txt := AStage;
    if APct >= 0 then Txt := Format('%s %d%%', [AStage, APct]);
  end
  else
    Txt := '';
  if FTiles[AIndex].PhotoSummary<>'' then Txt:=Txt+LineEnding+FTiles[AIndex].PhotoSummary;
  if L.Caption <> Txt then
  begin
    L.Caption := Txt;
    FTiles[AIndex].LabelDirty := True;
    FLabelsDirty := True;
  end;
end;

procedure TOsm3dWarmupOverlay.JoinBackgroundStop;
begin
  if FRasterTh<>nil then FRasterTh.WaitFor;
end;

procedure TOsm3dWarmupOverlay.SetTileHarvest(AIndex: Integer;
  AHPct: Integer; ADone: Boolean);
var
  L: TCastleLabel;
  Txt: string;
  NewPhase: TWarmupPhase;
begin
  if (AIndex < 0) or (AIndex > High(FTiles)) then Exit;
  if ADone then NewPhase := wpDone else NewPhase := wpHarvest;
  if (FTiles[AIndex].State.Phase = NewPhase)
     and (FTiles[AIndex].State.HPct = AHPct) then Exit;
  FTiles[AIndex].State.Phase := NewPhase;
  FTiles[AIndex].State.HPct  := AHPct;

  if AIndex > High(FBarLabels) then Exit;
  L := FBarLabels[AIndex];
  if L = nil then Exit;
  if ADone then Txt := '100%'
  else if AHPct < 0 then Txt := UiText('Reading roads')
  else Txt := Format(UiText('roads %d%%'), [Max(0, Min(100, AHPct))]);
  if FTiles[AIndex].PhotoSummary<>'' then Txt:=Txt+LineEnding+FTiles[AIndex].PhotoSummary;
  if L.Caption <> Txt then
  begin
    L.Caption := Txt;
    FTiles[AIndex].LabelDirty := True;
    FLabelsDirty := True;
  end;
end;

procedure TOsm3dWarmupOverlay.SetHeader(const ACaption: string);
begin
  if FHeader.Caption <> ACaption then
    FHeader.Caption := ACaption;
end;

procedure TOsm3dWarmupOverlay.UpdateStageLabel(AIndex: Integer);
var
  L: TCastleLabel;
  Txt: string;
begin
  if (AIndex < 0) or (AIndex >= WARMUP_STAGE_COUNT) then Exit;
  L := FStageLabels[AIndex];
  if L = nil then Exit;
  L.Exists := StageRow(AIndex) >= 0;
  if not L.Exists then Exit;
  L.Anchor(vpTop, -(WARMUP_HEADER_H + WARMUP_STAGE_TOP +
    StageRow(AIndex) * WARMUP_STAGE_ROW_H + 4));
  if FStages[AIndex].Detail <> '' then
    Txt := UiText(WARMUP_STAGE_NAMES[AIndex]) + ' - ' + FStages[AIndex].Detail
  else
    Txt := UiText(WARMUP_STAGE_NAMES[AIndex]);
  if L.Caption <> Txt then L.Caption := Txt;
  case FStages[AIndex].State of
    wssPending: L.Color := Vector4(0.55, 0.55, 0.55, 0.85);
    wssActive:  L.Color := Vector4(1.00, 0.80, 0.30, 0.98);
    wssDone:    L.Color := Vector4(0.55, 0.95, 0.60, 0.95);
    wssError:   L.Color := Vector4(1.00, 0.45, 0.40, 0.98);
  end;
end;

function TOsm3dWarmupOverlay.StageRow(AIndex: Integer): Integer;
begin
  if not FPointStart then Exit(AIndex);
  case AIndex of
    1: Result := 0; { one tile, no FIT or route-snap stages }
    5: Result := 1;
    else Result := -1;
  end;
end;

function TOsm3dWarmupOverlay.GetTileCount: Integer;
begin
  Result := Length(FTiles);
end;

procedure TOsm3dWarmupOverlay.SetStageState(AIndex: Integer;
  AState: TWarmupStageState; const ADetail: string);
begin
  if (AIndex < 0) or (AIndex >= WARMUP_STAGE_COUNT) then Exit;
  if (FStages[AIndex].State = AState)
     and (FStages[AIndex].Detail = ADetail) then Exit;
  FStages[AIndex].State  := AState;
  FStages[AIndex].Detail := ADetail;
  UpdateStageLabel(AIndex);
end;

procedure TOsm3dWarmupOverlay.SetError(const AMsg: string);
begin
  if FErrorMsg = AMsg then Exit;
  FErrorMsg := AMsg;
  if FErrorLabel = nil then Exit;
  if AMsg = '' then
  begin
    FErrorLabel.Caption := '';
    FErrorLabel.Exists  := False;
  end
  else
  begin
    FErrorLabel.Caption := AMsg;
    { перенос длинного текста; при ресайзе обновляется в Update }
    FErrorLabel.MaxWidth := EffectiveWidth * 0.7;
    FErrorLabel.Exists   := True;
  end;
end;

procedure TOsm3dWarmupOverlay.SetSnapProgress(AFrontIdx, ATotal: Integer);
var
  F: Integer;
begin
  if (AFrontIdx <= 0) or (Length(FRouteMerc) < 2) or (FRouteStep < 1) then
  begin
    FSnapTarget := -1;
    Exit;
  end;
  F := AFrontIdx div FRouteStep;
  if F > High(FRouteMerc) then F := High(FRouteMerc);
  if (ATotal > 0) and (AFrontIdx >= ATotal) then F := High(FRouteMerc);
  if F > FSnapTarget then FSnapTarget := F;
  FSnapFront := FSnapTarget;
end;

function TOsm3dWarmupOverlay.IsSnapAnimDone: Boolean;
begin
  { Compatibility gate: the displayed frontier is the completed work. }
  Result := (FSnapTarget < 0)
            or (FSnapTarget >= High(FRouteMerc));
end;

function TOsm3dWarmupOverlay.PanelRectLocal: TFloatRectangle;
var
  W, H, SpanX, SpanY, Scale, PW, PH: Single;
begin
  { слева зарезервирована колонка списка этапов — панель карты (а значит
    клетки тайлов и линия маршрута) её не перекрывает }
  W := EffectiveWidth  - WARMUP_MARGIN * 2 - WARMUP_STAGE_COL_W;
  H := EffectiveHeight - WARMUP_MARGIN * 2 - WARMUP_HEADER_H;
  if W < 8 then W := 8;
  if H < 8 then H := 8;
  SpanX := FMercMax.X - FMercMin.X;
  SpanY := FMercMax.Y - FMercMin.Y;
  if SpanX <= 0 then SpanX := 1e-9;
  if SpanY <= 0 then SpanY := 1e-9;
  Scale := Min(W / SpanX, H / SpanY);
  PW := SpanX * Scale;
  PH := SpanY * Scale;
  Result := FloatRectangle(
    WARMUP_MARGIN + WARMUP_STAGE_COL_W + (W - PW) * 0.5,
    WARMUP_MARGIN + (H - PH) * 0.5,
    PW, PH);
end;

function TOsm3dWarmupOverlay.MercToLocal(const M: TMercPt;
  const Panel: TFloatRectangle): TVector2;
begin
  { меркаторный Y растёт к югу, экранный Y CGE — вверх: юг внизу }
  Result := Vector2(
    Panel.Left +
      (M.X - FMercMin.X) / (FMercMax.X - FMercMin.X) * Panel.Width,
    Panel.Bottom +
      (FMercMax.Y - M.Y) / (FMercMax.Y - FMercMin.Y) * Panel.Height);
end;

procedure TOsm3dWarmupOverlay.RelayoutLabels;
var
  I, Attempt, WordIndex: Integer;
  Panel: TFloatRectangle;
  A, B: TVector2;
  CellW, CellH, BarCY, FS, MaxBarH, TextW, TextH, Fit, WordW: Single;
  L: TCastleLabel;
  Resized: Boolean;
  Caption: string;
begin
  Resized := (EffectiveWidth <> FLayoutW) or (EffectiveHeight <> FLayoutH);
  Panel := PanelRectLocal;
  for I := 0 to High(FBarLabels) do
  begin
    if not Resized and not FTiles[I].LabelDirty then Continue;
    FTiles[I].LabelDirty := False;
    L := FBarLabels[I];
    if L = nil then Continue;
    A := MercToLocal(FTiles[I].M0, Panel);   { NW: левый ВЕРХ клетки }
    B := MercToLocal(FTiles[I].M1, Panel);   { SE: правый НИЗ клетки }
    CellW := B.X - A.X;
    CellH := A.Y - B.Y;
    FTiles[I].BarHeight := Min(CellH * 0.28, 22.0);
    if CellW < WARMUP_MIN_LABEL_CELL_PX then
    begin
      L.Exists := False;
      Continue;
    end;
    L.Exists := True;
    { Wrap using actual font metrics, including translated stage names.
      Grow the bar for multiple lines, then reduce text only if it still
      exceeds the cell. CGE's wrapping also handles long UTF-8 words. }
    TextW := Max(1.0, CellW - 8.0);
    MaxBarH := Max(8.0, Min(CellH - 2.0, 64.0));
    TextH := MaxBarH - 6.0;
    FS := CellW / 130.0;
    if FS < 0.55 then FS := 0.55;
    if FS > 1.0  then FS := 1.0;
    L.FontScale := FS;
    { Keep translated words whole on narrow cells before wrapping lines. }
    Caption := L.Caption;
    WordW := 0;
    for WordIndex := 1 to WordCount(Caption, [' ', #9, #10, #13]) do
      WordW := Max(WordW, L.Font.TextWidth(
        ExtractWord(WordIndex, Caption, [' ', #9, #10, #13])) / L.UIScale);
    if WordW > TextW then
      L.FontScale := L.FontScale * TextW / WordW * 0.98;
    L.MaxWidth := TextW;
    for Attempt := 0 to 11 do
    begin
      Fit := Min(TextW / Max(1.0, L.EffectiveWidth),
                 TextH / Max(1.0, L.EffectiveHeight));
      if Fit >= 1.0 then Break;
      L.FontScale := L.FontScale * Max(0.5, Min(0.9, Fit));
    end;
    FTiles[I].BarHeight := Min(MaxBarH,
      Max(FTiles[I].BarHeight, Ceil(L.EffectiveHeight + 6.0)));
    BarCY := B.Y + FTiles[I].BarHeight * 0.5;
    L.Anchor(hpMiddle, (A.X + B.X) * 0.5 - EffectiveWidth * 0.5);
    L.Anchor(vpMiddle, BarCY - EffectiveHeight * 0.5);
  end;
end;

procedure TOsm3dWarmupOverlay.DrainRasterDecodes;
var
  I, DoneN: Integer;
  Img: TCastleImage;
begin
  if FRasterLock = nil then Exit;
  DoneN := 0;
  for I := 0 to High(FRaster) do
  begin
    if DoneN >= WARMUP_DECODE_PER_FRAME then Break;
    Img := nil;
    FRasterLock.Acquire;
    try
      if FRasterHave[I] then
      begin
        Img := FRasterImg[I];          { уже ДЕКОДИРОВАНА потоком }
        FRasterImg[I]  := nil;
        FRasterHave[I] := False;
      end;
    finally
      FRasterLock.Release;
    end;
    if Img = nil then Continue;
    Inc(DoneN);
    { Только GL-загрузка (декод сделан в потоке) — кадр не морозит.
      TDrawableImage владеет картинкой (OwnsImage=True), освободит сам. }
    FreeAndNil(FRaster[I].Img);
    FRaster[I].Img := TDrawableImage.Create(Img, True, True);
  end;
end;

procedure TOsm3dWarmupOverlay.Update(const SecondsPassed: Single;
  var HandleInput: Boolean);
begin
  inherited;
  if not FShowing then Exit;
  DrainRasterDecodes;
  FStagePulse := FStagePulse + SecondsPassed;   { пульс маркера active }

  { Show completed route points immediately, with no timed catch-up. }
  FSnapFront := FSnapTarget;
  if FLabelsDirty or (EffectiveWidth <> FLayoutW) or
     (EffectiveHeight <> FLayoutH) then
  begin
    FLabelsDirty := False;
    RelayoutLabels;
    FLayoutW := EffectiveWidth;
    FLayoutH := EffectiveHeight;
    if (FErrorLabel <> nil) and FErrorLabel.Exists then
      FErrorLabel.MaxWidth := EffectiveWidth * 0.7;
  end;
  HandleInput := False;                { ввод дальше вниз не проходит }
end;

procedure TOsm3dWarmupOverlay.Render;
var
  RR, Panel, Dev: TFloatRectangle;
  SX, SY: Single;

  { локальные (немасштабированные) координаты -> экранные }
  function DevRect(L, B, W, H: Single): TFloatRectangle;
  begin
    Result := FloatRectangle(RR.Left + L * SX, RR.Bottom + B * SY,
                             W * SX, H * SY);
  end;

var
  I, J: Integer;
  A, B: TVector2;
  CellL, CellB, CellW, CellH, BarH, FillW: Single;
  MkX, MkCY, P, EW, EH: Single;
  Mks: array[0..3] of TVector2;
  Pts: array of TVector2;
  MZ: Double;
  TM0, TM1: TMercPt;
  St: TWarmupTileState;
begin
  inherited;
  if not FShowing then Exit;

  RR := RenderRect;
  if (EffectiveWidth <= 0) or (EffectiveHeight <= 0) then Exit;
  SX := RR.Width  / EffectiveWidth;    { = UIScale, но выведен из фактов }
  SY := RR.Height / EffectiveHeight;

  { затемнённый фон на весь контрол }
  DrawRectangle(RR, Vector4(0.04, 0.06, 0.08, 1.0));

  Panel := PanelRectLocal;
  Dev := DevRect(Panel.Left, Panel.Bottom, Panel.Width, Panel.Height);
  DrawRectangle(Dev, Vector4(0.10, 0.12, 0.14, 1.0));

  { растровая подложка: каждый slippy-тайл — на своё меркаторное место }
  MZ := 1 shl FRasterZ;
  for I := 0 to High(FRaster) do
    if FRaster[I].Img <> nil then
    begin
      TM0.X := FRaster[I].X / MZ;       TM0.Y := FRaster[I].Y / MZ;
      TM1.X := (FRaster[I].X + 1) / MZ; TM1.Y := (FRaster[I].Y + 1) / MZ;
      A := MercToLocal(TM0, Panel);     { NW -> левый верх }
      B := MercToLocal(TM1, Panel);     { SE -> правый низ }
      FRaster[I].Img.Draw(DevRect(A.X, B.Y, B.X - A.X, A.Y - B.Y));
    end;
  { лёгкое общее затемнение растра, чтобы столбики и маршрут читались }
  DrawRectangle(Dev, Vector4(0.0, 0.0, 0.0, 0.28));

  { клетки тайлов + столбики прогресса }
  for I := 0 to High(FTiles) do
  begin
    A := MercToLocal(FTiles[I].M0, Panel);
    B := MercToLocal(FTiles[I].M1, Panel);
    CellL := A.X;  CellB := B.Y;
    CellW := B.X - A.X;  CellH := A.Y - B.Y;
    St := FTiles[I].State;

    { рамка клетки — четырьмя тонкими прямоугольниками }
    DrawRectangle(DevRect(CellL, CellB, CellW, 1), Vector4(1, 1, 1, 0.22));
    DrawRectangle(DevRect(CellL, CellB + CellH - 1, CellW, 1), Vector4(1, 1, 1, 0.22));
    DrawRectangle(DevRect(CellL, CellB, 1, CellH), Vector4(1, 1, 1, 0.22));
    DrawRectangle(DevRect(CellL + CellW - 1, CellB, 1, CellH), Vector4(1, 1, 1, 0.22));

    { Заливка клетки целиком по завершённым фазам:
        wpGenDone — тайл готов на диске, ждёт harvest: приглушённый жёлтый
        wpDone    — harvest завершён: зелёный }
    if St.Phase = wpDone then
      DrawRectangle(DevRect(CellL, CellB, CellW, CellH),
        Vector4(0.15, 0.85, 0.25, 0.28))
    else if St.Phase = wpGenDone then
      DrawRectangle(DevRect(CellL, CellB, CellW, CellH),
        Vector4(0.85, 0.62, 0.10, 0.22));

    { плоский полупрозрачный столбик прогресса по низу клетки }
    BarH := FTiles[I].BarHeight;
    if BarH <= 0 then BarH := Min(CellH * 0.28, 22.0);
    DrawRectangle(DevRect(CellL, CellB, CellW, BarH),
      Vector4(0, 0, 0, 0.45));
    { доля заливки столбика и его цвет — по фазе }
    case St.Phase of
      wpDone:     FillW := CellW;
      wpHarvest:  FillW := CellW * Max(0, Min(100, St.HPct)) / 100.0;
      wpGenDone:  FillW := CellW;
      wpGen:      if St.Stage <> '' then
                    FillW := CellW * Max(0, Min(100, St.Pct)) / 100.0
                  else FillW := 0;
    else
      FillW := 0;
    end;
    if FillW > 0 then
    begin
      if St.Phase in [wpHarvest, wpDone] then
        { harvest — ЗЕЛЁНЫЙ }
        DrawRectangle(DevRect(CellL, CellB, FillW, BarH),
          Vector4(0.15, 0.85, 0.25, 0.55))
      else
        { генерация/загрузка тайла — ЖЁЛТЫЙ }
        DrawRectangle(DevRect(CellL, CellB, FillW, BarH),
          Vector4(1.0, 0.72, 0.15, 0.55));
    end;
  end;

  if FPointStart and (Length(FRouteMerc) = 1) then
  begin
    A := MercToLocal(FRouteMerc[0], Panel);
    DrawRectangle(DevRect(A.X - 6, A.Y - 6, 12, 12), Vector4(0,0,0,0.7));
    DrawRectangle(DevRect(A.X - 4, A.Y - 4, 8, 8), Vector4(1,0.3,0.15,1));
  end;

  { Линия маршрута. Во время фазы притягивания уже ОБРАБОТАННЫЙ префикс
    [0..FSnapFront] перекрашен в зелёный, остаток — красный, на стыке —
    яркая «голова» фронтира: видно, как снап ползёт по маршруту. }
  if Length(FRouteMerc) >= 2 then
  begin
    SetLength(Pts, Length(FRouteMerc));
    for I := 0 to High(FRouteMerc) do
    begin
      A := MercToLocal(FRouteMerc[I], Panel);
      Pts[I] := Vector2(RR.Left + A.X * SX, RR.Bottom + A.Y * SY);
    end;
    if (FSnapFront > 0) and (FSnapFront <= High(FRouteMerc)) then
    begin
      { префикс: обработано — зелёный (стыковая точка входит в оба куска) }
      DrawPrimitive2D(pmLineStrip, Copy(Pts, 0, FSnapFront + 1),
        Vector4(0.20, 0.90, 0.40, 0.95));
      if FSnapFront < High(FRouteMerc) then
        DrawPrimitive2D(pmLineStrip,
          Copy(Pts, FSnapFront, Length(Pts) - FSnapFront),
          Vector4(0.95, 0.20, 0.15, 0.9));
      { второй проход со сдвигом — толщина }
      for I := 0 to High(Pts) do
        Pts[I] := Vector2(Pts[I].X, Pts[I].Y + 1);
      DrawPrimitive2D(pmLineStrip, Copy(Pts, 0, FSnapFront + 1),
        Vector4(0.20, 0.90, 0.40, 0.95));
      if FSnapFront < High(FRouteMerc) then
        DrawPrimitive2D(pmLineStrip,
          Copy(Pts, FSnapFront, Length(Pts) - FSnapFront),
          Vector4(0.95, 0.20, 0.15, 0.9));
      { голова фронтира: яркий квадрат 7x7 px на стыке }
      DrawRectangle(FloatRectangle(
        Pts[FSnapFront].X - 3.5, Pts[FSnapFront].Y - 4.5, 7, 7),
        Vector4(0.75, 1.0, 0.85, 1.0));
    end
    else
    begin
      DrawPrimitive2D(pmLineStrip, Pts, Vector4(0.95, 0.20, 0.15, 0.9));
      { второй проход со сдвигом в 1px — «толщина» без параметра LineWidth }
      for I := 0 to High(Pts) do
        Pts[I] := Vector2(Pts[I].X, Pts[I].Y + 1);
      DrawPrimitive2D(pmLineStrip, Pts, Vector4(0.95, 0.20, 0.15, 0.9));
    end;
  end;

  { ── маркеры списка этапов (текст строк — дочерние TCastleLabel) ── }
  for I := 0 to WARMUP_STAGE_COUNT - 1 do
  begin
    if StageRow(I) < 0 then Continue;
    { левый край и вертикальный центр строки i (локальные координаты);
      привязка к верху контрола — как у лейблов строк в конструкторе }
    MkX  := WARMUP_MARGIN + 2;
    MkCY := EffectiveHeight - (WARMUP_HEADER_H + WARMUP_STAGE_TOP +
            StageRow(I) * WARMUP_STAGE_ROW_H + WARMUP_STAGE_ROW_H * 0.5);
    case FStages[I].State of
      wssPending:
        { тусклый серый квадрат }
        DrawRectangle(DevRect(MkX, MkCY - 5, 10, 10),
          Vector4(0.55, 0.55, 0.55, 0.30));
      wssActive:
        begin
          { жёлтый квадрат с пульсом яркости }
          P := 0.5 + 0.5 * Sin(FStagePulse * 5.0);
          DrawRectangle(DevRect(MkX, MkCY - 5, 10, 10),
            Vector4(1.0, 0.72, 0.15, 0.45 + 0.55 * P));
        end;
      wssDone:
        begin
          { зелёная галочка — два отрезка; второй проход со сдвигом в 1px
            даёт толщину (как у линии маршрута выше) }
          Mks[0] := Vector2(RR.Left + (MkX + 1) * SX, RR.Bottom + (MkCY - 1) * SY);
          Mks[1] := Vector2(RR.Left + (MkX + 4) * SX, RR.Bottom + (MkCY - 5) * SY);
          Mks[2] := Mks[1];
          Mks[3] := Vector2(RR.Left + (MkX + 9) * SX, RR.Bottom + (MkCY + 4) * SY);
          DrawPrimitive2D(pmLines, Mks, Vector4(0.15, 0.85, 0.25, 0.95));
          for J := 0 to 3 do
            Mks[J] := Vector2(Mks[J].X + 1, Mks[J].Y);
          DrawPrimitive2D(pmLines, Mks, Vector4(0.15, 0.85, 0.25, 0.95));
        end;
      wssError:
        begin
          { красный крест — две диагонали, два прохода для толщины }
          Mks[0] := Vector2(RR.Left + MkX * SX,        RR.Bottom + (MkCY - 5) * SY);
          Mks[1] := Vector2(RR.Left + (MkX + 10) * SX, RR.Bottom + (MkCY + 5) * SY);
          Mks[2] := Vector2(RR.Left + MkX * SX,        RR.Bottom + (MkCY + 5) * SY);
          Mks[3] := Vector2(RR.Left + (MkX + 10) * SX, RR.Bottom + (MkCY - 5) * SY);
          DrawPrimitive2D(pmLines, Mks, Vector4(0.95, 0.20, 0.15, 0.95));
          for J := 0 to 3 do
            Mks[J] := Vector2(Mks[J].X + 1, Mks[J].Y);
          DrawPrimitive2D(pmLines, Mks, Vector4(0.95, 0.20, 0.15, 0.95));
        end;
    end;
  end;

  { ── красная плашка ошибки поверх карты (внизу по центру; карту,
    маршрут и список этапов не скрывает) ── }
  if (FErrorMsg <> '') and (FErrorLabel <> nil) and FErrorLabel.Exists then
  begin
    EW := FErrorLabel.EffectiveWidth + 24;
    EH := FErrorLabel.EffectiveHeight + 16;
    if EW > EffectiveWidth - WARMUP_MARGIN * 2 then
      EW := EffectiveWidth - WARMUP_MARGIN * 2;
    DrawRectangle(DevRect((EffectiveWidth - EW) * 0.5, 14, EW, EH),
      Vector4(0.75, 0.10, 0.10, 0.78));
  end;
end;

function TOsm3dWarmupOverlay.Press(const Event: TInputPressRelease): Boolean;
begin
  { The host must still be able to open its menu while loading/retrying. }
  if FShowing and Event.IsKey(keyEscape) then Exit(False);
  Result := inherited;
  if FShowing then Result := True;     { навигация под оверлеем заблокирована }
end;

function TOsm3dWarmupOverlay.Release(const Event: TInputPressRelease): Boolean;
begin
  Result := inherited;
  if FShowing then Result := True;
end;

function TOsm3dWarmupOverlay.Motion(const Event: TInputMotion): Boolean;
begin
  Result := inherited;
  if FShowing then Result := True;
end;

end.
