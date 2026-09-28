unit Osm3dIntGeo;

{ Целочисленное ядро ОБЩЕГО геометрического пайплайна — фундамент переезда
  зданий/табличек/заборов на int (продолжение int-first переписывания
  композита, см. Osm3dCarveLattice).

  Мотивация. Сегодня XZ-геометрия билдеров рождается так:
      JSON (7 знаков) → Double lat/lon → БЛОК-ЛОКАЛЬНАЯ float-проекция →
      Single-вершины.
  Один и тот же дом, попавший в halo четырёх блоков, получает ЧЕТЫРЕ разных
  битовых представления координат (origin блока разный → другие ошибки
  округления Single). Отсюда недетерминизм на стыках и вся хрупкость сварки.

  Целевая схема:
      JSON → ТОЧНЫЙ int e7 (lat/lon · 10^7) → МИРОВАЯ int-решётка 1/64 м
      (якорь — origin СЕССИИ, фикс-точка Q32) → блок-локальные int-координаты
      (мировые минус целочисленный сдвиг блока).
  Узел имеет ровно ОДНО мировое int-представление; в любом блоке его
  локальные координаты отличаются на точный целый сдвиг. Вся плановая (XZ)
  геометрия и предикаты — целочисленные и побитно совпадают между блоками
  и потоками.

  Точность парсинга: стандартный вывод Overpass — 7 десятичных знаков
  (нативная точность OSM). Double представляет такое значение с абсолютной
  ошибкой < 1e-9 градуса; после умножения на 1e7 суммарная ошибка < 1e-6 —
  много меньше 0.5, поэтому Round(AsFloat·1e7) ТОЧНО восстанавливает исходное
  целое e7. Отдельный текстовый парсер не нужен.

  Что остаётся float (осознанно, как в композите): высоты (Y — из тегов и
  рельефа), нормали, UV, метрики шрифта. Они детерминированы автоматически,
  как только их XZ-входы стали int: одинаковые биты на входе → одинаковые
  биты на выходе на любом блоке.

  Юнит без CGE-зависимостей (только Osm3dCarveLattice, который сам автономен)
  — компилируется и тестируется отдельно. }

{$mode objfpc}{$H+}

interface

uses
  Osm3dCarveLattice;   { TLatticePoint, LATTICE_UNITS_PER_M }

const
  { Единиц e7 в градусе: OSM-координата = градусы · E7_PER_DEG, точное целое. }
  E7_PER_DEG = 10000000;

type
  { Проекция «e7-градусы → мировая решётка 1/64 м», якорь — origin сессии.
    Формулы зеркалят TLocalProjection (equirectangular):
        X = −(lon − lon0) · MpdLon     (восток → −X)
        Z =  (lat − lat0) · MpdLat     (север  → +Z)
    Метрические множители ПЕРЕДАЮТСЯ снаружи (Proj.MetersPerDegreeLat/Lon
    сессионной float-проекции) — гарантирует побитовое согласие масштабов
    двух миров без дублирования констант Земли.

    Арифметика: D_e7 · K_q32 >> 32 c округлением к ближайшему (half away
    from zero). K = MpdDeg · 64 / 1e7 · 2^32 ≈ 3.06e9; |D_e7| ≤ 1.8e9
    (полный диапазон долгот) → произведение ≤ 5.6e18 < 2^63. Запас
    двукратный даже в худшем теоретическом случае; реальные сессии — доли
    градуса. }
  TLatticeProjection = class
  private
    FOriginLatE7: Int64;
    FOriginLonE7: Int64;
    FKLatQ32:     Int64;   { лат-единиц решётки на единицу e7 широты, Q32 }
    FKLonQ32:     Int64;   { то же для долготы (уже с cos сессии), Q32 }
  public
    constructor Create(AOriginLatE7, AOriginLonE7: Int64;
      AMetersPerDegLat, AMetersPerDegLon: Double);

    { Мировые координаты решётки (1/64 м от origin сессии). }
    function XOfLonE7(ALonE7: Int64): Int64;
    function ZOfLatE7(ALatE7: Int64): Int64;

    property OriginLatE7: Int64 read FOriginLatE7;
    property OriginLonE7: Int64 read FOriginLonE7;
  end;

{ Градусы (Double) → точное e7. Для координат, уже прошедших через Double
  (JSON-парс, готовые TLatLon): восстанавливает исходное 7-знаковое целое,
  см. обоснование точности в шапке юнита. }
function DegToE7(ADeg: Double): Int64; inline;

{ e7 → градусы (каноничный Double-образ целого). }
function E7ToDeg(AE7: Int64): Double; inline;

{ Решётка → метры (точное: I · 1/64, степень двойки). }
function LatUnitsToMeters(AUnits: Int64): Double; inline;

{ Целочисленный квадратный корень (floor), Ньютон. AV ≥ 0. }
function ISqrt64(AV: Int64): Int64;

{ ── Кольца на решётке ────────────────────────────────────────────────────
  Конвенция знака повторяет движковую (Osm3dGeoMath.EnsureCCWXZ):
  «CCW сверху» в осях (−X=восток, +Z=север) == ОТРИЦАТЕЛЬНАЯ shoelace-
  площадь. Все предикаты точные (Int64, без переполнений при блоке
  ±32 км: |коорд| < 2^21, произведения < 2^43, суммы < 2^58). }

{ Удвоенная знаковая площадь (shoelace ×2). }
function RingSignedArea2(const R: array of TLatticePoint): Int64;

{ Убрать последовательные дубли и совпадающую замыкающую точку. Возвращает
  новую длину; хвост массива не очищается — вызывающий делает SetLength. }
function RingDedupInPlace(var R: TLatticePointArray): Integer;

{ Привести знак shoelace-площади: AWantNegative=True → «CCW сверху»
  по-движковому (как EnsureCCWXZ), False → обратная ориентация (нужна,
  например, стенам внутреннего двора). Разворот на месте. }
procedure RingEnsureShoelaceSign(var R: TLatticePointArray;
  AWantNegative: Boolean);

{ Убрать почти-коллинеарные (180°) вершины: перпендикулярное отклонение
  вершины от прямой (prev→next) меньше AMaxPerpUnits единиц решётки.
  Дефолт 8 единиц = 12.5 см — согласован с float-фиксом крыш
  (COLLINEAR_EPS_M = 0.12). Сравнение без деления и без переполнения:
  |cross| < eps · |N−P|, где |N−P| берётся через ISqrt64. Один проход,
  маркировка по ИСХОДНЫМ соседям (как в float-версии). Возвращает False,
  если после чистки осталось < 3 вершин. }
function RingRemoveCollinear(var R: TLatticePointArray;
  AMaxPerpUnits: Int64 = 8): Boolean;

{ Точка внутри кольца (чётность пересечений; точки на границе считаются
  внутри). Кольцо без самопересечений, ориентация любая. }
function PointInRingLat(const P: TLatticePoint;
  const R: array of TLatticePoint): Boolean;

{ Границы кольца. False на пустом. }
function RingBoundsLat(const R: array of TLatticePoint;
  out AMinX, AMinZ, AMaxX, AMaxZ: Int32): Boolean;

implementation

{ ── скаляры ─────────────────────────────────────────────────────────── }

function DegToE7(ADeg: Double): Int64; inline;
begin
  Result := Round(ADeg * E7_PER_DEG);
end;

function E7ToDeg(AE7: Int64): Double; inline;
begin
  Result := AE7 / E7_PER_DEG;
end;

function LatUnitsToMeters(AUnits: Int64): Double; inline;
begin
  Result := AUnits * LATTICE_M_PER_UNIT;
end;

function ISqrt64(AV: Int64): Int64;
var
  X, Prev: Int64;
begin
  if AV <= 0 then Exit(0);
  { стартовое приближение сверху через Double, дожим Ньютоном (2-3 шага) }
  X := Trunc(Sqrt(AV)) + 1;
  repeat
    Prev := X;
    X := (X + AV div X) div 2;
  until X >= Prev;
  Result := Prev;
  { страховка от единичного перелёта double-старта }
  while Result * Result > AV do Dec(Result);
  while (Result + 1) * (Result + 1) <= AV do Inc(Result);
end;

{ Q32-умножение с округлением к ближайшему (half away from zero).
  Детерминировано и симметрично по знаку. }
function MulQ32Round(A, K: Int64): Int64; inline;
var
  P: Int64;
begin
  P := A * K;
  if P >= 0 then
    Result := Int64(QWord(P + $80000000) shr 32)
  else
    Result := -Int64(QWord((-P) + $80000000) shr 32);
end;

{ ── TLatticeProjection ──────────────────────────────────────────────── }

constructor TLatticeProjection.Create(AOriginLatE7, AOriginLonE7: Int64;
  AMetersPerDegLat, AMetersPerDegLon: Double);
begin
  inherited Create;
  FOriginLatE7 := AOriginLatE7;
  FOriginLonE7 := AOriginLonE7;
  { лат-единиц на e7-градус: MpdDeg · 64 / 1e7, в Q32. Round по Double —
    K вычисляется ОДИН раз на сессию, дальше только целые. }
  FKLatQ32 := Round(AMetersPerDegLat * LATTICE_UNITS_PER_M / E7_PER_DEG
                    * 4294967296.0);
  FKLonQ32 := Round(AMetersPerDegLon * LATTICE_UNITS_PER_M / E7_PER_DEG
                    * 4294967296.0);
end;

function TLatticeProjection.XOfLonE7(ALonE7: Int64): Int64;
begin
  { восток → −X, зеркально TLocalProjection.Project }
  Result := -MulQ32Round(ALonE7 - FOriginLonE7, FKLonQ32);
end;

function TLatticeProjection.ZOfLatE7(ALatE7: Int64): Int64;
begin
  Result := MulQ32Round(ALatE7 - FOriginLatE7, FKLatQ32);
end;

{ ── кольца ──────────────────────────────────────────────────────────── }

function RingSignedArea2(const R: array of TLatticePoint): Int64;
var
  I, N: Integer;
  A, B: TLatticePoint;
begin
  Result := 0;
  N := Length(R);
  if N < 3 then Exit;
  for I := 0 to N - 1 do
  begin
    A := R[I];
    B := R[(I + 1) mod N];
    Result := Result + Int64(A.X) * B.Z - Int64(B.X) * A.Z;
  end;
end;

function RingDedupInPlace(var R: TLatticePointArray): Integer;
var
  I, W, N: Integer;
begin
  N := Length(R);
  W := 0;
  for I := 0 to N - 1 do
    if (W = 0) or (R[I].X <> R[W - 1].X) or (R[I].Z <> R[W - 1].Z) then
    begin
      R[W] := R[I];
      Inc(W);
    end;
  { совпадающая замыкающая }
  if (W >= 2) and (R[W - 1].X = R[0].X) and (R[W - 1].Z = R[0].Z) then
    Dec(W);
  Result := W;
end;

procedure RingEnsureShoelaceSign(var R: TLatticePointArray;
  AWantNegative: Boolean);
var
  A2: Int64;
  I, N: Integer;
  T: TLatticePoint;
begin
  A2 := RingSignedArea2(R);
  if A2 = 0 then Exit;
  if (A2 < 0) = AWantNegative then Exit;
  N := Length(R);
  for I := 0 to N div 2 - 1 do
  begin
    T := R[I];
    R[I] := R[N - 1 - I];
    R[N - 1 - I] := T;
  end;
end;

function RingRemoveCollinear(var R: TLatticePointArray;
  AMaxPerpUnits: Int64): Boolean;
var
  N, I, K, Keep: Integer;
  Mark: array of Boolean;
  Px, Pz, Cx, Cz, Ex, Ez, Cross, Len: Int64;
  Dst: TLatticePointArray;
begin
  Result := False;
  N := Length(R);
  if N < 3 then Exit;
  SetLength(Mark, N);
  Keep := N;
  for I := 0 to N - 1 do
  begin
    Px := R[(I + N - 1) mod N].X;  Pz := R[(I + N - 1) mod N].Z;
    Cx := R[I].X;                  Cz := R[I].Z;
    Ex := R[(I + 1) mod N].X - Px;
    Ez := R[(I + 1) mod N].Z - Pz;
    if (Ex = 0) and (Ez = 0) then
      Mark[I] := True                    { prev = next: вершина лишняя }
    else
    begin
      Cross := (Cx - Px) * Ez - (Cz - Pz) * Ex;
      Len   := ISqrt64(Ex * Ex + Ez * Ez);
      { |perp| = |cross| / |edge| < eps  ⇔  |cross| < eps·|edge| }
      Mark[I] := Abs(Cross) < AMaxPerpUnits * Len;
    end;
    if Mark[I] then Dec(Keep);
  end;
  if Keep < 3 then Exit;
  SetLength(Dst, Keep);
  K := 0;
  for I := 0 to N - 1 do
    if not Mark[I] then
    begin
      Dst[K] := R[I];
      Inc(K);
    end;
  R := Dst;
  Result := True;
end;

function Min(A, B: Int32): Int32; inline;
begin
  if A < B then Result := A else Result := B;
end;

function Max(A, B: Int32): Int32; inline;
begin
  if A > B then Result := A else Result := B;
end;

function PointInRingLat(const P: TLatticePoint;
  const R: array of TLatticePoint): Boolean;
var
  I, N: Integer;
  A, B: TLatticePoint;
  Inside: Boolean;
  Cross: Int64;
begin
  N := Length(R);
  Result := False;
  if N < 3 then Exit;
  Inside := False;
  for I := 0 to N - 1 do
  begin
    A := R[I];
    B := R[(I + 1) mod N];
    { точка на ребре — считаем внутри (точный предикат) }
    Cross := Int64(B.X - A.X) * (P.Z - A.Z) - Int64(B.Z - A.Z) * (P.X - A.X);
    if (Cross = 0)
       and (P.X >= Min(A.X, B.X)) and (P.X <= Max(A.X, B.X))
       and (P.Z >= Min(A.Z, B.Z)) and (P.Z <= Max(A.Z, B.Z)) then
      Exit(True);
    { чётность пересечений горизонтальным лучом +X (полуинтервал по Z) }
    if (A.Z > P.Z) <> (B.Z > P.Z) then
      if ((Int64(B.X - A.X) * (P.Z - A.Z)
         - Int64(P.X - A.X) * (B.Z - A.Z)) > 0) = (B.Z > A.Z) then
        Inside := not Inside;
  end;
  Result := Inside;
end;

function RingBoundsLat(const R: array of TLatticePoint;
  out AMinX, AMinZ, AMaxX, AMaxZ: Int32): Boolean;
var
  I: Integer;
begin
  Result := Length(R) > 0;
  AMinX := 0; AMinZ := 0; AMaxX := 0; AMaxZ := 0;
  if not Result then Exit;
  AMinX := R[0].X; AMaxX := R[0].X;
  AMinZ := R[0].Z; AMaxZ := R[0].Z;
  for I := 1 to High(R) do
  begin
    if R[I].X < AMinX then AMinX := R[I].X
    else if R[I].X > AMaxX then AMaxX := R[I].X;
    if R[I].Z < AMinZ then AMinZ := R[I].Z
    else if R[I].Z > AMaxZ then AMaxZ := R[I].Z;
  end;
end;

end.
