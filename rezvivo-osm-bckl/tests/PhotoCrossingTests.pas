program PhotoCrossingTests;
{$mode objfpc}{$H+}
uses SysUtils,Math,CastleVectors,Osm3dOsmData,Osm3dGeoMath,Osm3dGeomMesh,
  Osm3dGeomRoads,Osm3dGroundComposite,Osm3dGroundSurfaceQuery,Osm3dGeomCrossings;
var Data:TOSMDataset;P:TLocalProjection;G:TGroundCompositeMesh;
  Q:TGroundSurfaceQuery;M:TMesh;W:TOSMWay;N:TOSMNode;
  Roads:TRoadCenterlineSegArray;Stats:TCrossingStats;I,Checks,SignVerts:Integer;
procedure Check(B:Boolean;const S:string);
begin if not B then raise Exception.Create(S);Inc(Checks) end;
procedure Rect(X0,Z0,X1,Z1:Single;Mat:Integer);
var V:TMeshVertex;B:Integer;
begin
  V:=Default(TMeshVertex);V.Normal:=Vector3(0,1,0);V.OsmId:=10;
  B:=G.VertexCount;
  V.Position:=Vector3(X0,5,Z0);G.AppendVertex(V,Mat);
  V.Position:=Vector3(X0,5,Z1);G.AppendVertex(V,Mat);
  V.Position:=Vector3(X1,5,Z1);G.AppendVertex(V,Mat);
  V.Position:=Vector3(X1,5,Z0);G.AppendVertex(V,Mat);
  G.AppendTriangle(B,B+1,B+2);G.AppendTriangle(B,B+2,B+3);
end;
begin
  Data:=TOSMDataset.Create;P:=TLocalProjection.Create(TLatLon.Make(59,60));
  G:=TGroundCompositeMesh.Create;Q:=nil;M:=nil;
  try
    Rect(-3,-30,3,30,13);Rect(-20,-30,-3,30,0);Rect(3,-30,20,30,0);
    W:=TOSMWay.Create(10);W.Tags.Add('highway','residential');Data.AddWay(W);
    SetLength(Roads,1);Roads[0]:=Default(TRoadCenterlineSeg);
    Roads[0].Z0:=-30;Roads[0].Z1:=30;Roads[0].Width:=6;Roads[0].WayId:=10;
    N:=TOSMNode.Create(100,P.Unproject(3.65,2.35));
    N.Tags.Add('rezvivo:photo_sign','crossing_right');N.Tags.Add('direction','180');Data.AddNode(N);
    M:=BuildCrossings(Data,P,Roads,G,Stats,Q);
    Check((M<>nil) and (Stats.Signs=1),'observed roadside sign uses native atlas');
    Check(M.VertexCount=40,'one support plus two-sided board, no duplicate pole');
    for I:=0 to M.VertexCount-1 do Check(M.Vertices[I].Position.Y>=4.999,'sign is grounded, no buried mesh');
    M.Free;M:=nil;
    N:=TOSMNode.Create(200,P.Unproject(0,0));
    N.Tags.Add('highway','crossing');N.Tags.Add('rezvivo:photo_crossing','yes');Data.AddNode(N);
    M:=BuildCrossings(Data,P,Roads,G,Stats,Q);
    Check((Stats.Crossings=1) and (Stats.Bumps=0),'observed zebra does not invent speed bumps');
    Check(Stats.Signs=2,'observed sign replaces adjacent inferred support');
    SignVerts:=0;
    for I:=0 to M.VertexCount-1 do if M.Vertices[I].OsmId=100 then Inc(SignVerts);
    Check(SignVerts=40,'observed support not duplicated by crossing');
    Check(G.TriangleCount=6,'no extra physical ground layer from photo crossing');
    M.Free;M:=nil;
    N:=Data.FindNode(100);N.Position:=P.Unproject(0,12);
    N.LatE7:=Round(N.Position.Lat*1e7);N.LonE7:=Round(N.Position.Lon*1e7);
    M:=BuildCrossings(Data,P,Roads,G,Stats,Q);SignVerts:=0;
    for I:=0 to M.VertexCount-1 do if M.Vertices[I].OsmId=100 then Inc(SignVerts);
    Check(SignVerts=0,'invalid sign in a travel lane is not emitted');
    WriteLn('PASS ',Checks,' native photo crossing checks');
  finally M.Free;Q.Free;G.Free;P.Free;Data.Free end;
end.
