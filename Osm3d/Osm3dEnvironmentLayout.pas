unit Osm3dEnvironmentLayout;
{$mode objfpc}{$H+}
{ Bounded photo features become ordinary OSM input, not a second renderer.
  No elevation is authored: native road/terrain grounding remains authoritative. }
interface
uses Classes, SysUtils, fpjson, Generics.Collections, Osm3dGeoMath, Osm3dOsmData;
const ENVIRONMENT_LAYOUT_TAG='rezvivo:environment_layout';
  ENVIRONMENT_LAYOUT_GENERATOR=1;
type
  TEnvironmentNodes=specialize TObjectList<TOSMNode>;
  TEnvironmentWays=specialize TObjectList<TOSMWay>;
function CanonicalEnvironmentLayout(Value:TJSONData;const Category:string):string;
function EnvironmentLayoutBox(const Text:string):TLatLonBox;
procedure StageEnvironmentLayout(const Text,Owner:string;Dataset:TOSMDataset;
  Nodes:TEnvironmentNodes;Ways:TEnvironmentWays);
function EnvironmentLayoutCapabilities:TJSONObject;
implementation
uses Math, MD5, Osm3dTileKnowledge, Osm3dPhotoSources, Osm3dVegetationLayout,Osm3dArchitecture;

procedure Need(B:Boolean;const S:string);
begin if not B then raise ETileKnowledge.Create('environment.layout: '+S) end;
procedure Keys(O:TJSONObject;const Allowed:string);
var I:Integer;
begin for I:=0 to O.Count-1 do Need(Pos('|'+O.Names[I]+'|',Allowed)>0,'unknown field '+O.Names[I]) end;
function Has(const S,Values:string):Boolean;
begin Result:=(S<>'') and (Pos('|'+S+'|',Values)>0) end;
function Number(O:TJSONObject;const Key:string;Lo,Hi:Double):Double;
begin
  Need((O.Find(Key)<>nil) and (O.Find(Key).JSONType=jtNumber),'numeric '+Key+' required');
  Result:=O.Find(Key).AsFloat;
  Need(not IsNan(Result) and not IsInfinite(Result) and (Result>=Lo) and (Result<=Hi),Key+' out of range');
  Result:=Round(Result*1000)/1000;
end;
function Point(J:TJSONData):TLatLon;
var A:TJSONArray;X,Y:Double;
begin
  Need(J is TJSONArray,'coordinate [longitude,latitude] required');A:=TJSONArray(J);
  Need(A.Count=2,'two coordinate components required');
  Need((A[0].JSONType=jtNumber) and (A[1].JSONType=jtNumber),'numeric coordinate required');
  X:=A[0].AsFloat;Y:=A[1].AsFloat;
  Need(not IsNan(X) and not IsInfinite(X) and not IsNan(Y) and not IsInfinite(Y) and
    (Abs(X)<=180) and (Abs(Y)<=85.051128),'invalid coordinate');
  Result:=TLatLon.Make(Round(Y*1e7)*1e-7,Round(X*1e7)*1e-7);
end;
function KindCategory(const Kind:string):string;
begin
  if Has(Kind,'|bench|street_lamp|utility_pole|traffic_signal|traffic_sign|crossing|sign|bus_stop|hydrant|bin|') then Exit('street_furniture');
  if Has(Kind,'|fence|wall|retaining_wall|hedge|parapet|') then Exit('fence');
  if Has(Kind,'|lawn|meadow|flowerbed|forest|scrub|') then Exit('vegetation');
  if Has(Kind,'|paving|parking|path|steps|') then Exit('terrain');
  if Kind='building' then Exit('building');
  Result:='';
end;
function IsPointKind(const Kind:string):Boolean;
begin Result:=KindCategory(Kind)='street_furniture' end;
function IsAreaKind(const Kind:string):Boolean;
begin Result:=(KindCategory(Kind)='vegetation') or Has(Kind,'|paving|parking|building|') end;
function Inside(const LL:TLatLon;const Ring:TPolygonRing):Boolean;
var I,J:Integer;DX,DY,T,D2:Double;
begin
  if PointInRingXZ(LL.Lon,LL.Lat,Ring) then Exit(True);
  for I:=0 to High(Ring) do begin
    J:=(I+1) mod Length(Ring);DX:=Ring[J].X-Ring[I].X;DY:=Ring[J].Z-Ring[I].Z;D2:=DX*DX+DY*DY;
    if D2<=0 then Continue;
    T:=EnsureRange(((LL.Lon-Ring[I].X)*DX+(LL.Lat-Ring[I].Z)*DY)/D2,0,1);
    if Sqr(LL.Lon-Ring[I].X-T*DX)+Sqr(LL.Lat-Ring[I].Z-T*DY)<1e-20 then Exit(True);
  end;
  Result:=False;
end;

function Cross(AX,AY,BX,BY:Double):Double;inline;
begin Result:=AX*BY-AY*BX end;

procedure CheckEdgeInside(const A,B:TLatLon;const Ring:TPolygonRing);
var Cuts:array of Double;I,J,K:Integer;DX,DY,EX,EY,Den,T,U,V:Double;Mid:TLatLon;
begin
  { A concave boundary may contain both endpoints but not their connecting
    edge. Split at every boundary intersection and test each open interval. }
  SetLength(Cuts,2);Cuts[0]:=0;Cuts[1]:=1;DX:=B.Lon-A.Lon;DY:=B.Lat-A.Lat;
  for I:=0 to High(Ring) do begin
    J:=(I+1) mod Length(Ring);EX:=Ring[J].X-Ring[I].X;EY:=Ring[J].Z-Ring[I].Z;
    Den:=Cross(DX,DY,EX,EY);if Abs(Den)<1e-22 then Continue;
    T:=Cross(Ring[I].X-A.Lon,Ring[I].Z-A.Lat,EX,EY)/Den;
    U:=Cross(Ring[I].X-A.Lon,Ring[I].Z-A.Lat,DX,DY)/Den;
    if (T>0) and (T<1) and (U>=-1e-9) and (U<=1+1e-9) then begin
      K:=Length(Cuts);SetLength(Cuts,K+1);Cuts[K]:=T;
    end;
  end;
  for I:=1 to High(Cuts) do begin
    V:=Cuts[I];J:=I-1;while (J>=0) and (Cuts[J]>V) do begin Cuts[J+1]:=Cuts[J];Dec(J) end;Cuts[J+1]:=V;
  end;
  for I:=1 to High(Cuts) do begin
    T:=(Cuts[I]+Cuts[I-1])*0.5;Mid:=TLatLon.Make(A.Lat+DY*T,A.Lon+DX*T);
    Need(Inside(Mid,Ring),'feature edge leaves boundary');
  end;
end;

function StrictInside(X,Y:Double;const R:TPolygonRing):Boolean;
var I,J:Integer;DX,DY,T,D2:Double;
begin
  Result:=False;
  for I:=0 to High(R) do begin
    J:=(I+1) mod Length(R);DX:=R[J].X-R[I].X;DY:=R[J].Z-R[I].Z;D2:=DX*DX+DY*DY;
    if D2<=0 then Continue;
    T:=EnsureRange(((X-R[I].X)*DX+(Y-R[I].Z)*DY)/D2,0,1);
    if Sqr(X-R[I].X-T*DX)+Sqr(Y-R[I].Z-T*DY)<1e-20 then Exit;
  end;
  Result:=PointInRingXZ(X,Y,R);
end;

function RingOverlap(const A,B:TPolygonRing):Boolean;
var I,J,K,L:Integer;Den,T,U,X,Y,DX,DY,Offset:Double;
begin
  Result:=False;if (Length(A)<3) or (Length(B)<3) then Exit;
  for I:=0 to High(A) do if StrictInside(A[I].X,A[I].Z,B) then Exit(True);
  for I:=0 to High(B) do if StrictInside(B[I].X,B[I].Z,A) then Exit(True);
  for I:=0 to High(A) do begin
    J:=(I+1) mod Length(A);
    for K:=0 to High(B) do begin
      L:=(K+1) mod Length(B);
      Den:=Cross(A[J].X-A[I].X,A[J].Z-A[I].Z,B[L].X-B[K].X,B[L].Z-B[K].Z);
      if Abs(Den)<1e-22 then Continue;
      T:=Cross(B[K].X-A[I].X,B[K].Z-A[I].Z,B[L].X-B[K].X,B[L].Z-B[K].Z)/Den;
      U:=Cross(B[K].X-A[I].X,B[K].Z-A[I].Z,A[J].X-A[I].X,A[J].Z-A[I].Z)/Den;
      if (T>1e-8) and (T<1-1e-8) and (U>1e-8) and (U<1-1e-8) then Exit(True);
    end;
    { Detect coincident rings, while permitting a shared wall. }
    X:=(A[I].X+A[J].X)*0.5;Y:=(A[I].Z+A[J].Z)*0.5;
    if StrictInside(X,Y,B) then Exit(True);
    { Equal concave rings may have every vertex on the boundary and their
      centroid outside. Probe both sides of a shared edge; adjacent buildings
      share a wall but never the same interior side. Coordinates are doubles. }
    DX:=A[J].X-A[I].X;DY:=A[J].Z-A[I].Z;Den:=Hypot(DX,DY);
    if Den>1e-12 then begin
      Offset:=Min(1e-8,Den*1e-4);DX:=DX/Den*Offset;DY:=DY/Den*Offset;
      if StrictInside(X-DY,Y+DX,A) and StrictInside(X-DY,Y+DX,B) then Exit(True);
      if StrictInside(X+DY,Y-DX,A) and StrictInside(X+DY,Y-DX,B) then Exit(True);
    end;
  end;
  X:=0;Y:=0;for I:=0 to High(A) do begin X+=A[I].X;Y+=A[I].Z end;
  X/=Length(A);Y/=Length(A);Result:=StrictInside(X,Y,A) and StrictInside(X,Y,B);
end;

function CanonicalEnvironmentLayout(Value:TJSONData;const Category:string):string;
var O,F,C,R,Check:TJSONObject; A,P,Features,Coordinates:TJSONArray;
  I,J,K:Integer;Kind,Id,S:string;B:TLatLonBox;Boundary:TPhotoPlantBoundary;
  Ring:TPolygonRing;LL:TLatLon;Tmp:TJSONData;Seen:TStringList;
begin
  Need(Value is TJSONObject,'object required');O:=TJSONObject(Value);
  Keys(O,'|version|boundary|features|');Need(Number(O,'version',1,1)=1,'version must be 1');
  Need(O.Find('boundary') is TJSONArray,'explicit bounded area required');
  { Share the tested simple-ring validator with plant layouts. }
  Check:=TJSONObject.Create(['version',1,'mode','replace_scatter','boundary',O.Find('boundary').Clone,'plants',TJSONArray.Create]);
  try
    S:=CanonicalVegetationLayout(Check);Boundary:=VegetationLayoutBoundary(S);
  finally Check.Free end;
  B:=TLatLonBox.Empty;SetLength(Ring,Length(Boundary));
  for I:=0 to High(Boundary) do begin B:=B.Include(Boundary[I]);Ring[I].X:=Boundary[I].Lon;Ring[I].Z:=Boundary[I].Lat end;
  Need(O.Find('features') is TJSONArray,'features array required');A:=TJSONArray(O.Find('features'));
  Need((A.Count>0) and (A.Count<=256),'1..256 features required');
  R:=TJSONObject.Create(['version',1]);Seen:=TStringList.Create;
  try
    Coordinates:=TJSONArray.Create;R.Add('boundary',Coordinates);
    for LL in Boundary do Coordinates.Add(TJSONArray.Create([LL.Lon,LL.Lat]));
    Features:=TJSONArray.Create;R.Add('features',Features);
    for I:=0 to A.Count-1 do begin
      Need(A[I] is TJSONObject,'feature object required');F:=TJSONObject(A[I]);
      Keys(F,'|id|kind|points|height_m|width_m|material|surface|genus|leaf_type|spacing_m|heading_deg|gates|levels|roof_shape|roof_height_m|architecture|sign_type|');
      Id:=F.Get('id','');Need((Length(Id)>0) and (Length(Id)<=64),'bounded stable id required');
      for J:=1 to Length(Id) do Need(Id[J] in ['a'..'z','A'..'Z','0'..'9',':','-','_'],'invalid feature id');
      Need(Seen.IndexOf(Id)<0,'duplicate id');Seen.Add(Id);
      Kind:=F.Get('kind','');Need((KindCategory(Kind)<>'') and (KindCategory(Kind)=Category),'unsupported kind/category '+Kind);
      Need(F.Find('points') is TJSONArray,'points required');P:=TJSONArray(F.Find('points'));
      if IsPointKind(Kind) then Need(P.Count=1,'point feature needs one position')
      else if IsAreaKind(Kind) then Need((P.Count>=3) and (P.Count<=64),'area needs 3..64 vertices')
      else Need((P.Count>=2) and (P.Count<=64),'line needs 2..64 vertices');
      C:=TJSONObject.Create(['id',Id,'kind',Kind]);Features.Add(C);
      Coordinates:=TJSONArray.Create;C.Add('points',Coordinates);
      for J:=0 to P.Count-1 do begin
        LL:=Point(P[J]);
        Need(Inside(LL,Ring),'feature outside boundary');
        if J>0 then Need((LL.Lat<>Point(P[J-1]).Lat) or (LL.Lon<>Point(P[J-1]).Lon),'zero length edge');
        Coordinates.Add(TJSONArray.Create([LL.Lon,LL.Lat]));
        if J>0 then CheckEdgeInside(Point(P[J-1]),LL,Ring);
      end;
      if IsAreaKind(Kind) then begin
        CheckEdgeInside(Point(P[P.Count-1]),Point(P[0]),Ring);
        Check:=TJSONObject.Create(['version',1,'mode','replace_scatter','boundary',Coordinates.Clone,'plants',TJSONArray.Create]);
        try S:=CanonicalVegetationLayout(Check) finally Check.Free end;
      end;
      if F.Find('height_m')<>nil then begin
        Need((Category='fence') or Has(Kind,'|forest|scrub|building|'),'height only supported for boundaries/plants/buildings');
        C.Add('height_m',Number(F,'height_m',0.2,30));
      end;
      if F.Find('width_m')<>nil then begin
        Need(Has(Kind,'|path|steps|'),'width only supported for paths/steps');C.Add('width_m',Number(F,'width_m',0.5,15));
      end;
      if F.Find('material')<>nil then begin
        Need(Category='fence','material only supported for boundaries');S:=F.Get('material','');
        Need(Has(S,'|wood|metal|chain_link|concrete|stone|'),'unsupported material');C.Add('material',S);
      end;
      if F.Find('surface')<>nil then begin
        Need(Category='terrain','surface only supported for terrain');S:=F.Get('surface','');
        Need(Has(S,'|asphalt|concrete|paving_stones|cobblestone|gravel|compacted|dirt|ground|sand|wood|'),'unsupported surface');C.Add('surface',S);
      end;
      if F.Find('genus')<>nil then begin
        Need(Has(Kind,'|forest|scrub|'),'genus only supported for wooded areas');
        Check:=TJSONObject.Create(['version',1,'mode','replace_scatter','plants',TJSONArray.Create([
          TJSONObject.Create(['id','check','kind','tree','height_m',5,'position',Coordinates[0].Clone,'genus',F.Get('genus','')])])]);
        try S:=CanonicalVegetationLayout(Check) finally Check.Free end;
        C.Add('genus',LowerCase(F.Get('genus','')));
      end;
      if F.Find('leaf_type')<>nil then begin
        Need(Has(Kind,'|forest|scrub|'),'leaf type only supported for wooded areas');S:=F.Get('leaf_type','');
        Need(Has(S,'|broadleaved|needleleaved|mixed|'),'unsupported leaf type');C.Add('leaf_type',S);
      end;
      if F.Find('spacing_m')<>nil then begin
        Need(Has(Kind,'|forest|scrub|'),'spacing only supported for wooded areas');C.Add('spacing_m',Number(F,'spacing_m',2,60));
      end;
      if F.Find('heading_deg')<>nil then begin
        Need(IsPointKind(Kind),'heading only for street furniture');C.Add('heading_deg',Number(F,'heading_deg',0,360));
      end;
      if Kind='traffic_sign' then begin
        Need(F.Find('heading_deg')<>nil,'traffic sign needs observed facing direction');S:=F.Get('sign_type','');
        Need(Has(S,'|crossing_right|crossing_left|bump_warning|bump|'),'unsupported sign atlas cell');C.Add('sign_type',S);
      end else Need(F.Find('sign_type')=nil,'sign_type only for traffic_sign');
      if F.Find('gates')<>nil then begin
        Need(Category='fence','gate indices only for fences');Need(F.Find('gates') is TJSONArray,'gate array required');
        Tmp:=F.Find('gates');Need(Tmp.Count<=16,'at most 16 gates');
        for J:=0 to Tmp.Count-1 do begin
          Need((Tmp.Items[J].JSONType=jtNumber) and (Frac(Tmp.Items[J].AsFloat)=0),'integer gate index required');
          K:=Tmp.Items[J].AsInteger;Need((K>=0) and (K<P.Count),'gate index out of range');
        end;
        C.Add('gates',Tmp.Clone);
      end;
      if Kind='building' then begin
        Need(F.Find('height_m')<>nil,'local building height required');
        if F.Find('levels')<>nil then begin
          K:=Round(Number(F,'levels',1,10));Need(K=F.Get('levels',0.0),'integer levels');C.Add('levels',K);
        end;
        S:=F.Get('roof_shape','flat');Need(Has(S,'|flat|gabled|hipped|pyramidal|'),'unsupported local roof');C.Add('roof_shape',S);
        if F.Find('roof_height_m')<>nil then begin
          C.Add('roof_height_m',Number(F,'roof_height_m',0,12));
          Need(C.Get('roof_height_m',0.0)<C.Get('height_m',0.0),'roof must fit building height');
        end;
        if F.Find('architecture')<>nil then begin
          S:=CanonicalArchitecture(F.Find('architecture'));C.Add('architecture',ParsePhotoJson(S));
        end;
      end else Need((F.Find('levels')=nil) and (F.Find('roof_shape')=nil) and
        (F.Find('roof_height_m')=nil) and (F.Find('architecture')=nil),'building properties require building kind');
    end;
    Result:=R.AsJSON;
  finally Seen.Free;R.Free end;
end;

function EnvironmentLayoutBox(const Text:string):TLatLonBox;
var O:TJSONData;A:TJSONArray;I:Integer;
begin
  Result:=TLatLonBox.Empty;O:=ParsePhotoJson(Text);
  try A:=TJSONArray(O.FindPath('boundary'));for I:=0 to A.Count-1 do Result:=Result.Include(Point(A[I]));finally O.Free end;
end;
function LocalId(const S:string):Int64;
begin Result:=-StrToInt64('$'+Copy(MD5Print(MD5String('photo-environment-v1:'+S)),1,15)) end;
procedure SetTags(T:TOSMTags;F:TJSONObject);
var Kind,S:string;FS:TFormatSettings;
begin
  Kind:=F.Get('kind','');FS:=DefaultFormatSettings;FS.DecimalSeparator:='.';
  if IsAreaKind(Kind) then T.Add('rezvivo:photo_replace_scatter','yes');
  if Kind='building' then begin
    T.Add('building','yes');T.Add('roof:shape',F.Get('roof_shape','flat'));
    if F.Find('levels')<>nil then T.Add('building:levels',IntToStr(F.Get('levels',1)));
    if F.Find('roof_height_m')<>nil then T.Add('roof:height',FloatToStr(F.Get('roof_height_m',0.0),FS));
    if F.Find('architecture')<>nil then T.Add(ARCHITECTURE_TAG,F.Find('architecture').AsJSON);
  end else if Kind='bench' then T.Add('amenity','bench')
  else if Kind='bin' then T.Add('amenity','waste_basket')
  else if Kind='street_lamp' then T.Add('highway','street_lamp')
  else if Kind='utility_pole' then T.Add('man_made','utility_pole')
  else if Kind='traffic_signal' then T.Add('highway','traffic_signals')
  else if Kind='traffic_sign' then begin T.Add('traffic_sign',F.Get('sign_type',''));T.Add('rezvivo:photo_sign',F.Get('sign_type','')) end
  else if Kind='crossing' then begin T.Add('highway','crossing');T.Add('crossing','uncontrolled');T.Add('rezvivo:photo_crossing','yes') end
  else if Kind='sign' then T.Add('tourism','information')
  else if Kind='bus_stop' then T.Add('highway','bus_stop')
  else if Kind='hydrant' then T.Add('emergency','fire_hydrant')
  else if Kind='hedge' then T.Add('barrier','hedge')
  else if Kind='fence' then begin T.Add('barrier','fence');S:=F.Get('material','metal');T.Add('fence_type',S);T.Add('material',S) end
  else if Has(Kind,'|wall|retaining_wall|parapet|') then begin
    if Kind='retaining_wall' then T.Add('barrier','retaining_wall') else T.Add('barrier','wall');
    T.Add('material',F.Get('material','stone'));
  end else if Kind='lawn' then T.Add('leisure','garden')
  else if Kind='meadow' then T.Add('landuse','meadow')
  else if Kind='flowerbed' then T.Add('landuse','flowerbed')
  else if Kind='forest' then T.Add('natural','wood')
  else if Kind='scrub' then T.Add('natural','scrub')
  else if Kind='parking' then begin T.Add('amenity','parking');T.Add('surface',F.Get('surface','asphalt')) end
  else if Kind='paving' then begin T.Add('highway','pedestrian');T.Add('area','yes');T.Add('surface',F.Get('surface','paving_stones')) end
  else if Has(Kind,'|path|steps|') then begin
    if Kind='steps' then T.Add('highway','steps') else T.Add('highway','footway');
    T.Add('surface',F.Get('surface','paving_stones'));
  end;
  if F.Find('height_m')<>nil then T.Add('height',FloatToStr(F.Floats['height_m'],FS));
  if F.Find('width_m')<>nil then T.Add('width',FloatToStr(F.Floats['width_m'],FS));
  if F.Find('spacing_m')<>nil then T.Add('rezvivo:plant_spacing',FloatToStr(F.Floats['spacing_m'],FS));
  if F.Find('genus')<>nil then T.Add('genus',F.Get('genus',''));
  if F.Find('leaf_type')<>nil then T.Add('leaf_type',F.Get('leaf_type',''));
  if F.Find('heading_deg')<>nil then T.Add('direction',FloatToStr(F.Floats['heading_deg'],FS));
end;

procedure StageEnvironmentLayout(const Text,Owner:string;Dataset:TOSMDataset;
  Nodes:TEnvironmentNodes;Ways:TEnvironmentWays);
var O,F:TJSONObject;A,P,G:TJSONArray;I,J,K:Integer;N,Existing:TOSMNode;W:TOSMWay;
  Kind,Key:string;Id:Int64;LL:TLatLon;Duplicate:Boolean;Probe:TOSMTags;
  CandidateRing,OtherRing:TPolygonRing;Other:TOSMWay;Rel:TOSMRelation;Member:TOSMRelationMember;
  function FindStagedNode(Id:Int64):TOSMNode;
  var V:Integer;
  begin
    Result:=Dataset.FindNode(Id);if Result<>nil then Exit;
    for V:=0 to Nodes.Count-1 do if Nodes[V].Id=Id then Exit(Nodes[V]);
  end;
  procedure CheckFence(Other:TOSMWay);
  var V,X:Integer;A0,B0:TLatLon;C0,D0:TOSMNode;
    ScaleX,AX,AZ,CX,CZ,DX,DZ,Len,OtherLen,U0,U1,Lo,Hi,T,Near0,Near1:Double;
  begin
    if (Other=nil) or not Other.Tags.HasKey('barrier') then Exit;
    for V:=1 to P.Count-1 do begin
      A0:=Point(P[V-1]);B0:=Point(P[V]);ScaleX:=111320*Cos(A0.Lat*Pi/180);
      AX:=(B0.Lon-A0.Lon)*ScaleX;AZ:=(B0.Lat-A0.Lat)*111320;Len:=Hypot(AX,AZ);
      if Len<0.01 then Continue;AX/=Len;AZ/=Len;
      for X:=1 to High(Other.NodeRefs) do begin
        C0:=FindStagedNode(Other.NodeRefs[X-1]);D0:=FindStagedNode(Other.NodeRefs[X]);
        if (C0=nil) or (D0=nil) then Continue;
        CX:=(C0.Position.Lon-A0.Lon)*ScaleX;CZ:=(C0.Position.Lat-A0.Lat)*111320;
        DX:=(D0.Position.Lon-A0.Lon)*ScaleX;DZ:=(D0.Position.Lat-A0.Lat)*111320;
        OtherLen:=Hypot(DX-CX,DZ-CZ);if OtherLen<0.01 then Continue;
        if Abs((DX-CX)*AX+(DZ-CZ)*AZ)<OtherLen*0.985 then Continue;
        U0:=CX*AX+CZ*AZ;U1:=DX*AX+DZ*AZ;
        Lo:=Max(0,Min(U0,U1));Hi:=Min(Len,Max(U0,U1));if Hi-Lo<0.4 then Continue;
        T:=(Lo-U0)/(U1-U0);Near0:=Abs((CX+(DX-CX)*T)*AZ-(CZ+(DZ-CZ)*T)*AX);
        T:=(Hi-U0)/(U1-U0);Near1:=Abs((CX+(DX-CX)*T)*AZ-(CZ+(DZ-CZ)*T)*AX);
        Need(Max(Near0,Near1)>0.35,'local fence overlaps a mapped or staged barrier; identify the existing boundary instead');
      end;
    end;
  end;
  procedure CheckFootprint(Other:TOSMWay);
  var V,X:Integer;Vertex:TOSMNode;Box,CandidateBox:TLatLonBox;Complete:Boolean;
  begin
    if Other=nil then Exit;
    Box:=TLatLonBox.Empty;CandidateBox:=TLatLonBox.Empty;Complete:=True;
    for V:=0 to High(CandidateRing) do CandidateBox:=CandidateBox.Include(TLatLon.Make(CandidateRing[V].Z,CandidateRing[V].X));
    for V:=0 to High(Other.NodeRefs) do begin
      Vertex:=Dataset.FindNode(Other.NodeRefs[V]);
      if Vertex=nil then for X:=0 to Nodes.Count-1 do if Nodes[X].Id=Other.NodeRefs[V] then begin Vertex:=Nodes[X];Break end;
      if Vertex=nil then Complete:=False else Box:=Box.Include(Vertex.Position);
    end;
    if Box.IsEmpty or (Box.MaxLat<=CandidateBox.MinLat) or (Box.MinLat>=CandidateBox.MaxLat) or
      (Box.MaxLon<=CandidateBox.MinLon) or (Box.MinLon>=CandidateBox.MaxLon) then Exit;
    Need(Complete and Other.IsClosed,'local building intersects an incomplete/component footprint; refine the existing relation instead');
    SetLength(OtherRing,Length(Other.NodeRefs)-1);
    for V:=0 to High(OtherRing) do begin
      Vertex:=Dataset.FindNode(Other.NodeRefs[V]);
      if Vertex=nil then for X:=0 to Nodes.Count-1 do if Nodes[X].Id=Other.NodeRefs[V] then begin Vertex:=Nodes[X];Break end;
      Need(Vertex<>nil,'incomplete existing footprint near a local building');
      OtherRing[V].X:=Vertex.Position.Lon;OtherRing[V].Z:=Vertex.Position.Lat;
    end;
    Need(not RingOverlap(CandidateRing,OtherRing),'local building overlaps an existing footprint; refine its OSM object instead');
  end;
begin
  O:=TJSONObject(ParsePhotoJson(Text));Probe:=TOSMTags.Create;
  try
    A:=TJSONArray(O.Find('features'));
    for I:=0 to A.Count-1 do begin
      F:=TJSONObject(A[I]);Kind:=F.Get('kind','');P:=TJSONArray(F.Find('points'));Key:=Owner+':'+F.Get('id','');
      if IsPointKind(Kind) then begin
        LL:=Point(P[0]);Probe.Clear;SetTags(Probe,F);Duplicate:=False;
        { Bounded additions preserve existing surveyed OSM furniture. }
        for Existing in Dataset.Nodes.Values do begin
          if Sqr((Existing.Position.Lat-LL.Lat)*111320)+
             Sqr((Existing.Position.Lon-LL.Lon)*111320*Cos(LL.Lat*Pi/180))>4 then Continue;
          if Existing.Tags.HasKeyValue(Probe.Keys[0],Probe.Values[0]) then Duplicate:=True;
          if Duplicate then Break;
        end;
        if not Duplicate then for Existing in Nodes do begin
          if Existing.Tags.HasKeyValue(Probe.Keys[0],Probe.Values[0]) and
            (Sqr((Existing.Position.Lat-LL.Lat)*111320)+
             Sqr((Existing.Position.Lon-LL.Lon)*111320*Cos(LL.Lat*Pi/180))<=4) then begin Duplicate:=True;Break end;
        end;
        if Duplicate then Continue;
        Id:=LocalId(Key);Need(Dataset.FindNode(Id)=nil,'generated node identity collision');
        N:=TOSMNode.Create(Id,LL);Nodes.Add(N);SetTags(N.Tags,F);N.Tags.Add('rezvivo:local_photo_object',Owner);
      end else begin
        if Has(Kind,'|fence|wall|retaining_wall|hedge|parapet|') then begin
          for Other in Dataset.Ways.Values do CheckFence(Other);
          for Other in Ways do CheckFence(Other);
        end;
        if Kind='building' then begin
          SetLength(CandidateRing,P.Count);
          for J:=0 to P.Count-1 do begin LL:=Point(P[J]);CandidateRing[J].X:=LL.Lon;CandidateRing[J].Z:=LL.Lat end;
          for Other in Dataset.Ways.Values do
            if Other.Tags.HasKey('building') or Other.Tags.HasKey('building:part') then CheckFootprint(Other);
          for Other in Ways do if Other.Tags.HasKey('building') then CheckFootprint(Other);
          for Rel in Dataset.Relations.Values do
            if Rel.Tags.HasKey('building') or Rel.Tags.HasKey('building:part') then
              for Member in Rel.Members do
                if (Member.Kind=omkWay) and ((Member.Role='outer') or (Member.Role='')) then CheckFootprint(Dataset.FindWay(Member.Ref));
        end;
        Id:=LocalId(Key);Need(Dataset.FindWay(Id)=nil,'generated way identity collision');
        W:=TOSMWay.Create(Id);Ways.Add(W);SetTags(W.Tags,F);W.Tags.Add('rezvivo:local_photo_object',Owner);
        SetLength(W.NodeRefs,P.Count+Ord(IsAreaKind(Kind)));
        for J:=0 to P.Count-1 do begin
          Id:=LocalId(Key+':'+IntToStr(J));Need(Dataset.FindNode(Id)=nil,'generated vertex identity collision');
          N:=TOSMNode.Create(Id,Point(P[J]));Nodes.Add(N);W.NodeRefs[J]:=Id;
          G:=TJSONArray(F.Find('gates'));if G<>nil then for K:=0 to G.Count-1 do
            if G[K].AsInteger=J then begin N.Tags.Add('barrier','gate');N.Tags.Add('width','3') end;
        end;
        if IsAreaKind(Kind) then W.NodeRefs[High(W.NodeRefs)]:=W.NodeRefs[0];
      end;
      Need((Nodes.Count<=65536) and (Ways.Count<=8192),'generated object budget exceeded');
    end;
  finally Probe.Free;O.Free end;
end;
function EnvironmentLayoutCapabilities:TJSONObject;
begin
  Result:=TJSONObject.Create(['version',1,'boundary','simple ring <=250m, within 80m of a fingerprinted OSM anchor',
    'features','stable id, kind, points [lon,lat]; native generators, terrain grounding and shared batching',
    'street_furniture','bench, bin, street_lamp, utility_pole, traffic_signal, crossing, traffic_sign (sign_type and heading_deg), information sign, bus_stop, hydrant',
    'fence','fence, wall, retaining_wall, hedge, parapet; gates are indices into points',
    'vegetation','lawn, meadow, flowerbed, forest, scrub; wooded areas allow spacing_m, genus, leaf_type',
    'terrain','paving, parking, path, steps; surface and path width_m',
    'building','bounded footprint, height_m <=30, levels <=10, roof_shape/roof_height_m, optional architecture; requires a measured footprint, never a camera point',
    'limits','256 features, 64 vertices/feature; preserve nearby existing point objects']);
end;
end.
