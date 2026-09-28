unit GameViewRouteLibrary;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses GameMenuTheme, Classes,SysUtils,fpjson,CastleUIControls,CastleControls,GameMenuTile,
  GameRouteLibraryData,GameRouteMap;
type
  TRouteLibraryPage=class(TMenuEmbeddedPage)
  private
    FTask:TRouteTask;
    FUserId:Int64;
    FShared,FMapShown,FMore,FAppend,FFitMap:Boolean;
    FOffset:Integer;
    FSort,FDirection:String;
    FItems:TJSONArray;
    FSelected:Int64;
    FStatus,FDetails:TCastleLabel;
    FList:TCastleVerticalGroup;
    FScroll:TCastleScrollView;
    FHeaders,FActions:TCastleHorizontalGroup;
    FOwn,FCommunity,FMapButton,FMoreButton,FFavorite,FShare,FDownload,FAdd,FEdit,FDelete:TCastleButton;
    FQuery,FAfter,FBefore,FDistMin,FDistMax,FGainMin,FGainMax:TCastleEdit;
    FOnlyFavorites:TCastleCheckbox;
    FMap:TRouteMap;
    FAttribution:TCastleButton;
    FEditPanel:TCastleRectangleControl;
    FTitleEdit,FDescriptionEdit:TCastleEdit;
    FPoll:Single;
    FPendingRefresh:Boolean;
    FToolbar,FSearchBar,FFilterBar,FDateBar:TMenuFlow;
    FFilterDelay,FLayoutWidth:Single;
    FStartAfterAdd:Boolean;
    FStartRouteId:Int64;
    FStartRouteDelay:Single;
    procedure FilterEdited(Sender:TObject);
    procedure ClickFilters(Sender:TObject);
    procedure StartRequest(const Method,Path,Body:String);
    procedure Load(More:Boolean=False);
    function Query:String;
    function Current:TJSONObject;
    procedure RenderItems;
    procedure UpdateSelection;
    procedure Layout;
    procedure SetBusy(Value:Boolean);
    procedure ClickOwn(Sender:TObject);
    procedure ClickCommunity(Sender:TObject);
    procedure ClickMap(Sender:TObject);
    procedure ClickRefresh(Sender:TObject);
    procedure ClickMore(Sender:TObject);
    procedure ClickSort(Sender:TObject);
    procedure ClickRow(Sender:TObject);
    procedure ClickFavorite(Sender:TObject);
    procedure ClickShare(Sender:TObject);
    procedure ClickAdd(Sender:TObject);
    procedure ClickDownload(Sender:TObject);
    procedure ClickEdit(Sender:TObject);
    procedure ClickSave(Sender:TObject);
    procedure ClickCancel(Sender:TObject);
    procedure ClickDelete(Sender:TObject);
    procedure ClickBack(Sender:TObject);
    procedure ClickCreate(Sender:TObject);
    procedure ClickUpload(Sender:TObject);
    procedure ClickAttribution(Sender:TObject);
    procedure MapChanged(Sender:TObject);
    procedure MapSelected(Sender:TObject);
    procedure Patch(const Key:String;Value:Boolean);
  public
    constructor Create(AOwner:TComponent);override;
    destructor Destroy;override;
    procedure PageShown;override;
    procedure PageHidden;override;
    procedure Update(const SecondsPassed:Single;var HandleInput:Boolean);override;
  end;
implementation
uses UiTranslations, Math,CastleVectors,CastleURIUtils,CastleWindow,CastleOpenDocument,
  VeloSiteAPI,GameViewMenu;

procedure TRouteLibraryPage.ClickCreate(Sender:TObject);
begin ViewMenu.OpenTab('route-create');end;

constructor TRouteLibraryPage.Create(AOwner:TComponent);
var Row:TCastleUserInterface;L:TCastleLabel;B:TCastleButton;Col:TCastleVerticalGroup;Background:TCastleRectangleControl;
  function ButtonText(const S:String;Click:TNotifyEvent):TCastleButton;
  begin Result:=TMenuButton.Create(Self);BindUiText(Result, S);Result.FontSize:=14;Result.OnClick:=Click;Row.InsertFront(Result);end;
  function EditText(const Caption:String;W:Single):TCastleEdit;
  var C:TCastleVerticalGroup;Lab:TCastleLabel;
  begin C:=TCastleVerticalGroup.Create(Self);C.Spacing:=3;Row.InsertFront(C);
    Lab:=TMenuLabel.Create(Self);BindUiText(Lab, Caption);Lab.FontSize:=13;Lab.Color:=Vector4(0.86,0.9,0.94,1);C.InsertFront(Lab);
    Result:=TMenuEdit.Create(Self);Result.Width:=W;C.InsertFront(Result);end;
begin
  inherited;FullSize:=True;FItems:=TJSONArray.Create;FSort:='date';FDirection:='desc';FFitMap:=True;
  Background:=TCastleRectangleControl.Create(Self);Background.FullSize:=True;Background.Color:=MenuBackground;InsertBack(Background);
  FToolbar:=TMenuFlow.Create(Self);FToolbar.Spacing:=8;Row:=FToolbar;InsertFront(Row);
  B:=ButtonText(UiText('On this computer'),@ClickBack);FOwn:=ButtonText(UiText('My routes'),@ClickOwn);FCommunity:=ButtonText(UiText('Community'),@ClickCommunity);
  FMapButton:=ButtonText(UiText('Map'),@ClickMap);B:=ButtonText(UiText('Create'),@ClickCreate);B:=ButtonText(UiText('Add FIT / GPX'),@ClickUpload);
  FSearchBar:=TMenuFlow.Create(Self);FSearchBar.Spacing:=8;Row:=FSearchBar;InsertFront(Row);
  FQuery:=EditText(UiText('Search routes'),280);FQuery.OnChange:=@FilterEdited;
  FOnlyFavorites:=TCastleCheckbox.Create(Self);BindUiText(FOnlyFavorites, 'Favorites only ♥');FOnlyFavorites.FontSize:=14;FOnlyFavorites.TextColor:=Vector4(0.9,0.93,0.97,1);FOnlyFavorites.CheckboxColor:=Vector4(0.8,0.85,0.9,1);Row.InsertFront(FOnlyFavorites);
  FOnlyFavorites.OnChange:=@FilterEdited;B:=ButtonText(UiText('Filters'),@ClickFilters);
  FFilterBar:=TMenuFlow.Create(Self);FFilterBar.Spacing:=8;FFilterBar.Exists:=False;Row:=FFilterBar;InsertFront(Row);
  FDistMin:=EditText(UiText('Min distance, km'),120);FDistMax:=EditText(UiText('Max, km'),120);FGainMin:=EditText(UiText('Min ascent, m'),120);FGainMax:=EditText(UiText('Max, m'),120);
  FDistMin.OnChange:=@FilterEdited;FDistMax.OnChange:=@FilterEdited;FGainMin.OnChange:=@FilterEdited;FGainMax.OnChange:=@FilterEdited;
  FDateBar:=TMenuFlow.Create(Self);FDateBar.Spacing:=8;FDateBar.Exists:=False;Row:=FDateBar;InsertFront(Row);
  FAfter:=EditText(UiText('From: YYYY-MM-DD'),145);FBefore:=EditText(UiText('Until'),145);FAfter.OnChange:=@FilterEdited;FBefore.OnChange:=@FilterEdited;
  Row:=FToolbar;FMoreButton:=ButtonText(UiText('More'),@ClickMore);FMoreButton.Exists:=False;
  FStatus:=TMenuLabel.Create(Self);FStatus.FontSize:=14;FStatus.Color:=Vector4(0.8,0.88,0.95,1);FStatus.Anchor(hpLeft,8);FStatus.Anchor(vpTop,-178);InsertFront(FStatus);
  FMap:=TRouteMap.Create(Self);FMap.WidthFraction:=1;FMap.Height:=250;FMap.Anchor(hpLeft);FMap.Anchor(vpTop,-205);FMap.OnChanged:=@MapChanged;FMap.OnSelect:=@MapSelected;FMap.Exists:=False;InsertFront(FMap);
  FAttribution:=TMenuButton.Create(Self);BindUiText(FAttribution, '© OpenStreetMap contributors · Natural Earth · Copernicus DEM');FAttribution.FontSize:=11;FAttribution.Anchor(hpRight,-6);FAttribution.Anchor(vpTop,-431);FAttribution.OnClick:=@ClickAttribution;FAttribution.Exists:=False;InsertFront(FAttribution);
  FScroll:=TMenuScrollView.Create(Self);FScroll.FullSize:=True;FScroll.Border.Left:=8;FScroll.Border.Right:=8;FScroll.Border.Bottom:=108;InsertFront(FScroll);
  FList:=TCastleVerticalGroup.Create(Self);FList.Spacing:=3;FList.Anchor(hpLeft);FList.Anchor(vpTop);FScroll.ScrollArea.InsertFront(FList);
  FHeaders:=TCastleHorizontalGroup.Create(Self);FHeaders.Spacing:=4;FHeaders.Anchor(hpLeft,8);InsertFront(FHeaders);Row:=FHeaders;
  B:=ButtonText(UiText('Route ↕'),@ClickSort);B.Tag:=0;B:=ButtonText(UiText('Date ↕'),@ClickSort);B.Tag:=1;
  B:=ButtonText(UiText('Distance ↕'),@ClickSort);B.Tag:=2;B:=ButtonText(UiText('Ascent ↕'),@ClickSort);B.Tag:=3;B:=ButtonText(UiText('Author ↕'),@ClickSort);B.Tag:=4;
  B:=ButtonText(UiText('Source ↕'),@ClickSort);B.Tag:=5;
  FDetails:=TMenuLabel.Create(Self);FDetails.FontSize:=14;FDetails.Color:=Vector4(0.9,0.93,0.97,1);FDetails.Anchor(hpLeft,8);FDetails.Anchor(vpBottom,54);InsertFront(FDetails);
  FActions:=TCastleHorizontalGroup.Create(Self);FActions.Spacing:=6;FActions.Anchor(hpLeft,8);FActions.Anchor(vpBottom,8);InsertFront(FActions);Row:=FActions;
  FDownload:=ButtonText(UiText('Start ride'),@ClickDownload);FDownload.Name:='StartOnlineRoute';
  FFavorite:=ButtonText(UiText('♡ Favorite'),@ClickFavorite);FShare:=ButtonText(UiText('Share'),@ClickShare);FAdd:=ButtonText(UiText('Add to my routes'),@ClickAdd);
  FEdit:=ButtonText(UiText('Edit'),@ClickEdit);FDelete:=ButtonText(UiText('Delete'),@ClickDelete);
  FEditPanel:=TCastleRectangleControl.Create(Self);FEditPanel.Width:=620;FEditPanel.Height:=260;FEditPanel.Color:=MenuSurface;FEditPanel.Anchor(hpMiddle);FEditPanel.Anchor(vpMiddle);FEditPanel.Exists:=False;InsertFront(FEditPanel);
  Col:=TCastleVerticalGroup.Create(Self);Col.Spacing:=15;Col.Anchor(hpLeft,16);Col.Anchor(vpTop,-16);FEditPanel.InsertFront(Col);
  L:=TMenuLabel.Create(Self);BindUiText(L, 'Route title and description');L.FontSize:=18;Col.InsertFront(L);
  FTitleEdit:=TMenuEdit.Create(Self);FTitleEdit.Width:=580;Col.InsertFront(FTitleEdit);
  FDescriptionEdit:=TMenuEdit.Create(Self);FDescriptionEdit.Width:=580;Col.InsertFront(FDescriptionEdit);
  Row:=TCastleHorizontalGroup.Create(Self);TCastleHorizontalGroup(Row).Spacing:=12;Col.InsertFront(Row);B:=ButtonText(UiText('Save'),@ClickSave);B:=ButtonText(UiText('Cancel'),@ClickCancel);
  UpdateSelection;Layout;
end;
destructor TRouteLibraryPage.Destroy;
begin RouteDetach(FTask);FItems.Free;inherited;end;
procedure TRouteLibraryPage.PageShown;
begin inherited;FUserId:=VeloSite.CachedProfile.Id;FMap.SetActive(FMapShown);
  if not FShared then try FItems.Free;FItems:=nil;FItems:=ReadRouteCatalog(FUserId);RenderItems;except FItems:=TJSONArray.Create;end;
  Load;end;
procedure TRouteLibraryPage.PageHidden;
begin inherited;FStartAfterAdd:=False;FStartRouteId:=0;RouteDetach(FTask);FMap.SetActive(False);FEditPanel.Exists:=False;end;
procedure TRouteLibraryPage.StartRequest(const Method,Path,Body:String);
begin
  if FTask<>nil then Exit;
  if(FUserId<=0)or(not VeloSite.IsAuthorized)then begin BindUiText(FStatus, 'Sign in to REZVIVO to use the route library');Exit;end;
  FTask:=TRouteTask.Create(FUserId,Method,Path,Body);FTask.Start;BindUiText(FStatus, 'Loading…');SetBusy(True);
end;
function TRouteLibraryPage.Query:String;
  procedure Add(const Key,Value:String;Multiplier:Double=1);
  var V:Double;FS:TFormatSettings;S:String;
  begin S:=Trim(Value);if S=''then Exit;if Multiplier<>1 then begin FS:=DefaultFormatSettings;FS.DecimalSeparator:='.';S:=StringReplace(S,',','.',[rfReplaceAll]);if not TryStrToFloat(S,V,FS)then raise Exception.Create(UiText('Enter a numeric distance'));S:=FloatToStr(V*Multiplier,FS);end;
    Result:=Result+'&'+Key+'='+RouteEncode(S);end;
begin
  Result:='?limit=50&offset='+IntToStr(FOffset)+'&sort='+FSort+'&direction='+FDirection;
  Add('q',FQuery.Text);Add('after',FAfter.Text);Add('before',FBefore.Text);
  Add('distance_min',FDistMin.Text,1000);Add('distance_max',FDistMax.Text,1000);
  Add('gain_min',FGainMin.Text);Add('gain_max',FGainMax.Text);
  if FOnlyFavorites.Checked then Result:=Result+'&favorite=1';
  if FShared and FMapShown then Result:=Result+'&bbox='+FMap.BoundsQuery;
end;
procedure TRouteLibraryPage.Load(More:Boolean);
var P:String;
begin
  if FTask<>nil then begin FPendingRefresh:=True;Exit;end;
  FPendingRefresh:=False;FAppend:=More;if not More then FOffset:=0;
  if FShared then P:='/shared-routes'else P:='/routes';
  try StartRequest('GET',P+Query,'');except on E:Exception do FStatus.Caption:=E.Message;end;
end;
function TRouteLibraryPage.Current:TJSONObject;
var I:Integer;
begin Result:=nil;for I:=0 to FItems.Count-1 do if TJSONObject(FItems[I]).Get('id',Int64(0))=FSelected then Exit(TJSONObject(FItems[I]));end;
procedure TRouteLibraryPage.Layout;
var Top,W,S:Single;I,J:Integer;Flow:TMenuFlow;
const Widths:array[0..5]of Single=(0.34,0.13,0.11,0.10,0.19,0.13);
begin
  S:=Max(0.65,Min(1,UIScale));Top:=8/S;
  for J:=0 to 3 do begin
    case J of 0:Flow:=FToolbar;1:Flow:=FSearchBar;2:Flow:=FFilterBar;else Flow:=FDateBar;end;
    if not Flow.Exists then Continue;
    Flow.Width:=Max(200,EffectiveWidth-16/S);Flow.Anchor(hpLeft,8/S);Flow.Anchor(vpTop,-Top);
    Flow.Arrange;Top:=Top+Flow.Height+12/S;
  end;
  FStatus.Anchor(vpTop,-Top);Top:=Top+34/S;
  FMap.Anchor(vpTop,-Top);FAttribution.Anchor(vpTop,-Top-226);
  if FMapShown then Top:=Top+260;
  SelectMenuButton(FOwn,not FShared);SelectMenuButton(FCommunity,FShared);FLayoutWidth:=EffectiveWidth;
  FHeaders.Anchor(vpTop,-Top);FScroll.Border.Top:=Top+38;
  FDetails.MaxWidth:=Max(200,EffectiveWidth-20);FStatus.MaxWidth:=Max(200,EffectiveWidth-20);
  FMap.Height:=250;
  W:=Max(500,EffectiveWidth-40)-20;
  for I:=0 to FHeaders.ControlsCount-1 do begin FHeaders.Controls[I].AutoSizeToChildren:=False;FHeaders.Controls[I].Width:=W*Widths[I];TCastleButton(FHeaders.Controls[I]).AutoSize:=False;FHeaders.Controls[I].Height:=32;end;
end;
procedure TRouteLibraryPage.SetBusy(Value:Boolean);
var I:Integer;
begin for I:=0 to FActions.ControlsCount-1 do if FActions.Controls[I] is TCastleButton then TCastleButton(FActions.Controls[I]).Enabled:=not Value;end;
procedure TRouteLibraryPage.RenderItems;
var I,J:Integer;O:TJSONObject;B:TCastleButton;Title,Source:String;L:TCastleLabel;X,W:Single;
    Values:array[0..5]of String;
const Widths:array[0..5]of Single=(0.34,0.13,0.11,0.10,0.19,0.13);
begin
  while FList.ControlsCount>0 do FList.Controls[0].Free;
  for I:=0 to FItems.Count-1 do begin O:=TJSONObject(FItems[I]);Title:=O.Get('title','');Source:=O.Get('source','');if Source='upload'then Source:=UiText('File');if Source='shared'then Source:=UiText('Community');
    if O.Get('favorite',False)then Title:='♥ '+Title;
    Values[0]:=UTF8Encode(Copy(UTF8Decode(Title),1,48));Values[1]:=Copy(RouteJSONText(O,'activity_date','—'),1,10);Values[2]:=RouteMetric(O,'distance_m',1000)+UiText(' km');Values[3]:=RouteMetric(O,'elevation_gain_m')+UiText(' m');Values[4]:=O.Get('author','');Values[5]:=Source;
    if O.Get('status','')='processing'then Values[2]:=UiText('Processing…');
    if O.Get('status','')='rejected'then Values[2]:=UiText('Error');
    B:=TMenuButton.Create(FList);B.Caption:='';B.FontSize:=14;B.AutoSize:=False;B.Width:=Max(500,EffectiveWidth-40);B.Height:=38;B.Tag:=I;B.OnClick:=@ClickRow;B.Toggle:=True;B.Pressed:=O.Get('id',Int64(0))=FSelected;FList.InsertFront(B);
    X:=8;W:=B.Width-20;
    for J:=0 to 5 do begin L:=TMenuLabel.Create(B);L.Caption:=Values[J];L.FontSize:=13;L.Color:=Vector4(0.92,0.95,1,1);L.MaxWidth:=W*Widths[J]-8;L.Anchor(hpLeft,X);L.Anchor(vpMiddle);B.InsertFront(L);X:=X+W*Widths[J]+4;end;
  end;
  FMoreButton.Exists:=FMore;FMap.SetRoutes(FItems,FFitMap and not FShared);FFitMap:=False;UpdateSelection;
end;
procedure TRouteLibraryPage.UpdateSelection;
var O:TJSONObject;Own,Ready:Boolean;
begin
  O:=Current;FActions.Exists:=O<>nil;if O=nil then begin BindUiText(FDetails, 'Select a route in the table or on the map');Exit;end;
  BindUiText(FDelete, 'Delete');
  Own:=O.Get('user_id',Int64(0))=FUserId;Ready:=O.Get('status','')='ready';
  FFavorite.Exists:=Own;FShare.Exists:=Own and Ready;FDownload.Exists:=Ready;FAdd.Exists:=False;FEdit.Exists:=Own;FDelete.Exists:=Own;
  if O.Get('favorite',False)then BindUiText(FFavorite, '♥ Favorite')else BindUiText(FFavorite, '♡ Favorite');
  if O.Get('shared',False)then BindUiText(FShare, 'Shared ✓')else BindUiText(FShare, 'Share');
  FDetails.Caption:=O.Get('title','')+' · '+O.Get('description','');FMap.SelectedId:=FSelected;
end;
procedure TRouteLibraryPage.ClickOwn(Sender:TObject);
begin FShared:=False;FFitMap:=True;Load;end;
procedure TRouteLibraryPage.ClickCommunity(Sender:TObject);
begin FShared:=True;if not FMapShown then ClickMap(nil)else Load;end;
procedure TRouteLibraryPage.ClickMap(Sender:TObject);
begin FMapShown:=not FMapShown;FMap.Exists:=FMapShown;FAttribution.Exists:=FMapShown;FMap.SetActive(FMapShown);Layout;if FMapShown and not FShared then FMap.FitRoute(0);Load;end;
procedure TRouteLibraryPage.ClickRefresh(Sender:TObject);
begin Load;end;
procedure TRouteLibraryPage.ClickMore(Sender:TObject);
begin Load(True);end;
procedure TRouteLibraryPage.ClickSort(Sender:TObject);
const Sorts:array[0..5]of String=('name','date','distance','gain','author','source');
var S:String;
begin S:=Sorts[TCastleButton(Sender).Tag];if(FSort=S)and(FDirection='desc')then FDirection:='asc'else FDirection:='desc';FSort:=S;Load;end;
procedure TRouteLibraryPage.ClickRow(Sender:TObject);
var I:Integer;
begin I:=TCastleButton(Sender).Tag;if(I<0)or(I>=FItems.Count)then Exit;FSelected:=TJSONObject(FItems[I]).Get('id',Int64(0));UpdateSelection;if FMapShown and not FShared then FMap.FitRoute(FSelected);end;
procedure TRouteLibraryPage.Patch(const Key:String;Value:Boolean);
var O,P:TJSONObject;
begin O:=Current;if O=nil then Exit;P:=TJSONObject.Create(['version',O.Get('version',Int64(0)),Key,Value]);try StartRequest('PATCH','/routes/'+IntToStr(FSelected),P.AsJSON);finally P.Free;end;end;
procedure TRouteLibraryPage.ClickFavorite(Sender:TObject);
begin if Current<>nil then Patch('favorite',not Current.Get('favorite',False));end;
procedure TRouteLibraryPage.ClickShare(Sender:TObject);
begin if Current<>nil then Patch('shared',not Current.Get('shared',False));end;
procedure TRouteLibraryPage.ClickAdd(Sender:TObject);
begin if Current<>nil then StartRequest('POST','/shared-routes/'+IntToStr(FSelected)+'/add','{}');end;
procedure TRouteLibraryPage.ClickDownload(Sender:TObject);
var O:TJSONObject;Dest,Format:String;
begin
  if FTask<>nil then Exit;O:=Current;if O=nil then Exit;
  if O.Get('user_id',Int64(0))<>FUserId then begin FStartAfterAdd:=True;ClickAdd(nil);Exit;end;
  Format:=O.Get('format','gpx');if(Format<>'fit')and(Format<>'gpx')then Exit;
  Dest:=RouteAccountDir(FUserId)+'routes'+PathDelim+IntToStr(FSelected)+'-'+O.Get('sha256','')+'.'+Format;
  if FileExists(Dest)then begin ViewMenu.OpenCloudRoute(Dest,True);Exit;end;
  FTask:=TRouteTask.Create(FUserId,'GET','','');FTask.RouteId:=FSelected;FTask.DownloadFile:=Dest;FTask.Start;
  BindUiText(FStatus, 'Downloading route…');SetBusy(True);
end;
procedure TRouteLibraryPage.ClickEdit(Sender:TObject);
begin if Current=nil then Exit;FTitleEdit.Text:=Current.Get('title','');FDescriptionEdit.Text:=Current.Get('description','');FEditPanel.Exists:=True;end;
procedure TRouteLibraryPage.ClickSave(Sender:TObject);
var P:TJSONObject;
begin if Current=nil then Exit;P:=TJSONObject.Create(['version',Current.Get('version',Int64(0)),'title',FTitleEdit.Text,'description',FDescriptionEdit.Text]);
  try StartRequest('PATCH','/routes/'+IntToStr(FSelected),P.AsJSON);finally P.Free;end;FEditPanel.Exists:=False;end;
procedure TRouteLibraryPage.ClickCancel(Sender:TObject);
begin FEditPanel.Exists:=False;end;
procedure TRouteLibraryPage.ClickDelete(Sender:TObject);
var P:TJSONObject;
begin
  if Current=nil then Exit;
  if FDelete.Caption<>UiText('Remove from your profile?')then begin BindUiText(FDelete, 'Remove from your profile?');Exit;end;
  BindUiText(FDelete, 'Delete');P:=TJSONObject.Create(['version',Current.Get('version',Int64(0))]);try StartRequest('DELETE','/routes/'+IntToStr(FSelected),P.AsJSON);finally P.Free;end;
end;
procedure TRouteLibraryPage.ClickBack(Sender:TObject);
begin ViewMenu.ShowRoutesPage;end;
procedure TRouteLibraryPage.ClickUpload(Sender:TObject);
var URL,FileName:String;
begin
  URL:='';if not Application.MainWindow.FileDialog(UiText('Add route'),URL,True,'FIT / GPX|*.fit;*.gpx')then Exit;
  FileName:=URIToFilenameSafe(URL);if not FileExists(FileName)then Exit;
  try ViewMenu.AcceptFile(FileName);except on E:Exception do FStatus.Caption:=E.Message;end;
end;
procedure TRouteLibraryPage.ClickAttribution(Sender:TObject);
begin OpenURL('https://www.openstreetmap.org/copyright');end;
procedure TRouteLibraryPage.MapChanged(Sender:TObject);
begin if FShared and FMapShown then Load;end;
procedure TRouteLibraryPage.MapSelected(Sender:TObject);
begin FSelected:=FMap.SelectedId;UpdateSelection;end;
procedure TRouteLibraryPage.Update(const SecondsPassed:Single;var HandleInput:Boolean);
var D:TJSONData;O:TJSONObject;A:TJSONArray;I:Integer;Mutated,Success:Boolean;Downloaded:String;Added:TJSONObject;
begin
  inherited;
  if Abs(FLayoutWidth-EffectiveWidth)>1 then begin Layout;RenderItems;end;
  if FFilterDelay>0 then begin FFilterDelay:=Max(0,FFilterDelay-SecondsPassed);if FFilterDelay=0 then Load;end;
  if FUserId<>VeloSite.CachedProfile.Id then begin FStartAfterAdd:=False;FStartRouteId:=0;RouteDetach(FTask);FUserId:=VeloSite.CachedProfile.Id;FItems.Clear;FSelected:=0;RenderItems;Load;end;
  if(FTask<>nil)and FTask.Done then
  begin
    SetBusy(False);Mutated:=FTask.Method<>'GET';Success:=FTask.ErrorText='';Downloaded:='';
    if(FStartRouteId>0)and(FTask.Path='/routes/'+IntToStr(FStartRouteId))then begin
      if not Success then begin FStatus.Caption:=FTask.ErrorText;FStartRouteId:=0;end
      else if FTask.Response is TJSONObject then begin
        Added:=TJSONObject(FTask.Response);
        if Added.Find('route')is TJSONObject then Added:=Added.Objects['route'];
        if Added.Get('status','')='ready' then begin
          FSelected:=FStartRouteId;FStartRouteId:=0;
          for I:=FItems.Count-1 downto 0 do if FItems.Objects[I].Get('id',Int64(0))=FSelected then FItems.Delete(I);
          FItems.Add(Added.Clone);FreeAndNil(FTask);ClickDownload(nil);Exit;
        end;
        if(Added.Get('status','')='failed')or(Added.Get('status','')='deleted')then begin
          BindUiText(FStatus,'Could not prepare this route');FStartRouteId:=0;
        end else begin BindUiText(FStatus,'Preparing the route on the server…');FStartRouteDelay:=1;SetBusy(True);end;
      end else begin BindUiText(FStatus,'Could not prepare this route');FStartRouteId:=0;end;
      FreeAndNil(FTask);Exit;
    end;
    if not Success then begin FStatus.Caption:=FTask.ErrorText;if FItems.Count>0 then FStatus.Caption:=FStatus.Caption+UiText(' · Showing a cached copy of the list');end else if FTask.DownloadFile<>''then Downloaded:=FTask.DownloadFile else
    if FTask.Response is TJSONObject then begin O:=TJSONObject(FTask.Response);D:=O.Find('items');if D is TJSONArray then begin
      A:=TJSONArray(D);if not FAppend then FItems.Clear;
      for I:=0 to A.Count-1 do FItems.Add(A[I].Clone);
      FMore:=O.Get('more',False);FOffset:=O.Get('next_offset',0);RenderItems;
      if not FShared then try SaveRouteCatalog(FUserId,FItems);except end;
      if FItems.Count=0 then BindUiText(FStatus, 'No routes yet. Add a file or change the filters.')else FStatus.Caption:=UiText('Routes: ')+IntToStr(FItems.Count);
    end;end;
    if FStartAfterAdd and Mutated then begin
      FStartAfterAdd:=False;
      if Success and(FTask.Response is TJSONObject)then begin
        Added:=TJSONObject(FTask.Response);
        if Added.Find('route')is TJSONObject then Added:=Added.Objects['route'];
        FStartRouteId:=Added.Get('route_id',Added.Get('id',Int64(0)));
        if FStartRouteId>0 then begin
          FreeAndNil(FTask);FStartRouteDelay:=0;FPendingRefresh:=False;
          StartRequest('GET','/routes/'+IntToStr(FStartRouteId),'');Exit;
        end;
      end;
    end;
    FreeAndNil(FTask);FPoll:=0;
    if Downloaded<>''then begin ViewMenu.OpenCloudRoute(Downloaded,True);Exit;end;
    if(Mutated and Success)or FPendingRefresh then Load;
  end;
  if FStartRouteId>0 then begin
    FStartRouteDelay:=Max(0,FStartRouteDelay-SecondsPassed);
    if(FTask=nil)and(FStartRouteDelay=0)then StartRequest('GET','/routes/'+IntToStr(FStartRouteId),'');
    Exit;
  end;
  FPoll:=FPoll+SecondsPassed;if FPoll>15 then begin FPoll:=0;if(not FEditPanel.Exists)and(FItems.Count<=50)then Load;end;
end;
procedure TRouteLibraryPage.FilterEdited(Sender:TObject);
begin FFilterDelay:=0.45;end;
procedure TRouteLibraryPage.ClickFilters(Sender:TObject);
begin FFilterBar.Exists:=not FFilterBar.Exists;FDateBar.Exists:=FFilterBar.Exists;Layout;end;

end.
