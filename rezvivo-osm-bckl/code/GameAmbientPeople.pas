unit GameAmbientPeople;
{$mode objfpc}{$H+}
interface
uses Classes, SysUtils, CastleVectors, CastleScene, CastleTransform, CastleViewport,
  GamePhysicalAgent, GamePhysicsCommon, GamePath, GameLocalBots, GameAmbientPeopleProfile,
  BikeParametric, RiderTripo, GameRiderShaderWarmup, GameBotShadow, Osm3dTravelRoads, fpjson;
const AmbientModelCount=2; AmbientRoutePoints=64;
type
  TAmbientRoadQuery=function(const Position:TVector3;Radius:Single):TTravelRoads of object;
  TAmbientRoute=record
    Count:Integer;
    Points:array[0..AmbientRoutePoints-1]of TVector3;
    Widths:array[0..AmbientRoutePoints-1]of Single;
    Length:Single;
  end;
  TAmbientYield=record
    Hold,ProbeDelay,ProbeAge,ProbeWidth:Single;
    ProbeCenter,ProbeForward,SafeCenter,SafeForward:TVector3;
    Pending,Safe:Boolean;
  end;
  TAmbientReplay=record
    Clock,NextAt:Double;
    Started:Boolean;
    Serial,Active:Integer;
    Route:TAmbientRoute;
    State:TAgentReplayState;
    Phase,AnimationDebt:Single;
    Yield:TAmbientYield;
  end;
  { At most one passer-by is visible, sharing the company's three-actor cap.
    Two fixed appearances are selected and warmed during loading; an encounter
    only attaches an existing model and a short route. No mid-ride asset IO. }
  TAmbientPeople=class
  private
    FOwner:TComponent;
    FViewport:TCastleViewport;
    FAvatar:TPhysicalAgent;
    FLanes:TLaneManager;
    FCompany:TLocalBots;
    FProfiles:array[0..AmbientModelCount-1]of TAmbientProfile;
    FAgents:array[0..AmbientModelCount-1]of TLocalBotAgent;
    FBikes:array[0..AmbientModelCount-1]of TBikeInstance;
    FShadows:array[0..AmbientModelCount-1]of TBotShadow;
    FWorker:TTripoGlbWorker;
    FWarmup:TRiderShaderWarmup;
    FJson,FError:string;
    FIndex,FStage,FActive,FSerial,FSpawned,FRemoved:Integer;
    FSeed:Cardinal;
    FReady,FPreparing,FStarted:Boolean;
    FClock,FNextAt,FRetryAt:Double;
    FMaxPrepareMs:QWord;
    FRoute:TAmbientRoute;
    FYield:TAmbientYield;
    FOnReady:TLocalBotReady;
    FRoadQuery:TAmbientRoadQuery;
    function BuildRoute(RunningBack:Boolean;Ahead:Single;out Route:TAmbientRoute):Boolean;
    procedure Hide;
    procedure Attach(Index:Integer);
    procedure CameraRelation(const P:TVector3;out Distance:Single;out InCamera:Boolean);
    function TrySpawn(Index:Integer;Ahead:Single;CheckVisibility:Boolean):Boolean;
    procedure PlanTraffic(Dt:Single);
    function GetActiveAgent:TLocalBotAgent;
  public
    constructor Create(Owner:TComponent;Viewport:TCastleViewport;Level:TCastleScene;
      Avatar:TPhysicalAgent;Company:TLocalBots;Seed:Cardinal);
    destructor Destroy;override;
    procedure PrepareNext;
    procedure ResetOnRoute(Lanes:TLaneManager;Avatar:TPhysicalAgent);
    procedure BeforePhysics(Dt:Single;Enabled:Boolean);
    procedure UpdatePhysics(Dt:Single);
    procedure Animate(Dt:Single;Enabled:Boolean);
    procedure RefreshPose(Model:TBikeInstance);
    procedure AppendShadowCasters(List:TCastleTransformList;UseRtx:Boolean);
    function Bike(Index:Integer):TBikeInstance;
    function CaptureReplay:TAmbientReplay;
    procedure RestoreReplay(const State:TAmbientReplay);
    function Diagnostics:TJSONObject;
    { Isolated MCP regression only; actual encounters always pass visibility checks. }
    function ProbeSpawn(Kind:TAmbientKind;Ahead:Single):Boolean;
    property Ready:Boolean read FReady;
    property PreparedCount:Integer read FIndex;
    property OnReady:TLocalBotReady read FOnReady write FOnReady;
    property RoadQuery:TAmbientRoadQuery read FRoadQuery write FRoadQuery;
    property ActiveAgent:TLocalBotAgent read GetActiveAgent;
    property Serial:Integer read FSerial;
  end;
function BuildAmbientRoadRoute(const Roads:TTravelRoads;const Rider:TVector3;
  Reverse:Boolean;out Route:TAmbientRoute):Boolean;
implementation
uses Math, CastleTimeUtils, CastleURIUtils, jsonparser, RiderBodyParameters,
  RiderGarmentState, RiderHeadAppearance, GameAgentControllers, GameRiderTraffic,
  GameBikeAvatar, GameRiderWardrobe, GamePedestrianTraffic, AppSettings, DebugLog;

function BuildAmbientRoadRoute(const Roads:TTravelRoads;const Rider:TVector3;
  Reverse:Boolean;out Route:TAmbientRoute):Boolean;
var I,J,Index,Direction,Next,ND,K:Integer;P,Q,D,V:TVector3;
  Distance,Best,Score,Dot,L:Single;Used:array of Boolean;
begin
  Route:=Default(TAmbientRoute);Result:=False;Index:=-1;Best:=1e30;Direction:=1;
  for I:=0 to High(Roads)do begin
    if(Roads[I].Width<1.8)or(Roads[I].Width>10)then Continue;
    for K:=0 to 1 do begin
      if K=0 then P:=Roads[I].A else P:=Roads[I].B;
      Distance:=Sqrt(RoadDistanceSq(P,Rider));
      if(Distance<55)or(Distance>150)then Continue;
      Score:=Abs(Distance-85);
      if Score<Best then begin Best:=Score;Index:=I;Direction:=1-2*K end;
    end;
  end;
  if Index<0 then Exit;
  if Reverse then Direction:=-Direction;
  SetLength(Used,Length(Roads));
  for K:=0 to AmbientRoutePoints-2 do begin
    Used[Index]:=True;
    if Direction>0 then begin P:=Roads[Index].A;Q:=Roads[Index].B end
    else begin P:=Roads[Index].B;Q:=Roads[Index].A end;
    if Route.Count=0 then begin Route.Points[0]:=P;Route.Widths[0]:=Roads[Index].Width;Route.Count:=1 end;
    L:=(Q-P).Length;if L<0.1 then Break;
    Route.Points[Route.Count]:=Q;Route.Widths[Route.Count]:=Roads[Index].Width;
    Inc(Route.Count);Route.Length:=Route.Length+L;if Route.Length>=260 then Break;
    D:=(Q-P).Normalize;Next:=-1;Best:=-2;
    for J:=0 to High(Roads)do begin
      if Used[J]or(Roads[J].Width<1.8)or(Roads[J].Width>10)then Continue;
      ND:=0;
      if RoadDistanceSq(Q,Roads[J].A)<0.25 then begin ND:=1;V:=Roads[J].B-Roads[J].A end
      else if RoadDistanceSq(Q,Roads[J].B)<0.25 then begin ND:=-1;V:=Roads[J].A-Roads[J].B end;
      if(ND=0)or(V.Length<0.1)then Continue;
      Dot:=TVector3.DotProduct(D,V.Normalize);if Dot<0.1 then Continue;
      Score:=Dot;if Roads[J].WayId=Roads[Index].WayId then Score:=Score+0.15;
      if Score>Best then begin Best:=Score;Next:=J;Direction:=ND end;
    end;
    if Next<0 then Break;Index:=Next;
  end;
  Result:=(Route.Count>=2)and(Route.Length>=35);
end;

constructor TAmbientPeople.Create(Owner:TComponent;Viewport:TCastleViewport;Level:TCastleScene;
  Avatar:TPhysicalAgent;Company:TLocalBots;Seed:Cardinal);
var I:Integer;T:TCastleTransform;S:TCastleScene;A:TLocalBotAgent;
begin
  inherited Create;FOwner:=Owner;FViewport:=Viewport;FAvatar:=Avatar;FCompany:=Company;
  if(GetEnvironmentVariable('REZVIVO_TEST_NO_HARDWARE')='1')and
    (GetEnvironmentVariable('REZVIVO_TEST_AUTH_FILE')<>'')then
    Seed:=Cardinal(StrToQWordDef(GetEnvironmentVariable('REZVIVO_TEST_BOT_SEED'),Seed));
  FSeed:=Seed;FActive:=-1;FNextAt:=35+(Seed mod 26);FWarmup:=TRiderShaderWarmup.Create;
  for I:=0 to AmbientModelCount-1 do begin
    FProfiles[I]:=SelectAmbientProfile(TAmbientKind(I),Seed xor Cardinal(I*7919));
    T:=TCastleTransform.Create(FOwner);T.Name:='AmbientPerson'+IntToStr(I);
    S:=TCastleScene.Create(FOwner);S.Name:='AmbientPersonScene'+IntToStr(I);T.Add(S);
    A:=TLocalBotAgent.Create(FOwner);FAgents[I]:=A;A.Name:=FProfiles[I].Name;
    A.SetupActor(T,S,nil,Viewport,nil,Level);
    A.PowerControl:=TPowerController.Create;A.SetController(A.PowerControl);
    A.RecreatePhysics(pmKinematicCurrent);A.State.Walking:=True;A.State.WheelContactAtOrigin:=True;
    A.State.AvatarMass:=FProfiles[I].Body.WeightKg;A.Physics.SetWheelProbeHalfSpan(0.18);
    A.State.CollisionHalfWidth:=0.28;A.State.CollisionBodyHeight:=FProfiles[I].Body.HeightCm*0.01;
    A.SetPhysicsLOD(plReduced);A.Initialize;
  end;
end;
destructor TAmbientPeople.Destroy;
var I:Integer;
begin
  Hide;FreeAndNil(FWorker);FreeAndNil(FWarmup);
  for I:=0 to AmbientModelCount-1 do begin
    FreeAndNil(FShadows[I]);FreeAndNil(FBikes[I]);FreeAndNil(FAgents[I]);
  end;
  inherited;
end;
function TAmbientPeople.Bike(Index:Integer):TBikeInstance;
begin Result:=nil;if(Index>=0)and(Index<AmbientModelCount)then Result:=FBikes[Index] end;
function TAmbientPeople.GetActiveAgent:TLocalBotAgent;
begin Result:=nil;if FActive>=0 then Result:=FAgents[FActive] end;

procedure TAmbientPeople.PrepareNext;
var Text:TStringList;O,R:TJSONObject;B:TBikeInstance;A:TLocalBotAgent;
  Path:string;Slot:TClothSlot;Advance:Boolean;Tick:QWord;
begin
  if FReady or FPreparing then Exit;
  FPreparing:=True;Tick:=GetTickCount64;
  try
    B:=FBikes[FIndex];A:=FAgents[FIndex];Advance:=True;
    try
      case FStage of
        0:begin
          Path:=WardrobeRiderPathFor(ResolveRiderGlbPath('castle-data:/avatars/RIDER.glb'),FProfiles[FIndex].Outfit);
          FWorker:=TTripoGlbWorker.Create(Path);
          Text:=TStringList.Create;
          try
            Text.LoadFromFile(BikeJsonUrlToFilename('castle-data:/bike_road2.json'));
            O:=TJSONObject(GetJSON(InjectRiderPath(Text.Text,Path,False)));
          finally Text.Free end;
          try
            R:=O.Objects['tripoRider'];R.Delete('body');R.Add('body',WriteRiderBody(FProfiles[FIndex].Body));
            R.Delete('garment');R.Add('garment',WriteRiderGarment(DefaultRiderGarment(FSeed+FIndex)));
            R.Floats['scale']:=1;FJson:=O.AsJSON;
          finally O.Free end;
          B:=LoadBikeInstanceFromJSONString(FJson,FOwner,12,30,65,False,True,True);
          FBikes[FIndex]:=B;B.ShadowMode:=bsmNone;A.Actor.Scene.Add(B.Group);
          B.ClothDyePresetMode:=cdmShader;
          for Slot:=Low(Slot)to High(Slot)do B.StageRiderClothColor(Slot,FProfiles[FIndex].Colors[Slot]);
        end;
        1:begin
          if not FWorker.Finished then Exit;
          AttachTripoRiderFromJSON(B,FJson,FWorker.Prepared);FreeAndNil(FWorker);FJson:='';
          if not B.HasTripoRider then raise Exception.Create('Pedestrian model unavailable');
        end;
        2:begin
          B.TripoRider.HairStyle:=FProfiles[FIndex].Hair;
          B.TripoRider.SetHeadAppearance(FProfiles[FIndex].Headwear,FProfiles[FIndex].Beard,rmNone);
          B.SetHeadwearColorLive(FProfiles[FIndex].Colors[csJersey],True);
          B.VisualDetailRequired:=True;B.OnFoot:=True;B.AnimateOnFoot(0,0,Pi/2);
          B.RiderScene.RenderOptions.CachedAnimationRevision:=1;
          FShadows[FIndex]:=TBotShadow.Create(FOwner);B.Group.Add(FShadows[FIndex]);
          FShadows[FIndex].UpdatePose(B);
          if Assigned(FOnReady)then FOnReady(B,A);
        end;
        3:FViewport.PrepareResources(B.Group,[]);
        4:Advance:=FWarmup.Step(FViewport,A.Actor.Transform,B.Group,B.RiderScene);
      end;
      if Advance then Inc(FStage);
    except on E:Exception do begin
      FError:=E.ClassName+': '+E.Message;Logger.Warning('[AmbientPeople] '+FError);
      FreeAndNil(FWorker);FWarmup.Finish;FreeAndNil(FShadows[FIndex]);FreeAndNil(FBikes[FIndex]);FStage:=5;
    end end;
    if FStage>=5 then begin
      Inc(FIndex);FStage:=0;FReady:=FIndex>=AmbientModelCount;
      if FReady then FWarmup.Finish;
    end;
  finally FMaxPrepareMs:=Max(FMaxPrepareMs,GetTickCount64-Tick);FPreparing:=False end;
end;
procedure TAmbientPeople.ResetOnRoute(Lanes:TLaneManager;Avatar:TPhysicalAgent);
begin
  Hide;FLanes:=Lanes;FAvatar:=Avatar;FClock:=0;FRetryAt:=0;FStarted:=False;FSerial:=0;
  FNextAt:=35+(FSeed mod 26);
end;
procedure TAmbientPeople.Hide;
var A:TLocalBotAgent;H:Integer;
begin
  if FActive<0 then Exit;A:=FAgents[FActive];
  FViewport.Items.Remove(A.Actor.Transform);A.Visible:=False;A.Spawned:=False;
  A.PowerControl.SetEnabled(False);A.State.CurrentSpeed:=0;
  if FLanes<>nil then begin H:=FLanes.FindRider(A);if H>=0 then FLanes.UnregisterRider(H) end;
  ClearTrafficConstraints(A);FActive:=-1;Inc(FRemoved);FYield:=Default(TAmbientYield);
  if FCompany<>nil then FCompany.SetExternalVisible(0);
end;
procedure TAmbientPeople.CameraRelation(const P:TVector3;out Distance:Single;out InCamera:Boolean);
var C,D,U,V:TVector3;
begin
  FViewport.Camera.GetWorldView(C,D,U);V:=P+Vector3(0,1,0)-C;Distance:=V.Length;
  InCamera:=(Distance<1)or(TVector3.DotProduct(V,D)>Distance*0.40);
end;
function TAmbientPeople.BuildRoute(RunningBack:Boolean;Ahead:Single;out Route:TAmbientRoute):Boolean;
var P:TPathPosition;I:Integer;Dir,Width:Single;Roads:TTravelRoads;
begin
  Route:=Default(TAmbientRoute);Result:=False;
  if FAvatar=nil then Exit;
  if FAvatar.State.FreeTravel and Assigned(FRoadQuery)then begin
    Roads:=FRoadQuery(FAvatar.State.WorldPosition,180);
    Exit(BuildAmbientRoadRoute(Roads,FAvatar.State.WorldPosition,RunningBack,Route));
  end;
  if FAvatar.Path.PointCount<3 then Exit;
  Dir:=1;if RunningBack then Dir:=-1;
  P:=FAvatar.Path.Position;FAvatar.Path.AdvanceFollow(P,Ahead-Dir*25);
  for I:=0 to AmbientRoutePoints-1 do begin
    Width:=FAvatar.Path.RoadWidthAt(P);
    if(Width<1.8)or(Width>10)then Break;
    Route.Points[I]:=FAvatar.Path.RoadCenterAt(P);Route.Widths[I]:=Width;
    if I>0 then Route.Length:=Route.Length+(Route.Points[I]-Route.Points[I-1]).Length;
    Inc(Route.Count);FAvatar.Path.AdvanceFollow(P,Dir*5);
  end;
  Result:=(Route.Count>2)and(Route.Length>35);
end;
procedure TAmbientPeople.Attach(Index:Integer);
var A:TLocalBotAgent;B:TBikeInstance;
begin
  FActive:=Index;A:=FAgents[Index];B:=FBikes[Index];A.Spawned:=True;A.Visible:=True;
  A.StartGroundPending:=True;A.StepDebt:=0;A.AnimationDebt:=0;
  A.State.GroundQuery:=FAvatar.State.GroundQuery;A.State.SlopeQuery:=FAvatar.State.GroundQuery;
  A.State.PositionConstraint:=FAvatar.State.PositionConstraint;
  A.State.TravelTargetSpeed:=FProfiles[Index].Speed;A.State.AppliedPowerWatts:=0;
  A.PowerControl.SetDesiredPower(0);A.PowerControl.SetEnabled(True);A.SetPhysicsLOD(plReduced);
  B.Group.Exists:=True;B.Group.Visible:=True;B.VisualDetailRequired:=True;
  PlaceTrafficAgent(FLanes,A);B.AnimateOnFoot(0,0,Pi/2);
  FViewport.Items.Add(A.Actor.Transform);
  if FCompany<>nil then FCompany.SetExternalVisible(1);
end;
function TAmbientPeople.TrySpawn(Index:Integer;Ahead:Single;CheckVisibility:Boolean):Boolean;
var R:TAmbientRoute;A:TLocalBotAgent;P:TVector3;Ground,CameraDist,Dist:Single;InCamera,Reverse:Boolean;Pos:TPathPosition;
begin
  Result:=False;if not FReady or(FActive>=0)or(FBikes[Index]=nil)or(FAvatar=nil)then Exit;
  Reverse:=((FSeed+Cardinal(FSerial))mod 3)<>0;
  if not BuildRoute(Reverse,Ahead,R)then Exit;
  { Keep the cyclic follower's artificial closing corner behind the actor. }
  A:=FAgents[Index];A.Path.SetLevelScene(nil);
  A.Path.LoadFromMemory(Slice(R.Points,R.Count),Slice(R.Widths,R.Count));A.Path.BakeWorldPoints;
  A.Path.UsePreparedCornerHints(False);
  Pos.Segment:=0;Pos.T:=0;A.Path.AdvanceFollow(Pos,Min(25,R.Length*0.25));
  P:=A.Path.RoadCenterAt(Pos);P.Y:=FAvatar.State.WorldPosition.Y;
  if not Assigned(FAvatar.State.GroundQuery)or not FAvatar.State.GroundQuery(P.X,P.Z,P.Y,Ground)then Exit;
  P.Y:=Ground;Dist:=(P-FAvatar.State.WorldPosition).Length;
  CameraRelation(P,CameraDist,InCamera);
  if CheckVisibility and not AmbientCanAppear(Dist,CameraDist,InCamera)then Exit;
  if(FCompany<>nil)and not FCompany.ReserveAmbientSlot then Exit;
  FRoute:=R;A.Path.CarrotWobbleEnabled:=False;A.TeleportToPath(Pos);
  A.State.WorldPosition.Y:=Ground;A.State.LastGroundY:=Ground;A.State.CurrentSpeed:=0;
  A.State.CumulativeDistance:=Min(25,R.Length*0.25);A.Physics.ResetTrackingAfterTeleport;
  Attach(Index);Inc(FSerial);Inc(FSpawned);Result:=True;
end;
procedure TAmbientPeople.BeforePhysics(Dt:Single;Enabled:Boolean);
var A:TLocalBotAgent;Dist,CameraDist:Single;InCamera:Boolean;Kind:Integer;
begin
  if not Enabled or((FCompany<>nil)and(FCompany.RenderLimit=0))then begin Hide;Exit end;
  if not FReady or(FAvatar=nil)or(Dt<=0)then Exit;
  if Abs(FAvatar.State.CurrentSpeed)>0.2 then FStarted:=True;
  if not FStarted then Exit;
  FClock:=FClock+Dt;
  if FActive>=0 then begin
    A:=FAgents[FActive];Dist:=(A.State.WorldPosition-FAvatar.State.WorldPosition).Length;
    CameraRelation(A.State.WorldPosition,CameraDist,InCamera);
    if(Dist>320)or((Dist>180)and(CameraDist>100)and not InCamera)then begin
      Hide;FNextAt:=FClock+AmbientNextDelay(FSeed,FSerial);
    end;
    if FActive>=0 then PlanTraffic(Dt);
  end;
  if(FActive>=0)or(FClock<FNextAt)or(FClock<FRetryAt)then Exit;
  FRetryAt:=FClock+5;Kind:=(FSerial+Integer(FSeed mod 2))mod AmbientModelCount;
  TrySpawn(Kind,110,True);
end;
procedure TAmbientPeople.PlanTraffic(Dt:Single);
var A,Peer:TPhysicalAgent;I,H:Integer;Center,Dir,Right,Edge:TVector3;
    Width,Offset:Single;Risk,ProbeReady,Safe:Boolean;
  procedure CheckPeer(Peer:TPhysicalAgent);
  begin
    if(Peer=nil)or(Peer=A)or Peer.State.Walking then Exit;
    if PedestrianConflict(Edge,Dir,A.State.CurrentSpeed,Peer.State.WorldPosition,
      Peer.State.ForwardDir,Peer.State.CurrentSpeed)then Risk:=True;
  end;
begin
  A:=FAgents[FActive];Dir:=A.Path.FollowDirectionXZ(A.Path.Position);
  Right:=Vector3(-Dir.Z,0,Dir.X);Width:=A.Path.RoadWidthAt(A.Path.Position);
  Center:=A.Path.RoadCenterAt(A.Path.Position);Center.Y:=A.State.LastGroundY;
  Offset:=PedestrianEdge(Width);Edge:=Center+Right*Offset;Risk:=False;
  CheckPeer(FAvatar);
  if FLanes<>nil then for I:=0 to FLanes.RiderCount-1 do begin
    Peer:=TPhysicalAgent(FLanes.RiderTag(I));if Peer=FAvatar then Continue;
    CheckPeer(Peer);
  end;
  FYield.Hold:=Max(0,FYield.Hold-Dt);if Risk then FYield.Hold:=1.8;
  FYield.ProbeDelay:=Max(0,FYield.ProbeDelay-Dt);
  if FYield.Safe and(((Center-FYield.SafeCenter).LengthSqr>9)or
    (TVector3.DotProduct(Dir,FYield.SafeForward)<0.94))then FYield.Safe:=False;
  if FYield.Hold>0 then begin
    if not FYield.Pending and(FYield.ProbeDelay<=0)then begin
      { Fixed positions throughout an asynchronous terrain probe. Changing
        GPU-query coordinates every frame would keep them pending forever. }
      FYield.ProbeCenter:=Center;FYield.ProbeForward:=Dir;FYield.ProbeWidth:=Width;
      FYield.Pending:=True;FYield.ProbeAge:=0;
    end;
    if FYield.Pending then begin
      FYield.ProbeAge:=FYield.ProbeAge+Dt;
      Safe:=ProbePedestrianShoulder(A.State,FYield.ProbeCenter,FYield.ProbeForward,
        FYield.ProbeWidth,ProbeReady);
      if not Safe or ProbeReady or(FYield.ProbeAge>1)then begin
        FYield.Pending:=False;FYield.ProbeDelay:=0.35;
        if ProbeReady or not Safe then begin
          FYield.Safe:=Safe and ProbeReady and((Center-FYield.ProbeCenter).LengthSqr<=9)and
            (TVector3.DotProduct(Dir,FYield.ProbeForward)>=0.94);
          FYield.SafeCenter:=FYield.ProbeCenter;
          FYield.SafeForward:=FYield.ProbeForward;
        end;
      end;
    end;
    if FYield.Safe then Offset:=Offset+PedestrianShoulderExtra;
  end else begin FYield.Pending:=False;FYield.Safe:=False end;
  if FLanes<>nil then begin
    H:=FLanes.FindRider(A);FLanes.SetPedestrianLine(H,Offset);
  end else begin
    A.State.LaneOffsetExternal:=True;
    A.State.LaneOffset:=A.State.LaneOffset+
      EnsureRange((Offset-A.State.LaneOffset)*(1-Exp(-3*Dt)),-0.65*Dt,0.85*Dt);
    A.State.TrafficLookAhead:=Max(0.8,A.State.CurrentSpeed*0.45);
  end;
end;
procedure TAmbientPeople.UpdatePhysics(Dt:Single);
var A:TLocalBotAgent;Target:Single;
begin
  if(FActive<0)or(Dt<=0)then Exit;A:=FAgents[FActive];
  Target:=FProfiles[FActive].Speed*(1+0.035*Sin(FClock*0.15+FActive*2));
  if A.State.CumulativeDistance>FRoute.Length-8 then Target:=0;
  { Free exploration does not register the player's moving body in lanes. }
  if FAvatar.State.FreeTravel and
     ((FAvatar.State.WorldPosition-A.State.WorldPosition).Length<2)then Target:=0;
  A.State.TravelTargetSpeed:=Target;
  A.UpdateOffline(Dt,1/60,Max(4,Min(64,Ceil(Dt*60)+2)));
end;
procedure TAmbientPeople.Animate(Dt:Single;Enabled:Boolean);
var A:TLocalBotAgent;B:TBikeInstance;
begin
  if FActive<0 then Exit;A:=FAgents[FActive];B:=FBikes[FActive];
  if(Dt<=0)or not Enabled then Exit;
  { Gait adapts the legs to slope; do not also pitch/lean the whole body
    using the bicycle's wheel frame. Same convention as the walking player. }
  A.Actor.Scene.Rotation:=Vector4(0,1,0,ModelBaseYRotation);
  { AnimateOnFoot advances only phase while culled; it skips IK, soft tissue,
    cloth and skin uploads. Do not lose gait time by throttling that phase. }
  B.AnimateOnFoot(Dt,A.State.CurrentSpeed,Pi/2,
    Tan(DegToRad(EnsureRange(A.State.CurrentGroundPitch,-40,40))));
  if B.RiderScene.RenderOptions.CachedAnimationRevision<>0 then
    Inc(B.RiderScene.RenderOptions.CachedAnimationRevision);
end;
procedure TAmbientPeople.RefreshPose(Model:TBikeInstance);
var A:TLocalBotAgent;
begin
  if(FActive<0)or(Model<>FBikes[FActive])then Exit;
  A:=FAgents[FActive];A.Actor.Scene.Rotation:=Vector4(0,1,0,ModelBaseYRotation);
  Model.AnimateOnFoot(0,A.State.CurrentSpeed,Pi/2,
    Tan(DegToRad(EnsureRange(A.State.CurrentGroundPitch,-40,40))));
  Inc(Model.RiderScene.RenderOptions.CachedAnimationRevision);
end;
procedure TAmbientPeople.AppendShadowCasters(List:TCastleTransformList;UseRtx:Boolean);
var B:TBikeInstance;Distance:Single;InCamera:Boolean;
begin
  if FActive<0 then Exit;B:=FBikes[FActive];if not B.Group.Visible or not B.Group.Exists then Exit;
  CameraRelation(FAgents[FActive].State.WorldPosition,Distance,InCamera);
  FShadows[FActive].Active:=not UseRtx and(Distance>24);
  FShadows[FActive].CastShadows:=not UseRtx;
  if FShadows[FActive].Active then begin FShadows[FActive].UpdatePose(B);List.Add(FShadows[FActive]) end
  else List.Add(B.Group);
end;
function TAmbientPeople.CaptureReplay:TAmbientReplay;
begin
  Result:=Default(TAmbientReplay);Result.Clock:=FClock;Result.NextAt:=FNextAt;
  Result.Started:=FStarted;Result.Serial:=FSerial;Result.Active:=FActive;Result.Route:=FRoute;
  Result.Yield:=FYield;
  if FActive>=0 then begin
    Result.State:=FAgents[FActive].CaptureReplay;Result.Phase:=FBikes[FActive].OnFootPhase;
    Result.AnimationDebt:=FAgents[FActive].AnimationDebt;
  end;
end;
procedure TAmbientPeople.RestoreReplay(const State:TAmbientReplay);
var A:TLocalBotAgent;
begin
  Hide;FClock:=State.Clock;FNextAt:=State.NextAt;FRetryAt:=0;FStarted:=State.Started;FSerial:=State.Serial;
  if(State.Active<0)or(State.Active>=AmbientModelCount)or(FBikes[State.Active]=nil)then Exit;
  FRoute:=State.Route;A:=FAgents[State.Active];A.Path.SetLevelScene(nil);
  A.Path.LoadFromMemory(Slice(FRoute.Points,FRoute.Count),Slice(FRoute.Widths,FRoute.Count));A.Path.BakeWorldPoints;
  A.Path.UsePreparedCornerHints(False);A.Path.CarrotWobbleEnabled:=False;
  Attach(State.Active);A.RestoreReplay(State.State);A.AnimationDebt:=State.AnimationDebt;
  FYield:=State.Yield;
  FBikes[FActive].AnimateOnFoot(0,A.State.CurrentSpeed,Pi/2,0,State.Phase);
end;
function TAmbientPeople.ProbeSpawn(Kind:TAmbientKind;Ahead:Single):Boolean;
begin
  if(GetEnvironmentVariable('REZVIVO_TEST_NO_HARDWARE')<>'1')or
    (GetEnvironmentVariable('REZVIVO_TEST_AUTH_FILE')='')then raise Exception.Create('Isolated test profile required');
  Hide;FStarted:=True;Result:=TrySpawn(Ord(Kind),EnsureRange(Ahead,8,150),False);
end;
function TAmbientPeople.Diagnostics:TJSONObject;
var Rows:TJSONArray;O:TJSONObject;I:Integer;P:TVector3;
begin
  Result:=TJSONObject.Create(['ready',FReady,'prepared',FIndex,'active',FActive,'catalog_count',AmbientCatalogCount,
    'elapsed',FClock,'next_at',FNextAt,'serial',FSerial,'created',FSpawned,'removed',FRemoved,'error',FError,'max_prepare_ms',Int64(FMaxPrepareMs)]);
  Rows:=TJSONArray.Create;Result.Add('people',Rows);
  Result.Add('warmup',FWarmup.Diagnostics);
  Result.Add('yielding',FYield.Hold>0);Result.Add('shoulder_safe',FYield.Safe);
  Result.Add('shoulder_pending',FYield.Pending);
  for I:=0 to AmbientModelCount-1 do begin
    P:=FAgents[I].State.WorldPosition;
    O:=TJSONObject.Create(['name',FProfiles[I].Name,'catalog_index',FProfiles[I].CatalogIndex,
      'kind',Ord(FProfiles[I].Kind),'sex',FProfiles[I].Body.Sex,'speed',FAgents[I].State.CurrentSpeed,
      'distance',FAgents[I].State.CumulativeDistance,'x',P.X,'y',P.Y,'z',P.Z,
      'loaded',FBikes[I]<>nil,'visible',I=FActive,'top',FProfiles[I].Outfit[0],
      'bottom',FProfiles[I].Outfit[1],'outer',FProfiles[I].Outfit[2],'feet',FProfiles[I].Outfit[3]]);
    O.Add('lane_offset',FAgents[I].State.LaneOffset);
    O.Add('road_width',FAgents[I].Path.RoadWidthAt(FAgents[I].Path.Position));
    if FBikes[I]<>nil then begin O.Add('on_foot',FBikes[I].OnFoot);O.Add('phase',FBikes[I].OnFootPhase) end;
    Rows.Add(O);
  end;
end;
end.
