unit GameViewTraining;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses Classes,SysUtils,CastleUIControls,CastleControls,GameMenuTheme,GameMenuTile,
  WorkoutFile,WorkoutLibrary,GameWorkoutPreview,GameWorkoutSuggest;
type
  TTrainingPage=class(TMenuEmbeddedPage)
  private
    FSearch,FBasePower:TCastleEdit;
    FToolbar,FPowerBar,FHeaderActions:TMenuFlow;
    FPageTitle,FPageHint:TCastleLabel;
    FScroll:TCastleScrollView;
    FContent:TCastleUserInterface;
    FContentOwner:TComponent;
    FItems:TList;
    FLocal:TWorkoutFileList;
    FSelected:TWorkoutFile;
    FDetails:TCastleRectangleControl;
    FDetailsContent:TCastleUserInterface;
    FDetailsScroll:TCastleScrollView;
    FDetailsTitle:TCastleLabel;
    FDetailsPreview:TWorkoutPreview;
    FDetailsDescription:TCastleLabel;
    FDetailsActions:TMenuFlow;
    procedure LayoutDetails;
  private
    FQuickFields:array[0..4]of TCastleEdit;
    FTimed:TCastleCheckbox;
    FStatus:TCastleLabel;
    FFilter,FLimit,FDuration:Integer;
    FDurationButton:TMenuButton;
    procedure ClickDuration(Sender:TObject);
  private
    FPickerBar:TMenuFlow;
    FPickerButton,FRepeatButton:TMenuButton;
    FPickerMinutes:Integer;
    FPickerGoal:TWorkoutGoal;
    procedure ClickPicker(Sender:TObject);
    procedure ClickPickerChoice(Sender:TObject);
    procedure ClickRepeat(Sender:TObject);
  private
    FWidth,FScale,FSearchDelay,FBarHeight:Single;
    FRebuild:Boolean;
    procedure LoadItems;
    procedure BuildList;
    procedure Layout;
    procedure SearchChanged(Sender:TObject);
    procedure ClickFilter(Sender:TObject);
    procedure ClickStart(Sender:TObject);
    procedure ClickDetails(Sender:TObject);
    procedure ClickFavorite(Sender:TObject);
    procedure ClickMore(Sender:TObject);
    procedure ClickImport(Sender:TObject);
    procedure ClickQuick(Sender:TObject);
    procedure ClickQuickStart(Sender:TObject);
    procedure ClickQuickSave(Sender:TObject);
    procedure ClickEdit(Sender:TObject);
    procedure ClickClose(Sender:TObject);
    procedure ClickPower(Sender:TObject);
    procedure ClickRider(Sender:TObject);
    function ReferencePower:Double;
    function MakeQuick:TWorkoutFile;
    function NewDetails(const Title:String):TCastleUserInterface;
    procedure AddCard(Plan:TWorkoutFile;Index,Column,Row:Integer;CardW,S:Single;const Reason:String='');
  public
    constructor Create(AOwner:TComponent);override;
    destructor Destroy;override;
    procedure PageShown;override;
    procedure PageHidden;override;
    procedure Resize;override;
    procedure Update(const SecondsPassed:Single;var HandleInput:Boolean);override;
    function HandleBack:Boolean;override;
    procedure ShowIntervals;
    procedure ImportFile(const FileName:String);
    procedure RefreshLibrary;
    function KeyboardRoot:TCastleUserInterface;
  end;
var ViewTraining:TTrainingPage;
implementation
uses Math,fpjson,CastleColors,CastleVectors,CastleWindow,CastleURIUtils,CastleApplicationProperties,
  UiTranslations,GameUserData,GameViewMenu,GameViewWorkoutEditor,VeloSiteAPI,GameFilePicker;

function LowerUtf(const S:String):String;
begin Result:=UTF8Encode(UnicodeLowerCase(UTF8Decode(S)));end;
function Btn(O:TComponent;P:TCastleUserInterface;const N,T:String;Click:TNotifyEvent):TMenuButton;
begin Result:=TMenuButton.Create(O);Result.Name:=N;Result.AutoIcon:=False;BindUiText(Result,T);
  Result.FontSize:=16;Result.OnClick:=Click;P.InsertFront(Result);end;
function Lbl(O:TComponent;P:TCastleUserInterface;const T:String;X,Y,Z:Single):TCastleLabel;
begin Result:=TMenuLabel.Create(O);BindUiText(Result,T);Result.Color:=White;
  Result.FontSize:=Z;Result.Anchor(hpLeft,X);Result.Anchor(vpTop,-Y);P.InsertFront(Result);end;

constructor TTrainingPage.Create(AOwner:TComponent);
var B:TMenuButton;Bg:TCastleRectangleControl;I:Integer;
const Filters:array[0..3]of String=('All workouts','Intervals','Favorites','My workouts');
  Minutes:array[0..3]of Integer=(20,30,45,60);
  Goals:array[TWorkoutGoal]of String=('Easy','Steady','Intervals');
begin
  inherited;FullSize:=True;FLimit:=40;FFilter:=1;FItems:=TList.Create;FLocal:=TWorkoutFileList.Create(True);
  Bg:=TCastleRectangleControl.Create(Self);Bg.FullSize:=True;Bg.Color:=MenuBackground;InsertBack(Bg);
  FPageTitle:=Lbl(Self,Self,'Training',24,16,30);FPageTitle.CustomFont:=MenuFont(True);
  FPageHint:=Lbl(Self,Self,'Choose a workout and start riding',24,58,14);FPageHint.Color:=MenuMuted;
  FHeaderActions:=TMenuFlow.Create(Self);InsertFront(FHeaderActions);
  FSearch:=TMenuEdit.Create(Self);FSearch.Name:='WorkoutSearch';FSearch.Text:='';BindUiText(FSearch,'Search workouts','Placeholder');
  FSearch.OnChange:=@SearchChanged;InsertFront(FSearch);
  FToolbar:=TMenuFlow.Create(Self);FToolbar.Spacing:=8;InsertFront(FToolbar);
  for I:=0 to 3 do begin B:=Btn(FToolbar,FToolbar,'WorkoutFilter'+IntToStr(I),Filters[I],@ClickFilter);B.Tag:=I;end;
  Btn(FHeaderActions,FHeaderActions,'CreateIntervals','Create intervals',@ClickQuick);
  Btn(FHeaderActions,FHeaderActions,'ImportWorkout','Import ZWO',@ClickImport);
  Btn(FHeaderActions,FHeaderActions,'WorkoutPowerOptions','Load settings',@ClickPower);
  FRepeatButton:=Btn(FHeaderActions,FHeaderActions,'RepeatLastWorkout','Repeat last workout',@ClickRepeat);
  FDurationButton:=Btn(FToolbar,FToolbar,'WorkoutDuration','Any duration',@ClickDuration);
  FPickerButton:=Btn(FToolbar,FToolbar,'SuggestWorkout','Help me choose',@ClickPicker);
  FPickerMinutes:=30;FPickerGoal:=wgIntervals;
  FPickerBar:=TMenuFlow.Create(Self);FPickerBar.Exists:=False;InsertFront(FPickerBar);
  for I:=0 to 3 do begin
    B:=Btn(FPickerBar,FPickerBar,'SuggestMinutes'+IntToStr(Minutes[I]),IntToStr(Minutes[I])+' min',@ClickPickerChoice);
    B.Tag:=Minutes[I];
  end;
  for I:=Ord(Low(TWorkoutGoal))to Ord(High(TWorkoutGoal))do begin
    B:=Btn(FPickerBar,FPickerBar,'SuggestGoal'+IntToStr(I),Goals[TWorkoutGoal(I)],@ClickPickerChoice);B.Tag:=-I-1;
  end;
  FPowerBar:=TMenuFlow.Create(Self);FPowerBar.Spacing:=12;FPowerBar.Exists:=False;InsertFront(FPowerBar);
  Lbl(FPowerBar,FPowerBar,'Power at 100%, W (optional)',0,0,16);
  FBasePower:=TMenuEdit.Create(FPowerBar);FBasePower.Name:='WorkoutBasePower';FBasePower.Width:=90;
  FBasePower.OnChange:=@SearchChanged;FPowerBar.InsertFront(FBasePower);
  FTimed:=TCastleCheckbox.Create(FPowerBar);FTimed.Name:='WorkoutTimedOnly';BindUiText(FTimed,'Timed intervals only');FTimed.FontSize:=16;
  FTimed.OnChange:=@SearchChanged;FPowerBar.InsertFront(FTimed);
  Btn(FPowerBar,FPowerBar,'WorkoutRiderSettings','Rider settings',@ClickRider);
  FStatus:=Lbl(Self,Self,'',24,0,14);FStatus.Color:=MenuMuted;
  FScroll:=TMenuScrollView.Create(Self);FScroll.FullSize:=True;FScroll.Border.Left:=12;FScroll.Border.Right:=12;FScroll.Border.Bottom:=12;InsertFront(FScroll);
  FContent:=TCastleUserInterface.Create(Self);FScroll.ScrollArea.InsertFront(FContent);
end;
destructor TTrainingPage.Destroy;
begin FSelected.Free;FItems.Free;FLocal.Free;inherited;end;
procedure TTrainingPage.LoadItems;
var I,J:Integer;W:TWorkoutFile;Recent:TJSONArray;K:Integer;
begin
  FContent.ClearControls;FreeAndNil(FContentOwner);FItems.Clear;FLocal.Clear;
  LoadLocalWorkoutFiles(UserDataDir+'workouts',FLocal);
  for I:=0 to FLocal.Count-1 do FItems.Add(FLocal[I]);
  if WorkoutLib<>nil then for I:=0 to WorkoutLib.Categories.Count-1 do
    for J:=0 to WorkoutLib.Categories[I].Workouts.Count-1 do FItems.Add(WorkoutLib.Categories[I].Workouts[J]);
  K:=0;for I:=0 to FItems.Count-1 do if Pos('/00-quick-start/',TWorkoutFile(FItems[I]).Url)>0 then begin
    W:=TWorkoutFile(FItems[I]);FItems.Delete(I);FItems.Insert(K,W);Inc(K);
  end;
  if UserPreferences.Find('recent_workouts')is TJSONArray then begin
    Recent:=UserPreferences.Arrays['recent_workouts'];
    for K:=Recent.Count-1 downto 0 do for I:=0 to FItems.Count-1 do
      if TWorkoutFile(FItems[I]).Url=Recent.Strings[K]then begin
        W:=TWorkoutFile(FItems[I]);FItems.Delete(I);FItems.Insert(0,W);Break;
      end;
  end;
end;
procedure TTrainingPage.PageShown;
var P:TVeloSiteProfile;I:Integer;
begin inherited;LoadItems;P:=EffectiveRiderProfile;
  FRepeatButton.Enabled:=False;
  for I:=0 to FItems.Count-1 do
    if TWorkoutFile(FItems[I]).Url=UserPreferences.Get('last_workout','')then begin FRepeatButton.Enabled:=True;Break;end;
  if P.FtpW>0 then FBasePower.Text:=IntToStr(P.FtpW)else FBasePower.Text:='';
  FTimed.Checked:=P.FtpW<=0;FRebuild:=True;Layout;end;
procedure TTrainingPage.PageHidden;
const Keys:array[0..4]of String=('interval_repeats','interval_work','interval_rest','interval_on','interval_off');
var I:Integer;
begin inherited;if FQuickFields[0]<>nil then begin
  for I:=0 to 4 do UserPreferences.Strings[Keys[I]]:=FQuickFields[I].Text;SaveUserPreferences;end;end;
procedure TTrainingPage.Resize;
begin inherited;Layout;FRebuild:=True;end;
procedure TTrainingPage.Layout;
var S,Top,ActionsTop:Single;I:Integer;
begin
  if FContent=nil then Exit;S:=Max(0.65,Min(1,UIScale));
  FSearch.Enabled:=not FPickerBar.Exists;FDurationButton.Enabled:=not FPickerBar.Exists;
  FPageTitle.FontSize:=30/S;FPageTitle.Anchor(hpLeft,24/S);FPageTitle.Anchor(vpTop,-16/S);
  FPageHint.FontSize:=14/S;FPageHint.Anchor(hpLeft,24/S);FPageHint.Anchor(vpTop,-60/S);
  FPageHint.MaxWidth:=EffectiveWidth-48/S;
  if EffectiveWidth*S>=1040 then begin
    FHeaderActions.Width:=EffectiveWidth-390/S;FHeaderActions.Anchor(hpLeft,366/S);ActionsTop:=16/S;
  end else begin
    FHeaderActions.Width:=EffectiveWidth-48/S;FHeaderActions.Anchor(hpLeft,24/S);ActionsTop:=96/S;
  end;
  FHeaderActions.Anchor(vpTop,-ActionsTop);FHeaderActions.Spacing:=8/S;
  for I:=0 to FHeaderActions.ControlsCount-1 do TCastleButton(FHeaderActions.Controls[I]).FontSize:=14/S;
  FHeaderActions.Arrange;
  Top:=Max(98/S,ActionsTop+FHeaderActions.Height+20/S);
  FSearch.Width:=Max(120,EffectiveWidth-48/S);FSearch.Height:=42/S;FSearch.FontSize:=15/S;
  FSearch.Anchor(hpLeft,24/S);FSearch.Anchor(vpTop,-Top);
  Top:=Top+56/S;
  FToolbar.Width:=Max(100,EffectiveWidth-48/S);FToolbar.Anchor(hpLeft,24/S);FToolbar.Anchor(vpTop,-Top);
  FToolbar.Spacing:=8/S;
  for I:=0 to FToolbar.ControlsCount-1 do TCastleButton(FToolbar.Controls[I]).FontSize:=14/S;
  FToolbar.Arrange;Top:=Top+FToolbar.Height+18/S;
  FPickerBar.Width:=FToolbar.Width;FPickerBar.Anchor(hpLeft,24/S);FPickerBar.Anchor(vpTop,-Top);
  FPickerBar.Spacing:=8/S;
  if FPickerBar.Exists then begin
    for I:=0 to 3 do SelectMenuButton(FToolbar.FindComponent('WorkoutFilter'+IntToStr(I))as TCastleButton,False);
    for I:=0 to FPickerBar.ControlsCount-1 do TCastleButton(FPickerBar.Controls[I]).FontSize:=14/S;
    FPickerBar.Arrange;Top:=Top+FPickerBar.Height+12/S;
  end;
  FPowerBar.Width:=FToolbar.Width;FPowerBar.Anchor(hpLeft,24/S);FPowerBar.Anchor(vpTop,-Top);
  if FPowerBar.Exists then begin FPowerBar.Arrange;Top:=Top+FPowerBar.Height+12/S;end;
  FStatus.FontSize:=13/S;FStatus.MaxWidth:=EffectiveWidth-48/S;FStatus.Anchor(hpLeft,24/S);FStatus.Anchor(vpTop,-Top);
  FScroll.Border.Top:=Top+Max(32/S,FStatus.EffectiveHeight+16/S);
  FScroll.Border.Left:=24/S;FScroll.Border.Right:=16/S;
  LayoutDetails;
  FWidth:=EffectiveWidth;FScale:=S;FBarHeight:=FToolbar.Height+FPowerBar.Height+FHeaderActions.Height;
end;
procedure TTrainingPage.Update(const SecondsPassed:Single;var HandleInput:Boolean);
begin inherited;
  if(Abs(FBarHeight-FToolbar.Height-FPowerBar.Height-FHeaderActions.Height)>0.1)or(Abs(FWidth-EffectiveWidth)>1)or(Abs(FScale-Max(0.65,Min(1,UIScale)))>0.001)then begin Layout;FRebuild:=True;end;
  FSearchDelay:=Max(0,FSearchDelay-SecondsPassed);
  if FRebuild and(FSearchDelay<=0)then begin FRebuild:=False;BuildList;end;
end;
procedure TTrainingPage.SearchChanged(Sender:TObject);
begin
  if Sender=FSearch then begin FPickerBar.Exists:=False;Layout;end;
  FLimit:=40;FSearchDelay:=0.2;FRebuild:=True;
end;
procedure TTrainingPage.ClickFilter(Sender:TObject);
begin FPickerBar.Exists:=False;FFilter:=TComponent(Sender).Tag;FLimit:=40;Layout;FRebuild:=True;end;
procedure TTrainingPage.ClickPicker(Sender:TObject);
begin FPickerBar.Exists:=not FPickerBar.Exists;Layout;FRebuild:=True;end;
procedure TTrainingPage.ClickPickerChoice(Sender:TObject);
var N:Integer;
begin
  N:=TComponent(Sender).Tag;
  if N>0 then FPickerMinutes:=N else FPickerGoal:=TWorkoutGoal(-N-1);
  FRebuild:=True;
end;
procedure TTrainingPage.ClickRepeat(Sender:TObject);
var I:Integer;
begin
  for I:=0 to FItems.Count-1 do
    if TWorkoutFile(FItems[I]).Url=UserPreferences.Get('last_workout','')then begin
      ViewMenu.StartWorkout(TWorkoutFile(FItems[I]),ReferencePower);Exit;
    end;
end;
procedure TTrainingPage.ShowIntervals;
begin FPickerBar.Exists:=False;FFilter:=1;Layout;FRebuild:=True;end;
function TTrainingPage.KeyboardRoot:TCastleUserInterface;
begin Result:=FDetails;end;
procedure TTrainingPage.ClickMore(Sender:TObject);
begin Inc(FLimit,40);FRebuild:=True;end;
procedure TTrainingPage.AddCard(Plan:TWorkoutFile;Index,Column,Row:Integer;CardW,S:Single;const Reason:String);
var Card:TMenuPanel;B:TMenuButton;Preview:TWorkoutPreview;L:TCastleLabel;
begin
  Card:=TMenuPanel.Create(FContentOwner);Card.Width:=CardW;Card.Height:=314/S;
  Card.Anchor(hpLeft,Column*(CardW+16/S));Card.Anchor(vpTop,-Row*330/S);FContent.InsertFront(Card);
  B:=Btn(Card,Card,'WorkoutDetails'+IntToStr(Index),Plan.Name,@ClickDetails);B.Tag:=Index;
  B.Style:=mbGhost;B.CustomTextColor:=MenuText;B.CustomFont:=MenuFont(True);
  B.AutoSize:=False;B.Width:=CardW-76/S;B.Height:=34/S;B.FontSize:=18/S;B.PaddingHorizontal:=0;B.Alignment:=hpLeft;
  B.Anchor(hpLeft,20/S);B.Anchor(vpTop,-18/S);B.Caption:=MenuEllipsis(UiText(Plan.Name),B.Font,(CardW-80/S)*UIScale);
  L:=Lbl(Card,Card,FormatWorkoutDuration(Plan.TotalDuration)+'  ·  '+UiText(StringReplace(Plan.Category,'00-quick-start','Quick start',[])),20/S,64/S,13/S);
  L.Color:=MenuMuted;L.MaxWidth:=CardW-40/S;
  if Reason<>''then L.Caption:=FormatWorkoutDuration(Plan.TotalDuration)+'  ·  '+Reason;
  Preview:=TWorkoutPreview.Create(Card);Preview.LoadWorkout(Plan);Preview.Width:=CardW-40/S;Preview.Height:=100/S;
  Preview.FtpWatts:=Round(ReferencePower);Preview.Anchor(hpLeft,20/S);Preview.Anchor(vpTop,-96/S);Card.InsertFront(Preview);
  B:=Btn(Card,Card,'StartWorkout'+IntToStr(Index),'Start',@ClickStart);B.Tag:=Index;B.FontSize:=14/S;
  B.Style:=mbPrimary;B.AutoSize:=False;B.Width:=CardW-40/S;B.Height:=44/S;
  B.Anchor(hpLeft,20/S);B.Anchor(vpBottom,62/S);if ReferencePower<=0 then BindUiText(B,'Start timed intervals');
  B:=Btn(Card,Card,'TrainingOnlyWorkout'+IntToStr(Index),'Training focus',@ClickStart);B.Tag:=Index;
  B.AutoIcon:=False;B.AutoSize:=False;B.FontSize:=14/S;B.Width:=CardW-40/S;B.Height:=36/S;
  B.Anchor(hpLeft,20/S);B.Anchor(vpBottom,18/S);
  B:=Btn(Card,Card,'FavoriteWorkout'+IntToStr(Index),'☆',@ClickFavorite);B.Tag:=Index;B.Style:=mbGhost;
  if WorkoutFavorite(Plan.Url)then begin B.Caption:='★';B.CustomTextColor:=MenuAccent;end;
  B.AutoSize:=False;B.Width:=36/S;B.Height:=36/S;B.FontSize:=22/S;B.PaddingHorizontal:=0;B.PaddingVertical:=0;
  B.Anchor(hpRight,-12/S);B.Anchor(vpTop,-16/S);
end;
procedure TTrainingPage.BuildList;
var I,J,N,Total,Columns:Integer;W:TWorkoutFile;S,CardW,H,AvailableW:Single;Match,Intervals:Boolean;Query:String;B:TMenuButton;
  Suggestions:TWorkoutSuggestions;
const Reasons:array[TWorkoutGoal]of String=('Easy effort','Steady effort','Work and recovery');
begin
  if FScroll.EffectiveWidth<100 then Exit;FContent.ClearControls;FreeAndNil(FContentOwner);FContentOwner:=TComponent.Create(Self);
  S:=Max(0.65,Min(1,UIScale));
  AvailableW:=FScroll.RenderRect.Width/Max(0.01,UIScale)-18/S;
  Columns:=EnsureRange(Floor(AvailableW*S/300),1,3);
  CardW:=(AvailableW-(Columns-1)*16/S)/Columns;N:=0;Total:=0;Query:=LowerUtf(Trim(FSearch.Text));
  SelectMenuButton(FPickerButton,FPickerBar.Exists);
  if FPickerBar.Exists then begin
    Suggestions:=SuggestWorkouts(FItems,FPickerMinutes,FPickerGoal);
    for I:=0 to High(Suggestions)do begin
      J:=Suggestions[I].Index;
      AddCard(TWorkoutFile(FItems[J]),J,N mod Columns,N div Columns,CardW,S,UiText(Reasons[FPickerGoal]));Inc(N);
    end;
    for I:=0 to FPickerBar.ControlsCount-1 do begin
      B:=FPickerBar.Controls[I]as TMenuButton;
      SelectMenuButton(B,(B.Tag=FPickerMinutes)or(B.Tag=-Ord(FPickerGoal)-1));
    end;
    H:=Ceil(N/Columns)*330/S;
    if N=0 then Lbl(FContentOwner,FContent,'No matching workouts',12,12,18/S);
    FContent.Width:=AvailableW;FContent.Height:=Max(100,H);FScroll.ScrollArea.Height:=FContent.Height;
    FStatus.Caption:=Format(UiText('Closest to %d min · based on duration and effort'),[FPickerMinutes]);
    Exit;
  end;
  for I:=0 to FItems.Count-1 do begin
    W:=TWorkoutFile(FItems[I]);Intervals:=False;
    for J:=0 to W.Segments.Count-1 do if W.Segments[J].Kind=wskInterval then begin Intervals:=True;Break;end;
    Match:=(Query='')or(Pos(Query,LowerUtf(UiText(W.Name)+' '+UiText(W.Description)+' '+UiText(W.Category)))>0);
    case FDuration of
      1:Match:=Match and(W.TotalDuration<=1800);
      2:Match:=Match and(W.TotalDuration>1800)and(W.TotalDuration<=3600);
      3:Match:=Match and(W.TotalDuration>3600);
    end;
    case FFilter of 1:Match:=Match and Intervals;2:Match:=Match and WorkoutFavorite(W.Url);3:Match:=Match and(FLocal.IndexOf(W)>=0);end;
    if not Match then Continue;Inc(Total);if N>=FLimit then Continue;
    AddCard(W,I,N mod Columns,N div Columns,CardW,S);Inc(N);
  end;
  H:=Ceil(N/Columns)*330/S;
  if Total>N then begin B:=Btn(FContentOwner,FContent,'MoreWorkouts','Show more',@ClickMore);B.Anchor(vpTop,-H);H:=H+52/S;end;
  if N=0 then Lbl(FContentOwner,FContent,'No matching workouts',12,12,18/S);
  FContent.Width:=AvailableW;FContent.Height:=Max(100,H);FScroll.ScrollArea.Height:=FContent.Height;
  FStatus.Caption:=IntToStr(Total)+' '+UiText('workouts')+'  ·  ';
  if ReferencePower>0 then FStatus.Caption:=FStatus.Caption+UiText('Power at 100%: ')+IntToStr(Round(ReferencePower))+UiText(' W')
  else FStatus.Caption:=FStatus.Caption+UiText('Timed mode · set power in Load settings when needed');
  for I:=0 to 3 do SelectMenuButton(FToolbar.FindComponent('WorkoutFilter'+IntToStr(I)) as TCastleButton,I=FFilter);
end;
function TTrainingPage.ReferencePower:Double;
var P:Integer;
begin Result:=0;if FTimed.Checked then Exit;if TryStrToInt(Trim(FBasePower.Text),P)and(P>=30)and(P<=1000)then Result:=P;end;
procedure TTrainingPage.ClickStart(Sender:TObject);
var W:TWorkoutFile;I:Integer;
begin I:=TComponent(Sender).Tag;if I<0 then W:=FSelected else if I<FItems.Count then W:=TWorkoutFile(FItems[I])else Exit;
  if W<>nil then ViewMenu.StartWorkout(W,ReferencePower,Pos('TrainingOnly',TComponent(Sender).Name)=1);end;
procedure TTrainingPage.ClickFavorite(Sender:TObject);
var I:Integer;
begin I:=TComponent(Sender).Tag;if(I>=0)and(I<FItems.Count)then ToggleWorkoutFavorite(TWorkoutFile(FItems[I]).Url);FRebuild:=True;end;
procedure TTrainingPage.ClickPower(Sender:TObject);
begin FPowerBar.Exists:=not FPowerBar.Exists;Layout;FRebuild:=True;end;
procedure TTrainingPage.ClickRider(Sender:TObject);
begin ViewMenu.OpenTab('rider');end;
function TTrainingPage.NewDetails(const Title:String):TCastleUserInterface;
var B:TMenuButton;S:Single;Scroll:TCastleScrollView;
begin
  ClickClose(nil);S:=Max(0.65,Min(1,UIScale));FDetails:=TCastleRectangleControl.Create(Self);FDetails.FullSize:=True;
  FDetails.Color:=MenuBackground;InsertFront(FDetails);
  B:=Btn(FDetails,FDetails,'WorkoutDetailsBack','Back',@ClickClose);B.Anchor(hpLeft,12/S);B.Anchor(vpTop,-12/S);
  FDetailsTitle:=Lbl(FDetails,FDetails,Title,140/S,18/S,21/S);
  Scroll:=TMenuScrollView.Create(FDetails);FDetailsScroll:=Scroll;Scroll.FullSize:=True;Scroll.Border.Top:=70/S;
  Scroll.Border.Bottom:=14/S;Scroll.Border.Left:=16/S;Scroll.Border.Right:=16/S;FDetails.InsertFront(Scroll);
  FDetailsContent:=TCastleUserInterface.Create(FDetails);FDetailsContent.Width:=Max(200,EffectiveWidth-48/S);
  FDetailsContent.Height:=760/S;Scroll.ScrollArea.InsertFront(FDetailsContent);Scroll.ScrollArea.Height:=FDetailsContent.Height;Result:=FDetailsContent;
  FDetailsActions:=TMenuFlow.Create(FDetails);FDetailsContent.InsertFront(FDetailsActions);
end;
procedure TTrainingPage.LayoutDetails;
var S,W,Y:Single;I:Integer;B:TCastleButton;
begin
  if FDetailsActions=nil then Exit;S:=Max(0.5,Min(1,UIScale));
  B:=FDetails.FindComponent('WorkoutDetailsBack')as TCastleButton;
  B.FontSize:=16/S;B.Anchor(hpLeft,12/S);B.Anchor(vpTop,-12/S);
  FDetailsTitle.FontSize:=21/S;FDetailsTitle.Anchor(hpLeft,140/S);FDetailsTitle.Anchor(vpTop,-18/S);
  FDetailsTitle.MaxWidth:=Max(100,EffectiveWidth-165/S);
  FDetailsScroll.Border.Top:=Max(70/S,FDetailsTitle.EffectiveHeight+32/S);
  FDetailsScroll.Border.Left:=16/S;FDetailsScroll.Border.Right:=16/S;
  W:=Max(200,EffectiveWidth-58/S);FDetailsContent.Width:=W;
  if FDetailsPreview<>nil then begin
    FDetailsPreview.Width:=W-16/S;FDetailsPreview.Height:=180/S;FDetailsPreview.Anchor(vpTop,-55/S);Y:=254/S;
  end else Y:=360/S;
  for I:=0 to FDetailsActions.ControlsCount-1 do
    TCastleButton(FDetailsActions.Controls[I]).FontSize:=16/S;
  FDetailsActions.Width:=W-16/S;FDetailsActions.Spacing:=16/S;
  FDetailsActions.Anchor(hpLeft,8/S);FDetailsActions.Anchor(vpTop,-Y);FDetailsActions.Arrange;
  Y:=Y+FDetailsActions.Height+26/S;
  if FDetailsDescription<>nil then begin
    FDetailsDescription.MaxWidth:=W-16/S;FDetailsDescription.FontSize:=16/S;
    FDetailsDescription.Anchor(vpTop,-Y);Y:=Y+FDetailsDescription.EffectiveHeight+26/S;
  end;
  FDetailsContent.Height:=Max(Y,460/S);FDetailsScroll.ScrollArea.Height:=FDetailsContent.Height;
end;

procedure TTrainingPage.ClickDetails(Sender:TObject);
var I:Integer;CopyPlan:TWorkoutFile;Panel:TCastleUserInterface;P:TWorkoutPreview;B:TMenuButton;S:Single;
begin
  I:=TComponent(Sender).Tag;if(I<0)or(I>=FItems.Count)then Exit;CopyPlan:=TWorkoutFile(FItems[I]).Clone;
  Panel:=NewDetails(CopyPlan.Name);FSelected:=CopyPlan;S:=Max(0.65,Min(1,UIScale));
  Lbl(FDetails,Panel,FormatWorkoutDuration(FSelected.TotalDuration),8,8,20/S);
  P:=TWorkoutPreview.Create(FDetails);FDetailsPreview:=P;P.LoadWorkout(FSelected);P.Width:=Panel.Width-20;P.Height:=180/S;
  P.FtpWatts:=Round(ReferencePower);
  P.Anchor(hpLeft,8);P.Anchor(vpTop,-55/S);Panel.InsertFront(P);
  B:=Btn(FDetails,FDetailsActions,'StartDetailedWorkout','Start',@ClickStart);B.Tag:=-1;B.Anchor(hpLeft,8);B.Anchor(vpTop,-254/S);
  B.Style:=mbPrimary;
  if ReferencePower<=0 then BindUiText(B,'Start timed intervals');
  B:=Btn(FDetails,FDetailsActions,'TrainingOnlyDetailedWorkout','Training focus',@ClickStart);B.Tag:=-1;
  B:=Btn(FDetails,FDetailsActions,'EditSelectedWorkout','Edit a copy',@ClickEdit);B.Anchor(hpLeft,260/S);B.Anchor(vpTop,-254/S);
  FDetailsDescription:=Lbl(FDetails,Panel,FSelected.Description,8,320/S,16/S);LayoutDetails;
end;
procedure TTrainingPage.ClickClose(Sender:TObject);
var Old:TCastleRectangleControl;
begin
  PageHidden;FillChar(FQuickFields,SizeOf(FQuickFields),0);
  Old:=FDetails;FDetails:=nil;
  if Old<>nil then begin Old.Exists:=False;RemoveControl(Old);ApplicationProperties.FreeDelayed(Old);end;
  FreeAndNil(FSelected);FDetailsContent:=nil;FDetailsScroll:=nil;FDetailsTitle:=nil;
  FDetailsPreview:=nil;FDetailsDescription:=nil;FDetailsActions:=nil;
end;
function TTrainingPage.HandleBack:Boolean;
begin Result:=FDetails<>nil;if Result then ClickClose(nil);end;
procedure TTrainingPage.ClickEdit(Sender:TObject);
begin if FSelected<>nil then begin ViewWorkoutEditor.SetWorkout(FSelected);ViewMenu.OpenChildView(ViewWorkoutEditor);end;end;
procedure TTrainingPage.ClickImport(Sender:TObject);
begin PickGameFile(Self,UiText('Import workout'),'ZWO|*.zwo',@ImportFile);end;
procedure TTrainingPage.ImportFile(const FileName:String);
var W:TWorkoutFile;Dest:String;
begin
  W:=TWorkoutFile.Create;
  try
    if not W.LoadFromUrl(FilenameToURISafe(FileName))then raise Exception.Create(UiText('Could not read this workout'));
    Dest:=UserDataDir+'workouts'+PathDelim+ExtractFileName(FileName);ForceDirectories(ExtractFileDir(Dest));
    if FileExists(Dest)then Dest:=ChangeFileExt(Dest,'')+'-'+FormatDateTime('yyyymmdd-hhnnss-zzz',Now)+'.zwo';
    if not W.SaveToUrl(FilenameToURISafe(Dest))then raise Exception.Create(UiText('Could not save this workout'));
    LoadItems;FFilter:=3;FSearch.Text:='';FRebuild:=True;
  finally W.Free;end;
end;
procedure TTrainingPage.ClickQuick(Sender:TObject);
const Captions:array[0..4]of String=('Repeats','Work, seconds','Recovery, seconds','Work, %','Recovery, %');
      Keys:array[0..4]of String=('interval_repeats','interval_work','interval_rest','interval_on','interval_off');
      Defaults:array[0..4]of String=('6','120','120','100','50');
var Panel:TCastleUserInterface;I:Integer;S:Single;B:TMenuButton;
begin
  Panel:=NewDetails(UiText('Create intervals'));S:=Max(0.65,Min(1,UIScale));
  for I:=0 to 4 do begin
    Lbl(FDetails,Panel,Captions[I],8,(16+I*54)/S,17/S);
    FQuickFields[I]:=TMenuEdit.Create(FDetails);FQuickFields[I].Name:='IntervalValue'+IntToStr(I);
    FQuickFields[I].Text:=UserPreference(Keys[I],Defaults[I]);FQuickFields[I].Width:=110/S;FQuickFields[I].FontSize:=17/S;
    FQuickFields[I].Anchor(hpLeft,230/S);FQuickFields[I].Anchor(vpTop,-(12+I*54)/S);Panel.InsertFront(FQuickFields[I]);
  end;
  Lbl(FDetails,Panel,'Includes 5 min warmup and 3 min cooldown',8,304/S,15/S).MaxWidth:=Panel.Width-24;
  B:=Btn(FDetails,FDetailsActions,'StartQuickIntervals','Start',@ClickQuickStart);B.Anchor(hpLeft,8);B.Anchor(vpTop,-360/S);
  B.Style:=mbPrimary;
  if ReferencePower<=0 then BindUiText(B,'Start timed intervals');
  B:=Btn(FDetails,FDetailsActions,'TrainingOnlyQuickIntervals','Training focus',@ClickQuickStart);
  B:=Btn(FDetails,FDetailsActions,'SaveQuickIntervals','Save template',@ClickQuickSave);B.Anchor(hpLeft,270/S);B.Anchor(vpTop,-360/S);LayoutDetails;
end;
function TTrainingPage.MakeQuick:TWorkoutFile;
var N,Work,Rest,OnPct,OffPct,I:Integer;S:TWorkoutSegment;Dest:String;
begin
  Result:=nil;
  if not TryStrToInt(FQuickFields[0].Text,N)or(N<1)or(N>100)or
    not TryStrToInt(FQuickFields[1].Text,Work)or(Work<1)or(Work>7200)or
    not TryStrToInt(FQuickFields[2].Text,Rest)or(Rest<1)or(Rest>7200)or
    not TryStrToInt(FQuickFields[3].Text,OnPct)or(OnPct<1)or(OnPct>300)or
    not TryStrToInt(FQuickFields[4].Text,OffPct)or(OffPct<1)or(OffPct>300)then raise Exception.Create(UiText('Check the interval values'));
  Result:=TWorkoutFile.Create;
  try
    Result.Name:=Format(UiText('Intervals %d × %s / %s'),[N,FormatWorkoutDuration(Work),FormatWorkoutDuration(Rest)]);Result.Category:=UiText('My workouts');
    S:=Result.AddSegment(wskWarmup);S.Duration:=300;S.PowerLow:=0.35;S.PowerHigh:=OffPct/100;
    for I:=1 to N do begin
      S:=Result.AddSegment(wskInterval);S.Duration:=Work;S.PowerLow:=OnPct/100;S.PowerHigh:=S.PowerLow;S.RepeatGroup:=1;S.IsOnPart:=True;
      S:=Result.AddSegment(wskInterval);S.Duration:=Rest;S.PowerLow:=OffPct/100;S.PowerHigh:=S.PowerLow;S.RepeatGroup:=1;S.IsOnPart:=False;
    end;
    S:=Result.AddSegment(wskCooldown);S.Duration:=180;S.PowerLow:=OffPct/100;S.PowerHigh:=0.3;
    Dest:=UserDataDir+'workouts'+PathDelim+'intervals-'+FormatDateTime('yyyymmdd-hhnnss-zzz',Now)+'.zwo';ForceDirectories(ExtractFileDir(Dest));
    if not Result.SaveToUrl(FilenameToURISafe(Dest))then raise Exception.Create(UiText('Could not save this workout'));
  except FreeAndNil(Result);raise;end;
end;
procedure TTrainingPage.ClickQuickStart(Sender:TObject);
var W:TWorkoutFile;
begin try W:=MakeQuick;try PageHidden;ViewMenu.StartWorkout(W,ReferencePower,Pos('TrainingOnly',TComponent(Sender).Name)=1);finally W.Free;end;
  except on E:Exception do Lbl(FDetails,FDetailsContent,E.Message,8,430,16);end;end;
procedure TTrainingPage.ClickQuickSave(Sender:TObject);
var W:TWorkoutFile;
begin try W:=MakeQuick;W.Free;PageHidden;ClickClose(nil);FFilter:=3;LoadItems;FRebuild:=True;
  except on E:Exception do Lbl(FDetails,FDetailsContent,E.Message,8,430,16);end;end;
procedure TTrainingPage.ClickDuration(Sender:TObject);
const Captions:array[0..3]of String=('Any duration','Up to 30 min','30–60 min','Over 60 min');
begin FPickerBar.Exists:=False;FDuration:=(FDuration+1)mod 4;BindUiText(FDurationButton,Captions[FDuration]);FLimit:=40;Layout;FRebuild:=True;end;

procedure TTrainingPage.RefreshLibrary;
begin LoadItems;FRebuild:=True;end;

end.
