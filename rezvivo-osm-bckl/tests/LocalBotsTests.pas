program LocalBotsTests;
{$mode objfpc}{$H+}
uses SysUtils, Math, Classes, CastleVectors, CastleTransform, GameLocalBotProfile,
  GameLocalBots, GamePath, GamePhysicalAgent, GamePhysicsCommon, GameAgentControllers,
  Osm3dRouteSnapper, Osm3dGeoMath, Osm3dMapUtils, GameFitLoadProfile, GameBotEffort,
  GameBotCompanyMotion, GameBotRouteExcursion;
var Checks:Integer;
procedure Check(B:Boolean;const Message:string);
begin Inc(Checks);if not B then raise Exception.Create(Message) end;

procedure ExcursionPhysics;
var Owner:TComponent;A:TLocalBotAgent;C:TLocalBotController;P:TPathPosition;
    Target:TBotExcursionTarget;V:TBotWaitInput;Control:TBotWaitControl;
    I:Integer;StopAt:Double;
begin
  Owner:=TComponent.Create(nil);A:=TLocalBotAgent.Create(Owner);
  try
    A.SetupActor(TCastleTransform.Create(Owner),nil,nil,nil,nil,nil);
    A.Path.LoadFromMemory([Vector3(0,0,0),Vector3(0,0,2000),Vector3(2000,0,2000),Vector3(2000,0,0)],[8,8,8,8]);
    A.RecreatePhysics(pmKinematicCurrent);A.SetPhysicsLOD(plMinimal);
    A.Initialize;A.InitializeAtStart;A.Spawned:=True;
    P:=A.Path.Position;A.Path.AdvanceFollow(P,100);A.TeleportToPath(P);
    A.State.CumulativeDistance:=100;A.State.CurrentSpeed:=8;A.State.AvatarMass:=84;
    C:=TLocalBotController.Create;A.PowerControl:=C;A.SetController(C);
    C.SetEnabled(True);C.SetDesiredPower(220);
    Target:=Default(TBotExcursionTarget);RequestBotExcursion(Target,True,180,Vector3(0,0,180));
    V:=Default(TBotWaitInput);V.Mass:=84;V.RidingPower:=220;
    for I:=1 to 900 do begin
      V.Distance:=A.State.CumulativeDistance;V.Speed:=A.State.CurrentSpeed;
      Control:=StepBotExcursionWait(A.ExcursionWait,Target,A.State.CumulativeDistance,8000,V,0.2);
      C.SetEnabled(Control.Enabled);C.SetDesiredPower(Control.Power);C.BrakeForce:=Control.BrakeForce;
      A.UpdateOffline(0.2,0.05,5);
      if A.ExcursionWait.Waiting then Break;
    end;
    Check(A.ExcursionWait.Waiting,'actual hidden bot reaches interception stop');
    Check(not A.State.AutoMove and(A.State.CurrentSpeed=0)and(A.State.AppliedPowerWatts=0)
      and(A.RequestedCadence=0),'waiting bot publishes grounded pose and stopped crank inputs');
    Check(Abs(A.State.CumulativeDistance-180)<3,'actual route physics stops near intersection');
    StopAt:=A.State.CumulativeDistance;
    for I:=1 to 100 do A.UpdateOffline(0.2,0.05,5);
    Check(A.State.CumulativeDistance=StopAt,'waiting physics holds physical position');
    ResetBotWait(A.Waiting,44);C.BrakeForce:=0;
    V.Started:=True;V.RiderMoving:=True;
    for I:=1 to 60 do begin
      V.Distance:=A.State.CumulativeDistance;V.Speed:=A.State.CurrentSpeed;
      Control:=StepBotWait(A.Waiting,V,0.2);
      C.SetEnabled(Control.Enabled);C.SetDesiredPower(Control.Power);C.BrakeForce:=Control.BrakeForce;
      A.UpdateOffline(0.2,0.05,5);
    end;
    Check(A.State.AutoMove and(A.RequestedCadence>0)and(A.State.CumulativeDistance>StopAt+10),
      'waiting bot resumes physical route movement and pedalling after rider returns');
    Check(not A.State.FreeTravel and
      (Abs(A.State.WorldPosition.X)<=A.Path.RoadWidthAt(A.Path.Position)*0.5+0.01),
      Format('excursion company always uses its original route: free=%s x=%.3f width=%.3f lane=%.3f',
        [BoolToStr(A.State.FreeTravel,True),A.State.WorldPosition.X,
         A.Path.RoadWidthAt(A.Path.Position),A.State.LaneOffset]));
    Writeln('PASS actual bot excursion stop, waiting pose inputs, resume');
  finally A.Free;Owner.Free end;
end;

procedure Profiles;
var I,J,K,Near,Weak,Strong:Integer;P,Q:TLocalBotProfile;W:Single;
  Seen:array[0..LocalBotCatalogCount-1]of Boolean;
  Seeds:array[0..3]of Cardinal=(0,12345,987654321,High(Cardinal));
begin
  Check(LocalBotCatalogCount=100,'fixed catalog size');
  for I:=0 to LocalBotCatalogCount-1 do begin
    P:=LocalBotCatalogProfile(I);
    Check((P.CatalogIndex=I)and(Length(P.DisplayName)>5),'stable identity');
    Check((P.Body.HeightCm>=150)and(P.Body.HeightCm<=200),'catalog height');
    Check((P.Body.WeightKg>=42)and(P.Body.WeightKg<=115),'catalog mass');
    for J:=0 to I-1 do begin
      Q:=LocalBotCatalogProfile(J);
      Check(P.DisplayName<>Q.DisplayName,'unique international names');
    end;
  end;
  for K:=0 to High(Seeds) do begin
    FillChar(Seen,SizeOf(Seen),0);
    for I:=0 to LocalBotCatalogCount-1 do begin
      P:=MakeLocalBotProfile(I,Seeds[K]);
      Check(not Seen[P.CatalogIndex],'selection without repeats');
      Seen[P.CatalogIndex]:=True;
      Q:=LocalBotCatalogProfile(P.CatalogIndex);
      Check(CompareMem(@P,@Q,SizeOf(P)),'selection retains fixed ability and character');
      Check((P.DisplayName=Q.DisplayName)and CompareMem(@P.Body,@Q.Body,SizeOf(P.Body))
        and CompareMem(@P.Colors,@Q.Colors,SizeOf(P.Colors))
        and (P.Hair=Q.Hair)and(P.Headwear=Q.Headwear)and(P.Beard=Q.Beard)
        and(P.Mustache=Q.Mustache),'selection retains authored appearance');
    end;
  end;
  Near:=0;Weak:=0;Strong:=0;
  for I:=0 to LocalBotCount-1 do begin
    P:=MakeLocalBotProfile(I,12345);Q:=MakeLocalBotProfile(I,12345);
    Check(CompareMem(@P,@Q,SizeOf(P)),'deterministic appearance/effort');
    if P.Ability<0.85 then Inc(Weak)else if P.Ability>1.15 then Inc(Strong)else Inc(Near);
    W:=LocalBotSustainablePower(P,200,84);
    Check((W>100)and(W<400),'plausible sustainable power');
    Check((P.CapacitySeconds>=65)and(P.RecoverySeconds>=55),'individual reserve/recovery');
    Check(LocalBotSustainablePower(P,200,100)<W,'mass scaling');
  end;
  Check((Weak=1)and(Strong=1)and(Near=5),'ability distribution');
  Check(BotCanAppear(-90,90,100,False),'behind, outside camera');
  Check(not BotCanAppear(-90,90,100,True),'no pop into camera');
  Check(not BotCanAppear(90,90,100,False),'no appearance ahead');
  Check(not BotCanAppear(-90,15,100,False),'nearby hairpin is not safely behind');
  Check(not BotCanDisappear(239,300,False),'exit hysteresis');
  Check(BotCanDisappear(250,260,False),'far and unseen exit');
  Check(not BotCanDisappear(250,10,True),'free camera keeps watched cyclist');
end;

procedure EffortReplay;
var A,B,Saved:TBotEffortState;V:TBotEffortInput;I:Integer;Previous:Single;
begin
  V:=Default(TBotEffortInput);V.SustainableWatts:=224;V.CapacitySeconds:=45;
  V.RecoverySeconds:=65;V.Aggression:=0.7;V.Racing:=True;V.Gap:=-72;
  V.RiderSpeed:=8;V.Speed:=8;
  ResetBotEffort(A,12345,200);B:=A;
  for I:=1 to 600 do begin
    Previous:=A.PowerWatts;StepBotEffort(A,V,0.5);
    Check(Abs(A.PowerWatts-Previous)<=10.001,'effort slew at most 20 W/s');
    Check((A.Energy>=0)and(A.Energy<=1)and(A.Fatigue>=0)and(A.Fatigue<=1),'bounded effort');
    StepBotEffort(B,V,0.125);StepBotEffort(B,V,0.125);
    StepBotEffort(B,V,0.125);StepBotEffort(B,V,0.125);
  end;
  Check(CompareMem(@A,@B,SizeOf(A)),'effort independent of rendering cadence');
  Check((A.Chases>1)and(A.Recoveries>0),'failed chase -> recover -> try again');
  Saved:=A;
  for I:=1 to 300 do StepBotEffort(A,V,0.5);
  B:=Saved;for I:=1 to 300 do StepBotEffort(B,V,0.5);
  Check(CompareMem(@A,@B,SizeOf(A)),'rewind preserves reserve, timers and randomness');
  V.Racing:=False;
  for I:=1 to 120 do begin
    StepBotEffort(A,V,0.5);
    Check(A.Mode in[bemCruise,bemRecover],'oncoming does not chase the avatar');
  end;
end;

procedure EffortRide(Ability:Single);
const Dt=0.1;Steps=18000;
var Owner:TComponent;A,R:TLocalBotAgent;Points:array[0..3]of TVector3;
  V:TBotEffortInput;I,Passes,Drops:Integer;Gap,PreviousGap,Lo,Hi:Single;
  P:TPathPosition;Mode:TBotEffortMode;ModeSeconds:array[TBotEffortMode]of Single;
  function Agent(Watts:Single):TLocalBotAgent;
  begin
    Result:=TLocalBotAgent.Create(Owner);
    Result.SetupActor(TCastleTransform.Create(Owner),nil,nil,nil,nil,nil);
    Result.Path.LoadFromMemory(Points,[]);Result.RecreatePhysics(pmKinematicCurrent);
    Result.SetPhysicsLOD(plMinimal);Result.Initialize;Result.InitializeAtStart;
    Result.Spawned:=True;Result.State.AvatarMass:=84;Result.State.CurrentSpeed:=8;
    Result.PowerControl:=TPowerController.Create;Result.SetController(Result.PowerControl);
    Result.PowerControl.SetEnabled(True);Result.PowerControl.SetDesiredPower(Watts);
  end;
begin
  Owner:=TComponent.Create(nil);
  Points[0]:=Vector3(0,0,0);Points[1]:=Vector3(20000,0,0);
  Points[2]:=Vector3(20000,0,20000);Points[3]:=Vector3(0,0,20000);
  A:=Agent(200);R:=Agent(200);
  try
    P:=A.Path.Position;A.Path.AdvanceFollow(P,-72);A.TeleportToPath(P);
    A.State.CumulativeDistance:=-72;A.State.CurrentSpeed:=8;
    V:=Default(TBotEffortInput);V.SustainableWatts:=224*Ability;
    V.CapacitySeconds:=75;V.RecoverySeconds:=65;V.Aggression:=0.7;V.Racing:=True;
    ResetBotEffort(A.Effort,12345,200*Ability);
    Passes:=0;Drops:=0;PreviousGap:=-72;Lo:=-72;Hi:=-72;
    FillChar(ModeSeconds,SizeOf(ModeSeconds),0);
    for I:=1 to Steps do begin
      V.Gap:=A.State.CumulativeDistance-R.State.CumulativeDistance;
      V.Speed:=A.State.CurrentSpeed;V.RiderSpeed:=R.State.CurrentSpeed;
      A.PowerControl.SetDesiredPower(StepBotEffort(A.Effort,V,Dt));
      ModeSeconds[A.Effort.Mode]:=ModeSeconds[A.Effort.Mode]+Dt;
      A.UpdateOffline(Dt,1/60,12);R.UpdateOffline(Dt,1/60,12);
      Gap:=A.State.CumulativeDistance-R.State.CumulativeDistance;
      if (PreviousGap<=0)and(Gap>0)then Inc(Passes);
      if (PreviousGap>=0)and(Gap<0)then Inc(Drops);
      Lo:=Min(Lo,Gap);Hi:=Max(Hi,Gap);PreviousGap:=Gap;
    end;
    Writeln('effort ride ability=',Ability:0:2,' pass=',Passes,' drop=',Drops,
      ' gap=',Lo:0:1,'..',Hi:0:1,' final=',Gap:0:1,' reserve=',A.Effort.Energy:0:2,
      ' fatigue=',A.Effort.Fatigue:0:2,' attacks=',A.Effort.Attacks,' recoveries=',A.Effort.Recoveries);
    for Mode:=Low(Mode)to High(Mode)do Write(BotEffortModeName(Mode),'=',ModeSeconds[Mode]:0:0,'s ');
    Writeln;
    if Abs(Ability-1)<0.01 then begin
      Check(Passes>=2,'peer catches and passes again after recovery');
      Check(Drops>=2,'peer tires and falls behind');
      Check((A.Effort.Attacks>0)and(A.Effort.Recoveries>0),'physical attack/recover cycle');
    end;
    Check(R.State.AppliedPowerWatts=200,'bot effort never modifies avatar watts');
  finally A.Free;R.Free;Owner.Free end;
end;

procedure Lanes;
var M:TLaneManager;I,H:Integer;
begin
  M:=TLaneManager.Create;
  try
    M.RegisterRider(Pointer(1));
    for I:=1 to 10000 do begin
      H:=M.RegisterRider(Pointer(2));Check(H=1,'reuse lane handles');
      M.UnregisterRider(H);
    end;
    Check(M.RiderCount=2,'no growing registry on visibility changes');
  finally M.Free end;
end;

procedure Crossings;
var Proj:TLocalProjection;O:TLatLon;Route:TRouteLatLonArray;Ways:TRouteWayIdArray;
  Segs:TSnapSegmentArray;Cross:TBotCrossingArray;I,J,K:Integer;Last:Double;
  procedure Segment(X0,Z0,X1,Z1,Width:Single;Way:Int64;Bridge:Boolean=False);
  var N:Integer;
  begin N:=Length(Segs);SetLength(Segs,N+1);
    Check(TRouteSnapper.MakeSnapSegment(X0,Z0,X1,Z1,Width,Way,Segs[N],Bridge),'valid segment');
  end;
begin
  O.Lat:=55.75;O.Lon:=37.62;Proj:=TLocalProjection.Create(O);
  try
    SetLength(Route,1501);SetLength(Ways,Length(Route));
    for I:=0 to High(Route)do begin Route[I]:=Proj.Unproject(0,I*20);Ways[I]:=1 end;
    Segment(0,0,0,30000,8,1);
    for I:=1 to 29 do begin
      { Real OSM ways split at intersections and tile boundaries. }
      for J:=-10 to 9 do Segment(J*20,I*1000,(J+1)*20,I*1000,8,1000+I*20+J);
    end;
    Cross:=TRouteSnapper.BotCrossings(Route,Segs,Proj,Ways);
    Check(Length(Cross)>=3,'cross roads every 3..10 km');Last:=0;
    for I:=0 to High(Cross)do begin
      Check(Cross[I].RouteDistance-Last>=2999,'minimum cross spacing');
      Check(Cross[I].RouteDistance-Last<=10001,'maximum cross spacing with roads available');
      Check(Length(Cross[I].Points)>10,'follows road polyline');
      Check((Cross[I].Points[0]-Cross[I].Center).Length>=159,'spawn far off route');
      Last:=Cross[I].RouteDistance;
    end;
    for K:=0 to High(Segs)do if Segs[K].WayId<>1 then Segs[K].IsBridge:=True;
    Cross:=TRouteSnapper.BotCrossings(Route,Segs,Proj,Ways);
    Check(Length(Cross)=0,'no grade-separated crossings');
    for K:=0 to High(Segs)do begin Segs[K].IsBridge:=False;Segs[K].Width:=3 end;
    Cross:=TRouteSnapper.BotCrossings(Route,Segs,Proj,Ways);
    Check(Length(Cross)=0,'no small paths masquerading as major roads');
    Segs:=nil;Segment(-50,5000,50,5000,8,9);
    Cross:=TRouteSnapper.BotCrossings(Route,Segs,Proj,Ways);
    Check(Length(Cross)=0,'do not extend a clipped road beyond real geometry');
  finally Proj.Free end;
end;

procedure ReversedRoutes;
var Path,Reverse,RoundTrip:TGamePath;Points,Centers:array[0..3]of TVector3;
  Widths:array[0..3]of Single;Src:array[0..3]of Double;
  D,H:TFitLoadValues;Profile:TFitLoadProfile;I,K:Integer;P,Q:TPathPosition;
  G,S,Y,RG,RS,RY:Single;
begin
  Path:=TGamePath.Create;Reverse:=TGamePath.Create;RoundTrip:=TGamePath.Create;
  try
    Points[0]:=Vector3(0,0,0);Points[1]:=Vector3(500,20,0);
    Points[2]:=Vector3(500,10,500);Points[3]:=Vector3(0,0,500);
    SetLength(D,5);SetLength(H,5);
    for I:=0 to 3 do begin
      Centers[I]:=Points[I]+Vector3(0.4,0,0.3);Widths[I]:=4+I;Src[I]:=I;
      D[I]:=I*500;H[I]:=Points[I].Y;
    end;
    D[4]:=2000;H[4]:=0;Profile:=BuildFitLoadProfile(D,H);
    Path.LoadFromMemory(Points,Widths);Path.SetPointCenters(Centers);
    Path.SetFitLoadProfile(Profile,Src);Path.CopyTo(Reverse,True);
    Reverse.CopyTo(RoundTrip,True);
    for I:=0 to 3 do for K:=1 to 9 do begin
      P.Segment:=I;P.T:=K/10;Q:=Path.ReversedPosition(P);
      Check((Path.RoadCenterAt(P)-Reverse.RoadCenterAt(Q)).Length<0.001,'reversed road centers');
      Check((Path.FollowTangent(P)+Reverse.FollowTangent(Q)).Length<0.001,'reversed heading');
      Check(Abs(Path.RoadWidthAt(P)-Reverse.RoadWidthAt(Q))<0.001,'reversed widths');
      Check(Path.FitLoadAtPosition(P,G,S,Y)and Reverse.FitLoadAtPosition(Q,RG,RS,RY),'reversed FIT exists');
      Check(Abs(S-RS)<0.001,'reversed FIT station including loop seam');
      Check(Abs(G+RG)<0.001,'reversed FIT grade');
      Check(Abs(Y-RY)<0.001,'reversed FIT height');
      Check(RoundTrip.FitLoadAtPosition(P,RG,RS,RY)and(Abs(G-RG)<0.001),'double reversal grade');
    end;
    Path.Clear;
    Check(Reverse.PointCount=4,'reversed data remains alive without source');
    Points[0]:=Vector3(0,0,0);Points[1]:=Vector3(500,20,0);
    Points[2]:=Vector3(1000,40,0);Points[3]:=Points[1];
    Src[3]:=1;Path.LoadFromMemory(Points,Widths);Path.UsePreparedCornerHints(True);
    Path.SetFitLoadProfile(Profile,Src);Path.CopyTo(Reverse,True);
    Check(Reverse.OutAndBack,'reversed endpoint metadata');
    for I:=0 to 3 do begin
      P.Segment:=I;P.T:=0.4;Q:=Path.ReversedPosition(P);
      Check((Path.RoadCenterAt(P)-Reverse.RoadCenterAt(Q)).Length<0.001,'out-and-back center');
      Check(Path.FitLoadAtPosition(P,G,S,Y)and Reverse.FitLoadAtPosition(Q,RG,RS,RY),'out-and-back profile');
      Check(Abs(S-RS)<0.001,'out-and-back station');
      Check(Abs(G+RG)<0.001,'out-and-back reversed grade');
    end;
  finally RoundTrip.Free;Reverse.Free;Path.Free end;
end;

procedure CoarseSimulation;
var Owner:TComponent;A:TLocalBotAgent;P:array[0..3]of TVector3;I:Integer;D:Single;
begin
  Owner:=TComponent.Create(nil);A:=TLocalBotAgent.Create(Owner);
  try
    A.SetupActor(TCastleTransform.Create(Owner),nil,nil,nil,nil,nil);
    P[0]:=Vector3(0,0,0);P[1]:=Vector3(1000,0,0);
    P[2]:=Vector3(1000,0,1000);P[3]:=Vector3(0,0,1000);
    A.Path.LoadFromMemory(P,[]);A.RecreatePhysics(pmKinematicCurrent);A.SetPhysicsLOD(plMinimal);
    A.Initialize;A.InitializeAtStart;A.Spawned:=True;
    A.PowerControl:=TPowerController.Create;A.SetController(A.PowerControl);
    A.PowerControl.SetEnabled(True);A.PowerControl.SetDesiredPower(200);
    for I:=1 to 60*60 do A.UpdateOffline(1/60,1/60,4);
    D:=A.State.CumulativeDistance;Check(D>200,'hidden bot keeps moving');
    Check(A.State.CurrentSpeed>5,'hidden bot responds to power');
    Check(A.PhysicsLOD=plMinimal,'hidden bot uses no surface queries');
    Writeln('hidden 60 s distance=',D:0:2,' speed=',A.State.CurrentSpeed:0:2);
  finally A.Free;Owner.Free end;
end;
begin
  Profiles;Lanes;Crossings;ReversedRoutes;CoarseSimulation;EffortReplay;ExcursionPhysics;
  EffortRide(1);EffortRide(0.8);EffortRide(1.25);
  Writeln('LOCAL_BOTS_OK ',Checks,' checks');
end.
