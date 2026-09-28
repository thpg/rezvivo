{ Routes is a menu overlay over the shared globe (or the live ride).
  Selection only reads FIT/GPX and draws its path on the menu globe.
  Route information, estimation and full statistics live in a separate form.
  Full statistics alone creates a streaming session to warm and sample tiles. }
unit GameViewMapEditor;

{$mode objfpc}{$H+}
{$codepage UTF8}

interface

uses
  Classes, SysUtils, fpjson,
  CastleComponentSerialize, CastleUIControls, CastleControls,
  CastleVectors, CastleColors, CastleKeysMouse, GameGlobeMap, GameRideCarousel,
  GameMenuTile, GameMenuTheme, GameRideMenuHeader,
  Osm3dMapUtils,
  Osm3dGeoMath,           { TLatLon, TLocalProjection }
  Osm3dGeoTileGrid,       { TGeoTileGrid, TGeoTileId }
  Osm3dStudioSettings,
  Osm3dStreamingLauncher, { TOsm3dStreamingSession — прогрев тайлов }
  Osm3dStudioLog,         { TFileLogTarget — поле лога osm3d_*.log }
  CastleViewport,         { мини-вьюпорт: тикает карту сессии }
  FitFile,                { TFitFile — лёгкий парсинг для мини-карт ленты }
  RideParamEstimator,     { типы оценки — расчёт по обеим высотам }
  RideEmulator,           { эмуляция прохождения всеми режимами уклона }
  RideFullEmulator, GameOfflineReadiness, GameStreamingRetirement, GameRouteReview;

type
  { Route cards and actions over the menu background; a separate details form. }
  TRoutesPage = class(TCastleUserInterface)
  private
    FGlobe: TGlobeMap; { borrowed from the menu }
    FDetails: TCastleRectangleControl;
    FDetailsPanel: TCastleRectangleControl;
    FDetailsScroll: TCastleScrollView;
    FDetailsColumn: TCastleVerticalGroup;
    FStatus: TCastleLabel;
    FOfflineLabel: TCastleLabel;
    FOfflinePrepareButton:TMenuTile;
    FOfflineTask: TOfflineReadinessTask;
    FOffline: TOfflineReadiness;
    FPrepareOnly: Boolean;
    FOfflinePreparing:Boolean;
    FReviewTask:TRouteReviewTask;
    FReview:TRouteReview;
    FReviewLabel:TCastleLabel;
    FReviewButton,FReviewNextButton:TMenuTile;
    FReviewRequested:Boolean;
    FReviewIndex:Integer;
    FPreparedCenters,FPreparedRide:TRouteLatLonArray;
    FPreparedWidths:TRouteWidthArray;
    FPreparedWays:TRouteWayIdArray;
    FPreparedCacheRoot,FPreparedGenHash:string;
    FWarmSettings,FPreparedSettings:TStudioSettings;
    procedure ClickReview(Sender:TObject);
    procedure ClickReviewNext(Sender:TObject);
    procedure StartReview;
    procedure ShowReview;
    procedure ClearReview;
    procedure CheckOffline(PrepareSources:Boolean=False);
    procedure ClickPrepareOffline(Sender:TObject);
    procedure BeginWarmup(ForOffline:Boolean);
  private
    FRouteArea: TCastleUserInterface;
    FActions: array[0..5] of TMenuTile;
    FHeader: TRideMenuHeader;
    FSearch: TCastleEdit;
    FFilters: array[0..2] of TMenuButton;
    FDistanceFilter: Integer;
    procedure FilterChanged(Sender:TObject);
  private
    FAnalyzedUrl, FLoadedUrl: String;
    procedure LayoutActions;
    function MakeAction(const AName, ATitle, AIcon: String;
      const AColor: TCastleColor; AClick: TNotifyEvent;
      const AWidth, AHeight: Single): TMenuTile;
    procedure ClickDetails(Sender: TObject);
    procedure ClickCloseDetails(Sender: TObject);
    procedure DisplayRoute(const Route: array of TLatLon; const FitView: Boolean);
    procedure LayoutDetails;
  private
    FFitUrl:         String;
    FFileNames:      TStringList;           { имена *.fit/*.gpx в routes }
    FCarousel:      TRideCarousel;
    FThumbQueue:     TStringList;           { файлы, ждущие генерации мини-карты }
    FOnLaunchRide:   TNotifyEvent;          { кнопка «Ехать» → меню }
    FOnStopRide:     TNotifyEvent;          { кнопка «Стоп» → меню (полный teardown) }
    { Панели левой колонки: подложка + контентная группа (высота подложки
      подгоняется под контент — FitPanel). }
    FPnlRoute:      TCastleRectangleControl;  { «Маршрут»: сводка }
    FPnlParams:     TCastleRectangleControl;  { «Настройка расчёта» }
    FPnlAnalysis:   TCastleRectangleControl;  { «Анализ»: оценщик + прогресс }
    FInnerRoute:    TCastleVerticalGroup;
    FInnerParams:   TCastleVerticalGroup;
    FInnerAnalysis: TCastleVerticalGroup;
    FStatsHost:      TCastleVerticalGroup;  { KV-таблица маршрута }
    FLabelEstimate:  TCastleLabel;          { вывод оценщика }
    FLabelProgress:  TCastleLabel;

    { Full-statistics session; its tiny viewport drives Map.Update. }
    FWarmSession: TOsm3dStreamingSession;
    FMiniVp:      TCastleViewport;
    FWarmProj:    TLocalProjection;   { проекция сессии (origin=центроид) }
    { Лог редактора карты → тот же osm3d_*.log, что у стриминга/карты
      (TFileLogTarget сам резолвит DefaultLogFile). События + фризы. }
    FOsmLog:         TFileLogTarget;
    FLastUpdateTick: QWord;           { предыдущий Update — для детектора фризов }
    { Отложенная работа на Update: Start/клики не выполняют тяжёлое
      (Start идёт внутри ProcessViewChanges; из клика незачем морозить
      кадр). Взводится ровно одно из полей. }
    FPendingFitUrl: String;
    FPendingMulti:  Boolean;

    { Сверка высот FIT с поверхностью сгенерированного мира: прогрев
      тайлов ведёт стриминг-сессия (FWarmSession), Update ждёт
      SnappedReady, затем высоты снимаются с тайлов из кэша — те же,
      что у красных сфер FIT-маршрута. }
    FDemPending: Boolean;             { ждём готовности снапа сессии }
    FDemWaitS:   Single;
    FDemRoute:   TRouteLatLonArray;
    { Время старта заезда (UTC) из FIT — уходит в Create warm-сессии
      «Полной статистики», чтобы солнце/тени тайлов пеклись под ТО ЖЕ
      время, что у игровой сессии (та передаёт Fit.RouteStartUTC).
      Раньше здесь было Now → тени прогретых тайлов не совпадали с
      игрой. 0 = в FIT нет таймштампов (солнце не ставится — как игра). }
    FDemStartUTC: TDateTime;
    FDemFitAlt:  array of Single;
    FDemDist:    array of Single;   { одометрия FIT, параллельно маршруту }
    { Для парного расчёта по обеим высотам: копия сэмплов заезда и
      результат/отчёт по FIT-высоте (DEM-прогон случится позже,
      когда доедет регион). }
    FDemSamples: TRideSampleArray;
    { Поточечная раскладка оценщика по FIT-высоте (уклон/классы/тормоза) —
      вход эмуляции прохождения (ComputeDemComparison → EmulateRideModes).
      Валидна только при FFitEstOk. }
    FFitPts: TRidePointResultArray;
    FFitEst:     TRideEstimate;
    FFitEstOk:   Boolean;
    FFitReport:  String;
    FPendingDelay:  Integer;   { кадров до запуска: прогресс-надпись
                                 успевает отрисоваться (Update идёт
                                 раньше Render) }

    { Пакетный режим --fitstats: без участия пользователя открыть FIT,
      прогнать «Полную статистику» (прогрев + снап + сверка + эмуляция),
      сохранить отчёт в <fit>.fullstats.txt рядом с FIT и завершить
      приложение. FBatchStage: 0 — стартовый тик (анализ + запуск
      прогрева), 1 — ждём FFullStatsDone (взводится в Update на месте
      вызова ComputeDemComparison). FBatchWaitS — защитный таймаут. }
    FBatchMode:     Boolean;
    FBatchStage:    Integer;
    FBatchPath:     String;
    FBatchWaitS:    Single;
    FFullStatsDone: Boolean;

    { Панель «Настройка расчёта» левой колонки. Снятая галка
      «авто» у параметра → его значение берётся из слайдера как жёсткая
      константа (в оценщик уходит приором с малой сигмой либо известным
      ветром); галка стоит → параметр оценивается алгоритмом. Выбор
      выборочный: каждый параметр независимо авто/вручную. }
    FParamsHost:   TCastleVerticalGroup;
    FSlMass:       TCastleFloatSlider;
    FSlCdA:        TCastleFloatSlider;
    FSlCrr:        TCastleFloatSlider;
    FSlWindSpd:    TCastleFloatSlider;
    FSlWindDir:    TCastleFloatSlider;
    FLblMass:      TCastleLabel;
    FLblCdA:       TCastleLabel;
    FLblCrr:       TCastleLabel;
    FLblWindSpd:   TCastleLabel;
    FLblWindDir:   TCastleLabel;
    FChkMassAuto:  TCastleCheckbox;
    FChkCdAAuto:   TCastleCheckbox;
    FChkCrrAuto:   TCastleCheckbox;
    FChkWindAuto:  TCastleCheckbox;

    procedure BuildForm;
    procedure RefreshFilesList;
    procedure SetProgress(const AText: String);
    procedure Resize; override;
    procedure AddStatRow(const AKey, AValue: String);
    procedure AddStatHeader(const ACaption: String);
    procedure ClearStats;
    { Записать текст оценки и подогнать высоту прокручиваемой области
      под число строк (иначе TCastleScrollView не знает, что скроллить). }
    procedure SetEstimate(const AText: String);

    { Панель единого стиля: тёмная полупрозрачная подложка + заголовок +
      контентная колонка с отступами (в AInner). Высота подложки
      подгоняется под контент вызовом FitPanel. }
    function  MakePanel(const ACaption: String;
      out AInner: TCastleVerticalGroup): TCastleRectangleControl;
    procedure FitPanel(APanel: TCastleRectangleControl;
      AInner: TCastleUserInterface);
    { Золотая рамка на карточке выбранного маршрута (−1 — снять со всех). }
    procedure SelectCard(AIndex: Integer);

    procedure ClickAddFit(Sender: TObject);
    procedure ClickLibrary(Sender:TObject);
    procedure ClickCreate(Sender:TObject);
    procedure ClickFileRow(Sender: TObject);
    procedure ClickRide(Sender: TObject);
    procedure ClickStopRide(Sender: TObject);
    procedure ClickMultiAnalysis(Sender: TObject);
    function  ThumbCachePath(const AFileName: String): String;
    function  RouteCardInfo(const AFit: TFitFile): String;
    function  RenderRouteThumb(const AFit: TFitFile;
      const APngPath: String): Boolean;
    function  EnsureRouteThumb(const AFileName: String;
      out APngPath, AInfo: String): Boolean;
    procedure ProcessThumbQueue;
    { Полная статистика по кнопке: прогрев тайлов + снап + зелёные сферы +
      сверка поверхности + CSV (простой клик этого не делает). }
    procedure ClickFullStats(Sender: TObject);

    { Пакетный режим: пошаговый драйвер (вызывается из Update в конце,
      после блока FDemPending — флаг FFullStatsDone виден в том же тике)
      и финализация (отчёт на диск + Terminate). AErr <> '' — отчёт об
      ошибке, ExitCode = 2. }
    procedure BatchUpdate(const SecondsPassed: Single);
    procedure BatchFinish(const AErr: String);

    { Панель параметров расчёта: масса/CdA/Crr/ветер (слайдеры) + галки
      «авто» на каждый. ParamsChanged обновляет подписи значений;
      SyncParamEnable гасит слайдер при «авто»; ClickRecompute гоняет
      текущий FIT заново с новым конфигом. }
    procedure BuildParamsPanel(AParent: TCastleVerticalGroup);
    procedure ParamsChanged(Sender: TObject);
    procedure SyncParamEnable;
    { После оценки выставить движки, стоящие на «авто», в посчитанные
      значения (зафиксированные юзером не трогать). }
    procedure UpdateAutoSliders(const AEst: TRideEstimate);
    procedure ClickRecompute(Sender: TObject);

    procedure OpenAndAnalyzeFit(const AFitUrl: String; const Analyze: Boolean = True);
    procedure RunMultiAnalysis;

    { Сверка высот FIT с поверхностью сгенерированного мира вдоль
      маршрута; строки — в статистику, лог — в CSV рядом с FIT. }
    function  BuildEstimatorCfg: TRideEstimatorConfig;
    procedure StreamLog(const Line: String);
    { Запись события редактора в osm3d_*.log (с префиксом [Routes]). }
    procedure LogOsm(const S: String);
    { Колбэк таймингов оценщика мин.колебаний → osm3d_*.log. }
    procedure EstLog(const S: String);
    procedure StopWarmSession;
    { Сверка высот FIT с поверхностью сгенерированного мира (те же
      высоты, что у красных сфер FIT-маршрута) + парный расчёт + CSV. }
    procedure ComputeDemComparison;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Update(const SecondsPassed: Single;
      var HandleInput: Boolean); override;

    { Menu tab lifecycle: refresh cards, cancel pending work when hidden. }
    procedure PageShown;
    procedure PageHidden;

    { Системный путь к FIT, выбранному последним кликом по ленте
      (или '' если ничего не выбрано). Меню читает это для запуска
      заезда — стриминг запускается по этому FIT. }
    function SelectedFitPath: String;
    function ReadyToRide:Boolean;
    procedure OpenLibraryFile(const FileName:String);
    procedure ImportFile(const FileName:String);
    function CloseDetails: Boolean;
    function DetailsVisible: Boolean;
    function Diagnostics: TJSONObject;
    property Globe: TGlobeMap read FGlobe write FGlobe;

    { Пакетный режим (--fitstats=<путь>): меню запускает его сразу после
      открытия страницы «Маршруты» — страница сама анализирует FIT,
      жмёт «Полную статистику», пишет отчёт и завершает приложение. }
    procedure StartBatchFullStats(const AFitPath: String);
    property BatchMode: Boolean read FBatchMode;
    { Кнопка «Ехать» на странице: меню подставляет запуск заезда
      (TViewMenu.LaunchSelectedRide). }
    property OnLaunchRide: TNotifyEvent read FOnLaunchRide write FOnLaunchRide;
    { Кнопка «Стоп» на странице: меню подставляет полное завершение заезда
      (TViewMenu.StopSelectedRide). }
    property OnStopRide: TNotifyEvent read FOnStopRide write FOnStopRide;
  end;

  { Заглушка бывшего полноэкранного вью — сохраняет компиляцию
    gameinitialize. Не используется. }
  TViewMapEditor = class(TCastleView)
  end;

{ Папка маршрутов залогиненного пользователя:
  [exe]/users/<ник>/routes/ (создаётся при необходимости).
  Без авторизации — users/guest/routes/. }
function UserRoutesDir: String;

{ Путь FIT из параметра командной строки --fitstats=<путь> ('' если
  параметра нет). Разбор ленивый и однократный. }
function BatchFitStatsPath: String;

var
  ViewMapEditor: TViewMapEditor;

implementation

uses UiTranslations,
  Math,
  CastleURIUtils, CastleWindow,
  CastleImages,             { TRGBAlphaImage, SaveImage — мини-карты ленты }
  Osm3dGeoTileCache,      { TGeoTileCache — чтение тайлов прогрева с диска }
  Osm3dFitCorrection,     { TFitCorrection — съём высот после коррекции }
  Osm3dFitHeightLayer,    { TFitHeightLayer — физический слой (поправка к земле) }
  Osm3dTileX3D,           { TTileModel — меши тайла }
  Osm3dGeomMesh,          { TMesh, TMeshVertexArray — вершины тайла }
  Osm3dSceneMaterials,    { TSceneMaterialKind (smk*) — фильтр ground-мешей }
  Osm3dStreamingMap,      { методы карты сессии (BeginRouteSnap и др.) }
  GpxFile,               { NewRouteParserForFile: .fit/.gpx по расширению }
  VeloSiteAPI, DebugLog, GameRouteLibraryData, GameViewMenu, GameViewPlay, AppSettings, GameUserData;

type
  TRouteDetailsBackdrop = class(TCastleRectangleControl)
    function Press(const Event: TInputPressRelease): Boolean; override;
    function Motion(const Event: TInputMotion): Boolean; override;
  end;

function TRouteDetailsBackdrop.Press(const Event: TInputPressRelease): Boolean;
begin
  inherited;
  Result := not Event.IsKey(keyEscape);
end;

function TRouteDetailsBackdrop.Motion(const Event: TInputMotion): Boolean;
begin inherited; Result := True; end;

const
  FREEZE_MS = 150;   { порог детектора фризов: разрыв кадра Update ≥ этого → лог }

  { Раскладка страницы: лента карточек от верхнего края, под ней —
    ряд действий, ниже — левая колонка панелей и большая карта справа. }
  BUTTONS_TOP = 8;
  BUTTONS_H = 72;
  CONTENT_TOP = BUTTONS_TOP + BUTTONS_H + 10;   { верх колонки панелей и карты }
  PANEL_W = 560;       { ширина панелей левой колонки }
  PANEL_PAD = 10;      { внутренние отступы панели }
  THUMB_W = 480;       { растр мини-карты (в 2 раза крупнее показа — }
  THUMB_H = 240;       {   чёткость на HiDPI), показ 236×120 }
  THUMB_MAX_PTS = 1500;{ прореживание трека для мини-карты }

{ ── Папка пользователя ─────────────────────────────────────────────── }

function SanitizeFolderName(const AName: String): String;
const
  Forbidden = '/\:*?"<>| ';
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(AName) do
    if Pos(AName[I], Forbidden) > 0 then
      Result := Result + '_'
    else
      Result := Result + AName[I];
  if Result = '' then Result := 'guest';
end;

function UserRoutesDir: String;
var
  Nick: String;
begin
  if(GetEnvironmentVariable('REZVIVO_TEST_AUTH_FILE')<>'')and(GetEnvironmentVariable('REZVIVO_TEST_ACCOUNT_DIR')<>'')then begin
    Result:=IncludeTrailingPathDelimiter(GetEnvironmentVariable('REZVIVO_TEST_ACCOUNT_DIR'))+'routes'+PathDelim;ForceDirectories(Result);Exit;
  end;
  Nick := 'guest';
  if VeloSite.IsAuthorized and VeloSite.HasCachedProfile and
     (VeloSite.CachedProfile.Nickname <> '') then
    Nick := SanitizeFolderName(VeloSite.CachedProfile.Nickname);
  Result := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)))
    + 'users' + PathDelim + Nick + PathDelim + 'routes' + PathDelim;
  if not ForceDirectories(Result) then
    Logger.Info('[Routes] Не удалось создать папку: ' + Result);
end;

{ Побайтовое копирование файла. }
procedure CopyFileBinary(const ASrc, ADst: String);
var
  Src, Dst: TFileStream;
begin
  Src := TFileStream.Create(ASrc, fmOpenRead or fmShareDenyWrite);
  try
    Dst := TFileStream.Create(ADst, fmCreate);
    try
      Dst.CopyFrom(Src, 0);
    finally
      Dst.Free;
    end;
  finally
    Src.Free;
  end;
end;

constructor TRoutesPage.Create(AOwner: TComponent);
begin
  inherited;
  FullSize := True;   { заполняем область, выданную меню (FPageHost) }

  FFitUrl := '';
  FPendingFitUrl := '';
  FPendingMulti := False;
  FPendingDelay := 0;
  FFileNames := TStringList.Create;
  FFileNames.Sorted := True;
  FThumbQueue := TStringList.Create;
  FOnLaunchRide := nil;
  FOnStopRide := nil;

  BuildForm;

  FWarmSession := nil;
  FMiniVp := nil;
  FWarmProj := nil;

  { Лог редактора в общий osm3d_*.log (пустой путь → DefaultLogFile —
    тот же файл сессии стриминга). }
  FOsmLog := TFileLogTarget.Create('');
  FLastUpdateTick := 0;

  FBatchMode := False;
  FBatchStage := 0;
  FBatchPath := '';
  FBatchWaitS := 0;
  FFullStatsDone := False;
  LogOsm('=== редактор карт открыт ===');
end;

destructor TRoutesPage.Destroy;
begin
  ClearReview;
  if FOfflineTask<>nil then begin FOfflineTask.Abandon;FOfflineTask:=nil end;
  StopWarmSession;
  FreeAndNil(FFileNames);
  FreeAndNil(FThumbQueue);
  if FOsmLog <> nil then
    LogOsm('=== редактор карт закрыт ===');
  FreeAndNil(FOsmLog);
  inherited;
end;

procedure TRoutesPage.LogOsm(const S: String);
begin
  { В общий osm3d_*.log (main-thread; TFileRawAppend под глобальным локом). }
  if FOsmLog <> nil then
    FOsmLog.Write(Osm3dStudioLog.llInfo, '[Routes] ' + S);
end;

procedure TRoutesPage.EstLog(const S: String);
begin
  LogOsm('оценка: ' + S);
end;

procedure TRoutesPage.StreamLog(const Line: String);
begin
  { Прогрев тайлов сессии — в тот же osm3d_*.log, что и остальной стриминг. }
  LogOsm('warm: ' + Line);
end;

{ Полная остановка прогрева: оверлей из UI, карта из мини-вьюпорта,
  сессия (штатно гасит своих воркеров — как при выходе из заезда). }
procedure TRoutesPage.StopWarmSession;
begin
  FDemPending := False;
  if FWarmSession <> nil then
  begin
    if FMiniVp <> nil then
      FMiniVp.Items.Remove(FWarmSession.Map);
    RetireStreamingSession(FWarmSession);
  end;
  FreeAndNil(FWarmProj);
end;

procedure TRoutesPage.PageShown;
begin
  FLastUpdateTick := 0;   { первый кадр после показа не считаем фризом }
  LogOsm('страница показана');
  RefreshFilesList;
  LayoutActions;
  FHeader.SetRideState(ViewMenu.RideUnderneath,
    SameFileName(SelectedFitPath,ViewPlay.CurrentFitPath));
  if(FFitUrl='')or not FileExists(SelectedFitPath)then begin
    FFitUrl:='';FLoadedUrl:='';
    FHeader.SetSelection(UiText('Choose a route'),UiText('Click a card to select a ride'),False);
  end;
  if FGlobe <> nil then FGlobe.FitArea := FRouteArea;
  if (FFitUrl <> '') and (FLoadedUrl <> FFitUrl) then
  begin
    FPendingFitUrl := FFitUrl;
    FPendingDelay := 2;
  end else if(FFitUrl<>'')and(FOfflineTask=nil)then CheckOffline;
end;

procedure TRoutesPage.PageHidden;
begin
  if FOfflineTask<>nil then begin FOfflineTask.Abandon;FOfflineTask:=nil end;
  CloseDetails;
  FCarousel.CancelGesture;
  if FGlobe <> nil then FGlobe.FitArea := nil;
  FPendingFitUrl := '';
  FPendingMulti := False;
  StopWarmSession;
end;

function TRoutesPage.ReadyToRide:Boolean;
begin
  { Selection readiness only; never use this as an offline-coverage claim. }
  Result:=FHeader.StartButton.Enabled and(FFitUrl<>'')and
    (FLoadedUrl=FFitUrl)and(FPendingFitUrl='');
end;

function TRoutesPage.SelectedFitPath: String;
begin
  { Системный путь выбранного FIT — для запуска заезда из меню. FFitUrl
    ставится синхронно в ClickFileRow / ClickAddFit / OpenAndAnalyzeFit. }
  if FFitUrl = '' then
    Result := ''
  else
    Result := URIToFilenameSafe(FFitUrl);
end;

procedure TRoutesPage.Update(const SecondsPassed: Single;
  var HandleInput: Boolean);
var
  Url: String;
  Tk, Dt: QWord;
begin
  inherited;
  if FReviewTask<>nil then begin
    FReview:=FReviewTask.Snapshot;FReviewLabel.Caption:=FReview.Caption;
    if FReview.Done then begin
      FreeAndNil(FReviewTask);FReviewRequested:=False;
      if FReview.ErrorText=''then FReviewButton.SetTitle(UiText('Show route comparison'))
      else FReviewButton.SetTitle(UiText('Check route geometry'));
      FReviewNextButton.Exists:=FReview.ConcernPoints>0;
      if FReview.ErrorText=''then ShowReview;
    end;
  end;
  if FOfflineTask<>nil then begin
    FOffline:=FOfflineTask.Snapshot;
    FOfflineLabel.Caption:=FOffline.Caption;
    if not FDemPending and(FPendingFitUrl='')and(FLabelProgress.Caption='')then
      FStatus.Caption:=FOffline.Caption;
    if FOffline.Done then begin
      FreeAndNil(FOfflineTask);
      if FOfflinePreparing and(FOffline.ErrorText='')and
        (FOffline.ReadyOsm=FOffline.Osm)and(FOffline.ReadyHeights=FOffline.Heights)and
        (FOffline.ReadyTiles<FOffline.Tiles)then BeginWarmup(True);
      FOfflinePreparing:=False;
      if FWarmSession=nil then FOfflinePrepareButton.SetTitle(UiText('Prepare for offline ride'));
    end;
  end;
  { Детектор фризов: разрыв между кадрами Update. Норма ~16 мс; большой
    разрыв = главный поток был заблокирован тяжёлой операцией редактора
    (загрузка/парсинг FIT, создание сессии, генерация/чтение тайлов,
    GL-загрузка растра). Пишем в osm3d_*.log рядом с событиями — видно,
    ЧТО фризило. Первый кадр после показа страницы пропускаем
    (FLastUpdateTick=0 после PageShown — иначе время «скрытости» = ложный фриз). }
  Tk := GetTickCount64;
  if FLastUpdateTick > 0 then
  begin
    Dt := Tk - FLastUpdateTick;
    if Dt >= FREEZE_MS then
      LogOsm(Format('ФРИЗ главного потока: %d мс', [Dt]));
  end;
  FLastUpdateTick := Tk;

  { Мини-карты ленты: один файл за тик — парсинг FIT по одному не
    морозит кадр ощутимо, пачкой — морозил бы. }
  ProcessThumbQueue;
  if DetailsVisible then LayoutDetails;

  if (FPendingFitUrl <> '') or FPendingMulti then
  begin
    Dec(FPendingDelay);
    if FPendingDelay > 0 then Exit;
    if FPendingFitUrl <> '' then
    begin
      Url := FPendingFitUrl;
      FPendingFitUrl := '';   { одноразово, до вызова }
      try
        OpenAndAnalyzeFit(Url, DetailsVisible);
      except on E:Exception do begin
        FLoadedUrl:='';FHeader.StartButton.Enabled:=False;DisplayRoute([],False);
        SetProgress(UiText('Could not read the route file.')+' '+E.Message);
      end;end;
    end
    else
    begin
      FPendingMulti := False;
      RunMultiAnalysis;
    end;
  end;

  { Ожидание прогрева: снап-воркер сессии генерит тайлы маршрута на
    диск; SnappedReady = всё готово (паттерн TGameOsmStreaming). }
  if FDemPending and (FWarmSession <> nil) then
  begin
    FDemWaitS := FDemWaitS + SecondsPassed;
    if FWarmSession.Map.SnappedReady and
       (Length(FWarmSession.Map.SnappedRoute) >= 2) then
    begin
      FDemPending := False;
      FPreparedCenters:=Copy(FWarmSession.Map.SnappedRouteCenters);
      FPreparedRide:=Copy(FWarmSession.Map.RideRoute);
      FPreparedWidths:=Copy(FWarmSession.Map.SnappedRouteWidths);
      FPreparedWays:=Copy(FWarmSession.Map.SnappedRouteWays);
      FPreparedCacheRoot:=FWarmSession.CacheRoot;FPreparedGenHash:=FWarmSession.GenHash;
      FPreparedSettings:=FWarmSettings;
      if FReviewRequested then StartReview;
      LogOsm(Format('снап готов за %.1f с — начинаю сверку высот (загрузка тайлов)',
        [FDemWaitS]));
      if not FPrepareOnly then begin
        SetProgress(UiText('Sampling surface elevations…'));
        Tk := GetTickCount64;
        ComputeDemComparison;
        FFullStatsDone := True;
        LogOsm(Format('ComputeDemComparison: %d ms',[GetTickCount64-Tk]));
      end;
      { Results are plain text/data now. No preview needs to keep the world
        alive and build debug meshes after the calculation has finished. }
      StopWarmSession;
      SetProgress('');
      CheckOffline;
    end
    else if FWarmSession.Map.RoutePrepDone then begin
      StopWarmSession;
      SetProgress(UiText('Route preparation ended with missing data. Check the offline status.'));
      CheckOffline;
    end
    else if FDemWaitS > 900.0 then
    begin
      StopWarmSession;   { гасит и FDemPending, снимает оверлей }
      LogOsm('прогрев не завершился за 15 минут — сверка пропущена');
      SetProgress(UiText('Preloading exceeded 15 minutes; elevation comparison skipped.'));
    end;
  end;

  { Пакетный режим --fitstats: в самом конце Update — флаг
    FFullStatsDone, взведённый выше, виден уже в этом тике. }
  BatchUpdate(SecondsPassed);
end;

{ ── Форма: шапка, лента карточек, левая колонка панелей ────────────── }

procedure TRoutesPage.BuildForm;
var
  Col: TCastleVerticalGroup;
  Row: TCastleHorizontalGroup;
  Btn: TMenuTile;
  I: Integer;
begin
  { The wheel is placed beside the globe by LayoutActions. }
  FCarousel:=TRideCarousel.Create(Self);
  FCarousel.Name:='RouteCarousel';
  FCarousel.OnChange:=@ClickFileRow;InsertFront(FCarousel);

  { Ряд действий — сверху. «Ехать» — запуск заезда по выбранному
    маршруту (без выбора — дефолтный мир). Само переключение вью делает
    меню (OnLaunchRide). }
  FHeader := TRideMenuHeader.Create(Self);FHeader.Anchor(vpTop);InsertFront(FHeader);
  FHeader.StartButton.OnClick:=@ClickRide;
  FHeader.SetSelection(UiText('Choose a route'),UiText('Click a card to select a ride'),False);
  FSearch:=TMenuEdit.Create(Self);FSearch.Name:='RouteSearch';
  FSearch.Text:='';BindUiText(FSearch,'Search routes','Placeholder');FSearch.OnChange:=@FilterChanged;InsertFront(FSearch);
  for I:=0 to High(FFilters)do begin
    FFilters[I]:=TMenuButton.Create(Self);FFilters[I].AutoIcon:=False;
    FFilters[I].AutoSize:=False;FFilters[I].Tag:=I;
    FFilters[I].Name:='RouteDistanceFilter'+IntToStr(I);
    FFilters[I].OnClick:=@FilterChanged;InsertFront(FFilters[I]);
  end;
  BindUiText(FFilters[0],'All distances');BindUiText(FFilters[1],'Up to 25 km');BindUiText(FFilters[2],'Over 25 km');
  SelectMenuButton(FFilters[0],True);
  FActions[2] := MakeAction('RouteAddButton', UiText('Import FIT / GPX'), 'import',
    Vector4(0.36, 0.52, 0.78, 0.85), @ClickAddFit, 196, BUTTONS_H);
  FActions[3] := MakeAction('RouteCreateButton', UiText('Create'), 'create',
    Vector4(0.30, 0.58, 0.68, 0.85), @ClickCreate, 196, BUTTONS_H);
  FActions[4] := MakeAction('RouteLibraryButton', UiText('Online routes'), 'library',
    Vector4(0.56, 0.52, 0.78, 0.85), @ClickLibrary, 196, BUTTONS_H);
  FActions[5] := MakeAction('RouteDetailsButton', UiText('Route details'), 'details',
    Vector4(0.72, 0.64, 0.38, 0.85), @ClickDetails, 196, BUTTONS_H);
  for Btn in FActions do if Btn<>nil then InsertFront(Btn);

  FStatus := TMenuLabel.Create(Self);
  FStatus.FontSize := 16;
  FStatus.Color := White;
  FStatus.Anchor(hpLeft, 8);
  FStatus.Anchor(vpTop, -CONTENT_TOP);
  InsertFront(FStatus);

  FRouteArea := TCastleUserInterface.Create(Self);
  FRouteArea.FullSize := True;
  FRouteArea.CapturesEvents := False;
  FRouteArea.Border.Top := CONTENT_TOP + 36;
  FRouteArea.Border.Bottom := 24;
  InsertBack(FRouteArea);

  FDetails := TRouteDetailsBackdrop.Create(Self);
  FDetails.Name := 'RouteDetailsForm';
  FDetails.FullSize := True;
  FDetails.Color := Vector4(0, 0, 0, 0.35);
  FDetails.Exists := False;
  InsertFront(FDetails);

  FDetailsPanel := TCastleRectangleControl.Create(Self);
  FDetailsPanel.Width := PANEL_W + 32;
  FDetailsPanel.HeightFraction := 1;
  FDetailsPanel.Anchor(hpMiddle);
  FDetailsPanel.Color := Vector4(0.07, 0.10, 0.15, 0.97);
  FDetails.InsertFront(FDetailsPanel);

  Row := TCastleHorizontalGroup.Create(Self);
  Row.Spacing := 8;
  Row.Anchor(hpLeft, 12);
  Row.Anchor(vpTop, -12);
  FDetailsPanel.InsertFront(Row);
  Btn := MakeAction('RouteFullStatsButton', UiText('Full') + LineEnding + UiText('statistics'),
    'statistics', Vector4(0.36, 0.52, 0.78, 0.85), @ClickFullStats, 184, 64);
  Row.InsertFront(Btn);
  Btn := MakeAction('RouteMultiAnalysisButton', UiText('Combined') + LineEnding + UiText('analysis'),
    'analysis', Vector4(0.56, 0.52, 0.78, 0.85), @ClickMultiAnalysis, 184, 64);
  Row.InsertFront(Btn);
  Btn := MakeAction('CloseRouteDetails', UiText('Close'), 'close',
    Vector4(0.37, 0.43, 0.52, 0.85), @ClickCloseDetails, 184, 64);
  Row.InsertFront(Btn);

  FDetailsScroll := TMenuScrollView.Create(Self);
  FDetailsScroll.FullSize := True;
  FDetailsScroll.Border.Top := 88;
  FDetailsScroll.Border.Bottom := 8;
  FDetailsScroll.Border.Left := 8;
  FDetailsScroll.Border.Right := 8;
  FDetailsPanel.InsertFront(FDetailsScroll);
  Col := TCastleVerticalGroup.Create(Self);
  Col.Spacing := 10;
  Col.Anchor(hpLeft, 4);
  Col.Anchor(vpTop, -4);
  FDetailsScroll.ScrollArea.InsertFront(Col);
  FDetailsColumn := Col;

  FOfflineLabel:=TMenuLabel.Create(Self);
  FOfflineLabel.FontSize:=15;
  FOfflineLabel.MaxWidth:=PANEL_W-24;
  Col.InsertFront(FOfflineLabel);
  Btn:=MakeAction('PrepareOfflineRoute',UiText('Prepare for offline ride'),
    'statistics',Vector4(0.36,0.52,0.78,0.85),@ClickPrepareOffline,280,52);
  Col.InsertFront(Btn);
  FOfflinePrepareButton:=Btn;

  FReviewLabel:=TMenuLabel.Create(Self);FReviewLabel.FontSize:=15;
  FReviewLabel.MaxWidth:=PANEL_W-24;Col.InsertFront(FReviewLabel);
  FReviewButton:=MakeAction('ReviewPreparedRoute',UiText('Check route geometry'),
    'analysis',Vector4(0.36,0.52,0.78,0.85),@ClickReview,280,52);
  Col.InsertFront(FReviewButton);
  FReviewNextButton:=MakeAction('NextRouteWarning',UiText('Next route warning'),
    'details',Vector4(0.63,0.45,0.22,0.85),@ClickReviewNext,280,52);
  FReviewNextButton.Exists:=False;Col.InsertFront(FReviewNextButton);

  { Панель «Маршрут»: сводка выбранного маршрута (KV-таблица). }
  FPnlRoute := MakePanel(UiText('Route'), FInnerRoute);
  Col.InsertFront(FPnlRoute);
  FStatsHost := TCastleVerticalGroup.Create(Self);
  FStatsHost.Spacing := 4;
  FInnerRoute.InsertFront(FStatsHost);
  FitPanel(FPnlRoute, FInnerRoute);

  { Панель «Настройка расчёта»: масса, CdA, Crr, ветер (сила+направление)
    со слайдерами и галками «авто». Поведение не менялось. }
  FPnlParams := MakePanel(UiText('Calculation settings'), FInnerParams);
  Col.InsertFront(FPnlParams);
  BuildParamsPanel(FInnerParams);
  FitPanel(FPnlParams, FInnerParams);

  { Панель «Анализ»: вывод оценщика в прокручиваемой области (совместный
    анализ по двум десяткам маршрутов даёт длинный список Crr) + строка
    прогресса. Высота скролла — остаточная, подгоняется в Resize. }
  FPnlAnalysis := MakePanel(UiText('Analysis'), FInnerAnalysis);
  Col.InsertFront(FPnlAnalysis);

  FLabelEstimate := TMenuLabel.Create(Self);
  FLabelEstimate.Caption  := '';
  FLabelEstimate.Color    := Vector4(0.80, 0.86, 0.92, 1);
  FLabelEstimate.FontSize := 15;
  FLabelEstimate.MaxWidth := PANEL_W - 2 * PANEL_PAD - 24;
  FInnerAnalysis.InsertFront(FLabelEstimate);

  FLabelProgress := TMenuLabel.Create(Self);
  FLabelProgress.Caption  := '';
  FLabelProgress.Color    := Vector4(1.0, 0.85, 0.3, 1);
  FLabelProgress.FontSize := 17;
  FInnerAnalysis.InsertFront(FLabelProgress);
  FitPanel(FPnlAnalysis, FInnerAnalysis);
  LayoutActions;
end;

function TRoutesPage.MakeAction(const AName, ATitle, AIcon: String;
  const AColor: TCastleColor; AClick: TNotifyEvent;
  const AWidth, AHeight: Single): TMenuTile;
begin
  Result := TMenuTile.Create(Self);
  Result.Name := AName;
  Result.SetTileSize(AWidth, AHeight);
  Result.SetTitle(ATitle);
  Result.SetTitleFontScale(0.8);
  Result.SetBaseColor(AColor);
  Result.SetIconUrl('castle-data:/menu/icons/routes/' + AIcon + '.png');
  Result.OnTileClick := AClick;
end;

procedure TRoutesPage.LayoutActions;
var
  TileWidth, ContentTop, Scale, WheelWidth, RowTop, FilterW: Single;
  I: Integer;
begin
  if (FActions[High(FActions)] = nil) or (EffectiveWidth <= 0) then Exit;
  Scale := Min(1, Max(0.65, UIScale));
  RowTop:=94/Scale;
  TileWidth:=Min(210/Scale,(EffectiveWidth-40)/4);
  for I := 2 to High(FActions) do
  begin
    FActions[I].SetTileSize(TileWidth, 38/Scale);
    FActions[I].SetTitleFontScale(0.8 / Scale);
    FActions[I].Anchor(hpLeft, 8 + (I-2)*(TileWidth+8));
    FActions[I].Anchor(vpTop, -RowTop);
  end;
  RowTop:=140/Scale;ContentTop:=184/Scale;
  WheelWidth:=Min(EffectiveWidth*0.32,350/Scale);
  FSearch.Width:=WheelWidth-8;FSearch.Height:=34/Scale;FSearch.FontSize:=15/Scale;
  FSearch.Anchor(hpLeft,8);FSearch.Anchor(vpTop,-RowTop);
  FilterW:=Min(130/Scale,(EffectiveWidth-WheelWidth-40)/3);
  for I:=0 to High(FFilters)do begin
    FFilters[I].Width:=FilterW;FFilters[I].Height:=34/Scale;FFilters[I].FontSize:=13/Scale;
    FFilters[I].Anchor(hpLeft,WheelWidth+24+I*(FilterW+6));FFilters[I].Anchor(vpTop,-RowTop);
  end;
  if FCarousel <> nil then
  begin
    FCarousel.Width := WheelWidth;
    FCarousel.Height := Max(120, EffectiveHeight - ContentTop - 16);
    FCarousel.Anchor(hpLeft, 8);
    FCarousel.Anchor(vpTop, -ContentTop);
  end;
  if FStatus <> nil then
  begin
    FStatus.Anchor(hpLeft, WheelWidth + 24);
    FStatus.Anchor(vpTop, -ContentTop);
    FStatus.MaxWidth := Max(100, EffectiveWidth - WheelWidth - 40);
  end;
  if FRouteArea <> nil then
  begin
    FRouteArea.Border.Left := WheelWidth + 24;
    FRouteArea.Border.Top := ContentTop + 36;
    if Exists and(FGlobe<>nil)and(Parent<>nil)then begin
      FGlobe.Border.Left:=Parent.Border.Left+FRouteArea.Border.Left;
      FGlobe.Border.Top:=Parent.Border.Top+ContentTop;
      FGlobe.Border.Right:=16;
      FGlobe.Border.Bottom:=Parent.Border.Bottom+24;
    end;
  end;
end;

procedure TRoutesPage.FilterChanged(Sender:TObject);
var I:Integer;
begin
  if Sender is TMenuButton then FDistanceFilter:=(Sender as TMenuButton).Tag;
  FCarousel.SetFilter(FSearch.Text,FDistanceFilter);
  for I:=0 to High(FFilters)do SelectMenuButton(FFilters[I],I=FDistanceFilter);
end;

function TRoutesPage.MakePanel(const ACaption: String;
  out AInner: TCastleVerticalGroup): TCastleRectangleControl;
var
  Hdr: TCastleLabel;
begin
  Result := TCastleRectangleControl.Create(Self);
  Result.Color := Vector4(0.17, 0.21, 0.28, 0.80);
  Result.AutoSizeToChildren := False;
  Result.Width := PANEL_W;
  Result.Height := 40;   { FitPanel пересчитает под контент }

  AInner := TCastleVerticalGroup.Create(Self);
  AInner.Spacing := 4;
  AInner.Anchor(hpLeft, PANEL_PAD);
  AInner.Anchor(vpTop, -PANEL_PAD);
  Result.InsertFront(AInner);

  Hdr := TMenuLabel.Create(Self);
  BindUiText(Hdr, ACaption);
  Hdr.Color    := Vector4(0.55, 0.60, 0.66, 1);
  Hdr.FontSize := 15;
  AInner.InsertFront(Hdr);
end;

procedure TRoutesPage.FitPanel(APanel: TCastleRectangleControl;
  AInner: TCastleUserInterface);
begin
  if (APanel = nil) or (AInner = nil) then Exit;
  APanel.Height := AInner.EffectiveHeight + 2 * PANEL_PAD;
end;

procedure TRoutesPage.SelectCard(AIndex: Integer);
begin FCarousel.Select(AIndex);end;

procedure TRoutesPage.ClickRide(Sender: TObject);
begin
  if not FHeader.StartButton.Enabled or (FFitUrl='') or
    (FLoadedUrl<>FFitUrl) or (FPendingFitUrl<>'') then Exit;
  if Assigned(FOnLaunchRide) then
    FOnLaunchRide(Self);
end;

procedure TRoutesPage.ClickStopRide(Sender: TObject);
begin
  { Полное завершение заезда — делает меню; здесь просто транслируем. }
  if Assigned(FOnStopRide) then
    FOnStopRide(Self);
end;

function TRoutesPage.DetailsVisible: Boolean;
begin
  Result := Assigned(FDetails) and FDetails.Exists;
end;

function TRoutesPage.Diagnostics: TJSONObject;
  procedure AddButton(const C: TCastleUserInterface);
  var I: Integer; Caption: String;
  begin
    Caption := '';
    if C is TMenuTile then
      Caption := StringReplace(TMenuTile(C).TitleLabel.Caption, LineEnding, ' ', [rfReplaceAll])
    else if C is TCastleButton then
      Caption := TCastleButton(C).Caption;
    if (Caption <> '') and (Result.Find(Caption) = nil) then
      Result.Add(Caption, TJSONArray.Create([
        C.RenderRect.Left, C.RenderRect.Bottom, C.RenderRect.Width, C.RenderRect.Height]));
    for I := 0 to C.ControlsCount - 1 do AddButton(C.Controls[I]);
  end;
begin
  Result := TJSONObject.Create(['selected', SelectedFitPath,
    'points', Length(FDemRoute), 'analyzed', (FFitUrl <> '') and (FAnalyzedUrl = FFitUrl),
    'pending', FPendingFitUrl <> '', 'details', DetailsVisible, 'warm_session', FWarmSession <> nil,
    'warming', FDemPending, 'full_stats_done', FFullStatsDone,
    'review_done',FReview.Done,'review_pending',FReviewTask<>nil,
    'review_warning_points',FReview.ConcernPoints,'review_tiles',FReview.CheckedTiles,
    'review_error',FReview.ErrorText,
    'report_length', Length(FLabelEstimate.Caption)]);
  Result.Add('carousel',FCarousel.Diagnostics);
  AddButton(Self);
end;

function TRoutesPage.CloseDetails: Boolean;
begin
  Result := DetailsVisible;
  if Result then FDetails.Exists := False;
end;

procedure TRoutesPage.ClickCloseDetails(Sender: TObject);
begin
  CloseDetails;
end;

procedure TRoutesPage.ClickDetails(Sender: TObject);
begin
  if FFitUrl=''then begin SetProgress(UiText('Select a route in the carousel first.'));Exit;end;
  FDetails.Exists := True;
  LayoutDetails;
  if (FFitUrl <> '') and (FAnalyzedUrl <> FFitUrl) then
  begin
    FPendingFitUrl := FFitUrl;
    FPendingDelay := 2;
    SetProgress(UiText('Analysing route…'));
  end;
end;

procedure TRoutesPage.LayoutDetails;
var H: Single;
begin
  if FDetailsColumn = nil then Exit;
  FitPanel(FPnlRoute, FInnerRoute);
  FitPanel(FPnlParams, FInnerParams);
  FitPanel(FPnlAnalysis, FInnerAnalysis);
  H := FDetailsColumn.EffectiveHeight + 16;
  if Abs(FDetailsScroll.ScrollArea.Height - H) > 1 then
    FDetailsScroll.ScrollArea.Height := H;
end;

procedure TRoutesPage.DisplayRoute(const Route: array of TLatLon; const FitView: Boolean);
var A, Segments, Line: TJSONArray; O: TJSONObject; I: Integer;
begin
  if FGlobe = nil then Exit;
  A := TJSONArray.Create;
  try
    if Length(Route) > 1 then
    begin
      O := TJSONObject.Create; A.Add(O); O.Add('id', 1);
      Segments := TJSONArray.Create; O.Add('map_path', Segments);
      Line := TJSONArray.Create; Segments.Add(Line);
      for I := 0 to High(Route) do
        Line.Add(TJSONArray.Create([Route[I].Lon, Route[I].Lat]));
    end;
    FGlobe.SelectedId := 1;
    FGlobe.SetRoutes(A, FitView);
  finally A.Free; end;
end;

{ ── Панель параметров расчёта ───────────────────────────────────────
  Пять слайдеров (масса/CdA/Crr/сила ветра/направление) + галки «авто».
  Галка стоит → параметр оценивается алгоритмом; снята → значение
  слайдера уходит в оценщик жёсткой константой (приор с малой сигмой
  либо известный ветер). См. BuildEstimatorCfg. }
procedure TRoutesPage.BuildParamsPanel(AParent: TCastleVerticalGroup);
var
  Row: TCastleHorizontalGroup;
  Hdr: TCastleLabel;
  Btn: TMenuTile;

  function MakeCap(const S: String): TCastleLabel;
  begin
    Result := TMenuLabel.Create(Self);
    BindUiText(Result, S);
    Result.Color    := Vector4(0.72, 0.78, 0.84, 1);
    Result.FontSize := 15;
  end;

  function MakeVal: TCastleLabel;
  begin
    Result := TMenuLabel.Create(Self);
    Result.Caption  := '';
    Result.Color    := White;
    Result.FontSize := 15;
  end;

  function MakeSlider(AMin, AMax, AVal: Single): TCastleFloatSlider;
  begin
    Result := TCastleFloatSlider.Create(Self);
    Result.Min      := AMin;
    Result.Max      := AMax;
    Result.Value    := AVal;
    Result.Width    := 230;
    Result.OnChange := {$ifdef FPC}@{$endif} ParamsChanged;
  end;

  function MakeAuto: TCastleCheckbox;
  begin
    Result := TCastleCheckbox.Create(Self);
    BindUiText(Result, 'auto');
    Result.Checked  := True;
    Result.CheckboxColor := White;   { рамка + галочка — белые }
    Result.TextColor     := White;   { подпись «авто» — белая }
    Result.OnChange := {$ifdef FPC}@{$endif} ParamsChanged;
  end;

begin
  FParamsHost := TCastleVerticalGroup.Create(Self);
  FParamsHost.Spacing := 4;
  AParent.InsertFront(FParamsHost);

  Hdr := TMenuLabel.Create(Self);
  BindUiText(Hdr, 'Clear “auto” to enter a value manually');
  Hdr.Color    := Vector4(0.55, 0.60, 0.66, 1);
  Hdr.FontSize := 14;
  FParamsHost.InsertFront(Hdr);

  { Масса, кг }
  Row := TCastleHorizontalGroup.Create(Self);
  Row.Spacing := 8;
  Row.InsertFront(MakeCap(UiText('Mass')));
  FSlMass := MakeSlider(40, 130, 80);
  Row.InsertFront(FSlMass);
  FLblMass := MakeVal;
  Row.InsertFront(FLblMass);
  FChkMassAuto := MakeAuto;
  Row.InsertFront(FChkMassAuto);
  FParamsHost.InsertFront(Row);

  { CdA }
  Row := TCastleHorizontalGroup.Create(Self);
  Row.Spacing := 8;
  Row.InsertFront(MakeCap('CdA'));
  FSlCdA := MakeSlider(0.15, 0.55, 0.35);
  Row.InsertFront(FSlCdA);
  FLblCdA := MakeVal;
  Row.InsertFront(FLblCdA);
  FChkCdAAuto := MakeAuto;
  Row.InsertFront(FChkCdAAuto);
  FParamsHost.InsertFront(Row);

  { Crr }
  Row := TCastleHorizontalGroup.Create(Self);
  Row.Spacing := 8;
  Row.InsertFront(MakeCap('Crr'));
  FSlCrr := MakeSlider(0.003, 0.020, 0.006);
  Row.InsertFront(FSlCrr);
  FLblCrr := MakeVal;
  Row.InsertFront(FLblCrr);
  FChkCrrAuto := MakeAuto;
  Row.InsertFront(FChkCrrAuto);
  FParamsHost.InsertFront(Row);

  { Ветер: сила, м/с (одна галка «авто» на силу+направление) }
  Row := TCastleHorizontalGroup.Create(Self);
  Row.Spacing := 8;
  Row.InsertFront(MakeCap(UiText('Wind')));
  FSlWindSpd := MakeSlider(0, 12, 0);
  Row.InsertFront(FSlWindSpd);
  FLblWindSpd := MakeVal;
  Row.InsertFront(FLblWindSpd);
  FChkWindAuto := MakeAuto;
  Row.InsertFront(FChkWindAuto);
  FParamsHost.InsertFront(Row);

  { Ветер: направление, откуда дует, ° }
  Row := TCastleHorizontalGroup.Create(Self);
  Row.Spacing := 8;
  Row.InsertFront(MakeCap(UiText('From')));
  FSlWindDir := MakeSlider(0, 360, 0);
  Row.InsertFront(FSlWindDir);
  FLblWindDir := MakeVal;
  Row.InsertFront(FLblWindDir);
  FParamsHost.InsertFront(Row);

  { Пересчитать текущий FIT с новыми параметрами. }
  Btn := MakeAction('RouteRecomputeButton', UiText('Recalculate'), 'refresh',
    Vector4(0.30, 0.58, 0.68, 0.85), @ClickRecompute, 184, 52);
  FParamsHost.InsertFront(Btn);

  ParamsChanged(nil);   { начальные подписи + серые слайдеры }
end;

{ Обновить подписи значений слайдеров (точка — десятичный разделитель,
  чтобы не зависеть от локали) и синхронизировать доступность. }
procedure TRoutesPage.ParamsChanged(Sender: TObject);
var
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  if Assigned(FLblMass) then
    FLblMass.Caption := Format(UiText('%.0f kg'), [FSlMass.Value], FS);
  if Assigned(FLblCdA) then
    FLblCdA.Caption := Format('%.3f', [FSlCdA.Value], FS);
  if Assigned(FLblCrr) then
    FLblCrr.Caption := Format('%.4f', [FSlCrr.Value], FS);
  if Assigned(FLblWindSpd) then
    FLblWindSpd.Caption := Format(UiText('%.1f m/s'), [FSlWindSpd.Value], FS);
  if Assigned(FLblWindDir) then
    FLblWindDir.Caption := Format('%.0f°', [FSlWindDir.Value], FS);
  SyncParamEnable;
end;

{ Галка «авто» стоит → подпись значения серая (параметр оценивается);
  снята → белая (значение задано вручную). Свойства .Enabled у
  TCastleFloatSlider в этой версии CGE нет, поэтому индицируем цветом
  подписи, слайдер остаётся кликабельным. }
procedure TRoutesPage.UpdateAutoSliders(const AEst: TRideEstimate);
var
  Deg: Single;

  function Clamp(Sl: TCastleFloatSlider; V: Single): Single;
  begin
    Result := V;
    if Result < Sl.Min then Result := Sl.Min;
    if Result > Sl.Max then Result := Sl.Max;
  end;

begin
  if not AEst.Success then Exit;
  { Обновляем только параметры на «авто»; зафиксированные (галка снята) —
    оставляем как задал юзер. Клампим в диапазон движка. ParamsChanged
    (OnChange или ручной вызов ниже) только обновляет подписи, пересчёт
    не запускает — цикла нет. }
  if Assigned(FChkMassAuto) and FChkMassAuto.Checked and Assigned(FSlMass) then
    FSlMass.Value := Clamp(FSlMass, AEst.MassKg);
  if Assigned(FChkCdAAuto) and FChkCdAAuto.Checked and Assigned(FSlCdA) then
    FSlCdA.Value := Clamp(FSlCdA, AEst.CdA);
  if Assigned(FChkCrrAuto) and FChkCrrAuto.Checked and Assigned(FSlCrr) then
    FSlCrr.Value := Clamp(FSlCrr, AEst.Crr);
  if Assigned(FChkWindAuto) and FChkWindAuto.Checked then
  begin
    if Assigned(FSlWindSpd) then
      FSlWindSpd.Value := Clamp(FSlWindSpd, AEst.WindSpeedMs);
    if Assigned(FSlWindDir) then
    begin
      Deg := AEst.WindDirRad * 180.0 / Pi;      { «откуда дует», в градусы }
      while Deg < 0 do Deg := Deg + 360;
      while Deg >= 360 do Deg := Deg - 360;
      FSlWindDir.Value := Clamp(FSlWindDir, Deg);
    end;
  end;
  ParamsChanged(nil);   { обновить подписи под новые значения движков }
end;

procedure TRoutesPage.SyncParamEnable;

  procedure Dim(ALbl: TCastleLabel; AAuto: Boolean);
  begin
    if not Assigned(ALbl) then Exit;
    if AAuto then
      ALbl.Color := Vector4(0.72, 0.75, 0.79, 1)
    else
      ALbl.Color := White;
  end;

begin
  if Assigned(FChkMassAuto) then Dim(FLblMass, FChkMassAuto.Checked);
  if Assigned(FChkCdAAuto)  then Dim(FLblCdA,  FChkCdAAuto.Checked);
  if Assigned(FChkCrrAuto)  then Dim(FLblCrr,  FChkCrrAuto.Checked);
  if Assigned(FChkWindAuto) then
  begin
    Dim(FLblWindSpd, FChkWindAuto.Checked);
    Dim(FLblWindDir, FChkWindAuto.Checked);
  end;
end;

{ Пересчитать текущий выбранный FIT с параметрами из панели. Работа
  отложена на Update (как в ClickFileRow) — из клика нельзя морозить
  кадр тяжёлым анализом. }
procedure TRoutesPage.ClickRecompute(Sender: TObject);
begin
  if FFitUrl <> '' then
  begin
    SetProgress(UiText('Recalculating with the selected settings…'));
    FPendingFitUrl := FFitUrl;
    FPendingDelay  := 2;
  end
  else
    SetProgress(UiText('Select a route in the carousel first.'));
end;

procedure TRoutesPage.RefreshFilesList;
var
  SR: TSearchRec;
  Dir, Mask, Png, TxtPath: String;
  I: Integer;
  SL: TStringList;
begin
  if FCarousel=nil then Exit;
  FCarousel.Clear;
  FThumbQueue.Clear;
  FFileNames.Clear;

  Dir := UserRoutesDir;
  { Маршруты двух форматов: FIT (записанные заезды) и GPX (только путь). }
  for I := 0 to 1 do
  begin
    if I = 0 then
      Mask := '*.fit'
    else
      Mask := '*.gpx';
    if FindFirst(Dir + Mask, 0, SR) = 0 then
    begin
      repeat
        FFileNames.Add(SR.Name);
      until FindNext(SR) <> 0;
      SysUtils.FindClose(SR);
    end;
  end;

    for I := 0 to FFileNames.Count - 1 do
    begin
      FCarousel.AddItem(ChangeFileExt(FFileNames[I],''),'','');
      { Свежий кэш мини-карты — грузим сразу; иначе файл в очередь
        генерации (ProcessThumbQueue, один за тик Update). }
      Png := ThumbCachePath(FFileNames[I]);
      if FileExists(Png) then
      begin
        FCarousel.SetImage(I,Png);
        TxtPath := ChangeFileExt(Png, '.txt');
        if FileExists(TxtPath) then
        begin
          SL := TStringList.Create;
          try
            try
              SL.LoadFromFile(TxtPath);
              if SL.Count > 0 then FCarousel.SetInfo(I,SL[0]);
            except
              { битый сайдкар — карточка останется без строки чисел }
            end;
          finally
            SL.Free;
          end;
        end;
      end
      else
        FThumbQueue.Add(FFileNames[I]);
    end;

  SelectCard(FFileNames.IndexOf(ExtractFileName(SelectedFitPath)));

  Logger.Info(Format('[Routes] %s: %d файлов', [Dir, FFileNames.Count]));
end;

function TRoutesPage.ThumbCachePath(const AFileName: String): String;
var
  Src, Dir, Base: String;
  SR: TSearchRec;
  Size, MTime: Int64;
begin
  Src := UserRoutesDir + AFileName;
  Size := 0;
  MTime := 0;
  if FindFirst(Src, 0, SR) = 0 then
  begin
    Size := SR.Size;
    MTime := SR.Time;
    SysUtils.FindClose(SR);
  end;
  Dir := UserRoutesDir + '.thumbs' + PathDelim;
  ForceDirectories(Dir);
  Base := ChangeFileExt(AFileName, '');
  Result := Dir + Format('%s-%d-%d.png', [Base, Size, MTime]);
end;

{ Строка ключевых чисел карточки: дистанция (сумма haversine по точкам)
  и набор высоты (из RouteAltM, если высоты есть). }
function TRoutesPage.RouteCardInfo(const AFit: TFitFile): String;
var
  I: Integer;
  DistM, Ascent: Double;
begin
  DistM := TRouteSrc.TotalLengthMeters(AFit.RouteLatLon);
  Ascent := 0;
  if Length(AFit.RouteAltM) = Length(AFit.RouteLatLon) then
    for I := 1 to High(AFit.RouteAltM) do
      if AFit.RouteAltM[I] > AFit.RouteAltM[I - 1] then
        Ascent := Ascent + (AFit.RouteAltM[I] - AFit.RouteAltM[I - 1]);
  Result := Format(UiText('%.1f km · +%.0f m'), [DistM / 1000.0, Ascent]);
end;

{ Рендер мини-карты: эквиректангулярная проекция (x = lon·cos(lat₀),
  y = lat) в bbox с полем 8%, растр 480×240 — тёмный фон, широкое
  полупрозрачное свечение + акцентная линия 3 px, старт/финиш — точки.
  Прямая запись пикселей через Colors — как в старом превью редактора.
  Y=0 в TCastleImage — нижняя строка, поэтому север (бóльшая lat)
  попадает в бóльший Y и на картинке оказывается сверху. }
function TRoutesPage.RenderRouteThumb(const AFit: TFitFile;
  const APngPath: String): Boolean;
const
  MARGIN = 0.08;   { поле вокруг bbox, доля размера }
var
  Img: TRGBAlphaImage;
  N, Step, M, I, J: Integer;
  CenLat, CenLon, CosLat: Double;
  PrjX, PrjY, MinX, MaxX, MinY, MaxY, RangeX, RangeY, Scale: Double;
  PixX, PixY: array of Integer;
  BgCol, Accent, Glow, StartCol, FinCol: TCastleColor;

  procedure Stamp(const AX, AY, AR: Integer; const ACol: TCastleColor);
  var
    X, Y: Integer;
  begin
    for Y := AY - AR to AY + AR do
      for X := AX - AR to AX + AR do
        if (X >= 0) and (X < THUMB_W) and (Y >= 0) and (Y < THUMB_H) then
          Img.Colors[X, Y, 0] := ACol;
  end;

  { Брезенхем со штампом AR×AR — толщина линии. }
  procedure DrawSeg(AX0, AY0, AX1, AY1, AR: Integer; const ACol: TCastleColor);
  var
    Dx, Dy, Sx, Sy, Err, E2: Integer;
  begin
    Dx := Abs(AX1 - AX0);
    if AX0 < AX1 then Sx := 1 else Sx := -1;
    Dy := -Abs(AY1 - AY0);
    if AY0 < AY1 then Sy := 1 else Sy := -1;
    Err := Dx + Dy;
    while True do
    begin
      Stamp(AX0, AY0, AR, ACol);
      if (AX0 = AX1) and (AY0 = AY1) then Break;
      E2 := 2 * Err;
      if E2 >= Dy then begin Err := Err + Dy; AX0 := AX0 + Sx; end;
      if E2 <= Dx then begin Err := Err + Dx; AY0 := AY0 + Sy; end;
    end;
  end;

begin
  Result := False;
  N := Length(AFit.RouteLatLon);
  if N < 2 then Exit;

  { Прореживание до ≤1500 точек — мини-карте больше не нужно. }
  Step := (N + THUMB_MAX_PTS - 1) div THUMB_MAX_PTS;
  M := (N + Step - 1) div Step;
  SetLength(PixX, M);
  SetLength(PixY, M);

  CenLat := 0;
  CenLon := 0;
  for I := 0 to N - 1 do
  begin
    CenLat := CenLat + AFit.RouteLatLon[I].Lat;
    CenLon := CenLon + AFit.RouteLatLon[I].Lon;
  end;
  CenLat := CenLat / N;
  CenLon := CenLon / N;
  CosLat := Cos(DegToRad(CenLat));

  MinX := 0; MaxX := 0; MinY := 0; MaxY := 0;
  for J := 0 to M - 1 do
  begin
    I := J * Step;
    if I > N - 1 then I := N - 1;
    PrjX := (AFit.RouteLatLon[I].Lon - CenLon) * CosLat;
    PrjY := AFit.RouteLatLon[I].Lat - CenLat;
    if J = 0 then
    begin
      MinX := PrjX; MaxX := PrjX; MinY := PrjY; MaxY := PrjY;
    end
    else
    begin
      if PrjX < MinX then MinX := PrjX;
      if PrjX > MaxX then MaxX := PrjX;
      if PrjY < MinY then MinY := PrjY;
      if PrjY > MaxY then MaxY := PrjY;
    end;
  end;
  RangeX := MaxX - MinX;
  RangeY := MaxY - MinY;
  if RangeX < 1e-9 then RangeX := 1e-9;
  if RangeY < 1e-9 then RangeY := 1e-9;
  Scale := (THUMB_W * (1 - 2 * MARGIN)) / RangeX;
  if Scale > (THUMB_H * (1 - 2 * MARGIN)) / RangeY then
    Scale := (THUMB_H * (1 - 2 * MARGIN)) / RangeY;

  for J := 0 to M - 1 do
  begin
    I := J * Step;
    if I > N - 1 then I := N - 1;
    PrjX := (AFit.RouteLatLon[I].Lon - CenLon) * CosLat;
    PrjY := AFit.RouteLatLon[I].Lat - CenLat;
    PixX[J] := Round(THUMB_W / 2 + (PrjX - (MinX + MaxX) / 2) * Scale);
    PixY[J] := Round(THUMB_H / 2 + (PrjY - (MinY + MaxY) / 2) * Scale);
  end;

  Img := TRGBAlphaImage.Create(THUMB_W, THUMB_H);
  try
    BgCol    := Vector4(0.05, 0.07, 0.10, 1.0);
    Accent   := Vector4(1.00, 0.72, 0.20, 1.0);  { янтарный, в тон золотой рамке }
    Glow     := Vector4(0.28, 0.22, 0.12, 1.0);  { «полупрозрачное» свечение — приглушённый акцент }
    StartCol := Vector4(0.30, 0.90, 0.40, 1.0);
    FinCol   := Vector4(0.95, 0.30, 0.25, 1.0);
    Img.Clear(BgCol);
    { Первый проход — широкое свечение, второй — линия 3 px, точки — поверх. }
    for J := 0 to M - 2 do
      DrawSeg(PixX[J], PixY[J], PixX[J + 1], PixY[J + 1], 5, Glow);
    for J := 0 to M - 2 do
      DrawSeg(PixX[J], PixY[J], PixX[J + 1], PixY[J + 1], 1, Accent);
    Stamp(PixX[0], PixY[0], 4, StartCol);
    Stamp(PixX[M - 1], PixY[M - 1], 4, FinCol);
    { SaveImage → libpng в некоторых сборках падает (см. PBRTextureUnit) —
      под try/except: без мини-карты карточка живёт на плейсхолдере. }
    try
      SaveImage(Img, FilenameToURISafe(APngPath));
      Result := True;
    except
      on E: Exception do
        LogOsm('мини-карта: SaveImage не удался: ' + E.Message);
    end;
  finally
    Img.Free;
  end;
end;

{ Мини-карта + строка чисел для карточки: из свежего кэша — сразу
  (сайдкар .txt с числами читается без парсинга FIT); иначе — лёгкий
  парсинг (как в RunMultiAnalysis) и генерация. Битый файл (нет точек) —
  AInfo = 'нет трека', картинки нет, выбор маршрута не ломается. }
function TRoutesPage.EnsureRouteThumb(const AFileName: String;
  out APngPath, AInfo: String): Boolean;
var
  Src, Png, TxtPath: String;
  Fit: TFitFile;
  SL: TStringList;
begin
  Result := False;
  APngPath := '';
  AInfo := '';
  Src := UserRoutesDir + AFileName;
  Png := ThumbCachePath(AFileName);
  TxtPath := ChangeFileExt(Png, '.txt');

  if FileExists(Png) then
  begin
    APngPath := Png;
    Result := True;
    if FileExists(TxtPath) then
    begin
      SL := TStringList.Create;
      try
        try
          SL.LoadFromFile(TxtPath);
          if SL.Count > 0 then AInfo := SL[0];
        except
          AInfo := '';
        end;
      finally
        SL.Free;
      end;
    end;
    Exit;
  end;

  Fit := NewRouteParserForFile(Src);   { .fit или .gpx — по расширению }
  try
    if (not Fit.LoadFromFile(Src)) or (Length(Fit.RouteLatLon) < 2) then
    begin
      AInfo := UiText('no track');
      Exit;
    end;
    AInfo := RouteCardInfo(Fit);
    if RenderRouteThumb(Fit, Png) then
    begin
      APngPath := Png;
      Result := True;
      { Сайдкар с числами — при следующем попадании в кэш FIT не парсим. }
      SL := TStringList.Create;
      try
        SL.Add(AInfo);
        try
          SL.SaveToFile(TxtPath);
        except
          { не критично: числа пересчитаются при следующей генерации }
        end;
      finally
        SL.Free;
      end;
    end;
  finally
    Fit.Free;
  end;
end;

{ Один файл из очереди за тик Update: сгенерировать/подхватить мини-карту
  и обновить карточку. }
procedure TRoutesPage.ProcessThumbQueue;
var FileBase,Png,Info:String;I:Integer;
begin
  if FThumbQueue.Count=0 then Exit;
  FileBase:=FThumbQueue[0];FThumbQueue.Delete(0);
  if EnsureRouteThumb(FileBase,Png,Info)or(Info<>'')then begin
    I:=FFileNames.IndexOf(FileBase);
    if I>=0 then begin
      if Png<>''then FCarousel.SetImage(I,Png);
      if Info<>''then FCarousel.SetInfo(I,Info);
    end;
  end;
end;

procedure TRoutesPage.SetProgress(const AText: String);
begin
  { НИКАКИХ Application.ProcessMessage: Start выполняется внутри
    ProcessViewChanges, рекурсивный event loop роняет контейнер.
    Тяжёлая работа отложена на Update (FPendingFitUrl/FPendingMulti). }
  if Assigned(FLabelProgress) then
    FLabelProgress.Caption := AText;
  if Assigned(FStatus) then FStatus.Caption := AText;
end;

procedure TRoutesPage.ClearStats;
begin
  if Assigned(FStatsHost) then
    while FStatsHost.ControlsCount > 0 do FStatsHost.Controls[0].Free;
  SetEstimate('');
  FitPanel(FPnlRoute, FInnerRoute);
end;

procedure TRoutesPage.Resize;
begin
  inherited;
  LayoutActions;
  LayoutDetails;
end;

procedure TRoutesPage.SetEstimate(const AText: String);
begin
  if not Assigned(FLabelEstimate) then Exit;
  FLabelEstimate.Caption := AText;
  LayoutDetails;
end;

procedure TRoutesPage.AddStatHeader(const ACaption: String);
var
  L: TCastleLabel;
begin
  L := TMenuLabel.Create(FStatsHost);
  BindUiText(L, ACaption);
  L.Color    := White;
  L.FontSize := 19;
  FStatsHost.InsertFront(L);
  FitPanel(FPnlRoute, FInnerRoute);
end;

procedure TRoutesPage.AddStatRow(const AKey, AValue: String);
var
  Row: TCastleHorizontalGroup;
  K, V: TCastleLabel;
begin
  Row := TCastleHorizontalGroup.Create(FStatsHost);
  Row.Spacing := 8;
  FStatsHost.InsertFront(Row);

  K := TMenuLabel.Create(Row);
  K.Caption  := AKey;
  K.Color    := Vector4(0.55, 0.60, 0.66, 1);
  K.FontSize := 16;
  K.AutoSize := False;
  K.Width    := 130;
  K.Height   := 22;
  Row.InsertFront(K);

  V := TMenuLabel.Create(Row);
  V.Caption  := AValue;
  V.Color    := Vector4(0.92, 0.95, 1.0, 1);
  V.FontSize := 16;
  Row.InsertFront(V);
  FitPanel(FPnlRoute, FInnerRoute);
end;

{ ── Кнопки ─────────────────────────────────────────────────────────── }

procedure TRoutesPage.ClickAddFit(Sender:TObject);
var Url:String;
begin
  Url:='';
  if Application.MainWindow.FileDialog(UiText('Add a route file (FIT or GPX)'),Url,True,'FIT / GPX|*.fit;*.gpx')then
    ImportFile(URIToFilenameSafe(Url));
end;
procedure TRoutesPage.ImportFile(const FileName:String);
var Dest,Base,Ext:String;N:Integer;
begin
  if not FileExists(FileName)then Exit;
  Dest:=UserRoutesDir+ExtractFileName(FileName);
  if not SameFileName(ExpandFileName(FileName),ExpandFileName(Dest))then begin
    Base:=ChangeFileExt(Dest,'');Ext:=ExtractFileExt(Dest);N:=0;
    while FileExists(Dest)do begin Inc(N);Dest:=Base+'-'+IntToStr(N)+Ext;end;
    try CopyFileBinary(FileName,Dest);
    except on E:Exception do begin SetProgress(UiText('Copy failed: ')+E.Message);Exit;end;end;
  end;
  RefreshFilesList;OpenLibraryFile(Dest);
  try QueueLocalRoute(Dest);except on E:Exception do SetProgress(E.Message);end;
end;

procedure TRoutesPage.ClickLibrary(Sender:TObject);
begin ViewMenu.OpenTab('route-library');end;
procedure TRoutesPage.ClickCreate(Sender:TObject);
begin ViewMenu.OpenTab('route-create');end;

procedure TRoutesPage.OpenLibraryFile(const FileName:String);
var I:Integer;
begin
  if not FileExists(FileName)then begin
    FFitUrl:='';FPendingFitUrl:='';FLoadedUrl:='';StopWarmSession;
    FHeader.SetSelection(ChangeFileExt(ExtractFileName(FileName),''),UiText('Route file not found.'),False);
    SetProgress(UiText('File not found: ')+FileName);Exit;
  end;
  if SameFileName(ExpandFileName(ExtractFileDir(FileName)),ExpandFileName(ExcludeTrailingPathDelimiter(UserRoutesDir)))then begin
    I:=FFileNames.IndexOf(ExtractFileName(FileName));if I>=0 then SelectCard(I);
  end;
  FFitUrl:=FilenameToURISafe(FileName);FPendingFitUrl:=FFitUrl;FPendingDelay:=2;
  Settings.SetSelectedRoutePath(FileName);
  RememberRideMap(rmkReal,FileName);
  FHeader.SetSelection(ChangeFileExt(ExtractFileName(FileName),''),UiText('Reading route…'),False);
  SetProgress(UiText('Reading route…'));
end;

procedure TRoutesPage.ClickFileRow(Sender: TObject);
var
  I: Integer;
begin
  I := FCarousel.Selected;
  if (I < 0) or (I >= FFileNames.Count) then Exit;
  SelectCard(I);
  FFitUrl := FilenameToURISafe(UserRoutesDir + FFileNames[I]);
  Settings.SetSelectedRoutePath(SelectedFitPath);
  RememberRideMap(rmkReal,SelectedFitPath);
  FHeader.SetSelection(FCarousel.ItemTitle(I),FCarousel.ItemInfo(I),False);
  FHeader.SetRideState(ViewMenu.RideUnderneath,SameFileName(SelectedFitPath,ViewPlay.CurrentFitPath));
  SetProgress(UiText('Reading FIT…'));
  FPendingFitUrl := FFitUrl;
  FPendingDelay := 2;
end;

procedure TRoutesPage.ClickMultiAnalysis(Sender: TObject);
begin
  if FFileNames.Count < 2 then
  begin
    SetProgress(UiText('Combined analysis requires at least two routes.'));
    Exit;
  end;
  SetProgress(Format(UiText('Analysing %d routes together…'),
    [FFileNames.Count]));
  FPendingMulti := True;
  FPendingDelay := 2;
end;

function TRoutesPage.BuildEstimatorCfg: TRideEstimatorConfig;
begin
  Result := DefaultRideEstimatorConfig;
  { По умолчанию масса — из профиля велосайта (если «авто» оставлена). }
  if VeloSite.HasCachedProfile and
     (VeloSite.CachedProfile.WeightKg > 20) then
    Result.RiderProfileMassKg := VeloSite.CachedProfile.WeightKg;

  { Ручные константы из панели: снятая галка «авто» → параметр
    фиксируется жёстким приором (малая сигма) либо известным ветром.
    Выбор выборочный — каждый параметр независимо. Панель может быть
    ещё не построена (тогда всё по умолчанию, т.е. авто). }
  if Assigned(FChkMassAuto) and (not FChkMassAuto.Checked) then
  begin
    Result.RiderProfileMassKg := FSlMass.Value;
    Result.BikeMassGuessKg    := 0;      { масса общая, велосипед уже в ней }
    Result.MassPriorSigmaKg   := 0.3;    { жёстко → фиксирует массу }
  end;
  if Assigned(FChkCdAAuto) and (not FChkCdAAuto.Checked) then
  begin
    Result.CdAPrior      := FSlCdA.Value;
    Result.CdAPriorSigma := 0.006;       { жёстко }
  end;
  if Assigned(FChkCrrAuto) and (not FChkCrrAuto.Checked) then
  begin
    Result.CrrPrior      := FSlCrr.Value;
    Result.CrrPriorSigma := 0.0004;      { жёстко }
  end;
  if Assigned(FChkWindAuto) then
  begin
    if FChkWindAuto.Checked then
      Result.EstimateWind := True        { оценить ветер по курсу GPS }
    else
    begin
      Result.WindKnown        := True;   { известный ветер задан вручную }
      Result.WindKnownSpeedMs := FSlWindSpd.Value;
      Result.WindKnownFromRad := DegToRad(FSlWindDir.Value);
    end;
  end;
end;

{ ── Одиночный анализ + превью ──────────────────────────────────────── }

procedure TRoutesPage.OpenAndAnalyzeFit(const AFitUrl: String; const Analyze: Boolean);
var
  Fit: TFitFile;
  FitPath: String;
  Samples: TRideSampleArray;
  Cfg: TRideEstimatorConfig;
  Est: TRideEstimate;
  Pts: TRidePointResultArray;
  Route: TRouteLatLonArray;
  I, N: Integer;
  Ascent, Descent, DistKm, DurSec: Double;
  T0, TL: QWord;
  MvEst: TRideEstimate;   { оценка по минимуму колебаний }
begin
  FitPath := URIToFilenameSafe(AFitUrl);
  if (FitPath = '') or (not FileExists(FitPath)) then
  begin
    SetProgress(UiText('File not found: ') + AFitUrl);
    Exit;
  end;
  T0 := GetTickCount64;
  LogOsm('чтение маршрута ' + ExtractFileName(FitPath));

  FFitUrl := AFitUrl;
  Settings.SetSelectedRoutePath(FitPath);
  FHeader.StartButton.Enabled:=False;
  StopWarmSession;
  FFitEstOk := False;
  FAnalyzedUrl := '';
  ClearReview;
  FDemRoute := nil;
  FDemSamples := nil;
  FFitPts := nil;
  ClearStats;
  FDemPending := False;   { прежнее ожидание высот больше не актуально }

  Fit := NewRouteParserForFile(FitPath);   { .fit или .gpx — по расширению }
  try
    TL := GetTickCount64;
    if not Fit.LoadFromFile(FitPath) then
    begin
      FLoadedUrl := '';
      DisplayRoute([], False);
      SetProgress(UiText('Could not read the route file.'));
      Exit;
    end;
    LogOsm(Format('маршрут загружен: %d мс', [GetTickCount64 - TL]));
    if Length(Fit.RouteLatLon) < 2 then
    begin
      FLoadedUrl := '';
      DisplayRoute([], False);
      SetProgress(UiText('The file contains no valid GPS route.'));
      Exit;
    end;

    SetLength(Route, Length(Fit.RouteLatLon));
    for I := 0 to High(Route) do
      Route[I] := Fit.RouteLatLon[I];

    Samples := Fit.ToRideSamples;
    N := Length(Samples);
    DistKm := 0;
    DurSec := 0;
    if N > 0 then
    begin
      DistKm := Samples[N - 1].DistanceM / 1000.0;
      DurSec := Samples[N - 1].TimeSec;
    end;
    Ascent := 0;
    Descent := 0;
    for I := 1 to High(Fit.RouteAltM) do
    begin
      if Fit.RouteAltM[I] > Fit.RouteAltM[I - 1] then
        Ascent := Ascent + (Fit.RouteAltM[I] - Fit.RouteAltM[I - 1])
      else
        Descent := Descent + (Fit.RouteAltM[I - 1] - Fit.RouteAltM[I]);
    end;
    AddStatHeader(ExtractFileName(FitPath));
    AddStatRow(UiText('Points'),     IntToStr(N));
    AddStatRow(UiText('Distance'), Format(UiText('%.1f km'), [DistKm]));
    AddStatRow(UiText('Time'),     Format('%d:%.2d:%.2d',
      [Trunc(DurSec) div 3600, (Trunc(DurSec) div 60) mod 60,
       Trunc(DurSec) mod 60]));
    AddStatRow(UiText('Ascent'),     Format(UiText('+%.0f m'), [Ascent]));
    AddStatRow(UiText('Descent'),     Format(UiText('−%.0f m'), [Descent]));

    if Analyze then
    begin
    SetProgress(UiText('Estimating rider parameters…'));
    Cfg := BuildEstimatorCfg;
    TL := GetTickCount64;
    FFitEstOk := EstimateRideParameters(Samples, Cfg, Est, Pts);
    LogOsm(Format('оценка параметров: %d мс (%d сэмплов, ok=%d)',
      [GetTickCount64 - TL, N, Ord(FFitEstOk)]));
    FFitEst := Est;
    FFitPts := Copy(Pts, 0, Length(Pts));   { для эмуляции в полной статистике }
    if FFitEstOk then
      FFitReport := FormatRideEstimate(Est)
    else
      FFitReport := UiText('Parameter estimation: ') + Est.Message;

    { Оценка по МИНИМУМУ КОЛЕБАНИЙ (новый метод: ищет параметры с наименьшим
      разбросом по заезду). Тайминги её этапов идут в osm3d_*.log через
      колбэк EstLog. }
    if EstimateRideMinVariance(Samples, Cfg, @EstLog, MvEst) then
    begin
      FFitReport := FFitReport + LineEnding + LineEnding
        + Format(UiText('── Minimum variation ──') + LineEnding
          + UiText('Mass %.1f kg (±%.1f, 95%%)') + LineEnding
          + 'CdA %.3f, Crr %.4f' + LineEnding
          + UiText('Wind %.0f m/s, from %.0f°') + LineEnding + '%s',
          [MvEst.MassKg, MvEst.MassCi95, MvEst.CdA, MvEst.Crr,
           MvEst.WindSpeedMs, MvEst.WindDirRad * 180.0 / Pi, MvEst.Message]);
      { Движки, стоящие на «авто», выставляем в посчитанные значения
        (зафиксированные юзером — не трогаем). }
      UpdateAutoSliders(MvEst);
    end
    else
      FFitReport := FFitReport + LineEnding + LineEnding
        + UiText('Minimum variation: ') + MvEst.Message;

    SetEstimate(FFitReport);
    FAnalyzedUrl := AFitUrl;
    end;
    { Копия сэмплов — для второго прогона на DEM-высоте (придёт позже). }
    FDemSamples := Copy(Samples, 0, Length(Samples));

    { Копии маршрута/высот/одометрии в поля страницы — Fit сейчас
      умрёт, а сверка высот случится позже, когда прогрев доедет
      (см. FDemPending в Update). }
    FDemRoute := Copy(Route, 0, Length(Route));
    FDemStartUTC := Fit.RouteStartUTC;   { для warm-сессии полной статистики }
    SetLength(FDemFitAlt, Length(Fit.RouteAltM));
    for I := 0 to High(Fit.RouteAltM) do
      FDemFitAlt[I] := Fit.RouteAltM[I];
    SetLength(FDemDist, Length(Samples));
    for I := 0 to High(Samples) do
      FDemDist[I] := Samples[I].DistanceM;
    DisplayRoute(Route, FLoadedUrl <> AFitUrl);
    FLoadedUrl := AFitUrl;
    CheckOffline;
    FHeader.SetSelection(ChangeFileExt(ExtractFileName(FitPath),''),
      Format(UiText('%.1f km  ·  Ascent %.0f m'),[DistKm,Ascent]),True);
    FHeader.SetRideState(ViewMenu.RideUnderneath,SameFileName(SelectedFitPath,ViewPlay.CurrentFitPath));
    SetProgress('');
    LogOsm(Format('маршрут открыт: %d точек, %.1f км, анализ=%d, всего %d мс',
      [N, DistKm, Ord(Analyze), GetTickCount64 - T0]));
  finally
    Fit.Free;
  end;
end;

{ ── Полная статистика (по кнопке) ──────────────────────────────────
  Тяжёлый путь: прогрев тайлов настоящей стриминг-сессией + снап +
  зелёные сферы (притянутый путь) + сверка высот поверхности + CSV +
  эмуляция прохождения всеми режимами уклона.
  Использует FDem*-массивы, заполненные простым кликом (OpenAndAnalyzeFit).
  Коррекция к моделям — ПО НАСТРОЙКЕ (Settings.FitHeightCorrection, гейт
  в Session.Create): сверка и эмуляция меряют фактический мир игры,
  ключ кэша общий с ней — прогретые тайлы переиспользуются. }
procedure TRoutesPage.ClickFullStats(Sender: TObject);
begin BeginWarmup(False) end;

procedure TRoutesPage.ClickPrepareOffline(Sender:TObject);
begin
  if FWarmSession<>nil then begin StopWarmSession;CheckOffline;Exit end;
  if FOfflinePreparing and(FOfflineTask<>nil)then begin
    FOfflineTask.Abandon;FOfflineTask:=nil;CheckOffline;Exit;
  end;
  if FOffline.Ready then CheckOffline else CheckOffline(True);
end;

procedure TRoutesPage.ClearReview;
begin
  if FReviewTask<>nil then begin FReviewTask.Abandon;FReviewTask:=nil end;
  FReview:=Default(TRouteReview);FReviewRequested:=False;FReviewIndex:=-1;
  FPreparedCenters:=nil;FPreparedRide:=nil;FPreparedWidths:=nil;FPreparedWays:=nil;
  FPreparedCacheRoot:='';FPreparedGenHash:='';
  if FReviewLabel<>nil then FReviewLabel.Caption:='';
  if FReviewButton<>nil then FReviewButton.SetTitle(UiText('Check route geometry'));
  if FReviewNextButton<>nil then FReviewNextButton.Exists:=False;
end;
procedure TRoutesPage.StartReview;
begin
  if FReviewTask<>nil then Exit;
  if Length(FPreparedCenters)<>Length(FDemRoute)then Exit;
  FReviewTask:=TRouteReviewTask.Create(FPreparedSettings,FPreparedCacheRoot,FPreparedGenHash,
    TRouteSrc.OriginCentroid(FDemRoute),FDemRoute,FPreparedCenters,FPreparedRide,FPreparedWidths,FPreparedWays);
  FReviewLabel.Caption:=UiText('Checking prepared route geometry...');
end;
procedure TRoutesPage.ClickReview(Sender:TObject);
begin
  if FReviewTask<>nil then Exit;
  if FReview.Done and(FReview.ErrorText='')then begin ShowReview;CloseDetails;Exit end;
  FReviewRequested:=True;
  if(Length(FPreparedCenters)=Length(FDemRoute))and(Length(FDemRoute)>1)then StartReview
  else BeginWarmup(True);
end;
procedure TRoutesPage.ShowReview;
var A,Segments,Line:TJSONArray;O:TJSONObject;I:Integer;
  procedure AddPath(const Path:TRouteLatLonArray;Id:Integer;const Color:TVector4;Width:Single);
  var K:Integer;
  begin
    O:=TJSONObject.Create(['id',Id,'line_width',Width]);A.Add(O);
    O.Add('line_color',TJSONArray.Create([Color.X,Color.Y,Color.Z,Color.W]));
    Segments:=TJSONArray.Create;O.Add('map_path',Segments);Line:=TJSONArray.Create;Segments.Add(Line);
    for K:=0 to High(Path)do Line.Add(TJSONArray.Create([Path[K].Lon,Path[K].Lat]));
    if(Id=-102)and not FReview.Turnarounds and(Length(Path)>1)then
      Line.Add(TJSONArray.Create([Path[0].Lon,Path[0].Lat]));
  end;
begin
  if(FGlobe=nil)or not FReview.Done or(FReview.ErrorText<>'')then Exit;
  A:=TJSONArray.Create;
  try
    AddPath(FReview.Original,-101,Vector4(0.65,0.67,0.7,0.9),7);
    AddPath(FReview.Ride,-102,Vector4(0.1,0.85,0.95,1),3);
    O:=TJSONObject.Create(['id',-103,'line_width',5.0]);A.Add(O);
    O.Add('line_color',TJSONArray.Create([1.0,0.49,0.08,1.0]));
    Segments:=TJSONArray.Create;O.Add('map_path',Segments);
    for I:=0 to High(FReview.Points)do if FReview.Points[I].Issues<>[]then begin
      Line:=TJSONArray.Create;Segments.Add(Line);
      if I>0 then Line.Add(TJSONArray.Create([FReview.Corrected[I-1].Lon,FReview.Corrected[I-1].Lat]));
      Line.Add(TJSONArray.Create([FReview.Corrected[I].Lon,FReview.Corrected[I].Lat]));
      if I<High(FReview.Points)then Line.Add(TJSONArray.Create([FReview.Corrected[I+1].Lon,FReview.Corrected[I+1].Lat]));
    end;
    FGlobe.SetRoutes(A,False);
  finally A.Free end;
  FStatus.Caption:=UiText('Gray: original; cyan: prepared ride; orange: review needed.');
end;
procedure TRoutesPage.ClickReviewNext(Sender:TObject);
var N,I:Integer;Start:Integer;
begin
  if not FReview.Done or(FGlobe=nil)then Exit;
  N:=Length(FReview.Points);if N=0 then Exit;
  Start:=FReviewIndex;
  { Visit starts of warning ranges, rather than every densely sampled point. }
  for I:=1 to N do begin
    FReviewIndex:=(Start+I)mod N;
    if(FReview.Points[FReviewIndex].Issues<>[])and
      ((FReviewIndex=0)or(FReview.Points[FReviewIndex].Issues<>FReview.Points[FReviewIndex-1].Issues))then begin
      ShowReview;CloseDetails;FGlobe.CenterAt(FReview.Corrected[FReviewIndex],18);
      FStatus.Caption:=Format(UiText('Review at %.2f km — gray: original; cyan: prepared ride; orange: warning.'),
        [FReview.Points[FReviewIndex].Distance/1000]);Exit;
    end;
  end;
end;

procedure TRoutesPage.CheckOffline(PrepareSources:Boolean);
begin
  if FOfflineTask<>nil then begin FOfflineTask.Abandon;FOfflineTask:=nil end;
  FOffline:=Default(TOfflineReadiness);
  FOfflinePreparing:=PrepareSources;
  if PrepareSources then FOfflinePrepareButton.SetTitle(UiText('Cancel preparation'))
  else FOfflinePrepareButton.SetTitle(UiText('Prepare for offline ride'));
  if(FLoadedUrl<>FFitUrl)or(Length(FDemRoute)<2)then begin
    FOfflineLabel.Caption:='';Exit;
  end;
  FOfflineTask:=TOfflineReadinessTask.CreateRoute(TStudioSettings.Defaults,FDemRoute,SelectedFitPath,PrepareSources);
  FOfflineLabel.Caption:=FOffline.Caption;
end;

procedure TRoutesPage.BeginWarmup(ForOffline:Boolean);
var
  WarmRoute:  TRouteLatLonArray;
  WarmOrigin: TLatLon;
  FitPath:    String;
  I:          Integer;
begin
  if FWarmSession<>nil then Exit; { reuse the already running preparation }
  FPrepareOnly:=ForOffline;
  if ForOffline then FOfflinePrepareButton.SetTitle(UiText('Cancel preparation'));
  if FPendingFitUrl <> '' then
  begin
    SetProgress(UiText('Wait for the route to finish loading and analysing.'));
    Exit;
  end;
  if (FFitUrl = '') or (Length(FDemRoute) < 2) then
  begin
    SetProgress(UiText('Select a route in the carousel first.'));
    Exit;
  end;
  FitPath := URIToFilenameSafe(FFitUrl);
  if (FitPath = '') or (not FileExists(FitPath)) then
  begin
    SetProgress(UiText('Route file not found.'));
    Exit;
  end;
  LogOsm('КНОПКА полной статистики: прогрев тайлов + снап + зелёные сферы + '
    + 'сверка + CSV — ' + ExtractFileName(FitPath));

  StopWarmSession;
  SetLength(WarmRoute, Length(FDemRoute));
  for I := 0 to High(FDemRoute) do
    WarmRoute[I] := FDemRoute[I];
  WarmOrigin := TRouteSrc.OriginCentroid(WarmRoute);
  FWarmProj := TLocalProjection.Create(WarmOrigin);
  try
    { Папка заездов + имя FIT + время старта заезда — РОВНО те же
      аргументы, что игровая сессия (TGameOsmStreaming.StartFromFit →
      Session.Create). Это принципиально: FIT-слой строится в Create,
      его сигнатура и имя FIT входят в gen-hash дискового кэша тайлов —
      только при побайтово одинаковом хэше прогретые здесь тайлы
      переиспользуются «Свободной ездой». Прежний вариант (Create без
      папки + SetRoutesFolder постфактум + Now вместо времени заезда)
      давал прогреву и игре РАЗНЫЕ ключи кэша: игра пекла всё заново
      на ходу, райдер обгонял генерацию и ехал по пустоте. }
    FWarmSettings:=TStudioSettings.Defaults;
    FWarmSession := TOsm3dStreamingSession.Create(
      FWarmSettings, WarmOrigin, @StreamLog, FDemStartUTC,
      WarmRoute, nil,
      ExtractFilePath(FitPath), ExtractFileName(FitPath));
    { Райдера на этой странице нет — гейт «гашение оверлея после
      постановки райдера» выключен, иначе оверлей не погас бы никогда. }
    FWarmSession.Map.WarmupHoldRider := False;
    { FitLayerBuild здесь НЕ перебиваем: Create уже выставил его из
      Settings.FitHeightCorrection (дефолт True — слой строится и ставится
      в физический слот карты, см. Osm3dStreamingLauncher). Слой —
      рантайм-данные физики: меши/тайлы/кэш остаются сырыми, gen-hash от
      списка фитов не зависит, прогретые тайлы общие с игрой всегда. }
  except
    on E: Exception do
    begin
      FreeAndNil(FWarmProj);
      SetProgress(UiText('Preloading failed to start: ') + E.Message);
      Exit;
    end;
  end;

  { Ключи дискового кэша — в лог: эта строка обязана совпадать с
    'StartFromFit: GenHash=... CacheRoot=...' игровой сессии того же FIT.
    Разошлись → прогрев не переиспользуется, искать разницу аргументов. }
  LogOsm(Format('полная статистика: GenHash=%s CacheRoot=%s fit=%s',
    [FWarmSession.GenHash, FWarmSession.CacheRoot,
     ExtractFileName(FitPath)]));

  { Мини-вьюпорт: карте нужен живой Update (оверлей прогрева ведётся
    из него). 2×2 px в углу — рендер мира нам не нужен. }
  if FMiniVp = nil then
  begin
    FMiniVp := TCastleViewport.Create(Self);
    FMiniVp.FullSize := False;
    FMiniVp.Width  := 2;
    FMiniVp.Height := 2;
    FMiniVp.Anchor(hpLeft, 0);
    FMiniVp.Anchor(vpBottom, 0);
    InsertFront(FMiniVp);
  end;
  FMiniVp.Items.Add(FWarmSession.Map);
  FMiniVp.Camera.SetView(
    FWarmProj.Project(WarmRoute[0], 0) + Vector3(0, 150, 0),
    Vector3(0, -1, 0.01),
    Vector3(0, 0, -1));

  FWarmSession.Map.BeginRouteSnap;

  FDemPending := True;
  FDemWaitS := 0;
  FFullStatsDone := False;   { взведётся в Update после ComputeDemComparison }
  SetProgress(UiText('Full statistics: preloading route tiles…'));
end;

{ ── Сверка высот FIT с рельефом ────────────────────────────────────
  Идея: барометр головного устройства может агрессивно сглаживать
  высоту — тогда наборы и уклоны в FIT систематически занижены, и
  оценке параметров (Crr/CdA через градиенты) доверять сложнее.
  DEM (Terrarium) — независимая опора с реальным рельефом.

  Метрика: сравниваются ПРИРАЩЕНИЯ высоты на шаге ~100 м вдоль пути
  (абсолютный оффсет барометра и DEM не важен — он сокращается).
  Коэффициент K = наклон робастной регрессии ΔFIT на ΔDEM через ноль:
    K ≈ 1  — амплитуда рельефа в FIT честная;
    K < 1  — FIT сглажен (потерял K-долю амплитуды);
    K > 1  — FIT шумнее рельефа (редко: плохой барометр/GPS-высота).
  Корреляция r страхует от бессмысленного K при рассинхроне трека
  с рельефом (плохой GPS, туннели). Шаг 100 м выбран больше пиксела
  DEM (~19 м на z13) и его метровой квантизации, но меньше
  характерного рельефа. }
procedure TRoutesPage.ComputeDemComparison;
const
  STEP_M = 100.0;
  GRADE_HALF = 2;      { окно уклона: ±2 узла = 5 точек, база 400 м }
  GRADE_MIN  = 0.010;  { |уклон DEM| ниже 1% — рельеф незначим }
  SEG_M      = 1000.0; { база покилометрового разбиения }
var
  I, K, NNodes, ChunkEnd, I0, I1, NSig: Integer;
  DistAcc: Double;
  DemAll, PathDist: array of Double;
  TileCache: TGeoTileCache;
  Model: TTileModel;
  T, CurTile: TGeoTileId;
  HaveTile, HaveLastY: Boolean;
  CV, WV: TVector3;
  CenX, CenZ, LastY, SurfY: Single;
  { пространственный хэш вершин ground-мешей текущего тайла }
  HashX, HashZ, HashY: array of Single;
  HashHead: array of Integer;    { NB×NB голов списков }
  HashNext: array of Integer;
  HMinX, HMinZ, HInv: Single;
  HNB: Integer;
  { way-индекс: вершины с OsmId<>0, отсортированы по id — высота
    зелёной сферы берётся с вершин ИМЕННО снапнутой way (настил моста
    несёт id мостовой way), без дистанц-гейта — как в
    MountFitSpheresForTile }
  HashId: array of Int64;
  WayIdx: array of Integer;      { индексы вершин, sort by HashId }
  WayN: Integer;

  { Хэш вершин ground-мешей тайла: ячейки BUCKET_M, связные списки.
    Семантика набора мешей — как у красных сфер (GROUND_MESH_KINDS). }
  procedure BuildGroundHash(AModel: TTileModel);
  const
    GROUND_KINDS = [smkTerrain, smkGrass, smkSurface, smkSand,
                    smkFarmland, smkForest];
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
      if not (AModel.Meshes[MI].Material in GROUND_KINDS) then Continue;
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
      if not (AModel.Meshes[MI].Material in GROUND_KINDS) then Continue;
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

    { way-индекс: сбор + shell-sort по HashId (вставками было O(n²)
      на десятках тысяч way-вершин) }
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

  { Ближайшая по XZ вершина СНАПНУТОЙ way (бинпоиск диапазона id в
    way-индексе; дистанция не гейтится — на плоском пролёте ближайшая
    вершина настила может быть далеко вдоль оси, но её Y корректен). }
  function HashWayY(AWay: Int64; LX, LZ: Single; out AY: Single): Boolean;
  var
    Lo, Hi, Mid, J: Integer;
    BestD2, D2: Single;
  begin
    Result := False;
    if (AWay = 0) or (WayN = 0) then Exit;
    AY := 0;
    { нижняя граница диапазона AWay }
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
    K, I: Integer;
    V, VW, SumW, Acc: Double;
  begin
    SetLength(R, AN);
    SetLength(W, AN);
    ANSig := 0;
    for K := 0 to AN - 1 do
      if Abs(AGB[K]) >= GRADE_MIN then
      begin
        R[ANSig] := AGF[K] / AGB[K];
        W[ANSig] := Abs(AGB[K]);
        Inc(ANSig);
      end;
    if ANSig < 10 then Exit(1.0);
    { сортировка пар вставками (значимых узлов — сотни) }
    for K := 1 to ANSig - 1 do
    begin
      V := R[K]; VW := W[K];
      I := K - 1;
      while (I >= 0) and (R[I] > V) do
      begin
        R[I + 1] := R[I];
        W[I + 1] := W[I];
        Dec(I);
      end;
      R[I + 1] := V; W[I + 1] := VW;
    end;
    SumW := 0;
    for K := 0 to ANSig - 1 do SumW := SumW + W[K];
    Acc := 0;
    Result := R[ANSig - 1];
    for K := 0 to ANSig - 1 do
    begin
      Acc := Acc + W[K];
      if Acc >= 0.5 * SumW then Exit(R[K]);
    end;
  end;

  { Знак числа для таблиц (флаг «+» в FPC Format не поддерживается). }
  function SgnF(const V: Double): String;
  begin
    if V >= 0 then
      Result := '+' + Format('%.1f', [V])
    else
      Result := '−' + Format('%.1f', [Abs(V)]);
  end;

var
  NodeFit, NodeDem: array of Double;
  L: TStringList;
  FS: TFormatSettings;
  LogPath: String;
  GF, GD, Ratio, RW, NodeDist: array of Double;
  NSeg: Integer;
  Sig, SXY, SXX, SYY, SX, SY, SRd, Coef, AscFit, AscDem, Corr: Double;
  SamplesDem: TRideSampleArray;
  EstDem: TRideEstimate;
  PtsDem: TRidePointResultArray;
  { зелёные сферы: снапнутый путь и высота с ленты/настила своей way }
  SnapPts: TRouteLatLonArray;
  SnapWays: TRouteWayIdArray;
  RoadAll, NodeRoad, GR: array of Double;
  HaveRoad: Boolean;
  EmuVirt: array of Double;
  EmuRes:  TEmuResultArray;
  EmuNote, EmuTxt, EmuCal: String;
  EmuMoving: Double;
  EmuMass, EmuCdA, EmuCrr: Double;
  TkEmu:   QWord;
  RouteWorldPts: array of TVector3;
  FullRes: TEmuResultArray;
  FullNote, FullTxt: String;
  { покилометровое разбиение: закономерность vs пертурбации }
  SegTxt, SegNote: String;
  SegCnt, SegI, S0, S1: Integer;
  SegSame, SegFSt, SegWSt: Integer;
  GrF, GrW, GrD, GrC, SegLen: Double;
  LayerOn: Boolean;
  { поправка физического FIT-слоя на треке (физика vs картинка) }
  NodeLL: array of TLatLon;
  PhysDelta: array of Double;   { Δ слоя на узле, м (0 = вне покрытия) }
  PhysCov, PhysI, PhysJ: Integer;
  PhysSort: array of Double;
  PhysTmp, PhysMed, PhysP90, PhysMax: Double;
  PhysSegMean: array of Double;
  PhysSegN: array of Integer;
  PhysSegTxt: String;
  PhysTopI: array of Integer;
  SamplesRoad: TRideSampleArray;
  EstRoad: TRideEstimate;
  PtsRoad: TRidePointResultArray;
  RoadOk: Boolean;
  KRoad: Double;
  NSigRoad: Integer;
begin
  if (Length(FDemRoute) < 3) or
     (Length(FDemFitAlt) <> Length(FDemRoute)) then Exit;

  { Путевая параметризация — ОДОМЕТРИЯ FIT (датчик/счисление головного
    устройства), а не эквирект-сумма GPS-точек: на полной остановке
    GPS дрожит на месте и надувает эквирект-путь километрами (реальный
    случай: привал 16 минут = +4.7 км фиктивного пути и полтора
    десятка мусорных узлов метрики). Одометрия на стоянке стоит —
    узлы там просто не создаются. }
  if Length(FDemDist) <> Length(FDemRoute) then Exit;
  SetLength(DemAll, Length(FDemRoute));
  SetLength(PathDist, Length(FDemRoute));
  for I := 0 to High(FDemRoute) do
    PathDist[I] := FDemDist[I] - FDemDist[0];

  { Высоты поверхности сгенерированного мира — ровно те, на которых
    сидят КРАСНЫЕ СФЕРЫ FIT-маршрута (MountFitSpheresForTile):
    ближайшая вершина ground-мешей тайла (Material в GROUND_KINDS —
    копия GROUND_MESH_KINDS из Osm3dStreamingMap, он в implementation).
    Тайлы читаются с диска штатным TGeoTileCache по параметрам сессии
    прогрева; координаты вершин тайл-локальны, центр тайла =
    Proj.Project(Grid.TileCenter(T)) — формула GeoCellCentre
    сборщика. Для скорости — пространственный хэш вершин (ячейка
    BUCKET_M): маршрут по тайлу это сотни точек × десятки тысяч
    вершин, лобовой перебор повесил бы кадр на десятки секунд. }
  if (FWarmSession = nil) or (FWarmProj = nil) then Exit;
  TileCache := TGeoTileCache.Create(FWarmSession.CacheRoot,
    FWarmSession.GenHash, TStudioSettings.Defaults.HeightmapZoom,
    0, FWarmProj.Origin.Lat);
  Model := nil;
  HaveTile := False;
  LastY := 0;
  HaveLastY := False;
  try
    for I := 0 to High(FDemRoute) do
    begin
      T := TileCache.Grid.TileAt(FDemRoute[I]);
      if (not HaveTile) or (not T.Equals(CurTile)) then
      begin
        FreeAndNil(Model);
        CurTile := T;
        HaveTile := True;
        if not TileCache.TryLoad(T, Model) then
        begin
          Model := nil;
          Logger.Info('[Routes] Нет тайла в кэше: ' + T.ToString);
        end;
        if Model <> nil then
        begin
          CV := FWarmProj.Project(TileCache.Grid.TileCenter(T), 0);
          CenX := CV.X;
          CenZ := CV.Z;
          { та же коррекция, что у боевых тайлов — красные/зелёные
            каналы после неё }
          if (FWarmSession <> nil) and
             (FWarmSession.Map.FitCorrection <> nil) and
             FWarmSession.Map.FitCorrection.LevelLocked then
            FWarmSession.Map.FitCorrection.ApplyToTileModel(
              Model, CenX, CenZ);
          BuildGroundHash(Model);
        end;
      end;
      if Model <> nil then
      begin
        WV := FWarmProj.Project(FDemRoute[I], 0);
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
        DemAll[I] := FDemFitAlt[I];
    end;

    { ── Третий канал: зелёные сферы (притянутый путь) ──
      SnappedRoute параллелен исходному маршруту; высота — с вершин
      ИМЕННО снапнутой way (настил моста несёт её id), фолбэк —
      ближайший рельеф в снапнутой точке. Семантика зелёного
      оверлея MountFitSpheresForTile один в один. }
    HaveRoad := False;
    SnapPts := FWarmSession.Map.SnappedRoute;
    SnapWays := FWarmSession.Map.SnappedRouteWays;
    if (Length(SnapPts) = Length(FDemRoute)) and
       (Length(SnapWays) = Length(FDemRoute)) then
    begin
      SetLength(RoadAll, Length(FDemRoute));
      HaveTile := False;
      HaveLastY := False;
      LastY := 0;
      for I := 0 to High(FDemRoute) do
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
            CV := FWarmProj.Project(TileCache.Grid.TileCenter(T), 0);
            CenX := CV.X;
            CenZ := CV.Z;
            if (FWarmSession <> nil) and
               (FWarmSession.Map.FitCorrection <> nil) and
               FWarmSession.Map.FitCorrection.LevelLocked then
              FWarmSession.Map.FitCorrection.ApplyToTileModel(
                Model, CenX, CenZ);
            BuildGroundHash(Model);
          end;
        end;
        if Model <> nil then
        begin
          WV := FWarmProj.Project(SnapPts[I], 0);
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
          RoadAll[I] := FDemFitAlt[I];
      end;
      HaveRoad := True;
    end
    else
      Logger.Info(Format(
        '[Routes] Снап не параллелен маршруту (%d/%d/%d) — '
        + 'зелёный проход пропущен',
        [Length(SnapPts), Length(SnapWays), Length(FDemRoute)]));
  finally
    FreeAndNil(Model);
    TileCache.Free;
  end;

  { Узлы каждые ~STEP_M метров вдоль пути. }
  SetLength(NodeFit, Length(FDemRoute));
  SetLength(NodeDem, Length(FDemRoute));
  SetLength(NodeRoad, Length(FDemRoute));
  SetLength(NodeDist, Length(FDemRoute));
  SetLength(NodeLL, Length(FDemRoute));
  SetLength(PhysDelta, Length(FDemRoute));
  NNodes := 0;
  DistAcc := -STEP_M;   { первая точка становится узлом сразу }
  for I := 0 to High(FDemRoute) do
    if PathDist[I] - DistAcc >= STEP_M then
    begin
      DistAcc := PathDist[I];
      NodeFit[NNodes] := FDemFitAlt[I];
      NodeDem[NNodes] := DemAll[I];
      if HaveRoad then NodeRoad[NNodes] := RoadAll[I]
      else NodeRoad[NNodes] := DemAll[I];
      NodeDist[NNodes] := PathDist[I];
      NodeLL[NNodes]  := FDemRoute[I];
      { Поправка физического слоя на узле: Δ = Y_физики − Y_сырой
        поверхности — ровно то, что GroundYAt добавит к треугольнику
        под колесом. 0 = узел вне покрытия слоя. }
      if (FWarmSession <> nil) and
         (FWarmSession.Map.FitPhysLayer <> nil) and
         FWarmSession.Map.FitPhysLayer.Active then
        PhysDelta[NNodes] :=
          FWarmSession.Map.FitPhysLayer.CorrectHeightGeo(
            FDemRoute[I], NodeDem[NNodes]) - NodeDem[NNodes]
      else
        PhysDelta[NNodes] := 0;
      Inc(NNodes);
    end;
  if NNodes < 10 then Exit;

  { ── Локальные уклоны по НЕСКОЛЬКИМ точкам ──────────────────────
    Расхождение считается не в абсолютных метрах, а как отношение
    ТЕКУЩЕГО уклона: grade = МНК-наклон высоты по окну из
    GRADE_HALF·2+1 узлов (±200 м базы при шаге 100 м) — отдельно для
    FIT и для DEM. Отношение gF/gD осмысленно только на значимом
    рельефе (|gD| ≥ GRADE_MIN, иначе делим шум на шум); итоговый
    коэффициент — взвешенная медиана отношений (вес |gD|): K≈1 —
    уклоны FIT честные, K<1 — теряется (1−K) доля крутизны. }
  NSeg := NNodes - 1;
  SetLength(GF, NNodes);
  SetLength(GD, NNodes);
  SetLength(GR, NNodes);
  for K := 0 to NNodes - 1 do
  begin
    I0 := Max(K - GRADE_HALF, 0);
    I1 := Min(K + GRADE_HALF, NNodes - 1);
    { МНК-наклон по узлам [I0..I1]: x — номер узла (шаг ≈ STEP_M). }
    SX := 0; SY := 0; SXX := 0; SXY := 0; SYY := 0;
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

  { Наборы — по узловым приращениям (сводка, как раньше). }
  AscFit := 0;
  AscDem := 0;
  for K := 0 to NSeg - 1 do
  begin
    if NodeFit[K + 1] > NodeFit[K] then
      AscFit := AscFit + (NodeFit[K + 1] - NodeFit[K]);
    if NodeDem[K + 1] > NodeDem[K] then
      AscDem := AscDem + (NodeDem[K + 1] - NodeDem[K]);
  end;

  { Отношения уклонов кан/опоры: мир и (если есть) дорога — одной
    функцией WMedianRatio (см. вложенные подпрограммы). }
  Coef := WMedianRatio(GF, GD, NNodes, NSig);
  if HaveRoad then
    KRoad := WMedianRatio(GF, GR, NNodes, NSigRoad)
  else
  begin
    KRoad := 0;
    NSigRoad := 0;
  end;
  if NSig < 10 then
  begin
    AddStatRow(UiText('Gradient factor'),
      UiText('terrain is too flat for comparison'));
    Coef := 1.0;
    Corr := 0.0;
  end
  else
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
      Corr := SXY / Sqrt(SXX * SYY)
    else
      Corr := 0;
  end;

  AddStatRow(UiText('Ascent (world)'), Format(UiText('+%.0f m'), [AscDem]));
  if NSig >= 10 then
    AddStatRow(UiText('Gradient factor'), Format(
      UiText('%.2f (%d of %d points, corr. %.2f)'),
      [Coef, NSig, NNodes, Corr]));
  if HaveRoad and (NSigRoad >= 10) then
    AddStatRow(UiText('K (road)'), Format(UiText('%.2f (%d points)'),
      [KRoad, NSigRoad]));
  if (NSig >= 10) and (Corr < 0.5) then
    AddStatRow(UiText('Warning'),
      UiText('track and terrain do not align well; the factor is unreliable'))
  else if (NSig >= 10) and (Coef < 0.7) then
    AddStatRow(UiText('Warning'), Format(
      UiText('FIT gradients are too low (~%.0f%% of terrain gradient)'),
      [Coef * 100]))
  else if (NSig >= 10) and (Coef > 1.3) then
    AddStatRow(UiText('Warning'), UiText('FIT gradients exceed terrain gradients (elevation noise?)'));

  Logger.Info(Format(
    '[Routes] DEM-сверка: узлов %d, K=%.3f, corr=%.3f, '
    + 'набор FIT +%.0f / DEM +%.0f м',
    [NNodes, Coef, Corr, AscFit, AscDem]));

  { ── Разбиение на участки по 1 км ────────────────────────────────
    Поузловой шум (база 100 м) усредняется километровым перепадом:
    устойчивое отклонение уклона мира от FIT — закономерность рельефа
    (модель высот мира систематически положит/крутит), а чередующийся
    знак — пертурбации (шум снапа/вершин). Уклон участка = перепад
    высот на нём / длина; «мир» — дорога при наличии снапа (как в
    эмуляции), иначе поверхность. }
  SegTxt := '';
  if NNodes >= 10 then
  begin
    { активен ли физический слой — тогда в таблице колонка сдвига уклона }
    LayerOn := (FWarmSession <> nil) and
               (FWarmSession.Map.FitPhysLayer <> nil) and
               FWarmSession.Map.FitPhysLayer.Active;
    if LayerOn then
      SegTxt := UiText('══ 1 km sections: FIT / world gradient, layer = gradient offset, pp ══') + LineEnding
    else
      SegTxt := UiText('══ 1 km sections: FIT / world gradient, pp ══') + LineEnding;
    SegSame := 0; SegFSt := 0; SegWSt := 0;
    SegCnt := Trunc(NodeDist[NNodes - 1] / SEG_M) + 1;
    S1 := 0;
    for SegI := 0 to SegCnt - 1 do
    begin
      S0 := S1;
      while (S1 < NNodes - 1) and
            (NodeDist[S1 + 1] <= (SegI + 1) * SEG_M) do Inc(S1);
      SegLen := NodeDist[S1] - NodeDist[S0];
      if SegLen < 100 then Continue;   { хвост <100 м сливается с предыдущим }
      GrF := (NodeFit[S1]  - NodeFit[S0])  / SegLen;
      GrW := (NodeRoad[S1] - NodeRoad[S0]) / SegLen;
      GrD := (GrF - GrW) * 100.0;   { разность уклонов, процентные пункты }
      { сдвиг уклона от слоя: перепад Δ на концах участка / длину — на
        сколько п.п. физический профиль круче (+) / положе (−) видимого
        меша на этом километре; ровно это чувствует g·sin(θ) и FTMS }
      GrC := (PhysDelta[S1] - PhysDelta[S0]) / SegLen * 100.0;
      if Abs(GrD) < 1.0 then Inc(SegSame)
      else if GrD > 0 then Inc(SegFSt)
      else Inc(SegWSt);
      SegTxt := SegTxt + Format(UiText('  %2d–%2d km:  %s%% / %s%%   Δ %s pp'),
        [Round(NodeDist[S0] / SEG_M), Round(NodeDist[S1] / SEG_M),
         SgnF(GrF * 100), SgnF(GrW * 100), SgnF(GrD)]);
      if LayerOn then
        SegTxt := SegTxt + Format(UiText('   layer %s pp'), [SgnF(GrC)]);
      if GrD >= 2.0 then SegTxt := SegTxt + UiText('  ← FIT steeper')
      else if GrD <= -2.0 then SegTxt := SegTxt + UiText('  ← world steeper');
      SegTxt := SegTxt + LineEnding;
    end;
    if SegSame + SegFSt + SegWSt > 0 then
    begin
      SegTxt := SegTxt + Format(
        UiText('  Match (|Δ|<1 pp): %d;  FIT steeper: %d;  world steeper: %d.'),
        [SegSame, SegFSt, SegWSt]);
      if SegFSt >= 2 * (SegWSt + 1) then
        SegNote := UiText('trend: world terrain is flatter than recorded terrain')
      else if SegWSt >= 2 * (SegFSt + 1) then
        SegNote := UiText('trend: world terrain is steeper than recorded terrain')
      else
        SegNote := UiText('no systematic offset; differences appear random');
      SegTxt := SegTxt + LineEnding + '  ' + SegNote;
      AddStatRow(UiText('1 km sections'), Format(UiText('%d/%d/%d (≈/FIT/world)'),
        [SegSame, SegFSt, SegWSt]));
    end;
  end;

  { ── Поправка FIT-слоя (физика) на треке ──────────────────────────
    Меши сырые, поэтому расхождение физики с картинкой = поправка слоя
    (CorrectHeightGeo − сырая поверхность) на узлах трека. Медиана/p90/
    макс |Δ| — масштаб; топ-участки по средней Δ километра — ГДЕ райдер
    едет выше/ниже видимого мира (настилы мостов, нивелированные ямы). }
  if (FWarmSession <> nil) and
     (FWarmSession.Map.FitPhysLayer <> nil) and
     FWarmSession.Map.FitPhysLayer.Active then
  begin
    PhysCov := 0; PhysMax := 0;
    SetLength(PhysSort, NNodes);
    for PhysI := 0 to NNodes - 1 do
    begin
      PhysSort[PhysI] := Abs(PhysDelta[PhysI]);
      if Abs(PhysDelta[PhysI]) > 0.05 then Inc(PhysCov);
      if Abs(PhysDelta[PhysI]) > PhysMax then
        PhysMax := Abs(PhysDelta[PhysI]);
    end;
    { сортировка вставками (узлов — сотни) }
    for PhysI := 1 to NNodes - 1 do
    begin
      PhysTmp := PhysSort[PhysI];
      PhysJ := PhysI - 1;
      while (PhysJ >= 0) and (PhysSort[PhysJ] > PhysTmp) do
      begin
        PhysSort[PhysJ + 1] := PhysSort[PhysJ];
        Dec(PhysJ);
      end;
      PhysSort[PhysJ + 1] := PhysTmp;
    end;
    PhysMed := PhysSort[NNodes div 2];
    PhysP90 := PhysSort[Trunc(NNodes * 0.9)];

    { средняя Δ по 1-км сегментам }
    SegCnt := Trunc(NodeDist[NNodes - 1] / SEG_M) + 1;
    SetLength(PhysSegMean, SegCnt);
    SetLength(PhysSegN, SegCnt);
    for PhysI := 0 to SegCnt - 1 do
    begin
      PhysSegMean[PhysI] := 0;
      PhysSegN[PhysI] := 0;
    end;
    for PhysI := 0 to NNodes - 1 do
    begin
      SegI := Trunc(NodeDist[PhysI] / SEG_M);
      if SegI > SegCnt - 1 then SegI := SegCnt - 1;
      PhysSegMean[SegI] := PhysSegMean[SegI] + PhysDelta[PhysI];
      Inc(PhysSegN[SegI]);
    end;
    for PhysI := 0 to SegCnt - 1 do
      if PhysSegN[PhysI] > 0 then
        PhysSegMean[PhysI] := PhysSegMean[PhysI] / PhysSegN[PhysI];

    { топ-3 сегмента по |средней Δ| }
    SetLength(PhysTopI, 3);
    PhysTopI[0] := -1; PhysTopI[1] := -1; PhysTopI[2] := -1;
    for PhysI := 0 to SegCnt - 1 do
      if (PhysSegN[PhysI] > 0) and
         (Abs(PhysSegMean[PhysI]) > 0.05) then
      begin
        if (PhysTopI[0] < 0) or
           (Abs(PhysSegMean[PhysI]) > Abs(PhysSegMean[PhysTopI[0]])) then
        begin
          PhysTopI[2] := PhysTopI[1];
          PhysTopI[1] := PhysTopI[0];
          PhysTopI[0] := PhysI;
        end
        else if (PhysTopI[1] < 0) or
           (Abs(PhysSegMean[PhysI]) > Abs(PhysSegMean[PhysTopI[1]])) then
        begin
          PhysTopI[2] := PhysTopI[1];
          PhysTopI[1] := PhysI;
        end
        else if (PhysTopI[2] < 0) or
           (Abs(PhysSegMean[PhysI]) > Abs(PhysSegMean[PhysTopI[2]])) then
          PhysTopI[2] := PhysI;
      end;

    SegTxt := SegTxt + LineEnding + LineEnding
      + UiText('══ FIT layer correction (physics) along the track ══') + LineEnding
      + Format(UiText('  coverage: %d%% of points (|Δ|>5 cm);  |Δ|: median %.2f m, ')
        + UiText('p90 %.2f m, max %.2f m'),
        [Round(100.0 * PhysCov / NNodes), PhysMed, PhysP90, PhysMax]);
    PhysSegTxt := '';
    for PhysJ := 0 to 2 do
      if PhysTopI[PhysJ] >= 0 then
      begin
        if PhysSegTxt <> '' then PhysSegTxt := PhysSegTxt + ';  ';
        PhysSegTxt := PhysSegTxt + Format(UiText('%d–%d km %s m'),
          [PhysTopI[PhysJ], PhysTopI[PhysJ] + 1,
           SgnF(PhysSegMean[PhysTopI[PhysJ]])]);
      end;
    if PhysSegTxt <> '' then
      SegTxt := SegTxt + LineEnding + UiText('  largest offsets: ') + PhysSegTxt
        + UiText('  (+ physics above rendered surface)');
    if PhysCov = 0 then
      SegTxt := SegTxt + LineEnding
        + UiText('  layer does not cover the track; physics = uncorrected world');
  end;

  { Лог анализа высот — рядом с FIT (<имя>-heights.csv): шапка с
    итогами и таблица по всем точкам с обеими высотами. }
  if FFitUrl <> '' then
  begin
    FS := DefaultFormatSettings;
    FS.DecimalSeparator := '.';
    LogPath := ChangeFileExt(URIToFilenameSafe(FFitUrl), '')
      + '-heights.csv';
    L := TStringList.Create;
    try
      L.Add('# heights log: FIT vs world surface (red-sphere ground, generated tiles)');
      L.Add('# source: ' + ExtractFileName(URIToFilenameSafe(FFitUrl)));
      if (FWarmSession <> nil) and
         (FWarmSession.Map.FitCorrection <> nil) and
         FWarmSession.Map.FitCorrection.LevelLocked then
        L.Add('# surf/road heights AFTER fit-correction (level-locked)');
      L.Add(Format('# K_grade_road=%.3f road_sig=%d', [KRoad, NSigRoad], FS));
      L.Add(Format('# K_grade_median=%.3f grade_corr=%.3f '
        + 'sig_nodes=%d/%d ascent_fit=%.0f ascent_dem=%.0f '
        + 'step_m=%.0f grade_win=%d grade_min=%.3f',
        [Coef, Corr, NSig, NNodes, AscFit, AscDem,
         STEP_M, GRADE_HALF * 2 + 1, GRADE_MIN], FS));
      L.Add('idx;lat;lon;dist_m;alt_fit_m;alt_surf_m;alt_road_m;'
        + 'grade_fit;grade_surf');
      { узловые уклоны интерполируются на точки по дистанции }
      K := 0;
      for I := 0 to High(FDemRoute) do
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
        L.Add(Format('%d;%.7f;%.7f;%.1f;%.2f;%.2f;%.2f;%.4f;%.4f',
          [I, FDemRoute[I].Lat, FDemRoute[I].Lon, PathDist[I],
           FDemFitAlt[I], DemAll[I], SRd,
           GF[Min(K, NNodes - 1)] * (1 - Sig)
             + GF[Min(K + 1, NNodes - 1)] * Sig,
           GD[Min(K, NNodes - 1)] * (1 - Sig)
             + GD[Min(K + 1, NNodes - 1)] * Sig], FS));
      end;
      try
        L.SaveToFile(LogPath);
        AddStatRow(UiText('Elevation log'), ExtractFileName(LogPath));
        Logger.Info('[Routes] Лог высот: ' + LogPath);
      except
        on E: Exception do
          Logger.Info('[Routes] Лог высот не записан: ' + E.Message);
      end;
    finally
      L.Free;
    end;
  end;

  { ── Расчёт по обеим высотам, вывод попарно ──
    Те же сэмплы, та же конфигурация; меняется только канал высоты:
    FIT (полотно, барометр) против сгенерированного мира (
    поверхность мира — высоты красных сфер). Пара показывает чувствительность
    оценки к высоте: у более правдивого канала RMS-невязки меньше и
    параметры физичнее. }
  if FFitEstOk and (Length(FDemSamples) = Length(DemAll)) then
  begin
    SetProgress(UiText('Estimating from the world surface…'));
    SamplesDem := Copy(FDemSamples, 0, Length(FDemSamples));
    for I := 0 to High(SamplesDem) do
      SamplesDem[I].AltM := DemAll[I];
    RoadOk := False;
    if HaveRoad then
    begin
      SetProgress(UiText('Estimating from the snapped route…'));
      SamplesRoad := Copy(FDemSamples, 0, Length(FDemSamples));
      for I := 0 to High(SamplesRoad) do
        SamplesRoad[I].AltM := RoadAll[I];
      RoadOk := EstimateRideParameters(SamplesRoad, BuildEstimatorCfg,
        EstRoad, PtsRoad);
    end;
    if EstimateRideParameters(SamplesDem, BuildEstimatorCfg,
      EstDem, PtsDem) then
    begin
      if RoadOk then
        SetEstimate(
          UiText('══ Three elevation sources: FIT / world / road ══')
            + LineEnding +
          Format(UiText('  Mass: %.1f±%.1f / %.1f±%.1f / %.1f±%.1f kg'),
            [FFitEst.MassKg, FFitEst.MassCi95,
             EstDem.MassKg, EstDem.MassCi95,
             EstRoad.MassKg, EstRoad.MassCi95]) + LineEnding +
          Format(UiText('  CdA:   %.3f±%.3f / %.3f±%.3f / %.3f±%.3f m²'),
            [FFitEst.CdA, FFitEst.CdACi95,
             EstDem.CdA, EstDem.CdACi95,
             EstRoad.CdA, EstRoad.CdACi95]) + LineEnding +
          Format('  Crr:   %.4f±%.4f / %.4f±%.4f / %.4f±%.4f',
            [FFitEst.Crr, FFitEst.CrrCi95,
             EstDem.Crr, EstDem.CrrCi95,
             EstRoad.Crr, EstRoad.CrrCi95]) + LineEnding +
          Format(UiText('  Pedalling RMS: %.0f / %.0f / %.0f W'),
            [FFitEst.RmsPedalW, EstDem.RmsPedalW,
             EstRoad.RmsPedalW]) + LineEnding +
          Format(UiText('  Coasting RMS:  %.1f / %.1f / %.1f N'),
            [FFitEst.RmsCoastN, EstDem.RmsCoastN,
             EstRoad.RmsCoastN]) + LineEnding +
          LineEnding + FFitReport)
      else
        SetEstimate(
          UiText('══ Two elevation sources: FIT / world ══') + LineEnding +
          Format(UiText('  Mass: %.1f ± %.1f  /  %.1f ± %.1f kg'),
            [FFitEst.MassKg, FFitEst.MassCi95,
             EstDem.MassKg, EstDem.MassCi95]) + LineEnding +
          Format(UiText('  CdA:   %.3f ± %.3f  /  %.3f ± %.3f m²'),
            [FFitEst.CdA, FFitEst.CdACi95,
             EstDem.CdA, EstDem.CdACi95]) + LineEnding +
          Format('  Crr:   %.4f ± %.4f  /  %.4f ± %.4f',
            [FFitEst.Crr, FFitEst.CrrCi95,
             EstDem.Crr, EstDem.CrrCi95]) + LineEnding +
          Format(UiText('  Pedalling RMS: %.0f / %.0f W'),
            [FFitEst.RmsPedalW, EstDem.RmsPedalW]) + LineEnding +
          Format(UiText('  Coasting RMS:  %.1f / %.1f N'),
            [FFitEst.RmsCoastN, EstDem.RmsCoastN]) + LineEnding +
          LineEnding + FFitReport);
    end
    else
      SetEstimate(FFitReport + LineEnding + LineEnding +
        UiText('World surface estimate: ') + EstDem.Message);
  end;

  { ── Эмуляция прохождения всеми режимами уклона ──
    Мощность и тормоза — из реального заезда по дистанции; физика шага —
    игровая ComputeCyclingAcceleration; уклон — по-разному в каждом режиме
    (геометрия мира / реальный / плавная поправка / интегральный).
    Профиль мира: притянутый путь (дорога), если снап есть — по нему игра
    и едет; иначе поверхность. Стартовые параметры райдера — из оценки по
    FIT-каналу (FFitEst), но перед прогоном они калибруются Nelder–Mead'ом
    по режиму «реальный уклон» (см. RideEmulator): «подмена» становится
    эталонной, а сравнение остальных режимов — честным. Блок калибровки
    (EmuCal) печатается перед таблицей режимов. }
  if FFitEstOk and (Length(FFitPts) = Length(FDemSamples))
     and (Length(DemAll) = Length(FDemSamples)) then
  begin
    SetProgress(UiText('Simulating the ride (4 modes)…'));
    if HaveRoad and (Length(RoadAll) = Length(FDemSamples)) then
    begin
      SetLength(EmuVirt, Length(RoadAll));
      for I := 0 to High(RoadAll) do EmuVirt[I] := RoadAll[I];
    end
    else
    begin
      SetLength(EmuVirt, Length(DemAll));
      for I := 0 to High(DemAll) do EmuVirt[I] := DemAll[I];
    end;
    TkEmu := GetTickCount64;
    EmuMass := FFitEst.MassKg;
    EmuCdA  := FFitEst.CdA;
    EmuCrr  := FFitEst.Crr;
    if EmulateRideModes(FDemSamples, FFitPts, EmuVirt,
         EmuMass, EmuCdA, EmuCrr,
         BuildEstimatorCfg.DrivetrainEff, True,
         EmuRes, EmuMoving, EmuCal, EmuNote) then
    begin
      EmuTxt := EmuCal + FormatEmuResults(EmuRes, EmuMoving)
        + '  (' + EmuNote + ')';
      LogOsm(Format('эмуляция прохождения: %d мс', [GetTickCount64 - TkEmu]));
      LogOsm(EmuTxt);
      if Assigned(FLabelEstimate) then
        SetEstimate(FLabelEstimate.Caption + LineEnding + LineEnding + EmuTxt)
      else
        SetEstimate(EmuTxt);
      for I := 0 to High(EmuRes) do
        if EmuRes[I].Finished then
          AddStatRow(UiText('Sim: ') + EMU_MODE_NAMES[EmuRes[I].Mode],
            Format(UiText('%.0f:%.2d (%s%.0f s)'),
              [Int(EmuRes[I].TimeSec / 60), Round(EmuRes[I].TimeSec) mod 60,
               BoolToStr(EmuRes[I].TimeSec >= EmuMoving, '+', '−'),
               Abs(EmuRes[I].TimeSec - EmuMoving)]))
        else
          AddStatRow(UiText('Sim: ') + EMU_MODE_NAMES[EmuRes[I].Mode], UiText('did not finish'));
    end
    else
      LogOsm('эмуляция: ' + EmuNote);
    { ── Полная эмуляция на физике игры (колёса, курс, повороты) ── }
    SetLength(RouteWorldPts, Length(FDemRoute));
    for I := 0 to High(FDemRoute) do
      RouteWorldPts[I] := FWarmProj.Project(FDemRoute[I], 0);
    if EmulateRideFull(FDemSamples, FFitPts, EmuVirt, RouteWorldPts,
         EmuMass, EmuCdA, EmuCrr, BuildEstimatorCfg.DrivetrainEff,
         FullRes, FullNote) then
    begin
      FullTxt := FormatEmuResults(FullRes, EmuMoving,
        UiText('══ Full simulation (game physics: wheels, heading, turns) ══'))
        + '  (' + FullNote + ')';
      LogOsm(FullTxt);
      if Assigned(FLabelEstimate) then
        SetEstimate(FLabelEstimate.Caption + LineEnding + LineEnding + FullTxt)
      else
        SetEstimate(FullTxt);
    end
    else
      LogOsm('полная эмуляция пропущена: ' + FullNote);
    SetProgress('');
  end;

  { Покилометровое разбиение — в конец текста оценки (и в отчёт
    fullstats, который из него собирается). Дата/время старта — из
    содержимого FIT (RouteStartUTC), никогда из имени файла. }
  if (FDemStartUTC > 0) and Assigned(FLabelEstimate) then
    SetEstimate(FLabelEstimate.Caption + LineEnding + LineEnding +
      UiText('Ride started (UTC): ') +
      FormatDateTime('yyyy-mm-dd hh:nn:ss', FDemStartUTC));
  if SegTxt <> '' then
  begin
    LogOsm(SegTxt);
    if Assigned(FLabelEstimate) then
      SetEstimate(FLabelEstimate.Caption + LineEnding + LineEnding + SegTxt)
    else
      SetEstimate(SegTxt);
  end;


end;

{ ── Совместный анализ всех маршрутов папки ─────────────────────────── }

procedure TRoutesPage.RunMultiAnalysis;
var
  Rides: array of TRideSampleArray;
  Names: array of String;
  Fit: TFitFile;
  Cfg: TRideEstimatorConfig;
  MEst: TMultiRideEstimate;
  I, NOk: Integer;
  Txt: String;
begin
  ClearStats;
  FDemPending := False;
  SetLength(Rides, FFileNames.Count);
  SetLength(Names, FFileNames.Count);
  NOk := 0;
  for I := 0 to FFileNames.Count - 1 do
  begin
    Fit := NewRouteParserForFile(UserRoutesDir + FFileNames[I]);
    try
      if Fit.LoadFromFile(UserRoutesDir + FFileNames[I]) and
         (Length(Fit.RouteLatLon) >= 2) then
      begin
        Rides[NOk] := Fit.ToRideSamples;
        Names[NOk] := FFileNames[I];
        Inc(NOk);
      end
      else
        Logger.Info('[Routes] Пропущен (не читается): ' + FFileNames[I]);
    finally
      Fit.Free;
    end;
  end;
  SetLength(Rides, NOk);
  if NOk < 2 then
  begin
    SetProgress(UiText('Fewer than two usable routes.'));
    Exit;
  end;

  Cfg := DefaultRideEstimatorConfig;
  if VeloSite.HasCachedProfile and
     (VeloSite.CachedProfile.WeightKg > 20) then
    Cfg.RiderProfileMassKg := VeloSite.CachedProfile.WeightKg;

  if not EstimateMultiRideParameters(Rides, Cfg, MEst) then
  begin
    SetProgress(UiText('Combined analysis: ') + MEst.Message);
    Exit;
  end;

  AddStatHeader(Format(UiText('Combined across %d routes'), [NOk]));
  AddStatRow(UiText('Mass'), Format(UiText('%.1f ± %.1f kg'),
    [MEst.MassKg, MEst.MassCI95]));
  AddStatRow('CdA', Format(UiText('%.3f ± %.3f m²'),
    [MEst.CdA, MEst.CdACI95]));

  Txt := '';
  for I := 0 to NOk - 1 do
  begin
    Txt := Txt + Format('%s:  Crr %.4f ± %.4f',
      [Names[I], MEst.RideCrr[I], MEst.RideCrrCI95[I]]);
    if MEst.RideWindMs[I] > 0.05 then
      Txt := Txt + Format(UiText('   wind %.1f m/s, from %.0f°'),
        [MEst.RideWindMs[I], MEst.RideWindDirRad[I] * 180 / Pi]);
    Txt := Txt + LineEnding;
  end;
  SetEstimate(Txt);

  SetProgress('');
  Logger.Info(Format('[Routes] Совместный анализ: %d маршрутов, '
    + 'масса %.1f, CdA %.3f', [NOk, MEst.MassKg, MEst.CdA]));
end;

{ ── Пакетный режим --fitstats ────────────────────────────────────────
  Сценарий (запускается меню при старте, см. TViewMenu.Start): открыть
  FIT (анализ как простым кликом), нажать «Полную статистику», дождаться
  конца сверки/эмуляции, сохранить текст панели оценки в
  <имя fit>.fullstats.txt рядом с FIT и завершить приложение.
  Отчёт пишется ДО Application.Terminate: в TODO.txt числится зависание
  при завершении — даже если выход повиснет, отчёт уже на диске. }

var
  FBatchFitParsed: Boolean = False;
  FBatchFitPath:   String  = '';

{ Путь FIT из командной строки. Принимаются формы --fitstats=...,
  -fitstats=..., /fitstats=... и значение следующим аргументом; кавычки
  вокруг пути снимаются. CGE (Window.ParseParameters с
  ParseOnlyKnownOptions=True) неизвестные параметры игнорирует, поэтому
  достаём сами из ParamStr. }
function BatchFitStatsPath: String;

  function StripQuotes(const AValue: String): String;
  begin
    Result := AValue;
    if (Length(Result) >= 2) and (Result[1] = '"') and
       (Result[Length(Result)] = '"') then
      Result := Copy(Result, 2, Length(Result) - 2);
  end;

var
  I, P: Integer;
  S: String;
begin
  if FBatchFitParsed then
  begin
    Result := FBatchFitPath;
    Exit;
  end;
  FBatchFitParsed := True;
  FBatchFitPath := '';
  I := 1;
  while I <= ParamCount do
  begin
    S := ParamStr(I);
    if (Length(S) > 0) and (S[1] in ['-', '/']) then
    begin
      while (Length(S) > 0) and (S[1] in ['-', '/']) do
        Delete(S, 1, 1);
      P := Pos('=', S);
      if P > 0 then
      begin
        if SameText(Copy(S, 1, P - 1), 'fitstats') then
          FBatchFitPath := StripQuotes(Copy(S, P + 1, MaxInt));
      end
      else if SameText(S, 'fitstats') and (I < ParamCount) then
      begin
        Inc(I);
        FBatchFitPath := StripQuotes(ParamStr(I));
      end
      else if SameText(S, 'fitcorr') then
      begin
        FitHeightCorrectionCLI := True;
        Logger.Info('[Routes] --fitcorr: коррекция мешей по FIT/GPX включена');
      end;
    end;
    Inc(I);
  end;
  Result := FBatchFitPath;
end;

procedure TRoutesPage.StartBatchFullStats(const AFitPath: String);
begin
  FBatchMode := True;
  FBatchStage := 0;
  FBatchPath := AFitPath;
  FBatchWaitS := 0;
  FFullStatsDone := False;
  LogOsm('пакетный режим: --fitstats=' + AFitPath);
end;

procedure TRoutesPage.BatchUpdate(const SecondsPassed: Single);
begin
  if not FBatchMode then Exit;
  case FBatchStage of
    0: begin
         { Первый тик: анализ FIT + запуск полного прогона. Оба вызова
           синхронные и тяжёлые — окно на это время «замораживается»,
           как при обычных кликах по кнопкам. }
         FBatchStage := 1;   { дальше только ждём флаг }
         if not FileExists(FBatchPath) then
         begin
           BatchFinish(UiText('File not found: ') + FBatchPath);
           Exit;
         end;
         OpenAndAnalyzeFit(FilenameToURISafe(FBatchPath));
         if (FFitUrl = '') or (Length(FDemRoute) < 2) then
         begin
           BatchFinish('FIT не содержит валидного маршрута: ' + FBatchPath);
           Exit;
         end;
         FFullStatsDone := False;
         ClickFullStats(nil);
         if not FDemPending then
         begin
           BatchFinish('«Полная статистика» не стартовала (см. лог выше).');
           Exit;
         end;
         LogOsm('пакетный режим: прогон «Полной статистики» запущен');
       end;
    1: begin
         FBatchWaitS := FBatchWaitS + SecondsPassed;
         if FFullStatsDone then
           BatchFinish('')
         else if FBatchWaitS > 1200.0 then
           BatchFinish('Таймаут: полная статистика не завершилась за 20 минут.');
       end;
  end;
end;

procedure TRoutesPage.BatchFinish(const AErr: String);
var
  Rpt: TStringList;
  RptPath: String;
begin
  RptPath := ChangeFileExt(FBatchPath, '.fullstats.txt');
  Rpt := TStringList.Create;
  try
    Rpt.Add('Полная статистика маршрута (пакетный режим --fitstats)');
    Rpt.Add('FIT:  ' + FBatchPath);
    Rpt.Add('Дата: ' + FormatDateTime('yyyy-mm-dd hh:nn:ss', Now));
    Rpt.Add('');
    if AErr <> '' then
      Rpt.Add('ОШИБКА: ' + AErr)
    else
      Rpt.Add(FLabelEstimate.Caption);
    try
      Rpt.SaveToFile(RptPath);
      LogOsm('пакетный режим: отчёт записан — ' + RptPath);
    except
      on E: Exception do
        LogOsm('пакетный режим: НЕ УДАЛОСЬ записать отчёт ' + RptPath
          + ': ' + E.Message);
    end;
  finally
    Rpt.Free;
  end;
  FBatchMode := False;
  if AErr <> '' then
  begin
    LogOsm('пакетный режим: завершение с ошибкой — ' + AErr);
    ExitCode := 2;
  end
  else
    LogOsm('пакетный режим: успешно, выход');
  Application.Terminate;
end;

end.
