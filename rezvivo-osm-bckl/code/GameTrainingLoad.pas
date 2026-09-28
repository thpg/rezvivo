unit GameTrainingLoad;
{$mode objfpc}{$H+}
interface
uses fpjson;
type
  { Matches the server's NP: one-second power means, full 30-second windows,
    fourth-power mean. Missing telemetry breaks the window, not measured work. }
  TTrainingLoad = class
  private
    FRing: array[0..29] of Double;
    FNext,FCount: Integer;
    FSum,FPartialSeconds,FPartialWork,FSum4,FWindows,FSeconds,FFtp: Double;
    procedure ClearWindow;
    function GetTSS: Double;
  public
    procedure Reset;
    procedure Step(Watts,Seconds,Ftp: Double; Active,Valid: Boolean);
    function SaveState:TJSONObject;
    procedure RestoreState(O:TJSONObject);
    property TSS: Double read GetTSS;
  end;
implementation
uses Math;
function TTrainingLoad.SaveState:TJSONObject;
var A:TJSONArray;I:Integer;
begin
  Result:=TJSONObject.Create(['next',FNext,'count',FCount,'sum',FSum,
    'partial_seconds',FPartialSeconds,'partial_work',FPartialWork,
    'sum4',FSum4,'windows',FWindows,'seconds',FSeconds,'ftp',FFtp]);
  A:=TJSONArray.Create;for I:=0 to 29 do A.Add(FRing[I]);Result.Add('ring',A);
end;
procedure TTrainingLoad.RestoreState(O:TJSONObject);
var I:Integer;A:TJSONData;
begin
  Reset;if O=nil then Exit;A:=O.Find('ring');
  if not(A is TJSONArray)or(A.Count<>30)then Exit;
  FNext:=EnsureRange(O.Get('next',0),0,29);FCount:=EnsureRange(O.Get('count',0),0,30);
  FSum:=O.Get('sum',0.0);FPartialSeconds:=EnsureRange(O.Get('partial_seconds',0.0),0.0,1.0);
  FPartialWork:=Max(Double(0),O.Get('partial_work',0.0));FSum4:=Max(Double(0),O.Get('sum4',0.0));
  FWindows:=Max(Double(0),O.Get('windows',0.0));FSeconds:=Max(Double(0),O.Get('seconds',0.0));FFtp:=Max(Double(0),O.Get('ftp',0.0));
  for I:=0 to 29 do FRing[I]:=A.Items[I].AsFloat;
end;
procedure TTrainingLoad.ClearWindow;
begin
  FNext:=0;FCount:=0;FSum:=0;FPartialSeconds:=0;FPartialWork:=0;
end;
procedure TTrainingLoad.Reset;
begin
  ClearWindow;FSum4:=0;FWindows:=0;FSeconds:=0;FFtp:=0;
end;
procedure TTrainingLoad.Step(Watts,Seconds,Ftp: Double;Active,Valid:Boolean);
var Dt,P,M:Double;
begin
  { Replayed frames have no accounting duration. They must not erase the
    rolling power window, even when their old telemetry was missing/paused. }
  if IsNan(Seconds) or IsInfinite(Seconds) or (Seconds<=0) then Exit;
  if not Active or not Valid or IsNan(Watts) or IsInfinite(Watts) then
  begin ClearWindow;Exit end;
  if (Ftp<=0) or IsNan(Ftp) or IsInfinite(Ftp) then begin ClearWindow;Exit end;
  FFtp:=Ftp;P:=Max(0,Watts);FSeconds:=FSeconds+Seconds;
  while Seconds>1e-10 do begin
    Dt:=Min(Seconds,1-FPartialSeconds);Seconds:=Seconds-Dt;
    FPartialSeconds:=FPartialSeconds+Dt;FPartialWork:=FPartialWork+Dt*P;
    if FPartialSeconds>=1-1e-10 then begin
      if FCount=30 then FSum:=FSum-FRing[FNext] else Inc(FCount);
      FRing[FNext]:=FPartialWork/FPartialSeconds;FSum:=FSum+FRing[FNext];
      FNext:=(FNext+1) mod 30;FPartialSeconds:=0;FPartialWork:=0;
      if FCount=30 then begin M:=Max(0,FSum/30);FSum4:=FSum4+Sqr(Sqr(M));FWindows:=FWindows+1 end;
    end;
  end;
end;
function TTrainingLoad.GetTSS:Double;
begin
  if (FFtp>0) and (FWindows>0) then Result:=FSeconds*Sqrt(FSum4/FWindows)/(36*Sqr(FFtp))
  else Result:=0;
end;
end.
