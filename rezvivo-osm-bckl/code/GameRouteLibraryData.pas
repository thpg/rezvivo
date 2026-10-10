unit GameRouteLibraryData;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses Classes, SysUtils, SyncObjs, fpjson;

type
  TRouteTask = class(TThread)
  private
    FLock: TCriticalSection;
    FDone: Boolean;
  protected
    procedure Execute; override;
  public
    UserId, RouteId: Int64;
    RequestTimeoutMS:Integer;
    Method, Path, Body, UploadFile, DownloadFile, ErrorText: String;
    Response: TJSONData;
    constructor Create(AUserId: Int64; const AMethod, APath, ABody: String);
    destructor Destroy; override;
    function Done: Boolean;
  end;

function RouteAccountDir(AUserId: Int64): String;
function RouteEncode(const S: String): String;
function RouteJSONText(O: TJSONObject; const Key: String; const Default: String = ''): String;
function RouteMetric(O: TJSONObject; const Key: String; Divisor: Double = 1): String;
procedure RouteDetach(var Task: TRouteTask);
{ Transfer a started thread with FreeOnTerminate=False to the shared cleanup queue. }
procedure DetachBackgroundThread(Task:TThread);
procedure RouteLibraryTick;
procedure QueueLocalRoute(const FileName: String);
function RouteUploadStatus: String;
procedure SaveRouteCatalog(UserId:Int64;Items:TJSONArray);
function ReadRouteCatalog(UserId:Int64):TJSONArray;
procedure WriteAccountJSON(const Name:String;Obj:TJSONObject);
function ReadAccountJSON(const Name:String):TJSONObject;

implementation
uses AppRuntimePaths, UiTranslations, Math, DateUtils, jsonparser, CastleURIUtils, CastleApplicationProperties, VeloSiteAPI
  {$ifdef MSWINDOWS}, Windows{$endif};

type TRoutePump=class
  procedure Update(Sender:TObject);
end;
var Detached: TList; UploadTask: TRouteTask; UploadMarker: String;Pump:TRoutePump;
    LastPoll: QWord; UploadInfo: String;

constructor TRouteTask.Create(AUserId: Int64; const AMethod,APath,ABody: String);
begin
  inherited Create(True);FreeOnTerminate:=False;FLock:=SyncObjs.TCriticalSection.Create;
  UserId:=AUserId;Method:=AMethod;Path:=APath;Body:=ABody;
  RequestTimeoutMS:=20000;
end;
destructor TRouteTask.Destroy;
begin Response.Free;FLock.Free;inherited;end;
function TRouteTask.Done:Boolean;
begin FLock.Enter;try Result:=FDone;finally FLock.Leave;end;end;
procedure TRouteTask.Execute;
begin
  try
    if not Terminated then
      if UploadFile<>'' then Response:=VeloSite.UploadRoute(UserId,UploadFile)
      else if DownloadFile<>'' then
      begin
        if not FileExists(DownloadFile) then VeloSite.DownloadRoute(UserId,RouteId,DownloadFile);
        Response:=TJSONObject.Create(['file',DownloadFile]);
      end
      else Response:=VeloSite.LibraryRequest(UserId,Method,Path,Body,RequestTimeoutMS);
  except on E:Exception do ErrorText:=E.Message;end;
  Body:='';
  FLock.Enter;try FDone:=True;finally FLock.Leave;end;
end;
function RouteAccountDir(AUserId:Int64):String;
begin
  if(Copy(VeloSite.BaseUrl,1,17)='http://127.0.0.1:')and(SysUtils.GetEnvironmentVariable('REZVIVO_TEST_ACCOUNT_DIR')<>'')then
    Exit(IncludeTrailingPathDelimiter(SysUtils.GetEnvironmentVariable('REZVIVO_TEST_ACCOUNT_DIR'))+IntToStr(AUserId)+PathDelim);
  Result:=IncludeTrailingPathDelimiter(AppDirectory)+
    'users'+PathDelim+'accounts'+PathDelim+IntToStr(AUserId)+PathDelim;
end;
function RouteEncode(const S:String):String;
var I:Integer;
begin Result:='';for I:=1 to Length(S) do
  if S[I] in ['A'..'Z','a'..'z','0'..'9','-','_','.','~'] then Result:=Result+S[I]
  else Result:=Result+'%'+IntToHex(Ord(S[I]),2);end;
function RouteJSONText(O:TJSONObject;const Key,Default:String):String;
var D:TJSONData;
begin Result:=Default;if O=nil then Exit;D:=O.Find(Key);if(D<>nil)and(D.JSONType<>jtNull)then Result:=D.AsString;end;
function RouteMetric(O:TJSONObject;const Key:String;Divisor:Double):String;
var D:TJSONData;FS:TFormatSettings;
begin Result:='—';if O=nil then Exit;D:=O.Find(Key);if(D=nil)or(D.JSONType=jtNull)then Exit;
  FS:=DefaultFormatSettings;FS.DecimalSeparator:='.';
  if Divisor=1 then Result:=FormatFloat('0',D.AsFloat,FS) else Result:=FormatFloat('0.0',D.AsFloat/Divisor,FS);end;
procedure RouteDetach(var Task:TRouteTask);
begin if Task=nil then Exit;Task.Terminate;DetachBackgroundThread(Task);Task:=nil;end;
procedure DetachBackgroundThread(Task:TThread);
begin if(Task<>nil)and(Detached.IndexOf(Task)<0)then Detached.Add(Task);end;

procedure WriteJSON(const Name:String;Obj:TJSONObject);
var F:TFileStream;S:String;
begin
  ForceDirectories(ExtractFileDir(Name));S:=Obj.AsJSON;
  F:=TFileStream.Create(Name+'.tmp',fmCreate);try if S<>'' then F.WriteBuffer(S[1],Length(S));finally F.Free;end;
  { RenameFile on Windows replaces an existing destination through MoveFileEx. }
  {$ifdef MSWINDOWS}
  if not MoveFileExW(PWideChar(UTF8Decode(Name+'.tmp')),PWideChar(UTF8Decode(Name)),MOVEFILE_REPLACE_EXISTING or $8) then
  {$else}
  if not RenameFile(Name+'.tmp',Name) then
  {$endif}
    raise Exception.Create(UiText('Could not save the route queue'));
end;
function ReadJSON(const Name:String):TJSONObject;
var F:TFileStream;D:TJSONData;
begin
  F:=TFileStream.Create(Name,fmOpenRead or fmShareDenyWrite);
  try D:=GetJSON(F);finally F.Free;end;
  if not(D is TJSONObject)then begin D.Free;raise Exception.Create(UiText('The route queue is corrupt'));end;
  Result:=TJSONObject(D);
end;
procedure SaveRouteCatalog(UserId:Int64;Items:TJSONArray);
var O:TJSONObject;
begin
  if UserId<=0 then Exit;O:=TJSONObject.Create(['user_id',UserId]);O.Add('items',Items.Clone);
  try WriteJSON(RouteAccountDir(UserId)+'library.json',O);finally O.Free;end;
end;
procedure WriteAccountJSON(const Name:String;Obj:TJSONObject);
begin WriteJSON(Name,Obj);end;
function ReadAccountJSON(const Name:String):TJSONObject;
begin Result:=ReadJSON(Name);end;
function ReadRouteCatalog(UserId:Int64):TJSONArray;
var O:TJSONObject;D:TJSONData;
begin
  Result:=TJSONArray.Create;if(UserId<=0)or(not FileExists(RouteAccountDir(UserId)+'library.json'))then Exit;
  O:=ReadJSON(RouteAccountDir(UserId)+'library.json');try
    if O.Get('user_id',Int64(0))<>UserId then Exit;D:=O.Find('items');if D is TJSONArray then begin Result.Free;Result:=TJSONArray(D.Clone);end;
  finally O.Free;end;
end;
procedure QueueLocalRoute(const FileName:String);
var UserId:Int64;Dir,Dest,Marker:String;G:TGUID;InFile,OutFile:TFileStream;O:TJSONObject;
begin
  UserId:=VeloSite.CachedProfile.Id;
  if(UserId<=0)or(not VeloSite.IsAuthorized)then begin UploadInfo:=UiText('Saved locally. Sign in to upload it.');Exit;end;
  CreateGUID(G);Dir:=RouteAccountDir(UserId)+'upload-queue'+PathDelim+
    StringReplace(StringReplace(GUIDToString(G),'{','',[]),'}','',[])+PathDelim;
  ForceDirectories(Dir);Dest:=Dir+ExtractFileName(FileName);Marker:=Dir+'pending.json';
  InFile:=TFileStream.Create(FileName,fmOpenRead or fmShareDenyWrite);
  try
    if InFile.Size>32*1024*1024 then raise Exception.Create(UiText('Route saved locally: the file exceeds 32 MiB'));
    OutFile:=TFileStream.Create(Dest,fmCreate);try OutFile.CopyFrom(InFile,0);finally OutFile.Free;end;
  finally InFile.Free;end;
  O:=TJSONObject.Create(['user_id',UserId,'file',Dest,'attempts',0,'next_at',Int64(0)]);
  try WriteJSON(Marker,O);finally O.Free;end;
  UploadInfo:=UiText('Route queued for upload');LastPoll:=0;
end;
function RouteUploadStatus:String;
begin Result:=UploadInfo;end;
procedure RouteLibraryTick;
var I,Attempt:Integer;T:TThread;UserId:Int64;Dir,Marker:String;SR:TSearchRec;O:TJSONObject;NextAt:Int64;
begin
  for I:=Detached.Count-1 downto 0 do begin T:=TThread(Detached[I]);if T.Finished then begin Detached.Delete(I);T.Free;end;end;
  if UploadTask<>nil then
  begin
    if not UploadTask.Done then Exit;
    try
      if UploadTask.ErrorText='' then
      begin
        { Keep a small receipt; only temporary upload bytes are removed. }
        O:=ReadJSON(UploadMarker);
        try
          O.Add('route_id',TJSONObject(UploadTask.Response).Get('route_id',Int64(0)));
          WriteJSON(ExtractFileDir(UploadMarker)+PathDelim+'sent.json',O);
          SysUtils.DeleteFile(UploadMarker);SysUtils.DeleteFile(UploadTask.UploadFile);
        finally O.Free;end;
        UploadInfo:=UiText('Route uploaded to your profile');
      end else
      begin
        O:=ReadJSON(UploadMarker);
        try
          Attempt:=O.Get('attempts',0)+1;O.Integers['attempts']:=Attempt;
          O.Int64s['next_at']:=DateTimeToUnix(Now,False)+Min(1800,Int64(10) shl Min(Attempt,7));
          O.Strings['error']:=UploadTask.ErrorText;WriteJSON(UploadMarker,O);
        finally O.Free;end;
        UploadInfo:=UiText('Upload deferred: ')+UploadTask.ErrorText;
      end;
    except on E:Exception do UploadInfo:=E.Message;end;
    FreeAndNil(UploadTask);
  end;
  if GetTickCount64-LastPoll<2000 then Exit;LastPoll:=GetTickCount64;
  UserId:=VeloSite.CachedProfile.Id;if(UserId<=0)or(not VeloSite.IsAuthorized)then Exit;
  Dir:=RouteAccountDir(UserId)+'upload-queue'+PathDelim;
  if FindFirst(Dir+'*',faDirectory,SR)=0 then
  try repeat
    if(SR.Attr and faDirectory=0)or(SR.Name='.')or(SR.Name='..')then Continue;
    Marker:=Dir+SR.Name+PathDelim+'pending.json';if not FileExists(Marker)then Continue;
    try
      O:=ReadJSON(Marker);
      try
        if O.Get('user_id',Int64(0))<>UserId then Continue;
        NextAt:=O.Get('next_at',Int64(0));if NextAt>DateTimeToUnix(Now,False)then Continue;
        if not FileExists(O.Get('file',''))then Continue;
        UploadTask:=TRouteTask.Create(UserId,'POST','/routes','');UploadTask.UploadFile:=O.Get('file','');
        UploadMarker:=Marker;UploadTask.Start;UploadInfo:=UiText('Uploading route to your profile…');Break;
      finally O.Free;end;
    except on E:Exception do UploadInfo:=E.Message;end;
  until FindNext(SR)<>0;finally SysUtils.FindClose(SR);end;
end;
procedure TRoutePump.Update(Sender:TObject);
begin RouteLibraryTick;end;
initialization
  Detached:=TList.Create;
  Pump:=TRoutePump.Create;ApplicationProperties.OnUpdate.Add(@Pump.Update);
finalization
  ApplicationProperties.OnUpdate.Remove(@Pump.Update);Pump.Free;
  if UploadTask<>nil then begin UploadTask.Terminate;UploadTask.WaitFor;UploadTask.Free;end;
  while Detached.Count>0 do begin TThread(Detached[0]).WaitFor;TThread(Detached[0]).Free;Detached.Delete(0);end;
  Detached.Free;
end.
