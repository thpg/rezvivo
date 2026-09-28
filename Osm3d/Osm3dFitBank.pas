unit Osm3dFitBank;

{$mode objfpc}{$H+}

{ ═══ Банк заездов: папка FIT/GPX → нивелированные высоты ══════════════

  Роль. Мост между файлами маршрутов и датум-солвером (Osm3dFitDatum):
    • грузит все *.fit/*.gpx из папки заездов;
    • проецирует их точки в общие метры (один центроид на папку —
      тот же фрейм для всех, обязателен для пространственного хэша сети);
    • подставляет DEM-высоту под каждой точкой (слабый арбитр слоя 2);
    • запускает SolveFitDatum и отдаёт приведённые высоты выбранного
      файла (alt_cal = alt_fit − дрейф) для коррекции террейна.

  DEM-вход. Берём тем же методом, что штатная сборка тайлов
  (TTerrariumFetcher.GetRegion — см. Osm3dBlockGenerator): он спускается
  до HTTP/дискового кэша, где высоты после прогрева маршрута уже лежат
  (в сеть не идёт). Регион запрашивается ПЕР-ФАЙЛ — компактный бокс
  каждого заезда, не единый бокс папки. CachedOnly-методы для расчёта
  не годятся: они лишь про RAM-кэш, который пуст, когда тайлы подняты
  с диска, минуя генерацию. DEM-слой сети — длинноволновый арбитр «есть
  склон/нет» (corr Terrarium↔поверхность >0.98). Нет фетчера/региона —
  Dem := Alt (нейтрально: точка без DEM-опоры).

  Владение. Загруженные TFitFile освобождаются внутри. Наружу —
  только числовые массивы. }

interface

uses
  Classes, SysUtils, Math,
  Osm3dGeoMath,       { TLatLon, TLatLonBox, TLocalProjection }
  Osm3dHeightmap,     { THeightmap, THeightmapSampler, TTerrariumFetcher }
  Osm3dFitDatum;      { TFitDatumRide*, SolveFitDatum }

type
  { Результат по одному файлу папки. }
  TFitBankRide = record
    FileName: String;
    Synthetic: Boolean;         { нет записанных высот: профиль из DEM }
    Lat, Lon: array of Double;   { градусы, параллельны Cal }
    AltFit:   array of Double;   { сырая высота FIT }
    AltCal:   array of Double;   { приведённая (датум снят) }
    Dem:      array of Double;   { высота мира под точкой (для классиф. мостов) }
    Drift:    array of Double;   { снятый дрейф c(t) }
    TimeSec:  array of Double;
  end;
  TFitBankRideArray = array of TFitBankRide;

{ Загрузить все *.fit/*.gpx из папки, нивелировать сеть, вернуть результаты.
  ASelectedFile — имя (без пути) выбранного файла; его индекс кладётся
  в OutSelected (−1 если не найден, но нивелирование всё равно идёт).
  AFetcher — источник DEM (может быть nil: тогда Dem := Alt для файлов
  с высотой; файлы без высоты пропускаются, нули не считаются измерениями).
  AHeightmapZoom — зум Terrarium. Возвращает строку статистики.
  AProgCur/AProgTotal — необязательные приёмники прогресса по заездам
  (N из M): пишутся простым присваиванием, читает их главный поток
  только для отображения.
  ACancel — необязательный флаг отмены: проверяется на каждом файле;
  при взводе сборка прерывается досрочно (результат не использовать —
  вызывающий сам проверяет свой cancel-флаг после возврата). Нужен,
  чтобы деструктор карты не ждал полный прогон банка (минуты на
  холодном DEM-кэше: 30+ файлов × GetRegion с HTTP до 30 с/тайл). }
function BuildFitBank(const AFolder, ASelectedFile: String;
  AFetcher: TTerrariumFetcher; AHeightmapZoom: Integer;
  out Rides: TFitBankRideArray; out OutSelected: Integer;
  AProgCur: PInteger = nil; AProgTotal: PInteger = nil;
  ACancel: PBoolean = nil): String;

implementation

uses
  Osm3dMapUtils,      { TRouteSrc.OriginCentroid }
  FitFile,            { TFitFile, ToGeoAltPoints, TFitGeoAltArray }
  GpxFile,            { NewRouteParserForFile: общий вход FIT/GPX }
  Osm3dDemProfile;    { тот же профиль без высот, что в FitLayerBuild }

function BuildFitBankCancelled(ACancel: PBoolean): Boolean; inline;
begin
  Result := (ACancel <> nil) and ACancel^;
end;

function BuildFitBank(const AFolder, ASelectedFile: String;
  AFetcher: TTerrariumFetcher; AHeightmapZoom: Integer;
  out Rides: TFitBankRideArray; out OutSelected: Integer;
  AProgCur: PInteger = nil; AProgTotal: PInteger = nil;
  ACancel: PBoolean = nil): String;
var
  Sr: TSearchRec;
  Names: TStringList;
  Geos: array of TFitGeoAltArray;
  Synthetic: array of Boolean;
  SyntheticDem: array of TDemProfileArr;
  DistArr, DemArr, SynArr: TDemProfileArr;
  AllLL: array of TLatLon;
  Origin: TLatLon;
  Proj: TLocalProjection;
  DatumRides: TFitDatumRideArray;
  Fit: TFitFile;
  I, K, R, NR, Nc, DemHit, DemMiss, NSynthetic, NNoHeight: Integer;
  RideBox: TLatLonBox;
  Hm: THeightmap;
  Stat, Mask: String;
begin
  OutSelected := -1;
  SetLength(Rides, 0);
  Names := TStringList.Create;
  try
    { Тот же набор форматов, что у слоя высот и загрузчика маршрутов. }
    for I := 0 to 1 do
    begin
      if I = 0 then Mask := '*.fit' else Mask := '*.gpx';
      if FindFirst(IncludeTrailingPathDelimiter(AFolder) + Mask,
        faAnyFile, Sr) = 0 then
      begin
        repeat
          if (Sr.Attr and faDirectory) = 0 then Names.Add(Sr.Name);
        until FindNext(Sr) <> 0;
        FindClose(Sr);
      end;
    end;
    Names.Sort;
    if Names.Count = 0 then Exit('fit bank: no *.fit/*.gpx in ' + AFolder);

    { загрузка геоточек по файлам + общий пул для центроида }
    SetLength(Geos, Names.Count);
    SetLength(Synthetic, Names.Count);
    SetLength(SyntheticDem, Names.Count);
    SetLength(AllLL, 0);
    for I := 0 to Names.Count - 1 do
    begin
      if BuildFitBankCancelled(ACancel) then
        Exit('fit bank: cancelled');
      Fit := NewRouteParserForFile(
        IncludeTrailingPathDelimiter(AFolder) + Names[I]);
      try
        if Fit.LoadFromFile(
          IncludeTrailingPathDelimiter(AFolder) + Names[I]) then
        begin
          Geos[I] := Fit.ToGeoAltPoints;
          Synthetic[I] := not Fit.HasAltitude;
        end
        else
          SetLength(Geos[I], 0);
      finally
        Fit.Free;
      end;
      Nc := Length(AllLL);
      SetLength(AllLL, Nc + Length(Geos[I]));
      for K := 0 to High(Geos[I]) do
        AllLL[Nc + K] := TLatLon.Make(Geos[I][K].Lat, Geos[I][K].Lon);
    end;
    if Length(AllLL) < 2 then Exit('fit bank: no geo points');

    Origin := TRouteSrc.OriginCentroid(AllLL);
    Proj := TLocalProjection.Create(Origin);
    try
      { сборка входа датум-сети. DEM берём тем же методом, что штатная
        сборка тайлов (TTerrariumFetcher.GetRegion — Osm3dBlockGenerator):
        он спускается до HTTP/дискового кэша, где высоты после прогрева
        уже лежат (в сеть не пойдёт). Регион — ПЕР-ФАЙЛ (компактный бокс
        заезда), не единый бокс папки: кэш-локально, без региона «на
        пол-страны». CachedOnly-методы тут нельзя — они лишь про RAM-кэш
        (пуст, когда тайлы поднялись с диска, минуя генерацию). }
      NR := Names.Count;
      DemHit := 0; DemMiss := 0;
      NSynthetic := 0; NNoHeight := 0;
      SetLength(DatumRides, NR);
      { Прогресс для оверлея прогрева: пишем простым присваиванием
        (читает только main и только для отображения «N / M»). }
      if AProgTotal <> nil then AProgTotal^ := NR;
      for R := 0 to NR - 1 do
      begin
        if BuildFitBankCancelled(ACancel) then
          Exit('fit bank: cancelled');
        { бокс этого заезда }
        RideBox := TLatLonBox.Empty;
        for K := 0 to High(Geos[R]) do
          RideBox := RideBox.Include(
            TLatLon.Make(Geos[R][K].Lat, Geos[R][K].Lon));
        Hm := nil;
        if (AFetcher <> nil) and (Length(Geos[R]) > 0) then
        begin
          RideBox := RideBox.ExpandMeters(50.0);
          Hm := AFetcher.GetRegion(RideBox, AHeightmapZoom, ACancel);
        end;
        if Hm <> nil then Inc(DemHit) else Inc(DemMiss);

        if Synthetic[R] and (Hm = nil) then
        begin
          { Нет ни измерений, ни DEM: не отдаём фиктивный нулевой профиль. }
          SetLength(Geos[R], 0);
          Inc(NNoHeight);
        end;
        SetLength(DatumRides[R].Points, Length(Geos[R]));
        for K := 0 to High(Geos[R]) do
        begin
          DatumRides[R].Points[K].X :=
            Proj.Project(Geos[R][K].Lat, Geos[R][K].Lon).X;
          DatumRides[R].Points[K].Z :=
            Proj.Project(Geos[R][K].Lat, Geos[R][K].Lon).Z;
          DatumRides[R].Points[K].Alt := Geos[R][K].AltM;
          DatumRides[R].Points[K].T   := Geos[R][K].TimeSec;
          if Hm <> nil then
            DatumRides[R].Points[K].Dem := THeightmapSampler.SampleBilinear(
              Hm, TLatLon.Make(Geos[R][K].Lat, Geos[R][K].Lon))
          else
            { нет DEM — нейтрально: точка без DEM-опоры }
            DatumRides[R].Points[K].Dem := Geos[R][K].AltM;
        end;
        if Hm <> nil then Hm.Free;
        if Synthetic[R] and (Length(Geos[R]) > 0) then
        begin
          Nc := Length(Geos[R]);
          SetLength(DistArr, Nc);
          SetLength(DemArr, Nc);
          DistArr[0] := 0;
          for K := 0 to Nc - 1 do
          begin
            if K > 0 then
              DistArr[K] := DistArr[K - 1] + Hypot(
                DatumRides[R].Points[K].X - DatumRides[R].Points[K - 1].X,
                DatumRides[R].Points[K].Z - DatumRides[R].Points[K - 1].Z);
            DemArr[K] := DatumRides[R].Points[K].Dem;
          end;
          SmoothProfile(DistArr, DemArr, SynArr);
          SyntheticDem[R] := Copy(DemArr, 0, Nc);
          for K := 0 to Nc - 1 do Geos[R][K].AltM := SynArr[K];
          { Синтетика не содержит барометрии и не должна менять датум
            соседних записанных заездов. Результат выдаём после солвера. }
          SetLength(DatumRides[R].Points, 0);
          Inc(NSynthetic);
        end;
        if (Length(Geos[R]) >= 2) and
           SameText(Names[R], ExtractFileName(ASelectedFile)) then
          OutSelected := R;
        if AProgCur <> nil then AProgCur^ := R + 1;   { заезд R обработан }
      end;

      Stat := SolveFitDatum(DatumRides, Max(OutSelected, 0), ACancel);
      if BuildFitBankCancelled(ACancel) then Exit('fit bank: cancelled');

      { вынос результатов наружу }
      SetLength(Rides, NR);
      for R := 0 to NR - 1 do
      begin
        Rides[R].FileName := Names[R];
        Rides[R].Synthetic := Synthetic[R];
        Nc := Length(Geos[R]);
        SetLength(Rides[R].Lat, Nc);
        SetLength(Rides[R].Lon, Nc);
        SetLength(Rides[R].AltFit, Nc);
        SetLength(Rides[R].AltCal, Nc);
        SetLength(Rides[R].Drift, Nc);
        SetLength(Rides[R].Dem, Nc);
        SetLength(Rides[R].TimeSec, Nc);
        for K := 0 to Nc - 1 do
        begin
          Rides[R].Lat[K]     := Geos[R][K].Lat;
          Rides[R].Lon[K]     := Geos[R][K].Lon;
          Rides[R].AltFit[K]  := Geos[R][K].AltM;
          if Synthetic[R] then
          begin
            Rides[R].AltCal[K] := Geos[R][K].AltM;
            Rides[R].Drift[K] := 0;
            Rides[R].Dem[K] := SyntheticDem[R][K];
          end
          else
          begin
            Rides[R].AltCal[K] := DatumRides[R].Cal[K];
            Rides[R].Drift[K] := DatumRides[R].Drift[K];
            Rides[R].Dem[K] := DatumRides[R].Points[K].Dem;
          end;
          Rides[R].TimeSec[K] := Geos[R][K].TimeSec;
        end;
      end;

      Result := Stat + Format(' [DEM regions: %d ok, %d nil; '
        + 'synthetic: %d; no altitude/DEM: %d]',
        [DemHit, DemMiss, NSynthetic, NNoHeight]);
    finally
      Proj.Free;
    end;
  finally
    Names.Free;
  end;
end;

end.
