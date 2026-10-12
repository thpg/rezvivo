program StairGeometryTests;
{$mode objfpc}{$H+}
uses SysUtils,Math,CastleVectors,fpjson,jsonparser,Osm3dGeoMath,Osm3dOsmData,
  Osm3dHeightmap,Osm3dGeomTerrain,Osm3dGeomSteps,Osm3dGroundComposite,Osm3dGeomMesh,
  Osm3dEnvironmentLayout,Osm3dKnowledgeProperties;
var D:TOSMDataset;W:TOSMWay;P:TLocalProjection;H:THeightmap;S:TTerrainSampler;
  C,Copied:TGroundCompositeMesh;I,J,Run,Tops,Risers:Integer;A,B,V,N:TVector3;
  Q:TJSONData;T:string;MV:TMeshVertex;UA,UB,UC:TVector2;
procedure Check(B:Boolean;const Text:string);
begin if not B then raise Exception.Create(Text) end;
begin
 D:=TOSMDataset.Create;P:=TLocalProjection.Create(TLatLon.Make(59.75,60.18));
 H:=THeightmap.Create(8,8,TLatLonBox.Make(59.75,60.18,59.7502,60.1802));
 try
  for I:=0 to 7 do for J:=0 to 7 do H[I,J]:=100+J;
  D.AddNode(TOSMNode.Create(1,TLatLon.Make(59.75002,60.1801)));
  D.AddNode(TOSMNode.Create(2,TLatLon.Make(59.75018,60.1801)));
  W:=TOSMWay.Create(1);W.NodeRefs:=[1,2];W.Tags.Add('highway','steps');W.Tags.Add('step_count','24');W.Tags.Add('width','4');D.AddWay(W);
  S:=TTerrainSampler.Create(H,P,1,13);
  try
   for Run:=0 to 1 do begin
    C:=TGroundCompositeMesh.Create('test');try
     Check(AppendStairWays(D,P,S,C)=1,'stair not generated');Tops:=0;Risers:=0;
     Check(C.TriangleCount=192,'unexpected geometry budget');
     for I:=0 to C.TriangleCount-1 do begin
      A:=C.PositionOf(C.Indices[I*3]);B:=C.PositionOf(C.Indices[I*3+1]);V:=C.PositionOf(C.Indices[I*3+2]);
      N:=TVector3.CrossProduct(B-A,V-A);Check(N.Length>1e-8,'degenerate face');
      UA:=C.UVOf(C.Indices[I*3]);UB:=C.UVOf(C.Indices[I*3+1])-UA;UC:=C.UVOf(C.Indices[I*3+2])-UA;
      Check(Abs(UB.X*UC.Y-UB.Y*UC.X)>1e-8,'singular stair UV causes unstable procedural normals');
      N:=N.Normalize;Check(TVector3.DotProduct(N,C.NormalOf(C.Indices[I*3]))>0.99,
        Format('normal mismatch triangle=%d n=%.2f,%.2f,%.2f stored=%.2f,%.2f,%.2f',[I,N.X,N.Y,N.Z,C.NormalOf(C.Indices[I*3]).X,C.NormalOf(C.Indices[I*3]).Y,C.NormalOf(C.Indices[I*3]).Z]));
      if N.Y>0.99 then begin Inc(Tops);Check(Abs(A.Y-B.Y)<1e-5,'tilted tread');Check(Abs(A.Y-V.Y)<1e-5,'tilted tread') end
      else if Abs(N.Z)>0.99 then Inc(Risers);
      Check(C.OsmIdOf(C.Indices[I*3])=1,'source id lost');
     end;
     Check(Tops=48,'tread count');Check(Risers=48,'riser count');
     Copied:=TGroundCompositeMesh.Create('slice');try
      Copied.ReserveForSlice(C.VertexCount,C.TriangleCount);
      for I:=0 to C.VertexCount-1 do begin
       MV.Position:=C.PositionOf(I);MV.Normal:=C.NormalOf(I);
       MV.UV:=C.UVOf(I);MV.OsmId:=C.OsmIdOf(I);
       J:=Copied.AppendVertex(MV,C.MatIdOf(I));
       Check(TVector3.DotProduct(Copied.NormalOf(J),MV.Normal)>0.99,'slice collapsed a hard stair edge');
      end;
     finally Copied.Free end;
    finally C.Free end;
    W.NodeRefs:=[2,1];
   end;
   W.Tags.Add('rezvivo:steps','no');Check(not IsStairWay(W),'explicit off ignored');
   C:=TGroundCompositeMesh.Create('disabled');try Check(AppendStairWays(D,P,S,C)=0,'disabled stairs still emitted') finally C.Free end;
   W.Tags.Add('highway','footway');W.Tags.Add('rezvivo:steps','yes');Check(IsStairWay(W),'sidewalk option ignored');
   W.NodeRefs:=[1,1];C:=TGroundCompositeMesh.Create('degenerate');try Check(AppendStairWays(D,P,S,C)=0,'zero length way') finally C.Free end;
  finally S.Free end;
  Check(KnowledgePropertyIndex('sidewalk.steps')>=0,'authoring option missing');
  Q:=GetJSON('{"version":1,"boundary":[[60,59],[60.0001,59],[60.0001,59.0001],[60,59.0001]],"features":[{"id":"s","kind":"steps","points":[[60.00002,59.00002],[60.00002,59.00008]],"width_m":4,"step_count":24}]}');
  try T:=CanonicalEnvironmentLayout(Q,'terrain');Check(Pos('step_count',T)>0,'authoring count lost') finally Q.Free end;
 finally H.Free;P.Free;D.Free end;
 Writeln('PASS stairs: uphill, downhill, winding, normals, flat treads, budget, source ID, disable, sidewalk option, degenerate way, authoring');
end.
