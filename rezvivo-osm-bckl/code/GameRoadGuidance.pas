unit GameRoadGuidance;
{$mode objfpc}{$H+}
interface
uses Math,CastleVectors,Osm3dTravelRoads;
const
  RoadAcquireSeconds=3.0;
  RoadAcquireHeadingDot=0.90;
type
  TRoadGuidance=class
  private
    FRoads:TTravelRoads;
    FLocked:TTravelRoad;
    FHasLock,FTurning:Boolean;
    FTurnRoad:TTravelRoad;
    FTurnDirection:Integer;
    FDirection,FPending:Integer;
    FPendingTime,FManualHold,FReacquire,FLateral:Single;
    FAcquireTime:Double;
    FAcquireValid:Boolean;
    FAcquireRoad:TTravelRoad;
    FAcquireDirection:Integer;
    procedure ResetAcquisition;
    function FindCurrent(const P,Heading:TVector3;MinDot:Single=0.45):Integer;
    function NextRoad(Index,Direction,Turn:Integer;out NextDirection:Integer):Integer;
  public
    OnRoad,Following,TurnTaken:Boolean;
    Width,Distance,SpeedLimit:Single;
    WayId:Int64;
    procedure Reset;
    procedure SetRoads(const Value:TTravelRoads);
    procedure QueueTurn(Direction:Integer);
    function Step(const P,Heading:TVector3;Speed,ManualAxis,Dt:Single;
      AcquireDelay:Single=RoadAcquireSeconds):Single;
    property PendingTurn:Integer read FPending;
    property SelectedTurnRoad:TTravelRoad read FTurnRoad;
    property SelectedTurnDirection:Integer read FTurnDirection;
    property AcquireTime:Double read FAcquireTime;
  end;
implementation
function FlatUnit(const V:TVector3):TVector3;
var L:Single;
begin L:=Sqrt(Sqr(V.X)+Sqr(V.Z));if L<1e-6 then Exit(Vector3(0,0,0));Result:=Vector3(V.X/L,0,V.Z/L)end;
function SignedAngle(const A,B:TVector3):Single;
begin Result:=ArcTan2(A.Z*B.X-A.X*B.Z,A.X*B.X+A.Z*B.Z) end;
function SameRoad(const A,B:TTravelRoad):Boolean;
begin Result:=(A.WayId=B.WayId)and
  (((RoadDistanceSq(A.A,B.A)<0.04)and(RoadDistanceSq(A.B,B.B)<0.04))or
   ((RoadDistanceSq(A.A,B.B)<0.04)and(RoadDistanceSq(A.B,B.A)<0.04)))end;
function ContinuesRoad(const A,B:TTravelRoad;ADirection,BDirection:Integer):Boolean;
var EndP,StartP:TVector3;
begin
  if A.WayId=B.WayId then Exit(True);
  if ADirection>0 then EndP:=A.B else EndP:=A.A;
  if BDirection>0 then StartP:=B.A else StartP:=B.B;
  Result:=RoadDistanceSq(EndP,StartP)<0.25;
end;
procedure TRoadGuidance.Reset;
begin
  FHasLock:=False;FTurning:=False;FPending:=0;FPendingTime:=0;FManualHold:=0;FReacquire:=0;
  ResetAcquisition;
  Following:=False;OnRoad:=False;TurnTaken:=False;WayId:=0;Width:=0;Distance:=0;FLateral:=0;SpeedLimit:=100;
end;
procedure TRoadGuidance.ResetAcquisition;
begin FAcquireTime:=0;FAcquireValid:=False end;
procedure TRoadGuidance.SetRoads(const Value:TTravelRoads);
begin FRoads:=Value end;
procedure TRoadGuidance.QueueTurn(Direction:Integer);
begin if Direction<>0 then begin FPending:=Sign(Direction);FPendingTime:=6 end end;
function TRoadGuidance.FindCurrent(const P,Heading:TVector3;MinDot:Single):Integer;
var I:Integer;Q,D:TVector3;T,Dist,Score,Best,Dot:Single;
begin
  Result:=-1;Best:=1e30;Distance:=1e30;OnRoad:=False;Width:=0;
  for I:=0 to High(FRoads)do begin
    Q:=RoadProjection(P,FRoads[I],T);Dist:=Sqrt(RoadDistanceSq(P,Q));
    if Dist<FRoads[I].Width*0.5+0.2 then OnRoad:=True;
    if Dist<Distance then Distance:=Dist;
    if Dist>FRoads[I].Width*0.5+0.65 then Continue;
    D:=FlatUnit(FRoads[I].B-FRoads[I].A);Dot:=Abs(TVector3.DotProduct(D,Heading));
    if Dot<MinDot then Continue;
    Score:=Dist+(1-Dot)*4;
    if FHasLock and(FRoads[I].WayId=FLocked.WayId)then Score:=Score-1.5;
    if FHasLock and SameRoad(FRoads[I],FLocked)then Score:=Score-2;
    if Score<Best then begin Best:=Score;Result:=I end;
  end;
end;
function TRoadGuidance.NextRoad(Index,Direction,Turn:Integer;out NextDirection:Integer):Integer;
var I,D:Integer;EndP,H,V:TVector3;Angle,Score,Best:Single;
begin
  Result:=-1;NextDirection:=1;Best:=1e30;
  H:=FlatUnit(FRoads[Index].B-FRoads[Index].A)*Direction;
  if Direction>0 then EndP:=FRoads[Index].B else EndP:=FRoads[Index].A;
  for I:=0 to High(FRoads)do begin
    if SameRoad(FRoads[I],FRoads[Index])then Continue;
    if RoadDistanceSq(EndP,FRoads[I].A)<0.25 then D:=1
    else if RoadDistanceSq(EndP,FRoads[I].B)<0.25 then D:=-1 else Continue;
    V:=FlatUnit(FRoads[I].B-FRoads[I].A)*D;Angle:=SignedAngle(H,V);
    if Abs(Angle)>Pi*0.85 then Continue;
    if Turn<>0 then begin
      if Angle*Turn<0.30 then Continue;
      Score:=Abs(Angle-Turn*Pi*0.5);
    end else begin
      Score:=Abs(Angle);
      { Stay on the current way through its bend. A straight side street
        must not become an unrequested turn just because its angle is less. }
      if FRoads[I].WayId=FRoads[Index].WayId then Score:=Score-Pi;
    end;
    if Score<Best then begin Best:=Score;Result:=I;NextDirection:=D end;
  end;
end;
function TRoadGuidance.Step(const P,Heading:TVector3;Speed,ManualAxis,Dt:Single;
  AcquireDelay:Single):Single;
var I,J,D,ND,N:Integer;T,Remain,Look,Angle,Rate,Use,HalfW,MinDot:Single;
  Q,H,Target,Right:TVector3;
begin
  Result:=ManualAxis;Following:=False;TurnTaken:=False;WayId:=0;SpeedLimit:=100;
  Dt:=EnsureRange(Dt,0,0.25);FReacquire:=Max(0,FReacquire-Dt);
  FPendingTime:=Max(0,FPendingTime-Dt);if FPendingTime=0 then FPending:=0;
  if Abs(ManualAxis)>0.25 then FManualHold:=FManualHold+Dt else FManualHold:=0;
  MinDot:=0.45;
  if not FHasLock and(AcquireDelay>0)then MinDot:=RoadAcquireHeadingDot;
  I:=FindCurrent(P,Heading,MinDot);
  { A held turn is an explicit request to leave the road. A short tap is
    latched for the next junction, where one connected branch is selected. }
  if FManualHold>0.45 then begin
    FReacquire:=0.7;FHasLock:=False;FTurning:=False;FPending:=0;ResetAcquisition;Exit
  end;
  if FTurning and(Speed>=0.2)then begin
    Q:=RoadProjection(P,FTurnRoad,T);
    H:=FlatUnit(FTurnRoad.B-FTurnRoad.A)*FTurnDirection;
    if FTurnDirection>0 then Target:=FTurnRoad.A else Target:=FTurnRoad.B;
    Remain:=TVector3.DotProduct(P-Target,H);
    if (Remain>1.5)and(Sqrt(RoadDistanceSq(P,Q))<FTurnRoad.Width*0.5)then begin
      FTurning:=False;FLocked:=FTurnRoad;FDirection:=FTurnDirection;FHasLock:=True;I:=FindCurrent(P,Heading);
    end else if RoadDistanceSq(P,Target)>Sqr(35)then FTurning:=False
    else begin
      Following:=True;WayId:=FTurnRoad.WayId;Width:=FTurnRoad.Width;
      SpeedLimit:=Sqrt(5*Max(1.5,Width*0.5));
      Target:=Target+H*EnsureRange(Abs(Speed)*0.55,2,7);
      Angle:=SignedAngle(Heading,FlatUnit(Target-P));
      Rate:=Min(1.25,Abs(Speed)*0.55);Rate:=Min(Rate,5/Max(1,Abs(Speed)));
      Exit(EnsureRange(Angle*2.5/Max(0.15,Rate),-1,1));
    end;
  end;
  if (I<0)or(FReacquire>0)or(Speed<0.2)then begin FHasLock:=False;ResetAcquisition;Exit end;
  H:=FlatUnit(FRoads[I].B-FRoads[I].A);D:=1;if TVector3.DotProduct(H,Heading)<0 then D:=-1;
  if FHasLock and(AcquireDelay>0)and not ContinuesRoad(FLocked,FRoads[I],FDirection,D)then begin
    FHasLock:=False;ResetAcquisition;
  end;
  if not FHasLock and(AcquireDelay>0)then begin
    if(Abs(ManualAxis)>=0.15)or(Abs(TVector3.DotProduct(H,Heading))<RoadAcquireHeadingDot)then begin
      ResetAcquisition;Exit
    end;
    { Count continuous forward travel on one corridor, not time spent near
      arbitrary roads. Segment boundaries and connected OSM way IDs do not
      interrupt the dwell; a different road or reversed heading does. }
    if not FAcquireValid or not ContinuesRoad(FAcquireRoad,FRoads[I],FAcquireDirection,D)or
      (TVector3.DotProduct(FlatUnit(FAcquireRoad.B-FAcquireRoad.A)*FAcquireDirection,H*D)<=0.5)then
      FAcquireTime:=0;
    FAcquireValid:=True;FAcquireRoad:=FRoads[I];FAcquireDirection:=D;
    FAcquireTime:=FAcquireTime+Dt;
    if FAcquireTime+1e-6<AcquireDelay then Exit;
  end;
  ResetAcquisition;
  Q:=RoadProjection(P,FRoads[I],T);Right:=Vector3(-H.Z*D,0,H.X*D);
  HalfW:=Max(0,FRoads[I].Width*0.5-0.45);
  if not FHasLock then FLateral:=EnsureRange(TVector3.DotProduct(P-Q,Right),-HalfW,HalfW);
  FLateral:=EnsureRange(FLateral,-HalfW,HalfW);
  FLocked:=FRoads[I];FHasLock:=True;FDirection:=D;
  Following:=True;WayId:=FLocked.WayId;Width:=FLocked.Width;
  Look:=EnsureRange(Abs(Speed)*0.75,2.0,9.0);
  if D>0 then Remain:=Sqrt(RoadDistanceSq(Q,FRoads[I].B))else Remain:=Sqrt(RoadDistanceSq(Q,FRoads[I].A));
  J:=-1;
  if FPending<>0 then J:=NextRoad(I,D,FPending,ND);
  if J<0 then J:=NextRoad(I,D,0,ND);
  if J>=0 then begin
    H:=FlatUnit(FRoads[I].B-FRoads[I].A)*D;
    Angle:=Abs(SignedAngle(H,FlatUnit(FRoads[J].B-FRoads[J].A)*ND));
    if Angle>0.4 then
      SpeedLimit:=Sqrt(5*Max(1.5,Min(FRoads[I].Width,FRoads[J].Width)*0.5)+4*Max(0,Remain-3));
  end;
  Target:=Q;N:=0;
  while (Look>Remain)and(N<12)do begin
    J:=-1;
    if FPending<>0 then J:=NextRoad(I,D,FPending,ND);
    if J>=0 then begin
      TurnTaken:=True;FPending:=0;FLateral:=0;
      FTurning:=True;FTurnRoad:=FRoads[J];FTurnDirection:=ND;
    end
    else J:=NextRoad(I,D,0,ND);
    if J<0 then Break;
    Look:=Look-Remain;I:=J;D:=ND;Inc(N);
    if D>0 then Target:=FRoads[I].A else Target:=FRoads[I].B;
    Remain:=Sqrt(RoadDistanceSq(FRoads[I].A,FRoads[I].B));
  end;
  H:=FlatUnit(FRoads[I].B-FRoads[I].A)*D;
  Use:=Min(Look,Remain);Target:=Target+H*Use+Vector3(-H.Z,0,H.X)*FLateral;
  H:=FlatUnit(Target-P);if H.LengthSqr<0.01 then Exit(0);
  Angle:=SignedAngle(Heading,H);
  Rate:=Min(1.25,Abs(Speed)*0.55);Rate:=Min(Rate,5/Max(1,Abs(Speed)));
  Result:=EnsureRange(Angle*2.5/Max(0.15,Rate),-1,1);
end;
end.
