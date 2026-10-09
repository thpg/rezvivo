unit Osm3dGeomManholes;
{$mode objfpc}{$H+}{$Q-}{$R-}
interface
uses Osm3dManholeData, Osm3dOsmData, Osm3dGeoMath, Osm3dGroundComposite,
  Osm3dGroundSurfaceQuery;
{ Query belongs to the caller. Reuse the crossing index and add only bumps. }
function BuildManholes(Data:TOSMDataset; Proj:TLocalProjection;
  Ground:TGroundCompositeMesh; var Query:TGroundSurfaceQuery):TManholeArray;
implementation
uses SysUtils, Math, Generics.Collections, CastleVectors, Osm3dGeomUtils,
  Osm3dRoadCurbs, Osm3dGenerationProgress;
type
  TIntList = specialize TList<Integer>;
  TCellList = specialize TList<Int64>;
  TGrid = specialize TObjectDictionary<Int64,TIntList>;
  TZone = record
    Polygon:TPolygonMultipolygon;
    Building, Serviced:Boolean;
    MinX,MaxX,MinZ,MaxZ:Single;
  end;
  TZones = array of TZone;
const CELL=32.0; SPACING=12.0; NEAR_HOUSE=40.0;
function Key(X,Z:Integer):Int64;
begin Result:=Int64((QWord(LongWord(X)) shl 32) or LongWord(Z)) end;
procedure Insert(Grid:TGrid; X,Z,Value:Integer);
var L:TIntList;
begin
  if not Grid.TryGetValue(Key(X,Z),L) then
  begin L:=TIntList.Create;Grid.Add(Key(X,Z),L) end;
  L.Add(Value);
end;
function Hash(X,Z:Int64):LongWord;
var V:QWord;
begin
  V:=QWord(X)*QWord($9E3779B185EBCA87) xor QWord(Z)*QWord($C2B2AE3D27D4EB4F);
  V:=(V xor (V shr 30))*QWord($BF58476D1CE4E5B9);
  V:=(V xor (V shr 27))*QWord($94D049BB133111EB);
  Result:=LongWord(V xor (V shr 31));
end;
function Inside(const P:TPolygonMultipolygon; X,Z:Single):Boolean;
var I:Integer;
begin
  Result:=PointInRingXZ(X,Z,P.Outer);if not Result then Exit;
  for I:=0 to High(P.Inners) do if PointInRingXZ(X,Z,P.Inners[I]) then Exit(False);
end;
function EdgeDistance(const P:TPolygonMultipolygon; X,Z:Single):Single;
var I,J:Integer; A,B:TScatterPoint; DX,DZ,T:Single;
begin
  Result:=1e20;J:=High(P.Outer);
  for I:=0 to High(P.Outer) do begin
    A:=P.Outer[J];B:=P.Outer[I];DX:=B.X-A.X;DZ:=B.Z-A.Z;
    T:=EnsureRange(((X-A.X)*DX+(Z-A.Z)*DZ)/Max(1e-9,DX*DX+DZ*DZ),0.0,1.0);
    Result:=Min(Result,Sqr(X-A.X-T*DX)+Sqr(Z-A.Z-T*DZ));J:=I;
  end;
  Result:=Sqrt(Result);
end;
function SurfaceClass(Mat:Integer):Integer;
begin
  if Mat in [12,14,28] then Exit(1); { pedestrian pavement }
  if Mat in [13,24,25,26,27,29] then Exit(0); { all asphalt, cycleways included }
  if Mat in [0,1,2,3,4,7,8,9,10,11,21,22,23,31] then Exit(2);
  Result:=-1; { water, railway, sports pitches and helipads }
end;
function BuildManholes(Data:TOSMDataset; Proj:TLocalProjection;
  Ground:TGroundCompositeMesh; var Query:TGroundSurfaceQuery):TManholeArray;
var
  Zones:TZones; ZoneGrid:TGrid; Candidates:TCellList;
  W:TOSMWay; Rel:TOSMRelation; Polys:TMultipolygonArray;
  I,IX,IZ,Mat,ClassId,OtherMat,N,AreaN,CandidateI,ZX,ZZ,ZoneCount:Integer;
  GX,GZ,X0,X1,Z0,Z1:Int64;
  MinX,MaxX,MinZ,MaxZ,WX,WZ,H,OtherH,NearDist:Single;
  OffsetX,OffsetZ,CellX,CellZ,JitterPad:Double; Seed:LongWord; M:TManhole;
  A,B,C,U,V,P,OtherNormal,SurfaceU:TVector3; Good,InResidential:Boolean;
  SurfaceOwner:Int64;
  ZoneKey,CandidateKey,CX0,CX1,CZ0,CZ1:Int64;

  procedure AddZone(const Poly:TPolygonMultipolygon; Tags:TOSMTags);
  var R:TZone; Id,CX,CZ:Integer; Bld:string; Radius:Single;
  begin
    if Length(Poly.Outer)<3 then Exit;
    R:=Default(TZone);R.Polygon:=Poly;Bld:=LowerCase(Tags.Get('building'));
    R.Building:=(Bld<>'') and (Bld<>'no');
    R.Serviced:=R.Building and not ((Bld='roof')or(Bld='shed')or(Bld='garage')or
      (Bld='garages')or(Bld='carport')or(Bld='ruins')or(Bld='construction')or
      (Bld='greenhouse')or(Bld='barn'));
    MultipolygonBBox(Poly,R.MinX,R.MaxX,R.MinZ,R.MaxZ);
    Id:=ZoneCount;Inc(ZoneCount);
    if ZoneCount>Length(Zones) then SetLength(Zones,Max(64,Length(Zones)*2));
    Zones[Id]:=R;
    if R.Serviced then Radius:=NEAR_HOUSE else Radius:=2;
    { Clip large residential polygons to the generated chunk before indexing. }
    for CZ:=Floor(Max(MinZ,R.MinZ-Radius)/CELL) to Floor(Min(MaxZ,R.MaxZ+Radius)/CELL) do
      for CX:=Floor(Max(MinX,R.MinX-Radius)/CELL) to Floor(Min(MaxX,R.MaxX+Radius)/CELL) do
        Insert(ZoneGrid,CX,CZ,Id);
  end;
  function EligibleZone(Tags:TOSMTags):Boolean;
  begin Result:=(Tags.Get('landuse')='residential') or
    ((Tags.Get('building')<>'')and(Tags.Get('building')<>'no')) end;
  function ZoneAt(PX,PZ:Single; out Near:Single; out Residential:Boolean):Boolean;
  var L:TIntList; Id:Integer; R:TZone; D:Single;
  begin
    Near:=1e20;Residential:=False;Result:=False;
    if not ZoneGrid.TryGetValue(Key(Floor(PX/CELL),Floor(PZ/CELL)),L) then Exit;
    for Id in L do begin
      R:=Zones[Id];
      if R.Building then begin
        if (PX<R.MinX-NEAR_HOUSE)or(PX>R.MaxX+NEAR_HOUSE)or
          (PZ<R.MinZ-NEAR_HOUSE)or(PZ>R.MaxZ+NEAR_HOUSE) then Continue;
        if Inside(R.Polygon,PX,PZ) then Exit(False);
        D:=EdgeDistance(R.Polygon,PX,PZ);
        if D<1.5 then Exit(False); { keep the full cover away from walls }
        if R.Serviced then Near:=Min(Near,D);
      end else if Inside(R.Polygon,PX,PZ) then Residential:=True;
    end;
    Result:=Residential or (Near<=NEAR_HOUSE);
  end;
  function Sample(PX,PZ:Single; out Y:Single; out Normal:TVector3;
    out MaterialId:Integer):Boolean;
  var Hit:TSurfaceHit;
  begin
    Result:=Query.Sample(PX,PZ,Hit,True);
    Y:=Hit.Position.Y;Normal:=Hit.Normal;MaterialId:=Hit.MaterialId;
    SurfaceOwner:=Hit.Owner;SurfaceU:=Hit.TangentU;
    if not Result then begin Normal:=Vector3(0,1,0);MaterialId:=-1 end;
    if (Hit.Owner=ROAD_CURB_OWNER)or(Hit.Owner=ROAD_BUMP_OWNER) then MaterialId:=-1;
  end;
begin
  Result:=nil;
  if (Data=nil)or(Proj=nil)or(Ground=nil)or(Ground.TriangleCount=0) then Exit;
  GenerationProgress('Manhole areas',0,0);
  ZoneCount:=0;
  ZoneGrid:=TGrid.Create([doOwnsValues]);Candidates:=TCellList.Create;
  try
    MinX:=1e20;MinZ:=1e20;MaxX:=-1e20;MaxZ:=-1e20;
    for I:=0 to Ground.VertexCount-1 do begin
      A:=Ground.PositionOf(I);MinX:=Min(MinX,A.X);MaxX:=Max(MaxX,A.X);
      MinZ:=Min(MinZ,A.Z);MaxZ:=Max(MaxZ,A.Z);
    end;
    for W in Data.Ways.Values do if W.IsClosed and EligibleZone(W.Tags) then
      AddZone(BuildMultipolygonFromWay(W,Data,Proj),W.Tags);
    for Rel in Data.Relations.Values do if EligibleZone(Rel.Tags) then begin
      Polys:=BuildMultipolygonsFromRelation(Rel,Data,Proj);
      for I:=0 to High(Polys) do AddZone(Polys[I],Rel.Tags);
    end;
    if ZoneCount=0 then Exit;
    if Query=nil then Query:=TGroundSurfaceQuery.Create(Ground)
    else Query.IncludeAppended;
    MinX:=1e20;MinZ:=1e20;MaxX:=-1e20;MaxZ:=-1e20;
    for I:=0 to Ground.TriangleCount-1 do begin
      A:=Ground.PositionOf(Ground.Indices[I*3]);B:=Ground.PositionOf(Ground.Indices[I*3+1]);
      C:=Ground.PositionOf(Ground.Indices[I*3+2]);
      WX:=Min(A.X,Min(B.X,C.X));WZ:=Min(A.Z,Min(B.Z,C.Z));
      MinX:=Min(MinX,WX);MinZ:=Min(MinZ,WZ);
      H:=Max(A.X,Max(B.X,C.X));OtherH:=Max(A.Z,Max(B.Z,C.Z));
      MaxX:=Max(MaxX,H);MaxZ:=Max(MaxZ,OtherH);
      if (I and 16383)=0 then CheckGenerationCancelled;
    end;
    { Geographic anchor: placement is independent of chunk origin and traversal
      order, and never hashes large float shader coordinates. }
    OffsetX:=-Proj.Origin.Lon*Proj.MetersPerDegreeLon;
    OffsetZ:=Proj.Origin.Lat*Proj.MetersPerDegreeLat;
    X0:=Floor((MinX+OffsetX)/SPACING);X1:=Floor((MaxX+OffsetX)/SPACING);
    Z0:=Floor((MinZ+OffsetZ)/SPACING);Z1:=Floor((MaxZ+OffsetZ)/SPACING);
    { A distant polygon fragment can stretch the overall bounds by hundreds
      of kilometres. Enumerate only occupied eligibility cells, not every
      12 m point in that mostly empty rectangle. The jittered point assigns
      each candidate to one 32 m cell, so no dedup set is necessary. }
    AreaN:=0;
    for ZoneKey in ZoneGrid.Keys do begin
      if (AreaN and 255)=0 then begin
        CheckGenerationCancelled;GenerationProgress('Manhole areas',AreaN,ZoneGrid.Count);
      end;
      ZX:=Integer(LongWord(QWord(ZoneKey) shr 32));ZZ:=Integer(LongWord(ZoneKey));
      { WX/WZ are Single: include their rounding margin at cell boundaries. }
      JitterPad:=Max(0.001,Max(Abs(Double(ZX)),Abs(Double(ZZ)))*CELL*1.2e-7);
      CX0:=Max(X0,Ceil((Double(ZX)*CELL+OffsetX-SPACING*0.75-JitterPad)/SPACING));
      CX1:=Min(X1,Floor(((Double(ZX)+1)*CELL+OffsetX-SPACING*0.25+JitterPad)/SPACING));
      CZ0:=Max(Z0,Ceil((Double(ZZ)*CELL+OffsetZ-SPACING*0.75-JitterPad)/SPACING));
      CZ1:=Min(Z1,Floor(((Double(ZZ)+1)*CELL+OffsetZ-SPACING*0.25+JitterPad)/SPACING));
      for GZ:=CZ0 to CZ1 do for GX:=CX0 to CX1 do begin
        Seed:=Hash(GX,GZ);if (Seed and 3)=0 then Continue;
        CellX:=Double(GX)*SPACING-OffsetX;CellZ:=Double(GZ)*SPACING-OffsetZ;
        WX:=CellX+(0.25+((Seed shr 2)and 255)/510.0)*SPACING;
        WZ:=CellZ+(0.25+((Seed shr 10)and 255)/510.0)*SPACING;
        if Key(Floor(WX/CELL),Floor(WZ/CELL))<>ZoneKey then Continue;
        CandidateKey:=(GZ shl 32)or LongWord(LongWord(GX)xor $80000000);
        Candidates.Add(CandidateKey);
      end;
      Inc(AreaN);
    end;
    { Preserve the old row-major output order, including negative coordinates. }
    Candidates.Sort;
    N:=0;
    for CandidateI:=0 to Candidates.Count-1 do begin
      if (CandidateI and 255)=0 then begin
        CheckGenerationCancelled;GenerationProgress('Manholes',CandidateI,Candidates.Count);
      end;
      CandidateKey:=Candidates[CandidateI];
      GZ:=Integer(LongWord(QWord(CandidateKey) shr 32));
      GX:=Integer(LongWord(CandidateKey)xor $80000000);
      Seed:=Hash(GX,GZ);if (Seed and 3)=0 then Continue;
      { Subtract the geographic origin in Double BEFORE adding sub-metre
        jitter. Large global Single coordinates quantize it to half metres. }
      CellX:=Double(GX)*SPACING-OffsetX;CellZ:=Double(GZ)*SPACING-OffsetZ;
      WX:=CellX+(0.25+((Seed shr 2)and 255)/510.0)*SPACING;
      WZ:=CellZ+(0.25+((Seed shr 10)and 255)/510.0)*SPACING;
      if not ZoneAt(WX,WZ,NearDist,InResidential) then Continue;
      if not Sample(WX,WZ,H,M.Normal,Mat) then Continue;
      W:=Data.FindWay(SurfaceOwner);
      if W<>nil then begin
        if (W.Tags.Get('bridge','no')<>'no')or(W.Tags.Get('tunnel','no')<>'no') then Continue;
      end;
      ClassId:=SurfaceClass(Mat);if (ClassId<0)or(M.Normal.Y<0.9) then Continue;
      if (ClassId=2)and((NearDist>12)or((Seed and 7)<>1)) then Continue;
      case ClassId of
        0:M.Kind:=(Seed shr 18)mod 4;
        1:M.Kind:=4+(Seed shr 18)mod 2;
        else M.Kind:=6+(Seed shr 18)mod 3;
      end;
      M.Position:=Vector3(WX,H+0.008,WZ);
      M.Rotation:=((Seed shr 22)and 1023)*(2*Pi/1024);
      if (ClassId=1) and (Sqr(SurfaceU.X)+Sqr(SurfaceU.Z)>1e-8) then
        M.Rotation:=ArcTan2(SurfaceU.Z,SurfaceU.X);
      ManholeAxes(M,U,V);U:=U*(MANHOLE_SIZES[M.Kind].X*0.5+0.08);
      V:=V*(MANHOLE_SIZES[M.Kind].Y*0.5+0.08);Good:=True;
      { All corners must be supported by the same kind of surface and plane;
        no floating covers across kerbs, pavement edges, water or a crease. }
      for IX:=-1 to 1 do begin
        if not Good then Break;
        for IZ:=-1 to 1 do begin
        P:=M.Position+U*IX+V*IZ;
        if not Sample(P.X,P.Z,OtherH,OtherNormal,OtherMat) or
           (SurfaceClass(OtherMat)<>ClassId)or(Abs(OtherH-(P.Y-0.008))>0.025) then begin Good:=False;Break end;
      end;
      end;
      if not Good then Continue;
      if N=Length(Result) then SetLength(Result,Max(64,N*2));
      Result[N]:=M;Inc(N);
    end;
    GenerationProgress('Manholes',Candidates.Count,Candidates.Count);
    SetLength(Result,N);
  finally Candidates.Free;ZoneGrid.Free end;
end;
end.
