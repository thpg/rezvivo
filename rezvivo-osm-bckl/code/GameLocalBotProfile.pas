unit GameLocalBotProfile;
{$mode objfpc}{$H+}
interface
uses CastleVectors, RiderBodyParameters, RiderHair, RiderHeadAppearance, RiderTripo;
const
  LocalBotCatalogCount = 100;
  LocalBotCount = 7;
  LocalBotVisibleLimit = 3;
  LocalBotEnterBehind = 65.0;
  LocalBotEnterFar = 160.0;
  LocalBotLeaveDistance = 240.0;
  LocalBotJoinInterval = 30.0;
  LocalBotAppearanceInterval = 20.0;
  LocalBotOncomingIndex = LocalBotCount-1;
  LocalBotOncomingFirst = 45.0;
  LocalBotOncomingInterval = 90.0;
type
  TLocalBotProfile = record
    CatalogIndex: Integer;
    DisplayName: string[48];
    Body: TRiderBodyParameters;
    Hair: TRiderHairStyle;
    Headwear: TRiderHeadwear;
    Beard: TRiderBeard;
    Mustache: TRiderMustache;
    Colors: array[TClothSlot] of TVector3;
    Frame, Rim, Helmet: TVector3;
    Ability: Single;
    Aggression,CapacitySeconds,RecoverySeconds:Single;
    EffortSeed:Cardinal;
  end;
function LocalBotCatalogProfile(Index: Integer): TLocalBotProfile;
function MakeLocalBotProfile(Index: Integer; Seed: Cardinal): TLocalBotProfile;
function LocalBotSustainablePower(const Profile: TLocalBotProfile;
  ReferencePower, ReferenceMass: Single): Single;
function BotCanAppear(RouteGap, RiderDistance, CameraDistance: Single;
  InCamera: Boolean): Boolean;
function BotCanDisappear(RiderDistance, CameraDistance: Single;
  InCamera: Boolean): Boolean;
implementation
uses Math;

type
  TCatalogEntry = record
    Name: string[48];
    Sex, Height, Weight, Composition, Inseam, Arms: Single;
    Hair: TRiderHairStyle;
    Headwear: TRiderHeadwear;
    Beard: TRiderBeard;
    Mustache: TRiderMustache;
    Skin, HairColor, Kit, Shorts, Socks, Boots, Frame, Helmet: Byte;
    Ability, Aggression, Capacity, Recovery: Single;
  end;
const
  Catalog: array[0..LocalBotCatalogCount-1] of TCatalogEntry = (
    {$I GameLocalBotCatalog.inc}
  );
  Kits: array[0..9] of TVector3 = (
    (X:0.90;Y:0.28;Z:0.13),(X:0.12;Y:0.40;Z:0.75),
    (X:0.13;Y:0.64;Z:0.53),(X:0.92;Y:0.73;Z:0.16),
    (X:0.72;Y:0.23;Z:0.43),(X:0.52;Y:0.40;Z:0.70),
    (X:0.85;Y:0.87;Z:0.82),(X:0.25;Y:0.34;Z:0.24),
    (X:0.89;Y:0.47;Z:0.19),(X:0.18;Y:0.61;Z:0.69));
  HairColors: array[0..4] of TVector3 = (
    (X:0.09;Y:0.065;Z:0.045),(X:0.25;Y:0.15;Z:0.07),
    (X:0.65;Y:0.46;Z:0.23),(X:0.44;Y:0.18;Z:0.075),
    (X:0.51;Y:0.49;Z:0.45));
  SkinColors: array[0..5] of TVector3 = (
    (X:0.88;Y:0.68;Z:0.54),(X:0.82;Y:0.61;Z:0.46),(X:0.74;Y:0.53;Z:0.37),
    (X:0.66;Y:0.44;Z:0.29),(X:0.54;Y:0.34;Z:0.22),(X:0.40;Y:0.25;Z:0.17));
  ShortsColors: array[0..3] of TVector3 = (
    (X:0.085;Y:0.095;Z:0.11),(X:0.11;Y:0.16;Z:0.23),
    (X:0.21;Y:0.13;Z:0.16),(X:0.13;Y:0.20;Z:0.17));
  DetailColors: array[0..2] of TVector3 = (
    (X:0.90;Y:0.90;Z:0.86),(X:0.15;Y:0.16;Z:0.18),(X:0.38;Y:0.40;Z:0.42));

function LocalBotCatalogProfile(Index: Integer): TLocalBotProfile;
var C: TCatalogEntry;
begin
  Index:=((Index mod LocalBotCatalogCount)+LocalBotCatalogCount) mod LocalBotCatalogCount;
  C:=Catalog[Index];
  Result:=Default(TLocalBotProfile);
  Result.CatalogIndex:=Index; Result.DisplayName:=C.Name;
  Result.Body:=DefaultRiderBody(C.Sex);
  Result.Body.HeightCm:=C.Height; Result.Body.WeightKg:=C.Weight;
  Result.Body.Composition:=C.Composition; Result.Body.InseamCm:=C.Inseam;
  Result.Body.ArmLengthCm:=C.Arms; Result.Body.HeadShape:=C.Sex;
  Result.Hair:=C.Hair; Result.Headwear:=C.Headwear;
  Result.Beard:=C.Beard; Result.Mustache:=C.Mustache;
  Result.Colors[csJersey]:=Kits[C.Kit];
  Result.Colors[csShorts]:=ShortsColors[C.Shorts];
  Result.Colors[csSocks]:=DetailColors[C.Socks];
  Result.Colors[csBoots]:=DetailColors[C.Boots];
  Result.Colors[csGloves]:=Kits[C.Kit]*0.65;
  Result.Colors[csHair]:=HairColors[C.HairColor];
  Result.Colors[csSkin]:=SkinColors[C.Skin];
  Result.Frame:=Kits[C.Frame]; Result.Rim:=Vector3(0.10,0.11,0.12);
  if C.Helmet=2 then Result.Helmet:=Kits[C.Kit]
  else Result.Helmet:=DetailColors[C.Helmet];
  Result.Ability:=C.Ability; Result.Aggression:=C.Aggression;
  Result.CapacitySeconds:=C.Capacity; Result.RecoverySeconds:=C.Recovery;
  Result.EffortSeed:=Cardinal(Index+1)*7919;
end;

function MakeLocalBotProfile(Index: Integer; Seed: Cardinal): TLocalBotProfile;
const Steps: array[0..19] of Byte=(1,3,7,9,11,13,17,19,21,23,27,29,31,33,37,39,41,43,47,49);
var Start,Stride,Role,Rank,I,Entry,Category: Integer;
begin
  { The roster is balanced, but each person's ability and appearance are fixed.
    Walk one permutation, selecting without replacement within each category. }
  Index:=((Index mod LocalBotCatalogCount)+LocalBotCatalogCount) mod LocalBotCatalogCount;
  Start:=Seed mod LocalBotCatalogCount;
  Stride:=Steps[(Seed div LocalBotCatalogCount) mod Length(Steps)];
  case Index mod LocalBotCount of
    4: begin Role:=1;Rank:=Index div LocalBotCount end;
    5: begin Role:=2;Rank:=Index div LocalBotCount end;
    else begin Role:=0;Rank:=(Index div LocalBotCount)*5+Min(4,Index mod LocalBotCount) end;
  end;
  for I:=0 to LocalBotCatalogCount-1 do begin
    Entry:=(Start+I*Stride) mod LocalBotCatalogCount;
    Category:=0;
    if Catalog[Entry].Ability<0.85 then Category:=1
    else if Catalog[Entry].Ability>1.15 then Category:=2;
    if Category<>Role then Continue;
    if Rank=0 then Exit(LocalBotCatalogProfile(Entry));
    Dec(Rank);
  end;
  Result:=LocalBotCatalogProfile(Start); { catalog invariants are tested }
end;

function LocalBotSustainablePower(const Profile:TLocalBotProfile;
  ReferencePower,ReferenceMass:Single):Single;
var MassFactor:Single;
begin
  { Blend W/kg on climbs with absolute watts on flats. No distance-based
    rubber band, teleport, or instant response to the player's pedal strokes. }
  MassFactor:=Power((Profile.Body.WeightKg+9)/Max(44,ReferenceMass),0.65);
  { Normal riding is about 89% of sustainable power. Keep the long-term
    reference close to the rider while retaining individual ability. }
  Result:=EnsureRange(ReferencePower*Profile.Ability*MassFactor*1.12,30,800);
end;

function BotCanAppear(RouteGap,RiderDistance,CameraDistance:Single;InCamera:Boolean):Boolean;
begin
  Result:=(RouteGap<=-LocalBotEnterBehind) and (RouteGap>=-LocalBotEnterFar)
    and (RiderDistance>=LocalBotEnterBehind) and (RiderDistance<=LocalBotEnterFar)
    and (CameraDistance>=50) and (not InCamera);
end;

function BotCanDisappear(RiderDistance,CameraDistance:Single;InCamera:Boolean):Boolean;
begin
  { Keep visible riders while a chase/free camera is watching them. }
  Result:=(RiderDistance>=LocalBotLeaveDistance) and
    ((not InCamera) or (CameraDistance>=400));
end;
end.
