program DeviceAssignmentsTests;
{$mode objfpc}{$H+}
uses SysUtils, Classes, fpjson, jsonparser, GameDeviceAssignments;
var Checks: Integer;

procedure Check(OK: Boolean; const Description: String);
begin
  Inc(Checks);
  if not OK then raise Exception.Create(Description);
end;

procedure Restart(const Source, Target: TDeviceRoleAssignments);
var O: TJSONObject; D: TJSONData;
begin
  O := Source.ToJSON;
  try
    D := GetJSON(O.AsJSON);
    try Target.LoadJSON(D); finally D.Free; end;
  finally O.Free; end;
end;

procedure Run;
var Local, Account, Reloaded: TDeviceRoleAssignments;
  R: TDeviceRole; O: TJSONObject; D: TJSONData;
begin
  Local := TDeviceRoleAssignments.Create;
  Account := TDeviceRoleAssignments.Create;
  Reloaded := TDeviceRoleAssignments.Create;
  try
    for R := Low(TDeviceRole) to High(TDeviceRole) do
      Check(Local.Allows(R, 'BLE', 'AA:01'), 'New profile permits initial pairing');
    Local.Select(drPower, 'BLE', 'AA:01', 'Power meter');
    Local.Select(drCadence, 'BLE', 'AA:01', 'Power meter');
    Local.Select(drHeartRate, 'BLE', 'AA:02', 'Heart rate');
    Local.Select(drControllable, 'BLE', 'AA:03', 'Trainer');
    Local.Disable(drSpeed);
    Restart(Local, Reloaded);
    Check(Reloaded.Matches(drPower, 'ble', 'aa:01'), 'Power restored');
    Check(Reloaded.Matches(drCadence, 'BLE', 'AA:01'), 'Cadence restored');
    Check(Reloaded.Matches(drHeartRate, 'BLE', 'AA:02'), 'HR restored');
    Check(Reloaded.Matches(drControllable, 'BLE', 'AA:03'), 'Controller restored separately');
    Check(not Reloaded.Allows(drControllable, 'BLE', 'AA:01'), 'Power meter cannot steal control');
    Check(not Reloaded.Allows(drPower, 'BLE', 'AA:03'), 'Trainer cannot steal external power role');
    Check(not Reloaded.Allows(drSpeed, 'BLE', 'AA:03'), 'Explicit None survives reconnect/restart');
    Check(not Reloaded.Allows(drControllable, 'BLE', 'AA:04'), 'Same-name neighbour never matches');
    Check(not Reloaded.Matches(drPower, 'ANT+', 'AA:01'), 'Transport is part of identity');
    Check(Reloaded.Matches(drPower, 'BLE', ' AA:01 '), 'Identifier normalization');
    Check(not Reloaded.Select(drPower, 'ble', 'aa:01', 'Power meter'), 'Unchanged choice avoids disk write');
    Check(Reloaded.Select(drPower, 'BLE', 'AA:01', 'Renamed meter'), 'Display name can change');
    Check(Reloaded.Matches(drPower, 'BLE', 'AA:01'), 'Name change does not lose pairing');
    Check(Reloaded.Disable(drHeartRate), 'Explicit clear changes intent');
    Check(not Reloaded.Disable(drHeartRate), 'Repeated clear avoids disk write');
    Restart(Reloaded, Account);
    Check(not Account.Allows(drHeartRate, 'BLE', 'AA:02'), 'None is not uninitialized');
    Check(Account.UsesDevice('ble', 'AA:03'), 'Saved controller reconnects');
    Check(not Account.UsesDevice('BLE', 'AA:04'), 'Neighbour not saved for reconnect');

    Account.Reset;
    Account.Select(drControllable, 'ANT+', 'ANT:42', 'Other profile trainer');
    Restart(Account, Reloaded);
    Check(Reloaded.Matches(drControllable, 'ANT+', 'ANT:42'), 'Account changes controller independently');
    Restart(Local, Reloaded);
    Check(Reloaded.Matches(drControllable, 'BLE', 'AA:03'), 'Local profile retained after account switch');
    Check(Reloaded.Matches(drHeartRate, 'BLE', 'AA:02'), 'Local HR was not overwritten by account None');

    { A corrupt or newer file must never authorize automatic trainer takeover. }
    D := GetJSON('{"version":99,"controllable":{"mode":"device","transport":"BLE","address":"AA:03"}}');
    try Reloaded.LoadJSON(D); finally D.Free; end;
    for R := Low(TDeviceRole) to High(TDeviceRole) do
      Check(not Reloaded.Allows(R, 'BLE', 'AA:04'), 'Unknown schema fails closed');
    D := GetJSON('{"version":1,"controllable":{"mode":"device","transport":"BLE","address":7},"power":{"mode":"none"}}');
    try Reloaded.LoadJSON(D); finally D.Free; end;
    Check(not Reloaded.Allows(drControllable, 'BLE', '7'), 'Malformed device address rejected');
    Check(not Reloaded.Allows(drPower, 'BLE', 'AA:01'), 'Explicit None parsed');
    Check(Reloaded.Allows(drHeartRate, 'BLE', 'AA:02'), 'Missing role remains available for first pairing');
    O := TJSONObject.Create(['version', '1']);
    try Reloaded.LoadJSON(O); finally O.Free; end;
    Check(not Reloaded.Allows(drControllable, 'BLE', 'AA:04'), 'Wrong schema type fails closed');
    Reloaded.LoadJSON(nil);
    Check(not Reloaded.HasRemembered, 'Missing file is a clean profile');
    Check(Reloaded.Select(drControllable, '', 'AA:03', 'Trainer'), 'Empty transport clears invalid choice');
    Check(not Reloaded.Allows(drControllable, 'BLE', 'AA:04'), 'Invalid choice cannot enable auto');
  finally
    Reloaded.Free;
    Account.Free;
    Local.Free;
  end;
end;
begin
  Run;
  WriteLn('PASS DeviceAssignmentsTests: ', Checks, ' checks');
end.
