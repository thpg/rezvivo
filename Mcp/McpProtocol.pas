{ MCP protocol session: JSON-RPC 2.0 message handling, transport-agnostic.

  Tools exposed to every application:
    objects_list                  — list registered objects
    object_describe {object}      — published properties of an object
    property_get  {object, path}  — read a published property (dotted path)
    property_set  {object, path, value} — write a published property
  Plus one tool per command registered via McpRegistry.RegisterMcpCommand.

  All RTTI access and command handlers are executed in the main thread via
  McpBridge.McpRunTask. }
unit McpProtocol;

{$mode objfpc}{$H+}

interface

uses SysUtils, Classes, fpjson;

type
  TMcpSession = class
  private
    FServerName, FServerVersion: String;
    function HandleRpc(AReq: TJSONObject): TJSONObject;
    function BuildToolsList: TJSONObject;
    function CallTool(const AName: String; AArgs: TJSONObject): TJSONObject;
  public
    constructor Create(const AServerName, AServerVersion: String);
    { Handles one parsed JSON-RPC payload (single message object or a batch
      array). Returns the response to send back (caller frees), or nil when
      there is nothing to reply (notifications). Takes ownership of nothing:
      caller frees APayload. }
    function HandlePayload(APayload: TJSONData): TJSONData;
  end;

implementation

uses jsonparser, McpCommon, McpRegistry, McpRtti, McpBridge;

const
  JRPC_PARSE_ERROR      = -32700;
  JRPC_INVALID_REQUEST  = -32600;
  JRPC_METHOD_NOT_FOUND = -32601;
  JRPC_INVALID_PARAMS   = -32602;
  JRPC_INTERNAL_ERROR   = -32603;

constructor TMcpSession.Create(const AServerName, AServerVersion: String);
begin
  inherited Create;
  FServerName := AServerName;
  FServerVersion := AServerVersion;
end;

function MakeError(AId: TJSONData; ACode: Integer; const AMessage: String): TJSONObject;
var
  Err: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('jsonrpc', '2.0');
  if AId <> nil then
    Result.Add('id', AId.Clone)
  else
    Result.Add('id', TJSONNull.Create);
  Err := TJSONObject.Create;
  Err.Add('code', ACode);
  Err.Add('message', AMessage);
  Result.Add('error', Err);
end;

function MakeResult(AId: TJSONData; AResult: TJSONData): TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.Add('jsonrpc', '2.0');
  Result.Add('id', AId.Clone);
  Result.Add('result', AResult);
end;

{ ── tools/list ───────────────────────────────────────────────────────── }

procedure AddTool(ATools: TJSONArray; const AName, ADescription, ASchemaJson: String);
var
  T: TJSONObject;
  Schema: TJSONData;
begin
  T := TJSONObject.Create;
  T.Add('name', AName);
  T.Add('description', ADescription);
  if ASchemaJson <> '' then
  begin
    Schema := GetJSON(ASchemaJson);
    T.Add('inputSchema', Schema);
  end
  else
    T.Add('inputSchema', TJSONObject.Create(
      ['type', 'object', 'properties', TJSONObject.Create]));
  ATools.Add(T);
end;

function TMcpSession.BuildToolsList: TJSONObject;
var
  Tools: TJSONArray;
  Names: TStringList;
  I: Integer;
  Cmd: TMcpCommand;
begin
  Tools := TJSONArray.Create;
  AddTool(Tools, 'objects_list',
    'List all objects registered for MCP control (views, services, settings...). ' +
    'Use object_describe to inspect an object.',
    '{"type":"object","properties":{}}');
  AddTool(Tools, 'object_describe',
    'List published properties of a registered object: name, type, readable/writable flags.',
    '{"type":"object","properties":{"object":{"type":"string","description":"object name from objects_list"}},"required":["object"]}');
  AddTool(Tools, 'property_get',
    'Read a published property of a registered object. Path supports dot ' +
    'navigation through object properties, e.g. "mainviewport.camera.translation".',
    '{"type":"object","properties":{' +
    '"object":{"type":"string"},' +
    '"path":{"type":"string","description":"property path, dot-separated"}},' +
    '"required":["object","path"]}');
  AddTool(Tools, 'property_set',
    'Write a published property of a registered object. Value type must match ' +
    'the property type (number, string, boolean, enum name, set string).',
    '{"type":"object","properties":{' +
    '"object":{"type":"string"},' +
    '"path":{"type":"string"},' +
    '"value":{"description":"new value, JSON type must match the property"}},' +
    '"required":["object","path","value"]}');

  Names := TStringList.Create;
  try
    McpCommandNames(Names);
    for I := 0 to Names.Count - 1 do
    begin
      Cmd := FindMcpCommand(Names[I]);
      if Cmd <> nil then
        AddTool(Tools, Cmd.Name, Cmd.Description, Cmd.InputSchemaJson);
    end;
  finally
    Names.Free;
  end;

  Result := TJSONObject.Create;
  Result.Add('tools', Tools);
end;

{ ── tools/call ───────────────────────────────────────────────────────── }

function ToolOk(AData: TJSONData): TJSONObject;
var
  Content: TJSONArray;
  Item: TJSONObject;
  Text: String;
begin
  Result := TJSONObject.Create;
  Content := TJSONArray.Create;
  Result.Add('content', Content);
  { Image convention: a command result may carry "_image_base64" /
    "_image_mime" keys — they are emitted as an MCP image content item
    (LLM clients render it inline) and removed from the text payload. }
  if (AData <> nil) and (AData.JSONType = jtObject) and
     (TJSONObject(AData).Find('_image_base64') <> nil) then
  begin
    Item := TJSONObject.Create;
    Item.Add('type', 'image');
    Item.Add('data', TJSONObject(AData).Strings['_image_base64']);
    Item.Add('mimeType', TJSONObject(AData).Get('_image_mime', 'image/png'));
    Content.Add(Item);
    TJSONObject(AData).Delete('_image_base64');
    TJSONObject(AData).Delete('_image_mime');
    if TJSONObject(AData).Count = 0 then
    begin
      AData.Free;
      Exit;
    end;
  end;
  if AData = nil then
    Text := 'null'
  else
    Text := AData.AsJSON;
  AData.Free;
  Item := TJSONObject.Create;
  Item.Add('type', 'text');
  Item.Add('text', Text);
  Content.Add(Item);
end;

function ToolError(const AMessage: String): TJSONObject;
var
  Content: TJSONArray;
  Item: TJSONObject;
begin
  Item := TJSONObject.Create;
  Item.Add('type', 'text');
  Item.Add('text', AMessage);
  Content := TJSONArray.Create;
  Content.Add(Item);
  Result := TJSONObject.Create;
  Result.Add('content', Content);
  Result.Add('isError', True);
end;

{ Main-thread tasks (heap-owned — see McpBridge docs for why this matters:
  on a bridge timeout the queued task executes LATER, after CallTool has
  returned, so every input must be owned by the task, never borrowed from
  the request payload or the caller's stack). }

type
  TObjectsListTask = class(TMcpTask)
  public
    Items: TJSONArray;  { output; caller steals on success }
    procedure Execute; override;
  end;

  TDescribeTask = class(TMcpTask)
  public
    Obj: TObject;
    Items: TJSONArray;  { output; caller steals }
    procedure Execute; override;
  end;

  TGetTask = class(TMcpTask)
  public
    Obj: TObject;
    Path: String;
    Res: TJSONData;     { output; caller steals }
    procedure Execute; override;
  end;

  TSetTask = class(TMcpTask)
  public
    Obj: TObject;
    Path: String;
    Value: TJSONData;   { owned clone of the request value }
    constructor Create(AObj: TObject; const APath: String; AValue: TJSONData);
    destructor Destroy; override;
    procedure Execute; override;
  end;

  TCommandTask = class(TMcpTask)
  public
    Cmd: TMcpCommand;
    Params: TJSONObject;  { owned clone of the request arguments }
    ResObj: TJSONObject;  { output; caller steals on success }
    constructor Create(ACmd: TMcpCommand; AParams: TJSONObject);
    destructor Destroy; override;
    procedure Execute; override;
  end;

procedure TObjectsListTask.Execute;
var
  L: TStringList;
  I: Integer;
begin
  Items := TJSONArray.Create;
  L := TStringList.Create;
  try
    McpObjectNames(L);
    for I := 0 to L.Count - 1 do
      Items.Add(L[I]);
  finally
    L.Free;
  end;
end;

procedure TDescribeTask.Execute;
begin
  Items := TJSONArray.Create;
  McpDescribeObject(Obj, Items);
end;

procedure TGetTask.Execute;
begin
  Res := McpGetPropJson(Obj, Path);
end;

constructor TSetTask.Create(AObj: TObject; const APath: String; AValue: TJSONData);
begin
  inherited Create;
  Obj := AObj;
  Path := APath;
  Value := AValue.Clone;
end;

destructor TSetTask.Destroy;
begin
  Value.Free;
  inherited Destroy;
end;

procedure TSetTask.Execute;
begin
  McpSetPropJson(Obj, Path, Value);
end;

constructor TCommandTask.Create(ACmd: TMcpCommand; AParams: TJSONObject);
begin
  inherited Create;
  Cmd := ACmd;
  if AParams <> nil then
    Params := TJSONObject(AParams.Clone)
  else
    Params := TJSONObject.Create;
  ResObj := TJSONObject.Create;
end;

destructor TCommandTask.Destroy;
begin
  Params.Free;
  ResObj.Free;
  inherited Destroy;
end;

procedure TCommandTask.Execute;
begin
  Cmd.Handler(Params, ResObj);
end;

const
  MSG_TIMEOUT = 'Timeout: main thread did not respond (application busy or frozen)';

function TMcpSession.CallTool(const AName: String; AArgs: TJSONObject): TJSONObject;
var
  Obj: TObject;
  ObjName, Path: String;
  ResObj: TJSONObject;
  Cmd: TMcpCommand;
  OwnArgs: TJSONObject;
  LTask: TObjectsListTask;
  DTask: TDescribeTask;
  GTask: TGetTask;
  STask: TSetTask;
  CTask: TCommandTask;
begin
  OwnArgs := nil;
  if AArgs = nil then
  begin
    OwnArgs := TJSONObject.Create;
    AArgs := OwnArgs;
  end;
  try
    try
      { Uniform ownership pattern for every task:
        - McpRunTask raises  → task still owned → freed by the finally;
        - returns False      → ownership LOST (late execution, intentional
          leak) → nil the variable so the finally does not touch it;
        - returns True       → steal outputs, task freed by the finally. }
      if SameText(AName, 'objects_list') then
      begin
        LTask := TObjectsListTask.Create;
        try
          if not McpRunTask(LTask) then
          begin
            Result := ToolError(MSG_TIMEOUT);
            LTask := nil;
            Exit;
          end;
          ResObj := TJSONObject.Create;
          ResObj.Add('objects', LTask.Items);
          LTask.Items := nil;
          Result := ToolOk(ResObj);
        finally
          LTask.Free;
        end;
        Exit;
      end;

      if SameText(AName, 'object_describe') then
      begin
        ObjName := AArgs.Get('object', '');
        Obj := FindMcpObject(ObjName);
        if Obj = nil then
          Exit(ToolError('Unknown object "' + ObjName + '" — see objects_list'));
        DTask := TDescribeTask.Create;
        DTask.Obj := Obj;
        try
          if not McpRunTask(DTask) then
          begin
            Result := ToolError(MSG_TIMEOUT);
            DTask := nil;
            Exit;
          end;
          Result := ToolOk(DTask.Items);
          DTask.Items := nil;
        finally
          DTask.Free;
        end;
        Exit;
      end;

      if SameText(AName, 'property_get') then
      begin
        ObjName := AArgs.Get('object', '');
        Path := AArgs.Get('path', '');
        Obj := FindMcpObject(ObjName);
        if Obj = nil then
          Exit(ToolError('Unknown object "' + ObjName + '" — see objects_list'));
        GTask := TGetTask.Create;
        GTask.Obj := Obj;
        GTask.Path := Path;
        try
          if not McpRunTask(GTask) then
          begin
            Result := ToolError(MSG_TIMEOUT);
            GTask := nil;
            Exit;
          end;
          Result := ToolOk(GTask.Res);
          GTask.Res := nil;
        finally
          GTask.Free;
        end;
        Exit;
      end;

      if SameText(AName, 'property_set') then
      begin
        ObjName := AArgs.Get('object', '');
        Path := AArgs.Get('path', '');
        if AArgs.Find('value') = nil then
          Exit(ToolError('Missing "value" argument'));
        Obj := FindMcpObject(ObjName);
        if Obj = nil then
          Exit(ToolError('Unknown object "' + ObjName + '" — see objects_list'));
        STask := TSetTask.Create(Obj, Path, AArgs.Find('value'));
        try
          if not McpRunTask(STask) then
          begin
            Result := ToolError(MSG_TIMEOUT);
            STask := nil;
            Exit;
          end;
          Result := ToolOk(TJSONString.Create('ok'));
        finally
          STask.Free;
        end;
        Exit;
      end;

      { Application-registered command }
      Cmd := FindMcpCommand(AName);
      if Cmd <> nil then
      begin
        CTask := TCommandTask.Create(Cmd, AArgs);
        try
          { 60 s: команды уровня ride.load_fit (reset сессии) и
            ride.stop_full (teardown) синхронно гоняют разборку/сборку
            стриминга — десяток секунд при живых воркерах. }
          if not McpRunTask(CTask, 60000) then
          begin
            Result := ToolError(MSG_TIMEOUT);
            CTask := nil;
            Exit;
          end;
          Result := ToolOk(CTask.ResObj);
          CTask.ResObj := nil;
        finally
          CTask.Free;
        end;
        Exit;
      end;

      Result := ToolError('Unknown tool "' + AName + '"');
    except
      { Tool execution failures (EMcpError from RTTI/bridge, exceptions from
        command handlers) are reported as MCP tool errors, not JSON-RPC errors. }
      on E: Exception do
        Result := ToolError(E.Message);
    end;
  finally
    OwnArgs.Free;
  end;
end;

{ ── JSON-RPC dispatch ────────────────────────────────────────────────── }

function TMcpSession.HandleRpc(AReq: TJSONObject): TJSONObject;
var
  Id: TJSONData;
  Method, Params_name: String;
  Params, Args: TJSONData;
  Res: TJSONObject;
  IsNotification: Boolean;
begin
  Id := AReq.Find('id');
  IsNotification := Id = nil;
  Method := AReq.Get('method', '');
  if Method = '' then
  begin
    if IsNotification then
      Exit(nil);
    Exit(MakeError(Id, JRPC_INVALID_REQUEST, 'Missing "method"'));
  end;

  { Notifications never get a response. Per JSON-RPC 2.0 any message
    without "id" is a notification. }
  if IsNotification or (Pos('notifications/', Method) = 1) then
    Exit(nil);

  try
    if Method = 'initialize' then
    begin
      Res := TJSONObject.Create;
      Res.Add('protocolVersion', MCP_PROTOCOL_VERSION);
      Res.Add('capabilities', TJSONObject.Create(
        ['tools', TJSONObject.Create(['listChanged', False])]));
      Res.Add('serverInfo', TJSONObject.Create(
        ['name', FServerName, 'version', FServerVersion]));
      Exit(MakeResult(Id, Res));
    end;

    if Method = 'ping' then
      Exit(MakeResult(Id, TJSONObject.Create));

    if Method = 'tools/list' then
      Exit(MakeResult(Id, BuildToolsList));

    if Method = 'tools/call' then
    begin
      Params := AReq.Find('params');
      if (Params = nil) or (Params.JSONType <> jtObject) then
        Exit(MakeError(Id, JRPC_INVALID_PARAMS, 'tools/call requires object "params"'));
      Params_name := TJSONObject(Params).Get('name', '');
      if Params_name = '' then
        Exit(MakeError(Id, JRPC_INVALID_PARAMS, 'tools/call requires "params.name"'));
      Args := TJSONObject(Params).Find('arguments');
      if (Args <> nil) and (Args.JSONType <> jtObject) then
        Exit(MakeError(Id, JRPC_INVALID_PARAMS, '"params.arguments" must be an object'));
      Exit(MakeResult(Id, CallTool(Params_name, TJSONObject(Args))));
    end;

    Result := MakeError(Id, JRPC_METHOD_NOT_FOUND, 'Unknown method "' + Method + '"');
  except
    on E: Exception do
    begin
      if IsNotification then
        Result := nil
      else
        Result := MakeError(Id, JRPC_INTERNAL_ERROR, E.ClassName + ': ' + E.Message);
    end;
  end;
end;

function TMcpSession.HandlePayload(APayload: TJSONData): TJSONData;
var
  Arr: TJSONArray;
  I: Integer;
  One: TJSONData;
begin
  Result := nil;
  if APayload = nil then Exit;

  if APayload.JSONType = jtArray then
  begin
    Arr := TJSONArray.Create;
    for I := 0 to APayload.Count - 1 do
    begin
      if APayload.Items[I].JSONType = jtObject then
        One := HandleRpc(TJSONObject(APayload.Items[I]))
      else
        One := MakeError(nil, JRPC_INVALID_REQUEST, 'Batch item is not an object');
      if One <> nil then
        Arr.Add(One);
    end;
    if Arr.Count > 0 then
      Result := Arr
    else
      Arr.Free;
    Exit;
  end;

  if APayload.JSONType = jtObject then
    Exit(HandleRpc(TJSONObject(APayload)));

  Result := MakeError(nil, JRPC_INVALID_REQUEST, 'Payload must be an object or an array');
end;

end.
