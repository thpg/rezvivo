unit RiderShaderSharing;
{$mode objfpc}{$H+}
interface
uses X3DNodes;
{ Call once after constructing the code and custom field declarations.
  Values (pose, tint, textures) remain private to each effect instance. }
procedure ShareRiderEffect(const Effect:TEffectNode);
implementation
uses SysUtils, MD5;
procedure ShareRiderEffect(const Effect:TEffectNode);
var I:Integer; Code:String; Part:TEffectPartNode;
  procedure Add(const S:String);
  begin Code:=Code+IntToStr(Length(S))+':'+S end;
begin
  Code:='rezvivo-effect-v1';
  Add(IntToStr(Ord(Effect.Language)));
  Add(IntToStr(Ord(Effect.InternalCacheVertexAnimation)));
  for I:=0 to Effect.FdParts.Count-1 do begin
    if not(Effect.FdParts[I] is TEffectPartNode)then Exit;
    Part:=TEffectPartNode(Effect.FdParts[I]);
    Add(IntToStr(Ord(Part.ShaderType)));Add(Part.Contents);
  end;
  for I:=0 to Effect.FdShaderLibraries.Count-1 do Add(Effect.FdShaderLibraries.Items[I]);
  if Effect.InterfaceDeclarations<>nil then
    for I:=0 to Effect.InterfaceDeclarations.Count-1 do begin
      { An input-only event has no retained value to restore on a draw. }
      if Effect.InterfaceDeclarations[I].Field=nil then Exit;
      Add(Effect.InterfaceDeclarations[I].Field.ClassName);
      Add(Effect.InterfaceDeclarations[I].Field.X3DName);
    end;
  Effect.InternalSharedCodeKey:=MD5Print(MD5String(Code));
  Effect.InternalSharedRevisionCache:=True;
end;
end.
