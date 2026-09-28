{ RideParamEstimator — оценка физических параметров райдера по реальному
  заезду (FIT-файл): масса (райдер+велосипед), CdA, Crr, детекция
  торможений, поточечная раскладка сил сопротивления.

  ═══ Физическая модель ═══════════════════════════════════════════════

  Баланс мощности (Martin et al., 1998) на каждой точке:

    η·P = v·[ m·g·sinθ + Crr·m·g·cosθ + m·(1+λ)·a + ½·ρ·CdA·v² ] + F_brake·v

  где  P — мощность с измерителя (Вт), η — КПД трансмиссии (~0.975),
       m — полная масса (кг), λ — надбавка на инерцию колёс (~0.012),
       a = dv/dt, θ — угол уклона, ρ — плотность воздуха,
       F_brake — сила торможения (=0 при честной езде).

  Дистанция FIT — длина пути (гипотенуза), поэтому sinθ = dh/ds точно.

  ═══ Репараметризация: задача линейна ════════════════════════════════

  Вводим x₁=m, x₂=m·Crr, x₃=CdA. Поточечная (силовая) форма:

    η·P/v = (g·sinθ + (1+λ)·a)·x₁ + (g·cosθ)·x₂ + (½·ρ·v²)·x₃   [Н]

  Поточечный уклон sinθ = dh/ds — производная шумного барометра, т.е.
  шум сидит в РЕГРЕССОРЕ (errors-in-variables) и смещает оценки
  (масса занижается, аэро перетекает в качение). Поэтому ПОДГОНКА
  ведётся в ИНТЕГРАЛЬНОЙ (энергетической) форме по окнам 10–20 с —
  идея virtual elevation Чанга:

    ∫η·P·dt = [g·Δh + (1+λ)·½·Δ(v²)]·x₁ + [g·∫v·cosθ·dt]·x₂
              + [½·∫ρ·v³·dt]·x₃                                  [Дж]

  ∫v·sinθ·dt = ∫dh телескопируется в РАЗНОСТЬ высот концов окна —
  дифференцирование высоты исчезает, шум только на двух точках.
  ∫v·a·dt = ½Δ(v²) — аналогично (концы окна берутся из СЫРОЙ скорости:
  её шум мал, а сглаженная смазана соседними торможениями). Окна
  режутся внутри непрерывных участков одного класса (педалирование /
  накат, ~25 с / ~8 с); дополнительно на каждый длинный участок
  ставится якорная строка на весь участок — длинная база Δh почти
  нечувствительна к дрейфу барометра и держит массу. b накатных = 0.

  ═══ Борьба со смещением от шума барометра (EIV) ═════════════════════

  Даже в оконной форме шум Δh (концы окна) сидит в столбце массы и
  через частичную коллинеарность (вниз — быстро, вверх — медленно)
  затухает её оценку: «масса вниз, CdA вниз, Crr вверх». Лечение —
  поправка Фуллера: из NE[0][0] вычитается известная дисперсия шума
  регрессора  Σw·g²·[ 2·σ²бел/N_сглаж + rw²·T_окна ].
  Белая σ² оценивается ИЗ ДАННЫХ (невязки высоты к лёгкому локальному
  сглаживанию ±AltEndpointWindowM). Скорость RW-дрейфа rw — свойство
  УСТРОЙСТВА (Cfg.BaroRwSigma, MEMS-барометры ~0.02–0.06 м/√с);
  занижение конфига возвращает часть смещения (2× вниз ≈ −3.5 кг на
  синтетике), кламп 70 % страхует от переоценки. Опционально дрейф
  моделируется кусочно-линейным сплайном во времени
  (Cfg.UseDriftSpline, для явно «плывущих» сенсоров); тогда rw-часть
  поправки гасится, чтобы не считать шум дважды.

  Мощность с головного устройства запаздывает относительно скорости
  (скользящее усреднение 1–3 с) — на ступеньках мощности это занижает
  массу. Лаг оценивается кросс-корреляцией η·P/v с кинематической
  силой m₀·((1+λ)a + g·sinθ) по сетке 0–4 с и компенсируется сдвигом
  канала мощности (интерполяция).

  Решается робастным IRLS (Huber) с раздельным масштабом шума для
  педалируемых и накатных окон и слабыми приорами (ridge) на случай
  вырожденных заездов (плоский равномерный → масса неопределима;
  честность оценки видна по CI95 и Est.MassPriorShare). Поточечная
  силовая форма используется для детекции торможений и выходной
  раскладки сил.

  Опционально (Cfg.EstimateWind + курс в сэмплах) — постоянный ветер:
    ½ρ·CdA·(v+w∥)² ≈ ½ρv²·x₃ + ρv·cos(hdg)·x₄ + ρv·sin(hdg)·x₅,
  x₄=CdA·Wx, x₅=CdA·Wy — система остаётся линейной (5 неизвестных).

  ═══ Детекция торможений ═════════════════════════════════════════════

  Тормоз — сила одного знака. На накатной строке невязка
    r = b − A·x = −A·x = F_brake   (Н, точно!)
  При честном выбеге r≈0; торможение даёт r >> 0. Итеративно:
  fit → r на накатах → runs r > max(порог, k·σ) длит. ≥ BrakeMinDurSec
  → вес 0, класс rpcBrake → refit. Сила и энергия торможения — прямой
  побочный результат.

  ═══ Использование ═══════════════════════════════════════════════════

    var S: TRideSampleArray; Est: TRideEstimate;
        Pts: TRidePointResultArray; Cfg: TRideEstimatorConfig;
    ...заполнить S из FIT (RIDE_NO_VALUE для отсутствующих полей)...
    Cfg := DefaultRideEstimatorConfig;
    Cfg.RiderProfileMassKg := 74;          // вес из профиля (может врать)
    if EstimateRideParameters(S, Cfg, Est, Pts) then
    begin
      WriteLn(FormatRideEstimate(Est));
      SaveRidePointsCsv(Pts, 'ride_points.csv');
    end;

  Юнит самодостаточен: только Classes, SysUtils, Math. }

unit RideParamEstimator;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math;

const
  { Sentinel «значения нет» для полей TRideSample. }
  RIDE_NO_VALUE = -1e9;

type
  { ── Входная точка заезда ──────────────────────────────────────────
    Все поля, кроме TimeSec, могут быть RIDE_NO_VALUE:
      SpeedMs   — восстановится из DistanceM;
      AltM      — без высоты оценка невозможна (уклон — половина физики);
      PowerW    — без мощности определимы только Crr и CdA/m;
      CadenceRpm— накат детектится по мощности;
      TempC     — плотность воздуха возьмётся по ISA;
      HeadingRad— курс движения (для оценки ветра), 0=восток, CCW. }
  TRideSample = record
    TimeSec:    Double;   { секунды от старта, монотонно возрастают }
    DistanceM:  Double;   { кумулятивная дистанция по пути, м }
    SpeedMs:    Double;   { скорость, м/с }
    AltM:       Double;   { абсолютная высота, м }
    PowerW:     Double;   { мощность, Вт }
    CadenceRpm: Double;   { каденс, об/мин }
    TempC:      Double;   { температура воздуха, °C }
    HeadingRad: Double;   { курс, рад (опционально, для ветра) }
  end;
  TRideSampleArray = array of TRideSample;

  { Классификация точки после анализа. }
  TRidePointClass = (
    rpcExcluded,   { не участвует: остановка, разрыв данных, переход }
    rpcPedal,      { педалирование — строка с b = η·P/v }
    rpcCoast,      { чистый накат — строка с b = 0 }
    rpcBrake);     { накат с торможением — исключена, F_brake оценена }

  { ── Поточечный результат ──────────────────────────────────────────
    Силы в Ньютонах, знак «+» = сопротивление движению
    (FInertiaN «+» = кинетическая энергия растёт, разгон). }
  TRidePointResult = record
    TimeSec:     Double;
    DistanceM:   Double;
    SpeedMs:     Double;   { сглаженная скорость }
    AccelMs2:    Double;   { сглаженное ускорение dv/dt }
    AltSmoothM:  Double;   { сглаженная высота }
    Grade:       Double;   { уклон dh/ds = sinθ (дистанция — длина пути) }
    AirDensity:  Double;   { кг/м³ }
    PointClass:  TRidePointClass;
    UsedInFit:   Boolean;
    FitWeight:   Double;   { итоговый IRLS-вес (0 = отброшена) }
    { Раскладка сил по подобранной модели: }
    FGravityN:   Double;   { m·g·sinθ }
    FRollingN:   Double;   { Crr·m·g·cosθ }
    RoadResistN: Double;   { FGravity + FRolling — «уклон + грунт» }
    FAeroN:      Double;   { ½·ρ·CdA·v² }
    FInertiaN:   Double;   { m·(1+λ)·a }
    FBrakeN:     Double;   { сила торможения (>0 только на rpcBrake) }
    FPedalN:     Double;   { η·P/v тяга на колесе (rpcPedal, иначе 0) }
    ResidualForceN: Double;{ b − A·x — невязка баланса, диагностика }
    ResidualPowerW: Double;{ то же × v }
    EffSlopePct: Double;   { 100·(sinθ + Crr·cosθ) — эффективный уклон
                             для воспроизведения дороги в виртуале }
  end;
  TRidePointResultArray = array of TRidePointResult;

  { ── Конфигурация ─────────────────────────────────────────────────── }
  TRideEstimatorConfig = record
    { Априори. Масса: профиль + велосипед, σ задаёт «недоверие профилю». }
    RiderProfileMassKg: Double;  { вес райдера из профиля }
    BikeMassGuessKg:    Double;  { априорная масса велосипеда (деф. 9) }
    MassPriorSigmaKg:   Double;  { деф. 8 — профиль может врать }
    CdAPrior:           Double;  { деф. 0.35 (шоссе, руки на пистолетах) }
    CdAPriorSigma:      Double;  { деф. 0.12 — слабый }
    CrrPrior:           Double;  { деф. 0.005 (асфальт) }
    CrrPriorSigma:      Double;  { деф. 0.004 — слабый }
    { Физика. }
    DrivetrainEff:      Double;  { деф. 0.975; измеритель во втулке → 1.0 }
    RotMassFactor:      Double;  { λ, деф. 0.012 }
    GravityMs2:         Double;  { деф. 9.81 }
    { Сглаживание. }
    AltWindowM:         Double;  { полуокно сглаживания высоты, м (35) }
    SpeedWindowSec:     Double;  { полуокно сглаживания скорости, с (2.5) }
    { Сегментация. }
    MinSpeedMs:         Double;  { ниже — точка исключается (2.0) }
    MinPedalPowerW:     Double;  { педалирование от, Вт (25) }
    CoastMaxPowerW:     Double;  { накат: мощность не выше, Вт (10) }
    CoastMinDurSec:     Double;  { мин. длительность наката, с (4) }
    CoastEdgeTrimSec:   Double;  { обрезка краёв наката, с (1.5) }
    MaxSampleGapSec:    Double;  { разрыв записи больше — точки рядом
                                   не годятся для ускорения (3.0) }
    { Окна энергетической подгонки. }
    PedalWindowSec:     Double;  { длина окна педалирования, с (20) }
    CoastWindowSec:     Double;  { длина окна наката, с (10) }
    MinWindowSec:       Double;  { короче — окно не используется (5) }
    AltEndpointWindowM: Double;  { лёгкое сглаживание высоты для
                                   концов окон, м (12) }
    BaroRwSigma:        Double;  { скорость RW-дрейфа барометра,
                                   м/√с (0.05). Свойство устройства:
                                   MEMS-барометры ~0.02–0.06. Входит в
                                   EIV-поправку и штраф сплайна.
                                   Недооценка → лёгкое смещение
                                   «масса вниз, Crr вверх», переоценка
                                   — наоборот (кламп 70% страхует) }
    UseDriftSpline:     Boolean; { моделировать дрейф сплайном (выкл).
                                   Вкл только при явном дрейфе сенсора;
                                   тогда RW-часть EIV-поправки гасится,
                                   чтобы не считать шум дважды }
    DriftKnotSec:       Double;  { шаг узлов дрейф-сплайна, с (120) }
    { Робастность / тормоза. }
    HuberK:             Double;  { деф. 1.345 }
    Iterations:         Integer; { IRLS-итераций (8) }
    BrakeForceMinN:     Double;  { абс. порог силы торможения, Н (12) }
    BrakeSigmaK:        Double;  { порог в сигмах накатного шума (3.0) }
    BrakeMinDurSec:     Double;  { мин. длительность торможения, с (1.5) }
    { Ветер. }
    EstimateWind:       Boolean; { деф. False; нужен HeadingRad }
    { Известный ветер (из панели/датчика). При WindKnown оценка ветра НЕ
      ведётся, аэро-член считается по заданному Va (квадратичная знаковая
      форма — на кольце не усредняется в ноль, в отличие от линейной). }
    WindKnown:          Boolean; { деф. False }
    WindKnownSpeedMs:   Double;  { скорость ветра, м/с }
    WindKnownFromRad:   Double;  { откуда дует, рад (0=восток, CCW) }
  end;

  { ── Итоговая статистика ──────────────────────────────────────────── }
  TRideEstimate = record
    Success:        Boolean;
    Message:        string;      { причина неудачи / предупреждения }
    { Параметры и 95% доверительные интервалы (аппроксимация). }
    MassKg:         Double;
    MassCi95:       Double;
    CdA:            Double;
    CdACi95:        Double;
    Crr:            Double;
    CrrCi95:        Double;
    WindSpeedMs:    Double;      { 0 если не оценивался }
    WindDirRad:     Double;      { направление, ОТКУДА дует }
    WindEstimated:  Boolean;
    { Идентифицируемость: доля информации о массе из приора (0..1).
      > 0.5 — заезд не позволяет определить массу (плоско/равномерно),
      результат по массе = фактически априорный. }
    MassPriorShare: Double;
    { Счётчики точек. }
    NumSamples:     Integer;
    NumPedal:       Integer;
    NumCoast:       Integer;
    NumBrake:       Integer;
    NumExcluded:    Integer;
    NumBrakeEvents: Integer;
    { Качество подгонки. }
    RmsPedalW:      Double;      { RMS невязки мощности на педалировании }
    RmsCoastN:      Double;      { RMS невязки силы на накате }
    { Энергоаудит, кДж (по всем классифицированным точкам). }
    EPedalKJ:       Double;      { ∫η·P dt }
    EAeroKJ:        Double;
    ERollKJ:        Double;
    EBrakeKJ:       Double;
    DeltaPeKJ:      Double;      { m·g·Δh }
    DeltaKeKJ:      Double;      { ½m(1+λ)Δv² }
    EResidKJ:       Double;      { невязка баланса }
    EResidPct:      Double;      { |невязка| / E_pedal · 100 }
    { Диагностика дрейфа барометра (модельная оценка). }
    BaroDriftRangeM: Double;     { размах d(t) за заезд, м }
    { Сводки по маршруту. }
    TotalDistKm:    Double;
    TotalTimeSec:   Double;
    AscentM:        Double;      { суммарный набор (по сглаж. высоте) }
    DescentM:       Double;
  end;

function DefaultRideEstimatorConfig: TRideEstimatorConfig;

{ Главная функция. Samples — как минимум TimeSec+DistanceM+AltM+PowerW.
  False + Est.Message при непригодных данных. }
function EstimateRideParameters(const Samples: TRideSampleArray;
  const Cfg: TRideEstimatorConfig;
  out Est: TRideEstimate;
  out Points: TRidePointResultArray): Boolean;

{ ── Оценка по МИНИМУМУ КОЛЕБАНИЙ параметров ──────────────────────────
  Не усредняет данные, а ищет (CdA, ветер), при которых оценка МАССЫ
  меньше всего колеблется между окнами заезда. Механизм: аэро ∝ v²·CdA;
  неверный CdA/ветер смещают аэро по-разному на быстрых и медленных
  окнах → выведенная масса «плывёт». Значения без колебаний = физически
  верные. Так вариация скорости по заезду разделяет аэро/массу/качение —
  чего глобальный МНК на плоском не может (Crr·m неразделимо). На 6
  реальных заездах разброс массы между заездами упал вчетверо (std 14→4
  кг), значения стали физичными. ALog (если задан) получает тайминги
  этапов пересчёта. }
type
  TRideEstLogProc = procedure(const AMsg: string) of object;

function EstimateRideMinVariance(const Samples: TRideSampleArray;
  const Cfg: TRideEstimatorConfig; ALog: TRideEstLogProc;
  out Est: TRideEstimate): Boolean;

{ ── Совместная оценка по НЕСКОЛЬКИМ заездам одного райдера ──
  Физика: масса и посадка (CdA) постоянны между заездами; качение
  (покрытие/давление шин) и ветер — свойства конкретного дня.
  Совместная линейная система:
    общие параметры: m, CdA;
    пер-заездные:    m·Crr_r  (+ CdA·Wx_r, CdA·Wy_r при наличии курса).
  Корреляция m↔m·Crr↔CdA внутри ОДНОГО заезда достигает −0.95
  («долина»): день паркует решение в своей точке долины — отсюда
  разброс массы между одиночными оценками. Долины разных дней
  (маршруты/скорости/ветра различны) пересекаются в одной точке —
  совместная оценка находит её без каких-либо фиксаций руками.
  Предобработка (лаг мощности, тормоза, окна, сигмы) — та же, что в
  одиночной оценке: оконные строки каждого заезда реюзаются как есть. }
type
  TMultiRideEstimate = record
    Valid: Boolean;
    Message: string;
    MassKg, MassCI95: Double;
    CdA, CdACI95: Double;
    RideCrr: array of Double;
    RideCrrCI95: array of Double;
    RideWindMs: array of Double;       { 0 — курса не было }
    RideWindDirRad: array of Double;   { откуда дует }
    NRides: Integer;
  end;

function EstimateMultiRideParameters(
  const ARides: array of TRideSampleArray;
  const Cfg: TRideEstimatorConfig;
  out MEst: TMultiRideEstimate): Boolean;

function FormatMultiRideEstimate(const MEst: TMultiRideEstimate): string;

{ Человекочитаемая сводка. }
function FormatRideEstimate(const Est: TRideEstimate): string;

{ CSV по точкам (для калибровки виртуальной езды). Разделитель ';',
  десятичная точка. True при успехе. }
function SaveRidePointsCsv(const Points: TRidePointResultArray;
  const FileName: string): Boolean;

implementation

const
  MAX_PARAMS = 5;

type
  TVecN = array [0..MAX_PARAMS - 1] of Double;
  TMatN = array [0..MAX_PARAMS - 1] of TVecN;
  TDVec = array of Double;
  TDMat = array of TDVec;

  { Внутреннее рабочее состояние точки. }
  TWorkPoint = record
    T, S, V, VRaw, A, Alt, AltLite, Grade, Rho: Double;
    NLite: Integer;              { точек в окне AltLite (дисперсия конца) }
    P, Cad: Double;
    SinT, CosT: Double;
    Heading: Double;
    HasHeading: Boolean;
    AccelValid: Boolean;         { соседние сэмплы без разрывов }
    Cls: TRidePointClass;
    BaseCls: TRidePointClass;    { класс до детекции тормозов }
    RowB: Double;                { правая часть строки }
    RowA: TVecN;                 { коэффициенты строки }
    IsRow: Boolean;              { участвует в системе }
    W: Double;                   { текущий IRLS-вес }
    Resid: Double;               { b − A·x }
  end;
  TWorkPointArray = array of TWorkPoint;

  { Окно энергетической подгонки: интеграл баланса по [I0..I1]. }
  TFitRow = record
    A: TVecN;                    { коэффициенты физ. параметров, Дж }
    B: Double;                   { ∫η·P·dt, Дж }
    Cls: TRidePointClass;        { rpcPedal / rpcCoast }
    I0, I1: Integer;             { индексы точек-концов }
    W: Double;                   { IRLS-вес }
    Resid: Double;               { B − A·x − Δdрейф }
    { Квадратичный член ветра ½ρ·CdA·w∥² (Гаусс-Ньютон):
      quad_E = (x₄²·Q11 + 2·x₄·x₅·Q12 + x₅²·Q22) / x₃  [Дж]. }
    Q11, Q22, Q12: Double;
    { Дрейф барометра входит через концы окна: до 4 узлов сплайна. }
    NKnots: Integer;
    KnotIdx: array [0..3] of Integer;
    KnotCoef: array [0..3] of Double;
  end;
  TFitRowArray = array of TFitRow;

{ ═══ Мелкая числовая утварь ═══════════════════════════════════════ }

function HasVal(X: Double): Boolean; inline;
begin
  Result := X > RIDE_NO_VALUE * 0.5;
end;

procedure SortDoubles(var A: array of Double; Lo, Hi: Integer);
var
  I, J: Integer;
  Pivot, Tmp: Double;
begin
  while Lo < Hi do
  begin
    I := Lo; J := Hi;
    Pivot := A[(Lo + Hi) div 2];
    repeat
      while A[I] < Pivot do Inc(I);
      while A[J] > Pivot do Dec(J);
      if I <= J then
      begin
        Tmp := A[I]; A[I] := A[J]; A[J] := Tmp;
        Inc(I); Dec(J);
      end;
    until I > J;
    if J - Lo < Hi - I then
    begin
      SortDoubles(A, Lo, J);
      Lo := I;
    end
    else
    begin
      SortDoubles(A, I, Hi);
      Hi := J;
    end;
  end;
end;

function MedianOf(const A: array of Double; Count: Integer): Double;
var
  Tmp: array of Double;
  I: Integer;
begin
  if Count <= 0 then begin Result := 0; Exit; end;
  SetLength(Tmp, Count);
  for I := 0 to Count - 1 do Tmp[I] := A[I];
  SortDoubles(Tmp, 0, Count - 1);
  if Odd(Count) then
    Result := Tmp[Count div 2]
  else
    Result := 0.5 * (Tmp[Count div 2 - 1] + Tmp[Count div 2]);
end;

{ Робастная сигма: 1.4826·MAD. }
function RobustSigma(const R: array of Double; Count: Integer): Double;
var
  Dev: array of Double;
  Med: Double;
  I: Integer;
begin
  if Count < 4 then begin Result := 0; Exit; end;
  Med := MedianOf(R, Count);
  SetLength(Dev, Count);
  for I := 0 to Count - 1 do Dev[I] := Abs(R[I] - Med);
  Result := 1.4826 * MedianOf(Dev, Count);
end;

{ Гаусс с частичным выбором ведущего. A портится. False = вырождена. }
function SolveLin(N: Integer; var A: TMatN; var B: TVecN;
  out X: TVecN): Boolean;
var
  I, J, K, PivRow: Integer;
  PivVal, Factor, Sum: Double;
  TmpV: TVecN;
  TmpB: Double;
begin
  Result := False;
  for K := 0 to N - 1 do
  begin
    PivRow := K;
    PivVal := Abs(A[K][K]);
    for I := K + 1 to N - 1 do
      if Abs(A[I][K]) > PivVal then
      begin
        PivVal := Abs(A[I][K]);
        PivRow := I;
      end;
    if PivVal < 1e-12 then Exit;
    if PivRow <> K then
    begin
      TmpV := A[K]; A[K] := A[PivRow]; A[PivRow] := TmpV;
      TmpB := B[K]; B[K] := B[PivRow]; B[PivRow] := TmpB;
    end;
    for I := K + 1 to N - 1 do
    begin
      Factor := A[I][K] / A[K][K];
      for J := K to N - 1 do
        A[I][J] := A[I][J] - Factor * A[K][J];
      B[I] := B[I] - Factor * B[K];
    end;
  end;
  for I := N - 1 downto 0 do
  begin
    Sum := B[I];
    for J := I + 1 to N - 1 do
      Sum := Sum - A[I][J] * X[J];
    X[I] := Sum / A[I][I];
  end;
  Result := True;
end;

{ Квадратичная ветровая поправка окна при текущих параметрах:
  (x₄²·Q11 + 2·x₄·x₅·Q12 + x₅²·Q22)/x₃.  0 при x₃≈0 или без ветра. }
function WindQuadOfRow(const Row: TFitRow; XW1, XW2, XCdA: Double): Double;
begin
  if Abs(XCdA) < 1e-4 then Exit(0);
  Result := (Sqr(XW1) * Row.Q11 + 2 * XW1 * XW2 * Row.Q12 +
             Sqr(XW2) * Row.Q22) / XCdA;
end;

{ Гаусс произвольной размерности (портит M и B). }
function SolveLinDyn(N: Integer; var M: TDMat; var B: TDVec;
  out X: TDVec): Boolean;
var
  I, J, K, PivRow: Integer;
  PivVal, Factor, Sum: Double;
  TmpRow: TDVec;
  TmpB: Double;
begin
  Result := False;
  SetLength(X, N);
  for K := 0 to N - 1 do
  begin
    PivRow := K;
    PivVal := Abs(M[K][K]);
    for I := K + 1 to N - 1 do
      if Abs(M[I][K]) > PivVal then
      begin
        PivVal := Abs(M[I][K]);
        PivRow := I;
      end;
    if PivVal < 1e-12 then Exit;
    if PivRow <> K then
    begin
      TmpRow := M[K]; M[K] := M[PivRow]; M[PivRow] := TmpRow;
      TmpB := B[K]; B[K] := B[PivRow]; B[PivRow] := TmpB;
    end;
    for I := K + 1 to N - 1 do
    begin
      Factor := M[I][K] / M[K][K];
      for J := K to N - 1 do
        M[I][J] := M[I][J] - Factor * M[K][J];
      B[I] := B[I] - Factor * B[K];
    end;
  end;
  for I := N - 1 downto 0 do
  begin
    Sum := B[I];
    for J := I + 1 to N - 1 do
      Sum := Sum - M[I][J] * X[J];
    X[I] := Sum / M[I][I];
  end;
  Result := True;
end;

{ Обращение симметричной N×N через решение N систем с базисами. }
function InvertSym(N: Integer; const A: TMatN; out Inv: TMatN): Boolean;
var
  I, J: Integer;
  Work: TMatN;
  B, X: TVecN;
begin
  Result := True;
  for J := 0 to N - 1 do
  begin
    Work := A;
    for I := 0 to N - 1 do B[I] := 0;
    B[J] := 1;
    if not SolveLin(N, Work, B, X) then
    begin
      Result := False;
      Exit;
    end;
    for I := 0 to N - 1 do Inv[I][J] := X[I];
  end;
end;

{ ═══ Локальная полиномиальная регрессия (степень 2) ═══════════════
  Сглаженное значение и производная в точке I0 по соседям в окне
  |x − x₀| ≤ HalfWin. Работает на неравномерной сетке — это и
  Savitzky-Golay, и защита от Smart Recording одновременно. }
procedure LocalQuadFit(const Xs, Ys: array of Double; Count, I0: Integer;
  HalfWin: Double; out Val, Deriv: Double);
var
  I, Lo, Hi, N: Integer;
  X0, U, Y: Double;
  S0, S1, S2, S3, S4, T0, T1, T2: Double;
  M: TMatN;
  B, Sol: TVecN;
begin
  X0 := Xs[I0];
  Val := Ys[I0];
  Deriv := 0;

  Lo := I0;
  while (Lo > 0) and (X0 - Xs[Lo - 1] <= HalfWin) do Dec(Lo);
  Hi := I0;
  while (Hi < Count - 1) and (Xs[Hi + 1] - X0 <= HalfWin) do Inc(Hi);
  N := Hi - Lo + 1;

  if N < 3 then Exit;

  S0 := 0; S1 := 0; S2 := 0; S3 := 0; S4 := 0;
  T0 := 0; T1 := 0; T2 := 0;
  for I := Lo to Hi do
  begin
    U := Xs[I] - X0;
    Y := Ys[I];
    S0 := S0 + 1;
    S1 := S1 + U;
    S2 := S2 + U * U;
    S3 := S3 + U * U * U;
    S4 := S4 + U * U * U * U;
    T0 := T0 + Y;
    T1 := T1 + Y * U;
    T2 := T2 + Y * U * U;
  end;

  if N >= 5 then
  begin
    M[0][0] := S0; M[0][1] := S1; M[0][2] := S2;
    M[1][0] := S1; M[1][1] := S2; M[1][2] := S3;
    M[2][0] := S2; M[2][1] := S3; M[2][2] := S4;
    B[0] := T0; B[1] := T1; B[2] := T2;
    if SolveLin(3, M, B, Sol) then
    begin
      Val := Sol[0];
      Deriv := Sol[1];
      Exit;
    end;
  end;

  { Линейный fallback. }
  if S0 * S2 - S1 * S1 > 1e-12 then
  begin
    Deriv := (S0 * T1 - S1 * T0) / (S0 * S2 - S1 * S1);
    Val := (T0 - Deriv * S1) / S0;
  end;
end;

{ ═══ Конфигурация по умолчанию ════════════════════════════════════ }

function DefaultRideEstimatorConfig: TRideEstimatorConfig;
begin
  Result.RiderProfileMassKg := 75;
  Result.BikeMassGuessKg    := 9;
  Result.MassPriorSigmaKg   := 8;
  Result.CdAPrior           := 0.35;
  Result.CdAPriorSigma      := 0.12;
  Result.CrrPrior           := 0.005;
  Result.CrrPriorSigma      := 0.004;
  Result.DrivetrainEff      := 0.975;
  Result.RotMassFactor      := 0.012;
  Result.GravityMs2         := 9.81;
  Result.AltWindowM         := 35;
  Result.PedalWindowSec     := 25;
  Result.CoastWindowSec     := 8;
  Result.MinWindowSec       := 5;
  Result.AltEndpointWindowM := 28;
  Result.BaroRwSigma        := 0.05;
  Result.UseDriftSpline     := False;
  Result.DriftKnotSec       := 120;
  Result.SpeedWindowSec     := 2.5;
  Result.MinSpeedMs         := 2.0;
  Result.MinPedalPowerW     := 25;
  Result.CoastMaxPowerW     := 10;
  Result.CoastMinDurSec     := 4.0;
  Result.CoastEdgeTrimSec   := 1.5;
  Result.MaxSampleGapSec    := 3.0;
  Result.HuberK             := 1.345;
  Result.Iterations         := 8;
  Result.BrakeForceMinN     := 25;
  Result.BrakeSigmaK        := 3.0;
  Result.BrakeMinDurSec     := 1.5;
  Result.EstimateWind       := False;
  Result.WindKnown          := False;
  Result.WindKnownSpeedMs   := 0;
  Result.WindKnownFromRad   := 0;
end;

{ ═══ Плотность воздуха ════════════════════════════════════════════
  ISA-давление по высоте; температура из файла либо ISA. }
function AirDensityAt(AltM, TempC: Double): Double;
var
  P, TK: Double;
begin
  P := 101325.0 * Power(1.0 - 2.25577e-5 * AltM, 5.25588);
  if HasVal(TempC) then
    TK := TempC + 273.15
  else
    TK := 288.15 - 0.0065 * AltM;
  Result := P / (287.05 * TK);
end;

{ ═══ Главная функция ══════════════════════════════════════════════ }

{ Внутренняя версия: дополнительно отдаёт оконные строки, их
  EIV-дисперсии и финальные сигмы — сырьё совместной оценки. }
function EstimateRideParametersEx(const Samples: TRideSampleArray;
  const Cfg: TRideEstimatorConfig;
  out Est: TRideEstimate;
  out Points: TRidePointResultArray;
  out OutRows: TFitRowArray;
  out OutEiv: TDVec;
  out OutSigP, OutSigC: Double;
  out OutHadHeading: Boolean): Boolean;
var
  WP: TWorkPointArray;
  FitRows: TFitRowArray;
  NFitRows: Integer;
  AltWhiteVar: Double;         { оценка белого шума высоты, м² }
  { Дрейф-сплайн барометра: кусочно-линейный d(t), узлы каждые
    DriftKnotSec. Неизвестные — в ЭНЕРГЕТИЧЕСКИХ единицах
    DE_k ≈ m·g·d(t_k) [Дж], чтобы система осталась линейной
    (физически дрейф входит как m·g·Δd). }
  NDrift: Integer;
  KnotT0, KnotDT: Double;
  DriftX: TDVec;               { решение по узлам, Дж }
  RwEst: Double;               { онлайн-оценка скорости RW, м/√с }
  NS, NPar: Integer;
  HasCadenceSensor, HasPowerData, UseWind: Boolean;
  X: TVecN;                       { текущие параметры }
  PriorVal, PriorW: TVecN;        { приоры и их веса (1/σ²) }
  MassKg, CdA, Crr: Double;
  G, Lam, Eff: Double;

  { ── подготовка каналов ── }
  procedure Preprocess;
  var
    I, K: Integer;
    Ts, Ds, Alts, Vs, AltResid: array of Double;
    Dt, Dv, Val, Der: Double;
    NHead: Integer;
  begin
    SetLength(WP, NS);
    SetLength(Ts, NS);
    SetLength(Ds, NS);
    SetLength(Alts, NS);
    SetLength(Vs, NS);

    NHead := 0;
    for I := 0 to NS - 1 do
    begin
      WP[I].T := Samples[I].TimeSec;
      WP[I].S := Samples[I].DistanceM;
      WP[I].P := Samples[I].PowerW;
      WP[I].Cad := Samples[I].CadenceRpm;
      WP[I].HasHeading := HasVal(Samples[I].HeadingRad);
      if WP[I].HasHeading then
      begin
        WP[I].Heading := Samples[I].HeadingRad;
        Inc(NHead);
      end
      else
        WP[I].Heading := 0;
      Ts[I] := WP[I].T;
      Ds[I] := WP[I].S;
      Alts[I] := Samples[I].AltM;

      { Скорость: из файла либо из дистанции. }
      if HasVal(Samples[I].SpeedMs) then
        Vs[I] := Samples[I].SpeedMs
      else if I > 0 then
      begin
        Dt := Samples[I].TimeSec - Samples[I - 1].TimeSec;
        if Dt > 0.01 then
          Vs[I] := (Samples[I].DistanceM - Samples[I - 1].DistanceM) / Dt
        else
          Vs[I] := Vs[I - 1];
      end
      else
        Vs[I] := 0;

      if HasVal(Samples[I].CadenceRpm) and (Samples[I].CadenceRpm > 5) then
        HasCadenceSensor := True;
      if HasVal(Samples[I].PowerW) then
        HasPowerData := True;
    end;

    UseWind := Cfg.EstimateWind and (not Cfg.WindKnown)
               and (NHead > (NS * 7) div 10);
    if UseWind then NPar := 5 else NPar := 3;

    { Высота: сглаживание + производная в ДИСТАНЦИОННОЙ области.
      dh/ds = sinθ, т.к. дистанция FIT — длина пути. }
    for I := 0 to NS - 1 do
    begin
      LocalQuadFit(Ds, Alts, NS, I, Cfg.AltWindowM, Val, Der);
      WP[I].Alt := Val;
      LocalQuadFit(Ds, Alts, NS, I, Cfg.AltEndpointWindowM, Val, Der);
      WP[I].AltLite := Val;
      { счётчик соседей в лёгком окне — для дисперсии конца окна }
      WP[I].NLite := 1;
      K := I;
      while (K > 0) and (Ds[I] - Ds[K - 1] <= Cfg.AltEndpointWindowM) do
      begin
        Dec(K);
        Inc(WP[I].NLite);
      end;
      K := I;
      while (K < NS - 1) and (Ds[K + 1] - Ds[I] <= Cfg.AltEndpointWindowM) do
      begin
        Inc(K);
        Inc(WP[I].NLite);
      end;
      LocalQuadFit(Ds, Alts, NS, I, Cfg.AltWindowM, Val, Der);
      WP[I].Grade := EnsureRange(Der, -0.35, 0.35);
      WP[I].SinT := WP[I].Grade;
      WP[I].CosT := Sqrt(1.0 - Sqr(WP[I].SinT));
      WP[I].Rho := AirDensityAt(Val, Samples[I].TempC);
    end;

    { Белый шум барометра: робастная сигма невязок высоты к лёгкому
      сглаживанию (×1.25 — поправка на само-подгонку локальной модели). }
    SetLength(AltResid, NS);
    for I := 0 to NS - 1 do
      AltResid[I] := Alts[I] - WP[I].AltLite;
    AltWhiteVar := Sqr(1.25 * RobustSigma(AltResid, NS));

    { Стоячие места: уклон «замирает» на последнем осмысленном.
      (в окне ±AltWindowM может не оказаться перепада дистанции) }
    for I := 1 to NS - 1 do
      if (Ds[I] - Ds[I - 1]) < 0.2 then
        WP[I].Grade := WP[I - 1].Grade;

    { Скорость и ускорение: сглаживание во временной области. }
    for I := 0 to NS - 1 do
    begin
      WP[I].VRaw := Max(Vs[I], 0);
      LocalQuadFit(Ts, Vs, NS, I, Cfg.SpeedWindowSec, Val, Der);
      WP[I].V := Max(Val, 0);
      WP[I].A := Der;
      { Ускорение валидно, если рядом нет разрывов записи. }
      WP[I].AccelValid := True;
      if I > 0 then
      begin
        Dt := Ts[I] - Ts[I - 1];
        if (Dt <= 0) or (Dt > Cfg.MaxSampleGapSec) then
          WP[I].AccelValid := False;
      end;
      if I < NS - 1 then
      begin
        Dt := Ts[I + 1] - Ts[I];
        if (Dt <= 0) or (Dt > Cfg.MaxSampleGapSec) then
          WP[I].AccelValid := False;
      end;
      { Пик |a| > 3 м/с² на велосипеде — артефакт данных. }
      Dv := Abs(WP[I].A);
      if Dv > 3.0 then WP[I].AccelValid := False;
    end;
  end;

  { ── компенсация лага мощности ──
    Головные устройства пишут мощность со сглаживанием/задержкой
    1–3 с относительно скорости. На ступеньках мощности это
    антикоррелирует b окна с ΔKE и занижает массу. Ищем лаг
    максимизацией корреляции η·P/v с кинематической силой
    m₀·((1+λ)·a + g·sinθ) по сетке 0..4 с, сдвигаем P интерполяцией. }
  procedure CompensatePowerLag;
  const
    MAX_LAG = 4.0;
    LAG_STEP = 0.5;
  var
    I, K, N: Integer;
    L, BestL, BestCorr, C: Double;
    F, Q: array of Double;
    M0: Double;

    function PAt(TT: Double): Double;
    var
      J: Integer;
      Frac: Double;
    begin
      { линейная интерполяция P по времени с клампом }
      if TT <= WP[0].T then begin Result := WP[0].P; Exit; end;
      if TT >= WP[NS - 1].T then begin Result := WP[NS - 1].P; Exit; end;
      J := 0;
      while (J < NS - 2) and (WP[J + 1].T < TT) do Inc(J);
      if WP[J + 1].T > WP[J].T then
        Frac := (TT - WP[J].T) / (WP[J + 1].T - WP[J].T)
      else
        Frac := 0;
      Result := WP[J].P + Frac * (WP[J + 1].P - WP[J].P);
    end;

    function CorrAtLag(Lag: Double): Double;
    var
      J, M: Integer;
      X1, Y1, SX, SY, SXX, SYY, SXY: Double;
    begin
      SX := 0; SY := 0; SXX := 0; SYY := 0; SXY := 0; M := 0;
      for J := 0 to N - 1 do
      begin
        X1 := PAt(Q[J] + Lag);            { запись отстаёт → берём вперёд }
        X1 := Eff * X1 / Max(F[J], 0.5);  { F[J] хранит v точки }
        Y1 := Q[N + J];                   { кинематическая сила }
        SX := SX + X1; SY := SY + Y1;
        SXX := SXX + X1 * X1; SYY := SYY + Y1 * Y1; SXY := SXY + X1 * Y1;
        Inc(M);
      end;
      if M < 30 then begin Result := 0; Exit; end;
      X1 := (SXY - SX * SY / M);
      Y1 := Sqrt(Max(SXX - SX * SX / M, 1e-9) *
                 Max(SYY - SY * SY / M, 1e-9));
      Result := X1 / Y1;
    end;

  begin
    { отбор точек: явное педалирование с валидным ускорением }
    M0 := PriorVal[0];
    SetLength(F, NS);
    SetLength(Q, 2 * NS);
    N := 0;
    for I := 0 to NS - 1 do
      if HasVal(WP[I].P) and (WP[I].P > 50) and (WP[I].V > 3) and
         WP[I].AccelValid then
      begin
        F[N] := WP[I].V;
        Q[N] := WP[I].T;
        Inc(N);
      end;
    if N < 120 then Exit;
    { вторая половина Q — кинематическая сила }
    K := 0;
    for I := 0 to NS - 1 do
      if HasVal(WP[I].P) and (WP[I].P > 50) and (WP[I].V > 3) and
         WP[I].AccelValid then
      begin
        Q[N + K] := M0 * ((1.0 + Lam) * WP[I].A + G * WP[I].SinT);
        Inc(K);
      end;

    BestL := 0;
    BestCorr := CorrAtLag(0);
    L := LAG_STEP;
    while L <= MAX_LAG + 1e-9 do
    begin
      C := CorrAtLag(L);
      if C > BestCorr then
      begin
        BestCorr := C;
        BestL := L;
      end;
      L := L + LAG_STEP;
    end;

    {$IFDEF ESTDEBUG}
    WriteLn(Format('DBG лаг мощности: %.1f с (corr %.3f), точек %d',
      [BestL, BestCorr, N]));
    {$ENDIF}
    if BestL > 0 then
    begin
      { сдвигаем мощность на найденный лаг }
      SetLength(F, NS);
      for I := 0 to NS - 1 do
        F[I] := PAt(WP[I].T + BestL);
      for I := 0 to NS - 1 do
        WP[I].P := F[I];
    end;
  end;

  { ── сегментация: накат / педалирование / прочее ── }
  procedure Classify;
  var
    I, K, RunStart, RunEnd: Integer;
    IsCoastRaw: array of Boolean;
    PwOk, CadZero: Boolean;
    TrimT: Double;
  begin
    SetLength(IsCoastRaw, NS);
    for I := 0 to NS - 1 do
    begin
      WP[I].Cls := rpcExcluded;
      PwOk := HasVal(WP[I].P) and (WP[I].P <= Cfg.CoastMaxPowerW);
      if HasCadenceSensor then
        CadZero := (not HasVal(WP[I].Cad)) or (WP[I].Cad <= 1.0)
      else
        CadZero := True;
      IsCoastRaw[I] := PwOk and CadZero;
    end;

    { Runs наката: длительность >= CoastMinDurSec, края обрезаются
      на CoastEdgeTrimSec (лаг датчика каденса / переходные). }
    I := 0;
    while I < NS do
    begin
      if IsCoastRaw[I] then
      begin
        RunStart := I;
        while (I < NS - 1) and IsCoastRaw[I + 1] do Inc(I);
        RunEnd := I;
        if WP[RunEnd].T - WP[RunStart].T >= Cfg.CoastMinDurSec then
        begin
          TrimT := WP[RunStart].T + Cfg.CoastEdgeTrimSec;
          while (RunStart <= RunEnd) and (WP[RunStart].T < TrimT) do
            Inc(RunStart);
          TrimT := WP[RunEnd].T - Cfg.CoastEdgeTrimSec;
          while (RunEnd >= RunStart) and (WP[RunEnd].T > TrimT) do
            Dec(RunEnd);
          for K := RunStart to RunEnd do
            if (WP[K].V >= Cfg.MinSpeedMs) and WP[K].AccelValid then
              WP[K].Cls := rpcCoast;
        end;
        Inc(I);
      end
      else
        Inc(I);
    end;

    { Педалирование. }
    for I := 0 to NS - 1 do
      if (WP[I].Cls = rpcExcluded) and HasVal(WP[I].P) and
         (WP[I].P >= Cfg.MinPedalPowerW) and
         (WP[I].V >= Cfg.MinSpeedMs) and
         WP[I].AccelValid and
         ((not HasCadenceSensor) or
          (HasVal(WP[I].Cad) and (WP[I].Cad >= 20))) then
        WP[I].Cls := rpcPedal;

    for I := 0 to NS - 1 do
      WP[I].BaseCls := WP[I].Cls;
  end;

  { ── поточечные строки (силовая форма, Н) ──
    Нужны для детекции торможений и выходной раскладки/диагностики. }
  procedure BuildPointRows;
  var
    I: Integer;
    Va: Double;
  begin
    for I := 0 to NS - 1 do
    begin
      WP[I].IsRow := WP[I].Cls in [rpcPedal, rpcCoast, rpcBrake];
      if not WP[I].IsRow then Continue;
      WP[I].RowA[0] := G * WP[I].SinT + (1.0 + Lam) * WP[I].A;
      WP[I].RowA[1] := G * WP[I].CosT;
      if Cfg.WindKnown and WP[I].HasHeading then
      begin
        { Известный ветер: Va = V + встречная компонента. Знаковая
          квадратичная 0.5ρ·Va·|Va| — на кольце маршрута НЕ усредняется в
          ноль (в отличие от линейной формы оценки ветра). }
        Va := WP[I].V + Cfg.WindKnownSpeedMs
              * Cos(WP[I].Heading - Cfg.WindKnownFromRad);
        WP[I].RowA[2] := 0.5 * WP[I].Rho * Va * Abs(Va);
      end
      else
        WP[I].RowA[2] := 0.5 * WP[I].Rho * Sqr(WP[I].V);
      WP[I].RowA[3] := 0;
      WP[I].RowA[4] := 0;
      if UseWind and WP[I].HasHeading then
      begin
        WP[I].RowA[3] := WP[I].Rho * WP[I].V * Cos(WP[I].Heading);
        WP[I].RowA[4] := WP[I].Rho * WP[I].V * Sin(WP[I].Heading);
      end;
      if WP[I].Cls = rpcPedal then
        WP[I].RowB := Eff * WP[I].P / Max(WP[I].V, 0.5)
      else
        WP[I].RowB := 0;
    end;
  end;

  procedure ComputePointResiduals;
  var
    I, J: Integer;
    Ax: Double;
  begin
    for I := 0 to NS - 1 do
      if WP[I].IsRow then
      begin
        Ax := 0;
        for J := 0 to NPar - 1 do
          Ax := Ax + WP[I].RowA[J] * X[J];
        WP[I].Resid := WP[I].RowB - Ax;
      end
      else
        WP[I].Resid := 0;
  end;

  { Детекция торможений по поточечной невязке на накате.
    Невязка на накате = −A·x = F_brake (Н). Runs > порога и длит.
    >= BrakeMinDurSec → ядро rpcBrake, по 2 сэмпла halo с каждой
    стороны → rpcExcluded (размазаны сглаживанием скорости). }
  procedure MarkBrakes;
  var
    I, K, RunStart, RunEnd, NC: Integer;
    RCst: array of Double;
    SigC, Thr: Double;
    IsBr: array of Boolean;
  begin
    { восстановить исходную классификацию накатной семьи }
    for I := 0 to NS - 1 do
      if WP[I].BaseCls = rpcCoast then WP[I].Cls := rpcCoast;
    BuildPointRows;
    ComputePointResiduals;

    SetLength(RCst, NS);
    NC := 0;
    for I := 0 to NS - 1 do
      if WP[I].Cls = rpcCoast then
      begin
        RCst[NC] := WP[I].Resid;
        Inc(NC);
      end;
    SigC := Max(RobustSigma(RCst, NC), 1.0);
    Thr := Max(Cfg.BrakeForceMinN, Cfg.BrakeSigmaK * SigC);

    SetLength(IsBr, NS);
    for I := 0 to NS - 1 do
      IsBr[I] := (WP[I].Cls = rpcCoast) and (WP[I].Resid > Thr);

    I := 0;
    while I < NS do
    begin
      if IsBr[I] then
      begin
        RunStart := I;
        while (I < NS - 1) and IsBr[I + 1] do Inc(I);
        RunEnd := I;
        if WP[RunEnd].T - WP[RunStart].T >= Cfg.BrakeMinDurSec then
        begin
          for K := RunStart to RunEnd do
            WP[K].Cls := rpcBrake;
          { halo: переходные сэмплы исключаем из наката
            (радиус сглаживания скорости) }
          for K := 1 to 3 do
          begin
            if (RunStart - K >= 0) and
               (WP[RunStart - K].Cls = rpcCoast) then
              WP[RunStart - K].Cls := rpcExcluded;
            if (RunEnd + K < NS) and
               (WP[RunEnd + K].Cls = rpcCoast) then
              WP[RunEnd + K].Cls := rpcExcluded;
          end;
        end;
        Inc(I);
      end
      else
        Inc(I);
    end;
  end;

  { ── окна энергетической подгонки ──
    Интеграл баланса по непрерывным участкам одного класса.
    Δh берётся из слегка сглаженной высоты (AltLite) — без
    дифференцирования, Δv² — из сглаженной скорости. }
  procedure BuildWindows;
  var
    I, RunStart, RunEnd, WinA, WinB, NWin, WIdx: Integer;
    Cls: TRidePointClass;
    RunDur, Target: Double;

    procedure EmitWindow(ACls: TRidePointClass; AI0, AI1: Integer);
    var
      K: Integer;
      Dt: Double;
      Row: TFitRow;

      { Вклад d(T) с множителем ASign в разреженные коэффициенты узлов.
        residual = B − A·x − (dE(t1) − dE(t0))  ⇒
        коэффициент узла j: −φ_j(t1) + φ_j(t0). }
      procedure AddDriftCoef(T: Double; ASign: Double);
      var
        Kn, J: Integer;
        Frac, W0: Double;

        procedure Put(Idx: Integer; C: Double);
        var
          Q: Integer;
        begin
          for Q := 0 to Row.NKnots - 1 do
            if Row.KnotIdx[Q] = Idx then
            begin
              Row.KnotCoef[Q] := Row.KnotCoef[Q] + C;
              Exit;
            end;
          if Row.NKnots < 4 then
          begin
            Row.KnotIdx[Row.NKnots] := Idx;
            Row.KnotCoef[Row.NKnots] := C;
            Inc(Row.NKnots);
          end;
        end;

      begin
        if NDrift < 2 then Exit;
        Frac := (T - KnotT0) / KnotDT;
        Kn := Trunc(Frac);
        if Kn < 0 then Kn := 0;
        if Kn > NDrift - 2 then Kn := NDrift - 2;
        Frac := EnsureRange(Frac - Kn, 0, 1);
        W0 := 1.0 - Frac;
        Put(Kn, ASign * W0);
        Put(Kn + 1, ASign * Frac);
        J := 0;
        if J <> 0 then ;
      end;

    begin
      FillChar(Row, SizeOf(Row), 0);
      Row.Cls := ACls;
      Row.I0 := AI0;
      Row.I1 := AI1;
      Row.W := 1;
      for K := AI0 + 1 to AI1 do
      begin
        Dt := WP[K].T - WP[K - 1].T;
        Row.B := Row.B + Eff * 0.5 * (WP[K].P + WP[K - 1].P) * Dt;
        Row.A[1] := Row.A[1] + G * 0.5 *
          (WP[K].V * WP[K].CosT + WP[K - 1].V * WP[K - 1].CosT) * Dt;
        Row.A[2] := Row.A[2] + 0.25 *
          (WP[K].Rho * Sqr(WP[K].V) * WP[K].V +
           WP[K - 1].Rho * Sqr(WP[K - 1].V) * WP[K - 1].V) * Dt;
        if UseWind then
        begin
          Row.A[3] := Row.A[3] + 0.5 *
            (WP[K].Rho * Sqr(WP[K].V) * Cos(WP[K].Heading) +
             WP[K - 1].Rho * Sqr(WP[K - 1].V) * Cos(WP[K - 1].Heading)) * Dt;
          Row.A[4] := Row.A[4] + 0.5 *
            (WP[K].Rho * Sqr(WP[K].V) * Sin(WP[K].Heading) +
             WP[K - 1].Rho * Sqr(WP[K - 1].V) * Sin(WP[K - 1].Heading)) * Dt;
          { квадратичные ветровые интегралы: ½∫ρ·v·{cos²,sin²,cos·sin}dt }
          Row.Q11 := Row.Q11 + 0.25 *
            (WP[K].Rho * WP[K].V * Sqr(Cos(WP[K].Heading)) +
             WP[K - 1].Rho * WP[K - 1].V * Sqr(Cos(WP[K - 1].Heading))) * Dt;
          Row.Q22 := Row.Q22 + 0.25 *
            (WP[K].Rho * WP[K].V * Sqr(Sin(WP[K].Heading)) +
             WP[K - 1].Rho * WP[K - 1].V * Sqr(Sin(WP[K - 1].Heading))) * Dt;
          Row.Q12 := Row.Q12 + 0.25 *
            (WP[K].Rho * WP[K].V * Cos(WP[K].Heading) * Sin(WP[K].Heading) +
             WP[K - 1].Rho * WP[K - 1].V *
               Cos(WP[K - 1].Heading) * Sin(WP[K - 1].Heading)) * Dt;
        end;
      end;
      { Δh — из слегка сглаженной высоты; ΔKE — из СЫРОЙ скорости:
        её шум мал (датчик), а сглаженная скорость у границ окна
        смазана соседним торможением/педалированием. }
      Row.A[0] := G * (WP[AI1].AltLite - WP[AI0].AltLite) +
        (1.0 + Lam) * 0.5 * (Sqr(WP[AI1].VRaw) - Sqr(WP[AI0].VRaw));
      AddDriftCoef(WP[AI1].T, -1.0);
      AddDriftCoef(WP[AI0].T, +1.0);
      if NFitRows >= Length(FitRows) then
        SetLength(FitRows, Length(FitRows) * 2);
      FitRows[NFitRows] := Row;
      Inc(NFitRows);
    end;

    function SameRun(A, B: Integer): Boolean;
    begin
      Result := (WP[B].Cls = WP[A].Cls) and
        (WP[B].T - WP[B - 1].T > 0) and
        (WP[B].T - WP[B - 1].T <= Cfg.MaxSampleGapSec);
    end;

  begin
    NFitRows := 0;
    SetLength(FitRows, 64);

    I := 0;
    while I < NS do
    begin
      Cls := WP[I].Cls;
      if not (Cls in [rpcPedal, rpcCoast]) then
      begin
        Inc(I);
        Continue;
      end;
      RunStart := I;
      while (I < NS - 1) and SameRun(RunStart, I + 1) do Inc(I);
      RunEnd := I;
      Inc(I);

      RunDur := WP[RunEnd].T - WP[RunStart].T;
      if RunDur < Cfg.MinWindowSec then Continue;

      if Cls = rpcPedal then Target := Cfg.PedalWindowSec
      else Target := Cfg.CoastWindowSec;
      NWin := Max(1, Round(RunDur / Target));

      { Якорная строка на весь run: длинная база Δh почти нечувствительна
        к дрейфу барометра и держит «гравитационное» направление (массу). }
      if (NWin >= 2) and (RunDur >= 2 * Target) then
        EmitWindow(Cls, RunStart, RunEnd);

      WinA := RunStart;
      for WIdx := 1 to NWin do
      begin
        if WIdx = NWin then
          WinB := RunEnd
        else
        begin
          WinB := WinA;
          while (WinB < RunEnd) and
                (WP[WinB].T - WP[RunStart].T <
                 RunDur * WIdx / NWin) do Inc(WinB);
        end;
        if (WinB > WinA) and
           (WP[WinB].T - WP[WinA].T >= Cfg.MinWindowSec) then
          EmitWindow(Cls, WinA, WinB);
        WinA := WinB;
      end;
    end;
  end;

  {$IFDEF ESTDEBUG}
  procedure DebugTrueResiduals;
  const
    TX0 = 85.2; TX1 = 85.2 * 0.0062; TX2 = 0.342;
  var
    I, J, NP1, NC1: Integer;
    Ax, SP, SC, SP2, SC2: Double;
    TX: TVecN;
  begin
    TX[0] := TX0; TX[1] := TX1; TX[2] := TX2; TX[3] := 0; TX[4] := 0;
    SP := 0; SC := 0; SP2 := 0; SC2 := 0; NP1 := 0; NC1 := 0;
    for I := 0 to NFitRows - 1 do
    begin
      Ax := 0;
      for J := 0 to NPar - 1 do Ax := Ax + FitRows[I].A[J] * TX[J];
      if FitRows[I].Cls = rpcPedal then
      begin
        SP := SP + (FitRows[I].B - Ax); SP2 := SP2 + Sqr(FitRows[I].B - Ax);
        Inc(NP1);
      end
      else
      begin
        SC := SC + (FitRows[I].B - Ax); SC2 := SC2 + Sqr(FitRows[I].B - Ax);
        Inc(NC1);
      end;
    end;
    if NP1 > 0 then
      WriteLn(Format('DBG окна@истина: pedal n=%d mean=%.0f rms=%.0f Дж',
        [NP1, SP / NP1, Sqrt(SP2 / NP1)]));
    if NC1 > 0 then
      WriteLn(Format('DBG окна@истина: coast n=%d mean=%.0f rms=%.0f Дж',
        [NC1, SC / NC1, Sqrt(SC2 / NC1)]));
  end;
  {$ENDIF}

  { IRLS по окнам: Huber, раздельные сигмы педалирование/накат.
    Расширенная система: физ. параметры + узлы дрейф-сплайна.
    CovPhys на выходе — МАРГИНАЛЬНАЯ ковариация физ. параметров
    (верхний блок полной обратной матрицы). }
  procedure SolveWindowsIrls(out CovPhys: TMatN; out CovOk: Boolean;
    out SigP, SigC: Double);
  var
    NTot, Iter, I, J, K, Q, NPed, NCst: Integer;
    RPed, RCst: array of Double;
    NE, NESave: TDMat;
    RHS, Sol, EVec: TDVec;
    Idx: array [0..8] of Integer;
    Cf: array [0..8] of Double;
    NIdx: Integer;
    HW, Scale, AbsR, SigmaRow, Ax, WInc, DEGauge, Fuller: Double;
  begin
    NTot := NPar + NDrift;
    SetLength(RPed, NFitRows);
    SetLength(RCst, NFitRows);
    SetLength(NE, NTot);
    SetLength(NESave, NTot);
    for I := 0 to NTot - 1 do
    begin
      SetLength(NE[I], NTot);
      SetLength(NESave[I], NTot);
    end;
    SetLength(RHS, NTot);
    SetLength(EVec, NTot);
    if Length(DriftX) <> NDrift then
    begin
      SetLength(DriftX, NDrift);
      for I := 0 to NDrift - 1 do DriftX[I] := 0;
    end;

    SigP := 1500;   { стартовые масштабы шума, Дж }
    SigC := 600;
    CovOk := False;
    FillChar(CovPhys, SizeOf(CovPhys), 0);

    { Вес RW-штрафа приращений дрейфа: DE ≈ m·g·d, приращение за шаг
      узла Δt имеет σ = m₀·g·rw·√Δt. }
    WInc := 1.0 / Max(Sqr(PriorVal[0] * G * Cfg.BaroRwSigma) * KnotDT, 1e-6);
    if not Cfg.UseDriftSpline then
      WInc := 1e12;  { сплайн выключен: дрейф зажат в ноль }
    DEGauge := 1e8;   { жёсткая привязка DE[0] = 0 (калибровка уровня) }

    for Iter := 1 to Cfg.Iterations do
    begin
      { невязки окон (с текущим дрейфом) }
      NPed := 0; NCst := 0;
      for I := 0 to NFitRows - 1 do
      begin
        Ax := 0;
        for J := 0 to NPar - 1 do
          Ax := Ax + FitRows[I].A[J] * X[J];
        for J := 0 to FitRows[I].NKnots - 1 do
          Ax := Ax + FitRows[I].KnotCoef[J] * DriftX[FitRows[I].KnotIdx[J]];
        if UseWind then
          Ax := Ax + WindQuadOfRow(FitRows[I], X[3], X[4], X[2]);
        FitRows[I].Resid := FitRows[I].B - Ax;
        if FitRows[I].Cls = rpcPedal then
        begin
          RPed[NPed] := FitRows[I].Resid; Inc(NPed);
        end
        else
        begin
          RCst[NCst] := FitRows[I].Resid; Inc(NCst);
        end;
      end;
      if NPed >= 6 then SigP := Max(RobustSigma(RPed, NPed), 50);
      if NCst >= 6 then SigC := Max(RobustSigma(RCst, NCst), 25);

      { нормальные уравнения: приоры физ. параметров }
      for I := 0 to NTot - 1 do
      begin
        RHS[I] := 0;
        for J := 0 to NTot - 1 do NE[I][J] := 0;
      end;
      for I := 0 to NPar - 1 do
      begin
        NE[I][I] := PriorW[I];
        RHS[I] := PriorW[I] * PriorVal[I];
      end;

      { приоры дрейфа: калибровка уровня + RW-штраф приращений }
      NE[NPar][NPar] := NE[NPar][NPar] + DEGauge;
      for K := 0 to NDrift - 2 do
      begin
        NE[NPar + K][NPar + K]         := NE[NPar + K][NPar + K] + WInc;
        NE[NPar + K + 1][NPar + K + 1] := NE[NPar + K + 1][NPar + K + 1] + WInc;
        NE[NPar + K][NPar + K + 1]     := NE[NPar + K][NPar + K + 1] - WInc;
        NE[NPar + K + 1][NPar + K]     := NE[NPar + K + 1][NPar + K] - WInc;
      end;

      { строки-окна: разреженная сборка }
      for I := 0 to NFitRows - 1 do
      begin
        if FitRows[I].Cls = rpcPedal then SigmaRow := SigP
        else SigmaRow := SigC;
        AbsR := Abs(FitRows[I].Resid);
        if AbsR <= Cfg.HuberK * SigmaRow then
          HW := 1.0
        else
          HW := Cfg.HuberK * SigmaRow / AbsR;
        Scale := HW / Sqr(SigmaRow);
        FitRows[I].W := Scale;

        NIdx := 0;
        for J := 0 to NPar - 1 do
        begin
          Idx[NIdx] := J;
          Cf[NIdx] := FitRows[I].A[J];
          Inc(NIdx);
        end;
        for J := 0 to FitRows[I].NKnots - 1 do
        begin
          Idx[NIdx] := NPar + FitRows[I].KnotIdx[J];
          Cf[NIdx] := FitRows[I].KnotCoef[J];
          Inc(NIdx);
        end;

        { b_eff: квадратичная ветровая поправка при текущей точке
          (Гаусс-Ньютон). }
        Ax := FitRows[I].B;
        if UseWind then
          Ax := Ax - WindQuadOfRow(FitRows[I], X[3], X[4], X[2]);
        for J := 0 to NIdx - 1 do
        begin
          RHS[Idx[J]] := RHS[Idx[J]] + Scale * Cf[J] * Ax;
          for Q := 0 to NIdx - 1 do
            NE[Idx[J]][Idx[Q]] := NE[Idx[J]][Idx[Q]] +
              Scale * Cf[J] * Cf[Q];
        end;
      end;

      { EIV-поправка (только белый шум высоты, дисперсия оценена из
        данных): шум концов окна сидит в столбце массы и затухает её.
        RW-часть уже поглощена дрейф-сплайном. }
      Fuller := 0;
      for I := 0 to NFitRows - 1 do
      begin
        Ax := AltWhiteVar *
          (1.0 / Max(WP[FitRows[I].I0].NLite, 1) +
           1.0 / Max(WP[FitRows[I].I1].NLite, 1));
        if not Cfg.UseDriftSpline then
          Ax := Ax + Sqr(RwEst) *
            (WP[FitRows[I].I1].T - WP[FitRows[I].I0].T);
        Fuller := Fuller + FitRows[I].W * Sqr(G) * Ax;
      end;
      {$IFDEF ESTDEBUG}
      if Iter = Cfg.Iterations then
        WriteLn(Format('DBG Fuller: rwest=%.3f м/√с, поправка %.0f%% инфо массы',
          [RwEst, 100 * Min(Fuller, 0.7 * Max(NE[0][0] - PriorW[0], 0)) /
           Max(NE[0][0] - PriorW[0], 1e-9)]));
      {$ENDIF}
      {$IFDEF ESTDEBUG}
      if Iter = Cfg.Iterations then
        WriteLn(Format('DBG Fuller: NE00=%.4g prior=%.4g корр=%.4g (кламп %.4g) rw=%.3f',
          [NE[0][0], PriorW[0], Fuller,
           0.7 * Max(NE[0][0] - PriorW[0], 0), RwEst]));
      {$ENDIF}
      Fuller := Min(Fuller, 0.7 * Max(NE[0][0] - PriorW[0], 0));
      NE[0][0] := NE[0][0] - Fuller;

      { сохранить информацию для ковариации до разрушения решателем }
      for I := 0 to NTot - 1 do
        for J := 0 to NTot - 1 do
          NESave[I][J] := NE[I][J];

      if not SolveLinDyn(NTot, NE, RHS, Sol) then Break;
      for J := 0 to NPar - 1 do X[J] := Sol[J];
      for J := 0 to NDrift - 1 do DriftX[J] := Sol[NPar + J];

      { маргинальная ковариация физ. параметров на последней итерации }
      if Iter = Cfg.Iterations then
      begin
        CovOk := True;
        for K := 0 to NPar - 1 do
        begin
          for I := 0 to NTot - 1 do
          begin
            EVec[I] := 0;
            for J := 0 to NTot - 1 do NE[I][J] := NESave[I][J];
          end;
          EVec[K] := 1;
          if not SolveLinDyn(NTot, NE, EVec, Sol) then
          begin
            CovOk := False;
            Break;
          end;
          for I := 0 to NPar - 1 do
            CovPhys[I][K] := Sol[I];
        end;
      end;
    end;
  end;

  { Оркестровка: приоры → [тормоза → окна → IRLS] × OuterLoops. }
  procedure SolveIrls(out CovOut: TMatN; out CovOk: Boolean;
    out SigP, SigC: Double);
  const
    OUTER_LOOPS = 4;
  var
    Outer, I: Integer;
  begin
    for I := 0 to NPar - 1 do X[I] := PriorVal[I];
    SigP := 0; SigC := 0;
    CovOk := False;
    FillChar(CovOut, SizeOf(CovOut), 0);
    for Outer := 1 to OUTER_LOOPS do
    begin
      MarkBrakes;
      BuildWindows;
      if NFitRows < 12 then Exit;
      {$IFDEF ESTDEBUG}
      WriteLn('DBG внешняя итерация ', Outer, ', окон: ', NFitRows);
      DebugTrueResiduals;
      WriteLn(Format('DBG текущие x: m=%.1f mCrr=%.3f CdA=%.3f',
        [X[0], X[1], X[2]]));
      {$ENDIF}
      SolveWindowsIrls(CovOut, CovOk, SigP, SigC);
    end;
    { финальные поточечные строки/невязки для выхода }
    BuildPointRows;
    ComputePointResiduals;
    { пометить точки, накрытые окнами, весом окна }
    for I := 0 to NS - 1 do WP[I].W := 0;
    for Outer := 0 to NFitRows - 1 do
      for I := FitRows[Outer].I0 to FitRows[Outer].I1 do
        WP[I].W := FitRows[Outer].W;
  end;

  { ── финальная раскладка сил и статистика ── }
  procedure FillOutputs(const Cov: TMatN; CovOk: Boolean;
    SigP, SigC: Double);
  var
    I, NP2, NC2: Integer;
    Inv: TMatN;
    InvOk: Boolean;
    VarM, VarMC, CovMMc, VarCdA: Double;
    Fg, Fr, Fa, Fi, Fb, Fp: Double;
    SumP2, SumC2: Double;
    Dt, PrevBrake: Double;
    EPed, EAero, ERoll, EBrake: Double;
    Asc, Desc, Dh: Double;
  begin
    Inv := Cov;              { уже маргинальная ковариация }
    InvOk := CovOk;

    MassKg := X[0];
    Crr := 0;
    if Abs(X[0]) > 1e-6 then Crr := X[1] / X[0];
    CdA := X[2];

    Est.MassKg := MassKg;
    Est.CdA := CdA;
    Est.Crr := Crr;

    if InvOk then
    begin
      VarM := Max(Inv[0][0], 0);
      VarMC := Max(Inv[1][1], 0);
      CovMMc := Inv[0][1];
      VarCdA := Max(Inv[2][2], 0);
      Est.MassCi95 := 1.96 * Sqrt(VarM);
      Est.CdACi95 := 1.96 * Sqrt(VarCdA);
      { дельта-метод для Crr = x₂/x₁ }
      if Abs(MassKg) > 1e-6 then
        Est.CrrCi95 := 1.96 * Sqrt(Max(
          VarMC / Sqr(MassKg)
          + Sqr(X[1]) * VarM / Sqr(Sqr(MassKg))
          - 2 * X[1] * CovMMc / (Sqr(MassKg) * MassKg), 0));
      { Доля информации о массе из приора: prior_weight × Var(m). }
      Est.MassPriorShare := EnsureRange(PriorW[0] * Max(Inv[0][0], 0), 0, 1);
    end;

    { Размах модельного дрейфа барометра, м (DE/(m·g)). }
    if (Length(DriftX) > 0) and (Abs(MassKg) > 1) then
    begin
      VarM := DriftX[0]; VarMC := DriftX[0];
      for I := 1 to High(DriftX) do
      begin
        if DriftX[I] > VarM then VarM := DriftX[I];
        if DriftX[I] < VarMC then VarMC := DriftX[I];
      end;
      Est.BaroDriftRangeM := (VarM - VarMC) / (MassKg * G);
    end;

    {$IFDEF ESTDEBUG}
    if InvOk and (Inv[0][0] > 0) and (Inv[1][1] > 0) and (Inv[2][2] > 0) then
      WriteLn(Format('DBG corr: m↔mCrr %.2f, m↔CdA %.2f, mCrr↔CdA %.2f; SigP=%.0f SigC=%.0f',
        [Inv[0][1] / Sqrt(Inv[0][0] * Inv[1][1]),
         Inv[0][2] / Sqrt(Inv[0][0] * Inv[2][2]),
         Inv[1][2] / Sqrt(Inv[1][1] * Inv[2][2]), SigP, SigC]));
    {$ENDIF}
    Est.WindEstimated := UseWind;
    if UseWind and (Abs(CdA) > 1e-4) then
    begin
      Est.WindSpeedMs := Sqrt(Sqr(X[3]) + Sqr(X[4])) / CdA;
      { x₄,x₅ — компоненты ветра НАВСТРЕЧУ; «откуда дует» = их направление }
      Est.WindDirRad := ArcTan2(X[4], X[3]);
    end
    else if Cfg.WindKnown then
    begin
      { Ветер задан извне — просто возвращаем его в результат. }
      Est.WindSpeedMs := Cfg.WindKnownSpeedMs;
      Est.WindDirRad := Cfg.WindKnownFromRad;
    end;

    SetLength(Points, NS);
    SumP2 := 0; SumC2 := 0; NP2 := 0; NC2 := 0;
    EPed := 0; EAero := 0; ERoll := 0; EBrake := 0;
    Asc := 0; Desc := 0;
    Est.NumPedal := 0; Est.NumCoast := 0;
    Est.NumBrake := 0; Est.NumExcluded := 0;
    Est.NumBrakeEvents := 0;
    PrevBrake := 0;

    for I := 0 to NS - 1 do
    begin
      Fg := MassKg * G * WP[I].SinT;
      Fr := X[1] * G * WP[I].CosT;                 { x₂ = m·Crr }
      Fa := 0.5 * WP[I].Rho * CdA * Sqr(WP[I].V);
      if UseWind and WP[I].HasHeading then
        Fa := Fa + WP[I].Rho * WP[I].V *
          (X[3] * Cos(WP[I].Heading) + X[4] * Sin(WP[I].Heading));
      Fi := MassKg * (1.0 + Lam) * WP[I].A;
      Fp := 0;
      Fb := 0;


      case WP[I].Cls of
        rpcPedal:
          begin
            Fp := Eff * WP[I].P / Max(WP[I].V, 0.1);
            SumP2 := SumP2 + Sqr(WP[I].Resid * WP[I].V);
            Inc(NP2);
            Inc(Est.NumPedal);
          end;
        rpcCoast:
          begin
            SumC2 := SumC2 + Sqr(WP[I].Resid);
            Inc(NC2);
            Inc(Est.NumCoast);
          end;
        rpcBrake:
          begin
            Fb := Max(WP[I].Resid, 0);      { невязка = сила торможения }
            Inc(Est.NumBrake);
            if PrevBrake <= 0 then Inc(Est.NumBrakeEvents);
          end;
        rpcExcluded:
          Inc(Est.NumExcluded);
      end;
      PrevBrake := Fb;

      Points[I].TimeSec := WP[I].T;
      Points[I].DistanceM := WP[I].S;
      Points[I].SpeedMs := WP[I].V;
      Points[I].AccelMs2 := WP[I].A;
      Points[I].AltSmoothM := WP[I].Alt;
      Points[I].Grade := WP[I].Grade;
      Points[I].AirDensity := WP[I].Rho;
      Points[I].PointClass := WP[I].Cls;
      Points[I].UsedInFit := WP[I].W > 0;
      Points[I].FitWeight := WP[I].W;
      Points[I].FGravityN := Fg;
      Points[I].FRollingN := Fr;
      Points[I].RoadResistN := Fg + Fr;
      Points[I].FAeroN := Fa;
      Points[I].FInertiaN := Fi;
      Points[I].FBrakeN := Fb;
      Points[I].FPedalN := Fp;
      Points[I].ResidualForceN := WP[I].Resid;
      Points[I].ResidualPowerW := WP[I].Resid * WP[I].V;
      Points[I].EffSlopePct := 100.0 * (WP[I].SinT + Crr * WP[I].CosT);

      { энергоаудит }
      if I > 0 then
      begin
        Dt := WP[I].T - WP[I - 1].T;
        if (Dt > 0) and (Dt <= Cfg.MaxSampleGapSec) then
        begin
          if HasVal(WP[I].P) and (WP[I].P > 0) then
            EPed := EPed + Eff * WP[I].P * Dt;
          EAero := EAero + Fa * WP[I].V * Dt;
          ERoll := ERoll + Fr * WP[I].V * Dt;
          EBrake := EBrake + Fb * WP[I].V * Dt;
        end;
        Dh := WP[I].Alt - WP[I - 1].Alt;
        if Dh > 0 then Asc := Asc + Dh else Desc := Desc - Dh;
      end;
    end;

    if NP2 > 0 then Est.RmsPedalW := Sqrt(SumP2 / NP2);
    if NC2 > 0 then Est.RmsCoastN := Sqrt(SumC2 / NC2);

    Est.EPedalKJ := EPed / 1000;
    Est.EAeroKJ := EAero / 1000;
    Est.ERollKJ := ERoll / 1000;
    Est.EBrakeKJ := EBrake / 1000;
    Est.DeltaPeKJ := MassKg * G * (WP[NS - 1].Alt - WP[0].Alt) / 1000;
    Est.DeltaKeKJ := 0.5 * MassKg * (1.0 + Lam) *
      (Sqr(WP[NS - 1].V) - Sqr(WP[0].V)) / 1000;
    Est.EResidKJ := Est.EPedalKJ - Est.DeltaPeKJ - Est.DeltaKeKJ -
      Est.EAeroKJ - Est.ERollKJ - Est.EBrakeKJ;
    if Est.EPedalKJ > 0.001 then
      Est.EResidPct := 100.0 * Abs(Est.EResidKJ) / Est.EPedalKJ;

    Est.TotalDistKm := (WP[NS - 1].S - WP[0].S) / 1000;
    Est.TotalTimeSec := WP[NS - 1].T - WP[0].T;
    Est.AscentM := Asc;
    Est.DescentM := Desc;
    Est.NumSamples := NS;
  end;

var
  Cov: TMatN;
  CovOk: Boolean;
  SigP, SigC: Double;
  I, NRows: Integer;
begin
  Result := False;
  FillChar(Est, SizeOf(Est), 0);
  Points := nil;
  NS := Length(Samples);

  G := Cfg.GravityMs2;
  Lam := Cfg.RotMassFactor;
  Eff := Cfg.DrivetrainEff;

  if NS < 60 then
  begin
    Est.Message := 'Слишком мало точек (< 60)';
    Exit;
  end;

  HasCadenceSensor := False;
  HasPowerData := False;
  UseWind := False;
  NPar := 3;

  { Приоры нужны до предобработки (лаг-компенсация использует m₀). }
  PriorVal[0] := Cfg.RiderProfileMassKg + Cfg.BikeMassGuessKg;
  PriorW[0]   := 1.0 / Sqr(Max(Cfg.MassPriorSigmaKg, 0.5));
  PriorVal[1] := PriorVal[0] * Cfg.CrrPrior;
  PriorW[1]   := 1.0 / Sqr(Max(PriorVal[0] * Cfg.CrrPriorSigma, 1e-4));
  PriorVal[2] := Cfg.CdAPrior;
  PriorW[2]   := 1.0 / Sqr(Max(Cfg.CdAPriorSigma, 1e-3));
  PriorVal[3] := 0;
  PriorW[3]   := 1.0 / Sqr(0.35 * 6.0);   { CdA·W: ветер 0 ± 6 м/с }
  PriorVal[4] := 0;
  PriorW[4]   := PriorW[3];

  Preprocess;

  if not HasPowerData then
  begin
    Est.Message := 'В файле нет данных мощности — полная оценка невозможна';
    Exit;
  end;

  { Высота обязательна: без неё уклон = 0 и вся гравитация уедет в Crr. }
  if not HasVal(Samples[0].AltM) then
  begin
    Est.Message := 'В файле нет высоты (altitude) — уклон неизвестен';
    Exit;
  end;

  CompensatePowerLag;
  Classify;

  NRows := 0;
  for I := 0 to NS - 1 do
    if WP[I].Cls in [rpcPedal, rpcCoast] then Inc(NRows);
  if NRows < 120 then
  begin
    Est.Message := Format('Слишком мало пригодных точек: %d', [NRows]);
    Exit;
  end;

  { Узлы дрейф-сплайна барометра. }
  KnotT0 := WP[0].T;
  KnotDT := Max(Cfg.DriftKnotSec, 20);
  NDrift := Trunc((WP[NS - 1].T - WP[0].T) / KnotDT) + 2;
  if NDrift > 240 then
  begin
    NDrift := 240;
    KnotDT := (WP[NS - 1].T - WP[0].T) / (NDrift - 1) + 1e-6;
  end;
  SetLength(DriftX, 0);
  { Скорость RW-дрейфа барометра — свойство ЖЕЛЕЗА (конфиг).
    Белая компонента шума оценивается из данных онлайн. }
  RwEst := Max(Cfg.BaroRwSigma, 0);

  SolveIrls(Cov, CovOk, SigP, SigC);
  if NFitRows < 12 then
  begin
    Est.Message := Format('Слишком мало окон подгонки: %d', [NFitRows]);
    Exit;
  end;
  FillOutputs(Cov, CovOk, SigP, SigC);

  { Экспорт окон для совместной многозаездной оценки: копия строк
    (дрейф-узлы зануляем — совместный солвер без сплайна), их
    EIV-дисперсии по столбцу массы, финальные сигмы. }
  OutRows := Copy(FitRows, 0, NFitRows);
  SetLength(OutEiv, NFitRows);
  for I := 0 to NFitRows - 1 do
  begin
    OutRows[I].NKnots := 0;
    OutEiv[I] := Sqr(G) *
      (AltWhiteVar *
       (1.0 / Max(WP[FitRows[I].I0].NLite, 1) +
        1.0 / Max(WP[FitRows[I].I1].NLite, 1))
       + Sqr(RwEst) *
         (WP[FitRows[I].I1].T - WP[FitRows[I].I0].T));
  end;
  OutSigP := SigP;
  OutSigC := SigC;
  OutHadHeading := UseWind;

  Est.Success := True;
  if Est.MassPriorShare > 0.5 then
    Est.Message := 'Внимание: масса определена в основном приором ' +
      '(заезд слишком плоский/равномерный)'
  else if Est.NumCoast < 30 then
    Est.Message := 'Внимание: мало накатных точек — Crr/CdA менее надёжны'
  else
    Est.Message := 'OK';
  Result := True;
end;

{ ═══ Форматирование ═══════════════════════════════════════════════ }

{ ── Совместная многозаездная оценка ─────────────────────────────── }

function EstimateMultiRideParameters(
  const ARides: array of TRideSampleArray;
  const Cfg: TRideEstimatorConfig;
  out MEst: TMultiRideEstimate): Boolean;
const
  G = 9.80665;
var
  R, NW, NTot, I, J, K, Q, Iter, RideI: Integer;
  CfgW: TRideEstimatorConfig;
  Est1: TRideEstimate;
  Pts1: TRidePointResultArray;
  RowsR: array of TFitRowArray;
  EivR: array of TDVec;
  SigPR, SigCR: TDVec;
  HadHdg: array of Boolean;
  WCol: array of Integer;          { базовая колонка ветра заезда; -1 }
  NE, NESave: TDMat;
  RHS, Sol, EVec, X: TDVec;
  Idx: array [0..5] of Integer;
  Cf: array [0..5] of Double;
  NIdx: Integer;
  PriorW0, PriorWCdA, PriorWCrr, PriorWWind, M0: Double;
  SigRow, AbsRes, HW, Scale, Ax, Fuller: Double;
  ResP, ResC: TDVec;
  NResP, NResC: Integer;
  CovCols: TDMat;                  { маргинальные столбцы ковариации }
  CovOk: Boolean;
  VarM, VarMC, CovMMC, MC: Double;

  function ColOfLocal(ARide, ALocal: Integer): Integer;
  begin
    case ALocal of
      0: Result := 0;                    { m — общий }
      2: Result := 1;                    { CdA — общий }
      1: Result := 2 + ARide;            { m·Crr_r }
      3: Result := WCol[ARide];          { CdA·Wx_r }
      4: Result := WCol[ARide] + 1;      { CdA·Wy_r }
    else
      Result := -1;
    end;
  end;

begin
  Result := False;
  FillChar(MEst, SizeOf(MEst), 0);
  MEst.Valid := False;
  R := Length(ARides);
  MEst.NRides := R;
  if R < 2 then
  begin
    MEst.Message := 'Нужно минимум два заезда';
    Exit;
  end;

  { Одиночные прогоны — вся предобработка честно реюзается. Ветер
    просим всегда: при наличии курса строки получат колонки 3..4,
    без курса — колонки нулевые и параметры не создаются. }
  CfgW := Cfg;
  CfgW.EstimateWind := True;
  SetLength(RowsR, R);
  SetLength(EivR, R);
  SetLength(SigPR, R);
  SetLength(SigCR, R);
  SetLength(HadHdg, R);
  SetLength(WCol, R);
  for I := 0 to R - 1 do
  begin
    if not EstimateRideParametersEx(ARides[I], CfgW, Est1, Pts1,
      RowsR[I], EivR[I], SigPR[I], SigCR[I], HadHdg[I]) then
    begin
      MEst.Message := Format('Заезд %d: %s', [I + 1, Est1.Message]);
      Exit;
    end;
    if Length(RowsR[I]) < 12 then
    begin
      MEst.Message := Format('Заезд %d: слишком мало окон', [I + 1]);
      Exit;
    end;
  end;

  { Раскладка колонок: [m, CdA] + Crr пер-заезда + ветра «курсовых». }
  NW := 0;
  for I := 0 to R - 1 do
    if HadHdg[I] then
    begin
      WCol[I] := 2 + R + 2 * NW;
      Inc(NW);
    end
    else
      WCol[I] := -1;
  NTot := 2 + R + 2 * NW;

  SetLength(NE, NTot);
  SetLength(NESave, NTot);
  for I := 0 to NTot - 1 do
  begin
    SetLength(NE[I], NTot);
    SetLength(NESave[I], NTot);
  end;
  SetLength(RHS, NTot);
  SetLength(EVec, NTot);
  SetLength(X, NTot);

  { Приоры (те же величины, что в одиночной оценке). }
  M0 := Cfg.RiderProfileMassKg + Cfg.BikeMassGuessKg;
  PriorW0    := 1.0 / Sqr(Max(Cfg.MassPriorSigmaKg, 0.5));
  PriorWCdA  := 1.0 / Sqr(Max(Cfg.CdAPriorSigma, 1e-3));
  PriorWCrr  := 1.0 / Sqr(Max(M0 * Cfg.CrrPriorSigma, 1e-4));
  PriorWWind := 1.0 / Sqr(0.35 * 6.0);

  { Старт: приорные значения. }
  X[0] := M0;
  X[1] := Cfg.CdAPrior;
  for I := 0 to R - 1 do
    X[2 + I] := M0 * Cfg.CrrPrior;
  for I := 2 + R to NTot - 1 do
    X[I] := 0;

  SetLength(ResP, 4096);
  SetLength(ResC, 4096);
  CovOk := False;
  SetLength(CovCols, 2 + R);

  for Iter := 1 to Cfg.Iterations do
  begin
    { Сигмы по группам (заезд × класс) из текущих невязок. }
    for RideI := 0 to R - 1 do
    begin
      NResP := 0;
      NResC := 0;
      for I := 0 to High(RowsR[RideI]) do
      begin
        Ax := 0;
        for J := 0 to 4 do
        begin
          K := ColOfLocal(RideI, J);
          if K >= 0 then
            Ax := Ax + RowsR[RideI][I].A[J] * X[K];
        end;
        if WCol[RideI] >= 0 then
          Ax := Ax + WindQuadOfRow(RowsR[RideI][I],
            X[WCol[RideI]], X[WCol[RideI] + 1], X[1]);
        RowsR[RideI][I].Resid := RowsR[RideI][I].B - Ax;
        if RowsR[RideI][I].Cls = rpcPedal then
        begin
          if NResP >= Length(ResP) then SetLength(ResP, Length(ResP) * 2);
          ResP[NResP] := RowsR[RideI][I].Resid;
          Inc(NResP);
        end
        else
        begin
          if NResC >= Length(ResC) then SetLength(ResC, Length(ResC) * 2);
          ResC[NResC] := RowsR[RideI][I].Resid;
          Inc(NResC);
        end;
      end;
      if NResP >= 6 then SigPR[RideI] := Max(RobustSigma(ResP, NResP), 50);
      if NResC >= 6 then SigCR[RideI] := Max(RobustSigma(ResC, NResC), 25);
    end;

    { Сборка нормальных уравнений. }
    for I := 0 to NTot - 1 do
    begin
      RHS[I] := 0;
      for J := 0 to NTot - 1 do NE[I][J] := 0;
    end;
    NE[0][0] := PriorW0;             RHS[0] := PriorW0 * M0;
    NE[1][1] := PriorWCdA;           RHS[1] := PriorWCdA * Cfg.CdAPrior;
    for I := 0 to R - 1 do
    begin
      NE[2 + I][2 + I] := PriorWCrr;
      RHS[2 + I] := PriorWCrr * M0 * Cfg.CrrPrior;
      if WCol[I] >= 0 then
      begin
        NE[WCol[I]][WCol[I]]         := PriorWWind;
        NE[WCol[I] + 1][WCol[I] + 1] := PriorWWind;
      end;
    end;

    Fuller := 0;
    for RideI := 0 to R - 1 do
      for I := 0 to High(RowsR[RideI]) do
      begin
        if RowsR[RideI][I].Cls = rpcPedal then SigRow := SigPR[RideI]
        else SigRow := SigCR[RideI];
        AbsRes := Abs(RowsR[RideI][I].Resid);
        if AbsRes <= Cfg.HuberK * SigRow then
          HW := 1.0
        else
          HW := Cfg.HuberK * SigRow / AbsRes;
        Scale := HW / Sqr(SigRow);
        RowsR[RideI][I].W := Scale;
        Fuller := Fuller + Scale * EivR[RideI][I];

        NIdx := 0;
        for J := 0 to 4 do
        begin
          K := ColOfLocal(RideI, J);
          if K >= 0 then
          begin
            Idx[NIdx] := K;
            Cf[NIdx] := RowsR[RideI][I].A[J];
            Inc(NIdx);
          end;
        end;
        { b_eff: квадратичная ветровая поправка (Гаусс-Ньютон). }
        Ax := RowsR[RideI][I].B;
        if WCol[RideI] >= 0 then
          Ax := Ax - WindQuadOfRow(RowsR[RideI][I],
            X[WCol[RideI]], X[WCol[RideI] + 1], X[1]);
        for J := 0 to NIdx - 1 do
        begin
          RHS[Idx[J]] := RHS[Idx[J]] + Scale * Cf[J] * Ax;
          for Q := 0 to NIdx - 1 do
            NE[Idx[J]][Idx[Q]] := NE[Idx[J]][Idx[Q]] +
              Scale * Cf[J] * Cf[Q];
        end;
      end;

    { EIV-поправка Фуллера по столбцу массы (та же, что в одиночной). }
    Fuller := Min(Fuller, 0.7 * Max(NE[0][0] - PriorW0, 0));
    NE[0][0] := NE[0][0] - Fuller;

    for I := 0 to NTot - 1 do
      for J := 0 to NTot - 1 do
        NESave[I][J] := NE[I][J];

    if not SolveLinDyn(NTot, NE, RHS, Sol) then
    begin
      MEst.Message := 'Вырожденная совместная система';
      Exit;
    end;
    for I := 0 to NTot - 1 do X[I] := Sol[I];

    if Iter = Cfg.Iterations then
    begin
      CovOk := True;
      for K := 0 to 2 + R - 1 do
      begin
        for I := 0 to NTot - 1 do
        begin
          EVec[I] := 0;
          for J := 0 to NTot - 1 do NE[I][J] := NESave[I][J];
        end;
        EVec[K] := 1;
        if not SolveLinDyn(NTot, NE, EVec, Sol) then
        begin
          CovOk := False;
          Break;
        end;
        CovCols[K] := Copy(Sol, 0, NTot);
      end;
    end;
  end;

  { Выход. }
  MEst.MassKg := X[0];
  MEst.CdA := X[1];
  SetLength(MEst.RideCrr, R);
  SetLength(MEst.RideCrrCI95, R);
  SetLength(MEst.RideWindMs, R);
  SetLength(MEst.RideWindDirRad, R);
  if CovOk then
  begin
    MEst.MassCI95 := 1.96 * Sqrt(Max(CovCols[0][0], 0));
    MEst.CdACI95  := 1.96 * Sqrt(Max(CovCols[1][1], 0));
  end;
  for I := 0 to R - 1 do
  begin
    MC := X[2 + I];
    MEst.RideCrr[I] := MC / Max(X[0], 1);
    if CovOk then
    begin
      VarM  := Max(CovCols[0][0], 0);
      VarMC := Max(CovCols[2 + I][2 + I], 0);
      CovMMC := CovCols[0][2 + I];
      { дельта-метод: Var(mc/m) ≈ Var(mc)/m² + mc²·Var(m)/m⁴
        − 2·mc·Cov/m³ }
      MEst.RideCrrCI95[I] := 1.96 * Sqrt(Max(
        VarMC / Sqr(X[0]) + Sqr(MC) * VarM / Sqr(Sqr(X[0]))
        - 2 * MC * CovMMC / (Sqr(X[0]) * X[0]), 0));
    end;
    if (WCol[I] >= 0) and (Abs(X[1]) > 1e-3) then
    begin
      MEst.RideWindMs[I] :=
        Sqrt(Sqr(X[WCol[I]]) + Sqr(X[WCol[I] + 1])) / X[1];
      MEst.RideWindDirRad[I] :=
        ArcTan2(X[WCol[I] + 1], X[WCol[I]]);
    end;
  end;
  MEst.Valid := True;
  MEst.Message := 'OK';
  Result := True;
end;

function FormatMultiRideEstimate(const MEst: TMultiRideEstimate): string;
var
  FS: TFormatSettings;
  I: Integer;
  NL: string;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  NL := LineEnding;
  if not MEst.Valid then
    Exit('Совместная оценка не выполнена: ' + MEst.Message);
  Result :=
    '══ Совместная оценка по ' + IntToStr(MEst.NRides) + ' заездам ══' + NL +
    Format('  Масса (райдер+вел): %6.1f ± %.1f кг', [MEst.MassKg, MEst.MassCI95], FS) + NL +
    Format('  CdA:                %6.3f ± %.3f м²', [MEst.CdA, MEst.CdACI95], FS) + NL;
  for I := 0 to MEst.NRides - 1 do
  begin
    Result := Result + Format('  Заезд %d: Crr %.4f ± %.4f',
      [I + 1, MEst.RideCrr[I], MEst.RideCrrCI95[I]], FS);
    if MEst.RideWindMs[I] > 0.05 then
      Result := Result + Format('   ветер %.1f м/с, откуда %.0f°',
        [MEst.RideWindMs[I],
         MEst.RideWindDirRad[I] * 180 / Pi], FS);
    Result := Result + NL;
  end;
end;

function EstimateRideParameters(const Samples: TRideSampleArray;
  const Cfg: TRideEstimatorConfig;
  out Est: TRideEstimate;
  out Points: TRidePointResultArray): Boolean;
var
  Rows: TFitRowArray;
  Eiv: TDVec;
  SP, SC: Double;
  HH: Boolean;
begin
  Result := EstimateRideParametersEx(Samples, Cfg, Est, Points,
    Rows, Eiv, SP, SC, HH);
end;

function FormatRideEstimate(const Est: TRideEstimate): string;
const
  NL = LineEnding;
var
  FS: TFormatSettings;
begin
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  Result :=
    '══ Оценка параметров заезда ══' + NL +
    Format('  Масса (райдер+вел): %7.1f ± %.1f кг', [Est.MassKg, Est.MassCi95], FS) + NL +
    Format('  CdA:                %7.3f ± %.3f м²', [Est.CdA, Est.CdACi95], FS) + NL +
    Format('  Crr:                %7.4f ± %.4f', [Est.Crr, Est.CrrCi95], FS) + NL;
  if Est.WindEstimated then
    Result := Result + Format('  Ветер:              %5.1f м/с, откуда %.0f°',
      [Est.WindSpeedMs, RadToDeg(Est.WindDirRad)], FS) + NL;
  if Est.BaroDriftRangeM > 0.05 then
    Result := Result +
      Format('  Дрейф барометра (модель): размах %.1f м',
        [Est.BaroDriftRangeM], FS) + NL;
  Result := Result +
    Format('  Доля приора в массе: %4.0f %%  (>50%% = заезд не информативен по массе)',
      [Est.MassPriorShare * 100], FS) + NL +
    '── Точки ──' + NL +
    Format('  всего %d: педалирование %d, накат %d, торможение %d (%d событий), исключено %d',
      [Est.NumSamples, Est.NumPedal, Est.NumCoast, Est.NumBrake,
       Est.NumBrakeEvents, Est.NumExcluded], FS) + NL +
    Format('  RMS невязки: %.1f Вт (педалирование), %.1f Н (накат)',
      [Est.RmsPedalW, Est.RmsCoastN], FS) + NL +
    '── Маршрут ──' + NL +
    Format('  %.2f км за %.0f с, набор +%.0f / спуск −%.0f м',
      [Est.TotalDistKm, Est.TotalTimeSec, Est.AscentM, Est.DescentM], FS) + NL +
    '── Энергоаудит ──' + NL +
    Format('  вход η·P: %8.1f кДж', [Est.EPedalKJ], FS) + NL +
    Format('  аэро:     %8.1f кДж   качение: %6.1f кДж   тормоза: %6.1f кДж',
      [Est.EAeroKJ, Est.ERollKJ, Est.EBrakeKJ], FS) + NL +
    Format('  ΔPE:      %8.1f кДж   ΔKE:     %6.1f кДж',
      [Est.DeltaPeKJ, Est.DeltaKeKJ], FS) + NL +
    Format('  невязка:  %8.1f кДж  (%.1f %% от входа)',
      [Est.EResidKJ, Est.EResidPct], FS) + NL +
    '── Статус ──' + NL +
    '  ' + Est.Message;
end;

function SaveRidePointsCsv(const Points: TRidePointResultArray;
  const FileName: string): Boolean;
const
  ClassNames: array [TRidePointClass] of string =
    ('excluded', 'pedal', 'coast', 'brake');
var
  SL: TStringList;
  I: Integer;
  FS: TFormatSettings;
begin
  Result := False;
  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';
  SL := TStringList.Create;
  try
    SL.Add('time_s;dist_m;speed_ms;accel_ms2;alt_m;grade_pct;eff_slope_pct;' +
      'rho;class;used;weight;F_gravity_N;F_rolling_N;F_road_N;F_aero_N;' +
      'F_inertia_N;F_brake_N;F_pedal_N;resid_N;resid_W');
    for I := 0 to High(Points) do
      with Points[I] do
        SL.Add(Format(
          '%.1f;%.1f;%.3f;%.3f;%.2f;%.2f;%.2f;%.4f;%s;%d;%.4f;' +
          '%.1f;%.1f;%.1f;%.1f;%.1f;%.1f;%.1f;%.2f;%.1f',
          [TimeSec, DistanceM, SpeedMs, AccelMs2, AltSmoothM,
           Grade * 100, EffSlopePct, AirDensity,
           ClassNames[PointClass], Ord(UsedInFit), FitWeight,
           FGravityN, FRollingN, RoadResistN, FAeroN, FInertiaN,
           FBrakeN, FPedalN, ResidualForceN, ResidualPowerW], FS));
    try
      SL.SaveToFile(FileName);
      Result := True;
    except
      on E: Exception do ;
    end;
  finally
    SL.Free;
  end;
end;

{ ── Оценка по минимуму колебаний параметров ──────────────────────── }
function EstimateRideMinVariance(const Samples: TRideSampleArray;
  const Cfg: TRideEstimatorConfig; ALog: TRideEstLogProc;
  out Est: TRideEstimate): Boolean;
const
  WIN_S     = 100.0;     { длина окна, с движущегося времени }
  VAR_S_MIN = 3.0e-4;    { порог идентифицируемости массы в окне (Var(s)) }
  MASS_LO   = 25.0;
  MASS_HI   = 160.0;
  PRIOR_W   = 0.02;      { вес слабых приоров CdA/Crr (только против границ) }
  CDA_LO    = 0.20;
  CDA_HI    = 0.50;
  CDA_STEP  = 0.01;
  WIND_MAX  = 8;         { перебор скорости ветра 0..8 м/с }
  WIND_DIRS = 12;        { направлений ветра }
  { Номинальные CdA/Crr ТОЛЬКО для оценки массы по подъёмам. Фиксированы
    (не из панели/оценки) — иначе climb-масса зависела бы от них, и
    фиксация Crr/CdA после авто меняла бы массу. Аэро на подъёме мало
    (CdA почти не влияет); Crr ~0.006 — физичное качение, при нём climb-
    масса совпадает с реальной. }
  CLIMB_CDA_NOM = 0.30;
  CLIMB_CRR_NOM = 0.006;
type
  TWin = record
    N: Integer;
    Lo, Hi: Integer;                       { диапазон [Lo,Hi) в отфильтр. массивах }
    SumS, SumSS, SumR, SumSR, VarS: Double; { фиксировано: s,R не зависят от ветра/CdA }
    IsClimb: Boolean;                       { средний уклон окна > порога (подъём) }
  end;
var
  T0, TS: QWord;
  N, I, J, K, Cnt, NW, WI, DI, NDir, KK, keptN, nEval: Integer;
  g, eta, vmin, rho, tmean, tcnt: Double;
  sgCda, sgCrr: Double;
  altRaw, altS, vRaw, vS, distA, tA, sinR, sinS, accA, accS: TDVec;
  sf, rf, vf, hf, tf, qf, sinf: TDVec;     { отфильтр. движущиеся точки }
  Wins: array of TWin;
  ws, wfr, cda, va, ddist, dt2, sn, ac: Double;
  SumQ, SumSQ, mk, crrk, wk, mtmp: TDVec;
  Sy, Ssy, det, Aa, Bb, med, mad, mw, cw, sw, cv, se, JJ: Double;
  bJ, bM, bCrr, bCda, bWs, bWf, bCv: Double;
  bNw: Integer;
  haveBest: Boolean;
  { Учёт зафиксированных юзером значений (панель: снятая «авто» → жёсткая
    сигма / WindKnown). Фикс. не перебираются и не переоцениваются. }
  MassFixed, CdAFixed, CrrFixed, WindFixed: Boolean;
  mFix, cdaLo, cdaHi, crrThis, objMw, objSw, objCv: Double;
  WsList, WfList, objk: TDVec;
  WciIdx: Integer;
  massClimb, massCvSave: Double;   { масса по подъёмам (проход 1) + её CV }
  massNwSave: Integer;
  twoPass: Boolean;

  procedure Smooth(const Src: TDVec; W: Integer; out Dst: TDVec);
  var i2, j2, lo, hi, c2: Integer; a2: Double;
  begin
    SetLength(Dst, Length(Src));
    if W < 1 then W := 1;
    for i2 := 0 to High(Src) do
    begin
      lo := i2 - W; if lo < 0 then lo := 0;
      hi := i2 + W; if hi > High(Src) then hi := High(Src);
      a2 := 0; c2 := 0;
      for j2 := lo to hi do begin a2 := a2 + Src[j2]; Inc(c2); end;
      if c2 > 0 then Dst[i2] := a2 / c2 else Dst[i2] := Src[i2];
    end;
  end;

  function MedianN(const Src: TDVec; C: Integer): Double;
  var i2: Integer; t: TDVec;
  begin
    Result := 0;
    if C <= 0 then Exit;
    SetLength(t, C);
    for i2 := 0 to C - 1 do t[i2] := Src[i2];
    SortDoubles(t, 0, C - 1);
    if Odd(C) then Result := t[C div 2]
    else Result := 0.5 * (t[C div 2 - 1] + t[C div 2]);
  end;

  function SIf(B: Boolean; const ST, SF: string): string;
  begin
    if B then Result := ST else Result := SF;
  end;

  { Один проход поиска (CdA×ветер). AClimbOnly — только окна-подъёмы (масса
    там не завязана на аэро). AFixMass — масса задана (AMassVal), тогда
    минимизируем разброс Crr; иначе минимизируем разброс массы. Пишет в
    bJ/bM/bCrr/bCda/bWs/bWf/bCv/bNw/haveBest. Читает окна/признаки/сетки
    из объемлющей функции. }
  procedure RunSearch(AClimbOnly, AFixMass, ANominalAero: Boolean; AMassVal: Double);
  var
    wci, ii, jj, kk2, kept2, nWind: Integer;
    ws2, wfr2, cda2, va2, sy2, ssy2, det2, aa2, bb2, crr2, loCda, hiCda: Double;
    med2, mad2, mw2, cw2, om2, os2, ocv2, jjv2: Double;
    minWin: Integer;
  begin
    haveBest := False; nEval := 0;
    bJ := 0; bM := 0; bCrr := 0; bCda := 0; bWs := 0; bWf := 0; bCv := 0; bNw := 0;
    if AClimbOnly then minWin := 3 else minWin := 5;   { подъёмов может быть мало }
    { Номинальное аэро (проход 1 по подъёмам): CdA=приор, ветер=0 — на
      подъёмах аэро мало, а поиск CdA/ветра там плохо обусловлен и смещает
      массу. Иначе — полный перебор по сеткам. }
    if ANominalAero then nWind := 1 else nWind := Length(WsList);
    for wci := 0 to nWind - 1 do
    begin
      if ANominalAero then begin ws2 := 0; wfr2 := 0; end
      else begin ws2 := WsList[wci]; wfr2 := WfList[wci]; end;
      for ii := 0 to Cnt - 1 do
      begin
        if ws2 > 0 then va2 := vf[ii] + ws2 * Cos(hf[ii] - wfr2) else va2 := vf[ii];
        qf[ii] := 0.5 * rho * va2 * Abs(va2);
      end;
      for jj := 0 to NW - 1 do
      begin
        SumQ[jj] := 0; SumSQ[jj] := 0;
        for ii := Wins[jj].Lo to Wins[jj].Hi - 1 do
        begin
          SumQ[jj]  := SumQ[jj]  + qf[ii];
          SumSQ[jj] := SumSQ[jj] + sf[ii] * qf[ii];
        end;
      end;
      if ANominalAero then begin loCda := Cfg.CdAPrior; hiCda := Cfg.CdAPrior; end
      else begin loCda := cdaLo; hiCda := cdaHi; end;
      cda2 := loCda;
      while cda2 <= hiCda + 1e-9 do
      begin
        Inc(nEval);
        kk2 := 0;
        for jj := 0 to NW - 1 do
        begin
          if Wins[jj].VarS < VAR_S_MIN then Continue;
          if AClimbOnly and (not Wins[jj].IsClimb) then Continue;   { только подъёмы }
          sy2  := Wins[jj].SumR  - cda2 * SumQ[jj];
          ssy2 := Wins[jj].SumSR - cda2 * SumSQ[jj];
          det2 := Wins[jj].N * Wins[jj].SumSS - Sqr(Wins[jj].SumS);
          if Abs(det2) < 1e-9 then Continue;
          bb2 := (Wins[jj].N * ssy2 - Wins[jj].SumS * sy2) / det2;      { m_k }
          aa2 := (Wins[jj].SumSS * sy2 - Wins[jj].SumS * ssy2) / det2;  { m·g·Crr }
          if (bb2 < MASS_LO) or (bb2 > MASS_HI) then Continue;
          if AFixMass then crr2 := aa2 / (AMassVal * g) else crr2 := aa2 / (bb2 * g);
          mk[kk2] := bb2; crrk[kk2] := crr2; wk[kk2] := Wins[jj].VarS * Wins[jj].N;
          if AFixMass then objk[kk2] := crr2 * 1000.0 else objk[kk2] := bb2;
          Inc(kk2);
        end;
        if kk2 >= minWin then
        begin
          med2 := MedianN(objk, kk2);
          for ii := 0 to kk2 - 1 do mtmp[ii] := Abs(objk[ii] - med2);
          mad2 := MedianN(mtmp, kk2) + 1e-6;
          mw2 := 0; cw2 := 0; om2 := 0; os2 := 0; kept2 := 0;
          for ii := 0 to kk2 - 1 do
            if Abs(objk[ii] - med2) < 3.5 * mad2 then
            begin
              mw2 := mw2 + wk[ii] * mk[ii]; cw2 := cw2 + wk[ii] * crrk[ii];
              om2 := om2 + wk[ii] * objk[ii]; os2 := os2 + wk[ii]; Inc(kept2);
            end;
          if (os2 > 0) and (kept2 >= minWin) then
          begin
            mw2 := mw2 / os2; cw2 := cw2 / os2; om2 := om2 / os2;
            ocv2 := 0;
            for ii := 0 to kk2 - 1 do
              if Abs(objk[ii] - med2) < 3.5 * mad2 then
                ocv2 := ocv2 + wk[ii] * Sqr(objk[ii] - om2);
            if om2 <> 0 then ocv2 := Sqrt(ocv2 / os2) / Abs(om2) else ocv2 := 1.0;
            jjv2 := ocv2 * ocv2;
            if not CdAFixed then
              jjv2 := jjv2 + PRIOR_W * Sqr((cda2 - Cfg.CdAPrior) / sgCda);
            if (not CrrFixed) and (not AFixMass) then
              jjv2 := jjv2 + PRIOR_W * Sqr((cw2 - Cfg.CrrPrior) / sgCrr);
            if (not haveBest) or (jjv2 < bJ) then
            begin
              haveBest := True; bJ := jjv2; bCda := cda2;
              bWs := ws2; bWf := wfr2; bCv := ocv2; bNw := kept2;
              if AFixMass then bM := AMassVal else bM := mw2;
              if CrrFixed then bCrr := Cfg.CrrPrior else bCrr := cw2;
            end;
          end;
        end;
        cda2 := cda2 + CDA_STEP;
        if ANominalAero or CdAFixed then Break;
      end;
    end;
  end;

  { Масса по подъёмам «уровнем»: на крутых участках (уклон > 4%) гравитация
    доминирует, m ≈ (R − CdA_ном·q)/(g·sinθ + a + g·Crr_ном). Робастная
    медиана по точкам. Именно УРОВЕНЬ сопротивления даёт массу (пооконный
    наклон её терял — на подъёме уклон ~постоянен). Ставит massNwSave/
    massCvSave; 0 если точек-подъёмов мало. }
  function ClimbMass(ACdA, ACrr: Double): Double;
  var
    i2, cc: Integer;
    num, den, mp, qp, medm, madm: Double;
    ms, dd: TDVec;
  begin
    Result := 0; massNwSave := 0; massCvSave := 1.0;
    SetLength(ms, Cnt); cc := 0;
    for i2 := 0 to Cnt - 1 do
    begin
      if sinf[i2] <= 0.04 then Continue;              { только подъёмы > 4% }
      den := sf[i2] + g * ACrr;                       { g·sinθ + a + g·Crr }
      if den < 0.3 then Continue;                     { знаменатель мал — пропуск }
      qp := 0.5 * rho * vf[i2] * vf[i2];
      num := rf[i2] - ACdA * qp;
      mp := num / den;
      if (mp > MASS_LO) and (mp < MASS_HI) then begin ms[cc] := mp; Inc(cc); end;
    end;
    if cc < 20 then Exit;                             { мало точек подъёмов }
    medm := MedianN(ms, cc);
    SetLength(dd, cc);
    for i2 := 0 to cc - 1 do dd[i2] := Abs(ms[i2] - medm);
    madm := MedianN(dd, cc);
    massNwSave := cc;
    if medm > 0 then massCvSave := 1.4826 * madm / medm else massCvSave := 1.0;
    Result := medm;
  end;

begin
  Result := False;
  FillChar(Est, SizeOf(Est), 0);   { Message — nil (out финализирован), безопасно }
  Est.Success := False;
  T0 := GetTickCount64;
  N := Length(Samples);
  if Assigned(ALog) then
    ALog(Format('мин.колебаний: старт, %d сэмплов', [N]));
  if N < 60 then begin Est.Message := 'слишком мало точек'; Exit; end;

  g := Cfg.GravityMs2;    if g <= 0 then g := 9.81;
  eta := Cfg.DrivetrainEff; if eta <= 0 then eta := 0.975;
  vmin := Cfg.MinSpeedMs; if vmin < 2.78 then vmin := 2.78;
  sgCda := Cfg.CdAPriorSigma; if sgCda < 1e-6 then sgCda := 1e-6;
  sgCrr := Cfg.CrrPriorSigma; if sgCrr < 1e-6 then sgCrr := 1e-6;

  { Плотность воздуха по средней температуре (уровень моря); нет темп → 1.20. }
  tmean := 0; tcnt := 0;
  for I := 0 to N - 1 do
    if (Samples[I].TempC > -40) and (Samples[I].TempC < 60) then
    begin tmean := tmean + Samples[I].TempC; tcnt := tcnt + 1; end;
  if tcnt > 0 then
  begin
    tmean := tmean / tcnt;
    rho := 101325.0 / (287.05 * (273.15 + tmean));
  end
  else rho := 1.20;

  { ── Этап 1: признаки s = g·sinθ + a, R = η·P/v (движущиеся точки) ── }
  TS := GetTickCount64;
  SetLength(altRaw, N); SetLength(vRaw, N); SetLength(distA, N); SetLength(tA, N);
  for I := 0 to N - 1 do
  begin
    altRaw[I] := Samples[I].AltM;
    vRaw[I]   := Samples[I].SpeedMs;
    distA[I]  := Samples[I].DistanceM;
    tA[I]     := Samples[I].TimeSec;
  end;
  Smooth(altRaw, 5, altS);   { ~11 точек ≈ 11 с при 1 Гц }
  Smooth(vRaw, 2, vS);
  SetLength(sinR, N); SetLength(accA, N);
  for I := 0 to N - 1 do
  begin
    sn := 0; ac := 0;
    if (I > 0) and (I < N - 1) then
    begin
      ddist := distA[I + 1] - distA[I - 1];
      if ddist > 0.4 then sn := (altS[I + 1] - altS[I - 1]) / ddist;
      dt2 := tA[I + 1] - tA[I - 1];
      if dt2 > 0 then ac := (vS[I + 1] - vS[I - 1]) / dt2;
    end;
    sinR[I] := sn; accA[I] := ac;
  end;
  Smooth(sinR, 5, sinS);     { сгладить уклон }
  Smooth(accA, 2, accS);     { сгладить ускорение (grad шумит) — отдельный массив }

  SetLength(sf, N); SetLength(rf, N); SetLength(vf, N);
  SetLength(hf, N); SetLength(tf, N); SetLength(sinf, N);
  Cnt := 0;
  for I := 0 to N - 1 do
  begin
    if (vRaw[I] <= vmin) or (Samples[I].PowerW <= 0) then Continue;
    sn := sinS[I]; if sn > 0.25 then sn := 0.25 else if sn < -0.25 then sn := -0.25;
    ac := accS[I]; if ac > 2 then ac := 2 else if ac < -2 then ac := -2;
    sf[Cnt] := g * sn + ac;
    sinf[Cnt] := sn;               { чистый уклон — для порога подъёма }
    rf[Cnt] := eta * Samples[I].PowerW / vRaw[I];
    vf[Cnt] := vRaw[I];
    hf[Cnt] := Samples[I].HeadingRad;
    tf[Cnt] := tA[I];
    Inc(Cnt);
  end;
  SetLength(sf, Cnt); SetLength(rf, Cnt); SetLength(vf, Cnt);
  SetLength(hf, Cnt); SetLength(tf, Cnt); SetLength(qf, Cnt); SetLength(sinf, Cnt);
  if Assigned(ALog) then
    ALog(Format('признаки: %d движущихся точек, ρ=%.3f, %d мс',
      [Cnt, rho, GetTickCount64 - TS]));
  if Cnt < 40 then begin Est.Message := 'мало движущихся точек'; Exit; end;

  { ── Этап 2: окна ~WIN_S с движущегося времени ── }
  TS := GetTickCount64;
  NW := 0; SetLength(Wins, Cnt div 15 + 2);
  I := 0;
  while I < Cnt do
  begin
    J := I;
    while (J < Cnt) and (tf[J] - tf[I] <= WIN_S) do Inc(J);
    if J - I >= 20 then
    begin
      Wins[NW].Lo := I; Wins[NW].Hi := J; Wins[NW].N := J - I;
      Inc(NW);
    end;
    I := J;
  end;
  SetLength(Wins, NW);
  { фиксированные суммы окна (s,R не зависят от ветра/CdA) }
  for J := 0 to NW - 1 do
  begin
    Wins[J].SumS := 0; Wins[J].SumSS := 0; Wins[J].SumR := 0; Wins[J].SumSR := 0;
    for I := Wins[J].Lo to Wins[J].Hi - 1 do
    begin
      Wins[J].SumS  := Wins[J].SumS  + sf[I];
      Wins[J].SumSS := Wins[J].SumSS + sf[I] * sf[I];
      Wins[J].SumR  := Wins[J].SumR  + rf[I];
      Wins[J].SumSR := Wins[J].SumSR + sf[I] * rf[I];
    end;
    Wins[J].VarS := Wins[J].SumSS / Wins[J].N
                    - Sqr(Wins[J].SumS / Wins[J].N);
    { Подъём: средний s ≈ g·средний уклон (ускорение усредняется в ноль).
      Порог ~1.5% — там гравитация доминирует, аэро мало (низкая скорость),
      масса определяется чисто, без завязки на CdA/спуски. }
    Wins[J].IsClimb := (Wins[J].SumS / Wins[J].N) > (g * 0.015);
  end;
  if Assigned(ALog) then
    ALog(Format('окон %d (по %.0f с), %d мс', [NW, WIN_S, GetTickCount64 - TS]));
  if NW < 5 then
  begin
    Est.Message := 'мало окон';
    Est.MassKg := Cfg.RiderProfileMassKg + Cfg.BikeMassGuessKg;
    Est.CdA := Cfg.CdAPrior; Est.Crr := Cfg.CrrPrior; Est.MassPriorShare := 1.0;
    Exit;
  end;

  { ── Этап 3: поиск (CdA, ветер), минимизирующий колебания ── }
  TS := GetTickCount64;
  SetLength(SumQ, NW); SetLength(SumSQ, NW);
  SetLength(mk, NW); SetLength(crrk, NW); SetLength(wk, NW);
  SetLength(mtmp, NW); SetLength(objk, NW);

  { Что зафиксировано юзером (панель кодирует жёсткими сигмами / WindKnown). }
  MassFixed := Cfg.MassPriorSigmaKg < 1.0;
  CdAFixed  := Cfg.CdAPriorSigma   < 0.02;
  CrrFixed  := Cfg.CrrPriorSigma   < 0.001;
  WindFixed := Cfg.WindKnown;
  mFix := Cfg.RiderProfileMassKg + Cfg.BikeMassGuessKg;  { при фиксе Bike=0 }

  { Кандидаты ветра: фикс → один; иначе сетка 0..8 м/с × направления. }
  if WindFixed then
  begin
    SetLength(WsList, 1); SetLength(WfList, 1);
    WsList[0] := Cfg.WindKnownSpeedMs; WfList[0] := Cfg.WindKnownFromRad;
  end
  else
  begin
    SetLength(WsList, 1 + WIND_MAX * WIND_DIRS);
    SetLength(WfList, 1 + WIND_MAX * WIND_DIRS);
    K := 0; WsList[0] := 0; WfList[0] := 0; Inc(K);
    for WI := 1 to WIND_MAX do
      for DI := 0 to WIND_DIRS - 1 do
      begin
        WsList[K] := WI; WfList[K] := 2 * Pi * DI / WIND_DIRS; Inc(K);
      end;
    SetLength(WsList, K); SetLength(WfList, K);
  end;
  { Границы CdA: фикс → одно значение. }
  if CdAFixed then begin cdaLo := Cfg.CdAPrior; cdaHi := Cfg.CdAPrior; end
  else begin cdaLo := CDA_LO; cdaHi := CDA_HI; end;

  { ── Двухпроходно (если масса не задана): сперва масса ТОЛЬКО по подъёмам
    (там аэро мало → масса не завязана на CdA/спуски), фиксируем её, затем
    считаем остальное. Масса задана юзером → один проход. Подъёмов мало →
    обычный однопроходный расчёт по всему заезду. }
  twoPass := False; massClimb := 0; massCvSave := 1.0; massNwSave := 0;
  if MassFixed then
    RunSearch(False, True, False, mFix)
  else
  begin
    { Проход 1: масса по подъёмам. САМО-СОГЛАСОВАНИЕ: сперва с номинальными
      CdA/Crr, затем уточняем массу уже с ОЦЕНЁННЫМИ CdA/Crr. Без этого
      оценка массы зависела от номинального Crr, и фиксация Crr на его же
      значении (после авто) заметно меняла массу — на 4% подъёме g·Crr это
      20–35% от g·sinθ. }
    { Масса по подъёмам — с ФИКСИРОВАННЫМ номиналом CdA/Crr (не из панели):
      так масса не зависит от того, заданы/на авто ли CdA и Crr, и фиксация
      их после авто массу не меняет. Итерация с оценёнными CdA/Crr не
      нужна и вредна — оценённый Crr завышен (из-за низкого CdA) и занижал
      бы массу. }
    massClimb := ClimbMass(CLIMB_CDA_NOM, CLIMB_CRR_NOM);
    if (massClimb > MASS_LO) and (massNwSave >= 20) then
    begin
      twoPass := True;
      if Assigned(ALog) then
        ALog(Format('проход 1 (подъёмы, уровень): масса %.1f кг, точек %d, '
          + 'разброс %.0f%%', [massClimb, massNwSave, massCvSave * 100]));
      RunSearch(False, True, False, massClimb);   { проход 2: CdA/Crr/ветер при массе }
    end
    else
    begin
      if Assigned(ALog) then
        ALog('подъёмов мало — однопроходный расчёт по всему заезду');
      RunSearch(False, False, False, 0.0);        { fallback }
    end;
  end;
  if Assigned(ALog) then
    ALog(Format('поиск CdA×ветер: %d вычислений, %d мс',
      [nEval, GetTickCount64 - TS]));

  { ── Этап 4: итог + флаг надёжности (SE средней массы) ── }
  if not haveBest then
  begin
    Est.Message := 'нет окон с уклоном/инерцией — массу определить нельзя';
    Est.MassKg := Cfg.RiderProfileMassKg + Cfg.BikeMassGuessKg;
    Est.CdA := Cfg.CdAPrior; Est.Crr := Cfg.CrrPrior; Est.MassPriorShare := 1.0;
    if Assigned(ALog) then ALog('мин.колебаний: масса не определима — приор');
    Exit;
  end;
  { SE средней массы: в двухпроходе — из прохода 1 (масса по подъёмам);
    в однопроходе-авто — из разброса массы; при заданной массе — нет. }
  if MassFixed then se := 0
  else if twoPass then se := massCvSave   { разброс массы по точкам подъёмов }
  else se := bCv / Sqrt(bNw);
  Est.Success := True;
  Est.MassKg := bM;
  Est.Crr := bCrr;
  Est.CdA := bCda;
  Est.WindSpeedMs := bWs;
  Est.WindDirRad := bWf;
  Est.WindEstimated := (not WindFixed) and (bWs > 0);
  if MassFixed then
  begin
    { Масса задана юзером — не из данных: CI ~0, надёжность полная. }
    Est.MassCi95 := 0;
    Est.MassPriorShare := 1.0;   { «масса целиком из приора» = задана вручную }
  end
  else
  begin
    Est.MassCi95 := 1.96 * se * bM;
    if se > 0.07 then Est.MassPriorShare := 0.6 else Est.MassPriorShare := 0.0;
  end;
  Est.NumSamples := N;
  if N > 0 then Est.TotalDistKm := Samples[N - 1].DistanceM / 1000.0;
  if MassFixed then
    Est.Message := Format('масса задана; согласование Crr: CV %.0f%%, окон %d',
      [bCv * 100, bNw])
  else if twoPass then
    Est.Message := Format('масса по подъёмам %.1f кг (разброс %.0f%%, %d точек); '
      + 'CdA/Crr согласованы по заезду (CV %.0f%%)',
      [bM, se * 100, massNwSave, bCv * 100])
  else
    Est.Message := Format('CV массы %.0f%%, SE %.1f%%, окон %d',
      [bCv * 100, se * 100, bNw]);
  { Пометка зафиксированных параметров. }
  if CdAFixed  then Est.Message := Est.Message + '; CdA задан';
  if CrrFixed  then Est.Message := Est.Message + '; Crr задан';
  if WindFixed then Est.Message := Est.Message + '; ветер задан';
  if Assigned(ALog) then
    ALog(Format('итог: масса %.1f%s, Crr %.4f%s, CdA %.3f%s, '
      + 'ветер %.0f м/с @ %.0f°%s, всего %d мс',
      [bM, SIf(MassFixed, ' (задана)',
              SIf(twoPass, Format(' (подъёмы, разброс %.0f%%)', [se * 100]),
                           Format(' (SE %.1f%%)', [se * 100]))),
       bCrr, SIf(CrrFixed, ' (задан)', ''),
       bCda, SIf(CdAFixed, ' (задан)', ''),
       bWs, bWf * 180.0 / Pi, SIf(WindFixed, ' (задан)', ''),
       GetTickCount64 - T0]));
  Result := True;
end;

end.
