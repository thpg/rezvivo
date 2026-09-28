{ GameViewWorkoutEditor — экран редактирования тренировки.

  Открывается из списка тренировок (вкладка «Тренировки» главного меню)
  при клике по плашке.
  Предоставляет:
    • поля метаданных (Name, Author, Description)
    • интерактивный chart — клик по сегменту выбирает его
    • property-panel выбранного сегмента (Duration, Power, PowerHigh)
    • кнопки управления выбранным: Move←, Move→, Duplicate, Delete
    • palette-кнопки добавления нового сегмента после выбранного:
      Warmup, Steady, Ramp, FreeRide, Cooldown
    • Save (личная копия) / Save As (новая копия)
    • статистику: Total Duration, TSS, IF
    • Back — сохраняет черновик, Undo отменяет последнее изменение

  Архитектура:
    TWorkoutChart — sub-класс TCastleUserInterface, рисует столбики
      сегментов (как в TWorkoutPreview), плюс поддерживает selection
      и фиксирует клики через OnSegmentClick. Вынесен сюда же —
      нужен только редактору.

    TViewWorkoutEditor — собственно view. Весь UI строится в коде в
      Start, без отдельного .castle-user-interface — так проще менять
      раскладку и не плодить файлы.

  Save поддерживается только для file:/// URL (на Web/Android запись
  через произвольный URL не работает). См. TWorkoutFile.SaveToUrl. }
unit GameViewWorkoutEditor;

{$mode objfpc}{$H+}
{$codepage UTF8}

interface

uses GameMenuTheme,
  Classes, SysUtils,
  CastleUIControls, CastleControls, CastleFonts, CastleVectors, CastleColors,
  CastleRectangles, CastleKeysMouse, CastleGLUtils,
  WorkoutFile,GameUiNavigation;

type
  TWorkoutChartClickEvent = procedure(Sender: TObject;
    SegmentIndex: Integer) of object;

  { Событие drag-изменения сегмента. SegmentIndex — выбранный, NewValue
    интерпретируется по DragMode. Для Warmup/Cooldown/Ramp в режиме
    cdmPower флаг HighSide различает PowerLow (False, левая половина)
    и PowerHigh (True, правая половина). Для остальных типов и для
    cdmDuration HighSide игнорируется. }
  TWorkoutChartDragMode = (
    cdmNone,
    cdmDuration,    { тащим правый край → меняется Duration }
    cdmPower        { тащим верхний край → меняется Power(Low|High) }
  );

  TWorkoutChartDragEvent = procedure(Sender: TObject;
    Mode: TWorkoutChartDragMode;
    NewValue: Single;
    HighSide: Boolean) of object;

  { ── Property-spinner: label + edit + кнопки −/+ ─────────────────────
    Композитный контрол — собирает группу из лейбла, поля ввода
    и двух кнопок-степпера. Всё кладётся в один родитель в нужной
    позиции; внутренние смещения считаются от Left=0.

    Spinner не наследуется от TCastleUserInterface — он не нужен как
    отдельный визуальный узел. Это просто builder, который создаёт
    четыре контрола и сообщает суммарную ширину чтобы caller знал
    где ставить следующий spinner. По сути — фабрика.

    Step хранит шаг инкремента в «логических единицах» того поля
    (для duration это секунды, для power — доли FTP, для repeats —
    штуки). Парсинг текста в число и обратно делает caller через
    OnApplyDelta — чтобы spinner оставался независимым от формата
    конкретного поля. }
  TPropSpinner = class(TComponent)
  public
    LabelCtl: TCastleLabel;
    EditCtl:  TCastleEdit;
    BtnMinus, BtnPlus: TCastleButton;
    Step: Single;
  end;

  { Один ряд редактирования TextEvent. Layout:
       [-][время][+]  [сообщение_long_edit]  [×]
    Все поля — дети одного контейнера (FTeContainer на view), их
    Tag хранит индекс TextEvent в Seg.TextEvents (одинаковый для
    всех контролов одного ряда). View по Tag находит обратно
    модель в обработчиках. }
  TPropTextEventRow = class
    BtnMinus, BtnPlus, BtnDelete: TCastleButton;
    EditTime, EditMessage: TCastleEdit;
  end;

  { ── Интерактивный chart ─────────────────────────────────────────── }

  TWorkoutChart = class(TCastleUserInterface)
  private
    FWorkout: TWorkoutFile;
    FSelectedIndex: Integer;
    FOnSegmentClick: TWorkoutChartClickEvent;
    FOnSegmentDrag:  TWorkoutChartDragEvent;
    FFtpWatts: Integer;
    FMaxPower: Single;

    { Drag state. Захват начинается на Press по правому/верхнему краю
      выбранного сегмента, обновляется в Motion, сбрасывается в Release.
      «Исходные» значения зафиксированы в момент Press — иначе из-за
      округления к 5-секундной/1%-сетке размер бы дрейфовал. }
    FDragMode: TWorkoutChartDragMode;
    FDragSegIndex: Integer;
    FDragStartMouseX: Single;
    FDragStartMouseY: Single;
    FDragStartDuration: Single;
    FDragStartPower: Single;
    FDragChartW: Single;        { запомненная ширина зоны графика для drag }
    FDragMaxBarH: Single;       { запомненная высота для drag }
    { В режиме cdmPower: какое поле редактируем — PowerLow (False)
      или PowerHigh (True). Для Steady/Interval всегда False; для
      Warmup/Cooldown/Ramp выбирается по тому, в левой или правой
      половине сегмента началось перетаскивание. }
    FDragHighSide: Boolean;

    { Hover state — для смены курсора при наведении. Пересчитывается
      в Motion и в Update; сам курсор устанавливается через свойство
      Cursor самого UI-контрола. }
    FHoverEdge: TWorkoutChartDragMode;

    { Индекс выбранного TextEvent-а в выбранном сегменте; -1 = нет. }
    FSelectedTextEvent: Integer;
    FOnTextEventClick: TNotifyEvent;

    function PowerToColor(P: Single): TCastleColor;
    function HitTestX(LocalX, ChartLeft, ChartW: Single): Integer;
    function IsInSelectedGroup(I: Integer): Boolean;

    { Возвращает геометрию сегмента в render-координатах:
      X — левая граница, BarW — ширина, TopY — Y верхней кромки
      (для трапеций — Max(Low,High)). Используется и в Render и
      в hit-test для drag-захвата. False если сегмент невалиден. }
    function GetSegmentGeometry(SegIndex: Integer;
      ChartLeft, ChartW, MaxBarH, ChartBaseY: Single;
      out X, BarW, TopY: Single): Boolean;

    { Геометрия группы сегментов: для члена IntervalsT-группы X и
      Width — границы всей группы суммарно; для одиночного — то же
      что GetSegmentGeometry. CanonicalIdx — индекс «канонического»
      сегмента (FirstIdx группы или сам SegIndex). Используется для
      рисования и hit-test маркеров TextEvents — они логически
      привязаны к каноническому сегменту, но визуально размазаны
      по всему блоку. }
    function GetGroupGeometry(SegIndex: Integer;
      ChartLeft, ChartW: Single;
      out CanonicalIdx: Integer;
      out X, BarW, TotalGroupDur: Single): Boolean;

    { Рендерит индикаторы TextEvents — букву «T» в правом-верхнем
      углу каждого сегмента, у которого есть хотя бы одно сообщение.
      Это чисто визуальная подсказка, не кликабельная. }
    procedure DrawTextEventMarkers(ChartLeft, ChartW, ChartBaseY,
      MaxBarH: Single);
  public
    constructor Create(AOwner: TComponent); override;

    procedure SetWorkout(W: TWorkoutFile);

    procedure Render; override;
    function  Press(const Event: TInputPressRelease): Boolean; override;
    function  Release(const Event: TInputPressRelease): Boolean; override;
    function  Motion(const Event: TInputMotion): Boolean; override;

    property Workout: TWorkoutFile read FWorkout;
    property SelectedIndex: Integer read FSelectedIndex write FSelectedIndex;
    property OnSegmentClick: TWorkoutChartClickEvent
      read FOnSegmentClick write FOnSegmentClick;
    property OnSegmentDrag:  TWorkoutChartDragEvent
      read FOnSegmentDrag  write FOnSegmentDrag;
    property OnTextEventClick: TNotifyEvent
      read FOnTextEventClick write FOnTextEventClick;
    property SelectedTextEvent: Integer
      read FSelectedTextEvent write FSelectedTextEvent;
    property FtpWatts: Integer read FFtpWatts write FFtpWatts;
    property MaxPower: Single  read FMaxPower write FMaxPower;
  end;

  { ── Главный view ────────────────────────────────────────────────── }

  TViewWorkoutEditor = class(TCastleView)
  private
    FKeyboard:TUiKeyboardNavigation;
    FWorkout: TWorkoutFile;
    FOriginalUrl: String;
    FOriginalCategory: String;
    FDraftUrl:String;
    FDraftDelay:Single;
    FDraftPending,FLoadingFields:Boolean;
    FUndoStates:TWorkoutFileList;
    FButtonStart,FButtonUndo:TCastleButton;
    procedure SaveDraft;
    procedure DoStartWorkout(Sender:TObject);
    procedure DoUndo(Sender:TObject);
  private
    { UI — всё строится в BuildUi, поля private }
    FBackground: TCastleRectangleControl;
    FEditorScroll:TCastleScrollView;
    FToolbar,FPalette,FStepActions:TMenuFlow;
    FMoreMetadata:TCastleButton;
    FMetadataExpanded,FLayoutBusy:Boolean;
    FLayoutWidth,FLayoutScale,FLayoutFlowHeight:Single;
    procedure DoMetadata(Sender:TObject);
  private
    FButtonBack, FButtonSave, FButtonSaveAs: TCastleButton;
    FLabelTitle: TCastleLabel;
    FLabelName, FLabelAuthor, FLabelDescription: TCastleLabel;
    FEditName, FEditAuthor, FEditDescription: TCastleEdit;

    FChart: TWorkoutChart;

    FLabelSelected: TCastleLabel;

    { Property panel — спиннеры. Каждый держит label, edit и две
      кнопки −/+. Repeats виден только когда выбран член IntervalsT-
      группы. PowerHigh виден для Warmup/Cooldown/Ramp. Каденция —
      два спиннера: основной всегда виден (если у сегмента вообще
      может быть каденция), второй — только для трапеций (CadenceHigh)
      и для Interval-On (CadenceResting Off-фазы). }
    FSpinDur, FSpinPower, FSpinPowerHigh, FSpinRepeats: TPropSpinner;
    FSpinCadence, FSpinCadenceHigh: TPropSpinner;

    { TextEvent редактор — динамический список под cadence-рядом.
      FTeContainer — пустой контейнер, в который RefreshSelectedPanel
      кладёт по одному TPropTextEventRow на каждый TextEvent
      канонического сегмента. Под контейнером — кнопка Add. }
    FTeContainer:    TCastleUserInterface;
    FTeRowsOwner:TComponent;
    FButtonTeAdd:    TCastleButton;
    FLabelTeHint:    TCastleLabel;     { показывается когда сегмент выбран но событий нет }

    { Кэш «последней раскладки» — чтобы не пересоздавать ряды на
      каждом RefreshSelectedPanel, если состав не поменялся. Иначе
      пользователь теряет фокус в edit-поле каждое его нажатие. }
    FTeRowsForSeg:   Integer;          { индекс сегмента, для которого построены ряды }
    FTeRowsCount:    Integer;          { сколько рядов сейчас в FTeContainer }

    FButtonMoveLeft, FButtonMoveRight: TCastleButton;
    FButtonDuplicate, FButtonDelete: TCastleButton;

    FLabelAdd: TCastleLabel;
    FButtonAddWarmup, FButtonAddSteady, FButtonAddRamp: TCastleButton;
    FButtonAddFreeRide, FButtonAddCooldown: TCastleButton;

    FLabelStats: TCastleLabel;

    procedure BuildUi;
    procedure LoadFromWorkout;
    procedure RefreshTitle;
    procedure RefreshChart;
    procedure RefreshSelectedPanel;
    procedure RefreshStats;

    procedure DoBack(Sender: TObject);
    procedure DoSave(Sender: TObject);
    procedure DoSaveAs(Sender: TObject);
    procedure DoChartSegmentClick(Sender: TObject; SegmentIndex: Integer);
    procedure DoChartSegmentDrag(Sender: TObject;
      Mode: TWorkoutChartDragMode; NewValue: Single; HighSide: Boolean);
    procedure DoNameChanged(Sender: TObject);
    procedure DoAuthorChanged(Sender: TObject);
    procedure DoDescriptionChanged(Sender: TObject);
    procedure DoEditDurChanged(Sender: TObject);
    procedure DoEditPowerChanged(Sender: TObject);
    procedure DoEditPowerHighChanged(Sender: TObject);
    procedure DoEditRepeatsChanged(Sender: TObject);
    procedure DoEditCadenceChanged(Sender: TObject);
    procedure DoEditCadenceHighChanged(Sender: TObject);

    { Степперы −/+. Tag кнопки = 0 для −, 1 для +. Поле определяется
      по тому, какая именно кнопка отправитель — у каждого spinner
      кнопки сохраняют ссылку обратно через одну из них. Проще:
      разные обработчики для каждого поля. }
    procedure DoStepDur(Sender: TObject);
    procedure DoStepPower(Sender: TObject);
    procedure DoStepPowerHigh(Sender: TObject);
    procedure DoStepRepeats(Sender: TObject);
    procedure DoStepCadence(Sender: TObject);
    procedure DoStepCadenceHigh(Sender: TObject);

    { TextEvent handlers. }
    procedure DoChartTextEventClick(Sender: TObject);
    procedure DoTeTimeChanged(Sender: TObject);
    procedure DoTeStepTime(Sender: TObject);
    procedure DoTeMessageChanged(Sender: TObject);
    procedure DoTeAddClick(Sender: TObject);
    procedure DoTeDeleteClick(Sender: TObject);

    { Доступ к TextEvent через Tag отправителя обработчика. Все
      контролы одного ряда имеют одинаковый Tag = индекс TextEvent
      в списке канонического сегмента. }
    function GetTextEventByTag(Sender: TObject;
      out CanonSegIdx, TeIdx: Integer): TWorkoutTextEvent;

    { Полная пересборка рядов в FTeContainer под выбранный сегмент.
      Зовётся когда состав изменился (Add/Delete/смена сегмента),
      НЕ зовётся при правке отдельных полей — иначе фокус edit-а
      пропадал бы каждое нажатие. }
    procedure RebuildTeRows(CanonSegIdx: Integer);

    { Точечное обновление времени в готовом ряду (без пересборки).
      Используется кнопками −/+ — они меняют значение в модели и
      должны отразить его в edit-поле, но фокус остаётся на кнопке. }
    procedure RefreshSingleTeRowTime(TeIdx: Integer; NewTime: Single);

    procedure DoMoveLeft(Sender: TObject);
    procedure DoMoveRight(Sender: TObject);
    procedure DoDuplicate(Sender: TObject);
    procedure DoDelete(Sender: TObject);
    procedure DoAddSegment(Sender: TObject);

    function CanEditPowerHigh: Boolean;
    function ParseDuration(const S: String): Single;
    function ParsePower(const S: String): Single;
    function FormatDur(D: Single): String;
    function FormatPwr(P: Single): String;

    function GenerateSaveAsUrl: String;
  public
    constructor Create(AOwner: TComponent); override;
    procedure Start; override;
    function PreviewPress(const Event:TInputPressRelease):Boolean;override;
    procedure RenderOverChildren;override;
    function Press(const Event:TInputPressRelease):Boolean; override;
    destructor Destroy; override;
    procedure Stop; override;
    procedure Update(const SecondsPassed:Single;var HandleInput:Boolean);override;
    procedure Resize; override;

    { Точка входа из списка тренировок. Вызывается до Container.View := …
      чтобы Start уже знал, что отображать. }
    procedure SetWorkout(W: TWorkoutFile);
  end;

var
  ViewWorkoutEditor: TViewWorkoutEditor;

implementation

uses GameUserData, md5, UiTranslations,
  Math, StrUtils,
  CastleLog, CastleUriUtils,CastleApplicationProperties,
  WorkoutLibrary, GameViewMenu, GameLocalization;

const
  CHART_PAD       = 8;
  CHART_MIN_BAR_W = 0.5;
  CHART_GRID_ALPHA = 0.18;

  { Тёмная подложка, повторяющая контур столбца но шире/выше на
    EDGE_INSET — даёт эффект «обводки тенью». На узких сегментах
    (короткие интервалы IntervalsT) подложка съела бы основной цвет,
    поэтому для столбцов с шириной меньше MIN_INSET_WIDTH inset=0
    и подложка не рисуется. Те же значения что в TWorkoutPreview —
    чарт редактора и превью-плашек выглядят согласованно. }
  EDGE_INSET      = 1.0;
  MIN_INSET_WIDTH = 4.0;

  { Размеры компонентов спиннера. Layout строится по двум строкам:
      [ Label                  ]   ← LABEL_ROW_Y
      [ − ][  Edit  ][ + ]         ← FIELD_ROW_Y (= LABEL_ROW_Y - LABEL_H)

    Все три контрола в нижней строке имеют одинаковую ширину
    (BTN_W = EDIT_W) — иначе кнопки выглядят сжатыми относительно
    edit-ов. Зазоры между ними нулевые: − плотно прилегает к edit
    слева, + к edit справа. }
  SPIN_LABEL_H     = 22;
  SPIN_GAP         = 0;     { зазор между −, edit, + (0 = впритык) }

  { Y-координаты разделов экрана.

    Метаданные:
      MetaTopY  -90  Название / Автор
      MetaTopY-60 = -150  Описание (edit ~30px → низ -180)

    НАД чартом, ОДИН РЯД:
      ABOVE_CHART_Y -220  [Total: ... TSS: ... IF: ...]  [Добавить: chips...]
      ChartTopY     -270  (зазор 50 px — кнопки палитры доходят до ~-250)

    ПОД чартом (низ чарта = -270 - 260 = -530):
      PROP_HEADER_Y  -545  Выбрано: …
      PROP_FIELDS_Y  -575  Длит/Power/PwrHigh/Повторов/Кад. работы/Кад. отдыха
      TEXT_EVENT_Y   -650  + Текст. сообщение / hint / ряды событий }
  ABOVE_CHART_Y  = -220;
  PROP_HEADER_Y  = -545;
  PROP_FIELDS_Y  = -575;
  TEXT_EVENT_Y   = -650;

  { Размеры одного TextEvent-ряда — нужны и в RebuildTeRows и в
    RefreshSelectedPanel (та считает где разместить «+ Добавить»
    под списком). }
  TE_ROW_H   = 30;
  TE_ROW_GAP = 6;

  { Цвета зон — те же что у TWorkoutPreview, чтобы редактор и список
    выглядели согласованно. }

{ ── TWorkoutChart ──────────────────────────────────────────────────── }

constructor TWorkoutChart.Create(AOwner: TComponent);
begin
  inherited;
  FSelectedIndex := -1;
  FFtpWatts := 250;
  FMaxPower := 1.5;
  Width := 600;
  Height := 220;
  FDragMode := cdmNone;
  FDragSegIndex := -1;
  FHoverEdge := cdmNone;
  FSelectedTextEvent := -1;
end;

procedure TWorkoutChart.SetWorkout(W: TWorkoutFile);
begin
  FWorkout := W;
  FDragMode := cdmNone;
  FDragSegIndex := -1;
  FSelectedTextEvent := -1;
  if W = nil then
    FSelectedIndex := -1
  else if FSelectedIndex >= W.Segments.Count then
    FSelectedIndex := W.Segments.Count - 1;
  VisibleChange([chRender]);
end;

function TWorkoutChart.PowerToColor(P: Single): TCastleColor;
begin
  if P < 0.001 then
    Result := Vector4(0.45, 0.45, 0.50, 1.0)
  else if P < 0.55 then
    Result := Vector4(0.45, 0.50, 0.55, 1.0)
  else if P < 0.75 then
    Result := Vector4(0.20, 0.45, 0.85, 1.0)
  else if P < 0.90 then
    Result := Vector4(0.30, 0.70, 0.95, 1.0)
  else if P < 1.05 then
    Result := Vector4(0.30, 0.78, 0.40, 1.0)
  else if P < 1.20 then
    Result := Vector4(0.95, 0.60, 0.25, 1.0)
  else
    Result := Vector4(0.90, 0.30, 0.30, 1.0);
end;

function TWorkoutChart.HitTestX(LocalX, ChartLeft, ChartW: Single): Integer;
var
  I: Integer;
  AccumX, BarW, TotalDur: Single;
begin
  Result := -1;
  if not Assigned(FWorkout) then Exit;
  if FWorkout.Segments.Count = 0 then Exit;
  TotalDur := FWorkout.TotalDuration;
  if TotalDur <= 0 then Exit;

  AccumX := ChartLeft;
  for I := 0 to FWorkout.Segments.Count - 1 do
  begin
    BarW := (FWorkout.Segments[I].Duration / TotalDur) * ChartW;
    if BarW < CHART_MIN_BAR_W then BarW := CHART_MIN_BAR_W;
    if (LocalX >= AccumX) and (LocalX < AccumX + BarW) then
      Exit(I);
    AccumX := AccumX + BarW;
  end;
end;

{ True если сегмент в той же IntervalsT-группе что и выбранный.
  «Группа» определяется по совпадению RepeatGroup>0 — непрерывность
  здесь не проверяется, потому что для подсветки достаточно
  логической принадлежности. Сам выбранный сегмент возвращает True
  тоже, поэтому caller должен сначала проверять I=FSelectedIndex
  если ему нужна разная отрисовка. }
function TWorkoutChart.IsInSelectedGroup(I: Integer): Boolean;
var
  SelGroup: Integer;
begin
  Result := False;
  if not Assigned(FWorkout) then Exit;
  if (FSelectedIndex < 0) or (FSelectedIndex >= FWorkout.Segments.Count) then Exit;
  if (I < 0) or (I >= FWorkout.Segments.Count) then Exit;
  SelGroup := FWorkout.Segments[FSelectedIndex].RepeatGroup;
  if SelGroup <= 0 then Exit;
  Result := FWorkout.Segments[I].RepeatGroup = SelGroup;
end;

{ Геометрия сегмента в render-координатах. Считает то же что цикл
  отрисовки, но один сегмент — нужно в Press и Motion для hit-test
  drag-захвата без копипасты всего render-цикла. }
function TWorkoutChart.GetSegmentGeometry(SegIndex: Integer;
  ChartLeft, ChartW, MaxBarH, ChartBaseY: Single;
  out X, BarW, TopY: Single): Boolean;
var
  I: Integer;
  Seg: TWorkoutSegment;
  TotalDur, AccumX, ThisBarW, Y1, Y2, Norm: Single;

  function PowerToY(Power: Single): Single;
  begin
    Norm := Power / FMaxPower;
    if Norm < 0 then Norm := 0;
    if Norm > 1 then Norm := 1;
    Result := Norm * MaxBarH;
  end;

begin
  Result := False;
  X := 0; BarW := 0; TopY := 0;
  if not Assigned(FWorkout) then Exit;
  if (SegIndex < 0) or (SegIndex >= FWorkout.Segments.Count) then Exit;
  TotalDur := FWorkout.TotalDuration;
  if TotalDur <= 0 then Exit;

  AccumX := ChartLeft;
  for I := 0 to SegIndex - 1 do
  begin
    ThisBarW := (FWorkout.Segments[I].Duration / TotalDur) * ChartW;
    if ThisBarW < CHART_MIN_BAR_W then ThisBarW := CHART_MIN_BAR_W;
    AccumX := AccumX + ThisBarW;
  end;

  Seg := FWorkout.Segments[SegIndex];
  BarW := (Seg.Duration / TotalDur) * ChartW;
  if BarW < CHART_MIN_BAR_W then BarW := CHART_MIN_BAR_W;
  X := AccumX;

  case Seg.Kind of
    wskWarmup, wskCooldown, wskRamp:
      begin
        Y1 := PowerToY(Seg.PowerLow);
        Y2 := PowerToY(Seg.PowerHigh);
        if Y1 > Y2 then TopY := ChartBaseY + Y1
                   else TopY := ChartBaseY + Y2;
      end;
    wskFreeRide:
      TopY := ChartBaseY + PowerToY(0.65);
  else
    TopY := ChartBaseY + PowerToY(Seg.PowerLow);
  end;

  Result := True;
end;

function TWorkoutChart.GetGroupGeometry(SegIndex: Integer;
  ChartLeft, ChartW: Single;
  out CanonicalIdx: Integer;
  out X, BarW, TotalGroupDur: Single): Boolean;
var
  TotalDur, AccumX, ThisBarW: Single;
  I, FirstIdx, LastIdx: Integer;
begin
  Result := False;
  CanonicalIdx := -1; X := 0; BarW := 0; TotalGroupDur := 0;
  if not Assigned(FWorkout) then Exit;
  if (SegIndex < 0) or (SegIndex >= FWorkout.Segments.Count) then Exit;

  TotalDur := FWorkout.TotalDuration;
  if TotalDur <= 0 then Exit;

  { Определяем границы группы. Если сегмент не в группе — берём
    его одного. }
  if not FWorkout.GroupRange(SegIndex, FirstIdx, LastIdx) then
  begin
    FirstIdx := SegIndex;
    LastIdx := SegIndex;
  end;
  CanonicalIdx := FirstIdx;

  { Считаем X начала первого сегмента группы. }
  AccumX := ChartLeft;
  for I := 0 to FirstIdx - 1 do
  begin
    ThisBarW := (FWorkout.Segments[I].Duration / TotalDur) * ChartW;
    if ThisBarW < CHART_MIN_BAR_W then ThisBarW := CHART_MIN_BAR_W;
    AccumX := AccumX + ThisBarW;
  end;
  X := AccumX;

  { Суммарная длительность и ширина группы. }
  TotalGroupDur := 0;
  BarW := 0;
  for I := FirstIdx to LastIdx do
  begin
    TotalGroupDur := TotalGroupDur + FWorkout.Segments[I].Duration;
    ThisBarW := (FWorkout.Segments[I].Duration / TotalDur) * ChartW;
    if ThisBarW < CHART_MIN_BAR_W then ThisBarW := CHART_MIN_BAR_W;
    BarW := BarW + ThisBarW;
  end;

  Result := TotalGroupDur > 0;
end;

procedure TWorkoutChart.DrawTextEventMarkers(ChartLeft, ChartW,
  ChartBaseY, MaxBarH: Single);
const
  PAD_TOP = 4;       { отступ буквы вниз от верхней кромки столбца }
var
  TotalDur, AccumX, BarW, X, SegTop: Single;
  I, K, CanonicalIdx: Integer;
  Seg, CanonSeg: TWorkoutSegment;
  Te: TWorkoutTextEvent;
  TextX, TextY, TextW, TextH: Single;
  Font: TCastleAbstractFont;
  GroupX, GroupW, GroupDur: Single;

  function PowerToY(Power: Single): Single;
  var Norm: Single;
  begin
    Norm := Power / FMaxPower;
    if Norm < 0 then Norm := 0;
    if Norm > 1 then Norm := 1;
    Result := Norm * MaxBarH;
  end;

  function SegTopForDraw(ASeg: TWorkoutSegment): Single;
  begin
    case ASeg.Kind of
      wskWarmup, wskCooldown, wskRamp:
        Result := PowerToY(Max(ASeg.PowerLow, ASeg.PowerHigh));
      wskFreeRide:
        Result := PowerToY(0.65);
    else
      Result := PowerToY(ASeg.PowerLow);
    end;
  end;

begin
  if not Assigned(FWorkout) then Exit;
  TotalDur := FWorkout.TotalDuration;
  if TotalDur <= 0 then Exit;

  Font := UIFont;
  if Font = nil then Exit;

  TextW := Font.TextWidth('T');
  TextH := Font.TextHeight('T');

  AccumX := ChartLeft;
  for I := 0 to FWorkout.Segments.Count - 1 do
  begin
    Seg := FWorkout.Segments[I];
    BarW := (Seg.Duration / TotalDur) * ChartW;
    if BarW < CHART_MIN_BAR_W then BarW := CHART_MIN_BAR_W;
    X := AccumX;
    AccumX := AccumX + BarW;

    { TextEvents хранятся на каноническом сегменте; для членов
      IntervalsT-группы — на FirstIdx, для одиночных — на самом
      сегменте. Букв мы рисуем на канонической позиции, т. к.
      timeoffset считается от начала группы (или от начала
      одиночного сегмента). }
    CanonicalIdx := FWorkout.CanonicalSegmentIndex(I);
    if (CanonicalIdx < 0) or (CanonicalIdx >= FWorkout.Segments.Count) then
      Continue;
    if I <> CanonicalIdx then Continue;     { рисуем только когда добрались до канонической позиции }

    CanonSeg := FWorkout.Segments[CanonicalIdx];
    if CanonSeg.TextEvents.Count = 0 then Continue;

    { Геометрия группы: для члена IntervalsT-группы это X+W всей
      группы суммарно, GroupDur — суммарная длительность группы.
      Для одиночного — то же что у самого сегмента. Используем
      готовый GetGroupGeometry который умеет оба случая. }
    if not GetGroupGeometry(I, ChartLeft, ChartW,
      CanonicalIdx, GroupX, GroupW, GroupDur) then Continue;
    if GroupDur <= 0 then Continue;

    SegTop := SegTopForDraw(Seg);

    { Y буквы общая для всех маркеров этого сегмента — у верхнего
      края столбца. Если столбец очень низкий (PowerLow ≈ 0) —
      буква уехала бы под базу; в этом случае пропускаем. }
    TextY := ChartBaseY + SegTop - PAD_TOP - TextH;
    if TextY < ChartBaseY then Continue;

    for K := 0 to CanonSeg.TextEvents.Count - 1 do
    begin
      Te := CanonSeg.TextEvents[K];

      { X буквы по timeoffset от начала группы. Центрируем букву
        на маркерной точке (вычитаем половину ширины). Клампим
        к границам группы — если timeoffset вышел за конец
        длительности (бывает в кривых файлах), кладём на правый
        край. }
      TextX := GroupX + (Te.TimeOffset / GroupDur) * GroupW - TextW * 0.5;
      if TextX < GroupX then TextX := GroupX;
      if TextX > GroupX + GroupW - TextW then
        TextX := GroupX + GroupW - TextW;

      { Тень + основной цвет, как раньше. }
      Font.Print(TextX + 1, TextY - 1, Vector4(0, 0, 0, 0.85), 'T');
      Font.Print(TextX, TextY, Vector4(1.0, 0.55, 0.10, 1.0), 'T');
    end;
  end;
end;

function TWorkoutChart.Press(const Event: TInputPressRelease): Boolean;
const
  EDGE_HIT_PX = 8;     { дальность hit-зоны от края/вершины }
var
  R: TFloatRectangle;
  ChartLeft, ChartW, MaxBarH, ChartBaseY: Single;
  LocalX: Single;
  Idx: Integer;
  SegX, SegW, SegTopY: Single;
  Seg: TWorkoutSegment;
  PX, PY: Single;
  IsTrapezoid: Boolean;
  EdgePower: Single;
  HitDuration, HitPower: Boolean;
  YHigh, YLow: Single;
begin
  Result := inherited;
  if Result then Exit;
  if not Event.IsMouseButton(buttonLeft) then Exit;
  if not Assigned(FWorkout) then Exit;

  R := RenderRect;
  if not R.Contains(Event.Position) then Exit;
  ChartLeft := R.Left + CHART_PAD;
  ChartW := R.Width - 2 * CHART_PAD;
  MaxBarH := R.Height - 2 * CHART_PAD;
  ChartBaseY := R.Bottom + CHART_PAD;

  PX := Event.Position.X;
  PY := Event.Position.Y;
  LocalX := PX - R.Left;

  { Drag-захват у правого края или верхней кромки выбранного сегмента.
    Координаты CGE-UI: Y растёт ВВЕРХ (R.Bottom — низ окна, R.Top —
    верх). База графика ChartBaseY = R.Bottom + Pad, верх столбца
    SegTopY = ChartBaseY + PowerToY(...). Для столбца с PowerLow > 0:
        ChartBaseY <= PY <= SegTopY  ⇔ внутри столбца. }
  if (FSelectedIndex >= 0) and
     (FSelectedIndex < FWorkout.Segments.Count) and
     GetSegmentGeometry(FSelectedIndex, ChartLeft, ChartW, MaxBarH,
       ChartBaseY, SegX, SegW, SegTopY) then
  begin
    Seg := FWorkout.Segments[FSelectedIndex];
    IsTrapezoid := Seg.Kind in [wskWarmup, wskCooldown, wskRamp];

    { 1) Правый край — изменение длительности. Hit-зона: вертикальная
         полоска ±EDGE_HIT_PX вокруг X = SegX+SegW, по Y от ChartBaseY
         до SegTopY+EDGE_HIT_PX (немного выше верха, чтобы попасть
         было удобнее). }
    HitDuration :=
      (PX >= SegX + SegW - EDGE_HIT_PX) and
      (PX <= SegX + SegW + EDGE_HIT_PX) and
      (PY >= ChartBaseY - EDGE_HIT_PX) and
      (PY <= SegTopY + EDGE_HIT_PX);

    { 2) Верхняя кромка — изменение мощности. Для Steady/Interval это
         просто горизонтальная полоска вокруг SegTopY на всю ширину
         столбца. Для трапеций — две полосы:
            левая половина  → у SegBaseY+PowerToY(PowerLow)
            правая половина → у SegBaseY+PowerToY(PowerHigh)
         FDragHighSide различит, что мы редактируем. }
    HitPower := False;
    EdgePower := 0;
    FDragHighSide := False;

    if (PX >= SegX) and (PX <= SegX + SegW) then
    begin
      if IsTrapezoid then
      begin
        { Считаем Y кромок Low и High. }
        YLow  := ChartBaseY + (Seg.PowerLow  / FMaxPower) * MaxBarH;
        YHigh := ChartBaseY + (Seg.PowerHigh / FMaxPower) * MaxBarH;
        if YLow  > ChartBaseY + MaxBarH then YLow  := ChartBaseY + MaxBarH;
        if YHigh > ChartBaseY + MaxBarH then YHigh := ChartBaseY + MaxBarH;

        { Левая половина — кромка PowerLow. }
        if (PX <= SegX + SegW * 0.5) and
           (PY >= YLow - EDGE_HIT_PX) and
           (PY <= YLow + EDGE_HIT_PX) then
        begin
          HitPower := True;
          EdgePower := Seg.PowerLow;
          FDragHighSide := False;
        end
        { Правая половина — кромка PowerHigh. }
        else if (PX > SegX + SegW * 0.5) and
                (PY >= YHigh - EDGE_HIT_PX) and
                (PY <= YHigh + EDGE_HIT_PX) then
        begin
          HitPower := True;
          EdgePower := Seg.PowerHigh;
          FDragHighSide := True;
        end;
      end
      else if Seg.Kind in [wskSteady, wskInterval] then
      begin
        { Простая горизонтальная полоска. }
        if (PY >= SegTopY - EDGE_HIT_PX) and
           (PY <= SegTopY + EDGE_HIT_PX) then
        begin
          HitPower := True;
          EdgePower := Seg.PowerLow;
          FDragHighSide := False;
        end;
      end;
      { FreeRide — без power-drag (нет осмысленного значения). }
    end;

    { Приоритет: правый край (Duration) важнее, чем угловая зона
      пересечения с верхней кромкой. Иначе на узких столбцах
      пользователь почти всегда попадал бы в Power вместо Duration. }
    if HitDuration then
    begin
      FDragMode := cdmDuration;
      FDragSegIndex := FSelectedIndex;
      FDragStartMouseX := PX;
      FDragStartMouseY := PY;
      FDragStartDuration := Seg.Duration;
      FDragStartPower := Seg.PowerLow;
      FDragChartW := ChartW;
      FDragMaxBarH := MaxBarH;
      Exit(True);
    end;
    if HitPower then
    begin
      FDragMode := cdmPower;
      FDragSegIndex := FSelectedIndex;
      FDragStartMouseX := PX;
      FDragStartMouseY := PY;
      FDragStartDuration := Seg.Duration;
      FDragStartPower := EdgePower;
      FDragChartW := ChartW;
      FDragMaxBarH := MaxBarH;
      Exit(True);
    end;
  end;

  { Не drag — обычная смена выделения по hit-test тела сегмента. }
  Idx := HitTestX(LocalX, CHART_PAD, ChartW);
  if Idx >= 0 then
  begin
    if Idx <> FSelectedIndex then
      FSelectedTextEvent := -1;  { новая «канонка» — старый te-index невалиден }
    FSelectedIndex := Idx;
    VisibleChange([chRender]);
    if Assigned(FOnSegmentClick) then
      FOnSegmentClick(Self, Idx);
    Exit(True);
  end;
end;

function TWorkoutChart.Release(const Event: TInputPressRelease): Boolean;
begin
  Result := inherited;
  if FDragMode <> cdmNone then
  begin
    FDragMode := cdmNone;
    FDragSegIndex := -1;
    Result := True;
  end;
end;

function TWorkoutChart.Motion(const Event: TInputMotion): Boolean;
const
  SNAP_DURATION = 5;       { секунд }
  SNAP_POWER    = 0.01;    { 1% FTP }
  MIN_DURATION  = 1;
  MAX_POWER     = 5.0;     { 500% FTP — sanity cap }
  EDGE_HIT_PX   = 8;
var
  TotalDurOther: Single;
  I: Integer;
  DeltaX, DeltaY, NewVal, CurPower: Single;
  Seg: TWorkoutSegment;

  { Hover-логика: при наведении на drag-зону выбранного сегмента —
    меняем курсор. Точно те же hit-зоны что в Press. }
  procedure UpdateHoverCursor;
  var
    R: TFloatRectangle;
    ChartLeft, ChartW, MaxBarH, ChartBaseY: Single;
    SegX, SegW, SegTopY: Single;
    HoverSeg: TWorkoutSegment;
    PX, PY, YLow, YHigh: Single;
    NewEdge: TWorkoutChartDragMode;
  begin
    NewEdge := cdmNone;

    if not Assigned(FWorkout) or
       (FSelectedIndex < 0) or
       (FSelectedIndex >= FWorkout.Segments.Count) then
    begin
      if FHoverEdge <> NewEdge then
      begin
        FHoverEdge := NewEdge;
        Cursor := mcDefault;
      end;
      Exit;
    end;

    R := RenderRect;
    if not R.Contains(Event.Position) then
    begin
      if FHoverEdge <> NewEdge then
      begin
        FHoverEdge := NewEdge;
        Cursor := mcDefault;
      end;
      Exit;
    end;

    ChartLeft := R.Left + CHART_PAD;
    ChartW := R.Width - 2 * CHART_PAD;
    MaxBarH := R.Height - 2 * CHART_PAD;
    ChartBaseY := R.Bottom + CHART_PAD;
    PX := Event.Position.X;
    PY := Event.Position.Y;

    if not GetSegmentGeometry(FSelectedIndex, ChartLeft, ChartW, MaxBarH,
       ChartBaseY, SegX, SegW, SegTopY) then
    begin
      if FHoverEdge <> NewEdge then
      begin
        FHoverEdge := NewEdge;
        Cursor := mcDefault;
      end;
      Exit;
    end;

    HoverSeg := FWorkout.Segments[FSelectedIndex];

    { Правый край → горизонтальный resize. }
    if (PX >= SegX + SegW - EDGE_HIT_PX) and
       (PX <= SegX + SegW + EDGE_HIT_PX) and
       (PY >= ChartBaseY - EDGE_HIT_PX) and
       (PY <= SegTopY + EDGE_HIT_PX) then
      NewEdge := cdmDuration
    { Верхняя кромка → вертикальный resize. Для трапеций — две
      разные кромки в зависимости от X. }
    else if (PX >= SegX) and (PX <= SegX + SegW) then
    begin
      if HoverSeg.Kind in [wskWarmup, wskCooldown, wskRamp] then
      begin
        YLow  := ChartBaseY + (HoverSeg.PowerLow  / FMaxPower) * MaxBarH;
        YHigh := ChartBaseY + (HoverSeg.PowerHigh / FMaxPower) * MaxBarH;
        if YLow  > ChartBaseY + MaxBarH then YLow  := ChartBaseY + MaxBarH;
        if YHigh > ChartBaseY + MaxBarH then YHigh := ChartBaseY + MaxBarH;

        if (PX <= SegX + SegW * 0.5) and
           (PY >= YLow - EDGE_HIT_PX) and (PY <= YLow + EDGE_HIT_PX) then
          NewEdge := cdmPower
        else if (PX > SegX + SegW * 0.5) and
                (PY >= YHigh - EDGE_HIT_PX) and (PY <= YHigh + EDGE_HIT_PX) then
          NewEdge := cdmPower;
      end
      else if HoverSeg.Kind in [wskSteady, wskInterval] then
      begin
        if (PY >= SegTopY - EDGE_HIT_PX) and (PY <= SegTopY + EDGE_HIT_PX) then
          NewEdge := cdmPower;
      end;
    end;

    if NewEdge <> FHoverEdge then
    begin
      FHoverEdge := NewEdge;
      case NewEdge of
        cdmDuration: Cursor := mcResizeHorizontal;
        cdmPower:    Cursor := mcResizeVertical;
      else
        Cursor := mcDefault;
      end;
    end;
  end;

begin
  Result := inherited;

  { Hover-курсор пересчитываем всегда (даже во время drag — там он
    останется зафиксированным режимом drag-а через FHoverEdge,
    но так проще). }
  UpdateHoverCursor;

  if FDragMode = cdmNone then Exit;
  if not Assigned(FWorkout) then Exit;
  if (FDragSegIndex < 0) or (FDragSegIndex >= FWorkout.Segments.Count) then
  begin
    FDragMode := cdmNone;
    Exit;
  end;

  case FDragMode of
    cdmDuration:
      begin
        TotalDurOther := 0;
        for I := 0 to FWorkout.Segments.Count - 1 do
          if I <> FDragSegIndex then
            TotalDurOther := TotalDurOther + FWorkout.Segments[I].Duration;

        DeltaX := Event.Position.X - FDragStartMouseX;
        NewVal := FDragStartDuration +
          DeltaX * ((TotalDurOther + FDragStartDuration) / FDragChartW);

        NewVal := Round(NewVal / SNAP_DURATION) * SNAP_DURATION;
        if NewVal < MIN_DURATION then NewVal := MIN_DURATION;

        if not SameValue(NewVal, FWorkout.Segments[FDragSegIndex].Duration) then
        begin
          if Assigned(FOnSegmentDrag) then
            FOnSegmentDrag(Self, cdmDuration, NewVal, False);
          VisibleChange([chRender]);
        end;
        Result := True;
      end;

    cdmPower:
      begin
        { В UI-координатах CGE Y растёт ВВЕРХ. Курсор тащится вверх →
          Event.Position.Y увеличивается → DeltaY положительна →
          Power растёт. }
        DeltaY := Event.Position.Y - FDragStartMouseY;
        NewVal := FDragStartPower + (DeltaY / FDragMaxBarH) * FMaxPower;

        NewVal := Round(NewVal / SNAP_POWER) * SNAP_POWER;
        if NewVal < 0 then NewVal := 0;
        if NewVal > MAX_POWER then NewVal := MAX_POWER;

        Seg := FWorkout.Segments[FDragSegIndex];
        if FDragHighSide then
          CurPower := Seg.PowerHigh
        else
          CurPower := Seg.PowerLow;

        if not SameValue(NewVal, CurPower) then
        begin
          if Assigned(FOnSegmentDrag) then
            FOnSegmentDrag(Self, cdmPower, NewVal, FDragHighSide);
          VisibleChange([chRender]);
        end;
        Result := True;
      end;
  end;
end;

procedure TWorkoutChart.Render;
var
  R: TFloatRectangle;
  TotalDur, ChartW, MaxBarH, BarW, X, AccumX, ChartBaseY: Single;
  I: Integer;
  Seg: TWorkoutSegment;
  Col, ShadowCol, GridCol: TCastleColor;
  Y0, Y1, Y2: Single;
  IsSelected: Boolean;
  Inset: Single;
  GridLevels: array[0..4] of Single;
  GL, YGrid: Single;
  K: Integer;

  function PowerToY(Power: Single): Single;
  var Norm: Single;
  begin
    Norm := Power / FMaxPower;
    if Norm < 0 then Norm := 0;
    if Norm > 1 then Norm := 1;
    Result := Norm * MaxBarH;
  end;

  { Высота фигуры этого сегмента (для расположения обводок поверх).
    Для трапеций возвращает максимум из PowerLow/PowerHigh, так что
    обводка по верхнему краю всегда лежит на самой высокой точке. }
  function SegTopY(ASeg: TWorkoutSegment): Single;
  begin
    case ASeg.Kind of
      wskWarmup, wskCooldown, wskRamp:
        Result := PowerToY(Max(ASeg.PowerLow, ASeg.PowerHigh));
      wskFreeRide:
        Result := PowerToY(0.65);
    else
      Result := PowerToY(ASeg.PowerLow);
    end;
  end;

begin
  inherited;

  R := RenderRect;
  ChartW := R.Width - 2 * CHART_PAD;
  MaxBarH := R.Height - 2 * CHART_PAD;
  if (ChartW <= 0) or (MaxBarH <= 0) then Exit;

  ChartBaseY := R.Bottom + CHART_PAD;

  { Тёмный фон chart-а — отделяет его от родительского цвета окна. }
  DrawRectangle(R, Vector4(0, 0, 0, 0.30));

  { Сетка по 25/50/75/100/125 % FTP }
  GridLevels[0] := 0.25;
  GridLevels[1] := 0.50;
  GridLevels[2] := 0.75;
  GridLevels[3] := 1.00;
  GridLevels[4] := 1.25;
  GridCol := Vector4(1, 1, 1, CHART_GRID_ALPHA);
  for K := 0 to High(GridLevels) do
  begin
    GL := GridLevels[K];
    YGrid := ChartBaseY + PowerToY(GL);
    if (YGrid > ChartBaseY) and (YGrid < ChartBaseY + MaxBarH) then
      DrawRectangle(FloatRectangle(R.Left + CHART_PAD, YGrid,
        ChartW, 1), GridCol);
  end;

  if (not Assigned(FWorkout)) or (FWorkout.Segments.Count = 0) then Exit;

  TotalDur := FWorkout.TotalDuration;
  if TotalDur <= 0 then Exit;

  { Тень — тёмный полупрозрачный контур-подложка. Тот же оттенок
    что в TWorkoutPreview (alpha 0.55), чтобы виджеты выглядели
    согласованно. }
  ShadowCol := Vector4(0, 0, 0, 0.55);

  AccumX := 0;
  for I := 0 to FWorkout.Segments.Count - 1 do
  begin
    Seg := FWorkout.Segments[I];
    BarW := (Seg.Duration / TotalDur) * ChartW;
    if BarW < CHART_MIN_BAR_W then BarW := CHART_MIN_BAR_W;
    X := R.Left + CHART_PAD + AccumX;

    IsSelected := (I = FSelectedIndex);

    { Узкие сегменты (короткие IntervalsT-зубцы) с обводкой выглядят
      хуже без неё — съедается основной цвет. Поэтому inset=0 для
      ширины меньше MIN_INSET_WIDTH. }
    if BarW >= MIN_INSET_WIDTH then
      Inset := EDGE_INSET
    else
      Inset := 0;

    case Seg.Kind of
      wskSteady, wskInterval:
        begin
          Y1 := PowerToY(Seg.PowerLow);

          { Тёмная подложка-тень — рисуем только если есть запас по
            ширине под основной цвет. }
          if Inset > 0 then
            DrawRectangle(
              FloatRectangle(X, ChartBaseY, BarW, Y1), ShadowCol);

          { Основной цвет — вписан в подложку с уменьшением Inset
            по периметру. }
          Col := PowerToColor(Seg.PowerLow);
          DrawRectangle(
            FloatRectangle(X + Inset, ChartBaseY + Inset,
              BarW - Inset * 2, Y1 - Inset * 2),
            Col);
        end;

      wskWarmup, wskCooldown, wskRamp:
        begin
          { Настоящая трапеция через DrawPrimitive2D — раньше
            рисовали прямоугольником средней мощности, что плохо
            читалось на чарте. Теперь у Ramp/Warmup/Cooldown виден
            реальный наклон. }
          Col := PowerToColor((Seg.PowerLow + Seg.PowerHigh) * 0.5);
          Y1 := PowerToY(Seg.PowerLow);
          Y2 := PowerToY(Seg.PowerHigh);
          Y0 := ChartBaseY;

          { Тень-обводка трапеции. }
          if Inset > 0 then
            DrawPrimitive2D(pmTriangleFan,
              [Vector2(X,         Y0),
               Vector2(X + BarW,  Y0),
               Vector2(X + BarW,  Y0 + Y2),
               Vector2(X,         Y0 + Y1)],
              ShadowCol);

          { Основная трапеция. }
          DrawPrimitive2D(pmTriangleFan,
            [Vector2(X + Inset,         Y0 + Inset),
             Vector2(X + BarW - Inset,  Y0 + Inset),
             Vector2(X + BarW - Inset,  Y0 + Y2 - Inset),
             Vector2(X + Inset,         Y0 + Y1 - Inset)],
            Col);
        end;

      wskFreeRide:
        begin
          Y1 := PowerToY(0.65);

          if Inset > 0 then
            DrawRectangle(
              FloatRectangle(X, ChartBaseY, BarW, Y1), ShadowCol);

          Col := Vector4(0.55, 0.55, 0.60, 0.85);
          DrawRectangle(
            FloatRectangle(X + Inset, ChartBaseY + Inset,
              BarW - Inset * 2, Y1 - Inset * 2),
            Col);
        end;
    end;

    { Обводка для выбранного и его «соседей по группе». Рисуется
      ПОВЕРХ тени и основной заливки — чтобы её было видно. Высоту
      берём через SegTopY (для трапеций — это Max(Low,High), не
      «средняя» Y1). }
    Y1 := SegTopY(Seg);
    if IsSelected then
    begin
      DrawRectangle(FloatRectangle(X, ChartBaseY + Y1 - 2, BarW, 2),
        Vector4(1, 0.85, 0.20, 1.0));
      DrawRectangle(FloatRectangle(X, ChartBaseY, 2, Y1),
        Vector4(1, 0.85, 0.20, 1.0));
      DrawRectangle(FloatRectangle(X + BarW - 2, ChartBaseY, 2, Y1),
        Vector4(1, 0.85, 0.20, 1.0));
    end
    else if IsInSelectedGroup(I) then
    begin
      DrawRectangle(FloatRectangle(X, ChartBaseY + Y1 - 1, BarW, 1),
        Vector4(1, 0.85, 0.20, 0.50));
      DrawRectangle(FloatRectangle(X, ChartBaseY, 1, Y1),
        Vector4(1, 0.85, 0.20, 0.50));
      DrawRectangle(FloatRectangle(X + BarW - 1, ChartBaseY, 1, Y1),
        Vector4(1, 0.85, 0.20, 0.50));
    end;

    AccumX := AccumX + BarW;
  end;

  { ── Маркеры TextEvents выбранного сегмента ───────────────────────
    Маркеры — оранжевые вертикальные полоски в нижней части chart-а,
    закреплённые в позиции timeoffset/SegDur от начала канонического
    сегмента. Выбранный маркер ярче (сплошной), остальные —
    полупрозрачные. На большем сегменте в IntervalsT-группе маркеры
    привязаны к границам всей группы (всё хранится у канонического
    On-сегмента группы). }
  if (FSelectedIndex >= 0) and (FSelectedIndex < FWorkout.Segments.Count) then
  begin
    DrawTextEventMarkers(R.Left + CHART_PAD, ChartW, ChartBaseY, MaxBarH);
  end;
end;

constructor TViewWorkoutEditor.Create(AOwner: TComponent);
begin
  inherited;
  FUndoStates:=TWorkoutFileList.Create(True);
end;

procedure TViewWorkoutEditor.SetWorkout(W: TWorkoutFile);
var
  WorkingCopy: TWorkoutFile;
begin
  SaveDraft;FUndoStates.Clear;
  WorkingCopy := nil;
  if W <> nil then WorkingCopy := W.Clone;
  if FChart <> nil then FChart.SetWorkout(nil);
  FreeAndNil(FWorkout);
  FWorkout := WorkingCopy;
  if Assigned(FWorkout) then
  begin
    FOriginalUrl := FWorkout.Url;
    FOriginalCategory := FWorkout.Category;
  end
  else
  begin
    FOriginalUrl := '';
    FOriginalCategory := '';
  end;
  FDraftUrl:=FilenameToURISafe(UserDataDir+'drafts'+PathDelim+'workout-'+MD5Print(MD5String(FOriginalUrl))+'.zwo');
  if(FWorkout<>nil)and FileExists(URIToFilenameSafe(FDraftUrl))then begin
    WorkingCopy:=TWorkoutFile.Create;
    if WorkingCopy.LoadFromUrl(FDraftUrl)then begin FWorkout.Free;FWorkout:=WorkingCopy;end else WorkingCopy.Free;
  end;
  if FWorkout<>nil then FUndoStates.Add(FWorkout.Clone);
  if FChart <> nil then LoadFromWorkout;
end;

destructor TViewWorkoutEditor.Destroy;
begin
  if FChart <> nil then FChart.SetWorkout(nil);
  FreeAndNil(FWorkout);
  FUndoStates.Free;
  inherited;
end;

procedure TViewWorkoutEditor.Start;
begin
  inherited;
  BuildUi;
  FKeyboard:=TUiKeyboardNavigation.Create(FreeAtStop);FKeyboard.Exists:=False;InsertFront(FKeyboard);
  if Assigned(FWorkout) then
    LoadFromWorkout
  else
    BindUiText(FLabelTitle, 'No workout to edit');
end;

procedure TViewWorkoutEditor.Stop;
begin
  FKeyboard:=nil;
  SaveDraft;
  if FChart <> nil then FChart.SetWorkout(nil);
  FChart := nil;                     { освобождается вместе с FreeAtStop }
  FMoreMetadata:=nil;FEditorScroll:=nil;FToolbar:=nil;FPalette:=nil;FStepActions:=nil;FTeRowsOwner:=nil;
  FreeAndNil(FWorkout);
  inherited;
end;

procedure TViewWorkoutEditor.Resize;
var W,S,X,Y,RowH,SpinW,EditW:Single;I:Integer;C:TCastleUserInterface;
  procedure Position(Control:TCastleUserInterface;Left,Top:Single);
  begin Control.Anchor(hpLeft,Left);Control.Anchor(vpTop,-Top);end;
  procedure Font(Control:TCastleUserInterface;Size:Single);
  begin
    if Control is TCastleLabel then begin TCastleLabel(Control).FontScale:=1;TCastleLabel(Control).FontSize:=Size/S;end
    else if Control is TCastleButton then begin TCastleButton(Control).FontScale:=1;TCastleButton(Control).FontSize:=Size/S;end
    else if Control is TCastleEdit then begin TCastleEdit(Control).FontScale:=1;TCastleEdit(Control).FontSize:=Size/S;end;
  end;
  procedure Flow(Control:TMenuFlow);
  var J:Integer;
  begin
    Control.Width:=W-40/S;Control.Spacing:=10/S;
    for J:=0 to Control.ControlsCount-1 do Font(Control.Controls[J],16);
    Position(Control,20/S,Y);Control.Arrange;Y:=Y+Control.Height+16/S;
  end;
  procedure Spinner(P:TPropSpinner;Pixels:Single);
  begin
    if not P.LabelCtl.Exists then Exit;SpinW:=Pixels/S;
    if X+SpinW>W-20/S then begin X:=20/S;Y:=Y+RowH;end;
    Font(P.LabelCtl,14);Font(P.EditCtl,16);Font(P.BtnMinus,18);Font(P.BtnPlus,18);
    P.LabelCtl.MaxWidth:=SpinW;Position(P.LabelCtl,X,Y);
    P.BtnMinus.Width:=30/S;P.BtnMinus.Height:=32/S;Position(P.BtnMinus,X,Y+24/S);
    EditW:=SpinW-60/S;P.EditCtl.Width:=EditW;P.EditCtl.Height:=32/S;Position(P.EditCtl,X+30/S,Y+24/S);
    P.BtnPlus.Width:=30/S;P.BtnPlus.Height:=32/S;Position(P.BtnPlus,X+30/S+EditW,Y+24/S);
    X:=X+SpinW+14/S;
  end;
begin
  inherited;if FLayoutBusy or(FMoreMetadata=nil)or(FEditorScroll=nil)then Exit;
  FLayoutBusy:=True;
  try
    S:=Max(0.5,Min(1,UIScale));W:=Max(400,EffectiveWidth-20/S);
    FBackground.Width:=W;Y:=18/S;Flow(FToolbar);
    Font(FLabelTitle,22);FLabelTitle.MaxWidth:=W-40/S;Position(FLabelTitle,20/S,Y);
    Y:=Y+Max(34/S,FLabelTitle.EffectiveHeight+10/S);
    Font(FLabelName,16);Position(FLabelName,20/S,Y+6/S);
    Font(FEditName,16);FEditName.Width:=W-160/S;FEditName.Height:=34/S;Position(FEditName,140/S,Y);Y:=Y+46/S;
    Font(FMoreMetadata,15);Position(FMoreMetadata,20/S,Y);Y:=Y+FMoreMetadata.EffectiveHeight+12/S;
    FLabelAuthor.Exists:=FMetadataExpanded;FEditAuthor.Exists:=FMetadataExpanded;
    FLabelDescription.Exists:=FMetadataExpanded;FEditDescription.Exists:=FMetadataExpanded;
    if FMetadataExpanded then begin
      Font(FLabelAuthor,16);Position(FLabelAuthor,20/S,Y+6/S);Font(FEditAuthor,16);
      FEditAuthor.Width:=W-160/S;FEditAuthor.Height:=34/S;Position(FEditAuthor,140/S,Y);Y:=Y+46/S;
      Font(FLabelDescription,16);Position(FLabelDescription,20/S,Y+6/S);Font(FEditDescription,16);
      FEditDescription.Width:=W-160/S;FEditDescription.Height:=34/S;Position(FEditDescription,140/S,Y);Y:=Y+46/S;
    end;
    Font(FLabelStats,15);Position(FLabelStats,20/S,Y);Y:=Y+32/S;Flow(FPalette);
    FChart.Width:=W-40/S;FChart.Height:=160/S;Position(FChart,20/S,Y);Y:=Y+178/S;
    Font(FLabelSelected,16);FLabelSelected.MaxWidth:=W-40/S;Position(FLabelSelected,20/S,Y);Y:=Y+32/S;
    X:=20/S;RowH:=72/S;
    Spinner(FSpinDur,150);Spinner(FSpinPower,150);Spinner(FSpinPowerHigh,150);
    Spinner(FSpinRepeats,120);Spinner(FSpinCadence,140);Spinner(FSpinCadenceHigh,140);
    Y:=Y+RowH;Flow(FStepActions);
    FTeContainer.Width:=W-40/S;Position(FTeContainer,20/S,Y);
    for I:=0 to FTeContainer.ControlsCount-1 do begin
      C:=FTeContainer.Controls[I];Font(C,15);C.Height:=32/S;
      if Pos('TeTimeMinus',C.Name)=1 then begin X:=0;C.Width:=30/S;end
      else if Pos('TeTimeInput',C.Name)=1 then begin X:=30/S;C.Width:=70/S;end
      else if Pos('TeTimePlus',C.Name)=1 then begin X:=100/S;C.Width:=30/S;end
      else if Pos('TeMessage',C.Name)=1 then begin X:=146/S;C.Width:=W-228/S;end
      else begin X:=W-74/S;C.Width:=30/S;end;
      Position(C,X,C.Tag*40/S);
    end;
    FTeContainer.Height:=Max(1,FTeRowsCount*40/S);Y:=Y+FTeContainer.Height+6/S;
    Font(FButtonTeAdd,15);FButtonTeAdd.AutoSize:=True;Position(FButtonTeAdd,20/S,Y);
    Font(FLabelTeHint,14);FLabelTeHint.MaxWidth:=W-310/S;Position(FLabelTeHint,290/S,Y+8/S);
    FBackground.Height:=Max(FEditorScroll.EffectiveHeight,Y+64/S);FEditorScroll.ScrollArea.Height:=FBackground.Height;
    FLayoutWidth:=EffectiveWidth;FLayoutScale:=S;
    FLayoutFlowHeight:=FToolbar.Height+FPalette.Height+FStepActions.Height;
  finally FLayoutBusy:=False;end;
end;

procedure TViewWorkoutEditor.DoMetadata(Sender:TObject);
begin FMetadataExpanded:=not FMetadataExpanded;SelectMenuButton(FMoreMetadata,FMetadataExpanded);Resize;end;

{ ── BuildUi ────────────────────────────────────────────────────────── }

procedure TViewWorkoutEditor.BuildUi;

  function MkLabel(const ACaption: String;
    AFontScale: Single = 1.0): TCastleLabel;
  begin
    Result := TMenuLabel.Create(FreeAtStop);
    BindUiText(Result, ACaption);
    Result.FontScale := AFontScale;
    Result.Color := Vector4(0.92, 0.92, 0.95, 1);
  end;

  function MkButton(const ACaption: String;
    AOnClick: TNotifyEvent): TCastleButton;
  begin
    Result := TMenuButton.Create(FreeAtStop);
    BindUiText(Result, ACaption);
    Result.PaddingHorizontal := 14;
    Result.PaddingVertical := 8;
    Result.FontScale := 1.0;
    Result.CustomBackground := True;
    Result.CustomTextColorUse := True;
    Result.CustomTextColor := Vector4(0.95, 0.95, 0.97, 1);
    Result.OnClick := AOnClick;
  end;

  function MkEdit(AWidth: Single; AOnChange: TNotifyEvent): TCastleEdit;
  begin
    Result := TMenuEdit.Create(FreeAtStop);
    Result.Width := AWidth;
    Result.PaddingHorizontal := 8;
    Result.PaddingVertical := 5;
    Result.OnChange := AOnChange;
    { Явно задаём высоту чтобы edit-ы и кнопки в одном ряду совпадали.
      CGE TCastleEdit обычно учитывает заданный Height если он больше
      минимально-необходимой высоты для шрифта; PaddingVertical=5 +
      стандартный шрифт ~18 px = 28 px минимум, наши 30 px — сверх
      того, безопасно. }
    Result.Height := 30;
  end;

  { Composite-конструктор: лейбл + edit + кнопки −/+, выкладываются
    по горизонтали начиная с заданного X. Возвращает TPropSpinner с
    ссылками на созданные контролы и шагом инкремента (хранится для
    обработчиков DoStep*).
    AStep — шаг инкремента; ALabelW — отведённая ширина под текст
    лейбла (чтобы edit-ы у разных спиннеров стартовали одинаково);
    AEditW — ширина поля ввода. }
  { Composite-конструктор: лейбл (отдельной строкой сверху) + ряд
      [ − ][ edit ][ + ]
    под ним. Высота всех трёх контролов в ряду = AFieldH. Кнопки
    −/+ квадратные (Width = Height = AFieldH), edit имеет свою
    ширину AEditW. Полная ширина спиннера = 2*AFieldH + AEditW.
    Caller сам ставит разумный отступ между соседними спиннерами. }
  function MkSpinner(const ALabel: String;
    AX, AY: Single;
    AEditW, AFieldH: Single;
    AStep: Single;
    AOnChange, AOnStep: TNotifyEvent): TPropSpinner;
  var
    FieldY, EditX, PlusX: Single;
  begin
    Result := TPropSpinner.Create(FreeAtStop);
    Result.Step := AStep;

    { Лейбл сверху, на полную ширину спиннера. }
    Result.LabelCtl := MkLabel(ALabel);
    Result.LabelCtl.FontScale := 0.75;
    Result.LabelCtl.Anchor(hpLeft, AX);
    Result.LabelCtl.Anchor(vpTop, AY);
    FBackground.InsertFront(Result.LabelCtl);

    FieldY := AY - SPIN_LABEL_H;

    { Минус слева. AutoSize отключаем — иначе кнопка сожмётся под
      ширину символа. Width = Height = AFieldH → квадрат. }
    Result.BtnMinus := MkButton('−', AOnStep);
    Result.BtnMinus.Tag := 0;
    Result.BtnMinus.AutoSize := False;
    Result.BtnMinus.Width  := AFieldH;
    Result.BtnMinus.Height := AFieldH;
    Result.BtnMinus.Anchor(hpLeft, AX);
    Result.BtnMinus.Anchor(vpTop, FieldY);
    FBackground.InsertFront(Result.BtnMinus);

    EditX := AX + AFieldH + SPIN_GAP;
    Result.EditCtl := MkEdit(AEditW, AOnChange);
    Result.EditCtl.Anchor(hpLeft, EditX);
    Result.EditCtl.Anchor(vpTop, FieldY);
    FBackground.InsertFront(Result.EditCtl);

    PlusX := EditX + AEditW + SPIN_GAP;
    Result.BtnPlus := MkButton('+', AOnStep);
    Result.BtnPlus.Tag := 1;
    Result.BtnPlus.AutoSize := False;
    Result.BtnPlus.Width  := AFieldH;
    Result.BtnPlus.Height := AFieldH;
    Result.BtnPlus.Anchor(hpLeft, PlusX);
    Result.BtnPlus.Anchor(vpTop, FieldY);
    FBackground.InsertFront(Result.BtnPlus);
  end;

const
  TopY        = -20;     { отступ сверху для верхней панели }
  MetaTopY    = -90;     { начало секции метаданных }
  ChartTopY   = -270;    { подвинут вниз: над чартом теперь Stats + Palette в одном ряду }
  ChartH      = 260;
  LeftPad     = 24;
  EditW       = 380;
  WideEditW   = 700;
var
  Palette: TMenuFlow;
  CanvasBackground:TCastleRectangleControl;
begin
  CanvasBackground:=TCastleRectangleControl.Create(FreeAtStop);CanvasBackground.FullSize:=True;
  CanvasBackground.Color:=MenuBackground;InsertBack(CanvasBackground);
  { Фон }
  FBackground := TCastleRectangleControl.Create(FreeAtStop);
  FBackground.Color := MenuBackground;
  FEditorScroll:=TMenuScrollView.Create(FreeAtStop);FEditorScroll.FullSize:=True;InsertFront(FEditorScroll);
  FBackground.FullSize := False;
  FEditorScroll.ScrollArea.InsertFront(FBackground);

  { Верхний бар: ButtonBack | LabelTitle (центр) | SaveAs / Save (справа) }
  FButtonBack := MkButton(T('Back'), @DoBack);
  FButtonBack.Anchor(hpLeft, LeftPad);
  FButtonBack.Anchor(vpTop, TopY);
  FBackground.InsertFront(FButtonBack);

  FLabelTitle := MkLabel(T('Workout editor'), 1.4);
  FLabelTitle.Anchor(hpMiddle);
  FLabelTitle.Anchor(vpTop, TopY - 6);
  FBackground.InsertFront(FLabelTitle);

  FButtonSave := MkButton('Save', @DoSave);FButtonSave.Name:='SaveEditedWorkout';
  FButtonSave.Anchor(hpRight, -LeftPad);
  FButtonSave.Anchor(vpTop, TopY);
  FBackground.InsertFront(FButtonSave);

  FButtonSaveAs := MkButton('Save copy', @DoSaveAs);
  FButtonSaveAs.Anchor(hpRight, -LeftPad - 160);
  FButtonSaveAs.Anchor(vpTop, TopY);
  FBackground.InsertFront(FButtonSaveAs);
  FButtonStart:=MkButton('Start workout',@DoStartWorkout);
  TMenuButton(FButtonStart).Style:=mbPrimary;TMenuButton(FButtonStart).AutoIcon:=False;
  FButtonStart.Name:='StartEditedWorkout';FButtonStart.Anchor(hpRight,-LeftPad);FButtonStart.Anchor(vpTop,-70);
  FBackground.InsertFront(FButtonStart);
  FButtonUndo:=MkButton('Undo',@DoUndo);FButtonUndo.Name:='UndoWorkoutEdit';
  FButtonUndo.Anchor(hpLeft,LeftPad+140);FButtonUndo.Anchor(vpTop,TopY);FBackground.InsertFront(FButtonUndo);
  FLabelTitle.Anchor(hpLeft,LeftPad);FLabelTitle.Anchor(vpTop,-65);FLabelTitle.MaxWidth:=600;

  { Метаданные: Name, Author, Description }
  FLabelName := MkLabel(T('Name:'));
  FLabelName.Anchor(hpLeft, LeftPad);
  FLabelName.Anchor(vpTop, MetaTopY);
  FBackground.InsertFront(FLabelName);

  FEditName := MkEdit(EditW, @DoNameChanged);FEditName.Name:='WorkoutNameInput';
  FEditName.Anchor(hpLeft, LeftPad + 130);
  FEditName.Anchor(vpTop, MetaTopY);
  FBackground.InsertFront(FEditName);

  FLabelAuthor := MkLabel(T('Author:'));
  FLabelAuthor.Anchor(hpLeft, LeftPad + 130 + EditW + 30);
  FLabelAuthor.Anchor(vpTop, MetaTopY);
  FBackground.InsertFront(FLabelAuthor);

  FEditAuthor := MkEdit(220, @DoAuthorChanged);
  FEditAuthor.Anchor(hpLeft, LeftPad + 130 + EditW + 110);
  FEditAuthor.Anchor(vpTop, MetaTopY);
  FBackground.InsertFront(FEditAuthor);

  FLabelDescription := MkLabel(T('Description:'));
  FLabelDescription.Anchor(hpLeft, LeftPad);
  FLabelDescription.Anchor(vpTop, MetaTopY - 60);
  FBackground.InsertFront(FLabelDescription);

  FEditDescription := MkEdit(WideEditW, @DoDescriptionChanged);
  FEditDescription.Anchor(hpLeft, LeftPad + 130);
  FEditDescription.Anchor(vpTop, MetaTopY - 60);
  FBackground.InsertFront(FEditDescription);

  { Chart — стартовая ширина «на глаз», в Resize пересчитываем
    на реальную ширину окна минус LeftPad с обеих сторон. }
  FChart := TWorkoutChart.Create(FreeAtStop);
  FChart.Width := 1800;
  FChart.Height := ChartH;
  FChart.Anchor(hpLeft, LeftPad);
  FChart.Anchor(vpTop, ChartTopY);
  FChart.OnSegmentClick := @DoChartSegmentClick;
  FChart.OnSegmentDrag  := @DoChartSegmentDrag;
  FChart.OnTextEventClick := @DoChartTextEventClick;
  FBackground.InsertFront(FChart);

  { Property panel — строка 1: заголовок «Выбрано: …». }
  FLabelSelected := MkLabel(T('Selected: —'), 1.05);
  FLabelSelected.Anchor(hpLeft, LeftPad);
  FLabelSelected.Anchor(vpTop, PROP_HEADER_Y);
  FBackground.InsertFront(FLabelSelected);

  { Property panel — строка 2: спиннеры (label сверху, кнопка-edit-кнопка
    под ним, всё одной высоты) и кнопки управления.

    Все спиннеры в одном ряду — Длит / Power / PowerHigh / Повторов /
    Кад. работы / Кад. отдыха — затем action-кнопки.

    Размеры:
      Длит/Power/PwrHigh: edit 90, общая ширина 30+90+30 = 150
      Повторов:           edit 40, общая 30+40+30 = 100
      Кад. *:             edit 40, общая 100

    Стартовые X (от LeftPad):
        0      150  170    Длит.
       170     150  320    Power
       340     150  490    PowerHigh
       510     100  610    Повторов
       630     100  730    Кад. работы
       750     100  850    Кад. отдыха
       880      35  915    ←
       920      35  955    →
       965      50  1015   Dup
      1020      50  1070   Del }
  FSpinDur := MkSpinner(T('Duration:'),
    LeftPad + 0, PROP_FIELDS_Y,
    90, 30, 5,
    @DoEditDurChanged, @DoStepDur);

  FSpinPower := MkSpinner('Power:',
    LeftPad + 170, PROP_FIELDS_Y,
    90, 30, 0.01,
    @DoEditPowerChanged, @DoStepPower);

  FSpinPowerHigh := MkSpinner('PowerHigh:',
    LeftPad + 340, PROP_FIELDS_Y,
    90, 30, 0.01,
    @DoEditPowerHighChanged, @DoStepPowerHigh);

  FSpinRepeats := MkSpinner(T('Repeats:'),
    LeftPad + 510, PROP_FIELDS_Y,
    40, 30, 1,
    @DoEditRepeatsChanged, @DoStepRepeats);

  { Каденция — два спиннера в том же ряду. Лейблы переключаются
    в RefreshSelectedPanel в зависимости от типа сегмента
    (Каденция / Каденция Low / Кад. работы / Кад. отдыха). }
  FSpinCadence := MkSpinner(T('Cadence (work):'),
    LeftPad + 630, PROP_FIELDS_Y,
    40, 30, 1,
    @DoEditCadenceChanged, @DoStepCadence);

  FSpinCadenceHigh := MkSpinner(T('Cadence (rest):'),
    LeftPad + 750, PROP_FIELDS_Y,
    40, 30, 1,
    @DoEditCadenceHighChanged, @DoStepCadenceHigh);

  { Action-кнопки в том же ряду полей (на ряду чисел, не лейблов). }
  FButtonMoveLeft := MkButton('←', @DoMoveLeft);
  FButtonMoveLeft.AutoSize := False;
  FButtonMoveLeft.Width  := 35;
  FButtonMoveLeft.Height := 30;
  FButtonMoveLeft.Anchor(hpLeft, LeftPad + 880);
  FButtonMoveLeft.Anchor(vpTop, PROP_FIELDS_Y - SPIN_LABEL_H);
  FBackground.InsertFront(FButtonMoveLeft);

  FButtonMoveRight := MkButton('→', @DoMoveRight);
  FButtonMoveRight.AutoSize := False;
  FButtonMoveRight.Width  := 35;
  FButtonMoveRight.Height := 30;
  FButtonMoveRight.Anchor(hpLeft, LeftPad + 920);
  FButtonMoveRight.Anchor(vpTop, PROP_FIELDS_Y - SPIN_LABEL_H);
  FBackground.InsertFront(FButtonMoveRight);

  FButtonDuplicate := MkButton('Copy', @DoDuplicate);
  FButtonDuplicate.AutoSize := False;
  FButtonDuplicate.Width  := 50;
  FButtonDuplicate.Height := 30;
  FButtonDuplicate.Anchor(hpLeft, LeftPad + 965);
  FButtonDuplicate.Anchor(vpTop, PROP_FIELDS_Y - SPIN_LABEL_H);
  FBackground.InsertFront(FButtonDuplicate);

  FButtonDelete := MkButton('Delete', @DoDelete);
  FButtonDelete.AutoSize := False;
  FButtonDelete.Width  := 50;
  FButtonDelete.Height := 30;
  FButtonDelete.Anchor(hpLeft, LeftPad + 1020);
  FButtonDelete.Anchor(vpTop, PROP_FIELDS_Y - SPIN_LABEL_H);
  FBackground.InsertFront(FButtonDelete);

  { TextEvents — динамический список под cadence-рядом. Контейнер
    «прозрачный» (без явного фона), позиционируется на TEXT_EVENT_Y,
    высота меняется в RefreshSelectedPanel под количество рядов.
    Сами ряды создаются динамически — каждый TPropTextEventRow это
    набор контролов уровня FTeContainer. }
  FTeContainer := TCastleUserInterface.Create(FreeAtStop);
  FTeContainer.AutoSizeToChildren := False;
  FTeContainer.Width  := 1200;       { пересчитается в Resize-аналоге }
  FTeContainer.Height := 1;
  FTeContainer.Anchor(hpLeft, LeftPad);
  FTeContainer.Anchor(vpTop, TEXT_EVENT_Y);
  FBackground.InsertFront(FTeContainer);

  FButtonTeAdd := MkButton(T('+ Text message'), @DoTeAddClick);
  FButtonTeAdd.AutoSize := False;
  FButtonTeAdd.Width  := 200;
  FButtonTeAdd.Height := 30;
  FButtonTeAdd.FontScale := 0.8;
  FButtonTeAdd.Anchor(hpLeft, LeftPad);
  FButtonTeAdd.Anchor(vpTop, TEXT_EVENT_Y);   { пересчитается под FTeContainer }
  FBackground.InsertFront(FButtonTeAdd);

  FLabelTeHint := MkLabel(T('This segment has no text messages'));
  FLabelTeHint.Color := Vector4(0.65, 0.68, 0.75, 1);
  FLabelTeHint.Anchor(hpLeft, LeftPad + 220);
  FLabelTeHint.Anchor(vpTop, TEXT_EVENT_Y);
  FBackground.InsertFront(FLabelTeHint);

  FTeRowsForSeg := -2;       { -2 = «никогда не строилось», -1 = «нет выбора» }
  FTeRowsCount  := 0;

  { Stats и Palette в одном ряду над чартом. Stats слева,
    «Добавить сегмент: …» с кнопками — правее. }
  FLabelStats := MkLabel('—', 0.9);
  FLabelStats.Color := Vector4(0.85, 0.88, 0.95, 1.0);
  FLabelStats.Anchor(hpLeft, LeftPad);
  FLabelStats.Anchor(vpTop, ABOVE_CHART_Y);
  FBackground.InsertFront(FLabelStats);

  FLabelAdd := MkLabel(T('Add segment:'), 1.0);
  FLabelAdd.Anchor(hpLeft, LeftPad + 320);
  FLabelAdd.Anchor(vpTop, ABOVE_CHART_Y);
  FBackground.InsertFront(FLabelAdd);

  FButtonAddWarmup := MkButton('Warmup', @DoAddSegment);
  FButtonAddWarmup.Tag := Ord(wskWarmup);
  FButtonAddWarmup.Anchor(hpLeft, LeftPad + 470);
  FButtonAddWarmup.Anchor(vpTop, ABOVE_CHART_Y);
  FBackground.InsertFront(FButtonAddWarmup);

  FButtonAddSteady := MkButton('Steady', @DoAddSegment);
  FButtonAddSteady.Tag := Ord(wskSteady);
  FButtonAddSteady.Anchor(hpLeft, LeftPad + 555);
  FButtonAddSteady.Anchor(vpTop, ABOVE_CHART_Y);
  FBackground.InsertFront(FButtonAddSteady);

  FButtonAddRamp := MkButton('Ramp', @DoAddSegment);
  FButtonAddRamp.Tag := Ord(wskRamp);
  FButtonAddRamp.Anchor(hpLeft, LeftPad + 635);
  FButtonAddRamp.Anchor(vpTop, ABOVE_CHART_Y);
  FBackground.InsertFront(FButtonAddRamp);

  FButtonAddFreeRide := MkButton('FreeRide', @DoAddSegment);
  FButtonAddFreeRide.Tag := Ord(wskFreeRide);
  FButtonAddFreeRide.Anchor(hpLeft, LeftPad + 705);
  FButtonAddFreeRide.Anchor(vpTop, ABOVE_CHART_Y);
  FBackground.InsertFront(FButtonAddFreeRide);

  FButtonAddCooldown := MkButton('Cooldown', @DoAddSegment);
  FButtonAddCooldown.Tag := Ord(wskCooldown);
  FButtonAddCooldown.Anchor(hpLeft, LeftPad + 805);
  FButtonAddCooldown.Anchor(vpTop, ABOVE_CHART_Y);
  FBackground.InsertFront(FButtonAddCooldown);
  Palette := TMenuFlow.Create(FreeAtStop);FPalette:=Palette;
  Palette.Spacing := 10;
  Palette.Anchor(hpLeft, LeftPad + 400);
  Palette.Anchor(vpTop, ABOVE_CHART_Y);
  FBackground.InsertFront(Palette);
  FBackground.RemoveControl(FLabelAdd); Palette.InsertFront(FLabelAdd);
  FBackground.RemoveControl(FButtonAddWarmup); Palette.InsertFront(FButtonAddWarmup);
  FBackground.RemoveControl(FButtonAddSteady); Palette.InsertFront(FButtonAddSteady);
  FBackground.RemoveControl(FButtonAddRamp); Palette.InsertFront(FButtonAddRamp);
  FBackground.RemoveControl(FButtonAddFreeRide); Palette.InsertFront(FButtonAddFreeRide);
  FBackground.RemoveControl(FButtonAddCooldown); Palette.InsertFront(FButtonAddCooldown);

  FToolbar:=TMenuFlow.Create(FreeAtStop);FBackground.InsertFront(FToolbar);
  FBackground.RemoveControl(FButtonBack);FToolbar.InsertFront(FButtonBack);
  FBackground.RemoveControl(FButtonUndo);FToolbar.InsertFront(FButtonUndo);
  FBackground.RemoveControl(FButtonSave);FToolbar.InsertFront(FButtonSave);
  FBackground.RemoveControl(FButtonSaveAs);FToolbar.InsertFront(FButtonSaveAs);
  FBackground.RemoveControl(FButtonStart);FToolbar.InsertFront(FButtonStart);
  FStepActions:=TMenuFlow.Create(FreeAtStop);FBackground.InsertFront(FStepActions);
  FBackground.RemoveControl(FButtonMoveLeft);FStepActions.InsertFront(FButtonMoveLeft);
  FBackground.RemoveControl(FButtonMoveRight);FStepActions.InsertFront(FButtonMoveRight);
  FBackground.RemoveControl(FButtonDuplicate);FStepActions.InsertFront(FButtonDuplicate);
  FBackground.RemoveControl(FButtonDelete);FStepActions.InsertFront(FButtonDelete);
  FButtonMoveLeft.AutoSize:=True;FButtonMoveRight.AutoSize:=True;
  FButtonDuplicate.AutoSize:=True;FButtonDelete.AutoSize:=True;
  FMoreMetadata:=MkButton('Author and description (optional)',@DoMetadata);
  FBackground.InsertFront(FMoreMetadata);Resize;
end;

{ ── Загрузка/обновление UI из FWorkout ────────────────────────────── }

procedure TViewWorkoutEditor.LoadFromWorkout;
begin
  if not Assigned(FWorkout) then Exit;

  FLoadingFields:=True;
  FEditName.Text := FWorkout.Name;
  FEditAuthor.Text := FWorkout.Author;
  FEditDescription.Text := FWorkout.Description;

  FChart.SetWorkout(FWorkout);
  if FWorkout.Segments.Count > 0 then
    FChart.SelectedIndex := 0
  else
    FChart.SelectedIndex := -1;
  FChart.SelectedTextEvent := -1;

  RefreshTitle;
  RefreshSelectedPanel;
  RefreshStats;

  { Modified выставляется setter-ами, но во время инициализации мы
    дёргаем Text напрямую — сетераторы Workout не вызываются. Всё
    равно сбрасываем для надёжности. }
  FLoadingFields:=False;
  FWorkout.Modified := False;
end;

procedure TViewWorkoutEditor.RefreshTitle;
begin
  if not Assigned(FWorkout) then Exit;
  if FWorkout.Modified and not FLoadingFields then begin
    FDraftPending:=True;FDraftDelay:=1.5;
    FUndoStates.Add(FWorkout.Clone);
    if FUndoStates.Count>24 then FUndoStates.Delete(0);
  end;
  if FButtonUndo<>nil then FButtonUndo.Enabled:=FUndoStates.Count>1;
  if FWorkout.Modified then
    FLabelTitle.Caption := FWorkout.Name + ' *'
  else
    FLabelTitle.Caption := FWorkout.Name;
end;

procedure TViewWorkoutEditor.RefreshChart;
begin
  if Assigned(FChart) then
    FChart.VisibleChange([chRender]);
end;

procedure TViewWorkoutEditor.RefreshSelectedPanel;
var
  Idx: Integer;
  Seg: TWorkoutSegment;
  KindName: String;
  ShowPower, ShowPowerHigh, ShowRepeats: Boolean;
  ShowCadence, ShowCadenceHigh: Boolean;
  CanonIdx: Integer;
  TeCount: Integer;
  TeBlockH: Integer;

  procedure SetSpinnerVisible(Sp: TPropSpinner; V: Boolean);
  begin
    Sp.LabelCtl.Exists := V;
    Sp.EditCtl.Exists  := V;
    Sp.BtnMinus.Exists := V;
    Sp.BtnPlus.Exists  := V;
  end;

  function FormatRPM(R: Integer): String;
  begin
    if R <= 0 then Result := ''
              else Result := IntToStr(R);
  end;

begin
  if not Assigned(FWorkout) or not Assigned(FChart) then Exit;
  Idx := FChart.SelectedIndex;

  if (Idx < 0) or (Idx >= FWorkout.Segments.Count) then
  begin
    BindUiText(FLabelSelected, 'Selected: —');
    SetSpinnerVisible(FSpinDur, False);
    SetSpinnerVisible(FSpinPower, False);
    SetSpinnerVisible(FSpinPowerHigh, False);
    SetSpinnerVisible(FSpinRepeats, False);
    SetSpinnerVisible(FSpinCadence, False);
    SetSpinnerVisible(FSpinCadenceHigh, False);
    if FTeRowsForSeg <> -1 then
    begin
      while FTeContainer.ControlsCount>0 do FTeContainer.Controls[0].Free;
      FTeRowsCount := 0;
      FTeContainer.Height := 1;
      FTeRowsForSeg := -1;
    end;
    FButtonTeAdd.Exists := False;
    FLabelTeHint.Exists := False;
    Exit;
  end;

  Seg := FWorkout.Segments[Idx];

  KindName := WorkoutSegmentKindName(Seg.Kind);
  if (Seg.Kind = wskInterval) and (Seg.RepeatGroup > 0) then
  begin
    if Seg.IsOnPart then
      KindName := 'Interval On'
    else
      KindName := 'Interval Off';
  end;
  FLabelSelected.Caption :=
    Format(T('Selected: %s (segment %d of %d)'),
      [UiText(KindName), Idx + 1, FWorkout.Segments.Count]);

  SetSpinnerVisible(FSpinDur, True);
  FSpinDur.EditCtl.Text := FormatDur(Seg.Duration);

  ShowPower := Seg.Kind <> wskFreeRide;
  SetSpinnerVisible(FSpinPower, ShowPower);
  if ShowPower then
    FSpinPower.EditCtl.Text := FormatPwr(Seg.PowerLow);

  ShowPowerHigh := CanEditPowerHigh;
  SetSpinnerVisible(FSpinPowerHigh, ShowPowerHigh);
  if ShowPowerHigh then
    FSpinPowerHigh.EditCtl.Text := FormatPwr(Seg.PowerHigh);

  ShowRepeats := (Seg.Kind = wskInterval) and (Seg.RepeatGroup > 0);
  SetSpinnerVisible(FSpinRepeats, ShowRepeats);
  if ShowRepeats then
    FSpinRepeats.EditCtl.Text := IntToStr(FWorkout.GroupRepCount(Idx));

  { Каденция — настройка по типу сегмента:
    • Steady, FreeRide: один спиннер «Каденция» (Cadence)
    • Interval On: «Каденция работы» + «Каденция отдыха» (= CadenceResting,
      берём с парного Off-сегмента, по аналогии с группой это первый Off
      = FirstIdx+1)
    • Interval Off: только «Каденция отдыха» (CadenceResting этого сегмента)
    • Warmup/Cooldown/Ramp: «Каденция Low» + «Каденция High» (CadenceLow/High;
      если в файле было только Cadence — оба показывают это значение) }
  ShowCadence := False;
  ShowCadenceHigh := False;
  case Seg.Kind of
    wskSteady, wskFreeRide:
      begin
        ShowCadence := True;
        BindUiText(FSpinCadence.LabelCtl, 'Cadence:');
        FSpinCadence.EditCtl.Text := FormatRPM(Seg.Cadence);
      end;
    wskInterval:
      if Seg.RepeatGroup > 0 then
      begin
        ShowCadence := True;
        if Seg.IsOnPart then
        begin
          BindUiText(FSpinCadence.LabelCtl, 'Cadence (work):');
          FSpinCadence.EditCtl.Text := FormatRPM(Seg.Cadence);
          { CadenceHigh-spinner для Interval = Каденция отдыха.
            Берём с парного Off-сегмента той же группы. }
          ShowCadenceHigh := True;
          BindUiText(FSpinCadenceHigh.LabelCtl, 'Cadence (rest):');
          if (Idx + 1 < FWorkout.Segments.Count) and
             (FWorkout.Segments[Idx + 1].RepeatGroup = Seg.RepeatGroup) and
             (not FWorkout.Segments[Idx + 1].IsOnPart) then
            FSpinCadenceHigh.EditCtl.Text :=
              FormatRPM(FWorkout.Segments[Idx + 1].CadenceResting)
          else
            FSpinCadenceHigh.EditCtl.Text := '';
        end
        else
        begin
          BindUiText(FSpinCadence.LabelCtl, 'Cadence (rest):');
          FSpinCadence.EditCtl.Text := FormatRPM(Seg.CadenceResting);
        end;
      end;
    wskWarmup, wskCooldown, wskRamp:
      begin
        ShowCadence := True;
        ShowCadenceHigh := True;
        BindUiText(FSpinCadence.LabelCtl, 'Cadence Low:');
        FSpinCadence.EditCtl.Text := FormatRPM(Seg.CadenceLow);
        BindUiText(FSpinCadenceHigh.LabelCtl, 'Cadence High:');
        FSpinCadenceHigh.EditCtl.Text := FormatRPM(Seg.CadenceHigh);
      end;
  end;
  SetSpinnerVisible(FSpinCadence, ShowCadence);
  SetSpinnerVisible(FSpinCadenceHigh, ShowCadenceHigh);

  { ── TextEvent UI: список рядов под cadence ──────────────────────
    Все TextEvents канонического сегмента отображаются как отдельные
    ряды друг под другом. Кнопка «+ Текст. сообщение» — ВСЕГДА
    видна и стоит ПОД списком (Y зависит от количества рядов).

    Hint показывается когда сегмент выбран, но событий нет. }
  CanonIdx := FWorkout.CanonicalSegmentIndex(Idx);
  if (CanonIdx >= 0) and (CanonIdx < FWorkout.Segments.Count) then
    TeCount := FWorkout.Segments[CanonIdx].TextEvents.Count
  else
    TeCount := 0;

  { Пересобираем ряды только если сменился сегмент или количество
    TextEvents изменилось. Иначе при каждом нажатии в edit-поле
    мы бы стирали и заново создавали edit, теряя фокус. }
  if (FTeRowsForSeg <> CanonIdx) or (FTeRowsCount <> TeCount) then
  begin
    RebuildTeRows(CanonIdx);
    FTeRowsForSeg := CanonIdx;
  end;

  FLabelTeHint.Exists := TeCount = 0;
  FButtonTeAdd.Exists := True;

  { Позиционируем кнопку Add под контейнером — её Y зависит от
    того сколько рядов сейчас. ROW_H+ROW_GAP в RebuildTeRows = 36;
    36*N - 6 (последний без gap снизу) ≈ 36N. Берём с запасом. }
  if TeCount = 0 then
  begin
    FButtonTeAdd.Anchor(vpTop, TEXT_EVENT_Y);
    FLabelTeHint.Anchor(vpTop, TEXT_EVENT_Y);
  end
  else
  begin
    { Высота TextEvent-блока в пикселях. Кнопка «+ Добавить» едет
      вниз, но Palette/Stats теперь НАД чартом — их сдвигать не
      нужно. }
    TeBlockH := TeCount * (TE_ROW_H + TE_ROW_GAP);
    FButtonTeAdd.Anchor(vpTop, TEXT_EVENT_Y - TeBlockH - 4);
  end;
  Resize;
end;

procedure TViewWorkoutEditor.RefreshStats;
begin
  if not Assigned(FWorkout) then Exit;
  FLabelStats.Caption :=
    Format(UiText('Total: %s   TSS: %d   IF: %.2f'),
      [FormatWorkoutDuration(FWorkout.TotalDuration),
       Round(FWorkout.TSS),
       FWorkout.IntensityFactor]);
end;

{ ── Обработчики ───────────────────────────────────────────────────── }

procedure TViewWorkoutEditor.DoChartSegmentClick(Sender: TObject;
  SegmentIndex: Integer);
begin
  RefreshSelectedPanel;
end;

procedure TViewWorkoutEditor.DoChartSegmentDrag(Sender: TObject;
  Mode: TWorkoutChartDragMode; NewValue: Single; HighSide: Boolean);
var
  Idx: Integer;
  Seg: TWorkoutSegment;
begin
  if not Assigned(FWorkout) or not Assigned(FChart) then Exit;
  Idx := FChart.SelectedIndex;
  if (Idx < 0) or (Idx >= FWorkout.Segments.Count) then Exit;

  case Mode of
    cdmDuration:
      begin
        { SetGroupDuration: для члена IntervalsT-группы пропагирует
          новую длительность на all-same-phase, для одиночного —
          пишет только в него. }
        FWorkout.SetGroupDuration(Idx, NewValue);
        FSpinDur.EditCtl.Text := FormatDur(NewValue);
      end;

    cdmPower:
      begin
        if HighSide then
        begin
          { Drag за правую половину Warmup/Cooldown/Ramp → PowerHigh.
            Эти типы не входят в IntervalsT-группы, так что групповая
            пропагация не нужна — пишем напрямую в сегмент. }
          Seg := FWorkout.Segments[Idx];
          Seg.PowerHigh := NewValue;
          FWorkout.Modified := True;
          FSpinPowerHigh.EditCtl.Text := FormatPwr(NewValue);
        end
        else
        begin
          { PowerLow — для Steady/Interval (где он = Power единственное),
            и для левой половины Warmup/Cooldown/Ramp. SetGroupPower
            корректно обработает оба случая. }
          FWorkout.SetGroupPower(Idx, NewValue);
          FSpinPower.EditCtl.Text := FormatPwr(NewValue);
        end;
      end;
  end;

  RefreshStats;
  RefreshTitle;
  { RefreshChart не нужен — TWorkoutChart сам делает VisibleChange
    при каждом Motion. }
end;

procedure TViewWorkoutEditor.DoNameChanged(Sender: TObject);
begin
  if not Assigned(FWorkout) then Exit;
  FWorkout.Name := FEditName.Text;
  RefreshTitle;
end;

procedure TViewWorkoutEditor.DoAuthorChanged(Sender: TObject);
begin
  if not Assigned(FWorkout) then Exit;
  FWorkout.Author := FEditAuthor.Text;
  RefreshTitle;
end;

procedure TViewWorkoutEditor.DoDescriptionChanged(Sender: TObject);
begin
  if not Assigned(FWorkout) then Exit;
  FWorkout.Description := FEditDescription.Text;
  RefreshTitle;
end;

procedure TViewWorkoutEditor.DoEditDurChanged(Sender: TObject);
var
  Idx: Integer;
  D: Single;
begin
  if not Assigned(FWorkout) or not Assigned(FChart) then Exit;
  Idx := FChart.SelectedIndex;
  if (Idx < 0) or (Idx >= FWorkout.Segments.Count) then Exit;

  D := ParseDuration(FSpinDur.EditCtl.Text);
  if D <= 0 then Exit;
  if SameValue(FWorkout.Segments[Idx].Duration, D) then Exit;

  { SetGroupDuration сам разберётся: для члена IntervalsT-группы
    запишет D во все сегменты той же фазы (On или Off, по IsOnPart
    кликнутого), для одиночного — только в него. }
  FWorkout.SetGroupDuration(Idx, D);
  RefreshChart;
  RefreshStats;
  RefreshTitle;
end;

procedure TViewWorkoutEditor.DoEditPowerChanged(Sender: TObject);
var
  Idx: Integer;
  P: Single;
begin
  if not Assigned(FWorkout) or not Assigned(FChart) then Exit;
  Idx := FChart.SelectedIndex;
  if (Idx < 0) or (Idx >= FWorkout.Segments.Count) then Exit;

  P := ParsePower(FSpinPower.EditCtl.Text);
  if P < 0 then Exit;
  if SameValue(FWorkout.Segments[Idx].PowerLow, P) then Exit;

  FWorkout.SetGroupPower(Idx, P);
  RefreshChart;
  RefreshStats;
  RefreshTitle;
end;

procedure TViewWorkoutEditor.DoEditPowerHighChanged(Sender: TObject);
var
  Idx: Integer;
  P: Single;
  Seg: TWorkoutSegment;
begin
  if not Assigned(FWorkout) or not Assigned(FChart) then Exit;
  Idx := FChart.SelectedIndex;
  if (Idx < 0) or (Idx >= FWorkout.Segments.Count) then Exit;

  P := ParsePower(FSpinPowerHigh.EditCtl.Text);
  if P < 0 then Exit;
  Seg := FWorkout.Segments[Idx];
  if SameValue(Seg.PowerHigh, P) then Exit;
  Seg.PowerHigh := P;
  FWorkout.Modified := True;
  RefreshChart;
  RefreshStats;
  RefreshTitle;
end;

procedure TViewWorkoutEditor.DoEditRepeatsChanged(Sender: TObject);
var
  Idx, NewCount, NewSelected: Integer;
begin
  if not Assigned(FWorkout) or not Assigned(FChart) then Exit;
  Idx := FChart.SelectedIndex;
  if (Idx < 0) or (Idx >= FWorkout.Segments.Count) then Exit;

  if not TryStrToInt(Trim(FSpinRepeats.EditCtl.Text), NewCount) then Exit;
  if NewCount < 1 then NewCount := 1;
  if NewCount = FWorkout.GroupRepCount(Idx) then Exit;

  NewSelected := FWorkout.SetGroupRepeatCount(Idx, NewCount);
  if NewSelected >= 0 then
    FChart.SelectedIndex := NewSelected;

  RefreshChart;
  RefreshSelectedPanel;
  RefreshStats;
  RefreshTitle;
end;

{ Степпер-кнопки ±. Tag кнопки = 1 для +, 0 для −. Обработчик сам
  читает текущее значение из модели (а не из text-поля), применяет
  Step, пишет обратно в модель и в текст edit-а. Парсинг текста не
  нужен — есть точное число. }

procedure TViewWorkoutEditor.DoStepDur(Sender: TObject);
var
  Idx: Integer;
  D, NewD: Single;
  Btn: TCastleButton;
begin
  if not Assigned(FWorkout) or not Assigned(FChart) then Exit;
  Idx := FChart.SelectedIndex;
  if (Idx < 0) or (Idx >= FWorkout.Segments.Count) then Exit;

  Btn := Sender as TCastleButton;
  D := FWorkout.Segments[Idx].Duration;
  if Btn.Tag = 1 then
    NewD := D + FSpinDur.Step
  else
    NewD := D - FSpinDur.Step;
  if NewD < 1 then NewD := 1;

  FWorkout.SetGroupDuration(Idx, NewD);
  FSpinDur.EditCtl.Text := FormatDur(NewD);
  RefreshChart;
  RefreshStats;
  RefreshTitle;
end;

procedure TViewWorkoutEditor.DoStepPower(Sender: TObject);
var
  Idx: Integer;
  P, NewP: Single;
  Btn: TCastleButton;
begin
  if not Assigned(FWorkout) or not Assigned(FChart) then Exit;
  Idx := FChart.SelectedIndex;
  if (Idx < 0) or (Idx >= FWorkout.Segments.Count) then Exit;

  Btn := Sender as TCastleButton;
  P := FWorkout.Segments[Idx].PowerLow;
  if Btn.Tag = 1 then
    NewP := P + FSpinPower.Step
  else
    NewP := P - FSpinPower.Step;
  if NewP < 0 then NewP := 0;
  if NewP > 5 then NewP := 5;

  FWorkout.SetGroupPower(Idx, NewP);
  FSpinPower.EditCtl.Text := FormatPwr(NewP);
  RefreshChart;
  RefreshStats;
  RefreshTitle;
end;

procedure TViewWorkoutEditor.DoStepPowerHigh(Sender: TObject);
var
  Idx: Integer;
  P, NewP: Single;
  Btn: TCastleButton;
  Seg: TWorkoutSegment;
begin
  if not Assigned(FWorkout) or not Assigned(FChart) then Exit;
  Idx := FChart.SelectedIndex;
  if (Idx < 0) or (Idx >= FWorkout.Segments.Count) then Exit;

  Btn := Sender as TCastleButton;
  Seg := FWorkout.Segments[Idx];
  P := Seg.PowerHigh;
  if Btn.Tag = 1 then
    NewP := P + FSpinPowerHigh.Step
  else
    NewP := P - FSpinPowerHigh.Step;
  if NewP < 0 then NewP := 0;
  if NewP > 5 then NewP := 5;

  Seg.PowerHigh := NewP;
  FWorkout.Modified := True;
  FSpinPowerHigh.EditCtl.Text := FormatPwr(NewP);
  RefreshChart;
  RefreshStats;
  RefreshTitle;
end;

procedure TViewWorkoutEditor.DoStepRepeats(Sender: TObject);
var
  Idx, Cur, NewCount, NewSelected: Integer;
  Btn: TCastleButton;
begin
  if not Assigned(FWorkout) or not Assigned(FChart) then Exit;
  Idx := FChart.SelectedIndex;
  if (Idx < 0) or (Idx >= FWorkout.Segments.Count) then Exit;

  Cur := FWorkout.GroupRepCount(Idx);
  if Cur < 1 then Exit;  { не в группе — нечего повторять }

  Btn := Sender as TCastleButton;
  if Btn.Tag = 1 then
    NewCount := Cur + Round(FSpinRepeats.Step)
  else
    NewCount := Cur - Round(FSpinRepeats.Step);
  if NewCount < 1 then NewCount := 1;
  if NewCount = Cur then Exit;

  NewSelected := FWorkout.SetGroupRepeatCount(Idx, NewCount);
  if NewSelected >= 0 then
    FChart.SelectedIndex := NewSelected;

  RefreshChart;
  RefreshSelectedPanel;
  RefreshStats;
  RefreshTitle;
end;

{ ── Cadence handlers ───────────────────────────────────────────────
  FSpinCadence интерпретируется по-разному в зависимости от выбранного
  сегмента (см. RefreshSelectedPanel):
    Steady, FreeRide → Cadence
    Interval On      → Cadence (рабочая каденция)
    Interval Off     → CadenceResting (как «основная» для Off-сегмента)
    Warmup/etc       → CadenceLow
  FSpinCadenceHigh:
    Interval On      → CadenceResting парного Off-сегмента
    Warmup/etc       → CadenceHigh
    остальные        → скрыт
  Чтобы не дублировать логику парсинга — обработчик читает
  значение из спиннера и зовёт ApplyCadence/ApplyCadenceHigh,
  которые сами разбираются с типом. }

procedure TViewWorkoutEditor.DoEditCadenceChanged(Sender: TObject);
var
  Idx, RPM: Integer;
  Seg: TWorkoutSegment;
begin
  if not Assigned(FWorkout) or not Assigned(FChart) then Exit;
  Idx := FChart.SelectedIndex;
  if (Idx < 0) or (Idx >= FWorkout.Segments.Count) then Exit;

  if Trim(FSpinCadence.EditCtl.Text) = '' then
    RPM := 0
  else if not TryStrToInt(Trim(FSpinCadence.EditCtl.Text), RPM) then Exit;
  if RPM < 0 then RPM := 0;

  Seg := FWorkout.Segments[Idx];
  case Seg.Kind of
    wskWarmup, wskCooldown, wskRamp:
      FWorkout.SetGroupCadence(Idx, RPM, False);  { Low side }
    wskInterval, wskSteady, wskFreeRide:
      FWorkout.SetGroupCadence(Idx, RPM, False);
  end;

  RefreshTitle;
end;

procedure TViewWorkoutEditor.DoEditCadenceHighChanged(Sender: TObject);
var
  Idx, RPM, OffIdx: Integer;
  Seg: TWorkoutSegment;
begin
  if not Assigned(FWorkout) or not Assigned(FChart) then Exit;
  Idx := FChart.SelectedIndex;
  if (Idx < 0) or (Idx >= FWorkout.Segments.Count) then Exit;

  if Trim(FSpinCadenceHigh.EditCtl.Text) = '' then
    RPM := 0
  else if not TryStrToInt(Trim(FSpinCadenceHigh.EditCtl.Text), RPM) then Exit;
  if RPM < 0 then RPM := 0;

  Seg := FWorkout.Segments[Idx];
  case Seg.Kind of
    wskWarmup, wskCooldown, wskRamp:
      FWorkout.SetGroupCadence(Idx, RPM, True);   { High side }
    wskInterval:
      if Seg.RepeatGroup > 0 then
      begin
        { Высокий-спиннер у Interval On — это Каденция отдыха,
          живущая на парном Off. Прокидываем дельту туда. }
        if Seg.IsOnPart then
        begin
          OffIdx := Idx + 1;
          if (OffIdx < FWorkout.Segments.Count) and
             (FWorkout.Segments[OffIdx].RepeatGroup = Seg.RepeatGroup) and
             (not FWorkout.Segments[OffIdx].IsOnPart) then
            FWorkout.SetGroupCadence(OffIdx, RPM, False);
        end;
      end;
  end;

  RefreshTitle;
end;

{ Step-кнопки cadence — увеличивают/уменьшают значение в FSpinCadence/
  FSpinCadenceHigh на 1 RPM. }
procedure TViewWorkoutEditor.DoStepCadence(Sender: TObject);
var
  Idx, NewRPM: Integer;
  Btn: TCastleButton;
  Cur: Integer;
  CurStr: String;
begin
  if not Assigned(FWorkout) or not Assigned(FChart) then Exit;
  Idx := FChart.SelectedIndex;
  if (Idx < 0) or (Idx >= FWorkout.Segments.Count) then Exit;

  CurStr := Trim(FSpinCadence.EditCtl.Text);
  if (CurStr = '') or (not TryStrToInt(CurStr, Cur)) then Cur := 0;

  Btn := Sender as TCastleButton;
  if Btn.Tag = 1 then NewRPM := Cur + 1
                 else NewRPM := Cur - 1;
  if NewRPM < 0 then NewRPM := 0;
  if NewRPM > 200 then NewRPM := 200;

  FSpinCadence.EditCtl.Text := IntToStr(NewRPM);
  DoEditCadenceChanged(FSpinCadence.EditCtl);
end;

procedure TViewWorkoutEditor.DoStepCadenceHigh(Sender: TObject);
var
  Idx, NewRPM: Integer;
  Btn: TCastleButton;
  Cur: Integer;
  CurStr: String;
begin
  if not Assigned(FWorkout) or not Assigned(FChart) then Exit;
  Idx := FChart.SelectedIndex;
  if (Idx < 0) or (Idx >= FWorkout.Segments.Count) then Exit;

  CurStr := Trim(FSpinCadenceHigh.EditCtl.Text);
  if (CurStr = '') or (not TryStrToInt(CurStr, Cur)) then Cur := 0;

  Btn := Sender as TCastleButton;
  if Btn.Tag = 1 then NewRPM := Cur + 1
                 else NewRPM := Cur - 1;
  if NewRPM < 0 then NewRPM := 0;
  if NewRPM > 200 then NewRPM := 200;

  FSpinCadenceHigh.EditCtl.Text := IntToStr(NewRPM);
  DoEditCadenceHighChanged(FSpinCadenceHigh.EditCtl);
end;

{ ── TextEvent handlers ─────────────────────────────────────────────
  TextEvents живут на «каноническом» сегменте (для одиночного — на
  нём самом; для члена IntervalsT-группы — на FirstIdx группы).
  Маркеры рисуются на полную ширину группы; timeoffset считается
  от начала группы.

  Каждый ряд редактирования — это набор контролов с одинаковым
  Tag = индекс TextEvent в Seg.TextEvents. Обработчик читает
  Tag отправителя, находит соответствующий TextEvent на каноническом
  сегменте и применяет правку. }

procedure TViewWorkoutEditor.RebuildTeRows(CanonSegIdx: Integer);
const
  ROW_H        = 30;
  ROW_GAP      = 6;
  BTN_W        = 30;        { квадратные −/+/× }
  TIME_EDIT_W  = 70;
  MSG_EDIT_W   = 600;
var
  Seg: TWorkoutSegment;
  K: Integer;
  Te: TWorkoutTextEvent;
  RowY: Single;
  Btn: TCastleButton;
  Edit: TCastleEdit;
  X: Single;

  function MkRowButton(const ACaption: String;
    AOnClick: TNotifyEvent; ATag: Integer): TCastleButton;
  begin
    Result := TMenuButton.Create(FTeRowsOwner);
    BindUiText(Result, ACaption);
    Result.AutoSize := False;
    Result.Width := BTN_W;
    Result.Height := ROW_H;
    Result.PaddingHorizontal := 0;
    Result.PaddingVertical := 0;
    Result.FontScale := 1.0;
    Result.CustomBackground := True;
    Result.CustomTextColorUse := True;
    Result.CustomTextColor := Vector4(0.95, 0.95, 0.97, 1);
    Result.OnClick := AOnClick;
    Result.Tag := ATag;
  end;

  function MkRowEdit(AWidth: Single; AOnChange: TNotifyEvent;
    ATag: Integer): TCastleEdit;
  begin
    Result := TMenuEdit.Create(FTeRowsOwner);
    Result.Width := AWidth;
    Result.PaddingHorizontal := 8;
    Result.PaddingVertical := 5;
    Result.OnChange := AOnChange;
    Result.Tag := ATag;
    Result.Height := TE_ROW_H;     { строго совпадает с Height кнопок в этом ряду }
  end;

begin
  { Удаляем старые контролы — ClearControls отвязывает их от parent
    но не уничтожает (они FreeAtStop-owned и будут жить до Stop view).
    Это означает что контролы накапливаются в памяти при каждой
    пересборке; для типичного редактора с десятками TextEvents за
    сессию это безболезненно. }
  FTeContainer.ClearControls;
  if FTeRowsOwner<>nil then ApplicationProperties.FreeDelayed(FTeRowsOwner);
  FTeRowsOwner:=TComponent.Create(FreeAtStop);

  if (CanonSegIdx < 0) or (CanonSegIdx >= FWorkout.Segments.Count) then
  begin
    FTeRowsCount := 0;
    FTeContainer.Height := 1;
    Exit;
  end;

  Seg := FWorkout.Segments[CanonSegIdx];
  FTeRowsCount := Seg.TextEvents.Count;

  if FTeRowsCount = 0 then
  begin
    FTeContainer.Height := 1;
    Exit;
  end;

  FTeContainer.Height := FTeRowsCount * ROW_H + (FTeRowsCount - 1) * ROW_GAP;

  for K := 0 to Seg.TextEvents.Count - 1 do
  begin
    Te := Seg.TextEvents[K];
    { В CGE Y растёт вниз внутри FTeContainer (anchor vpTop с
      отрицательным delta = ниже верха). Каждая следующая строка —
      на ROW_H + ROW_GAP ниже предыдущей. }
    RowY := -(K * (ROW_H + ROW_GAP));

    X := 0;

    Btn := MkRowButton('−', @DoTeStepTime, K);
    Btn.Name:='TeTimeMinus'+IntToStr(K);
    Btn.Anchor(hpLeft, X);
    Btn.Anchor(vpTop, RowY);
    FTeContainer.InsertFront(Btn);
    X := X + BTN_W;

    Edit := MkRowEdit(TIME_EDIT_W, @DoTeTimeChanged, K);
    Edit.Name:='TeTimeInput'+IntToStr(K);
    Edit.Text := FormatDur(Te.TimeOffset);
    Edit.Anchor(hpLeft, X);
    Edit.Anchor(vpTop, RowY);
    FTeContainer.InsertFront(Edit);
    X := X + TIME_EDIT_W;

    Btn := MkRowButton('+', @DoTeStepTime, K);
    Btn.Name:='TeTimePlus'+IntToStr(K);
    Btn.Anchor(hpLeft, X);
    Btn.Anchor(vpTop, RowY);
    FTeContainer.InsertFront(Btn);
    X := X + BTN_W + 16;

    Edit := MkRowEdit(MSG_EDIT_W, @DoTeMessageChanged, K);
    Edit.Name:='TeMessage'+IntToStr(K);
    Edit.Text := Te.Message;
    Edit.Anchor(hpLeft, X);
    Edit.Anchor(vpTop, RowY);
    FTeContainer.InsertFront(Edit);
    X := X + MSG_EDIT_W + 8;

    Btn := MkRowButton('×', @DoTeDeleteClick, K);
    Btn.Name:='TeDelete'+IntToStr(K);
    Btn.Anchor(hpLeft, X);
    Btn.Anchor(vpTop, RowY);
    FTeContainer.InsertFront(Btn);
  end;
end;

procedure TViewWorkoutEditor.RefreshSingleTeRowTime(TeIdx: Integer;
  NewTime: Single);
var
  I: Integer;
  Ctl: TCastleUserInterface;
  Edit: TCastleEdit;
begin
  if not Assigned(FTeContainer) then Exit;
  { Ищем edit времени с Tag = TeIdx и width = TIME_EDIT_W (70) —
    в ряду 70-шириной только один edit, это он. Мог бы хранить
    ссылки на ряды, но прохода 4-7 контролов на ряд достаточно. }
  for I := 0 to FTeContainer.ControlsCount - 1 do
  begin
    Ctl := FTeContainer.Controls[I];
    if (Ctl is TCastleEdit) and (Ctl.Tag = TeIdx) and
       (Pos('TeTimeInput',Ctl.Name)=1) then
    begin
      Edit := TCastleEdit(Ctl);
      Edit.Text := FormatDur(NewTime);
      Exit;
    end;
  end;
end;

function TViewWorkoutEditor.GetTextEventByTag(Sender: TObject;
  out CanonSegIdx, TeIdx: Integer): TWorkoutTextEvent;
var
  Ctl: TCastleUserInterface;
  Seg: TWorkoutSegment;
begin
  Result := nil;
  CanonSegIdx := -1;
  TeIdx := -1;
  if not Assigned(FWorkout) or not Assigned(FChart) then Exit;
  if not (Sender is TCastleUserInterface) then Exit;
  Ctl := TCastleUserInterface(Sender);
  TeIdx := Ctl.Tag;

  CanonSegIdx := FWorkout.CanonicalSegmentIndex(FChart.SelectedIndex);
  if (CanonSegIdx < 0) or (CanonSegIdx >= FWorkout.Segments.Count) then Exit;

  Seg := FWorkout.Segments[CanonSegIdx];
  if (TeIdx < 0) or (TeIdx >= Seg.TextEvents.Count) then Exit;

  Result := Seg.TextEvents[TeIdx];
end;

procedure TViewWorkoutEditor.DoChartTextEventClick(Sender: TObject);
begin
  { При клике на маркер в чарте мы только подсвечиваем его в чарте.
    Список рядов уже виден целиком, никакого «попапа» нет — просто
    обновим визуал чтобы выделение синхронизировалось. }
  RefreshChart;
end;

procedure TViewWorkoutEditor.DoTeTimeChanged(Sender: TObject);
var
  CanonIdx, TeIdx: Integer;
  Te: TWorkoutTextEvent;
  T: Single;
  Edit: TCastleEdit;
begin
  Te := GetTextEventByTag(Sender, CanonIdx, TeIdx);
  if Te = nil then Exit;
  Edit := Sender as TCastleEdit;

  T := ParseDuration(Edit.Text);
  if T < 0 then Exit;
  if SameValue(Te.TimeOffset, T) then Exit;

  Te.TimeOffset := T;
  FWorkout.Modified := True;
  FChart.SelectedTextEvent := TeIdx;
  RefreshChart;
  RefreshTitle;
end;

procedure TViewWorkoutEditor.DoTeStepTime(Sender: TObject);
const
  STEP = 5;
var
  CanonIdx, TeIdx: Integer;
  Te: TWorkoutTextEvent;
  Btn: TCastleButton;
  NewT: Single;
begin
  Te := GetTextEventByTag(Sender, CanonIdx, TeIdx);
  if Te = nil then Exit;

  Btn := Sender as TCastleButton;
  { У − и + одинаковый Tag (индекс Te) — направление различается
    через CustomColorNormal или через имя Caption. Проще — храним
    направление в дополнительном поле, но MkButton API без extra.
    Решение: '−' имеет Caption '−', '+' — '+'. По нему и судим. }
  if Btn.Caption = '+' then
    NewT := Te.TimeOffset + STEP
  else
    NewT := Te.TimeOffset - STEP;
  if NewT < 0 then NewT := 0;

  Te.TimeOffset := NewT;
  FWorkout.Modified := True;
  FChart.SelectedTextEvent := TeIdx;
  RefreshChart;
  { Обновляем edit времени в этом ряду. Найти его по Tag. }
  RefreshSingleTeRowTime(TeIdx, NewT);
  RefreshTitle;
end;

procedure TViewWorkoutEditor.DoTeMessageChanged(Sender: TObject);
var
  CanonIdx, TeIdx: Integer;
  Te: TWorkoutTextEvent;
  Edit: TCastleEdit;
begin
  Te := GetTextEventByTag(Sender, CanonIdx, TeIdx);
  if Te = nil then Exit;
  Edit := Sender as TCastleEdit;
  if Te.Message = Edit.Text then Exit;

  Te.Message := Edit.Text;
  FWorkout.Modified := True;
  FChart.SelectedTextEvent := TeIdx;
  RefreshTitle;
end;

procedure TViewWorkoutEditor.DoTeAddClick(Sender: TObject);
var
  CanonIdx: Integer;
  Seg: TWorkoutSegment;
  Te: TWorkoutTextEvent;
begin
  if not Assigned(FWorkout) or not Assigned(FChart) then Exit;
  if (FChart.SelectedIndex < 0) or
     (FChart.SelectedIndex >= FWorkout.Segments.Count) then Exit;

  CanonIdx := FWorkout.CanonicalSegmentIndex(FChart.SelectedIndex);
  if (CanonIdx < 0) or (CanonIdx >= FWorkout.Segments.Count) then Exit;

  Seg := FWorkout.Segments[CanonIdx];
  Te := TWorkoutTextEvent.Create;
  Te.OrigTagName := 'textevent';
  Te.TimeOffset := 0;
  Te.Duration := 0;
  Te.Message := T('New message');
  Seg.TextEvents.Add(Te);

  FWorkout.Modified := True;
  FChart.SelectedTextEvent := Seg.TextEvents.Count - 1;
  FTeRowsForSeg := -2;     { вынудить пересборку рядов }
  RefreshChart;
  RefreshSelectedPanel;
  RefreshTitle;
end;

procedure TViewWorkoutEditor.DoTeDeleteClick(Sender: TObject);
var
  CanonIdx, TeIdx: Integer;
  Seg: TWorkoutSegment;
  Btn: TCastleButton;
begin
  if not Assigned(FWorkout) or not Assigned(FChart) then Exit;
  if not (Sender is TCastleButton) then Exit;
  Btn := Sender as TCastleButton;
  TeIdx := Btn.Tag;

  CanonIdx := FWorkout.CanonicalSegmentIndex(FChart.SelectedIndex);
  if (CanonIdx < 0) or (CanonIdx >= FWorkout.Segments.Count) then Exit;

  Seg := FWorkout.Segments[CanonIdx];
  if (TeIdx < 0) or (TeIdx >= Seg.TextEvents.Count) then Exit;

  Seg.TextEvents.Delete(TeIdx);
  FWorkout.Modified := True;

  if FChart.SelectedTextEvent = TeIdx then
    FChart.SelectedTextEvent := -1
  else if FChart.SelectedTextEvent > TeIdx then
    FChart.SelectedTextEvent := FChart.SelectedTextEvent - 1;

  FTeRowsForSeg := -2;     { пересборка }
  RefreshChart;
  RefreshSelectedPanel;
  RefreshTitle;
end;

procedure TViewWorkoutEditor.DoMoveLeft(Sender: TObject);
var
  Idx, NewIdx: Integer;
begin
  if not Assigned(FWorkout) or not Assigned(FChart) then Exit;
  Idx := FChart.SelectedIndex;
  if Idx < 0 then Exit;

  { MoveBlock сам решит — двигать одиночный сегмент или всю
    IntervalsT-группу, и перепрыгнуть ли группу-соседа целиком.
    Возвращает новый индекс кликнутого сегмента после перемещения. }
  NewIdx := FWorkout.MoveBlock(Idx, -1);
  FChart.SelectedIndex := NewIdx;
  RefreshChart;
  RefreshSelectedPanel;
  RefreshStats;
  RefreshTitle;
end;

procedure TViewWorkoutEditor.DoMoveRight(Sender: TObject);
var
  Idx, NewIdx: Integer;
begin
  if not Assigned(FWorkout) or not Assigned(FChart) then Exit;
  Idx := FChart.SelectedIndex;
  if Idx < 0 then Exit;

  NewIdx := FWorkout.MoveBlock(Idx, +1);
  FChart.SelectedIndex := NewIdx;
  RefreshChart;
  RefreshSelectedPanel;
  RefreshStats;
  RefreshTitle;
end;

procedure TViewWorkoutEditor.DoDuplicate(Sender: TObject);
var
  Idx, NewIdx: Integer;
begin
  if not Assigned(FWorkout) or not Assigned(FChart) then Exit;
  Idx := FChart.SelectedIndex;
  if Idx < 0 then Exit;

  { Для члена IntervalsT-группы добавляем ещё один повтор (пара On+Off
    в конец группы), для одиночного сегмента — обычный duplicate. }
  NewIdx := FWorkout.DuplicateGroupRepOrSingle(Idx);
  if NewIdx >= 0 then
  begin
    FChart.SelectedIndex := NewIdx;
    RefreshChart;
    RefreshSelectedPanel;
    RefreshStats;
    RefreshTitle;
  end;
end;

procedure TViewWorkoutEditor.DoDelete(Sender: TObject);
var
  Idx, NewIdx: Integer;
begin
  if not Assigned(FWorkout) or not Assigned(FChart) then Exit;
  Idx := FChart.SelectedIndex;
  if Idx < 0 then Exit;

  { Для члена IntervalsT-группы удаляем целый повтор (пара On+Off),
    чтобы парность не нарушалась и счётчик повторов уменьшался на 1.
    Для одиночного — обычное удаление. }
  NewIdx := FWorkout.DeleteGroupRepOrSingle(Idx);
  FChart.SelectedIndex := NewIdx;
  RefreshChart;
  RefreshSelectedPanel;
  RefreshStats;
  RefreshTitle;
end;

procedure TViewWorkoutEditor.DoAddSegment(Sender: TObject);
var
  Btn: TCastleButton;
  Kind: TWorkoutSegmentKind;
  Idx: Integer;
  NewSeg: TWorkoutSegment;
begin
  if not Assigned(FWorkout) or not Assigned(FChart) then Exit;
  Btn := Sender as TCastleButton;
  Kind := TWorkoutSegmentKind(Btn.Tag);

  Idx := FChart.SelectedIndex;
  if Idx < 0 then
    NewSeg := FWorkout.AddSegment(Kind)
  else
    NewSeg := FWorkout.InsertSegmentAfter(Idx, Kind);

  if Assigned(NewSeg) then
  begin
    FChart.SelectedIndex := FWorkout.Segments.IndexOf(NewSeg);
    RefreshChart;
    RefreshSelectedPanel;
    RefreshStats;
    RefreshTitle;
  end;
end;

function TViewWorkoutEditor.PreviewPress(const Event:TInputPressRelease):Boolean;
var Delta:Integer;
begin
  if(Event.IsKey(keyPageUp)or Event.IsKey(keyPageDown))and
    (FWorkout<>nil)and(FChart<>nil)and(FWorkout.Segments.Count>0)and
    ((Container=nil)or(Container.ForceCaptureInput=nil))then begin
    Delta:=1;if Event.IsKey(keyPageUp)then Delta:=-1;
    FChart.SelectedIndex:=EnsureRange(FChart.SelectedIndex+Delta,0,FWorkout.Segments.Count-1);
    DoChartSegmentClick(FChart,FChart.SelectedIndex);Exit(True);
  end;
  if(FKeyboard<>nil)and FKeyboard.Handle(Event,Self)then Exit(True);
  Result:=inherited;
end;
procedure TViewWorkoutEditor.RenderOverChildren;
begin inherited;if FKeyboard<>nil then FKeyboard.Render;end;
function TViewWorkoutEditor.Press(const Event:TInputPressRelease):Boolean;
begin
  if Event.IsKey(keyEscape)then begin DoBack(nil);Exit(True);end;
  Result:=inherited;
end;
procedure TViewWorkoutEditor.DoBack(Sender: TObject);
begin
  { Stop освобождает рабочую копию вместе с несохранёнными правками.
    Объект библиотеки при редактировании не меняется. }

  { «Тренировки» больше не отдельный вью, а встроенная вкладка меню —
    возвращаемся на ViewMenu и открываем её. }
  ViewMenu.CloseChildView(Self,'training');
end;

procedure TViewWorkoutEditor.DoSave(Sender:TObject);
var Dest:String;
begin
  if FWorkout=nil then Exit;
  Dest:=FOriginalUrl;
  if Pos(ExpandFileName(UserDataDir+'workouts'+PathDelim),ExpandFileName(URIToFilenameSafe(Dest)))<>1 then
    Dest:=GenerateSaveAsUrl;
  if FWorkout.SaveToUrl(Dest)then begin
    FOriginalUrl:=Dest;FDraftPending:=False;
    if FileExists(URIToFilenameSafe(FDraftUrl))then DeleteFile(URIToFilenameSafe(FDraftUrl));
    FDraftUrl:=FilenameToURISafe(UserDataDir+'drafts'+PathDelim+'workout-'+MD5Print(MD5String(FOriginalUrl))+'.zwo');
    RefreshTitle;
  end else BindUiText(FLabelTitle,'Could not save workout');
end;

procedure TViewWorkoutEditor.DoSaveAs(Sender: TObject);
var
  NewUrl: String;
begin
  if not Assigned(FWorkout) then Exit;
  NewUrl := GenerateSaveAsUrl;
  if NewUrl = '' then
  begin
    WritelnWarning('WorkoutEditor',
      'Save As: не удалось сформировать целевой URL');
    Exit;
  end;

  if FWorkout.SaveToUrl(NewUrl) then
  begin
    FOriginalUrl := NewUrl;FDraftPending:=False;
    if FileExists(URIToFilenameSafe(FDraftUrl))then DeleteFile(URIToFilenameSafe(FDraftUrl));
    FDraftUrl:=FilenameToURISafe(UserDataDir+'drafts'+PathDelim+'workout-'+MD5Print(MD5String(FOriginalUrl))+'.zwo');
    RefreshTitle;

  end;
end;

{ ── Helpers ───────────────────────────────────────────────────────── }

function TViewWorkoutEditor.CanEditPowerHigh: Boolean;
var
  Idx: Integer;
  K: TWorkoutSegmentKind;
begin
  Result := False;
  if not Assigned(FWorkout) or not Assigned(FChart) then Exit;
  Idx := FChart.SelectedIndex;
  if (Idx < 0) or (Idx >= FWorkout.Segments.Count) then Exit;
  K := FWorkout.Segments[Idx].Kind;
  Result := K in [wskWarmup, wskCooldown, wskRamp];
end;

{ Парсинг строки длительности. Принимает форматы:
    «300» → 300 сек
    «5:00» → 300 сек
    «1:02:30» → 3750 сек
    «5m» / «5min» → 300 сек
  Возврат -1 при ошибке (caller не применяет правку). }
function TViewWorkoutEditor.ParseDuration(const S: String): Single;
var
  T, Part: String;
  Parts: array[0..2] of Integer;
  PartCount, V: Integer;
  P, I: Integer;
  HasMin: Boolean;
begin
  Result := -1;
  T := Trim(S);
  if T = '' then Exit;

  HasMin := False;
  if (Length(T) > 1) and (T[Length(T)] in ['m', 'M']) then
  begin
    HasMin := True;
    SetLength(T, Length(T) - 1);
  end;
  if EndsText('min', T) then
  begin
    HasMin := True;
    SetLength(T, Length(T) - 3);
  end;
  T := Trim(T);

  PartCount := 0;
  while (T <> '') and (PartCount < 3) do
  begin
    P := Pos(':', T);
    if P > 0 then
    begin
      Part := Copy(T, 1, P - 1);
      Delete(T, 1, P);
    end
    else
    begin
      Part := T;
      T := '';
    end;
    if not TryStrToInt(Trim(Part), V) then Exit;
    if V < 0 then Exit;
    Parts[PartCount] := V;
    Inc(PartCount);
  end;

  case PartCount of
    1:
      if HasMin then
        Result := Parts[0] * 60
      else
        Result := Parts[0];
    2:
      Result := Parts[0] * 60 + Parts[1];   { mm:ss }
    3:
      Result := Parts[0] * 3600 + Parts[1] * 60 + Parts[2];
  else
    Exit;
  end;

  if Result < 0 then Result := -1;
end;

{ Парсинг строки мощности. Принимает:
    «0.85» → 0.85
    «85%» → 0.85
    «85» (>= 5) → 0.85 (любое число ≥ 5 трактуется как процент)
    «0.85» (<= 5) → 0.85 (как доля)
  Возврат -1 при ошибке. }
function TViewWorkoutEditor.ParsePower(const S: String): Single;
var
  T: String;
  V: Double;
  FS: TFormatSettings;
  IsPercent: Boolean;
begin
  Result := -1;
  T := Trim(S);
  if T = '' then Exit;

  IsPercent := False;
  if T[Length(T)] = '%' then
  begin
    IsPercent := True;
    SetLength(T, Length(T) - 1);
    T := Trim(T);
  end;

  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  T := StringReplace(T, ',', '.', [rfReplaceAll]);
  if not TryStrToFloat(T, V, FS) then Exit;

  if IsPercent or (V > 5) then
    V := V / 100;

  if V < 0 then Exit;
  if V > 5 then V := 5;  { санитарный потолок 500% FTP }
  Result := V;
end;

function TViewWorkoutEditor.FormatDur(D: Single): String;
var
  Total, M, S: Integer;
begin
  Total := Max(0, Round(D));
  M := Total div 60;
  S := Total mod 60;
  Result := Format('%d:%.2d', [M, S]);
end;

function TViewWorkoutEditor.FormatPwr(P: Single): String;
begin
  Result := Format('%d%%', [Round(P * 100)]);
end;

{ Save As: генерируем «<original>_copy.zwo» в той же категории. }
function TViewWorkoutEditor.GenerateSaveAsUrl: String;
var
  Path, Dir, Base, Ext, Cand: String;
  N: Integer;
begin
  Result := '';
  Path := URIToFilenameSafe(FOriginalUrl);
  if Path='' then Path:='workout.zwo';
  if Path = '' then Exit;

  Dir := UserDataDir+'workouts'+PathDelim;
  Base := ChangeFileExt(ExtractFileName(Path), '');
  Ext := ExtractFileExt(Path);
  if Ext = '' then Ext := '.zwo';

  Cand := Dir + Base + '_copy' + Ext;
  N := 2;
  while FileExists(Cand) do
  begin
    Cand := Dir + Base + '_copy' + IntToStr(N) + Ext;
    Inc(N);
    if N > 100 then Exit;  { защита от бесконечного цикла }
  end;

  Result := FilenameToURISafe(Cand);
end;

procedure TViewWorkoutEditor.SaveDraft;
var CopyPlan:TWorkoutFile;
begin
  if(FWorkout=nil)or not FWorkout.Modified or(FDraftUrl='')then Exit;
  CopyPlan:=FWorkout.Clone;
  try
    if CopyPlan.SaveToUrl(FDraftUrl)then FDraftPending:=False;
  finally CopyPlan.Free;end;
end;
procedure TViewWorkoutEditor.Update(const SecondsPassed:Single;var HandleInput:Boolean);
begin
  inherited;
  if(FMoreMetadata<>nil)and((Abs(FLayoutWidth-EffectiveWidth)>1)or
    (Abs(FLayoutScale-Max(0.5,Min(1,UIScale)))>0.001)or
    (Abs(FLayoutFlowHeight-FToolbar.Height-FPalette.Height-FStepActions.Height)>0.1))then Resize;
  if FDraftPending then begin
    FDraftDelay:=FDraftDelay-SecondsPassed;
    if FDraftDelay<=0 then begin FDraftDelay:=5;SaveDraft;end;
  end;
end;
procedure TViewWorkoutEditor.DoStartWorkout(Sender:TObject);
begin
  if FWorkout=nil then Exit;DoSave(nil);
  if FWorkout.Modified then Exit;
  ViewMenu.StartEditorWorkout(FWorkout,EffectiveRiderProfile.FtpW);
  ViewMenu.CloseChildView(Self,'training');
end;
procedure TViewWorkoutEditor.DoUndo(Sender:TObject);
begin
  if FUndoStates.Count<2 then Exit;
  FUndoStates.Delete(FUndoStates.Count-1);
  FChart.SetWorkout(nil);FWorkout.Free;FWorkout:=FUndoStates[FUndoStates.Count-1].Clone;
  LoadFromWorkout;FWorkout.Modified:=True;FDraftPending:=True;FDraftDelay:=1.5;
  FButtonUndo.Enabled:=FUndoStates.Count>1;
end;

end.
