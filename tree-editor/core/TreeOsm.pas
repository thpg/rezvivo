unit TreeOsm;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses TreeModel, TreeForestRegions;
type
  TTreeClassification = record
    TypeCode: TTreeTypeCode;
    Source, Taxon, Note: UTF8String;
    CandidateCount: Integer;
    Approximate: Boolean;
  end;
{ No database, clock, UI or GPU context is needed. Mixed forests use position
  to select a member of the sorted, deduplicated list, with equal weights. }
function ClassifyTreeJSON(const Text: UTF8String; const Position: TTreeWorldPosition): TTreeClassification; overload;
function ClassifyTreeJSON(const Text: UTF8String; const Position: TTreeWorldPosition;
  const ForestLocation: TForestLocation): TTreeClassification; overload;
function TreeGPUTypeFromJSON(const Text: UTF8String): TTreeTypeCode; overload;
function TreeGPUTypeFromJSON(const Text: UTF8String; const Position: TTreeWorldPosition): TTreeTypeCode; overload;
function NormalizeTreeTaxon(const Text: UTF8String): UTF8String;
implementation
uses SysUtils, Math, fpjson, jsonparser;
type
  TCandidate = record Species: TTreeSpecies; Taxon: UTF8String; Approximate: Boolean; Weight:Double; end;
  TCandidates = array of TCandidate;

function NormalizeTreeTaxon(const Text: UTF8String): UTF8String;
var U,V: UnicodeString; I,N: Integer; C: WideChar;
begin
  U:=UTF8Decode(Text); V:='';
  for I:=1 to Length(U) do begin
    N:=Ord(U[I]);
    if (N>=$300) and (N<=$36F) then Continue;
    if (N>=65) and (N<=90) then Inc(N,32);
    if (N>=1040) and (N<=1071) then Inc(N,32);
    if (N=1025) or (N=1105) then N:=1077;
    case N of
      192..197,224..229: N:=97;
      200..203,232..235: N:=101;
      204..207,236..239: N:=105;
      210..214,216,242..246,248: N:=111;
      217..220,249..252: N:=117;
      199,231: N:=99;
      256,257: N:=97; 274,275: N:=101; 298,299: N:=105;
      332,333: N:=111; 362,363: N:=117;
    end;
    { OSM includes Latin botanical names typed with a Cyrillic first letter,
      e.g. "Рinus". Correct confusables only next to an ASCII letter. }
    if ((I<Length(U)) and (Ord(U[I+1]) in [65..90,97..122])) or
      ((I>1) and (Ord(U[I-1]) in [65..90,97..122])) then
      case N of
        1072: N:=97; 1074: N:=98; 1077: N:=101; 1082: N:=107; 1084: N:=109;
        1085: N:=104; 1086: N:=111; 1088: N:=112; 1089: N:=99; 1090: N:=116;
        1091: N:=121; 1093: N:=120;
      end;
    C:=WideChar(N);
    if N<=32 then begin
      if (Length(V)>0) and (V[Length(V)]<>' ') then V:=V+' ';
    end else V:=V+C;
  end;
  Result:=Trim(UTF8Encode(V));
end;
function TaxonHash(const S: UTF8String): LongWord;
var I: Integer;
begin
  Result:=137;
  for I:=1 to Length(S) do Result:=Hash32(Result xor Ord(S[I]));
end;
function Starts(const S,Prefix: UTF8String): Boolean;
begin
  Result:=(Copy(S,1,Length(Prefix))=Prefix) and
    ((Length(S)=Length(Prefix)) or (S[Length(Prefix)+1] in [' ','.','_','-']));
end;
function Identify(const Name: UTF8String; out S: TTreeSpecies; out Approximate: Boolean): Boolean;
var T: TTreeSpecies;
begin
  Approximate:=False; Result:=True;
  for T:=Low(TTreeSpecies) to High(TTreeSpecies) do
    if SpeciesName(T)=Name then begin S:=T; Exit; end;
  if Starts(Name,'bambusa') or Starts(Name,'phyllostachys') or Starts(Name,'fargesia') or
    Starts(Name,'dendrocalamus') or Starts(Name,'sasa') or Starts(Name,'arundinaria') or
    Starts(Name,'bambusoideae') or Starts(Name,'bamboo') or Starts(Name,'бамбук') then S:=tsBamboo
  else if Starts(Name,'washingtonia') or Starts(Name,'trachycarpus') or Starts(Name,'chamaerops') or
    Starts(Name,'sabal') or Starts(Name,'livistona') or Starts(Name,'fan palm') or
    Starts(Name,'веерная пальма') then S:=tsFanPalm
  else if Starts(Name,'arecaceae') or Starts(Name,'palmae') or Starts(Name,'phoenix') or
    Starts(Name,'cocos') or Starts(Name,'syagrus') or Starts(Name,'roystonea') or
    Starts(Name,'elaeis') or Starts(Name,'areca') or Starts(Name,'butia') or
    Starts(Name,'palm') or Starts(Name,'пальма') or Starts(Name,'финик') then S:=tsPalm
  else if Starts(Name,'opuntia') or Starts(Name,'prickly pear') or Starts(Name,'опунция') then S:=tsPricklyPear
  else if Starts(Name,'carnegiea') or Starts(Name,'pachycereus') or Starts(Name,'cereus') or
    Starts(Name,'stenocereus') or Starts(Name,'cactaceae') or Starts(Name,'cactus') or
    Starts(Name,'saguaro') or Starts(Name,'кактус') then S:=tsCactus
  else if Starts(Name,'eucalyptus') or Starts(Name,'corymbia') or Starts(Name,'эвкалипт') then S:=tsEucalyptus
  else if Starts(Name,'acacia') or Starts(Name,'vachellia') or Starts(Name,'senegalia') then begin
    S:=tsAcacia;Approximate:=True; { umbrella / fine-leaved visual family }
  end
  else if Starts(Name,'quercus') or Starts(Name,'дуб') or Starts(Name,'english oak') then S:=tsOak
  else if Starts(Name,'acer negundo') or Starts(Name,'клен ясенелистный') or
    Starts(Name,'salix caprea') then begin S:=tsBroadleaf; Approximate:=True; end
  else if Starts(Name,'acer') or Starts(Name,'клен') or Starts(Name,'platanus') or Starts(Name,'платан') then S:=tsMaple
  else if Starts(Name,'betula') or Starts(Name,'береза') or Starts(Name,'березовый') then S:=tsBirch
  else if Starts(Name,'pinus mugo') or Starts(Name,'pinus montana') or Starts(Name,'pinus pumila') or
    Starts(Name,'горная сосна') or Starts(Name,'сосна горная') then S:=tsMountainPine
  else if Starts(Name,'pinus') or Starts(Name,'сосна') or Starts(Name,'pinetree') then S:=tsPine
  else if Starts(Name,'picea') or Starts(Name,'ель') or Starts(Name,'елка') or Starts(Name,'spruce') then S:=tsSpruce
  else if Starts(Name,'abies') or Starts(Name,'пихта') then begin S:=tsSpruce; Approximate:=True; end
  else if Starts(Name,'larix') or Starts(Name,'лиственница') then S:=tsLarch
  else if Starts(Name,'salix') or Starts(Name,'ива') or Starts(Name,'верба') then S:=tsWillow
  else if Starts(Name,'juniperus') or Starts(Name,'можжевельник') then S:=tsJuniper
  else if Starts(Name,'thuja') or Starts(Name,'туя') or Starts(Name,'cupressus') or
    Starts(Name,'chamaecyparis') or Starts(Name,'taxus') or Starts(Name,'тис') or
    Starts(Name,'cedrus') or Starts(Name,'кедр') or Starts(Name,'platycladus') or
    Starts(Name,'плосковеточник') or Starts(Name,'pinaceae') then begin
    S:=tsSpruce; Approximate:=True; { explicit temporary conifer fallback }
  end
  else if (Starts(Name,'populus') or Starts(Name,'тополь')) and
    ((Pos('italica',Name)>0) or (Pos('pyramid',Name)>0) or (Pos('пирамид',Name)>0)) then S:=tsColumnar
  else if Starts(Name,'sorbus') or Starts(Name,'рябина') or Starts(Name,'rowan') or
    Starts(Name,'mountain ash') then S:=tsRowan
  else if Starts(Name,'malus') or Starts(Name,'pyrus') or Starts(Name,'prunus') or
    Starts(Name,'cerasus') or Starts(Name,'armeniaca') or Starts(Name,'sorbus') or Starts(Name,'crataegus') or
    Starts(Name,'яблоня') or Starts(Name,'груша') or Starts(Name,'вишня') or
    Starts(Name,'слива') or Starts(Name,'абрикос') or Starts(Name,'рябина') or Starts(Name,'черемуха') or
    Starts(Name,'боярышник') or Starts(Name,'персик') or Starts(Name,'citrus') or
    Starts(Name,'olea') or Starts(Name,'juglans') or Starts(Name,'castanea') or
    Starts(Name,'apple') or Starts(Name,'pear') or Starts(Name,'cherry') or
    Starts(Name,'plum') or Starts(Name,'apricot') or Starts(Name,'peach') or
    Starts(Name,'hawthorn') or Starts(Name,'bird cherry') or Starts(Name,'walnut') or
    Starts(Name,'sweet chestnut') or Starts(Name,'olive') or Starts(Name,'orange') or
    Starts(Name,'грецкий орех') or Starts(Name,'орех') or Starts(Name,'каштан съедобный') or
    Starts(Name,'олива') or Starts(Name,'маслина') or Starts(Name,'апельсин') then S:=tsFruit
  else if Starts(Name,'syringa') or Starts(Name,'corylus') or Starts(Name,'rosa') or
    Starts(Name,'spiraea') or Starts(Name,'spirea') or Starts(Name,'cornus') or Starts(Name,'berberis') or
    Starts(Name,'cotoneaster') or Starts(Name,'physocarpus') or Starts(Name,'caragana') or
    Starts(Name,'sorbaria') or Starts(Name,'forsythia') or Starts(Name,'lonicera') or
    Starts(Name,'philadelphus') or Starts(Name,'euonymus') or Starts(Name,'hippophae') or
    Starts(Name,'viburnum') or Starts(Name,'ligustrum') or Starts(Name,'ribes') or
    Starts(Name,'сирень') or Starts(Name,'лещина') or Starts(Name,'шиповник') or
    Starts(Name,'спирея') or Starts(Name,'барбарис') or Starts(Name,'куст') or Starts(Name,'кизильник') or
    Starts(Name,'пузыреплодник') or Starts(Name,'дерен') or Starts(Name,'форзиция') or Starts(Name,'жимолость') then S:=tsShrub
  else if Starts(Name,'tilia') or Starts(Name,'linden') or Starts(Name,'ulmus') or Starts(Name,'fagus') or
    Starts(Name,'alnus') or Starts(Name,'populus') or Starts(Name,'carpinus') or
    Starts(Name,'fraxinus') or Starts(Name,'aesculus') or Starts(Name,'robinia') or
    Starts(Name,'juglans') or Starts(Name,'castanea') or Starts(Name,'catalpa') or Starts(Name,'arbutus') or Starts(Name,'липа') or
    Starts(Name,'вяз') or Starts(Name,'бук') or Starts(Name,'ольха') or Starts(Name,'тополь') or
    Starts(Name,'осина') or Starts(Name,'граб') or Starts(Name,'ясень') or
    Starts(Name,'каштан') or Starts(Name,'акация') or Starts(Name,'орех') then begin
    S:=tsBroadleaf; Approximate:=True;
  end else Result:=False;
  if Result then begin
    if S in [tsShrub,tsFruit,tsJuniper] then Approximate:=True;
    if Starts(Name,'platanus') or Starts(Name,'платан') or
      Starts(Name,'pinus sibirica') or Starts(Name,'pinus cembra') or Starts(Name,'pinus strobus') or
      Starts(Name,'pinus pumila') or Starts(Name,'quercus ilex') or Starts(Name,'quercus rubra') then Approximate:=True;
  end;
end;

function FruitTaxonKind(const Name:UTF8String):TTreeFruitKind;
begin
  Result:=tfApple;
  if Starts(Name,'pyrus') or Starts(Name,'груша') or Starts(Name,'pear') then Result:=tfPear
  else if Starts(Name,'prunus padus') or Starts(Name,'prunus serotina') or Starts(Name,'черемуха') or Starts(Name,'bird cherry') then Result:=tfBirdCherry
  else if Starts(Name,'prunus persica') or Starts(Name,'персик') or Starts(Name,'peach') then Result:=tfPeach
  else if Starts(Name,'prunus armeniaca') or Starts(Name,'armeniaca') or Starts(Name,'абрикос') or Starts(Name,'apricot') then Result:=tfApricot
  else if Starts(Name,'prunus domestica') or Starts(Name,'prunus cerasifera') or Starts(Name,'слива') or Starts(Name,'plum') then Result:=tfPlum
  else if Starts(Name,'prunus') or Starts(Name,'cerasus') or Starts(Name,'вишня') or Starts(Name,'cherry') then Result:=tfCherry
  else if Starts(Name,'crataegus') or Starts(Name,'боярышник') or Starts(Name,'hawthorn') then Result:=tfHawthorn
  else if Starts(Name,'juglans') or Starts(Name,'орех') or Starts(Name,'грецкий орех') or Starts(Name,'walnut') then Result:=tfWalnut
  else if Starts(Name,'castanea') or Starts(Name,'каштан') or Starts(Name,'sweet chestnut') then Result:=tfChestnut
  else if Starts(Name,'citrus') or Starts(Name,'orange') or Starts(Name,'апельсин') then Result:=tfCitrus
  else if Starts(Name,'olea') or Starts(Name,'olive') or Starts(Name,'олива') or Starts(Name,'маслина') then Result:=tfOlive;
end;
function ClassifyTreeJSON(const Text: UTF8String; const Position: TTreeWorldPosition): TTreeClassification;
begin Result:=ClassifyTreeJSON(Text,Position,Default(TForestLocation));end;
function ClassifyTreeJSON(const Text: UTF8String; const Position: TTreeWorldPosition;
  const ForestLocation: TForestLocation): TTreeClassification;
const Keys: array[0..17] of UTF8String = ('species','species:ru','species:en','taxon','taxon:species','taxon:ru',
  'taxon:en','genus','taxon:genus','genus:ru','genus:en','taxon:family','family','type','trees','tree','wood','leaf_type');
var Root,Part,TagData: TJSONData; Tags: TJSONObject; Candidates: TCandidates;
    I,J,K,Age,Variant,Selected: Integer; Value,Token,AgeText: UTF8String;
    Item,Temp: TCandidate; Instance: TTreeInstance; V,TotalWeight: Double; Unknown,Regional: Boolean;
    Mix:TForestMix; S:TTreeSpecies; Cycle,Wetland:UTF8String;
  function Tag(const Key: UTF8String): UTF8String;
  var D: TJSONData;
  begin
    D:=Tags.Find(Key); Result:='';
    if (D<>nil) and (D.JSONType in [jtString,jtNumber]) then Result:=D.AsString;
  end;
  procedure AddToken(const Name: UTF8String);
  var C: Integer;
  begin
    if Name='' then Exit;
    if not Identify(Name,Item.Species,Item.Approximate) then begin Unknown:=True; Exit; end;
    Item.Taxon:=Name;Item.Weight:=1;
    for C:=0 to High(Candidates) do if Candidates[C].Taxon=Name then Exit;
    if Length(Candidates)>=64 then raise EConvertError.Create('At most 64 taxa per tree JSON');
    SetLength(Candidates,Length(Candidates)+1); Candidates[High(Candidates)]:=Item;
  end;
begin
  Result:=Default(TTreeClassification);
  if Length(Text)>65536 then raise EConvertError.Create('Tree JSON exceeds 64 KiB');
  Root:=GetJSON(Text);
  try
    if Root.JSONType<>jtObject then raise EConvertError.Create('Tree JSON must be an object');
    Tags:=TJSONObject(Root); Part:=Tags.Find('elements');
    if Part<>nil then begin
      if (Part.JSONType<>jtArray) or (Part.Count<>1) or (Part.Items[0].JSONType<>jtObject) then
        raise EConvertError.Create('Pass exactly one OSM element, or its tags');
      Tags:=TJSONObject(Part.Items[0]);
    end;
    TagData:=Tags.Find('tags');
    if TagData<>nil then begin
      if TagData.JSONType<>jtObject then raise EConvertError.Create('tags must be an object');
      Tags:=TJSONObject(TagData);
    end;
    Part:=Tags.Find('gpu_type');
    if Part<>nil then begin
      if Part.JSONType<>jtNumber then raise EConvertError.Create('gpu_type must be an unsigned integer');
      V:=Part.AsFloat;
      if (V<0) or (V>High(LongWord)) or (V<>Int(V)) then raise EConvertError.Create('Invalid gpu_type');
      Result.TypeCode:=LongWord(Round(V)); ValidateTreeType(Result.TypeCode);
      Result.Source:='gpu_type'; Result.Taxon:=SpeciesName(TreeTypeSpecies(Result.TypeCode));
      Result.CandidateCount:=1; Exit;
    end;
    Unknown:=False;Regional:=False;
    for I:=Low(Keys) to High(Keys) do begin
      Value:=NormalizeTreeTaxon(Tag(Keys[I])); Token:='';
      if (Keys[I]='wood') and ((Value='mixed') or (Value='deciduous') or (Value='coniferous') or
        (Value='no') or (Value='sparse')) then Continue;
      if (Keys[I]='leaf_type') and (Value<>'palm') and (Value<>'bamboo') then Continue;
      for J:=1 to Length(Value)+1 do begin
        if (J>Length(Value)) or (Value[J] in [';',',','/','+']) then begin
          AddToken(Trim(Token)); Token:='';
        end else Token:=Token+Value[J];
      end;
      if Length(Candidates)>0 then begin Result.Source:=Keys[I]; Break; end;
    end;
    if (Length(Candidates)=0) and ForestLocation.Enabled and (Tag('barrier')<>'hedge') then begin
      Value:=NormalizeTreeTaxon(Tag('leaf_type'));if Value='' then Value:=NormalizeTreeTaxon(Tag('wood'));
      Cycle:=NormalizeTreeTaxon(Tag('leaf_cycle'));Wetland:=NormalizeTreeTaxon(Tag('wetland'));
      if Tag('natural')='scrub' then Mix:=RegionalScrubMix(ForestLocation)
      else Mix:=RegionalForestMix(ForestLocation,Value,Cycle,Wetland);
      for S:=Low(S) to High(S) do if Mix.Weights[S]>0 then begin
        SetLength(Candidates,Length(Candidates)+1);
        with Candidates[High(Candidates)] do begin
          Species:=S;Taxon:=SpeciesName(S);Approximate:=True;Weight:=Mix.Weights[S];
        end;
      end;
      Regional:=True;Result.Source:='regional';
      Result.Note:='Regional forest: '+Mix.Region+'; approximate visual proportions.';
    end;
    if Length(Candidates)=0 then begin
      SetLength(Candidates,1); Candidates[0].Approximate:=True;
      Candidates[0].Taxon:='unknown'; Candidates[0].Species:=tsBroadleaf;
      Value:=NormalizeTreeTaxon(Tag('leaf_type')); if Value='' then Value:=NormalizeTreeTaxon(Tag('wood'));
      if (Value='needleleaved') or (Value='coniferous') then Candidates[0].Species:=tsSpruce;
      if Value='mixed' then begin
        SetLength(Candidates,2); Candidates[1]:=Candidates[0];
        Candidates[1].Taxon:='unknown_conifer'; Candidates[1].Species:=tsSpruce;
      end;
      if (Tag('natural')='scrub') or (Tag('natural')='shrub') or
        (Tag('barrier')='hedge') or (Value='shrubs') then begin
        SetLength(Candidates,1); Candidates[0].Species:=tsShrub;
      end;
      Result.Source:='fallback';
      Result.Note:='Порода не определена: использована общая форма по тегам.';
    end;
    { Stable order makes "Picea;Betula" and "Betula;Picea" identical. }
    for I:=0 to High(Candidates)-1 do for J:=I+1 to High(Candidates) do
      if Candidates[I].Taxon>Candidates[J].Taxon then begin Temp:=Candidates[I]; Candidates[I]:=Candidates[J]; Candidates[J]:=Temp; end;
    Instance:=Default(TTreeInstance); Instance.Position:=Position;
    Selected:=SeedForTree(Instance) mod LongWord(Length(Candidates));
    if Regional then begin
      TotalWeight:=0;for I:=0 to High(Candidates) do TotalWeight+=Candidates[I].Weight;
      V:=(SeedForTree(Instance)/4294967296.0)*TotalWeight;Selected:=High(Candidates);
      for I:=0 to High(Candidates) do begin
        V-=Candidates[I].Weight;if V<0 then begin Selected:=I;Break;end;
      end;
    end;
    Item:=Candidates[Selected];
    Value:=NormalizeTreeTaxon(Tag('tree:shape')+' '+Tag('shape')+' '+Tag('crown:shape'));
    if (Item.Species in [tsOak,tsBirch,tsMaple,tsBroadleaf,tsFruit]) and
      ((Pos('columnar',Value)>0) or (Pos('fastigiate',Value)>0)) then
      Item.Species:=tsColumnar;
    Age:=0; AgeText:=NormalizeTreeTaxon(Tag('age'));
    if AgeText<>'' then begin
      Value:=AgeText;
      for K:=1 to Length(Value) do if not (Value[K] in ['0'..'9']) then begin Value:=Trim(Copy(Value,1,K-1)); Break; end;
      if not TryStrToInt(Value,Age) or (Age<1) or (Age>TREE_MAX_AGE) then
        raise EConvertError.Create('age must be 1 .. 4095 years');
      Value:=Trim(Copy(AgeText,Length(Value)+1,MaxInt));
      if (Value<>'') and (Value<>'years') and (Value<>'year') and (Value<>'лет') and (Value<>'года') and (Value<>'год') then
        raise EConvertError.Create('Unsupported age unit or range');
    end else begin
      AgeText:=NormalizeTreeTaxon(Tag('wood:age'));
      V:=0;
      if (AgeText='sapling') or (AgeText='very_young') then V:=0.07
      else if AgeText='young' then V:=0.22
      else if AgeText='pole' then V:=0.40
      else if AgeText='middle' then V:=0.70
      else if (AgeText='adult') or (AgeText='mature') then V:=1
      else if AgeText='old' then V:=1.8
      else if AgeText='old_growth' then V:=2.8;
      if V>0 then begin
        Age:=Max(1,Round(MatureTreeAge(Item.Species)*V));
        Result.Note:=Result.Note+' Возраст оценён по wood:age, это художественная шкала.';
      end else if AgeText<>'' then Result.Note:=Result.Note+' Неизвестный wood:age: возраст автоматически от позиции.';
    end;
    Variant:=TaxonHash(Item.Taxon) mod 255+1;
    if (Item.Taxon=SpeciesName(Item.Species)) or (Result.Source='fallback') then Variant:=0;
    if (Item.Species=tsFruit) and (Variant<>0) then
      Variant:=(TaxonHash(Item.Taxon) mod 15+1)*16+Ord(FruitTaxonKind(Item.Taxon));
    Result.TypeCode:=PackTreeType(Item.Species,Age,Variant);
    Result.Taxon:=Item.Taxon; Result.CandidateCount:=Length(Candidates);
    Result.Approximate:=Item.Approximate or Unknown;
    if Item.Approximate then Result.Note:=Result.Note+' Общая визуальная группа; точная ботаническая модель не заявлена.';
    if Unknown then Result.Note:=Result.Note+' Часть названий не распознана.';
    if (Result.CandidateCount>1) and not Regional then
      Result.Note:=Result.Note+' Смесь: выбор по позиции, равные доли (доли OSM не заданы).';
    Result.Note:=Trim(Result.Note);
  finally Root.Free; end;
end;
function TreeGPUTypeFromJSON(const Text: UTF8String; const Position: TTreeWorldPosition): TTreeTypeCode;
begin Result:=ClassifyTreeJSON(Text,Position).TypeCode; end;
function TreeGPUTypeFromJSON(const Text: UTF8String): TTreeTypeCode;
var Position: TTreeWorldPosition;
begin Position:=Default(TTreeWorldPosition); Result:=TreeGPUTypeFromJSON(Text,Position); end;
end.
