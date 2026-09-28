unit Osm3dGeocode;

{ Osm3d-юниты отлаживались с выключенными overflow/range проверками. }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$codepage UTF8}

{ Поиск места по имени → координата (forward geocoding).

  Backend по умолчанию — публичный Nominatim (nominatim.openstreetmap.org).
  ВНИМАНИЕ — usage policy этого сервиса
  (https://operations.osmfoundation.org/policies/nominatim/):
    * НЕЛЬЗЯ автокомплит «по мере ввода» — только поиск по явному действию
      пользователя (Enter / кнопка). Виджет это соблюдает: один запрос на
      submit, минимальный интервал между запросами выдержан вызывающей стороной.
    * не более 1 запроса в секунду;
    * обязателен осмысленный User-Agent (задаётся ниже);
    * результаты кешируются (THTTPFetcherWithCache кеширует по URL);
    * нужна видимая атрибуция «© OpenStreetMap contributors» в UI.

  Чтобы переключиться на Photon / self-hosted / коммерческий провайдер —
  поменяйте GEOCODE_BASE_URL и, при необходимости, парсер ParseHits. }

interface

uses
  Classes,
  SysUtils,
  SyncObjs,
  Osm3dGeoMath;   { TLatLon, TLatLonBox }

const
  { Базовый endpoint. Сменив его, можно уйти на свой инстанс / Photon. }
  GEOCODE_BASE_URL = 'https://nominatim.openstreetmap.org/search';

  { User-Agent — ОБЯЗАТЕЛЕН политикой. Замените на контакт вашего проекта. }
  GEOCODE_USER_AGENT = 'osm3d-studio/1.0 (+https://github.com/local/osm3d)';

  GEOCODE_MAX_HITS_DEFAULT = 8;

type
  { Одно совпадение геокодера. }
  TGeoHit = record
    DisplayName: string;     { человекочитаемая строка для списка подсказок }
    Location:    TLatLon;    { центр найденного объекта }
    HasBox:      Boolean;    { есть ли bounding box (для «вписать в кадр») }
    Box:         TLatLonBox; { габариты объекта, если HasBox }
  end;
  TGeoHitArray = array of TGeoHit;

  { Запрос геокодера. ViewBox — необязательное смещение приоритета к текущему
    виду (Nominatim параметр viewbox), Bounded=False оставляет глобальный поиск,
    просто поднимая локальные совпадения. }
  TGeoQuery = record
    Text:        string;
    MaxHits:     Integer;
    HasViewBox:  Boolean;
    ViewBox:     TLatLonBox;
    AcceptLang:  string;     { '' → сервер решает; иначе напр. 'ru,en' }

    class function Make(const AText: string): TGeoQuery; static;
  end;

{ Синхронный поиск. False — сеть/парсинг не дали ни одного валидного хита.
  Блокирует поток до ответа — НЕ вызывать из главного потока UI. }
function GeocodeSearch(const AQuery: TGeoQuery; out AHits: TGeoHitArray): Boolean;

type
  { Фоновый геокодинг по образцу TIpLocateThread: Create → Poll() из главного
    потока. Execute не вызывает Synchronize, поэтому WaitFor при закрытии не
    может зайти в дедлок. Владелец освобождает экземпляр. }
  TGeocodeThread = class(TThread)
  private
    FLock:  TCriticalSection;
    FQuery: TGeoQuery;
    FDone:  Boolean;
    FDetached: Boolean;
    FOk:    Boolean;
    FHits:  TGeoHitArray;
  protected
    procedure Execute; override;
  public
    constructor Create(const AQuery: TGeoQuery);
    destructor  Destroy; override;
    { Relinquish ownership without waiting for an outstanding HTTP request. }
    procedure Detach;

    { Снимок состояния для главного потока. True — поиск завершён; тогда
      AOk говорит об успехе, AHits держит результат (копия). }
    function Poll(out ADone, AOk: Boolean; out AHits: TGeoHitArray): Boolean;
  end;

implementation

uses
  fphttpclient,
  opensslsockets,
  fpjson,
  jsonparser,
  Osm3dCache,
  Osm3dCacheHTTPFetcher,
  Osm3dOsmTagUtils;   { InvariantFmt }

class function TGeoQuery.Make(const AText: string): TGeoQuery;
begin
  Result.Text       := AText;
  Result.MaxHits    := GEOCODE_MAX_HITS_DEFAULT;
  Result.HasViewBox := False;
  Result.ViewBox    := TLatLonBox.Empty;
  Result.AcceptLang := '';
end;

{ Percent-encoding компонента запроса (RFC 3986 unreserved оставляем как есть).
  Своя реализация, чтобы не угадывать unit с URL-энкодером в данной сборке FPC. }
function UrlEncodeComponent(const S: string): string;
const
  HexD: array[0..15] of Char = '0123456789ABCDEF';
var
  I: Integer;
  B: Byte;
begin
  { Под {$codepage UTF8} string уже хранит UTF-8 побайтно, поэтому
    итерация по символам = итерация по байтам UTF-8 — то, что нужно. }
  Result := '';
  for I := 1 to Length(S) do
  begin
    B := Ord(S[I]);
    if ((B >= Ord('A')) and (B <= Ord('Z'))) or
       ((B >= Ord('a')) and (B <= Ord('z'))) or
       ((B >= Ord('0')) and (B <= Ord('9'))) or
       (B = Ord('-')) or (B = Ord('_')) or (B = Ord('.')) or (B = Ord('~')) then
      Result := Result + Chr(B)
    else
      Result := Result + '%' + HexD[B shr 4] + HexD[B and $0F];
  end;
end;

function F6(V: Double): string;
begin
  { точка-десятичный разделитель независимо от локали }
  Result := FormatFloat('0.000000', V, InvariantFmt);
end;

function BuildUrl(const Q: TGeoQuery): string;
var
  Lim: Integer;
begin
  Lim := Q.MaxHits;
  if Lim <= 0 then Lim := GEOCODE_MAX_HITS_DEFAULT;
  if Lim > 40 then Lim := 40;

  Result := GEOCODE_BASE_URL +
            '?format=jsonv2' +
            '&addressdetails=0' +
            '&limit=' + IntToStr(Lim) +
            '&q=' + UrlEncodeComponent(Q.Text);

  if Q.AcceptLang <> '' then
    Result := Result + '&accept-language=' + UrlEncodeComponent(Q.AcceptLang);

  { viewbox = left,top,right,bottom = minLon,maxLat,maxLon,minLat.
    bounded=0 → не отсекаем по рамке, только повышаем приоритет локальных. }
  if Q.HasViewBox and (not Q.ViewBox.IsEmpty) then
    Result := Result + '&viewbox=' +
              F6(Q.ViewBox.MinLon) + ',' + F6(Q.ViewBox.MaxLat) + ',' +
              F6(Q.ViewBox.MaxLon) + ',' + F6(Q.ViewBox.MinLat) +
              '&bounded=0';
end;

{ jsonv2 отдаёт массив объектов: lat, lon (строки), display_name,
  boundingbox = [south, north, west, east] (строки). }
function ParseHits(const ABody: TBytes; AMax: Integer;
  out AHits: TGeoHitArray): Boolean;
var
  S:    string;
  J:    TJSONData;
  Arr:  TJSONArray;
  O:    TJSONObject;
  BBox: TJSONArray;
  I, N: Integer;
  H:    TGeoHit;
  Lat, Lon, So, No_, We, Ea: Double;

  function StrNum(const AKey: string; out V: Double): Boolean;
  var D: TJSONData;
  begin
    D := O.Find(AKey);
    Result := False;
    if D = nil then Exit;
    if D.JSONType = jtNumber then begin V := D.AsFloat; Result := True; end
    else if D.JSONType = jtString then
      Result := TryStrToFloat(D.AsString, V, InvariantFmt);
  end;

begin
  AHits := nil;
  Result := False;
  if Length(ABody) = 0 then Exit;

  SetLength(S, Length(ABody));
  System.Move(ABody[0], S[1], Length(ABody));

  J := nil;
  try
    J := GetJSON(S);
  except
    on E: Exception do J := nil;
  end;
  if J = nil then Exit;

  try
    if not (J is TJSONArray) then Exit;
    Arr := TJSONArray(J);
    SetLength(AHits, Arr.Count);
    N := 0;
    for I := 0 to Arr.Count - 1 do
    begin
      if (AMax > 0) and (N >= AMax) then Break;
      if not (Arr.Items[I] is TJSONObject) then Continue;
      O := TJSONObject(Arr.Items[I]);

      if not (StrNum('lat', Lat) and StrNum('lon', Lon)) then Continue;
      if (Lat < -90) or (Lat > 90) or (Lon < -180) or (Lon > 180) then Continue;

      H.DisplayName := '';
      if O.Find('display_name') <> nil then
        H.DisplayName := O.Get('display_name', '');
      if H.DisplayName = '' then
        H.DisplayName := F6(Lat) + ', ' + F6(Lon);

      H.Location := TLatLon.Make(Lat, Lon);
      H.HasBox   := False;
      H.Box      := TLatLonBox.Empty;

      BBox := nil;
      if O.Find('boundingbox') is TJSONArray then
        BBox := TJSONArray(O.Find('boundingbox'));
      if (BBox <> nil) and (BBox.Count = 4) then
        if TryStrToFloat(BBox.Strings[0], So,  InvariantFmt) and
           TryStrToFloat(BBox.Strings[1], No_, InvariantFmt) and
           TryStrToFloat(BBox.Strings[2], We,  InvariantFmt) and
           TryStrToFloat(BBox.Strings[3], Ea,  InvariantFmt) then
        begin
          H.HasBox := True;
          H.Box := TLatLonBox.Make(So, We, No_, Ea);  { Min/Max lat, Min/Max lon }
        end;

      AHits[N] := H;
      Inc(N);
    end;
    SetLength(AHits, N);
    Result := N > 0;
  finally
    J.Free;
  end;
end;

function GeocodeSearch(const AQuery: TGeoQuery; out AHits: TGeoHitArray): Boolean;
var
  F: THTTPFetcherWithCache;
  R: TFetchResult;
begin
  Result := False;
  AHits := nil;
  if Trim(AQuery.Text) = '' then Exit;

  { Собственный фетчер с небольшим кешем: повтор того же запроса в рамках
    сессии берётся из кеша → выполняем условие политики «кешируйте результат».
    Для кеша между запусками подставьте сюда дисковый TCacheBase. }
  F := THTTPFetcherWithCache.Create(TMemoryCache.Create(512 * 1024), True);
  try
    F.UserAgent  := GEOCODE_USER_AGENT;   { обязателен политикой Nominatim }
    F.TimeoutMs  := 6000;
    F.MaxRetries := 1;
    try
      R := F.GetUrl(BuildUrl(AQuery));
    except
      on E: Exception do
        Exit;
    end;
    if R.Success and (Length(R.Data) > 0) then
      Result := ParseHits(R.Data, AQuery.MaxHits, AHits);
  finally
    F.Free;
  end;
end;

{ ------------------------- TGeocodeThread ------------------------- }

constructor TGeocodeThread.Create(const AQuery: TGeoQuery);
begin
  FLock  := TCriticalSection.Create;
  FQuery := AQuery;
  FDone  := False;
  FOk    := False;
  FHits  := nil;
  inherited Create(True);
  FreeOnTerminate := False;
  Start;
end;

destructor TGeocodeThread.Destroy;
begin
  inherited Destroy;                 { дождётся Execute (он без Synchronize) }
  FLock.Free;
end;

procedure TGeocodeThread.Execute;
var
  Ok:   Boolean;
  Hits: TGeoHitArray;
begin
  Hits := nil;
  Ok := False;
  try
    Ok := GeocodeSearch(FQuery, Hits);
  except
    on E: Exception do Ok := False;
  end;

  FLock.Enter;
  try
    FOk   := Ok;
    FHits := Hits;
    FDone := True;
    if FDetached then FreeOnTerminate := True;
  finally
    FLock.Leave;
  end;
end;

procedure TGeocodeThread.Detach;
var Complete:Boolean;
begin
  FLock.Enter;
  try
    Terminate;Complete:=FDone;
    if not Complete then FDetached:=True;
  finally FLock.Leave;end;
  if Complete then Free;
end;

function TGeocodeThread.Poll(out ADone, AOk: Boolean;
  out AHits: TGeoHitArray): Boolean;
begin
  FLock.Enter;
  try
    ADone := FDone;
    AOk   := FOk;
    if FDone then
      AHits := Copy(FHits, 0, Length(FHits))
    else
      AHits := nil;
  finally
    FLock.Leave;
  end;
  Result := ADone;
end;

end.
