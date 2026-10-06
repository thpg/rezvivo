unit GamePhysicsBase;

interface

uses Classes, Math,
  CastleVectors, CastleTransform, CastleViewport, CastleScene,
  CastleThirdPersonNavigation, CastleUIControls, CastleControls,
  CastleShapes,
  GamePhysicsCommon, GamePath, GameAgentControl, GameProfiler;

type
  TGroundTrackingReplay = record
    SmoothedGroundY: Single;
    SmoothedGroundYValid: Boolean;
    GroundProbePosition: TVector3;
    GroundGradient: TVector3;
    GroundWaitSec: Single;
    PrevYawRad: Single;
    SmoothedYawRateRad: Single;
    YawRateValid: Boolean;
    SlopeCorrSmooth: Single;
    ElevDebtM: Single;
    RoadSlopeGrade: Single;
    RoadSlopeValid: Boolean;
    RoadSlopeMissSec, RoadSlopeMissM: Single;
    FitSlopeMissSec, FitSlopeMissM: Single;
  end;

  PAgentControlInput = ^TAgentControlInput;

  TCustomActorPhysics = class abstract
  protected
    FActor: TPhysicsActor;
    FState: TPhysicsState;
    FPath: TGamePath;
    FDebug: TPhysicsDebug;
    FControlInput: PAgentControlInput;
    FProfiler: TFrameProfiler;  { внешний, не владеем }

    { Сглаживание ground Y — raycast возвращает дискретные Y
      из треугольников террейна, создавая ступеньки }
    FSmoothedGroundY: Single;
    FSmoothedGroundYValid: Boolean;

    { Height plane is anchored in world XZ at the latest wheel probes.
      Rendering and physics evaluate it at their OWN positions. }
    FGroundProbePosition, FGroundGradient: TVector3;
    FGroundLeaseLimitedSteps: QWord;
    FGroundLeaseRejectedMeters: Double;
    FGroundWaitSec: Single;

    { Состояние оценки кривизны траектории (см. UpdateTrajectoryFromRealVelocity).
      Кривизна берётся из приращения рысканья, а не из разности мировых
      координат: последняя на float32-координатах в километрах от начала
      мира теряла значимость и давала шум в разы выше сигнала.
      FYawRateValid = False → следующий шаг только привяжет опору. }
    FPrevYawRad: Single;
    FSmoothedYawRateRad: Single;
    FYawRateValid: Boolean;

    { Сглаженная добавка уклона FIT−меш, % grade (не градусы). }
    FSlopeCorrSmooth: Single;
    { Невыплаченные метры FIT−меш: плюс = ещё должны подъём (или
      меньший спуск). Учитываем фактически применённую поправку после
      сглаживания и ограничения знаком уклона меша. }
    FElevDebtM: Single;
    { Road-scale gravity is separate from the metre-long wheel contact plane.
      Missing asynchronous samples retain the last estimate for a bounded lease. }
    FRoadSlopeGrade: Single;
    FRoadSlopeValid: Boolean;
    FRoadSlopeMissSec, FRoadSlopeMissM: Single;
    FFitSlopeMissSec, FFitSlopeMissM: Single;
    procedure ResetSlopeTracking;

    function GroundHeightAtPosition(const Pos: TVector3): Single;
    procedure CaptureCameraRelativeState;
    procedure RestoreCameraRelativeState;
    procedure ApplyControlInput;

    function NormalizeAngleRad(const A: Single): Single;

    { SignedAngleXZ / DistanceXZ / NormalizeXZ / LerpDirXZ moved to
      GameMath.pas — they were pure-math helpers wrongly stored as
      methods. Internal call sites and external callers (gamepath,
      gamephysicskinematic) updated to use GameMath directly. }

    procedure PushTrajectorySample(const APosition: TVector3; const ATimeStamp: Single);
    function GetTrajectorySample(const RelativeIndexFromOldest: Integer): TTrajectorySample;
    function FindOldSampleForWindow(const WindowSeconds: Single; out SampleIndex: Integer): Boolean;
    procedure UpdateTrajectoryFromRealVelocity(const DeltaTime: Single);

    function CalculateTurnLeanAngle: Single;
    function CalculateTurnSpeedLimit: Single;

    procedure MeasureModelBounds;
    procedure ComputeGroundContactOffset;
    function IsOwnCollider(const T: TCastleTransform): Boolean;
    function FindGroundHeightAt(const X, Z: Single): Single; overload;
    { Same as FindGroundHeightAt, but reports how Y was resolved
      (mesh query / hold / raycast) for ground-log diagnostics. }
    function FindGroundHeightAt(const X, Z: Single;
      out ASrc: TGroundHitSource; out AHit: Boolean): Single; overload;
    { Gravity/trainer grade on a centred road segment. Mesh and FIT are
      sampled at the same endpoints; wheel pitch remains visual only. }
    procedure ApplySmoothedFitSlope(const PitchDeg, DeltaTime: Single);
    function ApplyRouteLoadProfile: Boolean;
    procedure UpdateDebugSpheres(const FrontWheelPos, RearWheelPos,
      FrontGroundPos, RearGroundPos: TVector3);
    function PlaceActorByWheels(const CenterXZ: TVector3; const Dir: TVector3; const FixedDelta: Single): Single;

    procedure UpdateModelPitch(DeltaTime: Single);
    procedure UpdateModelRoll(DeltaTime: Single);
    procedure ApplyModelRotation;
    function CalculateAcceleration(const DeltaTime:Single): Single;
    procedure SmoothRotateToDirection(const TargetDir: TVector3; DeltaTime: Single);
    function UpdateRouteTurnaround(const DeltaTime: Single): Boolean;
  public
    function CaptureReplay: TGroundTrackingReplay;
    procedure RestoreReplay(const Saved: TGroundTrackingReplay);
  public
    constructor Create(const AActor: TPhysicsActor; const AState: TPhysicsState;
      const APath: TGamePath; const ADebug: TPhysicsDebug;
      const AControlInput: PAgentControlInput); virtual;

    procedure Initialize; virtual;
    { A known start height seeds pending GPU wheel probes. NaN preserves
      the route's own height for legacy and baked worlds. }
    procedure InitializeAtStart(const InitialGroundY: Single = NaN); virtual;
    procedure StartMoving; virtual;
    procedure StopMoving; virtual;

    procedure FixedStep(const FixedDelta: Single); virtual; abstract;
    procedure SyncFromWorld; virtual;
    function Mode: TPhysicsMode; virtual; abstract;

    { Визуальное размещение на земле — вызывается каждый render-кадр.
      Raycast в текущей XZ, smooth Y, pitch/roll/rotation, debug-сферы.
      FixedStep делает только XZ-движение и slope для CalculateAcceleration. }
    procedure UpdateVisualGroundPlacement(const DeltaTime: Single);

    { Раздельные половины ground placement для троттлинга:
      UpdateVisualGroundProbes — ДОРОГАЯ часть (7 проб земли + сглаживание
      + slope/pitch-состояние), можно звать на 30 Гц;
      ApplyVisualGroundPlacement — ДЕШЁВАЯ часть (применить сглаженный Y к
      Transform/WorldPosition + pitch/roll smoothing + ApplyModelRotation),
      ОБЯЗАТЕЛЬНО каждый render-кадр: RestorePhysicsPosition в агенте каждый
      кадр откатывает Transform к сохранённой позиции с протухшим Y, и без
      переприменения визуального Y модель дёргается/тонет (колёса в земле). }
    procedure UpdateVisualGroundProbes(const DeltaTime: Single);
    procedure ApplyVisualGroundPlacement(const DeltaTime: Single);
    procedure UpdateVisualDebug; virtual;
    procedure InvalidateGroundPlacement;
    procedure ResetTrackingAfterTeleport;
    property GroundPlacementValid: Boolean read FSmoothedGroundYValid;
    { A pending streaming query may reuse the latest plane only locally.
      Pure clipping: no queries or state changes, also used by interpolation. }
    function ConstrainGroundMovement(const Position, Movement: TVector3): TVector3;
    { Diagnostics over this physics object's lifetime, not replay state.
      Initial waiting without a plane is excluded (no requested move yet). }
    property GroundLeaseLimitedSteps: QWord read FGroundLeaseLimitedSteps;
    property GroundLeaseRejectedMeters: Double read FGroundLeaseRejectedMeters;
    property GroundWaitSeconds: Single read FGroundWaitSec;

    { Точная геометрия колёсных проб: WheelOffset := AHalfSpanM
      (ModelHalfLength := AHalfSpanM + ScaledWheelInset). Вызывать из кода,
      знающего реальную базу колёс (TBikeInstance.AxleHalfSpanM), вместо
      bbox-оценки MeasureModelBounds — bbox модели может включать теневой
      catcher/rig и давать пробы в метрах от колёс. }
    procedure SetWheelProbeHalfSpan(const AHalfSpanM: Single);

    property Profiler: TFrameProfiler read FProfiler write FProfiler;
  end;

implementation


uses
  SysUtils, CastleSceneCore, CastleQuaternions, CastleBoxes, CastleColors, GameMath, DebugLog;     { NormalizeXZ, DistanceXZ, LerpDirXZ, SignedAngleXZ }

const GroundPlaneRadius = 1.5;

function TCustomActorPhysics.CaptureReplay: TGroundTrackingReplay;
begin
  Result.SmoothedGroundY:=FSmoothedGroundY;
  Result.SmoothedGroundYValid:=FSmoothedGroundYValid;
  Result.GroundProbePosition:=FGroundProbePosition;
  Result.GroundGradient:=FGroundGradient;
  Result.GroundWaitSec:=FGroundWaitSec;
  Result.PrevYawRad:=FPrevYawRad;
  Result.SmoothedYawRateRad:=FSmoothedYawRateRad;
  Result.YawRateValid:=FYawRateValid;
  Result.SlopeCorrSmooth:=FSlopeCorrSmooth;
  Result.ElevDebtM:=FElevDebtM;
  Result.RoadSlopeGrade:=FRoadSlopeGrade;
  Result.RoadSlopeValid:=FRoadSlopeValid;
  Result.RoadSlopeMissSec:=FRoadSlopeMissSec;
  Result.RoadSlopeMissM:=FRoadSlopeMissM;
  Result.FitSlopeMissSec:=FFitSlopeMissSec;
  Result.FitSlopeMissM:=FFitSlopeMissM;
end;

procedure TCustomActorPhysics.RestoreReplay(const Saved: TGroundTrackingReplay);
begin
  FSmoothedGroundY:=Saved.SmoothedGroundY;
  FSmoothedGroundYValid:=Saved.SmoothedGroundYValid;
  FGroundProbePosition:=Saved.GroundProbePosition;
  FGroundGradient:=Saved.GroundGradient;
  FGroundWaitSec:=Saved.GroundWaitSec;
  FPrevYawRad:=Saved.PrevYawRad;
  FSmoothedYawRateRad:=Saved.SmoothedYawRateRad;
  FYawRateValid:=Saved.YawRateValid;
  FSlopeCorrSmooth:=Saved.SlopeCorrSmooth;
  FElevDebtM:=Saved.ElevDebtM;
  FRoadSlopeGrade:=Saved.RoadSlopeGrade;
  FRoadSlopeValid:=Saved.RoadSlopeValid;
  FRoadSlopeMissSec:=Saved.RoadSlopeMissSec;
  FRoadSlopeMissM:=Saved.RoadSlopeMissM;
  FFitSlopeMissSec:=Saved.FitSlopeMissSec;
  FFitSlopeMissM:=Saved.FitSlopeMissM;
end;

procedure TCustomActorPhysics.ResetSlopeTracking;
begin
  FSlopeCorrSmooth:=0;
  FElevDebtM:=0;
  FRoadSlopeGrade:=0;
  FRoadSlopeValid:=False;
  FRoadSlopeMissSec:=0; FRoadSlopeMissM:=0;
  FFitSlopeMissSec:=0; FFitSlopeMissM:=0;
end;

constructor TCustomActorPhysics.Create(const AActor: TPhysicsActor; const AState: TPhysicsState;
  const APath: TGamePath; const ADebug: TPhysicsDebug;
  const AControlInput: PAgentControlInput);
begin
  inherited Create;
  FActor := AActor;
  FState := AState;
  FPath := APath;
  FDebug := ADebug;
  FControlInput := AControlInput;
  FSmoothedGroundY := 0;
  FSmoothedGroundYValid := false;
  FGroundProbePosition := Vector3(0, 0, 0);
  FGroundGradient := Vector3(0, 0, 0);
  FGroundLeaseLimitedSteps := 0;
  FGroundLeaseRejectedMeters := 0;
  FGroundWaitSec := 0;
  FPrevYawRad := 0;
  FSmoothedYawRateRad := 0;
  FYawRateValid := false;
  ResetSlopeTracking;
end;

procedure TCustomActorPhysics.Initialize;
begin
  if not Assigned(FState) then Exit;
  MeasureModelBounds;
  ComputeGroundContactOffset;
  { Raise the path-follow carrot to the rider's center (half model height)
    so the look-ahead target is not on the ground but at mid-body. }
  if Assigned(FPath) and (FState.ModelHeight > 0) then
    FPath.CarrotYOffset := FState.ModelHeight * 0.5;
end;

procedure TCustomActorPhysics.InitializeAtStart(const InitialGroundY: Single);
var
  StartPos, Dir: TVector3;
  ZeroPos: TPathPosition;
begin
  if not Assigned(FState) then Exit;
  if FPath.PointCount < 2 then Exit;
  if not Assigned(FActor.Transform) then Exit;

  ZeroPos.Segment := 0;
  ZeroPos.T := 0;
  FPath.Position := ZeroPos;

  FState.ResetDynamic;
  InvalidateGroundPlacement;

  StartPos := FPath.RoadCenterAt(FPath.Position);
  if not IsNan(InitialGroundY) and not IsInfinite(InitialGroundY) then
    StartPos.Y := InitialGroundY;
  FState.LastGroundY := StartPos.Y;
  FState.WorldPosition := StartPos;

  { Use the steering solver's actual first target, including its handling
    of tiny/repeated start points and already reached corners. Initializing
    from segment 0 alone could face the bike opposite to its first step. }
  Dir := FPath.GetSmartRouteDirection(StartPos, 0, 0, 0, True);
  if Dir.Length < 0.001 then
    Dir := Vector3(0, 0, 1);

  FState.ForwardDir := Dir.Normalize;
  FPath.SmoothedRouteDir := FState.ForwardDir;
  FState.CurrentYawRad := ArcTan2(FState.ForwardDir.Z, FState.ForwardDir.X);
  { Опора фильтра скорости рысканья — сразу от стартового курса, иначе
    первый шаг дал бы дельту от нуля (ResetDynamic обнуляет CurrentYawRad)
    и один кадр паразитного крена. }
  FPrevYawRad := FState.CurrentYawRad;
  FSmoothedYawRateRad := 0;
  FYawRateValid := True;
  FState.PrevWorldPosition := FState.WorldPosition;
  FState.RealVelocity := Vector3(0, 0, 0);
  FState.TrajectorySampleCount := 0;
  FState.TrajectorySampleIndex := 0;

  PushTrajectorySample(FState.WorldPosition, FState.SimulationTime);

  FActor.Transform.Direction := FState.ForwardDir;
  FActor.Transform.Up := Vector3(0, 1, 0);

  ResetSlopeTracking;
  FState.CurrentGroundPitch := PlaceActorByWheels(FState.WorldPosition, FState.ForwardDir, 1.0);
  FState.CurrentSlopeAngle := FState.CurrentGroundPitch;
  FState.CurrentSlopeCorrDeg := 0;
  FState.CurrentSlopeCorrValid := False;
  FState.CurrentModelPitch := FState.CurrentGroundPitch;
  FState.CurrentTurnAngle := 0;
  ApplyModelRotation;

  FState.CameraStateValid := false;
  FState.CameraLockActive := false;
end;

procedure TCustomActorPhysics.StartMoving;
begin
  if not Assigned(FState) then Exit;
  if FPath.PointCount < 2 then Exit;
  FState.AutoMove := true;
  FState.AccumulatedTime := 0;
  FSmoothedGroundYValid := false;
  { Пере-привязка опоры рысканья: пока райдер стоял (холд прогрева, пауза),
    курс мог быть изменён кем угодно, а PrevWorldPosition устарел —
    без этого первый шаг движения дал бы выброс скорости рысканья. }
  FYawRateValid := false;

  FState.CameraLockActive := Assigned(FActor.Navigation);
  FState.CameraStateValid := false;
  CaptureCameraRelativeState;
end;

procedure TCustomActorPhysics.StopMoving;
begin
  if not Assigned(FState) then Exit;
  FState.AutoMove := false;
  FState.CurrentSpeed := 0;
  FState.MovementVelocity := Vector3(0, 0, 0);
  FState.AccumulatedTime := 0;
  FState.CameraLockActive := false;
  FState.CameraStateValid := false;
end;

procedure TCustomActorPhysics.SyncFromWorld;
begin
end;

procedure TCustomActorPhysics.CaptureCameraRelativeState;
begin
  if not Assigned(FState) then Exit;
  FState.CameraStateValid := false;
  if not FState.CameraLockActive then Exit;
  if not Assigned(FActor.Viewport) then Exit;
  if not Assigned(FActor.Viewport.Camera) then Exit;
  if not Assigned(FActor.Transform) then Exit;
  if Assigned(FActor.Navigation) and FActor.Navigation.MouseLook then Exit;

  FState.CameraRelativePos := FActor.Viewport.Camera.Translation - FActor.Transform.Translation;
  FState.CameraDirectionSaved := FActor.Viewport.Camera.Direction;
  FState.CameraUpSaved := FActor.Viewport.Camera.Up;
  FState.CameraStateValid := true;
end;

procedure TCustomActorPhysics.RestoreCameraRelativeState;
begin
  if not Assigned(FState) then Exit;
  if not FState.CameraLockActive then Exit;
  if not FState.CameraStateValid then Exit;
  if not Assigned(FActor.Viewport) then Exit;
  if not Assigned(FActor.Viewport.Camera) then Exit;
  if not Assigned(FActor.Transform) then Exit;
  if Assigned(FActor.Navigation) and FActor.Navigation.MouseLook then Exit;

  FActor.Viewport.Camera.Translation := FActor.Transform.Translation + FState.CameraRelativePos;
  FActor.Viewport.Camera.Direction := FState.CameraDirectionSaved;
  FActor.Viewport.Camera.Up := FState.CameraUpSaved;
end;

function TCustomActorPhysics.NormalizeAngleRad(const A: Single): Single;
begin
  Result := A;
  while Result > Pi do Result := Result - 2 * Pi;
  while Result < -Pi do Result := Result + 2 * Pi;
end;

{ XZ helpers (SignedAngleXZ, DistanceXZ, NormalizeXZ, LerpDirXZ) moved to
  GameMath.pas. Internal call sites resolve through `uses GameMath` below. }


procedure TCustomActorPhysics.ApplyControlInput;
begin
  if not Assigned(FState) then Exit;
  if FControlInput = nil then Exit;
  FState.AppliedPowerWatts := FControlInput^.DesiredPowerWatts;
  FState.AutoMove := FControlInput^.WantsAutoMove;
end;


procedure TCustomActorPhysics.PushTrajectorySample(const APosition: TVector3; const ATimeStamp: Single);
begin
  if not Assigned(FState) then Exit;
  FState.TrajectorySamples[FState.TrajectorySampleIndex].Position := APosition;
  FState.TrajectorySamples[FState.TrajectorySampleIndex].TimeStamp := ATimeStamp;
  FState.TrajectorySampleIndex := (FState.TrajectorySampleIndex + 1) mod Length(FState.TrajectorySamples);
  if FState.TrajectorySampleCount < Length(FState.TrajectorySamples) then
    Inc(FState.TrajectorySampleCount);
end;

function TCustomActorPhysics.GetTrajectorySample(const RelativeIndexFromOldest: Integer): TTrajectorySample;
var
  OldestIndex, RealIndex: Integer;
begin
  Result.Position := Vector3(0, 0, 0);
  Result.TimeStamp := 0;
  if not Assigned(FState) then Exit;
  if FState.TrajectorySampleCount <= 0 then Exit;

  if FState.TrajectorySampleCount < Length(FState.TrajectorySamples) then
    OldestIndex := 0
  else
    OldestIndex := FState.TrajectorySampleIndex;

  RealIndex := (OldestIndex + RelativeIndexFromOldest) mod Length(FState.TrajectorySamples);
  Result := FState.TrajectorySamples[RealIndex];
end;

function TCustomActorPhysics.FindOldSampleForWindow(const WindowSeconds: Single; out SampleIndex: Integer): Boolean;
var
  I: Integer;
  S: TTrajectorySample;
begin
  Result := false;
  SampleIndex := -1;
  if not Assigned(FState) then Exit;
  if FState.TrajectorySampleCount < 2 then Exit;

  for I := 0 to FState.TrajectorySampleCount - 1 do
  begin
    S := GetTrajectorySample(I);
    if (FState.SimulationTime - S.TimeStamp) <= WindowSeconds then
    begin
      SampleIndex := I;
      Result := true;
      Exit;
    end;
  end;
end;

{ Кривизна траектории — из СКОРОСТИ РЫСКАНЬЯ, а не из численного
  дифференцирования мировых координат.

  Что было. Кривизна считалась двойной разностью позиций из кольца
  траектории: два соседних сегмента → их направления → угол между ними
  (SignedAngleXZ) → кривизна = угол / длина дуги. Позиции — TVector3, то
  есть float32, а начало мира — ЦЕНТРОИД маршрута (GameOsmStreaming:
  FOrigin := TRouteSrc.OriginCentroid). На заезде 20-60 км координаты
  ВСЁ ВРЕМЯ, включая старт, держатся в единицах-десятках километров, где
  ulp float32 = |X| * 1.2e-7, то есть 1-4 мм. Разность двух соседних
  сэмплов (база = скорость * шаг = 8 м/с / 60 Гц = 133 мм) — это
  катастрофическая потеря значимости: остаётся 1-2 значащих миллиметра,
  ошибка направления 1-3% → 0.01-0.03 рад шума на угол. Истинный угол за
  шаг на плавном повороте R=300 м — 0.0004 рад. Шум превышал сигнал в
  5-30 раз, знак поворота был СЛУЧАЙНЫМ: цель крена прыгала на ±9°
  каждый физический шаг, UpdateModelRoll с RollSmoothness=120°/с
  отрабатывал по 2° за кадр — велосипед мелко трясло вбок на десятках
  герц. Это не ловилось ни фильтром направления (0.5 с в
  GetSmartRouteDirection запирает траекторию, но крен идёт мимо него), ни
  гейтом MaxMeaningfulTurnRadius: шумовая оценка давала R ~ 80 м и всегда
  проходила порог 5000 м.

  Почему можно точно. Движение чисто кинематическое: позиция сдвигается
  строго вдоль ForwardDir, а ForwardDir = (Cos(CurrentYawRad), 0,
  Sin(CurrentYawRad)) пишет SmoothRotateToDirection. Значит угол между
  соседними сегментами ТОЖДЕСТВЕННО равен приращению рысканья, и его
  можно взять из самого рысканья — без вычитания больших координат:
      curvature = yawRate / speed
  Рысканье живёт в [-Pi, Pi], там ulp float32 ~ 1e-7 при шаге ~1e-3 рад —
  шум ниже сигнала в тысячи раз. Знак сохранён: для D = (Cos a, 0, Sin a)
  SignedAngleXZ(D1, D2) даёт ровно (a2 - a1), так что прежние ветки знака
  (CurrentTurnAngleDeltaRad < 0 в CalculateTurnLeanAngle и здесь у
  CurrentLateralAccel) работают как раньше. Тем же путём идёт и
  ригид-боди вариант: он тоже ведёт CurrentYawRad через
  SmoothRotateToDirection.

  ВНИМАНИЕ, изменение амплитуды крена. В старом коде числителем был
  СРЕДНИЙ угол на ОДНУ пару сэмплов, а знаменателем — СУММАРНАЯ дуга по
  пяти сегментам, то есть кривизна занижалась впятеро. Теперь она
  честная, и в реальных поворотах наклон станет примерно в 5 раз больше
  прежнего (прежде это скрывалось за шумом). Ручка тюнинга —
  TurnLeanMultiplier в GamePhysicsCommon (сейчас 1.95, поверх и без того
  физически корректного atan(v^2/(R*g))). }
procedure TCustomActorPhysics.UpdateTrajectoryFromRealVelocity(const DeltaTime: Single);
const
  { Постоянная времени фильтра скорости рысканья. Соразмерна прежнему
    окну усреднения (7 сэмплов по 1/60 = 0.117 с), но без его лага:
    старый код брал 7 САМЫХ СТАРЫХ сэмплов из окна 0.2 с и вдобавок
    давал максимальный вес самому старому (Weights[I] := 1 - I/PointCount),
    из-за чего крен отставал от поворота примерно на 0.15 с. Фильтр здесь
    нужен только чтобы сгладить ступеньку на насыщении ограничителя
    MaxTurnSpeed; шума, ради которого раньше усредняли, больше нет. }
  YAW_RATE_SMOOTH_TIME = 0.10;
var
  RawVelocity: TVector3;
  RawSpeed: Single;
  YawDelta, YawRate, Alpha: Single;
begin
  if not Assigned(FState) then Exit;
  if DeltaTime <= 0 then Exit;

  { Скорость по-прежнему меряем по позициям: здесь важна только ДЛИНА
    вектора, а её потеря значимости портит на ~1% (против 100%+ у
    направления) — для v^2 в наклоне это несущественно. }
  RawVelocity := (FState.WorldPosition - FState.PrevWorldPosition) / DeltaTime;
  RawVelocity.Y := 0;
  RawSpeed := RawVelocity.Length;
  FState.RealVelocity := RawVelocity;

  { Кольцо траектории в расчёте кривизны больше не участвует, но
    наполняется: на непустой буфер рассчитывает InitializeAtStart, и по
    нему удобно смотреть фактический трек в отладке. }
  PushTrajectorySample(FState.WorldPosition, FState.SimulationTime);

  { ── Приращение рысканья за шаг ── }
  if not FYawRateValid then
  begin
    { Первый шаг после старта/возобновления — только привязка опоры,
      скорость рысканья ещё не определена. }
    FPrevYawRad := FState.CurrentYawRad;
    FSmoothedYawRateRad := 0;
    FYawRateValid := True;
  end;
  YawDelta := NormalizeAngleRad(FState.CurrentYawRad - FPrevYawRad);
  FPrevYawRad := FState.CurrentYawRad;

  if RawSpeed >= MinVelocityForTrajectory then
  begin
    YawRate := YawDelta / DeltaTime;
    Alpha := 1.0 - Exp(-DeltaTime / YAW_RATE_SMOOTH_TIME);
    FSmoothedYawRateRad := FSmoothedYawRateRad
      + (YawRate - FSmoothedYawRateRad) * Alpha;

    FState.CurrentYawRateRad := FSmoothedYawRateRad;
    { Прежняя семантика поля: угол поворота за ОДИН шаг. Знак — как у
      SignedAngleXZ раньше. }
    FState.CurrentTurnAngleDeltaRad := FSmoothedYawRateRad * DeltaTime;
    FState.CurrentCurvature := FSmoothedYawRateRad / RawSpeed;

    if Abs(FState.CurrentCurvature) > 0.00001 then
      FState.CurrentTurnRadius := 1.0 / Abs(FState.CurrentCurvature)
    else
      FState.CurrentTurnRadius := 0;

    if FState.CurrentTurnRadius > MaxMeaningfulTurnRadius then
    begin
      { Прямая. Теперь этот гейт работает по назначению: при чистой
        оценке на прямой yawRate ~ 0 и радиус реально уходит за порог. }
      FState.CurrentTurnRadius := 0;
      FState.CurrentCurvature := 0;
      FState.CurrentYawRateRad := 0;
      FState.CurrentLateralAccel := 0;
      FState.CurrentTurnAngleDeltaRad := 0;
    end
    else
    begin
      if FState.CurrentTurnRadius > 0.001 then
        FState.CurrentLateralAccel := Sqr(RawSpeed) / FState.CurrentTurnRadius
      else
        FState.CurrentLateralAccel := 0;

      if FState.CurrentTurnAngleDeltaRad < 0 then
        FState.CurrentLateralAccel := -FState.CurrentLateralAccel;
    end;
  end
  else
  begin
    FSmoothedYawRateRad := 0;
    FState.CurrentYawRateRad := 0;
    FState.CurrentLateralAccel := 0;
    FState.CurrentCurvature := 0;
    FState.CurrentTurnRadius := 0;
    FState.CurrentTurnAngleDeltaRad := 0;
  end;

  FState.PrevWorldPosition := FState.WorldPosition;
end;

function TCustomActorPhysics.CalculateTurnLeanAngle: Single;
var
  SpeedAbs: Single;
  RadiusAbs: Single;
  CentripetalForce: Single;
  LeanRad: Single;
begin
  Result := 0;
  if not Assigned(FState) then Exit;
  SpeedAbs := FState.RealVelocity.Length;
  RadiusAbs := Abs(FState.CurrentTurnRadius);

  if (SpeedAbs < MinVelocityForTrajectory) or (RadiusAbs < 0.001) then
    Exit;

  CentripetalForce := FState.AvatarMass * Sqr(SpeedAbs) / RadiusAbs;
  LeanRad := ArcTan2(Abs(CentripetalForce), FState.AvatarMass * Gravity);

  Result := RadToDeg(LeanRad) * TurnLeanMultiplier;

  if FState.CurrentTurnAngleDeltaRad < 0 then
    Result := -Result;

  if Result > MaxLeanAngle then Result := MaxLeanAngle;
  if Result < -MaxLeanAngle then Result := -MaxLeanAngle;
end;

function TCustomActorPhysics.CalculateTurnSpeedLimit: Single;
var
  MaxLatAcc: Single;
begin
  Result := 0;
  if not Assigned(FState) then Exit;
  Result := MaxSpeed;
  if Abs(FState.CurrentCurvature) < 0.00001 then Exit;

  MaxLatAcc := Gravity * MaxAllowedLateralAccelFactor;
  Result := Sqrt(MaxLatAcc / Abs(FState.CurrentCurvature)) * TurnSpeedSafety;

  if Result > MaxSpeed then Result := MaxSpeed;
  if Result < 1.5 then Result := 1.5;
end;

procedure TCustomActorPhysics.MeasureModelBounds;
var
  LocalBox: TBox3D;
  ModelLength, ModelHeightLocal: Single;
begin
  if not Assigned(FState) then Exit;
  FState.AvatarScale := 1.0;
  FState.ModelHalfLength := DefaultWheelbase / 2;
  FState.ScaledWheelRadius := BaseWheelRadius;
  FState.ScaledWheelInset := BaseWheelInset;
  FState.ModelLocalMinY := 0;
  FState.ModelHeight := 0;

  if Assigned(FActor) and Assigned(FActor.Transform) then
  begin
    FState.AvatarScale :=
      (FActor.Transform.Scale.X +
       FActor.Transform.Scale.Y +
       FActor.Transform.Scale.Z) / 3;
    if FState.AvatarScale < 0.01 then
      FState.AvatarScale := 1.0;
  end;

  if (not Assigned(FActor)) or (not Assigned(FActor.Scene)) then
  begin
    FState.ModelHalfLength := (DefaultWheelbase / 2) * FState.AvatarScale;
    FState.ScaledWheelRadius := BaseWheelRadius * FState.AvatarScale;
    FState.ScaledWheelInset := BaseWheelInset * FState.AvatarScale;
    FState.ModelHeight := 0;
    Exit;
  end;

  LocalBox := FActor.Scene.LocalBoundingBox;
  if FState.WheelContactAtOrigin then
  begin
    { Модель на колёсах в Y=0 своего кадра (TBikeInstance): длину/высоту
      берём из bbox как обычно, а опорную точку — ноль, bbox-минимум после
      переворота сцены смешанного кадра не годится. }
    FState.ModelLocalMinY := 0;
    if LocalBox.IsEmpty then
    begin
      FState.ModelHalfLength := (DefaultWheelbase / 2) * FState.AvatarScale;
      FState.ScaledWheelRadius := BaseWheelRadius * FState.AvatarScale;
      FState.ScaledWheelInset := BaseWheelInset * FState.AvatarScale;
      FState.ModelHeight := 0;
      Exit;
    end;
    ModelLength := LocalBox.Data[1].X - LocalBox.Data[0].X;
    if (LocalBox.Data[1].Z - LocalBox.Data[0].Z) > ModelLength then
      ModelLength := LocalBox.Data[1].Z - LocalBox.Data[0].Z;
    ModelHeightLocal := LocalBox.Data[1].Y - LocalBox.Data[0].Y;
    FState.ModelHalfLength := (ModelLength / 2) * FState.AvatarScale;
    FState.ScaledWheelRadius := BaseWheelRadius * FState.AvatarScale;
    FState.ScaledWheelInset := BaseWheelInset * FState.AvatarScale;
    FState.ModelHeight := ModelHeightLocal * FState.AvatarScale;
    Exit;
  end;
  if LocalBox.IsEmpty then
  begin
    FState.ModelHalfLength := (DefaultWheelbase / 2) * FState.AvatarScale;
    FState.ScaledWheelRadius := BaseWheelRadius * FState.AvatarScale;
    FState.ScaledWheelInset := BaseWheelInset * FState.AvatarScale;
    FState.ModelLocalMinY := 0;
    FState.ModelHeight := 0;
    Exit;
  end;

  ModelLength := LocalBox.Data[1].X - LocalBox.Data[0].X;
  if (LocalBox.Data[1].Z - LocalBox.Data[0].Z) > ModelLength then
    ModelLength := LocalBox.Data[1].Z - LocalBox.Data[0].Z;

  ModelHeightLocal := LocalBox.Data[1].Y - LocalBox.Data[0].Y;

  FState.ModelLocalMinY := LocalBox.Data[0].Y;
  FState.ModelHalfLength := (ModelLength / 2) * FState.AvatarScale;
  FState.ScaledWheelRadius := BaseWheelRadius * FState.AvatarScale;
  FState.ScaledWheelInset := BaseWheelInset * FState.AvatarScale;
  FState.ModelHeight := ModelHeightLocal * FState.AvatarScale;

  Logger.Info('[Physics] ' + Format(
    'MeasureModelBounds: LocalMinY=%.4f Scale=%.3f Offset=%.4f HalfLen=%.3f WheelR=%.3f Box=(%.3f..%.3f, %.3f..%.3f, %.3f..%.3f)',
    [FState.ModelLocalMinY, FState.AvatarScale,
     -FState.ModelLocalMinY * FState.AvatarScale,
     FState.ModelHalfLength, FState.ScaledWheelRadius,
     LocalBox.Data[0].X, LocalBox.Data[1].X,
     LocalBox.Data[0].Y, LocalBox.Data[1].Y,
     LocalBox.Data[0].Z, LocalBox.Data[1].Z]));
end;

procedure TCustomActorPhysics.SetWheelProbeHalfSpan(const AHalfSpanM: Single);
begin
  if (not Assigned(FState)) or (AHalfSpanM < 0.01) then Exit;
  { WheelOffset = ModelHalfLength - ScaledWheelInset → ровно AHalfSpanM:
    пробы земли оказываются точно под осями колёс, а не по bbox модели
    (который включает теневой catcher/rig). }
  FState.ModelHalfLength := AHalfSpanM + FState.ScaledWheelInset;
end;

procedure TCustomActorPhysics.ComputeGroundContactOffset;
var
  Box: TBox3D;
  LenX, LenZ, LongLen: Single;
  RayOrigin, RayDir: TVector3;
  Collision: TRayCollision;
  I: Integer;
  FrontSumY, RearSumY, CenterOther, TestPos, Step: Single;
  FrontHits, RearHits: Integer;
  FrontAvgY, RearAvgY: Single;
  LongIsX: Boolean;
const
  WheelZoneFrac = 0.15;
  SamplesPerWheel = 3;
begin
  FState.FrontWheelContactOffset := 0;
  FState.RearWheelContactOffset := 0;
  FState.GroundContactOffset := 0;
  if not Assigned(FActor) or not Assigned(FActor.Scene) then Exit;
  if FState.WheelContactAtOrigin then Exit;   { колёса в Y=0 кадра, лучевая
    подгонка по смешанному bbox не нужна }

  Box := FActor.Scene.LocalBoundingBox;
  if Box.IsEmpty then Exit;

  LenX := Box.Data[1].X - Box.Data[0].X;
  LenZ := Box.Data[1].Z - Box.Data[0].Z;
  LongIsX := LenX >= LenZ;
  if LongIsX then LongLen := LenX else LongLen := LenZ;
  if LongLen < 0.01 then Exit;

  RayDir := Vector3(0, 1, 0);
  FrontSumY := 0; FrontHits := 0;
  RearSumY := 0;  RearHits := 0;

  for I := 0 to SamplesPerWheel * 2 - 1 do
  begin
    if I < SamplesPerWheel then
      Step := WheelZoneFrac * (I + 0.5) / SamplesPerWheel
    else
      Step := 1.0 - WheelZoneFrac + WheelZoneFrac * ((I - SamplesPerWheel) + 0.5) / SamplesPerWheel;

    if LongIsX then
    begin
      TestPos := Box.Data[0].X + LenX * Step;
      CenterOther := (Box.Data[0].Z + Box.Data[1].Z) / 2;
      RayOrigin := Vector3(TestPos, Box.Data[0].Y - 0.01, CenterOther);
    end
    else
    begin
      TestPos := Box.Data[0].Z + LenZ * Step;
      CenterOther := (Box.Data[0].X + Box.Data[1].X) / 2;
      RayOrigin := Vector3(CenterOther, Box.Data[0].Y - 0.01, TestPos);
    end;

    Collision := FActor.Scene.InternalRayCollision(RayOrigin, RayDir);
    if Collision <> nil then
    begin
      if Collision.Count > 0 then
      begin
        if I < SamplesPerWheel then
        begin
          RearSumY := RearSumY + Collision.First.Point.Y;
          Inc(RearHits);
        end
        else
        begin
          FrontSumY := FrontSumY + Collision.First.Point.Y;
          Inc(FrontHits);
        end;
      end;
      FreeAndNil(Collision);
    end;
  end;

  if RearHits > 0 then
  begin
    RearAvgY := RearSumY / RearHits;
    FState.RearWheelContactOffset := (RearAvgY - Box.Data[0].Y) * FState.AvatarScale;
    if FState.RearWheelContactOffset < 0 then FState.RearWheelContactOffset := 0;
  end;

  if FrontHits > 0 then
  begin
    FrontAvgY := FrontSumY / FrontHits;
    FState.FrontWheelContactOffset := (FrontAvgY - Box.Data[0].Y) * FState.AvatarScale;
    if FState.FrontWheelContactOffset < 0 then FState.FrontWheelContactOffset := 0;
  end;

  FState.GroundContactOffset := (FState.FrontWheelContactOffset + FState.RearWheelContactOffset) / 2;

  Logger.Info('[Physics] ' + Format(
    'ComputeGroundContactOffset: front(hits=%d avgY=%.4f off=%.4f) rear(hits=%d avgY=%.4f off=%.4f) avg=%.4f bboxMinY=%.4f scale=%.3f',
    [FrontHits, FrontSumY / Max(FrontHits, 1), FState.FrontWheelContactOffset,
     RearHits, RearSumY / Max(RearHits, 1), FState.RearWheelContactOffset,
     FState.GroundContactOffset, Box.Data[0].Y, FState.AvatarScale]));
end;

function TCustomActorPhysics.IsOwnCollider(const T: TCastleTransform): Boolean;
begin
  Result := false;
  if T = nil then Exit;
  if T = FActor.Transform then Exit(true);
  if T = FActor.Scene then Exit(true);
  if Assigned(FDebug) then
  begin
    if T = FDebug.DebugSphereFrontWheel then Exit(true);
    if T = FDebug.DebugSphereRearWheel then Exit(true);
    if T = FDebug.DebugSphereFrontGround then Exit(true);
    if T = FDebug.DebugSphereRearGround then Exit(true);
  end;
end;

function TCustomActorPhysics.FindGroundHeightAt(const X, Z: Single): Single;
var
  Src: TGroundHitSource;
  Hit: Boolean;
begin
  Result := FindGroundHeightAt(X, Z, Src, Hit);
end;

function TCustomActorPhysics.FindGroundHeightAt(const X, Z: Single;
  out ASrc: TGroundHitSource; out AHit: Boolean): Single;
var
  RayOriginY: Single;
  RayResult: TRayCastResult;
  Attempts: Integer;
  QueryY: Single;
begin
  ASrc := ghsNone;
  AHit := False;
  Result := 0;
  if not Assigned(FState) then Exit;
  Result := FState.LastGroundY;
  if not Assigned(FActor) then Exit;

  { Стриминговая карта Osm3d: её тайлы не имеют коллизий, raycast по
    ним не сработает. Если назначен провайдер высоты — берём высоту
    НАПРЯМУЮ из рельефного меша тайла (барицентрика треугольников
    GroundField), БЕЗ PhysicsRayCast. False = тайл ещё не подгружен
    или точка вне GroundBin → hold LastGroundY. }
  if Assigned(FState.GroundQuery) then
  begin
    if FState.GroundQuery(X, Z, FState.LastGroundY, QueryY) then
    begin
      Result := QueryY;
      ASrc := ghsMeshQuery;
      AHit := True;
    end
    else
    begin
      ASrc := ghsHoldLast;
      AHit := False;
    end;
    Exit;
  end;

  if not Assigned(FActor.Viewport) then Exit;
  if not Assigned(FActor.Viewport.Items) then Exit;

  { Fallback: raycast only when GroundQuery is nil (non-streaming maps). }
  RayOriginY := FState.LastGroundY + 10;
  Attempts := 0;
  while Attempts < 3 do
  begin
    Inc(Attempts);
    RayResult := FActor.Viewport.Items.PhysicsRayCast(
      Vector3(X, RayOriginY, Z), Vector3(0, -1, 0), 30);

    if not RayResult.Hit then
    begin
      ASrc := ghsRayMiss;
      AHit := False;
      Exit;
    end;

    if IsOwnCollider(RayResult.Transform) then
    begin
      RayOriginY := RayOriginY - RayResult.Distance - 0.05;
      Continue;
    end;

    Result := RayOriginY - RayResult.Distance;
    ASrc := ghsRaycast;
    AHit := True;
    Exit;
  end;
  ASrc := ghsRayMiss;
  AHit := False;
end;

function TCustomActorPhysics.ApplyRouteLoadProfile: Boolean;
var Grade,Station,Height:Single;
begin
  Result:=(FState<>nil) and (FPath<>nil) and
    FPath.FitLoadAtPosition(FPath.Position,Grade,Station,Height);
  if not Result then Exit;
  { This is the complete load, not a correction clamped to the sign or
    amplitude of a rendered road facet. No GPU availability or elevation debt. }
  ResetSlopeTracking;
  FState.CurrentSlopeAngle:=RadToDeg(ArcTan(Grade*0.01));
  FState.CurrentSlopeCorrDeg:=0;
  FState.CurrentSlopeCorrValid:=False;
end;

procedure TCustomActorPhysics.ApplySmoothedFitSlope(const PitchDeg, DeltaTime: Single);
const
  RoadHalfSpanM = 6.0;
  CorrTauSec = 2.2;
  PendingHoldSec = 1.0;
  PendingHoldM = 6.0;
  FlatG = 1.0;
  AmpMaxK = 2.0;
  PayHorizonM = 50.0;
  DebtMaxM = 8.0;
var
  Dt, Ds, Alpha, Span, BackSpan, FrontSpan: Single;
  Ym0, Ym1, Yf0, Yf1: Single;
  WheelG, MeshG, TargetG, DesiredG, OutG: Single;
  Back, Ahead: TPathPosition;
  Center, P0, P1, Dir: TVector3;
  MeshHit0, MeshHit1, FitHit0, FitHit1: Boolean;

  function GradeToDeg(G: Single): Single;
  begin
    Result := RadToDeg(ArcTan(G * 0.01));
  end;

  function SignLockedGrade(const BaseG, Desired: Single): Single;
  var Limit, FlatAllowance: Single;
  begin
    Limit := BaseG * AmpMaxK;
    FlatAllowance := Max(0.0, FlatG - Abs(Limit));
    Result := EnsureRange(Desired, Min(0.0, Limit) - FlatAllowance,
      Max(0.0, Limit) + FlatAllowance);
  end;

  procedure Publish(const FitValid: Boolean);
  begin
    OutG := SignLockedGrade(MeshG, MeshG + FSlopeCorrSmooth);
    FState.CurrentSlopeAngle := EnsureRange(GradeToDeg(OutG), -30.0, 30.0);
    OutG := Tan(DegToRad(FState.CurrentSlopeAngle)) * 100.0;
    { HUD correction is FIT versus road, not wheel jitter. }
    FState.CurrentSlopeCorrDeg := FState.CurrentSlopeAngle - GradeToDeg(MeshG);
    FState.CurrentSlopeCorrValid := FitValid;
  end;

  procedure PendingCorrection;
  begin
    FFitSlopeMissSec := FFitSlopeMissSec + Dt;
    FFitSlopeMissM := FFitSlopeMissM + Ds;
    { A pending GPU patch is not an absent FIT layer. Neither restart the
      correction ramp nor forgive/add elevation debt on an unknown sample. }
    if (FFitSlopeMissSec > PendingHoldSec) or
       (FFitSlopeMissM > PendingHoldM) then
    begin
      FSlopeCorrSmooth := FSlopeCorrSmooth * (1.0 - Alpha);
      FElevDebtM := FElevDebtM * (1.0 - Alpha);
    end;
    Publish(Abs(FSlopeCorrSmooth) > 0.001);
  end;

begin
  if not Assigned(FState) then Exit;
  if ApplyRouteLoadProfile then Exit;
  Dt := EnsureRange(DeltaTime, 0.0, 0.25);
  if Dt <= 0 then Exit;
  Ds := Max(0.0, FState.CurrentSpeed) * Dt;
  Alpha := 1.0 - Exp(-Dt / CorrTauSec);
  WheelG := Tan(DegToRad(PitchDeg)) * 100.0;
  MeshG := WheelG;
  if not Assigned(FState.GroundQuery) then
  begin
    ResetSlopeTracking;
    FState.CurrentSlopeAngle := PitchDeg;
    FState.CurrentSlopeCorrDeg := 0;
    FState.CurrentSlopeCorrValid := False;
    Exit;
  end;

  { Fixed CENTRED baseline: a 7 cm road seam over the wheelbase used to
    change trainer grade by seven percentage points. A forward-only or
    speed-dependent baseline shifts crests and modulates load with speed. }
  { Two points define a straight road, not a cyclic out-and-back corner. }
  if (FPath <> nil) and (FPath.PointCount >= 3) then
  begin
    Center := FPath.RoadCenterAt(FPath.Position);
    Back := FPath.Position; Ahead := FPath.Position;
    FPath.AdvanceFollow(Back, -RoadHalfSpanM);
    FPath.AdvanceFollow(Ahead, RoadHalfSpanM);
    P0 := FPath.RoadCenterAt(Back); P1 := FPath.RoadCenterAt(Ahead);
    { Legacy open paths still wrap their cursor. Never sample a fictitious
      closing segment kilometres from an endpoint; use a one-sided span. }
    if DistanceXZ(Center, P0) > RoadHalfSpanM * 1.25 then P0 := Center;
    if DistanceXZ(Center, P1) > RoadHalfSpanM * 1.25 then P1 := Center;
  end
  else
  begin
    Center := FState.WorldPosition;
    Dir := NormalizeXZ(FState.ForwardDir);
    P0 := Center - Dir * RoadHalfSpanM;
    P1 := Center + Dir * RoadHalfSpanM;
  end;
  BackSpan := DistanceXZ(Center, P0);
  FrontSpan := DistanceXZ(Center, P1);
  Span := BackSpan + FrontSpan;
  MeshHit0 := False; MeshHit1 := False;
  if Span > 0.1 then
  begin
    { Queue BOTH endpoints. Predict Y to keep the same bridge/tunnel floor. }
    MeshHit0 := FState.GroundQuery(P0.X, P0.Z,
      FState.LastGroundY - WheelG * BackSpan * 0.01, Ym0);
    MeshHit1 := FState.GroundQuery(P1.X, P1.Z,
      FState.LastGroundY + WheelG * FrontSpan * 0.01, Ym1);
  end;
  if MeshHit0 and MeshHit1 then
  begin
    MeshG := (Ym1 - Ym0) / Span * 100.0;
    FRoadSlopeGrade := MeshG;
    FRoadSlopeValid := True;
    FRoadSlopeMissSec := 0; FRoadSlopeMissM := 0;
  end
  else
  begin
    FRoadSlopeMissSec := FRoadSlopeMissSec + Dt;
    FRoadSlopeMissM := FRoadSlopeMissM + Ds;
    if FRoadSlopeValid then
    begin
      if (FRoadSlopeMissSec > PendingHoldSec) or
         (FRoadSlopeMissM > PendingHoldM) then
        FRoadSlopeGrade := FRoadSlopeGrade + (WheelG - FRoadSlopeGrade) * Alpha;
      MeshG := FRoadSlopeGrade;
    end;
    if Assigned(FState.SlopeQuery) then PendingCorrection
    else begin FSlopeCorrSmooth := 0; FElevDebtM := 0; Publish(False) end;
    Exit;
  end;

  if not Assigned(FState.SlopeQuery) then
  begin
    FSlopeCorrSmooth := 0; FElevDebtM := 0;
    FFitSlopeMissSec := 0; FFitSlopeMissM := 0;
    Publish(False);
    Exit;
  end;
  FitHit0 := FState.SlopeQuery(P0.X, P0.Z, Ym0, Yf0);
  FitHit1 := FState.SlopeQuery(P1.X, P1.Z, Ym1, Yf1);
  if not (FitHit0 and FitHit1) then
  begin
    PendingCorrection;
    Exit;
  end;
  FFitSlopeMissSec := 0; FFitSlopeMissM := 0;
  TargetG := (Yf1 - Yf0) / Span * 100.0;
  DesiredG := SignLockedGrade(MeshG, TargetG + FElevDebtM / PayHorizonM * 100.0);
  FSlopeCorrSmooth := FSlopeCorrSmooth +
    (DesiredG - MeshG - FSlopeCorrSmooth) * Alpha;
  Publish(True);
  FElevDebtM := EnsureRange(FElevDebtM + (TargetG - OutG) * 0.01 * Ds,
    -DebtMaxM, DebtMaxM);
end;


procedure TCustomActorPhysics.UpdateDebugSpheres(const FrontWheelPos, RearWheelPos,
  FrontGroundPos, RearGroundPos: TVector3);
begin
  if Assigned(FDebug.DebugSphereFrontWheel) then
    FDebug.DebugSphereFrontWheel.Translation := FrontWheelPos;
  if Assigned(FDebug.DebugSphereRearWheel) then
    FDebug.DebugSphereRearWheel.Translation := RearWheelPos;
  if Assigned(FDebug.DebugSphereFrontGround) then
    FDebug.DebugSphereFrontGround.Translation := FrontGroundPos;
  if Assigned(FDebug.DebugSphereRearGround) then
    FDebug.DebugSphereRearGround.Translation := RearGroundPos;
end;

function TCustomActorPhysics.PlaceActorByWheels(const CenterXZ: TVector3; const Dir: TVector3; const FixedDelta: Single): Single;
var
  WheelOffset: Single;
  FrontX, FrontZ, RearX, RearZ: Single;
  FrontGroundY, RearGroundY, AvgGroundY: Single;
  FrontWheelPos, RearWheelPos: TVector3;
  FrontGroundPos, RearGroundPos: TVector3;
  AvatarY: Single;
  Wheelbase, DeltaY: Single;
  SmoothAlpha: Single;
  FSrc, RSrc: TGroundHitSource;
  FHit, RHit: Boolean;
  PrevSmooth: Single;
const
  GroundSmoothTime = 0.015;
begin
  if not Assigned(FState) then begin Result := 0; Exit; end;

  Result := 0;
  WheelOffset := FState.ModelHalfLength - FState.ScaledWheelInset;
  if WheelOffset < 0.1 then
    WheelOffset := 0.1;

  FrontX := CenterXZ.X + Dir.X * WheelOffset;
  FrontZ := CenterXZ.Z + Dir.Z * WheelOffset;
  RearX := CenterXZ.X - Dir.X * WheelOffset;
  RearZ := CenterXZ.Z - Dir.Z * WheelOffset;

  FrontGroundY := FindGroundHeightAt(FrontX, FrontZ, FSrc, FHit);
  FState.FrontGroundPoint := Vector3(FrontX,FrontGroundY,FrontZ);
  FState.FrontGroundPointValid := FHit;
  RearGroundY := FindGroundHeightAt(RearX, RearZ, RSrc, RHit);
  FState.RearGroundPoint := Vector3(RearX,RearGroundY,RearZ);
  FState.RearGroundPointValid := RHit;
  AvgGroundY := ((FrontGroundY - FState.FrontWheelContactOffset)
              +  (RearGroundY  - FState.RearWheelContactOffset)) / 2;

  if Assigned(FState.GroundQuery) and not (FHit and RHit) then
  begin
    { A known start height is a display seed, not a measured ground plane. }
    FSmoothedGroundYValid := False;
    if Assigned(FActor.Transform) then
      FActor.Transform.Translation := Vector3(CenterXZ.X,
        FState.LastGroundY - FState.ModelLocalMinY * FState.AvatarScale, CenterXZ.Z);
    Exit;
  end;

  PrevSmooth := FSmoothedGroundY;
  if FState.WheelContactAtOrigin or not FSmoothedGroundYValid then
  begin
    FSmoothedGroundY := AvgGroundY;
    FSmoothedGroundYValid := true;
  end
  else
  begin
    SmoothAlpha := 1.0 - Exp(-FixedDelta / GroundSmoothTime);
    FSmoothedGroundY := FSmoothedGroundY + (AvgGroundY - FSmoothedGroundY) * SmoothAlpha;
  end;

  FGroundProbePosition := CenterXZ;
  FGroundGradient := Dir * (((FrontGroundY - FState.FrontWheelContactOffset) -
    (RearGroundY - FState.RearWheelContactOffset)) / (WheelOffset * 2));
  FGroundGradient.Y := 0;
  FState.LastGroundY := FSmoothedGroundY;

  FrontGroundPos := Vector3(FrontX, FrontGroundY, FrontZ);
  RearGroundPos := Vector3(RearX, RearGroundY, RearZ);
  FrontWheelPos := Vector3(FrontX,
    FrontGroundY - FState.FrontWheelContactOffset + FState.ScaledWheelRadius, FrontZ);
  RearWheelPos := Vector3(RearX,
    RearGroundY - FState.RearWheelContactOffset + FState.ScaledWheelRadius, RearZ);

  UpdateDebugSpheres(FrontWheelPos, RearWheelPos, FrontGroundPos, RearGroundPos);

  AvatarY := FSmoothedGroundY - FState.ModelLocalMinY * FState.AvatarScale;
  if Assigned(FActor.Transform) then
    FActor.Transform.Translation := Vector3(CenterXZ.X, AvatarY, CenterXZ.Z);

  if PhysicsGroundLogActive then
    PhysicsGroundLogLine(Format(
      '%d,%.3f,place,%d,' +
      '%.3f,%.3f,%.4f,%s,%d,%.3f,%.3f,%.4f,%s,%d,' +
      '%.4f,%.4f,%.4f,%.2f,%.4f,%.4f,' +
      '%.3f,%.4f,%.3f,%.3f,%.4f,%.3f,' +
      '%.4f,%.4f,%.4f,%.3f,%.3f',
      [GetTickCount64, FState.SimulationTime,
       Ord(Assigned(FState.GroundQuery)),
       FrontX, FrontZ, FrontGroundY, GroundHitSourceName(FSrc), Ord(FHit),
       RearX, RearZ, RearGroundY, GroundHitSourceName(RSrc), Ord(RHit),
       AvgGroundY, FSmoothedGroundY, AvatarY, FState.CumulativeDistance,
       FrontGroundY - RearGroundY, FSmoothedGroundY - PrevSmooth,
       FrontWheelPos.X, FrontWheelPos.Y, FrontWheelPos.Z,
       RearWheelPos.X, RearWheelPos.Y, RearWheelPos.Z,
       FState.FrontWheelContactOffset, FState.RearWheelContactOffset,
       FState.ScaledWheelRadius, CenterXZ.X, CenterXZ.Z]));

  Wheelbase := WheelOffset * 2;
  DeltaY := (FrontGroundY - FState.FrontWheelContactOffset)
          - (RearGroundY  - FState.RearWheelContactOffset);
  if Wheelbase > 0.01 then
    Result := RadToDeg(ArcTan2(DeltaY, Wheelbase));

  if Result > 30 then Result := 30;
  if Result < -30 then Result := -30;
end;

procedure TCustomActorPhysics.UpdateVisualGroundProbes(const DeltaTime: Single);
var
  WheelOffset: Single;
  Pos: TVector3;
  FrontX, FrontZ, RearX, RearZ: Single;
  FrontGroundY, RearGroundY, AvgGroundY: Single;
  FrontWheelPos, RearWheelPos: TVector3;
  FrontGroundPos, RearGroundPos: TVector3;
  AvatarY: Single;
  Wheelbase, DeltaY, Pitch: Single;
  SmoothAlpha: Single;
  ShSideX, ShSideZ, ShLX, ShLZ, ShRX, ShRZ, ShLeftY, ShRightY: Single;
  ShFX, ShFZ, ShBX, ShBZ, ShFrontY, ShBackY: Single;
  ShCX, ShCZ, ShCenterY: Single;
  ShVFR, ShVLR, ShNrm: TVector3;
  FSrc, RSrc: TGroundHitSource;
  FHit, RHit: Boolean;
  PrevSmooth: Single;
  PredictedY, GradientScale: Single;
const
  GroundSmoothTime = 0.015;
  ShadowFitSpan = 1.8;   { metres; fit the shadow ground plane over ~the quad
                           footprint (a low sun stretches the shadow ~2 m) so
                           the tilted quad corners track terrain, not sink }
begin
  if not Assigned(FState) then Exit;
  if not Assigned(FActor) then Exit;
  if not Assigned(FActor.Transform) then Exit;

  { plMinimal — no ground raycast at all, Y stays as-is }
  if FState.PhysicsLOD = plMinimal then Exit;

  Pos := FActor.Transform.Translation;
  FSrc := ghsNone; RSrc := ghsNone;
  FHit := False; RHit := False;
  PrevSmooth := FSmoothedGroundY;
  PredictedY := GroundHeightAtPosition(Pos);

  WheelOffset := FState.ModelHalfLength - FState.ScaledWheelInset;
  if WheelOffset < 0.1 then
    WheelOffset := 0.1;

  FrontX := Pos.X + FState.ForwardDir.X * WheelOffset;
  FrontZ := Pos.Z + FState.ForwardDir.Z * WheelOffset;
  RearX := Pos.X - FState.ForwardDir.X * WheelOffset;
  RearZ := Pos.Z - FState.ForwardDir.Z * WheelOffset;

  { Sources filled for ground-log (mesh vs ray vs hold). }
  FrontGroundY := FindGroundHeightAt(FrontX, FrontZ, FSrc, FHit);
  FState.FrontGroundPoint := Vector3(FrontX,FrontGroundY,FrontZ);
  FState.FrontGroundPointValid := FHit;
  RearGroundY := FindGroundHeightAt(RearX, RearZ, RSrc, RHit);
  FState.RearGroundPoint := Vector3(RearX,RearGroundY,RearZ);
  FState.RearGroundPointValid := RHit;
  { A missing tile is not a flat road or a fresh sample. Hold the previous
    plane until BOTH wheel queries are valid. }
  if not (FHit and RHit) then Exit;

  { --- Ground-plane normal for the contact shadow. ---
    The shadow is off to one side under a low sun, and it spans well beyond the
    wheelbase, so fit the plane under the SHADOW (bike + ShadowCenterOffset)
    over ~its footprint, not under the bike. Samples: the shadow centre, plus
    front/back and left/right of it. All via the same wheel ground query.
    Пропускаем целиком, когда тень скрыта/выключена/дальше shadow-LOD
    (ShadowPlaneWanted=False) — 5 проб земли на кадр впустую. }
  if FState.ShadowPlaneWanted then
  begin
    ShCX := Pos.X + FState.ShadowCenterOffset.X;   { shadow centre in world XZ }
    ShCZ := Pos.Z + FState.ShadowCenterOffset.Z;
    ShSideX := -FState.ForwardDir.Z;   { perpendicular to forward, in ground plane }
    ShSideZ :=  FState.ForwardDir.X;
    ShLX := ShCX + ShSideX * ShadowFitSpan;  ShLZ := ShCZ + ShSideZ * ShadowFitSpan;
    ShRX := ShCX - ShSideX * ShadowFitSpan;  ShRZ := ShCZ - ShSideZ * ShadowFitSpan;
    ShLeftY  := FindGroundHeightAt(ShLX, ShLZ);
    ShRightY := FindGroundHeightAt(ShRX, ShRZ);
    ShFX := ShCX + FState.ForwardDir.X * ShadowFitSpan;
    ShFZ := ShCZ + FState.ForwardDir.Z * ShadowFitSpan;
    ShBX := ShCX - FState.ForwardDir.X * ShadowFitSpan;
    ShBZ := ShCZ - FState.ForwardDir.Z * ShadowFitSpan;
    ShFrontY := FindGroundHeightAt(ShFX, ShFZ);
    ShBackY  := FindGroundHeightAt(ShBX, ShBZ);
    { centre sample — nudges the plane to pass through the shadow centre height,
      so a bump right under the shadow middle is accounted for, not just the rim }
    ShCenterY := FindGroundHeightAt(ShCX, ShCZ);
    ShVFR := Vector3(ShFX - ShBX, ShFrontY - ShBackY, ShFZ - ShBZ);
    ShVLR := Vector3(ShLX - ShRX, ShLeftY - ShRightY, ShLZ - ShRZ);
    ShNrm := TVector3.CrossProduct(ShVFR, ShVLR);
    if ShNrm.Length > 1e-6 then
    begin
      ShNrm := ShNrm.Normalize;
      if ShNrm.Y < 0 then ShNrm := -ShNrm;
      FState.ShadowGroundNormal := ShNrm;
      FState.ShadowGroundNormalValid := True;
    end;
  end;

  AvgGroundY := ((FrontGroundY - FState.FrontWheelContactOffset)
              +  (RearGroundY  - FState.RearWheelContactOffset)) / 2;

  if FState.WheelContactAtOrigin or not FSmoothedGroundYValid then
  begin
    FSmoothedGroundY := AvgGroundY;
    FSmoothedGroundYValid := true;
  end
  else
  begin
    SmoothAlpha := 1.0 - Exp(-DeltaTime / GroundSmoothTime);
    FSmoothedGroundY := PredictedY + (AvgGroundY - PredictedY) * SmoothAlpha;
  end;

  if AvgGroundY > FSmoothedGroundY then
    FSmoothedGroundY := AvgGroundY;

  FGroundProbePosition := Pos;
  GradientScale := ((FrontGroundY - FState.FrontWheelContactOffset) -
    (RearGroundY - FState.RearWheelContactOffset)) / (WheelOffset * 2);
  FGroundGradient := FState.ForwardDir * GradientScale;
  FGroundGradient.Y := 0;

  FState.LastGroundY := FSmoothedGroundY;

  if PhysicsGroundLogActive then
  begin
    AvatarY := FSmoothedGroundY - FState.ModelLocalMinY * FState.AvatarScale;
    FrontWheelPos := Vector3(FrontX,
      FrontGroundY - FState.FrontWheelContactOffset + FState.ScaledWheelRadius, FrontZ);
    RearWheelPos := Vector3(RearX,
      RearGroundY - FState.RearWheelContactOffset + FState.ScaledWheelRadius, RearZ);
    PhysicsGroundLogLine(Format(
      '%d,%.3f,visual,%d,' +
      '%.3f,%.3f,%.4f,%s,%d,%.3f,%.3f,%.4f,%s,%d,' +
      '%.4f,%.4f,%.4f,%.2f,%.4f,%.4f,' +
      '%.3f,%.4f,%.3f,%.3f,%.4f,%.3f,' +
      '%.4f,%.4f,%.4f,%.3f,%.3f',
      [GetTickCount64, FState.SimulationTime,
       Ord(Assigned(FState.GroundQuery)),
       FrontX, FrontZ, FrontGroundY, GroundHitSourceName(FSrc), Ord(FHit),
       RearX, RearZ, RearGroundY, GroundHitSourceName(RSrc), Ord(RHit),
       AvgGroundY, FSmoothedGroundY, AvatarY, FState.CumulativeDistance,
       FrontGroundY - RearGroundY, FSmoothedGroundY - PrevSmooth,
       FrontWheelPos.X, FrontWheelPos.Y, FrontWheelPos.Z,
       RearWheelPos.X, RearWheelPos.Y, RearWheelPos.Z,
       FState.FrontWheelContactOffset, FState.RearWheelContactOffset,
       FState.ScaledWheelRadius, Pos.X, Pos.Z]));
  end;

  { Debug spheres — only at plFull }
  if FState.PhysicsLOD = plFull then
  begin
    FrontGroundPos := Vector3(FrontX, FrontGroundY, FrontZ);
    RearGroundPos := Vector3(RearX, RearGroundY, RearZ);
    FrontWheelPos := Vector3(FrontX,
      FrontGroundY - FState.FrontWheelContactOffset + FState.ScaledWheelRadius, FrontZ);
    RearWheelPos := Vector3(RearX,
      RearGroundY - FState.RearWheelContactOffset + FState.ScaledWheelRadius, RearZ);
    UpdateDebugSpheres(FrontWheelPos, RearWheelPos, FrontGroundPos, RearGroundPos);
  end;

  { Slope for CalculateAcceleration — computed at all LOD levels }
  Wheelbase := WheelOffset * 2;
  DeltaY := (FrontGroundY - FState.FrontWheelContactOffset)
          - (RearGroundY  - FState.RearWheelContactOffset);
  Pitch := 0;
  if Wheelbase > 0.01 then
    Pitch := RadToDeg(ArcTan2(DeltaY, Wheelbase));
  if Pitch > 30 then Pitch := 30;
  if Pitch < -30 then Pitch := -30;
  FState.CurrentGroundPitch := Pitch;
  { Keep contact pitch for the bicycle. Gravity/trainer use the road profile. }
  ApplySmoothedFitSlope(Pitch, DeltaTime);
end;

procedure TCustomActorPhysics.ApplyVisualGroundPlacement(const DeltaTime: Single);
var
  Pos: TVector3;
  AvatarY: Single;
begin
  if not Assigned(FState) then Exit;
  if not Assigned(FActor) then Exit;
  if not Assigned(FActor.Transform) then Exit;
  if FState.PhysicsLOD = plMinimal then Exit;
  if not FSmoothedGroundYValid then Exit;   { до первого прогона проб }

  { Y применяем КАЖДЫЙ кадр из сглаженного кэша: RestorePhysicsPosition в
    агенте ежекадрно откатывает Transform к сохранённой позиции, где Y
    протухший (probes бегут на 30 Гц) — без переприменения визуального Y
    модель дёргается и тонет (колёса уходили под землю, экран моргал). }
  Pos := FActor.Transform.Translation;

  AvatarY := GroundHeightAtPosition(Pos);
  AvatarY := AvatarY - FState.ModelLocalMinY * FState.AvatarScale;

  FActor.Transform.Translation := Vector3(Pos.X, AvatarY, Pos.Z);
  FState.WorldPosition.Y := GroundHeightAtPosition(FState.WorldPosition)
    - FState.ModelLocalMinY * FState.AvatarScale;

  { Pitch / Roll / Rotation — only at plFull }
  if FState.PhysicsLOD = plFull then
  begin
    UpdateModelPitch(DeltaTime);
    UpdateModelRoll(DeltaTime);
    ApplyModelRotation;
  end
  else
  begin
    { At plReduced: simple pitch, no lean }
    FState.CurrentModelPitch := FState.CurrentGroundPitch;
    FState.CurrentTurnAngle := 0;
    ApplyModelRotation;
  end;
end;

procedure TCustomActorPhysics.InvalidateGroundPlacement;
begin
  FSmoothedGroundYValid := False;
  FGroundGradient := Vector3(0, 0, 0);
  FGroundWaitSec := 0;
end;

procedure TCustomActorPhysics.ResetTrackingAfterTeleport;
begin
  if Assigned(FPath) then FPath.ResetTurnaround;
  InvalidateGroundPlacement;
  FYawRateValid := False;
  FSmoothedYawRateRad := 0;
  ResetSlopeTracking;
  FState.CurrentCurvature := 0;
  FState.CurrentYawRateRad := 0;
  FState.CurrentLateralAccel := 0;
  FState.CurrentTurnAngle := 0;
  FState.TargetTurnAngle := 0;
end;

function TCustomActorPhysics.GroundHeightAtPosition(const Pos: TVector3): Single;
var
  Delta: TVector3;
  D: Single;
begin
  Delta := Pos - FGroundProbePosition;
  Delta.Y := 0;
  D := Delta.Length;
  { Bound stale samples spatially, without snapping back to their base Y. }
  if D > GroundPlaneRadius then Delta := Delta * (GroundPlaneRadius / D);
  Result := FSmoothedGroundY + Delta.X * FGroundGradient.X + Delta.Z * FGroundGradient.Z;
end;

function TCustomActorPhysics.ConstrainGroundMovement(
  const Position, Movement: TVector3): TVector3;
var DX,DZ,MX,MZ,A,B,C,T,EndX,EndZ:Double;
begin
  Result := Movement;
  if not Assigned(FState.GroundQuery) or (FState.PhysicsLOD = plMinimal) then Exit;
  Result := Vector3(0,0,0);
  if not FSmoothedGroundYValid then Exit;
  DX := Double(Position.X) - FGroundProbePosition.X;
  DZ := Double(Position.Z) - FGroundProbePosition.Z;
  MX := Movement.X; MZ := Movement.Z;
  C := DX*DX + DZ*DZ - Sqr(GroundPlaneRadius);
  { A teleport/correction outside the lease must acquire a new plane;
    never move or snap back toward an obsolete ground sample. }
  if C > 0.00001 then Exit;
  EndX := DX+MX; EndZ := DZ+MZ;
  if EndX*EndX + EndZ*EndZ <= Sqr(GroundPlaneRadius) then
    Exit(Movement);
  A := MX*MX + MZ*MZ;
  if A <= 1e-18 then Exit;
  B := DX*MX + DZ*MZ;
  T := EnsureRange((-B + Sqrt(Max(0.0,B*B-A*C)))/A,0.0,1.0);
  { Leave a tiny inward margin for single-precision world coordinates. }
  Result := Movement * (T * 0.9999);
end;

procedure TCustomActorPhysics.UpdateVisualDebug;
var
  Pos, Front, Rear: TVector3;
  Offset: Single;
begin
  if not Assigned(FDebug) or not FDebug.DebugSpheresVisible then Exit;
  if not Assigned(FActor.Transform) or not FSmoothedGroundYValid then Exit;
  Pos := FActor.Transform.Translation;
  Offset := Max(0.1, FState.ModelHalfLength - FState.ScaledWheelInset);
  Front := Pos + FState.ForwardDir * Offset;
  Rear := Pos - FState.ForwardDir * Offset;
  Front.Y := GroundHeightAtPosition(Front) + FState.ScaledWheelRadius;
  Rear.Y := GroundHeightAtPosition(Rear) + FState.ScaledWheelRadius;
  if Assigned(FDebug.DebugSphereFrontWheel) then FDebug.DebugSphereFrontWheel.Translation := Front;
  if Assigned(FDebug.DebugSphereRearWheel) then FDebug.DebugSphereRearWheel.Translation := Rear;
  { Ground spheres deliberately remain the RAW samples, at probe frequency. }
end;

procedure TCustomActorPhysics.UpdateVisualGroundPlacement(const DeltaTime: Single);
begin
  UpdateVisualGroundProbes(DeltaTime);
  ApplyVisualGroundPlacement(DeltaTime);
end;

procedure TCustomActorPhysics.UpdateModelPitch(DeltaTime: Single);
var
  Diff, MaxChange: Single;
begin
  if not Assigned(FState) then Exit;
  FState.TargetModelPitch := FState.CurrentGroundPitch;
  if FState.WheelContactAtOrigin then begin
    { Height and pitch describe the SAME pair of tyre contacts. Filtering
      pitch independently leaves one wheel below the road and the other
      hanging in the air. Rider/body damping remains in body dynamics. }
    FState.CurrentModelPitch:=FState.TargetModelPitch;
    Exit;
  end;
  MaxChange := PitchSmoothness * DeltaTime;
  Diff := FState.TargetModelPitch - FState.CurrentModelPitch;

  if Abs(Diff) <= MaxChange then
    FState.CurrentModelPitch := FState.TargetModelPitch
  else if Diff > 0 then
    FState.CurrentModelPitch := FState.CurrentModelPitch + MaxChange
  else
    FState.CurrentModelPitch := FState.CurrentModelPitch - MaxChange;
end;

procedure TCustomActorPhysics.UpdateModelRoll(DeltaTime: Single);
var
  Diff, MaxChange: Single;
begin
  if not Assigned(FState) then Exit;
  if Assigned(FActor) and FActor.RiderOwnsLean then Exit;
  FState.TargetTurnAngle := CalculateTurnLeanAngle;
  MaxChange := RollSmoothness * DeltaTime;
  Diff := FState.TargetTurnAngle - FState.CurrentTurnAngle;

  if Abs(Diff) <= MaxChange then
    FState.CurrentTurnAngle := FState.TargetTurnAngle
  else if Diff > 0 then
    FState.CurrentTurnAngle := FState.CurrentTurnAngle + MaxChange
  else
    FState.CurrentTurnAngle := FState.CurrentTurnAngle - MaxChange;
end;

procedure TCustomActorPhysics.ApplyModelRotation;
var
  PitchRad, RollRad: Single;
  BaseRotation, PitchRotation, RollRotation, FinalRotation: TQuaternion;
  AxisAngle: TVector4;
begin
  if not Assigned(FState) then Exit;
  if not Assigned(FActor.Scene) then Exit;

  BaseRotation := QuatFromAxisAngle(Vector3(0, 1, 0), ModelBaseYRotation);
  PitchRad := DegToRad(-FState.CurrentModelPitch);
  RollRad := DegToRad(FState.CurrentTurnAngle);
  if FActor.RiderOwnsLean then RollRad:=0;

  PitchRotation := QuatFromAxisAngle(Vector3(1, 0, 0), PitchRad);
  RollRotation := QuatFromAxisAngle(Vector3(0, 0, 1), RollRad);

  FinalRotation := RollRotation * PitchRotation * BaseRotation;
  AxisAngle := FinalRotation.ToAxisAngle;
  FActor.Scene.Rotation := AxisAngle;
end;

function TCustomActorPhysics.CalculateAcceleration(const DeltaTime:Single): Single;
var
  Curv: Single;
  SpeedLim: Single;
  BrakeForceN: Single;
begin
  if not Assigned(FState) then begin Result := 0; Exit; end;
  { Preserve the road-scale grade with or without FIT. Contact pitch is
    only a fallback until a separate road profile has become available. }
  if not ApplyRouteLoadProfile and not Assigned(FState.SlopeQuery) and not FRoadSlopeValid then
    FState.CurrentSlopeAngle := FState.CurrentGroundPitch;

  { At plFull LOD: include turn forces; at plReduced/plMinimal: straight line }
  if FState.PhysicsLOD = plFull then
  begin
    Curv := FState.CurrentCurvature;
    SpeedLim := CalculateTurnSpeedLimit;
  end
  else
  begin
    Curv := 0;
    SpeedLim := MaxSpeed;
  end;

  BrakeForceN := 0;
  if FControlInput <> nil then BrakeForceN := FControlInput^.BrakeForceN;
  Result := ComputeCyclingAcceleration(
    FState.AppliedPowerWatts,
    FState.CurrentSpeed,
    FState.AvatarMass,
    FState.DragCoefficient,
    FState.FrontalArea,
    FState.RollingResistance,
    FState.CurrentSlopeAngle,
    DeltaTime,
    Curv,
    SpeedLim,
    BrakeForceN);
end;

function TCustomActorPhysics.UpdateRouteTurnaround(const DeltaTime: Single): Boolean;
var TargetDir: TVector3;
begin
  Result:=FPath.TryTurnaround(FState.WorldPosition,FState.ForwardDir,TargetDir);
  if not Result then Exit;
  FState.CurrentSpeed:=0;
  FState.MovementVelocity:=Vector3(0,0,0);
  FState.LaneOffset:=0;
  { Heading interpolation of antiparallel vectors cannot rotate through
    180 degrees. Use the existing bounded angular turn, with no translation. }
  SmoothRotateToDirection(TargetDir,DeltaTime);
  if TVector3.DotProduct(FState.ForwardDir,TargetDir)>0.9999 then
    FPath.FinishTurnaround;
  UpdateTrajectoryFromRealVelocity(DeltaTime);
end;

procedure TCustomActorPhysics.SmoothRotateToDirection(const TargetDir: TVector3; DeltaTime: Single);
var
  CurrentAngle, TargetAngle, DeltaAngle, StepAngle, NewAngle: Single;
  NewDirection: TVector3;
begin
  if not Assigned(FState) then Exit;
  if not Assigned(FActor.Transform) then Exit;
  if TargetDir.Length < 0.001 then Exit;

  CurrentAngle := FState.CurrentYawRad;
  TargetAngle := ArcTan2(TargetDir.Z, TargetDir.X);
  DeltaAngle := NormalizeAngleRad(TargetAngle - CurrentAngle);

  StepAngle := MaxTurnSpeed * DeltaTime;
  if DeltaAngle > StepAngle then
    DeltaAngle := StepAngle
  else if DeltaAngle < -StepAngle then
    DeltaAngle := -StepAngle;

  NewAngle := CurrentAngle + DeltaAngle;
  NewDirection := Vector3(Cos(NewAngle), 0, Sin(NewAngle));
  { Turning a stopped bicycle can also intersect its neighbour. Accept the
    complete physical heading before publishing it to state or the model;
    the following displacement is swept along this same accepted heading. }
  if Assigned(FState.TrafficHeadingConstraint) then
  begin
    NewDirection := FState.TrafficHeadingConstraint(FState.TrafficTag,
      FState.WorldPosition, FState.ForwardDir, NewDirection, True);
    NewAngle := CurrentAngle + NormalizeAngleRad(
      ArcTan2(NewDirection.Z, NewDirection.X) - CurrentAngle);
  end;
  FState.CurrentYawRad := NewAngle;
  FState.ForwardDir := NewDirection;
  FActor.Transform.Direction := FState.ForwardDir;
end;

end.
