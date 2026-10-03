unit Osm3dFitHeightLayer;

{ overflow/range-проверки выключены намеренно (как в остальных geom/height-юнитах) }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$codepage UTF8}

{ ═══ Второй слой высот фетчера: коррекция по нивелированному FIT ═══════

  Класс-СЛОЙ (без зависимости от Osm3dHeightmap, чтобы TTerrariumFetcher мог
  держать его полем без цикла модулей). Держит в RAM корректированные высоты
  всех заездов папки и отдаёт по гео-точке высоту, СМЕШАННУЮ с DEM.

  ── ДВА УРОВНЯ (мосты / развязки) ──────────────────────────────────────
  В одной плановой точке (X,Z) FIT может быть на ДВУХ высотах: один заезд
  прошёл ПОД мостом, другой ПО нему; либо один и тот же заезд на развязке
  прошёл и низом, и верхом. Поэтому запрос НЕ усредняет всё подряд (среднее
  «низ+верх» — высота, которой нет), а КЛАСТЕРИЗУЕТ попавшие в коридор точки
  по высоте: ищем крупнейший разрыв; разрыв > FITL_LEVEL_SPLIT_M делит на
  НИЖНИЙ и ВЕРХНИЙ уровень. Кластеризация по высоте, не по заезду.

    • ЗЕМЛЯ (террейн) берёт НИЖНИЙ уровень:
        - обычная дорога — один кластер, как раньше;
        - развязка — нижняя дорога, а не среднее;
        - насыпь (набережная/дамба) — нижний кластер высокий → земля
          поднимается: насыпь сохраняется.
      Под ПРОЛЁТОМ моста (ABridgeMask=True): если есть отдельный нижний
      уровень (реальная низовая дорога) — берём его; иначе (единственный
      уровень = настил) — ЧИСТЫЙ DEM (воздух под мостом, насыпи-двойника нет).
    • НАСТИЛ моста берёт ВЕРХНИЙ уровень (DeckTarget) — строит Osm3dGeomBridges.

  На полотне (вес≈1) высота ТОЧНО из FIT, без DEM; за кромкой — косинусный
  феатер FIT→DEM; дальше — чистый DEM. DEM может быть и выше, и ниже FIT
  (выемка → земля опускается к FIT). Перекрытия одного уровня сводятся
  ВЗВЕШЕННОЙ МЕДИАНОЙ (интерполированной): устойчива к файлу-выбросу с
  уехавшим уровнем, который среднее утягивало бы за собой.
  Точки индексируются по КВАДАМ — разреженный хэш ячеек FITL_CELL_M.

  Наполняется извне: Osm3dFitLayerBuild.BuildFitHeightLayer грузит папку
  (CSV-кэш / пофайловый датум) и зовёт SetData. }

interface

uses
  SysUtils,            { FreeAndNil }
  Math,
  Generics.Collections,
  CastleVectors,       { TVector3 }
  Osm3dGeoMath;        { TLatLon, TLocalProjection }

const
  { Полуширина коридора коррекции (полотно+обочина), м. }
  FITL_HALF_WIDTH_M  = 8.0;
  { Поперечная растушёвка за коридором, м. }
  FITL_FEATHER_M     = 18.0;
  { Ячейка мирового квад-хэша, м. ДОЛЖНА быть >= HALF+FEATHER: запрос
    сканирует 3×3 ячейки, worst-case охват = размер ячейки. }
  FITL_CELL_M        = 25.0;
  { Предохранитель: макс |сдвиг| высоты узла от DEM в зоне феатера, м
    (защита от битого DEM-пикселя; на полотне не применяется — там чистый FIT). }
  FITL_MAX_DELTA_M   = 30.0;
  { Классификация «настил моста» при сборке CSV-кэша: превышение приведённой
    высоты над DEM, м (Osm3dFitLayerBuild). В самом слое не используется —
    уровни решаются кластеризацией на запросе. }
  FITL_BRIDGE_RISE_M = 5.0;
  { Разрыв высот между соседними точками коридора, выше которого они —
    РАЗНЫЕ уровни (нижний/верхний): мост/развязка. Ниже — один уровень. }
  FITL_LEVEL_SPLIT_M = 3.5;
  { Габарит под пролётом моста, м: под маской пролёта земля = DEM, но НЕ выше
    (настил − этот габарит). Грубый DEM (~19 м/px) не разрешает выемку, в
    которой идёт нижняя дорога/ж-д — холм сырого DEM вылезал ВЫШЕ полотна и
    глотал торцы настила. Если DEM выше — выемка докапывается до габарита. }
  FITL_UNDERPASS_CLEAR_M = 5.0;
  { Максимум точек-кандидатов на один запрос (стек-буфер без аллокаций в
    горячем цикле узлов террейна). Сверх — молча отсекается (для среднего
    неважно). }
  FITL_MAX_CAND      = 256;
  { Порог веса для ЖЁСТКОЙ цели полотна (RoadTarget*): узел дороги обязан
    лежать НА полотне заезда (косинус-вес ≥ этого = внутри
    FITL_HALF_WIDTH_M), а не в поперечном феатере. Феатер существует для
    мягкого схода ТЕРРЕЙНА к DEM; дороге он противопоказан: прежний код
    отдавал жёсткую цель на всей ширине HALF+FEATHER = 26 м, и параллельные
    дороги/дорожки в 10–25 м сбоку (дублёр под насыпью, тротуар у моста),
    по которым НЕ ездили, целиком поднимались на высоту полотна заезда. }
  FITL_ROAD_SNAP_W   = 0.999;

type
  { Точка приведённого профиля в МИРОВЫХ метрах проекции слоя. }
  TFitLayerPoint = record
    X, Z:   Double;   { мир (метры) в проекции слоя }
    AltCal: Double;   { приведённая абсолютная высота, м }
    Deck:   Boolean;  { пометка настила из CSV-кэша; в запросе не используется }
  end;
  TFitLayerPointArray = array of TFitLayerPoint;

  { Уровень запроса высоты. }
  TFitHeightLevel = (fhlGround, fhlDeck);

  { Разбор запроса уровней в точке — для ГЕН-ЛОГА дефектов. Показывает, из
    чего сложилась высота дороги: сколько кандидатов коридора, их разброс,
    крупнейший разрыв высот и был ли раскол на нижний/верхний уровень (мост/
    развязка/наложение заездов). Именно раскол и его «переброс» между соседними
    точками рождает пики полотна. }
  TFitLevelsDiag = record
    { Максимум веса среди НЕ-настильных точек НИЖНЕГО кластера. Это критерий
      «здесь реально ехали по земле, а не прошли поверху/рядом»: гейт
      прикалывания дорог в Osm3dGeomBuilder (LoGndW >= FITL_ROAD_SNAP_W) —
      тот же, что в RoadTargetXZ. Без него узел ЧУЖОЙ дороги в 25.9 м от
      трека (вес 0.0006!) прикалывался к его уровню, а битый датум одного
      заезда поднимал целые кварталы (замер: 628 узлов выше DEM на 10+ м,
      89% из них — один файл). }
    LoGndW:  Double;
    NC:      Integer;                  { кандидатов в коридоре (после отсечения по радиусу) }
    MinAlt:  Double;                   { мин высота кандидатов }
    MaxAlt:  Double;                   { макс высота кандидатов }
    BestGap: Double;                   { крупнейший разрыв высот между соседними кандидатами }
    SplitAt: Integer;                  { индекс начала ВЕРХНЕГО кластера; -1 — один уровень }
    AltN:    Integer;                  { сколько высот скопировано в Alt (<=16) }
    Alt:     array[0 .. 15] of Double; { отсортированные высоты кандидатов (первые 16) }
  end;
  PFitLevelsDiag = ^TFitLevelsDiag;

  { ── Слой корректированных высот. Потокобезопасен только на ЧТЕНИЕ
    (после SetData): запросы не пишут в поля. Строится на одном потоке. ── }
  TFitHeightLayer = class
  private
    FPts:   TFitLayerPointArray;
    FProj:  TLocalProjection;                        { гео → мир слоя }
    FCells: specialize TDictionary<Int64, Integer>;  { квад-ячейка → голова }
    FNext:  array of Integer;                        { связные списки точек }
    FInv:   Double;                                  { 1 / FITL_CELL_M }
    FActive: Boolean;
    FSig:   string;                                  { сигнатура набора }
    FDatumTime, FDatumCorrection: array of Double;
    FDatumSource: string;
    procedure BuildIndex;
    class function CellKey(ACx, ACz: Integer): Int64; static; inline;
    { Собрать целевые высоты FIT в (X,Z), РАЗДЕЛИВ по высоте на нижний и
      верхний уровни (кластеризация по разрыву FITL_LEVEL_SPLIT_M). Веса —
      косинус-феатер (1 в коридоре → 0 на кромке); *Y — взвешенное среднее
      уровня, *W — максимум веса уровня. AHasHi=False → уровень один. }
    { ALoGndW — максимум веса среди НЕ-настильных (Deck=False) кандидатов
      НИЖНЕГО кластера; 0, если нижний кластер целиком из точек настила.
      Нужен RoadTarget* и GroundHeight*: «по земле здесь реально ехали»
      отличается от «над этим местом проехали по мосту».
      ADkY/ADkW — уровень НАСТИЛА: взвешенная медиана ВСЕХ настильных
      кандидатов (без кластеризации) и их макс вес; ADkW=0 — настильных нет.
      Медиана по всем декам, а не «верхний кластер»: у моста 19 верхним
      кластером оказывались 8-11 точек прогревной зоны одного заезда
      (cal 184..188) против 73-83 честных настильных точек двенадцати
      заездов (173..179) — и настил уезжал на третий уровень. Медиана
      давит выброс числом на обоих концах пролёта одинаково. }
    procedure LevelsXZ(X, Z: Double;
      out ALoY, AHiY, ALoW, AHiW, ALoGndW, ADkY, ADkW: Double;
      out AHasLo, AHasHi: Boolean; ADiag: PFitLevelsDiag = nil);
    { Смешать цель ATarget (вес AWeight) с DEM: полотно (вес≥0.999) — ТОЧНО
      цель; феатер — косинус-микс с клампом дельты; иначе — ADem. }
    class function BlendGround(ATarget, AWeight, ADem: Double): Double; static;
  public
    constructor Create;
    destructor Destroy; override;

    { Установить данные: точки APts уже в мире проекции AOrigin (вызывающий
      проецировал тем же origin). Слой создаёт свою идентичную проекцию для
      запросов. <2 точек — деактивирует. ASig — сигнатура набора. }
    procedure SetData(const APts: TFitLayerPointArray;
      const AOrigin: TLatLon; const ASig: string);
    procedure Clear;

    { The selected ride's EXISTING barometer calibration, before spatial
      corridor blending. Load profiles sample it once during preparation;
      route crossings and nearby bridge levels must never choose its source. }
    procedure SetSelectedDatum(const Source: string;
      const TimeSec, RawAlt, CalAlt: array of Double);
    function CorrectSelectedAltitude(TimeSec, RawAlt: Double;
      out CalAlt: Double): Boolean;
    function HasSelectedDatum: Boolean;
    property SelectedDatumSource: string read FDatumSource;

    property Active: Boolean read FActive;
    { Сигнатура набора заездов (в gen-hash: смена .fit → смена сигнатуры →
      регенерация корректированных тайлов). }
    property Signature: string read FSig;

    { Готовая высота узла ЗЕМЛИ по ГЕО-точке: НИЖНИЙ уровень FIT, смешанный
      с DEM. ABridgeMask=True → узел под пролётом моста: одиночный (верхний)
      уровень игнорируется → чистый DEM; двойной — нижний (низовая дорога). }
    function GroundHeightGeo(const P: TLatLon; ADem: Double;
      ABridgeMask: Boolean): Double;
    { Совместимость: земля без маски моста (= GroundHeightGeo(P,ADem,False)). }
    function CorrectHeightGeo(const P: TLatLon; ADem: Double): Double;
    { Чистая цель НИЖНЕГО уровня (без DEM) — для ПОПЕРЕЧНОГО выравнивания
      дорог: обе кромки полотна ставятся на FIT, полотно ложится ровно.
      True + AY ТОЛЬКО если узел лежит НА полотне заезда (вес ≥
      FITL_ROAD_SNAP_W, т.е. внутри FITL_HALF_WIDTH_M) И в нижнем кластере
      есть не-настильные точки (по земле здесь реально ехали).
      Иначе False — дорога ложится на террейн/сетку (у террейна свой
      мягкий бленд с феатером и защита пролётов). Это чинит подъём чужих
      дорог: параллельных (феатер) и проходящих ПОД заездом (настил). }
    function RoadTargetGeo(const P: TLatLon; out AY: Double): Boolean;
    { ВЕРХНИЙ уровень (настил моста) по ГЕО-точке: максимальный FIT-уровень в
      точке (верхний кластер, иначе единственный). True, если FIT есть. }
    function DeckTargetGeo(const P: TLatLon; out AY: Double): Boolean;

    { Низкоуровневые варианты по мировым XZ проекции слоя. }
    function GroundHeightXZ(X, Z, ADem: Double; ABridgeMask: Boolean): Double;
    function CorrectHeightXZ(X, Z, ADem: Double): Double;
    function RoadTargetXZ(X, Z: Double; out AY: Double): Boolean;
    function DeckTargetXZ(X, Z: Double; out AY: Double): Boolean;

    { Диагностика запроса уровней (для ген-лога): все уровни + разбор кластеров
      ADiag. True, если FIT есть в точке. Ничего не меняет в состоянии слоя. }
    function DiagXZ(X, Z: Double;
      out ALoY, AHiY, ALoW, AHiW: Double;
      out AHasLo, AHasHi: Boolean; out ADiag: TFitLevelsDiag): Boolean;
    function DiagGeo(const P: TLatLon;
      out ALoY, AHiY, ALoW, AHiW: Double;
      out AHasLo, AHasHi: Boolean; out ADiag: TFitLevelsDiag): Boolean;

    property Projection: TLocalProjection read FProj;
  end;

implementation

constructor TFitHeightLayer.Create;
begin
  inherited Create;
  FProj := nil;
  FCells := specialize TDictionary<Int64, Integer>.Create;
  FActive := False;
  FInv := 1.0 / FITL_CELL_M;
end;

destructor TFitHeightLayer.Destroy;
begin
  FreeAndNil(FProj);
  FreeAndNil(FCells);
  inherited Destroy;
end;

class function TFitHeightLayer.CellKey(ACx, ACz: Integer): Int64;
begin
  Result := (Int64(Cardinal(ACx)) shl 32) or Int64(Cardinal(ACz));
end;

procedure TFitHeightLayer.Clear;
begin
  SetLength(FPts, 0);
  SetLength(FNext, 0);
  FCells.Clear;
  FreeAndNil(FProj);
  FActive := False;
  FSig := '';
  FDatumTime:=nil;FDatumCorrection:=nil;FDatumSource:='';
end;

procedure TFitHeightLayer.SetSelectedDatum(const Source: string;
  const TimeSec, RawAlt, CalAlt: array of Double);
var I,N:Integer;
begin
  FDatumTime:=nil;FDatumCorrection:=nil;FDatumSource:='';
  N:=Length(TimeSec);
  if (N<2) or (Length(RawAlt)<>N) or (Length(CalAlt)<>N) then Exit;
  for I:=0 to N-1 do begin
    if IsNan(TimeSec[I]) or IsInfinite(TimeSec[I]) or
       IsNan(RawAlt[I]) or IsInfinite(RawAlt[I]) or
       IsNan(CalAlt[I]) or IsInfinite(CalAlt[I]) then Exit;
    if (I>0) and (TimeSec[I]<TimeSec[I-1]) then Exit;
  end;
  SetLength(FDatumTime,N);SetLength(FDatumCorrection,N);
  for I:=0 to N-1 do begin
    FDatumTime[I]:=TimeSec[I];FDatumCorrection[I]:=RawAlt[I]-CalAlt[I];
  end;
  FDatumSource:=Source;
end;

function TFitHeightLayer.HasSelectedDatum: Boolean;
begin Result:=Length(FDatumTime)>=2 end;

function TFitHeightLayer.CorrectSelectedAltitude(TimeSec, RawAlt: Double;
  out CalAlt: Double): Boolean;
var Lo,Hi,M:Integer;F:Double;
begin
  CalAlt:=RawAlt;
  Result:=HasSelectedDatum and not(IsNan(TimeSec) or IsInfinite(TimeSec));
  if not Result then Exit;
  Lo:=0;Hi:=High(FDatumTime);
  if TimeSec<=FDatumTime[Lo] then CalAlt:=RawAlt-FDatumCorrection[Lo]
  else if TimeSec>=FDatumTime[Hi] then CalAlt:=RawAlt-FDatumCorrection[Hi]
  else begin
    while Lo+1<Hi do begin
      M:=(Lo+Hi) div 2;if FDatumTime[M]<=TimeSec then Lo:=M else Hi:=M;
    end;
    F:=(TimeSec-FDatumTime[Lo])/(FDatumTime[Hi]-FDatumTime[Lo]);
    CalAlt:=RawAlt-(FDatumCorrection[Lo]+(FDatumCorrection[Hi]-FDatumCorrection[Lo])*F);
  end;
end;

procedure TFitHeightLayer.SetData(const APts: TFitLayerPointArray;
  const AOrigin: TLatLon; const ASig: string);
begin
  Clear;
  FPts := Copy(APts, 0, Length(APts));
  FSig := ASig;
  FActive := Length(FPts) >= 2;
  if not FActive then Exit;
  FProj := TLocalProjection.Create(AOrigin);
  BuildIndex;
end;

procedure TFitHeightLayer.BuildIndex;
var
  I, GX, GZ, Head: Integer;
  Key: Int64;
begin
  FCells.Clear;
  SetLength(FNext, Length(FPts));
  for I := 0 to High(FPts) do
  begin
    GX := Floor(FPts[I].X * FInv);
    GZ := Floor(FPts[I].Z * FInv);
    Key := CellKey(GX, GZ);
    if FCells.TryGetValue(Key, Head) then
      FNext[I] := Head
    else
      FNext[I] := -1;
    FCells.AddOrSetValue(Key, I);
  end;
end;

procedure TFitHeightLayer.LevelsXZ(X, Z: Double;
  out ALoY, AHiY, ALoW, AHiW, ALoGndW, ADkY, ADkW: Double;
  out AHasLo, AHasHi: Boolean; ADiag: PFitLevelsDiag);
var
  CX, CZ, GX, GZ, Idx, Head, NC, I, J, Split, GapAt, LoEnd: Integer;
  Key: Int64;
  D, Wl, Av, Wv, Gap, BestGap: Double;
  Dv, HasGnd: Boolean;
  Alt:  array[0 .. FITL_MAX_CAND - 1] of Double;
  W:    array[0 .. FITL_MAX_CAND - 1] of Double;
  Dk:   array[0 .. FITL_MAX_CAND - 1] of Boolean;   { пометка настила }

  { Высота уровня = ВЗВЕШЕННАЯ МЕДИАНА высот его кандидатов (вес — косинус-
    феатер по расстоянию до FIT-точки). Медиана вместо среднего: при
    наложении заездов файл-выброс с уехавшим уровнем утягивал среднее за
    собой пропорционально весу; медиана держит уровень большинства
    (устойчивость до ~50% веса выбросов). Интерполяция по весовым позициям
    (кандидат = ступень CDF в центре своего веса, между ступенями линейно)
    сохраняет НЕПРЕРЫВНОСТЬ вдоль запроса: веса меняются плавно с
    координатой, значит и медиана плавная, без перещёлкиваний между
    заездами внутри уровня; кандидаты уже отсортированы по высоте общим
    проходом LevelsXZ. AW — максимум веса группы (для бленда с DEM у
    террейна). }
  procedure GroupStat(A0, A1: Integer; out AY, AW: Double);
  var
    K: Integer;
    WSum, MaxW, Half, CumB, PPrev, PCur: Double;
  begin
    WSum := 0; MaxW := 0;
    for K := A0 to A1 do
    begin
      WSum := WSum + W[K];
      if W[K] > MaxW then MaxW := W[K];
    end;
    AW := MaxW;
    if WSum <= 1e-9 then begin AY := 0; Exit; end;
    if A0 = A1 then begin AY := Alt[A0]; Exit; end;

    { Позиция кандидата K на CDF: (вес до него + половина его веса)/WSum.
      Ищем пару позиций вокруг 0.5 и линейно интерполируем высоту. }
    Half := 0.5;
    CumB := 0;
    PPrev := 0;
    AY := Alt[A1];                       { 0.5 правее всех позиций }
    for K := A0 to A1 do
    begin
      PCur := (CumB + 0.5 * W[K]) / WSum;
      if PCur >= Half then
      begin
        if K = A0 then
          AY := Alt[A0]                  { 0.5 левее первой позиции }
        else if PCur > PPrev then
          AY := Alt[K - 1] + (Alt[K] - Alt[K - 1])
                * (Half - PPrev) / (PCur - PPrev)
        else
          AY := Alt[K];
        Exit;
      end;
      CumB  := CumB + W[K];
      PPrev := PCur;
    end;
  end;

begin
  ALoY := 0; AHiY := 0; ALoW := 0; AHiW := 0; ALoGndW := 0;
  ADkY := 0; ADkW := 0;
  AHasLo := False; AHasHi := False;
  if ADiag <> nil then
  begin
    ADiag^.LoGndW := 0;
    ADiag^.NC := 0; ADiag^.MinAlt := 0; ADiag^.MaxAlt := 0;
    ADiag^.BestGap := 0; ADiag^.SplitAt := -1; ADiag^.AltN := 0;
  end;
  if not FActive then Exit;

  { Сбор кандидатов коридора (3×3 ячейки), вес — косинус-феатер. }
  NC := 0;
  CX := Floor(X * FInv);
  CZ := Floor(Z * FInv);
  for GZ := CZ - 1 to CZ + 1 do
    for GX := CX - 1 to CX + 1 do
    begin
      Key := CellKey(GX, GZ);
      if not FCells.TryGetValue(Key, Head) then Continue;
      Idx := Head;
      while Idx >= 0 do
      begin
        D := Sqrt(Sqr(FPts[Idx].X - X) + Sqr(FPts[Idx].Z - Z));
        if D < FITL_HALF_WIDTH_M + FITL_FEATHER_M then
        begin
          if D <= FITL_HALF_WIDTH_M then
            Wl := 1.0
          else
            Wl := 0.5 * (1.0 + Cos(Pi * (D - FITL_HALF_WIDTH_M)
                                   / FITL_FEATHER_M));
          if NC < FITL_MAX_CAND then
          begin
            Alt[NC] := FPts[Idx].AltCal;
            W[NC]   := Wl;
            Dk[NC]  := FPts[Idx].Deck;
            Inc(NC);
          end;
        end;
        Idx := FNext[Idx];
      end;
    end;

  if NC = 0 then Exit;

  { Сортировка по высоте (вставками; кандидатов немного). }
  for I := 1 to NC - 1 do
  begin
    Av := Alt[I]; Wv := W[I]; Dv := Dk[I];
    J := I - 1;
    while (J >= 0) and (Alt[J] > Av) do
    begin
      Alt[J + 1] := Alt[J];
      W[J + 1]   := W[J];
      Dk[J + 1]  := Dk[J];
      Dec(J);
    end;
    Alt[J + 1] := Av;
    W[J + 1]   := Wv;
    Dk[J + 1]  := Dv;
  end;

  { Крупнейший разрыв высот → граница нижний/верхний уровень. }
  BestGap := 0; GapAt := -1;
  for I := 0 to NC - 2 do
  begin
    Gap := Alt[I + 1] - Alt[I];
    if Gap > BestGap then begin BestGap := Gap; GapAt := I; end;
  end;

  AHasLo := True;
  if (GapAt >= 0) and (BestGap > FITL_LEVEL_SPLIT_M) then
  begin
    Split := GapAt + 1;               { верхний уровень: [Split .. NC-1] }
    { ФАЛЬШИВЫЙ РАСКОЛ: оба кластера целиком из точек НАСТИЛА — это не «мост
      над низовой дорогой», а ОДИН настил с рассогласованными датумами
      заездов. Настоящая двухуровневость всегда имеет наземные точки в
      нижнем кластере (по низу кто-то ехал ПО ЗЕМЛЕ). Схлопываем в один
      уровень — взвешенная медиана всего набора давит выброс числом.
      Реальный случай (мост 19, way 67142935): 91 точка одиннадцати заездов
      на 173..179 (честный настил, +9 над водой) против 11 точек прогревной
      зоны ОДНОГО заезда на 184..188 → разрыв 4.8 создавал раскол; DeckTarget
      брал верхний (мост уезжал на «третий уровень» 187), а маска пролёта
      обходилась (она работает только при not HasHi) — «нижний уровень
      авторитетен» поднимал землю И ВОДУ под мостом на высоту настила 176
      вместо DEM 167. Цена схлопывания: экзотика «два настила друг над
      другом» усреднится — принято осознанно. }
    HasGnd := False;
    for I := 0 to NC - 1 do
      if not Dk[I] then begin HasGnd := True; Break; end;
    if not HasGnd then
    begin
      Split := -1;
      GroupStat(0, NC - 1, ALoY, ALoW);
      LoEnd := NC - 1;
    end
    else
    begin
      GroupStat(0, Split - 1, ALoY, ALoW);
      GroupStat(Split, NC - 1, AHiY, AHiW);
      AHasHi := True;
      LoEnd := Split - 1;
    end;
  end
  else
  begin
    Split := -1;
    GroupStat(0, NC - 1, ALoY, ALoW); { один уровень }
    LoEnd := NC - 1;
  end;
  { Наземный вес нижнего кластера: максимум веса его НЕ-настильных точек.
    0 = кластер целиком из настила (над точкой ехали только ПО мосту) —
    RoadTarget такой цели дороге не отдаёт, а GroundHeight не поднимает
    землю. }
  for I := 0 to LoEnd do
    if (not Dk[I]) and (W[I] > ALoGndW) then ALoGndW := W[I];

  { Уровень настила: интерполированная взвешенная медиана настильных
    кандидатов. Массив отсортирован по высоте — идём по нему, учитывая
    только Dk. Позиция кандидата на CDF = (вес деков до него + половина
    его)/сумма; между позициями линейно (та же схема, что в GroupStat). }
  Wv := 0;
  for I := 0 to NC - 1 do
    if Dk[I] then
    begin
      Wv := Wv + W[I];
      if W[I] > ADkW then ADkW := W[I];
    end;
  if Wv > 1e-9 then
  begin
    Av := 0;          { накопленный вес деков до текущего }
    Gap := 0;         { позиция предыдущего дека на CDF }
    J := -1;          { индекс предыдущего дека }
    ADkY := 0;
    for I := 0 to NC - 1 do
    begin
      if not Dk[I] then Continue;
      D := (Av + 0.5 * W[I]) / Wv;      { позиция этого дека }
      if D >= 0.5 then
      begin
        if J < 0 then
          ADkY := Alt[I]
        else if D > Gap then
          ADkY := Alt[J] + (Alt[I] - Alt[J]) * (0.5 - Gap) / (D - Gap)
        else
          ADkY := Alt[I];
        Break;
      end;
      Av := Av + W[I];
      Gap := D;
      J := I;
      ADkY := Alt[I];                    { 0.5 правее всех позиций }
    end;
  end;

  { Диагностика для ген-лога: наполняем ПОСЛЕ сортировки/раскола (Alt[]
    отсортирован по возрастанию, кандидатов NC). }
  if ADiag <> nil then
  begin
    ADiag^.LoGndW  := ALoGndW;
    ADiag^.NC      := NC;
    ADiag^.MinAlt  := Alt[0];
    ADiag^.MaxAlt  := Alt[NC - 1];
    ADiag^.BestGap := BestGap;
    ADiag^.SplitAt := Split;
    if NC < 16 then ADiag^.AltN := NC else ADiag^.AltN := 16;
    for I := 0 to ADiag^.AltN - 1 do ADiag^.Alt[I] := Alt[I];
  end;
end;

class function TFitHeightLayer.BlendGround(ATarget, AWeight,
  ADem: Double): Double;
var Alpha, D: Double;
begin
  Alpha := AWeight;
  if Alpha > 1.0 then Alpha := 1.0;
  if Alpha >= 0.999 then
    Exit(ATarget);                 { полотно: высота ТОЧНО из FIT, без DEM }
  D := ATarget - ADem;
  if D > FITL_MAX_DELTA_M then D := FITL_MAX_DELTA_M
  else if D < -FITL_MAX_DELTA_M then D := -FITL_MAX_DELTA_M;
  Result := ADem + D * Alpha;
end;

function TFitHeightLayer.GroundHeightXZ(X, Z, ADem: Double;
  ABridgeMask: Boolean): Double;
var
  LoY, HiY, LoW, HiW, LoGndW, DkY, DkW: Double;
  HasLo, HasHi: Boolean;
begin
  Result := ADem;
  if not FActive then Exit;
  LevelsXZ(X, Z, LoY, HiY, LoW, HiW, LoGndW, DkY, DkW, HasLo, HasHi);
  if not HasLo then Exit;                { нет FIT в точке — чистый DEM }
  { Под пролётом моста одиночный уровень = настил → земля по DEM (воздух под
    мостом), НО не выше (настил − габарит): грубый DEM не разрешает выемку
    нижней дороги/ж-д, его холм вылезал ВЫШЕ полотна — докапываем габарит.
    Двойной уровень → нижний (низовая дорога развязки), он авторитетен. }
  if ABridgeMask and (not HasHi) then
  begin
    if Result > LoY - FITL_UNDERPASS_CLEAR_M then
      Result := LoY - FITL_UNDERPASS_CLEAR_M;
    Exit;
  end;
  { ОТКАТ правила «чисто настильный кластер не поднимает землю» (жило один
    прогон). Мотив был — подмостовая дорога у торца пролёта вставала на
    «короткую насыпь» из настильных точек. Но тот же признак (в коридоре
    одни Deck-точки) имеет и НАСТОЯЩАЯ насыпь подхода к мосту: её точки
    флагованы настилом по превышению над DEM (+5..9), наземных рядом нет —
    и правило роняло её на DEM (регресс «упал участок насыпи, который
    всегда был хорошо»). Флаги точек «воздух под настилом» от «грунта под
    насыпью» не отличают в принципе; это знание OSM-геометрии, и оно уже
    применяется по назначению: маска пролёта (CollectSpanMask) поперёк
    кроет полный коридор слоя, продольно НАМЕРЕННО EndM=0 — за торцом
    насыпь подхода, полоса DEM там рвала стык полотна с пяткой настила.
    Насыпь сохраняется — как и было задумано слоем изначально. }
  Result := BlendGround(LoY, LoW, ADem);
end;

function TFitHeightLayer.CorrectHeightXZ(X, Z, ADem: Double): Double;
begin
  Result := GroundHeightXZ(X, Z, ADem, False);
end;

function TFitHeightLayer.RoadTargetXZ(X, Z: Double; out AY: Double): Boolean;
var
  LoY, HiY, LoW, HiW, LoGndW, DkY, DkW: Double;
  HasLo, HasHi: Boolean;
begin
  AY := 0;
  Result := False;
  LevelsXZ(X, Z, LoY, HiY, LoW, HiW, LoGndW, DkY, DkW, HasLo, HasHi);
  if not HasLo then Exit;
  { Жёсткую цель полотна отдаём только когда:
      1) узел НА полотне заезда (наземный вес ≥ FITL_ROAD_SNAP_W = внутри
         FITL_HALF_WIDTH_M) — НЕ в поперечном феатере: прежняя жёсткая
         привязка на всей ширине HALF+FEATHER (26 м) поднимала на высоту
         заезда параллельные дороги, по которым не ездили, и ломала
         контракт route-only «поперечные дороги остаются без FIT»
         (Osm3dFitLayerBuild): поперечная дорога режет 26-м коридор и
         получала цель;
      2) в нижнем кластере есть НЕ-настильные точки (LoGndW считает только
         их): дорога, проходящая ПОД заездом (путепровод/насыпь без
         bridge-тега), видела в коридоре один кластер — настил — и целиком
         поднималась на него (+5..12 м). GroundHeightXZ от этого защищён
         маской пролёта и габаритом; у дороги защиты не было.
    Отказ здесь безопасен: дорога ложится на террейн, а террейн сам
    корректируется мягким блендом (BlendGround) с защитой пролётов.
    Цена: заезд по дамбе/насыпи, ошибочно помеченный настилом
    (порог FITL_BRIDGE_RISE_M по превышению над DEM), теряет прямую цель
    полотна — но террейн там всё равно поднят к FIT (GroundHeight флаги
    настила игнорирует), дорога драпируется по нему. }
  if LoGndW < FITL_ROAD_SNAP_W then Exit;
  AY := LoY;
  Result := True;
end;

function TFitHeightLayer.DeckTargetXZ(X, Z: Double; out AY: Double): Boolean;
var
  LoY, HiY, LoW, HiW, LoGndW, DkY, DkW: Double;
  HasHi: Boolean;
begin
  AY := 0;
  LevelsXZ(X, Z, LoY, HiY, LoW, HiW, LoGndW, DkY, DkW, Result, HasHi);
  if not Result then Exit;
  { Настил = медиана настильных кандидатов (см. LevelsXZ): «верхний кластер»
    у моста 19 оказывался прогревным мусором одного заезда, и концы пролёта
    расходились (176 против 187 — «третий уровень»). Фолбэк на кластерную
    логику — для низкого моста, чьи точки не отфлагованы настилом
    (превышение < FITL_BRIDGE_RISE_M): там медианы деков нет. }
  if DkW > 0 then
    AY := DkY
  else if HasHi then
    AY := HiY
  else
    AY := LoY;
end;

function TFitHeightLayer.GroundHeightGeo(const P: TLatLon; ADem: Double;
  ABridgeMask: Boolean): Double;
var V: TVector3;
begin
  if not FActive then Exit(ADem);
  V := FProj.Project(P);
  Result := GroundHeightXZ(V.X, V.Z, ADem, ABridgeMask);
end;

function TFitHeightLayer.CorrectHeightGeo(const P: TLatLon;
  ADem: Double): Double;
begin
  Result := GroundHeightGeo(P, ADem, False);
end;

function TFitHeightLayer.RoadTargetGeo(const P: TLatLon;
  out AY: Double): Boolean;
var V: TVector3;
begin
  AY := 0;
  if not FActive then Exit(False);
  V := FProj.Project(P);
  Result := RoadTargetXZ(V.X, V.Z, AY);
end;

function TFitHeightLayer.DeckTargetGeo(const P: TLatLon;
  out AY: Double): Boolean;
var V: TVector3;
begin
  AY := 0;
  if not FActive then Exit(False);
  V := FProj.Project(P);
  Result := DeckTargetXZ(V.X, V.Z, AY);
end;

function TFitHeightLayer.DiagXZ(X, Z: Double;
  out ALoY, AHiY, ALoW, AHiW: Double;
  out AHasLo, AHasHi: Boolean; out ADiag: TFitLevelsDiag): Boolean;
var
  LoGndW, DkY, DkW: Double;
begin
  FillChar(ADiag, SizeOf(ADiag), 0);
  ADiag.SplitAt := -1;
  ALoY := 0; AHiY := 0; ALoW := 0; AHiW := 0;
  AHasLo := False; AHasHi := False;
  if not FActive then Exit(False);
  LevelsXZ(X, Z, ALoY, AHiY, ALoW, AHiW, LoGndW, DkY, DkW, AHasLo, AHasHi,
    @ADiag);
  Result := AHasLo;
end;

function TFitHeightLayer.DiagGeo(const P: TLatLon;
  out ALoY, AHiY, ALoW, AHiW: Double;
  out AHasLo, AHasHi: Boolean; out ADiag: TFitLevelsDiag): Boolean;
var V: TVector3;
begin
  FillChar(ADiag, SizeOf(ADiag), 0);
  ADiag.SplitAt := -1;
  ALoY := 0; AHiY := 0; ALoW := 0; AHiW := 0;
  AHasLo := False; AHasHi := False;
  if not FActive then Exit(False);
  V := FProj.Project(P);
  Result := DiagXZ(V.X, V.Z, ALoY, AHiY, ALoW, AHiW, AHasLo, AHasHi, ADiag);
end;

end.
