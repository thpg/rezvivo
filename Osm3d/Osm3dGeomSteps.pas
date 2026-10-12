unit Osm3dGeomSteps;
{$mode objfpc}{$H+}

{ Real treads and risers, baked once after road draping. The sloping road
  underneath remains the filled foundation, not a second visible surface.
  Geometry, shadows and GPU contact queries use the same triangles. }
interface
uses Osm3dOsmData, Osm3dGeoMath, Osm3dGeomTerrain, Osm3dGroundComposite;
function IsStairWay(W:TOSMWay):Boolean;
function AppendStairWays(D:TOSMDataset; P:TLocalProjection;
  S:TTerrainSampler; C:TGroundCompositeMesh):Integer;

implementation
uses SysUtils,Math,CastleVectors,Osm3dGeomRoads,Osm3dGeomMesh;

function IsStairWay(W:TOSMWay):Boolean;
begin
  Result:=(W<>nil) and ((W.Tags.GetLower('highway')='steps') or
    (W.Tags.GetLower('rezvivo:steps')='yes'));
  if (W<>nil) and (W.Tags.GetLower('rezvivo:steps')='no') then Result:=False;
end;

function AppendStairWays(D:TOSMDataset; P:TLocalProjection;
  S:TTerrainSampler; C:TGroundCompositeMesh):Integer;
var W:TOSMWay;N:TOSMNode;Tmp:TGroundCompositeMesh;
  Points,EdgesL,EdgesR:array of TVector3;Distances:array of Double;
  I,K,Count,Valid:Integer;Total,Rise,Width,T,H,LowH,DX,DZ,L:Double;
  A,B,V,Q,Across,Forward: TVector3;Params:TRoadParams;
  procedure Quad(const A,B,C,D:TVector3);
  var V:TMeshVertex;Normal:TVector3;Base:array[0..3] of Integer;
    function Vert(const P:TVector3):Integer;
    var U,Along:Single;Rel:TVector3;
    begin
      V.Position:=P;V.Normal:=Normal;Rel:=P-EdgesL[I];
      U:=TVector3.DotProduct(Rel,Across)/(Width*2);
      Along:=Total*I/Count+TVector3.DotProduct(Rel,Forward);
      { XZ-only mapping is singular on a vertical riser. Every stair face
        needs two independent texture axes for the procedural normal map. }
      if Abs(Normal.Y)<0.5 then begin
        if Abs(TVector3.DotProduct(Normal,Across))>0.5 then U:=(P.Y-LowH)/(Width*2)
        else Along:=Total*I/Count+P.Y-LowH;
      end;
      V.UV:=Vector2(U,Along/TRoadBuilder.ClassUVScaleY(Params));
      V.OsmId:=W.Id;Result:=Tmp.AppendVertex(V,GROUND_MAT_ROAD_FOOTWAY);
    end;
  begin
    Normal:=TVector3.CrossProduct(B-A,C-A);
    if Normal.Length<1e-8 then Exit;
    Normal:=Normal.Normalize;
    Base[0]:=Vert(A);Base[1]:=Vert(B);Base[2]:=Vert(C);Base[3]:=Vert(D);
    Tmp.AppendTriangle(Base[0],Base[1],Base[2]);Tmp.AppendTriangle(Base[0],Base[2],Base[3]);
  end;
  function AtHeight(const V:TVector3;H:Single):TVector3;
  begin Result:=V;Result.Y:=H end;
begin
  Result:=0;if (D=nil) or (P=nil) or (S=nil) or (C=nil) then Exit;
  Tmp:=TGroundCompositeMesh.Create('steps',0.99);
  try
    for W in D.Ways.Values do begin
      if not IsStairWay(W) or OsmWayIsBridge(W.Tags) or OsmWayIsTunnel(W.Tags) then Continue;
      SetLength(Points,Length(W.NodeRefs));SetLength(Distances,Length(W.NodeRefs));Valid:=0;Total:=0;Rise:=0;
      for I:=0 to High(W.NodeRefs) do begin
        N:=D.FindNode(W.NodeRefs[I]);if N=nil then begin Valid:=0;Break end;
        V:=P.Project(N.Position,S.SampleAt(N.Position));
        if Valid>0 then begin
          L:=Hypot(V.X-Points[Valid-1].X,V.Z-Points[Valid-1].Z);
          if L<0.001 then Continue;
          Total+=L;Rise+=Abs(V.Y-Points[Valid-1].Y);
        end;
        Points[Valid]:=V;Distances[Valid]:=Total;Inc(Valid);
      end;
      if (Valid<2) or (Total<0.25) or (Rise<0.04) then Continue;
      SetLength(Points,Valid);SetLength(Distances,Valid);
      Params:=TRoadBuilder.ParseRoadParams(W.Tags);Width:=EnsureRange(Params.Width,0.5,15)*0.5;
      Count:=StrToIntDef(W.Tags.GetLower('step_count'),0);
      if Count<=0 then Count:=Round(Rise/0.16);
      Count:=EnsureRange(Count,1,Min(2048,Max(1,Trunc(Total/0.12))));
      SetLength(EdgesL,Count+1);SetLength(EdgesR,Count+1);K:=0;
      for I:=0 to Count do begin
        L:=Total*I/Count;
        while (K<Valid-2) and (Distances[K+1]<L) do Inc(K);
        T:=(L-Distances[K])/(Distances[K+1]-Distances[K]);
        V:=Points[K]+(Points[K+1]-Points[K])*T;
        DX:=Points[K+1].X-Points[K].X;DZ:=Points[K+1].Z-Points[K].Z;
        H:=Hypot(DX,DZ);Q:=Vector3(-DZ/H*Width,0,DX/H*Width);
        EdgesL[I]:=V+Q;EdgesR[I]:=V-Q;
      end;
      for I:=0 to Count-1 do begin
        Across:=EdgesR[I]-EdgesL[I];Across.Y:=0;Across:=Across.Normalize;
        Forward:=(EdgesL[I+1]+EdgesR[I+1])-(EdgesL[I]+EdgesR[I]);Forward.Y:=0;Forward:=Forward.Normalize;
        H:=Max(EdgesL[I].Y,EdgesL[I+1].Y)+TRoadBuilder.ClassLift(rkFootway)+0.015;
        LowH:=Min(EdgesL[I].Y,EdgesL[I+1].Y)+TRoadBuilder.ClassLift(rkFootway)+0.015;
        { Winding is independent of the way direction or the sign of grade. }
        Quad(AtHeight(EdgesL[I],H),AtHeight(EdgesL[I+1],H),AtHeight(EdgesR[I+1],H),AtHeight(EdgesR[I],H));
        if EdgesL[I+1].Y>EdgesL[I].Y then
          Quad(AtHeight(EdgesR[I],LowH),AtHeight(EdgesL[I],LowH),AtHeight(EdgesL[I],H),AtHeight(EdgesR[I],H))
        else
          Quad(AtHeight(EdgesL[I+1],LowH),AtHeight(EdgesR[I+1],LowH),AtHeight(EdgesR[I+1],H),AtHeight(EdgesL[I+1],H));
        { Filled side faces meet the original ramp below the tread. }
        A:=EdgesL[I];B:=EdgesL[I+1];A.Y-=0.04;B.Y-=0.04;
        Quad(A,B,AtHeight(B,H),AtHeight(A,H));
        A:=EdgesR[I];B:=EdgesR[I+1];A.Y-=0.04;B.Y-=0.04;
        Quad(B,A,AtHeight(A,H),AtHeight(B,H));
      end;
      Inc(Result);
    end;
    C.AppendRawComposite(Tmp);
  finally Tmp.Free end;
end;
end.
