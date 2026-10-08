program RoadPhotoGeometryTests;
{$mode objfpc}{$H+}
uses SysUtils,Math,Osm3dGeomVegetation,Osm3dStudioSettings,
  Osm3dGeomRoadJoints,Osm3dGeomTerrain,Osm3dRoadSurface,Osm3dOsmData,
  Osm3dPhotoRoadProfile,Osm3dGeoMath;

procedure Check(B:Boolean;const S:string);
begin if not B then raise Exception.Create(S) end;

procedure TestPlantMask;
var Mask:TRoadExclusionMask;Cands:TRoadSegArray;N,I:Integer;X,W:Single;
begin
  Mask:=TRoadExclusionMask.Create;
  try
    Mask.AddSegment(0,0,100,0,1,5);Mask.CollectCandidates(-20,-20,120,20,Cands,N);
    Check(N=1,'segment indexed once');
    for I:=0 to 10 do begin
      X:=I*10;W:=1+4*X/100+ROAD_CLEAR_M;
      Check(Mask.IsOnRoad(X,W-0.05,Cands,N),'plant allowed inside widening road');
      Check(not Mask.IsOnRoad(X,W+0.05,Cands,N),'mask uses maximum width at narrow end');
    end;
  finally Mask.Free end;
  Writeln('PASS variable-width vegetation mask: 22 edge samples');
end;

procedure TestCurve;
var C:TRibbonVertexArray;E:TRibbonEdgePointArray;W:TRibbonWidthArray;
  Stats:TPolylineStats;I:Integer;L,Area:Double;
begin
  SetLength(C,5);SetLength(W,5);
  C[0].X:=0;C[0].Z:=0;C[1].X:=40;C[1].Z:=0;
  C[2].X:=80;C[2].Z:=15;C[3].X:=120;C[3].Z:=45;
  C[4].X:=170;C[4].Z:=45;
  W[0]:=2;W[1]:=3;W[2]:=4;W[3]:=3;W[4]:=2;
  ComputeRibbonAccumLen(C);BuildSmoothRibbonEdges(C,4,E,Stats,CR_DEFAULT_CHORD_ERR_M,nil,W);
  Check(Length(E)>5,'curved road was not smoothed');L:=-1;
  for I:=0 to High(E) do begin
    Check(E[I].AccumLen>=L,'UV station went backwards');L:=E[I].AccumLen;
    Area:=Hypot(E[I].Right.X-E[I].Left.X,E[I].Right.Z-E[I].Left.Z);
    Check(not IsNan(Area) and (Area>=3.99) and (Area<9),'curved profile has an invalid span');
  end;
  Check(Abs(Hypot(E[0].Right.X-E[0].Left.X,E[0].Right.Z-E[0].Left.Z)-4)<0.001,'start width');
  I:=High(E);
  Check(Abs(Hypot(E[I].Right.X-E[I].Left.X,E[I].Right.Z-E[I].Left.Z)-4)<0.001,'end width');
  Writeln('PASS variable-width smoothed ribbon: ',Length(E),' sections');
end;

procedure TestOffsetCorner;
const Profile='{"version":1,"blend_m":10,"stations":[{"at_m":7,"width_m":2,"offset_m":2},{"at_m":50,"width_m":2,"offset_m":2}]}';
var Data:TOSMDataset;Way:TOSMWay;Plan:TPhotoRoadPlan;Node:TOSMNode;
  LL,Expected:TLatLon;I:Integer;Best:Double;
begin
  Data:=TOSMDataset.Create;Plan:=nil;
  try
    { A 90-degree corner with unequal 10/70 m arms. Chord averaging
      incorrectly pulls the offset vertex along the long segment. }
    LL:=TLatLon.Make(45,60);
    Data.AddNode(TOSMNode.Create(1,LL));
    LL.Lon+=10/(111320*Cos(45*Pi/180));Data.AddNode(TOSMNode.Create(2,LL));
    Expected:=LL;Expected.Lon+=2/(111320*Cos(45*Pi/180));Expected.Lat-=2/111320;
    LL.Lat+=70/111320;Data.AddNode(TOSMNode.Create(3,LL));
    Way:=TOSMWay.Create(123);SetLength(Way.NodeRefs,3);
    for I:=0 to 2 do Way.NodeRefs[I]:=I+1;Data.AddWay(Way);
    Plan:=BuildPhotoRoadPlan(Profile,Way,Data,2);Best:=1E30;
    for Node in Plan.Nodes do Best:=Min(Best,Node.Position.DistanceTo(Expected));
    Check(Best<0.03,'unequal-arm corner did not intersect its parallel offset lines');
    Check((Data.Nodes.Count=3) and (Length(Way.NodeRefs)=3),'planner mutated original data before validation');
    Plan.Apply(Data);
    Check((Way.NodeRefs[0]=1) and (Way.NodeRefs[High(Way.NodeRefs)]=3),'offset broke original endpoint IDs');
    Check(Way.HasPhotoProfile and (Length(Way.PhotoWidths)=Length(Way.NodeRefs)),'applied profile lost widths');
    Writeln('PASS shifted sidewalk corner with unequal arm lengths, staged nodes, fixed endpoints');
  finally Plan.Free;Data.Free end;
end;

begin TestPlantMask;TestCurve;TestOffsetCorner end.
