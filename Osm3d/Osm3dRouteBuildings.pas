unit Osm3dRouteBuildings;
{$mode objfpc}{$H+}
interface
uses SysUtils, Math, CastleVectors, Osm3dGeoMath, Osm3dMapUtils,
  Osm3dBuildingObstacleIndex, Osm3dDetourTypes;

const
  ROUTE_CLOSE_DISTANCE_M = 100.0;

{ Nearby endpoints may close a lap. Distant endpoints must return along
  the recorded route instead of inventing a cross-country closing edge. }
function RouteNeedsTurnarounds(const Centers: TRouteLatLonArray): Boolean;

{ Derived riding polyline. Original FIT points and 1:1 snap diagnostics stay
  intact. Open routes are prepared once, then mirrored without duplicating
  either endpoint. Their turnaround indices are 0 and Length(Ride) div 2.
  Only the preparation worker calls this, never the riding loop. }
procedure PrepareBuildingSafeRoute(const Centers: TRouteLatLonArray;
  const Widths: TRouteWidthArray; Projection: TLocalProjection;
  Obstacles: TBuildingObstacleIndex; out Ride: TRouteLatLonArray;
  out RideWidths: TRouteWidthArray; out Detours: Integer);

implementation

function RouteNeedsTurnarounds(const Centers: TRouteLatLonArray): Boolean;
begin
  Result := (Length(Centers) >= 2) and
    (Centers[0].DistanceTo(Centers[High(Centers)]) > ROUTE_CLOSE_DISTANCE_M);
end;

procedure PrepareBuildingSafeRoute(const Centers: TRouteLatLonArray;
  const Widths: TRouteWidthArray; Projection: TLocalProjection;
  Obstacles: TBuildingObstacleIndex; out Ride: TRouteLatLonArray;
  out RideWidths: TRouteWidthArray; out Detours: Integer);
var
  I,J,K,N,Count,Steps,WorkCount,LastEdge,LastTarget: Integer;
  OutAndBack: Boolean;
  Work: TRouteLatLonArray; WorkWidths: TRouteWidthArray;
  C,D: TVector3;
  A,B: TVector3;
  BaseY,MaxY,W: Single;
  Points: TDetourPoints;
  Status: TDetourResult;

  procedure Append(const P: TVector3; Width: Single);
  var Previous: TVector3;
  begin
    { Stationary FIT samples must not hide an endpoint behind empty edges. }
    if OutAndBack and (Count>0) then
    begin
      Previous:=Projection.Project(Ride[Count-1]);
      if (P-Previous).Length<0.001 then
      begin
        RideWidths[Count-1]:=Min(RideWidths[Count-1],Width);
        Exit;
      end;
    end;
    if Count=Length(Ride) then
    begin
      SetLength(Ride,Max(64,Count*2)); SetLength(RideWidths,Length(Ride));
    end;
    Ride[Count]:=Projection.Unproject(P.X,P.Z);
    RideWidths[Count]:=Width; Inc(Count);
  end;

  function WidthAt(Index: Integer): Single;
  begin
    if Index<Length(WorkWidths) then Result:=WorkWidths[Index] else Result:=0;
  end;


begin
  Ride:=nil; RideWidths:=nil; Count:=0; Detours:=0; N:=Length(Centers);
  if N<2 then Exit;
  OutAndBack:=RouteNeedsTurnarounds(Centers);
  { Bound each local search even for sparse GPX tracks. A closing edge is
    allowed only for nearby endpoints, never for the out-and-back route. }
  Work:=nil; WorkWidths:=nil; WorkCount:=0;
  LastEdge:=N-1;
  if OutAndBack then Dec(LastEdge);
  for I:=0 to LastEdge do
  begin
    C:=Projection.Project(Centers[I]); D:=Projection.Project(Centers[(I+1) mod N]);
    Steps:=Max(1,Ceil((D-C).Length/80));
    if WorkCount+Steps>Length(Work) then
    begin
      SetLength(Work,Max(WorkCount+Steps,Max(64,Length(Work)*2)));
      SetLength(WorkWidths,Length(Work));
    end;
    for J:=0 to Steps-1 do
    begin
      A:=C+(D-C)*(J/Steps); Work[WorkCount]:=Projection.Unproject(A.X,A.Z);
      if I<Length(Widths) then WorkWidths[WorkCount]:=Widths[I] else WorkWidths[WorkCount]:=0;
      Inc(WorkCount);
    end;
  end;
  if OutAndBack then
  begin
    SetLength(Work,WorkCount+1); SetLength(WorkWidths,WorkCount+1);
    Work[WorkCount]:=Centers[N-1];
    if N<=Length(Widths) then WorkWidths[WorkCount]:=Widths[N-1];
    Inc(WorkCount);
  end;
  N:=WorkCount;
  LastTarget:=N;
  if OutAndBack then Dec(LastTarget);
  A:=Projection.Project(Work[0]); W:=WidthAt(0);
  if Obstacles.TryPushOutXZ(A.X,A.Z,BaseY,MaxY,BUILDING_ROUTE_CLEARANCE_M) then W:=0;
  Append(A,W); I:=1;
  while I<=LastTarget do
  begin
    J:=I;
    repeat
      { N is visited only for a nearby closing endpoint. }
      B:=Projection.Project(Work[J mod N]);
      if J=N then B:=Projection.Project(Ride[0]);
      if OutAndBack and (J=LastTarget) then
        if Obstacles.TryPushOutXZ(B.X,B.Z,BaseY,MaxY,BUILDING_ROUTE_CLEARANCE_M) then WorkWidths[J]:=0;
      Status:=Obstacles.FindDetour(A,B,Points);
      if (Status<>drTargetBlocked) or (J=LastTarget) then Break;
      Inc(J);
    until False;
    if Status=drFound then
    begin
      RideWidths[Count-1]:=0;
      for K:=0 to High(Points) do Append(Points[K],0);
      Inc(Detours);
    end
    else if Status=drClear then Append(B,WidthAt(J mod N))
    else
      raise Exception.CreateFmt('Building-safe route: cannot connect points %d..%d at (%.1f, %.1f)',
        [I-1,J,A.X,A.Z]);
    A:=B; I:=J+1;
  end;
  if OutAndBack then
  begin
    { Return over the very same safe segments, including building detours.
      No second obstacle search, no far-end -> start connection. }
    N:=Count;
    if N<2 then raise Exception.Create('Building-safe route: no traversable segments');
    SetLength(Ride,2*N-2); SetLength(RideWidths,2*N-2);
    RideWidths[0]:=0; RideWidths[N-1]:=0; { approach turnarounds on the centerline }
    for I:=1 to N-2 do
    begin
      Ride[N-1+I]:=Ride[N-1-I];
      RideWidths[N-1+I]:=RideWidths[N-1-I];
    end;
    Count:=2*N-2;
  end
  else
    { Closing point equals the first one; GamePath closes the lap itself. }
    if Count>1 then Dec(Count);
  SetLength(Ride,Count); SetLength(RideWidths,Count);
end;
end.
