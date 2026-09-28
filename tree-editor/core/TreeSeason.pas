unit TreeSeason;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses TreeMath,TreeModel;
type
  { Environment input, independent of the packed identity and geometry cache.
    0 = spring, .25 = summer, .5 = autumn, .75 = winter; periodic. }
  TTreeSeasonState = record
    LeafAmount,Spring,Autumn: Single;
    LeafColor: TTreeVec3;
  end;
const TREE_SUMMER = 0.25;
function WrapTreeSeason(Phase: Single): Single;
function AdvanceTreeSeason(Current,Target,MaxStep: Single): Single;
function TreeEvergreen(Species: TTreeSpecies): Boolean;
function EvaluateTreeSeason(Species: TTreeSpecies; const SummerColor: TTreeVec3; Phase: Single): TTreeSeasonState;
function TreeFruitAmount(Species:TTreeSpecies;Phase:Single):Single;
implementation
uses Math,SysUtils;
function WrapTreeSeason(Phase: Single): Single;
begin
  if IsNan(Phase) or IsInfinite(Phase) then raise EArgumentException.Create('Invalid season phase');
  Result:=Phase-Floor(Phase);
end;
function AdvanceTreeSeason(Current,Target,MaxStep: Single): Single;
var Delta: Single;
begin
  Current:=WrapTreeSeason(Current); Target:=WrapTreeSeason(Target);
  Delta:=Target-Current; if Delta>0.5 then Delta:=Delta-1 else if Delta< -0.5 then Delta:=Delta+1;
  Result:=WrapTreeSeason(Current+Clamp(Delta,-Max(0,MaxStep),Max(0,MaxStep)));
end;
function TreeEvergreen(Species: TTreeSpecies): Boolean;
begin Result:=Species in [tsPine,tsMountainPine,tsSpruce,tsJuniper,
  tsBamboo,tsPalm,tsFanPalm,tsCactus,tsPricklyPear,tsEucalyptus,tsAcacia]; end;
function Smooth(A,B,X: Single): Single;
begin Result:=Clamp((X-A)/(B-A),0,1); Result:=Result*Result*(3-2*Result); end;
function TreeFruitAmount(Species:TTreeSpecies;Phase:Single):Single;
begin
  if IsConifer(Species) then Exit(1);
  Phase:=WrapTreeSeason(Phase);
  if Species=tsRowan then Result:=Smooth(0.12,0.24,Phase)*(1-Smooth(0.70,0.86,Phase))
  else Result:=Smooth(0.10,0.22,Phase)*(1-Smooth(0.55,0.68,Phase));
end;
function EvaluateTreeSeason(Species: TTreeSpecies; const SummerColor: TTreeVec3; Phase: Single): TTreeSeasonState;
const Offset: array[tsOak..tsRowan] of Single = (0.018,-0.012,0,0.015,0,0,0,-0.005,-0.008,0,-0.014,0.006,0.018,0.006);
      Fall: array[tsOak..tsRowan] of TTreeVec3 = (
        (X:0.69;Y:0.37;Z:0.12),(X:0.96;Y:0.76;Z:0.12),(X:0.25;Y:0.39;Z:0.24),
        (X:0.80;Y:0.67;Z:0.17),(X:0.23;Y:0.37;Z:0.24),(X:0.22;Y:0.35;Z:0.28),
        (X:0.77;Y:0.40;Z:0.17),(X:0.30;Y:0.40;Z:0.34),(X:0.94;Y:0.34;Z:0.06),
        (X:0.88;Y:0.63;Z:0.13),(X:0.96;Y:0.78;Z:0.17),(X:0.86;Y:0.42;Z:0.12),
        (X:0.95;Y:0.72;Z:0.16),(X:0.87;Y:0.30;Z:0.07));
var P,Rise,FallAmount: Single; YoungColor,AutumnColor: TTreeVec3;
begin
  if Species<=tsRowan then P:=WrapTreeSeason(Phase-Offset[Species])
  else P:=WrapTreeSeason(Phase);
  if P>0.80 then P:=P-1;
  Rise:=Smooth(-0.065,0.12,P); FallAmount:=Smooth(0.49,0.665,P);
  Result.Spring:=(1-Smooth(0.015,0.19,P))*Rise;
  Result.Autumn:=Smooth(0.345,0.51,P);
  Result.LeafAmount:=Rise*(1-FallAmount);
  YoungColor:=ColorToLinear(Vec(0.50,0.69,0.22));
  if Species<=tsRowan then AutumnColor:=ColorToLinear(Fall[Species]) else AutumnColor:=SummerColor;
  if TreeEvergreen(Species) then begin
    Result.LeafAmount:=1; Result.Autumn:=0;
    Result.LeafColor:=Mix(SummerColor,YoungColor,Result.Spring*0.16);
  end else begin
    Result.LeafColor:=Mix(SummerColor,YoungColor,Result.Spring*0.62);
    AutumnColor:=Mix(AutumnColor,ColorToLinear(Vec(0.42,0.23,0.085)),FallAmount*0.7);
    Result.LeafColor:=Mix(Result.LeafColor,AutumnColor,Result.Autumn);
  end;
end;
end.
