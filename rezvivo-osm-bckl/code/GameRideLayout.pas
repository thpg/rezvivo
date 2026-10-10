unit GameRideLayout;
{$mode objfpc}{$H+}
interface
const RideRiderCardHeight=36;RideRiderCardGap=3;
type TRideHudLayout=record
  Margin,ButtonWidth,ButtonHeight,ButtonGap,ButtonsTop:Single;
  MetricsLeft,MetricsTop,MetricsWidth,MetricsHeight:Single;
  RidersWidth,RidersTop,RidersMaxHeight:Single;
end;
{ All sizes are logical units after physical-DPI/accessibility scaling. }
function RideHudLayout(Width,Height:Single):TRideHudLayout;
implementation
uses Math;
function RideHudLayout(Width,Height:Single):TRideHudLayout;
begin
  Width:=Max(1,Width);Height:=Max(1,Height);
  Result.Margin:=8;Result.ButtonWidth:=120;
  Result.ButtonHeight:=32;Result.ButtonGap:=6;Result.ButtonsTop:=8;
  Result.MetricsTop:=8;
  if Width>=640 then begin
    Result.MetricsWidth:=Min(800,Width-Result.ButtonWidth-4*Result.Margin);
    Result.MetricsLeft:=Max(Result.ButtonWidth+3*Result.Margin,
      (Width-Result.MetricsWidth)/2);
  end else begin
    Result.MetricsWidth:=Max(1,Width-2*Result.Margin);
    Result.MetricsLeft:=Result.Margin;
    Result.ButtonsTop:=Result.MetricsTop+Result.MetricsWidth*0.148+Result.Margin;
  end;
  Result.MetricsHeight:=Result.MetricsWidth*0.148;
  Result.RidersWidth:=Min(210,Max(170,Width*0.23));
  Result.RidersWidth:=Min(Result.RidersWidth,Max(1,Width-Result.ButtonWidth-4*Result.Margin));
  Result.RidersTop:=Result.MetricsTop+Result.MetricsHeight+Result.Margin;
  Result.RidersMaxHeight:=Max(RideRiderCardHeight,
    Min(4*(RideRiderCardHeight+RideRiderCardGap)+4,
      Height-Result.RidersTop-40));
end;
end.
