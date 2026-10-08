unit GameMcpNavigation;
{$mode objfpc}{$H+}
interface
uses CastleUIControls;
{ Return to an existing view by dismissing overlays. The pending stack is
  authoritative: a previous operation in this same input/update callback may
  already have closed the Assistant, even though CurrentFrontView has not
  caught up. Never assign Container.View to an already-running ride. }
function ResumeMcpView(Container:TCastleContainer;Target:TCastleView):Boolean;
implementation
function ResumeMcpView(Container:TCastleContainer;Target:TCastleView):Boolean;
var I:Integer;
begin
  Result:=False;if (Container=nil) or (Target=nil) then Exit;
  for I:=0 to Container.PendingViewStackCount-1 do
    if Container.PendingViewStack[I]=Target then begin
      while Container.PendingFrontView<>Target do Container.PopView;
      Exit(True);
    end;
end;
end.
