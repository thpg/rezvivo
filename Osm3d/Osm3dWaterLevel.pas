unit Osm3dWaterLevel;
{$mode objfpc}{$H+}

{ Build-time surface shared by terrain, overlays and final road leveling.
  No per-frame work, no second rendered water/shore mesh. }
interface
uses SysUtils, Math, Generics.Collections, Osm3dGeoMath, Osm3dOsmData,
  Osm3dHeightmap;
type
  TWaterLevelInts = array of Integer;
  TWaterLevelGrid = array of TWaterLevelInts;
  TWaterLevelEdge = record A,B: TScatterPoint; end;
  TWaterLevelRoad = record
    A,B: TScatterPoint;
    HalfWidth,Len: Single;
    FordA,FordB: Boolean;
  end;
  TWaterLevelAxis = record
    A,B: TScatterPoint;
    HA,HB,HalfWidth: Single;
  end;
  TWaterAxisNode = record
    MinX,MinZ,MaxX,MaxZ: Double;
    Left,Right,First,Count: Integer;
  end;
  TWaterLevelFeature = record
    Poly: TPolygonMultipolygon;
    Edges: array of TWaterLevelEdge;
    Rows: TWaterLevelGrid;
    Axes: TWaterLevelInts;
    AxisTree: array of TWaterAxisNode;
    MinX,MinZ,MaxX,MaxZ: Double;
    Level: Single;
    LinearAxis: Integer; { -1 = polygon }
    River: Boolean;
    MinorWater: Boolean;
  end;
  TWaterLevelField = class
  private
    FFeatures: array of TWaterLevelFeature;
    FAxes: array of TWaterLevelAxis;
    FGrid: TWaterLevelGrid;
    FRoadGrid: TWaterLevelGrid;
    FRoads: array of TWaterLevelRoad;
    FMinX,FMinZ,FMaxX,FMaxZ,FCell: Double;
    FCols,FRows,FLakes,FRivers,FSkipped: Integer;
    FProjection: TLocalProjection; { borrowed, immutable during the build }
    FHM: THeightmap; { borrowed only during construction }
    FFetcher: TTerrariumFetcher; { optional canonical DEM samples outside halo }
    FZoom: Integer;
    function SampleLocal(X,Z: Double; out H: Single): Boolean;
    function SampleLake(const P: TLatLon; out H: Single): Boolean;
    procedure IndexEdges(var F: TWaterLevelFeature);
    function PolygonAt(const F: TWaterLevelFeature; X,Z: Double;
      out Distance: Double): Boolean;
    function AxisHeight(const F: TWaterLevelFeature; X,Z: Double; out H: Single): Boolean;
    procedure IndexAxes(var F: TWaterLevelFeature);
    procedure FallbackAxes(var F: TWaterLevelFeature);
    procedure AddArea(const MP, SampleMP: TPolygonMultipolygon;
      SampleProjection: TLocalProjection; Tags: TOSMTags);
    procedure AddAxis(const A,B: TScatterPoint; Width: Single; MinorWater: Boolean);
    procedure BuildGrid;
    procedure BuildRoadProtection(Dataset: TOSMDataset);
  public
    constructor Create(HM: THeightmap; Dataset: TOSMDataset;
      Projection: TLocalProjection; HeightmapZoom: Integer;
      Fetcher: TTerrariumFetcher = nil; ProtectRoads: Boolean = True);
    function RoadProtectionAt(X,Z: Double): Single;
    function TargetAt(X,Z: Double; out Height,Weight: Single): Boolean;
    function Apply(X,Z: Double; NaturalHeight: Single): Single;
    function ApplyGeo(const P: TLatLon; NaturalHeight: Single): Single;
    function Stats: string;
    function Empty: Boolean;
  end;

implementation
uses CastleVectors, Osm3dGeomUtils, Osm3dGeomSurface, Osm3dGeomRoads;
const
  BANK_BLEND = 12.0;
  SHORE_PIN = 0.08; { carve snaps to 1/64 m, cache to millimetres }
  AXIS_STEP = 20.0;
  MAX_GRID_CELLS = 262144;
  ROAD_SHOULDER = 1.0;
  ROAD_WATER_BLEND = 4.0;
  FORD_RADIUS = 8.0;

procedure Push(var A: TWaterLevelInts; V: Integer);
var N: Integer;
begin N:=Length(A);SetLength(A,N+1);A[N]:=V;end;

function DistanceToSegment(X,Z:Double;const A,B:TScatterPoint;out T:Double):Double;
var DX,DZ,L:Double;
begin
  DX:=B.X-A.X;DZ:=B.Z-A.Z;L:=DX*DX+DZ*DZ;
  if L>1e-12 then T:=EnsureRange(((X-A.X)*DX+(Z-A.Z)*DZ)/L,0.0,1.0) else T:=0;
  Result:=Hypot(X-A.X-T*DX,Z-A.Z-T*DZ);
end;

function RunningWater(Tags:TOSMTags):Boolean;
var W:string;
begin
  W:=Tags.GetLower('water');
  Result:=(W='river') or (W='stream') or (W='canal') or
    (Tags.GetLower('waterway')='riverbank') or TWaterBuilder.MinorWaterway(Tags);
end;

function MarineWater(Tags:TOSMTags):Boolean;
var W,N,P:string;
begin
  W:=Tags.GetLower('water');N:=Tags.GetLower('natural');P:=Tags.GetLower('place');
  Result:=(W='sea') or (W='ocean') or (N='bay') or (N='strait') or
    (P='sea') or (P='ocean');
end;

function TWaterLevelField.SampleLocal(X,Z:Double;out H:Single):Boolean;
var P:TLatLon;WP,PX,PY,GX,GY,FX,FY:Double;IX,IY:Integer;
begin
  Result:=False;H:=0;
  P:=FProjection.Unproject(X,Z);
  { Use the same global pixel phase as TerrainGridOf, not bbox/(W-1).
    Sampling outside the loaded DEM is never clamped into a false plateau. }
  WP:=256.0*IntPower(2,FZoom);
  GX:=Round((FHM.Box.MinLon+180)/360*WP);
  GY:=Round((1-Ln(Tan(FHM.Box.MaxLat*Pi/180)+1/Cos(FHM.Box.MaxLat*Pi/180))/Pi)*0.5*WP);
  PX:=(P.Lon+180)/360*WP-GX;
  PY:=(1-Ln(Tan(P.Lat*Pi/180)+1/Cos(P.Lat*Pi/180))/Pi)*0.5*WP-GY;
  if (PX<0) or (PY<0) or (PX>FHM.Width-1) or (PY>FHM.Height-1) then Exit;
  IX:=Min(FHM.Width-2,Floor(PX));IY:=Min(FHM.Height-2,Floor(PY));
  FX:=PX-IX;FY:=PY-IY;
  H:=(1-FX)*(1-FY)*FHM[IX,IY]+FX*(1-FY)*FHM[IX+1,IY]+
    (1-FX)*FY*FHM[IX,IY+1]+FX*FY*FHM[IX+1,IY+1];
  Result:=not IsNan(H) and not IsInfinite(H);
end;

function TWaterLevelField.SampleLake(const P:TLatLon;out H:Single):Boolean;
var V:TVector3;
begin
  if FFetcher=nil then begin
    V:=FProjection.Project(P);Exit(SampleLocal(V.X,V.Z,H));
  end;
  { Canonical geo samples, exact zoom and cross-tile interpolation:
    neither this block's clipping nor the cache's highest zoom sets a lake. }
  Result:=FFetcher.TryHeightAtZoom(P,FZoom,H);
end;

procedure TWaterLevelField.IndexEdges(var F:TWaterLevelFeature);
var K:Integer;
  procedure Ring(const P:TPolygonRing);
  var I,J,N,R,R0,R1:Integer;
  begin
    J:=High(P);
    for I:=0 to High(P) do begin
      N:=Length(F.Edges);SetLength(F.Edges,N+1);F.Edges[N].A:=P[J];F.Edges[N].B:=P[I];
      R0:=Max(0,Floor((Min(P[J].Z,P[I].Z)-FMinZ-BANK_BLEND-SHORE_PIN)/FCell));
      R1:=Min(FRows-1,Floor((Max(P[J].Z,P[I].Z)-FMinZ+BANK_BLEND+SHORE_PIN)/FCell));
      for R:=R0 to R1 do Push(F.Rows[R],N);
      J:=I;
    end;
  end;
begin
  SetLength(F.Rows,FRows);Ring(F.Poly.Outer);
  for K:=0 to High(F.Poly.Inners) do Ring(F.Poly.Inners[K]);
end;

function TWaterLevelField.PolygonAt(const F:TWaterLevelFeature;X,Z:Double;
  out Distance:Double):Boolean;
var Row,K,I:Integer;A,B:TScatterPoint;D,T:Double;
begin
  Result:=False;Distance:=1e30;
  Row:=Floor((Z-FMinZ)/FCell);
  if (Row<0) or (Row>=Length(F.Rows)) then Exit;
  { Row bins retain every crossing of the ray, including remote edges.
    Even/odd over all rings preserves islands and concave shores. }
  for K:=0 to High(F.Rows[Row]) do begin
    I:=F.Rows[Row][K];A:=F.Edges[I].A;B:=F.Edges[I].B;
    if ((A.Z>Z)<>(B.Z>Z)) and (X<(B.X-A.X)*(Z-A.Z)/(B.Z-A.Z)+A.X) then Result:=not Result;
    if (X<Min(A.X,B.X)-BANK_BLEND-SHORE_PIN) or (X>Max(A.X,B.X)+BANK_BLEND+SHORE_PIN) then Continue;
    D:=DistanceToSegment(X,Z,A,B,T);Distance:=Min(Distance,D);
  end;
  if Distance<=SHORE_PIN then Result:=True;
end;

procedure TWaterLevelField.AddAxis(const A,B:TScatterPoint;Width:Single;MinorWater:Boolean);
var Axis:TWaterLevelAxis;F:TWaterLevelFeature;N:Integer;
begin
  if Hypot(B.X-A.X,B.Z-A.Z)<0.001 then Exit;
  if (Max(A.X,B.X)+Width*1.5+BANK_BLEND<FMinX) or
     (Min(A.X,B.X)-Width*1.5-BANK_BLEND>FMaxX) or
     (Max(A.Z,B.Z)+Width*1.5+BANK_BLEND<FMinZ) or
     (Min(A.Z,B.Z)-Width*1.5-BANK_BLEND>FMaxZ) then Exit;
  if not SampleLocal(A.X,A.Z,Axis.HA) or not SampleLocal(B.X,B.Z,Axis.HB) then Exit;
  Axis.A:=A;Axis.B:=B;Axis.HalfWidth:=Width*0.5;
  N:=Length(FAxes);SetLength(FAxes,N+1);FAxes[N]:=Axis;
  F:=Default(TWaterLevelFeature);F.LinearAxis:=N;F.River:=True;
  F.MinorWater:=MinorWater;
  F.MinX:=Min(A.X,B.X)-Width*1.5;F.MaxX:=Max(A.X,B.X)+Width*1.5;
  F.MinZ:=Min(A.Z,B.Z)-Width*1.5;F.MaxZ:=Max(A.Z,B.Z)+Width*1.5;
  N:=Length(FFeatures);SetLength(FFeatures,N+1);FFeatures[N]:=F;
end;

function TWaterLevelField.AxisHeight(const F:TWaterLevelFeature;X,Z:Double;out H:Single):Boolean;
var Best:Double;Found:Boolean;Value:Single;
  procedure Visit(N:Integer);
  var K,I:Integer;D,T,DX,DZ,DL,DR:Double;B:TWaterAxisNode;
    function BoxDistance(Index:Integer):Double;
    var AX,AZ:Double;
    begin
      AX:=Max(Max(F.AxisTree[Index].MinX-X,0),X-F.AxisTree[Index].MaxX);
      AZ:=Max(Max(F.AxisTree[Index].MinZ-Z,0),Z-F.AxisTree[Index].MaxZ);
      Result:=AX*AX+AZ*AZ;
    end;
  begin
    B:=F.AxisTree[N];
    DX:=Max(Max(B.MinX-X,0),X-B.MaxX);
    DZ:=Max(Max(B.MinZ-Z,0),Z-B.MaxZ);
    if DX*DX+DZ*DZ>Best*Best then Exit;
    if B.Count>0 then
      for K:=B.First to B.First+B.Count-1 do begin
        I:=F.Axes[K];D:=DistanceToSegment(X,Z,FAxes[I].A,FAxes[I].B,T);
        if D<Best then begin Best:=D;Value:=FAxes[I].HA+(FAxes[I].HB-FAxes[I].HA)*T;Found:=True;end;
      end
    else begin
      DL:=BoxDistance(B.Left);DR:=BoxDistance(B.Right);
      if DL<=DR then begin Visit(B.Left);Visit(B.Right);end
      else begin Visit(B.Right);Visit(B.Left);end;
    end;
  end;
begin
  Found:=False;Best:=1e30;Value:=0;
  if Length(F.AxisTree)>0 then Visit(0);
  Result:=Found;H:=Value;
end;

procedure TWaterLevelField.IndexAxes(var F:TWaterLevelFeature);
  function Mid(I:Integer;AlongX:Boolean):Double;
  begin
    if AlongX then Result:=FAxes[I].A.X+FAxes[I].B.X
    else Result:=FAxes[I].A.Z+FAxes[I].B.Z;
  end;
  procedure Sort(L,R:Integer;AlongX:Boolean);
  var I,J,T:Integer;P:Double;
  begin
    I:=L;J:=R;P:=Mid(F.Axes[(L+R) div 2],AlongX);
    repeat
      while Mid(F.Axes[I],AlongX)<P do Inc(I);
      while Mid(F.Axes[J],AlongX)>P do Dec(J);
      if I<=J then begin T:=F.Axes[I];F.Axes[I]:=F.Axes[J];F.Axes[J]:=T;Inc(I);Dec(J);end;
    until I>J;
    if L<J then Sort(L,J,AlongX);
    if I<R then Sort(I,R,AlongX);
  end;
  function Build(L,R:Integer):Integer;
  var B:TWaterAxisNode;A:TWaterLevelAxis;I,N,M:Integer;
  begin
    N:=Length(F.AxisTree);SetLength(F.AxisTree,N+1);
    B:=Default(TWaterAxisNode);B.MinX:=1e30;B.MinZ:=1e30;B.MaxX:=-1e30;B.MaxZ:=-1e30;
    for I:=L to R do begin
      A:=FAxes[F.Axes[I]];
      B.MinX:=Min(B.MinX,Min(A.A.X,A.B.X));B.MaxX:=Max(B.MaxX,Max(A.A.X,A.B.X));
      B.MinZ:=Min(B.MinZ,Min(A.A.Z,A.B.Z));B.MaxZ:=Max(B.MaxZ,Max(A.A.Z,A.B.Z));
    end;
    if R-L<8 then begin B.First:=L;B.Count:=R-L+1;end
    else begin
      Sort(L,R,B.MaxX-B.MinX>B.MaxZ-B.MinZ);M:=(L+R) div 2;
      B.Left:=Build(L,M);B.Right:=Build(M+1,R);
    end;
    F.AxisTree[N]:=B;Result:=N;
  end;
begin
  if Length(F.Axes)>0 then Build(0,High(F.Axes));
end;

procedure TWaterLevelField.FallbackAxes(var F:TWaterLevelFeature);
type TSection=record A:TScatterPoint;Lo,Hi:Double;H:Single;end;
var Prev,Curr:array of TSection;Cuts:array of Double;
    I,J,K,N,Step,FirstStep,LastStep,Best:Integer;
    CX,CZ,XX,XZ,ZZ,DX,DZ,Angle,S,S0,S1,SA,SB,T,Q,Dist,BestD,Lo,Hi:Double;
    A,B:TScatterPoint;Axis:TWaterLevelAxis;Sec:TSection;
begin
  { Missing OSM centre line: slice the actual polygon along its major
    direction. Pair intersections (including holes), sample each section's
    centre, connect neighbouring overlapping sections. Never one lake level. }
  CX:=(F.MinX+F.MaxX)*0.5;CZ:=(F.MinZ+F.MaxZ)*0.5;
  XX:=0;XZ:=0;ZZ:=0;
  for I:=0 to High(F.Poly.Outer) do begin
    DX:=F.Poly.Outer[I].X-CX;DZ:=F.Poly.Outer[I].Z-CZ;
    XX:=XX+DX*DX;XZ:=XZ+DX*DZ;ZZ:=ZZ+DZ*DZ;
  end;
  Angle:=0.5*ArcTan2(2*XZ,XX-ZZ);DX:=Cos(Angle);DZ:=Sin(Angle);
  S0:=1e30;S1:=-1e30;
  for I:=0 to High(F.Poly.Outer) do begin
    S:=(F.Poly.Outer[I].X-CX)*DX+(F.Poly.Outer[I].Z-CZ)*DZ;
    S0:=Min(S0,S);S1:=Max(S1,S);
  end;
  if S1-S0<0.02 then Exit;
  { Limit slicing to the loaded halo even for very long source polygons. }
  Lo:=1e30;Hi:=-1e30;
  for I:=0 to 3 do begin
    if I and 1=0 then A.X:=FMinX else A.X:=FMaxX;
    if I and 2=0 then A.Z:=FMinZ else A.Z:=FMaxZ;
    S:=(A.X-CX)*DX+(A.Z-CZ)*DZ;Lo:=Min(Lo,S);Hi:=Max(Hi,S);
  end;
  FirstStep:=Floor(Max(S0,Lo)/AXIS_STEP);LastStep:=Ceil(Min(S1,Hi)/AXIS_STEP);
  SetLength(Cuts,Length(F.Edges));Prev:=nil;
  for Step:=FirstStep to LastStep do begin
    S:=EnsureRange(Step*AXIS_STEP,S0+0.01,S1-0.01);N:=0;
    for I:=0 to High(F.Edges) do begin
      A:=F.Edges[I].A;B:=F.Edges[I].B;
      SA:=(A.X-CX)*DX+(A.Z-CZ)*DZ;SB:=(B.X-CX)*DX+(B.Z-CZ)*DZ;
      if (SA>S)=(SB>S) then Continue;
      T:=(S-SA)/(SB-SA);
      Q:=-(A.X+(B.X-A.X)*T-CX)*DZ+(A.Z+(B.Z-A.Z)*T-CZ)*DX;
      J:=N-1;
      while (J>=0) and (Cuts[J]>Q) do begin Cuts[J+1]:=Cuts[J];Dec(J);end;
      Cuts[J+1]:=Q;Inc(N);
    end;
    Curr:=nil;
    for I:=0 to (N div 2)-1 do begin
      Sec.Lo:=Cuts[I*2];Sec.Hi:=Cuts[I*2+1];Q:=(Sec.Lo+Sec.Hi)*0.5;
      Sec.A.X:=CX+S*DX-Q*DZ;Sec.A.Z:=CZ+S*DZ+Q*DX;
      if not SampleLocal(Sec.A.X,Sec.A.Z,Sec.H) then Continue;
      Best:=-1;BestD:=1e30;
      for J:=0 to High(Prev) do begin
        if (Prev[J].Hi<Sec.Lo) or (Prev[J].Lo>Sec.Hi) then Continue;
        Dist:=Hypot(Sec.A.X-Prev[J].A.X,Sec.A.Z-Prev[J].A.Z);
        if Dist<BestD then begin BestD:=Dist;Best:=J;end;
      end;
      if Best>=0 then begin
        Axis.A:=Prev[Best].A;Axis.B:=Sec.A;Axis.HA:=Prev[Best].H;Axis.HB:=Sec.H;
        Axis.HalfWidth:=0;
        K:=Length(FAxes);SetLength(FAxes,K+1);FAxes[K]:=Axis;Push(F.Axes,K);
      end;
      K:=Length(Curr);SetLength(Curr,K+1);Curr[K]:=Sec;
    end;
    Prev:=Curr;
  end;
end;

procedure TWaterLevelField.AddArea(const MP,SampleMP:TPolygonMultipolygon;
  SampleProjection:TLocalProjection;Tags:TOSMTags);
var F:TWaterLevelFeature;I,J,K,N,NS:Integer;D,X,Z,CX,CZ,H,Temp:Double;
    SX0,SX1,SZ0,SZ1:Double;
    SampleH:Single;Samples:array[0..24]of Double;
    Cuts:array of Double;CutCount:Integer;Unavailable:Boolean;
  procedure Crossings(const Ring:TPolygonRing;AZ:Double);
  var A,B:TScatterPoint;I,J,K:Integer;AX:Double;
  begin
    J:=High(Ring);
    for I:=0 to High(Ring) do begin
      A:=Ring[J];B:=Ring[I];J:=I;
      if (A.Z>AZ)=(B.Z>AZ) then Continue;
      AX:=A.X+(B.X-A.X)*(AZ-A.Z)/(B.Z-A.Z);
      K:=CutCount-1;
      while (K>=0) and (Cuts[K]>AX) do begin Cuts[K+1]:=Cuts[K];Dec(K);end;
      Cuts[K+1]:=AX;Inc(CutCount);
    end;
  end;
  procedure TrySample(AX,AZ:Double);
  var Hole:Integer;
  begin
    if Unavailable or (NS=Length(Samples)) then Exit;
    if not PointInRingXZ(AX,AZ,SampleMP.Outer) then Exit;
    for Hole:=0 to High(SampleMP.Inners) do
      if PointInRingXZ(AX,AZ,SampleMP.Inners[Hole]) then Exit;
    if SampleLake(SampleProjection.Unproject(AX,AZ),SampleH) then begin Samples[NS]:=SampleH;Inc(NS);end
    else Unavailable:=True;
  end;
begin
  if Length(MP.Outer)<3 then Exit;
  F:=Default(TWaterLevelFeature);F.Poly:=MP;F.LinearAxis:=-1;F.River:=RunningWater(Tags);
  F.MinorWater:=TWaterBuilder.MinorWaterway(Tags);
  F.MinX:=MP.Outer[0].X;F.MaxX:=F.MinX;F.MinZ:=MP.Outer[0].Z;F.MaxZ:=F.MinZ;
  for I:=1 to High(MP.Outer) do begin
    F.MinX:=Min(F.MinX,MP.Outer[I].X);F.MaxX:=Max(F.MaxX,MP.Outer[I].X);
    F.MinZ:=Min(F.MinZ,MP.Outer[I].Z);F.MaxZ:=Max(F.MaxZ,MP.Outer[I].Z);
  end;
  if (F.MaxX+BANK_BLEND<FMinX) or (F.MinX-BANK_BLEND>FMaxX) or
     (F.MaxZ+BANK_BLEND<FMinZ) or (F.MinZ-BANK_BLEND>FMaxZ) then Exit;
  IndexEdges(F);
  if F.River then begin
    { Prefer the actual meandering OSM axis. Never average river height
      over its length, nor impose a slope cap on mountain streams. }
    for I:=0 to High(FAxes) do begin
      X:=(FAxes[I].A.X+FAxes[I].B.X)*0.5;Z:=(FAxes[I].A.Z+FAxes[I].B.Z)*0.5;
      if (X<F.MinX) or (X>F.MaxX) or (Z<F.MinZ) or (Z>F.MaxZ) then Continue;
      if PolygonAt(F,X,Z,D) then Push(F.Axes,I);
    end;
    if Length(F.Axes)=0 then FallbackAxes(F);
    if Length(F.Axes)=0 then begin Inc(FSkipped);Exit;end;
    IndexAxes(F);
    Inc(FRivers);
  end else if MarineWater(Tags) then begin F.Level:=0;Inc(FLakes);end
  else begin
    if Length(SampleMP.Outer)<3 then Exit;
    SX0:=SampleMP.Outer[0].X;SX1:=SX0;SZ0:=SampleMP.Outer[0].Z;SZ1:=SZ0;
    for I:=1 to High(SampleMP.Outer) do begin
      SX0:=Min(SX0,SampleMP.Outer[I].X);SX1:=Max(SX1,SampleMP.Outer[I].X);
      SZ0:=Min(SZ0,SampleMP.Outer[I].Z);SZ1:=Max(SZ1,SampleMP.Outer[I].Z);
    end;
    NS:=0;Unavailable:=False;CX:=(SX0+SX1)*0.5;CZ:=(SZ0+SZ1)*0.5;
    TrySample(CX,CZ);
    { A large body uses several interior samples; median rejects a bad DEM
      pixel. No samples from the shoreline or from island holes. }
    if (Max(SX1-SX0,SZ1-SZ0)>500) or (NS=0) then
      for J:=0 to 4 do for I:=0 to 4 do
        if (I<>2) or (J<>2) then
          TrySample(SX0+(SX1-SX0)*(I+0.5)/5,SZ0+(SZ1-SZ0)*(J+0.5)/5);
    if (NS=0) or ((NS<3) and (Max(SX1-SX0,SZ1-SZ0)>500)) then begin
      { Concave/narrow ponds: actual interior intervals, including holes
        and the closing edge. A bbox-centre heuristic misses thin C shapes. }
      N:=Length(SampleMP.Outer);
      for I:=0 to High(SampleMP.Inners) do Inc(N,Length(SampleMP.Inners[I]));
      SetLength(Cuts,N);
      for K:=0 to 15 do begin
        Z:=SZ0+(SZ1-SZ0)*(K+0.5)/16;
        CutCount:=0;Crossings(SampleMP.Outer,Z);
        for I:=0 to High(SampleMP.Inners) do Crossings(SampleMP.Inners[I],Z);
        for I:=0 to CutCount div 2-1 do TrySample((Cuts[I*2]+Cuts[I*2+1])*0.5,Z);
        if (NS>0) and (Max(SX1-SX0,SZ1-SZ0)<=500) then Break;
      end;
    end;
    { A partial set would make the lake depend on which remote source tile
      happened to load. Keep the original terrain when any sample failed. }
    if Unavailable or (NS=0) then begin Inc(FSkipped);Exit;end;
    for I:=1 to NS-1 do begin Temp:=Samples[I];J:=I-1;
      while (J>=0) and (Samples[J]>Temp) do begin Samples[J+1]:=Samples[J];Dec(J);end;
      Samples[J+1]:=Temp;
    end;
    H:=(Samples[(NS-1) div 2]+Samples[NS div 2])*0.5;
    F.Level:=Round(H*64)/64;Inc(FLakes);
  end;
  N:=Length(FFeatures);SetLength(FFeatures,N+1);FFeatures[N]:=F;
end;

procedure TWaterLevelField.BuildRoadProtection(Dataset: TOSMDataset);
var Way:TOSMWay;A,B:TOSMNode;Params:TRoadParams;P:TVector3;
    Road:TWaterLevelRoad;I,N,X,Z,X0,X1,Z0,Z1:Integer;R:Double;
  function Ford(Tags:TOSMTags):Boolean;
  var V:string;
  begin
    V:=Tags.GetLower('ford');
    Result:=((V<>'') and (V<>'no') and (V<>'false') and (V<>'0'))
      or (Tags.GetLower('highway')='ford');
  end;
begin
  if Length(FGrid)=0 then Exit;
  N:=0;
  for I:=0 to High(FFeatures) do if FFeatures[I].MinorWater then Inc(N);
  if N=0 then Exit;
  SetLength(FRoadGrid,Length(FGrid));N:=0;
  for Way in Dataset.Ways.Values do begin
    if OsmWayIsBridge(Way.Tags) or OsmWayIsTunnel(Way.Tags) or
       Ford(Way.Tags) or (Way.Tags.GetLower('area')='yes') then Continue;
    Params:=TRoadBuilder.ParseRoadParams(Way.Tags);
    if (Params.Kind=rkNone) or (Params.Kind=rkRailway) then Continue;
    Road.HalfWidth:=Params.Width*0.5;
    R:=Road.HalfWidth+ROAD_SHOULDER+ROAD_WATER_BLEND;
    for I:=1 to High(Way.NodeRefs) do begin
      A:=Dataset.FindNode(Way.NodeRefs[I-1]);B:=Dataset.FindNode(Way.NodeRefs[I]);
      if (A=nil) or (B=nil) then Continue;
      P:=NodePlanePos(Dataset,A,FProjection);Road.A.X:=P.X;Road.A.Z:=P.Z;
      P:=NodePlanePos(Dataset,B,FProjection);Road.B.X:=P.X;Road.B.Z:=P.Z;
      Road.Len:=Hypot(Road.B.X-Road.A.X,Road.B.Z-Road.A.Z);
      if (Road.Len<0.001) or (Sqr(Road.Len)>ROAD_RUNAWAY_SEG_M2) then Continue;
      X0:=Max(0,Floor((Min(Road.A.X,Road.B.X)-R-FMinX)/FCell));
      X1:=Min(FCols-1,Floor((Max(Road.A.X,Road.B.X)+R-FMinX)/FCell));
      Z0:=Max(0,Floor((Min(Road.A.Z,Road.B.Z)-R-FMinZ)/FCell));
      Z1:=Min(FRows-1,Floor((Max(Road.A.Z,Road.B.Z)+R-FMinZ)/FCell));
      if (X0>X1) or (Z0>Z1) then Continue;
      Road.FordA:=Ford(A.Tags);Road.FordB:=Ford(B.Tags);
      if N=Length(FRoads) then SetLength(FRoads,Max(64,N*2));
      FRoads[N]:=Road;
      { Only water cells need road candidates; immutable after construction. }
      for Z:=Z0 to Z1 do for X:=X0 to X1 do
        if Length(FGrid[Z*FCols+X])>0 then Push(FRoadGrid[Z*FCols+X],N);
      Inc(N);
    end;
  end;
  SetLength(FRoads,N);
end;

function TWaterLevelField.RoadProtectionAt(X,Z:Double):Single;
var CX,CZ,K:Integer;Road:^TWaterLevelRoad;D,T,W,FordD,F:Double;
begin
  Result:=0;
  if Length(FRoadGrid)=0 then Exit;
  CX:=Floor((X-FMinX)/FCell);CZ:=Floor((Z-FMinZ)/FCell);
  if (CX<0) or (CZ<0) or (CX>=FCols) or (CZ>=FRows) then Exit;
  for K:=0 to High(FRoadGrid[CZ*FCols+CX]) do begin
    Road:=@FRoads[FRoadGrid[CZ*FCols+CX][K]];
    D:=DistanceToSegment(X,Z,Road^.A,Road^.B,T)-Road^.HalfWidth-ROAD_SHOULDER;
    if D>=ROAD_WATER_BLEND then Continue;
    if D<=0 then W:=1 else begin F:=D/ROAD_WATER_BLEND;W:=1-F*F*(3-2*F);end;
    { A node-tagged ford opens only its crossing, not the entire OSM way. }
    FordD:=1e30;
    if Road^.FordA then FordD:=T*Road^.Len;
    if Road^.FordB then FordD:=Min(FordD,(1-T)*Road^.Len);
    if FordD<FORD_RADIUS+ROAD_WATER_BLEND then begin
      F:=EnsureRange((FordD-FORD_RADIUS)/ROAD_WATER_BLEND,0.0,1.0);
      W:=W*F*F*(3-2*F);
    end;
    Result:=Max(Result,W);
    if Result>=1 then Exit;
  end;
end;

procedure TWaterLevelField.BuildGrid;
var I,X,Z,X0,X1,Z0,Z1:Integer;
begin
  if Length(FFeatures)=0 then Exit;
  SetLength(FGrid,FCols*FRows);
  for I:=0 to High(FFeatures) do with FFeatures[I] do begin
    X0:=Max(0,Floor((MinX-BANK_BLEND-FMinX)/FCell));X1:=Min(FCols-1,Floor((MaxX+BANK_BLEND-FMinX)/FCell));
    Z0:=Max(0,Floor((MinZ-BANK_BLEND-FMinZ)/FCell));Z1:=Min(FRows-1,Floor((MaxZ+BANK_BLEND-FMinZ)/FCell));
    for Z:=Z0 to Z1 do for X:=X0 to X1 do Push(FGrid[Z*FCols+X],I);
  end;
end;

constructor TWaterLevelField.Create(HM:THeightmap;Dataset:TOSMDataset;
  Projection:TLocalProjection;HeightmapZoom:Integer;Fetcher:TTerrariumFetcher;
  ProtectRoads:Boolean);
var W:TOSMWay;Rel:TOSMRelation;N0,N1:TOSMNode;P:TVector3;
    A,B,U,V:TScatterPoint;I,J,N:Integer;Polys,SamplePolys:TMultipolygonArray;
    SampleProjection:TLocalProjection;Anchor:TLatLon;AnchorId:Int64;
    Used:specialize TDictionary<Int64,Boolean>;Waterway:string;L,T0,T1:Double;
  procedure IncludeWay(Way:TOSMWay);
  var K:Integer;Node:TOSMNode;
  begin
    if Way=nil then Exit;
    for K:=0 to High(Way.NodeRefs) do
      if Way.NodeRefs[K]<AnchorId then begin
        Node:=Dataset.FindNode(Way.NodeRefs[K]);
        if Node<>nil then begin AnchorId:=Node.Id;Anchor:=Node.Position;end;
      end;
  end;
begin
  inherited Create;
  FHM:=HM;FProjection:=Projection;FFetcher:=Fetcher;FZoom:=HeightmapZoom;
  if (HM=nil) or (Dataset=nil) or (Projection=nil) or (HM.Width<2) or (HM.Height<2) then Exit;
  P:=Projection.Project(TLatLon.Make(HM.Box.MinLat,HM.Box.MaxLon));FMinX:=P.X-32;FMinZ:=P.Z-32;
  P:=Projection.Project(TLatLon.Make(HM.Box.MaxLat,HM.Box.MinLon));FMaxX:=P.X+32;FMaxZ:=P.Z+32;
  FCell:=64;
  repeat
    FCols:=Max(1,Ceil((FMaxX-FMinX)/FCell));FRows:=Max(1,Ceil((FMaxZ-FMinZ)/FCell));
    if Int64(FCols)*FRows<=MAX_GRID_CELLS then Break;
    FCell:=FCell*2;
  until False;
  for W in Dataset.Ways.Values do begin
    Waterway:=W.Tags.GetLower('waterway');
    if not ((Waterway='river') or (Waterway='stream') or (Waterway='canal') or
      (Waterway='drain') or (Waterway='ditch')) then Continue;
    if W.IsClosed or (W.Tags.GetLower('area')='yes') or
       TWaterBuilder.Underground(W.Tags) then Continue;
    for I:=1 to High(W.NodeRefs) do begin
      N0:=Dataset.FindNode(W.NodeRefs[I-1]);N1:=Dataset.FindNode(W.NodeRefs[I]);
      if (N0=nil) or (N1=nil) then Continue;
      P:=Projection.Project(N0.Position);A.X:=P.X;A.Z:=P.Z;
      P:=Projection.Project(N1.Position);B.X:=P.X;B.Z:=P.Z;
      if (Max(A.X,B.X)<FMinX-256) or (Min(A.X,B.X)>FMaxX+256) or
         (Max(A.Z,B.Z)<FMinZ-256) or (Min(A.Z,B.Z)>FMaxZ+256) then Continue;
      L:=Hypot(B.X-A.X,B.Z-A.Z);N:=Max(1,Ceil(L/AXIS_STEP));
      { Bound source work even if an OSM response contains a remote, long way. }
      if N>100000 then Continue;
      for J:=0 to N-1 do begin
        T0:=J/N;T1:=(J+1)/N;
        U.X:=A.X+(B.X-A.X)*T0;U.Z:=A.Z+(B.Z-A.Z)*T0;
        V.X:=A.X+(B.X-A.X)*T1;V.Z:=A.Z+(B.Z-A.Z)*T1;
        AddAxis(U,V,TWaterBuilder.ClassifyWidth(W.Tags),TWaterBuilder.MinorWaterway(W.Tags));
      end;
    end;
  end;
  Used:=specialize TDictionary<Int64,Boolean>.Create;
  try
    for Rel in Dataset.Relations.Values do
      if (TLanduseBuilder.ClassifyTags(Rel.Tags)=lkWater) or (Rel.Tags.GetLower('waterway')='riverbank') then begin
        Polys:=BuildMultipolygonsFromRelation(Rel,Dataset,Projection);
        AnchorId:=High(Int64);Anchor:=Projection.Origin;
        for I:=0 to High(Rel.Members) do if Rel.Members[I].Kind=omkWay then
          IncludeWay(Dataset.FindWay(Rel.Members[I].Ref));
        SampleProjection:=TLocalProjection.Create(Anchor);
        try
          { The sample frame depends on the full OSM object, never on this
            block's origin, clipping or latitude band. }
          SamplePolys:=BuildMultipolygonsFromRelation(Rel,Dataset,SampleProjection);
          for I:=0 to Min(High(Polys),High(SamplePolys)) do
            AddArea(Polys[I],SamplePolys[I],SampleProjection,Rel.Tags);
        finally SampleProjection.Free;end;
        if Length(Polys)>0 then
          for I:=0 to High(Rel.Members) do if Rel.Members[I].Kind=omkWay then Used.AddOrSetValue(Rel.Members[I].Ref,True);
      end;
    for W in Dataset.Ways.Values do if W.IsClosed and not Used.ContainsKey(W.Id) and
      ((TLanduseBuilder.ClassifyTags(W.Tags)=lkWater) or (W.Tags.GetLower('waterway')='riverbank')) then begin
        AnchorId:=High(Int64);Anchor:=Projection.Origin;IncludeWay(W);
        SampleProjection:=TLocalProjection.Create(Anchor);
        try
          AddArea(BuildMultipolygonFromWay(W,Dataset,Projection),
            BuildMultipolygonFromWay(W,Dataset,SampleProjection),SampleProjection,W.Tags);
        finally SampleProjection.Free;end;
      end;
  finally Used.Free;end;
  BuildGrid;
  if ProtectRoads then BuildRoadProtection(Dataset);
  { Runtime membership uses indexed edges, not another copy of the rings. }
  for I:=0 to High(FFeatures) do begin
    FFeatures[I].Poly.Outer:=nil;FFeatures[I].Poly.Inners:=nil;
  end;
  FHM:=nil;FFetcher:=nil; { all runtime queries below are immutable and local }
end;

function TWaterLevelField.TargetAt(X,Z:Double;out Height,Weight:Single):Boolean;
var CX,CZ,K,I,BestKind,Kind:Integer;F:^TWaterLevelFeature;A:^TWaterLevelAxis;
    Inside:Boolean;D,T,W,BestD,RankD:Double;H,RoadWeight:Single;
begin
  Height:=0;Weight:=0;Result:=False;
  if Length(FGrid)=0 then Exit;
  CX:=Floor((X-FMinX)/FCell);CZ:=Floor((Z-FMinZ)/FCell);
  if (CX<0) or (CZ<0) or (CX>=FCols) or (CZ>=FRows) then Exit;
  BestKind:=-1;BestD:=1e30;
  RoadWeight:=-1;
  for K:=0 to High(FGrid[CZ*FCols+CX]) do begin
    I:=FGrid[CZ*FCols+CX][K];F:=@FFeatures[I];
    if (X<F^.MinX-BANK_BLEND) or (X>F^.MaxX+BANK_BLEND) or
       (Z<F^.MinZ-BANK_BLEND) or (Z>F^.MaxZ+BANK_BLEND) then Continue;
    if F^.LinearAxis>=0 then begin
      A:=@FAxes[F^.LinearAxis];D:=DistanceToSegment(X,Z,A^.A,A^.B,T);
      RankD:=D;
      H:=A^.HA+(A^.HB-A^.HA)*T;D:=Max(0,D-A^.HalfWidth);Kind:=0;
    end else begin
      Inside:=PolygonAt(F^,X,Z,D);
      if Inside then D:=0;
      if D>BANK_BLEND then Continue;
      if F^.River then begin if not AxisHeight(F^,X,Z,H) then Continue;Kind:=1;end
      else begin H:=F^.Level;Kind:=2;end;
      RankD:=D;
    end;
    if D>BANK_BLEND then Continue;
    { Water interior beats another body's bank blend. For line spans use
      distance to the axis, not clamped distance to the ribbon: otherwise
      every covered span averages the longitudinal profile into steps. }
    if D=0 then Inc(Kind,4);
    if D=0 then W:=1 else begin T:=D/BANK_BLEND;W:=1-T*T*(3-2*T);end;
    { Streams may pass under an ordinary road even without a mapped culvert.
      Keep its full width and blend back to the stream beyond the shoulder.
      Lakes and rivers retain their existing level priority. }
    if F^.MinorWater then begin
      if RoadWeight<0 then RoadWeight:=RoadProtectionAt(X,Z);
      W:=W*(1-RoadWeight);
      if W<=0 then Continue;
    end;
    { Actual area contours win over schematic waterway ribbons. On shores,
      nearest body wins; overlapping feather bands must not tilt lake water. }
    if (Kind<BestKind) or ((Kind=BestKind) and (RankD>=BestD)) then Continue;
    BestKind:=Kind;BestD:=RankD;Weight:=W;Height:=H;Result:=True;
  end;
end;

function TWaterLevelField.Apply(X,Z:Double;NaturalHeight:Single):Single;
var H,W:Single;
begin Result:=NaturalHeight;if TargetAt(X,Z,H,W) then Result:=NaturalHeight+(H-NaturalHeight)*W;end;
function TWaterLevelField.ApplyGeo(const P:TLatLon;NaturalHeight:Single):Single;
var V:TVector3;
begin
  Result:=NaturalHeight;if Empty then Exit;
  V:=FProjection.Project(P);Result:=Apply(V.X,V.Z,NaturalHeight);
end;
function TWaterLevelField.Stats:string;
begin Result:=Format('water levels: %d still areas, %d river areas, %d axis spans, %d unavailable',[FLakes,FRivers,Length(FAxes),FSkipped]);end;
function TWaterLevelField.Empty:Boolean;
begin Result:=Length(FFeatures)=0;end;
end.
