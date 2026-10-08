unit Osm3dKnowledgeOsm;
{$mode objfpc}{$H+}{$codepage UTF8}

{ The authoring context and the generator must fingerprint exactly the same
  original OSM data. Dataset is borrowed; this reader never mutates it. }
interface
uses Classes, SysUtils, fpjson, Generics.Collections, Osm3dGeoMath, Osm3dOsmData;
type
  TKnowledgeOsmReader = class
  private
    FDataset: TOSMDataset;
    FCancel: TThread;
    FSteps: Int64;
    FGeometryComplete: Boolean;
    FNodeUses: specialize TDictionary<Int64,Integer>;
    FBuildingOwners: specialize TDictionary<Int64,TOSMRelation>;
    procedure IndexNodeUses;
    procedure IndexBuildingOwners;
    procedure Step;
    function WayBounds(W: TOSMWay; out Geo: string): TLatLonBox;
    function RelationBounds(R: TOSMRelation; Depth: Integer; out Geo: string): TLatLonBox;
  public
    constructor Create(Dataset: TOSMDataset; Cancel: TThread = nil);
    destructor Destroy; override;
    function Tags(const Kind: string; Id: Int64): TOSMTags;
    function ObjectInfo(const Kind: string; Id: Int64; IncludeGeometry:Boolean=False): TJSONObject;
  end;
function KnowledgeBox(J: TJSONData): TLatLonBox;
function KnowledgeBoxesIntersect(const A,B: TLatLonBox): Boolean;
implementation
uses Math, MD5, Osm3dTileKnowledge;

function TagsJSON(Tags: TOSMTags): TJSONObject;
var I: Integer;
begin
  Result:=TJSONObject.Create;
  for I:=0 to Tags.Count-1 do Result.Add(Tags.Keys[I],Tags.Values[I]);
end;

function KnowledgeBox(J: TJSONData): TLatLonBox;
var A: TJSONArray; I: Integer; V: Double;
begin
  if (J=nil) or (J.JSONType<>jtArray) or (J.Count<>4) then
    raise ETileKnowledge.Create('Expected geographic bbox [west,south,east,north]');
  A:=TJSONArray(J);
  for I:=0 to 3 do begin
    if A.Items[I].JSONType<>jtNumber then raise ETileKnowledge.Create('bbox coordinates must be numeric');
    V:=A.Items[I].AsFloat;
    if IsNan(V) or IsInfinite(V) then raise ETileKnowledge.Create('bbox coordinates must be finite');
  end;
  if (A.Floats[0]>A.Floats[2]) or (A.Floats[1]>A.Floats[3]) then
    raise ETileKnowledge.Create('Inverted bbox');
  Result:=TLatLonBox.Make(A.Floats[1],A.Floats[0],A.Floats[3],A.Floats[2]);
end;

function KnowledgeBoxesIntersect(const A,B: TLatLonBox): Boolean;
begin
  Result:=not A.IsEmpty and not B.IsEmpty and
    (A.MaxLat>=B.MinLat) and (A.MinLat<=B.MaxLat) and
    (A.MaxLon>=B.MinLon) and (A.MinLon<=B.MaxLon);
end;

constructor TKnowledgeOsmReader.Create(Dataset: TOSMDataset; Cancel: TThread);
begin inherited Create; FDataset:=Dataset; FCancel:=Cancel end;

destructor TKnowledgeOsmReader.Destroy;
begin FBuildingOwners.Free;FNodeUses.Free; inherited end;

procedure TKnowledgeOsmReader.IndexBuildingOwners;
var R:TOSMRelation;M:TOSMRelationMember;
begin
  if FBuildingOwners<>nil then Exit;
  FBuildingOwners:=specialize TDictionary<Int64,TOSMRelation>.Create;
  for R in FDataset.Relations.Values do
    if R.Tags.HasKeyValue('type','multipolygon') and
      (R.Tags.HasKey('building') or R.Tags.HasKey('building:part')) then
    for M in R.Members do if (M.Kind=omkWay) and ((M.Role='') or SameText(M.Role,'outer')) then begin
      if FBuildingOwners.ContainsKey(M.Ref) then FBuildingOwners[M.Ref]:=nil
      else FBuildingOwners.Add(M.Ref,R);
    end;
end;

procedure TKnowledgeOsmReader.IndexNodeUses;
var W:TOSMWay; Id:Int64; N:Integer;
begin
  if FNodeUses<>nil then Exit;
  FNodeUses:=specialize TDictionary<Int64,Integer>.Create;
  for W in FDataset.Ways.Values do for Id in W.NodeRefs do begin
    Step; if not FNodeUses.TryGetValue(Id,N) then N:=0;
    FNodeUses.AddOrSetValue(Id,N+1);
  end;
end;

procedure TKnowledgeOsmReader.Step;
begin
  Inc(FSteps);
  if (FSteps and 1023)=0 then
    if (FCancel<>nil) and FCancel.CheckTerminated then raise EAbort.Create('cancelled');
  if FSteps>2000000 then raise ETileKnowledge.Create('OSM knowledge geometry budget exceeded');
end;

function TKnowledgeOsmReader.WayBounds(W: TOSMWay; out Geo: string): TLatLonBox;
var N: TOSMNode; RefId: Int64; S: TStringBuilder;
begin
  Result:=TLatLonBox.Empty; S:=TStringBuilder.Create;
  try
    for RefId in W.NodeRefs do begin
      Step; N:=FDataset.FindNode(RefId);
      S.Append(IntToStr(RefId)); S.Append(':');
      if N<>nil then begin
        Result:=Result.Include(N.Position); S.Append(IntToStr(N.LatE7)); S.Append(','); S.Append(IntToStr(N.LonE7));
      end else begin S.Append('?'); FGeometryComplete:=False end;
      S.Append(';');
    end;
    Geo:=S.ToString;
  finally S.Free end;
end;

function TKnowledgeOsmReader.RelationBounds(R: TOSMRelation; Depth: Integer; out Geo: string): TLatLonBox;
var M: TOSMRelationMember; W: TOSMWay; N: TOSMNode; Child: TOSMRelation;
  RB: TLatLonBox; Part: string; S: TStringBuilder; MemberTags: TOSMTags; J: TJSONObject;
begin
  Result:=TLatLonBox.Empty; Geo:=''; if Depth>8 then begin FGeometryComplete:=False; Exit end;
  S:=TStringBuilder.Create;
  try
    for M in R.Members do begin
      Step; RB:=TLatLonBox.Empty; Part:='?'; MemberTags:=nil;
      case M.Kind of
        omkNode: begin N:=FDataset.FindNode(M.Ref); if N<>nil then begin
          MemberTags:=N.Tags; RB:=RB.Include(N.Position); Part:=IntToStr(N.LatE7)+','+IntToStr(N.LonE7) end else FGeometryComplete:=False end;
        omkWay: begin W:=FDataset.FindWay(M.Ref); if W<>nil then begin
          MemberTags:=W.Tags; RB:=WayBounds(W,Part) end else FGeometryComplete:=False end;
        omkRelation: begin Child:=FDataset.FindRelation(M.Ref);
          if (Child<>nil) and (Child<>R) then begin
            MemberTags:=Child.Tags; RB:=RelationBounds(Child,Depth+1,Part) end else FGeometryComplete:=False end;
      end;
      { Member tags affect generator ownership: an outer way acquiring its
        own building tag must invalidate an accepted relation recipe. }
      if MemberTags<>nil then begin
        J:=TagsJSON(MemberTags);
        try Part:=Part+#10+J.AsJSON finally J.Free end;
      end;
      if not RB.IsEmpty then Result:=Result.Union(RB);
      S.Append(IntToStr(Ord(M.Kind))+'/'+IntToStr(M.Ref)+':'+M.Role+':'+MD5Print(MD5String(Part))+';');
    end;
    Geo:=S.ToString;
  finally S.Free end;
end;

function TKnowledgeOsmReader.Tags(const Kind: string; Id: Int64): TOSMTags;
var N: TOSMNode; W: TOSMWay; R: TOSMRelation;
begin
  Result:=nil;
  if Kind='node' then begin N:=FDataset.FindNode(Id); if N<>nil then Result:=N.Tags end
  else if Kind='way' then begin W:=FDataset.FindWay(Id); if W<>nil then Result:=W.Tags end
  else if Kind='relation' then begin R:=FDataset.FindRelation(Id); if R<>nil then Result:=R.Tags end;
end;

function TKnowledgeOsmReader.ObjectInfo(const Kind: string; Id: Int64; IncludeGeometry:Boolean): TJSONObject;
var T,A: TJSONObject; ObjTags: TOSMTags; B: TLatLonBox; N: TOSMNode;
  I: Integer; Geo,StableId,Category: string; Outline,Owners:TJSONArray; W:TOSMWay; RefId:Int64;
  Rel,BuildingOwner:TOSMRelation; Member:TOSMRelationMember; Locked:TJSONArray; UsesCount:Integer;
begin
  Result:=nil; Step; FGeometryComplete:=True; ObjTags:=Tags(Kind,Id); if ObjTags=nil then Exit;
  if Kind='node' then begin
    N:=FDataset.FindNode(Id); B:=TLatLonBox.Empty.Include(N.Position);
    Geo:=IntToStr(N.LatE7)+','+IntToStr(N.LonE7);
  end else if Kind='way' then B:=WayBounds(FDataset.FindWay(Id),Geo)
  else B:=RelationBounds(FDataset.FindRelation(Id),0,Geo);
  if B.IsEmpty then Exit;
  T:=TagsJSON(ObjTags); A:=TJSONObject.Create;
  for I:=0 to ObjTags.Count-1 do begin
    if Copy(ObjTags.Keys[I],1,5)='addr:' then A.Add(ObjTags.Keys[I],ObjTags.Values[I]);
  end;
  Category:='other';
  if ObjTags.HasKey('building') or ObjTags.HasKey('building:part') then Category:='building'
  else if ObjTags.HasKey('highway') then Category:='road'
  else if (ObjTags.Get('natural')='tree') or (ObjTags.Get('natural')='tree_row') or
    (ObjTags.Get('natural')='shrub') or (ObjTags.Get('natural')='scrub') or
    (ObjTags.Get('natural')='wood') or (ObjTags.Get('natural')='grassland') or
    (ObjTags.Get('landuse')='grass') or (ObjTags.Get('landuse')='meadow') or
    ObjTags.HasKey('genus') or ObjTags.HasKey('species') or (ObjTags.Get('landuse')='forest') then Category:='vegetation'
  else if ObjTags.HasKey('waterway') or (ObjTags.Get('natural')='water') then Category:='water'
  else if ObjTags.HasKey('barrier') then Category:='fence';
  BuildingOwner:=nil;
  if (Kind='way') and (Category='other') and FDataset.FindWay(Id).IsClosed then begin
    IndexBuildingOwners;
    if FBuildingOwners.TryGetValue(Id,BuildingOwner) and (BuildingOwner<>nil) then begin
      Category:='building';
      Geo+=#10+'outer-of:'+IntToStr(BuildingOwner.Id)+#10+BuildingOwner.Tags.ToString;
      { Parent properties are the native defaults for this ring; own tags win. }
      for I:=0 to BuildingOwner.Tags.Count-1 do
        if T.Find(BuildingOwner.Tags.Keys[I])=nil then T.Add(BuildingOwner.Tags.Keys[I],BuildingOwner.Tags.Values[I]);
    end;
  end;
  StableId:=Kind+'/'+IntToStr(Id);
  Result:=TJSONObject.Create(['id',StableId,'type',Kind,'osm_id',IntToStr(Id),
    'category',Category,'tags',T,'address',A,
    'bbox',TJSONArray.Create([B.MinLon,B.MinLat,B.MaxLon,B.MaxLat]),
    'latitude',B.Center.Lat,'longitude',B.Center.Lon,
    'fingerprint',MD5Print(MD5String(StableId+#10+T.AsJSON+#10+Geo))]);
  Result.Add('geometry_complete',FGeometryComplete);
  if BuildingOwner<>nil then Result.Add('component_of','relation/'+IntToStr(BuildingOwner.Id));
  if IncludeGeometry and (Kind='relation') then begin
    Owners:=TJSONArray.Create;Result.Add('members',Owners);Rel:=FDataset.FindRelation(Id);
    for Member in Rel.Members do begin
      case Member.Kind of
        omkNode:StableId:='node';omkWay:StableId:='way';omkRelation:StableId:='relation';
      end;
      Owners.Add(TJSONObject.Create(['type',StableId,'id',IntToStr(Member.Ref),'role',Member.Role]));
    end;
  end;
  if Kind='way' then Result.Add('closed',FDataset.FindWay(Id).IsClosed);
  if IncludeGeometry and (Kind='way') then begin
    Outline:=TJSONArray.Create;Result.Add('outline',Outline);W:=FDataset.FindWay(Id);
    for RefId in W.NodeRefs do begin
      N:=FDataset.FindNode(RefId);
      if N<>nil then Outline.Add(TJSONArray.Create([N.Position.Lon,N.Position.Lat]));
    end;
    if Category='road' then begin
      IndexNodeUses; Locked:=TJSONArray.Create;Result.Add('locked_node_indices',Locked);
      for I:=0 to High(W.NodeRefs) do begin
        N:=FDataset.FindNode(W.NodeRefs[I]);
        if not FNodeUses.TryGetValue(W.NodeRefs[I],UsesCount) then UsesCount:=0;
        if (I=0) or (I=High(W.NodeRefs)) or (UsesCount>1) or
          ((N<>nil) and (N.Tags.Count>0)) then Locked.Add(I);
      end;
    end;
    if Category='vegetation' then begin
      Owners:=TJSONArray.Create;Result.Add('vegetation_relations',Owners);
      for Rel in FDataset.Relations.Values do
        if Rel.Tags.HasKeyValue('type','multipolygon') and
          (Rel.Tags.HasKeyValue('natural','wood') or Rel.Tags.HasKeyValue('natural','scrub') or
           Rel.Tags.HasKeyValue('landuse','forest')) then
          for Member in Rel.Members do if (Member.Kind=omkWay) and (Member.Ref=Id) then begin
            Owners.Add(IntToStr(Rel.Id));Break;
          end;
    end;
  end;
end;
end.
