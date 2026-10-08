unit RenderComplexity;
{$mode objfpc}{$H+}
interface
uses X3DNodes;
type TRenderDomain=(rdRider,rdWorld);
{ Material algorithms, independent of visibility distance and geometry LOD.
  Full (3) preserves the original shaders; changes reach existing scenes. }
procedure AttachRenderComplexity(Effect:TEffectNode;Domain:TRenderDomain);
procedure SetRenderComplexity(Domain:TRenderDomain;Value:Integer);
function GetRenderComplexity(Domain:TRenderDomain):Integer;
implementation
uses Classes, SysUtils, Math, X3DFields;
type TBinding=class
  Effect:TEffectNode;
  Field:TSFFloat;
  Domain:TRenderDomain;
  procedure Gone(const Node:TX3DNode);
end;
var Bindings:TList;Lock:TRTLCriticalSection;
  Values:array[TRenderDomain]of Integer=(3,3);
procedure TBinding.Gone(const Node:TX3DNode);
begin
  EnterCriticalSection(Lock);
  try Bindings.Remove(Self);finally LeaveCriticalSection(Lock) end;
  Free;
end;
procedure AttachRenderComplexity(Effect:TEffectNode;Domain:TRenderDomain);
var B:TBinding;
begin
  if Effect.Field('rz_complexity')<>nil then Exit;
  EnterCriticalSection(Lock);
  try
    B:=TBinding.Create;B.Effect:=Effect;B.Domain:=Domain;
    B.Field:=TSFFloat.Create(Effect,True,'rz_complexity',Values[Domain]);
    Effect.AddCustomField(B.Field);
    Effect.AddDestructionNotification(@B.Gone);Bindings.Add(B);
  finally LeaveCriticalSection(Lock) end;
end;
procedure SetRenderComplexity(Domain:TRenderDomain;Value:Integer);
var I:Integer;B:TBinding;
begin
  Value:=EnsureRange(Value,0,3);
  EnterCriticalSection(Lock);
  try
    if Values[Domain]=Value then Exit;
    Values[Domain]:=Value;
    for I:=0 to Bindings.Count-1 do begin
      B:=TBinding(Bindings[I]);
      if B.Domain=Domain then B.Field.Send(Value);
    end;
  finally LeaveCriticalSection(Lock) end;
end;
function GetRenderComplexity(Domain:TRenderDomain):Integer;
begin
  EnterCriticalSection(Lock);
  try Result:=Values[Domain];finally LeaveCriticalSection(Lock) end;
end;
procedure ClearBindings;
var B:TBinding;
begin
  while Bindings.Count>0 do begin
    B:=TBinding(Bindings.Last);
    B.Effect.RemoveDestructionNotification(@B.Gone);
    Bindings.Delete(Bindings.Count-1);B.Free;
  end;
end;
initialization InitCriticalSection(Lock);Bindings:=TList.Create;
finalization ClearBindings;Bindings.Free;DoneCriticalSection(Lock);
end.
