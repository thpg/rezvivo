{ RideEmulator — эмуляция прохождения записанного заезда виртуальным
  райдером по ВСЕМ режимам источника уклона, ОДНОВРЕМЕННО (один цикл
  времени шагает все симуляции параллельно, а не прогоняет их по очереди).

  Зачем: геометрия виртуального мира расходится с реальной, и игра может
  брать уклон для физики/тренажёра по-разному. Прежде чем выбирать режим
  в живой езде, кнопка «Полная статистика» прогоняет заезд всеми режимами
  и показывает, каким получится время/скорость/работа против реальных.

  Режимы (TEmuMode):
    emGame      — уклон из геометрии мира вдоль пути (как игра едет сейчас).
                  Динамика режима ERG (целевая мощность на тренажёре)
                  СОВПАДАЕТ с этим режимом: ERG меняет команду тренажёру,
                  а не физику аватара — при воспроизведении мощности из FIT
                  разницы нет, отдельной строки не заслуживает.
    emRealSlope — подмена: уклон реального заезда (сглаженное баро) по
                  дистанции, геометрия мира игнорируется.
    emDelta     — плавная поправка: уклон мира + сглаженная (±DELTA_HALF_M)
                  разница «реальность − мир». В мелком масштабе ощущения
                  следуют картинке, в крупном — реальности.
    emIntegral  — интегральная: уклон мира + поправка от накопленного
                  дефицита набора высоты (реальный ∫grade·ds против
                  применённого). Гарантирует сходимость работы, мгновенная
                  форма может отставать.

  Мощность на входе — ИЗ FIT: канал power, если он есть; иначе
  реконструкция из раскладки сил оценщика (RideParamEstimator) на
  подобранных параметрах — (Fграв+Fкач+Fаэро+Fинерц)·v, класс наката/
  торможения/стоянки даёт 0. Реальные торможения воспроизводятся силой
  FBrakeN по дистанции — иначе все режимы летели бы в повороты быстрее
  человека и сравнение времён было бы бессмысленным.

  Физика шага — БУКВАЛЬНО игровая ComputeCyclingAcceleration из
  gamephysicscommon (с её ограничениями и фактическим шагом времени): смысл
  эмуляции — предсказать поведение ИГРЫ, а не абстрактной модели.
  CdA передаётся как Cd при Area=1 (формула их перемножает).

  Стоянки FIT пропускаются: точки, где реальный райдер стоял (и сырая
  скорость, и сглаженная оценщика < STOP_V_MS), выкидываются из рабочей
  сетки — как будто райдер ехал постоянно, без остановок. Торможение и
  разгон вокруг стоянки остаются — это езда, а не стоянка. Разрывы
  записи длиннее GAP_STOP_S (датчик выключен/пауза) — тоже стоянки,
  независимо от скоростей на концах: «время заезда» считается по
  реальному времени езды, а не по разности меток первой/последней
  точки (как в заголовке файла). Эталонное время — ходовое (полное
  минус сумма стоянок), возвращается в AMovingTimeSec. Подпор
  Непроходимый при записанной мощности участок завершает расчёт по
  ограничению времени с Finished=False, без искусственного движения.

  Калибровка (ACalibrate): перед прогоном режимов тройка (m, CdA, Crr)
  подгоняется Nelder–Mead'ом так, чтобы режим emRealSlope (реальные
  мощность + уклон + тормоза) воспроизводил заезд с минимальной ошибкой
  (J = RMSv + |Δ средней скорости|, м/с). Смысл: оценщик подбирает
  параметры поточечной алгеброй сил, а эмулятор — интегратор; подгонка
  через сам интегратор делает «подмену» эталонной (ошибка → минимум),
  а сравнение остальных режимов — честным. Координаты — множители к
  стартовой тройке оценщика, физические пределы зажаты. }

unit RideEmulator;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math,
  RideParamEstimator,   { TRideSampleArray, TRidePointResultArray, RIDE_NO_VALUE }
  gamephysicscommon;    { ComputeCyclingAcceleration — ровно игровая формула }

type
  TEmuMode = (emGame, emRealSlope, emDelta, emIntegral);

  TEmuResult = record
    Mode:        TEmuMode;
    Finished:    Boolean;   { False = не доехал за кап времени (3×ходовое+10 мин) }
    TimeSec:     Double;
    AvgSpeedKmh: Double;
    MaxSpeedKmh: Double;
    WorkKJ:      Double;    { ∫P·dt по применённой мощности }
    ClimbAppliedM: Double;  { набор по ПРИМЕНЁННОМУ уклону — что «прожито» }
    RmsSpeedVsRealMs: Double; { RMS(v_sim − v_real) по времени симуляции }
  end;
  TEmuResultArray = array of TEmuResult;

const
  EMU_MODE_NAMES: array[TEmuMode] of string = (
    'Геометрия игры (как сейчас; = ERG)',
    'Реальный уклон (подмена)',
    'Плавная поправка Δ',
    'Интегральная (по работе)');

  { Константы режима emIntegral и поправки Δ — в interface: их разделяет
    и полная эмуляция (RideFullEmulator), дублировать значения нельзя. }
  EMU_DELTA_CLAMP  = 0.06;   { |Δ| и |интегральная поправка| ≤ 6% }
  EMU_SLEW_PER_SEC = 0.01;   { скорость изменения поправки: 1%/с }
  EMU_INT_GAIN_M   = 50.0;   { дефицит набора размазывается на 50 м пути }

type
  { Общий прекомпьют обоих эмуляторов (1D и полного): компактная сетка
    дистанций без стоянок FIT, скорость/мощность/тормоза реального
    заезда, уклоны режимов и профили высот. Индексы всех массивов
    параллельны S (0..N-1); Keep — компактный индекс → исходный. }
  TRideChannels = record
    N: Integer;
    SEnd, RealDur: Double;
    MovingDur, StopDur: Double;
    StopCnt: Integer;
    S, VR, PW, FBr: array of Double;
    GFit, GVirt, DeltaG: array of Double;
    AWorld, AFit: array of Double;
    Keep: array of Integer;
    { Ходовое время (без стоянок) на каждый узел компактной сетки —
      ось временной подачи каналов (Tau[N-1] = MovingDur). Сейчас не
      используется: обе эмуляции подают каналы по дистанции; оставлено
      как готовая ось на случай временной подачи. }
    Tau: array of Double;
  end;

{ Подготовить каналы заезда для эмуляции: монотонизация одометра,
  скорость с фолбэком, пропуск стоянок (Keep), мощность (канал power ×
  КПД либо реконструкция из раскладки сил) и тормоза из FIT, уклон
  реальный (оценщик) и мира (сглаженный ±30 м профиль AVirtAlt),
  поправка Δ (сглаженная ±100 м разница, кламп 6%), профили высот
  мира и FIT. False — данных не хватает (Note объясняет). }
function PrepareRideChannels(
  const Samples: TRideSampleArray;
  const PtsFit:  TRidePointResultArray;
  const AVirtAlt: array of Double;
  ADrivetrainEff: Double;
  out Ch: TRideChannels;
  out Note: string): Boolean;

{ Прогнать все режимы. Массивы параллельны Samples (одна точка FIT = один
  индекс): PtsFit — результат оценщика по FIT-высоте (уклон/классы/тормоза),
  AVirtAlt — высота МИРА вдоль маршрута (дорога, если снап есть, иначе
  поверхность). ADrivetrainEff — КПД из конфига оценщика (мощность FIT →
  колесо). MassKg/CdA/Crr — стартовые параметры райдера (из оценщика); при
  ACalibrate=True они подгоняются Nelder–Mead'ом по режиму emRealSlope и
  возвращаются откалиброванными (CalReport — блок для панели, иначе '').
  Стоянки FIT пропускаются (см. шапку): в AMovingTimeSec возвращается
  ходовое время заезда (полное минус стоянки) — эталон для колонки Δ.
  False = данных не хватает (Note объясняет). }
function EmulateRideModes(
  const Samples: TRideSampleArray;
  const PtsFit:  TRidePointResultArray;
  const AVirtAlt: array of Double;
  var MassKg, CdA, Crr: Double;
  ADrivetrainEff: Double;
  ACalibrate: Boolean;
  out Results: TEmuResultArray;
  out AMovingTimeSec: Double;
  out CalReport: string;
  out Note: string): Boolean;

{ Готовый текстовый блок для панели оценки. ARealTimeSec — ходовое время
  заезда без стоянок (для колонки Δ). AHeader = '' → заголовок по
  умолчанию; полная эмуляция (RideFullEmulator) передаёт свой — строки
  режимов форматируются здесь же, без дублирования. }
function FormatEmuResults(const R: TEmuResultArray;
  ARealTimeSec: Double; const AHeader: string = ''): string;

implementation

const
  DT_SEC        = 0.2;    { bounded implicit step; transient acceleration is
                            more damped than the game's 1/60 s step }
  SMOOTH_HALF_M = 30.0;   { полуокно сглаживания высоты мира (как AltWindowM
                            оценщика по порядку — профили сопоставимы) }
  DELTA_HALF_M  = 100.0;  { полуокно сглаживания поправки Δ (emDelta) }
  DELTA_CLAMP   = EMU_DELTA_CLAMP;   { значения — в interface (их разделяет
    RideFullEmulator); здесь только локальные алиасы прежних имён }
  SLEW_PER_SEC  = EMU_SLEW_PER_SEC;
  INT_GAIN_M    = EMU_INT_GAIN_M;
  GRADE_ABS_MAX = 0.30;   { кламп уклона перед ArcSin }
  STOP_V_MS     = 0.5;    { реальная скорость ниже — стоянка FIT:
                            точка выкидывается из сетки (см. шапку) }
  GAP_STOP_S    = 60.0;   { разрыв записи дольше — пауза независимо от
                            скоростей на концах (ночёвка с выключенным
                            датчиком: дыры в треке не накручивают
                            «ходовое время» — см. расчёт по реальному
                            времени езды, не по времени из заголовка) }
  NM_MAX_EVALS  = 90;     { кап оценок Nelder–Mead (одна оценка ≈ прогон
                            emRealSlope — миллисекунды на типовом заезде) }
  NM_STEP0      = 0.10;   { стартовый шаг симплекса (доля от тройки) }
  NM_FTOL       = 1e-4;   { сходимость по разбросу значений симплекса }

type
  TVec3 = array[0..2] of Double;

  TSimState = record
    v, s, t:   Double;
    Work:      Double;
    MaxV:      Double;
    Climb:     Double;
    RmsAcc:    Double;
    CInt:      Double;    { emIntegral: накопленный дефицит набора, м }
    GApplied:  Double;    { последний применённый уклон (slew emIntegral) }
    Cursor:    Integer;   { индекс левого узла сетки дистанций }
    Active:    Boolean;
    Finished:  Boolean;
  end;

{ Дельта времени в минутах со знаком («+»/«−») для отчёта калибровки. }
function SignedMin(ASec: Double): string;
begin
  if ASec >= 0 then Result := Format('+%.1f', [ASec / 60])
  else Result := Format('−%.1f', [-ASec / 60]);
end;

{ ── Общий прекомпьют эмуляторов (1D и полного) ───────────────────────
  Код тот же, что был телом EmulateRideModes до разделения: сетка
  дистанций, скорость с фолбэком, пропуск стоянок FIT, мощность и
  тормоза из FIT, уклоны GFit/GVirt, поправка Δ, профили высот мира и
  FIT. Ничего не знает о режимах прогона — только готовит каналы. }
function PrepareRideChannels(
  const Samples: TRideSampleArray;
  const PtsFit:  TRidePointResultArray;
  const AVirtAlt: array of Double;
  ADrivetrainEff: Double;
  out Ch: TRideChannels;
  out Note: string): Boolean;
var
  N, I, K, J0, J1: Integer;
  S, VR, VirtSm, TauS: array of Double;
  Acc, WSum, FSum, MT: Double;
  NK: Integer;
  InStop, IsStop: Boolean;
begin
  Result := False;
  Note := '';
  FillChar(Ch, SizeOf(Ch), 0);
  N := Length(Samples);
  if (N < 10) or (Length(PtsFit) <> N) or (Length(AVirtAlt) <> N) then
  begin
    Note := 'эмуляция пропущена: каналы разной длины или мало точек';
    Exit;
  end;

  { ── Сетка дистанций (монотонизация на всякий случай) ── }
  SetLength(S, N);
  S[0] := Samples[0].DistanceM;
  for I := 1 to N - 1 do
  begin
    S[I] := Samples[I].DistanceM;
    if S[I] < S[I - 1] then S[I] := S[I - 1];
  end;
  Ch.SEnd := S[N - 1];
  Ch.RealDur := Samples[N - 1].TimeSec - Samples[0].TimeSec;
  if (Ch.SEnd < 100) or (Ch.RealDur < 30) then
  begin
    Note := 'эмуляция пропущена: слишком короткий заезд';
    Exit;
  end;

  { ── Скорость реального заезда (фолбэк из одометрии) ── }
  SetLength(VR, N);
  for I := 0 to N - 1 do
  begin
    if Samples[I].SpeedMs > RIDE_NO_VALUE * 0.5 then
      VR[I] := Samples[I].SpeedMs
    else
    begin
      J0 := Max(0, I - 1); J1 := Min(N - 1, I + 1);
      if Samples[J1].TimeSec > Samples[J0].TimeSec then
        VR[I] := (S[J1] - S[J0]) / (Samples[J1].TimeSec - Samples[J0].TimeSec)
      else
        VR[I] := 0;
    end;
    if VR[I] < 0 then VR[I] := 0;
  end;

  { ── Пропуск стоянок FIT: райдер едет постоянно, без остановок ──
    Точка — стоянка, если И сырая скорость (VR, с фолбэком одометрии),
    И сглаженная скорость оценщика ниже STOP_V_MS. Такие точки
    выкидываем из рабочей сетки: симуляция проезжает эти места без
    остановки, а эталонное время становится ходовым. }
  SetLength(Ch.Keep, N);
  SetLength(TauS, N);
  NK := 0;
  Ch.StopDur := 0;
  Ch.StopCnt := 0;
  InStop := False;
  MT := 0;
  TauS[0] := 0;
  for I := 0 to N - 1 do
  begin
    IsStop := (VR[I] < STOP_V_MS) and (PtsFit[I].SpeedMs < STOP_V_MS);
    { Разрыв записи (датчик выключен/пауза на датчике) — пауза всегда,
      даже если скорости на концах разрыва ненулевые: иначе ночёвки
      между записями целиком ложатся в «ходовое время» (реальный случай:
      38.85 км «ехали» 46:09:00). }
    if (I > 0) and
       (Samples[I].TimeSec - Samples[I - 1].TimeSec > GAP_STOP_S) then
      IsStop := True;
    if IsStop then
    begin
      if I > 0 then
        Ch.StopDur := Ch.StopDur + (Samples[I].TimeSec - Samples[I - 1].TimeSec);
      if not InStop then
      begin
        Inc(Ch.StopCnt);
        InStop := True;
      end;
    end
    else
    begin
      Ch.Keep[NK] := I;
      Inc(NK);
      InStop := False;
    end;
    { Ходовое время по образцам: переход считается, если конечная точка
      не стоянка — в сумме даёт ровно MovingDur. }
    if (I > 0) and (not IsStop) then
      MT := MT + (Samples[I].TimeSec - Samples[I - 1].TimeSec);
    TauS[I] := MT;
  end;
  Ch.MovingDur := (Samples[N - 1].TimeSec - Samples[0].TimeSec) - Ch.StopDur;
  if Ch.MovingDur < 1 then Ch.MovingDur := 1;
  if NK < 10 then
  begin
    Note := 'эмуляция пропущена: после пропуска стоянок мало точек';
    Exit;
  end;
  SetLength(Ch.Keep, NK);

  { Компактная сетка: дистанция/скорость и профили высот — только по
    оставшимся точкам. AFit — баро-высота FIT (Samples[].AltM). }
  SetLength(Ch.S, NK);
  SetLength(Ch.VR, NK);
  SetLength(Ch.AWorld, NK);
  SetLength(Ch.AFit, NK);
  SetLength(Ch.Tau, NK);
  for I := 0 to NK - 1 do
  begin
    Ch.S[I] := S[Ch.Keep[I]];
    Ch.VR[I] := VR[Ch.Keep[I]];
    Ch.AWorld[I] := AVirtAlt[Ch.Keep[I]];
    Ch.AFit[I] := Samples[Ch.Keep[I]].AltM;
    Ch.Tau[I] := TauS[Ch.Keep[I]];
  end;
  Ch.N := NK;

  { ── Мощность на колесе по дистанции ──
    Канал power (× КПД) либо реконструкция из раскладки сил оценщика.
    Классы наката/торможения/стоянки дают 0 в обоих путях. }
  SetLength(Ch.PW, NK);
  SetLength(Ch.FBr, NK);
  for I := 0 to NK - 1 do
  begin
    Ch.FBr[I] := Max(0.0, PtsFit[Ch.Keep[I]].FBrakeN);
    if PtsFit[Ch.Keep[I]].PointClass in [rpcCoast, rpcBrake, rpcExcluded] then
      Ch.PW[I] := 0
    else if Samples[Ch.Keep[I]].PowerW > RIDE_NO_VALUE * 0.5 then
      Ch.PW[I] := Max(0.0, Samples[Ch.Keep[I]].PowerW * ADrivetrainEff)
    else
    begin
      FSum := PtsFit[Ch.Keep[I]].FGravityN + PtsFit[Ch.Keep[I]].FRollingN
            + PtsFit[Ch.Keep[I]].FAeroN + PtsFit[Ch.Keep[I]].FInertiaN;
      Ch.PW[I] := Max(0.0, FSum * Max(0.0, PtsFit[Ch.Keep[I]].SpeedMs));
    end;
  end;

  { ── Уклоны: реальный — готовый из оценщика; мира — из высот вдоль
    маршрута, сглаженных тем же порядком окна, центральная разность ── }
  SetLength(Ch.GFit, NK);
  for I := 0 to NK - 1 do
    Ch.GFit[I] := EnsureRange(PtsFit[Ch.Keep[I]].Grade,
                              -GRADE_ABS_MAX, GRADE_ABS_MAX);

  SetLength(VirtSm, NK);
  for I := 0 to NK - 1 do
  begin
    Acc := 0; WSum := 0;
    J0 := I; J1 := I;
    while (J0 > 0)      and (Ch.S[I] - Ch.S[J0 - 1] <= SMOOTH_HALF_M) do Dec(J0);
    while (J1 < NK - 1) and (Ch.S[J1 + 1] - Ch.S[I] <= SMOOTH_HALF_M) do Inc(J1);
    for K := J0 to J1 do
    begin
      Acc := Acc + Ch.AWorld[K];
      WSum := WSum + 1;
    end;
    VirtSm[I] := Acc / WSum;
  end;
  SetLength(Ch.GVirt, NK);
  for I := 0 to NK - 1 do
  begin
    J0 := Max(0, I - 2); J1 := Min(NK - 1, I + 2);
    if Ch.S[J1] - Ch.S[J0] > 5.0 then
      Ch.GVirt[I] := EnsureRange(
        (VirtSm[J1] - VirtSm[J0]) / (Ch.S[J1] - Ch.S[J0]),
        -GRADE_ABS_MAX, GRADE_ABS_MAX)
    else
      Ch.GVirt[I] := 0;
  end;

  { ── Поправка Δ для emDelta: сглаженная разница профилей ── }
  SetLength(Ch.DeltaG, NK);
  for I := 0 to NK - 1 do
  begin
    Acc := 0; WSum := 0;
    J0 := I; J1 := I;
    while (J0 > 0)      and (Ch.S[I] - Ch.S[J0 - 1] <= DELTA_HALF_M) do Dec(J0);
    while (J1 < NK - 1) and (Ch.S[J1 + 1] - Ch.S[I] <= DELTA_HALF_M) do Inc(J1);
    for K := J0 to J1 do
    begin
      Acc := Acc + (Ch.GFit[K] - Ch.GVirt[K]);
      WSum := WSum + 1;
    end;
    Ch.DeltaG[I] := EnsureRange(Acc / WSum, -DELTA_CLAMP, DELTA_CLAMP);
  end;

  Result := True;
end;

function EmulateRideModes(
  const Samples: TRideSampleArray;
  const PtsFit:  TRidePointResultArray;
  const AVirtAlt: array of Double;
  var MassKg, CdA, Crr: Double;
  ADrivetrainEff: Double;
  ACalibrate: Boolean;
  out Results: TEmuResultArray;
  out AMovingTimeSec: Double;
  out CalReport: string;
  out Note: string): Boolean;
var
  Ch: TRideChannels;
  N: Integer;
  S, VR, PW, FBr, GFit, GVirt, DeltaG: array of Double;
  SEnd, TCap: Double;
  SimR: TEmuResult;
  M: TEmuMode;
  StopCnt: Integer;
  StopDur, MovingDur: Double;
  { калибровка: тройка «до» и её качество, число оценок NM }
  CalMassB, CalCdAB, CalCrrB: Double;
  CalRmsB, CalDtB: Double;
  CalEvals: Integer;

  { Левый узел сетки для дистанции ASim.s — курсор только вперёд
    (s монотонна), поиск амортизированно O(1). }
  procedure AdvanceCursor(var ASim: TSimState);
  begin
    while (ASim.Cursor < N - 2) and (S[ASim.Cursor + 1] <= ASim.s) do
      Inc(ASim.Cursor);
  end;

  { ── Один прогон режима по готовым каналам (сетка S без стоянок) ── }
  procedure RunMode(AM: TEmuMode; AMass, ACdA, ACrr, ATCap: Double;
    out RR: TEmuResult);
  var
    St: TSimState;
    gg, SlopeDeg, aa, dvv, dss: Double;
    II: Integer;
  begin
    FillChar(St, SizeOf(St), 0);
    { The retained FIT may begin while already coasting. Use its measured
      initial speed once; subsequent speed is determined only by physics. }
    if (Length(VR)>0) and not IsNan(VR[0]) and not IsInfinite(VR[0]) then
      St.v := EnsureRange(VR[0],0.0,Double(MaxSpeed));
    St.MaxV := St.v;
    repeat
      AdvanceCursor(St);
      II := St.Cursor;

      { уклон режима }
      case AM of
        emGame:      gg := GVirt[II];
        emRealSlope: gg := GFit[II];
        emDelta:     gg := GVirt[II] + DeltaG[II];
        emIntegral:
          begin
            gg := GVirt[II] + EnsureRange(St.CInt / INT_GAIN_M,
                                          -DELTA_CLAMP, DELTA_CLAMP);
            { плавность: не быстрее SLEW_PER_SEC }
            gg := EnsureRange(gg,
                   St.GApplied - SLEW_PER_SEC * DT_SEC,
                   St.GApplied + SLEW_PER_SEC * DT_SEC);
          end;
      end;
      gg := EnsureRange(gg, -GRADE_ABS_MAX, GRADE_ABS_MAX);
      St.GApplied := gg;
      SlopeDeg := RadToDeg(ArcSin(gg));   { Grade = sinθ (дистанция — путь) }

      { игровая формула + реальное торможение по дистанции }
      aa := ComputeCyclingAcceleration(
             PW[II], St.v, AMass, ACdA, 1.0, ACrr, SlopeDeg, DT_SEC,
             0, MaxSpeed, FBr[II]);

      St.v := St.v + aa * DT_SEC;
      if St.v < 0 then St.v := 0;

      dss := St.v * DT_SEC;
      St.s := St.s + dss;
      St.t := St.t + DT_SEC;
      St.Work := St.Work + PW[II] * DT_SEC;
      if St.v > St.MaxV then St.MaxV := St.v;
      if gg > 0 then St.Climb := St.Climb + gg * dss;
      if AM = emIntegral then
        St.CInt := St.CInt + (GFit[II] - gg) * dss;
      dvv := St.v - VR[II];
      St.RmsAcc := St.RmsAcc + dvv * dvv * DT_SEC;

      if St.s >= SEnd then St.Finished := True;
    until St.Finished or (St.t > ATCap);

    RR.Mode     := AM;
    RR.Finished := St.Finished;
    RR.TimeSec  := St.t;
    if St.t > 1 then
      RR.AvgSpeedKmh := (St.s / St.t) * 3.6
    else
      RR.AvgSpeedKmh := 0;
    RR.MaxSpeedKmh := St.MaxV * 3.6;
    RR.WorkKJ      := St.Work / 1000.0;
    RR.ClimbAppliedM := St.Climb;
    if St.t > 1 then
      RR.RmsSpeedVsRealMs := Sqrt(St.RmsAcc / St.t)
    else
      RR.RmsSpeedVsRealMs := 0;
  end;

  { ── Калибровка (m, CdA, Crr) Nelder–Mead'ом по emRealSlope ──
    Координаты — множители к стартовой тройке оценщика (нормировка снимает
    разницу масштабов параметров). Цель J = RMSv + |Δ средней скорости|
    в м/с: совпадение и по форме траектории, и по итоговому времени.
    Обновляет var-параметры MassKg/CdA/Crr лучшей найденной тройкой;
    «до»-статистику пишет в CalRmsB/CalDtB, число оценок — в CalEvals. }
  procedure Calibrate;
  var
    Mass0, CdA0, Crr0: Double;
    RB: TEmuResult;
    X: array[0..3] of TVec3;
    F: array[0..3] of Double;
    II, JJ: Integer;
    Cent, XR, XE, XC: TVec3;
    FR, FE, FC: Double;
    Accepted: Boolean;

    function Obj(const XX: TVec3): Double;
    var
      Pm, Pc, Pr: Double;
      RR: TEmuResult;
    begin
      Pm := Mass0 * XX[0]; Pc := CdA0 * XX[1]; Pr := Crr0 * XX[2];
      if (Pm < 40) or (Pm > 150) or (Pc < 0.15) or (Pc > 0.6)
         or (Pr < 0.002) or (Pr > 0.03) then
        Exit(1.0e6);   { вне физических пределов — запрет }
      RunMode(emRealSlope, Pm, Pc, Pr, TCap, RR);
      Inc(CalEvals);
      if not RR.Finished then
        Exit(1.0e5);   { не доехал — хуже любого доехавшего }
      Result := RR.RmsSpeedVsRealMs
              + Abs(SEnd / RR.TimeSec - SEnd / MovingDur);
    end;

    procedure SortSimplex;   { по возрастанию F: [0] лучшая, [3] худшая }
    var
      A, B: Integer;
      TF: Double;
      TX: TVec3;
    begin
      for A := 1 to 3 do
      begin
        B := A;
        while (B > 0) and (F[B] < F[B - 1]) do
        begin
          TF := F[B]; F[B] := F[B - 1]; F[B - 1] := TF;
          TX := X[B]; X[B] := X[B - 1]; X[B - 1] := TX;
          Dec(B);
        end;
      end;
    end;

  begin
    Mass0 := MassKg; CdA0 := CdA; Crr0 := Crr;
    CalEvals := 0;

    { «до»: прогон на стартовой тройке (в счёт оценок NM не входит) }
    RunMode(emRealSlope, Mass0, CdA0, Crr0, TCap, RB);
    CalRmsB := RB.RmsSpeedVsRealMs;
    CalDtB  := RB.TimeSec - MovingDur;

    { стартовый симплекс: (1,1,1) + шаги NM_STEP0 по осям }
    X[0][0] := 1; X[0][1] := 1; X[0][2] := 1;
    for II := 1 to 3 do
    begin
      X[II] := X[0];
      X[II][II - 1] := 1 + NM_STEP0;
    end;
    for II := 0 to 3 do F[II] := Obj(X[II]);

    repeat
      SortSimplex;
      if (CalEvals >= NM_MAX_EVALS) or (F[3] - F[0] < NM_FTOL) then Break;

      { центроид всех, кроме худшей }
      for JJ := 0 to 2 do
        Cent[JJ] := (X[0][JJ] + X[1][JJ] + X[2][JJ]) / 3;

      { отражение (α=1) }
      for JJ := 0 to 2 do XR[JJ] := 2 * Cent[JJ] - X[3][JJ];
      FR := Obj(XR);

      if FR < F[0] then
      begin
        { растяжение (γ=2) }
        for JJ := 0 to 2 do XE[JJ] := Cent[JJ] + 2 * (XR[JJ] - Cent[JJ]);
        FE := Obj(XE);
        if FE < FR then begin X[3] := XE; F[3] := FE; end
                   else begin X[3] := XR; F[3] := FR; end;
      end
      else if FR < F[2] then
      begin
        X[3] := XR; F[3] := FR;
      end
      else
      begin
        { сжатие (ρ=0.5): внешнее, если отражение лучше худшей, иначе внутреннее }
        Accepted := False;
        if FR < F[3] then
        begin
          for JJ := 0 to 2 do XC[JJ] := Cent[JJ] + 0.5 * (XR[JJ] - Cent[JJ]);
          FC := Obj(XC);
          if FC <= FR then begin X[3] := XC; F[3] := FC; Accepted := True; end;
        end
        else
        begin
          for JJ := 0 to 2 do XC[JJ] := Cent[JJ] + 0.5 * (X[3][JJ] - Cent[JJ]);
          FC := Obj(XC);
          if FC < F[3] then begin X[3] := XC; F[3] := FC; Accepted := True; end;
        end;
        if not Accepted then
          { глобальное сжатие к лучшей (σ=0.5) }
          for II := 1 to 3 do
          begin
            for JJ := 0 to 2 do
              X[II][JJ] := X[0][JJ] + 0.5 * (X[II][JJ] - X[0][JJ]);
            F[II] := Obj(X[II]);
          end;
      end;
    until False;

    SortSimplex;
    MassKg := Mass0 * X[0][0];
    CdA    := CdA0 * X[0][1];
    Crr    := Crr0 * X[0][2];
  end;

begin
  Result := False;
  SetLength(Results, 0);
  Note := '';
  CalReport := '';
  AMovingTimeSec := 0;
  if (MassKg < 30) or (CdA <= 0) or (Crr <= 0) then
  begin
    Note := 'эмуляция пропущена: параметры райдера не определены';
    Exit;
  end;
  if ADrivetrainEff <= 0 then ADrivetrainEff := 1.0;

  { Общий прекомпьют (сетка без стоянок, мощность/тормоза из FIT,
    уклоны режимов, поправка Δ) — разделяется с полной эмуляцией
    (RideFullEmulator), дублировать код нельзя. }
  if not PrepareRideChannels(Samples, PtsFit, AVirtAlt, ADrivetrainEff,
       Ch, Note) then
    Exit;

  { Каналы — в локальные переменные: вложенные RunMode/Calibrate
    захватывают их по имени. }
  N := Ch.N;
  S := Ch.S; VR := Ch.VR; PW := Ch.PW; FBr := Ch.FBr;
  GFit := Ch.GFit; GVirt := Ch.GVirt; DeltaG := Ch.DeltaG;
  SEnd := Ch.SEnd;
  MovingDur := Ch.MovingDur;
  StopDur := Ch.StopDur;
  StopCnt := Ch.StopCnt;
  AMovingTimeSec := MovingDur;

  TCap := MovingDur * 3.0 + 600.0;

  { ── Калибровка параметров по режиму подмены ──
    До прогона режимов: «подмена» на честных параметрах обязана
    воспроизводить заезд почти точно; что останется — предел модели. }
  if ACalibrate then
  begin
    CalMassB := MassKg; CalCdAB := CdA; CalCrrB := Crr;
    Calibrate;
  end;

  { ── Финальный прогон всех режимов (на откалиброванных параметрах,
    если калибровка была) ── }
  SetLength(Results, Ord(High(TEmuMode)) + 1);
  for M := Low(TEmuMode) to High(TEmuMode) do
  begin
    RunMode(M, MassKg, CdA, Crr, TCap, SimR);
    Results[Ord(M)] := SimR;
  end;

  Note := Format('мощность/тормоза из FIT по дистанции; стоянки FIT '
    + 'пропущены (%d шт, %.0f с); физика — игровая '
    + 'формула, параметры m=%.1f кг, CdA=%.3f, Crr=%.4f',
    [StopCnt, StopDur, MassKg, CdA, Crr]);

  if ACalibrate then
    CalReport := Format(
      '══ Калибровка по реальному уклону (Nelder–Mead, %d оценок) ══'
      + LineEnding
      + '  оценщик: m=%.1f кг, CdA=%.3f, Crr=%.4f → RMSv %.2f м/с, Δ %s мин'
      + LineEnding
      + '  эмулятор: m=%.1f кг, CdA=%.3f, Crr=%.4f → RMSv %.2f м/с, Δ %s мин'
      + LineEnding,
      [CalEvals,
       CalMassB, CalCdAB, CalCrrB, CalRmsB, SignedMin(CalDtB),
       MassKg, CdA, Crr, Results[Ord(emRealSlope)].RmsSpeedVsRealMs,
       SignedMin(Results[Ord(emRealSlope)].TimeSec - MovingDur)]);
  Result := True;
end;

function FormatEmuResults(const R: TEmuResultArray;
  ARealTimeSec: Double; const AHeader: string = ''): string;

  function Hms(ASec: Double): string;
  var T: Integer;
  begin
    T := Round(ASec);
    if T >= 3600 then
      Result := Format('%d:%.2d:%.2d', [T div 3600, (T div 60) mod 60, T mod 60])
    else
      Result := Format('%d:%.2d', [T div 60, T mod 60]);
  end;

  function DeltaStr(ASec: Double): string;
  begin
    if ASec >= 0 then Result := '+' + Hms(ASec)
    else Result := '−' + Hms(-ASec);
  end;

var
  I: Integer;
  L, H: string;
begin
  H := AHeader;
  if H = '' then
    H := '══ Эмуляция прохождения (мощность из FIT, без стоянок) ══';
  Result := H + LineEnding
    + Format('  Реальный заезд (ходовое время): %s', [Hms(ARealTimeSec)])
    + LineEnding;
  for I := 0 to High(R) do
  begin
    L := Format('  %-38s %s', [EMU_MODE_NAMES[R[I].Mode], Hms(R[I].TimeSec)]);
    if R[I].Finished then
      L := L + Format(' (%s)  ср %.1f  макс %.1f км/ч  %.0f кДж  '
             + 'набор %.0f м  RMSv %.2f м/с',
             [DeltaStr(R[I].TimeSec - ARealTimeSec),
              R[I].AvgSpeedKmh, R[I].MaxSpeedKmh, R[I].WorkKJ,
              R[I].ClimbAppliedM, R[I].RmsSpeedVsRealMs])
    else
      L := L + '  — НЕ ДОЕХАЛ (кап времени)';
    Result := Result + L + LineEnding;
  end;
end;

end.
