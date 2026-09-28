{ WorkoutFile — парсер и сериализатор тренировок в формате .zwo
  (Zwift Workout XML).

  Формат описывает структурированную интервальную тренировку как
  последовательность сегментов с заданной мощностью (в долях от FTP).
  Шесть основных типов сегментов:

    Warmup    — линейный рост мощности от PowerLow к PowerHigh
    Cooldown  — линейный спад от PowerHigh к PowerLow
    Ramp      — то же что Warmup, но без подразумеваемого «начала тренировки»
    SteadyState — постоянная мощность Power на Duration секунд
    IntervalsT — Repeat × (OnDuration на OnPower + OffDuration на OffPower)
    FreeRide   — свободная езда, мощность не задана

  Все длительности в секундах, мощности — доли FTP (1.0 = 100% FTP).

  Парсер раскрывает IntervalsT в плоский список простых сегментов
  (чтобы превью-виджет рисовал каждый круг интервала отдельной
  «зубчатой» парой столбцов). Сериализатор v1 пишет каждый
  сегмент как SteadyState (без re-rolling в IntervalsT) — это
  расширяет файл, но всегда корректно. Re-rolling — задача для v2.

  Устойчивость к битым файлам:
    Многие .zwo в дикой природе содержат голый '&' или '<' в тексте
    description/name (вместо &amp; и &lt;). Прямой парсер падает с
    EXMLReaderError при попытке разобрать такие атрибуты. Поэтому
    LoadFromUrl сначала скачивает файл в строку, пытается распарсить;
    при неудаче применяет лёгкий санитайзинг (экранирует одиночные '&')
    и пробует ещё раз. Только если оба прохода провалились — файл
    помечается битым и пропускается.

  Редактирование:
    Метаданные (Name, Description, Author, SportType) — write-properties
    с трекингом Modified.
    Список сегментов — мутаторы AddSegment / InsertSegmentAfter /
    DeleteSegment / SwapSegments / DuplicateSegment, каждый ставит
    Modified := True.
    Сохранение — SaveToUrl: разрешает только file:/// URL (на Web/Android
    запись напрямую в произвольный URL не поддерживается). Возвращает
    False с warning в лог если URL нелокальный или запись сорвалась. }
unit WorkoutFile;

{$mode objfpc}{$H+}
{$codepage UTF8}

interface

uses
  Classes, SysUtils, fgl;

type
  TWorkoutSegmentKind = (
    wskWarmup,
    wskCooldown,
    wskRamp,
    wskSteady,
    wskInterval,
    wskFreeRide
  );

  { TextEvent — всплывающее сообщение которое показывается во время
    проигрывания workout-а в момент TimeOffset секунд от начала
    родительского сегмента. Распознаются три варианта тэга:
      <textevent>       — нижний регистр, самый частый
      <TextEvent>       — встречается в Zwift-сгенерированных файлах
      <TextNotification> — с координатами x/y, font_size; редкий
    Все три нормализуем в один объект, исходный TagName сохраняем
    для записи в том же стиле что был при чтении (пользователь не
    хочет видеть, что его файл «переписался» если он не редактировал
    эти события).

    RawAttrs — pass-through хранилище для атрибутов которые мы не
    знаем (y, distoffset, textscale, x, font_size). На записи они
    возвращаются обратно в XML без изменений. }
  TWorkoutTextEvent = class
    TimeOffset:  Single;
    Duration:    Single;     { 0 = не задано, использовать дефолт игры }
    Message:     String;
    OrigTagName: String;     { 'textevent' / 'TextEvent' / 'TextNotification' }
    RawAttrs:    TStringList;
    constructor Create;
    destructor Destroy; override;
  end;

  TWorkoutTextEventList = specialize TFPGObjectList<TWorkoutTextEvent>;

  TWorkoutSegment = class
    Kind:        TWorkoutSegmentKind;
    Duration:    Single;       { сек }
    PowerLow:    Single;       { 1.0 = 100% FTP; для steady = power }
    PowerHigh:   Single;       { для warmup/cooldown/ramp }
    RepeatGroup: Integer;      { 0 = вне группы; >0 = id группы IntervalsT }
    IsOnPart:    Boolean;      { true = «работа» внутри IntervalsT }

    { Каденция (RPM). 0 = не задано, использовать любую/свободно.
      CadenceLow/High используются для Warmup/Cooldown/Ramp как
      аналог PowerLow/High; для Steady и Interval On — Cadence,
      для Interval Off — CadenceResting. Для упрощённой модели
      «постоянного значения» CadenceLow=CadenceHigh=Cadence. }
    Cadence:        Integer;
    CadenceResting: Integer;
    CadenceLow:     Integer;
    CadenceHigh:    Integer;

    { Pass-through: всё что не разобрали в типизированные поля.
      На записи возвращается в XML без изменений. RawAttrs — для
      неизвестных атрибутов (Zone, OverUnder, FlatRoad, pace, ...).
      RawChildren — для неизвестных дочерних элементов (outer XML
      каждого узла как строка); TextEvents/TextNotification сюда
      НЕ кладём — они в TextEvents. }
    RawAttrs:    TStringList;
    RawChildren: TStringList;
    TextEvents:  TWorkoutTextEventList;

    constructor Create;
    destructor Destroy; override;
  end;

  TWorkoutSegmentList = specialize TFPGObjectList<TWorkoutSegment>;

  TWorkoutFile = class
  private
    FName:        String;
    FDescription: String;
    FAuthor:      String;
    FSportType:   String;
    FUrl:         String;
    FCategory:    String;
    FSegments:    TWorkoutSegmentList;
    FModified:    Boolean;

    { Pass-through заголовка: дочерние элементы <workout_file> которые
      мы не разобрали в типизированные поля. Сюда попадают
      <category>, <subcategory>, <tags>, <entid>, <painIndex>,
      <test_details>, <WorkoutPlan>, и любые будущие. Каждая строка —
      сериализованный outer XML одного элемента. }
    FRawHeaderChildren: TStringList;

    procedure SetName(const V: String);
    procedure SetDescription(const V: String);
    procedure SetAuthor(const V: String);
    procedure SetSportType(const V: String);

    function GetTotalDuration: Single;
    function GetIntensityFactor: Single;
    function GetTSS: Single;
  public
    { Local calendar origin; carried through clones and ride recovery. }
    ScheduleUserId:Int64;
    ScheduleKey:String;
    constructor Create;
    destructor Destroy; override;

    { Независимая рабочая копия, включая события и неизвестные XML-поля.
      Возвращённым объектом владеет вызывающий код. }
    function Clone: TWorkoutFile;

    { Загрузка из URL (в т. ч. castle-data:/...). True если получилось. }
    function LoadFromUrl(const AUrl: String): Boolean;

    { Сохранение в URL — на v1 только file:///. True если получилось.
      После успешного сохранения сбрасывает Modified в False и обновляет
      FUrl на новое значение. }
    function SaveToUrl(const AUrl: String): Boolean;

    { ── Мутаторы списка сегментов ────────────────────────────────── }
    function  AddSegment(AKind: TWorkoutSegmentKind): TWorkoutSegment;
    function  InsertSegmentAfter(Index: Integer;
      AKind: TWorkoutSegmentKind): TWorkoutSegment;
    procedure DeleteSegment(Index: Integer);
    procedure SwapSegments(IndexA, IndexB: Integer);
    function  DuplicateSegment(Index: Integer): TWorkoutSegment;

    { ── Групповые операции для сегментов IntervalsT ──────────────────
      Хранение остаётся плоским — IntervalsT раскрывается в N пар
      (On, Off) при загрузке. Эти helpers позволяют редактору
      обращаться с такой раскрытой группой как с одной сущностью:
      редактирование любого элемента действует на все того же
      «фаза» (On или Off), удаление — убирает один повтор, и т. д.

      «Группа» = непрерывный диапазон сегментов с одинаковым
      RepeatGroup > 0. Если сегмент в неё не входит — функции,
      помеченные «OrSingle», работают как обычные одиночные операции;
      остальные — возвращают False/нулевой результат. }

    { True если сегмент по индексу — часть группы. В этом случае
      FirstIdx/LastIdx устанавливаются в границы непрерывного блока
      с тем же RepeatGroup. }
    function  GroupRange(SegIndex: Integer;
      out FirstIdx, LastIdx: Integer): Boolean;

    { Число повторов в группе (один повтор = пара On+Off).
      0 если сегмент не в группе. }
    function  GroupRepCount(SegIndex: Integer): Integer;

    { Записывает Duration во все члены группы той же «фазы»
      (On или Off, определяется по IsOnPart кликнутого сегмента).
      Если сегмент не в группе — меняет только его. }
    procedure SetGroupDuration(SegIndex: Integer; D: Single);

    { Аналогично для PowerLow (для interval-сегментов PowerLow=PowerHigh,
      второе синхронизируется автоматически). }
    procedure SetGroupPower(SegIndex: Integer; P: Single);

    { Каденция (RPM). Для члена IntervalsT-группы пишет всем
      сегментам той же фазы (On — в Cadence; Off — в CadenceResting).
      Для одиночного сегмента: если он Steady или часть Warmup/Cooldown/Ramp
      и HighSide=False — пишет в Cadence/CadenceLow; иначе CadenceHigh.
      Значение 0 = убрать заданность (атрибут не запишется). }
    procedure SetGroupCadence(SegIndex: Integer; CadenceRPM: Integer;
      HighSide: Boolean);

    { Удаляет один повтор (пара On+Off) к которой относится сегмент.
      Если сегмент не в группе — удаляет его одного.
      Возвращает индекс который имеет смысл выделить после операции
      (или -1 если ничего не осталось). }
    function  DeleteGroupRepOrSingle(SegIndex: Integer): Integer;

    { Добавляет ещё один повтор в группу: новая пара (On, Off) в её
      конец со значениями скопированными с первого повтора.
      Если сегмент не в группе — обычный duplicate.
      Возвращает индекс первого нового сегмента. }
    function  DuplicateGroupRepOrSingle(SegIndex: Integer): Integer;

    { Перемещает блок (всю группу или одиночный сегмент) через
      соседний блок справа (Direction>0) или слева (Direction<0).
      Соседний блок тоже может быть группой — тогда мы перепрыгиваем
      его целиком. Возвращает новый индекс кликнутого сегмента
      после перемещения (или прежний, если перемещение невозможно). }
    function  MoveBlock(SegIndex: Integer; Direction: Integer): Integer;

    { Устанавливает количество повторов в IntervalsT-группе.
      Уменьшение — удаление лишних пар с конца группы. Увеличение —
      добавление пар с теми же значениями что у первого повтора.
      Минимум 1 повтор (полное удаление группы делается через
      Delete на каждом сегменте). NewCount<=0 игнорируется.
      Если SegIndex не в группе — ничего не делает.
      Возвращает индекс «канонического» On-сегмента после операции
      (FirstIdx группы), либо -1. }
    function  SetGroupRepeatCount(SegIndex: Integer;
      NewCount: Integer): Integer;

    property Name:        String read FName        write SetName;
    property Description: String read FDescription write SetDescription;
    property Author:      String read FAuthor      write SetAuthor;
    property SportType:   String read FSportType   write SetSportType;
    property Url:         String read FUrl;
    property Category:    String read FCategory    write FCategory;
    property Segments:    TWorkoutSegmentList read FSegments;

    property Modified: Boolean read FModified write FModified;

    { Pass-through хранилище неизвестных дочерних элементов
      <workout_file> (category, tags, entid, и т.п.). Редактор
      обычно его не трогает, но при сохранении содержимое
      возвращается в файл. Доступно как read-write на случай если
      каким-то импортёрам захочется добавить элементов программно. }
    property RawHeaderChildren: TStringList read FRawHeaderChildren;

    { Для сегмента в IntervalsT-группе — индекс «канонического»
      сегмента, на котором у нас хранятся TextEvents и pass-through
      (это первый сегмент группы — первый On). Для одиночного
      сегмента возвращает SegIndex.
      -1 если индекс невалиден. }
    function CanonicalSegmentIndex(SegIndex: Integer): Integer;

    property TotalDuration:   Single read GetTotalDuration;
    property IntensityFactor: Single read GetIntensityFactor;
    property TSS:             Single read GetTSS;
  end;

  TWorkoutFileList = specialize TFPGObjectList<TWorkoutFile>;

{ Утилиты форматирования. }
function FormatWorkoutDuration(Seconds: Single): String;     { '01:30:00' / '48:20' }
function FormatWorkoutPowerPct(Power: Single): String;       { '75%' }
function WorkoutSegmentKindName(Kind: TWorkoutSegmentKind): String;

implementation

uses
  Math, StrUtils,
  CastleXmlUtils, CastleLog, CastleDownload, CastleUriUtils,
  DOM, XMLRead, XMLWrite;

{ ── Утилиты ────────────────────────────────────────────────────────── }

function FormatWorkoutDuration(Seconds: Single): String;
var
  Total, H, M, S: Integer;
begin
  Total := Round(Seconds);
  H := Total div 3600;
  M := (Total mod 3600) div 60;
  S := Total mod 60;
  if H > 0 then
    Result := Format('%.2d:%.2d:%.2d', [H, M, S])
  else
    Result := Format('%.2d:%.2d', [M, S]);
end;

function FormatWorkoutPowerPct(Power: Single): String;
begin
  Result := Format('%d%%', [Round(Power * 100)]);
end;

function WorkoutSegmentKindName(Kind: TWorkoutSegmentKind): String;
begin
  case Kind of
    wskWarmup:   Result := 'Warmup';
    wskCooldown: Result := 'Cooldown';
    wskRamp:     Result := 'Ramp';
    wskSteady:   Result := 'Steady';
    wskInterval: Result := 'Interval';
    wskFreeRide: Result := 'Free Ride';
  else
    Result := '';
  end;
end;

{ Безопасное чтение float-атрибута: zwo всегда использует точку как
  десятичный разделитель, независимо от системной локали. }
function AttrFloat(Node: TDOMElement; const AttrName: String;
  const Default: Single): Single;
var
  S: String;
  FS: TFormatSettings;
  V: Double;
begin
  S := Trim(Node.AttributeStringDef(AttrName, ''));
  if S = '' then Exit(Default);

  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  FS.ThousandSeparator := ',';
  if not TryStrToFloat(S, V, FS) then Exit(Default);
  Result := V;
end;

function AttrInt(Node: TDOMElement; const AttrName: String;
  const Default: Integer): Integer;
var
  S: String;
  V: Integer;
begin
  S := Trim(Node.AttributeStringDef(AttrName, ''));
  if (S = '') or (not TryStrToInt(S, V)) then Exit(Default);
  Result := V;
end;

{ ── Known-attribute sets для pass-through ─────────────────────────────
  При чтении сегмента известные атрибуты (Duration, Power, ...)
  забираются в типизированные поля; остальное складывается в
  RawAttrs. Чтобы знать «что известно» — держим списки имён,
  сравнение case-insensitive (XML атрибуты бывают в любом регистре). }

function IsKnownSegmentAttr(const Kind: TWorkoutSegmentKind;
  const AttrName: String): Boolean;
var
  Lower: String;
begin
  Lower := LowerCase(AttrName);
  case Kind of
    wskWarmup, wskCooldown, wskRamp:
      Result := (Lower = 'duration') or
                (Lower = 'powerlow') or (Lower = 'powerhigh') or
                (Lower = 'cadence') or (Lower = 'cadenceresting') or
                (Lower = 'cadencelow') or (Lower = 'cadencehigh');
    wskSteady:
      Result := (Lower = 'duration') or (Lower = 'power') or
                (Lower = 'cadence') or (Lower = 'cadenceresting') or
                (Lower = 'cadencelow') or (Lower = 'cadencehigh');
    wskInterval:
      { IntervalsT-родитель имеет on/off-атрибуты, при разворачивании в
        отдельные сегменты мы их размазываем по PowerLow/Duration —
        со списком cadence-атрибутов это тоже работает.
        repeat — атрибут IntervalsT, не самого «зубца», но раз он у
        родителя — пусть будет в known. }
      Result := (Lower = 'repeat') or
                (Lower = 'onduration') or (Lower = 'offduration') or
                (Lower = 'onpower') or (Lower = 'offpower') or
                (Lower = 'cadence') or (Lower = 'cadenceresting') or
                (Lower = 'cadencelow') or (Lower = 'cadencehigh');
    wskFreeRide:
      Result := Lower = 'duration';
  else
    Result := False;
  end;
end;

function IsKnownHeaderChild(const TagName: String): Boolean;
var
  Lower: String;
begin
  Lower := LowerCase(TagName);
  Result := (Lower = 'name') or (Lower = 'description') or
            (Lower = 'author') or (Lower = 'sporttype') or
            (Lower = 'workout');
end;

function IsTextEventTag(const TagName: String): Boolean;
var
  Lower: String;
begin
  Lower := LowerCase(TagName);
  Result := (Lower = 'textevent') or (Lower = 'textnotification');
end;

{ Сериализация одного DOM-узла обратно в строку — нужно для
  pass-through. Используем WriteXML в TStringStream: оборачивает
  узел в полноценный XML-фрагмент с XML declaration; declaration
  потом вырезаем. }
function NodeToOuterXml(Node: TDOMElement): String;
var
  TempDoc: TXMLDocument;
  Cloned: TDOMNode;
  SS: TStringStream;
  XmlText: String;
  P: Integer;
begin
  Result := '';
  if Node = nil then Exit;
  TempDoc := TXMLDocument.Create;
  try
    Cloned := Node.CloneNode(True, TempDoc);
    TempDoc.AppendChild(Cloned);
    SS := TStringStream.Create('');
    try
      WriteXMLFile(TempDoc, SS);
      XmlText := SS.DataString;
      { Удаляем XML declaration "<?xml ... ?>" если есть. }
      P := Pos('?>', XmlText);
      if (P > 0) and (Copy(XmlText, 1, 5) = '<?xml') then
        XmlText := Trim(Copy(XmlText, P + 2, MaxInt));
      Result := Trim(XmlText);
    finally
      SS.Free;
    end;
  finally
    TempDoc.Free;
  end;
end;

{ Вставляет outer XML-строку как ребёнка ParentEl. На обратной
  стороне от NodeToOuterXml. Если строка не парсится — пропускаем
  с warning, не падаем (не должно быть, т. к. мы сами её
  сериализовали). }
procedure AppendOuterXml(Doc: TXMLDocument; ParentEl: TDOMElement;
  const OuterXml: String);
var
  TempDoc: TXMLDocument;
  SS: TStringStream;
  Imported: TDOMNode;
  Wrapped: String;
begin
  if Trim(OuterXml) = '' then Exit;
  Wrapped := '<?xml version="1.0" encoding="UTF-8"?><root>' +
    OuterXml + '</root>';
  SS := TStringStream.Create(Wrapped);
  try
    try
      ReadXMLFile(TempDoc, SS);
    except
      on E: Exception do
      begin
        WritelnWarning('Workout',
          'AppendOuterXml: не удалось распарсить pass-through XML [%s]: %s',
          [E.ClassName, E.Message]);
        Exit;
      end;
    end;
    if (TempDoc <> nil) and (TempDoc.DocumentElement <> nil) then
      try
        while TempDoc.DocumentElement.FirstChild <> nil do
        begin
          Imported := Doc.ImportNode(TempDoc.DocumentElement.FirstChild, True);
          ParentEl.AppendChild(Imported);
          TempDoc.DocumentElement.RemoveChild(TempDoc.DocumentElement.FirstChild);
        end;
      finally
        TempDoc.Free;
      end;
  finally
    SS.Free;
  end;
end;

{ ── Форматирование значений для записи в XML ─────────────────────── }

{ Целые секунды — Zwift сам редактор пишет как float ('300.0000001'),
  но валидно и просто '300', и оба варианта читаются. Берём целые. }
function FormatDurationXml(D: Single): String;
begin
  Result := IntToStr(Max(0, Round(D)));
end;

{ Доля FTP — две знаков после запятой, без хвостовых нулей.
  '0.50' → '0.5'; '1.00' → '1'; '0.85' → '0.85'.
  Точка как разделитель независимо от локали. }
function FormatPowerXml(P: Single): String;
var
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  FS.ThousandSeparator := ',';
  Result := Format('%.2f', [P], FS);
  while (Length(Result) > 1) and (Result[Length(Result)] = '0') do
    SetLength(Result, Length(Result) - 1);
  if (Length(Result) > 1) and (Result[Length(Result)] = '.') then
    SetLength(Result, Length(Result) - 1);
end;

{ ── XML I/O helpers ───────────────────────────────────────────────── }

function DownloadAsString(const AUrl: String): String;
var
  Stream: TStream;
  SS: TStringStream;
begin
  Result := '';
  Stream := Download(AUrl, []);
  try
    SS := TStringStream.Create('');
    try
      SS.CopyFrom(Stream, 0);
      Result := SS.DataString;
    finally
      SS.Free;
    end;
  finally
    Stream.Free;
  end;
end;

function IsValidEntityRefAt(const S: String; StartIdx, L: Integer): Boolean;
var
  J, MaxJ: Integer;
  IsNumeric: Boolean;
begin
  Result := False;
  if (StartIdx > L) or (S[StartIdx] <> '&') then Exit;
  MaxJ := StartIdx + 10;
  if MaxJ > L then MaxJ := L;

  J := StartIdx + 1;
  if J > L then Exit;

  IsNumeric := S[J] = '#';
  if IsNumeric then
  begin
    Inc(J);
    if J > L then Exit;
    if (S[J] = 'x') or (S[J] = 'X') then Inc(J);
    while (J <= MaxJ) and (S[J] in ['0'..'9', 'a'..'f', 'A'..'F']) do Inc(J);
  end
  else
    while (J <= MaxJ) and (S[J] in ['a'..'z', 'A'..'Z', '0'..'9']) do Inc(J);

  Result := (J <= L) and (S[J] = ';') and (J > StartIdx + 2);
end;

function SanitizeAmpersands(const S: String): String;
var
  I, L, OutLen: Integer;
  AmpCount: Integer;
begin
  L := Length(S);
  AmpCount := 0;
  for I := 1 to L do
    if (S[I] = '&') and not IsValidEntityRefAt(S, I, L) then
      Inc(AmpCount);

  if AmpCount = 0 then Exit(S);

  SetLength(Result, L + AmpCount * 4);
  OutLen := 0;
  I := 1;
  while I <= L do
  begin
    if (S[I] = '&') and not IsValidEntityRefAt(S, I, L) then
    begin
      Inc(OutLen); Result[OutLen] := '&';
      Inc(OutLen); Result[OutLen] := 'a';
      Inc(OutLen); Result[OutLen] := 'm';
      Inc(OutLen); Result[OutLen] := 'p';
      Inc(OutLen); Result[OutLen] := ';';
    end
    else
    begin
      Inc(OutLen);
      Result[OutLen] := S[I];
    end;
    Inc(I);
  end;
  SetLength(Result, OutLen);
end;

function TryParseXmlString(const AContent, AUrl, ATag: String;
  out ADoc: TXMLDocument): Boolean;
var
  SS: TStringStream;
begin
  Result := False;
  ADoc := nil;
  if AContent = '' then Exit;

  SS := TStringStream.Create(AContent);
  try
    try
      ReadXMLFile(ADoc, SS);
      Result := ADoc <> nil;
    except
      on E: Exception do
      begin
        FreeAndNil(ADoc);
        WritelnLog('Workout', '%s parse failed [%s]: %s — %s',
          [ATag, E.ClassName, AUrl, E.Message]);
      end;
    end;
  finally
    SS.Free;
  end;
end;

{ ── Default values для нового сегмента ────────────────────────────── }

procedure InitDefaultSegment(Seg: TWorkoutSegment; AKind: TWorkoutSegmentKind);
begin
  Seg.Kind := AKind;
  Seg.RepeatGroup := 0;
  Seg.IsOnPart := False;
  case AKind of
    wskWarmup:
      begin
        Seg.Duration := 600;     { 10 min }
        Seg.PowerLow := 0.5;
        Seg.PowerHigh := 0.75;
      end;
    wskCooldown:
      begin
        Seg.Duration := 300;     { 5 min }
        Seg.PowerLow := 0.5;
        Seg.PowerHigh := 0.3;
      end;
    wskRamp:
      begin
        Seg.Duration := 300;
        Seg.PowerLow := 0.5;
        Seg.PowerHigh := 0.75;
      end;
    wskSteady, wskInterval:
      begin
        Seg.Duration := 300;
        Seg.PowerLow := 0.7;
        Seg.PowerHigh := 0.7;
      end;
    wskFreeRide:
      begin
        Seg.Duration := 300;
        Seg.PowerLow := 0;
        Seg.PowerHigh := 0;
      end;
  end;
end;

{ ── TWorkoutFile ───────────────────────────────────────────────────── }

{ ── TWorkoutTextEvent ──────────────────────────────────────────────── }

constructor TWorkoutTextEvent.Create;
begin
  inherited;
  RawAttrs := TStringList.Create;
  OrigTagName := 'textevent';
end;

destructor TWorkoutTextEvent.Destroy;
begin
  FreeAndNil(RawAttrs);
  inherited;
end;

{ ── TWorkoutSegment ────────────────────────────────────────────────── }

constructor TWorkoutSegment.Create;
begin
  inherited;
  RawAttrs    := TStringList.Create;
  RawChildren := TStringList.Create;
  TextEvents  := TWorkoutTextEventList.Create(True);  { OwnsObjects }
end;

destructor TWorkoutSegment.Destroy;
begin
  FreeAndNil(TextEvents);
  FreeAndNil(RawChildren);
  FreeAndNil(RawAttrs);
  inherited;
end;

{ ── TWorkoutFile ───────────────────────────────────────────────────── }

constructor TWorkoutFile.Create;
begin
  inherited;
  FSegments := TWorkoutSegmentList.Create(True);  { OwnsObjects }
  FRawHeaderChildren := TStringList.Create;
  FModified := False;
end;

destructor TWorkoutFile.Destroy;
begin
  FreeAndNil(FRawHeaderChildren);
  FreeAndNil(FSegments);
  inherited;
end;

function TWorkoutFile.Clone: TWorkoutFile;
var
  Src, Dst: TWorkoutSegment;
  SrcEvent, DstEvent: TWorkoutTextEvent;
begin
  Result := TWorkoutFile.Create;
  try
    Result.FName := FName;
    Result.FDescription := FDescription;
    Result.FAuthor := FAuthor;
    Result.FSportType := FSportType;
    Result.FUrl := FUrl;
    Result.ScheduleUserId:=ScheduleUserId;Result.ScheduleKey:=ScheduleKey;
    Result.FCategory := FCategory;
    Result.FRawHeaderChildren.Assign(FRawHeaderChildren);
    for Src in FSegments do
    begin
      Dst := Result.AddSegment(Src.Kind);
      Dst.Duration := Src.Duration;
      Dst.PowerLow := Src.PowerLow;
      Dst.PowerHigh := Src.PowerHigh;
      Dst.RepeatGroup := Src.RepeatGroup;
      Dst.IsOnPart := Src.IsOnPart;
      Dst.Cadence := Src.Cadence;
      Dst.CadenceResting := Src.CadenceResting;
      Dst.CadenceLow := Src.CadenceLow;
      Dst.CadenceHigh := Src.CadenceHigh;
      Dst.RawAttrs.Assign(Src.RawAttrs);
      Dst.RawChildren.Assign(Src.RawChildren);
      for SrcEvent in Src.TextEvents do
      begin
        DstEvent := TWorkoutTextEvent.Create;
        try
          DstEvent.TimeOffset := SrcEvent.TimeOffset;
          DstEvent.Duration := SrcEvent.Duration;
          DstEvent.Message := SrcEvent.Message;
          DstEvent.OrigTagName := SrcEvent.OrigTagName;
          DstEvent.RawAttrs.Assign(SrcEvent.RawAttrs);
          Dst.TextEvents.Add(DstEvent);
          DstEvent := nil;
        finally
          DstEvent.Free;
        end;
      end;
    end;
    Result.FModified := FModified;
  except
    Result.Free;
    raise;
  end;
end;

procedure TWorkoutFile.SetName(const V: String);
begin
  if FName = V then Exit;
  FName := V;
  FModified := True;
end;

procedure TWorkoutFile.SetDescription(const V: String);
begin
  if FDescription = V then Exit;
  FDescription := V;
  FModified := True;
end;

procedure TWorkoutFile.SetAuthor(const V: String);
begin
  if FAuthor = V then Exit;
  FAuthor := V;
  FModified := True;
end;

procedure TWorkoutFile.SetSportType(const V: String);
begin
  if FSportType = V then Exit;
  FSportType := V;
  FModified := True;
end;

function TWorkoutFile.GetTotalDuration: Single;
var
  I: Integer;
begin
  Result := 0;
  for I := 0 to FSegments.Count - 1 do
    Result := Result + FSegments[I].Duration;
end;

{ Аппроксимация Normalized Power → Intensity Factor.
  Формула: IF = (Σ p^4 * dt / Σ dt) ^ (1/4). }
function TWorkoutFile.GetIntensityFactor: Single;
var
  I: Integer;
  Sum, P, Total: Double;
  Seg: TWorkoutSegment;
begin
  Result := 0;
  if FSegments.Count = 0 then Exit;
  Sum := 0; Total := 0;
  for I := 0 to FSegments.Count - 1 do
  begin
    Seg := FSegments[I];
    case Seg.Kind of
      wskSteady, wskInterval:        P := Seg.PowerLow;
      wskWarmup, wskCooldown, wskRamp: P := (Seg.PowerLow + Seg.PowerHigh) / 2;
      wskFreeRide:                   P := 0.65;
    else
      P := Seg.PowerLow;
    end;
    Sum := Sum + Math.Power(P, 4) * Seg.Duration;
    Total := Total + Seg.Duration;
  end;
  if Total <= 0 then Exit;
  Result := Math.Power(Sum / Total, 1.0 / 4.0);
end;

function TWorkoutFile.GetTSS: Single;
var
  IF_: Single;
begin
  IF_ := GetIntensityFactor;
  Result := (GetTotalDuration / 3600) * IF_ * IF_ * 100;
end;

{ ── Мутаторы списка сегментов ──────────────────────────────────────── }

function TWorkoutFile.AddSegment(AKind: TWorkoutSegmentKind): TWorkoutSegment;
begin
  Result := TWorkoutSegment.Create;
  InitDefaultSegment(Result, AKind);
  FSegments.Add(Result);
  FModified := True;
end;

function TWorkoutFile.InsertSegmentAfter(Index: Integer;
  AKind: TWorkoutSegmentKind): TWorkoutSegment;
var
  InsertAt: Integer;
begin
  Result := TWorkoutSegment.Create;
  InitDefaultSegment(Result, AKind);
  if Index < 0 then
    InsertAt := FSegments.Count
  else if Index >= FSegments.Count then
    InsertAt := FSegments.Count
  else
    InsertAt := Index + 1;
  FSegments.Insert(InsertAt, Result);
  FModified := True;
end;

procedure TWorkoutFile.DeleteSegment(Index: Integer);
begin
  if (Index < 0) or (Index >= FSegments.Count) then Exit;
  FSegments.Delete(Index);
  FModified := True;
end;

procedure TWorkoutFile.SwapSegments(IndexA, IndexB: Integer);
begin
  if (IndexA < 0) or (IndexB < 0) then Exit;
  if (IndexA >= FSegments.Count) or (IndexB >= FSegments.Count) then Exit;
  if IndexA = IndexB then Exit;
  FSegments.Exchange(IndexA, IndexB);
  FModified := True;
end;

function TWorkoutFile.DuplicateSegment(Index: Integer): TWorkoutSegment;
var
  Src: TWorkoutSegment;
begin
  Result := nil;
  if (Index < 0) or (Index >= FSegments.Count) then Exit;
  Src := FSegments[Index];
  Result := TWorkoutSegment.Create;
  Result.Kind := Src.Kind;
  Result.Duration := Src.Duration;
  Result.PowerLow := Src.PowerLow;
  Result.PowerHigh := Src.PowerHigh;
  Result.Cadence := Src.Cadence;
  Result.CadenceResting := Src.CadenceResting;
  Result.CadenceLow := Src.CadenceLow;
  Result.CadenceHigh := Src.CadenceHigh;
  { Pass-through атрибуты дублируем, дочерние элементы (RawChildren,
    TextEvents) — нет: новый сегмент это новая сущность, и иметь
    «привязку» к старым детям было бы странно (например, две копии
    того же текстового сообщения). }
  Result.RawAttrs.Assign(Src.RawAttrs);
  { Дубликат теряет принадлежность к группе IntervalsT — иначе он
    сломает re-rolling и нарушит парность On/Off. }
  Result.RepeatGroup := 0;
  Result.IsOnPart := False;
  FSegments.Insert(Index + 1, Result);
  FModified := True;
end;

{ ── Групповые операции ─────────────────────────────────────────────── }

function TWorkoutFile.GroupRange(SegIndex: Integer;
  out FirstIdx, LastIdx: Integer): Boolean;
var
  G: Integer;
begin
  Result := False;
  FirstIdx := -1;
  LastIdx := -1;
  if (SegIndex < 0) or (SegIndex >= FSegments.Count) then Exit;
  G := FSegments[SegIndex].RepeatGroup;
  if G <= 0 then Exit;

  FirstIdx := SegIndex;
  while (FirstIdx > 0) and (FSegments[FirstIdx - 1].RepeatGroup = G) do
    Dec(FirstIdx);

  LastIdx := SegIndex;
  while (LastIdx + 1 < FSegments.Count) and
        (FSegments[LastIdx + 1].RepeatGroup = G) do
    Inc(LastIdx);

  Result := True;
end;

function TWorkoutFile.GroupRepCount(SegIndex: Integer): Integer;
var
  FirstIdx, LastIdx: Integer;
begin
  Result := 0;
  if not GroupRange(SegIndex, FirstIdx, LastIdx) then Exit;
  { Количество сегментов / 2, потому что один повтор = пара On+Off.
    Если по какой-то причине число нечётное — округляем вверх. }
  Result := (LastIdx - FirstIdx + 2) div 2;
end;

function TWorkoutFile.CanonicalSegmentIndex(SegIndex: Integer): Integer;
var
  FirstIdx, LastIdx: Integer;
begin
  Result := -1;
  if (SegIndex < 0) or (SegIndex >= FSegments.Count) then Exit;
  if GroupRange(SegIndex, FirstIdx, LastIdx) then
    Result := FirstIdx
  else
    Result := SegIndex;
end;

procedure TWorkoutFile.SetGroupDuration(SegIndex: Integer; D: Single);
var
  FirstIdx, LastIdx, I: Integer;
  Phase: Boolean;
begin
  if (SegIndex < 0) or (SegIndex >= FSegments.Count) then Exit;
  if D <= 0 then Exit;

  if GroupRange(SegIndex, FirstIdx, LastIdx) then
  begin
    Phase := FSegments[SegIndex].IsOnPart;
    for I := FirstIdx to LastIdx do
      if FSegments[I].IsOnPart = Phase then
        FSegments[I].Duration := D;
  end
  else
    FSegments[SegIndex].Duration := D;

  FModified := True;
end;

procedure TWorkoutFile.SetGroupPower(SegIndex: Integer; P: Single);
var
  FirstIdx, LastIdx, I: Integer;
  Phase: Boolean;
  Seg: TWorkoutSegment;
begin
  if (SegIndex < 0) or (SegIndex >= FSegments.Count) then Exit;
  if P < 0 then Exit;

  if GroupRange(SegIndex, FirstIdx, LastIdx) then
  begin
    Phase := FSegments[SegIndex].IsOnPart;
    for I := FirstIdx to LastIdx do
      if FSegments[I].IsOnPart = Phase then
      begin
        Seg := FSegments[I];
        Seg.PowerLow := P;
        Seg.PowerHigh := P;  { interval-сегменты держат Low=High }
      end;
  end
  else
  begin
    Seg := FSegments[SegIndex];
    Seg.PowerLow := P;
    if Seg.Kind in [wskSteady, wskInterval, wskFreeRide] then
      Seg.PowerHigh := P;
  end;

  FModified := True;
end;

procedure TWorkoutFile.SetGroupCadence(SegIndex: Integer;
  CadenceRPM: Integer; HighSide: Boolean);
var
  FirstIdx, LastIdx, I: Integer;
  Phase: Boolean;
  Seg: TWorkoutSegment;
begin
  if (SegIndex < 0) or (SegIndex >= FSegments.Count) then Exit;
  if CadenceRPM < 0 then CadenceRPM := 0;

  if GroupRange(SegIndex, FirstIdx, LastIdx) then
  begin
    { В IntervalsT-группе: On-фаза → пишем в Cadence,
      Off-фаза → в CadenceResting. HighSide игнорируется (для
      интервалов диапазон Low/High не используется). }
    Phase := FSegments[SegIndex].IsOnPart;
    for I := FirstIdx to LastIdx do
      if FSegments[I].IsOnPart = Phase then
      begin
        Seg := FSegments[I];
        if Phase then
          Seg.Cadence := CadenceRPM
        else
          Seg.CadenceResting := CadenceRPM;
      end;
  end
  else
  begin
    Seg := FSegments[SegIndex];
    case Seg.Kind of
      wskWarmup, wskCooldown, wskRamp:
        begin
          if HighSide then
            Seg.CadenceHigh := CadenceRPM
          else
            Seg.CadenceLow := CadenceRPM;
          { Поддерживаем зеркало в «постоянном» Cadence — пользователь
            может прийти из старого workout-а где был только Cadence,
            и не запутаемся при чтении. Если оба Low/High = 0 (всё
            unset), Cadence тоже сбрасывается. }
          if (Seg.CadenceLow > 0) and (Seg.CadenceHigh > 0) and
             (Seg.CadenceLow = Seg.CadenceHigh) then
            Seg.Cadence := Seg.CadenceLow
          else
            Seg.Cadence := 0;
        end;
      wskSteady:
        Seg.Cadence := CadenceRPM;
      wskFreeRide:
        Seg.Cadence := CadenceRPM;
    end;
  end;

  FModified := True;
end;

function TWorkoutFile.DeleteGroupRepOrSingle(SegIndex: Integer): Integer;
var
  FirstIdx, LastIdx, OnIdx, OffIdx: Integer;
begin
  Result := -1;
  if (SegIndex < 0) or (SegIndex >= FSegments.Count) then Exit;

  if GroupRange(SegIndex, FirstIdx, LastIdx) then
  begin
    { Один повтор = пара (On, Off). Найдём оба сегмента пары к
      которой относится клик. }
    if FSegments[SegIndex].IsOnPart then
    begin
      OnIdx := SegIndex;
      OffIdx := SegIndex + 1;
      { Если справа нет Off (битая структура) — на всякий случай
        попробуем слева. }
      if (OffIdx > LastIdx) or (FSegments[OffIdx].IsOnPart) then
        OffIdx := -1;
    end
    else
    begin
      OffIdx := SegIndex;
      OnIdx := SegIndex - 1;
      if (OnIdx < FirstIdx) or (not FSegments[OnIdx].IsOnPart) then
        OnIdx := -1;
    end;

    { Удаляем оба (или одного из них, если пара битая). }
    if (OnIdx >= 0) and (OffIdx >= 0) then
    begin
      { Удаляем больший индекс первым, чтобы меньший не сместился. }
      if OffIdx > OnIdx then
      begin
        FSegments.Delete(OffIdx);
        FSegments.Delete(OnIdx);
      end
      else
      begin
        FSegments.Delete(OnIdx);
        FSegments.Delete(OffIdx);
      end;
    end
    else if OnIdx >= 0 then
      FSegments.Delete(OnIdx)
    else if OffIdx >= 0 then
      FSegments.Delete(OffIdx)
    else
      FSegments.Delete(SegIndex);

    { Что выделить дальше: оставшийся сегмент группы по тому же
      FirstIdx, либо ближайший выживший, либо ничего. }
    if FSegments.Count = 0 then
      Result := -1
    else if FirstIdx < FSegments.Count then
      Result := FirstIdx
    else
      Result := FSegments.Count - 1;
  end
  else
  begin
    FSegments.Delete(SegIndex);
    if FSegments.Count = 0 then
      Result := -1
    else if SegIndex < FSegments.Count then
      Result := SegIndex
    else
      Result := FSegments.Count - 1;
  end;

  FModified := True;
end;

function TWorkoutFile.DuplicateGroupRepOrSingle(SegIndex: Integer): Integer;
var
  FirstIdx, LastIdx: Integer;
  OnSrc, OffSrc, OnNew, OffNew: TWorkoutSegment;
begin
  Result := -1;
  if (SegIndex < 0) or (SegIndex >= FSegments.Count) then Exit;

  if GroupRange(SegIndex, FirstIdx, LastIdx) then
  begin
    { В группе всегда чередование On, Off, On, Off, … начиная с On.
      Берём первый On и первый Off как образцы — в редакторе с гибридом
      все «On»-ы группы синхронизированы, как и «Off»-ы. }
    OnSrc := nil; OffSrc := nil;
    if FSegments[FirstIdx].IsOnPart then
      OnSrc := FSegments[FirstIdx];
    if (FirstIdx + 1 <= LastIdx) and (not FSegments[FirstIdx + 1].IsOnPart) then
      OffSrc := FSegments[FirstIdx + 1];

    { Создаём новую пару, добавляем в конец группы. }
    if Assigned(OnSrc) then
    begin
      OnNew := TWorkoutSegment.Create;
      OnNew.Kind := wskInterval;
      OnNew.Duration := OnSrc.Duration;
      OnNew.PowerLow := OnSrc.PowerLow;
      OnNew.PowerHigh := OnSrc.PowerHigh;
      OnNew.Cadence := OnSrc.Cadence;
      OnNew.CadenceLow := OnSrc.CadenceLow;
      OnNew.CadenceHigh := OnSrc.CadenceHigh;
      OnNew.RepeatGroup := OnSrc.RepeatGroup;
      OnNew.IsOnPart := True;
      FSegments.Insert(LastIdx + 1, OnNew);
      Result := LastIdx + 1;
      Inc(LastIdx);
    end;

    if Assigned(OffSrc) then
    begin
      OffNew := TWorkoutSegment.Create;
      OffNew.Kind := wskInterval;
      OffNew.Duration := OffSrc.Duration;
      OffNew.PowerLow := OffSrc.PowerLow;
      OffNew.PowerHigh := OffSrc.PowerHigh;
      OffNew.Cadence := OffSrc.Cadence;
      OffNew.CadenceResting := OffSrc.CadenceResting;
      OffNew.RepeatGroup := OffSrc.RepeatGroup;
      OffNew.IsOnPart := False;
      FSegments.Insert(LastIdx + 1, OffNew);
      if Result < 0 then Result := LastIdx + 1;
    end;

    FModified := True;
  end
  else
  begin
    if Assigned(DuplicateSegment(SegIndex)) then
      Result := SegIndex + 1;
  end;
end;

function TWorkoutFile.MoveBlock(SegIndex: Integer;
  Direction: Integer): Integer;
var
  GS, GE, AS_, AE: Integer;     { границы нашего блока и соседнего }
  BlockLen, AdjLen, I, NewStart: Integer;
  Saved: array of TWorkoutSegment;

  procedure FindBlockAround(Idx: Integer; out BS, BE: Integer);
  var
    GFirst, GLast: Integer;
  begin
    if GroupRange(Idx, GFirst, GLast) then
    begin
      BS := GFirst;
      BE := GLast;
    end
    else
    begin
      BS := Idx;
      BE := Idx;
    end;
  end;

begin
  Result := SegIndex;
  if (SegIndex < 0) or (SegIndex >= FSegments.Count) then Exit;
  if Direction = 0 then Exit;

  FindBlockAround(SegIndex, GS, GE);
  BlockLen := GE - GS + 1;

  if Direction > 0 then
  begin
    if GE >= FSegments.Count - 1 then Exit;   { некуда вправо }
    FindBlockAround(GE + 1, AS_, AE);
  end
  else
  begin
    if GS <= 0 then Exit;                     { некуда влево }
    FindBlockAround(GS - 1, AS_, AE);
  end;
  AdjLen := AE - AS_ + 1;

  { Вынимаем наш блок (без free), сохраняем ссылки. }
  SetLength(Saved, BlockLen);
  for I := 0 to BlockLen - 1 do
    Saved[I] := FSegments[GS + I];
  for I := 0 to BlockLen - 1 do
    FSegments.Extract(Saved[I]);

  { После Extract соседний блок «съехал». Если двигались вправо —
    он теперь занимает позиции [GS .. GS+AdjLen-1], а нам надо
    встать сразу после него: NewStart := GS + AdjLen.
    Если влево — соседний блок остался на своём месте [AS_ .. AE],
    мы вставляемся ПЕРЕД ним: NewStart := AS_. }
  if Direction > 0 then
    NewStart := GS + AdjLen
  else
    NewStart := AS_;

  for I := 0 to BlockLen - 1 do
    FSegments.Insert(NewStart + I, Saved[I]);

  FModified := True;
  { Возвращаем новый индекс кликнутого сегмента в его блоке. }
  Result := NewStart + (SegIndex - GS);
end;

function TWorkoutFile.SetGroupRepeatCount(SegIndex: Integer;
  NewCount: Integer): Integer;
var
  FirstIdx, LastIdx, CurCount, Diff, I: Integer;
  OnSrc, OffSrc, NewSeg: TWorkoutSegment;
  GroupId: Integer;
begin
  Result := -1;
  if NewCount < 1 then Exit;
  if not GroupRange(SegIndex, FirstIdx, LastIdx) then Exit;

  CurCount := (LastIdx - FirstIdx + 2) div 2;
  if CurCount = NewCount then
  begin
    Result := FirstIdx;
    Exit;
  end;

  GroupId := FSegments[FirstIdx].RepeatGroup;

  { Образцовая пара (On, Off) — берём первые два сегмента группы,
    они «канонические». При гибридном редактировании все остальные
    On/Off синхронизированы с ними по Duration/Power. }
  OnSrc := nil; OffSrc := nil;
  if (FirstIdx <= LastIdx) and FSegments[FirstIdx].IsOnPart then
    OnSrc := FSegments[FirstIdx];
  if (FirstIdx + 1 <= LastIdx) and (not FSegments[FirstIdx + 1].IsOnPart) then
    OffSrc := FSegments[FirstIdx + 1];
  if (OnSrc = nil) or (OffSrc = nil) then Exit;

  Diff := NewCount - CurCount;

  if Diff > 0 then
  begin
    { Добавляем Diff повторов сразу за LastIdx. Образец читаем
      ДО первой вставки — после неё OnSrc/OffSrc остаются
      валидными ссылками (мы не трогаем сами объекты), но индексы
      бы сдвинулись. }
    for I := 1 to Diff do
    begin
      NewSeg := TWorkoutSegment.Create;
      NewSeg.Kind := wskInterval;
      NewSeg.Duration := OnSrc.Duration;
      NewSeg.PowerLow := OnSrc.PowerLow;
      NewSeg.PowerHigh := OnSrc.PowerHigh;
      NewSeg.Cadence := OnSrc.Cadence;
      NewSeg.CadenceLow := OnSrc.CadenceLow;
      NewSeg.CadenceHigh := OnSrc.CadenceHigh;
      NewSeg.RepeatGroup := GroupId;
      NewSeg.IsOnPart := True;
      Inc(LastIdx);
      FSegments.Insert(LastIdx, NewSeg);

      NewSeg := TWorkoutSegment.Create;
      NewSeg.Kind := wskInterval;
      NewSeg.Duration := OffSrc.Duration;
      NewSeg.PowerLow := OffSrc.PowerLow;
      NewSeg.PowerHigh := OffSrc.PowerHigh;
      NewSeg.Cadence := OffSrc.Cadence;
      NewSeg.CadenceResting := OffSrc.CadenceResting;
      NewSeg.RepeatGroup := GroupId;
      NewSeg.IsOnPart := False;
      Inc(LastIdx);
      FSegments.Insert(LastIdx, NewSeg);
    end;
  end
  else
  begin
    { Удаляем |Diff| повторов с конца группы. Каждый повтор — это
      пара сегментов: Off (в LastIdx) и On (в LastIdx-1). Удаляем
      больший индекс первым — иначе меньший уплыл бы. }
    for I := 1 to -Diff do
    begin
      if LastIdx <= FirstIdx + 1 then Break;  { защита: оставляем минимум одну пару }
      FSegments.Delete(LastIdx);      { Off }
      Dec(LastIdx);
      FSegments.Delete(LastIdx);      { On }
      Dec(LastIdx);
    end;
  end;

  FModified := True;
  Result := FirstIdx;
end;

{ ── LoadFromUrl ────────────────────────────────────────────────────── }

function TWorkoutFile.LoadFromUrl(const AUrl: String): Boolean;
var
  Doc: TXMLDocument;
  Root, WorkoutNode, Child, HeadChild: TDOMElement;
  Iter, HeaderIter: TXMLElementIterator;
  GroupId: Integer;
  TagName: String;
  RawContent, Sanitized: String;

  function AddSeg(AKind: TWorkoutSegmentKind;
    ADuration, APowerLow, APowerHigh: Single;
    ARepeatGroup: Integer; AIsOnPart: Boolean): TWorkoutSegment;
  begin
    Result := TWorkoutSegment.Create;
    Result.Kind := AKind;
    Result.Duration := ADuration;
    Result.PowerLow := APowerLow;
    Result.PowerHigh := APowerHigh;
    Result.RepeatGroup := ARepeatGroup;
    Result.IsOnPart := AIsOnPart;
    FSegments.Add(Result);
  end;

  { Копирует все атрибуты узла, не входящие в known-set для данного
    Kind, в Seg.RawAttrs. Имена атрибутов берём как они есть в XML
    (без LowerCase) — иначе при записи мы их переименуем и файл
    «протекает». }
  procedure CaptureUnknownAttrs(Seg: TWorkoutSegment; Node: TDOMElement);
  var
    I: Integer;
    AttrNode: TDOMNode;
  begin
    if Node.Attributes = nil then Exit;
    for I := 0 to Node.Attributes.Length - 1 do
    begin
      AttrNode := Node.Attributes[I];
      if AttrNode.NodeType = ATTRIBUTE_NODE then
        if not IsKnownSegmentAttr(Seg.Kind, String(AttrNode.NodeName)) then
          Seg.RawAttrs.Add(
            String(AttrNode.NodeName) + '=' + String(AttrNode.NodeValue));
    end;
  end;

  { Парсит детей сегмента: <textevent>/<TextEvent>/<TextNotification>
    идут в Seg.TextEvents; всё остальное — в Seg.RawChildren как
    outer XML. }
  procedure CaptureChildren(Seg: TWorkoutSegment; Node: TDOMElement);
  var
    SubChild: TDOMElement;
    SubIter: TXMLElementIterator;
    Te: TWorkoutTextEvent;
    SubName: String;
    K: Integer;
    AttrNode: TDOMNode;
    AttrLower: String;
  begin
    SubIter := Node.ChildrenIterator;
    try
      while SubIter.GetNext do
      begin
        SubChild := SubIter.Current;
        SubName := String(SubChild.TagName);

        if IsTextEventTag(SubName) then
        begin
          Te := TWorkoutTextEvent.Create;
          Te.OrigTagName := SubName;
          Te.TimeOffset := AttrFloat(SubChild, 'timeoffset',
            AttrFloat(SubChild, 'TimeOffset', 0));
          Te.Duration := AttrFloat(SubChild, 'duration',
            AttrFloat(SubChild, 'Duration', 0));
          Te.Message := SubChild.AttributeStringDef('message',
            SubChild.AttributeStringDef('text', ''));

          if SubChild.Attributes <> nil then
            for K := 0 to SubChild.Attributes.Length - 1 do
            begin
              AttrNode := SubChild.Attributes[K];
              if AttrNode.NodeType = ATTRIBUTE_NODE then
              begin
                AttrLower := LowerCase(String(AttrNode.NodeName));
                if (AttrLower <> 'timeoffset') and
                   (AttrLower <> 'duration') and
                   (AttrLower <> 'message') and
                   (AttrLower <> 'text') then
                  Te.RawAttrs.Add(
                    String(AttrNode.NodeName) + '=' +
                    String(AttrNode.NodeValue));
              end;
            end;

          Seg.TextEvents.Add(Te);
        end
        else
          Seg.RawChildren.Add(NodeToOuterXml(SubChild));
      end;
    finally
      SubIter.Free;
    end;
  end;

  { Парсит обычный сегмент (всё кроме IntervalsT): известные атрибуты
    в типизированные поля, остальное в RawAttrs, дочерние элементы
    через CaptureChildren. }
  procedure ProcessSimpleSegment(AKind: TWorkoutSegmentKind;
    Node: TDOMElement);
  var
    Seg: TWorkoutSegment;
    DefPwr, DefPwrHigh: Single;
  begin
    case AKind of
      wskWarmup, wskCooldown, wskRamp:
        begin
          if AKind = wskCooldown then DefPwrHigh := 0.5
                                 else DefPwrHigh := 0.75;
          Seg := AddSeg(AKind,
            AttrFloat(Node, 'Duration', 0),
            AttrFloat(Node, 'PowerLow', 0.5),
            AttrFloat(Node, 'PowerHigh', DefPwrHigh),
            0, False);
          Seg.CadenceLow := AttrInt(Node, 'CadenceLow',
            AttrInt(Node, 'Cadence', 0));
          Seg.CadenceHigh := AttrInt(Node, 'CadenceHigh',
            AttrInt(Node, 'Cadence', 0));
          Seg.Cadence := AttrInt(Node, 'Cadence', 0);
        end;
      wskSteady:
        begin
          DefPwr := AttrFloat(Node, 'Power',
            (AttrFloat(Node,'PowerLow',0.6)+AttrFloat(Node,'PowerHigh',
              AttrFloat(Node,'PowerLow',0.6)))*0.5);
          Seg := AddSeg(wskSteady, AttrFloat(Node, 'Duration', 0),
            DefPwr, DefPwr, 0, False);
          Seg.Cadence := AttrInt(Node, 'Cadence', 0);
          Seg.CadenceResting := AttrInt(Node, 'CadenceResting', 0);
        end;
      wskFreeRide:
        begin
          Seg := AddSeg(wskFreeRide,
            AttrFloat(Node, 'Duration', 60), 0, 0, 0, False);
          Seg.Cadence := AttrInt(Node, 'Cadence', 0);
        end;
    else
      Exit;
    end;

    CaptureUnknownAttrs(Seg, Node);
    CaptureChildren(Seg, Node);
  end;

  { Парсит IntervalsT — разворачивает в Repeats × (On, Off). Cadence
    из родительского узла копируется в каждую On-часть, CadenceResting
    в каждую Off-часть. RawAttrs/RawChildren родительского узла мы
    кладём в первый сегмент группы — он будет «каноническим» при
    re-rolling в v2. TextEvents IntervalsT идут на первый On.
    Унаследованные атрибуты в N-кратном дублировании на разворачиваемых
    сегментах — нет, это бы исказило значение OverUnder etc. }
  procedure ProcessIntervalsT(Node: TDOMElement; AGroupId: Integer);
  var
    Seg, FirstSeg: TWorkoutSegment;
    Repeats, R: Integer;
    OnDur, OffDur, OnPwr, OffPwr: Single;
    OnCad, OffCad, CadL, CadH: Integer;
  begin
    Repeats := AttrInt(Node, 'Repeat', 1);
    if Repeats < 1 then Repeats := 1;

    OnDur := AttrFloat(Node, 'OnDuration', 30);
    OffDur := AttrFloat(Node, 'OffDuration', 30);
    OnPwr := AttrFloat(Node, 'OnPower',
      (AttrFloat(Node,'OnPowerLow',1.0)+AttrFloat(Node,'OnPowerHigh',
        AttrFloat(Node,'OnPowerLow',1.0)))*0.5);
    OffPwr := AttrFloat(Node, 'OffPower',
      (AttrFloat(Node,'OffPowerLow',0.5)+AttrFloat(Node,'OffPowerHigh',
        AttrFloat(Node,'OffPowerLow',0.5)))*0.5);

    OnCad  := AttrInt(Node, 'Cadence', 0);
    OffCad := AttrInt(Node, 'CadenceResting', 0);
    CadL   := AttrInt(Node, 'CadenceLow', 0);
    CadH   := AttrInt(Node, 'CadenceHigh', 0);

    FirstSeg := nil;
    for R := 1 to Repeats do
    begin
      Seg := AddSeg(wskInterval, OnDur, OnPwr, OnPwr, AGroupId, True);
      Seg.Cadence := OnCad;
      Seg.CadenceLow := CadL;
      Seg.CadenceHigh := CadH;
      if FirstSeg = nil then FirstSeg := Seg;

      Seg := AddSeg(wskInterval, OffDur, OffPwr, OffPwr, AGroupId, False);
      Seg.Cadence := OffCad;
      Seg.CadenceResting := OffCad;
    end;

    { Pass-through на первом сегменте — он же канонический. }
    if FirstSeg <> nil then
    begin
      CaptureUnknownAttrs(FirstSeg, Node);
      CaptureChildren(FirstSeg, Node);
    end;
  end;

begin
  Result := False;
  FUrl := AUrl;
  ScheduleUserId:=0;ScheduleKey:='';
  FName := ChangeFileExt(ExtractFileName(AUrl), '');
  FSegments.Clear;
  FRawHeaderChildren.Clear;

  RawContent := '';
  try
    RawContent := DownloadAsString(AUrl);
  except
    on E: Exception do
    begin
      WritelnWarning('Workout', 'Не удалось скачать %s [%s]: %s',
        [AUrl, E.ClassName, E.Message]);
      Exit;
    end;
  end;

  if RawContent = '' then
  begin
    WritelnWarning('Workout', 'Пустой файл: %s', [AUrl]);
    Exit;
  end;

  Doc := nil;
  TryParseXmlString(RawContent, AUrl, 'pass1', Doc);

  if Doc = nil then
  begin
    Sanitized := SanitizeAmpersands(RawContent);
    if Sanitized <> RawContent then
    begin
      WritelnLog('Workout',
        'Файл %s не парсится напрямую — пробую с экранированием амперсандов',
        [AUrl]);
      TryParseXmlString(Sanitized, AUrl, 'pass2', Doc);
    end;
  end;

  if Doc = nil then
  begin
    WritelnWarning('Workout', 'Не удалось распарсить даже после санитайзинга: %s',
      [AUrl]);
    Exit;
  end;

  try
    Root := Doc.DocumentElement;
    if Root = nil then Exit;

    HeadChild := Root.ChildElement('name', False);
    if HeadChild <> nil then
      FName := Trim(String(HeadChild.TextContent));
    HeadChild := Root.ChildElement('description', False);
    if HeadChild <> nil then
      FDescription := Trim(String(HeadChild.TextContent));
    HeadChild := Root.ChildElement('author', False);
    if HeadChild <> nil then
      FAuthor := Trim(String(HeadChild.TextContent));
    HeadChild := Root.ChildElement('sportType', False);
    if HeadChild <> nil then
      FSportType := Trim(String(HeadChild.TextContent));

    { Pass-through дочерних элементов <workout_file>: всё кроме
      name/description/author/sportType/workout. Сюда попадают
      <category>, <subcategory>, <tags>, <entid>, <painIndex>,
      <test_details>, <WorkoutPlan> и прочие.
      На записи они вернутся в файл без изменений. }
    HeaderIter := Root.ChildrenIterator;
    try
      while HeaderIter.GetNext do
      begin
        Child := HeaderIter.Current;
        if not IsKnownHeaderChild(String(Child.TagName)) then
          FRawHeaderChildren.Add(NodeToOuterXml(Child));
      end;
    finally
      HeaderIter.Free;
    end;

    WorkoutNode := Root.ChildElement('workout', False);
    if WorkoutNode = nil then Exit;

    GroupId := 0;
    Iter := WorkoutNode.ChildrenIterator;
    try
      while Iter.GetNext do
      begin
        Child := Iter.Current;
        TagName := LowerCase(String(Child.TagName));

        if TagName = 'warmup' then
          ProcessSimpleSegment(wskWarmup, Child)
        else if TagName = 'cooldown' then
          ProcessSimpleSegment(wskCooldown, Child)
        else if TagName = 'ramp' then
          ProcessSimpleSegment(wskRamp, Child)
        else if TagName = 'steadystate' then
          ProcessSimpleSegment(wskSteady, Child)
        else if TagName = 'intervalst' then
        begin
          Inc(GroupId);
          ProcessIntervalsT(Child, GroupId);
        end
        else if TagName = 'freeride' then
          ProcessSimpleSegment(wskFreeRide, Child)
        else
        begin
          { Совершенно неизвестный сегмент в <workout>. Не теряем —
            добавляем «фантомный» сегмент-нулёвку, который служит
            держателем pass-through, либо просто кладём в
            RawHeaderChildren. Корректнее — последнее, потому что
            «фантом» сломал бы расчёт TotalDuration. }
          FRawHeaderChildren.Add(
            '<!-- segment from <workout>: -->' + NodeToOuterXml(Child));
        end;
      end;
    finally
      Iter.Free;
    end;
  finally
    Doc.Free;
  end;

  Result := FSegments.Count > 0;
  FModified := False;
end;

{ ── Сборка XML-документа для сохранения ───────────────────────────── }

procedure AppendTextChild(Doc: TXMLDocument; Parent: TDOMElement;
  const Tag, Text: String);
var
  El: TDOMElement;
begin
  El := Doc.CreateElement(Tag);
  if Text <> '' then
    El.AppendChild(Doc.CreateTextNode(Text));
  Parent.AppendChild(El);
end;

{ Строит DOM для текущего состояния workout. Сегменты выводятся
  каждый отдельно (без re-rolling в IntervalsT). }
function BuildWorkoutXmlDoc(W: TWorkoutFile): TXMLDocument;
var
  Root, WkNode, El: TDOMElement;
  I: Integer;
  Seg: TWorkoutSegment;

  { Записать атрибут только если значение «задано». Для Cadence
    задано = > 0; 0 = unset. }
  procedure SetIntAttrIfSet(AEl: TDOMElement; const AName: String; AValue: Integer);
  begin
    if AValue > 0 then
      AEl.SetAttribute(AName, IntToStr(AValue));
  end;

  { Дублирует Seg.RawAttrs (key=value) обратно в атрибуты узла. }
  procedure WriteRawAttrs(AEl: TDOMElement; AAttrs: TStringList);
  var
    K: Integer;
    Line: String;
    Eq: Integer;
  begin
    if AAttrs = nil then Exit;
    for K := 0 to AAttrs.Count - 1 do
    begin
      Line := AAttrs[K];
      Eq := Pos('=', Line);
      if Eq <= 0 then Continue;
      AEl.SetAttribute(Copy(Line, 1, Eq - 1), Copy(Line, Eq + 1, MaxInt));
    end;
  end;

  { Дублирует Seg.RawChildren (outer XML каждого узла) обратно как
    дочерние элементы. Парсит каждую строку через AppendOuterXml. }
  procedure WriteRawChildren(ADoc: TXMLDocument; AParent: TDOMElement;
    AChildren: TStringList);
  var
    K: Integer;
  begin
    if AChildren = nil then Exit;
    for K := 0 to AChildren.Count - 1 do
      AppendOuterXml(ADoc, AParent, AChildren[K]);
  end;

  { Записать TextEvents после атрибутов сегмента. Тэг и заглавность
    атрибутов берём из OrigTagName / RawAttrs если они были; иначе
    дефолт «textevent» в нижнем регистре, message и timeoffset. }
  procedure WriteTextEvents(ADoc: TXMLDocument; AParent: TDOMElement;
    AList: TWorkoutTextEventList);
  var
    K: Integer;
    EvEl: TDOMElement;
    Te2: TWorkoutTextEvent;
    TagName: String;
  begin
    if AList = nil then Exit;
    for K := 0 to AList.Count - 1 do
    begin
      Te2 := AList[K];
      if Te2.OrigTagName <> '' then
        TagName := Te2.OrigTagName
      else
        TagName := 'textevent';

      EvEl := ADoc.CreateElement(TagName);
      EvEl.SetAttribute('timeoffset', FormatDurationXml(Te2.TimeOffset));
      if Te2.Duration > 0 then
        EvEl.SetAttribute('duration', FormatDurationXml(Te2.Duration));
      EvEl.SetAttribute('message', Te2.Message);
      WriteRawAttrs(EvEl, Te2.RawAttrs);
      AParent.AppendChild(EvEl);
    end;
  end;

begin
  Result := TXMLDocument.Create;
  Root := Result.CreateElement('workout_file');
  Result.AppendChild(Root);

  AppendTextChild(Result, Root, 'name', W.Name);
  AppendTextChild(Result, Root, 'author', W.Author);
  AppendTextChild(Result, Root, 'description', W.Description);
  if W.SportType <> '' then
    AppendTextChild(Result, Root, 'sportType', W.SportType)
  else
    AppendTextChild(Result, Root, 'sportType', 'bike');

  { Pass-through заголовка: возвращаем все нераспознанные дочерние
    элементы <workout_file> на их место. Сюда попадают <category>,
    <tags>, <entid>, <painIndex>, <test_details> и прочие. Порядок
    может слегка отличаться от исходного — name/author/desc/sport
    идут первыми, всё остальное за ними; для Zwift это не критично. }
  for I := 0 to W.RawHeaderChildren.Count - 1 do
    AppendOuterXml(Result, Root, W.RawHeaderChildren[I]);

  WkNode := Result.CreateElement('workout');
  Root.AppendChild(WkNode);

  for I := 0 to W.Segments.Count - 1 do
  begin
    Seg := W.Segments[I];
    case Seg.Kind of
      wskWarmup:
        begin
          El := Result.CreateElement('Warmup');
          El.SetAttribute('Duration', FormatDurationXml(Seg.Duration));
          El.SetAttribute('PowerLow', FormatPowerXml(Seg.PowerLow));
          El.SetAttribute('PowerHigh', FormatPowerXml(Seg.PowerHigh));
          SetIntAttrIfSet(El, 'CadenceLow', Seg.CadenceLow);
          SetIntAttrIfSet(El, 'CadenceHigh', Seg.CadenceHigh);
          { Если Low/High не заданы (=0), но есть «постоянная» Cadence —
            пишем её. Так старые файлы которые знали только Cadence
            не теряют значение. }
          if (Seg.CadenceLow = 0) and (Seg.CadenceHigh = 0) then
            SetIntAttrIfSet(El, 'Cadence', Seg.Cadence);
          WriteRawAttrs(El, Seg.RawAttrs);
          WriteTextEvents(Result, El, Seg.TextEvents);
          WriteRawChildren(Result, El, Seg.RawChildren);
          WkNode.AppendChild(El);
        end;
      wskCooldown:
        begin
          El := Result.CreateElement('Cooldown');
          El.SetAttribute('Duration', FormatDurationXml(Seg.Duration));
          El.SetAttribute('PowerLow', FormatPowerXml(Seg.PowerLow));
          El.SetAttribute('PowerHigh', FormatPowerXml(Seg.PowerHigh));
          SetIntAttrIfSet(El, 'CadenceLow', Seg.CadenceLow);
          SetIntAttrIfSet(El, 'CadenceHigh', Seg.CadenceHigh);
          if (Seg.CadenceLow = 0) and (Seg.CadenceHigh = 0) then
            SetIntAttrIfSet(El, 'Cadence', Seg.Cadence);
          WriteRawAttrs(El, Seg.RawAttrs);
          WriteTextEvents(Result, El, Seg.TextEvents);
          WriteRawChildren(Result, El, Seg.RawChildren);
          WkNode.AppendChild(El);
        end;
      wskRamp:
        begin
          El := Result.CreateElement('Ramp');
          El.SetAttribute('Duration', FormatDurationXml(Seg.Duration));
          El.SetAttribute('PowerLow', FormatPowerXml(Seg.PowerLow));
          El.SetAttribute('PowerHigh', FormatPowerXml(Seg.PowerHigh));
          SetIntAttrIfSet(El, 'CadenceLow', Seg.CadenceLow);
          SetIntAttrIfSet(El, 'CadenceHigh', Seg.CadenceHigh);
          if (Seg.CadenceLow = 0) and (Seg.CadenceHigh = 0) then
            SetIntAttrIfSet(El, 'Cadence', Seg.Cadence);
          WriteRawAttrs(El, Seg.RawAttrs);
          WriteTextEvents(Result, El, Seg.TextEvents);
          WriteRawChildren(Result, El, Seg.RawChildren);
          WkNode.AppendChild(El);
        end;
      wskFreeRide:
        begin
          El := Result.CreateElement('FreeRide');
          El.SetAttribute('Duration', FormatDurationXml(Seg.Duration));
          SetIntAttrIfSet(El, 'Cadence', Seg.Cadence);
          WriteRawAttrs(El, Seg.RawAttrs);
          WriteTextEvents(Result, El, Seg.TextEvents);
          WriteRawChildren(Result, El, Seg.RawChildren);
          WkNode.AppendChild(El);
        end;
      wskSteady, wskInterval:
        begin
          { v1: и Steady и Interval сериализуем как SteadyState. Это
            теряет «компактность» исходного IntervalsT (если он был),
            но workout играется идентично. Re-rolling в IntervalsT —
            задача для v2. }
          El := Result.CreateElement('SteadyState');
          El.SetAttribute('Duration', FormatDurationXml(Seg.Duration));
          El.SetAttribute('Power', FormatPowerXml(Seg.PowerLow));
          SetIntAttrIfSet(El, 'Cadence', Seg.Cadence);
          SetIntAttrIfSet(El, 'CadenceResting', Seg.CadenceResting);
          WriteRawAttrs(El, Seg.RawAttrs);
          WriteTextEvents(Result, El, Seg.TextEvents);
          WriteRawChildren(Result, El, Seg.RawChildren);
          WkNode.AppendChild(El);
        end;
    end;
  end;
end;

{ ── SaveToUrl ──────────────────────────────────────────────────────── }

function TWorkoutFile.SaveToUrl(const AUrl: String): Boolean;
var
  Doc: TXMLDocument;
  Path: String;
  Stream: TFileStream;
  DirPath: String;
begin
  Result := False;

  if AUrl = '' then
  begin
    WritelnWarning('Workout', 'SaveToUrl: пустой URL');
    Exit;
  end;

  { Поддерживаем только локальные file:/// URL — для других схем
    (castle-data:/, http://) запись недоступна. На Web/Android этот
    путь возвращает пусто или непригодное значение. }
  Path := URIToFilenameSafe(AUrl);
  if Path = '' then
  begin
    WritelnWarning('Workout',
      'SaveToUrl: URL %s не указывает на локальный файл — запись недоступна',
      [AUrl]);
    Exit;
  end;

  { На случай если категория новая — создаём подпапку. }
  DirPath := ExtractFilePath(Path);
  if (DirPath <> '') and (not DirectoryExists(DirPath)) then
  begin
    try
      ForceDirectories(DirPath);
    except
      on E: Exception do
      begin
        WritelnWarning('Workout',
          'SaveToUrl: не удалось создать папку %s [%s]: %s',
          [DirPath, E.ClassName, E.Message]);
        Exit;
      end;
    end;
  end;

  try
    Doc := BuildWorkoutXmlDoc(Self);
    try
      Stream := TFileStream.Create(Path, fmCreate);
      try
        WriteXMLFile(Doc, Stream);
        Result := True;
        FUrl := AUrl;
        FModified := False;
        WritelnLog('Workout', 'Сохранено: %s (%d сегм.)',
          [Path, FSegments.Count]);
      finally
        Stream.Free;
      end;
    finally
      Doc.Free;
    end;
  except
    on E: Exception do
      WritelnWarning('Workout',
        'SaveToUrl ошибка [%s]: %s', [E.ClassName, E.Message]);
  end;
end;

end.
