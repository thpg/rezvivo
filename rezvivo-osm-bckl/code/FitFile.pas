{ FitFile — парсер бинарного формата Garmin .fit.

  Читает:
    • record (msg 20)        — GPS-точки активности или курса:
                               position_lat, position_long, altitude,
                               distance, timestamp.
    • workout_step (msg 27)  — шаги структурированной тренировки:
                               wkt_step_name, intensity, duration_type/value,
                               target_type/value, custom_target_value_low/high.
  Прочие глобальные сообщения (file_id, lap, session, hr, …) пропускаются
  по размеру их definition'а.

  Поддерживается:
    • стандартный заголовок 12 или 14 байт с проверкой ненулевого CRC заголовка;
    • little-endian и big-endian (поле architecture в definition);
    • developer-fields (только пропускаются по размеру);
    • CRC файла и полнота всех объявленных записей;
    • compressed-timestamp data records (бит 7 заголовка записи установлен).

  Не поддерживается / упрощения:
    • массивы и строки длиннее объявленного size — читается ровно
      Field.Size байт;
    • многосессионные FIT — читаются как один сплошной поток;
    • enhanced_altitude/enhanced_speed (поля 78/73) — игнорируются,
      используется обычное altitude (поле 2). }
unit FitFile;

{$mode objfpc}{$H+}
{$codepage UTF8}

interface

uses
  Classes, SysUtils,
  RouteWorkoutFile,
  GameSensorLog,
  RideParamEstimator, { TRideSampleArray — экспорт каналов в оценщик }
  Osm3dGeoMath,       { TLatLon — для гео-маршрута стриминговой карты }
  Osm3dMapUtils;      { TRouteAltArray — высоты гео-маршрута }

const
  { Sentinel-значения «поле не задано» (те же, что в FIT-SDK) и шкалы
    record-полей. В interface: сырые точки заполняют и наследники-парсеры
    (GpxFile), не только сам FIT. }
  INVALID_S32 = $7FFFFFFF;
  INVALID_U16 = $FFFF;
  INVALID_U32 = $FFFFFFFF;
  INVALID_U8  = $FF;
  SEMICIRCLE_TO_DEG = 180.0 / 2147483648.0;
  ALT_SCALE         = 5.0;
  ALT_OFFSET        = 500.0;

type
  { Гео-маршрут (lat/lon) для стримингового пайплайна Osm3d.
    Совпадает по типу с Osm3dMapUtils.TRouteLatLonArray. }
  TFitLatLonArray = array of TLatLon;

  { Синхронная запись геоточки для нивелирования датума высот
    (Osm3dFitDatum): координаты, СЫРАЯ высота FIT и время от старта —
    все из одной FRawPoints, поэтому индекс-в-индекс согласованы. }
  TFitGeoAltPoint = record
    Lat, Lon: Double;    { градусы }
    AltM:     Double;    { сырая высота FIT, м (до датум-коррекции) }
    TimeSec:  Double;    { секунды от первой точки }
  end;
  TFitGeoAltArray = array of TFitGeoAltPoint;

type
  { Внутренние типы — нужны для объявления полей TFitFile.
    Не предназначены для использования снаружи юнита. }
  TFitFieldDef = record
    FieldNum:  Byte;
    Size:      Byte;
    BaseType:  Byte;
    Offset:    Integer;     { смещение от начала data record, байт }
  end;
  TFitFieldDefArray = array of TFitFieldDef;

  TFitMessageDef = record
    Defined:      Boolean;
    BigEndian:    Boolean;
    GlobalMsgNum: Word;
    Fields:       TFitFieldDefArray;
    DataSize:     Integer;  { сумма размеров обычных полей }
    DevSize:      Integer;  { сумма размеров developer-полей }
  end;

  TFitRawPoint = record
    LatSemi:    LongInt;    { семициклы; INVALID_S32 если нет }
    LonSemi:    LongInt;
    AltRaw:     LongWord;   { uint16 raw ЛИБО uint32 enhanced;
                              INVALID_U32 если нет }
    DistanceM:  Single;     { 0 если нет }
    Timestamp:  LongWord;   { сек от FIT-эпохи; 0 если нет }
    { ── каналы для оценщика параметров (RideParamEstimator) ── }
    SpeedRaw:   LongWord;   { мм/с (u16 speed ЛИБО u32 enhanced);
                              INVALID_U32 если нет }
    PowerRaw:   Word;       { Вт; INVALID_U16 если нет }
    CadenceRaw: Byte;       { об/мин; $FF если нет }
    HrRaw:      Byte;       { уд/мин; $FF если нет }
    TempRaw:    ShortInt;   { °C; 127 если нет }
    HasEnhAlt:  Boolean;    { AltRaw пришёл из enhanced_altitude }
  end;
  TFitRawPointArray = array of TFitRawPoint;

  { Optional telemetry consumer, including indoor records without GPS.
    Called during parsing; discard its output if LoadFromFile fails. }
  TFitSensorRecordEvent = procedure(const ARecord: TSensorSessionRecord) of object;

  TFitFile = class(TRouteWorkoutFile)
  protected   { protected, а не private: TGpxFile (GpxFile.pas) заполняет
                те же сырые точки и зовёт общий ConvertGpsToRoutePoints }
    FBuf:        array of Byte;
    FPos:        Integer;
    FEndPos:     Integer;
    FLocalDefs:  array [0..15] of TFitMessageDef;
    FRawPoints:  TFitRawPointArray;
    FRawCount:   Integer;
    FLastTimestamp: LongWord;
    FHasLastTimestamp: Boolean;
    FParseFailed: Boolean;
    FOnSensorRecord: TFitSensorRecordEvent;

    { Координаты первой валидной GPS-точки трека. Используются для
      обратной конвертации локальных X/Z (метры) в WGS-84 lat/lng,
      что нужно для запросов в внешний DEM-API (Open-Meteo и т.п.).
      Заполняются в ConvertGpsToRoutePoints. }
    FOriginLatDeg: Double;
    FOriginLonDeg: Double;
    FHasOrigin:    Boolean;

    { Первая известная FIT-метка (секунды от FIT-эпохи 1989-12-31).
      0 если в файле нет таймштампов. Заполняется в ConvertGpsToRoutePoints.
      Для перевода в UTC: StartTimestampSec + 631065600 = Unix-секунды. }
    FStartTimestampSec: LongWord;
    FRelativeTimeSec: array of Double;

    { Гео-координаты трека (lat/lon, градусы WGS-84). Только валидные
      точки — записи без GPS-фикса (INVALID_S32) пропускаются, иначе
      стриминговая карта получит выброс в (0,0). Заполняется в
      ConvertGpsToRoutePoints параллельно с FRoutePoints. }
    FRouteLatLon: TFitLatLonArray;

    { Оригинальная высота трека (абсолютные метры WGS-84, как в FIT —
      AltRaw/ALT_SCALE − ALT_OFFSET), параллельно FRouteLatLon по тому же
      индексу валидных точек. Источник для синих сфер «оригинальной
      высоты». Пусто, если в файле не было altitude. }
    FRouteAltM: TRouteAltArray;

    function HasBytes(N: Integer): Boolean;
    function ReadU16At(Idx: Integer; BE: Boolean): Word;
    function ReadU32At(Idx: Integer; BE: Boolean): LongWord;
    function ReadS32At(Idx: Integer; BE: Boolean): LongInt;

    procedure ResetParseState;
    function  ReadFitHeader: Boolean;
    procedure ParseRecord;
    procedure ParseDefinition(LocalType: Byte; HasDev: Boolean);
    procedure ParseDataMessage(LocalType: Byte; TimeOffset: Integer = -1);
    procedure HandleRecordMsg(const Def: TFitMessageDef; DataStart: Integer;
      MessageTimestamp: LongWord);
    procedure HandleWorkoutStepMsg(const Def: TFitMessageDef; DataStart: Integer);
    procedure AddRawPoint(LatSemi, LonSemi: LongInt; AltRaw: LongWord;
      DistanceM: Single; Timestamp: LongWord;
      SpeedRaw: LongWord; PowerRaw: Word;
      CadenceRaw, HrRaw: Byte; TempRaw: ShortInt; HasEnhAlt: Boolean);
    procedure ConvertGpsToRoutePoints;
    procedure ResolveRelativeTimes;
  public
    function LoadFromFile(const Filename: String): Boolean; override;
    property OnSensorRecord: TFitSensorRecordEvent read FOnSensorRecord write FOnSensorRecord;

    property OriginLatDeg:      Double   read FOriginLatDeg;
    property OriginLonDeg:      Double   read FOriginLonDeg;
    property HasOrigin:         Boolean  read FHasOrigin;
    { Первая известная FIT-метка времени. 0 = нет данных.
      Для конвертации в UTC TDateTime используй FitTimestampToUTC. }
    property StartTimestampSec: LongWord read FStartTimestampSec;

    { Гео-маршрут трека для стримингового пайплайна Osm3d.
      Пустой массив, если в файле нет валидных GPS-точек.
      Передаётся в TOsm3dStreamingSession.Create как ARoute и служит
      источником для проекции пути велосипедиста. }
    property RouteLatLon: TFitLatLonArray read FRouteLatLon;

    { Высоты трека (абсолютные метры), параллельно RouteLatLon. Пусто,
      если altitude в файле отсутствовал. }
    property RouteAltM: TRouteAltArray read FRouteAltM;

    { True, если хотя бы у одной точки есть валидная высота. Файл «только
      координаты» (GPX без <ele>, FIT без баро-канала) → False: высотный
      слой мира по такому файлу строить нельзя — нули сломали бы датум. }
    function HasAltitude: Boolean;

    { Время старта заезда в UTC (TDateTime). 0 если в файле нет
      таймштампов. Передаётся в TOsm3dStreamingSession.Create как
      AStartUTC — задаёт направление солнца стриминговой карты. }
    function RouteStartUTC: TDateTime;

    { Экспорт каналов записи (время/дистанция/скорость/высота/мощность/
      каденс/температура/курс) в формат оценщика параметров райдера.
      Отсутствующие каналы = RIDE_NO_VALUE. Время — секунды от первой
      известной метки; пропуски разрешены общей шкалой ResolveRelativeTimes.
      Курс — из последовательных lat/lon (равноугольное
      приближение, для ветровой модели этого достаточно). }
    function ToRideSamples: TRideSampleArray;

    { Геоточки с синхронными высотой и временем — вход датум-сети
      (Osm3dFitDatum). Только записи с валидным GPS-фиксом (как
      RouteLatLon), но с добавленным временем — то, чего RouteLatLon и
      ToRideSamples по отдельности не дают. }
    function ToGeoAltPoints: TFitGeoAltArray;
  end;

  { ── TFitFileWriter ────────────────────────────────────────────────

    Минимальный валидный FIT activity-файл из массива записей трейнера.

    Структура файла:
      Header (12 байт): size, protocol_version, profile_version (LE),
                        data_size (LE), ".FIT".
      Body:    file_id (msg 0)        — 1 запись;
               record   (msg 20)      — N записей с power/cadence/hr/
                                         speed/distance/grade;
               session  (msg 18)      — 1 запись со суммами;
               event    (msg 21)      — таймер и изменения интервалов/цели;
               lap      (msg 19)      — выполненные интервалы;
               activity (msg 34)      — 1 запись (без неё сервер
                                         возвращает status=rejected).
      Footer (2 байта): CRC-16 поверх header+body, FIT poly 0x84CF.

    Все числа little-endian. Timestamp в FIT — uint32 секунд от
    1989-12-31 00:00:00 UTC.

    GPS-полей в записях НЕТ — CSV-журнал индорный, координаты не
    пишутся. FIT/сервер допускают `record` без lat/lon. }
  TFitFileWriter = class
  private
    FBuf:           TMemoryStream;
    FStartUnix:     Int64;
    FEndUnix:       Int64;
    FRecordCount:   Integer;
    FTotalDistance: Double;       { metres, normalized to this activity }
    FMaxSpeedMs:    Single;       { м/с, для session }
    FElapsedSec, FTimerSec, FWorkJ: Double;
    FLapCount: Word;
    FErrorText: String;

    procedure WriteByte(B: Byte);
    procedure WriteWordLE(W: Word);
    procedure WriteSmallIntLE(V: SmallInt);
    procedure WriteLongWordLE(L: LongWord);
    procedure WriteString(const S: AnsiString; ASize: Integer);

    procedure WriteHeader(ADataSize: LongWord);
    procedure WriteFitCrc(ADataStart: Int64);

    procedure WriteFileIdDefinition;
    procedure WriteFileIdData;

    procedure WriteRecordDefinition;
    procedure WriteRecordData(const ARec: TSensorSessionRecord; DistanceM: Double);
    procedure WriteDeveloperMetadata;
    procedure WriteEventDefinition;
    procedure WriteEventData(const ARec: TSensorSessionRecord;
      Event, EventType: Byte);

    procedure WriteSessionDefinition;
    procedure WriteSessionData;

    procedure WriteLapDefinition;
    procedure WriteLapData(StartUnix, EndUnix: Int64;
      ElapsedSec, TimerSec, DistanceM, WorkJ: Double; FinalLap: Boolean);

    procedure WriteActivityDefinition;
    procedure WriteActivityData;

    function  ToFitTimestamp(AUnixSec: Int64): LongWord;
  public
    constructor Create;
    destructor  Destroy; override;

    { Сериализовать массив записей в .fit на диск. Возвращает True
      при успехе. Если ARecords пуст или записать в файл не удалось —
      False, ошибка в WritelnLog. }
    function SaveToFile(const ARecords: TSensorSessionRecordArray;
      const AFileName: String): Boolean;
    property ErrorText: String read FErrorText;
  end;

{ Конвертация FIT-таймштампа (секунды от FIT-эпохи 1989-12-31 00:00:00 UTC)
  в TDateTime (UTC).  Возвращает 0 если ATimestampSec = 0 (нет данных). }
function FitTimestampToUTC(ATimestampSec: LongWord): TDateTime;

implementation

uses
  {$ifdef MSWINDOWS}Windows,{$endif}
  Math, CastleVectors, CastleLog;

const
  { Базовые типы FIT (старший бит = endian-зависимость). }
  BT_ENUM    = $00;
  BT_SINT8   = $01;
  BT_UINT8   = $02;
  BT_SINT16  = $83;
  BT_UINT16  = $84;
  BT_SINT32  = $85;
  BT_UINT32  = $86;
  BT_STRING  = $07;
  BT_FLOAT32 = $88;
  BT_FLOAT64 = $89;
  BT_UINT8Z  = $0A;
  BT_UINT16Z = $8B;
  BT_UINT32Z = $8C;
  BT_BYTES   = $0D;

  { Глобальные номера сообщений, которые мы разбираем. }
  MSG_RECORD       = 20;
  MSG_WORKOUT      = 26;
  MSG_WORKOUT_STEP = 27;

  { Константы для record-полей (сентинелы и шкалы высоты/семициклов —
    в interface: ими пользуется GpxFile). }
  DIST_SCALE        = 100.0;

{ ── Публичные хелперы ────────────────────────────────────────────────── }

function FitTimestampToUTC(ATimestampSec: LongWord): TDateTime;
const
  { FIT-эпоха (1989-12-31 00:00:00 UTC) как TDateTime.
    = EncodeDate(1970,1,1) + FIT_EPOCH_UNIX/86400
    = 25569.0 + 631065600/86400 = 25569.0 + 7304.0 = 32873.0 }
  FIT_EPOCH_DT = 32873.0;
begin
  if ATimestampSec = 0 then
    Result := 0
  else
    Result := FIT_EPOCH_DT + ATimestampSec / 86400.0;
end;

{ ── Низкоуровневое чтение из FBuf с учётом архитектуры ───────────── }

function TFitFile.HasBytes(N: Integer): Boolean;
begin
  Result := (N >= 0) and (FPos >= 0) and (FPos <= FEndPos) and
    (N <= FEndPos - FPos);
  if not Result then FParseFailed := True;
end;

function TFitFile.ReadU16At(Idx: Integer; BE: Boolean): Word;
begin
  if BE then
    Result := (Word(FBuf[Idx]) shl 8) or Word(FBuf[Idx + 1])
  else
    Result := Word(FBuf[Idx]) or (Word(FBuf[Idx + 1]) shl 8);
end;

function TFitFile.ReadU32At(Idx: Integer; BE: Boolean): LongWord;
begin
  if BE then
    Result := (LongWord(FBuf[Idx])     shl 24) or
              (LongWord(FBuf[Idx + 1]) shl 16) or
              (LongWord(FBuf[Idx + 2]) shl  8) or
               LongWord(FBuf[Idx + 3])
  else
    Result :=  LongWord(FBuf[Idx])           or
              (LongWord(FBuf[Idx + 1]) shl  8) or
              (LongWord(FBuf[Idx + 2]) shl 16) or
              (LongWord(FBuf[Idx + 3]) shl 24);
end;

function TFitFile.ReadS32At(Idx: Integer; BE: Boolean): LongInt;
var
  U: LongWord;
begin
  U := ReadU32At(Idx, BE);
  Result := LongInt(U);
end;

{ ── Сброс состояния перед новой загрузкой ─────────────────────────── }

procedure TFitFile.ResetParseState;
var
  I: Integer;
begin
  SetLength(FBuf, 0);
  FPos := 0;
  FEndPos := 0;
  for I := 0 to 15 do
  begin
    FLocalDefs[I].Defined := False;
    FLocalDefs[I].BigEndian := False;
    FLocalDefs[I].GlobalMsgNum := 0;
    SetLength(FLocalDefs[I].Fields, 0);
    FLocalDefs[I].DataSize := 0;
    FLocalDefs[I].DevSize := 0;
  end;
  SetLength(FRawPoints, 0);
  FRawCount := 0;
  SetLength(FRouteLatLon, 0);
  SetLength(FRouteAltM, 0);
  SetLength(FRelativeTimeSec, 0);
  FOriginLatDeg := 0;
  FOriginLonDeg := 0;
  FHasOrigin := False;
  FStartTimestampSec := 0;
  FLastTimestamp := 0;
  FHasLastTimestamp := False;
  FParseFailed := False;
end;

{ ── Заголовок FIT ─────────────────────────────────────────────────── }

function FitCrcUpdate(ACrc: Word; AByte: Byte): Word; forward;

function TFitFile.ReadFitHeader: Boolean;
var
  HeaderSize: Byte;
  DataSize: LongWord;
  I: Integer;
  Crc: Word;
begin
  Result := False;
  if Length(FBuf) < 12 then Exit;

  HeaderSize := FBuf[0];
  if (HeaderSize <> 12) and (HeaderSize <> 14) then Exit;
  if Length(FBuf) < HeaderSize then Exit;

  { Заголовок всегда little-endian. }
  DataSize := LongWord(FBuf[4])         or
              (LongWord(FBuf[5]) shl  8) or
              (LongWord(FBuf[6]) shl 16) or
              (LongWord(FBuf[7]) shl 24);

  if (FBuf[8]  <> Byte(Ord('.'))) or
     (FBuf[9]  <> Byte(Ord('F'))) or
     (FBuf[10] <> Byte(Ord('I'))) or
     (FBuf[11] <> Byte(Ord('T'))) then
    Exit;

  if (QWord(HeaderSize) + DataSize + 2 <> QWord(Length(FBuf))) or
     (Length(FBuf) > High(Integer)) then Exit;
  if HeaderSize = 14 then
  begin
    Crc := 0;
    for I := 0 to 11 do Crc := FitCrcUpdate(Crc, FBuf[I]);
    if (ReadU16At(12, False) <> 0) and (ReadU16At(12, False) <> Crc) then Exit;
  end;
  Crc := 0;
  for I := 0 to Length(FBuf) - 3 do Crc := FitCrcUpdate(Crc, FBuf[I]);
  if Crc <> ReadU16At(Length(FBuf) - 2, False) then Exit;
  FPos := HeaderSize;
  FEndPos := HeaderSize + Integer(DataSize);

  Result := True;
end;

{ ── Разбор одной записи (definition или data) ────────────────────── }

procedure TFitFile.ParseRecord;
var
  Hdr: Byte;
  IsDef, HasDev: Boolean;
  LocalType: Byte;
begin
  if not HasBytes(1) then begin FPos := FEndPos; Exit; end;
  Hdr := FBuf[FPos];
  Inc(FPos);

  if (Hdr and $80) <> 0 then
  begin
    { Compressed-timestamp data record: биты 5-6 = local type. }
    LocalType := (Hdr shr 5) and $03;
    ParseDataMessage(LocalType, Hdr and $1F);
    Exit;
  end;

  IsDef     := (Hdr and $40) <> 0;
  HasDev    := (Hdr and $20) <> 0;
  LocalType := Hdr and $0F;

  if IsDef then
    ParseDefinition(LocalType, HasDev)
  else
    ParseDataMessage(LocalType);
end;

procedure TFitFile.ParseDefinition(LocalType: Byte; HasDev: Boolean);
var
  Arch, NumFields, NumDevFields: Byte;
  GlobalNum: Word;
  I: Integer;
  Field: TFitFieldDef;
  Offset, DevSize, DevFieldSize: Integer;
begin
  if LocalType > 15 then Exit;
  if not HasBytes(5) then begin FPos := FEndPos; Exit; end;

  { Reserved (1 байт) — пропускаем. }
  Inc(FPos);
  Arch := FBuf[FPos]; Inc(FPos);
  if Arch > 1 then begin FParseFailed := True; FPos := FEndPos; Exit; end;

  GlobalNum := ReadU16At(FPos, Arch <> 0);
  Inc(FPos, 2);

  NumFields := FBuf[FPos]; Inc(FPos);
  if not HasBytes(Integer(NumFields) * 3) then begin FPos := FEndPos; Exit; end;

  FLocalDefs[LocalType].Defined := True;
  FLocalDefs[LocalType].BigEndian := Arch <> 0;
  FLocalDefs[LocalType].GlobalMsgNum := GlobalNum;
  SetLength(FLocalDefs[LocalType].Fields, NumFields);

  Offset := 0;
  for I := 0 to Integer(NumFields) - 1 do
  begin
    Field.FieldNum := FBuf[FPos]; Inc(FPos);
    Field.Size     := FBuf[FPos]; Inc(FPos);
    Field.BaseType := FBuf[FPos]; Inc(FPos);
    Field.Offset   := Offset;
    FLocalDefs[LocalType].Fields[I] := Field;
    Inc(Offset, Field.Size);
  end;
  FLocalDefs[LocalType].DataSize := Offset;

  DevSize := 0;
  if HasDev then
  begin
    if not HasBytes(1) then begin FPos := FEndPos; Exit; end;
    NumDevFields := FBuf[FPos]; Inc(FPos);
    if not HasBytes(Integer(NumDevFields) * 3) then begin FPos := FEndPos; Exit; end;
    for I := 0 to Integer(NumDevFields) - 1 do
    begin
      { dev field header: field_num (1), size (1), dev_data_index (1) }
      Inc(FPos);
      DevFieldSize := FBuf[FPos]; Inc(FPos);
      Inc(FPos);
      Inc(DevSize, DevFieldSize);
    end;
  end;
  FLocalDefs[LocalType].DevSize := DevSize;
end;

procedure TFitFile.ParseDataMessage(LocalType: Byte; TimeOffset: Integer);
var
  Def: TFitMessageDef;
  DataStart, TotalSize: Integer;
  I, Delta: Integer;
  TimestampVal, RawTimestamp: LongWord;
begin
  if LocalType > 15 then Exit;
  Def := FLocalDefs[LocalType];
  if not Def.Defined then
  begin
    { Данные без определения — мы не знаем сколько байт пропустить.
      Файл явно битый, прерываем разбор. }
    WritelnLog('FitFile', Format(
      'Data record для local_type=%d без definition, прерываем разбор',
      [LocalType]));
    FPos := FEndPos;
    FParseFailed := True;
    Exit;
  end;

  TotalSize := Def.DataSize + Def.DevSize;
  if not HasBytes(TotalSize) then begin FPos := FEndPos; Exit; end;

  DataStart := FPos;
  TimestampVal := 0;
  if TimeOffset >= 0 then
  begin
    if not FHasLastTimestamp then
    begin FParseFailed := True; FPos := FEndPos; Exit; end;
    Delta := (TimeOffset - Integer(FLastTimestamp and $1F)) and $1F;
    if QWord(FLastTimestamp) + QWord(Delta) >= INVALID_U32 then
    begin FParseFailed := True; FPos := FEndPos; Exit; end;
    TimestampVal := FLastTimestamp + LongWord(Delta);
    FLastTimestamp := TimestampVal;
  end;
  { A normal timestamp in any global message seeds the next compressed
    header. Definitions describe only bytes actually present in the payload. }
  for I := 0 to High(Def.Fields) do
    if (Def.Fields[I].FieldNum = 253) and (Def.Fields[I].Size = 4) and
       (Def.Fields[I].BaseType = BT_UINT32) then
    begin
      RawTimestamp := ReadU32At(DataStart + Def.Fields[I].Offset, Def.BigEndian);
      if RawTimestamp <> INVALID_U32 then
      begin
        TimestampVal := RawTimestamp;
        FLastTimestamp := RawTimestamp;
        FHasLastTimestamp := True;
      end;
    end;
  case Def.GlobalMsgNum of
    MSG_RECORD:       HandleRecordMsg(Def, DataStart, TimestampVal);
    MSG_WORKOUT_STEP: HandleWorkoutStepMsg(Def, DataStart);
    { MSG_WORKOUT и прочие — игнорируем содержимое, просто продвигаемся }
  end;
  Inc(FPos, TotalSize);
end;

{ ── Обработчик record (msg 20) ────────────────────────────────────── }

procedure TFitFile.HandleRecordMsg(const Def: TFitMessageDef;
  DataStart: Integer; MessageTimestamp: LongWord);
var
  I: Integer;
  Field: TFitFieldDef;
  LatSemi, LonSemi: LongInt;
  AltRaw: LongWord;
  DistanceM: Single;
  TimestampVal: LongWord;
  RawU32: LongWord;
  RawU16: Word;
  HasLat, HasLon: Boolean;
  SpeedRaw: LongWord;
  PowerRaw: Word;
  CadenceRaw, HrRaw: Byte;
  TempRaw: ShortInt;
  HasEnhAlt: Boolean;
  GradeRaw: SmallInt;
  SensorRecord: TSensorSessionRecord;
begin
  LatSemi := 0;
  LonSemi := 0;
  AltRaw := INVALID_U32;
  DistanceM := 0;
  TimestampVal := MessageTimestamp;
  HasLat := False;
  HasLon := False;
  SpeedRaw := INVALID_U32;
  PowerRaw := INVALID_U16;
  CadenceRaw := $FF;
  HrRaw := $FF;
  TempRaw := 127;
  HasEnhAlt := False;
  GradeRaw := 0;

  for I := 0 to High(Def.Fields) do
  begin
    Field := Def.Fields[I];
    case Field.FieldNum of
      0:   { position_lat — sint32, semicircles }
        if (Field.Size = 4) and (Field.BaseType = BT_SINT32) then
        begin
          LatSemi := ReadS32At(DataStart + Field.Offset, Def.BigEndian);
          if LatSemi <> INVALID_S32 then HasLat := True;
        end;
      1:   { position_long — sint32, semicircles }
        if (Field.Size = 4) and (Field.BaseType = BT_SINT32) then
        begin
          LonSemi := ReadS32At(DataStart + Field.Offset, Def.BigEndian);
          if LonSemi <> INVALID_S32 then HasLon := True;
        end;
      2:   { altitude — uint16, scale=5, offset=500.
             Sentinel uint16 = $FFFF: оставляем AltRaw = INVALID_U32 как
             маркер "высоты нет". }
        if (Field.Size = 2) and (Field.BaseType = BT_UINT16) then
        begin
          RawU16 := ReadU16At(DataStart + Field.Offset, Def.BigEndian);
          if (RawU16 <> INVALID_U16) and (not HasEnhAlt) then
            AltRaw := RawU16;
        end;
      3:   { heart_rate — uint8, sentinel $FF }
        if (Field.Size = 1) and (Field.BaseType = BT_UINT8) then
          HrRaw := FBuf[DataStart + Field.Offset];
      4:   { cadence — uint8, об/мин, sentinel $FF }
        if (Field.Size = 1) and (Field.BaseType = BT_UINT8) then
          CadenceRaw := FBuf[DataStart + Field.Offset];
      5:   { distance — uint32, scale=100 -> m }
        if (Field.Size = 4) and (Field.BaseType = BT_UINT32) then
        begin
          RawU32 := ReadU32At(DataStart + Field.Offset, Def.BigEndian);
          if RawU32 <> INVALID_U32 then
            DistanceM := RawU32 / DIST_SCALE;
        end;
      6:   { speed — uint16, мм/с (scale 1000). enhanced приоритетнее. }
        if (Field.Size = 2) and (Field.BaseType = BT_UINT16) then
        begin
          RawU16 := ReadU16At(DataStart + Field.Offset, Def.BigEndian);
          if (RawU16 <> INVALID_U16) and (SpeedRaw = INVALID_U32) then
            SpeedRaw := RawU16;
        end;
      7:   { power — uint16, Вт, sentinel $FFFF }
        if (Field.Size = 2) and (Field.BaseType = BT_UINT16) then
        begin
          RawU16 := ReadU16At(DataStart + Field.Offset, Def.BigEndian);
          if RawU16 <> INVALID_U16 then
            PowerRaw := RawU16;
        end;
      9:   { grade — sint16, scale 100 }
        if (Field.Size = 2) and (Field.BaseType = BT_SINT16) then
        begin
          RawU16 := ReadU16At(DataStart + Field.Offset, Def.BigEndian);
          if RawU16 <> $7FFF then GradeRaw := SmallInt(RawU16);
        end;
      13:  { temperature — sint8, °C, sentinel 127 }
        if (Field.Size = 1) and (Field.BaseType = BT_SINT8) then
          TempRaw := ShortInt(FBuf[DataStart + Field.Offset]);
      73:  { enhanced_speed — uint32, мм/с }
        if (Field.Size = 4) and (Field.BaseType = BT_UINT32) then
        begin
          RawU32 := ReadU32At(DataStart + Field.Offset, Def.BigEndian);
          if RawU32 <> INVALID_U32 then
            SpeedRaw := RawU32;
        end;
      78:  { enhanced_altitude — uint32, scale=5, offset=500 }
        if (Field.Size = 4) and (Field.BaseType = BT_UINT32) then
        begin
          RawU32 := ReadU32At(DataStart + Field.Offset, Def.BigEndian);
          if RawU32 <> INVALID_U32 then
          begin
            AltRaw := RawU32;
            HasEnhAlt := True;
          end;
        end;
    end;
  end;

  if HasLat and HasLon then
    AddRawPoint(LatSemi, LonSemi, AltRaw, DistanceM, TimestampVal,
      SpeedRaw, PowerRaw, CadenceRaw, HrRaw, TempRaw, HasEnhAlt);

  if Assigned(FOnSensorRecord) and (TimestampVal <> 0) and
     (TimestampVal <> INVALID_U32) then
  begin
    SensorRecord := Default(TSensorSessionRecord);
    SensorRecord.TimestampUtcUnix := Int64(TimestampVal) + 631065600;
    SensorRecord.DistanceM := Trunc(DistanceM);
    if SpeedRaw <> INVALID_U32 then SensorRecord.SpeedKmh := SpeedRaw * 0.0036;
    if PowerRaw <> INVALID_U16 then SensorRecord.Power := PowerRaw;
    if CadenceRaw <> INVALID_U8 then SensorRecord.Cadence := CadenceRaw;
    if HrRaw <> INVALID_U8 then SensorRecord.HeartRate := HrRaw;
    SensorRecord.SlopePct := GradeRaw / 100.0;
    FOnSensorRecord(SensorRecord);
  end;
end;

{ ── Обработчик workout_step (msg 27) ──────────────────────────────── }

procedure TFitFile.HandleWorkoutStepMsg(const Def: TFitMessageDef;
  DataStart: Integer);
var
  I, J, NL: Integer;
  Field: TFitFieldDef;
  Step: TWorkoutStep;
  DurType, TgtType, IntensityVal: Byte;
  DurValue, TgtValue, CustomLow, CustomHigh: LongWord;
  StepName: String;
  C: AnsiChar;
begin
  DurType      := INVALID_U8;
  TgtType      := INVALID_U8;
  IntensityVal := INVALID_U8;
  DurValue     := INVALID_U32;
  TgtValue     := INVALID_U32;
  CustomLow    := INVALID_U32;
  CustomHigh   := INVALID_U32;
  StepName     := '';

  for I := 0 to High(Def.Fields) do
  begin
    Field := Def.Fields[I];
    case Field.FieldNum of
      0:  { wkt_step_name — string, нуль-терминированная или ровно Field.Size }
        if Field.BaseType = BT_STRING then
          for J := 0 to Integer(Field.Size) - 1 do
          begin
            C := AnsiChar(FBuf[DataStart + Field.Offset + J]);
            if C = #0 then Break;
            StepName := StepName + C;
          end;
      7:  { intensity — enum }
        if (Field.Size = 1) and (Field.BaseType = BT_ENUM) then
          IntensityVal := FBuf[DataStart + Field.Offset];
      1:  { duration_type — enum }
        if (Field.Size = 1) and (Field.BaseType = BT_ENUM) then
          DurType := FBuf[DataStart + Field.Offset];
      2:  { duration_value — uint32 }
        if (Field.Size = 4) and (Field.BaseType = BT_UINT32) then
          DurValue := ReadU32At(DataStart + Field.Offset, Def.BigEndian);
      3:  { target_type — enum }
        if (Field.Size = 1) and (Field.BaseType = BT_ENUM) then
          TgtType := FBuf[DataStart + Field.Offset];
      4:  { target_value — uint32 }
        if (Field.Size = 4) and (Field.BaseType = BT_UINT32) then
          TgtValue := ReadU32At(DataStart + Field.Offset, Def.BigEndian);
      5:  { custom_target_value_low — uint32 }
        if (Field.Size = 4) and (Field.BaseType = BT_UINT32) then
          CustomLow := ReadU32At(DataStart + Field.Offset, Def.BigEndian);
      6:  { custom_target_value_high — uint32 }
        if (Field.Size = 4) and (Field.BaseType = BT_UINT32) then
          CustomHigh := ReadU32At(DataStart + Field.Offset, Def.BigEndian);
    end;
  end;

  Step.Name := StepName;
  if (DurValue = INVALID_U32) and (DurType <> 5) then
    DurType := INVALID_U8;

  { Длительность. Единицы в FIT:
      0 (time)        → миллисекунды
      1 (distance)    → сантиметры
      4 (calories)    → ккал
      5 (open)        → нет
      6..13 (repeat_until_*) → meta, значение = индекс шага, на который ссылаемся
      28 (reps)       → штуки
    Прочие маппим в wdkUnknown с raw value. }
  case DurType of
    0:  begin Step.DurationKind := wdkTime;     Step.DurationValue := DurValue / 1000.0; end;
    1:  begin Step.DurationKind := wdkDistance; Step.DurationValue := DurValue / 100.0;  end;
    4:  begin Step.DurationKind := wdkCalories; Step.DurationValue := DurValue;          end;
    5:  begin Step.DurationKind := wdkOpen;     Step.DurationValue := 0;                 end;
    6..13: begin Step.DurationKind := wdkRepeat; Step.DurationValue := DurValue;          end;
  else
    Step.DurationKind  := wdkUnknown;
    Step.DurationValue := 0;
  end;

  { Тип цели. }
  case TgtType of
    0: Step.TargetKind := wtkSpeed;
    1: Step.TargetKind := wtkHeartRate;
    2: Step.TargetKind := wtkOpen;
    3: Step.TargetKind := wtkCadence;
    4: Step.TargetKind := wtkPower;
    5: Step.TargetKind := wtkGrade;
    6: Step.TargetKind := wtkResistance;
  else
    Step.TargetKind := wtkUnknown;
  end;

  { target_value=0 selects custom bounds; a nonzero value selects a zone.
    Preserve raw FIT target encoding: callers distinguish percentages,
    absolute values and zone indices using the workout target type. }
  if (TgtValue = 0) and (CustomLow <> INVALID_U32) and (CustomHigh <> INVALID_U32) then
  begin
    Step.TargetLow  := CustomLow;
    Step.TargetHigh := CustomHigh;
  end
  else if TgtValue <> INVALID_U32 then
  begin
    Step.TargetLow  := TgtValue;
    Step.TargetHigh := TgtValue;
  end
  else
  begin
    Step.TargetLow  := 0;
    Step.TargetHigh := 0;
  end;

  case IntensityVal of
    0: Step.Intensity := wiActive;
    1: Step.Intensity := wiRest;
    2: Step.Intensity := wiWarmup;
    3: Step.Intensity := wiCooldown;
    4: Step.Intensity := wiRecovery;
    5: Step.Intensity := wiInterval;
  else
    Step.Intensity := wiOther;
  end;

  NL := Length(FWorkoutSteps);
  SetLength(FWorkoutSteps, NL + 1);
  FWorkoutSteps[NL] := Step;
end;

{ ── Накопление сырых GPS-точек ────────────────────────────────────── }

procedure TFitFile.AddRawPoint(LatSemi, LonSemi: LongInt; AltRaw: LongWord;
  DistanceM: Single; Timestamp: LongWord;
  SpeedRaw: LongWord; PowerRaw: Word;
  CadenceRaw, HrRaw: Byte; TempRaw: ShortInt; HasEnhAlt: Boolean);
var
  RP: TFitRawPoint;
begin
  if FRawCount >= Length(FRawPoints) then
  begin
    if Length(FRawPoints) = 0 then
      SetLength(FRawPoints, 256)
    else
      SetLength(FRawPoints, Length(FRawPoints) * 2);
  end;
  RP.LatSemi    := LatSemi;
  RP.LonSemi    := LonSemi;
  RP.AltRaw     := AltRaw;
  RP.DistanceM  := DistanceM;
  RP.Timestamp  := Timestamp;
  RP.SpeedRaw   := SpeedRaw;
  RP.PowerRaw   := PowerRaw;
  RP.CadenceRaw := CadenceRaw;
  RP.HrRaw      := HrRaw;
  RP.TempRaw    := TempRaw;
  RP.HasEnhAlt  := HasEnhAlt;
  FRawPoints[FRawCount] := RP;
  Inc(FRawCount);
end;

{ ── Конвертация GPS в локальные TRoutePoint ──────────────────────── }

procedure TFitFile.ResolveRelativeTimes;
var
  I, J, Previous: Integer;
  Stamp: LongWord;
  Elapsed, PreviousTime: Double;
begin
  SetLength(FRelativeTimeSec, FRawCount);
  FStartTimestampSec := 0;
  Previous := -1;
  PreviousTime := 0;
  for I := 0 to FRawCount - 1 do
  begin
    FRelativeTimeSec[I] := 0;
    Stamp := FRawPoints[I].Timestamp;
    if (Stamp = 0) or (Stamp = INVALID_U32) then Continue;
    if Previous < 0 then
    begin
      FStartTimestampSec := Stamp;
      Previous := I;
      Continue;
    end;
    { Preserve raw missing timestamps. Only the exported timeline is resolved:
      interpolate inner gaps by sample index; clamp backward clock steps. }
    Elapsed := Int64(Stamp) - Int64(FStartTimestampSec);
    if Elapsed < PreviousTime then Elapsed := PreviousTime;
    for J := Previous + 1 to I do
      FRelativeTimeSec[J] := PreviousTime +
        (Elapsed - PreviousTime) * (J - Previous) / (I - Previous);
    Previous := I;
    PreviousTime := Elapsed;
  end;
  { No extrapolation before the first or after the last known timestamp.
    With no timestamps all values remain zero, without a fictional 1 Hz clock. }
  if Previous >= 0 then
    for I := Previous + 1 to FRawCount - 1 do
      FRelativeTimeSec[I] := PreviousTime;
end;

procedure TFitFile.ConvertGpsToRoutePoints;
var
  I, GeoCount: Integer;
  LocOriginLatDeg, LocOriginLonDeg, LocOriginAlt: Double;
  LocHasOrigin: Boolean;
  LatDeg, LonDeg, AltM: Double;
  EastNorth: TVector2;
  RP: TRoutePoint;
begin
  SetLength(FRoutePoints, 0);
  SetLength(FRouteLatLon, 0);
  SetLength(FRouteAltM,  0);
  ResolveRelativeTimes;
  if FRawCount < 2 then Exit;

  LocOriginLatDeg := 0;
  LocOriginLonDeg := 0;
  LocOriginAlt := 0;
  LocHasOrigin := False;

  SetLength(FRoutePoints, FRawCount);
  SetLength(FRouteLatLon, FRawCount);   { обрежем по GeoCount в конце }
  SetLength(FRouteAltM,  FRawCount);    { параллельно FRouteLatLon }
  GeoCount := 0;
  for I := 0 to FRawCount - 1 do
  begin
    LatDeg := FRawPoints[I].LatSemi * SEMICIRCLE_TO_DEG;
    LonDeg := FRawPoints[I].LonSemi * SEMICIRCLE_TO_DEG;

    { Высота нужна синхронно с гео-точкой ниже, поэтому декодируем её
      ДО записи lat/lon. Абсолютные метры по FIT-шкале; 0 если поля нет. }
    if FRawPoints[I].AltRaw <> INVALID_U32 then
      AltM := (FRawPoints[I].AltRaw / ALT_SCALE) - ALT_OFFSET
    else
      AltM := 0;

    { Гео-маршрут для Osm3d: только записи с валидным GPS-фиксом.
      Точка без фикса дала бы (0,0) — выброс в Атлантику. Высота пишется
      тем же индексом GeoCount, чтобы оставаться параллельной lat/lon. }
    if (FRawPoints[I].LatSemi <> INVALID_S32) and
       (FRawPoints[I].LonSemi <> INVALID_S32) then
    begin
      FRouteLatLon[GeoCount] := TLatLon.Make(LatDeg, LonDeg);
      FRouteAltM[GeoCount]   := AltM;
      Inc(GeoCount);
    end;

    if not LocHasOrigin then
    begin
      LocOriginLatDeg := LatDeg;
      LocOriginLonDeg := LonDeg;
      LocOriginAlt    := AltM;
      LocHasOrigin    := True;

      { Сохраняем для последующих обращений извне (DEM-API и т.п.). }
      FOriginLatDeg      := LatDeg;
      FOriginLonDeg      := LonDeg;
      FHasOrigin         := True;
    end;

    EastNorth := GpsToLocalEastNorth(LatDeg, LonDeg,
      LocOriginLatDeg, LocOriginLonDeg);
    { Тройка (восток=+X, север=+Z, верх=+Y) даёт E×N=−Y — гео-левую
      систему относительно стандартной OpenGL-камеры (forward×up=right).
      Из-за этого при езде на север (+Z) screen-right выходит на запад,
      и трасса в превью/в игре выглядит зеркально к карте. Чтобы сделать
      тройку гео-правой при сохранении +Y вверх и +Z север, инвертируем
      X: восток теперь в −X. Все потребители (X3D-меш, JSON-путь, road
      model, ViewPlay) живут в этом «−X=восток» внутреннем фрейме —
      они оперируют Position.X как абстрактной осью и сами по себе
      корректны. Единственное место, где требуется обратная компенсация —
      это GenerateMapPreview (ему нужно вернуть восток вправо при
      рисовании PNG) и FetchDemGrid (LocalEastNorthToGps ожидает на входе
      настоящий +East — там WX перед вызовом негируется). }
    RP.Position.X := -EastNorth.X;         { восток в -X }
    RP.Position.Y := AltM - LocOriginAlt;  { относительная высота }
    RP.Position.Z := EastNorth.Y;          { север в +Z }
    RP.DistanceFromStart := FRawPoints[I].DistanceM;
    RP.TimeFromStart := FRelativeTimeSec[I];
    FRoutePoints[I] := RP;
  end;

  SetLength(FRouteLatLon, GeoCount);
  SetLength(FRouteAltM,  GeoCount);
  FHasRoute := True;
end;

function TFitFile.RouteStartUTC: TDateTime;
begin
  if FStartTimestampSec = 0 then
    Result := 0
  else
    Result := FitTimestampToUTC(FStartTimestampSec);
end;

function TFitFile.HasAltitude: Boolean;
var
  I: Integer;
begin
  for I := 0 to FRawCount - 1 do
    if FRawPoints[I].AltRaw <> INVALID_U32 then
      Exit(True);
  Result := False;
end;

function TFitFile.ToRideSamples: TRideSampleArray;
var
  I: Integer;
  P: TFitRawPoint;
  PrevLat, PrevLon, DLat, DLon: Double;
  HavePrev: Boolean;
begin
  SetLength(Result, FRawCount);
  if FRawCount = 0 then Exit;
  HavePrev := False;
  PrevLat := 0;
  PrevLon := 0;
  for I := 0 to FRawCount - 1 do
  begin
    P := FRawPoints[I];
    Result[I].TimeSec   := FRelativeTimeSec[I];
    Result[I].DistanceM := P.DistanceM;

    if P.SpeedRaw <> INVALID_U32 then
      Result[I].SpeedMs := P.SpeedRaw / 1000.0
    else
      Result[I].SpeedMs := RIDE_NO_VALUE;

    if P.AltRaw <> INVALID_U32 then
      Result[I].AltM := P.AltRaw / ALT_SCALE - ALT_OFFSET
    else
      Result[I].AltM := RIDE_NO_VALUE;

    if P.PowerRaw <> INVALID_U16 then
      Result[I].PowerW := P.PowerRaw
    else
      Result[I].PowerW := RIDE_NO_VALUE;

    if P.CadenceRaw <> $FF then
      Result[I].CadenceRpm := P.CadenceRaw
    else
      Result[I].CadenceRpm := RIDE_NO_VALUE;

    if P.TempRaw <> 127 then
      Result[I].TempC := P.TempRaw
    else
      Result[I].TempC := RIDE_NO_VALUE;

    Result[I].HeadingRad := RIDE_NO_VALUE;
    if (P.LatSemi <> INVALID_S32) and (P.LonSemi <> INVALID_S32) then
    begin
      if HavePrev then
      begin
        DLat := (P.LatSemi - PrevLat) * SEMICIRCLE_TO_DEG;
        DLon := (P.LonSemi - PrevLon) * SEMICIRCLE_TO_DEG *
          Cos(P.LatSemi * SEMICIRCLE_TO_DEG * Pi / 180.0);
        if (Abs(DLat) > 1e-9) or (Abs(DLon) > 1e-9) then
          Result[I].HeadingRad := ArcTan2(DLon, DLat)
        else if I > 0 then
          Result[I].HeadingRad := Result[I - 1].HeadingRad;
      end;
      PrevLat := P.LatSemi;
      PrevLon := P.LonSemi;
      HavePrev := True;
    end;
  end;
end;

function TFitFile.ToGeoAltPoints: TFitGeoAltArray;
var
  I, N: Integer;
begin
  SetLength(Result, FRawCount);
  N := 0;
  for I := 0 to FRawCount - 1 do
  begin
    { тот же GPS-фильтр, что в LoadFromFile — иначе (0,0)-выброс }
    if (FRawPoints[I].LatSemi = INVALID_S32) or
       (FRawPoints[I].LonSemi = INVALID_S32) then Continue;
    Result[N].Lat := FRawPoints[I].LatSemi * SEMICIRCLE_TO_DEG;
    Result[N].Lon := FRawPoints[I].LonSemi * SEMICIRCLE_TO_DEG;
    if FRawPoints[I].AltRaw <> INVALID_U32 then
      Result[N].AltM := FRawPoints[I].AltRaw / ALT_SCALE - ALT_OFFSET
    else
      Result[N].AltM := 0;
    Result[N].TimeSec := FRelativeTimeSec[I];
    Inc(N);
  end;
  SetLength(Result, N);
end;

{ ── Главная точка входа ───────────────────────────────────────────── }

function TFitFile.LoadFromFile(const Filename: String): Boolean;
var
  FS: TFileStream;
begin
  Result := False;
  ResetData;
  ResetParseState;
  FName := ChangeFileExt(ExtractFileName(Filename), '');

  if not FileExists(Filename) then
  begin
    WritelnLog('FitFile', 'Файл не найден: ' + Filename);
    Exit;
  end;

  try
    FS := TFileStream.Create(Filename, fmOpenRead or fmShareDenyWrite);
    try
      if FS.Size > High(Integer) then Exit;
      SetLength(FBuf, FS.Size);
      if FS.Size > 0 then
        FS.ReadBuffer(FBuf[0], FS.Size);
    finally
      FS.Free;
    end;
  except
    on E: Exception do
    begin
      WritelnLog('FitFile', 'Ошибка чтения ' + Filename + ': ' + E.Message);
      ResetParseState;
      Exit;
    end;
  end;

  if not ReadFitHeader then
  begin
    WritelnLog('FitFile', 'Неверный заголовок FIT: ' + Filename);
    ResetParseState;
    Exit;
  end;

  while FPos < FEndPos do
    ParseRecord;

  if FParseFailed then
  begin
    WritelnLog('FitFile', 'Invalid or truncated FIT record: ' + Filename);
    ResetData;
    ResetParseState;
    Exit;
  end;

  ConvertGpsToRoutePoints;
  if Length(FWorkoutSteps) > 0 then
    FHasWorkout := True;

  WritelnLog('FitFile', Format(
    'Загружен %s: %d точек маршрута, %d шагов тренировки',
    [Filename, Length(FRoutePoints), Length(FWorkoutSteps)]));

  { Освобождаем буфер файла. Сырые точки НЕ чистим: они — источник
    ToRideSamples (каналы для оценщика параметров), живут вместе с
    объектом. Память копеечная (~40 байт/точка). }
  SetLength(FBuf, 0);
  SetLength(FRawPoints, FRawCount);   { ужать до фактического размера }

  Result := True;
end;

{ ══════════════════════════════════════════════════════════════════
  TFitFileWriter

  Минимальный валидный FIT activity. CRC — стандартный FIT (table-driven,
  4-битный, polynomial 0x84CF). FIT-эпоха = 631065600 Unix.
  ══════════════════════════════════════════════════════════════════ }

const
  FIT_EPOCH_UNIX = 631065600;     { 1989-12-31 00:00:00 UTC }

  { Local message types (4 бита, наши собственные индексы; мы используем
    четыре разных, поэтому хватает 0..3). Каждый перед использованием
    эмитим definition, потом data. }
  LMT_FILE_ID  = 0;
  LMT_RECORD   = 1;
  LMT_LAP      = 2;
  LMT_SESSION  = 3;
  LMT_ACTIVITY = 0;     { переиспользуем: file_id уже не нужен в конце }
  LMT_EVENT = 4;
  LMT_DEVELOPER = 5;

  { Заголовки записей: data = local_type только; definition = $40 | local_type. }
  HDR_DEF = $40;

  { Global message numbers — из FIT SDK. }
  GMSG_FILE_ID  = 0;
  GMSG_SESSION  = 18;
  GMSG_LAP      = 19;
  GMSG_RECORD   = 20;
  GMSG_ACTIVITY = 34;
  GMSG_EVENT = 21;

  { FIT base type constants. Старший бит установлен — это endian-aware. }
  FT_ENUM   = $00;
  FT_UINT8  = $02;
  FT_STRING = $07;
  FT_UINT16 = $84;
  FT_UINT32 = $86;
  FT_SINT16 = $83;

  { 16-бит CRC табличка от FIT SDK. }
  FIT_CRC_TABLE: array[0..15] of Word = (
    $0000, $CC01, $D801, $1400, $F001, $3C00, $2800, $E401,
    $A001, $6C00, $7800, $B401, $5000, $9C01, $8801, $4400
  );

function FitCrcUpdate(ACrc: Word; AByte: Byte): Word;
var
  Tmp: Word;
begin
  Tmp := FIT_CRC_TABLE[ACrc and $0F];
  ACrc := (ACrc shr 4) and $0FFF;
  ACrc := ACrc xor Tmp xor FIT_CRC_TABLE[AByte and $0F];

  Tmp := FIT_CRC_TABLE[ACrc and $0F];
  ACrc := (ACrc shr 4) and $0FFF;
  ACrc := ACrc xor Tmp xor FIT_CRC_TABLE[(AByte shr 4) and $0F];

  Result := ACrc;
end;

constructor TFitFileWriter.Create;
begin
  inherited Create;
  FBuf := TMemoryStream.Create;
end;

destructor TFitFileWriter.Destroy;
begin
  FBuf.Free;
  inherited;
end;

procedure TFitFileWriter.WriteByte(B: Byte);
begin
  FBuf.WriteBuffer(B, 1);
end;

procedure TFitFileWriter.WriteWordLE(W: Word);
var
  B: array[0..1] of Byte;
begin
  B[0] := Lo(W);
  B[1] := Hi(W);
  FBuf.WriteBuffer(B[0], 2);
end;

procedure TFitFileWriter.WriteSmallIntLE(V: SmallInt);
begin
  WriteWordLE(Word(V));
end;

procedure TFitFileWriter.WriteLongWordLE(L: LongWord);
var
  B: array[0..3] of Byte;
begin
  B[0] := Byte(L);
  B[1] := Byte(L shr 8);
  B[2] := Byte(L shr 16);
  B[3] := Byte(L shr 24);
  FBuf.WriteBuffer(B[0], 4);
end;

procedure TFitFileWriter.WriteString(const S: AnsiString; ASize: Integer);
var
  Buf: array of Byte;
  I, L: Integer;
begin
  SetLength(Buf, ASize);
  L := Length(S);
  if L > ASize - 1 then L := ASize - 1;     { оставляем место под \0 }
  for I := 0 to L - 1 do
    Buf[I] := Byte(S[I + 1]);
  for I := L to ASize - 1 do
    Buf[I] := 0;
  if ASize > 0 then
    FBuf.WriteBuffer(Buf[0], ASize);
end;

function TFitFileWriter.ToFitTimestamp(AUnixSec: Int64): LongWord;
begin
  if AUnixSec < FIT_EPOCH_UNIX then
    Result := 0
  else
    Result := LongWord(AUnixSec - FIT_EPOCH_UNIX);
end;

{ ── Header ────────────────────────────────────────────────────────
  12-байтовый header без header-CRC. Layout:
    [0]   size = 12
    [1]   protocol_version (1.0 = 0x10)
    [2-3] profile_version LE (2.0.0 = 200, любое валидное значение)
    [4-7] data_size LE — размер всего что между header и file CRC
    [8-11] ".FIT"
  Файл-CRC после data_size байт. }

procedure TFitFileWriter.WriteHeader(ADataSize: LongWord);
begin
  WriteByte(12);                  { size }
  WriteByte($20);                 { protocol 2.0, developer fields }
  WriteWordLE(21214);             { profile 21.214, major * 1000 + minor }
  WriteLongWordLE(ADataSize);     { data_size }
  WriteByte(Ord('.'));
  WriteByte(Ord('F'));
  WriteByte(Ord('I'));
  WriteByte(Ord('T'));
end;

procedure TFitFileWriter.WriteFitCrc(ADataStart: Int64);
var
  Crc: Word;
  B: Byte;
  I: Int64;
  EndPos: Int64;
begin
  Crc := 0;
  EndPos := FBuf.Size;
  FBuf.Position := ADataStart;
  for I := ADataStart to EndPos - 1 do
  begin
    FBuf.ReadBuffer(B, 1);
    Crc := FitCrcUpdate(Crc, B);
  end;
  FBuf.Position := EndPos;
  WriteWordLE(Crc);
end;

{ ── file_id (msg 0) ──────────────────────────────────────────────
  Поля минимум:
    type        (0,  enum,   1) = 4 (activity)
    manufacturer(1,  uint16, 2) = 255 (development)
    product     (2,  uint16, 2) = 0
    serial      (3,  uint32, 4) = 1
    time_created(4,  uint32, 4) = FIT-timestamp старта }

procedure TFitFileWriter.WriteFileIdDefinition;
begin
  WriteByte(HDR_DEF or LMT_FILE_ID);
  WriteByte(0);                    { reserved }
  WriteByte(0);                    { architecture: 0 = LE }
  WriteWordLE(GMSG_FILE_ID);
  WriteByte(5);                    { num fields }
  { type }
  WriteByte(0); WriteByte(1); WriteByte(FT_ENUM);
  { manufacturer }
  WriteByte(1); WriteByte(2); WriteByte(FT_UINT16);
  { product }
  WriteByte(2); WriteByte(2); WriteByte(FT_UINT16);
  { serial_number }
  WriteByte(3); WriteByte(4); WriteByte(FT_UINT32);
  { time_created }
  WriteByte(4); WriteByte(4); WriteByte(FT_UINT32);
end;

procedure TFitFileWriter.WriteFileIdData;
begin
  WriteByte(LMT_FILE_ID);
  WriteByte(4);                    { type = activity }
  WriteWordLE(255);                { manufacturer = development }
  WriteWordLE(0);                  { product }
  WriteLongWordLE(1);              { serial }
  WriteLongWordLE(ToFitTimestamp(FStartUnix));
end;

procedure TFitFileWriter.WriteDeveloperMetadata;
const
  AppId: array[0..15] of Byte = ($9D,$6E,$A2,$91,$27,$32,$4C,$0D,
    $A3,$C6,$84,$52,$45,$5A,$56,$49);
  Names: array[0..2] of String = ('target_power', 'journal_elapsed_ms', 'interval_index');
  Units: array[0..2] of String = ('W', 'ms', '');
var I: Integer;
begin
  { A stable application id and typed fields let independent FIT tools read
    the actual target (including +/-5 W) and subsecond event timing. }
  WriteByte(HDR_DEF or LMT_DEVELOPER); WriteByte(0); WriteByte(0);
  WriteWordLE(207); WriteByte(3); { developer_data_id }
  WriteByte(1); WriteByte(16); WriteByte($0D); { application_id, byte[16] }
  WriteByte(3); WriteByte(1); WriteByte(FT_UINT8);
  WriteByte(4); WriteByte(4); WriteByte(FT_UINT32);
  WriteByte(LMT_DEVELOPER);
  for I := 0 to High(AppId) do WriteByte(AppId[I]);
  WriteByte(0); WriteLongWordLE(1);

  WriteByte(HDR_DEF or LMT_DEVELOPER); WriteByte(0); WriteByte(0);
  WriteWordLE(206); WriteByte(5); { field_description }
  WriteByte(0); WriteByte(1); WriteByte(FT_UINT8);
  WriteByte(1); WriteByte(1); WriteByte(FT_UINT8);
  WriteByte(2); WriteByte(1); WriteByte(FT_UINT8);
  WriteByte(3); WriteByte(24); WriteByte(FT_STRING);
  WriteByte(8); WriteByte(8); WriteByte(FT_STRING);
  for I := 0 to 2 do
  begin
    WriteByte(LMT_DEVELOPER); WriteByte(0); WriteByte(I);
    if I = 1 then WriteByte(FT_UINT32) else WriteByte(FT_UINT16);
    WriteString(Names[I], 24); WriteString(Units[I], 8);
  end;
end;

procedure TFitFileWriter.WriteEventDefinition;
begin
  WriteByte(HDR_DEF or $20 or LMT_EVENT); WriteByte(0); WriteByte(0);
  WriteWordLE(GMSG_EVENT); WriteByte(5);
  WriteByte(253); WriteByte(4); WriteByte(FT_UINT32);
  WriteByte(0); WriteByte(1); WriteByte(FT_ENUM);
  WriteByte(1); WriteByte(1); WriteByte(FT_ENUM);
  WriteByte(3); WriteByte(4); WriteByte(FT_UINT32);
  WriteByte(4); WriteByte(1); WriteByte(FT_UINT8);
  WriteByte(3);
  WriteByte(0); WriteByte(2); WriteByte(0);
  WriteByte(1); WriteByte(4); WriteByte(0);
  WriteByte(2); WriteByte(2); WriteByte(0);
end;

procedure TFitFileWriter.WriteEventData(const ARec: TSensorSessionRecord;
  Event, EventType: Byte);
begin
  WriteByte(LMT_EVENT);
  WriteLongWordLE(ToFitTimestamp(ARec.TimestampUtcUnix));
  WriteByte(Event); WriteByte(EventType);
  if Event = 0 then WriteLongWordLE(0) { timer_trigger = manual }
  else WriteLongWordLE($FFFFFFFF);
  WriteByte(0); { event_group }
  if ARec.HasSessionState then WriteWordLE(ARec.TargetWatts)
  else WriteWordLE($FFFF);
  WriteLongWordLE(Round(Max(0, Min($FFFFFFFE, Double(ARec.ElapsedSec) * 1000))));
  if ARec.HasSessionState then WriteWordLE(Max(0, Min($FFFE, ARec.Lap)))
  else WriteWordLE($FFFF);
end;

{ ── record (msg 20) ──────────────────────────────────────────────
  Поля (все опциональные кроме timestamp):
    timestamp  (253, uint32, 4)
    distance   (5,   uint32, 4)  — мм... нет, m × 100
    speed      (6,   uint16, 2)  — m/s × 1000
    power      (7,   uint16, 2)
    grade      (9,   sint16, 2)  — % × 100
    heart_rate (3,   uint8,  1)
    cadence    (4,   uint8,  1)
  Всего 16 байт + 1 байт header = 17 байт на запись. }

procedure TFitFileWriter.WriteRecordDefinition;
begin
  WriteByte(HDR_DEF or $20 or LMT_RECORD);
  WriteByte(0);
  WriteByte(0);
  WriteWordLE(GMSG_RECORD);
  WriteByte(7);                    { 7 fields }
  WriteByte(253); WriteByte(4); WriteByte(FT_UINT32); { timestamp }
  WriteByte(5);   WriteByte(4); WriteByte(FT_UINT32); { distance }
  WriteByte(6);   WriteByte(2); WriteByte(FT_UINT16); { speed }
  WriteByte(7);   WriteByte(2); WriteByte(FT_UINT16); { power }
  WriteByte(9);   WriteByte(2); WriteByte(FT_SINT16); { grade }
  WriteByte(3);   WriteByte(1); WriteByte(FT_UINT8);  { heart_rate }
  WriteByte(4);   WriteByte(1); WriteByte(FT_UINT8);  { cadence }
  WriteByte(1);                   { developer fields }
  WriteByte(0); WriteByte(2); WriteByte(0); { target_power, uint16, developer 0 }
end;

procedure TFitFileWriter.WriteRecordData(const ARec: TSensorSessionRecord; DistanceM: Double);
var
  SpeedMs: Single;
  SpeedRaw: LongWord;
  DistanceRaw: LongWord;
  GradeRaw: SmallInt;
begin
  WriteByte(LMT_RECORD);
  WriteLongWordLE(ToFitTimestamp(ARec.TimestampUtcUnix));

  DistanceRaw := Round(Min($FFFFFFFE, Max(0, DistanceM * 100)));
  WriteLongWordLE(DistanceRaw);

  SpeedMs := ARec.SpeedKmh / 3.6;
  if SpeedMs > FMaxSpeedMs then FMaxSpeedMs := SpeedMs;
  SpeedRaw := Round(Max(0, SpeedMs * 1000));
  if SpeedRaw > $FFFE then SpeedRaw := $FFFE;
  WriteWordLE(Word(SpeedRaw));

  WriteWordLE(ARec.Power);

  GradeRaw := SmallInt(Round(Max(-32768, Min(32766, ARec.SlopePct * 100))));
  WriteSmallIntLE(GradeRaw);

  WriteByte(ARec.HeartRate);
  if ARec.Cadence > 254 then
    WriteByte(254)
  else
    WriteByte(Byte(ARec.Cadence));

  if ARec.HasSessionState then WriteWordLE(ARec.TargetWatts)
  else WriteWordLE($FFFF);
  Inc(FRecordCount);
end;

{ ── lap (msg 19) ─────────────────────────────────────────────────
  Поля:
    timestamp           (253, uint32, 4)
    start_time          (2,   uint32, 4)
    total_elapsed_time  (7,   uint32, 4)  — сек × 1000
    total_timer_time    (8,   uint32, 4)  — сек × 1000
    total_distance      (9,   uint32, 4)  — m × 100
    event               (0,   enum,   1) = 9 (lap)
    event_type          (1,   enum,   1) = 1 (stop) }

procedure TFitFileWriter.WriteLapDefinition;
begin
  WriteByte(HDR_DEF or LMT_LAP);
  WriteByte(0);
  WriteByte(0);
  WriteWordLE(GMSG_LAP);
  WriteByte(11);
  WriteByte(253); WriteByte(4); WriteByte(FT_UINT32);
  WriteByte(2);   WriteByte(4); WriteByte(FT_UINT32);
  WriteByte(7);   WriteByte(4); WriteByte(FT_UINT32);
  WriteByte(8);   WriteByte(4); WriteByte(FT_UINT32);
  WriteByte(9);   WriteByte(4); WriteByte(FT_UINT32);
  WriteByte(0);   WriteByte(1); WriteByte(FT_ENUM);
  WriteByte(1);   WriteByte(1); WriteByte(FT_ENUM);
  WriteByte(254); WriteByte(2); WriteByte(FT_UINT16); { message_index }
  WriteByte(41); WriteByte(4); WriteByte(FT_UINT32); { total_work, J }
  WriteByte(19); WriteByte(2); WriteByte(FT_UINT16); { avg_power }
  WriteByte(24); WriteByte(1); WriteByte(FT_ENUM); { lap_trigger }
end;

procedure TFitFileWriter.WriteLapData(StartUnix, EndUnix: Int64;
  ElapsedSec, TimerSec, DistanceM, WorkJ: Double; FinalLap: Boolean);
begin
  WriteByte(LMT_LAP);
  WriteLongWordLE(ToFitTimestamp(EndUnix));
  WriteLongWordLE(ToFitTimestamp(StartUnix));
  WriteLongWordLE(Round(Max(0, Min($FFFFFFFE, ElapsedSec * 1000))));
  WriteLongWordLE(Round(Max(0, Min($FFFFFFFE, TimerSec * 1000))));
  WriteLongWordLE(Round(Max(0, Min($FFFFFFFE, DistanceM * 100))));
  WriteByte(9);                    { event = lap }
  WriteByte(1);                    { event_type = stop }
  WriteWordLE(FLapCount);
  WriteLongWordLE(Round(Max(0, Min($FFFFFFFE, WorkJ))));
  if TimerSec > 0 then WriteWordLE(Round(Min($FFFE, Max(0, WorkJ / TimerSec))))
  else WriteWordLE(0);
  if FinalLap then WriteByte(7) else WriteByte(0);
  Inc(FLapCount);
end;

{ ── session (msg 18) ─────────────────────────────────────────────
  Поля:
    timestamp           (253, uint32, 4)
    start_time          (2,   uint32, 4)
    total_elapsed_time  (7,   uint32, 4)
    total_timer_time    (8,   uint32, 4)
    total_distance      (9,   uint32, 4)
    sport               (5,   enum,   1) = 2 (cycling)
    sub_sport           (6,   enum,   1) = 6 (indoor cycling)
    event               (0,   enum,   1) = 8 (session)
    event_type          (1,   enum,   1) = 1 (stop) }

procedure TFitFileWriter.WriteSessionDefinition;
begin
  WriteByte(HDR_DEF or LMT_SESSION);
  WriteByte(0);
  WriteByte(0);
  WriteWordLE(GMSG_SESSION);
  WriteByte(13);
  WriteByte(253); WriteByte(4); WriteByte(FT_UINT32);
  WriteByte(2);   WriteByte(4); WriteByte(FT_UINT32);
  WriteByte(7);   WriteByte(4); WriteByte(FT_UINT32);
  WriteByte(8);   WriteByte(4); WriteByte(FT_UINT32);
  WriteByte(9);   WriteByte(4); WriteByte(FT_UINT32);
  WriteByte(5);   WriteByte(1); WriteByte(FT_ENUM);
  WriteByte(6);   WriteByte(1); WriteByte(FT_ENUM);
  WriteByte(0);   WriteByte(1); WriteByte(FT_ENUM);
  WriteByte(1);   WriteByte(1); WriteByte(FT_ENUM);
  WriteByte(25); WriteByte(2); WriteByte(FT_UINT16); { first_lap_index }
  WriteByte(26); WriteByte(2); WriteByte(FT_UINT16); { num_laps }
  WriteByte(48); WriteByte(4); WriteByte(FT_UINT32); { total_work }
  WriteByte(20); WriteByte(2); WriteByte(FT_UINT16); { avg_power }
end;

procedure TFitFileWriter.WriteSessionData;
begin
  WriteByte(LMT_SESSION);
  WriteLongWordLE(ToFitTimestamp(FEndUnix));
  WriteLongWordLE(ToFitTimestamp(FStartUnix));
  WriteLongWordLE(Round(Min($FFFFFFFE, FElapsedSec * 1000)));
  WriteLongWordLE(Round(Min($FFFFFFFE, FTimerSec * 1000)));
  WriteLongWordLE(Round(Min($FFFFFFFE, FTotalDistance * 100)));
  WriteByte(2);                    { sport = cycling }
  WriteByte(6);                    { sub_sport = indoor cycling }
  WriteByte(8);                    { event = session }
  WriteByte(1);                    { event_type = stop }
  WriteWordLE(0);
  WriteWordLE(FLapCount);
  WriteLongWordLE(Round(Min($FFFFFFFE, FWorkJ)));
  if FTimerSec > 0 then WriteWordLE(Round(Min($FFFE, FWorkJ / FTimerSec)))
  else WriteWordLE(0);
end;

{ ── activity (msg 34) ────────────────────────────────────────────
  Без неё сервер шлёт rejected.
  Поля:
    timestamp        (253, uint32, 4)
    total_timer_time (0,   uint32, 4)
    num_sessions     (1,   uint16, 2) = 1
    type             (2,   enum,   1) = 0 (manual)
    event            (3,   enum,   1) = 26 (activity)
    event_type       (4,   enum,   1) = 1 (stop) }

procedure TFitFileWriter.WriteActivityDefinition;
begin
  WriteByte(HDR_DEF or LMT_ACTIVITY);
  WriteByte(0);
  WriteByte(0);
  WriteWordLE(GMSG_ACTIVITY);
  WriteByte(6);
  WriteByte(253); WriteByte(4); WriteByte(FT_UINT32);
  WriteByte(0);   WriteByte(4); WriteByte(FT_UINT32);
  WriteByte(1);   WriteByte(2); WriteByte(FT_UINT16);
  WriteByte(2);   WriteByte(1); WriteByte(FT_ENUM);
  WriteByte(3);   WriteByte(1); WriteByte(FT_ENUM);
  WriteByte(4);   WriteByte(1); WriteByte(FT_ENUM);
end;

procedure TFitFileWriter.WriteActivityData;
begin
  WriteByte(LMT_ACTIVITY);
  WriteLongWordLE(ToFitTimestamp(FEndUnix));
  WriteLongWordLE(Round(Min($FFFFFFFE, FTimerSec * 1000)));
  WriteWordLE(1);                  { num_sessions }
  WriteByte(0);                    { type = manual }
  WriteByte(26);                   { event = activity }
  WriteByte(1);                    { event_type = stop }
end;

function TFitFileWriter.SaveToFile(const ARecords: TSensorSessionRecordArray;
  const AFileName: String): Boolean;
var
  I, J, RecordAt, GroupEnd: Integer;
  DataSize: LongWord;
  FS: TFileStream;
  Cur, Prev: TSensorSessionRecord;
  TimerRunning, HaveTimerState, LapChanged, TargetChanged, UseElapsed: Boolean;
  Delta, ClockNow, LapStartClock, LapTimerStart, LapDistanceStart, LapWorkStart: Double;
  LapStartUnix: Int64;
  TempName: String;
  TempCreated: Boolean;

  function IsActive(const R: TSensorSessionRecord): Boolean;
  begin Result := not R.HasSessionState or R.TimerActive; end;

  function ClockAt(Index: Integer): Double;
  begin
    if UseElapsed then Result := Double(ARecords[Index].ElapsedSec) - ARecords[0].ElapsedSec
    else Result := ARecords[Index].TimestampUtcUnix - FStartUnix;
  end;
begin
  Result := False;
  FErrorText := '';
  TempCreated := False;
  TempName := AFileName + '.rezvivo.tmp';
  try
    if Length(ARecords) = 0 then raise Exception.Create('No sensor records to export');
    FBuf.Clear;
    FRecordCount := 0;
    FTotalDistance := 0;
    FMaxSpeedMs := 0;
    FTimerSec := 0;
    FWorkJ := 0;
    FLapCount := 0;
    FStartUnix := ARecords[0].TimestampUtcUnix;
    FEndUnix := ARecords[High(ARecords)].TimestampUtcUnix;
    UseElapsed := ARecords[High(ARecords)].ElapsedSec > ARecords[0].ElapsedSec;
    for I := 0 to High(ARecords) do
    begin
      Cur := ARecords[I];
      if IsNan(Cur.ElapsedSec) or IsInfinite(Cur.ElapsedSec) or
        IsNan(Cur.SpeedKmh) or IsInfinite(Cur.SpeedKmh) or
        IsNan(Cur.SlopePct) or IsInfinite(Cur.SlopePct) or
        (Cur.ElapsedSec < 0) or (Cur.TimestampUtcUnix < FIT_EPOCH_UNIX) or
        (Cur.TimestampUtcUnix - FIT_EPOCH_UNIX >= $FFFFFFFF) then
        raise Exception.CreateFmt('Invalid sensor record %d', [I + 1]);
      if I > 0 then
        if (Cur.TimestampUtcUnix < ARecords[I-1].TimestampUtcUnix) or
          (Cur.ElapsedSec < ARecords[I-1].ElapsedSec) then
          raise Exception.CreateFmt('Sensor time goes backwards at record %d', [I + 1]);
      if Cur.HasSessionState then UseElapsed := True;
    end;
    FElapsedSec := ClockAt(High(ARecords));
    if FElapsedSec * 1000 >= $FFFFFFFF then
      raise Exception.Create('Activity is too long for FIT');

    WriteHeader(0);
    WriteFileIdDefinition;
    WriteFileIdData;
    WriteDeveloperMetadata;
    WriteRecordDefinition;
    WriteEventDefinition;
    WriteLapDefinition;
    LapStartClock := 0; LapTimerStart := 0; LapDistanceStart := 0; LapWorkStart := 0;
    LapStartUnix := FStartUnix;
    HaveTimerState := False;
    TimerRunning := False;
    GroupEnd := -1;
    RecordAt := -1;
    Prev := Default(TSensorSessionRecord);
    for I := 0 to High(ARecords) do
    begin
      Cur := ARecords[I];
      ClockNow := ClockAt(I);
      if I > 0 then
      begin
        Delta := ClockNow - ClockAt(I-1);
        if IsActive(Prev) then
        begin
          FTimerSec := FTimerSec + Delta;
          if Prev.Power <> $FFFF then FWorkJ := FWorkJ + Double(Prev.Power) * Delta;
          FTotalDistance := FTotalDistance + Max(0, Double(Cur.DistanceM) - Prev.DistanceM);
        end;
      end;
      LapChanged := Cur.HasSessionState and (I > 0) and
        ((not Prev.HasSessionState) or (Cur.Lap <> Prev.Lap));
      TargetChanged := Cur.HasSessionState and ((I = 0) or
        not Prev.HasSessionState or (Cur.TargetWatts <> Prev.TargetWatts));
      if LapChanged then
      begin
        if FLapCount >= $FFFE then raise Exception.Create('Too many workout intervals');
        WriteLapData(LapStartUnix, Cur.TimestampUtcUnix, ClockNow - LapStartClock,
          FTimerSec - LapTimerStart, FTotalDistance - LapDistanceStart,
          FWorkJ - LapWorkStart, False);
        LapStartUnix := Cur.TimestampUtcUnix;
        LapStartClock := ClockNow;
        LapTimerStart := FTimerSec;
        LapDistanceStart := FTotalDistance;
        LapWorkStart := FWorkJ;
      end;
      { A stop row closes the preceding active span. Emit its final distance
        and telemetry before the timer-stop event, never during the pause. }
      if I > GroupEnd then
      begin
        GroupEnd := I;
        while (GroupEnd < High(ARecords)) and
          (ARecords[GroupEnd + 1].TimestampUtcUnix = Cur.TimestampUtcUnix) do Inc(GroupEnd);
        RecordAt := -1;
        for J := I to GroupEnd do
          if IsActive(ARecords[J]) or ((J > 0) and IsActive(ARecords[J-1])) then RecordAt := J;
      end;
      if (I = RecordAt) and not IsActive(Cur) then WriteRecordData(Cur, FTotalDistance);
      if not HaveTimerState or (IsActive(Cur) <> TimerRunning) then
      begin
        TimerRunning := IsActive(Cur);
        HaveTimerState := True;
        if TimerRunning then WriteEventData(Cur, 0, 0)
        else WriteEventData(Cur, 0, 4);
      end;
      if LapChanged or ((I = 0) and Cur.HasSessionState and (Cur.Lap > 0)) then
        WriteEventData(Cur, 4, 3) { workout_step marker }
      else if TargetChanged then WriteEventData(Cur, 32, 3); { user marker: target change }

      { Keep every event, including several events in the same second. Only
        telemetry is thinned, to one active record per UTC second for the
        server's (ride_id, t_ms) key. Never emit records while paused. }
      if (I = RecordAt) and IsActive(Cur) then WriteRecordData(Cur, FTotalDistance);
      Prev := Cur;
    end;
    if FRecordCount = 0 then raise Exception.Create('No active sensor records to export');
    if TimerRunning then WriteEventData(Cur, 0, 4);
    if (FElapsedSec > LapStartClock) or (FLapCount = 0) then
      WriteLapData(LapStartUnix, FEndUnix, FElapsedSec - LapStartClock,
        FTimerSec - LapTimerStart, FTotalDistance - LapDistanceStart,
        FWorkJ - LapWorkStart, True);
    WriteSessionDefinition;
    WriteSessionData;
    WriteActivityDefinition;
    WriteActivityData;
    DataSize := LongWord(FBuf.Size - 12);
    FBuf.Position := 4;
    WriteLongWordLE(DataSize);
    FBuf.Position := FBuf.Size;
    WriteFitCrc(0);

    FS := TFileStream.Create(TempName, fmCreate);
    TempCreated := True;
    try
      FBuf.Position := 0;
      FS.CopyFrom(FBuf, FBuf.Size);
    finally FS.Free; end;
    {$ifdef MSWINDOWS}
    if not MoveFileExW(PWideChar(UTF8Decode(TempName)), PWideChar(UTF8Decode(AFileName)),
      MOVEFILE_REPLACE_EXISTING or $8) then RaiseLastOSError;
    {$else}
    if not RenameFile(TempName, AFileName) then RaiseLastOSError;
    {$endif}
    TempCreated := False;
    Result := True;
    WritelnLog('FitWriter', Format(
      'Wrote %s: %d records, %d laps, %.1fs elapsed / %.1fs timer, %.0f J',
      [AFileName, FRecordCount, FLapCount, FElapsedSec, FTimerSec, FWorkJ]));
  except
    on E: Exception do
    begin
      FErrorText := E.Message;
      WritelnLog('FitWriter', 'SaveToFile error: ' + E.Message);
    end;
  end;
  if TempCreated then SysUtils.DeleteFile(TempName);
end;

end.
