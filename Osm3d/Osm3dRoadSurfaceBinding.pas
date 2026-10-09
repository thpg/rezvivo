unit Osm3dRoadSurfaceBinding;

{$mode objfpc}{$H+}{$Q-}{$R-}

interface

uses Osm3dStaticGeometry, CastleVectors, X3DNodes, Osm3dGroundComposite, Osm3dTileX3D;

procedure AttachRoadSurface(Geo: TIndexedFaceSetNode;
  Composite: TGroundCompositeMesh; Model: TTileModel;
  const TileOrigin: TVector3; EastScale: Single; AreaCondition: Integer = 0);

implementation

uses SysUtils, Math, Generics.Collections, Osm3dRoadSurface,
  Osm3dRoadMaterial, Osm3dGeomRoads, Osm3dRoadCurbs, Osm3dRoadPuddles;

type
  TWayInfo = record
    Width, MinUV, MaxUV: Single;
    Surface: TRoadSurfaceProfile;
    Handle: Integer;
    Seed: Single;
    MatId: Integer;
    FirstSegment:Integer;
  end;

// Old carve caches kept metric UVs but lost the road ID. Recover one owner
// per connected UV island, never interpolate unrelated profile handles inside
// a triangle. New caches retain the original owner and skip this step.
type TRoadOwnerArray = array of Int64;

function SurfaceOwners(Composite:TGroundCompositeMesh; Model:TTileModel;
  const TileOrigin:TVector3; EastScale:Single):TRoadOwnerArray;
type TIntArray=array of Integer;
var Parent:TIntArray; Area:array of Single; Centers:array of TVector3;
  I,J,A,B,C,R,Mat:Integer; P,Q,T,V:TVector3; Seg:TTileRoadSeg;
  ar,dx,dz,k,dist,best:Single;
  function Root(N:Integer):Integer;
  begin
    while Parent[N]<>N do begin Parent[N]:=Parent[Parent[N]]; N:=Parent[N] end;
    Result:=N;
  end;
begin
  SetLength(Result,Composite.VertexCount); SetLength(Parent,Length(Result));
  SetLength(Area,Length(Result)); SetLength(Centers,Length(Result));
  for I:=0 to High(Result) do begin Result[I]:=Composite.OsmIdOf(I); Parent[I]:=I end;
  for I:=0 to Composite.TriangleCount-1 do
  begin
    A:=Composite.Indices[I*3]; B:=Composite.Indices[I*3+1]; C:=Composite.Indices[I*3+2];
    Mat:=Composite.MatIdOf(A);
    if (Mat<24) or (Mat>29) or (Result[A]<>0) or (Result[B]<>0) or (Result[C]<>0) then Continue;
    Parent[Root(B)]:=Root(A); Parent[Root(C)]:=Root(A);
  end;
  for I:=0 to Composite.TriangleCount-1 do
  begin
    A:=Composite.Indices[I*3]; B:=Composite.Indices[I*3+1]; C:=Composite.Indices[I*3+2];
    Mat:=Composite.MatIdOf(A);
    if (Mat<24) or (Mat>29) or (Result[A]<>0) then Continue;
    R:=Root(A); P:=Composite.PositionOf(A); Q:=Composite.PositionOf(B); T:=Composite.PositionOf(C);
    ar:=Abs((Q.X-P.X)*(T.Z-P.Z)-(Q.Z-P.Z)*(T.X-P.X));
    if ar>Area[R] then begin Area[R]:=ar; Centers[R]:=(P+Q+T)/3 end;
  end;
  if Model<>nil then
    for I:=0 to High(Result) do
      if (Parent[I]=I) and (Area[I]>0) then
      begin
        P:=Centers[I]-TileOrigin; P.X:=P.X/EastScale; best:=1e20;
        for J:=0 to Model.RoadSegCount-1 do
        begin
          Seg:=Model.RoadSegs[J];
          if Seg.IsBridge then Continue;
          dx:=Seg.X1-Seg.X0; dz:=Seg.Z1-Seg.Z0;
          k:=EnsureRange(((P.X-Seg.X0)*dx+(P.Z-Seg.Z0)*dz)/Max(dx*dx+dz*dz,0.0001),0.0,1.0);
          V:=Vector3(P.X-Seg.X0-dx*k,0,P.Z-Seg.Z0-dz*k);
          dist:=Sqrt(V.X*V.X+V.Z*V.Z);
          if (dist<best) and (dist<Seg.Width*0.5+1.5) then
          begin best:=dist; Result[I]:=Seg.WayId end;
        end;
      end;
  for I:=0 to High(Result) do
    if Result[I]=0 then Result[I]:=Result[Root(I)];
end;

// Separating-axis test: no cache requests for empty corners of a large
// asphalt triangle's bounding box. Coordinates are session-world XZ.
function OverlapsCell(const A,B,C:TVector3; X0,Z0,X1,Z1:Single):Boolean;
var P,Q:TVector3; E:Integer; NX,NZ,D,Lo,Hi:Single;
begin
  if (Max(A.X,Max(B.X,C.X))<X0) or (Min(A.X,Min(B.X,C.X))>X1) or
     (Max(A.Z,Max(B.Z,C.Z))<Z0) or (Min(A.Z,Min(B.Z,C.Z))>Z1) then Exit(False);
  for E:=0 to 2 do
  begin
    case E of 0:begin P:=A; Q:=B end; 1:begin P:=B; Q:=C end; else begin P:=C; Q:=A end end;
    NX:=Q.Z-P.Z; NZ:=P.X-Q.X;
    D:=NX*(C.X-P.X)+NZ*(C.Z-P.Z);
    if E=1 then D:=NX*(A.X-P.X)+NZ*(A.Z-P.Z);
    if E=2 then D:=NX*(B.X-P.X)+NZ*(B.Z-P.Z);
    Lo:=Min(NX*(X0-P.X),NX*(X1-P.X))+Min(NZ*(Z0-P.Z),NZ*(Z1-P.Z));
    Hi:=Max(NX*(X0-P.X),NX*(X1-P.X))+Max(NZ*(Z0-P.Z),NZ*(Z1-P.Z));
    if ((D>0) and (Hi<0)) or ((D<0) and (Lo>0)) then Exit(False);
  end;
  Result:=True;
end;

procedure AttachRoadSurface(Geo: TIndexedFaceSetNode;
  Composite: TGroundCompositeMesh; Model: TTileModel;
  const TileOrigin: TVector3; EastScale: Single; AreaCondition: Integer);
var
  Owners: TRoadOwnerArray;
  Ways: specialize TDictionary<Int64,TWayInfo>;
  RequestsByKey: specialize TDictionary<QWord,Integer>;
  Pair: specialize TPair<Int64,TWayInfo>;
  Keys: array of Int64;
  NextSegment:array of Integer;
  W: TWayInfo; Seg: TTileRoadSeg;
  I,K,M,RI,Block,N,F,B,Tri,E,V0,V1,Profile,AreaRow,V2: Integer;
  Id: Int64; Key:QWord;
  UV:TVector2; P:TVector3;
  T,S,Span,MinS,MaxS,S0,S1,DS,Lo,Hi:Single;
  ActualWidth,BestDistance,Distance,DX,DZ,Along:Single;
  LocalP:TVector3; SegmentIndex:Integer;
  EdgeStart,EdgeEnd,AreaA,AreaB,AreaC:TVector3;
  MinT,MaxT:Single;
  Coord,Style:array of Single;
  Requests:TRoadPageRequests;
  RequestCount:Integer;
  R:TRoadPageRequest;
  A:TRoadCoordAttribute;
  SA:TFloatVertexAttributeNode;
  Puddles:TRoadPuddleCollector;
  procedure RequestPoint(AProfile,ABlock:Integer; const AP:TVector3);
  begin
    Key:=(QWord(AProfile) shl 32) or LongWord(ABlock);
    if RequestsByKey.TryGetValue(Key,RI) then
    begin
      Requests[RI].MinX:=Min(Requests[RI].MinX,AP.X);
      Requests[RI].MaxX:=Max(Requests[RI].MaxX,AP.X);
      Requests[RI].MinZ:=Min(Requests[RI].MinZ,AP.Z);
      Requests[RI].MaxZ:=Max(Requests[RI].MaxZ,AP.Z);
    end else
    begin
      R.Profile:=AProfile; R.Block:=ABlock;
      R.MinX:=AP.X; R.MaxX:=AP.X; R.MinZ:=AP.Z; R.MaxZ:=AP.Z;
      RI:=RequestCount;Inc(RequestCount);
      if RequestCount>Length(Requests) then SetLength(Requests,Max(64,Length(Requests)*2));
      Requests[RI]:=R;
      RequestsByKey.Add(Key,RI);
    end;
  end;
begin
  if (Geo=nil) or (Composite=nil) then Exit;
  RequestCount:=0;
  Owners:=SurfaceOwners(Composite,Model,TileOrigin,EastScale);
  Ways:=specialize TDictionary<Int64,TWayInfo>.Create;
  RequestsByKey:=specialize TDictionary<QWord,Integer>.Create;
  Puddles:=TRoadPuddleCollector.Create;
  try
    if Model<>nil then SetLength(NextSegment,Model.RoadSegCount);
    if Model<>nil then
      for I:=0 to Model.RoadSegCount-1 do
      begin
        Seg:=Model.RoadSegs[I];
        if Ways.TryGetValue(Seg.WayId,W) then begin
          NextSegment[I]:=W.FirstSegment;W.FirstSegment:=I;Ways[Seg.WayId]:=W;Continue;
        end;
        W:=Default(TWayInfo);
        W.Width:=Seg.Width;
        W.MinUV:=1e20; W.MaxUV:=-1e20;
        W.Surface:=Seg.Surface;W.FirstSegment:=I;NextSegment[I]:=-1;
        if (Seg.Surface.WidthStart>0) and (Seg.Surface.Layout.Count>0) then begin
          W.Width:=2*Seg.Surface.Layout.Edge;
          for K:=0 to Seg.Surface.Layout.Count-1 do W.Width+=Seg.Surface.Layout.Widths[K];
        end;
        Ways.Add(Seg.WayId,W);
      end;
    for I:=0 to Composite.VertexCount-1 do
    begin
      M:=Composite.MatIdOf(I);
      if (M<24) or (M>29) or (Composite.OsmIdOf(I)=ROAD_CURB_OWNER) then Continue;
      Id:=Owners[I];
      if Id=0 then Continue;
      if not Ways.TryGetValue(Id,W) then
      begin
        W:=Default(TWayInfo); W.Width:=6;
        W.MinUV:=1e20; W.MaxUV:=-1e20;
      end;
      UV:=Composite.UVOf(I);
      W.MinUV:=Min(W.MinUV,UV.X); W.MaxUV:=Max(W.MaxUV,UV.X);
      W.MatId:=M;
      Ways.AddOrSetValue(Id,W);
    end;
    // Separate loop: do not mutate a dictionary while enumerating it.
    SetLength(Keys,Ways.Count); K:=0;
    for Pair in Ways do begin Keys[K]:=Pair.Key; Inc(K) end;
    for K:=0 to High(Keys) do
    begin
      Id:=Keys[K]; W:=Ways[Id];
      if W.MatId=0 then Continue;
      W.Width:=EnsureRange(W.Width,0.1,200.0);
      if W.Surface.UVScale<=0 then
      begin
        // Backwards-compatible reconstruction of the legacy four-lane UV
        // slice. Counts beyond the old 2-per-side clamp use road width.
        F:=EnsureRange(Round((0.5-W.MinUV+0.0125)*4),0,2);
        B:=EnsureRange(Round((W.MaxUV-0.5+0.0125)*4),0,2);
        if F+B=0 then begin F:=1; B:=1 end;
        N:=F+B;
        if (N=4) and (W.Width>14) then
        begin N:=Max(4,Round(W.Width/3.25)); F:=(N+1) div 2; B:=N-F end;
        W.Surface.ForwardLanes:=F; W.Surface.BackwardLanes:=B;
        W.Surface.UVMin:=0.5-Min(F,2)*0.25+0.0125;
        W.Surface.UVMax:=0.5+Min(B,2)*0.25-0.0125;
        W.Surface.UVScale:=ROAD_UV_SCALE_Y_ASPHALT;
        W.Surface.Marked:=Ord(W.MatId<=25);
      end;
      // Old carriageway profiles stored concrete as "other", but its 12 m
      // UV scale distinguishes it from stone/dirt/sand (6 m) and wood (4 m).
      // Footways/cycleways override UV scale: never infer their material here.
      if (W.MatId<=GROUND_MAT_ROAD_SERVICE) and
         (W.Surface.Asphalt=ROAD_SURFACE_OTHER) and
         (Abs(W.Surface.UVScale-ROAD_UV_SCALE_Y_CONCRETE)<0.001) then
        W.Surface.Asphalt:=ROAD_SURFACE_CONCRETE;
      // Sidewalk ribbons retain procedural asphalt, including legacy
      // footway profiles classified as dirt or paving. Keep old atlas data
      // intact so the legacy material switch still works. Explicit concrete
      // now retains its own material on sidewalks too.
      if (W.MatId=GROUND_MAT_ROAD_FOOTWAY) and
         (W.Surface.Asphalt<>ROAD_SURFACE_CONCRETE) then W.Surface.Asphalt:=ROAD_SURFACE_ASPHALT;
      if W.MatId in [28,29] then
      begin
        if W.Surface.Asphalt=ROAD_SURFACE_OTHER then begin Ways[Id]:=W; Continue end;
        // No car wheel wear or painted lines on sidewalks.
        W.Surface.ForwardLanes:=Ord(W.MatId<>GROUND_MAT_ROAD_FOOTWAY); W.Surface.BackwardLanes:=0;
        W.Surface.UVMin:=0; W.Surface.UVMax:=1; W.Surface.Marked:=0;
        if W.MatId=28 then W.Surface.UVScale:=ROAD_UV_SCALE_Y_FOOTWAY
        else W.Surface.UVScale:=ROAD_UV_SCALE_Y_CYCLEWAY;
      end;
      N:=0;
      if W.MatId<=27 then N:=W.Surface.ForwardLanes+W.Surface.BackwardLanes;
      if W.Surface.Asphalt<>ROAD_SURFACE_OTHER then
        W.Handle:=RoadMaterialRegister(Id,W.Width,N,W.Surface.Layout,W.Seed,
          W.Surface.Condition,W.Surface.Asphalt=ROAD_SURFACE_CONCRETE);
      Ways[Id]:=W;
    end;

    SetLength(Coord,Composite.VertexCount*4);
    SetLength(Style,Composite.VertexCount*4);
    for I:=0 to Composite.VertexCount-1 do
    begin
      M:=Composite.MatIdOf(I); P:=Composite.PositionOf(I);
      // Existing road buckets preserve highway class even in old tile caches.
      // Keep the marking bit separate: bit 0 = markings, higher bits = grain.
      // Unknown-owner junctions inherit their road class without gaining lines.
      if (M>=24) and (M<=29) then Style[I*4+2]:=2*(M-23);
      if Composite.OsmIdOf(I)=ROAD_CURB_OWNER then
      begin
        UV:=Composite.UVOf(I);
        Coord[I*4]:=UV.X; Coord[I*4+1]:=UV.Y;
        Coord[I*4+2]:=1; Coord[I*4+3]:=-2;
        Continue;
      end;
      if M=GROUND_MAT_ASPHALT then
      begin
        // Flat areas have no lane direction. Use world Z/X, matching their
        // existing V/U tangent frame; negative handle selects 2D page lookup.
        Coord[I*4]:=P.Z; Coord[I*4+1]:=P.X;
        Coord[I*4+2]:=16; Coord[I*4+3]:=-1;
        Style[I*4+2]:=16*AreaCondition;
        Continue;
      end;
      if (M<24) or (M>29) or (Composite.OsmIdOf(I)=ROAD_CURB_OWNER) then Continue;
      Id:=Owners[I];
      if (Id=0) or not Ways.TryGetValue(Id,W) then
      begin
        // Untagged junction fill: plain asphalt, never spurious lane lines.
        Coord[I*4]:=P.Z; Coord[I*4+1]:=P.X; Coord[I*4+2]:=16; Coord[I*4+3]:=-1;
        Continue;
      end;
      if W.Surface.Asphalt=ROAD_SURFACE_OTHER then Continue;
      UV:=Composite.UVOf(I);
      Span:=W.Surface.UVMax-W.Surface.UVMin;
      if Span<=0.001 then Continue;
      ActualWidth:=W.Width;
      if (W.Surface.WidthStart>0) and (Model<>nil) then begin
        LocalP:=P-TileOrigin;LocalP.X:=LocalP.X/EastScale;
        SegmentIndex:=W.FirstSegment;BestDistance:=1e30;
        while SegmentIndex>=0 do begin
          Seg:=Model.RoadSegs[SegmentIndex];DX:=Seg.X1-Seg.X0;DZ:=Seg.Z1-Seg.Z0;
          Along:=EnsureRange(((LocalP.X-Seg.X0)*DX+(LocalP.Z-Seg.Z0)*DZ)/Max(0.0001,DX*DX+DZ*DZ),0,1);
          Distance:=Sqr(LocalP.X-Seg.X0-DX*Along)+Sqr(LocalP.Z-Seg.Z0-DZ*Along);
          if Distance<BestDistance then begin
            BestDistance:=Distance;ActualWidth:=RoadWidthAt(Seg.Surface,Seg.Width,Along);
          end;
          SegmentIndex:=NextSegment[SegmentIndex];
        end;
      end;
      T:=((UV.X-W.Surface.UVMin)/Span-0.5)*ActualWidth;
      S:=UV.Y*W.Surface.UVScale;
      Coord[I*4]:=S; Coord[I*4+1]:=T;
      Coord[I*4+2]:=ActualWidth; Coord[I*4+3]:=W.Handle;
      Style[I*4]:=W.Surface.ForwardLanes;
      Style[I*4+1]:=W.Surface.BackwardLanes;
      Style[I*4+2]:=W.Surface.Marked+2*(M-23)+16*W.Surface.Condition;
      if W.Surface.Asphalt=ROAD_SURFACE_CONCRETE then
        Style[I*4+2]:=Style[I*4+2]+ROAD_STYLE_CONCRETE;
      Style[I*4+3]:=W.Seed;
    end;
    // Cover every page intersected by a triangle, including pages with no
    // original vertex inside. Clip its edges in s so priority bounds follow
    // the actual page footprint, even on long triangles.
    for Tri:=0 to Composite.TriangleCount-1 do
    begin
      V0:=Composite.Indices[Tri*3]; Profile:=Round(Coord[V0*4+3]);
      if Coord[V0*4+2]>=1 then begin
        V1:=Composite.Indices[Tri*3+1];V2:=Composite.Indices[Tri*3+2];
        Puddles.Triangle(Composite.PositionOf(V0),Composite.PositionOf(V1),Composite.PositionOf(V2),
          Composite.NormalOf(V0),Composite.NormalOf(V1),Composite.NormalOf(V2),
          Vector4(Coord[V0*4],Coord[V0*4+1],Coord[V0*4+2],Coord[V0*4+3]),
          Vector4(Coord[V1*4],Coord[V1*4+1],Coord[V1*4+2],Coord[V1*4+3]),
          Vector4(Coord[V2*4],Coord[V2*4+1],Coord[V2*4+2],Coord[V2*4+3]),
          Vector4(Style[V0*4],Style[V0*4+1],Style[V0*4+2],Style[V0*4+3]));
      end;
      if (Profile=0) or (Profile < -1) then Continue;
      if Profile<0 then
      begin
        V1:=Composite.Indices[Tri*3+1]; V2:=Composite.Indices[Tri*3+2];
        if (Coord[V1*4+3]>=0) or (Coord[V2*4+3]>=0) then Continue;
        AreaA:=Composite.PositionOf(V0); AreaB:=Composite.PositionOf(V1); AreaC:=Composite.PositionOf(V2);
        MinS:=Min(AreaA.Z,Min(AreaB.Z,AreaC.Z)); MaxS:=Max(AreaA.Z,Max(AreaB.Z,AreaC.Z));
        MinT:=Min(AreaA.X,Min(AreaB.X,AreaC.X)); MaxT:=Max(AreaA.X,Max(AreaB.X,AreaC.X));
        if (MaxS-MinS>16384) or (MaxT-MinT>16384) then Continue;
        for AreaRow:=Floor(MinT/16) to Floor(MaxT/16) do
        begin
          Profile:=RoadMaterialRegisterArea(AreaRow,Round(Style[V0*4+2]) div 16); if Profile=0 then Continue;
          for Block:=Floor(MinS/16) to Floor(MaxS/16) do
            if OverlapsCell(AreaA,AreaB,AreaC,AreaRow*16,Block*16,(AreaRow+1)*16,(Block+1)*16) then
            begin
              RequestPoint(Profile,Block,Vector3(Max(MinT,AreaRow*16),0,Max(MinS,Block*16)));
              RequestPoint(Profile,Block,Vector3(Min(MaxT,(AreaRow+1)*16),0,Min(MaxS,(Block+1)*16)));
            end;
        end;
        Continue;
      end;
      MinS:=Coord[V0*4]; MaxS:=MinS;
      for E:=1 to 2 do
      begin
        V1:=Composite.Indices[Tri*3+E];
        if Round(Coord[V1*4+3])<>Profile then Profile:=0;
        MinS:=Min(MinS,Coord[V1*4]); MaxS:=Max(MaxS,Coord[V1*4]);
      end;
      if (Profile=0) or (MaxS-MinS>16384) then Continue;
      for Block:=Floor(MinS/16) to Floor(MaxS/16) do
        for E:=0 to 2 do
        begin
          V0:=Composite.Indices[Tri*3+E]; V1:=Composite.Indices[Tri*3+(E+1) mod 3];
          S0:=Coord[V0*4]; S1:=Coord[V1*4]; DS:=S1-S0;
          if Abs(DS)<1e-6 then
          begin
            if (S0<Block*16) or (S0>(Block+1)*16) then Continue;
            Lo:=0; Hi:=1;
          end else
          begin
            Lo:=(Block*16-S0)/DS; Hi:=((Block+1)*16-S0)/DS;
            if Lo>Hi then begin T:=Lo; Lo:=Hi; Hi:=T end;
            Lo:=Max(0.0,Lo); Hi:=Min(1.0,Hi);
            if Lo>Hi then Continue;
          end;
          EdgeStart:=Composite.PositionOf(V0); EdgeEnd:=Composite.PositionOf(V1);
          RequestPoint(Profile,Block,EdgeStart+(EdgeEnd-EdgeStart)*Lo);
          RequestPoint(Profile,Block,EdgeStart+(EdgeEnd-EdgeStart)*Hi);
        end;
    end;
    A:=TRoadCoordAttribute.Create;
    A.NameField:='roadCoord'; A.NumComponents:=4; AssignStaticField(A.FdValue, Coord);
    SA:=TFloatVertexAttributeNode.Create;
    SA.NameField:='roadStyle'; SA.NumComponents:=4; AssignStaticField(SA.FdValue, Style);
    Geo.FdAttrib.Add(A); Geo.FdAttrib.Add(SA);
    SetLength(Requests,RequestCount);
    A.Publish(Requests);
    RegisterRoadPuddles(Geo,Puddles.Sites);
  finally Puddles.Free;RequestsByKey.Free; Ways.Free end;
end;

end.
