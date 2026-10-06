unit GameTrainerGrade;
{$mode objfpc}{$H+}
interface
const
  TrainerGradeLimit = 15.0;
  ComfortableGradeLimit = 8.0;
{ Output policy only. Never apply this to route grade or measured power. }
function GradeForTrainer(RoadGrade:Single;SensitivityPercent:Integer):Single;
function SmoothTrainerGrade(Current,Target,Speed,Dt:Single):Single;
implementation
uses Math;
function GradeForTrainer(RoadGrade:Single;SensitivityPercent:Integer):Single;
begin
  if IsNan(RoadGrade)or IsInfinite(RoadGrade)then Exit(0);
  SensitivityPercent:=EnsureRange(SensitivityPercent,0,100);
  Result:=EnsureRange(RoadGrade,-TrainerGradeLimit,TrainerGradeLimit);
  if SensitivityPercent<100 then
    Result:=EnsureRange(Result,-ComfortableGradeLimit,ComfortableGradeLimit)*
      SensitivityPercent/100;
end;
function SmoothTrainerGrade(Current,Target,Speed,Dt:Single):Single;
var Tau:Single;
begin
  Result:=Current;Dt:=EnsureRange(Dt,Single(0),Single(0.25));
  if Dt<=0 then Exit;
  Speed:=Max(0,Speed);
  if Target>Current+0.05 then begin
    Tau:=0.50+Speed/9.81;
    if Current<0.5 then Tau:=Tau+0.70*Speed/9.81;
  end else Tau:=0.30;
  Result:=Current+(Target-Current)*(1-Exp(-Dt/Tau));
  { Reach an exact flat command, instead of retaining a sub-threshold slope. }
  if Abs(Result-Target)<0.01 then Result:=Target;
  Result:=EnsureRange(Result,-TrainerGradeLimit,TrainerGradeLimit);
end;
end.
