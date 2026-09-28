unit GameViewConnectors;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses GameMenuTheme, Classes, SysUtils, CastleUIControls, CastleControls, GameMenuTile,
  GameRouteLibraryData;
type
  TConnectorsPage=class(TMenuEmbeddedPage)
  private
    FStatus,FProgress,FUpload,FError:TCastleLabel;
    FKey:TCastleEdit;
    FConnect,FSync,FDisconnect:TCastleButton;
    FTask:TRouteTask;
    FUserId:Int64;
    FPoll:Single;
    FConnected:Boolean;
    procedure ClickConnect(Sender:TObject);
    procedure ClickSync(Sender:TObject);
    procedure ClickDisconnect(Sender:TObject);
    procedure ClickSettings(Sender:TObject);
    procedure Request(const Method,Path,Body:String);
    procedure Refresh;
    procedure ApplyState;
  public
    constructor Create(AOwner:TComponent);override;
    destructor Destroy;override;
    procedure PageShown;override;
    procedure PageHidden;override;
    procedure Update(const SecondsPassed:Single;var HandleInput:Boolean);override;
  end;
implementation
uses GameWorkoutSchedule, UiTranslations, fpjson, CastleVectors, CastleURIUtils, CastleOpenDocument, VeloSiteAPI;

constructor TConnectorsPage.Create(AOwner:TComponent);
var Col:TCastleVerticalGroup;Row:TCastleHorizontalGroup;L:TCastleLabel;B:TCastleButton;Background:TCastleRectangleControl;
  function LabelText(const S:String;Size:Single):TCastleLabel;
  begin Result:=TMenuLabel.Create(Self);BindUiText(Result, S);Result.FontSize:=Size;
    Result.Color:=Vector4(0.88,0.92,0.97,1);Result.MaxWidth:=740;Col.InsertFront(Result);end;
  function ButtonText(const S:String;Click:TNotifyEvent):TCastleButton;
  begin Result:=TMenuButton.Create(Self);BindUiText(Result, S);Result.FontSize:=16;
    Result.OnClick:=Click;Row.InsertFront(Result);end;
begin
  inherited;FullSize:=True;
  Background:=TCastleRectangleControl.Create(Self);Background.FullSize:=True;Background.Color:=MenuBackground;InsertBack(Background);
  Col:=TCastleVerticalGroup.Create(Self);Col.Spacing:=18;Col.Anchor(hpLeft,20);Col.Anchor(vpTop,-24);InsertFront(Col);
  L:=LabelText('Intervals.icu',23);
  L:=LabelText(UiText('Connect Intervals.icu for routes, training schedule and smart-trainer uploads.'),16);
  FStatus:=LabelText(UiText('Sign in to REZVIVO to connect a service.'),18);
  L:=LabelText(UiText('Personal API key'),16);
  FKey:=TMenuEdit.Create(Self);FKey.Name:='ConnectorApiKey';FKey.Text:='';FKey.Width:=480;FKey.PasswordChar:='*';Col.InsertFront(FKey);
  Row:=TCastleHorizontalGroup.Create(Self);Row.Spacing:=10;Col.InsertFront(Row);
  FConnect:=ButtonText(UiText('Connect'),@ClickConnect);
  FSync:=ButtonText(UiText('Synchronize'),@ClickSync);
  FDisconnect:=ButtonText(UiText('Disconnect'),@ClickDisconnect);
  B:=ButtonText(UiText('Where to get the key'),@ClickSettings);
  FUpload:=LabelText('',16);FUpload.Name:='IntervalsUploadStatus';
  FProgress:=LabelText('',16);FError:=LabelText('',16);FError.Color:=Vector4(1,0.48,0.48,1);
  L:=LabelText(UiText('Import starts with your latest rides and continues in the background.')+LineEnding+
    UiText('Files without GPS are skipped. Disconnecting does not remove imported routes.'),16);
  FSync.Exists:=False;FDisconnect.Exists:=False;
end;
destructor TConnectorsPage.Destroy;
begin RouteDetach(FTask);inherited;end;
procedure TConnectorsPage.PageShown;
begin inherited;FUserId:=VeloSite.CachedProfile.Id;FPoll:=0;Refresh;end;
procedure TConnectorsPage.PageHidden;
begin inherited;RouteDetach(FTask);FKey.Text:='';end;
procedure TConnectorsPage.Request(const Method,Path,Body:String);
begin
  if FTask<>nil then Exit;
  if(FUserId<=0)or(not VeloSite.IsAuthorized)then begin BindUiText(FStatus, 'Sign in to REZVIVO to connect a service.');Exit;end;
  FTask:=TRouteTask.Create(FUserId,Method,Path,Body);FTask.Start;
  FConnect.Enabled:=False;FSync.Enabled:=False;FDisconnect.Enabled:=False;
end;
procedure TConnectorsPage.Refresh;
begin Request('GET','/connectors','');end;
procedure TConnectorsPage.ClickConnect(Sender:TObject);
var O:TJSONObject;
begin
  if Trim(FKey.Text)='' then begin BindUiText(FError, 'Enter the key from Settings → Developer Settings on Intervals.icu');Exit;end;
  O:=TJSONObject.Create(['api_key',Trim(FKey.Text)]);
  try FError.Caption:='';Request('POST','/connectors/intervals/key',O.AsJSON);finally O.Free;end;
  FKey.Text:='';BindUiText(FStatus, 'Checking key…');
end;
procedure TConnectorsPage.ClickSync(Sender:TObject);
begin FError.Caption:='';Request('POST','/connectors/intervals/sync','{}');end;
procedure TConnectorsPage.ClickDisconnect(Sender:TObject);
begin FError.Caption:='';Request('DELETE','/connectors/intervals','{}');end;
procedure TConnectorsPage.ClickSettings(Sender:TObject);
begin OpenDocument('https://intervals.icu/settings');end;
procedure TConnectorsPage.ApplyState;
var O,S,J:TJSONObject;A:TJSONArray;D:TJSONData;Text,Stage:String;
begin
  if not(FTask.Response is TJSONObject)then Exit;
  O:=TJSONObject(FTask.Response);D:=O.Find('items');if not(D is TJSONArray)then Exit;A:=TJSONArray(D);if A.Count=0 then Exit;
  S:=TJSONObject(A[0]);FConnected:=S.Get('connected',False);
  FConnect.Exists:=not FConnected;FKey.Exists:=not FConnected;FSync.Exists:=FConnected;FDisconnect.Exists:=FConnected;
  if FConnected then FStatus.Caption:=UiText('Connected · ')+S.Get('name','Intervals') else BindUiText(FStatus, 'Intervals is not connected');
  BindUiText(FUpload,'Completed smart-trainer rides upload automatically. Simulations are excluded.');
  if FConnected and(S.Find('can_upload')<>nil)and not S.Get('can_upload',False)then
    BindUiText(FUpload,'Upload permission is missing. Reconnect Intervals.icu.');
  D:=S.Find('upload_job');
  if FConnected and(D is TJSONObject)then begin
    J:=TJSONObject(D);Stage:=J.Get('status','');
    if Stage='done'then begin
      if J.Get('processed',Int64(0))>0 then Text:=UiText('Last ride uploaded to Intervals.icu')
      else Text:=UiText('Ride upload cancelled');
    end else if Stage='failed'then Text:=UiText('Ride upload failed. Reconnect Intervals.icu to retry.')
    else if Stage='cancelled'then Text:=UiText('Ride upload cancelled')
    else Text:=UiText('Ride queued for Intervals.icu. Upload runs in the background.');
    FUpload.Caption:=FUpload.Caption+LineEnding+Text;
  end;
  FProgress.Caption:='';D:=S.Find('job');
  if D is TJSONObject then begin J:=TJSONObject(D);Stage:=J.Get('status','');
    if Stage='done'then Text:=UiText('Import completed') else if Stage='failed'then Text:=UiText('Import stopped') else
    if Stage='retry'then Text:=UiText('Waiting to retry') else if Stage='cancelled'then Text:=UiText('Import cancelled') else Text:=UiText('Import in progress');
    FProgress.Caption:=Text+UiText(' · Imported: ')+IntToStr(J.Get('processed',Int64(0)))+
      UiText(', skipped: ')+IntToStr(J.Get('skipped',Int64(0)));
    if J.Get('error','')<>''then FProgress.Caption:=FProgress.Caption+LineEnding+J.Get('error','');
    FSync.Enabled:=(Stage='done')or(Stage='failed')or(Stage='cancelled');
  end;
end;
procedure TConnectorsPage.Update(const SecondsPassed:Single;var HandleInput:Boolean);
var WasRead:Boolean;
begin
  inherited;
  if FUserId<>VeloSite.CachedProfile.Id then begin RouteDetach(FTask);FUserId:=VeloSite.CachedProfile.Id;FKey.Text:='';FStatus.Caption:='';FProgress.Caption:='';FUpload.Caption:='';FError.Caption:='';Refresh;end;
  if(FTask<>nil)and FTask.Done then
  begin
    FConnect.Enabled:=True;FSync.Enabled:=True;FDisconnect.Enabled:=True;
    WasRead:=FTask.Method='GET';
    if FTask.ErrorText<>''then FError.Caption:=FTask.ErrorText else if WasRead then ApplyState;
    if not WasRead and(FTask.ErrorText='')then WorkoutSchedule.ConnectionChanged;
    FreeAndNil(FTask);FPoll:=0;if not WasRead then Refresh;
  end;
  FPoll:=FPoll+SecondsPassed;if FPoll>5 then begin FPoll:=0;Refresh;end;
end;
end.
