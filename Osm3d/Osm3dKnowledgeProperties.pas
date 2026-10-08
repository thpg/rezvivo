unit Osm3dKnowledgeProperties;
{$mode objfpc}{$H+}

{ One vocabulary for compilation, capabilities and provenance reports. Tags
  are scoped by category: height on a tree is not building.height_m. Keep the
  original eleven building entries stable for existing recipe hashes. }
interface
uses SysUtils, fpjson;
type
  TKnowledgeValueKind = (kvNumber, kvInteger, kvEnum, kvColor, kvTaxon, kvObject);
  TKnowledgeProperty = record
    Name, TagName, Category: string;
    Kind: TKnowledgeValueKind;
    UnitName: string;
    MinValue, MaxValue: Double;
    Values: string;
  end;
const
  KnowledgeProperties: array[0..31] of TKnowledgeProperty = (
    (Name:'building.height_m'; TagName:'height'; Category:'building'; Kind:kvNumber; UnitName:'m'; MinValue:0.5; MaxValue:1000; Values:''),
    (Name:'building.levels'; TagName:'building:levels'; Category:'building'; Kind:kvInteger; UnitName:'storeys'; MinValue:1; MaxValue:250; Values:''),
    (Name:'building.min_height_m'; TagName:'min_height'; Category:'building'; Kind:kvNumber; UnitName:'m'; MinValue:0; MaxValue:1000; Values:''),
    (Name:'roof.shape'; TagName:'roof:shape'; Category:'building'; Kind:kvEnum; UnitName:''; MinValue:0; MaxValue:0; Values:'|flat|pyramidal|skillion|gabled|hipped|half-hipped|mansard|gambrel|saltbox|onion|dome|round|'),
    (Name:'roof.height_m'; TagName:'roof:height'; Category:'building'; Kind:kvNumber; UnitName:'m'; MinValue:0; MaxValue:100; Values:''),
    (Name:'facade.material'; TagName:'building:material'; Category:'building'; Kind:kvEnum; UnitName:''; MinValue:0; MaxValue:0; Values:'|brick|cement_block|glass|wood|plaster|concrete|'),
    (Name:'facade.color'; TagName:'building:colour'; Category:'building'; Kind:kvColor; UnitName:''; MinValue:0; MaxValue:0; Values:''),
    (Name:'facade.layout'; TagName:'rezvivo:facade_layout'; Category:'building'; Kind:kvObject; UnitName:''; MinValue:0; MaxValue:0; Values:''),
    (Name:'building.massing'; TagName:'rezvivo:building_massing'; Category:'building'; Kind:kvObject; UnitName:''; MinValue:0; MaxValue:0; Values:''),
    (Name:'building.architecture'; TagName:'rezvivo:architecture'; Category:'building'; Kind:kvObject; UnitName:''; MinValue:0; MaxValue:0; Values:''),
    (Name:'roof.layout'; TagName:'rezvivo:roof_layout'; Category:'building'; Kind:kvObject; UnitName:''; MinValue:0; MaxValue:0; Values:''),
    (Name:'road.width_m'; TagName:'width'; Category:'road'; Kind:kvNumber; UnitName:'m'; MinValue:1; MaxValue:60; Values:''),
    (Name:'road.lanes'; TagName:'lanes'; Category:'road'; Kind:kvInteger; UnitName:''; MinValue:1; MaxValue:16; Values:''),
    (Name:'road.lanes_forward'; TagName:'lanes:forward'; Category:'road'; Kind:kvInteger; UnitName:''; MinValue:0; MaxValue:16; Values:''),
    (Name:'road.lanes_backward'; TagName:'lanes:backward'; Category:'road'; Kind:kvInteger; UnitName:''; MinValue:0; MaxValue:16; Values:''),
    (Name:'road.surface'; TagName:'surface'; Category:'road'; Kind:kvEnum; UnitName:''; MinValue:0; MaxValue:0; Values:'|asphalt|concrete|paving_stones|cobblestone|gravel|compacted|dirt|ground|sand|wood|'),
    (Name:'road.smoothness'; TagName:'smoothness'; Category:'road'; Kind:kvEnum; UnitName:''; MinValue:0; MaxValue:0; Values:'|excellent|good|intermediate|bad|very_bad|horrible|very_horrible|impassable|'),
    (Name:'sidewalk.width_m'; TagName:'width'; Category:'sidewalk'; Kind:kvNumber; UnitName:'m'; MinValue:0.5; MaxValue:15; Values:''),
    (Name:'sidewalk.surface'; TagName:'surface'; Category:'sidewalk'; Kind:kvEnum; UnitName:''; MinValue:0; MaxValue:0; Values:'|asphalt|concrete|paving_stones|cobblestone|gravel|compacted|dirt|ground|sand|wood|'),
    (Name:'vegetation.genus'; TagName:'genus'; Category:'vegetation'; Kind:kvTaxon; UnitName:''; MinValue:0; MaxValue:0; Values:''),
    (Name:'vegetation.species'; TagName:'species'; Category:'vegetation'; Kind:kvTaxon; UnitName:''; MinValue:0; MaxValue:0; Values:''),
    (Name:'vegetation.leaf_type'; TagName:'leaf_type'; Category:'vegetation'; Kind:kvEnum; UnitName:''; MinValue:0; MaxValue:0; Values:'|broadleaved|needleleaved|mixed|'),
    (Name:'vegetation.height_m'; TagName:'height'; Category:'vegetation'; Kind:kvNumber; UnitName:'m'; MinValue:0.2; MaxValue:80; Values:''),
    (Name:'vegetation.layout'; TagName:'rezvivo:vegetation_layout'; Category:'vegetation'; Kind:kvObject; UnitName:''; MinValue:0; MaxValue:0; Values:''),
    (Name:'road.profile'; TagName:'rezvivo:road_profile'; Category:'road'; Kind:kvObject; UnitName:''; MinValue:0; MaxValue:0; Values:''),
    (Name:'sidewalk.profile'; TagName:'rezvivo:road_profile'; Category:'sidewalk'; Kind:kvObject; UnitName:''; MinValue:0; MaxValue:0; Values:''),
    (Name:'street_furniture.layout'; TagName:'rezvivo:environment_layout'; Category:'street_furniture'; Kind:kvObject; UnitName:''; MinValue:0; MaxValue:0; Values:''),
    (Name:'fence.layout'; TagName:'rezvivo:environment_layout'; Category:'fence'; Kind:kvObject; UnitName:''; MinValue:0; MaxValue:0; Values:''),
    (Name:'vegetation.areas'; TagName:'rezvivo:environment_layout'; Category:'vegetation'; Kind:kvObject; UnitName:''; MinValue:0; MaxValue:0; Values:''),
    (Name:'terrain.layout'; TagName:'rezvivo:environment_layout'; Category:'terrain'; Kind:kvObject; UnitName:''; MinValue:0; MaxValue:0; Values:''),
    (Name:'building.local'; TagName:'rezvivo:environment_layout'; Category:'building'; Kind:kvObject; UnitName:''; MinValue:0; MaxValue:0; Values:''),
    (Name:'road.oneway'; TagName:'oneway'; Category:'road'; Kind:kvEnum; UnitName:''; MinValue:0; MaxValue:0; Values:'|yes|no|-1|')
  );
function KnowledgePropertyIndex(const Name: string): Integer;
function KnowledgeTagIndex(const TagName, Category: string): Integer;
function KnowledgePropertySupported(const Name: string): Boolean;
function KnowledgePropertyCategory(const Name, Category: string): Boolean;
function CanonicalKnowledgeScalar(Index: Integer; Value: TJSONData;
  const UnitName: string): string;
implementation
uses Math, Osm3dTileKnowledge, TreeOsm, TreeModel;

function KnowledgePropertyIndex(const Name: string): Integer;
var I: Integer;
begin
  for I:=Low(KnowledgeProperties) to High(KnowledgeProperties) do
    if Name=KnowledgeProperties[I].Name then Exit(I);
  Result:=-1;
end;
function KnowledgeTagIndex(const TagName, Category: string): Integer;
var I: Integer;
begin
  for I:=Low(KnowledgeProperties) to High(KnowledgeProperties) do
    if (TagName=KnowledgeProperties[I].TagName) and
      (Category=KnowledgeProperties[I].Category) then Exit(I);
  Result:=-1;
end;
function KnowledgePropertySupported(const Name: string): Boolean;
begin Result:=KnowledgePropertyIndex(Name)>=0 end;
function KnowledgePropertyCategory(const Name, Category: string): Boolean;
var I: Integer;
begin
  I:=KnowledgePropertyIndex(Name);
  Result:=(I>=0) and (KnowledgeProperties[I].Category=Category);
end;
function CanonicalKnowledgeScalar(Index: Integer; Value: TJSONData;
  const UnitName: string): string;
var P: TKnowledgeProperty; V: Double; F: TFormatSettings; I: Integer;
  Taxon:TJSONObject; Classification:TTreeClassification;
  procedure Invalid(const Reason: string);
  begin raise ETileKnowledge.Create(P.Name+': '+Reason) end;
begin
  P:=KnowledgeProperties[Index];
  if Value=nil then Invalid('value is required');
  if UnitName<>P.UnitName then
    if not ((P.Kind=kvInteger) and (UnitName='') and (P.UnitName='storeys')) then
      Invalid('unit must be '+P.UnitName);
  if P.Kind in [kvNumber,kvInteger] then begin
    if Value.JSONType<>jtNumber then Invalid('numeric value required');
    V:=Value.AsFloat;
    if IsNan(V) or IsInfinite(V) or (V<P.MinValue) or (V>P.MaxValue) then Invalid('out of range');
    if (P.Kind=kvInteger) and (Frac(V)<>0) then Invalid('integer required');
    F:=DefaultFormatSettings; F.DecimalSeparator:='.';
    Exit(FloatToStr(V,F));
  end;
  if (Value.JSONType<>jtString) or (P.Kind=kvObject) then Invalid('string value required');
  Result:=LowerCase(Value.AsString);
  case P.Kind of
    kvEnum: if (Result='') or (Pos('|'+Result+'|',P.Values)=0) then Invalid('unsupported value '+Result);
    kvColor: begin
      if (Length(Result)<>7) or (Result[1]<>'#') then Invalid('must be #RRGGBB');
      for I:=2 to 7 do if not (Result[I] in ['0'..'9','a'..'f']) then Invalid('must be #RRGGBB');
    end;
    kvTaxon: begin
      { Scientific names are bounded ASCII text, not free-form renderer code. }
      if (Length(Result)<3) or (Length(Result)>96) or (Trim(Result)<>Result) then Invalid('invalid taxon');
      for I:=1 to Length(Result) do if not (Result[I] in ['a'..'z',' ','-','.']) then Invalid('Latin taxon required');
      Taxon:=TJSONObject.Create([P.TagName,Result]);
      try Classification:=ClassifyTreeJSON(Taxon.AsJSON,Default(TTreeWorldPosition)) finally Taxon.Free end;
      if Classification.Source='fallback' then Invalid('taxon has no supported procedural representation');
    end;
  end;
end;
end.
