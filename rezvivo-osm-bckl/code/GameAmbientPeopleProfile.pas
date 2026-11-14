unit GameAmbientPeopleProfile;
{$mode objfpc}{$H+}
interface
uses CastleVectors, RiderBodyParameters, RiderHair, RiderHeadAppearance, RiderTripo;
const AmbientCatalogCount=32;
type
  TAmbientKind=(akWalker,akRunner);
  TAmbientProfile=record
    CatalogIndex:Integer;
    Name:string;
    Kind:TAmbientKind;
    Body:TRiderBodyParameters;
    Hair:TRiderHairStyle;
    Headwear:TRiderHeadwear;
    Beard:TRiderBeard;
    Colors:array[TClothSlot]of TVector3;
    Outfit:array[0..4]of string;
    Speed:Single;
  end;
function AmbientProfile(Index:Integer):TAmbientProfile;
function SelectAmbientProfile(Kind:TAmbientKind;Seed:Cardinal):TAmbientProfile;
function AmbientNextDelay(Seed:Cardinal;Encounter:Integer):Single;
function AmbientCanAppear(RiderDistance,CameraDistance:Single;InCamera:Boolean):Boolean;
implementation
uses Math;
type TEntry=record
  Name:string[32];Sex,Height,Weight,Composition:Single;
  Hair:TRiderHairStyle;Skin,HairColor,Clothes,Outfit:Byte;
end;
const
  { Separate stable pedestrian catalog: pairs are walking / running, each
    with its own body, hair, skin and everyday or sports clothing. }
  Catalog:array[0..AmbientCatalogCount-1]of TEntry=(
    (Name:'Maya Chen';Sex:1;Height:165;Weight:63;Composition:0.35;Hair:rhsPonytail;Skin:1;HairColor:0;Clothes:0;Outfit:0),
    (Name:'Daniel Costa';Sex:0;Height:178;Weight:70;Composition:0.75;Hair:rhsShort;Skin:2;HairColor:1;Clothes:1;Outfit:0),
    (Name:'Oliver Jensen';Sex:0;Height:186;Weight:92;Composition:0.35;Hair:rhsSwept;Skin:0;HairColor:2;Clothes:2;Outfit:1),
    (Name:'Amina Diallo';Sex:1;Height:172;Weight:61;Composition:0.70;Hair:rhsCoils;Skin:5;HairColor:0;Clothes:3;Outfit:0),
    (Name:'Sofia Rossi';Sex:1;Height:159;Weight:58;Composition:0.40;Hair:rhsBraid;Skin:2;HairColor:1;Clothes:4;Outfit:2),
    (Name:'Kenji Sato';Sex:0;Height:171;Weight:62;Composition:0.70;Hair:rhsSwept;Skin:1;HairColor:0;Clothes:5;Outfit:1),
    (Name:'Yusuf Demir';Sex:0;Height:175;Weight:81;Composition:0.45;Hair:rhsCurly;Skin:3;HairColor:0;Clothes:6;Outfit:0),
    (Name:'Emma Wilson';Sex:1;Height:168;Weight:60;Composition:0.65;Hair:rhsPonytail;Skin:0;HairColor:2;Clothes:7;Outfit:1),
    (Name:'Priya Sharma';Sex:1;Height:162;Weight:66;Composition:0.35;Hair:rhsLongBraid;Skin:3;HairColor:0;Clothes:1;Outfit:1),
    (Name:'Lucas Martin';Sex:0;Height:182;Weight:76;Composition:0.80;Hair:rhsShort;Skin:1;HairColor:1;Clothes:3;Outfit:0),
    (Name:'Noah Okafor';Sex:0;Height:183;Weight:87;Composition:0.55;Hair:rhsCoils;Skin:5;HairColor:0;Clothes:5;Outfit:2),
    (Name:'Elena Petrova';Sex:1;Height:170;Weight:63;Composition:0.60;Hair:rhsBraid;Skin:0;HairColor:1;Clothes:0;Outfit:0),
    (Name:'Hana Kim';Sex:1;Height:158;Weight:54;Composition:0.40;Hair:rhsMedium;Skin:1;HairColor:0;Clothes:7;Outfit:0),
    (Name:'Samuel Mensah';Sex:0;Height:179;Weight:72;Composition:0.75;Hair:rhsCoils;Skin:4;HairColor:0;Clothes:6;Outfit:1),
    (Name:'Mateo Garcia';Sex:0;Height:173;Weight:78;Composition:0.45;Hair:rhsParted;Skin:2;HairColor:1;Clothes:4;Outfit:1),
    (Name:'Zoe Campbell';Sex:1;Height:174;Weight:65;Composition:0.75;Hair:rhsPonytail;Skin:4;HairColor:0;Clothes:2;Outfit:0),
    (Name:'Nora Berg';Sex:1;Height:177;Weight:79;Composition:0.35;Hair:rhsSwept;Skin:0;HairColor:2;Clothes:6;Outfit:2),
    (Name:'Arjun Patel';Sex:0;Height:176;Weight:67;Composition:0.65;Hair:rhsShort;Skin:3;HairColor:0;Clothes:4;Outfit:1),
    (Name:'Thomas Weber';Sex:0;Height:180;Weight:86;Composition:0.40;Hair:rhsBald;Skin:1;HairColor:3;Clothes:0;Outfit:0),
    (Name:'Sara Hassan';Sex:1;Height:163;Weight:58;Composition:0.65;Hair:rhsBraid;Skin:3;HairColor:0;Clothes:5;Outfit:0),
    (Name:'Ana Silva';Sex:1;Height:166;Weight:68;Composition:0.40;Hair:rhsCurly;Skin:2;HairColor:1;Clothes:2;Outfit:1),
    (Name:'Joon Park';Sex:0;Height:181;Weight:73;Composition:0.70;Hair:rhsParted;Skin:1;HairColor:0;Clothes:7;Outfit:1),
    (Name:'Ibrahim Ali';Sex:0;Height:178;Weight:84;Composition:0.45;Hair:rhsShort;Skin:4;HairColor:0;Clothes:3;Outfit:2),
    (Name:'Lena Fischer';Sex:1;Height:167;Weight:59;Composition:0.70;Hair:rhsPonytail;Skin:0;HairColor:2;Clothes:1;Outfit:0),
    (Name:'Keiko Tanaka';Sex:1;Height:160;Weight:57;Composition:0.40;Hair:rhsSwept;Skin:1;HairColor:0;Clothes:5;Outfit:0),
    (Name:'Rafael Santos';Sex:0;Height:177;Weight:71;Composition:0.75;Hair:rhsCurly;Skin:3;HairColor:0;Clothes:0;Outfit:1),
    (Name:'Adam Kowalski';Sex:0;Height:184;Weight:91;Composition:0.35;Hair:rhsParted;Skin:0;HairColor:3;Clothes:1;Outfit:1),
    (Name:'Fatima Benali';Sex:1;Height:169;Weight:62;Composition:0.65;Hair:rhsBraid;Skin:3;HairColor:0;Clothes:2;Outfit:0),
    (Name:'Leila Haddad';Sex:1;Height:164;Weight:65;Composition:0.40;Hair:rhsMedium;Skin:2;HairColor:1;Clothes:7;Outfit:2),
    (Name:'David Brown';Sex:0;Height:185;Weight:80;Composition:0.70;Hair:rhsBald;Skin:4;HairColor:0;Clothes:4;Outfit:1),
    (Name:'Ben Taylor';Sex:0;Height:172;Weight:76;Composition:0.40;Hair:rhsShort;Skin:0;HairColor:1;Clothes:4;Outfit:0),
    (Name:'Isabel Moreno';Sex:1;Height:171;Weight:64;Composition:0.70;Hair:rhsPonytail;Skin:2;HairColor:1;Clothes:6;Outfit:0)
  );
  Cloth:array[0..7]of TVector3=(
    (X:0.19;Y:0.43;Z:0.48),(X:0.70;Y:0.29;Z:0.17),(X:0.46;Y:0.37;Z:0.55),
    (X:0.69;Y:0.65;Z:0.43),(X:0.24;Y:0.35;Z:0.25),(X:0.72;Y:0.72;Z:0.67),
    (X:0.17;Y:0.28;Z:0.47),(X:0.66;Y:0.30;Z:0.39));
  Skin:array[0..5]of TVector3=(
    (X:0.88;Y:0.68;Z:0.54),(X:0.82;Y:0.61;Z:0.46),(X:0.74;Y:0.53;Z:0.37),
    (X:0.66;Y:0.44;Z:0.29),(X:0.54;Y:0.34;Z:0.22),(X:0.40;Y:0.25;Z:0.17));
  Hair:array[0..3]of TVector3=((X:0.08;Y:0.06;Z:0.04),(X:0.25;Y:0.14;Z:0.07),
    (X:0.62;Y:0.43;Z:0.22),(X:0.48;Y:0.47;Z:0.44));
function AmbientProfile(Index:Integer):TAmbientProfile;
var E:TEntry;
begin
  Index:=((Index mod AmbientCatalogCount)+AmbientCatalogCount)mod AmbientCatalogCount;
  E:=Catalog[Index];Result:=Default(TAmbientProfile);Result.CatalogIndex:=Index;
  Result.Name:=E.Name;Result.Kind:=TAmbientKind(Index mod 2);
  Result.Body:=DefaultRiderBody(E.Sex);Result.Body.HeightCm:=E.Height;
  Result.Body.WeightKg:=E.Weight;Result.Body.Composition:=E.Composition;Result.Body.HeadShape:=E.Sex;
  Result.Hair:=E.Hair;Result.Headwear:=rhwNone;Result.Beard:=rbNone;
  Result.Colors[csSkin]:=Skin[E.Skin];Result.Colors[csHair]:=Hair[E.HairColor];
  Result.Colors[csJersey]:=Cloth[E.Clothes];Result.Colors[csShorts]:=Vector3(0.12,0.16,0.21);
  Result.Colors[csSocks]:=Vector3(0.65,0.66,0.63);Result.Colors[csBoots]:=Vector3(0.30,0.31,0.32);
  Result.Colors[csGloves]:=Result.Colors[csSkin];
  Result.Outfit[0]:='tshirt';Result.Outfit[1]:='trousers';Result.Outfit[3]:='sneakers';
  if Result.Kind=akRunner then begin
    Result.Speed:=2.9+(Index div 2 mod 6)*0.17;
    if E.Outfit=1 then Result.Headwear:=rhwCap;
  end else begin
    Result.Speed:=1.10+(Index div 2 mod 6)*0.08;
    Result.Outfit[1]:='jeans';
    if E.Outfit=1 then Result.Outfit[0]:='sweatshirt';
    if E.Outfit=2 then Result.Outfit[2]:='jacket';
  end;
end;
function SelectAmbientProfile(Kind:TAmbientKind;Seed:Cardinal):TAmbientProfile;
begin Result:=AmbientProfile(Integer(Seed mod (AmbientCatalogCount div 2))*2+Ord(Kind)) end;
function AmbientNextDelay(Seed:Cardinal;Encounter:Integer):Single;
begin Result:=75+((QWord(Seed)+QWord(Max(0,Encounter))*7919)mod 76) end;
function AmbientCanAppear(RiderDistance,CameraDistance:Single;InCamera:Boolean):Boolean;
begin
  Result:=(RiderDistance>=45)and(RiderDistance<=180)and(CameraDistance>=45)and
    (not InCamera or(CameraDistance>=100));
end;
end.
