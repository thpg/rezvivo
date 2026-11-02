program RideHudLayoutTests;
{$mode objfpc}{$H+}
uses SysUtils,Math,GameRideLayout,GameMenuLayout;
procedure Check(Value:Boolean;const Msg:String);
begin if not Value then raise Exception.Create(Msg) end;
const Widths:array[0..7]of Integer=(320,360,411,640,800,960,1280,1920);
  Heights:array[0..3]of Integer=(360,540,760,1080);
var W,H,N:Integer;L,P:TRideHudLayout;Scale,ListHeight,MapAvailable,PanelHeight:Single;
begin
  for W in Widths do for H in Heights do begin
    L:=RideHudLayout(W,H);
    Check(L.MetricsLeft>=0,'metrics outside left edge');
    Check(L.MetricsLeft+L.MetricsWidth<=W,'metrics outside right edge');
    Check(L.ButtonsTop+3*L.ButtonHeight+2*L.ButtonGap<=H,'buttons outside bottom');
    Check((L.ButtonsTop>=L.MetricsTop+L.MetricsHeight)or
      (L.Margin+L.ButtonWidth<=L.MetricsLeft),'buttons overlap metrics');
    Check(L.RidersTop>=L.MetricsTop+L.MetricsHeight,'riders overlap metrics');
    Check(L.RidersTop+L.RidersMaxHeight<=H,'rider list outside bottom');
    Check(W-L.RidersWidth-L.Margin>L.ButtonWidth+L.Margin,'riders overlap buttons');
    Check(L.MetricsWidth<=800,'wide window enlarged metrics without limit');
    for N:=0 to 20 do begin
      RidePanelHeights(L,H,48,N,ListHeight,MapAvailable);
      PanelHeight:=48+2*RidePanelPadding+RidePanelGap+ListHeight+MapAvailable;
      if N>0 then PanelHeight:=PanelHeight+RidePanelGap;
      Check(L.RidersTop+PanelHeight+L.Margin<=H+0.01,'combined ride panel below screen');
      Check((ListHeight>=0)and(MapAvailable>=0),'negative ride panel area');
    end;
    if W<520 then begin
      Check(L.CompactMetrics,'narrow HUD was reduced instead of reflowed');
      Check(L.MetricsHeight>=130,'portrait readings too small');
      Check(L.RidersMaxHeight<=2*(RideRiderCardHeight+RideRiderCardGap)+4,
        'portrait rider list obscures too much of the view');
    end;
  end;
  Scale:=MenuInterfaceScale(2400,1080,480,1,True);
  L:=RideHudLayout(2400/Scale,1080/Scale);
  Check(L.MetricsWidth*Scale>1800,'phone metrics remain pixel-capped');
  Check(L.RidersWidth*Scale<600,'phone rider list too wide');
  Check(L.ButtonHeight*Scale<110,'phone buttons too tall');
  RidePanelHeights(L,1080/Scale,48,10,ListHeight,MapAvailable);
  Check(MapAvailable>=99.9,'landscape map too short');
  Check(ListHeight>=RideRiderCardHeight,'landscape list cannot show a rider');
  Scale:=MenuInterfaceScale(1200,540,240,1,True);
  P:=RideHudLayout(1200/Scale,540/Scale);
  Check(Abs(P.MetricsWidth-L.MetricsWidth)<0.01,'layout depends on resolution, not physical size');
  P:=RideHudLayout(1080/3,2400/3);
  Check(P.CompactMetrics,'phone portrait needs compact metrics');
  Check(P.ButtonsTop>P.MetricsTop+P.MetricsHeight,'portrait controls overlap reflowed HUD');
  Check(not RideHudLayout(2400/3,1080/3).CompactMetrics,'rotation did not restore wide HUD');
  Writeln('PASS ride HUD bounds, non-overlap, physical scaling, compact controls and roster');
end.
