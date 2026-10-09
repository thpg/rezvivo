unit Osm3dGeomBuilder;

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$codepage UTF8}

{$WARN 5092 OFF}

interface

uses
  Classes,
  SysUtils, Osm3dGeomManholes, Osm3dGeomCrossings,
  CastleVectors,
  X3DNodes,
  Osm3dChunk,
  Osm3dStudioSettings,
  Osm3dStudioLog,
  Osm3dGeoMath,
  Osm3dOsmData,
  Osm3dHeightmap,
  Osm3dGeomMesh,
  Osm3dGeomTerrain,
  Osm3dGeomSurface,
  Osm3dGeomVegetation,
  Osm3dGeomBuildings, Osm3dGroundOpenings,
  Osm3dGeomFences,
  Osm3dCarveGround,
  Osm3dGeomRoads, Osm3dRoadSurface,
  Osm3dGroundComposite,
  Osm3dGeomBridges,
  Osm3dGeomTunnels,
  Osm3dRoadDistField,
  Osm3dGeomPOI,
  Osm3dGeomPlates,
  Osm3dPlateAtlas,
  Osm3dWorkerPool,
  Osm3dFitHeightLayer,
  Osm3dSceneAssembler
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
;    { TSceneInput }

type
  { Стык настила FIT-моста с дорогой («одна геометрия»): полотно в сечении
    стыка (торец настила) прижимается выравниванием ТОЧНО к высоте кромки
    настила H и плавно (smoothstep) выходит на обычную выровненную высоту за
    ROAD_JOINT_BLEND_M вдоль дороги НАРУЖУ от моста. Кромка настила эмитится
    на тех же XZ/Y (Osm3dGeomBridges, WeldJoints) — вершины свариваются в
    пуле композита, щель/бугор на стыке исключены по построению. }
  TDeckJoint = record
    JX, JZ:     Single;   { кромка настила на осевой (торец пролёта) }
    DirX, DirZ: Single;   { единичное направление наружу (от моста вдоль дороги) }
    HalfW:      Single;   { полуширина полотна настила }
    H:          Single;   { высота кромки настила (без лифта) = Spec.CenterY[торец] }
  end;
  TDeckJointArray = array of TDeckJoint;

  { Single-use orchestrator: one chunk → one Build call. }
  TGeometryBuilder = class(TLogOwner)
  private
    FChunk:      TOsm3dChunkData;
    FSettings:   TStudioSettings;
    FLogProc:    TLogProc;
    FTotalVerts: Integer;
    FTotalTris:  Integer;
    FTStep:      TDateTime;
    FSunDirection: TVector3;     { set via the BlockGenerator API; not
                                   consumed here (per-vertex shadow baking
                                   was removed) }

    { Якоря стыков FIT-мостов (по два на настил): заполняются в Build сразу
      после TBridgeBuilder.Collect, читаются в BuildGroundComposite при
      выравнивании дорог (LevelRoadsInComposite → LeveledHeightAt). }
    FDeckJoints: TDeckJointArray;

    procedure LogStep(const What: string; Mesh: TMesh);

    { Merge landuse + roads into one TGroundCompositeMesh with per-vertex
      matId, plus a TGroundAtlas of all surface PNGs. Source mesh data is
      copied — caller still owns originals. }
    procedure BuildGroundComposite(var AInput: TSceneInput;
      const Roads: TRoadMeshes;
      const AWaterRings: TLatRingBag;
      const ATunnelRamps: TTunnelApproachSegArray;
      const AFences: TFenceMeshes;
      Sampler: TTerrainSampler = nil;
      Projection: TLocalProjection = nil);

    { Set dist-field bounds from the composite mesh's XZ extent so the
      raster covers exactly the area sampled in the FS. Linear pass. }
    procedure BuildRoadDistFieldBounds(const AInput: TSceneInput;
      Field: TRoadDistField);
  public
    { Второй слой высот (FIT-коррекция). Ставит генератор блока ДО Build
      (Builder.FitLayer := FTerrFetcher.FitLayer). Прокидывается в
      TTerrainBuilder.Build и TTerrainSampler.Create — высоты узлов
      террейна смешиваются с FIT, вся геометрия садится на корр. землю.
      nil = без коррекции. Ссылка (владеет фетчер), билдер не освобождает. }
    FitLayer: TFitHeightLayer;
    WaterHeightSource: TTerrariumFetcher; { borrowed, fixed-zoom lake samples }

    { Режим «геометрия только вдоль пути FIT»: коридор маршрута в локальной
      системе блока. Ставит генератор блока ДО Build. Когда задан: террейн
      отбрасывает треугольники, у которых ВСЕ вершины вне коридора; земляной
      композит пересобирается по тому же правилу (OSM-фичи фильтруются раньше,
      на этапе датасета). nil = обычная полная генерация. Ссылка — владеет и
      освобождает генератор блока. }
    RouteCorridor: TRouteCorridor;

    constructor Create(AChunk: TOsm3dChunkData; const ASettings: TStudioSettings;
      ALog: TLogTarget; ALogProc: TLogProc = nil);

    { Sun direction (light-travel vector), set via the BlockGenerator API.
      Per-vertex shadow baking was removed; building shadows now come from
      the CPU shadow-mask path, so this is not consumed here at present. }
    property SunDirection: TVector3 read FSunDirection write FSunDirection;

    { Returns False only if Chunk = nil. On partial errors logs and leaves
      the corresponding mesh nil. Caller owns all meshes. }
    function Build(out AInput: TSceneInput;
      out ATrees: TForestBuildResult): Boolean;

    property TotalVerts: Integer read FTotalVerts;
    property TotalTris:  Integer read FTotalTris;
  end;

{ CPU generation primitives; shared by the builder and geometry regression
  probes. Neither function touches scene state or a graphics context. }
function BuildHoleNodeMask(const Casters:TBuildingShadowCasters;
  Sampler:TTerrainSampler;Projection:TLocalProjection):TBytes;
function BuildBuildingBasesMesh(const Casters:TBuildingShadowCasters;
  UVScale:Single;ABag:PLatRingBag=nil):TMesh;
const
  { Above grass/lawn, tied with forest floor (10), below all mapped roads
    (>=11). Captured after landuse: the common stable sort puts later equal
    priorities first, so paving also replaces forest undergrowth. }
  BUILDING_PASSAGE_PAVING_ZINDEX = 10;
  { Hide carve-lattice edge rounding beneath the jambs. This affects only
    material coverage, never the passage geometry or obstacle clearance. }
  BUILDING_PASSAGE_PAVING_MARGIN_M = 0.03;
procedure BuildBuildingPassagePaving(const Casters:TBuildingShadowCasters;
  out Bag:TLatRingBag);

implementation

uses
  Math,                 { ArcCos — остаточный «запас коридора» узла (fit-fade) }
  Generics.Collections, { TDictionary — узловой граф дорожной сети (fit-fade) }
  Osm3dGeomUtils,   { TPolygonTriangulator.TriangulateXZ, TIndexArray }
  Osm3dCarveLattice, Osm3dCarveCell,
  Osm3dIntGeo,      { TLatticeProjection, DegToE7 — int-first ядро }
  Osm3dOsmIndex,    { TOsmRoadIndex — единый пер-блочный индекс дорог }
  Osm3dRoadProfile, { продольное сглаживание профиля дорог на HM }
  Osm3dWaterLevel, Osm3dGenerationProgress, Osm3dGroundSurfaceQuery;

var
  { Diagnostic: total carve/capture pool threads live across ALL concurrent block
    generations; logged at phase boundaries to show overlap (total = 2x pool). }
  gBuildCarveThreads: Integer = 0;

constructor TGeometryBuilder.Create(AChunk: TOsm3dChunkData;
  const ASettings: TStudioSettings; ALog: TLogTarget; ALogProc: TLogProc);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1058);{$ENDIF}
  inherited Create;
  FChunk    := AChunk;
  FSettings := ASettings;
  FLog      := ALog;
  FLogProc  := ALogProc;
  FSunDirection := Vector3(0, 0, 0);
  FitLayer  := nil;   { ставит генератор блока из фетчера до Build }
  RouteCorridor := nil;   { ставит генератор блока (route-only) до Build }
  FDeckJoints := nil; { заполняет Build после TBridgeBuilder.Collect }
end;

procedure TGeometryBuilder.LogStep(const What: string; Mesh: TMesh);
var
  Dt: Double;
  Stats: string;
  TLog0, TLogMs: QWord;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(150);{$ENDIF}
  Dt := (Now - FTStep) * 86400.0;
  if Mesh = nil then
    Stats := '<none>'
  else
    Stats := Format('%d verts, %d tris', [Mesh.VertexCount, Mesh.TriangleCount]);
  TLog0 := GetTickCount64;
  LogInfo(Format('Geometry: %s built in %.2f s — %s', [What, Dt, Stats]));
  TLogMs := GetTickCount64 - TLog0;
  { LogInfo on a worker Synchronizes to the main thread; a multi-second value here
    means the freeze is in the log channel, not in geometry building. }
  if TLogMs >= 200 then
    LogInfo(Format('  >>> previous log line BLOCKED %d ms in LogInfo '
      + '(worker log Synchronize stalled on the main thread)', [TLogMs]));
  if Mesh <> nil then
  begin
    Inc(FTotalVerts, Mesh.VertexCount);
    Inc(FTotalTris,  Mesh.TriangleCount);
  end;
  FTStep := Now;
end;

{ Road cross-slope leveling (after weld, before tiling): set each pool position within a
  road's half-width to the centerline height at its longitudinal projection, so the road is
  LEVEL across and follows terrain only along its length; a blend band eases back to terrain
  (embankment). Welded positions move road + coincident ground edge together. Purely geometric
  ("on a road" = within Width/2 of a centerline), so no matId/OsmId needed. }

{ Параллельный проход по пулу [0..Count) вынесен в Osm3dWorkerPool.ParallelForPool:
  общий на весь процесс пул с политикой допуска потоков (не переподписывать CPU,
  когда несколько блоков генерируются разом) и caller-draining разбором работы.
  Прежняя локальная статическая реализация удалена; вызовы ниже (drape / normals
  / leveling / weld / builders) резолвятся в юнит. }

{ Apply terrain height to the flat (Y=0) carved composite, once, before road leveling.
  Parallel per-vertex: disjoint SetPosition, read-only sampler. }
type
  TDrapeCtx = record
    Comp:       TGroundCompositeMesh;
    Sampler:    TTerrainSampler;
    Projection: TLocalProjection;
  end;
  PDrapeCtx = ^TDrapeCtx;

procedure DrapeRange(Ctx: Pointer; AStartIdx, AEndExcl: Integer);
var
  c:   PDrapeCtx;
  p:   Integer;
  Pos: TVector3;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1417);{$ENDIF}
  c := PDrapeCtx(Ctx);
  for p := AStartIdx to AEndExcl - 1 do
  begin
    Pos := c^.Comp.Pool.PositionOf(p);
    c^.Comp.Pool.SetPosition(p,
      Vector3(Pos.X, c^.Sampler.SampleAtXZ(c^.Projection, Pos.X, Pos.Z), Pos.Z));
  end;
end;

procedure DrapeComposite(Composite: TGroundCompositeMesh;
  Sampler: TTerrainSampler; Projection: TLocalProjection);
var
  ctx: TDrapeCtx;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1418);{$ENDIF}
  if (Composite = nil) or (Sampler = nil) or (Projection = nil) then Exit;
  ctx.Comp := Composite; ctx.Sampler := Sampler; ctx.Projection := Projection;
  GenerationParallelFor('Terrain heights', Composite.Pool.Count, @DrapeRange, @ctx);
end;

{ Replace every pool normal with the gradient of the smooth (cubic) terrain surface, so the
  coarse ground shades as C1 (geometry untouched). Runs LAST (after leveling, stitch, T-junction)
  so nothing overwrites it. For Y=H(x,z) the up normal is (-dH/dx, 1, -dH/dz), central difference.
  Parallel per-vertex: disjoint SetNormal, read-only sampler. }
type
  TNormalsCtx = record
    Comp:       TGroundCompositeMesh;
    Sampler:    TTerrainSampler;
    Projection: TLocalProjection;
  end;
  PNormalsCtx = ^TNormalsCtx;

procedure SmoothNormalsRange(Ctx: Pointer; AStartIdx, AEndExcl: Integer);
const
  EPS = 1.0;
var
  c: PNormalsCtx;
  p: Integer;
  Pos: TVector3;
  hL, hR, hD, hU, dHdx, dHdz, nx, nz, inv: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1419);{$ENDIF}
  c := PNormalsCtx(Ctx);
  for p := AStartIdx to AEndExcl - 1 do
  begin
    Pos := c^.Comp.Pool.PositionOf(p);
    hL := c^.Sampler.SampleAtXZCubic(c^.Projection, Pos.X - EPS, Pos.Z);
    hR := c^.Sampler.SampleAtXZCubic(c^.Projection, Pos.X + EPS, Pos.Z);
    hD := c^.Sampler.SampleAtXZCubic(c^.Projection, Pos.X, Pos.Z - EPS);
    hU := c^.Sampler.SampleAtXZCubic(c^.Projection, Pos.X, Pos.Z + EPS);
    dHdx := (hR - hL) * (1.0 / (2.0 * EPS));
    dHdz := (hU - hD) * (1.0 / (2.0 * EPS));
    nx := -dHdx;
    nz := -dHdz;
    inv := 1.0 / Sqrt(nx*nx + 1.0 + nz*nz);
    c^.Comp.Pool.SetNormal(p, Vector3(nx * inv, inv, nz * inv));
  end;
end;

procedure SmoothCompositeNormals(Composite: TGroundCompositeMesh;
  Sampler: TTerrainSampler; Projection: TLocalProjection);
var
  ctx: TNormalsCtx;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1420);{$ENDIF}
  if (Composite = nil) or (Sampler = nil) or (Projection = nil) then Exit;
  ctx.Comp := Composite; ctx.Sampler := Sampler; ctx.Projection := Projection;
  GenerationParallelFor('Surface normals', Composite.Pool.Count, @SmoothNormalsRange, @ctx);
end;

type
  { Named so the local grid and the worker-context field are the SAME type —
    two distinct anonymous `array of array of Integer` are not assignment-
    compatible in FPC. }
  TLvlIntArr = array of Integer;
  TLvlSglArr = array of Single;
  TLvlGrid   = array of TLvlIntArr;

  TLevelCtx = record
    Comp:         TGroundCompositeMesh;
    Sampler:      TTerrainSampler;
    Projection:   TLocalProjection;
    FitLayer:     TFitHeightLayer;            { ref — read-only; nil/inactive → чистая сетка }
    Segs:         TRoadCenterlineSegArray;   { ref — read-only in workers }
    JoinedEnds:   TLvlIntArr;                { bit 0: A shared; bit 1: B shared by ground segments }
    BridgeSegs:   TRoadCenterlineSegArray;   { только IsBridge-сегменты — «есть ли настил над точкой» }
    { Остаточный FIT-офсет узловой сети дорог в концах A/B каждого сегмента
      (знак в значении) и «запас коридора» R концов: внутри R от узла офсет —
      плато (полная величина), дальше затухает с уклоном ROAD_FIT_FADE_SLOPE.
      Вдоль сегмента воркер берёт максимум конусов двух концов — плато у кромки
      коридора FIT + съезд 12%, без ступеньки на границе. Считается в
      LevelRoadsInComposite до параллели. }
    SegOffA:      TLvlSglArr;
    SegOffB:      TLvlSglArr;
    SegRA:        TLvlSglArr;
    SegRB:        TLvlSglArr;
    { Подходные съезды туннелей (Osm3dGeomTunnels): сегменты с индексом
      >= RampStart — траншеи с ЯВНЫМИ высотами концов (RampH0/H1 по
      индексу S-RampStart). Воркер считает их отдельно от дорожных
      сегментов и при наличии съезда в охвате берёт ТОЛЬКО его профиль —
      дорожная сеть у портала не приподнимает дно траншеи. }
    RampStart:    Integer;
    RampH0:       TLvlSglArr;
    RampH1:       TLvlSglArr;
    { Якоря стыков FIT-мостов («одна геометрия»): в сечении стыка полотно =
      ровно высота кромки настила (см. ApplyJoints в LeveledHeightAt). }
    Joints:       TDeckJointArray;            { ref — read-only in workers }
    Grid:         TLvlGrid;                   { ref — read-only in workers }
    GridN:        TLvlIntArr;                 { ref — read-only in workers }
    GW, GH:       Integer;
    GMinX, GMinZ: Single;
    CELL, BLEND:  Single;
    Moved:        LongInt;   { summed across workers via InterlockedExchangeAdd }
  end;
  PLevelCtx = ^TLevelCtx;

const
  { Порог |FIT − рельеф_сетки|, выше которого точка МОЖЕТ быть не дорогой
    текущего заезда: настил моста над поперечной дорогой отстоит от неё на
    7-21 м (замер ген-лога), а дорога заезда лежит почти на своём FIT-рельефе
    (сетка там скорректирована тем же FIT). 4 м уверенно разделяет эти случаи. }
  ROAD_FIT_DEM_BAND_M = 4.0;
  { Запас к полуширине настила при проверке «точка под мостом», м. }
  BRIDGE_UNDER_MARGIN_M = 3.0;
  { Максимальный ДОПОЛНИТЕЛЬНЫЙ уклон полотна при затухании FIT-офсета вдоль
    дорожной сети за коридором FIT (плавный съезд с полотна на рельеф там, где
    FIT кончается или куда уходит поперечная дорога без своего FIT). 0.12 = 12%. }
  ROAD_FIT_FADE_SLOPE = 0.12;
  { Длина продольного бленда прижима полотна к кромке настила моста, м:
    в сечении стыка полотно = ровно высота кромки, за эти метры наружу
    прижим smoothstep-ом выходит на обычную выровненную высоту. }
  ROAD_JOINT_BLEND_M = 6.0;
  { Полоса полного прижима у сечения стыка, м (float-допуск на вершины
    среза + первые сантиметры полотна строго на высоте кромки). }
  ROAD_JOINT_PIN_M = 0.10;

{ Есть ли НАД точкой (APX,APZ) мостовой настил — т.е. точка в плане попадает в
  полосу какого-либо IsBridge-сегмента. Только тогда «FIT сильно выше рельефа»
  трактуем как поперечную дорогу под мостом (ронять на рельеф). Переезд через
  воду без моста настила над собой НЕ имеет → остаётся на FIT (без исключений,
  как и просил заказчик). }
function PointUnderBridge(const ABr: TRoadCenterlineSegArray;
  APX, APZ: Single): Boolean;
var
  B: Integer;
  bx, bz, bl2, bt, qx, qz, bd, bhalf: Single;
begin
  Result := False;
  for B := 0 to High(ABr) do
  begin
    bx := ABr[B].X1 - ABr[B].X0;
    bz := ABr[B].Z1 - ABr[B].Z0;
    bl2 := bx*bx + bz*bz;
    if bl2 < 1e-9 then bt := 0
    else bt := ((APX - ABr[B].X0)*bx + (APZ - ABr[B].Z0)*bz) / bl2;
    if bt < 0 then bt := 0 else if bt > 1 then bt := 1;
    qx := ABr[B].X0 + bt*bx;
    qz := ABr[B].Z0 + bt*bz;
    bd := Sqrt((APX - qx)*(APX - qx) + (APZ - qz)*(APZ - qz));
    bhalf := ABr[B].Width * 0.5 + BRIDGE_UNDER_MARGIN_M;
    if bd <= bhalf then Exit(True);
  end;
end;

{ Высота ВЫРОВНЕННОЙ поверхности в плановой точке (PX,PZ) — единственное
  определение функции выравнивания дорог. Точная логика прежнего тела
  LevelRange: осевые высоты по FIT (гладкий продольный профиль) / рельеф +
  затухающий FIT-офсет сети (плато на запас коридора + конус 12%), 1/d²-бленд
  сегментов, плоское полотно поперёк, насыпь smoothstep за кромкой.
  AApplied=False — точка вне охвата дорог (высота = рельеф как есть).
  ACubic: рельефные сэмплы (gridE / natY / фолбэк) бикубические — для расчёта
  НОРМАЛЕЙ градиентом этой же функции (гладкая земля без фасеток); False —
  билинейные, бит-в-бит прежнее выравнивание геометрии. }
function RoadLeveledHeightAt(c: PLevelCtx; PX, PZ: Single;
  ACubic: Boolean; out AApplied: Boolean): Single;
var
  cx, cz, cidx, k, S, bestSeg: Integer;
  dx, dz, len2, t, tR, fx, fz, d, half, edgeY, natY, f: Single;
  bestD, bestHalf, eyW, eySum, wseg, ey, gridE: Single;
  segL, arcA, arcB, oA, oB, oS, rawE: Single;
  rbestD, rbestHalf, reyW, reySum: Single;
  rFound, rAnyInt: Boolean;
  HaveFit, anyInterior: Boolean;
  fitY: Double;

  function TerrAt(AX, AZ: Single): Single; inline;
  begin
    if ACubic then
      Result := c^.Sampler.SampleAtXZCubic(c^.Projection, AX, AZ)
    else
      Result := c^.Sampler.SampleAtXZ(c^.Projection, AX, AZ);
  end;

  { Прижим полотна к кромке настила моста («одна геометрия», FIT-мосты).
    Применяется ПОСЛЕДНИМ, поверх FIT/фейдов/кап-гейта: кромка настила —
    жёсткий якорь. В сечении стыка (вдоль <= ROAD_JOINT_PIN_M наружу)
    высота = ровно H кромки, дальше smoothstep-выход на обычную функцию за
    ROAD_JOINT_BLEND_M; поперёк — полный прижим на полотне, спад на полосе
    насыпи (BLEND).
    ГЕОМЕТРИЯ (ACubic=False): точки на мостовой стороне (вдоль <
    -ROAD_JOINT_PIN_M) не трогаются — там лист обязан упасть в вырез под
    настил (стенка абатмента).
    НОРМАЛИ (ACubic=True): поверхность «как едут» продолжается за стык НА
    настил, поэтому прижим действует и на мостовую сторону (до -BLEND):
    центральные разности ±EPS у стыка не должны пересекать обрыв выреза —
    иначе поднятый прижимом край дороги остаётся с нормалями обрыва (тёмная
    полоса, выглядит как провал полотна, хотя геометрия ровная). Стенке
    выреза под настилом это даёт «плоские» нормали — она скрыта настилом. }
  procedure ApplyJoints;
  var
    j: Integer;
    jdx, jdz, ja, jlat, jf, jw: Single;
  begin
    for j := 0 to High(c^.Joints) do
    begin
      jdx := PX - c^.Joints[j].JX;
      jdz := PZ - c^.Joints[j].JZ;
      ja  := jdx * c^.Joints[j].DirX + jdz * c^.Joints[j].DirZ;
      if ACubic then
      begin
        if (ja < -ROAD_JOINT_BLEND_M) or (ja > ROAD_JOINT_BLEND_M) then Continue;
      end
      else if (ja < -ROAD_JOINT_PIN_M) or (ja > ROAD_JOINT_BLEND_M) then Continue;
      jlat := Abs(jdx * c^.Joints[j].DirZ - jdz * c^.Joints[j].DirX);
      if jlat > c^.Joints[j].HalfW + c^.BLEND then Continue;
      if ja <= ROAD_JOINT_PIN_M then
        jw := 1.0                    { на стыке и на мостовой стороне — полный }
      else
      begin
        jf := (ja - ROAD_JOINT_PIN_M) / (ROAD_JOINT_BLEND_M - ROAD_JOINT_PIN_M);
        jw := 1.0 - jf * jf * (3.0 - 2.0 * jf);
      end;
      if jlat > c^.Joints[j].HalfW then
      begin
        jf := (jlat - c^.Joints[j].HalfW) / c^.BLEND;
        jw := jw * (1.0 - jf * jf * (3.0 - 2.0 * jf));
      end;
      if jw <= 0.0 then Continue;
      Result := Result + jw * (c^.Joints[j].H - Result);
      AApplied := True;
    end;
  end;

begin
  AApplied := False;
  Result := TerrAt(PX, PZ);   { вне охвата дорог — рельеф как есть }

  cx := Trunc((PX - c^.GMinX) / c^.CELL);
  cz := Trunc((PZ - c^.GMinZ) / c^.CELL);
  if (cx < 0) or (cx >= c^.GW) or (cz < 0) or (cz >= c^.GH) then
  begin
    ApplyJoints;
    Exit;
  end;
  cidx := cz * c^.GW + cx;
  if c^.GridN[cidx] = 0 then
  begin
    ApplyJoints;
    Exit;
  end;

  HaveFit := (c^.FitLayer <> nil) and c^.FitLayer.Active;
  anyInterior := False;
  bestD := 1e30; bestSeg := -1; bestHalf := 0;
  eyW := 0; eySum := 0;
  rFound := False; rAnyInt := False;
  rbestD := 1e30; rbestHalf := 0; reyW := 0; reySum := 0;
  for k := 0 to c^.GridN[cidx] - 1 do
  begin
    S := c^.Grid[cidx][k];
    dx := c^.Segs[S].X1 - c^.Segs[S].X0;
    dz := c^.Segs[S].Z1 - c^.Segs[S].Z0;
    len2 := dx*dx + dz*dz;
    if len2 < 1e-9 then tR := 0
    else tR := ((PX - c^.Segs[S].X0)*dx + (PZ - c^.Segs[S].Z0)*dz) / len2;
    t := tR;
    if t < 0 then t := 0 else if t > 1 then t := 1;
    fx := c^.Segs[S].X0 + t*dx;
    fz := c^.Segs[S].Z0 + t*dz;
    d  := Sqrt((PX - fx)*(PX - fx) + (PZ - fz)*(PZ - fz));
    half := RoadWidthAt(c^.Segs[S].Surface,c^.Segs[S].Width,t) * 0.5;
    if S >= c^.RampStart then
    begin
      { Подходной съезд туннеля: ЯВНЫЙ продольный профиль траншеи, строго
        внутри сегмента (за торцами — нет влияния: траншея кончается у
        портала/у съезда без «чаши» в соседнем грунте). Учитывается
        отдельно от дорожных сегментов (см. выбор результата ниже). }
      if (tR < -1e-4) or (tR > 1.0 + 1e-4) then Continue;
      if d > half + c^.BLEND then Continue;
      rFound := True;
      if tR < 1.0 - 1e-4 then rAnyInt := True;
      wseg  := 1.0 / (d*d + 0.25);
      reyW  := reyW + wseg;
      reySum := reySum + wseg * (c^.RampH0[S - c^.RampStart]
        + (c^.RampH1[S - c^.RampStart] - c^.RampH0[S - c^.RampStart]) * t);
      if d < rbestD then
      begin
        rbestD := d; rbestHalf := half;
      end;
      Continue;
    end;
    if d <= half + c^.BLEND then
    begin
      { The outside wedge of a bend projects past BOTH joined segments.
        It still belongs to the road, not a terminal cap to drop onto DEM.
        Bridges are excluded from JoinedEnds: the ground at a deck approach
        must retain the existing terminal-cap rule. }
      if ((tR >= -1e-4) and (tR < 1.0 - 1e-4)) or
         ((tR < 0) and ((c^.JoinedEnds[S] and 1) <> 0)) or
         ((tR >= 1.0 - 1e-4) and ((c^.JoinedEnds[S] and 2) <> 0)) then
        anyInterior := True;
      { distance-weighted (1/d^2) height at this seg's nearest point: nearest seg dominates,
        neighbours blend at junctions so edgeY stays continuous across the Voronoi seam. }
      wseg  := 1.0 / (d*d + 0.25);
      eyW   := eyW + wseg;
      { Высота осевой точки:
        • полотно с FIT (в коридоре, не под настилом) — ТОЧНЫЙ гладкий FIT
          (в т.ч. переезд через воду без моста — никаких исключений);
        • иначе — рельеф + остаточный FIT-офсет узловой сети дорог: от узла с
          офсетом идёт ПЛАТО на его «запас коридора» R, дальше затухание с
          уклоном ROAD_FIT_FADE_SLOPE (12%); берём максимум конусов обоих
          концов сегмента — плавный съезд вместо «стены». Под настилом моста
          узлы не прикалываются (v25) → поперечная уходит ПОД мост. }
      gridE := TerrAt(fx, fz);
      if HaveFit
         and c^.FitLayer.RoadTargetGeo(c^.Projection.Unproject(fx, fz), fitY)
         and not ((Abs(fitY - gridE) > ROAD_FIT_DEM_BAND_M)
                  and PointUnderBridge(c^.BridgeSegs, fx, fz)) then
        ey := fitY
      else if S <= High(c^.SegOffA) then
      begin
        { База конуса — СЫРОЙ рельеф. Офсет узла считался как FIT − сырой DEM
          (полный провал), поэтому складывать его можно только с сырым
          рельефом: rawE + off даёт ровно FIT у приколотого узла. С TerrAt
          (скорректированный) внутри коридора выходил ДВОЙНОЙ счёт:
          [DEM + w·(FIT−DEM)] + (FIT−DEM) — перелёт до (1+w)·(FIT−DEM) над
          целью. Раньше это не стреляло лишь потому, что RoadTargetGeo
          отдавал жёсткую цель на всём коридоре и ветка else работала только
          снаружи, где TerrAt = сырой DEM. }
        rawE := c^.Sampler.SampleRawAtXZ(c^.Projection, fx, fz);
        segL := Sqrt(len2);
        arcA := t * segL - c^.SegRA[S];          { за плато узла A }
        if arcA < 0 then arcA := 0;
        oA := Abs(c^.SegOffA[S]) - ROAD_FIT_FADE_SLOPE * arcA;
        if oA < 0 then oA := 0;
        arcB := (1.0 - t) * segL - c^.SegRB[S];  { за плато узла B }
        if arcB < 0 then arcB := 0;
        oB := Abs(c^.SegOffB[S]) - ROAD_FIT_FADE_SLOPE * arcB;
        if oB < 0 then oB := 0;
        if oA >= oB then
        begin
          if c^.SegOffA[S] < 0 then oA := -oA;
          oS := oA;
        end
        else
        begin
          if c^.SegOffB[S] < 0 then oB := -oB;
          oS := oB;
        end;
        { Огибающая с рельефом — НЕПРЕРЫВНО (max/min двух непрерывных):
            подъём (oS>=0): ey = max(rawE + oS, gridE)
            выемка (oS<0):  ey = min(rawE + oS, gridE)
          У приколотого узла оба члена = FIT → ровно цель. Где конус
          иссяк (oS=0) → рельеф: за коридором gridE = rawE (шва нет), а
          ВНУТРИ коридора (поперечная режет коридор без своего узла) —
          скорректированный рельеф, и дорога не проваливается под землю
          на (FIT − DEM), как было бы с голым rawE. }
        ey := rawE + oS;
        if oS >= 0 then
        begin
          if ey < gridE then ey := gridE;
        end
        else
          if ey > gridE then ey := gridE;
      end
      else
        ey := gridE;
      eySum := eySum + wseg * ey;
      if d < bestD then
      begin
        bestD := d; bestSeg := S; bestHalf := half;
      end;
    end;
  end;

  { Съезд туннеля в охвате — БЕРЁМ ТОЛЬКО ЕГО: дорожная сеть у портала
    (её концевые «шапки» с высотой рельефа) не должна приподнимать дно
    траншеи над полотном забоя. Поперёк — то же правило, что у дорог:
    на полотне плоско, за кромкой smoothstep-откос на рельеф (стенки
    траншеи). }
  if rFound then
  begin
    edgeY := reySum / reyW;   { reyW > 0 при rFound }
    if rbestD <= rbestHalf then
      Result := edgeY
    else
    begin
      natY := TerrAt(PX, PZ);
      f := (rbestD - rbestHalf) / c^.BLEND;
      f := f * f * (3.0 - 2.0 * f);
      Result := edgeY + f * (natY - edgeY);
    end;
    { гейт «не строить выше» для концевых шапок — как у дорог }
    if not rAnyInt then
    begin
      natY := TerrAt(PX, PZ);
      if Result > natY then Result := natY;
    end;
    ApplyJoints;
    AApplied := True;
    Exit;
  end;

  if bestSeg < 0 then
  begin
    ApplyJoints;
    Exit;
  end;

  edgeY := eySum / eyW;     { eyW > 0 whenever bestSeg >= 0 }
  if bestD <= bestHalf then
    Result := edgeY                              { on the road: flat cross section }
  else
  begin
    natY := TerrAt(PX, PZ);
    f := (bestD - bestHalf) / c^.BLEND;          { 0 at edge .. 1 at band outer }
    f := f * f * (3.0 - 2.0 * f);                { smoothstep }
    Result := edgeY + f * (natY - edgeY);        { embankment }
  end;

  { Кап-гейт «не строить выше»: точка держится ТОЛЬКО концевыми «шапками»
    сегментов (все проекции клампятся на торцы way) — например, за
    примыканием дороги к мосту, над вырезом пролёта: мостовые сегменты в
    выравнивании не участвуют, и шапка последнего сегмента подхода тянула
    землю выреза ВВЕРХ до уровня полотна — бугор у торца настила. Выше
    естественной высоты в шапке не поднимаем; опускание (срез у тупика,
    прежний провал полотна вниз здесь не возвращается — полотно проецируется
    внутрь сегмента) оставляем. }
  if not anyInterior then
  begin
    if bestD <= bestHalf then
      natY := TerrAt(PX, PZ);    { в on-road ветке ещё не сэмплирован }
    if Result > natY then
      Result := natY;
  end;
  { Якорь стыка настила — последним, поверх кап-гейта: у торца моста полотно
    обязано выйти ровно на кромку настила, даже если шапка сегмента подхода
    попала под гейт «не строить выше». }
  ApplyJoints;
  AApplied := True;
end;

function LeveledHeightAt(c: PLevelCtx; PX, PZ: Single;
  ACubic: Boolean; out AApplied: Boolean): Single;
var WaterH, Weight, Base: Single;
begin
  Result := RoadLeveledHeightAt(c, PX, PZ, ACubic, AApplied);
  if (c^.Sampler.WaterLevels <> nil) and
     c^.Sampler.WaterLevels.TargetAt(PX, PZ, WaterH, Weight) then
  begin
    { The sampler already applies the bank blend. Attenuate only the ROAD
      correction here, so the bank is not blended twice and roads cannot
      tilt a lake or its welded shoreline. Bridge decks are built later. }
    if ACubic then Base := c^.Sampler.SampleAtXZCubic(c^.Projection, PX, PZ)
    else Base := c^.Sampler.SampleAtXZ(c^.Projection, PX, PZ);
    Result := Base + (Result - Base) * (1 - Weight);
    AApplied := True;
  end;
end;

procedure LevelRange(Ctx: Pointer; AStartIdx, AEndExcl: Integer);
var
  c: PLevelCtx;
  p, localMoved: Integer;
  Pos: TVector3;
  newY: Single;
  applied: Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1421);{$ENDIF}
  c := PLevelCtx(Ctx);
  localMoved := 0;
  for p := AStartIdx to AEndExcl - 1 do
  begin
    Pos := c^.Comp.Pool.PositionOf(p);
    newY := LeveledHeightAt(c, Pos.X, Pos.Z, False, applied);
    if not applied then Continue;
    c^.Comp.Pool.SetPosition(p, Vector3(Pos.X, newY, Pos.Z));
    Inc(localMoved);
  end;
  if localMoved > 0 then
    InterlockedExchangeAdd(c^.Moved, localMoved);   { one add per worker }
end;

{ Нормали пула — градиент ТОЙ ЖЕ выровненной поверхности LeveledHeightAt
  (бикубический рельеф + дороги/насыпи/съезды), центральные разности ±EPS.
  Прежний SmoothCompositeNormals брал градиент ЧИСТОГО рельефа сэмплера — пока
  дорога совпадала с сэмплером это сходилось, но с высотой полотна из FIT
  (v23) и съездами (v27) поверхность ушла от сэмплера на метры, и нормали
  перестали соответствовать видимой геометрии: пятна/полосы освещения вдоль
  дорог и насыпей. Теперь высота и нормаль — одна функция. }
procedure LevelNormalsRange(Ctx: Pointer; AStartIdx, AEndExcl: Integer);
const
  EPS = 1.0;
var
  c: PLevelCtx;
  p: Integer;
  Pos: TVector3;
  hL, hR, hD, hU, dHdx, dHdz, nx, nz, inv: Single;
  dummy: Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1423);{$ENDIF}
  c := PLevelCtx(Ctx);
  for p := AStartIdx to AEndExcl - 1 do
  begin
    Pos := c^.Comp.Pool.PositionOf(p);
    hL := LeveledHeightAt(c, Pos.X - EPS, Pos.Z, True, dummy);
    hR := LeveledHeightAt(c, Pos.X + EPS, Pos.Z, True, dummy);
    hD := LeveledHeightAt(c, Pos.X, Pos.Z - EPS, True, dummy);
    hU := LeveledHeightAt(c, Pos.X, Pos.Z + EPS, True, dummy);
    dHdx := (hR - hL) * (1.0 / (2.0 * EPS));
    dHdz := (hU - hD) * (1.0 / (2.0 * EPS));
    nx := -dHdx;
    nz := -dHdz;
    inv := 1.0 / Sqrt(nx*nx + 1.0 + nz*nz);
    c^.Comp.Pool.SetNormal(p, Vector3(nx * inv, inv, nz * inv));
  end;
end;

{ Возвращает True, если выравнивание отработало И нормали пула пересчитаны по
  выровненной поверхности (LevelNormalsRange). False — ранний выход (нет
  сегментов/композита): вызывающий обязан прогнать SmoothCompositeNormals,
  иначе пул останется с нормалями карва. }
function LevelRoadsInComposite(Composite: TGroundCompositeMesh;
  const ARoadSegs: TRoadCenterlineSegArray;
  const ARamps: TTunnelApproachSegArray; const AFences: TFenceMeshes;
  Sampler: TTerrainSampler;
  Projection: TLocalProjection; AFitLayer: TFitHeightLayer;
  const AJoints: TDeckJointArray;
  LogProc: TLogProc): Boolean;
const
  CELL  = 32.0;     { seg grid cell, metres }
  MAX_GRID_CELLS = 262144; { bound the dense index even for unusually large surfaces }
  QUERY_MARGIN = 2.0; { LevelNormalsRange samples one metre outside the surface }
  BLEND = 6.0;      { embankment band beyond the road edge, metres }
var
  ctx: TLevelCtx;
  GMinX, GMinZ, GMaxX, GMaxZ, CellSize, InvCell: Single;
  GridW64, GridH64: Int64;
  Pos: TVector3;
  GW, GH, NC: Integer;
  Grid:  TLvlGrid;                { cell -> seg indices }
  GridN: TLvlIntArr;              { live seg count per cell }
  I, S, cx, cz, cx0, cx1, cz0, cz1, cidx: Integer;
  half, reach, bminx, bminz, bmaxx, bmaxz: Single;
  PoolN, LiveSegs, BrN: Integer;
  Segs: TRoadCenterlineSegArray;  { дорожные осевые + съезды туннелей (в конце) }
  RampH0, RampH1: TLvlSglArr;     { явные высоты концов съездов }
  BridgeSegs: TRoadCenterlineSegArray;
  { — узловой граф дорожной сети для затухания FIT-офсета (fit-fade) — }
  NodeMap: specialize TDictionary<Int64, Integer>;
  NodeX, NodeZ, NodeP, NodeSg, NodeR, AdjLen: TLvlSglArr;
  SegNA, SegNB, NodeDegree, AdjHead, AdjNext, AdjNode, QueueArr: TLvlIntArr;
  InQ: array of Boolean;
  SegOffA, SegOffB, SegRA, SegRB: TLvlSglArr;
  NN, EN, QH, QT, QCap, n, e, u, v, pinned: Integer;
  loY, hiY, loW, hiW: Double;
  hasLo, hasHi, underBr, pinUnder: Boolean;
  ndg: TFitLevelsDiag;
  gNc, gNr, off0, cand, dcy, maxOff, segLenM: Single;
  FenceMat,FenceV,FenceMoved:Integer;
  FenceMesh:TMesh; FenceVerts:TMeshVertexArray; FencePos:TVector3;
  FenceGround,FenceOffset:Single; FenceApplied:Boolean;

  { Узел по концу сегмента: слить совпадающие концы (квант 0.125 м — смежные
    OSM-way делят узел, координаты совпадают до эпсилона). }
  function NodeOf(AX, AZ: Single): Integer;
  var Key: Int64;
  begin
    Key := (Int64(Cardinal(Round(AX * 8.0))) shl 32)
        or  Int64(Cardinal(Round(AZ * 8.0)));
    if NodeMap.TryGetValue(Key, Result) then Exit;
    Result := NN;
    NodeMap.Add(Key, Result);
    if NN >= Length(NodeX) then
    begin
      SetLength(NodeX, (NN + 1) * 2);
      SetLength(NodeZ, (NN + 1) * 2);
    end;
    NodeX[NN] := AX; NodeZ[NN] := AZ;
    Inc(NN);
  end;

  procedure AddEdge(AFrom, ATo: Integer; ALen: Single);
  begin
    if EN >= Length(AdjNext) then
    begin
      SetLength(AdjNext, (EN + 1) * 2);
      SetLength(AdjNode, (EN + 1) * 2);
      SetLength(AdjLen,  (EN + 1) * 2);
    end;
    AdjNext[EN] := AdjHead[AFrom];
    AdjNode[EN] := ATo;
    AdjLen[EN]  := ALen;
    AdjHead[AFrom] := EN;
    Inc(EN);
  end;

  procedure QPush(AN: Integer);
  begin
    if InQ[AN] then Exit;
    QueueArr[QT] := AN; QT := (QT + 1) mod QCap; InQ[AN] := True;
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1422);{$ENDIF}
  Result := False;
  Grid := nil; GridN := nil;
  { Дорожные осевые + подходные съезды туннелей (в конец общего массива,
    индексы >= Length(ARoadSegs) — воркер считает их по RampH0/H1). }
  Segs := nil;
  SetLength(Segs, Length(ARoadSegs) + Length(ARamps));
  if Length(ARoadSegs) > 0 then
    Move(ARoadSegs[0], Segs[0], Length(ARoadSegs) * SizeOf(Segs[0]));
  RampH0 := nil; RampH1 := nil;
  SetLength(RampH0, Length(ARamps));
  SetLength(RampH1, Length(ARamps));
  for I := 0 to High(ARamps) do
  begin
    Segs[Length(ARoadSegs) + I] := ARamps[I].Seg;
    RampH0[I] := ARamps[I].H0;
    RampH1[I] := ARamps[I].H1;
  end;

  if (Composite = nil) or (Composite.VertexCount = 0)
     or (Length(Segs) = 0) or (Sampler = nil) or (Projection = nil) then Exit;

  { Мостовые сегменты (настилы) — отдельным компактным списком: по нему воркер
    решает, есть ли настил НАД точкой (поперечная под мостом → на рельеф). }
  BrN := 0;
  SetLength(BridgeSegs, Length(Segs));
  for I := 0 to High(Segs) do
    if Segs[I].IsBridge then
    begin
      BridgeSegs[BrN] := Segs[I];
      Inc(BrN);
    end;
  SetLength(BridgeSegs, BrN);

  { Bound the lookup by its QUERY surface, not by all OSM ways. A recursive
    OSM response may include roads thousands of kilometres away. Keep those
    segments in the topology graph below (FIT propagation and joined ends),
    but never allocate empty grid cells between them and this surface. }
  GMinX := 1e30; GMinZ := 1e30; GMaxX := -1e30; GMaxZ := -1e30;
  for I := 0 to Composite.Pool.Count - 1 do
  begin
    Pos := Composite.Pool.PositionOf(I);
    GMinX := Min(GMinX, Pos.X); GMaxX := Max(GMaxX, Pos.X);
    GMinZ := Min(GMinZ, Pos.Z); GMaxZ := Max(GMaxZ, Pos.Z);
  end;
  GMinX := GMinX - QUERY_MARGIN; GMinZ := GMinZ - QUERY_MARGIN;
  GMaxX := GMaxX + QUERY_MARGIN; GMaxZ := GMaxZ + QUERY_MARGIN;
  if IsNan(GMaxX - GMinX) or IsInfinite(GMaxX - GMinX) or
     IsNan(GMaxZ - GMinZ) or IsInfinite(GMaxZ - GMinZ) then
    raise ERangeError.Create('Non-finite road leveling bounds');

  { A coarser lookup changes candidates only, not the exact distance/height
    calculation. Size arithmetic stays in Double/Int64 until bounded. }
  CellSize := CELL;
  while ((Double(GMaxX) - GMinX) / CellSize + 1) *
        ((Double(GMaxZ) - GMinZ) / CellSize + 1) > MAX_GRID_CELLS do
    CellSize := CellSize * 2;
  InvCell := 1.0 / CellSize;
  GridW64 := Trunc((Double(GMaxX) - GMinX) * InvCell) + 1;
  GridH64 := Trunc((Double(GMaxZ) - GMinZ) * InvCell) + 1;
  if (GridW64 < 1) or (GridH64 < 1) or
     (GridW64 * GridH64 > MAX_GRID_CELLS) then
    raise ERangeError.Create('Invalid road leveling grid size');
  GW := GridW64; GH := GridH64;
  NC := GridW64 * GridH64;
  SetLength(Grid, NC);
  SetLength(GridN, NC);
  for I := 0 to NC - 1 do GridN[I] := 0;

  LiveSegs := 0;
  for S := 0 to High(Segs) do
  begin
    if Segs[S].IsBridge then Continue;   { в сетку выравнивания не попадают }
    half  := Segs[S].Width * 0.5;
    reach := half + BLEND;
    if Segs[S].X0 < Segs[S].X1 then begin bminx := Segs[S].X0; bmaxx := Segs[S].X1; end
    else begin bminx := Segs[S].X1; bmaxx := Segs[S].X0; end;
    if Segs[S].Z0 < Segs[S].Z1 then begin bminz := Segs[S].Z0; bmaxz := Segs[S].Z1; end
    else begin bminz := Segs[S].Z1; bmaxz := Segs[S].Z0; end;
    { Reject before clamping: otherwise remote ways land in the edge cell.
      An outside centreline whose width/blend reaches the surface is kept. }
    bminx := bminx - reach; bmaxx := bmaxx + reach;
    bminz := bminz - reach; bmaxz := bmaxz + reach;
    if (bmaxx < GMinX) or (bminx > GMaxX) or
       (bmaxz < GMinZ) or (bminz > GMaxZ) then Continue;
    Inc(LiveSegs);
    cx0 := Trunc((Max(bminx, GMinX) - GMinX) * InvCell);
    cx1 := Min(GW - 1, Trunc((Min(bmaxx, GMaxX) - GMinX) * InvCell));
    cz0 := Trunc((Max(bminz, GMinZ) - GMinZ) * InvCell);
    cz1 := Min(GH - 1, Trunc((Min(bmaxz, GMaxZ) - GMinZ) * InvCell));
    for cz := cz0 to cz1 do
      for cx := cx0 to cx1 do
      begin
        cidx := cz * GW + cx;
        if GridN[cidx] >= Length(Grid[cidx]) then
        begin
          if Length(Grid[cidx]) = 0 then SetLength(Grid[cidx], 4)
          else SetLength(Grid[cidx], Length(Grid[cidx]) * 2);
        end;
        Grid[cidx][GridN[cidx]] := S;
        Inc(GridN[cidx]);
      end;
  end;

  if Assigned(LogProc) then
    LogProc(Format('  road leveling grid: %dx%d, %d cells, %.0f m, %d / %d segments',
      [GW, GH, NC, CellSize, LiveSegs, Length(Segs)]));

  { 2b. Остаточный FIT-офсет узлов дорожной сети (fit-fade). Узлы = слитые
       концы сегментов; узел в коридоре FIT (и не под настилом моста) «приколот»
       с офсетом = FIT − рельеф_сетки. От приколотых узлов офсет затухает по
       рёбрам сети с уклоном ROAD_FIT_FADE_SLOPE (12%) — SPFA-релаксация.
       Воркеры добавляют офсет (плато на «запас коридора» узла + конус 12%,
       максимум двух концов сегмента) к рельефу ЗА коридором FIT: плавный съезд
       с полотна вместо «стены» там, где FIT кончается (конец заезда) или куда
       уходит поперечная дорога без своего FIT. Затухание идёт ТОЛЬКО по связной
       дорожной сети — параллельная несоединённая дорога рядом с насыпью офсет
       не получает (иначе её приподняло бы без причины). }
  SetLength(SegOffA, Length(Segs));
  SetLength(SegOffB, Length(Segs));
  SetLength(SegRA,   Length(Segs));
  SetLength(SegRB,   Length(Segs));
  for I := 0 to High(Segs) do
  begin
    SegOffA[I] := 0; SegOffB[I] := 0; SegRA[I] := 0; SegRB[I] := 0;
  end;
  pinned := 0; maxOff := 0;
  { Topology is needed even without FIT: distinguish a joined corner from
    a real road end. The same node graph also drives FIT offset propagation. }
  if Length(Segs) > 0 then
  begin
    NodeMap := specialize TDictionary<Int64, Integer>.Create;
    try
      NN := 0; EN := 0;
      SetLength(SegNA, Length(Segs));
      SetLength(SegNB, Length(Segs));
      for I := 0 to High(Segs) do
      begin
        SegNA[I] := -1; SegNB[I] := -1;
        if Segs[I].IsBridge then Continue;   { настилы не выравниваются — вне сети }
        SegNA[I] := NodeOf(Segs[I].X0, Segs[I].Z0);
        SegNB[I] := NodeOf(Segs[I].X1, Segs[I].Z1);
      end;
      SetLength(NodeDegree, NN);
      for I := 0 to High(Segs) do
      begin
        if (SegNA[I] < 0) or (SegNB[I] < 0) or (SegNA[I] = SegNB[I]) then Continue;
        Inc(NodeDegree[SegNA[I]]);
        Inc(NodeDegree[SegNB[I]]);
      end;
      SetLength(ctx.JoinedEnds, Length(Segs));
      for I := 0 to High(Segs) do
      begin
        if (SegNA[I] < 0) or (SegNB[I] < 0) then Continue;
        if NodeDegree[SegNA[I]] > 1 then ctx.JoinedEnds[I] := 1;
        if NodeDegree[SegNB[I]] > 1 then ctx.JoinedEnds[I] := ctx.JoinedEnds[I] or 2;
      end;
      if (NN > 0) and (AFitLayer <> nil) and AFitLayer.Active then
      begin
        SetLength(AdjHead, NN);
        for n := 0 to NN - 1 do AdjHead[n] := -1;
        for I := 0 to High(Segs) do
        begin
          if (SegNA[I] < 0) or (SegNB[I] < 0) or (SegNA[I] = SegNB[I]) then Continue;
          segLenM := Sqrt(Sqr(Segs[I].X1 - Segs[I].X0)
                        + Sqr(Segs[I].Z1 - Segs[I].Z0));
          AddEdge(SegNA[I], SegNB[I], segLenM);
          AddEdge(SegNB[I], SegNA[I], segLenM);
        end;

        SetLength(NodeP, NN); SetLength(NodeSg, NN); SetLength(NodeR, NN);
        SetLength(InQ, NN);
        QCap := NN + 1;
        SetLength(QueueArr, QCap);
        QH := 0; QT := 0;
        for n := 0 to NN - 1 do
        begin
          NodeP[n] := 0; NodeSg[n] := 0; NodeR[n] := 0; InQ[n] := False;
        end;

        { Прикалывание: узел в коридоре FIT → офсет = FIT − СЫРОЙ DEM (за
          коридором рельеф падает на DEM — офсет должен покрыть весь провал,
          иначе на дороге заезда его собственный офсет был бы ≈0: сетка в
          коридоре уже FIT-корректирована). Гейт как в LevelRange (v25): FIT
          сильно выше СКОРРЕКТИРОВАННОГО рельефа И под настилом = поперечная
          под мостом — не прикалываем (она уходит под мост по рельефу).
          NodeR — «запас коридора»: расстояние от узла до кромки коридора FIT
          вдоль дороги; в его пределах офсет — плато (продолжение полотна),
          затухание начинается за кромкой. Восстанавливается из веса феатера
          loW (обратный косинус); w≥0.999 — узел на полотне, запас максимум. }
        for n := 0 to NN - 1 do
        begin
          if not AFitLayer.DiagGeo(Projection.Unproject(NodeX[n], NodeZ[n]),
               loY, hiY, loW, hiW, hasLo, hasHi, ndg) then Continue;
          { ГЕЙТ ПОЛОТНА (тот же, что в RoadTargetXZ). Прикалываем только там,
            где по земле реально ехали: наземный вес нижнего кластера ≥ порога
            = узел ВНУТРИ FITL_HALF_WIDTH_M, и в кластере есть НЕ-настильные
            точки. Раньше гейта не было — DiagGeo отдаёт True на любой кандидат
            в HALF+FEATHER (26 м), и узел ЧУЖОЙ улицы в 25.9 м от трека (вес
            феатера 0.0006!) прикалывался к его уровню целиком: off0 = FIT −
            сырой DEM, дальше SPFA разливал это по связной сети на off/0.12 =
            до 347 м. Замер по ген-логу: 628 узлов выше сырого DEM на 10+ м,
            89% из них задаёт ОДИН файл с битым датумом, у которого в тех
            точках сырой барометр совпадает с DEM (подъём целиком придумало
            нивелирование). Земля от этого защищена весовым блендом
            (BlendGround), у прикалывания защиты не было. }
          underBr := PointUnderBridge(BridgeSegs, NodeX[n], NodeZ[n]);
          { РАСШИРЕНИЕ НИЖНИХ ВЫСОТ ПОД МОСТОМ. Поперечная дорога, идущая ПОД
            пролётом, обязана держать НИЖНИЙ уровень непрерывно: строгий гейт
            полотна (вес=1) давал цель только ровно по линии проезда, между —
            дорога проваливалась на сетку, полотно шло волнами. Под мостом
            прикалываем узел к нижнему уровню при ЛЮБОМ наземном свидетельстве
            (LoGndW>0 — по низу здесь ездили, пусть и в стороне); плато —
            полный коридор слоя, плавный возврат к обычным высотам за мостом
            делает штатное затухание 12% (SPFA) — расстояние возврата то же,
            что у затухания. Чисто настильные кластеры (LoGndW=0, по низу
            никто не ездил) по-прежнему не прикалывают. }
          pinUnder := underBr and (ndg.LoGndW > 0);
          if (ndg.LoGndW < FITL_ROAD_SNAP_W) and (not pinUnder) then Continue;
          gNc := Sampler.SampleAtXZ(Projection, NodeX[n], NodeZ[n]);
          gNr := Sampler.SampleRawAtXZ(Projection, NodeX[n], NodeZ[n]);
          if (Abs(Single(loY) - gNc) > ROAD_FIT_DEM_BAND_M)
             and underBr and (not pinUnder) then
            Continue;
          off0 := Single(loY) - gNr;
          NodeP[n] := Abs(off0);
          if off0 >= 0 then NodeSg[n] := 1.0 else NodeSg[n] := -1.0;
          { Запас коридора: узел на полотне (вес≈1) — плато = ПОЛУШИРИНА
            полотна (прежнее HALF+FEATHER продлевало плато на 18 м феатера,
            где жёсткой цели уже нет, — ступенька). Узел ПОД МОСТОМ
            (pinUnder) — плато на полный коридор слоя: соседние подмостовые
            узлы перекрываются плато, нижний уровень идёт под пролётом
            непрерывно, без провалов конуса между узлами. }
          if pinUnder and (ndg.LoGndW < FITL_ROAD_SNAP_W) then
            NodeR[n] := FITL_HALF_WIDTH_M + FITL_FEATHER_M
          else
            NodeR[n] := FITL_HALF_WIDTH_M;
          Inc(pinned);
          if Abs(off0) > maxOff then maxOff := Abs(off0);
          QPush(n);
        end;

        { SPFA-релаксация: |офсет| убывает на SLOPE·(len − запас) вдоль ребра —
          плато в пределах запаса коридора, затем конус 12%. }
        while QH <> QT do
        begin
          u := QueueArr[QH]; QH := (QH + 1) mod QCap; InQ[u] := False;
          e := AdjHead[u];
          while e >= 0 do
          begin
            v := AdjNode[e];
            dcy := AdjLen[e] - NodeR[u];
            if dcy < 0 then dcy := 0;
            cand := NodeP[u] - ROAD_FIT_FADE_SLOPE * dcy;
            if cand > NodeP[v] + 0.001 then
            begin
              NodeP[v] := cand; NodeSg[v] := NodeSg[u];
              QPush(v);
            end;
            e := AdjNext[e];
          end;
        end;

        for I := 0 to High(Segs) do
        begin
          if (SegNA[I] < 0) or (SegNB[I] < 0) then Continue;
          SegOffA[I] := NodeSg[SegNA[I]] * NodeP[SegNA[I]];
          SegOffB[I] := NodeSg[SegNB[I]] * NodeP[SegNB[I]];
          SegRA[I]   := NodeR[SegNA[I]];
          SegRB[I]   := NodeR[SegNB[I]];
        end;
      end;
    finally
      NodeMap.Free;
    end;
  end;

  { 3. level each pool entry against the nearest centerline within reach —
       PARALLEL: pure per-vertex, disjoint SetPosition, read-only grid/segs. }
  PoolN := Composite.Pool.Count;
  ctx.Comp := Composite; ctx.Sampler := Sampler; ctx.Projection := Projection;
  ctx.FitLayer := AFitLayer;
  ctx.Segs := Segs;
  ctx.BridgeSegs := BridgeSegs;
  ctx.Joints := AJoints;   { якоря стыков настилов («одна геометрия») }
  ctx.SegOffA := SegOffA;
  ctx.SegOffB := SegOffB;
  ctx.SegRA := SegRA;
  ctx.SegRB := SegRB;
  ctx.RampStart := Length(ARoadSegs);
  ctx.RampH0 := RampH0;
  ctx.RampH1 := RampH1;
  ctx.Grid := Grid; ctx.GridN := GridN;
  ctx.GW := GW; ctx.GH := GH;
  ctx.GMinX := GMinX; ctx.GMinZ := GMinZ;
  ctx.CELL := CellSize; ctx.BLEND := BLEND;
  ctx.Moved := 0;
  GenerationParallelFor('Road leveling', PoolN, @LevelRange, @ctx);

  { OSM barriers were extruded against the sampler before road leveling and
    tunnel approach excavation. Move each vertical edge by the same terrain
    correction, preserving fence height, gates and explicit min_height.
    Bridge parapets are emitted later and must retain their deck attachment. }
  FenceMoved:=0;
  for FenceMat:=0 to FENCE_PALETTE_SIZE-1 do
  begin
    FenceMesh:=AFences.Fences[FenceMat];
    if FenceMesh=nil then Continue;
    FenceVerts:=FenceMesh.Vertices;
    for FenceV:=0 to FenceMesh.VertexCount-1 do
    begin
      FencePos:=FenceVerts[FenceV].Position;
      FenceGround:=LeveledHeightAt(@ctx,FencePos.X,FencePos.Z,False,FenceApplied);
      if not FenceApplied then Continue;
      FenceOffset:=FenceGround-Sampler.SampleAtXZ(Projection,FencePos.X,FencePos.Z);
      if Abs(FenceOffset)<0.001 then Continue;
      FencePos.Y:=FencePos.Y+FenceOffset;
      FenceMesh.SetVertexPosition(FenceV,FencePos);
      Inc(FenceMoved);
    end;
  end;
  if (FenceMoved>0) and Assigned(LogProc) then
    LogProc(Format('  fence grounding: adjusted %d vertices to leveled roads/tunnel approaches',[FenceMoved]));


  { Нормали — градиент ТОЙ ЖЕ выровненной поверхности (LeveledHeightAt с
    бикубическим рельефом), тем же ctx. Заменяет SmoothCompositeNormals на
    этом пути: тот брал чистый рельеф сэмплера, и после ухода полотна на FIT
    нормали переставали соответствовать геометрии (пятна освещения). }
  GenerationParallelFor('Road normals', PoolN, @LevelNormalsRange, @ctx);
  Result := True;

  if Assigned(LogProc) then
  begin
    LogProc(Format('  road leveling: adjusted %d / %d pool entries (%d centerline segs); normals: leveled-surface gradient',
      [ctx.Moved, PoolN, LiveSegs]));
    if pinned > 0 then
      LogProc(Format('  fit-fade: %d узлов сети приколото к FIT, max|off|=%.2f м, затухание %.0f%% вдоль дорог',
        [pinned, maxOff, ROAD_FIT_FADE_SLOPE * 100.0]));
  end;
end;

{ ── Диагностический дамп высот полотна в ОТДЕЛЬНЫЙ ген-лог (osm3d_gen_*.log) ──
  Пишет, из чего сложилась высота дороги вдоль КАЖДОЙ осевой (то, что теперь
  берётся прямо из FIT через RoadTargetGeo). Идёт по сегментам с шагом
  DIAG_STEP_M и на каждой выборке кладёт: гео-координаты, roadY(=нижний уровень
  FIT), ΔY к предыдущей выборке, верхний уровень HiY, признак раскола на два
  уровня (split>=0 → мост/развязка/наложение заездов), число кандидатов коридора
  NC, крупнейший разрыв высот gap и разброс [min..max], сырой DEM и высоту сетки
  террейна для сравнения. Скачок |ΔY| > SPIKE_DY_M или наличие двух уровней
  помечаются флагом и дампят СПИСОК высот кандидатов — по нему видно, что пик
  рождается «перебросом» нижнего кластера между соседними точками. Итог блока —
  строка SUMMARY. Только для чтения слоя; геометрию не меняет. }
procedure DumpFitRoadDiag(const Segs: TRoadCenterlineSegArray;
  Sampler: TTerrainSampler; Projection: TLocalProjection;
  AFitLayer: TFitHeightLayer; const ASettings: TStudioSettings;
  const ABox: TLatLonBox);
const
  DIAG_STEP_M = 4.0;     { шаг выборки вдоль осевой, м }
  MAX_PER_SEG = 48;      { потолок выборок на сегмент }
  MAX_LINES   = 6000;    { потолок строк дампа на блок (защита от гиганта) }
  SPIKE_DY_M  = 0.5;     { |ΔY| соседних выборок выше этого — помечаем ПИК }
var
  S, i, nSamp, lines, twoLev, spikes, liveSegs, k: Integer;
  nx, nz, segLen, t: Double;
  fx, fz: Single;
  LoY, HiY, LoW, HiW, prevY, dY, worstDY, rawDem, gridY: Double;
  HasLo, HasHi, hadPrev, capped: Boolean;
  Diag: TFitLevelsDiag;
  LL, worstLL: TLatLon;
  flag, altStr: string;
begin
  if (not GenDiagEnabled) or (AFitLayer = nil) or (not AFitLayer.Active) then Exit;
  if Length(Segs) = 0 then Exit;

  liveSegs := 0;
  for S := 0 to High(Segs) do
    if not Segs[S].IsBridge then Inc(liveSegs);

  GenLog('');
  GenLog(Format('==== BLOCK lat[%.6f..%.6f] lon[%.6f..%.6f]  fit_sig=%s ====',
    [ABox.MinLat, ABox.MaxLat, ABox.MinLon, ABox.MaxLon, AFitLayer.Signature]));
  GenLog(Format('  gen: gridStep=%.1fm subdiv=%d hmZoom=%d routeOnly=%s radius=%.0fm',
    [ASettings.TerrainGridStepMeters, ASettings.TerrainSubdiv, ASettings.HeightmapZoom,
     BoolToStr(ASettings.GenerateRouteOnly, 'on', 'off'), ASettings.RouteOnlyRadiusM]));
  GenLog(Format('  fit corridor: half=%.1fm feather=%.1fm levelSplit=%.1fm  segs(live)=%d',
    [FITL_HALF_WIDTH_M, FITL_FEATHER_M, FITL_LEVEL_SPLIT_M, liveSegs]));
  GenLog('  cols: seg/t | lat lon | roadY dY | HiY split NC gap[min..max] | rawDEM gridY | flag');

  lines := 0; twoLev := 0; spikes := 0; worstDY := 0; capped := False;
  worstLL.Lat := 0; worstLL.Lon := 0;

  for S := 0 to High(Segs) do
  begin
    if Segs[S].IsBridge then Continue;
    if lines >= MAX_LINES then begin capped := True; Break; end;

    nx := Segs[S].X1 - Segs[S].X0;
    nz := Segs[S].Z1 - Segs[S].Z0;
    segLen := Sqrt(nx*nx + nz*nz);
    if segLen < 1e-6 then Continue;
    nSamp := Trunc(segLen / DIAG_STEP_M);
    if nSamp < 1 then nSamp := 1;
    if nSamp > MAX_PER_SEG then nSamp := MAX_PER_SEG;

    hadPrev := False; prevY := 0;
    for i := 0 to nSamp do
    begin
      if lines >= MAX_LINES then begin capped := True; Break; end;
      t := i / nSamp;
      fx := Segs[S].X0 + t * nx;
      fz := Segs[S].Z0 + t * nz;
      LL := Projection.Unproject(fx, fz);
      rawDem := Sampler.SampleRawAtXZ(Projection, fx, fz);
      gridY  := Sampler.SampleAtXZ(Projection, fx, fz);

      if not AFitLayer.DiagGeo(LL, LoY, HiY, LoW, HiW, HasLo, HasHi, Diag) then
      begin
        { осевая точка ВНЕ коридора FIT — дорога тут падает на сетку террейна }
        GenLog(Format('  %d/%.2f | %.6f %.6f | (no-fit)      | | rawDEM=%.2f gridY=%.2f | FALLBACK-TO-GRID',
          [S, t, LL.Lat, LL.Lon, rawDem, gridY]));
        Inc(lines);
        hadPrev := False;
        Continue;
      end;

      if HasHi then Inc(twoLev);

      dY := 0;
      if hadPrev then dY := LoY - prevY;

      flag := '';
      if HasHi then flag := flag + 'TWO-LEVEL ';
      if hadPrev and (Abs(dY) > SPIKE_DY_M) then
      begin
        flag := flag + Format('SPIKE(dY=%.2f) ', [dY]);
        Inc(spikes);
        if Abs(dY) > Abs(worstDY) then begin worstDY := dY; worstLL := LL; end;
      end;

      { список высот кандидатов — только на подозрительных точках (иначе лог
        распухнет): именно здесь видно два кластера и почему нижний «прыгает». }
      altStr := '';
      if (HasHi) or (hadPrev and (Abs(dY) > SPIKE_DY_M)) then
      begin
        for k := 0 to Diag.AltN - 1 do
          altStr := altStr + Format('%.2f ', [Diag.Alt[k]]);
        altStr := ' alts=[' + Trim(altStr) + ']';
      end;

      GenLog(Format('  %d/%.2f | %.6f %.6f | roadY=%.2f dY=%.2f | HiY=%.2f split=%d NC=%d gap=%.2f[%.2f..%.2f] | rawDEM=%.2f gridY=%.2f | %s%s',
        [S, t, LL.Lat, LL.Lon, LoY, dY, HiY, Diag.SplitAt, Diag.NC,
         Diag.BestGap, Diag.MinAlt, Diag.MaxAlt, rawDem, gridY, flag, altStr]));
      Inc(lines);
      prevY := LoY; hadPrev := True;
    end;
  end;

  GenLog(Format('  SUMMARY: samples=%d two-level=%d spikes=%d worst_dY=%.2f @ lat %.6f lon %.6f%s',
    [lines, twoLev, spikes, worstDY, worstLL.Lat, worstLL.Lon,
     BoolToStr(capped, '  (CAPPED)', '')]));
end;

{ Master switch for the audit passes. The audit is a read-only topology diagnostic (no geometry
  change) but costs a full edge pass + twin-pair search and heavy logging. OFF in production;
  flip to True only when debugging cracks / watertightness. }
var
  AUDIT_GROUND_COMPOSITE: Boolean = False;

{ TEST TOGGLE: горизонтальное выравнивание дорог по горизонту (LevelRoadsInComposite).
  True  — обычный режим (дороги выравниваются по фит/фейд, нормали с выровненной пов-ти).
  False — выравнивание ПОЛНОСТЬЮ пропускается: полотно ложится на рельеф как есть
          (DrapeComposite остаётся), нормали считает фолбэк SmoothCompositeNormals.
  Флаг только для отладки. Смена значения меняет геометрию → сбросьте кэш тайлов. }
var
  LEVEL_ROADS_ENABLED: Boolean = True;

{ Целочисленный тракт карва (Osm3dCarveGround) — единственный:
  float-клиппер и его флаг USE_INT_CARVE физически снесены (этапы 5-6). }
{ Topology diagnostic (no geometry change). Reports open edges (used by exactly one triangle =
  hole/crack), split into perimeter (expected) vs INTERIOR (real cracks), plus near-but-unwelded
  vertex pairs. interior-open = 0 means the composite is watertight and any cracks come later
  (tiling / render), not the carve. }
procedure AuditGroundComposite(Composite: TGroundCompositeMesh;
  const ATag: string; LogProc: TLogProc);
const
  MARGIN    = 1.0;          { open edge within this of the chunk bbox = perimeter }
  NEAR_MIN2 = 0.1 * 0.1;    { below the 0.1 m weld -> already merged }
  NEAR_MAX2 = 0.5 * 0.5;    { report unwelded twins up to 0.5 m }
  TWIN_CAP  = 6000;         { cap the O(M^2) interior-endpoint twin scan }
var
  TriN, PN, I, p0, p1, p2, nE, e, rs, rl, a, b, mId: Integer;
  VtRef: TCompositeVertexArray;
  IRef:  TMeshIndexArray;
  MRef:  TMaterialIdArray;
  Keys:  array of Int64;
  EMat:  array of Integer;
  bMinX, bMinZ, bMaxX, bMaxZ, mx, mz: Single;
  Pp, Pa, Pb: TVector3;
  openCount, maniCount, nonMani, interiorOpen: Integer;
  m3, m46, m712, m13p, nmMono, nmMixed, kk: Integer;
  nmSame: Boolean;
  iMinX, iMinZ, iMaxX, iMaxZ: Single;
  EP: array of Integer;
  epN, j, k, twinN, sampN: Integer;
  MatHist: array of Integer;
  isPerim: Boolean;
  d2: Single;

  procedure PushEdge(x, y, m: Integer);
  var key: Int64;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1423);{$ENDIF}
    if x = y then Exit;
    if x < y then key := (Int64(x) shl 32) or Int64(Cardinal(y))
    else          key := (Int64(y) shl 32) or Int64(Cardinal(x));
    Keys[nE] := key; EMat[nE] := m; Inc(nE);
  end;

  procedure QSort(lo, hi: Integer);
  var i2, j2, tm: Integer; piv, tk: Int64;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1424);{$ENDIF}
    while lo < hi do
    begin
      i2 := lo; j2 := hi; piv := Keys[(lo + hi) shr 1];
      while i2 <= j2 do
      begin
        while Keys[i2] < piv do Inc(i2);
        while Keys[j2] > piv do Dec(j2);
        if i2 <= j2 then
        begin
          tk := Keys[i2]; Keys[i2] := Keys[j2]; Keys[j2] := tk;
          tm := EMat[i2]; EMat[i2] := EMat[j2]; EMat[j2] := tm;
          Inc(i2); Dec(j2);
        end;
      end;
      if (j2 - lo) < (hi - i2) then
      begin if lo < j2 then QSort(lo, j2); lo := i2; end
      else
      begin if i2 < hi then QSort(i2, hi); hi := j2; end;
    end;
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1425);{$ENDIF}
  if (Composite = nil) or not Assigned(LogProc) then Exit;
  TriN := Composite.TriangleCount;
  PN   := Composite.Pool.Count;
  if (TriN = 0) or (PN = 0) then Exit;
  VtRef := Composite.Verts;
  IRef  := Composite.Indices;
  MRef  := Composite.MaterialIds;

  { chunk bbox -> separate perimeter open edges from interior cracks }
  bMinX := 1e30; bMinZ := 1e30; bMaxX := -1e30; bMaxZ := -1e30;
  for I := 0 to PN - 1 do
  begin
    Pp := Composite.Pool.PositionOf(I);
    if Pp.X < bMinX then bMinX := Pp.X;
    if Pp.X > bMaxX then bMaxX := Pp.X;
    if Pp.Z < bMinZ then bMinZ := Pp.Z;
    if Pp.Z > bMaxZ then bMaxZ := Pp.Z;
  end;

  SetLength(Keys, TriN * 3);
  SetLength(EMat, TriN * 3);
  nE := 0;
  for I := 0 to TriN - 1 do
  begin
    p0 := VtRef[IRef[I*3    ]].PoolIdx;
    p1 := VtRef[IRef[I*3 + 1]].PoolIdx;
    p2 := VtRef[IRef[I*3 + 2]].PoolIdx;
    if IRef[I*3] < Length(MRef) then mId := MRef[IRef[I*3]] else mId := -1;
    PushEdge(p0, p1, mId);
    PushEdge(p1, p2, mId);
    PushEdge(p2, p0, mId);
  end;
  if nE = 0 then Exit;
  QSort(0, nE - 1);

  openCount := 0; maniCount := 0; nonMani := 0; interiorOpen := 0;
  m3 := 0; m46 := 0; m712 := 0; m13p := 0; nmMono := 0; nmMixed := 0;
  iMinX := 1e30; iMinZ := 1e30; iMaxX := -1e30; iMaxZ := -1e30;
  EP := nil; epN := 0; MatHist := nil;
  e := 0;
  while e < nE do
  begin
    rs := e;
    while (e < nE) and (Keys[e] = Keys[rs]) do Inc(e);
    rl := e - rs;
    if rl = 1 then
    begin
      Inc(openCount);
      a := Integer(Keys[rs] shr 32);
      b := Integer(Keys[rs] and Int64($FFFFFFFF));
      Pa := Composite.Pool.PositionOf(a);
      Pb := Composite.Pool.PositionOf(b);
      mx := (Pa.X + Pb.X) * 0.5;
      mz := (Pa.Z + Pb.Z) * 0.5;
      isPerim := (mx - bMinX <= MARGIN) or (bMaxX - mx <= MARGIN)
              or (mz - bMinZ <= MARGIN) or (bMaxZ - mz <= MARGIN);
      if not isPerim then
      begin
        Inc(interiorOpen);
        if mx < iMinX then iMinX := mx;
        if mx > iMaxX then iMaxX := mx;
        if mz < iMinZ then iMinZ := mz;
        if mz > iMaxZ then iMaxZ := mz;
        mId := EMat[rs];
        if (mId >= 0) and (mId < 4096) then
        begin
          if mId >= Length(MatHist) then SetLength(MatHist, mId + 1);
          Inc(MatHist[mId]);
        end;
        if epN < TWIN_CAP * 2 then
        begin
          if epN + 2 > Length(EP) then SetLength(EP, (epN + 2) * 2 + 16);
          EP[epN] := a; Inc(epN);
          EP[epN] := b; Inc(epN);
        end;
      end;
    end
    else if rl = 2 then Inc(maniCount)
    else
    begin
      Inc(nonMani);
      if rl = 3 then Inc(m3)
      else if rl <= 6 then Inc(m46)
      else if rl <= 12 then Inc(m712)
      else Inc(m13p);
      nmSame := True;
      for kk := rs + 1 to e - 1 do
        if EMat[kk] <> EMat[rs] then begin nmSame := False; Break; end;
      if nmSame then Inc(nmMono) else Inc(nmMixed);
    end;
  end;

  { unwelded twins among interior open-edge endpoints (3D; post-level the
    leveling has spread coincident-but-unmerged vertices apart). O(epN^2), capped. }
  twinN := 0; sampN := 0;
  if (epN > 0) and (epN <= TWIN_CAP * 2) then
    for j := 0 to epN - 1 do
    begin
      Pa := Composite.Pool.PositionOf(EP[j]);
      for k := j + 1 to epN - 1 do
      begin
        if EP[k] = EP[j] then Continue;
        Pb := Composite.Pool.PositionOf(EP[k]);
        d2 := (Pa.X-Pb.X)*(Pa.X-Pb.X) + (Pa.Y-Pb.Y)*(Pa.Y-Pb.Y) + (Pa.Z-Pb.Z)*(Pa.Z-Pb.Z);
        if (d2 > NEAR_MIN2) and (d2 <= NEAR_MAX2) then
        begin
          Inc(twinN);
          if sampN < 8 then
          begin
            { dxz/dy раздельно: по ним видно, какая метрика закроет пару —
              широкий твин карва (dxz большой) или «вертикальная щель»
              выравнивания (dxz мал, dy велик) — и каким допуском. }
            LogProc(Format('    [audit %s] twin pool %d<->%d  d=%.3f m ' +
              '(dxz=%.3f dy=%.3f)  @(%.1f, %.1f, %.1f)',
              [ATag, EP[j], EP[k], Sqrt(d2),
               Sqrt((Pa.X-Pb.X)*(Pa.X-Pb.X) + (Pa.Z-Pb.Z)*(Pa.Z-Pb.Z)),
               Abs(Pa.Y-Pb.Y), Pa.X, Pa.Y, Pa.Z]));
            Inc(sampN);
          end;
        end;
      end;
    end;

  LogProc(Format('  [audit %s] tris=%d edges=%d | manifold=%d open=%d (interior=%d perimeter=%d) nonmanifold=%d',
    [ATag, TriN, openCount + maniCount + nonMani, maniCount,
     openCount, interiorOpen, openCount - interiorOpen, nonMani]));
  if nonMani > 0 then
    LogProc(Format('    [audit %s] nonmanifold mult: 3=%d 4-6=%d 7-12=%d 13+=%d | mono-material=%d mixed-material=%d',
      [ATag, m3, m46, m712, m13p, nmMono, nmMixed]));
  if interiorOpen > 0 then
  begin
    LogProc(Format('    [audit %s] INTERIOR open edges span X[%.0f..%.0f] Z[%.0f..%.0f]  unwelded-twin pairs=%d',
      [ATag, iMinX, iMaxX, iMinZ, iMaxZ, twinN]));
    for I := 0 to High(MatHist) do
      if MatHist[I] > 0 then
        LogProc(Format('      matId %d : %d interior open edges', [I, MatHist[I]]));
  end
  else
    LogProc(Format('    [audit %s] no INTERIOR open edges -> composite watertight inside; cracks (if any) come from tiling/render',
      [ATag]));
end;

{ ═════ ОТЛАДКА «ДРОТИКОВ»: дамп карва вокруг одной гео-точки ═════
  Пишет carve_debug_<tick>.log в DefaultCacheRoot только если геометрия
  чанка пересекает бокс вокруг (CARVE_DBG_LAT, CARVE_DBG_LON). Иначе —
  ни одной строки: никакого спама на остальных чанках. }
const
  CARVE_DBG_ENABLED   = False;
  CARVE_DBG_LAT: Double = 59.75923;
  CARVE_DBG_LON: Double = 60.18442;
  CARVE_DBG_R:   Double = 80.0;      { полубокс, м }
  CARVE_DBG_RING_FULL = 400;         { кольца длиннее — печать только окном }
  CARVE_DBG_MAX_TRIS  = 20000;
  CARVE_CELLS_R: Double = 14.0;      { полубокс пер-ячеечного дампа items, м }

function DumpCarveDebugAt(const ALayers: array of TIntCaptureLayer;
  ALayerN: Integer; const AOutMeshes: TCarvedMatMeshArray;
  Projection: TLocalProjection): string;
var
  SL: TStringList;
  C: TVector3;
  BX0, BZ0, BX1, BZ1: Double;
  L, R, K, mi, t, cnt, TrisPrinted, HitRings: Integer;
  wx, wz, rx0, rz0, rx1, rz1, Area2, px, pz: Double;
  AnyHit, Full, InWin, PrevIn, OutOfRange: Boolean;
  Ring: TLatRing;
  M: TMesh;
  V: TMeshVertexArray;
  Ix: TMeshIndexArray;
  i0, i1, i2: Integer;
  tx0, tz0, tx1, tz1: Double;
  S: string;

  function MatName(AId: Integer): string;
  begin
    if AId = GROUND_MAT_HOLE then Exit('HOLE(-1)');
    if (AId >= 0) and (AId < GROUND_MAT_COUNT) then
      Exit(GROUND_MATERIALS[AId].Name + '(' + IntToStr(AId) + ')');
    Result := '?(' + IntToStr(AId) + ')';
  end;

  function BoxHit(ax0, az0, ax1, az1: Double): Boolean;
  begin
    Result := (ax1 >= BX0) and (ax0 <= BX1) and
              (az1 >= BZ0) and (az0 <= BZ1);
  end;

  procedure RingBBox(const Rg: TLatRing);
  var q: Integer;
  begin
    rx0 := 1e30; rz0 := 1e30; rx1 := -1e30; rz1 := -1e30;
    Area2 := 0; OutOfRange := False;
    if Length(Rg) = 0 then Exit;
    for q := 0 to High(Rg) do
    begin
      wx := LatToWorld(Rg[q].X); wz := LatToWorld(Rg[q].Z);
      if wx < rx0 then rx0 := wx;
      if wx > rx1 then rx1 := wx;
      if wz < rz0 then rz0 := wz;
      if wz > rz1 then rz1 := wz;
      if (Abs(Rg[q].X) >= 262144) or (Abs(Rg[q].Z) >= 262144) then
        OutOfRange := True;
      px := LatToWorld(Rg[(q + 1) mod Length(Rg)].X);
      pz := LatToWorld(Rg[(q + 1) mod Length(Rg)].Z);
      Area2 := Area2 + (wx * pz - px * wz);
    end;
  end;

begin
  Result := '';
  if not CARVE_DBG_ENABLED then Exit;
  if Projection = nil then Exit;
  C := Projection.Project(CARVE_DBG_LAT, CARVE_DBG_LON);
  BX0 := C.X - CARVE_DBG_R; BX1 := C.X + CARVE_DBG_R;
  BZ0 := C.Z - CARVE_DBG_R; BZ1 := C.Z + CARVE_DBG_R;

  { быстрый отсев чанков мимо бокса }
  AnyHit := False;
  for L := 0 to ALayerN - 1 do
  begin
    for R := 0 to High(ALayers[L].Rings) do
    begin
      RingBBox(ALayers[L].Rings[R]);
      if BoxHit(rx0, rz0, rx1, rz1) then begin AnyHit := True; Break; end;
    end;
    if AnyHit then Break;
  end;
  if not AnyHit then Exit;

  SL := TStringList.Create;
  try
    SL.Add(Format('== carve debug @ lat=%.6f lon=%.6f -> local (%.2f, %.2f), box +-%.0f m',
      [CARVE_DBG_LAT, CARVE_DBG_LON, C.X, C.Z, CARVE_DBG_R]));
    SL.Add(Format('== layers (peel order, по убыванию ZIndex): %d', [ALayerN]));

    for L := 0 to ALayerN - 1 do
    begin
      HitRings := 0;
      for R := 0 to High(ALayers[L].Rings) do
      begin
        Ring := ALayers[L].Rings[R];
        RingBBox(Ring);
        if not BoxHit(rx0, rz0, rx1, rz1) then Continue;
        if HitRings = 0 then
          SL.Add(Format('LAYER %d mat=%s zindex=%d uv=%d rings_total=%d',
            [L, MatName(ALayers[L].MatId), ALayers[L].ZIndex,
             Ord(ALayers[L].UVMode), Length(ALayers[L].Rings)]));
        Inc(HitRings);
        if Area2 < 0 then S := 'CW' else S := 'CCW';
        SL.Add(Format(' RING %d pts=%d %s area2=%.1f bbox=(%.2f,%.2f)..(%.2f,%.2f)%s',
          [R, Length(Ring), S, Area2, rx0, rz0, rx1, rz1,
           BoolToStr(OutOfRange, ' !!LATTICE-OUT-OF-RANGE', '')]));
        Full := Length(Ring) <= CARVE_DBG_RING_FULL;
        S := '  v='; cnt := 0; PrevIn := False;
        for K := 0 to High(Ring) do
        begin
          wx := LatToWorld(Ring[K].X); wz := LatToWorld(Ring[K].Z);
          InWin := Full or
            ((wx >= BX0 - 40) and (wx <= BX1 + 40) and
             (wz >= BZ0 - 40) and (wz <= BZ1 + 40));
          if InWin then
          begin
            S := S + Format('#%d(%.2f,%.2f)', [K, wx, wz]);
            Inc(cnt);
            if cnt mod 6 = 0 then begin SL.Add(S); S := '    '; end;
          end
          else if PrevIn then
            S := S + ' ... ';
          PrevIn := InWin;
        end;
        if Trim(S) <> '' then SL.Add(S);
      end;
    end;

    SL.Add('== output triangles in box ==');
    TrisPrinted := 0;
    for mi := 0 to High(AOutMeshes) do
    begin
      M := AOutMeshes[mi].Mesh;
      if (M = nil) or (M.TriangleCount = 0) then Continue;
      V := M.Vertices; Ix := M.Indices;
      cnt := 0;
      for t := 0 to M.TriangleCount - 1 do
      begin
        i0 := Ix[t*3]; i1 := Ix[t*3+1]; i2 := Ix[t*3+2];
        tx0 := V[i0].Position.X; tx1 := tx0;
        tz0 := V[i0].Position.Z; tz1 := tz0;
        if V[i1].Position.X < tx0 then tx0 := V[i1].Position.X;
        if V[i1].Position.X > tx1 then tx1 := V[i1].Position.X;
        if V[i2].Position.X < tx0 then tx0 := V[i2].Position.X;
        if V[i2].Position.X > tx1 then tx1 := V[i2].Position.X;
        if V[i1].Position.Z < tz0 then tz0 := V[i1].Position.Z;
        if V[i1].Position.Z > tz1 then tz1 := V[i1].Position.Z;
        if V[i2].Position.Z < tz0 then tz0 := V[i2].Position.Z;
        if V[i2].Position.Z > tz1 then tz1 := V[i2].Position.Z;
        if not BoxHit(tx0, tz0, tx1, tz1) then Continue;
        if cnt = 0 then
          SL.Add('OUT mat=' + MatName(AOutMeshes[mi].MatId));
        Inc(cnt); Inc(TrisPrinted);
        SL.Add(Format(' T (%.2f,%.2f)(%.2f,%.2f)(%.2f,%.2f) ' +
          'uv=(%.3f,%.3f)(%.3f,%.3f)(%.3f,%.3f) osm=%d/%d/%d',
          [V[i0].Position.X, V[i0].Position.Z,
           V[i1].Position.X, V[i1].Position.Z,
           V[i2].Position.X, V[i2].Position.Z,
           V[i0].UV.X, V[i0].UV.Y, V[i1].UV.X, V[i1].UV.Y,
           V[i2].UV.X, V[i2].UV.Y,
           V[i0].OsmId, V[i1].OsmId, V[i2].OsmId]));
        if TrisPrinted >= CARVE_DBG_MAX_TRIS then Break;
      end;
      if cnt > 0 then
        SL.Add(Format(' (mat %s: %d tris in box)',
          [MatName(AOutMeshes[mi].MatId), cnt]));
      if TrisPrinted >= CARVE_DBG_MAX_TRIS then
      begin
        SL.Add(' !! MAX_TRIS cap hit, output truncated');
        Break;
      end;
    end;

    Result := IncludeTrailingPathDelimiter(DefaultCacheRoot) +
      'carve_debug_' + IntToStr(GetTickCount64) + '.log';
    ForceDirectories(DefaultCacheRoot);
    SL.SaveToFile(Result);
  finally
    SL.Free;
  end;
end;


{ Узловая маска нутра: узлы сетки, лежащие строго внутри какого-либо
  футпринта. Ячейка с 4 узлами в маске целиком невидима (крыша/стены). }
function BuildHoleNodeMask(const Casters: TBuildingShadowCasters;
  Sampler: TTerrainSampler; Projection: TLocalProjection): TBytes;
var
  GX, GZ, ix, iz, ix0, ix1, iz0, iz1, i, k: Integer;
  fx, fz, minx, maxx, minz, maxz: Double;
  ax, az: Single;
  ctr: TVector3;
begin
  Result := nil;
  if (Sampler = nil) or (Projection = nil) or (Length(Casters) = 0) then Exit;
  GX := Sampler.GridX; GZ := Sampler.GridZ;
  if (GX < 2) or (GZ < 2) then Exit;
  SetLength(Result, GX * GZ);   { обнулён }
  for i := 0 to High(Casters) do
  begin
    if Length(Casters[i].Footprint) < 3 then Continue;
    { Дворы (мультиполигоны с inner-кольцами) и навесы (building=roof):
      земля под ними ВИДИМА — двор просматривается сверху сквозь вырез,
      навес насквозь под крышей. Такие футпринты в маску не попадают:
      карв/дециматор оставляют композит земли целым. Флаг ставит
      TBuildingBuilderExt.Build (Osm3dGeomBuildings). }
    if Casters[i].KeepGroundUnder then Continue;
    minx := 1e30; maxx := -1e30; minz := 1e30; maxz := -1e30;
    for k := 0 to High(Casters[i].Footprint) do
      if Sampler.WorldToCellFrac(Projection,
           Casters[i].Footprint[k].X, Casters[i].Footprint[k].Z, fx, fz) then
      begin
        if fx < minx then minx := fx;  if fx > maxx then maxx := fx;
        if fz < minz then minz := fz;  if fz > maxz then maxz := fz;
      end;
    if maxx < minx then Continue;
    ix0 := Trunc(minx);     if ix0 < 0 then ix0 := 0;
    iz0 := Trunc(minz);     if iz0 < 0 then iz0 := 0;
    ix1 := Trunc(maxx) + 1; if ix1 > GX - 1 then ix1 := GX - 1;
    iz1 := Trunc(maxz) + 1; if iz1 > GZ - 1 then iz1 := GZ - 1;
    for iz := iz0 to iz1 do
      for ix := ix0 to ix1 do
      begin
        if Result[iz * GX + ix] <> 0 then Continue;
        if not Sampler.NodePositionXZ(ix, iz, ax, az) then Continue;
        ctr.X := ax; ctr.Y := 0; ctr.Z := az;
        if PointInPolygonXZ(ctr, Casters[i].Footprint) and
          not InBuildingGroundOpening(ctr,Casters[i].GroundOpenings) then
          Result[iz * GX + ix] := 1;
      end;
  end;
end;

const
  BUILDING_BASE_EXPAND_M  = 0.7;    { ширина отмостки вокруг контура, м }
  BUILDING_BASE_MITER_CAP = 3.0;    { предел длины митра = CAP*EXPAND (острые углы) }

procedure AppendExpandedFootprintXZ(const FP: array of TVector3;
  D, InvUV: Single; Target: TMesh; ABag: PLatRingBag = nil;
  const Openings: TBuildingGroundOpenings = nil);
var
  N, I, J, Prev, Base: Integer;
  Ring, EN, Off: array of TVector3;   { CCW-копия, нормали рёбер, offset — все Y=0 }
  Tris: TIndexArray;
  dx, dz, len, dot, denom, t: Single;
  nA, nB, dir: TVector3;
  IntPts: TScatterPointArray;
  Pieces: TBuildingGroundOpenings;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1438);{$ENDIF}
  N := Length(FP);
  if N < 3 then Exit;

  { CCW-копия в XZ (формула внешней нормали ниже это предполагает). }
  SetLength(Ring, N);
  if PolygonSignedAreaXZ(FP) >= 0 then
    for I := 0 to N - 1 do Ring[I] := Vector3(FP[I].X, 0, FP[I].Z)
  else
    for I := 0 to N - 1 do Ring[N - 1 - I] := Vector3(FP[I].X, 0, FP[I].Z);

  { Внешняя единичная нормаль ребра i (Ring[i]->Ring[i+1]) для CCW = (dz,-dx);
    вырожденные рёбра получают нулевую нормаль и не толкают свои концы. }
  SetLength(EN, N);
  for I := 0 to N - 1 do
  begin
    J  := (I + 1) mod N;
    dx := Ring[J].X - Ring[I].X;
    dz := Ring[J].Z - Ring[I].Z;
    len := Sqrt(dx * dx + dz * dz);
    if len < 1e-6 then EN[I] := Vector3(0, 0, 0)
    else               EN[I] := Vector3(dz / len, 0, -dx / len);
  end;

  { Митр: вершина выдвигается вдоль суммы нормалей двух смежных рёбер
    P = V + D/(1+nA·nB)·(nA+nB); длина митра ограничена для острых углов. }
  SetLength(Off, N);
  for I := 0 to N - 1 do
  begin
    Prev := (I + N - 1) mod N;
    nA := EN[Prev];
    nB := EN[I];
    dir := Vector3(nA.X + nB.X, 0, nA.Z + nB.Z);
    len := Sqrt(dir.X * dir.X + dir.Z * dir.Z);
    if len < 1e-6 then begin Off[I] := Ring[I]; Continue; end;  { ~180° шип }
    dot   := nA.X * nB.X + nA.Z * nB.Z;
    denom := 1.0 + dot;
    if denom < 1e-3 then denom := 1e-3;          { страховка от деления у ~180° }
    t := D / denom;
    if len * t > D * BUILDING_BASE_MITER_CAP then
      t := (D * BUILDING_BASE_MITER_CAP) / len;
    Off[I] := Vector3(Ring[I].X + dir.X * t, 0, Ring[I].Z + dir.Z * t);
  end;

  { Cut AFTER expansion: expanding the resulting pieces would close a
    narrow passage again. Both float and int-first paths use these rings. }
  if Length(Openings)>0 then
  begin
    Pieces:=SubtractBuildingGroundOpenings(Off,Openings);
    for I:=0 to High(Pieces) do
      AppendExpandedFootprintXZ(Pieces[I],0,InvUV,Target,ABag);
    Exit;
  end;

  { int-first: расширенный контур (митры уже разрешены) уходит кольцом
    от источника — триангуляция и меш не нужны вовсе }
  if ABag <> nil then
  begin
    SetLength(IntPts, N);
    for I := 0 to N - 1 do
    begin
      IntPts[I].X := Off[I].X;
      IntPts[I].Z := Off[I].Z;
    end;
    BagAddRingWorld(ABag^, IntPts, True);
    Exit;
  end;

  { Намотка перевёрнута (T0,T2,T1) — лицом вверх, как landuse/крыши. }
  Tris := TPolygonTriangulator.TriangulateXZ(Off);
  if Length(Tris) < 3 then Exit;

  Base := Target.VertexCount;
  for I := 0 to N - 1 do
    Target.AddVertex(Off[I], Vector3(0, 1, 0),
                     Vector2(Off[I].X * InvUV, Off[I].Z * InvUV));

  I := 0;
  while I + 3 <= Length(Tris) do
  begin
    if (Tris[I]   >= 0) and (Tris[I]   < N)
    and (Tris[I+1] >= 0) and (Tris[I+1] < N)
    and (Tris[I+2] >= 0) and (Tris[I+2] < N) then
      Target.AddTriangle(Base + Tris[I], Base + Tris[I + 2], Base + Tris[I + 1]);
    Inc(I, 3);
  end;
end;

{ Общий меш отмосток всех домов чанка (пустой = no-op в захвате).
  Владелец — вызывающий (создаём, захватываем, освобождаем). }
function BuildBuildingBasesMesh(const Casters: TBuildingShadowCasters;
  UVScale: Single; ABag: PLatRingBag): TMesh;
var
  I: Integer;
  InvUV: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1439);{$ENDIF}
  Result := TMesh.Create('building_bases');
  if UVScale > 0 then InvUV := 1.0 / UVScale else InvUV := 0;
  for I := 0 to High(Casters) do
    AppendExpandedFootprintXZ(Casters[I].Footprint,
      BUILDING_BASE_EXPAND_M, InvUV, Result, ABag,Casters[I].GroundOpenings);
end;

procedure BuildBuildingPassagePaving(const Casters:TBuildingShadowCasters;
  out Bag:TLatRingBag);
var I,J,K,Start,At:Integer;One:TLatRingBag;
  Seen:TStringList;Key:string;Ring:TLatRing;
begin
  Bag:=Default(TLatRingBag);Seen:=nil;
  try
    for I:=0 to High(Casters) do
      for J:=0 to High(Casters[I].GroundOpenings) do begin
        One:=Default(TLatRingBag);
        AppendExpandedFootprintXZ(Casters[I].GroundOpenings[J],
          BUILDING_PASSAGE_PAVING_MARGIN_M,0,nil,@One);
        if One.N=0 then Continue;
        { Decoration casters copy their owner's openings. Deduplicate using
          the carve lattice, canonical winding and start vertex, independent
          of caster order, source Y, or cyclic ring representation. }
        Ring:=One.Rings[0];Start:=0;
        for K:=1 to High(Ring) do
          if (Ring[K].X<Ring[Start].X) or
            ((Ring[K].X=Ring[Start].X) and (Ring[K].Z<Ring[Start].Z)) then Start:=K;
        Key:='';
        for K:=0 to High(Ring) do begin
          At:=(Start+K) mod Length(Ring);
          Key:=Key+IntToStr(Ring[At].X)+','+IntToStr(Ring[At].Z)+';';
        end;
        if Seen=nil then begin
          Seen:=TStringList.Create;Seen.Sorted:=True;Seen.CaseSensitive:=True;
        end;
        if Seen.IndexOf(Key)>=0 then Continue;
        Seen.Add(Key);BagAppend(Bag,One);
      end;
  finally Seen.Free end;
end;

{ Parallel strip weld: partition carved triangles into Z-strips, weld each into its own builder
  (own pool, no shared state) on a worker thread, then concat. Int-путь идёт одной полосой:
  канонические позиции решётки делают межполосные щели невозможными по построению. }
type
  TWeldStripCtx = record
    OutMeshes:    TCarvedMatMeshArray;            { read-only, ref-shared }
    WaterShaders: Boolean;
    Bounds:       array of Single;                { nStrips+1 strip edges }
    SubComp:      array of TGroundCompositeMesh;   { output, one per strip }
  end;
  PWeldStripCtx = ^TWeldStripCtx;

procedure WeldStripRange(Ctx: Pointer; AStartIdx, AEndExcl: Integer);
var
  w:         PWeldStripCtx;
  strip, qi: Integer;
  B:         TGroundCompositeBuilder;
begin
  w := PWeldStripCtx(Ctx);
  for strip := AStartIdx to AEndExcl - 1 do
  begin
    B := TGroundCompositeBuilder.Create('ground_strip');
    try
      { Единая генерация: вода ВСЕГДА идёт в композит (без ветвления по
        WaterShaders). Анимация воды — на этапе рендера, шейдером материала. }
      for qi := 0 to High(w^.OutMeshes) do
        B.AppendStripInt(w^.OutMeshes[qi].Mesh, w^.OutMeshes[qi].MatId,
                      w^.OutMeshes[qi].TriTileKeys,
                      w^.Bounds[strip], w^.Bounds[strip + 1]);
      w^.SubComp[strip] := B.Finalize(nil);
    finally
      B.Free;
    end;
  end;
end;

{ ───────────────────── Децимация земли: карта близости к дорогам ─────────────
  Временный растр на разрешении карв-сетки (один тексель на узел IZ*GX+IX):
  каждый дорожный сегмент нарисован лентой своей полуширины + полосой KeepBandM
  (= зона полной детализации), затем box-блюр для мягкого спада. Значение
  255 у дороги -> 0 вдали ("чем жирнее точка, тем ближе к дороге"). В стейдже 2
  PASS 1 эмита карва читает map[cellKey] и выбирает уровень RQT-укрупнения для
  пустых ячеек. Возвращает GX*GZ байт; nil если дорог/сетки нет. ────────────── }
function BuildRoadProximityMap(const Segs: TRoadCenterlineSegArray;
  Sampler: TTerrainSampler; Projection: TLocalProjection;
  KeepBandM, RangeM: Single; out AGX, AGZ: Integer): TBytes;
var
  GX, GZ, ix, iz, minx, maxx, minz, maxz, S, blurR, pass, i, k, lo, hi: Integer;
  acc, cnt: Integer;
  cellMeters, keepCells, nx0, nz0, nx1, nz1: Single;
  fx0, fz0, fx1, fz1: Double;
  mnx, mxx, mnz, mxz, rad, dx, dz, len2, t, qx, qz, dd: Double;
  core, blur, tmp: TBytes;
begin
  AGX := 0; AGZ := 0; Result := nil;
  if (Sampler = nil) or (Projection = nil) or (Length(Segs) = 0) then Exit;
  { одни мостовые (снап-only) сегменты = дорог для drape нет: nil, как до
    их появления — блок с единственным мостом ведёт себя байт-в-байт }
  i := 0;
  while (i <= High(Segs)) and Segs[i].IsBridge do Inc(i);
  if i > High(Segs) then Exit;
  GX := Sampler.GridX; GZ := Sampler.GridZ;
  if (GX < 2) or (GZ < 2) then Exit;
  AGX := GX; AGZ := GZ;

  { метров на ячейку — из двух соседних узлов }
  Sampler.NodePositionXZ(0, 0, nx0, nz0);
  Sampler.NodePositionXZ(1, 0, nx1, nz1);
  cellMeters := Sqrt(Sqr(nx1 - nx0) + Sqr(nz1 - nz0));
  if cellMeters <= 1e-4 then cellMeters := 1.0;
  keepCells := KeepBandM / cellMeters;

  SetLength(core, GX * GZ);   { dynamic array of Byte: уже обнулён }

  { растеризация дорог-лент в клеточном пространстве (точка-сегмент дистанция) }
  for S := 0 to High(Segs) do
  begin
    { мостовые осевые — только для снаппера: под пролётом рельеф не
      drape'ится под дорогу, мелкую сетку там держать незачем (симметрично
      исключению моста в Osm3dRoadDistField) }
    if Segs[S].IsBridge then Continue;
    if not Sampler.WorldToCellFrac(Projection, Segs[S].X0, Segs[S].Z0, fx0, fz0) then Continue;
    if not Sampler.WorldToCellFrac(Projection, Segs[S].X1, Segs[S].Z1, fx1, fz1) then Continue;
    rad := Segs[S].Width * 0.5 / cellMeters + keepCells;
    if rad < 0.5 then rad := 0.5;
    if fx0 < fx1 then begin mnx := fx0; mxx := fx1; end else begin mnx := fx1; mxx := fx0; end;
    if fz0 < fz1 then begin mnz := fz0; mxz := fz1; end else begin mnz := fz1; mxz := fz0; end;
    minx := Trunc(mnx - rad);     if minx < 0 then minx := 0;
    maxx := Trunc(mxx + rad) + 1; if maxx > GX - 1 then maxx := GX - 1;
    minz := Trunc(mnz - rad);     if minz < 0 then minz := 0;
    maxz := Trunc(mxz + rad) + 1; if maxz > GZ - 1 then maxz := GZ - 1;
    dx := fx1 - fx0; dz := fz1 - fz0; len2 := dx*dx + dz*dz;
    for iz := minz to maxz do
      for ix := minx to maxx do
      begin
        if len2 < 1e-9 then t := 0
        else
        begin
          t := ((ix - fx0)*dx + (iz - fz0)*dz) / len2;
          if t < 0 then t := 0 else if t > 1 then t := 1;
        end;
        qx := fx0 + t*dx; qz := fz0 + t*dz;
        dd := Sqrt(Sqr(ix - qx) + Sqr(iz - qz));
        if dd <= rad then core[iz*GX + ix] := 255;
      end;
  end;

  { box-блюр (раздельный, 2 прохода) — мягкий спад снаружи ленты }
  blurR := Round(RangeM / cellMeters); if blurR < 1 then blurR := 1;
  SetLength(blur, GX * GZ); Move(core[0], blur[0], GX * GZ);
  SetLength(tmp, GX * GZ);
  for pass := 1 to 2 do
  begin
    for iz := 0 to GZ - 1 do
      for ix := 0 to GX - 1 do
      begin
        lo := ix - blurR; if lo < 0 then lo := 0;
        hi := ix + blurR; if hi > GX - 1 then hi := GX - 1;
        acc := 0; cnt := 0;
        for k := lo to hi do begin Inc(acc, blur[iz*GX + k]); Inc(cnt); end;
        tmp[iz*GX + ix] := acc div cnt;
      end;
    for ix := 0 to GX - 1 do
      for iz := 0 to GZ - 1 do
      begin
        lo := iz - blurR; if lo < 0 then lo := 0;
        hi := iz + blurR; if hi > GZ - 1 then hi := GZ - 1;
        acc := 0; cnt := 0;
        for k := lo to hi do begin Inc(acc, tmp[k*GX + ix]); Inc(cnt); end;
        blur[iz*GX + ix] := acc div cnt;
      end;
  end;

  { результат = max(ядро, блюр): дорога+полоса держатся на 255, спад снаружи }
  SetLength(Result, GX * GZ);
  for i := 0 to GX*GZ - 1 do
    if core[i] > blur[i] then Result[i] := core[i] else Result[i] := blur[i];
end;

{ Дамп карты близости в .pgm (P5, бинарный grayscale) — для визуальной
  проверки стейджа 1. Best-effort: ошибку записи молча игнорируем. }
procedure SaveProximityPGM(const Map: TBytes; GX, GZ: Integer; const APath: string);
var
  fs:  TFileStream;
  hdr: AnsiString;
begin
  if (GX <= 0) or (GZ <= 0) or (Length(Map) < GX * GZ) or (APath = '') then Exit;
  try
    fs := TFileStream.Create(APath, fmCreate);
    try
      hdr := Format('P5'#10'%d %d'#10'255'#10, [GX, GZ]);
      fs.WriteBuffer(hdr[1], Length(hdr));
      fs.WriteBuffer(Map[0], GX * GZ);
    finally
      fs.Free;
    end;
  except
    { best-effort отладочный дамп — ошибку записи игнорируем }
  end;
end;

{ Карта близости (255=на дороге .. 0=далеко) -> поле желаемых уровней RQT
  укрупнения на ячейку: 255 -> 0 (полная детализация), 0 -> MaxLevel. Линейно. }
function ProximityToLevelField(const Prox: TBytes; MaxLevel: Integer): TBytes;
var i, v, lvl: Integer;
begin
  Result := nil;
  if Length(Prox) = 0 then Exit;
  if MaxLevel < 0 then MaxLevel := 0;
  SetLength(Result, Length(Prox));
  for i := 0 to High(Prox) do
  begin
    v := Prox[i];
    lvl := ((255 - v) * (MaxLevel + 1)) div 256;
    if lvl < 0 then lvl := 0 else if lvl > MaxLevel then lvl := MaxLevel;
    Result[i] := Byte(lvl);
  end;
end;

procedure TGeometryBuilder.BuildGroundComposite(var AInput: TSceneInput;
  const Roads: TRoadMeshes;
  const AWaterRings: TLatRingBag;
  const ATunnelRamps: TTunnelApproachSegArray;
      const AFences: TFenceMeshes;
  Sampler: TTerrainSampler = nil;
  Projection: TLocalProjection = nil);
var
  CBuilder:  TGroundCompositeBuilder;
  Composite: TGroundCompositeMesh;
  Layout:    TGroundAtlasLayout;
  K:         TLanduseMeshKind;
  MatId:     TGroundMaterialId;
  UVTable:   TUVSourceCtxArray;
  OutMeshes: TCarvedMatMeshArray;
  TerrainSourceTag: Integer;
  UVCount:    Integer;   { trimmed once after all captures, before the carve)   }
  TCap, TEmit: TDateTime;
  nPar, totA: Integer;   { carve-pool size + running cross-gen thread total }
  Lg: TLogProc;
  Prof:      TCarveProfile;
  SrcTris:   Integer;
  qi:        Integer;
  BasesMesh: TMesh;      { отмостки домов — захватываются как pavement }
  BasesBag,PassageBag: TLatRingBag;
  HoleMask: TBytes;
  tStep:     QWord;      { per-step wall-clock (ms) for the composite log line }
  msWeld, msFinalize, msDrape, msLevel,
  msSmooth: Int64;
  LeveledNorm: Boolean;  { выравнивание отработало и нормали пересчитаны в нём }
  zMin, zMax: Single;    { geometry Z range for balanced weld strips }
  gnx, gnz: Integer;     { grid node counts for the perimeter Z-range scan }
  pxq, pzq: Single;      { scratch world XZ of a perimeter grid node }
  nStrips, vi, MergeVertices, MergeTriangles, MergePool: Integer;
  WSrcV:     TMeshVertexArray;
  WSrcI:     TMeshIndexArray;
  WeldCtx:   TWeldStripCtx;
  RoadProx:  TBytes;        { стейдж 1: карта близости к дорогам (децимация земли) }
  RoadLevel: TBytes;        { стейдж 2: поле уровней укрупнения (карта -> Lmax) }
  ProxGX, ProxGZ: Integer;
  mi: Integer;              { диагностика: проход по материалам карва }
  sfi, denC: Integer;       { диагностика: single-fill кандидаты }
  IntLayers: TIntCaptureLayerArray;   { int-тракт: слои захвата }
  IntLayerN: Integer;
  IntStats:  TCarveGroundStats;
  IntRings, ili, ilj: Integer;
  IntTmpL:   TIntCaptureLayer;
  CarveDbgFN: string;                 { отладка «дротиков»: путь дампа карва }

  function LanduseInvUVOf(AMatId: TGroundMaterialId): Single;
  begin
    if GROUND_MATERIALS[AMatId].UVScale > 0 then
      Result := 1.0 / GROUND_MATERIALS[AMatId].UVScale
    else
      Result := 0;
  end;

  procedure CaptureLayer(M: TMesh; AMatId: TGroundMaterialId;
    AStretchedUV: Boolean = False);
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1440);{$ENDIF}
    if (M <> nil) and (M.TriangleCount > 0) then
    begin
      Inc(SrcTris, M.TriangleCount);
      begin
        { int-тракт: слой = граничные кольца меша + UV-контекст.
          Дороги (ленты) и stretch-виды (питчи/хелипад: OMBB-UV 0..1 на
          полигон, из позиции не выводится) — bary по мешу-источнику;
          bary-меш обязан жить до конца карва (Roads.* живут, stretch-
          landuse чистится ПОСЛЕ CarveGroundInt). Остальной landuse —
          planar, его меш не нужен и чистится сразу после захвата. }
        if IntLayerN >= Length(IntLayers) then
          SetLength(IntLayers, IntLayerN * 2 + 8);
        IntLayers[IntLayerN].Mesh   := M;
        IntLayers[IntLayerN].MatId  := AMatId;
        IntLayers[IntLayerN].ZIndex := GROUND_MATERIALS[AMatId].ZIndex;
        if (AMatId >= GROUND_MAT_ROAD_FIRST) or AStretchedUV then
        begin
          IntLayers[IntLayerN].UVMode := iumBary;
          IntLayers[IntLayerN].InvUV  := 0;
        end
        else
        begin
          IntLayers[IntLayerN].UVMode := iumPlanar;
          if GROUND_MATERIALS[AMatId].UVScale > 0 then
            IntLayers[IntLayerN].InvUV := 1.0 / GROUND_MATERIALS[AMatId].UVScale
          else
            IntLayers[IntLayerN].InvUV := 0;
        end;
        IntRings := CaptureMeshBoundaryInt(IntLayers[IntLayerN]);
        if IntRings > 0 then
          Inc(IntLayerN);
      end;
    end;
  end;

  { дорога: кольца ленты от источника слоем (bary-UV по лёгкому UV-мешу
    квадов Edges); мешевой захват остаётся страховкой для float-пути
    (на int меш пуст — no-op) }
  procedure CaptureRoad(M: TMesh; AKind: TRoadKind; AMatId: TGroundMaterialId);
  begin
    if Roads.IntRings[AKind].N > 0 then
    begin
      if IntLayerN >= Length(IntLayers) then
        SetLength(IntLayers, IntLayerN * 2 + 8);
      LayerFromBag(IntLayers[IntLayerN], Roads.IntRings[AKind],
        AMatId, GROUND_MATERIALS[AMatId].ZIndex, iumBary, 0);
      IntLayers[IntLayerN].Mesh := Roads.UVMesh[AKind];
      Inc(IntLayerN);
    end;
    CaptureLayer(M, AMatId);
  end;


begin
  {$IFDEF IAM_LIVE}IamLiveTrack(154);{$ENDIF}
  msWeld := 0; msFinalize := 0; msDrape := 0;
  msLevel := 0; msSmooth := 0; msFinalize := 0;
  { Atlas layout from settings; fall back to default for invalid values. }
  Layout.GridCols   := FSettings.GroundAtlasGridCols;
  Layout.GridRows   := FSettings.GroundAtlasGridRows;
  Layout.TilePixels := FSettings.GroundAtlasTilePixels;
  if (Layout.GridCols < 1) or (Layout.GridRows < 1) or
     (Layout.TilePixels < 16) then
    Layout := DefaultGroundAtlasLayout;
  if Layout.GridCols * Layout.GridRows < GROUND_MAT_COUNT then
    LogInfo(Format('  GroundAtlas warning: layout %dx%d holds %d cells, ' +
      'less than GROUND_MAT_COUNT=%d. Higher-id materials will alias ' +
      'into lower cells; expect visual artefacts.',
      [Layout.GridCols, Layout.GridRows,
       Layout.GridCols * Layout.GridRows, GROUND_MAT_COUNT]));

  { No TGroundAtlas is built here. BuildGroundComposite runs on a
    background generation worker, and TGroundAtlas.BuildImage loads PNGs
    through CGE — image loading off the main thread corrupts the global
    TCastleDownload state and crashes TCastleDownload.Update. The
    composite mesh only needs matId/layout metadata, never the packed
    image; the render-side atlas is built once on the main thread
    (TCachedAssemblyResources.EnsureAtlas / the chunk assembler). }

  CBuilder := TGroundCompositeBuilder.Create('ground_composite');
  CBuilder.LogProc := FLogProc;
  try
    if (Sampler <> nil) and (Projection <> nil) then
    begin
      { carved single non-overlapping layer
 Re-clip each finished overlay mesh per terrain cell into tagged
 pieces, then CarveCell each cell (empty cells -> the full-cell terrain
 remainder) so the carved terrain replaces AInput.Terrain entirely.
 UVTable[0] is the terrain's planar context; the int capture
 appends one context per overlay triangle. }
      UVTable := nil; OutMeshes := nil;
      HoleMask := nil;
      SetLength(UVTable, 1);
      UVTable[0].Mode        := usmPlanar;
      if GROUND_MATERIALS[GROUND_MAT_TERRAIN].UVScale > 0 then
        UVTable[0].InvUV := 1.0 / GROUND_MATERIALS[GROUND_MAT_TERRAIN].UVScale
      else
        UVTable[0].InvUV := 0;
      UVTable[0].UVTransform := nil;
      UVTable[0].Bary.Valid  := False;
      TerrainSourceTag := 0;
      IntLayers := nil;
      IntLayerN := 0;
      UVCount    := 1;   { UVTable[0] (terrain) already occupies index 0 }
      SrcTris    := 0;
      TCap := Now;
      nPar := TThread.ProcessorCount;
      if nPar < 1  then nPar := 1;
      if nPar > 32 then nPar := 32;
      totA := InterlockedExchangeAdd(gBuildCarveThreads, nPar) + nPar;
      LogInfo(Format('  build threads: gen tid=%d capture +%d -> %d live (all gens)',
        [Int64(GetCurrentThreadID), nPar, totA]));

      for K := Low(TLanduseMeshKind) to High(TLanduseMeshKind) do
      begin
        MatId := GROUND_MAT_FOR_LANDUSE[K];
        if MatId = GROUND_MAT_NONE then Continue;
        { int-first: кольца полигонов от источника — слоем напрямую, мимо
          треугольного супа. В мешах на int-пути остаются только
          ориентированные UV-полигоны — их подхватывает мешевой захват
          ниже. Вода при кольцах мешем НЕ захватывается (меш — шейдерный
          шейп, кольца уже режут ложе). }
        if AInput.Landuse.IntRings[K].N > 0 then
        begin
          if IntLayerN >= Length(IntLayers) then
            SetLength(IntLayers, IntLayerN * 2 + 8);
          LayerFromBag(IntLayers[IntLayerN], AInput.Landuse.IntRings[K],
            MatId, GROUND_MATERIALS[MatId].ZIndex, iumPlanar,
            LanduseInvUVOf(MatId));
          Inc(IntLayerN);
        end;
        { Water is ALWAYS carved — it clips the terrain at the shoreline so
          no terrain pokes through. In shader-water mode the source mesh is
          kept (NOT cleared) so the assembler still emits the separate
          animated water shape on top of the carved basin. }
        if not ((K = lkWater)
                and (AInput.Landuse.IntRings[K].N > 0)) then
          CaptureLayer(AInput.Landuse.Items[K], MatId,
            TSurfaceTextures.GetDescriptor(Ord(K)).Stretch);
        { Stretch-виды ушли bary — их меш обязан жить до конца
          CarveGroundInt (см. CaptureLayer). Чистятся после карва. }
        if (AInput.Landuse.Items[K] <> nil)
           and not TSurfaceTextures.GetDescriptor(Ord(K)).Stretch then
          AInput.Landuse.Items[K].Clear;   { вода в композите -> отдельный меш не нужен ни в каком режиме }
      end;
      CaptureRoad(Roads.Railway,   rkRailway,   GROUND_MAT_ROAD_RAILWAY);
      CaptureRoad(Roads.DirtPath,  rkDirtPath,  GROUND_MAT_ROAD_DIRT);
      CaptureRoad(Roads.SandPath,  rkSandPath,  GROUND_MAT_ROAD_SAND);
      CaptureRoad(Roads.Footway,   rkFootway,   GROUND_MAT_ROAD_FOOTWAY);
      CaptureRoad(Roads.Cycleway,  rkCycleway,  GROUND_MAT_ROAD_CYCLEWAY);
      CaptureRoad(Roads.Service,   rkService,   GROUND_MAT_ROAD_SERVICE);
      CaptureRoad(Roads.Minor,     rkMinor,     GROUND_MAT_ROAD_MINOR);
      CaptureRoad(Roads.Secondary, rkSecondary, GROUND_MAT_ROAD_SECOND);
      CaptureRoad(Roads.Major,     rkMajor,     GROUND_MAT_ROAD_MAJOR);
      { River strips also always carved. In shader mode WaterRivers stays
        available (the assembler gates the separate animated shape on
        WaterShaders), so the carved basin gets the shader water on top. }
      if AWaterRings.N > 0 then
      begin
        if IntLayerN >= Length(IntLayers) then
          SetLength(IntLayers, IntLayerN * 2 + 8);
        LayerFromBag(IntLayers[IntLayerN], AWaterRings,
          GROUND_MAT_WATER, GROUND_MATERIALS[GROUND_MAT_WATER].ZIndex,
          iumPlanar, LanduseInvUVOf(GROUND_MAT_WATER));
        Inc(IntLayerN);
      end
      else
        CaptureLayer(AInput.WaterRivers, GROUND_MAT_WATER);

      { Основания домов: контур, расширенный на BUILDING_BASE_EXPAND_M и залитый
        pavement'ом — отмостка-«тротуар» вокруг здания. Int-путь: кольца от
        источника (ZIndex pavement=18 — поверх травы/тротуаров, под асфальтом),
        DrapeComposite сажает на рельеф. }
      begin
        { int-first: отмостки кольцами от источника (расширенные митровые
          контуры), мимо триангуляции и мешевого захвата }
        BasesBag.Rings := nil;
        BasesBag.N := 0;
        BasesMesh := BuildBuildingBasesMesh(AInput.BuildingShadowCasters,
          GROUND_MATERIALS[GROUND_MAT_PAVEMENT].UVScale, @BasesBag);
        BasesMesh.Free;                        { пуст на int-пути }
        if BasesBag.N > 0 then
        begin
          if IntLayerN >= Length(IntLayers) then
            SetLength(IntLayers, IntLayerN * 2 + 8);
          LayerFromBag(IntLayers[IntLayerN], BasesBag,
            GROUND_MAT_PAVEMENT,
            GROUND_MATERIALS[GROUND_MAT_PAVEMENT].ZIndex,
            iumPlanar, LanduseInvUVOf(GROUND_MAT_PAVEMENT));
          Inc(IntLayerN);
        end;
        { Нутро под зданиями: УЗЛОВАЯ МАСКА (float-стиль), не кольца —
          кольца футпринтов надробили ячеек по периметрам всех зданий
          больше, чем выбрасывало нутро (лог 10:02: +330k tris нетто).
          Маска не добавляет нодеру ни одного сегмента: ячейки, все 4
          узла которых внутри футпринта, просто не эмитятся; нутро
          остаётся крупными RQT-блоками и выбрасывается бесплатно. }
        { A ground-level architectural opening retains terrain and receives
          paving through the same non-overlapping ground carve. No floor mesh
          or Y offset: drape/road leveling and grass material filtering apply
          exactly as for ordinary ground. Mapped roads keep their priority;
          capturing after landuse wins the forest-floor tie at ZIndex 10. }
        BuildBuildingPassagePaving(AInput.BuildingShadowCasters,PassageBag);
        if PassageBag.N>0 then begin
          if IntLayerN>=Length(IntLayers) then
            SetLength(IntLayers,IntLayerN*2+8);
          LayerFromBag(IntLayers[IntLayerN],PassageBag,
            GROUND_MAT_PAVEMENT,BUILDING_PASSAGE_PAVING_ZINDEX,
            iumPlanar,LanduseInvUVOf(GROUND_MAT_PAVEMENT));
          Inc(IntLayerN);
        end;
        HoleMask := BuildHoleNodeMask(AInput.BuildingShadowCasters,
          Sampler, Projection);
      end;

      SetLength(UVTable, UVCount);
      LogInfo(Format('  carve: captured %d int layers from %d src tris in %.2f s',
        [IntLayerN, SrcTris, (Now - TCap) * 86400.0]));
      totA := InterlockedExchangeAdd(gBuildCarveThreads, -nPar) - nPar;
      LogInfo(Format('  build threads: gen tid=%d capture done -%d -> %d live',
        [Int64(GetCurrentThreadID), nPar, totA]));
      { Децимация земли: строим карту близости к дорогам -> поле уровней RQT,
        которое передаём в карв (PASS 1 укрупняет пустые ячейки). Опц. .pgm дамп
        карты для проверки. Без GlobalTerrainDecimate RoadLevel=nil -> старый путь. }
      RoadLevel := nil;
      { int-путь: RQT-укрупнение своё (решёточное, через border-таблицы),
        но узловое поле близости к дорогам — общее: держит мелкую сетку
        рядом с дорогами ради высотной детализации drape. }
      if GlobalTerrainDecimate and (Sampler <> nil)
         and (Length(AInput.RoadSegments) > 0) then
      begin
        RoadProx := BuildRoadProximityMap(AInput.RoadSegments, Sampler, Projection,
          GlobalTerrainDecimateKeepM, GlobalTerrainDecimateRangeM, ProxGX, ProxGZ);
        if Length(RoadProx) > 0 then
        begin
          if GlobalTerrainDecimateDebugPGM <> '' then
          begin
            SaveProximityPGM(RoadProx, ProxGX, ProxGZ, GlobalTerrainDecimateDebugPGM);
            LogInfo(Format('  decimate: road proximity %dx%d -> %s',
              [ProxGX, ProxGZ, GlobalTerrainDecimateDebugPGM]));
          end;
          RoadLevel := ProximityToLevelField(RoadProx, GlobalTerrainDecimateMaxLevel);
        end;
      end;

      TEmit := Now;
      totA := InterlockedExchangeAdd(gBuildCarveThreads, nPar) + nPar;
      LogInfo(Format('  build threads: gen tid=%d carve +%d -> %d live (all gens)',
        [Int64(GetCurrentThreadID), nPar, totA]));
      begin
        { стабильная сортировка слоёв по УБЫВАНИЮ ZIndex; при равных —
          позже захваченный ВЫШЕ (later wins, как у float-CarveCell) }
        SetLength(IntLayers, IntLayerN);
        for ili := 1 to IntLayerN - 1 do
        begin
          IntTmpL := IntLayers[ili];
          ilj := ili - 1;
          while (ilj >= 0) and (IntLayers[ilj].ZIndex <= IntTmpL.ZIndex) do
          begin
            IntLayers[ilj + 1] := IntLayers[ilj];
            Dec(ilj);
          end;
          IntLayers[ilj + 1] := IntTmpL;
        end;
        if GlobalTerrainDecimate then
          ili := GlobalTerrainDecimateMaxLevel
        else
          ili := 0;
        if (ili > 0) and (RoadLevel <> nil)
           and (Length(RoadLevel) <> Sampler.Grid.NX * Sampler.Grid.NZ) then
          LogInfo(Format('  decimate: RoadLevel size %d != grid %dx%d — кап у дорог не действует!',
            [Length(RoadLevel), Sampler.Grid.NX, Sampler.Grid.NZ]));
        GenerationProgress('Ground surfaces', 0, 0);
        CarveGroundInt(Sampler.Grid, Projection, IntLayers,
          GROUND_MAT_TERRAIN, UVTable[0].InvUV, GEO_TILE_EDGE_PX,
          OutMeshes, IntStats, nPar,
          RoadLevel, ili, HoleMask, Sampler);
        { bary-меши stretch-видов больше не нужны — снять отложенную
          очистку (см. захват выше), чтобы ассемблер не задвоил их
          отдельными плоскими шейпами. }
        for K := Low(TLanduseMeshKind) to High(TLanduseMeshKind) do
          if TSurfaceTextures.GetDescriptor(Ord(K)).Stretch
             and (AInput.Landuse.Items[K] <> nil) then
            AInput.Landuse.Items[K].Clear;
        FillChar(Prof, SizeOf(Prof), 0);
        Prof.TotalCells := IntStats.Cells;
        Prof.EmptyCells := IntStats.EmptyCells;
        Prof.TotalTris  := IntStats.TrisOut;
        Prof.TotalVerts := IntStats.VertsOut;
        LogInfo(Format('  int-carve: layers=%d rings=%d segs=%d cells=%d ' +
          '(empty=%d) tris=%d dictVerts=%d in %d ms',
          [IntLayerN, IntStats.RingsNoded, IntStats.SegsNoded,
           IntStats.Cells, IntStats.EmptyCells, IntStats.TrisOut,
           IntStats.VertsOut, IntStats.Ms]));
        { ОТЛАДКА «дротиков»: дамп колец слоёв + выходных треугольников
          вокруг точки со скрина. Пишет файл только на попавшем чанке. }
        CarveDbgFN := DumpCarveDebugAt(IntLayers, IntLayerN, OutMeshes, Projection);
        if CarveDbgFN <> '' then
          LogInfo('  carve-debug: ' + CarveDbgFN);
        if IntStats.Fail <> '' then
          LogInfo('  int-carve FAIL: ' + IntStats.Fail);
        if IntStats.Warn <> '' then
          LogInfo('  int-carve WARN: ' + IntStats.Warn);
        if IntStats.DecimBlocks > 0 then
          LogInfo(Format('  int-carve decim: blocks=%d coarseCells=%d (of %d)',
            [IntStats.DecimBlocks, IntStats.DecimCoarseCells, IntStats.Cells]));
        if IntStats.DecimHeightRejected > 0 then
          LogInfo(Format('  int-carve decim: %d merges rejected by terrain height error',
            [IntStats.DecimHeightRejected]));
        if IntStats.HoleTris > 0 then
          LogInfo(Format('  int-carve hole: %d tris нутра под зданиями выброшено (маской, без дробления)',
            [IntStats.HoleTris]));
      end;
      LogInfo(Format('  carve: emitted %d material meshes in %.2f s',
        [Length(OutMeshes), (Now - TEmit) * 86400.0]));
      totA := InterlockedExchangeAdd(gBuildCarveThreads, -nPar) - nPar;
      LogInfo(Format('  build threads: gen tid=%d carve done -%d -> %d live',
        [Int64(GetCurrentThreadID), nPar, totA]));
      if (GenerationProgressContext.Cancel <> nil) and
         GenerationProgressContext.Cancel^ then
      begin
        for qi := 0 to High(OutMeshes) do
          FreeAndNil(OutMeshes[qi].Mesh);
        Exit;  { CBuilder is released by finally; caller observes cancellation. }
      end;
      LogInfo(Format('  carve cells: total=%d empty=%d carved=%d pieces=%d  ' +
        'verts=%d (terrain=%d p1empty=%d) tris=%d',
        [Prof.TotalCells, Prof.EmptyCells, Prof.CarvedCells, Prof.CarvedPieces,
         Prof.TotalVerts, Prof.TerrainVerts, Prof.EmptyGridVerts, Prof.TotalTris]));
      { разбивка по материалам: что весит в карв-выводе (>50k верт) }
      for mi := 0 to High(OutMeshes) do
        if (OutMeshes[mi].Mesh <> nil) and (OutMeshes[mi].Mesh.VertexCount > 50000) then
          LogInfo(Format('  carve mat[%d]: verts=%d tris=%d',
            [OutMeshes[mi].MatId, OutMeshes[mi].Mesh.VertexCount,
             OutMeshes[mi].Mesh.TriangleCount]));
      { single-fill: ячейки, целиком покрытые одним материалом — кандидаты на
        общий грид земли (вместо несвязанной пер-кусочной вырезки в карве) }
      if Prof.SingleFillCells > 0 then
      begin
        denC := Prof.CarvedCells; if denC < 1 then denC := 1;
        LogInfo(Format('  carve singlefill: cells=%d (of carved=%d, %.1f%%)',
          [Prof.SingleFillCells, Prof.CarvedCells, Prof.SingleFillCells * 100.0 / denC]));
        for sfi := 0 to 63 do
          if Prof.SingleFillByMat[sfi] > 5000 then
            LogInfo(Format('    singlefill mat[%d]: cells=%d', [sfi, Prof.SingleFillByMat[sfi]]));
      end;
      if Prof.SharedLanduseCells > 0 then
        LogInfo(Format('  carve shared-landuse: cells=%d (децимированы вместе с землёй)',
          [Prof.SharedLanduseCells]));
      if GlobalTerrainDecimate then
        LogInfo(Format('  decimate: active=%s levelCells=%d coarseBlocks=%d ' +
          'coarseCells=%d tallyCoarse=%d tallyL0=%d (empty=%d)',
          [BoolToStr(Prof.DecimActive, True), Length(RoadLevel),
           Prof.DecimCoarseBlocks, Prof.DecimCoarseCells,
           Prof.DecimTallyCoarse, Prof.DecimTallyL0, Prof.EmptyCells]));
      LogInfo(Format('  carve ms: nodeNorms=%.0f sort=%.0f loadCorners=%.0f ' +
        'emptyEmit=%.0f carveCell=%.0f pieceEmit=%.0f',
        [Prof.MsNodeNorms, Prof.MsSort, Prof.MsLoadCorners,
         Prof.MsEmptyEmit, Prof.MsCarveCell, Prof.MsPieceEmit]));
      LogInfo(Format('  carve diag: dcCalls=%d aabbReject=%d itemPeel=%d ' +
        'terrPeel=%d cellsCovered=%d capHits=%d',
        [Prof.DCCalls, Prof.DCAABBReject, Prof.ItemPeel,
         Prof.TerrPeel, Prof.CellsCovered, Prof.CapHits]));
      LogInfo(Format('  carve peels: itemSame=%d itemDiff=%d fullCoverSame=%d',
        [Prof.ItemPeelSame, Prof.ItemPeelDiff, Prof.FullCoverSame]));
      tStep := GetTickCount64;
      { weld: int-путь — одна полоса (канонические позиции, щелей между
        полосами не бывает по построению), пул через точную int-карту. }
      { Pre-trim every mesh's Vertices/Indices on THIS thread: GetVertices/
        GetIndices lazily SetLength on first access, which would race if the
        strip workers triggered it concurrently on a shared mesh. After this
        the workers' .Vertices/.Indices calls are pure reads. (Z range for the
        strips is taken from the tile frame below, not scanned here.) }
      for qi := 0 to High(OutMeshes) do
      begin
        WSrcV := OutMeshes[qi].Mesh.Vertices;   { force trim (reads) }
        WSrcI := OutMeshes[qi].Mesh.Indices;
        if WSrcI = nil then ;                    { silence "unused" }
        if WSrcV = nil then ;                    { silence "unused" }
      end;
      { Z-диапазон полос — из РАМКИ тайла (периметр узлов решётки), а не
        пересканом ~2M вершин. Карв всегда заполняет весь тайл (пустые ячейки
        дают полноячеечный остаток террейна), поэтому Z-габарит геометрии по
        построению совпадает с Z-габаритом рамки — баланс полос сохраняется.
        Точность нужна ТОЛЬКО для баланса: края полос ±1e30, покрытие Z полное
        при любом [zMin,zMax], поэтому даже грубая оценка корректна. O(NX+NZ)
        вместо O(вершин). Проекция может быть повёрнута => world-Z не монотонен
        по индексу iz, поэтому обходим весь периметр, а не только 4 угла. }
      zMin :=  1e30; zMax := -1e30;
      if Sampler <> nil then
      begin
        gnx := Sampler.GridX; gnz := Sampler.GridZ;
        for vi := 0 to gnx - 1 do
        begin
          if Sampler.NodePositionXZ(vi, 0, pxq, pzq) then
          begin
            if pzq < zMin then zMin := pzq;
            if pzq > zMax then zMax := pzq;
          end;
          if Sampler.NodePositionXZ(vi, gnz - 1, pxq, pzq) then
          begin
            if pzq < zMin then zMin := pzq;
            if pzq > zMax then zMax := pzq;
          end;
        end;
        for vi := 0 to gnz - 1 do
        begin
          if Sampler.NodePositionXZ(0, vi, pxq, pzq) then
          begin
            if pzq < zMin then zMin := pzq;
            if pzq > zMax then zMax := pzq;
          end;
          if Sampler.NodePositionXZ(gnx - 1, vi, pxq, pzq) then
          begin
            if pzq < zMin then zMin := pzq;
            if pzq > zMax then zMax := pzq;
          end;
        end;
      end;

      nStrips := TThread.ProcessorCount;
      if nStrips < 1  then nStrips := 1;
      if nStrips > 16 then nStrips := 16;
      if zMax <= zMin then nStrips := 1;   { degenerate / empty -> one strip }
      { параллельный int-weld: полосы по Z; вершины на стыках полос
        дублируются пер-полосными пулами и сводятся ПОСЛЕ конката точной
        int-склейкой WeldPoolExactLat (канонические позиции решётки —
        стык бит-в-бит, стежок не нужен) }
      if nStrips > 8 then nStrips := 8;

      SetLength(WeldCtx.Bounds, nStrips + 1);
      WeldCtx.Bounds[0]       := -1e30;
      WeldCtx.Bounds[nStrips] :=  1e30;
      for vi := 1 to nStrips - 1 do
        WeldCtx.Bounds[vi] := zMin + (zMax - zMin) * vi / nStrips;
      SetLength(WeldCtx.SubComp, nStrips);
      for vi := 0 to nStrips - 1 do WeldCtx.SubComp[vi] := nil;
      WeldCtx.OutMeshes    := OutMeshes;
      WeldCtx.WaterShaders := FSettings.WaterShaders;

      totA := InterlockedExchangeAdd(gBuildCarveThreads, nStrips) + nStrips;
      LogInfo(Format('  build threads: gen tid=%d weld +%d -> %d live (all gens)',
        [Int64(GetCurrentThreadID), nStrips, totA]));
      GenerationParallelFor('Welding surfaces', nStrips, @WeldStripRange, @WeldCtx, 1);
      totA := InterlockedExchangeAdd(gBuildCarveThreads, -nStrips) - nStrips;
      LogInfo(Format('  build threads: gen tid=%d weld done -%d -> %d live',
        [Int64(GetCurrentThreadID), nStrips, totA]));

      { serial concat of the per-strip sub-composites (raw, no re-weld) }
      Composite := TGroundCompositeMesh.Create('ground_composite');
      MergeVertices:=0;MergeTriangles:=0;MergePool:=0;
      for vi:=0 to nStrips-1 do
        if WeldCtx.SubComp[vi]<>nil then begin
          Inc(MergeVertices,WeldCtx.SubComp[vi].VertexCount);
          Inc(MergeTriangles,WeldCtx.SubComp[vi].TriangleCount);
          Inc(MergePool,WeldCtx.SubComp[vi].Pool.Count);
        end;
      Composite.ReserveForRawMerge(MergeVertices,MergeTriangles,MergePool);
      for vi := 0 to nStrips - 1 do
        if WeldCtx.SubComp[vi] <> nil then
        begin
          Composite.AppendRawComposite(WeldCtx.SubComp[vi]);
          WeldCtx.SubComp[vi].Free;
        end;
      Composite.WeldPoolExactLat;    { стыки полос: дубли пула -> канон }
      Composite.TrimArrays;

      for qi := 0 to High(OutMeshes) do OutMeshes[qi].Mesh.Free;
      msWeld := Int64(GetTickCount64 - tStep);
      msFinalize := 0;
    end
    else
    begin
      tStep := GetTickCount64;
      Composite := CBuilder.Finalize(FLogProc);
      msFinalize := Int64(GetTickCount64 - tStep);
    end;
  finally
    CBuilder.Free;
  end;

  { Road cross-slope leveling. Meaningful on the carved path (the composite
    then contains road surfaces welded to the terrain at their edges); the
    welded pool makes the adjacent ground follow each moved road edge. }
  Lg := @Self.LogInfo;   { real builder log; FLogProc is nil in the streaming build path }
  if (Composite <> nil)
     and (Sampler <> nil) and (Projection <> nil) then
  begin
    tStep := GetTickCount64;
    DrapeComposite(Composite, Sampler, Projection);   { flat carve → terrain height }
    msDrape := Int64(GetTickCount64 - tStep);

    if AUDIT_GROUND_COMPOSITE then
      AuditGroundComposite(Composite, 'pre-level', Lg);

    tStep := GetTickCount64;
    if LEVEL_ROADS_ENABLED then
      LeveledNorm := LevelRoadsInComposite(Composite, AInput.RoadSegments,
                            ATunnelRamps, AFences, Sampler, Projection, Self.FitLayer,
                            Self.FDeckJoints, Lg)
    else
    begin
      LeveledNorm := False;   { → SmoothCompositeNormals пересчитает нормали рельефа }
      Lg('  LevelRoadsInComposite ПРОПУЩЕН (LEVEL_ROADS_ENABLED=False)');
    end;
    msLevel := Int64(GetTickCount64 - tStep);

    { Диагностика высот полотна в отдельный ген-лог (osm3d_gen_<stamp>.log) —
      данные для разбора дефектов (пиков) геометрии дороги. }
    DumpFitRoadDiag(AInput.RoadSegments, Sampler, Projection,
                    Self.FitLayer, FSettings, FChunk.Box);

    { Last: shade the ground as a smooth surface (normals only). Нормали уже
      пересчитаны ВНУТРИ LevelRoadsInComposite по выровненной поверхности
      (рельеф+дороги — одна функция высоты и нормали); чистый сэмплерный
      градиент — только фолбэк, когда выравнивание не отработало (нет дорог). }
    tStep := GetTickCount64;
    if not LeveledNorm then
      SmoothCompositeNormals(Composite, Sampler, Projection);
    msSmooth := Int64(GetTickCount64 - tStep);

    if AUDIT_GROUND_COMPOSITE then
      AuditGroundComposite(Composite, 'post-fix', Lg);

    { One line, all steps. weld = parallel strip weld + serial concat (finalize
      folded in, =0); drape/level/smooth parallel; stitch/tjunction serial. }
    LogInfo(Format('  composite steps ms: weld=%d finalize=%d drape=%d ' +
      'level=%d smooth=%d',
      [msWeld, msFinalize, msDrape, msLevel, msSmooth]));
  end;

  AInput.GroundComposite := Composite;
  AInput.GroundAtlas     := nil;
  AInput.AttachGroundShader := FSettings.UseGroundCompositionShader;
  AInput.AttachGroundMaterialIdAttribute := FSettings.UseGroundCompositionMaterialIdAttribute;
end;

procedure TGeometryBuilder.BuildRoadDistFieldBounds(
  const AInput: TSceneInput; Field: TRoadDistField);
{ Empty / nil composite → 100 m × 100 m default centred at origin
  (Build is a no-op anyway when no segments). }
var
  N, I: Integer;
  P: TVector3;
  MinX, MinZ, MaxX, MaxZ: Single;
  HaveBox: Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(155);{$ENDIF}
  if Field = nil then Exit;
  HaveBox := False;
  MinX := 0; MinZ := 0; MaxX := 0; MaxZ := 0;

  if (AInput.GroundComposite <> nil) and
     (AInput.GroundComposite.VertexCount > 0) then
  begin
    N := AInput.GroundComposite.VertexCount;
    for I := 0 to N - 1 do
    begin
      P := AInput.GroundComposite.PositionOf(I);
      if not HaveBox then
      begin
        MinX := P.X; MaxX := P.X;
        MinZ := P.Z; MaxZ := P.Z;
        HaveBox := True;
      end
      else
      begin
        if P.X < MinX then MinX := P.X
        else if P.X > MaxX then MaxX := P.X;
        if P.Z < MinZ then MinZ := P.Z
        else if P.Z > MaxZ then MaxZ := P.Z;
      end;
    end;
  end;

  if not HaveBox then
  begin
    MinX := -50; MaxX := 50;
    MinZ := -50; MaxZ := 50;
  end;

  Field.SetWorldBounds(MinX, MinZ, MaxX, MaxZ);
end;

type
  { Параллельная фаза билдеров: ландюз/деревья/вода/здания/заборы/таблички
    независимы по данным (читают Dataset/Heightmap/Sampler read-only; сэмплер
    прогрет PrecomputeNodePositions до секции, SampleAt чистый, лог с локом).
    Сумма последовательных времён превращается в максимум одной задачи. }
  TLanduseMeshesPtr = ^TLanduseMeshes;
  TBuildingShadowCastersPtr = ^TBuildingShadowCasters;
  TLatRingBagPtr = ^TLatRingBag;

  TBuildersCtx = record
    Dataset: TOSMDataset;
    HM: THeightmap;
    Proj: TLocalProjection;
    Sampler: TTerrainSampler;
    RoadIdx: TOsmRoadIndex;   { общий индекс дорог блока (может быть nil) }
    Corridor: TRouteCorridor; { route-only: поэлементный фильтр забора/растит. по полосе (nil = весь блок) }
    Log: TLogProc;
    GenTrees, GenBuildings, GenFences, GenPlates: Boolean;
    PLanduse: TLanduseMeshesPtr;
    PTrees: ^TForestBuildResult;
    PWater: ^TMesh;
    PWaterRings: TLatRingBagPtr;
    PBuildings: ^TBuildingMeshes;
    PCasters: TBuildingShadowCastersPtr;
    PFences: ^TFenceMeshes;
    PPlates: ^TMesh;
    PPlateAnchors: ^TPlateTileAnchorArray;
  end;
  PBuildersCtx = ^TBuildersCtx;

procedure RunBuildersRange(Ctx: Pointer; A, B: Integer);
const
  { имена задач для лога — индекс i совпадает с case ниже }
  BUILDER_NAME: array[0..5] of string =
    ('landuse', 'trees', 'water', 'buildings', 'fences', 'plates');
var
  C: PBuildersCtx;
  i: Integer;
  PltAtlas: TPlateGlyphAtlas;
  TTask: QWord;                    { старт замера текущей задачи }
begin
  C := PBuildersCtx(Ctx);
  for i := A to B - 1 do
  begin
    if (GenerationProgressContext.Cancel <> nil) and
       GenerationProgressContext.Cancel^ then Exit;
    TTask := GetTickCount64;
    case i of
      0: { ландюз }
        if (C^.Dataset <> nil) and (C^.HM <> nil) then
        try
          C^.PLanduse^ := TLanduseBuilder.BuildAll(
            C^.Dataset, C^.HM, C^.Proj,
            LanduseUVScalesFromMaterials,
            C^.Sampler, C^.Log, True, True);
        except
          on E: Exception do
            C^.Log(Format('Landuse build FAILED: %s: %s',
              [E.ClassName, E.Message]));
        end
        else C^.Log('Skipping landuse (no dataset or heightmap)');
      1: { деревья }
        if (C^.Dataset <> nil) and (C^.HM <> nil) and C^.GenTrees then
        try
          C^.PTrees^ := TForestInstanceBuilder.BuildAllDefaults(
            C^.Dataset, C^.HM, C^.Proj, C^.Sampler, C^.Log);
        except
          on E: Exception do
            C^.Log(Format('Tree pipeline FAILED: %s: %s',
              [E.ClassName, E.Message]));
        end
        else C^.Log('Skipping trees (no dataset / heightmap / disabled)');
      2: { реки }
        if (C^.Dataset <> nil) and (C^.HM <> nil) then
        try
          C^.PWater^ := TWaterBuilder.BuildAll(
            C^.Dataset, C^.HM, C^.Proj, C^.Sampler, C^.Log,
            C^.PWaterRings);
        except
          on E: Exception do
            C^.Log(Format('Water rivers build FAILED: %s: %s',
              [E.ClassName, E.Message]));
        end
        else C^.Log('Skipping water rivers (no dataset or heightmap)');
      3: { здания }
        if (C^.Dataset <> nil) and C^.GenBuildings then
        try
          { шардированный параллельный билд: категория buildings была
            крупнейшим однопоточным куском ген-фазы (см. [gen-cat]) }
          C^.PBuildings^ := TBuildingBuilderExt.BuildAllParallel(
            C^.Dataset, C^.HM, C^.Proj,
            C^.PCasters^,
            C^.Sampler, C^.Log);
        except
          on E: Exception do
            C^.Log(Format('Buildings build FAILED: %s: %s',
              [E.ClassName, E.Message]));
        end
        else C^.Log('Skipping buildings (disabled or no dataset)');
      4: { заборы }
        if (C^.Dataset <> nil) and C^.GenFences then
        try
          { шардированный параллельный билд: заборы были крупнейшей
            оставшейся однопоточной категорией ген-фазы (см. [gen-cat]) }
          C^.PFences^ := TFenceBuilder.BuildAllParallel(
            C^.Dataset, C^.HM, C^.Proj, C^.Sampler, C^.Log, 4, C^.Corridor);
        except
          on E: Exception do
            C^.Log(Format('Fences build FAILED: %s: %s',
              [E.ClassName, E.Message]));
        end
        else C^.Log('Skipping fences (disabled or no dataset)');
      5: { таблички }
        if (C^.Dataset <> nil) and C^.GenPlates then
        try
          PltAtlas := TPlateGlyphAtlas.Create;
          try
            C^.PPlates^ := TPlateBuilder.BuildAll(
              C^.Dataset, C^.HM, C^.Proj,
              PltAtlas, C^.PPlateAnchors^, C^.Sampler, C^.Log,
              C^.RoadIdx);
          finally
            PltAtlas.Free;
          end;
        except
          on E: Exception do
            C^.Log(Format('Plates build FAILED: %s: %s',
              [E.ClassName, E.Message]));
        end
        else C^.Log('Skipping plates (disabled or no dataset)');
    end;
    { длительность задачи: видно, какая категория доминирует в max() —
      именно она определяет невидимый простой на «Gen 99%». tid — чтобы
      различать воркеры пула. }
    if Assigned(C^.Log) then
      C^.Log(Format('  [gen-cat] %-9s tid=%d  %d ms',
        [BUILDER_NAME[i], Int64(GetCurrentThreadID),
         GetTickCount64 - TTask]));
  end;
end;

{ Route-only: поэлементный фильтр деревьев/кустов по коридору — выкидываем ТОЛЬКО
  инстансы, чья позиция вне полосы (не весь лесной полигон: он может задевать
  коридор краем, а деревья рассажены по всей его площади). Компакт-сдвиг на
  месте; возвращает число удалённых. Зеркалит FilterTreesByRoadCandidates из
  Osm3dGeomVegetation, но по коридору вместо дорог. }
function FilterTreeInstancesByCorridor(var Arr: TTreeInstanceArray;
  ACorridor: TRouteCorridor): Integer;
var Src, Dst: Integer;
begin
  Result := 0;
  if (Length(Arr) = 0) or (ACorridor = nil) then Exit;
  Dst := 0;
  for Src := 0 to High(Arr) do
    if ACorridor.Contains(Arr[Src].X, Arr[Src].Z) then
    begin
      if Dst <> Src then Arr[Dst] := Arr[Src];
      Inc(Dst);
    end
    else
      Inc(Result);
  SetLength(Arr, Dst);
end;

{ Route-only: пересобрать земляной композит, оставив ТОЛЬКО треугольники, у
  которых хотя бы одна вершина в коридоре маршрута. Через публичный append-API
  композита — реально УМЕНЬШАЕТ буфер (не вырожденные треугольники), поэтому
  тайл в отдельном кэше содержит землю только вдоль пути. Кадр локальный —
  тот же, что у вершин композита (Projection.Project с origin блока). }
procedure ClipCompositeToCorridor(var AComposite: TGroundCompositeMesh;
  ACorridor: TRouteCorridor; ALog: TLogProc);
var
  Old, NewC: TGroundCompositeMesh;
  IdxRef: TMeshIndexArray;
  t, tc, i0, i1, i2, ni0, ni1, ni2, kept: Integer;
  P0, P1, P2: TVector3;

  function AppV(vi: Integer): Integer;
  var V: TMeshVertex;
  begin
    { управляемых полей у вершины нет; FPC инициализирует их (если есть) в nil,
      а неиспользуемые value-поля AppendVertex не читает. }
    V.Position := Old.PositionOf(vi);
    V.Normal   := Old.NormalOf(vi);
    V.UV       := Old.UVOf(vi);
    V.OsmId    := Old.OsmIdOf(vi);
    Result := NewC.AppendVertex(V, Old.MatIdOf(vi));
  end;

begin
  if (AComposite = nil) or (ACorridor = nil) then Exit;
  Old := AComposite;
  tc  := Old.TriangleCount;
  if tc = 0 then Exit;

  NewC := TGroundCompositeMesh.Create('ground_composite', -1.0);
  try
    NewC.ReserveForSlice(Old.VertexCount, tc);
    IdxRef := Old.Indices;
    kept := 0;
    for t := 0 to tc - 1 do
    begin
      i0 := Integer(IdxRef[t * 3]);
      i1 := Integer(IdxRef[t * 3 + 1]);
      i2 := Integer(IdxRef[t * 3 + 2]);
      P0 := Old.PositionOf(i0);
      P1 := Old.PositionOf(i1);
      P2 := Old.PositionOf(i2);
      if ACorridor.Contains(P0.X, P0.Z)
         or ACorridor.Contains(P1.X, P1.Z)
         or ACorridor.Contains(P2.X, P2.Z) then
      begin
        ni0 := AppV(i0);  ni1 := AppV(i1);  ni2 := AppV(i2);
        NewC.AppendTriangle(ni0, ni1, ni2, Old.TriTileKeyOf(t));
        Inc(kept);
      end;
    end;
    NewC.TrimArrays;
  except
    NewC.Free;
    raise;
  end;

  if Assigned(ALog) then
    ALog(Format('  route-only: composite clipped %d -> %d tris (corridor)',
      [tc, kept]));
  AComposite.Free;
  AComposite := NewC;
end;

function TGeometryBuilder.Build(out AInput: TSceneInput;
  out ATrees: TForestBuildResult): Boolean;
var
  MeshesPublished: Boolean;
  TPhase:        QWord;              { старт замера крупной фазы Build }
  Proj:          TLocalProjection;
  LatProj:       TLatticeProjection; { int-first: e7 → мировая решётка 1/64 м }
  LatAnchor:     TLatLon;
  RoadIdx:       TOsmRoadIndex;      { единый индекс дорог блока }
  TerrainSampler: TTerrainSampler;
  WaterLevels: TWaterLevelField;
  BridgeMask:    TBridgeSpanMask;    { пролёты OSM-мостов: под ними земля по DEM }
  TerrainGridX, TerrainGridZ: Integer;
  WaterRivers:   TMesh;
  WaterRiverRings: TLatRingBag;      { int-first: кольца речных лент }
  Roads:         TRoadMeshes;
  RoadSegs:      TRoadCenterlineSegArray;
  CrossingStats: TCrossingStats;
  SurfaceQuery: TGroundSurfaceQuery;
  BridgeSpecs:   TBridgeSpecArray;
  TunnelSpecs:   TBridgeSpecArray;   { общая с мостами запись (Osm3dGeomTunnels) }
  TunnelRamps:   TTunnelApproachSegArray;   { подходные траншеи туннелей → выравнивание }
  TunnelPortalTerr: TSingleArray;    { рельеф у торцов туннелей → оголовки/козырьки }
  Buildings:     TBuildingMeshes;
  Fences:        TFenceMeshes;
  FencePaletteI: Integer;
  RemTrees, RemShrubs: Integer;   { route-only: сколько инстансов вне коридора отсечено }
  Plates:        TMesh;
  PlateAnchors:  TPlateTileAnchorArray;
  BCtx:          TBuildersCtx;
  RiverSigns:    TRiverSignArray;
  RsAtlas:       TPlateGlyphAtlas;
  rsCount, rsMade, bi, cN: Integer;
  rdx, rdz, rdl: Single;
  jointN:        Integer;            { заполнено якорей стыков FIT-мостов }
  PaletteI:      Integer;
  TotalWalls, TotalRoofs: Integer;
  K:             TLanduseMeshKind;
  T0:            TDateTime;


  { Always publish partial results as well: the caller owns and frees
    TSceneInput when cancellation or another exception stops this build. }
  procedure PublishOwnedMeshes;
  var
    RKf: TRoadKind;
    PaletteI, FencePaletteI: Integer;
  begin
    if MeshesPublished then Exit;
    AInput.WaterRivers    := WaterRivers;
    AInput.RoadMajor      := Roads.Major;
    AInput.RoadSecondary  := Roads.Secondary;
    AInput.RoadMinor      := Roads.Minor;
    AInput.RoadService    := Roads.Service;
    AInput.RoadFootway    := Roads.Footway;
    AInput.RoadCycleway   := Roads.Cycleway;
    AInput.RoadRailway    := Roads.Railway;
    AInput.RoadDirtPath   := Roads.DirtPath;
    AInput.RoadSandPath   := Roads.SandPath;
    { UV-меши int-карва дорог отслужили (bary-lookup жил внутри
      BuildGroundComposite); кольца — динмассивы, умирают с записью.
      Сами меши дорог переданы во владение AInput выше. }
    for RKf := Low(TRoadKind) to High(TRoadKind) do
      FreeAndNil(Roads.UVMesh[RKf]);
    for PaletteI := 0 to BUILDING_PALETTE_SIZE - 1 do
    begin
      AInput.BuildingWalls[PaletteI] := Buildings.Walls[PaletteI];
      AInput.BuildingRoofs[PaletteI] := Buildings.Roofs[PaletteI];
    end;
    { Anchor table — required for the tiled assembler to keep each
      building whole inside one tile (walls + roofs in the same cell,
      tile picked from the footprint centroid). Built by
      TBuildingBuilderExt.BuildAll alongside the wall/roof meshes. }
    AInput.BuildingTileAnchors := Buildings.TileAnchors;

    { Fences — same anchor-based tiling as buildings. nil meshes when
      GenerateFences is off; the assembler tolerates that (no composite). }
    for FencePaletteI := 0 to FENCE_PALETTE_SIZE - 1 do
      AInput.Fences[FencePaletteI] := Fences.Fences[FencePaletteI];
    AInput.FenceTileAnchors := Fences.TileAnchors;

    { Plates — single global mesh + per-building anchors (nil when off). }
    AInput.Plates           := Plates;
    AInput.PlateTileAnchors := PlateAnchors;
    MeshesPublished := True;
  end;

  { Один якорь стыка настила с дорогой: торец AEndIdx (внутренний сосед
    AInnerIdx задаёт направление наружу), высота — кромка настила там же.
    Пишет в FDeckJoints[AN], двигает AN. Вырожденное направление — пропуск. }
  procedure PushDeckJoint(const ASpec: TBridgeSpec;
    AEndIdx, AInnerIdx: Integer; var AN: Integer);
  var
    ddx, ddz, dl: Double;
  begin
    ddx := ASpec.Center[AEndIdx].X - ASpec.Center[AInnerIdx].X;
    ddz := ASpec.Center[AEndIdx].Z - ASpec.Center[AInnerIdx].Z;
    dl := Sqrt(ddx*ddx + ddz*ddz);
    if dl < 1e-9 then Exit;
    FDeckJoints[AN].JX    := Single(ASpec.Center[AEndIdx].X);
    FDeckJoints[AN].JZ    := Single(ASpec.Center[AEndIdx].Z);
    FDeckJoints[AN].DirX  := Single(ddx / dl);
    FDeckJoints[AN].DirZ  := Single(ddz / dl);
    FDeckJoints[AN].HalfW := ASpec.Width * 0.5;
    FDeckJoints[AN].H     := ASpec.CenterY[AEndIdx];
    Inc(AN);
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(156);{$ENDIF}
  Result := False;
  if FChunk = nil then
  begin
    LogError('TGeometryBuilder.Build: Chunk = nil, nothing to build');
    Exit;
  end;

  FillChar(AInput,  SizeOf(AInput),  0);
  FillChar(ATrees,  SizeOf(ATrees),  0);
  FTotalVerts := 0;
  FTotalTris  := 0;
  T0    := Now;
  FTStep := T0;

  LogInfo('────────────────────────────────────────');
  LogInfo('GeometryBuilder: starting geometry build');
  LogInfo(Format('  origin: lat=%.6f lon=%.6f',
    [FChunk.Origin.Lat, FChunk.Origin.Lon]));
  LogInfo(Format('  bbox:   lat[%.5f..%.5f] lon[%.5f..%.5f]',
    [FChunk.Box.MinLat, FChunk.Box.MaxLat,
     FChunk.Box.MinLon, FChunk.Box.MaxLon]));
  LogInfo(Format('  heightmap: %s, dataset: %s',
    [BoolToStr(FChunk.Heightmap <> nil, 'present', 'none'),
     BoolToStr(FChunk.Dataset   <> nil, 'present', 'none')]));
  if FChunk.Dataset <> nil then
    LogInfo('  dataset stats: ' + FChunk.Dataset.StatsString);
  LogInfo(Format('  flags: buildings=%s, roads=%s, trees=%s, grid=%.2f m',
    [BoolToStr(FSettings.GenerateBuildings, True),
     BoolToStr(FSettings.GenerateRoads,     True),
     BoolToStr(FSettings.GenerateTrees,     True),
     FSettings.TerrainGridStepMeters]));

  MeshesPublished := False;
  Roads := Default(TRoadMeshes);
  Buildings := Default(TBuildingMeshes);
  Fences := Default(TFenceMeshes);
  WaterRivers := nil;
  Plates := nil;
  PlateAnchors := nil;
  RoadIdx := nil;   { до try: finally делает FreeAndNil, мусор недопустим }
  TerrainSampler := nil;
  WaterLevels := nil;
  Proj := TLocalProjection.Create(FChunk.Origin, FChunk.ScaleLat);
  try
    CheckGenerationCancelled;
    { ── int-first: пер-узловой кэш мировой решётки 1/64 м ─────────────
      Якорь — origin СЕССИИ: один OSM-узел в halo разных блоков получает
      решёточные координаты, отличающиеся ровно на целый сдвиг блока,
      т.е. плановая геометрия потребителей (здания и далее по миграции)
      совпадает ПОБИТНО между блоками. Масштабы берём из Proj — побитовое
      согласие метрики двух миров. Fallback на Origin блока (легаси-хост
      без SessionOrigin) сохраняет детерминизм внутри блока. }
    if FChunk.Dataset <> nil then
    begin
      LatAnchor := FChunk.SessionOrigin;
      if (LatAnchor.Lat = 0) and (LatAnchor.Lon = 0) then
        LatAnchor := FChunk.Origin;
      LatProj := TLatticeProjection.Create(
        DegToE7(LatAnchor.Lat), DegToE7(LatAnchor.Lon),
        Proj.MetersPerDegreeLat, Proj.MetersPerDegreeLon);
      try
        FChunk.Dataset.PrecomputeLattice(LatProj,
          LatProj.XOfLonE7(DegToE7(FChunk.Origin.Lon)),
          LatProj.ZOfLatE7(DegToE7(FChunk.Origin.Lat)));
      finally
        LatProj.Free;
      end;
      LogInfo('  + node lattice cached (int-first, якорь сессии)');
    end;

    { ── единый пер-блочный индекс дорог (Osm3dOsmIndex) ────────────────
      Строится ОДИН раз, read-only для всех потребителей: остановки
      (таблички + модели POI) и мосты (adjacency вместо полного скана
      ways × ParseRoadParams на каждый конец моста). }
    if FChunk.Dataset <> nil then
    begin
      TPhase := GetTickCount64;
      RoadIdx := TOsmRoadIndex.Build(FChunk.Dataset, Proj);
      LogInfo(Format('  + road index: %d vehicular segs, %d poi stops (%d ms)',
        [RoadIdx.VehicularSegCount, RoadIdx.PoiStopCount,
         GetTickCount64 - TPhase]));
    end;

    TerrainGridX := 0; TerrainGridZ := 0;
    WaterRivers := nil;
    WaterRiverRings.Rings := nil;
    WaterRiverRings.N := 0;
    Roads.Major := nil;     Roads.Secondary := nil;
    Roads.Minor := nil;     Roads.Service   := nil;
    Roads.Footway := nil;   Roads.Cycleway  := nil;
    Roads.Railway := nil;
    Roads.DirtPath := nil;  Roads.SandPath := nil;
    for PaletteI := 0 to BUILDING_PALETTE_SIZE - 1 do
    begin
      Buildings.Walls[PaletteI] := nil;
      Buildings.Roofs[PaletteI] := nil;
    end;
    for FencePaletteI := 0 to FENCE_PALETTE_SIZE - 1 do
      Fences.Fences[FencePaletteI] := nil;
    Fences.TileAnchors := nil;
    for K := Low(TLanduseMeshKind) to High(TLanduseMeshKind) do
      AInput.Landuse.Items[K] := nil;
    AInput.Landuse.ForestSeeds := nil;

    if FChunk.Heightmap <> nil then
    begin
      { Capture original water profiles before roads and FIT alter the DEM.
        Shared by all builders and the final welded ground drape. }
      WaterLevels := TWaterLevelField.Create(FChunk.Heightmap,
        FChunk.Dataset, Proj, FSettings.HeightmapZoom, WaterHeightSource,
        FSettings.GenerateRoads);
      LogInfo('  ' + WaterLevels.Stats);
      if WaterLevels.Empty then FreeAndNil(WaterLevels);
      { Продольное сглаживание профиля дорог — ДО меша: меш, сэмплер,
        лента (клип по тем же узлам), carve и вода читают один HM и
        остаются согласованными. Лечит шум источника высот вдоль
        полотна (замер: набор «по дороге» был ×1.9 от барометра).
        Швы: вес фильтра вырождается у края слепка — соседние чанки
        свариваются как раньше (см. Osm3dRoadProfile). }
      if FChunk.Dataset <> nil then
        LogInfo('  ' + SmoothRoadProfilesOnHeightmap(FChunk.Heightmap,
          FChunk.Dataset, Proj, FSettings.HeightmapZoom));

      { Маска пролётов мостов ДО постройки террейна: под пролётом OSM-моста
        земля берётся по чистому DEM / нижнему уровню (без насыпи-двойника),
        а настил встанет на верхний уровень FIT (Osm3dGeomBridges). Только при
        активном FIT-слое и включённых дорогах — иначе маскировать нечего. }
      BridgeMask := nil;
      if (FChunk.Dataset <> nil) and FSettings.GenerateRoads
         and (FitLayer <> nil) and FitLayer.Active then
      begin
        BridgeMask := TBridgeBuilder.CollectSpanMask(FChunk.Dataset, Proj);
        LogInfo(Format('  + span/waterway mask: %d segment(s) → под мостами и над реками земля по DEM',
          [Length(BridgeMask)]));
      end;

      LogInfo('Building terrain mesh from heightmap...');
      try
        GenerationProgress('Terrain', 0, 0);
        AInput.Terrain := TTerrainBuilder.Build(FChunk.Heightmap, Proj,
          FSettings.TerrainGridStepMeters, FSettings.HeightmapZoom,
          FSettings.TerrainSubdiv, FitLayer, BridgeMask, RouteCorridor, WaterLevels);
        LogStep('terrain', AInput.Terrain);

        { Sampler on the SAME lattice as the mesh (TerrainGridOf) — so
          water / roads / landuse draped through SampleAt sit flush on
          the terrain surface. }
        TerrainSampler := TTerrainSampler.Create(
          FChunk.Heightmap, Proj,
          FSettings.TerrainGridStepMeters, FSettings.HeightmapZoom,
          FSettings.TerrainSubdiv, FitLayer, BridgeMask, WaterLevels);
        TerrainGridX := TerrainSampler.GridX;
        TerrainGridZ := TerrainSampler.GridZ;
        LogInfo(Format('  + TerrainSampler ready (%dx%d nodes, %.1f MB)',
          [TerrainGridX, TerrainGridZ,
           (TerrainGridX * TerrainGridZ * 4) / (1024 * 1024)]));
        TerrainSampler.PrecomputeNodePositions(Proj);
        LogInfo(Format('  + TerrainSampler node positions cached (%.1f MB)',
          [(TerrainGridX * TerrainGridZ * 8) / (1024 * 1024)]));
        { Диагностика фетчера высот (2-й слой): работает ли FIT-коррекция на
          этом тайле — сколько узлов сдвинуто. 0 при активном слое = блок вне
          коридора маршрута; OFF = слой не установлен на момент генерации. }
        if (FitLayer <> nil) and FitLayer.Active then
          LogInfo(Format('  + FIT height-layer: ON sig=%s — corrected %d/%d terrain nodes, %d возвращены на DEM/низ маской (мосты+реки)',
            [FitLayer.Signature, TerrainSampler.CorrectedNodes,
             TerrainGridX * TerrainGridZ, TerrainSampler.MaskedNodes]))
        else
          LogInfo('  + FIT height-layer: OFF (nil/inactive) — terrain on raw DEM');
      except
        on E: Exception do
          LogError(Format('Terrain build FAILED: %s: %s',
            [E.ClassName, E.Message]));
      end;
    end
    else
      LogInfo('No heightmap — skipping terrain');

    CheckGenerationCancelled;

    if (FChunk.FarHeightmap <> nil) and FSettings.GenerateFarTerrain then
    begin
      LogInfo(Format('Building far-terrain mesh (grid step %.0f m, with hole)...',
        [FSettings.FarTerrainGridStepM]));
      try
        AInput.FarTerrain := TFarTerrainBuilder.Build(
          FChunk.FarHeightmap, Proj, FChunk.Box,
          FSettings.FarTerrainGridStepM);
        LogStep('far terrain', AInput.FarTerrain);
      except
        on E: Exception do
          LogError(Format('Far terrain build FAILED: %s: %s',
            [E.ClassName, E.Message]));
      end;
    end
    else if FSettings.GenerateFarTerrain then
      LogInfo('Far terrain enabled but no FarHeightmap in chunk');

    { ПАРАЛЛЕЛЬНАЯ ФАЗА БИЛДЕРОВ: шесть независимых задач на пуле —
      сумма их последовательных времён превращается в максимум одной.
      Dataset/Heightmap/Sampler читаются read-only (сэмплер прогрет выше),
      каждая задача пишет в свой выход и ловит свои исключения. }
    LogInfo('Building landuse / trees / water / buildings / fences / plates in parallel...');
    TPhase := GetTickCount64;
    BCtx.Dataset := FChunk.Dataset;
    BCtx.HM := FChunk.Heightmap;
    BCtx.Proj := Proj;
    BCtx.Sampler := TerrainSampler;
    BCtx.RoadIdx := RoadIdx;
    BCtx.Corridor := RouteCorridor;   { route-only: поэлементный фильтр забора по полосе }
    BCtx.Log := @Self.LogInfo;   { НЕ FLogProc: в стриминговом пути он nil
                                   (см. строку с 'FLogProc is nil in the
                                   streaming build path'), поэтому и «Skipping»,
                                   и [gen-cat] из задач молча терялись. LogInfo —
                                   метод билдера, лог под локом, уже зовётся из
                                   пула (Lg в фазе композита). }
    BCtx.GenTrees := FSettings.GenerateTrees;
    BCtx.GenBuildings := FSettings.GenerateBuildings;
    BCtx.GenFences := FSettings.GenerateFences;
    BCtx.GenPlates := FSettings.GeneratePlates;
    BCtx.PLanduse := @AInput.Landuse;
    BCtx.PTrees := @ATrees;
    BCtx.PWater := @WaterRivers;
    BCtx.PWaterRings := @WaterRiverRings;
    BCtx.PBuildings := @Buildings;
    BCtx.PCasters := @AInput.BuildingShadowCasters;
    BCtx.PFences := @Fences;
    BCtx.PPlates := @Plates;
    BCtx.PPlateAnchors := @PlateAnchors;
    Plates := nil;
    PlateAnchors := nil;
    GenerationParallelFor('Scene layers', 6, @RunBuildersRange, @BCtx, 1);
    CheckGenerationCancelled;
    { стеновое время всей параллельной фазы = max() шести задач выше плюс
      накладные пула. Сравнение с per-cat [gen-cat] показывает, съедает ли
      время одна категория или планировщик. }
    LogInfo(Format('  [gen-phase] parallel builders: %d ms',
      [GetTickCount64 - TPhase]));

    { Route-only: поэлементно отсечь деревья/кусты вне коридора (лесные полигоны
      задевают полосу краем, но рассаживают по всей площади — фильтруем по позиции
      каждого инстанса, сам полигон не выкидываем). }
    if RouteCorridor <> nil then
    begin
      RemTrees  := FilterTreeInstancesByCorridor(ATrees.Trees,  RouteCorridor);
      RemShrubs := FilterTreeInstancesByCorridor(ATrees.Shrubs, RouteCorridor);
      if (RemTrees > 0) or (RemShrubs > 0) then
        LogInfo(Format('  route-only: деревья вне коридора отсечены (−%d дерев, −%d куст)',
          [RemTrees, RemShrubs]));
    end;

    { пост-статистика по результатам (однопоточно, как раньше) }
    for K := Low(TLanduseMeshKind) to High(TLanduseMeshKind) do
      LogStep('landuse:' + LanduseKindName(K), AInput.Landuse.Items[K]);
    LogInfo(Format('  → %d tree instances, %d shrub instances',
      [Length(ATrees.Trees), Length(ATrees.Shrubs)]));
    FTStep := Now;
    LogStep('water rivers', WaterRivers);
    TotalWalls := 0; TotalRoofs := 0;
    for PaletteI := 0 to BUILDING_PALETTE_SIZE - 1 do
    begin
      if Buildings.Walls[PaletteI] <> nil then
        Inc(TotalWalls, Buildings.Walls[PaletteI].TriangleCount);
      if Buildings.Roofs[PaletteI] <> nil then
        Inc(TotalRoofs, Buildings.Roofs[PaletteI].TriangleCount);
      LogStep(Format('building walls p%d', [PaletteI]), Buildings.Walls[PaletteI]);
      LogStep(Format('building roofs p%d', [PaletteI]), Buildings.Roofs[PaletteI]);
    end;
    LogInfo(Format('Total: %d wall tris, %d roof tris (%d palettes), %d shadow casters',
      [TotalWalls, TotalRoofs, BUILDING_PALETTE_SIZE,
       Length(AInput.BuildingShadowCasters)]));
    for FencePaletteI := 0 to FENCE_PALETTE_SIZE - 1 do
      LogStep(Format('fence p%d', [FencePaletteI]),
              Fences.Fences[FencePaletteI]);
    LogStep('plates', Plates);

    if (FChunk.Dataset <> nil) and FSettings.GenerateRoads then
    begin
      LogInfo('Building classified road meshes...');
      TPhase := GetTickCount64;
      try
        GenerationProgress('Roads', 0, 0);
        Roads := TRoadBuilder.BuildAll(
          FChunk.Dataset, FChunk.Heightmap, Proj, RoadSegs, TerrainSampler,
          FLogProc, True, True);
        AInput.RoadSegments := RoadSegs;
        LogInfo(Format('  [gen-phase] roads: %d ms', [GetTickCount64 - TPhase]));
        LogStep('roads major',     Roads.Major);
        LogStep('roads secondary', Roads.Secondary);
        LogStep('roads minor',     Roads.Minor);
        LogStep('roads service',   Roads.Service);
        LogStep('roads footway',   Roads.Footway);
        LogStep('roads cycleway',  Roads.Cycleway);
        LogStep('roads railway',   Roads.Railway);
        LogStep('roads dirt path', Roads.DirtPath);
        LogStep('roads sand path', Roads.SandPath);
      except
        on E: Exception do
          LogError(Format('Roads build FAILED: %s: %s',
            [E.ClassName, E.Message]));
      end;
    end
    else
      LogInfo('Skipping roads (disabled or no dataset)');
    CheckGenerationCancelled;

    if FSettings.UseGroundComposition then
    begin
      TPhase := GetTickCount64;
      { Bridge end positions are computed BEFORE the carve (PlaceBridge samples
        the terrain height field, which the carve does not change), so the
        approach roads can be clipped exactly at the deck junction up front.
        TBridgeBuilder.Collect is pure (writes no geometry). ClipRoadsUnderDecks
        снимает полотно, ушедшее на мост/заезд/съезд (TMesh + UVMesh + IntRings),
        в т.ч. для FIT WeldJoints: срез в сечении торца палубы; новые треугольники
        среза остаются в дорожном меше → карв земли; под пролётом виден
        landuse/terrain (материал контакта). WeldJoints: выравнивание
        (FDeckJoints) по-прежнему прижимает кромку полотна к торцу настила.
        Deck/parapets — после carve (Emit). BridgeSpecs empty if roads off. }
      GenerationProgress('Bridges and tunnels', 0, 0);
      BridgeSpecs := nil;
      if FSettings.GenerateRoads and (FChunk.Dataset <> nil) then
      begin
        try
          BridgeSpecs := TBridgeBuilder.Collect(
            FChunk.Dataset, Proj, TerrainSampler, @Self.LogInfo,
            RoadIdx, FitLayer);
          TBridgeBuilder.ClipRoadsUnderDecks(BridgeSpecs, Roads, @Self.LogInfo);
        except
          on E: Exception do
            LogError(Format('Bridge collect/clip FAILED: %s: %s',
              [E.ClassName, E.Message]));
        end;
      end;

      { Якоря стыков FIT-мостов для выравнивания дорог («одна геометрия»):
        по два на сваренный настил — сечение торца, высота кромки (без
        лифта), направление наружу вдоль дороги. LeveledHeightAt/ApplyJoints
        прижмёт полотно в этих сечениях ровно к кромке настила; настил
        эмитится на тех же XZ/Y и сварится со срезом дороги. }
      FDeckJoints := nil;
      if Length(BridgeSpecs) > 0 then
      begin
        jointN := 0;
        SetLength(FDeckJoints, Length(BridgeSpecs) * 2);
        for bi := 0 to High(BridgeSpecs) do
        begin
          if not BridgeSpecs[bi].WeldJoints then Continue;
          cN := Length(BridgeSpecs[bi].Center);
          if (cN < 2) or (Length(BridgeSpecs[bi].CenterY) < cN) then Continue;
          { тупик (примыкающей дороги нет) — прижимать нечего, якорь только
            поднял бы землю пьедесталом под свисающим торцом }
          if BridgeSpecs[bi].ApprStartWayId <> 0 then
            PushDeckJoint(BridgeSpecs[bi], 0,      1,      jointN);
          if BridgeSpecs[bi].ApprEndWayId <> 0 then
            PushDeckJoint(BridgeSpecs[bi], cN - 1, cN - 2, jointN);
        end;
        SetLength(FDeckJoints, jointN);
        if jointN > 0 then
        begin
          LogInfo(Format('  + %d deck joint anchor(s): полотно прижимается к кромке настила («одна геометрия»)',
            [jointN]));
          { ген-диагностика: сечения стыков — сверять с FIT ROAD DIAG }
          for bi := 0 to jointN - 1 do
            GenLog(Format('DECK JOINT [%d]: x=%.1f z=%.1f H=%.2f halfW=%.1f out=(%.2f,%.2f)',
              [bi, FDeckJoints[bi].JX, FDeckJoints[bi].JZ, FDeckJoints[bi].H,
               FDeckJoints[bi].HalfW, FDeckJoints[bi].DirX, FDeckJoints[bi].DirZ]));
        end;
      end;

      { Речные таблички «р. …»: из BridgeSpecs.RiverName + концов настила собираем
        массив TRiverSign и доклеиваем панели в уже собранный plate-меш (он ещё
        мутабелен — присваивается AInput.Plates ниже) и его якоря. Извлечение тут,
        в билдере, держит Plates и Bridges развязанными (тип TRiverSign — в Plates,
        TBridgeSpec — в Bridges, общий шов — только здесь). }
      if (Plates <> nil) and FSettings.GeneratePlates and (Length(BridgeSpecs) > 0) then
      begin
        try
          RiverSigns := nil; rsCount := 0;
          for bi := 0 to High(BridgeSpecs) do
          begin
            if Trim(BridgeSpecs[bi].RiverName) = '' then Continue;
            cN := Length(BridgeSpecs[bi].Center);
            if (cN < 2) or (Length(BridgeSpecs[bi].CenterY) < cN) then Continue;
            if rsCount >= Length(RiverSigns) then
              SetLength(RiverSigns, (rsCount + 1) * 2);
            RiverSigns[rsCount].WayId := BridgeSpecs[bi].WayId;
            RiverSigns[rsCount].Name  := BridgeSpecs[bi].RiverName;
            { приоритет дедупа речных табличек — ширина моста (шире = крупнее дорога):
              из двух параллельных мостов над рекой табличку оставит более широкий. }
            RiverSigns[rsCount].Prio  := BridgeSpecs[bi].Width;
            { сквозной номер моста на табличку только при отладке (тот же, что в
              логе); иначе -1 — табличка без номера. }
            if LOGGING_ENABLED then RiverSigns[rsCount].Num := BridgeSpecs[bi].Num
            else                    RiverSigns[rsCount].Num := -1;
            { конец A = Center[0], направление внутрь = Center[1]-Center[0] }
            RiverSigns[rsCount].Ax := BridgeSpecs[bi].Center[0].X;
            RiverSigns[rsCount].Az := BridgeSpecs[bi].Center[0].Z;
            RiverSigns[rsCount].Ay := BridgeSpecs[bi].CenterY[0];
            rdx := BridgeSpecs[bi].Center[1].X - BridgeSpecs[bi].Center[0].X;
            rdz := BridgeSpecs[bi].Center[1].Z - BridgeSpecs[bi].Center[0].Z;
            rdl := Sqrt(rdx*rdx + rdz*rdz);
            if rdl > 1e-9 then begin rdx := rdx/rdl; rdz := rdz/rdl; end;
            RiverSigns[rsCount].Adx := rdx; RiverSigns[rsCount].Adz := rdz;
            { конец B = Center[High], направление внутрь = Center[High-1]-Center[High] }
            cN := High(BridgeSpecs[bi].Center);
            RiverSigns[rsCount].Bx := BridgeSpecs[bi].Center[cN].X;
            RiverSigns[rsCount].Bz := BridgeSpecs[bi].Center[cN].Z;
            RiverSigns[rsCount].By := BridgeSpecs[bi].CenterY[cN];
            rdx := BridgeSpecs[bi].Center[cN-1].X - BridgeSpecs[bi].Center[cN].X;
            rdz := BridgeSpecs[bi].Center[cN-1].Z - BridgeSpecs[bi].Center[cN].Z;
            rdl := Sqrt(rdx*rdx + rdz*rdz);
            if rdl > 1e-9 then begin rdx := rdx/rdl; rdz := rdz/rdl; end;
            RiverSigns[rsCount].Bdx := rdx; RiverSigns[rsCount].Bdz := rdz;
            Inc(rsCount);
          end;
          SetLength(RiverSigns, rsCount);

          if rsCount > 0 then
          begin
            RsAtlas := TPlateGlyphAtlas.Create;
            try
              rsCount := Length(PlateAnchors);   { текущее число якорей }
              rsMade  := 0;
              TPlateBuilder.AppendRiverSigns(Plates, RiverSigns, RsAtlas,
                PlateAnchors, rsCount, rsMade, @Self.LogInfo);
              SetLength(PlateAnchors, rsCount);  { обрезать дорощенный массив }
            finally
              RsAtlas.Free;
            end;
          end;
        except
          on E: Exception do
            LogError(Format('River signs FAILED: %s: %s',
              [E.ClassName, E.Message]));
        end;
      end;

      { Туннели — сбор ДО карва: те же specs позже (пост-карв слот ниже)
        дадут полотно+обделку, а подходные съезды (TunnelRamps) уходят в
        выравнивание композита — полотно ныряет под землю ДО портала. }
      TunnelSpecs := nil; TunnelRamps := nil; TunnelPortalTerr := nil;
      if FSettings.GenerateRoads and (FChunk.Dataset <> nil) then
      begin
        try
          TunnelSpecs := TTunnelBuilder.Collect(FChunk.Dataset, Proj,
            TerrainSampler, @Self.LogInfo, FitLayer, TunnelRamps,
            TunnelPortalTerr);
        except
          on E: Exception do
            LogError(Format('Tunnels collect FAILED: %s: %s',
              [E.ClassName, E.Message]));
        end;
      end;

      CheckGenerationCancelled;
      LogInfo('Building ground composite (terrain + landuse + roads)...');
      try
        BuildGroundComposite(AInput, Roads, WaterRiverRings, TunnelRamps,
          Fences, TerrainSampler, Proj);
      except
        on E: Exception do
          LogError(Format('GroundComposite build FAILED: %s: %s',
            [E.ClassName, E.Message]));
      end;
      CheckGenerationCancelled;
      { Route-only: земляной композит (карвом = сплошная земля на весь тайл)
        пересобираем, оставляя только треугольники, у которых ХОТЯ БЫ одна
        вершина в коридоре маршрута — иначе тайл в отдельном кэше был бы
        неотличим от полного мира. Дороги/лендюз тоже здесь (они в композите);
        здания/деревья/POI отфильтрованы раньше на этапе датасета. }
      if (RouteCorridor <> nil) and (AInput.GroundComposite <> nil) then
        ClipCompositeToCorridor(AInput.GroundComposite, RouteCorridor,
          @Self.LogInfo);

      { Bridges: deck + parapets appended AFTER carve AND leveling so the deck stays horizontal
        (never re-draped/leveled/normalled). Ground under bridges is left un-carved by
        ClipRoadsUnderDecks + the bridge-way exclusion in TRoadBuilder.BuildAll. Deck = road
        material; parapets = a concrete fence in the live Fences meshes. }
      if FSettings.GenerateRoads and (FChunk.Dataset <> nil) and
         (AInput.GroundComposite <> nil) and
         (AInput.GroundComposite.VertexCount > 0) then
      begin
        LogInfo('Building bridge decks + parapets...');
        try
          TBridgeBuilder.Emit(BridgeSpecs, AInput.GroundComposite, Fences,
            FSettings.GenerateFences, @Self.LogInfo);
        except
          on E: Exception do
            LogError(Format('Bridges build FAILED: %s: %s',
              [E.ClassName, E.Message]));
        end;
      end;

      { Tunnels — «мост наоборот» (Osm3dGeomTunnels): нижнее полотно тем же
        EmitDeck (дорожный материал), но опущенное под рельеф; бетонная
        обделка (боковые/торцевые стены + потолок) — в массив стен зданий
        палитрой «бетон» (+ якоря тайлов). Туннельные way исключены из
        дорожных мешей в TRoadBuilder.BuildAll (как мосты), поэтому склон
        над трубой остаётся некарвленным; ныряние полотна ДО портала —
        подходные траншеи в выравнивании (Collect выше, до карва). Тот же
        пост-карв слот, что мосты: полотно не пере-драпируется/не
        выравнивается. Specs собраны заранее (до BuildGroundComposite). }
      if FSettings.GenerateRoads and (FChunk.Dataset <> nil) and
         (TunnelSpecs <> nil) and
         (AInput.GroundComposite <> nil) and
         (AInput.GroundComposite.VertexCount > 0) then
      begin
        LogInfo('Building tunnel decks + concrete tubes...');
        try
          TTunnelBuilder.Emit(TunnelSpecs, AInput.GroundComposite, Buildings,
            TunnelPortalTerr, @Self.LogInfo);
        except
          on E: Exception do
            LogError(Format('Tunnels build FAILED: %s: %s',
              [E.ClassName, E.Message]));
        end;
      end;

      { Road dist-field for FS-side sandy halo (streets-gl style).
        Rasterise every paved segment into an R8 mask, Gaussian-blur,
        composite FS samples and blends sandy_soil over grass. }
      if (FChunk.Dataset <> nil) and (AInput.GroundComposite <> nil) and
         (AInput.GroundComposite.VertexCount > 0) then
      begin
        LogInfo('Building road distance-field for shader-side halo...');
        try
          AInput.RoadDistField := TRoadDistField.Create;
          BuildRoadDistFieldBounds(AInput, AInput.RoadDistField);
          AInput.RoadDistField.AddFromDataset(FChunk.Dataset, Proj);
          AInput.RoadDistField.Build(FLogProc);
        except
          on E: Exception do
          begin
            LogError(Format('RoadDistField build FAILED: %s: %s',
              [E.ClassName, E.Message]));
            FreeAndNil(AInput.RoadDistField);
          end;
        end;
      end;
    end;

    if FSettings.UseGroundComposition then
      LogInfo(Format('  [gen-phase] ground composite + carve: %d ms',
        [GetTickCount64 - TPhase]));

    LogInfo(Format('Geometry totals: %d verts, %d tris across all meshes',
      [FTotalVerts, FTotalTris]));

    { Единая генерация: речные ленты всегда в грунт-композите (WaterRiverRings),
      поэтому отдельный меш WaterRivers не нужен НИ в каком режиме — иначе он
      дублировал бы карвленную ленту (z-fight, поверх полигона/дорог). Очищаем
      всегда, как и полигональную воду. Анимация воды — шейдером материала. }
    if (WaterRivers <> nil) and (WaterRiverRings.N > 0) then
      WaterRivers.Clear;

    PublishOwnedMeshes;
    CheckGenerationCancelled;

    if (FChunk.Dataset <> nil) and (FChunk.Heightmap <> nil) and
       FSettings.GeneratePOI then
    begin
      LogInfo('Building POI instances...');
      { Reset step timer: prior LogStep was minutes ago through unrelated
        work, would skew the POI line to ~80 s instead of actual ~200 ms. }
      FTStep := Now;
      try
        { Keep compact placement records in the cache. The assembler batches
          their templates by material at tile load; AInput.POI stays nil. }
        GenerationProgress('Map objects', 0, 0);
        AInput.POIInstances := TPOIBuilderExt.BuildAllInstances(
          FChunk.Dataset, FChunk.Heightmap, Proj, TerrainSampler,
          RoadIdx);
        AInput.POI := nil;
        LogInfo(Format('  %d POI instances built in %.0f ms',
          [Length(AInput.POIInstances), (Now - FTStep) * 86400000.0]));
      except
        on E: Exception do
          LogError(Format('POI build FAILED: %s: %s',
            [E.ClassName, E.Message]));
      end;
    end
    else
      LogInfo('Skipping POI (disabled or no dataset)');

    SurfaceQuery:=nil;
    try
      if FSettings.GenerateRoads then begin
        TPhase := GetTickCount64;
        AInput.RoadFurniture:=BuildCrossings(FChunk.Dataset,Proj,AInput.RoadSegments,
          AInput.GroundComposite,CrossingStats,SurfaceQuery);
        if CrossingStats.Crossings>0 then
          LogInfo(Format('Crossings: %d, signs: %d, speed bumps: %d (%d ms)',
            [CrossingStats.Crossings,CrossingStats.Signs,CrossingStats.Bumps,
             GetTickCount64 - TPhase]));
      end;
      TPhase := GetTickCount64;
      AInput.Manholes:=BuildManholes(FChunk.Dataset,Proj,AInput.GroundComposite,SurfaceQuery);
      if Length(AInput.Manholes)>0 then
        LogInfo(Format('Manholes: %d cached placements (%d ms)',
          [Length(AInput.Manholes),GetTickCount64 - TPhase]));
    finally SurfaceQuery.Free end;

    { RenderLabels gates building the label X3D nodes (text shapes + material)
      at creation level. Build-stage gate, so it takes effect on the next
      reload, not instantly. }
    if (FChunk.Dataset <> nil) and FSettings.GenerateLabels
       and FSettings.RenderLabels then
    begin
      LogInfo('Building street/POI labels...');
      try
        GenerationProgress('Map labels', 0, 0);
        AInput.LabelsRoot := TLabelBuilder.BuildAll(
          FChunk.Dataset, FChunk.Heightmap, Proj, TerrainSampler);
        if AInput.LabelsRoot <> nil then
          LogInfo(Format('Labels: %d billboards',
            [AInput.LabelsRoot.FdChildren.Count]))
        else
          LogInfo('Labels: none');
      except
        on E: Exception do
        begin
          LogError(Format('Labels build FAILED: %s: %s',
            [E.ClassName, E.Message]));
          AInput.LabelsRoot := nil;
        end;
      end;
    end
    else
      LogInfo('Skipping labels (disabled or no dataset)');

    LogInfo(Format('GeometryBuilder: COMPLETE in %.2f s total',
      [(Now - T0) * 86400.0]));

    Result := True;
  finally
    PublishOwnedMeshes;
    FreeAndNil(RoadIdx);   { единый индекс дорог блока (Osm3dOsmIndex) }
    TerrainSampler.Free;
    WaterLevels.Free;
    Proj.Free;
  end;
end;

end.
