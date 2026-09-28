unit BikeGpuSpin;

{$mode objfpc}{$H+}

{ ── GPU-вращение жёстких частей байка (GPU_ANIM_DESIGN.md, этап 4) ──────────

  Заменяет TimeSensor/OrientationInterpolator/ROUTE-цепочку
  (TAnimationComponent.BuildGeometry до этапа 4): углы колёс, шатунов,
  counter-spin и pitch платформ педалей считает вершинный шейдер из
  uPhase/uWheelPhase (CPU-накопители TBikeInstance.FPhase/FWheelPhase).

  Именованные трансформы (RearWheelRot/FrontWheelRot/CranksRot/Pedal*Rot/
  Pedal*Foot) остаются в сцене с identity-ротацией (их узлы — точки
  совместимости для внешнего кода), вращение переносится в plug
  PLUG_vertex_object_space на шейпах поддеревьев.

  Композиция для педали (точная, без приближений):
    исходный стек: CrankGroup·RotGroup(Rc)·PM(T)·PCR(Rp)·PFoot(Rf)·PB·v
    Rc — crank spin (−2π·phase о Z), Rp — counter-spin (+2π·phase о Z),
    Rc·Rp = I  =>  v' = Rc·T + Rf·v.
    Т.е. тело педали = смещение на вращающийся конец шатуна + pitch
    платформы (анклинг, порт BicycleAnkleFlexCurve, без free-ноги фейда).
    Нормаль поворачивается только на Rf (смещение на нормаль не влияет).

  CPU на кадр: SendFrame — 4 float (phase, wheelPhase, ankleFlex, freeR/L).
  Эффекты пересоздаются на каждый билд байка (владелец вызывает Build после
  пересборки геометрии; старые эффекты умирают вместе с appearance'ами). }

interface

uses
  Classes, SysUtils, Math, fpjson,
  CastleVectors, CastleScene, X3DNodes, X3DFields;

type
  TGpuBikeSpin = class
  private
    FPedalDir: Single;
    FReady: Boolean;
    FBuildCount: Integer;   { сколько раз вызывался Build (диаг продублированных эффектов) }
    { список одноимённых uniform-полей колёсных эффектов —
      Send дублирует значение в каждый }
    FWheelFields: TList;
    FAllEffects: TList;   { все созданные TEffectNode — Scene и SetActive }
    { Общие эффекты на все appearance'ы группы (один Send на группу вместо
      десятков: раньше у каждого appearance'а был свой эффект со своим
      uniform-полем — 63 Send'а на кадр, теперь 4 групповых + 6 полей).
      Кранки — один общий (шейпы RotGroup минус педали);
      колёса — один общий (вращение не зависит от шейпа);
      педали — по эффекту на сторону (запечённый CrankEnd). }
    FSharedCrankEff, FSharedWheelEff: TEffectNode;
    FSharedPedalREff, FSharedPedalLEff: TEffectNode;
    FCrankPhase, FWheelPhase: TSFFloat;
    { педали: 3 float упакованы в один vec3 (phase, ankleFlex, freeMul) —
      1 Send на сторону вместо 3 }
    FPedalUrfR, FPedalUrfL: TSFVec3f;
    { кэш последних отправленных значений — Send только при изменении;
      первый кадр после Build/включения эффектов шлёт всё }
    FLastPhase, FLastWheelPhase, FLastAnkleFlex, FLastFreeR, FLastFreeL: Single;
    FLastValid: Boolean;
    function AddFloat(AEff: TEffectNode; const N: string; V: Single): TSFFloat;
    procedure AttachWheel(AShape: TShapeNode; var Done: TList);
    procedure AttachCrank(AShape: TShapeNode; var Done: TList);
    procedure AttachPedal(AShape: TShapeNode; var Done: TList;
      const CrankEnd: TVector3; IsRight: Boolean);
  public
    constructor Create(APedalDir: Single);
    destructor Destroy; override;
    { Найти именованные трансформы в подграфе ARoot, создать эффекты и
      навесить на шейпы. AScene — сцена-владелец: проставляется эффектам
      вручную (FdEffects.Add её не ставит, а без Scene<>nil Changed поля
      молчит и uniform'ы не доходят до GPU). Возвращает False, если ничего
      не найдено. }
    function Build(ARoot: TX3DNode; AScene: TX3DEventsEngine; ALog: TStrings): Boolean;
    { Покадровая отправка. FreeMulR/L = (1 - LegFreeR/L) — гаситель pitch'а
      платформы для свободной ноги, как в CPU-пути. }
    procedure SendFrame(const Phase, WheelPhase, AnkleFlexDeg,
      FreeMulR, FreeMulL: Single);
    { Вкл/выкл все эффекты (переключение GPU/CPU-пути на лету: на CPU-пути
      вращение делают трансформы, эффект обязан быть выключен, иначе
      двойное вращение поверх DriveSpinNodesCPU). }
    procedure SetActive(AOn: Boolean);
    { Диагностика для MCP bike.wheels_debug: значения uniform-полей,
      состояние эффектов (enabled/scene), счётчик Build. }
    function DebugJson: TJSONObject;
    property Ready: Boolean read FReady;
    function ActiveEffectCount: Integer;
  end;

implementation

uses
  BikeLog,       { StartupLog }
  BikeGfxUtil;   { GNum — GLSL-литералы }

{ Rz(a) как GLSL-выражение над (v): правосторонний поворот о +Z:
  x' = c·x − s·y; y' = s·x + c·y — совпадает с axis-angle (0,0,1,a). }
function RotZExpr(const AExpr, VExpr: string): string;
begin
  Result := '(vec3(' +
    'cos(' + AExpr + ')*' + VExpr + '.x - sin(' + AExpr + ')*' + VExpr + '.y,' +
    'sin(' + AExpr + ')*' + VExpr + '.x + cos(' + AExpr + ')*' + VExpr + '.y,' +
    VExpr + '.z))';
end;

constructor TGpuBikeSpin.Create(APedalDir: Single);
begin
  inherited Create;
  FPedalDir := APedalDir;
  FReady := False;
  FWheelFields := TList.Create;
  FAllEffects := TList.Create;
end;

destructor TGpuBikeSpin.Destroy;
begin
  FWheelFields.Free; FAllEffects.Free;
  inherited;
end;

function TGpuBikeSpin.AddFloat(AEff: TEffectNode; const N: string; V: Single): TSFFloat;
begin
  Result := TSFFloat.Create(AEff, true, N, V);
  AEff.AddCustomField(Result);
end;

{ собрать все TShapeNode поддерева N (включая вложенные трансформы) }
procedure CollectShapes(N: TX3DNode; Out_: TList);
var I: Integer;
begin
  if N = nil then Exit;
  if N is TShapeNode then Out_.Add(N);
  if N is TAbstractGroupingNode then
    for I := 0 to TAbstractGroupingNode(N).FdChildren.Count - 1 do
      CollectShapes(TAbstractGroupingNode(N).FdChildren[I], Out_);
end;

{ общий каркас эффекта создан в Attach*; здесь только навеска }

procedure TGpuBikeSpin.AttachWheel(AShape: TShapeNode; var Done: TList);
var Part: TEffectPartNode; App: TAppearanceNode;
begin
  App := AShape.Appearance;
  if (App = nil) or (Done.IndexOf(App) >= 0) then Exit;
  Done.Add(App);
  if FSharedWheelEff = nil then
  begin
    { общий эффект на все колёсные appearance'ы: одно поле uWheelPhase }
    FSharedWheelEff := TEffectNode.Create;
    FSharedWheelEff.Language := slGLSL;
    FSharedWheelEff.X3DName := 'GpuSpinWheel';
    FWheelPhase := AddFloat(FSharedWheelEff, 'uWheelPhase', 0);
    FWheelFields.Add(FWheelPhase);
    Part := TEffectPartNode.Create;
    Part.FdType.Value := 'VERTEX';
    Part.Contents :=
      'uniform float uWheelPhase;' + LineEnding +
      'void PLUG_vertex_object_space(inout vec4 vertex, inout vec3 normal) {' + LineEnding +
      '  float a = -6.2831853 * uWheelPhase;' + LineEnding +   { axis (0,0,-1), как WheelSpin }
      '  vertex = vec4(' + RotZExpr('a', 'vertex.xyz') + ', vertex.w);' + LineEnding +
      '  normal = ' + RotZExpr('a', 'normal') + ';' + LineEnding +
      '}' + LineEnding;
    FSharedWheelEff.FdParts.Add(Part);
    FAllEffects.Add(FSharedWheelEff);
  end;
  App.FdEffects.Add(FSharedWheelEff);
end;

procedure TGpuBikeSpin.AttachCrank(AShape: TShapeNode; var Done: TList);
var Part: TEffectPartNode; App: TAppearanceNode;
begin
  App := AShape.Appearance;
  if (App = nil) or (Done.IndexOf(App) >= 0) then Exit;
  Done.Add(App);
  if FSharedCrankEff = nil then
  begin
    FSharedCrankEff := TEffectNode.Create;
    FSharedCrankEff.Language := slGLSL;
    FSharedCrankEff.X3DName := 'GpuSpinCrank';
    FCrankPhase := AddFloat(FSharedCrankEff, 'uPhase', 0);
    Part := TEffectPartNode.Create;
    Part.FdType.Value := 'VERTEX';
    Part.Contents :=
      'uniform float uPhase;' + LineEnding +
      'void PLUG_vertex_object_space(inout vec4 vertex, inout vec3 normal) {' + LineEnding +
      '  float a = -6.2831853 * uPhase;' + LineEnding +        { axis (0,0,-1), как CrankSpin }
      '  vertex = vec4(' + RotZExpr('a', 'vertex.xyz') + ', vertex.w);' + LineEnding +
      '  normal = ' + RotZExpr('a', 'normal') + ';' + LineEnding +
      '}' + LineEnding;
    FSharedCrankEff.FdParts.Add(Part);
    FAllEffects.Add(FSharedCrankEff);
  end;
  App.FdEffects.Add(FSharedCrankEff);
end;

procedure TGpuBikeSpin.AttachPedal(AShape: TShapeNode; var Done: TList;
  const CrankEnd: TVector3; IsRight: Boolean);
var Eff: TEffectNode; Part: TEffectPartNode; App: TAppearanceNode;
    A0, Src: string;
begin
  App := AShape.Appearance;
  if (App = nil) or (Done.IndexOf(App) >= 0) then Exit;
  Done.Add(App);
  if IsRight then
  begin
    if FSharedPedalREff = nil then
    begin
      FSharedPedalREff := TEffectNode.Create;
      FPedalUrfR := TSFVec3f.Create(FSharedPedalREff, true, 'uPAF',
        Vector3(0, 0, 1));
      FSharedPedalREff.AddCustomField(FPedalUrfR);
      FAllEffects.Add(FSharedPedalREff);
    end;
    Eff := FSharedPedalREff;
  end else
  begin
    if FSharedPedalLEff = nil then
    begin
      FSharedPedalLEff := TEffectNode.Create;
      FPedalUrfL := TSFVec3f.Create(FSharedPedalLEff, true, 'uPAF',
        Vector3(0, 0, 1));
      FSharedPedalLEff.AddCustomField(FPedalUrfL);
      FAllEffects.Add(FSharedPedalLEff);
    end;
    Eff := FSharedPedalLEff;
  end;
  if Eff.FdParts.Count = 0 then
  begin
    Eff.Language := slGLSL;
    if IsRight then Eff.X3DName := 'GpuSpinPedalR' else Eff.X3DName := 'GpuSpinPedalL';
    A0 := GNum(ArcTan2(CrankEnd.Y, CrankEnd.X));
    Src :=
      'uniform vec3 uPAF;' + LineEnding +
      '#define uPhase uPAF.x' + LineEnding +
      '#define uAnkleFlex uPAF.y' + LineEnding +
      '#define uFreeMul uPAF.z' + LineEnding +
      'const vec2 T = vec2(' + GNum(CrankEnd.X) + ',' + GNum(CrankEnd.Y) + ');' + LineEnding +
      'const float A0 = ' + A0 + ';' + LineEnding +
      'const float DIR = ' + GNum(FPedalDir) + ';' + LineEnding +
      'float gsbAnkleCurve(float crankDeg) {' + LineEnding +   { порт BicycleAnkleFlexCurve (BikeGfxUtil) }
      '  float A = mod(crankDeg, 360.0); if (A < 0.0) A += 360.0;' + LineEnding +
      '  float S = cos(radians(A-' + GNum(ANKLE_CURVE_PHASE1) + ')) + 0.25*cos(radians(2.0*(A-' + GNum(ANKLE_CURVE_PHASE2) + ')));' + LineEnding +
      '  return S >= 0.0 ? uAnkleFlex*(S/' + GNum(ANKLE_CURVE_POS_PEAK) + ') : uAnkleFlex*(S/' + GNum(ANKLE_CURVE_NEG_PEAK) + ');' + LineEnding +
      '}' + LineEnding +
      'void PLUG_vertex_object_space(inout vec4 vertex, inout vec3 normal) {' + LineEnding +
      '  float ac = -6.2831853 * uPhase;' + LineEnding +        { crank spin }
      { PM.Translation (=T) движок применит ПОСЛЕ плага: итог T + v'. Нужно
        Rc·T + Rf·v (Rc·Rp=I)  =>  v' = Rf·v + (Rc−I)·T. Без учёта родительского
        T педаль получала двойное смещение и болталась за концом шатуна. }
      '  vec2 rc = vec2(T.x*cos(ac) - T.y*sin(ac), T.x*sin(ac) + T.y*cos(ac));' + LineEnding +
      '  vec2 off = rc - T;' + LineEnding +
      '  float crankDeg = degrees(A0 + DIR*6.2831853*uPhase);' + LineEnding +
      '  float flex = -radians(gsbAnkleCurve(90.0 - crankDeg)) * uFreeMul;' + LineEnding +
      '  vertex = vec4(' + RotZExpr('flex', 'vertex.xyz') + ' + vec3(off, 0.0), vertex.w);' + LineEnding +
      '  normal = ' + RotZExpr('flex', 'normal') + ';' + LineEnding +
      '}' + LineEnding;
    Part := TEffectPartNode.Create;
    Part.FdType.Value := 'VERTEX';
    Part.Contents := Src;
    Eff.FdParts.Add(Part);
  end;
  App.FdEffects.Add(Eff);
end;

function TGpuBikeSpin.Build(ARoot: TX3DNode; AScene: TX3DEventsEngine; ALog: TStrings): Boolean;
var Done: TList;      { appearance'ы, уже получившие эффект (дедупликация) }
    Found, J: Integer;

  { рекурсивный обход: named-трансформы → эффекты на шейпы поддеревьев.
    ParentT — трансляция ближайшего родительского трансформа (для PM педали). }
  procedure Walk(N: TX3DNode; const ParentT: TVector3);
  var I, K: Integer; TN: TTransformNode; Shapes: TList; NM: string;
      T3: TVector3;
  begin
    if N = nil then Exit;
    if N is TTransformNode then
    begin
      TN := TTransformNode(N);
      NM := TN.X3DName;
      if (NM = 'RearWheelRot') or (NM = 'FrontWheelRot') then
      begin
        Shapes := TList.Create;
        try CollectShapes(TN, Shapes);
          for K := 0 to Shapes.Count - 1 do AttachWheel(TShapeNode(Shapes[K]), Done);
          Inc(Found, Shapes.Count);
        finally Shapes.Free; end;
        Exit;   { внутрь spinning-поддерева не спускаемся }
      end;
      if NM = 'CranksRot' then
      begin
        Shapes := TList.Create;
        try
          { шейпы самого RotGroup минус педальные поддеревья }
          for I := 0 to TN.FdChildren.Count - 1 do
            if (TN.FdChildren[I] is TTransformNode) and
               (TTransformNode(TN.FdChildren[I]).FdChildren.Count > 0) and
               (TTransformNode(TN.FdChildren[I]).FdChildren[0] is TTransformNode) and
               ((TTransformNode(TTransformNode(TN.FdChildren[I]).FdChildren[0]).X3DName = 'PedalRightRot') or
                (TTransformNode(TTransformNode(TN.FdChildren[I]).FdChildren[0]).X3DName = 'PedalLeftRot')) then
              { PM педали — пропускаем (обрабатывается веткой ниже) }
            else
              CollectShapes(TN.FdChildren[I], Shapes);
          for K := 0 to Shapes.Count - 1 do AttachCrank(TShapeNode(Shapes[K]), Done);
          Inc(Found, Shapes.Count);
        finally Shapes.Free; end;
        { педали: PM → PCR('Pedal*Rot'); T = PM.Translation }
        for I := 0 to TN.FdChildren.Count - 1 do
          if TN.FdChildren[I] is TTransformNode then
            Walk(TN.FdChildren[I], TTransformNode(TN.FdChildren[I]).Translation);
        Exit;
      end;
      if (NM = 'PedalRightRot') or (NM = 'PedalLeftRot') then
      begin
        Shapes := TList.Create;
        try CollectShapes(TN, Shapes);
          for K := 0 to Shapes.Count - 1 do
            AttachPedal(TShapeNode(Shapes[K]), Done, ParentT, NM = 'PedalRightRot');
          Inc(Found, Shapes.Count);
        finally Shapes.Free; end;
        Exit;
      end;
      T3 := ParentT;
      if TN.Translation.LengthSqr > 1e-12 then T3 := TN.Translation;
      for I := 0 to TN.FdChildren.Count - 1 do Walk(TN.FdChildren[I], T3);
      Exit;
    end;
    if N is TAbstractGroupingNode then
      for I := 0 to TAbstractGroupingNode(N).FdChildren.Count - 1 do
        Walk(TAbstractGroupingNode(N).FdChildren[I], ParentT);
  end;

begin
  Result := False;
  FReady := False;
  Inc(FBuildCount);
  if ARoot = nil then Exit;
  Done := TList.Create;
  try
    Found := 0;
    { FdEffects.ChangeAlways = chEverything: каждый Attach без schedule
      делает полный ChangedAll (байкфит/старт заезда → фриз nvoglv64). }
    if AScene is TCastleScene then
      TCastleScene(AScene).BeginChangesSchedule;
    try
      Walk(ARoot, TVector3.Zero);
    finally
      if AScene is TCastleScene then
        TCastleScene(AScene).EndChangesSchedule;
    end;
    FReady := Found > 0;
    Result := FReady;
    FLastValid := False;   { первый SendFrame после Build обязан послать все uniform'ы }
    { FdEffects.Add не проставляет ноду Scene, а без неё TX3DField.Changed
      молчит (Parent.Scene=nil) и uniform'ы не доходят до GPU —
      проверено дампом: FCrankPhase.Value менялся, шейдер видел 0. }
    if AScene <> nil then
      for J := 0 to FAllEffects.Count - 1 do
        TEffectNode(FAllEffects[J]).Scene := AScene;
    StartupLog(Format('[gpu-spin] built: %d shape(s), effects: wheel=%d all=%d scene=%s',
      [Found, FWheelFields.Count, FAllEffects.Count,
       BoolToStr(AScene <> nil, True)]));
  finally
    Done.Free;
  end;
end;

procedure TGpuBikeSpin.SendFrame(const Phase, WheelPhase, AnkleFlexDeg,
  FreeMulR, FreeMulL: Single);
var I: Integer;
begin
  if not FReady then Exit;
  { OPT: Send только при изменении (Send = X3D-event + glUseProgram + glUniform).
    Стоящий байк → 0 Send'ов вместо 4+; первый кадр после Build/enable шлёт всё. }
  if (FCrankPhase <> nil) and
     ((not FLastValid) or (Abs(Phase - FLastPhase) > 1e-6)) then
    FCrankPhase.Send(Phase);
  if (not FLastValid) or (Abs(WheelPhase - FLastWheelPhase) > 1e-6) then
    for I := 0 to FWheelFields.Count - 1 do TSFFloat(FWheelFields[I]).Send(WheelPhase);
  if (FPedalUrfR <> nil) and
     ((not FLastValid) or (Abs(Phase - FLastPhase) > 1e-6)
      or (Abs(AnkleFlexDeg - FLastAnkleFlex) > 1e-6)
      or (Abs(FreeMulR - FLastFreeR) > 1e-6)) then
    FPedalUrfR.Send(Vector3(Phase, AnkleFlexDeg, FreeMulR));
  if (FPedalUrfL <> nil) and
     ((not FLastValid) or (Abs(Phase - FLastPhase) > 1e-6)
      or (Abs(AnkleFlexDeg - FLastAnkleFlex) > 1e-6)
      or (Abs(FreeMulL - FLastFreeL) > 1e-6)) then
    FPedalUrfL.Send(Vector3(Phase, AnkleFlexDeg, FreeMulL));
  FLastPhase := Phase; FLastWheelPhase := WheelPhase;
  FLastAnkleFlex := AnkleFlexDeg;
  FLastFreeR := FreeMulR; FLastFreeL := FreeMulL;
  FLastValid := True;
end;

function TGpuBikeSpin.ActiveEffectCount: Integer;
var I: Integer;
begin
  Result := 0;
  for I := 0 to FAllEffects.Count - 1 do
    if TEffectNode(FAllEffects[I]).Enabled then Inc(Result);
end;

procedure TGpuBikeSpin.SetActive(AOn: Boolean);
var I: Integer;
begin
  for I := 0 to FAllEffects.Count - 1 do
    if TEffectNode(FAllEffects[I]).Enabled <> AOn then
      TEffectNode(FAllEffects[I]).Enabled := AOn;
  if AOn then FLastValid := False;   { перестраховка: после enable дослать uniform'ы }
end;

function TGpuBikeSpin.DebugJson: TJSONObject;

  function FieldArr(L: TList): TJSONArray;
  var I: Integer;
  begin
    Result := TJSONArray.Create;
    for I := 0 to L.Count - 1 do
      Result.Add(TSFFloat(L[I]).Value);
  end;

var
  Arr: TJSONArray;
  O: TJSONObject;
  I: Integer;
  Eff: TEffectNode;
begin
  Result := TJSONObject.Create;
  Result.Add('ready', FReady);
  Result.Add('build_count', FBuildCount);
  Result.Add('wheel_phase_fields', FieldArr(FWheelFields));
  if FCrankPhase <> nil then
    Result.Add('crank_phase_field', FCrankPhase.Value);
  if FPedalUrfR <> nil then
    Result.Add('pedal_r', Format('%.3f,%.3f,%.3f',
      [FPedalUrfR.Value.X, FPedalUrfR.Value.Y, FPedalUrfR.Value.Z]));
  if FPedalUrfL <> nil then
    Result.Add('pedal_l', Format('%.3f,%.3f,%.3f',
      [FPedalUrfL.Value.X, FPedalUrfL.Value.Y, FPedalUrfL.Value.Z]));
  Arr := TJSONArray.Create;
  for I := 0 to FAllEffects.Count - 1 do
  begin
    Eff := TEffectNode(FAllEffects[I]);
    O := TJSONObject.Create;
    O.Add('name', Eff.X3DName);
    O.Add('enabled', Eff.Enabled);
    O.Add('scene_assigned', Eff.Scene <> nil);
    Arr.Add(O);
  end;
  Result.Add('effects', Arr);
end;

end.
