unit GameRoutePlanner;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses Classes, SysUtils, Generics.Collections, Osm3dGeoMath, Osm3dOsmData;
type
  TPlannerPoints = array of TLatLon;
  TPlannerSnap = record
    Valid: Boolean;
    Segment: Integer;
    T: Double;
    Position: TLatLon;
  end;
  TPlannerSnaps = array of TPlannerSnap;
  TPlannerNode = record
    Position: TLatLon;
    X, Z: Double;
    Head: Integer;
  end;
  TPlannerSegment = record
    A, B: Integer;
    Length, Cost: Double;
    ForwardAllowed, BackwardAllowed: Boolean;
  end;
  TPlannerArc = record
    Target, Next: Integer;
    Cost: Double;
  end;
  TPlannerCellItem = record Segment, Next: Integer; end;
  { Immutable after construction. UI snapping and background routing can read
    the same graph; explicit references keep old graphs alive during a reload. }
  TPlannerGraph = class
  private
    FRefs: LongInt;
    FProjection: TLocalProjection;
    FNodes: array of TPlannerNode;
    FSegments: array of TPlannerSegment;
    FArcs: array of TPlannerArc;
    FCells: specialize TDictionary<Int64, Integer>;
    FCellItems: array of TPlannerCellItem;
    FNodeCount, FSegmentCount, FArcCount, FCellCount: Integer;
    procedure AddArc(A, B: Integer; Cost: Double);
    procedure IndexSegment(Index: Integer);
    function RouteLeg(const A, B: TPlannerSnap; out Points: TPlannerPoints;
      Cancel: TThread): Boolean;
  public
    Coverage: TLatLonBox;
    constructor Create(Data: TOSMDataset; const Box: TLatLonBox; Cancel: TThread = nil);
    destructor Destroy; override;
    procedure AddRef;
    procedure Release;
    function Snap(const P: TLatLon; out S: TPlannerSnap; Radius: Double = 100): Boolean;
    function Route(const Stops: TPlannerPoints; Loop: Boolean;
      out Points: TPlannerPoints; out ErrorText: string; Cancel: TThread = nil): Boolean;
    property SegmentCount: Integer read FSegmentCount;
  end;
function PlannerDistance(const A, B: TLatLon): Double;
function PlannerLength(const Points: TPlannerPoints): Double;
procedure SavePlannerGPX(const FileName, Title: string; const Points,
  Stops: TPlannerPoints; Loop: Boolean);
implementation
uses UiTranslations, Math, CastleVectors;
const CELL_M = 200.0;
function CellKey(X, Z: Integer): Int64; inline;
begin Result := (Int64(Cardinal(X)) shl 32) or Cardinal(Z); end;
function PlannerDistance(const A, B: TLatLon): Double;
var X,Y: Double;
begin
  X:=Sin((B.Lat-A.Lat)*Pi/360); Y:=Sin((B.Lon-A.Lon)*Pi/360);
  Result:=2*EARTH_RADIUS_M*ArcSin(Sqrt(EnsureRange(X*X+Cos(A.Lat*DEG_TO_RAD)*
    Cos(B.Lat*DEG_TO_RAD)*Y*Y,0.0,1.0)));
end;
function PlannerLength(const Points: TPlannerPoints): Double;
var I: Integer;
begin Result:=0; for I:=1 to High(Points) do Result:=Result+PlannerDistance(Points[I-1],Points[I]); end;
function AllowedWay(W:TOSMWay; out Fwd,Back:Boolean; out Factor:Double):Boolean;
var Kind,Bike,Access,One:string;
begin
  Result:=False; Kind:=W.Tags.GetLower('highway'); Bike:=W.Tags.GetLower('bicycle');
  if (Kind='') or (Kind='construction') or (Kind='proposed') or (Kind='steps') or
    (W.Tags.GetLower('area')='yes') or (Bike='no') or (Bike='private') then Exit;
  Access:=W.Tags.GetLower('access');
  if ((Access='no') or (Access='private')) and (Bike<>'yes') and (Bike<>'designated') and (Bike<>'permissive') then Exit;
  if ((Kind='motorway') or (Kind='motorway_link') or (Kind='trunk') or (Kind='trunk_link')) and
    (Bike<>'yes') and (Bike<>'designated') then Exit;
  if (Kind='raceway') or (Kind='platform') then Exit;
  Factor:=1;
  if (Kind='path') or (Kind='track') then Factor:=1.2;
  if (Kind='footway') or (Kind='pedestrian') then Factor:=1.5;
  One:=W.Tags.GetLower('oneway:bicycle');
  if One='' then begin
    One:=W.Tags.GetLower('oneway');
    if (One='') and (W.Tags.GetLower('junction')='roundabout') then One:='yes';
    if Pos('opposite',W.Tags.GetLower('cycleway'))>0 then One:='no';
  end;
  Fwd:=One<>'-1'; Back:=(One<>'yes') and (One<>'1') and (One<>'true');
  Result:=True;
end;
constructor TPlannerGraph.Create(Data:TOSMDataset; const Box:TLatLonBox; Cancel:TThread);
var Map:specialize TDictionary<Int64,Integer>; W:TOSMWay; N:TOSMNode;
    I,A,B:Integer; Fwd,Back:Boolean; Factor,L:Double; V:TVector3;
  function Node(Id:Int64):Integer;
  begin
    if Map.TryGetValue(Id,Result) then Exit;
    N:=Data.FindNode(Id); if N=nil then Exit(-1);
    Result:=FNodeCount; Inc(FNodeCount);
    if FNodeCount>Length(FNodes) then SetLength(FNodes,FNodeCount*2+64);
    FNodes[Result].Position:=N.Position; V:=FProjection.Project(N.Position);
    FNodes[Result].X:=V.X; FNodes[Result].Z:=V.Z; FNodes[Result].Head:=-1;
    Map.Add(Id,Result);
  end;
begin
  inherited Create; FRefs:=1; Coverage:=Box;
  FProjection:=TLocalProjection.Create(Box.Center);
  FCells:=specialize TDictionary<Int64,Integer>.Create;
  Map:=specialize TDictionary<Int64,Integer>.Create;
  try
    for W in Data.Ways.Values do begin
      if (Cancel<>nil) and Cancel.CheckTerminated then raise EAbort.Create(UiText('Cancelled'));
      if not AllowedWay(W,Fwd,Back,Factor) then Continue;
      for I:=1 to High(W.NodeRefs) do begin
        A:=Node(W.NodeRefs[I-1]); B:=Node(W.NodeRefs[I]);
        if (A<0) or (B<0) or (A=B) then Continue;
        L:=PlannerDistance(FNodes[A].Position,FNodes[B].Position); if L<0.01 then Continue;
        if FSegmentCount>=Length(FSegments) then SetLength(FSegments,FSegmentCount*2+64);
        FSegments[FSegmentCount].A:=A; FSegments[FSegmentCount].B:=B;
        FSegments[FSegmentCount].Length:=L; FSegments[FSegmentCount].Cost:=L*Factor;
        FSegments[FSegmentCount].ForwardAllowed:=Fwd; FSegments[FSegmentCount].BackwardAllowed:=Back;
        if Fwd then AddArc(A,B,L*Factor); if Back then AddArc(B,A,L*Factor);
        IndexSegment(FSegmentCount); Inc(FSegmentCount);
      end;
    end;
  finally Map.Free; end;
  SetLength(FNodes,FNodeCount); SetLength(FSegments,FSegmentCount);
  SetLength(FArcs,FArcCount); SetLength(FCellItems,FCellCount);
end;
destructor TPlannerGraph.Destroy;
begin FCells.Free; FProjection.Free; inherited; end;
procedure TPlannerGraph.AddRef;
begin InterlockedIncrement(FRefs); end;
procedure TPlannerGraph.Release;
begin if InterlockedDecrement(FRefs)=0 then Free; end;
procedure TPlannerGraph.AddArc(A,B:Integer; Cost:Double);
begin
  if FArcCount>=Length(FArcs) then SetLength(FArcs,FArcCount*2+128);
  FArcs[FArcCount].Target:=B; FArcs[FArcCount].Cost:=Cost;
  FArcs[FArcCount].Next:=FNodes[A].Head; FNodes[A].Head:=FArcCount; Inc(FArcCount);
end;
procedure TPlannerGraph.IndexSegment(Index:Integer);
var A,B:TPlannerNode; I,Steps,Head:Integer; Key,LastKey:Int64; T:Double;
begin
  A:=FNodes[FSegments[Index].A]; B:=FNodes[FSegments[Index].B];
  Steps:=Max(1,Ceil(Max(Abs(B.X-A.X),Abs(B.Z-A.Z))/CELL_M)); LastKey:=High(Int64);
  for I:=0 to Steps do begin
    T:=I/Steps; Key:=CellKey(Floor((A.X+(B.X-A.X)*T)/CELL_M),Floor((A.Z+(B.Z-A.Z)*T)/CELL_M));
    if Key=LastKey then Continue; LastKey:=Key;
    if not FCells.TryGetValue(Key,Head) then Head:=-1;
    if FCellCount>=Length(FCellItems) then SetLength(FCellItems,FCellCount*2+128);
    FCellItems[FCellCount].Segment:=Index; FCellItems[FCellCount].Next:=Head;
    FCells.AddOrSetValue(Key,FCellCount); Inc(FCellCount);
  end;
end;
function TPlannerGraph.Snap(const P:TLatLon; out S:TPlannerSnap; Radius:Double):Boolean;
var V:TVector3; X,Z,CX,CZ,R,J,K:Integer; A,B:TPlannerNode; DX,DZ,T,D,Best:Double;
begin
  S:=Default(TPlannerSnap); S.Segment:=-1; Result:=False;
  if IsNan(P.Lat) or IsNan(P.Lon) or IsInfinite(P.Lat) or IsInfinite(P.Lon) then Exit;
  V:=FProjection.Project(P); CX:=Floor(V.X/CELL_M); CZ:=Floor(V.Z/CELL_M);
  R:=Ceil(Radius/CELL_M)+1; Best:=Sqr(Radius);
  for Z:=CZ-R to CZ+R do for X:=CX-R to CX+R do
    if FCells.TryGetValue(CellKey(X,Z),J) then while J>=0 do begin
      K:=FCellItems[J].Segment; A:=FNodes[FSegments[K].A]; B:=FNodes[FSegments[K].B];
      DX:=B.X-A.X; DZ:=B.Z-A.Z;
      T:=EnsureRange(((V.X-A.X)*DX+(V.Z-A.Z)*DZ)/Max(1e-12,DX*DX+DZ*DZ),0.0,1.0);
      D:=Sqr(V.X-A.X-T*DX)+Sqr(V.Z-A.Z-T*DZ);
      if D<Best then begin
        Best:=D; S.Valid:=True; S.Segment:=K; S.T:=T;
        S.Position:=TLatLon.Make(A.Position.Lat+(B.Position.Lat-A.Position.Lat)*T,
          A.Position.Lon+(B.Position.Lon-A.Position.Lon)*T);
      end;
      J:=FCellItems[J].Next;
    end;
  Result:=S.Valid;
end;
function TPlannerGraph.RouteLeg(const A,B:TPlannerSnap; out Points:TPlannerPoints; Cancel:TThread):Boolean;
type THeapItem=record Node:Integer; G,F:Double; end;
var Dist:array of Double; Prev,Chain:array of Integer; Heap:array of THeapItem;
    Count,I,J,N,E,Target,BestNode,Steps:Integer; H,Tmp:THeapItem;
    Best,Cost,EndCost:Double; SA,SB:TPlannerSegment;
  procedure Push(Node:Integer; G:Double);
  var K,Parent:Integer; Item:THeapItem;
  begin
    if G>=Dist[Node] then Exit;
    Dist[Node]:=G; Item.Node:=Node; Item.G:=G;
    Item.F:=G+PlannerDistance(FNodes[Node].Position,B.Position);
    if Count>=Length(Heap) then SetLength(Heap,Count*2+64);
    K:=Count; Inc(Count);
    while K>0 do begin Parent:=(K-1) div 2; if Heap[Parent].F<=Item.F then Break;
      Heap[K]:=Heap[Parent]; K:=Parent; end;
    Heap[K]:=Item;
  end;
  function Pop:THeapItem;
  var K,C:Integer;
  begin
    Result:=Heap[0]; Dec(Count); if Count=0 then Exit;
    Tmp:=Heap[Count]; K:=0;
    while K*2+1<Count do begin C:=K*2+1;
      if (C+1<Count) and (Heap[C+1].F<Heap[C].F) then Inc(C);
      if Heap[C].F>=Tmp.F then Break; Heap[K]:=Heap[C]; K:=C; end;
    Heap[K]:=Tmp;
  end;
begin
  Points:=nil; Result:=False; SA:=FSegments[A.Segment]; SB:=FSegments[B.Segment];
  Best:=1e100; BestNode:=-1;
  if (A.Segment=B.Segment) and (((B.T>=A.T) and SA.ForwardAllowed) or
    ((B.T<=A.T) and SA.BackwardAllowed)) then Best:=Abs(B.T-A.T)*SA.Cost;
  SetLength(Dist,FNodeCount); SetLength(Prev,FNodeCount);
  for I:=0 to FNodeCount-1 do begin Dist[I]:=1e100; Prev[I]:=-1; end;
  Count:=0;
  if SA.BackwardAllowed or (A.T<1e-8) then Push(SA.A,A.T*SA.Cost);
  if SA.ForwardAllowed or (A.T>1-1e-8) then Push(SA.B,(1-A.T)*SA.Cost);
  Steps:=0;
  while Count>0 do begin
    Inc(Steps); if (Steps mod 256=0) and (Cancel<>nil) and Cancel.CheckTerminated then Exit;
    H:=Pop; if H.G>Dist[H.Node]+1e-8 then Continue;
    if H.F>Best+1e-6 then Break;
    EndCost:=1e100;
    if (H.Node=SB.A) and (SB.ForwardAllowed or (B.T<1e-8)) then EndCost:=B.T*SB.Cost;
    if (H.Node=SB.B) and (SB.BackwardAllowed or (B.T>1-1e-8)) then EndCost:=Min(EndCost,(1-B.T)*SB.Cost);
    if H.G+EndCost<Best then begin Best:=H.G+EndCost; BestNode:=H.Node; end;
    E:=FNodes[H.Node].Head;
    while E>=0 do begin
      Target:=FArcs[E].Target; Cost:=H.G+FArcs[E].Cost;
      if Cost<Dist[Target] then begin Prev[Target]:=H.Node; Push(Target,Cost); end;
      E:=FArcs[E].Next;
    end;
  end;
  if Best>=1e99 then Exit;
  Chain:=nil; N:=0; I:=BestNode;
  while I>=0 do begin
    if N>=Length(Chain) then SetLength(Chain,N*2+32);
    Chain[N]:=I; Inc(N); I:=Prev[I]; if N>FNodeCount then Exit;
  end;
  SetLength(Points,N+2); Points[0]:=A.Position;
  for J:=0 to N-1 do Points[J+1]:=FNodes[Chain[N-1-J]].Position;
  Points[N+1]:=B.Position; Result:=True;
end;
function TPlannerGraph.Route(const Stops:TPlannerPoints; Loop:Boolean;
  out Points:TPlannerPoints; out ErrorText:string; Cancel:TThread):Boolean;
var Snaps:TPlannerSnaps; Leg:TPlannerPoints; I,J,K,N,Legs,Parts:Integer; L,T:Double;
  procedure Append(const P:TLatLon);
  begin
    if (N>0) and (PlannerDistance(Points[N-1],P)<0.02) then Exit;
    if N>=Length(Points) then SetLength(Points,N*2+128); Points[N]:=P; Inc(N);
  end;
begin
  Points:=nil; ErrorText:=''; Result:=False; N:=0;
  if Length(Stops)<2 then begin ErrorText:=UiText('Add at least two points'); Exit; end;
  SetLength(Snaps,Length(Stops));
  for I:=0 to High(Stops) do if not Snap(Stops[I],Snaps[I]) then begin
    ErrorText:=Format(UiText('No road found near point %d'),[I+1]); Exit; end;
  Legs:=Length(Stops)-1; if Loop then Inc(Legs);
  for I:=0 to Legs-1 do begin
    if (Cancel<>nil) and Cancel.CheckTerminated then Exit;
    if not RouteLeg(Snaps[I],Snaps[(I+1) mod Length(Stops)],Leg,Cancel) then begin
      Points:=nil; ErrorText:=Format(UiText('No road connection between points %d and %d'),[I+1,(I+1) mod Length(Stops)+1]); Exit; end;
    Append(Leg[0]);
    for J:=1 to High(Leg) do begin
      L:=PlannerDistance(Leg[J-1],Leg[J]); Parts:=Max(1,Ceil(L/5));
      for K:=1 to Parts do begin T:=K/Parts;
        Append(TLatLon.Make(Leg[J-1].Lat+(Leg[J].Lat-Leg[J-1].Lat)*T,
          Leg[J-1].Lon+(Leg[J].Lon-Leg[J-1].Lon)*T)); end;
    end;
  end;
  SetLength(Points,N); Result:=N>=2;
  if not Result then ErrorText:=UiText('Route points coincide');
end;
procedure SavePlannerGPX(const FileName,Title:string; const Points,Stops:TPlannerPoints; Loop:Boolean);
var S:TStringList; I:Integer; FS:TFormatSettings;
  function Esc(const V:string):string;
  begin Result:=StringReplace(V,'&','&amp;',[rfReplaceAll]);
    Result:=StringReplace(Result,'<','&lt;',[rfReplaceAll]); Result:=StringReplace(Result,'>','&gt;',[rfReplaceAll]); end;
  function LL(const P:TLatLon):string;
  begin Result:='lat="'+FloatToStrF(P.Lat,ffFixed,15,7,FS)+'" lon="'+FloatToStrF(P.Lon,ffFixed,15,7,FS)+'"'; end;
begin
  if Length(Points)<2 then raise Exception.Create(UiText('The route has not been calculated yet'));
  if FileExists(FileName) then raise Exception.Create(UiText('A file with this name already exists'));
  FS:=DefaultFormatSettings; FS.DecimalSeparator:='.'; S:=TStringList.Create;
  try
    S.Add('<?xml version="1.0" encoding="UTF-8"?>');
    S.Add('<gpx version="1.1" creator="REZVIVO" xmlns="http://www.topografix.com/GPX/1/1" xmlns:rezvivo="https://rezvivo.com/gpx/1">');
    S.Add('<metadata><name>'+Esc(Title)+'</name></metadata>');
    for I:=0 to High(Stops) do S.Add('<wpt '+LL(Stops[I])+'><name>'+IntToStr(I+1)+'</name></wpt>');
    S.Add('<trk><name>'+Esc(Title)+'</name><extensions><rezvivo:loop>'+LowerCase(BoolToStr(Loop,True))+'</rezvivo:loop></extensions><trkseg>');
    for I:=0 to High(Points) do S.Add('<trkpt '+LL(Points[I])+'/>');
    S.Add('</trkseg></trk></gpx>');
    ForceDirectories(ExtractFileDir(FileName)); S.SaveToFile(FileName+'.tmp');
    if not RenameFile(FileName+'.tmp',FileName) then raise Exception.Create(UiText('Could not save the route'));
  finally S.Free; end;
end;
end.
