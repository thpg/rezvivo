unit Osm3dBridgeDetails;
{$mode objfpc}{$H+}
interface
uses SysUtils, fpjson, CastleVectors, Osm3dGeoMath, Osm3dGeomMesh;
const BRIDGE_DETAILS_TAG='rezvivo:bridge_details';
type
  TBridgeRail=(brNone,brConcrete,brMetal);
  TBridgeDetails=record
    Suspension:Boolean;
    Side:Integer; { -1 / +1 in OffsetPolyline coordinates; 0 means both }
    TowerHeight,MainSpan,SideOffset:Single;
    NegativeRail,PositiveRail:TBridgeRail;
    DeckGroup:string;
    DeckOffset:Single;
  end;
function CanonicalBridgeDetails(Value:TJSONData):string;
function ReadBridgeDetails(const Text:string):TBridgeDetails;
procedure ValidateBridgeDetailsSource(Source:TJSONObject);
procedure EmitBridgeDetails(const D:TBridgeDetails;const Center:TXZArray;
  const Heights:array of Single; Width:Single;Mesh:TMesh);
implementation
uses Math, Osm3dPhotoSources, Osm3dTileKnowledge;
procedure Need(B:Boolean;const S:string);
begin if not B then raise ETileKnowledge.Create('road.bridge_details: '+S) end;
function Number(O:TJSONObject;const K:string;Lo,Hi,Def:Double):Double;
var V:TJSONData;
begin
  V:=O.Find(K);if V=nil then Exit(Def);
  Need(V.JSONType=jtNumber,K+' must be numeric');Result:=V.AsFloat;
  Need(not IsNan(Result) and not IsInfinite(Result) and (Result>=Lo) and (Result<=Hi),K+' out of range');
end;
function Rail(O:TJSONObject;const K:string):TBridgeRail;
var S:string;
begin
  S:=O.Get(K,'concrete');
  if S='none' then Exit(brNone);if S='metal' then Exit(brMetal);
  Need(S='concrete','invalid '+K);Result:=brConcrete;
end;
function Decode(J:TJSONData):TBridgeDetails;
var O:TJSONObject;I:Integer;S:string;
begin
  Result:=Default(TBridgeDetails);Result.NegativeRail:=brConcrete;Result.PositiveRail:=brConcrete;
  Need(J is TJSONObject,'object required');O:=TJSONObject(J);
  for I:=0 to O.Count-1 do Need(Pos('|'+O.Names[I]+'|','|version|structure|side|tower_height_m|main_span_m|side_offset_m|negative_rail|positive_rail|deck_group|deck_offset_m|')>0,'unknown field '+O.Names[I]);
  Need(Number(O,'version',1,1,0)=1,'version 1 required');
  S:=O.Get('structure','none');Need((S='none') or (S='suspension'),'unsupported structure');Result.Suspension:=S='suspension';
  Result.Side:=Round(Number(O,'side',-1,1,0));Need(Result.Side=Number(O,'side',-1,1,0),'side must be -1, 0 or 1');
  Result.TowerHeight:=Number(O,'tower_height_m',5,100,23);
  Result.MainSpan:=Number(O,'main_span_m',15,1500,168);
  Result.SideOffset:=Number(O,'side_offset_m',0,10,0);
  Result.NegativeRail:=Rail(O,'negative_rail');Result.PositiveRail:=Rail(O,'positive_rail');
  Result.DeckGroup:=O.Get('deck_group','');Need(Length(Result.DeckGroup)<=80,'deck_group too long');
  Result.DeckOffset:=Number(O,'deck_offset_m',0,0.3,0);
  Need((Result.DeckOffset=0) or (Result.DeckGroup<>''),'deck offset requires a shared group');
end;
function ReadBridgeDetails(const Text:string):TBridgeDetails;
var J:TJSONData;
begin
  if Text='' then begin Result:=Default(TBridgeDetails);Result.NegativeRail:=brConcrete;Result.PositiveRail:=brConcrete;Exit end;
  J:=ParsePhotoJson(Text);try Result:=Decode(J) finally J.Free end;
end;
function CanonicalBridgeDetails(Value:TJSONData):string;
const Names:array[TBridgeRail]of string=('none','concrete','metal');
var D:TBridgeDetails;O:TJSONObject;S:string;
begin
  D:=Decode(Value);S:='none';if D.Suspension then S:='suspension';
  O:=TJSONObject.Create(['version',1,'structure',S,'side',D.Side,'tower_height_m',D.TowerHeight,
    'main_span_m',D.MainSpan,'side_offset_m',D.SideOffset,'negative_rail',Names[D.NegativeRail],'positive_rail',Names[D.PositiveRail]]);
  { Preserve canonical old recipes that predate optional shared decks. }
  if D.DeckGroup<>'' then begin O.Add('deck_group',D.DeckGroup);O.Add('deck_offset_m',D.DeckOffset) end;
  try Result:=O.AsJSON finally O.Free end;
end;

procedure ValidateBridgeDetailsSource(Source:TJSONObject);
var Tags:TJSONObject;S:string;
begin
  Need((Source<>nil) and (Source.Get('type','')='way'),'requires a bridge road way');
  Need(Source.Find('tags') is TJSONObject,'source tags required');Tags:=TJSONObject(Source.Find('tags'));
  S:=LowerCase(Tags.Get('bridge',''));
  Need((S<>'') and (S<>'no') and (S<>'false') and (S<>'0'),'source is not a bridge');
end;

{ Closed, flat-shaded rectangular members. One shared baked mesh; no scene
  nodes, per-frame work, textures or new draw calls per cable/hanger. }
procedure Member(M:TMesh;const A,B:TVector3;W,D:Single);
var U,V,N:TVector3;P:array[0..7]of TVector3;I,K,Q:Integer;
const Faces:array[0..5,0..3]of Integer=((0,1,5,4),(1,2,6,5),(2,3,7,6),(3,0,4,7),(3,2,1,0),(4,5,6,7));
begin
  U:=B-A;if U.Length<0.0001 then Exit;U:=U.Normalize;
  if Abs(U.Y)<0.95 then V:=TVector3.CrossProduct(U,Vector3(0,1,0)).Normalize
  else V:=TVector3.CrossProduct(U,Vector3(1,0,0)).Normalize;
  N:=TVector3.CrossProduct(U,V).Normalize;V:=V*(W*0.5);N:=N*(D*0.5);
  P[0]:=A-V-N;P[1]:=A+V-N;P[2]:=A+V+N;P[3]:=A-V+N;
  for I:=0 to 3 do P[I+4]:=P[I]+(B-A);
  for I:=0 to 5 do begin
    N:=TVector3.CrossProduct(P[Faces[I,1]]-P[Faces[I,0]],P[Faces[I,2]]-P[Faces[I,0]]).Normalize;
    Q:=M.VertexCount;
    { Painted steel: sample the neutral concrete palette interior, not its
      dirty lower edge. Members carry real geometry, not a fence silhouette. }
    for K:=0 to 3 do M.AddVertex(P[Faces[I,K]],N,MakeUV(0.5,0.65));
    M.AddQuad(Q,Q+1,Q+2,Q+3);
  end;
end;
procedure EmitBridgeDetails(const D:TBridgeDetails;const Center:TXZArray;
  const Heights:array of Single;Width:Single;Mesh:TMesh);
var Along:array of Double;I,S,N:Integer;Total,A,B,Run,Span,AtM,Offset:Double;P,Q:TVector3;
  function At(Arc,Lateral,Height:Double):TVector3;
  var K:Integer;F,DX,DZ,L:Double;
  begin
    K:=0;while (K<High(Center)-1) and (Along[K+1]<Arc) do Inc(K);
    L:=Along[K+1]-Along[K];F:=0;if L>1e-6 then F:=EnsureRange((Arc-Along[K])/L,0.0,1.0);
    DX:=Center[K+1].X-Center[K].X;DZ:=Center[K+1].Z-Center[K].Z;
    Result:=Vector3(Center[K].X+DX*F,Heights[K]+(Heights[K+1]-Heights[K])*F+Height,Center[K].Z+DZ*F);
    if L>1e-6 then begin Result.X+=DZ/L*Lateral;Result.Z-=DX/L*Lateral end;
  end;
  function CableHeight(X:Double):Double;
  var F:Double;
  begin
    if X<A then Exit(1.3+(D.TowerHeight-1.3)*X/Max(A,1));
    if X>B then Exit(1.3+(D.TowerHeight-1.3)*(Total-X)/Max(Total-B,1));
    F:=2*(X-A)/Span-1;Result:=3.2+(D.TowerHeight-3.2)*F*F;
  end;
begin
  if (Mesh=nil) or (Length(Center)<2) or (Length(Heights)<Length(Center)) then Exit;
  SetLength(Along,Length(Center));Along[0]:=0;
  for I:=1 to High(Center) do Along[I]:=Along[I-1]+Hypot(Center[I].X-Center[I-1].X,Center[I].Z-Center[I-1].Z);
  Total:=Along[High(Along)];if Total<1 then Exit;
  for S:=-1 to 1 do begin
    if S=0 then Continue;
    { Railing silhouettes are emitted by the bridge builder into the shared
      metal-fence material. Do not duplicate every picket as geometry. }
    if not D.Suspension or ((D.Side<>0) and (D.Side<>S)) then Continue;
    Offset:=S*(Width*0.5+D.SideOffset);Span:=Min(D.MainSpan,Total*0.85);A:=(Total-Span)*0.5;B:=A+Span;
    for I:=0 to 1 do begin
      AtM:=A;if I=1 then AtM:=B;
      Member(Mesh,At(AtM,Offset,-0.45),At(AtM,Offset,D.TowerHeight+0.7),1.05,1.55);
      Member(Mesh,At(AtM,Offset,-0.5),At(AtM,Offset,1),1.50,2.05);
    end;
    { Fixed metre spacing preserves the silhouette without excessive facets. }
    N:=Max(3,Ceil(Total/3.5));
    for I:=0 to N-1 do begin
      Run:=Total*I/N;AtM:=Total*(I+1)/N;
      P:=At(Run,Offset,CableHeight(Run));Q:=At(AtM,Offset,CableHeight(AtM));Member(Mesh,P,Q,0.32,0.42);
    end;
    N:=Max(2,Round(Span/5.25));
    for I:=1 to N-1 do begin
      AtM:=A+Span*I/N;Member(Mesh,At(AtM,Offset,-0.1),At(AtM,Offset,CableHeight(AtM)),0.09,0.11);
    end;
    Member(Mesh,At(A,Offset,-0.4),At(B,Offset,-0.4),0.50,0.80);
  end;
end;
end.
