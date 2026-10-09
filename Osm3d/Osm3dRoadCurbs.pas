unit Osm3dRoadCurbs;

{$mode objfpc}{$H+}{$Q-}{$R-}

interface

uses CastleVectors, Osm3dGroundComposite, Osm3dTileX3D;

const
  ROAD_CURB_OWNER = Low(Int64)+73;
  ROAD_BUMP_OWNER = Low(Int64)+74;
  ROAD_CURB_WIDTH = 0.26;
  ROAD_CURB_HEIGHT = 0.15;
  ROAD_CURB_ROWS = 6;
  // Cross-section baked into the tile mesh during preparation.
  ROAD_CURB_OFFSETS: array[0..ROAD_CURB_ROWS-1] of Single = (0,0.004,0.19,0.22,0.224,0.26);
  ROAD_CURB_LIFTS: array[0..ROAD_CURB_ROWS-1] of Single = (0,1,1,0.8,0,0);

type
  TCurbMesh = record
    Positions: array of TVector3; { tile-relative XZ, one copy per vertex }
    Indices: array of Cardinal;  { three indices per baked triangle }
  end;

var
  CurbContactsEnabled: Boolean = True; { diagnostic A/B switch only }

{ Append raised curbs to the existing composite on the tile preparation worker.
  Export the same vertices for the common ground-height index.
  Only a shared road/non-road edge qualifies: neither intersections nor
  artificial tile cuts can generate a curb. Returns curb segment count. }
function AppendUrbanRoadCurbs(Comp:TGroundCompositeMesh; Model:TTileModel;
  const TileOrigin:TVector3; EastScale:Single; var CurbVertices:TCurbMesh; PhaseOriginX:Double=0; PhaseOriginZ:Double=0):Integer;

implementation

uses Math, Generics.Collections, Osm3dGeomMesh, Osm3dCurbSimplify,
  Osm3dRoadSurface;

const
  { Road triangles are finely tessellated by terrain carving. A 64 m cell
    feeds thousands of unrelated triangles to every short curb edge. This
    broad phase only filters candidates; exact clipping below is unchanged. }
  ROAD_QUERY_CELL = 8.0;
  BUILDING_QUERY_CELL = 128.0;

type
  TEdge = record A,B,C,Mat,Roads:Integer; Neighbour,MappedNeighbour:Boolean end;
  TCurbEdge = record
    A,B,C,Mat,Side:Integer;
    StartInset,EndInset:TVector3;
    NewChain,Unmapped:Boolean;
  end;
  TEdges = specialize TDictionary<QWord,TEdge>;
  TLink = record Count,First,Second:Integer end;
  TLinks = specialize TDictionary<Integer,TLink>;
  TRoadIds = specialize TList<Integer>;
  TRoadGrid = specialize TObjectDictionary<Int64,TRoadIds>;

function AppendUrbanRoadCurbs(Comp:TGroundCompositeMesh; Model:TTileModel;
  const TileOrigin:TVector3; EastScale:Single; var CurbVertices:TCurbMesh; PhaseOriginX,PhaseOriginZ:Double):Integer;
var Edges:TEdges; Key:QWord; Edge:TEdge; Curb:TCurbEdge; Pair:specialize TPair<QWord,TEdge>;
  Tri,I,A,B,C,PA,PB,Mat,J,NearCount,Ring,Row,Count,RingCount,FirstTri,FirstVertex,ExportBase,IndexBase:Integer;
  PreviousRing,SharedRings,SharedVertices,PoolIndex:Integer;
  P,Q,R,Inside,Normal,Local,StartInset,EndInset:TVector3;
  Len,Side,DX,DZ,Distance,Closest,S0,Fraction:Single;
  Phase,NextPhase:Double;
  V:TMeshVertex; Asphalt:specialize TDictionary<Int64,Boolean>;
  Eligible:Boolean; Seg:TTileRoadSeg;
  Candidates: array of TCurbEdge;
  Joins:specialize TDictionary<Integer,TVector3>;
  Degrees:specialize TDictionary<Integer,Integer>;
  StartOpen,EndOpen,CanShare,AllShared:Boolean;
  RingS:array[0..3] of Single;
  RingLift:array[0..3] of Boolean;
  RingIndex:array[0..3,0..ROAD_CURB_ROWS-1] of Integer;
  PreviousIndex:array[0..ROAD_CURB_ROWS-1] of Integer;
  RoadGrid,BuildingGrid:TRoadGrid;
  RoadSeen:array of Integer;
  RoadStamp:Integer;
  procedure AddJoin(Vertex:Integer; const Inset:TVector3); forward;
  function GridKey(X,Z:Integer):Int64; inline;
  begin Result:=Int64((QWord(LongWord(X)) shl 32) or LongWord(Z)) end;
  procedure IndexBuildings;
  var N,X,Z:Integer; Items:TRoadIds; Key:Int64;
  begin
    { UrbanAt needs only boxes within 120 m of the query, not every
      building in the tile for every short road-boundary edge. }
    for N:=0 to High(Model.BuildingObstacles) do
      with Model.BuildingObstacles[N] do
        for Z:=Floor((MinZ-120)/BUILDING_QUERY_CELL) to Floor((MaxZ+120)/BUILDING_QUERY_CELL) do
          for X:=Floor((MinX*EastScale-120)/BUILDING_QUERY_CELL) to Floor((MaxX*EastScale+120)/BUILDING_QUERY_CELL) do begin
            Key:=GridKey(X,Z);
            if not BuildingGrid.TryGetValue(Key,Items) then begin
              Items:=TRoadIds.Create;BuildingGrid.Add(Key,Items);
            end;
            Items.Add(N);
          end;
  end;
  procedure IndexRoads;
  var S,X,Z,K,Mat:Integer; A,B,C:TVector3; Items:TRoadIds; Key:Int64;
  begin
    { Use the rendered road polygons, including junction widening and asphalt
      areas. Centerline rectangles cannot describe the actual junction outline. }
    SetLength(RoadSeen,Comp.TriangleCount);
    for S:=0 to Comp.TriangleCount-1 do begin
      K:=Comp.Indices[S*3];Mat:=Comp.MatIdOf(K);
      if not ((Mat=13) or (Mat in [24..27])) then Continue;
      A:=Comp.PositionOf(K);B:=Comp.PositionOf(Comp.Indices[S*3+1]);C:=Comp.PositionOf(Comp.Indices[S*3+2]);
      for Z:=Floor((Min(A.Z,Min(B.Z,C.Z))-2*ROAD_CURB_WIDTH-0.02)/ROAD_QUERY_CELL) to
             Floor((Max(A.Z,Max(B.Z,C.Z))+2*ROAD_CURB_WIDTH+0.02)/ROAD_QUERY_CELL) do
        for X:=Floor((Min(A.X,Min(B.X,C.X))-2*ROAD_CURB_WIDTH-0.02)/ROAD_QUERY_CELL) to
               Floor((Max(A.X,Max(B.X,C.X))+2*ROAD_CURB_WIDTH+0.02)/ROAD_QUERY_CELL) do begin
          Key:=GridKey(X,Z);
          if not RoadGrid.TryGetValue(Key,Items) then begin
            Items:=TRoadIds.Create;RoadGrid.Add(Key,Items);
          end;
          Items.Add(S);
        end;
    end;
  end;
  procedure AddOpenEdge;
  var Cuts:array of TVector2; CutN,X,Z,S,N,K:Integer; Items:TRoadIds;
    A0,A1,A2,D,StartP,Probe,Nrm:TVector3; Area,SignArea,T0,T1,At,Left,Right,SurfaceY,Clearance:Single;
    Swap:TVector2;
    function Clip(Value,Delta,Lo,Hi:Single):Boolean;
    var L,R,T:Single;
    begin
      if Abs(Delta)<1e-7 then Exit((Value>=Lo)and(Value<=Hi));
      L:=(Lo-Value)/Delta;R:=(Hi-Value)/Delta;
      if L>R then begin T:=L;L:=R;R:=T end;
      T0:=Max(T0,L);T1:=Min(T1,R);Result:=T1>T0;
    end;
    function VertexAt(T:Single):Integer;
    var V:TMeshVertex;
    begin
      if T<0.00001 then Exit(Edge.A);
      if T>0.99999 then Exit(Edge.B);
      V:=Default(TMeshVertex);V.Position:=P+(Q-P)*T;
      V.Normal:=(Comp.NormalOf(Edge.A)*(1-T)+Comp.NormalOf(Edge.B)*T).Normalize;
      V.UV:=Comp.UVOf(Edge.A)*(1-T)+Comp.UVOf(Edge.B)*T;
      V.OsmId:=Comp.OsmIdOf(Edge.A);Result:=Comp.AppendVertex(V,Edge.Mat);
    end;
    procedure Keep(L,R:Single);
    begin
      if (R-L)*Len<0.10 then Exit;
      Curb:=Default(TCurbEdge);Curb.A:=VertexAt(L);Curb.B:=VertexAt(R);
      Curb.C:=Edge.C;Curb.Mat:=Edge.Mat;Curb.Unmapped:=not Edge.MappedNeighbour;
      AddJoin(Curb.A,Inside);AddJoin(Curb.B,Inside);
      if Count=Length(Candidates) then SetLength(Candidates,Max(16,Count*2));
      Candidates[Count]:=Curb;Inc(Count);
    end;
  begin
    Inc(RoadStamp);CutN:=0;
    Clearance:=ROAD_CURB_WIDTH+0.02;
    { An unmapped terrain remnant between two road polygons needs room for
      both curbs. Otherwise their faces overlap across a triangulation sliver.
      Explicitly mapped islands keep the ordinary single-curb test. }
    if not Edge.MappedNeighbour then Clearance:=2*ROAD_CURB_WIDTH+0.02;
    for Z:=Floor(Min(P.Z,Q.Z)/ROAD_QUERY_CELL) to Floor(Max(P.Z,Q.Z)/ROAD_QUERY_CELL) do
      for X:=Floor(Min(P.X,Q.X)/ROAD_QUERY_CELL) to Floor(Max(P.X,Q.X)/ROAD_QUERY_CELL) do
        if RoadGrid.TryGetValue(GridKey(X,Z),Items) then for S in Items do begin
          if RoadSeen[S]=RoadStamp then Continue;RoadSeen[S]:=RoadStamp;
          A0:=Comp.PositionOf(Comp.Indices[S*3]);
          A1:=Comp.PositionOf(Comp.Indices[S*3+1]);
          A2:=Comp.PositionOf(Comp.Indices[S*3+2]);
          Area:=(A1.X-A0.X)*(A2.Z-A0.Z)-(A1.Z-A0.Z)*(A2.X-A0.X);
          if Abs(Area)<0.00001 then Continue;
          SignArea:=1;if Area<0 then SignArea:=-1;
          { The whole curb must fit on the non-road side. Testing only its
            centre leaves raised blocks spanning thin grass slivers in joints. }
          StartP:=P+Inside*Clearance;D:=Q-P;T0:=0;T1:=1;
          if not Clip(SignArea*((A1.X-A0.X)*(StartP.Z-A0.Z)-(A1.Z-A0.Z)*(StartP.X-A0.X)),
            SignArea*((A1.X-A0.X)*D.Z-(A1.Z-A0.Z)*D.X),0,1e20) then Continue;
          if not Clip(SignArea*((A2.X-A1.X)*(StartP.Z-A1.Z)-(A2.Z-A1.Z)*(StartP.X-A1.X)),
            SignArea*((A2.X-A1.X)*D.Z-(A2.Z-A1.Z)*D.X),0,1e20) then Continue;
          if not Clip(SignArea*((A0.X-A2.X)*(StartP.Z-A2.Z)-(A0.Z-A2.Z)*(StartP.X-A2.X)),
            SignArea*((A0.X-A2.X)*D.Z-(A0.Z-A2.Z)*D.X),0,1e20) then Continue;
          Probe:=StartP+D*((T0+T1)*0.5);
          Nrm:=TVector3.CrossProduct(A1-A0,A2-A0);
          SurfaceY:=A0.Y-(Nrm.X*(Probe.X-A0.X)+Nrm.Z*(Probe.Z-A0.Z))/Nrm.Y;
          { Decks at another elevation cannot cut an opening in this curb. }
          if Abs(SurfaceY-Probe.Y)>0.35 then Continue;
          if CutN=Length(Cuts) then SetLength(Cuts,Max(8,CutN*2));
          Cuts[CutN]:=Vector2(T0,T1);Inc(CutN);
        end;
    for N:=1 to CutN-1 do begin
      Swap:=Cuts[N];K:=N;
      while (K>0)and(Cuts[K-1].X>Swap.X) do begin Cuts[K]:=Cuts[K-1];Dec(K) end;
      Cuts[K]:=Swap;
    end;
    At:=0;
    for N:=0 to CutN-1 do begin
      Left:=Cuts[N].X;Right:=Cuts[N].Y;
      if Left>At then Keep(At,Left);
      At:=Max(At,Right);
    end;
    if At<1 then Keep(At,1);
  end;
  procedure AddJoin(Vertex:Integer; const Inset:TVector3);
  var Id,D:Integer; N:TVector3;
  begin
    Id:=Comp.Verts[Vertex].PoolIdx;
    if Degrees.TryGetValue(Id,D) then
    begin N:=Joins[Id]+Inset; Inc(D) end
    else begin N:=Inset; D:=1 end;
    Joins.AddOrSetValue(Id,N); Degrees.AddOrSetValue(Id,D);
  end;
  function JoinInset(Vertex:Integer; const Inset:TVector3):TVector3;
  var Id:Integer; N:TVector3; DotN:Single;
  begin
    Result:=Inset; Id:=Comp.Verts[Vertex].PoolIdx;
    if Degrees[Id]<>2 then Exit;
    N:=Joins[Id]; N.Y:=0;
    if N.LengthSqr<0.1 then Exit;
    N:=N.Normalize; DotN:=N.X*Inset.X+N.Z*Inset.Z;
    if DotN>0.5 then Result:=N/DotN; // bounded miter, at most twice width
  end;
  function EdgeKey(VA,VB:Integer):QWord;
  begin
    PA:=Comp.Verts[VA].PoolIdx; PB:=Comp.Verts[VB].PoolIdx;
    Result:=(QWord(Min(PA,PB)) shl 32) or LongWord(Max(PA,PB));
  end;
  function UrbanAt(const Pos:TVector3):Boolean;
  var N:Integer; Items:TRoadIds;
  begin
    if not BuildingGrid.TryGetValue(GridKey(
      Floor((Pos.X-TileOrigin.X)/BUILDING_QUERY_CELL),
      Floor((Pos.Z-TileOrigin.Z)/BUILDING_QUERY_CELL)),Items) then Exit(False);
    Local:=Pos-TileOrigin; Local.X:=Local.X/EastScale;
    NearCount:=0; Closest:=1e20;
    for N in Items do
      with Model.BuildingObstacles[N] do
      begin
        DX:=Max(0.0,Max(MinX-Local.X,Local.X-MaxX))*EastScale;
        DZ:=Max(0.0,Max(MinZ-Local.Z,Local.Z-MaxZ));
        Distance:=DX*DX+DZ*DZ;
        Closest:=Min(Closest,Distance);
        if Distance<120*120 then Inc(NearCount);
        if (NearCount>=3) and (Closest<70*70) then Exit(True);
      end;
    Result:=False;
  end;

  procedure MergeCandidates;
  var Links:TLinks; Used:array of Boolean;
    Merged:array of TCurbEdge; Path:TCurbPath; PathEdges:array of Integer;
    Keep:TCurbPathIndices;
    K,Pass,Start,Current,AtVertex,Next,PathN,OutN,N,EA,EB:Integer;
    E,LastE:TCurbEdge; Point:TCurbPathPoint;
    {$IFDEF CURB_MERGE_TRACE}
    PathCount,ShortCount,ShortPaths:Integer;
    SpanLength,OriginalLength:Double;
    {$ENDIF}

    procedure AddLink(Vertex,EdgeIndex:Integer);
    var Id:Integer; L:TLink;
    begin
      Id:=Comp.Verts[Vertex].PoolIdx;
      if not Links.TryGetValue(Id,L) then L:=Default(TLink);
      if L.Count=0 then L.First:=EdgeIndex else if L.Count=1 then L.Second:=EdgeIndex;
      Inc(L.Count);Links.AddOrSetValue(Id,L);
    end;

    function Following(EdgeIndex,Vertex:Integer):Integer;
    var L:TLink; Id,S1,S2:Integer;
    begin
      Result:=-1;Id:=Comp.Verts[Vertex].PoolIdx;L:=Links[Id];
      if L.Count<>2 then Exit;
      if L.First=EdgeIndex then Result:=L.Second else Result:=L.First;
      if Candidates[Result].Mat<>Candidates[EdgeIndex].Mat then begin Result:=-1;Exit end;
      S1:=Candidates[EdgeIndex].Side;
      if Comp.Verts[Candidates[EdgeIndex].A].PoolIdx=Id then S1:=-S1;
      S2:=Candidates[Result].Side;
      if Comp.Verts[Candidates[Result].B].PoolIdx=Id then S2:=-S2;
      if S1<>S2 then Result:=-1;
    end;

    function Oriented(EdgeIndex,Vertex:Integer):TCurbEdge;
    var T:Integer; Offset:TVector3;
    begin
      Result:=Candidates[EdgeIndex];
      if Comp.Verts[Result.A].PoolIdx=Comp.Verts[Vertex].PoolIdx then Exit;
      T:=Result.A;Result.A:=Result.B;Result.B:=T;Result.Side:=-Result.Side;
      Offset:=Result.StartInset;Result.StartInset:=Result.EndInset;Result.EndInset:=Offset;
    end;

    procedure AppendPoint(Vertex:Integer; const Offset:TVector3);
    var D:TVector3;
    begin
      if PathN=Length(Path) then
      begin SetLength(Path,Max(32,PathN*2));SetLength(PathEdges,Length(Path)) end;
      Point.Vertex:=Vertex;Point.Position:=Comp.PositionOf(Vertex);
      Point.Outer:=Point.Position+Offset*ROAD_CURB_WIDTH;
      Point.OuterNext:=Point.Outer;
      Point.Station:=0;
      if PathN>0 then
      begin
        D:=Point.Position-Path[PathN-1].Position;
        Point.Station:=Path[PathN-1].Station+Sqrt(Double(D.X)*D.X+Double(D.Z)*D.Z);
      end;
      Path[PathN]:=Point;Inc(PathN);
    end;

  begin
    Links:=TLinks.Create;
    try
      SetLength(Used,Count);SetLength(Merged,Count);OutN:=0;
      {$IFDEF CURB_MERGE_TRACE}PathCount:=0;ShortCount:=0;ShortPaths:=0;OriginalLength:=0;{$ENDIF}
      for K:=0 to Count-1 do
      begin AddLink(Candidates[K].A,K);AddLink(Candidates[K].B,K) end;
      { Open/branched paths first; the second pass handles closed loops. }
      for Pass:=0 to 1 do
      for K:=0 to Count-1 do if not Used[K] then
      begin
        Start:=Candidates[K].A;
        if Pass=0 then
        begin
          if Following(K,Start)>=0 then
          begin
            Start:=Candidates[K].B;
            if Following(K,Start)>=0 then Continue;
          end;
        end;
        Current:=K;AtVertex:=Start;PathN:=0;
        repeat
          E:=Oriented(Current,AtVertex);
          if PathN=0 then AppendPoint(E.A,E.StartInset);
          Path[PathN-1].OuterNext:=Path[PathN-1].Position+E.StartInset*ROAD_CURB_WIDTH;
          PathEdges[PathN-1]:=Current;Used[Current]:=True;
          AppendPoint(E.B,E.EndInset);
          Next:=Following(Current,E.B);AtVertex:=E.B;
          if (Next<0) or Used[Next] then Break;
          Current:=Next;
        until False;
        SetLength(Path,PathN);Keep:=SimplifyCurbPath(Path);
        {$IFDEF CURB_MERGE_TRACE}
        Inc(PathCount);if Path[PathN-1].Station<CURB_BLOCK_LENGTH then Inc(ShortPaths);
        OriginalLength:=OriginalLength+Path[PathN-1].Station;
        {$ENDIF}
        for N:=0 to High(Keep)-1 do
        begin
          EA:=Keep[N];EB:=Keep[N+1];
          E:=Oriented(PathEdges[EA],Path[EA].Vertex);
          LastE:=Oriented(PathEdges[EB-1],Path[EB-1].Vertex);
          E.B:=LastE.B;E.EndInset:=LastE.EndInset;
          E.NewChain:=N=0;
          {$IFDEF CURB_MERGE_TRACE}
          SpanLength:=Path[EB].Station-Path[EA].Station;
          if SpanLength<CURB_BLOCK_LENGTH then Inc(ShortCount);
          {$ENDIF}
          Merged[OutN]:=E;Inc(OutN);
        end;
      end;
      {$IFDEF CURB_MERGE_TRACE}
      WriteLn('curb_merge paths=',PathCount,' short_paths=',ShortPaths,' length=',OriginalLength:0:1,
        ' source=',Count,' merged=',OutN,' short_spans=',ShortCount);
      {$ENDIF}
      SetLength(Merged,OutN);Candidates:=Merged;Count:=OutN;
    finally Links.Free end;
  end;
begin
  Result:=0;
  if (Comp=nil) or (Model=nil) or (Length(Model.BuildingObstacles)<3) then Exit;
  FirstTri:=Comp.TriangleCount;
  FirstVertex:=Comp.VertexCount;
  Edges:=TEdges.Create;
  Asphalt:=specialize TDictionary<Int64,Boolean>.Create;
  Joins:=specialize TDictionary<Integer,TVector3>.Create;
  Degrees:=specialize TDictionary<Integer,Integer>.Create;
  RoadGrid:=TRoadGrid.Create([doOwnsValues]);RoadStamp:=0;
  BuildingGrid:=TRoadGrid.Create([doOwnsValues]);
  try
    IndexRoads;IndexBuildings;
    for I:=0 to Model.RoadSegCount-1 do
    begin
      Seg:=Model.RoadSegs[I];
      Eligible:=(Seg.Surface.Asphalt in [ROAD_SURFACE_UNKNOWN, ROAD_SURFACE_ASPHALT])
        and not Seg.IsBridge;
      Asphalt.AddOrSetValue(Seg.WayId,Eligible);
    end;
    // Index just road edges, then find their non-road neighbours. The pool
    // unifies coincident positions across materials, unlike UV vertex IDs.
    for Tri:=0 to Comp.TriangleCount-1 do
    begin
      A:=Comp.Indices[Tri*3]; Mat:=Comp.MatIdOf(A);
      if (Mat<24) or (Mat>27) then Continue;
      if (Comp.OsmIdOf(A)=ROAD_CURB_OWNER)or(Comp.OsmIdOf(A)=ROAD_BUMP_OWNER) then Continue;
      if Asphalt.TryGetValue(Comp.OsmIdOf(A),Eligible) and not Eligible then Continue;
      for I:=0 to 2 do
      begin
        A:=Comp.Indices[Tri*3+I]; B:=Comp.Indices[Tri*3+(I+1) mod 3];
        C:=Comp.Indices[Tri*3+(I+2) mod 3]; Key:=EdgeKey(A,B);
        if Edges.TryGetValue(Key,Edge) then Inc(Edge.Roads)
        else begin Edge:=Default(TEdge); Edge.A:=A; Edge.B:=B; Edge.C:=C; Edge.Mat:=Mat; Edge.Roads:=1 end;
        Edges.AddOrSetValue(Key,Edge);
      end;
    end;
    for Tri:=0 to Comp.TriangleCount-1 do
    begin
      Mat:=Comp.MatIdOf(Comp.Indices[Tri*3]);
      // Asphalt areas and paths are openings, as are water and railways.
      if not (Mat in [0..12,14,21,22]) then Continue;
      for I:=0 to 2 do
      begin
        Key:=EdgeKey(Comp.Indices[Tri*3+I],Comp.Indices[Tri*3+(I+1) mod 3]);
        if Edges.TryGetValue(Key,Edge) then
        begin
          Edge.Neighbour:=True;
          Edge.MappedNeighbour:=Edge.MappedNeighbour or
            (Mat<>GROUND_MAT_TERRAIN) or (Comp.OsmIdOf(Comp.Indices[Tri*3])<>0);
          Edges[Key]:=Edge;
        end;
      end;
    end;
    { Most indexed road edges are internal and never become curbs. Do not
      reserve an expanded curb record for every triangulation edge. }
    SetLength(Candidates,Min(1024,Edges.Count)); Count:=0;
    for Pair in Edges do
    begin
      Edge:=Pair.Value;
      if (Edge.Roads<>1) or not Edge.Neighbour then Continue;
      P:=Comp.PositionOf(Edge.A); Q:=Comp.PositionOf(Edge.B); R:=Comp.PositionOf(Edge.C);
      if not UrbanAt((P+Q)*0.5) then Continue;
      DX:=Q.X-P.X; DZ:=Q.Z-P.Z; Len:=Sqrt(DX*DX+DZ*DZ);
      if Len<0.10 then Continue;
      Inside:=Vector3(-DZ/Len,0,DX/Len);
      if (R.X-P.X)*Inside.X+(R.Z-P.Z)*Inside.Z<0 then Inside:=-Inside;
      Inside:=-Inside; // joins use the same outward direction as the curb faces
      AddOpenEdge;
    end;
    { Clipping the sides of a narrow terrain remnant can leave its short end
      cap on its own. Discard only isolated unmapped caps narrower than two
      curbs; mapped islands and connected short blocks remain intact. }
    J:=0;
    for I:=0 to Count-1 do begin
      Curb:=Candidates[I];P:=Comp.PositionOf(Curb.A);Q:=Comp.PositionOf(Curb.B);
      if Curb.Unmapped and
         (Degrees[Comp.Verts[Curb.A].PoolIdx]=1) and
         (Degrees[Comp.Verts[Curb.B].PoolIdx]=1) and
         (Sqr(P.X-Q.X)+Sqr(P.Z-Q.Z)<Sqr(2*ROAD_CURB_WIDTH)) then Continue;
      Candidates[J]:=Curb;Inc(J);
    end;
    Count:=J;SetLength(Candidates,Count);
    { Freeze the original endpoint cross-sections before simplifying. This
      keeps miter corners and terrain contact at retained endpoints unchanged. }
    for I:=0 to Count-1 do
    begin
      Curb:=Candidates[I];
      P:=Comp.PositionOf(Curb.A); Q:=Comp.PositionOf(Curb.B); R:=Comp.PositionOf(Curb.C);
      DX:=Q.X-P.X; DZ:=Q.Z-P.Z; Len:=Sqrt(DX*DX+DZ*DZ);
      Inside:=Vector3(-DZ/Len,0,DX/Len);
      Side:=(R.X-P.X)*Inside.X+(R.Z-P.Z)*Inside.Z;
      if Side<0 then Inside:=-Inside;
      Inside:=-Inside; Side:=-Side;
      Normal:=Comp.NormalOf(Curb.A)+Comp.NormalOf(Curb.B);
      if Normal.LengthSqr<0.1 then Normal:=Vector3(0,1,0) else Normal:=Normal.Normalize;
      StartInset:=JoinInset(Curb.A,Inside); EndInset:=JoinInset(Curb.B,Inside);
      StartInset.Y:=-(Normal.X*StartInset.X+Normal.Z*StartInset.Z)/Max(Normal.Y,0.2);
      EndInset.Y:=-(Normal.X*EndInset.X+Normal.Z*EndInset.Z)/Max(Normal.Y,0.2);
      Candidates[I].StartInset:=StartInset;Candidates[I].EndInset:=EndInset;
      if Side<0 then Candidates[I].Side:=-1 else Candidates[I].Side:=1;
    end;
    MergeCandidates;
    PreviousRing:=-1;NextPhase:=0;SharedRings:=0;SharedVertices:=0;
    for I:=0 to Count-1 do
    begin
      Curb:=Candidates[I];P:=Comp.PositionOf(Curb.A);Q:=Comp.PositionOf(Curb.B);
      DX:=Q.X-P.X;DZ:=Q.Z-P.Z;Len:=Sqrt(DX*DX+DZ*DZ);Side:=Curb.Side;
      Normal:=Comp.NormalOf(Curb.A)+Comp.NormalOf(Curb.B);
      if Normal.LengthSqr<0.1 then Normal:=Vector3(0,1,0) else Normal:=Normal.Normalize;
      StartInset:=Curb.StartInset;EndInset:=Curb.EndInset;
      StartOpen:=Degrees[Comp.Verts[Curb.A].PoolIdx]<>2;
      EndOpen:=Degrees[Comp.Verts[Curb.B].PoolIdx]<>2;
      // End rings at ground height close exposed ends. A 12 mm horizontal
      // run keeps the end faces sampleable by the ground-height query.
      RingCount:=1; RingS[0]:=0; RingLift[0]:=not StartOpen;
      if StartOpen then begin RingS[RingCount]:=0.012; RingLift[RingCount]:=True; Inc(RingCount) end;
      if EndOpen then begin RingS[RingCount]:=Len-0.012; RingLift[RingCount]:=True; Inc(RingCount) end;
      RingS[RingCount]:=Len; RingLift[RingCount]:=not EndOpen; Inc(RingCount);
      // Anchor each chain geographically, then keep metre UV continuous at
      // its joints. Reset only at 1024m boundaries, duplicating that UV seam.
      if Curb.NewChain then
        Phase:=((Double(P.X)+PhaseOriginX)*DX+(Double(P.Z)+PhaseOriginZ)*DZ)/Len
      else Phase:=NextPhase;
      S0:=Phase-Floor(Phase/1024.0)*1024.0;
      NextPhase:=Double(S0)+Len;
      for Ring:=0 to RingCount-1 do
      begin
        Fraction:=RingS[Ring]/Len;
        AllShared:=True;
        for Row:=0 to ROAD_CURB_ROWS-1 do
        begin
          V:=Default(TMeshVertex);V.OsmId:=ROAD_CURB_OWNER;V.Normal:=Normal;
          V.Position:=P+(Q-P)*Fraction+(StartInset+(EndInset-StartInset)*Fraction)*ROAD_CURB_OFFSETS[Row];
          V.Position.Y:=V.Position.Y+0.002;
          if RingLift[Ring] then V.Position.Y:=V.Position.Y+ROAD_CURB_HEIGHT*ROAD_CURB_LIFTS[Row];
          V.UV.X:=S0+RingS[Ring];V.UV.Y:=ROAD_CURB_OFFSETS[Row];
          // Resolve through the SAME pool operation as AppendVertex. Raw
          // input normals/positions need not equal the welded values. Sharing
          // is exact on the final (pool position, pool normal, UV, material).
          PoolIndex:=Comp.Pool.Add(V.Position,V.Normal);
          CanShare:=(Ring=0) and not Curb.NewChain and not StartOpen and (PreviousRing>=0);
          if CanShare then
          begin
            J:=PreviousIndex[Row];
            CanShare:=(Comp.Verts[J].PoolIdx=PoolIndex) and (Comp.MatIdOf(J)=Curb.Mat) and
              (Comp.UVOf(J).X=V.UV.X) and (Comp.UVOf(J).Y=V.UV.Y);
          end;
          if CanShare then
          begin RingIndex[Ring,Row]:=J;Inc(SharedVertices) end
          else
          begin
            RingIndex[Ring,Row]:=Comp.AddCompVert(PoolIndex,V.UV,V.OsmId,Curb.Mat);
            AllShared:=False;
          end;
        end;
        if AllShared then Inc(SharedRings);
      end;
      for Ring:=0 to RingCount-2 do
      for Row:=0 to ROAD_CURB_ROWS-2 do
      begin
        A:=RingIndex[Ring,Row];B:=RingIndex[Ring+1,Row];
        PA:=RingIndex[Ring,Row+1];PB:=RingIndex[Ring+1,Row+1];
        if Side<0 then begin Comp.AppendTriangle(A,B,PB); Comp.AppendTriangle(A,PB,PA) end
        else begin Comp.AppendTriangle(A,PB,B); Comp.AppendTriangle(A,PA,PB) end;
      end;
      if EndOpen then PreviousRing:=-1
      else
      begin
        PreviousRing:=RingCount-1;
        for Row:=0 to ROAD_CURB_ROWS-1 do PreviousIndex[Row]:=RingIndex[PreviousRing,Row];
      end;
      Inc(Result);
    end;
    {$IFDEF CURB_MERGE_TRACE}
    WriteLn('curb_shared rings=',SharedRings,' saved_vertices=',SharedVertices);
    {$ENDIF}
    // Copy actual render vertices once; no second profile or displacement.
    ExportBase:=Length(CurbVertices.Positions);
    IndexBase:=Length(CurbVertices.Indices);
    SetLength(CurbVertices.Positions,ExportBase+Comp.VertexCount-FirstVertex);
    SetLength(CurbVertices.Indices,IndexBase+(Comp.TriangleCount-FirstTri)*3);
    for J:=FirstVertex to Comp.VertexCount-1 do
    begin
      Local:=Comp.PositionOf(J);
      Local.X:=Local.X-TileOrigin.X; Local.Z:=Local.Z-TileOrigin.Z;
      CurbVertices.Positions[ExportBase+J-FirstVertex]:=Local;
    end;
    for J:=FirstTri*3 to Comp.TriangleCount*3-1 do
      CurbVertices.Indices[IndexBase+J-FirstTri*3]:=
        ExportBase+Integer(Comp.Indices[J])-FirstVertex;
    Comp.TrimArrays;
  finally BuildingGrid.Free; RoadGrid.Free; Degrees.Free; Joins.Free; Asphalt.Free; Edges.Free end;
end;

end.
