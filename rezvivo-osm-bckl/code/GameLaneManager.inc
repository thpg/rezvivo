{ Traffic uses physical positions and metre clearances. Lane numbers alone
  cannot describe clearance on a narrowing road, or while changing lanes. }
function TLaneManager.FindRider(ATag: Pointer): TLaneRiderHandle;
var I: Integer;
begin
  for I:=0 to FCount-1 do if FRiders[I].Tag=ATag then Exit(I);
  Result:=-1;
end;

function TLaneManager.RiderTag(AHandle: TLaneRiderHandle): Pointer;
begin
  Result:=nil;
  if (AHandle>=0) and (AHandle<FCount) and FRiders[AHandle].Active then
    Result:=FRiders[AHandle].Tag;
end;

procedure TLaneManager.SetRiderPose(AHandle: TLaneRiderHandle;
  const Position, Direction: TVector3; RoadWidth, ActualOffset, Speed: Single);
var D: TVector3;
begin
  if (AHandle<0) or (AHandle>=FCount) then Exit;
  { A route seek/reconnect teleport releases the old entry priority. }
  if FRiders[AHandle].PoseValid and
    ((Position-FRiders[AHandle].WorldPosition).Length>Max(8,FRiders[AHandle].Speed*FLastDT*3+2))then begin
    FRiders[AHandle].PassageKey:=0;FRiders[AHandle].PassageAge:=0;
  end;
  D:=Vector3(Direction.X,0,Direction.Z);
  if D.Length<0.001 then D:=Vector3(0,0,1) else D:=D.Normalize;
  FRiders[AHandle].WorldPosition:=Position;
  FRiders[AHandle].ForwardDir:=D;
  FRiders[AHandle].CollisionDir:=D;
  FRiders[AHandle].RoadWidth:=Max(0,RoadWidth);
  FRiders[AHandle].ActualOffset:=ActualOffset;
  FRiders[AHandle].Speed:=Max(0,Speed);
  FRiders[AHandle].PoseValid:=True;
end;

procedure TLaneManager.SetRiderHeading(AHandle:TLaneRiderHandle;const Direction:TVector3);
var D:TVector3;
begin
  if(AHandle<0)or(AHandle>=FCount)then Exit;
  D:=Vector3(Direction.X,0,Direction.Z);
  if D.Length>0.001 then FRiders[AHandle].CollisionDir:=D.Normalize;
end;

procedure TLaneManager.InvalidateRiderPose(AHandle: TLaneRiderHandle);
begin
  if (AHandle>=0) and (AHandle<FCount) then begin
    FRiders[AHandle].PoseValid:=False;
    FRiders[AHandle].PassageKey:=0;FRiders[AHandle].PassageAge:=0;
  end;
end;

procedure TLaneManager.SetNarrowPassage(AHandle:TLaneRiderHandle;Key:QWord;
  Forward,Inside:Boolean;EntryDistance:Single;Exclusive:Boolean);
begin
  if(AHandle<0)or(AHandle>=FCount)then Exit;
  if(FRiders[AHandle].PassageKey<>Key)or
    (FRiders[AHandle].PassageForward<>Forward)then FRiders[AHandle].PassageAge:=0;
  FRiders[AHandle].PassageKey:=Key;FRiders[AHandle].PassageForward:=Forward;
  FRiders[AHandle].PassageInside:=Inside;FRiders[AHandle].PassageDistance:=EntryDistance;
  FRiders[AHandle].PassageExclusive:=Exclusive;
end;

function TLaneManager.ReservePlacement(AHandle: TLaneRiderHandle;
  const Center, Direction: TVector3; RoadWidth: Single; out Offset: Single): Boolean;
var L,J,Best: Integer; Cost,BestCost,Along,Across: Single;
    P,D,Right,Delta: TVector3; SlotFree: Boolean;
begin
  Result:=False; Offset:=0;
  if (AHandle<0) or (AHandle>=FCount) then Exit;
  D:=Vector3(Direction.X,0,Direction.Z);
  if D.Length<0.001 then D:=Vector3(0,0,1) else D:=D.Normalize;
  Right:=Vector3(-D.Z,0,D.X); Best:=-1; BestCost:=1e30;
  for L:=0 to FLaneCount-1 do begin
    P:=Center+Right*OffsetForWidth(L,RoadWidth); SlotFree:=True;
    for J:=0 to FCount-1 do begin
      if (J=AHandle) or not FRiders[J].Active or not FRiders[J].PoseValid then Continue;
      Delta:=FRiders[J].WorldPosition-P;
      if Abs(Delta.Y)>2.0 then Continue;
      Along:=TVector3.DotProduct(Delta,D); Across:=TVector3.DotProduct(Delta,Right);
      if (Abs(Along)<2.4) and (Abs(Across)<0.95) then begin SlotFree:=False;Break end;
    end;
    Cost:=Abs(L-FDefaultLane);
    if SlotFree and (Cost<BestCost) then begin Best:=L;BestCost:=Cost end;
  end;
  if Best<0 then Exit;
  FRiders[AHandle].Lane:=Best; FRiders[AHandle].SmoothLane:=Best;
  Offset:=OffsetForWidth(Best,RoadWidth);
  SetRiderPose(AHandle,Center+Right*Offset,D,RoadWidth,Offset,0);
  Result:=True;
end;

function TLaneManager.LaneClear(AHandle, ALane: Integer; Clearance: Single): Boolean;
var J: Integer; Target,OtherTarget,Gap,Across,FutureAcross,CurrentAcross,LowSide,HighSide: Single;
    Right,OtherRight,Delta,Future: TVector3;
begin
  Result:=True;
  if not FRiders[AHandle].PoseValid then begin
    for J:=0 to FCount-1 do begin
      if (J=AHandle) or not FRiders[J].Active then Continue;
      Gap:=WrapDistance(FRiders[J].LoopPos-FRiders[AHandle].LoopPos,FPathTotalLength);
      if Gap>FPathTotalLength*0.5 then Gap:=Gap-FPathTotalLength;
      if (Abs(Gap)<Clearance) and
         ((FRiders[J].Lane=ALane) or (Abs(FRiders[J].SmoothLane-ALane)<0.95)) then Exit(False);
    end;
    Exit;
  end;
  Right:=Vector3(-FRiders[AHandle].ForwardDir.Z,0,FRiders[AHandle].ForwardDir.X);
  Target:=OffsetForWidth(ALane,FRiders[AHandle].RoadWidth);
  CurrentAcross:=FRiders[AHandle].ActualOffset;
  LowSide:=Min(CurrentAcross,Target)-0.95;
  HighSide:=Max(CurrentAcross,Target)+0.95;
  for J:=0 to FCount-1 do begin
    if (J=AHandle) or not FRiders[J].Active or not FRiders[J].PoseValid then Continue;
    Delta:=FRiders[J].WorldPosition-FRiders[AHandle].WorldPosition;
    if (Abs(Delta.Y)>2) or (Delta.Length>Clearance+5) then Continue;
    Gap:=TVector3.DotProduct(Delta,FRiders[AHandle].ForwardDir);
    if Abs(Gap)>=Clearance then Continue;
    { A same-direction follower behind the full bicycle clearance already
      yields through TrafficLimit/swept contact. At equal or lower speed it
      must not reserve every exit lane in front of its leader. }
    if(Gap< -2.4)and(TVector3.DotProduct(FRiders[J].ForwardDir,FRiders[AHandle].ForwardDir)>0.5)and
      (FRiders[J].Speed<=FRiders[AHandle].Speed+0.5)then Continue;
    Across:=CurrentAcross+TVector3.DotProduct(Delta,Right);
    OtherRight:=Vector3(-FRiders[J].ForwardDir.Z,0,FRiders[J].ForwardDir.X);
    OtherTarget:=OffsetForWidth(FRiders[J].Lane,FRiders[J].RoadWidth);
    { A stopped cyclist cannot slide to a requested lane: steering needs
      forward travel. Reserving that phantom side position blocks the real
      free side as well and deadlocks an exit beside a waiting cyclist. }
    if FRiders[J].Speed<0.1 then OtherTarget:=FRiders[J].ActualOffset;
    Future:=Delta+OtherRight*(OtherTarget-FRiders[J].ActualOffset);
    FutureAcross:=CurrentAcross+TVector3.DotProduct(Future,Right);
    if (Abs(Across-Target)<0.95) or (Abs(FutureAcross-Target)<0.95) then Exit(False);
    { A target beyond a nearby bicycle is not reachable by steering through
      its side. Re-evaluate that lane before braking reaches zero, while the
      genuinely free side remains selectable. }
    { A bicycle whose centre is slightly behind is still alongside us.
      A far-side target can be farther from its centre than our current
      position, yet reaching it would still cross the whole bicycle. }
    if(Gap> -2.4)and(Gap<6)and
      (Across>Min(CurrentAcross,Target))and(Across<Max(CurrentAcross,Target))then Exit(False);
    { Do not sweep sideways through a rider already alongside us. }
    if (Abs(Gap)<2.4) and
      (((Across>LowSide) and (Across<HighSide) and
        (Abs(Across-Target)<Abs(Across-CurrentAcross))) or
       ((FutureAcross>LowSide) and (FutureAcross<HighSide) and
        (Abs(FutureAcross-Target)<Abs(FutureAcross-CurrentAcross))))then Exit(False);
  end;
end;

function TLaneManager.ConstrainMovement(Tag: Pointer; const Position, Movement: TVector3;
  Commit: Boolean): TVector3;
var I,J: Integer; Delta,CurrentHeading: TVector3;
    Limit,Travel,HeadingLength: Single;PairLimit:Double;
begin
  Result:=Movement; I:=FindRider(Tag);
  if (I<0) or not FRiders[I].Active or not FRiders[I].PoseValid then Exit;
  Limit:=1; Travel:=Movement.Length;
  { A render frame can contain many fixed steps. The proposed displacement
    already follows this step's physical heading, unlike the frame snapshot.
    Keep extrapolation read-only; only committed motion updates the snapshot. }
  CurrentHeading:=FRiders[I].CollisionDir;
  HeadingLength:=Sqrt(Sqr(Movement.X)+Sqr(Movement.Z));
  if HeadingLength>0.000001 then
    CurrentHeading:=Vector3(Movement.X/HeadingLength,0,Movement.Z/HeadingLength);
  if Travel>0.000001 then for J:=0 to FCount-1 do begin
    if (J=I) or not FRiders[J].Active or not FRiders[J].PoseValid then Continue;
    Delta:=Position-FRiders[J].WorldPosition;
    if (Abs(Delta.Y)>2) or (Sqr(Delta.X)+Sqr(Delta.Z)>Sqr(Travel+3)) then Continue;
    { Segment tangents jump at path vertices; the bicycle itself turns
      continuously. Using lane tangents here expands its ellipse sideways
      into an adjacent rider at a bend, creating a false existing overlap. }
    PairLimit:=TrafficSweepLimit(Delta.X,Delta.Z,Movement.X,Movement.Z,
      CurrentHeading.X,CurrentHeading.Z,FRiders[J].CollisionDir.X,
      FRiders[J].CollisionDir.Z,Travel);
    Limit:=Min(Limit,PairLimit);
    if Limit<=0 then Break;
  end;
  Result:=Movement*Limit;
  { Keep subsequent fixed steps and other riders' sweeps up to date. }
  if Commit then begin
    FRiders[I].WorldPosition:=Position+Result;
    FRiders[I].CollisionDir:=CurrentHeading;
  end;
end;

function TLaneManager.ConstrainHeading(Tag:Pointer;
  const Position,PreviousDir,ProposedDir:TVector3;Commit:Boolean):TVector3;
var I,J,Nodes:Integer;Delta:TVector3;PreviousYaw,AcceptedYaw,PeerYaw:Double;
    HaveAngles:Boolean;
begin
  Result:=ProposedDir;I:=FindRider(Tag);
  if(I<0)or not FRiders[I].Active or not FRiders[I].PoseValid then Exit;
  HaveAngles:=False;
  { No allocation, no raycast and no trig for zero turns or remote peers. }
  if(Sqr(ProposedDir.X-PreviousDir.X)+Sqr(ProposedDir.Z-PreviousDir.Z)>1e-14)then
    for J:=0 to FCount-1 do begin
      if(J=I)or not FRiders[J].Active or not FRiders[J].PoseValid then Continue;
      Delta:=Position-FRiders[J].WorldPosition;
      if(Abs(Delta.Y)>2)or(Sqr(Delta.X)+Sqr(Delta.Z)>9)then Continue;
      if not HaveAngles then begin
        PreviousYaw:=ArcTan2(PreviousDir.Z,PreviousDir.X);
        AcceptedYaw:=ArcTan2(ProposedDir.Z,ProposedDir.X);HaveAngles:=True;
      end;
      PeerYaw:=ArcTan2(FRiders[J].CollisionDir.Z,FRiders[J].CollisionDir.X);
      AcceptedYaw:=TrafficYawLimit(Delta.X,Delta.Z,PreviousYaw,AcceptedYaw,PeerYaw,Nodes);
    end;
  if HaveAngles then Result:=Vector3(Cos(AcceptedYaw),0,Sin(AcceptedYaw));
  { Turnaround may return before a translation step: publish the accepted
    physical heading here as well, but never mutate during a read-only query. }
  if Commit then FRiders[I].CollisionDir:=Result;
end;

function TLaneManager.TrafficLimit(AHandle: TLaneRiderHandle): Single;
var J: Integer; Delta,Right: TVector3; Gap,Across,LeaderSpeed,LeadLimit: Single;
    PeerWins,Exclusive:Boolean;
begin
  Result:=MaxSpeed;
  if (AHandle<0) or (AHandle>=FCount) or not FRiders[AHandle].PoseValid then Exit;
  Right:=Vector3(-FRiders[AHandle].ForwardDir.Z,0,FRiders[AHandle].ForwardDir.X);
  for J:=0 to FCount-1 do begin
    if (J=AHandle) or not FRiders[J].Active or not FRiders[J].PoseValid then Continue;
    Exclusive:=FRiders[AHandle].PassageExclusive or FRiders[J].PassageExclusive;
    if Exclusive then
      { One physical queue into a terminal: front bicycle first, then hold
        every follower until its return. No local-handle tie-breaker. }
      { No distance dead band here: side-by-side riders can wait at the same
        stop line, and a 10 cm tie previously admitted both. Use a strict
        shared order, independent of the local registration handles. }
      PeerWins:=FRiders[J].PassageInside or
        (FRiders[J].PassageDistance<FRiders[AHandle].PassageDistance)or
        ((FRiders[J].PassageDistance=FRiders[AHandle].PassageDistance)and
         ((FRiders[J].WorldPosition.X<FRiders[AHandle].WorldPosition.X)or
          ((FRiders[J].WorldPosition.X=FRiders[AHandle].WorldPosition.X)and
           (FRiders[J].WorldPosition.Z<FRiders[AHandle].WorldPosition.Z))))
    else PeerWins:=FRiders[J].PassageInside or
      (FRiders[J].PassageAge>FRiders[AHandle].PassageAge+2)or
      ((Abs(FRiders[J].PassageAge-FRiders[AHandle].PassageAge)<=2)and FRiders[J].PassageForward);
    { Reserve a whole connected single-file corridor, including bends hundreds
      of metres ahead. Wait on the wide approach, leaving room for its exit.
      Riders already inside clear it first. Among approaches the oldest request
      wins; arrivals within the relay delay choose the same canonical direction
      on every client, independent of local handle allocation. }
    if(FRiders[AHandle].PassageKey<>0)and not FRiders[AHandle].PassageInside and
      (FRiders[J].PassageKey=FRiders[AHandle].PassageKey)and
      (Exclusive or(FRiders[J].PassageForward<>FRiders[AHandle].PassageForward))and PeerWins then
      Result:=Min(Result,Sqrt(4*Max(0,FRiders[AHandle].PassageDistance-20)));
    Delta:=FRiders[J].WorldPosition-FRiders[AHandle].WorldPosition;
    if (Abs(Delta.Y)>2) or (Delta.Length>40) then Continue;
    Gap:=TVector3.DotProduct(Delta,FRiders[AHandle].ForwardDir);
    Across:=Abs(TVector3.DotProduct(Delta,Right));
    if (Gap<=0) or (Across>=0.95) then Continue;
    LeaderSpeed:=Max(0,FRiders[J].Speed*TVector3.DotProduct(
      FRiders[J].ForwardDir,FRiders[AHandle].ForwardDir));
    LeadLimit:=Sqrt(Sqr(LeaderSpeed)+4*Max(0,Gap-2.5));
    { A free side can be reached at walking speed; the physical sweep remains
      authoritative. Min with Result preserves a zero corridor reservation. }
    if(LeadLimit<0.8)and
      (Abs(OffsetForWidth(FRiders[AHandle].Lane,FRiders[AHandle].RoadWidth)-FRiders[AHandle].ActualOffset)>0.15)and
      LaneClear(AHandle,FRiders[AHandle].Lane,6)then LeadLimit:=0.8;
    Result:=Min(Result,LeadLimit);
  end;
end;

procedure TLaneManager.SetSteering(AHandle: TLaneRiderHandle; Enabled: Boolean; Axis: Single);
begin
  if (AHandle<0) or (AHandle>=FCount) then Exit;
  FRiders[AHandle].ManualSteering:=Enabled;
  FRiders[AHandle].SteeringAxis:=EnsureRange(Axis,-1,1);
end;

procedure TLaneManager.Update(const DeltaTime: Single);
var I,L,Best: Integer; Approach,Cost,BestCost,Alpha: Single;
begin
  for I:=0 to FCount-1 do begin
    if not FRiders[I].Active then Continue;
    if FRiders[I].PassageKey<>0 then FRiders[I].PassageAge:=FRiders[I].PassageAge+Max(0,DeltaTime);
    FRiders[I].Lane:=EnsureRange(FRiders[I].Lane,0,FLaneCount-1);
    if FRiders[I].ManualSteering then
    begin
      { Center holds the selected line. Request the next slot only after the
        previous smooth transition; traffic clearance and road edges still
        apply. The normal traffic speed limiter handles a blocked line. }
      if (FRiders[I].Speed>0.3) and (Abs(FRiders[I].SteeringAxis)>0.08) and
        (Abs(FRiders[I].SmoothLane-FRiders[I].Lane)<0.2) then
      begin
        L:=EnsureRange(FRiders[I].Lane-Sign(FRiders[I].SteeringAxis),0,FLaneCount-1);
        if (L<>FRiders[I].Lane) and LaneClear(I,L,4) then FRiders[I].Lane:=L;
      end;
      Continue;
    end;
    Approach:=12+Min(18,FRiders[I].Speed*0.8);
    if not LaneClear(I,FRiders[I].Lane,Approach) then begin
      Best:=-1; BestCost:=1e30;
      for L:=0 to FLaneCount-1 do if LaneClear(I,L,Approach) then begin
        Cost:=Abs(L-FDefaultLane)+0.2*Abs(L-FRiders[I].SmoothLane);
        if Cost<BestCost then begin Best:=L;BestCost:=Cost end;
      end;
      if Best>=0 then FRiders[I].Lane:=Best;
    end else if (FRiders[I].Lane<>FDefaultLane) and LaneClear(I,FDefaultLane,Approach+5) then
      FRiders[I].Lane:=FDefaultLane;
  end;
  Alpha:=1-Exp(-3*Max(DeltaTime,0));
  for I:=0 to FCount-1 do begin
    FRiders[I].SmoothLane:=FRiders[I].SmoothLane+(FRiders[I].Lane-FRiders[I].SmoothLane)*Alpha;
    FRiders[I].PrevLoopPos:=FRiders[I].LoopPos;
  end;
  FLastDT:=DeltaTime;
end;
