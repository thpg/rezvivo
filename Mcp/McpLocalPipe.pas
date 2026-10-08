unit McpLocalPipe;
{$mode objfpc}{$H+}
{ Explicit local attach, one same-user client. The registry and protocol are
  identical to stdio. Only this worker owns blocking pipe I/O and its session. }
interface
uses Classes,SysUtils,SyncObjs,McpProtocol;
type
  TMcpLocalPipeStatus=record
    Enabled,ClientConnected:Boolean;
    Generation,Revision:QWord;
    Endpoint,Error:string;
  end;
  TMcpLocalPipeServer=class;
  TMcpLocalPipeThread=class(TThread)
  private FOwner:TMcpLocalPipeServer;
  protected procedure Execute;override;
  public constructor Create(Owner:TMcpLocalPipeServer);
  end;
  TMcpLocalPipeServer=class
  private
    FLock:TCriticalSection;
    FPipe:THandle;
    FWorker:TMcpLocalPipeThread;
    FSession:TMcpSession;
    FStatus:TMcpLocalPipeStatus;
    FName,FVersion:string;
    FBefore:TNotifyEvent;
    FStopping:Boolean;
    FStopEvent:THandle;
    procedure BeforeDispatch(Sender:TObject);
    function GetFinished:Boolean;
  public
    constructor Create(const Name,Version:string);
    destructor Destroy;override;
    function Start(out Error:string):Boolean;
    procedure RequestStop;
    function Status:TMcpLocalPipeStatus;
    function CheckClientConnected:Boolean;
    property Finished:Boolean read GetFinished;
    property OnBeforeDispatch:TNotifyEvent read FBefore write FBefore;
  end;
implementation
uses fpjson,jsonparser,McpLocalCommon,McpCommon{$ifdef MSWINDOWS},Windows{$endif};
{$I Utf8Json.inc}
{$ifdef MSWINDOWS}
function ConvertSidToStringSidW(Sid:Pointer;out Str:PWideChar):BOOL;stdcall;external 'advapi32.dll';
function ConvertStringSecurityDescriptorToSecurityDescriptorW(Str:PWideChar;Revision:DWORD;
  out SD:Pointer;Size:Pointer):BOOL;stdcall;external 'advapi32.dll';
function McpCancelIoEx(Handle:THandle;Overlapped:POverlapped):BOOL;stdcall;external 'kernel32.dll' name 'CancelIoEx';
function PrivateDescriptor:Pointer;
type PTokenUserData=^TTokenUserData;TTokenUserData=record Sid:Pointer;Attributes:DWORD end;
var Token:THandle;Size:DWORD;Data:TBytes;SidText:PWideChar;S:UnicodeString;
begin
  Result:=nil;Token:=0;SidText:=nil;
  if not OpenProcessToken(GetCurrentProcess,TOKEN_QUERY,Token) then Exit;
  try
    Size:=0;GetTokenInformation(Token,TokenUser,nil,0,Size);if Size=0 then Exit;
    SetLength(Data,Size);if not GetTokenInformation(Token,TokenUser,@Data[0],Size,Size) then Exit;
    if not ConvertSidToStringSidW(PTokenUserData(@Data[0])^.Sid,SidText) then Exit;
    S:='D:P(A;;GA;;;'+UnicodeString(SidText)+')';
    if not ConvertStringSecurityDescriptorToSecurityDescriptorW(PWideChar(S),1,Result,nil) then Result:=nil;
  finally
    if SidText<>nil then LocalFree(HLOCAL(SidText));CloseHandle(Token);
  end;
end;
{$endif}
constructor TMcpLocalPipeServer.Create(const Name,Version:string);
begin
  inherited Create;FLock:=SyncObjs.TCriticalSection.Create;
  {$ifdef MSWINDOWS}FStopEvent:=CreateEvent(nil,True,False,nil);{$endif}
  FName:=Name;FVersion:=Version;
end;
destructor TMcpLocalPipeServer.Destroy;
begin
  RequestStop;
  if FWorker<>nil then begin
    { Cancel invalidates queued commands first. Pump only to release their
      waiting worker; guarded callbacks cannot touch an application now. }
    while not FWorker.Finished do begin
      if GetCurrentThreadID=MainThreadID then CheckSynchronize(0);
      Sleep(1);
    end;
    FWorker.Free;
  end;
  {$ifdef MSWINDOWS}if FPipe<>0 then CloseHandle(FPipe);{$endif}
  {$ifdef MSWINDOWS}if FStopEvent<>0 then CloseHandle(FStopEvent);{$endif}
  FLock.Free;inherited;
end;
function TMcpLocalPipeServer.Start(out Error:string):Boolean;
{$ifdef MSWINDOWS}
var G:TGUID;S:string;I:Integer;SD:Pointer;SA:TSecurityAttributes;Path:UnicodeString;
{$endif}
begin
  Result:=False;Error:='';if FWorker<>nil then begin Error:='mcp_already_started';Exit end;
  {$ifdef MSWINDOWS}
  if FStopEvent=0 then begin Error:='mcp_pipe_failed';Exit end;
  if CreateGUID(G)<>0 then begin Error:='mcp_endpoint_failed';Exit end;
  S:=LowerCase(GUIDToString(G));
  for I:=Length(S) downto 1 do if S[I] in ['{','}','-'] then Delete(S,I,1);
  FStatus.Endpoint:='rezvivo-'+IntToStr(GetCurrentProcessId)+'-'+S;SD:=PrivateDescriptor;
  if SD=nil then begin Error:='mcp_security_failed';Exit end;
  try
    FillChar(SA,SizeOf(SA),0);SA.nLength:=SizeOf(SA);SA.lpSecurityDescriptor:=SD;
    Path:='\\.\pipe\'+UTF8Decode(FStatus.Endpoint);
    FPipe:=CreateNamedPipeW(PWideChar(Path),PIPE_ACCESS_DUPLEX or FILE_FLAG_OVERLAPPED or $00080000,
      PIPE_TYPE_BYTE or PIPE_READMODE_BYTE or PIPE_WAIT or $00000008,1,65536,65536,0,@SA);
    if FPipe=INVALID_HANDLE_VALUE then begin FPipe:=0;Error:='mcp_pipe_failed';Exit end;
  finally LocalFree(HLOCAL(SD)) end;
  FStatus.Enabled:=True;Inc(FStatus.Revision);FWorker:=TMcpLocalPipeThread.Create(Self);Result:=True;
  {$else}Error:='mcp_platform_unsupported';{$endif}
  if not Result then FStatus.Error:=Error;
end;
procedure TMcpLocalPipeServer.RequestStop;
begin
  FLock.Acquire;
  try
    if not FStopping then Inc(FStatus.Revision);
    FStopping:=True;FStatus.Enabled:=False;FStatus.ClientConnected:=False;
    if FSession<>nil then FSession.Cancel;
  finally FLock.Release end;
  {$ifdef MSWINDOWS}if FStopEvent<>0 then SetEvent(FStopEvent);{$endif}
  if FWorker<>nil then begin
    FWorker.Terminate;
  end;
end;
function TMcpLocalPipeServer.GetFinished:Boolean;
begin Result:=(FWorker=nil) or FWorker.Finished end;
function TMcpLocalPipeServer.Status:TMcpLocalPipeStatus;
begin FLock.Acquire;try Result:=FStatus finally FLock.Release end end;
function TMcpLocalPipeServer.CheckClientConnected:Boolean;
{$ifdef MSWINDOWS}var Available:DWORD;{$endif}
begin
  FLock.Acquire;
  try
    Result:=FStatus.Enabled and FStatus.ClientConnected and not FStopping;
    {$ifdef MSWINDOWS}
    if Result then Result:=PeekNamedPipe(FPipe,nil,0,nil,@Available,nil);
    {$endif}
    if not Result and (FSession<>nil) then FSession.Cancel;
  finally FLock.Release end;
end;
procedure TMcpLocalPipeServer.BeforeDispatch(Sender:TObject);
begin
  if not CheckClientConnected then raise EMcpError.Create('MCP session closed');
  if Assigned(FBefore) then FBefore(Self);
end;
constructor TMcpLocalPipeThread.Create(Owner:TMcpLocalPipeServer);
begin inherited Create(True);FOwner:=Owner;FreeOnTerminate:=False;Start end;
procedure TMcpLocalPipeThread.Execute;
{$ifdef MSWINDOWS}
var Session:TMcpSession;Payload,Response:TJSONData;Buffer:array[0..65535]of Byte;
  Count,Sent,Done:DWORD;I,First:Integer;Line,Part,Raw:RawByteString;Connected,Keep:Boolean;
  IO:TOverlapped;WaitHandles:array[0..1]of THandle;IOEvent:THandle;
  function CompleteIO(const Immediate:Boolean):Boolean;
  var Err,WaitResult,Transferred:DWORD;
  begin
    if Immediate then Exit(True);
    Err:=GetLastError;if Err<>ERROR_IO_PENDING then Exit(False);
    WaitResult:=WaitForMultipleObjects(2,@WaitHandles[0],False,INFINITE);
    if WaitResult<>WAIT_OBJECT_0+1 then begin
      McpCancelIoEx(FOwner.FPipe,@IO);
      { Wait before reusing the stack OVERLAPPED or data buffer. The stop event
        is level triggered, so cancellation cannot race the next blocking I/O. }
      GetOverlappedResult(FOwner.FPipe,IO,Transferred,True);Exit(False);
    end;
    Result:=GetOverlappedResult(FOwner.FPipe,IO,Transferred,False);
  end;
  procedure PrepareIO;
  begin FillChar(IO,SizeOf(IO),0);IO.hEvent:=IOEvent;ResetEvent(IOEvent) end;
  procedure WriteLine(const Text:string);
  begin
    Raw:=UTF8Encode(Text)+#10;Done:=0;
    while (Done<DWORD(Length(Raw))) and not Terminated do begin
      PrepareIO;
      if not CompleteIO(WriteFile(FOwner.FPipe,Raw[Done+1],Length(Raw)-Done,Sent,@IO)) then begin Keep:=False;Exit end;
      if not GetOverlappedResult(FOwner.FPipe,IO,Sent,False) or (Sent=0) then begin Keep:=False;Exit end;
      Inc(Done,Sent);
    end;
  end;
  procedure HandleLine;
  begin
    Payload:=nil;Response:=nil;
    try
      try Payload:=ParseUtf8Json(string(Line))
      except
        WriteLine('{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Invalid JSON"}}');Exit;
      end;
      Response:=Session.HandlePayload(Payload);
      if Response<>nil then WriteLine(Response.AsJSON);
    finally Payload.Free;Response.Free end;
  end;
{$endif}
begin
  {$ifdef MSWINDOWS}
  IOEvent:=CreateEvent(nil,True,False,nil);
  if IOEvent=0 then begin
    FOwner.FLock.Acquire;
    try FOwner.FStatus.Enabled:=False;FOwner.FStatus.Error:='mcp_pipe_failed';Inc(FOwner.FStatus.Revision)
    finally FOwner.FLock.Release end;
    Exit;
  end;
  WaitHandles[0]:=FOwner.FStopEvent;WaitHandles[1]:=IOEvent;
  try
  while not Terminated do begin
    PrepareIO;Connected:=ConnectNamedPipe(FOwner.FPipe,@IO);
    if not Connected then begin
      if GetLastError=ERROR_PIPE_CONNECTED then Connected:=True
      else Connected:=CompleteIO(False);
    end;
    if not Connected then Break;
    if Terminated then Break;
    Session:=TMcpSession.Create(FOwner.FName,FOwner.FVersion);Session.OnBeforeDispatch:=@FOwner.BeforeDispatch;
    FOwner.FLock.Acquire;
    try
      FOwner.FSession:=Session;FOwner.FStatus.ClientConnected:=True;
      Inc(FOwner.FStatus.Generation);Inc(FOwner.FStatus.Revision);
      if FOwner.FStopping then Session.Cancel;
    finally FOwner.FLock.Release end;
    try
      Line:='';Keep:=True;
      while not Terminated and Keep do begin
        PrepareIO;
        if not CompleteIO(ReadFile(FOwner.FPipe,Buffer,SizeOf(Buffer),Count,@IO)) then Break;
        if not GetOverlappedResult(FOwner.FPipe,IO,Count,False) or (Count=0) then Break;
        First:=0;
        for I:=0 to Integer(Count)-1 do if Buffer[I]=10 then begin
          SetString(Part,PAnsiChar(@Buffer[First]),I-First);Line:=Line+Part;First:=I+1;
          if Length(Line)>MCP_LOCAL_MAX_LINE then begin Keep:=False;Break end;
          if (Length(Line)>0) and (Line[Length(Line)]=#13) then Delete(Line,Length(Line),1);
          if Line<>'' then HandleLine;Line:='';if not Keep or Terminated then Break;
        end;
        if Keep and (First<Integer(Count)) then begin
          SetString(Part,PAnsiChar(@Buffer[First]),Integer(Count)-First);Line:=Line+Part;
          if Length(Line)>MCP_LOCAL_MAX_LINE then Keep:=False;
        end;
        if not Keep and (Length(Line)>MCP_LOCAL_MAX_LINE) then
          WriteLine('{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"Request too large"}}');
      end;
    except { Isolate a broken client from the game and the next connection. }
    end;
    FOwner.FLock.Acquire;
    try
      Session.Cancel;FOwner.FSession:=nil;FOwner.FStatus.ClientConnected:=False;Inc(FOwner.FStatus.Revision);
    finally FOwner.FLock.Release end;
    Session.Free;DisconnectNamedPipe(FOwner.FPipe);
  end;
  finally
  CloseHandle(IOEvent);
  DisconnectNamedPipe(FOwner.FPipe);
  FOwner.FLock.Acquire;
  try
    FOwner.FStatus.ClientConnected:=False;FOwner.FStatus.Enabled:=False;
    if not Terminated then FOwner.FStatus.Error:='mcp_pipe_failed';
    Inc(FOwner.FStatus.Revision);
  finally FOwner.FLock.Release end;
  end;
  {$endif}
end;
end.
