unit Osm3dCarveGround;

{$Q-}{$R-}

{ Целочисленный тракт карва земли (этап 3 переделки, см.
  carve-watertight-redesign.md): int-замена связки
  TTerrainClipper.CaptureMeshTriangles + CarveAndEmitCaptured.

  Поток данных:
    1) CaptureMeshBoundaryInt — из готового меша слоя (ландюз, отмостки,
       вода, дорожные ленты) извлекаются ГРАНИЧНЫЕ кольца: направленные
       рёбра без пары, сцепленные в циклы по квантованным вершинам.
       Ориентация меша даёт наружные кольца CCW и дыры CW сама собой —
       ровно то, что ест winding-peel ячейки.
    2) CarveGroundInt — линии клеточной сетки квантуются ОДИН РАЗ на чанк
       (LatQuant от проекции узла), все кольца и линии нодируются
       TLatticeNoder'ом, кольца пересобираются из канонических цепочек,
       затем каждая ячейка режется целочисленным CarveCell с
       border-таблицами нодера.
    3) Эмит: треугольники ячеек идут через ОДИН TLatticeVertexDict на
       чанк — общая каноническая точка из любой ячейки получает один
       индекс, «велд» происходит по построению. Y=0 и up-нормаль:
       реальную высоту и гладкую нормаль кладёт существующий drape-проход
       по свелженному композиту (как у float-тракта), поэтому канонические
       вершины получают идентичный Y автоматически.

  UV: planar — pos*InvUV слоя; bary (дороги) — по мешу-источнику слоя
  через spatial-hash треугольников и барицентрический lookup (переходная
  схема из плана; цель — аналитическая UV от центрлайна). Вершина на
  границе двух кусков одного материала берёт UV первого пришедшего куска
  (в свелженном меше вершина одна) — компромисс, тот же по духу, что
  вершинная развязка старого тракта.

  Межчанковый шов остаётся существующему механизму (пер-band weld):
  проекции чанков локальны, канонизация действует внутри чанка. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, CastleVectors, Osm3dGeoMath, Osm3dGeomMesh, Osm3dGeomTerrain,
  Osm3dCarveLattice, Osm3dCarveCell;

type
  TIntUVMode = (iumNone, iumPlanar, iumBary);

  TIntCaptureLayer = record
    Mesh:   TMesh;              { источник границ и bary-UV }
    MatId:  Integer;
    ZIndex: Integer;            { информативно; порядок массива слоёв —
                                  убывание ZIndex, его и ест peel }
    UVMode: TIntUVMode;
    InvUV:  Single;             { для iumPlanar }
    Rings:  array of TLatRing;  { заполняет CaptureMeshBoundaryInt }
  end;
  TIntCaptureLayerArray = array of TIntCaptureLayer;

  TCarveGroundStats = record
    Cells, EmptyCells: Integer;
    RingsIn, RingsNoded: Integer;
    SegsNoded: Integer;
    TrisOut, VertsOut: Integer;
    Arcs, Blankets: Integer;
    DecimBlocks, DecimCoarseCells: Integer;
    DecimHeightRejected: Integer;
    HoleTris: Integer;                 { выброшено кусков нутра под зданиями }
    Ms: QWord;
    Fail: string;               { '' = ок; иначе причина пустого выхода }
    Warn: string;               { нефатальные аномалии (мусорные точки и пр.) }
  end;

{ Извлечь граничные кольца меша слоя в L.Rings (квантованные, деген-рёбра и
  нулевые кольца выброшены). Возвращает число колец. }
function CaptureMeshBoundaryInt(var L: TIntCaptureLayer): Integer;

{ ───── кольца от ИСТОЧНИКА (int-first вход, минуя треугольный суп) ─────
  Полигоны OSM подаются в карв напрямую: локальные XZ -> решётка, с
  принудительной ориентацией (наружные CCW, дыры CW по знаку площади).
  Мешок колец живёт параллельно мешам ландюза: воркер пишет в свой,
  слияние конкатенирует. }
const
  { Слой-«дыра»: где он выигрывает peel, геометрия НЕ эмитится вовсе
    (нутро под зданиями: крыша сверху, стены по периметру, видимое кольцо
    отмостки снаружи). ZIndex дыры ставится выше площадных материалов и
    ниже дорог — дорога сквозь футпринт не продырявится. }
  GROUND_MAT_HOLE = -1;

  { Запас клип-прямоугольника за край сетки (единиц решётки = 1 км при
    64/м): на покрытие ячеек не влияет, нужен только чтобы не резать
    кольца, идущие вплотную к границе блока. }
  CLIP_MARGIN_UNITS = 64000;

type
  TLatRingBag = record
    Rings: array of TLatRing;
    N: Integer;
  end;
  PLatRingBag = ^TLatRingBag;

{ Квантовать контур в решётку и положить в мешок с ориентацией AWantCCW.
  Дедуп последовательных, нулевая площадь — отбрасывается. }
procedure BagAddRingWorld(var Bag: TLatRingBag;
  const Pts: array of TScatterPoint; AWantCCW: Boolean);

{ Мультиполигон: Outer как CCW, каждое Inner как CW. }
procedure BagAddMultipolygon(var Bag: TLatRingBag;
  const MP: TPolygonMultipolygon);

{ Конкатенация (слияние воркеров). }
procedure BagAppend(var Dst: TLatRingBag; const Src: TLatRingBag);

{ Слой карва из мешка (Rings копируются срезом; Mesh=nil). }
procedure LayerFromBag(out L: TIntCaptureLayer; const Bag: TLatRingBag;
  AMatId, AZIndex: Integer; AUVMode: TIntUVMode; AInvUV: Single);

{ Полный тракт по чанку. ALayers — по УБЫВАНИЮ ZIndex (верхние первыми).
  OutMeshes[i].Mesh — TMesh (каст от TObject контракта). }
procedure CarveGroundInt(
  const AGrid: TTerrainGrid;
  AProjection: TLocalProjection;
  var ALayers: array of TIntCaptureLayer;
  ATerrainMatId: Integer;
  ATerrainInvUV: Single;
  AEdgePx: Integer;
  out OutMeshes: TCarvedMatMeshArray;
  out AStats: TCarveGroundStats;
  AThreads: Integer = 1;
  const ARoadLevel: TBytes = nil;      { узловое поле NXL x NZL: кап уровня }
  ADecimMaxLevel: Integer = 0;         { 0 = RQT выкл; L = блоки до 2^L }
  const AHoleMask: TBytes = nil;       { узловая маска NXL x NZL: ячейка с
                                         4 узлами в маске НЕ эмитится вовсе
                                         (нутро под зданиями) — ни одного
                                         нового кольца/дуги, в отличие от
                                         слоя-дыры }
  ASampler: TTerrainSampler = nil);   { required for height-safe decimation }

implementation

uses
  Classes, Math, Osm3dWorkerPool, Osm3dGenerationProgress;

{$POINTERMATH ON}

type
  PMVx = ^TMeshVertex;
  PMIx = ^Cardinal;



{ ─────────────── захват граничных колец ─────────────── }

function CaptureMeshBoundaryInt(var L: TIntCaptureLayer): Integer;
type
  TDirEdge = record A, B: TLatticePoint; end;
var
  V:  TMeshVertexArray;
  Ix: TMeshIndexArray;
  TriN, I, K, N, EN, M, RN, PN, start, cur: Integer;
  QP: array of TLatticePoint;          { квантованные вершины меша }
  E:  array of TDirEdge;
  Dict: TLatticeVertexDict;            { уникальные точки -> id }
  AId, BId: Integer;
  PairCnt: array of Integer;           { счёт направленного ребра AId->BId }
  PairKey: array of Int64;
  OutFrom: array of Integer;           { голова списка исходящих для точки }
  NextE:   array of Integer;           { связь списка }
  Taken:   array of Boolean;
  Ring: TLatRing;
  a2: Int64;

  function PackAB(AI, BI: Integer): Int64; inline;
  begin
    Result := (Int64(AI) shl 32) or Int64(Cardinal(BI));
  end;

  { линейный хэш пар: пар немного (граничных рёбер), open addressing }
  var HCap: Integer; HKey: array of Int64; HVal: array of Integer;
  procedure HInit(Cap: Integer);
  var q: Integer;
  begin
    HCap := 64;
    while HCap < Cap * 2 do HCap := HCap * 2;
    SetLength(HKey, HCap); SetLength(HVal, HCap);
    for q := 0 to HCap - 1 do HVal[q] := -1;
  end;
  function HSlot(Key: Int64): Integer;
  begin
    {$push}{$Q-}{$R-}
    Result := Integer((QWord(Key) * QWord($9E3779B97F4A7C15))
              shr (64 - BsrQWord(QWord(HCap))));
    {$pop}
    while (HVal[Result] >= 0) and (HKey[Result] <> Key) do
      Result := (Result + 1) and (HCap - 1);
  end;

begin
  Result := 0;
  L.Rings := nil;
  if L.Mesh = nil then Exit;
  V := L.Mesh.Vertices;
  Ix := L.Mesh.Indices;
  TriN := L.Mesh.TriangleCount;
  if TriN = 0 then Exit;

  { квантование вершин и id уникальных точек }
  N := L.Mesh.VertexCount;
  SetLength(QP, N);
  Dict := TLatticeVertexDict.Create;
  try
    for I := 0 to N - 1 do
      QP[I] := LatPoint(V[I].Position.X, V[I].Position.Z);

    { счёт направленных рёбер по id-парам: ребро с парой-антиподом —
      внутреннее; остаток — граница (кратность учитывается) }
    HInit(TriN * 3);
    SetLength(PairKey, 0); SetLength(PairCnt, 0);
    M := 0;
    for I := 0 to TriN - 1 do
      for K := 0 to 2 do
      begin
        AId := Dict.IndexOf(QP[Ix[I*3 + K]]);
        BId := Dict.IndexOf(QP[Ix[I*3 + ((K+1) mod 3)]]);
        if AId = BId then Continue;                  { деген после кванта }
        cur := HSlot(PackAB(AId, BId));
        if HVal[cur] < 0 then
        begin
          HKey[cur] := PackAB(AId, BId);
          HVal[cur] := M;
          if M >= Length(PairKey) then
          begin
            SetLength(PairKey, M * 2 + 64);
            SetLength(PairCnt, M * 2 + 64);
          end;
          PairKey[M] := HKey[cur];
          PairCnt[M] := 0;
          Inc(M);
        end;
        Inc(PairCnt[HVal[cur]]);
      end;

    { граничные направленные рёбра: cnt(A->B) - cnt(B->A) > 0, столько раз }
    EN := 0;
    SetLength(E, 64);
    for I := 0 to M - 1 do
    begin
      AId := Integer(PairKey[I] shr 32);
      BId := Integer(Cardinal(PairKey[I]));
      cur := HSlot(PackAB(BId, AId));
      K := PairCnt[I];
      if HVal[cur] >= 0 then Dec(K, PairCnt[HVal[cur]]);
      while K > 0 do
      begin
        if EN >= Length(E) then SetLength(E, EN * 2 + 64);
        E[EN].A := Dict.PointOf(AId);
        E[EN].B := Dict.PointOf(BId);
        Inc(EN);
        Dec(K);
      end;
    end;
    if EN = 0 then Exit;

    { списки исходящих по точке-источнику }
    SetLength(OutFrom, Dict.Count);
    for I := 0 to Dict.Count - 1 do OutFrom[I] := -1;
    SetLength(NextE, EN);
    for I := 0 to EN - 1 do
    begin
      Dict.TryIndexOf(E[I].A, AId);
      NextE[I] := OutFrom[AId];
      OutFrom[AId] := I;
    end;

    { сцепка циклов }
    SetLength(Taken, EN);
    RN := 0;
    for start := 0 to EN - 1 do
    begin
      if Taken[start] then Continue;
      PN := 0;
      SetLength(Ring, 16);
      cur := start;
      repeat
        Taken[cur] := True;
        if PN >= Length(Ring) then SetLength(Ring, PN * 2 + 16);
        Ring[PN] := E[cur].A;
        Inc(PN);
        Dict.TryIndexOf(E[cur].B, BId);
        { следующий untaken исходящий из B }
        I := OutFrom[BId];
        cur := -1;
        while I >= 0 do
        begin
          if not Taken[I] then begin cur := I; Break; end;
          I := NextE[I];
        end;
      until (cur < 0) or LatSame(E[cur].A, Ring[0]);
      { схлоп последовательных дублей }
      K := 0;
      for I := 0 to PN - 1 do
        if (K = 0) or (not LatSame(Ring[I], Ring[K-1])) then
        begin
          Ring[K] := Ring[I];
          Inc(K);
        end;
      if (K > 1) and LatSame(Ring[K-1], Ring[0]) then Dec(K);
      PN := K;
      if PN < 3 then Continue;
      SetLength(Ring, PN);
      a2 := 0;
      for I := 0 to PN - 1 do
        a2 := a2 + Int64(Ring[I].X) * Ring[(I+1) mod PN].Z
                 - Int64(Ring[I].Z) * Ring[(I+1) mod PN].X;
      if a2 = 0 then Continue;
      if RN >= Length(L.Rings) then
        SetLength(L.Rings, RN * 2 + 8);
      L.Rings[RN] := Copy(Ring, 0, PN);
      Inc(RN);
    end;
    SetLength(L.Rings, RN);
    Result := RN;
  finally
    Dict.Free;
  end;
end;

{ ─────────────── кольца от источника ─────────────── }

procedure BagAddRingWorld(var Bag: TLatRingBag;
  const Pts: array of TScatterPoint; AWantCCW: Boolean);
var
  R: TLatRing;
  I, N: Integer;
  a2: Int64;
  T: TLatticePoint;
begin
  if Length(Pts) < 3 then Exit;
  SetLength(R, Length(Pts));
  N := 0;
  for I := 0 to High(Pts) do
  begin
    R[N] := LatPoint(Pts[I].X, Pts[I].Z);
    if (N = 0) or (not LatSame(R[N], R[N-1])) then Inc(N);
  end;
  if (N > 1) and LatSame(R[N-1], R[0]) then Dec(N);
  if N < 3 then Exit;
  a2 := 0;
  for I := 0 to N - 1 do
    a2 := a2 + Int64(R[I].X) * R[(I+1) mod N].Z
             - Int64(R[I].Z) * R[(I+1) mod N].X;
  if a2 = 0 then Exit;
  if (a2 > 0) <> AWantCCW then
    for I := 0 to N div 2 - 1 do
    begin
      T := R[I];
      R[I] := R[N - 1 - I];
      R[N - 1 - I] := T;
    end;
  if Bag.N >= Length(Bag.Rings) then
    SetLength(Bag.Rings, Bag.N * 2 + 8);
  Bag.Rings[Bag.N] := Copy(R, 0, N);
  Inc(Bag.N);
end;

procedure BagAddMultipolygon(var Bag: TLatRingBag;
  const MP: TPolygonMultipolygon);
var
  I: Integer;
begin
  BagAddRingWorld(Bag, MP.Outer, True);
  for I := 0 to High(MP.Inners) do
    BagAddRingWorld(Bag, MP.Inners[I], False);
end;

procedure BagAppend(var Dst: TLatRingBag; const Src: TLatRingBag);
var
  I: Integer;
begin
  if Src.N = 0 then Exit;
  if Dst.N + Src.N > Length(Dst.Rings) then
    SetLength(Dst.Rings, (Dst.N + Src.N) * 2);
  for I := 0 to Src.N - 1 do
  begin
    Dst.Rings[Dst.N] := Src.Rings[I];
    Inc(Dst.N);
  end;
end;

procedure LayerFromBag(out L: TIntCaptureLayer; const Bag: TLatRingBag;
  AMatId, AZIndex: Integer; AUVMode: TIntUVMode; AInvUV: Single);
begin
  L.Mesh := nil;
  L.MatId := AMatId;
  L.ZIndex := AZIndex;
  L.UVMode := AUVMode;
  L.InvUV := AInvUV;
  L.Rings := Copy(Bag.Rings, 0, Bag.N);
end;

{ ─────────────── клиппинг колец к прямоугольнику сетки ───────────────
  Overpass отдаёт way/relations ЦЕЛИКОМ: макро-релейшены (Волга, Дон,
  лесные массивы) и way'и с битыми узлами тащат в карв точки за сотни и
  тысячи км. Раньше это взрывало SetLength бакетов нодера (160 ГБ — краш,
  блок 4952/2562), после клампа бакетов — вешало попарную проверку в
  краевых бакетах (карв >8 мин, блоки 4952/2560-61). Правильное место
  отсечения — здесь, до нодинга: семантика покрытия ячеек сохраняется
  точно (пересекающие кольца режутся Sutherland–Hodgman'ом, накрывающие
  всю сетку заменяются blanket-прямоугольником, внешние выбрасываются). }

const
  { Предел модуля координаты кольца (≈16.7 тыс. км): убивает антимеридиан-
    переполненный мусор до того, как Int64-математика клиппера его увидит. }
  LAT_COORD_CLAMP = 1 shl 30;

procedure LatClampRing(var R: TLatRing);
var I: Integer;
begin
  for I := 0 to High(R) do
  begin
    if R[I].X < -LAT_COORD_CLAMP then R[I].X := -LAT_COORD_CLAMP
    else if R[I].X > LAT_COORD_CLAMP then R[I].X := LAT_COORD_CLAMP;
    if R[I].Z < -LAT_COORD_CLAMP then R[I].Z := -LAT_COORD_CLAMP
    else if R[I].Z > LAT_COORD_CLAMP then R[I].Z := LAT_COORD_CLAMP;
  end;
end;

{ Удвоенная площадь кольца (знак = ориентация, >0 при CCW). Double
  достаточно: нужен только знак заведомо невырожденного кольца. }
function LatRingArea2(const R: TLatRing): Double;
var I, N: Integer;
begin
  Result := 0; N := Length(R);
  for I := 0 to N - 1 do
    Result := Result + R[I].X * R[(I + 1) mod N].Z
                     - R[I].Z * R[(I + 1) mod N].X;
end;

{ even-odd тест точки в кольце (луч +X), Int64-точно (координаты уже
  дожаты LatClampRing — произведения ≤ 2^62). }
function LatPointInRing(X, Z: Int32; const R: TLatRing): Boolean;
var
  I, N: Integer;
  A, B: TLatticePoint;
  Num, Den, XL: Int64;
begin
  Result := False;
  N := Length(R);
  for I := 0 to N - 1 do
  begin
    A := R[I]; B := R[(I + 1) mod N];
    if (A.Z > Z) <> (B.Z > Z) then
    begin
      Den := Int64(B.Z) - A.Z;
      Num := Int64(A.X) * Den + (Int64(Z) - A.Z) * (Int64(B.X) - A.X);
      XL  := Int64(X) * Den;
      if (Den > 0) = (XL < Num) then Result := not Result;
    end;
  end;
end;

{ Один проход Sutherland–Hodgman: оставить полуплоскость. Axis 0 = X,
  1 = Z; KeepLow=False — coord >= C, KeepLow=True — coord <= C. }
procedure LatRingClipPass(const InR: TLatRing; out OutR: TLatRing;
  Axis: Integer; C: Int32; KeepLow: Boolean);
var
  I, N, M: Integer;
  S, E: TLatticePoint;
  SIn, EIn: Boolean;

  function CoordOf(const P: TLatticePoint): Int32; inline;
  begin
    if Axis = 0 then Result := P.X else Result := P.Z;
  end;

  function Inside(const P: TLatticePoint): Boolean; inline;
  begin
    if KeepLow then Result := CoordOf(P) <= C
               else Result := CoordOf(P) >= C;
  end;

  { Точка пересечения ребра S->E с линией coord = C (ребро гарантированно
    её пересекает). Деление с округлением — субметровая точность, знак
    делителя нормализуем. }
  function Cross(const S, E: TLatticePoint): TLatticePoint;
  var
    SC, EC, tnum, tden, oth: Int64;
  begin
    SC := CoordOf(S); EC := CoordOf(E);
    Result := E;
    if EC = SC then Exit;
    tnum := Int64(C) - SC;
    tden := EC - SC;
    if tden < 0 then begin tnum := -tnum; tden := -tden; end;
    if Axis = 0 then
    begin
      oth := Int64(E.Z) - S.Z;
      Result.X := C;
      Result.Z := S.Z + (oth * tnum + tden div 2) div tden;
    end
    else
    begin
      oth := Int64(E.X) - S.X;
      Result.Z := C;
      Result.X := S.X + (oth * tnum + tden div 2) div tden;
    end;
  end;

begin
  N := Length(InR);
  M := 0;
  SetLength(OutR, 2 * N + 4);
  if N = 0 then Exit;
  S := InR[N - 1]; SIn := Inside(S);
  for I := 0 to N - 1 do
  begin
    E := InR[I]; EIn := Inside(E);
    if EIn then
    begin
      if not SIn then begin OutR[M] := Cross(S, E); Inc(M); end;
      OutR[M] := E; Inc(M);
    end
    else if SIn then
    begin
      OutR[M] := Cross(S, E); Inc(M);
    end;
    S := E; SIn := EIn;
  end;
  SetLength(OutR, M);
end;

{ Клиппинг кольца к прямоугольнику [X0,X1] x [Z0,Z1] (4 прохода). }
function LatRingClipRect(const R: TLatRing; X0, X1, Z0, Z1: Int32): TLatRing;
var T1, T2: TLatRing;
begin
  LatRingClipPass(R,  T1, 0, X0, False);
  LatRingClipPass(T1, T2, 0, X1, True);
  LatRingClipPass(T2, T1, 1, Z0, False);
  LatRingClipPass(T1, Result, 1, Z1, True);
end;

{ ─────────────── bary-UV lookup по мешу слоя ─────────────── }

type
  TBaryIndex = record
    Built: Boolean;
    MinX, MinZ: Single;
    CW, CH: Integer;                     { бакеты 4 м }
    Head: array of Integer;              { голова списка entries по бакету }
    { пер-вставочные записи: треугольник входит в НЕСКОЛЬКО ячеек bbox'а —
      единый NextT[tri] перезаписывался каждой следующей ячейкой и ОБРЫВАЛ
      цепочки ранних вставок (потеря кандидатов -> UV чужого квада
      «местами», вне связи с поворотами) }
    EntryTri: array of Integer;
    EntryNext: array of Integer;
    EntryN: Integer;
    { сырые указатели на данные меша: пер-вызовный геттер Vertices/Indices
      делал АТОМАРНЫЙ refcount динмассива на каждый из ~13M lookup'ов }
    PV: PMVx;
    PIx: PMIx;
    Mesh: TMesh;
    { ДИАГ: OsmId вершин на экстремумах bbox (поиск way-виновника раздува) }
    OsmMinX, OsmMaxX, OsmMinZ, OsmMaxZ: Int64;
  end;

{ Мировой bbox колец слоя + запас AMargin: bary-сетку строим только в этих
  пределах — квады UV-меша, убежавшие за пределы блока (чужие/битые way в
  объединённом датасете: way целиком из другого региона в сотнях км), не
  раздувают сетку до потолка ячеек и не гасят UV всего слоя. Lookup'ы
  всё равно идут только по точкам колец/ячеек внутри этого bbox. }
function RingWorldBBox(const ALayer: TIntCaptureLayer; AMargin: Single;
  out AMinX, AMinZ, AMaxX, AMaxZ: Single): Boolean;
var
  R, K: Integer;
  x, z: Single;
begin
  AMinX := 1.0e30; AMaxX := -1.0e30;
  AMinZ := 1.0e30; AMaxZ := -1.0e30;
  for R := 0 to High(ALayer.Rings) do
    for K := 0 to High(ALayer.Rings[R]) do
    begin
      x := LatToWorld(ALayer.Rings[R][K].X);
      z := LatToWorld(ALayer.Rings[R][K].Z);
      if x < AMinX then AMinX := x;
      if x > AMaxX then AMaxX := x;
      if z < AMinZ then AMinZ := z;
      if z > AMaxZ then AMaxZ := z;
    end;
  Result := AMinX <= AMaxX;
  if Result then
  begin
    AMinX := AMinX - AMargin; AMaxX := AMaxX + AMargin;
    AMinZ := AMinZ - AMargin; AMaxZ := AMaxZ + AMargin;
  end;
end;

procedure BuildBaryIndex(var B: TBaryIndex; M: TMesh;
  const AClampMinX, AClampMinZ, AClampMaxX, AClampMaxZ: Single);
const
  CELL = 4.0;
  { Одна «убежавшая» вершина (баг геометрии дороги выше по конвейеру: коорд.
    в сотни км) раздувает bbox до сетки в миллиарды ячеек -> SetLength на
    гигабайты -> OOM-краш. Потолок ячеек: блок ~несколько км, даже с большим
    запасом сетка << этого; всё, что выше — патология. }
  BARY_MAX_CELLS = 64 * 1024 * 1024;   { 64M ячеек = 256 МБ Head — недостижимо для здорового меша }
var
  V: TMeshVertexArray;
  Ix: TMeshIndexArray;
  I, K, cx0, cx1, cz0, cz1, cx, cz: Integer;
  MaxX, MaxZ, x, z: Single;
begin
  B.Built := False;
  B.Mesh := M;
  if (M = nil) or (M.TriangleCount = 0) then Exit;
  V := M.Vertices; Ix := M.Indices;
  B.MinX := V[0].Position.X; MaxX := B.MinX;
  B.MinZ := V[0].Position.Z; MaxZ := B.MinZ;
  B.OsmMinX := V[0].OsmId; B.OsmMaxX := V[0].OsmId;
  B.OsmMinZ := V[0].OsmId; B.OsmMaxZ := V[0].OsmId;
  for I := 1 to M.VertexCount - 1 do
  begin
    x := V[I].Position.X; z := V[I].Position.Z;
    if x < B.MinX then begin B.MinX := x; B.OsmMinX := V[I].OsmId; end;
    if x > MaxX then begin MaxX := x; B.OsmMaxX := V[I].OsmId; end;
    if z < B.MinZ then begin B.MinZ := z; B.OsmMinZ := V[I].OsmId; end;
    if z > MaxZ then begin MaxZ := z; B.OsmMaxZ := V[I].OsmId; end;
  end;
  { Клип сетки к bbox колец слоя: выбросы UV-меша вне блока не индексируем
    (их ячейки всё равно никогда не запрашиваются — lookup'ы идут по точкам
    внутри блока). Дальние треугольники сами выпадают из диапазонов ниже. }
  if AClampMinX > B.MinX then B.MinX := AClampMinX;
  if AClampMaxX < MaxX then MaxX := AClampMaxX;
  if AClampMinZ > B.MinZ then B.MinZ := AClampMinZ;
  if AClampMaxZ < MaxZ then MaxZ := AClampMaxZ;
  B.PV := @V[0];
  B.PIx := @Ix[0];
  B.CW := Trunc((MaxX - B.MinX) * (1.0 / CELL)) + 1;
  B.CH := Trunc((MaxZ - B.MinZ) * (1.0 / CELL)) + 1;
  { Патологический bbox (сетка пуста после клипа или всё ещё за потолком) ->
    НЕ строим ускоряющий индекс: оставляем B.Built=False, LookupBaryUV
    корректно вернёт «промах». Int64 в проверке — от переполнения умножения. }
  if (B.CW <= 0) or (B.CH <= 0)
     or (Int64(B.CW) * Int64(B.CH) > BARY_MAX_CELLS) then
    Exit;
  SetLength(B.Head, B.CW * B.CH);
  for I := 0 to High(B.Head) do B.Head[I] := -1;
  B.EntryN := 0;
  SetLength(B.EntryTri, M.TriangleCount * 2);
  SetLength(B.EntryNext, M.TriangleCount * 2);
  for I := 0 to M.TriangleCount - 1 do
  begin
    cx0 := Max(0, Trunc((Min(Min(V[Ix[I*3]].Position.X, V[Ix[I*3+1]].Position.X),
      V[Ix[I*3+2]].Position.X) - B.MinX) / CELL));
    cx1 := Min(B.CW-1, Trunc((Max(Max(V[Ix[I*3]].Position.X, V[Ix[I*3+1]].Position.X),
      V[Ix[I*3+2]].Position.X) - B.MinX) / CELL));
    cz0 := Max(0, Trunc((Min(Min(V[Ix[I*3]].Position.Z, V[Ix[I*3+1]].Position.Z),
      V[Ix[I*3+2]].Position.Z) - B.MinZ) / CELL));
    cz1 := Min(B.CH-1, Trunc((Max(Max(V[Ix[I*3]].Position.Z, V[Ix[I*3+1]].Position.Z),
      V[Ix[I*3+2]].Position.Z) - B.MinZ) / CELL));
    for cz := cz0 to cz1 do
      for cx := cx0 to cx1 do
      begin
        K := cz * B.CW + cx;
        if B.EntryN >= Length(B.EntryTri) then
        begin
          SetLength(B.EntryTri, B.EntryN * 2);
          SetLength(B.EntryNext, B.EntryN * 2);
        end;
        B.EntryTri[B.EntryN] := I;
        B.EntryNext[B.EntryN] := B.Head[K];
        B.Head[K] := B.EntryN;
        Inc(B.EntryN);
      end;
  end;
  B.Built := True;
end;

function LookupBaryUV(const B: TBaryIndex; WX, WZ: Single;
  out U, Vv: Single; out AWay: Int64; AWayFilter: Int64;
  AMinDepth: Single = -1.0): Boolean;
const
  CELL = 4.0;
  EPS  = 1e-3;
var
  V: PMVx;
  Ix: PMIx;
  cx, cz, dx, dz, ci, T, E: Integer;
  ax, az, b0x, b0z, b1x, b1z: Double;
  d00, d01, d11, d20, d21, den, bu, bv, bw, depth, best: Double;
  bestT: Integer;
  bestU, bestV, bestW: Double;
begin
  Result := False;
  U := 0; Vv := 0; AWay := 0;
  if not B.Built then Exit;
  V := B.PV; Ix := B.PIx;
  cx := Trunc((WX - B.MinX) * (1.0 / CELL));
  cz := Trunc((WZ - B.MinZ) * (1.0 / CELL));
  best := -1e30; bestT := -1; bestU := 0; bestV := 0; bestW := 0;
  for dz := -1 to 1 do
    for dx := -1 to 1 do
    begin
      if (cx+dx < 0) or (cx+dx >= B.CW) or (cz+dz < 0) or (cz+dz >= B.CH) then
        Continue;
      ci := (cz+dz) * B.CW + (cx+dx);
      E := B.Head[ci];
      while E >= 0 do
      begin
        T := B.EntryTri[E];
        { фильтр по исходному way: перекрёсток/перекрытия берут развёртку
          ОДНОЙ ленты, выбранной вызывающим по центроиду треугольника —
          иначе соседние вершины мешают V разных дорог (размазанные полосы) }
        if (AWayFilter <> 0) and (V[Ix[T*3]].OsmId <> AWayFilter) then
        begin
          E := B.EntryNext[E];
          Continue;
        end;
        ax  := V[Ix[T*3]].Position.X;   az  := V[Ix[T*3]].Position.Z;
        b0x := V[Ix[T*3+1]].Position.X - ax;
        b0z := V[Ix[T*3+1]].Position.Z - az;
        b1x := V[Ix[T*3+2]].Position.X - ax;
        b1z := V[Ix[T*3+2]].Position.Z - az;
        d00 := b0x*b0x + b0z*b0z;
        d01 := b0x*b1x + b0z*b1z;
        d11 := b1x*b1x + b1z*b1z;
        den := d00*d11 - d01*d01;
        if Abs(den) > 1e-12 then
        begin
          d20 := (WX-ax)*b0x + (WZ-az)*b0z;
          d21 := (WX-ax)*b1x + (WZ-az)*b1z;
          bv := (d11*d20 - d01*d21) / den;
          bw := (d00*d21 - d01*d20) / den;
          bu := 1.0 - bv - bw;
          depth := Min(bu, Min(bv, bw));
          { владелец = МАКСИМАЛЬНАЯ барицентрическая глубина среди всех
            кандидатов (не первый содержащий): на развязках из многих лент
            одного материала первый-попавшийся давал лоскутную смену
            владельца между соседними треугольниками и «щепки» с UV кромки
            чужой ленты; глубина даёт вороного-подобный раздел.
            ПРИ ФИЛЬТРЕ (кандидаты одной ленты) глубина не критична —
            перекрытия только на витках скруглений, V непрерывен вдоль
            ленты: ранний выход возвращает дешевизну горячего пути. }
          if depth > best then
          begin
            best := depth; bestT := T;
            bestU := bu; bestV := bv; bestW := bw;
          end;
          if (AWayFilter <> 0)
             and (((AMinDepth <= -1.0) and (depth >= -EPS))
                  or ((AMinDepth > -1.0) and (depth >= AMinDepth))) then
          begin
            U := bu * V[Ix[T*3]].UV.X + bv * V[Ix[T*3+1]].UV.X
               + bw * V[Ix[T*3+2]].UV.X;
            Vv := bu * V[Ix[T*3]].UV.Y + bv * V[Ix[T*3+1]].UV.Y
                + bw * V[Ix[T*3+2]].UV.Y;
            AWay := V[Ix[T*3]].OsmId;
            Exit(True);
          end;
        end;
        E := B.EntryNext[E];
      end;
    end;
  { fallback: лучший по барицентрической глубине (клип к треугольнику) }
  if (bestT >= 0)
     and ((AMinDepth <= -1.0) or (best >= AMinDepth)) then
  begin
    bu := Max(0.0, bestU); bv := Max(0.0, bestV); bw := Max(0.0, bestW);
    den := bu + bv + bw;
    if den > 0 then
    begin
      bu := bu / den; bv := bv / den; bw := bw / den;
      U  := bu * V[Ix[bestT*3]].UV.X + bv * V[Ix[bestT*3+1]].UV.X
          + bw * V[Ix[bestT*3+2]].UV.X;
      Vv := bu * V[Ix[bestT*3]].UV.Y + bv * V[Ix[bestT*3+1]].UV.Y
          + bw * V[Ix[bestT*3+2]].UV.Y;
      AWay := V[Ix[bestT*3]].OsmId;
      Result := True;
    end;
  end;
end;

{ ─────────────── тракт по чанку ─────────────── }

function PackTileKeyInt(TX, TY: Integer): Int64; inline;
begin
  Result := (Int64(TX) shl 32) or Int64(Cardinal(TY));
end;

type
  TTripRec = record
    CellKey, Layer: Integer;
    ArcStart, ArcLen: Integer;
    { исходное кольцо слоя: дуги РАЗНЫХ колец в ячейке перекрытия
      пересекаются внутри неё — жадная периметральная сцепка вперемешку
      рождала самопересекающиеся/CW-кольца, триангулятор их отбрасывал,
      слой в ячейке пропадал («квадрат травы» на перекрытиях лент).
      Сцепка идёт пер-кольцево: каждое исходное кольцо замыкается
      отдельно, перекрытие даёт честные +1-кольца для peel. }
    RingId: Integer;
  end;
  TTripArray = array of TTripRec;
  TBaryIndexArray = array of TBaryIndex;

  { Контекст полосы строк [Z0..Z1): общие данные read-only, выход и
    словари — свои. Скретчи — локальные переменные CarveBandCells. }
  TCarveBandCtx = record
    Cancel: PBoolean;
    LX, LZ: array of Int32;
    CellsX, Z0, Z1, CellsZTot: Integer;
    Noder: TLatticeNoder;
    Trip: TTripArray;
    Order, Offs: array of Integer;
    ArcPool: TLatticePointArray;
    Layers: TIntCaptureLayerArray;
    Bary: TBaryIndexArray;
    TerrainMatId: Integer;
    TerrainInvUV: Single;
    GPX0, GPY0: Int64;
    PitchPx: Double;
    EdgePx: Integer;
    FlipX, FlipZ: Boolean;
    Lv: TBytes;                        { финальный уровень ячейки (0 = мелко) }
    HoleCell: TBytes;                  { 1 = ячейка целиком под зданием }
    CellCls, WinLay: TBytes;           { класс: MatId / 254 terrain / 255 mixed }
    OutMeshes: TCarvedMatMeshArray;
    MDict: array of TLatticeVertexDict;
    StatCells, StatEmpty, StatTris: Integer;
    StatBlocks, StatCoarse: Integer;
    StatHole: Integer;
  end;
  PCarveBandCtx = ^TCarveBandCtx;

procedure CarveBandCells(var B: TCarveBandCtx);
var
  Items: TCarveItemArray;
  PosStarts, PosLens, NegStarts, NegLens: array of Integer;
  PosRing, NegRing: array of Integer;
  grpA, grpB: Integer;
  LTrip: TTripArray;
  LOrder: array of Integer;
  LOffs: array of Integer;
  pTR: ^TTripRec;
  { строчный буфер индексов терраин-вершин на узлах сетки: замена
    словарного IndexOf арифметикой строки (низ RowA / верх RowB);
    валиден только для пер-ячеечного пути (в блоках FCellIx=-1) }
  RowA, RowB, RowSwp: array of Integer;
  DictMap: array of array of Integer;   { пер-меш: id словаря -> вершина }
  { прямое отображение MatId -> индекс в OutMeshes: замена линейного поиска
    по OutMeshes на каждый эмит-треугольник (O(M)) прямой индексацией (O(1)).
    Индекс = MatId + 1, смещение +1 покрывает GROUND_MAT_HOLE = -1. Значение
    -1 = слот ещё не заведён. MatId вне таблицы обслуживает медленный путь. }
  MatSlot: array of Integer;
  FCellIx: Integer;
  FCellLX0, FCellLX1, FCellLZ0, FCellLZ1: Int32;
  rowIz: Integer;
  cellArcs: Boolean;
  BXl, BXr, BZbot, BZtop: TLatticePointArray;
  bxIx: Integer;
  fMat: Integer;
  fTag: Int64;
  FastTri: TCarveTri;
  posN, negN, BaseW, outRN, aLen, ItemUse: Integer;
  RingBuf: array of TLatRing;
  CAEnt, CAExt: array of Int64;
  CAUsed: array of Boolean;
  CARing: TLatRing;
  { UV-кэш (позиция решётки, владелец) -> UV: свежие вершины bary убили
    словарный дедуп — кэш возвращает один lookup на уникальную пару }
  UCKey: array of Int64;
  UCWay: array of Int64;
  UCU, UCV: array of Single;
  UCVtx: array of Integer;
  UCMesh: array of Integer;
  UCMask, UCN: Integer;
  OMKey: array of Int64;
  OMWay: array of Int64;
  OMMask, OMN: Integer;
  I, J, K, ix, iz, ck, run, itemN, li, origIX, origIZ, sz: Integer;
  Tris: TCarveTriArray;
  tileKey: Int64;
  SideW, SideE, SideN, SideS: TLatticePointArray;

  function MatMeshIdx(AMat: Integer): Integer;
  var q, mi: Integer;
  begin
    { быстрый путь: MatId в пределах таблицы -> прямая индексация O(1) }
    mi := AMat + 1;
    if (mi >= 0) and (mi < Length(MatSlot)) then
    begin
      Result := MatSlot[mi];
      if Result >= 0 then Exit;      { слот уже заведён }
    end
    else
    begin
      { MatId вне таблицы (не ожидается: диапазон -1..GROUND_MAT_COUNT-1) —
        страховочный линейный поиск сохраняет поведение при любом MatId }
      mi := -1;
      for q := 0 to High(B.OutMeshes) do
        if B.OutMeshes[q].MatId = AMat then Exit(q);
    end;
    { промах: завести новый меш (порядок first-seen сохранён — как раньше) }
    q := Length(B.OutMeshes);
    SetLength(B.OutMeshes, q + 1);
    B.OutMeshes[q].MatId := AMat;
    B.OutMeshes[q].Mesh := TMesh.Create;
    B.OutMeshes[q].TriTileKeys := nil;
    B.OutMeshes[q].TriKeyCount := 0;
    SetLength(B.MDict, q + 1);
    B.MDict[q] := TLatticeVertexDict.Create;
    if mi >= 0 then MatSlot[mi] := q;   { запомнить только для MatId в таблице }
    Result := q;
  end;

  { замыкание дуг ОДНОГО знака в ячейке в замкнутые суб-кольца.
    ADir=+1: связка exit->entry против часовой (CCW-кольца), -1: по часовой
    (CW-дыры). Дуги с first==last — готовые кольца. Для выпуклого клипа
    (прямоугольник) связывание exit -> ближайший-entry-по-направлению даёт
    корректную сумму winding'ов даже для дуг разных исходных колец. }
  procedure SortArcsByRing(var AStarts, ALens, ARing: array of Integer;
    ACount: Integer);
  var
    i4, j4, ts, tl, tr: Integer;
  begin
    for i4 := 1 to ACount - 1 do
    begin
      ts := AStarts[i4]; tl := ALens[i4]; tr := ARing[i4];
      j4 := i4 - 1;
      while (j4 >= 0) and (ARing[j4] > tr) do
      begin
        AStarts[j4+1] := AStarts[j4];
        ALens[j4+1] := ALens[j4];
        ARing[j4+1] := ARing[j4];
        Dec(j4);
      end;
      AStarts[j4+1] := ts; ALens[j4+1] := tl; ARing[j4+1] := tr;
    end;
  end;

  procedure CloseArcsToRingsSub(x0c, z0c, x1c, z1c: Int32;
    const AStarts, ALens: array of Integer; AOfs, ACount, ADir: Integer;
    var OutRings: array of TLatRing; var OutN: Integer);
  var
    PerTot, cw, ch: Int64;
    ai, bi, best, cur, n2, guard, k3, srcs, srcl, RN2: Integer;
    bestP, curP, cp: Int64;

    function Perim(const P0: TLatticePoint): Int64;
    var
      px, pz, d0, d1, d2, d3, m: Int64;
    begin
      { ФИКС «дротиков»: концы дуг НЕ обязаны лежать на границах ячейки —
        CutRingToArcs режет кольцо по midpoint'ам сегментов, и конец дуги
        обычно торчит в соседнюю ячейку. Прежняя классификация строгим
        равенством (Z=z0c / X=x1c / Z=z1c / иначе-левая) валила такие
        точки в ветку «левая сторона»: у дуги, идущей вдоль верхней кромки,
        оба конца получали почти одинаковую «левую» позицию, обход
        exit->entry вставлял все 4 угла и суб-кольцо накрывало ВСЮ ячейку —
        слой затапливал её до клеточных линий (клин между кромкой ленты и
        линией, остриё на стыке с корректной ячейкой). Классифицируем по
        БЛИЖАЙШЕЙ стороне с клампом внутрь: для точек, лежащих на границе,
        результат бит-в-бит прежний; для торчащих — геометрически верный. }
      px := P0.X; pz := P0.Z;
      if px < x0c then px := x0c else if px > x1c then px := x1c;
      if pz < z0c then pz := z0c else if pz > z1c then pz := z1c;
      d0 := pz - z0c;          { до нижней (Z=z0c) }
      d1 := Int64(x1c) - px;   { до правой (X=x1c) }
      d2 := Int64(z1c) - pz;   { до верхней (Z=z1c) }
      d3 := px - x0c;          { до левой (X=x0c) }
      m := d0;
      if d1 < m then m := d1;
      if d2 < m then m := d2;
      if d3 < m then m := d3;
      if m = d0 then Result := px - x0c
      else if m = d1 then Result := cw + d0
      else if m = d2 then Result := cw + ch + (Int64(x1c) - px)
      else Result := 2 * cw + ch + (Int64(z1c) - pz);
      if ADir < 0 then Result := PerTot - Result;
      if Result >= PerTot then Result := Result - PerTot;
    end;
    procedure RingPush(const P0: TLatticePoint);
    begin
      if (RN2 > 0) and LatSame(CARing[RN2-1], P0) then Exit;
      if RN2 >= Length(CARing) then SetLength(CARing, RN2 * 2 + 16);
      CARing[RN2] := P0;
      Inc(RN2);
    end;
    { углы прямоугольника с периметром строго внутри (PFrom -> PTo)
      по направлению обхода — вставляются по порядку следования }
    procedure PushCornersBetween(PFrom, PTo: Int64);
    var
      c4, bc: Integer;
      pc, dc, bd, dTo: Int64;
      CP4: TLatticePoint;
    begin
      dTo := PTo - PFrom;
      if dTo <= 0 then dTo := dTo + PerTot;
      repeat
        bc := -1; bd := High(Int64);
        for c4 := 0 to 3 do
        begin
          case c4 of
            0: pc := 0;                { SW }
            1: pc := cw;               { SE }
            2: pc := cw + ch;          { NE }
            else pc := 2 * cw + ch;    { NW }
          end;
          if ADir < 0 then
          begin
            pc := PerTot - pc;
            if pc >= PerTot then pc := pc - PerTot;
          end;
          dc := pc - PFrom;
          if dc <= 0 then dc := dc + PerTot;
          if dc < bd then
          begin
            bd := dc;
            bc := c4;
          end;
        end;
        if bd >= dTo then Break;       { ближайший угол за entry — конец }
        case bc of
          0: begin CP4.X := x0c; CP4.Z := z0c; end;
          1: begin CP4.X := x1c; CP4.Z := z0c; end;
          2: begin CP4.X := x1c; CP4.Z := z1c; end;
          else begin CP4.X := x0c; CP4.Z := z1c; end;
        end;
        RingPush(CP4);
        PFrom := PFrom + bd;
        if PFrom >= PerTot then PFrom := PFrom - PerTot;
        dTo := dTo - bd;
      until False;
    end;

  begin
    cw := Int64(x1c) - x0c;
    ch := Int64(z1c) - z0c;
    PerTot := 2 * (cw + ch);
    if ACount > Length(CAEnt) then
    begin
      SetLength(CAEnt, ACount * 2 + 8);
      SetLength(CAExt, ACount * 2 + 8);
      SetLength(CAUsed, ACount * 2 + 8);
    end;
    n2 := 0;
    for ai := 0 to ACount - 1 do
    begin
      srcs := AStarts[AOfs + ai];
      srcl := ALens[AOfs + ai];
      if LatSame(B.ArcPool[srcs], B.ArcPool[srcs + srcl - 1]) then
      begin
        if srcl - 1 >= 3 then
        begin
          OutRings[OutN] := Copy(B.ArcPool, srcs, srcl - 1);
          Inc(OutN);
        end;
        CAUsed[ai] := True;
      end
      else
      begin
        CAUsed[ai] := False;
        CAEnt[ai] := Perim(B.ArcPool[srcs]);
        CAExt[ai] := Perim(B.ArcPool[srcs + srcl - 1]);
        Inc(n2);
      end;
    end;
    guard := n2 * 2 + 4;
    while (n2 > 0) and (guard > 0) do
    begin
      Dec(guard);
      cur := -1;
      for ai := 0 to ACount - 1 do
        if not CAUsed[ai] then begin cur := ai; Break; end;
      if cur < 0 then Break;
      RN2 := 0;
      CAUsed[cur] := True;
      Dec(n2);
      bi := cur;
      repeat
        srcs := AStarts[AOfs + bi];
        srcl := ALens[AOfs + bi];
        for k3 := 0 to srcl - 1 do RingPush(B.ArcPool[srcs + k3]);
        curP := CAExt[bi];
        best := -1; bestP := High(Int64);
        for ai := 0 to ACount - 1 do
          if (not CAUsed[ai]) or (ai = cur) then
          begin
            cp := CAEnt[ai] - curP;
            if cp <= 0 then cp := cp + PerTot;
            if cp < bestP then
            begin
              bestP := cp;
              best := ai;
            end;
          end;
        if best < 0 then Break;
        PushCornersBetween(curP, CAEnt[best]);
        if best = cur then Break;
        CAUsed[best] := True;
        Dec(n2);
        bi := best;
      until False;
      if (RN2 > 1) and LatSame(CARing[RN2-1], CARing[0]) then Dec(RN2);
      if RN2 >= 3 then
      begin
        OutRings[OutN] := Copy(CARing, 0, RN2);
        Inc(OutN);
      end;
    end;
  end;

  { точки катов линии X=const строго внутри (z0,z1)? бинпоиск по Z }
  function CutsInsideX(const A: TLatticePointArray; z0, z1: Int32): Boolean;
  var lo3, hi3, mid3: Integer;
  begin
    Result := False;
    if A = nil then Exit;
    lo3 := 0; hi3 := High(A);
    while lo3 <= hi3 do
    begin
      mid3 := (lo3 + hi3) shr 1;
      if A[mid3].Z <= z0 then lo3 := mid3 + 1
      else hi3 := mid3 - 1;
    end;
    Result := (lo3 <= High(A)) and (A[lo3].Z < z1);
  end;

  function CutsInsideZ(const A: TLatticePointArray; x0, x1: Int32): Boolean;
  var lo3, hi3, mid3: Integer;
  begin
    Result := False;
    if A = nil then Exit;
    lo3 := 0; hi3 := High(A);
    while lo3 <= hi3 do
    begin
      mid3 := (lo3 + hi3) shr 1;
      if A[mid3].X <= x0 then lo3 := mid3 + 1
      else hi3 := mid3 - 1;
    end;
    Result := (lo3 <= High(A)) and (A[lo3].X < x1);
  end;

  { владелец региона бакета: >0 — единственная лента 3x3-окрестности,
    0 — мульти-way или пусто (нужен полный скан). Кэш пер-полосный. }
  function MemoOwnerOf(ALay: Integer; AWX, AWZ: Single): Int64;
  var
    bx2, bz2, ci2, slot, dx2, dz2, e2: Integer;
    key2: Int64;
    w2, found: Int64;
  begin
    Result := 0;
    with B.Bary[ALay] do
    begin
      if not Built then Exit;
      bx2 := Trunc((AWX - MinX) * 0.25);
      bz2 := Trunc((AWZ - MinZ) * 0.25);
      if (bx2 < 0) or (bx2 >= CW) or (bz2 < 0) or (bz2 >= CH) then Exit;
      ci2 := bz2 * CW + bx2;
    end;
    if OMKey = nil then
    begin
      OMMask := (1 shl 16) - 1;
      SetLength(OMKey, OMMask + 1);
      SetLength(OMWay, OMMask + 1);
      for slot := 0 to OMMask do OMWay[slot] := 0;
    end;
    key2 := (Int64(ALay) shl 32) or Int64(Cardinal(ci2)) or Int64(1) shl 62;
    {$push}{$Q-}{$R-}
    slot := Integer((QWord(key2) * QWord($9E3779B97F4A7C15)) shr 48)
      and OMMask;
    {$pop}
    while (OMWay[slot] <> 0) and (OMKey[slot] <> key2) do
      slot := (slot + 1) and OMMask;
    if OMWay[slot] <> 0 then
    begin
      if OMWay[slot] > 0 then
        Result := OMWay[slot];
      Exit;
    end;
    { промах: один обход 3x3 — единственная лента или мульти }
    found := 0;
    with B.Bary[ALay] do
      for dz2 := -1 to 1 do
        for dx2 := -1 to 1 do
        begin
          bx2 := Trunc((AWX - MinX) * 0.25) + dx2;
          bz2 := Trunc((AWZ - MinZ) * 0.25) + dz2;
          if (bx2 < 0) or (bx2 >= CW) or (bz2 < 0) or (bz2 >= CH) then
            Continue;
          e2 := Head[bz2 * CW + bx2];
          while e2 >= 0 do
          begin
            w2 := PV[PIx[EntryTri[e2] * 3]].OsmId;
            if found = 0 then found := w2
            else if (w2 <> found) then
            begin
              found := -1;
              Break;
            end;
            e2 := EntryNext[e2];
          end;
          if found = -1 then Break;
        end;
    if found = 0 then found := -1;      { пусто = полный скан (fallback) }
    if OMN * 2 < OMMask then
    begin
      OMKey[slot] := key2;
      OMWay[slot] := found;
      Inc(OMN);
    end;
    if found > 0 then Result := found;
  end;

  procedure EmitTri(MeshI: Integer; const T: TCarveTri; TileK: Int64);
  var
    idx: array[0..2] of Integer;
    q, di, vi: Integer;
    LP: TLatticePoint;
    pos, nrm: TVector3;
    uv: TVector2;
    lu, lv: Single;
    lay: Integer;
    triWay, dummyW: Int64;
    K2: Integer;
    EM: TMesh;
    ucK: Int64;
    ucSlot: Integer;
    cx, cz: Single;
    isBary: Boolean;
  begin
    EM := B.OutMeshes[MeshI].Mesh;      { хойст: без пере-индексаций в ветках }
    lay := Integer(T.Tag) - 1;          { Tag: слой+1, 0 = терраин }
    isBary := (lay >= 0) and (lay <= High(B.Layers))
              and (B.Layers[lay].UVMode = iumBary);
    if isBary and (UCKey = nil) then
    begin
      UCMask := (1 shl 18) - 1;
      SetLength(UCKey, UCMask + 1);
      SetLength(UCWay, UCMask + 1);
      SetLength(UCU, UCMask + 1);
      SetLength(UCV, UCMask + 1);
      SetLength(UCVtx, UCMask + 1);
      SetLength(UCMesh, UCMask + 1);
      for q := 0 to UCMask do UCWay[q] := 0;   { 0 = пустой слот }
      UCN := 0;
    end;
    triWay := 0;
    if isBary then
    begin
      { пер-треугольная когерентность источника: перекрытия лент одного
        материала (перекрёстки, витки скруглений) мешали V разных дорог в
        соседних вершинах — размазанные полосы. Треугольник выбирает ОДНУ
        ленту по центроиду, все три вершины берут UV только из её квадов. }
      cx := (LatToWorld(T.A.X) + LatToWorld(T.B.X) + LatToWorld(T.C.X))
            * Single(1.0/3.0);
      cz := (LatToWorld(T.A.Z) + LatToWorld(T.B.Z) + LatToWorld(T.C.Z))
            * Single(1.0/3.0);
      { мемоизация владельца по бакету (порядко-независимая, точная):
        если все квады в 3x3 бакетах центроида принадлежат ОДНОЙ ленте,
        владелец известен без барицентрических решений — доминирующий
        случай прямых участков; мульти-way бакеты (развязки) честно
        сканируются best-depth. Заменяет prevWay-шорткат без его
        зависимости от порядка эмита. }
      triWay := MemoOwnerOf(lay, cx, cz);
      if triWay = 0 then
        LookupBaryUV(B.Bary[lay], cx, cz, lu, lv, triWay, 0);
    end;
    EM.CurrentOsmId := triWay; { preserve the chosen road owner in cached geometry }
    for q := 0 to 2 do
    begin
      case q of
        0: LP := T.A; 1: LP := T.B; else LP := T.C;
      end;
      if isBary then
      begin
        { bary-материалы: СВЕЖИЕ вершины на треугольник (без словаря) —
          UV пер-треугольно когерентна выбранной ленте, совпавшие
          (позиция+UV) дубли сольёт weld композита, как жил float-тракт;
          позиции канонические — водонепроницаемость не страдает }
        pos.X := LatToWorld(LP.X);
        pos.Y := 0;
        pos.Z := LatToWorld(LP.Z);
        nrm.X := 0; nrm.Y := 1; nrm.Z := 0;
        uv.X := 0; uv.Y := 0;
        ucSlot := -1;
        if triWay <> 0 then
        begin
          ucK := (Int64(LP.X) shl 32) or Int64(Cardinal(LP.Z));
          {$push}{$Q-}{$R-}
          ucSlot := Integer((QWord(ucK) * QWord($9E3779B97F4A7C15)
            + QWord(triWay) * QWord($D1B54A32D192ED03)) shr 40)
            and UCMask;
          {$pop}
          while (UCWay[ucSlot] <> 0)
                and ((UCKey[ucSlot] <> ucK) or (UCWay[ucSlot] <> triWay)) do
            ucSlot := (ucSlot + 1) and UCMask;
          if UCWay[ucSlot] <> 0 then
          begin
            if UCMesh[ucSlot] = MeshI then
            begin
              idx[q] := UCVtx[ucSlot];
              Continue;
            end;
            lu := UCU[ucSlot]; lv := UCV[ucSlot];
            uv.X := lu; uv.Y := lv;
            vi := EM.AddVertex(pos, nrm, uv);
            UCVtx[ucSlot] := vi; UCMesh[ucSlot] := MeshI;
            idx[q] := vi;
            Continue;
          end;
        end;
        { ТЕСТ «дротиков»: фолбэк НИКОГДА не берёт UV у чужой ленты.
          Диагноз по дампу: на Т-стыке двух footway вершина треугольника,
          чей центроид у ленты A, лежала вне полосы A → строгий lookup(A)
          возвращал False → срабатывал lookup(fromWay=0), бравший
          ПЕРПЕНДИКУЛЯРНУЮ ленту B с V≈54 рядом с V≈20 у соседней вершины →
          при драпе текстура растягивалась в «дротик».
          LookupBaryUV с фильтром triWay уже умеет клипнуть вершину к
          ближайшему треугольнику СВОЕЙ ленты (глубинный fallback внутри),
          но выходит с False при строгом первом проходе. Даём ему вернуть
          этот клип: зовём с ослабленным порогом (AMinDepth=-1e9 → примет
          любой лучший-по-глубине треугольник ленты владельца). Общий
          lookup(0) остаётся ТОЛЬКО когда владельца нет (triWay=0). }
        if triWay <> 0 then
        begin
          if not LookupBaryUV(B.Bary[lay], pos.X, pos.Z, lu, lv,
                              dummyW, triWay) then
            LookupBaryUV(B.Bary[lay], pos.X, pos.Z, lu, lv,
                         dummyW, triWay, -1.0e9);
        end
        else
          LookupBaryUV(B.Bary[lay], pos.X, pos.Z, lu, lv, dummyW, 0);
        uv.X := lu; uv.Y := lv;
        vi := EM.AddVertex(pos, nrm, uv);
        if (ucSlot >= 0) and (UCN * 2 < UCMask) then
        begin
          UCKey[ucSlot] := (Int64(LP.X) shl 32) or Int64(Cardinal(LP.Z));
          UCWay[ucSlot] := triWay;
          UCU[ucSlot] := lu; UCV[ucSlot] := lv;
          UCVtx[ucSlot] := vi; UCMesh[ucSlot] := MeshI;
          Inc(UCN);
        end;
      end
      else
      begin
        { угловой узел сетки на пер-ячеечном пути терраина: индекс из
          строчного буфера (арифметика вместо хэша словаря) }
        vi := -1;
        if (FCellIx >= 0) and (lay = -1) then
        begin
          if LP.Z = FCellLZ0 then
          begin
            if LP.X = FCellLX0 then vi := RowA[FCellIx]
            else if LP.X = FCellLX1 then vi := RowA[FCellIx + 1];
          end
          else if LP.Z = FCellLZ1 then
          begin
            if LP.X = FCellLX0 then vi := RowB[FCellIx]
            else if LP.X = FCellLX1 then vi := RowB[FCellIx + 1];
          end;
          if vi >= 0 then
          begin
            idx[q] := vi;
            Continue;
          end;
          if (LP.Z = FCellLZ0) and ((LP.X = FCellLX0) or (LP.X = FCellLX1))
             or (LP.Z = FCellLZ1) and ((LP.X = FCellLX0) or (LP.X = FCellLX1)) then
          begin
            pos.X := LatToWorld(LP.X);
            pos.Y := 0;
            pos.Z := LatToWorld(LP.Z);
            nrm.X := 0; nrm.Y := 1; nrm.Z := 0;
            uv.X := pos.X * B.TerrainInvUV;
            uv.Y := pos.Z * B.TerrainInvUV;
            vi := EM.AddVertex(pos, nrm, uv);
            if LP.Z = FCellLZ0 then
            begin
              if LP.X = FCellLX0 then RowA[FCellIx] := vi
              else RowA[FCellIx + 1] := vi;
            end
            else
            begin
              if LP.X = FCellLX0 then RowB[FCellIx] := vi
              else RowB[FCellIx + 1] := vi;
            end;
            idx[q] := vi;
            Continue;
          end;
        end;
        { явная карта id словаря -> индекс вершины: строчный буфер создаёт
          вершины мимо словаря, старый инвариант id==VertexCount разорван }
        if MeshI >= Length(DictMap) then
          SetLength(DictMap, MeshI * 2 + 8);   { меши растут на лету }
        di := B.MDict[MeshI].IndexOf(LP);
        if di >= Length(DictMap[MeshI]) then
        begin
          K2 := Length(DictMap[MeshI]);
          SetLength(DictMap[MeshI], di * 2 + 64);
          while K2 < Length(DictMap[MeshI]) do
          begin
            DictMap[MeshI][K2] := -1;
            Inc(K2);
          end;
        end;
        vi := DictMap[MeshI][di];
        if vi < 0 then
        begin
          pos.X := LatToWorld(LP.X);
          pos.Y := 0;                   { высоту кладёт drape-проход }
          pos.Z := LatToWorld(LP.Z);
          nrm.X := 0; nrm.Y := 1; nrm.Z := 0;
          uv.X := 0; uv.Y := 0;
          if (lay >= 0) and (lay <= High(B.Layers)) then
          begin
            if B.Layers[lay].UVMode = iumPlanar then
            begin
              uv.X := pos.X * B.Layers[lay].InvUV;
              uv.Y := pos.Z * B.Layers[lay].InvUV;
            end;
          end
          else if lay = -1 then
          begin
            uv.X := pos.X * B.TerrainInvUV;    { терраин: планар }
            uv.Y := pos.Z * B.TerrainInvUV;
          end;
          vi := EM.AddVertex(pos, nrm, uv);
          DictMap[MeshI][di] := vi;
        end;
      end;
      idx[q] := vi;
    end;
    { winding-конвенция эмита старого тракта: CCW-в-XZ кусок кладётся как
      (0, J, J-1), т.е. по часовой в XZ — повторяем: (A, C, B). }
    B.OutMeshes[MeshI].Mesh.AddTriangle(idx[0], idx[2], idx[1]);
    if B.OutMeshes[MeshI].TriKeyCount >= Length(B.OutMeshes[MeshI].TriTileKeys) then
      SetLength(B.OutMeshes[MeshI].TriTileKeys,
        B.OutMeshes[MeshI].TriKeyCount * 2 + 256);
    B.OutMeshes[MeshI].TriTileKeys[B.OutMeshes[MeshI].TriKeyCount] := TileK;
    Inc(B.OutMeshes[MeshI].TriKeyCount);
  end;

  { сторона блока: срез border-таблицы линии (по диапазону, бинпоиском —
    таблицы отсортированы вдоль линии) + углы более мелких соседей
    (граница смены блока соседа => обязательная точка нашей стороны).
    Буферы рост-only. }
  procedure BuildSideX(LineIx, Iz0, Iz1: Integer; NbIx: Integer;
    var Buf: TLatticePointArray; out N: Integer);
  var
    T: TLatticePointArray;
    lo, hi, q, prevOz, oz, nck: Integer;
    P: TLatticePoint;
  begin
    N := 0;
    T := B.Noder.BorderCutsX(LineIx);
    if Length(T) > 0 then
    begin
      lo := 0; hi := Length(T) - 1;
      while (lo <= hi) and (T[lo].Z < B.LZ[Iz0]) do Inc(lo);
      while (hi >= lo) and (T[hi].Z > B.LZ[Iz1]) do Dec(hi);
      for q := lo to hi do
      begin
        if N >= Length(Buf) then SetLength(Buf, N * 2 + 16);
        Buf[N] := T[q];
        Inc(N);
      end;
    end;
    if (NbIx >= 0) and (NbIx < B.CellsX) and (B.Lv <> nil) then
    begin
      prevOz := -1;
      for q := Iz0 to Iz1 - 1 do
      begin
        nck := q * B.CellsX + NbIx;
        oz := q and not ((1 shl B.Lv[nck]) - 1);
        if (oz <> prevOz) and (q > Iz0) then
        begin
          P.X := B.LX[LineIx];
          P.Z := B.LZ[q];
          if N >= Length(Buf) then SetLength(Buf, N * 2 + 16);
          Buf[N] := P;
          Inc(N);
        end;
        prevOz := oz;
      end;
    end;
  end;

  procedure BuildSideZ(LineIz, Ix0, Ix1: Integer; NbIz: Integer;
    var Buf: TLatticePointArray; out N: Integer);
  var
    T: TLatticePointArray;
    lo, hi, q, prevOx, ox, nck: Integer;
    P: TLatticePoint;
  begin
    N := 0;
    T := B.Noder.BorderCutsZ(LineIz);
    if Length(T) > 0 then
    begin
      lo := 0; hi := Length(T) - 1;
      while (lo <= hi) and (T[lo].X < B.LX[Ix0]) do Inc(lo);
      while (hi >= lo) and (T[hi].X > B.LX[Ix1]) do Dec(hi);
      for q := lo to hi do
      begin
        if N >= Length(Buf) then SetLength(Buf, N * 2 + 16);
        Buf[N] := T[q];
        Inc(N);
      end;
    end;
    if (NbIz >= 0) and (NbIz < B.CellsZTot) and (B.Lv <> nil) then
    begin
      prevOx := -1;
      for q := Ix0 to Ix1 - 1 do
      begin
        nck := NbIz * B.CellsX + q;
        ox := q and not ((1 shl B.Lv[nck]) - 1);
        if (ox <> prevOx) and (q > Ix0) then
        begin
          P.X := B.LX[q];
          P.Z := B.LZ[LineIz];
          if N >= Length(Buf) then SetLength(Buf, N * 2 + 16);
          Buf[N] := P;
          Inc(N);
        end;
        prevOx := ox;
      end;
    end;
  end;

  { Крупный блок sz x sz: тот же CarveCell на прямоугольнике блока; стороны
    из таблиц+углов соседей — водонепроницаемость по построению. Материал:
    класс ячейки (254 = терраин без items; иначе один blanket-item
    победителя стека). tileKey — по origin-ячейке блока (превью-тени на
    крупных блоках грубее на размер блока — осознанный компромисс). }
  procedure EmitBlock(Ix0, Iz0, ASz: Integer);
  var
    nW, nE, nN, nS, q: Integer;
    ck0: Integer;
  begin
    FCellIx := -1;                     { блоки мимо строчного буфера }
    ck0 := Iz0 * B.CellsX + Ix0;
    if B.CellCls[ck0] = 253 then
    begin
      { нутро под зданием: блок не порождает ни одного треугольника }
      Inc(B.StatHole, ASz * ASz * 2);
      Exit;
    end;
    BuildSideX(Ix0,       Iz0, Iz0 + ASz, Ix0 - 1,   SideW, nW);
    BuildSideX(Ix0 + ASz, Iz0, Iz0 + ASz, Ix0 + ASz, SideE, nE);
    BuildSideZ(Iz0 + ASz, Ix0, Ix0 + ASz, Iz0 + ASz, SideN, nN);
    BuildSideZ(Iz0,       Ix0, Ix0 + ASz, Iz0 - 1,   SideS, nS);
    SetLength(SideW, nW); SetLength(SideE, nE);
    SetLength(SideN, nN); SetLength(SideS, nS);
    if B.CellCls[ck0] = 254 then
      ItemUse := 0
    else
    begin
      if Length(Items) < 1 then SetLength(Items, 4);
      Items[0].Rings := nil;
      Items[0].BaseWinding := 1;
      Items[0].MatId := B.CellCls[ck0];
      Items[0].ZIndex := B.Layers[B.WinLay[ck0]].ZIndex;
      Items[0].Tag := B.WinLay[ck0] + 1;
      ItemUse := 1;
    end;
    Tris := CarveCell(B.LX[Ix0], B.LZ[Iz0], B.LX[Ix0+ASz], B.LZ[Iz0+ASz],
      SideW, SideE, SideN, SideS,
      Items, ItemUse, B.TerrainMatId, 0);
    if B.FlipX then origIX := B.CellsX - 1 - Ix0 else origIX := Ix0;
    if B.FlipZ then origIZ := B.CellsZTot - 1 - Iz0 else origIZ := Iz0;
    tileKey := PackTileKeyInt(
      Integer(Floor((B.GPX0 + origIX * B.PitchPx) / B.EdgePx)),
      Integer(Floor((B.GPY0 + origIZ * B.PitchPx) / B.EdgePx)));
    for q := 0 to High(Tris) do
    begin
      EmitTri(MatMeshIdx(Tris[q].MatId), Tris[q], tileKey);
      Inc(B.StatTris);
    end;
  end;

begin
  Items := nil;
  PosStarts := nil; PosLens := nil;
  NegStarts := nil; NegLens := nil;
  RingBuf := nil;
  CAEnt := nil; CAExt := nil; CAUsed := nil;
  SetLength(CARing, 64);
  { гейзер ссылок контекста: refcount один раз на полосу, доступ в циклах
    без двойной косвенности через контекст }
  LTrip := B.Trip;
  LOrder := B.Order;
  LOffs := B.Offs;
  OMKey := nil; OMN := 0;
  { прямой MatId-кэш: индекс MatId+1 покрывает -1..126 (материалы 0..
    GROUND_MAT_COUNT-1 плюс GROUND_MAT_HOLE=-1); -1 = слот не заведён.
    Засев из уже существующих мешей делает кэш корректным даже если
    OutMeshes придёт непустым (обычно пуст на входе в полосу). }
  SetLength(MatSlot, 128);
  for I := 0 to High(MatSlot) do MatSlot[I] := -1;
  for I := 0 to High(B.OutMeshes) do
    if (B.OutMeshes[I].MatId + 1 >= 0)
       and (B.OutMeshes[I].MatId + 1 < Length(MatSlot)) then
      MatSlot[B.OutMeshes[I].MatId + 1] := I;
  SetLength(DictMap, Length(B.OutMeshes) + 8);
  SetLength(RowA, B.CellsX + 1);
  SetLength(RowB, B.CellsX + 1);
  for I := 0 to B.CellsX do begin RowA[I] := -1; RowB[I] := -1; end;
  rowIz := -100;
  FCellIx := -1;
  for iz := B.Z0 to B.Z1 - 1 do
    for ix := 0 to B.CellsX - 1 do
    begin
      { At most one row before cooperative shutdown. Do not raise here:
        band output remains owned by CarveGroundInt until all workers join. }
      if (ix = 0) and (B.Cancel <> nil) and B.Cancel^ then Exit;
      ck := iz * B.CellsX + ix;
      Inc(B.StatCells);
      { нутро под зданием: ячейка не эмитится вовсе (крыша сверху, стены
        по периметру); пограничные ячейки остаются обычными }
      if (B.HoleCell <> nil) and (B.HoleCell[ck] <> 0) then
      begin
        Inc(B.StatHole, 2);
        Continue;
      end;
      { RQT: ячейка внутри крупного блока — эмитится только origin }
      if (B.Lv <> nil) and (B.Lv[ck] > 0) then
      begin
        sz := 1 shl B.Lv[ck];
        if ((ix and (sz - 1)) <> 0) or ((iz and (sz - 1)) <> 0) then
        begin
          Inc(B.StatCoarse);
          Continue;
        end;
        EmitBlock(ix, iz, sz);
        Inc(B.StatBlocks);
        Continue;
      end;
      cellArcs := False;
      run := LOffs[ck];
      itemN := LOffs[ck+1] - run;
      ItemUse := 0;
      I := 0;
      while I < itemN do
      begin
        li := LTrip[LOrder[run + I]].Layer;
        K := I;
        posN := 0; negN := 0; BaseW := 0;
        while K < itemN do
        begin
          pTR := @LTrip[LOrder[run + K]];
          if pTR^.Layer <> li then Break;
          aLen := pTR^.ArcLen;
          if aLen <> 0 then cellArcs := True;
          if aLen = 0 then
            Inc(BaseW, pTR^.ArcStart)
          else if aLen > 0 then
          begin
            if posN >= Length(PosStarts) then
            begin
              SetLength(PosStarts, posN * 2 + 8);
              SetLength(PosLens, posN * 2 + 8);
              SetLength(PosRing, posN * 2 + 8);
            end;
            PosStarts[posN] := pTR^.ArcStart;
            PosLens[posN] := aLen;
            PosRing[posN] := pTR^.RingId;
            Inc(posN);
          end
          else
          begin
            if negN >= Length(NegStarts) then
            begin
              SetLength(NegStarts, negN * 2 + 8);
              SetLength(NegLens, negN * 2 + 8);
              SetLength(NegRing, negN * 2 + 8);
            end;
            NegStarts[negN] := pTR^.ArcStart;
            NegLens[negN] := -aLen;
            NegRing[negN] := pTR^.RingId;
            Inc(negN);
          end;
          Inc(K);
        end;
        if posN + negN + 2 > Length(RingBuf) then
          SetLength(RingBuf, posN + negN + 8);
        outRN := 0;
        { сцепка пер-исходному-кольцу: дуги разных колец в ячейке
          перекрытия пересекаются внутри неё — смешанная сцепка рождала
          самопересекающиеся/CW-кольца, триангулятор их отбрасывал, слой
          пропадал («квадрат травы» на перекрытиях лент) }
        if posN > 0 then
        begin
          SortArcsByRing(PosStarts, PosLens, PosRing, posN);
          grpA := 0;
          while grpA < posN do
          begin
            grpB := grpA;
            while (grpB < posN) and (PosRing[grpB] = PosRing[grpA]) do
              Inc(grpB);
            CloseArcsToRingsSub(B.LX[ix], B.LZ[iz], B.LX[ix+1], B.LZ[iz+1],
              PosStarts, PosLens, grpA, grpB - grpA, 1, RingBuf, outRN);
            grpA := grpB;
          end;
        end;
        if negN > 0 then
        begin
          SortArcsByRing(NegStarts, NegLens, NegRing, negN);
          grpA := 0;
          while grpA < negN do
          begin
            grpB := grpA;
            while (grpB < negN) and (NegRing[grpB] = NegRing[grpA]) do
              Inc(grpB);
            CloseArcsToRingsSub(B.LX[ix], B.LZ[iz], B.LX[ix+1], B.LZ[iz+1],
              NegStarts, NegLens, grpA, grpB - grpA, -1, RingBuf, outRN);
            grpA := grpB;
          end;
        end;
        if (outRN > 0) or (BaseW <> 0) then
        begin
          if ItemUse >= Length(Items) then
            SetLength(Items, ItemUse * 2 + 8);
          with Items[ItemUse] do
          begin
            Rings := Copy(RingBuf, 0, outRN);
            BaseWinding := BaseW;
            MatId := B.Layers[li].MatId;
            ZIndex := B.Layers[li].ZIndex;
            Tag := li + 1;
          end;
          Inc(ItemUse);
        end;
        I := K;
      end;
      if itemN = 0 then Inc(B.StatEmpty);

      if iz <> rowIz then
      begin
        { новая строка: верхние узлы прошлой строки становятся нижними }
        if iz = rowIz + 1 then
        begin
          RowSwp := RowA; RowA := RowB; RowB := RowSwp;
        end
        else
          for I := 0 to B.CellsX do RowA[I] := -1;
        for I := 0 to B.CellsX do RowB[I] := -1;
        rowIz := iz;
        BZbot := B.Noder.BorderCutsZ(iz);
        BZtop := B.Noder.BorderCutsZ(iz + 1);
        BXr := B.Noder.BorderCutsX(ix);   { левая линия первой ячейки строки }
        bxIx := ix;
      end;
      if bxIx <> ix then
      begin
        BXl := BXr;                        { сдвиг: право прошлой = лево этой }
        BXr := B.Noder.BorderCutsX(ix + 1);
        bxIx := ix;
      end
      else
      begin
        BXl := BXr;
        BXr := B.Noder.BorderCutsX(ix + 1);
      end;
      FCellIx := ix;
      FCellLX0 := B.LX[ix];  FCellLX1 := B.LX[ix+1];
      FCellLZ0 := B.LZ[iz];  FCellLZ1 := B.LZ[iz+1];
      { fast-path: ни дуг, ни катов соседей на 4 сторонах — ячейка
        тривиальна (телеметрия: CarveCell = 57% карва, а он гонял полный
        триангулятор и для таких). Победитель — верхний blanket-слой
        (items уже в порядке убывания ZIndex), иначе терраин; семантика
        тождественна CarveCell при пустых входах. }
      if (not cellArcs)
         and not CutsInsideX(BXl, FCellLZ0, FCellLZ1)
         and not CutsInsideX(BXr, FCellLZ0, FCellLZ1)
         and not CutsInsideZ(BZbot, FCellLX0, FCellLX1)
         and not CutsInsideZ(BZtop, FCellLX0, FCellLX1) then
      begin
        fMat := B.TerrainMatId; fTag := 0;
        for K := 0 to ItemUse - 1 do
          if Items[K].BaseWinding <> 0 then
          begin
            fMat := Items[K].MatId;
            fTag := Items[K].Tag;
            Break;
          end;
        if fMat <> GROUND_MAT_HOLE then
        begin
          if B.FlipX then origIX := B.CellsX - 1 - ix else origIX := ix;
          if B.FlipZ then origIZ := B.CellsZTot - 1 - iz else origIZ := iz;
          tileKey := PackTileKeyInt(
            Integer(Floor((B.GPX0 + origIX * B.PitchPx) / B.EdgePx)),
            Integer(Floor((B.GPY0 + origIZ * B.PitchPx) / B.EdgePx)));
          FastTri.MatId := fMat;
          FastTri.Tag := fTag;
          FastTri.A.X := FCellLX0; FastTri.A.Z := FCellLZ0;
          FastTri.B.X := FCellLX1; FastTri.B.Z := FCellLZ0;
          FastTri.C.X := FCellLX1; FastTri.C.Z := FCellLZ1;
          EmitTri(MatMeshIdx(fMat), FastTri, tileKey);
          FastTri.B.X := FCellLX1; FastTri.B.Z := FCellLZ1;
          FastTri.C.X := FCellLX0; FastTri.C.Z := FCellLZ1;
          EmitTri(MatMeshIdx(fMat), FastTri, tileKey);
          Inc(B.StatTris, 2);
        end
        else
          Inc(B.StatHole, 2);
        Continue;
      end;
      Tris := CarveCell(B.LX[ix], B.LZ[iz], B.LX[ix+1], B.LZ[iz+1],
        B.Noder.BorderCutsX(ix), B.Noder.BorderCutsX(ix+1),
        B.Noder.BorderCutsZ(iz+1), B.Noder.BorderCutsZ(iz),
        Items, ItemUse, B.TerrainMatId, 0);

      if B.FlipX then origIX := B.CellsX - 1 - ix else origIX := ix;
      if B.FlipZ then origIZ := B.CellsZTot - 1 - iz else origIZ := iz;
      tileKey := PackTileKeyInt(
        Integer(Floor((B.GPX0 + origIX * B.PitchPx) / B.EdgePx)),
        Integer(Floor((B.GPY0 + origIZ * B.PitchPx) / B.EdgePx)));
      for K := 0 to High(Tris) do
      begin
        if Tris[K].MatId = GROUND_MAT_HOLE then
        begin
          Inc(B.StatHole);
          Continue;
        end;
        EmitTri(MatMeshIdx(Tris[K].MatId), Tris[K], tileKey);
        Inc(B.StatTris);
      end;
    end;
end;

type
  TCarveBandCtxArray = array of TCarveBandCtx;

  PCarveBandDispatch = ^TCarveBandDispatch;
  TCarveBandDispatch = record
    Bands: TCarveBandCtxArray;   { общая ссылка на динмассив полос (refcount) }
    Count: Integer;
    Next:  Integer;              { атомарный курсор следующей полосы }
    Done: Integer;
    Progress: TGenerationProgressEvent;
    { первая ошибка воркера: FailSet 0->1 first-wins (InterlockedCompareExchange),
      сообщение пишет только победивший поток; читается после WaitFor всех }
    FailSet: Integer;
    FailMsg: string;
  end;

  { Воркер карв-полос: тянет следующую полосу из общей очереди, пока они есть.
    И воркеры, и ВЫЗЫВАЮЩИЙ поток тянут из одной очереди -> все полосы будут
    обработаны при любом числе допущенных воркеров (в т.ч. нуле), без потери
    работы и дедлока. Порядок обработки не важен: merge ниже идёт по bi=0..nB-1
    независимо от него, поэтому выход побайтово тот же при любой конкуренции. }
  TCarveBandThread = class(TThread)
  private
    FDisp: PCarveBandDispatch;
  protected
    procedure Execute; override;
  public
    constructor Create(ADisp: PCarveBandDispatch);
  end;

{ разбор общей очереди полос (вызывается и воркерами, и вызывающим потоком) }
procedure CarveDrainBands(Disp: PCarveBandDispatch);
var i, Completed: Integer;
begin
  repeat
    i := InterlockedExchangeAdd(Disp^.Next, 1);
    if i >= Disp^.Count then Break;
    if (Disp^.Bands[i].Cancel <> nil) and Disp^.Bands[i].Cancel^ then Break;
    CarveBandCells(Disp^.Bands[i]);
    Completed := InterlockedIncrement(Disp^.Done);
    if Assigned(Disp^.Progress) then
      Disp^.Progress('Ground strips', Completed, Disp^.Count);
  until False;
end;

constructor TCarveBandThread.Create(ADisp: PCarveBandDispatch);
begin
  FDisp := ADisp;
  inherited Create(False);
end;

procedure TCarveBandThread.Execute;
begin
  { Исключение НЕ должно уходить из Execute: FPC в этом случае гробит поток
    мимо аккуратного завершения, а вызывающий ниже ждёт WaitFor'ом и
    отпускает допуск пула (PoolReleaseWorker) — сбойный поток терял бы
    допуск навсегда. Ошибку не прячем: первая фиксируется в Disp и
    попадает в AStats.Fail вызывающего. }
  try
    CarveDrainBands(FDisp);
  except
    on E: Exception do
      if InterlockedCompareExchange(FDisp^.FailSet, 1, 0) = 0 then
        FDisp^.FailMsg := E.ClassName + ': ' + E.Message;
  end;
end;

procedure CarveGroundInt(
  const AGrid: TTerrainGrid;
  AProjection: TLocalProjection;
  var ALayers: array of TIntCaptureLayer;
  ATerrainMatId: Integer;
  ATerrainInvUV: Single;
  AEdgePx: Integer;
  out OutMeshes: TCarvedMatMeshArray;
  out AStats: TCarveGroundStats;
  AThreads: Integer;
  const ARoadLevel: TBytes;
  ADecimMaxLevel: Integer;
  const AHoleMask: TBytes;
  ASampler: TTerrainSampler);
var
  t0: QWord;
  LX, LZ: array of Int32;              { квантованные линии сетки }
  NXL, NZL, CellsX, CellsZ, CellCount: Integer;
  Noder: TLatticeNoder;
  SegL, SegR: array of Integer;        { seg -> (layer, ring) }
  SegN: Integer;
  NRings: array of array of TLatRing;  { пересобранные кольца }
  { Trip: пер-ячейковая работа. ArcLen>0 — дуга кольца (точки в ArcPool);
    ArcLen=0 — blanket-вклад (ArcStart = знак +1/-1). }
  Trip: TTripArray;
  TripN: Integer;
  ArcPool: TLatticePointArray;
  ArcPoolN: Integer;
  Counts, Offs, Order, Fill: array of Integer;
  RUsed: array of array of Integer;
  Ch: TLatticePointArray;
  TouchKey: array of Integer;          { open-hash ячеек, тронутых дугами кольца }
  TouchVer: array of Integer;          { эпоха слота: валиден при = TouchCur }
  TouchCap, TouchN, TouchCur: Integer;
  RowHead, RowNext: array of Integer;  { пер-строчные списки parity-колонок }
  RowColV: array of Integer;
  RowColS: array of ShortInt;          { знак пересечения: направление ребра по Z }
  RowN, RowListN: Integer;
  TouchedRows: array of Integer;
  TouchedRowN: Integer;
  RingSign: Integer;
  a2ring: Int64;
  nB, bi: Integer;
  LvA, ClsA, WinA, HoleA: TBytes;
  hIx, hIz: Integer;             { пер-ячейковые уровни/классы }
  UniCls, UniPrev: array of Int32;     { uniform-класс блока уровня L }
  MinRL, MinRLPrev: TBytes;            { min дорожного поля по блоку }
  DecMax, Lq, bw, bh, bx, bz, cix, ciz, cls0: Integer;
  haveRL: Boolean;
  blockAlign: Integer;
  Bands: TCarveBandCtxArray;
  BThreads: array of TCarveBandThread;
  Disp: TCarveBandDispatch;
  made: Integer;
  LayersRef: TIntCaptureLayerArray;
  PosStarts, PosLens, NegStarts, NegLens: array of Integer;
  posN, negN, BaseW, outRN, aLen, ItemUse: Integer;
  RingBuf: array of TLatRing;
  CAEnt, CAExt: array of Int64;
  CAUsed: array of Boolean;
  CARing: TLatRing;
  Bary: TBaryIndexArray;
  ClMinX, ClMaxX, ClMinZ, ClMaxZ: Single;   { клип bary-сетки по bbox колец слоя }
  I, J, K, R, ix0, ix1, iz0, iz1, ix, iz, ck, run, itemN, li: Integer;
  FlipX, FlipZ: Boolean;
  origIX, origIZ: Integer;
  tmpq: Int32;
  GMinX, GMaxX, GMinZ, GMaxZ: Int32;   { клип-прямоугольник (сетка ± CLIP_MARGIN) }
  ClipN, DropN, BlankN, WR: Integer;
  Ring: TLatRing;
  rbX0, rbX1, rbZ0, rbZ1: Int32;
  P: TLatLon;
  W: TVector3;
  Items: TCarveItemArray;
  Tris: TCarveTriArray;
  tileKey: Int64;

  function BlockFollowsTerrain(X0, Z0, Size: Integer): Boolean;
  const
    { All retained and omitted nodes must be close to ONE plane. Thus
      any triangulation of the retained boundary stays within twice this
      error of the original piecewise-linear terrain, including steep slopes. }
    MAX_PLANE_ERROR_M = 0.25;
  var
    X, Z: Integer;
    H0, DX, DZ, RowH, Actual: Double;
    function HeightAt(AX, AZ: Integer): Single; inline;
    begin
      if FlipX then AX := NXL - 1 - AX;
      if FlipZ then AZ := NZL - 1 - AZ;
      Result := ASampler.NodeHeight(AX, AZ);
    end;
  begin
    Result := False;
    if (ASampler = nil) or (ASampler.GridX <> NXL) or
       (ASampler.GridZ <> NZL) then Exit;
    H0 := HeightAt(X0, Z0);
    DX := (HeightAt(X0 + Size, Z0) - H0) / (LX[X0 + Size] - LX[X0]);
    DZ := (HeightAt(X0, Z0 + Size) - H0) / (LZ[Z0 + Size] - LZ[Z0]);
    for Z := Z0 to Z0 + Size do
    begin
      RowH := H0 + DZ * (LZ[Z] - LZ[Z0]);
      for X := X0 to X0 + Size do
      begin
        Actual := HeightAt(X, Z);
        if IsNan(Actual) or IsInfinite(Actual) or
           (Abs(Actual - (RowH + DX * (LX[X] - LX[X0]))) > MAX_PLANE_ERROR_M) then
        begin
          Inc(AStats.DecimHeightRejected);
          Exit;
        end;
      end;
    end;
    Result := True;
  end;

  { колонка/строка по УДВОЕННОЙ координате midpoint'а сегмента.
    OnLine=True: mid ровно на внутренней линии idx (сегмент вдоль неё) —
    вызывающий берёт МЕНЬШУЮ смежную ячейку. Вне сетки — -1. }
  function ColOf2(Mid2: Int64; const L: array of Int32; N: Integer;
    out OnLine: Boolean; out LineIdx: Integer): Integer;
  var lo, hi, mid: Integer;
  begin
    OnLine := False; LineIdx := -1;
    if (Mid2 < Int64(L[0]) * 2) or (Mid2 > Int64(L[N-1]) * 2) then Exit(-1);
    { последний i с 2*L[i] <= Mid2 }
    lo := 0; hi := N - 1; Result := 0;
    while lo <= hi do
    begin
      mid := (lo + hi) div 2;
      if Int64(L[mid]) * 2 <= Mid2 then begin Result := mid; lo := mid + 1; end
      else hi := mid - 1;
    end;
    if Int64(L[Result]) * 2 = Mid2 then
    begin
      OnLine := True; LineIdx := Result;
      if Result > 0 then Dec(Result);    { вдоль линии — левая/нижняя ячейка }
      if Result > N - 2 then Result := N - 2;
    end
    else if Result > N - 2 then
      Exit(-1);                          { ровно на правой рамке уйти некуда }
  end;

  { хэш тронутых ячеек: сброс O(1) сменой эпохи, рост удвоением с
    пересыпкой живых — гигантское кольцо (периметр в тысячи ячеек)
    раньше заполняло фиксированную таблицу и зацикливало probing }
  procedure TouchReset;
  begin
    Inc(TouchCur);
    TouchN := 0;
  end;
  procedure TouchGrow;
  var
    OldKey, OldVer: array of Integer;
    oc, q, h2: Integer;
  begin
    OldKey := TouchKey; OldVer := TouchVer;
    oc := TouchCap;
    TouchCap := TouchCap * 2;
    TouchKey := nil; TouchVer := nil;
    SetLength(TouchKey, TouchCap);
    SetLength(TouchVer, TouchCap);
    for q := 0 to oc - 1 do
      if OldVer[q] = TouchCur then
      begin
        h2 := (OldKey[q] * 2654435761) and (TouchCap - 1);
        while TouchVer[h2] = TouchCur do
          h2 := (h2 + 1) and (TouchCap - 1);
        TouchKey[h2] := OldKey[q];
        TouchVer[h2] := TouchCur;
      end;
  end;
  procedure TouchAdd(CK: Integer);
  var h: Integer;
  begin
    if (TouchN + 1) * 2 >= TouchCap then TouchGrow;
    h := (CK * 2654435761) and (TouchCap - 1);
    while TouchVer[h] = TouchCur do
    begin
      if TouchKey[h] = CK then Exit;
      h := (h + 1) and (TouchCap - 1);
    end;
    TouchKey[h] := CK;
    TouchVer[h] := TouchCur;
    Inc(TouchN);
  end;
  function TouchHas(CK: Integer): Boolean;
  var h: Integer;
  begin
    h := (CK * 2654435761) and (TouchCap - 1);
    while TouchVer[h] = TouchCur do
    begin
      if TouchKey[h] = CK then Exit(True);
      h := (h + 1) and (TouchCap - 1);
    end;
    Result := False;
  end;

  { тайл ячейки по осям (в ИСХОДНЫХ узловых индексах, с учётом флипов) —
    ячейка целиком лежит в одном тайле по построению решётки }
  function TileXOfCell(AIx: Integer): Integer;
  var o: Integer;
  begin
    if FlipX then o := CellsX - 1 - AIx else o := AIx;
    Result := Integer(Floor((AGrid.GPX0 + o * AGrid.PitchPx) / AEdgePx));
  end;
  function TileZOfCell(AIz: Integer): Integer;
  var o: Integer;
  begin
    if FlipZ then o := CellsZ - 1 - AIz else o := AIz;
    Result := Integer(Floor((AGrid.GPY0 + o * AGrid.PitchPx) / AEdgePx));
  end;

  { ячейка целиком под зданием: все 4 узла в узловой маске (флипы осей
    как у дорожного поля — маска строится до нормализации) }
  function HoleCellOf(const HM: TBytes; AIx, AIz: Integer): Boolean;
  var nx0, nz0: Integer;
  begin
    if FlipX then nx0 := NXL - 2 - AIx else nx0 := AIx;
    if FlipZ then nz0 := NZL - 2 - AIz else nz0 := AIz;
    Result := (HM[nz0 * NXL + nx0] <> 0)
      and (HM[nz0 * NXL + nx0 + 1] <> 0)
      and (HM[(nz0 + 1) * NXL + nx0] <> 0)
      and (HM[(nz0 + 1) * NXL + nx0 + 1] <> 0);
  end;

  { min узлового дорожного поля по 4 углам ячейки (в ИСХОДНЫХ индексах
    узлов — поле построено до нормализации осей) }
  function RLOfCell(const RL: TBytes; AIx, AIz: Integer): Byte;
  var
    nx0, nz0, q, w: Integer;
    v: Byte;
  begin
    if FlipX then nx0 := NXL - 2 - AIx else nx0 := AIx;
    if FlipZ then nz0 := NZL - 2 - AIz else nz0 := AIz;
    Result := 255;
    for q := 0 to 1 do
      for w := 0 to 1 do
      begin
        v := RL[(nz0 + q) * NXL + (nx0 + w)];
        if v < Result then Result := v;
      end;
  end;

  procedure PushTrip(ACell, ALayer, AStart, ALen: Integer;
    ARingId: Integer = 0);
  begin
    if TripN >= Length(Trip) then SetLength(Trip, TripN * 2 + 64);
    Trip[TripN].CellKey := ACell;
    Trip[TripN].Layer := ALayer;
    Trip[TripN].ArcStart := AStart;
    Trip[TripN].ArcLen := ALen;
    Trip[TripN].RingId := ARingId;
    Inc(TripN);
  end;
  procedure PoolPush(const P0: TLatticePoint);
  begin
    if ArcPoolN >= Length(ArcPool) then SetLength(ArcPool, ArcPoolN * 2 + 256);
    ArcPool[ArcPoolN] := P0;
    Inc(ArcPoolN);
  end;

  { сегмент -> ячейка его midpoint'а (-1 = вне сетки / деген) }
  function SegCell(const A0, B0: TLatticePoint): Integer;
  var
    cx2, cz2, lix2, liz2: Integer;
    onx2, onz2: Boolean;
  begin
    cx2 := ColOf2(Int64(A0.X) + B0.X, LX, NXL, onx2, lix2);
    cz2 := ColOf2(Int64(A0.Z) + B0.Z, LZ, NZL, onz2, liz2);
    if (cx2 < 0) or (cz2 < 0) then Exit(-1);
    Result := cz2 * CellsX + cx2;
  end;

  { один проход кольца: склейка сегментов одной ячейки в дуги (ArcPool),
    ротация старта до первого перехода границы; кольцо целиком в одной
    ячейке — единственная замкнутая дуга (последняя точка == первой) }
  procedure CutRingToArcs(const Ring: TLatRing; LayerIdx: Integer;
    ARingId: Integer);
  var
    NR2, k2, kk, startk, ck, curCell, arcStart, arcLen: Integer;
  begin
    NR2 := Length(Ring);
    ck := SegCell(Ring[0], Ring[1 mod NR2]);
    startk := -1;
    for k2 := 1 to NR2 - 1 do
      if SegCell(Ring[k2], Ring[(k2+1) mod NR2]) <> ck then
      begin
        startk := k2;
        Break;
      end;
    if startk < 0 then
    begin
      { всё кольцо в одной ячейке (или всё вне сетки) }
      if ck < 0 then Exit;
      TouchAdd(ck);
      arcStart := ArcPoolN;
      for k2 := 0 to NR2 - 1 do PoolPush(Ring[k2]);
      PoolPush(Ring[0]);                       { явное замыкание }
      PushTrip(ck, LayerIdx, arcStart, (NR2 + 1) * RingSign, ARingId);
      Exit;
    end;
    curCell := -1; arcStart := 0; arcLen := 0;
    for kk := 0 to NR2 - 1 do
    begin
      k2 := (startk + kk) mod NR2;
      ck := SegCell(Ring[k2], Ring[(k2+1) mod NR2]);
      if ck <> curCell then
      begin
        if (curCell >= 0) and (arcLen >= 2) then
        begin
          TouchAdd(curCell);
          PushTrip(curCell, LayerIdx, arcStart, arcLen * RingSign, ARingId);
        end;
        curCell := ck;
        arcStart := ArcPoolN;
        arcLen := 0;
        if ck >= 0 then
        begin
          PoolPush(Ring[k2]);
          arcLen := 1;
        end;
      end;
      if curCell >= 0 then
      begin
        PoolPush(Ring[(k2+1) mod NR2]);
        Inc(arcLen);
      end;
    end;
    if (curCell >= 0) and (arcLen >= 2) then
    begin
      TouchAdd(curCell);
      PushTrip(curCell, LayerIdx, arcStart, arcLen * RingSign, ARingId);
    end;
  end;

  { parity-blanket: пересечения рёбер кольца с полуцелыми строками
    2Zc = 2*LZ[iz]+1; ячейки с нечётной чётностью и БЕЗ дуг кольца
    получают BaseWinding-вклад ASign }
  { nonzero-blanket: пересечения полуцелых строк со ЗНАКОМ направления
    ребра; интервалы заливаются при накопленном winding <> 0. Прежний
    even-odd (чётные интервалы) давал ДЫРУ там, где лента накладывалась
    сама на себя (разворотная петля, острый крюк на конце): чётность зоны
    двойного покрытия = 0 — и перекрывающие дороги «гасли». Nonzero даёт
    winding 2 -> покрыто; inner-кольца мультиполигонов — отдельные кольца
    со своим ASign, их вычитание не меняется. }
  procedure BlanketRing(const Ring: TLatRing; LayerIdx, ASign: Integer);
  var
    NR2, k2, iz, izLo, izHi, col, lo2, hi2, mid2, ci, ti, cnt, ix: Integer;
    A0, B0: TLatticePoint;
    zLo, zHi: Int32;
    dz2, t2, numX, lhs: Int64;
    Cols: array of Integer;
    Sgns: array of ShortInt;
    wnd: Integer;
    tmpc, a3, b3, fromC, toC: Integer;
    tmps: ShortInt;
  begin
    NR2 := Length(Ring);
    TouchedRowN := 0;
    for k2 := 0 to NR2 - 1 do
    begin
      A0 := Ring[k2];
      B0 := Ring[(k2+1) mod NR2];
      if A0.Z = B0.Z then Continue;
      if A0.Z < B0.Z then begin zLo := A0.Z; zHi := B0.Z; end
      else begin zLo := B0.Z; zHi := A0.Z; end;
      izLo := LatLowerBound(LZ, NZL, zLo);
      izHi := LatUpperBound(LZ, NZL, zHi - 1);
      if izHi > CellsZ - 1 then izHi := CellsZ - 1;
      dz2 := 2 * (Int64(B0.Z) - A0.Z);
      for iz := izLo to izHi do
      begin
        t2 := Int64(LZ[iz]) * 2 + 1 - Int64(A0.Z) * 2;
        numX := Int64(A0.X) * dz2 + (Int64(B0.X) - A0.X) * t2;
        lo2 := 0; hi2 := NXL - 1; col := 0;
        while lo2 <= hi2 do
        begin
          mid2 := (lo2 + hi2) div 2;
          lhs := Int64(LX[mid2]) * dz2;
          if ((dz2 > 0) and (lhs <= numX)) or
             ((dz2 < 0) and (lhs >= numX)) then
          begin
            col := mid2 + 1;
            lo2 := mid2 + 1;
          end
          else
            hi2 := mid2 - 1;
        end;
        if RowHead[iz] < 0 then
        begin
          if TouchedRowN >= Length(TouchedRows) then
            SetLength(TouchedRows, TouchedRowN * 2 + 16);
          TouchedRows[TouchedRowN] := iz;
          Inc(TouchedRowN);
        end;
        if RowListN >= Length(RowNext) then
        begin
          SetLength(RowNext, RowListN * 2 + 256);
          SetLength(RowColV, RowListN * 2 + 256);
          SetLength(RowColS, RowListN * 2 + 256);
        end;
        RowColV[RowListN] := col;
        if dz2 > 0 then RowColS[RowListN] := 1
        else RowColS[RowListN] := -1;
        RowNext[RowListN] := RowHead[iz];
        RowHead[iz] := RowListN;
        Inc(RowListN);
      end;
    end;
    SetLength(Cols, 16);
    SetLength(Sgns, 16);
    for ti := 0 to TouchedRowN - 1 do
    begin
      iz := TouchedRows[ti];
      cnt := 0;
      ci := RowHead[iz];
      while ci >= 0 do
      begin
        if cnt >= Length(Cols) then
        begin
          SetLength(Cols, cnt * 2 + 16);
          SetLength(Sgns, cnt * 2 + 16);
        end;
        Cols[cnt] := RowColV[ci];
        Sgns[cnt] := RowColS[ci];
        Inc(cnt);
        ci := RowNext[ci];
      end;
      RowHead[iz] := -1;
      for a3 := 1 to cnt - 1 do
      begin
        tmpc := Cols[a3];
        tmps := Sgns[a3];
        b3 := a3 - 1;
        while (b3 >= 0) and (Cols[b3] > tmpc) do
        begin
          Cols[b3+1] := Cols[b3];
          Sgns[b3+1] := Sgns[b3];
          Dec(b3);
        end;
        Cols[b3+1] := tmpc;
        Sgns[b3+1] := tmps;
      end;
      wnd := 0;
      for a3 := 0 to cnt - 1 do
      begin
        wnd := wnd + Sgns[a3];
        if (wnd <> 0) and (a3 + 1 < cnt) then
        begin
          fromC := Cols[a3];
          toC := Cols[a3 + 1] - 1;
          if fromC < 0 then fromC := 0;
          if toC > CellsX - 1 then toC := CellsX - 1;
          for ix := fromC to toC do
            if not TouchHas(iz * CellsX + ix) then
              PushTrip(iz * CellsX + ix, LayerIdx, ASign, 0);
        end;
      end;
    end;
  end;

begin
  t0 := GetTickCount64;
  FillChar(AStats, SizeOf(AStats), 0);
  AStats.Fail := '';
  AStats.Warn := '';
  OutMeshes := nil;
  if (not AGrid.Valid) or (AGrid.NX < 2) or (AGrid.NZ < 2) then
  begin
    AStats.Fail := Format('grid invalid (valid=%d NX=%d NZ=%d)',
      [Ord(AGrid.Valid), AGrid.NX, AGrid.NZ]);
    Exit;
  end;

  { 1. линии сетки: квантованная проекция узлов, один раз на чанк.
       Сетка осепараллельна (slippy-решётка в локальном Меркаторе):
       X зависит только от JX, Z — только от JZ. Направление осей —
       ЛЮБОЕ: slippy-пиксель Y растёт на юг, поэтому Z по IZ обычно
       убывает; каждая ось нормализуется реверсом (FlipX/FlipZ), а ключи
       тайлов считаются по ИСХОДНОМУ узловому индексу. }
  SetLength(LayersRef, Length(ALayers));
  for I := 0 to High(ALayers) do LayersRef[I] := ALayers[I];
  NXL := AGrid.NX; NZL := AGrid.NZ;
  SetLength(LX, NXL); SetLength(LZ, NZL);
  for I := 0 to NXL - 1 do
  begin
    P := TerrainGridNodeLatLon(AGrid, I, 0);
    W := AProjection.Project(P, 0);
    LX[I] := LatQuant(W.X);
  end;
  for I := 0 to NZL - 1 do
  begin
    P := TerrainGridNodeLatLon(AGrid, 0, I);
    W := AProjection.Project(P, 0);
    LZ[I] := LatQuant(W.Z);
  end;
  FlipX := (NXL >= 2) and (LX[1] < LX[0]);
  if FlipX then
    for I := 0 to NXL div 2 - 1 do
    begin
      tmpq := LX[I]; LX[I] := LX[NXL-1-I]; LX[NXL-1-I] := tmpq;
    end;
  FlipZ := (NZL >= 2) and (LZ[1] < LZ[0]);
  if FlipZ then
    for I := 0 to NZL div 2 - 1 do
    begin
      tmpq := LZ[I]; LZ[I] := LZ[NZL-1-I]; LZ[NZL-1-I] := tmpq;
    end;
  for I := 1 to NXL - 1 do
    if LX[I] <= LX[I-1] then
    begin
      AStats.Fail := Format('grid X non-monotone at %d (%d..%d)',
        [I, LX[I-1], LX[I]]);
      Exit;
    end;
  for I := 1 to NZL - 1 do
    if LZ[I] <= LZ[I-1] then
    begin
      AStats.Fail := Format('grid Z non-monotone at %d (%d..%d)',
        [I, LZ[I-1], LZ[I]]);
      Exit;
    end;
  CellsX := NXL - 1; CellsZ := NZL - 1;
  CellCount := CellsX * CellsZ;

  { Клиппинг колец к сетке ± CLIP_MARGIN_UNITS перед нодингом (см. блок
    хелперов выше): убирает макро-релейшены/битые way'и с точками за
    сотни-тысячи км — иначе нодер либо раздувает бакеты (страховочный
    кламп), либо виснет на попарной проверке в краевых бакетах. }
  GMinX := LX[0] - CLIP_MARGIN_UNITS; GMaxX := LX[NXL - 1] + CLIP_MARGIN_UNITS;
  GMinZ := LZ[0] - CLIP_MARGIN_UNITS; GMaxZ := LZ[NZL - 1] + CLIP_MARGIN_UNITS;
  ClipN := 0; DropN := 0; BlankN := 0;
  for I := 0 to High(ALayers) do
  begin
    WR := 0;
    for R := 0 to High(ALayers[I].Rings) do
    begin
      Ring := ALayers[I].Rings[R];
      if Length(Ring) < 3 then Continue;          { пустое/деген — выбросить }
      { СВОЯ копия буфера: ниже кольцо мутируется (LatClampRing, blanket-
        SetLength), а присваивание динмассива выше делило буфер с
        ALayers[I].Rings[R] (refcount>1) — запись по элементу НЕ делает
        COW и портила бы исходное кольцо слоя. }
      Ring := Copy(Ring);
      LatClampRing(Ring);                          { антимеридиан-мусор }
      rbX0 := Ring[0].X; rbX1 := rbX0;
      rbZ0 := Ring[0].Z; rbZ1 := rbZ0;
      for K := 1 to High(Ring) do
      begin
        if Ring[K].X < rbX0 then rbX0 := Ring[K].X
        else if Ring[K].X > rbX1 then rbX1 := Ring[K].X;
        if Ring[K].Z < rbZ0 then rbZ0 := Ring[K].Z
        else if Ring[K].Z > rbZ1 then rbZ1 := Ring[K].Z;
      end;
      if (rbX1 < GMinX) or (rbX0 > GMaxX) or (rbZ1 < GMinZ) or (rbZ0 > GMaxZ) then
      begin
        { bbox вне прямоугольника: граница кольца сетку не касается —
          покрытие сетки однородно; решает тест угла }
        if LatPointInRing(LX[0], LZ[0], Ring) then
        begin
          { blanket: сетка целиком внутри кольца (лесной массив, накрывший
            блок) — заменяем прямоугольником с ориентацией исходного.
            Ориентацию считаем ДО SetLength (общий с исходным буфер). }
          if LatRingArea2(Ring) > 0 then
          begin
            SetLength(Ring, 4);
            Ring[0].X := GMinX; Ring[0].Z := GMinZ;
            Ring[1].X := GMaxX; Ring[1].Z := GMinZ;
            Ring[2].X := GMaxX; Ring[2].Z := GMaxZ;
            Ring[3].X := GMinX; Ring[3].Z := GMaxZ;
          end
          else
          begin
            SetLength(Ring, 4);
            Ring[0].X := GMinX; Ring[0].Z := GMinZ;
            Ring[1].X := GMinX; Ring[1].Z := GMaxZ;
            Ring[2].X := GMaxX; Ring[2].Z := GMaxZ;
            Ring[3].X := GMaxX; Ring[3].Z := GMinZ;
          end;
          Inc(BlankN);
          ALayers[I].Rings[WR] := Ring;
          Inc(WR);
        end
        else
          Inc(DropN);                              { далеко и не накрывает }
        Continue;
      end;
      if (rbX0 < GMinX) or (rbX1 > GMaxX) or (rbZ0 < GMinZ) or (rbZ1 > GMaxZ) then
      begin
        { пересекает прямоугольник и вылезает наружу — режем SH }
        Ring := LatRingClipRect(Ring, GMinX, GMaxX, GMinZ, GMaxZ);
        Inc(ClipN);
        if Length(Ring) < 3 then begin Inc(DropN); Continue; end;
      end;
      ALayers[I].Rings[WR] := Ring;
      Inc(WR);
    end;
    SetLength(ALayers[I].Rings, WR);
  end;
  if (ClipN > 0) or (DropN > 0) or (BlankN > 0) then
    AStats.Warn := AStats.Warn + Format(
      'clip: %d обрезано, %d выброшено, %d blanket (макро-релейшены/битые узлы); ',
      [ClipN, DropN, BlankN]);

  { 2. нодинг: линии + все кольца всех слоёв }
  Noder := TLatticeNoder.Create;
  try
    for I := 0 to NXL - 1 do Noder.AddGridLineX(LX[I]);
    for I := 0 to NZL - 1 do Noder.AddGridLineZ(LZ[I]);
    SegN := 0;
    SetLength(SegL, 64); SetLength(SegR, 64);
    for I := 0 to High(ALayers) do
      for R := 0 to High(ALayers[I].Rings) do
      begin
        Inc(AStats.RingsIn);
        for K := 0 to High(ALayers[I].Rings[R]) do
        begin
          J := Noder.AddSegment(ALayers[I].Rings[R][K],
            ALayers[I].Rings[R][(K+1) mod Length(ALayers[I].Rings[R])],
            SegN);
          if J < 0 then Continue;
          if SegN >= Length(SegL) then
          begin
            SetLength(SegL, SegN * 2 + 64);
            SetLength(SegR, SegN * 2 + 64);
          end;
          SegL[SegN] := I;
          SegR[SegN] := R;
          Inc(SegN);
        end;
      end;
    AStats.SegsNoded := SegN;
    if (GenerationProgressContext.Cancel <> nil) and
       GenerationProgressContext.Cancel^ then Exit;
    Noder.Node;
    if (GenerationProgressContext.Cancel <> nil) and
       GenerationProgressContext.Cancel^ then Exit;
    if Noder.ClampNote <> '' then
      AStats.Warn := AStats.Warn + Noder.ClampNote + '; ';

    SetLength(Bary, Length(ALayers));
    for I := 0 to High(ALayers) do
    begin
      Bary[I].Built := False;
      if ALayers[I].UVMode = iumBary then
      begin
        { сетку клипуем к bbox колец слоя (+64 м): убежавшие квады UV-меша
          (way из другого региона в общем датасете) не взрывают её размер }
        if RingWorldBBox(ALayers[I], 64.0, ClMinX, ClMinZ, ClMaxX, ClMaxZ) then
          BuildBaryIndex(Bary[I], ALayers[I].Mesh,
            ClMinX, ClMinZ, ClMaxX, ClMaxZ)
        else
          BuildBaryIndex(Bary[I], ALayers[I].Mesh,
            -1.0e30, -1.0e30, 1.0e30, 1.0e30);
        { слой остался без bary-UV => все его вершины получат (0,0) —
          видно как «гладкие» дороги; ловим причину в варнинг. }
        if not Bary[I].Built then
        begin
          if (ALayers[I].Mesh = nil) then
            AStats.Warn := AStats.Warn + Format(
              'bary-bail mat=%d: mesh=nil; ', [ALayers[I].MatId])
          else if ALayers[I].Mesh.TriangleCount = 0 then
            AStats.Warn := AStats.Warn + Format(
              'bary-bail mat=%d: 0 tri; ', [ALayers[I].MatId])
          else
            AStats.Warn := AStats.Warn + Format(
              'bary-bail mat=%d: bbox %dx%d cells (tri=%d) Osm[minX=%d maxX=%d minZ=%d maxZ=%d]; ',
              [ALayers[I].MatId, Bary[I].CW, Bary[I].CH,
               ALayers[I].Mesh.TriangleCount,
               Bary[I].OsmMinX, Bary[I].OsmMaxX,
               Bary[I].OsmMinZ, Bary[I].OsmMaxZ]);
        end;
      end;
    end;

    { 3. кольца из канонических цепочек + bbox }
    SetLength(NRings, Length(ALayers));
    for I := 0 to High(ALayers) do
    begin
      SetLength(NRings[I], Length(ALayers[I].Rings));
      for R := 0 to High(NRings[I]) do
        NRings[I][R] := nil;
    end;
    SetLength(RUsed, Length(ALayers));
    for I := 0 to High(ALayers) do
    begin
      SetLength(RUsed[I], Length(ALayers[I].Rings));
      for R := 0 to High(RUsed[I]) do RUsed[I][R] := 0;
    end;
    for J := 0 to SegN - 1 do
    begin
      I := SegL[J]; R := SegR[J];
      Ch := Noder.ChainOf(J);
      { конкатенация цепочек без последней точки каждой }
      for K := 0 to Length(Ch) - 2 do
      begin
        if RUsed[I][R] >= Length(NRings[I][R]) then
          SetLength(NRings[I][R], RUsed[I][R] * 2 + 16);
        NRings[I][R][RUsed[I][R]] := Ch[K];
        Inc(RUsed[I][R]);
      end;
    end;
    for I := 0 to High(ALayers) do
      for R := 0 to High(NRings[I]) do
        SetLength(NRings[I][R], RUsed[I][R]);
    for I := 0 to High(ALayers) do
      for R := 0 to High(NRings[I]) do
        if Length(NRings[I][R]) >= 3 then
          Inc(AStats.RingsNoded);

    { 4. разрезка колец на пер-ячейковые ДУГИ + parity-blanket.
       Кольца после нодинга канонические: пересечения с линиями — вершины,
       поэтому сегмент между соседними точками лежит ровно в одной ячейке
       (midpoint однозначен; вдоль-линейный отдаётся левой/нижней —
       соседняя восстановит топологию замыканием по периметру). Сегменты
       вне рамки чанка отбрасываются: parity по полуцелым строкам
       2Zc = 2*LZ[iz]+1 (вершины туда не попадают — граничных случаев
       нет) всё равно даёт верный blanket-вклад кольца в накрытые ячейки. }
    TripN := 0;
    SetLength(Trip, 1024);
    ArcPoolN := 0;
    SetLength(ArcPool, 4096);
    TouchCap := 1024;
    SetLength(TouchKey, TouchCap);
    SetLength(TouchVer, TouchCap);
    TouchCur := 0;
    TouchN := 0;
    RowN := CellsZ;
    SetLength(RowHead, RowN);
    for J := 0 to RowN - 1 do RowHead[J] := -1;
    RowListN := 0;
    SetLength(RowNext, 256);
    SetLength(RowColV, 256);
    SetLength(RowColS, 256);
    for I := 0 to High(ALayers) do
      for R := 0 to High(NRings[I]) do
      begin
        K := Length(NRings[I][R]);
        if K < 3 then Continue;

        { знак кольца (CCW=+1 наружное, CW=-1 дыра) }
        a2ring := 0;
        for J := 0 to K - 1 do
          a2ring := a2ring
            + Int64(NRings[I][R][J].X) * NRings[I][R][(J+1) mod K].Z
            - Int64(NRings[I][R][J].Z) * NRings[I][R][(J+1) mod K].X;
        if a2ring > 0 then RingSign := 1
        else if a2ring < 0 then RingSign := -1
        else Continue;

        { --- 4а. дуги: один проход, склейка по смене ячейки --- }
        TouchReset;
        CutRingToArcs(NRings[I][R], I, R + 1);

        { --- 4б. parity-blanket по строкам, пропуская touched --- }
        BlanketRing(NRings[I][R], I, RingSign);
      end;
    AStats.Arcs := 0;
    AStats.Blankets := 0;
    for I := 0 to TripN - 1 do
      if Trip[I].ArcLen > 0 then Inc(AStats.Arcs)
      else Inc(AStats.Blankets);

    SetLength(Counts, CellCount + 1);
    for I := 0 to CellCount do Counts[I] := 0;
    for I := 0 to TripN - 1 do Inc(Counts[Trip[I].CellKey]);
    SetLength(Offs, CellCount + 1);
    Offs[0] := 0;
    for I := 1 to CellCount do Offs[I] := Offs[I-1] + Counts[I-1];
    { стабильная раскладка: слои внутри ячейки сохраняют порядок ввода
      (возрастание layerIdx = убывание ZIndex) }
    SetLength(Order, TripN);
      SetLength(Fill, CellCount);
      for I := 0 to CellCount - 1 do Fill[I] := Offs[I];
      for I := 0 to TripN - 1 do
      begin
        Order[Fill[Trip[I].CellKey]] := I;
        Inc(Fill[Trip[I].CellKey]);
      end;

      { 4в. RQT-уровни: класс ячейки одним проходом по Trip (любая дуга =
         mixed; иначе победитель blanket-стека по порядку слоёв), затем
         uniform-редукция снизу вверх с min-редукцией узлового дорожного
         поля. Ячейка получает максимальный уровень L, при котором её
         выровненный блок 2^L однороден и не запрещён полем. }
      DecMax := ADecimMaxLevel;
      if DecMax > 6 then DecMax := 6;
      LvA := nil; ClsA := nil; WinA := nil;
      HoleA := nil;
      if Length(AHoleMask) = NXL * NZL then
      begin
        SetLength(HoleA, CellCount);
        hIx := 0; hIz := 0;
        for I := 0 to CellCount - 1 do
        begin
          if HoleCellOf(AHoleMask, hIx, hIz) then
            HoleA[I] := 1
          else
            HoleA[I] := 0;
          Inc(hIx);
          if hIx = CellsX then begin hIx := 0; Inc(hIz); end;
        end;
      end;
      if DecMax > 0 then
      begin
        SetLength(ClsA, CellCount);
        SetLength(WinA, CellCount);
        SetLength(LvA, CellCount);
        haveRL := Length(ARoadLevel) = NXL * NZL;
        for I := 0 to CellCount - 1 do
        begin
          LvA[I] := 0;
          if (HoleA <> nil) and (HoleA[I] <> 0) then
          begin
            ClsA[I] := 253;            { нутро: класс «дыра» безусловно }
            Continue;
          end;
          run := Offs[I];
          itemN := Offs[I+1] - run;
          cls0 := 254;                     { terrain }
          J := 0;
          while J < itemN do
          begin
            li := Trip[Order[run + J]].Layer;
            K := J;
            bw := 0;                       { ΣBaseW слоя }
            while (K < itemN) and (Trip[Order[run + K]].Layer = li) do
            begin
              if Trip[Order[run + K]].ArcLen <> 0 then
              begin
                cls0 := 255;               { дуги — mixed }
                Break;
              end;
              Inc(bw, Trip[Order[run + K]].ArcStart);
              Inc(K);
            end;
            if cls0 = 255 then Break;
            if (bw <> 0) and (cls0 = 254) then
            begin
              { победитель стека; bary-материалы (дороги) НЕ укрупняются:
                их UV следует изгибу центрлайна и не аффинна по позиции —
                интерполяция на блочном треугольнике размазывает текстуру
                и гнёт разметку. Планарные интерполируются точно при
                любом размере блока. }
              if LayersRef[li].MatId = GROUND_MAT_HOLE then
              begin
                cls0 := 253;           { класс «дыра»: блок целиком выброшен }
                WinA[I] := Byte(li);
              end
              else if LayersRef[li].UVMode = iumBary then
                cls0 := 255
              else
              begin
                cls0 := LayersRef[li].MatId;
                WinA[I] := Byte(li);
              end;
            end;
            J := K;
          end;
          ClsA[I] := Byte(cls0);
        end;
        { уровни: PrevCls = уровень 0 }
        SetLength(UniPrev, CellCount);
        SetLength(MinRLPrev, CellCount);
        for I := 0 to CellCount - 1 do
        begin
          if ClsA[I] = 255 then UniPrev[I] := -1 else UniPrev[I] := ClsA[I];
          if haveRL then
            MinRLPrev[I] := RLOfCell(ARoadLevel, I mod CellsX, I div CellsX)
          else
            MinRLPrev[I] := 255;
        end;
        for Lq := 1 to DecMax do
        begin
          bw := CellsX shr Lq;             { блоков по X на уровне }
          bh := CellsZ shr Lq;
          if (bw = 0) or (bh = 0) then Break;
          SetLength(UniCls, bw * bh);
          SetLength(MinRL, bw * bh);
          for bz := 0 to bh - 1 do
            for bx := 0 to bw - 1 do
            begin
              cix := (CellsX shr (Lq-1));
              I := (bz*2) * cix + bx*2;    { NW-ребёнок на уровне Lq-1 }
              cls0 := UniPrev[I];
              if (cls0 < 0)
                 or (UniPrev[I+1] <> cls0)
                 or (UniPrev[I+cix] <> cls0)
                 or (UniPrev[I+cix+1] <> cls0) then
                cls0 := -1;
              UniCls[bz*bw+bx] := cls0;
              ciz := MinRLPrev[I];
              if MinRLPrev[I+1] < ciz then ciz := MinRLPrev[I+1];
              if MinRLPrev[I+cix] < ciz then ciz := MinRLPrev[I+cix];
              if MinRLPrev[I+cix+1] < ciz then ciz := MinRLPrev[I+cix+1];
              MinRL[bz*bw+bx] := Byte(ciz);
              { блок, касающийся РАМКИ чанка, не укрупняется: соседний чанк
                дробит общую рамку своим паттерном, и несовпадение сторон
                даёт клинья после drape. Рамочное кольцо остаётся уровня 0,
                уровни растут от рамки ступенчато.
                Блок также не имеет права ПЕРЕСЕКАТЬ ТАЙЛОВУЮ линию:
                пер-тайловый сплит режет геометрию по ключам треугольников,
                треугольник блока с ключом origin-тайла, физически накрывающий
                соседний тайл, даёт дыру при независимом стриминге тайлов —
                «ровная обрезка тайла» float-тракта возвращена как инвариант
                (ключи блочных треугольников при этом снова точные). }
              if (cls0 >= 0) and (ciz >= Lq)
                 and (bx shl Lq > 0) and (bz shl Lq > 0)
                 and ((bx shl Lq) + (1 shl Lq) < CellsX)
                 and ((bz shl Lq) + (1 shl Lq) < CellsZ)
                 and (TileXOfCell(bx shl Lq)
                      = TileXOfCell((bx shl Lq) + (1 shl Lq) - 1))
                 and (TileZOfCell(bz shl Lq)
                      = TileZOfCell((bz shl Lq) + (1 shl Lq) - 1))
                 and ((cls0 = 253) or BlockFollowsTerrain(
                   bx shl Lq, bz shl Lq, 1 shl Lq)) then
                { блок однороден и разрешён: все его ячейки -> уровень Lq }
                for ciz := bz shl Lq to (bz shl Lq) + (1 shl Lq) - 1 do
                  for cix := bx shl Lq to (bx shl Lq) + (1 shl Lq) - 1 do
                    LvA[ciz * CellsX + cix] := Byte(Lq);
            end;
          UniPrev := UniCls; UniCls := nil;
          MinRLPrev := MinRL; MinRL := nil;
        end;
      end;

      { 5. пер-ячейка: полосы строк независимы — параллельный карв.
         Каждая полоса пишет в СВОИ меши со СВОИМИ словарями; общие
         данные (линии, нодер, Trip, пул дуг, bary-индексы) — read-only.
         Дубли вершин на стыках полос сваривает существующий weld
         композита (позиции совпадают бит-в-бит). }
      nB := AThreads;
      if nB < 1 then nB := 1;
      if nB > CellsZ then nB := CellsZ;
      if nB > 32 then nB := 32;
      SetLength(Bands, nB);
      for bi := 0 to nB - 1 do
      begin
        { НЕ FillChar: TCarveBandCtx содержит managed-поля (динмассивы) —
          побайтовое обнуление сорвёт их финализацию. Свежий SetLength уже
          занулил все элементы (managed = nil, скаляры = 0). }
        Bands[bi].Cancel := GenerationProgressContext.Cancel;
        Bands[bi].LX := LX; Bands[bi].LZ := LZ;
        Bands[bi].CellsX := CellsX;
        blockAlign := 1;
        if DecMax > 0 then blockAlign := 1 shl DecMax;
        Bands[bi].Z0 := ((CellsZ * bi) div nB) and not (blockAlign - 1);
        if bi = nB - 1 then
          Bands[bi].Z1 := CellsZ
        else
          Bands[bi].Z1 := ((CellsZ * (bi + 1)) div nB) and not (blockAlign - 1);
        Bands[bi].Noder := Noder;
        Bands[bi].Trip := Trip;
        Bands[bi].Order := Order;
        Bands[bi].Offs := Offs;
        Bands[bi].ArcPool := ArcPool;
        Bands[bi].Layers := LayersRef;
        Bands[bi].Bary := Bary;
        Bands[bi].TerrainMatId := ATerrainMatId;
        Bands[bi].TerrainInvUV := ATerrainInvUV;
        Bands[bi].GPX0 := AGrid.GPX0;
        Bands[bi].GPY0 := AGrid.GPY0;
        Bands[bi].PitchPx := AGrid.PitchPx;
        Bands[bi].EdgePx := AEdgePx;
        Bands[bi].FlipX := FlipX;
        Bands[bi].FlipZ := FlipZ;
        Bands[bi].CellsZTot := CellsZ;
        Bands[bi].Lv := LvA;
        Bands[bi].CellCls := ClsA;
        Bands[bi].WinLay := WinA;
        Bands[bi].HoleCell := HoleA;
      end;
      GenerationProgress('Ground strips', 0, nB);
      if nB = 1 then
      begin
        CarveBandCells(Bands[0]);
        GenerationProgress('Ground strips', 1, 1);
      end
      else
      begin
        { Общая очередь полос + допуск воркеров по политике Osm3dWorkerPool
          (не переподписывать CPU, когда несколько блоков карвятся разом).
          Недопущенные полосы разбирает вызывающий поток -> все полосы всегда
          выполняются; выход не зависит от числа воркеров. }
        Disp.Bands := Bands;
        Disp.Count := nB;
        Disp.Next  := 0;
        Disp.Done := 0;
        Disp.Progress := GenerationProgressContext.Notify;
        Disp.FailSet := 0;
        Disp.FailMsg := '';
        SetLength(BThreads, nB);        { запас; реально создадим <= nB-1 }
        made := 0;
        { join в finally: допуск пула (PoolReleaseWorker) отпускается РОВНО
          один раз на каждый успешный PoolTryAdmitWorker даже если разбор
          полос на вызывающем потоке бросил исключение — иначе пул терял
          допуски навсегда, а живые воркеры продолжали читать Disp/Bands
          уже после выхода из процедуры. }
        try
          for bi := 0 to nB - 2 do      { вызывающий поток — ещё один участник }
          begin
            if not PoolTryAdmitWorker then Break;   { CPU>=80% и пол закрыт -> стоп }
            BThreads[made] := TCarveBandThread.Create(@Disp);
            Inc(made);
          end;
          CarveDrainBands(@Disp);       { вызывающий поток тоже тянет полосы }
        finally
          for bi := 0 to made - 1 do
          begin
            BThreads[bi].WaitFor;
            PoolReleaseWorker;
            BThreads[bi].Free;
          end;
        end;
        if Disp.FailMsg <> '' then
        begin
          AStats.Fail := 'carve band worker: ' + Disp.FailMsg;
          Exit;
        end;
      end;
      if (GenerationProgressContext.Cancel <> nil) and
         GenerationProgressContext.Cancel^ then Exit;
      { merge: меши полос -> выход; первый мат забирает меш владением }
      for bi := 0 to nB - 1 do
        for I := 0 to High(Bands[bi].OutMeshes) do
        begin
          K := -1;
          for J := 0 to High(OutMeshes) do
            if OutMeshes[J].MatId = Bands[bi].OutMeshes[I].MatId then
            begin
              K := J;
              Break;
            end;
          if K < 0 then
          begin
            K := Length(OutMeshes);
            SetLength(OutMeshes, K + 1);
            OutMeshes[K] := Bands[bi].OutMeshes[I];
            Bands[bi].OutMeshes[I].Mesh := nil;   { владение передано }
          end
          else
          begin
            OutMeshes[K].Mesh.AppendMesh(Bands[bi].OutMeshes[I].Mesh);
            if OutMeshes[K].TriKeyCount + Bands[bi].OutMeshes[I].TriKeyCount
               > Length(OutMeshes[K].TriTileKeys) then
              SetLength(OutMeshes[K].TriTileKeys,
                (OutMeshes[K].TriKeyCount
                 + Bands[bi].OutMeshes[I].TriKeyCount) * 2);
            for J := 0 to Bands[bi].OutMeshes[I].TriKeyCount - 1 do
            begin
              OutMeshes[K].TriTileKeys[OutMeshes[K].TriKeyCount] :=
                Bands[bi].OutMeshes[I].TriTileKeys[J];
              Inc(OutMeshes[K].TriKeyCount);
            end;
            FreeAndNil(Bands[bi].OutMeshes[I].Mesh);
          end;
        end;
      for bi := 0 to nB - 1 do
      begin
        for I := 0 to High(Bands[bi].MDict) do
          FreeAndNil(Bands[bi].MDict[I]);
        Inc(AStats.Cells, Bands[bi].StatCells);
        Inc(AStats.EmptyCells, Bands[bi].StatEmpty);
        Inc(AStats.TrisOut, Bands[bi].StatTris);
        Inc(AStats.DecimBlocks, Bands[bi].StatBlocks);
        Inc(AStats.DecimCoarseCells, Bands[bi].StatCoarse);
        Inc(AStats.HoleTris, Bands[bi].StatHole);
      end;
      for I := 0 to High(OutMeshes) do
      begin
        Inc(AStats.VertsOut, OutMeshes[I].Mesh.VertexCount);
        { КОНТРАКТ TCarvedMatMesh: массив ключей ОБРЕЗАН до TriKeyCount.
          AppendStrip композита включает ключи только при строгом
          Length(Keys) = TriangleCount — ёмкость с запасом молча роняет
          весь чанк на центроидный биннинг, и треугольники ячеек,
          рассечённых тайловой линией, разъезжаются по тайлам (пила по
          краю загруженной зоны). }
        SetLength(OutMeshes[I].TriTileKeys, OutMeshes[I].TriKeyCount);
      end;

  finally
    { Includes aborted and failed bands. Successful transfers have nilled
      their pointers, so this also covers exceptions during the merge. }
    for bi := 0 to High(Bands) do
    begin
      for I := 0 to High(Bands[bi].OutMeshes) do
        Bands[bi].OutMeshes[I].Mesh.Free;
      for I := 0 to High(Bands[bi].MDict) do
        Bands[bi].MDict[I].Free;
    end;
    Noder.Free;
  end;
  AStats.Ms := GetTickCount64 - t0;
end;

end.
