{ MCP registry: named objects exposed over RTTI + named commands.

  Applications register their singletons (views, services, settings...) and
  command callbacks at startup. Registry is thread-safe: transports read it
  from background threads while the main thread registers at startup. }
unit McpRegistry;

{$mode objfpc}{$H+}

interface

uses SysUtils, Classes, SyncObjs, fpjson, McpCommon;

type
  { Command callback. AParams — 'arguments' object from tools/call (never
    nil, may be empty). Fill AResult with result data (already created,
    empty). Raise EMcpError (or any Exception) on failure — it becomes a
    tool error result.
    Always executed in the MAIN thread (wrapped by McpBridge). }
  TMcpCommandHandler = procedure(const AParams: TJSONObject; AResult: TJSONObject);

  TMcpCommand = class
    Name: String;
    Description: String;
    { JSON text of the inputSchema for tools/list. '' means
      {"type":"object","properties":{}}. }
    InputSchemaJson: String;
    Handler: TMcpCommandHandler;
  end;

procedure RegisterMcpObject(const AName: String; AObject: TObject);
procedure UnregisterMcpObject(const AName: String);
function FindMcpObject(const AName: String): TObject;
procedure McpObjectNames(AList: TStrings);

procedure RegisterMcpCommand(const AName, ADescription, AInputSchemaJson: String;
  AHandler: TMcpCommandHandler);
function FindMcpCommand(const AName: String): TMcpCommand;
procedure McpCommandNames(AList: TStrings);

implementation

var
  GLock: TCriticalSection;
  GObjects: TStringList;   { name (lowercase) -> TObject }
  GCommands: TStringList;  { name (lowercase) -> TMcpCommand }

procedure RegisterMcpObject(const AName: String; AObject: TObject);
var
  Key: String;
  Idx: Integer;
begin
  if AObject = nil then
    raise EMcpRegistryError.Create('RegisterMcpObject: object is nil for "' + AName + '"');
  Key := LowerCase(AName);
  GLock.Acquire;
  try
    if GObjects.Find(Key, Idx) then
      GObjects.Objects[Idx] := AObject
    else
      GObjects.AddObject(Key, AObject);
  finally
    GLock.Release;
  end;
end;

procedure UnregisterMcpObject(const AName: String);
var
  Idx: Integer;
begin
  GLock.Acquire;
  try
    if GObjects.Find(LowerCase(AName), Idx) then
      GObjects.Delete(Idx);
  finally
    GLock.Release;
  end;
end;

function FindMcpObject(const AName: String): TObject;
var
  Idx: Integer;
begin
  GLock.Acquire;
  try
    if GObjects.Find(LowerCase(AName), Idx) then
      Result := TObject(GObjects.Objects[Idx])
    else
      Result := nil;
  finally
    GLock.Release;
  end;
end;

procedure McpObjectNames(AList: TStrings);
var
  I: Integer;
begin
  GLock.Acquire;
  try
    for I := 0 to GObjects.Count - 1 do
      AList.Add(GObjects[I]);
  finally
    GLock.Release;
  end;
end;

procedure RegisterMcpCommand(const AName, ADescription, AInputSchemaJson: String;
  AHandler: TMcpCommandHandler);
var
  Cmd: TMcpCommand;
  Key: String;
  Idx: Integer;
begin
  if not Assigned(AHandler) then
    raise EMcpRegistryError.Create('RegisterMcpCommand: handler is nil for "' + AName + '"');
  Cmd := TMcpCommand.Create;
  Cmd.Name := AName;
  Cmd.Description := ADescription;
  Cmd.InputSchemaJson := AInputSchemaJson;
  Cmd.Handler := AHandler;
  Key := LowerCase(AName);
  GLock.Acquire;
  try
    if GCommands.Find(Key, Idx) then
    begin
      GCommands.Objects[Idx].Free;
      GCommands.Objects[Idx] := Cmd;
    end
    else
      GCommands.AddObject(Key, Cmd);
  finally
    GLock.Release;
  end;
end;

function FindMcpCommand(const AName: String): TMcpCommand;
var
  Idx: Integer;
begin
  GLock.Acquire;
  try
    if GCommands.Find(LowerCase(AName), Idx) then
      Result := TMcpCommand(GCommands.Objects[Idx])
    else
      Result := nil;
  finally
    GLock.Release;
  end;
end;

procedure McpCommandNames(AList: TStrings);
var
  I: Integer;
begin
  GLock.Acquire;
  try
    for I := 0 to GCommands.Count - 1 do
      AList.Add(GCommands[I]);
  finally
    GLock.Release;
  end;
end;

procedure FreeRegistry;
var
  I: Integer;
begin
  for I := 0 to GCommands.Count - 1 do
    GCommands.Objects[I].Free;
  GCommands.Free;
  GObjects.Free;
  GLock.Free;
end;

initialization
  GLock := TCriticalSection.Create;
  GObjects := TStringList.Create;
  GObjects.Sorted := True;
  GObjects.CaseSensitive := False;
  GCommands := TStringList.Create;
  GCommands.Sorted := True;
  GCommands.CaseSensitive := False;

finalization
  FreeRegistry;

end.
