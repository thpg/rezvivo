unit GamePhysicsEngineRigidBody;

interface

uses
  Math, GamePhysicsBase, GamePhysicsCommon;

type
  TEngineRigidBodyPhysics = class(TCustomActorPhysics)
  public
    procedure Initialize; override;
    procedure InitializeAtStart(const InitialGroundY: Single = NaN); override;
    procedure FixedStep(const FixedDelta: Single); override;
    procedure SyncFromWorld; override;
    function Mode: TPhysicsMode; override;
  end;

implementation

uses
  CastleVectors;

procedure TEngineRigidBodyPhysics.Initialize;
begin
  inherited;

  if Assigned(FActor) and Assigned(FActor.RigidBody) then
    FActor.RigidBody.Exists := true;
end;

procedure TEngineRigidBodyPhysics.InitializeAtStart(const InitialGroundY: Single);
begin
  inherited InitializeAtStart(InitialGroundY);

  if Assigned(FActor) and Assigned(FActor.RigidBody) and Assigned(FActor.Transform) then
  begin
    FActor.RigidBody.Exists := true;
    FActor.Transform.Direction := FState.ForwardDir;
  end;
end;

procedure TEngineRigidBodyPhysics.SyncFromWorld;
begin
  if not Assigned(FActor) then Exit;
  if not Assigned(FActor.Transform) then Exit;
  if not Assigned(FState) then Exit;

  FState.WorldPosition := FActor.Transform.Translation;
  FState.ForwardDir := FActor.Transform.Direction;
  FState.ForwardDir.Y := 0;

  if FState.ForwardDir.Length > 0.001 then
    FState.ForwardDir := FState.ForwardDir.Normalize
  else
    FState.ForwardDir := Vector3(0, 0, 1);

  FState.CurrentYawRad := ArcTan2(FState.ForwardDir.Z, FState.ForwardDir.X);
end;

procedure TEngineRigidBodyPhysics.FixedStep(const FixedDelta: Single);
var
  Accel, TargetSpeed, MoveDist: Single;
  MoveDir: TVector3;
  Vel: TVector3;
begin
  if not Assigned(FActor) then Exit;
  if not Assigned(FActor.Transform) then Exit;
  if not Assigned(FState) then Exit;
  if not Assigned(FPath) then Exit;
  if FPath.PointCount < 2 then Exit;

  ApplyControlInput;
  if not FState.AutoMove then Exit;

  CaptureCameraRelativeState;

  FState.SimulationTime := FState.SimulationTime + FixedDelta;

  SyncFromWorld;

  if UpdateRouteTurnaround(FixedDelta) then
  begin
    {$ifdef CASTLE_UNFINISHED_CHANGE_TRANSFORMATION_BY_FORCE}
    if Assigned(FActor.RigidBody) then
      FActor.RigidBody.LinearVelocity:=Vector3(0,0,0);
    {$endif}
    RestoreCameraRelativeState;
    Exit;
  end;

  { Направление — морковка на палке, как в kinematic }
  MoveDir := FPath.GetSmartRouteDirection(FState.WorldPosition, FState.CurrentSpeed, FixedDelta);
  SmoothRotateToDirection(MoveDir, FixedDelta);
  if Assigned(FProfiler) then FProfiler.Mark('dir');

  Accel := CalculateAcceleration(FixedDelta);
  FState.CurrentSpeed := FState.CurrentSpeed + Accel * FixedDelta;
  if FState.CurrentSpeed < 0 then
    FState.CurrentSpeed := 0;
  if FState.CurrentSpeed > MaxSpeed then
    FState.CurrentSpeed := MaxSpeed;

  TargetSpeed := FState.CurrentSpeed;
  Vel := FState.ForwardDir * TargetSpeed;
  MoveDist := TargetSpeed * FixedDelta;

  if Assigned(FActor.RigidBody) then
  begin
    {$ifdef CASTLE_UNFINISHED_CHANGE_TRANSFORMATION_BY_FORCE}
    FActor.RigidBody.LinearVelocity := Vel;
    {$else}
    FActor.Transform.Translation := FActor.Transform.Translation + Vel * FixedDelta;
    {$endif}
  end
  else
    FActor.Transform.Translation := FActor.Transform.Translation + Vel * FixedDelta;

  FActor.Transform.Direction := FState.ForwardDir;

  { Путь — только морковку двигаем вперёд (без SyncPathPositionToWorldFast) }
  FPath.AdvancePathPosition(MoveDist);
  if Assigned(FProfiler) then FProfiler.Mark('move');

  SyncFromWorld;
  UpdateTrajectoryFromRealVelocity(FixedDelta);

  RestoreCameraRelativeState;
  if Assigned(FProfiler) then FProfiler.Mark('model');
end;

function TEngineRigidBodyPhysics.Mode: TPhysicsMode;
begin
  Result := pmEngineRigidBody;
end;

end.
