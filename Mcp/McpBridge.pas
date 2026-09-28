{ Main-thread bridge for MCP.

  MCP transports (stdio reader / HTTP workers) live in background threads,
  but Castle Game Engine and LCL objects may only be touched from the main
  thread. McpRunTask queues a heap-owned task for the main thread and waits
  for it with a timeout.

  WHY heap-owned tasks and not closures: if the main thread is frozen (this
  app blocks it for minutes during world generation), the wait times out and
  the caller's stack frame is destroyed — but the queued work item stays in
  TThread.Queue and runs LATER. A closure capturing caller locals would then
  write into a dead stack frame (heap corruption, runaway memory, freezes).
  A TMcpTask owns ALL its inputs and outputs on the heap, so a late
  execution is harmless: on timeout the task is simply leaked (bounded,
  only during main-loop freezes), never corrupt.

  NOTE: the queue is pumped by CheckSynchronize. CGE applications must pump
  it manually (e.g. from ApplicationProperties.OnUpdate) — the projects in
  this repo already do that (see GameDeviceService / GameMcpServer). }
unit McpBridge;

{$mode objfpc}{$H+}

interface

uses SysUtils, Classes, SyncObjs;

type
  { Work item executed in the main thread. Subclass, store all inputs in
    fields (CLONE anything borrowed — request JSON owned by the transport
    thread may be freed before a late execution!), fill result fields in
    Execute. Raise exceptions to report failure — the message is re-raised
    in the calling thread as EMcpError. }
  TMcpTask = class
  private
    FDone: TEvent;
    FError: String;
    procedure QueuedRun;  { internal — queued via TThread.Queue }
  public
    constructor Create;
    destructor Destroy; override;
    procedure Execute; virtual; abstract;
  end;

{ Queue ATask for execution in the main thread and wait (ATimeoutMs).

  Returns True: task executed. Caller still OWNS ATask — read results from
  its fields, then free it. Exceptions from Execute are re-raised (EMcpError)
  before returning — the caller still owns the task and must free it.

  Returns False: timeout (main loop frozen). OWNERSHIP IS LOST — the task
  may still execute later; it is intentionally leaked afterwards. Do NOT
  touch ATask after a False return.

  If already on the main thread, executes directly (same ownership rules
  as success). }
function McpRunTask(ATask: TMcpTask; ATimeoutMs: Integer = 5000): Boolean;

implementation

uses McpCommon;

function TaskExceptionMessage(E:Exception):string;
var I:Integer;
begin
  Result:=E.ClassName+': '+E.Message;
  if GetEnvironmentVariable('REZVIVO_TEST_TRACE_EXCEPTIONS')='1' then begin
    Result:=Result+' at '+BackTraceStrFunc(ExceptAddr);
    for I:=0 to ExceptFrameCount-1 do
      Result:=Result+#10+BackTraceStrFunc(ExceptFrames[I]);
  end;
end;

constructor TMcpTask.Create;
begin
  inherited Create;
  FDone := TEvent.Create(nil, True, False, '');
end;

destructor TMcpTask.Destroy;
begin
  FDone.Free;
  inherited Destroy;
end;

procedure TMcpTask.QueuedRun;
begin
  try
    Execute;
  except
    on E: Exception do
    begin
      FError := TaskExceptionMessage(E);
    end;
  end;
  FDone.SetEvent;
end;

function McpRunTask(ATask: TMcpTask; ATimeoutMs: Integer): Boolean;
var
  Err: String;
begin
  if GetCurrentThreadId = MainThreadID then
  begin
    try
      ATask.Execute;
    except
      on E: Exception do
        raise EMcpError.Create(TaskExceptionMessage(E));
    end;
    Exit(True);
  end;
  TThread.Queue(nil, @ATask.QueuedRun);
  Result := ATask.FDone.WaitFor(DWORD(ATimeoutMs)) = wrSignaled;
  if not Result then
    Exit;  { ownership lost — intentional leak, see interface docs }
  Err := ATask.FError;
  if Err <> '' then
    raise EMcpError.Create(Err);
end;

end.
