unit GameLocalBots;
{$mode objfpc}{$H+}
interface
uses Classes, SysUtils, CastleVectors, CastleTransform, CastleScene, CastleViewport,
  BikeParametric, GamePhysicalAgent, GameAgentControllers, GamePhysicsCommon,
  GameWorld, GamePath, GameLocalBotProfile, GameBotEffort, GameRiderPoseControl, Osm3dRouteSnapper, fpjson, RiderTripo, GameBotShadow, GameRiderShaderWarmup;
type
  TCrossingGround = record
    Points:array of TVector3;
    Ready:array of Boolean;
    ReferenceY:Single;
  end;
  TLocalBotAgent = class(TPhysicalAgent)
  public
    Spawned, Visible, StartGroundPending, Oncoming: Boolean;
    StepDebt: Single;
    AnimationDebt: Single;
    Effort:TBotEffortState;
    PowerControl: TPowerController; { owned through Agent.Controller }
    procedure UpdateOffline(const SecondsPassed, FixedDelta: Single;
      const MaxSteps: Integer = 4); override;
  end;
  TLocalBotReplay = record
    Spawned, Visible: Boolean;
    StepDebt,AnimationDebt: Single;
    Effort:TBotEffortState;
    HasBike:Boolean;
    Bike:TBikePlaybackState;
    Pose:TPoseManagerReplay;
  end;
  TLocalBotsReplay = record
    Elapsed, SelectionTime: Double;
    NextAppearance,NextOncoming:Double;
    ReferencePower: Single;
    Bots: array[0..LocalBotCount-1] of TLocalBotReplay;
    CrossActive:Boolean;
    CrossRoute,CrossVisual:Integer;
    CrossIdentity:Pointer;
    CrossState:TAgentReplayState;
    CrossPose:TPoseManagerReplay;
    CrossUsed:array of Integer;
  end;
  TLocalBotReady = procedure(Bike:TBikeInstance; Agent:TPhysicalAgent) of object;
  TLocalBots = class
  private
    FOwner:TComponent;
    FViewport:TCastleViewport;
    FLevel:TCastleScene;
    FWorld:TGameWorld;
    FAvatar:TPhysicalAgent;
    FLanes:TLaneManager;
    FAgents,FBikes,FPoses:TList;
    FProfiles:array[0..LocalBotCount-1]of TLocalBotProfile;
    FShadows:array[0..LocalBotCount-1]of TBotShadow;
    FShadowPoseDirty:array[0..LocalBotCount-1]of Boolean;
    FJson:string; { shared source configuration; fit and appearance are per bot }
    FPrepareJson:string; { only the currently loading bot, freed after attachment }
    FDistances:array of Double;
    FLength:Double;
    FElapsed,FSelectionTime:Double;
    FNextAppearance,FNextOncoming:Double;
    FReferencePower,FFtp:Single;
    FPrepareIndex,FPrepareStage,FVisibleCount,FRenderLimit:Integer;
    FReady,FRenderEnabled,FAnimationEnabled:Boolean;
    FPoseCachePolicy:Integer;
    FGlbWorker:TTripoGlbWorker;
    FMaxPrepareMs,FLastSwitchMs,FMaxSwitchMs:QWord;
    FPrepareTimes:array[0..4]of QWord;
    FShaderWarmup:TRiderShaderWarmup;
    FOnReady:TLocalBotReady;
    FOnRosterChanged:TNotifyEvent;
    FCrossings:TBotCrossingArray;
    FCrossGround:array of TCrossingGround;
    FCrossUsed:array of Integer;
    FCrossAgent:TLocalBotAgent;
    FCrossOwner:TComponent;
    FCrossRoute,FCrossVisual:Integer;
    FCrossSerial:Integer;
    FCrossRemoved,FCrossFailed:Integer;
    FCrossError:string;
    FCrossLength:Single;
    FCrossRetryAt:Double;
    procedure TryCrossing;
    procedure TryOncoming;
    function ReserveTrafficSlot:Boolean;
    procedure CreateCrossing(RouteIndex,VisualIndex:Integer);
    procedure RemoveCrossing;
    function GetAgent(Index:Integer):TLocalBotAgent;
    procedure CreateBot(Index:Integer;Seed:Cardinal);
    procedure SetVisible(Index:Integer;Value:Boolean;ReserveLane:Boolean=True);
    function PrepareCrossingGround(Index:Integer):Boolean;
    function VisibilityPosition(Agent:TLocalBotAgent):TVector3;
    procedure CameraRelation(Agent:TLocalBotAgent;out Distance:Single;out InCamera:Boolean);
    function Station(const P:TPathPosition):Double;
  public
    constructor Create(Owner:TComponent;Viewport:TCastleViewport;Level:TCastleScene;
      World:TGameWorld;Avatar:TPhysicalAgent;Ftp:Single;Seed:Cardinal);
    destructor Destroy;override;
    { Initial loading only. One model stage / resource group per frame.
      Models remain cached and detached when absent: no GLB/texture loads while riding. }
    procedure PrepareNext;
    procedure ResetOnRoute(Lanes:TLaneManager;Avatar:TPhysicalAgent);
    procedure BeforePhysics(Dt:Single);
    function AnimationStep(Index:Integer;Dt:Single):Single;
    procedure InvalidateShadowPose(Index:Integer);
    procedure AppendShadowCasters(List:TCastleTransformList);
    procedure SetRenderEnabled(Value:Boolean);
    procedure SetAnimationEnabled(Value:Boolean);
    procedure SetRenderLimit(Value:Integer);
    procedure SetPoseCachePolicy(Value:Integer);
    procedure SetCrossings(const Value:TBotCrossingArray);
    function RouteGap(Index:Integer):Single;
    function CaptureReplay:TLocalBotsReplay;
    procedure RestoreReplay(const Value:TLocalBotsReplay);
    function Diagnostics:TJSONObject;
    property Agents:TList read FAgents;
    property Bikes:TList read FBikes;
    property Poses:TList read FPoses;
    property Ready:Boolean read FReady;
    property PreparedCount:Integer read FPrepareIndex;
    property VisibleCount:Integer read FVisibleCount;
    property OnReady:TLocalBotReady read FOnReady write FOnReady;
    property CrossAgent:TLocalBotAgent read FCrossAgent;
    property OnRosterChanged:TNotifyEvent read FOnRosterChanged write FOnRosterChanged;
  end;
implementation
uses Math, CastleTimeUtils, CastleURIUtils, RiderBodyParameters, jsonparser,
  BikeGeometryLib, BikeParametric_Frame, BikeParametric_Crankset,
  GameBikeAvatar, GameRiderTraffic, GameAgentNetwork, GameMath, DebugLog, AppSettings, UiTranslations;

procedure TLocalBotAgent.UpdateOffline(const SecondsPassed,FixedDelta:Single;const MaxSteps:Integer);
var Dt:Single;Tangent:TVector3;
begin
  if not Spawned then Exit;
  if Visible then begin
    if StartGroundPending and Assigned(State.GroundQuery)then begin
      { A GPU contact request needs a render/readback cycle. Keep the
        intended entry speed until wheel probes are ready, instead of the
        physics missing-ground guard turning every arrival into a start
        from rest. No movement or synchronous GPU wait while pending. }
      Physics.UpdateVisualGroundProbes(SecondsPassed);
      Physics.ApplyVisualGroundPlacement(SecondsPassed);
      if not Physics.GroundPlacementValid then Exit;
    end;
    StartGroundPending:=False;
    Dt:=SecondsPassed+StepDebt;StepDebt:=0;
    inherited UpdateOffline(Dt,FixedDelta,Max(MaxSteps,Ceil(Dt/FixedDelta)+1));
  end else begin
    StepDebt:=StepDebt+SecondsPassed;
    if StepDebt<0.20 then Exit;
    Dt:=StepDebt;StepDebt:=0;
    { Geometry is not queried off screen, including beyond loaded tiles.
      The prepared route (and FIT load profile, when present) gives grade. }
    Tangent:=Path.FollowTangent(Path.Position);
    State.CurrentGroundPitch:=RadToDeg(ArcTan2(Tangent.Y,
      Max(0.01,Sqrt(Sqr(Tangent.X)+Sqr(Tangent.Z)))));
    State.CurrentSlopeAngle:=State.CurrentGroundPitch;
    inherited UpdateOffline(Dt,0.05,Ceil(Dt/0.05)+1);
  end;
end;

constructor TLocalBots.Create(Owner:TComponent;Viewport:TCastleViewport;Level:TCastleScene;
  World:TGameWorld;Avatar:TPhysicalAgent;Ftp:Single;Seed:Cardinal);
var I:Integer;Text:TStringList;
begin
  inherited Create;
  FOwner:=Owner;FViewport:=Viewport;FLevel:=Level;FWorld:=World;FAvatar:=Avatar;
  FFtp:=EnsureRange(Ftp,70,600);FReferencePower:=FFtp*0.75;
  FRenderEnabled:=True;FAnimationEnabled:=True;FRenderLimit:=LocalBotVisibleLimit;
  FPoseCachePolicy:=-1;
  FShaderWarmup:=TRiderShaderWarmup.Create;
  FAgents:=TList.Create;FBikes:=TList.Create;FPoses:=TList.Create;
  Text:=TStringList.Create;
  try
    Text.LoadFromFile(BikeJsonUrlToFilename('castle-data:/bike_road2.json'));
    FJson:=InjectRiderPath(Text.Text,ResolveRiderGlbPath('castle-data:/avatars/RIDER.glb'),False);
  finally Text.Free end;
  for I:=0 to LocalBotCount-1 do CreateBot(I,Seed);
end;

destructor TLocalBots.Destroy;
var I:Integer;
begin
  { World owns agents; FreeAtStop owns their transforms/scenes. Detach before
    bike destruction and before World/LaneManager/viewport are destroyed. }
  RemoveCrossing;
  FreeAndNil(FShaderWarmup);
  FreeAndNil(FGlbWorker);
  for I:=0 to FAgents.Count-1 do SetVisible(I,False);
  for I:=0 to FPoses.Count-1 do TObject(FPoses[I]).Free;
  for I:=0 to High(FShadows)do FreeAndNil(FShadows[I]);
  for I:=0 to FBikes.Count-1 do TObject(FBikes[I]).Free;
  FPoses.Free;FBikes.Free;FAgents.Free;
  inherited;
end;

function TLocalBots.GetAgent(Index:Integer):TLocalBotAgent;
begin Result:=TLocalBotAgent(FAgents[Index]) end;

procedure TLocalBots.CreateBot(Index:Integer;Seed:Cardinal);
var A:TLocalBotAgent;T:TCastleTransform;S:TCastleScene;
begin
  FProfiles[Index]:=MakeLocalBotProfile(Index,Seed);
  T:=TCastleTransform.Create(FOwner);T.Name:='LocalBotTransform'+IntToStr(Index);
  S:=TCastleScene.Create(FOwner);S.Name:='LocalBotScene'+IntToStr(Index);T.Add(S);
  A:=TLocalBotAgent.Create(FOwner);A.Name:=FProfiles[Index].DisplayName;
  A.Oncoming:=Index=LocalBotOncomingIndex;
  A.SetupActor(T,S,nil,FViewport,nil,FLevel);
  A.PowerControl:=TPowerController.Create;A.SetController(A.PowerControl);
  A.RecreatePhysics(pmKinematicCurrent);A.State.WheelContactAtOrigin:=True;
  A.State.AvatarMass:=FProfiles[Index].Body.WeightKg+9;
  A.State.DragCoefficient:=FAvatar.State.DragCoefficient;
  A.State.FrontalArea:=FAvatar.State.FrontalArea;
  A.State.RollingResistance:=FAvatar.State.RollingResistance;
  A.SetPhysicsLOD(plMinimal);A.Initialize;A.NetworkAuthority:=naLocalOnly;
  FWorld.AddBot(A);FWorld.RegisterAgentInNetwork(A);
  FAgents.Add(A);FBikes.Add(nil);FPoses.Add(nil);
end;

procedure TLocalBots.PrepareNext;
var I:Integer;B:TBikeInstance;A:TLocalBotAgent;Slot:TClothSlot;Tick:QWord;
  Advance:Boolean;
  Config, Rider:TJSONObject;
begin
  if FReady then Exit;
  Tick:=GetTickCount64;I:=FPrepareIndex;A:=GetAgent(I);B:=TBikeInstance(FBikes[I]);
  Advance:=True;
  try
    case FPrepareStage of
      0:begin
        FGlbWorker:=TTripoGlbWorker.Create(ResolveRiderGlbPath('castle-data:/avatars/RIDER.glb'));
        Config:=TJSONObject(GetJSON(FJson));
        try
          Rider:=Config.Objects['tripoRider'];
          Rider.Delete('body');Rider.Add('body',WriteRiderBody(FProfiles[I].Body));
          Rider.Floats['scale']:=1;
          { Cleats follow this bike's actual pedals, not a legacy width
            saved for an older model. No user fit/profile is inherited. }
          Rider.Floats['stanceHalf']:=0;
          Rider.Floats['footYawDeg']:=0;
          FPrepareJson:=Config.AsJSON;
        finally Config.Free end;
        B:=LoadBikeInstanceFromJSONString(FPrepareJson,FOwner,12,30,65,False,True,True);
        FBikes[I]:=B;B.ShadowMode:=bsmNone;
        A.Actor.Scene.Add(B.Group);
        B.ClothDyePresetMode:=cdmShader;
        for Slot:=Low(Slot)to High(Slot)do B.StageRiderClothColor(Slot,FProfiles[I].Colors[Slot]);
      end;
      1:begin
        if not FGlbWorker.Finished then Exit;
        AttachTripoRiderFromJSON(B,FPrepareJson,FGlbWorker.Prepared);
        FreeAndNil(FGlbWorker);
        FPrepareJson:='';
        if not B.HasTripoRider then raise Exception.Create('Companion rider model unavailable');
        { Body was staged before attaching the GLB. Do not deform/upload
          a default body first and repeat it for the bot's real proportions. }
        if not B.FitSaddleToRider then
          raise Exception.Create('Companion rider saddle fit failed');
      end;
      2:begin
        B.TripoRider.HairStyle:=FProfiles[I].Hair;
        B.TripoRider.SetHeadAppearance(FProfiles[I].Headwear,FProfiles[I].Beard,FProfiles[I].Mustache);
        B.TripoRider.ApplyHelmetColor(FProfiles[I].Helmet,True);
        B.SetFrameColorLive(FProfiles[I].Frame);B.SetRimColorLive(FProfiles[I].Rim);
        FPoses[I]:=TRiderPoseManager.Create(B);
        A.Physics.SetWheelProbeHalfSpan(B.AxleHalfSpanM);
        B.AnimationEnabled:=FAnimationEnabled;
        B.AnimateFrame(Single(0));
        B.RiderScene.RenderOptions.CachedAnimationRevision:=1;
        FShadows[I]:=TBotShadow.Create(FOwner);B.Group.Add(FShadows[I]);
        FShadows[I].UpdatePose(B);
        if Assigned(FOnReady)then FOnReady(B,A);
      end;
      { All four SubScene accessors now refer to the same bicycle scene.
        Upload textures once; compile/draw shapes in bounded loading steps. }
      3:FViewport.PrepareResources(B.Group,[]);
      4:Advance:=FShaderWarmup.Step(FViewport,A.Actor.Transform,B.Group,B.RiderScene);
    end;
    FPrepareTimes[FPrepareStage]:=Max(FPrepareTimes[FPrepareStage],GetTickCount64-Tick);
    if Advance then Inc(FPrepareStage);
  except
    on E:Exception do begin
      Logger.Warning('[LocalBots] prepare '+IntToStr(I)+': '+E.Message);
      FreeAndNil(FGlbWorker);
      FPrepareJson:='';
      TObject(FPoses[I]).Free;FPoses[I]:=nil;
      FreeAndNil(FShadows[I]);
      FShaderWarmup.Finish;
      B.Free;FBikes[I]:=nil;FPrepareStage:=5;
    end;
  end;
  FMaxPrepareMs:=Max(FMaxPrepareMs,GetTickCount64-Tick);
  if FPrepareStage>=5 then begin
    B:=TBikeInstance(FBikes[I]);if B<>nil then B.Group.Exists:=FRenderEnabled;
    Inc(FPrepareIndex);FPrepareStage:=0;FReady:=FPrepareIndex>=LocalBotCount;
    if FReady then begin
      FShaderWarmup.Finish;
      Logger.Info(Format('[LocalBots] prepared %d cached riders; max stage=%d ms; visible cap=%d',
        [LocalBotCount,FMaxPrepareMs,LocalBotVisibleLimit]));
    end;
  end;
end;

procedure TLocalBots.ResetOnRoute(Lanes:TLaneManager;Avatar:TPhysicalAgent);
var I:Integer;A:TLocalBotAgent;P:TPathPosition;
begin
  RemoveCrossing;
  for I:=0 to FAgents.Count-1 do SetVisible(I,False);
  FLanes:=Lanes;FAvatar:=Avatar;FElapsed:=0;FSelectionTime:=0;
  FNextAppearance:=0;FNextOncoming:=LocalBotOncomingFirst;
  FReferencePower:=FFtp*0.75;FLength:=0;
  SetLength(FDistances,FAvatar.Path.PointCount+1);
  for I:=0 to FAvatar.Path.PointCount-1 do begin
    FDistances[I]:=FLength;
    P.Segment:=I;P.T:=0;
    FLength:=FLength+FAvatar.Path.FollowTangent(P).Length;
  end;
  FDistances[High(FDistances)]:=FLength;
  for I:=0 to FAgents.Count-1 do begin
    A:=GetAgent(I);A.Spawned:=False;A.StepDebt:=0;
    ResetBotEffort(A.Effort,FProfiles[I].EffortSeed,
      LocalBotSustainablePower(FProfiles[I],FReferencePower,FAvatar.State.AvatarMass)*0.89);
    FAvatar.Path.CopyTo(A.Path,A.Oncoming);A.SetPhysicsLOD(plMinimal);
    A.PowerControl.SetEnabled(False);
  end;
end;

function TLocalBots.Station(const P:TPathPosition):Double;
begin
  Result:=0;
  if(P.Segment>=0)and(P.Segment<Length(FDistances)-1)then
    Result:=FDistances[P.Segment]+P.T*(FDistances[P.Segment+1]-FDistances[P.Segment]);
end;

function TLocalBots.RouteGap(Index:Integer):Single;
var P:TPathPosition;
begin
  P:=GetAgent(Index).Path.Position;
  if GetAgent(Index).Oncoming then P:=FAvatar.Path.ReversedPosition(P);
  Result:=Station(P)-Station(FAvatar.Path.Position);
  if FLength>0 then Result:=Result-Floor((Result+FLength*0.5)/FLength)*FLength;
end;

function TLocalBots.VisibilityPosition(Agent:TLocalBotAgent):TVector3;
begin
  Result:=Agent.State.WorldPosition;
  if (Agent<>FCrossAgent) and (not Agent.Visible or Agent.StartGroundPending) then
  begin
    { Minimal physics deliberately does not sample ground. OSM path heights
      may be zero, so its raw Y is not a world-space surface position. Use
      the player's resolved height plus the relative route height for both
      visibility tests and the initial ground-query hint. This also retains
      hills on baked Dream routes, without raycasting the hidden company.
      Cross-road bots already have their own ground-sampled world heights. }
    Result.Y:=FAvatar.State.WorldPosition.Y+
      Agent.Path.RoadCenterAt(Agent.Path.Position).Y-
      FAvatar.Path.RoadCenterAt(FAvatar.Path.Position).Y;
  end;
end;

procedure TLocalBots.CameraRelation(Agent:TLocalBotAgent;out Distance:Single;out InCamera:Boolean);
var P,D,U,V:TVector3;
begin
  FViewport.Camera.GetWorldView(P,D,U);V:=VisibilityPosition(Agent)+Vector3(0,1,0)-P;
  Distance:=V.Length;
  { Wide cone also covers the edges of ultrawide windows. Conservative:
    prefer delaying a spawn over exposing it in a free/cinematic camera. }
  InCamera:=(Distance<1)or(TVector3.DotProduct(V,D)>0.40*Distance);
end;

procedure TLocalBots.SetVisible(Index:Integer;Value:Boolean;ReserveLane:Boolean);
var A:TLocalBotAgent;B:TBikeInstance;H:Integer;Tick:QWord;EntryPosition:TVector3;
begin
  A:=GetAgent(Index);B:=TBikeInstance(FBikes[Index]);
  if Value and (B=nil)then Exit;
  if A.Visible=Value then Exit;
  if Value then EntryPosition:=VisibilityPosition(A);
  Tick:=GetTickCount64;A.Visible:=Value;A.StartGroundPending:=Value;
  A.AnimationDebt:=0.20; { prime a current pose on appearance / replay restore }
  if Value then begin
    if ReserveLane then FNextAppearance:=FElapsed+LocalBotAppearanceInterval;
    Inc(FVisibleCount);A.SetPhysicsLOD(plFull);
    { Settle wheels and reserve a free lane while still outside the camera. }
    A.State.LastGroundY:=EntryPosition.Y;
    A.State.WorldPosition.Y:=EntryPosition.Y;
    A.Physics.ResetTrackingAfterTeleport;
    if ReserveLane then PlaceTrafficAgent(FLanes,A)
    else RegisterTrafficAgent(FLanes,A);
    A.Physics.UpdateVisualGroundPlacement(0);
    { Visibility must not change the skinning pipeline. AnimationEnabled=False
      bakes a CPU pose and tears down GPU skin shaders. Re-enabling it used
      to cause a full shader recompile on the first visible frame. Detached
      scenes receive no updates/draws; keep their prepared GPU pipeline. }
    B.AnimationEnabled:=FAnimationEnabled;
    B.Group.Exists:=FRenderEnabled;
    FViewport.Items.Add(A.Actor.Transform);
  end else begin
    Dec(FVisibleCount);FViewport.Items.Remove(A.Actor.Transform);
    if A.Oncoming then begin
      A.Spawned:=False;A.PowerControl.SetEnabled(False);
      FNextOncoming:=FElapsed+LocalBotOncomingInterval;
    end;
    A.SetPhysicsLOD(plMinimal);A.Actor.RiderOwnsLean:=False;
    A.State.ShadowPlaneWanted:=False;
    if FLanes<>nil then begin H:=FLanes.FindRider(A);if H>=0 then FLanes.UnregisterRider(H) end;
    A.State.TrafficMoveConstraint:=nil;A.State.TrafficHeadingConstraint:=nil;
    A.State.LaneOffsetExternal:=False;
  end;
  FLastSwitchMs:=GetTickCount64-Tick;
  FMaxSwitchMs:=Max(FMaxSwitchMs,FLastSwitchMs);
  if Assigned(FOnRosterChanged)then FOnRosterChanged(Self);
end;

function TLocalBots.AnimationStep(Index:Integer;Dt:Single):Single;
var A:TLocalBotAgent;B:TBikeInstance;Distance,Interval:Single;InCamera,RevisionCache:Boolean;
begin
  A:=GetAgent(Index);CameraRelation(A,Distance,InCamera);
  { Continuously animated visible riders use the same per-pass policy as the
    avatar: capture only when the detailed mesh participates in shadow passes.
    Forcing a capture of every distant mesh adds a feedback draw and barrier
    even though its shadow is a separate proxy and color is its only pass.
    Keep revision caching for throttled, off-camera poses. }
  RevisionCache:=(FPoseCachePolicy=1)or((FPoseCachePolicy<0)and not InCamera);
  B:=TBikeInstance(FBikes[Index]);
  if (B<>nil)and(B.RiderScene<>nil)then begin
    if not RevisionCache then B.RiderScene.RenderOptions.CachedAnimationRevision:=0
    else if B.RiderScene.RenderOptions.CachedAnimationRevision=0 then
      B.RiderScene.RenderOptions.CachedAnimationRevision:=1;
  end;
  Interval:=0;
  { AnimateFrame also moves the whole bicycle (balance/yaw/steering), not
    just distant limbs. A 30 Hz gate at 35 FPS actually skipped every other
    frame, visibly stepping the bike and its rider. Only the at-most-three
    rendered bikes facing the camera need continuous animation; unseen
    models still use the cheap cadence and hidden agents keep coarse physics. }
  if not InCamera then Interval:=1/8;
  A.AnimationDebt:=A.AnimationDebt+Dt;Result:=0;
  if A.AnimationDebt+0.00001<Interval then Exit;
  Result:=Min(A.AnimationDebt,0.4);A.AnimationDebt:=0;
end;

procedure TLocalBots.InvalidateShadowPose(Index:Integer);
var Visual:Integer;
begin
  Visual:=Index;if Index=LocalBotCount then Visual:=FCrossVisual;
  if(Visual>=0)and(Visual<LocalBotCount)then FShadowPoseDirty[Visual]:=True;
end;

procedure TLocalBots.AppendShadowCasters(List:TCastleTransformList);
var I,Visual:Integer;B:TBikeInstance;Distance:Single;InCamera,Proxy:Boolean;
begin
  for I:=0 to FAgents.Count-1 do begin
    if not GetAgent(I).Visible then Continue;
    B:=TBikeInstance(FBikes[I]);if(B=nil)or not B.Group.Exists then Continue;
    Visual:=I;if I=LocalBotCount then Visual:=FCrossVisual;
    CameraRelation(GetAgent(I),Distance,InCamera);
    Proxy:=Distance>24;
    if FShadows[Visual]<>nil then begin
      { Hysteresis avoids oscillating between the two casters at the edge. }
      if FShadows[Visual].Active then Proxy:=Distance>20;
      FShadows[Visual].Active:=Proxy;
      if Proxy then begin
        { Refresh only when this proxy is actually requested for the atlas.
          A pose can change many times while detailed or disabled shadows
          are in use. The first proxy frame must consume the latest pose. }
        if FShadowPoseDirty[Visual]then begin
          FShadows[Visual].UpdatePose(B);FShadowPoseDirty[Visual]:=False;
        end;
        List.Add(FShadows[Visual]);
      end else List.Add(B.Group);
    end else List.Add(B.Group);
  end;
end;

procedure TLocalBots.BeforePhysics(Dt:Single);
var I,CompanionLimit:Integer;A:TLocalBotAgent;C:TPowerController;P:TPathPosition;
  Distance,CameraDistance,Target,Gap,Behind:Single;InCamera:Boolean;
  EffortInput:TBotEffortInput;
begin
  if not FReady or(Dt<=0)or(FLength<200)then Exit;
  FElapsed:=FElapsed+Dt;
  Target:=FAvatar.State.AppliedPowerWatts;
  if Target>10 then FReferencePower:=FReferencePower+
    (EnsureRange(Target,FFtp*0.30,FFtp*1.5)-FReferencePower)*(1-Exp(-Dt/90));
  for I:=0 to LocalBotCount-1 do begin
    A:=GetAgent(I);C:=A.PowerControl;
    if not A.Spawned then begin
      if A.Oncoming or (FElapsed<I*LocalBotJoinInterval) then Continue;
      Behind:=72+I*12;
      { At the start of an out-and-back ride there is no road behind yet.
        Wait, instead of spawning on the opposite-direction return branch. }
      if FAvatar.Path.OutAndBack and(Station(FAvatar.Path.Position)<Behind+5)then Continue;
      P:=FAvatar.Path.Position;FAvatar.Path.AdvanceFollow(P,-Behind);
      A.TeleportToPath(P);A.State.CumulativeDistance:=FAvatar.State.CumulativeDistance-Behind;
      A.State.CurrentSpeed:=FAvatar.State.CurrentSpeed;A.Spawned:=True;
    end;
    C.SetEnabled(True);
    EffortInput.SustainableWatts:=LocalBotSustainablePower(FProfiles[I],FReferencePower,FAvatar.State.AvatarMass);
    EffortInput.CapacitySeconds:=FProfiles[I].CapacitySeconds;
    EffortInput.RecoverySeconds:=FProfiles[I].RecoverySeconds;
    EffortInput.Aggression:=FProfiles[I].Aggression;
    EffortInput.Gap:=RouteGap(I);EffortInput.Speed:=A.State.CurrentSpeed;
    EffortInput.RiderSpeed:=FAvatar.State.CurrentSpeed;
    EffortInput.Racing:=not A.Oncoming and (EffortInput.RiderSpeed>0.5);
    EffortInput.UnderPressure:=(EffortInput.Gap>0)and(EffortInput.Gap<30)and
      (EffortInput.RiderSpeed>EffortInput.Speed+0.4);
    C.SetDesiredPower(StepBotEffort(A.Effort,EffortInput,Dt));
  end;
  if FCrossAgent<>nil then begin
    if FCrossAgent.State.CumulativeDistance>=FCrossLength-25 then begin
      FCrossAgent.PowerControl.SetEnabled(False);
      FCrossAgent.State.CurrentSpeed:=0;FCrossAgent.State.AutoMove:=False;
    end;
    FCrossAgent.UpdateOffline(Dt,1/60,Max(4,Ceil(Dt*60)+1));
    CameraRelation(FCrossAgent,CameraDistance,InCamera);
    Distance:=(VisibilityPosition(FCrossAgent)-FAvatar.State.WorldPosition).Length;
    if BotCanDisappear(Distance,CameraDistance,InCamera)then RemoveCrossing;
  end;
  if FElapsed<FSelectionTime then Exit;
  FSelectionTime:=FElapsed+0.25;
  for I:=0 to LocalBotCount-1 do begin
    A:=GetAgent(I);if not A.Spawned then Continue;
    Distance:=(VisibilityPosition(A)-FAvatar.State.WorldPosition).Length;
    CameraRelation(A,CameraDistance,InCamera);
    if A.Visible then begin
      if BotCanDisappear(Distance,CameraDistance,InCamera)then begin
        SetVisible(I,False);
      end;
    end;
  end;
  if not FRenderEnabled or (FElapsed<FNextAppearance) then Exit;
  if FElapsed>=LocalBotJoinInterval then TryCrossing;
  if FElapsed<FNextAppearance then Exit;
  TryOncoming;
  if FElapsed<FNextAppearance then Exit;
  CompanionLimit:=FRenderLimit;
  { Keep an overdue encounter's slot available while a bend delays its safe
    distant entry. Otherwise a third companion can starve oncoming traffic
    indefinitely. Close/watched riders are never evicted for this. }
  if not GetAgent(LocalBotOncomingIndex).Spawned and (FElapsed>=FNextOncoming) and
     (FAvatar.Path.RoadWidthAt(FAvatar.Path.Position)>=3) then
    CompanionLimit:=Max(1,FRenderLimit-1);
  if (FVisibleCount>=CompanionLimit)or(FVisibleCount>=FRenderLimit)or not FRenderEnabled then Exit;
  for I:=0 to LocalBotCount-1 do begin
    if(FCrossAgent<>nil)and(I=FCrossVisual)then Continue;
    A:=GetAgent(I);if not A.Spawned or A.Visible or A.Oncoming then Continue;
    Distance:=(VisibilityPosition(A)-FAvatar.State.WorldPosition).Length;
    Gap:=RouteGap(I);CameraRelation(A,CameraDistance,InCamera);
    if BotCanAppear(Gap,Distance,CameraDistance,InCamera)then begin
      SetVisible(I,True);Break; { at most one activation per selection tick }
    end;
  end;
end;

function TLocalBots.ReserveTrafficSlot:Boolean;
var I:Integer;Distance:Single;InCamera:Boolean;
begin
  if FRenderLimit=0 then Exit(False);
  if FVisibleCount>=FRenderLimit then
    for I:=0 to LocalBotCount-1 do
      if GetAgent(I).Visible and not GetAgent(I).Oncoming then begin
        CameraRelation(GetAgent(I),Distance,InCamera);
        if not InCamera and
          ((VisibilityPosition(GetAgent(I))-FAvatar.State.WorldPosition).Length>120) then begin
          SetVisible(I,False);Break;
        end;
      end;
  Result:=FVisibleCount<FRenderLimit;
end;

procedure TLocalBots.TryOncoming;
const AheadM=280.0;
var A:TLocalBotAgent;P:TPathPosition;S,EndS,Distance,CameraDistance:Single;
  InCamera:Boolean;
begin
  A:=GetAgent(LocalBotOncomingIndex);
  if A.Spawned or (FElapsed<FNextOncoming) or (FAvatar.State.CurrentSpeed<2) or
    ((FCrossAgent<>nil)and(FCrossVisual=LocalBotOncomingIndex)) or
    (FBikes[LocalBotOncomingIndex]=nil) then Exit;
  { Never wrap an encounter across the endpoint onto the return branch. }
  if FAvatar.Path.OutAndBack then begin
    S:=Station(FAvatar.Path.Position);EndS:=FDistances[FAvatar.Path.PointCount div 2];
    if S>=EndS then EndS:=FLength;
    if S+AheadM+40>=EndS then Exit;
  end;
  P:=FAvatar.Path.Position;FAvatar.Path.AdvanceFollow(P,AheadM);
  { Avoid head-on traffic in single-track corridors. The shared lane manager
    assigns the normal right-hand offset relative to the REVERSED heading. }
  if FAvatar.Path.RoadWidthAt(P)<3 then Exit;
  A.TeleportToPath(FAvatar.Path.ReversedPosition(P));
  Distance:=(VisibilityPosition(A)-FAvatar.State.WorldPosition).Length;
  CameraRelation(A,CameraDistance,InCamera);
  if (Distance<200) or (CameraDistance<70) or (InCamera and(CameraDistance<220)) then Exit;
  if not ReserveTrafficSlot then Exit;
  A.StepDebt:=0;A.State.CumulativeDistance:=0;A.State.CurrentSpeed:=6;
  A.Spawned:=True;A.PowerControl.SetEnabled(True);
  ResetBotEffort(A.Effort,A.Effort.RandomState,
    LocalBotSustainablePower(FProfiles[LocalBotOncomingIndex],FReferencePower,FAvatar.State.AvatarMass)*0.89);
  A.PowerControl.SetDesiredPower(A.Effort.PowerWatts);
  SetVisible(LocalBotOncomingIndex,True);
end;

procedure TLocalBots.SetCrossings(const Value:TBotCrossingArray);
var I:Integer;
begin
  RemoveCrossing;FCrossRetryAt:=0;FCrossings:=Copy(Value);SetLength(FCrossUsed,Length(Value));
  FCrossGround:=nil;SetLength(FCrossGround,Length(Value));
  for I:=0 to High(FCrossUsed)do FCrossUsed[I]:=-1;
end;

function TLocalBots.PrepareCrossingGround(Index:Integer):Boolean;
var I:Integer;Y:Single;
begin
  Result:=True;
  if Length(FCrossGround[Index].Points)=0 then begin
    FCrossGround[Index].Points:=Copy(FCrossings[Index].Points);
    SetLength(FCrossGround[Index].Ready,Length(FCrossings[Index].Points));
    FCrossGround[Index].ReferenceY:=FAvatar.State.LastGroundY;
  end;
  { GPU ground probes complete asynchronously. Queue all missing samples,
    keep a fixed reference height, and retain completed points. Never wait
    for the GPU or restart the first sample each time the rider moves. }
  for I:=0 to High(FCrossGround[Index].Points)do
    if not FCrossGround[Index].Ready[I]then begin
      if Assigned(FAvatar.State.GroundQuery)and FAvatar.State.GroundQuery(
        FCrossGround[Index].Points[I].X,FCrossGround[Index].Points[I].Z,
        FCrossGround[Index].ReferenceY,Y)then begin
        FCrossGround[Index].Points[I].Y:=Y;FCrossGround[Index].Ready[I]:=True;
      end else Result:=False;
    end;
end;

procedure TLocalBots.CreateCrossing(RouteIndex,VisualIndex:Integer);
var T:TCastleTransform;S:TCastleScene;B:TBikeInstance;
  Points:array of TVector3;Widths:array of Single;I:Integer;Start:TPathPosition;
begin
  if(FCrossAgent<>nil)or(RouteIndex<0)or(RouteIndex>=Length(FCrossings))or
    (VisualIndex<0)or(VisualIndex>=LocalBotCount)or GetAgent(VisualIndex).Visible then Exit;
  B:=TBikeInstance(FBikes[VisualIndex]);if B=nil then Exit;
  if not PrepareCrossingGround(RouteIndex)then Exit;
  FCrossOwner:=TComponent.Create(nil);FCrossRoute:=RouteIndex;FCrossVisual:=VisualIndex;
  FCrossAgent:=TLocalBotAgent.Create(FCrossOwner);
  try
    T:=TCastleTransform.Create(FCrossOwner);S:=TCastleScene.Create(FCrossOwner);T.Add(S);
    FCrossAgent.SetupActor(T,S,nil,FViewport,nil,FLevel);
    FCrossAgent.PowerControl:=TPowerController.Create;FCrossAgent.SetController(FCrossAgent.PowerControl);
    FCrossAgent.RecreatePhysics(pmKinematicCurrent);FCrossAgent.SetPhysicsLOD(plMinimal);
    FCrossAgent.State.WheelContactAtOrigin:=True;
    FCrossAgent.State.AvatarMass:=FProfiles[VisualIndex].Body.WeightKg+9;
    if Assigned(FOnReady)then FOnReady(B,FCrossAgent);
    Points:=Copy(FCrossGround[RouteIndex].Points);SetLength(Widths,Length(Points));
    FCrossLength:=0;
    for I:=0 to High(Points)do begin
      Widths[I]:=FCrossings[RouteIndex].Width;
      if I>0 then FCrossLength:=FCrossLength+(Points[I]-Points[I-1]).Length;
    end;
    FCrossAgent.Path.LoadFromMemory(Points,Widths);
    FCrossAgent.Path.UsePreparedCornerHints(False);
    FCrossAgent.Initialize;FCrossAgent.InitializeAtStart(Points[0].Y);
    { The shared path follower is cyclic. Keep both endpoint joins outside
      the travelled portion; otherwise its lookahead sees a 180-degree
      corner at the first point and unnecessarily brakes the new cyclist. }
    Start.Segment:=0;Start.T:=0;FCrossAgent.Path.AdvanceFollow(Start,25);
    FCrossAgent.TeleportToPath(Start);FCrossAgent.State.CumulativeDistance:=25;
    FCrossAgent.Name:=FProfiles[VisualIndex].DisplayName;Inc(FCrossSerial);
    FCrossAgent.NetworkId:=-1000000-FCrossSerial;FCrossAgent.NetworkAuthority:=naLocalOnly;
    FCrossAgent.PowerControl.SetDesiredPower(160+35*FProfiles[VisualIndex].Ability);
    FCrossAgent.PowerControl.SetEnabled(True);FCrossAgent.Spawned:=True;
    FCrossAgent.State.CurrentSpeed:=6;
    GetAgent(VisualIndex).Actor.Scene.Remove(B.Group);S.Add(B.Group);
    FAgents.Add(FCrossAgent);FBikes.Add(B);FPoses.Add(TRiderPoseManager.Create(B));
    FCrossAgent.Physics.SetWheelProbeHalfSpan(B.AxleHalfSpanM);
    SetVisible(LocalBotCount,True);
  except
    { A missing tile must skip this optional event, never stop the ride. }
    on E:Exception do begin
      Inc(FCrossFailed);FCrossError:=E.Message;RemoveCrossing;
    end;
  end;
end;

procedure TLocalBots.RemoveCrossing;
var B:TBikeInstance;
begin
  if FCrossAgent=nil then Exit;
  if FAgents.Count>LocalBotCount then begin
    SetVisible(LocalBotCount,False);
    B:=TBikeInstance(FBikes[LocalBotCount]);
    FCrossAgent.Actor.Scene.Remove(B.Group);GetAgent(FCrossVisual).Actor.Scene.Add(B.Group);
    TObject(FPoses[LocalBotCount]).Free;
    FPoses.Delete(LocalBotCount);FBikes.Delete(LocalBotCount);FAgents.Delete(LocalBotCount);
    Inc(FCrossRemoved);
  end else if Assigned(FCrossAgent.Actor)and Assigned(FCrossAgent.Actor.Scene)then begin
    { Also restore the borrowed model if creation failed between reparenting
      and publication in the roster. The bike keeps its original owner. }
    B:=TBikeInstance(FBikes[FCrossVisual]);
    FCrossAgent.Actor.Scene.Remove(B.Group);
    if (GetAgent(FCrossVisual).Actor.Scene.List=nil)or
      (GetAgent(FCrossVisual).Actor.Scene.List.IndexOf(B.Group)<0)then
      GetAgent(FCrossVisual).Actor.Scene.Add(B.Group);
  end;
  FreeAndNil(FCrossAgent);FreeAndNil(FCrossOwner);
end;

procedure TLocalBots.TryCrossing;
var I,J,Lap,Visual:Integer;V,P,D,U,ToCam:TVector3;Ahead,Dist,CamDist:Single;
begin
  if(FCrossAgent<>nil)or(FRenderLimit=0)or(FAvatar.State.CurrentSpeed<2)or
    (FElapsed<FCrossRetryAt)then Exit;
  Lap:=Floor(Max(0,FAvatar.State.CumulativeDistance)/Max(1,FLength));
  for I:=0 to High(FCrossings)do begin
    if FCrossUsed[I]=Lap then Continue;
    V:=FCrossings[I].Center-FAvatar.State.WorldPosition;V.Y:=0;
    Ahead:=TVector3.DotProduct(V,FAvatar.State.ForwardDir);Dist:=V.Length;
    if(Ahead<70)or(Ahead>220)or(Dist>240)then Continue;
    if not PrepareCrossingGround(I)then Continue;
    FViewport.Camera.GetView(P,D,U);
    ToCam:=FCrossings[I].Points[0]-P;ToCam.Y:=0;CamDist:=ToCam.Length;
    if(CamDist<180)and(TVector3.DotProduct(ToCam,D)>0.4*CamDist)then Continue;
    if not ReserveTrafficSlot then Exit;
    Visual:=-1;
    for J:=0 to LocalBotCount-1 do if not GetAgent(J).Visible and(FBikes[J]<>nil)then begin Visual:=J;Break end;
    if Visual<0 then Exit;
    CreateCrossing(I,Visual);
    if FCrossAgent<>nil then FCrossUsed[I]:=Lap
    else FCrossRetryAt:=FElapsed+2; { streaming can finish while approaching }
    Exit;
  end;
end;

procedure TLocalBots.SetRenderEnabled(Value:Boolean);
var I:Integer;B:TBikeInstance;
begin
  FRenderEnabled:=Value;
  for I:=0 to FBikes.Count-1 do begin
    B:=TBikeInstance(FBikes[I]);if B=nil then Continue;
    B.Group.Exists:=Value;
  end;
end;

procedure TLocalBots.SetAnimationEnabled(Value:Boolean);
var I:Integer;
begin
  if FAnimationEnabled=Value then Exit;
  FAnimationEnabled:=Value;
  for I:=0 to LocalBotCount-1 do if FBikes[I]<>nil then begin
    TBikeInstance(FBikes[I]).AnimationEnabled:=Value;
    { Disabling animation bakes the current pose once. }
    InvalidateShadowPose(I);
  end;
end;

procedure TLocalBots.SetRenderLimit(Value:Integer);
var I:Integer;
begin
  FRenderLimit:=EnsureRange(Value,0,LocalBotVisibleLimit);
  if(FVisibleCount>FRenderLimit)and(FCrossAgent<>nil)then RemoveCrossing;
  for I:=FAgents.Count-1 downto 0 do
    if(FVisibleCount>FRenderLimit)and GetAgent(I).Visible then SetVisible(I,False);
end;

procedure TLocalBots.SetPoseCachePolicy(Value:Integer);
var I:Integer;B:TBikeInstance;
begin
  FPoseCachePolicy:=EnsureRange(Value,-1,1);
  for I:=0 to FBikes.Count-1 do begin
    B:=TBikeInstance(FBikes[I]);
    if (B<>nil)and(B.RiderScene<>nil)then
      B.RiderScene.RenderOptions.CachedAnimationRevision:=Ord(FPoseCachePolicy<>0);
  end;
end;

function TLocalBots.CaptureReplay:TLocalBotsReplay;
var I:Integer;A:TLocalBotAgent;
begin
  Result:=Default(TLocalBotsReplay);
  Result.Elapsed:=FElapsed;Result.SelectionTime:=FSelectionTime;Result.ReferencePower:=FReferencePower;
  Result.NextAppearance:=FNextAppearance;Result.NextOncoming:=FNextOncoming;
  for I:=0 to LocalBotCount-1 do begin A:=GetAgent(I);
    Result.Bots[I].Spawned:=A.Spawned;Result.Bots[I].Visible:=A.Visible;Result.Bots[I].StepDebt:=A.StepDebt;
    Result.Bots[I].AnimationDebt:=A.AnimationDebt;Result.Bots[I].HasBike:=FBikes[I]<>nil;
    Result.Bots[I].Effort:=A.Effort;
    if FBikes[I]<>nil then Result.Bots[I].Bike:=TBikeInstance(FBikes[I]).CaptureReplay;
    if FPoses[I]<>nil then Result.Bots[I].Pose:=TRiderPoseManager(FPoses[I]).CaptureReplay;
  end;
  Result.CrossUsed:=Copy(FCrossUsed);
  Result.CrossActive:=FCrossAgent<>nil;
  if Result.CrossActive then begin
    Result.CrossIdentity:=Pointer(FCrossAgent);Result.CrossRoute:=FCrossRoute;Result.CrossVisual:=FCrossVisual;
    Result.CrossState:=FCrossAgent.CaptureReplay;
    Result.CrossPose:=TRiderPoseManager(FPoses[LocalBotCount]).CaptureReplay;
  end;
end;

procedure TLocalBots.RestoreReplay(const Value:TLocalBotsReplay);
var I:Integer;A:TLocalBotAgent;
begin
  RemoveCrossing;
  FElapsed:=Value.Elapsed;FSelectionTime:=Value.SelectionTime;FReferencePower:=Value.ReferencePower;
  for I:=0 to LocalBotCount-1 do begin A:=GetAgent(I);
    A.Spawned:=Value.Bots[I].Spawned;A.StepDebt:=Value.Bots[I].StepDebt;
    SetVisible(I,Value.Bots[I].Visible,False);
    A.AnimationDebt:=Value.Bots[I].AnimationDebt;
    A.Effort:=Value.Bots[I].Effort;
    A.StartGroundPending:=A.Visible;
  end;
  FCrossUsed:=Copy(Value.CrossUsed);
  if Value.CrossActive then begin
    CreateCrossing(Value.CrossRoute,Value.CrossVisual);
    if FCrossAgent<>nil then FCrossAgent.RestoreReplay(Value.CrossState);
  end;
  for I:=0 to LocalBotCount-1 do if Value.Bots[I].HasBike and(FBikes[I]<>nil)then begin
    if FPoses[I]<>nil then TRiderPoseManager(FPoses[I]).RestoreReplay(Value.Bots[I].Pose);
    if(FCrossAgent<>nil)and(I=FCrossVisual)then
      TRiderPoseManager(FPoses[LocalBotCount]).RestoreReplay(Value.CrossPose);
    TBikeInstance(FBikes[I]).RestoreReplay(Value.Bots[I].Bike);
    Inc(TBikeInstance(FBikes[I]).RiderScene.RenderOptions.CachedAnimationRevision);
    InvalidateShadowPose(I);
  end;
  { Restoring a borrowed crossing model must not advance the spawn clock. }
  FNextAppearance:=Value.NextAppearance;FNextOncoming:=Value.NextOncoming;
end;

function TLocalBots.Diagnostics:TJSONObject;
var I:Integer;Rows:TJSONArray;A:TLocalBotAgent;B:TBikeInstance;P,V,BB,Saddle:TVector3;
  RiderDistance,CameraDistance:Single;InCamera:Boolean;
  Fit:TJSONObject;SeatExt,SaddleOff,Spacers,Stem:Single;
  Frame:TFrameComponent;Crank:TCranksetComponent;
begin
  Result:=TJSONObject.Create(['count',FAgents.Count,'company_count',LocalBotCount,
    'pose_cache_policy',FPoseCachePolicy,
    'crossings',Length(FCrossings),'cross_active',FCrossAgent<>nil,
    'cross_created',FCrossSerial,'cross_removed',FCrossRemoved,
    'cross_failed',FCrossFailed,'cross_error',FCrossError,
    'visible',FVisibleCount,'limit',FRenderLimit,
    'ready',FReady,'prepared',FPrepareIndex,'max_prepare_ms',Int64(FMaxPrepareMs),
    'last_switch_ms',Int64(FLastSwitchMs),'max_switch_ms',Int64(FMaxSwitchMs),
    'elapsed',FElapsed,'reference_power',FReferencePower,
    'next_appearance',FNextAppearance,'next_oncoming',FNextOncoming,
    'render_enabled',FRenderEnabled,'route_length',FLength,
    'avatar_station',Station(FAvatar.Path.Position),'out_and_back',FAvatar.Path.OutAndBack]);
  Rows:=TJSONArray.Create;Result.Add('bots',Rows);
  Result.Add('shader_warmup',FShaderWarmup.Diagnostics);
  Result.Add('prepare_stage_max_ms',TJSONArray.Create([Int64(FPrepareTimes[0]),Int64(FPrepareTimes[1]),
    Int64(FPrepareTimes[2]),Int64(FPrepareTimes[3]),Int64(FPrepareTimes[4])]));
  for I:=0 to LocalBotCount-1 do begin A:=GetAgent(I);P:=A.State.WorldPosition;
    V:=VisibilityPosition(A);RiderDistance:=(V-FAvatar.State.WorldPosition).Length;
    CameraRelation(A,CameraDistance,InCamera);
    Rows.Add(TJSONObject.Create(['index',I,'spawned',A.Spawned,'visible',A.Visible,
      'oncoming',A.Oncoming,'heading',TJSONArray.Create([A.State.ForwardDir.X,A.State.ForwardDir.Y,A.State.ForwardDir.Z]),
      'model_loaded',FBikes[I]<>nil,'ability',FProfiles[I].Ability,
      'effort',BotEffortModeName(A.Effort.Mode),'reserve_pct',A.Effort.Energy*100,
      'fatigue_pct',A.Effort.Fatigue*100,'desired_watts',A.Effort.PowerWatts,
      'effort_time',A.Effort.ModeTime,'chases',A.Effort.Chases,'overtakes',A.Effort.Overtakes,
      'attacks',A.Effort.Attacks,'recoveries',A.Effort.Recoveries,
      'gap',RouteGap(I),'distance',A.State.CumulativeDistance,'speed',A.State.CurrentSpeed,
      'power',A.State.AppliedPowerWatts,'physics_lod',Ord(A.PhysicsLOD),
      'visibility_position',TJSONArray.Create([V.X,V.Y,V.Z]),
      'rider_distance',RiderDistance,'camera_distance',CameraDistance,'in_camera',InCamera,
      'ground_pending',A.StartGroundPending,'ground_valid',A.Physics.GroundPlacementValid,
      'position',TJSONArray.Create([P.X,P.Y,P.Z]),'name',A.Name,'catalog_index',FProfiles[I].CatalogIndex,'body',WriteRiderBody(FProfiles[I].Body)]));
    B:=TBikeInstance(FBikes[I]);
    if (B<>nil)and(B.RiderScene<>nil)then begin
      Rows.Objects[Rows.Count-1].Add('pose_cache_revision',Int64(B.RiderScene.RenderOptions.CachedAnimationRevision));
      Rows.Objects[Rows.Count-1].Add('model_enabled',B.Group.Exists);
      ReadFitAdjustments(B,SeatExt,SaddleOff,Spacers,Stem);
      Fit:=TJSONObject.Create(['seatpost_mm',SeatExt,'saddle_offset_mm',SaddleOff,
        'spacers_mm',Spacers,'stem_mm',Stem,'wheelbase_mm',B.AxleHalfSpanM*2000]);
      Rows.Objects[Rows.Count-1].Add('fit',Fit);
      if B.BikeAnchor('bb',BB) and B.BikeAnchor('saddle_contact',Saddle) then
        Fit.Add('saddle_height_mm',(Saddle-BB).Length*1000);
      Frame:=TFrameComponent(B.Component(TFrameComponent));
      if Frame<>nil then begin
        Fit.Add('seat_tube_mm',Frame.SeatTubeLength);
        Fit.Add('stack_mm',Frame.Stack);Fit.Add('reach_mm',Frame.Reach);
      end;
      Crank:=TCranksetComponent(B.Component(TCranksetComponent));
      if Crank<>nil then Fit.Add('crank_mm',Crank.CrankLength);
    end;
  end;
  Rows:=TJSONArray.Create;Result.Add('crossing_routes',Rows);
  for I:=0 to High(FCrossings)do begin P:=FCrossings[I].Center;
    Rows.Add(TJSONObject.Create(['distance',FCrossings[I].RouteDistance,
      'way',FCrossings[I].WayId,'width',FCrossings[I].Width,
      'points',Length(FCrossings[I].Points),'center',TJSONArray.Create([P.X,P.Y,P.Z])]));
  end;
  if FCrossAgent<>nil then begin
    P:=FCrossAgent.State.WorldPosition;
    Result.Add('cross_bot',TJSONObject.Create(['route',FCrossRoute,'visual',FCrossVisual,
      'distance',FCrossAgent.State.CumulativeDistance,'length',FCrossLength,
      'position',TJSONArray.Create([P.X,P.Y,P.Z])]));
  end;
end;
end.
