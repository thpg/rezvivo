program VisualHeadingTests;
{$mode objfpc}{$H+}
uses SysUtils, Math, CastleVectors, CastleTransform, CastleViewport,
  CastleCameras, GamePhysicalAgent, GameAgentControl, GamePhysicsCommon,
  GameCinematicCamera, GamePath;

const Step: Single = 1/60;
type
  TControl = class(TCustomAgentController)
    Moving: Boolean;
    procedure UpdateControl(const Dt: Single; var Input: TAgentControlInput); override;
  end;
  TFixture = class
    Agent: TPhysicalAgent;
    Target: TCastleTransform;
    View: TCastleViewport;
    Camera: TCinematicCamera;
    Control: TControl;
    ReadOnlyHeadingCalls: Integer;
    constructor Create;
    destructor Destroy; override;
    function Ground(X,Z,ReferenceY:Single;out Y:Single):Boolean;
    function BlockHeading(Tag:Pointer;const Position,PreviousDir,ProposedDir:TVector3;
      Commit:Boolean):TVector3;
    procedure Frame(Dt:Single);
  end;
var Measure:Boolean;
procedure Check(B:Boolean;const S:String);
begin if not Measure and not B then raise Exception.Create(S) end;
function Angle(const V:TVector3):Single;
begin Result:=ArcTan2(V.Z,V.X) end;
function Delta(A,B:Single):Single;
begin
  Result:=A-B;
  while Result>Pi do Result:=Result-2*Pi;
  while Result< -Pi do Result:=Result+2*Pi;
end;
procedure TControl.UpdateControl(const Dt:Single;var Input:TAgentControlInput);
begin Input.Reset;Input.WantsAutoMove:=Moving;Input.DesiredPowerWatts:=0 end;
function TFixture.Ground(X,Z,ReferenceY:Single;out Y:Single):Boolean;
begin Y:=0;Result:=True end;
function TFixture.BlockHeading(Tag:Pointer;const Position,PreviousDir,ProposedDir:TVector3;
  Commit:Boolean):TVector3;
begin
  if Commit then Result:=ProposedDir
  else begin Inc(ReadOnlyHeadingCalls);Result:=PreviousDir end;
end;
constructor TFixture.Create;
begin
  inherited;
  Target:=TCastleTransform.Create(nil);Agent:=TPhysicalAgent.Create(nil);
  Agent.SetupActor(Target,nil,nil,nil,nil,nil);
  Agent.Path.LoadFromMemory([Vector3(0,0,0),Vector3(0,0,1000)],[0,0]);
  Agent.State.GroundQuery:=@Ground;Agent.State.ShadowPlaneWanted:=False;
  Agent.RecreatePhysics(pmKinematicCurrent);Agent.Initialize;Agent.InitializeAtStart(0);
  { The real free-travel physics supplies an exactly constant yaw rate, with
    no renderer, GPU, network, bot decisions or frame stalls in the fixture. }
  Agent.State.FreeTravel:=True;Agent.State.Walking:=True;
  Agent.State.TravelSteering:=0.2;Agent.State.TravelTargetSpeed:=2;
  Agent.State.CurrentSpeed:=2;Agent.State.AutoMove:=True;
  Control:=TControl.Create;Control.Moving:=True;Agent.SetController(Control);
  View:=TCastleViewport.Create(nil);
  if View.Camera=nil then begin
    View.Camera:=TCastleCamera.Create(View);View.Items.Add(View.Camera);
  end;
  Camera:=TCinematicCamera.Create;Camera.Setup(View,Target,nil);
  Camera.GroundQuery:=@Ground;Camera.AutoSwitch:=False;Camera.TargetSpeed:=2;
  Camera.Enabled:=True;Frame(Step);
end;
destructor TFixture.Destroy;
begin Camera.Free;View.Free;Agent.Free;Target.Free;inherited end;
procedure TFixture.Frame(Dt:Single);
begin Agent.UpdateOffline(Dt,Step,64);Camera.Update(Dt) end;

procedure ConstantTurn(Fps:Integer;Jitter:Boolean);
var F,Reference:TFixture;I,FlatFrames:Integer;Dt,PrevYaw,PrevCam,Yaw,CamYaw:Single;
  MinRate,MaxRate,MinCam,MaxCam,Rate,Expected,MaxError:Single;
  P,D,U:TVector3;Elapsed:Double;
begin
  F:=TFixture.Create;Reference:=TFixture.Create;
  try
    PrevYaw:=Angle(F.Target.Direction);F.View.Camera.GetView(P,D,U);PrevCam:=Angle(D);
    MinRate:=1e9;MaxRate:=-1e9;MinCam:=1e9;MaxCam:=-1e9;
    MaxError:=0;Elapsed:=Step;FlatFrames:=0;
    for I:=1 to Fps*8 do begin
      Dt:=1/Fps;if Jitter then Dt:=Dt*(0.65+0.7*(I mod 7)/6);
      F.Frame(Dt);Elapsed:=Elapsed+Dt;
      while Reference.Agent.State.SimulationTime+Step*0.5<F.Agent.State.SimulationTime do
      begin
        Reference.Agent.FixedStep(Step);
        Reference.Agent.Physics.UpdateVisualGroundPlacement(Step);
      end;
      Check((Reference.Agent.State.WorldPosition-F.Agent.State.WorldPosition).Length<0.000001,
        'Visual prediction changed the authoritative trajectory');
      Check((Reference.Agent.State.ForwardDir-F.Agent.State.ForwardDir).Length<0.000001,
        'Visual prediction fed back into physics heading');
      Check((F.Agent.BuildNetworkState.ForwardDir-F.Agent.State.ForwardDir).Length<0.000001,
        'Network state contains the predicted display heading');
      Yaw:=Angle(F.Target.Direction);F.View.Camera.GetView(P,D,U);CamYaw:=Angle(D);
      Expected:=Pi/2-Elapsed*1.8*0.2;
      if I>10 then begin
        Rate:=RadToDeg(Delta(Yaw,PrevYaw)/Dt);MinRate:=Min(MinRate,Rate);MaxRate:=Max(MaxRate,Rate);
        if Abs(Rate)<0.01 then Inc(FlatFrames);
        Rate:=RadToDeg(Delta(CamYaw,PrevCam)/Dt);MinCam:=Min(MinCam,Rate);MaxCam:=Max(MaxCam,Rate);
        MaxError:=Max(MaxError,Abs(RadToDeg(Delta(Yaw,Expected))));
      end;
      PrevYaw:=Yaw;PrevCam:=CamYaw;
    end;
    Writeln('fps=',Fps,' jitter=',Jitter,' actor_rate_range=',(MaxRate-MinRate):0:6,
      ' camera_rate_range=',(MaxCam-MinCam):0:6,' heading_error_deg=',MaxError:0:6,
      ' frozen_rotation_frames=',FlatFrames);
    Check(MaxError<0.003,'Rendered heading does not follow continuous simulation time');
    Check(MaxRate-MinRate<0.06,'Fixed-step heading is visible as angular speed steps');
    Check(MaxCam-MinCam<0.12,'Follow camera repeats fixed-step heading quantization');
    Check(FlatFrames=0,'Render frames repeat the previous physics heading during a turn');
  finally Reference.Free;F.Free end;
end;

procedure ReplayAndReset;
var F:TFixture;Saved:TAgentReplayState;CamSaved:TCameraReplayState;
  Expected,PhysExpected:array[1..40]of TVector3;
  I:Integer;D:TVector3;Pos:TPathPosition;Yaw:Single;
begin
  F:=TFixture.Create;
  try
    for I:=1 to 70 do F.Frame(1/144);
    Saved:=F.Agent.CaptureReplay;CamSaved:=F.Camera.CaptureReplay;
    for I:=1 to 40 do begin
      F.Frame(1/144);Expected[I]:=F.Target.Direction;
      PhysExpected[I]:=F.Agent.State.ForwardDir;
    end;
    F.Agent.RestoreReplay(Saved);F.Camera.RestoreReplay(CamSaved);
    for I:=1 to 40 do begin
      F.Frame(1/144);
      Check((Expected[I]-F.Target.Direction).Length<0.000001,'Replay lost fractional heading');
      Check((PhysExpected[I]-F.Agent.State.ForwardDir).Length<0.000001,'Replay changed physics heading');
    end;
    { A zero-time presentation must not accumulate another rotation. }
    D:=F.Target.Direction;
    for I:=1 to 20 do F.Frame(0);
    Check((D-F.Target.Direction).Length<0.000001,'Zero-delta frames accumulate heading');
    F.Control.Moving:=False;F.Frame(1/144);D:=F.Target.Direction;
    for I:=1 to 100 do F.Frame(1/144);
    Check((D-F.Target.Direction).Length<0.000001,'Stopped actor retains angular momentum');
    Pos.Segment:=0;Pos.T:=0.2;F.Agent.TeleportToPath(Pos);
    F.Frame(0);Yaw:=Angle(F.Agent.State.ForwardDir);
    Check(Abs(Delta(Angle(F.Target.Direction),Yaw))<0.00001,'Teleport retained old visual heading');
    Writeln('PASS replay, zero delta, stop and teleport');
  finally F.Free end;
end;

procedure InPlaceAndTraffic;
var F:TFixture;I:Integer;Start,Expected:Single;
begin
  F:=TFixture.Create;
  try
    F.Agent.State.CurrentSpeed:=0;F.Agent.State.TravelTargetSpeed:=0;
    { Cross the signed-angle boundary while rotating in place. }
    F.Agent.State.CurrentYawRad:=-Pi+0.001;
    F.Agent.State.ForwardDir:=Vector3(Cos(F.Agent.State.CurrentYawRad),0,Sin(F.Agent.State.CurrentYawRad));
    F.Frame(Step);Start:=Angle(F.Target.Direction);
    for I:=1 to 100 do F.Frame(1/144);
    Expected:=Start-100/144*1.8*0.2;
    Check(Abs(Delta(Angle(F.Target.Direction),Expected))<0.00002,
      'In-place turn / signed-angle wrap is not continuous');
    F.Agent.State.TrafficHeadingConstraint:=@F.BlockHeading;
    for I:=1 to 10 do begin
      F.Frame(1/144);
      Check((F.Target.Direction-F.Agent.State.ForwardDir).Length<0.000001,
        'Visual turn bypassed the traffic heading constraint');
    end;
    Check(F.ReadOnlyHeadingCalls>0,'Visual heading did not use a read-only collision query');
    Writeln('PASS zero-speed turn, angle wrap and read-only traffic constraint');
  finally F.Free end;
end;

var Fps:Integer;
begin
  Measure:=(ParamCount>0)and(ParamStr(1)='--measure');
  for Fps in [30,35,59,60,90,144] do ConstantTurn(Fps,False);
  ConstantTurn(60,True);ReplayAndReset;InPlaceAndTraffic;
  Writeln('VISUAL_HEADING_OK');
end.
