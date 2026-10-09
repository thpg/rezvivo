{ GameViewMenu — главный экран приложения.

  Меню — вертикальная колонка плашек (TMenuTile) слева, ведущих в
  подэкраны: Маршруты, Устройства, Байкфит, Тренировки, Профиль,
  События. Клик по плашке открывает страницу раздела: все разделы —
  встроенные вкладки в правой части меню (TMenuEmbeddedPage в
  FPageHost). Страница «Маршруты» открыта сразу после запуска (кроме
  CLI-режимов --fitstats/--freeride).

  Библиотека карт (data/maps + map.json) упразднена: FIT-маршруты
  живут в [exe]/users/<ник>/routes/ и управляются страницей «Маршруты»
  (GameViewMapEditor). Заезд запускается кнопкой «Ехать» на странице
  «Маршруты» — стриминг по выбранному FIT (TRoutesPage.SelectedFitPath). }
unit GameViewMenu;

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }

{$mode objfpc}{$H+}
{$codepage UTF8}

interface

uses GameMenuTheme,
  Classes, SysUtils, fpjson, WorkoutFile, GameViewStart,
  CastleComponentSerialize, CastleUIControls, CastleControls,
  CastleVectors, CastleColors, CastleKeysMouse, GameGlobeMap,
  GameMenuTile,GameUiNavigation,GameRideRoomsUI,GameTravel,GameTravelSelector,GameExploreMap,
  GameViewMapEditor,   { TRoutesPage — встроенная страница «Маршруты» }
  GameViewDevices,     { TDevicesPage — встроенная страница «Устройства» }
  GameViewBikeFit,     { TBikeFitPage — встроенная страница «Байкфит» }
  GameViewEvents,      { TEventsPage — встроенная страница «События» }
  GameViewTraining,    { TTrainingPage — встроенная страница «Тренировки» }
  GameViewRouteLibrary, GameViewSchedule,
  GameViewRouteCreator, GameViewDreamWorld,
  GameViewProfile;     { TProfilePage — встроенная страница «Профиль» }

type
  TViewMenu = class(TCastleView)
  published
    Background: TCastleImageControl;
    LabelTitle: TCastleLabel;
    ButtonQuit: TCastleButton;
    TilesHost:  TCastleUserInterface;
    MapSidebar: TCastleRectangleControl;
    LabelMapsHeader: TCastleLabel;
    MapsScroll: TCastleScrollView;
    ButtonMapEditor: TCastleButton;
  private
    FKeyboard:TUiKeyboardNavigation;
    FGlobe: TGlobeMap;
    FNavBackground: TCastleRectangleControl;
    FTopBar:TCastleRectangleControl;
    FTravelSelector:TTravelSelector;
    FWorldModeBar:TCastleHorizontalGroup;
    FWorldTrack,FWorldExplore:TMenuButton;
    FExplorePage:TExplorePage;
    procedure TravelChanged(Sender:TObject);
    procedure WorldModeChanged(Sender:TObject);
    procedure ShowWorldMode;
    procedure LaunchExplore(Sender:TObject);
  private
    FVersionButton:TMenuButton;
    FResumeButton, FEndRideButton, FDevicesSummary: TMenuButton;
    FSessionLabel: TCastleLabel;
    FRoomButton:TMenuButton;
    FRoomView:TViewRideRooms;
    procedure ClickRoom(Sender:TObject);
    procedure LaunchRoom(Sender:TObject);
    procedure RoomSignIn(Sender:TObject);
    procedure RoomChanged(Sender:TObject);
    procedure ClickVersion(Sender:TObject);
    procedure ClickResume(Sender: TObject);
    procedure ClickSettings(Sender: TObject);
    procedure RefreshRideControls;
  private
    FGlobeCredit: TCastleRectangleControl;
    { Правая область сплита: сюда встраиваются страницы разделов.
      FullSize с Border.Left = ширина колонки плашек. }
    FPageHost:   TCastleUserInterface;
    FPendingTab: String;
    FStartPage:TStartPage;
    FHistoryPage:THistoryPage;
    FSchedulePage:TSchedulePage;
    FTileSchedule:TMenuTile;
    FTileHome,FTileHistory,FTileAssistant:TMenuTile;
    FPendingWorkout:TWorkoutFile;
    FPendingReference:Double;
    FLaunchPane:TCastleRectangleControl;
    FLaunchDevices:TDevicesPage;
    FWaitingPower:Boolean;
    FPendingImport:String;
    FAutoRoute,FEndRequested:Boolean;
    FLaunchEditorWorkout:TWorkoutFile;
    FLaunchEditorReference:Double;
    FChildReturnTab:String;
    procedure ClickHome(Sender:TObject);
    procedure ClickHistory(Sender:TObject);
    procedure ClickAssistant(Sender:TObject);
    procedure ClickSchedule(Sender:TObject);
    procedure LoadLastMap;
    procedure ApplyPendingWorkout;
    procedure ShowDevicePrompt;
    procedure CancelLaunch(Sender:TObject);
    procedure StartTimed(Sender:TObject);
    procedure CloseDevicePrompt;
    procedure ContinueWorkoutLaunch;
  private
    FTileCol:    TCastleUserInterface;
    FRoutesPage: TRoutesPage;
    FDevicesPage: TDevicesPage;
    FBikeFitPage: TBikeFitPage;
    FEventsPage:  TEventsPage;
    FTrainingPage: TTrainingPage;
    FProfilePage:  TProfilePage;
	FRouteLibraryPage: TRouteLibraryPage;
    FRouteCreatorPage: TRouteCreatorPage;

    FDreamPage: TDreamWorldPage;
    FTileDream: TMenuTile;

    FTileRoutes:   TMenuTile;
    FTileDevices:  TMenuTile;
    FTileBikeFit:  TMenuTile;
    FTileTraining: TMenuTile;
    FTileProfile:  TMenuTile;
    FTileEvents:   TMenuTile;


    FProfilePollAccum: Single;

    { Профиль вверху меню. Видна всегда: либо «Войти» (когда не
      авторизован), либо ник + краткие данные (FTP, вес, метка
      подписки) с кликом во вкладку «Профиль». Состояние меняется
      асинхронно после RefreshProfile, поэтому пересоздаётся
      из той же опросной петли что и dev pane. }
    FProfilePane:        TCastleRectangleControl;
    FProfileButton:      TCastleButton;
    FProfileLabelName:   TCastleLabel;
    FProfileLabelDetail: TCastleLabel;
    FProfilePaneSig:     String;

    { Кеш параметров, от которых зависит LayoutTiles: перераскладка
      только когда что-то из этого реально изменилось. -1 = не считано. }
    FLastLayoutW:   Single;
    FLastLayoutH:   Single;

    procedure BuildTiles;

    procedure LayoutTiles;
    { Скрыть текущую встроенную страницу (если открыта). }
    procedure HideEmbeddedPage;
    { Общий toggle встроенной страницы по плашке: ленивое создание
      (owner FreeAtStop, Exists сразу гасим), повторный клик по той же
      плашке сворачивает, клик при открытой другой странице — переключает. }
    procedure TogglePage(var APage; AClass: TMenuEmbeddedPageClass;
      ATile: TMenuTile);
    procedure BuildProfilePane;
    procedure LanguageChanged(Sender: TObject);

    procedure ClickQuit(Sender: TObject);

    procedure ClickDevices(Sender: TObject);
    procedure ClickBikeFit(Sender: TObject);
    { Запуск заезда по FIT, выбранному на странице «Маршруты» (кнопка
      «Ехать» страницы зовёт сюда через TRoutesPage.OnLaunchRide). }
    procedure LaunchSelectedRide(Sender: TObject);
    { ПОЛНОЕ завершение заезда (кнопка «Стоп» страницы «Маршруты»):
      стриминг стоп, запись FIT завершена, ресурсы play освобождены. }
    procedure StopSelectedRide(Sender: TObject);
    { Меню лежит поверх живой play-сессии (оверлей меню)? }
    procedure ClickTraining(Sender: TObject);
    procedure ClickProfile(Sender: TObject);
    procedure ClickEvents(Sender: TObject);
	procedure ClickConnectors(Sender: TObject);
	procedure ClickRouteLibrary(Sender: TObject);
    procedure ClickRouteCreator(Sender:TObject);

    procedure ClickDream(Sender:TObject);
    procedure ClickRoutes(Sender: TObject);


    procedure ClickProfilePane(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
    procedure Start; override;
    function PreviewPress(const Event:TInputPressRelease):Boolean;override;
    procedure RenderOverChildren;override;
    procedure Stop; override;
    function Press(const Event: TInputPressRelease): Boolean; override;
    procedure ReturnToRide;
    procedure QuickRide;
    procedure SelectTravelMode(Mode:TTravelMode);
    procedure StartExploration(Lat,Lon:Double);
    procedure ResumeActivity(Activity:TJSONObject);
    procedure StartWorkout(Plan:TWorkoutFile;ReferenceWatts:Double;TrainingOnly:Boolean=False);
    procedure StartEditorWorkout(Plan:TWorkoutFile;ReferenceWatts:Double);
    procedure RepeatWorkout;
    procedure RepeatActivity(Activity:TJSONObject);
    procedure FinishRide;
    procedure AcceptFile(const FileName:String);
    procedure OpenChildView(Child: TCastleView);
    procedure CloseChildView(Child: TCastleView; const Tab: String);
    function RideUnderneath: Boolean;
    function SessionUnderneath: Boolean;
    function AccountChangeError:String;
    function CanLaunchRide:Boolean;
    procedure Update(const SecondsPassed: Single;
      var HandleInput: Boolean); override;

    { Библиотека карт упразднена; всегда пустая строка = дефолтный
      террейн. Свойство сохранено для обратной совместимости. }
    function SelectedMapJsonUrl: String;

    { Selected route, or the last selected route restored from settings.
      The optional simulation recording never changes the world route. }
    function SelectedFitPath: String;

    { Открыть вкладку «Маршруты» (без toggle): кнопки «Назад» встроенных
      страниц ведут сюда. }
    procedure ShowRoutesPage;
    procedure LaunchDreamRide(Sender:TObject);
    property DreamPage:TDreamWorldPage read FDreamPage;
    property Globe: TGlobeMap read FGlobe;
    property RoutesPage: TRoutesPage read FRoutesPage;
    property ExplorePage: TExplorePage read FExplorePage;
    procedure OpenCloudRoute(const FileName:String;AutoRide:Boolean=False);

    { Открыть вкладку по имени ('routes','devices','bikefit','events',
      'training','profile'). Неизвестные имена — игнор с предупреждением
      в лог. Вызывает MCP и редактор тренировок при возврате. }
    procedure OpenTab(const AName: String);
    function BikeFitPage: TBikeFitPage;
  published
    property RouteCreator:TRouteCreatorPage read FRouteCreatorPage;
  end;

var
  ViewMenu: TViewMenu;

implementation

uses GameTravelUI, UiTranslations, GameBuildInfo, GameClientUpdate,GameAccountChange,CastleMessages,
  Math, GameDeviceSensor, GameDeviceTypes, CastleApplicationProperties, CastleWindow, CastleLog, CastleURIUtils,
  GameViewPlay,GameViewTrainingOnly,GameAssistantUI,
  GameViewLogin,
  GameDreamWorldScene, AppSettings, VeloSiteAPI, GameDeviceService, GameUserData, GameWorkoutPlayer, GameRideHistory, DebugLog, GameLocalization, GameRouteLibraryData, Osm3dDreamWorld,GameRideCommands,GameRideRooms;

const
  { Колонка плашек: размеры подгоняются под окно (LayoutTiles),
    здесь — стартовые значения и пределы. }
  TILE_W = 220;
  TILE_H = 96;
  TILES_COUNT = 7;
  TILE_MIN_H = 56;
  TILE_MAX_H = 150;
  TILE_MIN_W = 240;
  TILE_MAX_W = 340;
  TILE_GAP = 6;

{ TViewMenu ------------------------------------------------------------------ }

constructor TViewMenu.Create(AOwner: TComponent);
begin
  inherited;
  DesignUrl := 'castle-data:/gameviewmenu.castle-user-interface';
  { The menu can cover a live ride. Keep its mouse/keyboard input here. }
  InterceptInput := True;
end;

{ Диагностический автозапуск «Свободной езды» из командной строки:
  --freeride[=<путь к FIT>] (формы -freeride / /freeride тоже).
  Без значения — как кнопка «Ехать» (SelectedFitPath). }
var
  GFreeRideCliDone: Boolean = False;
  GFreeRideCliPending: Boolean = False;
  GFreeRideCliFit: String = '';

function FreeRideCliFit(out AFit: String): Boolean;
var
  I, P: Integer;
  S: String;
begin
  Result := False;
  AFit := '';
  if GFreeRideCliDone then Exit;
  GFreeRideCliDone := True;   { парсим один раз; возврат в меню не перезапускает }
  for I := 1 to ParamCount do
  begin
    S := ParamStr(I);
    if (Length(S) = 0) or (not (S[1] in ['-', '/'])) then Continue;
    while (Length(S) > 0) and (S[1] in ['-', '/']) do Delete(S, 1, 1);
    P := Pos('=', S);
    if P > 0 then
    begin
      if SameText(Copy(S, 1, P - 1), 'freeride') then
      begin
        AFit := Copy(S, P + 1, MaxInt);
        if (Length(AFit) >= 2) and (AFit[1] = '"') and
           (AFit[Length(AFit)] = '"') then
          AFit := Copy(AFit, 2, Length(AFit) - 2);
        Exit(True);
      end;
    end
    else if SameText(S, 'freeride') then
      Exit(True);
  end;
end;

procedure TViewMenu.Start;
var
  FCliFit: String;
  PendingTab: String;
  CliFreeRide: Boolean;
  Credit: TCastleLabel;
  CanvasBackground:TCastleRectangleControl;
begin
  inherited;
  LocalizeDesignedUi(Self);
  ApplyUserInterfaceScale(Container);
  FKeyboard:=TUiKeyboardNavigation.Create(FreeAtStop);FKeyboard.Exists:=False;InsertFront(FKeyboard);

  if Assigned(Background) then Background.Color := Vector4(1, 1, 1, 0);

  FGlobe := nil;
  FGlobeCredit := nil;
  if not SessionUnderneath then
  begin
    FGlobe := TGlobeMap.Create(FreeAtStop);
    FGlobe.Name := 'MenuGlobe';
    FGlobe.FullSize := True;
    InsertBack(FGlobe);
    FGlobeCredit := TCastleRectangleControl.Create(FreeAtStop);
    FGlobeCredit.Color := Vector4(0.04, 0.06, 0.09, 0.75);
    FGlobeCredit.AutoSizeToChildren := True;
    FGlobeCredit.Anchor(hpRight, -8);
    InsertFront(FGlobeCredit);
    Credit := TMenuLabel.Create(FGlobeCredit);
    BindUiText(Credit, '© OpenStreetMap contributors · Natural Earth · Copernicus DEM');
    Credit.FontSize := 11;
    Credit.Color := White;
    Credit.Padding := 4;
    FGlobeCredit.InsertFront(Credit);
  end;

  if Assigned(LabelTitle) then begin
    LabelTitle.Exists:=True;LabelTitle.Caption:='REZVIVO';LabelTitle.FontSize:=24;
    LabelTitle.Color:=White;
    LabelTitle.Anchor(hpLeft,20);LabelTitle.Anchor(vpTop,-16);
  end;
  FVersionButton:=TMenuButton.Create(FreeAtStop);FVersionButton.Name:='ClientVersion';
  FVersionButton.Caption:=ClientVersion;FVersionButton.AutoIcon:=False;FVersionButton.Style:=mbGhost;
  FVersionButton.OnClick:=@ClickVersion;InsertFront(FVersionButton);
  FNavBackground:=TCastleRectangleControl.Create(FreeAtStop);
  FNavBackground.FullSize:=False;FNavBackground.HeightFraction:=1;
  FNavBackground.Color:=Vector4(0.058,0.082,0.103,1);
  FNavBackground.Anchor(hpLeft);FNavBackground.Anchor(vpTop);InsertBack(FNavBackground);
  FTopBar:=TCastleRectangleControl.Create(FreeAtStop);FTopBar.WidthFraction:=1;
  FTopBar.Color:=MenuBackground;FTopBar.Anchor(vpTop);InsertBack(FTopBar);
  if not RideUnderneath then begin
    CanvasBackground:=TCastleRectangleControl.Create(FreeAtStop);
    CanvasBackground.FullSize:=True;CanvasBackground.Color:=MenuBackground;
    InsertBack(CanvasBackground);
  end;
  FTravelSelector:=TTravelSelector.Create(FreeAtStop);
  FTravelSelector.OnChange:=@TravelChanged;InsertFront(FTravelSelector);
  FDevicesSummary:=TMenuButton.Create(FreeAtStop);FDevicesSummary.Name:='MenuDevicesStatus';
  FDevicesSummary.AutoSize:=False;FDevicesSummary.AutoIcon:=False;
  FDevicesSummary.OnClick:=@ClickDevices;InsertFront(FDevicesSummary);
  FResumeButton:=TMenuButton.Create(FreeAtStop);FResumeButton.Name:='ResumeRideButton';
  FRoomButton:=TMenuButton.Create(FreeAtStop);FRoomButton.Name:='RideWithFriend';
  FRoomButton.AutoSize:=False;FRoomButton.AutoIcon:=False;BindTravelText(FRoomButton, 'Ride with a friend');
  FRoomButton.OnClick:=@ClickRoom;InsertFront(FRoomButton);
  FResumeButton.AutoSize:=False;FResumeButton.AutoIcon:=False;
  BindTravelText(FResumeButton, 'Return to ride');FResumeButton.OnClick:=@ClickResume;
  FResumeButton.Style:=mbPrimary;InsertFront(FResumeButton);
  FEndRideButton:=TMenuButton.Create(FreeAtStop);FEndRideButton.Name:='EndRideButton';
  FEndRideButton.AutoSize:=False;FEndRideButton.AutoIcon:=False;
  BindTravelText(FEndRideButton, 'Finish ride');FEndRideButton.OnClick:=@StopSelectedRide;
  FEndRideButton.Style:=mbDanger;InsertFront(FEndRideButton);
  FSessionLabel:=TMenuLabel.Create(FreeAtStop);FSessionLabel.Color:=Vector4(0.68,0.78,0.82,1);
  BindTravelText(FSessionLabel, 'Ride continues while this menu is open');InsertFront(FSessionLabel);
  RefreshRideControls;

  if Assigned(ButtonQuit) then
  begin
    ButtonQuit.OnClick := @ClickQuit;
    ButtonQuit.Exists  := ApplicationProperties.ShowUserInterfaceToQuit;
  end;

  { Сайдбар библиотеки карт упразднён — элементы дизайна прячем,
    сам дизайн-файл не трогаем. TilesHost из дизайна тоже: колонка
    плашек кладётся прямо на вью, вплотную к левому краю. }
  if Assigned(MapSidebar) then MapSidebar.Exists := False;
  if Assigned(ButtonMapEditor) then ButtonMapEditor.Exists := False;
  if Assigned(TilesHost) then TilesHost.Exists := False;

  { Правая область страниц: весь вью минус колонка плашек слева.
    Сверху без отступа — вкладка идёт от края окна. }
  FPageHost := TCastleUserInterface.Create(FreeAtStop);
  FPageHost.FullSize := True;
  FPageHost.Border.Left   := TILE_W + 24;
  FPageHost.Border.Top    := 80; { account header must never cover a page }
  FPageHost.Border.Right  := 8;

  FPageHost.Border.Bottom := 0;
  InsertFront(FPageHost);
  FWorldModeBar:=TCastleHorizontalGroup.Create(FreeAtStop);FWorldModeBar.Spacing:=8;
  FWorldModeBar.Anchor(hpLeft,8);FWorldModeBar.Anchor(vpTop,-2);FWorldModeBar.Exists:=False;
  FPageHost.InsertFront(FWorldModeBar);
  FWorldTrack:=TMenuButton.Create(FreeAtStop);FWorldTrack.Name:='WorldFollowTrack';
  FWorldTrack.AutoIcon:=False;BindUiText(FWorldTrack,'Follow track');FWorldTrack.OnClick:=@WorldModeChanged;
  FWorldModeBar.InsertFront(FWorldTrack);
  FWorldExplore:=TMenuButton.Create(FreeAtStop);FWorldExplore.Name:='WorldFreeExplore';
  FWorldExplore.AutoIcon:=False;FWorldExplore.Tag:=1;BindUiText(FWorldExplore,'Free exploration');
  FWorldExplore.OnClick:=@WorldModeChanged;FWorldModeBar.InsertFront(FWorldExplore);
  FStartPage:=nil;FHistoryPage:=nil;FTileHome:=nil;FTileHistory:=nil;FTileAssistant:=nil;
  FSchedulePage:=nil;FTileSchedule:=nil;
  FRoutesPage := nil;
  FDreamPage := nil;
  FDevicesPage := nil;
  FBikeFitPage := nil;
  FEventsPage := nil;
  FTrainingPage := nil;
  FProfilePage := nil;
	FRouteLibraryPage := nil;
    FRouteCreatorPage := nil;

  BuildTiles;
  BindTravelText(FTileBikeFit.TitleLabel,'Rider and bicycle');
  BindTravelText(FTileHistory.TitleLabel,'My rides');

  { Первая подгонка плашек под окно; дальше Update следит сам. }
  FLastLayoutW := -1;
  FLastLayoutH := -1;
  LayoutTiles;

  FProfilePollAccum := 0;

  { Профиль-плашка вверху. Пересоздаётся когда меняется auth/профиль,
    из той же опросной петли. }
  FProfilePane := nil;
  FProfilePaneSig := '';
  BuildProfilePane;
  LayoutTiles;
  ObserveUiLanguage(FreeAtStop, @LanguageChanged);

  { Пакетный режим: --fitstats=<путь к FIT> — открыть страницу
    «Маршруты» и прогнать полную статистику по FIT с записью отчёта
    <fit>.fullstats.txt и автоматическим выходом. Тяжёлая работа идёт
    не здесь, а из Update страницы (StartBatchFullStats лишь взводит
    стейт). Guard по BatchMode — чтобы возврат в меню не перезапустил
    прогон, пока приложение не завершилось. }
  if (BatchFitStatsPath <> '') and
     ((FRoutesPage = nil) or (not FRoutesPage.BatchMode)) then
  begin
    ClickRoutes(nil);
    FRoutesPage.StartBatchFullStats(BatchFitStatsPath);
  end;

  { Диагностический автозапуск «Свободной езды» (--freeride[=<FIT>]).
    Само переключение вью — в Update: SetView во время lifecycle-метода
    вью (Start/Resume/Pause/Stop) запрещён CGE (EInternalError).
    FreeRideCliFit парсит параметры однократно (side-effect «один раз»),
    поэтому его результат используем и для взвода GFreeRideCliPending,
    и для решения об автопоказе «Маршрутов» ниже. }
  CliFreeRide := FreeRideCliFit(FCliFit);
  if CliFreeRide then
  begin
    GFreeRideCliFit     := FCliFit;
    GFreeRideCliPending := True;
  end;

  { По умолчанию меню открывается сразу на странице «Маршруты». Кроме
    CLI-режимов: --fitstats сам открыл страницу выше (и взвёл её
    BatchMode), --freeride сразу уходит в игру. }
  if (BatchFitStatsPath = '') and (not CliFreeRide) and (not SessionUnderneath)
    and (FPendingTab = '') then
    ClickHome(nil);
  PendingTab := FPendingTab;
  FPendingTab := '';
  if PendingTab <> '' then OpenTab(PendingTab);
end;

procedure TViewMenu.BuildTiles;
var
  Col: TCastleVerticalGroup;

  function MakeTile(const ATitle: String; const ABaseColor: TCastleColor;
    AClick: TNotifyEvent; const AIconUrl: String): TMenuTile;
  begin
    Result := TMenuTile.Create(FreeAtStop);
    Result.SetTileSize(TILE_W, TILE_H);   { стартовый размер; LayoutTiles подгонит под окно }
    Result.SetTitle(ATitle);
    Result.SetBaseColor(ABaseColor);
    Result.SetIconUrl(AIconUrl);
    Result.OnTileClick := AClick;
  end;

begin
  { Одна вертикальная колонка вплотную к левому краю вью. Клик по
    плашке открывает страницу раздела в FPageHost (встроенные вкладки). }
  Col := TCastleVerticalGroup.Create(FreeAtStop);
  Col.Spacing := TILE_GAP;
  Col.Anchor(hpLeft, 8);
  Col.Anchor(vpTop, -64);

  FTileCol := Col;
  InsertFront(Col);

  FTileHome:=MakeTile(T('Home'),Vector4(0.25,0.5,0.4,1),@ClickHome,'native:home');Col.InsertFront(FTileHome);
  FTileRoutes := MakeTile(
    'Real World',
    Vector4(0.36, 0.52, 0.78, 0.85),  { небесный }
    @ClickRoutes,
    'native:world');
  Col.InsertFront(FTileRoutes);
  FTileDream := MakeTile('Dream World',Vector4(0.39,0.35,0.61,0.90),
    @ClickDream,'native:mountain');
  Col.InsertFront(FTileDream);

  FTileDevices := MakeTile(
    T('Devices'),
    Vector4(0.30, 0.58, 0.68, 0.85),  { бирюзовый }
    @ClickDevices,
    'castle-data:/menu/icons/devices.png');
  FTileDevices.Exists:=False;

  FTileBikeFit := MakeTile(
    T('Rider and bicycle'),
    Vector4(0.38, 0.62, 0.44, 0.85),  { травяной }
    @ClickBikeFit,
    'native:bicycle');


  FTileTraining := MakeTile(
    T('Training'),
    Vector4(0.76, 0.42, 0.40, 0.85),  { терракотовый }
    @ClickTraining,
    'native:training');
  Col.InsertFront(FTileTraining);
  FTileSchedule:=MakeTile(T('Schedule'),MenuAccent,@ClickSchedule,'native:calendar');
  Col.InsertFront(FTileSchedule);
  Col.InsertFront(FTileBikeFit);

  FTileProfile := MakeTile(
    T('Settings'),
    Vector4(0.56, 0.52, 0.78, 0.85),
    @ClickSettings,
    'native:settings');
  InsertFront(FTileProfile);

  FTileEvents := MakeTile(
    T('Events'),
    Vector4(0.72, 0.64, 0.38, 0.85),  { охра }
    @ClickEvents,
    'castle-data:/menu/icons/events.png');
  FTileEvents.Exists:=False;
  FTileHistory:=MakeTile(T('My rides'),Vector4(0.4,0.5,0.6,1),@ClickHistory,'native:history');Col.InsertFront(FTileHistory);
  FTileAssistant:=MakeTile('Assistant',MenuAccent,@ClickAssistant,'native:assistant');
  FTileAssistant.Name:='MenuAssistant';Col.InsertFront(FTileAssistant);
end;

procedure TViewMenu.LayoutTiles;
var S,TileW,TileH,BottomInset,PageLeft:Single;
  procedure SizeTile(Tile:TMenuTile);
  begin
    if Tile=nil then Exit;Tile.SetTileSize(TileW,TileH,S);

  end;
begin
  if(EffectiveWidth<=0)or(EffectiveHeight<=0)then Exit;
  S:=Max(0.65,Min(1,UIScale));BottomInset:=8;
  TileW:=EnsureRange(EffectiveWidth*0.14,190/S,220/S);
  TileH:=Min(52/S,(EffectiveHeight-BottomInset-240/S-7*TILE_GAP)/8);
  TileH:=Max(32/S,TileH);PageLeft:=TileW+40/S;
  SizeTile(FTileHome);SizeTile(FTileHistory);SizeTile(FTileAssistant);SizeTile(FTileRoutes);SizeTile(FTileDream);SizeTile(FTileDevices);
  SizeTile(FTileSchedule);SizeTile(FTileBikeFit);SizeTile(FTileTraining);SizeTile(FTileProfile);SizeTile(FTileEvents);
  if FTileCol<>nil then begin FTileCol.Anchor(vpTop,-100/S);FTileCol.Anchor(hpLeft,12/S);end;
  if FTileProfile<>nil then begin FTileProfile.Anchor(hpLeft,12/S);FTileProfile.Anchor(vpBottom,BottomInset+58/S);end;
  if FNavBackground<>nil then FNavBackground.Width:=TileW+24/S;
  if LabelTitle<>nil then begin LabelTitle.FontScale:=1;LabelTitle.CustomFont:=MenuFont(True);LabelTitle.FontSize:=22/S;LabelTitle.Anchor(hpLeft,26/S);LabelTitle.Anchor(vpTop,-34/S);end;
  if FVersionButton<>nil then begin FVersionButton.FontSize:=12/S;FVersionButton.Anchor(hpLeft,22/S);FVersionButton.Anchor(vpTop,-64/S);end;
  if FPageHost<>nil then begin
    FPageHost.Border.Left:=PageLeft;
    if SessionUnderneath then FPageHost.Border.Top:=160/S else FPageHost.Border.Top:=124/S;
    FPageHost.Border.Right:=24/S;
    if FTopBar<>nil then FTopBar.Height:=FPageHost.Border.Top;
  end;
  if FProfilePane<>nil then begin
    FProfilePane.Width:=230/S;FProfilePane.Height:=48/S;
    FProfilePane.Anchor(hpRight,-24/S);FProfilePane.Anchor(vpTop,-12/S);
    if(FProfileButton<>nil)and(FProfileButton.Caption<>'')then begin
      FProfileButton.FontScale:=1;FProfileButton.FontSize:=14/S;
      FProfileButton.AutoSize:=False;FProfileButton.Width:=84/S;FProfileButton.Height:=34/S;
    end;
    if FProfileLabelName<>nil then begin FProfileLabelName.FontSize:=16/S;FProfileLabelName.FontScale:=1;end;
    if FProfileLabelDetail<>nil then begin FProfileLabelDetail.FontSize:=12/S;FProfileLabelDetail.FontScale:=1;end;
  end;
  if FDevicesSummary<>nil then begin
    FDevicesSummary.Width:=Min(250/S,Max(100,EffectiveWidth-PageLeft-260/S));
    FDevicesSummary.Height:=40/S;FDevicesSummary.FontSize:=14/S;
    FDevicesSummary.Anchor(hpRight,-270/S);FDevicesSummary.Anchor(vpTop,-16/S);
  end;
  if FTravelSelector<>nil then begin FTravelSelector.Anchor(hpLeft,PageLeft);FTravelSelector.Anchor(vpTop,-16/S) end;
  if FRoomButton<>nil then begin
    FRoomButton.Width:=220/S;FRoomButton.Height:=40/S;FRoomButton.FontSize:=15/S;
    FRoomButton.Anchor(hpLeft,PageLeft);FRoomButton.Anchor(vpTop,-64/S);
  end;
  if FResumeButton<>nil then begin
    FResumeButton.Width:=190/S;FResumeButton.Height:=40/S;FResumeButton.FontSize:=16/S;
    FResumeButton.Anchor(hpLeft,PageLeft);FResumeButton.Anchor(vpTop,-108/S);
    FEndRideButton.Width:=190/S;FEndRideButton.Height:=40/S;FEndRideButton.FontSize:=16/S;
    FEndRideButton.Anchor(hpRight,-16/S);FEndRideButton.Anchor(vpTop,-108/S);
    FSessionLabel.FontSize:=14/S;FSessionLabel.Anchor(hpLeft,PageLeft+205/S);FSessionLabel.Anchor(vpTop,-120/S);
    FSessionLabel.MaxWidth:=Max(60,EffectiveWidth-PageLeft-425/S);
  end;
  if ButtonQuit<>nil then begin
    ButtonQuit.Anchor(hpLeft,28/S);ButtonQuit.Anchor(vpBottom,BottomInset+8);
    ButtonQuit.FontSize:=14/S;BindUiText(ButtonQuit,'Close game');
    if ButtonQuit is TMenuButton then TMenuButton(ButtonQuit).Style:=mbGhost;
  end;
  if FGlobeCredit<>nil then FGlobeCredit.Anchor(vpBottom,BottomInset);
  if(FStartPage<>nil)and FStartPage.Exists and(FGlobe<>nil)then begin
    FGlobe.Width:=Max(220/S,Min(800/S,(EffectiveWidth-PageLeft)*0.53));
    FGlobe.Height:=Min(FGlobe.Width,EffectiveHeight*0.82);
  end;
  FLastLayoutW:=EffectiveWidth;FLastLayoutH:=EffectiveHeight;
end;

procedure TViewMenu.ClickResume(Sender:TObject);
begin ReturnToRide;end;
procedure TViewMenu.ClickRoom(Sender:TObject);
var Kind:TRideMapKind;Id:string;
begin
  if FRoomView=nil then begin
    FRoomView:=TViewRideRooms.Create(FreeAtStop);FRoomView.OnRide:=@LaunchRoom;
    FRoomView.OnSignIn:=@RoomSignIn;FRoomView.OnRoomChanged:=@RoomChanged;
  end;
  FRoomView.SourceKind:='dream';FRoomView.SourceFile:='';FRoomView.SourceTitle:='';
  if(FDreamPage<>nil)and FDreamPage.Exists then FRoomView.SourceFile:=FDreamPage.SelectedManifest
  else if(FRoutesPage<>nil)and FRoutesPage.Exists then begin
    FRoomView.SourceKind:='real';FRoomView.SourceFile:=SelectedFitPath;
  end else if RideUnderneath then begin
    if ViewPlay.DreamWorld<>nil then FRoomView.SourceFile:=ViewPlay.DreamWorld.ManifestPath
    else begin FRoomView.SourceKind:='real';FRoomView.SourceFile:=ViewPlay.CurrentFitPath end;
  end else begin
    LastRideMap(Kind,Id);
    if Kind=rmkReal then begin FRoomView.SourceKind:='real';FRoomView.SourceFile:=Id end
    else FRoomView.SourceFile:=URIToFilenameSafe('castle-data:/dream-worlds/'+Id+'/world.json');
  end;
  if FRoomView.SourceKind='dream'then FRoomView.SourceTitle:=ExtractFileName(ExtractFileDir(FRoomView.SourceFile))
  else FRoomView.SourceTitle:=ChangeFileExt(ExtractFileName(FRoomView.SourceFile),'');
  Container.PushView(FRoomView);
end;
procedure TViewMenu.RoomSignIn(Sender:TObject);
begin OpenTab('profile');end;
procedure TViewMenu.RoomChanged(Sender:TObject);
begin if RideUnderneath then ViewPlay.ConnectRideRoom;end;
procedure TViewMenu.LaunchRoom(Sender:TObject);
var I:TRideRoomInfo;WorldId:string;
begin
  if not RideRooms.Active then Exit;I:=RideRooms.Info;WorldId:='';
  if RideUnderneath then begin
    if ViewPlay.DreamWorld<>nil then WorldId:=ViewPlay.DreamWorld.Id;
    if RideRooms.MatchesRide(ViewPlay.CurrentFitPath,WorldId)then begin
      ViewPlay.ConnectRideRoom;ReturnToRide;Exit;
    end;
  end;
  if I.Kind='real'then OpenCloudRoute(I.RouteFile,True)
  else begin OpenTab('dream');FDreamPage.SelectWorldId(I.WorldId);FDreamPage.AutoStart:=True end;
end;
procedure TViewMenu.ClickVersion(Sender:TObject);
begin ShowClientUpdates(Sender);end;

procedure TViewMenu.RefreshRideControls;
var HasRide:Boolean;Text:String;
begin
  HasRide:=SessionUnderneath;
  FResumeButton.Exists:=HasRide;FEndRideButton.Exists:=HasRide;FSessionLabel.Exists:=HasRide;
  if Assigned(DeviceService) and DeviceService.IsSimulationActive then Text:=UiText('Devices: simulation')
  else if Assigned(DeviceService) and(DeviceService.HasSensor(skPower)or DeviceService.HasSensor(skHeartRate))then Text:=UiText('Devices connected')else Text:=UiText('Connect devices');
  if FDevicesSummary.Caption<>Text then FDevicesSummary.Caption:=Text;
end;

procedure TViewMenu.ClickQuit(Sender: TObject);
begin
  Application.Terminate;
end;

procedure TViewMenu.ClickDevices(Sender: TObject);
begin
  TogglePage(FDevicesPage, TDevicesPage, FTileDevices);
end;

procedure TViewMenu.Stop;
begin
  { Detach borrowed ride objects before FreeAtStop destroys page controls. }
  HideEmbeddedPage;
  if FGlobe <> nil then FGlobe.SetActive(False);
  CloseDevicePrompt;FreeAndNil(FPendingWorkout);
  inherited;
  FGlobe := nil;
  FGlobeCredit := nil;
  FPageHost := nil;
  FProfilePane:=nil;FProfileButton:=nil;FProfileLabelName:=nil;FProfileLabelDetail:=nil;
  FTileCol:=nil;FTileRoutes:=nil;FTileDream:=nil;FTileDevices:=nil;
  FTileBikeFit:=nil;FTileTraining:=nil;FTileProfile:=nil;FTileEvents:=nil;
  FTravelSelector:=nil;FWorldModeBar:=nil;FWorldTrack:=nil;FWorldExplore:=nil;FExplorePage:=nil;
  FResumeButton:=nil;FEndRideButton:=nil;FDevicesSummary:=nil;FSessionLabel:=nil;FNavBackground:=nil;FTopBar:=nil;
  FVersionButton:=nil;
  FRoomButton:=nil;FRoomView:=nil;
  FStartPage:=nil;FHistoryPage:=nil;FTileHome:=nil;FTileHistory:=nil;FTileAssistant:=nil;
  FSchedulePage:=nil;FTileSchedule:=nil;
  FRoutesPage := nil;
  FDreamPage := nil;
  FDevicesPage := nil;
  FBikeFitPage := nil;
  FEventsPage := nil;
  FTrainingPage := nil;
  FProfilePage := nil;
  FRouteLibraryPage := nil;
  FRouteCreatorPage := nil;
end;

procedure TViewMenu.ReturnToRide;
begin
  if not SessionUnderneath then Exit;
  HideEmbeddedPage;
  Container.PopView(Self);
end;

function TViewMenu.PreviewPress(const Event:TInputPressRelease):Boolean;
var Scope:TCastleUserInterface;
begin
  Scope:=Self;
  if FLaunchPane<>nil then Scope:=FLaunchPane
  else if(FTrainingPage<>nil)and FTrainingPage.Exists and(FTrainingPage.KeyboardRoot<>nil)then Scope:=FTrainingPage.KeyboardRoot
  else if(FProfilePage<>nil)and FProfilePage.Exists and(FProfilePage.KeyboardRoot<>nil)then Scope:=FProfilePage.KeyboardRoot
  else if(FBikeFitPage<>nil)and FBikeFitPage.Exists and(FBikeFitPage.KeyboardRoot<>nil)then Scope:=FBikeFitPage.KeyboardRoot;
  if(FKeyboard<>nil)and FKeyboard.Handle(Event,Scope)then Exit(True);
  Result:=inherited;
end;
procedure TViewMenu.RenderOverChildren;
begin inherited;if FKeyboard<>nil then FKeyboard.Render;end;
function TViewMenu.Press(const Event:TInputPressRelease):Boolean;
begin
  if Event.IsKey(keyEscape) then begin
    if FLaunchPane<>nil then begin CancelLaunch(nil);Exit(True);end;
    if Assigned(FSchedulePage)and FSchedulePage.Exists and FSchedulePage.HandleBack then Exit(True);
    if Assigned(FHistoryPage)and FHistoryPage.Exists and FHistoryPage.HandleBack then Exit(True);
    if Assigned(FRoutesPage) and FRoutesPage.Exists and FRoutesPage.CloseDetails then Exit(True);
    if Assigned(FBikeFitPage) and FBikeFitPage.Exists and FBikeFitPage.HandleBack then Exit(True);
    if Assigned(FProfilePage) and FProfilePage.Exists and FProfilePage.HandleBack then Exit(True);
    if Assigned(FTrainingPage) and FTrainingPage.Exists and FTrainingPage.HandleBack then Exit(True);
    if (Assigned(FRouteCreatorPage) and FRouteCreatorPage.Exists)or
       (Assigned(FRouteLibraryPage) and FRouteLibraryPage.Exists)then begin ShowRoutesPage;Exit(True);end;
    if SessionUnderneath then ReturnToRide;
    Exit(True);
  end;
  Result:=inherited;
end;

procedure TViewMenu.OpenChildView(Child:TCastleView);
begin
  FChildReturnTab:='home';
  if FTrainingPage<>nil then if FTrainingPage.Exists then FChildReturnTab:='training';
  if FRoutesPage<>nil then if FRoutesPage.Exists then FChildReturnTab:='routes';
  if FDreamPage<>nil then if FDreamPage.Exists then FChildReturnTab:='dream';
  if FBikeFitPage<>nil then if FBikeFitPage.Exists then FChildReturnTab:='bikefit';
  if FRouteLibraryPage<>nil then if FRouteLibraryPage.Exists then FChildReturnTab:='route-library';
  if FProfilePage<>nil then if FProfilePage.Exists then FChildReturnTab:='profile';

  if(Child<>nil)and(Container.PendingFrontView=Self)then begin
    HideEmbeddedPage;
    Container.PushView(Child);
  end;
end;

procedure TViewMenu.CloseChildView(Child:TCastleView;const Tab:String);
var Dest:String;
begin
  Dest:=Tab;if Dest=''then Dest:=FChildReturnTab;
  if(Container.CurrentViewStackCount>1)and
    (Container.CurrentViewStack[Container.CurrentViewStackCount-2]=Self)then begin
    Container.PopView(Child);
    OpenTab(Dest);
    if(Dest='training')and(FTrainingPage<>nil)then FTrainingPage.RefreshLibrary;
  end else begin Container.View:=Self;OpenTab(Dest);end;
end;

procedure TViewMenu.ClickBikeFit(Sender: TObject);
begin
  TogglePage(FBikeFitPage, TBikeFitPage, FTileBikeFit);
end;

procedure TViewMenu.ClickDream(Sender:TObject);
begin
  TogglePage(FDreamPage,TDreamWorldPage,FTileDream);
  if FDreamPage<>nil then FDreamPage.OnStartRide:=@LaunchDreamRide;
  if FGlobe<>nil then begin FGlobe.SetActive(not FDreamPage.Exists);FGlobe.Exists:=not FDreamPage.Exists;end;
end;

procedure TViewMenu.LaunchDreamRide(Sender:TObject);
var World:TDreamWorld;Visual:TDreamWorldVisual;
begin
  if not CanLaunchRide then begin if FDreamPage<>nil then FDreamPage.AutoStart:=False;Exit;end;
  if FDreamPage=nil then Exit;
  FDreamPage.AutoStart:=False;
  World:=FDreamPage.TakeWorld;Visual:=FDreamPage.TakeVisual;
  RememberRideMap(rmkDream,World.Id);HideEmbeddedPage;
  if RideUnderneath then begin
    ViewPlay.ResetRideToDream(World,Visual);ApplyPendingWorkout;Container.PopView;
  end else begin
    ViewPlay.PrepareDreamWorld(World,Visual);ApplyPendingWorkout;Container.View:=ViewPlay;
  end;
end;

procedure TViewMenu.LaunchSelectedRide(Sender: TObject);
var
  FitPath: String;
begin
  if not CanLaunchRide then begin FAutoRoute:=False;Exit;end;
  { Заезд запускает стриминг по FIT, выбранному на странице «Маршруты»
    (кнопка «Ехать» страницы). FitPath читаем ДО HideEmbeddedPage: та зовёт
    StopWarmSession и освобождает warm-сессию редактора (двух сессий
    разом не будет). }
  FitPath := SelectedFitPath;
  if (FRoutesPage = nil) or (FRoutesPage.SelectedFitPath = '') then Exit;
  ViewPlay.PrepareRouteTravel;
  RememberRideMap(rmkReal,FitPath);
  FAutoRoute:=False;

  HideEmbeddedPage;

  if RideUnderneath then
  begin
    { Сессия жива под меню (оверлей меню): мир/байк/ботов НЕ пересоздаём —
      новый путь + райдер на старт (ResetRideToFit), затем снимаем меню
      со стека (play продолжится). }
    ViewPlay.ResetRideToFit(FitPath);
    ApplyPendingWorkout;
    Container.PopView;
    Exit;
  end;

  { Свежий запуск (первый заезд или после «Стоп»): полный Start. }
  ViewPlay.PrepareDreamWorld(nil);ViewPlay.PrepareRouteTravel;
  ViewPlay.CurrentFitPath := FitPath;   { пусто = дефолтный мир, без стриминга }
  ApplyPendingWorkout;
  Container.View := ViewPlay;
end;

procedure TViewMenu.StopSelectedRide(Sender:TObject);
begin FinishRide;end;

procedure TViewMenu.FinishRide;
begin
  if not SessionUnderneath then begin
    FEndRequested:=ViewPlay.SessionAlive or((ViewTrainingOnly<>nil)and ViewTrainingOnly.SessionAlive);Exit;
  end;
  FEndRequested:=False;
  FPendingTab:='result';Container.PopView;Container.View:=ViewMenu;
end;

function TViewMenu.AccountChangeError:String;
begin
  Result:=RideHistory.AccountChangeError((ViewPlay<>nil)and ViewPlay.SessionAlive);
  if Result<>''then Result:=UiText(Result);
end;

function TViewMenu.CanLaunchRide:Boolean;
begin
  if AccountChangePending then begin
    MessageOK(Application.MainWindow,UiText('Account change in progress. Please wait.'));
    Exit(False);
  end;
  Result:=ClientCanStartRide;
end;

function TViewMenu.RideUnderneath: Boolean;
var I:Integer;
begin
  Result := False;
  if (Container = nil) or not ViewPlay.SessionAlive then Exit;
  for I:=1 to Container.CurrentViewStackCount-1 do
    if Container.CurrentViewStack[I]=Self then
      Exit(Container.CurrentViewStack[I-1]=ViewPlay);
end;

procedure TViewMenu.ClickSchedule(Sender:TObject);
begin TogglePage(FSchedulePage,TSchedulePage,FTileSchedule);end;

procedure TViewMenu.ClickTraining(Sender: TObject);
begin
  TogglePage(FTrainingPage, TTrainingPage, FTileTraining);
end;

procedure TViewMenu.ClickProfile(Sender: TObject);
begin
  TogglePage(FProfilePage, TProfilePage, nil);
  FProfilePage.ShowAccount;
  if FTileProfile<>nil then FTileProfile.Selected:=False;
end;

procedure TViewMenu.ClickSettings(Sender:TObject);
begin
  TogglePage(FProfilePage,TProfilePage,FTileProfile);FProfilePage.ShowSettings;
end;

procedure TViewMenu.ClickEvents(Sender: TObject);
begin
  TogglePage(FEventsPage, TEventsPage, FTileEvents);
end;

procedure TViewMenu.ClickConnectors(Sender:TObject);
begin
  if (FProfilePage = nil) or not FProfilePage.Exists then ClickProfile(nil);
  FProfilePage.ShowConnections;
end;

procedure TViewMenu.ClickRouteLibrary(Sender:TObject);
begin TogglePage(FRouteLibraryPage,TRouteLibraryPage,FTileRoutes);end;
procedure TViewMenu.ClickRouteCreator(Sender:TObject);
begin TogglePage(FRouteCreatorPage,TRouteCreatorPage,FTileRoutes);end;

procedure TViewMenu.OpenCloudRoute(const FileName:String;AutoRide:Boolean);
begin
  SelectTravelMode(travelBicycle);Settings.ExploreBicycle:=False;
  ShowRoutesPage;FRoutesPage.OpenLibraryFile(FileName);
  FAutoRoute:=AutoRide and FileExists(FileName);
end;

function TViewMenu.SessionUnderneath:Boolean;
var I:Integer;
begin
  Result:=RideUnderneath;if Result or(Container=nil)or(ViewTrainingOnly=nil)then Exit;
  if not ViewTrainingOnly.SessionAlive then Exit;
  for I:=1 to Container.CurrentViewStackCount-1 do
    if Container.CurrentViewStack[I]=Self then Exit(Container.CurrentViewStack[I-1]=ViewTrainingOnly);
end;

procedure TViewMenu.HideEmbeddedPage;

  procedure HidePage(const APage: TMenuEmbeddedPage);
  begin
    if Assigned(APage) and APage.Exists then
    begin
      APage.PageHidden;
      APage.Exists := False;
    end;
  end;

begin
  if FWorldModeBar<>nil then FWorldModeBar.Exists:=False;
  if FExplorePage<>nil then begin FExplorePage.HideMap;FExplorePage.Exists:=False end;
  if Assigned(FRoutesPage) and FRoutesPage.Exists then
  begin
    if FAutoRoute then FreeAndNil(FPendingWorkout);
    FAutoRoute:=False;
    FRoutesPage.PageHidden;
    FRoutesPage.Exists := False;
  end;
  HidePage(FStartPage);HidePage(FHistoryPage);HidePage(FSchedulePage);
  if FTileSchedule<>nil then FTileSchedule.Selected:=False;
  if(FTileHome<>nil)then FTileHome.Selected:=False;
  if(FTileHistory<>nil)then FTileHistory.Selected:=False;
  if(FDreamPage<>nil)and FDreamPage.AutoStart then FreeAndNil(FPendingWorkout);
  HidePage(FDreamPage);
  if FGlobeCredit<>nil then FGlobeCredit.Exists:=False;
  if FGlobe<>nil then begin
    FGlobe.Exists:=False;FGlobe.SetActive(False);
  end;
  HidePage(FDevicesPage);
  HidePage(FBikeFitPage);
  HidePage(FEventsPage);
  HidePage(FTrainingPage);
  HidePage(FProfilePage);
	HidePage(FRouteLibraryPage);
  HidePage(FRouteCreatorPage);
  if Assigned(FTileDream) then FTileDream.Selected:=False;
  if Assigned(FTileRoutes)   then FTileRoutes.Selected := False;
  if Assigned(FTileDevices)  then FTileDevices.Selected := False;
  if Assigned(FTileBikeFit)  then FTileBikeFit.Selected := False;
  if Assigned(FTileEvents)   then FTileEvents.Selected := False;
  if Assigned(FTileTraining) then FTileTraining.Selected := False;
  if Assigned(FTileProfile)  then FTileProfile.Selected := False;
end;

procedure TViewMenu.TogglePage(var APage; AClass: TMenuEmbeddedPageClass;
  ATile: TMenuTile);
var
  P: TMenuEmbeddedPage;
begin
  P := TMenuEmbeddedPage(APage);
  if P = nil then
  begin
    P := AClass.Create(FreeAtStop);
    { У свежего контрола Exists=True по умолчанию — гасим ДО toggle-
      логики ниже, иначе первый клик попадает в ветку «свернуть». }
    P.Exists := False;
    FPageHost.InsertFront(P);
    TMenuEmbeddedPage(APage) := P;
  end;
  if P.Exists then
  begin
    if Assigned(ATile) then ATile.Selected:=True;
    Exit;
  end;
  HideEmbeddedPage;   { свернуть другую открытую страницу }
  P.Exists := True;
  P.PageShown;
  if Assigned(ATile) then ATile.Selected := True;
end;

procedure TViewMenu.SelectTravelMode(Mode:TTravelMode);
begin
  Settings.TravelMode:=Mode;
  if FTravelSelector<>nil then FTravelSelector.Refresh;
  TravelChanged(nil);
end;
procedure TViewMenu.StartExploration(Lat,Lon:Double);
begin
  Settings.SetExploreStart(Lat,Lon);LaunchExplore(nil);
end;

procedure TViewMenu.ShowWorldMode;
begin
  FWorldModeBar.Exists:=True;
  FWorldTrack.Enabled:=Settings.TravelMode=travelBicycle;
  SelectMenuButton(FWorldTrack,(Settings.TravelMode=travelBicycle) and not Settings.ExploreBicycle);
  SelectMenuButton(FWorldExplore,not FWorldTrack.Enabled or Settings.ExploreBicycle);
end;
procedure TViewMenu.TravelChanged(Sender:TObject);
var InWorld,InFit:Boolean;
begin
  RefreshTravelTexts;
  InWorld:=((FRoutesPage<>nil)and FRoutesPage.Exists)or((FExplorePage<>nil)and FExplorePage.Exists);
  InFit:=(FBikeFitPage<>nil)and FBikeFitPage.Exists;
  if RideUnderneath then ViewPlay.ChangeTravelMode(Settings.TravelMode);
  if InWorld then begin HideEmbeddedPage;ClickRoutes(nil) end;
  if InFit then begin HideEmbeddedPage;ClickBikeFit(nil) end;
end;
procedure TViewMenu.WorldModeChanged(Sender:TObject);
begin
  Settings.ExploreBicycle:=TComponent(Sender).Tag=1;
  HideEmbeddedPage;ClickRoutes(nil);
end;
procedure TViewMenu.LaunchExplore(Sender:TObject);
begin
  if not CanLaunchRide or not Settings.ExploreStartSet then Exit;
  HideEmbeddedPage;
  ViewPlay.PrepareExploration(Settings.ExploreLat,Settings.ExploreLon,Settings.TravelMode);
  if RideUnderneath then begin
    ViewPlay.ResetRideToExploration;Container.PopView;
  end else Container.View:=ViewPlay;
end;

procedure TViewMenu.ClickRoutes(Sender: TObject);
begin
  if (Settings.TravelMode<>travelBicycle) or Settings.ExploreBicycle then begin
    HideEmbeddedPage;
    if FExplorePage=nil then begin
      FExplorePage:=TExplorePage.Create(FreeAtStop);FExplorePage.Border.Top:=48;
      FExplorePage.OnStart:=@LaunchExplore;FPageHost.InsertFront(FExplorePage);
    end;
    FExplorePage.Exists:=True;FExplorePage.ShowMap;ShowWorldMode;
    if FGlobeCredit<>nil then FGlobeCredit.Exists:=True;
    if FTileRoutes<>nil then FTileRoutes.Selected:=True;
    Exit;
  end;
  { Страница «Маршруты» — встроенная: показывается справа внутри
    главного меню, а не отдельным полноэкранным вью. }
  if FRoutesPage = nil then
  begin
    FRoutesPage := TRoutesPage.Create(FreeAtStop);
    FRoutesPage.Globe := FGlobe;FRoutesPage.Border.Top:=48;
    { Кнопка «Ехать» на странице — запуск заезда по выбранному FIT. }
    FRoutesPage.OnLaunchRide := @LaunchSelectedRide;
    { Кнопка «Стоп» — полное завершение заезда (teardown play-сессии). }
    FRoutesPage.OnStopRide := @StopSelectedRide;
    { У свежего контрола Exists=True по умолчанию — гасим ДО toggle-
      логики ниже, иначе первый клик попадает в ветку «свернуть». }
    FRoutesPage.Exists := False;
    FPageHost.InsertFront(FRoutesPage);
  end;
  if FRoutesPage.Exists then
  begin
    if Assigned(FTileRoutes) then FTileRoutes.Selected:=True;
    Exit;
  end;
  HideEmbeddedPage;   { свернуть другую открытую страницу }
  FRoutesPage.Exists := True;
  if FGlobeCredit<>nil then FGlobeCredit.Exists:=True;
  if FGlobe<>nil then begin FGlobe.FullSize:=True;FGlobe.Anchor(hpLeft);FGlobe.Anchor(vpBottom);FGlobe.Exists:=True;FGlobe.SetActive(True);end;
  FRoutesPage.PageShown;ShowWorldMode;
  if Assigned(FTileRoutes) then FTileRoutes.Selected := True;
end;

function TViewMenu.SelectedMapJsonUrl: String;
begin
  Result := '';
end;

function TViewMenu.SelectedFitPath: String;
begin
  Result := '';
  if Assigned(FRoutesPage) then Result := FRoutesPage.SelectedFitPath;
  if Result = '' then Result := Settings.GetSelectedRoutePath;
end;

procedure TViewMenu.ShowRoutesPage;
begin
  if (FRoutesPage = nil) or (not FRoutesPage.Exists) then
    ClickRoutes(nil);
end;

function TViewMenu.BikeFitPage: TBikeFitPage;
begin
  Result := FBikeFitPage;
end;

procedure TViewMenu.OpenTab(const AName: String);
var
  N: String;
begin
  N := LowerCase(Trim(AName));
  { PushView may be deferred while a play Update is processing events.
    FreeAtStop has already destroyed the previous page host. Open the tab
    only after Start has constructed the new controls. }
  if FPageHost = nil then
  begin
    FPendingTab := N;
    Exit;
  end;
  if N='home' then begin ClickHome(nil);Exit;end;
  if N='schedule' then begin ClickSchedule(nil);Exit;end;
  if N='history' then begin ClickHistory(nil);Exit;end;
  if N='result' then begin ClickHistory(nil);FHistoryPage.ShowResult;Exit;end;
  if N='rider' then begin TogglePage(FProfilePage,TProfilePage,FTileBikeFit);FProfilePage.ShowRider;Exit;end;
  if N='intervals' then begin ClickTraining(nil);FTrainingPage.ShowIntervals;Exit;end;
  if N='settings' then begin ClickSettings(nil);Exit;end;
  if N='route-library' then begin if(FRouteLibraryPage=nil)or(not FRouteLibraryPage.Exists)then ClickRouteLibrary(nil);Exit;end;
  if N='route-create' then begin if(FRouteCreatorPage=nil)or(not FRouteCreatorPage.Exists)then ClickRouteCreator(nil);Exit;end;
  if N='connectors' then begin ClickConnectors(nil);Exit;end;
  if (N='dream')or(N='dream-world')then begin
    if(FDreamPage=nil)or not FDreamPage.Exists then ClickDream(nil);Exit;end;
  if (N = 'routes')or(N='real-world') then
    ShowRoutesPage
  else
  if N = 'devices' then
  begin
    if (FDevicesPage = nil) or (not FDevicesPage.Exists) then
      ClickDevices(nil);
  end
  else
  if N = 'bikefit' then
  begin
    if (FBikeFitPage = nil) or (not FBikeFitPage.Exists) then
      ClickBikeFit(nil);
  end
  else
  if N = 'events' then
  begin
    if (FEventsPage = nil) or (not FEventsPage.Exists) then
      ClickEvents(nil);
  end
  else
  if N = 'training' then
  begin
    if (FTrainingPage = nil) or (not FTrainingPage.Exists) then
      ClickTraining(nil);
  end
  else
  if N = 'profile' then
  begin
    ClickProfile(nil);
  end
  else
    Logger.Warning('[Menu] OpenTab: неизвестная вкладка "' + AName + '"');
end;


procedure TViewMenu.ClickHome(Sender:TObject);
begin
  TogglePage(FStartPage,TStartPage,FTileHome);
  if(FGlobe<>nil)and not RideUnderneath then begin
    FGlobe.Border.AllSides:=0;FGlobe.Border.Left:=0;FGlobe.Border.Right:=0;
    FGlobe.Border.Top:=0;FGlobe.Border.Bottom:=0;FGlobe.FullSize:=False;
    FGlobe.ShowPlanet;
    FGlobe.Anchor(hpRight,-16);FGlobe.Anchor(vpMiddle);FGlobe.Exists:=True;FGlobe.SetActive(True);
    LayoutTiles;
    if FGlobeCredit<>nil then FGlobeCredit.Exists:=True;
  end;
end;
procedure TViewMenu.ClickHistory(Sender:TObject);
begin TogglePage(FHistoryPage,THistoryPage,FTileHistory);end;

procedure TViewMenu.ClickAssistant(Sender:TObject);
begin ShowAssistant(Container);end;
procedure TViewMenu.LoadLastMap;
var Kind:TRideMapKind;MapId:String;
begin
  if not CanLaunchRide then Exit;
  LastRideMap(Kind,MapId);
  if Kind=rmkReal then begin OpenCloudRoute(MapId,True);Exit;end;
  ClickDream(nil);FDreamPage.SelectWorldId(MapId);
  FDreamPage.AutoStart:=True;
end;
procedure TViewMenu.QuickRide;
begin
  if (Settings.TravelMode<>travelBicycle) or Settings.ExploreBicycle then begin
    if Settings.ExploreStartSet then LaunchExplore(nil) else ShowRoutesPage;
    Exit;
  end;
  RideHistory.CancelResume;
  FreeAndNil(FPendingWorkout);LoadLastMap;
end;
procedure TViewMenu.ResumeActivity(Activity:TJSONObject);
var World,Route:String;
begin
  if not CanLaunchRide then Exit;
  if SessionUnderneath then Exit;
  World:=Activity.Get('world','');Route:=Activity.Get('route','');
  if(World='')and not FileExists(Route)then raise Exception.Create(UiText('File not found: ')+Route);
  RideHistory.RequestResume(Activity);FreeAndNil(FPendingWorkout);
  if World=TrainingOnlyWorld then begin
    if ViewTrainingOnly=nil then ViewTrainingOnly:=TViewTrainingOnly.Create(Application);
    ViewTrainingOnly.Prepare(nil,0);Container.View:=ViewTrainingOnly;Exit;
  end;
  if World<>''then RememberRideMap(rmkDream,World)else RememberRideMap(rmkReal,Route);
  try LoadLastMap;except RideHistory.CancelResume;raise;end;
end;
procedure TViewMenu.StartEditorWorkout(Plan:TWorkoutFile;ReferenceWatts:Double);
begin
  FreeAndNil(FLaunchEditorWorkout);FLaunchEditorWorkout:=Plan.Clone;
  FLaunchEditorReference:=ReferenceWatts;
end;
procedure TViewMenu.StartWorkout(Plan:TWorkoutFile;ReferenceWatts:Double;TrainingOnly:Boolean);
var CopyPlan:TWorkoutFile;
begin
  if Plan=nil then Exit;
  if Settings.TravelMode<>travelBicycle then SelectTravelMode(travelBicycle);
  CopyPlan:=Plan.Clone;FreeAndNil(FPendingWorkout);FPendingWorkout:=CopyPlan;
  FPendingReference:=ReferenceWatts;
  if TrainingOnly then begin
    if not CanLaunchRide then begin FreeAndNil(FPendingWorkout);Exit;end;
    if SessionUnderneath then begin
      ApplyPendingWorkout;
      if RideUnderneath then ViewPlay.TrainingFocusMode:=True;
      ReturnToRide;
    end else begin
      RideHistory.CancelResume;
      if ViewTrainingOnly=nil then ViewTrainingOnly:=TViewTrainingOnly.Create(Application);
      ViewTrainingOnly.Prepare(FPendingWorkout,ReferenceWatts);
      FreeAndNil(FPendingWorkout);Container.View:=ViewTrainingOnly;
    end;
    Exit;
  end;
  if(ReferenceWatts>0)and(not Assigned(DeviceService)or not DeviceService.HasSensor(skPower)or
    not DeviceService.Power.HasData or(DeviceService.Power.DataAgeSec>=3))then
    ShowDevicePrompt
  else ContinueWorkoutLaunch;
end;
procedure TViewMenu.ApplyPendingWorkout;
begin
  if FPendingWorkout=nil then Exit;
  WorkoutPlayer.Start(FPendingWorkout,FPendingReference,FPendingReference>0,FPendingReference>0);
  RememberWorkout(FPendingWorkout.Url);
  RideHistory.SetWorkout(FPendingWorkout.Name,FPendingWorkout.Url);
  FreeAndNil(FPendingWorkout);
end;
procedure TViewMenu.ContinueWorkoutLaunch;
begin
  if SessionUnderneath then begin ApplyPendingWorkout;ReturnToRide;end
  else LoadLastMap;
end;
procedure TViewMenu.RepeatWorkout;
var W:TWorkoutFile;
begin
  W:=TWorkoutFile.Create;
  try
    if W.LoadFromUrl(UserPreference('last_workout'))then StartWorkout(W,EffectiveRiderProfile.FtpW)
    else OpenTab('training');
  finally W.Free;end;
end;
procedure TViewMenu.RepeatActivity(Activity:TJSONObject);
var W:TWorkoutFile;Route:String;
begin
  if Activity=nil then Exit;Route:=Activity.Get('workout_url','');
  if Route<>'' then begin
    W:=TWorkoutFile.Create;
    try if W.LoadFromUrl(Route)then begin StartWorkout(W,EffectiveRiderProfile.FtpW,
      Activity.Get('world','')=TrainingOnlyWorld);Exit;end;
    finally W.Free;end;
  end;
  Route:=Activity.Get('route','');
  if(Route<>'')and FileExists(Route)then begin
    RememberRideMap(rmkReal,Route);
    HideEmbeddedPage;
    if RideUnderneath then begin ViewPlay.ResetRideToFit(Route);Container.PopView;end
    else begin ViewPlay.PrepareDreamWorld(nil);ViewPlay.PrepareRouteTravel;ViewPlay.CurrentFitPath:=Route;Container.View:=ViewPlay;end;
  end else begin
    RememberRideMap(rmkDream,Activity.Get('world',FirstRideWorldId));QuickRide;
  end;
end;
procedure TViewMenu.AcceptFile(const FileName:String);
begin
  if not(SameText(ExtractFileExt(FileName),'.fit')or SameText(ExtractFileExt(FileName),'.gpx')or SameText(ExtractFileExt(FileName),'.zwo'))then Exit;
  FPendingImport:=FileName;
  if Container.PendingFrontView<>Self then
    if ViewPlay.SessionAlive then ViewPlay.OpenMenu
    else if(ViewTrainingOnly<>nil)and ViewTrainingOnly.SessionAlive then ViewTrainingOnly.OpenMenu
    else Container.View:=Self;
end;
procedure TViewMenu.ShowDevicePrompt;
var L:TCastleLabel;B:TMenuButton;
begin
  CloseDevicePrompt;FWaitingPower:=True;
  FLaunchPane:=TCastleRectangleControl.Create(FreeAtStop);FLaunchPane.FullSize:=True;
  FLaunchPane.Color:=Vector4(0.035,0.055,0.08,1);InsertFront(FLaunchPane);
  L:=TMenuLabel.Create(FLaunchPane);BindUiText(L,'Choose your trainer and start pedaling');
  L.Color:=White;L.FontSize:=24;L.Anchor(hpLeft,24);L.Anchor(vpTop,-22);FLaunchPane.InsertFront(L);
  FLaunchDevices:=TDevicesPage.Create(FLaunchPane);FLaunchDevices.Border.Top:=80;FLaunchDevices.Border.Bottom:=90;
  FLaunchPane.InsertFront(FLaunchDevices);FLaunchDevices.PageShown;
  B:=TMenuButton.Create(FLaunchPane);B.Name:='CancelWorkoutLaunch';BindUiText(B,'Back');B.OnClick:=@CancelLaunch;
  B.Anchor(hpLeft,24);B.Anchor(vpBottom,20);FLaunchPane.InsertFront(B);
  B:=TMenuButton.Create(FLaunchPane);B.Name:='StartWithoutPower';BindUiText(B,'Start timed intervals');B.OnClick:=@StartTimed;
  B.Anchor(hpRight,-24);B.Anchor(vpBottom,20);FLaunchPane.InsertFront(B);
end;
procedure TViewMenu.CloseDevicePrompt;
var Old:TCastleRectangleControl;
begin
  FWaitingPower:=False;
  if FLaunchDevices<>nil then FLaunchDevices.PageHidden;
  FLaunchDevices:=nil;Old:=FLaunchPane;FLaunchPane:=nil;
  if Old<>nil then begin Old.Exists:=False;RemoveControl(Old);ApplicationProperties.FreeDelayed(Old);end;
end;
procedure TViewMenu.CancelLaunch(Sender:TObject);
begin CloseDevicePrompt;FreeAndNil(FPendingWorkout);end;
procedure TViewMenu.StartTimed(Sender:TObject);
begin CloseDevicePrompt;FPendingReference:=0;ContinueWorkoutLaunch;end;



procedure TViewMenu.Update(const SecondsPassed: Single;
  var HandleInput: Boolean);
const
  POLL_INTERVAL_SEC = 1.0;
var ImportPath:String;
begin
  inherited;
  if FEndRequested then begin FinishRide;Exit;end;
  if FLaunchEditorWorkout<>nil then begin
    StartWorkout(FLaunchEditorWorkout,FLaunchEditorReference);
    FreeAndNil(FLaunchEditorWorkout);Exit;
  end;
  if FAutoRoute and(FRoutesPage<>nil)and FRoutesPage.Exists and FRoutesPage.ReadyToRide then begin
    FAutoRoute:=False;LaunchSelectedRide(nil);Exit;
  end;

  { Диагностический автозапуск «Свободной езды»: переключение вью
    отложено из Start сюда — SetView в lifecycle-методе вью запрещён. }
  if GFreeRideCliPending then
  begin
    GFreeRideCliPending := False;
    if GFreeRideCliFit <> '' then
      ViewPlay.CurrentFitPath := GFreeRideCliFit
    else
      ViewPlay.CurrentFitPath := SelectedFitPath;
    HideEmbeddedPage;
    Container.View := ViewPlay;
    Exit;
  end;


  if (EffectiveWidth <> FLastLayoutW) or
     (EffectiveHeight <> FLastLayoutH) then
    LayoutTiles;

  { Прокручиваем очередь TThread.Queue. Без этого queued-вызовы
    (например, FlushPendingConnectionChanged в DeviceManager) копятся
    пока юзер сидит в меню, и реальные обработчики (auto-assign
    sim-сенсоров и т.д.) не отрабатывают до входа в FreeRide. }
  CheckSynchronize(0);
  if FPendingImport<>'' then begin
    ImportPath:=FPendingImport;FPendingImport:='';
    if SameText(ExtractFileExt(ImportPath),'.zwo') then begin
      ClickTraining(nil);FTrainingPage.ImportFile(ImportPath);
    end else begin ShowRoutesPage;FRoutesPage.ImportFile(ImportPath);end;
  end;
  if FWaitingPower and Assigned(DeviceService)and DeviceService.HasSensor(skPower)then
    if DeviceService.Power.HasData and(DeviceService.Power.DataAgeSec<3)then begin
      CloseDevicePrompt;ContinueWorkoutLaunch;Exit;
    end;


  FProfilePollAccum := FProfilePollAccum + SecondsPassed;
  if FProfilePollAccum >= POLL_INTERVAL_SEC then
  begin
    FProfilePollAccum := 0;
    BuildProfilePane;
    RefreshRideControls;
  end;
end;

procedure TViewMenu.LanguageChanged(Sender: TObject);
begin
  if FTravelSelector<>nil then FTravelSelector.Refresh;
  BuildProfilePane;
end;

procedure TViewMenu.BuildProfilePane;
var
  P: TVeloSiteProfile;
  E: TVeloSiteEntitlements;
  Sig, Detail, NameStr: String;
  HasProfile: Boolean;
  S:Single;
begin
  { Сигнатура текущего состояния — если она не менялась, ничего не
    делаем (дешёвая опросная петля). Включаем все поля, которые
    отображаем, чтобы изменение веса/FTP/подписки на вкладке «Профиль»
    тут же отразилось при возврате на «Маршруты». }
  HasProfile := VeloSite.IsAuthorized and VeloSite.HasCachedProfile;
  if HasProfile then
  begin
    P := EffectiveRiderProfile;
    E := VeloSite.CachedEntitlements;
    Sig := Format('1|%s|%d|%.1f|%s', [P.Nickname, P.FtpW, P.WeightKg,
      BoolToStr(E.HasAccess, True)]);
  end
  else
    Sig := '0';

  Sig := Sig + '|' + UiLanguage;
  if Sig = FProfilePaneSig then Exit;
  S:=Max(0.65,Min(1,UIScale));
  FProfilePaneSig := Sig;

  if FProfilePane <> nil then
  begin
    RemoveControl(FProfilePane);
    FreeAndNil(FProfilePane);
    FProfileButton      := nil;
    FProfileLabelName   := nil;
    FProfileLabelDetail := nil;
  end;

  { Контейнер: тонкая полоса вверху окна, прибит к правому краю
    (TopBar главного меню часто справа от заголовка). }
  FProfilePane := TMenuPanel.Create(FreeAtStop);
  FProfilePane.Color := MenuSurface;  { светлый слейт }
  FProfilePane.FullSize := False;
  FProfilePane.Anchor(hpRight, -24/S);
  FProfilePane.Anchor(vpTop, -12/S);
  FProfilePane.Width := 230/Max(0.65,Min(1,UIScale));
  FProfilePane.Height := 48/Max(0.65,Min(1,UIScale));
  InsertFront(FProfilePane);

  if not HasProfile then
  begin
    { Гость — большая кнопка "Войти" }
    FProfileButton := TMenuButton.Create(FProfilePane);
    TMenuButton(FProfileButton).AutoIcon:=False;FProfileButton.FontSize:=14/S;
    BindUiText(FProfileButton, 'Sign in');
    FProfileButton.OnClick := @ClickProfilePane;
    FProfileButton.Anchor(hpRight, -8);
    FProfileButton.Anchor(vpMiddle, 0);
    FProfilePane.InsertFront(FProfileButton);

    FProfileLabelName := TMenuLabel.Create(FProfilePane);
    BindUiText(FProfileLabelName, 'Guest');
    FProfileLabelName.FontSize := 16/S;
    FProfileLabelName.Color := Vector4(0.85, 0.85, 0.85, 1.0);
    FProfileLabelName.Anchor(hpLeft, 12);
    FProfileLabelName.Anchor(vpMiddle, 0);
    FProfilePane.InsertFront(FProfileLabelName);
  end
  else
  begin
    { Залогинен — ник сверху, детали под ним; вся плашка кликабельна
      через невидимую кнопку поверх. }
    NameStr := P.Nickname;
    if NameStr = '' then NameStr := P.Email;
    if NameStr = '' then NameStr := T('User');

    if E.HasAccess then
      NameStr := NameStr + '  ★';   { маркер активной подписки }

    Detail := '';
    if P.FtpW > 0 then
      Detail := Format(T('FTP %d W'), [P.FtpW]);
    if P.WeightKg > 0 then
    begin
      if Detail <> '' then Detail := Detail + '   ';
      Detail := Detail + Format(T('%.1f kg'), [P.WeightKg]);
    end;
    if Detail = '' then
      Detail := T('(no profile data)');

    FProfileLabelName := TMenuLabel.Create(FProfilePane);
    FProfileLabelName.Caption := NameStr;
    FProfileLabelName.FontSize := 16/S;
    FProfileLabelName.Color := Vector4(1.0, 1.0, 1.0, 1.0);
    FProfileLabelName.Anchor(hpLeft, 12);
    FProfileLabelName.Anchor(vpTop, -6);
    FProfilePane.InsertFront(FProfileLabelName);

    FProfileLabelDetail := TMenuLabel.Create(FProfilePane);
    FProfileLabelDetail.Caption := Detail;
    FProfileLabelDetail.FontSize := 12/S;
    FProfileLabelDetail.Color := Vector4(0.75, 0.80, 0.85, 1.0);
    FProfileLabelDetail.Anchor(hpLeft, 12);
    FProfileLabelDetail.Anchor(vpBottom, 6);
    FProfilePane.InsertFront(FProfileLabelDetail);

    { Прозрачная кнопка поверх всей плашки — клик ведёт во вкладку
      «Профиль». }
    FProfileButton := TMenuButton.Create(FProfilePane);
    FProfileButton.Caption := '';
    FProfileButton.CustomBackground := True;
    FProfileButton.OnClick := @ClickProfilePane;
    FProfileButton.FullSize := True;
    FProfileButton.CustomColorNormal:=Vector4(0,0,0,0);
    FProfileButton.CustomColorFocused:=Vector4(0.5,0.8,0.9,0.06);
    FProfileButton.CustomColorPressed:=Vector4(0.5,0.8,0.9,0.12);
    FProfilePane.InsertFront(FProfileButton);
  end;
end;

procedure TViewMenu.ClickProfilePane(Sender: TObject);
begin
  if VeloSite.IsAuthorized then
    OpenTab('profile')   { вкладка «Профиль» встроена в меню }
  else
    OpenChildView(ViewLogin);
end;

end.
