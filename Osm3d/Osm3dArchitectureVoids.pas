unit Osm3dArchitectureVoids;
{$mode objfpc}{$H+}{$modeswitch advancedrecords}
{ Bounded straight passages/recesses, baked once by the building worker.
  Subtract convex prisms from this building's mesh tail, preserving every
  vertex attribute. The colour pass, picking and both shadow paths then see
  the same openings. No fragment discard or extra scene/material is needed. }
interface
uses SysUtils,Math,fpjson,CastleVectors,Osm3dGeoMath,Osm3dGeomMesh;
type
  TArchitecturePassage=record
    Start,Finish:TLatLon;
    A,B:TVector3;
    Width,Height,Bottom,Rise,Roughness:Single;
    WallColor,FloorColor:Cardinal;
    Through:Boolean;
  end;
  TArchitecturePassages=array of TArchitecturePassage;
  TArchitectureVoidRing=array of TVector3;
  TArchitectureVoidRings=array of TArchitectureVoidRing;
function ParseArchitecturePassages(J:TJSONData):TArchitecturePassages;
function CanonicalArchitecturePassages(J:TJSONData):TJSONArray;
procedure ProjectArchitecturePassages(var Passages:TArchitecturePassages;
  Projection:TLocalProjection;const Footprint:array of TVector3;
  const InnerRings:TArchitectureVoidRings=nil);
function CarveArchitecturePassages(const Passages:TArchitecturePassages;
  Base,Top,FoundationBottom:Single;Mesh:TMesh;FirstVertex,FirstTriangle:Integer):Boolean;
function PassageGroundCorner(const P:TArchitecturePassage;Index:Integer):TVector3;
implementation
type
  TVertexPolygon=array of TMeshVertex;
  TSection=array of TVector2;
  TPlane=record N:TVector3;D:Single end;
  TPlanes=array of TPlane;
procedure Check(B:Boolean;const Message:string);
begin if not B then raise EConvertError.Create('building.architecture.passages: '+Message) end;
function Number(O:TJSONObject;const Name:string;Default,Lo,Hi:Double):Double;
var V:TJSONData;
begin
  V:=O.Find(Name);Result:=Default;if V=nil then Exit;
  Check(V.JSONType=jtNumber,Name+' must be numeric');Result:=V.AsFloat;
  Check(not IsNan(Result) and not IsInfinite(Result) and
    (Result>=Lo-1e-6*Max(1,Abs(Lo))) and (Result<=Hi+1e-6*Max(1,Abs(Hi))),Name+' out of range');
  Result:=EnsureRange(Result,Lo,Hi);
end;
function Text(O:TJSONObject;const Name,Default:string):string;
var V:TJSONData;
begin V:=O.Find(Name);if V=nil then Exit(Default);Check(V.JSONType=jtString,Name+' must be a string');Result:=V.AsString end;
function Colour(O:TJSONObject;const Name,Default:string):Cardinal;
var S:string;I:Integer;
begin
  S:=Text(O,Name,Default);Check((Length(S)=7) and (S[1]='#'),Name+' must be #RRGGBB');
  for I:=2 to 7 do Check(S[I] in ['0'..'9','a'..'f','A'..'F'],Name+' must be #RRGGBB');
  Result:=StrToInt('$'+Copy(S,2,6));
end;
function Coordinate(V:TJSONData):TLatLon;
var X,Y:Double;
begin
  Check((V<>nil) and (V.JSONType=jtArray) and (V.Count=2),'start/end must be [longitude, latitude]');
  Check((V.Items[0].JSONType=jtNumber) and (V.Items[1].JSONType=jtNumber),'numeric coordinates required');
  X:=V.Items[0].AsFloat;Y:=V.Items[1].AsFloat;
  Check(not IsNan(X) and not IsNan(Y) and (Abs(X)<=180) and (Abs(Y)<=85),'invalid coordinate');
  Result:=TLatLon.Make(Y,X);
end;
function PassageOverlap(const A,B:TArchitecturePassage):Boolean;
var UA,UB,Axis,PA,PB,RA,RB:TVector3;I:Integer;LA,LB,HalfA,HalfB:Single;
begin
  Result:=False;if (A.Bottom>=B.Bottom+B.Height) or (B.Bottom>=A.Bottom+A.Height) then Exit;
  LA:=(A.B-A.A).Length;LB:=(B.B-B.A).Length;
  UA:=(A.B-A.A)/LA;UB:=(B.B-B.A)/LB;
  RA:=TVector3.CrossProduct(UA,Vector3(0,1,0));RB:=TVector3.CrossProduct(UB,Vector3(0,1,0));
  PA:=(A.A+A.B)*0.5;PB:=(B.A+B.B)*0.5;
  for I:=0 to 3 do begin
    case I of 0:Axis:=UA;1:Axis:=UB;2:Axis:=RA;else Axis:=RB end;
    HalfA:=Abs(VecDot(UA,Axis))*LA*0.5+Abs(VecDot(RA,Axis))*A.Width*0.5;
    HalfB:=Abs(VecDot(UB,Axis))*LB*0.5+Abs(VecDot(RB,Axis))*B.Width*0.5;
    if Abs(VecDot(PA-PB,Axis))>=HalfA+HalfB-0.001 then Exit;
  end;
  Result:=True;
end;
function ParseArchitecturePassages(J:TJSONData):TArchitecturePassages;
var I,K:Integer;O:TJSONObject;S:string;Projection:TLocalProjection;L:Single;
begin
  Result:=nil;if J=nil then Exit;
  Check((J.JSONType=jtArray) and (J.Count<=8),'at most eight passages per building');
  SetLength(Result,J.Count);
  for I:=0 to J.Count-1 do with Result[I] do begin
    Check(J.Items[I].JSONType=jtObject,'passage must be an object');O:=TJSONObject(J.Items[I]);
    for K:=0 to O.Count-1 do Check(Pos('|'+O.Names[K]+'|',
      '|kind|start|end|width_m|height_m|bottom_m|shape|arch_rise_m|wall_color|floor_color|roughness|')>0,'unknown field '+O.Names[K]);
    S:=Text(O,'kind','through');Check((S='through') or (S='recess'),'invalid kind');Through:=S='through';
    Start:=Coordinate(O.Find('start'));Finish:=Coordinate(O.Find('end'));
    Projection:=TLocalProjection.Create(Result[0].Start,Result[0].Start.Lat);
    try A:=Projection.Project(Start,0);B:=Projection.Project(Finish,0) finally Projection.Free end;
    L:=(B-A).Length;Check((L>=0.2) and (L<=80),'length must be 0.2..80 m');
    Width:=Number(O,'width_m',3,0.5,12);Height:=Number(O,'height_m',3.5,0.5,15);
    Bottom:=Number(O,'bottom_m',0,0,100);Roughness:=Number(O,'roughness',0.9,0.15,1);
    S:=Text(O,'shape','rectangle');Check((S='rectangle') or (S='round_arch'),'invalid shape');
    if S='round_arch' then Rise:=Number(O,'arch_rise_m',Min(Width*0.5,Height*0.5),0.1,Min(Height-0.1,Width))
    else Check(O.Find('arch_rise_m')=nil,'arch_rise_m requires round_arch');
    WallColor:=Colour(O,'wall_color','#bdb7a7');FloorColor:=Colour(O,'floor_color','#77766e');
    for K:=0 to I-1 do Check(not PassageOverlap(Result[I],Result[K]),'passage volumes overlap');
  end;
end;
function CanonicalArchitecturePassages(J:TJSONData):TJSONArray;
var P:TArchitecturePassages;I:Integer;O:TJSONObject;S:string;
begin
  P:=ParseArchitecturePassages(J);Result:=TJSONArray.Create;
  try
    for I:=0 to High(P) do with P[I] do begin
      S:='recess';if Through then S:='through';
      O:=TJSONObject.Create(['kind',S,'start',TJSONArray.Create([Start.Lon,Start.Lat]),
        'end',TJSONArray.Create([Finish.Lon,Finish.Lat]),'width_m',Double(Width),'height_m',Double(Height),
        'bottom_m',Double(Bottom),'roughness',Double(Roughness),
        'wall_color','#'+LowerCase(IntToHex(WallColor,6)),'floor_color','#'+LowerCase(IntToHex(FloorColor,6))]);
      if Rise>0 then begin O.Add('shape','round_arch');O.Add('arch_rise_m',Double(Rise)) end;
      Result.Add(O);
    end;
  except Result.Free;raise end;
end;
function Inside(const P:TVector3;const Ring:array of TVector3):Boolean;
var I,J:Integer;
begin
  Result:=False;J:=High(Ring);
  for I:=0 to High(Ring) do begin
    if ((Ring[I].Z>P.Z)<>(Ring[J].Z>P.Z)) and
      (P.X<(Ring[J].X-Ring[I].X)*(P.Z-Ring[I].Z)/(Ring[J].Z-Ring[I].Z)+Ring[I].X) then Result:=not Result;
    J:=I;
  end;
end;
function PassageGroundCorner(const P:TArchitecturePassage;Index:Integer):TVector3;
var U,R:TVector3;ExitMargin:Single;
begin
  U:=(P.B-P.A).Normalize;R:=TVector3.CrossProduct(U,Vector3(0,1,0));
  ExitMargin:=0;if P.Through then ExitMargin:=0.8;
  case Index of
    0:Result:=P.A-U*0.8-R*(P.Width*0.5);
    1:Result:=P.B+U*ExitMargin-R*(P.Width*0.5);
    2:Result:=P.B+U*ExitMargin+R*(P.Width*0.5);
  else Result:=P.A-U*0.8+R*(P.Width*0.5) end;
end;
procedure ProjectArchitecturePassages(var Passages:TArchitecturePassages;
  Projection:TLocalProjection;const Footprint:array of TVector3;
  const InnerRings:TArchitectureVoidRings);
var I,J,K,Side:Integer;U,R,Q:TVector3;Valid:Boolean;L,T0,T1,TSide:Single;
  function Solid(const Point:TVector3):Boolean;
  var H:Integer;
  begin
    Result:=Inside(Point,Footprint);
    if Result then for H:=0 to High(InnerRings) do if Inside(Point,InnerRings[H]) then Exit(False);
  end;
  function Boundary(const From:TVector3;Near:Single;out Along:Single):Boolean;
  var H:Integer;Best:Single;
    procedure Visit(const Ring:array of TVector3);
    var E,Next:Integer;D,V:TVector3;Den,T,S:Single;
    begin
    for E:=0 to High(Ring) do begin
      Next:=(E+1) mod Length(Ring);D:=Ring[Next]-Ring[E];V:=Ring[E]-From;
      Den:=U.X*D.Z-U.Z*D.X;if Abs(Den)<1e-8 then Continue;
      T:=(V.X*D.Z-V.Z*D.X)/Den;S:=(V.X*U.Z-V.Z*U.X)/Den;
      if (S>=-0.0001) and (S<=1.0001) and (Abs(T-Near)<Best) then begin
        Along:=T;Best:=Abs(T-Near);Result:=True;
      end;
    end;
    end;
  begin
    Result:=False;Best:=0.65;Visit(Footprint);
    for H:=0 to High(InnerRings) do Visit(InnerRings[H]);
  end;
  function CrossesInteriorBoundary(const Origin:TVector3;Width,LengthM:Single):Boolean;
  var Ring:TArchitectureVoidRing;H,E,Next:Integer;A0,B0,D:TVector2;TA,TB:Single;
    function Clip(P,Q:Single):Boolean;
    var T:Single;
    begin
      if Abs(P)<1e-8 then Exit(Q>=0);T:=Q/P;
      if P<0 then begin if T>TB then Exit(False);TA:=Max(TA,T) end
      else begin if T<TA then Exit(False);TB:=Min(TB,T) end;
      Result:=True;
    end;
  begin
    Result:=False;
    { Any outer notch or courtyard edge intersecting the open rectangle
      invalidates it, including holes too small to hit a sampling grid. }
    for H:=-1 to High(InnerRings) do begin
      if H<0 then begin SetLength(Ring,Length(Footprint));for E:=0 to High(Footprint) do Ring[E]:=Footprint[E] end
      else Ring:=InnerRings[H];
      for E:=0 to High(Ring) do begin
        Next:=(E+1) mod Length(Ring);
        A0:=Vector2(VecDot(Ring[E]-Origin,R),VecDot(Ring[E]-Origin,U));
        B0:=Vector2(VecDot(Ring[Next]-Origin,R),VecDot(Ring[Next]-Origin,U));D:=B0-A0;TA:=0;TB:=1;
          if Clip(-D.X,A0.X+Width*0.5-0.001) and Clip(D.X,Width*0.5-0.001-A0.X) and
          Clip(-D.Y,A0.Y-0.08) and Clip(D.Y,LengthM-0.08-A0.Y) then Exit(True);
      end;
    end;
  end;
begin
  K:=0;
  for I:=0 to High(Passages) do begin
    Passages[I].A:=Projection.Project(Passages[I].Start,0);Passages[I].B:=Projection.Project(Passages[I].Finish,0);
    U:=(Passages[I].B-Passages[I].A).Normalize;R:=TVector3.CrossProduct(U,Vector3(0,1,0));
    L:=(Passages[I].B-Passages[I].A).Length;
    Valid:=Boundary(Passages[I].A,0,T0);
    T1:=L;if Passages[I].Through then Valid:=Valid and Boundary(Passages[I].A,L,T1);
    if not Valid then Continue;
    { Snap measured endpoints onto their OSM walls; accept straight portals
      only when both jambs reach the same wall plane. }
    for Side:=-1 to 1 do if Side<>0 then begin
      Valid:=Valid and Boundary(Passages[I].A+R*(Side*Passages[I].Width*0.5),T0,TSide);
      Valid:=Valid and (Abs(TSide-T0)<0.08);
      if Passages[I].Through then begin
        Valid:=Valid and Boundary(Passages[I].A+R*(Side*Passages[I].Width*0.5),T1,TSide);
        Valid:=Valid and (Abs(TSide-T1)<0.08);
      end;
    end;
    if not Valid then Continue;
    Passages[I].B:=Passages[I].A+U*T1;Passages[I].A:=Passages[I].A+U*T0;L:=T1-T0;
    { Require a real entrance and a continuous solid envelope. A guessed
      remote or courtyard-crossing corridor must not carve unrelated faces. }
    Valid:=(L>=0.2) and (Length(Footprint)>=3) and not Solid(Passages[I].A-U*0.5);
    if Passages[I].Through then Valid:=Valid and not Solid(Passages[I].B+U*0.5)
    else Valid:=Valid and Solid(Passages[I].B);
    Valid:=Valid and not CrossesInteriorBoundary(Passages[I].A,Passages[I].Width,L);
    for J:=1 to 19 do for Side:=-1 to 1 do begin
      Q:=Passages[I].A+U*(L*J/20)+R*(Side*Passages[I].Width*0.48);
      Valid:=Valid and Solid(Q);
    end;
    if Valid then begin Passages[K]:=Passages[I];Inc(K) end;
  end;
  SetLength(Passages,K);
end;
function Section(const P:TArchitecturePassage;Bottom:Single):TSection;
var I,N:Integer;A:Double;
begin
  if P.Rise=0 then begin
    SetLength(Result,4);Result[0]:=Vector2(-P.Width*0.5,Bottom);Result[1]:=Vector2(P.Width*0.5,Bottom);
    Result[2]:=Vector2(P.Width*0.5,P.Bottom+P.Height);Result[3]:=Vector2(-P.Width*0.5,P.Bottom+P.Height);
  end else begin
    N:=Min(24,Max(8,Ceil(P.Width*3)));SetLength(Result,N+3);
    Result[0]:=Vector2(-P.Width*0.5,Bottom);Result[1]:=Vector2(P.Width*0.5,Bottom);
    for I:=0 to N do begin A:=Pi*I/N;Result[I+2]:=Vector2(Cos(A)*P.Width*0.5,P.Bottom+P.Height-P.Rise+Sin(A)*P.Rise) end;
  end;
end;
function Interpolate(const A,B:TMeshVertex;T:Single):TMeshVertex;
begin
  Result:=A;Result.Position:=A.Position+(B.Position-A.Position)*T;
  Result.Normal:=VecNormalize(A.Normal+(B.Normal-A.Normal)*T);Result.UV:=A.UV+(B.UV-A.UV)*T;
end;
procedure Split(const Poly:TVertexPolygon;const Plane:TPlane;out InPart,OutPart:TVertexPolygon);
var I,J,NI,NO:Integer;A,B:TMeshVertex;DA,DB:Single;IA,IB:Boolean;V:TMeshVertex;
begin
  SetLength(InPart,Length(Poly)+1);SetLength(OutPart,Length(Poly)+1);NI:=0;NO:=0;
  for I:=0 to High(Poly) do begin
    J:=(I+1) mod Length(Poly);A:=Poly[I];B:=Poly[J];
    DA:=TVector3.DotProduct(Plane.N,A.Position)+Plane.D;DB:=TVector3.DotProduct(Plane.N,B.Position)+Plane.D;
    IA:=DA>=0;IB:=DB>=0;
    if IA then begin InPart[NI]:=A;Inc(NI) end else begin OutPart[NO]:=A;Inc(NO) end;
    if IA<>IB then begin V:=Interpolate(A,B,DA/(DA-DB));InPart[NI]:=V;Inc(NI);OutPart[NO]:=V;Inc(NO) end;
  end;
  SetLength(InPart,NI);SetLength(OutPart,NO);
end;
procedure EmitPolygon(Mesh:TMesh;const P:TVertexPolygon);
var I,A,B,C:Integer;
begin
  if Length(P)<3 then Exit;
  for I:=1 to High(P)-1 do begin
    if VecCross(P[I].Position-P[0].Position,P[I+1].Position-P[0].Position).LengthSqr<1e-12 then Continue;
    A:=Mesh.AddVertex(P[0]);B:=Mesh.AddVertex(P[I]);C:=Mesh.AddVertex(P[I+1]);Mesh.AddTriangle(A,B,C);
  end;
end;
function CarveArchitecturePassages(const Passages:TArchitecturePassages;
  Base,Top,FoundationBottom:Single;Mesh:TMesh;FirstVertex,FirstTriangle:Integer):Boolean;
var I,J,K,Q,L,Count,TriangleLimit,VertexLimit:Integer;P:TArchitecturePassage;U,R,Origin,NA,NB:TVector3;
  CrossSection:TSection;Planes:TPlanes;Distance,MinD,MaxD:Single;
  Source,Dest,Kept:TMesh;Vertices:TMeshVertexArray;Indices:TMeshIndexArray;Remap:array of Integer;
  Poly,InPart,OutPart:TVertexPolygon;Unchanged:Boolean;UV:TVector2;
  function World(const V:TVector2;Z:Single):TVector3;
  begin Result:=Origin+R*V.X+Vector3(0,V.Y,0)+U*Z end;
  procedure Face(const A,B,C,D,Normal:TVector3;Color:Cardinal);
  var A0,B0,C0,D0:Integer;
  begin
    UV:=Vector2(Color,-1000000-Round(P.Roughness*255));
    A0:=Source.AddVertex(A,Normal,UV);B0:=Source.AddVertex(B,Normal,UV);
    C0:=Source.AddVertex(C,Normal,UV);D0:=Source.AddVertex(D,Normal,UV);
    if VecDot(VecCross(B-A,C-A),Normal)>=0 then Source.AddQuad(A0,B0,C0,D0)
    else Source.AddQuad(A0,D0,C0,B0);
  end;
begin
  Result:=False;
  if (Mesh=nil) or (Length(Passages)=0) then Exit;
  if (Mesh.TriangleCount-FirstTriangle>65536) or (Mesh.VertexCount-FirstVertex>262144) then Exit;
  TriangleLimit:=Min(131072,Mesh.TriangleCount-FirstTriangle+32768);
  VertexLimit:=Min(524288,Mesh.VertexCount-FirstVertex+131072);
  Source:=TMesh.Create;Dest:=nil;Kept:=nil;
  try
    Source.CurrentOsmId:=Mesh.CurrentOsmId;Vertices:=Mesh.Vertices;Indices:=Mesh.Indices;
    for I:=FirstVertex to High(Vertices) do Source.AddVertex(Vertices[I]);
    for I:=FirstTriangle*3 to High(Indices) do begin
      Check(Indices[I]>=Cardinal(FirstVertex),'building mesh tail references another building');
      if (I mod 3)=0 then Source.AddTriangle(Indices[I]-FirstVertex,Indices[I+1]-FirstVertex,Indices[I+2]-FirstVertex);
    end;
    for Q:=0 to High(Passages) do begin
      P:=Passages[Q];if Base+P.Bottom+P.Height>Top-0.02 then Continue;
      Origin:=P.A;Origin.Y:=Base;U:=(P.B-P.A).Normalize;R:=TVector3.CrossProduct(U,Vector3(0,1,0));
      Distance:=(P.B-P.A).Length;
      MinD:=P.Bottom;if P.Bottom<0.01 then MinD:=Min(FoundationBottom-Base-0.05,0);
      CrossSection:=Section(P,MinD);Count:=Length(CrossSection);SetLength(Planes,Count+2);
      for I:=0 to Count-1 do begin
        J:=(I+1) mod Count;NA:=Vector3(-(CrossSection[J].Y-CrossSection[I].Y),CrossSection[J].X-CrossSection[I].X,0).Normalize;
        Planes[I].N:=R*NA.X+Vector3(0,NA.Y,0);
        Planes[I].D:=-TVector3.DotProduct(Planes[I].N,World(CrossSection[I],0));
      end;
      { Cut projecting plinth/cornice geometry as well as the wall plane. }
      Planes[Count].N:=U;Planes[Count].D:=-VecDot(U,Origin-U*0.8);
      MaxD:=0.04;if P.Through then MaxD:=0.8;
      Planes[Count+1].N:=-U;Planes[Count+1].D:=VecDot(U,P.B+U*MaxD);
      Dest:=TMesh.Create;Dest.CurrentOsmId:=Source.CurrentOsmId;
      Vertices:=Source.Vertices;Indices:=Source.Indices;
      { Share untouched vertices: carving must not triple the rest of a facade. }
      for I:=0 to High(Vertices) do Dest.AddVertex(Vertices[I]);
      for I:=0 to Source.TriangleCount-1 do begin
        if (Dest.TriangleCount>TriangleLimit) or (Dest.VertexCount>VertexLimit) then Exit;
        Unchanged:=False;
        for J:=0 to High(Planes) do begin
          MaxD:=-1e30;for K:=0 to 2 do MaxD:=Max(MaxD,VecDot(Planes[J].N,Vertices[Indices[I*3+K]].Position)+Planes[J].D);
          if MaxD<=0 then begin Unchanged:=True;Break end;
        end;
        if Unchanged then begin Dest.AddTriangle(Indices[I*3],Indices[I*3+1],Indices[I*3+2]);Continue end;
        SetLength(Poly,3);for K:=0 to 2 do Poly[K]:=Vertices[Indices[I*3+K]];
        for J:=0 to High(Planes) do begin
          Split(Poly,Planes[J],InPart,OutPart);EmitPolygon(Dest,OutPart);Poly:=InPart;if Length(Poly)<3 then Break;
        end;
      end;
      Source.Free;Source:=Dest;Dest:=nil;
      { Ground-level openings retain the real terrain/road surface. Base is
        the highest terrain point of the whole building: using it as a floor
        would leave a floating platform across a downhill passage. Extend
        jambs below local ground and let that existing surface own the floor.
        Raised openings still need their own sill/floor and closed recesses
        additionally own their back plate. }
      CrossSection:=Section(P,MinD);
      for I:=0 to High(CrossSection) do begin
        if (I=0) and (P.Bottom<0.01) then Continue;
        J:=(I+1) mod Length(CrossSection);
        NA:=Vector3(-(CrossSection[J].Y-CrossSection[I].Y),CrossSection[J].X-CrossSection[I].X,0).Normalize;
        NB:=R*NA.X+Vector3(0,NA.Y,0);L:=P.WallColor;if I=0 then L:=P.FloorColor;
        Face(World(CrossSection[I],0),World(CrossSection[J],0),World(CrossSection[J],Distance),World(CrossSection[I],Distance),NB,Cardinal(L));
      end;
      if not P.Through then begin
        UV:=Vector2(P.WallColor,-1000000-Round(P.Roughness*255));SetLength(Poly,Length(CrossSection));
        for I:=0 to High(CrossSection) do begin
          Poly[I]:=MakeVertex2(World(CrossSection[I],Distance),-U);Poly[I].UV:=UV;Poly[I].OsmId:=Source.CurrentOsmId;
        end;
        EmitPolygon(Source,Poly);
      end;
    end;
    { Compact unreferenced vertices left by removed original triangles. }
    Vertices:=Source.Vertices;Indices:=Source.Indices;Kept:=TMesh.Create;
    Kept.CurrentOsmId:=Source.CurrentOsmId;
    SetLength(Remap,Length(Vertices));for I:=0 to High(Remap) do Remap[I]:=-1;
    for I:=0 to High(Indices) do begin
      J:=Indices[I];if Remap[J]<0 then Remap[J]:=Kept.AddVertex(Vertices[J]);
      if (I mod 3)=2 then Kept.AddTriangle(Remap[Indices[I-2]],Remap[Indices[I-1]],Remap[J]);
    end;
    if (Kept.TriangleCount>TriangleLimit) or (Kept.VertexCount>VertexLimit) then Exit;
    Mesh.TruncateGeometry(FirstVertex,FirstTriangle);Mesh.AppendMesh(Kept);Result:=True;
  finally Kept.Free;Dest.Free;Source.Free end;
end;
end.
