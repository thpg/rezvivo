unit GameReadyRoutes;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses Classes,SysUtils,fpjson,GameHttpClient;
type
  TReadyRouteSync=class(TThread)
  private
    FBase,FDirectory,FRevision:string;
    FCancel:TGameHttpCancellation;
    function Fetch(const Path,ETag:string;Limit:Integer;out Status:Integer):string;
  protected
    procedure Execute;override;
  public
    Catalog:TJSONObject;
    ErrorText:string;
    constructor Create(const Base,Directory,Revision:string);
    destructor Destroy;override;
  end;
  TReadyRoutes=class
  private
    FDirectory,FBase:string;
    FCatalog:TJSONObject;
    FTask:TReadyRouteSync;
    FNextCheck:QWord;
    FGeneration:Cardinal;
    FError:string;
    function FileFor(Item:TJSONObject):string;
    function FindFile(const FileName:string):TJSONObject;
  public
    constructor Create;
    destructor Destroy;override;
    procedure Tick;
    procedure AppendFiles(Files:TStrings);
    function ResolveFile(const FileName:string):string;
    function Title(const FileName:string):string;
    function Identity(const FileName:string;out Id,SHA:string):Boolean;
    function Diagnostics:TJSONObject;
    property Generation:Cardinal read FGeneration;
  end;
function ReadyRoutes:TReadyRoutes;
procedure ReadyRoutesTick;
implementation
uses jsonparser,CastleDownload,AppRuntimePaths,VeloSiteAPI,GameUpdateDownload,
  GameLocalization,DebugLog{$ifdef MSWINDOWS},Windows{$endif};
type
  TBoundedRouteStream=class(TStringStream)
    Limit:Integer;
    function Write(const Buffer;Count:LongInt):LongInt;override;
  end;
var Instance:TReadyRoutes;
function TBoundedRouteStream.Write(const Buffer;Count:LongInt):LongInt;
begin if Position+Count>Limit then raise Exception.Create('Ready route exceeds size limit');Result:=inherited Write(Buffer,Count)end;
function ValidId(const S:string):Boolean;
var C:Char;
begin Result:=(Length(S)>0)and(Length(S)<=80);if not Result then Exit;for C in S do if not(C in ['a'..'z','0'..'9','-'])then Exit(False)end;
function ValidSHA(const S:string):Boolean;
var C:Char;
begin Result:=Length(S)=64;if not Result then Exit;for C in S do if not(C in ['a'..'f','0'..'9'])then Exit(False)end;
function ReadObject(const Raw:string):TJSONObject;
var D:TJSONData;A:TJSONArray;I:Integer;O:TJSONObject;Ids:TStringList;
begin
 D:=GetJSON(Raw);try
  if not(D is TJSONObject)then raise Exception.Create('Invalid ready route catalogue');
  Result:=TJSONObject(D);
  if(Result.Get('schema',0)<>1)or not(Result.Find('items')is TJSONArray)then raise Exception.Create('Invalid ready route schema');
  if(Result.Get('revision','')<>'')and not ValidSHA(Result.Get('revision',''))then raise Exception.Create('Invalid ready route revision');
  A:=Result.Arrays['items'];if A.Count>256 then raise Exception.Create('Ready route catalogue is too large');
  Ids:=TStringList.Create;try
   for I:=0 to A.Count-1 do begin
    if not(A[I]is TJSONObject)then raise Exception.Create('Invalid route item');O:=TJSONObject(A[I]);
    if not ValidId(O.Get('id',''))or not ValidSHA(O.Get('sha256',''))or
     (O.Get('size_bytes',0)<1)or(O.Get('size_bytes',0)>4*1024*1024)or(Ids.IndexOf(O.Get('id',''))>=0)then raise Exception.Create('Invalid ready route identity');
    Ids.Add(O.Get('id',''));
   end;
  finally Ids.Free end;
 except D.Free;raise end;
end;
function ReadText(const FileName:string):string;
var S:TStringStream;
begin S:=TStringStream.Create('');try S.LoadFromFile(FileName);Result:=S.DataString;finally S.Free end end;
procedure AtomicSave(const FileName,Raw:string);
var S:TStringStream;
begin
 ForceDirectories(ExtractFileDir(FileName));S:=TStringStream.Create(Raw);
 try S.SaveToFile(FileName+'.part');finally S.Free end;
 {$ifdef MSWINDOWS}
 if not MoveFileExW(PWideChar(UTF8Decode(FileName+'.part')),PWideChar(UTF8Decode(FileName)),MOVEFILE_REPLACE_EXISTING or $8)then
 {$else}
 if not RenameFile(FileName+'.part',FileName)then
 {$endif}
  raise Exception.Create('Could not save ready route');
end;
function Asset(const Name:string):string;
var S:TStream;T:TStringStream;
begin
 S:=Download('castle-data:/ready-routes/'+Name);T:=TStringStream.Create('');
 try T.CopyFrom(S,0);Result:=T.DataString;finally T.Free;S.Free end;
end;
constructor TReadyRouteSync.Create(const Base,Directory,Revision:string);
begin inherited Create(True);FBase:=Base;FDirectory:=Directory;FRevision:=Revision;FCancel:=TGameHttpCancellation.Create;Start end;
destructor TReadyRouteSync.Destroy;
begin Terminate;FCancel.Cancel;WaitFor;FCancel.Free;Catalog.Free;inherited end;
function TReadyRouteSync.Fetch(const Path,ETag:string;Limit:Integer;out Status:Integer):string;
var H:TStringList;O:TBoundedRouteStream;
begin
 FCancel.Check;H:=TStringList.Create;O:=TBoundedRouteStream.Create('');O.Limit:=Limit;
 try
  if ETag<>''then H.Add('If-None-Match: "'+ETag+'"');
  GameHttpRequest('GET',FBase+'/api/v1/ready-routes'+Path,H,nil,3000,10000,O,Status,FCancel);
  if(Status<>200)and(Status<>304)then raise Exception.CreateFmt('Ready routes HTTP %d',[Status]);
  Result:=O.DataString;
 finally O.Free;H.Free end;
end;
procedure TReadyRouteSync.Execute;
var Raw,Path,SHA:string;Status,I:Integer;O:TJSONObject;A:TJSONArray;
begin
 try
  Raw:=Fetch('',FRevision,2*1024*1024,Status);if Status=304 then Exit;
  Catalog:=ReadObject(Raw);A:=Catalog.Arrays['items'];
  for I:=0 to A.Count-1 do begin
   FCancel.Check;O:=A.Objects[I];SHA:=O.Get('sha256','');Path:=FDirectory+'objects'+PathDelim+SHA+'.gpx';
   if FileExists(Path)and SameText(UpdateSHA256(Path,FCancel),SHA)then begin
    AtomicSave(Path+'.json',O.AsJSON);Continue;
   end;
   Raw:=Fetch('/'+O.Get('id','')+'/file?sha256='+SHA,'',O.Get('size_bytes',0),Status);
   if(Status<>200)or(Length(Raw)<>O.Get('size_bytes',0))then raise Exception.Create('Incomplete ready route');
   AtomicSave(Path+'.verify',Raw);
   try
    if not SameText(UpdateSHA256(Path+'.verify',FCancel),SHA)then raise Exception.Create('Ready route checksum mismatch');
    AtomicSave(Path,Raw);
    AtomicSave(Path+'.json',O.AsJSON);
   finally SysUtils.DeleteFile(Path+'.verify')end;
  end;
  FCancel.Check;AtomicSave(FDirectory+'catalog.json',Catalog.AsJSON);
 except on E:Exception do begin ErrorText:=E.Message;FreeAndNil(Catalog)end end;
end;
function ReadyRoutes:TReadyRoutes;
begin if Instance=nil then Instance:=TReadyRoutes.Create;Result:=Instance end;
procedure ReadyRoutesTick;
begin if Instance<>nil then Instance.Tick end;
constructor TReadyRoutes.Create;
var Seed:TJSONObject;A:TJSONArray;I:Integer;O:TJSONObject;P:string;
begin
 inherited;
 FDirectory:=IncludeTrailingPathDelimiter(AppDirectory)+'users'+PathDelim+'ready-routes'+PathDelim;
 if SysUtils.GetEnvironmentVariable('REZVIVO_TEST_ACCOUNT_DIR')<>''then FDirectory:=IncludeTrailingPathDelimiter(SysUtils.GetEnvironmentVariable('REZVIVO_TEST_ACCOUNT_DIR'))+'ready-routes'+PathDelim;
 ForceDirectories(FDirectory+'objects');
 if FileExists(FDirectory+'catalog.json')then try FCatalog:=ReadObject(ReadText(FDirectory+'catalog.json'));except FCatalog:=nil end;
 // Seed is installer content, not a private profile. Empty remote catalogues
 // remain empty; a deliberately unpublished route is not resurrected.
 { Bundled routes are a seed, not a prerequisite for opening Real World.
   An incomplete install must still allow personal routes, free exploration
   and asynchronous recovery from the server. Keep a valid cached catalogue. }
 Seed:=nil;
 try Seed:=ReadObject(Asset('catalog.json'));
 except on E:Exception do begin
  FError:='Bundled ready routes unavailable: '+E.Message;
  Logger.Warning('[ReadyRoutes] '+FError);
 end end;
 try
  if Seed<>nil then begin
   A:=Seed.Arrays['items'];for I:=0 to A.Count-1 do begin
    O:=A.Objects[I];P:=FileFor(O);
    try
     if not FileExists(P)then AtomicSave(P,Asset(O.Get('id','')+'.gpx'));
     if not FileExists(P+'.json')then AtomicSave(P+'.json',O.AsJSON);
    except on E:Exception do begin
     FError:='Bundled ready route '+O.Get('id','')+' unavailable: '+E.Message;
     Logger.Warning('[ReadyRoutes] '+FError);
    end end;
   end;
   if FCatalog=nil then begin FCatalog:=Seed;Seed:=nil end;
  end;
 finally Seed.Free end;
 if FCatalog=nil then FCatalog:=TJSONObject.Create(['schema',1,'revision','','items',TJSONArray.Create]);
 A:=FCatalog.Arrays['items'];for I:=0 to A.Count-1 do begin
  P:=FileFor(A.Objects[I]);
  if not FileExists(P)then FCatalog.Strings['revision']:=''
  else if not FileExists(P+'.json')then AtomicSave(P+'.json',A.Objects[I].AsJSON);
 end;
 FGeneration:=1;FBase:=ExcludeTrailingPathDelimiter(VeloSite.BaseUrl);
 Tick;
end;
destructor TReadyRoutes.Destroy;
begin FTask.Free;FCatalog.Free;inherited end;
function TReadyRoutes.FileFor(Item:TJSONObject):string;
begin Result:=FDirectory+'objects'+PathDelim+Item.Get('sha256','')+'.gpx' end;
procedure TReadyRoutes.Tick;
var Base:string;
begin
 if FTask<>nil then begin
  if not FTask.Finished then Exit;
  if FTask.Catalog<>nil then begin
   FCatalog.Free;FCatalog:=FTask.Catalog;FTask.Catalog:=nil;Inc(FGeneration);
   Logger.Info('[ReadyRoutes] Catalogue synchronized: '+IntToStr(FCatalog.Arrays['items'].Count));
  end;
  FError:=FTask.ErrorText;
  if FError<>''then begin Logger.Warning('[ReadyRoutes] '+FError);FNextCheck:=GetTickCount64+60000 end;
  FreeAndNil(FTask);
 end;
 Base:=ExcludeTrailingPathDelimiter(VeloSite.BaseUrl);if Base<>FBase then begin FBase:=Base;FNextCheck:=0 end;
 if(SysUtils.GetEnvironmentVariable('REZVIVO_OFFLINE')='1')or(GetTickCount64<FNextCheck)then Exit;
 FNextCheck:=GetTickCount64+300000;
 FTask:=TReadyRouteSync.Create(FBase,FDirectory,FCatalog.Get('revision',''));
end;
procedure TReadyRoutes.AppendFiles(Files:TStrings);
var A:TJSONArray;I:Integer;P:string;
begin A:=FCatalog.Arrays['items'];for I:=0 to A.Count-1 do begin P:=FileFor(A.Objects[I]);if FileExists(P)then Files.Add(P)end end;
function TReadyRoutes.ResolveFile(const FileName:string):string;
var D:TJSONData;A:TJSONArray;Id:string;I:Integer;
begin
 Result:=FileName;
 if FindFile(FileName)<>nil then Exit;
 if not SameFileName(ExtractFileDir(FileName),FDirectory+'objects')or
  not FileExists(FileName+'.json')then Exit;
 try
  D:=GetJSON(ReadText(FileName+'.json'));
  try
   if not(D is TJSONObject)then Exit;Id:=TJSONObject(D).Get('id','');
   A:=FCatalog.Arrays['items'];for I:=0 to A.Count-1 do
    if(A.Objects[I].Get('id','')=Id)and FileExists(FileFor(A.Objects[I]))then Exit(FileFor(A.Objects[I]));
  finally D.Free end;
 except { Keep the already downloaded file if an optional sidecar is damaged. }end;
end;
function TReadyRoutes.FindFile(const FileName:string):TJSONObject;
var A:TJSONArray;I:Integer;
begin Result:=nil;A:=FCatalog.Arrays['items'];for I:=0 to A.Count-1 do if SameFileName(FileFor(A.Objects[I]),FileName)then Exit(A.Objects[I])end;
function TReadyRoutes.Title(const FileName:string):string;
var O:TJSONObject;
begin Result:=ChangeFileExt(ExtractFileName(FileName),'');O:=FindFile(FileName);if O=nil then Exit;
 Result:=O.Get('title','');if(CurrentAppliedLanguage<>'ru')and(O.Get('title_en','')<>'')then Result:=O.Get('title_en','')end;
function TReadyRoutes.Identity(const FileName:string;out Id,SHA:string):Boolean;
var O:TJSONObject;
begin Id:='';SHA:='';O:=FindFile(FileName);Result:=O<>nil;if Result then begin Id:=O.Get('id','');SHA:=O.Get('sha256','')end end;
function TReadyRoutes.Diagnostics:TJSONObject;
begin Result:=TJSONObject.Create(['generation',FGeneration,'busy',FTask<>nil,'error',FError,'revision',FCatalog.Get('revision','')]);Result.Add('items',FCatalog.Arrays['items'].Clone)end;
finalization
 FreeAndNil(Instance);
end.
