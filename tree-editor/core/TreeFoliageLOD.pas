unit TreeFoliageLOD;
{$mode objfpc}{$H+}
interface
uses TreeModel;
const DISTANT_NEEDLE_TRIANGLES = 120000;
      NEEDLE_COVERAGE_VERSION = 2;
      NEEDLE_DENSITY_GROUPS = 4;
      NEEDLE_GROUP_PAIRS:array[0..NEEDLE_DENSITY_GROUPS-1]of Integer=(64,128,256,512);
{ Short, almost straight needles need one tapered triangle. Long pine needles
  retain the curved three-triangle ribbon. No per-needle CPU data is stored. }
function NeedleVertices(Species:TTreeSpecies):Integer;
function NearNeedleDetail(Distance:Single):Single;
function NeedleDensityGroup(const Shoot:TTreeNeedleShoot;const Params:TTreeParams):Integer;
function DrawNeedlePairs(FullPairs,Shoots:Integer;Species:TTreeSpecies;
  LeafFraction,NearDetail:Single):Integer;
implementation
uses Math, TreeMath;
function NeedleDensityGroup(const Shoot:TTreeNeedleShoot;const Params:TTreeParams):Integer;
var LengthM,ReferenceLength,Pairs:Single;
begin
  { Density describes a length of shoot, not a fixed count on twigs that can
    differ tenfold in size. Bands bound shader work and require only four draws. }
  LengthM:=(Magnitude(Sub(Shoot.Control,Shoot.Start))+Magnitude(Sub(Shoot.Tip,Shoot.Control))+
    Magnitude(Sub(Shoot.Tip,Shoot.Start)))*0.5;
  case Params.Species of
    tsSpruce:ReferenceLength:=0.12;
    tsLarch:ReferenceLength:=0.14;
    tsJuniper:ReferenceLength:=0.08;
    else ReferenceLength:=0.14;
  end;
  Pairs:=NeedlePairsPerShoot(Params.LeafDensity)*LengthM/ReferenceLength;
  Result:=0;
  while (Result<NEEDLE_DENSITY_GROUPS-1) and
    (Pairs>Sqrt(NEEDLE_GROUP_PAIRS[Result]*NEEDLE_GROUP_PAIRS[Result+1])) do Inc(Result);
end;
function NeedleVertices(Species:TTreeSpecies):Integer;
begin
  if Species in [tsSpruce,tsJuniper,tsLarch] then Result:=3 else Result:=9;
end;
function NearNeedleDetail(Distance:Single):Single;
var T:Single;
begin
  T:=Max(0,Min(1,(16-Distance)/10));
  Result:=T*T*(3-2*T); { individual needles within 6 m; integrated shoots after 16 m }
end;
function DrawNeedlePairs(FullPairs,Shoots:Integer;Species:TTreeSpecies;
  LeafFraction,NearDetail:Single):Integer;
var Coarse:Integer; Cost:Int64; T:Single;
begin
  if (FullPairs<=0) or (Shoots<=0) then Exit(0);
  Cost:=Int64(Shoots)*NeedlesPerFascicle(Species)*(NeedleVertices(Species) div 3);
  Coarse:=Max(1,Min(FullPairs,DISTANT_NEEDLE_TRIANGLES div Cost));
  if LeafFraction>0 then Coarse:=Max(1,Round(Coarse*Sqrt(Min(1,LeafFraction))));
  T:=Max(0,Min(1,NearDetail));
  Result:=Min(FullPairs,Max(1,Round(Coarse+(FullPairs-Coarse)*T)));
end;
end.
