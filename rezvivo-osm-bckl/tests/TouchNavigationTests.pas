program TouchNavigationTests;
{$mode objfpc}{$H+}
uses SysUtils,Math,CastleFilesUtils,CastleUIControls,CastleKeysMouse,CastleVectors,
  GameTouchControls,GameTravel;
type
  TProbeContainer=class(TCastleContainer)
    function PixelsWidth:Integer;override;
    function PixelsHeight:Integer;override;
  end;
function TProbeContainer.PixelsWidth:Integer;
begin Result:=960 end;
function TProbeContainer.PixelsHeight:Integer;
begin Result:=540 end;
procedure Check(Value:Boolean;const Why:string);
begin if not Value then raise Exception.Create(Why) end;
var C:TProbeContainer;UI:TTravelTouchControls;Stick,Action,Look:TTravelTouchPad;
    A,B,P:TVector2;
begin
  ApplicationDataOverride:=IncludeTrailingPathDelimiter(GetCurrentDir)+'data/';
  C:=TProbeContainer.Create(nil);
  try
    UI:=TTravelTouchControls.Create(C);C.Controls.InsertFront(UI);
    Check(UI.Supported,'run with REZVIVO_TEST_TOUCH=1');
    UI.Configure(travelBicycle,True,True,False);C.EventResize;
    Stick:=TTravelTouchPad(UI.FindComponent('TouchMove'));
    Action:=TTravelTouchPad(UI.FindComponent('TouchAction'));
    Look:=TTravelTouchPad(UI.FindComponent('TouchLook'));
    A:=Stick.RenderRect.Center;B:=Action.RenderRect.Center;
    C.EventPress(InputMouseButton(A,buttonLeft,1,[]));
    C.EventMotion(InputMotion(A,A+Vector2(100,0),[buttonLeft],1));
    C.EventUpdate;
    Check(UI.Movement.X>0.9,'first finger steers');
    C.EventPress(InputMouseButton(B,buttonLeft,2,[]));
    Check(UI.PowerAxis=1,'second finger applies power while steering');
    C.EventRelease(InputMouseButton(B,buttonLeft,2,[]));
    Check((UI.PowerAxis=0)and(UI.Movement.X>0.9),'releasing action preserves the other finger');
    P:=Look.RenderRect.Center;
    C.EventPress(InputMouseButton(P,buttonLeft,2,[]));
    C.EventMotion(InputMotion(P,P+Vector2(20,10),[buttonLeft],2));
    C.EventUpdate;
    Check(UI.TakeLook.LengthSqr>1,'look with a second finger');
    Check(UI.Movement.X>0.9,'look cannot steer the first finger');
    C.EventRelease(InputMouseButton(P,buttonLeft,2,[]));
    C.EventRelease(InputMouseButton(Vector2(2,500),buttonLeft,1,[]));
    Check(UI.Movement.LengthSqr=0,'release outside the stick stops steering');
    C.EventPress(InputMouseButton(B,buttonLeft,2,[]));
    UI.Configure(travelBicycle,True,False,False);
    Check((UI.PowerAxis=0)and not Action.Exists,'real sensor takes over and clears captured throttle');
    UI.Configure(travelFlight,True,True,True);
    C.EventPress(InputMouseButton(B,buttonLeft,2,[]));
    Check(UI.VerticalAxis=1,'flight reuses action as climb');
    UI.Configure(travelFlight,False,True,True);
    Check((UI.VerticalAxis=0)and(UI.Movement.LengthSqr=0),'menu/focus loss cancels all input');
    UI.Configure(travelWalk,True,True,False);
    Check(not UI.Fast,'mode change never resumes stale fingers');
    Writeln('PASS multitouch, independent capture, outside release, sensor priority, mode/focus reset');
  finally C.Free end;
end.
