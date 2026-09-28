{ GameOsmStreaming — игровая обёртка над стриминговой картой Osm3d.

  Изолирует API Osm3dStreamingLauncher / Osm3dStreamingMap от
  gameviewplay: вся работа с TOsm3dStreamingSession, проекцией
  маршрута и настройками собрана здесь.

  Жизненный цикл (вариант «стриминг заменяет генеренную землю»):

      FOsm := TGameOsmStreaming.Create;
      FOsm.StartFromFit(FitRoute, FitStartUTC, MainViewport, CacheRoot);
      ...                                  { карта стримится сама }
      FOsm.LoadAvatarPath(Avatar.Path);     { путь велосипедиста — без INI }
      ...
      FreeAndNil(FOsm);                     { ДО уничтожения вьюпорта }

  ВАЖНО: освобождать объект нужно раньше, чем будет уничтожен
  TCastleViewport, в чьи Items добавлена карта — сессия владеет картой
  сама (Owner=nil), вьюпорт её не освобождает. Освобождение карты
  само отцепляет её от Viewport.Items (free-notification CGE).

  Проекция: КРИТИЧНО — путь велосипедиста проецируется ТОЙ ЖЕ проекцией,
  что и тайлы мира (Session.GeoToLocal = проекция карты). Иначе трасса и
  мир расходятся тем сильнее, чем дальше от origin: райдер уезжает мимо
  коридора в пустоту (тайла под ним нет → нет высоты → «висит в воздухе»).
  Раньше путь брался из INI (уже в мировых координатах), теперь — из FIT,
  поэтому проекцию нужно брать строго у сессии. }

unit GameOsmStreaming;

{$mode objfpc}{$H+}
{$codepage UTF8}

interface

uses
  Classes, SysUtils,
  CastleVectors, CastleViewport, CastleUIControls,
  Osm3dGeoMath, Osm3dMapUtils, Osm3dStudioSettings, Osm3dStreamingLauncher,
  FitFile, GamePath;

type
  { Назначение ApplySnappedWidths — разный эффект на геометрию пути:
    aspCamera — для кинематограф-камеры / обычной езды по FIT:
      только ширины + centers (притяжение морковки). XZ точек пути
      НЕ двигаем: look-ahead (AdvanceOnPath 50 m) идёт по сырому FIT
      и не thrash'ит yaw (bisect 2026-08-14: pull ломал камеру).
    aspBridge — для мостов / съездов / деки (road-priority track):
      XZ точек с width>0 переписываются на осевую OSM-снапа
      (SetPathPointLocalXZ), чтобы GPS «под мостом» не уводил
      райдера с рампы/деки. Не использовать на пути, который
      читает cinematic camera look-ahead, без отдельного фикса. }
  TApplySnappedPurpose = (aspCamera, aspBridge);

  {$M+}
  TGameOsmStreaming = class
  private
    FSession:    TOsm3dStreamingSession;
    FViewport:   TCastleViewport;
    { Текущий родитель оверлея прогрева (вьюпорт сессии или вью игры
      после RaiseWarmupToFront) — для явного отцепления в Destroy. }
    FOverlayHost: TCastleUserInterface;
    FOrigin:     TLatLon;
    FRoute:      TRouteLatLonArray;
    FActive:     Boolean;

    { Лог стриминга — приходит уже маршалленным в главный поток. }
    procedure HandleStreamLog(const Line: string);

    { Настройки для игры: TStudioSettings.Defaults + переопределения,
      специфичные для встраивания (публичный Overpass, кэш игры,
      выключенные маркеры маршрута). }
    function BuildSettings(const ACacheRoot: string): TStudioSettings;
  public
    constructor Create;
    destructor Destroy; override;

    { Запустить стриминговую карту по FIT-маршруту. AFitRoute — гео-точки
      (TFitFile.RouteLatLon), AStartUTC — TFitFile.RouteStartUTC (солнце),
      AViewport — вьюпорт игры (в его Items добавляется карта; у него
      должна быть назначена камера). ACacheRoot — корневая папка кэша
      тайлов; пусто = кэш Osm3d по умолчанию.

      ARoutesFolder/ASelectedFit — папка заездов и имя выбранного FIT.
      Это БОЕВОЙ путь коррекции: сессия строит FIT-слой высот в Create
      (синхронно, ДО генерации), его сигнатура и имя FIT входят в
      gen-hash дискового кэша. КРИТИЧНО передавать сюда РОВНО то же,
      что «Полная статистика» страницы «Маршруты» передаёт в свой
      Create — иначе gen-hash разойдётся и прогрев вкладки Route
      перестанет попадать в кэш игры (каждый тайл будет генериться
      заново на ходу — райдер обгоняет генерацию и едет по пустоте).
      Пусто → без коррекции (старое поведение).

      Возвращает False, если в маршруте меньше 2 точек. }
    function StartFromFit(const AFitRoute: TFitLatLonArray;
      AStartUTC: TDateTime; AViewport: TCastleViewport;
      const ACacheRoot: string = '';
      const ARoutesFolder: string = '';
      const ASelectedFit: string = ''): Boolean;

    { Запустить асинхронную привязку маршрута к дорожной сети OSM.
      Безопасно звать сразу после StartFromFit; результат публикуется
      позже (см. SnapReady / LoadAvatarPath с ASnapped=True). }
    procedure BeginRouteSnap;

    { True, когда асинхронная привязка маршрута завершена и снапнутый
      трек доступен. Игра опрашивает это в Update и, когда True,
      перестраивает путь велосипедиста на снапнутый маршрут. }
    function SnapReady: Boolean;

    { True, когда подготовка маршрута, запущенная BeginRouteSnap,
      полностью завершена: прогрев тайлов маршрута отработал, снап
      закончился (успехом или неуспехом), экран прогрева спрятан.
      Игра опрашивает это в Update и держит райдера на месте, пока
      подготовка не завершится (иначе райдер обгоняет генерацию
      тайлов и едет по пустоте). False до BeginRouteSnap и при
      неактивной сессии. }
    function RoutePrepDone: Boolean;

    { Диагностика подготовки маршрута для лога ожидания:
      'worker=... hold=... overlay=... snapped=...' либо 'inactive'. }
    function RoutePrepStateStr: string;

    { Прикрепить к пути данные OSM-снапа (1:1 по индексу с FIT).
      APurpose выбирает режим (см. TApplySnappedPurpose):
        aspCamera (default) — widths + centers, XZ FIT не трогаем
          (безопасно для cinematic look-ahead / камеры);
        aspBridge — плюс pull XZ на осевую дороги/деки/съезда
          (приоритет моста; для камеры thrash'ит yaw — только осознанно).
      SnapReady required; иначе no-op. Возвращает число применённых точек. }
    function ApplySnappedWidths(APath: TGamePath;
      APurpose: TApplySnappedPurpose = aspCamera): Integer;

    { Загрузить путь велосипедиста напрямую в TGamePath — без INI.
      ASnapped=False — сырой FIT-маршрут (для старта заезда).
      ASnapped=True — снапнутый на дорожную сеть трек (доступен после
      SnapReady; если снап ещё не готов, грузится сырой маршрут).
      Точки проецируются проекцией СЕССИИ (той же, что тайлы), Y=0
      (рельеф подставит физика). В FPointWidths кладётся ширина дороги
      под точкой (0 = мимо дорог) — только для снапнутого трека.
      Возвращает число загруженных точек (0, если путь пуст/нет сессии). }
    function LoadAvatarPath(APath: TGamePath;
      ASnapped: Boolean = False): Integer;

    { Гео → мировые XZ через проекцию СЕССИИ (Y = 0). Тот же фрейм, что
      у тайлов мира. Нужно, если игре потребуется спроецировать
      произвольную гео-точку в системе координат карты. }
    function ProjectGeo(const AGeo: TLatLon): TVector3;

    { Высота земли стриминговой карты в мировой точке (X, Z).
      Возвращает True и заполняет AY мировым Y рельефа, если тайл,
      покрывающий XZ, уже подгружен; False — если тайл ещё не
      стримился (вызывающая сторона должна сохранить прежний Y).
      Используется физикой велосипедиста вместо raycast-а: тайлы
      Osm3d не имеют коллизий, а этот запрос даёт высоту напрямую
      из рельефного меша тайла. }
    function GroundShadowAt(WorldX, WorldZ: Single): Single;
    function GroundNearYAt(WorldX,WorldZ,ReferenceY:Single; out AY:Single):Boolean;
    function GroundNearYCorrAt(WorldX,WorldZ,ReferenceY:Single; out AY:Single):Boolean;
    function GroundYAt(WorldX, WorldZ: Single; out AY: Single): Boolean;

    { Высота земли с поправкой FIT-слоя — для УКЛОНА физики езды
      (State.SlopeQuery): физика ускорений и инклайн FTMS чувствуют
      нивелированный профиль заездов, а колёса стоят на GroundYAt
      (видимый меш). Тот же контракт промаха: False = прежний Y. }
    function GroundYCorrAt(WorldX, WorldZ: Single; out AY: Single): Boolean;

    { BUILDING_OBSTACLE: soft XZ push if world point is inside a solid
      building footprint (session index on streaming map). }
    function BuildingPushOutXZ(var WorldX, WorldZ: Single): Boolean;
    { BUILDING_OBSTACLE: camera push-out + soft roof lift. }
    function ResolveCameraBuilding(var Cam: TVector3): Boolean;

    { Debug: red/green FIT path spheres on the streaming map. }
    function FitPointOverlaysOn: Boolean;
    procedure SetFitPointOverlays(AOn: Boolean);
    { MCP: JSON analysis of green snap path vs bridges / missing Y. }
    function AnalyzeSnapPathJSON(ARefreshY: Boolean = True;
      ABridgeClearM: Single = 1.5): string;
    function DumpRouteArraysJSON(ARefreshY: Boolean = True;
      AMaxPts: Integer = 0; AStep: Integer = 1): string;

    { Готовность земли под СТАРТОВОЙ точкой маршрута: True и AY = реальная
      высота рельефа, если тайл старта уже смонтирован (GroundYAt по
      проекции первой точки FIT); False — тайл ещё стримится. Игра держит
      холд старта, пока здесь не станет True (или не сработает таймаут). }
    function RouteStartGroundY(out AY: Single): Boolean;

    { Подтвердить постановку райдера на старт: этап «Постановка на старт»
      на оверлее прогрева → done и оверлей гасится. AError <> '' — этап
      помечается ошибкой (старт без точной высоты по таймауту), но оверлей
      всё равно гаснет: езда не блокируется вечно. }
    procedure NotifyRiderPlaced(const AError: string = '');

    { Пересадить оверлей прогрева из вьюпорта в front-список AHost (вью),
      чтобы HUD игры не перекрывал список этапов. Вызывать после
      StartFromFit/BeginRouteSnap; освобождение сессии отцепляет контрол
      само (CGE). }
    procedure RaiseWarmupToFront(AHost: TCastleUserInterface);

    { ── Общее солнце сессии. ──
      Направление ДВИЖЕНИЯ солнечного света (единичный вектор, Y < 0) в
      мировом фрейме стриминговой карты. Направление и доступность тени
      читаются из карты, как в Studio. Без времени маршрута используется
      дневной DEFAULT; реальная ночь/рассвет ниже ~2° не даёт тени. }
    function SunWorldDir(out ADir: TVector3): Boolean;

    property Origin:  TLatLon read FOrigin;
    property Session: TOsm3dStreamingSession read FSession;
  published
    property Active:  Boolean read FActive;
  end;
  {$M-}

implementation

uses
  Math, CastleLog, DebugLog,
  Osm3dStreamingMap, Osm3dRouteBuildings;

constructor TGameOsmStreaming.Create;
begin
  inherited Create;
  FSession    := nil;
  FViewport   := nil;
  FOverlayHost := nil;
  FActive     := False;
  SetLength(FRoute, 0);
end;

destructor TGameOsmStreaming.Destroy;
begin
  { Оверлей прогрева мог быть пересажен из вьюпорта на уровень вью
    (RaiseWarmupToFront). Отцепляем ЯВНО до освобождения сессии: авто-
    отцепление CGE при Free срабатывает уже внутри teardown'а вью и
    падает в UNREGISTERCONTAINER на полуразрушенном контейнере. }
  if (FOverlayHost <> nil) and (FSession <> nil) and
     (FSession.Map <> nil) then
    FOverlayHost.RemoveControl(FSession.Map.WarmupOverlay);
  FOverlayHost := nil;
  { Сессия освобождает карту, фетчер и кэши. Карта при этом сама
    отцепляется от Viewport.Items. Делать это нужно ДО уничтожения
    вьюпорта — гарантируется порядком вызовов в gameviewplay.Stop. }
  FreeAndNil(FSession);
  FViewport := nil;
  inherited Destroy;
end;

procedure TGameOsmStreaming.HandleStreamLog(const Line: string);
begin
  { Лог Osm3d идёт в общий журнал игры (trainer_*.log), а не в
    отдельный CastleLog — чтобы стриминговая диагностика была в том
    же файле, что и остальной лог заезда. }
  if Assigned(Logger) then
    Logger.Info('[Osm3d] ' + Line)
  else
    WritelnLog('Osm3d', Line);
end;

function TGameOsmStreaming.BuildSettings(
  const ACacheRoot: string): TStudioSettings;
begin
  Result := TStudioSettings.Defaults;
  { The shared GPU atlas supplies ground shadows in rides. Keep the CPU
    mask implementation available to the studio, but do not allocate its
    textures, register silhouettes or enqueue raster jobs in game sessions. }
  Result.GenerateGroundShadows := False;
  Result.BuildingShadows := False;

  { Defaults содержит LAN-адрес Overpass dev-машины — для игры он
    недоступен. Ставим публичный пул. (Оставлено закомментированным по
    твоему указанию — dev-URL доступен.) }
  //Result.OverpassEndpoint  := 'https://overpass-api.de/api/interpreter';
  //Result.OverpassEndpoints := 'https://overpass-api.de/api/interpreter';

  { Маркеры FIT-маршрута (красные/зелёные сферы) в игре не нужны —
    индикатор маршрута это сам велосипедист. Снап маршрута при этом
    всё равно работает (BeginRouteSnap), просто без overlay. }
  //Result.ShowFitPoints        := False;
  //Result.ShowFitPointsSnapped := False;

  if ACacheRoot <> '' then
    Result.CacheRoot := ACacheRoot;
end;

function TGameOsmStreaming.StartFromFit(const AFitRoute: TFitLatLonArray;
  AStartUTC: TDateTime; AViewport: TCastleViewport;
  const ACacheRoot: string;
  const ARoutesFolder: string;
  const ASelectedFit: string): Boolean;
var
  Settings: TStudioSettings;
  I: Integer;
begin
  Result := False;
  if FActive then Exit;
  if AViewport = nil then Exit;
  if Length(AFitRoute) < 2 then
  begin
    WritelnLog('Osm3d', 'StartFromFit: маршрут содержит <2 точек, выход');
    Exit;
  end;

  { Копируем гео-маршрут в TRouteLatLonArray (типы совместимы по
    элементу TLatLon, но это разные именованные массивы). }
  SetLength(FRoute, Length(AFitRoute));
  for I := 0 to High(AFitRoute) do
    FRoute[I] := AFitRoute[I];

  FViewport := AViewport;

  { Origin фиксируется на всю сессию. Это НЕ то же, что в студии: та стартует
    с FRoute[0] (Osm3dStudioMainForm.StartStreaming), здесь — центроид. Прежний
    комментарий утверждал обратное («как в эталонном btnGenerateClick») и устарел
    с тех пор, как студия перешла на первую точку.

    Расхождение безвредно: origin задаёт только ПАРАЛЛЕЛЬНЫЙ ПЕРЕНОС кадра
    сессии, метрика от него больше не зависит — cos долготы берётся из
    Settings.WorldScaleLatDeg (широта местности), и выпечка, и расстановка
    тайлов идут по нему. До этого масштаб брался от широты origin, и разные
    origin двух приложений (59.7603 против 59.6715, 9.9 км) давали 0.265%
    расхождения по востоку = щель 1.33 м между тайлами ОДНОГО кэша на ребре
    500 м; север не страдал, т.к. от cos не зависит. }
  FOrigin := TRouteSrc.OriginCentroid(FRoute);

  Settings := BuildSettings(ACacheRoot);

  { The studio pushes settings to the engine's global mirrors via
    ApplyStudioSettingsToGlobals; the game does not (it only hands Settings
    to the session). So BuildingShadows never reaches its global mirror, and
    the shadow gating (TestSun injection, lit composites, shadow-map size)
    stays off in the game. Push just that one mirror from the game settings —
    deliberately NOT the full ApplyStudioSettingsToGlobals, which would also
    overwrite GlobalLODConfig / render toggles the game relies on. }
  Osm3dStudioSettings.BuildingShadowsActive := Settings.BuildingShadows;

  try
    { Папка заездов + выбранный FIT уходят в Create (боевой путь):
      FIT-слой высот строится синхронно ДО генерации, его сигнатура и
      имя FIT входят в gen-hash — коррекция мешей консистентна с
      дисковым кэшем и с прогревом «Полной статистики» (та зовёт Create
      с ТЕМИ ЖЕ аргументами). Первый прогон датума может занять
      секунды (DEM из сети), дальше — CSV-кэш. }
    FSession := TOsm3dStreamingSession.Create(
      Settings, FOrigin, @HandleStreamLog, AStartUTC, FRoute,
      nil, ARoutesFolder, ASelectedFit);
  except
    on E: Exception do
    begin
      WritelnLog('Osm3d', 'StartFromFit: ошибка создания сессии: ' + E.Message);
      FViewport := nil;
      Exit;
    end;
  end;

  { Ключи дискового кэша — в лог. Одна строка отвечает на вопрос «бьёт
    ли игра в кэш, прогретый вкладкой Route»: GenHash и CacheRoot здесь
    обязаны совпадать со строкой, которую пишет ClickFullStats. }
  WritelnLog('Osm3d', Format(
    'StartFromFit: GenHash=%s CacheRoot=%s routesFolder=%s selectedFit=%s',
    [FSession.GenHash, FSession.CacheRoot, ARoutesFolder, ASelectedFit]));

  { Карта — TCastleTransform; добавляем в тот же вьюпорт, где едет
    велосипедист. Стример сам перецентрируется по MainCamera вьюпорта. }
  AViewport.Items.Add(FSession.Map);
  { Прогрев маршрута — общая фича стримера: на время сборки тайлов
    маршрута (до запуска притягивания) карта сама показывает поверх
    вьюпорта плоскую карту области FIT с прогрессом по каждому тайлу. }
  AViewport.InsertFront(FSession.Map.WarmupOverlay);
  FOverlayHost := AViewport;

  { Гейт до постановки райдера: оверлей прогрева не гасится, пока игра
    не подтвердит постановку райдера на реальную землю (NotifyRiderPlaced
    из TViewPlay.Update после снятия холда). }
  FSession.Map.WarmupHoldRider := True;
  { Гасим overlay'и FIT-маршрута на карте — defence in depth. }
  FSession.Map.ShowFitPoints        := False;
  FSession.Map.ShowFitPointsSnapped := False;

  FActive := True;
  Result  := True;
  WritelnLog('Osm3d', Format(
    'StartFromFit: сессия запущена, origin %.6f, %.6f, точек %d',
    [FOrigin.Lat, FOrigin.Lon, Length(FRoute)]));

  { ДИАГНОСТИКА рассинхрона путь↔тайлы: печатаем первую/последнюю точку
    маршрута в проекции СЕССИИ (та же, что тайлы). Если путь визуально
    расходится с коридором — сравни эти координаты с местом старта
    райдера (KinDiag Pos) и с TILE mount координатами. }
  WritelnLog('Osm3d', Format(
    'StartFromFit: route[0] -> world %s ; route[end] -> world %s (проекция сессии)',
    [FSession.GeoToLocal(FRoute[0]).ToString,
     FSession.GeoToLocal(FRoute[High(FRoute)]).ToString]));
end;

procedure TGameOsmStreaming.BeginRouteSnap;
begin
  if not FActive then Exit;
  if FSession = nil then Exit;
  FSession.Map.BeginRouteSnap;
end;

procedure TGameOsmStreaming.RaiseWarmupToFront(AHost: TCastleUserInterface);
begin
  if (not FActive) or (FSession = nil) or (AHost = nil) then Exit;
  { Оверлей вставлен во вьюпорт в StartFromFit, но HUD игры (панель
    Power/Speed) — контрол уровня ВЬЮ и рисуется позже (выше), закрывая
    верх списка этапов. Пересаживаем оверлей в front-список хоста (вью):
    Update/рендер тикают так же (дерево контейнера общее). Вызывать
    ТОЛЬКО из Update, когда вью полностью запущено: во время Start вью
    ещё не в контейнере, и регистрация контейнера при пересадке падает
    (REGISTERCONTAINER AV). }
  if FViewport <> nil then
    FViewport.RemoveControl(FSession.Map.WarmupOverlay);
  AHost.InsertFront(FSession.Map.WarmupOverlay);
  FOverlayHost := AHost;
end;

function TGameOsmStreaming.SnapReady: Boolean;
begin
  Result := FActive and (FSession <> nil) and FSession.Map.SnappedReady
            and (Length(FSession.Map.RideRoute) >= 2);
end;

function TGameOsmStreaming.RoutePrepDone: Boolean;
begin
  Result := FActive and (FSession <> nil) and FSession.Map.RoutePrepDone;
end;

function TGameOsmStreaming.RouteStartGroundY(out AY: Single): Boolean;
var
  P: TVector3;
  I, ProbeN: Integer;
begin
  AY := 0.0;
  Result := False;
  if (not FActive) or (FSession = nil) or (Length(FRoute) < 1) then Exit;
  { Старт маршрута → мировые XZ проекцией СЕССИИ (той же, что тайлы).
    Зондируем первые точки маршрута (до 80): старт может лежать на воде
    или дамбе — там ground-меша нет, GroundYAt в точке route[0] вечно
    False (20-секундный таймаут и райдер на Y=0). Первая grounded
    высота по треку идёт и в гейт, и в начальную постановку. }
  if SnapReady then
  begin
    P:=FSession.GeoToLocal(FSession.Map.RideRoute[0]);
    Exit(GroundYAt(P.X,P.Z,AY));
  end;
  ProbeN := Length(FRoute);
  if ProbeN > 80 then ProbeN := 80;
  for I := 0 to ProbeN - 1 do
  begin
    P := FSession.GeoToLocal(FRoute[I]);
    if GroundYAt(P.X, P.Z, AY) then Exit(True);
  end;
end;

procedure TGameOsmStreaming.NotifyRiderPlaced(const AError: string);
begin
  if (not FActive) or (FSession = nil) then Exit;
  { Ошибку помечаем ПЕРЕД подтверждением: защёлка wssError в карте не даёт
    NotifyRiderPlaced перекрыть её зелёной галочкой. }
  if AError <> '' then
    FSession.Map.WarmupFail(5, AError);
  FSession.Map.NotifyRiderPlaced;
end;

function TGameOsmStreaming.RoutePrepStateStr: string;
begin
  if (not FActive) or (FSession = nil) then
    Result := 'inactive'
  else
    Result := FSession.Map.RoutePrepStateStr;
end;

function TGameOsmStreaming.ProjectGeo(const AGeo: TLatLon): TVector3;
begin
  { Проекция СЕССИИ (= проекция карты), а не отдельная — чтобы гео-точка
    легла ровно в систему координат тайлов. }
  if (FSession = nil) then
    Result := TVector3.Zero
  else
    Result := FSession.GeoToLocal(AGeo);
end;

function TGameOsmStreaming.GroundShadowAt(WorldX, WorldZ: Single): Single;
begin
  Result := 0;
  if FActive and (FSession<>nil) and (FSession.Map<>nil) then
    Result := FSession.Map.GroundShadowAt(WorldX,WorldZ);
end;

function TGameOsmStreaming.GroundNearYAt(WorldX,WorldZ,ReferenceY:Single;
  out AY:Single):Boolean;
begin
  AY:=0; Result:=False;
  if not FActive or (FSession=nil) or (FSession.Map=nil) then Exit;
  Result:=FSession.Map.GroundNearYAt(WorldX,WorldZ,ReferenceY,AY);
end;

function TGameOsmStreaming.GroundNearYCorrAt(WorldX,WorldZ,ReferenceY:Single;
  out AY:Single):Boolean;
begin
  AY:=0; Result:=False;
  if not FActive or (FSession=nil) or (FSession.Map=nil) then Exit;
  Result:=FSession.Map.GroundNearYCorrAt(WorldX,WorldZ,ReferenceY,AY);
end;

function TGameOsmStreaming.GroundYAt(WorldX, WorldZ: Single;
  out AY: Single): Boolean;
const
  ROAD_SURFACE_BIAS_M = 0.00;
begin
  AY := 0.0;
  Result := False;
  if not FActive then Exit;
  if (FSession = nil) or (FSession.Map = nil) then Exit;
  try
    Result := FSession.Map.GroundYAt(WorldX, WorldZ, AY);
    if Result then
      AY := AY + ROAD_SURFACE_BIAS_M;
  except
    { Тайл пересобирается в воркере / карта ещё не готова — камера
      держит прошлый пол, игра не должна падать EAccessViolation. }
    Result := False;
    AY := 0.0;
  end;
end;

function TGameOsmStreaming.GroundYCorrAt(WorldX, WorldZ: Single;
  out AY: Single): Boolean;
const
  ROAD_SURFACE_BIAS_M = 0.00;
begin
  AY := 0.0;
  Result := False;
  if not FActive then Exit;
  if (FSession = nil) or (FSession.Map = nil) then Exit;
  try
    Result := FSession.Map.GroundYCorrAt(WorldX, WorldZ, AY);
    if Result then
      AY := AY + ROAD_SURFACE_BIAS_M;
  except
    Result := False;
    AY := 0.0;
  end;
end;

function TGameOsmStreaming.BuildingPushOutXZ(var WorldX, WorldZ: Single): Boolean;
var
  BaseY, MaxY: Single;
begin
  { BUILDING_OBSTACLE }
  Result := False;
  if not FActive then Exit;
  if FSession = nil then Exit;
  Result := FSession.Map.BuildingPushOutXZ(WorldX, WorldZ, BaseY, MaxY);
end;

function TGameOsmStreaming.ResolveCameraBuilding(var Cam: TVector3): Boolean;
begin
  { BUILDING_OBSTACLE }
  Result := False;
  if not FActive then Exit;
  if FSession = nil then Exit;
  Result := FSession.Map.ResolveCameraBuilding(Cam);
end;

function TGameOsmStreaming.FitPointOverlaysOn: Boolean;
begin
  Result := False;
  if not FActive then Exit;
  if FSession = nil then Exit;
  Result := FSession.Map.FitPointOverlaysOn;
end;

procedure TGameOsmStreaming.SetFitPointOverlays(AOn: Boolean);
begin
  if not FActive then Exit;
  if FSession = nil then Exit;
  FSession.Map.SetFitPointOverlays(AOn);
  WritelnLog('Osm3d', Format('FitPointOverlays: %s',
    [BoolToStr(AOn, True)]));
end;

function TGameOsmStreaming.AnalyzeSnapPathJSON(ARefreshY: Boolean;
  ABridgeClearM: Single): string;
begin
  if (not FActive) or (FSession = nil) then
  begin
    Result := '{"snapped_ready":false,"error":"no active streaming session",'
      + '"summary":{"ok":false}}';
    Exit;
  end;
  Result := FSession.Map.AnalyzeSnapPathJSON(ARefreshY, ABridgeClearM);
end;

function TGameOsmStreaming.DumpRouteArraysJSON(ARefreshY: Boolean;
  AMaxPts: Integer; AStep: Integer): string;
begin
  if (not FActive) or (FSession = nil) then
  begin
    Result := '{"error":"no active streaming session","summary":{"ok":false}}';
    Exit;
  end;
  Result := FSession.Map.DumpRouteArraysJSON(ARefreshY, AMaxPts, AStep);
end;

function TGameOsmStreaming.SunWorldDir(out ADir: TVector3): Boolean;
begin
  Result := False;
  ADir := Vector3(0, -1, 0);
  if not FActive then Exit;
  if FSession = nil then Exit;
  if FSession.Map = nil then Exit;
  Result := FSession.Map.SunWorldShadowDir(ADir);
end;

function TGameOsmStreaming.ApplySnappedWidths(APath: TGamePath;
  APurpose: TApplySnappedPurpose): Integer;
var
  Centers: TRouteLatLonArray;
  Widths: TRouteWidthArray;
  LocalCenters: array of TVector3;
  I: Integer;
begin
  Result:=0;
  if (APath=nil) or not SnapReady then Exit;
  Centers:=FSession.Map.RideRoute;
  Widths:=FSession.Map.RideRouteWidths;
  if Length(Centers)<2 then Exit;
  SetLength(LocalCenters,Length(Centers));
  for I:=0 to High(Centers) do LocalCenters[I]:=FSession.GeoToLocal(Centers[I]);
  { The prepared riding polyline includes building detours. Keep the raw FIT
    and 1:1 snap arrays in the map for height correction and diagnostics. }
  APath.LoadFromMemory(LocalCenters,Widths);
  APath.UsePreparedCornerHints(
    RouteNeedsTurnarounds(FSession.Map.SnappedRouteCenters));
  Result:=Length(Centers);
  WritelnLog('Osm3d',Format('ApplySnappedWidths: prepared building-safe path, %d points',[Result]));
end;

function TGameOsmStreaming.LoadAvatarPath(APath: TGamePath;
  ASnapped: Boolean): Integer;
var
  P: TVector3;
  I: Integer;
  Pts: TRouteLatLonArray;
  Widths: TRouteWidthArray;
  Source: string;
  LocalPts: array of TVector3;
  LocalWidths: array of Single;
begin
  Result := 0;
  if APath = nil then Exit;
  if not FActive then Exit;
  if FSession = nil then Exit;

  { Выбор источника точек: снапнутый трек (если запрошен и готов) или
    сырой FIT-маршрут. Снап ещё не готов → откатываемся на сырой.
    Ширина дороги (Widths) есть только у снапнутого трека. }
  if ASnapped and SnapReady then
  begin
    Pts    := FSession.Map.RideRoute;
    Widths := FSession.Map.RideRouteWidths;
    Source := 'snapped';
  end
  else
  begin
    Pts    := FRoute;
    Widths := nil;
    Source := 'raw';
  end;

  if Length(Pts) < 2 then Exit;

  { КРИТИЧНО: проецируем ТОЙ ЖЕ проекцией, что и тайлы мира —
    FSession.GeoToLocal (= проекция карты). Отдельная TLocalProjection
    давала другой geo→world и путь расходился с коридором (райдер уезжал
    в пустоту). Y = 0: высоту велосипедисту подставит физика (GroundQuery). }
  SetLength(LocalPts, Length(Pts));
  SetLength(LocalWidths, Length(Pts));
  for I := 0 to High(Pts) do
  begin
    P := FSession.GeoToLocal(Pts[I]);
    LocalPts[I] := P;
    if I <= High(Widths) then
      LocalWidths[I] := Widths[I]
    else
      LocalWidths[I] := 0.0;
  end;

  APath.LoadFromMemory(LocalPts, LocalWidths);
  if ASnapped and SnapReady then
    APath.UsePreparedCornerHints(
      RouteNeedsTurnarounds(FSession.Map.SnappedRouteCenters));
  Result := APath.PointCount;

  WritelnLog('Osm3d', Format(
    'LoadAvatarPath: путь загружен (проекция сессии), источник %s, точек %d; '
    + 'start world %s',
    [Source, Result, LocalPts[0].ToString]));
end;

end.
