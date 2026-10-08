program KnowledgeRecipeRecoveryTest;
{$mode objfpc}{$H+}{$codepage UTF8}
uses SysUtils,Classes,fpjson,Osm3dPhotoSources,Osm3dTileKnowledge,Osm3dKnowledgeRecipe;
var Root,Path,Expected,Original:string; Catalog,Entries,Entry,T,Tags:TJSONObject;
  Targets:TJSONArray; Snapshot:TKnowledgeRecipeSnapshot; Text:TStringList; Failed:Boolean;
procedure Check(Value:Boolean;const Msg:string);
begin if not Value then raise Exception.Create(Msg) end;
procedure Save;
begin Text.Text:=Catalog.AsJSON;Text.SaveToFile(Path) end;
begin
  if ParamCount<>1 then raise Exception.Create('Pass an isolated test cache root');
  Root:=ExpandFileName(ParamStr(1));Path:=Root+'-knowledge'+PathDelim+'active-recipes-v1.json';
  ForceDirectories(ExtractFilePath(Path));Text:=TStringList.Create;
  Tags:=TJSONObject.Create(['height','12']);
  T:=TJSONObject.Create(['id','way/123','category','building','fingerprint',StringOfChar('a',32),
    'bbox',TJSONArray.Create([37.5,55.7,37.501,55.701]),'set_tags',Tags]);
  Targets:=TJSONArray.Create;Targets.Add(T);
  Entry:=TJSONObject.Create(['recipe_version',1,'targets',Targets,'evidence',TJSONArray.Create,
    'tile',TJSONObject.Create(['zoom',13,'edge_px',256,'x',4949,'y',2562])]);
  Entries:=TJSONObject.Create;Entries.Add('real/z13/e256/4949/2562',Entry);
  Catalog:=TJSONObject.Create(['schema_version',1,'tiles',Entries]);
  try
    Snapshot:=TKnowledgeRecipeSnapshot.FromCatalog(Catalog,nil);
    try Expected:=Snapshot.ContentHash;Check(Expected<>'','empty reference hash') finally Snapshot.Free end;
    Tags.Strings['height']:='12.000';Save;Original:=Text.Text;
    Failed:=False;
    try Snapshot:=TKnowledgeRecipeSnapshot.FromCatalog(Catalog,nil);Snapshot.Free
    except on E:ETileKnowledge do Failed:=True end;
    Check(Failed,'publication accepted a noncanonical value');
    Snapshot:=TKnowledgeRecipeSnapshot.Create(Root,nil);
    try Check(Snapshot.ContentHash=Expected,'compatible cached value lost its recipe') finally Snapshot.Free end;
    Text.LoadFromFile(Path);Check(Text.Text=Original,'loader rewrote authored cache');
    T:=TJSONObject(T.Clone);T.Strings['id']:='way/456';
    TJSONObject(T.Find('set_tags')).Strings['height']:='-50';Targets.Add(T);Save;
    Snapshot:=TKnowledgeRecipeSnapshot.Create(Root,nil);
    try Check(Snapshot.ContentHash=Expected,'bad target discarded valid recipes') finally Snapshot.Free end;
    Text.Text:='{broken';Text.SaveToFile(Path);
    Snapshot:=TKnowledgeRecipeSnapshot.Create(Root,nil);
    try Check(Snapshot.ContentHash='','broken optional catalog did not fall back to base OSM') finally Snapshot.Free end;
    Catalog.Integers['schema_version']:=99;Save;
    Snapshot:=TKnowledgeRecipeSnapshot.Create(Root,nil);
    try Check(Snapshot.ContentHash='','unknown schema did not fall back') finally Snapshot.Free end;
    WriteLn('PASS: normalization, strict publication, per-target recovery, corrupt/unknown catalog fallback');
  finally Catalog.Free;Text.Free end;
end.
