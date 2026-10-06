unit GamePath;

interface

uses
  Classes, SysUtils, Math,
  CastleVectors, CastleScene, GameFitLoadProfile;

type
  TPathNarrowPassage = record
    Key: QWord;
    Forward, Inside, Exclusive: Boolean;
    EntryDistance: Single;
  end;
  TPathPassageSpan = record
    Key: QWord;
    Forward, Exclusive: Boolean;
    StartDistance, EndDistance: Single;
    StartPoint, EndPoint: TVector3;
  end;
  TPathPosition = record
    Segment: Integer;
    T: Single;
  end;

  TPathReplayState = record
    Position: TPathPosition;
    SmoothedRouteDir: TVector3;
    TurnaroundIndex: Integer;
    WobbleCurrent: Single;
    WobbleTarget: Single;
    WobbleTimer: Single;
    WobblePhase: Single;
    LastCarrotWorld: TVector3;
    LastWobbleOffsetM: Single;
    LastLaneOffsetM: Single;
    SteeringSpeedLimit: Single;
  end;

  TGamePath = class
  private
    FPoints: array of TVector3;
    { Ширина дороги под каждой точкой (метры). Параллелен FPoints.
      0 = точка мимо дорог (снап не притянул её) — на таком участке
      райдер едет просто по точке, без полосного смещения. Заполняется
      из LoadFromMemory (точки приходят напрямую из FIT/снапнутого трека
      с ширинами OSM-дорог) либо из 5-го поля road-INI в LoadRoadPoints
      для нестриминговых карт. }
    FPointWidths: array of Single;
    { Позиция ОСЕВОЙ дороги под каждой точкой (локальный фрейм, как
      FPoints). Параллелен FPoints. Заполняется снапнутыми центрами
      (SetPointCenters) — это место на осевой дороги, к которому
      притянута точка. Пусто = нет данных (отладка падает на сам путь). }
    FPointCenters: array of TVector3;
    FWorldPoints: array of TVector3;  { кеш мировых координат }
    FWorldCenters: array of TVector3;
    FFitLoad: TFitLoadProfile;
    FFitLoadStations: TFitLoadValues;
    FFitLoadReversed: Boolean;
    FPassageDistances: array of Single;
    FPassages: array of TPathPassageSpan;
    FSteeringCorners: array of Boolean;
    FCornerDistance: array of Single;
    FPreparedBuildingRoute: Boolean;
    FOutAndBack: Boolean;
    FTurnaroundIndex: Integer;
    FWorldPointsBaked: Boolean;
    FPosition: TPathPosition;
    FSmoothedRouteDir: TVector3;
    FLevelScene: TCastleScene;

    { Carrot wobble — smooth random lateral drift for lifelike movement }
    FWobbleCurrent: Single;   { current lateral offset (meters) }
    FWobbleTarget: Single;    { target lateral offset }
    FWobbleTimer: Single;     { countdown to next target change }
    FWobblePhase: Single;     { seconds into periodic test sine }
    function GetFollowPointWorld(Index: Integer): TVector3;
    procedure BuildNarrowPassages;
    function GetPointCount: Integer;
  public
    function CaptureReplay: TPathReplayState;
    procedure RestoreReplay(const Saved: TPathReplayState);
  public
    DebugEnabled: Boolean;

    { Last carrot position computed by GetSmartRouteDirection (XYZ world).
      Available for trace logging after each call. }
    LastCarrotWorld: TVector3;

    { Last lateral test-wobble offset applied to the carrot (meters, +right).
      0 when PathTestWobble is off. For MCP / HUD diagnostics. }
    LastWobbleOffsetM: Single;
    LastLaneOffsetM: Single;

    { Y offset applied to carrot position — half model height so the
      look-ahead target sits at the rider's center rather than on the ground. }
    CarrotYOffset: Single;
    { Speed cap from the baked distance to the next mandatory corner. }
    SteeringSpeedLimit: Single;

    { Enable small random lateral wobble on the carrot for lifelike movement }
    CarrotWobbleEnabled: Boolean;
    CarrotWobbleAmplitude: Single;  { max lateral drift, meters (default 0.12) }

    constructor Create;
    procedure Clear;
    procedure SetLevelScene(const AScene: TCastleScene);
    function LooksLikeRoadHeader(const S: string): Boolean;
    procedure LoadRoadPoints(const FileName: string);

    { Загрузить точки пути напрямую из памяти — без промежуточного INI.
      APoints — точки в локальном фрейме сцены (как раньше читались из
      [Points]); AWidths — ширина дороги под каждой точкой (метры, 0 =
      мимо дорог), параллелен APoints. AWidths может быть короче/пустым:
      недостающие ширины считаются нулевыми. Это прямой путь FIT→path,
      эквивалентный LoadRoadPoints, но без файла. }
    procedure LoadFromMemory(const APoints: array of TVector3;
      const AWidths: array of Single);

    { Скопировать точки/ширины/уровень-сцену в другой путь (например,
      из пути аватара в путь свежесозданного удалённого райдера) — без
      повторного чтения файла. Целевой путь помечается «не запечён». }
    procedure CopyTo(ADest: TGamePath; const Reversed: Boolean = False);
    { Same physical point on a copy with reversed traversal. Point zero and
      the two endpoints of an out-and-back route keep their indices. }
    function ReversedPosition(const Pos:TPathPosition):TPathPosition;
    procedure SetFitLoadProfile(const Profile: TFitLoadProfile;
      const SourceIndices: array of Double);
    function HasFitLoadProfile: Boolean;
    function FitLoadDatumCorrected: Boolean;
    function FitLoadAtPosition(const Pos: TPathPosition;
      out GradePct, SourceM, HeightM: Single): Boolean;

    { Заменить только ширины дорог под точками (FPoints не трогаются).
      Нужно, чтобы после снапа к дорогам прикрепить к сырому FIT-пути
      реальные OSM-ширины (снапнутый трек 1:1 по индексу с сырым), не
      сдвигая сами точки. AWidths короче PointCount → недостающие 0;
      длиннее — лишнее игнорируется. }
    procedure SetPointWidths(const AWidths: array of Single);

    { Ширина дороги под точкой I (метры; 0 = мимо дорог). Для построения
      профиля ширины (менеджер полос). Вне диапазона → 0. }
    function PointWidth(I: Integer): Single;

    { Задать позиции осевой дороги под точками (локальный фрейм, как
      FPoints). Параллельно SetPointWidths: «куда притянуто» — центр
      дороги. Пустой/короткий массив → недостающие = сама точка пути. }
    procedure SetPointCenters(const ACenters: array of TVector3);

    { Мировая позиция ОСЕВОЙ дороги в позиции пути (для отладки: осевую
      линию рисуем здесь, а не по сырому треку аватара). Если центры не
      заданы — падаем на GetSplinePosition (сам путь). }
    function RoadCenterAt(const Pos: TPathPosition): TVector3;
    function FollowTangent(const Pos: TPathPosition): TVector3;
    function FollowDirectionXZ(const Pos: TPathPosition): TVector3;
    procedure AdvanceFollow(var Pos: TPathPosition; Distance: Single);
    { Local XZ projection, signed arc window in metres. Never scans other
      branches or changes the shared cursor (also used by visual diagnostics). }
    function ProjectFollow(const WorldPosition: TVector3;
      const Seed: TPathPosition; const WindowM: Single): TPathPosition;

    { Пересчитать мировые координаты всех точек.
      Вызывать после LoadRoadPoints + SetLevelScene. }
    procedure BakeWorldPoints;
    procedure UsePreparedCornerHints(const AOutAndBack: Boolean = False);
    { Lock the cursor at an endpoint while physics rotates in place. }
    function TryTurnaround(const WorldPosition, ForwardDir: TVector3;
      out TargetDirection: TVector3): Boolean;
    procedure FinishTurnaround;
    procedure ResetTurnaround;

    function GetPathPointWorld(Index: Integer): TVector3; inline;
    { Path point in the path's local frame (pre-LevelScene bake). }
    function PathPointLocal(Index: Integer): TVector3;
    { Move a path point in local XZ (Y kept). Invalidates world bake.
      Used when the road/exit is the priority track vs raw FIT GPS. }
    procedure SetPathPointLocalXZ(Index: Integer; AX, AZ: Single);
    function ClampPathPosition(const Pos: TPathPosition): TPathPosition;
    procedure AdvanceOnPath(var Pos: TPathPosition; Distance: Single);
    function GetSplinePosition(const Pos: TPathPosition): TVector3;
    function GetSplineTangent(const Pos: TPathPosition): TVector3;
    function GetSplineDirectionXZ(const Pos: TPathPosition): TVector3;

    { Ширина дороги в позиции пути (метры). Берёт ширину ближайшей
      точки сегмента; 0 = участок мимо дорог (полосное смещение не
      применяется, райдер едет по осевой точке). }
    function RoadWidthAt(const Pos: TPathPosition): Single;
    { Prepared once with the world points. A physical corridor has the same
      key for independently copied/reversed routes; no agent pointers. }
    function NarrowPassageAt(const Pos: TPathPosition; LookAhead: Single;
      out Passage: TPathNarrowPassage): Boolean;

    { NormalizeXZ / DistanceXZ / LerpDirXZ moved to GameMath.pas — they
      were pure-math helpers wrongly stored as methods. External callers
      (gamephysicsbase, gamephysicskinematic) updated to use GameMath
      directly instead of going through TGamePath. }

    procedure AdvancePathPosition(Distance: Single);
    procedure SyncPathPositionToWorldFast(const WorldPosition: TVector3);

    { Немутирующий вариант SyncPathPositionToWorldFast: тот же локальный
      поиск ближайшей позиции пути к мировой точке (окно ±0.8T от ASeed),
      но НЕ трогает общий курсор FPosition. Для сторонних потребителей
      (кинематик-камера), которым нужна позиция на пути без вмешательства
      в следящую логику физики. }
    function FindPathPositionNear(const WorldPosition: TVector3;
      const ASeed: TPathPosition): TPathPosition;
    function GetSmartRouteDirection(const WorldPosition: TVector3;
      const CurrentSpeed, DeltaTime: Single;
      const ALaneOffset: Single = 0.0;
      const ResetDirection: Boolean = False): TVector3;

    property PointCount: Integer read GetPointCount;
    property Position: TPathPosition read FPosition write FPosition;
    property PreparedBuildingRoute: Boolean read FPreparedBuildingRoute;
    property OutAndBack: Boolean read FOutAndBack;
    property SmoothedRouteDir: TVector3 read FSmoothedRouteDir write FSmoothedRouteDir;
  end;

const
  MinLookAhead = 5.0;
  LookAheadPerSpeed = 0.4;
  DirectionSmoothTime = 0.5;

  RoutePointIgnoreDistance = 2.0;
  DirectionLookAheadBase = 3.0;
  DirectionLookAheadBySpeed = 0.45;
  RouteAverageNearDist = 2.0;
  RouteAverageFarDist = 12.0;
  RouteAverageSamples = 16;
  RouteDirectionSmoothness = 5.0;

{ Test harness: large periodic left/right carrot sway so lean + steer
  are obvious on camera.chase / thirdperson. Live globals — MCP and CLI
  flip them without recreating TGamePath instances. }
procedure PathTestWobbleConfigure(AEnabled: Boolean;
  AAmplitudeM: Single = -1; APeriodS: Single = -1);
function PathTestWobbleIsEnabled: Boolean;
function PathTestWobbleGetAmplitudeM: Single;
function PathTestWobbleGetPeriodS: Single;

{ BISECT (camera yaw thrash): live toggles for recent path-related changes.
  Defaults = current production behaviour (both True).
  CLI: --no-road-pull / --road-pull, --no-findpath-fullscan / --findpath-fullscan
  MCP: path.bisect_flags }
procedure PathBisectConfigure(ARoadPriorityPull, AFindFullRescan: Boolean);
function PathRoadPriorityPullEnabled: Boolean;
function PathFindFullRescanEnabled: Boolean;
function PathBisectFlagsJSON: string;

implementation


uses
  CastleURIUtils, DebugLog, IniFiles, GameMath, CastleLog;

var
  PathTestWobbleEnabled: Boolean = False;
  PathTestWobbleAmplitudeM: Single = 2.0;   { meters each side of centre line }
  PathTestWobblePeriodS: Single = 8.0;      { full L→R→L cycle }
  { BISECT / CLI: road-priority pull is OFF by default (camera-safe).
    --road-pull enables aspBridge at ApplySnappedWidths call site.
    FindPath fullscan still default ON (helps re-ride teleport; not the yaw root). }
  GPathRoadPriorityPull: Boolean = False;
  GPathFindFullRescan: Boolean = True;

procedure PathTestWobbleConfigure(AEnabled: Boolean;
  AAmplitudeM: Single; APeriodS: Single);
begin
  PathTestWobbleEnabled := AEnabled;
  if AAmplitudeM > 0 then PathTestWobbleAmplitudeM := AAmplitudeM;
  if APeriodS > 0.1 then PathTestWobblePeriodS := APeriodS;
end;

function PathTestWobbleIsEnabled: Boolean;
begin
  Result := PathTestWobbleEnabled;
end;

function PathTestWobbleGetAmplitudeM: Single;
begin
  Result := PathTestWobbleAmplitudeM;
end;

function PathTestWobbleGetPeriodS: Single;
begin
  Result := PathTestWobblePeriodS;
end;

procedure PathBisectConfigure(ARoadPriorityPull, AFindFullRescan: Boolean);
begin
  GPathRoadPriorityPull := ARoadPriorityPull;
  GPathFindFullRescan := AFindFullRescan;
end;

function PathRoadPriorityPullEnabled: Boolean;
begin
  Result := GPathRoadPriorityPull;
end;

function PathFindFullRescanEnabled: Boolean;
begin
  Result := GPathFindFullRescan;
end;

function PathBisectFlagsJSON: string;
begin
  Result := Format(
    '{"road_priority_pull":%s,"findpath_fullscan":%s}',
    [LowerCase(BoolToStr(GPathRoadPriorityPull, True)),
     LowerCase(BoolToStr(GPathFindFullRescan, True))]);
end;

function TGamePath.CaptureReplay: TPathReplayState;
begin
  Result.Position:=FPosition;
  Result.SmoothedRouteDir:=FSmoothedRouteDir;
  Result.TurnaroundIndex:=FTurnaroundIndex;
  Result.WobbleCurrent:=FWobbleCurrent;
  Result.WobbleTarget:=FWobbleTarget;
  Result.WobbleTimer:=FWobbleTimer;
  Result.WobblePhase:=FWobblePhase;
  Result.LastCarrotWorld:=LastCarrotWorld;
  Result.LastWobbleOffsetM:=LastWobbleOffsetM;
  Result.LastLaneOffsetM:=LastLaneOffsetM;
  Result.SteeringSpeedLimit:=SteeringSpeedLimit;
end;

procedure TGamePath.RestoreReplay(const Saved: TPathReplayState);
begin
  FPosition:=Saved.Position;
  FSmoothedRouteDir:=Saved.SmoothedRouteDir;
  FTurnaroundIndex:=Saved.TurnaroundIndex;
  FWobbleCurrent:=Saved.WobbleCurrent;
  FWobbleTarget:=Saved.WobbleTarget;
  FWobbleTimer:=Saved.WobbleTimer;
  FWobblePhase:=Saved.WobblePhase;
  LastCarrotWorld:=Saved.LastCarrotWorld;
  LastWobbleOffsetM:=Saved.LastWobbleOffsetM;
  LastLaneOffsetM:=Saved.LastLaneOffsetM;
  SteeringSpeedLimit:=Saved.SteeringSpeedLimit;
end;

constructor TGamePath.Create;
begin
  inherited Create;
  FTurnaroundIndex:=-1;
  FPosition.Segment := 0; FPosition.T := 0;
  FSmoothedRouteDir := Vector3(0, 0, 1);
  FWorldPointsBaked := false;
  DebugEnabled := false;
  CarrotYOffset := 0;
  SteeringSpeedLimit:=1e30;
  CarrotWobbleEnabled := true;
  CarrotWobbleAmplitude := 0.12;
  FWobbleCurrent := 0;
  FWobbleTarget := 0;
  FWobbleTimer := 0;
  FWobblePhase := 0;
  LastWobbleOffsetM := 0;
end;

procedure TGamePath.Clear;
begin
  SetLength(FPoints, 0);
  SetLength(FPointWidths, 0);
  SetLength(FPointCenters, 0);
  SetLength(FWorldPoints, 0);
  FFitLoad:=Default(TFitLoadProfile);FFitLoadStations:=nil;FFitLoadReversed:=False;
  FSteeringCorners:=nil; FCornerDistance:=nil;
  FPassages:=nil; FPassageDistances:=nil;
  FPreparedBuildingRoute:=False;
  FOutAndBack:=False;
  FTurnaroundIndex:=-1;
  SteeringSpeedLimit:=1e30;
  FWorldPointsBaked := false;
  FPosition.Segment := 0; FPosition.T := 0;
  FSmoothedRouteDir := Vector3(0, 0, 1);
end;

procedure TGamePath.SetLevelScene(const AScene: TCastleScene);
begin
  FLevelScene := AScene;
  FWorldPointsBaked := false;
end;

function TGamePath.GetPointCount: Integer;
begin Result := Length(FPoints); end;

function TGamePath.LooksLikeRoadHeader(const S: string): Boolean;
var N: string;
begin
  N := Trim(LowerCase(S));
  N := StringReplace(N, ' ', '', [rfReplaceAll]);
  N := StringReplace(N, #9, '', [rfReplaceAll]);
  N := StringReplace(N, ';', ',', [rfReplaceAll]);
  Result := N = 'index,x,y,z,angle';
end;

procedure TGamePath.LoadRoadPoints(const FileName: string);
var
  Ini: TIniFile;
  SL: TStringList;
  FS: TFormatSettings;
  RealName: string;
  I, Count: Integer;
  S: string;
begin
  Clear;
  FS := DefaultFormatSettings; FS.DecimalSeparator := '.';
  RealName := URIToFilenameSafe(FileName);
  Logger.Info('[GamePath] ' + 'LoadRoadPoints: loading "' + RealName + '"');
  if not FileExists(RealName) then
  begin
    Logger.Info('[GamePath] ' + 'File not found: "' + RealName + '"');
    Exit;
  end;
  SL := TStringList.Create;
  Ini := TIniFile.Create(RealName);
  try
    Count := Ini.ReadInteger('Road', 'PointCount', 0);
    if Count < 2 then
    begin
      Logger.Info('[GamePath] ' + 'PointCount=' + IntToStr(Count) + ', too few');
      Exit;
    end;
    SetLength(FPoints, Count);
    SetLength(FPointWidths, Count);
    for I := 0 to Count - 1 do
    begin
      S := Ini.ReadString('Points', 'P' + IntToStr(I), '');
      if S = '' then
      begin
        SetLength(FPoints, I); SetLength(FPointWidths, I); Break;
      end;
      SL.Delimiter := ',';
      SL.StrictDelimiter := True;
      SL.DelimitedText := S;
      if SL.Count < 3 then
      begin
        SetLength(FPoints, I); SetLength(FPointWidths, I); Break;
      end;
      FPoints[I] := Vector3(
        StrToFloat(SL[0], FS),
        StrToFloat(SL[1], FS),
        StrToFloat(SL[2], FS));
      { 5-е поле — ширина дороги под точкой. Старый формат INI его не
        содержит (SL.Count < 5) → ширина 0, участок «мимо дорог». }
      if SL.Count >= 5 then
        FPointWidths[I] := StrToFloatDef(SL[4], 0.0, FS)
      else
        FPointWidths[I] := 0.0;
    end;
  finally
    Ini.Free;
    SL.Free;
  end;
  FWorldPointsBaked := false;
  Logger.Info('[GamePath] ' + 'Loaded ' + IntToStr(Length(FPoints)) + ' road points (INI format)');
end;

procedure TGamePath.LoadFromMemory(const APoints: array of TVector3;
  const AWidths: array of Single);
var
  I, Count: Integer;
begin
  Clear;
  Count := Length(APoints);
  if Count < 2 then
  begin
    Logger.Info('[GamePath] ' + 'LoadFromMemory: too few points (' +
      IntToStr(Count) + ')');
    Exit;
  end;
  SetLength(FPoints, Count);
  SetLength(FPointWidths, Count);
  for I := 0 to Count - 1 do
  begin
    FPoints[I] := APoints[I];
    if I <= High(AWidths) then
      FPointWidths[I] := AWidths[I]
    else
      FPointWidths[I] := 0.0;
  end;
  FWorldPointsBaked := false;
  Logger.Info('[GamePath] ' + 'Loaded ' + IntToStr(Count) +
    ' road points (in-memory, direct from FIT)');
end;

procedure TGamePath.CopyTo(ADest: TGamePath; const Reversed: Boolean);
var
  I, J, Count: Integer;
begin
  if (ADest = nil) or (ADest=Self) then Exit;
  ADest.Clear;
  ADest.SetLevelScene(FLevelScene);
  Count := Length(FPoints);
  SetLength(ADest.FPoints, Count);
  SetLength(ADest.FPointWidths, Count);
  for I := 0 to Count - 1 do
  begin
    J:=I;if Reversed then J:=(Count-I) mod Count;
    ADest.FPoints[I] := FPoints[J];
    if J <= High(FPointWidths) then
      ADest.FPointWidths[I] := FPointWidths[J]
    else
      ADest.FPointWidths[I] := 0.0;
  end;
  { Центры дороги тоже копируем (если есть). }
  if Length(FPointCenters)>0 then begin
    SetLength(ADest.FPointCenters,Count);
    for I := 0 to Count-1 do begin
      J:=I;if Reversed then J:=(Count-I) mod Count;
      if J<Length(FPointCenters) then ADest.FPointCenters[I]:=FPointCenters[J]
      else ADest.FPointCenters[I]:=FPoints[J];
    end;
  end;
  ADest.FPreparedBuildingRoute:=FPreparedBuildingRoute;
  ADest.FOutAndBack:=FOutAndBack;
  ADest.FFitLoad:=FFitLoad;ADest.FFitLoadStations:=FFitLoadStations;
  ADest.FFitLoadReversed:=FFitLoadReversed xor Reversed;
  if Reversed and (Length(FFitLoadStations)=Count) then begin
    ADest.FFitLoadStations:=Copy(FFitLoadStations);
    for I:=0 to Count-1 do ADest.FFitLoadStations[I]:=FFitLoadStations[(Count-I) mod Count];
  end;
  ADest.FWorldPointsBaked := false;
  Logger.Info('[GamePath] ' + 'CopyTo: ' + IntToStr(Count) + ' points copied');
end;

function TGamePath.ReversedPosition(const Pos:TPathPosition):TPathPosition;
begin
  Result:=ClampPathPosition(Pos);
  if PointCount<2 then Exit;
  Result.Segment:=PointCount-1-Result.Segment;
  Result.T:=1-Result.T;
end;

procedure TGamePath.SetFitLoadProfile(const Profile: TFitLoadProfile;
  const SourceIndices: array of Double);
var
  I,N,Mid:Integer;
  PathM,SourceM,Smoothed:TFitLoadValues;
  Delta:TVector3;
begin
  FFitLoad:=Default(TFitLoadProfile);FFitLoadStations:=nil;FFitLoadReversed:=False;
  if (Length(Profile.HeightM)<2) or (Length(SourceIndices)<>PointCount) then Exit;
  FFitLoad:=Profile;SetLength(FFitLoadStations,PointCount);
  for I:=0 to PointCount-1 do
    FFitLoadStations[I]:=FitLoadStationAtIndex(Profile,SourceIndices[I]);
  { FIT indices survive detours, but OSM snapping can compress their spacing
    to centimetres. Prepare a continuous correspondence once, in horizontal
    path metres. This does not depend on rendered height or frame timing. }
  N:=PointCount;
  SetLength(PathM,N+1);SetLength(SourceM,N+1);
  for I:=0 to N-1 do
  begin
    SourceM[I]:=FFitLoadStations[I];
    Delta:=GetFollowPointWorld(I+1)-GetFollowPointWorld(I);
    Delta.Y:=0;
    PathM[I+1]:=PathM[I]+Delta.Length;
  end;
  if FOutAndBack then
  begin
    SourceM[N]:=SourceM[0];Mid:=N div 2;
    { Filter each leg separately: the actual turnaround must still reach
      the last FIT station, with the gradient reversed on the return leg. }
    Smoothed:=SmoothFitSourceStations(Copy(PathM,0,Mid+1),Copy(SourceM,0,Mid+1),False);
    for I:=0 to Mid do FFitLoadStations[I]:=Smoothed[I];
    Smoothed:=SmoothFitSourceStations(Copy(PathM,Mid,N-Mid+1),Copy(SourceM,Mid,N-Mid+1),False);
    for I:=Mid to N-1 do FFitLoadStations[I]:=Smoothed[I-Mid];
  end
  else
  begin
    SourceM[N]:=Profile.LengthM;
    Smoothed:=SmoothFitSourceStations(PathM,SourceM,True);
    for I:=0 to N-1 do FFitLoadStations[I]:=Smoothed[I];
  end;
end;

function TGamePath.HasFitLoadProfile: Boolean;
begin
  Result:=(Length(FFitLoad.HeightM)>=2) and (Length(FFitLoadStations)=PointCount) and (PointCount>=2);
end;

function TGamePath.FitLoadDatumCorrected: Boolean;
begin Result:=HasFitLoadProfile and FFitLoad.DatumCorrected end;

function TGamePath.FitLoadAtPosition(const Pos: TPathPosition;
  out GradePct, SourceM, HeightM: Single): Boolean;
var I,J,N:Integer;A,B,S:Double;Reverse:Boolean;
begin
  GradePct:=0;SourceM:=0;HeightM:=0;Result:=False;
  if not HasFitLoadProfile then Exit;
  N:=Length(FFitLoadStations);I:=Pos.Segment;
  if I<0 then I:=0 else if I>=N then I:=N-1;
  J:=I+1;if J=N then J:=0;
  A:=FFitLoadStations[I];B:=FFitLoadStations[J];
  if not FOutAndBack then begin
    if not FFitLoadReversed and (J=0) then B:=FFitLoad.LengthM;
    if FFitLoadReversed and (I=0) then A:=FFitLoad.LengthM;
  end;
  S:=A+(B-A)*EnsureRange(Pos.T,Single(0),Single(1));SourceM:=S;
  Reverse:=(B<A) or ((B=A) and FOutAndBack and (I>=N div 2));
  Result:=FitLoadAt(FFitLoad,S,HeightM,GradePct);
  if Reverse then GradePct:=-GradePct;
end;

procedure TGamePath.SetPointWidths(const AWidths: array of Single);
var
  I, N: Integer;
begin
  FWorldPointsBaked:=False;
  N := Length(FPoints);
  SetLength(FPointWidths, N);
  for I := 0 to N - 1 do
    if I <= High(AWidths) then
      FPointWidths[I] := AWidths[I]
    else
      FPointWidths[I] := 0.0;
  Logger.Info('[GamePath] ' + 'SetPointWidths: ' + IntToStr(N) +
    ' widths attached (positions unchanged)');
end;

function TGamePath.PointWidth(I: Integer): Single;
begin
  if (I >= 0) and (I <= High(FPointWidths)) then
    Result := FPointWidths[I]
  else
    Result := 0.0;
end;

procedure TGamePath.SetPointCenters(const ACenters: array of TVector3);
var
  I, N: Integer;
begin
  N := Length(FPoints);
  SetLength(FPointCenters, N);
  for I := 0 to N - 1 do
    if I <= High(ACenters) then
      FPointCenters[I] := ACenters[I]
    else
      FPointCenters[I] := FPoints[I];   { нет данных → сама точка }
  FWorldPointsBaked := false;            { центры считаются отдельно }
  Logger.Info('[GamePath] ' + 'SetPointCenters: ' + IntToStr(N) + ' road centers attached');
end;

function TGamePath.GetFollowPointWorld(Index: Integer): TVector3;
begin
  if Length(FPointCenters) < 2 then Exit(GetPathPointWorld(Index));
  if not FWorldPointsBaked then BakeWorldPoints;
  Index := Index mod PointCount;
  if Index < 0 then Inc(Index, PointCount);
  Result := FWorldCenters[Index];
end;

{ ========================================================================== }
{ BakeWorldPoints — однократно пересчитать координаты в мировые              }
{ ========================================================================== }

procedure TGamePath.UsePreparedCornerHints(const AOutAndBack: Boolean);
begin
  FPreparedBuildingRoute:=True;
  FOutAndBack:=AOutAndBack;
  FTurnaroundIndex:=-1;
  FWorldPointsBaked:=False;
end;

function TGamePath.TryTurnaround(const WorldPosition, ForwardDir: TVector3;
  out TargetDirection: TVector3): Boolean;
var I, Candidate: Integer; P: TPathPosition;
begin
  Result:=False;
  TargetDirection:=Vector3(0,0,0);
  if not FOutAndBack or (PointCount<2) then Exit;
  if not FWorldPointsBaked then BakeWorldPoints;
  if FTurnaroundIndex<0 then
    for I:=0 to 1 do
    begin
      { The progress predictor may already have crossed the endpoint.
        Check both ends of the current segment, never scan the route. }
      Candidate:=(FPosition.Segment+I) mod PointCount;
      if (Candidate<>0) and (Candidate<>PointCount div 2) then Continue;
      if DistanceXZ(WorldPosition,GetFollowPointWorld(Candidate))>0.6 then Continue;
      P.Segment:=Candidate; P.T:=0;
      if TVector3.DotProduct(ForwardDir,FollowDirectionXZ(P))>=0.5 then Continue;
      FTurnaroundIndex:=Candidate;
      Break;
    end;
  if FTurnaroundIndex<0 then Exit;
  FPosition.Segment:=FTurnaroundIndex; FPosition.T:=0;
  TargetDirection:=FollowDirectionXZ(FPosition);
  SteeringSpeedLimit:=0;
  LastLaneOffsetM:=0; LastWobbleOffsetM:=0;
  LastCarrotWorld:=RoadCenterAt(FPosition)+TargetDirection*MinLookAhead;
  LastCarrotWorld.Y:=LastCarrotWorld.Y+CarrotYOffset;
  Result:=True;
end;

procedure TGamePath.FinishTurnaround;
begin
  if FTurnaroundIndex<0 then Exit;
  FPosition.Segment:=FTurnaroundIndex; FPosition.T:=0;
  FSmoothedRouteDir:=FollowDirectionXZ(FPosition);
  FTurnaroundIndex:=-1;
end;

procedure TGamePath.ResetTurnaround;
begin
  FTurnaroundIndex:=-1;
end;

procedure TGamePath.BakeWorldPoints;
var
  I, C, J, K: Integer;
  CornerDist: Single;
  Incoming, Outgoing: TVector3;
begin
  C := Length(FPoints);
  SetLength(FWorldPoints, C);
  for I := 0 to C - 1 do
  begin
    if Assigned(FLevelScene) then
      FWorldPoints[I] := FLevelScene.LocalToWorld(FPoints[I])
    else
      FWorldPoints[I] := FPoints[I];
  end;
  SetLength(FWorldCenters, Length(FPointCenters));
  for I := 0 to High(FPointCenters) do
    if Assigned(FLevelScene) then
      FWorldCenters[I] := FLevelScene.LocalToWorld(FPointCenters[I])
    else
      FWorldCenters[I] := FPointCenters[I];
  FWorldPointsBaked := true;
  SetLength(FSteeringCorners,C);
  for I:=0 to C-1 do
  begin
    Incoming:=GetFollowPointWorld(I)-GetFollowPointWorld((I+C-1) mod C);
    Outgoing:=GetFollowPointWorld((I+1) mod C)-GetFollowPointWorld(I);
    Incoming.Y:=0; Outgoing.Y:=0;
    FSteeringCorners[I]:=FPreparedBuildingRoute and (Incoming.Length>0.01) and (Outgoing.Length>0.01) and
      (((PointWidth(I)=0) and
        (TVector3.DotProduct(Incoming,Outgoing)<0.8660254*Incoming.Length*Outgoing.Length)) or
       (TVector3.DotProduct(Incoming,Outgoing)<-0.5*Incoming.Length*Outgoing.Length));
  end;
  { Two reverse passes cover the closed route without per-frame searches. }
  SetLength(FCornerDistance,C); CornerDist:=1e30;
  for I:=2*C-1 downto 0 do
  begin
    J:=I mod C; K:=(J+1) mod C;
    if FSteeringCorners[K] then CornerDist:=0;
    CornerDist:=CornerDist+(GetFollowPointWorld(K)-GetFollowPointWorld(J)).Length;
    FCornerDistance[J]:=CornerDist;
  end;
  BuildNarrowPassages;
  Logger.Info('[GamePath] ' + 'BakeWorldPoints: ' + IntToStr(C) + ' points baked');
end;

procedure TGamePath.BuildNarrowPassages;
const PassingWidth=1.9;
var I,J,N,C,Turn:Integer; W0,W1,A,B,L,D:Single; P:TPathPosition;
    Q:array[0..5]of Int64; T:Int64; H:QWord;
begin
  C:=PointCount;FPassages:=nil;SetLength(FPassageDistances,C+1);
  FPassageDistances[0]:=0;
  if C<2 then Exit;
  for I:=0 to C-1 do begin
    L:=(GetFollowPointWorld(I+1)-GetFollowPointWorld(I)).Length;
    D:=FPassageDistances[I];FPassageDistances[I+1]:=D+L;
    W0:=PointWidth(I);W1:=PointWidth(Min(I+1,C-1));
    if (L<0.001)or((W0>=PassingWidth)and(W1>=PassingWidth))then Continue;
    A:=0;B:=1;
    if W0>=PassingWidth then begin
      if W1=0 then A:=0.5 else A:=(W0-PassingWidth)/(W0-W1);
    end;
    if W1>=PassingWidth then begin
      if W0=0 then B:=0.5 else B:=(PassingWidth-W0)/(W1-W0);
    end;
    N:=Length(FPassages);
    { A short wide gap cannot hold both an exiting bicycle and the next
      waiting queue. Reserve such successive narrows as one passage. }
    if(N=0)or(D+A*L-FPassages[N-1].EndDistance>48)then begin
      SetLength(FPassages,N+1);P.Segment:=I;P.T:=A;
      FPassages[N].StartDistance:=D+A*L;FPassages[N].StartPoint:=RoadCenterAt(P);
      Inc(N);
    end;
    P.Segment:=I;P.T:=B;
    FPassages[N-1].EndDistance:=D+B*L;FPassages[N-1].EndPoint:=RoadCenterAt(P);
  end;
  N:=Length(FPassages);
  { Join a corridor crossing the loop's index zero. }
  if(N>1)and(FPassages[0].StartDistance+FPassageDistances[C]-FPassages[N-1].EndDistance<=48)then begin
    FPassages[N-1].EndDistance:=FPassageDistances[C]+FPassages[0].EndDistance;
    FPassages[N-1].EndPoint:=FPassages[0].EndPoint;
    for I:=1 to N-1 do FPassages[I-1]:=FPassages[I];
    Dec(N);SetLength(FPassages,N);
  end;
  for I:=0 to N-1 do begin
    { A narrow terminal U-turn has no passing bay. Keep the whole outbound
      and return span occupied until this one bicycle has returned outside. }
    if FOutAndBack then for Turn:=0 to 1 do begin
      J:=Turn*(C div 2);D:=FPassageDistances[J];
      if(PointWidth(J)<PassingWidth)and
        (((D>=FPassages[I].StartDistance)and(D<=FPassages[I].EndDistance))or
         ((D+FPassageDistances[C]>=FPassages[I].StartDistance)and
          (D+FPassageDistances[C]<=FPassages[I].EndDistance)))then FPassages[I].Exclusive:=True;
    end;
    Q[0]:=Round(FPassages[I].StartPoint.X*10);Q[1]:=Round(FPassages[I].StartPoint.Y*10);
    Q[2]:=Round(FPassages[I].StartPoint.Z*10);Q[3]:=Round(FPassages[I].EndPoint.X*10);
    Q[4]:=Round(FPassages[I].EndPoint.Y*10);Q[5]:=Round(FPassages[I].EndPoint.Z*10);
    FPassages[I].Forward:=(Q[0]<Q[3])or((Q[0]=Q[3])and((Q[1]<Q[4])or
      ((Q[1]=Q[4])and(Q[2]<Q[5]))));
    if not FPassages[I].Forward then for J:=0 to 2 do begin T:=Q[J];Q[J]:=Q[J+3];Q[J+3]:=T end;
    H:=14695981039346656037;
    {$push}{$Q-}{$R-}
    for J:=0 to SizeOf(Q)-1 do H:=(H xor PByte(@Q)[J])*1099511628211;
    {$pop}
    if H=0 then H:=1;FPassages[I].Key:=H;
  end;
end;

function TGamePath.NarrowPassageAt(const Pos:TPathPosition;LookAhead:Single;
  out Passage:TPathNarrowPassage):Boolean;
const ExitClearance=28;
var I,L,R,M,C:Integer; D,Shift,Total:Single; P:TPathPosition;
begin
  Result:=False;FillChar(Passage,SizeOf(Passage),0);
  if not FWorldPointsBaked then BakeWorldPoints;
  C:=PointCount;if(C<2)or(Length(FPassages)=0)then Exit;
  P:=ClampPathPosition(Pos);Total:=FPassageDistances[C];
  D:=FPassageDistances[P.Segment]+P.T*(FPassageDistances[P.Segment+1]-FPassageDistances[P.Segment]);
  Shift:=0;I:=High(FPassages);
  if(FPassages[I].EndDistance>Total)and(D<=FPassages[I].EndDistance-Total+ExitClearance)then Shift:=-Total
  else begin
    L:=0;R:=Length(FPassages);
    while L<R do begin M:=(L+R)div 2;
      if FPassages[M].EndDistance+ExitClearance<D then L:=M+1 else R:=M end;
    I:=L;if I=Length(FPassages)then begin I:=0;Shift:=Total end;
  end;
  Passage.EntryDistance:=FPassages[I].StartDistance+Shift-D;
  if Passage.EntryDistance>LookAhead then Exit;
  Passage.Key:=FPassages[I].Key;Passage.Forward:=FPassages[I].Forward;
  Passage.Exclusive:=FPassages[I].Exclusive;
  Passage.Inside:=Passage.EntryDistance<=0;Result:=True;
end;

{ ========================================================================== }
{ GetPathPointWorld — просто чтение из массива, без матричных операций        }
{ ========================================================================== }

function TGamePath.GetPathPointWorld(Index: Integer): TVector3;
var C: Integer;
begin
  C := PointCount;
  if C = 0 then begin Result := Vector3(0,0,0); Exit; end;
  Index := Index mod C;
  if Index < 0 then Index := Index + C;

  if FWorldPointsBaked then
    Result := FWorldPoints[Index]
  else
  begin
    Result := FPoints[Index];
    if Assigned(FLevelScene) then Result := FLevelScene.LocalToWorld(Result);
  end;
end;

function TGamePath.PathPointLocal(Index: Integer): TVector3;
begin
  if (Index < 0) or (Index >= Length(FPoints)) then
    Result := Vector3(0, 0, 0)
  else
    Result := FPoints[Index];
end;

procedure TGamePath.SetPathPointLocalXZ(Index: Integer; AX, AZ: Single);
begin
  if (Index < 0) or (Index >= Length(FPoints)) then Exit;
  FPoints[Index].X := AX;
  FPoints[Index].Z := AZ;
  FWorldPointsBaked := False;
  if Index <= High(FPointCenters) then
  begin
    { Keep center aligned if it was a pure copy of the point. }
  end;
end;

function TGamePath.ClampPathPosition(const Pos: TPathPosition): TPathPosition;
var C: Integer;
begin
  Result := Pos; C := PointCount; if C < 1 then Exit;
  while Result.T >= 1.0 do begin Result.T := Result.T - 1.0; Result.Segment := (Result.Segment+1) mod C; end;
  while Result.T < 0.0 do begin Result.T := Result.T + 1.0; Dec(Result.Segment); if Result.Segment < 0 then Result.Segment := Result.Segment + C; end;
end;

procedure TGamePath.AdvanceOnPath(var Pos: TPathPosition; Distance: Single);
var Tangent: TVector3; DsDt, Step: Single; Iters: Integer;
const
  MaxStep = 1.0;  { увеличен с 0.3 — для морковки точность не критична }
  { Safety cap. At MaxStep = 1 m the loop runs one iteration per metre,
    so iteration count == distance in metres. Any sane track is far
    under 200 km; a larger distance means the caller passed a cumulative
    / absolute value (e.g. a relay rider's 15 500 km), which would spin
    for tens of seconds on the main thread and freeze the whole app.
    Callers SHOULD wrap the distance by the path length first (the path
    is cyclic); this cap is the last-line defence so a bad value
    degrades to a wrong position instead of a hang. }
  MaxIters = 200000;
begin
  if PointCount < 2 then Exit; if Distance <= 0 then Exit;
  Iters := 0;
  while Distance > 0 do begin
    Step := Distance; if Step > MaxStep then Step := MaxStep;
    Tangent := GetSplineTangent(Pos);
    DsDt := Tangent.Length; if DsDt < 0.01 then DsDt := 0.01;
    Pos.T := Pos.T + Step / DsDt;
    Pos := ClampPathPosition(Pos);
    Distance := Distance - Step;
    Inc(Iters);
    if Iters >= MaxIters then
    begin
      WritelnLog('GamePath', Format('AdvanceOnPath: ABORTED after %d iters, '
        + '%.0f m of distance left unprocessed — caller passed an '
        + 'out-of-range distance (cumulative/absolute instead of '
        + 'wrapped-to-track-length?)', [Iters, Distance]));
      Break;
    end;
  end;
end;

function SplinePosition(const P0,P1,P2,P3: TVector3; const T: Single): TVector3;
var T2,T3: Single;
begin
  T2 := T*T; T3 := T2*T;
  Result.X := 0.5*((2*P1.X)+(-P0.X+P2.X)*T+(2*P0.X-5*P1.X+4*P2.X-P3.X)*T2+(-P0.X+3*P1.X-3*P2.X+P3.X)*T3);
  Result.Y := 0.5*((2*P1.Y)+(-P0.Y+P2.Y)*T+(2*P0.Y-5*P1.Y+4*P2.Y-P3.Y)*T2+(-P0.Y+3*P1.Y-3*P2.Y+P3.Y)*T3);
  Result.Z := 0.5*((2*P1.Z)+(-P0.Z+P2.Z)*T+(2*P0.Z-5*P1.Z+4*P2.Z-P3.Z)*T2+(-P0.Z+3*P1.Z-3*P2.Z+P3.Z)*T3);
end;

function SplineTangent(const P0,P1,P2,P3: TVector3; const T: Single): TVector3;
var T2,T3: Single;
begin
  T2 := T*T;
  Result.X := 0.5*((-P0.X+P2.X)+2*(2*P0.X-5*P1.X+4*P2.X-P3.X)*T+3*(-P0.X+3*P1.X-3*P2.X+P3.X)*T2);
  Result.Y := 0.5*((-P0.Y+P2.Y)+2*(2*P0.Y-5*P1.Y+4*P2.Y-P3.Y)*T+3*(-P0.Y+3*P1.Y-3*P2.Y+P3.Y)*T2);
  Result.Z := 0.5*((-P0.Z+P2.Z)+2*(2*P0.Z-5*P1.Z+4*P2.Z-P3.Z)*T+3*(-P0.Z+3*P1.Z-3*P2.Z+P3.Z)*T2);
end;

function TGamePath.GetSplinePosition(const Pos: TPathPosition): TVector3;
begin
  if PointCount < 2 then Exit(Vector3(0,0,0));
  Result := SplinePosition(GetPathPointWorld(Pos.Segment-1), GetPathPointWorld(Pos.Segment),
    GetPathPointWorld(Pos.Segment+1), GetPathPointWorld(Pos.Segment+2), Pos.T);
end;

function TGamePath.GetSplineTangent(const Pos: TPathPosition): TVector3;
begin
  if PointCount < 2 then Exit(Vector3(0,0,0));
  Result := SplineTangent(GetPathPointWorld(Pos.Segment-1), GetPathPointWorld(Pos.Segment),
    GetPathPointWorld(Pos.Segment+1), GetPathPointWorld(Pos.Segment+2), Pos.T);
end;

function TGamePath.GetSplineDirectionXZ(const Pos: TPathPosition): TVector3;
begin Result := NormalizeXZ(GetSplineTangent(Pos)); end;

{ Use the source polyline for following. GPS/snap samples often contain
  duplicates and strongly unequal spacing: uniform Catmull-Rom then invents
  reversing cusps. Steering already smooths heading toward its look-ahead.
  Position, tangent, distance and projection below use exactly this geometry. }
function TGamePath.RoadCenterAt(const Pos: TPathPosition): TVector3;
var A, B: TVector3;
begin
  if PointCount < 2 then Exit(Vector3(0,0,0));
  A := GetFollowPointWorld(Pos.Segment);
  B := GetFollowPointWorld(Pos.Segment+1);
  Result := A + (B-A) * Pos.T;
end;

function TGamePath.FollowTangent(const Pos: TPathPosition): TVector3;
begin
  if PointCount < 2 then Exit(Vector3(0,0,0));
  Result := GetFollowPointWorld(Pos.Segment+1) - GetFollowPointWorld(Pos.Segment);
end;

function TGamePath.FollowDirectionXZ(const Pos: TPathPosition): TVector3;
var I: Integer; Tangent: TVector3; Next: TPathPosition;
begin
  Next := Pos;
  for I := 1 to PointCount do
  begin
    Tangent := FollowTangent(Next);
    if Sqr(Tangent.X)+Sqr(Tangent.Z) > 0.000001 then
      Exit(NormalizeXZ(Tangent));
    Next.Segment := (Next.Segment+1) mod PointCount;
  end;
  Result := Vector3(0,0,1);
end;

procedure TGamePath.AdvanceFollow(var Pos: TPathPosition; Distance: Single);
var Len, Available, Dir: Single; I, EmptySegments: Integer;
begin
  if (PointCount < 2) or (Distance = 0) then Exit;
  Pos := ClampPathPosition(Pos);
  Dir := Sign(Distance);
  Distance := Min(Abs(Distance), 200000);
  EmptySegments := 0;
  for I := 1 to 400000 do
  begin
    Len := FollowTangent(Pos).Length;
    if Len < 0.000001 then
    begin
      Inc(EmptySegments);
      if EmptySegments >= PointCount then Exit;
    end
    else
    begin
      EmptySegments := 0;
      if Dir > 0 then Available := (1-Pos.T)*Len else Available := Pos.T*Len;
      if Distance <= Available then
      begin
        Pos.T := Pos.T + Dir*Distance/Len;
        Pos := ClampPathPosition(Pos);
        Exit;
      end;
      Distance := Distance - Available;
    end;
    if Dir > 0 then
    begin
      Pos.Segment := (Pos.Segment+1) mod PointCount;
      Pos.T := 0;
    end
    else
    begin
      Pos.Segment := (Pos.Segment+PointCount-1) mod PointCount;
      Pos.T := 1;
    end;
  end;
end;

function TGamePath.ProjectFollow(const WorldPosition: TVector3;
  const Seed: TPathPosition; const WindowM: Single): TPathPosition;
var
  BestDist, BestTravel: Single;
  Point: TVector3;

  procedure Search(const ForwardSearch: Boolean);
  var
    Cursor, Candidate: TPathPosition;
    A, Tangent, V: TVector3;
    Len, Denom, Remaining, Travel, Span, Lo, Hi, T, Dist, CandidateTravel: Single;
    I: Integer;
  begin
    Cursor := Seed;
    Remaining := WindowM;
    Travel := 0;
    { At most one lap; zero-length segments consume no distance. }
    for I := 0 to PointCount do
    begin
      A := GetFollowPointWorld(Cursor.Segment);
      Tangent := FollowTangent(Cursor);
      Len := Tangent.Length;
      if Len > 0.000001 then
      begin
        if ForwardSearch then
        begin
          Lo := Cursor.T;
          Hi := Min(1.0, Lo + Remaining/Len);
        end
        else
        begin
          Hi := Cursor.T;
          Lo := Max(0.0, Hi - Remaining/Len);
        end;
        Denom := Sqr(Tangent.X)+Sqr(Tangent.Z);
        if Denom > 0.000001 then
        begin
          T := EnsureRange(((WorldPosition.X-A.X)*Tangent.X +
            (WorldPosition.Z-A.Z)*Tangent.Z)/Denom, Lo, Hi);
          V := A + Tangent*T;
          Dist := Sqr(V.X-WorldPosition.X)+Sqr(V.Z-WorldPosition.Z);
          CandidateTravel := Travel + Abs(T-Cursor.T)*Len;
          if (Dist < BestDist - 0.0000001) or
             ((Abs(Dist-BestDist) <= 0.0000001) and (CandidateTravel < BestTravel)) then
          begin
            Candidate := Cursor; Candidate.T := T;
            Result := ClampPathPosition(Candidate);
            BestDist := Dist;
            BestTravel := CandidateTravel;
          end;
        end;
        Span := (Hi-Lo)*Len;
        Travel := Travel + Span;
        Remaining := Remaining - Span;
        if Remaining <= 0.00001 then Exit;
      end;
      if ForwardSearch then
      begin
        Cursor.Segment := (Cursor.Segment+1) mod PointCount; Cursor.T := 0;
      end
      else
      begin
        Cursor.Segment := (Cursor.Segment+PointCount-1) mod PointCount; Cursor.T := 1;
      end;
    end;
  end;

begin
  Result := Seed;
  if (PointCount < 2) or (WindowM <= 0) then Exit;
  Point := RoadCenterAt(Seed);
  BestDist := Sqr(Point.X-WorldPosition.X)+Sqr(Point.Z-WorldPosition.Z);
  BestTravel := 0;
  Search(True);
  Search(False);
end;

function TGamePath.RoadWidthAt(const Pos: TPathPosition): Single;
var
  I0, I1: Integer;
  W0, W1: Single;
begin
  Result := 0.0;
  if Length(FPointWidths) < 2 then Exit;

  { Точка пути лежит на сегменте Segment → Segment+1. }
  I0 := Pos.Segment;
  if I0 < 0 then I0 := 0;
  if I0 > High(FPointWidths) then I0 := High(FPointWidths);
  { The final segment ends at point zero, like FollowTangent/RoadCenterAt.
    Clamping to the last width made the same segment differ when reversed. }
  I1 := (I0 + 1) mod Length(FPointWidths);

  W0 := FPointWidths[I0];
  W1 := FPointWidths[I1];

  { Обе точки на дороге — линейная интерполяция ширины по T.
    Одна из точек off-road (ширина 0) — берём ширину ближайшей: так
    граница въезда/съезда с дороги приходится на середину сегмента,
    без интерполяции к нулю в пределах самой дороги. }
  if (W0 > 0.0) and (W1 > 0.0) then
    Result := W0 + (W1 - W0) * Pos.T
  else if Pos.T < 0.5 then
    Result := W0
  else
    Result := W1;
end;

{ NormalizeXZ / DistanceXZ / LerpDirXZ bodies removed — see GameMath.pas.
  Internal call at GetSplineDirectionXZ above resolves through GameMath
  via uses clause. }

procedure TGamePath.AdvancePathPosition(Distance: Single);
begin
  if PointCount < 2 then Exit;
  if Distance <= 0 then Exit;
  AdvanceOnPath(FPosition, Distance);
end;

procedure TGamePath.SyncPathPositionToWorldFast(const WorldPosition: TVector3);
var BestPos, TestPos: TPathPosition; BestDistSq, DistSq: Single; I: Integer;
begin
  if PointCount < 2 then Exit;
  if not FWorldPointsBaked then BakeWorldPoints;
  BestPos := FPosition;
  BestDistSq := Sqr(GetSplinePosition(BestPos).X-WorldPosition.X)+Sqr(GetSplinePosition(BestPos).Z-WorldPosition.Z);
  for I := 1 to 20 do begin
    TestPos := FPosition; TestPos.T := TestPos.T + I*0.04; TestPos := ClampPathPosition(TestPos);
    DistSq := Sqr(GetSplinePosition(TestPos).X-WorldPosition.X)+Sqr(GetSplinePosition(TestPos).Z-WorldPosition.Z);
    if DistSq < BestDistSq then begin BestDistSq := DistSq; BestPos := TestPos; end;
  end;
  for I := 1 to 8 do begin
    TestPos := FPosition; TestPos.T := TestPos.T - I*0.04; TestPos := ClampPathPosition(TestPos);
    DistSq := Sqr(GetSplinePosition(TestPos).X-WorldPosition.X)+Sqr(GetSplinePosition(TestPos).Z-WorldPosition.Z);
    if DistSq < BestDistSq then begin BestDistSq := DistSq; BestPos := TestPos; end;
  end;
  FPosition := BestPos;
end;

function TGamePath.FindPathPositionNear(const WorldPosition: TVector3;
  const ASeed: TPathPosition): TPathPosition;
var BestPos, TestPos: TPathPosition; BestDistSq, DistSq: Single; I: Integer;
begin
  { Тот же локальный поиск, что SyncPathPositionToWorldFast, но БЕЗ записи
    в общий курсор FPosition — кинематик-камера снимает свою позицию на
    пути этим вызовом и больше НЕ дергает курсор физики (её ресинхронизация
    на извилинах старта ловила райдера в челночную петлю). }
  Result := ASeed;
  if PointCount < 2 then Exit;
  if not FWorldPointsBaked then BakeWorldPoints;
  BestPos := ASeed;
  BestDistSq := Sqr(GetSplinePosition(BestPos).X-WorldPosition.X)+Sqr(GetSplinePosition(BestPos).Z-WorldPosition.Z);
  for I := 1 to 20 do begin
    TestPos := ASeed; TestPos.T := TestPos.T + I*0.04; TestPos := ClampPathPosition(TestPos);
    DistSq := Sqr(GetSplinePosition(TestPos).X-WorldPosition.X)+Sqr(GetSplinePosition(TestPos).Z-WorldPosition.Z);
    if DistSq < BestDistSq then begin BestDistSq := DistSq; BestPos := TestPos; end;
  end;
  for I := 1 to 8 do begin
    TestPos := ASeed; TestPos.T := TestPos.T - I*0.04; TestPos := ClampPathPosition(TestPos);
    DistSq := Sqr(GetSplinePosition(TestPos).X-WorldPosition.X)+Sqr(GetSplinePosition(TestPos).Z-WorldPosition.Z);
    if DistSq < BestDistSq then begin BestDistSq := DistSq; BestPos := TestPos; end;
  end;

  { Затравка далеко от райдера (повторная езда: у камеры затравка осталась
    от ПРОШЛОГО маршрута; телепорт по ходу езды) — локальное окно ±0.8T
    до райдера не дотягивается, и камера остаётся на устаревшей позиции
    (смотрит назад/не туда). Тогда — полный перебор всех точек: редкий
    случай, цена одного кадра приемлема.
    BISECT: GPathFindFullRescan=False disables this (pre-13.08 behaviour). }
  if GPathFindFullRescan and (BestDistSq > 2500) then   { >50 м до лучшего в окне }
  begin
    for I := 0 to PointCount - 1 do
    begin
      TestPos.Segment := I; TestPos.T := 0;
      DistSq := Sqr(GetSplinePosition(TestPos).X-WorldPosition.X)+Sqr(GetSplinePosition(TestPos).Z-WorldPosition.Z);
      if DistSq < BestDistSq then begin BestDistSq := DistSq; BestPos := TestPos; end;
    end;
  end;

  Result := BestPos;
end;

function TGamePath.GetSmartRouteDirection(const WorldPosition: TVector3;
  const CurrentSpeed, DeltaTime: Single;
  const ALaneOffset: Single; const ResetDirection: Boolean): TVector3;
const
  { Below this speed, blend carrot direction with path tangent.
    On steep climbs the carrot's XZ projection shrinks → unreliable direction.
    Path tangent is always stable regardless of slope. }
  LowSpeedThreshold = 3.0;
var
  LookAhead: Single;
  CarrotPos: TPathPosition;
  CarrotWorld, RawDir, OldSmoothed, PathDir, PathTangent, RightVec: TVector3;
  Blend, SpeedBlend: Single;
  WobbleBlend, Remaining, Span: Single;
  NextCorner, Guard: Integer;
  KeepCorner, AllowLateral: Boolean;
  LaneShift: Single;
begin
  if PointCount < 2 then begin Result := FSmoothedRouteDir; Exit; end;
  if ResetDirection then ResetTurnaround;

  { Ленивый bake при первом использовании }
  if not FWorldPointsBaked then BakeWorldPoints;

  FPosition:=ClampPathPosition(FPosition);
  SteeringSpeedLimit:=Sqrt(4.0+6.0*Max(0.0,
    FCornerDistance[FPosition.Segment]-FPosition.T*FollowTangent(FPosition).Length-2.0));
  LookAhead := MinLookAhead + CurrentSpeed * LookAheadPerSpeed;
  CarrotPos := FPosition;
  { Prepared detours contain mandatory bends. Do not aim through the next
    wall by skipping a bend with the ordinary speed-dependent look-ahead.
    This follows precomputed geometry; no building query or planning here. }
  Remaining:=LookAhead; KeepCorner:=False;
  if not FPreparedBuildingRoute then AdvanceFollow(CarrotPos,LookAhead)
  else for Guard:=0 to PointCount-1 do
  begin
    Span:=(1-CarrotPos.T)*FollowTangent(CarrotPos).Length;
    NextCorner:=(CarrotPos.Segment+1) mod PointCount;
    if FSteeringCorners[NextCorner] and (Span<Remaining) and
      (DistanceXZ(WorldPosition,GetFollowPointWorld(NextCorner))>0.6) then
    begin CarrotPos.T:=1; KeepCorner:=True; Break end;
    if Span>=Remaining then begin AdvanceFollow(CarrotPos,Remaining); Break end;
    if FSteeringCorners[NextCorner] and (CarrotPos.Segment=FPosition.Segment) and
      (DistanceXZ(WorldPosition,GetFollowPointWorld(NextCorner))<=0.6) then
    begin FPosition.Segment:=NextCorner; FPosition.T:=0 end;
    Remaining:=Remaining-Span;
    CarrotPos.Segment:=NextCorner; CarrotPos.T:=0;
  end;
  { База морковки — ОСЕВАЯ ДОРОГИ (куда притянул снап), а не сырой трек.
    Тогда боковой offset откладывается от центра дороги, и райдер едет
    по полосам разметки. Если центров нет (нет снапа/не та карта) —
    RoadCenterAt падает на сам путь, поведение прежнее. }
  CarrotWorld := RoadCenterAt(CarrotPos);

  { Apply lane offset perpendicular to path direction at carrot }
  PathDir := FollowDirectionXZ(CarrotPos);
  RightVec := TVector3.CrossProduct(PathDir, Vector3(0, 1, 0));
  if RightVec.Length > 0.001 then
    RightVec := RightVec.Normalize
  else
    RightVec := Vector3(1, 0, 0);

  { The prepared detour has zero lateral clearance. A lane request from
    another route distance (or from a missing width profile) must never move
    its target back into the building. Check BOTH the current and target
    segments, including their endpoints; keep the whole transition centered. }
  AllowLateral:=(not FPreparedBuildingRoute) or
    ((PointWidth(FPosition.Segment)>0) and
     (PointWidth((FPosition.Segment+1) mod PointCount)>0) and
     (PointWidth(CarrotPos.Segment)>0) and
     (PointWidth((CarrotPos.Segment+1) mod PointCount)>0));
  LaneShift:=ALaneOffset;
  if not AllowLateral then LaneShift:=0;
  LastLaneOffsetM:=LaneShift;
  if Abs(LaneShift)>0.001 then
    CarrotWorld:=CarrotWorld+RightVec*LaneShift;

  LastWobbleOffsetM := 0;
  { Test periodic L/R sway (meters) — overrides micro-wobble while on.
    Sine on the carrot forces continuous yaw → lean + handlebar steer. }
  if AllowLateral and PathTestWobbleEnabled and (DeltaTime > 0)
     and (PathTestWobbleAmplitudeM > 0) and (PathTestWobblePeriodS > 0.1) then
  begin
    FWobblePhase := FWobblePhase + DeltaTime;
    if FWobblePhase > PathTestWobblePeriodS then
      FWobblePhase := FWobblePhase - PathTestWobblePeriodS
        * Trunc(FWobblePhase / PathTestWobblePeriodS);
    FWobbleCurrent := PathTestWobbleAmplitudeM
      * Sin(2.0 * Pi * FWobblePhase / PathTestWobblePeriodS);
    LastWobbleOffsetM := FWobbleCurrent;
    CarrotWorld := CarrotWorld + RightVec * FWobbleCurrent;
  end
  { Wobble — smooth random lateral micro-drift for lifelike movement.
    Pick a new random target every 1.5–3.5 s, smoothly interpolate toward it. }
  else if AllowLateral and CarrotWobbleEnabled and (DeltaTime > 0) and (CarrotWobbleAmplitude > 0) then
  begin
    FWobbleTimer := FWobbleTimer - DeltaTime;
    if FWobbleTimer <= 0 then
    begin
      FWobbleTarget := (Random * 2.0 - 1.0) * CarrotWobbleAmplitude;
      FWobbleTimer := 1.5 + Random * 2.0;
    end;
    WobbleBlend := DeltaTime * 1.5;  { ~0.67 s to reach target }
    if WobbleBlend > 1.0 then WobbleBlend := 1.0;
    FWobbleCurrent := FWobbleCurrent + (FWobbleTarget - FWobbleCurrent) * WobbleBlend;
    LastWobbleOffsetM := FWobbleCurrent;
    CarrotWorld := CarrotWorld + RightVec * FWobbleCurrent;
  end;

  { Store final carrot (with lane offset + Y offset for model center) for trace }
  LastCarrotWorld := CarrotWorld;
  if CarrotYOffset > 0 then
    LastCarrotWorld.Y := LastCarrotWorld.Y + CarrotYOffset;

  RawDir := Vector3(CarrotWorld.X - WorldPosition.X, 0, CarrotWorld.Z - WorldPosition.Z);
  if RawDir.Length > 0.001 then
    RawDir := RawDir.Normalize
  else
    RawDir := FollowDirectionXZ(FPosition);

  { At low speed, blend toward path tangent to prevent oscillation on steep climbs.
    The carrot's XZ projection degrades when path is mostly vertical —
    path tangent is always stable regardless of slope angle. }
  if (CurrentSpeed < LowSpeedThreshold) and (not KeepCorner) and
     ((not FPreparedBuildingRoute) or (PointWidth(FPosition.Segment)>0)) then
  begin
    PathTangent := FollowDirectionXZ(FPosition);
    SpeedBlend := CurrentSpeed / LowSpeedThreshold;
    { Do not suppress the steering needed to leave a stationary queue for a
      clear lane. Traffic still limits crawl speed and sweeps collisions. }
    if Abs(LaneShift-TVector3.DotProduct(WorldPosition-RoadCenterAt(FPosition),
      Vector3(-PathTangent.Z,0,PathTangent.X)))>0.15 then SpeedBlend:=Max(0.5,SpeedBlend);
    RawDir := LerpDirXZ(PathTangent, RawDir, SpeedBlend);
  end;

  OldSmoothed := FSmoothedRouteDir;

  Blend := DeltaTime / DirectionSmoothTime;
  if Blend > 1.0 then Blend := 1.0;
  if ResetDirection then FSmoothedRouteDir := RawDir
  else FSmoothedRouteDir := LerpDirXZ(FSmoothedRouteDir, RawDir, Blend);
  Result := FSmoothedRouteDir;

  if DebugEnabled then
    Logger.Info(Format(
      '  PATH | LookAhead=%.2f CarrotSeg=%d CarrotT=%.4f ' +
      'CarrotXZ=(%.3f,%.3f) AvatarXZ=(%.3f,%.3f) | ' +
      'RawDir=(%.4f,%.4f) OldSmooth=(%.4f,%.4f) NewSmooth=(%.4f,%.4f) Blend=%.4f | ' +
      'PathSeg=%d PathT=%.4f PathXZ=(%.3f,%.3f)',
      [LookAhead, CarrotPos.Segment, CarrotPos.T,
       CarrotWorld.X, CarrotWorld.Z,
       WorldPosition.X, WorldPosition.Z,
       RawDir.X, RawDir.Z,
       OldSmoothed.X, OldSmoothed.Z,
       FSmoothedRouteDir.X, FSmoothedRouteDir.Z,
       Blend,
       FPosition.Segment, FPosition.T,
       GetSplinePosition(FPosition).X, GetSplinePosition(FPosition).Z
      ]));
end;

end.
