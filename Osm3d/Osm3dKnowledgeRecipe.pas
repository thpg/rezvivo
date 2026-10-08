unit Osm3dKnowledgeRecipe;
{$mode objfpc}{$H+}{$codepage UTF8}

{ Accepted evidence -> bounded procedural inputs -> the existing generator.
  A scene owns an immutable snapshot. Publication only affects later loads. }
interface
uses Classes, SysUtils, fpjson, Generics.Collections, Osm3dGeoMath,
  Osm3dGeoTileGrid, Osm3dOsmData, Osm3dTileX3D;
type
  TPhotoTileCoverage = record
    Buildings, Roads, Plants, Details: Integer;
  end;
  TKnowledgeRecipeSnapshot = class
  private
    FTargets: TStringList;
    FTileHashes: specialize TDictionary<Int64,string>;
    FCoverage: specialize TDictionary<Int64,TPhotoTileCoverage>;
    FHash: string;
    FWorkflow:TJSONObject;
    procedure LoadCatalog(Catalog: TJSONObject; Grid: TGeoTileGrid);
  public
    constructor Create(const CacheRoot: string; Grid: TGeoTileGrid);
    constructor FromCatalog(Catalog: TJSONObject; Grid: TGeoTileGrid);
    destructor Destroy; override;
    function TileHash(const Tile: TGeoTileId): string;
    function TileCoverage(const Tile:TGeoTileId):TPhotoTileCoverage;
    function TileWorkflow(const Tile:TGeoTileId):TJSONObject; { borrowed snapshot }
    function BlockHash(const NW: TGeoTileId; Size: Integer): string;
    procedure Apply(Dataset: TOSMDataset; const Box: TLatLonBox);
    procedure BakeFacades(Model:TTileModel; ScaleLat:Double);
    property ContentHash: string read FHash;
  end;
function KnowledgeRecipeCapabilities: TJSONObject;
function CompileKnowledgeRecipe(const CacheRoot: string; Request: TJSONObject;
  Cancel: TThread = nil): TJSONObject;
function ReadActiveKnowledgeRecipe(const CacheRoot:string;Tile:TJSONObject):TJSONObject;
function AuditKnowledgeEvidence(const CacheRoot:string;Request:TJSONObject;
  Cancel:TThread=nil):TJSONObject;
function ReviewKnowledgePhoto(const CacheRoot:string;Request:TJSONObject;
  Cancel:TThread=nil):TJSONObject;
implementation
uses Math, MD5, Osm3dTileKnowledge, Osm3dKnowledgeContext, Osm3dKnowledgeOsm,
  Osm3dPhotoSources, Osm3dFacadeLayout, Osm3dSceneMaterials, Osm3dBuildingMassing, Osm3dArchitecture, Osm3dCompoundRoof,
  Osm3dKnowledgeEvidence,Osm3dPhotoApi,Osm3dCache,Osm3dKnowledgeProperties,
  Osm3dVegetationLayout,Osm3dPhotoRoadProfile,Osm3dGeomRoads,CastleVectors,Osm3dEnvironmentLayout,Osm3dPhotoPipeline,Osm3dBuildingParts;
const RecipeVersion = 1;
  CatalogMaxBytes = 16*1024*1024;

function Digest(const S: string): string;
begin Result:=MD5Print(MD5String(S)) end;

function Invariant: TFormatSettings;
begin Result:=DefaultFormatSettings; Result.DecimalSeparator:='.' end;

function SortedList: TStringList;
begin
  Result:=TStringList.Create; Result.CaseSensitive:=True;
  Result.Sorted:=True; Result.Duplicates:=dupError;
end;

function SortedJson(J: TJSONObject): TJSONObject;
var L: TStringList; I: Integer;
begin
  Result:=TJSONObject.Create; L:=SortedList;
  try
    for I:=0 to J.Count-1 do L.Add(J.Names[I]);
    for I:=0 to L.Count-1 do Result.Add(L[I],J.Find(L[I]).Clone);
  finally L.Free end;
end;

function AsObject(J: TJSONData; const Name: string): TJSONObject;
begin
  if (J=nil) or (J.JSONType<>jtObject) then raise ETileKnowledge.Create(Name+' must be an object');
  Result:=TJSONObject(J);
end;

function AsArray(J: TJSONData; const Name: string): TJSONArray;
begin
  if (J=nil) or (J.JSONType<>jtArray) then raise ETileKnowledge.Create(Name+' must be an array');
  Result:=TJSONArray(J);
end;

function PropertyIndex(const Name: string): Integer;
begin
  Result:=KnowledgePropertyIndex(Name);
  if Result<0 then raise ETileKnowledge.Create('Unsupported accepted property: '+Name+'; see knowledge.capabilities');
end;

function CanonicalValue(Index: Integer; Value: TJSONData; const UnitName: string): string;
begin
  if KnowledgeProperties[Index].Kind<>kvObject then Exit(CanonicalKnowledgeScalar(Index,Value,UnitName));
  if UnitName<>'' then raise ETileKnowledge.Create(KnowledgeProperties[Index].Name+' has no unit');
  case Index of
    7: Result:=CanonicalFacadeLayout(Value);
    8: Result:=CanonicalBuildingMassing(Value);
    9: Result:=CanonicalArchitecture(Value);
    10: Result:=CanonicalCompoundRoof(Value);
    23: Result:=CanonicalVegetationLayout(Value);
    24,25: Result:=CanonicalPhotoRoadProfile(Value,Index=25);
    26..30: Result:=CanonicalEnvironmentLayout(Value,KnowledgeProperties[Index].Category);
    else raise ETileKnowledge.Create('Unsupported structured property');
  end;
end;

function KnowledgeRecipeCapabilities: TJSONObject;
var A: TJSONArray; I: Integer; P: TJSONObject;
begin
  A:=TJSONArray.Create;
  Result:=TJSONObject.Create(['recipe_version',RecipeVersion,'properties',A,
    'targets','building ways/multipolygons; highway ways; separate sidewalk ways; tagged tree/shrub nodes and forest/scrub areas',
    'policy','accepted + confirmed binding + matching OSM fingerprint; existing conflicting OSM requires manual_override',
    'activation','explicit activate=true; immutable scene snapshot; reload the map to apply',
    'limits','2 MiB knowledge, 16 MiB active catalog, 8192 objects, 256 affected tiles per object',
    'network_requests',0]);
  for I:=Low(KnowledgeProperties) to High(KnowledgeProperties) do begin
    P:=TJSONObject.Create(['property',KnowledgeProperties[I].Name,'osm_tag',KnowledgeProperties[I].TagName,
      'category',KnowledgeProperties[I].Category]); A.Add(P);
    if I>10 then begin
      P.Add('unit',KnowledgeProperties[I].UnitName);
      if KnowledgeProperties[I].Values<>'' then P.Add('values',KnowledgeProperties[I].Values);
      if KnowledgeProperties[I].Kind in [kvNumber,kvInteger] then begin
        P.Add('min',KnowledgeProperties[I].MinValue);P.Add('max',KnowledgeProperties[I].MaxValue);
      end;
    end;
    if I in [0,2,4] then P.Add('unit','m');
    if I=1 then P.Add('unit','storeys');
    if I=3 then P.Add('values',KnowledgeProperties[I].Values);
    if I=5 then P.Add('values',KnowledgeProperties[I].Values);
    if I=6 then P.Add('note','#RRGGBB wall tint independent of material; preserves windows, normals and roughness');
    if I=9 then P.Add('library',ArchitectureCapabilities);
    if I=10 then P.Add('library',CompoundRoofCapabilities);
    if I=23 then P.Add('library',VegetationLayoutCapabilities);
    if I in [24,25] then P.Add('library',PhotoRoadCapabilities);
    if I in [26..30] then P.Add('library',EnvironmentLayoutCapabilities);
    if I=8 then P.Add('note','version=1, type=colonnade, front_start/end [lon,lat], columns 1..24 per row, rows 1..2, pier_width_m 1..20, column_radius_m .2..2.5, opening_height_m 3..40, tower_height_m 0..3; fits a rectangular OSM footprint and height, otherwise retains OSM envelope. Baked geometry; separate pier/column obstacles, open passage ground preserved.');
    if I=7 then P.Add('note','version=1; facades: directed start/end [lon,lat], bays [{width_m, floor_shift, balcony_floors}], cornice_floors, balcony_depth_m, balcony_width; outward normal = edge cross up; floor 0 is ground; whole straight exterior edges only; repeated unseen bays must be labelled inferred');
  end;
end;

function CatalogPath(const CacheRoot: string): string;
var Store: TTileKnowledgeStore;
begin
  Store:=TTileKnowledgeStore.Create(CacheRoot);
  try Result:=Store.Root+'active-recipes-v1.json' finally Store.Free end;
end;

function ReadCatalog(const Path: string): TJSONObject;
var F: TFileStream; S: RawByteString; J: TJSONData;
begin
  if not FileExists(Path) then Exit(TJSONObject.Create(['schema_version',RecipeVersion,'tiles',TJSONObject.Create]));
  F:=TFileStream.Create(Path,fmOpenRead or fmShareDenyNone);
  try
    if F.Size>CatalogMaxBytes then raise ETileKnowledge.Create('Active recipe catalog exceeds 16 MiB');
    SetLength(S,F.Size); if S<>'' then F.ReadBuffer(S[1],Length(S));
  finally F.Free end;
  J:=ParsePhotoJson(S);
  try
    Result:=AsObject(J,'Recipe catalog');
    if Result.Get('schema_version',0)<>RecipeVersion then raise ETileKnowledge.Create('Unsupported recipe catalog version');
    AsObject(Result.Find('tiles'),'Recipe tiles');
  except J.Free; raise end;
end;

function TileKey(Tile: TJSONObject): string;
begin
  Result:=Format('real/z%d/e%d/%d/%d',[Tile.Get('zoom',0),Tile.Get('edge_px',0),Tile.Get('x',0),Tile.Get('y',0)]);
end;

procedure SplitId(const S: string; out Kind: string; out Id: Int64);
var P: Integer; Tail: string;
begin
  P:=Pos('/',S); Kind:=Copy(S,1,P-1); Tail:=Copy(S,P+1,MaxInt);
  if not ((Kind='node') or (Kind='way') or (Kind='relation')) or not TryStrToInt64(Tail,Id) or
    (Id<=0) or (IntToStr(Id)<>Tail) then raise ETileKnowledge.Create('Invalid OSM target: '+S);
end;

function IsLocalTarget(T:TJSONObject):Boolean;
begin Result:=Copy(T.Get('id',''),1,6)='local:' end;
function AnchorId(T:TJSONObject):string;
begin if IsLocalTarget(T) then Result:=T.Get('anchor_id','') else Result:=T.Get('id','') end;
function PlantBoundaryBox(const Text:string):TLatLonBox;
var Boundary:TPhotoPlantBoundary;I:Integer;
begin
  Boundary:=VegetationLayoutBoundary(Text);Result:=TLatLonBox.Empty;
  for I:=0 to High(Boundary) do Result:=Result.Include(Boundary[I]);
  if Result.IsEmpty then raise ETileKnowledge.Create('Local plants require an explicit boundary');
end;

procedure ValidateTarget(T: TJSONObject);
var Kind,Hash,S,Canonical,Category: string; Id: Int64; I,K: Integer; Tags: TJSONObject;
  J: TJSONData; B,LocalBox: TLatLonBox; V: Double;
begin
  SplitId(AnchorId(T),Kind,Id); Hash:=T.Get('fingerprint','');
  Category:=T.Get('category','building');
  if Length(Hash)<>32 then raise ETileKnowledge.Create('Expected original OSM fingerprint');
  for I:=1 to Length(Hash) do if not (Hash[I] in ['0'..'9','a'..'f']) then
    raise ETileKnowledge.Create('Invalid original OSM fingerprint');
  B:=KnowledgeBox(T.Find('bbox'));
  if B.IsEmpty or (B.MinLat < -85.051129) or (B.MaxLat > 85.051129) or
    (B.MinLon < -180) or (B.MaxLon > 180) then raise ETileKnowledge.Create('Invalid recipe bbox');
  Tags:=AsObject(T.Find('set_tags'),'set_tags');
  if IsLocalTarget(T) then begin
    S:=T.Get('id','');
    if (Length(S)>200) or (Length(S)<=6) or (Tags.Count<>1) or
      ((Tags.Find(VEGETATION_LAYOUT_TAG)=nil) and (Tags.Find(ENVIRONMENT_LAYOUT_TAG)=nil)) then
      raise ETileKnowledge.Create('Local recipes require a single bounded vegetation/environment layout');
    for I:=7 to Length(S) do if not (S[I] in ['a'..'z','A'..'Z','0'..'9',':','-','_','.']) then
      raise ETileKnowledge.Create('Invalid stable local object id');
    if Tags.Find(ENVIRONMENT_LAYOUT_TAG)<>nil then LocalBox:=EnvironmentLayoutBox(Tags.Get(ENVIRONMENT_LAYOUT_TAG,''))
    else LocalBox:=PlantBoundaryBox(Tags.Get(VEGETATION_LAYOUT_TAG,''));
    if (Abs(LocalBox.MinLat-B.MinLat)>1e-10) or (Abs(LocalBox.MaxLat-B.MaxLat)>1e-10) or
      (Abs(LocalBox.MinLon-B.MinLon)>1e-10) or (Abs(LocalBox.MaxLon-B.MaxLon)>1e-10) then
      raise ETileKnowledge.Create('Local recipe bbox must match its planting boundary');
  end;
  if (Tags.Count=0) or (Tags.Count>Length(KnowledgeProperties)) then raise ETileKnowledge.Create('Invalid recipe tag count');
  for I:=0 to Tags.Count-1 do begin
    K:=KnowledgeTagIndex(Tags.Names[I],Category);
    if K<0 then raise ETileKnowledge.Create('Unsupported recipe tag '+Tags.Names[I]);
    if Tags.Items[I].JSONType<>jtString then raise ETileKnowledge.Create('Recipe tag must be a string');
    S:=Tags.Items[I].AsString;
    if KnowledgeProperties[K].Kind in [kvNumber,kvInteger] then begin
      if not TryStrToFloat(S,V,Invariant) then raise ETileKnowledge.Create('Invalid numeric recipe tag');
      J:=TJSONFloatNumber.Create(V);
    end else if KnowledgeProperties[K].Kind=kvObject then J:=ParsePhotoJson(S)
    else J:=TJSONString.Create(S);
    try
      Canonical:=CanonicalValue(K,J,KnowledgeProperties[K].UnitName);
      if S<>Canonical then raise ETileKnowledge.Create('Noncanonical recipe value');
    finally J.Free end;
  end;
  if (Tags.Find(ARCHITECTURE_TAG)<>nil) and
    ((Tags.Find(FACADE_LAYOUT_TAG)<>nil) or (Tags.Find(BUILDING_MASSING_TAG)<>nil)) then
    raise ETileKnowledge.Create('building.architecture replaces facade.layout/building.massing for this target; remove the older property to avoid duplicate geometry');
  if (Tags.Find(COMPOUND_ROOF_TAG)<>nil) and (Tags.Find(BUILDING_MASSING_TAG)<>nil) then
    raise ETileKnowledge.Create('roof.layout cannot be combined with building.massing, which replaces the complete envelope');
end;

function ReadActiveKnowledgeRecipe(const CacheRoot:string;Tile:TJSONObject):TJSONObject;
var Catalog,Entries:TJSONObject;Entry:TJSONData;
begin
  Result:=nil;Catalog:=ReadCatalog(CatalogPath(CacheRoot));
  try
    Entries:=AsObject(Catalog.Find('tiles'),'tiles');Entry:=Entries.Find(TileKey(Tile));
    if Entry is TJSONObject then Result:=TJSONObject(Entry.Clone);
  finally Catalog.Free end;
end;

function AuditKnowledgeEvidence(const CacheRoot:string;Request:TJSONObject;Cancel:TThread):TJSONObject;
var Store:TTileKnowledgeStore;ReadBack,Doc,Catalog,Recipe,Tile:TJSONObject;
  Client:TPhotoApiClient;Grid:TGeoTileGrid;T:TGeoTileId;
begin
  Store:=TTileKnowledgeStore.Create(CacheRoot);ReadBack:=nil;Catalog:=nil;Recipe:=nil;Client:=nil;Grid:=nil;
  try
    if (Cancel<>nil) and Cancel.CheckTerminated then raise EAbort.Create('cancelled');
    ReadBack:=Store.Read(Request,Request.Get('zoom',13),Request.Get('edge_px',256));
    Doc:=TJSONObject(ReadBack.Find('document'));Tile:=TJSONObject(Doc.Find('tile'));
    Grid:=TGeoTileGrid.Create(Tile.Get('zoom',13),Tile.Get('edge_px',256));
    T:=TGeoTileId.Make(0,True,Tile.Get('x',0),Tile.Get('y',0));
    Client:=TPhotoApiClient.Create(TFileSystemCache.Create(CacheRoot),True,DefaultPhotoApiConfig);
    Catalog:=Client.CachedTileCatalog(Grid,T);Recipe:=ReadActiveKnowledgeRecipe(CacheRoot,Tile);
    if (Cancel<>nil) and Cancel.CheckTerminated then raise EAbort.Create('cancelled');
    Result:=BuildKnowledgeEvidenceReport(Doc,Catalog,Client,Recipe,ReadBack.Get('content_hash',''));
    Result.Add('knowledge_revision',Doc.Get('revision',0));Result.Add('knowledge_hash',ReadBack.Get('content_hash',''));
  finally Grid.Free;Client.Free;Recipe.Free;Catalog.Free;ReadBack.Free;Store.Free end;
end;

function ReviewKnowledgePhoto(const CacheRoot:string;Request:TJSONObject;Cancel:TThread):TJSONObject;
var Store:TTileKnowledgeStore;Q,Compiled:TJSONObject;CompileError:string;
begin
  Result:=nil;Q:=nil;Compiled:=nil;Store:=TTileKnowledgeStore.Create(CacheRoot);
  try
   try
    if (Cancel<>nil) and Cancel.CheckTerminated then raise EAbort.Create('cancelled');
    Result:=Store.ReviewPhoto(Request,Request.Get('zoom',13),Request.Get('edge_px',256));
    if Request.Find('review_status')=nil then Exit;
    Q:=TJSONObject(Request.Clone);Q.Integers['expected_revision']:=Result.Get('revision',0);
    Q.Strings['expected_hash']:=Result.Get('content_hash','');Q.Booleans['activate']:=True;
    Q.Booleans['deactivate']:=False;
    { Once the review is committed, complete its recipe publication even when
      the UI closes. Keeping a superseded rejected contribution is not a valid
      cancellation outcome. The revision guard still protects other writers. }
    try
      Compiled:=CompileKnowledgeRecipe(CacheRoot,Q,nil);
      Result.Add('recipe_current',True);Result.Add('recipe_deactivated',False);
      Result.Add('recipe_result',Compiled);Compiled:=nil;
    except on E:Exception do begin
      CompileError:=E.Message;Result.Add('compile_error',CompileError);Result.Add('recipe_current',False);
      Q.Booleans['deactivate']:=True;
      try
        Compiled:=CompileKnowledgeRecipe(CacheRoot,Q,nil);
        Result.Add('recipe_deactivated',Compiled.Get('activated',False));
      except on D:Exception do begin
        Result.Add('recipe_deactivated',False);Result.Add('deactivation_error',D.Message);
      end end;
    end end;
    Result.Add('effective','next map load');
   except FreeAndNil(Result);raise end;
  finally Compiled.Free;Q.Free;Store.Free end;
end;

function SemanticTarget(T: TJSONObject): TJSONObject;
begin
  Result:=TJSONObject.Create(['id',T.Get('id',''),'fingerprint',T.Get('fingerprint',''),
    'bbox',T.Find('bbox').Clone,'set_tags',SortedJson(AsObject(T.Find('set_tags'),'set_tags'))]);
  if T.Get('category','building')<>'building' then Result.Add('category',T.Get('category',''));
  if IsLocalTarget(T) then Result.Add('anchor_id',AnchorId(T));
  if TJSONObject(T.Find('set_tags')).Find(FACADE_LAYOUT_TAG)<>nil then
    Result.Add('facade_generator',FACADE_LAYOUT_GENERATOR);
  if TJSONObject(T.Find('set_tags')).Find('building:colour')<>nil then
    Result.Add('appearance_generator',1);
  if TJSONObject(T.Find('set_tags')).Find(BUILDING_MASSING_TAG)<>nil then
    Result.Add('massing_generator',BUILDING_MASSING_GENERATOR);
  if TJSONObject(T.Find('set_tags')).Find(ARCHITECTURE_TAG)<>nil then
    Result.Add('architecture_generator',ARCHITECTURE_GENERATOR);
  if TJSONObject(T.Find('set_tags')).Find(COMPOUND_ROOF_TAG)<>nil then
    Result.Add('roof_layout_generator',COMPOUND_ROOF_GENERATOR);
  if TJSONObject(T.Find('set_tags')).Find(VEGETATION_LAYOUT_TAG)<>nil then
    Result.Add('vegetation_layout_generator',VEGETATION_LAYOUT_GENERATOR);
  if TJSONObject(T.Find('set_tags')).Find(PHOTO_ROAD_PROFILE_TAG)<>nil then
    Result.Add('road_profile_generator',PHOTO_ROAD_PROFILE_GENERATOR);
  if TJSONObject(T.Find('set_tags')).Find(ENVIRONMENT_LAYOUT_TAG)<>nil then
    Result.Add('environment_layout_generator',ENVIRONMENT_LAYOUT_GENERATOR);
end;

procedure TKnowledgeRecipeSnapshot.LoadCatalog(Catalog: TJSONObject; Grid: TGeoTileGrid);
var Tiles,Entry,Target,Existing,Tags,Other,Semantic: TJSONObject; A: TJSONArray;
  I,J,K,N,Covered: Integer; Key,S,Old: string; B: TLatLonBox; TT: TGeoTileIdArray;
  NW,SE: TGeoTileId; Whole: TStringBuilder;Coverage:TPhotoTileCoverage;Category:string;
begin
  FTargets:=SortedList; FTileHashes:=specialize TDictionary<Int64,string>.Create;
  FCoverage:=specialize TDictionary<Int64,TPhotoTileCoverage>.Create;
  Tiles:=AsObject(Catalog.Find('tiles'),'tiles');
  if Tiles.Count>8192 then raise ETileKnowledge.Create('Too many active recipe tiles');
  for I:=0 to Tiles.Count-1 do begin
    Entry:=AsObject(Tiles.Items[I],'recipe entry');
    if Entry.Get('recipe_version',0)<>RecipeVersion then raise ETileKnowledge.Create('Unsupported compiled recipe version');
    A:=AsArray(Entry.Find('targets'),'recipe targets');
    for J:=0 to A.Count-1 do begin
      Target:=AsObject(A.Items[J],'recipe target'); ValidateTarget(Target); Key:=Target.Get('id','');
      if FTargets.Find(Key,N) then begin
        Existing:=TJSONObject(FTargets.Objects[N]);
        if (AnchorId(Existing)<>AnchorId(Target)) or (Existing.Get('category','building')<>Target.Get('category','building')) or
          (Existing.Get('fingerprint','')<>Target.Get('fingerprint','')) or
          (Existing.Find('bbox').AsJSON<>Target.Find('bbox').AsJSON) then
          raise ETileKnowledge.Create('Conflicting OSM bases for '+Key+' in neighboring knowledge tiles');
        Tags:=AsObject(Existing.Find('set_tags'),'tags'); Other:=AsObject(Target.Find('set_tags'),'tags');
        for K:=0 to Other.Count-1 do begin
          if (Tags.Find(Other.Names[K])<>nil) and (Tags.Get(Other.Names[K],'')<>Other.Items[K].AsString) then
            raise ETileKnowledge.Create('Conflicting recipes for '+Key+' / '+Other.Names[K]);
          Tags.Strings[Other.Names[K]]:=Other.Items[K].AsString;
        end;
      end else FTargets.AddObject(Key,SemanticTarget(Target));
      if FTargets.Count>8192 then raise ETileKnowledge.Create('Too many active object recipes');
    end;
  end;
  Whole:=TStringBuilder.Create; Covered:=0;
  try
    for I:=0 to FTargets.Count-1 do begin
      Target:=TJSONObject(FTargets.Objects[I]); Semantic:=SemanticTarget(Target);
      try S:=Digest(Semantic.AsJSON) finally Semantic.Free end;
      Whole.Append(S);
      if Grid=nil then Continue;
      B:=KnowledgeBox(Target.Find('bbox'));
      if Target.Get('category','building')='building' then B:=B.ExpandMeters(8)
      else B:=B.ExpandMeters(80); { carriageway/levelling, crown and scatter footprint }
      NW:=Grid.TileAt(TLatLon.Make(B.MaxLat,B.MinLon)); SE:=Grid.TileAt(TLatLon.Make(B.MinLat,B.MaxLon));
      if (Int64(SE.TX)-NW.TX+1)*(Int64(SE.TY)-NW.TY+1)>256 then
        raise ETileKnowledge.Create('Object recipe affects more than 256 tiles: '+FTargets[I]);
      TT:=Grid.TilesCovering(B); Inc(Covered,Length(TT));
      if Covered>65536 then raise ETileKnowledge.Create('Active recipes exceed tile dependency budget');
      for J:=0 to High(TT) do begin
        if not FTileHashes.TryGetValue(TT[J].ToKey,Old) then Old:='';
        FTileHashes.AddOrSetValue(TT[J].ToKey,Digest(Old+S));
        if not FCoverage.TryGetValue(TT[J].ToKey,Coverage) then FillChar(Coverage,SizeOf(Coverage),0);
        Category:=Target.Get('category','building');
        if Category='building' then Inc(Coverage.Buildings)
        else if (Category='road') or (Category='sidewalk') then Inc(Coverage.Roads)
        else if Category='vegetation' then Inc(Coverage.Plants)
        else Inc(Coverage.Details);
        FCoverage.AddOrSetValue(TT[J].ToKey,Coverage);
      end;
    end;
    if FTargets.Count>0 then FHash:=Digest(Whole.ToString);
  finally Whole.Free end;
end;

{ The active recipe remains stable while agents draft unrelated edits. Source
  rejection is the exception: a new scene must not resurrect a removed piece
  of evidence through an older compiled entry or binary geometry variant.
  This check runs once when constructing the immutable scene snapshot. }
procedure ExcludeRejectedRecipeTargets(const CacheRoot:string;Catalog:TJSONObject);
var Store:TTileKnowledgeStore;Client:TPhotoApiClient;Grid:TGeoTileGrid;SourceIndex:TKnowledgeSourceIndex;
  Entries,Entry,Tile,Q,ReadBack,Current,Published,ReviewDoc,PhotoCatalog,S,P,O,Obs:TJSONObject;
  Sources,CurrentSources,Objects,Observations,Refs,Evidence,Targets:TJSONArray;
  Aliases,Blocked:TStringList;I,J,K,N:Integer;SourceId,HistoryPath,Hash,TargetId:string;
  F:TFileStream;Raw:RawByteString;D:TJSONData;T:TGeoTileId;NeedsCheck:Boolean;
  function PublishedDocument:TJSONObject;
  var C:Integer;
  begin
    Result:=nil;Hash:=Entry.Get('knowledge_hash','');
    if Hash=ReadBack.Get('content_hash','') then Exit(TJSONObject(Current.Clone));
    if Length(Hash)<>32 then Exit;
    for C:=1 to Length(Hash) do if not (Hash[C] in ['0'..'9','a'..'f']) then Exit;
    HistoryPath:=ReadBack.Get('path','')+'.history'+PathDelim+
      IntToStr(Entry.Get('knowledge_revision',0))+'-'+Hash+'.json';
    if not FileExists(HistoryPath) then Exit;
    F:=TFileStream.Create(HistoryPath,fmOpenRead or fmShareDenyNone);
    try
      if (F.Size<=0) or (F.Size>KnowledgeMaxBytes) then Exit;
      SetLength(Raw,F.Size);F.ReadBuffer(Raw[1],Length(Raw));
    finally F.Free end;
    D:=ParsePhotoJson(Raw);
    try
      if D is TJSONObject then begin ValidateTileKnowledge(TJSONObject(D),Tile);Result:=TJSONObject(D);D:=nil end;
    finally D.Free end;
  end;
  procedure BlockObservation(V:TJSONObject;const Id:string);
  begin
    if SourceIndex.RejectedSupport(V)<>'' then Blocked.Add(Id);
  end;
begin
  Entries:=AsObject(Catalog.Find('tiles'),'tiles');if Entries.Count=0 then Exit;
  Store:=TTileKnowledgeStore.Create(CacheRoot);Client:=nil;
  try
    for I:=0 to Entries.Count-1 do begin
      Entry:=TJSONObject(Entries.Items[I]);Targets:=AsArray(Entry.Find('targets'),'targets');
      if Targets.Count=0 then Continue;Tile:=AsObject(Entry.Find('tile'),'recipe tile');
      Evidence:=ArrayAt(Entry,'evidence');NeedsCheck:=Evidence=nil;
      if Evidence<>nil then for J:=0 to Evidence.Count-1 do
        if (ArrayAt(Evidence[J],'source_ids')<>nil) and (ArrayAt(Evidence[J],'source_ids').Count>0) then NeedsCheck:=True;
      if not NeedsCheck then Continue;
      Q:=TJSONObject.Create(['tile_x',Tile.Get('x',0),'tile_y',Tile.Get('y',0),
        'zoom',Tile.Get('zoom',13),'edge_px',Tile.Get('edge_px',256)]);
      ReadBack:=nil;Published:=nil;ReviewDoc:=nil;PhotoCatalog:=nil;Grid:=nil;SourceIndex:=nil;
      Aliases:=TStringList.Create;Aliases.Sorted:=True;Aliases.CaseSensitive:=True;Aliases.Duplicates:=dupIgnore;
      Blocked:=TStringList.Create;Blocked.Sorted:=True;Blocked.Duplicates:=dupIgnore;
      try
        ReadBack:=Store.Read(Q,13,256);Current:=TJSONObject(ReadBack.Find('document'));
        Published:=PublishedDocument;
        if Published<>nil then ReviewDoc:=TJSONObject(Published.Clone) else ReviewDoc:=TJSONObject(Current.Clone);
        Sources:=AsArray(ReviewDoc.Find('sources'),'sources');CurrentSources:=AsArray(Current.Find('sources'),'sources');
        { Current source reviews override the published source records; removed
          draft objects still retain their published evidence identities. }
        for J:=0 to Sources.Count-1 do Aliases.AddObject(TJSONObject(Sources[J]).Get('id',''),TObject(PtrInt(J)));
        for J:=0 to CurrentSources.Count-1 do begin
          S:=TJSONObject(CurrentSources[J]);SourceId:=S.Get('id','');K:=Aliases.IndexOf(SourceId);
          if K<0 then Sources.Add(S.Clone)
          else begin N:=PtrInt(Aliases.Objects[K]);Sources.Items[N]:=S.Clone end;
        end;
        if Sources.Count=0 then Continue;
        if Client=nil then Client:=TPhotoApiClient.Create(TFileSystemCache.Create(CacheRoot),True,DefaultPhotoApiConfig);
        Grid:=TGeoTileGrid.Create(Tile.Get('zoom',13),Tile.Get('edge_px',256));
        T:=TGeoTileId.Make(0,True,Tile.Get('x',0),Tile.Get('y',0));PhotoCatalog:=Client.CachedTileCatalog(Grid,T);
        SourceIndex:=TKnowledgeSourceIndex.Create(ReviewDoc,PhotoCatalog);
        if Evidence<>nil then begin
          for J:=0 to Evidence.Count-1 do BlockObservation(TJSONObject(Evidence[J]),TJSONObject(Evidence[J]).Get('target_id',''));
        end else begin
          { Legacy recipes have no journal. Recover their accepted references
            from the immutable published knowledge revision when available. }
          Objects:=ArrayAt(ReviewDoc,'objects');
          if Objects<>nil then for J:=0 to Objects.Count-1 do begin
            O:=TJSONObject(Objects[J]);Refs:=ArrayAt(O,'osm_refs');Observations:=ArrayAt(O,'observations');
            if (Refs=nil) or (Refs.Count<>1) or (Observations=nil) then Continue;
            P:=TJSONObject(Refs[0]);TargetId:=P.Get('type','')+'/'+P.Get('id','');
            for K:=0 to Observations.Count-1 do begin
              Obs:=TJSONObject(Observations[K]);
              if (Obs.Get('decision','')='accepted') and (Obs.Find('property')<>nil) then BlockObservation(Obs,TargetId);
            end;
          end;
        end;
        { A building is a coupled set of heights/roof/architecture parameters;
          remove the affected contribution as a whole, never a half-valid mix.
          Another independently supported tile contribution may still supply it. }
        for J:=Targets.Count-1 downto 0 do if Blocked.IndexOf(TJSONObject(Targets[J]).Get('id',''))>=0 then Targets.Delete(J);
      finally
        Blocked.Free;Aliases.Free;SourceIndex.Free;Grid.Free;PhotoCatalog.Free;ReviewDoc.Free;Published.Free;ReadBack.Free;Q.Free;
      end;
    end;
  finally Client.Free;Store.Free end;
end;

constructor TKnowledgeRecipeSnapshot.Create(const CacheRoot: string; Grid: TGeoTileGrid);
var Catalog: TJSONObject;
begin
  inherited Create; Catalog:=ReadCatalog(CatalogPath(CacheRoot));
  try ExcludeRejectedRecipeTargets(CacheRoot,Catalog);LoadCatalog(Catalog,Grid) finally Catalog.Free end;
  if Grid<>nil then FWorkflow:=PhotoPipelineTileIndex(CacheRoot,Grid.Zoom,Grid.EdgePx);
end;

constructor TKnowledgeRecipeSnapshot.FromCatalog(Catalog: TJSONObject; Grid: TGeoTileGrid);
begin inherited Create; LoadCatalog(Catalog,Grid) end;

destructor TKnowledgeRecipeSnapshot.Destroy;
var I: Integer;
begin
  if FTargets<>nil then for I:=0 to FTargets.Count-1 do FTargets.Objects[I].Free;
  FTargets.Free; FTileHashes.Free;FCoverage.Free;FWorkflow.Free; inherited;
end;

function TKnowledgeRecipeSnapshot.TileWorkflow(const Tile:TGeoTileId):TJSONObject;
begin
  Result:=nil;if FWorkflow<>nil then Result:=TJSONObject(FWorkflow.Find(IntToStr(Tile.TX)+'/'+IntToStr(Tile.TY)));
end;

function TKnowledgeRecipeSnapshot.TileCoverage(const Tile:TGeoTileId):TPhotoTileCoverage;
begin
  if not FCoverage.TryGetValue(Tile.ToKey,Result) then FillChar(Result,SizeOf(Result),0);
end;

function TKnowledgeRecipeSnapshot.TileHash(const Tile: TGeoTileId): string;
begin if not FTileHashes.TryGetValue(Tile.ToKey,Result) then Result:='' end;

function TKnowledgeRecipeSnapshot.BlockHash(const NW: TGeoTileId; Size: Integer): string;
var X,Y: Integer; S,H: string;
begin
  Result:=''; if FTargets.Count=0 then Exit; S:='';
  for Y:=0 to Size-1 do for X:=0 to Size-1 do begin
    H:=TileHash(TGeoTileId.Make(0,True,NW.TX+X,NW.TY+Y)); if H<>'' then S:=S+IntToStr(X)+','+IntToStr(Y)+':'+H+';';
  end;
  if S<>'' then Result:=Digest(S);
end;

procedure ValidateSourceCategory(const Category:string; Source:TJSONObject);forward;
procedure ValidatePlantLayoutSource(const Text:string; Source:TJSONObject);forward;

function ProfileBaseWidth(Tags:TJSONObject):Single;
var T:TOSMTags;I:Integer;
begin
  T:=TOSMTags.Create;
  try
    for I:=0 to Tags.Count-1 do T.Add(Tags.Names[I],Tags.Items[I].AsString);
    Result:=TRoadBuilder.ClassWidth(T);
  finally T.Free end;
end;

procedure TKnowledgeRecipeSnapshot.Apply(Dataset: TOSMDataset; const Box: TLatLonBox);
var R: TKnowledgeOsmReader; I,J: Integer; T,Current,SetTags,Effective: TJSONObject;
  Kind: string; Id,GeneratedId: Int64; Targets: array of TOSMTags;
  PendingWays:specialize TObjectList<TOSMWay>;
  PendingNodes:specialize TObjectList<TOSMNode>;
  W:TOSMWay; N:TOSMNode;
  RoadPlans:specialize TObjectList<TPhotoRoadPlan>; RoadPlan:TPhotoRoadPlan;
  Boundary:TPhotoPlantBoundary; UsedIds:TStringList; Key:string;GeneratedCount,NodeStart,WayStart:Integer;
  function LocalId(const Name:string):Int64;
  begin Result:=-StrToInt64('$'+Copy(Digest('photo-local-v1:'+Name),1,15)) end;
  procedure Reserve(const Kind:string; NewId:Int64);
  begin
    Key:=Kind+'/'+IntToStr(NewId);
    if (R.Tags(Kind,NewId)<>nil) or (UsedIds.IndexOf(Key)>=0) then
      raise ETileKnowledge.Create('Local generated identity collision: '+Key);
    UsedIds.Add(Key);
    Inc(GeneratedCount);
    if GeneratedCount>65536 then raise ETileKnowledge.Create('Local photo geometry budget exceeded');
  end;
begin
  if FTargets.Count=0 then Exit;
  R:=TKnowledgeOsmReader.Create(Dataset); SetLength(Targets,FTargets.Count);
  PendingWays:=specialize TObjectList<TOSMWay>.Create(True);
  PendingNodes:=specialize TObjectList<TOSMNode>.Create(True);UsedIds:=SortedList;
  RoadPlans:=specialize TObjectList<TPhotoRoadPlan>.Create(True);
  GeneratedCount:=0;
  try
    { Validate all fingerprints and stage local objects before the first mutation. }
    for I:=0 to FTargets.Count-1 do begin
      T:=TJSONObject(FTargets.Objects[I]);
      if not KnowledgeBoxesIntersect(KnowledgeBox(T.Find('bbox')),Box) then Continue;
      SetTags:=AsObject(T.Find('set_tags'),'tags');
      SplitId(AnchorId(T),Kind,Id); Current:=R.ObjectInfo(Kind,Id,
        ((T.Get('category','building')='vegetation') and not IsLocalTarget(T)) or
        (SetTags.Find(PHOTO_ROAD_PROFILE_TAG)<>nil));
      try
        if Current=nil then raise ETileKnowledge.Create('knowledge_recipe_stale: missing '+AnchorId(T));
        if Current.Get('fingerprint','')<>T.Get('fingerprint','') then
          raise ETileKnowledge.Create('knowledge_recipe_stale: OSM changed for '+AnchorId(T)+'; review and recompile tile knowledge');
        if not IsLocalTarget(T) then begin
          ValidateSourceCategory(T.Get('category','building'),Current);
          SetTags:=AsObject(T.Find('set_tags'),'tags');
          if SetTags.Find(VEGETATION_LAYOUT_TAG)<>nil then
            ValidatePlantLayoutSource(SetTags.Get(VEGETATION_LAYOUT_TAG,''),Current);
          if SetTags.Find(PHOTO_ROAD_PROFILE_TAG)<>nil then begin
            Effective:=TJSONObject(Current.Find('tags').Clone);
            try
              for J:=0 to SetTags.Count-1 do Effective.Strings[SetTags.Names[J]]:=SetTags.Items[J].AsString;
              ValidatePhotoRoadSource(SetTags.Get(PHOTO_ROAD_PROFILE_TAG,''),Current,ProfileBaseWidth(Effective),False);
              RoadPlan:=BuildPhotoRoadPlan(SetTags.Get(PHOTO_ROAD_PROFILE_TAG,''),
                Dataset.FindWay(Id),Dataset,ProfileBaseWidth(Effective));
              RoadPlans.Add(RoadPlan);
              for N in RoadPlan.Nodes do Reserve('node',N.Id);
            finally Effective.Free end;
          end;
          Targets[I]:=R.Tags(Kind,Id);
          { Defer mutation until every original fingerprint has passed. }
        end;
      finally Current.Free end;
      if IsLocalTarget(T) then begin
        SetTags:=AsObject(T.Find('set_tags'),'tags');
        if SetTags.Find(ENVIRONMENT_LAYOUT_TAG)<>nil then begin
          NodeStart:=PendingNodes.Count;WayStart:=PendingWays.Count;
          StageEnvironmentLayout(SetTags.Get(ENVIRONMENT_LAYOUT_TAG,''),FTargets[I],Dataset,PendingNodes,PendingWays);
          for J:=NodeStart to PendingNodes.Count-1 do Reserve('node',PendingNodes[J].Id);
          for J:=WayStart to PendingWays.Count-1 do Reserve('way',PendingWays[J].Id);
          Continue;
        end;
        Boundary:=VegetationLayoutBoundary(SetTags.Get(VEGETATION_LAYOUT_TAG,''));
        GeneratedId:=LocalId(FTargets[I]);Reserve('way',GeneratedId);
        W:=TOSMWay.Create(GeneratedId);PendingWays.Add(W);SetLength(W.NodeRefs,Length(Boundary)+1);
        for J:=0 to High(Boundary) do begin
          GeneratedId:=LocalId(FTargets[I]+':boundary:'+IntToStr(J));Reserve('node',GeneratedId);
          N:=TOSMNode.Create(GeneratedId,Boundary[J]);PendingNodes.Add(N);W.NodeRefs[J]:=GeneratedId;
        end;
        W.NodeRefs[High(W.NodeRefs)]:=W.NodeRefs[0];
        W.Tags.Add('rezvivo:local_photo_object',FTargets[I]);
        W.Tags.Add(VEGETATION_LAYOUT_TAG,SetTags.Get(VEGETATION_LAYOUT_TAG,''));
        if PendingNodes.Count>65536 then raise ETileKnowledge.Create('Local photo node budget exceeded');
      end;
    end;
    for I:=0 to FTargets.Count-1 do if Targets[I]<>nil then begin
      SetTags:=TJSONObject(TJSONObject(FTargets.Objects[I]).Find('set_tags'));
      if TJSONObject(FTargets.Objects[I]).Get('category','building')='building' then
        Targets[I].Add('rezvivo:photo_building','yes');
      for J:=0 to SetTags.Count-1 do Targets[I].Add(SetTags.Names[J],SetTags.Items[J].AsString);
    end;
    PendingNodes.OwnsObjects:=False;PendingWays.OwnsObjects:=False;
    if PendingWays.Count>0 then Dataset.HasLocalPhotoVegetation:=True;
    for I:=0 to PendingNodes.Count-1 do Dataset.AddNode(PendingNodes[I]);
    for I:=0 to PendingWays.Count-1 do Dataset.AddWay(PendingWays[I]);
    for RoadPlan in RoadPlans do RoadPlan.Apply(Dataset);
  finally RoadPlans.Free;UsedIds.Free;PendingNodes.Free;PendingWays.Free;R.Free end;
end;

procedure TKnowledgeRecipeSnapshot.BakeFacades(Model:TTileModel; ScaleLat:Double);
var I,J,K,N:Integer; Id:Int64; Kind,S:string; T,Tags:TJSONObject;
    Value:TJSONData; Layouts:TFacadeLayouts; P:TLocalProjection;
    Present:specialize TDictionary<Int64,Boolean>;
begin
  if (Model=nil) or (FTargets.Count=0) then Exit;
  Present:=specialize TDictionary<Int64,Boolean>.Create; P:=nil;
  try
    { Only scan geometry when this tile needs cached facade appearance data. }
    N:=0;
    for I:=0 to FTargets.Count-1 do begin
      T:=TJSONObject(FTargets.Objects[I]); Tags:=TJSONObject(T.Find('set_tags'));
      if ((Tags.Find(FACADE_LAYOUT_TAG)<>nil) or (Tags.Find('building:colour')<>nil)) and
        KnowledgeBoxesIntersect(KnowledgeBox(T.Find('bbox')).ExpandMeters(8),Model.Box) then Inc(N);
    end;
    if N=0 then Exit;
    for I:=0 to Model.MeshCount-1 do
      if Model.Meshes[I].Material in [smkBuildingWall,smkBuildingWall0..smkBuildingWall9] then
      for J:=0 to Model.Meshes[I].Mesh.VertexCount-1 do begin
        Id:=Model.Meshes[I].Mesh.Vertices[J].OsmId;
        if Id<>0 then Present.AddOrSetValue(Id,True);
      end;
    P:=TLocalProjection.Create(Model.Origin,ScaleLat);
    for I:=0 to FTargets.Count-1 do begin
      T:=TJSONObject(FTargets.Objects[I]);
      if T.Get('category','building')<>'building' then Continue;
      if IsLocalTarget(T) then Continue; { optional local architecture is already baked by the native builder }
      SplitId(FTargets[I],Kind,Id);
      if not Present.ContainsKey(Id) then Continue;
      Tags:=TJSONObject(T.Find('set_tags'));
      if Tags.Find('building:colour')<>nil then begin
        N:=Length(Model.BuildingTints); SetLength(Model.BuildingTints,N+1);
        Model.BuildingTints[N].OsmId:=Id;
        Model.BuildingTints[N].Color:=BuildingTintColor(Tags.Get('building:colour',''));
      end;
      S:=Tags.Get(FACADE_LAYOUT_TAG,'');
      if S='' then Continue;
      Value:=ParsePhotoJson(S);
      try Layouts:=ParseFacadeLayouts(Value) finally Value.Free end;
      ProjectFacadeLayouts(Layouts,P,Id);
      N:=Length(Model.FacadeLayouts); SetLength(Model.FacadeLayouts,N+Length(Layouts));
      for K:=0 to High(Layouts) do Model.FacadeLayouts[N+K]:=Layouts[K];
    end;
  finally P.Free; Present.Free end;
end;

procedure ValidateSourceCategory(const Category:string; Source:TJSONObject);
var Tags:TJSONObject; Kind,Id,H,N,L:string; VegetatedArea:Boolean;
begin
  Id:=Source.Get('id',''); Kind:=Source.Get('type','');
  Tags:=AsObject(Source.Find('tags'),'OSM tags');
  if not Source.Get('geometry_complete',False) then
    raise ETileKnowledge.Create('Incomplete OSM geometry for '+Id);
  if Category='building' then begin
    if (Source.Get('category','')<>'building') or (Kind='node') then
      raise ETileKnowledge.Create('Target must be an existing building way or multipolygon: '+Id);
    if (Kind='way') and not Source.Get('closed',False) then
      raise ETileKnowledge.Create('Building way must be closed: '+Id);
    if (Kind='relation') and ((Tags.Get('type','')<>'multipolygon') or
      ((Tags.Find('building')=nil) and (Tags.Find('building:part')=nil))) then
      raise ETileKnowledge.Create('Only building multipolygon relations are currently supported');
  end else if (Category='road') or (Category='sidewalk') then begin
    H:=Tags.Get('highway','');
    if (Kind<>'way') or (Source.Get('category','')<>'road') then
      raise ETileKnowledge.Create('Road/sidewalk refinement requires a highway way: '+Id);
    if Category='sidewalk' then begin
      if (H<>'footway') and (H<>'path') and (H<>'pedestrian') then
        raise ETileKnowledge.Create('Sidewalk refinement requires a separate pedestrian way: '+Id);
    end else if (H='') or (Pos('|'+H+'|','|motorway|trunk|primary|secondary|tertiary|residential|unclassified|road|living_street|service|busway|raceway|track|motorway_link|trunk_link|primary_link|secondary_link|tertiary_link|')=0) then
      raise ETileKnowledge.Create('Road refinement requires a supported carriageway: '+Id);
  end else if Category='vegetation' then begin
    if (Source.Find('vegetation_relations')<>nil) and (Source.Find('vegetation_relations').Count>0) then
      raise ETileKnowledge.Create('Vegetation way belongs to a multipolygon; refine its owning relation or a bounded local area: '+Id);
    N:=Tags.Get('natural',''); L:=Tags.Get('landuse','');
    VegetatedArea:=(N='wood') or (N='scrub') or (L='forest') or
      (L='grass') or (L='meadow') or (N='grassland');
    if Kind='node' then begin
      if (N<>'tree') and (N<>'shrub') then
        raise ETileKnowledge.Create('Plant refinement requires natural=tree/shrub: '+Id);
    end else if not VegetatedArea or ((Kind='way') and not Source.Get('closed',False)) or
      ((Kind='relation') and (Tags.Get('type','')<>'multipolygon')) then
      raise ETileKnowledge.Create('Plant refinement requires a tree/shrub node or forest/scrub polygon: '+Id);
  end else raise ETileKnowledge.Create('Unsupported recipe category: '+Category);
end;

procedure ValidateRoadTags(Tags:TJSONObject; const Id:string);
var N,F,B,C:Integer; HasN,HasF,HasB,Reverse,OneWay:Boolean; S:string;
  function Lane(const Key:string; out V:Integer):Boolean;
  begin
    Result:=Tags.Find(Key)<>nil; V:=0;
    if Result and (not TryStrToInt(Tags.Get(Key,''),V) or (V<0) or (V>16)) then
      raise ETileKnowledge.Create(Id+': invalid '+Key);
  end;
begin
  HasN:=Lane('lanes',N); HasF:=Lane('lanes:forward',F); HasB:=Lane('lanes:backward',B);
  Lane('lanes:both_ways',C);
  if (HasN and (N=0)) or (HasF and HasB and (F+B+C=0)) or
    (F+B+C>16) or (HasN and (F+B+C>N)) or
    (HasN and HasF and HasB and (F+B+C<>N)) then
    raise ETileKnowledge.Create(Id+': inconsistent lane totals/directions');
  S:=Tags.Get('oneway',''); Reverse:=(S='-1') or (S='reverse');
  OneWay:=Reverse or (S='yes') or (S='1') or (S='true');
  if S='' then OneWay:=(Tags.Get('highway','')='motorway') or
    (Tags.Get('highway','')='motorway_link') or (Tags.Get('junction','')='roundabout');
  if OneWay and ((C>0) or (Reverse and (F>0)) or (not Reverse and (B>0)) or
    (HasN and ((Reverse and HasB and (B<>N)) or (not Reverse and HasF and (F<>N))))) then
    raise ETileKnowledge.Create(Id+': lane directions contradict oneway');
end;

procedure ValidatePlantLayoutSource(const Text:string; Source:TJSONObject);
var Plants:TPhotoPlants; Ring:TPolygonRing; Outline,LL:TJSONArray;
  P:TLocalProjection; I:Integer; B:TLatLonBox; V:TVector3;
begin
  if (Source.Get('type','')<>'way') or not Source.Get('closed',False) then
    raise ETileKnowledge.Create('vegetation.layout requires one closed area way');
  if Length(VegetationLayoutBoundary(Text))>0 then
    raise ETileKnowledge.Create('A bounded partial planting requires a local: object; an OSM way layout replaces its whole polygon');
  Outline:=AsArray(Source.Find('outline'),'OSM outline');
  if Outline.Count>8192 then raise ETileKnowledge.Create('Plant layout host is too complex');
  B:=KnowledgeBox(Source.Find('bbox'));
  if (B.Width*111320*Cos(B.Center.Lat*Pi/180)>4000) or (B.Height*111320>4000) then
    raise ETileKnowledge.Create('Plant layout host exceeds 4 km; refine a smaller mapped area');
  Plants:=ReadVegetationLayout(Text);P:=TLocalProjection.Create(B.Center);
  try
    SetLength(Ring,Outline.Count);
    for I:=0 to Outline.Count-1 do begin
      LL:=AsArray(Outline[I],'outline coordinate');V:=P.Project(TLatLon.Make(LL[1].AsFloat,LL[0].AsFloat));
      Ring[I].X:=V.X;Ring[I].Z:=V.Z;
    end;
    for I:=0 to High(Plants) do begin
      V:=P.Project(Plants[I].Position);
      if not PointInRingXZ(V.X,V.Z,Ring) then
        raise ETileKnowledge.Create('Photo plant outside its OSM polygon: '+Plants[I].Id);
    end;
  finally P.Free end;
end;

function CompileKnowledgeRecipe(const CacheRoot: string; Request: TJSONObject; Cancel: TThread): TJSONObject;
var Store: TTileKnowledgeStore; ReadBack,Doc,Context,Tile,Recipe,Catalog,ContextRequest,ObjectsById,
  O,Obs,Ref,Source,Tags,SetTags,Target,Before,After,Again: TJSONObject;
  Objects,Observations,Refs,Targets,Warnings,Changes,RequestedIds,Evidence: TJSONArray;
  Ordered: TStringList; Snapshot: TKnowledgeRecipeSnapshot; Grid: TGeoTileGrid;
  I,J,K,N,Skipped: Integer; Height,MinHeight,RoofHeight: Double; Seen: TJSONObject; Id,SourceId,Prop,Val,Key,Hash,Path,OldValue,UnitName: string; LocalTarget:Boolean; LocalBox,AnchorBox:TLatLonBox;
  Activate,AnyAccepted,Deactivate: Boolean; H,DocLock: THandle; S: RawByteString;
  SourceIndex:TKnowledgeSourceIndex;EvidenceRow:TJSONObject;RejectedId:string;
  EvidenceClient:TPhotoApiClient;EvidenceCatalog:TJSONObject;EvidenceTile:TGeoTileId;
  ValidationDataset:TOSMDataset;
  procedure ValidatePartSelection;
  var Parts:TBuildingPartSelection;
  begin
    if ValidationDataset=nil then Exit;
    Parts:=TBuildingPartSelection.Create(ValidationDataset);
    try Parts.ValidatePhotoParts(ValidationDataset) finally Parts.Free end;
  end;

  procedure CheckCancelled;
  begin if (Cancel<>nil) and Cancel.CheckTerminated then raise EAbort.Create('cancelled') end;

  procedure CheckRevision(R: TJSONObject);
  begin
    if (Request.Find('expected_revision')=nil) or (Request.Find('expected_hash')=nil) then
      raise ETileKnowledge.Create('expected_revision and expected_hash are required; read saved knowledge first');
    if (not R.Get('exists',False)) or (Request.Get('expected_hash','')<>R.Get('content_hash','')) or
      (Request.Get('expected_revision',-1)<>TJSONObject(R.Find('document')).Get('revision',0)) then
      raise ETileKnowledge.Create('knowledge_revision_conflict: read latest document before compiling');
  end;

  procedure SetEntry;
  var Entries: TJSONObject;
  begin
    Entries:=AsObject(Catalog.Find('tiles'),'tiles'); Key:=TileKey(Tile);
    if Entries.Find(Key)<>nil then Entries.Delete(Key);
    if (Targets.Count>0) or (Evidence.Count>0) then Entries.Add(Key,Recipe.Clone);
  end;

begin
  Result:=nil; ReadBack:=nil; Context:=nil; Recipe:=nil; Catalog:=nil; ObjectsById:=nil;
  Ordered:=nil; Snapshot:=nil; Grid:=nil;SourceIndex:=nil;EvidenceClient:=nil;EvidenceCatalog:=nil;
  ValidationDataset:=nil;
  Store:=TTileKnowledgeStore.Create(CacheRoot);
  try
    try
      ReadBack:=Store.Read(Request,Request.Get('zoom',13),Request.Get('edge_px',256)); CheckRevision(ReadBack);
      Doc:=AsObject(ReadBack.Find('document'),'knowledge'); Tile:=AsObject(Doc.Find('tile'),'tile');
      Deactivate:=Request.Get('deactivate',False);
      Grid:=TGeoTileGrid.Create(Tile.Get('zoom',13),Tile.Get('edge_px',256));
      if not Deactivate and (AsArray(Doc.Find('sources'),'sources').Count>0) then begin
        EvidenceClient:=TPhotoApiClient.Create(TFileSystemCache.Create(CacheRoot),True,DefaultPhotoApiConfig);
        EvidenceTile:=TGeoTileId.Make(0,True,Tile.Get('x',0),Tile.Get('y',0));
        EvidenceCatalog:=EvidenceClient.CachedTileCatalog(Grid,EvidenceTile);
      end;
      SourceIndex:=TKnowledgeSourceIndex.Create(Doc,EvidenceCatalog);
      ContextRequest:=TJSONObject(Request.Clone);
      { Saved discovery scope must not invalidate previously accepted objects.
        Compilation requests exact bound IDs against their original OSM. }
      if ContextRequest.Find('route_scope')<>nil then ContextRequest.Delete('route_scope');
      ContextRequest.Add('route_scope',TJSONObject.Create(['enabled',False]));
      ContextRequest.Booleans['include_geometry']:=True;
      try
        ContextRequest.Integers['max_objects']:=Request.Get('max_objects',10000);
        if ContextRequest.Find('object_ids')<>nil then ContextRequest.Delete('object_ids');
        RequestedIds:=TJSONArray.Create; ContextRequest.Add('object_ids',RequestedIds);
        Objects:=AsArray(Doc.Find('objects'),'objects');
        for I:=0 to Objects.Count-1 do begin
          if Deactivate then Break;
          O:=TJSONObject(Objects.Items[I]); Observations:=AsArray(O.Find('observations'),'observations');
          AnyAccepted:=False;
          for J:=0 to Observations.Count-1 do begin
            Obs:=TJSONObject(Observations.Items[J]);
            if (Obs.Get('decision','')='accepted') and (Obs.Find('property')<>nil) and
              (SourceIndex.RejectedSupport(Obs)='') then AnyAccepted:=True;
          end;
          if not AnyAccepted then Continue;
          Refs:=AsArray(O.Find('osm_refs'),'osm_refs');
          if Refs.Count<>1 then raise ETileKnowledge.Create('Recipe requires exactly one OSM target per object');
          Ref:=TJSONObject(Refs.Items[0]); RequestedIds.Add(Ref.Get('type','')+'/'+Ref.Get('id',''));
        end;
        if Deactivate or (RequestedIds.Count=0) then Context:=TJSONObject.Create(['objects',TJSONArray.Create,'complete',True])
        else Context:=CachedKnowledgeContext(CacheRoot,ContextRequest,Cancel,nil,@ValidationDataset);
      finally ContextRequest.Free end;
      if not Deactivate and (not Context.Get('complete',False) or Context.Get('truncated',False)) then
        raise ETileKnowledge.Create('Complete cached OSM context is required; warm this tile first, then retry (max_objects <= 10000)');
      ObjectsById:=TJSONObject.Create; Objects:=AsArray(Context.Find('objects'),'context objects');
      for I:=0 to Objects.Count-1 do begin Source:=TJSONObject(Objects.Items[I]); ObjectsById.Add(Source.Get('id',''),Source.Clone) end;
      Targets:=TJSONArray.Create;Evidence:=TJSONArray.Create;
      Recipe:=TJSONObject.Create(['recipe_version',RecipeVersion,'tile',Tile.Clone,
        'knowledge_revision',Doc.Get('revision',0),'knowledge_hash',ReadBack.Get('content_hash',''),
        'targets',Targets,'evidence',Evidence]);
      Warnings:=TJSONArray.Create; Changes:=TJSONArray.Create;
      Result:=TJSONObject.Create(['compiled',True,'saved',False,'activated',False,'geometry_applied',False,
        'effective','next map load','network_requests',0,'warnings',Warnings,'changes',Changes]);
      Objects:=AsArray(Doc.Find('objects'),'objects'); Ordered:=SortedList; Skipped:=0;
      for I:=0 to Objects.Count-1 do begin
        if Deactivate then Break;
        CheckCancelled; O:=TJSONObject(Objects.Items[I]); Observations:=AsArray(O.Find('observations'),'observations');
        AnyAccepted:=False;
        for J:=0 to Observations.Count-1 do begin
          Obs:=TJSONObject(Observations.Items[J]);
          RejectedId:=SourceIndex.RejectedSupport(Obs);
          if (Obs.Get('decision','')='accepted') and (Obs.Find('property')<>nil) and
            (RejectedId='') then AnyAccepted:=True else Inc(Skipped);
          if (RejectedId<>'') and (Obs.Get('decision','')='accepted') then
            Warnings.Add(TJSONObject.Create(['reason','rejected_source','object_id',O.Get('id',''),
              'observation_id',Obs.Get('id',''),'source_id',RejectedId]));
        end;
        if not AnyAccepted then Continue;
        if O.Get('mapping_status','')<>'confirmed' then
          raise ETileKnowledge.Create('Accepted properties require a confirmed binding: '+O.Get('id',''));
        Refs:=AsArray(O.Find('osm_refs'),'osm_refs');
        if Refs.Count<>1 then raise ETileKnowledge.Create('Recipe requires exactly one OSM target per object');
        Ref:=TJSONObject(Refs.Items[0]); SourceId:=Ref.Get('type','')+'/'+Ref.Get('id','');
        Source:=AsObject(ObjectsById.Find(SourceId),'OSM target '+SourceId);
        LocalTarget:=Copy(O.Get('id',''),1,6)='local:';Id:=SourceId;
        if LocalTarget then begin
          Id:=O.Get('id','');
          if not Source.Get('geometry_complete',False) then
            raise ETileKnowledge.Create('Local recipe requires a complete OSM anchor');
        end else ValidateSourceCategory(O.Get('category',''),Source);
        Tags:=AsObject(Source.Find('tags'),'OSM tags');
        if (Ref.Get('fingerprint','')='') or (Ref.Get('fingerprint','')<>Source.Get('fingerprint','')) then
          raise ETileKnowledge.Create('OSM fingerprint changed or missing for '+Id+'; review knowledge.context');
        if Ordered.Find(Id,N) then Target:=TJSONObject(Ordered.Objects[N]) else begin
          Target:=TJSONObject.Create(['id',Id,'fingerprint',Ref.Get('fingerprint',''),
            'bbox',Source.Find('bbox').Clone,'set_tags',TJSONObject.Create,'seen',TJSONObject.Create]);
          if O.Get('category','')<>'building' then Target.Add('category',O.Get('category',''));
          if LocalTarget then Target.Add('anchor_id',SourceId);Ordered.AddObject(Id,Target);
        end;
        SetTags:=TJSONObject(Target.Find('set_tags')); Seen:=TJSONObject(Target.Find('seen'));
        if Target.Get('category','building')<>O.Get('category','') then
          raise ETileKnowledge.Create('Conflicting categories for '+Id);
        for J:=0 to Observations.Count-1 do begin
          Obs:=TJSONObject(Observations.Items[J]);
          if (Obs.Get('decision','')<>'accepted') or (Obs.Find('property')=nil) then Continue;
          if SourceIndex.RejectedSupport(Obs)<>'' then Continue;
          Prop:=Obs.Get('property',''); K:=PropertyIndex(Prop); UnitName:=Obs.Get('unit','');
          if not KnowledgePropertyCategory(Prop,O.Get('category','')) then
            raise ETileKnowledge.Create('Property/category mismatch: '+Id+' / '+Prop);
          if (Prop='vegetation.height_m') and (Ref.Get('type','')<>'node') then
            raise ETileKnowledge.Create('Explicit plant height currently requires an individual tree/shrub node');
          Val:=CanonicalValue(K,Obs.Find('value'),UnitName); Key:=KnowledgeProperties[K].TagName; OldValue:=Tags.Get(Key,'');
          if (Key=ENVIRONMENT_LAYOUT_TAG) and not LocalTarget then
            raise ETileKnowledge.Create('Environment additions need a stable local: object anchored to existing OSM');
          if LocalTarget then begin
            if Key=ENVIRONMENT_LAYOUT_TAG then LocalBox:=EnvironmentLayoutBox(Val)
            else if Prop='vegetation.layout' then LocalBox:=PlantBoundaryBox(Val)
            else raise ETileKnowledge.Create('Local additions require a bounded layout');
            AnchorBox:=KnowledgeBox(Source.Find('bbox')).ExpandMeters(80);
            if (LocalBox.MinLat<AnchorBox.MinLat) or (LocalBox.MaxLat>AnchorBox.MaxLat) or
              (LocalBox.MinLon<AnchorBox.MinLon) or (LocalBox.MaxLon>AnchorBox.MaxLon) then
              raise ETileKnowledge.Create('Local planting boundary is too far from the OSM anchor');
            Target.Delete('bbox');Target.Add('bbox',TJSONArray.Create([LocalBox.MinLon,LocalBox.MinLat,LocalBox.MaxLon,LocalBox.MaxLat]));
            OldValue:='';
          end else if Prop='vegetation.layout' then ValidatePlantLayoutSource(Val,Source);
          if not LocalTarget and (O.Get('category','')='vegetation') and (Ref.Get('type','')<>'node') and
            (Prop<>'vegetation.layout') and (Tags.Get('landuse','')<>'forest') and
            (Tags.Get('natural','')<>'wood') and (Tags.Get('natural','')<>'scrub') then
            raise ETileKnowledge.Create('Grass/meadow plants need an explicit vegetation.layout');
          if (Obs.Get('visibility','')='ambiguous') or
            ((Obs.Get('visibility','')='not_visible') and (Obs.Get('origin','')<>'local_inferred')) then
            raise ETileKnowledge.Create('Accepted property has no usable visibility: '+Obs.Get('id',''));
          if (Obs.Get('visibility','')='not_visible') and
            ((AsArray(Obs.Find('source_ids'),'inference sources').Count=0) or
             (Obs.Get('note','')='') or (Obs.Get('confidence',1.0)>0.75)) then
            raise ETileKnowledge.Create('Unseen local inference needs source examples, a rationale and confidence <= 0.75');
          if (OldValue<>'') and (OldValue<>Val) and (Obs.Get('origin','')<>'manual_override') then
            raise ETileKnowledge.Create('Explicit OSM conflict: '+Id+' / '+Key+'; requires manual_override');
          if (Seen.Find(Key)<>nil) and (Seen.Get(Key,'')<>Val) then
            raise ETileKnowledge.Create('Conflicting accepted observations: '+Id+' / '+Key);
          Seen.Strings[Key]:=Val;
          EvidenceRow:=TJSONObject.Create(['object_id',O.Get('id',''),'target_id',Id,
            'observation_id',Obs.Get('id',''),'property',Prop,'tag',Key,'before',OldValue,'after',Val,
            'origin',Obs.Get('origin',''),'source_ids',Obs.Find('source_ids').Clone]);
          if OldValue=Val then EvidenceRow.Add('effect','confirmed_osm') else EvidenceRow.Add('effect','changed');
          Evidence.Add(EvidenceRow);
          { Equal values are valid confirmations but need no geometry variant. }
          if OldValue=Val then Continue;
          SetTags.Strings[Key]:=Val;
          Changes.Add(TJSONObject.Create(['id',Id,'property',Prop,'tag',Key,'before',OldValue,'after',Val,
            'observation_id',Obs.Get('id',''),'origin',Obs.Get('origin',''),'source_ids',Obs.Find('source_ids').Clone]));
        end;
      end;
      for I:=0 to Ordered.Count-1 do begin
        Target:=TJSONObject(Ordered.Objects[I]); SetTags:=TJSONObject(Target.Find('set_tags'));
        if SetTags.Count=0 then Continue;
        Source:=AsObject(ObjectsById.Find(AnchorId(Target)),'target'); Before:=TJSONObject(Source.Find('tags'));
        After:=TJSONObject(Before.Clone);
        try
          for J:=0 to SetTags.Count-1 do After.Strings[SetTags.Names[J]]:=SetTags.Items[J].AsString;
          if Target.Get('category','building')='road' then ValidateRoadTags(After,Ordered[I]);
          if SetTags.Find(PHOTO_ROAD_PROFILE_TAG)<>nil then begin
            ValidatePhotoRoadSource(SetTags.Get(PHOTO_ROAD_PROFILE_TAG,''),Source,ProfileBaseWidth(After));
            { A moved sidewalk/changed edge can affect a neighbour tile too. }
            LocalBox:=KnowledgeBox(Source.Find('bbox')).ExpandMeters(50);
            Target.Delete('bbox');Target.Add('bbox',TJSONArray.Create([
              LocalBox.MinLon,LocalBox.MinLat,LocalBox.MaxLon,LocalBox.MaxLat]));
          end;
          Height:=0; MinHeight:=0; RoofHeight:=0;
          TryStrToFloat(After.Get('height','0'),Height,Invariant);
          TryStrToFloat(After.Get('min_height','0'),MinHeight,Invariant);
          TryStrToFloat(After.Get('roof:height','0'),RoofHeight,Invariant);
          if (Target.Get('category','building')='building') and (After.Find(COMPOUND_ROOF_TAG)=nil) and (Height>0) and (MinHeight+RoofHeight>=Height) then
            raise ETileKnowledge.Create(Ordered[I]+': min_height + roof height must be below total height');
          if (Target.Get('category','building')='building') and (After.Find(COMPOUND_ROOF_TAG)=nil) and (After.Get('roof:shape','')='flat') and (RoofHeight>0) then
            raise ETileKnowledge.Create(Ordered[I]+': flat roof must have zero roof height');
        finally After.Free end;
        ValidateTarget(Target); Targets.Add(SemanticTarget(Target));
      end;
      Hash:=Digest(Targets.AsJSON); Recipe.Add('geometry_hash',Hash);
      Result.Add('geometry_hash',Hash); Result.Add('target_count',Targets.Count); Result.Add('skipped_observations',Skipped);
      Result.Add('evidence_report',BuildKnowledgeEvidenceReport(Doc,EvidenceCatalog,EvidenceClient,Recipe,ReadBack.Get('content_hash','')));
      Result.Add('recipe',Recipe.Clone); Path:=CatalogPath(CacheRoot);
      Activate:=Request.Get('activate',False);
      if Activate then begin
        if not ForceDirectories(ExtractFilePath(Path)) then raise ETileKnowledge.Create('Cannot create recipe directory');
        DocLock:=KnowledgeAcquireWriter(ReadBack.Get('path','')+'.lock');
        try
          Again:=Store.Read(Request,Request.Get('zoom',13),Request.Get('edge_px',256));
          try CheckRevision(Again) finally Again.Free end;
          H:=KnowledgeAcquireWriter(Path+'.lock');
          try
            Catalog:=ReadCatalog(Path); SetEntry;
            Snapshot:=TKnowledgeRecipeSnapshot.FromCatalog(Catalog,Grid);
            if ValidationDataset<>nil then Snapshot.Apply(ValidationDataset,KnowledgeBox(Tile.Find('bbox')));
            ValidatePartSelection;
            S:=Catalog.FormatJSON([],2);
            if Length(S)>CatalogMaxBytes then raise ETileKnowledge.Create('Active recipe catalog exceeds 16 MiB');
            CheckCancelled; KnowledgeAtomicText(Path,S);
            Result.Booleans['activated']:=True; Result.Booleans['saved']:=True; Result.Add('path',Path);
          finally KnowledgeReleaseWriter(H) end;
        finally KnowledgeReleaseWriter(DocLock) end;
      end else begin
        Catalog:=ReadCatalog(Path); SetEntry;
        Snapshot:=TKnowledgeRecipeSnapshot.FromCatalog(Catalog,Grid);
        if ValidationDataset<>nil then Snapshot.Apply(ValidationDataset,KnowledgeBox(Tile.Find('bbox')));
        ValidatePartSelection;
      end;
    except FreeAndNil(Result); raise end;
  finally
    ValidationDataset.Free;SourceIndex.Free;EvidenceCatalog.Free;EvidenceClient.Free;Snapshot.Free; Grid.Free; Catalog.Free; Recipe.Free; ObjectsById.Free; Context.Free; ReadBack.Free; Store.Free;
    if Ordered<>nil then for I:=0 to Ordered.Count-1 do Ordered.Objects[I].Free;
    Ordered.Free;
  end;
end;
end.
