unit Osm3dBuildingParts;
{$mode objfpc}{$H+}
{ Select either a complete OSM building outline or its complete partition.
  Never emit both. Shared node edges prove coverage, rather than a bbox or a
  centre-point guess that can erase courtyards or neighbouring wings. }
interface
uses Classes,SysUtils,Osm3dOsmData;
type
  TBuildingPartSelection=class
  private
    FHidden,FParts,FBlocked:TStringList;
  public
    constructor Create(Dataset:TOSMDataset);
    destructor Destroy;override;
    function Hidden(const Kind:string;Id:Int64):Boolean;
    function PartVisible(const Kind:string;Id:Int64):Boolean;
    procedure ValidatePhotoParts(Dataset:TOSMDataset);
  end;
implementation
uses Math,Osm3dGeoMath,Osm3dGeomUtils;
type
  TPartFootprint=record
    Key:string;
    Part,Valid,HasParent,Selected:Boolean;
    Chains:TInt64ArrayArray;
    OuterCount:Integer;
    Box:TLatLonBox;
    Area:Double;
  end;
  TFootprints=array of TPartFootprint;

function PartTag(Tags:TOSMTags):Boolean;
begin Result:=Tags.HasKey('building:part') and (Tags.GetLower('building:part')<>'no') end;
function Key(const Kind:string;Id:Int64):string;
begin Result:=Kind+'/'+IntToStr(Id) end;
function NewSet:TStringList;
begin Result:=TStringList.Create;Result.Sorted:=True;Result.Duplicates:=dupIgnore end;
function EdgeKey(A,B:Int64):string;
var T:Int64;
begin if A>B then begin T:=A;A:=B;B:=T end;Result:=IntToStr(A)+':'+IntToStr(B) end;
procedure AddEdges(const E:TPartFootprint;Edges:TStringList);
var C,I:Integer;
begin
  for C:=0 to High(E.Chains) do for I:=1 to High(E.Chains[C]) do
    Edges.Add(EdgeKey(E.Chains[C][I-1],E.Chains[C][I]));
end;

constructor TBuildingPartSelection.Create(Dataset:TOSMDataset);
var E:TFootprints;W:TOSMWay;R:TOSMRelation;N:TOSMNode;
  I,J,K,C,A,B,Count:Integer;Candidate:array of Integer;TotalArea:Double;
  ParentEdges,PartEdges:TStringList;Valid:Boolean;
  procedure Append(const Id:string;IsPart:Boolean;const Outers,Inners:TInt64ArrayArray;Complete:Boolean);
  var F:TPartFootprint;Q,H:Integer;P,Prev,Origin:TLatLon;SignedArea:Double;
  begin
    F:=Default(TPartFootprint);F.Key:=Id;F.Part:=IsPart;
    F.Valid:=Complete and (Length(Outers)>0);F.Box:=TLatLonBox.Empty;
    F.OuterCount:=Length(Outers);F.Chains:=Copy(Outers);
    SetLength(F.Chains,Length(Outers)+Length(Inners));
    for Q:=0 to High(Inners) do F.Chains[Length(Outers)+Q]:=Inners[Q];
    for Q:=0 to High(F.Chains) do begin
      if (Length(F.Chains[Q])<4) or (F.Chains[Q][0]<>F.Chains[Q][High(F.Chains[Q])]) then begin F.Valid:=False;Continue end;
      SignedArea:=0;Origin:=Default(TLatLon);Prev:=Origin;
      for H:=0 to High(F.Chains[Q]) do begin
        N:=Dataset.FindNode(F.Chains[Q][H]);
        if N=nil then begin F.Valid:=False;Continue end;
        P:=N.Position;F.Box:=F.Box.Include(P);
        if H=0 then Origin:=P else
          SignedArea+=(Prev.Lon-Origin.Lon)*(P.Lat-Origin.Lat)-(P.Lon-Origin.Lon)*(Prev.Lat-Origin.Lat);
        Prev:=P;
      end;
      if Q<F.OuterCount then F.Area+=Abs(SignedArea)*0.5 else F.Area-=Abs(SignedArea)*0.5;
    end;
    F.Valid:=F.Valid and (F.Area>1e-14);
    Q:=Length(E);SetLength(E,Q+1);E[Q]:=F;
  end;
  procedure AddWay(Way:TOSMWay);
  var Chains:TInt64ArrayArray;
  begin
    SetLength(Chains,1);Chains[0]:=ExtractNodeRefs(Way);
    Append(Key('way',Way.Id),PartTag(Way.Tags),Chains,nil,True);
  end;
  procedure AddRelation(Rel:TOSMRelation);
  var Outers,Inners:TOSMWayArray;Q,H:Integer;Member:TOSMWay;Role:string;Complete:Boolean;
  begin
    Outers:=nil;Inners:=nil;Complete:=True;
    for Q:=0 to Rel.MemberCount-1 do begin
      Role:=LowerCase(Rel.Members[Q].Role);
      if (Role<>'outer') and (Role<>'inner') and (Role<>'') then Continue;
      if Rel.Members[Q].Kind<>omkWay then begin Complete:=False;Continue end;
      Member:=Dataset.FindWay(Rel.Members[Q].Ref);
      if (Member=nil) or (Length(Member.NodeRefs)<2) then begin Complete:=False;Continue end;
      if Role='inner' then begin H:=Length(Inners);SetLength(Inners,H+1);Inners[H]:=Member end
      else begin H:=Length(Outers);SetLength(Outers,H+1);Outers[H]:=Member end;
    end;
    Append(Key('relation',Rel.Id),PartTag(Rel.Tags),StitchWaysIntoRingChains(Outers),StitchWaysIntoRingChains(Inners),Complete);
  end;
  function ContainsBox(const Parent,Part:TPartFootprint):Boolean;
  begin
    Result:=(Part.Box.MinLon>=Parent.Box.MinLon-1e-10) and (Part.Box.MaxLon<=Parent.Box.MaxLon+1e-10) and
      (Part.Box.MinLat>=Parent.Box.MinLat-1e-10) and (Part.Box.MaxLat<=Parent.Box.MaxLat+1e-10);
  end;
  function InRing(const P:TLatLon;const Chain:TInt64Array):Integer;
  var Q:Integer;U,V:TLatLon;DX,DY,CrossProduct:Double;Inside:Boolean;
  begin
    Inside:=False;
    for Q:=1 to High(Chain) do begin
      U:=Dataset.FindNode(Chain[Q-1]).Position;V:=Dataset.FindNode(Chain[Q]).Position;
      DX:=V.Lon-U.Lon;DY:=V.Lat-U.Lat;
      CrossProduct:=(P.Lon-U.Lon)*DY-(P.Lat-U.Lat)*DX;
      if (Abs(CrossProduct)<=1e-16) and (P.Lon>=Min(U.Lon,V.Lon)-1e-10) and
        (P.Lon<=Max(U.Lon,V.Lon)+1e-10) and (P.Lat>=Min(U.Lat,V.Lat)-1e-10) and
        (P.Lat<=Max(U.Lat,V.Lat)+1e-10) then Exit(0);
      if (U.Lat>P.Lat)<>(V.Lat>P.Lat) then
        if P.Lon<(V.Lon-U.Lon)*(P.Lat-U.Lat)/(V.Lat-U.Lat)+U.Lon then Inside:=not Inside;
    end;
    if Inside then Result:=1 else Result:=-1;
  end;
  function InsideParent(const P:TLatLon;const Parent:TPartFootprint):Boolean;
  var Q:Integer;
  begin
    Result:=False;
    for Q:=0 to Parent.OuterCount-1 do if InRing(P,Parent.Chains[Q])>=0 then begin Result:=True;Break end;
    if not Result then Exit;
    for Q:=Parent.OuterCount to High(Parent.Chains) do if InRing(P,Parent.Chains[Q])>0 then Exit(False);
  end;
  function TouchesInterior(const Parent,Part:TPartFootprint):Boolean;
  var Q,H:Integer;U,V:TLatLon;
  begin
    Result:=False;
    if (Part.Box.MaxLon<Parent.Box.MinLon) or (Part.Box.MinLon>Parent.Box.MaxLon) or
      (Part.Box.MaxLat<Parent.Box.MinLat) or (Part.Box.MinLat>Parent.Box.MaxLat) then Exit;
    for Q:=0 to Part.OuterCount-1 do for H:=1 to High(Part.Chains[Q]) do begin
      U:=Dataset.FindNode(Part.Chains[Q][H-1]).Position;V:=Dataset.FindNode(Part.Chains[Q][H]).Position;
      if InsideParent(U,Parent) or InsideParent(TLatLon.Make((U.Lat+V.Lat)*0.5,(U.Lon+V.Lon)*0.5),Parent) then Exit(True);
    end;
  end;
begin
  inherited Create;FHidden:=NewSet;FParts:=NewSet;FBlocked:=NewSet;
  { No work beyond the tag scan for the overwhelmingly common part-free tile. }
  Valid:=False;
  for W in Dataset.Ways.Values do if PartTag(W.Tags) then begin Valid:=True;Break end;
  if not Valid then for R in Dataset.Relations.Values do if PartTag(R.Tags) then begin Valid:=True;Break end;
  if not Valid then Exit;
  E:=nil;
  for W in Dataset.Ways.Values do if W.IsClosed and (W.Tags.HasKey('building') or PartTag(W.Tags)) then AddWay(W);
  for R in Dataset.Relations.Values do
    if (R.Tags.GetLower('type')='multipolygon') and (R.Tags.HasKey('building') or PartTag(R.Tags)) then AddRelation(R);
  ParentEdges:=TStringList.Create;PartEdges:=TStringList.Create;
  try
    for I:=0 to High(E) do if not E[I].Part and E[I].Valid then begin
      Candidate:=nil;TotalArea:=0;
      for J:=0 to High(E) do if E[J].Part and E[J].Valid and TouchesInterior(E[I],E[J]) then begin
        { A candidate is not accepted on this coarse test: both exact boundary
          coverage AND additive area below must prove a complete partition. }
        E[J].HasParent:=True;
        if not ContainsBox(E[I],E[J]) then Continue;
        K:=Length(Candidate);SetLength(Candidate,K+1);Candidate[K]:=J;TotalArea+=E[J].Area;
      end;
      if (Length(Candidate)=0) or (Abs(TotalArea-E[I].Area)>Max(1e-14,E[I].Area*1e-7)) then Continue;
      ParentEdges.Clear;PartEdges.Clear;AddEdges(E[I],ParentEdges);
      for J in Candidate do AddEdges(E[J],PartEdges);
      ParentEdges.Sort;PartEdges.Sort;A:=0;B:=0;Valid:=True;
      while B<PartEdges.Count do begin
        C:=B;while (B<PartEdges.Count) and (PartEdges[B]=PartEdges[C]) do Inc(B);Count:=B-C;
        if (A<ParentEdges.Count) and (ParentEdges[A]=PartEdges[C]) then begin
          if Count<>1 then begin Valid:=False;Break end;Inc(A);
        end else if Count<>2 then begin Valid:=False;Break end;
      end;
      if not Valid or (A<>ParentEdges.Count) then Continue;
      FHidden.Add(E[I].Key);for J in Candidate do E[J].Selected:=True;
    end;
    for I:=0 to High(E) do if E[I].Part then begin
      if E[I].Valid and (E[I].Selected or not E[I].HasParent) then FParts.Add(E[I].Key)
      else begin FBlocked.Add(E[I].Key);FHidden.Add(E[I].Key) end;
    end;
  finally PartEdges.Free;ParentEdges.Free end;
end;
destructor TBuildingPartSelection.Destroy;
begin FBlocked.Free;FParts.Free;FHidden.Free;inherited end;
function TBuildingPartSelection.Hidden(const Kind:string;Id:Int64):Boolean;
begin Result:=FHidden.IndexOf(Key(Kind,Id))>=0 end;
function TBuildingPartSelection.PartVisible(const Kind:string;Id:Int64):Boolean;
begin Result:=FParts.IndexOf(Key(Kind,Id))>=0 end;
procedure TBuildingPartSelection.ValidatePhotoParts(Dataset:TOSMDataset);
var W:TOSMWay;R:TOSMRelation;
  procedure Check(Tags:TOSMTags;const Id:string);
  begin
    if Tags.HasKey('rezvivo:photo_building') and (FBlocked.IndexOf(Id)>=0) then
      raise Exception.Create(Id+': building parts do not form a complete, non-overlapping partition of the parent outline; retain the parent and resolve missing/overlapping parts before applying this photo');
  end;
begin
  for W in Dataset.Ways.Values do Check(W.Tags,Key('way',W.Id));
  for R in Dataset.Relations.Values do Check(R.Tags,Key('relation',R.Id));
end;
end.
