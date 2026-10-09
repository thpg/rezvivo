unit GamePhysicsKinematic;

interface

uses
  Math, GamePhysicsBase, GamePhysicsCommon;

type
  TKinematicActorPhysics = class(TCustomActorPhysics)
  private
    FTraceFrameNum: Cardinal;
    FDiagFrames: Cardinal;     { счётчик кадров для разовой диагностики FixedStep }
    { Обновить отладочные линии разметки/центра/края по ТЕКУЩЕЙ ширине
      дороги (FState.CurrentRoadWidth). Линии длиной 3 м, ориентированы
      вдоль движения, привязаны к осевой пути → едут вместе с
      велосипедом. No-op, когда отладка выключена. }
    procedure UpdateRoadDebugLines;
    procedure FreeTravelStep(const Dt: Single);
  public
    procedure Initialize; override;
    procedure FixedStep(const FixedDelta: Single); override;
    procedure UpdateVisualDebug; override;
    function Mode: TPhysicsMode; override;
  end;

implementation

uses
  SysUtils, CastleVectors, CastleScene, GamePath, GameProfiler, DebugLog,
  GameMath;     { DistanceXZ — was FPath.DistanceXZ before migration }

const
  { Полосное смещение райдера как доля ПОЛУШИРИНЫ дороги.
      0.0  — ехать ровно по треку (как его поставил снаппер маршрута);
      > 0  — смещение вправо от осевой (правостороннее движение);
      < 0  — влево.
    Итоговое боковое смещение = RoadWidth * 0.5 * LANE_OFFSET_FACTOR,
    поэтому на широкой дороге райдер отступает от центра дальше, на
    узкой — меньше; масштабируется шириной автоматически.
    Снаппер уже подвинул трек широких дорог к полосе, так что это —
    тонкая подстройка; держите |фактор| небольшим (0.3..0.6), иначе
    райдер уедет за край. На тропинках (ширина <=
    PATH_SINGLE_FILE_WIDTH_M из GamePhysicsCommon) смещение дополнительно
    гасится LaneCenterFactor'ом до нуля — по узкой дорожке едем по
    центру. Вынести в AppSettings для подстройки из UI —
    отдельный шаг. }
  LANE_OFFSET_FACTOR = 0.45;

  { Ширина одной полосы, по которой ОТЛАДКА делит дорогу на разметку.
    Это чисто визуальное допущение для линий разметки: в самой физике
    одиночного аватара счётчика полос нет, поэтому число разделителей
    выводится как round(ШиринаДороги / DEBUG_LANE_WIDTH_M). Сама ширина
    дороги берётся текущей (FState.CurrentRoadWidth), отдельно не
    пересчитывается. }
  DEBUG_LANE_WIDTH_M = 3.5;

  { Запасная ширина дороги для ОТЛАДОЧНЫХ линий, когда текущая ширина = 0
    (например, велосипедист едет по сырому FIT-треку без снапнутых ширин —
    тогда RoadWidthAt = 0). Реальная текущая ширина используется всегда,
    когда она > 0; этот фолбэк только чтобы линии были видны на участках
    без ширины. }
  DEBUG_FALLBACK_ROAD_WIDTH_M = 6.0;

  { Подъём отладочных линий над поверхностью дороги (метры) — чтобы не
    тонули в полотне. }
  DEBUG_LINE_LIFT_M = 0.4;

  { GPU readback / a patch change is not a collision. Retain momentum during
    a short wait, but do not accelerate in place or carry it through a long
    missing-tile stall. This is simulated time, including accelerated FIT. }
  GroundMomentumHoldSeconds = 0.5;

procedure TKinematicActorPhysics.Initialize;
begin
  inherited;
  FTraceFrameNum := 0;
  FDiagFrames := 0;
  if Assigned(FActor) and Assigned(FActor.RigidBody) then
    FActor.RigidBody.Exists := false;
end;

procedure TKinematicActorPhysics.FreeTravelStep(const Dt: Single);
var Wanted, Safe, Dir: TVector3;
  Turn, Accel, OldSpeed, LengthBefore, StepDistance: Single;
begin
  if Dt<=0 then Exit;
  ApplyControlInput;
  if not FState.AutoMove then Exit;
  if Assigned(FState.GroundQuery) and not GroundPlacementValid then begin
    FState.CurrentSpeed:=0;FState.MovementVelocity:=Vector3(0,0,0);Exit;
  end;
  CaptureCameraRelativeState;
  FState.SimulationTime:=FState.SimulationTime+Dt;
  FState.LaneOffset:=0;FState.CurrentRoadWidth:=0;
  OldSpeed:=FState.CurrentSpeed;
  if FState.Walking then begin
    Accel:=EnsureRange((FState.TravelTargetSpeed-OldSpeed)*5,-5,3);
    Turn:=FState.TravelSteering*1.8;
  end else begin
    Accel:=CalculateAcceleration(Dt);
    { Bicycle steering: large handlebar angle at low speed, bounded lateral
      acceleration at speed. Rear tyre follows the integrated heading. }
    Turn:=FState.TravelSteering*Min(1.25,FState.CurrentSpeed*0.55);
    Turn:=EnsureRange(Turn,-5/Max(1,FState.CurrentSpeed),5/Max(1,FState.CurrentSpeed));
  end;
  if FState.Walking then FState.CurrentSpeed:=EnsureRange(OldSpeed+Accel*Dt,-2,6)
  else FState.CurrentSpeed:=EnsureRange(OldSpeed+Accel*Dt,0,MaxSpeed);
  Dir:=RotatePointAroundAxis(Vector4(0,1,0,Turn*Dt),FState.ForwardDir);
  SmoothRotateToDirection(Dir,Dt);
  StepDistance:=Abs(FState.CurrentSpeed)*Dt;
  Wanted:=FState.ForwardDir*(FState.CurrentSpeed*Cos(DegToRad(FState.CurrentGroundPitch))*Dt);
  Safe:=ConstrainGroundMovement(FState.WorldPosition,Wanted);
  LengthBefore:=Wanted.Length;
  if Safe.LengthSqr+1e-12<Wanted.LengthSqr then FState.CurrentSpeed:=Min(OldSpeed,FState.CurrentSpeed);
  Dir:=FState.WorldPosition+Safe;
  if FState.ConstrainBodyMove(FState.WorldPosition,Dir) then
    FState.CurrentSpeed:=FState.CurrentSpeed*
      Min(1,(Dir-FState.WorldPosition).Length/Max(1e-6,Safe.Length));
  Safe:=Dir-FState.WorldPosition;
  FState.MovementVelocity:=Safe/Dt;
  FState.WorldPosition:=Dir;
  if LengthBefore>1e-7 then FState.CumulativeDistance:=FState.CumulativeDistance+
    StepDistance*Min(1,Safe.Length/LengthBefore);
  UpdateTrajectoryFromRealVelocity(Dt);
  FActor.Transform.Translation:=Vector3(Dir.X,FActor.Transform.Translation.Y,Dir.Z);
  RestoreCameraRelativeState;
end;

procedure TKinematicActorPhysics.FixedStep(const FixedDelta: Single);
var
  Accel, MoveDist, TanFull, TanXZ, MoveScale: Single;
  SpeedBeforeStep, GroundMoveLength: Single;
  Cursor: TPathPosition;
  RoadW, LaneTarget: Single;
  MoveDir, PathTan, WantedMove, SafeMove, NextPosition: TVector3;
  Log: Boolean;
  LOD: TPhysicsLOD;
  DiagOn: Boolean;
begin
  { Разовая диагностика первых кадров — почему велосипедист стоит. }
  DiagOn := FDiagFrames < 8;
  { Count attempts, including missing ground / other early returns. A tile
    that remains pending must not turn startup diagnostics into frame spam. }
  if DiagOn then Inc(FDiagFrames);

  if not Assigned(FActor) then
  begin
    if DiagOn then Logger.Info('[KinDiag] ' + 'EXIT: FActor=nil');
    Exit;
  end;
  if not Assigned(FActor.Transform) then
  begin
    if DiagOn then Logger.Info('[KinDiag] ' + 'EXIT: FActor.Transform=nil');
    Exit;
  end;
  if not Assigned(FState) then
  begin
    if DiagOn then Logger.Info('[KinDiag] ' + 'EXIT: FState=nil');
    Exit;
  end;
  if FState.FreeTravel then begin FreeTravelStep(FixedDelta);Exit end;
  if not Assigned(FPath) then
  begin
    if DiagOn then Logger.Info('[KinDiag] ' + 'EXIT: FPath=nil');
    Exit;
  end;
  if FPath.PointCount < 2 then
  begin
    if DiagOn then Logger.Info('[KinDiag] ' + Format('EXIT: PointCount=%d',
      [FPath.PointCount]));
    Exit;
  end;

  ApplyControlInput;
  if DiagOn then
    Logger.Info('[KinDiag] ' + Format(
      'frame=%d AutoMove=%s Power=%.1f Speed=%.3f Pos=(%.1f,%.1f,%.1f) '
      + 'PathPos seg=%d t=%.3f PointCount=%d',
      [FDiagFrames, BoolToStr(FState.AutoMove, True),
       FState.AppliedPowerWatts, FState.CurrentSpeed,
       FState.WorldPosition.X, FState.WorldPosition.Y, FState.WorldPosition.Z,
       FPath.Position.Segment, FPath.Position.T, FPath.PointCount]));

  if not FState.AutoMove then
  begin
    if DiagOn then Logger.Info('[KinDiag] ' + 'EXIT: AutoMove=false');
    Exit;
  end;

  { Streaming samples are acquired by the render probes, never per fixed
    step. Missing initial ground cannot become valid merely by a timeout. }
  if Assigned(FState.GroundQuery) and (FState.PhysicsLOD <> plMinimal) and
     not GroundPlacementValid then
  begin
    FState.CurrentSpeed := 0;
    FState.MovementVelocity := Vector3(0,0,0);
    Exit;
  end;

  LOD := FState.PhysicsLOD;

  Log := False; { D controls drawing, never per-frame file logging. }
  FPath.DebugEnabled := Log;

  { Camera lock — protected by CameraLockActive (requires Navigation) }
  CaptureCameraRelativeState;

  FState.SimulationTime := FState.SimulationTime + FixedDelta;

  { Полосное смещение из ширины дороги.

    RoadWidthAt даёт ширину дороги под текущей точкой пути (0 — участок
    мимо дорог). Снаппер маршрута уже сместил трек широких дорог к
    полосе (инсет от края), поэтому здесь — лишь тонкая подстройка
    положения в полосе: смещение = доля полуширины со знаком.
    LANE_OFFSET_FACTOR: + вправо, − влево, 0 — по треку как есть.
    На участках мимо дорог (ширина 0) offset обнуляется — райдер едет
    просто по точкам. Смещение сглаживается, чтобы въезд/съезд с дороги
    не дёргал райдера вбок. }
  RoadW := FPath.RoadWidthAt(FPath.Position);
  { Сохраняем текущую ширину дороги — отладочная визуализация берёт
    именно это значение, не пересчитывая. }
  FState.CurrentRoadWidth := RoadW;
  { Если боковым смещением управляет менеджер полос (LaneOffsetExternal),
    кинематика его НЕ трогает — иначе она бы перетирала значение
    менеджера своим сглаживанием к RoadW*0.5*фактор. Иначе (одиночный
    режим, бот) считаем offset сами из ширины дороги. }
  if not FState.LaneOffsetExternal then
  begin
    { LaneCenterFactor: на тропинке (<= PATH_SINGLE_FILE_WIDTH_M) цель — 0,
      едем по центру; к нормальной ширине фактор линейно выходит на 1.
      Рампа пространственная, плюс прежнее временное сглаживание ниже. }
    if RoadW > 0.0 then
      LaneTarget := RoadW * 0.5 * LANE_OFFSET_FACTOR * LaneCenterFactor(RoadW)
    else
      LaneTarget := 0.0;
    { Экспоненциальное сглаживание к цели (постоянная времени ~0.4 с). }
    FState.LaneOffset := FState.LaneOffset
      + (LaneTarget - FState.LaneOffset)
        * Min(1.0, FixedDelta / 0.4);
  end;

  FPath.Position := FPath.ProjectFollow(FState.WorldPosition, FPath.Position,
    Max(2.0, FState.CurrentSpeed * FixedDelta * 2));

  if UpdateRouteTurnaround(FixedDelta) then
  begin
    RestoreCameraRelativeState;
    Exit;
  end;

  { 1. Direction — carrot offset by lane }
  MoveDir := FPath.GetSmartRouteDirection(
    FState.WorldPosition, FState.CurrentSpeed, FixedDelta,
    FState.LaneOffset);
  SmoothRotateToDirection(MoveDir, FixedDelta);
  if Assigned(FProfiler) then FProfiler.Mark('dir');

  { 2. Speed — same acceleration formula at all LODs }
  SpeedBeforeStep := FState.CurrentSpeed;
  Accel := CalculateAcceleration(FixedDelta);
  FState.CurrentSpeed := FState.CurrentSpeed + Accel * FixedDelta;
  if FState.CurrentSpeed < 0 then FState.CurrentSpeed := 0;
  if FState.CurrentSpeed > MaxSpeed then FState.CurrentSpeed := MaxSpeed;
  { A physically reachable turn on the prepared path: decelerate before
    mandatory bends instead of cutting through the avoided building. }
  FState.CurrentSpeed:=Min(FState.CurrentSpeed,FPath.SteeringSpeedLimit);
  if Assigned(FState.TrafficMoveConstraint) then
    FState.CurrentSpeed:=Min(FState.CurrentSpeed,FState.TrafficSpeedLimit);

  { 3. Movement — MoveDist is 3D road distance; project onto XZ using path slope }
  MoveDist := FState.CurrentSpeed * FixedDelta;
  PathTan := FPath.FollowTangent(FPath.Position);
  TanFull := PathTan.Length;
  if TanFull > 0.01 then
    TanXZ := Sqrt(Sqr(PathTan.X) + Sqr(PathTan.Z)) / TanFull
  else
    TanXZ := 1.0;
  { Visible mesh slope determines horizontal travel. FIT slope correction
    affects acceleration, never the geometry of ground contact. }
  if Assigned(FState.GroundQuery) then
    TanXZ := Cos(DegToRad(FState.CurrentGroundPitch));
  FState.MovementVelocity := FState.ForwardDir * (FState.CurrentSpeed * TanXZ);
  WantedMove := FState.MovementVelocity * FixedDelta;
  SafeMove := ConstrainGroundMovement(FState.WorldPosition, WantedMove);
  GroundMoveLength := SafeMove.Length;
  if SafeMove.LengthSqr + 1e-12 < WantedMove.LengthSqr then
  begin
    Inc(FGroundLeaseLimitedSteps);
    FGroundLeaseRejectedMeters := FGroundLeaseRejectedMeters +
      (WantedMove.Length - SafeMove.Length);
    FGroundWaitSec := FGroundWaitSec + FixedDelta;
    if FGroundWaitSec <= GroundMomentumHoldSeconds then
      { Reject added propulsion energy while held; real braking and speed
        limits can still lower speed. Never turn a data delay into friction. }
      FState.CurrentSpeed := Min(FState.CurrentSpeed, SpeedBeforeStep)
    else
      FState.CurrentSpeed := 0;
  end else
    FGroundWaitSec := 0;
  if Assigned(FState.TrafficMoveConstraint) then
    SafeMove := FState.TrafficMoveConstraint(FState.TrafficTag,
      FState.WorldPosition, SafeMove, True);
  if WantedMove.Length > 0.000001 then
  begin
    MoveScale := Min(1,SafeMove.Length/WantedMove.Length);
    { Only a real rider / obstacle constraint dissipates momentum. Ground
      clipping still bounds position, odometer and render extrapolation. }
    if GroundMoveLength > 0.000001 then
      FState.CurrentSpeed := FState.CurrentSpeed * Min(1,SafeMove.Length/GroundMoveLength);
    MoveDist := MoveDist * MoveScale;
    FState.MovementVelocity := SafeMove / FixedDelta;
  end;
  NextPosition:=FState.WorldPosition+FState.MovementVelocity*FixedDelta;
  if FState.ConstrainBodyMove(FState.WorldPosition,NextPosition) then begin
    MoveScale:=Min(1,(NextPosition-FState.WorldPosition).Length/Max(1e-6,SafeMove.Length));
    MoveDist:=MoveDist*MoveScale;FState.CurrentSpeed:=FState.CurrentSpeed*MoveScale;
    FState.MovementVelocity:=(NextPosition-FState.WorldPosition)/FixedDelta;
    InvalidateGroundPlacement;
  end;
  FState.WorldPosition:=NextPosition;

  { Progress is the local projection of the new physical position, not a
    comparison between arc length and the chord to an old carrot. }
  Cursor := FPath.Position;
  FPath.AdvanceFollow(Cursor, MoveDist);
  FPath.Position := FPath.ProjectFollow(FState.WorldPosition, Cursor,
    Max(2.0, MoveDist * 2));

  { 4a. Cumulative distance — tracked here, synchronized with physics step }
  FState.CumulativeDistance := FState.CumulativeDistance + MoveDist;

  if DiagOn then
  begin
    Logger.Info('[KinDiag] ' + Format(
      'frame=%d MoveDir=(%.3f,%.3f,%.3f) Accel=%.4f MaxSpeed=%.2f '
      + 'MoveDist=%.5f TanXZ=%.3f Fwd=(%.3f,%.3f,%.3f) NewPos=(%.1f,%.1f,%.1f)',
      [FDiagFrames,
       MoveDir.X, MoveDir.Y, MoveDir.Z, Accel, MaxSpeed,
       MoveDist, TanXZ,
       FState.ForwardDir.X, FState.ForwardDir.Y, FState.ForwardDir.Z,
       FState.WorldPosition.X, FState.WorldPosition.Y, FState.WorldPosition.Z]));
  end;

  if Assigned(FProfiler) then FProfiler.Mark('move');

  { 4b. Avatar trace — disabled (too verbose, enable manually if needed).
    Was: per-frame CSV with position, carrot, speed, slope, etc. }
  {
  if GLogEnabled and Assigned(FActor.Navigation) then
  begin
    Inc(FTraceFrameNum);
    TraceLog.Info(Format('%d,%.3f,%.2f,%.0f,%.2f,%.3f,%.3f,%.4f,%.4f,%d,%.4f,%.3f,%.3f,%.3f,%.1f',
      [FTraceFrameNum,
       FState.SimulationTime,
       FState.CurrentSpeed,
       FState.AppliedPowerWatts,
       FState.CurrentSlopeAngle,
       FState.WorldPosition.X,
       FState.WorldPosition.Z,
       FState.ForwardDir.X,
       FState.ForwardDir.Z,
       FPath.Position.Segment,
       FPath.Position.T,
       FPath.LastCarrotWorld.X,
       FPath.LastCarrotWorld.Z,
       FState.LaneOffset,
       FState.CumulativeDistance]));
  end;
  }

  { 5. Trajectory — only at plFull (needed for turn forces and lean) }
  if LOD = plFull then
    UpdateTrajectoryFromRealVelocity(FixedDelta)
  else
    FState.PrevWorldPosition := FState.WorldPosition;

  { 6. Transform XZ (Y is set in UpdateVisualGroundPlacement each render frame) }
  if Assigned(FActor.Transform) then
    FActor.Transform.Translation := Vector3(
      FState.WorldPosition.X,
      FActor.Transform.Translation.Y,
      FState.WorldPosition.Z);

  RestoreCameraRelativeState;
  if Assigned(FProfiler) then FProfiler.Mark('model');
end;

procedure TKinematicActorPhysics.UpdateVisualDebug;
begin
  inherited;
  if Assigned(FDebug) and FDebug.DebugSpheresVisible then
  begin
    if Assigned(FDebug.DebugSphereCarrot) then
      FDebug.DebugSphereCarrot.Translation := FPath.LastCarrotWorld;
    UpdateRoadDebugLines;
  end;
end;

procedure TKinematicActorPhysics.UpdateRoadDebugLines;
var
  W, HalfW, Yaw, Lateral, BaseY: Single;
  Center, Fwd, Right, Anchor: TVector3;
  LaneCount, Interior, I: Integer;
  UsingReal: Boolean;
  VisualCursor: TPathPosition;

  procedure PlaceLine(ALine: TCastleBox; ALateral: Single);
  var P: TVector3;
  begin
    if not Assigned(ALine) then Exit;
    P := Anchor + Right * ALateral;
    { Y берём от велосипеда (он стоит на поверхности дороги), а не от
      точки пути — у точки пути Y = 0 (высоту подставляет физика), из-за
      чего линии иначе уезжали под мир. BaseY уже включает подъём. }
    ALine.Translation := Vector3(P.X, BaseY, P.Z);
    ALine.Rotation    := Vector4(0, 1, 0, Yaw);
    ALine.Exists      := True;
  end;

  procedure HideLine(ALine: TCastleBox);
  begin
    if Assigned(ALine) then ALine.Exists := False;
  end;

begin
  if not Assigned(FDebug) then Exit;
  if not FDebug.DebugSpheresVisible then Exit;
  if not Assigned(FPath) or (FPath.PointCount < 2) then Exit;

  W := FState.CurrentRoadWidth;   { именно текущая ширина, без пересчёта }
  { Ширина 0 (сырой трек / мимо дорог) → рисуем фолбэк-шириной, иначе
    отлаживать нечего и линии были бы скрыты. UsingReal различает эти
    случаи для окраски краёв. }
  UsingReal := W > 0.0;
  if not UsingReal then
    W := DEBUG_FALLBACK_ROAD_WIDTH_M;

  HalfW := W * 0.5;

  { Осевая ДОРОГИ (куда притянул снап), а не сырой трек аватара. Если
    центры не заданы (нет снапа) — RoadCenterAt падает на сам путь.
    К ней привязаны линии, поэтому они едут вместе с велосипедом. }
  VisualCursor := FPath.ProjectFollow(FActor.Transform.Translation,
    FPath.Position, 2.0);
  Center := FPath.RoadCenterAt(VisualCursor);
  Anchor := Center;

  BaseY := GroundHeightAtPosition(FActor.Transform.Translation) + DEBUG_LINE_LIFT_M;

  { Направление движения в плоскости XZ и перпендикуляр (право). }
  Fwd   := FPath.FollowDirectionXZ(VisualCursor);
  if Fwd.Length < 0.001 then Fwd := Vector3(0, 0, 1);
  Right := Vector3(Fwd.Z, 0, -Fwd.X);

  { Брус-линия длинной осью смотрит вдоль локального +Z; поворот вокруг
    Y на Yaw разворачивает её по направлению движения. }
  Yaw := ArcTan2(Fwd.X, Fwd.Z);

  { Цвет краёв: синий — когда ширина реальная (точка притянута к дороге),
    красный — когда ширина нулевая и взят дефолт. }
  if Assigned(FDebug.DebugLineEdgeLeft) then
    if UsingReal then
      FDebug.DebugLineEdgeLeft.Color := Vector4(0, 0, 1, 1)
    else
      FDebug.DebugLineEdgeLeft.Color := Vector4(1, 0, 0, 1);
  if Assigned(FDebug.DebugLineEdgeRight) then
    if UsingReal then
      FDebug.DebugLineEdgeRight.Color := Vector4(0, 0, 1, 1)
    else
      FDebug.DebugLineEdgeRight.Color := Vector4(1, 0, 0, 1);

  { Осевая и края. }
  PlaceLine(FDebug.DebugLineCenter, 0.0);
  PlaceLine(FDebug.DebugLineEdgeLeft,  -HalfW);
  PlaceLine(FDebug.DebugLineEdgeRight, +HalfW);

  { Разделители полос: дорога делится на LaneCount равных полос, рисуем
    внутренние границы (их LaneCount-1). Число полос — из текущей ширины
    и допущения DEBUG_LANE_WIDTH_M (чисто отладочное). }
  LaneCount := Round(W / DEBUG_LANE_WIDTH_M);
  if LaneCount < 1 then LaneCount := 1;
  if LaneCount > DEBUG_MAX_LANE_MARKS + 1 then
    LaneCount := DEBUG_MAX_LANE_MARKS + 1;
  Interior := LaneCount - 1;

  for I := 0 to DEBUG_MAX_LANE_MARKS - 1 do
  begin
    if I < Interior then
    begin
      Lateral := -HalfW + (I + 1) * (W / LaneCount);
      PlaceLine(FDebug.DebugLineLanes[I], Lateral);
    end
    else
      HideLine(FDebug.DebugLineLanes[I]);
  end;
end;

function TKinematicActorPhysics.Mode: TPhysicsMode;
begin
  Result := pmKinematicCurrent;
end;

end.
