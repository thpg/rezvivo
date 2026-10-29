program RoadJunctionTests;
{$mode objfpc}{$H+}
uses SysUtils,Math,CastleVectors,Osm3dRoadJunctions,Osm3dGeomRoads,
  Osm3dGeoMath,Osm3dOsmData,Osm3dGeomMesh,Osm3dRoadSurface;

procedure Check(B:Boolean;const S:string);
begin if not B then raise Exception.Create(S) end;

function Inside(const R:TJunctionOutline; X,Y:Single):Boolean;
var I,J:Integer;
begin
  Result:=False;J:=High(R);
  for I:=0 to High(R) do begin
    if ((R[I].Z>Y)<>(R[J].Z>Y)) and
       (X<(R[J].X-R[I].X)*(Y-R[I].Z)/(R[J].Z-R[I].Z)+R[I].X) then Result:=not Result;
    J:=I;
  end;
end;

procedure ShapeTest;
var Arms:TJunctionArms;R:TJunctionOutline;I,J:Integer;A,Area:Single;
begin
  SetLength(Arms,3);
  for I:=0 to 2 do begin
    A:=I*Pi/2;Arms[I].Direction:=Vector2(Cos(A),Sin(A));
    Arms[I].HalfWidth:=2;Arms[I].Available:=30;
  end;
  R:=RoundedJunction(Vector2(0,0),Arms,True);
  Check(Length(R)>15,'rounded contour missing');
  Check(Inside(R,2.2,2.2),'rounding must fill the concave shoulder');
  Check(not Inside(R,5,5),'junction must not cover unrelated terrain');
  Check(Inside(R,0,0),'center must remain pavement');
  Area:=0;
  for I:=0 to High(R) do begin J:=(I+1) mod Length(R);
    A:=R[I].X*R[J].Z-R[I].Z*R[J].X;
    Check(A>=-0.001,'fan must not invert');Area+=A;
  end;
  Check(Area>0,'winding');
  Writeln('PASS rounded T: ',Length(R),' outline vertices');
end;

procedure BuilderTest(const MainSurface,SideSurface:string;MainWidth,SideWidth:Single;
  SideX:Single=0;SideZ:Single=30);
var DS:TOSMDataset;Projection:TLocalProjection;W:TOSMWay;
  Roads:TRoadMeshes;Segs:TRoadCenterlineSegArray;K:TRoadKind;
  I,N:Integer;UV:TVector2;HasSuppressed:Boolean;MaxX:Single;
  procedure Node(Id:Integer;X,Z:Single);
  begin DS.AddNode(TOSMNode.Create(Id,Projection.Unproject(X,Z))) end;
  procedure Way(Id:Integer;const Refs:array of Int64;const Surface:string;Width:Single);
  var J:Integer;
  begin W:=TOSMWay.Create(Id);SetLength(W.NodeRefs,Length(Refs));
    for J:=0 to High(Refs) do W.NodeRefs[J]:=Refs[J];
    if Surface='dirt' then W.Tags.Add('highway','track') else W.Tags.Add('highway','footway');
    W.Tags.Add('surface',Surface);
    W.Tags.Add('width',FloatToStr(Width));W.Tags.Add('rezvivo:road_markings','edge');DS.AddWay(W);
  end;
begin
  DS:=TOSMDataset.Create;Projection:=TLocalProjection.Create(TLatLon.Make(59.77,60.2));
  try
    Node(1,-30,0);Node(2,0,0);Node(3,30,0);Node(4,SideX,SideZ);
    Way(100,[1,2,3],MainSurface,MainWidth);Way(101,[2,4],SideSurface,SideWidth);
    Roads:=TRoadBuilder.BuildAll(DS,nil,Projection,Segs,nil,nil,True,True);
    try
      N:=0;HasSuppressed:=False;MaxX:=-1e20;
      for K:=Low(TRoadKind) to High(TRoadKind) do if Roads.JunctionUV[K]<>nil then begin
        Inc(N,Roads.JunctionRings[K].N);
        for I:=0 to Roads.JunctionUV[K].VertexCount-1 do begin
          UV:=Roads.JunctionUV[K].Vertices[I].UV;
          MaxX:=Max(MaxX,Roads.JunctionUV[K].Vertices[I].Position.X);
          if UV.X<ROAD_JUNCTION_UV_SHIFT*0.5 then HasSuppressed:=True;
          Check(Roads.JunctionUV[K].Vertices[I].OsmId=100,'dominant source way must survive');
        end;
      end;
      Check(N=1,'one common junction');
      Check(HasSuppressed=((MainSurface=SideSurface) or (MainSurface='')),'only a same-surface common junction removes interior stripes');
      Check(Length(Segs)=3,'route centerlines must not change');
      if (SideX=30) and (MainSurface='dirt') then
        Check(MaxX>14,'acute narrow paved branch must end at the edge of the broad dirt road');
      Writeln('PASS ground-source junction ',MainSurface,' / ',SideSurface);
    finally
      Roads.Major.Free;Roads.Secondary.Free;Roads.Minor.Free;Roads.Service.Free;
      Roads.Footway.Free;Roads.Cycleway.Free;Roads.Railway.Free;Roads.DirtPath.Free;Roads.SandPath.Free;
      for K:=Low(TRoadKind) to High(TRoadKind) do begin Roads.UVMesh[K].Free;Roads.JunctionUV[K].Free end;
    end;
  finally DS.Free;Projection.Free end;
end;
begin
  DefaultFormatSettings.DecimalSeparator:='.';
  ShapeTest;BuilderTest('asphalt','asphalt',4,3);
  BuilderTest('dirt','asphalt',8,2);BuilderTest('asphalt','dirt',8,2);
  BuilderTest('','asphalt',4,3);
  BuilderTest('dirt','asphalt',8,2,30,10);
  BuilderTest('asphalt','asphalt',4,2,30,10);
end.
