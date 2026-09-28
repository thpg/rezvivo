unit TreeRecipe;
{$mode objfpc}{$H+}
interface
uses TreeModel,TreeSeason;
function TreeToJSON(const P: TTreeParams): string;
function TreeFromJSON(const Text: string): TTreeParams;
procedure SaveTreeRecipe(const FileName: string; const P: TTreeParams);
function LoadTreeRecipe(const FileName: string): TTreeParams;
procedure SaveTreeDocument(const FileName: string; const Instance: TTreeInstance; const Profile: TTreeParams; Season: Single = TREE_SUMMER);
procedure LoadTreeDocument(const FileName: string; out Instance: TTreeInstance; out Profile: TTreeParams); overload;
procedure LoadTreeDocument(const FileName: string; out Instance: TTreeInstance; out Profile: TTreeParams; out Season: Single); overload;
implementation
uses SysUtils, Classes, fpjson, jsonparser, TreeMath;
function TreeToJSON(const P: TTreeParams): string;
var J: TJSONObject;
  procedure Number(const Name: string; Value: Double);
  begin
    { The host may replace fpjson's global float factory (BikeJSON does).
      Recipes and atlas keys require the original, full precision encoding. }
    J.Add(Name,TJSONFloatNumber.Create(Value));
  end;
  function Color(const V: TTreeVec3): TJSONArray;
  begin
    Result:=TJSONArray.Create;
    Result.Add(TJSONFloatNumber.Create(V.X));
    Result.Add(TJSONFloatNumber.Create(V.Y));
    Result.Add(TJSONFloatNumber.Create(V.Z));
  end;
begin
  ValidateTreeParams(P); J:=TJSONObject.Create;
  try
    J.Add('format','rezvivo.procedural-tree'); J.Add('version',TREE_GENERATOR_VERSION);
    J.Add('species',SpeciesName(P.Species));
    Number('height',P.Height); Number('trunkRadius',P.TrunkRadius); Number('crownSpread',P.CrownSpread);
    Number('heightVariation',P.HeightVariation); Number('needleLength',P.NeedleLength); Number('needleWidth',P.NeedleWidth);
    Number('crownStart',P.CrownStart); Number('branchAngle',P.BranchAngle);
    Number('irregularity',P.Irregularity); Number('leafSize',P.LeafSize);
    Number('leafDensity',P.LeafDensity); Number('droop',P.Droop);
    J.Add('primaryBranches',P.PrimaryBranches); J.Add('maxDepth',P.MaxDepth);
    J.Add('barkColor',Color(P.BarkColor));
    J.Add('leafColor',Color(P.LeafColor));
    Result:=J.FormatJSON;
  finally J.Free; end;
end;
function TreeFromJSON(const Text: string): TTreeParams;
var Data: TJSONData; J: TJSONObject; Version: Integer;
  function Number(const Name: string): Double;
  var D: TJSONData;
  begin
    D:=J.Find(Name); if (D=nil) or (D.JSONType<>jtNumber) then
      raise EConvertError.Create('Missing or invalid numeric field: '+Name);
    Result:=D.AsFloat;
  end;
  function IntegerField(const Name: string; Lo,Hi: Int64): Int64;
  var N: Double;
  begin
    N:=Number(Name);
    if (N<Lo) or (N>Hi) or (N<>Int(N)) then raise EConvertError.Create('Invalid integer: '+Name);
    Result:=Round(N);
  end;
  function Color(const Name: string): TTreeVec3;
  var D: TJSONData; A: TJSONArray; I: Integer;
  begin
    D:=J.Find(Name);
    if (D=nil) or (D.JSONType<>jtArray) or (D.Count<>3) then raise EConvertError.Create('Invalid color: '+Name);
    A:=TJSONArray(D);
    for I:=0 to 2 do if A.Items[I].JSONType<>jtNumber then raise EConvertError.Create('Invalid color channel');
    Result:=Vec(A.Floats[0],A.Floats[1],A.Floats[2]);
  end;
begin
  if Length(Text)>65536 then raise EConvertError.Create('Recipe exceeds 64 KiB');
  Data:=GetJSON(Text);
  try
    if Data.JSONType<>jtObject then raise EConvertError.Create('Recipe must be a JSON object');
    J:=TJSONObject(Data);
    if J.Get('format','')<>'rezvivo.procedural-tree' then raise EConvertError.Create('Unknown recipe format');
    Version:=IntegerField('version',1,TREE_GENERATOR_VERSION);
    Result:=DefaultTreeParams(SpeciesFromName(J.Get('species','')));
    Result.Height:=Number('height'); Result.TrunkRadius:=Number('trunkRadius');
    if Version>=2 then begin
      Result.HeightVariation:=Number('heightVariation'); Result.NeedleLength:=Number('needleLength');
      Result.NeedleWidth:=Number('needleWidth');
    end;
    Result.CrownSpread:=Number('crownSpread'); Result.CrownStart:=Number('crownStart');
    Result.BranchAngle:=Number('branchAngle'); Result.Irregularity:=Number('irregularity');
    Result.LeafSize:=Number('leafSize'); Result.LeafDensity:=Number('leafDensity'); Result.Droop:=Number('droop');
    Result.PrimaryBranches:=IntegerField('primaryBranches',4,TREE_MAX_PRIMARY_BRANCHES); Result.MaxDepth:=IntegerField('maxDepth',1,4);
    Result.BarkColor:=Color('barkColor'); Result.LeafColor:=Color('leafColor'); ValidateTreeParams(Result);
  finally Data.Free; end;
end;
procedure SaveTreeRecipe(const FileName: string; const P: TTreeParams);
var S: TStringList;
begin S:=TStringList.Create; try S.Text:=TreeToJSON(P); S.SaveToFile(FileName); finally S.Free; end; end;
function LoadTreeRecipe(const FileName: string): TTreeParams;
var S: TStringList; F: TFileStream;
begin
  F:=TFileStream.Create(FileName,fmOpenRead or fmShareDenyNone);
  try
    if F.Size>65536 then raise EConvertError.Create('Recipe exceeds 64 KiB');
    S:=TStringList.Create;
    try S.LoadFromStream(F); Result:=TreeFromJSON(S.Text); finally S.Free; end;
  finally F.Free; end;
end;
procedure SaveTreeDocument(const FileName: string; const Instance: TTreeInstance; const Profile: TTreeParams; Season: Single);
var J,Environment: TJSONObject; S: TStringList;
begin
  SeedForTree(Instance); ValidateTreeParams(Profile);
  if Instance.Species<>Profile.Species then raise EArgumentException.Create('Instance type and profile differ');
  J:=TJSONObject.Create; S:=TStringList.Create;
  try
    J.Add('format','rezvivo.tree-editor'); J.Add('version',TREE_GENERATOR_VERSION);
    J.Add('position',TJSONArray.Create([Instance.Position.X,Instance.Position.Y,Instance.Position.Z]));
    J.Add('type',SpeciesName(Instance.Species)); J.Add('gpu_type',Int64(Instance.TypeCode));
    J.Add('profile',GetJSON(TreeToJSON(Profile)));
    Environment:=TJSONObject.Create; Environment.Add('year_phase',WrapTreeSeason(Season)); J.Add('environment',Environment);
    S.Text:=J.FormatJSON; S.SaveToFile(FileName);
  finally S.Free; J.Free; end;
end;
procedure LoadTreeDocument(const FileName: string; out Instance: TTreeInstance; out Profile: TTreeParams);
var Season: Single;
begin LoadTreeDocument(FileName,Instance,Profile,Season); end;
procedure LoadTreeDocument(const FileName: string; out Instance: TTreeInstance; out Profile: TTreeParams; out Season: Single);
var F: TFileStream; S: TStringList; D,A,Part: TJSONData; J: TJSONObject;
    NewInstance: TTreeInstance; NewProfile: TTreeParams; I: Integer; NewSeason: Single;
begin
  F:=TFileStream.Create(FileName,fmOpenRead or fmShareDenyNone); S:=TStringList.Create; D:=nil;
  try
    if F.Size>65536 then raise EConvertError.Create('Document exceeds 64 KiB');
    S.LoadFromStream(F); D:=GetJSON(S.Text);
    if D.JSONType<>jtObject then raise EConvertError.Create('Document must be an object');
    J:=TJSONObject(D);
    if J.Get('format','')<>'rezvivo.tree-editor' then raise EConvertError.Create('Unknown document format');
    A:=J.Find('version');
    if (A=nil) or (A.JSONType<>jtNumber) or (A.AsFloat<1) or
      (A.AsFloat>TREE_GENERATOR_VERSION) or (A.AsFloat<>Int(A.AsFloat)) then
      raise EConvertError.Create('Unsupported document version');
    A:=J.Find('position');
    if (A=nil) or (A.JSONType<>jtArray) or (A.Count<>3) then raise EConvertError.Create('Invalid world position');
    for I:=0 to 2 do if A.Items[I].JSONType<>jtNumber then raise EConvertError.Create('Position must contain numbers');
    NewInstance:=Default(TTreeInstance); NewInstance.Species:=SpeciesFromName(J.Get('type',''));
    NewInstance.Position.X:=A.Items[0].AsFloat; NewInstance.Position.Y:=A.Items[1].AsFloat;
    NewInstance.Position.Z:=A.Items[2].AsFloat; SeedForTree(NewInstance);
    Part:=J.Find('gpu_type');
    if Part<>nil then begin
      if (Part.JSONType<>jtNumber) or (Part.AsFloat<0) or (Part.AsFloat>High(LongWord)) or
        (Part.AsFloat<>Int(Part.AsFloat)) then raise EConvertError.Create('Invalid gpu_type');
      NewInstance.TypeCode:=LongWord(Round(Part.AsFloat)); ValidateTreeType(NewInstance.TypeCode);
      if SpeciesName(NewInstance.Species)<>J.Get('type','') then raise EConvertError.Create('GPU family and type differ');
    end else if J.Get('version',0)>=4 then raise EConvertError.Create('Missing gpu_type');
    Part:=J.Find('profile'); if Part=nil then raise EConvertError.Create('Missing type profile');
    NewProfile:=TreeFromJSON(Part.AsJSON);
    if NewProfile.Species<>NewInstance.Species then raise EConvertError.Create('Type and profile species differ');
    NewSeason:=TREE_SUMMER; Part:=J.Find('environment');
    if Part<>nil then begin
      if Part.JSONType<>jtObject then raise EConvertError.Create('Invalid environment');
      A:=TJSONObject(Part).Find('year_phase');
      if (A=nil) or (A.JSONType<>jtNumber) then raise EConvertError.Create('Invalid season');
      NewSeason:=WrapTreeSeason(A.AsFloat);
    end;
    Instance:=NewInstance; Profile:=NewProfile; Season:=NewSeason;
  finally D.Free; S.Free; F.Free; end;
end;
end.
