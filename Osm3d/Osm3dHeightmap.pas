unit Osm3dHeightmap;

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$codepage UTF8}

interface

uses
  Classes,
  SysUtils,
  Math,
  SyncObjs,
  Generics.Collections,
  Osm3dGeoMath,
  FPImage,
  FPReadPNG,
  FPWritePNG,
  Osm3dCacheHTTPFetcher,
  Osm3dOsmDirectory,
  Osm3dFitHeightLayer          { TFitHeightLayer — второй слой высот фетчера }
  {$IFDEF TILE_MEM_PROFILE}, Osm3dMemCensus{$ENDIF}
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
;

type
  THeightmap = class
  private
    FWidth:  Integer;
    FHeight: Integer;
    FBox:    TLatLonBox;
    FData:   array of Single;       { row-major: [Y * FWidth + X] }
    { Precomputed geo->pixel mapping terms (see LatLonToPixel): box lon
      range and the Web-Mercator ordinates of the box top/span. MercN is
      tan+ln+cos — caching per box keeps it out of every sample. }
    FRangeLon: Double;
    FMTop:     Double;
    FMSpan:    Double;

    function GetSampleByXY(X, Y: Integer): Single;
    procedure SetSampleByXY(X, Y: Integer; V: Single);
  public
    constructor Create(AWidth, AHeight: Integer; const ABox: TLatLonBox);

    property Width:  Integer    read FWidth;
    property Height: Integer    read FHeight;
    property Box:    TLatLonBox read FBox;
    property RangeLon: Double   read FRangeLon;
    property MercTop:  Double   read FMTop;
    property MercSpan: Double   read FMSpan;

    property Sample[X, Y: Integer]: Single
      read GetSampleByXY write SetSampleByXY; default;

    { Clamps X/Y to [0..W-1] / [0..H-1] — for edge sampling. }
    function SampleClamped(X, Y: Integer): Single;

    function MinHeight: Single;
    function MaxHeight: Single;

    { Separable Gaussian low-pass, in place. SigmaPx = blur radius in heightmap pixels (<=0 no-op).
      The source AWS heights are integer-metre quantised (a staircase); blurring once after stitch
      dissolves the 1 m steps into a continuous slope read by every downstream consumer. Borders
      clamped, so a per-block blur with whole-tile margin produces no seams. }
    procedure BlurGaussian(SigmaPx: Single);

    { Pointer to the start of row Y — for bulk copy / fast samplers. }

    function DataBytes: Int64;
  end;

type
  THeightmapSampler = class
  public
    { Returns True iff P falls strictly inside the bbox; coordinates are
      computed regardless so the caller can decide on clamp / NaN. }
    class function LatLonToPixel(const HM: THeightmap; const P: TLatLon;
      out PX, PY: Single): Boolean;

    { Bilinear between 4 neighbours, clamps outside bbox. }
    class function SampleBilinear(const HM: THeightmap; const P: TLatLon): Single;

    { Bicubic (Catmull-Rom) over the 4x4 pixel neighbourhood, edge-clamped.
      C1-continuous and interpolating (passes through the pixel samples),
      so it gives a smooth surface BETWEEN heightmap pixels without moving
      the values AT the pixels. SampleBicubic takes a geo point; CubicSamplePx
      takes a fractional pixel coordinate directly (used by the terrain
      sub-node oversampler). }
    class function CubicSamplePx(const HM: THeightmap; FX, FY: Single): Single;
  end;

type
  THeightmapStitcher = class
  public
    { Length(ATiles) must equal TilesX × TilesY; all tiles must share
      pixel dimensions. Caller owns the result. }
    class function Stitch(const ATiles: array of THeightmap;
      ATilesX, ATilesY: Integer): THeightmap;
  end;

const
  TERRARIUM_URL_DEFAULT = HEIGHT_PUBLIC_TEMPLATE;
  TERRARIUM_TILE_PIXELS = 256;

type
  { Плоская сетка высот row-major: [IZ*Grid + IX]; строка 0 = север (MaxLat),
    столбец 0 = запад (MinLon); значения — абсолютные метры над уровнем моря
    (как .prev). Пустой массив (Length=0) = «нет данных». }
  THeightArray = array of Single;

  TTerrariumDecoder = class
  public
    class function RGBToHeight(R, G, B: Byte): Single;

    { Caller owns the returned THeightmap. Raises on invalid PNG. }
    class function Decode(const PngBytes: TBytes;
      const ATile: TTileXY): THeightmap;
  end;

  { Internal LRU brick — one decoded source tile + bookkeeping. }
  TTerrTileEntry = class
  public
    Hm:  THeightmap;   { owned by this entry }
    Pin: Integer;      { >0 while an in-flight GetRegion references it }
    Seq: Int64;        { last-touch order for LRU }
    destructor Destroy; override;
  end;

  { Heightmap source + cache. Holds a bounded read-only cache of DECODED terrarium tiles and
    assembles stitched heightmaps for a region. Must be long-lived and session-shared so the cache
    spans blocks/previews. Thread-safe; concurrent fetches of the same tile are coalesced (poll-wait)
    so each tile is downloaded+decoded once. }
  { Задание фонового расчёта грида высот (обрабатывает ОДИН воркер). }
  TGridJob = record
    Key:  string;
    Box:  TLatLonBox;
    N, Zoom: Integer;
  end;

  TTerrariumFetcher = class
  private
    FFetcher:     THTTPFetcherWithCache;   { DI — caller owns it }
    FUrlTemplate: string;
    FLock:        TCriticalSection;
    FTiles:       specialize TObjectDictionary<Int64, TTerrTileEntry>;
    FLoading:     specialize TDictionary<Int64, Boolean>;
    FRequested:   specialize TDictionary<Int64, Boolean>;  { дедуп фоновых загрузок пола }
    FActiveLoads: LongInt;    { счётчик живых фон-загрузчиков (teardown ждёт) }
    { Асинхронный расчёт грида высот в фоне. }
    FReadyGrids: specialize TDictionary<string, THeightArray>;  { готовые гриды }
    FReadyZoom:  specialize TDictionary<string, Integer>;        { фактический зум грида }
    FGridReq:    specialize TDictionary<string, Boolean>;       { дедуп грид-задач }
    FGridLock:   TCriticalSection;
    FGridQueue:  specialize TQueue<TGridJob>;   { очередь грид-задач }
    FGridWake:   TEvent;
    FGridWorker: TThread;                        { ОДИН персистентный воркер }
    FMaxTiles:    Integer;
    FSeq:         Int64;
    { Отмена по teardown карты: AcquireTile не ждёт чужой загрузчик, сетевые
      попытки общего фетчера рвутся (см. AbortFetches). }
    FAbortAll:    Boolean;
    { Второй слой высот: корректированные высоты из FIT (Osm3dFitHeightLayer).
      Фетчер ВЛАДЕЕТ им (ставит SetFitLayer, освобождает в Destroy). Читается
      генератором тайлов (Builder.FitLayer := FTerrFetcher.FitLayer) на узлах
      террейна; сам фетчер GetRegion им НЕ трогает (сырой DEM для датума). }
    FFitLayer:    TFitHeightLayer;

    function  TileKey(const ATile: TTileXY): Int64; inline;
    { Cached tile (pinned) or decode-once (coalesced). nil only on failure.
      Caller must ReleaseTile afterwards. }
    function  AcquireTile(const ATile: TTileXY;
      ACacheOnly: Boolean = False): THeightmap;
    { Как FetchTile, но строго из кэша (GetUrlCachedOnly) — без сети. }
    function  FetchTileCachedOnly(const ATile: TTileXY): THeightmap;
    function TileCandidates(const ATile: TTileXY; AllowRefresh: Boolean): TStringArray;
    procedure ReleaseTile(const ATile: TTileXY);
    procedure RequestTileLoad(const ATile: TTileXY);
    function  PadForZoom(const ABox: TLatLonBox;
      AZoom: Integer): TLatLonBox;
    procedure EvictLocked;
  public
    { AFetcher is DI — caller owns it. AUrlTemplate = '' / 'auto' → height directory.
      AMaxTiles bounds the decoded-tile cache (see HEIGHT_TILE_CACHE_MAX). }
    constructor Create(AFetcher: THTTPFetcherWithCache;
      const AUrlTemplate: string = ''; AMaxTiles: Integer = 256);
    destructor  Destroy; override;

    { Returns nil on network error (details in the fetcher's OnError event).
      Uncached — does NOT touch the tile cache (raw fetch+decode). }
    function FetchTile(const ATile: TTileXY): THeightmap;

    { Stitched heightmap covering ABox at AZoom, assembled from the shared decoded-tile cache.
      Caller owns and frees it. nil if ANY covering tile could not be read (gaps are not acceptable).
      No blur applied — that is a consumer decision.
      ACancel — необязательный флаг отмены: проверяется перед каждым тайлом,
      при взводе возвращает nil немедленно (не дожидаясь остальных HTTP-
      запросов региона — иначе деструктор карты ждёт весь регион). }
    function GetRegion(const ABox: TLatLonBox; AZoom: Integer;
      ACancel: PBoolean = nil): THeightmap;
    { Worker-only sample at EXACTLY this zoom, with bilinear neighbours
      across tile boundaries. Uses pinned cache tiles, no stitched copy.
      May fetch missing tiles; never call from a render/UI query. }
    function TryHeightAtZoom(const P: TLatLon; AZoom: Integer;
      out AHeight: Single): Boolean;
    { Отмена всех загрузок (teardown карты): рвёт идущие HTTP (AbortAllRequests
      на общем фетчере) и спин-ожидания чужих загрузчиков в AcquireTile.
      Окно отмены ограничено — ResetFetchAbort сразу после джойна воркеров. }
    procedure AbortFetches;
    { Permanent shutdown, separate from temporary fetch cancellation. }
    procedure RequestBackgroundStop;
    procedure JoinBackgroundStop;
    procedure ResetFetchAbort;
    { Как GetRegion, но строго из кэша (RAM/диск), БЕЗ сети: мгновенный
      «слепок того, что есть». nil — хотя бы один тайл не в кэше. }
    function GetRegionCachedOnly(const ABox: TLatLonBox;
      AZoom: Integer): THeightmap;
    { Фоновая догрузка ВСЕХ terrarium-тайлов, покрывающих бокс (с запасом
      2 texel'а под билинейку) — дедуп внутри, потоки FreeOnTerminate. }
    procedure RequestRegionLoad(const ABox: TLatLonBox; AZoom: Integer);

    { Высоты супертайла: сетка AGrid×AGrid над ABox с terrarium НИЗКОГО разрешения (AZoom, напр.
      10). Строка 0 = север (MaxLat), столбец 0 = запад (MinLon); значения абсолютные (м н.у.м.).
      Общий тайл-кэш (ключ содержит zoom — грубый и полный не коллизируют). Пусто = регион не
      прочитался (вызывающий оставляет заглушку, без ям). Грубого хитмэпа хватает: меш супера всё
      равно грубый (~43 PNG на zoom 10 вместо ~2700 на 13). }
    function GetSuperHeights(const ABox: TLatLonBox;
      AGrid, AZoom: Integer): THeightArray;

    { Высота земли в точке — ТОЛЬКО из кэша (декодир. тайлы), без HTTP.
      False, если покрывающий terrarium-тайл ещё не в кэше. }
    function TryHeightCached(const P: TLatLon; AZoom: Integer;
      out AHeight: Single): Boolean;
    { Сетка AN×AN высот над боксом — ТОЛЬКО из кэша. False, если хоть одна точка
      не в кэше (для меша нужна полная сетка). }
    function TryHeightGridCached(const ABox: TLatLonBox; AN, AZoom: Integer;
      out AHeights: THeightArray): Boolean;
    { Фоново подгрузить покрывающий тайл (не блокирует). }
    procedure RequestHeightLoad(const P: TLatLon; AZoom: Integer);
    { ФОНОВЫЙ расчёт грида высот: запросить (дедуп) и позже забрать готовый на
      main. Тяжёлое сэмплирование уходит с главного потока. }
    procedure RequestHeightGrid(const AKey: string; const ABox: TLatLonBox;
      AN, AZoom: Integer);
    function TryTakeHeightGrid(const AKey: string; out AHeights: THeightArray;
      out AZoom: Integer): Boolean;

    { Установить второй слой высот (FIT-коррекция). Фетчер ЗАБИРАЕТ владение —
      прежний слой освобождается. nil снимает коррекцию. ВНИМАНИЕ: ставить,
      когда генерация тайлов ещё не читает FitLayer (иначе гонка/free при
      активном воркере) — боевой путь ставит на этапе Create сессии. }
    procedure SetFitLayer(ALayer: TFitHeightLayer);
    property FitLayer: TFitHeightLayer read FFitLayer;

    property UrlTemplate: string
      read FUrlTemplate write FUrlTemplate;
    property Fetcher: THTTPFetcherWithCache read FFetcher;
    {$IFDEF TILE_MEM_PROFILE}function MemoryBytes: Int64;{$ENDIF}
    property MaxTiles: Integer read FMaxTiles;
  end;

implementation

uses Osm3dGenerationProgress;

type
  { Protected-member crack for TFPMemoryImage.FData — the row-major
    TFPColor array fcl-image's own GetInternalColor indexes as
    PFPColorArray(FData)^[y*FWidth+x]. Lets the DEM decode loop read
    pixels directly instead of 65K virtual Colors[] calls per tile. }
  TFPMemoryImageCrack = class(TFPMemoryImage);

{ Web-Mercator ордината: asinh(tan(lat)) = ln(tan + sec). Ровно та
  нелинейность, которой TTileMath.TileToLatLonBox назначает границы
  slippy-тайлов (ArcTan(Sinh(...)) — её обращение), поэтому на кромках
  тайлов она даёт целопиксельные значения. }
function MercN(ALatDeg: Double): Double; inline;
var
  R: Double;
begin
  R := ALatDeg * DEG_TO_RAD;
  Result := Ln(Tan(R) + 1.0 / Cos(R));
end;

constructor THeightmap.Create(AWidth, AHeight: Integer; const ABox: TLatLonBox);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1168);{$ENDIF}
  inherited Create;
  if (AWidth <= 0) or (AHeight <= 0) then
    raise ERangeError.CreateFmt('THeightmap: invalid dimensions %d×%d',
      [AWidth, AHeight]);
  FWidth  := AWidth;
  FHeight := AHeight;
  FBox    := ABox;
  FRangeLon := FBox.MaxLon - FBox.MinLon;
  FMTop     := MercN(FBox.MaxLat);
  FMSpan    := FMTop - MercN(FBox.MinLat);
  SetLength(FData, FWidth * FHeight);    { SetLength zero-inits Singles to 0.0 }
end;

function THeightmap.GetSampleByXY(X, Y: Integer): Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(504);{$ENDIF}
  if (X < 0) or (X >= FWidth) or (Y < 0) or (Y >= FHeight) then
    raise ERangeError.CreateFmt('THeightmap.Sample: (%d,%d) outside (%d×%d)',
      [X, Y, FWidth, FHeight]);
  Result := FData[Y * FWidth + X];
end;

procedure THeightmap.SetSampleByXY(X, Y: Integer; V: Single);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(505);{$ENDIF}
  if (X < 0) or (X >= FWidth) or (Y < 0) or (Y >= FHeight) then
    raise ERangeError.CreateFmt('THeightmap.Sample: (%d,%d) outside (%d×%d)',
      [X, Y, FWidth, FHeight]);
  FData[Y * FWidth + X] := V;
end;

function THeightmap.SampleClamped(X, Y: Integer): Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(506);{$ENDIF}
  if X < 0          then X := 0;
  if X >= FWidth    then X := FWidth - 1;
  if Y < 0          then Y := 0;
  if Y >= FHeight   then Y := FHeight - 1;
  Result := FData[Y * FWidth + X];
end;

function THeightmap.MinHeight: Single;
var
  I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(508);{$ENDIF}
  if Length(FData) = 0 then Exit(0);
  Result := FData[0];
  for I := 1 to High(FData) do
    if FData[I] < Result then
      Result := FData[I];
end;

function THeightmap.MaxHeight: Single;
var
  I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(509);{$ENDIF}
  if Length(FData) = 0 then Exit(0);
  Result := FData[0];
  for I := 1 to High(FData) do
    if FData[I] > Result then
      Result := FData[I];
end;

function THeightmap.DataBytes: Int64;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(511);{$ENDIF}
  Result := Length(FData) * SizeOf(Single);
end;

procedure THeightmap.BlurGaussian(SigmaPx: Single);
var
  Radius, I, X, Y, K, SX, SY: Integer;
  Sum, WSum: Single;
  Kern: array of Single;
  Tmp:  array of Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1532);{$ENDIF}
  if (SigmaPx <= 0) or (Length(FData) = 0) then Exit;

  Radius := Ceil(3.0 * SigmaPx);
  if Radius < 1 then Exit;

  { normalized 1D Gaussian kernel }
  SetLength(Kern, 2 * Radius + 1);
  WSum := 0;
  for I := -Radius to Radius do
  begin
    Kern[I + Radius] := Exp(-(I * I) / (2.0 * SigmaPx * SigmaPx));
    WSum := WSum + Kern[I + Radius];
  end;
  for I := 0 to High(Kern) do
    Kern[I] := Kern[I] / WSum;

  SetLength(Tmp, Length(FData));

  { horizontal pass: FData -> Tmp (clamped at the left/right edge) }
  for Y := 0 to FHeight - 1 do
    for X := 0 to FWidth - 1 do
    begin
      Sum := 0;
      for K := -Radius to Radius do
      begin
        SX := X + K;
        if SX < 0 then SX := 0
        else if SX >= FWidth then SX := FWidth - 1;
        Sum := Sum + Kern[K + Radius] * FData[Y * FWidth + SX];
      end;
      Tmp[Y * FWidth + X] := Sum;
    end;

  { vertical pass: Tmp -> FData (clamped at the top/bottom edge) }
  for Y := 0 to FHeight - 1 do
    for X := 0 to FWidth - 1 do
    begin
      Sum := 0;
      for K := -Radius to Radius do
      begin
        SY := Y + K;
        if SY < 0 then SY := 0
        else if SY >= FHeight then SY := FHeight - 1;
        Sum := Sum + Kern[K + Radius] * Tmp[SY * FWidth + X];
      end;
      FData[Y * FWidth + X] := Sum;
    end;
end;

class function THeightmapSampler.LatLonToPixel(const HM: THeightmap;
  const P: TLatLon; out PX, PY: Single): Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1169);{$ENDIF}
  { Маппинг гео -> пиксель сшитой карты. Прежний вариант
      PX := (Lon-MinLon)/RangeLon * (Width-1);
      PY := (MaxLat-Lat)/RangeLat * (Height-1);
    имел два дефекта, из-за которых ОДНА точка семплилась ПО-РАЗНОМУ в
    зависимости от охвата сшивки (соседние превью-тайлы и суперы дальнего
    рельефа расходились по высоте на швах):
      1) (Width-1) — «узловая» регистрация, а terrarium пиксель-центровый:
         доля texel'а под точкой зависела от числа тайлов в сшивке;
      2) широта интерполировалась ЛИНЕЙНО, а slippy-тайлы — Меркатор:
         ошибка также зависела от охвата. Долгота у slippy линейна,
         поэтому дефект (2) не трогал вертикальные швы — характерный
         симптом «N-S стыкуются, W-E порваны».
    Теперь: пиксель-центр (-0.5) и Меркатор по широте. Обе шкалы аффинны
    ГЛОБАЛЬНЫМ slippy-пиксельным координатам зума: масштаб — мировая
    константа зума, смещение между любыми сшивками одного зума — целые
    пиксели (кромки сшивок лежат на границах тайлов). Значит выбор texel'ов
    и веса билинейки не зависят от охвата карты: швы совпадают, а сэмплинг
    согласуется с глобально-пиксельным конвейером рельефа (GPX0/PitchPx). }
  { Бокс-члены маппинга (RangeLon / MTop / MSpan) предвычислены в
    THeightmap.Create — tan/ln/cos Меркатора не пересчитываются на каждый
    сэмпл. }
  if (HM.RangeLon <= 0) or (HM.MercSpan <= 0) then
  begin
    PX := 0; PY := 0;
    Exit(False);
  end;

  PX := (P.Lon - HM.Box.MinLon)      / HM.RangeLon * HM.Width  - 0.5;
  PY := (HM.MercTop - MercN(P.Lat))  / HM.MercSpan * HM.Height - 0.5;

  Result := (PX >= -0.5) and (PX <= HM.Width  - 0.5)
        and (PY >= -0.5) and (PY <= HM.Height - 0.5);
end;

class function THeightmapSampler.SampleBilinear(const HM: THeightmap;
  const P: TLatLon): Single;
var
  PX, PY:           Single;
  IX, IY:           Integer;
  FX, FY:           Single;
  H00, H10, H01, H11: Single;
  Top, Bot:         Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1170);{$ENDIF}
  LatLonToPixel(HM, P, PX, PY);

  IX := Floor(PX);
  IY := Floor(PY);
  FX := PX - IX;
  FY := PY - IY;

  H00 := HM.SampleClamped(IX,     IY);
  H10 := HM.SampleClamped(IX + 1, IY);
  H01 := HM.SampleClamped(IX,     IY + 1);
  H11 := HM.SampleClamped(IX + 1, IY + 1);

  Top := H00 + FX * (H10 - H00);
  Bot := H01 + FX * (H11 - H01);
  Result := Top + FY * (Bot - Top);
end;

{ Approximating cubic kernel (uniform cubic B-spline). Unlike an interpolating kernel it does NOT
  pass through the pixel values — it low-passes them, which is what's needed: the AWS heights are
  integer-metre quantised (a staircase), and an interpolating kernel must reproduce the steps
  (Catmull-Rom as an overshoot "wave", monotone as flat "terraces"). The B-spline is C2 and
  convex-hull bounded, so it never overshoots and smooths the 1 m steps into a continuous slope.
  Cost: real peaks soften slightly — irrelevant at ~9 m source resolution. }
function BSplineCubic1D(p0, p1, p2, p3, t: Single): Single;
var
  t2, t3, w0, w1, w2, w3: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1533);{$ENDIF}
  t2 := t * t;
  t3 := t2 * t;
  w0 := (1.0 - 3.0*t + 3.0*t2 - t3) / 6.0;     { = (1-t)^3 / 6 }
  w1 := (4.0 - 6.0*t2 + 3.0*t3) / 6.0;
  w2 := (1.0 + 3.0*t + 3.0*t2 - 3.0*t3) / 6.0;
  w3 := t3 / 6.0;
  Result := w0*p0 + w1*p1 + w2*p2 + w3*p3;
end;

class function THeightmapSampler.CubicSamplePx(const HM: THeightmap;
  FX, FY: Single): Single;
var
  ix, iy, m, n: Integer;
  tx, ty:       Single;
  rows:         array[0..3] of Single;
  cols:         array[0..3] of Single;
  cx, cy:       array[0..3] of Integer;
  W, H:         Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1534);{$ENDIF}
  ix := Floor(FX);
  iy := Floor(FY);
  tx := FX - ix;
  ty := FY - iy;
  W := HM.FWidth;
  H := HM.FHeight;
  { Precompute the 4 clamped column and 4 clamped row indices ONCE (identical
    edge clamp to SampleClamped) and read FData directly, instead of clamping
    and recomputing Y*FWidth+X inside 16 SampleClamped calls per sample. }
  for m := 0 to 3 do
  begin
    cx[m] := ix - 1 + m;
    if cx[m] < 0 then cx[m] := 0 else if cx[m] >= W then cx[m] := W - 1;
    cy[m] := iy - 1 + m;
    if cy[m] < 0 then cy[m] := 0 else if cy[m] >= H then cy[m] := H - 1;
  end;
  for n := 0 to 3 do
  begin
    for m := 0 to 3 do
      rows[m] := HM.FData[cy[n] * W + cx[m]];
    cols[n] := BSplineCubic1D(rows[0], rows[1], rows[2], rows[3], tx);
  end;
  Result := BSplineCubic1D(cols[0], cols[1], cols[2], cols[3], ty);
end;

class function THeightmapStitcher.Stitch(const ATiles: array of THeightmap;
  ATilesX, ATilesY: Integer): THeightmap;
var
  Expected:   Integer;
  TileW, TileH: Integer;
  TotalW, TotalH: Integer;
  CombinedBox: TLatLonBox;
  TX, TY:     Integer;
  X, Y:       Integer;
  Src:        THeightmap;
  DstX, DstY: Integer;
  I:          Integer;
  Idx:        Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1536);{$ENDIF}
  Result := nil;

  Expected := ATilesX * ATilesY;
  if Length(ATiles) <> Expected then
    raise ERangeError.CreateFmt(
      'THeightmapStitcher.Stitch: expected %d tiles (%dx%d), got %d',
      [Expected, ATilesX, ATilesY, Length(ATiles)]);
  if Expected = 0 then
    raise ERangeError.Create('THeightmapStitcher.Stitch: empty tile array');

  TileW := ATiles[0].Width;
  TileH := ATiles[0].Height;
  for I := 1 to High(ATiles) do
    if (ATiles[I].Width <> TileW) or (ATiles[I].Height <> TileH) then
      raise ERangeError.CreateFmt(
        'THeightmapStitcher.Stitch: tile %d has size %dx%d, expected %dx%d',
        [I, ATiles[I].Width, ATiles[I].Height, TileW, TileH]);

  CombinedBox := TLatLonBox.Empty;
  for I := 0 to High(ATiles) do
    CombinedBox := CombinedBox.Union(ATiles[I].Box);

  TotalW := ATilesX * TileW;
  TotalH := ATilesY * TileH;

  Result := THeightmap.Create(TotalW, TotalH, CombinedBox);
  try
    { ATiles[Idx] = (TX, TY) with Idx = TY*TilesX + TX.
      Top-left tile occupies pixels (0..TileW-1, 0..TileH-1). }
    for TY := 0 to ATilesY - 1 do
      for TX := 0 to ATilesX - 1 do
      begin
        Idx := TY * ATilesX + TX;
        Src := ATiles[Idx];
        DstX := TX * TileW;
        DstY := TY * TileH;
        for Y := 0 to TileH - 1 do
          for X := 0 to TileW - 1 do
            Result[DstX + X, DstY + Y] := Src[X, Y];
      end;
  except
    FreeAndNil(Result);
    raise;
  end;
end;

class function TTerrariumDecoder.RGBToHeight(R, G, B: Byte): Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1173);{$ENDIF}
  Result := (Integer(R) * 256 + Integer(G) + Integer(B) / 256.0) - 32768.0;
end;

class function TTerrariumDecoder.Decode(const PngBytes: TBytes;
  const ATile: TTileXY): THeightmap;
var
  Img:    TFPMemoryImage;
  Reader: TFPReaderPNG;
  Stream: TBytesStream;
  X, Y:   Integer;
  C:      TFPColor;
  Pix:    PFPColorArray;
  Box:    TLatLonBox;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1175);{$ENDIF}
  Result := nil;
  { Создаём экземпляр ИМЕННО crack-класса: ниже стоит жёсткий каст
    TFPMemoryImageCrack(Img) ради protected FData, и с включёнными
    objectchecks он валиден только когда runtime-тип — crack (иначе
    EInvalidCast на каждом тайле). Полей у crack нет — поведение то же. }
  Img    := TFPMemoryImageCrack.Create(0, 0);
  Reader := TFPReaderPNG.Create;
  Stream := TBytesStream.Create(PngBytes);
  try
    try
      Img.LoadFromStream(Stream, Reader);
      Box := TTileMath.TileToLatLonBox(ATile);
      Result := THeightmap.Create(Img.Width, Img.Height, Box);
      if not Img.UsePalette then
      begin
        { Прямой доступ к сырым пикселям (см. TFPMemoryImageCrack).
          TFPColor is 16-bit per channel; 8-bit PNG has the byte
          duplicated in both halves, so >> 8 is exact. }
        Pix := PFPColorArray(TFPMemoryImageCrack(Img).FData);
        for Y := 0 to Img.Height - 1 do
          for X := 0 to Img.Width - 1 do
          begin
            C := Pix^[Y * Img.Width + X];
            Result.FData[Y * Img.Width + X] :=
              RGBToHeight(Byte(C.Red shr 8), Byte(C.Green shr 8), Byte(C.Blue shr 8));
          end;
      end
      else
        for Y := 0 to Img.Height - 1 do
          for X := 0 to Img.Width - 1 do
          begin
            C := Img.Colors[X, Y];
            { TFPColor is 16-bit per channel; 8-bit PNG has the byte
              duplicated in both halves, so >> 8 is exact. }
            Result.FData[Y * Img.Width + X] :=
              RGBToHeight(Byte(C.Red shr 8), Byte(C.Green shr 8), Byte(C.Blue shr 8));
          end;
    except
      FreeAndNil(Result);
      raise;
    end;
  finally
    Stream.Free;
    Reader.Free;
    Img.Free;
  end;
end;

destructor TTerrTileEntry.Destroy;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1537);{$ENDIF}
  FreeAndNil(Hm);
  inherited;
end;

{$IFDEF TILE_MEM_PROFILE}
function TTerrariumFetcher.MemoryBytes: Int64;
var
  E: TTerrTileEntry;
begin
  Result := 0;
  FLock.Enter;
  try
    for E in FTiles.Values do
      if (E <> nil) and (E.Hm <> nil) then
        Inc(Result, Int64(E.Hm.Width) * E.Hm.Height * SizeOf(Single));
  finally
    FLock.Leave;
  end;
end;
{$ENDIF}

constructor TTerrariumFetcher.Create(AFetcher: THTTPFetcherWithCache;
  const AUrlTemplate: string; AMaxTiles: Integer);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1176);{$ENDIF}
  inherited Create;
  FFetcher := AFetcher;
  if AUrlTemplate = '' then
    FUrlTemplate := OSM_DIRECTORY_MODE
  else
    FUrlTemplate := AUrlTemplate;
  if AMaxTiles < 4 then AMaxTiles := 4;
  FMaxTiles := AMaxTiles;
  FLock     := TCriticalSection.Create;
  FTiles    := specialize TObjectDictionary<Int64, TTerrTileEntry>.Create([doOwnsValues]);
  FLoading  := specialize TDictionary<Int64, Boolean>.Create;
  FRequested := specialize TDictionary<Int64, Boolean>.Create;
  FActiveLoads := 0;
  FReadyGrids := specialize TDictionary<string, THeightArray>.Create;
  FReadyZoom  := specialize TDictionary<string, Integer>.Create;
  FGridReq    := specialize TDictionary<string, Boolean>.Create;
  FGridLock   := TCriticalSection.Create;
  FGridQueue  := specialize TQueue<TGridJob>.Create;
  FGridWake   := TEvent.Create(nil, False, False, '');
  FGridWorker := nil;   { ленивое создание при первом запросе }
  FSeq      := 0;
  FAbortAll := False;
  FFitLayer := nil;     { второй слой ставится извне через SetFitLayer }
  {$IFDEF TILE_MEM_PROFILE}
  MemProbeAdd(Self, 'heightmap-cache', mkRAM, @MemoryBytes);
  {$ENDIF}
end;

destructor TTerrariumFetcher.Destroy;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1538);{$ENDIF}
  {$IFDEF TILE_MEM_PROFILE}MemProbeRemove(Self);{$ENDIF}
  { Stop new claims. Existing I/O keeps its owner alive until it returns. }
  FAbortAll := True;
  { Грид-воркер держит FLock/FTiles/FGrid* — остановить ДО любого освобождения. }
  if FGridWorker <> nil then
  begin
    FGridWorker.Terminate;
    if FGridWake <> nil then FGridWake.SetEvent;
    FGridWorker.WaitFor;
    FreeAndNil(FGridWorker);
  end;
  while InterlockedCompareExchange(FActiveLoads, 0, 0) > 0 do Sleep(1);
  { FFetcher is DI — NOT owned, do not free. Callers must have stopped
    using this object before it is destroyed. }
  FreeAndNil(FFitLayer);
  FreeAndNil(FTiles);     { frees every entry and its THeightmap }
  FreeAndNil(FLoading);
  FreeAndNil(FRequested);
  FreeAndNil(FReadyGrids);
  FreeAndNil(FReadyZoom);
  FreeAndNil(FGridReq);
  FreeAndNil(FGridLock);
  FreeAndNil(FGridQueue);
  FreeAndNil(FGridWake);
  FreeAndNil(FLock);
  inherited;
end;

procedure TTerrariumFetcher.SetFitLayer(ALayer: TFitHeightLayer);
begin
  if FFitLayer = ALayer then Exit;
  FreeAndNil(FFitLayer);
  FFitLayer := ALayer;
end;

function TTerrariumFetcher.TileKey(const ATile: TTileXY): Int64;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1539);{$ENDIF}
  { Биективный числовой ключ: Zoom в старших битах, затем X, Y (по 30 бит —
    X,Y < 2^Zoom при любом реальном зуме terrarium ≤ 15). Строковый вид
    'z/x/y' остаётся только в URL/диск-кэше (TTileMath.FormatTileUrl). }
  Result := (Int64(ATile.Zoom) shl 60) or (Int64(ATile.X) shl 30)
            or Int64(ATile.Y);
end;

procedure TTerrariumFetcher.EvictLocked;
var
  K, VictimKey: Int64;
  E, Victim: TTerrTileEntry;
  Low: Int64;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1540);{$ENDIF}
  while FTiles.Count > FMaxTiles do
  begin
    Victim := nil; VictimKey := 0; Low := High(Int64);
    for K in FTiles.Keys do
    begin
      E := FTiles[K];
      if (E.Pin <= 0) and (E.Seq < Low) then
      begin Low := E.Seq; Victim := E; VictimKey := K; end;
    end;
    if Victim = nil then Break;          { all pinned — over budget briefly }
    FTiles.Remove(VictimKey);            { doOwnsValues -> frees entry+Hm }
  end;
end;

function TTerrariumFetcher.AcquireTile(const ATile: TTileXY;
  ACacheOnly: Boolean): THeightmap;
const
  { Потолок ожидания чужого загрузчика: HTTP-подвис больше не крутит
    спин вечно — возвращаем nil (вызывающий рисует заглушку/фолбэк,
    слот FLoading отпустит сам загрузчик, когда очнётся). }
  WAIT_LOADER_TIMEOUT_MS = 30000;
var
  Key: Int64;
  E:   TTerrTileEntry;
  Hm:  THeightmap;
  WaitStarted: QWord;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1541);{$ENDIF}
  Key := TileKey(ATile);

  { Phase 1: claim — cached (pin+return) / become loader / wait for loader. }
  WaitStarted := GetTickCount64;
  repeat
    if FAbortAll then Exit(nil);   { teardown карты: не ждём никого }
    FLock.Enter;
    try
      if FTiles.TryGetValue(Key, E) then
      begin
        Inc(E.Pin); Inc(FSeq); E.Seq := FSeq;
        Exit(E.Hm);
      end;
      if not FLoading.ContainsKey(Key) then
      begin
        FLoading.Add(Key, True);
        Break;                            { we load it }
      end;
      if ACacheOnly then Exit(nil);        { never wait for another loader }
    finally
      FLock.Leave;
    end;
    Sleep(1);                             { another thread is decoding it }
    if GetTickCount64 - WaitStarted >= WAIT_LOADER_TIMEOUT_MS then
      Exit(nil);
  until False;

  { Phase 2: fetch+decode OUTSIDE the lock. }
  Hm := nil;
  try
    if ACacheOnly then
      Hm := FetchTileCachedOnly(ATile)
    else
      Hm := FetchTile(ATile);
  except
    Hm := nil;
  end;

  { Phase 3: publish (or drop) and release the loader slot. }
  FLock.Enter;
  try
    FLoading.Remove(Key);
    if Hm <> nil then
    begin
      E := TTerrTileEntry.Create;
      E.Hm := Hm; E.Pin := 1; Inc(FSeq); E.Seq := FSeq;
      FTiles.AddOrSetValue(Key, E);
      EvictLocked;
      Result := Hm;
    end
    else
      Result := nil;
  finally
    FLock.Leave;
  end;
end;

procedure TTerrariumFetcher.ReleaseTile(const ATile: TTileXY);
var
  E: TTerrTileEntry;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1542);{$ENDIF}
  FLock.Enter;
  try
    if FTiles.TryGetValue(TileKey(ATile), E) and (E.Pin > 0) then
      Dec(E.Pin);
  finally
    FLock.Leave;
  end;
end;

procedure TTerrariumFetcher.AbortFetches;
begin
  FAbortAll := True;
  if FFetcher <> nil then FFetcher.AbortAllRequests;
end;

procedure TTerrariumFetcher.RequestBackgroundStop;
begin
  AbortFetches;
  FGridLock.Enter;
  try
    if FGridWorker<>nil then FGridWorker.Terminate;
    if FGridWake<>nil then FGridWake.SetEvent;
  finally FGridLock.Leave end;
end;

procedure TTerrariumFetcher.JoinBackgroundStop;
begin
  if FGridWorker<>nil then FGridWorker.WaitFor;
  while InterlockedCompareExchange(FActiveLoads,0,0)>0 do Sleep(1);
end;

procedure TTerrariumFetcher.ResetFetchAbort;
begin
  FAbortAll := False;
  if FFetcher <> nil then FFetcher.ResetAbort;
end;

function TTerrariumFetcher.GetRegion(const ABox: TLatLonBox;
  AZoom: Integer; ACancel: PBoolean): THeightmap;
var
  Tiles: TTileXYArray;
  Hms:   array of THeightmap;
  I, TilesX, TilesY: Integer;
  AllOk: Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1543);{$ENDIF}
  Result := nil;
  Tiles := TTileMath.TilesCoveringBox(ABox, AZoom);
  if Length(Tiles) = 0 then Exit;

  SetLength(Hms, Length(Tiles));
  AllOk := True;
  try
    GenerationProgress('Height tiles', 0, Length(Tiles));
    for I := 0 to High(Tiles) do
    begin
      if (ACancel <> nil) and ACancel^ then Exit;
      Hms[I] := AcquireTile(Tiles[I]);     { pinned, cache-owned }
      if Hms[I] = nil then AllOk := False;
      GenerationProgress('Height tiles', I + 1, Length(Tiles));
    end;
    if (ACancel <> nil) and ACancel^ then Exit;
    if AllOk then
    begin
      { TilesCoveringBox is row-major: Tiles[0]=(minX,minY), Tiles[High]=
        (maxX,maxY) — same convention the old inline stitch used. }
      TilesX := Tiles[High(Tiles)].X - Tiles[0].X + 1;
      TilesY := Tiles[High(Tiles)].Y - Tiles[0].Y + 1;
      Result := THeightmapStitcher.Stitch(Hms, TilesX, TilesY);  { fresh, caller-owned }
    end;
  finally
    for I := 0 to High(Tiles) do
      if Hms[I] <> nil then
        ReleaseTile(Tiles[I]);
  end;
end;

function TTerrariumFetcher.TryHeightAtZoom(const P: TLatLon; AZoom: Integer;
  out AHeight: Single): Boolean;
var
  Maps: array[0..3] of THeightmap;
  Tiles: array[0..3] of TTileXY;
  Heights: array[0..3] of Single;
  WP, PX, PY, FX, FY, Lat: Double;
  X, Y: array[0..1] of Int64;
  IX, IY, I, J, N, Found: Integer;
  Tile: TTileXY;
begin
  Result := False; AHeight := 0; N := 0;
  if FAbortAll or (AZoom < 0) or (AZoom > 22) then Exit;
  WP := 256.0 * IntPower(2, AZoom);
  Lat := EnsureRange(P.Lat, -85.0511287, 85.0511287) * Pi / 180;
  PX := EnsureRange((P.Lon + 180) / 360 * WP, 0.0, WP - 1);
  PY := EnsureRange((1 - Ln(Tan(Lat) + 1 / Cos(Lat)) / Pi) * 0.5 * WP, 0.0, WP - 1);
  X[0] := Floor(PX); X[1] := Min(X[0] + 1, Round(WP) - 1);
  Y[0] := Floor(PY); Y[1] := Min(Y[0] + 1, Round(WP) - 1);
  FX := PX - X[0]; FY := PY - Y[0];
  try
    for IY := 0 to 1 do for IX := 0 to 1 do
    begin
      Tile := TTileXY.Make(X[IX] div 256, Y[IY] div 256, AZoom);
      Found := -1;
      for J := 0 to N - 1 do
        if (Tiles[J].X = Tile.X) and (Tiles[J].Y = Tile.Y) then Found := J;
      if Found < 0 then
      begin
        Found := N; Tiles[N] := Tile; Maps[N] := AcquireTile(Tile); Inc(N);
        if Maps[Found] = nil then Exit;
      end;
      Heights[IY * 2 + IX] := Maps[Found][X[IX] mod 256, Y[IY] mod 256];
    end;
    AHeight := (1-FX)*(1-FY)*Heights[0] + FX*(1-FY)*Heights[1] +
               (1-FX)*FY*Heights[2] + FX*FY*Heights[3];
    Result := not IsNan(AHeight) and not IsInfinite(AHeight);
  finally
    for I := 0 to N - 1 do if Maps[I] <> nil then ReleaseTile(Tiles[I]);
  end;
end;

function TTerrariumFetcher.GetRegionCachedOnly(const ABox: TLatLonBox;
  AZoom: Integer): THeightmap;
var
  Tiles: TTileXYArray;
  Hms:   array of THeightmap;
  I, TilesX, TilesY: Integer;
  AllOk: Boolean;
begin
  Result := nil;
  Tiles := TTileMath.TilesCoveringBox(ABox, AZoom);
  if Length(Tiles) = 0 then Exit;
  SetLength(Hms, Length(Tiles));
  AllOk := True;
  try
    for I := 0 to High(Tiles) do
    begin
      Hms[I] := AcquireTile(Tiles[I], True);   { только кэш, без сети }
      if Hms[I] = nil then AllOk := False;
    end;
    if AllOk then
    begin
      TilesX := Tiles[High(Tiles)].X - Tiles[0].X + 1;
      TilesY := Tiles[High(Tiles)].Y - Tiles[0].Y + 1;
      Result := THeightmapStitcher.Stitch(Hms, TilesX, TilesY);
    end;
  finally
    for I := 0 to High(Tiles) do
      if Hms[I] <> nil then
        ReleaseTile(Tiles[I]);
  end;
end;

function TTerrariumFetcher.PadForZoom(const ABox: TLatLonBox;
  AZoom: Integer): TLatLonBox;
begin
  { 2 texel'а зума + 1 м: краевым билинейным сэмплам нужен сосед за
    границей бокса (тот же запас, что у превью и суперов) }
  Result := ABox.ExpandMeters(
    2.0 * (2.0 * Pi * EARTH_RADIUS_M) * Cos(ABox.Center.Lat * DEG_TO_RAD)
    / (Int64(256) shl AZoom) + 1.0);
end;

procedure TTerrariumFetcher.RequestRegionLoad(const ABox: TLatLonBox;
  AZoom: Integer);
var
  Tiles: TTileXYArray;
  I: Integer;
begin
  Tiles := TTileMath.TilesCoveringBox(PadForZoom(ABox, AZoom), AZoom);
  for I := 0 to High(Tiles) do
    RequestTileLoad(Tiles[I]);
end;

function DecodeHeightResponse(const R: TFetchResult; const ATile: TTileXY): THeightmap;
const Signature: array[0..7] of Byte = ($89,$50,$4E,$47,$0D,$0A,$1A,$0A);
var I: Integer;
begin
  Result:=nil;
  if not R.Success or (Length(R.Data)<33) then Exit;
  for I:=0 to 7 do if R.Data[I]<>Signature[I] then Exit;
  { Reject wrong dimensions before the PNG reader allocates image memory. }
  if (R.Data[12]<>Ord('I')) or (R.Data[13]<>Ord('H')) or
     (R.Data[14]<>Ord('D')) or (R.Data[15]<>Ord('R')) or
     (R.Data[16]<>0) or (R.Data[17]<>0) or (R.Data[18]<>1) or (R.Data[19]<>0) or
     (R.Data[20]<>0) or (R.Data[21]<>0) or (R.Data[22]<>1) or (R.Data[23]<>0) then Exit;
  try Result:=TTerrariumDecoder.Decode(R.Data,ATile);
  except on E: Exception do FreeAndNil(Result);end;
end;

function TTerrariumFetcher.TileCandidates(const ATile: TTileXY;
  AllowRefresh: Boolean): TStringArray;
var B: TLatLonBox;
begin
  if SameText(Trim(FUrlTemplate),OSM_DIRECTORY_MODE) or (FUrlTemplate='') then begin
    B:=TTileMath.TileToLatLonBox(ATile);
    Result:=HeightServerCandidates(B.MinLat,B.MinLon,B.MaxLat,B.MaxLon,AllowRefresh);
  end else begin
    SetLength(Result,1);Result[0]:=FUrlTemplate;
  end;
end;

function TTerrariumFetcher.FetchTile(const ATile: TTileXY): THeightmap;
var
  Url: string;
  R:   TFetchResult;
  Candidates: TStringArray;
  I: Integer;
  Automatic: Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(512);{$ENDIF}
  Result := nil;
  if FFetcher = nil then
    raise EAccessViolation.Create('TTerrariumFetcher.FetchTile: fetcher not set');

  if FFetcher.Aborted then Exit;
  Automatic := SameText(Trim(FUrlTemplate), OSM_DIRECTORY_MODE) or (FUrlTemplate='');
  Candidates := TileCandidates(ATile, True);
  for I:=0 to High(Candidates) do begin
    if FFetcher.Aborted then Exit;
    if Automatic and not OsmEndpointCanTry('height:'+Candidates[I]) then Continue;
    Url := TTileMath.FormatTileUrl(Candidates[I], ATile);
    if Automatic then R := FFetcher.GetUrl(Url,3000,1) else R := FFetcher.GetUrl(Url);
    if FFetcher.Aborted then Exit;
    if R.Success then begin
      Result := DecodeHeightResponse(R,ATile);
      if Result=nil then FFetcher.InvalidateGetUrl(Url);
    end;
    { A missing tile is a coverage miss, not an outage of the whole service. }
    if Automatic and (R.StatusCode<>404) then
      OsmEndpointResult('height:'+Candidates[I],Result<>nil);
    if Result<>nil then Exit;
  end;
end;

function TTerrariumFetcher.FetchTileCachedOnly(const ATile: TTileXY): THeightmap;
var
  Url: string;
  R:   TFetchResult;
  Candidates: TStringArray;
  I: Integer;
begin
  Result := nil;
  if FFetcher = nil then Exit;
  Candidates := TileCandidates(ATile, False);
  for I:=0 to High(Candidates) do begin
    Url := TTileMath.FormatTileUrl(Candidates[I], ATile);
    R := FFetcher.GetUrlCachedOnly(Url);
    { Never let an older public DEM win over an available preferred provider.
      The worker will fetch this candidate; this cache-only path stays offline. }
    if not R.Success then Exit;
    Result := DecodeHeightResponse(R,ATile);
    if Result<>nil then Exit;
    FFetcher.InvalidateGetUrl(Url);
    Exit;
  end;
end;

function TTerrariumFetcher.GetSuperHeights(const ABox: TLatLonBox;
  AGrid, AZoom: Integer): THeightArray;
var
  HM:         THeightmap;
  IX, IZ:     Integer;
  DLat, DLon: Double;
  P:          TLatLon;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1544);{$ENDIF}
  Result := nil;
  if AGrid < 2 then Exit;

  { terrarium низкого разрешения (AZoom), сшитый под бокс супера. GetRegion декодит/кэширует
    тайлы; nil (сеть/дыра) -> возвращаем пусто, чтобы вызывающий оставил заглушку, а не яму на Y=0.
    Запас 2 texel'а зума: краевые билинейные сэмплы супера иначе клампятся на
    границе впритык-сшивки, и соседние суперы расходятся по высоте на швах —
    тот же дефект, что у превью-тайлов (см. BuildHeightPreview). Семплинг
    ниже идёт по точному ABox. }
  HM := GetRegion(ABox.ExpandMeters(
          2.0 * (2.0 * Pi * EARTH_RADIUS_M) * Cos(ABox.Center.Lat * DEG_TO_RAD)
          / (Int64(256) shl AZoom) + 1.0), AZoom);
  if HM = nil then Exit;
  try
    SetLength(Result, AGrid * AGrid);
    DLat := ABox.MaxLat - ABox.MinLat;
    DLon := ABox.MaxLon - ABox.MinLon;
    for IZ := 0 to AGrid - 1 do
    begin
      { строка 0 = север (MaxLat) }
      P.Lat := ABox.MaxLat - DLat * IZ / (AGrid - 1);
      for IX := 0 to AGrid - 1 do
      begin
        { столбец 0 = запад (MinLon) }
        P.Lon := ABox.MinLon + DLon * IX / (AGrid - 1);
        Result[IZ * AGrid + IX] := THeightmapSampler.SampleBilinear(HM, P);
      end;
    end;
  finally
    HM.Free;
  end;
end;

{ ---- Фоновая подгрузка terrarium-тайла для «пола» плейсхолдера ---------- }
type
  TTerrariumLoadThread = class(TThread)
  private
    FOwner: TTerrariumFetcher;
    FTile:  TTileXY;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TTerrariumFetcher; const ATile: TTileXY);
  end;

constructor TTerrariumLoadThread.Create(AOwner: TTerrariumFetcher;
  const ATile: TTileXY);
begin
  FOwner := AOwner;
  FTile  := ATile;
  FreeOnTerminate := True;
  inherited Create(False);
end;

procedure TTerrariumLoadThread.Execute;
var Hm: THeightmap; Key: Int64;
begin
  Key := FOwner.TileKey(FTile);
  try
    try
      Hm := FOwner.AcquireTile(FTile);   { fetch+decode в FTiles (или хит кэша) }
      if Hm <> nil then FOwner.ReleaseTile(FTile);   { unpin; остаётся в кэше }
    except
    end;
    FOwner.FLock.Enter;
    try FOwner.FRequested.Remove(Key); finally FOwner.FLock.Leave; end;
  finally
    InterlockedDecrement(FOwner.FActiveLoads);
  end;
end;

{ ---- ОДИН персистентный воркер грида + очередь (не поток-на-запрос) -------- }
type
  TTerrariumGridWorker = class(TThread)
  private
    FOwner: TTerrariumFetcher;
  protected
    procedure Execute; override;
  public
    constructor Create(AOwner: TTerrariumFetcher);
  end;

constructor TTerrariumGridWorker.Create(AOwner: TTerrariumFetcher);
begin
  FOwner := AOwner;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TTerrariumGridWorker.Execute;
var Job: TGridJob; Got: Boolean; H: THeightArray;
begin
  while not Terminated do
  begin
    FOwner.FGridWake.WaitFor(200);
    repeat
      Got := False;
      FOwner.FGridLock.Enter;
      try
        if FOwner.FGridQueue.Count > 0 then
        begin Job := FOwner.FGridQueue.Dequeue; Got := True; end;
      finally FOwner.FGridLock.Leave; end;
      if Got and (not Terminated) then
      begin
        try
          { TryHeightGridCached берёт FLock покадрово — main не блокируется }
          if FOwner.TryHeightGridCached(Job.Box, Job.N, Job.Zoom, H) then
          begin
            FOwner.FGridLock.Enter;
            try
              FOwner.FReadyGrids.AddOrSetValue(Job.Key, H);
              FOwner.FReadyZoom.AddOrSetValue(Job.Key, Job.Zoom);
            finally FOwner.FGridLock.Leave; end;
          end;
        except
        end;
        FOwner.FGridLock.Enter;
        try FOwner.FGridReq.Remove(Job.Key); finally FOwner.FGridLock.Leave; end;
      end;
    until (not Got) or Terminated;
  end;
end;

function TTerrariumFetcher.TryHeightCached(const P: TLatLon; AZoom: Integer;
  out AHeight: Single): Boolean;
const MAX_DETAIL_ZOOM = 15;   { потолок terrarium }
var Z, HiZoom: Integer; Tile: TTileXY; Key: Int64; E: TTerrTileEntry;
begin
  Result := False; AHeight := 0;
  HiZoom := MAX_DETAIL_ZOOM;
  if AZoom > HiZoom then HiZoom := AZoom;
  FLock.Enter;
  try
    { Предпочесть самые ПОДРОБНЫЕ уже загруженные высоты (их фоново тянет gen),
      иначе спускаться к грубым вплоть до запрошенного AZoom. Тайлы разных зумов
      сосуществуют в FTiles (ключ включает зум). }
    for Z := HiZoom downto AZoom do
    begin
      Tile := TTileMath.LatLonToTile(P, Z);
      Key  := TileKey(Tile);
      if FTiles.TryGetValue(Key, E) and (E <> nil) and (E.Hm <> nil) then
      begin
        AHeight := THeightmapSampler.SampleBilinear(E.Hm, P);
        Result  := True;
        Break;
      end;
    end;
  finally
    FLock.Leave;
  end;
end;

function TTerrariumFetcher.TryHeightGridCached(const ABox: TLatLonBox;
  AN, AZoom: Integer; out AHeights: THeightArray): Boolean;
var
  IX, IZ: Integer;
  P: TLatLon;
  HM: THeightmap;
begin
  { Раньше сетка собиралась ПО-ТОЧЕЧНО через TryHeightCached: каждая точка
    брала «самый детальный закэшированный» тайл под собой — внутри одной
    сетки смешивались зумы, а билинейка клампилась на кромке каждого
    одиночного тайла. Оба эффекта давали ступени между соседними
    заглушками (и внутри одной). Теперь: ОДИН зум на всю сетку, сшивка
    с запасом 2 texel'а (как у превью/суперов), строго из кэша — без
    сети, воркер не блокируется. Промах любого тайла -> False, вызывающий
    дозакажет RequestRegionLoad и перепроверит следующим тиком. }
  Result := False;
  AHeights := nil;
  if AN < 2 then Exit;
  HM := GetRegionCachedOnly(PadForZoom(ABox, AZoom), AZoom);
  if HM = nil then Exit;
  try
    SetLength(AHeights, AN * AN);
    for IZ := 0 to AN - 1 do
    begin
      P.Lat := ABox.MinLat + (ABox.MaxLat - ABox.MinLat) * IZ / (AN - 1);
      for IX := 0 to AN - 1 do
      begin
        P.Lon := ABox.MinLon + (ABox.MaxLon - ABox.MinLon) * IX / (AN - 1);
        AHeights[IZ * AN + IX] := THeightmapSampler.SampleBilinear(HM, P);
      end;
    end;
    Result := True;
  finally
    HM.Free;
  end;
end;

procedure TTerrariumFetcher.RequestTileLoad(const ATile: TTileXY);
var Key: Int64; Spawn: Boolean;
begin
  Key  := TileKey(ATile);
  Spawn := False;
  FLock.Enter;
  try
    if FAbortAll then Exit;
    { уже в кэше / уже грузится / уже запрошено -> НЕ плодим потоки и запросы }
    if not (FTiles.ContainsKey(Key) or FLoading.ContainsKey(Key)
            or FRequested.ContainsKey(Key)) then
    begin
      FRequested.Add(Key, True);
      InterlockedIncrement(FActiveLoads);
      Spawn := True;
    end;
  finally
    FLock.Leave;
  end;
  if Spawn then
  try
    TTerrariumLoadThread.Create(Self, ATile);   { FreeOnTerminate }
  except
    FLock.Enter;
    try FRequested.Remove(Key); finally FLock.Leave; end;
    InterlockedDecrement(FActiveLoads);
    raise;
  end;
end;

procedure TTerrariumFetcher.RequestHeightLoad(const P: TLatLon; AZoom: Integer);
begin
  RequestTileLoad(TTileMath.LatLonToTile(P, AZoom));
end;

procedure TTerrariumFetcher.RequestHeightGrid(const AKey: string;
  const ABox: TLatLonBox; AN, AZoom: Integer);
var Job: TGridJob;
begin
  FGridLock.Enter;
  try
    if FAbortAll then Exit;
    if FGridWorker = nil then
      FGridWorker := TTerrariumGridWorker.Create(Self);   { ленивое создание, ОДИН воркер }
    { уже готов / уже в очереди -> не дублируем }
    if not (FReadyGrids.ContainsKey(AKey) or FGridReq.ContainsKey(AKey)) then
    begin
      FGridReq.Add(AKey, True);
      Job.Key := AKey; Job.Box := ABox; Job.N := AN; Job.Zoom := AZoom;
      FGridQueue.Enqueue(Job);
      FGridWake.SetEvent;
    end;
  finally
    FGridLock.Leave;
  end;
end;

function TTerrariumFetcher.TryTakeHeightGrid(const AKey: string;
  out AHeights: THeightArray; out AZoom: Integer): Boolean;
begin
  Result := False; AHeights := nil; AZoom := 0;
  FGridLock.Enter;
  try
    if FReadyGrids.TryGetValue(AKey, AHeights) then
    begin
      FReadyGrids.Remove(AKey);
      { фактический зум, на котором воркер собрал грид (диагностика швов
        заглушек: сосед z10 против соседа z13 — вечная ступень) }
      if not FReadyZoom.TryGetValue(AKey, AZoom) then AZoom := 0;
      FReadyZoom.Remove(AKey);
      Result := True;
    end;
  finally
    FGridLock.Leave;
  end;
end;

end.
