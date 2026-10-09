unit Osm3dGeomFences;

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$codepage UTF8}

interface

uses
  Classes,
  SysUtils,
  Math,
  CastleVectors,
  Osm3dGeoMath,           { TLatLon, TLocalProjection, TLogProc }
  Osm3dGeomMesh,          { TMesh, MakeUV }
  Osm3dOsmData,           { TOSMDataset / TOSMWay / TOSMTags }
  Osm3dOsmTagUtils,        { ParseOSMMeters }
  Osm3dHeightmap,         { THeightmap / THeightmapSampler }
  Osm3dGeomTerrain        { TTerrainSampler, TRouteCorridor }
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
,
  Osm3dWorkerPool;   { ParallelForPool — шардированный BuildAllParallel }

const
  { Ord(TFenceMaterial) is the material id used downstream; MUST stay parallel to FENCE_MAT_*
    in Osm3dFenceComposite so geometry, atlas cell and shader agree without a translation table. }
  FENCE_PALETTE_SIZE = 6;

  { Base segment split so a vertex lands at least every DRAPE_STEP m, each dropped onto the
    terrain so the fence base follows slopes (like road centreline resampling). }
  FENCE_DRAPE_STEP = 4.0;

  { Ворота по точке barrier=gate НА линии забора: в ленте прорезается проём
    полной ширины FENCE_GATE_WIDTH_M (метры вдоль линии, центр — в узле), и в
    нём ставятся две створки — половинки одного текстурного тайла, каждая от
    своей петли (край проёма) к середине, под FENCE_GATE_ANGLE_DEG к хорде
    проёма: одна «внутрь», другая «наружу» — полуоткрытые ворота. Проём короче
    FENCE_GATE_MIN_SPAN_M (упёрся в конец way, слился с соседним, узел в очень
    остром изломе) вырождается — такой узел пропускается. }
  FENCE_GATE_WIDTH_M    = 3.0;
  FENCE_GATE_ANGLE_DEG  = 30.0;
  FENCE_GATE_MIN_SPAN_M = 0.6;

type
  TFenceMaterial = (
    fmWood,       { 0 — picket / plank fences            }
    fmChainLink,  { 1 — see-through wire mesh (alpha)    }
    fmMetal,      { 2 — railings, bars, palisade         }
    fmConcrete,   { 3 — poured / block walls             }
    fmHedge,      { 4 — vegetation barrier               }
    fmStone       { 5 — dry-stone / retaining / city wall }
  );

  { Resolved per-way render parameters. }
  TFenceParams = record
    Material:  Integer;   { Ord(TFenceMaterial) }
    Height:    Single;    { metres, top above the (draped) base }
    MinHeight: Single;    { metres, base lifted above the ground (min_height) }
  end;

  { Per-way record in the material meshes. Ranges are half-open:
    [TriStart, TriEnd) and [VertStart, VertEnd). Mirrors
    TBuildingTileAnchor (minus the walls/roofs split — a fence is a single
    ribbon, so one range pair is enough). Way с воротами ДРУГОГО материала
    (concrete → metal) даёт два якоря: лента в своём меше, створки в своём. }
  TFenceTileAnchor = record
    Material:  Integer;   { which Fences[] mesh this range lives in }
    AnchorX:   Single;    { polyline XZ centroid — tile key source }
    AnchorZ:   Single;
    TriStart:  Integer;
    TriEnd:    Integer;
    VertStart: Integer;
    VertEnd:   Integer;
  end;
  TFenceTileAnchorArray = array of TFenceTileAnchor;

  { One mesh per material + the per-way ranges, mirroring TBuildingMeshes.
    TileAnchors is nil only if nothing was built. }
  TFenceMeshes = record
    Fences:      array[0..FENCE_PALETTE_SIZE-1] of TMesh;
    TileAnchors: TFenceTileAnchorArray;
  end;

  { Utility class — parsing + extrusion only, no state (matches the
    class-function style of TBuildingBuilderExt). }
  TFenceBuilder = class
  public
    { Map a way's tags to fence render parameters. Ok=False when the way is
      not an extrudable barrier (gates, bollards, kerbs, unknown values) —
      the caller skips it. }
    class function ParseFenceParams(Tags: TOSMTags; WayId: Int64;
      out Ok: Boolean): TFenceParams; static;

    { Metres of fence length that map to one horizontal texture tile.
      = Height * per-material width ratio (after streets-gl getFenceParams):
      wood 1, chain-link 1, metal 1.64, concrete 2, hedge 1, stone 2. }
    class function FenceUVWidth(Material: Integer; Height: Single): Single; static;

    { Материал СТВОРОК ворот для материала забора: у бетонного забора ворота
      металлические (распашных бетонных створок не бывает), у остальных —
      материал самого забора. Расширение таблицы — одна строка. }
    class function GateMaterialFor(FenceMat: Integer): Integer; static;

    { Extrude one way's polyline into Target. Vertices are stamped with
      Way.Id (via Target.CurrentOsmId). Returns the number of triangles
      added to Target. Sampler preferred for base heights; HM bilinear is
      the fallback; flat (y=0) if neither is available.

      Corridor (route-only, опц.): звенья ленты и створки ворот, чья позиция
      вне полосы маршрута, НЕ выводятся — поэлементный фильтр (забор задевает
      коридор краем, но тянется далеко за него). nil = весь блок, как раньше.

      Узлы way с тегом barrier=gate становятся воротами: в ленте забора
      прорезается проём FENCE_GATE_WIDTH_M, в GateTarget добавляются две
      полуоткрытые створки (константы FENCE_GATE_*), GatesAdded — число
      построенных ворот. GateTarget может совпадать с Target (материал
      ворот = материалу забора; створки тогда входят в возвращаемый
      счётчик) или быть другим мешем (бетон → металл). GateTarget=nil
      выключает и проёмы, и створки — прежнее поведение ленты. }
    class function AppendWayFence(Way: TOSMWay; Dataset: TOSMDataset;
      HM: THeightmap; Projection: TLocalProjection;
      const P: TFenceParams; Sampler: TTerrainSampler;
      Target: TMesh; GateTarget: TMesh; Corridor: TRouteCorridor;
      out GatesAdded: Integer): Integer; static;

    { Build every barrier way in the dataset. One mesh per material;
      минимум один TileAnchor на way с геометрией (два — когда створки
      ворот легли в меш другого материала). Caller owns the meshes.
      Corridor (route-only, опц.) — поэлементный фильтр по полосе. }
    class function BuildAll(Dataset: TOSMDataset; HM: THeightmap;
      Projection: TLocalProjection;
      Sampler: TTerrainSampler = nil;
      LogProc: TLogProc = nil;
      AShard: Integer = 0;
      AShardCount: Integer = 1;
      Corridor: TRouteCorridor = nil): TFenceMeshes; static;

    { Параллельная версия (тот же рецепт, что TBuildingBuilderExt): заборы —
      крупнейшая ОСТАВШАЯСЯ однопоточная категория ген-фазы (по [gen-cat]
      до 10 с/блок при простое пула). Датасет шардируется детерминированно
      по Way.Id mod K, каждый шард строит свои меши+якоря полным BuildAll,
      затем шарды сливаются с оффсетами. Порядок лент в мешах меняется
      (шардовый), геометрия — побитно та же. Corridor — поэлементный фильтр. }
    class function BuildAllParallel(Dataset: TOSMDataset; HM: THeightmap;
      Projection: TLocalProjection;
      Sampler: TTerrainSampler = nil;
      LogProc: TLogProc = nil;
      AShards: Integer = 4;
      Corridor: TRouteCorridor = nil): TFenceMeshes; static;
  end;

implementation

{ height sampling (same fallback chain buildings/vegetation use) }

function SampleGroundY(Sampler: TTerrainSampler; HM: THeightmap;
  Projection: TLocalProjection; X, Z: Single): Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1306);{$ENDIF}
  if Sampler <> nil then
    Result := Sampler.SampleAtXZ(Projection, X, Z)
  else if (HM <> nil) and (Projection <> nil) then
    Result := THeightmapSampler.SampleBilinear(HM, Projection.Unproject(X, Z))
  else
    Result := 0;
  if IsNan(Result) or IsInfinite(Result) then
    Result := 0;
end;

class function TFenceBuilder.ParseFenceParams(Tags: TOSMTags; WayId: Int64;
  out Ok: Boolean): TFenceParams;
var
  Barrier, Sub: string;
  HV: string;
  PV: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1307);{$ENDIF}
  Ok := False;
  Result.Material  := Ord(fmMetal);
  Result.Height    := 1.5;
  Result.MinHeight := 0.0;

  if Tags = nil then Exit;
  Barrier := Tags.GetLower('barrier');

  { amenity=prison → the compound perimeter is ALWAYS a tall concrete wall,
    even with no barrier tag at all, and it overrides any barrier tag that is
    present (a prison is concrete, not whatever fence_type was tagged).
    Explicit height / min_height tags below still win. }
  if Tags.GetLower('amenity') = 'prison' then
  begin
    Result.Material := Ord(fmConcrete);
    Result.Height   := 5.0;
  end
  else if Barrier = '' then
    Exit
  else if Barrier = 'fence' then
  begin
    Sub := Tags.GetLower('fence_type');
    if (Sub = 'wood') or (Sub = 'wooden') or (Sub = 'split_rail') or
       (Sub = 'paling') or (Sub = 'picket') then
    begin
      Result.Material := Ord(fmWood);   Result.Height := 2.0;
    end
    else if (Sub = 'chain_link') or (Sub = 'chainlink') or (Sub = 'wire') or
            (Sub = 'mesh') or (Sub = 'metal_mesh') or (Sub = 'net') then
    begin
      Result.Material := Ord(fmChainLink); Result.Height := 3.0;
    end
    else if (Sub = 'concrete') then
    begin
      Result.Material := Ord(fmConcrete); Result.Height := 2.5;
    end
    else
    begin
      { metal / railing / bars / pole / palisade / spike / unspecified }
      Result.Material := Ord(fmMetal);  Result.Height := 1.5;
    end;
  end
  else if Barrier = 'hedge' then
  begin
    Result.Material := Ord(fmHedge);    Result.Height := 1.2;
  end
  else if Barrier = 'wall' then
  begin
    Sub := Tags.GetLower('wall');
    if (Sub = 'concrete') or (Sub = 'brick') or (Sub = 'block') or
       (Sub = 'flemish_bond') or (Sub = 'castellated') then
    begin
      Result.Material := Ord(fmConcrete); Result.Height := 2.0;
    end
    else
    begin
      { dry_stone / gabion / stone / flint / unspecified → stone }
      Result.Material := Ord(fmStone);  Result.Height := 2.0;
    end;
  end
  else if Barrier = 'retaining_wall' then
  begin
    Result.Material := Ord(fmStone);    Result.Height := 1.5;
  end
  else if (Barrier = 'city_wall') then
  begin
    Result.Material := Ord(fmStone);    Result.Height := 4.0;
  end
  else if (Barrier = 'guard_rail') or (Barrier = 'guardrail') or
          (Barrier = 'handrail') then
  begin
    Result.Material := Ord(fmMetal);    Result.Height := 0.9;
  end
  else
    { bollard, gate, lift_gate, cycle_barrier, kerb, block, … — not an
      extrudable linear barrier. Leave Ok=False. }
    Exit;

  { Optional explicit dimensions. ParseOSMMeters returns 0 on empty/bad
    input, so only override when it parsed something positive. }
  HV := Tags.Get('height');
  if HV <> '' then
  begin
    PV := ParseOSMMeters(HV, 1.0);
    if PV > 0.0 then Result.Height := PV;
  end;
  HV := Tags.Get('min_height');
  if HV <> '' then
  begin
    PV := ParseOSMMeters(HV, 1.0);
    if PV > 0.0 then Result.MinHeight := PV;
  end;

  { Clamp to something sane so a bogus height=0.01 or height=900 can't
    produce degenerate or skyscraper fences. }
  if Result.Height < 0.2  then Result.Height := 0.2;
  if Result.Height > 30.0 then Result.Height := 30.0;
  if Result.MinHeight < 0.0 then Result.MinHeight := 0.0;

  Ok := True;
end;

class function TFenceBuilder.FenceUVWidth(Material: Integer;
  Height: Single): Single;
var
  Ratio: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(263);{$ENDIF}
  case TFenceMaterial(Material) of
    fmConcrete: Ratio := 2.0;
    fmStone:    Ratio := 2.0;
    fmMetal:    Ratio := 1.64;
  else
    { wood / chain-link / hedge }
    Ratio := 1.0;
  end;
  Result := Height * Ratio;
  if Result < 1e-3 then Result := 1.0;
end;

class function TFenceBuilder.GateMaterialFor(FenceMat: Integer): Integer;
begin
  if FenceMat = Ord(fmConcrete) then
    Result := Ord(fmMetal)
  else
    Result := FenceMat;
end;

class function TFenceBuilder.AppendWayFence(Way: TOSMWay;
  Dataset: TOSMDataset; HM: THeightmap; Projection: TLocalProjection;
  const P: TFenceParams; Sampler: TTerrainSampler; Target: TMesh;
  GateTarget: TMesh; Corridor: TRouteCorridor; out GatesAdded: Integer): Integer;
var
  PtsX, PtsZ: array of Single;
  IsGate:     array of Boolean;
  CumD:       array of Single;
  GapA, GapB: array of Single;    { проёмы ворот по дистанции, слитые, по возрастанию }
  NodeCount, I, S, K, NGaps, GapIdx: Integer;
  Node: TOSMNode;
  Pr: TVector3;
  Ax, Az, Dx, Dz, SegLen, Nx, Nz: Single;
  N: TVector3;
  UVWidth, InvW: Single;
  D0, D1, VA, VB, GA, GB: Single;
  PrevOsm: Int64;
  TrisBefore: Integer;
  TotalLen: Single;
  HasGates: Boolean;

  { Точка на ломаной по дистанции от начала (клампится в [0, TotalLen]). }
  procedure PointAtDist(D: Single; out PX, PZ: Single);
  var
    Si: Integer;
    Tq: Single;
  begin
    if D <= 0 then
    begin PX := PtsX[0]; PZ := PtsZ[0]; Exit; end;
    if D >= TotalLen then
    begin PX := PtsX[High(PtsX)]; PZ := PtsZ[High(PtsZ)]; Exit; end;
    Si := 0;
    while (Si < High(PtsX) - 1) and (CumD[Si + 1] <= D) do Inc(Si);
    if CumD[Si + 1] > CumD[Si] then
      Tq := (D - CumD[Si]) / (CumD[Si + 1] - CumD[Si])
    else
      Tq := 0;
    PX := PtsX[Si] + (PtsX[Si + 1] - PtsX[Si]) * Tq;
    PZ := PtsZ[Si] + (PtsZ[Si + 1] - PtsZ[Si]) * Tq;
  end;

  { Кусок ленты [A2,B2] (дистанции ВНУТРИ текущего сегмента S) — прежний
    дрейп-шаг и прежние UV: U = абсолютная дистанция * InvW, так что без
    проёмов вывод бит-в-бит совпадает со старой лентой, а с проёмами
    текстура продолжается сквозь них без сдвига рисунка. Corridor (route-only):
    звено, чья середина вне полосы, пропускается — поэлементный фильтр. }
  procedure EmitRun(A2, B2: Single);
  var
    K2, Steps2: Integer;
    TT0, TT1, X0, Z0, X1, Z1: Single;
    BaseY0, TopY0, BaseY1, TopY1, U0, U1: Single;
    IdxV00, IdxV10, IdxV11, IdxV01: Integer;
  begin
    if B2 - A2 < 1e-4 then Exit;
    Steps2 := Max(1, Ceil((B2 - A2) / FENCE_DRAPE_STEP));
    for K2 := 0 to Steps2 - 1 do
    begin
      TT0 := A2 + (B2 - A2) * K2 / Steps2;
      TT1 := A2 + (B2 - A2) * (K2 + 1) / Steps2;

      X0 := Ax + Dx * ((TT0 - D0) / SegLen);
      Z0 := Az + Dz * ((TT0 - D0) / SegLen);
      X1 := Ax + Dx * ((TT1 - D0) / SegLen);
      Z1 := Az + Dz * ((TT1 - D0) / SegLen);

      { route-only: звено вне коридора — не выводим (проверяем середину). }
      if (Corridor <> nil) and
         (not Corridor.Contains((X0 + X1) * 0.5, (Z0 + Z1) * 0.5)) then
        Continue;

      BaseY0 := SampleGroundY(Sampler, HM, Projection, X0, Z0) + P.MinHeight;
      BaseY1 := SampleGroundY(Sampler, HM, Projection, X1, Z1) + P.MinHeight;
      TopY0  := BaseY0 + P.Height;
      TopY1  := BaseY1 + P.Height;

      U0 := TT0 * InvW;
      U1 := TT1 * InvW;

      { bottom-left, bottom-right, top-right, top-left }
      IdxV00 := Target.AddVertex(Vector3(X0, BaseY0, Z0), N, MakeUV(U0, 0.0));
      IdxV10 := Target.AddVertex(Vector3(X1, BaseY1, Z1), N, MakeUV(U1, 0.0));
      IdxV11 := Target.AddVertex(Vector3(X1, TopY1,  Z1), N, MakeUV(U1, 1.0));
      IdxV01 := Target.AddVertex(Vector3(X0, TopY0,  Z0), N, MakeUV(U0, 1.0));
      Target.AddQuad(IdxV00, IdxV10, IdxV11, IdxV01);
    end;
  end;

  { Одна створка: вертикальный квад от петли (HX,HZ) длиной LLen вдоль
    единичного (LDx,LDz); U от UHinge к UTip — половинка тайла; V 0..1.
    Основание — по земле у петли и у свободного края, верх = + P.Height. }
  procedure AppendLeaf(HX, HZ, LDx, LDz, LLen, UHinge, UTip: Single);
  var
    TX2, TZ2, BY0, BY1: Single;
    Iv00, Iv10, Iv11, Iv01: Integer;
    LN: TVector3;
  begin
    TX2 := HX + LDx * LLen;
    TZ2 := HZ + LDz * LLen;
    BY0 := SampleGroundY(Sampler, HM, Projection, HX, HZ)   + P.MinHeight;
    BY1 := SampleGroundY(Sampler, HM, Projection, TX2, TZ2) + P.MinHeight;
    LN  := Vector3(LDz, 0.0, -LDx);
    Iv00 := GateTarget.AddVertex(Vector3(HX,  BY0,            HZ),  LN, MakeUV(UHinge, 0.0));
    Iv10 := GateTarget.AddVertex(Vector3(TX2, BY1,            TZ2), LN, MakeUV(UTip,   0.0));
    Iv11 := GateTarget.AddVertex(Vector3(TX2, BY1 + P.Height, TZ2), LN, MakeUV(UTip,   1.0));
    Iv01 := GateTarget.AddVertex(Vector3(HX,  BY0 + P.Height, HZ),  LN, MakeUV(UHinge, 1.0));
    GateTarget.AddQuad(Iv00, Iv10, Iv11, Iv01);
  end;

  { Пара створок в проёме [GA2,GB2]: петли на краях проёма, каждая створка —
    половина хорды. Поворот хорды на +A и ОБРАТНОЙ хорды на +A даёт
    противоположные стороны: одна створка «внутрь», другая «наружу» —
    полуоткрытые ворота. U-раскладка — две половинки одного тайла (0→0.5 и
    1→0.5): свободные края встречаются на U=0.5, закрытые ворота дали бы
    непрерывный тайл. }
  procedure AppendGate(GA2, GB2: Single);
  var
    GSx, GSz, GEx, GEz, ChX, ChZ, ChLen, HalfL: Single;
    CosA, SinA, R1x, R1z, R2x, R2z: Single;
  begin
    PointAtDist(GA2, GSx, GSz);
    PointAtDist(GB2, GEx, GEz);
    { route-only: ворота вне коридора — целиком пропускаем (проверяем центр). }
    if (Corridor <> nil) and
       (not Corridor.Contains((GSx + GEx) * 0.5, (GSz + GEz) * 0.5)) then
      Exit;
    ChX := GEx - GSx;  ChZ := GEz - GSz;
    ChLen := Sqrt(ChX * ChX + ChZ * ChZ);
    { Хорда через острый излом может быть заметно короче дуги — вырождение. }
    if ChLen < FENCE_GATE_MIN_SPAN_M then Exit;
    ChX := ChX / ChLen;  ChZ := ChZ / ChLen;
    HalfL := ChLen * 0.5;
    CosA := Cos(DegToRad(FENCE_GATE_ANGLE_DEG));
    SinA := Sin(DegToRad(FENCE_GATE_ANGLE_DEG));
    R1x :=  ChX * CosA - ChZ * SinA;   R1z :=  ChX * SinA + ChZ * CosA;
    R2x := -ChX * CosA + ChZ * SinA;   R2z := -ChX * SinA - ChZ * CosA;
    AppendLeaf(GSx, GSz, R1x, R1z, HalfL, 0.0, 0.5);
    AppendLeaf(GEx, GEz, R2x, R2z, HalfL, 1.0, 0.5);
    Inc(GatesAdded);
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(264);{$ENDIF}
  Result := 0;
  GatesAdded := 0;
  if (Way = nil) or (Target = nil) or (Projection = nil) then Exit;
  NodeCount := Length(Way.NodeRefs);
  if NodeCount < 2 then Exit;

  { Resolve + project the nodes once, dropping any we can't find. We keep
    only XZ; Y is sampled per sub-vertex below. Заодно помечаем узлы
    barrier=gate — по ним прорезаются проёмы и ставятся створки. }
  SetLength(PtsX, NodeCount);
  SetLength(PtsZ, NodeCount);
  SetLength(IsGate, NodeCount);
  HasGates := False;
  K := 0;
  for I := 0 to NodeCount - 1 do
  begin
    Node := Dataset.FindNode(Way.NodeRefs[I]);
    if Node = nil then Continue;
    if Dataset.LatticeReady then
    begin
      { int-first: точные решёточные координаты узла (мировая решётка 1/64 м
        минус целый сдвиг блока) — побитно одинаковы во всех блоках halo,
        см. Osm3dOsmData.PrecomputeLattice }
      Pr.X := Node.LatticeX * (1.0 / 64.0);
      Pr.Y := 0;
      Pr.Z := Node.LatticeZ * (1.0 / 64.0);
    end
    else
    begin
      { fallback (хост без int-обвязки): прежний путь }
      Pr := Projection.Project(Node.Position);
      Pr.X := Round(Pr.X * 64.0) * (1.0 / 64.0);
      Pr.Z := Round(Pr.Z * 64.0) * (1.0 / 64.0);
    end;
    PtsX[K] := Pr.X;
    PtsZ[K] := Pr.Z;
    IsGate[K] := (Node.Tags <> nil) and
                 (Node.Tags.GetLower('barrier') = 'gate');
    if IsGate[K] then HasGates := True;
    Inc(K);
  end;
  if K < 2 then Exit;
  SetLength(PtsX, K);
  SetLength(PtsZ, K);
  SetLength(IsGate, K);

  { Накопленная дистанция по ломаной — общая шкала ленты, UV и проёмов. }
  SetLength(CumD, K);
  CumD[0] := 0;
  for I := 1 to K - 1 do
    CumD[I] := CumD[I - 1] +
      Sqrt(Sqr(PtsX[I] - PtsX[I - 1]) + Sqr(PtsZ[I] - PtsZ[I - 1]));
  TotalLen := CumD[K - 1];
  if TotalLen < 1e-4 then Exit;

  { Проёмы ворот: интервал полной ширины вокруг каждого gate-узла, кламп в
    границы way, слияние перекрывающихся (двое ворот рядом → один общий
    проём с одной парой створок). GateTarget=nil — ворота выключены. }
  NGaps := 0;
  if (GateTarget <> nil) and HasGates then
  begin
    SetLength(GapA, K);
    SetLength(GapB, K);
    for I := 0 to K - 1 do
    begin
      if not IsGate[I] then Continue;
      GA := CumD[I] - FENCE_GATE_WIDTH_M * 0.5;
      GB := CumD[I] + FENCE_GATE_WIDTH_M * 0.5;
      if GA < 0 then GA := 0;
      if GB > TotalLen then GB := TotalLen;
      if GB - GA < FENCE_GATE_MIN_SPAN_M then Continue;
      if (NGaps > 0) and (GA <= GapB[NGaps - 1] + 1e-3) then
      begin
        if GB > GapB[NGaps - 1] then GapB[NGaps - 1] := GB;
      end
      else
      begin
        GapA[NGaps] := GA;
        GapB[NGaps] := GB;
        Inc(NGaps);
      end;
    end;
  end;

  UVWidth := FenceUVWidth(P.Material, P.Height);
  InvW    := 1.0 / UVWidth;

  TrisBefore := Target.TriangleCount;

  { Stamp every vertex with this way's id (restore the builder's id after). }
  PrevOsm := Target.CurrentOsmId;
  Target.CurrentOsmId := Way.Id;
  try
    for S := 0 to High(PtsX) - 1 do
    begin
      D0 := CumD[S];
      D1 := CumD[S + 1];
      SegLen := D1 - D0;
      if SegLen < 1e-6 then Continue;   { coincident nodes — no advance }

      Ax := PtsX[S];  Az := PtsZ[S];
      Dx := PtsX[S + 1] - Ax;
      Dz := PtsZ[S + 1] - Az;

      { Horizontal normal (segment direction rotated -90° in XZ). The IFS
        is two-sided and the FS re-orients toward the camera, so the chosen
        sign only has to be consistent, not "outward". }
      Nx := Dz / SegLen;
      Nz := -Dx / SegLen;
      N  := Vector3(Nx, 0.0, Nz);

      { Лента сегмента за вычетом проёмов ворот. }
      VA := D0;
      for GapIdx := 0 to NGaps - 1 do
      begin
        if GapB[GapIdx] <= VA then Continue;
        if GapA[GapIdx] >= D1 then Break;
        VB := GapA[GapIdx];
        if VB > D1 then VB := D1;
        EmitRun(VA, VB);
        if GapB[GapIdx] > VA then VA := GapB[GapIdx];
        if VA >= D1 then Break;
      end;
      if VA < D1 then EmitRun(VA, D1);
    end;
  finally
    Target.CurrentOsmId := PrevOsm;
  end;

  { Створки — после ленты, со штампом того же way id в своём меше (он может
    совпадать с Target — тогда створки лягут в тот же диапазон якоря). }
  if NGaps > 0 then
  begin
    PrevOsm := GateTarget.CurrentOsmId;
    GateTarget.CurrentOsmId := Way.Id;
    try
      for GapIdx := 0 to NGaps - 1 do
        AppendGate(GapA[GapIdx], GapB[GapIdx]);
    finally
      GateTarget.CurrentOsmId := PrevOsm;
    end;
  end;

  Result := Target.TriangleCount - TrisBefore;
end;

class function TFenceBuilder.BuildAll(Dataset: TOSMDataset; HM: THeightmap;
  Projection: TLocalProjection; Sampler: TTerrainSampler;
  LogProc: TLogProc; AShard: Integer; AShardCount: Integer;
  Corridor: TRouteCorridor): TFenceMeshes;
var
  M, Mat, GateMat: Integer;
  Way: TOSMWay;
  Params: TFenceParams;
  Ok: Boolean;
  PreVert, PreTri, PreVertG, PreTriG, AddedTris, GatesAdded: Integer;
  AnchorCount, AnchorCap: Integer;
  WaysSeen, WaysBuilt, GatesTotal: Integer;
  FenceMesh, GateMesh: TMesh;

  procedure Log(const Msg: string);
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1446);{$ENDIF}
    if Assigned(LogProc) then LogProc(Msg);
  end;

  { Якорь по диапазону [APreTri..сейчас) / [APreVert..сейчас) в меше AMesh
    материала AMat; центроид — по добавленным вершинам (для створок в чужом
    меше это центроид самих ворот — тайл выбирается у ворот). Пустой
    диапазон — no-op. }
  procedure PushAnchor(AMat: Integer; AMesh: TMesh;
    APreTri, APreVert: Integer);
  var
    SumX, SumZ: Single;
    VertSpan, KV: Integer;
  begin
    VertSpan := AMesh.VertexCount - APreVert;
    if (VertSpan <= 0) or (AMesh.TriangleCount <= APreTri) then Exit;
    SumX := 0; SumZ := 0;
    for KV := APreVert to AMesh.VertexCount - 1 do
    begin
      SumX := SumX + AMesh.VertexAt[KV].Position.X;
      SumZ := SumZ + AMesh.VertexAt[KV].Position.Z;
    end;
    SumX := SumX / VertSpan;
    SumZ := SumZ / VertSpan;

    if AnchorCount >= AnchorCap then
    begin
      if AnchorCap = 0 then AnchorCap := 64 else AnchorCap := AnchorCap * 2;
      SetLength(Result.TileAnchors, AnchorCap);
    end;
    Result.TileAnchors[AnchorCount].Material  := AMat;
    Result.TileAnchors[AnchorCount].AnchorX   := SumX;
    Result.TileAnchors[AnchorCount].AnchorZ   := SumZ;
    Result.TileAnchors[AnchorCount].TriStart  := APreTri;
    Result.TileAnchors[AnchorCount].TriEnd    := AMesh.TriangleCount;
    Result.TileAnchors[AnchorCount].VertStart := APreVert;
    Result.TileAnchors[AnchorCount].VertEnd   := AMesh.VertexCount;
    Inc(AnchorCount);
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(265);{$ENDIF}
  for M := 0 to FENCE_PALETTE_SIZE - 1 do
    Result.Fences[M] := TMesh.Create;
  Result.TileAnchors := nil;
  AnchorCount := 0;
  AnchorCap   := 0;
  WaysSeen    := 0;
  WaysBuilt   := 0;
  GatesTotal  := 0;

  if (Dataset = nil) or (Projection = nil) then
  begin
    Log('Osm3dGeomFences: no dataset/projection — 0 fences');
    Exit;
  end;

  for Way in Dataset.Ways.Values do
  begin
    if Way = nil then Continue;
    { шардирование по Id: детерминированное разбиение для BuildAllParallel;
      AShardCount=1 (дефолт) — прежний однопоточный полный проход }
    if (AShardCount > 1) and (Way.Id mod AShardCount <> AShard) then Continue;
    Params := ParseFenceParams(Way.Tags, Way.Id, Ok);
    if not Ok then Continue;
    if Length(Way.NodeRefs) < 2 then Continue;
    Inc(WaysSeen);

    Mat := Params.Material;
    if (Mat < 0) or (Mat >= FENCE_PALETTE_SIZE) then
      Mat := Ord(fmMetal);
    GateMat := GateMaterialFor(Mat);

    FenceMesh := Result.Fences[Mat];
    GateMesh  := Result.Fences[GateMat];

    PreVert  := FenceMesh.VertexCount;
    PreTri   := FenceMesh.TriangleCount;
    PreVertG := GateMesh.VertexCount;     { = PreVert/PreTri, если меш тот же }
    PreTriG  := GateMesh.TriangleCount;

    AddedTris := AppendWayFence(Way, Dataset, HM, Projection,
                                Params, Sampler, FenceMesh, GateMesh,
                                Corridor, GatesAdded);
    if (AddedTris <= 0) and (GateMesh.TriangleCount = PreTriG) then Continue;
    Inc(WaysBuilt);
    Inc(GatesTotal, GatesAdded);

    { Footprint XZ centroid over exactly the vertices this way added —
      identical to the building anchor, and it picks the same tile.
      Створки в меше ДРУГОГО материала — отдельный якорь со своим
      диапазоном; в том же меше они уже внутри диапазона ленты. }
    PushAnchor(Mat, FenceMesh, PreTri, PreVert);
    if GateMat <> Mat then
      PushAnchor(GateMat, GateMesh, PreTriG, PreVertG);
  end;

  SetLength(Result.TileAnchors, AnchorCount);
  Log(Format('Osm3dGeomFences: %d barrier ways → %d built, %d gates, %d anchors',
    [WaysSeen, WaysBuilt, GatesTotal, AnchorCount]));
end;

{ ── BuildAllParallel: шардированный параллельный запуск ──────────────── }

{ Дозапись всего Src в Dst со сдвигом индексов; возвращает оффсеты вершин
  и треугольников, на которые сдвигаются якорные диапазоны шарда. }
procedure AppendWholeFenceMesh(Dst, Src: TMesh; out AVOfs, ATOfs: Integer);
var
  SV: TMeshVertexArray;
  SI: TMeshIndexArray;
  R:  Integer;
begin
  AVOfs := 0; ATOfs := 0;
  if Dst = nil then Exit;
  AVOfs := Dst.VertexCount;
  ATOfs := Dst.TriangleCount;
  if (Src = nil) or (Src.VertexCount = 0) then Exit;
  SV := Src.Vertices;
  SI := Src.Indices;
  for R := 0 to Src.VertexCount - 1 do
    Dst.AddVertex(SV[R]);
  for R := 0 to Src.TriangleCount - 1 do
    Dst.AddTriangle(
      Integer(SI[R * 3])     + AVOfs,
      Integer(SI[R * 3 + 1]) + AVOfs,
      Integer(SI[R * 3 + 2]) + AVOfs);
end;

type
  TFenceShardCtx = record
    Dataset:  TOSMDataset;
    HM:       THeightmap;
    Proj:     TLocalProjection;
    Sampler:  TTerrainSampler;
    Shards:   Integer;
    Corridor: TRouteCorridor;
    Meshes:   array[0..15] of TFenceMeshes;
  end;
  PFenceShardCtx = ^TFenceShardCtx;

procedure RunFenceShardRange(Ctx: Pointer; A, B: Integer);
var
  C: PFenceShardCtx;
  I: Integer;
begin
  C := PFenceShardCtx(Ctx);
  for I := A to B - 1 do
    C^.Meshes[I] := TFenceBuilder.BuildAll(
      C^.Dataset, C^.HM, C^.Proj, C^.Sampler,
      nil,               { лог шардов отключён — сводку пишет вызывающий }
      I, C^.Shards, C^.Corridor);
end;

class function TFenceBuilder.BuildAllParallel(Dataset: TOSMDataset;
  HM: THeightmap; Projection: TLocalProjection;
  Sampler: TTerrainSampler; LogProc: TLogProc;
  AShards: Integer; Corridor: TRouteCorridor): TFenceMeshes;
var
  Ctx: TFenceShardCtx;
  S, M, K, AOfs, TotA: Integer;
  VOfs, TOfs: array[0..FENCE_PALETTE_SIZE - 1] of Integer;
  An: TFenceTileAnchor;
begin
  if AShards < 1 then AShards := 1;
  if AShards > 16 then AShards := 16;
  if AShards = 1 then
  begin
    Result := BuildAll(Dataset, HM, Projection, Sampler, LogProc, 0, 1, Corridor);
    Exit;
  end;

  Ctx.Dataset  := Dataset;
  Ctx.HM       := HM;
  Ctx.Proj     := Projection;
  Ctx.Sampler  := Sampler;
  Ctx.Shards   := AShards;
  Ctx.Corridor := Corridor;
  ParallelForPool(AShards, @RunFenceShardRange, @Ctx, 1);

  { merge: базой служит шард 0, остальные дозаписываются с оффсетами }
  Result := Ctx.Meshes[0];
  TotA := Length(Result.TileAnchors);
  for S := 1 to AShards - 1 do
    Inc(TotA, Length(Ctx.Meshes[S].TileAnchors));
  AOfs := Length(Result.TileAnchors);
  SetLength(Result.TileAnchors, TotA);

  for S := 1 to AShards - 1 do
  begin
    { пер-материальные оффсеты фиксируются ДО дозаписи шарда }
    for M := 0 to FENCE_PALETTE_SIZE - 1 do
      AppendWholeFenceMesh(Result.Fences[M], Ctx.Meshes[S].Fences[M],
        VOfs[M], TOfs[M]);
    { якорь ремапится по СВОЕМУ материалу — лента и створки могут жить в
      разных мешах (бетон → металл), у каждого свой оффсет }
    for K := 0 to High(Ctx.Meshes[S].TileAnchors) do
    begin
      An := Ctx.Meshes[S].TileAnchors[K];
      M := An.Material;
      if (M >= 0) and (M < FENCE_PALETTE_SIZE) then
      begin
        Inc(An.TriStart,  TOfs[M]);  Inc(An.TriEnd,  TOfs[M]);
        Inc(An.VertStart, VOfs[M]);  Inc(An.VertEnd, VOfs[M]);
      end;
      Result.TileAnchors[AOfs] := An;
      Inc(AOfs);
    end;
    { меши шарда слиты в базу — освобождаем оболочки }
    for M := 0 to FENCE_PALETTE_SIZE - 1 do
      Ctx.Meshes[S].Fences[M].Free;
  end;

  if Assigned(LogProc) then
    LogProc(Format('Osm3dGeomFences: %d shards merged — %d anchors',
      [AShards, TotA]));
end;

end.
