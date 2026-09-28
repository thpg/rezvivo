unit GameRideRooms;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses Classes,SysUtils,GameHttpClient;
type
  TRideRoomInfo=record
    Code,Kind,WorldId,Title,ContentHash,RelayUrl,RouteFile,Manifest,ErrorText:string;
    RiderId,StartSlot,Members:Integer;
  end;
  TRideRoomOperation=(roCreate,roJoin,roLeave);
  TRideRoomTask=class(TThread)
  private
    FCancel:TGameHttpCancellation;
    FOperation:TRideRoomOperation;
    FInput:TRideRoomInfo;
    FBase,FDirectory,FDreamDirectory:string;
    FAccountId:Int64;
    FCleanupCode:string;
    function Request(const Method,Path,Body:string;Limit:Integer):string;
    procedure CleanupMembership;
    procedure Work;
  protected
    procedure Execute;override;
  public
    ResultInfo:TRideRoomInfo;
    constructor Create(Operation:TRideRoomOperation;const Input:TRideRoomInfo;
      const Base,Directory,DreamDirectory:string;AccountId:Int64);
    destructor Destroy;override;
    procedure Cancel;
  end;
  TRideRooms=class
  private
    FTask:TRideRoomTask;
    FInfo:TRideRoomInfo;
    FError:string;
    FOperation:TRideRoomOperation;
    FAccount:Int64;
    procedure BeginTask(Operation:TRideRoomOperation;const Info:TRideRoomInfo);
  public
    RelayError:string;
    destructor Destroy;override;
    procedure CreateRoom(const Kind,SourceFile:string);
    procedure Join(const Code:string);
    procedure Leave;
    procedure Cancel;
    procedure Update;
    function Busy:Boolean;
    function Active:Boolean;
    function MatchesRide(const FitFile,WorldId:string):Boolean;
    property Info:TRideRoomInfo read FInfo;
    property ErrorText:string read FError;
  end;
function RideRooms:TRideRooms;
function NormalizeRoomCode(const Code:string):string;
function ValidRoomHash(const Value:string):Boolean;
function DreamRoomHash(const Manifest:string;Cancel:TGameHttpCancellation=nil):string;
implementation
uses Math,fpjson,jsonparser,base64,CastleURIUtils,UiTranslations,
  VeloSiteAPI,GameUserData,GameUpdateDownload;
const MaxRouteBytes=4*1024*1024;
type
  TLimitedResponse=class(TStringStream)
    Limit:Integer;
    function Write(const Buffer;Count:LongInt):LongInt;override;
  end;
var RoomsInstance:TRideRooms;
function ValidRoomHash(const Value:string):Boolean;
var C:Char;
begin
  Result:=Length(Value)=64;if not Result then Exit;
  for C in Value do if not(C in['0'..'9','a'..'f','A'..'F'])then Exit(False);
end;
function TLimitedResponse.Write(const Buffer;Count:LongInt):LongInt;
begin
  if Position+Count>Limit then raise Exception.Create('Room response exceeds size limit');
  Result:=inherited Write(Buffer,Count);
end;
function RideRooms:TRideRooms;
begin if RoomsInstance=nil then RoomsInstance:=TRideRooms.Create;Result:=RoomsInstance end;
function NormalizeRoomCode(const Code:string):string;
var C:Char;S:string;P:Integer;
begin
  S:=Trim(Code);P:=Pos('room=',LowerCase(S));if P>0 then S:=Copy(S,P+5,MaxInt);
  Result:='';
  for C in UpperCase(S)do begin
    if C in[' ','-']then Continue;
    if not(C in['A'..'Z','2'..'7'])then Exit('');Result:=Result+C;
  end;
  if Length(Result)<>10 then Result:='';
end;
function ReadSmallFile(const Path:string;Limit:Integer):string;
var S:TFileStream;
begin
  S:=TFileStream.Create(Path,fmOpenRead or fmShareDenyWrite);
  try
    if(S.Size<1)or(S.Size>Limit)then raise Exception.Create('Route file must be between 1 byte and 4 MiB');
    SetLength(Result,S.Size);S.ReadBuffer(Result[1],Length(Result));
  finally S.Free end;
end;
function DreamRoomHash(const Manifest:string;Cancel:TGameHttpCancellation):string;
var Files,Lines:TStringList;Root,Path,Tmp,Rel:string;G:TGUID;I:Integer;
  procedure Collect(const Directory:string);
  var R:TSearchRec;P,Ext:string;
  begin
    if Cancel<>nil then Cancel.Check;
    if FindFirst(IncludeTrailingPathDelimiter(Directory)+'*',faAnyFile,R)<>0 then Exit;
    try repeat
      if(R.Name='.')or(R.Name='..')then Continue;
      P:=IncludeTrailingPathDelimiter(Directory)+R.Name;
      if R.Attr and faDirectory<>0 then Collect(P)
      else begin
        Ext:=LowerCase(ExtractFileExt(P));
        if(Ext='.json')or(Ext='.x3d')or(Ext='.glb')or(Ext='.gltf')or(Ext='.bin')or
          (Ext='.png')or(Ext='.jpg')or(Ext='.jpeg')or(Ext='.webp')or(Ext='.ktx')then Files.Add(P);
      end;
    until FindNext(R)<>0;finally FindClose(R)end;
  end;
begin
  if not FileExists(Manifest)then raise Exception.Create('Dream world is not installed');
  Root:=IncludeTrailingPathDelimiter(ExpandFileName(ExtractFileDir(Manifest)));
  Files:=TStringList.Create;Files.CaseSensitive:=True;Files.Sorted:=True;
  Lines:=TStringList.Create;Lines.LineBreak:=#10;Tmp:='';
  try
    Collect(Root);Lines.Add('REZVIVO-DREAM-PACKAGE-SHA256-v1');
    { Stable package identity: sorted relative UTF-8 paths and SHA256 bytes.
      Documents/editor backups are not runtime world content. }
    for I:=0 to Files.Count-1 do begin
      Path:=Files[I];Rel:=StringReplace(Copy(Path,Length(Root)+1,MaxInt),'\','/',[rfReplaceAll]);
      Lines.Add(Rel+#0+LowerCase(UpdateSHA256(Path,Cancel)));
    end;
    CreateGUID(G);Tmp:=IncludeTrailingPathDelimiter(GetTempDir)+'rezvivo-room-'+GUIDToString(G)+'.digest';
    Lines.SaveToFile(Tmp);Result:=LowerCase(UpdateSHA256(Tmp,Cancel));
  finally if Tmp<>''then DeleteFile(Tmp);Lines.Free;Files.Free end;
end;
constructor TRideRoomTask.Create(Operation:TRideRoomOperation;const Input:TRideRoomInfo;
  const Base,Directory,DreamDirectory:string;AccountId:Int64);
begin
  inherited Create(True);FCancel:=TGameHttpCancellation.Create;
  FOperation:=Operation;FInput:=Input;FBase:=ExcludeTrailingPathDelimiter(Base);
  FDirectory:=Directory;FDreamDirectory:=DreamDirectory;FAccountId:=AccountId;Start;
end;
destructor TRideRoomTask.Destroy;
begin Cancel;WaitFor;FCancel.Free;inherited end;
procedure TRideRoomTask.Cancel;
begin Terminate;FCancel.Cancel end;
function TRideRoomTask.Request(const Method,Path,Body:string;Limit:Integer):string;
var H:TStringList;Input:TStringStream;Output:TLimitedResponse;Status:Integer;Token:string;
begin
  FCancel.Check;
  Token:=VeloSite.GetAccessTokenForUser(FAccountId);
  if Token=''then raise Exception.Create('Sign in to ride with a friend.');
  H:=TStringList.Create;Input:=TStringStream.Create(Body);Output:=TLimitedResponse.Create('');Output.Limit:=Limit;
  try
    H.Add('Authorization: Bearer '+Token);H.Add('Content-Type: application/json');
    GameHttpRequest(Method,FBase+'/api/v1/relay/rooms'+Path,H,Input,3000,6000,Output,Status,FCancel);
    if Status=404 then raise Exception.Create('Room not found, expired, or this server does not support rooms yet.');
    if Status=401 then begin VeloSite.RefreshProfileAsync;raise Exception.Create('Sign in again to join a room.')end;
    if Status=403 then raise Exception.Create('You are not a member of this room.');
    if Status=409 then raise Exception.Create('The room is full.');
    if Status=429 then raise Exception.Create('Too many room requests. Please try again shortly.');
    if(Status<200)or(Status>=300)then raise Exception.CreateFmt('Room server HTTP %d',[Status]);
    Result:=Output.DataString;
  finally Output.Free;Input.Free;H.Free end;
end;
procedure TRideRoomTask.CleanupMembership;
var H:TStringList;Output:TLimitedResponse;Token:string;Status:Integer;
begin
  if FCleanupCode=''then Exit;
  Token:=VeloSite.GetAccessTokenForUser(FAccountId);if Token=''then Exit;
  H:=TStringList.Create;Output:=TLimitedResponse.Create('');Output.Limit:=65536;
  try
    H.Add('Authorization: Bearer '+Token);
    { Independent, bounded cleanup remains possible after the original request
      was cancelled. No UI callback, and no original account's new token. }
    try GameHttpRequest('POST',FBase+'/api/v1/relay/rooms/'+FCleanupCode+'/leave',
      H,nil,300,400,Output,Status);except end;
  finally Output.Free;H.Free end;
end;
procedure TRideRoomTask.Work;
var Body,J,W:TJSONObject;D:TJSONData;Raw,Ext,Path,Hash,Code:string;S:TStringStream;
begin
  ResultInfo:=FInput;
  if FOperation=roLeave then begin Request('POST','/'+FInput.Code+'/leave','{}',65536);ResultInfo:=Default(TRideRoomInfo);Exit end;
  Body:=TJSONObject.Create;
  try
    if FOperation=roCreate then begin
      if FInput.Kind='dream'then begin
        Raw:=ReadSmallFile(FInput.Manifest,MaxRouteBytes);D:=GetJSON(Raw);
        try
          if not(D is TJSONObject)then raise Exception.Create('Invalid Dream manifest');
          J:=TJSONObject(D);ResultInfo.WorldId:=J.Get('id','');ResultInfo.Title:=J.Get('title',ResultInfo.WorldId);
        finally D.Free end;
        Hash:=DreamRoomHash(FInput.Manifest,FCancel);
      end else begin
        Raw:=ReadSmallFile(FInput.RouteFile,MaxRouteBytes);Ext:=LowerCase(Copy(ExtractFileExt(FInput.RouteFile),2,MaxInt));
        if(Ext<>'fit')and(Ext<>'gpx')then raise Exception.Create('Select a FIT or GPX route.');
        Hash:=LowerCase(UpdateSHA256(FInput.RouteFile,FCancel));
        ResultInfo.WorldId:=ExtractFileName(FInput.RouteFile);ResultInfo.Title:=ChangeFileExt(ResultInfo.WorldId,'');
        Body.Add('route_format',Ext);Body.Add('route_data',EncodeStringBase64(Raw));
      end;
      W:=TJSONObject.Create(['kind',FInput.Kind,'id',ResultInfo.WorldId,'title',ResultInfo.Title,'content_hash',Hash]);Body.Add('world',W);
      Raw:=Request('POST','',Body.AsJSON,65536);
    end else begin
      Code:=NormalizeRoomCode(FInput.Code);if Code=''then raise Exception.Create('Enter a valid 10-character room code.');
      Body.Add('code',Code);FCleanupCode:=Code;Raw:=Request('POST','/join',Body.AsJSON,65536);
    end;
  finally Body.Free end;
  D:=GetJSON(Raw);
  try
    if not(D is TJSONObject)then raise Exception.Create('Invalid room response');J:=TJSONObject(D);
    ResultInfo.Code:=NormalizeRoomCode(J.Get('code',''));
    if ResultInfo.Code<>''then FCleanupCode:=ResultInfo.Code;
    if not(J.Find('world')is TJSONObject)then raise Exception.Create('Invalid room response');
    W:=J.Objects['world'];
    ResultInfo.Kind:=W.Get('kind','');ResultInfo.WorldId:=W.Get('id','');ResultInfo.Title:=W.Get('title','');
    ResultInfo.ContentHash:=LowerCase(W.Get('content_hash',''));ResultInfo.RiderId:=J.Get('rider_id',0);
    ResultInfo.StartSlot:=J.Get('start_slot',0);ResultInfo.Members:=J.Get('members',0);
    if(ResultInfo.Code='')or(ResultInfo.RiderId<>FAccountId)or not ValidRoomHash(ResultInfo.ContentHash)or
      (ResultInfo.StartSlot<0)or(ResultInfo.StartSlot>7)then
      raise Exception.Create('Invalid room identity');
    { Ignore server-supplied relay URLs: bearer tokens stay on this API host. }
    ResultInfo.RelayUrl:=FBase+'/api/v1/relay/rooms/'+ResultInfo.Code;
    if ResultInfo.Kind='real'then begin
      Ext:=J.Get('route_format','');
      if((Ext<>'fit')and(Ext<>'gpx'))or(J.Get('route_size',0)>MaxRouteBytes)or(J.Get('route_size',0)<1)then raise Exception.Create('Invalid shared route');
      if(FOperation=roCreate)and not SameText(Hash,ResultInfo.ContentHash)then raise Exception.Create('Shared route checksum does not match.');
      if FOperation=roJoin then begin
        Raw:=Request('GET','/'+ResultInfo.Code+'/route','',MaxRouteBytes);
        if Length(Raw)<>J.Get('route_size',0)then raise Exception.Create('Shared route download is incomplete.');
        ForceDirectories(FDirectory);Path:=IncludeTrailingPathDelimiter(FDirectory)+ResultInfo.ContentHash+'.'+Ext;
        S:=TStringStream.Create(Raw);try S.SaveToFile(Path+'.part');finally S.Free end;
        try
          if not SameText(UpdateSHA256(Path+'.part',FCancel),ResultInfo.ContentHash)then raise Exception.Create('Shared route checksum does not match.');
          if FileExists(Path)then DeleteFile(Path);
          if not RenameFile(Path+'.part',Path)then raise Exception.Create('Could not save the shared route.');
        finally DeleteFile(Path+'.part')end;
        ResultInfo.RouteFile:=Path;
      end;
    end else if ResultInfo.Kind='dream'then begin
      if(Pos('/',ResultInfo.WorldId)>0)or(Pos('\',ResultInfo.WorldId)>0)or(Pos('..',ResultInfo.WorldId)>0)or(Pos(':',ResultInfo.WorldId)>0)then
        raise Exception.Create('Invalid Dream world identifier');
      if FOperation=roJoin then ResultInfo.Manifest:=IncludeTrailingPathDelimiter(FDreamDirectory)+ResultInfo.WorldId+PathDelim+'world.json';
      if FOperation=roJoin then Hash:=DreamRoomHash(ResultInfo.Manifest,FCancel);
      if not SameText(Hash,ResultInfo.ContentHash)then
        raise Exception.Create('This room uses a different Dream world version. Update the world first.');
    end else raise Exception.Create('Unsupported room world');
  finally D.Free end;
end;
procedure TRideRoomTask.Execute;
begin
  try Work;FCancel.Check;except on E:Exception do begin
    if Terminated then ResultInfo.ErrorText:='Cancelled'else ResultInfo.ErrorText:=E.Message;
    if FOperation<>roLeave then CleanupMembership;
  end end;
end;
destructor TRideRooms.Destroy;
begin if FTask<>nil then begin FTask.Cancel;FTask.WaitFor;FTask.Free end;inherited end;
procedure TRideRooms.BeginTask(Operation:TRideRoomOperation;const Info:TRideRoomInfo);
begin
  Update;if Busy then Exit;FError:='';
  if not VeloSite.IsAuthorized or(VeloSite.CachedProfile.Id=0)then begin FError:='Sign in to ride with a friend.';Exit end;
  FAccount:=VeloSite.CachedProfile.Id;
  if(Operation=roLeave)and(Info.RiderId<>FAccount)then Exit;
  FOperation:=Operation;
  FTask:=TRideRoomTask.Create(Operation,Info,VeloSite.BaseUrl,UserDataDir+'shared-routes',
    URIToFilenameSafe('castle-data:/dream-worlds/'),FAccount);
end;
procedure TRideRooms.CreateRoom(const Kind,SourceFile:string);
var I:TRideRoomInfo;
begin
  if Busy or Active then Exit;
  I:=Default(TRideRoomInfo);I.Kind:=Kind;
  if(Kind<>'dream')and(Kind<>'real')then begin FError:='Select a world first.';Exit end;
  if Kind='dream'then I.Manifest:=SourceFile else I.RouteFile:=SourceFile;
  BeginTask(roCreate,I);
end;
procedure TRideRooms.Join(const Code:string);
var I:TRideRoomInfo;
begin if Busy or Active then Exit;I:=Default(TRideRoomInfo);I.Code:=Code;BeginTask(roJoin,I)end;
procedure TRideRooms.Leave;
var I:TRideRoomInfo;
begin if Busy then Exit;I:=FInfo;FInfo:=Default(TRideRoomInfo);RelayError:='';if I.Code<>''then BeginTask(roLeave,I)end;
procedure TRideRooms.Cancel;
begin if FTask<>nil then FTask.Cancel end;
procedure TRideRooms.Update;
var Cleanup:Boolean;CancelledInfo:TRideRoomInfo;
begin
  if(FTask<>nil)and FTask.Finished then begin
    FTask.WaitFor;
    Cleanup:=FTask.Terminated and(FTask.ResultInfo.ErrorText='')and
      (FOperation<>roLeave)and(NormalizeRoomCode(FTask.ResultInfo.Code)<>'');
    CancelledInfo:=FTask.ResultInfo;
    if FTask.Terminated then FError:='Cancelled'
    else if FTask.ResultInfo.ErrorText<>''then FError:=FTask.ResultInfo.ErrorText
    else if VeloSite.IsAuthorized and(VeloSite.CachedProfile.Id=FAccount)then FInfo:=FTask.ResultInfo;
    FreeAndNil(FTask);
    { Cancel may arrive after Execute's final check or after Finished. Retire
      that membership in a new worker, never accept it into active UI state. }
    if Cleanup then BeginTask(roLeave,CancelledInfo);
  end;
  if(FInfo.Code<>'')and(not VeloSite.IsAuthorized or(VeloSite.CachedProfile.Id<>FInfo.RiderId))then FInfo:=Default(TRideRoomInfo);
end;
function TRideRooms.Busy:Boolean;
begin Result:=FTask<>nil end;
function TRideRooms.Active:Boolean;
begin Update;Result:=FInfo.Code<>''end;
function TRideRooms.MatchesRide(const FitFile,WorldId:string):Boolean;
begin
  Result:=Active;if not Result then Exit;
  if FInfo.Kind='dream'then Result:=(WorldId=FInfo.WorldId)
  else Result:=(WorldId='')and(FitFile<>'')and SameFileName(ExpandFileName(FitFile),ExpandFileName(FInfo.RouteFile));
end;
finalization
  FreeAndNil(RoomsInstance);
end.
