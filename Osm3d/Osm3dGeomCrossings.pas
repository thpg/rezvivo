unit Osm3dGeomCrossings;
{$mode objfpc}{$H+}
interface
uses CastleVectors, Osm3dOsmData, Osm3dGeoMath, Osm3dGeomMesh,
  Osm3dGeomRoads, Osm3dGroundComposite, Osm3dGroundSurfaceQuery;
type
  TCrossingStats = record Crossings, Signs, Bumps:Integer end;
{ Builds one atlas batch. Physical bump surfaces join the existing ground
  composite, so both CPU and GPU wheel contact use exactly the baked shape.
  Query is created lazily and owned by the caller, for reuse by manholes. }
function BuildCrossings(Data:TOSMDataset; Proj:TLocalProjection;
  const Roads:TRoadCenterlineSegArray; Ground:TGroundCompositeMesh;
  out Stats:TCrossingStats; var Query:TGroundSurfaceQuery):TMesh;
implementation
uses Osm3dGenerationProgress, SysUtils, Math, Generics.Collections,
  Osm3dRoadFurniture, Osm3dRoadCurbs, Osm3dRoadSurface,Osm3dOsmTagUtils;
type
  TIntList = specialize TList<Integer>;
  TGrid = specialize TObjectDictionary<Int64,TIntList>;
  TCrossing = record
    Center,Along,Across:TVector3;
    Width,Depth:Single;
    RoadId,SourceId:Int64;
    PhotoLocated:Boolean;
  end;
  TQuad = array[0..3] of TVector3;
const GRID=64.0;BUMP_LENGTH_M=1.0;BUMP_ROAD_CLEARANCE=0.15;
function Key(X,Z:Integer):Int64;
begin Result:=Int64((QWord(LongWord(X)) shl 32) or LongWord(Z)) end;
function AtGrade(Tags:TOSMTags):Boolean;
begin Result:=(Tags.Get('bridge','no')='no') and (Tags.Get('tunnel','no')='no') end;
function CrossingTags(Tags:TOSMTags):Boolean;
begin
  Result:=AtGrade(Tags) and (Tags.Get('crossing')<>'no') and
    (Tags.Get('foot')<>'no') and ((Tags.Get('highway')='crossing') or
    (Tags.Get('footway')='crossing') or (Tags.Get('path')='crossing'));
end;
function Cross2(const A,B:TVector3):Single;
begin Result:=A.X*B.Z-A.Z*B.X end;
function RoadSurface(const H:TSurfaceHit):Boolean;
begin Result:=(H.MaterialId in [12,13,14,16,17,18,19,24,25,26,27,28,29]) and
  (H.Owner<>ROAD_CURB_OWNER) and (H.Normal.Y>0.8) end;
function BuildCrossings(Data:TOSMDataset; Proj:TLocalProjection;
  const Roads:TRoadCenterlineSegArray; Ground:TGroundCompositeMesh;
  out Stats:TCrossingStats; var Query:TGroundSurfaceQuery):TMesh;
var
  RoadGrid,PlacedGrid:TGrid;Candidates:array of TCrossing;
  RoadOK:array of Boolean;W:TOSMWay;Node,N0,N1:TOSMNode;RP:TRoadParams;
  I,J,K,X,Z,CX,CZ,Best:Integer;L:TIntList;P,A,B,D,Q:TVector3;
  C:TCrossing;F,T,U,Dist,BestDist,Span,Lo,Hi:Single;Hit:TSurfaceHit;
  HasBumpBefore,HasBumpAfter:Boolean;
  PhotoSigns:array of TOSMNode;

  procedure Insert(G:TGrid; X,Z,Value:Integer);
  var Items:TIntList; Id:Int64;
  begin
    Id:=Key(X,Z);
    if not G.TryGetValue(Id,Items) then begin Items:=TIntList.Create;G.Add(Id,Items) end;
    Items.Add(Value);
  end;
  procedure AddCandidate(Seg:Integer; const Position,FootDirection:TVector3; Source:Int64);
  var NewC:TCrossing;GX,GZ,Id:Integer;Items:TIntList;DotAcross:Single;
  begin
    if not Query.Sample(Position.X,Position.Z,Hit) or not RoadSurface(Hit) then Exit;
    NewC:=Default(TCrossing);NewC.Center:=Hit.Position;
    NewC.Along:=Vector3(Roads[Seg].X1-Roads[Seg].X0,0,Roads[Seg].Z1-Roads[Seg].Z0).Normalize;
    NewC.Across:=Vector3(NewC.Along.Z,0,-NewC.Along.X);
    NewC.Width:=RoadWidthAtPoint(Roads[Seg].Surface,Roads[Seg].Width,
      Roads[Seg].X0,Roads[Seg].Z0,Roads[Seg].X1,Roads[Seg].Z1,Position.X,Position.Z);NewC.Depth:=4;
    NewC.RoadId:=Roads[Seg].WayId;NewC.SourceId:=Source;
    if Data.FindNode(Source)<>nil then NewC.PhotoLocated:=Data.FindNode(Source).Tags.HasKey('rezvivo:photo_crossing');
    { Keep skew crossings on their mapped footway, while stripes remain
      parallel to vehicle travel. Reject a nearly parallel footpath. }
    if FootDirection.Length>0.01 then begin
      DotAcross:=TVector3.DotProduct(FootDirection,NewC.Across);
      if Abs(DotAcross)<0.35 then Exit;
      NewC.Across:=NewC.Across+NewC.Along*
        (TVector3.DotProduct(FootDirection,NewC.Along)/DotAcross);
    end;
    for GZ:=Floor((Position.Z-3)/GRID) to Floor((Position.Z+3)/GRID) do
      for GX:=Floor((Position.X-3)/GRID) to Floor((Position.X+3)/GRID) do
        if PlacedGrid.TryGetValue(Key(GX,GZ),Items) then for Id in Items do
          if (Candidates[Id].Center-NewC.Center).Length<3 then
            if Abs(TVector3.DotProduct(Candidates[Id].Along,NewC.Along))>0.8 then Exit;
    Id:=Length(Candidates);SetLength(Candidates,Id+1);Candidates[Id]:=NewC;
    Insert(PlacedGrid,Floor(Position.X/GRID),Floor(Position.Z/GRID),Id);
  end;
  procedure AddQuad(const V:TQuad; Cell:Integer; Up:Boolean; SwapUV:Boolean=False);
  var N:TVector3;Base,J:Integer;
  const US:array[0..3]of Single=(0,0,1,1);VS:array[0..3]of Single=(0,1,1,0);
  begin
    N:=TVector3.CrossProduct(V[1]-V[0],V[2]-V[0]).Normalize;
    if Up and (N.Y<0) then N:=-N;
    Base:=Result.VertexCount;
    for J:=0 to 3 do
      if SwapUV then Result.AddVertex(V[J],N,RoadFurnitureUV(Cell,VS[J],US[J]))
      else Result.AddVertex(V[J],N,RoadFurnitureUV(Cell,US[J],VS[J]));
    Result.AddQuad(Base,Base+1,Base+2,Base+3);
  end;
  function OnRoad(const Pos:TVector3; out H:TSurfaceHit):Boolean;
  begin
    Result:=Query.Sample(Pos.X,Pos.Z,H) and RoadSurface(H) and
      (Abs(H.Position.Y-C.Center.Y)<2.5);
  end;
  procedure PaintStrip(B0,B1:Single);
  var V:TQuad;H:TSurfaceHit;J,Row,Rows:Integer;A0,A1:Single;
  const ASide:array[0..3]of Integer=(0,0,1,1);
        BSide:array[0..3]of Integer=(0,1,1,0);
  begin
    { Subdivision follows the finished road camber/grade. No full rectangle
      floats across a pavement edge or a change of terrain slope. }
    Rows:=Ceil(C.Depth/0.5);
    for Row:=0 to Rows-1 do begin
      A0:=-C.Depth*0.5+C.Depth*Row/Rows;A1:=-C.Depth*0.5+C.Depth*(Row+1)/Rows;
      for J:=0 to 3 do begin
        V[J]:=C.Center+C.Along*(A0+(A1-A0)*ASide[J])+C.Across*(B0+(B1-B0)*BSide[J]);
        if not OnRoad(V[J],H) then Break;
        V[J]:=H.Position;V[J].Y:=V[J].Y+0.009;
      end;
      if J=3 then begin
        if not OnRoad(V[3],H) then Continue;
        AddQuad(V,SIGN_WHITE,True);
      end;
    end;
  end;
  function TryBump(Offset:Single):Boolean;
  const ROWS=8;HEIGHT_M=0.075;
  var Hits:array of TSurfaceHit;Vertices:array of TVector3;BaseIdx:array of Integer;
    Col,Row,Cols,Idx,J,Cell,BI:Integer;AlongPos,AcrossPos,Rise,Slope:Single;
    V:TQuad;MV:TMeshVertex;N,Right:TVector3;
  begin
    Result:=False;
    Right:=Vector3(C.Along.Z,0,-C.Along.X);Cols:=Max(1,Ceil((C.Width-0.4)/0.5));
    SetLength(Hits,(Cols+1)*(ROWS+1));SetLength(Vertices,Length(Hits));
    SetLength(BaseIdx,Length(Hits));
    for Row:=0 to ROWS do for Col:=0 to Cols do begin
      Idx:=Row*(Cols+1)+Col;
      AlongPos:=Offset-BUMP_LENGTH_M*0.5+BUMP_LENGTH_M*Row/ROWS;
      AcrossPos:=(Col/Cols-0.5)*(C.Width-0.4);
      P:=C.Center+C.Along*AlongPos+Right*AcrossPos;
      if not OnRoad(P,Hits[Idx]) then Exit; { never leave a half-built hump }
      Rise:=HEIGHT_M*Sqr(Sin(Pi*Row/ROWS));
      Vertices[Idx]:=Hits[Idx].Position;Vertices[Idx].Y:=Vertices[Idx].Y+Rise+0.001;
    end;
    for Row:=0 to ROWS do for Col:=0 to Cols do begin
      Idx:=Row*(Cols+1)+Col;
      Slope:=HEIGHT_M*Pi/BUMP_LENGTH_M*Sin(2*Pi*Row/ROWS);
      N:=(Hits[Idx].Normal-C.Along*Slope).Normalize;
      MV:=MakeVertex2(Vertices[Idx],N);MV.UV:=Hits[Idx].UV;MV.OsmId:=ROAD_BUMP_OWNER;
      BaseIdx[Idx]:=Ground.AppendVertex(MV,Hits[Idx].MaterialId);
    end;
    for Row:=0 to ROWS-1 do for Col:=0 to Cols-1 do begin
      Idx:=Row*(Cols+1)+Col;
      { Along x Right winds upward for this coordinate convention. }
      Ground.AppendTriangle(BaseIdx[Idx],BaseIdx[Idx+Cols+1],BaseIdx[Idx+Cols+2]);
      Ground.AppendTriangle(BaseIdx[Idx],BaseIdx[Idx+Cols+2],BaseIdx[Idx+1]);
      V[0]:=Vertices[Idx];V[1]:=Vertices[Idx+Cols+1];
      V[2]:=Vertices[Idx+Cols+2];V[3]:=Vertices[Idx+1];
      for J:=0 to 3 do V[J].Y:=V[J].Y+0.003;
      if Col mod 2=0 then Cell:=SIGN_RUBBER else Cell:=SIGN_YELLOW;
      AddQuad(V,Cell,True);
    end;
    Inc(Stats.Bumps);
    Result:=True;
  end;
  function BumpOverlapsOtherRoad(Offset:Single):Boolean;
  const HALF_LENGTH=BUMP_LENGTH_M*0.5;
  var Center,Right,SegStart,SegAlong,SegRight,Delta:TVector3;
    HalfWidth,HalfSeg,HalfRoad,RX,RZ,Len:Single;
    GX,GZ,Id:Integer;Items:TIntList;
    function Separated(const Axis:TVector3):Boolean;
    begin
      Result:=Abs(TVector3.DotProduct(Delta,Axis))>
        HALF_LENGTH*Abs(TVector3.DotProduct(C.Along,Axis))+
        HalfWidth*Abs(TVector3.DotProduct(Right,Axis))+
        HalfSeg*Abs(TVector3.DotProduct(SegAlong,Axis))+
        HalfRoad*Abs(TVector3.DotProduct(SegRight,Axis));
    end;
  begin
    Result:=False;Center:=C.Center+C.Along*Offset;
    Right:=Vector3(C.Along.Z,0,-C.Along.X);HalfWidth:=(C.Width-0.4)*0.5;
    RX:=Abs(C.Along.X)*HALF_LENGTH+Abs(Right.X)*HalfWidth;
    RZ:=Abs(C.Along.Z)*HALF_LENGTH+Abs(Right.Z)*HalfWidth;
    for GZ:=Floor((Center.Z-RZ)/GRID) to Floor((Center.Z+RZ)/GRID) do
      for GX:=Floor((Center.X-RX)/GRID) to Floor((Center.X+RX)/GRID) do
        if RoadGrid.TryGetValue(Key(GX,GZ),Items) then for Id in Items do begin
          if Roads[Id].WayId=C.RoadId then Continue;
          SegStart:=Vector3(Roads[Id].X0,0,Roads[Id].Z0);
          SegAlong:=Vector3(Roads[Id].X1-Roads[Id].X0,0,Roads[Id].Z1-Roads[Id].Z0);
          Len:=SegAlong.Length;if Len<0.001 then Continue;
          SegAlong:=SegAlong/Len;SegRight:=Vector3(SegAlong.Z,0,-SegAlong.X);
          { A straight road may be split into OSM ways at a tag change. Such a
            continuation is not a junction, even though its way id differs. }
          if (Abs(Cross2(SegAlong,C.Along))<0.001) and
            (Abs(TVector3.DotProduct(SegStart-C.Center,Right))<0.05) then Continue;
          HalfSeg:=Len*0.5+BUMP_ROAD_CLEARANCE;
          HalfRoad:=Roads[Id].Width*0.5+BUMP_ROAD_CLEARANCE;
          Delta:=SegStart+SegAlong*(Len*0.5)-Center;
          { Four separating axes test the entire hump, including a corner
            entering a skew junction or a wide road whose axis is outside it. }
          if not Separated(C.Along) and not Separated(Right) and
            not Separated(SegAlong) and not Separated(SegRight) then Exit(True);
        end;
  end;
  function Bump(Offset:Single):Boolean;
  var Step:Integer;Position:Single;
  begin
    Result:=False;
    { A bump entering another road is omitted, not moved into the junction.
      Only missing ground support may shorten an otherwise clear approach. }
    for Step:=0 to 4 do begin
      Position:=Offset-Sign(Offset)*Step*0.5;
      if BumpOverlapsOtherRoad(Position) then Exit;
      if TryBump(Position) then Exit(True);
    end;
  end;
  procedure Board(const Center,Right,Facing:TVector3; Size:Single;Front,Back:Integer);
  var V:TQuad;Up,P0:TVector3;J:Integer;
  begin
    Up:=Vector3(0,Size*0.5,0);P0:=Center+Facing*0.045;
    V[0]:=P0-Right*(Size*0.5)-Up;V[1]:=P0+Right*(Size*0.5)-Up;
    V[2]:=P0+Right*(Size*0.5)+Up;V[3]:=P0-Right*(Size*0.5)+Up;
    AddQuad(V,Front,False,True);
    P0:=Center-Facing*0.045;
    V[0]:=P0+Right*(Size*0.5)-Up;V[1]:=P0-Right*(Size*0.5)-Up;
    V[2]:=P0-Right*(Size*0.5)+Up;V[3]:=P0+Right*(Size*0.5)+Up;
    AddQuad(V,Back,False,True);
  end;
  procedure Post(const Base:TVector3);
  var J:Integer;A0,A1:Single;V:TQuad;
  begin
    for J:=0 to 7 do begin
      A0:=J*Pi/4;A1:=(J+1)*Pi/4;
      V[0]:=Base+Vector3(Cos(A1)*0.035,0,Sin(A1)*0.035);
      V[1]:=Base+Vector3(Cos(A0)*0.035,0,Sin(A0)*0.035);
      V[2]:=V[1]+Vector3(0,2.9,0);V[3]:=V[0]+Vector3(0,2.9,0);
      AddQuad(V,SIGN_METAL,False);
    end;
  end;
  procedure PhotoSign(Node:TOSMNode);
  var Base,Right,Facing:TVector3;H:TSurfaceHit;Angle:Double;Cell:Integer;Kind:string;
  begin
    Base:=NodePlanePos(Data,Node,Proj);
    if not Query.Sample(Base.X,Base.Z,H) or RoadSurface(H) then Exit;
    Base:=H.Position;Angle:=DegToRad(ParseOSMMeters(Node.Tags.Get('direction')));
    Facing:=Vector3(-Sin(Angle),0,Cos(Angle));Right:=Vector3(Facing.Z,0,-Facing.X);
    Kind:=Node.Tags.Get('rezvivo:photo_sign');
    if Kind='crossing_right' then Cell:=SIGN_CROSSING_RIGHT
    else if Kind='crossing_left' then Cell:=SIGN_CROSSING_LEFT
    else if Kind='bump_warning' then Cell:=SIGN_BUMP_WARNING else Cell:=SIGN_BUMP;
    Result.CurrentOsmId:=Node.Id;Post(Base);
    Board(Base+Vector3(0,2.5,0),Right,Facing,0.8,Cell,SIGN_METAL);Inc(Stats.Signs);
  end;
  procedure Sign(Side:Integer;HasBump:Boolean);
  var Base,Right,Facing,BoardP:TVector3;H:TSurfaceHit;V:TQuad;
    J,ForwardStep,SideStep:Integer;A0,A1:Single;Found:Boolean;
  begin
    Right:=Vector3(C.Along.Z,0,-C.Along.X);Facing:=C.Along*Side;
    Found:=False;
    { At junctions the nominal verge may lie on the OTHER road. Search the
      nearby pavement/verge, never plant a post in a vehicle travel lane. }
    for ForwardStep:=0 to 8 do begin
      for SideStep:=0 to 5 do begin
        Base:=C.Center+C.Along*(Side*(C.Depth*0.5+0.35+ForwardStep*0.8))+
          C.Across*(Side*(C.Width*0.5+0.65+SideStep*0.5));
        if not Query.Sample(Base.X,Base.Z,H) then Continue;
        if H.MaterialId in [13,15,16,17,18,19,20,24,25,26,27,29,30] then Continue;
        if Abs(H.Position.Y-C.Center.Y)>1.5 then Continue;
        Found:=True;Break;
      end;
      if Found then Break;
    end;
    if not Found then Exit;
    Base:=H.Position;Result.CurrentOsmId:=C.SourceId;
    for J:=0 to High(PhotoSigns) do begin
      BoardP:=NodePlanePos(Data,PhotoSigns[J],Proj);
      if Sqr(BoardP.X-Base.X)+Sqr(BoardP.Z-Base.Z)<16 then Exit; { one observed support replaces the inferred one }
    end;
    { Eight-sided post, 7 cm diameter; all sign geometry shares the atlas. }
    Post(Base);
    BoardP:=Base+Vector3(0,2.5,0);
    Board(BoardP,Right*Side,Facing,0.8,SIGN_CROSSING_RIGHT,SIGN_CROSSING_LEFT);
    if HasBump then begin
      BoardP:=Base+Vector3(0,1.8,0);
      Board(BoardP,Right*Side,Facing,0.5,SIGN_BUMP,SIGN_BUMP);
    end;
    Inc(Stats.Signs);
  end;
begin
  Result:=nil;Stats:=Default(TCrossingStats);
  if (Data=nil)or(Proj=nil)or(Ground=nil)or(Ground.TriangleCount=0) then Exit;
  RoadGrid:=TGrid.Create([doOwnsValues]);PlacedGrid:=TGrid.Create([doOwnsValues]);
  try
    SetLength(RoadOK,Length(Roads));
    for I:=0 to High(Roads) do begin
      W:=Data.FindWay(Roads[I].WayId);if (W=nil)or Roads[I].IsBridge then Continue;
      RP:=TRoadBuilder.ParseRoadParams(W.Tags);
      if not(RP.Kind in [rkMajor,rkSecondary,rkMinor,rkService]) or not AtGrade(W.Tags) then Continue;
      if Roads[I].Width<=0 then Continue;
      RoadOK[I]:=(Pos('motorway',W.Tags.Get('highway'))<>1) and
        (Roads[I].Width>=2) and (Roads[I].Width<=40);
      { Index full road widths, including roads that cannot host a crossing.
        Otherwise a wide adjacent carriageway can be missed across a grid edge. }
      F:=Roads[I].Width*0.5+BUMP_ROAD_CLEARANCE;
      for Z:=Floor((Min(Roads[I].Z0,Roads[I].Z1)-F)/GRID) to Floor((Max(Roads[I].Z0,Roads[I].Z1)+F)/GRID) do
        for X:=Floor((Min(Roads[I].X0,Roads[I].X1)-F)/GRID) to Floor((Max(Roads[I].X0,Roads[I].X1)+F)/GRID) do
          Insert(RoadGrid,X,Z,I);
    end;
    for Node in Data.Nodes.Values do if Node.Tags.HasKey('rezvivo:photo_sign') then begin
      I:=Length(PhotoSigns);SetLength(PhotoSigns,I+1);PhotoSigns[I]:=Node;
    end;
    if (RoadGrid.Count=0) and (Length(PhotoSigns)=0) then Exit;
    if Query=nil then Query:=TGroundSurfaceQuery.Create(Ground)
    else Query.IncludeAppended;
    GenerationProgress('Crossings',0,0);
    { Ways first: retain the mapped crossing angle when a node also exists. }
    for W in Data.Ways.Values do if CrossingTags(W.Tags) then
      for I:=1 to High(W.NodeRefs) do begin
        N0:=Data.FindNode(W.NodeRefs[I-1]);N1:=Data.FindNode(W.NodeRefs[I]);
        if (N0=nil)or(N1=nil) then Continue;
        A:=NodePlanePos(Data,N0,Proj);B:=NodePlanePos(Data,N1,Proj);D:=B-A;
        if D.Length<0.01 then Continue;
        for Z:=Floor(Min(A.Z,B.Z)/GRID) to Floor(Max(A.Z,B.Z)/GRID) do
          for X:=Floor(Min(A.X,B.X)/GRID) to Floor(Max(A.X,B.X)/GRID) do
            if RoadGrid.TryGetValue(Key(X,Z),L) then for J in L do begin
              if not RoadOK[J] then Continue;
              P:=Vector3(Roads[J].X0,0,Roads[J].Z0);
              Q:=Vector3(Roads[J].X1-Roads[J].X0,0,Roads[J].Z1-Roads[J].Z0);
              F:=Cross2(D,Q);if Abs(F)<1e-6 then Continue;
              T:=Cross2(P-A,Q)/F;U:=Cross2(P-A,D)/F;
              if (T< -0.0001)or(T>1.0001)or(U< -0.0001)or(U>1.0001) then Continue;
              AddCandidate(J,A+D*T,D.Normalize,W.Id);
            end;
      end;
    for Node in Data.Nodes.Values do if CrossingTags(Node.Tags) then begin
      P:=NodePlanePos(Data,Node,Proj);Best:=-1;BestDist:=4;
      for Z:=Floor((P.Z-2)/GRID) to Floor((P.Z+2)/GRID) do
        for X:=Floor((P.X-2)/GRID) to Floor((P.X+2)/GRID) do
          if RoadGrid.TryGetValue(Key(X,Z),L) then for J in L do begin
            if not RoadOK[J] then Continue;
            A:=Vector3(Roads[J].X0,0,Roads[J].Z0);
            D:=Vector3(Roads[J].X1-Roads[J].X0,0,Roads[J].Z1-Roads[J].Z0);
            F:=TVector3.DotProduct(D,D);if F<1e-8 then Continue;
            T:=EnsureRange(TVector3.DotProduct(P-A,D)/F,0.0,1.0);
            Q:=A+D*T;Dist:=Sqr(Q.X-P.X)+Sqr(Q.Z-P.Z);
            if (Dist<BestDist)or((Dist=BestDist)and((Best<0)or(Roads[J].WayId<Roads[Best].WayId))) then begin
              Best:=J;BestDist:=Dist;B:=Q;
            end;
          end;
      if Best>=0 then AddCandidate(Best,B,Vector3(0,0,0),Node.Id);
    end;
    if (Length(Candidates)=0) and (Length(PhotoSigns)=0) then Exit;
    Result:=TMesh.Create('road_furniture');
    try
    for I:=0 to High(PhotoSigns) do PhotoSign(PhotoSigns[I]);
    for I:=0 to High(Candidates) do begin
      CheckGenerationCancelled;
      GenerationProgress('Crossings', I, Length(Candidates));
      C:=Candidates[I];Result.CurrentOsmId:=C.SourceId;
      Span:=C.Width-0.4;K:=Max(1,Floor(Span));
      for J:=0 to K-1 do begin
        Lo:=(J-K*0.5)*1.0+0.25;Hi:=Lo+0.5;
        PaintStrip(Lo,Hi);
      end;
      HasBumpBefore:=False;HasBumpAfter:=False;
      if not C.PhotoLocated then begin
        HasBumpBefore:=Bump(-C.Depth*0.5-3);HasBumpAfter:=Bump(C.Depth*0.5+3);
      end; { a photographed zebra is not evidence of speed bumps }
      Sign(-1,HasBumpBefore);Sign(1,HasBumpAfter);
      Inc(Stats.Crossings);
    end;
    GenerationProgress('Crossings', Length(Candidates), Length(Candidates));
    Result.MakeWindingMatchNormals;
    except FreeAndNil(Result); raise end;
  finally PlacedGrid.Free;RoadGrid.Free end;
end;
end.
