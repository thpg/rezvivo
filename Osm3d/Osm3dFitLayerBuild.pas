unit Osm3dFitLayerBuild;

{$Q-}{$R-}
{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$codepage UTF8}

{ ═══ Сборка FIT-слоя высот из папки заездов ═══════════════════════════

  Наполняет TFitHeightLayer (Osm3dFitHeightLayer). Для каждого *.fit —
  НЕЗАВИСИМЫЙ пофайловый датум с явным ПРИЗЕМЛЕНИЕМ на DEM:

    1) SolveFitDatum на одном заезде: самоперекрытия (далёкие по времени
       проходы того же места) + DEM-арбитр на одиноких точках + гладкость
       снимают ФОРМУ дрейфа c(t);
    2) приземление: вся кривая сдвигается одной константой так, что
       медиана (cal − dem) по файлу = 0. Уровень файла держит ЗЕМЛЯ, а
       не средний ноль сырого баро (прежний сетевой прогон показал: без
       этого уровень сети = среднее произвольных калибровок барометра,
       депо висело на +15 м над DEM при внутренне сшитой сети). Медиана
       робастна к мостам, прогреву и лесному пологу в DEM.

  Кэш v3: <fit>-fitcache.csv, ПОФАЙЛОВЫЙ — зависит только от своего .fit
  (маркер src=name|mtime): смена одного файла папки пересчитывает только
  его. В кэш пишутся и t_sec, и alt_dem_m — офлайн-анализ уровней и
  будущая МЕЖФАЙЛОВАЯ сшивка (вычисление общего уровня по всем файлам)
  смогут работать прямо из кэшей, без повторного DEM/солвера.

  <fit>-heights.csv (отладочный дамп студии) не читается и не пишется.

  Route-only (AOnlySelected=True): считается/кладётся в слой только
  выбранный заезд — поперечных дорог в нём нет, они остаются без FIT.

  Вынесено из Osm3dFitHeightLayer, чтобы класс-слой не зависел от
  Osm3dHeightmap (иначе цикл модулей с TTerrariumFetcher, который держит
  слой полем). }

interface

uses
  Classes,
  Osm3dGeoMath,        { TLatLon }
  Osm3dHeightmap,      { TTerrariumFetcher }
  Osm3dFitHeightLayer; { TFitHeightLayer, TFitLayerPoint* }

const
  FITL_DEM_ZOOM_DEFAULT = 13;   { зум Terrarium для DEM-арбитра датума }

{ Построить слой из папки. ASelectedFile — выбранный заезд (статистика;
  в route-only — единственный источник точек слоя). AZoom<=0 →
  FITL_DEM_ZOOM_DEFAULT. Возвращает строку статистики; ALog (если задан)
  получает построчный лог. }
function BuildFitHeightLayer(const AFolder, ASelectedFile: string;
  AFetcher: TTerrariumFetcher; AZoom: Integer;
  ALayer: TFitHeightLayer; ALog: TStrings = nil;
  AOnlySelected: Boolean = False): string;

implementation

uses
  SysUtils, Math, StrUtils,   { IfThen(строковый) }
  CastleVectors,       { TVector3 }
  Osm3dMapUtils,       { TRouteSrc.OriginCentroid }
  Osm3dFitDatum,       { TFitDatumRide*, SolveFitDatum }
  FitFile,             { TFitFile, ToGeoAltPoints, TFitGeoAltArray }
  GpxFile,             { NewRouteParserForFile: .fit/.gpx по расширению }
  Osm3dDemProfile,     { SmoothProfile — синтетика высоты из DEM для файлов без ele }
  Osm3dOsmDirectory, md5;

const
  { Маркер версии кэша. Менять при ЛЮБОМ изменении алгоритма нивелирования
    или формата: старые кэши перестанут читаться и пересчитаются.
    v1 (пофайловый без приземления) и v2 (сетевой датум) не читаются по
    несовпадению маркера — их уровни несовместимы с v3. }
  FITC_CACHE_VER = 'fit-height cache v5 (per-file datum, DEM-source and zoom aware)';

  { ── Детектор битой позиции: «датчик скорости/GPS не работал» ───────────
    Признак — ПОЗИЦИЯ СТОИТ, А ВЫСОТА ЕДЕТ: велокомпьютер продолжает писать
    точки в последней известной координате, барометр честно отмеряет реальный
    подъём. Такие точки не просто бесполезны — они ЯДОВИТЫ: кладут столб
    высот в одну плановую точку, датум видит «на одном месте высота гуляет на
    70 м» и раскладывает это в дрейф c(t) по ВСЕМУ файлу (замер по 04-27:
    15 минут неподвижности, разброс барометра 70 м → конец заезда уехал на
    +41 м над DEM при том, что сырой барометр там сходится с DEM в пределах
    метра).

    Обычная стоянка (светофор) выглядит иначе: позиция стоит, высота НЕ едет.
    Замер по папке (26 заездов): у 25 здоровых максимальный размах высоты на
    стоянке 1.40 м, у 04-27 — 15.60 м. Порог 3.0 м делит их с запасом ×2 и ×5.

    Окно скользит по ВРЕМЕНИ (не по индексам): частота записи у файлов разная. }
  FITD_FREEZE_WIN_SEC = 60.0;   { окно анализа, с }
  FITD_FREEZE_MOVE_M  = 5.0;    { «позиция стоит»: макс смещение в окне, м }
  FITD_FREEZE_ALT_M   = 3.0;    { «высота едет»: размах барометра в окне, м }
  FITD_FREEZE_MIN_PTS = 5;      { минимум точек в окне для суждения }

  { Брак файла целиком: вырезано больше доли точек, или осталось меньше
    минимума. Вырезание 11% (случай 04-27) файл не бракует — остаток
    здоровый: сырой fit−dem у него med −3.4, p95 +2.2 против p95 +30.3 у
    файла целиком. Брак — крайняя мера для файлов, где битой позиции больше
    трети. }
  FITD_REJECT_FRAC    = 0.35;
  FITD_MIN_POINTS     = 100;

type
  TDblArr  = array of Double;
  TBoolArr = array of Boolean;
  TStrArr  = array of string;

{ Разбить строку по разделителю (без зависимости от string-хелперов). }
function SplitStr(const S: string; Sep: Char): TStrArr;
var
  I, Start, N: Integer;
begin
  { ёмкость = число разделителей + 1: один SetLength вместо роста по полю }
  N := 1;
  for I := 1 to Length(S) do
    if S[I] = Sep then Inc(N);
  SetLength(Result, N);
  N := 0; Start := 1;
  for I := 1 to Length(S) do
    if S[I] = Sep then
    begin
      Result[N] := Copy(S, Start, I - Start);
      Inc(N);
      Start := I + 1;
    end;
  Result[N] := Copy(S, Start, Length(S) - Start + 1);
end;

function CsvFmt: TFormatSettings;
begin
  Result := DefaultFormatSettings;
  Result.DecimalSeparator := '.';
  Result.ThousandSeparator := #0;
end;

{ Индекс колонки в заголовке «a;b;c» (без регистра). }
function CsvColIndex(const AHeader, ACol: string): Integer;
var
  Parts: TStrArr;
  I: Integer;
begin
  Result := -1;
  Parts := SplitStr(AHeader, ';');
  for I := 0 to High(Parts) do
    if SameText(Trim(Parts[I]), ACol) then Exit(I);
end;

{ Медиана массива (копия+сортировка вставками не годится на 10k — heap
  не нужен, хватает QuickSort из Math? нет его; простой отбор: копия и
  сортировка через ванильный quicksort). }
procedure QSortD(var A: TDblArr; L, R: Integer);
var
  I, J: Integer;
  P, T: Double;
begin
  while L < R do
  begin
    I := L; J := R; P := A[(L + R) shr 1];
    repeat
      while A[I] < P do Inc(I);
      while A[J] > P do Dec(J);
      if I <= J then
      begin
        T := A[I]; A[I] := A[J]; A[J] := T;
        Inc(I); Dec(J);
      end;
    until I > J;
    if J - L < R - I then
    begin
      if L < J then QSortD(A, L, J);
      L := I;
    end
    else
    begin
      if I < R then QSortD(A, I, R);
      R := J;
    end;
  end;
end;

function MedianD(const A: TDblArr): Double;
var
  C: TDblArr;
  N: Integer;
begin
  N := Length(A);
  if N = 0 then Exit(0);
  C := Copy(A, 0, N);
  QSortD(C, 0, N - 1);
  if Odd(N) then
    Result := C[N shr 1]
  else
    Result := 0.5 * (C[N shr 1 - 1] + C[N shr 1]);
end;

{ ── Кэш v3 (пофайловый) ── }

type
  TCsvRide = record
    Lat, Lon, AltCal: TDblArr;
    Deck: TBoolArr;
    Empty: Boolean;   { валидный маркер «файл пропущен» (мало точек) }
  end;

function CacheCsvPath(const AFitPath: string): string;
begin
  Result := ChangeFileExt(AFitPath, '') + '-fitcache.csv';
end;

{ Пофайловая сигнатура кэша: имя|mtime самого .fit. }
function SrcSig(const AName: string; AMTime: LongInt): string;
begin
  Result := Format('%s|%d', [AName, AMTime]);
end;

{ Прочитать кэш v3. True только если версия И src-сигнатура совпали.
  Слою нужны lat/lon/alt_fitcorr_m/deck; t_sec и alt_dem_m в кэше — для
  офлайн-анализа и будущей межфайловой сшивки, здесь не читаются. }
function ReadCacheCsv(const APath, ASrcSig: string;
  out ARide: TCsvRide): Boolean;
var
  L: TStringList;
  Fmt: TFormatSettings;
  I, N, CiLat, CiLon, CiCal, CiDeck, M: Integer;
  Line: string;
  F: TStrArr;
  VerOk, SigOk, PermanentEmpty: Boolean;
begin
  Result := False;
  ARide := Default(TCsvRide);
  if not FileExists(APath) then Exit;
  Fmt := CsvFmt;
  L := TStringList.Create;
  try
    L.LoadFromFile(APath);
    VerOk := False; SigOk := False; PermanentEmpty := False;
    CiLat := -1; CiLon := -1; CiCal := -1; CiDeck := -1;
    N := -1;
    for I := 0 to L.Count - 1 do
    begin
      Line := L[I];
      if Line = '' then Continue;
      if Line[1] = '#' then
      begin
        if Pos(FITC_CACHE_VER, Line) > 0 then VerOk := True;
        if Pos('src=' + ASrcSig, Line) > 0 then SigOk := True;
        if Pos('# empty', Line) = 1 then ARide.Empty := True;
        if Pos('# empty permanent ', Line) = 1 then PermanentEmpty := True;
        Continue;
      end;
      if Pos('lat', LowerCase(Line)) > 0 then
      begin
        CiLat  := CsvColIndex(Line, 'lat');
        CiLon  := CsvColIndex(Line, 'lon');
        CiCal  := CsvColIndex(Line, 'alt_fitcorr_m');
        CiDeck := CsvColIndex(Line, 'deck');
        N := I;
        Break;
      end;
    end;
    if not (VerOk and SigOk) then Exit;
    { Старые маркеры могли означать временно недоступный DEM. }
    if ARide.Empty then Exit(PermanentEmpty);
    if (N < 0) or (CiLat < 0) or (CiLon < 0) or (CiCal < 0) then Exit;

    { верхняя граница — число строк после заголовка; финальный trim по M }
    SetLength(ARide.Lat,    L.Count - N - 1);
    SetLength(ARide.Lon,    L.Count - N - 1);
    SetLength(ARide.AltCal, L.Count - N - 1);
    SetLength(ARide.Deck,   L.Count - N - 1);
    M := 0;
    for I := N + 1 to L.Count - 1 do
    begin
      Line := L[I];
      if (Line = '') or (Line[1] = '#') then Continue;
      F := SplitStr(Line, ';');
      if (CiLat > High(F)) or (CiLon > High(F)) or (CiCal > High(F)) then
        Continue;
      ARide.Lat[M]    := StrToFloatDef(Trim(F[CiLat]), 0, Fmt);
      ARide.Lon[M]    := StrToFloatDef(Trim(F[CiLon]), 0, Fmt);
      ARide.AltCal[M] := StrToFloatDef(Trim(F[CiCal]), 0, Fmt);
      ARide.Deck[M]   := (CiDeck >= 0) and (CiDeck <= High(F)) and
                         (Trim(F[CiDeck]) = '1');
      Inc(M);
    end;
    SetLength(ARide.Lat,    M);
    SetLength(ARide.Lon,    M);
    SetLength(ARide.AltCal, M);
    SetLength(ARide.Deck,   M);
    Result := M >= 2;
  finally
    L.Free;
  end;
end;

procedure WriteCacheCsv(const APath, ASrcSig: string;
  const AT, ALat, ALon, AAltFit, ADem, AAltCal: TDblArr;
  const ADeck: TBoolArr; ALanding: Double; ACut: Integer);
var
  L: TStringList;
  Fmt: TFormatSettings;
  I: Integer;
begin
  Fmt := CsvFmt;
  L := TStringList.Create;
  try
    L.Add('# ' + FITC_CACHE_VER);
    L.Add('# src=' + ASrcSig + '  (пофайловый кэш: зависит только от своего .fit)');
    L.Add(Format('# landing=%.2f  (медианный сдвиг cal к DEM, уже применён)',
      [ALanding], Fmt));
    L.Add(Format('# frozen-pos-cut=%d  (точек вырезано детектором битой позиции)',
      [ACut]));
    L.Add('idx;t_sec;lat;lon;alt_fit_m;alt_dem_m;alt_fitcorr_m;deck');
    for I := 0 to High(AAltCal) do
      L.Add(Format('%d;%.1f;%.7f;%.7f;%.2f;%.2f;%.2f;%d',
        [I, AT[I], ALat[I], ALon[I], AAltFit[I], ADem[I], AAltCal[I],
         Ord(ADeck[I])], Fmt));
    try
      L.SaveToFile(APath);
    except
      on E: Exception do ;   { кэш не критичен }
    end;
  finally
    L.Free;
  end;
end;

{ Маркер «файл не в слое» (пустой/битый/забракованный) — чтобы он не
  пересчитывался на каждом запуске. AReason уходит в файл для человека. }
procedure WriteCacheEmpty(const APath, ASrcSig, AReason: string);
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.Add('# ' + FITC_CACHE_VER);
    L.Add('# src=' + ASrcSig);
    if AReason <> '' then
      L.Add('# empty permanent (забракован): ' + AReason)
    else
      L.Add('# empty permanent (недостаточно точек)');
    try
      L.SaveToFile(APath);
    except
      on E: Exception do ;
    end;
  finally
    L.Free;
  end;
end;

{ ── Детектор битой позиции ── }

{ Пометить точки, попавшие в окна «позиция стоит, высота едет». Возвращает
  число помеченных. Окно — по времени; отметка ставится на ВСЁ окно (края
  такого участка так же недостоверны, как середина). }
function MarkFrozenPos(const AGeo: TFitGeoAltArray;
  out ABad: TBoolArr): Integer;
var
  N, I, J, K: Integer;
  KX, KY, Dx, Dz, D, MinA, MaxA: Double;
begin
  Result := 0;
  N := Length(AGeo);
  SetLength(ABad, N);
  for I := 0 to N - 1 do ABad[I] := False;
  if N < FITD_FREEZE_MIN_PTS then Exit;
  KY := 111320.0;
  KX := KY * Cos(AGeo[0].Lat * Pi / 180.0);   { локальный масштаб долготы }
  J := 0;
  for I := 0 to N - 1 do
  begin
    if J < I then J := I;
    while (J < N - 1)
      and (AGeo[J + 1].TimeSec - AGeo[I].TimeSec < FITD_FREEZE_WIN_SEC) do
      Inc(J);
    if (J - I + 1) < FITD_FREEZE_MIN_PTS then Continue;
    { окно должно быть заполнено по времени хотя бы наполовину — иначе это
      конец файла / дыра записи, а не суждение о неподвижности }
    if (AGeo[J].TimeSec - AGeo[I].TimeSec) < 0.5 * FITD_FREEZE_WIN_SEC then
      Continue;
    Dx := 0; Dz := 0;
    MinA := AGeo[I].AltM; MaxA := MinA;
    for K := I to J do
    begin
      D := Abs(AGeo[K].Lon - AGeo[I].Lon) * KX;
      if D > Dx then Dx := D;
      D := Abs(AGeo[K].Lat - AGeo[I].Lat) * KY;
      if D > Dz then Dz := D;
      if AGeo[K].AltM < MinA then MinA := AGeo[K].AltM;
      if AGeo[K].AltM > MaxA then MaxA := AGeo[K].AltM;
    end;
    if (Sqrt(Dx * Dx + Dz * Dz) < FITD_FREEZE_MOVE_M)
       and ((MaxA - MinA) > FITD_FREEZE_ALT_M) then
      for K := I to J do
        if not ABad[K] then
        begin
          ABad[K] := True;
          Inc(Result);
        end;
  end;
end;

{ ── Пофайловый датум с приземлением на DEM ── }

{ AReject <> '' → файл забракован целиком (причина для лога/кэша). }
function ComputeRideDatum(const AFolder, AName: string;
  AFetcher: TTerrariumFetcher; AZoom: Integer; ALog: TStrings;
  out AT, ALat, ALon, AAltFit, ADem, AAltCal: TDblArr;
  out ADeck: TBoolArr; out ALanding: Double;
  out ACut: Integer; out AReject: string; out ACacheable: Boolean): Boolean;
var
  Fit: TFitFile;
  Geo, GeoAll: TFitGeoAltArray;
  Bad: TBoolArr;
  Origin: TLatLon;
  Proj: TLocalProjection;
  Rides: TFitDatumRideArray;
  Box: TLatLonBox;
  Hm: THeightmap;
  AllLL: array of TLatLon;
  Diff: TDblArr;
  FSynthetic: Boolean;   { файл без высоты → канал синтезируется из DEM }
  DistArr, DemArr, SynArr: TDemProfileArr;
  K, Nc, NAll, NBad, T0i, T1i: Integer;
  V: TVector3;
begin
  Result := False;
  ALanding := 0;
  ACut := 0;
  AReject := '';
  ACacheable := False;               { ошибка чтения может быть временной }
  SetLength(AT, 0); SetLength(ALat, 0); SetLength(ALon, 0);
  SetLength(AAltFit, 0); SetLength(ADem, 0); SetLength(AAltCal, 0);
  SetLength(ADeck, 0);

  Fit := NewRouteParserForFile(IncludeTrailingPathDelimiter(AFolder) + AName);
  try
    if not Fit.LoadFromFile(IncludeTrailingPathDelimiter(AFolder) + AName) then
      Exit;
    ACacheable := True;
    { Файл «только координаты» (GPX без <ele>, FIT без баро): высотный
      канал синтезируем из DEM ниже по коду — датум не решаем. }
    FSynthetic := not Fit.HasAltitude;
    GeoAll := Fit.ToGeoAltPoints;
  finally
    Fit.Free;
  end;
  NAll := Length(GeoAll);
  if NAll < 2 then Exit;

  { ── Нож битой позиции ДО солвера: точки с замороженной координатой и
    едущим барометром выбрасываются и из датума, и из слоя. В датуме они
    ломают весь файл (пары самоперекрытия в одной кляксе → фиктивный дрейф);
    в слое кладут столб чужих высот в одну плановую точку. ── }
  NBad := MarkFrozenPos(GeoAll, Bad);
  ACut := NBad;
  if NBad > 0 then
  begin
    T0i := -1; T1i := -1;
    for K := 0 to NAll - 1 do
      if Bad[K] then
      begin
        if T0i < 0 then T0i := K;
        T1i := K;
      end;
    if (NBad > Round(FITD_REJECT_FRAC * NAll))
       or ((NAll - NBad) < FITD_MIN_POINTS) then
    begin
      AReject := Format('битая позиция (датчик скорости/GPS): %d из %d точек '
        + '(%.0f%%), t=%.0f..%.0f c', [NBad, NAll, 100.0 * NBad / NAll,
        GeoAll[T0i].TimeSec, GeoAll[T1i].TimeSec]);
      if ALog <> nil then
        ALog.Add('fit-layer: ' + AName + ' — ЗАБРАКОВАН: ' + AReject);
      Exit;
    end;
    if ALog <> nil then
      ALog.Add(Format('fit-layer: %s — вырезано %d из %d точек (%.0f%%) '
        + 'битой позиции, t=%.0f..%.0f c', [AName, NBad, NAll,
        100.0 * NBad / NAll, GeoAll[T0i].TimeSec, GeoAll[T1i].TimeSec]));
  end;
  SetLength(Geo, NAll - NBad);
  Nc := 0;
  for K := 0 to NAll - 1 do
    if not Bad[K] then
    begin
      Geo[Nc] := GeoAll[K];
      Inc(Nc);
    end;
  if Nc < 2 then Exit;

  SetLength(AllLL, Nc);
  for K := 0 to Nc - 1 do
    AllLL[K] := TLatLon.Make(Geo[K].Lat, Geo[K].Lon);
  Origin := TRouteSrc.OriginCentroid(AllLL);
  Proj := TLocalProjection.Create(Origin);
  try
    Box := TLatLonBox.Empty;
    for K := 0 to Nc - 1 do
      Box := Box.Include(TLatLon.Make(Geo[K].Lat, Geo[K].Lon));
    Hm := nil;
    if AFetcher <> nil then
    begin
      Box := Box.ExpandMeters(50.0);
      Hm := AFetcher.GetRegion(Box, AZoom);
    end;
    { Не сохранять ни отказ синтетики, ни неприземлённую барометрию
      как окончательный результат при временном отсутствии DEM. }
    if Hm = nil then ACacheable := False;

    SetLength(Rides, 1);
    SetLength(Rides[0].Points, Nc);
    for K := 0 to Nc - 1 do
    begin
      V := Proj.Project(Geo[K].Lat, Geo[K].Lon);
      Rides[0].Points[K].X   := V.X;
      Rides[0].Points[K].Z   := V.Z;
      Rides[0].Points[K].Alt := Geo[K].AltM;
      Rides[0].Points[K].T   := Geo[K].TimeSec;
      if Hm <> nil then
        Rides[0].Points[K].Dem := THeightmapSampler.SampleBilinear(
          Hm, TLatLon.Make(Geo[K].Lat, Geo[K].Lon))
      else
        Rides[0].Points[K].Dem := Geo[K].AltM;
    end;
    { Синтетика без DEM невозможна (высоты нулевые) — бракуем честно. }
    if FSynthetic and (Hm = nil) then
    begin
      AReject := 'нет высоты (altitude/ele) и DEM недоступен — слой не строится';
      if ALog <> nil then
        ALog.Add('fit-layer: ' + AName + ' — ЗАБРАКОВАН: ' + AReject);
      Exit;
    end;
    if Hm <> nil then Hm.Free;

    if FSynthetic then
    begin
      { Файл «только координаты» (GPX без <ele>): высотный канал —
        синтетика из DEM (медиана 5 + скользящее среднее 300 м вдоль пути,
        Osm3dDemProfile — замер пользы в шапке юнита). Датум НЕ решаем —
        нивелировать нечего; Cal = синтетика, приземление 0, deck-флагов
        нет (мосты/туннели из DEM не отличить — интерполяция пролётов
        через снап-теги, будущее улучшение). }
      SetLength(DistArr, Nc);
      DistArr[0] := 0;
      for K := 1 to Nc - 1 do
        DistArr[K] := DistArr[K - 1] + Hypot(
          Rides[0].Points[K].X - Rides[0].Points[K - 1].X,
          Rides[0].Points[K].Z - Rides[0].Points[K - 1].Z);
      SetLength(DemArr, Nc);
      for K := 0 to Nc - 1 do
        DemArr[K] := Rides[0].Points[K].Dem;
      SmoothProfile(DistArr, DemArr, SynArr);
      SetLength(Rides[0].Cal, Nc);   { в несинтетике выделяет SolveFitDatum }
      for K := 0 to Nc - 1 do
      begin
        Geo[K].AltM            := SynArr[K];
        Rides[0].Points[K].Alt := SynArr[K];
        Rides[0].Cal[K]        := SynArr[K];
      end;
      ALanding := 0;
      if ALog <> nil then
        ALog.Add('fit-layer: ' + AName +
          ' — нет высоты: синтетический профиль из DEM (медиана 5 + среднее 300 м)');
    end
    else
    begin
      { форма дрейфа: самоперекрытия + DEM-арбитр одиноких + гладкость }
      SolveFitDatum(Rides, 0);   { заполняет Rides[0].Cal }

      { ПРИЗЕМЛЕНИЕ: медианный сдвиг cal → DEM. Одна константа на файл;
        медиана робастна к мостам (высокие +), прогреву (первые ~2% точек)
        и лесному пологу DEM (локальные −). Без него уровень файла = средний
        ноль сырого баро (W_LEVEL солвера) — произвольная калибровка дня. }
      SetLength(Diff, Nc);
      for K := 0 to Nc - 1 do
        Diff[K] := Rides[0].Cal[K] - Rides[0].Points[K].Dem;
      ALanding := MedianD(Diff);
      if (AFetcher = nil) and (ALog <> nil) then
        ALog.Add('fit-layer: ' + AName +
          ' — DEM недоступен, приземление на сырой баро (уровень условный)');
    end;

    SetLength(AT, Nc); SetLength(ALat, Nc); SetLength(ALon, Nc);
    SetLength(AAltFit, Nc); SetLength(ADem, Nc); SetLength(AAltCal, Nc);
    SetLength(ADeck, Nc);
    for K := 0 to Nc - 1 do
    begin
      AT[K]      := Geo[K].TimeSec;
      ALat[K]    := Geo[K].Lat;
      ALon[K]    := Geo[K].Lon;
      AAltFit[K] := Geo[K].AltM;
      ADem[K]    := Rides[0].Points[K].Dem;
      AAltCal[K] := Rides[0].Cal[K] - ALanding;
      ADeck[K]   := (not FSynthetic) and
                    ((AAltCal[K] - ADem[K]) > FITL_BRIDGE_RISE_M);
    end;
    Result := True;
  finally
    Proj.Free;
  end;
end;

{ FNV-1a 64 → hex. Сигнатура набора: sorted "name|mtime". }
function FnvHex(const S: string): string;
var
  H: QWord;
  I: Integer;
begin
  H := QWord($CBF29CE484222325);
  for I := 1 to Length(S) do
  begin
    H := H xor QWord(Ord(S[I]));
    H := H * QWord($100000001B3);
  end;
  Result := IntToHex(H, 16);
end;

function BuildFitHeightLayer(const AFolder, ASelectedFile: string;
  AFetcher: TTerrariumFetcher; AZoom: Integer;
  ALayer: TFitHeightLayer; ALog: TStrings; AOnlySelected: Boolean): string;
var
  Sr: TSearchRec;
  Names: TStringList;
  MTimes: array of LongInt;
  SigSrc, DemSig: string;
  Pts: TFitLayerPointArray;
  NPts, I, DeckAll, GndAll, FromCache, Computed: Integer;
  Origin: TLatLon;
  LayerProj: TLocalProjection;
  AllLL: array of TLatLon;
  FitPath, SelName, Mask: string;
  Csv: TCsvRide;
  T0, Lat, Lon, AltFit, Dem, AltCal: TDblArr;
  Deck: TBoolArr;
  Landing: Double;
  Cut, CutAll, Rejected: Integer;
  Reject: string;
  Cacheable: Boolean;
  V: TVector3;
  Found: Boolean;

  procedure Note(const S: string);
  begin
    if ALog <> nil then ALog.Add(S);
  end;

  { Точки в слой; мир слоя посчитаем вторым проходом (временно X=lat, Z=lon). }
  procedure AppendRide(const ALatA, ALonA, AAltCalA: TDblArr;
    const ADeckA: TBoolArr);
  var J, Base: Integer;
  begin
    Base := Length(Pts);
    SetLength(Pts, Base + Length(AAltCalA));
    for J := 0 to High(AAltCalA) do
    begin
      Pts[Base + J].AltCal := AAltCalA[J];
      Pts[Base + J].Deck   := (J <= High(ADeckA)) and ADeckA[J];
      Pts[Base + J].X := ALatA[J];
      Pts[Base + J].Z := ALonA[J];
    end;
    Inc(NPts, Length(AAltCalA));
  end;

begin
  Result := '';
  if ALayer = nil then Exit('fit-layer: nil layer');
  ALayer.Clear;
  if AZoom <= 0 then AZoom := FITL_DEM_ZOOM_DEFAULT;
  if AFetcher <> nil then
    DemSig := HeightDatasetCacheKey(AFetcher.UrlTemplate)
  else
    DemSig := 'no-dem';
  DemSig := '|dem=' + LowerCase(MD5Print(MD5String(DemSig+'|z='+IntToStr(AZoom))));

  Names := TStringList.Create;
  try
    { Маршруты двух форматов: FIT (записанные заезды) и GPX (только путь). }
    for I := 0 to 1 do
    begin
      if I = 0 then
        Mask := '*.fit'
      else
        Mask := '*.gpx';
      if FindFirst(IncludeTrailingPathDelimiter(AFolder) + Mask,
        faAnyFile, Sr) = 0 then
      begin
        repeat
          if (Sr.Attr and faDirectory) = 0 then
            Names.Add(Sr.Name);
        until FindNext(Sr) <> 0;
        FindClose(Sr);
      end;
    end;
    Names.Sort;

    { Режим «только текущий заезд»: оставляем в наборе единственный выбранный
      файл (датум пофайловый — остальные не нужны и не считаются). Если он
      не найден (рассинхрон пути) — откат на все заезды. }
    if AOnlySelected then
    begin
      SelName := ExtractFileName(ASelectedFile);
      Found := False;
      if SelName <> '' then
        for I := 0 to Names.Count - 1 do
          if SameText(Names[I], SelName) then begin Found := True; Break; end;
      if Found then
      begin
        for I := Names.Count - 1 downto 0 do
          if not SameText(Names[I], SelName) then Names.Delete(I);
        Note('fit-layer: route-only → только выбранный заезд ' + SelName);
      end
      else
      begin
        Note('fit-layer: route-only, но выбранный ' + SelName +
             ' не найден в папке — беру все заезды');
        AOnlySelected := False;
      end;
    end;

    if Names.Count = 0 then
    begin
      Note('fit-layer: no *.fit/*.gpx in ' + AFolder);
      Exit('fit-layer: no *.fit/*.gpx');
    end;

    { Сигнатура слоя (gen-hash): perfile-v3 — смена алгоритма обязана
      сменить хэш при тех же .fit, иначе поднимутся старые тайлы. }
    SetLength(MTimes, Names.Count);
    SigSrc := 'perfile-v5'+DemSig+';';
    for I := 0 to Names.Count - 1 do
    begin
      FitPath   := IncludeTrailingPathDelimiter(AFolder) + Names[I];
      MTimes[I] := FileAge(FitPath);
      SigSrc := SigSrc + Format('%s|%d;', [Names[I], MTimes[I]]);
    end;
    if AOnlySelected then SigSrc := SigSrc + 'onlysel;';

    SetLength(Pts, 0);
    NPts := 0; FromCache := 0; Computed := 0;
    CutAll := 0; Rejected := 0;
    for I := 0 to Names.Count - 1 do
    begin
      FitPath := IncludeTrailingPathDelimiter(AFolder) + Names[I];

      if ReadCacheCsv(CacheCsvPath(FitPath),
           SrcSig(Names[I], MTimes[I])+DemSig, Csv) then
      begin
        if not Csv.Empty then
        begin
          AppendRide(Csv.Lat, Csv.Lon, Csv.AltCal, Csv.Deck);
          Inc(FromCache);
        end;
        Continue;
      end;

      if ComputeRideDatum(AFolder, Names[I], AFetcher, AZoom, ALog,
                          T0, Lat, Lon, AltFit, Dem, AltCal, Deck,
                          Landing, Cut, Reject, Cacheable) then
      begin
        if Cacheable then
          WriteCacheCsv(CacheCsvPath(FitPath), SrcSig(Names[I], MTimes[I])+DemSig,
            T0, Lat, Lon, AltFit, Dem, AltCal, Deck, Landing, Cut);
        { NB: без флага '+' — FPC/Delphi Format его не понимает (грамматика
          %[индекс:][-][ширина][.точность]тип), '+' уходит в разбор индекса
          через StrToInt64Def и валит EConvertError. Знак минуса печатается
          сам. }
        Note(Format('fit-layer: %s — датум решён, приземление %.1f м%s',
          [Names[I], Landing,
           IfThen(Cut > 0, Format(', вырезано %d точек', [Cut]), '')]));
        AppendRide(Lat, Lon, AltCal, Deck);
        Inc(Computed);
        Inc(CutAll, Cut);
      end
      else
      begin
        if Cacheable then
          WriteCacheEmpty(CacheCsvPath(FitPath),
            SrcSig(Names[I], MTimes[I])+DemSig, Reject);
        if Reject <> '' then Inc(Rejected);
      end;
    end;
  finally
    Names.Free;
  end;

  if Length(Pts) < 2 then
  begin
    Note('fit-layer: <2 точек суммарно — слой пуст');
    Exit('fit-layer: empty');
  end;

  { origin слоя = центроид всех его точек; проецируем гео(X=lat,Z=lon)→мир }
  SetLength(AllLL, Length(Pts));
  for I := 0 to High(Pts) do
    AllLL[I] := TLatLon.Make(Pts[I].X, Pts[I].Z);   { X=lat, Z=lon пока }
  Origin := TRouteSrc.OriginCentroid(AllLL);
  LayerProj := TLocalProjection.Create(Origin);
  try
    for I := 0 to High(Pts) do
    begin
      V := LayerProj.Project(Pts[I].X, Pts[I].Z);   { (lat,lon) }
      Pts[I].X := V.X;
      Pts[I].Z := V.Z;
    end;
  finally
    LayerProj.Free;
  end;

  ALayer.SetData(Pts, Origin, FnvHex(SigSrc));

  DeckAll := 0; GndAll := 0;
  for I := 0 to High(Pts) do
    if Pts[I].Deck then Inc(DeckAll) else Inc(GndAll);

  Result := Format(
    'fit-layer: пофайловый датум + DEM-приземление, %d файлов '
    + '(кэш %d / расчёт %d, брак %d), %d точек (%d земля, %d настил, '
    + 'вырезано %d битой позиции), sig=%s',
    [FromCache + Computed, FromCache, Computed, Rejected, NPts, GndAll,
     DeckAll, CutAll, ALayer.Signature]);
  Note(Result);
end;

end.
