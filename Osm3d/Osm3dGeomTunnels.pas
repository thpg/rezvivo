unit Osm3dGeomTunnels;

{ overflow/range-проверки выключены намеренно (как в смежных модулях геометрии:
  упаковка/арифметика индексов рассчитывает на тот же режим). }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$codepage UTF8}

{ Tunnels for the ground composite — «мост наоборот» (образец: Osm3dGeomBridges).
    1. Tunnel ways are excluded from the road meshes (TRoadBuilder.BuildAll,
       OsmWayIsTunnel) — the carve only cuts what is in the meshes, so the
       hillside ABOVE the bore stays un-cut (мост: земля под настилом;
       туннель: склон над трубой).
    2. AFTER the carve this builder emits:
       • НИЖНЕЕ ПОЛОТНО — тот же настил, что у моста (TBridgeBuilder.EmitDeck,
         дорожный материал/UV/намотка), только ОПУЩЕННЫЙ под рельеф, а не
         поднятый над ним;
       • БЕТОННАЯ ОБДЕЛКА — боковые стены, торцевые стены обоих порталов и
         потолок — дописывается в массив стен ЗДАНИЙ (Buildings.Walls) палитрой
         «бетон» (TUNNEL_WALL_PALETTE), UV прижаты к глухой полосе фасада —
         приём cooling tower из Osm3dGeomBuildings. Перил нет — стены вместо
         них.
  Высота полотна — ВСЕГДА ниже композита земли: потолок трубы (полотно +
  TUNNEL_CLEAR_HEIGHT_M) удерживается под рельефом с запасом TUNNEL_COVER_M,
  допустимое заглубление растёт от порталов по пандусу TUNNEL_RAMP_SLOPE_DEG
  (на торцах 0 — шов с дорогой). Базовый профиль: с активным FIT-слоем —
  повертексно RoadTargetGeo (уровень, где реально ехали), без FIT — ровный
  забой на min-рельефе вдоль пути минус CLEAR+COVER+TUNNEL_BORE_DIG_M; оба
  профиля затем режутся сверху ограничением заглубления. Оба конца получают
  пятку-перекрытие на примыкающую дорогу — закрывает поперечный шов. }

interface

uses
  Classes,
  SysUtils,
  Math,
  CastleVectors,
  Osm3dGeoMath,           { TLatLon, TLocalProjection, TXZ / TXZArray, TLogProc }
  Osm3dGeomMesh,          { TMesh, TMeshVertex, MakeUV }
  Osm3dOsmData,           { TOSMDataset / TOSMWay / TOSMNode, NodePlanePos }
  Osm3dGeomTerrain,       { TTerrainSampler }
  Osm3dFitHeightLayer,    { TFitHeightLayer — нижний уровень FIT (дорога в трубе) }
  Osm3dGeomRoads,         { TRoadBuilder, TRoadParams, OsmWayIsTunnel }
  Osm3dGroundComposite,   { TGroundCompositeMesh, GROUND_MAT_FOR_ROAD, TGroundMaterialId }
  Osm3dGeomBridges,       { TBridgeSpec / TBridgeSpecArray / TBridgeBuilder.EmitDeck }
  Osm3dGeomBuildings      { TBuildingMeshes, TBuildingTileAnchor }
  ;

const
  { Туннели короче этого (по проекции) игнорируются — случайный tunnel=yes на
    перемычке-проходе только засорил бы сцену. }
  TUNNEL_MIN_LEN_M        = 1.0;
  { Габарит трубы над полотном (низ потолка), м. }
  TUNNEL_CLEAR_HEIGHT_M   = 5.0;
  { Стены продлены НИЖЕ полотна — закрывают шов «стена/настил». }
  TUNNEL_WALL_BELOW_M     = 0.30;
  { Вылет торцевой стенки за габарит трубы (обрамление портала), м. }
  TUNNEL_PORTAL_FLANGE_M  = 0.60;
  { Верх торцевой стенки над потолком, м. }
  TUNNEL_PORTAL_TOP_M     = 0.80;
  { Боковые крылья оголовка за габарит трубы: закрывают фронт вырезанного
    земляного вала на всю ширину траншеи (BLEND выравнивания ~6 м + запас). }
  TUNNEL_PORTAL_WING_M    = 7.0;
  { Возвышение оголовка/козырька над рельефом у портала, м. }
  TUNNEL_PORTAL_CAP_H_M   = 0.30;
  { Хирургия проёма: полоса вырезания крутых треугольников композита
    СНАРУЖИ от портала (по траншее), м. }
  TUNNEL_SURG_OUT_M       = 4.0;
  { ... и ВНУТРЬ бура (под козырёк), м. }
  TUNNEL_SURG_IN_M        = 7.0;
  { Полотно заходит на дорогу за торцами — закрывает поперечный шов. }
  TUNNEL_DECK_OVERLAP_M   = 2.5;
  { Микролифт пятки-перекрытия над дорогой — против z-fight на шве. }
  TUNNEL_DECK_LIFT_M      = 0.03;
  { Опускание забоя под минимальный рельеф вдоль пути (режим без FIT), м. }
  TUNNEL_BORE_DIG_M       = 0.5;
  { Запас грунта над потолком трубы: полотно заглубляется так, чтобы потолок
    (полотно + CLEAR) оставался ниже композита земли хотя бы на эту толщину. }
  TUNNEL_COVER_M          = 1.0;
  { Глубина заложения полотна под композитом: потолок трубы (полотно+CLEAR)
    + запас грунта (COVER) + докопка. На эту глубину ныряет и подходная
    траншея (съезд до портала по пандусу TUNNEL_RAMP_SLOPE_DEG). }
  TUNNEL_DECK_DEPTH_M     = TUNNEL_CLEAR_HEIGHT_M + TUNNEL_COVER_M
                          + TUNNEL_BORE_DIG_M;
  { Уклон внутреннего съезда от портала в забой (режим без FIT), градусы. }
  TUNNEL_RAMP_SLOPE_DEG   = 8.0;
  { Палитра стен зданий «бетон» (Osm3dGeomBuildings: concrete/plaster → 2). }
  TUNNEL_WALL_PALETTE     = 2;

type
  TTunnelBuilder = class
  public
    { Найти в датасете туннельные пути (OsmWayIsTunnel + реальный класс дороги)
      и разобрать каждый в TBridgeSpec — запись ОБЩАЯ с мостами (настил =
      нижнее полотно туннеля), поэтому эмит полотна переиспользует
      TBridgeBuilder.EmitDeck. Чистая функция — геометрию не пишет.
      AFitLayer (опц.) — полотно на уровне, где реально ехали (RoadTargetGeo);
      nil / вне покрытия = забой по рельефу.
      AApproachSegs (out) — подходные съезды с ЯВНЫМ профилем высот: по ним
      LevelRoadsInComposite тянет траншею, и полотно ныряет под композит
      ДО портала (а не за ним, внутри трубы).
      APortalTerr (out) — рельеф у торцов каждого spec'а [2i]=начало,
      [2i+1]=конец (по Spec.Num): высота оголовков/козырьков порталов. }
    class function Collect(Dataset: TOSMDataset; Projection: TLocalProjection;
      Sampler: TTerrainSampler; LogProc: TLogProc;
      AFitLayer: TFitHeightLayer;
      out AApproachSegs: TTunnelApproachSegArray;
      out APortalTerr: TSingleArray): TBridgeSpecArray; static;

    { Записать нижние полотна в композит (TBridgeBuilder.EmitDeck) и бетонные
      трубы (стены/торцы/потолок) в Buildings.Walls[TUNNEL_WALL_PALETTE]
      (+ якоря тайлов). Меняет Composite (append + TrimArrays) и Buildings
      (append вершин + TileAnchors). ДО труб — хирургия проёмов: из
      композита вырезаются крутые треугольники подъёма у порталов (иначе
      земляной вал закрывает устье), края выреза закрывает оголовок с
      козырьком. APortalTerr — рельеф у торцов (из Collect, [2i]/[2i+1] по
      Spec.Num; nil/короткий = фолбэк над потолком). }
    class procedure Emit(const Specs: TBridgeSpecArray;
      Composite: TGroundCompositeMesh; var Buildings: TBuildingMeshes;
      const APortalTerr: TSingleArray;
      LogProc: TLogProc); static;
  end;

implementation

{ ----------------------------------------------------------------- helpers }

{ Сэмплинг высоты рельефа — общий SampleTerrainYXZ в Osm3dGeomTerrain
  (тот же скорректированный сэмплер с NaN-защитой, что у мостов); перпендикуляры
  и смещённые ломаные — общие PerpAt/OffsetPolyline в Osm3dGeoMath. }

{ Квад с гарантированной намоткой ПОД заданную нормаль: порядок вершин
  разворачивается, если геометрическая нормаль смотрит против N. UV прижаты
  к глухой полосе бетонного фасада (V=0), U — пробег (как cooling tower).
  Меши зданий MakeWindingMatchNormals для нас не вызывают (трубы дописаны
  после их билда) — поэтому намотку держим сами. }
procedure AddQuadN(Target: TMesh; const P0, P1, P2, P3: TVector3;
  const N: TVector3; U0, U1: Single);
var
  cx, cy, cz, d: Double;
  v0, v1, v2, v3: Integer;
begin
  cx := (P1.Y - P0.Y) * (P2.Z - P0.Z) - (P1.Z - P0.Z) * (P2.Y - P0.Y);
  cy := (P1.Z - P0.Z) * (P2.X - P0.X) - (P1.X - P0.X) * (P2.Z - P0.Z);
  cz := (P1.X - P0.X) * (P2.Y - P0.Y) - (P1.Y - P0.Y) * (P2.X - P0.X);
  d := cx * N.X + cy * N.Y + cz * N.Z;
  if d >= 0 then
  begin
    v0 := Target.AddVertex(P0, N, MakeUV(U0, 0.0));
    v1 := Target.AddVertex(P1, N, MakeUV(U1, 0.0));
    v2 := Target.AddVertex(P2, N, MakeUV(U1, 0.0));
    v3 := Target.AddVertex(P3, N, MakeUV(U0, 0.0));
    Target.AddQuad(v0, v1, v2, v3);
  end
  else
  begin
    v0 := Target.AddVertex(P0, N, MakeUV(U0, 0.0));
    v3 := Target.AddVertex(P3, N, MakeUV(U0, 0.0));
    v2 := Target.AddVertex(P2, N, MakeUV(U1, 0.0));
    v1 := Target.AddVertex(P1, N, MakeUV(U1, 0.0));
    Target.AddQuad(v0, v3, v2, v1);
  end;
end;

{ ------------------------------------------------------ бетонная обделка }

{ Одна труба: боковые стены от (полотно − TUNNEL_WALL_BELOW_M) до (полотно +
  TUNNEL_CLEAR_HEIGHT_M), потолок между верхами стен, торцевые стены на обоих
  концах. Нормали — ВНУТРЬ трубы (стены/потолок видны из проезда), у
  торцевых — НАРУЖУ (фасад портала).
  Оголовок портала (terrP = рельеф у торца, из Collect): ПОЛНАЯ стена через
  всю ширину траншеи от полотна до (рельеф + TUNNEL_PORTAL_CAP_H_M) с
  проёмом = сечение трубы — закрывает фронт вырезанного хирургией земляного
  вала (CarvePortalOpenings); сверху — горизонтальный козырёк над вырезом
  (от подхода до глубины бура) с бортиками. Один якорь на трубу — как у
  зданий/заборов. }
procedure EmitTube(const Spec: TBridgeSpec; var Buildings: TBuildingMeshes;
  terrS, terrE: Single; hasTerr: Boolean; wingS, wingE: Single);
var
  L, R: TXZArray;
  i, hi, preVert, preTri, vEnd, tEnd, vspan, an: Integer;
  halfW: Single;
  yB0, yB1, yT0, yT1: Single;
  u0, u1: Single;
  WallMesh: TMesh;
  prevOsm: Int64;
  NL, NR, ND, NOut: TVector3;
  px, pz, ox, oz, dl: Double;
  sumX, sumZ: Single;
  pLO, pRO: TVector3;

  procedure EmitPortal(idx, innerIdx: Integer; terrP: Single; wingP: Single);
  var
    Lx, Lz, Rx, Rz: Double;
    yBv, yTv, yTop: Single;
    cfx, cfz, cbx, cbz, wing: Double;
    NUp, NSide: TVector3;
  begin
    { направление НАРУЖУ из трубы через торец idx }
    ox := Spec.Center[idx].X - Spec.Center[innerIdx].X;
    oz := Spec.Center[idx].Z - Spec.Center[innerIdx].Z;
    dl := Sqrt(ox*ox + oz*oz);
    if dl < 1e-9 then Exit;
    ox := ox/dl; oz := oz/dl;
    NOut := Vector3(Single(ox), 0.0, Single(oz));
    { перпендикуляр торца (как у стен) и внешние грани крыльев }
    Lx := L[idx].X; Lz := L[idx].Z;
    Rx := R[idx].X; Rz := R[idx].Z;
    wing := wingP;
    pLO := Vector3(Single(Lx - px * wing), 0.0, Single(Lz - pz * wing));
    pRO := Vector3(Single(Rx + px * wing), 0.0, Single(Rz + pz * wing));
    yBv := Spec.CenterY[idx] - TUNNEL_WALL_BELOW_M;
    yTv := Spec.CenterY[idx] + TUNNEL_CLEAR_HEIGHT_M;
    if hasTerr then
      yTop := terrP + TUNNEL_PORTAL_CAP_H_M
    else
      yTop := yTv + TUNNEL_PORTAL_TOP_M;
    { левое крыло: от внешней грани до стены трубы, ВСЯ высота }
    AddQuadN(WallMesh,
      Vector3(pLO.X, yBv, pLO.Z), Vector3(Single(Lx), yBv, Single(Lz)),
      Vector3(Single(Lx), yTop, Single(Lz)), Vector3(pLO.X, yTop, pLO.Z),
      NOut, 0.0, 1.0);
    { правое крыло }
    AddQuadN(WallMesh,
      Vector3(Single(Rx), yBv, Single(Rz)), Vector3(pRO.X, yBv, pRO.Z),
      Vector3(pRO.X, yTop, pRO.Z), Vector3(Single(Rx), yTop, Single(Rz)),
      NOut, 0.0, 1.0);
    { перемычка над проездом — во всю ширину сечения }
    AddQuadN(WallMesh,
      Vector3(pLO.X, yTv, pLO.Z), Vector3(pRO.X, yTv, pRO.Z),
      Vector3(pRO.X, yTop, pRO.Z), Vector3(pLO.X, yTop, pLO.Z),
      NOut, 0.0, 1.0);
    { козырёк над вырезом композита: горизонтальная плита от подхода
      (SURG_OUT за портал) до глубины бура (SURG_IN внутрь), во всю ширину
      крыльев; нормаль вверх. Края плиты — бортики вниз (прячут кромку). }
    cfx := Spec.Center[idx].X + ox * (TUNNEL_SURG_OUT_M + 2.0);
    cfz := Spec.Center[idx].Z + oz * (TUNNEL_SURG_OUT_M + 2.0);
    cbx := Spec.Center[idx].X - ox * (TUNNEL_SURG_IN_M + 2.0);
    cbz := Spec.Center[idx].Z - oz * (TUNNEL_SURG_IN_M + 2.0);
    NUp := Vector3(0.0, 1.0, 0.0);
    AddQuadN(WallMesh,
      Vector3(Single(cfx - px * wing), yTop, Single(cfz - pz * wing)),
      Vector3(Single(cfx + px * wing), yTop, Single(cfz + pz * wing)),
      Vector3(Single(cbx + px * wing), yTop, Single(cbz + pz * wing)),
      Vector3(Single(cbx - px * wing), yTop, Single(cbz - pz * wing)),
      NUp, 0.0, 1.0);
    { бортик левый }
    NSide := Vector3(Single(-px), 0.0, Single(-pz));
    AddQuadN(WallMesh,
      Vector3(Single(cbx - px * wing), yTop - 1.0, Single(cbz - pz * wing)),
      Vector3(Single(cfx - px * wing), yTop - 1.0, Single(cfz - pz * wing)),
      Vector3(Single(cfx - px * wing), yTop, Single(cfz - pz * wing)),
      Vector3(Single(cbx - px * wing), yTop, Single(cbz - pz * wing)),
      NSide, 0.0, 1.0);
    { бортик правый }
    NSide := Vector3(Single(px), 0.0, Single(pz));
    AddQuadN(WallMesh,
      Vector3(Single(cfx + px * wing), yTop - 1.0, Single(cfz + pz * wing)),
      Vector3(Single(cbx + px * wing), yTop - 1.0, Single(cbz + pz * wing)),
      Vector3(Single(cbx + px * wing), yTop, Single(cbz + pz * wing)),
      Vector3(Single(cfx + px * wing), yTop, Single(cfz + pz * wing)),
      NSide, 0.0, 1.0);
    { бортик задний (внутрь бура) }
    NSide := Vector3(Single(-ox), 0.0, Single(-oz));
    AddQuadN(WallMesh,
      Vector3(Single(cbx - px * wing), yTop - 1.0, Single(cbz - pz * wing)),
      Vector3(Single(cbx + px * wing), yTop - 1.0, Single(cbz + pz * wing)),
      Vector3(Single(cbx + px * wing), yTop, Single(cbz + pz * wing)),
      Vector3(Single(cbx - px * wing), yTop, Single(cbz - pz * wing)),
      NSide, 0.0, 1.0);
  end;

begin
  if Length(Spec.Center) < 2 then Exit;
  if Length(Spec.CenterY) < Length(Spec.Center) then Exit;
  halfW := Spec.Width * 0.5;
  if halfW < 0.8 then halfW := 0.8;    { узкая дорожка — минимальный габарит трубы }

  WallMesh := Buildings.Walls[TUNNEL_WALL_PALETTE];
  if WallMesh = nil then
  begin
    WallMesh := TMesh.Create;
    Buildings.Walls[TUNNEL_WALL_PALETTE] := WallMesh;
  end;

  OffsetPolyline(Spec.Center, -halfW, L);   { левый край }
  OffsetPolyline(Spec.Center,  halfW, R);   { правый край }

  preVert := WallMesh.VertexCount;
  preTri  := WallMesh.TriangleCount;
  prevOsm := WallMesh.CurrentOsmId;
  WallMesh.CurrentOsmId := Spec.WayId;
  try
    hi := High(Spec.Center);
    for i := 0 to hi - 1 do
    begin
      yB0 := Spec.CenterY[i]   - TUNNEL_WALL_BELOW_M;
      yB1 := Spec.CenterY[i+1] - TUNNEL_WALL_BELOW_M;
      yT0 := Spec.CenterY[i]   + TUNNEL_CLEAR_HEIGHT_M;
      yT1 := Spec.CenterY[i+1] + TUNNEL_CLEAR_HEIGHT_M;
      u0 := Spec.AccumLen[i]   / 4.0;
      u1 := Spec.AccumLen[i+1] / 4.0;
      { нормали стен — горизонтально внутрь трубы }
      NL := Vector3(Single(R[i].X - L[i].X), 0.0, Single(R[i].Z - L[i].Z));
      NR := Vector3(Single(L[i].X - R[i].X), 0.0, Single(L[i].Z - R[i].Z));
      ND := Vector3(0.0, -1.0, 0.0);
      { левая стена }
      AddQuadN(WallMesh,
        Vector3(Single(L[i].X),   yB0, Single(L[i].Z)),
        Vector3(Single(L[i+1].X), yB1, Single(L[i+1].Z)),
        Vector3(Single(L[i+1].X), yT1, Single(L[i+1].Z)),
        Vector3(Single(L[i].X),   yT0, Single(L[i].Z)),
        NL, u0, u1);
      { правая стена }
      AddQuadN(WallMesh,
        Vector3(Single(R[i].X),   yB0, Single(R[i].Z)),
        Vector3(Single(R[i+1].X), yB1, Single(R[i+1].Z)),
        Vector3(Single(R[i+1].X), yT1, Single(R[i+1].Z)),
        Vector3(Single(R[i].X),   yT0, Single(R[i].Z)),
        NR, u0, u1);
      { потолок — нормаль вниз, в проезд }
      AddQuadN(WallMesh,
        Vector3(Single(L[i].X),   yT0, Single(L[i].Z)),
        Vector3(Single(L[i+1].X), yT1, Single(L[i+1].Z)),
        Vector3(Single(R[i+1].X), yT1, Single(R[i+1].Z)),
        Vector3(Single(R[i].X),   yT0, Single(R[i].Z)),
        ND, u0, u1);
    end;

    { оголовки обоих порталов (перпендикуляр торца — из PerpAt; рельеф
      торца — из Collect, фолбэк — над потолком) }
    PerpAt(Spec.Center, 0,  px, pz);
    EmitPortal(0, 1, terrS, wingS);
    PerpAt(Spec.Center, hi, px, pz);
    EmitPortal(hi, hi - 1, terrE, wingE);
  finally
    WallMesh.CurrentOsmId := prevOsm;
  end;

  { один якорь на трубу (центроид добавленных вершин), раскладка как у
    зданий/заборов — крышного диапазона нет (потолок живёт в стенах). }
  vEnd  := WallMesh.VertexCount;
  tEnd  := WallMesh.TriangleCount;
  vspan := vEnd - preVert;
  if vspan <= 0 then Exit;
  sumX := 0; sumZ := 0;
  for i := preVert to vEnd - 1 do
  begin
    sumX := sumX + WallMesh.Vertices[i].Position.X;
    sumZ := sumZ + WallMesh.Vertices[i].Position.Z;
  end;
  an := Length(Buildings.TileAnchors);
  SetLength(Buildings.TileAnchors, an + 1);
  Buildings.TileAnchors[an].Palette        := TUNNEL_WALL_PALETTE;
  Buildings.TileAnchors[an].AnchorX        := sumX / vspan;
  Buildings.TileAnchors[an].AnchorZ        := sumZ / vspan;
  Buildings.TileAnchors[an].WallsTriStart  := preTri;
  Buildings.TileAnchors[an].WallsTriEnd    := tEnd;
  Buildings.TileAnchors[an].WallsVertStart := preVert;
  Buildings.TileAnchors[an].WallsVertEnd   := vEnd;
  Buildings.TileAnchors[an].RoofsTriStart  := 0;
  Buildings.TileAnchors[an].RoofsTriEnd    := 0;
  Buildings.TileAnchors[an].RoofsVertStart := 0;
  Buildings.TileAnchors[an].RoofsVertEnd   := 0;
  Buildings.TileAnchors[an].NoShadowCast   := True;
end;

{ Хирургия проёмов порталов. Композит — однозначная поверхность: между
  траншеей подхода (полотно на глубине забоя) и нетронутым холмом над
  буром он неизбежно поднимается КРУТЫМ валом прямо через устье трубы —
  закрывает въезд. Убрать вал изменением высот нельзя (поверхность обязана
  подняться), поэтому крутые треугольники в полосе УСТЬЯ вырезаются из
  композита (KeepTriangles), а края выреза закрывает бетон оголовка и
  козырька (EmitPortal). Критерий выреза: центроид треугольника в полосе
  (SURG_OUT снаружи .. SURG_IN внутри бура, |поперёк| <= halfW +
  min(wing,2.5) + 0.5 — ТОЛЬКО устье, откосы траншеи не задеваем: их
  треугольники козырёк не накрывает, были бы голубые дыры) И выше полотна
  на 1.2+ м — полотно и дно траншеи (≈уровень полотна) остаются. }
procedure CarvePortalOpenings(const Specs: TBridgeSpecArray;
  Composite: TGroundCompositeMesh; const AWingLim: TSingleArray;
  LogProc: TLogProc);
var
  Keep: array of Boolean;
  CenX, CenY, CenZ: TSingleArray;
  T, s, nt, idx, inner, e, removed: Integer;
  i0, i1, i2: Integer;
  P0, P1, P2: TVector3;
  cx, cy, cz, along, lat, halfW, bandW, deckY: Single;
  dx, dz, px, pz, dl: Single;
begin
  if Composite = nil then Exit;
  nt := Composite.TriangleCount;
  if nt = 0 then Exit;
  SetLength(Keep, nt);
  for T := 0 to nt - 1 do Keep[T] := True;
  removed := 0;
  { центроиды треугольников — один раз (раньше PositionOf пересчитывался
    для каждого из 2×Specs порталов) }
  SetLength(CenX, nt); SetLength(CenY, nt); SetLength(CenZ, nt);
  for T := 0 to nt - 1 do
  begin
    i0 := Composite.Indices[T*3];
    i1 := Composite.Indices[T*3+1];
    i2 := Composite.Indices[T*3+2];
    P0 := Composite.PositionOf(i0);
    P1 := Composite.PositionOf(i1);
    P2 := Composite.PositionOf(i2);
    CenX[T] := (P0.X + P1.X + P2.X) / 3.0;
    CenY[T] := (P0.Y + P1.Y + P2.Y) / 3.0;
    CenZ[T] := (P0.Z + P1.Z + P2.Z) / 3.0;
  end;
  for s := 0 to High(Specs) do
  begin
    if Length(Specs[s].Center) < 2 then Continue;
    halfW := Specs[s].Width * 0.5;
    if halfW < 0.8 then halfW := 0.8;
    for idx := 0 to High(Specs[s].Center) do
      if (idx = 0) or (idx = High(Specs[s].Center)) then
      begin
        if idx = 0 then begin inner := 1; e := 0; end
        else begin inner := idx - 1; e := 1; end;
        bandW := halfW + 2.5;
        if (AWingLim <> nil) and (s * 2 + e < Length(AWingLim))
           and (AWingLim[s*2+e] + 0.5 < bandW - halfW) then
          bandW := halfW + AWingLim[s*2+e] + 0.5;
        { направление ВНУТРЬ бура от торца }
        dx := Specs[s].Center[inner].X - Specs[s].Center[idx].X;
        dz := Specs[s].Center[inner].Z - Specs[s].Center[idx].Z;
        dl := Sqrt(dx*dx + dz*dz);
        if dl < 1e-9 then Continue;
        dx := dx/dl; dz := dz/dl;
        px := dz; pz := -dx;
        deckY := Specs[s].CenterY[idx];
        for T := 0 to nt - 1 do
          if Keep[T] then
          begin
            cx := CenX[T];
            cy := CenY[T];
            cz := CenZ[T];
            if cy <= deckY + 1.2 then Continue;   { полотно/дно — не трогаем }
            along := (cx - Single(Specs[s].Center[idx].X)) * dx
                   + (cz - Single(Specs[s].Center[idx].Z)) * dz;
            if (along < -TUNNEL_SURG_OUT_M) or (along > TUNNEL_SURG_IN_M) then Continue;
            lat := (cx - Single(Specs[s].Center[idx].X)) * px
                 + (cz - Single(Specs[s].Center[idx].Z)) * pz;
            if (lat > bandW) or (lat < -bandW) then Continue;
            Keep[T] := False;
            Inc(removed);
          end;
      end;
  end;
  if removed > 0 then
    Composite.KeepTriangles(Keep);
  if Assigned(LogProc) then
    LogProc(Format('Osm3dGeomTunnels: portal openings: %d composite tris carved',
      [removed]));
end;

{ ------------------------------------------------------------- TTunnelBuilder }

class function TTunnelBuilder.Collect(Dataset: TOSMDataset;
  Projection: TLocalProjection; Sampler: TTerrainSampler; LogProc: TLogProc;
  AFitLayer: TFitHeightLayer;
  out AApproachSegs: TTunnelApproachSegArray;
  out APortalTerr: TSingleArray): TBridgeSpecArray;
var
  Way: TOSMWay;
  Params: TRoadParams;
  Mat: TGroundMaterialId;
  Node: TOSMNode;
  Pr: TVector3;
  C, CDeck: TXZArray;
  CDeckY, Acc, FitY, DFromS: TSingleArray;
  FitOk: array of Boolean;
  i, k, kd, count, f0, l0: Integer;
  nApp: Integer;
  lastX, lastZ: Single;
  ddx, ddz, ddy, total: Single;
  sOdx, sOdz, eOdx, eOdz, ol2: Double;
  haveLast, anyFit: Boolean;
  Ybore, teS, teE, rampTan, hh, yR, dep, terr: Single;
  LL: TLatLon;
  dy: Double;
  Spec: TBridgeSpec;
  nFit: Integer;

  { Рельеф под полотном в (cx,cz) с поперечником (dirx,dirz): максимум по оси
    и обоим краям — зеркало HMaxAcross мостов: забой и габарит торцов меряем
    по самому высокому краю, чтобы стена не ушла под склон. }
  function HMaxAcross(cx, cz, dirx, dirz, halfW: Double): Single;
  var dl, ox, oz: Double; hL, hR: Single;
  begin
    Result := SampleTerrainYXZ(Sampler, Projection, Single(cx), Single(cz));
    dl := Sqrt(dirx*dirx + dirz*dirz);
    if (dl < 1e-9) or (halfW <= 0) then Exit;
    ox :=  dirz/dl * halfW;
    oz := -dirx/dl * halfW;
    hL := SampleTerrainYXZ(Sampler, Projection, Single(cx + ox), Single(cz + oz));
    hR := SampleTerrainYXZ(Sampler, Projection, Single(cx - ox), Single(cz - oz));
    if hL > Result then Result := hL;
    if hR > Result then Result := hR;
  end;

  { Рельеф НАД трубой в (cx,cz) с поперечником: МИНИМУМ по оси и краям —
    контроль заглубления полотна: потолок трубы не должен всплывать над
    самым низким местом композита над буром. }
  function HMinAcross(cx, cz, dirx, dirz, halfW: Double): Single;
  var dl, ox, oz: Double; hL, hR: Single;
  begin
    Result := SampleTerrainYXZ(Sampler, Projection, Single(cx), Single(cz));
    dl := Sqrt(dirx*dirx + dirz*dirz);
    if (dl < 1e-9) or (halfW <= 0) then Exit;
    ox :=  dirz/dl * halfW;
    oz := -dirx/dl * halfW;
    hL := SampleTerrainYXZ(Sampler, Projection, Single(cx + ox), Single(cz + oz));
    hR := SampleTerrainYXZ(Sampler, Projection, Single(cx - ox), Single(cz - oz));
    if hL < Result then Result := hL;
    if hR < Result then Result := hR;
  end;

begin
  Result := nil;
  count := 0;
  nFit := 0;
  nApp := 0;  AApproachSegs := nil;  APortalTerr := nil;
  C := nil; CDeck := nil; CDeckY := nil; Acc := nil; FitY := nil;
  DFromS := nil; FitOk := nil;
  if (Dataset = nil) or (Projection = nil) or (Dataset.Ways = nil) then Exit;

  for Way in Dataset.Ways.Values do
  begin
    if Way = nil then Continue;
    if not OsmWayIsTunnel(Way.Tags) then Continue;
    Params := TRoadBuilder.ParseRoadParams(Way.Tags);
    { Только автомобильные дороги: метро/жд (rkRailway: subway/tram/rail/...),
      пешеходные подземные переходы (rkFootway), вело- (rkCycleway) и
      грунтовые дорожки не строим; building_passage — проезд сквозь здание
      в уровне земли, а не бур — тоже мимо }
    if not (Params.Kind in [rkMajor, rkSecondary, rkMinor, rkService]) then Continue;
    if Way.Tags.GetLower('tunnel') = 'building_passage' then Continue;
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

    { длина пути + пробег от начала (для съездов и V-развёртки) }
    SetLength(DFromS, k);
    DFromS[0] := 0.0;
    total := 0.0;
    for i := 1 to k - 1 do
    begin
      ddx := Single(C[i].X - C[i-1].X);
      ddz := Single(C[i].Z - C[i-1].Z);
      total := total + Sqrt(ddx*ddx + ddz*ddz);
      DFromS[i] := total;
    end;
    if total < TUNNEL_MIN_LEN_M then Continue;

    { направления наружу на концах (для пяток-перекрытий) }
    sOdx := C[0].X - C[1].X; sOdz := C[0].Z - C[1].Z;
    ol2 := Sqrt(sOdx*sOdx + sOdz*sOdz);
    if ol2 > 1e-9 then begin sOdx := sOdx/ol2; sOdz := sOdz/ol2; end else begin sOdx := 0.0; sOdz := 0.0; end;
    eOdx := C[k-1].X - C[k-2].X; eOdz := C[k-1].Z - C[k-2].Z;
    ol2 := Sqrt(eOdx*eOdx + eOdz*eOdz);
    if ol2 > 1e-9 then begin eOdx := eOdx/ol2; eOdz := eOdz/ol2; end else begin eOdx := 0.0; eOdz := 0.0; end;

    { FIT-профиль полотна (уровень, где реально ехали): нижний уровень слоя —
      дорога в трубе, пока рельеф сверху остаётся сырым холмом. }
    SetLength(FitY, k);
    SetLength(FitOk, k);
    anyFit := False;
    if (AFitLayer <> nil) and AFitLayer.Active then
      for i := 0 to k - 1 do
      begin
        LL := Projection.Unproject(Single(C[i].X), Single(C[i].Z));
        FitOk[i] := AFitLayer.RoadTargetGeo(LL, dy);
        if FitOk[i] then
        begin
          FitY[i] := Single(dy);
          anyFit := True;
        end;
      end;

    { Габариты земли на торцах — всегда (база забоя и подходных съездов). }
    teS := HMaxAcross(C[0].X, C[0].Z, C[1].X - C[0].X, C[1].Z - C[0].Z,
      Params.Width * 0.5);
    teE := HMaxAcross(C[k-1].X, C[k-1].Z, C[k-1].X - C[k-2].X, C[k-1].Z - C[k-2].Z,
      Params.Width * 0.5);
    rampTan := Tan(TUNNEL_RAMP_SLOPE_DEG * Pi / 180.0);
    if rampTan < 1e-4 then rampTan := 1e-4;

    SetLength(CDeckY, k);
    if anyFit then
    begin
      { пропуски заполняем ближайшим валидным: голова — первым, хвост —
        последним, середина — вперёд по ходу. }
      f0 := 0; while (f0 < k) and not FitOk[f0] do Inc(f0);
      l0 := k - 1; while (l0 >= 0) and not FitOk[l0] do Dec(l0);
      for i := 0 to f0 do FitY[i] := FitY[f0];
      for i := k - 1 downto l0 do FitY[i] := FitY[l0];
      for i := f0 + 1 to l0 - 1 do
        if not FitOk[i] then FitY[i] := FitY[i - 1];
      for i := 0 to k - 1 do CDeckY[i] := FitY[i];
      Inc(nFit);
    end
    else
    begin
      { Без FIT: ровный забой — нижний из портальных габаритов минус глубина
        заложения трубы; локальные впадины рельефа над буром дожмет
        cap-проход ниже. Съезд наружу — подходная траншея (AApproachSegs),
        внутри трубы пандуса больше нет. }
      Ybore := teS; if teE < Ybore then Ybore := teE;
      Ybore := Ybore - TUNNEL_DECK_DEPTH_M;
      for i := 0 to k - 1 do CDeckY[i] := Ybore;
    end;

    { Полотно — НИЖЕ композита земли: потолок трубы (полотно + CLEAR) не
      должен всплывать над рельефом. Режем на полную глубину заложения от
      самого портала — ныряние делает подходная траншея СНАРУЖИ (см. ниже),
      поэтому и у торца полотно уже на глубине. Режет оба режима:
      FIT-профиль в трубе обычно держится у поверхности (GPS/баро под
      землёй не ныряет), без этого реза труба лежала бы на уровне дороги. }
    for i := 0 to k - 1 do
    begin
      if i = 0 then
        terr := teS
      else if i = k - 1 then
        terr := teE
      else
        terr := HMinAcross(C[i].X, C[i].Z, C[i+1].X - C[i-1].X, C[i+1].Z - C[i-1].Z,
          Params.Width * 0.5);
      yR := terr - TUNNEL_DECK_DEPTH_M;
      if CDeckY[i] > yR then CDeckY[i] := yR;
    end;

    { Подходные съезды: траншея от рельефа до глубины забоя ДО портала
      (пандус TUNNEL_RAMP_SLOPE_DEG снаружи). LevelRoadsInComposite тянет
      по ним выемку в композите — полотно ныряет под землю до трубы.
      Высота у портала = фактическая высота полотна (после cap-прохода),
      у внешнего конца — рельеф: стык с обеих сторон непрерывен. }
    if (sOdx <> 0.0) or (sOdz <> 0.0) then
    begin
      dep := teS - CDeckY[0];
      if dep < 0.5 then dep := 0.5;
      hh := dep / rampTan + TUNNEL_DECK_OVERLAP_M;
      if nApp >= Length(AApproachSegs) then
        SetLength(AApproachSegs, nApp + 16);
      AApproachSegs[nApp].Seg.X0 := C[0].X + sOdx * hh;
      AApproachSegs[nApp].Seg.Z0 := C[0].Z + sOdz * hh;
      AApproachSegs[nApp].Seg.X1 := C[0].X;
      AApproachSegs[nApp].Seg.Z1 := C[0].Z;
      AApproachSegs[nApp].Seg.Width    := Params.Width;
      AApproachSegs[nApp].Seg.WayId    := Way.Id;
      AApproachSegs[nApp].Seg.IsBridge := False;
      AApproachSegs[nApp].H0 := HMaxAcross(AApproachSegs[nApp].Seg.X0,
        AApproachSegs[nApp].Seg.Z0, C[1].X - C[0].X, C[1].Z - C[0].Z,
        Params.Width * 0.5);
      AApproachSegs[nApp].H1 := CDeckY[0];
      Inc(nApp);
    end;
    if (eOdx <> 0.0) or (eOdz <> 0.0) then
    begin
      dep := teE - CDeckY[k-1];
      if dep < 0.5 then dep := 0.5;
      hh := dep / rampTan + TUNNEL_DECK_OVERLAP_M;
      if nApp >= Length(AApproachSegs) then
        SetLength(AApproachSegs, nApp + 16);
      AApproachSegs[nApp].Seg.X0 := C[k-1].X;
      AApproachSegs[nApp].Seg.Z0 := C[k-1].Z;
      AApproachSegs[nApp].Seg.X1 := C[k-1].X + eOdx * hh;
      AApproachSegs[nApp].Seg.Z1 := C[k-1].Z + eOdz * hh;
      AApproachSegs[nApp].Seg.Width    := Params.Width;
      AApproachSegs[nApp].Seg.WayId    := Way.Id;
      AApproachSegs[nApp].Seg.IsBridge := False;
      AApproachSegs[nApp].H0 := CDeckY[k-1];
      AApproachSegs[nApp].H1 := HMaxAcross(AApproachSegs[nApp].Seg.X1,
        AApproachSegs[nApp].Seg.Z1, C[k-1].X - C[k-2].X, C[k-1].Z - C[k-2].Z,
        Params.Width * 0.5);
      Inc(nApp);
    end;

    { Сборка осевой полотна: пятка-перекрытие на подход (на уровне кромки
      полотна у торца + микролифт против z-fight), сам путь, вторая пятка. }
    SetLength(CDeck, k + 2);
    SetLength(Acc, k + 2);
    kd := 0;
    CDeck[kd].X := C[0].X + sOdx * TUNNEL_DECK_OVERLAP_M;
    CDeck[kd].Z := C[0].Z + sOdz * TUNNEL_DECK_OVERLAP_M;
    Inc(kd);
    for i := 0 to k - 1 do
    begin
      CDeck[kd] := C[i];
      Inc(kd);
    end;
    CDeck[kd].X := C[k-1].X + eOdx * TUNNEL_DECK_OVERLAP_M;
    CDeck[kd].Z := C[k-1].Z + eOdz * TUNNEL_DECK_OVERLAP_M;
    Inc(kd);
    { высоты сдвигаем на одну позицию (пятка в голове), пятки — на уровне
      кромки торца + лифт }
    SetLength(CDeckY, kd);
    for i := k - 1 downto 0 do CDeckY[i + 1] := CDeckY[i];
    CDeckY[0]      := CDeckY[1]      + TUNNEL_DECK_LIFT_M;
    CDeckY[kd - 1] := CDeckY[kd - 2] + TUNNEL_DECK_LIFT_M;

    { накопленная длина вдоль 3D-осевой — для V-развёртки полотна }
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
    Spec.Num      := count;
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
    Spec.ApprStartWayId := 0;   { подрезки подходов у туннелей нет }
    Spec.ApprEndWayId   := 0;
    Spec.RiverName      := '';
    Spec.WeldJoints     := False;

    if count >= Length(Result) then
      SetLength(Result, (count + 1) * 2);
    Result[count] := Spec;
    if Length(APortalTerr) < (count + 1) * 2 then
      SetLength(APortalTerr, (count + 1) * 2 * 2);
    APortalTerr[count * 2]     := teS;
    APortalTerr[count * 2 + 1] := teE;
    Inc(count);
  end;

  SetLength(Result, count);
  SetLength(AApproachSegs, nApp);
  SetLength(APortalTerr, count * 2);
  if Assigned(LogProc) then
    LogProc(Format('Osm3dGeomTunnels: %d tunnel way(s) collected (%d with FIT profile), %d approach ramp(s)',
      [count, nFit, nApp]));
end;

class procedure TTunnelBuilder.Emit(const Specs: TBridgeSpecArray;
  Composite: TGroundCompositeMesh; var Buildings: TBuildingMeshes;
  const APortalTerr: TSingleArray;
  LogProc: TLogProc);
var
  s, decks, tubes, preWallVerts, preWallTris: Integer;
  preComposVerts, preComposTris: Integer;
  hasTerr: Boolean;
  tS, tE: Single;
  WingLim: TSingleArray;   { [2s]/[2s+1]: ширина крыла оголовка с учётом соседей }
  s2, e, idx, i2: Integer;
  Px, Pz, qx, qz, dx, dz, bl2, bt, bd, d, best: Single;
begin
  if (Composite = nil) or (Length(Specs) = 0) then Exit;
  decks := 0;
  tubes := 0;
  preComposVerts := Composite.VertexCount;
  preComposTris  := Composite.TriangleCount;
  if Buildings.Walls[TUNNEL_WALL_PALETTE] <> nil then
  begin
    preWallVerts := Buildings.Walls[TUNNEL_WALL_PALETTE].VertexCount;
    preWallTris  := Buildings.Walls[TUNNEL_WALL_PALETTE].TriangleCount;
  end
  else
  begin
    preWallVerts := 0;
    preWallTris  := 0;
  end;

  { Лимиты крыльев оголовков: крыло не должно перекрывать проём СОСЕДНЕГО
    бура (двухпутные туннели идут рядом). Лимит = зазор до ближайшей чужой
    осевой минус её и своя полуширина, минус 0.3 м; не уже фланца. }
  SetLength(WingLim, Length(Specs) * 2);
  for s := 0 to High(Specs) do
    for e := 0 to 1 do
    begin
      if e = 0 then idx := 0 else idx := High(Specs[s].Center);
      Px := Single(Specs[s].Center[idx].X);
      Pz := Single(Specs[s].Center[idx].Z);
      best := TUNNEL_PORTAL_WING_M;
      for s2 := 0 to High(Specs) do
        if s2 <> s then
          for i2 := 0 to High(Specs[s2].Center) - 1 do
          begin
            dx := Single(Specs[s2].Center[i2+1].X - Specs[s2].Center[i2].X);
            dz := Single(Specs[s2].Center[i2+1].Z - Specs[s2].Center[i2].Z);
            bl2 := dx*dx + dz*dz;
            if bl2 < 1e-9 then bt := 0
            else bt := ((Px - Single(Specs[s2].Center[i2].X))*dx
                      + (Pz - Single(Specs[s2].Center[i2].Z))*dz) / bl2;
            if bt < 0 then bt := 0 else if bt > 1 then bt := 1;
            qx := Single(Specs[s2].Center[i2].X) + bt*dx;
            qz := Single(Specs[s2].Center[i2].Z) + bt*dz;
            bd := Sqrt((Px-qx)*(Px-qx) + (Pz-qz)*(Pz-qz));
            d := bd - Specs[s2].Width*0.5 - Specs[s].Width*0.5 - 0.3;
            if d < best then best := d;
          end;
      if best < TUNNEL_PORTAL_FLANGE_M then best := TUNNEL_PORTAL_FLANGE_M;
      WingLim[s*2+e] := best;
    end;

  { хирургия проёмов — ДО полотен и труб: вырезанные треугольники — старый
    композит (подъём у портала); полотна допишутся ниже и под нож не
    попадают (дно траншеи ≈уровень полотна — ниже порога 1.2 м) }
  CarvePortalOpenings(Specs, Composite, WingLim, LogProc);

  for s := 0 to High(Specs) do
  begin
    TBridgeBuilder.EmitDeck(Specs[s], Composite);   { нижнее полотно }
    Inc(decks);
    hasTerr := (APortalTerr <> nil)
      and (Specs[s].Num >= 0) and (Specs[s].Num * 2 + 1 < Length(APortalTerr));
    if hasTerr then
    begin
      tS := APortalTerr[Specs[s].Num * 2];
      tE := APortalTerr[Specs[s].Num * 2 + 1];
    end
    else
    begin
      tS := 0; tE := 0;
    end;
    EmitTube(Specs[s], Buildings, tS, tE, hasTerr,
      WingLim[s*2], WingLim[s*2+1]);   { бетонная обделка }
    Inc(tubes);
  end;

  { полотно дописано в композит — вернуть массивы к точной длине для тайлера }
  Composite.TrimArrays;

  if Assigned(LogProc) then
  begin
    if Buildings.Walls[TUNNEL_WALL_PALETTE] <> nil then
      LogProc(Format('Osm3dGeomTunnels: %d deck(s) +%d верш / +%d тре в композит; ' +
        '%d tube(s) +%d верш / +%d тре в Walls[бетон] (всего %d верш / %d тре)',
        [decks, Composite.VertexCount - preComposVerts,
         Composite.TriangleCount - preComposTris, tubes,
         Buildings.Walls[TUNNEL_WALL_PALETTE].VertexCount - preWallVerts,
         Buildings.Walls[TUNNEL_WALL_PALETTE].TriangleCount - preWallTris,
         Buildings.Walls[TUNNEL_WALL_PALETTE].VertexCount,
         Buildings.Walls[TUNNEL_WALL_PALETTE].TriangleCount]))
    else
      LogProc(Format('Osm3dGeomTunnels: %d deck(s) +%d верш / +%d тре в композит; обделка не вышла',
        [decks, Composite.VertexCount - preComposVerts,
         Composite.TriangleCount - preComposTris]));
  end;
end;

end.
