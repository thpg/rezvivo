unit Osm3dPhotoRoadProfile;
{$mode objfpc}{$H+}
interface
uses Classes,SysUtils,fpjson,Generics.Collections,Osm3dOsmData,Osm3dGeoMath;
const PHOTO_ROAD_PROFILE_TAG='rezvivo:road_profile';
  PHOTO_ROAD_PROFILE_GENERATOR=1;
type
  TPhotoRoadStation=record AtM,Width,Offset:Double end;
  TPhotoRoadStations=array of TPhotoRoadStation;
  TPhotoRoadProfile=record Stations:TPhotoRoadStations; Blend:Double end;
  TPhotoRoadPlan=class
    Way:TOSMWay;
    Refs:TOSMIdArray;
    Widths:TOSMSingleArray;
    Nodes:specialize TObjectList<TOSMNode>;
    constructor Create;
    destructor Destroy;override;
    procedure Apply(Dataset:TOSMDataset);
  end;
function CanonicalPhotoRoadProfile(Value:TJSONData; Sidewalk:Boolean):string;
procedure ValidatePhotoRoadSource(const Text:string; Source:TJSONObject; BaseWidth:Double;
  CheckGeometry:Boolean=True);
function BuildPhotoRoadPlan(const Text:string; Way:TOSMWay; Dataset:TOSMDataset;
  BaseWidth:Double):TPhotoRoadPlan;
function PhotoRoadCapabilities:TJSONObject;
implementation
uses Math,MD5,Osm3dPhotoSources,Osm3dTileKnowledge;
type TDoubles=array of Double; TPositions=array of TLatLon;
procedure Need(B:Boolean;const S:string);
begin if not B then raise ETileKnowledge.Create('road.profile: '+S) end;
procedure Keys(O:TJSONObject;const Allowed:string);
var I:Integer;
begin for I:=0 to O.Count-1 do Need(Pos('|'+O.Names[I]+'|',Allowed)>0,'unknown field '+O.Names[I]) end;
function Number(O:TJSONObject;const Key:string;Lo,Hi:Double):Double;
var V:TJSONData;
begin
  V:=O.Find(Key);Need((V<>nil) and (V.JSONType=jtNumber),Key+' must be a number');
  Result:=V.AsFloat;Need(not IsNan(Result) and not IsInfinite(Result) and
    (Result>=Lo) and (Result<=Hi),Key+' out of range');
end;
function Decode(Value:TJSONData;Sidewalk:Boolean;AnyWidth:Boolean=False):TPhotoRoadProfile;
var O,P:TJSONObject;A:TJSONArray;I:Integer;MinW,MaxW,D:Double;
begin
  Result:=Default(TPhotoRoadProfile);Need(Value is TJSONObject,'object required');O:=TJSONObject(Value);
  Keys(O,'|version|blend_m|stations|');Need(Number(O,'version',1,1)=1,'version 1 required');
  Result.Blend:=Number(O,'blend_m',2,100);
  Need(O.Find('stations') is TJSONArray,'stations required');A:=TJSONArray(O.Find('stations'));
  Need((A.Count>=2) and (A.Count<=64),'2..64 stations required');
  if Sidewalk then begin MinW:=0.5;MaxW:=15 end else begin MinW:=1;MaxW:=60 end;
  if AnyWidth then begin MinW:=0.5;MaxW:=60 end;
  SetLength(Result.Stations,A.Count);
  for I:=0 to A.Count-1 do begin
    Need(A[I] is TJSONObject,'station object required');P:=TJSONObject(A[I]);
    Keys(P,'|at_m|width_m|offset_m|');
    with Result.Stations[I] do begin
      AtM:=Round(Number(P,'at_m',0,20000)*1000)*0.001;
      Width:=Round(Number(P,'width_m',MinW,MaxW)*1000)*0.001;
      Offset:=0;if P.Find('offset_m')<>nil then Offset:=Round(Number(P,'offset_m',-8,8)*1000)*0.001;
    end;
    if I>0 then begin
      D:=Result.Stations[I].AtM-Result.Stations[I-1].AtM;
      Need(D>=1,'stations must be ordered and at least 1 m apart');
      Need(Abs(Result.Stations[I].Width-Result.Stations[I-1].Width)<=D*0.5,'width transition too abrupt');
      Need(Abs(Result.Stations[I].Offset-Result.Stations[I-1].Offset)<=D*0.3,'offset transition too abrupt');
    end;
  end;
end;
function CanonicalPhotoRoadProfile(Value:TJSONData;Sidewalk:Boolean):string;
var P:TPhotoRoadProfile;O:TJSONObject;A:TJSONArray;I:Integer;
begin
  P:=Decode(Value,Sidewalk);A:=TJSONArray.Create;
  O:=TJSONObject.Create(['version',1,'blend_m',P.Blend,'stations',A]);
  try
    for I:=0 to High(P.Stations) do with P.Stations[I] do
      A.Add(TJSONObject.Create(['at_m',AtM,'width_m',Width,'offset_m',Offset]));
    Result:=O.AsJSON;
  finally O.Free end;
end;
function ReadProfile(const Text:string):TPhotoRoadProfile;
var J:TJSONData;
begin J:=ParsePhotoJson(Text);try Result:=Decode(J,True,True) finally J.Free end end;
procedure ValidatePhotoRoadSource(const Text:string;Source:TJSONObject; BaseWidth:Double;
  CheckGeometry:Boolean);
var P:TPhotoRoadProfile;A,Locked:TJSONArray;I:Integer;Tags:TJSONObject;L:Double;Prev,LL:TLatLon;
  Data:TOSMDataset; W:TOSMWay; N:TOSMNode; Plan:TPhotoRoadPlan;
  function Enabled(const Key:string):Boolean;
  var V:string;
  begin V:=LowerCase(Tags.Get(Key,''));Result:=(V<>'') and (V<>'no') and (V<>'false') and (V<>'0') end;
begin
  P:=ReadProfile(Text);Need(Source.Get('type','')='way','requires an OSM way');
  Need(Source.Get('geometry_complete',False),'complete source required');
  Need(not Source.Get('closed',False),'closed ways are not supported by an open profile');
  Need(Source.Find('tags') is TJSONObject,'source tags required');
  Tags:=TJSONObject(Source.Find('tags'));
  Need(not Enabled('bridge') and not Enabled('tunnel') and not Enabled('area'),
    'bridge, tunnel and area profiles require their own geometry support');
  Need(Source.Find('outline') is TJSONArray,'complete source outline required');
  A:=TJSONArray(Source.Find('outline'));Need((A.Count>=2) and (A.Count<=8192),'unsupported source point count');
  L:=0;
  for I:=0 to A.Count-1 do begin
    LL:=TLatLon.Make(A[I].Items[1].AsFloat,A[I].Items[0].AsFloat);
    if I>0 then begin
      Need(Prev.DistanceTo(LL)<2000,'source has an excessively long segment');
      L+=Prev.DistanceTo(LL);
    end;
    Prev:=LL;
  end;
  Need((L>=1) and (L<=20000),'source length out of range');
  Need(P.Stations[High(P.Stations)].AtM<=L+0.02,'station exceeds original way length');
  Need(Source.Find('locked_node_indices') is TJSONArray,'source junction metadata required');
  if not CheckGeometry then Exit; { the worker builds its actual plan once below }
  Locked:=TJSONArray(Source.Find('locked_node_indices'));
  { Preview executes the same geometry planner as the worker, on a borrowed
    description of the original way. Protected vertices remain protected. }
  Data:=TOSMDataset.Create;Plan:=nil;
  try
    W:=TOSMWay.Create(1);Data.AddWay(W);SetLength(W.NodeRefs,A.Count);
    for I:=0 to A.Count-1 do begin
      N:=TOSMNode.Create(I+1,TLatLon.Make(A[I].Items[1].AsFloat,A[I].Items[0].AsFloat));
      Data.AddNode(N);W.NodeRefs[I]:=N.Id;
    end;
    for I:=0 to Locked.Count-1 do begin
      Need((Locked[I].AsInteger>=0) and (Locked[I].AsInteger<A.Count),'invalid protected vertex');
      Data.FindNode(Locked[I].AsInteger+1).Tags.Add('protected','yes');
    end;
    Plan:=BuildPhotoRoadPlan(Text,W,Data,BaseWidth);
  finally Plan.Free;Data.Free end;
end;
constructor TPhotoRoadPlan.Create;
begin inherited;Nodes:=specialize TObjectList<TOSMNode>.Create(True) end;
destructor TPhotoRoadPlan.Destroy;
begin Nodes.Free;inherited end;
procedure TPhotoRoadPlan.Apply(Dataset:TOSMDataset);
var I:Integer;
begin
  Nodes.OwnsObjects:=False;
  for I:=0 to Nodes.Count-1 do Dataset.AddNode(Nodes[I]);
  Way.NodeRefs:=Refs;Way.PhotoWidths:=Widths;Way.HasPhotoProfile:=True;
end;
function BuildPhotoRoadPlan(const Text:string;Way:TOSMWay;Dataset:TOSMDataset;
  BaseWidth:Double):TPhotoRoadPlan;
var Profile:TPhotoRoadProfile;Positions:TPositions;Along,Points:TDoubles;
  I,J,K,N,OriginalIndex:Integer;Total,D,Alpha,W,Offset,E,Nth,Len,AtM,StartM,EndM:Double;
  E1,N1,E2,N2,L1,L2:Double;
  LL:TLatLon;Node:TOSMNode;Other:TOSMWay;Locked,HasOffset:Boolean;Seed:string;Id:Int64;
  Shared:specialize TDictionary<Int64,Boolean>;
  procedure InsertPoint(Value:Double);
  var A,B,M:Integer;
  begin
    Value:=EnsureRange(Value,0,Total);A:=0;B:=Length(Points);
    while A<B do begin M:=(A+B) div 2;if Points[M]<Value then A:=M+1 else B:=M end;
    { E7 source coordinates are centimetre quantised: do not create a
      second node that collapses onto the same location after quantisation. }
    if (A<Length(Points)) and (Abs(Points[A]-Value)<0.02) then Exit;
    if (A>0) and (Abs(Points[A-1]-Value)<0.02) then Exit;
    B:=Length(Points);SetLength(Points,B+1);
    while B>A do begin Points[B]:=Points[B-1];Dec(B) end;Points[A]:=Value;
  end;
  procedure AtStation(S:Double;out Width,Shift:Double);
  var A:Integer;T,Span:Double;
  begin
    Width:=BaseWidth;Shift:=0;
    if (S<StartM-0.001) or (S>EndM+0.001) then Exit;
    if S<Profile.Stations[0].AtM then begin
      Span:=Profile.Stations[0].AtM-StartM;
      if Span<=0.001 then Exit;
      T:=(S-StartM)/Span;Width:=BaseWidth+(Profile.Stations[0].Width-BaseWidth)*T;
      Shift:=Profile.Stations[0].Offset*T;Exit;
    end;
    A:=High(Profile.Stations);
    if S>Profile.Stations[A].AtM then begin
      Span:=EndM-Profile.Stations[A].AtM;if Span<=0.001 then Exit;
      T:=(EndM-S)/Span;Width:=BaseWidth+(Profile.Stations[A].Width-BaseWidth)*T;
      Shift:=Profile.Stations[A].Offset*T;Exit;
    end;
    A:=0;while (A<High(Profile.Stations)-1) and (S>Profile.Stations[A+1].AtM) do Inc(A);
    T:=EnsureRange((S-Profile.Stations[A].AtM)/(Profile.Stations[A+1].AtM-Profile.Stations[A].AtM),0,1);
    Width:=Profile.Stations[A].Width+(Profile.Stations[A+1].Width-Profile.Stations[A].Width)*T;
    Shift:=Profile.Stations[A].Offset+(Profile.Stations[A+1].Offset-Profile.Stations[A].Offset)*T;
  end;
begin
  Result:=nil;Shared:=nil;Profile:=ReadProfile(Text);N:=Length(Way.NodeRefs);
  Need((BaseWidth>=0.5) and (BaseWidth<=60),'base width out of range');
  Need((N>=2) and (N<=8192) and not Way.IsClosed,'unsupported source way');
  SetLength(Positions,N);SetLength(Along,N);Total:=0;
  for I:=0 to N-1 do begin
    Node:=Dataset.FindNode(Way.NodeRefs[I]);Need(Node<>nil,'source node missing');Positions[I]:=Node.Position;
    if I>0 then Total+=Positions[I-1].DistanceTo(Positions[I]);Along[I]:=Total;
  end;
  Need(Profile.Stations[High(Profile.Stations)].AtM<=Total+0.02,'station exceeds original way length');
  StartM:=Max(0,Profile.Stations[0].AtM-Profile.Blend);
  EndM:=Min(Total,Profile.Stations[High(Profile.Stations)].AtM+Profile.Blend);
  if Profile.Stations[0].AtM>0 then begin
    D:=Profile.Stations[0].AtM-StartM;
    Need(Abs(Profile.Stations[0].Width-BaseWidth)<=D*0.5+0.001,'start width blend too abrupt');
    Need(Abs(Profile.Stations[0].Offset)<=D*0.3+0.001,'start offset blend too abrupt');
  end;
  K:=High(Profile.Stations);
  if Profile.Stations[K].AtM<Total-0.02 then begin
    D:=EndM-Profile.Stations[K].AtM;
    Need(Abs(Profile.Stations[K].Width-BaseWidth)<=D*0.5+0.001,'end width blend too abrupt');
    Need(Abs(Profile.Stations[K].Offset)<=D*0.3+0.001,'end offset blend too abrupt');
  end;
  Points:=Copy(Along);
  InsertPoint(StartM);InsertPoint(EndM);
  for I:=0 to High(Profile.Stations) do InsertPoint(Profile.Stations[I].AtM);
  Result:=TPhotoRoadPlan.Create;
  try
    HasOffset:=False;for I:=0 to High(Profile.Stations) do
      HasOffset:=HasOffset or (Abs(Profile.Stations[I].Offset)>0.0001);
    if HasOffset then begin
      Shared:=specialize TDictionary<Int64,Boolean>.Create;
      for Id in Way.NodeRefs do Shared.AddOrSetValue(Id,False);
      for Other in Dataset.Ways.Values do if Other<>Way then
        for Id in Other.NodeRefs do if Shared.ContainsKey(Id) then Shared[Id]:=True;
    end;
    Result.Way:=Way;SetLength(Result.Refs,Length(Points));SetLength(Result.Widths,Length(Points));J:=0;
    for I:=0 to High(Points) do begin
      AtM:=Points[I];while (J<N-2) and (AtM>Along[J+1]+0.001) do Inc(J);
      D:=Along[J+1]-Along[J];Need(D>0.001,'duplicate source positions');
      Alpha:=EnsureRange((AtM-Along[J])/D,0,1);
      LL:=TLatLon.Make(Positions[J].Lat+(Positions[J+1].Lat-Positions[J].Lat)*Alpha,
        Positions[J].Lon+(Positions[J+1].Lon-Positions[J].Lon)*Alpha);
      OriginalIndex:=-1;
      if Abs(AtM-Along[J])<0.001 then OriginalIndex:=J
      else if Abs(AtM-Along[J+1])<0.001 then OriginalIndex:=J+1;
      AtStation(AtM,W,Offset);Result.Widths[I]:=W;
      if (OriginalIndex>=0) and (Abs(Offset)<0.001) then begin
        Result.Refs[I]:=Way.NodeRefs[OriginalIndex];Continue;
      end;
      if OriginalIndex>=0 then begin
        Locked:=(OriginalIndex=0) or (OriginalIndex=N-1) or
          (Dataset.FindNode(Way.NodeRefs[OriginalIndex]).Tags.Count>0);
        if not Locked and (Shared<>nil) then Locked:=Shared[Way.NodeRefs[OriginalIndex]];
        Need(not Locked,'offset moves a shared/tagged node or endpoint; taper to zero there');
      end;
      E:=(Positions[J+1].Lon-Positions[J].Lon)*Cos(LL.Lat*Pi/180);Nth:=Positions[J+1].Lat-Positions[J].Lat;
      if (Abs(Offset)>0.001) and (OriginalIndex>0) and (OriginalIndex<N-1) then begin
        { Intersect the two parallel offset lines. Use unit directions so
          uneven OSM node spacing cannot tilt the offset into the road. }
        E1:=(Positions[OriginalIndex].Lon-Positions[OriginalIndex-1].Lon)*Cos(LL.Lat*Pi/180);
        N1:=Positions[OriginalIndex].Lat-Positions[OriginalIndex-1].Lat;
        E2:=(Positions[OriginalIndex+1].Lon-Positions[OriginalIndex].Lon)*Cos(LL.Lat*Pi/180);
        N2:=Positions[OriginalIndex+1].Lat-Positions[OriginalIndex].Lat;
        L1:=Hypot(E1,N1);L2:=Hypot(E2,N2);Need((L1>1e-12) and (L2>1e-12),'duplicate offset corner');
        E:=E1/L1+E2/L2;Nth:=N1/L1+N2/L2;Len:=Hypot(E,Nth);
        Need(Len>=1,'offset at a tight reversal requires explicit local geometry');
        Offset:=Offset*2/Len;
      end;
      Len:=Sqrt(E*E+Nth*Nth);Need(Len>1e-12,'ambiguous offset direction');
      LL.Lon+=Offset*Nth/Len/(111320*Cos(LL.Lat*Pi/180));LL.Lat-=Offset*E/Len/111320;
      Seed:=MD5Print(MD5String('photo-road-v1:'+IntToStr(Way.Id)+':'+IntToStr(Round(AtM*1000))));
      Id:=-StrToInt64('$'+Copy(Seed,1,15));Need(Dataset.FindNode(Id)=nil,'generated node identity collision');
      Node:=TOSMNode.Create(Id,LL);Result.Nodes.Add(Node);Result.Refs[I]:=Id;
    end;
  except Shared.Free;Result.Free;Result:=nil;raise end;
  Shared.Free;
end;
function PhotoRoadCapabilities:TJSONObject;
begin
  Result:=TJSONObject.Create(['version',1,'stations','2..64 increasing at_m along original OSM way, width_m, optional offset_m (positive right in OSM order)',
    'blend_m','2..100 m transition to original width and zero offset outside the observed range',
    'scope','open ground-level highway or separate footway; endpoints/shared/tagged nodes cannot move; no bridges/tunnels/areas',
    'ownership','same OSM way ID; centreline and widths compiled before all native geometry and movement data']);
end;
end.
