unit McpLocalRelay;
{$mode objfpc}{$H+}
{ Raw stdio relay. Deliberately independent of the engine, registry and game
  units: an attach process must never create a window or touch a profile. }
interface
function RunMcpLocalRelay(const Endpoint:string):Integer;
implementation
uses Classes,SysUtils,McpLocalCommon{$ifdef MSWINDOWS},Windows{$endif};
{$ifdef MSWINDOWS}
function RelayCancelIoEx(Handle:THandle;Overlapped:POverlapped):BOOL;stdcall;external 'kernel32.dll' name 'CancelIoEx';
type
  TRelayPump=class(TThread)
  private FSource,FDestination,FPipe,FStopEvent:THandle;
  protected procedure Execute;override;
  public constructor Create(Source,Destination,Pipe,StopEvent:THandle);
  end;
constructor TRelayPump.Create(Source,Destination,Pipe,StopEvent:THandle);
begin
  inherited Create(True);FreeOnTerminate:=False;
  FSource:=Source;FDestination:=Destination;FPipe:=Pipe;FStopEvent:=StopEvent;Start;
end;
procedure TRelayPump.Execute;
var Buffer:array[0..65535]of Byte;Count,Sent,Offset:DWORD;
  IO:TOverlapped;IOEvent:THandle;Handles:array[0..1]of THandle;
  function Transfer(ReadOperation:Boolean;Handle:THandle;Data:Pointer;Size:DWORD;out Transferred:DWORD):Boolean;
  var P:POverlapped;Immediate:BOOL;
  begin
    if Terminated then Exit(False);
    P:=nil;
    if Handle=FPipe then begin
      FillChar(IO,SizeOf(IO),0);IO.hEvent:=IOEvent;ResetEvent(IOEvent);P:=@IO;
    end;
    if ReadOperation then Immediate:=ReadFile(Handle,PByte(Data)^,Size,Transferred,P)
    else Immediate:=WriteFile(Handle,PByte(Data)^,Size,Transferred,P);
    if P=nil then Exit(Immediate and (Transferred>0));
    if not Immediate then begin
      if GetLastError<>ERROR_IO_PENDING then Exit(False);
      if WaitForMultipleObjects(2,@Handles[0],False,INFINITE)<>WAIT_OBJECT_0+1 then begin
        RelayCancelIoEx(Handle,@IO);GetOverlappedResult(Handle,IO,Transferred,True);Exit(False);
      end;
    end;
    Result:=GetOverlappedResult(Handle,IO,Transferred,False) and (Transferred>0);
  end;
begin
  IOEvent:=CreateEvent(nil,True,False,nil);if IOEvent=0 then Exit;
  Handles[0]:=FStopEvent;Handles[1]:=IOEvent;
  try
  while not Terminated do begin
    if not Transfer(True,FSource,@Buffer[0],SizeOf(Buffer),Count) then Exit;
    Offset:=0;
    while (Offset<Count) and not Terminated do begin
      if not Transfer(False,FDestination,@Buffer[Offset],Count-Offset,Sent) then Exit;
      Inc(Offset,Sent);
    end;
  end;
  finally CloseHandle(IOEvent) end;
end;
procedure ReportFailure;
const Text:AnsiString='REZVIVO: local MCP connection unavailable.'#13#10;
var Written:DWORD;H:THandle;
begin
  H:=GetStdHandle(STD_ERROR_HANDLE);
  if (H<>0) and (H<>INVALID_HANDLE_VALUE) then WriteFile(H,Text[1],Length(Text),Written,nil);
end;
{$endif}
function RunMcpLocalRelay(const Endpoint:string):Integer;
{$ifdef MSWINDOWS}
var Pipe,InputHandle,OutputHandle,StopEvent:THandle;Path:UnicodeString;InputPump,OutputPump:TRelayPump;
{$endif}
begin
  Result:=64;
  if not ValidMcpLocalEndpoint(Endpoint) then begin {$ifdef MSWINDOWS}ReportFailure;{$endif}Exit end;
  {$ifdef MSWINDOWS}
  InputHandle:=GetStdHandle(STD_INPUT_HANDLE);OutputHandle:=GetStdHandle(STD_OUTPUT_HANDLE);
  if (InputHandle=0) or (InputHandle=INVALID_HANDLE_VALUE) or
    (OutputHandle=0) or (OutputHandle=INVALID_HANDLE_VALUE) then begin ReportFailure;Exit end;
  Path:='\\.\pipe\'+UTF8Decode(Endpoint);
  Pipe:=CreateFileW(PWideChar(Path),GENERIC_READ or GENERIC_WRITE,0,nil,OPEN_EXISTING,
    FILE_FLAG_OVERLAPPED or SECURITY_SQOS_PRESENT or SECURITY_IDENTIFICATION,0);
  if Pipe=INVALID_HANDLE_VALUE then begin ReportFailure;Exit(69) end;
  StopEvent:=CreateEvent(nil,True,False,nil);
  if StopEvent=0 then begin CloseHandle(Pipe);ReportFailure;Exit(69) end;
  InputPump:=nil;OutputPump:=nil;
  try
    InputPump:=TRelayPump.Create(InputHandle,Pipe,Pipe,StopEvent);
    OutputPump:=TRelayPump.Create(Pipe,OutputHandle,Pipe,StopEvent);
    while not InputPump.Finished and not OutputPump.Finished do Sleep(5);
    Result:=0;
  finally
    SetEvent(StopEvent);
    if InputPump<>nil then InputPump.Terminate;
    if OutputPump<>nil then OutputPump.Terminate;
    { Both ends may be blocked in synchronous OS I/O. Retry cancellation while
      joining to cover cancellation racing the start of the final read/write. }
    while ((InputPump<>nil) and not InputPump.Finished) or
      ((OutputPump<>nil) and not OutputPump.Finished) do begin
      if InputPump<>nil then McpCancelSynchronousIo(InputPump.Handle);
      if OutputPump<>nil then McpCancelSynchronousIo(OutputPump.Handle);
      Sleep(1);
    end;
    InputPump.Free;OutputPump.Free;CloseHandle(Pipe);CloseHandle(StopEvent);
  end;
  {$endif}
end;
end.
