{ Uses the snapper's existing spatial index. Runs in the route worker, never
  scans the full road network per ride frame and never requests more tiles. }
class function TRouteSnapper.BotCrossings(const Route:TRouteLatLonArray;
  const Segs:TSnapSegmentArray;Projection:TLocalProjection;
  const RouteWays:TRouteWayIdArray):TBotCrossingArray;
const MinSpacing=3000.0;MaxSpacing=10000.0;HalfRoute=160.0;
var
  Grid:TSnapGrid;Cells:TCellIndexArray;
  I,J,K,C,SI,Part,Parts,N,Pick:Integer;
  A,B,D,M,Q,V:TVector3;
  Len,Den,T,U,SinAngle,Along,Last,Target,BestError:Double;
  Candidates:TBotCrossingArray;
  Seen:array of Integer;
  RouteBridge:specialize TDictionary<Int64,Boolean>;
  Bridge:Boolean;
  Cross:TBotCrossing;

  function TraceRoad(SegIndex:Integer;const Center:TVector3;
    Forward:Boolean;out Points:TRouteVector3Array):Boolean;
  var Current,Previous,Step,Cell,Idx,NextSeg:Integer;
    P,EndP,Delta,PrevDir,Dir:TVector3;Remaining,L,Score,Best:Single;
    Around:TCellIndexArray;Visited:specialize TDictionary<Integer,Boolean>;
  begin
    Result:=False;Points:=nil;Current:=SegIndex;Previous:=-1;P:=Center;
    Remaining:=HalfRoute;PrevDir:=Vector3(Segs[Current].DX,0,Segs[Current].DZ)*Segs[Current].LenInv;
    if not Forward then PrevDir:=-PrevDir;
    Visited:=specialize TDictionary<Integer,Boolean>.Create;
    try
      for Step:=0 to 256 do begin
        if Visited.ContainsKey(Current)then Exit;
        Visited.Add(Current,True);
        if Forward then EndP:=Vector3(Segs[Current].X1,0,Segs[Current].Z1)
        else EndP:=Vector3(Segs[Current].X0,0,Segs[Current].Z0);
        Delta:=EndP-P;L:=Delta.Length;
        if L>0.01 then begin
          PrevDir:=Delta/L;
          if L>=Remaining then begin
            SetLength(Points,Length(Points)+1);Points[High(Points)]:=P+PrevDir*Remaining;
            Exit(True);
          end;
          SetLength(Points,Length(Points)+1);Points[High(Points)]:=EndP;
          Remaining:=Remaining-L;
        end;
        P:=EndP;Around:=GridCellsAround(Grid,P.X,P.Z);NextSeg:=-1;Best:=0.65;
        for Cell in Around do
          for Idx:=Grid.Starts[Cell]to Grid.Starts[Cell+1]-1 do begin
            Previous:=Grid.Indices[Idx];
            if Visited.ContainsKey(Previous)or Segs[Previous].IsBridge or
              (Segs[Previous].Width<6)then Continue;
            { OSM ways are commonly split AT the junction. Continue along
              connected, similarly wide carriageways, not just one way id. }
            if(Segs[Previous].WayId<>Segs[Current].WayId)and
              (Abs(Segs[Previous].Width-Segs[Current].Width)>Max(2,Segs[Current].Width*0.35))then Continue;
            { Stay on the actual polyline, including bends. Never extend a
              straight tangent into a house/field at a clipped road end. }
            if Sqr(Segs[Previous].X0-P.X)+Sqr(Segs[Previous].Z0-P.Z)<0.04 then
              Dir:=Vector3(Segs[Previous].DX,0,Segs[Previous].DZ)*Segs[Previous].LenInv
            else if Sqr(Segs[Previous].X1-P.X)+Sqr(Segs[Previous].Z1-P.Z)<0.04 then
              Dir:=-Vector3(Segs[Previous].DX,0,Segs[Previous].DZ)*Segs[Previous].LenInv
            else Continue;
            Score:=TVector3.DotProduct(Dir,PrevDir);
            if(Segs[Previous].WayId<>Segs[Current].WayId)and(Score<0.87)then Continue;
            if Score>Best then begin Best:=Score;NextSeg:=Previous end;
          end;
        if NextSeg<0 then Exit;
        Forward:=Sqr(Segs[NextSeg].X0-P.X)+Sqr(Segs[NextSeg].Z0-P.Z)<0.04;
        Current:=NextSeg;
      end;
    finally Visited.Free end;
  end;

  function MakeRoute(SegIndex:Integer;const Center:TVector3;out Crossing:TBotCrossing):Boolean;
  var Left,Right:TRouteVector3Array;K,M:Integer;
  begin
    Crossing:=Default(TBotCrossing);Result:=False;
    if not TraceRoad(SegIndex,Center,False,Left)then Exit;
    if not TraceRoad(SegIndex,Center,True,Right)then Exit;
    SetLength(Crossing.Points,Length(Left)+1+Length(Right));M:=0;
    for K:=High(Left)downto 0 do begin Crossing.Points[M]:=Left[K];Inc(M) end;
    Crossing.Points[M]:=Center;Inc(M);
    for K:=0 to High(Right)do begin Crossing.Points[M]:=Right[K];Inc(M) end;
    Crossing.Width:=Segs[SegIndex].Width;Crossing.WayId:=Segs[SegIndex].WayId;
    Crossing.Center:=Center;Result:=True;
  end;
begin
  Result:=nil;
  if(Length(Route)<2)or(Length(Segs)=0)then Exit;
  BuildSegmentGrid(Segs,Grid);SetLength(Seen,Length(Segs));Along:=0;
  RouteBridge:=specialize TDictionary<Int64,Boolean>.Create;
  try
    for I:=0 to High(Segs)do if Segs[I].IsBridge then RouteBridge.AddOrSetValue(Segs[I].WayId,True);
    for I:=0 to High(Route)-1 do begin
      A:=Projection.Project(Route[I]);B:=Projection.Project(Route[I+1]);D:=B-A;Len:=D.Length;
      if Len<0.01 then Continue;
      Bridge:=False;
      if I<Length(RouteWays)then Bridge:=RouteBridge.ContainsKey(RouteWays[I]);
      if not Bridge then begin
        Parts:=Max(1,Ceil(Len/25));
        for Part:=0 to Parts-1 do begin
          M:=A+D*((Part+0.5)/Parts);Cells:=GridCellsAround(Grid,M.X,M.Z);
          for C in Cells do for J:=Grid.Starts[C]to Grid.Starts[C+1]-1 do begin
            SI:=Grid.Indices[J];
            if Seen[SI]=I+1 then Continue;Seen[SI]:=I+1;
            { Cached centerlines preserve widths, but not highway tags.
              >=6m selects substantial carriageways, excluding paths/lanes.
              Both bridge/tunnel approaches are explicitly rejected. }
            if Segs[SI].IsBridge or(Segs[SI].Width<6)then Continue;
            if(I<Length(RouteWays))and(Segs[SI].WayId=RouteWays[I])then Continue;
            Den:=D.X*Segs[SI].DZ-D.Z*Segs[SI].DX;
            SinAngle:=Abs(Den)*Segs[SI].LenInv/Len;
            if SinAngle<0.7071 then Continue;
            Q:=Vector3(Segs[SI].X0-A.X,0,Segs[SI].Z0-A.Z);
            T:=(Q.X*Segs[SI].DZ-Q.Z*Segs[SI].DX)/Den;
            U:=(Q.X*D.Z-Q.Z*D.X)/Den;
            if(T<0)or(T>1)or(U<0)or(U>1)then Continue;
            if Along+T*Len<MinSpacing then Continue;
            N:=Length(Candidates);
            if(N>0)and(Abs(Along+T*Len-Candidates[N-1].RouteDistance)<100)then Continue;
            V:=A+D*T;V.Y:=0;
            if not MakeRoute(SI,V,Cross)then Continue;
            Cross.RouteDistance:=Along+T*Len;Cross.RoutePoint:=I;
            SetLength(Candidates,N+1);Candidates[N]:=Cross;
          end;
        end;
      end;
      Along:=Along+Len;
    end;
  finally RouteBridge.Free end;
  { Select near a deterministic 3..10 km target, with a nearest valid
    junction fallback. An area without intersections creates no fake road. }
  Last:=0;I:=0;
  while I<Length(Candidates)do begin
    Target:=Last+MinSpacing+Frac(Abs(Sin((Length(Result)+1)*12.9898))*43758.5453)*(MaxSpacing-MinSpacing);
    Pick:=-1;BestError:=1e30;
    for K:=I to High(Candidates)do begin
      if Candidates[K].RouteDistance<Last+MinSpacing then Continue;
      if(Candidates[K].RouteDistance>Last+MaxSpacing)and(Pick>=0)then Break;
      if Abs(Candidates[K].RouteDistance-Target)<BestError then begin
        Pick:=K;BestError:=Abs(Candidates[K].RouteDistance-Target);
      end;
      if Candidates[K].RouteDistance>Last+MaxSpacing then Break;
    end;
    if Pick<0 then Break;
    N:=Length(Result);SetLength(Result,N+1);Result[N]:=Candidates[Pick];
    Last:=Candidates[Pick].RouteDistance;I:=Pick+1;
  end;
end;
