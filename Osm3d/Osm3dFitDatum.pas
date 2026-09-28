unit Osm3dFitDatum;

{$mode objfpc}{$H+}

{ ═══ Нивелирование датума высот FIT по папке заездов ═══════════════════

  Задача. Барометр велокомпьютера даёт верные ПЕРЕПАДЫ высоты, но:
    • некалиброван — абсолютный уровень плавает (у нас ±0.4…10 м);
    • дрейфует за поездку НЕЛИНЕЙНО (погода) — на одном месте в разное
      время высота гуляла до ±13 м (замер по самоперекрытиям).
  Чтобы использовать FIT как эталон для коррекции террейна, оба эффекта
  надо снять. Один заезд этого не может: медленный подъём высоты на
  длинном перегоне неотличим от дрейфа. Решение — СЕТЬ заездов папки.

  Модель. Каждому файлу k — своя кривая дрейфа c_k(t), кусочно-линейная
  на редких узлах (NODE_SEC ≈ 4 мин ≈ 1.6 км пути). Редкость узлов —
  не экономия, а СТРУКТУРНАЯ гарантия: c_k физически длинноволновой, не
  может повторить среднемасштабную ошибку DEM (лес ~сотни м < шага узла).
  Приведённая высота: alt_cal = alt_fit − c_k(t).

  Слои ограничений (взвешенный МНК, CG по нормальным уравнениям):
    1. ОБЩИЕ УЧАСТКИ (главный). Точки любых файлов ближе SAME_ROAD_R в
       плане (для одного файла — ещё и далёкие по времени) лежат на одной
       земле ⇒ c_a(ti) − c_b(tj) = alt_i − alt_j. Связь БЕЗ участия DEM.
       Кросс-заездные пары дают 41…98 % покрытия выбранного трека.
    2. DEM-АРБИТР (только на ОДИНОКИХ точках — без общей пары). Там
       перепад FIT неотличим «дрейф vs реальный склон»; DEM на длинной
       волне (>1 км) верен во всех заездах (corr 0.98…1.0) и говорит,
       есть ли подъём: c_k(ti) ≈ alt_i − dem_i, слабый вес. На точках с
       опорами слоя 1 не ставится — чтобы не тянуть к DEM-ошибкам (лес).
    3. ГЛАДКОСТЬ. c_k''≈0 — дрейф медленный; заполняет микродыры.
    4. УРОВЕНЬ. Слабый якорь среднего c_k к 0 — гасит нуль-моду сети.
  Робастность: 2 прохода IRLS — пары/якоря с большой невязкой (мосты,
  лес, GPS-глюк) глушатся весом Хубера и система перерешивается.

  Юнит самодостаточен (Classes/SysUtils/Math): работает на массивах
  точек, к проекту цепляется тонким адаптером (FIT→TFitDatumPoint). }

interface

uses
  Classes, SysUtils, Math;

const
  { Радиус «одной дороги» в плане, м. 15 м ловит соседние полосы и оба
    направления как одну дорогу — это и нужно для общих участков. }
  SAME_ROAD_RADIUS_M = 15.0;

  { Шаг узлов кривой дрейфа c(t), с. ~4 мин ≈ 1.6 км пути — длинная
    волна (см. заголовок). }
  DATUM_NODE_SEC = 240.0;

  { Веса слоёв. Общие участки главенствуют; DEM — слабый арбитр;
    гладкость держит форму; уровень едва фиксирует нуль. }
  W_OVERLAP = 1.0;
  W_DEM     = 0.05;
  W_SMOOTH  = 3.0;
  W_LEVEL   = 0.02;

  { Порог совпадения по времени внутри одного файла, с — пары ближе по
    времени это соседи по треку, не «второй проезд». }
  SELF_TIME_GAP_SEC = 180.0;

  { IRLS: порог Хубера, м — сравнивается с невязкой напрямую (Cal − Cal,
    без нормировки на σ); число проходов. }
  HUBER_K       = 2.5;
  IRLS_PASSES   = 2;

  { CG. }
  CG_MAX_ITER = 4000;
  CG_TOL      = 1e-8;

type
  { Одна точка заезда (спроецированная снаружи в метры XZ ради
    дешёвого пространственного хэша; альтернатива — lat/lon+cos, но
    метры удобнее и детерминированнее). }
  TFitDatumPoint = record
    X, Z: Double;      { мировые метры (любая общая проекция для папки) }
    Alt:  Double;      { сырая высота FIT, м }
    Dem:  Double;      { высота мира под точкой (для DEM-арбитра), м }
    T:    Double;      { время от старта файла, с (стоянки уже без пути) }
  end;
  TFitDatumPointArray = array of TFitDatumPoint;

  { Заезд = массив точек + результат (заполняется Solve). }
  TFitDatumRide = record
    Points: TFitDatumPointArray;
    Cal:    array of Double;   { приведённая высота = Alt − c(t) }
    Drift:  array of Double;   { c(t) в каждой точке, м }
  end;
  TFitDatumRideArray = array of TFitDatumRide;

{ Нивелировать сеть заездов. Изменяет Rides: заполняет Cal и Drift.
  ASelected — индекс выбранного файла (для лога/статистики; в расчёте
  участвуют все). Возвращает строку статистики.
  ACancel — необязательный флаг отмены: проверяется в длинных циклах
  (перебор пар сотен тысяч точек, проходы IRLS); при взводе возвращает
  'fit datum: cancelled' досрочно — иначе деструктор карты ждёт весь
  расчёт на WaitFor воркера (десятки секунд при Stop). }
function SolveFitDatum(var Rides: TFitDatumRideArray;
  ASelected: Integer = 0; ACancel: PBoolean = nil): string;

implementation

type
  { Разреженная строка ограничения: Σ coef·x[idx] = rhs, вес w.
    Entries статические (максимум 4 коэффициента у пары) — без
    тысяч мелких аллокаций на строку. }
  TConEntry = record Idx: Integer; Coef: Double; end;
  TConRow = record
    Entries: array[0..3] of TConEntry;
    EN:      Integer;
    Rhs, W:  Double;
  end;
  TConArray = array of TConRow;

{ ── Пространственный хэш точек всех заездов (ячейки SAME_ROAD_R) ── }
type
  TCellKey = record Cx, Cz: Integer; end;
  TCellHit = record Ride, Idx: Integer; end;

{ Плоская хэш-таблица ячейка→список точек. Реализация на открытой
  адресации была бы быстрее, но для десятков тысяч точек хватает
  отсортированного массива ключей + бинпоиска. }
type
  TBucket = record
    Key:  TCellKey;
    Hits: array of TCellHit;
  end;
  TBucketArray = array of TBucket;

function CellOf(X, Z: Double): TCellKey;
begin
  Result.Cx := Floor(X / SAME_ROAD_RADIUS_M);
  Result.Cz := Floor(Z / SAME_ROAD_RADIUS_M);
end;

function KeyLess(const A, B: TCellKey): Boolean; inline;
begin
  if A.Cx <> B.Cx then Result := A.Cx < B.Cx
  else Result := A.Cz < B.Cz;
end;

function KeyEq(const A, B: TCellKey): Boolean; inline;
begin
  Result := (A.Cx = B.Cx) and (A.Cz = B.Cz);
end;

{ Построить бакеты (отсортированы по ключу). }
procedure BuildBuckets(const Rides: TFitDatumRideArray;
  out Buckets: TBucketArray);
var
  Flat: array of record Key: TCellKey; Hit: TCellHit; end;
  NF, R, I, J, K: Integer;
  TmpKey: TCellKey; TmpHit: TCellHit;
begin
  NF := 0;
  for R := 0 to High(Rides) do Inc(NF, Length(Rides[R].Points));
  SetLength(Flat, NF);
  K := 0;
  for R := 0 to High(Rides) do
    for I := 0 to High(Rides[R].Points) do
    begin
      Flat[K].Key := CellOf(Rides[R].Points[I].X, Rides[R].Points[I].Z);
      Flat[K].Hit.Ride := R;
      Flat[K].Hit.Idx := I;
      Inc(K);
    end;
  { сортировка по ключу — простая быстрая (insertion слишком медленно на
    десятках тысяч; берём shell-sort) }
  K := 1;
  while K < NF do K := K * 3 + 1;
  K := K div 3;
  while K >= 1 do
  begin
    for I := K to NF - 1 do
    begin
      TmpKey := Flat[I].Key; TmpHit := Flat[I].Hit;
      J := I;
      while (J >= K) and KeyLess(TmpKey, Flat[J - K].Key) do
      begin
        Flat[J] := Flat[J - K];
        Dec(J, K);
      end;
      Flat[J].Key := TmpKey; Flat[J].Hit := TmpHit;
    end;
    K := K div 3;
  end;
  { склейка в бакеты: Flat отсортирован — диапазон одной ячейки
    непрерывен, размер известен до заполнения (без роста по одному) }
  SetLength(Buckets, NF);
  NF := 0;
  I := 0;
  while I < Length(Flat) do
  begin
    J := I;
    while (J < Length(Flat)) and KeyEq(Flat[J].Key, Flat[I].Key) do
      Inc(J);
    Buckets[NF].Key := Flat[I].Key;
    SetLength(Buckets[NF].Hits, J - I);
    for K := I to J - 1 do
      Buckets[NF].Hits[K - I] := Flat[K].Hit;
    Inc(NF);
    I := J;
  end;
  SetLength(Buckets, NF);
end;

function FindBucket(const Buckets: TBucketArray;
  const K: TCellKey): Integer;
var Lo, Hi, Mid: Integer;
begin
  Lo := 0; Hi := High(Buckets); Result := -1;
  while Lo <= Hi do
  begin
    Mid := (Lo + Hi) div 2;
    if KeyEq(Buckets[Mid].Key, K) then Exit(Mid)
    else if KeyLess(Buckets[Mid].Key, K) then Lo := Mid + 1
    else Hi := Mid - 1;
  end;
end;

{ Quicksort по возрастанию (итеративный хвост). Для медианы порядок равных
  неважен — замена shell-sort на пер-заездных массивах LvlDiff. }
procedure SortDoubles(var A: array of Double; Lo, Hi: Integer);
var
  I, J: Integer;
  Pivot, Tmp: Double;
begin
  while Lo < Hi do
  begin
    I := Lo; J := Hi;
    Pivot := A[(Lo + Hi) div 2];
    repeat
      while A[I] < Pivot do Inc(I);
      while A[J] > Pivot do Dec(J);
      if I <= J then
      begin
        Tmp := A[I]; A[I] := A[J]; A[J] := Tmp;
        Inc(I); Dec(J);
      end;
    until I > J;
    if J - Lo < Hi - I then
    begin
      SortDoubles(A, Lo, J);
      Lo := I;
    end
    else
    begin
      SortDoubles(A, I, Hi);
      Hi := J;
    end;
  end;
end;

{ ── CG по нормальным уравнениям AᵀWA x = AᵀW b ── }
procedure ApplyAtWA(const Con: TConArray; ACount: Integer;
  const X: array of Double; var Y: array of Double);
var
  R, E, N: Integer;
  Dot, Wr: Double;
begin
  for N := 0 to High(Y) do Y[N] := 0;
  for R := 0 to ACount - 1 do
  begin
    Dot := 0;
    for E := 0 to Con[R].EN - 1 do
      Dot := Dot + Con[R].Entries[E].Coef * X[Con[R].Entries[E].Idx];
    Wr := Con[R].W * Con[R].W * Dot;   { вес входит дважды (WᵀW) }
    for E := 0 to Con[R].EN - 1 do
      Y[Con[R].Entries[E].Idx] :=
        Y[Con[R].Entries[E].Idx] + Con[R].Entries[E].Coef * Wr;
  end;
end;

procedure ComputeAtWb(const Con: TConArray; ACount: Integer;
  var B: array of Double);
var R, E: Integer; Wr: Double;
begin
  for R := 0 to High(B) do B[R] := 0;
  for R := 0 to ACount - 1 do
  begin
    Wr := Con[R].W * Con[R].W * Con[R].Rhs;
    for E := 0 to Con[R].EN - 1 do
      B[Con[R].Entries[E].Idx] :=
        B[Con[R].Entries[E].Idx] + Con[R].Entries[E].Coef * Wr;
  end;
end;

procedure SolveCG(const Con: TConArray; ACount, NV: Integer;
  var X: array of Double);
var
  Rk, Pk, Ap, Bb: array of Double;
  I, Iter: Integer;
  Rs, RsNew, Alpha, PAp: Double;
begin
  SetLength(Rk, NV); SetLength(Pk, NV); SetLength(Ap, NV); SetLength(Bb, NV);
  ComputeAtWb(Con, ACount, Bb);
  for I := 0 to NV - 1 do X[I] := 0;
  { r0 = b - A x0 = b }
  for I := 0 to NV - 1 do begin Rk[I] := Bb[I]; Pk[I] := Bb[I]; end;
  Rs := 0; for I := 0 to NV - 1 do Rs := Rs + Rk[I] * Rk[I];
  if Rs < 1e-30 then Exit;
  for Iter := 0 to CG_MAX_ITER - 1 do
  begin
    ApplyAtWA(Con, ACount, Pk, Ap);
    PAp := 0; for I := 0 to NV - 1 do PAp := PAp + Pk[I] * Ap[I];
    if Abs(PAp) < 1e-30 then Break;
    Alpha := Rs / PAp;
    for I := 0 to NV - 1 do X[I] := X[I] + Alpha * Pk[I];
    for I := 0 to NV - 1 do Rk[I] := Rk[I] - Alpha * Ap[I];
    RsNew := 0; for I := 0 to NV - 1 do RsNew := RsNew + Rk[I] * Rk[I];
    if Sqrt(RsNew) < CG_TOL then Break;
    for I := 0 to NV - 1 do Pk[I] := Rk[I] + (RsNew / Rs) * Pk[I];
    Rs := RsNew;
  end;
end;

function SolveFitDatum(var Rides: TFitDatumRideArray;
  ASelected: Integer; ACancel: PBoolean): string;
var
  Buckets: TBucketArray;
  NodeBase: array of Integer;
  NV, R, I, J, NR, Pass, NPair, NLone, NCon: Integer;
  Con: TConArray;
  X: array of Double;
  HasSupport: array of array of Boolean;

  function DatumCancelled: Boolean; inline;
  begin
    Result := (ACancel <> nil) and ACancel^;
  end;

  { узел-ссылка: базовый индекс + дробь до следующего }
  procedure NodeRef(R2: Integer; T: Double; out N0: Integer;
    out Frac: Double; out N1: Integer);
  var K, NK: Integer; XT: Double;
  begin
    NK := (NodeBase[R2 + 1] - NodeBase[R2]);
    XT := T / DATUM_NODE_SEC;
    K := Trunc(XT);
    if K >= NK - 1 then
    begin
      N0 := NodeBase[R2] + NK - 1; Frac := 0; N1 := N0;
    end
    else
    begin
      N0 := NodeBase[R2] + K; Frac := XT - K; N1 := N0 + 1;
    end;
  end;

  procedure AddRow(const E: array of TConEntry; Rhs, W: Double);
  var M: Integer;
  begin
    if NCon = Length(Con) then
      SetLength(Con, Max(1024, NCon * 2));   { амортизированный рост }
    Con[NCon].EN := Length(E);
    for M := 0 to High(E) do Con[NCon].Entries[M] := E[M];
    Con[NCon].Rhs := Rhs;
    Con[NCon].W := W;
    Inc(NCon);
  end;

  function EvalDrift(R2: Integer; T: Double): Double;
  var N0, N1: Integer; Fr: Double;
  begin
    NodeRef(R2, T, N0, Fr, N1);
    Result := (1 - Fr) * X[N0] + Fr * X[N1];
  end;

var
  N0a, N1a, N0b, N1b, Bk, H: Integer;
  Dx, Dz, RR, JJ, BestR, BestI: Integer;
  BestD: Double;
  Fa, Fb, D2, Res, Wt: Double;
  { Кэш пар: геометрия неизменна между IRLS-проходами, меняется
    только вес Хубера. Строим пары один раз (проход 1), дальше —
    лишь пересчёт веса и решение. }
  PairE: array of array[0..3] of TConEntry;
  PairRhs: array of Double;
  PairRa, PairIa, PairRb, PairIb: array of Integer;
  NPairs, PairCap, StaticCon, TotN: Integer;
  LvlMed: Double;
  LvlDiff: array of Double;
  E2: array[0..3] of TConEntry;
  EDem: array[0..1] of TConEntry;
  E1: array[0..0] of TConEntry;
  E3: array[0..2] of TConEntry;
  CK: TCellKey;
begin
  NR := Length(Rides);
  if NR = 0 then Exit('fit datum: no rides');

  { узловые базы: NV = сумма (число узлов) по файлам }
  SetLength(NodeBase, NR + 1);
  NodeBase[0] := 0;
  for R := 0 to NR - 1 do
  begin
    if Length(Rides[R].Points) = 0 then
      NodeBase[R + 1] := NodeBase[R]
    else
      NodeBase[R + 1] := NodeBase[R] +
        Trunc(Rides[R].Points[High(Rides[R].Points)].T / DATUM_NODE_SEC) + 2;
  end;
  NV := NodeBase[NR];
  if NV = 0 then Exit('fit datum: empty');
  SetLength(X, NV);

  BuildBuckets(Rides, Buckets);

  { маска «есть общая опора» — для DEM-арбитра только на одиноких }
  SetLength(HasSupport, NR);
  for R := 0 to NR - 1 do
  begin
    SetLength(HasSupport[R], Length(Rides[R].Points));
    for I := 0 to High(HasSupport[R]) do HasSupport[R][I] := False;
  end;

  { ── Проход 1: найти пары (перебор ячеек) в КЭШ, построить статичные
    слои 2–4 в Con один раз. Дальше проходы лишь пересчитывают вес
    пар и решают — без повторного перебора сотен тысяч точек. ── }
  NPairs := 0; PairCap := 0;
  NCon := 0; NPair := 0; NLone := 0;

  { СЛОЙ 1: пары → кэш }
  for R := 0 to NR - 1 do
  begin
    I := 0;
    while I <= High(Rides[R].Points) do
    begin
      if (I and $1FF) = 0 then
        if DatumCancelled then Exit('fit datum: cancelled');
      BestR := -1; BestI := -1; BestD := 1e30;
      for Dx := -1 to 1 do
        for Dz := -1 to 1 do
        begin
          CK.Cx := Floor(Rides[R].Points[I].X / SAME_ROAD_RADIUS_M) + Dx;
          CK.Cz := Floor(Rides[R].Points[I].Z / SAME_ROAD_RADIUS_M) + Dz;
          Bk := FindBucket(Buckets, CK);
          if Bk < 0 then Continue;
          for H := 0 to High(Buckets[Bk].Hits) do
          begin
            RR := Buckets[Bk].Hits[H].Ride;
            JJ := Buckets[Bk].Hits[H].Idx;
            if (RR = R) and
               (Abs(Rides[RR].Points[JJ].T - Rides[R].Points[I].T)
                 < SELF_TIME_GAP_SEC) then Continue;
            if (RR < R) or ((RR = R) and (JJ <= I)) then Continue;
            D2 := Sqr(Rides[RR].Points[JJ].X - Rides[R].Points[I].X)
                + Sqr(Rides[RR].Points[JJ].Z - Rides[R].Points[I].Z);
            if (D2 < Sqr(SAME_ROAD_RADIUS_M)) and (D2 < BestD) then
            begin
              BestD := D2; BestR := RR; BestI := JJ;
            end;
          end;
        end;
      if BestR >= 0 then
      begin
        NodeRef(R, Rides[R].Points[I].T, N0a, Fa, N1a);
        NodeRef(BestR, Rides[BestR].Points[BestI].T, N0b, Fb, N1b);
        if NPairs = PairCap then
        begin
          PairCap := Max(1024, PairCap * 2);
          SetLength(PairE, PairCap);
          SetLength(PairRhs, PairCap);
          SetLength(PairRa, PairCap); SetLength(PairIa, PairCap);
          SetLength(PairRb, PairCap); SetLength(PairIb, PairCap);
        end;
        PairE[NPairs][0].Idx := N0a; PairE[NPairs][0].Coef := (1 - Fa);
        PairE[NPairs][1].Idx := N1a; PairE[NPairs][1].Coef := Fa;
        PairE[NPairs][2].Idx := N0b; PairE[NPairs][2].Coef := -(1 - Fb);
        PairE[NPairs][3].Idx := N1b; PairE[NPairs][3].Coef := -Fb;
        PairRhs[NPairs] := Rides[R].Points[I].Alt
                         - Rides[BestR].Points[BestI].Alt;
        PairRa[NPairs] := R;      PairIa[NPairs] := I;
        PairRb[NPairs] := BestR;  PairIb[NPairs] := BestI;
        Inc(NPairs);
        HasSupport[R][I] := True;
        HasSupport[BestR][BestI] := True;
      end;
      Inc(I, 2);
    end;
  end;
  NPair := NPairs;

  { СЛОЙ 2: DEM-арбитр на одиноких (статично) }
  for R := 0 to NR - 1 do
  begin
    I := 0;
    while I <= High(Rides[R].Points) do
    begin
      if not HasSupport[R][I] then
      begin
        NodeRef(R, Rides[R].Points[I].T, N0a, Fa, N1a);
        EDem[0].Idx := N0a; EDem[0].Coef := (1 - Fa);
        EDem[1].Idx := N1a; EDem[1].Coef := Fa;
        AddRow(EDem, Rides[R].Points[I].Alt - Rides[R].Points[I].Dem, W_DEM);
        Inc(NLone);
      end;
      Inc(I, 10);
    end;
  end;

  { СЛОЙ 3: гладкость (статично) }
  for R := 0 to NR - 1 do
    for J := NodeBase[R] + 1 to NodeBase[R + 1] - 2 do
    begin
      E3[0].Idx := J - 1; E3[0].Coef := 1;
      E3[1].Idx := J;     E3[1].Coef := -2;
      E3[2].Idx := J + 1; E3[2].Coef := 1;
      AddRow(E3, 0, W_SMOOTH);
    end;

  { СЛОЙ 4: уровень (статично) }
  for J := 0 to NV - 1 do
  begin
    E1[0].Idx := J; E1[0].Coef := 1;
    AddRow(E1, 0, W_LEVEL);
  end;

  StaticCon := NCon;   { границы статичной части Con }

  { ── Проходы IRLS: дописываем пары с текущим весом, решаем ── }
  for Pass := 1 to IRLS_PASSES do
  begin
    if DatumCancelled then Exit('fit datum: cancelled');
    NCon := StaticCon;   { откат к статичной части, пары добавляем заново }
    for H := 0 to NPairs - 1 do
    begin
      Wt := W_OVERLAP;
      if Pass > 1 then
      begin
        Res := Rides[PairRa[H]].Cal[PairIa[H]]
             - Rides[PairRb[H]].Cal[PairIb[H]];
        if Abs(Res) > HUBER_K then Wt := Wt * HUBER_K / Abs(Res);
      end;
      AddRow(PairE[H], PairRhs[H], Wt);
    end;

    SolveCG(Con, NCon, NV, X);

    { приведённые высоты этого прохода (для IRLS следующего) }
    for R := 0 to NR - 1 do
    begin
      SetLength(Rides[R].Cal, Length(Rides[R].Points));
      SetLength(Rides[R].Drift, Length(Rides[R].Points));
      for I := 0 to High(Rides[R].Points) do
      begin
        Rides[R].Drift[I] := EvalDrift(R, Rides[R].Points[I].T);
        Rides[R].Cal[I] := Rides[R].Points[I].Alt - Rides[R].Drift[I];
      end;
    end;
  end;

  { ── Якорь абсолютного уровня к DEM: ПЕР-ЗАЕЗДНО ──
    Сеть по общим участкам определяет ФОРМУ дрейфа, но её общий уровень
    слабо закреплён (мало одиноких DEM-точек). Единая медиана по ВСЕМ
    заездам не годилась: у заездов разные маршруты, и один сдвиг оставлял
    пер-заездные уровни разъехавшимися на ±15 м (наблюдали медианы
    Cal−Dem −10.3..+5.0) — скорректированный фит уходил на ~9 м от
    рельефа, хотя простой сдвиг каждого заезда к его рельефу давал ~2.7 м.
    Поэтому у КАЖДОГО заезда вычитаем ЕГО медиану (Cal − Dem): его
    приведённые высоты садятся на уровень мира (медиана Cal−Dem → 0),
    форма (уклоны, кросс-заездная согласованность внутри заезда) не
    меняется — сдвиг на константу. Это то самое «приведение фита к
    рельефу», ради которого и задумывался приведённый уровень. }
  for R := 0 to NR - 1 do
  begin
    TotN := Length(Rides[R].Points);
    if TotN = 0 then Continue;
    SetLength(LvlDiff, TotN);
    for I := 0 to TotN - 1 do
      LvlDiff[I] := Rides[R].Cal[I] - Rides[R].Points[I].Dem;
    SortDoubles(LvlDiff, 0, TotN - 1);
    LvlMed := LvlDiff[TotN div 2];
    for I := 0 to TotN - 1 do
    begin
      Rides[R].Cal[I] := Rides[R].Cal[I] - LvlMed;
      Rides[R].Drift[I] := Rides[R].Drift[I] + LvlMed;
    end;
  end;

  Result := Format(
    'fit datum: rides %d, nodes %d, pairs %d, lone %d, selected %d',
    [NR, NV, NPair, NLone, ASelected]);
end;

end.
