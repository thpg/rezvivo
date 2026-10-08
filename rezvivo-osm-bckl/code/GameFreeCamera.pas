{ GameFreeCamera — свободная (облётная) камера.

  Порт схемы управления из Osm3d-студии (TVerticalFlyHandler, 3D-ветка):

    WASD    — полёт в горизонтальной плоскости ОТНОСИТЕЛЬНО взгляда
              (W/S — вперёд/назад по «сплющенному» направлению камеры,
               A/D — строф влево/вправо);
    E / Q   — подъём / спуск строго по мировой вертикали;
    стрелки — поворот (влево/вправо — рыскание, вверх/вниз — тангаж);
    мышь (перетаскивание с зажатой ЛКМ) — поворот;
    колесо  — наезд/отъезд вдоль направления взгляда.

  Крена нет: рыскание всегда идёт вокруг мировой вертикали, поэтому камера
  остаётся «выровненной» на любой ориентации. Никакой привязки к террейну —
  это именно свободная камера, летит куда угодно, в том числе под землю.

  Класс не перехватывает ввод сам: владелец (TViewPlay) вызывает Update
  каждый кадр для клавиатуры, а MouseDragRotate/WheelDolly — из своих
  обработчиков Motion/Press. Так у владельца остаётся полный контроль над
  приоритетом клавиш относительно остальной игровой логики. }
unit GameFreeCamera;

{$mode objfpc}{$H+}

interface

uses
  CastleVectors, CastleTransform, CastleKeysMouse, GameTravel;

type
  {$M+}
  TFreeCameraController = class
  private
    FCamera: TCastleTransform;   { обычно MainViewport.Camera (TCastleCamera —
                                   потомок TCastleTransform); типизуем базой,
                                   чтобы не зависеть от юнита с TCastleCamera }
    FMoveSpeed: Single;
    FRotateSpeed: Single;
    FMoveHold: array[0..2] of THeldMovement;
    FRotateHold: array[0..1] of THeldMovement;
    { Поворот направления взгляда: рыскание вокруг мировой вертикали,
      тангаж вокруг «правого» вектора камеры. После поворота базис
      переортонормируется, чтобы не накапливать крен/дрейф. }
    procedure RotateCamera(const AYaw, APitch: Single);
  public
    constructor Create;
    procedure ResetMovement;

    { Покадровое движение с клавиатуры. APressed — это Container.Pressed
      владельца (набор зажатых клавиш). SecondsPassed — дельта кадра. }
    procedure Update(const APressed: TKeysPressed; const SecondsPassed: Single);

    { Поворот мышью: пиксельная дельта перетаскивания (Position-OldPosition). }
    procedure MouseDragRotate(const ADeltaX, ADeltaY: Single);

    { Наезд/отъезд колесом вдоль взгляда: AScroll = Event.MouseWheelScroll. }
    procedure WheelDolly(const AScroll: Single);
  published
    { Камеру владелец обязан задать перед первым Update (обычно
      MainViewport.Camera — присваивается через неявный upcast). }
    property Camera: TCastleTransform read FCamera write FCamera;

    { Максимальная скорость полёта после разгона, м/с. }
    property MoveSpeed: Single read FMoveSpeed write FMoveSpeed;
    { Скорость поворота стрелками, рад/с. }
    property RotateSpeed: Single read FRotateSpeed write FRotateSpeed;
  end;
  {$M-}

implementation

uses Math;

const
  WORLD_UP: TVector3 = (X: 0; Y: 1; Z: 0);

constructor TFreeCameraController.Create;
begin
  inherited Create;
  { Дефолты из референса. При желании владелец может переопределить через
    свойства (в маленьком игровом мире, возможно, захочется поменьше). }
  FMoveSpeed   := 280.0;
  FRotateSpeed := 1.5;
end;

procedure TFreeCameraController.ResetMovement;
begin
  FillChar(FMoveHold,SizeOf(FMoveHold),0);
  FillChar(FRotateHold,SizeOf(FRotateHold),0);
end;

procedure TFreeCameraController.Update(const APressed: TKeysPressed;
  const SecondsPassed: Single);
var
  Pos, Dir, Right, FlatDir, Movement: TVector3;
  SpeedX,SpeedY,SpeedZ,Yaw,Pitch,FlatLen,MaxAxis,Dt: Single;
begin
  if (FCamera = nil) or (APressed = nil) then begin ResetMovement;Exit end;
  Dt:=EnsureRange(SecondsPassed,0,0.25);
  SpeedX:=HeldMovementSpeed(FMoveHold[0],Ord(APressed[keyD])-Ord(APressed[keyA]),Dt,3,FMoveSpeed,10);
  SpeedY:=HeldMovementSpeed(FMoveHold[1],Ord(APressed[keyE])-Ord(APressed[keyQ]),Dt,3,FMoveSpeed,10);
  SpeedZ:=HeldMovementSpeed(FMoveHold[2],Ord(APressed[keyW])-Ord(APressed[keyS]),Dt,3,FMoveSpeed,10);
  Yaw:=HeldMovementSpeed(FRotateHold[0],Ord(APressed[keyArrowLeft])-Ord(APressed[keyArrowRight]),Dt,0.35,FRotateSpeed,2);
  Pitch:=HeldMovementSpeed(FRotateHold[1],Ord(APressed[keyArrowUp])-Ord(APressed[keyArrowDown]),Dt,0.35,FRotateSpeed,2);

  Pos := FCamera.Translation;
  Dir := FCamera.Direction;

  { Горизонтальная проекция направления — по ней идут W/S; A/D — строф
    вдоль «правого» вектора. Так полёт всегда параллелен земле, а высоту
    меняют только E/Q. }
  FlatDir := Vector3(Dir.X, 0, Dir.Z);
  FlatLen := Sqrt(FlatDir.X * FlatDir.X + FlatDir.Z * FlatDir.Z);
  if FlatLen < 1.0e-6 then
    FlatDir := Vector3(0, 0, -1)          { смотрим вертикально: берём любой азимут }
  else
    FlatDir := FlatDir * (1.0 / FlatLen);

  Right := TVector3.CrossProduct(FlatDir, WORLD_UP);

  Movement:=FlatDir*SpeedZ+Right*SpeedX+WORLD_UP*SpeedY;
  MaxAxis:=Max(Abs(SpeedX),Max(Abs(SpeedY),Abs(SpeedZ)));
  { No diagonal boost. A newly pressed direction has its own slow start,
    without resetting acceleration along a direction that is still held. }
  if Movement.Length>1E-6 then Movement:=Movement*(MaxAxis/Movement.Length);
  Pos:=Pos+Movement*Dt;

  FCamera.Translation := Pos;

  if (Yaw<>0)or(Pitch<>0)then RotateCamera(Yaw*Dt,Pitch*Dt);
end;

procedure TFreeCameraController.RotateCamera(const AYaw, APitch: Single);
var
  Pos, Dir, Right, Up: TVector3;
  Len: Single;
begin
  if FCamera = nil then Exit;

  Pos := FCamera.Translation;
  Dir := FCamera.Direction;

  { Рыскание — вокруг мировой вертикали (без крена). }
  if Abs(AYaw) > 1.0e-7 then
    Dir := RotatePointAroundAxis(
      Vector4(WORLD_UP.X, WORLD_UP.Y, WORLD_UP.Z, AYaw), Dir);

  { «Правый» вектор — горизонтальная нормаль к взгляду; вокруг него тангаж. }
  Right := TVector3.CrossProduct(Vector3(Dir.X, 0, Dir.Z), WORLD_UP);
  Len := Right.Length;
  if Len < 1.0e-6 then Right := Vector3(1, 0, 0)
  else Right := Right * (1.0 / Len);

  if Abs(APitch) > 1.0e-7 then
    Dir := RotatePointAroundAxis(
      Vector4(Right.X, Right.Y, Right.Z, APitch), Dir);

  { Переортонормировка базиса, чтобы не копить ошибки/крен. }
  Len := Dir.Length;
  if Len < 1.0e-6 then Dir := Vector3(0, 0, -1)
  else Dir := Dir * (1.0 / Len);

  Right := TVector3.CrossProduct(Vector3(Dir.X, 0, Dir.Z), WORLD_UP);
  Len := Right.Length;
  if Len < 1.0e-6 then Right := Vector3(1, 0, 0)
  else Right := Right * (1.0 / Len);

  Up := TVector3.CrossProduct(Right, Dir);
  Len := Up.Length;
  if Len < 1.0e-6 then Up := WORLD_UP
  else Up := Up * (1.0 / Len);

  FCamera.SetView(Pos, Dir, Up);
end;

procedure TFreeCameraController.MouseDragRotate(const ADeltaX, ADeltaY: Single);
const
  MOUSE_ROTATE_SPEED = 0.006;
begin
  { Тянем вправо → камера поворачивается вправо; тянем вниз → смотрим ниже. }
  RotateCamera(-ADeltaX * MOUSE_ROTATE_SPEED, -ADeltaY * MOUSE_ROTATE_SPEED);
end;

procedure TFreeCameraController.WheelDolly(const AScroll: Single);
begin
  if FCamera = nil then Exit;
  FCamera.Translation := FCamera.Translation +
    FCamera.Direction * (Min(Max(FMoveSpeed,0),3.0) * 0.5 * AScroll);
end;

end.
