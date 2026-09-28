unit GameClientUpdate;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses Classes,SysUtils,fpjson,CastleUIControls;
procedure InitializeClientUpdates(Container:TCastleContainer;const ApiBase:String);
procedure ShutdownClientUpdates;
procedure ShowClientUpdates(Sender:TObject);
function ClientCanStartRide:Boolean;
function ClientVersionInfo:TJSONObject;

implementation
uses SyncObjs,jsonparser,CastleControls,CastleVectors,CastleColors,CastleKeysMouse,
  CastleApplicationProperties,CastleWindow,CastleOpenDocument,GameMenuTheme,
  UiTranslations,GameBuildInfo,GameHttpClient,GameCrashReports,GameViewMenu,
  GameViewPlay,GameViewTrainingOnly,GameUpdateDownload{$IFDEF WINDOWS},Windows,ShellApi{$ENDIF};
type
  TVersionTask=class(TThread)
  public
    Done:TEvent;
    Base,Response,ManifestSHA256:String;
    Cancellation:TGameHttpCancellation;
    constructor Create(const ApiBase:String);
    destructor Destroy;override;
    procedure Execute;override;
  end;
  TUpdateDialog=class(TCastleRectangleControl)
    function Press(const Event:TInputPressRelease):Boolean;override;
    function Release(const Event:TInputPressRelease):Boolean;override;
    function Motion(const Event:TInputMotion):Boolean;override;
  end;
  TClientUpdates=class
  private
    FTask:TVersionTask;
    FTransfer:TUpdateDownload;
    FPackage:TUpdatePackage;
    FPendingPackage:TUpdatePackage;
    FHasPendingPackage:Boolean;
    FPackageKnown,FInstallRequested,FOfflineAllowed:Boolean;
    FBlockReason:String;
    FInstalledManifestSHA256:String;
    FLastRefresh:QWord;
    FContainer:TCastleContainer;
    FBase,FLatest:String;
    FBlocked,FNewVersion,FKnown,FOffered,FCheckFailed:Boolean;
    FDialog:TUpdateDialog;
    FStatus:TCastleLabel;
    FClose,FDownload,FCheck,FFeedback:TMenuButton;
    FLastCheck:QWord;
    procedure Tick(Sender:TObject);
    procedure Refresh;
    procedure Check(Sender:TObject);
    procedure Close(Sender:TObject);
    procedure Download(Sender:TObject);
    procedure Feedback(Sender:TObject);
    procedure Quit(Sender:TObject);
    function ApplyResponse(const Value:String):Boolean;
    procedure SaveCache(const Text:String);
    procedure InstallReady;
  public
    constructor Create(Container:TCastleContainer;const ApiBase:String);
    destructor Destroy;override;
    procedure Show;
  end;
var Updates:TClientUpdates;

constructor TVersionTask.Create(const ApiBase:String);
begin inherited Create(True);FreeOnTerminate:=False;Base:=ApiBase;Done:=TEvent.Create(nil,True,False,'');Cancellation:=TGameHttpCancellation.Create;Start;end;
destructor TVersionTask.Destroy;
begin Cancellation.Cancel;WaitFor;Cancellation.Free;Done.Free;inherited;end;
procedure TVersionTask.Execute;
var Reply:TStringStream;Headers:TStringList;Status:Integer;Manifest:String;
begin
  Reply:=TStringStream.Create('');Headers:=TStringList.Create;
  try
    try
      Headers.Add('User-Agent: '+ClientUserAgent);
      GameHttpRequest('GET',ExcludeTrailingPathDelimiter(Base)+'/api/v1/client/version?build='+IntToStr(ClientBuild),
        Headers,nil,2000,4000,Reply,Status,Cancellation);
      if(Status=200)and(Reply.Size<65536)then Response:=Reply.DataString;
      Manifest:=ExtractFilePath(ParamStr(0))+'installed-files.json';
      if FileExists(Manifest)then ManifestSHA256:=UpdateSHA256(Manifest,Cancellation);
    except { Optional updates must not prevent offline use. } end;
  finally Headers.Free;Reply.Free;Done.SetEvent;end;
end;
function TUpdateDialog.Press(const Event:TInputPressRelease):Boolean;
begin inherited;Result:=True;end;
function TUpdateDialog.Release(const Event:TInputPressRelease):Boolean;
begin inherited;Result:=True;end;
function TUpdateDialog.Motion(const Event:TInputMotion):Boolean;
begin inherited;Result:=True;end;

constructor TClientUpdates.Create(Container:TCastleContainer;const ApiBase:String);
var Panel:TMenuPanel;Title,VersionLabel:TCastleLabel;B:TMenuButton;F:TStringList;
  function Button(const Name,Caption:String;X,Y:Single;Handler:TNotifyEvent):TMenuButton;
  begin
    Result:=TMenuButton.Create(FDialog);Result.Name:=Name;Result.AutoIcon:=False;BindUiText(Result,Caption);
    Result.FontSize:=17;Result.Anchor(hpLeft,X);Result.Anchor(vpBottom,Y);Result.OnClick:=Handler;Panel.InsertFront(Result);
  end;
begin
  inherited Create;FContainer:=Container;FBase:=ApiBase;
  FDialog:=TUpdateDialog.Create(nil);FDialog.FullSize:=True;FDialog.Color:=Vector4(0.01,0.025,0.04,0.92);FDialog.Exists:=False;
  Panel:=TMenuPanel.Create(FDialog);Panel.Width:=650;Panel.Height:=440;Panel.Anchor(hpMiddle);Panel.Anchor(vpMiddle);FDialog.InsertFront(Panel);
  Title:=TMenuLabel.Create(FDialog);Title.Caption:='REZVIVO';Title.FontSize:=30;Title.Color:=MenuText;Title.Anchor(hpLeft,24);Title.Anchor(vpTop,-24);Panel.InsertFront(Title);
  VersionLabel:=TMenuLabel.Create(FDialog);VersionLabel.Caption:=ClientVersion;VersionLabel.FontSize:=18;VersionLabel.Color:=MenuMuted;VersionLabel.Anchor(hpLeft,24);VersionLabel.Anchor(vpTop,-70);Panel.InsertFront(VersionLabel);
  FStatus:=TMenuLabel.Create(FDialog);FStatus.Name:='ClientVersionStatus';FStatus.FontSize:=18;FStatus.MaxWidth:=600;FStatus.Color:=MenuText;FStatus.Anchor(hpLeft,24);FStatus.Anchor(vpTop,-105);Panel.InsertFront(FStatus);
  FDownload:=Button('ClientDownload','Download update',24,165,@Download);FDownload.Style:=mbPrimary;
  FCheck:=Button('ClientCheck','Check for updates',24,77,@Check);
  FFeedback:=Button('ClientFeedback','Send feedback',320,77,@Feedback);
  FClose:=Button('ClientUpdateClose','Close',24,24,@Close);
  B:=Button('ClientUpdateQuit','Close game',320,24,@Quit);B.Style:=mbGhost;
  FContainer.Controls.InsertFront(FDialog);
  F:=TStringList.Create;
  try
    try
      if FileExists(ClientDiagnosticsDir+'version-policy.json')then begin F.LoadFromFile(ClientDiagnosticsDir+'version-policy.json');ApplyResponse(F.Text);end;
    except end;
  finally F.Free;end;
  ApplicationProperties.OnUpdate.Add(@Tick);Check(nil);
end;
destructor TClientUpdates.Destroy;
begin
  ApplicationProperties.OnUpdate.Remove(@Tick);
  FTransfer.Free;FTask.Free;FContainer.Controls.Remove(FDialog);FDialog.Free;inherited;
end;
procedure TClientUpdates.Check(Sender:TObject);
begin if FTask<>nil then Exit;FLastCheck:=GetTickCount64;FTask:=TVersionTask.Create(FBase);Refresh;end;
function TClientUpdates.ApplyResponse(const Value:String):Boolean;
var J:TJSONData;O,L:TJSONObject;D:TJSONData;Package:TUpdatePackage;
  Blocked,NewVersion,OfflineAllowed,PackageKnown:Boolean;Latest,Reason:String;
begin
  Result:=False;J:=nil;
  try
   try
    J:=GetJSON(Value);if not(J is TJSONObject)then Exit;O:=TJSONObject(J);
    { A policy belongs to a specific build. Never inherit an old build's block
      after installing an update, or treat an invalid response as permission. }
    if O.Get('current_build',-1)<>ClientBuild then Exit;
    D:=O.Find('allowed');if(D=nil)or(D.JSONType<>jtBoolean)then Exit;
    Blocked:=not D.AsBoolean;NewVersion:=O.Get('update_available',False);Latest:='';
    OfflineAllowed:=O.Get('offline_allowed',False);
    Reason:=O.Get('reason','');
    D:=O.Find('latest');PackageKnown:=False;
    if D is TJSONObject then begin
      L:=TJSONObject(D);Latest:=L.Get('version','');
      PackageKnown:=ParseUpdatePackage(L,FBase,Package,FInstalledManifestSHA256);
    end;
    { Commit only a fully parsed policy, preserving the last known restriction
      when a response is malformed halfway through its fields. }
    FBlocked:=Blocked;FNewVersion:=NewVersion;FLatest:=Latest;
    FOfflineAllowed:=OfflineAllowed;FBlockReason:=Reason;
    FPackageKnown:=PackageKnown;FHasPendingPackage:=False;
    if PackageKnown then begin
        { A changing release must not install a completed older transfer. }
        if(FTransfer<>nil)and(FPackage.SHA256<>Package.SHA256)then begin
          FTransfer.Pause;FInstallRequested:=False;
          if FTransfer.Done.WaitFor(0)=wrSignaled then FreeAndNil(FTransfer)
          else begin
            FPackageKnown:=False;FPendingPackage:=Package;FHasPendingPackage:=True;
          end;
        end;
        if FPackageKnown then FPackage:=Package;
    end else FInstallRequested:=False;
    FKnown:=True;Result:=True;
   except Result:=False;end;
  finally J.Free;end;
end;
procedure TClientUpdates.SaveCache(const Text:String);
var F:TStringList;
begin
  F:=TStringList.Create;
  try
    try ForceDirectories(ClientDiagnosticsDir);F.Text:=Text;F.SaveToFile(ClientDiagnosticsDir+'version-policy.json');except end;
  finally F.Free;end;
end;
procedure TClientUpdates.Refresh;
var S:TUpdateDownloadStatus;Caption:String;Riding:Boolean;
begin
  Riding:=((ViewPlay<>nil)and ViewPlay.SessionAlive)or
    ((ViewTrainingOnly<>nil)and ViewTrainingOnly.SessionAlive);
  if FBlocked then FStatus.Caption:=UiText('This version requires an update to continue.')
  else if FTask<>nil then FStatus.Caption:=UiText('Checking for updates...')
  else if FNewVersion then FStatus.Caption:=UiText('New version available: ')+FLatest
  else if FKnown and not FCheckFailed then FStatus.Caption:=UiText('The installed version is up to date.')
  else FStatus.Caption:=UiText('Could not check for updates. You can continue offline.');
  if FBlocked and(FBlockReason<>'')then FStatus.Caption:=FStatus.Caption+#10+UiText(FBlockReason);
  if FBlocked and FOfflineAllowed then FStatus.Caption:=FStatus.Caption+#10+UiText('Offline rides remain available.');
  if FPackageKnown and(FNewVersion or FBlocked)then
    FStatus.Caption:=FStatus.Caption+#10+UiText('Download size: ')+Format('%.1f MiB',[FPackage.SizeBytes/1048576.0]);
  Caption:='Download update';FDownload.Enabled:=True;
  if FTransfer<>nil then begin
    S:=FTransfer.Status;
    case S.State of
      udsDownloading:begin Caption:='Pause download';FStatus.Caption:=FStatus.Caption+#10+UiText('Downloading update: ')+Format('%.1f / %.1f MiB',[S.Received/1048576.0,S.Total/1048576.0]);end;
      udsVerifying:begin Caption:='Pause download';FStatus.Caption:=FStatus.Caption+#10+UiText('Verifying update integrity...');end;
      udsReady:begin
        Caption:='Install update';FDownload.Enabled:=not Riding;
        if FPackage.InstallerProtocol<>1 then Caption:='Open download page';
        if Riding then FStatus.Caption:=FStatus.Caption+#10+UiText('Update ready. Finish the ride to install.')
        else FStatus.Caption:=FStatus.Caption+#10+UiText('Update ready. Installation closes the game.');
      end;
      udsPaused:begin Caption:='Resume download';FStatus.Caption:=FStatus.Caption+#10+UiText('Download paused. Progress is saved.');end;
      udsFailed:begin Caption:='Retry download';FStatus.Caption:=FStatus.Caption+#10+UiText('Could not download update: ')+S.ErrorText;end;
    end;
  end;
  BindUiText(FDownload,Caption);
  FClose.Exists:=True;FDownload.Exists:=FNewVersion or FBlocked or(FTransfer<>nil);FCheck.Enabled:=FTask=nil;
end;
procedure TClientUpdates.Tick(Sender:TObject);
begin
  if(FTask<>nil)and(FTask.Done.WaitFor(0)=wrSignaled)then begin
    FInstalledManifestSHA256:=FTask.ManifestSHA256;
    FCheckFailed:=not ApplyResponse(FTask.Response);
    if not FCheckFailed then SaveCache(FTask.Response);
    FreeAndNil(FTask);Refresh;
  end;
  if FHasPendingPackage and(FTransfer<>nil)and(FTransfer.Done.WaitFor(0)=wrSignaled)then begin
    FreeAndNil(FTransfer);FPackage:=FPendingPackage;FPackageKnown:=True;
    FHasPendingPackage:=False;Refresh;
  end;
  { A menu over the live ride is still a ride; do not cover it or install there. }
  if not(((ViewPlay<>nil)and ViewPlay.SessionAlive)or
    ((ViewTrainingOnly<>nil)and ViewTrainingOnly.SessionAlive))then begin
    if FBlocked and not FOffered then begin FOffered:=True;Show;end
    else if FNewVersion and not FOffered and(ViewMenu<>nil)and ViewMenu.Active then begin FOffered:=True;Show;end;
  end;
  if(FTransfer<>nil)and(GetTickCount64-FLastRefresh>=250)then begin
    FLastRefresh:=GetTickCount64;Refresh;
    if FInstallRequested and(FTransfer.Done.WaitFor(0)=wrSignaled)then begin
      FInstallRequested:=False;
      if FTransfer.Status.State=udsReady then InstallReady;
    end;
  end;
  if(FTask=nil)and(GetTickCount64-FLastCheck>30*60*1000)and(ViewMenu<>nil)and ViewMenu.Active then Check(nil);
end;
procedure TClientUpdates.Show;
begin Refresh;FDialog.Exists:=True;end;
procedure TClientUpdates.Close(Sender:TObject);
begin FDialog.Exists:=False;end;
procedure TClientUpdates.Download(Sender:TObject);
var S:TUpdateDownloadStatus;
begin
  if not FPackageKnown then begin OpenUrl(ExcludeTrailingPathDelimiter(FBase)+'/download?build='+IntToStr(ClientBuild));Exit end;
  if FTransfer<>nil then begin
    S:=FTransfer.Status;
    if FTransfer.Done.WaitFor(0)<>wrSignaled then begin FTransfer.Pause;FInstallRequested:=False;Exit end;
    if S.State=udsReady then begin
      if FPackage.InstallerProtocol<>1 then begin OpenUrl(ExcludeTrailingPathDelimiter(FBase)+'/download?build='+IntToStr(ClientBuild));Exit end;
      if((ViewPlay<>nil)and ViewPlay.SessionAlive)or
        ((ViewTrainingOnly<>nil)and ViewTrainingOnly.SessionAlive)then Exit;
      { Recheck cached bytes on the worker immediately before installation. }
      FInstallRequested:=True;
    end;
    FreeAndNil(FTransfer);
  end;
  FTransfer:=TUpdateDownload.Create(FPackage,ClientDiagnosticsDir+'updates');Refresh;
end;
procedure TClientUpdates.InstallReady;
{$IFDEF WINDOWS}
var Filename,Args:WideString;Started:PtrInt;
{$ENDIF}
begin
  if((ViewPlay<>nil)and ViewPlay.SessionAlive)or
    ((ViewTrainingOnly<>nil)and ViewTrainingOnly.SessionAlive)then begin Refresh;Exit end;
  if not FPackageKnown or(FTransfer=nil)or(FTransfer.Status.State<>udsReady)then Exit;
  {$IFDEF WINDOWS}
  Filename:=UTF8Decode(FTransfer.Status.Filename);
  Args:='/WAITPID='+IntToStr(GetCurrentProcessId);
  if SameText(ExtractFileName(ParamStr(0)),'REZVIVO.exe')then
    Args:=Args+' /D='+UTF8Decode(ExcludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))));
  Started:=PtrInt(ShellExecuteW(0,'open',PWideChar(Filename),PWideChar(Args),nil,SW_SHOWNORMAL));
  if Started>32 then Application.Terminate
  else FStatus.Caption:=UiText('Could not start the update installer.');
  {$ENDIF}
end;
procedure TClientUpdates.Feedback(Sender:TObject);
begin OpenUrl(ExcludeTrailingPathDelimiter(FBase)+'/feedback?build='+IntToStr(ClientBuild));end;
procedure TClientUpdates.Quit(Sender:TObject);
begin Application.Terminate;end;
procedure InitializeClientUpdates(Container:TCastleContainer;const ApiBase:String);
begin if Updates=nil then Updates:=TClientUpdates.Create(Container,ApiBase);end;
procedure ShutdownClientUpdates;
begin FreeAndNil(Updates);end;
procedure ShowClientUpdates(Sender:TObject);
begin if Updates<>nil then Updates.Show;end;
function ClientCanStartRide:Boolean;
begin
  Result:=(Updates=nil)or not Updates.FBlocked or Updates.FOfflineAllowed;
  if not Result then Updates.Show;
end;
function ClientVersionInfo:TJSONObject;
begin
  Result:=TJSONObject.Create(['version',ClientVersion,'build',ClientBuild]);
  if Updates<>nil then begin
    Result.Add('checking',Updates.FTask<>nil);Result.Add('known',Updates.FKnown);
    Result.Add('allowed',not Updates.FBlocked);Result.Add('update_available',Updates.FNewVersion);Result.Add('latest',Updates.FLatest);
    Result.Add('dialog_visible',Updates.FDialog.Exists);Result.Add('status',Updates.FStatus.Caption);
    Result.Add('download_available',Updates.FPackageKnown);
    Result.Add('package_kind',Updates.FPackage.Kind);
    Result.Add('changed_program_bytes',Updates.FPackage.ProgramBytes);
    Result.Add('changed_resource_bytes',Updates.FPackage.ResourceBytes);
    Result.Add('offline_allowed',Updates.FOfflineAllowed);
    if Updates.FTransfer<>nil then begin
      Result.Add('download_state',Ord(Updates.FTransfer.Status.State));
      Result.Add('downloaded_bytes',Updates.FTransfer.Status.Received);
      Result.Add('download_bytes',Updates.FTransfer.Status.Total);
    end;
  end;
end;
end.
