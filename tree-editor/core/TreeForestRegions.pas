unit TreeForestRegions;
{$mode objfpc}{$H+}
interface
uses TreeModel;
const FOREST_REGION_VERSION = 2;
type
  TForestLocation = record
    Enabled: Boolean; { only real-world forest polygons, never Dream coordinates }
    Latitude, Longitude, Elevation: Double;
  end;
  TForestWeights = array[TTreeSpecies] of Double;
  TForestMix = record
    Weights: TForestWeights;
    Region: string;
  end;
{ Approximate visual proportions, not inventory statistics. Explicit OSM taxa
  are handled by TreeOsm before this fallback. No IO, global mutable state or GL. }
function RegionalForestMix(const Location: TForestLocation;
  const LeafType, LeafCycle, Wetland: string): TForestMix;
function RegionalScrubMix(const Location:TForestLocation):TForestMix;
implementation
uses Math, SysUtils;
type
  TForestProfile = (fpTropical, fpTemperate, fpBoreal, fpMediterranean,
    fpCaucasus, fpWestSiberia, fpEastSiberia, fpFarEast, fpKamchatka,
    fpEastAsia, fpSubtropicalAsia, fpHimalaya, fpCentralAsia,
    fpAmericaEast, fpAmericaWest, fpAmericaBoreal, fpAmericaSouthEast,
    fpCalifornia, fpMexico, fpCentralAmerica, fpSouthernAndes,
    fpAustralasia, fpAfricaMontane, fpAustralia);
  TRegion = record
    Name: string[32];
    South, North, West, East: Single;
    Profile: TForestProfile;
  end;
const
  { Broad geographic envelopes with a 1.5 degree feather, applied from broad
    to specific. These are deliberately NOT claimed as FAO GIS boundaries.
    See docs/forest-regions-20260918/README.md for sources and model mappings. }
  Regions: array[0..25] of TRegion = (
    (Name:'europe-temperate';South:42;North:59;West:-14;East:62;Profile:fpTemperate),
    (Name:'europe-boreal';South:58;North:75;West:-14;East:62;Profile:fpBoreal),
    (Name:'mediterranean';South:29;North:43;West:-14;East:39;Profile:fpMediterranean),
    (Name:'central-asia';South:30;North:51;West:49;East:99;Profile:fpCentralAsia),
    (Name:'west-siberia';South:51;North:75;West:62;East:96;Profile:fpWestSiberia),
    (Name:'east-siberia';South:50;North:76;West:96;East:190;Profile:fpEastSiberia),
    (Name:'tropical-asia';South:-12;North:25;West:65;East:160;Profile:fpTropical),
    (Name:'east-asia';South:28;North:43;West:103;East:146;Profile:fpEastAsia),
    (Name:'subtropical-asia';South:20;North:28;West:95;East:136;Profile:fpSubtropicalAsia),
    (Name:'himalaya';South:26;North:36;West:70;East:101;Profile:fpHimalaya),
    (Name:'far-east';South:41;North:51;West:120;East:151;Profile:fpFarEast),
    (Name:'kamchatka';South:51;North:63;West:155;East:175;Profile:fpKamchatka),
    (Name:'caucasus';South:39;North:45;West:37;East:50;Profile:fpCaucasus),
    (Name:'north-america-east';South:30;North:52;West:-105;East:-50;Profile:fpAmericaEast),
    (Name:'north-america-west';South:30;North:54;West:-136;East:-105;Profile:fpAmericaWest),
    (Name:'north-america-boreal';South:52;North:76;West:-170;East:-50;Profile:fpAmericaBoreal),
    (Name:'southeast-usa';South:24;North:36;West:-105;East:-75;Profile:fpAmericaSouthEast),
    (Name:'california';South:31;North:41;West:-125;East:-115;Profile:fpCalifornia),
    (Name:'mexico';South:16;North:30;West:-118;East:-86;Profile:fpMexico),
    (Name:'central-america';South:7;North:21;West:-93;East:-59;Profile:fpCentralAmerica),
    (Name:'south-america';South:-56;North:12;West:-82;East:-34;Profile:fpTropical),
    (Name:'southern-andes';South:-56;North:-33;West:-78;East:-63;Profile:fpSouthernAndes),
    (Name:'africa';South:-36;North:29;West:-20;East:52;Profile:fpAfricaMontane),
    (Name:'australia';South:-45;North:-12;West:110;East:155;Profile:fpAustralia),
    (Name:'new-zealand';South:-49;North:-33;West:165;East:179;Profile:fpAustralasia),
    (Name:'pacific-islands';South:-25;North:24;West:160;East:220;Profile:fpTropical)
  );
function Smooth(A,B,X:Double):Double;
begin Result:=EnsureRange((X-A)/(B-A),0.0,1.0);Result:=Result*Result*(3-2*Result);end;
function Weights(Oak,Birch,Pine,Willow,MountainPine,Spruce,Maple,Broadleaf,Larch:Double):TForestWeights;
begin
  Result:=Default(TForestWeights);
  Result[tsOak]:=Oak;Result[tsBirch]:=Birch;Result[tsPine]:=Pine;
  Result[tsWillow]:=Willow;Result[tsMountainPine]:=MountainPine;
  Result[tsSpruce]:=Spruce;Result[tsMaple]:=Maple;
  Result[tsBroadleaf]:=Broadleaf;Result[tsLarch]:=Larch;
end;
procedure Blend(var Dest:TForestWeights;const Src:TForestWeights;Amount:Double);
var S:TTreeSpecies;
begin for S:=Low(S) to High(S) do Dest[S]:=Dest[S]*(1-Amount)+Src[S]*Amount;end;
function ProfileMix(P:TForestProfile;Elevation:Double):TForestWeights;
var Mountain:TForestWeights;StartHeight,EndHeight:Double;
begin
  Mountain:=Weights(0,10,20,0,10,40,0,0,20);StartHeight:=800;EndHeight:=2200;
  case P of
    fpTropical: begin
      Result:=Weights(0,0,0,0,0,0,0,88,0);Result[tsPalm]:=9;Result[tsFanPalm]:=3;
      Mountain:=Weights(0,0,0,0,0,0,0,100,0);StartHeight:=800;EndHeight:=2100;
    end;
    fpTemperate: Result:=Weights(18,18,15,0,0,17,8,24,0);
    fpBoreal: begin
      Result:=Weights(0,20,35,0,0,40,0,5,0);
      Mountain:=Weights(0,45,25,0,0,25,0,5,0);StartHeight:=400;EndHeight:=1300;
    end;
    fpMediterranean: begin
      Result:=Weights(35,0,35,0,0,0,0,30,0);
      Mountain:=Weights(15,0,45,0,5,15,0,20,0);StartHeight:=1100;EndHeight:=2500;
    end;
    fpCaucasus: begin
      Result:=Weights(15,5,8,0,0,10,7,55,0);
      Mountain:=Weights(0,10,25,0,0,45,0,20,0);StartHeight:=900;EndHeight:=2200;
    end;
    fpWestSiberia: begin
      Result:=Weights(0,25,30,0,0,25,0,5,15);
      Mountain:=Weights(0,10,30,0,0,30,0,0,30);StartHeight:=600;EndHeight:=1700;
    end;
    fpEastSiberia: begin
      Result:=Weights(0,10,10,0,0,8,0,2,70);
      Mountain:=Weights(0,10,15,0,10,0,0,0,65);StartHeight:=500;EndHeight:=1600;
    end;
    fpFarEast: begin
      Result:=Weights(18,12,20,0,0,12,10,20,8);
      Mountain:=Weights(0,15,20,0,10,30,0,5,20);StartHeight:=600;EndHeight:=1900;
    end;
    fpKamchatka: begin
      Result:=Weights(0,45,5,0,0,15,0,15,20);
      Mountain:=Weights(0,50,0,0,30,0,0,10,10);StartHeight:=400;EndHeight:=1300;
    end;
    fpEastAsia: begin
      Result:=Weights(18,0,20,0,0,5,17,35,0);Result[tsBamboo]:=5;
      Mountain:=Weights(0,10,20,0,0,25,10,20,15);StartHeight:=1100;EndHeight:=2600;
    end;
    fpSubtropicalAsia: begin
      Result:=Weights(0,0,15,0,0,0,0,67,0);Result[tsBamboo]:=14;Result[tsPalm]:=4;
      Mountain:=Weights(10,0,30,0,0,25,10,25,0);StartHeight:=1800;EndHeight:=3300;
    end;
    fpHimalaya: begin
      Result:=Weights(10,0,20,0,0,10,0,60,0);
      Mountain:=Weights(10,10,25,0,0,40,0,15,0);StartHeight:=1700;EndHeight:=3500;
    end;
    fpCentralAsia: begin
      Result:=Weights(0,5,15,5,0,10,0,65,0);
      Mountain:=Weights(0,15,30,0,0,40,0,15,0);StartHeight:=1000;EndHeight:=2700;
    end;
    fpAmericaEast: begin
      Result:=Weights(22,12,15,0,0,8,20,23,0);
      Mountain:=Weights(5,15,20,0,0,35,15,10,0);
    end;
    fpAmericaWest: begin
      Result:=Weights(5,5,40,0,0,35,0,10,5);
      Mountain:=Weights(0,5,40,0,0,40,0,5,10);StartHeight:=1000;EndHeight:=2500;
    end;
    fpAmericaBoreal: begin
      Result:=Weights(0,18,20,0,0,45,0,10,7);
      Mountain:=Weights(0,20,15,0,0,50,0,10,5);StartHeight:=600;EndHeight:=1700;
    end;
    fpAmericaSouthEast: begin
      Result:=Weights(25,0,45,0,0,0,0,30,0);
      Mountain:=Weights(15,10,25,0,0,20,15,15,0);StartHeight:=1000;EndHeight:=2200;
    end;
    fpCalifornia: begin
      Result:=Weights(35,0,35,0,0,5,0,25,0);
      Mountain:=Weights(5,0,55,0,0,30,0,10,0);StartHeight:=1000;EndHeight:=2600;
    end;
    fpMexico: begin
      Result:=Weights(30,0,40,0,0,0,0,30,0);
      Mountain:=Weights(25,0,55,0,0,10,0,10,0);StartHeight:=1700;EndHeight:=3400;
    end;
    fpCentralAmerica: begin
      Result:=Weights(0,0,10,0,0,0,0,81,0);Result[tsPalm]:=6;Result[tsFanPalm]:=3;
      Mountain:=Weights(15,0,40,0,0,5,0,40,0);StartHeight:=1500;EndHeight:=3000;
    end;
    fpSouthernAndes: begin
      Result:=Weights(0,0,10,0,0,5,0,85,0);
      Mountain:=Weights(0,0,20,0,0,10,0,70,0);StartHeight:=800;EndHeight:=2000;
    end;
    fpAustralasia: begin
      Result:=Weights(0,0,5,0,0,0,0,95,0);
      Mountain:=Weights(0,0,10,0,0,5,0,85,0);StartHeight:=1200;EndHeight:=2400;
    end;
    fpAustralia: begin
      Result:=Weights(0,0,0,0,0,0,0,12,0);Result[tsEucalyptus]:=78;Result[tsAcacia]:=10;
      Mountain:=Weights(0,0,0,0,0,0,0,20,0);Mountain[tsEucalyptus]:=75;Mountain[tsAcacia]:=5;
      StartHeight:=1200;EndHeight:=2400;
    end;
    fpAfricaMontane: begin
      Result:=Weights(0,0,0,0,0,0,0,85,0);Result[tsAcacia]:=15;
      Mountain:=Weights(0,0,5,0,0,10,0,85,0);StartHeight:=1800;EndHeight:=3300;
    end;
  end;
  Blend(Result,Mountain,Smooth(StartHeight,EndHeight,Elevation));
  { Sparse rowan admixture in its temperate / boreal Eurasian range. }
  if P in [fpTemperate,fpBoreal,fpCaucasus,fpWestSiberia] then begin
    Result[tsRowan]:=(Result[tsBirch]+Result[tsBroadleaf])*0.06;
    Result[tsBirch]:=Result[tsBirch]*0.94;Result[tsBroadleaf]:=Result[tsBroadleaf]*0.94;
  end;
end;
function BoxWeight(const R:TRegion;Lat,Lon:Double):Double;
var D,Center:Double;
begin
  Center:=(R.West+R.East)*0.5;
  D:=Lon-Center;D:=Abs(D-360*Round(D/360));
  Result:=(1-Smooth((R.East-R.West)*0.5,(R.East-R.West)*0.5+1.5,D))*
    Smooth(R.South-1.5,R.South,Lat)*(1-Smooth(R.North,R.North+1.5,Lat));
end;
function RegionalForestMix(const Location:TForestLocation;
  const LeafType,LeafCycle,Wetland:string):TForestMix;
var Lat,Lon,H,A,Conifers,Broad,Target,Sum:Double;I:Integer;S:TTreeSpecies;
    WantNeedle,WantBroad,Deciduous,Evergreen:Boolean;W:TForestWeights;
begin
  Result:=Default(TForestMix);Lat:=Location.Latitude;Lon:=Location.Longitude;H:=Location.Elevation;
  if IsNan(Lat) or IsInfinite(Lat) or IsNan(Lon) or IsInfinite(Lon) then
    raise EArgumentException.Create('Invalid forest coordinates');
  Lat:=EnsureRange(Lat,-90.0,90.0);Lon:=Lon-Floor((Lon+180)/360)*360;
  if IsNan(H) or IsInfinite(H) then H:=0;
  Result.Region:='latitude-fallback';Result.Weights:=ProfileMix(fpTropical,H);
  if Lat>0 then begin
    Blend(Result.Weights,ProfileMix(fpTemperate,H),Smooth(24,40,Lat));
    Blend(Result.Weights,ProfileMix(fpBoreal,H),Smooth(50,62,Lat));
  end else Blend(Result.Weights,ProfileMix(fpAustralasia,H),Smooth(25,42,-Lat));
  for I:=Low(Regions) to High(Regions) do begin
    A:=BoxWeight(Regions[I],Lat,Lon);
    if A<=0 then Continue;
    Blend(Result.Weights,ProfileMix(Regions[I].Profile,H),A);
    if A>=0.5 then Result.Region:=Regions[I].Name;
  end;
  { Bamboo groves are a modest lowland admixture only in Asian regions. }
  if (Result.Region='tropical-asia') and (H<1600) then begin
    A:=0.10*(1-Smooth(800,1600,H));
    Result.Weights[tsBamboo]:=Result.Weights[tsBroadleaf]*A;
    Result.Weights[tsBroadleaf]*=1-A;
  end;
  { Generic geographic boxes are deliberately broad. Do not place warm-climate
    plants on the cold northern edge or high mountain limit of those boxes. }
  A:=1-Smooth(33,39,Abs(Lat));
  for S:=tsBamboo to tsFanPalm do begin
    Result.Weights[tsBroadleaf]+=Result.Weights[S]*(1-A);Result.Weights[S]*=A;
  end;
  if Wetland='mangrove' then begin
    Result.Weights:=Weights(0,0,0,0,0,0,0,100,0);Result.Region:=Result.Region+'/mangrove';
  end else if Wetland='swamp' then begin
    if Abs(Lat)>28 then W:=Weights(0,20,0,40,0,0,0,40,0)
    else W:=Weights(0,0,0,0,0,0,0,100,0);
    Blend(Result.Weights,W,0.8);Result.Region:=Result.Region+'/wet-forest';
  end;
  WantNeedle:=(LeafType='needleleaved') or (LeafType='coniferous');
  WantBroad:=(LeafType='broadleaved') or (LeafType='deciduous');
  Deciduous:=(LeafCycle='deciduous') or (LeafType='deciduous');
  Evergreen:=LeafCycle='evergreen';
  for S:=Low(S) to High(S) do begin
    if (WantNeedle and not IsConifer(S)) or (WantBroad and IsConifer(S)) then Result.Weights[S]:=0;
    if Deciduous and IsConifer(S) and (S<>tsLarch) then Result.Weights[S]:=0;
    if Evergreen and (S in [tsBirch,tsMaple,tsWillow,tsLarch,tsRowan]) then Result.Weights[S]:=0;
    if Deciduous and (S in [tsBamboo,tsPalm,tsFanPalm,tsCactus,tsPricklyPear,tsEucalyptus]) then
      Result.Weights[S]:=0;
  end;
  Conifers:=0;Broad:=0;
  for S:=Low(S) to High(S) do
    if IsConifer(S) then Conifers+=Result.Weights[S] else Broad+=Result.Weights[S];
  if (LeafType='mixed') and (Wetland<>'mangrove') then begin
    if Conifers=0 then begin
      if Deciduous then Result.Weights[tsLarch]:=1 else Result.Weights[tsPine]:=1;
      Conifers:=1;
    end;
    if Broad=0 then begin Result.Weights[tsBroadleaf]:=1;Broad:=1;end;
    Target:=EnsureRange(Conifers/(Conifers+Broad),0.2,0.8);
    for S:=Low(S) to High(S) do
      if IsConifer(S) then Result.Weights[S]*=Target/Conifers
      else Result.Weights[S]*=(1-Target)/Broad;
  end;
  Sum:=0;for S:=Low(S) to High(S) do Sum+=Result.Weights[S];
  if Sum<=0 then begin
    if WantNeedle then begin
      if Deciduous then Result.Weights[tsLarch]:=1 else Result.Weights[tsPine]:=1;
    end else Result.Weights[tsBroadleaf]:=1;
    Sum:=1;
  end;
  for S:=Low(S) to High(S) do Result.Weights[S]:=Result.Weights[S]/Sum;
end;
function RegionalScrubMix(const Location:TForestLocation):TForestMix;
var Lat,Lon,H:Double;
begin
  Result:=Default(TForestMix);Result.Region:='generic-scrub';Result.Weights[tsShrub]:=1;
  Lat:=Location.Latitude;Lon:=Location.Longitude;H:=Location.Elevation;
  if IsNan(Lat) or IsInfinite(Lat) or IsNan(Lon) or IsInfinite(Lon) then Exit;
  if IsNan(H) or IsInfinite(H) then H:=0;
  { Cacti are not a worldwide desert default. This small envelope covers
    low-elevation Sonoran scrub; explicit OSM taxa work anywhere. }
  if (Lat>=28) and (Lat<=33.5) and (Lon>=-114.5) and (Lon<=-109.5) and (H<1200) then begin
    Result.Region:='sonoran-scrub';Result.Weights[tsShrub]:=0.55;
    Result.Weights[tsCactus]:=0.20;Result.Weights[tsPricklyPear]:=0.25;
  end;
end;
end.
