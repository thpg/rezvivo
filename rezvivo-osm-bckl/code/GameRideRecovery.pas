unit GameRideRecovery;
{$mode objfpc}{$H+}
interface
uses fpjson, GamePhysicalAgent;
function CaptureRidePosition(Agent:TPhysicalAgent):TJSONObject;
procedure RestoreRidePosition(Agent:TPhysicalAgent;O:TJSONObject);
implementation
uses SysUtils,Math,CastleVectors;
function CaptureRidePosition(Agent:TPhysicalAgent):TJSONObject;
var S:TAgentReplayState;
begin
  S:=Agent.CaptureReplay;
  Result:=TJSONObject.Create(['points',Agent.Path.PointCount,
    'segment',S.Path.Position.Segment,'t',S.Path.Position.T,'turnaround',S.Path.TurnaroundIndex,
    'x',S.Physics.WorldPosition.X,'y',S.Physics.WorldPosition.Y,'z',S.Physics.WorldPosition.Z,
    'yaw',S.Physics.CurrentYawRad,'distance',S.Physics.CumulativeDistance,
    'forward_x',S.Physics.ForwardDir.X,'forward_y',S.Physics.ForwardDir.Y,'forward_z',S.Physics.ForwardDir.Z,
    'ground_y',S.Ground.SmoothedGroundY,'pitch',S.Physics.CurrentModelPitch]);
end;
procedure RestoreRidePosition(Agent:TPhysicalAgent;O:TJSONObject);
var S:TAgentReplayState;P:TVector3;Yaw:Double;
begin
  if(Agent=nil)or(O=nil)then raise Exception.Create('Saved rider is unavailable');
  if Agent.Path.PointCount<>O.Get('points',0)then raise Exception.Create('The saved route has changed');
  P:=Vector3(O.Get('x',0.0),O.Get('y',0.0),O.Get('z',0.0));Yaw:=O.Get('yaw',0.0);
  if IsNan(P.X)or IsNan(P.Y)or IsNan(P.Z)or IsInfinite(P.X)or IsInfinite(P.Y)or IsInfinite(P.Z)
    or IsNan(Yaw)or IsInfinite(Yaw)then raise Exception.Create('Invalid saved position');
  S:=Agent.CaptureReplay;
  S.Path.Position.Segment:=O.Get('segment',0);S.Path.Position.T:=EnsureRange(O.Get('t',0.0),0.0,1.0);
  S.Path.Position:=Agent.Path.ClampPathPosition(S.Path.Position);S.Path.TurnaroundIndex:=O.Get('turnaround',-1);
  S.Physics.WorldPosition:=P;S.Physics.PrevWorldPosition:=P;
  S.Physics.ForwardDir:=Vector3(O.Get('forward_x',0.0),O.Get('forward_y',0.0),O.Get('forward_z',-1.0));
  S.Path.SmoothedRouteDir:=S.Physics.ForwardDir;
  S.Physics.CurrentYawRad:=Yaw;S.Physics.CumulativeDistance:=Max(0,O.Get('distance',0.0));
  S.Physics.CurrentSpeed:=0;S.Physics.MovementVelocity:=Vector3(0,0,0);S.Physics.RealVelocity:=Vector3(0,0,0);
  S.Physics.TrajectorySampleCount:=0;S.Physics.TrajectorySampleIndex:=0;S.Physics.AppliedPowerWatts:=0;
  S.Physics.FrontGroundPointValid:=False;S.Physics.RearGroundPointValid:=False;
  S.Physics.CurrentModelPitch:=O.Get('pitch',0.0);S.Physics.TargetModelPitch:=S.Physics.CurrentModelPitch;
  S.Ground.SmoothedGroundY:=O.Get('ground_y',P.Y);S.Ground.SmoothedGroundYValid:=True;
  S.Ground.GroundProbePosition:=P;S.Ground.GroundGradient:=Vector3(0,0,0);S.Ground.YawRateValid:=False;
  S.ControlInput.Reset;S.Physics.AutoMove:=False;S.Translation:=P;
  S.Rotation:=Vector4(0,1,0,Yaw);S.PhysicsTranslation:=P;S.VisualExtrapolated:=False;
  Agent.RestoreReplay(S);
end;
end.
