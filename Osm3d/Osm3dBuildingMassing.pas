unit Osm3dBuildingMassing;
{$mode objfpc}{$H+}

{ Small, bounded landmark modules. Inputs belong to the tile knowledge recipe;
  the result is ordinary baked building geometry, shared by game and Studio. }
interface
uses SysUtils, Math, fpjson, CastleVectors, Osm3dGeoMath, Osm3dGeomMesh,
  Osm3dGeomBuildings;
const
  BUILDING_MASSING_TAG = 'rezvivo:building_massing';
  BUILDING_MASSING_GENERATOR = 2;
type
  TColonnade = record
    FrontA, FrontB: TLatLon;
    Columns, Rows: Integer;
    PierWidth, Radius, OpeningHeight, TowerHeight: Double;
  end;
function ParseBuildingMassing(J:TJSONData):TColonnade;
function CanonicalBuildingMassing(J:TJSONData):string;
function EmitColonnade(const P:TColonnade; const Ring:array of TVector3;
  Projection:TLocalProjection; GroundY,BottomY,Height:Single; Mesh:TMesh;
  out Casters:TBuildingShadowCasters):Boolean;
implementation
procedure Require(B:Boolean; const S:string);
begin if not B then raise EConvertError.Create('building.massing: '+S) end;
function Number(O:TJSONObject; const Key:string; Lo,Hi:Double):Double;
var J:TJSONData;
begin
  J:=O.Find(Key); Require((J<>nil) and (J.JSONType=jtNumber),'number required: '+Key);
  Result:=J.AsFloat;
  Require(not IsNan(Result) and not IsInfinite(Result) and (Result>=Lo) and (Result<=Hi),'out of range: '+Key);
end;
function Geo(J:TJSONData):TLatLon;
var A:TJSONArray; X,Y:Double;
begin
  Require((J<>nil) and (J.JSONType=jtArray),'[longitude, latitude] required');
  A:=TJSONArray(J); Require(A.Count=2,'two coordinates required');
  Require((A[0].JSONType=jtNumber) and (A[1].JSONType=jtNumber),'numeric coordinates required');
  X:=A[0].AsFloat; Y:=A[1].AsFloat;
  Require(not IsNan(X) and not IsNan(Y) and (Abs(X)<=180) and (Abs(Y)<=85),'invalid coordinates');
  Result:=TLatLon.Make(Y,X);
end;
function ParseBuildingMassing(J:TJSONData):TColonnade;
var O:TJSONObject; I:Integer; V:Double; Proj:TLocalProjection;
begin
  Require((J<>nil) and (J.JSONType=jtObject),'object required'); O:=TJSONObject(J);
  for I:=0 to O.Count-1 do Require(Pos('|'+O.Names[I]+'|',
    '|version|type|front_start|front_end|columns|rows|pier_width_m|column_radius_m|opening_height_m|tower_height_m|')>0,
    'unknown field '+O.Names[I]);
  Require(Number(O,'version',1,1)=1,'unsupported version');
  Require(O.Get('type','')='colonnade','unsupported type');
  Result.FrontA:=Geo(O.Find('front_start')); Result.FrontB:=Geo(O.Find('front_end'));
  Proj:=TLocalProjection.Create(Result.FrontA,Result.FrontA.Lat);
  try V:=Proj.Project(Result.FrontB,0).Length finally Proj.Free end;
  Require((V>=10) and (V<=200),'front length must be 10..200 metres');
  V:=Number(O,'columns',1,24); Require(Frac(V)=0,'integral column count required'); Result.Columns:=Round(V);
  V:=Number(O,'rows',1,2); Require(Frac(V)=0,'integral row count required'); Result.Rows:=Round(V);
  Result.PierWidth:=Number(O,'pier_width_m',1,20);
  Result.Radius:=Number(O,'column_radius_m',0.2,2.5);
  Result.OpeningHeight:=Number(O,'opening_height_m',3,40);
  Result.TowerHeight:=Number(O,'tower_height_m',0,3);
end;
function CanonicalBuildingMassing(J:TJSONData):string;
var P:TColonnade; O:TJSONObject;
begin
  P:=ParseBuildingMassing(J);
  O:=TJSONObject.Create(['version',1,'type','colonnade',
    'front_start',TJSONArray.Create([P.FrontA.Lon,P.FrontA.Lat]),
    'front_end',TJSONArray.Create([P.FrontB.Lon,P.FrontB.Lat]),
    'columns',P.Columns,'rows',P.Rows,'pier_width_m',P.PierWidth,
    'column_radius_m',P.Radius,'opening_height_m',P.OpeningHeight,'tower_height_m',P.TowerHeight]);
  try Result:=O.AsJSON finally O.Free end;
end;

function EmitColonnade(const P:TColonnade; const Ring:array of TVector3;
  Projection:TLocalProjection; GroundY,BottomY,Height:Single; Mesh:TMesh;
  out Casters:TBuildingShadowCasters):Boolean;
const SIDES=16;
var A,B,U,V,Q:TVector3; Width,Depth,X,MinX,MaxX,MinZ,MaxZ,BeamTop,Step,RowZ,Area:Single;
    I,J,K:Integer;
  function World(X,Y,Z:Single):TVector3;
  begin Result:=A+U*X+V*Z+Vector3(0,GroundY+Y,0) end;
  procedure Quad(const P0,P1,P2,P3,N:TVector3);
  var T:Integer;
  begin
    T:=Mesh.AddVertex(P0,N,Vector2(0,0));
    Mesh.AddVertex(P1,N,Vector2((P1-P0).Length/4,0));
    Mesh.AddVertex(P2,N,Vector2((P1-P0).Length/4,0));
    Mesh.AddVertex(P3,N,Vector2(0,0));
    if TVector3.DotProduct(TVector3.CrossProduct(P1-P0,P2-P0),N)>0 then Mesh.AddQuad(T,T+1,T+2,T+3)
    else Mesh.AddQuad(T+3,T+2,T+1,T);
  end;
  procedure Box(X0,Y0,Z0,X1,Y1,Z1:Single);
  var C:array[0..7] of TVector3;
  begin
    C[0]:=World(X0,Y0,Z0); C[1]:=World(X1,Y0,Z0); C[2]:=World(X1,Y1,Z0); C[3]:=World(X0,Y1,Z0);
    C[4]:=World(X0,Y0,Z1); C[5]:=World(X1,Y0,Z1); C[6]:=World(X1,Y1,Z1); C[7]:=World(X0,Y1,Z1);
    Quad(C[0],C[1],C[2],C[3],-V); Quad(C[4],C[5],C[6],C[7],V);
    Quad(C[0],C[4],C[7],C[3],-U); Quad(C[1],C[5],C[6],C[2],U);
    Quad(C[0],C[1],C[5],C[4],Vector3(0,-1,0)); Quad(C[3],C[2],C[6],C[7],Vector3(0,1,0));
  end;
  procedure Caster(X0,Z0,X1,Z1,Base,Top:Single; OpenBelow:Boolean);
  var N:Integer;
  begin
    N:=Length(Casters); SetLength(Casters,N+1); SetLength(Casters[N].Footprint,4);
    Casters[N].Footprint[0]:=World(X0,0,Z0); Casters[N].Footprint[1]:=World(X1,0,Z0);
    Casters[N].Footprint[2]:=World(X1,0,Z1); Casters[N].Footprint[3]:=World(X0,0,Z1);
    Casters[N].BaseY:=GroundY+Base; Casters[N].MaxY:=GroundY+Top;
    Casters[N].GroundY:=BottomY; Casters[N].KeepGroundUnder:=OpenBelow;
  end;
  procedure Column(CX,CZ:Single);
  var L,S,T:Integer; A0,A1,Y0,Y1,R0,R1:Single; N0,N1,C0,C1,C2,C3:TVector3;
      H:Single;
  begin
    H:=P.OpeningHeight;
    Box(CX-P.Radius*1.22,BottomY-GroundY,CZ-P.Radius*1.22,CX+P.Radius*1.22,0.35,CZ+P.Radius*1.22);
    Box(CX-P.Radius*1.22,H-0.4,CZ-P.Radius*1.22,CX+P.Radius*1.22,H,CZ+P.Radius*1.22);
    for L:=0 to 1 do begin
      Y0:=0.35+(H-0.75)*L/2; Y1:=0.35+(H-0.75)*(L+1)/2;
      if L=0 then begin R0:=P.Radius;R1:=P.Radius*1.025 end
      else begin R0:=P.Radius*1.025;R1:=P.Radius*0.91 end;
      for S:=0 to SIDES-1 do begin
        A0:=S*2*Pi/SIDES; A1:=(S+1)*2*Pi/SIDES;
        N0:=U*Cos(A0)+V*Sin(A0); N1:=U*Cos(A1)+V*Sin(A1);
        C0:=World(CX,Y0,CZ)+N0*R0; C1:=World(CX,Y0,CZ)+N1*R0;
        C2:=World(CX,Y1,CZ)+N1*R1; C3:=World(CX,Y1,CZ)+N0*R1;
        N0:=(N0+Vector3(0,(R0-R1)/(Y1-Y0),0)).Normalize;
        N1:=(N1+Vector3(0,(R0-R1)/(Y1-Y0),0)).Normalize;
        T:=Mesh.AddVertex(C0,N0,Vector2(0,0)); Mesh.AddVertex(C1,N1,Vector2(0.25,0));
        Mesh.AddVertex(C2,N1,Vector2(0.25,0)); Mesh.AddVertex(C3,N0,Vector2(0,0));
        if TVector3.DotProduct(TVector3.CrossProduct(C1-C0,C2-C0),N0)>0 then Mesh.AddQuad(T,T+1,T+2,T+3)
        else Mesh.AddQuad(T+3,T+2,T+1,T);
      end;
    end;
    Caster(CX-P.Radius*1.22,CZ-P.Radius*1.22,CX+P.Radius*1.22,CZ+P.Radius*1.22,0,H,False);
  end;
begin
  Result:=False; Casters:=nil;
  if (Length(Ring)<4) or (Height<P.OpeningHeight+P.TowerHeight+1) then Exit;
  A:=Projection.Project(P.FrontA,0); B:=Projection.Project(P.FrontB,0);
  Width:=(B-A).Length; U:=(B-A)/Width; V:=TVector3.CrossProduct(U,Vector3(0,1,0));
  Q:=Vector3(0,0,0); for I:=0 to High(Ring) do Q:=Q+Ring[I]; Q:=Q/Length(Ring)-A;
  if TVector3.DotProduct(Q,V)<0 then V:=-V;
  MinX:=1e30;MaxX:=-1e30;MinZ:=1e30;MaxZ:=-1e30;
  for I:=0 to High(Ring) do begin
    Q:=Ring[I]-A; X:=TVector3.DotProduct(Q,U); Depth:=TVector3.DotProduct(Q,V);
    MinX:=Min(MinX,X);MaxX:=Max(MaxX,X);MinZ:=Min(MinZ,Depth);MaxZ:=Max(MaxZ,Depth);
  end;
  if (Abs(MinX)>1) or (Abs(MaxX-Width)>1) or (Abs(MinZ)>1) then Exit;
  Depth:=MaxZ-MinZ;
  if (Depth<Max(3,P.Radius*5)) or (Depth>40) then Exit;
  Area:=0;
  for I:=0 to High(Ring) do begin
    { Only approximately rectangular footprints; never erase an L-shaped wing. }
    Q:=Ring[I]-A; X:=TVector3.DotProduct(Q,U); RowZ:=TVector3.DotProduct(Q,V);
    { The real entrance outline has shallow 1.06 m recesses between its piers. }
    if Min(Min(Abs(X),Abs(X-Width)),Min(Abs(RowZ-MinZ),Abs(RowZ-MaxZ)))>1.25 then Exit;
    B:=Ring[(I+1) mod Length(Ring)]-A;
    Area:=Area+Q.X*B.Z-B.X*Q.Z;
  end;
  if Abs(Area)*0.5<Width*Depth*0.90 then Exit;
  Step:=(Width-2*P.PierWidth)/(P.Columns+1);
  if Step<2*P.Radius*1.22+1 then Exit;
  A:=A+V*MinZ; BeamTop:=Height-P.TowerHeight;
  for K:=0 to 1 do begin
    X:=K*(Width-P.PierWidth);
    Box(X,BottomY-GroundY,0,X+P.PierWidth,P.OpeningHeight,Depth);
    Caster(X,0,X+P.PierWidth,Depth,0,Height,False);
    if P.TowerHeight>0 then Box(X+0.35,BeamTop,0.35,X+P.PierWidth-0.35,Height,Depth-0.35);
    { Recessed panel frames: silhouette cues, without pretending to reproduce sculpture. }
    for J:=0 to 1 do begin
      RowZ:=J*Depth;
      Box(X+0.7,1.0,RowZ-0.10,X+P.PierWidth-0.7,1.22,RowZ+0.10);
      Box(X+0.7,P.OpeningHeight-0.9,RowZ-0.10,X+P.PierWidth-0.7,P.OpeningHeight-0.65,RowZ+0.10);
    end;
  end;
  Box(0,P.OpeningHeight,0,Width,BeamTop,Depth);
  Box(-0.3,P.OpeningHeight+0.15,-0.3,Width+0.3,P.OpeningHeight+0.55,Depth+0.3);
  Box(-0.35,BeamTop-0.32,-0.35,Width+0.35,BeamTop,Depth+0.35);
  Caster(0,0,Width,Depth,P.OpeningHeight,BeamTop,True);
  for J:=0 to P.Rows-1 do begin
    if P.Rows=1 then RowZ:=Depth/2
    else RowZ:=P.Radius*1.35+J*(Depth-P.Radius*2.7);
    for I:=1 to P.Columns do Column(P.PierWidth+Step*I,RowZ);
  end;
  Result:=True;
end;
end.
