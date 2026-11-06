unit GameRideLayout;
{$mode objfpc}{$H+}
interface
const RideRiderCardHeight=44;RideRiderCardGap=3;
  RidePanelPadding=10;RidePanelGap=10;
type TRideHudLayout=record
  CompactMetrics:Boolean;
  Margin,ButtonWidth,ButtonHeight,ButtonGap,ButtonsTop:Single;
  MetricsLeft,MetricsTop,MetricsWidth,MetricsHeight:Single;
  RidersWidth,RidersTop,RidersMaxHeight:Single;
end;
{ All sizes are logical units after physical-DPI/accessibility scaling. }
function RideSmallScreen(Width,Height:Single):Boolean;
function RideHudLayout(Width,Height:Single):TRideHudLayout;
procedure RidePanelHeights(const L:TRideHudLayout;ScreenHeight,HeaderHeight:Single;
  RiderCount:Integer;out ListHeight,MapAvailable:Single);
implementation
uses Math;
function RideSmallScreen(Width,Height:Single):Boolean;
begin
  Result:=(Width>0)and(Height>0)and(Min(Width,Height)<600);
end;

procedure RidePanelHeights(const L:TRideHudLayout;ScreenHeight,HeaderHeight:Single;
  RiderCount:Integer;out ListHeight,MapAvailable:Single);
var Room,Wanted:Single;
begin
  { Reserve the whole container (padding, gaps, header and bottom margin)
    before allocating space to the roster. In landscape the roster scrolls,
    rather than pushing the map below the screen. }
  Room:=Max(0,ScreenHeight-L.RidersTop-L.Margin-2*RidePanelPadding-HeaderHeight);
  if HeaderHeight>0 then Room:=Max(0,Room-RidePanelGap);
  ListHeight:=0;
  if RiderCount>0 then begin
    Room:=Max(0,Room-RidePanelGap);
    Wanted:=Min(L.RidersMaxHeight,RiderCount*(RideRiderCardHeight+RideRiderCardGap)+4);
    ListHeight:=Min(Wanted,Max(0,Room-100));
  end;
  MapAvailable:=Max(0,Room-ListHeight);
end;

function RideHudLayout(Width,Height:Single):TRideHudLayout;
begin
  Width:=Max(1,Width);Height:=Max(1,Height);
  Result.Margin:=8;Result.ButtonWidth:=120;
  Result.ButtonHeight:=32;Result.ButtonGap:=6;Result.ButtonsTop:=8;
  Result.CompactMetrics:=Width<520;
  Result.MetricsTop:=8;
  if Width>=640 then begin
    Result.MetricsWidth:=Min(800,Width-Result.ButtonWidth-4*Result.Margin);
    Result.MetricsLeft:=Max(Result.ButtonWidth+3*Result.Margin,
      (Width-Result.MetricsWidth)/2);
  end else begin
    Result.MetricsWidth:=Max(1,Width-2*Result.Margin);
    Result.MetricsLeft:=Result.Margin;
  end;
  if Result.CompactMetrics then Result.MetricsHeight:=Result.MetricsWidth*(156/360)
  else Result.MetricsHeight:=Result.MetricsWidth*0.148;
  if Width<640 then Result.ButtonsTop:=Result.MetricsTop+Result.MetricsHeight+Result.Margin;
  Result.RidersWidth:=Min(210,Max(170,Width*0.23));
  Result.RidersWidth:=Min(Result.RidersWidth,Max(1,Width-Result.ButtonWidth-4*Result.Margin));
  Result.RidersTop:=Result.MetricsTop+Result.MetricsHeight+Result.Margin;
  Result.RidersMaxHeight:=Max(RideRiderCardHeight,
    Min(4*(RideRiderCardHeight+RideRiderCardGap)+4,
      Height-Result.RidersTop-40));
  if Result.CompactMetrics then Result.RidersMaxHeight:=Min(Result.RidersMaxHeight,
    2*(RideRiderCardHeight+RideRiderCardGap)+4);
end;
end.
