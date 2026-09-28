unit RiderEquipment;
{$mode objfpc}{$H+}
interface
uses SysUtils, fpjson;
const
  RiderEquipmentSlots: array[0..2] of string = ('logoChest', 'logoBack', 'helmet');
function RiderEquipmentInfo(Root: TJSONObject; const Slot: string;
  CreateMissing: Boolean = False): TJSONObject;
function RiderEquipmentPath(Root: TJSONObject; const Slot: string): string;
function RiderEquipmentEnabled(Root: TJSONObject; const Slot: string): Boolean;
function EquipmentAbsolutePath(const Path, ModelPath: string): string;
procedure NormalizeEquipmentPaths(Root: TJSONObject; const ModelPath: string);
implementation
uses GltfCore;
function RiderEquipmentInfo(Root: TJSONObject; const Slot: string;
  CreateMissing: Boolean): TJSONObject;
var Ex, Kit: TJSONObject;
  function Child(O: TJSONObject; const Name: string): TJSONObject;
  begin
    Result := ObjOf(O, Name);
    if (Result = nil) and CreateMissing and (O <> nil) then
    begin Result := TJSONObject.Create; O.Add(Name, Result) end;
  end;
begin
  if (Slot <> 'logoChest') and (Slot <> 'logoBack') and (Slot <> 'helmet') then
    raise EArgumentException.Create('Unknown rider equipment slot: ' + Slot);
  Ex := Child(Root, 'extras'); Kit := Child(Ex, 'equipment'); Result := Child(Kit, Slot);
end;
function RiderEquipmentPath(Root: TJSONObject; const Slot: string): string;
var O: TJSONObject;
begin
  O := RiderEquipmentInfo(Root, Slot);
  if Slot = 'helmet' then Result := StrOf(O, 'model', '')
  else Result := StrOf(O, 'image', '');
end;
function RiderEquipmentEnabled(Root: TJSONObject; const Slot: string): Boolean;
var O: TJSONObject;
begin
  O := RiderEquipmentInfo(Root, Slot);
  Result := (O = nil) or O.Get('enabled', True);
end;
function EquipmentAbsolutePath(const Path, ModelPath: string): string;
begin
  Result := Trim(Path);
  if (Result = '') or (Pos(':', Result) > 0) or
     (Result[1] in ['/', '\']) then Exit;
  Result := ExpandFileName(ExtractFilePath(ModelPath) + Result);
end;
procedure NormalizeEquipmentPaths(Root: TJSONObject; const ModelPath: string);
var I: Integer; O: TJSONObject; S, Key: string;
begin
  for I := 0 to High(RiderEquipmentSlots) do
  begin
    O := RiderEquipmentInfo(Root, RiderEquipmentSlots[I]);
    if O = nil then Continue;
    if I = 2 then Key := 'model' else Key := 'image';
    S := StrOf(O, Key, '');
    if S <> '' then
    begin O.Delete(Key); O.Add(Key, EquipmentAbsolutePath(S, ModelPath)) end;
  end;
end;
end.
