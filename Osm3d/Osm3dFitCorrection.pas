unit Osm3dFitCorrection;

{$mode objfpc}{$H+}

{ ═══ Коррекция высот террейна по нивелированному FIT ══════════════════

  Что делает. Держит в памяти сессии профиль ПОЛОТНА выбранного заезда
  (приведённые высоты alt_cal из Osm3dFitBank/FitDatum, датум снят) и
  деформирует сетку высот тайла в коридоре дорог перед постройкой меша
  земли — НА ЛЕТУ, при каждом (пере)монтаже тайла. Кэш тайла на диске
  остаётся чистым (базовый Terrarium); коррекция живёт только пока
  активен FIT (см. ТЗ: «тайл в кэше всегда без фита»).

  Геометрия узла (обязана совпадать с BuildGroundLoadingScene):
    сетка AN×AN, row-major AHeights[IZ*AN + IX];
    X = CenterX − SizeX/2 + (AN−1−IX)·StepX;
    Z = CenterZ − SizeZ/2 +          IZ ·StepZ.
  Мы НЕ трогаем порядок/маппинг — только значения высот.

  Профиль. Точки alt_cal проецированы в те же мировые метры (общий
  центроид папки → мировая проекция карты; их совмещает вызывающий).
  Для узла берём цель = alt_cal ближайшей точки трека в пределах
  коридора (полуширина + растушёвка); вес по поперечному расстоянию —
  косинус-спад, как в Osm3dRoadProfile. Несколько точек в коридоре
  усредняются весами (перекрёстки/двойные проезды).

  Мосты. Классификация — вне этого юнита (по SnappedRouteWays), сюда
  приходит уже помеченный профиль: точки настила (BridgeDeck=True) не
  влияют на землю и наоборот — землю правят только не-настильные точки.
  Настилы мостов деформируются отдельным вызовом ApplyToDeckMesh. }

interface

uses
  Classes, SysUtils, Math,
  CastleVectors,          { TVector3 }
  Osm3dSceneMaterials,    { TSceneMaterialKind, smk* }
  Osm3dTileX3D,           { TTileModel, TTileRoadSeg }
  Osm3dGeomMesh;          { TMesh }

const
  { Полуширина коридора коррекции, м (полотно + обочина). }
  CORR_HALF_WIDTH_M = 4.0;
  { Поперечная растушёвка за коридором, м. Была 6: при |дельте| до
    CORR_MAX_DELTA_M склон выходил 2:1 (стена) и местами весь спад
    попадал внутрь одного треугольника крупной сетки рельефа —
    визуальный обрыв с зигзагом по рёбрам. }
  CORR_FEATHER_M    = 9.0;
  { Радиус поиска точек трека вокруг узла, м (коридор+феатер+запас). }
  CORR_SEARCH_M     = 15.0;
  { Ячейка пространственного хэша точек трека, м. ДОЛЖНА быть не меньше
    CORR_HALF_WIDTH_M + CORR_FEATHER_M: TargetAt сканирует 3×3 ячейки,
    worst-case охват = размер ячейки. }
  CORR_CELL_M       = 15.0;

  { Окно продольного усреднения целей вдоль way (жёсткий профиль
    настила/ленты), м. }
  CORR_ALONG_M      = 45.0;
  { Окно медианного сглаживания дельт целей, м: гасит квантовый шум
    refY и выбросы, не размывая настоящий уклон (короткое). }
  CORR_SMOOTH_M     = 18.0;
  { СТРАХОВОЧНЫЙ вертикальный предел привязки цели к way, м. Прежний
    CORR_VERT_TOL_M=8 был БИНАРНЫМ вето: там, где DEM разошёлся с FIT
    сильнее 8 м (лес, развязки), цели не привязывались вовсе, и вдоль
    дороги коррекция «включалась» скачком в точке, где расходимость
    опускалась под порог. Роль порога (точка под мостом не должна
    прилипнуть к настилу) теперь играет выбор ближайшей ПО ВЕРТИКАЛИ
    way среди горизонтальных кандидатов; предел — только защита от
    совсем чужих поверхностей. }
  CORR_VERT_REJECT_M = 25.0;
  { Вертикаль решает выбор way ТОЛЬКО при явном расслоении поверхностей
    (мост: настил выше нижней дороги минимум на это), м. Иначе выбор —
    по горизонтали: параллельные ways одного уровня (тротуар вдоль
    шоссе) перехватывали бы цели по сантиметровому шуму высот,
    распыляя профиль между ways. }
  CORR_VERT_DECIDE_M = 3.0;
  { Запас обочины за кромкой полотна (полуширина сегмента), м:
    рельеф в этой полосе едет с полотном на полный вес. }
  CORR_EDGE_MARGIN_M = 1.5;
  { Радиус «любой» вертикальной опоры цели, м: когда у way нет СВОИХ
    вершин (обычная дорога запечена карвом в композит и её вершины не
    несут OsmId — id есть только у настилов мостов, EmitDeck), опора
    берётся с ближайшей поверхности тайла прямо под точкой. }
  CORR_REF_ANY_M = 4.0;
  { Предохранитель: максимум |сдвига| вершины, м. }
  CORR_MAX_DELTA_M  = 12.0;
  { Материалы рельефа — зеркало GROUND_MESH_KINDS карты. }
  CORR_GROUND_KINDS = [smkTerrain, smkGrass, smkSurface, smkSand,
                       smkFarmland, smkForest];
  { Материалы ПОЛОТНА дороги (отдельный непрерывный меш). OSM-центрлинии
    RoadSeg рвутся на стыках way, а полотно построено сплошным — по нему
    и держим коридор коррекции, чтобы срез не выпадал в дырах OSM
    («стены»). Railway намеренно исключён — по рельсам не едут. }
  CORR_ROAD_KINDS   = [smkRoad, smkRoadMajor, smkRoadSecondary,
                       smkRoadMinor, smkRoadService, smkRoadFootway,
                       smkRoadCycleway];
  { Радиус «на полотне», м: вершина рельефа в этом радиусе от вершины
    полотна корректируется даже без ближайшего сегмента RoadSeg. }
  CORR_PAVE_M       = 6.0;

type
  { Точка нивелированного профиля в МИРОВЫХ метрах карты. }
  TFitCorrPoint = record
    X, Z:      Double;
    AltCal:    Double;    { приведённая высота (цель полотна) }
    BridgeDeck: Boolean;  { True — точка на настиле моста }
    { Доверие точке 0..1: старт заезда (барометр не калиброван, GPS
      плывёт) приходит с весом ~0, полный вес — после прогрева
      (FIT_WARMUP_SEC в карте). Затухает цели и невязки лока; на кольце
      место старта корректируют финишные точки с полным весом.
      0 в SetProfile трактуется как «не задано» → 1. }
    Conf:      Double;
    { Рабочие поля ApplyToTileModel (кэш привязки на время вызова;
      снаружи не заполнять). }
    TmpWay:    Integer;
    TmpRefY:   Double;
  end;
  TFitCorrPointArray = array of TFitCorrPoint;

  { Профиль коррекции: точки + пространственный хэш для быстрого
    поиска ближайших в коридоре узла. }
  TFitCorrection = class
  private
    FPts:  TFitCorrPointArray;
    { Разреженный пространственный хэш точек трека (open addressing).
      Раньше — плотная матрица голов списков FNB×FNB на весь bbox трека:
      трек — тонкая линия в огромном bbox, на длинном заезде матрица
      съедала десятки-сотни МБ впустую. Теперь таблица ~2×числа точек:
      FHTab — ключ ячейки (GZ shl 32 or GX), FHHead — голова цепочки,
      FNext — звенья цепочки (как прежде). }
    FHTab: array of QWord;
    FHHead, FNext: array of Integer;
    FHMask: Integer;           { размер таблицы − 1; 0 = хэш не построен }
    FMinX, FMinZ, FInv: Double;
    FActive: Boolean;
    { Единый уровневый сдвиг датум-боевой меш: невязки (alt_cal минус
      опорная вершина) копятся по ВСЕМ тайлам первого батча, медиана
      вычитается из AltCal один раз (лок). До лока вершины не
      трогаются - иначе тайлы получили бы разные нули. }
    FLvlBuf: array of Double;
    FLvlN: Integer;
    FLevelLocked: Boolean;
    FLevelOffset: Double;
    FLastBound: Integer;   { целей привязано последним вызовом }
    FLastMoved: Integer;   { вершин сдвинуто последним вызовом }
    { Диагностика последнего ApplyToTileModel — где теряются цели
      (сводку печатает карта): точек в bbox тайла; без горизонтальных
      кандидатов; кандидаты без вертикальной опоры в 7 м; вето по
      CORR_VERT_REJECT_M; ways с целями; сегментов кромочного поля;
      сдвинуто way-вершин / рельефных раздельно. }
    FLastPtsBox, FLastNoCand, FLastNoRef, FLastVeto: Integer;
    FLastWaysT, FLastEdgeSegs: Integer;
    FLastMovedWay, FLastMovedGnd: Integer;
    { Детектор «нужна коррекция, но не сделана»: вершины у трека
      (в EdgeGate), которые НЕ сдвинулись, с разбивкой по причине +
      сэмпл позиций/материала для лога. }
    FDiagWallNear, FDiagWallMoved: Integer;
    FDiagWallMat, FDiagWallNoCover, FDiagWallPaveND, FDiagWallDeck: Integer;
    FDiagWallSample: string;
    procedure BuildHash;
    { Цель высоты для мировой точки (X,Z): взвешенное среднее alt_cal
      точек трека в коридоре. ADeck — искать среди настильных (True)
      или наземных (False) точек. Возвращает вес (0 = не в коридоре). }
    function TargetAt(X, Z: Double; ADeck: Boolean; out AY: Double): Double;
    { Слот ключа ячейки в таблице (умножение на константу Фибоначчи). }
    function HashSlot(Key: QWord): Integer;
    { Голова цепочки точек ячейки (GX,GZ) или -1, если ячейка пуста. }
    function CellHead(GX, GZ: Integer): Integer;
  public
    constructor Create;
    destructor Destroy; override;
    { Задать профиль (мировые метры). Пустой массив — деактивирует. }
    procedure SetProfile(const APts: TFitCorrPointArray);
    { Копия профиля из другого экземпляра — для использования из
      ФОНОВОГО потока (сверка высот студии): ApplyToTileModel пишет
      рабочие поля (TmpWay/TmpRefY, счётчики), дёргать общий экземпляр
      из двух потоков нельзя. Точки после лока уже несут batch-level
      сдвиг; статус лока наследуется, хэш перестраивается. }
    procedure CopyFrom(ASrc: TFitCorrection);
    procedure Clear;
    property Active: Boolean read FActive;

    { Деформировать сетку высот тайла ПЕРЕД постройкой меша земли.
      AHeights — row-major AN×AN (как GridH). Center/Size — из того же
      источника, что BuildGroundLoadingScene получает. Наземные точки
      (BridgeDeck=False). Возвращает число изменённых узлов. }
    function ApplyToGroundGrid(var AHeights: array of Single; AN: Integer;
      ACenterX, ACenterZ, ASizeX, ASizeZ: Double): Integer;

    { Деформировать БОЕВУЮ модель тайла перед сборкой сцены (MountBatch):
      вершины с OsmId — жёстким профилем вдоль их way (цели банка,
      3D-привязка: «по мосту» двигает настил, «под мостом» — землю;
      сечение целиком, рампы сползают к наземному полю сами); рельеф
      GROUND-материалов без id — точечным полем в коридоре. Центр —
      мировой центр тайла (вершины тайл-локальны). Кэш не трогается:
      модель правится в памяти на каждом (пере)монтаже. }
    function ApplyToTileModel(AModel: TTileModel;
      ATileCenterX, ATileCenterZ: Double): Integer;

    { Лок уровня: если накоплено >= AMinResiduals невязок - вычесть их
      медиану из AltCal всех точек (единый ноль для всех тайлов) и
      разрешить деформацию. True при локе; OutOffset - сдвиг. }
    function TryLockLevel(AMinResiduals: Integer;
      out OutOffset: Double): Boolean;
    property LevelLocked: Boolean read FLevelLocked;
    property LastBound: Integer read FLastBound;
    property LastMoved: Integer read FLastMoved;
    property LastPtsBox: Integer read FLastPtsBox;
    property LastNoCand: Integer read FLastNoCand;
    property LastNoRef: Integer read FLastNoRef;
    property LastVeto: Integer read FLastVeto;
    property LastWaysT: Integer read FLastWaysT;
    property LastEdgeSegs: Integer read FLastEdgeSegs;
    property LastMovedWay: Integer read FLastMovedWay;
    property LastMovedGnd: Integer read FLastMovedGnd;
    { Детектор стен. }
    property DiagWallNear: Integer read FDiagWallNear;
    property DiagWallMoved: Integer read FDiagWallMoved;
    property DiagWallMat: Integer read FDiagWallMat;
    property DiagWallNoCover: Integer read FDiagWallNoCover;
    property DiagWallPaveND: Integer read FDiagWallPaveND;
    property DiagWallDeck: Integer read FDiagWallDeck;
    property DiagWallSample: string read FDiagWallSample;
  end;

implementation

const
  { Пустой слот хэш-таблицы ячеек: ключи несут GZ ≥ 0 в старших 32 битах,
    «все единицы» (это был бы GZ = -1) ключом быть не может. }
  HASH_EMPTY_KEY = QWord($FFFFFFFFFFFFFFFF);

constructor TFitCorrection.Create;
begin
  inherited Create;
  FActive := False;
  FHMask := 0;
end;

destructor TFitCorrection.Destroy;
begin
  inherited Destroy;
end;

procedure TFitCorrection.Clear;
begin
  SetLength(FPts, 0);
  SetLength(FHTab, 0);
  SetLength(FHHead, 0);
  SetLength(FNext, 0);
  FHMask := 0;
  FActive := False;
  FLvlN := 0;
  FLevelLocked := False;
  FLevelOffset := 0;
end;

procedure TFitCorrection.SetProfile(const APts: TFitCorrPointArray);
var
  I: Integer;
begin
  FPts := Copy(APts, 0, Length(APts));
  { обратная совместимость: незаданное доверие = полное }
  for I := 0 to High(FPts) do
    if FPts[I].Conf <= 0 then FPts[I].Conf := 1.0;
  FActive := Length(FPts) >= 2;
  FLvlN := 0;
  FLevelLocked := False;
  FLevelOffset := 0;
  if FActive then BuildHash;
end;

procedure TFitCorrection.CopyFrom(ASrc: TFitCorrection);
begin
  if ASrc = nil then
  begin
    Clear;
    Exit;
  end;
  FPts := Copy(ASrc.FPts, 0, Length(ASrc.FPts));
  FActive := ASrc.FActive;
  FLevelLocked := ASrc.FLevelLocked;
  FLevelOffset := ASrc.FLevelOffset;
  FLvlN := 0;   { копия невязок не копит — уровень уже решён источником }
  if FActive then BuildHash;
end;

function TFitCorrection.HashSlot(Key: QWord): Integer;
begin
  Key := Key * QWord($9E3779B97F4A7C15);
  Result := Integer((Key xor (Key shr 32)) and QWord(FHMask));
end;

function TFitCorrection.CellHead(GX, GZ: Integer): Integer;
var
  Key: QWord;
  Slot: Integer;
begin
  if FHMask = 0 then Exit(-1);
  Key := (QWord(GZ) shl 32) or QWord(Cardinal(GX));
  Slot := HashSlot(Key);
  while FHTab[Slot] <> HASH_EMPTY_KEY do
  begin
    if FHTab[Slot] = Key then Exit(FHHead[Slot]);
    Slot := (Slot + 1) and FHMask;
  end;
  Result := -1;
end;

procedure TFitCorrection.BuildHash;
var
  I, GX, GZ, Slot, Size: Integer;
  Key: QWord;
begin
  { bbox больше не нужен как размер матрицы — только база координат
    ячеек, чтобы GX/GZ (и ключи) были неотрицательны }
  FMinX := FPts[0].X;
  FMinZ := FPts[0].Z;
  for I := 1 to High(FPts) do
  begin
    if FPts[I].X < FMinX then FMinX := FPts[I].X;
    if FPts[I].Z < FMinZ then FMinZ := FPts[I].Z;
  end;
  FInv := 1.0 / CORR_CELL_M;
  { Уникальных ячеек не больше, чем точек: таблица с запасом ≥2×N даёт
    load factor ≤ 0.5 без рехэша. Цепочки внутри ячейки строятся как
    раньше (вставкой в голову в порядке индексов) — порядок перебора
    кандидатов в запросах не изменился. }
  Size := 16;
  while Size < Length(FPts) * 2 do Size := Size * 2;
  FHMask := Size - 1;
  SetLength(FHTab, Size);
  SetLength(FHHead, Size);
  for Slot := 0 to Size - 1 do FHTab[Slot] := HASH_EMPTY_KEY;
  SetLength(FNext, Length(FPts));
  for I := 0 to High(FPts) do
  begin
    GX := Trunc((FPts[I].X - FMinX) * FInv);
    GZ := Trunc((FPts[I].Z - FMinZ) * FInv);
    Key := (QWord(GZ) shl 32) or QWord(Cardinal(GX));
    Slot := HashSlot(Key);
    while (FHTab[Slot] <> HASH_EMPTY_KEY) and (FHTab[Slot] <> Key) do
      Slot := (Slot + 1) and FHMask;
    if FHTab[Slot] = Key then
      FNext[I] := FHHead[Slot]
    else
    begin
      FHTab[Slot] := Key;
      FNext[I] := -1;
    end;
    FHHead[Slot] := I;
  end;
end;

function TFitCorrection.TargetAt(X, Z: Double; ADeck: Boolean;
  out AY: Double): Double;
var
  CX, CZ, GX, GZ, Idx: Integer;
  D, WSum, WYSum, Wl, MaxW, HalfW, Feather: Double;
begin
  Result := 0; AY := 0;
  if FHMask = 0 then Exit;
  HalfW := CORR_HALF_WIDTH_M;
  Feather := CORR_FEATHER_M;
  WSum := 0; WYSum := 0; MaxW := 0;
  CX := Trunc((X - FMinX) * FInv);
  CZ := Trunc((Z - FMinZ) * FInv);
  for GZ := CZ - 1 to CZ + 1 do
    for GX := CX - 1 to CX + 1 do
    begin
      Idx := CellHead(GX, GZ);
      while Idx >= 0 do
      begin
        if FPts[Idx].BridgeDeck = ADeck then
        begin
          D := Sqrt(Sqr(FPts[Idx].X - X) + Sqr(FPts[Idx].Z - Z));
          if D < HalfW + Feather then
          begin
            if D <= HalfW then
              Wl := 1.0
            else
              Wl := 0.5 * (1.0 + Cos(Pi * (D - HalfW) / Feather));
            Wl := Wl * FPts[Idx].Conf;   { прогрев старта затухает вклад }
            WSum := WSum + Wl;
            WYSum := WYSum + Wl * FPts[Idx].AltCal;
            if Wl > MaxW then MaxW := Wl;
          end;
        end;
        Idx := FNext[Idx];
      end;
    end;
  if WSum > 1e-6 then
  begin
    AY := WYSum / WSum;
    { Вес смешивания — МАКСИМУМ Wl, а не сумма: точки трека идут через
      ~2 м, в радиусе их десятки, сумма ≫1 и после клампа давала
      бинарное «яма/не яма» — косинус-феатер тонул, край зоны
      обрывался ступенью. Max — гладкая функция поперечного расстояния
      до трека: 1 в коридоре, косинус к нулю на кромке феатера. Цель
      AY остаётся взвешенным средним (устойчива к шуму точек). }
    Result := MaxW;
  end;
end;

function TFitCorrection.ApplyToGroundGrid(var AHeights: array of Single;
  AN: Integer; ACenterX, ACenterZ, ASizeX, ASizeZ: Double): Integer;
var
  IX, IZ: Integer;
  StepX, StepZ, OX, OZ, WX, WZ, TY, W, Alpha: Double;
begin
  Result := 0;
  if (not FActive) or (AN < 2) then Exit;
  StepX := ASizeX / (AN - 1);
  StepZ := ASizeZ / (AN - 1);
  OX := ACenterX - ASizeX * 0.5;
  OZ := ACenterZ - ASizeZ * 0.5;
  for IZ := 0 to AN - 1 do
    for IX := 0 to AN - 1 do
    begin
      { мировые XZ узла — та же формула, что BuildGroundLoadingScene }
      WX := OX + (AN - 1 - IX) * StepX;
      WZ := OZ + IZ * StepZ;
      W := TargetAt(WX, WZ, False, TY);
      if W > 1e-6 then
      begin
        { мягкое смешивание: в центре коридора почти целиком цель,
          к кромке — исходная высота (W уже спал косинусом) }
        Alpha := W;
        if Alpha > 1.0 then Alpha := 1.0;
        AHeights[IZ * AN + IX] :=
          AHeights[IZ * AN + IX] * (1.0 - Alpha) + TY * Alpha;
        Inc(Result);
      end;
    end;
end;

function TFitCorrection.ApplyToTileModel(AModel: TTileModel;
  ATileCenterX, ATileCenterZ: Double): Integer;
type
  TWayTarget = record
    X, Z:  Double;   { мир }
    Delta: Double;   { alt_cal − высота поверхности way в точке }
    Deck:  Boolean;  { цель настила: кромочное поле РЕЛЬЕФА её пропускает
                       (земля под мостом не должна ехать с настилом) }
    Conf:  Double;   { доверие точки (прогрев старта) — множитель веса }
  end;
var
  { уникальные WayId, отсортированы — бинпоиск везде }
  WayIds: array of Int64;
  NW: Integer;
  { сегменты, сгруппированные по way: SegIdx[SegLo[w]..SegHi[w]) }
  SegIdx, SegLo, SegHi: array of Integer;
  { вершины: плоские списки + группировка по way тем же приёмом }
  VtxMesh, VtxV, VtxWayIdx: array of Integer;
  NV: Integer;
  WVtxIdx, WVtxLo, WVtxHi: array of Integer;
  { цели по way }
  Targets: array of TWayTarget;
  TgtCnt, TgtLo, TgtHi: array of Integer;
  GndCnt: array of Integer;        { наземных целей на way }
  NT: Integer;
  BbMinX, BbMaxX, BbMinZ, BbMaxZ: Double;
  { горизонтальные кандидаты привязки цели: мин. дист² до сегментов way }
  CandD2: array of Double;
  { кромочное поле рельефа: плоский список сегментов ways с наземными
    целями (полуширина полотна+обочина) }
  EsX0, EsZ0, EsX1, EsZ1, EsHalf: array of Double;
  EsWay: array of Integer;
  NE: Integer;
  EdgeGate: Double;                { радиус гейта по треку для рельефа }
  { Пул опорных вершин тайла (мировые XZ + Y): рельеф GROUND_KINDS +
    все вершины с OsmId. С него снимается вертикальная опора цели,
    когда своих way-вершин нет (см. CORR_REF_ANY_M). Хэш 6 м. }
  RefX, RefZ, RefYv: array of Single;
  RefHead, RefNext: array of Integer;
  RefMinX, RefMinZ, RefInv: Double;
  RefNB, NRef: Integer;
  { Пул вершин ПОЛОТНА (road-материалы) — непрерывный коридор коррекции.
    Хэш 6 м. }
  PaveX, PaveZ: array of Single;
  PaveHead, PaveNext: array of Integer;
  PaveMinX, PaveMinZ, PaveInv: Double;
  PaveNB, NPave: Integer;
  { Дельта на КАЖДУЮ точку профиля (alt_cal − опора) + признак пригодности
    как наземной цели-в-разрыве. Для точек без OSM-way (nocand) опора —
    AnyRefY; так разрыв OSM режется по трекам, лежащим на полотне. }
  PtDelta: array of Double;
  PtPave: array of Boolean;

  function FindWay(AId: Int64): Integer;
  var Lo, Hi, Mid: Integer;
  begin
    Lo := 0;
    Hi := NW - 1;
    while Lo <= Hi do
    begin
      Mid := (Lo + Hi) div 2;
      if WayIds[Mid] = AId then Exit(Mid)
      else if WayIds[Mid] < AId then Lo := Mid + 1
      else Hi := Mid - 1;
    end;
    Result := -1;
  end;

  { Квадрат дистанции до сегмента - Sqrt не нужен для сравнения. }
  procedure SegClosestSq(const S: TTileRoadSeg; X, Z: Double;
    out D2: Double);
  var AX, AZ, EX, EZ, LL, T: Double;
  begin
    AX := ATileCenterX + S.X0;  AZ := ATileCenterZ + S.Z0;
    EX := S.X1 - S.X0;          EZ := S.Z1 - S.Z0;
    LL := EX * EX + EZ * EZ;
    if LL < 1e-9 then T := 0
    else
    begin
      T := ((X - AX) * EX + (Z - AZ) * EZ) / LL;
      if T < 0 then T := 0 else if T > 1 then T := 1;
    end;
    D2 := Sqr(X - (AX + EX * T)) + Sqr(Z - (AZ + EZ * T));
  end;

  { Вертикальная опора с ЛЮБОЙ поверхности: min |Y − AAltCal| среди
    опорных вершин в радиусе CORR_REF_ANY_M от точки. }
  function AnyRefY(X, Z, AAltCal: Double; out AY: Double): Boolean;
  var
    CX, CZ, GX, GZ, Idx, RC: Integer;
    BestDh, DhL: Double;
  begin
    Result := False;
    AY := 0;
    if RefNB = 0 then Exit;
    BestDh := 1e30;
    RC := Trunc(CORR_REF_ANY_M * RefInv) + 1;
    CX := Trunc((X - RefMinX) * RefInv);
    CZ := Trunc((Z - RefMinZ) * RefInv);
    for GZ := CZ - RC to CZ + RC do
      for GX := CX - RC to CX + RC do
      begin
        if (GX < 0) or (GX > RefNB - 1) or
           (GZ < 0) or (GZ > RefNB - 1) then Continue;
        Idx := RefHead[GZ * RefNB + GX];
        while Idx >= 0 do
        begin
          if Sqr(RefX[Idx] - X) + Sqr(RefZ[Idx] - Z) <=
             CORR_REF_ANY_M * CORR_REF_ANY_M then
          begin
            DhL := Abs(RefYv[Idx] - AAltCal);
            if DhL < BestDh then
            begin
              BestDh := DhL;
              AY := RefYv[Idx];
              Result := True;
            end;
          end;
          Idx := RefNext[Idx];
        end;
      end;
  end;

  { Расстояние до ближайшей точки трека в радиусе R (или R, если нет) —
    для косинусного феатера наземного среза в разрывах OSM: полотно
    непрерывно вдоль ТРЕКА, феатер по дистанции до трека даёт плавный
    спад вместо жёсткого обрыва (стены). }
  function TrackDist(X, Z, R: Double): Double;
  var
    CX, CZ, GX, GZ, Idx, RC: Integer;
    D2, Best: Double;
  begin
    Best := R * R;
    if FHMask = 0 then Exit(Sqrt(Best));
    RC := Trunc(R * FInv) + 1;
    CX := Trunc((X - FMinX) * FInv);
    CZ := Trunc((Z - FMinZ) * FInv);
    for GZ := CZ - RC to CZ + RC do
      for GX := CX - RC to CX + RC do
      begin
        Idx := CellHead(GX, GZ);
        while Idx >= 0 do
        begin
          if PtPave[Idx] and (not FPts[Idx].BridgeDeck) then
          begin
            D2 := Sqr(FPts[Idx].X - X) + Sqr(FPts[Idx].Z - Z);
            if D2 < Best then Best := D2;
          end;
          Idx := FNext[Idx];
        end;
      end;
    Result := Sqrt(Best);
  end;

  { Целевая ГОЛУБАЯ высота в точке (WX,WZ): взвешенное по дистанции и
    доверию среднее AltCal окрестных НАЗЕМНЫХ треков (окно CORR_ALONG_M).
    Для ЖЁСТКОГО приведения полотна: вершина полотна ставится ТОЧНО на эту
    высоту (не сдвигается дельтой), поэтому дорога ложится ровно на голубую
    кривую без остаточной ВЧ-вариации рельефа. }
  function PaveTargetY(WX, WZ: Double; out AY: Double): Boolean;
  var
    CX, CZ, GX, GZ, Idx, RC: Integer;
    DL, WS, DS, Wl: Double;
  begin
    Result := False;
    AY := 0;
    if FHMask = 0 then Exit;
    WS := 0; DS := 0;
    RC := Trunc(CORR_ALONG_M * FInv) + 1;
    CX := Trunc((WX - FMinX) * FInv);
    CZ := Trunc((WZ - FMinZ) * FInv);
    for GZ := CZ - RC to CZ + RC do
      for GX := CX - RC to CX + RC do
      begin
        Idx := CellHead(GX, GZ);
        while Idx >= 0 do
        begin
          if not FPts[Idx].BridgeDeck then
          begin
            DL := Sqr(FPts[Idx].X - WX) + Sqr(FPts[Idx].Z - WZ);
            if DL < CORR_ALONG_M * CORR_ALONG_M then
            begin
              DL := Sqrt(DL);
              Wl := (1.0 - DL / CORR_ALONG_M) * FPts[Idx].Conf;
              WS := WS + Wl;
              DS := DS + Wl * FPts[Idx].AltCal;
            end;
          end;
          Idx := FNext[Idx];
        end;
      end;
    if WS > 0.05 then
    begin
      AY := DS / WS;
      Result := True;
    end;
  end;

  { Есть ли точка трека в радиусе R — дешёвый гейт для рельефа
    (пространственный хэш профиля; охват ячеек по радиусу). }
  function NearTrack(X, Z, R: Double): Boolean;
  var
    CX, CZ, GX, GZ, Idx, RC: Integer;
    R2: Double;
  begin
    Result := False;
    if FHMask = 0 then Exit;
    R2 := R * R;
    RC := Trunc(R * FInv) + 1;
    CX := Trunc((X - FMinX) * FInv);
    CZ := Trunc((Z - FMinZ) * FInv);
    for GZ := CZ - RC to CZ + RC do
      for GX := CX - RC to CX + RC do
      begin
        Idx := CellHead(GX, GZ);
        while Idx >= 0 do
        begin
          if Sqr(FPts[Idx].X - X) + Sqr(FPts[Idx].Z - Z) <= R2 then
            Exit(True);
          Idx := FNext[Idx];
        end;
      end;
  end;

  { Дистанция² до ближайшей вершины ПОЛОТНА (пул PaveX/PaveZ). Возвращает
    True, если в радиусе CORR_PAVE_M — вершина рельефа «на полотне»,
    её режем даже без ближайшего сегмента RoadSeg. }
  function NearPave(X, Z: Double): Boolean;
  var
    CX, CZ, GX, GZ, Idx, RC: Integer;
  begin
    Result := False;
    if PaveNB = 0 then Exit;
    RC := Trunc(CORR_PAVE_M * PaveInv) + 1;
    CX := Trunc((X - PaveMinX) * PaveInv);
    CZ := Trunc((Z - PaveMinZ) * PaveInv);
    for GZ := CZ - RC to CZ + RC do
      for GX := CX - RC to CX + RC do
      begin
        if (GX < 0) or (GX > PaveNB - 1) or
           (GZ < 0) or (GZ > PaveNB - 1) then Continue;
        Idx := PaveHead[GZ * PaveNB + GX];
        while Idx >= 0 do
        begin
          if Sqr(PaveX[Idx] - X) + Sqr(PaveZ[Idx] - Z) <=
             CORR_PAVE_M * CORR_PAVE_M then Exit(True);
          Idx := PaveNext[Idx];
        end;
      end;
  end;

  { Дельта в точке (WX,WZ) по НАЗЕМНЫМ трекам вокруг (хэш профиля,
    продольное окно CORR_ALONG_M, веса × Conf, знаменатель — чистая
    геометрия). Для среза рельефа на полотне в разрывах OSM, где нет
    сегмента RoadSeg и потому нет way-целей. }
  function PaveDelta(WX, WZ: Double; out ADelta: Double): Boolean;
  var
    CX, CZ, GX, GZ, Idx, RC: Integer;
    DL, WS, GS, DS, Wl: Double;
  begin
    Result := False;
    ADelta := 0;
    if FHMask = 0 then Exit;
    WS := 0; GS := 0; DS := 0;
    RC := Trunc(CORR_ALONG_M * FInv) + 1;
    CX := Trunc((WX - FMinX) * FInv);
    CZ := Trunc((WZ - FMinZ) * FInv);
    for GZ := CZ - RC to CZ + RC do
      for GX := CX - RC to CX + RC do
      begin
        Idx := CellHead(GX, GZ);
        while Idx >= 0 do
        begin
          if PtPave[Idx] and (not FPts[Idx].BridgeDeck) then
          begin
            DL := Sqr(FPts[Idx].X - WX) + Sqr(FPts[Idx].Z - WZ);
            if DL < CORR_ALONG_M * CORR_ALONG_M then
            begin
              DL := Sqrt(DL);
              Wl := 1.0 - DL / CORR_ALONG_M;
              GS := GS + Wl;
              Wl := Wl * FPts[Idx].Conf;
              WS := WS + Wl;
              DS := DS + Wl * PtDelta[Idx];
            end;
          end;
          Idx := FNext[Idx];
        end;
      end;
    if (WS > 0.05) and (GS > 0.05) then
    begin
      ADelta := DS / GS;
      Result := True;
    end;
  end;

var
  I, J, K, M, V, W, GapK: Integer;
  GX, GZ, CX, CZ: Integer;
  Id: Int64;
  Seg: TTileRoadSeg;
  Msh: TMesh;
  D, BestD, HalfW, BestRef, Dh, WSum, DSum, Wt, NewY: Double;
  RefY, SegPX, SegPZ, AnyY, GSum: Double;
  SmDelta, SmBuf: array of Double;
  SmN: Integer;
  Applied: Boolean;
  DiagRB: Integer;
  DiagWX, DiagWZ: Double;
  DiagRS: string;
  WX, WZ: Double;
  P: TVector3;
  { Сетка сегментов для привязки целей (вместо перебора точки×сегменты):
    ячейка = макс. порог дистанции среди сегментов, сегмент лежит во
    всех ячейках своего bbox (слоты SgWay/SgSeg/SgNext + головы SgHead),
    точка сканирует 3×3 ячейки. SgCX0..SgCZ1 — диапазоны ячеек сегмента
    (по позиции в SegIdx), SgMark/SgTag — отсечка повторного осмотра
    одного сегмента из соседних слотов. }
  SgHead, SgNext, SgWay, SgSeg, SgMark: array of Integer;
  SgCX0, SgCX1, SgCZ0, SgCZ1: array of Integer;
  SgMinX, SgMinZ, SgInv, SgCell: Double;
  SgNB, SgSlots, SgTag: Integer;
  { Сетка целей для медианного сглаживания (ячейка = CORR_SMOOTH_M). }
  TgHead, TgNext, TgWay: array of Integer;
  TgMinX, TgMinZ, TgInv: Double;
  TgNB: Integer;
begin
  Result := 0;
  FLastPtsBox := 0; FLastNoCand := 0; FLastNoRef := 0; FLastVeto := 0;
  FLastWaysT := 0; FLastEdgeSegs := 0;
  FLastMovedWay := 0; FLastMovedGnd := 0;
  FDiagWallNear := 0; FDiagWallMoved := 0;
  FDiagWallMat := 0; FDiagWallNoCover := 0;
  FDiagWallPaveND := 0; FDiagWallDeck := 0;
  FDiagWallSample := '';
  if (not FActive) or (AModel = nil) then Exit;
  if AModel.RoadSegCount = 0 then Exit;

  { ── 1. Уникальные WayId: сбор → shell-sort → дедуп ── }
  SetLength(WayIds, AModel.RoadSegCount);
  NW := 0;
  BbMinX := 1e30; BbMaxX := -1e30;
  BbMinZ := 1e30; BbMaxZ := -1e30;
  for I := 0 to AModel.RoadSegCount - 1 do
  begin
    Seg := AModel.RoadSegs[I];
    if Seg.WayId = 0 then Continue;
    WayIds[NW] := Seg.WayId;
    Inc(NW);
    BbMinX := Min(BbMinX, ATileCenterX + Min(Seg.X0, Seg.X1));
    BbMaxX := Max(BbMaxX, ATileCenterX + Max(Seg.X0, Seg.X1));
    BbMinZ := Min(BbMinZ, ATileCenterZ + Min(Seg.Z0, Seg.Z1));
    BbMaxZ := Max(BbMaxZ, ATileCenterZ + Max(Seg.Z0, Seg.Z1));
  end;
  if NW = 0 then Exit;
  GapK := 1;
  while GapK < NW do GapK := GapK * 3 + 1;
  GapK := GapK div 3;
  while GapK >= 1 do
  begin
    for I := GapK to NW - 1 do
    begin
      Id := WayIds[I];
      J := I;
      while (J >= GapK) and (WayIds[J - GapK] > Id) do
      begin
        WayIds[J] := WayIds[J - GapK];
        Dec(J, GapK);
      end;
      WayIds[J] := Id;
    end;
    GapK := GapK div 3;
  end;
  J := 0;
  for I := 1 to NW - 1 do
    if WayIds[I] <> WayIds[J] then
    begin
      Inc(J);
      WayIds[J] := WayIds[I];
    end;
  NW := J + 1;
  SetLength(WayIds, NW);

  { ── 2. Сегменты по way: счёт → срезы → заполнение (без реаллоков) ── }
  SetLength(SegLo, NW + 1);
  SetLength(SegHi, NW);
  for K := 0 to NW do SegLo[K] := 0;
  for I := 0 to AModel.RoadSegCount - 1 do
  begin
    K := FindWay(AModel.RoadSegs[I].WayId);
    if K >= 0 then Inc(SegLo[K + 1]);
  end;
  for K := 1 to NW do Inc(SegLo[K], SegLo[K - 1]);
  SetLength(SegIdx, SegLo[NW]);
  for K := 0 to NW - 1 do SegHi[K] := SegLo[K];
  for I := 0 to AModel.RoadSegCount - 1 do
  begin
    K := FindWay(AModel.RoadSegs[I].WayId);
    if K < 0 then Continue;
    SegIdx[SegHi[K]] := I;
    Inc(SegHi[K]);
  end;

  { ── 3. Вершины: плоский разбор + группировка way-вершин срезами ── }
  NV := 0;
  for M := 0 to AModel.MeshCount - 1 do
    if AModel.Meshes[M].Mesh <> nil then
      Inc(NV, AModel.Meshes[M].Mesh.VertexCount);
  SetLength(VtxMesh, NV);
  SetLength(VtxV, NV);
  SetLength(VtxWayIdx, NV);
  SetLength(WVtxLo, NW + 1);
  for K := 0 to NW do WVtxLo[K] := 0;
  NV := 0;
  for M := 0 to AModel.MeshCount - 1 do
  begin
    Msh := AModel.Meshes[M].Mesh;
    if Msh = nil then Continue;
    for V := 0 to Msh.VertexCount - 1 do
    begin
      VtxMesh[NV] := M;
      VtxV[NV] := V;
      Id := Msh.Vertices[V].OsmId;
      if Id <> 0 then
        VtxWayIdx[NV] := FindWay(Id)
      else
        VtxWayIdx[NV] := -1;
      if VtxWayIdx[NV] >= 0 then
        Inc(WVtxLo[VtxWayIdx[NV] + 1]);
      Inc(NV);
    end;
  end;
  for K := 1 to NW do Inc(WVtxLo[K], WVtxLo[K - 1]);
  SetLength(WVtxIdx, WVtxLo[NW]);
  SetLength(WVtxHi, NW);
  for K := 0 to NW - 1 do WVtxHi[K] := WVtxLo[K];
  for I := 0 to NV - 1 do
    if VtxWayIdx[I] >= 0 then
    begin
      WVtxIdx[WVtxHi[VtxWayIdx[I]]] := I;
      Inc(WVtxHi[VtxWayIdx[I]]);
    end;

  { Пул опорных вершин: рельеф (GROUND_KINDS — включая полотно,
    запечённое в композит) + все вершины с OsmId (настилы). Границы и
    хэш ячейками 6 м. }
  SetLength(RefX, NV);
  SetLength(RefZ, NV);
  SetLength(RefYv, NV);
  NRef := 0;
  RefMinX := 1e30;
  RefMinZ := 1e30;
  Dh := -1e30;   { max X }
  NewY := -1e30; { max Z }
  for I := 0 to NV - 1 do
  begin
    Msh := AModel.Meshes[VtxMesh[I]].Mesh;
    P := Msh.Vertices[VtxV[I]].Position;
    if (VtxWayIdx[I] < 0) and
       (not (AModel.Meshes[VtxMesh[I]].Material in CORR_GROUND_KINDS)) then
      Continue;
    RefX[NRef] := ATileCenterX + P.X;
    RefZ[NRef] := ATileCenterZ + P.Z;
    RefYv[NRef] := P.Y;
    if RefX[NRef] < RefMinX then RefMinX := RefX[NRef];
    if RefX[NRef] > Dh then Dh := RefX[NRef];
    if RefZ[NRef] < RefMinZ then RefMinZ := RefZ[NRef];
    if RefZ[NRef] > NewY then NewY := RefZ[NRef];
    Inc(NRef);
  end;
  RefNB := 0;
  if NRef > 0 then
  begin
    RefInv := 1.0 / 6.0;
    RefNB := Trunc(Max(Dh - RefMinX, NewY - RefMinZ) * RefInv) + 2;
    SetLength(RefHead, RefNB * RefNB);
    for I := 0 to RefNB * RefNB - 1 do RefHead[I] := -1;
    SetLength(RefNext, NRef);
    for I := 0 to NRef - 1 do
    begin
      K := Trunc((RefX[I] - RefMinX) * RefInv);
      V := Trunc((RefZ[I] - RefMinZ) * RefInv);
      if K < 0 then K := 0; if K > RefNB - 1 then K := RefNB - 1;
      if V < 0 then V := 0; if V > RefNB - 1 then V := RefNB - 1;
      RefNext[I] := RefHead[V * RefNB + K];
      RefHead[V * RefNB + K] := I;
    end;
  end;

  { Пул вершин ПОЛОТНА (road-материалы) — сплошной коридор для среза в
    разрывах OSM. Границы + хэш 6 м. }
  SetLength(PaveX, NV);
  SetLength(PaveZ, NV);
  NPave := 0;
  PaveMinX := 1e30;
  PaveMinZ := 1e30;
  Dh := -1e30;
  NewY := -1e30;
  for I := 0 to NV - 1 do
  begin
    if not (AModel.Meshes[VtxMesh[I]].Material in CORR_ROAD_KINDS) then
      Continue;
    Msh := AModel.Meshes[VtxMesh[I]].Mesh;
    P := Msh.Vertices[VtxV[I]].Position;
    PaveX[NPave] := ATileCenterX + P.X;
    PaveZ[NPave] := ATileCenterZ + P.Z;
    if PaveX[NPave] < PaveMinX then PaveMinX := PaveX[NPave];
    if PaveX[NPave] > Dh then Dh := PaveX[NPave];
    if PaveZ[NPave] < PaveMinZ then PaveMinZ := PaveZ[NPave];
    if PaveZ[NPave] > NewY then NewY := PaveZ[NPave];
    Inc(NPave);
  end;
  PaveNB := 0;
  if NPave > 0 then
  begin
    PaveInv := 1.0 / 6.0;
    PaveNB := Trunc(Max(Dh - PaveMinX, NewY - PaveMinZ) * PaveInv) + 2;
    SetLength(PaveHead, PaveNB * PaveNB);
    for I := 0 to PaveNB * PaveNB - 1 do PaveHead[I] := -1;
    SetLength(PaveNext, NPave);
    for I := 0 to NPave - 1 do
    begin
      K := Trunc((PaveX[I] - PaveMinX) * PaveInv);
      V := Trunc((PaveZ[I] - PaveMinZ) * PaveInv);
      if K < 0 then K := 0; if K > PaveNB - 1 then K := PaveNB - 1;
      if V < 0 then V := 0; if V > PaveNB - 1 then V := PaveNB - 1;
      PaveNext[I] := PaveHead[V * PaveNB + K];
      PaveHead[V * PaveNB + K] := I;
    end;
  end;

  { ── 3.5. Сетка сегментов для привязки целей: прежний код мерил
    дистанцию от каждой точки профиля до КАЖДОГО сегмента
    (O(точки×сегменты) на тайл). Ячейка = макс. порог приёмки
    (HalfW = Width/2+2, мин 5) — тогда 3×3 ячейки вокруг точки
    гарантированно содержат все сегменты в её досягаемости; сама
    проверка дистанции и порог не меняются, набор кандидатов
    тождественен полному перебору. }
  SgCell := 5.0;
  for I := 0 to AModel.RoadSegCount - 1 do
  begin
    HalfW := AModel.RoadSegs[I].Width * 0.5 + 2.0;
    if HalfW > SgCell then SgCell := HalfW;
  end;
  SgInv := 1.0 / SgCell;
  SgMinX := BbMinX;
  SgMinZ := BbMinZ;
  SgNB := Trunc(Max(BbMaxX - BbMinX, BbMaxZ - BbMinZ) * SgInv) + 2;
  SetLength(SgHead, SgNB * SgNB);
  for I := 0 to SgNB * SgNB - 1 do SgHead[I] := -1;
  { диапазоны ячеек bbox каждого сегмента (bbox сегментов уже покрыт
    BbMin/BbMax, клампы — чистая страховка, как в хэше профиля) }
  SetLength(SgCX0, SegLo[NW]);
  SetLength(SgCX1, SegLo[NW]);
  SetLength(SgCZ0, SegLo[NW]);
  SetLength(SgCZ1, SegLo[NW]);
  SgSlots := 0;
  for K := 0 to NW - 1 do
    for J := SegLo[K] to SegHi[K] - 1 do
    begin
      Seg := AModel.RoadSegs[SegIdx[J]];
      SgCX0[J] := Trunc((ATileCenterX + Min(Seg.X0, Seg.X1) - SgMinX) * SgInv);
      SgCX1[J] := Trunc((ATileCenterX + Max(Seg.X0, Seg.X1) - SgMinX) * SgInv);
      SgCZ0[J] := Trunc((ATileCenterZ + Min(Seg.Z0, Seg.Z1) - SgMinZ) * SgInv);
      SgCZ1[J] := Trunc((ATileCenterZ + Max(Seg.Z0, Seg.Z1) - SgMinZ) * SgInv);
      if SgCX0[J] < 0 then SgCX0[J] := 0;
      if SgCX1[J] > SgNB - 1 then SgCX1[J] := SgNB - 1;
      if SgCZ0[J] < 0 then SgCZ0[J] := 0;
      if SgCZ1[J] > SgNB - 1 then SgCZ1[J] := SgNB - 1;
      Inc(SgSlots, (SgCX1[J] - SgCX0[J] + 1) * (SgCZ1[J] - SgCZ0[J] + 1));
    end;
  { слоты = сегмент × перекрытая ячейка; цепочки — как в хэше профиля }
  SetLength(SgWay, SgSlots);
  SetLength(SgSeg, SgSlots);
  SetLength(SgNext, SgSlots);
  SgSlots := 0;
  for K := 0 to NW - 1 do
    for J := SegLo[K] to SegHi[K] - 1 do
      for GZ := SgCZ0[J] to SgCZ1[J] do
        for GX := SgCX0[J] to SgCX1[J] do
        begin
          SgWay[SgSlots] := K;
          SgSeg[SgSlots] := SegIdx[J];
          SgNext[SgSlots] := SgHead[GZ * SgNB + GX];
          SgHead[GZ * SgNB + GX] := SgSlots;
          Inc(SgSlots);
        end;
  SetLength(SgMark, AModel.RoadSegCount);
  for I := 0 to AModel.RoadSegCount - 1 do SgMark[I] := 0;
  SgTag := 0;

  { ── 4. Привязка целей: счёт на way → срезы → заполнение ──
    Гориз.: КАНДИДАТЫ — все ways, чьи сегменты ближе полуширины+2
    (bbox-отсев раньше). Верт.: у каждого кандидата — опорная вершина
    СВОЕЙ way (срез WVtxIdx) в радиусе 7 м с минимальной |Y − alt_cal|;
    выбирается way с ближайшей ПО ВЕРТИКАЛИ опорой (точка «под мостом»
    не прилипнет к настилу), вето — лишь CORR_VERT_REJECT_M. }
  SetLength(TgtCnt, NW);
  SetLength(TgtLo, NW + 1);
  SetLength(TgtHi, NW);
  for K := 0 to NW - 1 do TgtCnt[K] := 0;

  { какому way принадлежит цель — считаем один раз, кэшируем }
  SetLength(CandD2, NW);
  SetLength(GndCnt, NW);
  for K := 0 to NW - 1 do GndCnt[K] := 0;
  { дельта/пригодность на каждую точку профиля (наземный срез в разрывах) }
  SetLength(PtDelta, Length(FPts));
  SetLength(PtPave, Length(FPts));
  for I := 0 to High(FPts) do PtPave[I] := False;
  for I := 0 to High(FPts) do
  begin
    if (FPts[I].X < BbMinX - 40) or (FPts[I].X > BbMaxX + 40) or
       (FPts[I].Z < BbMinZ - 40) or (FPts[I].Z > BbMaxZ + 40) then
    begin
      FPts[I].TmpWay := -1;
      Continue;
    end;
    Inc(FLastPtsBox);
    { Горизонтальные КАНДИДАТЫ: мин. дист² до сегментов каждой way в
      пределах её полуширины (+запас). Прежний код брал одну ближайшую
      по горизонтали и вето по вертикали 8 м резало привязку. Перебор —
      через сетку сегментов (3×3 ячейки, ячейка = макс. HalfW): CandD2 —
      тот же min по тем же проверкам, что при полном переборе; SgMark
      не даёт осмотреть один сегмент из двух соседних слотов. }
    for K := 0 to NW - 1 do CandD2[K] := 1e30;
    Inc(SgTag);
    CX := Trunc((FPts[I].X - SgMinX) * SgInv);
    CZ := Trunc((FPts[I].Z - SgMinZ) * SgInv);
    for GZ := CZ - 1 to CZ + 1 do
      for GX := CX - 1 to CX + 1 do
      begin
        if (GX < 0) or (GX > SgNB - 1) or
           (GZ < 0) or (GZ > SgNB - 1) then Continue;
        J := SgHead[GZ * SgNB + GX];
        while J >= 0 do
        begin
          if SgMark[SgSeg[J]] <> SgTag then
          begin
            SgMark[SgSeg[J]] := SgTag;
            Seg := AModel.RoadSegs[SgSeg[J]];
            HalfW := Seg.Width * 0.5 + 2.0;
            if HalfW < 5.0 then HalfW := 5.0;
            SegClosestSq(Seg, FPts[I].X, FPts[I].Z, D);
            if (D < HalfW * HalfW) and (D < CandD2[SgWay[J]]) then
              CandD2[SgWay[J]] := D;
          end;
          J := SgNext[J];
        end;
      end;
    { Выбор — ГИБРИДНЫЙ. По умолчанию берём ближайшую ПО ГОРИЗОНТАЛИ
      way (историческое поведение: трек лежит на своей дороге), а
      вертикаль (ближайшая |Y − alt_cal| опорная вершина в 7 м гориз.)
      решает только при явном расслоении поверхностей — когда другой
      кандидат вертикально ближе горизонтального лидера минимум на
      CORR_VERT_DECIDE_M (мост: под пролётом нижняя way выигрывает у
      настила). Чисто вертикальный выбор распылял цели между
      параллельными ways одного уровня по шуму высот; чисто
      горизонтальный с бинарным вето 8 м давал скачок «включения»
      коррекции там, где DEM разошёлся с FIT. Вето осталось лишь
      страховкой CORR_VERT_REJECT_M. }
    W := -1;
    BestD := 1e30;    { мин. горизонтальная дист² — лидер }
    RefY := 0;
    Dh := 1e30;       { верт. |Y − alt_cal| горизонтального лидера }
    BestRef := 1e30;  { лучший верт. среди всех кандидатов }
    M := -1;          { его way }
    NewY := 0;        { его RefY }
    for K := 0 to NW - 1 do
    begin
      if CandD2[K] >= 1e29 then Continue;
      { опорная вершина этой way }
      WSum := 1e30;   { верт. разность кандидата K }
      DSum := 0;      { RefY кандидата K }
      for J := WVtxLo[K] to WVtxHi[K] - 1 do
      begin
        V := WVtxIdx[J];
        Msh := AModel.Meshes[VtxMesh[V]].Mesh;
        P := Msh.Vertices[VtxV[V]].Position;
        D := Sqr(ATileCenterX + P.X - FPts[I].X) +
             Sqr(ATileCenterZ + P.Z - FPts[I].Z);
        if D > 49.0 then Continue;
        D := Abs(P.Y - FPts[I].AltCal);
        if D < WSum then
        begin
          WSum := D;
          DSum := P.Y;
        end;
      end;
      { Своих way-вершин нет (обычная дорога запечена в композит без
        OsmId) — опора с ЛЮБОЙ поверхности прямо под точкой. Для way,
        имеющей свои вершины (мостовой настил), фолбэк не применяется:
        расслоение мост/низ решается своими опорами. }
      if WSum >= 1e29 then
      begin
        if AnyRefY(FPts[I].X, FPts[I].Z, FPts[I].AltCal, AnyY) then
        begin
          WSum := Abs(AnyY - FPts[I].AltCal);
          DSum := AnyY;
        end;
      end;
      if WSum >= 1e29 then Continue;   { опоры нет вовсе — не кандидат }
      if CandD2[K] < BestD then
      begin
        BestD := CandD2[K];
        W := K;
        RefY := DSum;
        Dh := WSum;
      end;
      if WSum < BestRef then
      begin
        BestRef := WSum;
        M := K;
        NewY := DSum;
      end;
    end;
    { вертикальное расслоение — отдать мостовому кандидату }
    if (W >= 0) and (M >= 0) and (M <> W) and
       (Dh - BestRef >= CORR_VERT_DECIDE_M) then
    begin
      W := M;
      RefY := NewY;
      Dh := BestRef;
    end;
    if W < 0 then
    begin
      { различить: не было горизонтальных кандидатов вовсе — или были,
        но ни у одного вертикальной опоры в 7 м }
      DSum := 0;
      for K := 0 to NW - 1 do
        if CandD2[K] < 1e29 then DSum := 1;
      if DSum > 0 then Inc(FLastNoRef) else Inc(FLastNoCand);
    end
    else if Dh > CORR_VERT_REJECT_M then
    begin
      Inc(FLastVeto);
      W := -1;
    end;
    if W >= 0 then FPts[I].TmpRefY := RefY;
    FPts[I].TmpWay := W;
    { Дельта точки для наземного среза-в-разрыве (полотно есть, OSM-
      сегмента нет). Опора: привязанной точки — её RefY; без way —
      AnyRefY (любая поверхность под точкой). Кламп как у way-целей. }
    if W >= 0 then
    begin
      Dh := FPts[I].AltCal - RefY;
      if Dh > CORR_MAX_DELTA_M then Dh := CORR_MAX_DELTA_M;
      if Dh < -CORR_MAX_DELTA_M then Dh := -CORR_MAX_DELTA_M;
      PtDelta[I] := Dh;
      PtPave[I] := True;
    end
    else if AnyRefY(FPts[I].X, FPts[I].Z, FPts[I].AltCal, AnyY) then
    begin
      Dh := FPts[I].AltCal - AnyY;
      if Dh > CORR_MAX_DELTA_M then Dh := CORR_MAX_DELTA_M;
      if Dh < -CORR_MAX_DELTA_M then Dh := -CORR_MAX_DELTA_M;
      PtDelta[I] := Dh;
      PtPave[I] := True;
    end
    else
      PtPave[I] := False;
    if W >= 0 then
    begin
      Inc(TgtCnt[W]);
      { Наземно-эффективная цель: не-настил ЛИБО у way нет вершин
        настила (OsmId) в этом тайле — тогда «настил» из классификации
        по высоте ложный (DEM-бугор, не мост), и точка правит землю.
        Настоящий мост несёт вершины настила → его deck землю не трогает.
        Без этого ложный deck-интервал на обычной дороге вырезал дыру в
        наземном поле → пандус-ступень на кромке дыры. }
      if (not FPts[I].BridgeDeck) or (WVtxLo[W] >= WVtxHi[W]) then
        Inc(GndCnt[W]);
      { невязка уровня датум-меш: копится до лока. Точки прогрева
        (Conf < 0.5) не участвуют — некалиброванный старт не должен
        задавать общий ноль. }
      if (not FLevelLocked) and (FPts[I].Conf >= 0.5) then
      begin
        if FLvlN = Length(FLvlBuf) then
          SetLength(FLvlBuf, Max(256, FLvlN * 2));
        FLvlBuf[FLvlN] := FPts[I].AltCal - FPts[I].TmpRefY;
        Inc(FLvlN);
      end;
    end;
  end;

  FLastBound := 0;
  for K := 0 to NW - 1 do
  begin
    Inc(FLastBound, TgtCnt[K]);
    if TgtCnt[K] > 0 then Inc(FLastWaysT);
  end;
  if not FLevelLocked then
  begin
    { уровень ещё не залочен: невязки собраны, вершины не трогаем -
      иначе тайлы разных батчей получили бы разные нули }
    FLastMoved := 0;
    Exit;
  end;

  TgtLo[0] := 0;
  for K := 0 to NW - 1 do TgtLo[K + 1] := TgtLo[K] + TgtCnt[K];
  NT := TgtLo[NW];
  SetLength(Targets, NT);
  SetLength(TgWay, NT);
  for K := 0 to NW - 1 do TgtHi[K] := TgtLo[K];
  for I := 0 to High(FPts) do
  begin
    W := FPts[I].TmpWay;
    if W < 0 then Continue;
    Dh := FPts[I].AltCal - FPts[I].TmpRefY;
    if Dh > CORR_MAX_DELTA_M then Dh := CORR_MAX_DELTA_M;
    if Dh < -CORR_MAX_DELTA_M then Dh := -CORR_MAX_DELTA_M;
    Targets[TgtHi[W]].X := FPts[I].X;
    Targets[TgtHi[W]].Z := FPts[I].Z;
    Targets[TgtHi[W]].Delta := Dh;
    { эффективный deck: только если way реально несёт настил (OsmId) }
    Targets[TgtHi[W]].Deck :=
      FPts[I].BridgeDeck and (WVtxLo[W] < WVtxHi[W]);
    Targets[TgtHi[W]].Conf := FPts[I].Conf;
    TgWay[TgtHi[W]] := W;
    Inc(TgtHi[W]);
  end;

  { Сглаживание дельт целей: у каждой цели Delta = alt_cal − refY, где
    refY — ближайшая вершина поверхности (квантование по вершинам даёт
    шум ±0.5..1 м). Незаглаженный шум разъезжается по мешу мелкой
    шершавостью и раздувает «набор» (интеграл |приращений|), а редкие
    выбросы (сложный refY у кромок) рождают продольные ступеньки.
    Заменяем Delta каждой цели МЕДИАНОЙ дельт целей той же way в
    окне ALONG_SMOOTH_M (робастно к выбросам; настоящий уклон
    сохраняется — окно короткое). Работает на массиве целей, меш не
    трогает — кромки/бордюры остаются резкими. }
  if NT > 0 then
  begin
    { Сетка целей (ячейка = CORR_SMOOTH_M): прежний код для каждой цели
      перебирал ВСЕ цели своей way — O(Σ T²). 3×3 ячейки вокруг цели
      покрывают круг радиуса сглаживания; фильтр по way и три проверки
      дистанции прежние — набор соседей в окне тождественен полному
      перебору (порядок сбора не важен: перед медианой сортировка). }
    TgMinX := Targets[0].X;
    Dh := Targets[0].X;     { max X }
    TgMinZ := Targets[0].Z;
    NewY := Targets[0].Z;   { max Z }
    for K := 1 to NT - 1 do
    begin
      if Targets[K].X < TgMinX then TgMinX := Targets[K].X;
      if Targets[K].X > Dh then Dh := Targets[K].X;
      if Targets[K].Z < TgMinZ then TgMinZ := Targets[K].Z;
      if Targets[K].Z > NewY then NewY := Targets[K].Z;
    end;
    TgInv := 1.0 / CORR_SMOOTH_M;
    TgNB := Trunc(Max(Dh - TgMinX, NewY - TgMinZ) * TgInv) + 2;
    SetLength(TgHead, TgNB * TgNB);
    for K := 0 to TgNB * TgNB - 1 do TgHead[K] := -1;
    SetLength(TgNext, NT);
    for K := 0 to NT - 1 do
    begin
      GX := Trunc((Targets[K].X - TgMinX) * TgInv);
      GZ := Trunc((Targets[K].Z - TgMinZ) * TgInv);
      if GX < 0 then GX := 0; if GX > TgNB - 1 then GX := TgNB - 1;
      if GZ < 0 then GZ := 0; if GZ > TgNB - 1 then GZ := TgNB - 1;
      TgNext[K] := TgHead[GZ * TgNB + GX];
      TgHead[GZ * TgNB + GX] := K;
    end;
    SetLength(SmDelta, NT);
    for W := 0 to NW - 1 do
      for K := TgtLo[W] to TgtHi[W] - 1 do
      begin
        SmN := 0;
        CX := Trunc((Targets[K].X - TgMinX) * TgInv);
        CZ := Trunc((Targets[K].Z - TgMinZ) * TgInv);
        for GZ := CZ - 1 to CZ + 1 do
          for GX := CX - 1 to CX + 1 do
          begin
            if (GX < 0) or (GX > TgNB - 1) or
               (GZ < 0) or (GZ > TgNB - 1) then Continue;
            J := TgHead[GZ * TgNB + GX];
            while J >= 0 do
            begin
              if TgWay[J] = W then
              begin
                Dh := Targets[K].X - Targets[J].X;
                if (Dh < CORR_SMOOTH_M) and (Dh > -CORR_SMOOTH_M) then
                begin
                  D := Targets[K].Z - Targets[J].Z;
                  if (D < CORR_SMOOTH_M) and (D > -CORR_SMOOTH_M) and
                     (Dh * Dh + D * D < CORR_SMOOTH_M * CORR_SMOOTH_M) then
                  begin
                    if SmN = Length(SmBuf) then
                      SetLength(SmBuf, Max(16, SmN * 2));
                    SmBuf[SmN] := Targets[J].Delta;
                    Inc(SmN);
                  end;
                end;
              end;
              J := TgNext[J];
            end;
          end;
        if SmN = 0 then
        begin
          SmDelta[K] := Targets[K].Delta;
          Continue;
        end;
        { медиана SmBuf[0..SmN-1] — вставками (окно мало) }
        for M := 1 to SmN - 1 do
        begin
          D := SmBuf[M];
          J := M - 1;
          while (J >= 0) and (SmBuf[J] > D) do
          begin
            SmBuf[J + 1] := SmBuf[J];
            Dec(J);
          end;
          SmBuf[J + 1] := D;
        end;
        SmDelta[K] := SmBuf[SmN div 2];
      end;
    for K := 0 to NT - 1 do Targets[K].Delta := SmDelta[K];
  end;

  { Кромочное поле рельефа: плоский список сегментов ways, имеющих
    НАЗЕМНЫЕ цели. Ближайший сегмент задаёт КРОМКУ ПОЛОТНА (полуширина
    сегмента + обочина) — от неё рельеф едет way-дельтой с весом 1 на
    полотне и косинусным спадом за кромкой. Прежнее точечное поле
    вокруг GPS-трека не знало ширину дороги: трек жмётся к правой
    полосе, дальняя кромка выпадала из коридора — лента ныряла на
    полный вес, рельеф у кромки на частичный, шов загибался. }
  SetLength(EsX0, SegLo[NW]);
  SetLength(EsZ0, SegLo[NW]);
  SetLength(EsX1, SegLo[NW]);
  SetLength(EsZ1, SegLo[NW]);
  SetLength(EsHalf, SegLo[NW]);
  SetLength(EsWay, SegLo[NW]);
  NE := 0;
  EdgeGate := 0;
  for K := 0 to NW - 1 do
  begin
    if GndCnt[K] = 0 then Continue;
    for J := SegLo[K] to SegHi[K] - 1 do
    begin
      Seg := AModel.RoadSegs[SegIdx[J]];
      EsX0[NE] := ATileCenterX + Seg.X0;
      EsZ0[NE] := ATileCenterZ + Seg.Z0;
      EsX1[NE] := ATileCenterX + Seg.X1;
      EsZ1[NE] := ATileCenterZ + Seg.Z1;
      HalfW := Seg.Width * 0.5;
      if HalfW < 2.0 then HalfW := 2.0;
      EsHalf[NE] := HalfW + CORR_EDGE_MARGIN_M;
      if EsHalf[NE] > EdgeGate then EdgeGate := EsHalf[NE];
      EsWay[NE] := K;
      Inc(NE);
    end;
  end;
  { гейт по треку: кромка + феатер + запас на отступ трека от оси }
  EdgeGate := EdgeGate + CORR_FEATHER_M + CORR_HALF_WIDTH_M + 2.0;
  FLastEdgeSegs := NE;

  { ── 5. Применение ── }
  for I := 0 to NV - 1 do
  begin
    Msh := AModel.Meshes[VtxMesh[I]].Mesh;
    V := VtxV[I];
    P := Msh.Vertices[V].Position;
    W := VtxWayIdx[I];
    DiagRB := Result;                     { сдвиги ДО этой вершины }
    DiagWX := ATileCenterX + P.X;         { гориз. позиция (для детектора) }
    DiagWZ := ATileCenterZ + P.Z;
    if (W >= 0) and (TgtHi[W] > TgtLo[W]) then
    begin
      { жёсткий профиль вдоль way: сечение (настил+перила) едет целиком.
        Взносы — с доверием (Conf, прогрев старта), знаменатель GSum —
        чистая геометрия: дельта = DSum/GSum. При полном доверии это
        обычное среднее; в прогревной зоне амплитуда давится долей
        доверия окна (среднее с Conf-весами НЕ гаснет, если все соседи
        прогревные и врут одинаково); на кольце финишные точки с полным
        весом корректируют место старта. }
      WSum := 0;
      GSum := 0;
      DSum := 0;
      WX := ATileCenterX + P.X;
      WZ := ATileCenterZ + P.Z;
      for K := TgtLo[W] to TgtHi[W] - 1 do
      begin
        Dh := WX - Targets[K].X;
        if (Dh >= CORR_ALONG_M) or (Dh <= -CORR_ALONG_M) then Continue;
        D := WZ - Targets[K].Z;
        if (D >= CORR_ALONG_M) or (D <= -CORR_ALONG_M) then Continue;
        D := Dh * Dh + D * D;
        if D >= CORR_ALONG_M * CORR_ALONG_M then Continue;
        D := Sqrt(D);
        Wt := 1.0 - D / CORR_ALONG_M;
        GSum := GSum + Wt;
        Wt := Wt * Targets[K].Conf;
        WSum := WSum + Wt;
        DSum := DSum + Wt * Targets[K].Delta;
      end;
      if (WSum > 0.05) and (GSum > 0.05) then
      begin
        P.Y := P.Y + DSum / GSum;
        Msh.SetVertexPosition(V, P);
        Inc(Result);
        Inc(FLastMovedWay);
      end;
      { счётчик для лога ведёт Result; FLastMoved присвоим в конце }
    end
    else if (AModel.Meshes[VtxMesh[I]].Material in CORR_ROAD_KINDS)
            and PaveTargetY(DiagWX, DiagWZ, AnyY) then
    begin
      { ЖЁСТКОЕ приведение ПОЛОТНА к голубым точкам: вершина полотна
        ставится ТОЧНО на интерполированную голубую высоту (не сдвигается
        дельтой). Дорога ложится ровно на голубую кривую — гладкая, без
        остаточной ВЧ-вариации рельефа. Настил (OsmId) сюда не попадает —
        он ушёл в way-профиль выше. Если рядом НЕТ не-настильных точек
        трека (PaveTargetY=False, напр. в зоне ложного «настила») — вершина
        НЕ остаётся на OSM-высоте, а проваливается в рельефную ветку ниже
        и едет на скорректированной земле. }
      P.Y := AnyY;
      Msh.SetVertexPosition(V, P);
      Inc(Result);
      Inc(FLastMovedWay);
    end
    else if (NE > 0) and
            ((AModel.Meshes[VtxMesh[I]].Material in CORR_GROUND_KINDS)
             or (AModel.Meshes[VtxMesh[I]].Material in CORR_ROAD_KINDS)) then
    begin
      { Рельеф — кромочное поле: полотно+обочина едут с лентой на
        полный вес, дальше косинусный спад ОТ КРОМКИ. Дельта — та же
        продольная интерполяция, что у way-вершин, но ТОЛЬКО по
        наземным целям (настильные пропускаются: земля под мостом не
        должна ехать с настилом). }
      WX := ATileCenterX + P.X;
      WZ := ATileCenterZ + P.Z;
      if not NearTrack(WX, WZ, EdgeGate) then Continue;
      { ближайший сегмент наземных ways — кромка }
      BestD := 1e30;
      W := -1;
      HalfW := 0;
      for K := 0 to NE - 1 do
      begin
        SegPX := EsX1[K] - EsX0[K];
        SegPZ := EsZ1[K] - EsZ0[K];
        NewY := SegPX * SegPX + SegPZ * SegPZ;
        if NewY < 1e-9 then
          Wt := 0
        else
        begin
          Wt := ((WX - EsX0[K]) * SegPX + (WZ - EsZ0[K]) * SegPZ) / NewY;
          if Wt < 0 then Wt := 0 else if Wt > 1 then Wt := 1;
        end;
        D := Sqr(WX - (EsX0[K] + SegPX * Wt)) +
             Sqr(WZ - (EsZ0[K] + SegPZ * Wt));
        if D < BestD then
        begin
          BestD := D;
          W := EsWay[K];
          HalfW := EsHalf[K];
        end;
      end;
      Applied := False;
      if W >= 0 then
      begin
        D := Sqrt(BestD) - HalfW;       { дистанция ЗА кромку полотна }
        if D < CORR_FEATHER_M then
        begin
          if D <= 0 then
            Wt := 1.0
          else
            Wt := 0.5 * (1.0 + Cos(Pi * D / CORR_FEATHER_M));
          WSum := 0;
          GSum := 0;
          DSum := 0;
          for K := TgtLo[W] to TgtHi[W] - 1 do
          begin
            if Targets[K].Deck then Continue;
            Dh := WX - Targets[K].X;
            if (Dh >= CORR_ALONG_M) or (Dh <= -CORR_ALONG_M) then Continue;
            D := WZ - Targets[K].Z;
            if (D >= CORR_ALONG_M) or (D <= -CORR_ALONG_M) then Continue;
            D := Dh * Dh + D * D;
            if D >= CORR_ALONG_M * CORR_ALONG_M then Continue;
            D := Sqrt(D);
            NewY := 1.0 - D / CORR_ALONG_M;
            GSum := GSum + NewY;
            NewY := NewY * Targets[K].Conf;
            WSum := WSum + NewY;
            DSum := DSum + NewY * Targets[K].Delta;
          end;
          if (WSum > 0.05) and (GSum > 0.05) then
          begin
            { DSum/GSum: дельта с прогревным затуханием (см. way-ветку) }
            P.Y := P.Y + (DSum / GSum) * Wt;
            Msh.SetVertexPosition(V, P);
            Inc(Result);
            Inc(FLastMovedGnd);
            Applied := True;
          end;
        end;
      end;
      { РАЗРЫВ OSM: ближайшего сегмента RoadSeg нет/за феатером. Режем
        рельеф вдоль НЕПРЕРЫВНОГО трека: полная сила в пределах ширины
        дороги (CORR_PAVE_M) от трека, косинусный спад до 0 на +феатер.
        Плавно, без обрыва — «стены» на потере снапа/разрывах way уходят.
        Дельта — по наземным трекам вокруг (PaveDelta). }
      if not Applied then
      begin
        D := TrackDist(WX, WZ, CORR_PAVE_M + CORR_FEATHER_M);
        if D < CORR_PAVE_M + CORR_FEATHER_M then
        begin
          if D <= CORR_PAVE_M then
            Wt := 1.0
          else
            Wt := 0.5 * (1.0 + Cos(Pi * (D - CORR_PAVE_M) / CORR_FEATHER_M));
          if PaveDelta(WX, WZ, Dh) then
          begin
            P.Y := P.Y + Dh * Wt;
            Msh.SetVertexPosition(V, P);
            Inc(Result);
            Inc(FLastMovedGnd);
            Applied := True;
          end;
        end;
      end;
    end;

    { ── ДЕТЕКТОР «нужна коррекция, но не сделана» ──
      Вершина у трека (в EdgeGate), но Result не вырос → не сдвинута.
      Причина: material — не рельеф/полотно (в цикл не входит);
      deck — настил без целей; noCover — рельеф/полотно, но нет ни
      сегмента, ни полотна рядом; paveND — полотно рядом, но нет
      наземных треков в окне (PaveDelta пуст). Сэмпл первых 8. }
    if (Result = DiagRB) and NearTrack(DiagWX, DiagWZ, EdgeGate) then
    begin
      Inc(FDiagWallNear);
      if VtxWayIdx[I] >= 0 then
        Inc(FDiagWallDeck)
      else if not ((AModel.Meshes[VtxMesh[I]].Material in CORR_GROUND_KINDS)
                or (AModel.Meshes[VtxMesh[I]].Material in CORR_ROAD_KINDS)) then
        Inc(FDiagWallMat)
      else if TrackDist(DiagWX, DiagWZ, CORR_PAVE_M + CORR_FEATHER_M)
              < CORR_PAVE_M + CORR_FEATHER_M then
        Inc(FDiagWallPaveND)          { в досягаемости феатера, но не сдвинут }
      else
        Inc(FDiagWallNoCover);        { дальше феатера — спад к 0, легитимно }
      if FDiagWallNear <= 8 then
      begin
        if VtxWayIdx[I] >= 0 then
        begin M := -2; DiagRS := 'deck'; end
        else if not ((AModel.Meshes[VtxMesh[I]].Material in CORR_GROUND_KINDS)
                  or (AModel.Meshes[VtxMesh[I]].Material in CORR_ROAD_KINDS)) then
        begin M := Ord(AModel.Meshes[VtxMesh[I]].Material); DiagRS := 'mat'; end
        else
        begin
          M := Ord(AModel.Meshes[VtxMesh[I]].Material);
          if TrackDist(DiagWX, DiagWZ, CORR_PAVE_M + CORR_FEATHER_M)
             < CORR_PAVE_M + CORR_FEATHER_M then DiagRS := 'deltaFail'
          else DiagRS := 'trackFar';
        end;
        FDiagWallSample := FDiagWallSample +
          Format('[%.0f,%.0f,%.1f mat=%d %s] ',
            [DiagWX, DiagWZ, P.Y, M, DiagRS]);
      end;
    end
    else if Result > DiagRB then
      Inc(FDiagWallMoved);
  end;
  FLastMoved := Result;
end;

function TFitCorrection.TryLockLevel(AMinResiduals: Integer;
  out OutOffset: Double): Boolean;
begin
  OutOffset := 0;
  Result := FLevelLocked;
  if FLevelLocked then
  begin
    OutOffset := FLevelOffset;
    Exit;
  end;
  if FLvlN < AMinResiduals then Exit(False);
  { Цель профиля (DriftCorr) — АБСОЛЮТНАЯ: сплайн дрейфа привязал её к
    рельефу (медиана fit−Dem снята), земля режется ПРЯМО на неё —
    delta = DriftCorr − поверхность. Общий офсет НЕ вычитается: раньше
    (для DEM-относительного датумного профиля) лок сажал цель на уровень
    меша медианой невязок, но при абсолютной цели это лишь топит весь
    профиль — настилы (65% точек, DriftCorr−Dem>5) задирали медиану
    невязок до ~7 м, и земля уходила в трэнч даже там, где голубой≈
    красный. Лок оставлен ГЕЙТОМ (правим только после привязки к реальной
    геометрии — FLvlN невязок собрано), но сдвиг = 0. }
  FLevelOffset := 0;
  FLevelLocked := True;
  OutOffset := 0;
  Result := True;
end;

end.
