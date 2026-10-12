procedure TViewPlay.CancelWarmup(Sender:TObject);
begin FCancelWarmup:=True end;

procedure TViewPlay.LeaveRoute;
begin
  if FFreeExplore or not HasActiveState then Exit;
  FFreeExplore:=True;FRouteExcursion:=FActiveAvatarAgent.Path.PointCount>2;
  FExcursionTime:=0;FReturnDwell:=0;FLeftRouteCorridor:=False;
  FActiveAvatarAgent.State.FreeTravel:=True;
  FActiveAvatarAgent.State.TrafficMoveConstraint:=nil;
  FActiveAvatarAgent.State.TrafficHeadingConstraint:=nil;
  FActiveAvatarAgent.State.LaneOffset:=0;
  FActiveAvatarAgent.State.SlopeQuery:=FActiveAvatarAgent.State.GroundQuery;
  SetCameraMode(pcmThirdPerson);SetChaseCamera(True,4.5,2.0,0,1.0);
  if(FRouteReturn=nil)and FRouteExcursion then
    FRouteReturn:=TRouteReturnGuide.Create(FreeAtStop,MainViewport.Items);
  if FLocalBots<>nil then FLocalBots.SetRouteExcursion(FRouteExcursion,FActiveAvatarAgent.Path.Position);
end;

procedure TViewPlay.ResumeRoute;
begin
  if not FRouteExcursion or not HasActiveState or(FRouteReturn=nil)then Exit;
  ResumeAgentRoute(FActiveAvatarAgent,FRouteReturn.Target);
  FFreeExplore:=False;FRouteExcursion:=False;FExplicitTurnTime:=0;
  FRoadGuidance.Reset;FRouteReturn.Hide;
  if FOsmStreaming<>nil then FActiveAvatarAgent.State.SlopeQuery:=@FOsmStreaming.GroundNearYCorrAt;
  if FLaneManager<>nil then FLocalLaneHandle:=RegisterTrafficAgent(FLaneManager,FActiveAvatarAgent);
  if FLocalBots<>nil then FLocalBots.SetRouteExcursion(False,FActiveAvatarAgent.Path.Position);
end;

procedure TViewPlay.SyncRestoredTravel;
begin
  if not HasActiveState then Exit;
  FFreeExplore:=FActiveAvatarAgent.State.FreeTravel;
  FRouteExcursion:=RestoredRouteExcursion(FActiveAvatarAgent,FPointExplore);
  FExplicitTurnTime:=0;FExcursionTime:=0;FReturnDwell:=0;FLeftRouteCorridor:=False;
  FManualSteerIntent:=0;FSteeringIntentHold:=0;FLastManualTurn:=0;FRoadRefresh:=0;
  if FRoadGuidance=nil then FRoadGuidance:=TRoadGuidance.Create;
  FRoadGuidance.Reset;
  if FRouteReturn<>nil then FRouteReturn.Hide;
  FActiveAvatarAgent.State.TravelRoadGuided:=False;
  FActiveAvatarAgent.State.TravelOffRoad:=False;
  if FFreeExplore then begin
    FActiveAvatarAgent.State.TrafficMoveConstraint:=nil;
    FActiveAvatarAgent.State.TrafficHeadingConstraint:=nil;
    FActiveAvatarAgent.State.LaneOffsetExternal:=False;
    FActiveAvatarAgent.State.TrafficSpeedLimit:=MaxSpeed;
    FActiveAvatarAgent.State.SlopeQuery:=FActiveAvatarAgent.State.GroundQuery;
  end else begin
    ApplyGroundQueryToAgent(FActiveAvatarAgent);
    if FLaneManager<>nil then FLocalLaneHandle:=RegisterTrafficAgent(FLaneManager,FActiveAvatarAgent);
  end;
  if FRouteExcursion then begin
    if FRouteReturn=nil then FRouteReturn:=TRouteReturnGuide.Create(FreeAtStop,MainViewport.Items);
    FRouteReturn.Step(FActiveAvatarAgent.Path,FActiveAvatarAgent.State.WorldPosition,
      FActiveAvatarAgent.State.ForwardDir,0,True);
    FLeftRouteCorridor:=FRouteReturn.Distance>Math.Max(4.0,
      FActiveAvatarAgent.Path.RoadWidthAt(FRouteReturn.Target)*0.5+1);
  end;
  if FLocalBots<>nil then begin
    if FRouteExcursion then FLocalBots.SetRouteExcursion(True,FRouteReturn.Target)
    else FLocalBots.SetRouteExcursion(False,FActiveAvatarAgent.Path.Position);
    FLocalBots.SetRenderEnabled(FPerfRiders and(not FFreeExplore or FRouteExcursion));
  end;
  if FExploreHint<>nil then FExploreHint.Exists:=FFreeExplore;
end;

function TViewPlay.GuideTravel(Dt,Steer:Single;Turn:Integer):Single;
var Roads:TTravelRoads;I,N,Count:Integer;P,Q:TVector3;Guided,T:Single;
  R:TTravelRoad;RoadPos:TPathPosition;
begin
  Result:=Steer;
  if HasActiveState then FActiveAvatarAgent.State.TravelRoadGuided:=False;
  if not HasActiveState or RidePreparationHeld or(FTravelMode=travelFlight)then Exit;
  if FRoadGuidance=nil then FRoadGuidance:=TRoadGuidance.Create;
  if Abs(Steer)>0.35 then FExplicitTurnTime:=FExplicitTurnTime+Math.Min(Dt,0.25)
  else FExplicitTurnTime:=0;
  if Turn<>0 then FRoadGuidance.QueueTurn(Turn);
  if not FFreeExplore and(FExplicitTurnTime>0.45)then LeaveRoute;
  if not FFreeExplore and(Turn=0)and(FRoadGuidance.PendingTurn=0)then Exit;
  FRoadRefresh:=FRoadRefresh-Dt;
  if FRoadRefresh<=0 then begin
    FRoadRefresh:=0.2;Roads:=nil;
    if(FOsmStreaming<>nil)and(FOsmStreaming.Session<>nil)and(FOsmStreaming.Session.Map<>nil)then
      Roads:=FOsmStreaming.Session.Map.NearbyTravelRoads(FActiveAvatarAgent.State.WorldPosition,90)
    else if(FDreamWorld<>nil)and(FActiveAvatarAgent.Path.PointCount>2)then begin
      { Dream worlds keep their existing authored road/route geometry. }
      N:=FActiveAvatarAgent.Path.PointCount;Count:=0;
      for I:=0 to N-1 do begin
        RoadPos.Segment:=I;RoadPos.T:=0;R:=Default(TTravelRoad);
        R.A:=FActiveAvatarAgent.Path.RoadCenterAt(RoadPos);
        R.B:=R.A+FActiveAvatarAgent.Path.FollowTangent(RoadPos);
        Q:=RoadProjection(FActiveAvatarAgent.State.WorldPosition,R,T);
        if RoadDistanceSq(Q,FActiveAvatarAgent.State.WorldPosition)>Sqr(90)then Continue;
        R.Width:=FActiveAvatarAgent.Path.PointWidth(I);R.WayId:=1;
        if Count=Length(Roads)then SetLength(Roads,Max(64,Count*2));
        Roads[Count]:=R;Inc(Count);
      end;
      SetLength(Roads,Count);
    end;
    FRoadGuidance.SetRoads(Roads);
  end;
  P:=FActiveAvatarAgent.State.WorldPosition;
  Guided:=FRoadGuidance.Step(P,FActiveAvatarAgent.State.ForwardDir,
    FActiveAvatarAgent.State.CurrentSpeed,Steer,Dt);
  if not FFreeExplore and FRoadGuidance.TurnTaken then begin
    if RouteTurnFollowsPath(FActiveAvatarAgent.Path,FActiveAvatarAgent.Path.Position,
      FRoadGuidance.SelectedTurnRoad,FRoadGuidance.SelectedTurnDirection)then
      FRoadGuidance.Reset
    else LeaveRoute;
  end;
  if FFreeExplore then begin
    Result:=Guided;
    FActiveAvatarAgent.State.TravelOffRoad:=not FRoadGuidance.OnRoad;
    FActiveAvatarAgent.State.TravelRoadGuided:=FRoadGuidance.Following;
    FActiveAvatarAgent.State.TravelRoadSpeedLimit:=FRoadGuidance.SpeedLimit;
    if(FTravelMode=travelWalk)and FRoadGuidance.Following then
      Result:=Result*Math.Min(1.25,Abs(FActiveAvatarAgent.State.CurrentSpeed)*0.55)/1.8;
  end;
end;

procedure TViewPlay.UpdateRouteReturn(Dt:Single);
var Heading:TVector3;
begin
  if not FRouteExcursion or not HasActiveState or(FRouteReturn=nil)then Exit;
  FExcursionTime:=FExcursionTime+Dt;
  FRouteReturn.Step(FActiveAvatarAgent.Path,FActiveAvatarAgent.State.WorldPosition,
    FActiveAvatarAgent.State.ForwardDir,Dt,True);
  if FLocalBots<>nil then FLocalBots.SetRouteExcursion(True,FRouteReturn.Target);
  if FRouteReturn.Distance>Math.Max(4.0,FActiveAvatarAgent.Path.RoadWidthAt(FRouteReturn.Target)*0.5+1)then
    FLeftRouteCorridor:=True;
  Heading:=FActiveAvatarAgent.Path.FollowDirectionXZ(FRouteReturn.Target);
  if(FExcursionTime>4)and(FLeftRouteCorridor or(FExcursionTime>8))and
    RouteReturnAligned(FRouteReturn.Distance,
      TVector3.DotProduct(Heading,FActiveAvatarAgent.State.ForwardDir),FManualSteerIntent,
      (FSteeringIntentHold>0)or(FRoadGuidance.PendingTurn<>0))then
    FReturnDwell:=FReturnDwell+Dt else FReturnDwell:=0;
  if FReturnDwell>1 then ResumeRoute;
end;
