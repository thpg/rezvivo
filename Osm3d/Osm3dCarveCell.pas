unit Osm3dCarveCell;

{ Целочисленный клип одной ячейки карва (этап 2 переделки, см.
  carve-watertight-redesign.md). Работает ПОВЕРХ Osm3dCarveLattice: все
  входы — пре-нодированные решёточные цепочки, у которых пересечения друг
  с другом и с линиями клеточной сетки уже вставлены нодером.

  Идея: раз новые пересечения запрещены по построению, «клип» вырождается
  в три операции над триангуляцией ячейки —
    1) стартовая триангуляция прямоугольника ячейки, периметр которой
       заранее подразбит КАНОНИЧЕСКИМИ точками из border-таблиц нодера
       (обе соседние ячейки получают тождественные точки на общей стороне,
       независимо от того, чьи полигоны их породили);
    2) вставка цепочек item'ов как ОГРАНИЧЕНИЙ (constraint edges): вершина
       -> InsertPoint (на ребре — сплит смежных, внутри — фан), ребро ->
       вырезка коридора пересекаемых треугольников и ear-заполнение двух
       полостей вдоль ребра;
    3) классификация треугольников по item'ам в порядке убывания ZIndex
       (целочисленный winding по утроенному центроиду) — «peel»: верхний
       слой забирает свои треугольники, остаток достаётся нижним и в конце
       терраину.

  Про инвариант честно: вставка constraint-ребра МОЖЕТ породить точку —
  пересечение с ребром уже вставленного ограничения этой же ячейки
  (цепочка A × цепочка B, чьё округлённое нодером пересечение легло рядом,
  или цепочка × приватная диагональ). Такие точки ПРИВАТНЫ ячейке: они
  строго внутри неё (на границе всё канонично по построению) и обе местные
  стороны разреза получают ОДНУ округлённую точку. Сшивка между ячейками и
  слоями от них не зависит — инвариант «общих цепочек» держится.

  Юнит без CGE-зависимостей; структуры рассчитаны на сотни–тысячи
  треугольников на ячейку (линейные поиски с AABB-прунингом; оптимизация
  локатора — по профилю, не заранее). }

{$mode objfpc}{$H+}

interface

uses
  Osm3dCarveLattice;

type
  TLatRing = TLatticePointArray;          { замкнутое кольцо, без повторения
                                            первой точки в конце }

  TCarveItem = record
    Rings:  array of TLatRing;            { внешние CCW, дыры CW; классификация
                                            winding'ом — дыры бесплатны }
    { Вклад колец слоя, ЦЕЛИКОМ накрывающих ячейку без захода (blanket):
      +1 за каждое CCW-наружное, -1 за каждую CW-дыру. Вызывающий считает
      его parity-сканом; peel прибавляет к winding суб-колец. }
    BaseWinding: Integer;
    MatId:  Integer;
    ZIndex: Integer;
    Tag:    Int64;                        { OsmId и т.п. — сквозной }
  end;
  TCarveItemArray = array of TCarveItem;

  TCarveTri = record
    A, B, C: TLatticePoint;
    MatId:   Integer;
    Tag:     Int64;
  end;
  TCarveTriArray = array of TCarveTri;

{ Клип ячейки. AMinX..AMaxZ — решёточные границы; ABorderW/E — канонические
  точки на западной/восточной сторонах (только Z в диапазоне, отсортированы
  нодером); ABorderN/S — на северной/южной (по X). AItems — item'ы, чьи
  цепочки пре-нодированы; кольца передаются ЦЕЛИКОМ (не обрезанные по
  ячейке) — winding-классификации нужен весь контур, а ограничениями
  вставляются только звенья, пересекающие ячейку. ATerrainMat/ATerrainTag —
  материал остатка. Выход — треугольники ячейки: покрытие точное
  (целочисленная сумма удвоенных площадей == удвоенной площади ячейки). }
function CarveCell(AMinX, AMinZ, AMaxX, AMaxZ: Int32;
  const ABorderW, ABorderE, ABorderN, ABorderS: TLatticePointArray;
  const AItems: TCarveItemArray; AItemN: Integer;
  ATerrainMat: Integer; ATerrainTag: Int64): TCarveTriArray;

{ Удвоенная ориентированная площадь треугольника (целая, точная). }
function Tri2Area(const A, B, C: TLatticePoint): Int64;

{ Winding number точки с УТРОЕННЫМИ координатами (3*Px, 3*Pz) относительно
  кольца в обычных решёточных координатах: позволяет классифицировать
  центроид треугольника без деления и без выхода из целых. }
function WindingAt3(P3X, P3Z: Int64; const Ring: TLatRing): Integer;

implementation

uses
  SysUtils, Math;

function Tri2Area(const A, B, C: TLatticePoint): Int64;
begin
  Result := Int64(B.X - A.X) * Int64(C.Z - A.Z)
          - Int64(B.Z - A.Z) * Int64(C.X - A.X);
end;

function WindingAt3(P3X, P3Z: Int64; const Ring: TLatRing): Integer;
var
  I, J, N: Integer;
  AX3, AZ3, BX3, BZ3, cr: Int64;
begin
  { Классика winding number; все сравнения — против утроенных координат
    кольца (умножение на 3 в Int64), пересечения с горизонталью через
    знаки ориентации — точно. Точка НА ребре кольцу не встречается: центроид
    невырожденного треугольника, все вершины которого лежат по одну сторону
    или на ребре, на само ребро не попадает (сумма трёх коллинеарных точек
    коллинеарна — этот случай классифицируется соседним кольцом/слоем и
    для peel безразличен: вырожденных треугольников триангуляция не держит). }
  Result := 0;
  N := Length(Ring);
  if N < 3 then Exit;
  J := N - 1;
  for I := 0 to N - 1 do
  begin
    AX3 := Int64(Ring[J].X) * 3; AZ3 := Int64(Ring[J].Z) * 3;
    BX3 := Int64(Ring[I].X) * 3; BZ3 := Int64(Ring[I].Z) * 3;
    if AZ3 <= P3Z then
    begin
      if BZ3 > P3Z then
      begin
        cr := (BX3 - AX3) * (P3Z - AZ3) - (P3X - AX3) * (BZ3 - AZ3);
        if cr > 0 then Inc(Result);
      end;
    end
    else
    begin
      if BZ3 <= P3Z then
      begin
        cr := (BX3 - AX3) * (P3Z - AZ3) - (P3X - AX3) * (BZ3 - AZ3);
        if cr < 0 then Dec(Result);
      end;
    end;
    J := I;
  end;
end;

{ ───────────── внутренняя триангуляция ячейки ───────────── }

type
  TTri = record
    V: array[0..2] of Integer;   { индексы вершин }
    Alive: Boolean;
  end;

  TCellTriangulation = record
    Pts:  TLatticePointArray;
    PtN:  Integer;
    Tris: array of TTri;
    TriN: Integer;
  end;

procedure InitT(var T: TCellTriangulation);
begin
  T.Pts := nil; T.PtN := 0;
  T.Tris := nil; T.TriN := 0;
end;

function AddPt(var T: TCellTriangulation; const P: TLatticePoint): Integer;
var I: Integer;
begin
  for I := 0 to T.PtN - 1 do
    if LatSame(T.Pts[I], P) then Exit(I);
  if T.PtN >= Length(T.Pts) then SetLength(T.Pts, T.PtN * 2 + 32);
  T.Pts[T.PtN] := P;
  Result := T.PtN;
  Inc(T.PtN);
end;

procedure AddTri(var T: TCellTriangulation; A, B, C: Integer);
var a2: Int64;
begin
  a2 := Tri2Area(T.Pts[A], T.Pts[B], T.Pts[C]);
  if a2 <= 0 then Exit;   { деген и CW не держим; вызывающие подают CCW }
  if T.TriN >= Length(T.Tris) then SetLength(T.Tris, T.TriN * 2 + 32);
  T.Tris[T.TriN].V[0] := A;
  T.Tris[T.TriN].V[1] := B;
  T.Tris[T.TriN].V[2] := C;
  T.Tris[T.TriN].Alive := True;
  Inc(T.TriN);
end;

procedure AddTriCCW(var T: TCellTriangulation; A, B, C: Integer);
var a2: Int64;
begin
  a2 := Tri2Area(T.Pts[A], T.Pts[B], T.Pts[C]);
  if a2 = 0 then Exit;
  if a2 < 0 then AddTri(T, A, C, B) else AddTri(T, A, B, C);
end;

{ Точка на ребре (строго между концами)? }
function OnEdgeStrict(const P, A, B: TLatticePoint): Boolean;
begin
  Result := (not LatSame(P, A)) and (not LatSame(P, B))
        and LatOnSegment(P, A, B);
end;

{ Вставка точки: вершина -> индекс; на ребре -> сплит ВСЕХ живых
  треугольников, несущих это ребро (обычно двух); внутри -> фан 1->3.
  Точки вне триангуляции игнорируются (кольца передаются целиком, их
  дальние вершины ячейке не нужны). Возвращает индекс или -1. }
function InsertPoint(var T: TCellTriangulation;
  const P: TLatticePoint): Integer;
var
  I, K, pi, va, vb, vc: Integer;
  s0, s1, s2: Int64;
  hit: Boolean;
begin
  Result := -1;
  { уже вершина? }
  for I := 0 to T.PtN - 1 do
    if LatSame(T.Pts[I], P) then Exit(I);

  pi := -1;
  { на ребре какого-то живого треугольника? — сплитим все смежные }
  hit := False;
  for I := T.TriN - 1 downto 0 do
  begin
    if not T.Tris[I].Alive then Continue;
    va := T.Tris[I].V[0]; vb := T.Tris[I].V[1]; vc := T.Tris[I].V[2];
    for K := 0 to 2 do
    begin
      case K of
        0: if not OnEdgeStrict(P, T.Pts[va], T.Pts[vb]) then Continue;
        1: if not OnEdgeStrict(P, T.Pts[vb], T.Pts[vc]) then Continue;
        2: if not OnEdgeStrict(P, T.Pts[vc], T.Pts[va]) then Continue;
      end;
      if pi < 0 then pi := AddPt(T, P);
      T.Tris[I].Alive := False;
      case K of
        0: begin AddTriCCW(T, va, pi, vc); AddTriCCW(T, pi, vb, vc); end;
        1: begin AddTriCCW(T, vb, pi, va); AddTriCCW(T, pi, vc, va); end;
        2: begin AddTriCCW(T, vc, pi, vb); AddTriCCW(T, pi, va, vb); end;
      end;
      hit := True;
      Break;
    end;
  end;
  if hit then Exit(pi);

  { строго внутри какого-то треугольника? — фан }
  for I := 0 to T.TriN - 1 do
  begin
    if not T.Tris[I].Alive then Continue;
    va := T.Tris[I].V[0]; vb := T.Tris[I].V[1]; vc := T.Tris[I].V[2];
    s0 := LatCross(T.Pts[va], T.Pts[vb], P);
    s1 := LatCross(T.Pts[vb], T.Pts[vc], P);
    s2 := LatCross(T.Pts[vc], T.Pts[va], P);
    if (s0 > 0) and (s1 > 0) and (s2 > 0) then
    begin
      pi := AddPt(T, P);
      T.Tris[I].Alive := False;
      AddTriCCW(T, va, vb, pi);
      AddTriCCW(T, vb, vc, pi);
      AddTriCCW(T, vc, va, pi);
      Exit(pi);
    end;
  end;
end;


{ Принудительный сплит ребра (VA,VB) точкой около P. Носители ребра
  (двое внутри, один на периметре) заменяются фаном из точки Pk — первого
  кандидата из списка «P и 4 соседних узла», лежащего СТРОГО ВНУТРИ
  области носителей (квада a-R-b-L при двух, треугольника при одном).
  Для такого Pk все дети CCW автоматически (фан из внутренней точки),
  вставка идёт БЕЗ авто-переворота. Ни один кандидат не внутри
  (ультра-тонкий каскадный клин тоньше юнита) — сплит честно отклоняется
  (-1): вызывающий пропустит пересечение, ограничение локально
  аппроксимируется существующим путём с утечкой < 1 юнита (~1.6 см);
  точность ПОКРЫТИЯ важнее точности линии. }
function SplitEdgeAt(var T: TCellTriangulation; VA, VB: Integer;
  const P: TLatticePoint): Integer;
var
  CarL, CarR, I, K, vc, ci, pi: Integer;
  A, B, Cand: TLatticePoint;
  cr: Int64;
  ins: Boolean;
begin
  Result := -1;
  A := T.Pts[VA]; B := T.Pts[VB];
  CarL := -1; CarR := -1;
  for I := 0 to T.TriN - 1 do
  begin
    if not T.Tris[I].Alive then Continue;
    vc := -1;
    for K := 0 to 2 do
      if ((T.Tris[I].V[K] = VA) and (T.Tris[I].V[(K+1) mod 3] = VB)) or
         ((T.Tris[I].V[K] = VB) and (T.Tris[I].V[(K+1) mod 3] = VA)) then
        vc := T.Tris[I].V[(K+2) mod 3];
    if vc < 0 then Continue;
    cr := LatCross(A, B, T.Pts[vc]);
    if cr > 0 then
    begin
      if CarL >= 0 then Exit;            { немногообразность — не трогаем }
      CarL := I;
    end
    else if cr < 0 then
    begin
      if CarR >= 0 then Exit;
      CarR := I;
    end
    else
      Exit;                              { деген-носитель }
  end;
  if (CarL < 0) and (CarR < 0) then Exit;

  for ci := 0 to 4 do
  begin
    Cand := P;
    case ci of
      1: Dec(Cand.X);
      2: Inc(Cand.X);
      3: Dec(Cand.Z);
      4: Inc(Cand.Z);
    end;
    if LatSame(Cand, A) or LatSame(Cand, B) then Continue;
    { строго внутри области носителей: против часовой a -> R -> b -> L }
    ins := True;
    if CarR >= 0 then
    begin
      vc := 0;
      for K := 0 to 2 do
        if (T.Tris[CarR].V[K] <> VA) and (T.Tris[CarR].V[K] <> VB) then
          vc := T.Tris[CarR].V[K];
      if (Tri2Area(A, T.Pts[vc], Cand) <= 0) or
         (Tri2Area(T.Pts[vc], B, Cand) <= 0) then ins := False;
    end
    else
      if Tri2Area(A, B, Cand) >= 0 then ins := False;   { нет R: не левее ребра }
    if ins and (CarL >= 0) then
    begin
      vc := 0;
      for K := 0 to 2 do
        if (T.Tris[CarL].V[K] <> VA) and (T.Tris[CarL].V[K] <> VB) then
          vc := T.Tris[CarL].V[K];
      if (Tri2Area(B, T.Pts[vc], Cand) <= 0) or
         (Tri2Area(T.Pts[vc], A, Cand) <= 0) then ins := False;
    end
    else if ins and (CarL < 0) then
      if Tri2Area(A, B, Cand) <= 0 then ins := False;   { нет L: не правее }
    if not ins then Continue;

    pi := AddPt(T, Cand);
    if CarL >= 0 then
    begin
      vc := 0;
      for K := 0 to 2 do
        if (T.Tris[CarL].V[K] <> VA) and (T.Tris[CarL].V[K] <> VB) then
          vc := T.Tris[CarL].V[K];
      T.Tris[CarL].Alive := False;
      AddTri(T, VA, pi, vc);             { CCW по построению (Pk внутри) }
      AddTri(T, pi, VB, vc);
    end;
    if CarR >= 0 then
    begin
      vc := 0;
      for K := 0 to 2 do
        if (T.Tris[CarR].V[K] <> VA) and (T.Tris[CarR].V[K] <> VB) then
          vc := T.Tris[CarR].V[K];
      T.Tris[CarR].Alive := False;
      AddTri(T, VB, pi, vc);
      AddTri(T, pi, VA, vc);
    end;
    Exit(pi);
  end;
end;

{ Вставка ограничения-ребра между СУЩЕСТВУЮЩИМИ вершинами PA..PB.

  ФИКС «дротиков». Прежняя стратегия «Штейнер-точка в каждом пересечении»
  каскадила на почти параллельных диагоналях стартового веера: два
  пересечения в 1–3 юнитах друг от друга -> у второго сплита носитель —
  ультратонкий клин, все кандидаты SplitEdgeAt проваливают строгий
  inside-тест -> -1 -> Continue -> цикл кончается, и ОСТАТОК ограничения
  (метры!) молча выбрасывался. Треугольники продолжали пересекать
  истинную границу, peel красил их по центроиду -> «пила»/парные клинья
  на кромках лент через каждый ряд ячеек.

  Новая стратегия — классическая CDT-вставка полостью:
    (1) ребро уже есть — ноп;
    (2) вершина на/почти на [A,B] (перп. дистанция <= FUZZ юнитов, проекция
        строго внутри) — рекурсия по половинам через неё (ограничение
        изгибается <= ~3 см — в допуске дизайна, каскад гасится в зачатке);
    (3) собрать ВСЕ живые треугольники, чьи рёбра строго пересекают (A,B)
        (целочисленный straddle-тест, без округлений), убить их и ушить обе
        полости ear-clip'ом; ребро PA-PB возникает как общая граница полостей.
  Штейнер-точек нет вовсе: вершины ячейки не прибавляются, стороны
  (границы с соседями) не трогаются — инвариант сшивки сохранён. }
procedure InsertEdge(var T: TCellTriangulation; PA, PB: Integer;
  ADepth: Integer = 0);
const
  FUZZ2 = 4;                       { перп. дистанция <= 2 юнитов: cr^2 <= 4*len2 }
var
  I, K, va, vb, bestV, cn, bn, wn, guard: Integer;
  A, B: TLatticePoint;
  d1, d2, d3, d4, cr, dt, len2, bestCr, lav2, lvb2: Int64;
  Crossed: array of Integer;       { индексы убиваемых треугольников }
  BFrom, BTo: array of Integer;    { направленные граничные рёбра полости }
  Poly: array of Integer;          { текущая полость (цикл вершин) }

  function HasEdge(X, Y: Integer): Boolean;
  var q: Integer;
  begin
    Result := False;
    for q := 0 to T.TriN - 1 do
      if T.Tris[q].Alive then
        with T.Tris[q] do
          if ((V[0]=X)and(V[1]=Y)) or ((V[1]=X)and(V[2]=Y)) or ((V[2]=X)and(V[0]=Y)) or
             ((V[0]=Y)and(V[1]=X)) or ((V[1]=Y)and(V[2]=X)) or ((V[2]=Y)and(V[0]=X)) then
            Exit(True);
  end;

  { направленное ребро (X->Y) есть среди рёбер убиваемого набора? }
  function CrossedHasDir(X, Y: Integer): Boolean;
  var q, k2: Integer;
  begin
    Result := False;
    for q := 0 to cn - 1 do
      with T.Tris[Crossed[q]] do
        for k2 := 0 to 2 do
          if (V[k2] = X) and (V[(k2+1) mod 3] = Y) then Exit(True);
  end;

  { ушить полость: Poly[0..wn-1] — простой CCW-многоугольник (цикл).
    Ear-clip на целых предикатах; коллинеарная вершина отбрасывается
    без эмита; страховка от зацикливания — веер. }
  procedure StitchPoly;
  var
    n2, i2, j2, ip, inx: Integer;
    a2: Int64;
    ear, blocked: Boolean;
    Pa, Pb, Pc, Q: TLatticePoint;
  begin
    n2 := wn;
    guard := n2 * n2 + 8;
    while n2 > 3 do
    begin
      Dec(guard);
      ear := False;
      for i2 := 0 to n2 - 1 do
      begin
        ip := (i2 + n2 - 1) mod n2;
        inx := (i2 + 1) mod n2;
        Pa := T.Pts[Poly[ip]];
        Pb := T.Pts[Poly[i2]];
        Pc := T.Pts[Poly[inx]];
        a2 := Tri2Area(Pa, Pb, Pc);
        if a2 = 0 then
        begin
          { коллинеарная вершина — просто выпадает из цикла }
          for j2 := i2 to n2 - 2 do Poly[j2] := Poly[j2 + 1];
          Dec(n2);
          ear := True;
          Break;
        end;
        if a2 < 0 then Continue;   { рефлексная — не ухо }
        blocked := False;
        for j2 := 0 to n2 - 1 do
        begin
          if (j2 = ip) or (j2 = i2) or (j2 = inx) then Continue;
          Q := T.Pts[Poly[j2]];
          if (LatCross(Pa, Pb, Q) >= 0) and (LatCross(Pb, Pc, Q) >= 0)
             and (LatCross(Pc, Pa, Q) >= 0) then
          begin
            blocked := True;
            Break;
          end;
        end;
        if blocked then Continue;
        AddTri(T, Poly[ip], Poly[i2], Poly[inx]);
        for j2 := i2 to n2 - 2 do Poly[j2] := Poly[j2 + 1];
        Dec(n2);
        ear := True;
        Break;
      end;
      if (not ear) or (guard <= 0) then
      begin
        { простые полости сюда не попадают; страховка: веер, покрытие важнее }
        for j2 := 1 to n2 - 2 do
          AddTriCCW(T, Poly[0], Poly[j2], Poly[j2 + 1]);
        Exit;
      end;
    end;
    if n2 = 3 then
      AddTri(T, Poly[0], Poly[1], Poly[2]);
  end;

begin
  if ADepth > 64 then Exit;        { страховка: реальная геометрия глубже
                                     нескольких хопов не ходит }
  if PA = PB then Exit;
  if HasEdge(PA, PB) then Exit;
  A := T.Pts[PA]; B := T.Pts[PB];
  len2 := Int64(B.X - A.X) * (B.X - A.X) + Int64(B.Z - A.Z) * (B.Z - A.Z);
  if len2 = 0 then Exit;

  { (2) вершина на/почти на [A,B] (перп <= 2 юнитов, проекция строго
    внутри) — рекурсия по половинам через ближайшую к линии.
    ОБЯЗАТЕЛЬНОЕ УСЛОВИЕ ПРОГРЕССА: оба подотрезка строго короче целого,
    иначе два соседних border-ката (1-3 юнита друг от друга, джиттер
    квантования кромки у клеточной линии) с почти общей дальней вершиной
    маршрутизируют констрейнты друг через друга — взаимная рекурсия без
    убывания (стековзрыв). Строгое убывание len2 (Int64 >= 0) на обеих
    ветках гарантирует конечность; отбракованный вейпоинт уходит в
    полость, которая режет точно. }
  bestV := -1; bestCr := 0;
  for I := 0 to T.PtN - 1 do
  begin
    if (I = PA) or (I = PB) then Continue;
    cr := LatCross(A, B, T.Pts[I]);
    if cr < 0 then cr := -cr;
    if cr * cr > FUZZ2 * len2 then Continue;
    dt := Int64(T.Pts[I].X - A.X) * (B.X - A.X)
        + Int64(T.Pts[I].Z - A.Z) * (B.Z - A.Z);
    if (dt <= 0) or (dt >= len2) then Continue;
    lav2 := Int64(T.Pts[I].X - A.X) * (T.Pts[I].X - A.X)
          + Int64(T.Pts[I].Z - A.Z) * (T.Pts[I].Z - A.Z);
    lvb2 := Int64(B.X - T.Pts[I].X) * (B.X - T.Pts[I].X)
          + Int64(B.Z - T.Pts[I].Z) * (B.Z - T.Pts[I].Z);
    if (lav2 >= len2) or (lvb2 >= len2) then Continue;
    if (bestV < 0) or (cr < bestCr) then
    begin
      bestV := I;
      bestCr := cr;
    end;
  end;
  if bestV >= 0 then
  begin
    InsertEdge(T, PA, bestV, ADepth + 1);
    InsertEdge(T, bestV, PB, ADepth + 1);
    Exit;
  end;

  { (3) полость: все живые треугольники, чьи рёбра СТРОГО пересекают (A,B) }
  cn := 0;
  SetLength(Crossed, 8);
  for I := 0 to T.TriN - 1 do
  begin
    if not T.Tris[I].Alive then Continue;
    for K := 0 to 2 do
    begin
      va := T.Tris[I].V[K];
      vb := T.Tris[I].V[(K + 1) mod 3];
      d1 := LatCross(A, B, T.Pts[va]);
      d2 := LatCross(A, B, T.Pts[vb]);
      if (d1 = 0) or (d2 = 0) or ((d1 > 0) = (d2 > 0)) then Continue;
      d3 := LatCross(T.Pts[va], T.Pts[vb], A);
      d4 := LatCross(T.Pts[va], T.Pts[vb], B);
      if (d3 = 0) or (d4 = 0) or ((d3 > 0) = (d4 > 0)) then Continue;
      if cn >= Length(Crossed) then SetLength(Crossed, cn * 2 + 8);
      Crossed[cn] := I;
      Inc(cn);
      Break;
    end;
  end;
  if cn = 0 then Exit;   { пересечений нет: AB уже составлено из звеньев }

  { граница полости: направленные рёбра набора без обратной пары внутри }
  bn := 0;
  SetLength(BFrom, cn + 2); SetLength(BTo, cn + 2);
  for I := 0 to cn - 1 do
    for K := 0 to 2 do
    begin
      va := T.Tris[Crossed[I]].V[K];
      vb := T.Tris[Crossed[I]].V[(K + 1) mod 3];
      if CrossedHasDir(vb, va) then Continue;
      if bn >= Length(BFrom) then
      begin
        SetLength(BFrom, bn * 2 + 8);
        SetLength(BTo, bn * 2 + 8);
      end;
      BFrom[bn] := va; BTo[bn] := vb;
      Inc(bn);
    end;

  { pinch: какая-то from-вершина встречается на границе дважды — полость
    касается себя в вершине (веер дальнего узла подрезан констрейнтом с
    двух сторон); обход возьмёт не ту ветку, и ушивка даст перекрытие.
    Тихий выход БЕЗ изменений: ограничение локально аппроксимируется
    существующим путём (как при отказе старого SplitEdgeAt), но
    триангуляция не портится. В продакшен-геометрии лент не встречается
    (0/1000 в стрессе), только на экстремальных конфигурациях. }
  for I := 0 to bn - 1 do
    for K := I + 1 to bn - 1 do
      if BFrom[I] = BFrom[K] then Exit;

  { обход цикла границы: PA -> ... -> PB (полость 1), PB -> ... -> PA
    (полость 2); каждая замыкается ребром PB-PA / PA-PB. Любая
    несогласованность — тихий выход БЕЗ изменений (как раньше, но без
    порчи триангуляции). }
  SetLength(Poly, bn + 2);
  wn := 0;
  va := PA;
  guard := bn + 2;
  repeat
    Poly[wn] := va; Inc(wn);
    vb := -1;
    for I := 0 to bn - 1 do
      if BFrom[I] = va then begin vb := BTo[I]; Break; end;
    if vb < 0 then Exit;
    va := vb;
    Dec(guard);
  until (va = PB) or (guard <= 0);
  if va <> PB then Exit;
  Poly[wn] := PB; Inc(wn);
  { полость 1 готова (замыкание PB->PA — новое ребро-ограничение) —
    но сперва проверим обход второй половины, чтобы не убивать зря }
  I := wn;   { длина полости 1 }
  va := PB;
  guard := bn + 2;
  repeat
    vb := -1;
    for K := 0 to bn - 1 do
      if BFrom[K] = va then begin vb := BTo[K]; Break; end;
    if vb < 0 then Exit;
    va := vb;
    Dec(guard);
  until (va = PA) or (guard <= 0);
  if va <> PA then Exit;

  { всё связно — убиваем набор и шьём обе полости }
  for K := 0 to cn - 1 do
    T.Tris[Crossed[K]].Alive := False;
  StitchPoly;                       { полость 1: Poly[0..wn-1] }

  wn := 0;
  va := PB;
  guard := bn + 2;
  repeat
    Poly[wn] := va; Inc(wn);
    vb := -1;
    for K := 0 to bn - 1 do
      if BFrom[K] = va then begin vb := BTo[K]; Break; end;
    va := vb;
    Dec(guard);
  until (va = PA) or (guard <= 0);
  Poly[wn] := PA; Inc(wn);
  StitchPoly;                       { полость 2 }
end;


function CarveCell(AMinX, AMinZ, AMaxX, AMaxZ: Int32;
  const ABorderW, ABorderE, ABorderN, ABorderS: TLatticePointArray;
  const AItems: TCarveItemArray; AItemN: Integer;
  ATerrainMat: Integer; ATerrainTag: Int64): TCarveTriArray;
var
  T: TCellTriangulation;
  Perim: array of Integer;
  PN, I, J, K, RN2: Integer;
  PrevI, CurI: Integer;
  ResN: Integer;
  cx3, cz3: Int64;
  w, MatOf: Integer;
  TagOf: Int64;
  claimed: Boolean;

  procedure PushPerim(const Q: TLatticePoint);
  begin
    if (PN > 0) and LatSame(T.Pts[Perim[PN-1]], Q) then Exit;
    if PN >= Length(Perim) then SetLength(Perim, PN * 2 + 16);
    Perim[PN] := AddPt(T, Q);
    Inc(PN);
  end;
  function LP2(X, Z: Int32): TLatticePoint;
  begin
    Result.X := X; Result.Z := Z;
  end;

begin
  Result := nil;
  InitT(T);

  { 1. стартовая сетка: прямоугольник ячейки двумя треугольниками (фан от
       SW-угла), затем канонические border-точки вставляются штатным
       InsertPoint — точка ложится ровно на периметрическое ребро и
       сплитит его носителя. Фан от угла с точками В периметре не годится:
       точки на смежных углу сторонах коллинеарны ему, их треугольники
       вырождены и дропаются — точки повисали бы вне сетки (ловилось
       тестом сшивки: у соседа сторона подразбита, у нас нет). Порядок
       вставки детерминирован (таблицы нодера отсортированы) — обе соседки
       получают на общей стороне ОДНИ И ТЕ ЖЕ точки. }
  PN := 0;
  SetLength(Perim, 4);
  PushPerim(LP2(AMinX, AMinZ));
  PushPerim(LP2(AMaxX, AMinZ));
  PushPerim(LP2(AMaxX, AMaxZ));
  PushPerim(LP2(AMinX, AMaxZ));
  AddTriCCW(T, Perim[0], Perim[1], Perim[2]);
  AddTriCCW(T, Perim[0], Perim[2], Perim[3]);
  for I := 0 to High(ABorderS) do
    if (ABorderS[I].X > AMinX) and (ABorderS[I].X < AMaxX) then
      InsertPoint(T, ABorderS[I]);
  for I := 0 to High(ABorderE) do
    if (ABorderE[I].Z > AMinZ) and (ABorderE[I].Z < AMaxZ) then
      InsertPoint(T, ABorderE[I]);
  for I := 0 to High(ABorderN) do
    if (ABorderN[I].X > AMinX) and (ABorderN[I].X < AMaxX) then
      InsertPoint(T, ABorderN[I]);
  for I := 0 to High(ABorderW) do
    if (ABorderW[I].Z > AMinZ) and (ABorderW[I].Z < AMaxZ) then
      InsertPoint(T, ABorderW[I]);

  { 2. вставка цепочек item'ов как ограничений. Вершины вне ячейки
       игнорируются InsertPoint'ом; звенья с потерянным концом
       пропускаются — их роль на границе уже сыграли border-точки. }
  for I := 0 to AItemN - 1 do
    for J := 0 to High(AItems[I].Rings) do
    begin
      RN2 := Length(AItems[I].Rings[J]);
      if RN2 < 3 then Continue;
      PrevI := InsertPoint(T, AItems[I].Rings[J][RN2 - 1]);
      for K := 0 to RN2 - 1 do
      begin
        CurI := InsertPoint(T, AItems[I].Rings[J][K]);
        if (PrevI >= 0) and (CurI >= 0) then
          InsertEdge(T, PrevI, CurI);
        PrevI := CurI;
      end;
    end;

  { 3. peel: каждому живому треугольнику — материал верхнего item'а,
       накрывающего его центроид (winding по всем кольцам item'а);
       никто не накрыл — терраин. Item'ы просматриваются по убыванию
       ZIndex (вызывающий подаёт их уже отсортированными; здесь — по
       порядку массива). }
  ResN := 0;
  SetLength(Result, T.TriN);
  for I := 0 to T.TriN - 1 do
  begin
    if not T.Tris[I].Alive then Continue;
    cx3 := Int64(T.Pts[T.Tris[I].V[0]].X) + Int64(T.Pts[T.Tris[I].V[1]].X)
         + Int64(T.Pts[T.Tris[I].V[2]].X);
    cz3 := Int64(T.Pts[T.Tris[I].V[0]].Z) + Int64(T.Pts[T.Tris[I].V[1]].Z)
         + Int64(T.Pts[T.Tris[I].V[2]].Z);
    MatOf := ATerrainMat;
    TagOf := ATerrainTag;
    for J := 0 to AItemN - 1 do
    begin
      w := AItems[J].BaseWinding;
      for K := 0 to High(AItems[J].Rings) do
        w := w + WindingAt3(cx3, cz3, AItems[J].Rings[K]);
      claimed := w <> 0;
      if claimed then
      begin
        MatOf := AItems[J].MatId;
        TagOf := AItems[J].Tag;
        Break;
      end;
    end;
    Result[ResN].A := T.Pts[T.Tris[I].V[0]];
    Result[ResN].B := T.Pts[T.Tris[I].V[1]];
    Result[ResN].C := T.Pts[T.Tris[I].V[2]];
    Result[ResN].MatId := MatOf;
    Result[ResN].Tag := TagOf;
    Inc(ResN);
  end;
  SetLength(Result, ResN);
end;

end.
