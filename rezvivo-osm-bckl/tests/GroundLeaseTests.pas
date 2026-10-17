program GroundLeaseTests;
{$mode objfpc}{$H+}
uses SysUtils,Math,CastleVectors,CastleTransform,GamePhysicsCommon,
  GamePhysicsBase,GamePhysicsKinematic,GamePath,GameAgentControl,
  GamePhysicalAgent,GameAgentControllers,DebugLog;
type
  TGround = class
    Available,OneWheel:Boolean;
    Calls,LogCalls:Integer;
    Grade:Single;
    function Query(X,Z,ReferenceY:Single;out Y:Single):Boolean;virtual;
    function BlockTraffic(Tag:Pointer;const Position,Movement:TVector3;Reserve:Boolean):TVector3;
    procedure OnLog(const S:String);
  end;
  TDelayedGround = class(TGround)
    FrameNumber:Integer;
    Patches:array of record X,Z,ReadyFrame:Integer end;
    function Query(X,Z,ReferenceY:Single;out Y:Single):Boolean;override;
  end;
  TFixture = class
    G:TGround;Actor:TPhysicsActor;State:TPhysicsState;Path:TGamePath;
    Physics:TKinematicActorPhysics;Input:TAgentControlInput;Debug:TPhysicsDebug;
    constructor Create(Ready:Boolean;Grade:Single=0);
    destructor Destroy;override;
    procedure Frame(Dt:Single);
  end;
var Checks:Integer;
procedure Check(B:Boolean;const S:String);
begin Inc(Checks);if not B then raise Exception.Create(S);end;
function TGround.Query(X,Z,ReferenceY:Single;out Y:Single):Boolean;
begin Inc(Calls);Y:=100+Z*Grade;Result:=Available and not(OneWheel and(Z>0));end;
function TGround.BlockTraffic(Tag:Pointer;const Position,Movement:TVector3;Reserve:Boolean):TVector3;
begin Result:=Vector3(0,0,0);end;
procedure TGround.OnLog(const S:String);
begin if(Pos('[KinDiag] ',S)=1)and(Pos('AutoMove=',S)>0)then Inc(LogCalls);end;
function TDelayedGround.Query(X,Z,ReferenceY:Single;out Y:Single):Boolean;
var I,CX,CZ:Integer;
begin
  Result:=inherited Query(X,Z,ReferenceY,Y);if not Result then Exit;
  { CPU fixture models spatial requests completed three render frames later.
    It deliberately cannot satisfy newly requested points synchronously. }
  CX:=Floor(X/2);CZ:=Floor(Z/2);
  for I:=0 to High(Patches)do if(Patches[I].X=CX)and(Patches[I].Z=CZ)then
    Exit(FrameNumber>=Patches[I].ReadyFrame);
  I:=Length(Patches);SetLength(Patches,I+1);
  Patches[I].X:=CX;Patches[I].Z:=CZ;Patches[I].ReadyFrame:=FrameNumber+3;
  Result:=False;
end;
constructor TFixture.Create(Ready:Boolean;Grade:Single);
begin
  inherited Create;G:=TGround.Create;G.Available:=Ready;G.Grade:=Grade;
  Actor:=TPhysicsActor.Create;State:=TPhysicsState.Create;Path:=TGamePath.Create;
  Actor.Transform:=TCastleTransform.Create(nil);
  Path.LoadFromMemory([Vector3(0,0,0),Vector3(0,0,10000)],[0,0]);
  Path.CarrotWobbleEnabled:=False;State.GroundQuery:=@G.Query;
  State.PhysicsLOD:=plFull;State.ShadowPlaneWanted:=False;
  State.AvatarMass:=85;Input.Reset;Input.WantsAutoMove:=True;Input.DesiredPowerWatts:=190;
  Debug:=TPhysicsDebug.Create;
  Physics:=TKinematicActorPhysics.Create(Actor,State,Path,Debug,@Input);
  Physics.Initialize;Physics.InitializeAtStart(100);Physics.StartMoving;
  Physics.UpdateVisualGroundPlacement(1/60);
end;
destructor TFixture.Destroy;
begin Physics.Free;Debug.Free;Actor.Transform.Free;Actor.Free;State.Free;Path.Free;G.Free;inherited;end;
procedure TFixture.Frame(Dt:Single);
var I,N:Integer;
begin N:=Round(Dt*60);for I:=1 to N do Physics.FixedStep(1/60);
  Physics.UpdateVisualGroundPlacement(Dt);end;

procedure MissingAndRecovery;
var F:TFixture;I,Calls:Integer;Start,Stopped,Expected:Single;R:TGroundTrackingReplay;
begin
  F:=TFixture.Create(False,-0.2);
  try
    Check(not GLogEnabled,'test unexpectedly enabled per-frame diagnostics');
    Logger.OnLogMessage:=@F.G.OnLog;
    Check(not F.Physics.GroundPlacementValid,'initial miss became a valid flat plane');
    Calls:=F.G.Calls;
    for I:=1 to 600 do F.Physics.FixedStep(1/60);
    Check(F.G.LogCalls=8,'initial ground hold produces repeated startup diagnostics');
    Check(F.G.Calls=Calls,'initial wait polls ground per fixed step');
    Check((F.State.CumulativeDistance=0)and(F.State.CurrentSpeed=0),'initial missing tile timed out into movement');
    F.G.Available:=True;F.G.OneWheel:=True;F.Physics.UpdateVisualGroundPlacement(1/60);
    Check(not F.Physics.GroundPlacementValid,'one missing wheel became a valid plane');
    F.G.OneWheel:=False;F.Physics.UpdateVisualGroundPlacement(1/60);
    Check(F.Physics.GroundPlacementValid,'completed initial probes did not become ready');
    Check(F.State.CurrentGroundPitch< -5,'downhill fixture did not establish old slope');
    F.State.CurrentSpeed:=12;F.G.Available:=False;Start:=F.State.WorldPosition.Z;
    Calls:=F.G.Calls;Expected:=1.5/Cos(DegToRad(F.State.CurrentGroundPitch));
    for I:=1 to 6000 do F.Physics.FixedStep(1/60);
    Check(F.G.Calls=Calls,'pending movement added fixed-step queries');
    Check(F.State.WorldPosition.Z-Start<=1.5001,'old downhill moved beyond spatial lease');
    Check(Abs(F.State.CumulativeDistance-Expected)<0.002,'odometer does not match accepted slope distance');
    Check(F.State.CurrentSpeed<0.001,'missing downhill keeps accelerating in place');
    Check(F.Physics.GroundLeaseLimitedSteps>5000,'missing ground did not increment physical hold diagnostics');
    Check(F.Physics.GroundLeaseRejectedMeters>0,'rejected ground displacement was not recorded');
    Check(F.State.MovementVelocity.Length<0.001,'waiting retains extrapolation velocity');
    Stopped:=F.State.WorldPosition.Z;
    for I:=1 to 10 do F.Frame(0.8);
    Check(Abs(F.State.WorldPosition.Z-Stopped)<0.0001,'continued missing queries renew old lease');
    R:=F.Physics.CaptureReplay;
    Check(Abs(R.GroundProbePosition.Z-Start)<0.0001,'missing probes moved the ground anchor');
    F.G.Available:=True;F.Frame(0.8);F.Frame(0.8);
    Check(F.State.WorldPosition.Z>Stopped+0.05,'ready query did not release held rider');
    Check(F.State.WorldPosition.Z<Stopped+1.51,'fresh query caused a catch-up teleport');
    Writeln('PASS missing start/both wheels, 100s stale downhill, exact odometer, recovery');
  finally Logger.OnLogMessage:=nil;F.Free;end;
end;

procedure ClipAndReplay;
var F:TFixture;R:TGroundTrackingReplay;V:TVector3;
begin
  F:=TFixture.Create(True);
  try
    R:=F.Physics.CaptureReplay;
    V:=F.Physics.ConstrainGroundMovement(Vector3(0,100,0),Vector3(2,0,2));
    Check(Abs(V.Length-1.5)<0.001,'diagonal clip is not radial');
    V:=F.Physics.ConstrainGroundMovement(Vector3(1.4,100,0),Vector3(-2.8,0,0));
    Check(Abs(V.X+2.8)<0.0001,'movement across valid diameter clipped unnecessarily');
    V:=F.Physics.ConstrainGroundMovement(Vector3(3,100,0),Vector3(-1,0,0));
    Check(V.Length=0,'outside teleport returned toward old plane');
    Check((F.Physics.CaptureReplay.GroundProbePosition-R.GroundProbePosition).Length=0,
      'read-only constraint changed ground anchor');
    Check((F.Physics.GroundLeaseLimitedSteps=0)and(F.Physics.GroundLeaseRejectedMeters=0),
      'read-only clip updated physical hold diagnostics');
    F.Physics.InvalidateGroundPlacement;F.Physics.RestoreReplay(R);
    V:=F.Physics.ConstrainGroundMovement(Vector3(0,100,0),Vector3(0,0,3));
    Check(Abs(V.Z-1.5)<0.001,'replay lost spatial lease');
    F.State.PhysicsLOD:=plMinimal;
    Check(F.Physics.ConstrainGroundMovement(Vector3(0,100,0),Vector3(0,0,3)).Z=3,
      'explicit no-ground LOD contract changed');
    F.State.PhysicsLOD:=plFull;F.State.GroundQuery:=nil;
    Check(F.Physics.ConstrainGroundMovement(Vector3(0,100,0),Vector3(0,0,3)).Z=3,
      'nonstreaming movement changed');
    Writeln('PASS radial/diameter/outside/read-only/replay and explicit no-ground paths');
  finally F.Free;end;
end;

procedure ReadyProvider;
const FPS:array[0..2]of Integer=(30,60,144);
var F:TFixture;Rate,I,Steps:Integer;Before,Distance,Accumulator:Double;R:TGroundTrackingReplay;
begin
  Distance:=0;
  for Rate:=0 to High(FPS)do begin
    F:=TFixture.Create(True,-0.1);
    try
      F.State.CurrentSpeed:=8;Accumulator:=0;Steps:=0;
      for I:=1 to FPS[Rate]*10 do begin
        Accumulator:=Accumulator+1/FPS[Rate];
        while Accumulator+1e-10>=1/60 do begin
          Before:=F.State.CumulativeDistance;
          F.Physics.FixedStep(1/60);Inc(Steps);Accumulator:=Accumulator-1/60;
          Check(F.State.CumulativeDistance>Before,'ready provider unexpectedly held movement');
        end;
        F.Physics.UpdateVisualGroundPlacement(1/FPS[Rate]);
      end;
      Check(Steps=600,'normal frame-rate fixture changed fixed-step count');
      Check(F.Physics.GroundLeaseLimitedSteps=0,'ready 1x provider introduced small ground holds');
      Writeln('ready surface fps=',FPS[Rate],' distance=',F.State.CumulativeDistance:0:6,
        ' grade=',Tan(DegToRad(F.State.CurrentSlopeAngle))*100:0:5);
      if Rate=0 then Distance:=F.State.CumulativeDistance
      else Check(Abs(F.State.CumulativeDistance-Distance)<0.003,'normal 1x sampling changed physical travel');
      R:=F.Physics.CaptureReplay;
      Check(Abs(R.GroundProbePosition.Z-F.State.WorldPosition.Z)<0.001,'fresh plane did not follow');
    finally F.Free;end;
  end;
  Writeln('PASS normal 1x ready surface at 30/60/144 render Hz: ',Distance:0:3,' m');
end;

procedure ShortPendingMomentum;
var F:TFixture;I:Integer;Before,Stopped:Single;R:TGroundTrackingReplay;
begin
  F:=TFixture.Create(True);
  try
    F.State.CurrentSpeed:=12;F.G.Available:=False;Before:=F.State.WorldPosition.Z;
    { A few pending GPU frames are missing data, not a physical obstacle.
      The old code multiplied speed by every clipped displacement fraction. }
    for I:=1 to 15 do F.Physics.FixedStep(1/60);
    Check(F.Physics.GroundLeaseLimitedSteps>0,'short pending fixture did not reach its ground boundary');
    Check(F.State.WorldPosition.Z-Before<=1.5001,'momentum preservation escaped ground lease');
    Check(F.State.CurrentSpeed>11.5,'short GPU wait destroyed cycling momentum');
    Check(F.State.CurrentSpeed<=12.001,'pending ground accumulated propulsion energy');
    Check(F.State.MovementVelocity.Length<0.001,'held position still extrapolates ahead');
    R:=F.Physics.CaptureReplay;
    Check(R.GroundWaitSec>0,'pending wait missing from replay state');
    F.Physics.InvalidateGroundPlacement;
    Check(F.Physics.GroundWaitSeconds=0,'teleport retains old ground wait');
    F.Physics.RestoreReplay(R);
    Check(F.Physics.GroundWaitSeconds=R.GroundWaitSec,'replay changes the remaining momentum hold');
    Stopped:=F.State.WorldPosition.Z;
    F.G.Available:=True;F.Physics.UpdateVisualGroundPlacement(1/60);
    F.Physics.FixedStep(1/60);
    Check(F.State.CurrentSpeed>11.5,'ready ground did not resume with retained momentum');
    Check(F.State.WorldPosition.Z-Stopped>0.18,'ready ground still starts accelerating from rest');
    Check(F.State.WorldPosition.Z-Stopped<0.21,'ready ground catches up rejected distance');
    Check(F.Physics.GroundWaitSeconds=0,'accepted movement did not clear pending wait');
    F.Physics.UpdateVisualGroundPlacement(1/60);Stopped:=F.State.CumulativeDistance;
    F.State.TrafficMoveConstraint:=@F.G.BlockTraffic;
    F.Physics.FixedStep(1/60);
    Check(F.State.CurrentSpeed=0,'ground momentum fix disabled rider collision braking');
    Check(F.State.CumulativeDistance=Stopped,'blocked traffic adds odometer travel');
    Writeln('PASS short pending GPU samples preserve momentum without travel or energy catch-up');
  finally F.Free;end;
end;

procedure AgentExtrapolation;
var G:TGround;A:TPhysicalAgent;C:TPowerController;I:Integer;R:TGroundTrackingReplay;
    P:TAgentReplayState;
begin
  G:=TGround.Create;G.Available:=True;G.Grade:=-0.1;A:=TPhysicalAgent.Create(nil);
  try
    A.Actor.Transform:=TCastleTransform.Create(nil);
    A.Path.LoadFromMemory([Vector3(0,0,0),Vector3(0,0,10000)],[0,0]);
    A.Path.CarrotWobbleEnabled:=False;A.State.GroundQuery:=@G.Query;A.State.ShadowPlaneWanted:=False;
    A.RecreatePhysics(pmKinematicCurrent);A.InitializeAtStart(100);
    C:=TPowerController.Create;C.SetDesiredPower(190);C.SetAutoMove(True);A.SetController(C);
    A.UpdateOffline(1/60,1/60);A.State.CurrentSpeed:=20;G.Available:=False;
    P:=A.CaptureReplay;R:=P.Ground;
    for I:=1 to 100 do begin
      A.UpdateOffline(0.801,1/60,64);
      Check(Abs(A.State.WorldPosition.Z-R.GroundProbePosition.Z)<1.501,'8x substeps escaped lease');
      Check(Abs(A.Actor.Transform.Translation.Z-R.GroundProbePosition.Z)<1.501,'extrapolation escaped lease');
    end;
    G.Available:=True;for I:=1 to 30 do A.UpdateOffline(0.8,1/60,64);
    Check(A.State.CumulativeDistance>10,'8x render queries failed to release movement');
    Writeln('PASS actual agent 8x substeps, render extrapolation and continued recovery');
  finally A.Actor.Transform.Free;A.Free;G.Free;end;
end;

procedure DelayedProvider;
var G:TDelayedGround;A:TPhysicalAgent;C:TPowerController;I,Before:Integer;
    P:TAgentReplayState;Offset:TVector3;
begin
  G:=TDelayedGround.Create;G.Available:=True;G.Grade:=-0.2;A:=TPhysicalAgent.Create(nil);
  try
    A.Actor.Transform:=TCastleTransform.Create(nil);
    A.Path.LoadFromMemory([Vector3(0,0,0),Vector3(0,0,10000)],[0,0]);
    A.Path.CarrotWobbleEnabled:=False;A.State.GroundQuery:=@G.Query;A.State.ShadowPlaneWanted:=False;
    A.RecreatePhysics(pmKinematicCurrent);A.InitializeAtStart(100);
    C:=TPowerController.Create;C.SetDesiredPower(190);C.SetAutoMove(True);A.SetController(C);
    for I:=1 to 240 do begin
      G.FrameNumber:=I;Before:=G.Calls;A.UpdateOffline(0.8,1/60,64);
      { Two wheel contacts plus two road-grade endpoints, once per visual
        probe update; never multiply these by the 48 physics substeps. }
      Check(G.Calls-Before<=4,'pending provider queried in fixed-step loop');
      P:=A.CaptureReplay;
      if P.Ground.SmoothedGroundYValid then begin
        Offset:=A.State.WorldPosition-P.Ground.GroundProbePosition;Offset.Y:=0;
        Check(Offset.Length<=1.501,'delayed provider escaped anchor');
      end;
      if I=8 then A.State.CurrentSpeed:=25;
    end;
    Check(A.State.CumulativeDistance>60,'asynchronous patches deadlocked at the lease boundary');
    Check(Length(G.Patches)>20,'fixture did not cross enough pending patch boundaries');
    Writeln('PASS three-frame asynchronous patches at 8x: ',A.State.CumulativeDistance:0:3,
      ' m, ',Length(G.Patches),' patches');
  finally A.Actor.Transform.Free;A.Free;G.Free;end;
end;

procedure BicycleContacts;
const FPS:array[0..2]of Integer=(30,60,144);
var G:TGround;A:TPhysicalAgent;C:TPowerController;Rate,I,Before:Integer;
    ExpectedY,ExpectedPitch:Single;
begin
  for Rate:=0 to High(FPS)do begin
    G:=TGround.Create;G.Available:=True;A:=TPhysicalAgent.Create(nil);
    try
      A.Actor.Transform:=TCastleTransform.Create(nil);
      A.Path.LoadFromMemory([Vector3(0,0,0),Vector3(0,0,10000)],[0,0]);
      A.Path.CarrotWobbleEnabled:=False;A.State.GroundQuery:=@G.Query;
      A.State.ShadowPlaneWanted:=False;A.State.WheelContactAtOrigin:=True;
      A.RecreatePhysics(pmKinematicCurrent);A.Initialize;A.InitializeAtStart(100);
      C:=TPowerController.Create;C.SetDesiredPower(190);C.SetAutoMove(True);A.SetController(C);
      for I:=1 to FPS[Rate]*3 do begin
        { A change of road inclination must affect both height AND frame
          pitch together, including at render rates above probe throttling. }
        G.Grade:=0.15*Sin(I*0.05);Before:=G.Calls;
        A.UpdateOffline(1/FPS[Rate],1/60,4);
        ExpectedY:=100+A.Actor.Transform.Translation.Z*G.Grade;
        ExpectedPitch:=RadToDeg(ArcTan(G.Grade));
        Check(Abs(A.Actor.Transform.Translation.Y-ExpectedY)<0.0001,'bicycle height lags contact');
        Check(Abs(A.State.CurrentModelPitch-ExpectedPitch)<0.002,Format(
          'bicycle pitch lags contact: frame=%d fps=%d expected=%.6f model=%.6f ground=%.6f dirZ=%.6f',
          [I,FPS[Rate],ExpectedPitch,A.State.CurrentModelPitch,A.State.CurrentGroundPitch,A.State.ForwardDir.Z]));
        Check(G.Calls-Before<=4,'bicycle ground reads multiplied by physics substeps');
      end;
      Check(A.Physics.GroundLeaseLimitedSteps=0,'ready bicycle surface holds movement');
    finally A.Actor.Transform.Free;A.Free;G.Free end;
  end;
  Writeln('PASS bicycle height/pitch contact together at 30/60/144 Hz');
end;

begin MissingAndRecovery;ClipAndReplay;ReadyProvider;ShortPendingMomentum;AgentExtrapolation;DelayedProvider;BicycleContacts;
  Writeln('ALL PASS ',Checks,' assertions');end.
