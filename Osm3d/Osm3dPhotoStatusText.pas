unit Osm3dPhotoStatusText;
{$mode objfpc}{$H+}
interface
uses fpjson;
function PhotoWorkflowCaption(State:TJSONObject):string;
implementation
uses SysUtils,UiTranslations;
function PhotoWorkflowCaption(State:TJSONObject):string;
var S:string;
begin
  Result:='';if State=nil then Exit;S:=State.Get('state','');
  if S='running' then Result:=UiText('Photo task: running')
  else if S='complete' then Result:=UiText('Photo task: complete')
  else if S='complete_with_deferred' then Result:=UiText('Photo task: unresolved details')
  else if S='cancelled' then Result:=UiText('Photo task: stopped')
  else if S='budget_exhausted' then Result:=UiText('Photo task: budget reached')
  else Result:=UiText('Photo task: pending');
  if State.Get('deferred_steps',0)>0 then Result:=Result+Format(UiText(' (%d deferred stages)'),[State.Get('deferred_steps',0)]);
end;
end.
