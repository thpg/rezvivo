unit Osm3dCompoundRoof;
{$mode objfpc}{$H+}
{ Photo-authored roof wings. The upper envelope is clipped to the existing
  triangulated OSM footprint, including its courtyard holes. Everything is
  baked once into the ordinary building batch; no runtime objects or CSG. }
interface
uses SysUtils, Math, fpjson, CastleVectors, Osm3dGeoMath, Osm3dGeomMesh;
const
  COMPOUND_ROOF_TAG = 'rezvivo:roof_layout';
  COMPOUND_ROOF_GENERATOR = 1;
type
  TCompoundRoofShape = (crFlat, crGabled, crHipped, crSkillion);
  TCompoundRoofPart = record
    Shape:TCompoundRoofShape;
    A,B:TLatLon;
    Width,Eave,Ridge:Single;
    Color:Cardinal;
    Roughness,Metallic:Single;
  end;
  TCompoundRoofRecipe = record
    Eave:Single;
    Color,WallColor:Cardinal;
    Parts:array of TCompoundRoofPart;
  end;
function CompoundRoofCapabilities:TJSONObject;
function ParseCompoundRoof(J:TJSONData):TCompoundRoofRecipe;
function CanonicalCompoundRoof(J:TJSONData):string;
function CompoundRoofMaxHeight(const R:TCompoundRoofRecipe):Single;
{ Domain is an already triangulated flat OSM roof. Output is transactional:
  invalid/costly geometry never partially modifies the caller's mesh. }
function EmitCompoundRoof(const R:TCompoundRoofRecipe; Projection:TLocalProjection;
  Domain:TMesh; BaseY:Single; Target:TMesh):Boolean;
implementation
uses Osm3dArchitecture, Osm3dPolygonClipXZ;
const Names:array[TCompoundRoofShape] of string=('flat','gabled','hipped','skillion');
  Eps=0.00001;
  MaxPieces=8192;
type
  TPoly=TXZClipPolygon;
  TPolys=TXZClipPolygons;
  TPlane=record X,Z,C:Double end;
  TSurface=record P:TPoly; Plane:TPlane; UV:TVector2 end;
  TSurfaces=array of TSurface;
  TNumbers=array of Double;

procedure Check(B:Boolean;const S:string);
begin if not B then raise EConvertError.Create('roof.layout: '+S) end;
procedure Keys(O:TJSONObject;const Allowed:string);
var I:Integer;
begin for I:=0 to O.Count-1 do Check(Pos('|'+O.Names[I]+'|',Allowed)>0,'unknown field '+O.Names[I]) end;
function Obj(J:TJSONData):TJSONObject;
begin Check((J<>nil) and (J.JSONType=jtObject),'object required');Result:=TJSONObject(J) end;
function Num(O:TJSONObject;const Key:string; Default,Lo,Hi:Double):Double;
var J:TJSONData;
begin
  Result:=Default;J:=O.Find(Key);if J=nil then Exit;
  Check(J.JSONType=jtNumber,Key+' must be numeric');Result:=J.AsFloat;
  Check(not IsNan(Result) and not IsInfinite(Result) and (Result>=Lo) and (Result<=Hi),Key+' out of range');
end;
function Str(O:TJSONObject;const Key,Default:string):string;
var J:TJSONData;
begin J:=O.Find(Key);if J=nil then Exit(Default);Check(J.JSONType=jtString,Key+' must be a string');Result:=J.AsString end;
function Color(O:TJSONObject;const Key,Default:string):Cardinal;
var S:string;I:Integer;
begin
  S:=Str(O,Key,Default);Check((Length(S)=7) and (S[1]='#'),Key+' must be #RRGGBB');
  for I:=2 to 7 do Check(S[I] in ['0'..'9','a'..'f','A'..'F'],Key+' must be #RRGGBB');
  Result:=StrToInt('$'+Copy(S,2,6));
end;
function Geo(J:TJSONData):TLatLon;
var A:TJSONArray;Lat,Lon:Double;
begin
  Check((J<>nil) and (J.JSONType=jtArray) and (J.Count=2),'axis endpoints must be [longitude,latitude]');A:=TJSONArray(J);
  Check((A[0].JSONType=jtNumber) and (A[1].JSONType=jtNumber),'numeric coordinate required');Lon:=A[0].AsFloat;Lat:=A[1].AsFloat;
  Check(not IsNan(Lon) and not IsNan(Lat) and (Abs(Lon)<=180) and (Abs(Lat)<=85),'invalid coordinate');Result:=TLatLon.Make(Lat,Lon);
end;
function CompoundRoofCapabilities:TJSONObject;
begin
  Result:=TJSONObject.Create(['version',1,'generator',COMPOUND_ROOF_GENERATOR,
    'shapes','flat, gabled, hipped, skillion',
    'coordinates','parts: axis_start/axis_end [lon,lat] define the rectangular wing centre line, width_m across it. No automatic axis rotation. Coordinates are clipped to the actual OSM building and courtyard holes.',
    'heights','root eave_m above building base sets the wall top. Each part eave_m (default root), ridge_m are absolute heights above the same base, never relative rises; ridge >= eave >= root eave. A skillion rises across the width toward axis cross up.',
    'materials','root color and wall_color; parts may override color, roughness, metallic. Baked into the shared building material.',
    'combination','Overlapping wings use only the visible upper surface; intersections form valleys. Uncovered footprint remains a flat deck at root eave_m. Courtyards stay open, including on raised sections; exposed gables and height steps are closed.',
    'limits','1..24 wings, axis length 1..500 m, width 0.5..150 m, eave 0.5..300 m, rise <= 50 m; 1024 input footprint triangles and 32768 output triangles; bounded clipping cost, safe fallback on unsuitable geometry.',
    'replaces','Replaces the complete default roof and its overhang; does not cover the courtyard or add a second hidden default roof. Compatible with building.architecture, incompatible with building.massing.']);
end;
function ParseCompoundRoof(J:TJSONData):TCompoundRoofRecipe;
var O,P:TJSONObject;Items:TJSONArray;I,K:Integer;S:string;Proj:TLocalProjection;D:TVector3;
begin
  Result:=Default(TCompoundRoofRecipe);O:=Obj(J);Keys(O,'|version|eave_m|color|wall_color|parts|');
  Check(Num(O,'version',0,1,1)=1,'version 1 required');Check(O.Find('eave_m')<>nil,'eave_m required');
  Result.Eave:=Num(O,'eave_m',0,0.5,300);Result.Color:=Color(O,'color','#596166');Result.WallColor:=Color(O,'wall_color','#d2cdc1');
  Check((O.Find('parts')<>nil) and (O.Find('parts').JSONType=jtArray),'parts array required');Items:=TJSONArray(O.Find('parts'));
  Check((Items.Count>=1) and (Items.Count<=24),'1..24 parts required');SetLength(Result.Parts,Items.Count);
  for I:=0 to Items.Count-1 do begin
    P:=Obj(Items[I]);Keys(P,'|shape|axis_start|axis_end|width_m|eave_m|ridge_m|color|roughness|metallic|');
    S:=Str(P,'shape','gabled');K:=0;while (K<=Ord(High(TCompoundRoofShape))) and (Names[TCompoundRoofShape(K)]<>S) do Inc(K);
    Check(K<=Ord(High(TCompoundRoofShape)),'unknown roof shape '+S);
    with Result.Parts[I] do begin
      Shape:=TCompoundRoofShape(K);
      Result.Parts[I].A:=Geo(P.Find('axis_start'));B:=Geo(P.Find('axis_end'));
      Width:=Num(P,'width_m',0,0.5,150);Check(P.Find('width_m')<>nil,'width_m required');
      { Recipe JSON is double precision, stored dimensions are float32.
        Compare in that common representation: e.g. JSON 10.8 is slightly
        below float32(10.8), although these are the same authored height. }
      Eave:=Num(P,'eave_m',Result.Eave,0.5,300);
      Check(Eave>=Result.Eave,'part eave_m must not be below root eave_m');
      Ridge:=Num(P,'ridge_m',Eave,0.5,350);
      Check(Ridge>=Eave,'ridge_m must not be below part eave_m');
      Check(Ridge-Eave<=50.00003,'roof rise exceeds 50 m');
      Check((Shape=crFlat) or (Ridge>Eave),'pitched roof needs ridge above eave');Check((Shape<>crFlat) or (Ridge=Eave),'flat roof has equal eave and ridge');
      Color:=Osm3dCompoundRoof.Color(P,'color','#'+IntToHex(Result.Color,6));Roughness:=Num(P,'roughness',0.82,0.05,1);Metallic:=Num(P,'metallic',0,0,1);
      Proj:=TLocalProjection.Create(Result.Parts[I].A,Result.Parts[I].A.Lat);
      try D:=Proj.Project(B,0);Check((D.Length>=1) and (D.Length<=500),'axis length outside 1..500 m') finally Proj.Free end;
    end;
  end;
end;
function CanonicalCompoundRoof(J:TJSONData):string;
var R:TCompoundRoofRecipe;O,P:TJSONObject;Items:TJSONArray;I:Integer;
begin
  R:=ParseCompoundRoof(J);Items:=TJSONArray.Create;O:=TJSONObject.Create(['version',1,'eave_m',R.Eave,
    'color','#'+LowerCase(IntToHex(R.Color,6)),'wall_color','#'+LowerCase(IntToHex(R.WallColor,6)),'parts',Items]);
  try
    for I:=0 to High(R.Parts) do with R.Parts[I] do begin
      P:=TJSONObject.Create(['shape',Names[Shape],'axis_start',TJSONArray.Create([R.Parts[I].A.Lon,R.Parts[I].A.Lat]),
        'axis_end',TJSONArray.Create([B.Lon,B.Lat]),'width_m',Width,'eave_m',Eave,'ridge_m',Ridge,
        'color','#'+LowerCase(IntToHex(Color,6)),'roughness',Roughness,'metallic',Metallic]);Items.Add(P);
    end;
    Result:=O.AsJSON;
  finally O.Free end;
end;
function CompoundRoofMaxHeight(const R:TCompoundRoofRecipe):Single;
var I:Integer;
begin Result:=R.Eave;for I:=0 to High(R.Parts) do Result:=Max(Result,R.Parts[I].Ridge) end;

function IntersectPoly(const A,B:TPoly):TPoly;
var I:Integer;D:TVector2;
begin
  Result:=A;
  for I:=0 to High(B) do begin D:=B[(I+1) mod Length(B)]-B[I];Result:=XZClipHalfPlane(Result,-D.Y,D.X,D.Y*B[I].X-D.X*B[I].Y);if Length(Result)<3 then Exit end;
end;
function HeightAt(const P:TPlane;const V:TVector2):Double;inline;
begin Result:=P.X*V.X+P.Z*V.Y+P.C end;
function Contains(const P:TPoly;const V:TVector2):Boolean;
var I:Integer;
begin Result:=False;for I:=0 to High(P) do if XZCross(P[(I+1) mod Length(P)]-P[I],V-P[I])<-0.00001 then Exit;Result:=True end;

function EmitCompoundRoof(const R:TCompoundRoofRecipe; Projection:TLocalProjection;
  Domain:TMesh; BaseY:Single; Target:TMesh):Boolean;
var Faces,Final:TSurfaces;Domains:TPolys;Origin:TVector3;M:TMesh;Vertices:TMeshVertexArray;Indices:TMeshIndexArray;
  I,J,K,L,Edge,PartIndex:Integer;S:TSurface;P,Cut:TPoly;Work,Next:TPolys;
  A,B,U,V:TVector3;Len,W,Hip:Single;UV:TVector2;
  T:TNumbers;E0,E1,D,Normal,A2,B2,Mid:TVector2;Own0,Own1,Low0,Low1,TM:Double;Neighbor:TPlane;
  function World(const V:TVector2;Y:Single):TVector3;
  begin Result:=Vector3(V.X+Origin.X,Y+BaseY,V.Y+Origin.Z) end;
  procedure EmitTri(const A,B,C,N:TVector3;const UV:TVector2);
  var IA,IB,IC:Integer;B1,C1:TVector3;
  begin
    if TVector3.CrossProduct(B-A,C-A).Length<0.000001 then Exit;
    B1:=B;C1:=C;if TVector3.DotProduct(TVector3.CrossProduct(B1-A,C1-A),N)<0 then begin B1:=C;C1:=B end;
    IA:=M.AddVertex(A,N,UV);IB:=M.AddVertex(B1,N,UV);IC:=M.AddVertex(C1,N,UV);M.AddTriangle(IA,IB,IC);
    Check(M.TriangleCount<=32768,'output triangle budget exceeded');
  end;
  procedure Face(const Points:array of TVector3);
  var F:TSurface;I,J,Count:Integer;A,B,C,N3:TVector3;V:TVector2;
  begin
    SetLength(F.P,Length(Points));Count:=0;
    for I:=0 to High(Points) do begin
      V:=Vector2(Points[I].X,Points[I].Z);
      if (Count>0) and ((F.P[Count-1]-V).Length<0.00001) then Continue;
      F.P[Count]:=V;Inc(Count);
    end;
    if (Count>1) and ((F.P[0]-F.P[Count-1]).Length<0.00001) then Dec(Count);
    SetLength(F.P,Count);if Count<3 then Exit;
    if Abs(XZPolygonArea(F.P))<Eps then Exit;
    A:=Points[0];N3:=Vector3(0,0,0);
    for I:=1 to High(Points)-1 do begin B:=Points[I];C:=Points[I+1];N3:=TVector3.CrossProduct(B-A,C-A);if Abs(N3.Y)>0.000001 then Break end;
    Check(Abs(N3.Y)>0.000001,'vertical surface used as roof');F.Plane.X:=-N3.X/N3.Y;F.Plane.Z:=-N3.Z/N3.Y;
    F.Plane.C:=A.Y-F.Plane.X*A.X-F.Plane.Z*A.Z;F.UV:=UV;
    if XZPolygonArea(F.P)<0 then for I:=0 to Length(F.P) div 2-1 do begin J:=High(F.P)-I;V:=F.P[I];F.P[I]:=F.P[J];F.P[J]:=V end;
    I:=Length(Faces);SetLength(Faces,I+1);Faces[I]:=F;
  end;
  function Point(X,Z,Y:Single):TVector3;
  begin Result:=A+U*X+V*Z;Result.Y:=Y end;
  procedure AddFinal(const P:TPoly;const Surface:TSurface);
  var N:Integer;
  begin
    if (Length(P)<3) or (Abs(XZPolygonArea(P))<Eps) then Exit;N:=Length(Final);Check(N<MaxPieces,'surface budget exceeded');
    SetLength(Final,N+1);Final[N]:=Surface;Final[N].P:=P;
  end;
  procedure AddT(Value:Double);
  var I,N:Integer;
  begin
    if (Value<=0.000001) or (Value>=0.999999) then Exit;
    for I:=0 to High(T) do if Abs(T[I]-Value)<0.000001 then Exit;
    N:=Length(T);SetLength(T,N+1);T[N]:=Value;
  end;
  procedure SplitAt(const P:TPoly);
  var I:Integer;C,F:TVector2;Den,A0,B0:Double;
  begin
    for I:=0 to High(P) do begin
      C:=P[I];F:=P[(I+1) mod Length(P)]-C;Den:=XZCross(D,F);
      if Abs(Den)>0.000001 then begin A0:=XZCross(C-E0,F)/Den;B0:=XZCross(C-E0,D)/Den;if (B0>=-0.000001) and (B0<=1.000001) then AddT(A0) end
      else if Abs(XZCross(C-E0,D))<0.00001 then begin
        if Abs(D.X)>Abs(D.Y) then begin AddT((C.X-E0.X)/D.X);AddT((C.X+F.X-E0.X)/D.X) end
        else begin AddT((C.Y-E0.Y)/D.Y);AddT((C.Y+F.Y-E0.Y)/D.Y) end;
      end;
    end;
  end;
  function Adjacent(const V:TVector2):TPlane;
  var I:Integer;InDomain:Boolean;Y:Double;
  begin
    Result.X:=0;Result.Z:=0;Result.C:=R.Eave;InDomain:=False;
    for I:=0 to High(Domains) do if Contains(Domains[I],V) then begin InDomain:=True;Break end;
    if not InDomain then Exit;
    for I:=0 to High(Faces) do if Contains(Faces[I].P,V) then begin
      Y:=HeightAt(Faces[I].Plane,V);if Y>HeightAt(Result,V) then Result:=Faces[I].Plane;
    end;
  end;
begin
  Result:=False;if (Domain=nil) or (Target=nil) or (Domain.TriangleCount=0) or
    (Domain.TriangleCount>1024) or (Length(R.Parts)=0) then Exit;
  Faces:=nil;Final:=nil;Domains:=nil;M:=TMesh.Create;
  try
   try
    M.CurrentOsmId:=Target.CurrentOsmId;Origin:=Projection.Project(R.Parts[0].A,0);
    Vertices:=Domain.Vertices;Indices:=Domain.Indices;
    for I:=0 to Domain.TriangleCount-1 do begin
      SetLength(P,3);for J:=0 to 2 do begin A:=Vertices[Indices[I*3+J]].Position-Origin;P[J]:=Vector2(A.X,A.Z) end;
      if XZPolygonArea(P)<0 then begin E0:=P[1];P[1]:=P[2];P[2]:=E0 end;XZAppendPolygon(Domains,P);
    end;
    for PartIndex:=0 to High(R.Parts) do begin
      A:=Projection.Project(R.Parts[PartIndex].A,0)-Origin;B:=Projection.Project(R.Parts[PartIndex].B,0)-Origin;
      U:=B-A;Len:=U.Length;U:=U/Len;V:=TVector3.CrossProduct(U,Vector3(0,1,0));W:=R.Parts[PartIndex].Width*0.5;
      UV:=ArchitectureUV(R.Parts[PartIndex].Color,R.Parts[PartIndex].Roughness,R.Parts[PartIndex].Metallic);
      with R.Parts[PartIndex] do case Shape of
        crFlat:Face([Point(0,-W,Eave),Point(Len,-W,Eave),Point(Len,W,Eave),Point(0,W,Eave)]);
        crSkillion:Face([Point(0,-W,Eave),Point(Len,-W,Eave),Point(Len,W,Ridge),Point(0,W,Ridge)]);
        crGabled:begin
          Face([Point(0,-W,Eave),Point(Len,-W,Eave),Point(Len,0,Ridge),Point(0,0,Ridge)]);
          Face([Point(0,0,Ridge),Point(Len,0,Ridge),Point(Len,W,Eave),Point(0,W,Eave)]);
        end;
        crHipped:begin
          Hip:=Min(W,Len*0.5);
          Face([Point(0,-W,Eave),Point(Len,-W,Eave),Point(Len-Hip,0,Ridge),Point(Hip,0,Ridge)]);
          Face([Point(Hip,0,Ridge),Point(Len-Hip,0,Ridge),Point(Len,W,Eave),Point(0,W,Eave)]);
          Face([Point(0,W,Eave),Point(0,-W,Eave),Point(Hip,0,Ridge)]);
          Face([Point(Len,-W,Eave),Point(Len,W,Eave),Point(Len-Hip,0,Ridge)]);
        end;
      end;
    end;
    for I:=0 to High(Faces) do for J:=0 to High(Domains) do begin
      if not XZOverlapBounds(Faces[I].P,Domains[J]) then Continue;
      P:=IntersectPoly(Faces[I].P,Domains[J]);Work:=nil;XZAppendPolygon(Work,P);
      for K:=0 to High(Faces) do if K<>I then begin
        if Length(Work)=0 then Break;
        if not XZOverlapBounds(P,Faces[K].P) then Continue;
        { Coplanar overlaps are owned by the earlier part, deterministically. }
        if (Abs(Faces[K].Plane.X-Faces[I].Plane.X)<1e-7) and (Abs(Faces[K].Plane.Z-Faces[I].Plane.Z)<1e-7) and
          (Abs(Faces[K].Plane.C-Faces[I].Plane.C)<0.00001) then begin if K>I then Continue;Cut:=Faces[K].P end
        else Cut:=XZClipHalfPlane(Faces[K].P,Faces[K].Plane.X-Faces[I].Plane.X,Faces[K].Plane.Z-Faces[I].Plane.Z,Faces[K].Plane.C-Faces[I].Plane.C);
        Next:=nil;for L:=0 to High(Work) do XZSubtractConvex(Work[L],Cut,Next);Work:=Next;
      end;
      for K:=0 to High(Work) do AddFinal(Work[K],Faces[I]);
    end;
    S.Plane.X:=0;S.Plane.Z:=0;S.Plane.C:=R.Eave;S.UV:=ArchitectureUV(R.Color,0.85,0);
    for I:=0 to High(Domains) do begin
      Work:=nil;XZAppendPolygon(Work,Domains[I]);
      for J:=0 to High(Faces) do begin Next:=nil;for K:=0 to High(Work) do XZSubtractConvex(Work[K],Faces[J].P,Next);Work:=Next;if Length(Work)=0 then Break end;
      for J:=0 to High(Work) do AddFinal(Work[J],S);
    end;
    Check(Length(Final)>0,'empty clipped roof');
    for I:=0 to High(Final) do begin
      S:=Final[I];A:=World(S.P[0],HeightAt(S.Plane,S.P[0]));U:=Vector3(-S.Plane.X,1,-S.Plane.Z).Normalize;
      for J:=1 to High(S.P)-1 do EmitTri(A,World(S.P[J],HeightAt(S.Plane,S.P[J])),World(S.P[J+1],HeightAt(S.Plane,S.P[J+1])),U,S.UV);
      for Edge:=0 to High(S.P) do begin
        E0:=S.P[Edge];E1:=S.P[(Edge+1) mod Length(S.P)];D:=E1-E0;if D.Length<0.00001 then Continue;
        Normal:=Vector2(D.Y,-D.X)/D.Length;SetLength(T,2);T[0]:=0;T[1]:=1;
        for J:=0 to High(Faces) do begin
          SplitAt(Faces[J].P);Own0:=HeightAt(S.Plane,E0)-HeightAt(Faces[J].Plane,E0);Own1:=HeightAt(S.Plane,E1)-HeightAt(Faces[J].Plane,E1);
          if Abs(Own0-Own1)>0.000001 then AddT(Own0/(Own0-Own1));
        end;
        for J:=0 to High(Domains) do SplitAt(Domains[J]);
        for J:=1 to High(T) do begin TM:=T[J];K:=J-1;while (K>=0) and (T[K]>TM) do begin T[K+1]:=T[K];Dec(K) end;T[K+1]:=TM end;
        for J:=0 to High(T)-1 do begin
          A2:=E0+D*T[J];B2:=E0+D*T[J+1];Mid:=(A2+B2)*0.5+Normal*0.002;
          Neighbor:=Adjacent(Mid);Own0:=HeightAt(S.Plane,A2);Own1:=HeightAt(S.Plane,B2);Low0:=HeightAt(Neighbor,A2);Low1:=HeightAt(Neighbor,B2);
          if (Own0+Own1)<=(Low0+Low1)+0.001 then Continue;
          Low0:=Min(Own0,Max(R.Eave,Low0));Low1:=Min(Own1,Max(R.Eave,Low1));U:=Vector3(Normal.X,0,Normal.Y);
          UV:=ArchitectureUV(R.WallColor,0.87,0);
          EmitTri(World(A2,Low0),World(B2,Low1),World(B2,Own1),U,UV);
          EmitTri(World(A2,Low0),World(B2,Own1),World(A2,Own0),U,UV);
        end;
      end;
    end;
    Target.AppendMesh(M);Result:=True;
   except on E:EConvertError do Result:=False end;
  finally M.Free end;
end;
end.
