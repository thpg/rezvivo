unit GameViewSchedule;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses Classes,SysUtils,CastleUIControls,CastleControls,GameMenuTile,
  GameMenuTheme,WorkoutFile;
type
  TSchedulePage=class(TMenuEmbeddedPage)
  private
    FScroll:TMenuScrollView;
    FContent:TCastleUserInterface;
    FOwner:TComponent;
    FPlan:TWorkoutFile;
    FKey,FDay,FError,FLanguage:String;
    FRevision:QWord;
    FWidth:Single;
    FOffset:Integer;
    procedure Build;
    procedure ClickEvent(Sender:TObject);
    procedure ClickStart(Sender:TObject);
    procedure ClickConnect(Sender:TObject);
    procedure ClickRefresh(Sender:TObject);
    procedure ClickWeek(Sender:TObject);
    procedure ClickBack(Sender:TObject);
  public
    constructor Create(AOwner:TComponent);override;
    destructor Destroy;override;
    procedure PageShown;override;
    procedure Resize;override;
    procedure Update(const SecondsPassed:Single;var HandleInput:Boolean);override;
    function HandleBack:Boolean;override;
  end;
procedure StartScheduledWorkout(const Key:String;TrainingOnly:Boolean);
implementation
uses Math,DateUtils,fpjson,CastleApplicationProperties,CastleWindow,CastleMessages,
  GameViewMenu,GameWorkoutSchedule,GameWorkoutPreview,GameUserData,VeloSiteAPI,UiTranslations;
type TScheduleEventButton=class(TMenuButton)
public
  EventKey:String;
end;

procedure StartScheduledWorkout(const Key:String;TrainingOnly:Boolean);
var W:TWorkoutFile;
begin
  W:=nil;
  try
    WorkoutSchedule.Tick;
    W:=WorkoutSchedule.LoadWorkout(WorkoutSchedule.Find(Key));
    if W=nil then begin
      MessageOK(Application.MainWindow,UiText('This calendar entry has no supported timed cycling workout.'));Exit;
    end;
    ViewMenu.StartWorkout(W,EffectiveRiderProfile.FtpW,TrainingOnly);
  except on E:Exception do MessageOK(Application.MainWindow,UiText('Could not start the scheduled workout')+': '+E.Message);end;
  W.Free;
end;
constructor TSchedulePage.Create(AOwner:TComponent);
begin
  inherited;FullSize:=True;
  FScroll:=TMenuScrollView.Create(Self);FScroll.FullSize:=True;
  FScroll.Border.AllSides:=16;InsertFront(FScroll);
  FContent:=TCastleUserInterface.Create(Self);FScroll.ScrollArea.InsertFront(FContent);
end;
destructor TSchedulePage.Destroy;
begin FPlan.Free;inherited;end;
procedure TSchedulePage.PageShown;
begin inherited;WorkoutSchedule.Tick;FDay:=ScheduleDay(Date);Build;end;
procedure TSchedulePage.Resize;
begin inherited;if(FContent<>nil)and(Abs(FWidth-EffectiveWidth)>1)then Build;end;
procedure TSchedulePage.Update(const SecondsPassed:Single;var HandleInput:Boolean);
begin
  inherited;
  if FDay<>ScheduleDay(Date)then begin FDay:=ScheduleDay(Date);FOffset:=0;FKey:='';end;
  if(FRevision<>WorkoutSchedule.Revision)or(FLanguage<>UiLanguage)then Build;
end;
function TSchedulePage.HandleBack:Boolean;
begin Result:=FKey<>'';if Result then begin FKey:='';FError:='';Build;end;end;
procedure TSchedulePage.ClickBack(Sender:TObject);
begin HandleBack;end;
procedure TSchedulePage.ClickConnect(Sender:TObject);
begin if VeloSite.IsAuthorized then ViewMenu.OpenTab('connectors')else ViewMenu.OpenTab('profile');end;
procedure TSchedulePage.ClickRefresh(Sender:TObject);
begin WorkoutSchedule.Refresh;Build;end;
procedure TSchedulePage.ClickWeek(Sender:TObject);
begin
  if TComponent(Sender).Tag=0 then FOffset:=0 else FOffset:=EnsureRange(FOffset+TComponent(Sender).Tag,-7,28);
  Build;
end;
procedure TSchedulePage.ClickEvent(Sender:TObject);
begin
  FKey:=TScheduleEventButton(Sender).EventKey;FError:='';Build;
end;
procedure TSchedulePage.ClickStart(Sender:TObject);
begin StartScheduledWorkout(FKey,TComponent(Sender).Tag=1);end;
procedure TSchedulePage.Build;
var S,W,Y:Single;L:TCastleLabel;B:TMenuButton;Flow:TMenuFlow;Preview:TWorkoutPreview;
    E:TJSONObject;A:TJSONArray;I,J,Count:Integer;Day,Caption:String;
  procedure Text(const Value:String;Size:Single;Muted:Boolean=False);
  begin
    L:=TMenuLabel.Create(FOwner);L.Caption:=Value;L.FontSize:=Size/S;L.MaxWidth:=W;
    if Muted then L.Color:=MenuMuted;
    L.Anchor(hpLeft,8/S);L.Anchor(vpTop,-Y);FContent.InsertFront(L);
    Y:=Y+Max(28/S,L.EffectiveHeight+12/S);
  end;
  procedure BeginActions;
  begin
    Flow:=TMenuFlow.Create(FOwner);Flow.WidthFraction:=0;Flow.Width:=W;
    Flow.Anchor(hpLeft,8/S);Flow.Anchor(vpTop,-Y);FContent.InsertFront(Flow);
  end;
  function Action(const Name,Caption:String;Click:TNotifyEvent):TMenuButton;
  begin
    Result:=TMenuButton.Create(FOwner);Result.Name:=Name;Result.FontSize:=15/S;
    BindUiText(Result,Caption);Result.OnClick:=Click;Flow.InsertFront(Result);
  end;
  procedure EndActions;
  begin Flow.Arrange;Y:=Y+Flow.EffectiveHeight+20/S;end;
begin
  if FScroll.EffectiveWidth<100 then Exit;
  FWidth:=EffectiveWidth;FRevision:=WorkoutSchedule.Revision;FLanguage:=UiLanguage;
  FContent.ClearControls;
  if FOwner<>nil then ApplicationProperties.FreeDelayed(FOwner);
  FOwner:=TComponent.Create(Self);FreeAndNil(FPlan);
  S:=Max(0.65,Min(1,UIScale));W:=FScroll.EffectiveWidth-32/S;Y:=8/S;
  Text(UiText('Training schedule'),28);
  Text(WorkoutSchedule.Status,14,True);
  if FError<>'' then Text(FError,14);
  BeginActions;
  B:=Action('ScheduleRefresh','Sync now',@ClickRefresh);B.Enabled:=(WorkoutSchedule.UserId>0)and not WorkoutSchedule.Busy;
  Action('ScheduleConnect','Intervals.icu connection',@ClickConnect);
  EndActions;
  E:=WorkoutSchedule.Find(FKey);
  if(FKey<>'')and(E=nil)then begin FKey:='';Text(UiText('This workout was removed or moved. The schedule has been refreshed.'),15);end;
  if E<>nil then begin
    Text(E.Get('date','')+' · '+E.Get('name',''),23);
    if WorkoutSchedule.Completed(E)then Text(UiText('Completed'),16,True);
    try FPlan:=WorkoutSchedule.LoadWorkout(E);
    except FPlan:=nil;end;
    if FPlan<>nil then begin
      Text(FormatWorkoutDuration(FPlan.TotalDuration)+' · TSS '+FormatFloat('0',FPlan.TSS),17);
      Preview:=TWorkoutPreview.Create(FOwner);Preview.Width:=W;Preview.Height:=130/S;
      Preview.FtpWatts:=Round(EffectiveRiderProfile.FtpW);Preview.LoadWorkout(FPlan);
      Preview.Anchor(hpLeft,8/S);Preview.Anchor(vpTop,-Y);FContent.InsertFront(Preview);Y:=Y+148/S;
      BeginActions;
      B:=Action('ScheduleStartRide','Start workout in a ride',@ClickStart);B.Style:=mbPrimary;
      B:=Action('ScheduleStartOnly','Workout only',@ClickStart);B.Tag:=1;
      EndActions;
    end else Text(UiText('This calendar entry has no supported timed cycling workout.'),16);
    BeginActions;Action('ScheduleBack','Back to schedule',@ClickBack);EndActions;
    if E.Get('description','')<>'' then Text(E.Get('description',''),15,True);
  end else begin
    Text(UiText('Planned cycling workouts. Changes are made in Intervals.icu.'),15,True);
    BeginActions;
    B:=Action('SchedulePrevious','Previous week',@ClickWeek);B.Tag:=-7;B.Enabled:=FOffset>-7;
    Action('ScheduleToday','Today',@ClickWeek);
    B:=Action('ScheduleNext','Next week',@ClickWeek);B.Tag:=7;B.Enabled:=FOffset<28;
    EndActions;
    A:=WorkoutSchedule.Items;
    for J:=0 to 6 do begin
      Day:=ScheduleDay(Date+FOffset+J);
      Caption:=FormatDateTime('dd.mm.yyyy',Date+FOffset+J);
      if Day=ScheduleDay(Date)then Caption:=UiText('Today')+' · '+Caption;
      Text(Caption,19);Count:=0;
      if A<>nil then for I:=0 to A.Count-1 do if A.Items[I] is TJSONObject then begin
        E:=A.Objects[I];if E.Get('date','')<>Day then Continue;Inc(Count);
        Caption:=E.Get('name','');
        if E.Get('duration',0)>0 then Caption:=Caption+' · '+FormatWorkoutDuration(E.Get('duration',0));
        if WorkoutSchedule.Completed(E)then Caption:=Caption+' · '+UiText('Completed');
        B:=TScheduleEventButton.Create(FOwner);B.Name:='ScheduleEvent'+IntToStr(E.Get('id',Int64(0)));
        B.AutoSize:=False;B.Width:=W;B.Height:=48/S;B.FontSize:=16/S;
        B.Caption:=MenuEllipsis(Caption,B.Font,W-32/S);TScheduleEventButton(B).EventKey:=WorkoutSchedule.EventKey(E);
        B.Anchor(hpLeft,8/S);B.Anchor(vpTop,-Y);B.OnClick:=@ClickEvent;
        FContent.InsertFront(B);Y:=Y+56/S;
      end;
      if Count=0 then Text(UiText('No workouts planned'),14,True);
      Y:=Y+10/S;
    end;
  end;
  FContent.Width:=W;FContent.Height:=Max(100,Y);FScroll.ScrollArea.Height:=FContent.Height;
end;
end.
