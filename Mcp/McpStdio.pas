{ MCP stdio transport: newline-delimited JSON-RPC over stdin/stdout.

  The MCP host (Claude Desktop etc.) launches this application as a child
  process with piped std handles. A reader thread reads one JSON-RPC message
  per line from stdin; responses are written directly to the stdout OS handle
  (bypassing the Pascal Output textfile, which we redirect to NUL — any
  stray WriteLn from the engine would otherwise corrupt the protocol).

  Reading is done in raw bytes from the OS handle and treated as UTF-8,
  so no console codepage translation corrupts non-ASCII JSON.

  When stdin reaches EOF (host closed the pipe), OnEndOfStream fires in the
  main thread — the application should terminate itself there. }
unit McpStdio;

{$mode objfpc}{$H+}

interface

uses SysUtils, Classes, SyncObjs, McpProtocol;

type
  TMcpStdioServer = class
  private
    FSession: TMcpSession;
    FReaderThread: TThread;
    FWriteLock: TCriticalSection;
    FOnEndOfStream: TNotifyEvent;
    FInHandle, FOutHandle: THandle;
    { Read buffer: FileRead grabs whole pipe chunks, so leftover bytes past
      the first LF must survive between ReadLineRaw calls. }
    FBuf: array[0..65535] of Byte;
    FBufLen, FBufPos: Integer;
    procedure WriteResponse(const AJsonLine: String);
    { Reads one LF-terminated line as raw UTF-8 bytes (CR stripped).
      Returns False on EOF / read error. }
    function ReadLineRaw(out ALine: String): Boolean;
  public
    constructor Create(const AServerName, AServerVersion: String);
    destructor Destroy; override;
    { Starts the reader thread. Returns False when std handles are not
      available (app not launched by an MCP host with pipes). }
    function Start: Boolean;
    procedure Stop;
    property Session: TMcpSession read FSession;
    property OnEndOfStream: TNotifyEvent read FOnEndOfStream write FOnEndOfStream;
  end;

{ Redirect the Pascal standard Output textfile to the null device, so any
  stray WriteLn (engine logs, debug output) cannot corrupt the MCP stream.
  Call before Start, as early as possible in application startup.
  MCP responses are written straight to the OS handle and are unaffected. }
procedure McpSilenceStdOut;

implementation

uses jsonparser, fpjson
{$IFDEF WINDOWS}, Windows{$ENDIF};

{ ── raw std-handle IO ────────────────────────────────────────────────── }

function GetStdInHandle: THandle;
begin
  {$IFDEF WINDOWS}
  Result := GetStdHandle(STD_INPUT_HANDLE);
  {$ELSE}
  Result := 0;  { stdin }
  {$ENDIF}
end;

function GetStdOutHandle: THandle;
begin
  {$IFDEF WINDOWS}
  Result := GetStdHandle(STD_OUTPUT_HANDLE);
  {$ELSE}
  Result := 1;  { stdout }
  {$ENDIF}
end;

function HandleValid(AHandle: THandle): Boolean;
begin
  {$IFDEF WINDOWS}
  Result := (AHandle <> 0) and (AHandle <> THandle(INVALID_HANDLE_VALUE));
  {$ELSE}
  Result := AHandle >= 0;
  {$ENDIF}
end;

procedure McpSilenceStdOut;
begin
  {$IFDEF WINDOWS}
  AssignFile(Output, 'NUL');
  {$ELSE}
  AssignFile(Output, '/dev/null');
  {$ENDIF}
  Rewrite(Output);
end;

{ ── reader thread ────────────────────────────────────────────────────── }

type
  TMcpReaderThread = class(TThread)
  private
    FServer: TMcpStdioServer;
    procedure DoEndOfStream;
  protected
    procedure Execute; override;
  public
    constructor Create(AServer: TMcpStdioServer);
  end;

constructor TMcpReaderThread.Create(AServer: TMcpStdioServer);
begin
  inherited Create(True);  { created suspended, started in TMcpStdioServer.Start }
  FreeOnTerminate := False;
  FServer := AServer;
end;

procedure TMcpReaderThread.DoEndOfStream;
begin
  if Assigned(FServer.FOnEndOfStream) then
    FServer.FOnEndOfStream(FServer);
end;

{ Reads one line (up to LF) as raw bytes from the stdin handle.
  Returns False on EOF / read error. CR before LF is stripped.
  Leftover bytes in FServer's buffer are consumed first. }
function TMcpStdioServer.ReadLineRaw(out ALine: String): Boolean;
var
  S: UTF8String;
begin
  S := '';
  while True do
  begin
    if FBufPos >= FBufLen then
    begin
      FBufLen := FileRead(FInHandle, FBuf, SizeOf(FBuf));
      FBufPos := 0;
      if FBufLen <= 0 then
      begin
        { EOF or error: deliver accumulated partial line if any }
        if S <> '' then
        begin
          ALine := String(S);
          Exit(True);
        end;
        Exit(False);
      end;
    end;
    if FBuf[FBufPos] = 10 then  { LF }
    begin
      Inc(FBufPos);
      ALine := String(S);
      Exit(True);
    end;
    if FBuf[FBufPos] <> 13 then  { skip CR }
      S := S + Chr(FBuf[FBufPos]);
    Inc(FBufPos);
  end;
end;

procedure TMcpReaderThread.Execute;
var
  Line: String;
  Payload, Resp: TJSONData;
begin
  while not Terminated do
  begin
    if not FServer.ReadLineRaw(Line) then
      Break;  { EOF: host closed the pipe }
    Line := Trim(Line);
    if Line = '' then Continue;
    try
      Payload := GetJSON(Line);
    except
      on E: Exception do
      begin
        FServer.WriteResponse(
          '{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":' +
          '"Parse error: ' + StringReplace(E.Message, '"', '''', [rfReplaceAll]) +
          '"}}');
        Continue;
      end;
    end;
    try
      Resp := FServer.FSession.HandlePayload(Payload);
    finally
      Payload.Free;
    end;
    if Resp <> nil then
    try
      FServer.WriteResponse(Resp.AsJSON);
    finally
      Resp.Free;
    end;
  end;
  { EOF — notify in the main thread }
  if not Terminated then
    TThread.Queue(nil, @DoEndOfStream);
end;

{ ── TMcpStdioServer ──────────────────────────────────────────────────── }

constructor TMcpStdioServer.Create(const AServerName, AServerVersion: String);
begin
  inherited Create;
  FSession := TMcpSession.Create(AServerName, AServerVersion);
  { Windows unit defines its own TCriticalSection (record) that shadows
    SyncObjs — qualify explicitly. }
  FWriteLock := SyncObjs.TCriticalSection.Create;
end;

destructor TMcpStdioServer.Destroy;
begin
  Stop;
  FWriteLock.Free;
  FSession.Free;
  inherited Destroy;
end;

function TMcpStdioServer.Start: Boolean;
begin
  FInHandle := GetStdInHandle;
  FOutHandle := GetStdOutHandle;
  Result := HandleValid(FInHandle) and HandleValid(FOutHandle);
  if not Result then Exit;
  FReaderThread := TMcpReaderThread.Create(Self);
  FReaderThread.Start;
end;

procedure TMcpStdioServer.Stop;
begin
  if FReaderThread <> nil then
  begin
    FReaderThread.Terminate;
    { The reader is likely blocked in FileRead on the pipe; it will not
      wake up until the host sends something or closes the pipe. We do not
      wait for it — process shutdown kills the thread anyway. Only free it
      when it already finished (EOF path). }
    if FReaderThread.Finished then
      FReaderThread.Free;
    FReaderThread := nil;
  end;
end;

procedure TMcpStdioServer.WriteResponse(const AJsonLine: String);
var
  S: UTF8String;
  Total, Written: Integer;
begin
  S := UTF8Encode(AJsonLine) + #10;
  FWriteLock.Acquire;
  try
    Total := 0;
    while Total < Length(S) do
    begin
      Written := FileWrite(FOutHandle, S[Total + 1], Length(S) - Total);
      if Written <= 0 then Break;  { pipe broken — nothing we can do }
      Inc(Total, Written);
    end;
  finally
    FWriteLock.Release;
  end;
end;

end.
