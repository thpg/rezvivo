program ArchitectureTests;
{$mode objfpc}{$H+}
uses SysUtils, Math, fpjson, jsonparser, CastleVectors, Osm3dGeoMath,
  Osm3dGeomMesh, Osm3dArchitecture;
var Checks:Integer;
procedure Check(B:Boolean; const S:string);
begin Inc(Checks);if not B then raise Exception.Create(S) end;
function ReadJSON(const Path:string):TJSONData;
var S:RawByteString;F:TextFile;Line:string;
begin S:='';AssignFile(F,Path);Reset(F);while not Eof(F) do begin ReadLn(F,Line);S:=S+Line end;CloseFile(F);Result:=GetJSON(S) end;
function Ray(M:TMesh;X,Y:Single; IncludePanes:Boolean; out Z:Single):Boolean;
var I:Integer;A,B,C,E1,E2,H,Q,S,D,O:TVector3;Det,U,V,T,Dist:Single;
begin
  Result:=False;Dist:=1e20;D:=Vector3(0,0,-1);O:=Vector3(X,Y,10);
  for I:=0 to M.TriangleCount-1 do begin
    if not IncludePanes and (M.Vertices[M.Indices[I*3]].UV.Y<=ARCHITECTURE_UV_MARKER-65536) then Continue;
    A:=M.Vertices[M.Indices[I*3]].Position;B:=M.Vertices[M.Indices[I*3+1]].Position;C:=M.Vertices[M.Indices[I*3+2]].Position;
    E1:=B-A;E2:=C-A;H:=TVector3.CrossProduct(D,E2);Det:=TVector3.DotProduct(E1,H);if Abs(Det)<1e-8 then Continue;
    S:=O-A;U:=TVector3.DotProduct(S,H)/Det;if (U<0) or (U>1) then Continue;
    Q:=TVector3.CrossProduct(S,E1);V:=TVector3.DotProduct(D,Q)/Det;if (V<0) or (U+V>1) then Continue;
    T:=TVector3.DotProduct(E2,Q)/Det;
    if (T>=0) and (T<Dist) then begin Dist:=T;Z:=10-T;Result:=True end;
  end;
end;
procedure Geometry(M:TMesh);
var I:Integer;A,B,C,N:TVector3;
begin
  for I:=0 to M.VertexCount-1 do begin
    Check(M.Vertices[I].OsmId=314,'OSM picking identity');
    Check(Abs(M.Vertices[I].Normal.Length-1)<0.0001,'unit normals');
    Check(IsArchitectureUV(M.Vertices[I].UV),'tagged surface');
  end;
  for I:=0 to M.TriangleCount-1 do begin
    A:=M.Vertices[M.Indices[I*3]].Position;B:=M.Vertices[M.Indices[I*3+1]].Position;C:=M.Vertices[M.Indices[I*3+2]].Position;
    N:=M.Vertices[M.Indices[I*3]].Normal;
    Check(TVector3.DotProduct(TVector3.CrossProduct(B-A,C-A),N)>1e-8,'nondegenerate outward triangle '+IntToStr(I));
  end;
end;
procedure Run;
var J,K:TJSONData;S,T:string;R:TArchitectureRecipe;M,Spl:TMesh;P:TLocalProjection;
    Poly:array[0..3] of TVector3;C:TArchCasters;Z:Single;Rejected:Boolean;Row,Face:TJSONObject;I:Integer;
begin
  J:=GetJSON('{"version":1,"facades":[{"start":[37,55],"end":[36.999373,55],"wall_color":"#accec1",'+
    '"rows":[{"x_m":4,"bottom_m":1,"width_m":2,"height_m":3,"count":3,"step_m":5,"shape":"round_arch","mullions_x":0}],'+
    '"components":[{"kind":"cornice","x_m":10,"bottom_m":8,"width_m":20,"height_m":0.4,"depth_m":0.45},'+
    '{"kind":"column","x_m":5,"width_m":0.8,"depth_m":0.8,"height_m":6,"offset_m":2,"count":2,"step_m":8},'+
    '{"kind":"pediment","x_m":10,"bottom_m":8.4,"width_m":20,"height_m":3,"depth_m":0.8},'+
    '{"kind":"dome","x_m":10,"bottom_m":0,"offset_m":-7,"width_m":6,"depth_m":6,"height_m":4,"anchor":"ridge"}]}]}');
  M:=TMesh.Create;Spl:=TMesh.Create;
  try
    S:=CanonicalArchitecture(J);K:=GetJSON(S);
    try T:=CanonicalArchitecture(K);Check(S=T,'canonical compact round trip') finally K.Free end;
    Face:=TJSONObject(TJSONArray(TJSONObject(J).Find('facades'))[0]);Row:=TJSONObject(TJSONArray(Face.Find('rows'))[0]);
    Face.Floats['metallic']:=0.8;R:=ParseArchitecture(J);Check(Abs(R.Facades[0].Metallic-0.8)<0.00001,'metal facade uses shared PBR');
    K:=GetJSON(CanonicalArchitecture(J));try R:=ParseArchitecture(K);Check(Abs(R.Facades[0].Metallic-0.8)<0.00001,'metallic survives canonical recipe') finally K.Free end;
    Face.Delete('metallic');
    Row.Floats['count']:=2.5;Rejected:=False;try R:=ParseArchitecture(J) except on E:EConvertError do Rejected:=True end;
    Check(Rejected,'reject fractional count');Row.Integers['count']:=3;
    Row.Floats['step_m']:=1;Rejected:=False;try R:=ParseArchitecture(J) except on E:EConvertError do Rejected:=True end;
    Check(Rejected,'reject overlapping windows');Row.Floats['step_m']:=5;
    R:=ParseArchitecture(J);Check(Length(R.Facades[0].Openings)=3,'expanded row');
    P:=TLocalProjection.Create(R.Facades[0].Start,55);
    try
      Poly[0]:=Vector3(0,0,0);Poly[1]:=Vector3(40,0,0);Poly[2]:=Vector3(40,0,-15);Poly[3]:=Vector3(0,0,-15);
      R.Facades[0].Finish:=P.Unproject(40,0);ProjectArchitecture(R,P,Poly);
      Check(Length(R.Facades)=1,'facade matches OSM footprint');
    finally P.Free end;
    M.CurrentOsmId:=314;Spl.CurrentOsmId:=314;
    Check(EmitArchitecturalWall(R.Facades,Poly[0],Poly[1],Vector3(0,0,1),8,M),'facade replacement');
    Check(Ray(M,4,2,True,Z) and (Abs(Z+0.16)<0.001),'recessed glass, no original solid wall behind opening');
    Check(not Ray(M,4,2,False,Z),'actual aperture before glazing');
    Check(Ray(M,3.05,3.95,False,Z) and (Abs(Z)<0.001),'solid wall outside round arch');
    Check(Ray(M,2,2,False,Z) and (Abs(Z)<0.001),'solid pier');
    Check(EmitArchitecturalWall(R.Facades,Poly[0],Vector3(4.3,0,0),Vector3(0,0,1),8,Spl),'split first wall');
    Check(EmitArchitecturalWall(R.Facades,Vector3(4.3,0,0),Poly[1],Vector3(0,0,1),8,Spl),'split second wall');
    for I:=0 to 70 do begin
      Check(Ray(M,2+I*0.08,2.5,True,Z),'whole wall watertight');
      Check(Ray(Spl,2+I*0.08,2.5,True,Z),'collinear split watertight');
    end;
    Geometry(M);Geometry(Spl);Writeln('facade triangles=',M.TriangleCount);
    EmitArchitecturalParts(R,0,8,11,M,C);Check(Length(C)=5,'repeat expansion and separate component casters');
    Geometry(M);Check(M.TriangleCount<2500,'small landmark stays below 2500 triangles');
    Writeln('landmark triangles=',M.TriangleCount,' vertices=',M.VertexCount);
    M.Clear;M.CurrentOsmId:=314;Check(not EmitArchitecturalWall(R.Facades,Poly[0],Poly[1],Vector3(0,0,1),2,M),'invalid headroom keeps old wall');
    Check(M.VertexCount=0,'no partially emitted replacement');
  finally M.Free;Spl.Free;J.Free end;
end;
procedure AllComponents;
const Names:array[0..18] of string=('block','pilaster','column','cornice','pediment','canopy','steps','balcony','arch','drum','dome','spire','gable_roof',
  'capital','pediment_frame','dentil_course','rosette','wall_panel','quoins');
var I:Integer;J,K:TJSONData;R:TArchitectureRecipe;M:TMesh;C:TArchCasters;F:TJSONObject;
    S:string;Z:Single;
begin
  M:=TMesh.Create;M.CurrentOsmId:=314;
  try
    for I:=0 to High(Names) do begin
      J:=GetJSON('{"version":1,"facades":[{"start":[37,55],"end":[36.999373,55],"components":['+
        '{"kind":"'+Names[I]+'","x_m":10,"width_m":3,"height_m":4,"depth_m":3}]}]}');
      try
        F:=TJSONObject(TJSONArray(TJSONObject(J).Find('facades'))[0]);
        if Names[I]='cornice' then TJSONObject(TJSONArray(F.Find('components'))[0]).Add('profile',
          GetJSON('[[0,0.15],[0.1,0.15],[0.2,0.35],[0.3,0.65],[0.4,0.85],[0.5,0.95],[0.6,1],[1,1]]'));
        S:=CanonicalArchitecture(J);K:=GetJSON(S);
        try Check(CanonicalArchitecture(K)=S,'component canonical '+Names[I]) finally K.Free end;
        R:=ParseArchitecture(J);R.Facades[0].A:=Vector3(0,0,0);R.Facades[0].B:=Vector3(40,0,0);
        M.Clear;M.CurrentOsmId:=314;EmitArchitecturalParts(R,0,8,11,M,C);Geometry(M);
        Check(Length(C)=1,'one component caster');Check(M.TriangleCount<512,'component cost cap');
        Writeln(Names[I],': ',M.TriangleCount,' triangles, ',M.VertexCount,' vertices');
      finally J.Free end;
    end;
    J:=GetJSON('{"version":1,"facades":[{"start":[37,55],"end":[36.999373,55],"inset_m":3}]}');
    try R:=ParseArchitecture(J) finally J.Free end;
    R.Facades[0].A:=Vector3(0,0,0);R.Facades[0].B:=Vector3(40,0,0);M.Clear;M.CurrentOsmId:=314;
    Check(EmitArchitecturalWall(R.Facades,Vector3(0,0,0),Vector3(40,0,0),Vector3(0,0,1),8,M),'portico wall');
    Check(Ray(M,20,4,True,Z) and (Abs(Z+3)<0.001),'portico has no solid wall at the column plane');Geometry(M);
  finally M.Free end;
end;
procedure DecorationChecks;
const Styles:array[0..2] of string=('doric','ionic','foliate');
var J,K:TJSONData;R:TArchitectureRecipe;M:TMesh;C:TArchCasters;
    Part:TJSONObject;S:string;I,V:Integer;Z:Single;Rejected:Boolean;
begin
  M:=TMesh.Create;
  try
    for I:=0 to High(Styles) do begin
      J:=GetJSON('{"version":1,"facades":[{"start":[37,55],"end":[36.999373,55],"components":['+
        '{"kind":"capital","style":"'+Styles[I]+'","x_m":10,"width_m":1.2,"height_m":0.8,"depth_m":0.9}]}]}');
      try
        S:=CanonicalArchitecture(J);K:=GetJSON(S);
        try Check(CanonicalArchitecture(K)=S,'capital style roundtrip') finally K.Free end;
        R:=ParseArchitecture(J);R.Facades[0].A:=Vector3(0,0,0);R.Facades[0].B:=Vector3(40,0,0);
        M.Clear;M.CurrentOsmId:=314;EmitArchitecturalParts(R,0,8,11,M,C);Geometry(M);
        for V:=0 to M.VertexCount-1 do with M.Vertices[V].Position do begin
          Check((X>=9.4-0.001) and (X<=10.6+0.001) and (Y>=-0.001) and (Y<=0.801) and (Z>=-0.001) and (Z<=0.901),'capital dimensions bound actual geometry');
          Check((Y>=C[0].BaseY-0.001) and (Y<=C[0].MaxY+0.001),'capital caster includes relief');
        end;
        Writeln('capital ',Styles[I],': ',M.TriangleCount,' triangles');
      finally J.Free end;
    end;
    J:=GetJSON('{"version":1,"facades":[{"start":[37,55],"end":[36.999373,55],"components":['+
      '{"kind":"pediment_frame","x_m":10,"bottom_m":5,"width_m":12,"height_m":2,"depth_m":0.2}]}]}');
    try
      R:=ParseArchitecture(J);R.Facades[0].A:=Vector3(0,0,0);R.Facades[0].B:=Vector3(40,0,0);
      M.Clear;M.CurrentOsmId:=314;EmitArchitecturalParts(R,0,8,11,M,C);
      Check(not Ray(M,10,5.8,True,Z),'pediment frame has open centre');
      Check(Ray(M,10,5.03,True,Z),'pediment lower moulding exists');
      Part:=TJSONObject(TJSONArray(TJSONObject(TJSONArray(TJSONObject(J).Find('facades'))[0]).Find('components'))[0]);
      Part.Strings['kind']:='dentil_course';Part.Add('spacing_m',0.1);
      Rejected:=False;try R:=ParseArchitecture(J) except on E:EConvertError do Rejected:=True end;
      Check(Rejected,'oversized dentil repetition rejected before meshing');
      Part.Floats['spacing_m']:=0.65;Part.Add('style','ionic');
      Rejected:=False;try R:=ParseArchitecture(J) except on E:EConvertError do Rejected:=True end;
      Check(Rejected,'capital style not silently ignored on other components');
    finally J.Free end;
  finally M.Free end;
end;
procedure ReversedFacade;
var R:TArchitectureRecipe;P:TLocalProjection;Poly:array[0..3] of TVector3;
  J:TJSONData;M:TMesh;Z:Single;
begin
  P:=TLocalProjection.Create(TLatLon.Make(55,37));M:=TMesh.Create;M.CurrentOsmId:=314;
  J:=GetJSON('{"version":1,"facades":[{"start":[37,55],"end":[37.0006,55],"rows":[{"x_m":4,"bottom_m":1,"width_m":2,"height_m":2}],"components":[{"kind":"pilaster","x_m":2,"width_m":0.3,"height_m":4,"depth_m":0.2,"count":3,"step_m":5}]}]}');
  try
    R:=ParseArchitecture(J);
    Poly[0]:=Vector3(0,0,0);Poly[1]:=Vector3(40,0,0);Poly[2]:=Vector3(40,0,-15);Poly[3]:=Vector3(0,0,-15);
    R.Facades[0].Start:=P.Unproject(40,0);R.Facades[0].Finish:=P.Unproject(0,0);
    ProjectArchitecture(R,P,Poly);
    Check(Length(R.Facades)=1,'reverse edge keeps authored facade');
    Check(Abs(R.Facades[0].Openings[0].X-36)<0.001,'reverse edge preserves opening world position');
    Check(Abs(R.Facades[0].Components[0].X-28)<0.001,'reverse edge preserves repeated piers');
    Check(EmitArchitecturalWall(R.Facades,Poly[0],Poly[1],Vector3(0,0,1),8,M),'reverse edge emits native wall');
    Check(Ray(M,36.35,2.2,True,Z) and (Z<0),'reverse edge opening remains recessed');
    Check(not Ray(M,36.35,2.2,False,Z),'reverse edge does not seal aperture');
    Geometry(M);
  finally J.Free;M.Free;P.Free end;
end;
begin Run;AllComponents;DecorationChecks;ReversedFacade;Writeln('PASS ',Checks) end.
