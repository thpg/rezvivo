unit Osm3dCoastline;
{$mode objfpc}{$H+}{$Q-}{$R-}

interface
uses SysUtils, Math, Generics.Collections, Osm3dGeoMath, Osm3dOsmData;

{ Adds a clipped marine multipolygon to this block's private dataset.
  Directed coastline is the boundary; no huge ocean polygon is requested.
  Return number of rings, -1 for incomplete/ambiguous OSM topology. }
function AddSeaSurfaces(Dataset: TOSMDataset; const Box: TLatLonBox;
  const Origin: TLatLon; ScaleLat: Double): Integer;
function CoarseOceanAt(const P: TLatLon): Boolean;
{ Offline fallback for scenes whose visible tiles stop inland. }
function CoarseOceanNear(const P: TLatLon; RadiusM: Double): Boolean;

implementation
{$I Osm3dLandMask.inc}

type
  TSegment = record A,B: TScatterPoint end;
  TEdge = record A,B: TScatterPoint; Used: Boolean end;
  TBoundary = record P: TScatterPoint; S: Double end;
  TEdgeMap = specialize TDictionary<QWord,Integer>;

function CoarseOceanAt(const P: TLatLon): Boolean;
var X,Y:Double;R,I,J,A,N:Integer;Inside:Boolean;
begin
  X:=P.Lon*100000;Y:=P.Lat*100000;
  for R:=0 to High(LandRings) do
  begin
    if (X<LandRings[R,2]) or (X>LandRings[R,4]) or
       (Y<LandRings[R,3]) or (Y>LandRings[R,5]) then Continue;
    A:=LandRings[R,0];N:=LandRings[R,1];J:=A+N-1;Inside:=False;
    for I:=A to A+N-1 do
    begin
      if ((LandPoints[I,1]>Y)<>(LandPoints[J,1]>Y)) and
        (X<(Double(LandPoints[J,0])-LandPoints[I,0])*(Y-LandPoints[I,1])/
        (Double(LandPoints[J,1])-LandPoints[I,1])+LandPoints[I,0]) then Inside:=not Inside;
      J:=I;
    end;
    if Inside then Exit(False);
  end;
  Result:=True;
end;

function CoarseOceanNear(const P:TLatLon;RadiusM:Double):Boolean;
var R,I,J,A,N:Integer;SX,SZ,AX,AZ,BX,BZ,DX,DZ,D,T:Double;
begin
  if CoarseOceanAt(P)then Exit(True);
  Result:=False;if RadiusM<=0 then Exit;
  SX:=EARTH_RADIUS_M*DEG_TO_RAD*Max(0.000001,Cos(P.Lat*DEG_TO_RAD));
  SZ:=EARTH_RADIUS_M*DEG_TO_RAD;
  for R:=0 to High(LandRings)do begin
    if(P.Lat<LandRings[R,3]*0.00001-RadiusM/SZ)or
      (P.Lat>LandRings[R,5]*0.00001+RadiusM/SZ)then Continue;
    A:=LandRings[R,0];N:=LandRings[R,1];J:=A+N-1;
    for I:=A to A+N-1 do begin
      AX:=(LandPoints[J,0]*0.00001-P.Lon);
      AX:=AX-360*Floor((AX+180)/360);
      DX:=(LandPoints[I,0]-LandPoints[J,0])*0.00001;
      DX:=DX-360*Floor((DX+180)/360);
      BX:=(AX+DX)*SX;AX:=AX*SX;
      AZ:=(LandPoints[J,1]*0.00001-P.Lat)*SZ;
      BZ:=(LandPoints[I,1]*0.00001-P.Lat)*SZ;
      DX:=BX-AX;DZ:=BZ-AZ;D:=DX*DX+DZ*DZ;
      if D>0 then T:=EnsureRange(-(AX*DX+AZ*DZ)/D,0.0,1.0)else T:=0;
      if Sqr(AX+T*DX)+Sqr(AZ+T*DZ)<=Sqr(RadiusM)then Exit(True);
      J:=I;
    end;
  end;
end;

function Pt(X,Z:Double):TScatterPoint;inline;
begin Result.X:=X;Result.Z:=Z end;

function Key(const P:TScatterPoint):QWord;inline;
begin Result:=(QWord(LongWord(LongInt(Round(P.X*64)))) shl 32) or LongWord(LongInt(Round(P.Z*64))) end;

function AddSeaSurfaces(Dataset:TOSMDataset;const Box:TLatLonBox;
  const Origin:TLatLon;ScaleLat:Double):Integer;
var
  Projection:TLocalProjection;
  Segs:array of TSegment; Edges:array of TEdge; Boundary:array of TBoundary;
  Rings:array of TPolygonRing; Areas:array of Double;
  Starts,Ends:TEdgeMap;
  Way,NewWay:TOSMWay; Rel:TOSMRelation; NA,NB:TOSMNode;
  A,B,P:TScatterPoint; BN,EN,SN,RN,I,J,N,E,NextE,FirstE,OuterCount:Integer;
  MinX,MinZ,MaxX,MaxZ,W,H,Area:Double;
  NodeId,WayId:Int64; LL:TLatLon;
  Bad:Boolean;

  function Project(const L:TLatLon):TScatterPoint;
  begin
    Result.X:=-(L.Lon-Origin.Lon)*Projection.MetersPerDegreeLon;
    Result.Z:=(L.Lat-Origin.Lat)*Projection.MetersPerDegreeLat;
  end;

  function Snap(const P:TScatterPoint):TScatterPoint;
  begin Result:=Pt(Round(P.X*64)/64.0,Round(P.Z*64)/64.0) end;

  procedure PushEdge(const A,B:TScatterPoint);
  var Old:Integer; AA,BB:TScatterPoint;
  begin
    AA:=Snap(A);BB:=Snap(B);
    if Key(AA)=Key(BB) then Exit;
    if Starts.TryGetValue(Key(AA),Old) then
    begin
      if Key(Edges[Old].B)<>Key(BB) then Bad:=True;
      Exit;
    end;
    if Ends.ContainsKey(Key(BB)) then begin Bad:=True;Exit end;
    if EN=Length(Edges) then SetLength(Edges,Max(64,EN*2));
    Edges[EN].A:=AA;Edges[EN].B:=BB;Edges[EN].Used:=False;
    Starts.Add(Key(AA),EN);Ends.Add(Key(BB),EN);Inc(EN);
  end;

  procedure PushBoundary(const P:TScatterPoint);
  var S:Double;
  begin
    if Abs(P.Z-MinZ)<0.02 then S:=P.X-MinX
    else if Abs(P.X-MaxX)<0.02 then S:=W+P.Z-MinZ
    else if Abs(P.Z-MaxZ)<0.02 then S:=W+H+MaxX-P.X
    else if Abs(P.X-MinX)<0.02 then S:=2*W+H+MaxZ-P.Z
    else Exit;
    if BN=Length(Boundary) then SetLength(Boundary,Max(16,BN*2));
    Boundary[BN].P:=P;Boundary[BN].S:=S;Inc(BN);
  end;

  function Clip(const A,B:TScatterPoint;out C,D:TScatterPoint):Boolean;
  var DX,DZ,Lo,Hi:Double;
    function Test(P,Q:Double):Boolean;
    var T:Double;
    begin
      if Abs(P)<1e-15 then Exit(Q>=0);
      T:=Q/P;
      if P<0 then begin if T>Hi then Exit(False);Lo:=Max(Lo,T) end
      else begin if T<Lo then Exit(False);Hi:=Min(Hi,T) end;
      Result:=True;
    end;
  begin
    DX:=B.X-A.X;DZ:=B.Z-A.Z;Lo:=0;Hi:=1;
    Result:=Test(-DX,A.X-MinX) and Test(DX,MaxX-A.X) and
            Test(-DZ,A.Z-MinZ) and Test(DZ,MaxZ-A.Z) and (Hi-Lo>1e-12);
    if Result then begin C:=Pt(A.X+Lo*DX,A.Z+Lo*DZ);D:=Pt(A.X+Hi*DX,A.Z+Hi*DZ) end;
  end;

  function SeaAt(const P:TScatterPoint):Boolean;
  var I:Integer;DX,DZ,L2,T,D,Cross,Best,SignSum:Double;
  begin
    if SN=0 then
      Exit(CoarseOceanAt(TLatLon.Make(Origin.Lat+P.Z/Projection.MetersPerDegreeLat,
                                     Origin.Lon-P.X/Projection.MetersPerDegreeLon)));
    Best:=1e100;SignSum:=0;
    for I:=0 to SN-1 do
    begin
      DX:=Segs[I].B.X-Segs[I].A.X;DZ:=Segs[I].B.Z-Segs[I].A.Z;L2:=DX*DX+DZ*DZ;
      if L2<1e-12 then Continue;
      T:=EnsureRange(((P.X-Segs[I].A.X)*DX+(P.Z-Segs[I].A.Z)*DZ)/L2,0.0,1.0);
      D:=Sqr(P.X-Segs[I].A.X-T*DX)+Sqr(P.Z-Segs[I].A.Z-T*DZ);
      Cross:=(DX*(P.Z-Segs[I].A.Z)-DZ*(P.X-Segs[I].A.X))/Sqrt(L2);
      if D<Best-0.000001 then begin Best:=D;SignSum:=Cross end
      else if Abs(D-Best)<0.000001 then SignSum:=SignSum+Cross;
    end;
    { Projection mirrors East: OSM's water-on-right becomes water-on-left. }
    Result:=SignSum>0;
  end;

  procedure SortBoundary(L,R:Integer);
  var I,J:Integer;P:Double;Tmp:TBoundary;
  begin
    I:=L;J:=R;P:=Boundary[(L+R) div 2].S;
    repeat
      while Boundary[I].S<P do Inc(I);
      while Boundary[J].S>P do Dec(J);
      if I<=J then begin Tmp:=Boundary[I];Boundary[I]:=Boundary[J];Boundary[J]:=Tmp;Inc(I);Dec(J) end;
    until I>J;
    if L<J then SortBoundary(L,J);if I<R then SortBoundary(I,R);
  end;

  procedure ConsumeSegment(const A,B:TScatterPoint);
  var C,D:TScatterPoint;
  begin
    if SN=Length(Segs) then SetLength(Segs,Max(256,SN*2));
    Segs[SN].A:=A;Segs[SN].B:=B;Inc(SN);
    if Clip(A,B,C,D) then
    begin
      { A coast coincident with the frame and facing OUT of this box has
        no marine area here. Do not leave a dangling zero-area chain. }
      if (Abs(C.X-MinX)<1e-7) and (Abs(D.X-MinX)<1e-7) and (D.Z>C.Z) then Exit;
      if (Abs(C.X-MaxX)<1e-7) and (Abs(D.X-MaxX)<1e-7) and (D.Z<C.Z) then Exit;
      if (Abs(C.Z-MinZ)<1e-7) and (Abs(D.Z-MinZ)<1e-7) and (D.X<C.X) then Exit;
      if (Abs(C.Z-MaxZ)<1e-7) and (Abs(D.Z-MaxZ)<1e-7) and (D.X>C.X) then Exit;
      PushEdge(C,D);PushBoundary(C);PushBoundary(D)
    end;
  end;

begin
  Result:=0;if (Dataset=nil) or Box.IsEmpty then Exit;
  Projection:=TLocalProjection.Create(Origin,ScaleLat);
  Starts:=TEdgeMap.Create;Ends:=TEdgeMap.Create;
  try
    A:=Project(TLatLon.Make(Box.MinLat,Box.MaxLon));
    B:=Project(TLatLon.Make(Box.MaxLat,Box.MinLon));
    MinX:=A.X;MinZ:=A.Z;MaxX:=B.X;MaxZ:=B.Z;W:=MaxX-MinX;H:=MaxZ-MinZ;
    BN:=0;EN:=0;SN:=0;Bad:=False;
    for Way in Dataset.Ways.Values do
      if (Way<>nil) and (Way.Tags.GetLower('natural')='coastline') then
        for I:=1 to High(Way.NodeRefs) do
        begin
          NA:=Dataset.FindNode(Way.NodeRefs[I-1]);NB:=Dataset.FindNode(Way.NodeRefs[I]);
          if (NA=nil) or (NB=nil) then begin Bad:=True;Continue end;
          ConsumeSegment(Project(NA.Position),Project(NB.Position));
        end;
    if Bad then Exit(-1);
    PushBoundary(Pt(MinX,MinZ));PushBoundary(Pt(MaxX,MinZ));
    PushBoundary(Pt(MaxX,MaxZ));PushBoundary(Pt(MinX,MaxZ));
    SortBoundary(0,BN-1);
    N:=0;
    for I:=0 to BN-1 do
      if (N=0) or (Key(Boundary[I].P)<>Key(Boundary[N-1].P)) then
      begin Boundary[N]:=Boundary[I];Inc(N) end;
    BN:=N;
    for I:=0 to BN-1 do
    begin
      J:=(I+1) mod BN;A:=Boundary[I].P;B:=Boundary[J].P;
      P:=Pt((A.X+B.X)*0.5,(A.Z+B.Z)*0.5);
      if SeaAt(P) then PushEdge(A,B);
    end;
    if Bad then Exit(-1);
    { Never bridge missing inland endpoints with an invented coastline. }
    for I:=0 to EN-1 do
      if not Starts.ContainsKey(Key(Edges[I].B)) then Exit(-1);
    RN:=0;OuterCount:=0;
    for I:=0 to EN-1 do
    begin
      if Edges[I].Used then Continue;
      SetLength(Rings,RN+1);SetLength(Areas,RN+1);
      E:=I;FirstE:=I;N:=0;Area:=0;
      repeat
        if Edges[E].Used then Exit(-1);
        Edges[E].Used:=True;
        if N=Length(Rings[RN]) then SetLength(Rings[RN],Max(32,N*2));
        Rings[RN][N]:=Edges[E].A;Inc(N);
        Area:=Area+Edges[E].A.X*Edges[E].B.Z-Edges[E].B.X*Edges[E].A.Z;
        if not Starts.TryGetValue(Key(Edges[E].B),NextE) then Exit(-1);
        E:=NextE;
      until E=FirstE;
      if (N>=3) and (Abs(Area)>0.0001) then
      begin SetLength(Rings[RN],N);Areas[RN]:=Area;if Area>0 then Inc(OuterCount);Inc(RN) end;
    end;
    if OuterCount=0 then Exit;
    { Reserved negative IDs, only in this block's transient dataset. Tags live
      on the relation, so landuse/profile builders see each polygon once. }
    NodeId:=-8000000000000000;WayId:=-8000000000000000;
    Rel:=TOSMRelation.Create(-8000000000000000);
    Rel.Tags.Add('type','multipolygon');Rel.Tags.Add('natural','water');Rel.Tags.Add('water','sea');
    SetLength(Rel.Members,RN);
    try
      for I:=0 to RN-1 do
      begin
        NewWay:=TOSMWay.Create(WayId);Inc(WayId);N:=Length(Rings[I]);
        SetLength(NewWay.NodeRefs,N+1);
        for J:=0 to N-1 do
        begin
          LL:=TLatLon.Make(Origin.Lat+Rings[I][J].Z/Projection.MetersPerDegreeLat,
                          Origin.Lon-Rings[I][J].X/Projection.MetersPerDegreeLon);
          Dataset.AddNode(TOSMNode.Create(NodeId,LL));NewWay.NodeRefs[J]:=NodeId;Inc(NodeId);
        end;
        NewWay.NodeRefs[N]:=NewWay.NodeRefs[0];Dataset.AddWay(NewWay);
        Rel.Members[I].Kind:=omkWay;Rel.Members[I].Ref:=NewWay.Id;
        if Areas[I]>0 then Rel.Members[I].Role:='outer' else Rel.Members[I].Role:='inner';
      end;
      Dataset.AddRelation(Rel);Rel:=nil;
    finally Rel.Free end;
    Result:=RN;
  finally Ends.Free;Starts.Free;Projection.Free end;
end;
end.
