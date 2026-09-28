{ Osm3dDemProfile — синтетический высотный профиль маршрута из DEM.

  Для файлов «только координаты» (GPX без <ele>, FIT без баро-канала):
  высотный канал синтезируется из DEM вдоль пути и дальше идёт по тому
  же конвейеру (FIT-слой, сверка, статистика), что настоящая барометрия.

  Фильтр подобран на 31 заезде с барометрией (heights.csv, эталон =
  alt_fit): медиана 5 точек (режет одиночные выбросы сетки DEM) +
  скользящее среднее ~300 м вдоль пути (режет полог леса, ступени
  квантования и размытие рамп). Замер (медианы по заездам):
    шум уклона 30 м:   2.47 → 1.67 %
    1-км |Δ| к баро:   0.40 → 0.36 пп (не портится — сигнал длиннее окна)
    ошибка набора:     48.5 → 15.3 %
  Окно 300 м годится для холмистой местности (реальные подъёмы длиннее);
  в горах с серпантинами окно стоит уменьшить — константа ниже. }
unit Osm3dDemProfile;

{$mode objfpc}{$H+}
{$codepage UTF8}

interface

type
  TDemProfileArr = array of Double;

const
  { Параметры фильтра (см. замер в шапке). }
  DEMPROF_MEDIAN_PTS = 5;       { окно медианы, точек (нечёт) }
  DEMPROF_AVG_WIN_M  = 300.0;   { окно скользящего среднего, м }

{ Сгладить профиль высоты вдоль пути: медиана + скользящее среднее по
  одометрии. ADist — накопленная дистанция (м, неубывающая), AAlt —
  высоты (м), одинаковой длины. Результат — ASyn той же длины. }
procedure SmoothProfile(const ADist, AAlt: TDemProfileArr;
  out ASyn: TDemProfileArr);

implementation

uses
  Math;

{ Простая сортировка вставками — окна крошечные (5 точек). }
procedure SortDouble(var A: array of Double; const Count: Integer);
var
  I, J: Integer;
  V: Double;
begin
  for I := 1 to Count - 1 do
  begin
    V := A[I];
    J := I - 1;
    while (J >= 0) and (A[J] > V) do
    begin
      A[J + 1] := A[J];
      Dec(J);
    end;
    A[J + 1] := V;
  end;
end;

function MedianOfRange(const A: TDemProfileArr; Lo, Hi: Integer): Double;
var
  B: array[0..2 * (DEMPROF_MEDIAN_PTS div 2)] of Double;
  K, M: Integer;
begin
  M := Hi - Lo + 1;
  for K := 0 to M - 1 do
    B[K] := A[Lo + K];
  SortDouble(B, M);
  if Odd(M) then
    Result := B[M div 2]
  else
    Result := (B[M div 2 - 1] + B[M div 2]) / 2;
end;

procedure SmoothProfile(const ADist, AAlt: TDemProfileArr;
  out ASyn: TDemProfileArr);
var
  N, I, J0, J1, Half: Integer;
  W: TDemProfileArr;
  WindowSum: Double;
begin
  N := Length(AAlt);
  SetLength(ASyn, N);
  if N = 0 then Exit;
  if Length(ADist) <> N then
  begin
    { некорректный вход — отдаём как есть }
    ASyn := Copy(AAlt, 0, N);
    Exit;
  end;

  { 1) медиана по соседям — убирает одиночные выбросы сетки DEM }
  Half := DEMPROF_MEDIAN_PTS div 2;
  for I := 0 to N - 1 do
  begin
    J0 := Max(0, I - Half);
    J1 := Min(N - 1, I + Half);
    ASyn[I] := MedianOfRange(AAlt, J0, J1);
  end;

  { 2) скользящее среднее ±DEMPROF_AVG_WIN_M/2 по одометрии }
  SetLength(W, N);
  J0 := 0;
  J1 := 0;
  WindowSum := ASyn[0];
  for I := 0 to N - 1 do
  begin
    while (J0 < I) and (ADist[J0] < ADist[I] - DEMPROF_AVG_WIN_M / 2) do
    begin
      WindowSum := WindowSum - ASyn[J0];
      Inc(J0);
    end;
    while (J1 < N - 1) and (ADist[J1 + 1] <= ADist[I] + DEMPROF_AVG_WIN_M / 2) do
    begin
      Inc(J1);
      WindowSum := WindowSum + ASyn[J1];
    end;
    W[I] := WindowSum / (J1 - J0 + 1);
  end;
  ASyn := W;
end;

end.
