unit Osm3dCarveLattice;

{ Целочисленное ядро водонепроницаемого карва (этап 1 переделки, см.
  carve-watertight-redesign.md).

  Инвариант, который обслуживает юнит: «ячейка не имеет права изобрести
  точку». Все XZ-координаты карва живут на целочисленной решётке; все
  пересечения (сегмент×сегмент, сегмент×линия клеточной сетки) вычисляются
  ЗДЕСЬ, один раз на чанк, целочисленными предикатами — детерминированно и
  одинаково для любой ячейки и любого потока. Потребители (клиппер, эмиссия)
  получают готовые канонические цепочки и таблицы точек на границах ячеек;
  обе стороны любой границы читают ОДИН список и потому совпадают побитно.

  Шаг решётки: 1/64 м ≈ 1.6 см. Исходник — карта OSM с точностью в лучшем
  случае дециметры, поэтому грубее 1 см — можно, тоньше — незачем; степень
  двойки даёт точную конверсию float<->int одним умножением и дешёвые
  предикаты. Диапазон: чанк ±4 км -> |коорд| < 2^18 единиц; ориентация —
  до 2^39, числители пересечений — до 2^59: всё в Int64 с запасом.

  Про snap-rounding честно: округление точки пересечения на решётку может
  сдвинуть её на <=0.7 единицы (~1.1 см) от истинной. Водонепроницаемость от
  этого НЕ страдает — оба участника получают ОДНУ И ТУ ЖЕ округлённую точку,
  их цепочки изгибаются тождественно. Теоретические вторичные пересечения
  изогнутых цепочек — перекрытия масштаба ~1 клетки решётки; ZIndex-peeling
  режет обе стороны всё теми же общими цепочками, так что и они швов не
  дают. Инвариант держится на ОБЩИХ ЦЕПОЧКАХ, а не на идеальной планарности.

  Юнит без CGE-зависимостей — компилируется и тестируется автономно. }

{$mode objfpc}{$H+}

interface

const
  { Единиц решётки на метр. Менять только степенью двойки. }
  LATTICE_UNITS_PER_M = 64;
  LATTICE_M_PER_UNIT  = 1.0 / LATTICE_UNITS_PER_M;

type
  TLatticePoint = record
    X, Z: Int32;
  end;
  TLatticePointArray = array of TLatticePoint;

  TLatticeSeg = record
    A, B: TLatticePoint;
    Tag:  Int32;        { произвольная метка вызывающего (id полигона/слоя) }
  end;

  { Глобальный нодер чанка. Порядок работы:
      1) AddGridLineX/Z — линии клеточной сетки (границы ячеек и
         coarse-блоков; кратные линии добавлять один раз);
      2) AddSegment — все сегменты, способные оказаться на границе
         выпускаемого куска (контуры полигонов, рёбра захватываемых мешей);
      3) Node — один вызов, все взаимные пересечения;
      4) ChainOf(seg) — каноническая цепочка сегмента: концы + все врезки,
         отсортированы вдоль сегмента, без дублей;
         BorderCutsX/Z(line) — канонические точки на линии сетки,
         отсортированы вдоль линии.
    После Node добавлять что-либо нельзя. }
  TLatticeNoder = class
  private
    FSegs:    array of TLatticeSeg;
    FSegN:    Integer;
    FLinesX:  array of Int32;      { X-координаты вертикальных линий }
    FLinesZ:  array of Int32;
    FLineXN, FLineZN: Integer;
    FCuts:    array of TLatticePointArray;  { пер-сегментные врезки (сырьё) }
    FCutN:    array of Integer;              { фактическое число (ёмкость — в Length) }
    FChains:  array of TLatticePointArray;  { готовые цепочки (после Node) }
    FBorderX: array of TLatticePointArray;  { пер-линейные точки }
    FBorderZ: array of TLatticePointArray;
    FBorderXN, FBorderZN: array of Integer;
    FNoded:   Boolean;
    procedure PushCut(SegIdx: Integer; const P: TLatticePoint);
    procedure PushBorderX(LineIdx: Integer; const P: TLatticePoint);
    procedure PushBorderZ(LineIdx: Integer; const P: TLatticePoint);
  public
    function  AddSegment(const A, B: TLatticePoint; ATag: Int32): Integer;
    procedure AddGridLineX(AX: Int32);
    procedure AddGridLineZ(AZ: Int32);
    procedure Node;
    function  SegCount: Integer;
    function  SegOf(I: Integer): TLatticeSeg;
    function  ChainOf(I: Integer): TLatticePointArray;
    function  LineXCount: Integer;
    function  LineZCount: Integer;
    function  BorderCutsX(LineIdx: Integer): TLatticePointArray;
    function  BorderCutsZ(LineIdx: Integer): TLatticePointArray;
  public
    { Диагностика из Node: непустая, если сработал кламп безумного bbox
      (мусорная точка среди сегментов). Читать после Node. }
    ClampNote: string;
  end;

  { Глобальный словарь вершин: решёточная точка -> индекс. Одна и та же
    точка из любой ячейки/слоя получает один индекс — «велд» по построению.
    Open addressing, ключ пакуется в Int64. }
  TLatticeVertexDict = class
  private
    FKeys:  array of Int64;     { упакованные точки; свободный слот = NOKEY }
    FVals:  array of Integer;
    FCap:   Integer;
    FCount: Integer;
    FPts:   TLatticePointArray; { индекс -> точка }
    procedure Grow;
  public
    constructor Create;
    function IndexOf(const P: TLatticePoint): Integer;  { add-if-missing }
    function TryIndexOf(const P: TLatticePoint; out Idx: Integer): Boolean;
    function Count: Integer;
    function PointOf(I: Integer): TLatticePoint;
  end;

{ Квантование мировой координаты (метры) на решётку. Floor(v*64+0.5):
  детерминировано, симметрично сшивает .5 вверх (не банковское Round). }
function LatQuant(V: Double): Int32;
function LatPoint(WX, WZ: Double): TLatticePoint;
function LatToWorld(I: Int32): Single;

function LatSame(const A, B: TLatticePoint): Boolean;

{ Ориентация: >0 — B левее луча O->A, <0 — правее, 0 — коллинеарны.
  Точный Int64 (|коорд| < 2^18 -> |результат| < 2^39). }
function LatCross(const O, A, B: TLatticePoint): Int64;

{ P на отрезке [A,B] (включая концы)? Коллинеарность + bbox, точно. }
function LatOnSegment(const P, A, B: TLatticePoint): Boolean;

{ Деление с округлением к ближайшему (половины — от нуля), знаки любые. }
function DivRoundNearest(Num, Den: Int64): Int64;

{ Бинпоиски по отсортированному массиву (N — фактическая длина):
  первый индекс с Arr[i] >= V; последний с Arr[i] <= V (-1 если нет). }
function LatLowerBound(const Arr: array of Int32; N: Integer; V: Int32): Integer;
function LatUpperBound(const Arr: array of Int32; N: Integer; V: Int32): Integer;

{ Пересечение отрезков на решётке.
  lirNone     — не пересекаются;
  lirPoint    — единственная точка (в т.ч. касание концом): P — округлённая
                на решётку, ОДИНАКОВАЯ для обоих участников;
  lirOverlap  — коллинеарное наложение: [P, Q] — концы общей подцепочки
                (решёточные точки исходных отрезков). }
type
  TLatIntersectKind = (lirNone, lirPoint, lirOverlap);

function LatSegIntersect(const A1, B1, A2, B2: TLatticePoint;
  out P, Q: TLatticePoint): TLatIntersectKind;

implementation

uses
  SysUtils, Math;

function LatQuant(V: Double): Int32;
begin
  Result := Int32(Trunc(Floor(V * LATTICE_UNITS_PER_M + 0.5)));
end;

function LatPoint(WX, WZ: Double): TLatticePoint;
begin
  Result.X := LatQuant(WX);
  Result.Z := LatQuant(WZ);
end;

function LatToWorld(I: Int32): Single;
begin
  Result := I * LATTICE_M_PER_UNIT;
end;

function LatSame(const A, B: TLatticePoint): Boolean;
begin
  Result := (A.X = B.X) and (A.Z = B.Z);
end;

function LatCross(const O, A, B: TLatticePoint): Int64;
begin
  Result := Int64(A.X - O.X) * Int64(B.Z - O.Z)
          - Int64(A.Z - O.Z) * Int64(B.X - O.X);
end;

function LatOnSegment(const P, A, B: TLatticePoint): Boolean;
begin
  Result := (LatCross(A, B, P) = 0)
        and (P.X >= Min(A.X, B.X)) and (P.X <= Max(A.X, B.X))
        and (P.Z >= Min(A.Z, B.Z)) and (P.Z <= Max(A.Z, B.Z));
end;

function DivRoundNearest(Num, Den: Int64): Int64;
var
  q, r: Int64;
begin
  if Den < 0 then begin Num := -Num; Den := -Den; end;
  q := Num div Den;
  r := Num - q * Den;                { знак остатка = знак Num }
  if r >= 0 then
  begin
    if 2 * r >= Den then Inc(q);
  end
  else
  begin
    if -2 * r >= Den then Dec(q);    { -0.5 -> -1: половины от нуля }
  end;
  Result := q;
end;

function LatSegIntersect(const A1, B1, A2, B2: TLatticePoint;
  out P, Q: TLatticePoint): TLatIntersectKind;
var
  d1a, d1b, d2a, d2b, den, tnum: Int64;

  { Для коллинеарного случая: упорядочить точки вдоль общей прямой. }
  function LessAlong(const U, V: TLatticePoint): Boolean;
  begin
    if U.X <> V.X then Result := U.X < V.X
    else Result := U.Z < V.Z;
  end;
  procedure MinMax2(const U, V: TLatticePoint; out Mn, Mx: TLatticePoint);
  begin
    if LessAlong(U, V) then begin Mn := U; Mx := V; end
    else begin Mn := V; Mx := U; end;
  end;

var
  mn1, mx1, mn2, mx2: TLatticePoint;
begin
  Result := lirNone;
  P.X := 0; P.Z := 0; Q := P;

  d2a := LatCross(A1, B1, A2);   { положение концов 2 относительно 1 }
  d2b := LatCross(A1, B1, B2);
  d1a := LatCross(A2, B2, A1);   { и наоборот }
  d1b := LatCross(A2, B2, B1);

  if (d2a = 0) and (d2b = 0) then
  begin
    { Коллинеарны. Пересечение bbox вдоль общей прямой. }
    MinMax2(A1, B1, mn1, mx1);
    MinMax2(A2, B2, mn2, mx2);
    if LessAlong(mn2, mn1) then mn2 := mn1;   { mn2 := max(mn1, mn2) }
    if LessAlong(mx1, mx2) then mx2 := mx1;   { mx2 := min(mx1, mx2) }
    if LessAlong(mx2, mn2) then Exit;         { разъехались }
    if LatSame(mn2, mx2) then
    begin
      P := mn2;
      Exit(lirPoint);                          { касание концами }
    end;
    P := mn2; Q := mx2;
    Exit(lirOverlap);
  end;

  { Общий случай: строгие/нестрогие знаки. Пересекаются, если концы каждого
    по разные стороны (или на) прямой другого И попадание в оба отрезка. }
  if ((d2a > 0) and (d2b > 0)) or ((d2a < 0) and (d2b < 0)) then Exit;
  if ((d1a > 0) and (d1b > 0)) or ((d1a < 0) and (d1b < 0)) then Exit;

  { Касание концом — вернуть сам решёточный конец (без деления). }
  if d2a = 0 then begin
    if LatOnSegment(A2, A1, B1) then begin P := A2; Exit(lirPoint); end
    else Exit;
  end;
  if d2b = 0 then begin
    if LatOnSegment(B2, A1, B1) then begin P := B2; Exit(lirPoint); end
    else Exit;
  end;
  if d1a = 0 then begin
    if LatOnSegment(A1, A2, B2) then begin P := A1; Exit(lirPoint); end
    else Exit;
  end;
  if d1b = 0 then begin
    if LatOnSegment(B1, A2, B2) then begin P := B1; Exit(lirPoint); end
    else Exit;
  end;

  { Строгое пересечение: t по первому отрезку = d1a / (d1a - d1b),
    точка = A1 + t*(B1-A1); считаем в Int64, округляем к ближайшему.
    Оба участника зовут эту же формулу -> одна и та же точка. }
  den  := d1a - d1b;                 { <> 0: знаки d1a/d1b разные }
  tnum := d1a;
  P.X := Int32(DivRoundNearest(Int64(A1.X) * den + Int64(B1.X - A1.X) * tnum, den));
  P.Z := Int32(DivRoundNearest(Int64(A1.Z) * den + Int64(B1.Z - A1.Z) * tnum, den));
  Result := lirPoint;
end;

function LatLowerBound(const Arr: array of Int32; N: Integer; V: Int32): Integer;
var lo, hi, mid: Integer;
begin
  lo := 0; hi := N - 1; Result := N;
  while lo <= hi do
  begin
    mid := (lo + hi) div 2;
    if Arr[mid] >= V then begin Result := mid; hi := mid - 1; end
    else lo := mid + 1;
  end;
end;

function LatUpperBound(const Arr: array of Int32; N: Integer; V: Int32): Integer;
var lo, hi, mid: Integer;
begin
  lo := 0; hi := N - 1; Result := -1;
  while lo <= hi do
  begin
    mid := (lo + hi) div 2;
    if Arr[mid] <= V then begin Result := mid; lo := mid + 1; end
    else hi := mid - 1;
  end;
end;

{ ───────────────────────── TLatticeNoder ───────────────────────── }

function TLatticeNoder.AddSegment(const A, B: TLatticePoint;
  ATag: Int32): Integer;
begin
  if FNoded then
    raise Exception.Create('TLatticeNoder: AddSegment after Node');
  if LatSame(A, B) then Exit(-1);          { деген после квантования }
  if FSegN >= Length(FSegs) then
    SetLength(FSegs, FSegN * 2 + 64);
  FSegs[FSegN].A := A;
  FSegs[FSegN].B := B;
  FSegs[FSegN].Tag := ATag;
  Result := FSegN;
  Inc(FSegN);
end;

procedure TLatticeNoder.AddGridLineX(AX: Int32);
begin
  if FNoded then
    raise Exception.Create('TLatticeNoder: AddGridLineX after Node');
  if FLineXN >= Length(FLinesX) then SetLength(FLinesX, FLineXN * 2 + 16);
  FLinesX[FLineXN] := AX;
  Inc(FLineXN);
end;

procedure TLatticeNoder.AddGridLineZ(AZ: Int32);
begin
  if FNoded then
    raise Exception.Create('TLatticeNoder: AddGridLineZ after Node');
  if FLineZN >= Length(FLinesZ) then SetLength(FLinesZ, FLineZN * 2 + 16);
  FLinesZ[FLineZN] := AZ;
  Inc(FLineZN);
end;

procedure TLatticeNoder.PushCut(SegIdx: Integer; const P: TLatticePoint);
begin
  if FCutN[SegIdx] >= Length(FCuts[SegIdx]) then
    SetLength(FCuts[SegIdx], FCutN[SegIdx] * 2 + 4);
  FCuts[SegIdx][FCutN[SegIdx]] := P;
  Inc(FCutN[SegIdx]);
end;

procedure TLatticeNoder.PushBorderX(LineIdx: Integer; const P: TLatticePoint);
begin
  if FBorderXN[LineIdx] >= Length(FBorderX[LineIdx]) then
    SetLength(FBorderX[LineIdx], FBorderXN[LineIdx] * 2 + 8);
  FBorderX[LineIdx][FBorderXN[LineIdx]] := P;
  Inc(FBorderXN[LineIdx]);
end;

procedure TLatticeNoder.PushBorderZ(LineIdx: Integer; const P: TLatticePoint);
begin
  if FBorderZN[LineIdx] >= Length(FBorderZ[LineIdx]) then
    SetLength(FBorderZ[LineIdx], FBorderZN[LineIdx] * 2 + 8);
  FBorderZ[LineIdx][FBorderZN[LineIdx]] := P;
  Inc(FBorderZN[LineIdx]);
end;

procedure TLatticeNoder.Node;
const
  BUCKET = 512;                       { 8 м в единицах решётки }
  { Макс. ячеек бакетов (≈268 МБ указателей + 134 МБ счётчиков). Обычный
    чанк — десятки тысяч; чанк с далёкими некропнутыми реками — до ~17 М.
    Больше — верный признак мусорной точки, включается кламп к сетке. }
  MAX_BUCKET_CELLS = 1 shl 25;
var
  I, J, K, bx0, bx1, bz0, bz1, bx, bz, GW, GH, ci: Integer;
  MinX, MinZ, MaxX, MaxZ: Int32;
  ClMinX, ClMaxX, ClMinZ, ClMaxZ: Int32;
  Buckets: array of array of Integer;
  BN: array of Integer;
  Seen: array of Integer;             { сег -> последний обработанный сосед }
  A, B: TLatticePoint;
  P, Q: TLatticePoint;
  kind: TLatIntersectKind;
  lx, lz: Int32;
  t, dAB: Int64;

  procedure BucketRange(const S: TLatticeSeg;
    out ax0, ax1, az0, az1: Integer);
  var t0, t1: Int64;
  begin
    { Int64-математика: разность Int32-координат мусорной точки с охватом
      может переполнить Int32 (обернувшись в противоположный край) }
    t0 := (Int64(Min(S.A.X, S.B.X)) - MinX) div BUCKET;
    t1 := (Int64(Max(S.A.X, S.B.X)) - MinX) div BUCKET;
    if t0 < 0 then t0 := 0 else if t0 >= GW then t0 := GW - 1;
    if t1 < 0 then t1 := 0 else if t1 >= GW then t1 := GW - 1;
    ax0 := t0; ax1 := t1;
    t0 := (Int64(Min(S.A.Z, S.B.Z)) - MinZ) div BUCKET;
    t1 := (Int64(Max(S.A.Z, S.B.Z)) - MinZ) div BUCKET;
    if t0 < 0 then t0 := 0 else if t0 >= GH then t0 := GH - 1;
    if t1 < 0 then t1 := 0 else if t1 >= GH then t1 := GH - 1;
    az0 := t0; az1 := t1;
  end;

  { Отсортировать цепочку сегмента вдоль него и выкинуть дубли. Ключ —
    целочисленная проекция (P-A)·(B-A): монотонна вдоль отрезка, точна. }
  procedure FinalizeChain(SegIdx: Integer);
  var
    Cuts: TLatticePointArray;
    Keys: array of Int64;
    n, a2, b2, m: Integer;
    tk: Int64;
    tp: TLatticePoint;
    SA, SB: TLatticePoint;
  begin
    SA := FSegs[SegIdx].A;
    SB := FSegs[SegIdx].B;
    Cuts := FCuts[SegIdx];
    n := FCutN[SegIdx];
    SetLength(Keys, n);
    for a2 := 0 to n - 1 do
      Keys[a2] := Int64(Cuts[a2].X - SA.X) * Int64(SB.X - SA.X)
                + Int64(Cuts[a2].Z - SA.Z) * Int64(SB.Z - SA.Z);
    { вставками: врезок на сегмент обычно единицы }
    for a2 := 1 to n - 1 do
    begin
      tk := Keys[a2]; tp := Cuts[a2];
      b2 := a2 - 1;
      while (b2 >= 0) and (Keys[b2] > tk) do
      begin
        Keys[b2+1] := Keys[b2]; Cuts[b2+1] := Cuts[b2];
        Dec(b2);
      end;
      Keys[b2+1] := tk; Cuts[b2+1] := tp;
    end;
    { цепочка: A + врезки (без дублей и без концов) + B }
    SetLength(FChains[SegIdx], n + 2);
    FChains[SegIdx][0] := SA;
    m := 1;
    for a2 := 0 to n - 1 do
      if (not LatSame(Cuts[a2], SA)) and (not LatSame(Cuts[a2], SB))
         and ((m = 1) or (not LatSame(Cuts[a2], FChains[SegIdx][m-1]))) then
      begin
        FChains[SegIdx][m] := Cuts[a2];
        Inc(m);
      end;
    FChains[SegIdx][m] := SB;
    SetLength(FChains[SegIdx], m + 1);
  end;

  procedure SortBorder(var Arr: TLatticePointArray; ByZ: Boolean);
  var m, a2: Integer;
    function KeyOf(const P: TLatticePoint): Int64; inline;
    begin
      { первичный ключ вдоль линии, вторичный — поперёк (полная детерминированность) }
      if ByZ then Result := (Int64(P.Z) shl 32) or Int64(Cardinal(P.X))
      else Result := (Int64(P.X) shl 32) or Int64(Cardinal(P.Z));
    end;
    procedure QS(L, R2: Integer);
    var i2, j2: Integer; pk: Int64; tp: TLatticePoint;
    begin
      while L < R2 do
      begin
        i2 := L; j2 := R2;
        pk := KeyOf(Arr[(L + R2) div 2]);
        repeat
          while KeyOf(Arr[i2]) < pk do Inc(i2);
          while KeyOf(Arr[j2]) > pk do Dec(j2);
          if i2 <= j2 then
          begin
            tp := Arr[i2]; Arr[i2] := Arr[j2]; Arr[j2] := tp;
            Inc(i2); Dec(j2);
          end;
        until i2 > j2;
        if j2 - L < R2 - i2 then
        begin
          QS(L, j2);
          L := i2;
        end
        else
        begin
          QS(i2, R2);
          R2 := j2;
        end;
      end;
    end;
  begin
    if Length(Arr) > 1 then QS(0, High(Arr));
    { дедуп }
    m := 0;
    for a2 := 0 to High(Arr) do
      if (m = 0) or (not LatSame(Arr[a2], Arr[m-1])) then
      begin
        Arr[m] := Arr[a2];
        Inc(m);
      end;
    SetLength(Arr, m);
  end;

begin
  if FNoded then Exit;
  FNoded := True;
  SetLength(FSegs, FSegN);
  SetLength(FLinesX, FLineXN);
  SetLength(FLinesZ, FLineZN);
  SetLength(FCuts, FSegN);
  SetLength(FCutN, FSegN);
  SetLength(FChains, FSegN);
  SetLength(FBorderX, FLineXN);
  SetLength(FBorderZ, FLineZN);
  SetLength(FBorderXN, FLineXN);
  SetLength(FBorderZN, FLineZN);
  if FSegN = 0 then Exit;

  { bbox + бакеты }
  MinX := High(Int32); MinZ := High(Int32);
  MaxX := Low(Int32);  MaxZ := Low(Int32);
  for I := 0 to FSegN - 1 do
  begin
    MinX := Min(MinX, Min(FSegs[I].A.X, FSegs[I].B.X));
    MaxX := Max(MaxX, Max(FSegs[I].A.X, FSegs[I].B.X));
    MinZ := Min(MinZ, Min(FSegs[I].A.Z, FSegs[I].B.Z));
    MaxZ := Max(MaxZ, Max(FSegs[I].A.Z, FSegs[I].B.Z));
  end;
  GW := (MaxX - MinX) div BUCKET + 1;
  GH := (MaxZ - MinZ) div BUCKET + 1;
  { Страховка от мусорной точки: бакеты — O(GW*GH) памяти, одна точка за
    сотни км от чанка взрывает SetLength (OOM в воркере = смерть процесса,
    21.07.26: блок 4952/2562, запрос 160 ГБ). Если решётка бакетов
    неразумно велика, сжимаем её охват до линий сетки чанка ± бакет:
    дальние сегменты дожимаются BucketRange в краевые бакеты — их взаимные
    пересечения, доходящие до чанка, по-прежнему находятся, а пересечения
    далеко за чанком на ячейки чанка не влияют. }
  if (Int64(GW) * Int64(GH) > MAX_BUCKET_CELLS)
     and (FLineXN > 0) and (FLineZN > 0) then
  begin
    ClMinX := FLinesX[0]; ClMaxX := FLinesX[0];
    for I := 1 to FLineXN - 1 do
    begin
      if FLinesX[I] < ClMinX then ClMinX := FLinesX[I];
      if FLinesX[I] > ClMaxX then ClMaxX := FLinesX[I];
    end;
    ClMinZ := FLinesZ[0]; ClMaxZ := FLinesZ[0];
    for I := 1 to FLineZN - 1 do
    begin
      if FLinesZ[I] < ClMinZ then ClMinZ := FLinesZ[I];
      if FLinesZ[I] > ClMaxZ then ClMaxZ := FLinesZ[I];
    end;
    ClampNote := Format(
      'noder: безумный bbox сегментов (%d..%d x %d..%d, %d сегм) — ' +
      'бакеты сжаты к сетке (%d..%d x %d..%d); среди сегментов мусорная точка',
      [MinX, MaxX, MinZ, MaxZ, FSegN, ClMinX, ClMaxX, ClMinZ, ClMaxZ]);
    ClMinX := ClMinX - BUCKET; ClMaxX := ClMaxX + BUCKET;
    ClMinZ := ClMinZ - BUCKET; ClMaxZ := ClMaxZ + BUCKET;
    if MinX < ClMinX then MinX := ClMinX;
    if MaxX > ClMaxX then MaxX := ClMaxX;
    if MinZ < ClMinZ then MinZ := ClMinZ;
    if MaxZ > ClMaxZ then MaxZ := ClMaxZ;
    GW := (MaxX - MinX) div BUCKET + 1;
    GH := (MaxZ - MinZ) div BUCKET + 1;
  end;
  SetLength(Buckets, GW * GH);
  SetLength(BN, GW * GH);
  for I := 0 to FSegN - 1 do
  begin
    BucketRange(FSegs[I], bx0, bx1, bz0, bz1);
    for bz := bz0 to bz1 do
      for bx := bx0 to bx1 do
      begin
        ci := bz * GW + bx;
        if BN[ci] >= Length(Buckets[ci]) then
          SetLength(Buckets[ci], BN[ci] * 2 + 4);
        Buckets[ci][BN[ci]] := I;
        Inc(BN[ci]);
      end;
  end;

  { сегмент × сегмент }
  SetLength(Seen, FSegN);
  for I := 0 to FSegN - 1 do Seen[I] := -1;
  for I := 0 to FSegN - 1 do
  begin
    BucketRange(FSegs[I], bx0, bx1, bz0, bz1);
    for bz := bz0 to bz1 do
      for bx := bx0 to bx1 do
      begin
        ci := bz * GW + bx;
        for K := 0 to BN[ci] - 1 do
        begin
          J := Buckets[ci][K];
          if J <= I then Continue;
          if Seen[J] = I then Continue;   { пара уже обработана в другом бакете }
          Seen[J] := I;
          kind := LatSegIntersect(FSegs[I].A, FSegs[I].B,
                                  FSegs[J].A, FSegs[J].B, P, Q);
          case kind of
            lirPoint:
              begin
                PushCut(I, P);
                PushCut(J, P);
              end;
            lirOverlap:
              begin
                { общая подцепочка [P,Q] — оба получают ОБА конца }
                PushCut(I, P); PushCut(I, Q);
                PushCut(J, P); PushCut(J, Q);
              end;
          end;
        end;
      end;
  end;

  { сегмент × линии сетки. Линия — решёточная координата, пересечение
    точное: t = (lx - A.X) / (B.X - A.X), Z = A.Z + t*(B.Z - A.Z).
    Линии ОТСОРТИРОВАНЫ вызывающим по возрастанию (границы ячеек чанка);
    диапазон линий в охвате сегмента берётся бинпоиском — иначе на
    реальном чанке (сотни тысяч сегментов x ~тысяча линий) полный перебор
    стоит сотни миллионов холостых итераций. }
  for I := 0 to FSegN - 1 do
  begin
    A := FSegs[I].A; B := FSegs[I].B;
    for J := LatLowerBound(FLinesX, FLineXN, Min(A.X, B.X))
         to LatUpperBound(FLinesX, FLineXN, Max(A.X, B.X)) do
    begin
      lx := FLinesX[J];
      dAB := Int64(B.X) - Int64(A.X);
      if dAB = 0 then
      begin
        { сегмент лежит НА линии: оба конца — валюта линии. Наклонные
          соседи кладут только КРАЯ пробега; внутренние стыки
          вдоль-линейных сегментов между собой без этого в таблицу не
          попадают, и смежная ячейка не подразбивает свой периметр в них
          (T-стык на касании кольца с линией сетки). Резать сегмент
          нечем — концы уже его вершины. }
        if A.X = lx then
        begin
          PushBorderX(J, A);
          PushBorderX(J, B);
        end;
        Continue;
      end;
      t := Int64(lx) - Int64(A.X);
      P.X := lx;
      P.Z := Int32(DivRoundNearest(Int64(A.Z) * dAB + (Int64(B.Z) - Int64(A.Z)) * t, dAB));
      PushCut(I, P);
      PushBorderX(J, P);
    end;
    for J := LatLowerBound(FLinesZ, FLineZN, Min(A.Z, B.Z))
         to LatUpperBound(FLinesZ, FLineZN, Max(A.Z, B.Z)) do
    begin
      lz := FLinesZ[J];
      dAB := Int64(B.Z) - Int64(A.Z);
      if dAB = 0 then
      begin
        if A.Z = lz then
        begin
          PushBorderZ(J, A);
          PushBorderZ(J, B);
        end;
        Continue;
      end;
      t := Int64(lz) - Int64(A.Z);
      P.Z := lz;
      P.X := Int32(DivRoundNearest(Int64(A.X) * dAB + (Int64(B.X) - Int64(A.X)) * t, dAB));
      PushCut(I, P);
      PushBorderZ(J, P);
    end;
  end;

  { финализация }
  for I := 0 to FSegN - 1 do
    FinalizeChain(I);
  for J := 0 to FLineXN - 1 do
  begin
    SetLength(FBorderX[J], FBorderXN[J]);
    SortBorder(FBorderX[J], True);
  end;
  for J := 0 to FLineZN - 1 do
  begin
    SetLength(FBorderZ[J], FBorderZN[J]);
    SortBorder(FBorderZ[J], False);
  end;
end;

function TLatticeNoder.SegCount: Integer;
begin
  Result := FSegN;
end;

function TLatticeNoder.SegOf(I: Integer): TLatticeSeg;
begin
  Result := FSegs[I];
end;

function TLatticeNoder.ChainOf(I: Integer): TLatticePointArray;
begin
  if not FNoded then
    raise Exception.Create('TLatticeNoder: ChainOf before Node');
  Result := FChains[I];
end;

function TLatticeNoder.LineXCount: Integer;
begin
  Result := FLineXN;
end;

function TLatticeNoder.LineZCount: Integer;
begin
  Result := FLineZN;
end;

function TLatticeNoder.BorderCutsX(LineIdx: Integer): TLatticePointArray;
begin
  if not FNoded then
    raise Exception.Create('TLatticeNoder: BorderCutsX before Node');
  Result := FBorderX[LineIdx];
end;

function TLatticeNoder.BorderCutsZ(LineIdx: Integer): TLatticePointArray;
begin
  if not FNoded then
    raise Exception.Create('TLatticeNoder: BorderCutsZ before Node');
  Result := FBorderZ[LineIdx];
end;

{ ─────────────────────── TLatticeVertexDict ─────────────────────── }

const
  NOKEY = Int64($8000000000000000);   { недостижимый пак: X=Low(Int32), Z=0 —
                                        реальные координаты чанка на порядки
                                        меньше по модулю }

function PackPoint(const P: TLatticePoint): Int64; inline;
begin
  Result := (Int64(P.X) shl 32) or Int64(Cardinal(P.Z));
end;

{ Фибоначчи-хеш: умножение НАМЕРЕННО переполняется (mixing по модулю 2^64).
  Локально отключаем overflow/range-проверки — иначе в билде с {$Q+}/{$R+} падает
  FPC_OVERFLOW при больших ключах (например, когда блок далеко от origin — нет
  FIT-пути / нулевой центр — и lattice-координаты огромны). }
function LatFibHash(K: Int64; ACap: Integer): Integer; inline;
begin
  {$push}{$Q-}{$R-}
  Result := Integer((QWord(K) * QWord($9E3779B97F4A7C15))
                    shr (64 - BsrQWord(QWord(ACap))));
  {$pop}
end;

constructor TLatticeVertexDict.Create;
var I: Integer;
begin
  inherited Create;
  FCap := 1024;
  SetLength(FKeys, FCap);
  SetLength(FVals, FCap);
  for I := 0 to FCap - 1 do FKeys[I] := NOKEY;
end;

procedure TLatticeVertexDict.Grow;
var
  OldKeys: array of Int64;
  OldVals: array of Integer;
  I, h: Integer;
begin
  OldKeys := FKeys; OldVals := FVals;
  FCap := FCap * 2;
  FKeys := nil; FVals := nil;
  SetLength(FKeys, FCap);
  SetLength(FVals, FCap);
  for I := 0 to FCap - 1 do FKeys[I] := NOKEY;
  for I := 0 to High(OldKeys) do
    if OldKeys[I] <> NOKEY then
    begin
      h := LatFibHash(OldKeys[I], FCap);
      while FKeys[h] <> NOKEY do h := (h + 1) and (FCap - 1);
      FKeys[h] := OldKeys[I];
      FVals[h] := OldVals[I];
    end;
end;

function TLatticeVertexDict.IndexOf(const P: TLatticePoint): Integer;
var
  kk: Int64;
  h: Integer;
begin
  if FCount * 2 >= FCap then Grow;
  kk := PackPoint(P);
  h := LatFibHash(kk, FCap);
  while FKeys[h] <> NOKEY do
  begin
    if FKeys[h] = kk then Exit(FVals[h]);
    h := (h + 1) and (FCap - 1);
  end;
  FKeys[h] := kk;
  FVals[h] := FCount;
  if FCount >= Length(FPts) then SetLength(FPts, FCount * 2 + 256);
  FPts[FCount] := P;
  Result := FCount;
  Inc(FCount);
end;

function TLatticeVertexDict.TryIndexOf(const P: TLatticePoint;
  out Idx: Integer): Boolean;
var
  kk: Int64;
  h: Integer;
begin
  Idx := -1;
  if FCount = 0 then Exit(False);
  kk := PackPoint(P);
  h := LatFibHash(kk, FCap);
  while FKeys[h] <> NOKEY do
  begin
    if FKeys[h] = kk then begin Idx := FVals[h]; Exit(True); end;
    h := (h + 1) and (FCap - 1);
  end;
  Result := False;
end;

function TLatticeVertexDict.Count: Integer;
begin
  Result := FCount;
end;

function TLatticeVertexDict.PointOf(I: Integer): TLatticePoint;
begin
  Result := FPts[I];
end;

end.
