unit Osm3dGeomBridges;

{ overflow/range-проверки выключены намеренно (как в смежных модулях геометрии:
  упаковка/арифметика индексов рассчитывает на тот же режим). }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$codepage UTF8}

{ Bridges for the ground composite.
    1. BEFORE carving: road segments on bridges are excluded from carving so the
       ground under the bridge isn't cut by the road (the river ditch still is).
    2. AFTER carving: the bridge is built — deck = the same road in the GROUND
       COMPOSITE (same GROUND_MAT_FOR_ROAD[Kind], UV and winding as AppendWayRibbon);
       rails = fence geometry (a concrete fence both sides, full length).
  Bridge position is recomputed from terrain (PlaceBridge), not taken from OSM: a high
  bridge spans flat at Y=max(endHeights) with horizontal extension or a ramp down; a low
  bridge spans at HR+BRIDGE_LOW_CLEAR_M with ramps both sides. So CenterY is per-vertex
  (flat on the span, descending on ramps). }

interface

uses
  Classes,
  SysUtils,
  Math,
  CastleVectors,
  Osm3dGeoMath,           { TLatLon, TLocalProjection, TXZ / TXZArray, TLogProc }
  Osm3dGeomMesh,          { TMesh, TMeshVertex, MakeUV }
  Osm3dOsmData,           { TOSMDataset / TOSMWay / TOSMNode / TOSMTags }
  Osm3dGeomTerrain,       { TTerrainSampler, TBridgeSpanMask }
  Osm3dFitHeightLayer,    { TFitHeightLayer — верхний уровень FIT для настила }
  Osm3dGeomRoads,         { TRoadBuilder, TRoadParams, OsmWayIsBridge, TRoadMeshes }
  Osm3dGeomFences,        { TFenceMeshes, TFenceTileAnchor, FenceUVWidth, fmConcrete }
  Osm3dGroundComposite,   { TGroundCompositeMesh, GROUND_MAT_FOR_ROAD, TGroundMaterialId }
  Osm3dCarveGround,       { CaptureMeshBoundaryInt — пересборка IntRings после клипа }
  Osm3dStudioLog          { LOGGING_ENABLED — общий master-флаг логирования }
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
,
  Osm3dOsmIndex;     { TOsmRoadIndex — adjacency «узел → дорожные ways» }

const
  { Высота бетонного парапета над настилом, м. }
  BRIDGE_RAIL_HEIGHT_M = 1.10;
  { Отступ перил от края настила, чтобы парапет стоял НА плите. }
  BRIDGE_RAIL_INSET_M  = 0.15;
  { Мосты короче этого (по проекции) игнорируются — случайный bridge=yes на
    30-см перемычке только засорил бы сцену. }
  BRIDGE_MIN_LEN_M     = 1.0;
  { Deck lift above terrain: avoids vertex-pool welding (eps 1 mm) and z-fight at the seam. }
  BRIDGE_DECK_LIFT_M   = 0.25;
  { Настил заходит на дорогу на столько с каждого конца — закрывает поперечный
    шов на стыке (иначе настил просто упирается в дорогу встык). }
  BRIDGE_DECK_OVERLAP_M = 2.5;
  { Уклон заезда/съезда (наклонной секции), градусы: секция идёт от высоты
    пролёта вниз с этим уклоном до встречи с рельефом. }
  BRIDGE_RAMP_SLOPE_DEG = 6.0;
  { Low/high threshold AND the low-bridge span height above river level HR.
    Both ends within this above HR -> low bridge (span at HR + this). }
  BRIDGE_LOW_CLEAR_M   = 1.0;
  { Шаг маршей вдоль оси (HR, горизонтальный луч, заезд), м. }
  BRIDGE_RAY_STEP_M    = 0.5;
  { Approach turn sharper than this (deg) at an end node = "bridge misses it": that
    end is pulled toward centre and the ramp goes straight along the axis. }
  BRIDGE_SHARP_TURN_DEG = 45.0;
  { Габарит НАД ж/д для теговых мостов, пересекающих железную дорогу. Нормы:
    AREMA — мин. 23 фута (~7.0 м) над головкой рельса; California PUC GO 26-D —
    22'6" мин / 23'4" рек. (~6.9–7.1 м); на электрифицированных линиях больше
    (запас на контактную сеть). 10 м — консервативная «высокая» отметка. }
  BRIDGE_RAIL_CROSS_CLEAR_M = 10.0;
  { ПОПЕРЕЧНЫЙ запас маски пролёта сверх габарита настила, м — участвует лишь
    в max() с полным FIT-коридором (актуален только для настилов шире коридора).
    ПРОДОЛЬНО вырез строго между торцами пролёта (EndM=0 в CollectSpanMask):
    за торцом сразу насыпь подхода, дорога и пятка настила стыкуются на её
    уровне; продольный запас клал за торец полосу DEM — полотно подхода и
    пятка ныряли в вырез, щель на краях моста. }
  BRIDGE_SPAN_MASK_MARGIN_M = 3.0;

type
  TSingleArray = array of Single;

  { One parsed bridge ready for geometry. Center = deck centreline in local XZ after
    position recompute; CenterY[i] = deck height at vertex i (lift included); AccumLen[i] =
    run along the 3D centreline for V. Width/Mat/UV* from ParseRoadParams, so the deck
    samples the same atlas cell as the road. }
  TBridgeSpec = record
    WayId:    Int64;
    { Сквозной номер моста (порядковый среди принятых) — для лога и нумерации
      речных табличек при LOGGING_ENABLED. }
    Num:      Integer;
    Center:   TXZArray;
    CenterY:  TSingleArray;
    AccumLen: TSingleArray;
    Width:    Single;
    Mat:      TGroundMaterialId;
    UVScaleY: Single;
    UVMinX:   Single;
    UVMaxX:   Single;
    { id примыкающих дорог за концами (выбранных FindApproach) — по ним
      подрезается полотно ровно под стык с настилом до карвинга; 0 — тупик
      (примыкающей дороги нет, резать нечего). }
    ApprStartWayId: Int64;
    ApprEndWayId:   Int64;
    { Название реки/водотока под мостом (тег name пересекаемого waterway), ''
      если река без имени или пролёт ничего не пересекает. Для речных табличек
      «р. …» у концов моста (Center[0] / Center[High]). }
    RiverName: string;
    { «Одна геометрия» с дорогой (FIT-мост): чейнов-съездов и пяток-перекрытий
      нет, настил начинается ровно в сечении торца way на высоте полотна БЕЗ
      лифта — крайний ряд вершин настила совпадает по XZ и Y со срезом дороги
      и сваривается с ним в пуле композита (стык без щели/бугра по построению).
      Выравнивание дорог прижимает полотно в этом сечении к той же высоте
      (TDeckJoint в Osm3dGeomBuilder). ClipRoadsUnderDecks режет подход в
      том же сечении (полотно не уходит под палубу). }
    WeldJoints: Boolean;
  end;
  TBridgeSpecArray = array of TBridgeSpec;

  TBridgeBuilder = class
  public
    { Reverse only bridge deck faces into a concrete underside. Works on
      cached composites too; never enters the wheel ground-height index. }
    class function BuildUnderside(Composite:TGroundCompositeMesh;
      const BridgeWayIds:array of Int64):TMesh; static;
    { Найти в датасете мостовые пути (OsmWayIsBridge + реальный класс дороги)
      и разобрать каждый в TBridgeSpec. Чистая функция — геометрию не пишет.
      AFitLayer (опц.) — второй слой высот: верхний уровень (настил) ставит
      плоскую плиту на приведённую FIT-высоту (там реально ехали), а не на
      рельеф; съезды спускаются к DEM-подходам. nil = настил по рельефу. }
    class function Collect(Dataset: TOSMDataset; Projection: TLocalProjection;
      Sampler: TTerrainSampler; LogProc: TLogProc;
      ARoadIdx: TOsmRoadIndex = nil;
      AFitLayer: TFitHeightLayer = nil): TBridgeSpecArray; static;

    { Маска пролётов мостов (осевые OSM-мостов в мировых XZ + полуширина) для
      строителя террейна: под пролётом земля берётся по чистому DEM / нижнему
      уровню, без насыпи-двойника. Снимается ДО постройки террейна (рельеф не
      нужен — только геометрия way). AMarginM расширяет коридор за габарит
      настила. }
    class function CollectSpanMask(Dataset: TOSMDataset;
      Projection: TLocalProjection;
      AMarginM: Single = BRIDGE_SPAN_MASK_MARGIN_M): TBridgeSpanMask; static;

    { Записать настилы в композит (материал дороги) и бетонные парапеты в меши
      заборов (только при GenerateFences). Меняет Composite (append + TrimArrays)
      и Fences (append вершин + якоря тайлов). }
    class procedure Emit(const Specs: TBridgeSpecArray;
      Composite: TGroundCompositeMesh; var Fences: TFenceMeshes;
      GenerateFences: Boolean; LogProc: TLogProc); static;

    { Настил одного спека в композит (дорожный материал/UV/намотка дороги).
      Public для Osm3dGeomTunnels: нижнее полотно туннеля — тот же настил
      по построению, только опущенный под рельеф (перил там нет). }
    class procedure EmitDeck(const Spec: TBridgeSpec;
      Composite: TGroundCompositeMesh); static;

    { Подрезать полотно примыкающих дорог ровно под стык с настилом — ДО
      карвинга (в т.ч. FIT WeldJoints: полотно заезда/съезда НЕ уходит
      под палубу). Режет TMesh + UVMesh и пересобирает IntRings, иначе
      int-карв по старым кольцам снова кладёт асфальт под пролёт.
      Поперечник в сечении посадки: оставляется внешняя (от моста)
      половина; новые треугольники среза остаются в дорожном меше →
      композит земли. Под пролётом после удаления полотна виден landuse/
      terrain (материал контакта). Поперечные дороги (другой OsmId) не
      трогаются. }
    class procedure ClipRoadsUnderDecks(const Specs: TBridgeSpecArray;
      var Roads: TRoadMeshes; LogProc: TLogProc); static;

    { Collect + Emit. Единственная точка входа, которую дёргает билдер. }
    class procedure BuildAll(Dataset: TOSMDataset; Projection: TLocalProjection;
      Sampler: TTerrainSampler; Composite: TGroundCompositeMesh;
      var Fences: TFenceMeshes; GenerateFences: Boolean;
      LogProc: TLogProc; AFitLayer: TFitHeightLayer = nil); static;
  end;

implementation

uses Generics.Collections, Osm3dGeomSurface;

class function TBridgeBuilder.BuildUnderside(Composite:TGroundCompositeMesh;
  const BridgeWayIds:array of Int64):TMesh;
var Ways:specialize TDictionary<Int64,Boolean>; I,J,Tri,Id,Base:Integer;
  V:TMeshVertex; A,B,C,N:TVector3;
begin
  Result:=nil;
  if (Composite=nil) or (Length(BridgeWayIds)=0) then Exit;
  Ways:=specialize TDictionary<Int64,Boolean>.Create;
  try
    for I:=0 to High(BridgeWayIds) do Ways.AddOrSetValue(BridgeWayIds[I],True);
    for Tri:=0 to Composite.TriangleCount-1 do
    begin
      Id:=Composite.Indices[Tri*3];
      if not (Composite.MatIdOf(Id) in [24..29]) or
         not Ways.ContainsKey(Composite.OsmIdOf(Id)) then Continue;
      A:=Composite.PositionOf(Id);
      B:=Composite.PositionOf(Composite.Indices[Tri*3+1]);
      C:=Composite.PositionOf(Composite.Indices[Tri*3+2]);
      N:=TVector3.CrossProduct(B-A,C-A);
      if (N.Y<=0) or (N.LengthSqr<1e-12) then Continue;
      if Result=nil then Result:=TMesh.Create('bridge_underside');
      Base:=Result.VertexCount;
      for J:=0 to 2 do
      begin
        Id:=Composite.Indices[Tri*3+J]; V:=Default(TMeshVertex);
        V.Position:=Composite.PositionOf(Id); V.Normal:=-Composite.NormalOf(Id);
        V.UV:=Vector2(Composite.UVOf(Id).Y,0); { blank concrete facade strip }
        V.OsmId:=Composite.OsmIdOf(Id);
        Result.AddVertex(V);
      end;
      Result.AddTriangle(Base,Base+2,Base+1);
    end;
  finally Ways.Free end;
end;

{ ----------------------------------------------------------------- helpers }

{ Высота рельефа в (X,Z) c защитой от NaN/Inf и от отсутствия сэмплера —
  общий SampleTerrainYXZ в Osm3dGeomTerrain.
  СКОРРЕКТИРОВАННЫЙ сэмплер (SampleAtXZ): маска пролётов уже сделала землю ПОД
  пролётом равной чистому DEM / нижней дороге (воздух под мостом), а НА подходах
  оставила уровень насыпи (FIT). Поэтому:
    • TerrainMin/Max под пролётом = естественный DEM (долина) → воздух;
    • посадка съездов на подходах = уровень насыпи (FIT) → настил стыкуется с
      дорогой на насыпи, а не «съезжает» к сырому DEM.
  Сырой DEM (SampleRawAtXZ) тут НЕ нужен — его роль под пролётом выполняет
  маска в скорректированной поверхности.
  Перпендикуляры/смещённые ломаные — общие PerpAt/OffsetPolyline в Osm3dGeoMath. }

{ Найти примыкающую дорогу за концевым узлом моста и собрать её ломаную НАРУЖУ.
  Из всех дорожных путей (Kind<>rkNone, кроме самого моста), содержащих этот
  узел, берём тот (и направление обхода), чей первый сегмент максимально
  коллинеарен оси моста наружу (axOutDx,axOutDz) — «продолжение той же дороги»
  на стыке/перекрёстке. Appr[0] — сам узел, дальше наружу до MaxArc. Пусто,
  если дороги нет (тупик за мостом). }
procedure FindApproach(Dataset: TOSMDataset; Projection: TLocalProjection;
  SelfWayId, EndNodeId: Int64; axOutDx, axOutDz, MaxArc: Double;
  AIdx: TOsmRoadIndex;
  out Appr: TXZArray; out ApprWayId: Int64);
var
  W, bestWay: TOSMWay;
  rp: TRoadParams;
  p, bestP, bestStep, step, idx, cnt: Integer;
  nd0: TOSMNode;
  q0: TVector3;
  ddx, ddz, dl, bestDot, cum, lastX, lastZ, curX, curZ: Double;
  AdjLst: TRoadAdjArray;

  procedure ConsiderNeighbor(W2: TOSMWay; pp, nstep: Integer);
  var a, b: TOSMNode; pa, pb: TVector3; ex, ez, el, dd: Double;
  begin
    a := Dataset.FindNode(W2.NodeRefs[pp]);
    b := Dataset.FindNode(W2.NodeRefs[pp + nstep]);
    if (a = nil) or (b = nil) then Exit;
    pa := NodePlanePos(Dataset, a, Projection);   { int-first }
    pb := NodePlanePos(Dataset, b, Projection);
    ex := pb.X - pa.X; ez := pb.Z - pa.Z; el := Sqrt(ex*ex + ez*ez);
    if el < 1e-9 then Exit;
    dd := (ex/el)*axOutDx + (ez/el)*axOutDz;
    if dd > bestDot then begin bestDot := dd; bestWay := W2; bestP := pp; bestStep := nstep; end;
  end;

begin
  Appr := nil;
  ApprWayId := 0;
  if (Dataset = nil) or (Dataset.Ways = nil) or (Projection = nil) then Exit;
  bestWay := nil; bestDot := -2.0; bestP := -1; bestStep := 0;

  if AIdx <> nil then
  begin
    { единый индекс (Osm3dOsmIndex): adjacency «узел → дорожные ways» —
      O(степени узла) вместо обхода ВСЕХ ways с ParseRoadParams на каждый
      конец каждого моста (на мостатых блоках это было ~14 с/блок).
      Adjacency уже отфильтрован по Kind<>rkNone, каждое вхождение узла
      (само-петли) — отдельная запись: семантика 1:1 со сканом ниже. }
    if AIdx.AdjOf(EndNodeId, AdjLst) then
      for p := 0 to High(AdjLst) do
      begin
        W := AdjLst[p].Way;
        if (W = nil) or (W.Id = SelfWayId) then Continue;
        if AdjLst[p].Pos > 0 then
          ConsiderNeighbor(W, AdjLst[p].Pos, -1);
        if AdjLst[p].Pos < High(W.NodeRefs) then
          ConsiderNeighbor(W, AdjLst[p].Pos, +1);
      end;
  end
  else
    for W in Dataset.Ways.Values do
    begin
      if W = nil then Continue;
      if W.Id = SelfWayId then Continue;
      rp := TRoadBuilder.ParseRoadParams(W.Tags);
      if rp.Kind = rkNone then Continue;
      for p := 0 to High(W.NodeRefs) do
      begin
        if W.NodeRefs[p] <> EndNodeId then Continue;
        if p > 0                then ConsiderNeighbor(W, p, -1);
        if p < High(W.NodeRefs) then ConsiderNeighbor(W, p, +1);
      end;
    end;

  if (bestWay = nil) or (bestStep = 0) then Exit;
  ApprWayId := bestWay.Id;

  SetLength(Appr, Length(bestWay.NodeRefs));
  cnt := 0; cum := 0.0; lastX := 0.0; lastZ := 0.0;
  idx := bestP; step := bestStep;
  while (idx >= 0) and (idx <= High(bestWay.NodeRefs)) do
  begin
    nd0 := Dataset.FindNode(bestWay.NodeRefs[idx]);
    if nd0 <> nil then
    begin
      q0 := NodePlanePos(Dataset, nd0, Projection);   { int-first }
      curX := q0.X; curZ := q0.Z;
      if cnt = 0 then
      begin
        Appr[cnt].X := curX; Appr[cnt].Z := curZ;
        lastX := curX; lastZ := curZ; Inc(cnt);
      end
      else
      begin
        ddx := curX - lastX; ddz := curZ - lastZ; dl := Sqrt(ddx*ddx + ddz*ddz);
        if dl >= 1e-4 then
        begin
          { Clip inside a sparse OSM segment, not at its far-away next node. }
          if cum + dl > MaxArc then
          begin
            curX := lastX + ddx * (MaxArc - cum) / dl;
            curZ := lastZ + ddz * (MaxArc - cum) / dl;
            dl := MaxArc - cum;
          end;
          cum := cum + dl;
          Appr[cnt].X := curX; Appr[cnt].Z := curZ;
          lastX := curX; lastZ := curZ; Inc(cnt);
          if cum >= MaxArc then Break;
        end;
      end;
    end;
    idx := idx + step;
  end;
  SetLength(Appr, cnt);
  if cnt < 2 then begin Appr := nil; ApprWayId := 0; end;   { дорога фактически кончилась сразу — тупик }
end;

{ ----- Пересчёт реальной позиции моста (ДО карвинга) -----------------------
  Вход: COrig — спроецированная осевая (XZ), OrigLen — её длина; ApprStart/
  ApprEnd — ломаные примыкающих дорог за концами (от узла наружу, пусто если
  тупик). Выход: Center (XZ настила) и CenterY (высота на вершину, с подъёмом).

  Заезд/продление идут ВДОЛЬ ломаной примыкающей дороги (повторяя её поворот) и
  садятся на неё. Если дороги нет или поворот в узле круче BRIDGE_SHARP_TURN_DEG
  — этот конец стягивается к центру моста (горизонтальный пролёт укорачивается
  вплоть до 0), а заезд идёт прямо по оси вниз до земли. }
procedure PlaceBridge(const COrig: TXZArray; OrigLen: Single; DeckHalfW: Double;
  Sampler: TTerrainSampler; Projection: TLocalProjection;
  const ApprStart, ApprEnd: TXZArray;
  out Center: TXZArray; out CenterY: TSingleArray;
  BWayId: Int64 = 0; BNum: Integer = 0; BLog: TLogProc = nil;
  AMinClearance: Single = 0.0; AFitLayer: TFitHeightLayer = nil;
  AWeldOut: PBoolean = nil);
var
  m, i, idx, ns, ne, flatN, totN, finalN, j: Integer;
  vhbS, vhbE, HR, Yspan, fitDeckY, roadY: Single;
  haveFitDeck: Boolean;
  fitP: Double;   { FIT-уровень вершины осевой настила (DeckTargetGeo) }
  rampTan, sharpCos, maxRamp, halfLen, cenX, cenZ, l: Double;
  axSdx, axSdz, axEdx, axEdz: Double;
  sox, soz, soy, eox, eoz, eoy: Double;
  ldx, ldz: Double; dmin, dmax, gt: Single; anyBelow: Boolean;   { только для лога }
  highBridge, startNeedsChain, endNeedsChain, allowExtS, allowExtE: Boolean;
  startReloc, endReloc, haveSO, haveEO: Boolean;
  scXZ, ecXZ, FXZ, FX2: TXZArray;
  scY, ecY, FY, FY2: TSingleArray;
  effS, effE: TXZ;

  function HAt(X, Z: Double): Single;
  begin
    HAt := SampleTerrainYXZ(Sampler, Projection, Single(X), Single(Z));
  end;

  { Высота рельефа под полотном в точке (cx,cz) с продольным направлением
    (dirx,dirz): максимум из трёх замеров — по оси и на обоих краях полотна
    (поперёк оси, на ±DeckHalfW; перпендикуляр (Dz,-Dx) как в PerpAt). Берём
    наибольшую, чтобы край настила не уходил под рельеф там, где земля поперёк
    оси выше, чем под самой осью. При нулевой ширине/направлении — одна точка. }
  function HMaxAcross(cx, cz, dirx, dirz: Double): Single;
  var dl, ox, oz: Double; hL, hR: Single;
  begin
    HMaxAcross := HAt(cx, cz);
    dl := Sqrt(dirx*dirx + dirz*dirz);
    if (dl < 1e-9) or (DeckHalfW <= 0) then Exit;
    ox :=  dirz/dl * DeckHalfW;
    oz := -dirx/dl * DeckHalfW;
    hL := HAt(cx + ox, cz + oz);
    hR := HAt(cx - ox, cz - oz);
    if hL > HMaxAcross then HMaxAcross := hL;
    if hR > HMaxAcross then HMaxAcross := hR;
  end;

  function TerrainMinAlong: Single;
  var ii, tt, st: Integer; aax, aaz, bbx, bbz, sl, ff, px, pz: Double; hh, mn: Single;
  begin
    mn := HAt(COrig[0].X, COrig[0].Z);
    for ii := 0 to High(COrig) - 1 do
    begin
      aax := COrig[ii].X; aaz := COrig[ii].Z;
      bbx := COrig[ii+1].X; bbz := COrig[ii+1].Z;
      sl := Sqrt((bbx-aax)*(bbx-aax) + (bbz-aaz)*(bbz-aaz));
      st := Trunc(sl / BRIDGE_RAY_STEP_M) + 1;
      for tt := 0 to st do
      begin
        ff := tt / st;
        px := aax + (bbx-aax)*ff; pz := aaz + (bbz-aaz)*ff;
        hh := HAt(px, pz);
        if hh < mn then mn := hh;
      end;
    end;
    TerrainMinAlong := mn;
  end;

  { Самая ВЫСОКАЯ земля под всем пролётом (поперёк всей ширины настила). Шагаем
    вдоль осевой как TerrainMinAlong, но берём HMaxAcross (ось + оба края) и
    максимум. Это уровень РОВНОЙ плиты: на нём плита нигде не ниже рельефа —
    ни вдоль, ни поперёк, ни на одном из концов. }
  function TerrainMaxAlong: Single;
  var ii, tt, st: Integer; aax, aaz, bbx, bbz, ddx, ddz, sl, ff, px, pz: Double; hh, mx: Single;
  begin
    mx := HMaxAcross(COrig[0].X, COrig[0].Z, COrig[1].X - COrig[0].X, COrig[1].Z - COrig[0].Z);
    for ii := 0 to High(COrig) - 1 do
    begin
      aax := COrig[ii].X; aaz := COrig[ii].Z;
      bbx := COrig[ii+1].X; bbz := COrig[ii+1].Z;
      ddx := bbx - aax; ddz := bbz - aaz;
      sl := Sqrt(ddx*ddx + ddz*ddz);
      st := Trunc(sl / BRIDGE_RAY_STEP_M) + 1;
      for tt := 0 to st do
      begin
        ff := tt / st;
        px := aax + ddx*ff; pz := aaz + ddz*ff;
        hh := HMaxAcross(px, pz, ddx, ddz);
        if hh > mx then mx := hh;
      end;
    end;
    TerrainMaxAlong := mx;
  end;

  { Уровень настила по ВЕРХНЕМУ уровню FIT над пролётом (там реально ехали):
    медиана DeckTargetGeo по узлам исходной осевой COrig. False — FIT над
    мостом нет (мост не на маршруте) → плита остаётся по рельефу. }
  function FitDeckLevel(out AY: Single): Boolean;
  var
    ii, nfs, a2, b2: Integer;
    dy, vtmp: Double;
    LL: TLatLon;
    samp: array of Single;
  begin
    Result := False; AY := 0;
    if (AFitLayer = nil) or (not AFitLayer.Active) or (Projection = nil) then Exit;
    SetLength(samp, Length(COrig));
    nfs := 0;
    for ii := 0 to High(COrig) do
    begin
      LL := Projection.Unproject(Single(COrig[ii].X), Single(COrig[ii].Z));
      if AFitLayer.DeckTargetGeo(LL, dy) then
      begin
        samp[nfs] := Single(dy);
        Inc(nfs);
      end;
    end;
    if nfs = 0 then Exit;
    { медиана — сортировка вставками (узлов мало) }
    for a2 := 1 to nfs - 1 do
    begin
      vtmp := samp[a2]; b2 := a2 - 1;
      while (b2 >= 0) and (samp[b2] > vtmp) do
      begin samp[b2 + 1] := samp[b2]; Dec(b2); end;
      samp[b2 + 1] := Single(vtmp);
    end;
    AY := samp[nfs div 2];
    Result := True;
  end;

  { Sample just outside the span mask at the road joint. Distance is metric,
    independent of OSM node spacing (the next node may be kilometres away). }
  function ApproachRoadLevel(out AY: Single): Boolean;
  var yS, yE: Single; okS, okE: Boolean;

    function JointLevel(const AP: TXZArray; out Y: Single): Boolean;
    var k: Integer; remaining, dx, dz, len, f: Double;
    begin
      Result := False;
      remaining := BRIDGE_DECK_OVERLAP_M;
      for k := 1 to High(AP) do
      begin
        dx := AP[k].X - AP[k-1].X; dz := AP[k].Z - AP[k-1].Z;
        len := Sqrt(dx*dx + dz*dz);
        if len < 1e-9 then Continue;
        if (len >= remaining) or (k = High(AP)) then
        begin
          f := Min(remaining / len, 1.0);
          Y := HMaxAcross(AP[k-1].X + dx*f, AP[k-1].Z + dz*f, dx, dz);
          Exit(True);
        end;
        remaining := remaining - len;
      end;
    end;

  begin
    AY := 0;
    okS := JointLevel(ApprStart, yS);
    okE := JointLevel(ApprEnd, yE);
    Result := okS or okE;
    if okS and okE then AY := Max(yS, yE)
    else if okS then AY := yS
    else if okE then AY := yE;
  end;

  function ApproachOK(const AP: TXZArray; dx, dz: Double): Boolean;
  var ex, ez, el: Double;
  begin
    ApproachOK := False;
    if Length(AP) < 2 then Exit;
    ex := AP[1].X - AP[0].X; ez := AP[1].Z - AP[0].Z; el := Sqrt(ex*ex + ez*ez);
    if el < 1e-9 then Exit;
    ApproachOK := ((ex/el)*dx + (ez/el)*dz) >= sharpCos;
  end;

  { Search only the remaining ramp budget, including its exact endpoint.
    Refine the first terrain contact to avoid burying the joint by a full step.
    If the budget is exhausted, join the terrain there instead of extrapolating
    an unchecked descending deck underneath the rest of the road. }
  procedure RampHit(sx, sz, dx, dz, y0, limit: Double; out gx, gz, gy: Double);
  var d, lo, hi, mid: Double; k: Integer;
  begin
    lo := 0; d := 0;
    repeat
      d := Min(d + BRIDGE_RAY_STEP_M, limit);
      if y0 - rampTan*d <= HAt(sx + dx*d, sz + dz*d) then
      begin
        hi := d;
        for k := 1 to 12 do
        begin
          mid := (lo + hi) * 0.5;
          if y0 - rampTan*mid <= HAt(sx + dx*mid, sz + dz*mid)
            then hi := mid else lo := mid;
        end;
        d := hi;
        Break;
      end;
      lo := d;
    until d >= limit;
    gx := sx + dx*d; gz := sz + dz*d;
    gy := HAt(gx, gz);
  end;

  procedure FollowChain(const AP: TXZArray; Yspan: Single; allowExtend: Boolean;
    out oXZ: TXZArray; out oY: TSingleArray);
  var
    h, k, np, refine: Integer;
    vc: array of Double;
    tot, dd, limit, lo, hi, mid, ldx, ldz, ll, gx, gz, gy, qx, qz: Double;
    found: Boolean;

    procedure PointAtArc(d: Double; out ax, az: Double);
    var kk: Integer; segL, fr: Double;
    begin
      if d <= 0 then begin ax := AP[0].X; az := AP[0].Z; Exit; end;
      if d >= tot then begin ax := AP[h].X; az := AP[h].Z; Exit; end;
      for kk := 0 to h - 1 do
        if d <= vc[kk+1] then
        begin
          segL := vc[kk+1] - vc[kk];
          if segL < 1e-9 then fr := 0.0 else fr := (d - vc[kk]) / segL;
          ax := AP[kk].X + (AP[kk+1].X - AP[kk].X) * fr;
          az := AP[kk].Z + (AP[kk+1].Z - AP[kk].Z) * fr;
          Exit;
        end;
      ax := AP[h].X; az := AP[h].Z;
    end;

    procedure EmitUpToArc(d: Double; ramp: Boolean);
    var kk, c: Integer; ax, az: Double;
    begin
      oXZ := nil; oY := nil; c := 0;
      SetLength(oXZ, h + 2); SetLength(oY, h + 2);
      for kk := 1 to h do
        if vc[kk] < d - 1e-6 then
        begin
          oXZ[c].X := AP[kk].X; oXZ[c].Z := AP[kk].Z;
          if ramp then oY[c] := Single(Yspan - rampTan*vc[kk]) else oY[c] := Yspan;
          Inc(c);
        end
        else Break;
      PointAtArc(d, ax, az);
      oXZ[c].X := ax; oXZ[c].Z := az;
      if ramp then oY[c] := Single(Yspan - rampTan*d) else oY[c] := Yspan;
      Inc(c);
      SetLength(oXZ, c); SetLength(oY, c);
    end;

  begin
    oXZ := nil; oY := nil; vc := nil;
    h := High(AP);
    if h < 1 then Exit;
    SetLength(vc, h + 1);
    vc[0] := 0.0;
    for k := 1 to h do
      vc[k] := vc[k-1] + Sqrt((AP[k].X-AP[k-1].X)*(AP[k].X-AP[k-1].X) +
                              (AP[k].Z-AP[k-1].Z)*(AP[k].Z-AP[k-1].Z));
    tot := vc[h];
    if tot < 1e-6 then Exit;

    if allowExtend then
    begin
      found := False; dd := BRIDGE_RAY_STEP_M;
      while (dd <= halfLen) and (dd <= tot) do
      begin
        PointAtArc(dd, qx, qz);
        if HAt(qx, qz) >= Yspan then begin found := True; Break; end;
        dd := dd + BRIDGE_RAY_STEP_M;
      end;
      if found then begin EmitUpToArc(dd, False); Exit; end;
    end;

    limit := Min(maxRamp, tot);
    found := False; dd := 0; lo := 0;
    repeat
      dd := Min(dd + BRIDGE_RAY_STEP_M, limit);
      PointAtArc(dd, qx, qz);
      if (Yspan - rampTan*dd) <= HAt(qx, qz) then
      begin
        found := True; hi := dd;
        for refine := 1 to 12 do
        begin
          mid := (lo + hi) * 0.5;
          PointAtArc(mid, qx, qz);
          if Yspan - rampTan*mid <= HAt(qx, qz)
            then hi := mid else lo := mid;
        end;
        dd := hi;
        Break;
      end;
      lo := dd;
    until dd >= limit;
    EmitUpToArc(dd, True);
    if found or (tot >= maxRamp) then
    begin
      PointAtArc(dd, qx, qz);
      oY[High(oY)] := HAt(qx, qz);
      Exit;
    end;

    ldx := AP[h].X - AP[h-1].X; ldz := AP[h].Z - AP[h-1].Z; ll := Sqrt(ldx*ldx + ldz*ldz);
    if ll > 1e-9 then
    begin
      ldx := ldx/ll; ldz := ldz/ll;
      RampHit(AP[h].X, AP[h].Z, ldx, ldz, Yspan - rampTan*tot,
        maxRamp - tot, gx, gz, gy);
      np := Length(oXZ); SetLength(oXZ, np + 1); SetLength(oY, np + 1);
      oXZ[np].X := gx; oXZ[np].Z := gz; oY[np] := Single(gy);
    end;
  end;

  procedure StraightRamp(sx, sz: Double; Yspan: Single; dx, dz: Double;
    out oXZ: TXZArray; out oY: TSingleArray);
  var gx, gz, gy: Double;
  begin
    oXZ := nil; oY := nil;
    RampHit(sx, sz, dx, dz, Yspan, maxRamp, gx, gz, gy);
    SetLength(oXZ, 1); SetLength(oY, 1);
    oXZ[0].X := gx; oXZ[0].Z := gz; oY[0] := Single(gy);
  end;

  { Overlap "foot" of one deck end (start/finish mirror -> one helper). edgeIdx = end
    vertex, innerIdx = neighbour inward (sets the edge direction). Direction follows the
    approach road on a high dead end, else the edge segment. Foot Y = terrain but NOT above
    the slab edge (else a down-ramp onto the bridge). have=False = degenerate, no foot. }
  procedure ComputeFoot(edgeIdx, innerIdx: Integer; const Appr: TXZArray;
    needsChain: Boolean; axdx, axdz: Double; out ox, oz, oy: Double; out have: Boolean);
  var dvx, dvz, dl: Double;
  begin
    have := False;
    if highBridge and (not needsChain) and ApproachOK(Appr, axdx, axdz) then
      begin dvx := Appr[1].X - Appr[0].X; dvz := Appr[1].Z - Appr[0].Z; end
    else
      begin dvx := Center[edgeIdx].X - Center[innerIdx].X;
            dvz := Center[edgeIdx].Z - Center[innerIdx].Z; end;
    dl := Sqrt(dvx*dvx + dvz*dvz);
    if dl <= 1e-9 then Exit;
    ox := Center[edgeIdx].X + (dvx/dl)*BRIDGE_DECK_OVERLAP_M;
    oz := Center[edgeIdx].Z + (dvz/dl)*BRIDGE_DECK_OVERLAP_M;
    oy := HMaxAcross(ox, oz, dvx, dvz);
    { Пятку нельзя поднимать выше края плиты: если рельеф у пятки выше плиты
      (земля поднимается к мосту), пятка на рельефе дала бы съезд ВНИЗ на настил
      («от дороги вверх к настилу» -> «с дороги вниз на настил»). Держим на уровне
      края — настил остаётся РОВНЫМ, кромка уходит в склон (стык под землёй). В
      долине (рельеф НИЖЕ плиты) min ничего не меняет — заезд вверх сохраняется. }
    if oy > CenterY[edgeIdx] then oy := CenterY[edgeIdx];
    have := True;
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1611);{$ENDIF}
  Center := nil; CenterY := nil;
  if AWeldOut <> nil then AWeldOut^ := False;
  scXZ := nil; ecXZ := nil; FXZ := nil; scY := nil; ecY := nil; FY := nil; FX2 := nil; FY2 := nil;
  m := High(COrig);
  if m < 1 then
  begin
    Center := Copy(COrig, 0, Length(COrig));
    SetLength(CenterY, Length(COrig));
    for i := 0 to High(COrig) do
      CenterY[i] := HAt(COrig[i].X, COrig[i].Z) + BRIDGE_DECK_LIFT_M;
    Exit;
  end;

  vhbS := HMaxAcross(COrig[0].X, COrig[0].Z, COrig[1].X - COrig[0].X, COrig[1].Z - COrig[0].Z);
  vhbE := HMaxAcross(COrig[m].X, COrig[m].Z, COrig[m].X - COrig[m-1].X, COrig[m].Z - COrig[m-1].Z);
  HR   := TerrainMinAlong;
  rampTan := Tan(BRIDGE_RAMP_SLOPE_DEG * Pi / 180.0);
  if rampTan < 1e-4 then rampTan := 1e-4;
  sharpCos := Cos(BRIDGE_SHARP_TURN_DEG * Pi / 180.0);
  halfLen := 0.5 * OrigLen;
  maxRamp := 3.0 * OrigLen + 100.0;

  cenX := 0.5 * (COrig[0].X + COrig[m].X);
  cenZ := 0.5 * (COrig[0].Z + COrig[m].Z);

  axSdx := COrig[0].X - COrig[1].X; axSdz := COrig[0].Z - COrig[1].Z;
  l := Sqrt(axSdx*axSdx + axSdz*axSdz);
  if l > 1e-9 then begin axSdx := axSdx/l; axSdz := axSdz/l; end else begin axSdx := 0.0; axSdz := 0.0; end;
  axEdx := COrig[m].X - COrig[m-1].X; axEdz := COrig[m].Z - COrig[m-1].Z;
  l := Sqrt(axEdx*axEdx + axEdz*axEdz);
  if l > 1e-9 then begin axEdx := axEdx/l; axEdz := axEdz/l; end else begin axEdx := 0.0; axEdz := 0.0; end;

  highBridge := ((vhbS - HR) > BRIDGE_LOW_CLEAR_M) or ((vhbE - HR) > BRIDGE_LOW_CLEAR_M);

  startNeedsChain := False; endNeedsChain := False;
  allowExtS := False; allowExtE := False;
  { Flat-slab level = highest ground under the whole span (across width), so the slab is
    nowhere below terrain or the ends. An end below the slab gets a ramp: first try extending
    the slab flat until ground rises to meet it, else drop a ramp to ground. allowExtend is
    therefore set on each ramped end. }
  Yspan := TerrainMaxAlong;
  haveFitDeck := FitDeckLevel(fitDeckY);
  if not ApproachRoadLevel(roadY) then roadY := Yspan;   { определён для лога и ветки без FIT }
  if haveFitDeck then
  begin
    { Есть FIT над пролётом (в route-only это ТЕКУЩИЙ заезд, без чужих кластеров):
      настил стоит на уровне полотна, где реально ехали (fitDeckY). Не ниже
      рельефа под пролётом (иначе плита в земле). И НЕ поднимаем к подходу roadY:
      если под настилом уже есть просвет (fitDeckY выше рельефа пролёта из-за
      разницы DEM/FIT или двух уровней FIT), подъём к roadY дал бы «мост построен
      ВЫШЕ полотна». Заезд сам догоняет полотно (FollowChain по подходу). }
    if fitDeckY > Yspan then Yspan := fitDeckY;
    { искусственный габарит над ж/д при наличии FIT не применяем — высоту задаёт
      полотно заезда (иначе снова «мост выше насыпи»). }
  end
  else
  begin
    { Без FIT — как раньше: настил на уровень ДОРОГИ на подходах (насыпь за
      пролётом), не на дно DEM-провала под пролётом. }
    if roadY > Yspan then Yspan := roadY;
    { Габарит плиты над низшей точкой HR (BRIDGE_RAIL_CROSS_CLEAR_M над ж/д). }
    if (AMinClearance > 0.0) and ((Yspan - HR) < AMinClearance) then
      Yspan := HR + AMinClearance;
  end;
  startNeedsChain := (Yspan - vhbS) > BRIDGE_DECK_LIFT_M;
  endNeedsChain   := (Yspan - vhbE) > BRIDGE_DECK_LIFT_M;
  { FIT-мост: «одна геометрия» с дорогой. Дорога выровнена тем же FIT и сама
    приходит на высоту настила у торца, поэтому чейны-съезды за пролёт и
    пятки-перекрытия не нужны: настил заканчивается ровно на торце way, его
    крайнее сечение — на высоте полотна (без лифта) — совпадает со срезом
    дороги и сваривается с ним в пуле композита. Полотно в сечении стыка
    прижимает к той же высоте выравнивание (TDeckJoint, Osm3dGeomBuilder). }
  if haveFitDeck then
  begin
    startNeedsChain := False;
    endNeedsChain   := False;
    if AWeldOut <> nil then AWeldOut^ := True;
  end;
  allowExtS := startNeedsChain;
  allowExtE := endNeedsChain;

  { Диагностика моста — пишется только при общем LOGGING_ENABLED (компайл-тайм
    константа из Osm3dStudioLog: при False весь блок вырезается, без построения
    строк). Assigned(BLog) — на случай стримингового пути с nil-логом. }
  if LOGGING_ENABLED and Assigned(BLog) then
  begin
    BLog(Format('--- BRIDGE #%d way=%d nodes=%d len=%.1fm width=%.1fm high=%s ---',
      [BNum, BWayId, m + 1, OrigLen, DeckHalfW * 2.0, BoolToStr(highBridge, True)]));
    BLog(Format('  levels: vhbS=%.2f vhbE=%.2f HR(min)=%.2f  roadAppr=%.2f fitMed=%.2f haveFit=%s  Yspan=%.2f',
      [vhbS, vhbE, HR, roadY, fitDeckY, BoolToStr(haveFitDeck, True), Yspan]));
    BLog(Format('  decision: startChain=%s(ext=%s) endChain=%s(ext=%s)  rampSlope=%.1f deg',
      [BoolToStr(startNeedsChain, True), BoolToStr(allowExtS, True),
       BoolToStr(endNeedsChain, True), BoolToStr(allowExtE, True),
       BRIDGE_RAMP_SLOPE_DEG]));
    BLog('  span nodes (i: x z terr[across]):');
    for i := 0 to m do
    begin
      if i < m then begin ldx := COrig[i+1].X - COrig[i].X; ldz := COrig[i+1].Z - COrig[i].Z; end
      else           begin ldx := COrig[i].X - COrig[i-1].X; ldz := COrig[i].Z - COrig[i-1].Z; end;
      BLog(Format('    [%d] x=%.1f z=%.1f terr=%.2f',
        [i, COrig[i].X, COrig[i].Z, HMaxAcross(COrig[i].X, COrig[i].Z, ldx, ldz)]));
    end;
    BLog(Format('  apprStart pts=%d (x z terr):', [Length(ApprStart)]));
    for i := 0 to High(ApprStart) do
      BLog(Format('    [%d] x=%.1f z=%.1f terr=%.2f',
        [i, ApprStart[i].X, ApprStart[i].Z, HAt(ApprStart[i].X, ApprStart[i].Z)]));
    BLog(Format('  apprEnd pts=%d (x z terr):', [Length(ApprEnd)]));
    for i := 0 to High(ApprEnd) do
      BLog(Format('    [%d] x=%.1f z=%.1f terr=%.2f',
        [i, ApprEnd[i].X, ApprEnd[i].Z, HAt(ApprEnd[i].X, ApprEnd[i].Z)]));
  end;

  startReloc := False; endReloc := False;
  effS := COrig[0]; effE := COrig[m];

  if startNeedsChain then
  begin
    if ApproachOK(ApprStart, axSdx, axSdz) then
      FollowChain(ApprStart, Yspan, allowExtS, scXZ, scY)
    else
    begin
      startReloc := True; effS.X := cenX; effS.Z := cenZ;
      StraightRamp(cenX, cenZ, Yspan, axSdx, axSdz, scXZ, scY);
    end;
  end;

  if endNeedsChain then
  begin
    if ApproachOK(ApprEnd, axEdx, axEdz) then
      FollowChain(ApprEnd, Yspan, allowExtE, ecXZ, ecY)
    else
    begin
      endReloc := True; effE.X := cenX; effE.Z := cenZ;
      StraightRamp(cenX, cenZ, Yspan, axEdx, axEdz, ecXZ, ecY);
    end;
  end;

  if LOGGING_ENABLED and Assigned(BLog) then
  begin
    if Length(scXZ) > 0 then
      BLog(Format('  startChain: pts=%d reloc=%s Y[outer..inner]=%.2f..%.2f',
        [Length(scXZ), BoolToStr(startReloc, True), scY[High(scY)], scY[0]]))
    else
      BLog(Format('  startChain: pts=0 reloc=%s (flush)', [BoolToStr(startReloc, True)]));
    if Length(ecXZ) > 0 then
      BLog(Format('  endChain:   pts=%d reloc=%s Y[inner..outer]=%.2f..%.2f',
        [Length(ecXZ), BoolToStr(endReloc, True), ecY[0], ecY[High(ecY)]]))
    else
      BLog(Format('  endChain:   pts=0 reloc=%s (flush)', [BoolToStr(endReloc, True)]));
  end;

  if (not startReloc) and (not endReloc) then
  begin
    flatN := m + 1;
    SetLength(FXZ, flatN); SetLength(FY, flatN);
    for i := 0 to m do begin FXZ[i] := COrig[i]; FY[i] := Yspan; end;
  end
  else if startReloc and endReloc then
  begin
    flatN := 1;
    SetLength(FXZ, 1); SetLength(FY, 1);
    FXZ[0] := effS; FY[0] := Yspan;
  end
  else
  begin
    flatN := 2;
    SetLength(FXZ, 2); SetLength(FY, 2);
    FXZ[0] := effS; FY[0] := Yspan;
    FXZ[1] := effE; FY[1] := Yspan;
  end;

  ns := Length(scXZ); ne := Length(ecXZ);
  totN := ns + flatN + ne;
  SetLength(Center, totN); SetLength(CenterY, totN);
  idx := 0;
  for i := ns - 1 downto 0 do begin Center[idx] := scXZ[i]; CenterY[idx] := scY[i]; Inc(idx); end;
  for i := 0 to flatN - 1   do begin Center[idx] := FXZ[i]; CenterY[idx] := FY[i]; Inc(idx); end;
  for i := 0 to ne - 1      do begin Center[idx] := ecXZ[i]; CenterY[idx] := ecY[i]; Inc(idx); end;

  { --- стыковка с дорогой ---
    Подъём над рельефом — на ВСЁ полотно настила, включая обе крайние вершины
    (посадки заездов). Раньше крайние вершины исключались (i=1..totN-2), чтобы
    лежать ровно на дороге без ступеньки, но тогда оба конца настила оставались
    на уровне рельефа и z-fight'или с землёй под мостом (особенно после того, как
    дорогу под пролётом срезаем). Плавный стык с дорогой теперь обеспечивают
    перекрытия (overlap-«пятки» ниже): они добавляются на уровне рельефа и идут
    от дороги вверх к поднятому настилу. Перекрытие закрывает поперечный шов: на
    «глухом» (высоком) конце берём направление вдоль примыкающей дороги (попасть
    в неё), иначе — вдоль крайнего сегмента настила (он уже идёт по дороге). }
  totN := Length(Center);
  { Плита уже на уровне самой высокой земли под пролётом (Yspan = TerrainMaxAlong),
    поэтому НИГДЕ не ниже рельефа — никакого «подтягивания» вершин к земле быть не
    должно (иначе плита перестаёт быть ровной и появляются паразитные съезды).
    Здесь — только общий лифт над рельефом против z-fight; плита остаётся РОВНОЙ. }
  for i := 0 to totN - 1 do
    CenterY[i] := CenterY[i] + BRIDGE_DECK_LIFT_M;

  { Стык «одной геометрией» (FIT-мост): крайние сечения настила — БЕЗ лифта,
    ровно на уровне полотна (совпадают со срезом дороги и свариваются). Лифт
    остаётся только на внутренних вершинах — против z-fight с рельефом. }
  if haveFitDeck and (totN >= 2) then
  begin
    CenterY[0]        := CenterY[0]        - BRIDGE_DECK_LIFT_M;
    CenterY[totN - 1] := CenterY[totN - 1] - BRIDGE_DECK_LIFT_M;
  end;

  haveSO := False; haveEO := False;
  { Пятки-перекрытия — только БЕЗ FIT: на FIT-мосту настил стыкуется с дорогой
    встык «одной геометрией», перекрытие снова дало бы двойную поверхность. }
  if (totN >= 2) and (not haveFitDeck) then
  begin
    ComputeFoot(0,      1,        ApprStart, startNeedsChain, axSdx, axSdz, sox, soz, soy, haveSO);
    ComputeFoot(totN-1, totN-2,   ApprEnd,   endNeedsChain,   axEdx, axEdz, eox, eoz, eoy, haveEO);
  end;

  if haveSO or haveEO then
  begin
    finalN := totN + Ord(haveSO) + Ord(haveEO);
    SetLength(FX2, finalN); SetLength(FY2, finalN);
    j := 0;
    if haveSO then begin FX2[j].X := sox; FX2[j].Z := soz; FY2[j] := Single(soy); Inc(j); end;
    for i := 0 to totN - 1 do begin FX2[j] := Center[i]; FY2[j] := CenterY[i]; Inc(j); end;
    if haveEO then begin FX2[j].X := eox; FX2[j].Z := eoz; FY2[j] := Single(eoy); Inc(j); end;
    Center := FX2; CenterY := FY2;
  end;

  { FIT-профиль настила. Плоская плита на МЕДИАНЕ FIT пролёта (Yspan=fitMed)
    расходится с реальным профилем заезда: полотно по мосту имеет уклон
    (замер BRIDGE #2: 174.2 → 175.2 на 43 м), и у ВЫСОКОГО торца плита
    оказывалась НИЖЕ дороги-подхода на 0.3–0.5 м — земля (=FIT полотна)
    вылезала БУГРОМ над настилом («бугры в начале моста»). С активным FIT
    каждая вершина осевой садится на СВОЙ верхний FIT-уровень (профиль
    заезда, гладкий). Торцы (i=0 / High: чейнов и пяток на FIT-мосту нет,
    крайние вершины = торцы way) — БЕЗ лифта, ровно на полотне: сечение
    совпадает со срезом дороги («одна геометрия», стык без щели/бугра).
    Вне коридора FIT (DeckTargetGeo=False) вершина сохраняет прежнюю
    высоту (торец уже без лифта — снято выше). }
  if haveFitDeck and (AFitLayer <> nil) and AFitLayer.Active then
    for i := 0 to High(Center) do
      if AFitLayer.DeckTargetGeo(
           Projection.Unproject(Single(Center[i].X), Single(Center[i].Z)),
           fitP) then
      begin
        if (i = 0) or (i = High(Center)) then
          CenterY[i] := Single(fitP)                        { торец на полотне }
        else
          CenterY[i] := Single(fitP) + BRIDGE_DECK_LIFT_M;  { плита с лифтом }
      end;

  if LOGGING_ENABLED and Assigned(BLog) then
  begin
    BLog(Format('  FINAL deck pts=%d (i: x z Y terr dY)  [dY<0 = deck BELOW ground]:',
      [Length(Center)]));
    dmin := 1e9; dmax := -1e9; anyBelow := False;
    for i := 0 to High(Center) do
    begin
      if Length(Center) >= 2 then
      begin
        if i = 0 then
          begin ldx := Center[1].X - Center[0].X; ldz := Center[1].Z - Center[0].Z; end
        else if i = High(Center) then
          begin ldx := Center[i].X - Center[i-1].X; ldz := Center[i].Z - Center[i-1].Z; end
        else
          begin ldx := Center[i+1].X - Center[i-1].X; ldz := Center[i+1].Z - Center[i-1].Z; end;
      end
      else begin ldx := 0.0; ldz := 0.0; end;
      gt := HMaxAcross(Center[i].X, Center[i].Z, ldx, ldz);
      BLog(Format('    [%d] x=%.1f z=%.1f Y=%.2f terr=%.2f dY=%.2f',
        [i, Center[i].X, Center[i].Z, CenterY[i], gt, CenterY[i] - gt]));
      if CenterY[i] < dmin then dmin := CenterY[i];
      if CenterY[i] > dmax then dmax := CenterY[i];
      if CenterY[i] + 1e-3 < gt then anyBelow := True;
    end;
    BLog(Format('  deck Y: min=%.2f max=%.2f drop=%.2f  anyBelowTerrain=%s',
      [dmin, dmax, dmax - dmin, BoolToStr(anyBelow, True)]));
  end;
end;

{ Deck: top layer along the 3D centreline (Center + CenterY), road material and UV.
  Winding/UV match AppendWayRibbon (Right -> UVMinX, Left -> UVMaxX, V = AccumLen/UVScaleY).
  Per-vertex height from CenterY; normal tilts with the along-axis slope. AppendVertex welds
  shared points of adjacent segments, but the lift keeps it out of the ground. }
procedure EmitDeckCore(const Spec: TBridgeSpec; Composite: TGroundCompositeMesh);
var
  L, R: TXZArray;
  halfW, vScale: Single;
  i: Integer;
  iR0, iL0, iL1, iR1: Integer;
  N0, N1: TVector3;

  { нормаль настила в вершине idx: перпендикуляр к 3D-касательной вдоль оси и
    горизонтальному поперечнику (настил плоский поперёк ширины). }
  function NrmAt(idx: Integer): TVector3;
  var a, b: Integer; tx, ty, tz, px, pz, rx, ry, rz, l: Double;
  begin
    a := idx - 1; if a < 0 then a := 0;
    b := idx + 1; if b > High(Spec.Center) then b := High(Spec.Center);
    tx := Spec.Center[b].X - Spec.Center[a].X;
    tz := Spec.Center[b].Z - Spec.Center[a].Z;
    ty := Spec.CenterY[b] - Spec.CenterY[a];
    PerpAt(Spec.Center, idx, px, pz);              { горизонтальный поперечник (ширина) }
    rx := 0.0*tz - pz*ty;                           { N = cross((px,0,pz),(tx,ty,tz)) }
    ry := pz*tx - px*tz;
    rz := px*ty - 0.0*tx;
    l := Sqrt(rx*rx + ry*ry + rz*rz);
    if l > 1e-9 then begin rx := rx/l; ry := ry/l; rz := rz/l; end
    else begin rx := 0.0; ry := 1.0; rz := 0.0; end;
    if ry < 0 then begin rx := -rx; ry := -ry; rz := -rz; end;     { вверх }
    Result := Vector3(Single(rx), Single(ry), Single(rz));
  end;

  function Mk(const PXZ: TXZ; Yv: Single; const N: TVector3; U, V: Single): TMeshVertex;
  begin
    Result.Position := Vector3(Single(PXZ.X), Yv, Single(PXZ.Z));
    Result.Normal   := N;
    Result.UV       := MakeUV(U, V);
    Result.OsmId    := Spec.WayId;
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1612);{$ENDIF}
  if (Composite = nil) or (Length(Spec.Center) < 2) then Exit;
  if Length(Spec.CenterY) < Length(Spec.Center) then Exit;
  halfW := Spec.Width * 0.5;
  if halfW < 0.05 then halfW := 0.05;
  vScale := Spec.UVScaleY;
  if vScale <= 0 then vScale := 1.0;

  { Знак ДОЛЖЕН совпадать с дорогой (Osm3dGeomRoadJoints: Right = Center +
    (+Dz,-Dx)*halfW, Left = Center + (-Dz,+Dx)*halfW). PerpAt даёт (+Dz,-Dx),
    значит правый край = +halfW, левый = -halfW. Иначе намотка переворачивается
    и при Solid=TRUE (бэкфейс-куллинг) настил смотрит ВНИЗ и не виден. }
  OffsetPolyline(Spec.Center, -halfW, L);   { левый  край -> UVMaxX }
  OffsetPolyline(Spec.Center,  halfW, R);   { правый край -> UVMinX }

  for i := 0 to High(Spec.Center) - 1 do
  begin
    N0 := NrmAt(i);
    N1 := NrmAt(i+1);
    iR0 := Composite.AppendVertex(Mk(R[i],   Spec.CenterY[i],   N0, Spec.UVMinX, Spec.AccumLen[i]   / vScale), Spec.Mat);
    iL0 := Composite.AppendVertex(Mk(L[i],   Spec.CenterY[i],   N0, Spec.UVMaxX, Spec.AccumLen[i]   / vScale), Spec.Mat);
    iL1 := Composite.AppendVertex(Mk(L[i+1], Spec.CenterY[i+1], N1, Spec.UVMaxX, Spec.AccumLen[i+1] / vScale), Spec.Mat);
    iR1 := Composite.AppendVertex(Mk(R[i+1], Spec.CenterY[i+1], N1, Spec.UVMinX, Spec.AccumLen[i+1] / vScale), Spec.Mat);
    { тот же веер из двух треугольников, что AddQuad(R0,L0,L1,R1) }
    Composite.AppendTriangle(iR0, iL0, iL1, -1);
    Composite.AppendTriangle(iR0, iL1, iR1, -1);
  end;
end;

{ Один бетонный парапет вдоль ломаной: повторяет вертикальную раскладку
  заборного квада (низ-лево, низ-право, верх-право, верх-лево; горизонтальная
  нормаль; U = пробег / FenceUVWidth, V 0..1). Низ каждой вершины — BaseY[i]
  (высота настила там), верх — BaseY[i] + RailH: стойки вертикальные, поручень
  идёт по уклону настила (горизонталь — ровно, заезд — наклонно). Один квад на
  сегмент (дробление не нужно). }
procedure EmitRailRun(const Pts: TXZArray; const BaseY: TSingleArray;
  RailH: Single; Mat: Integer; Target: TMesh; WayId: Int64);
var
  i: Integer;
  ax, az, bx, bz, dx, dz, segLen: Single;
  nx, nz, invW, uvW, uProg, u0, u1: Single;
  N: TVector3;
  baseYa, baseYb, topYa, topYb: Single;
  v00, v10, v11, v01: Integer;
  prevOsm: Int64;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1613);{$ENDIF}
  if (Target = nil) or (Length(Pts) < 2) then Exit;
  if Length(BaseY) < Length(Pts) then Exit;
  uvW := TFenceBuilder.FenceUVWidth(Mat, RailH);
  if uvW < 1e-3 then uvW := 1.0;
  invW := 1.0 / uvW;

  prevOsm := Target.CurrentOsmId;
  Target.CurrentOsmId := WayId;
  try
    uProg := 0.0;
    for i := 0 to High(Pts) - 1 do
    begin
      ax := Single(Pts[i].X);   az := Single(Pts[i].Z);
      bx := Single(Pts[i+1].X); bz := Single(Pts[i+1].Z);
      dx := bx - ax; dz := bz - az;
      segLen := Sqrt(dx*dx + dz*dz);
      if segLen < 1e-6 then Continue;       { совпавшие точки — нет продвижения }

      nx := dz / segLen; nz := -dx / segLen;
      N  := Vector3(nx, 0.0, nz);
      baseYa := BaseY[i];   topYa := baseYa + RailH;
      baseYb := BaseY[i+1]; topYb := baseYb + RailH;
      u0 := uProg * invW;
      u1 := (uProg + segLen) * invW;

      { низ-лево, низ-право, верх-право, верх-лево }
      v00 := Target.AddVertex(Vector3(ax, baseYa, az), N, MakeUV(u0, 0.0));
      v10 := Target.AddVertex(Vector3(bx, baseYb, bz), N, MakeUV(u1, 0.0));
      v11 := Target.AddVertex(Vector3(bx, topYb,  bz), N, MakeUV(u1, 1.0));
      v01 := Target.AddVertex(Vector3(ax, topYa,  az), N, MakeUV(u0, 1.0));
      Target.AddQuad(v00, v10, v11, v01);

      uProg := uProg + segLen;
    end;
  finally
    Target.CurrentOsmId := prevOsm;
  end;
end;

{ ----- Точная подрезка дорожного полотна под стык с настилом -----------------
  PlaceBridge уже посчитал ТОЧНЫЕ концы настила. Полотно примыкающей дороги,
  уходящее ПОД настил (под заезд и пролёт), нужно убрать из дорожных мешей ДО
  карвинга: иначе карвинг впечатает дорогу в рельеф под мостом, и она будет
  торчать из-под приподнятого настила. Режем ровно по поперечнику в точке
  посадки заезда и оставляем ВНЕШНЮЮ (от моста наружу) половину; перекрытие
  настила (Center[0]→Center[1]) ложится на оставленную дорогу и закрывает
  поперечный шов — стык гладкий. Режем настоящим слайсером (Сазерленд–Ходжман
  в XZ с интерполяцией Position/Normal/UV), а не выбрасыванием целых
  треугольников, поэтому линия среза ровная. Подрезаем ТОЛЬКО треугольники той
  самой примыкающей дороги (по OsmId вершины); поперечные дороги под пролётом
  (другой OsmId) не трогаем. }

type
  { Поперечник среза одного стыка: полуплоскость в XZ. Оставляем точки со
    стороной s(Q) = (Q.X-Px)*OutDx + (Q.Z-Pz)*OutDz >= -EPS (наружу от моста). }
  TDeckClipLine = record
    WayId:        Int64;
    Px, Pz:       Double;
    OutDx, OutDz: Double;
  end;
  TDeckClipLineArray = array of TDeckClipLine;

const
  DECK_CLIP_EPS = 1.0e-4;        { 0.1 мм: точки ровно на линии относим внутрь }

{ Угол (0..90°) между ненаправленными 2D-векторами. }
function UndirAngDegXZ(AX, AZ, BX, BZ: Single): Single;
var
  la, lb, c: Single;
begin
  la := Sqrt(AX * AX + AZ * AZ);
  lb := Sqrt(BX * BX + BZ * BZ);
  if (la < 1e-6) or (lb < 1e-6) then Exit(90);
  c := (AX * BX + AZ * BZ) / (la * lb);
  if c < 0 then c := -c;
  if c > 1 then c := 1;
  Result := RadToDeg(ArcCos(c));
end;

{ Линейная интерполяция вершины меша вдоль ребра A->B при параметре t∈[0,1].
  Position/UV — линейно, Normal — линейно + ренормировка, OsmId наследуется
  (обе вершины ребра одного пути). }
function LerpMeshVertex(const A, B: TMeshVertex; t: Double): TMeshVertex;
var
  nx, ny, nz, l: Double;
begin
  if t < 0 then t := 0 else if t > 1 then t := 1;
  Result.Position.X := Single(A.Position.X + t*(B.Position.X - A.Position.X));
  Result.Position.Y := Single(A.Position.Y + t*(B.Position.Y - A.Position.Y));
  Result.Position.Z := Single(A.Position.Z + t*(B.Position.Z - A.Position.Z));
  nx := A.Normal.X + t*(B.Normal.X - A.Normal.X);
  ny := A.Normal.Y + t*(B.Normal.Y - A.Normal.Y);
  nz := A.Normal.Z + t*(B.Normal.Z - A.Normal.Z);
  l := Sqrt(nx*nx + ny*ny + nz*nz);
  if l > 1e-9 then
  begin
    Result.Normal.X := Single(nx/l);
    Result.Normal.Y := Single(ny/l);
    Result.Normal.Z := Single(nz/l);
  end
  else
    Result.Normal := A.Normal;
  Result.UV.X := Single(A.UV.X + t*(B.UV.X - A.UV.X));
  Result.UV.Y := Single(A.UV.Y + t*(B.UV.Y - A.UV.Y));
  if A.OsmId <> 0 then Result.OsmId := A.OsmId else Result.OsmId := B.OsmId;
end;

{ Подрезать выпуклый полигон (вершины меша) одной полуплоскостью XZ. Один
  проход Сазерленда–Ходжмана: на каждое ребро cur->next выдаём cur (если внутри)
  и точку пересечения (если ребро пересекает границу). Запись в OutPoly с
  защитой от переполнения буфера (режимы $R- — переполнение молча затёрло бы
  стек). }
procedure ClipPolyHalfPlaneXZ(const InPoly: array of TMeshVertex; InCnt: Integer;
  Px, Pz, Dx, Dz: Double; var OutPoly: array of TMeshVertex; out OutCnt: Integer);
var
  i, j, cap: Integer;
  sCur, sNext, t: Double;
  curIn, nextIn: Boolean;

  procedure PushOut(const V: TMeshVertex);
  begin
    if OutCnt <= cap then begin OutPoly[OutCnt] := V; Inc(OutCnt); end;
  end;

begin
  OutCnt := 0;
  cap := High(OutPoly);
  if InCnt < 2 then Exit;
  for i := 0 to InCnt - 1 do
  begin
    j := i + 1; if j = InCnt then j := 0;
    sCur  := (InPoly[i].Position.X - Px)*Dx + (InPoly[i].Position.Z - Pz)*Dz;
    sNext := (InPoly[j].Position.X - Px)*Dx + (InPoly[j].Position.Z - Pz)*Dz;
    curIn  := sCur  >= -DECK_CLIP_EPS;
    nextIn := sNext >= -DECK_CLIP_EPS;
    if curIn then PushOut(InPoly[i]);
    if curIn <> nextIn then
    begin
      if Abs(sCur - sNext) > 1e-12 then t := sCur / (sCur - sNext) else t := 0.0;
      PushOut(LerpMeshVertex(InPoly[i], InPoly[j], t));
    end;
  end;
end;

{ Направление «вдоль ленты» для UV-меша: ребро с max |ΔUV.Y| (AccumLen).
  Без UV — fallback на самое длинное XZ-ребро. }
procedure TriAlongDir(const A, B, C: TMeshVertex; out DX, DZ: Single);
var
  dU, best: Single;
begin
  best := -1; DX := B.Position.X - A.Position.X; DZ := B.Position.Z - A.Position.Z;
  dU := Abs(B.UV.Y - A.UV.Y);
  if dU > best then begin best := dU; DX := B.Position.X - A.Position.X; DZ := B.Position.Z - A.Position.Z; end;
  dU := Abs(C.UV.Y - B.UV.Y);
  if dU > best then begin best := dU; DX := C.Position.X - B.Position.X; DZ := C.Position.Z - B.Position.Z; end;
  dU := Abs(A.UV.Y - C.UV.Y);
  if dU > best then begin best := dU; DX := A.Position.X - C.Position.X; DZ := A.Position.Z - C.Position.Z; end;
  if best < 1e-8 then
  begin
    { UV.Y не информативен — longest XZ edge }
    DX := B.Position.X - A.Position.X; DZ := B.Position.Z - A.Position.Z;
    if Sqr(C.Position.X - B.Position.X) + Sqr(C.Position.Z - B.Position.Z) >
       DX * DX + DZ * DZ then
    begin DX := C.Position.X - B.Position.X; DZ := C.Position.Z - B.Position.Z; end;
    if Sqr(A.Position.X - C.Position.X) + Sqr(A.Position.Z - C.Position.Z) >
       DX * DX + DZ * DZ then
    begin DX := A.Position.X - C.Position.X; DZ := A.Position.Z - C.Position.Z; end;
  end;
end;

{ Пересобрать меш: полуплоскости Lines режут треугольники (Сазерленд–Ходжман —
  появляются новые вершины на линии стыка). Срабатывает если:
  • OsmId = Line.WayId, или
  • цепочка way: треугольник параллелен OutDx (вдоль ленты по UV.Y) и
    центроид в 30 m от точки стыка — тогда тот же half-plane.
  Поперечная (угол > 40° к OutDx) никогда не режется. }
function ClipMeshUnderDecks(M: TMesh; const Lines: TDeckClipLineArray): Boolean;
var
  lv: TMeshVertexArray;
  li: TMeshIndexArray;
  remap: array of Integer;
  newV: TMeshVertexArray;
  newI: TMeshIndexArray;
  nv, ni, tcount, t, k, c: Integer;
  i0, i1, i2: Cardinal;
  wid: Int64;
  polyA, polyB: array[0..63] of TMeshVertex;
  fanIdx: array[0..63] of Cardinal;
  aCnt, bCnt: Integer;
  wayHit: Boolean;
  cx, cz, edx, edz, d2, bestD2: Single;
  bestK: Integer;

  function MapOld(idx: Cardinal): Cardinal;
  begin
    if remap[idx] < 0 then
    begin
      if nv >= Length(newV) then SetLength(newV, (nv + 1) * 2);
      newV[nv] := lv[idx];
      remap[idx] := nv;
      Inc(nv);
    end;
    Result := Cardinal(remap[idx]);
  end;

  function PushVert(const V: TMeshVertex): Cardinal;
  begin
    if nv >= Length(newV) then SetLength(newV, (nv + 1) * 2);
    newV[nv] := V;
    Result := Cardinal(nv);
    Inc(nv);
  end;

  procedure PushTri(a, b, cc: Cardinal);
  begin
    if ni + 3 > Length(newI) then SetLength(newI, (ni + 3) * 2);
    newI[ni] := a; newI[ni+1] := b; newI[ni+2] := cc; Inc(ni, 3);
  end;

begin
  Result := False;
  if (M = nil) or (M.TriangleCount = 0) or (Length(Lines) = 0) then Exit;

  lv := M.Vertices;
  li := M.Indices;
  tcount := Length(li) div 3;
  SetLength(remap, Length(lv));
  for t := 0 to High(remap) do remap[t] := -1;
  nv := 0; ni := 0;
  SetLength(newV, Length(lv));
  SetLength(newI, Length(li));

  for t := 0 to tcount - 1 do
  begin
    i0 := li[t*3]; i1 := li[t*3+1]; i2 := li[t*3+2];
    wid := lv[i0].OsmId;
    if wid = 0 then wid := lv[i1].OsmId;
    if wid = 0 then wid := lv[i2].OsmId;

    polyA[0] := lv[i0]; polyA[1] := lv[i1]; polyA[2] := lv[i2];
    aCnt := 3;
    wayHit := False;
    TriAlongDir(lv[i0], lv[i1], lv[i2], edx, edz);
    cx := (lv[i0].Position.X + lv[i1].Position.X + lv[i2].Position.X) / 3.0;
    cz := (lv[i0].Position.Z + lv[i1].Position.Z + lv[i2].Position.Z) / 3.0;

    { 1) Все half-plane с точным OsmId (заезд/съезд этого way).
       2) Если ни одной — не больше ОДНОЙ spatial (ближайший стык, parallel),
          иначе несколько мостов подряд «съедают» полотно. }
    for k := 0 to High(Lines) do
    begin
      if Lines[k].WayId <> wid then Continue;
      wayHit := True;
      ClipPolyHalfPlaneXZ(polyA, aCnt, Lines[k].Px, Lines[k].Pz,
        Lines[k].OutDx, Lines[k].OutDz, polyB, bCnt);
      for c := 0 to bCnt - 1 do polyA[c] := polyB[c];
      aCnt := bCnt;
      if aCnt < 3 then Break;
    end;
    if (not wayHit) and (aCnt >= 3) then
    begin
      { spatial: одна ближайшая линия }
      bestK := -1; bestD2 := 1e30;
      for k := 0 to High(Lines) do
      begin
        d2 := Sqr(cx - Lines[k].Px) + Sqr(cz - Lines[k].Pz);
        if d2 > Sqr(25.0) then Continue;
        if UndirAngDegXZ(edx, edz, Single(Lines[k].OutDx),
             Single(Lines[k].OutDz)) > 35.0 then
          Continue;
        if d2 < bestD2 then begin bestD2 := d2; bestK := k; end;
      end;
      if bestK >= 0 then
      begin
        wayHit := True;
        ClipPolyHalfPlaneXZ(polyA, aCnt, Lines[bestK].Px, Lines[bestK].Pz,
          Lines[bestK].OutDx, Lines[bestK].OutDz, polyB, bCnt);
        aCnt := bCnt;
        for c := 0 to bCnt - 1 do polyA[c] := polyB[c];
      end;
    end;

    if not wayHit then
    begin
      PushTri(MapOld(i0), MapOld(i1), MapOld(i2));
      Continue;
    end;

    Result := True;
    if aCnt < 3 then Continue;      { целиком на стороне моста — убран }

    { веер: новые вершины ровно на линии стыка }
    for c := 0 to aCnt - 1 do fanIdx[c] := PushVert(polyA[c]);
    for c := 1 to aCnt - 2 do PushTri(fanIdx[0], fanIdx[c], fanIdx[c+1]);
  end;

  if not Result then Exit;

  M.Clear;
  M.ReserveVertices(nv);
  M.ReserveIndices(ni);
  for t := 0 to nv - 1 do M.AddVertex(newV[t]);
  t := 0;
  while t < ni do
  begin
    M.AddTriangle(Integer(newI[t]), Integer(newI[t+1]), Integer(newI[t+2]));
    Inc(t, 3);
  end;
end;

{ -------------------------------------------------------------- TBridgeBuilder }

{ Именованный водоток (спроецированная осевая) — для поиска реки под мостом. }
type
  TNamedWaterway = record
    Name: string;
    Rank: Integer;       { река=3 > канал=2 > ручей=1 > прочее=0 — приоритет }
    Pts:  TXZArray;      { спроецированные узлы }
  end;
  TNamedWaterwayArray = array of TNamedWaterway;

{ Строгое пересечение отрезков a1a2 и b1b2 в плоскости XZ (касания/коллинеарность
  не считаем — для перекрытия «мост × река» нужен честный крест). }
function SegSegCrossXZ(const a1, a2, b1, b2: TXZ): Boolean;
  function Orient(const p, q, r: TXZ): Double;
  begin
    Orient := (q.X - p.X)*(r.Z - p.Z) - (q.Z - p.Z)*(r.X - p.X);
  end;
var d1, d2, d3, d4: Double;
begin
  d1 := Orient(b1, b2, a1);
  d2 := Orient(b1, b2, a2);
  d3 := Orient(a1, a2, b1);
  d4 := Orient(a1, a2, b2);
  SegSegCrossXZ := (((d1 > 0) and (d2 < 0)) or ((d1 < 0) and (d2 > 0))) and
                   (((d3 > 0) and (d4 < 0)) or ((d3 < 0) and (d4 > 0)));
end;

{ Пересекает ли пролёт C (ломаная) осевую водотока Pts. }
function SpanCrossesWaterway(const C, Pts: TXZArray): Boolean;
var i, j: Integer;
begin
  SpanCrossesWaterway := False;
  for i := 0 to High(C) - 1 do
    for j := 0 to High(Pts) - 1 do
      if SegSegCrossXZ(C[i], C[i+1], Pts[j], Pts[j+1]) then Exit(True);
end;

{ Один раз по датасету: собрать ИМЕНОВАННЫЕ водотоки (waterway + name) в виде
  спроецированных ломаных с приоритетом по типу. }
function CollectNamedWaterways(Dataset: TOSMDataset;
  Projection: TLocalProjection): TNamedWaterwayArray;
var
  Way: TOSMWay;
  Node: TOSMNode;
  Pr: TVector3;
  wpts: TXZArray;
  nm, wv: string;
  i, pk, rc: Integer;
begin
  Result := nil; rc := 0; wpts := nil;
  if Dataset = nil then Exit;
  for Way in Dataset.Ways.Values do
  begin
    if Way = nil then Continue;
    if not Way.Tags.HasKey('waterway') then Continue;
    nm := Trim(Way.Tags.Get('name'));
    if nm = '' then Continue;
    if Length(Way.NodeRefs) < 2 then Continue;
    { wpts — переиспользуемый буфер: растим только если этому way нужно больше,
      не ужимаем (Copy ниже всё равно берёт ровно pk) — нет перевыделения на
      каждый way. }
    if Length(Way.NodeRefs) > Length(wpts) then SetLength(wpts, Length(Way.NodeRefs));
    pk := 0;
    for i := 0 to High(Way.NodeRefs) do
    begin
      Node := Dataset.FindNode(Way.NodeRefs[i]);
      if Node = nil then Continue;
      Pr := NodePlanePos(Dataset, Node, Projection);   { int-first }
      wpts[pk].X := Pr.X; wpts[pk].Z := Pr.Z; Inc(pk);
    end;
    if pk < 2 then Continue;
    wv := Way.Tags.GetLower('waterway');
    if rc >= Length(Result) then SetLength(Result, (rc + 1) * 2);
    Result[rc].Name := nm;
    if      wv = 'river'  then Result[rc].Rank := 3
    else if wv = 'canal'  then Result[rc].Rank := 2
    else if wv = 'stream' then Result[rc].Rank := 1
    else                       Result[rc].Rank := 0;
    Result[rc].Pts := Copy(wpts, 0, pk);
    Inc(rc);
  end;
  SetLength(Result, rc);
end;

{ Имя реки под пролётом C: из пересекаемых именованных водотоков берём с
  наибольшим Rank (река важнее канавы); '' — ничего не пересекаем. }
function RiverNameUnderSpan(const Waterways: TNamedWaterwayArray;
  const C: TXZArray): string;
var i, bestRank: Integer;
begin
  RiverNameUnderSpan := ''; bestRank := -1;
  for i := 0 to High(Waterways) do
    if (Waterways[i].Rank > bestRank) and SpanCrossesWaterway(C, Waterways[i].Pts) then
    begin
      bestRank := Waterways[i].Rank;
      RiverNameUnderSpan := Waterways[i].Name;
    end;
end;

class function TBridgeBuilder.CollectSpanMask(Dataset: TOSMDataset;
  Projection: TLocalProjection; AMarginM: Single): TBridgeSpanMask;
var
  Way: TOSMWay;
  Params: TRoadParams;
  wv: string;
  halfW: Single;
  nsegVar: Integer;

  { Полуширина коридора маски по OSM-тегу width (если есть) или дефолту типа
    водотока, м. Маска влияет ТОЛЬКО на FIT-поднятые узлы (иначе GroundHeightGeo
    и так отдаёт DEM), поэтому осевые водотоков вне дорог — холостые. }
  function WaterwayHalfW(const ATags: TOSMTags; const AWv: string): Single;
  var w: Single; s: string;
  begin
    s := Trim(ATags.Get('width'));
    w := 0;
    if s <> '' then w := StrToFloatDef(StringReplace(s, ',', '.', [rfReplaceAll]), 0);
    if w > 0.5 then
      Result := w * 0.5
    else if AWv = 'river' then Result := 5.0
    else if AWv = 'canal' then Result := 4.0
    else if AWv = 'stream' then Result := 2.0
    else Result := 1.5;                         { ditch / drain / прочее }
    Result := Result + 1.5;                      { небольшой запас на кромку воды }
  end;

  { Спроецировать узлы way (int-first, без подряд-дубликатов) и добавить его
    сегменты в маску: AHW — поперечная полуширина, AEndM — продольный запас
    за концы сегмента (см. TBridgeMaskSeg в Osm3dGeomTerrain). }
  procedure AddWaySegments(AWay: TOSMWay; AHW, AEndM: Single; AMinorWater: Boolean);
  var
    Node: TOSMNode;
    Pr: TVector3;
    C: TXZArray;
    i, k: Integer;
    lastX, lastZ: Single;
    haveLast: Boolean;
  begin
    if (AWay = nil) or (Length(AWay.NodeRefs) < 2) then Exit;
    SetLength(C, Length(AWay.NodeRefs));
    k := 0; haveLast := False; lastX := 0; lastZ := 0;
    for i := 0 to High(AWay.NodeRefs) do
    begin
      Node := Dataset.FindNode(AWay.NodeRefs[i]);
      if Node = nil then Continue;
      Pr := NodePlanePos(Dataset, Node, Projection);   { int-first }
      if haveLast and (Abs(Pr.X - lastX) < 1e-4) and (Abs(Pr.Z - lastZ) < 1e-4) then
        Continue;
      C[k].X := Pr.X; C[k].Z := Pr.Z;
      lastX := Pr.X; lastZ := Pr.Z; haveLast := True;
      Inc(k);
    end;
    if k < 2 then Exit;
    for i := 0 to k - 2 do
    begin
      if nsegVar >= Length(Result) then SetLength(Result, (nsegVar + 1) * 2);
      Result[nsegVar].AX := Single(C[i].X);   Result[nsegVar].AZ := Single(C[i].Z);
      Result[nsegVar].BX := Single(C[i+1].X); Result[nsegVar].BZ := Single(C[i+1].Z);
      Result[nsegVar].HalfW := AHW;
      Result[nsegVar].EndM  := AEndM;
      Result[nsegVar].MinorWater := AMinorWater;
      Inc(nsegVar);
    end;
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1618);{$ENDIF}
  Result := nil; nsegVar := 0;
  if (Dataset = nil) or (Projection = nil) or (Dataset.Ways = nil) then Exit;

  for Way in Dataset.Ways.Values do
  begin
    if Way = nil then Continue;

    { 1. Мостовые пролёты (bridge=yes на реальной дороге). ПОПЕРЁК коридор
      обязан накрыть FIT-насыпь на ВСЮ её ширину (полный коридор слоя
      HALF+FEATHER, иначе сбоку от настила остаётся стена нетронутой
      насыпи). ПРОДОЛЬНО вырез НЕ выходит за торцы пролёта (EndM=0): за
      торцом сразу насыпь подхода — дорога перед мостом и пятка настила
      сэмплируют её уровень и стыкуются заподлицо. Любой продольный запас
      (был 3 м) клал за торец полосу DEM: полотно подхода ныряло по срезу
      вниз, пятка настила за ним — щель на краях моста. }
    if OsmWayIsBridge(Way.Tags) then
    begin
      Params := TRoadBuilder.ParseRoadParams(Way.Tags);
      if Params.Kind <> rkNone then
        AddWaySegments(Way,
          Max(Params.Width * 0.5 + AMarginM,
              FITL_HALF_WIDTH_M + FITL_FEATHER_M + 1.0),
          0.0, False);
    end;

    { 2. Водотоки: где FIT-насыпь легла ПОВЕРХ реки/ручья/канала — вернуть DEM,
      чтобы вода не оказалась под насыпью (osm bridge=yes часто в 1–2 м, шире
      реки его не покрыть). На узлы без FIT-подъёма маска не влияет.
      EndM = HalfW — прежний «стадионный» охват у концов. }
    wv := Way.Tags.GetLower('waterway');
    if ((wv = 'river') or (wv = 'stream') or (wv = 'canal')
       or (wv = 'ditch') or (wv = 'drain')) and
       not TWaterBuilder.Underground(Way.Tags) then
    begin
      halfW := WaterwayHalfW(Way.Tags, wv);
      AddWaySegments(Way, halfW, halfW, TWaterBuilder.MinorWaterway(Way.Tags));
    end;
  end;
  SetLength(Result, nsegVar);
end;

class function TBridgeBuilder.Collect(Dataset: TOSMDataset;
  Projection: TLocalProjection; Sampler: TTerrainSampler;
  LogProc: TLogProc;
  ARoadIdx: TOsmRoadIndex;
  AFitLayer: TFitHeightLayer): TBridgeSpecArray;
var
  Way: TOSMWay;
  Params: TRoadParams;
  Mat: TGroundMaterialId;
  Node: TOSMNode;
  Pr: TVector3;
  C, CDeck, ApprStart, ApprEnd: TXZArray;
  CDeckY, Acc: TSingleArray;
  i, k, kd, count: Integer;
  startNodeId, endNodeId: Int64;
  apprStartWayId, apprEndWayId: Int64;
  lastX, lastZ: Single;
  ddx, ddz, ddy, total: Single;
  sOdx, sOdz, eOdx, eOdz, ol2: Double;
  haveLast: Boolean;
  Spec: TBridgeSpec;
  Waterways: TNamedWaterwayArray;
  RailLines: array of TXZArray;
  nRail, pk: Integer;
  minClear: Single;
  wpts: TXZArray;
  rv: string;
  weldB: Boolean;   { PlaceBridge: FIT-мост состыкован «одной геометрией» }
  nWeld: Integer;

  { пересекает ли пролёт Cc какую-либо ж/д осевую }
  function SpanCrossesAnyRail(const Cc: TXZArray): Boolean;
  var rj: Integer;
  begin
    Result := False;
    for rj := 0 to nRail - 1 do
      if SpanCrossesWaterway(Cc, RailLines[rj]) then Exit(True);
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1614);{$ENDIF}
  Result := nil;
  count := 0;
  nWeld := 0;
  C := nil; CDeck := nil; CDeckY := nil; Acc := nil;   { локальные динмассивы }
  ApprStart := nil; ApprEnd := nil;
  if (Dataset = nil) or (Projection = nil) then Exit;

  { Один проход: именованные водотоки тайла — для подписи реки под мостом. }
  Waterways := CollectNamedWaterways(Dataset, Projection);

  { ж/д осевые тайла — для подъёма теговых мостов над ж/д до
    BRIDGE_RAIL_CROSS_CLEAR_M (только линейные пути, не платформы/станции). }
  RailLines := nil; nRail := 0; wpts := nil;
  for Way in Dataset.Ways.Values do
  begin
    if Way = nil then Continue;
    rv := Way.Tags.GetLower('railway');
    if not ((rv = 'rail') or (rv = 'light_rail') or (rv = 'subway')
            or (rv = 'tram') or (rv = 'narrow_gauge') or (rv = 'funicular')
            or (rv = 'monorail') or (rv = 'preserved')) then Continue;
    if Length(Way.NodeRefs) < 2 then Continue;
    if Length(Way.NodeRefs) > Length(wpts) then SetLength(wpts, Length(Way.NodeRefs));
    pk := 0;
    for i := 0 to High(Way.NodeRefs) do
    begin
      Node := Dataset.FindNode(Way.NodeRefs[i]);
      if Node = nil then Continue;
      Pr := NodePlanePos(Dataset, Node, Projection);   { int-first }
      wpts[pk].X := Pr.X; wpts[pk].Z := Pr.Z; Inc(pk);
    end;
    if pk < 2 then Continue;
    if nRail >= Length(RailLines) then SetLength(RailLines, (nRail + 1) * 2);
    RailLines[nRail] := Copy(wpts, 0, pk);
    Inc(nRail);
  end;
  SetLength(RailLines, nRail);

  for Way in Dataset.Ways.Values do
  begin
    if Way = nil then Continue;
    if not OsmWayIsBridge(Way.Tags) then Continue;
    Params := TRoadBuilder.ParseRoadParams(Way.Tags);
    if Params.Kind = rkNone then Continue;            { мост не по дороге — пропуск }
    Mat := GROUND_MAT_FOR_ROAD[Params.Kind];
    if Mat = GROUND_MAT_NONE then Continue;
    if Length(Way.NodeRefs) < 2 then Continue;

    { проекция узлов + отбрасывание подряд идущих дубликатов }
    SetLength(C, Length(Way.NodeRefs));
    k := 0;
    haveLast := False;
    lastX := 0; lastZ := 0;
    for i := 0 to High(Way.NodeRefs) do
    begin
      Node := Dataset.FindNode(Way.NodeRefs[i]);
      if Node = nil then Continue;
      Pr := NodePlanePos(Dataset, Node, Projection);   { int-first }
      if haveLast and (Abs(Pr.X - lastX) < 1e-4) and (Abs(Pr.Z - lastZ) < 1e-4) then
        Continue;
      C[k].X := Pr.X; C[k].Z := Pr.Z;
      lastX := Pr.X; lastZ := Pr.Z; haveLast := True;
      Inc(k);
    end;
    SetLength(C, k);
    if k < 2 then Continue;

    { длина исходного пролёта для порога BRIDGE_MIN_LEN_M и для критерия ½ в
      PlaceBridge (фильтр мусорных bridge=yes на микро-перемычках). }
    total := 0.0;
    for i := 1 to k - 1 do
    begin
      ddx := Single(C[i].X - C[i-1].X);
      ddz := Single(C[i].Z - C[i-1].Z);
      total := total + Sqrt(ddx*ddx + ddz*ddz);
    end;
    if total < BRIDGE_MIN_LEN_M then Continue;

    { примыкающие дороги за концами (наружу-направления концов из C) }
    startNodeId := Way.NodeRefs[0];
    endNodeId   := Way.NodeRefs[High(Way.NodeRefs)];
    sOdx := C[0].X - C[1].X; sOdz := C[0].Z - C[1].Z; ol2 := Sqrt(sOdx*sOdx + sOdz*sOdz);
    if ol2 > 1e-9 then begin sOdx := sOdx/ol2; sOdz := sOdz/ol2; end else begin sOdx := 0.0; sOdz := 0.0; end;
    eOdx := C[k-1].X - C[k-2].X; eOdz := C[k-1].Z - C[k-2].Z; ol2 := Sqrt(eOdx*eOdx + eOdz*eOdz);
    if ol2 > 1e-9 then begin eOdx := eOdx/ol2; eOdz := eOdz/ol2; end else begin eOdx := 0.0; eOdz := 0.0; end;
    FindApproach(Dataset, Projection, Way.Id, startNodeId, sOdx, sOdz,
      3.0*total + 100.0, ARoadIdx, ApprStart, apprStartWayId);
    FindApproach(Dataset, Projection, Way.Id, endNodeId,   eOdx, eOdz,
      3.0*total + 100.0, ARoadIdx, ApprEnd,   apprEndWayId);

    { Мост над ж/д -> высокий габарит (BRIDGE_RAIL_CROSS_CLEAR_M). }
    minClear := 0.0;
    if SpanCrossesAnyRail(C) then
    begin
      minClear := BRIDGE_RAIL_CROSS_CLEAR_M;
      if Assigned(LogProc) then
        LogProc(Format('Osm3dGeomBridges: bridge way=%d crosses railway -> raised to %.1f m clearance',
          [Way.Id, BRIDGE_RAIL_CROSS_CLEAR_M]));
    end;

    { Пересчёт реальной позиции моста по рельефу + стыковка с дорогами. Настил
      по FIT (AFitLayer) — верхний уровень над пролётом; рельеф — сырой DEM. }
    weldB := False;
    PlaceBridge(C, total, Params.Width * 0.5, Sampler, Projection, ApprStart, ApprEnd,
                CDeck, CDeckY, Way.Id, count, LogProc, minClear, AFitLayer, @weldB);
    kd := Length(CDeck);
    if (kd < 2) or (Length(CDeckY) < kd) then Continue;

    { накопленная длина вдоль 3D-осевой — для V-развёртки настила. }
    SetLength(Acc, kd);
    Acc[0] := 0.0;
    total := 0.0;
    for i := 1 to kd - 1 do
    begin
      ddx := Single(CDeck[i].X - CDeck[i-1].X);
      ddz := Single(CDeck[i].Z - CDeck[i-1].Z);
      ddy := CDeckY[i] - CDeckY[i-1];
      total := total + Sqrt(ddx*ddx + ddz*ddz + ddy*ddy);
      Acc[i] := total;
    end;

    Spec.WayId    := Way.Id;
    Spec.Num      := count;   { сквозной номер: тот же в логе и на речной табличке }
    Spec.Center   := Copy(CDeck, 0, kd);
    SetLength(Spec.CenterY, kd);
    for i := 0 to kd - 1 do Spec.CenterY[i] := CDeckY[i];
    SetLength(Spec.AccumLen, kd);
    for i := 0 to kd - 1 do Spec.AccumLen[i] := Acc[i];
    Spec.Width    := Params.Width;
    Spec.Mat      := Mat;
    Spec.UVScaleY := TRoadBuilder.ClassUVScaleY(Params);
    Spec.UVMinX   := Params.UVMinX;
    Spec.UVMaxX   := Params.UVMaxX;
    Spec.ApprStartWayId := apprStartWayId;
    Spec.ApprEndWayId   := apprEndWayId;
    Spec.WeldJoints     := weldB;
    if weldB then Inc(nWeld);
    { Имя реки под мостом — по пересечению ИСХОДНОГО пролёта C с водотоками. }
    Spec.RiverName := RiverNameUnderSpan(Waterways, C);

    if count >= Length(Result) then
      SetLength(Result, (count + 1) * 2);
    Result[count] := Spec;
    Inc(count);
  end;

  SetLength(Result, count);
  if Assigned(LogProc) then
    LogProc(Format('Osm3dGeomBridges: %d bridge way(s) collected (%d welded to road — «одна геометрия»)',
      [count, nWeld]));
end;

class procedure TBridgeBuilder.EmitDeck(const Spec: TBridgeSpec;
  Composite: TGroundCompositeMesh);
begin
  EmitDeckCore(Spec, Composite);
end;

class procedure TBridgeBuilder.Emit(const Specs: TBridgeSpecArray;
  Composite: TGroundCompositeMesh; var Fences: TFenceMeshes;
  GenerateFences: Boolean; LogProc: TLogProc);
var
  s, concMat, i, an, preVert, preTri, vEnd, tEnd, vspan, decks, rails: Integer;
  preComposVerts, preComposTris: Integer;
  halfW, railOff: Single;
  RailL, RailR: TXZArray;
  RailMesh: TMesh;
  sumX, sumZ: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1615);{$ENDIF}
  if (Composite = nil) or (Length(Specs) = 0) then Exit;
  concMat := Ord(fmConcrete);
  decks := 0;
  rails := 0;
  preComposVerts := Composite.VertexCount;   { измерить ВКЛАД дек, а не итог композита }
  preComposTris  := Composite.TriangleCount;

  for s := 0 to High(Specs) do
  begin
    EmitDeck(Specs[s], Composite);
    Inc(decks);

    if not GenerateFences then Continue;

    { бетонный меш заборов уже есть, когда GenerateFences построил палитру;
      на всякий случай создаём его, если nil }
    if Fences.Fences[concMat] = nil then
      Fences.Fences[concMat] := TMesh.Create;
    RailMesh := Fences.Fences[concMat];

    halfW   := Specs[s].Width * 0.5;
    railOff := halfW - BRIDGE_RAIL_INSET_M;
    if railOff < 0.05 then railOff := halfW;     { очень узкий настил: перила по краю }

    OffsetPolyline(Specs[s].Center,  railOff, RailL);
    OffsetPolyline(Specs[s].Center, -railOff, RailR);

    preVert := RailMesh.VertexCount;
    preTri  := RailMesh.TriangleCount;

    EmitRailRun(RailL, Specs[s].CenterY, BRIDGE_RAIL_HEIGHT_M, concMat, RailMesh, Specs[s].WayId);
    EmitRailRun(RailR, Specs[s].CenterY, BRIDGE_RAIL_HEIGHT_M, concMat, RailMesh, Specs[s].WayId);

    vEnd  := RailMesh.VertexCount;
    tEnd  := RailMesh.TriangleCount;
    vspan := vEnd - preVert;
    if vspan <= 0 then Continue;
    Inc(rails);

    { один якорь на мост (оба парапета имеют общий центр -> один тайл),
      раскладка как у TFenceBuilder.BuildAll / зданий }
    sumX := 0; sumZ := 0;
    for i := preVert to vEnd - 1 do
    begin
      sumX := sumX + RailMesh.VertexAt[i].Position.X;
      sumZ := sumZ + RailMesh.VertexAt[i].Position.Z;
    end;
    sumX := sumX / vspan;
    sumZ := sumZ / vspan;

    an := Length(Fences.TileAnchors);
    SetLength(Fences.TileAnchors, an + 1);
    Fences.TileAnchors[an].Material  := concMat;
    Fences.TileAnchors[an].AnchorX   := sumX;
    Fences.TileAnchors[an].AnchorZ   := sumZ;
    Fences.TileAnchors[an].TriStart  := preTri;
    Fences.TileAnchors[an].TriEnd    := tEnd;
    Fences.TileAnchors[an].VertStart := preVert;
    Fences.TileAnchors[an].VertEnd   := vEnd;
  end;

  { настил дописан в композит — вернуть массивы к точной длине для тайлера }
  Composite.TrimArrays;

  if Assigned(LogProc) then
    LogProc(Format('Osm3dGeomBridges: %d deck(s) добавили +%d верш / +%d тре, ' +
      '%d пар парапетов (в меш заборов); грунт-композит теперь %d верш / %d тре',
      [decks, Composite.VertexCount - preComposVerts,
       Composite.TriangleCount - preComposTris, rails,
       Composite.VertexCount, Composite.TriangleCount]));
end;

class procedure TBridgeBuilder.ClipRoadsUnderDecks(const Specs: TBridgeSpecArray;
  var Roads: TRoadMeshes; LogProc: TLogProc);
var
  Lines: TDeckClipLineArray;
  nLines, s, kd, meshes, ringN: Integer;
  C: TXZArray;

  { Поперечник в точке стыка: полуплоскость «наружу» от моста (оставить
    дорогу на стороне Out, убрать полотно, ушедшее на заезд/пролёт). }
  procedure AddLine(WayId: Int64; X0, Z0, RawDx, RawDz: Double);
  var
    l: Double;
    j: Integer;
  begin
    if WayId = 0 then Exit;
    l := Sqrt(RawDx*RawDx + RawDz*RawDz);
    if l < 1e-9 then Exit;
    { не дублировать ту же (way, точка) }
    for j := 0 to nLines - 1 do
      if (Lines[j].WayId = WayId) and
         (Sqr(Lines[j].Px - X0) + Sqr(Lines[j].Pz - Z0) < 0.01) then
        Exit;
    if nLines >= Length(Lines) then SetLength(Lines, (nLines + 1) * 2);
    Lines[nLines].WayId := WayId;
    Lines[nLines].Px := X0;       Lines[nLines].Pz := Z0;
    Lines[nLines].OutDx := RawDx/l; Lines[nLines].OutDz := RawDz/l;
    Inc(nLines);
  end;

  { IntRings карва строились ДО клипа — без пересборки асфальт снова
    попадёт под палубу через LayerFromBag. Кольца = граница clipped UVMesh. }
  procedure RebuildIntRings(var Bag: TLatRingBag; UV: TMesh);
  var
    L: TIntCaptureLayer;
    I, RN: Integer;
  begin
    Bag.Rings := nil;
    Bag.N := 0;
    if (UV = nil) or (UV.TriangleCount = 0) then Exit;
    L.Mesh := UV;
    L.MatId := 0;
    L.ZIndex := 0;
    L.UVMode := iumNone;
    L.InvUV := 0;
    L.Rings := nil;
    RN := CaptureMeshBoundaryInt(L);
    if RN <= 0 then Exit;
    SetLength(Bag.Rings, RN);
    for I := 0 to RN - 1 do
      Bag.Rings[I] := L.Rings[I];
    Bag.N := RN;
  end;

  { Только half-plane на стыке (Сазерленд–Ходжман → новые вершины на линии).
    Elevated-corridor wipe снят: резал поперечку и «съедал» целые треугольники.
    Int-first: клип UVMesh + пересборка IntRings. }
  function ClipKind(M: TMesh; UV: TMesh; var Bag: TLatRingBag): Integer;
  var
    Hit: Boolean;
  begin
    Result := 0;
    Hit := False;
    if nLines <= 0 then Exit;
    if (UV <> nil) and (UV.TriangleCount > 0) then
      if ClipMeshUnderDecks(UV, Lines) then
        Hit := True;
    if (M <> nil) and (M.TriangleCount > 0) then
      if ClipMeshUnderDecks(M, Lines) then
        Hit := True;
    if not Hit then Exit;
    Result := 1;
    if UV <> nil then
      RebuildIntRings(Bag, UV)
    else if M <> nil then
      RebuildIntRings(Bag, M);
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1617);{$ENDIF}
  if Length(Specs) = 0 then Exit;
  Lines := nil; nLines := 0;

  for s := 0 to High(Specs) do
  begin
    C := Specs[s].Center;
    kd := Length(C);
    if kd < 2 then Continue;
    if Specs[s].WeldJoints or (kd < 4) then
    begin
      { FIT / короткий настил: стык в торце Center[0]/[High], без пятки. }
      AddLine(Specs[s].ApprStartWayId, C[0].X,    C[0].Z,
        C[0].X - C[1].X, C[0].Z - C[1].Z);
      AddLine(Specs[s].ApprEndWayId,   C[kd-1].X, C[kd-1].Z,
        C[kd-1].X - C[kd-2].X, C[kd-1].Z - C[kd-2].Z);
    end
    else
    begin
      { с заездами: посадка = Center[1]/[kd-2]; «наружу» — к пятке. }
      AddLine(Specs[s].ApprStartWayId, C[1].X,    C[1].Z,
        C[0].X - C[1].X, C[0].Z - C[1].Z);
      AddLine(Specs[s].ApprEndWayId,   C[kd-2].X, C[kd-2].Z,
        C[kd-1].X - C[kd-2].X, C[kd-1].Z - C[kd-2].Z);
    end;
  end;

  if nLines > 0 then
    SetLength(Lines, nLines);

  meshes := 0; ringN := 0;
  Inc(meshes, ClipKind(Roads.Major,     Roads.UVMesh[rkMajor],     Roads.IntRings[rkMajor]));
  Inc(meshes, ClipKind(Roads.Secondary, Roads.UVMesh[rkSecondary], Roads.IntRings[rkSecondary]));
  Inc(meshes, ClipKind(Roads.Minor,     Roads.UVMesh[rkMinor],     Roads.IntRings[rkMinor]));
  Inc(meshes, ClipKind(Roads.Service,   Roads.UVMesh[rkService],   Roads.IntRings[rkService]));
  Inc(meshes, ClipKind(Roads.Footway,   Roads.UVMesh[rkFootway],   Roads.IntRings[rkFootway]));
  Inc(meshes, ClipKind(Roads.Cycleway,  Roads.UVMesh[rkCycleway],  Roads.IntRings[rkCycleway]));
  Inc(meshes, ClipKind(Roads.Railway,   Roads.UVMesh[rkRailway],   Roads.IntRings[rkRailway]));
  Inc(meshes, ClipKind(Roads.DirtPath,  Roads.UVMesh[rkDirtPath],  Roads.IntRings[rkDirtPath]));
  Inc(meshes, ClipKind(Roads.SandPath,  Roads.UVMesh[rkSandPath],  Roads.IntRings[rkSandPath]));
  ringN := Roads.IntRings[rkMajor].N + Roads.IntRings[rkSecondary].N +
    Roads.IntRings[rkMinor].N + Roads.IntRings[rkService].N +
    Roads.IntRings[rkFootway].N + Roads.IntRings[rkCycleway].N;

  if Assigned(LogProc) then
    LogProc(Format('Osm3dGeomBridges: road clip half-plane junctions=%d, ' +
      '%d class mesh(es) re-sliced (int rings bag N~%d); ' +
      'разрез стыка, поперечка не трогается',
      [nLines, meshes, ringN]));
end;

class procedure TBridgeBuilder.BuildAll(Dataset: TOSMDataset;
  Projection: TLocalProjection; Sampler: TTerrainSampler;
  Composite: TGroundCompositeMesh; var Fences: TFenceMeshes;
  GenerateFences: Boolean; LogProc: TLogProc; AFitLayer: TFitHeightLayer);
var
  Specs: TBridgeSpecArray;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1616);{$ENDIF}
  if (Dataset = nil) or (Projection = nil) or (Composite = nil) then Exit;
  Specs := Collect(Dataset, Projection, Sampler, LogProc, nil, AFitLayer);
  if Length(Specs) = 0 then Exit;
  Emit(Specs, Composite, Fences, GenerateFences, LogProc);
end;

end.
