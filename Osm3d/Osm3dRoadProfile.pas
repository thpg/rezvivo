unit Osm3dRoadProfile;

{$mode objfpc}{$H+}

{ ═══ Продольное сглаживание высотного профиля дорог ═══════════════════

  Зачем. Источник высот (Terrarium, ~19 м/px + метровая квантизация +
  SRTM-качество) несёт вдоль дорог шум σ≈1.5–3 м на базе 50–200 м.
  Меш террейна, лента дороги (она КЛИПАЕТСЯ по треугольникам решётки),
  carve и физика — все наследуют этот шум: замер по реальному заезду
  дал набор высоты «по дороге» ×1.9 против барометра. Реальное полотно
  так не выглядит: дороги строятся с нормируемым продольным уклоном и
  вертикальными кривыми — профиль полотна низкочастотен по построению.

  Что делает. ДО построения меша (единственная точка, где правка
  согласует сразу всё: меш, сэмплер, ленту, carve, воду — они читают
  один и тот же хайтмэп) высоты хайтмэпа в коридорах автодорог
  заменяются продольно сглаженным профилем оси way:

    ось way → дуговая параметризация → профиль h(s) билинейно из HM →
    локальная линейная регрессия окном ±HALF_WINDOW_M →
    запись в полосу ширины дороги с поперечным косинус-спадом
    к нетронутому рельефу и весовым аккумулятором (перекрёстки —
    среднее профилей, а не «кто последний»).

  Шов тайлов. У слепка чанка нет запаса за границей, поэтому вес
  сглаживания вырождается к нулю у края хайтмэпа И у концов way
  (полуокно): на шве соседние чанки видят одинаковые СЫРЫЕ значения и
  свариваются как раньше; сглаживание плавно включается вглубь. Цена —
  ~HALF_WINDOW_M несглаженного профиля у шва; честный компромисс,
  пока слепок не расширен margin-тайлами.

  Мосты и тоннели пропускаются: у моста профиль задаёт настил
  (EmitDeck), у тоннеля рельеф сверху трогать нельзя. }

interface

uses
  Classes, SysUtils, Math,
  Osm3dGeoMath,      { TLatLon, TLocalProjection }
  Osm3dHeightmap,    { THeightmap: Box, Width/Height, Sample[X,Y] r/w }
  Osm3dOsmData;      { TOSMDataset, TOSMWay, TOSMNode, TOSMTags }

{ Сгладить профили дорог на хайтмэпе. Возвращает строку статистики
  для лога вызывающего («ways 41, px 18632» / «skipped: no data»).
  Безопасна к nil-аргументам (no-op). }
function SmoothRoadProfilesOnHeightmap(HM: THeightmap;
  Dataset: TOSMDataset; Projection: TLocalProjection;
  HeightmapZoom: Integer): string;

implementation

const
  { Полуокно продольной регрессии, м. Полное окно ~400 м — по нашим
    замерам паразитный шум поверхности жив до ~200–400 м (масштабный
    анализ σΔ), а масштаб вертикальных кривых загородных дорог его
    покрывает, так что реальный рельеф не срезается. }
  HALF_WINDOW_M = 200.0;

  { Полумедиана предочистки: перед регрессией сырой профиль по дуге
    прогоняется медианой окном (2·MEDIAN_HALF+1) отсчётов — сбивает
    одиночные пиксельные выбросы SRTM, которые иначе тянут МНК. }
  MEDIAN_HALF = 2;

  { Поперечный спад за кромкой полосы, в пикселях хайтмэпа. }
  FEATHER_PX = 2.5;

  { Ниже этого веса пиксель считается незатронутым. }
  MIN_ACC_W = 1e-3;

type
  TDoubleArray = array of Double;

{ Полная ширина полотна по классу highway, м. Числа — практичные
  дефолты в духе HighwayDefaults (Osm3dGeomRoads); собственная
  таблица, чтобы юнит не тянул весь дорожный конвейер. }
function RoadFullWidth(const Hw: string): Single;
begin
  if (Hw = 'motorway') or (Hw = 'motorway_link') then Exit(14.0);
  if (Hw = 'trunk') or (Hw = 'trunk_link') then Exit(12.0);
  if (Hw = 'primary') or (Hw = 'primary_link') then Exit(10.0);
  if (Hw = 'secondary') or (Hw = 'secondary_link') then Exit(9.0);
  if (Hw = 'tertiary') or (Hw = 'tertiary_link') then Exit(8.0);
  if Hw = 'living_street' then Exit(5.0);
  if Hw = 'service' then Exit(4.0);
  if Hw = 'track' then Exit(3.5);
  if (Hw = 'cycleway') or (Hw = 'footway') or (Hw = 'path')
     or (Hw = 'pedestrian') or (Hw = 'bridleway') then Exit(2.5);
  Result := 6.0;   { unclassified / residential / прочее }
end;

function SmoothRoadProfilesOnHeightmap(HM: THeightmap;
  Dataset: TOSMDataset; Projection: TLocalProjection;
  HeightmapZoom: Integer): string;
var
  W, H: Integer;
  WorldPx, GPX0, GPY0, PxM: Double;
  AccW, AccH: array of Single;
  WaysDone, WaysSkip, PxTouched: Integer;

  { lat/lon → пиксель слепка. Формулы — зеркало TerrainGridOf /
    TerrainGridNodeLatLon (Osm3dGeomTerrain): lon линеен в глобальной
    slippy-сетке, lat через Web-Mercator forward; фаза GPX0/GPY0 — от
    границ слепка (границы = целые тайлы, округление точное). }
  procedure LatLonToPx(const P: TLatLon; out PX, PY: Double);
  begin
    PX := (P.Lon + 180.0) / 360.0 * WorldPx - GPX0;
    PY := (1.0 - Ln(Tan(P.Lat * Pi / 180.0)
            + 1.0 / Cos(P.Lat * Pi / 180.0)) / Pi) / 2.0 * WorldPx
          - GPY0;
  end;

  function SampleBil(PX, PY: Double): Single;
  var
    X0, Y0: Integer;
    FX, FY: Double;
  begin
    if PX < 0 then PX := 0;
    if PY < 0 then PY := 0;
    if PX > W - 1 then PX := W - 1;
    if PY > H - 1 then PY := H - 1;
    X0 := Trunc(PX);
    Y0 := Trunc(PY);
    if X0 > W - 2 then X0 := W - 2;
    if Y0 > H - 2 then Y0 := H - 2;
    FX := PX - X0;
    FY := PY - Y0;
    Result :=
      (1 - FX) * (1 - FY) * HM.Sample[X0,     Y0    ] +
      FX       * (1 - FY) * HM.Sample[X0 + 1, Y0    ] +
      (1 - FX) * FY       * HM.Sample[X0,     Y0 + 1] +
      FX       * FY       * HM.Sample[X0 + 1, Y0 + 1];
  end;

  procedure ProcessWay(Way: TOSMWay);
  var
    Hw: string;
    NPts, I, K, J, NS: Integer;
    Node: TOSMNode;
    PX, PY: TDoubleArray;          { полилиния оси, px }
    S: TDoubleArray;               { дуга, м }
    QX, QY, SQ, HRaw, HSm, WFade: TDoubleArray;
    DS, Total, T, SegLen: Double;
    HalfWM, HalfWPx, FeatherM: Double;
    S0, S1, SW, SWX, SWXX, SWY, SWXY, WgtJ, XJ, Det: Double;
    EdgeD, EndD: Double;
    X0i, X1i, Y0i, Y1i, XPix, YPix: Integer;
    NW: Integer;
    MedBuf: array[0 .. 2 * MEDIAN_HALF] of Double;
    AXd, AYd, BXd, BYd, EXd, EYd, LL2, TT, DXp, DYp, DPerp, WLat,
      HT, WPix: Double;
  begin
    Hw := Way.Tags.GetLower('highway');
    if (Hw = '') or (Hw = 'proposed') or (Hw = 'construction')
       or (Hw = 'steps') then
    begin
      Inc(WaysSkip);
      Exit;
    end;
    { мост/тоннель: профиль не наш (настил / рельеф сверху) }
    if (Way.Tags.GetLower('bridge') <> '') and
       (Way.Tags.GetLower('bridge') <> 'no') then
    begin
      Inc(WaysSkip);
      Exit;
    end;
    if (Way.Tags.GetLower('tunnel') <> '') and
       (Way.Tags.GetLower('tunnel') <> 'no') then
    begin
      Inc(WaysSkip);
      Exit;
    end;
    if Way.Tags.HasKeyValue('area', 'yes') then
    begin
      Inc(WaysSkip);
      Exit;
    end;

    { полилиния в пикселях слепка }
    SetLength(PX, Length(Way.NodeRefs));
    SetLength(PY, Length(Way.NodeRefs));
    NPts := 0;
    for I := 0 to High(Way.NodeRefs) do
      if Dataset.Nodes.TryGetValue(Way.NodeRefs[I], Node) and
         (Node <> nil) then
      begin
        LatLonToPx(Node.Position, PX[NPts], PY[NPts]);
        Inc(NPts);
      end;
    if NPts < 2 then
    begin
      Inc(WaysSkip);
      Exit;
    end;

    { дуга (метры) }
    SetLength(S, NPts);
    S[0] := 0;
    for I := 1 to NPts - 1 do
      S[I] := S[I - 1] +
        Sqrt(Sqr(PX[I] - PX[I - 1]) + Sqr(PY[I] - PY[I - 1])) * PxM;
    Total := S[NPts - 1];
    if Total < 4.0 then
    begin
      Inc(WaysSkip);
      Exit;
    end;

    { ресемпл оси шагом ~DS (не мельче пикселя источника) }
    DS := Max(PxM * 0.75, 5.0);
    NS := Max(2, Trunc(Total / DS) + 1);
    SetLength(QX, NS);
    SetLength(QY, NS);
    SetLength(SQ, NS);
    SetLength(HRaw, NS);
    SetLength(HSm, NS);   { служит буфером и для медианы, и для профиля }
    SetLength(WFade, NS);
    K := 0;
    for I := 0 to NS - 1 do
    begin
      SQ[I] := Total * I / (NS - 1);
      while (K < NPts - 2) and (S[K + 1] < SQ[I]) do
        Inc(K);
      SegLen := S[K + 1] - S[K];
      if SegLen > 1e-9 then
        T := (SQ[I] - S[K]) / SegLen
      else
        T := 0;
      QX[I] := PX[K] + (PX[K + 1] - PX[K]) * T;
      QY[I] := PY[K] + (PY[K + 1] - PY[K]) * T;
      HRaw[I] := SampleBil(QX[I], QY[I]);

      { вес сглаживания: 0 у края слепка и у концов way (шов/перекрёсток
        остаются сырыми и потому детерминированно совпадают у соседей) }
      EdgeD := Min(Min(QX[I], W - 1 - QX[I]),
                   Min(QY[I], H - 1 - QY[I])) * PxM;
      EndD := Min(SQ[I], Total - SQ[I]);
      WFade[I] := Min(1.0, Max(0.0, EdgeD / HALF_WINDOW_M)) *
                  Min(1.0, Max(0.0, EndD / HALF_WINDOW_M));
    end;

    { Предочистка: медиана окном (2·MEDIAN_HALF+1) по дуге сбивает
      одиночные пиксельные выбросы SRTM до регрессии (в HSm как буфер,
      затем HRaw := HSm). }
    for I := 0 to NS - 1 do
    begin
      NW := 0;
      for J := Max(0, I - MEDIAN_HALF) to Min(NS - 1, I + MEDIAN_HALF) do
      begin
        MedBuf[NW] := HRaw[J];
        Inc(NW);
      end;
      for J := 1 to NW - 1 do
      begin
        T := MedBuf[J];
        K := J - 1;
        while (K >= 0) and (MedBuf[K] > T) do
        begin
          MedBuf[K + 1] := MedBuf[K];
          Dec(K);
        end;
        MedBuf[K + 1] := T;
      end;
      HSm[I] := MedBuf[NW div 2];
    end;
    for I := 0 to NS - 1 do
      HRaw[I] := HSm[I];

    { продольная локальная линейная регрессия (окно ±HALF_WINDOW_M,
      треугольные веса) — гладкая «вертикальная кривая» через шум }
    for I := 0 to NS - 1 do
    begin
      S0 := SQ[I] - HALF_WINDOW_M;
      S1 := SQ[I] + HALF_WINDOW_M;
      SW := 0; SWX := 0; SWXX := 0; SWY := 0; SWXY := 0;
      for J := Max(0, I - Trunc(HALF_WINDOW_M / DS) - 1) to
               Min(NS - 1, I + Trunc(HALF_WINDOW_M / DS) + 1) do
      begin
        if (SQ[J] < S0) or (SQ[J] > S1) then Continue;
        XJ := SQ[J] - SQ[I];
        WgtJ := 1.0 - Abs(XJ) / HALF_WINDOW_M;
        if WgtJ <= 0 then Continue;
        SW := SW + WgtJ;
        SWX := SWX + WgtJ * XJ;
        SWXX := SWXX + WgtJ * XJ * XJ;
        SWY := SWY + WgtJ * HRaw[J];
        SWXY := SWXY + WgtJ * XJ * HRaw[J];
      end;
      { взвешенная прямая через окно; значение в центре окна.
        (полноценная парабола не нужна: окно симметрично, центрируем) }
      Det := SW * SWXX - SWX * SWX;
      if (SW > 1e-9) and (Abs(Det) > 1e-9) then
        HSm[I] := (SWY * SWXX - SWX * SWXY) / Det
      else
        HSm[I] := HRaw[I];
    end;

    { Сохраняем естественный продольный уклон. Глобальный предел 12%
      распространял высоту начала way на весь горный спуск и поднимал
      землю на сотни метров. Фильтр должен сглаживать шум, сохраняя тренд;
      OSM не задаёт нам проектную отметку дороги или глубину выемки. }
    { запись: полоса halfW с косинус-растушёвкой FEATHER_PX;
      вклад — в аккумулятор (перекрёстки усредняются) }
    HalfWM := RoadFullWidth(Hw) * 0.5 + 1.0;
    HalfWPx := HalfWM / PxM;
    FeatherM := FEATHER_PX * PxM;
    for I := 0 to NS - 2 do
    begin
      if (WFade[I] <= 0) and (WFade[I + 1] <= 0) then Continue;
      AXd := QX[I];     AYd := QY[I];
      BXd := QX[I + 1]; BYd := QY[I + 1];
      X0i := Floor(Min(AXd, BXd) - HalfWPx - FEATHER_PX);
      X1i := Ceil (Max(AXd, BXd) + HalfWPx + FEATHER_PX);
      Y0i := Floor(Min(AYd, BYd) - HalfWPx - FEATHER_PX);
      Y1i := Ceil (Max(AYd, BYd) + HalfWPx + FEATHER_PX);
      if X0i < 0 then X0i := 0;
      if Y0i < 0 then Y0i := 0;
      if X1i > W - 1 then X1i := W - 1;
      if Y1i > H - 1 then Y1i := H - 1;
      EXd := BXd - AXd;
      EYd := BYd - AYd;
      LL2 := EXd * EXd + EYd * EYd;
      if LL2 < 1e-12 then Continue;
      for YPix := Y0i to Y1i do
        for XPix := X0i to X1i do
        begin
          TT := ((XPix - AXd) * EXd + (YPix - AYd) * EYd) / LL2;
          if TT < 0 then TT := 0 else if TT > 1 then TT := 1;
          DXp := XPix - (AXd + EXd * TT);
          DYp := YPix - (AYd + EYd * TT);
          DPerp := Sqrt(DXp * DXp + DYp * DYp) * PxM;
          if DPerp >= HalfWM + FeatherM then Continue;
          if DPerp <= HalfWM then
            WLat := 1.0
          else
            WLat := 0.5 * (1.0 + Cos(Pi * (DPerp - HalfWM) / FeatherM));
          HT := HSm[I] + (HSm[I + 1] - HSm[I]) * TT;
          WPix := WLat * (WFade[I] + (WFade[I + 1] - WFade[I]) * TT);
          if WPix <= 0 then Continue;
          AccW[YPix * W + XPix] := AccW[YPix * W + XPix] + WPix;
          AccH[YPix * W + XPix] := AccH[YPix * W + XPix] + WPix * HT;
        end;
    end;
    Inc(WaysDone);
  end;

var
  Way: TOSMWay;
  Idx: Integer;
  Alpha, V: Double;
begin
  Result := 'skipped: no data';
  if (HM = nil) or (Dataset = nil) or (Projection = nil) then Exit;
  W := HM.Width;
  H := HM.Height;
  if (W < 4) or (H < 4) then Exit;
  if HM.Box.IsEmpty then Exit;

  WorldPx := 256.0 * IntPower(2.0, Max(0, Min(22, HeightmapZoom)));
  GPX0 := Round((HM.Box.MinLon + 180.0) / 360.0 * WorldPx);
  GPY0 := Round((1.0 - Ln(Tan(HM.Box.MaxLat * Pi / 180.0)
            + 1.0 / Cos(HM.Box.MaxLat * Pi / 180.0)) / Pi)
          / 2.0 * WorldPx);
  PxM := (360.0 / WorldPx) * Projection.MetersPerDegreeLon;
  if PxM < 1e-6 then Exit;

  SetLength(AccW, W * H);
  SetLength(AccH, W * H);
  FillChar(AccW[0], Length(AccW) * SizeOf(Single), 0);
  FillChar(AccH[0], Length(AccH) * SizeOf(Single), 0);

  WaysDone := 0;
  WaysSkip := 0;
  PxTouched := 0;

  for Way in Dataset.Ways.Values do
  begin
    if Way = nil then Continue;
    ProcessWay(Way);
  end;

  { финальный проход: смесь сырого и профиля по накопленному весу }
  for Idx := 0 to W * H - 1 do
    if AccW[Idx] > MIN_ACC_W then
    begin
      V := AccH[Idx] / AccW[Idx];
      Alpha := AccW[Idx];
      if Alpha > 1.0 then Alpha := 1.0;
      HM.Sample[Idx mod W, Idx div W] :=
        HM.Sample[Idx mod W, Idx div W] * (1.0 - Alpha) + V * Alpha;
      Inc(PxTouched);
    end;

  Result := Format('road profiles: ways %d (skip %d), px %d',
    [WaysDone, WaysSkip, PxTouched]);
end;

end.
