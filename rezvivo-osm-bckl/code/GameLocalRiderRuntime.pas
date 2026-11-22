unit GameLocalRiderRuntime;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses Classes,SysUtils,fpjson,CastleUIControls,CastleViewport,CastleScene,CastleTransform,
  CastleVectors,GamePhysicalAgent,GameAgentControllers,GameWorld,GamePath,GameTravel,
  BikeParametric,GameBLEHud,GameRiderPoseControl,GameRideMetricsHud,GameWorkoutHud,
  GameDeviceService,GameWorkoutPlayer,GameRideHistory,GameRemoteRiders,GamePhysicsCommon;
type
  { One local participant, including guests. The world owns physical agents;
    FreeAtStop owns scene/UI components. This class owns the plain bike, pose
    and telemetry objects and the participant's entire ride lifecycle. }
  TLocalRiderRuntime=class
  private
    FIndex:Integer;
    FEnded:Boolean;
    FSimAccountedUntil:Double;
    FSteering:Single;
    procedure FinishClick(Sender:TObject);
  public
    Agent:TPhysicalAgent;
    Controller:TPlayerAgentController;
    Bike:TBikeInstance;
    Pose:TRiderPoseManager;
    Hud:TBLEHudUpdater;
    Metrics:TRideMetricsHud;
    WorkoutHud:TWorkoutHud;
    Publisher:TRemoteRidersManager;
    RoomRetryAt:QWord;
    constructor Create(Index:Integer);
    destructor Destroy;override;
    procedure Bind(AAgent:TPhysicalAgent;AController:TPlayerAgentController;
      ABike:TBikeInstance;APose:TRiderPoseManager;AHud:TBLEHudUpdater;
      AMetrics:TRideMetricsHud;AWorkoutHud:TWorkoutHud);
    procedure CreateParticipant(Owner:TComponent;View:TCastleView;Viewport:TCastleViewport;
      Level:TCastleScene;World:TGameWorld;Template:TPhysicalAgent;Count:Integer);
    procedure SyncBikeFit;
    procedure BeforePhysics(Ready,Manual:Boolean;Mode:TTravelMode;Animate:Boolean);
    procedure UpdateSteering(Dt:Single;Enabled:Boolean;Lanes:TLaneManager);
    procedure TrainerStep(Seconds:Single;Mode:TTravelMode);
    function Situation(Manual:Boolean;ManualWatts:Single):TRiderSituation;
    procedure Animate(Seconds:Single;const S:TRiderSituation;Spin:Boolean=True);
    procedure BeginRide(const Title,Route,WorldId:String;CopyWorkout:Boolean);
    procedure FinishFrame(Seconds,WallSeconds:Single;Ready,Manual,ShowWorkout:Boolean;
      Mode:TTravelMode;UpdateLabels:Boolean=True);
    procedure Restore;
    procedure Checkpoint(Ready,Manual,Focus:Boolean);
    procedure FinishRide;
    function Devices:TGameDeviceService;
    function Workout:TWorkoutPlayer;
    function History:TRideHistory;
    property Index:Integer read FIndex;
    property Ended:Boolean read FEnded;
    property SimAccountedUntil:Double read FSimAccountedUntil write FSimAccountedUntil;
  end;
procedure ApplyBikePhysicsToAgent(ABike:TBikeInstance;AAgent:TPhysicalAgent;
  UseLocalRider:Boolean=False;ProfileIndex:Integer=0);
procedure ApplySteerFromPhysics(ABike:TBikeInstance;AAgent:TPhysicalAgent);
implementation
uses Math,DebugLog,AppSettings,GameUserData,GameBikeAvatar,
  GameAgentNetwork,GameSensorLog,GameDailyTraining,GameActivityAccounting,
  GameRideRecovery,RideUploadQueue,TrainerData,GameSimReplay,
  BikeParametric_Animation,EliteSterzoProtocol,GameRideRooms;
procedure ApplyBikePhysicsToAgent(ABike: TBikeInstance; AAgent: TPhysicalAgent;UseLocalRider:Boolean;ProfileIndex:Integer);
var
  Anim: TAnimationComponent;
  Mass, Cd, Area, Crr: Single;
begin
  if not Assigned(AAgent) then Exit;
  if not Assigned(AAgent.State) then Exit;
  try
    if ABike <> nil then
      Anim := ABike.Component(TAnimationComponent) as TAnimationComponent
    else
      Anim := nil;

    if (Anim <> nil) and (Anim.RiderWeight > 1.0) then
      Mass := Anim.RiderWeight
    else
      Mass := DefaultMass;
    if UseLocalRider and(EffectiveRiderProfile(ProfileIndex).WeightKg>0)then Mass:=EffectiveRiderProfile(ProfileIndex).WeightKg;
    if (Anim <> nil) and (Anim.BikeWeight > 0.1) then
      Mass := Mass + Anim.BikeWeight;

    if (Anim <> nil) and (Anim.DragCoefficient > 0.01) then
      Cd := Anim.DragCoefficient
    else
      Cd := DefaultDragCoefficient;

    if (Anim <> nil) and (Anim.FrontalArea > 0.01) then
      Area := Anim.FrontalArea
    else
      Area := DefaultFrontalArea;

    if (Anim <> nil) and (Anim.RollingResistance > 0.0001) then
      Crr := Anim.RollingResistance
    else
      Crr := DefaultRollingResistance;

    AAgent.State.AvatarMass := Mass;
    AAgent.State.DragCoefficient := Cd;
    AAgent.State.FrontalArea := Area;
    AAgent.State.RollingResistance := Crr;
    if ABike<>nil then begin
      AAgent.State.CollisionBodyHeight:=ABike.BodyParameters.HeightCm*0.01;
      AAgent.State.CollisionHalfWidth:=0.36*
        EnsureRange(AAgent.State.CollisionBodyHeight/1.78,0.85,1.2);
    end;

    Logger.Info('[Physics] ' + Format(
      'Applied to "%s": mass=%.1fkg Cd=%.2f A=%.2fm² Crr=%.4f CdA=%.3f',
      [AAgent.Name, Mass, Cd, Area, Crr, Cd * Area]));
  except
    on E: Exception do
      Logger.Info('[Physics] ' + 'Failed to apply bike params to "' +
        AAgent.Name + '": ' + E.Message);
  end;
end;

{ Kinematic bicycle: tan(δ) ≈ L · κ. Positive curvature turns +X toward +Z;
  the upward steerer axis therefore needs a negative SteerAngleDeg.
  Positive local +X roll banks toward that same +Z direction.
  At near-zero curvature falls
  back to a small lean-proportional angle so slow turns still show bar input. }
procedure ApplySteerFromPhysics(ABike: TBikeInstance; AAgent: TPhysicalAgent);
const
  MaxSteerDeg = 40.0;
  LeanToSteerAtLowSpeed = 0.35;   { δ ≈ 0.35 · lean when path κ is tiny }
var
  WB, Steer, V, G: Single;
  S: TPhysicsState;
begin
  if (ABike = nil) or (AAgent = nil) or (AAgent.State = nil) then Exit;
  S := AAgent.State;
  WB := ABike.AxleHalfSpanM * 2.0;
  if WB < 0.3 then WB := DefaultWheelbase;
  if Abs(S.CurrentCurvature) > 1e-5 then
    Steer := -RadToDeg(ArcTan(WB * S.CurrentCurvature))
  else if Assigned(AAgent.Actor)and AAgent.Actor.RiderOwnsLean then
    { Body roll also contains pedal balance. It is not route curvature and
      must not feed back into steering on a straight road. }
    Steer:=0
  else
  begin
    { Low-speed / straight: couple bars lightly to lean so they don't stay
      glued straight while the bike is banked. }
    V := S.CurrentSpeed;
    if V < 0.5 then V := 0.5;
    G := 9.81;
    if Abs(S.CurrentTurnAngle) > 0.05 then
      Steer := -RadToDeg(ArcTan(
        (WB * G * Tan(DegToRad(S.CurrentTurnAngle))) / Sqr(V)))
    else
      Steer := 0;
    { Soft blend toward lean-proportional when the kinematic estimate is
      large at very low speed (unstable division). }
    if V < 2.0 then
      Steer := Steer * (V / 2.0) +
        (-S.CurrentTurnAngle * LeanToSteerAtLowSpeed) * (1.0 - V / 2.0);
  end;
  if Steer > MaxSteerDeg then Steer := MaxSteerDeg
  else if Steer < -MaxSteerDeg then Steer := -MaxSteerDeg;
  ABike.SteerAngleDeg := Steer;
end;


constructor TLocalRiderRuntime.Create(Index:Integer);
begin inherited Create;FIndex:=Index;FEnded:=True;end;

procedure TLocalRiderRuntime.Bind(AAgent:TPhysicalAgent;AController:TPlayerAgentController;
  ABike:TBikeInstance;APose:TRiderPoseManager;AHud:TBLEHudUpdater;
  AMetrics:TRideMetricsHud;AWorkoutHud:TWorkoutHud);
begin
  FEnded:=False;Agent:=AAgent;Controller:=AController;Bike:=ABike;Pose:=APose;Hud:=AHud;
  Metrics:=AMetrics;WorkoutHud:=AWorkoutHud;
end;

procedure TLocalRiderRuntime.CreateParticipant(Owner:TComponent;View:TCastleView;
  Viewport:TCastleViewport;Level:TCastleScene;World:TGameWorld;
  Template:TPhysicalAgent;Count:Integer);
var Root:TCastleTransform;Scene:TCastleScene;Labels:THudLabels;LocalOwner:TComponent;
begin
  LocalOwner:=TComponent.Create(Owner);Owner:=LocalOwner;
  Root:=TCastleTransform.Create(Owner);Root.Name:='LocalRiderRoot'+IntToStr(FIndex+1);
  Scene:=TCastleScene.Create(Owner);Scene.Name:='LocalRiderScene'+IntToStr(FIndex+1);
  Root.Add(Scene);Viewport.Items.Add(Root);Scene.Pickable:=False;Scene.Collides:=False;
  Bike:=LoadActiveBikeInstance(Owner,12,30,65,FIndex);Scene.Add(Bike.Group);
  Pose:=TRiderPoseManager.Create(Bike,Cardinal(FIndex+1)*7919);
  Controller:=TPlayerAgentController.Create;
  Agent:=TPhysicalAgent.Create(Owner);Agent.Name:=LocalRider(FIndex).DisplayName;
  Agent.SetupActor(Root,Scene,nil,Viewport,nil,Level);Agent.SetController(Controller);
  Template.Path.CopyTo(Agent.Path);Agent.RecreatePhysics(pmKinematicCurrent);
  Agent.State.WheelContactAtOrigin:=True;
  Agent.NetworkAuthority:=naLocalOnly;World.AddAgent(Agent);World.RegisterAgentInNetwork(Agent);
  SyncBikeFit;Agent.Initialize;Agent.InitializeAtStart;
  Hud:=TBLEHudUpdater.Create(FIndex);Hud.Reset;
  Metrics:=TRideMetricsHud.Create(Owner);Metrics.ProfileIndex:=FIndex;
  View.InsertFront(Metrics);Metrics.SetGridSlot(FIndex,Count);Labels:=Metrics.Labels;
  Hud.SetLabels(Labels);
  WorkoutHud:=TWorkoutHud.Create(Owner);WorkoutHud.ProfileIndex:=FIndex;
  WorkoutHud.OnFinishRide:=@FinishClick;View.InsertFront(WorkoutHud);
  Bike.AnimateFrame(Single(0));
end;

procedure TLocalRiderRuntime.SyncBikeFit;
begin
  ApplyBikePhysicsToAgent(Bike,Agent,True,FIndex);
  if(Bike<>nil)and(Agent<>nil)and(Agent.Physics<>nil)then
    Agent.Physics.SetWheelProbeHalfSpan(Bike.AxleHalfSpanM);
  if(Pose<>nil)and(Bike<>nil)then
    Pose.OverlayKneeAnkle(Bike.TripoKneeFlare,Bike.TripoAnkleFlex);
end;

function TLocalRiderRuntime.Devices:TGameDeviceService;
begin Result:=DeviceService.ForRider(FIndex) end;
function TLocalRiderRuntime.Workout:TWorkoutPlayer;
begin Result:=WorkoutPlayerForRider(FIndex) end;
function TLocalRiderRuntime.History:TRideHistory;
begin Result:=RideHistoryForRider(FIndex) end;

procedure TLocalRiderRuntime.BeforePhysics(Ready,Manual:Boolean;Mode:TTravelMode;Animate:Boolean);
begin
  if(Agent=nil)or(Hud=nil)or FEnded then Exit;
  if(Mode=travelBicycle)and not Manual then begin
    Hud.UpdateBLETelemetry(Agent);
    Controller.SetDesiredPower(Agent.State.AppliedPowerWatts);
    if Ready and Hud.ReadMeasuredPower.Valid and(Agent.State.AppliedPowerWatts>0)then
      Controller.SetAutoMove(True);
  end;
  if not Ready then begin Controller.SetAutoMove(False);Agent.State.AutoMove:=False end;
  Agent.Actor.RiderOwnsLean:=(Mode=travelBicycle)and(Bike<>nil)and
    Animate and Bike.BodyDynamicsEnabled and Bike.HasTripoRider;
end;

procedure TLocalRiderRuntime.TrainerStep(Seconds:Single;Mode:TTravelMode);
begin
  if Hud=nil then Exit;
  if not FEnded and(Mode=travelBicycle)and
    ((WorkoutHud=nil)or not WorkoutHud.ControlsTrainer)then
    Hud.UpdateBLETrainerControl(Agent,Seconds)
  else Hud.SuspendTrainerControl;
end;

procedure TLocalRiderRuntime.UpdateSteering(Dt:Single;Enabled:Boolean;Lanes:TLaneManager);
var Axis:Single;Turn:Integer;Active:Boolean;
begin
  if Agent=nil then Exit;
  Active:=Enabled and not FEnded;
  if Active then Active:=Devices.ReadSteeringInput(Axis,Turn)
  else Devices.ResetSteeringInput;
  if Active then FSteering:=SmoothSteering(FSteering,Axis,Dt)else FSteering:=0;
  if Agent.State.FreeTravel then Agent.State.TravelSteering:=FSteering
  else if Lanes<>nil then Lanes.SetSteering(Lanes.FindRider(Agent),Active,FSteering);
end;

function TLocalRiderRuntime.Situation(Manual:Boolean;ManualWatts:Single):TRiderSituation;
var Cadence:Single;
begin
  Result:=Default(TRiderSituation);if(Agent=nil)or(Bike=nil)or FEnded then Exit;
  Cadence:=Hud.BLEData.InstantCadence;
  if Manual then
    if ManualWatts>0 then Cadence:=EnsureRange(55+ManualWatts*0.1,55,115)else Cadence:=0;
  Result.CadenceRpm:=Bike.VisualCadence(Cadence,Agent.State.CurrentSpeed);
  Result.SpeedKmh:=Agent.State.CurrentSpeed*3.6;
  Result.PowerW:=Agent.State.AppliedPowerWatts;
  if not Agent.State.AutoMove and(Result.CadenceRpm<4)then Result.PowerW:=0;
  Result.GradePct:=SlopeDegToGradePct(Agent.State.CurrentSlopeAngle);
  Result.LateralAccel:=Agent.State.CurrentSpeed*Agent.State.CurrentYawRateRad;
  Result.FtpW:=EffectiveRiderProfile(FIndex).FtpW;
end;

procedure TLocalRiderRuntime.Animate(Seconds:Single;const S:TRiderSituation;Spin:Boolean);
var Crank:Single;
begin
  if(Agent=nil)or(Bike=nil)then Exit;
  Bike.GroundTurn:=Agent.State.GroundTurn.Frame;
  if S.CadenceRpm>0 then Crank:=60/S.CadenceRpm else Crank:=9999;
  if Spin then begin Bike.SetAnimationSpeed(Crank,Crank);Bike.SetWheelSpeedMps(Agent.State.CurrentSpeed) end;
  if Agent.Actor.RiderOwnsLean then
    Bike.SetRiderDynamicsSituation(S.PowerW,S.LateralAccel,0,Agent.State.CurrentModelPitch)
  else Bike.SetRiderDynamicsSituation(S.PowerW,S.LateralAccel,
    Agent.State.CurrentTurnAngle,Agent.State.CurrentModelPitch);
  if Pose<>nil then Pose.Update(Seconds,S);
  Bike.AnimateFrame(Seconds);
  if Agent.Actor.RiderOwnsLean then begin
    Agent.State.CurrentTurnAngle:=Bike.RiderTotalLeanDeg;
    Agent.State.TargetTurnAngle:=Agent.State.CurrentTurnAngle;
  end;
end;

procedure TLocalRiderRuntime.BeginRide(const Title,Route,WorldId:String;CopyWorkout:Boolean);
var Reference:Double;
begin
  FEnded:=False;FSimAccountedUntil:=0;RoomRetryAt:=0;Devices.ResetSession;
  if CopyWorkout and(FIndex<>0)then begin
    Workout.Stop;
    if WorkoutPlayer.Plan<>nil then begin
      Reference:=0;
      if WorkoutPlayer.InitialReferenceWatts>0 then begin
        Reference:=EffectiveRiderProfile(FIndex).FtpW;
        { An unconfigured guest has no FTP yet. Keep the selected workout's
          reference instead of silently converting its relative targets to 0. }
        if Reference<=0 then Reference:=WorkoutPlayer.InitialReferenceWatts;
      end;
      Workout.Start(WorkoutPlayer.Plan,Reference,Reference>0,Reference>0);
    end;
  end;
  History.BeginRide(Title,Route,WorldId);
  if Agent<>nil then History.RebaseDistance(Agent.State.CumulativeDistance);
  if Workout.Plan<>nil then History.SetWorkout(Workout.Plan.Name,Workout.Plan.Url);
end;

procedure TLocalRiderRuntime.FinishFrame(Seconds,WallSeconds:Single;
  Ready,Manual,ShowWorkout:Boolean;Mode:TTravelMode;UpdateLabels:Boolean);
var Accounting:TActivityAccounting;Paused:Boolean;Cur,Total:Integer;D:TTrainerDataRecord;
  MetricsSeconds:Double;Journal:TSensorLog;
begin
  if(Agent=nil)or(Hud=nil)or FEnded then Exit;
  MetricsSeconds:=Seconds;
  if Devices.IsSimulationActive then begin
    MetricsSeconds:=Min(Seconds,Max(0,Devices.SimPositionSec-FSimAccountedUntil));
    FSimAccountedUntil:=Max(FSimAccountedUntil,Devices.SimPositionSec);
  end;
  Journal:=SensorLogForRider(FIndex);
  Journal.RecordingEnabled:=(Mode=travelBicycle)and not Manual and
    (not Devices.IsSimulationActive or(Devices.SimPositionSec>=FSimAccountedUntil));
  Journal.UseActivityClock;
  if(WorkoutHud<>nil)and(Mode=travelBicycle)then
    WorkoutHud.Step(MetricsSeconds,Ready and not Manual,ShowWorkout);
  Paused:=False;
  if Devices.IsSimulationActive then Devices.SimPlayerInfo(Paused,Cur,Total);
  Accounting:=ActivityAccounting(Ready and(Mode=travelBicycle)and not Manual and
    not History.RestoreNeeded,Paused,Workout.State in[wsReady,wsRunning,wsPaused],
    Workout.State=wsRunning,Agent.State.CurrentSpeed,Hud.ReadMeasuredPower);
  Journal.SetSessionState(Accounting.Running,Workout.JournalLap,
    EnsureRange(Round(Workout.TargetWatts),0,65535));
  if Ready and(Mode=travelBicycle)and not History.RestoreNeeded then begin
    D:=Hud.BLEData;D.InstantPower:=JournalPower(Accounting.Power);
    D.InstantSpeed:=Agent.State.CurrentSpeed*3.6;
    D.Distance:=Round(Agent.State.CumulativeDistance);
    Journal.LogFrame(D,SlopeDegToGradePct(Agent.State.CurrentSlopeAngle),MetricsSeconds,
      Devices.ActivitySourceFlags);
  end;
  History.Step(MetricsSeconds,Agent.State.CumulativeDistance,Agent.State.WorldPosition.Y,
    Accounting.Power.Watts,EffectiveRiderProfile(FIndex).FtpW,Accounting.Running,Accounting.Power.Valid);
  Hud.UpdatePowerMetrics(MetricsSeconds,Accounting,WallSeconds);
  if UpdateLabels then Hud.UpdateInfoLabels(Agent,nil);
end;

procedure TLocalRiderRuntime.Checkpoint(Ready,Manual,Focus:Boolean);
var O:TJSONObject;
begin
  if not Ready or Manual or(Agent=nil)or FEnded or not History.CheckpointDue then Exit;
  O:=CaptureRidePosition(Agent);O.Add('training_focus',Focus);
  if Devices.IsSimulationActive then begin
    O.Add('sim_position',Devices.SimPositionSec);O.Add('sim_accounted',FSimAccountedUntil);
  end;
  History.Checkpoint(O);
end;

procedure TLocalRiderRuntime.Restore;
var O,R:TJSONObject;Seek:TSimSeekEvent;
begin
  if(Agent=nil)or not History.RestoreNeeded then Exit;
  O:=History.TakeResume;if O=nil then Exit;
  try
    if O.Get('version',0)<>1 then raise Exception.Create('Unsupported saved ride version');
    R:=O.Objects['rider'];RestoreRidePosition(Agent,R);
    Workout.RestoreState(O.Objects['workout']);DailyTrainingForRider(FIndex).RestoreState(O.Objects['daily']);
    if Devices.IsSimulationActive and(R.Find('sim_position')<>nil)then begin
      Seek:=Devices.OnSimSeek;Devices.OnSimSeek:=nil;
      try Devices.SimSeekSec(R.Get('sim_position',0.0));Devices.SimSetPaused(True);
      finally Devices.OnSimSeek:=Seek end;
      FSimAccountedUntil:=R.Get('sim_accounted',R.Get('sim_position',0.0));
    end;
    History.ResumeApplied;
  finally O.Free end;
end;

procedure TLocalRiderRuntime.FinishClick(Sender:TObject);
begin FinishRide end;
procedure TLocalRiderRuntime.FinishRide;
begin
  if FEnded then Exit;FEnded:=True;
  if WorkoutHud<>nil then WorkoutHud.ReleaseTrainer;
  if Hud<>nil then Hud.SuspendTrainerControl;
  if Devices.HasControlDevice then
    try Devices.StopTrainer;except on E:Exception do Logger.Warning('[Trainer] '+E.Message) end;
  if Controller<>nil then begin Controller.SetDesiredPower(0);Controller.SetAutoMove(False) end;
  if Agent<>nil then Agent.StopMoving;
  { A filesystem/upload error for one participant must not leave the other
    trainers running or prevent cleanup of the shared world. Failed journals
    retain their recovery checkpoint and are not re-attributed to an account. }
  try History.Finish;
  except on E:Exception do Logger.Warning('[Local rider history] '+E.Message) end;
  Workout.Stop;DailyTrainingForRider(FIndex).EndRide;
  try SensorLogForRider(FIndex).Close;
  except on E:Exception do Logger.Warning('[Local rider journal] '+E.Message) end;
  try if UploadQueue<>nil then RideUploadQueueForRider(FIndex).Scan;
  except on E:Exception do Logger.Warning('[Local rider upload] '+E.Message) end;
  if Publisher<>nil then Publisher.StopRelay;
  if FIndex>0 then RideRooms(FIndex).Leave;
end;

destructor TLocalRiderRuntime.Destroy;
begin
  FinishRide;
  { The legacy primary publisher remains owned by the shared view. }
  if FIndex>0 then Publisher.Free;
  Pose.Free;Bike.Free;Hud.Free;
  inherited;
end;
end.
