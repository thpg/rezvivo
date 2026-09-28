{ GpxFile — парсер маршрутов GPS Exchange Format (.gpx).

  Наследник TFitFile: заполняет те же сырые точки (FRawPoints) через
  AddRawPoint и зовёт общий ConvertGpsToRoutePoints — дальше весь
  конвейер (RouteLatLon / RouteAltM / RouteStartUTC / ToRideSamples /
  ToGeoAltPoints / FIT-слой высот) работает без изменений, как с FIT.
  Код преобразования/экспорта НЕ дублируется — он весь из FitFile.

  Что читается из GPX:
    <trkpt lat lon>  — точки трека; если трека нет — <rtept> маршрута;
    <ele>            — высота, м (нет → «файл без высоты», см. HasAltitude);
    <time>           — ISO-8601 (Z или со смещением ±HH:MM); нет →
                       Timestamp=0 (солнце мира не ставится, как для FIT
                       без таймштампов).
  Каналов power/cadence/hr в GPX нет — помечаются INVALID_*, оценщик
  параметров честно скажет «нет данных», как для FIT без датчиков.

  Парсер — потоковый текстовый (без DOM): GPX это килобайты-мегабайты
  плоских тегов, DOM ни к чему. Пространства имён (префиксы вида
  <gpx:trkpt>) срезаются при сравнении имён тегов.

  Фабрика NewRouteParserForFile — выбор парсера по расширению файла:
  все места загрузки маршрутов зовут её вместо прямого TFitFile.Create. }
unit GpxFile;

{$mode objfpc}{$H+}
{$codepage UTF8}

interface

uses
  Classes, SysUtils,
  FitFile;

type
  TGpxFile = class(TFitFile)
  private
    { Разбор всех точек с именем тега ATag ('trkpt' или 'rtept') в тексте S.
      Дистанция/«была предыдущая» — снаружи: трек и маршрут (если вдруг
      оба) склеиваются в одну одометрию. Возвращает число добавленных. }
    function ParsePoints(const S, ATag: AnsiString;
      var ADistM: Double; var AHavePrev: Boolean;
      var APrevLat, APrevLon: Double; out AHaveEle, AHaveTime: Boolean): Integer;
  public
    function LoadFromFile(const Filename: String): Boolean; override;
  end;

{ Парсер маршрута по расширению: .gpx → TGpxFile, остальное → TFitFile.
  Результат освобождает вызывающий. }
function NewRouteParserForFile(const Filename: String): TFitFile;

implementation

uses
  Math, StrUtils, CastleLog;

const
  UNIX_EPOCH_DT  = 25569.0;      { 1970-01-01 как TDateTime }
  FIT_EPOCH_UNIX = 631065600;    { FIT-эпоха 1989-12-31 в unix-секундах }
  EARTH_R_M      = 6371000.0;

{ ── Теговые примитивы ──────────────────────────────────────────────── }

{ End of a markup item. Comments, CDATA and processing instructions are
  opaque to the element scanner; quotes and a DOCTYPE subset may contain '>'. }
function MarkupEnd(const S: AnsiString; P: Integer): Integer;
var Q, Brackets: Integer; Quote: Char; Declaration: Boolean;
begin
  if Copy(S,P,4)='<!--' then
  begin
    Q:=PosEx('-->',S,P+4);
    if Q=0 then raise EReadError.Create('Unterminated XML comment');
    Exit(Q+2);
  end;
  if Copy(S,P,9)='<![CDATA[' then
  begin
    Q:=PosEx(']]>',S,P+9);
    if Q=0 then raise EReadError.Create('Unterminated CDATA');
    Exit(Q+2);
  end;
  if Copy(S,P,2)='<?' then
  begin
    Q:=PosEx('?>',S,P+2);
    if Q=0 then raise EReadError.Create('Unterminated processing instruction');
    Exit(Q+1);
  end;
  Quote:=#0; Brackets:=0; Declaration:=Copy(S,P,2)='<!';
  for Q:=P+1 to Length(S) do
  begin
    if Quote<>#0 then
    begin if S[Q]=Quote then Quote:=#0; Continue end;
    if S[Q] in ['"', #39] then Quote:=S[Q]
    else if Declaration and (S[Q]='[') then Inc(Brackets)
    else if Declaration and (S[Q]=']') and (Brackets>0) then Dec(Brackets)
    else if (S[Q]='>') and (Brackets=0) then Exit(Q);
  end;
  raise EReadError.Create('Unterminated XML tag');
end;

function FindNamedTag(const S, Name: AnsiString; FromPos: Integer;
  Closing: Boolean): Integer;
var P,Q,StartName,NS,Last: Integer; Full: AnsiString; IsClose:Boolean;
begin
  P:=FromPos; Result:=0;
  while True do
  begin
    P:=PosEx('<',S,P);
    if (P=0) or (P=Length(S)) then Exit;
    Last:=MarkupEnd(S,P);
    if not (S[P+1] in ['!','?']) then
    begin
      IsClose:=S[P+1]='/';
      StartName:=P+1; if IsClose then Inc(StartName);
      Q:=StartName;
      while (Q<Last) and (S[Q] in ['A'..'Z','a'..'z','0'..'9',':','_','-','.']) do Inc(Q);
      Full:=Copy(S,StartName,Q-StartName);
      NS:=Pos(':',Full); if NS>0 then Full:=Copy(Full,NS+1,MaxInt);
      if (IsClose=Closing) and (Full=Name) then Exit(P);
    end;
    P:=Last+1;
  end;
end;

function FindTag(const S, Name: AnsiString; FromPos: Integer): Integer;
begin Result:=FindNamedTag(S,Name,FromPos,False) end;

function FindCloseTag(const S, Name: AnsiString; FromPos: Integer): Integer;
begin Result:=FindNamedTag(S,Name,FromPos,True) end;

function AttrValue(const Hdr, Name: AnsiString): AnsiString;
var P,StartName,StartValue: Integer; Quote:Char; AttrName:AnsiString;
begin
  Result:=''; P:=2;
  while (P<=Length(Hdr)) and not (Hdr[P] in [' ',#9,#10,#13,'/','>']) do Inc(P);
  while P<=Length(Hdr) do
  begin
    while (P<=Length(Hdr)) and (Hdr[P] in [' ',#9,#10,#13]) do Inc(P);
    if (P>Length(Hdr)) or (Hdr[P] in ['/','>']) then Exit;
    StartName:=P;
    while (P<=Length(Hdr)) and not (Hdr[P] in [' ',#9,#10,#13,'=','/','>']) do Inc(P);
    AttrName:=Copy(Hdr,StartName,P-StartName);
    while (P<=Length(Hdr)) and (Hdr[P] in [' ',#9,#10,#13]) do Inc(P);
    if (P>Length(Hdr)) or (Hdr[P]<>'=') then Exit;
    Inc(P);
    while (P<=Length(Hdr)) and (Hdr[P] in [' ',#9,#10,#13]) do Inc(P);
    if (P>Length(Hdr)) or not (Hdr[P] in ['"',#39]) then Exit;
    Quote:=Hdr[P]; Inc(P); StartValue:=P;
    while (P<=Length(Hdr)) and (Hdr[P]<>Quote) do Inc(P);
    if P>Length(Hdr) then Exit;
    if AttrName=Name then Exit(Copy(Hdr,StartValue,P-StartValue));
    Inc(P);
  end;
end;

function InnerText(const Cnt, Name: AnsiString): AnsiString;
var P,Q,Last,EndPos: Integer;
begin
  Result:=''; P:=FindTag(Cnt,Name,1); if P=0 then Exit;
  P:=MarkupEnd(Cnt,P)+1;
  EndPos:=FindCloseTag(Cnt,Name,P); if EndPos=0 then Exit;
  while P<EndPos do
  begin
    Q:=PosEx('<',Cnt,P); if (Q=0) or (Q>EndPos) then Q:=EndPos;
    Result:=Result+Copy(Cnt,P,Q-P);
    if Q=EndPos then Break;
    Last:=MarkupEnd(Cnt,Q);
    if Copy(Cnt,Q,9)='<![CDATA[' then
      Result:=Result+Copy(Cnt,Q+9,Last-Q-11)
    else if (Copy(Cnt,Q,4)<>'<!--') and (Copy(Cnt,Q,2)<>'<?') then
      Exit(''); { a numeric/time field cannot contain nested elements }
    P:=Last+1;
  end;
  Result:=Trim(Result);
end;

{ ── Числа/время/геодезия ───────────────────────────────────────────── }

{ ISO-8601 → секунды от FIT-эпохи (шкала TFitRawPoint.Timestamp).
  Формат: YYYY-MM-DDTHH:MM:SS[.fff][Z|±HH:MM]. 0 = не разобрано/нет. }
function IsoTimeToFitSec(const S: AnsiString): LongWord;
var
  Y, Mo, D, H, Mi, Se: Integer;
  OffH, OffM, P, Sign: Integer;
  DT: TDateTime;
  UnixSec: Int64;
begin
  Result := 0;
  if Length(S) < 19 then Exit;
  Y  := StrToIntDef(Copy(S, 1, 4), -1);
  Mo := StrToIntDef(Copy(S, 6, 2), -1);
  D  := StrToIntDef(Copy(S, 9, 2), -1);
  H  := StrToIntDef(Copy(S, 12, 2), -1);
  Mi := StrToIntDef(Copy(S, 15, 2), -1);
  Se := StrToIntDef(Copy(S, 18, 2), -1);
  if Se > 59 then Se := 59;   { високосная секунда }
  if (Y < 1990) or (Mo < 1) or (Mo > 12) or (D < 1) or (D > 31) or
     (H < 0) or (H > 23) or (Mi < 0) or (Mi > 59) or (Se < 0) then
    Exit;
  if not TryEncodeDate(Y, Mo, D, DT) then Exit;
  DT := DT + EncodeTime(H, Mi, Se, 0);
  { смещение ±HH:MM после секунд ('Z' — нулевое, пропускаем) }
  P := 20;
  while (P <= Length(S)) and (S[P] in ['0'..'9', '.', ',']) do Inc(P);
  if (P + 5 <= Length(S)) and ((S[P] = '+') or (S[P] = '-')) then
  begin
    if S[P] = '+' then Sign := 1 else Sign := -1;
    OffH := StrToIntDef(Copy(S, P + 1, 2), 0);
    OffM := StrToIntDef(Copy(S, P + 4, 2), 0);
    DT := DT - Sign * (OffH * 60 + OffM) / 1440.0;
  end;
  UnixSec := Round((DT - UNIX_EPOCH_DT) * 86400.0);
  if UnixSec <= FIT_EPOCH_UNIX then Exit;
  Result := LongWord(UnixSec - FIT_EPOCH_UNIX);
end;

function HaversineM(Lat1, Lon1, Lat2, Lon2: Double): Double;
var
  P1, P2, DP, DL, A: Double;
begin
  P1 := DegToRad(Lat1);
  P2 := DegToRad(Lat2);
  DP := DegToRad(Lat2 - Lat1);
  DL := DegToRad(Lon2 - Lon1);
  A := Sqr(Sin(DP / 2)) + Cos(P1) * Cos(P2) * Sqr(Sin(DL / 2));
  Result := 2 * EARTH_R_M * ArcSin(Sqrt(A));
end;

{ ── TGpxFile ───────────────────────────────────────────────────────── }

function TGpxFile.ParsePoints(const S, ATag: AnsiString;
  var ADistM: Double; var AHavePrev: Boolean;
  var APrevLat, APrevLon: Double; out AHaveEle, AHaveTime: Boolean): Integer;
var
  TagPos, GtPos, EndPos, ClosePos, GtPos2: Integer;
  Hdr, Cnt, LatS, LonS, EleS, TimeS: AnsiString;
  Lat, Lon, Ele: Double;
  AltRawV, Ts: LongWord;
  Fmt: TFormatSettings;
begin
  Result := 0;
  AHaveEle := False;
  AHaveTime := False;
  Fmt := DefaultFormatSettings;
  Fmt.DecimalSeparator := '.';

  TagPos := 1;
  while True do
  begin
    TagPos := FindTag(S, ATag, TagPos);
    if TagPos = 0 then Break;
    GtPos := MarkupEnd(S, TagPos);
    if GtPos = 0 then Break;
    Hdr := Copy(S, TagPos, GtPos - TagPos + 1);

    { тело элемента: '/>' — самозакрытый; иначе до '</...ATag>' }
    if (GtPos >= 2) and (S[GtPos - 1] = '/') then
    begin
      Cnt := '';
      EndPos := GtPos + 1;
    end
    else
    begin
      ClosePos := FindCloseTag(S, ATag, GtPos + 1);
      if ClosePos = 0 then
      begin
        Cnt := Copy(S, GtPos + 1, MaxInt);
        EndPos := Length(S) + 1;
      end
      else
      begin
        Cnt := Copy(S, GtPos + 1, ClosePos - GtPos - 1);
        GtPos2 := MarkupEnd(S, ClosePos);
        if GtPos2 = 0 then
          EndPos := Length(S) + 1
        else
          EndPos := GtPos2 + 1;
      end;
    end;
    TagPos := EndPos;

    LatS := AttrValue(Hdr, 'lat');
    LonS := AttrValue(Hdr, 'lon');
    if (LatS = '') or (LonS = '') then Continue;
    Lat := StrToFloatDef(LatS, 400, Fmt);
    Lon := StrToFloatDef(LonS, 400, Fmt);
    if (Abs(Lat) > 90) or (Abs(Lon) > 180) then Continue;

    EleS  := InnerText(Cnt, 'ele');
    TimeS := InnerText(Cnt, 'time');

    if AHavePrev then
      ADistM := ADistM + HaversineM(APrevLat, APrevLon, Lat, Lon);
    APrevLat := Lat;
    APrevLon := Lon;
    AHavePrev := True;

    if EleS <> '' then
    begin
      Ele := StrToFloatDef(EleS, 0, Fmt);
      AltRawV := LongWord(Round((Ele + ALT_OFFSET) * ALT_SCALE));
      AHaveEle := True;
    end
    else
      AltRawV := INVALID_U32;

    Ts := IsoTimeToFitSec(TimeS);
    if Ts <> 0 then
      AHaveTime := True;

    AddRawPoint(LongInt(Round(Lat / SEMICIRCLE_TO_DEG)),
      LongInt(Round(Lon / SEMICIRCLE_TO_DEG)), AltRawV, ADistM, Ts,
      INVALID_U32 { speed }, INVALID_U16 { power },
      INVALID_U8 { cadence }, INVALID_U8 { hr }, 127 { temp }, False);
    Inc(Result);
  end;
end;

function TGpxFile.LoadFromFile(const Filename: String): Boolean;
var
  FS: TFileStream;
  S: AnsiString;
  DistM, PrevLat, PrevLon: Double;
  HavePrev, HaveEle, HaveTime, HaveEle2, HaveTime2: Boolean;
  N: Integer;
begin
  Result := False;
  ResetData;
  ResetParseState;
  FName := ChangeFileExt(ExtractFileName(Filename), '');

  if not FileExists(Filename) then
  begin
    WritelnLog('GpxFile', 'Файл не найден: ' + Filename);
    Exit;
  end;

  try
    FS := TFileStream.Create(Filename, fmOpenRead or fmShareDenyWrite);
    try
      SetLength(S, FS.Size);
      if FS.Size > 0 then
        FS.ReadBuffer(S[1], FS.Size);
    finally
      FS.Free;
    end;
  except
    on E: Exception do
    begin
      WritelnLog('GpxFile', 'Ошибка чтения ' + Filename + ': ' + E.Message);
      Exit;
    end;
  end;

  DistM := 0;
  HavePrev := False;
  PrevLat := 0;
  PrevLon := 0;
  HaveEle := False;
  HaveTime := False;

  try
    N := ParsePoints(S, 'trkpt', DistM, HavePrev, PrevLat, PrevLon,
      HaveEle, HaveTime);
    if N = 0 then
      N := ParsePoints(S, 'rtept', DistM, HavePrev, PrevLat, PrevLon,
        HaveEle2, HaveTime2)
    else
    begin
      HaveEle2 := False;
      HaveTime2 := False;
    end;
    HaveEle := HaveEle or HaveEle2;
    HaveTime := HaveTime or HaveTime2;

    ConvertGpsToRoutePoints;
    SetLength(FRawPoints, FRawCount);   { ужать, как в TFitFile }

    WritelnLog('GpxFile', Format(
      'Загружен %s: %d точек маршрута (высота: %s, время: %s, %.1f км)',
      [Filename, FRawCount,
       BoolToStr(HaveEle, True), BoolToStr(HaveTime, True), DistM / 1000.0]));
    Result := True;
  except
    on E: Exception do
    begin
      ResetData;
      ResetParseState;
      WritelnLog('GpxFile', 'Invalid GPX: ' + E.Message);
      Result := False;
    end;
  end;
end;

function NewRouteParserForFile(const Filename: String): TFitFile;
begin
  if LowerCase(ExtractFileExt(Filename)) = '.gpx' then
    Result := TGpxFile.Create
  else
    Result := TFitFile.Create;
end;

end.
