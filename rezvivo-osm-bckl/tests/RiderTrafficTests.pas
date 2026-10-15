program RiderTrafficTests;
{$mode objfpc}{$H+}
uses Classes, SysUtils, Math, CastleVectors, CastleTransform, GamePath,
  GamePhysicsCommon, GamePhysicsBase, GamePhysicalAgent, GameRiderTraffic, GameAgentControllers,GameAgentControl;

type TGround = class
  function Query(X,Z,ReferenceY:Single; out Y:Single):Boolean;
end;
type TPhysicsAccess = class(TCustomActorPhysics)
  procedure RotateForTest(const Direction:TVector3;Dt:Single);
end;
procedure TPhysicsAccess.RotateForTest(const Direction:TVector3;Dt:Single);
begin SmoothRotateToDirection(Direction,Dt) end;
function TGround.Query(X,Z,ReferenceY:Single; out Y:Single):Boolean;
begin Y:=0;Result:=True end;

procedure Check(B: Boolean; const Msg: string);
begin if not B then raise Exception.Create(Msg) end;

procedure TestStart;
var M: TLaneManager; A,B: Integer; O1,O2: Single; P: TVector3;
begin
  M:=TLaneManager.Create;
  try
    M.SetRoad(8,1000); A:=M.RegisterRider(Pointer(1));B:=M.RegisterRider(Pointer(2));
    M.Update(0);
    Check(M.GetLane(A)<>M.GetLane(B),'equal stationary positions must reserve different lanes');
    Check(M.ReservePlacement(A,Vector3(0,0,0),Vector3(0,0,1),8,O1),'first wide-road start');
    Check(M.ReservePlacement(B,Vector3(0,0,0),Vector3(0,0,1),8,O2),'second wide-road start');
    Check(Abs(O1-O2)>=0.95,'wide-road start has overlapping handlebars');
    M.InvalidateRiderPose(A);M.InvalidateRiderPose(B);
    Check(M.ReservePlacement(A,Vector3(0,0,0),Vector3(0,0,1),5.5,O1),'island first start');
    Check(M.ReservePlacement(B,Vector3(0,0,0),Vector3(0,0,1),5.5,O2),'island second start');
    Check(Abs(O1-O2)>=0.95,'island start slots collapsed');
    M.InvalidateRiderPose(A);M.InvalidateRiderPose(B);
    Check(M.ReservePlacement(A,Vector3(0,0,0),Vector3(0,0,1),1.2,O1),'narrow first start');
    Check(not M.ReservePlacement(B,Vector3(0,0,0),Vector3(0,0,1),1.2,O2),'narrow start must request another row');
    P:=Vector3(0,0,2.5);
    Check(M.ReservePlacement(B,P,Vector3(0,0,1),1.2,O2),'second narrow-road row');
    Writeln('PASS start: equal speed, wide road, 5.5 m island, narrow path queue');
  finally M.Free end;
end;

procedure TestCompanionStart;
var Path:TGamePath;Start,Position:TPathPosition;Behind:Single;
begin
  Path:=TGamePath.Create;
  try
    Start.Segment:=0;Start.T:=0;
    Path.LoadFromMemory([Vector3(0,0,0),Vector3(0,0,100),Vector3(100,0,100),
      Vector3(100,0,-100),Vector3(0,0,-100)],[]);
    Check(FindCompanionStartBehind(Path,Start,24,Position,Behind)and(Behind=4),
      'ordinary closed route keeps the companion 4 m behind');
    { Rollerski: finish crosses the start, overshoots 6 m, then returns.
      The old -4 m spawn is physically 4 m AHEAD and faces the player. }
    Path.LoadFromMemory([Vector3(0,0,0),Vector3(0,0,100),Vector3(100,0,100),
      Vector3(100,0,-100),Vector3(0,0,-100),Vector3(0,0,0),
      Vector3(0,0,6),Vector3(0,0,0)],[]);
    Check(FindCompanionStartBehind(Path,Start,24,Position,Behind),
      'reversed loop seam must find an alternative spawn');
    Check((Behind=16)and(Path.RoadCenterAt(Position).Z< -3.9),
      'companion must leave the outgoing acceleration corridor clear');
    Check(not FindCompanionStartBehind(Path,Start,8,Position,Behind),
      'do not force an unsafe spawn when no available route is behind');
    Check(not FindCompanionStartBehind(Path,Start,0,Position,Behind),
      'do not wrap past the beginning of an open route');
    Path.LoadFromMemory([Vector3(0,0,0),Vector3(0,0,0),Vector3(1,0,1),
      Vector3(0,0,0)],[]);
    Check(not FindCompanionStartBehind(Path,Start,24,Position,Behind),
      'degenerate short loop must defer spawning instead of overlapping');
    Writeln('PASS companion starts: ordinary loop, reversed closure, bounded search, defer');
  finally Path.Free end;
end;

procedure TestMovement;
var M: TLaneManager; A,B: Integer; V: TVector3; Before,After: TLaneReplayState;
begin
  M:=TLaneManager.Create;
  try
    M.SetRoad(8,1000); A:=M.RegisterRider(Pointer(1));B:=M.RegisterRider(Pointer(2));
    M.SetRiderPose(A,Vector3(0,0,0),Vector3(0,0,1),8,0,20);
    M.SetRiderPose(B,Vector3(0,0,5),Vector3(0,0,1),8,0,0);
    Check(M.TrafficLimit(A)<4,'must brake before a stationary bicycle');
    Before:=M.CaptureReplay;
    V:=M.ConstrainMovement(Pointer(1),Vector3(0,0,0),Vector3(0,0,10),False);
    Check((V.Z>2.7) and (V.Z<2.81),'swept contact must prevent tunneling at a long frame');
    After:=M.CaptureReplay;
    Check((Before[A].WorldPosition-After[A].WorldPosition).Length=0,'visual interpolation changed physics');
    M.SetRiderPose(B,Vector3(1.6,0,5),Vector3(0,0,1),8,-1.6,0);
    V:=M.ConstrainMovement(Pointer(1),Vector3(0,0,0),Vector3(0,0,10),True);
    Check(Abs(V.Z-10)<0.001,'clear adjacent lane must allow passing');
    M.SetRiderPose(B,Vector3(0,4,5),Vector3(0,0,1),8,0,0);
    V:=M.ConstrainMovement(Pointer(1),Vector3(0,0,0),Vector3(0,0,10),False);
    Check(Abs(V.Z-10)<0.001,'rider on another bridge level must not block movement');
    Writeln('PASS movement: braking, swept collision, read-only extrapolation, passing, bridge levels');
  finally M.Free end;
end;

procedure TestFollowing(Fps: Integer);
var M: TLaneManager; A,B,I: Integer; PA,PB,V: TVector3; Dt,Speed: Single;
begin
  M:=TLaneManager.Create;
  try
    M.SetRoad(1.2,1000); A:=M.RegisterRider(Pointer(1));B:=M.RegisterRider(Pointer(2));
    PA:=Vector3(0,0,0);PB:=Vector3(0,0,6);Dt:=1/Fps;Speed:=14;
    for I:=1 to Fps*20 do begin
      M.SetRiderPose(A,PA,Vector3(0,0,1),1.2,0,Speed);
      M.SetRiderPose(B,PB,Vector3(0,0,1),1.2,0,5);
      M.Update(Dt);Speed:=Min(Speed+2*Dt,M.TrafficLimit(A));
      V:=M.ConstrainMovement(Pointer(1),PA,Vector3(0,0,Speed*Dt),True);PA:=PA+V;
      PB:=PB+M.ConstrainMovement(Pointer(2),PB,Vector3(0,0,5*Dt),True);
      Check(PB.Z-PA.Z>2.19,'overlap in a single-file queue');
    end;
    Check(PA.Z>90,'following rider stalled instead of matching leader speed');
    Writeln('PASS queue at ',Fps,' FPS, final gap=',PB.Z-PA.Z:0:3,' m');
  finally M.Free end;
end;

procedure TestAgentPlacement;
var M: TLaneManager; A,B: TPhysicalAgent;
begin
  M:=TLaneManager.Create;A:=TPhysicalAgent.Create(nil);B:=TPhysicalAgent.Create(nil);
  try
    M.SetRoad(8,200);
    A.Path.LoadFromMemory([Vector3(0,600,0),Vector3(0,600,100)], [8,8]);
    A.Path.CopyTo(B.Path);
    A.State.LastGroundY:=20;B.State.LastGroundY:=20;
    PlaceTrafficAgent(M,A);PlaceTrafficAgent(M,B);
    Check((A.State.WorldPosition-B.State.WorldPosition).Length>=0.95,'agent placement overlaps');
    Check((A.State.WorldPosition.Y=20) and (B.State.WorldPosition.Y=20),'placement lost resolved ground height');
    Check(Assigned(A.State.TrafficMoveConstraint) and Assigned(B.State.TrafficMoveConstraint),'agent is not registered for traffic');
    UpdateRiderTraffic(M,0);
    Check(Abs(A.State.LaneOffset-B.State.LaneOffset)>=0.95,'first paused update collapsed lanes');
    Writeln('PASS agents: immediate placement, shared constraints, no raw FIT height restore');
  finally A.Free;B.Free;M.Free end;
end;

procedure TestRoomStartSlots;
var M:TLaneManager;Agents:array[0..7]of TPhysicalAgent;I,J,H:Integer;
begin
  M:=TLaneManager.Create;FillChar(Agents,SizeOf(Agents),0);
  try
    M.SetRoad(1.2,2000);
    for I:=0 to 7 do begin
      Agents[I]:=TPhysicalAgent.Create(nil);
      Agents[I].Path.LoadFromMemory([Vector3(0,0,0),Vector3(0,0,1000)], [1.2,1.2]);
      PlaceTrafficStartSlot(M,Agents[I],I);
      Check(Abs(Agents[I].State.CumulativeDistance-I*3)<0.01,'room start slot distance');
    end;
    UpdateRiderTraffic(M,0);
    for I:=0 to 7 do for J:=0 to I-1 do
      Check((Agents[I].State.WorldPosition-Agents[J].State.WorldPosition).Length>=2.4,'room start slots overlap');
    H:=M.FindRider(Agents[3]);M.UnregisterRider(H);
    Check(M.FindRider(Agents[3])<0,'departed room member retains stale traffic pointer');
    Agents[1].State.CumulativeDistance:=500;PlaceTrafficStartSlot(M,Agents[1],1);
    Check(Agents[1].State.CumulativeDistance>=500,'join mid-ride resets recorded distance');
    Writeln('PASS eight private room slots, narrow road, departure, no mid-ride distance reset');
  finally for I:=0 to 7 do Agents[I].Free;M.Free end;
end;

procedure TestRemoteCoasting;
var C:TRemotePowerController;Input:TAgentControlInput;
begin
  C:=TRemotePowerController.Create;
  try
    C.SetActive(True);C.FeedServerData(0,0,8);C.UpdateControl(0.1,Input);
    Check(Input.WantsAutoMove and(Input.DesiredPowerWatts=0),'remote coasting stopped or invented power');
    C.FeedServerData(0,0,0);C.UpdateControl(0.1,Input);
    Check(not Input.WantsAutoMove,'stationary remote started moving');
    C.SetActive(False);C.FeedServerData(200,80,8);C.UpdateControl(0.1,Input);
    Check(not Input.WantsAutoMove,'disconnected remote remains active');
    Writeln('PASS remote zero-power coasting, stop and disconnected state');
  finally C.Free end;
end;

procedure TestNarrowPassageKeys;
var A,B:TGamePath;P:TPathPosition;X,Y:TPathNarrowPassage;
begin
  A:=TGamePath.Create;B:=TGamePath.Create;
  try
    A.LoadFromMemory([Vector3(0,0,-100),Vector3(0,0,-20),Vector3(0,0,0),Vector3(0,0,522),Vector3(0,0,542),Vector3(0,0,700)], [6.5,6.5,1.2,1.2,6.5,6.5]);
    B.LoadFromMemory([Vector3(0,0,700),Vector3(0,0,542),Vector3(0,0,522),Vector3(0,0,0),Vector3(0,0,-20),Vector3(0,0,-100)], [6.5,6.5,1.2,1.2,6.5,6.5]);
    P.Segment:=1;P.T:=0;
    Check(A.NarrowPassageAt(P,60,X)and B.NarrowPassageAt(P,60,Y),'narrow entry discovery');
    Check((X.Key=Y.Key)and(X.Forward<>Y.Forward),'independent reverse route has a different corridor key');
    A.SetPointWidths([6.5,6.5,6.5,6.5,6.5,6.5]);
    Check(not A.NarrowPassageAt(P,60,X),'width replacement kept a stale corridor');
    A.LoadFromMemory([Vector3(0,0,-100),Vector3(0,0,-20),Vector3(0,0,0),Vector3(0,0,20),
      Vector3(0,0,30),Vector3(0,0,40),Vector3(0,0,60),Vector3(0,0,80),Vector3(0,0,100),Vector3(0,0,200)],
      [6.5,6.5,1.2,1.2,6.5,6.5,1.2,1.2,6.5,6.5]);
    P.Segment:=2;P.T:=0.5;Check(A.NarrowPassageAt(P,60,X),'first consecutive narrow');
    P.Segment:=6;Check(A.NarrowPassageAt(P,60,Y)and(X.Key=Y.Key),'short wide gap lost next entry reservation');
    A.LoadFromMemory([Vector3(0,0,-100),Vector3(0,0,0),Vector3(0,0,100),Vector3(0,0,200)], [6.5,6.5,0,6.5]);
    P.Segment:=1;P.T:=0.5;
    Check(A.NarrowPassageAt(P,60,X)and(Abs(X.EntryDistance)<0.01),'zero width switch must occur at T=0.5');
    A.LoadFromMemory([Vector3(0,0,522),Vector3(0,0,0),Vector3(0,0,-20),Vector3(0,0,-100),Vector3(0,0,-20),Vector3(0,0,0)],
      [1.2,1.2,6.5,6.5,6.5,1.2]);A.UsePreparedCornerHints(True);
    P.Segment:=0;P.T:=0.5;Check(A.NarrowPassageAt(P,60,X)and X.Exclusive and X.Inside,'wrapped terminal outgoing not exclusive');
    P.Segment:=5;Check(A.NarrowPassageAt(P,60,Y)and Y.Exclusive and Y.Inside and(X.Key=Y.Key),'wrapped terminal return lost occupancy');
    Writeln('PASS corridor cache: reversed paths, stable key, width invalidation, close narrows, zero widths');
  finally A.Free;B.Free end;
end;

procedure TestCachedPassages(const FileName:string);
type TSnapPoint=packed record Lat,Lon,CenterLat,CenterLon:Double;Width:Single;Way:Int64 end;
var F:TFileStream;N:LongWord;Raw:array of TSnapPoint;
    Points,ReversePoints:array of TVector3;Widths,ReverseWidths:array of Single;
    A,B:TGamePath;P,Q:TPathPosition;X,Y:TPathNarrowPassage;I,J,Count,Checked:Integer;
    Lat,Lon,Scale:Double;
begin
  F:=TFileStream.Create(FileName,fmOpenRead or fmShareDenyWrite);
  try
    F.Position:=8;F.ReadBuffer(N,4);Check((N>2)and(N<200000),'invalid snap point count');
    Check(F.Size=28+Int64(N)*SizeOf(TSnapPoint),'invalid snap record size');
    F.Position:=28;SetLength(Raw,N);F.ReadBuffer(Raw[0],N*SizeOf(TSnapPoint));
  finally F.Free end;
  Lat:=Raw[0].CenterLat;Lon:=Raw[0].CenterLon;Scale:=Cos(DegToRad(Lat));
  Count:=2*N-2;SetLength(Points,Count);SetLength(ReversePoints,Count);SetLength(Widths,Count);SetLength(ReverseWidths,Count);
  for I:=0 to N-1 do begin
    Points[I]:=Vector3(-(Raw[I].CenterLon-Lon)*111195*Scale,0,(Raw[I].CenterLat-Lat)*111195);
    Widths[I]:=Raw[I].Width;
  end;
  { Ahun is open-ended: reproduce the actual out-and-back expansion, never
    invent the straight last-to-first closure of the raw GPX. }
  for I:=N to Count-1 do begin Points[I]:=Points[Count-I];Widths[I]:=Widths[Count-I] end;
  for I:=0 to Count-1 do begin
    J:=(Count-I)mod Count;ReversePoints[I]:=Points[J];ReverseWidths[I]:=Widths[J];
  end;
  A:=TGamePath.Create;B:=TGamePath.Create;Checked:=0;
  try
    A.LoadFromMemory(Points,Widths);B.LoadFromMemory(ReversePoints,ReverseWidths);
    A.UsePreparedCornerHints(True);B.UsePreparedCornerHints(True);
    for I:=1 to N-3 do if(Widths[I]<1.9)and(Widths[I+1]<1.9)then begin
      P.Segment:=I;P.T:=0.4;Q.Segment:=Count-1-I;Q.T:=0.6;
      Check(A.NarrowPassageAt(P,60,X)and B.NarrowPassageAt(Q,60,Y),'real cached narrow missing');
      Check((X.Key=Y.Key)and((X.Forward<>Y.Forward)or(X.Exclusive and Y.Exclusive)),
        'real cached reverse key/direction mismatch at '+IntToStr(I));
      Inc(Checked);
    end;
    Check(Checked>100,'fixture does not exercise the actual narrow section');
    Writeln('PASS real cached route: ',Checked,' narrow segments, independent reversed route keys');
  finally A.Free;B.Free end;
end;

procedure TestPassagePriority;
var M:TLaneManager;A,B,I:Integer;ForwardHandle,ReverseHandle:Integer;
begin
  M:=TLaneManager.Create;
  try
    M.SetRoad(6.5,2000);A:=M.RegisterRider(Pointer(1));B:=M.RegisterRider(Pointer(2));
    for I:=0 to 1 do begin
      if I=0 then begin ForwardHandle:=A;ReverseHandle:=B end else begin ForwardHandle:=B;ReverseHandle:=A end;
      M.InvalidateRiderPose(A);M.InvalidateRiderPose(B);
      M.SetRiderPose(A,Vector3(0,0,0),Vector3(0,0,1),6.5,0,0);
      M.SetRiderPose(B,Vector3(0,0,600),Vector3(0,0,-1),6.5,0,0);
      M.SetNarrowPassage(ForwardHandle,123,True,False,30);M.SetNarrowPassage(ReverseHandle,123,False,False,30);M.Update(1);
      Check(M.TrafficLimit(ForwardHandle)>50,'canonical priority depends on local handle');
      Check(M.TrafficLimit(ReverseHandle)<7,'simultaneous opposite entry not held');
    end;
    M.SetNarrowPassage(A,123,False,False,20);M.SetNarrowPassage(B,0,False,False,0);M.Update(8);
    M.SetNarrowPassage(B,123,True,False,30);M.Update(0.1);
    Check(M.TrafficLimit(A)>50,'old opposite request starved by a new preferred direction');
    Check(M.TrafficLimit(B)<7,'newcomer ignores old waiting direction');
    M.SetNarrowPassage(B,123,True,True,-100);
    Check(M.TrafficLimit(A)=0,'inside occupancy must preserve zero entry limit');
    M.SetRiderActive(B,False);Check(M.TrafficLimit(A)>50,'inactive rider retained reservation');
    M.SetRiderActive(B,True);M.SetNarrowPassage(B,123,True,True,-100);
    M.UnregisterRider(B);Check(M.TrafficLimit(A)>50,'unregistered rider retained reservation');
    Writeln('PASS shared canonical priority, waiting fairness, inside priority, deactivate/unregister');
  finally M.Free end;
end;

procedure TestOncomingCorridor(Fps:Integer;Group:Boolean;Terminal:Boolean=False);
var M:TLaneManager;Agents:array[0..3]of TPhysicalAgent;G:TGround;
    P:TPathPosition;C:TPowerController;I,J,K,Count,DoneCount,InsideCount,TestSeconds:Integer;
    DT,Clearance:Single;Delta:TVector3;Done:array[0..3]of Boolean;
    WasWaiting,EnteredTogether:Boolean;PrevDistance:array[0..3]of Single;
    Snapshot:TLaneReplayState;
begin
  M:=TLaneManager.Create;G:=TGround.Create;FillChar(Agents,SizeOf(Agents),0);
  FillChar(Done,SizeOf(Done),0);FillChar(PrevDistance,SizeOf(PrevDistance),0);
  if Group then Count:=4 else Count:=2;
  TestSeconds:=240;if Terminal then begin Count:=3;TestSeconds:=600 end;
  try
    M.SetRoad(6.5,1600);DT:=1/Fps;WasWaiting:=False;EnteredTogether:=False;DoneCount:=0;
    for I:=0 to Count-1 do begin
      Agents[I]:=TPhysicalAgent.Create(nil);
      if Terminal then begin
        Agents[I].Path.LoadFromMemory([Vector3(0,0,-100),Vector3(0,0,-20),Vector3(0,0,0),
          Vector3(0,0,522),Vector3(0,0,0),Vector3(0,0,-20)], [6.5,6.5,1.2,1.2,1.2,6.5]);
        Agents[I].Path.UsePreparedCornerHints(True);
      end else if I=Count-1 then Agents[I].Path.LoadFromMemory(
        [Vector3(0,0,700),Vector3(0,0,542),Vector3(0,0,522),Vector3(0,0,0),Vector3(0,0,-20),Vector3(0,0,-100)], [6.5,6.5,1.2,1.2,6.5,6.5])
      else Agents[I].Path.LoadFromMemory(
        [Vector3(0,0,-100),Vector3(0,0,-20),Vector3(0,0,0),Vector3(0,0,522),Vector3(0,0,542),Vector3(0,0,700)], [6.5,6.5,1.2,1.2,6.5,6.5]);
      Agents[I].Path.CarrotWobbleEnabled:=False;
      Agents[I].Actor.Transform:=TCastleTransform.Create(nil);
      Agents[I].State.GroundQuery:=@G.Query;Agents[I].State.PhysicsLOD:=plMinimal;
      Agents[I].RecreatePhysics(pmKinematicCurrent);Agents[I].InitializeAtStart;
      P.Segment:=0;if(I=Count-1)and not Terminal then P.T:=150/158 else P.T:=(60-I*5)/80;
      Agents[I].TeleportToPath(P);PlaceTrafficAgent(M,Agents[I]);
      C:=TPowerController.Create;C.SetDesiredPower(250);C.SetAutoMove(True);Agents[I].SetController(C);
    end;
    for K:=1 to Fps*TestSeconds do begin
      UpdateRiderTraffic(M,DT);
      for I:=0 to Count-1 do if not Done[I]then begin
        Agents[I].UpdateOffline(DT,DT);
        Check(Agents[I].State.CumulativeDistance>=PrevDistance[I],'corridor wait reset odometer');
        PrevDistance[I]:=Agents[I].State.CumulativeDistance;
        if(I=Count-1)and(Agents[I].State.CurrentSpeed<0.1)and(K>Fps*10)then WasWaiting:=True;
        if(Terminal and(Agents[I].State.CumulativeDistance>1000)and(Agents[I].State.WorldPosition.Z< -50))or
          (not Terminal and(((I<Count-1)and(Agents[I].State.WorldPosition.Z>580))or
           ((I=Count-1)and(Agents[I].State.WorldPosition.Z< -50))))then begin
          Done[I]:=True;Inc(DoneCount);M.UnregisterRider(M.FindRider(Agents[I]));
        end;
      end;
      for I:=0 to Count-1 do for J:=0 to I-1 do if not Done[I]and not Done[J]then begin
        Delta:=Agents[I].State.WorldPosition-Agents[J].State.WorldPosition;
        Clearance:=Sqr(Delta.X/0.9)+Sqr(Delta.Z/2.2);
        Check(Clearance>=0.99,'opposing cyclists intersected');
        if not Terminal and(I=Count-1)and(Agents[I].State.WorldPosition.Z>0)and(Agents[I].State.WorldPosition.Z<522)and
          (Agents[J].State.WorldPosition.Z>0)and(Agents[J].State.WorldPosition.Z<522)then EnteredTogether:=True;
      end;
      if Terminal then begin
        InsideCount:=0;for I:=0 to Count-1 do if not Done[I]and(Agents[I].State.WorldPosition.Z>0)then Inc(InsideCount);
        Check(InsideCount<=1,'two riders entered an exclusive narrow U-turn');
      end;
      if DoneCount=Count then Break;
    end;
    Check(not EnteredTogether,'opposing cyclists entered the same single-file corridor');
    if DoneCount<>Count then begin Snapshot:=M.CaptureReplay;for I:=0 to Count-1 do Writeln('stuck ',I,' pos=',Agents[I].State.WorldPosition.X:0:3,',',Agents[I].State.WorldPosition.Z:0:3,
      ' speed=',Agents[I].State.CurrentSpeed:0:3,' limit=',Agents[I].State.TrafficSpeedLimit:0:3,' lane=',Agents[I].State.LaneOffset:0:3,
      ' path=',Agents[I].Path.Position.Segment,':',Agents[I].Path.Position.T:0:3,
      ' stored=',Snapshot[I].WorldPosition.X:0:3,',',Snapshot[I].WorldPosition.Z:0:3,
      ' speed=',Snapshot[I].Speed:0:3,' actual=',Snapshot[I].ActualOffset:0:3,' target=',Snapshot[I].Lane,' width=',Snapshot[I].RoadWidth:0:3);end;
    Check(DoneCount=Count,Format('single-file corridor deadlocked: %d/%d passed at %d FPS',[DoneCount,Count,Fps]));
    Check(WasWaiting,'opposing entry was never held');
    Writeln('PASS 522m corridor at ',Fps,' FPS, riders=',Count,' terminal=',Terminal,' time=',K/Fps:0:1,'s');
  finally
    for I:=0 to High(Agents)do if Agents[I]<>nil then begin Agents[I].Actor.Transform.Free;Agents[I].Free end;
    G.Free;M.Free;
  end;
end;

procedure TestAlongsideTarget;
var M:TLaneManager;A,B:Integer;P,Q,CA,CB,D,R:TVector3;
    OA,OB:Single;S:TLaneReplayState;
begin
  M:=TLaneManager.Create;
  try
    { Recorded Focus stop, D493: the avatar stands outside its neighbour,
      but keeps requesting lane4 on the other side of that bicycle. The
      neighbour is only 45cm behind, so its entire bicycle is alongside. }
    M.SetRoad(8,1000);A:=M.RegisterRider(Pointer(1));B:=M.RegisterRider(Pointer(2));
    P:=Vector3(1815.824829,0,-285.273193);Q:=Vector3(1816.636230,0,-286.000977);
    CA:=Vector3(1818.116699,0,-285.994873);CB:=Vector3(1817.980469,0,-286.425842);
    D:=(CA-CB).Normalize;R:=Vector3(-D.Z,0,D.X);
    OA:=TVector3.DotProduct(P-CA,R);OB:=TVector3.DotProduct(Q-CB,R);
    M.SetRiderPose(A,P,D,6.5,OA,0);M.SetRiderPose(B,Q,D,6.5,OB,0);
    S:=M.CaptureReplay;S[A].Lane:=4;S[A].SmoothLane:=4;
    S[B].Lane:=7;S[B].SmoothLane:=7;M.RestoreReplay(S);
    Check(Abs(M.GetSmoothOffset(A,6.5)+0.7125)<0.0001,'Focus fixture lost recorded lane target');
    M.Update(10);
    Check(M.GetSmoothOffset(A,6.5)>OB+0.95,
      'alongside cyclist behind us still permits a target across its bicycle');
    S:=M.CaptureReplay;
    Check((S[A].WorldPosition-P).Length=0,'lane reconsideration teleported the cyclist');
    Check((S[B].WorldPosition-Q).Length=0,'lane reconsideration moved the neighbour');
    { Second recorded failure, DAA2: after the sharp bend it is the bot's
      old lane2 target that lies beyond the avatar slightly behind it. }
    P:=Vector3(1834.747437,0,-232.841354);Q:=Vector3(1834.715820,0,-234.360733);
    D:=Vector3(-0.803346,0,-0.595512).Normalize;
    M.SetRiderPose(A,P,D,6.5,0.709988,0);M.SetRiderPose(B,Q,D,6.5,1.911748,0);
    M.SetRiderHeading(A,Vector3(-0.816399,0,-0.577489));
    M.SetRiderHeading(B,Vector3(-0.991367,0,0.131113));
    Check(M.ConstrainMovement(Pointer(1),P,Vector3(-0.816399,0,-0.577489)*0.01,False).Length=0,
      'recorded avatar contact was not reproduced');
    Check(M.ConstrainMovement(Pointer(2),Q,Vector3(-0.991367,0,0.131113)*0.01,False).Length=0,
      'recorded bot contact was not reproduced');
    S:=M.CaptureReplay;S[A].Lane:=6;S[A].SmoothLane:=6;
    S[B].Lane:=2;S[B].SmoothLane:=2;M.RestoreReplay(S);M.Update(10);
    Check(M.GetSmoothOffset(B,6.5)>0.709988+0.95,
      'recorded bot keeps requesting a target across the avatar after the bend');
    S:=M.CaptureReplay;
    Check((S[A].WorldPosition-P).Length=0,'lane reconsideration moved the recorded avatar');
    Check((S[B].WorldPosition-Q).Length=0,'lane reconsideration teleported the recorded bot');
    Writeln('PASS two actual Focus pairs: swept contact retained, outer targets reachable');
  finally M.Free end;
end;

procedure TestAcceptedHeadingIntegration;
var M:TLaneManager;Ag:TPhysicalAgent;H,Peer,I:Integer;P,Q,OldDir,Proposed,Preview:TVector3;
    Before,After:TLaneReplayState;
begin
  M:=TLaneManager.Create;Ag:=TPhysicalAgent.Create(nil);
  try
    M.SetRoad(8,1000);Ag.Actor.Transform:=TCastleTransform.Create(nil);
    Ag.RecreatePhysics(pmKinematicCurrent);H:=RegisterTrafficAgent(M,Ag);
    Peer:=M.RegisterRider(Pointer(2));
    { Recorded 689m pair, but begin from a genuinely admissible parallel
      pose. This checks prevention of the turn, not depenetration of the
      already overlapping failure snapshot. }
    P:=Vector3(1834.747437,0,-232.841354);Q:=Vector3(1834.715820,0,-234.360733);
    OldDir:=Vector3(-0.816399,0,-0.577489).Normalize;
    Proposed:=Vector3(-0.991367,0,0.131113).Normalize;
    M.SetRiderPose(H,Q,OldDir,6.5,1.911748,0);
    M.SetRiderPose(Peer,P,OldDir,6.5,0.709988,0);
    Ag.State.WorldPosition:=Q;Ag.State.ForwardDir:=OldDir;
    Ag.State.CurrentYawRad:=ArcTan2(OldDir.Z,OldDir.X);
    Ag.Actor.Transform.Direction:=OldDir;
    Before:=M.CaptureReplay;
    Preview:=M.ConstrainHeading(Ag,Q,OldDir,Proposed,False);After:=M.CaptureReplay;
    Check((Before[H].CollisionDir-After[H].CollisionDir).Length=0,'read-only turn changed collision heading');
    Check((Before[H].WorldPosition-After[H].WorldPosition).Length=0,'read-only turn changed position');
    Check((Preview-Proposed).Length>0.01,'recorded turn still accepted the overlapping target');
    { A no-translation turn goes through the actual production method.
      Its accepted angle must be committed even without a movement call. }
    for I:=1 to 120 do
      TPhysicsAccess(Ag.Physics).RotateForTest(Proposed,1/60);
    After:=M.CaptureReplay;
    Check((After[H].CollisionDir-Ag.State.ForwardDir).Length<1e-6,'turn-only state and collision heading diverged');
    Check((Ag.Actor.Transform.Direction-Ag.State.ForwardDir).Length<1e-6,'model and physical heading diverged');
    Check((Vector3(Cos(Ag.State.CurrentYawRad),0,Sin(Ag.State.CurrentYawRad))-Ag.State.ForwardDir).Length<1e-6,
      'accepted yaw and forward direction diverged');
    Check((Ag.State.WorldPosition-Q).Length=0,'blocked turn moved the physical bicycle');
    Check((After[H].WorldPosition-Q).Length=0,'blocked turn moved the collision bicycle');
    Check((Ag.State.ForwardDir-Proposed).Length>0.01,'repeated stopped turns crossed the contact boundary');
    M.UnregisterRider(Peer);
    TPhysicsAccess(Ag.Physics).RotateForTest(Proposed,1);
    Check((Ag.State.ForwardDir-Proposed).Length<1e-6,'released neighbour left a stale heading restriction');
    After:=M.CaptureReplay;
    Check((After[H].CollisionDir-Ag.State.ForwardDir).Length<1e-6,'free turn did not publish the accepted heading');
    Writeln('PASS actual turn method: state/model/collision agree, no translation, release and read-only preview');
  finally Ag.Actor.Transform.Free;Ag.Free;M.Free end;
end;

procedure TestCollisionHeading;
var M:TLaneManager;A,B:Integer;P,Q,Body,Move,Safe:TVector3;S:TLaneReplayState;
begin
  M:=TLaneManager.Create;
  try
    M.SetRoad(6.5,1000);A:=M.RegisterRider(Pointer(1));B:=M.RegisterRider(Pointer(2));
    { Actual Ahun stop: two neighbours straddle a 35-degree path corner,
      while their bodies still have parallel, smoothly turning headings. }
    P:=Vector3(1916.065552,0,-638.3125);Q:=Vector3(1917.119019,0,-639.044373);
    M.SetRiderPose(A,P,Vector3(0.779818,0,0.626007),6.5,0,0);
    M.SetRiderPose(B,Q,Vector3(0.280336,0,0.959902),6.5,0,0);
    Body:=Vector3(0.724748,0,0.689014).Normalize;Move:=Body*0.01;
    Safe:=M.ConstrainMovement(Pointer(1),P,Move,False);
    Check(Safe.Length=0,'corner fixture did not reproduce false tangent overlap');
    M.SetRiderHeading(A,Body);M.SetRiderHeading(B,Body);
    Safe:=M.ConstrainMovement(Pointer(1),P,Move,False);
    Check(Safe.Length>0.0099,'physical heading still inherits the path-corner overlap');
    S:=M.CaptureReplay;
    Check(Abs(S[A].ForwardDir.X-0.779818)<0.001,'body heading changed the lane tangent');
    Check((S[A].WorldPosition-P).Length=0,'read-only sweep moved the rider');
    M.SetRiderHeading(A,Vector3(0,0,1));M.RestoreReplay(S);S:=M.CaptureReplay;
    Check((S[A].CollisionDir-Body).Length<0.0001,'replay lost physical collision heading');
    Writeln('PASS actual Ahun corner: lane tangent independent of collision heading');
  finally M.Free end;
end;

procedure TestCollisionHeadingSubsteps;
var M:TLaneManager;A,B,H,I:Integer;P,Move,Safe,BeforeHeading:TVector3;
    Snapshot:TLaneReplayState;Ag:TPhysicalAgent;G:TGround;C:TPowerController;
    Cursor:TPathPosition;MaxTurn,Turn:Double;
begin
  M:=TLaneManager.Create;
  try
    M.SetRoad(6.5,1000);A:=M.RegisterRider(Pointer(1));B:=M.RegisterRider(Pointer(2));
    P:=Vector3(0,0,0);Move:=Vector3(0,0,0.01);
    M.SetRiderPose(A,P,Vector3(0,0,1),6.5,0,0);
    M.SetRiderPose(B,Vector3(1.2,0,0.1),Vector3(0,0,1),6.5,0,0);
    { The frame snapshot still faces X, but this physical step is already
      parallel to the neighbour. The old stale ellipse falsely blocked it. }
    M.SetRiderHeading(A,Vector3(1,0,0));
    Safe:=M.ConstrainMovement(Pointer(1),P,Move,False);
    Check(Safe.Length>0.0099,'substep sweep still uses stale frame heading');
    Snapshot:=M.CaptureReplay;
    Check((Snapshot[A].CollisionDir-Vector3(1,0,0)).Length=0,'extrapolation changed collision heading');
    Check((Snapshot[A].WorldPosition-P).Length=0,'extrapolation changed collision position');
    Safe:=M.ConstrainMovement(Pointer(1),P,Move,True);Snapshot:=M.CaptureReplay;
    Check((Snapshot[A].CollisionDir-Vector3(0,0,1)).Length<1e-6,'committed step kept stale heading');
    Check((Snapshot[A].WorldPosition-(P+Safe)).Length<1e-6,'committed step lost position');
    M.SetRiderPose(B,Vector3(0,0,1),Vector3(0,0,1),6.5,0,0);
    M.SetRiderHeading(A,Vector3(1,0,0));
    Safe:=M.ConstrainMovement(Pointer(1),P,Move,True);Snapshot:=M.CaptureReplay;
    Check(Safe.Length=0,'overlap unexpectedly passed through neighbour');
    Check((Snapshot[A].CollisionDir-Vector3(0,0,1)).Length<1e-6,'blocked step lost physical heading');
    Writeln('PASS current movement heading, commit/read-only separation and blocked step');
  finally M.Free end;

  M:=TLaneManager.Create;G:=TGround.Create;Ag:=TPhysicalAgent.Create(nil);
  try
    M.SetRoad(6.5,400);
    Ag.Path.LoadFromMemory([Vector3(0,0,0),Vector3(0,0,20),Vector3(100,0,20),Vector3(100,0,120)],
      [6.5,6.5,6.5,6.5]);
    Ag.Path.CarrotWobbleEnabled:=False;
    Ag.Actor.Transform:=TCastleTransform.Create(nil);Ag.State.GroundQuery:=@G.Query;
    Ag.State.PhysicsLOD:=plFull;Ag.RecreatePhysics(pmKinematicCurrent);Ag.InitializeAtStart;
    Cursor.Segment:=0;Cursor.T:=0.45;Ag.TeleportToPath(Cursor);PlaceTrafficAgent(M,Ag);
    { This fixture exercises travelling headings across many fixed steps,
      not asynchronous ground availability. Keep the real full kinematics
      on its already flat plane; GroundLeaseTests separately checks the
      streaming hold at 10 FPS x8. A ground hold would turn in place and
      thus stop testing the movement-derived collision heading below. }
    Ag.State.GroundQuery:=nil;
    C:=TPowerController.Create;C.SetDesiredPower(300);C.SetAutoMove(True);Ag.SetController(C);
    Ag.State.CurrentSpeed:=8;H:=M.FindRider(Ag);MaxTurn:=0;
    for I:=1 to 10 do begin
      UpdateRiderTraffic(M,0.8);BeforeHeading:=Ag.State.ForwardDir;
      { Actual 10 FPS x8: many fixed steps share one traffic update. }
      Ag.UpdateOffline(0.8,1/60,64);Snapshot:=M.CaptureReplay;
      Turn:=RadToDeg(ArcCos(EnsureRange(TVector3.DotProduct(BeforeHeading,Ag.State.ForwardDir.Normalize),-1.0,1.0)));
      MaxTurn:=Max(MaxTurn,Turn);
      Check((Snapshot[H].CollisionDir-Ag.State.ForwardDir.Normalize).Length<1e-5,
        'actual fixed steps left collision heading at the previous render frame');
    end;
    Check(MaxTurn>20,'substep fixture did not exercise a significant turn');
    Writeln('PASS actual 10 FPS x8 heading refresh, largest frame turn=',MaxTurn:0:3,' deg');
  finally Ag.Actor.Transform.Free;Ag.Free;G.Free;M.Free end;
end;

procedure TestExclusiveAdmissionTies;
var M:TLaneManager;A,B,First,Second,Order,CaseIndex:Integer;D:Single;
begin
  for Order:=0 to 1 do for CaseIndex:=0 to 1 do begin
    M:=TLaneManager.Create;
    try
      M.SetRoad(6.5,1600);A:=M.RegisterRider(Pointer(1));B:=M.RegisterRider(Pointer(2));
      if Order=0 then begin First:=A;Second:=B end else begin First:=B;Second:=A end;
      D:=CaseIndex*0.04;
      M.SetRiderPose(First,Vector3(-1,0,-20),Vector3(0,0,1),6.5,1,0);
      M.SetRiderPose(Second,Vector3(1,0,-20+D),Vector3(0,0,1),6.5,-1,0);
      M.SetNarrowPassage(First,123,True,False,20,True);
      M.SetNarrowPassage(Second,123,True,False,20-D,True);
      if CaseIndex=0 then begin
        Check(M.TrafficLimit(First)>50,'equal-entry exclusive priority depends on local handle');
        Check(M.TrafficLimit(Second)=0,'equal-entry exclusive admitted two riders');
      end else begin
        Check(M.TrafficLimit(Second)>50,'nearer exclusive rider did not get admission');
        Check(M.TrafficLimit(First)=0,'exclusive distance tie band admitted two riders');
      end;
    finally M.Free end;
  end;
  Writeln('PASS exclusive same-entry and 4cm-separated admissions, reversed registration');
end;

procedure TestFreeTravelRelease;
var M:TLaneManager;A,B:TPhysicalAgent;P:TVector3;Saved:TLaneReplayState;H:Integer;
begin
  M:=TLaneManager.Create;A:=TPhysicalAgent.Create(nil);B:=TPhysicalAgent.Create(nil);
  try
    M.SetRoad(1.2,4000);
    A.Path.LoadFromMemory([Vector3(0,0,0),Vector3(0,0,1000),Vector3(0,0,2000)],[1.2,1.2,1.2]);
    A.Path.CopyTo(B.Path);
    A.State.WorldPosition:=Vector3(0,0,100);A.State.ForwardDir:=Vector3(0,0,1);
    A.State.CurrentSpeed:=8;
    B.State.WorldPosition:=Vector3(0,0,105);B.State.ForwardDir:=Vector3(0,0,1);
    RegisterTrafficAgent(M,A);H:=RegisterTrafficAgent(M,B);
    UpdateRiderTraffic(M,0.1);
    Check(A.State.TrafficSpeedLimit<4,'route rider brakes for the waiting company');
    M.SetNarrowPassage(H,42,True,True,0,True);
    B.State.FreeTravel:=True;B.State.TrafficSpeedLimit:=0;
    UpdateRiderTraffic(M,0.1);Saved:=M.CaptureReplay;
    Check(not Saved[H].PoseValid and(Saved[H].PassageKey=0),'off-route rider releases pose and narrow passage');
    Check(A.State.TrafficSpeedLimit=MaxSpeed,'off-route avatar cannot leave a phantom traffic obstacle');
    Check(not Assigned(B.State.TrafficMoveConstraint)and not Assigned(B.State.TrafficHeadingConstraint)
      and not B.State.LaneOffsetExternal and(B.State.TrafficSpeedLimit=MaxSpeed),
      'free travel clears route constraints and stale speed limit');
    P:=Vector3(40,0,123);B.State.WorldPosition:=P;B.State.CumulativeDistance:=0;
    PlaceTrafficStartSlot(M,B,3);PlaceTrafficAgent(M,B);
    Check((B.State.WorldPosition-P).Length=0,'registering free travel must not teleport onto route');
    Check(B.State.CumulativeDistance=0,'free travel must not advance to a route start slot');
    B.State.WorldPosition:=Vector3(0,0,105);B.State.FreeTravel:=False;
    UpdateRiderTraffic(M,0.1);Saved:=M.CaptureReplay;
    Check(Saved[H].PoseValid and Assigned(B.State.TrafficMoveConstraint)
      and Assigned(B.State.TrafficHeadingConstraint)and B.State.LaneOffsetExternal,
      'returning to route restores traffic without another registration');
    Check(A.State.TrafficSpeedLimit<4,'returning avatar participates in traffic again');
    Writeln('PASS free travel: release, no placement teleport, route return');
  finally A.Free;B.Free;M.Free end;
end;

procedure TestKinematicTraffic(Width: Single);
const DT=1/60;
var M: TLaneManager; A,B: TPhysicalAgent; G:TGround; P:TPathPosition;
    CA,CB:TPowerController;
    I:Integer; Delta:TVector3; MinClearance,Clearance:Single;
begin
  M:=TLaneManager.Create;A:=TPhysicalAgent.Create(nil);B:=TPhysicalAgent.Create(nil);
  G:=TGround.Create;
  try
    M.SetRoad(Width,4000);
    A.Path.LoadFromMemory([Vector3(0,0,0),Vector3(0,0,1000),Vector3(0,0,2000)], [Width,Width,Width]);
    A.Path.CopyTo(B.Path);
    A.Actor.Transform:=TCastleTransform.Create(nil);B.Actor.Transform:=TCastleTransform.Create(nil);
    A.State.GroundQuery:=@G.Query;B.State.GroundQuery:=@G.Query;
    A.State.PhysicsLOD:=plMinimal;B.State.PhysicsLOD:=plMinimal;
    A.RecreatePhysics(pmKinematicCurrent);B.RecreatePhysics(pmKinematicCurrent);
    A.InitializeAtStart;B.InitializeAtStart;
    P:=B.Path.Position;B.Path.AdvanceFollow(P,16);B.TeleportToPath(P);
    PlaceTrafficAgent(M,A);PlaceTrafficAgent(M,B);
    CA:=TPowerController.Create;CB:=TPowerController.Create;
    CA.SetDesiredPower(350);CB.SetDesiredPower(100);CA.SetAutoMove(True);CB.SetAutoMove(True);
    A.SetController(CA);B.SetController(CB);MinClearance:=1e20;
    for I:=1 to 60*70 do begin
      UpdateRiderTraffic(M,DT);
      A.UpdateOffline(DT,DT);B.UpdateOffline(DT,DT);
      Delta:=A.State.WorldPosition-B.State.WorldPosition;
      Clearance:=Sqr(Delta.X/0.9)+Sqr(Delta.Z/2.2);
      MinClearance:=Min(MinClearance,Clearance);
      Check(Clearance>=0.99,'kinematic riders intersected');
      Check(Abs(A.State.WorldPosition.X)<=Width*0.5,'passing rider left the road');
    end;
    Check(A.State.CumulativeDistance>200,Format('kinematic follower stalled: width=%.1f a=(%.2f,%.2f) b=(%.2f,%.2f) speed=%.2f/%.2f dist=%.2f power=%.1f auto=%s lane=%.2f/%.2f limit=%.2f',
      [Width,A.State.WorldPosition.X,A.State.WorldPosition.Z,B.State.WorldPosition.X,B.State.WorldPosition.Z,
       A.State.CurrentSpeed,B.State.CurrentSpeed,A.State.CumulativeDistance,A.State.AppliedPowerWatts,
       BoolToStr(A.State.AutoMove,True),A.State.LaneOffset,B.State.LaneOffset,A.State.TrafficSpeedLimit]));
    if Width>3 then Check(A.State.WorldPosition.Z>B.State.WorldPosition.Z+5,'wide-road overtake did not complete')
    else Check(A.State.WorldPosition.Z<B.State.WorldPosition.Z-2.19,'narrow-road follower passed through leader');
    Writeln('PASS kinematic traffic: width=',Width:0:1,' min clearance=',MinClearance:0:3,
      ' distance=',A.State.CumulativeDistance:0:1);
  finally A.Actor.Transform.Free;B.Actor.Transform.Free;A.Free;B.Free;G.Free;M.Free end;
end;

begin
  TestStart;TestCompanionStart;TestMovement;TestAgentPlacement;TestRoomStartSlots;TestRemoteCoasting;TestFollowing(10);TestFollowing(30);TestFollowing(144);
  TestFreeTravelRelease;TestKinematicTraffic(8);TestKinematicTraffic(1.2);
  TestNarrowPassageKeys;
  TestPassagePriority;
  TestAlongsideTarget;
  TestAcceptedHeadingIntegration;
  TestCollisionHeading;
  TestCollisionHeadingSubsteps;
  TestExclusiveAdmissionTies;
  TestOncomingCorridor(10,False);TestOncomingCorridor(30,False);TestOncomingCorridor(144,False);
  TestOncomingCorridor(30,True);
  TestOncomingCorridor(10,False,True);TestOncomingCorridor(30,False,True);TestOncomingCorridor(144,False,True);
  if ParamCount>0 then TestCachedPassages(ParamStr(1));
end.
