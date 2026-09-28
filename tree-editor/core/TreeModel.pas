unit TreeModel;
{$mode objfpc}{$H+}{$modeswitch advancedrecords}
interface
uses TreeMath;
const
  TREE_GENERATOR_VERSION = 4;
  TREE_BIRCH_GEOMETRY_VERSION = 1; { invalidate only birch LOD atlases }
  TREE_FRUIT_GEOMETRY_VERSION = 1;
  TREE_ROWAN_GEOMETRY_VERSION = 2; { open pinnate foliage and terminal bunches }
  TREE_REGIONAL_GEOMETRY_VERSION = 1;
  TREE_IDENTITY_VERSION = 1; { preserve position/type identity across profile upgrades }
  TREE_MAX_AGE = 4095;
  TREE_MAX_PRIMARY_BRANCHES = 48;
  TREE_LOD_DISTANCE_SCALE = 1.5;
  TREE_TYPE_USED_MASK = LongWord($0FFFFFFF);
type
  { Append new IDs: existing position/type hashes must remain stable. }
  TTreeSpecies = (tsOak, tsBirch, tsPine, tsWillow, tsMountainPine, tsSpruce, tsShrub, tsJuniper,
    tsMaple, tsBroadleaf, tsColumnar, tsFruit, tsLarch, tsRowan,
    tsBamboo, tsPalm, tsFanPalm, tsCactus, tsPricklyPear, tsEucalyptus, tsAcacia);
  { Fruit-family variant low nibble; other families retain their existing IDs. }
  TTreeFruitKind = (tfApple,tfPear,tfCherry,tfPlum,tfApricot,tfPeach,
    tfHawthorn,tfBirdCherry,tfWalnut,tfChestnut,tfCitrus,tfOlive,
    tfCone,tfRowan,tfJuniper);
  TTreeTypeCode = LongWord; { 8 family + 12 years (0=automatic) + 8 variant + 4 reserved }
  TTreeWorldPosition = record X, Y, Z: Double; end;
  TTreeInstance = record
    Position: TTreeWorldPosition;
    TypeCode: TTreeTypeCode;
    function GetSpecies: TTreeSpecies;
    procedure SetSpecies(Value: TTreeSpecies);
    property Species: TTreeSpecies read GetSpecies write SetSpecies;
  end;
  TTreeParams = record
    Seed: LongWord; { internal derived value; never an input of a world instance }
    Species: TTreeSpecies;
    TypeCode: TTreeTypeCode; { resolved runtime values, not editable profile fields }
    AgeYears: Integer;
    Maturity: Single;
    Height, TrunkRadius, CrownSpread, CrownStart, BranchAngle: Single;
    HeightVariation, NeedleLength, NeedleWidth: Single;
    Irregularity, LeafSize, LeafDensity, Droop: Single;
    PrimaryBranches, MaxDepth: Integer;
    BarkColor, LeafColor: TTreeVec3; { linear RGB, before lighting and display gamma }
  end;
  TTreeBranch = record
    ID: LongWord;
    Parent, Depth: Integer;
    Attach: Single;
    Start, Control, Tip: TTreeVec3;
    Radius, TipRadius: Single;
  end;
  TTreeBranches = array of TTreeBranch;
  TTreeLeaf = record
    Center, Axis: TTreeVec3;
    Size, Aspect, Phase: Single;
  end;
  TTreeLeaves = array of TTreeLeaf;
  TTreeNeedleShoot = record
    Start, Control, Tip: TTreeVec3;
    Radius, NeedleLength, NeedleWidth, Phase: Single;
  end;
  TTreeNeedleShoots = array of TTreeNeedleShoot;
  TTreeCrown = record
    Center, Radius: TTreeVec3;
    Phase: Single;
  end;
  TTreeCrowns = array of TTreeCrown;
  TTreeFruit = record
    Center,Axis,Color: TTreeVec3;
    Radius,HalfLength,Phase: Single;
    Kind:TTreeFruitKind;
  end;
  TTreeFruits = array of TTreeFruit;
  TTreeData = record
    Params: TTreeParams;
    Branches: TTreeBranches;
    Leaves: TTreeLeaves;
    NeedleShoots: TTreeNeedleShoots; { compact stems; individual needles exist only on GPU }
    Crowns: TTreeCrowns;
    Fruits: TTreeFruits; { bounded branch-attached descriptors, geometry on GPU }
    BoundsMin, BoundsMax: TTreeVec3;
    Fingerprint: LongWord;
  end;
function Hash32(X: LongWord): LongWord;
function HashChild(Parent: LongWord; Index: Integer): LongWord;
function HashUnit(Seed: LongWord; Channel: Integer): Single;
function PackTreeType(Species: TTreeSpecies; AgeYears: Integer = 0; Variant: Integer = 0): TTreeTypeCode;
procedure ValidateTreeType(Code: TTreeTypeCode);
function TreeTypeSpecies(Code: TTreeTypeCode): TTreeSpecies;
function TreeTypeAge(Code: TTreeTypeCode): Integer;
function TreeTypeVariant(Code: TTreeTypeCode): Integer;
function MatureTreeAge(Species: TTreeSpecies): Integer;
function SpeciesName(S: TTreeSpecies): string;
function SpeciesFromName(const S: string): TTreeSpecies;
function IsConifer(S: TTreeSpecies): Boolean;
function IsShrub(S: TTreeSpecies): Boolean;
function HasTreeFruit(S: TTreeSpecies): Boolean;
function TreeFruitKind(Code:TTreeTypeCode):TTreeFruitKind;
function NeedlesPerFascicle(S: TTreeSpecies): Integer;
function DefaultTreeParams(S: TTreeSpecies): TTreeParams;
procedure ValidateTreeParams(const P: TTreeParams);
function SeedForTree(const Instance: TTreeInstance): LongWord;
function ResolveTreeParams(const Instance: TTreeInstance; const Profile: TTreeParams): TTreeParams;
function NeedlePairsPerShoot(Density: Single): Integer;
function GenerateTreeAt(const Instance: TTreeInstance; const Profile: TTreeParams;
  DetailDepth: Integer = -1; IncludeLeaves: Boolean = True): TTreeData;
function TreeQuality(Distance, Height: Single): Single;
function TreeLODSize(const Resolved: TTreeParams): Single;
function BranchGrowth(Depth: Integer; Quality: Single): Single;
implementation
uses SysUtils, Math, TreeFruits, TreeRegionalPlants;

function PackTreeType(Species: TTreeSpecies; AgeYears: Integer; Variant: Integer): TTreeTypeCode;
begin
  if (Ord(Species)<0) or (Ord(Species)>Ord(High(TTreeSpecies))) then raise ERangeError.Create('Invalid tree family');
  if (AgeYears<0) or (AgeYears>TREE_MAX_AGE) then raise ERangeError.Create('Age must be 0 .. 4095 years');
  if (Variant<0) or (Variant>255) then raise ERangeError.Create('Variant must be 0 .. 255');
  Result:=LongWord(Ord(Species)) or (LongWord(AgeYears) shl 8) or (LongWord(Variant) shl 20);
end;
procedure ValidateTreeType(Code: TTreeTypeCode);
begin
  if (Code and not TREE_TYPE_USED_MASK)<>0 then raise ERangeError.Create('Reserved tree bits must be zero');
  if (Code and 255)>Ord(High(TTreeSpecies)) then raise ERangeError.Create('Unknown GPU tree family');
end;
function TreeTypeSpecies(Code: TTreeTypeCode): TTreeSpecies;
begin ValidateTreeType(Code); Result:=TTreeSpecies(Code and 255); end;
function TreeTypeAge(Code: TTreeTypeCode): Integer;
begin Result:=(Code shr 8) and 4095; end;
function TreeTypeVariant(Code: TTreeTypeCode): Integer;
begin Result:=(Code shr 20) and 255; end;
function TTreeInstance.GetSpecies: TTreeSpecies;
begin Result:=TreeTypeSpecies(TypeCode); end;
procedure TTreeInstance.SetSpecies(Value: TTreeSpecies);
begin
  if (TypeCode and 255)=Ord(Value) then Exit;
  TypeCode:=PackTreeType(Value,TreeTypeAge(TypeCode));
end;
function MatureTreeAge(Species: TTreeSpecies): Integer;
const Ages: array[TTreeSpecies] of Integer = (80,35,55,30,35,60,8,25,45,45,30,20,50,25,
  4,35,30,75,12,35,30);
begin Result:=Ages[Species]; end;

{$push}{$Q-}{$R-}
function Hash32(X: LongWord): LongWord;
begin
  X := (X xor (X shr 16)) * LongWord($7FEB352D);
  X := (X xor (X shr 15)) * LongWord($846CA68B);
  Result := X xor (X shr 16);
end;
function HashChild(Parent: LongWord; Index: Integer): LongWord;
begin Result := Hash32(Parent xor Hash32(LongWord(Index)+$9E3779B9)); end;
function HashUnit(Seed: LongWord; Channel: Integer): Single;
begin Result := (HashChild(Seed,Channel) shr 8) * (1.0/16777216.0); end;
{$pop}
function SeedForTree(const Instance: TTreeInstance): LongWord;
  procedure Coordinate(V: Double);
  var Q: Int64; U: QWord;
  begin
    if IsNan(V) or IsInfinite(V) or (Abs(V)>1e7) then
      raise ERangeError.Create('World coordinates must be finite and within +/- 10000000 m');
    Q:=Round(V*100); Move(Q,U,SizeOf(U));
    Result:=Hash32(Result xor Hash32(LongWord(U and $FFFFFFFF)));
    Result:=Hash32(Result xor Hash32(LongWord(U shr 32)));
  end;
begin
  if (Ord(Instance.Species)<0) or (Ord(Instance.Species)>Ord(High(TTreeSpecies))) then raise ERangeError.Create('Invalid species');
  Result:=Hash32(LongWord(Ord(Instance.Species))+TREE_IDENTITY_VERSION*137);
  if TreeTypeVariant(Instance.TypeCode)<>0 then
    Result:=Hash32(Result xor HashChild(TreeTypeVariant(Instance.TypeCode),8123));
  Coordinate(Instance.Position.X); Coordinate(Instance.Position.Y); Coordinate(Instance.Position.Z);
end;
function SpeciesName(S: TTreeSpecies): string;
const Names: array[TTreeSpecies] of string = ('oak','birch','pine','willow','mountain_pine','spruce','shrub','juniper',
  'maple','broadleaf','columnar','fruit','larch','rowan',
  'bamboo','palm','fan_palm','cactus','prickly_pear','eucalyptus','acacia');
begin Result:=Names[S]; end;
function SpeciesFromName(const S: string): TTreeSpecies;
begin
  for Result:=Low(TTreeSpecies) to High(TTreeSpecies) do
    if SpeciesName(Result)=S then Exit;
  raise EConvertError.Create('Unknown species: '+S);
end;
function IsConifer(S: TTreeSpecies): Boolean;
begin Result:=S in [tsPine,tsMountainPine,tsSpruce,tsJuniper,tsLarch]; end;
function IsShrub(S: TTreeSpecies): Boolean;
begin Result:=S in [tsShrub,tsJuniper,tsPricklyPear]; end;
function HasTreeFruit(S:TTreeSpecies):Boolean;
begin Result:=IsConifer(S) or (S in [tsFruit,tsRowan]);end;
function TreeFruitKind(Code:TTreeTypeCode):TTreeFruitKind;
var K:Integer;S:TTreeSpecies;
begin
  S:=TreeTypeSpecies(Code);
  if S=tsRowan then Exit(tfRowan);
  if S=tsJuniper then Exit(tfJuniper);
  if IsConifer(S) then Exit(tfCone);
  K:=TreeTypeVariant(Code) and 15;
  if K>Ord(tfOlive) then K:=0;
  Result:=TTreeFruitKind(K);
end;
function NeedlesPerFascicle(S: TTreeSpecies): Integer;
begin
  case S of
    tsPine,tsMountainPine: Result:=2;
    tsSpruce: Result:=1;
    tsJuniper: Result:=3;
    tsLarch: Result:=8; { compact radial rosette, expanded only by the shader }
    else Result:=0;
  end;
end;
function DefaultTreeParams(S: TTreeSpecies): TTreeParams;
const LeafDisplayRGB: array[TTreeSpecies] of LongWord = (
  $4F6D39, { oak: deep, slightly warm green }
  $729448, { birch: lighter fresh green }
  $547B70, { Scots pine: muted blue-green }
  $789073, { willow: soft gray-green, silvery underside in the shader }
  $355B3E, { mountain pine: dark forest green }
  $315E4B, { Norway spruce: deep cool green }
  $648447, { broadleaf shrub: warm medium green }
  $6A918F, { juniper: glaucous gray / blue-green }
  $3D743D, { Norway maple: saturated leaf green }
  $527B45, { general broadleaf: balanced middle green }
  $5F8740, { columnar poplar: fresh yellow-green }
  $687D4F, { fruit group: muted apple-leaf green }
  $7BAC56, { larch: bright light green }
  $587D3D, { rowan: pinnate leaves }
  $54793F, $4D793F, $627C49, $527D5A, $668365, $718B79, $738044
);
var RGB: LongWord;
begin
  Result:=Default(TTreeParams); Result.Seed:=78241; Result.Species:=S;
  Result.Height:=12; Result.HeightVariation:=0.25;
  Result.NeedleLength:=0.12; Result.NeedleWidth:=0.003;
  Result.TrunkRadius:=0.27; Result.CrownSpread:=0.85;
  Result.CrownStart:=0.30; Result.BranchAngle:=56; Result.Irregularity:=0.32;
  Result.LeafSize:=0.24; Result.LeafDensity:=1; Result.Droop:=0.05;
  Result.PrimaryBranches:=18; Result.MaxDepth:=4;
  Result.BarkColor:=Vec(0.29,0.20,0.13);
  case S of
    tsOak: begin
      Result.Height:=14; Result.TrunkRadius:=0.43; Result.CrownSpread:=1.12;
      Result.CrownStart:=0.26; Result.BranchAngle:=68; Result.Irregularity:=0.68;
      Result.LeafSize:=0.095; Result.LeafDensity:=2.3; Result.PrimaryBranches:=16;
    end;
    tsBirch: begin
      Result.Height:=15; Result.TrunkRadius:=0.15; Result.CrownSpread:=0.72;
      Result.CrownStart:=0.30; Result.BranchAngle:=58; Result.PrimaryBranches:=28;
      Result.Irregularity:=0.46; Result.LeafSize:=0.15; Result.LeafDensity:=1.15;
      Result.Droop:=0.28;
      Result.BarkColor:=Vec(0.80,0.81,0.72);
    end;
    tsPine: begin
      Result.Height:=16; Result.TrunkRadius:=0.23; Result.CrownSpread:=0.66;
      Result.CrownStart:=0.14; Result.BranchAngle:=82; Result.PrimaryBranches:=34;
      Result.LeafSize:=0.25; Result.LeafDensity:=2.6; Result.Droop:=0.03;
      Result.BarkColor:=Vec(0.35,0.20,0.12);
    end;
    tsWillow: begin
      Result.Height:=11; Result.TrunkRadius:=0.30; Result.CrownSpread:=1.10;
      Result.CrownStart:=0.44; Result.BranchAngle:=57; Result.Droop:=0.78;
      Result.LeafSize:=0.29; Result.PrimaryBranches:=20;
    end;
    tsMountainPine: begin
      Result.Height:=3.6; Result.TrunkRadius:=0.17; Result.CrownSpread:=1.45;
      Result.CrownStart:=0.08; Result.BranchAngle:=68; Result.PrimaryBranches:=22;
      Result.Irregularity:=0.85; Result.Droop:=0.12;
      Result.NeedleLength:=0.085; Result.NeedleWidth:=0.003; Result.LeafDensity:=2.5;
      Result.BarkColor:=Vec(0.29,0.22,0.16);
    end;
    tsSpruce: begin
      Result.Height:=14; Result.TrunkRadius:=0.23; Result.CrownSpread:=0.72;
      Result.CrownStart:=0.055; Result.BranchAngle:=82; Result.PrimaryBranches:=48;
      Result.Irregularity:=0.28; Result.Droop:=0.30;
      Result.NeedleLength:=0.035; Result.NeedleWidth:=0.0024; Result.LeafDensity:=3;
      Result.BarkColor:=Vec(0.25,0.18,0.12);
    end;
    tsShrub: begin
      Result.Height:=1.6; Result.TrunkRadius:=0.045; Result.CrownSpread:=1.55;
      Result.CrownStart:=0.035; Result.BranchAngle:=53; Result.PrimaryBranches:=14;
      Result.Irregularity:=0.52; Result.Droop:=0.10; Result.MaxDepth:=3;
      Result.LeafSize:=0.075; Result.LeafDensity:=2.2;
      Result.BarkColor:=Vec(0.26,0.18,0.10);
    end;
    tsJuniper: begin
      Result.Height:=1.1; Result.TrunkRadius:=0.055; Result.CrownSpread:=1.65;
      Result.CrownStart:=0.03; Result.BranchAngle:=73; Result.PrimaryBranches:=12;
      Result.Irregularity:=0.65; Result.Droop:=0.12; Result.MaxDepth:=3;
      Result.NeedleLength:=0.017; Result.NeedleWidth:=0.0015; Result.LeafDensity:=2.6;
      Result.BarkColor:=Vec(0.30,0.19,0.12);
    end;
    tsMaple: begin
      Result.Height:=13; Result.TrunkRadius:=0.25; Result.CrownSpread:=0.84;
      Result.CrownStart:=0.34; Result.BranchAngle:=50; Result.Irregularity:=0.23;
      Result.PrimaryBranches:=22; Result.LeafSize:=0.12; Result.LeafDensity:=2.1;
      Result.BarkColor:=Vec(0.32,0.30,0.24);
    end;
    tsBroadleaf: begin
      Result.Height:=15; Result.CrownSpread:=0.78; Result.BranchAngle:=49;
      Result.LeafSize:=0.10; Result.LeafDensity:=2.1; Result.PrimaryBranches:=22;
    end;
    tsColumnar: begin
      Result.Height:=22; Result.TrunkRadius:=0.31; Result.CrownSpread:=0.32;
      Result.CrownStart:=0.12; Result.BranchAngle:=23; Result.PrimaryBranches:=28;
      Result.LeafSize:=0.105; Result.LeafDensity:=2.2; Result.Irregularity:=0.20;
    end;
    tsFruit: begin
      Result.Height:=5; Result.TrunkRadius:=0.15; Result.CrownSpread:=1.10;
      Result.CrownStart:=0.23; Result.BranchAngle:=58; Result.PrimaryBranches:=14;
      Result.LeafSize:=0.075; Result.LeafDensity:=2.0; Result.Irregularity:=0.45;
    end;
    tsLarch: begin
      Result.Height:=19; Result.TrunkRadius:=0.24; Result.CrownSpread:=0.58;
      Result.CrownStart:=0.17; Result.BranchAngle:=83; Result.PrimaryBranches:=28;
      Result.Irregularity:=0.24; Result.Droop:=0.35;
      Result.NeedleLength:=0.035; Result.NeedleWidth:=0.0012; Result.LeafDensity:=0.75;
      Result.BarkColor:=Vec(0.32,0.23,0.17);
    end;
    tsRowan: begin
      Result.Height:=9;Result.TrunkRadius:=0.14;Result.CrownSpread:=1.18;
      Result.CrownStart:=0.24;Result.BranchAngle:=63;Result.PrimaryBranches:=18;
      Result.Irregularity:=0.42;Result.Droop:=0.18;
      Result.LeafSize:=0.14;Result.LeafDensity:=1.25;
      Result.BarkColor:=ColorToLinear(Vec(0.43,0.44,0.38));
    end;
  end;
  { Authored summer swatches, informed by botanical descriptions; see
    research/FOLIAGE-COLORS.md. No palette file is needed at runtime. }
  case S of
    tsBamboo: begin
      Result.Height:=7; Result.TrunkRadius:=0.055; Result.CrownSpread:=0.45;
      Result.CrownStart:=0.38; Result.PrimaryBranches:=9; Result.MaxDepth:=2;
      Result.LeafSize:=0.18; Result.LeafDensity:=1.4; Result.Droop:=0.15;
      Result.BarkColor:=ColorToLinear(Vec(0.38,0.49,0.22));
    end;
    tsPalm,tsFanPalm: begin
      Result.Height:=10; Result.TrunkRadius:=0.22; Result.CrownSpread:=0.80;
      Result.CrownStart:=0.75; Result.PrimaryBranches:=18; Result.MaxDepth:=2;
      Result.LeafSize:=0.48; Result.LeafDensity:=1.3; Result.Droop:=0.55;
      Result.BarkColor:=ColorToLinear(Vec(0.42,0.36,0.27));
      if S=tsFanPalm then begin Result.Height:=8;Result.CrownSpread:=0.68;end;
    end;
    tsCactus: begin
      Result.Height:=5.5; Result.TrunkRadius:=0.25; Result.CrownSpread:=0.50;
      Result.PrimaryBranches:=4; Result.MaxDepth:=1; Result.LeafDensity:=0;
      Result.BarkColor:=ColorToLinear(Vec(0.32,0.46,0.32));
    end;
    tsPricklyPear: begin
      Result.Height:=1.8; Result.TrunkRadius:=0.08; Result.CrownSpread:=1.10;
      Result.PrimaryBranches:=7; Result.MaxDepth:=3; Result.LeafDensity:=0;
      Result.BarkColor:=ColorToLinear(Vec(0.40,0.47,0.30));
    end;
    tsEucalyptus: begin
      Result.Height:=20; Result.TrunkRadius:=0.33; Result.CrownSpread:=0.70;
      Result.CrownStart:=0.48; Result.BranchAngle:=52; Result.Droop:=0.48;
      Result.PrimaryBranches:=16; Result.LeafSize:=0.17; Result.LeafDensity:=1.35;
      Result.BarkColor:=ColorToLinear(Vec(0.66,0.66,0.55));
    end;
    tsAcacia: begin
      Result.Height:=7; Result.TrunkRadius:=0.24; Result.CrownSpread:=1.60;
      Result.CrownStart:=0.55; Result.BranchAngle:=84; Result.PrimaryBranches:=16;
      Result.LeafSize:=0.16; Result.LeafDensity:=1.7; Result.Droop:=0.02;
      Result.BarkColor:=ColorToLinear(Vec(0.32,0.29,0.23));
    end;
  end;
  RGB:=LeafDisplayRGB[S];
  Result.LeafColor:=ColorToLinear(Vec(((RGB shr 16) and 255)/255,((RGB shr 8) and 255)/255,(RGB and 255)/255));
end;
procedure ValidateTreeParams(const P: TTreeParams);
  procedure Check(X, Lo, Hi: Single; const Name: string);
  begin
    if IsNan(X) or IsInfinite(X) or (X<Lo) or (X>Hi) then
      raise ERangeError.CreateFmt('%s must be within %g .. %g',[Name,Lo,Hi]);
  end;
begin
  if (Ord(P.Species)<0) or (Ord(P.Species)>Ord(High(TTreeSpecies))) then raise ERangeError.Create('Invalid species');
  Check(P.Height,0.3,40,'Height'); Check(P.TrunkRadius,0.005,1.5,'Trunk radius');
  Check(P.HeightVariation,0,0.5,'Height variation');
  Check(P.NeedleLength,0.008,0.30,'Needle length'); Check(P.NeedleWidth,0.001,0.008,'Needle width');
  Check(P.CrownSpread,0.15,1.8,'Crown spread'); Check(P.CrownStart,0.02,0.75,'Crown start');
  Check(P.BranchAngle,15,100,'Branch angle'); Check(P.Irregularity,0,1,'Irregularity');
  Check(P.LeafSize,0.02,0.65,'Leaf size'); Check(P.LeafDensity,0,3,'Leaf density');
  Check(P.Droop,0,1,'Droop');
  if (P.PrimaryBranches<4) or (P.PrimaryBranches>TREE_MAX_PRIMARY_BRANCHES) then
    raise ERangeError.CreateFmt('Primary branches must be 4 .. %d',[TREE_MAX_PRIMARY_BRANCHES]);
  if (P.MaxDepth<1) or (P.MaxDepth>4) then raise ERangeError.Create('Depth must be 1 .. 4');
  Check(P.BarkColor.X,0,1,'Bark red'); Check(P.BarkColor.Y,0,1,'Bark green'); Check(P.BarkColor.Z,0,1,'Bark blue');
  Check(P.LeafColor.X,0,1,'Leaf red'); Check(P.LeafColor.Y,0,1,'Leaf green'); Check(P.LeafColor.Z,0,1,'Leaf blue');
end;
function ResolveTreeParams(const Instance: TTreeInstance; const Profile: TTreeParams): TTreeParams;
var Factor,Ratio,Growth,Youth,Old: Single; Age: Integer; AgeExponent: Double;
begin
  ValidateTreeParams(Profile);
  if Instance.Species<>Profile.Species then raise EArgumentException.Create('Instance type and profile differ');
  Result:=Profile; Result.Seed:=SeedForTree(Instance);
  Age:=TreeTypeAge(Instance.TypeCode);
  if Age=0 then begin
    { With no age tag, about 90% of trees should be mature. Keep the same
      species-relative range and a small young population; do not stretch
      every tree or change explicitly aged instances / baked LOD samples. }
    if IsShrub(Profile.Species) then AgeExponent:=0.7 else AgeExponent:=0.3;
    Age:=Max(1,Round(MatureTreeAge(Profile.Species)*
      (0.16+Power(HashUnit(Result.Seed,8402),AgeExponent)*1.65)));
  end;
  Ratio:=Age/MatureTreeAge(Profile.Species);
  Result.AgeYears:=Age; Result.Maturity:=Ratio;
  Result.TypeCode:=PackTreeType(Profile.Species,Age,TreeTypeVariant(Instance.TypeCode));
  Growth:=(1-Exp(-3*Ratio))/(1-Exp(-3));
  Youth:=Clamp(1-Ratio,0,1); Old:=Clamp((Ratio-1)/2,0,1);
  Factor:=1+(HashUnit(Result.Seed,8401)*2-1)*Profile.HeightVariation;
  Result.Height:=Profile.Height*Factor*Growth;
  Result.TrunkRadius:=Profile.TrunkRadius*Power(Factor,0.8)*Power(Growth,1.3)*(1+Old*0.75);
  Result.CrownSpread:=Profile.CrownSpread*(1-Youth*0.36+Old*0.18);
  Result.BranchAngle:=Profile.BranchAngle*(1-Youth*0.24);
  Result.Irregularity:=Clamp(Profile.Irregularity*(1-Youth*0.55)+Old*0.20,0,1);
  Result.CrownStart:=Max(0.02,Profile.CrownStart*(1-Youth*0.45));
  Result.PrimaryBranches:=Max(4,Round(Profile.PrimaryBranches*(1-Youth*0.55)));
  if Ratio<0.14 then Result.MaxDepth:=Min(Result.MaxDepth,2)
  else if Ratio<0.40 then Result.MaxDepth:=Min(Result.MaxDepth,3);
  Result.LeafSize:=Profile.LeafSize*(0.62+0.38*Min(1,Growth));
  Result.NeedleLength:=Profile.NeedleLength*(0.75+0.25*Min(1,Growth));
  if IsConifer(Profile.Species) and not IsShrub(Profile.Species) then
    Result.CrownStart:=Min(0.55,Result.CrownStart+Old*0.13);
  if Profile.Species=tsOak then begin
    Result.CrownSpread:=Result.CrownSpread*(1+Old*0.12);
    Result.BranchAngle:=Min(93,Result.BranchAngle+Old*12);
  end;
  Result.LeafDensity:=Profile.LeafDensity*(1-Old*0.13);
end;
function NeedlePairsPerShoot(Density: Single): Integer;
begin Result:=Max(0,Min(128,Round(Density*40))); end;
function BranchGrowth(Depth: Integer; Quality: Single): Single;
var T, Start: Single;
begin
  if Depth=0 then Exit(1);
  Start:=0.2+(Depth-1)*0.8;
  T:=Clamp((Quality-Start)/0.8,0,1); Result:=T*T*(3-2*T);
end;
function TreeQuality(Distance, Height: Single): Single;
begin
  Result:=Clamp(4-1.7*Ln(Max(0.01,Distance)/(Max(1,Height*1.9)*TREE_LOD_DISTANCE_SCALE))/Ln(2),0,4);
end;
function TreeLODSize(const Resolved: TTreeParams): Single;
begin
  Result:=Resolved.Height;
  if IsShrub(Resolved.Species) or (Resolved.Species=tsMountainPine) then
    Result:=Result*Max(1,Resolved.CrownSpread*1.25);
end;

function GenerateTree(const P: TTreeParams; DetailDepth: Integer; IncludeLeaves: Boolean): TTreeData;
var Data: TTreeData; BC,LC,CC,NC,I,J,N,First,Last,Dep,ParentIndex: Integer;
    StemCount,StemIndex,BranchIndex,BranchesOnStem,PrimaryFirst,PrimaryLast: Integer;
    B,Parent: TTreeBranch; Leaf: TTreeLeaf; Crown: TTreeCrown;
    Shoot: TTreeNeedleShoot;
    Seed: LongWord; T,A,Len,Envelope,Pitch,R,Size,Tw,BendAngle,CrownBase: Single;
    Dir,Side,Up,Center: TTreeVec3;
  procedure Bounds(const V: TTreeVec3; Radius: Single);
  begin
    Data.BoundsMin.X:=Min(Data.BoundsMin.X,V.X-Radius);
    Data.BoundsMin.Y:=Min(Data.BoundsMin.Y,V.Y-Radius);
    Data.BoundsMin.Z:=Min(Data.BoundsMin.Z,V.Z-Radius);
    Data.BoundsMax.X:=Max(Data.BoundsMax.X,V.X+Radius);
    Data.BoundsMax.Y:=Max(Data.BoundsMax.Y,V.Y+Radius);
    Data.BoundsMax.Z:=Max(Data.BoundsMax.Z,V.Z+Radius);
  end;
  procedure AddBranch(const Item: TTreeBranch);
  begin
    if BC>=Length(Data.Branches) then SetLength(Data.Branches,Max(64,BC*2));
    Data.Branches[BC]:=Item; Inc(BC);
    Bounds(Item.Start,Item.Radius); Bounds(Item.Control,Item.Radius); Bounds(Item.Tip,Item.Radius);
  end;
  procedure AddLeaf(const Item: TTreeLeaf);
  begin
    if LC>=Length(Data.Leaves) then SetLength(Data.Leaves,Max(256,LC*2));
    Data.Leaves[LC]:=Item; Inc(LC); Bounds(Item.Center,Item.Size);
  end;
  function MakeBranch(AParent, Depth: Integer; ID: LongWord; Attach: Single;
    const Start,Direction: TTreeVec3; LengthM,RadiusM: Single): TTreeBranch;
  var Bend: TTreeVec3;
  begin
    Result:=Default(TTreeBranch); Result.ID:=ID; Result.Parent:=AParent;
    Result.Depth:=Depth; Result.Attach:=Attach; Result.Start:=Start;
    Result.Tip:=Add(Start,Scale(Direction,LengthM));
    Bend:=Vec((HashUnit(ID,12)-0.5)*P.Irregularity*LengthM*0.55,
      LengthM*0.16, (HashUnit(ID,13)-0.5)*P.Irregularity*LengthM*0.55);
    Result.Control:=Add(Mix(Start,Result.Tip,0.5),Bend);
    if (P.Species=tsOak) and (Depth>0) then begin
      { Heavy crooked scaffold limbs; the curvature is inherited by finer wood. }
      Result.Control:=Add(Result.Control,Vec((HashUnit(ID,18)-0.5)*LengthM*P.Irregularity*0.65,
        LengthM*(HashUnit(ID,19)-0.40)*0.45,(HashUnit(ID,21)-0.5)*LengthM*P.Irregularity*0.65));
    end;
    if (P.Species=tsMountainPine) and (Depth>0) then begin
      Result.Control:=Add(Result.Control,Vec(Cos(BendAngle)*LengthM*0.36,
        LengthM*(0.2+HashUnit(ID,14)*0.25),Sin(BendAngle)*LengthM*0.36));
    end;
    if (P.Species in [tsSpruce,tsLarch]) and (Depth>0) then
      Result.Control.Y:=Result.Control.Y-LengthM*(0.30+(HashUnit(ID,22)-0.5)*0.30*P.Irregularity);
    if Depth>=2 then Result.Tip.Y:=Result.Tip.Y-P.Droop*LengthM*(0.45+Depth*0.15);
    Result.Tip.Y:=Max(Min(0.18,P.Height*0.035),Result.Tip.Y);
    if P.Species in [tsSpruce,tsLarch] then Result.Control.Y:=Max(P.Height*0.006,Result.Control.Y);
    Result.Radius:=RadiusM; Result.TipRadius:=RadiusM*0.18;
  end;
  procedure FingerprintValue(V: Single);
  var Bits: LongWord;
  begin Move(V,Bits,SizeOf(Bits)); Data.Fingerprint:=Hash32(Data.Fingerprint xor Bits); end;
  function AcaciaPoint(const V:TTreeVec3):TTreeVec3;
  begin
    Result:=V;
    if V.Y>P.Height*0.55 then Result.Y:=P.Height*0.55+(V.Y-P.Height*0.55)*0.28;
  end;
begin
  { P is resolved from a validated profile. Its sampled height may exceed the
    nominal profile limits; never clamp it here or distant/near trees disagree. }
  Data:=Default(TTreeData); Data.Params:=P;
  if P.Species in [tsBamboo,tsPalm,tsFanPalm,tsCactus,tsPricklyPear] then
    Exit(GenerateRegionalPlant(P,IncludeLeaves));
  if DetailDepth<0 then DetailDepth:=P.MaxDepth;
  DetailDepth:=Max(1,Min(P.MaxDepth,DetailDepth));
  BC:=0; LC:=0; CC:=0; NC:=0; Data.BoundsMin:=Vec(0,0,0); Data.BoundsMax:=Vec(0,0,0);
  BendAngle:=HashUnit(P.Seed,8501)*Pi*2;
  StemCount:=1;
  if P.Species in [tsBirch,tsRowan] then begin
    { One persistent organism, not several independently generated trees.
      Age/LOD changes must never change its number of basal stems. }
    T:=HashUnit(P.Seed,8601);
    if T<0.10 then StemCount:=3 else if T<0.30 then StemCount:=2;
  end;
  for StemIndex:=0 to StemCount-1 do begin
  Seed:=Hash32(P.Seed);
  if StemIndex>0 then Seed:=HashChild(Seed,TREE_MAX_PRIMARY_BRANCHES+StemIndex);
  B:=MakeBranch(-1,0,Seed,0,Vec(0,0,0),Vec(0,1,0),P.Height,P.TrunkRadius);
  B.Tip.X:=(HashUnit(P.Seed,30)-0.5)*P.Height*P.Irregularity*0.19;
  B.Tip.Z:=(HashUnit(P.Seed,31)-0.5)*P.Height*P.Irregularity*0.19;
  B.Control:=Add(Scale(B.Tip,0.5),Vec(P.Height*P.Irregularity*0.08,0,0));
  if P.Species=tsOak then begin
    B.Tip.Y:=P.Height*(0.70+0.18*Clamp(1-P.Maturity,0,1));
    B.Control.Y:=B.Tip.Y*0.54;
  end;
  if P.Species=tsMountainPine then begin
    B.Tip:=Vec(Cos(BendAngle)*P.Height*0.32,P.Height,Sin(BendAngle)*P.Height*0.32);
    B.Control:=Vec(Cos(BendAngle)*P.Height*0.92,P.Height*0.12,Sin(BendAngle)*P.Height*0.92);
  end;
  if IsShrub(P.Species) then begin
    B.Tip:=Scale(B.Tip,0.22); B.Control:=Scale(B.Control,0.22);
  end;
  if StemCount>1 then begin
    A:=BendAngle+StemIndex*Pi*2/StemCount+(HashUnit(Seed,8602)-0.5)*0.25;
    Len:=P.Height;
    if StemIndex>0 then Len:=Len*(0.80+HashUnit(Seed,8603)*0.15);
    R:=P.Height*(0.08+HashUnit(Seed,8604)*0.06);
    B.Radius:=P.TrunkRadius*1.10/Sqrt(StemCount);
    { Bases overlap inside a single root collar; trunks gradually fan out. }
    B.Start:=Vec(Cos(A)*P.TrunkRadius*0.22,0,Sin(A)*P.TrunkRadius*0.22);
    B.Tip:=Vec(Cos(A)*R,Len,Sin(A)*R);
    B.Control:=Vec(B.Tip.X*0.27,Len*0.52,B.Tip.Z*0.27);
  end;
  B.TipRadius:=B.Radius*0.025; AddBranch(B);
  end;
  PrimaryFirst:=BC;
  CrownBase:=P.CrownStart;
  if StemCount>1 then CrownBase:=CrownBase*0.72;
  for I:=0 to P.PrimaryBranches-1 do begin
    { Share the tree's branch budget between stems, keeping a breadth-first
      hierarchy and identical branch prefixes at every detail level. }
    ParentIndex:=I mod StemCount; BranchIndex:=I div StemCount;
    BranchesOnStem:=(P.PrimaryBranches-1-ParentIndex) div StemCount+1;
    Parent:=Data.Branches[ParentIndex]; Seed:=HashChild(Parent.ID,BranchIndex);
    T:=CrownBase+(0.97-CrownBase)*(BranchIndex+0.5)/BranchesOnStem;
    if P.Species=tsPine then T:=P.CrownStart+(0.95-P.CrownStart)*(I div 5+0.3)/(P.PrimaryBranches div 5+0.3);
    if P.Species in [tsSpruce,tsLarch] then begin
      { Uneven whorls, rather than identical rings sampled from a cone. }
      T:=P.CrownStart+(0.96-P.CrownStart)*(I div 3+0.28)/((P.PrimaryBranches-1) div 3+0.5);
      T:=Clamp(T+(HashUnit(Seed,23)-0.5)*0.055*P.Irregularity,P.CrownStart*0.65,0.97);
    end;
    if P.Species=tsMaple then
      T:=P.CrownStart+(0.94-P.CrownStart)*(I div 2+0.5)/((P.PrimaryBranches+1) div 2);
    if IsShrub(P.Species) then T:=0.06+HashUnit(Seed,16)*0.40;
    A:=BranchIndex*2.39996323+ParentIndex*Pi*2/StemCount+(HashUnit(Seed,1)-0.5)*P.Irregularity*1.5;
    if P.Species=tsBirch then A:=A+BendAngle;
    if P.Species=tsMaple then A:=(I div 2)*1.57079633+(I mod 2)*Pi+(HashUnit(Seed,1)-0.5)*0.32;
    Pitch:=DegToRad(P.BranchAngle)*(0.85+HashUnit(Seed,2)*0.3);
    Envelope:=Power(Max(0.06,Sin(Pi*0.85*(T-CrownBase)/(1-CrownBase)+0.35)),0.7);
    if P.Species=tsPine then Envelope:=Power(1-T,0.85)*1.6;
    if P.Species in [tsSpruce,tsLarch] then begin
      Envelope:=Power(1-T,0.82)*1.65;
      Envelope:=Envelope*(1+(HashUnit(Seed,24)-0.5)*0.70*P.Irregularity)*
        (1+0.18*P.Irregularity*Cos(A-BendAngle));
      if (P.Maturity>0.7) and (HashUnit(Seed,25)<0.14*P.Irregularity) then
        Envelope:=Envelope*(1-0.45*P.Irregularity);
      Pitch:=DegToRad(P.BranchAngle)*(1+(HashUnit(Seed,2)-0.5)*0.30*P.Irregularity)+
        (HashUnit(Seed,26)-0.5)*0.32*P.Irregularity;
    end;
    if P.Species=tsOak then Envelope:=Envelope*(0.76+0.52*HashUnit(Seed,27));
    if P.Species=tsAcacia then begin
      Envelope:=0.85+HashUnit(Seed,27)*0.2;
      Pitch:=Pi*0.43;T:=P.CrownStart+(1-P.CrownStart)*0.28*HashUnit(Seed,28);
    end;
    if P.Species=tsMountainPine then Envelope:=0.72+Sin(T*Pi)*0.4;
    Len:=P.Height*P.CrownSpread*0.36*Envelope*(0.8+HashUnit(Seed,3)*0.4);
    if P.Species in [tsSpruce,tsLarch] then
      Len:=P.Height*P.CrownSpread*0.36*Envelope*(1+(HashUnit(Seed,3)-0.5)*0.50*P.Irregularity);
    if P.Species=tsMaple then begin
      Envelope:=Power(Max(0.035,Sin(Pi*(T-P.CrownStart)/(1-P.CrownStart))),0.60);
      Len:=P.Height*P.CrownSpread*0.46*Envelope*(0.85+HashUnit(Seed,3)*0.3);
    end;
    if (P.Species=tsOak) and (I<3) then begin
      T:=0.48+I*0.15; Pitch:=0.76+HashUnit(Seed,29)*0.28;
      Len:=P.Height*P.CrownSpread*(0.47+HashUnit(Seed,3)*0.12);
    end;
    if IsShrub(P.Species) then begin
      Len:=P.Height*(0.58+HashUnit(Seed,3)*0.28);
      Pitch:=DegToRad(P.BranchAngle)*(0.6+HashUnit(Seed,2)*0.6);
    end;
    Dir:=Normalize(Vec(Cos(A)*Sin(Pitch),Cos(Pitch),Sin(A)*Sin(Pitch)));
    if IsShrub(P.Species) then begin
      Dir.X:=Dir.X*P.CrownSpread/1.4; Dir.Z:=Dir.Z*P.CrownSpread/1.4;
      Len:=Len*Magnitude(Dir); Dir:=Normalize(Dir);
    end;
    R:=P.TrunkRadius*Power(1-T,0.6)*0.53;
    if P.Species=tsOak then R:=R*1.38;
    if P.Species in [tsSpruce,tsLarch] then R:=R*0.56;
    if IsShrub(P.Species) then R:=P.TrunkRadius*(0.42+HashUnit(Seed,17)*0.3);
    if StemCount>1 then R:=R*Parent.Radius/P.TrunkRadius;
    B:=MakeBranch(ParentIndex,1,Seed,T,Curve(Parent.Start,Parent.Control,Parent.Tip,T),Dir,Len,R);
    AddBranch(B);
  end;
  PrimaryLast:=BC-1;
  First:=PrimaryFirst; Last:=PrimaryLast;
  for Dep:=2 to DetailDepth do begin
    for ParentIndex:=First to Last do begin
      Parent:=Data.Branches[ParentIndex];
      if Dep=2 then N:=4 else if Dep=3 then N:=3 else N:=2;
      if (P.Species=tsBirch) and (Dep=2) then N:=5;
      if P.Species=tsOak then begin
        if Dep=2 then N:=5 else if Dep=3 then N:=4 else N:=3;
      end;
      if IsConifer(P.Species) then begin
        if Dep=2 then N:=5 else if Dep=3 then N:=4 else N:=3;
      end;
      if P.Species=tsSpruce then begin
        if Dep=2 then N:=8 else if Dep=3 then N:=6 else N:=4;
      end;
      for I:=0 to N-1 do begin
        Seed:=HashChild(Parent.ID,I);
        T:=0.36+(I+0.4)/N*0.59;
        Dir:=Tangent(Parent.Start,Parent.Control,Parent.Tip,T);
        Side:=Normalize(Cross(Dir,Vec(0.01,1,0.02))); Up:=Normalize(Cross(Side,Dir));
        A:=I*2.39996323+HashUnit(Seed,4)*1.8;
        if P.Species=tsMaple then A:=(I mod 2)*Pi+(I div 2)*0.40+HashUnit(Seed,4)*0.30;
        Tw:=0.55+HashUnit(Seed,5)*0.42;
        Dir:=Normalize(Add(Scale(Dir,0.75),Add(Scale(Side,Cos(A)*Tw),Scale(Up,Sin(A)*Tw))));
        if IsConifer(P.Species) then begin
          { Lateral sprays along whorled boughs, with upward terminal shoots. }
          Dir:=Normalize(Add(Scale(Tangent(Parent.Start,Parent.Control,Parent.Tip,T),0.85),
            Add(Scale(Side,(Ord(Odd(I))*2-1)*0.68),Vec(0,0.16,0))));
        end;
        if P.Species in [tsSpruce,tsLarch] then begin
          if Dep=2 then Dir.Y:=Dir.Y-(0.44+(HashUnit(Seed,28)-0.5)*0.40*P.Irregularity)
          else Dir.Y:=Dir.Y-(0.15+(HashUnit(Seed,28)-0.5)*0.18*P.Irregularity);
        end;
        if P.Species=tsMountainPine then Dir.Y:=Dir.Y+0.15*HashUnit(Seed,15);
        if (P.Species=tsBirch) and (Dep>=3) then
          Dir.Y:=Max(-0.65,Dir.Y-0.16-HashUnit(Seed,8605)*0.20);
        if not (P.Species in [tsBirch,tsWillow,tsSpruce,tsLarch]) then Dir.Y:=Max(Dir.Y,-0.24);
        Dir:=Normalize(Dir);
        Len:=Magnitude(Sub(Parent.Tip,Parent.Start))*(0.45+HashUnit(Seed,6)*0.23)*(1-T*0.27);
        if P.Species=tsSpruce then
          Len:=Magnitude(Sub(Parent.Tip,Parent.Start))*(0.40+HashUnit(Seed,6)*0.19)*(1-T*0.27);
        R:=(Parent.Radius*(1-T)+Parent.TipRadius*T)*0.58;
        if P.Species in [tsSpruce,tsLarch] then R:=R*0.80;
        B:=MakeBranch(ParentIndex,Dep,Seed,T,Curve(Parent.Start,Parent.Control,Parent.Tip,T),Dir,Len,R);
        AddBranch(B);
      end;
    end;
    First:=Last+1; Last:=BC-1;
  end;
  SetLength(Data.Branches,BC);
  { Proxies depend only on primary branches, so a far request does not expand
    the hierarchy or enumerate leaves. They remain identical at every LOD. }
  SetLength(Data.Crowns,P.PrimaryBranches);
  for I:=PrimaryFirst to PrimaryLast do begin
    B:=Data.Branches[I]; Len:=Magnitude(Sub(B.Tip,B.Start));
    Crown.Center:=Add(B.Tip,Scale(Normalize(Sub(B.Tip,B.Start)),Len*0.16));
    Crown.Radius:=Vec(Len*0.42,Len*0.34,Len*0.42);
    if P.Species in [tsPine,tsSpruce,tsLarch] then Crown.Radius.Y:=Len*0.22;
    if P.Species=tsWillow then begin Crown.Center.Y:=Crown.Center.Y-Len*0.24;
      Crown.Radius.Y:=Len*0.55; end;
    Size:=P.LeafSize*2.3;
    if IsConifer(P.Species) then Size:=P.NeedleLength*1.5;
    Crown.Radius:=Add(Crown.Radius,Vec(Size,Size,Size)); Crown.Phase:=HashUnit(Data.Branches[I].ID,20);
    Data.Crowns[CC]:=Crown; Inc(CC); Bounds(Crown.Center,Magnitude(Crown.Radius));
  end;
  if IncludeLeaves and IsConifer(P.Species) and (NeedlePairsPerShoot(P.LeafDensity)>0) then begin
    SetLength(Data.NeedleShoots,BC);
    for I:=1 to BC-1 do begin
      B:=Data.Branches[I];
      if B.Depth<Max(1,P.MaxDepth-1) then Continue;
      { Exact quadratic subcurve [0.18,1] of the parent twig. }
      T:=0.18; Shoot.Start:=Curve(B.Start,B.Control,B.Tip,T);
      Shoot.Control:=Mix(B.Control,B.Tip,T); Shoot.Tip:=B.Tip;
      Shoot.Radius:=B.Radius*(1-T)+B.TipRadius*T;
      Shoot.NeedleLength:=P.NeedleLength*(0.85+HashUnit(B.ID,71)*0.3);
      Shoot.NeedleWidth:=P.NeedleWidth;
      Shoot.Phase:=HashUnit(B.ID,72);
      Data.NeedleShoots[NC]:=Shoot; Inc(NC);
      Bounds(Shoot.Start,Shoot.NeedleLength*1.4);
      Bounds(Shoot.Control,Shoot.NeedleLength*1.4); Bounds(Shoot.Tip,Shoot.NeedleLength*1.4);
    end;
    SetLength(Data.NeedleShoots,NC);
  end;
  if IncludeLeaves and not IsConifer(P.Species) then for I:=1 to BC-1 do begin
    B:=Data.Branches[I];
    if B.Depth=0 then Continue;
    if (B.Depth<2) and (P.MaxDepth>1) then Continue;
    N:=Round(P.LeafDensity*22);
    if P.Species=tsRowan then N:=Round(P.LeafDensity*16);
    if B.Depth<P.MaxDepth then N:=N div 2;
    for J:=0 to N-1 do begin
      Seed:=HashChild(B.ID,100+J); T:=0.20+HashUnit(Seed,1)*0.8;
      if P.Species=tsRowan then begin
        { Alternate compound leaves attached by their petiole. Keep the end
          of each fruiting shoot open instead of hiding berries in leaf clouds. }
        T:=0.12+(J+0.25+HashUnit(Seed,1)*0.5)/N*0.64;
        Center:=Curve(B.Start,B.Control,B.Tip,T);
        Dir:=Tangent(B.Start,B.Control,B.Tip,T);
        Side:=Normalize(Cross(Dir,Vec(0.01,1,0.02)));
        Size:=P.LeafSize*(0.80+HashUnit(Seed,2)*0.40);
        Leaf.Axis:=Normalize(Add(Scale(Dir,0.45),
          Add(Scale(Side,(Ord(Odd(J))*2-1)*(0.75+HashUnit(Seed,3)*0.35)),
            Vec(0,-0.20+HashUnit(Seed,4)*0.85,0))));
        Leaf.Center:=Add(Center,Scale(Leaf.Axis,Size*0.96));
        Leaf.Size:=Size;Leaf.Aspect:=0.55;
        Leaf.Phase:=HashUnit(Seed,9);AddLeaf(Leaf);
        Continue;
      end;
      Center:=Curve(B.Start,B.Control,B.Tip,T);
      Size:=P.LeafSize*(0.70+HashUnit(Seed,2)*0.65);
      A:=HashUnit(Seed,3)*Pi*2; R:=Size*(0.4+HashUnit(Seed,4)*1.4);
      Leaf.Center:=Add(Center,Vec(Cos(A)*R,(HashUnit(Seed,5)-0.25)*Size*2,Sin(A)*R));
      Leaf.Axis:=Normalize(Vec(HashUnit(Seed,6)-0.5,0.12+HashUnit(Seed,7)*0.8,HashUnit(Seed,8)-0.5));
      Leaf.Size:=Size; Leaf.Aspect:=0.60;
      if P.Species=tsMaple then Leaf.Aspect:=1.05;
      if P.Species=tsOak then Leaf.Aspect:=0.54;
      if P.Species=tsWillow then Leaf.Aspect:=0.23;
      if P.Species=tsEucalyptus then Leaf.Aspect:=0.17;
      if P.Species=tsAcacia then Leaf.Aspect:=0.55;
      Leaf.Phase:=HashUnit(Seed,9); AddLeaf(Leaf);
    end;
  end;
  SetLength(Data.Leaves,LC);
  if P.Species=tsAcacia then begin
    { A broad umbrella of fine branchlets, rather than a round European crown. }
    Data.BoundsMin:=Vec(0,0,0);Data.BoundsMax:=Vec(0,0,0);
    for I:=0 to BC-1 do begin
      Data.Branches[I].Start:=AcaciaPoint(Data.Branches[I].Start);
      Data.Branches[I].Control:=AcaciaPoint(Data.Branches[I].Control);
      Data.Branches[I].Tip:=AcaciaPoint(Data.Branches[I].Tip);
      Bounds(Data.Branches[I].Start,Data.Branches[I].Radius);
      Bounds(Data.Branches[I].Control,Data.Branches[I].Radius);
      Bounds(Data.Branches[I].Tip,Data.Branches[I].Radius);
    end;
    for I:=0 to LC-1 do begin
      Data.Leaves[I].Center:=AcaciaPoint(Data.Leaves[I].Center);
      Bounds(Data.Leaves[I].Center,Data.Leaves[I].Size);
    end;
    for I:=0 to CC-1 do begin
      Data.Crowns[I].Center:=AcaciaPoint(Data.Crowns[I].Center);
      Data.Crowns[I].Radius.Y:=Data.Crowns[I].Radius.Y*0.28;
    end;
  end;
  Data.Fingerprint:=Hash32(P.Seed);
  if NC>0 then FingerprintValue(NeedlePairsPerShoot(P.LeafDensity)*NeedlesPerFascicle(P.Species));
  for I:=0 to BC-1 do begin
    B:=Data.Branches[I]; Data.Fingerprint:=Hash32(Data.Fingerprint xor B.ID);
    FingerprintValue(B.Start.X); FingerprintValue(B.Start.Y); FingerprintValue(B.Start.Z);
    FingerprintValue(B.Control.X); FingerprintValue(B.Control.Y); FingerprintValue(B.Control.Z);
    FingerprintValue(B.Tip.X); FingerprintValue(B.Tip.Y); FingerprintValue(B.Tip.Z);
    FingerprintValue(B.Radius); FingerprintValue(B.TipRadius);
  end;
  for I:=0 to LC-1 do begin
    FingerprintValue(Data.Leaves[I].Center.X); FingerprintValue(Data.Leaves[I].Center.Y);
    FingerprintValue(Data.Leaves[I].Center.Z); FingerprintValue(Data.Leaves[I].Size);
  end;
  for I:=0 to NC-1 do begin
    Shoot:=Data.NeedleShoots[I];
    FingerprintValue(Shoot.Start.X); FingerprintValue(Shoot.Start.Y); FingerprintValue(Shoot.Start.Z);
    FingerprintValue(Shoot.NeedleLength); FingerprintValue(Shoot.NeedleWidth); FingerprintValue(Shoot.Phase);
  end;
  if IncludeLeaves then GenerateTreeFruits(Data);
  Result:=Data;
end;
function GenerateTreeAt(const Instance: TTreeInstance; const Profile: TTreeParams;
  DetailDepth: Integer; IncludeLeaves: Boolean): TTreeData;
var P: TTreeParams;
begin
  P:=ResolveTreeParams(Instance,Profile);
  Result:=GenerateTree(P,DetailDepth,IncludeLeaves);
end;
end.
