unit GameTravelUI;
{$mode objfpc}{$H+}{$codepage utf8}
interface
uses Classes, GameTravel;
function TravelTextSource(const Source:string;Mode:TTravelMode):string;
procedure BindTravelText(Target:TComponent;const Source:string;
  const PropName:string='Caption');
procedure RefreshTravelTexts;
implementation
uses SysUtils, AppSettings, UiTranslations;
type
  TTravelTextBinding=class(TComponent)
  public
    Source,PropName:string;
    procedure Refresh;
    destructor Destroy;override;
  end;
var Bindings:TList;

function TravelTextSource(const Source:string;Mode:TTravelMode):string;
const Texts:array[0..14,0..2]of string=(
  ('Just ride','Just run','Just fly'),
  ('YOUR NEXT RIDE','YOUR NEXT RUN','YOUR NEXT FLIGHT'),
  ('Where will you ride today?','Where will you run today?','Where will you fly today?'),
  ('A ride, a workout, a new route. Start with what feels right.',
   'A walk, a run, a new place. Explore at your own pace.',
   'Explore the world from above. Choose a place and take off.'),
  ('Ride with a friend','Run with a friend','Fly with a friend'),
  ('Return to ride','Return to run','Return to flight'),
  ('Finish ride','Finish run','Finish flight'),
  ('Ride continues while this menu is open','Run continues while this menu is open','Flight continues while this menu is open'),
  ('Start ride','Start run','Start flight'),
  ('Start another ride','Start another run','Start another flight'),
  ('Rider','Avatar','Avatar'),
  ('Ride pose and animation','Movement and animation','Movement and animation'),
  ('Changes apply to the rider in the current ride','Changes apply to the current avatar','Changes apply to the current avatar'),
  ('Saved and applied to the current ride.','Saved and applied to the current run.','Saved and applied to the current flight.'),
  ('Saved — applies to the next ride.','Saved — applies to the next run.','Saved — applies to the next flight.'));
var I,Col:Integer;
begin
  Col:=0;if Mode=travelWalk then Col:=1 else if Mode=travelFlight then Col:=2;
  for I:=Low(Texts)to High(Texts)do if Source=Texts[I,0]then Exit(Texts[I,Col]);
  Result:=Source;
  if Mode<>travelBicycle then begin
    if Source='Rider and bicycle'then Result:='Avatar';
    if Source='My rides'then Result:='My activities';
  end;
end;

procedure TTravelTextBinding.Refresh;
begin BindUiText(Owner,TravelTextSource(Source,Settings.TravelMode),PropName) end;
destructor TTravelTextBinding.Destroy;
begin if Bindings<>nil then Bindings.Remove(Self);inherited end;
procedure BindTravelText(Target:TComponent;const Source,PropName:string);
var C:TComponent;B:TTravelTextBinding;
begin
  if Target=nil then Exit;
  C:=Target.FindComponent('TravelText_'+PropName);
  if C is TTravelTextBinding then B:=TTravelTextBinding(C)
  else begin B:=TTravelTextBinding.Create(Target);B.Name:='TravelText_'+PropName;Bindings.Add(B) end;
  B.Source:=Source;B.PropName:=PropName;B.Refresh;
end;
procedure RefreshTravelTexts;
var I:Integer;
begin for I:=0 to Bindings.Count-1 do TTravelTextBinding(Bindings[I]).Refresh end;
initialization Bindings:=TList.Create;
finalization FreeAndNil(Bindings);
end.
