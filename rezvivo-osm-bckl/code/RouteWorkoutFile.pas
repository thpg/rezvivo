{ RouteWorkoutFile — абстрактный базовый тип для парсеров файлов
  маршрутов и тренировок.

  Один файл может нести:
    • только маршрут           (например, GPS-курс)
    • только тренировку        (структурированный workout без GPS)
    • и то, и другое одновременно (записанная активность с power/hr)

  Поэтому интерфейс симметричен: HasRoute / RoutePoints и
  HasWorkout / WorkoutSteps. Конкретные наследники:
    • TFitFile  (юнит FitFile)        — Garmin .fit
    • будущие   (.gpx, .tcx, .crs, …) — добавляются как отдельные юниты

  Координатная конвенция для маршрута: TVector3 в локальной
  правосторонней системе с Y вверх. Реализация выбирает удобную
  ориентацию X/Z (FitFile использует X = восток, Z = север,
  Y = высота относительно первой точки). }
unit RouteWorkoutFile;

{$mode objfpc}{$H+}
{$codepage UTF8}

interface

uses
  Classes, SysUtils,
  CastleVectors;

type
  TRoutePoint = record
    Position:           TVector3;   { локальные координаты, м (Y вверх) }
    DistanceFromStart:  Single;     { накопленная дистанция, м }
    TimeFromStart:      Single;     { сек от начала; 0 если в файле нет таймштампов }
  end;
  TRoutePointArray = array of TRoutePoint;

  { Тип длительности шага тренировки. Интерпретация DurationValue
    зависит от этого поля. }
  TWorkoutDurationKind = (
    wdkUnknown,
    wdkOpen,        { вручную / lap / неопределённая }
    wdkTime,        { секунды }
    wdkDistance,    { метры }
    wdkCalories,    { ккал }
    wdkRepeat       { повтор от шага N (FIT-специфика) }
  );

  { Тип цели шага тренировки. Интерпретация TargetLow/TargetHigh
    зависит от этого поля (вт/уд.мин/rpm/м.с⁻¹). }
  TWorkoutTargetKind = (
    wtkUnknown,
    wtkOpen,
    wtkSpeed,
    wtkHeartRate,
    wtkCadence,
    wtkPower,
    wtkGrade,
    wtkResistance
  );

  TWorkoutIntensity = (
    wiActive,
    wiRest,
    wiWarmup,
    wiCooldown,
    wiRecovery,
    wiInterval,
    wiOther
  );

  TWorkoutStep = record
    Name:           String;
    DurationKind:   TWorkoutDurationKind;
    DurationValue:  Single;       { сек / м / ккал — по DurationKind }
    TargetKind:     TWorkoutTargetKind;
    TargetLow:      Single;       { нижняя граница цели }
    TargetHigh:     Single;       { верхняя граница; = TargetLow если значение одно }
    Intensity:      TWorkoutIntensity;
  end;
  TWorkoutStepArray = array of TWorkoutStep;

  { Базовый тип. Конкретные парсеры наследуют и переопределяют LoadFromFile. }
  TRouteWorkoutFile = class
  protected
    FName:         String;
    FDescription:  String;
    FHasRoute:     Boolean;
    FHasWorkout:   Boolean;
    FRoutePoints:  TRoutePointArray;
    FWorkoutSteps: TWorkoutStepArray;

    { Сброс полей перед новой загрузкой. Вызывается из LoadFromUrl и
      должен вызываться наследником в начале LoadFromFile. }
    procedure ResetData;
  public
    constructor Create; virtual;

    { LoadFromUrl преобразует URL в физический путь и зовёт LoadFromFile.
      Возвращает False если URL не локальный или LoadFromFile вернул False. }
    function LoadFromUrl(const Url: String): Boolean;
    function LoadFromFile(const Filename: String): Boolean; virtual; abstract;

    { Записать массив точек маршрута в формате terrain_road.ini,
      совместимом с TGamePath.LoadRoadPoints. Перезапишет существующий.
      Возвращает False если точек < 2 или запись сорвалась. }
    function SaveRoutePointsAsRoadIni(const Filename: String): Boolean;

    property Name:         String              read FName;
    property Description:  String              read FDescription;
    property HasRoute:     Boolean             read FHasRoute;
    property HasWorkout:   Boolean             read FHasWorkout;
    property RoutePoints:  TRoutePointArray    read FRoutePoints;
    property WorkoutSteps: TWorkoutStepArray   read FWorkoutSteps;
  end;

{ Утилита: проекция GPS (градусы) в локальные east/north метры
  относительно опорной точки. Эквидистантная цилиндрическая, точна
  на расстояниях до ~100 км от опорной точки.
  Result.X = восток (+), Result.Y = север (+). }
function GpsToLocalEastNorth(const LatDeg, LonDeg, OriginLatDeg,
  OriginLonDeg: Double): TVector2;

{ Обратная проекция: локальные east(X)/north(Z) метры → GPS-градусы.
  Используется для запросов в внешний DEM-API (Open-Meteo,
  Open Topo Data и т.п.), которые принимают только lat/lng. }
procedure LocalEastNorthToGps(const EastM, NorthM, OriginLatDeg,
  OriginLonDeg: Double; out LatDeg, LonDeg: Double);

implementation

uses
  IniFiles, Math,
  CastleURIUtils, CastleLog;

const
  EARTH_RADIUS_M = 6371000.0;

{ ── TRouteWorkoutFile ─────────────────────────────────────────────── }

constructor TRouteWorkoutFile.Create;
begin
  inherited Create;
  ResetData;
end;

procedure TRouteWorkoutFile.ResetData;
begin
  FName := '';
  FDescription := '';
  FHasRoute := False;
  FHasWorkout := False;
  SetLength(FRoutePoints, 0);
  SetLength(FWorkoutSteps, 0);
end;

function TRouteWorkoutFile.LoadFromUrl(const Url: String): Boolean;
var
  Filename: String;
begin
  Filename := URIToFilenameSafe(Url);
  if Filename = '' then
  begin
    WritelnLog('RouteWorkoutFile', 'URL не локальный: ' + Url);
    Exit(False);
  end;
  Result := LoadFromFile(Filename);
end;

function TRouteWorkoutFile.SaveRoutePointsAsRoadIni(
  const Filename: String): Boolean;
var
  Ini: TIniFile;
  FS: TFormatSettings;
  I: Integer;
  P: TVector3;
begin
  Result := False;
  if Length(FRoutePoints) < 2 then
  begin
    WritelnLog('RouteWorkoutFile', Format(
      'Слишком мало точек для записи road.ini: %d', [Length(FRoutePoints)]));
    Exit;
  end;

  FS := DefaultFormatSettings;
  FS.DecimalSeparator := '.';

  if FileExists(Filename) then
    DeleteFile(Filename);

  try
    Ini := TIniFile.Create(Filename);
    try
      Ini.WriteInteger('Road', 'PointCount', Length(FRoutePoints));
      for I := 0 to High(FRoutePoints) do
      begin
        P := FRoutePoints[I].Position;
        Ini.WriteString('Points', 'P' + IntToStr(I),
          Format('%.3f,%.3f,%.3f', [P.X, P.Y, P.Z], FS));
      end;
    finally
      Ini.Free;
    end;
    Result := True;
    WritelnLog('RouteWorkoutFile', Format(
      'Сохранено %d точек в %s', [Length(FRoutePoints), Filename]));
  except
    on E: Exception do
      WritelnLog('RouteWorkoutFile',
        'Ошибка записи ' + Filename + ': ' + E.Message);
  end;
end;

{ ── Утилита проекции GPS ─────────────────────────────────────────── }

function GpsToLocalEastNorth(const LatDeg, LonDeg, OriginLatDeg,
  OriginLonDeg: Double): TVector2;
var
  OriginLatRad, DeltaLatRad, DeltaLonRad: Double;
begin
  OriginLatRad := DegToRad(OriginLatDeg);
  DeltaLatRad  := DegToRad(LatDeg - OriginLatDeg);
  DeltaLonRad  := DegToRad(LonDeg - OriginLonDeg);
  Result.X := DeltaLonRad * Cos(OriginLatRad) * EARTH_RADIUS_M;
  Result.Y := DeltaLatRad * EARTH_RADIUS_M;
end;

procedure LocalEastNorthToGps(const EastM, NorthM, OriginLatDeg,
  OriginLonDeg: Double; out LatDeg, LonDeg: Double);
var
  OriginLatRad, DeltaLatRad, DeltaLonRad: Double;
begin
  OriginLatRad := DegToRad(OriginLatDeg);
  DeltaLatRad  := NorthM / EARTH_RADIUS_M;
  DeltaLonRad  := EastM / (Cos(OriginLatRad) * EARTH_RADIUS_M);
  LatDeg := OriginLatDeg + RadToDeg(DeltaLatRad);
  LonDeg := OriginLonDeg + RadToDeg(DeltaLonRad);
end;

end.
