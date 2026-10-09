unit GameGraphicsAutoPolicy;

{$mode objfpc}{$H+}

interface

uses GameGraphicsOptions;

function GraphicsAutoCandidate(Tier:Integer;const Original:TGraphicsValues;
  MemoryTier:Integer=4):TGraphicsValues;
function AutoTargetFPS(const Original:TGraphicsValues):Integer;
{ Inputs are MiB, not bytes. Unknown free space never authorizes high/ultra.
  Thresholds apply after a reserve for streaming and other GPU processes. }
function GraphicsAutoMemoryTier(FreeMiB,TotalMiB:Int64;Known:Boolean):Integer;
{ Samples are chronological, finite positive frame durations in milliseconds.
  Infinity means there are not enough valid measurements to make a choice. }
function GraphicsAutoScore(const Samples:array of Double):Double;
function GraphicsAutoPass(Ms:Double;TargetFPS:Integer):Boolean;

implementation

uses Math;

function GraphicsAutoCandidate(Tier:Integer;const Original:TGraphicsValues;
  MemoryTier:Integer):TGraphicsValues;
const
  ShadowSize:array[0..4]of Integer=(0,1024,2048,2048,4096);
  ShadowFilter:array[0..4]of Integer=(1,4,4,16,16);
  ShadowDistance:array[0..4]of Integer=(60,60,100,160,160);
  Textures:array[0..4]of Integer=(0,1,2,3,3);
begin
  Tier:=EnsureRange(Tier,0,4);Result:=Original;
  Result[goShadowSize]:=ShadowSize[Tier];
  Result[goShadowFilter]:=ShadowFilter[Tier];
  Result[goShadowDistance]:=ShadowDistance[Tier];
  Result[goGrass]:=Ord(Tier>0);
  Result[goTrees]:=Tier;
  Result[goHair]:=EnsureRange(Tier-1,0,3);
  Result[goRiderComplexity]:=Min(Tier,3);
  Result[goWorldComplexity]:=Min(Tier,3);
  Result[goVegetationComplexity]:=Min(Tier,3);
  { Geometry/shadow cost and texture memory are different limits. A slow
    forest must not blur the road and rider when VRAM is plentiful. Keep
    the chosen texture quality unless the measured memory budget limits it. }
  Result[goTextures]:=Min(Original[goTextures],Textures[EnsureRange(MemoryTier,0,4)]);
  if Tier<=1 then Result[goVegetationCache]:=0 else Result[goVegetationCache]:=1;
  Result[goVegetationAdaptive]:=1;
  { The probe cannot change the live framebuffer's MSAA sample count.
    Preserve AA and the user's frame limit; the runner may temporarily
    remove frame pacing, then restore these exact original choices. }
end;

function AutoTargetFPS(const Original:TGraphicsValues):Integer;
begin
  Result:=Original[goFrameLimit];
  if Result<=0 then Result:=60;
end;

function GraphicsAutoMemoryTier(FreeMiB,TotalMiB:Int64;Known:Boolean):Integer;
var ReserveMiB,AvailableMiB:Int64;
begin
  if not Known or (FreeMiB<0) then Exit(2);
  ReserveMiB:=256;
  if TotalMiB>0 then begin
    FreeMiB:=Min(FreeMiB,TotalMiB);
    ReserveMiB:=Max(Int64(256),Min(Int64(1024),TotalMiB div 10));
  end;
  AvailableMiB:=Max(Int64(0),FreeMiB-ReserveMiB);
  if AvailableMiB<384 then Result:=0
  else if AvailableMiB<768 then Result:=1
  else if AvailableMiB<1536 then Result:=2
  else if AvailableMiB<3072 then Result:=3
  else Result:=4;
end;

function GraphicsAutoScore(const Samples:array of Double):Double;
var Ordered:array of Double;Recent:array[0..7]of Double;
    I,J,N,RecentCount,P90Index:Integer;
    Value,RecentTotal,RecentMax,Tail:Double;
begin
  Result:=Infinity;N:=0;RecentCount:=0;
  SetLength(Ordered,Length(Samples));
  for I:=0 to High(Samples) do begin
    Value:=Samples[I];
    if IsNan(Value)or IsInfinite(Value)or(Value<=0)then Continue;
    Ordered[N]:=Value;Recent[N mod Length(Recent)]:=Value;Inc(N);
  end;
  if N<8 then Exit;
  { Probe windows are short (normally 30..60 frames). Insertion sort keeps
    the policy independent of renderer/collection units and never mutates
    the caller's chronological samples. }
  for I:=1 to N-1 do begin
    Value:=Ordered[I];J:=I-1;
    while (J>=0)and(Ordered[J]>Value)do begin Ordered[J+1]:=Ordered[J];Dec(J);end;
    Ordered[J+1]:=Value;
  end;
  P90Index:=Ceil(N*0.9)-1;Result:=Ordered[P90Index];
  { A single OS scheduling/driver outlier is not a sustained load. Repeated
    slow frames still matter even when they occupy less than 10% of a run. }
  Tail:=(Ordered[N-2]+Ordered[N-3])*0.5;
  Result:=Max(Result,Tail*0.75);
  { Reject a configuration that is starting to slow down at the end of the
    probe (e.g. its geometry cache becomes populated). Trim one spike only. }
  RecentCount:=Min(N,Length(Recent));RecentTotal:=0;RecentMax:=0;
  for I:=0 to RecentCount-1 do begin
    RecentTotal:=RecentTotal+Recent[I];RecentMax:=Max(RecentMax,Recent[I]);
  end;
  Result:=Max(Result,(RecentTotal-RecentMax)/(RecentCount-1));
end;

function GraphicsAutoPass(Ms:Double;TargetFPS:Integer):Boolean;
begin
  Result:=(TargetFPS>0)and not IsNan(Ms)and not IsInfinite(Ms)and(Ms>0);
  if Result then Result:=Ms<=1000.0*0.85/TargetFPS;
end;

end.
