unit Osm3dVegetationBudget;
{$mode objfpc}{$H+}{$modeswitch advancedrecords}
interface
const TREE_CACHE_MAX_BYTES = Int64(512)*1024*1024;
type
  TTreeLoadControl = record
    Level: Integer;
    MeasuredFPS, Target, Warmup, WindowTime, SlowTime, GoodTime: Single;
    WindowFrames, LongFrames: Integer;
    procedure Observe(FrameSeconds, TargetFPS: Single);
    function PlanInterval: Single;
    function UploadInterval: Single;
    function DetailFraction: Single;
    function ActiveFraction: Single;
  end;
{ -1 = refresh rate of the current OpenGL display; 0 = unlimited. }
var VegetationFrameTarget: Single = -1;
procedure SetVegetationFrameLimit(Limit: Single; VSync: Boolean);
function TreeCacheBudget(Used, Free, Total: Int64): Int64;
{ The renderer's 0.35..0.95 range is one complementary atlas/branch fade.
  Keep the distance curve linear here: the fragment shader applies smoothstep. }
function TreeDistanceQuality(Distance, FadeStart, FadeEnd: Single): Single;
function AdvanceTreeQuality(Current, Target, Seconds, FadeSeconds: Single): Single;
implementation
uses Math, Osm3dVegetationQuality;
function TreeDistanceQuality(Distance, FadeStart, FadeEnd: Single): Single;
begin
  if Distance>=FadeEnd then Exit(0);
  if Distance<=FadeStart then Exit(1);
  Result:=0.35+0.6*(FadeEnd-Distance)/Max(0.01,FadeEnd-FadeStart);
end;
function AdvanceTreeQuality(Current, Target, Seconds, FadeSeconds: Single): Single;
var Step:Single;
begin
  { 0..0.35 draws exactly the same atlas. Do not waste fade time there or
    keep a separate single-tree draw alive after the crossfade has finished. }
  if (Current=0) and (Target>0.35) then Current:=0.35;
  Step:=0.6*Max(0,Seconds)/Max(0.1,FadeSeconds);
  if Current<Target then Result:=Min(Target,Current+Step)
  else Result:=Max(Target,Current-Step);
  if (Target=0) and (Result<=0.35) then Result:=0;
end;
procedure SetVegetationFrameLimit(Limit: Single; VSync: Boolean);
begin
  if Limit>0 then VegetationFrameTarget:=Limit
  else if VSync then VegetationFrameTarget:=-1
  else VegetationFrameTarget:=0;
end;
function TreeCacheBudget(Used, Free, Total: Int64): Int64;
var Reserve: Int64;
begin
  if Free<0 then Exit(128*1024*1024);
  Reserve:=Max(Int64(256)*1024*1024,Min(Int64(1024)*1024*1024,Total div 10));
  Result:=Max(Int64(32)*1024*1024,Min(TREE_CACHE_MAX_BYTES,Used+(Free-Reserve) div 2));
  Result:=(Result div (8*1024*1024))*(8*1024*1024);
end;
procedure TTreeLoadControl.Observe(FrameSeconds, TargetFPS: Single);
begin
  if Target<>TargetFPS then begin
    Self:=Default(TTreeLoadControl);Target:=TargetFPS;
  end;
  if Target<=0 then begin Level:=0;Exit;end;
  if FrameSeconds<=0 then Exit;
  { Ignore one loading pause, but repeated 250+ ms frames are a real overload. }
  if FrameSeconds>0.25 then Inc(LongFrames) else LongFrames:=0;
  if LongFrames=1 then begin
    WindowTime:=0;WindowFrames:=0;SlowTime:=0;GoodTime:=0;Exit;
  end;
  FrameSeconds:=Min(FrameSeconds,1);
  Warmup:=Warmup+FrameSeconds;
  if Warmup<2 then Exit;
  WindowTime:=WindowTime+FrameSeconds;Inc(WindowFrames);
  if WindowTime<0.5 then Exit;
  MeasuredFPS:=WindowFrames/WindowTime;
  if MeasuredFPS<Target*0.94 then begin
    SlowTime:=SlowTime+WindowTime;GoodTime:=0;
    if SlowTime>=1.5 then begin Level:=Min(6,Level+1);SlowTime:=0;end;
  end else if MeasuredFPS>=Target*0.96 then begin
    GoodTime:=GoodTime+WindowTime;SlowTime:=0;
    if GoodTime>=6 then begin Level:=Max(0,Level-1);GoodTime:=0;end;
  end else begin SlowTime:=0;GoodTime:=0;end;
  WindowTime:=0;WindowFrames:=0;
end;
function TTreeLoadControl.PlanInterval: Single;
begin Result:=Max(0.08,(0.25+Level*0.125)/Sqrt(Max(0.1,VegetationDetail.TreeCacheRate)));end;
function TTreeLoadControl.UploadInterval: Single;
begin Result:=(0.028+0.03*Level)/Max(0.1,VegetationDetail.TreeCacheRate);end;
function TTreeLoadControl.DetailFraction: Single;
begin Result:=Max(0.35,1-Max(0,Level-1)*0.13);end;
function TTreeLoadControl.ActiveFraction: Single;
begin
  case Level of
    0..2:Result:=1;
    3:Result:=0.85;
    4:Result:=0.65;
    5:Result:=0.5;
    else Result:=0.35;
  end;
end;
end.
