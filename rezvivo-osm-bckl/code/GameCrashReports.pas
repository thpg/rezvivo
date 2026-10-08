unit GameCrashReports;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses Classes, SysUtils;
procedure StartCrashReports;
procedure RefreshCrashDiagnostics;
procedure EnableCrashUpload(const ApiBase:String);
procedure CaptureCrash(E:Exception);
procedure MarkClientCleanExit;
function ClientDiagnosticsDir:String;
function RedactClientLog(const Text:String):String;

implementation
uses SyncObjs,fpjson,jsonparser,CustApp,CastleWindow,DebugLog,GameBuildInfo,
  GameHttpClient,GameMachineInfo{$ifdef MSWINDOWS},Windows{$endif};

type
  TCrashUpload=class(TThread)
  private
    FBase:String;
    FWake:TEvent;
    function Upload(const FileName:String):Boolean;
  protected
    procedure Execute;override;
  public
    constructor Create(const Base:String);
    destructor Destroy;override;
    procedure Wake;
  end;
  TCrashHook=class
    Previous:TExceptionEvent;
    procedure Handle(Sender:TObject;E:Exception);
  end;
var Worker:TCrashUpload;Hook:TCrashHook;Marker,SessionId:String;
  CleanExit:Boolean=False;Capturing:Boolean=False;Reported:Boolean=False;

function ClientDiagnosticsDir:String;
var Root:String;
begin
  Root:=SysUtils.GetEnvironmentVariable('REZVIVO_TEST_SESSION_DIR');
  if (SysUtils.GetEnvironmentVariable('REZVIVO_TEST_AUTH_FILE')='')or(Root='')then begin
    Root:=SysUtils.GetEnvironmentVariable('LOCALAPPDATA');
    if Root='' then Root:=GetAppConfigDir(False);
    Root:=IncludeTrailingPathDelimiter(Root)+'REZVIVO';
  end;
  Result:=IncludeTrailingPathDelimiter(Root)+'diagnostics'+PathDelim;
end;

function NewId:String;
var Id:TGUID;
begin CreateGUID(Id);Result:=LowerCase(Copy(GUIDToString(Id),2,36));end;

function RedactClientLog(const Text:String):String;
const Keys:array[0..13]of String=('authorization','password','access_token','refresh_token',
  'api_key','api-key','apikey','client_secret','secret=','cookie:','bearer ','?token=','&token=','set-cookie');
var Lines:TStringList;I,K:Integer;Lower:String;
begin
  Lines:=TStringList.Create;
  try
    Lines.Text:=Text;
    for I:=0 to Lines.Count-1 do begin
      Lower:=LowerCase(Lines[I]);
      for K:=Low(Keys)to High(Keys)do if Pos(Keys[K],Lower)>0 then begin
        Lines[I]:='[credential line removed]';Break;
      end;
    end;
    Result:=Lines.Text;
  finally Lines.Free;end;
end;

function ReadText(const FileName:String;MaxBytes:Integer;FromStart:Boolean=False):String;
var F:TFileStream;N:Int64;
begin
  Result:='';F:=TFileStream.Create(FileName,fmOpenRead or fmShareDenyNone);
  try
    N:=F.Size;if N>MaxBytes then begin
      if not FromStart then F.Position:=N-MaxBytes;
      N:=MaxBytes;
    end;
    SetLength(Result,N);if N>0 then F.ReadBuffer(Result[1],N);
  finally F.Free;end;
end;

procedure SaveJson(const FileName:String;Obj:TJSONObject);
{$ifdef MSWINDOWS}
const MoveFileWriteThrough=$00000008; { MOVEFILE_WRITE_THROUGH, absent in FPC 3.2.2 headers }
{$endif}
var S:String;F:TFileStream;Saved:Boolean;
begin
  S:=Obj.AsJSON;F:=TFileStream.Create(FileName+'.tmp',fmCreate);
  try if S<>''then F.WriteBuffer(S[1],Length(S));finally F.Free;end;
  {$ifdef MSWINDOWS}
  { The marker is refreshed after GL initialization. Windows RenameFile cannot
    replace an existing destination; leave the previous complete marker intact
    until the new snapshot has been written and closed. }
  Saved:=MoveFileExW(PWideChar(UTF8Decode(FileName+'.tmp')),
    PWideChar(UTF8Decode(FileName)),MOVEFILE_REPLACE_EXISTING or MoveFileWriteThrough);
  {$else}
  Saved:=RenameFile(FileName+'.tmp',FileName);
  {$endif}
  if not Saved then begin
    SysUtils.DeleteFile(FileName+'.tmp');raise Exception.Create('Cannot save diagnostic report');
  end;
end;

procedure QueueReport(const Id,LogFile,Version,Message,Machine:String;Build:Integer);
const TailLimit=768*1024;MachineLimit=64*1024;MessageLimit=32*1024;
var J:TJSONObject;Text,Target,Oldest,Info,LogTail:String;SR:TSearchRec;Count:Integer;OldTime:LongInt;
begin
  Target:=ClientDiagnosticsDir+Id+'.report.json';if FileExists(Target)then Exit;
  Count:=0;Oldest:='';OldTime:=High(LongInt);
  if FindFirst(ClientDiagnosticsDir+'*.report.json',faAnyFile,SR)=0 then
    try repeat
      Inc(Count);if SR.Time<OldTime then begin OldTime:=SR.Time;Oldest:=SR.Name;end;
    until FindNext(SR)<>0;finally SysUtils.FindClose(SR);end;
  if(Count>=20)and(Oldest<>'')then SysUtils.DeleteFile(ClientDiagnosticsDir+Oldest);
  LogTail:='';Info:=Copy(Machine,1,MachineLimit);
  try
    if FileExists(LogFile)then begin
      LogTail:=ReadText(LogFile,TailLimit);
      { Old clients did not persist a snapshot. If their log was truncated,
        preserve its startup section too; never substitute this launch's GPU. }
      if(Info='')and(Length(LogTail)>=TailLimit)then
        Info:='[Legacy session: original startup log]'+#10+ReadText(LogFile,MachineLimit,True);
    end;
  except { A missing or unreadable log must not discard the hardware snapshot. }
  end;
  if Info=''then Info:='[Machine snapshot unavailable in this session]';
  Info:=Copy(RedactClientLog(Info),1,MachineLimit);
  LogTail:=RedactClientLog(LogTail);
  if Length(LogTail)>TailLimit then
    Delete(LogTail,1,Length(LogTail)-TailLimit);
  Text:=Copy(RedactClientLog(Message),1,MessageLimit)+#10+
    '========== machine diagnostics =========='+#10+Info+#10+
    '========== session log (tail, up to 768 KiB) =========='+#10+LogTail;
  J:=TJSONObject.Create(['report_id',Id,'build',Build,'version',Version,
    'message',Copy(RedactClientLog(Message),1,1800),'log',Text]);
  try SaveJson(Target,J);finally J.Free;end;
  if Worker<>nil then Worker.Wake;
end;

function ProcessRunning(Pid:Integer):Boolean;
{$ifdef MSWINDOWS}
var H:THandle;Code:DWORD;
{$endif}
begin
  Result:=False;if Pid<=0 then Exit;
  {$ifdef MSWINDOWS}
  H:=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,False,Pid);
  if H<>0 then try Result:=GetExitCodeProcess(H,Code)and(Code=STILL_ACTIVE);finally CloseHandle(H);end
  else Result:=GetLastError=ERROR_ACCESS_DENIED;
  {$endif}
end;

procedure RecoverReports;
var SR:TSearchRec;J:TJSONData;O:TJSONObject;Path:String;
begin
  if FindFirst(ClientDiagnosticsDir+'*.running.json',faAnyFile,SR)<>0 then Exit;
  try repeat
    Path:=ClientDiagnosticsDir+SR.Name;J:=nil;
    try
      J:=GetJSON(ReadText(Path,256*1024,True));
      if J is TJSONObject then begin
        O:=TJSONObject(J);
        if not ProcessRunning(O.Get('pid',0))then begin
          QueueReport(O.Get('report_id',NewId),O.Get('log',''),O.Get('version','unknown'),
            'Previous session ended unexpectedly',O.Get('machine',''),O.Get('build',0));
          SysUtils.DeleteFile(Path);
        end;
      end;
    except on E:Exception do Logger.Warning('[CrashReport] Recovery deferred: '+E.ClassName);end;
    J.Free;
  until FindNext(SR)<>0;finally SysUtils.FindClose(SR);end;
end;

procedure RefreshCrashDiagnostics;
var J:TJSONObject;
begin
  if Marker=''then Exit;
  try
    { FPC returns SizeUInt (QWord on Win64); fpjson's array-of-const
      constructor does not support vtQWord. A PID fits in signed Int64. }
    J:=TJSONObject.Create(['report_id',SessionId,'pid',Int64(GetProcessID),'log',GetLogFileName,
      'build',ClientBuild,'version',ClientVersion,
      'machine',Copy(RedactClientLog(MachineDiagnosticsSnapshot),1,64*1024)]);
    try SaveJson(Marker,J);finally J.Free;end;
  except on E:Exception do Logger.Warning('[CrashReport] Machine snapshot deferred: '+E.ClassName);end;
end;

procedure StartCrashReports;
begin
  if Hook<>nil then Exit;
  try
    ForceDirectories(ClientDiagnosticsDir);RecoverReports;
    SessionId:=NewId;Marker:=ClientDiagnosticsDir+SessionId+'.running.json';
    RefreshCrashDiagnostics;
    Hook:=TCrashHook.Create;Hook.Previous:=Application.OnException;Application.OnException:=@Hook.Handle;
  except on E:Exception do Logger.Warning('[CrashReport] Initialization failed: '+E.ClassName);end;
end;

procedure CaptureCrash(E:Exception);
var Text:String;I:Integer;
begin
  if Capturing or Reported or(E is EAbort)then Exit;Capturing:=True;
  try
    Text:=E.ClassName+': '+E.Message;
    if Assigned(BackTraceStrFunc)then begin
      if ExceptAddr<>nil then Text:=Text+#10+BackTraceStrFunc(ExceptAddr);
      if ExceptFrames<>nil then for I:=0 to ExceptFrameCount-1 do begin
        if I>=32 then Break;Text:=Text+#10+BackTraceStrFunc(ExceptFrames[I]);
      end;
    end;
    Logger.Error('[CrashReport] '+RedactClientLog(Text));Logger.FlushNow;
    ForceDirectories(ClientDiagnosticsDir);
    if SessionId=''then SessionId:=NewId;
    QueueReport(SessionId,GetLogFileName,ClientVersion,Text,
      MachineDiagnosticsSnapshot,ClientBuild);Reported:=True;
  except { Never replace the original exception with a reporting failure. }
  end;
  Capturing:=False;
end;

procedure TCrashHook.Handle(Sender:TObject;E:Exception);
begin
  CaptureCrash(E);
  { Preserve CGE's exception dialog and StopOnException behavior. }
  Application.OnException:=Previous;
  try Application.HandleException(Sender);finally Application.OnException:=@Handle;end;
end;

constructor TCrashUpload.Create(const Base:String);
begin inherited Create(True);FreeOnTerminate:=False;FBase:=ExcludeTrailingPathDelimiter(Base);FWake:=TEvent.Create(nil,False,False,'');Start;end;
destructor TCrashUpload.Destroy;
begin Terminate;Wake;WaitFor;FWake.Free;inherited;end;
procedure TCrashUpload.Wake;
begin FWake.SetEvent;end;
function TCrashUpload.Upload(const FileName:String):Boolean;
var Body,Reply:TStringStream;Headers:TStringList;Status:Integer;J:TJSONData;
begin
  Result:=False;Body:=TStringStream.Create(ReadText(FileName,2*1024*1024));Reply:=TStringStream.Create('');Headers:=TStringList.Create;J:=nil;
  try
    Headers.Add('Content-Type: application/json');Headers.Add('User-Agent: '+ClientUserAgent);
    GameHttpRequest('POST',FBase+'/api/v1/client/crash',Headers,Body,2000,3000,Reply,Status);
    if(Status>=200)and(Status<300)then begin
      J:=GetJSON(Reply.DataString);Result:=(J is TJSONObject)and TJSONObject(J).Get('accepted',False)
        and(TJSONObject(J).Get('report_id','')=Copy(ExtractFileName(FileName),1,36));
    end;
  finally J.Free;Headers.Free;Reply.Free;Body.Free;end;
end;
procedure TCrashUpload.Execute;
var SR:TSearchRec;Path:String;Count:Integer;
begin
  while not Terminated do begin
    Count:=0;
    if FindFirst(ClientDiagnosticsDir+'*.report.json',faAnyFile,SR)=0 then
      try repeat
        if Terminated or(Count>=3)then Break;Inc(Count);Path:=ClientDiagnosticsDir+SR.Name;
        try if Upload(Path)then SysUtils.DeleteFile(Path);except end;
      until FindNext(SR)<>0;finally SysUtils.FindClose(SR);end;
    if not Terminated then FWake.WaitFor(60000);
  end;
end;
procedure EnableCrashUpload(const ApiBase:String);
begin
  if(Worker=nil)and(SysUtils.GetEnvironmentVariable('REZVIVO_TEST_NO_UPLOAD')<>'1')then
    Worker:=TCrashUpload.Create(ApiBase);
end;
procedure MarkClientCleanExit;
begin CleanExit:=True;end;

finalization
  FreeAndNil(Worker);
  if Hook<>nil then begin Application.OnException:=Hook.Previous;FreeAndNil(Hook);end;
  if CleanExit and(ExitCode=0)and(Marker<>'')then SysUtils.DeleteFile(Marker);
end.
