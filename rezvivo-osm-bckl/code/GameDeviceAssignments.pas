{ Persistent intent is independent of discovery order and connection lifetime.
  Device names are display labels, never identifiers. No GL or transport code. }
unit GameDeviceAssignments;
{$mode objfpc}{$H+}
interface
uses SysUtils, fpjson;
type
  TDeviceRole = (drHeartRate, drPower, drCadence, drSpeed, drControllable);
  TDeviceSelectionMode = (dsmAutomatic, dsmNone, dsmDevice);
  TDeviceSelection = record
    Mode: TDeviceSelectionMode;
    Transport, Address, Name: String;
  end;
  TDeviceRoleAssignments = class
  private
    FSelections: array[TDeviceRole] of TDeviceSelection;
    function GetSelection(Role: TDeviceRole): TDeviceSelection;
  public
    procedure Reset(Disabled: Boolean = False);
    { nil = a new profile; malformed/unknown schema fails closed. }
    procedure LoadJSON(Data: TJSONData);
    function ToJSON: TJSONObject;
    function Select(Role: TDeviceRole; const Transport, Address,
      Name: String): Boolean;
    function Disable(Role: TDeviceRole): Boolean;
    function Matches(Role: TDeviceRole; const Transport, Address: String): Boolean;
    function Allows(Role: TDeviceRole; const Transport, Address: String): Boolean;
    function HasRemembered: Boolean;
    function UsesDevice(const Transport, Address: String): Boolean;
    property Selection[Role: TDeviceRole]: TDeviceSelection read GetSelection;
  end;
const
  DeviceRoleKeys: array[TDeviceRole] of String =
    ('heart_rate', 'power', 'cadence', 'speed', 'controllable');
implementation

function JsonString(O: TJSONObject; const Key: String): String;
var D: TJSONData;
begin
  Result := '';
  D := O.Find(Key);
  if (D <> nil) and (D.JSONType = jtString) then Result := D.AsString;
end;

function TDeviceRoleAssignments.GetSelection(Role: TDeviceRole): TDeviceSelection;
begin Result := FSelections[Role]; end;

procedure TDeviceRoleAssignments.Reset(Disabled: Boolean);
var R: TDeviceRole;
begin
  for R := Low(TDeviceRole) to High(TDeviceRole) do
  begin
    FSelections[R] := Default(TDeviceSelection);
    if Disabled then FSelections[R].Mode := dsmNone;
  end;
end;

function TDeviceRoleAssignments.Disable(Role: TDeviceRole): Boolean;
begin
  Result := FSelections[Role].Mode <> dsmNone;
  FSelections[Role] := Default(TDeviceSelection);
  FSelections[Role].Mode := dsmNone;
end;

function TDeviceRoleAssignments.Select(Role: TDeviceRole;
  const Transport, Address, Name: String): Boolean;
var S: TDeviceSelection;
begin
  if (Trim(Transport) = '') or (Trim(Address) = '') then Exit(Disable(Role));
  S.Mode := dsmDevice;
  S.Transport := LowerCase(Trim(Transport));
  S.Address := LowerCase(Trim(Address));
  S.Name := Trim(Name);
  Result := (FSelections[Role].Mode <> S.Mode) or
    (FSelections[Role].Transport <> S.Transport) or
    (FSelections[Role].Address <> S.Address) or (FSelections[Role].Name <> S.Name);
  FSelections[Role] := S;
end;

function TDeviceRoleAssignments.Matches(Role: TDeviceRole;
  const Transport, Address: String): Boolean;
begin
  Result := (FSelections[Role].Mode = dsmDevice) and
    SameText(FSelections[Role].Transport, Trim(Transport)) and
    SameText(FSelections[Role].Address, Trim(Address));
end;

function TDeviceRoleAssignments.Allows(Role: TDeviceRole;
  const Transport, Address: String): Boolean;
begin
  Result := (FSelections[Role].Mode = dsmAutomatic) or Matches(Role, Transport, Address);
end;

function TDeviceRoleAssignments.HasRemembered: Boolean;
var R: TDeviceRole;
begin
  for R := Low(TDeviceRole) to High(TDeviceRole) do
    if FSelections[R].Mode <> dsmAutomatic then Exit(True);
  Result := False;
end;

function TDeviceRoleAssignments.UsesDevice(const Transport, Address: String): Boolean;
var R: TDeviceRole;
begin
  for R := Low(TDeviceRole) to High(TDeviceRole) do
    if Matches(R, Transport, Address) then Exit(True);
  Result := False;
end;

procedure TDeviceRoleAssignments.LoadJSON(Data: TJSONData);
var R: TDeviceRole; O, V: TJSONObject; D: TJSONData; Mode: String;
begin
  Reset(Data <> nil);
  if Data = nil then Exit;
  if not (Data is TJSONObject) then Exit;
  O := TJSONObject(Data);
  D := O.Find('version');
  if (D = nil) or (D.JSONType <> jtNumber) or (D.AsInteger <> 1) then Exit;
  for R := Low(TDeviceRole) to High(TDeviceRole) do
  begin
    D := O.Find(DeviceRoleKeys[R]);
    if D = nil then
    begin
      FSelections[R] := Default(TDeviceSelection);
      Continue;
    end;
    if not (D is TJSONObject) then Continue;
    V := TJSONObject(D);
    Mode := JsonString(V, 'mode');
    if Mode = 'device' then Select(R, JsonString(V, 'transport'),
      JsonString(V, 'address'), JsonString(V, 'name'))
    else if Mode = 'auto' then FSelections[R] := Default(TDeviceSelection);
  end;
end;

function TDeviceRoleAssignments.ToJSON: TJSONObject;
var R: TDeviceRole; O: TJSONObject; S: TDeviceSelection;
begin
  Result := TJSONObject.Create(['version', 1]);
  for R := Low(TDeviceRole) to High(TDeviceRole) do
  begin
    S := FSelections[R];
    if S.Mode = dsmAutomatic then Continue;
    if S.Mode = dsmNone then O := TJSONObject.Create(['mode', 'none'])
    else O := TJSONObject.Create(['mode', 'device', 'transport', S.Transport,
      'address', S.Address, 'name', S.Name]);
    Result.Add(DeviceRoleKeys[R], O);
  end;
end;
end.
