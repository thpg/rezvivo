unit GameWalkingCamera;
{$mode objfpc}{$H+}
interface
uses Math, CastleVectors;

type
  { Camera state is independent of the avatar transform and its animated
    skeleton. Position, heading and framing have separate response times. }
  TWalkingCamera = class
  private
    FReady, FOverview: Boolean;
    FPosition, FPositionVelocity, FLookAt, FLookVelocity, FLastTarget: TVector3;
    FYaw, FOrbitYaw, FOverviewBlend, FStillTime, FLastHeading: Single;
  public
    procedure Reset;
    procedure Resume(const Target, Forward, Position, Direction: TVector3);
    procedure Update(const Target, Forward: TVector3; Speed, Dt: Single);
    procedure LiftAboveGround(Height: Single);
    function Direction: TVector3;
    property Position: TVector3 read FPosition;
    property Ready: Boolean read FReady;
    property Overview: Boolean read FOverview;
    property StillTime: Single read FStillTime;
  end;

implementation
const
  FollowDistance = 4.5;
  FollowHeight = 2.0;
  AimHeight = 1.05;
  OverviewDelay = 3.0;

function AngleDelta(A: Single): Single;
begin
  Result:=A-Floor((A+Pi)/(2*Pi))*2*Pi;
end;

procedure Spring(var Value,Velocity:Single; Target,SmoothTime,Dt:Single);
var Omega,Decay,Offset,Impulse:Single;
begin
  { Exact critically damped step for a fixed goal, stable at any frame rate. }
  Omega:=2/SmoothTime;Decay:=Exp(-Omega*Dt);
  Offset:=Value-Target;Impulse:=(Velocity+Omega*Offset)*Dt;
  Value:=Target+(Offset+Impulse)*Decay;
  Velocity:=(Velocity-Omega*Impulse)*Decay;
end;

procedure TWalkingCamera.Reset;
begin
  FReady:=False;FOverview:=False;FStillTime:=0;FOverviewBlend:=0;
  FPositionVelocity:=TVector3.Zero;FLookVelocity:=TVector3.Zero;
end;

procedure TWalkingCamera.Resume(const Target,Forward,Position,Direction:TVector3);
var Behind:TVector3;
begin
  Reset;
  FReady:=True;FPosition:=Position;FLastTarget:=Target;
  FLastHeading:=ArcTan2(Forward.X,Forward.Z);
  FLookAt:=Position+Direction*Max(1,(Target+Vector3(0,AimHeight,0)-Position).Length);
  Behind:=Target-Position;Behind.Y:=0;
  if Behind.LengthSqr<0.01 then Behind:=Forward;
  FYaw:=ArcTan2(Behind.X,Behind.Z);FOrbitYaw:=FYaw;
end;

procedure TWalkingCamera.Update(const Target,Forward:TVector3; Speed,Dt:Single);
var Heading,DesiredYaw,Distance,Height,BlendGoal,H:Single;
  Delta,Goal,LookGoal,Back:TVector3;Moving:Boolean;
begin
  Heading:=ArcTan2(Forward.X,Forward.Z);
  Delta:=Target-FLastTarget;
  if not FReady or (Delta.LengthSqr>Sqr(12)) then begin
    { A new scene or teleport must not fly the camera through the world. }
    Reset;FReady:=True;FLastTarget:=Target;
    FYaw:=Heading;FOrbitYaw:=Heading;FLastHeading:=Heading;
    FPosition:=Target-Vector3(Sin(Heading),0,Cos(Heading))*FollowDistance+
      Vector3(0,FollowHeight,0);
    FLookAt:=Target+Vector3(0,AimHeight,0);
    Exit;
  end;
  if Dt<=0 then Exit;
  H:=Dt;
  Delta.Y:=0;
  Moving:=(Abs(Speed)>0.08)or(Delta.Length>Max(0.01,Dt*0.12))or
    (Abs(AngleDelta(Heading-FLastHeading))>Max(0.00001,DegToRad(0.5)*Dt));
  FLastTarget:=Target;FLastHeading:=Heading;
  if Moving then begin FStillTime:=0;FOverview:=False end
  else begin
    FStillTime:=Min(OverviewDelay+1,FStillTime+H);
    if not FOverview and(FStillTime>=OverviewDelay)then begin
      FOverview:=True;FOrbitYaw:=FYaw;
    end;
  end;
  BlendGoal:=Ord(FOverview);
  FOverviewBlend:=FOverviewBlend+(BlendGoal-FOverviewBlend)*(1-Exp(-H/0.75));
  if FOverview then begin
    FOrbitYaw:=AngleDelta(FOrbitYaw+DegToRad(8)*H*FOverviewBlend);
    DesiredYaw:=FOrbitYaw;
  end else DesiredYaw:=Heading;
  FYaw:=AngleDelta(FYaw+AngleDelta(DesiredYaw-FYaw)*(1-Exp(-H/0.45)));
  Distance:=FollowDistance+3.0*FOverviewBlend;
  Height:=FollowHeight+1.2*FOverviewBlend;
  Back:=Vector3(Sin(FYaw),0,Cos(FYaw));
  Goal:=Target-Back*Distance+Vector3(0,Height,0);
  Spring(FPosition.X,FPositionVelocity.X,Goal.X,0.32,H);
  Spring(FPosition.Y,FPositionVelocity.Y,Goal.Y,0.45,H);
  Spring(FPosition.Z,FPositionVelocity.Z,Goal.Z,0.32,H);
  LookGoal:=Target+Vector3(0,AimHeight,0);
  Spring(FLookAt.X,FLookVelocity.X,LookGoal.X,0.16,H);
  Spring(FLookAt.Y,FLookVelocity.Y,LookGoal.Y,0.28,H);
  Spring(FLookAt.Z,FLookVelocity.Z,LookGoal.Z,0.16,H);
end;

procedure TWalkingCamera.LiftAboveGround(Height:Single);
begin
  if Height<=FPosition.Y then Exit;
  FPosition.Y:=Height;
  if FPositionVelocity.Y<0 then FPositionVelocity.Y:=0;
end;

function TWalkingCamera.Direction:TVector3;
begin
  Result:=FLookAt-FPosition;
  if Result.LengthSqr>0.000001 then Result:=Result.Normalize
  else Result:=Vector3(Sin(FYaw),0,Cos(FYaw));
end;
end.
