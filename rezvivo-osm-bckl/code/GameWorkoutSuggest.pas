unit GameWorkoutSuggest;
{$mode objfpc}{$H+}
interface
uses Classes,WorkoutFile;
type
  TWorkoutGoal=(wgEasy,wgSteady,wgIntervals);
  TWorkoutSuggestion=record Index:Integer;Score:Double;end;
  TWorkoutSuggestions=array of TWorkoutSuggestion;
function WorkoutMatchesGoal(Plan:TWorkoutFile;Goal:TWorkoutGoal):Boolean;
function SuggestWorkouts(Items:TList;Minutes:Integer;Goal:TWorkoutGoal):TWorkoutSuggestions;
implementation
uses Math,SysUtils;

function WorkoutMatchesGoal(Plan:TWorkoutFile;Goal:TWorkoutGoal):Boolean;
var I,Changes:Integer;S:TWorkoutSegment;Work,Duration,Peak,Prev,P:Double;Intervals:Boolean;
begin
  Result:=False;
  if(Plan=nil)or(Plan.Segments.Count=0)then Exit;
  Work:=0;Duration:=0;Peak:=0;Prev:=-1;Changes:=0;Intervals:=False;
  for I:=0 to Plan.Segments.Count-1 do begin
    S:=Plan.Segments[I];
    if(S.Duration<=0)or IsNan(S.Duration)or IsInfinite(S.Duration)then Exit;
    if S.Kind=wskFreeRide then Continue;
    P:=(S.PowerLow+S.PowerHigh)*0.5;
    if IsNan(P)or IsInfinite(P)then Exit;
    Work:=Work+P*S.Duration;Duration:=Duration+S.Duration;
    Peak:=Max(Peak,Max(S.PowerLow,S.PowerHigh));
    Intervals:=Intervals or(S.Kind=wskInterval);
    if S.Kind in[wskSteady,wskInterval]then begin
      if(Prev>=0)and(Abs(P-Prev)>=0.15)then Inc(Changes);
      Prev:=P;
    end;
  end;
  if Duration<=0 then Exit;
  Intervals:=Intervals or(Changes>=3);
  case Goal of
    wgEasy:Result:=(Work/Duration<=0.65)and(Peak<=0.80);
    wgSteady:Result:=not Intervals and(Work/Duration>0.60)and(Peak<=1.05);
    wgIntervals:Result:=Intervals;
  end;
end;

function SuggestWorkouts(Items:TList;Minutes:Integer;Goal:TWorkoutGoal):TWorkoutSuggestions;
var I,J,K,N:Integer;Score:Double;W:TWorkoutFile;
begin
  Result:=nil;if Items=nil then Exit;
  for I:=0 to Items.Count-1 do begin
    W:=TWorkoutFile(Items[I]);if not WorkoutMatchesGoal(W,Goal)then Continue;
    Score:=Abs(W.TotalDuration-Minutes*60)/60;
    { Going over the available time is less useful than a slightly shorter ride. }
    if W.TotalDuration>Minutes*60 then Score:=Score*1.25;
    N:=Length(Result);J:=0;
    while(J<N)and((Result[J].Score<Score)or
      ((Result[J].Score=Score)and(CompareText(TWorkoutFile(Items[Result[J].Index]).Name,W.Name)<=0)))do Inc(J);
    if J>=3 then Continue;
    if N<3 then begin Inc(N);SetLength(Result,N);end;
    for K:=N-1 downto J+1 do Result[K]:=Result[K-1];
    Result[J].Index:=I;Result[J].Score:=Score;
  end;
end;
end.
