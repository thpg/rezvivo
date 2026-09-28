{ RideFullEmulator — ПОЛНАЯ эмуляция прохождения записанного заезда на
  ЖИВОЙ физике игры: TKinematicActorPhysics (GamePhysicsKinematic) —
  колёсная постановка на рельеф (рейкаст высоты под каждым колесом),
  курсовая динамика с ограничителем поворота, кривизна и лимит скорости
  в поворотах, сглаживание высоты земли — весь код игровой, ничего не
  продублировано.

  Отличия от живой игры вынесены в точки подмены, предусмотренные самой
  игрой:
    • высота земли — через FState.GroundQuery (штатный провайдер,
      gamephysicscommon): в игре — меш тайлов карты, здесь — профиль
      высот режима вдоль маршрута (TEmuTerrain). Рейкаст сцены не
      используется — вьюпорта у эмуляции нет;
    • ввод — TAgentControlInput: мощность из FIT по дистанции (одометр
      байка), торможение — отдельной измеренной силой. Начальная
      скорость берётся из FIT; дальше скорость определяется физикой;
    • визуальные части (сцена/камера/навигация) отсутствуют — все
      обращения к ним в физике nil-безопасны (MeasureModelBounds и
      ApplyModelRotation сами выходят по nil).

  Режимы уклона — те же четыре (TEmuMode, RideEmulator): различаются
  только профилем высот, который видят «колёса»:
    emGame      — высоты мира (дорога/поверхность, канал AVirtAlt);
    emRealSlope — баро-высоты FIT (подмена рельефа реальностью);
    emDelta     — профиль мира + интеграл сглаженной поправки Δ;
    emIntegral  — профиль мира + живая поправка от накопленного
                  дефицита набора (контур обновляется по ходу прогона,
                  как в 1D-эмуляторе — те же константы EMU_*).

  Каналы заезда — общие с 1D-эмулятором (PrepareRideChannels): сетка
  дистанций без стоянок FIT, мощность/тормоза, уклоны, поправка Δ.
  Калибровка параметров — общая с 1D (вызывающий передаёт уже
  откалиброванные AMass/ACdA/ACrr). }
unit RideFullEmulator;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math,
  CastleVectors,
  RideParamEstimator,     { TRideSampleArray, TRidePointResultArray }
  RideEmulator;           { TRideChannels, TEmuResultArray, PrepareRideChannels }

{ Прогнать все режимы полной эмуляции. Параметры Samples/PtsFit/AVirtAlt
  и ADrivetrainEff — как у EmulateRideModes (каналы готовит тот же
  PrepareRideChannels). ARouteWorld — маршрут в мировых XZ (та же
  проекция, что у мира игры; Y игнорируется — высоту даёт профиль
  режима), полной длины (индексация Samples). AMass/ACdA/ACrr —
  параметры райдера (после общей калибровки). False — данных не хватает
  (Note объясняет). }
function EmulateRideFull(
  const Samples: TRideSampleArray;
  const PtsFit:  TRidePointResultArray;
  const AVirtAlt: array of Double;
  const ARouteWorld: array of TVector3;
  AMass, ACdA, ACrr, ADrivetrainEff: Double;
  out Results: TEmuResultArray;
  out Note: string): Boolean;

implementation

uses
  CastleTransform,
  GamePhysicsCommon,      { TPhysicsState, TPhysicsActor, TPhysicsDebug, plFull }
  GamePhysicsKinematic,   { TKinematicActorPhysics — игровой шаг физики }
  GamePath,               { TGamePath — путь и carrot-навигация }
  GameAgentControl;       { TAgentControlInput — ввод мощности }

const
  FULL_DT   = 1.0 / 60.0; { шаг симуляции — как кадр игры }
  SCAN_HALF = 32;         { полуокно курсорного поиска ближайшей точки маршрута }

type
  { Провайдер высоты земли для FState.GroundQuery: высотный профиль
    вдоль маршрута. (X, Z) → ближайшая точка полилинии (курсор, окно
    ±SCAN_HALF — байк движется непрерывно) → проекция на соседний
    сегмент → интерполированные s и высота. Для emIntegral поверх
    профиля — смещение уклона FBias, заякоренное на текущей дистанции
    байка (поле локально градиентно-согласовано). }
  TEmuTerrain = class
  private
    FRte: array of TVector3;
    FS:   array of Double;
    FAlt: array of Double;
    FBias, FBiasAnchor: Double;
    FCursor: Integer;
  public
    { Ожидаемая дистанция байка (одометр) — подтягивает курсор, чтобы
      на петлях/серпантине ближайшая точка не прыгала на параллельный
      участок маршрута. Прогон выставляет перед запросами кадра. }
    ExpectedS: Double;
    constructor Create(const ARte: array of TVector3; const ASArc,
      AAlt: array of Double);
    procedure SetProfile(const AAlt: array of Double);
    procedure SetBias(const ABias, AAnchorS: Double);
    procedure ResetCursor;
    function GroundY(WorldX, WorldZ, ReferenceY: Single; out AY: Single): Boolean;
  end;

constructor TEmuTerrain.Create(const ARte: array of TVector3;
  const ASArc, AAlt: array of Double);
var
  I: Integer;
begin
  inherited Create;
  SetLength(FRte, Length(ARte));
  for I := 0 to High(ARte) do FRte[I] := ARte[I];
  SetLength(FS, Length(ASArc));
  for I := 0 to High(ASArc) do FS[I] := ASArc[I];
  SetProfile(AAlt);
end;

procedure TEmuTerrain.SetProfile(const AAlt: array of Double);
var
  I: Integer;
begin
  SetLength(FAlt, Length(AAlt));
  for I := 0 to High(AAlt) do FAlt[I] := AAlt[I];
  FBias := 0;
  FBiasAnchor := 0;
end;

procedure TEmuTerrain.SetBias(const ABias, AAnchorS: Double);
begin
  FBias := ABias;
  FBiasAnchor := AAnchorS;
end;

procedure TEmuTerrain.ResetCursor;
begin
  FCursor := 0;
  ExpectedS := 0;
end;

function TEmuTerrain.GroundY(WorldX, WorldZ, ReferenceY: Single; out AY: Single): Boolean;
var
  I, I0, I1, BI, A, B: Integer;
  D, BD, T, SCur, Px, Pz, Dx, Dz, L2, DQ1, DQ2: Double;
begin
  Result := False;
  if (Length(FRte) < 2) or (Length(FAlt) <> Length(FRte)) then Exit;

  { Курсор синхронизируем с одометром (окно вокруг ожидаемой дистанции):
    серпантин с параллельными ветками не уводит высоту на чужой участок. }
  while (FCursor < High(FRte)) and (FS[FCursor + 1] < ExpectedS - 30.0) do
    Inc(FCursor);

  { Ближайшая вершина в окне вокруг курсора. }
  I0 := Max(0, FCursor - SCAN_HALF);
  I1 := Min(High(FRte), FCursor + SCAN_HALF);
  BI := FCursor;
  BD := 1.0e30;
  for I := I0 to I1 do
  begin
    D := Sqr(FRte[I].X - WorldX) + Sqr(FRte[I].Z - WorldZ);
    if D < BD then
    begin
      BD := D;
      BI := I;
    end;
  end;
  if BI > FCursor then FCursor := BI;

  { Непрерывная s: проекция на лучший из двух соседних сегментов. }
  A := BI; B := BI; T := 0;
  DQ1 := 1.0e30; DQ2 := 1.0e30;
  if BI < High(FRte) then
  begin
    Dx := FRte[BI + 1].X - FRte[BI].X;
    Dz := FRte[BI + 1].Z - FRte[BI].Z;
    L2 := Dx * Dx + Dz * Dz;
    if L2 > 1.0e-9 then
    begin
      T := ((WorldX - FRte[BI].X) * Dx + (WorldZ - FRte[BI].Z) * Dz) / L2;
      T := EnsureRange(T, 0.0, 1.0);
      Px := FRte[BI].X + Dx * T;
      Pz := FRte[BI].Z + Dz * T;
      DQ1 := Sqr(WorldX - Px) + Sqr(WorldZ - Pz);
      A := BI; B := BI + 1;
    end;
  end;
  if BI > 0 then
  begin
    Dx := FRte[BI].X - FRte[BI - 1].X;
    Dz := FRte[BI].Z - FRte[BI - 1].Z;
    L2 := Dx * Dx + Dz * Dz;
    if L2 > 1.0e-9 then
    begin
      T := ((WorldX - FRte[BI - 1].X) * Dx + (WorldZ - FRte[BI - 1].Z) * Dz) / L2;
      T := EnsureRange(T, 0.0, 1.0);
      Px := FRte[BI - 1].X + Dx * T;
      Pz := FRte[BI - 1].Z + Dz * T;
      DQ2 := Sqr(WorldX - Px) + Sqr(WorldZ - Pz);
      if DQ2 < DQ1 then
      begin
        A := BI - 1; B := BI;
        DQ1 := DQ2;
      end
      else
      begin
        A := BI; B := Min(BI + 1, High(FRte));
      end;
    end;
  end;
  { Пересчёт T на выбранном сегменте (A, B). }
  T := 0;
  if B > A then
  begin
    Dx := FRte[B].X - FRte[A].X;
    Dz := FRte[B].Z - FRte[A].Z;
    L2 := Dx * Dx + Dz * Dz;
    if L2 > 1.0e-9 then
      T := EnsureRange(
        ((WorldX - FRte[A].X) * Dx + (WorldZ - FRte[A].Z) * Dz) / L2,
        0.0, 1.0);
  end;
  SCur := FS[A] + (FS[B] - FS[A]) * T;
  AY := FAlt[A] + (FAlt[B] - FAlt[A]) * T
      + FBias * (SCur - FBiasAnchor);
  Result := True;
end;

{ ── Прогон всех режимов ────────────────────────────────────────────── }
function EmulateRideFull(
  const Samples: TRideSampleArray;
  const PtsFit:  TRidePointResultArray;
  const AVirtAlt: array of Double;
  const ARouteWorld: array of TVector3;
  AMass, ACdA, ACrr, ADrivetrainEff: Double;
  out Results: TEmuResultArray;
  out Note: string): Boolean;
var
  Ch: TRideChannels;
  Rte, SteeringRte: array of TVector3;
  EndDirection: TVector3;
  ADelta, AFitSm, AWorldSm: array of Double;
  Terrain: TEmuTerrain;
  TCap: Double;
  I: Integer;
  M: TEmuMode;
  DiagAll: String;

  { Один прогон режима на игровой физике. }
  function RunFull(AM: TEmuMode): TEmuResult;
  var
    State: TPhysicsState;
    Actor: TPhysicsActor;
    Path: TGamePath;
    Dbg: TPhysicsDebug;
    Phys: TKinematicActorPhysics;
    Input: TAgentControlInput;
    T, CurS, SPrev, MoveD: Double;
    ArcNow, ArcPrev, CurSBase: Double;
    PNow, FNow, VNow, GFitNow: Double;
    Grade, MaxV, Work, Climb, RmsAcc: Double;
    CInt, Bias, BiasTarget: Double;
    CI: Integer;
    Steps: Integer;
    SnapTxt: String;

    { Линейная интерполяция канала по дистанции CurS; курсор CI только
      вперёд (CurS монотонна). }
    function ChanAt(const Arr: array of Double): Double;
    var
      T1: Double;
    begin
      if CurS <= Ch.S[0] then Exit(Arr[0]);
      if CurS >= Ch.S[Ch.N - 1] then Exit(Arr[Ch.N - 1]);
      while (CI < Ch.N - 2) and (Ch.S[CI + 1] <= CurS) do Inc(CI);
      if Ch.S[CI + 1] > Ch.S[CI] then
        T1 := (CurS - Ch.S[CI]) / (Ch.S[CI + 1] - Ch.S[CI])
      else
        T1 := 0;
      Result := Arr[CI] + (Arr[CI + 1] - Arr[CI]) * T1;
    end;

    { The steering path continues beyond the FIT endpoint. Reaching that
      service segment finishes the ride; its length is never counted. }
    function RouteArcS: Double;
    var
      Seg: Integer;
    begin
      Seg := Path.Position.Segment;
      if Seg < 0 then Seg := 0;
      if Seg >= Ch.N - 1 then Exit(Ch.SEnd);
      Result := Ch.S[Seg]
        + (Ch.S[Seg + 1] - Ch.S[Seg])
          * EnsureRange(Path.Position.T, 0.0, 1.0);
    end;

  begin
    FillChar(Result, SizeOf(Result), 0);
    Result.Mode := AM;

    { Профиль режима → «рельеф» для колёс. }
    case AM of
      emGame:      Terrain.SetProfile(AWorldSm);
      emRealSlope: Terrain.SetProfile(AFitSm);
      emDelta:     Terrain.SetProfile(ADelta);
      emIntegral:  Terrain.SetProfile(AWorldSm);
    end;
    Terrain.ResetCursor;
    Terrain.SetBias(0, 0);

    { Сборка игрового стека headless: трансформ без сцены/вьюпорта,
      провайдер высоты — наш профиль. }
    State := TPhysicsState.Create;
    Actor := TPhysicsActor.Create;
    Path := TGamePath.Create;
    Dbg := TPhysicsDebug.Create;
    Actor.Transform := TCastleTransform.Create(nil);
    State.AvatarMass := AMass;
    State.DragCoefficient := ACdA;   { CdA передаётся как Cd при Area=1 }
    State.FrontalArea := 1.0;
    State.RollingResistance := ACrr;
    State.PhysicsLOD := plFull;      { кривизна + лимит скорости поворотов }
    State.GroundQuery := @Terrain.GroundY;
    Path.LoadFromMemory(SteeringRte, []);
    Path.BakeWorldPoints;            { без сцены — мировые = как есть }
    Path.CarrotWobbleEnabled := False; { cosmetic randomness must not bias mode comparison }
    Input.Reset;
    Input.WantsAutoMove := True;
    Phys := TKinematicActorPhysics.Create(Actor, State, Path, Dbg, @Input);
    try
      Phys.Initialize;
      Phys.InitializeAtStart;
      Phys.StartMoving;
      if (Length(Ch.VR)>0) and not IsNan(Ch.VR[0]) and not IsInfinite(Ch.VR[0]) then
        State.CurrentSpeed := EnsureRange(Ch.VR[0],0.0,Double(MaxSpeed));

      T := 0; SPrev := 0; CI := 0;
      MaxV := State.CurrentSpeed; Work := 0; Climb := 0; RmsAcc := 0;
      CInt := 0; Bias := 0;
      Steps := 0; SnapTxt := '';
      ArcPrev := 0; CurSBase := 0;
      repeat
        { Позиция на маршруте — по КУРСОРУ ПУТИ (дуга под курсором), а не
          по одометру: байк срезает повороты (морковка 8–10 м), одометр
          отстаёт от дуги маршрута — каналы «опаздывали», а финиш
          требовал лишних виртуальных метров. Курсор пути мотается через
          конец на 0 (путь циклический) — переход ловим по падению дуги. }
        ArcNow := RouteArcS;
        if ArcNow < ArcPrev - 100.0 then
          CurSBase := CurSBase + Ch.SEnd;
        ArcPrev := ArcNow;
        CurS := CurSBase + ArcNow;
        if CurS >= Ch.SEnd then Break; { do not integrate past a reached finish }
        Terrain.ExpectedS := CurS;   { курсор рельефа — за позицией }
        PNow := ChanAt(Ch.PW);
        FNow := ChanAt(Ch.FBr);
        VNow := ChanAt(Ch.VR);
        Input.DesiredPowerWatts := PNow;
        Input.BrakeForceN := FNow;

        Phys.UpdateVisualGroundPlacement(FULL_DT);  { колёса → высота/питч }
        Phys.FixedStep(FULL_DT);                    { курс/ускорение/ход }
        Inc(Steps);

        T := T + FULL_DT;
        if (SnapTxt = '') and (T >= 5.0) then
          SnapTxt := Format('@5с: v=%.2f P=%.0f pitch=%.1f dist=%.1f '
            + 'pos=(%.1f,%.1f,%.1f)',
            [State.CurrentSpeed, State.AppliedPowerWatts,
             State.CurrentGroundPitch, State.CumulativeDistance,
             State.WorldPosition.X, State.WorldPosition.Y,
             State.WorldPosition.Z]);
        MoveD := State.CumulativeDistance - SPrev;
        SPrev := State.CumulativeDistance;
        Work := Work + PNow * FULL_DT;
        if State.CurrentSpeed > MaxV then MaxV := State.CurrentSpeed;
        Grade := Sin(DegToRad(State.CurrentGroundPitch));
        if Grade > 0 then Climb := Climb + Grade * MoveD;
        RmsAcc := RmsAcc + Sqr(State.CurrentSpeed - VNow) * FULL_DT;

        if AM = emIntegral then
        begin
          GFitNow := ChanAt(Ch.GFit);
          CInt := CInt + (GFitNow - Grade) * MoveD;
          BiasTarget := EnsureRange(CInt / EMU_INT_GAIN_M,
            -EMU_DELTA_CLAMP, EMU_DELTA_CLAMP);
          Bias := Bias + EnsureRange(BiasTarget - Bias,
            -EMU_SLEW_PER_SEC * FULL_DT, EMU_SLEW_PER_SEC * FULL_DT);
          Terrain.SetBias(Bias, CurS);
        end;
      until (CurS >= Ch.SEnd) or (T > TCap);

      Result.Finished := CurS >= Ch.SEnd;
      Result.TimeSec := T;
      if T > 1 then
        Result.AvgSpeedKmh := (CurS / T) * 3.6
      else
        Result.AvgSpeedKmh := 0;
      Result.MaxSpeedKmh := MaxV * 3.6;
      Result.WorkKJ := Work / 1000.0;
      Result.ClimbAppliedM := Climb;
      if T > 1 then
        Result.RmsSpeedVsRealMs := Sqrt(RmsAcc / T)
      else
        Result.RmsSpeedVsRealMs := 0;
      { Диагностика прогона — в примечание отчёта (Logger.Info сюда не
        доходит); печатается только для недоехавшего режима. }
      if not Result.Finished then
        DiagAll := DiagAll + Format(
          '  [diag %s] шагов=%d t=%.0fс дуга=%.0f/%.0fм одометр=%.0fм '
          + 'v=%.2f макс=%.1f pitch=%.1f %s' + LineEnding,
          [EMU_MODE_NAMES[AM], Steps, T, CurS, Ch.SEnd,
           State.CumulativeDistance,
           State.CurrentSpeed, MaxV * 3.6, State.CurrentGroundPitch,
           SnapTxt]);
    finally
      Phys.Free;
      Dbg.Free;
      Path.Free;
      Actor.Transform.Free;
      Actor.Free;
      State.Free;
    end;
  end;

begin
  Result := False;
  SetLength(Results, 0);
  Note := '';
  if ADrivetrainEff <= 0 then ADrivetrainEff := 1.0;
  if not PrepareRideChannels(Samples, PtsFit, AVirtAlt, ADrivetrainEff,
       Ch, Note) then
    Exit;
  if Length(ARouteWorld) < Length(Samples) then
  begin
    Note := 'полная эмуляция пропущена: мировой маршрут короче FIT';
    Exit;
  end;

  { Компактный маршрут (та же сетка без стоянок), Y занулён — высоту
    подставляет провайдер (как точки пути игры: «Y = 0, высота —
    из физики»). }
  SetLength(Rte, Ch.N);
  for I := 0 to Ch.N - 1 do
  begin
    Rte[I] := ARouteWorld[Ch.Keep[I]];
    Rte[I].Y := 0;
  end;
  { TGamePath loops, while the FIT calculation must stop at its endpoint.
    Extend only its steering polyline beyond the largest 45 m lookahead;
    the original terrain, samples and measured route length stay intact. }
  SetLength(SteeringRte, Ch.N+1);
  for I := 0 to Ch.N-1 do SteeringRte[I] := Rte[I];
  EndDirection := Vector3(0,0,1);
  for I := Ch.N-2 downto 0 do
    if (Rte[Ch.N-1]-Rte[I]).LengthSqr > 1e-8 then
    begin
      EndDirection := (Rte[Ch.N-1]-Rte[I]).Normalize;
      Break;
    end;
  SteeringRte[Ch.N] := Rte[Ch.N-1]+EndDirection*50;

  { Высотный профиль emDelta: мир + ∫(GVirt + Δ) ds — чтобы колёса
    чувствовали тот же уклон, что 1D-режим применяет напрямую. }
  SetLength(ADelta, Ch.N);
  ADelta[0] := Ch.AWorld[0];
  for I := 1 to Ch.N - 1 do
    ADelta[I] := ADelta[I - 1]
      + (Ch.GVirt[I - 1] + Ch.DeltaG[I - 1]) * (Ch.S[I] - Ch.S[I - 1]);

  { Профиль «реальности» для колёс: НЕ сырая баро-высота (её ступени
    между сэмплами дают ложные стены ±30% — байк встаёт), а интеграл
    сглаженного уклона оценщика GFit — тот же уклон, что видит 1D. }
  SetLength(AFitSm, Ch.N);
  AFitSm[0] := Ch.AFit[0];
  for I := 1 to Ch.N - 1 do
    AFitSm[I] := AFitSm[I - 1]
      + Ch.GFit[I - 1] * (Ch.S[I] - Ch.S[I - 1]);

  { Профиль «мира» для колёс — так же: интеграл сглаженного уклона
    мира GVirt (сырые высоты вершин меша скачут между узлами — те же
    ложные стены; 1D берёт именно GVirt). }
  SetLength(AWorldSm, Ch.N);
  AWorldSm[0] := Ch.AWorld[0];
  for I := 1 to Ch.N - 1 do
    AWorldSm[I] := AWorldSm[I - 1]
      + Ch.GVirt[I - 1] * (Ch.S[I] - Ch.S[I - 1]);

  TCap := Ch.MovingDur * 3.0 + 600.0;
  DiagAll := '';
  Terrain := TEmuTerrain.Create(Rte, Ch.S, Ch.AWorld);
  try
    SetLength(Results, Ord(High(TEmuMode)) + 1);
    for M := Low(TEmuMode) to High(TEmuMode) do
      Results[Ord(M)] := RunFull(M);
  finally
    Terrain.Free;
  end;

  Note := Format('мощность/сила торможения из FIT по дистанции; '
    + 'стоянки FIT пропущены (%d шт, %.0f с); '
    + 'начальная скорость из FIT, далее без принудительного движения; '
    + 'физика — игровая (колёса, курс, кривизна, лимиты поворотов), '
    + 'параметры m=%.1f кг, CdA=%.3f, Crr=%.4f',
    [Ch.StopCnt, Ch.StopDur, AMass, ACdA, ACrr]);
  if DiagAll <> '' then
    Note := Note + LineEnding + DiagAll;
  Result := True;
end;

end.
