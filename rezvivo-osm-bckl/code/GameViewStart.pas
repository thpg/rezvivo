unit GameViewStart;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses Classes,SysUtils,fpjson,CastleUIControls,CastleControls,GameMenuTile,GameMenuTheme;
type
  TStartPage=class(TMenuEmbeddedPage)
  private
    FEyebrow,FTitle,FHint:TCastleLabel;
    FCards:array[1..2]of TMenuPanel;
    FCardTitles,FCardHints:array[1..2]of TCastleLabel;
    FCardIcons,FCardArrows:array[1..2]of TMenuGlyph;
    FButtons:array[0..3]of TMenuButton;
    FRecovery:TJSONObject;
    FContinue,FFinishSaved:TMenuButton;
    procedure ClickContinue(Sender:TObject);
    procedure ClickFinishSaved(Sender:TObject);
    procedure ClickAction(Sender:TObject);
  public
    constructor Create(AOwner:TComponent);override;
    destructor Destroy;override;
    procedure PageShown;override;
    procedure Resize;override;
  end;
  THistoryPage=class(TMenuEmbeddedPage)
  private
    FScroll:TCastleScrollView;
    FContent:TCastleUserInterface;
    FOwner:TComponent;
    FItems:TJSONArray;
    FDetails:TJSONObject;
    FLastWidth:Single;
    procedure Build;
    procedure ClickItem(Sender:TObject);
    procedure ClickRepeat(Sender:TObject);
    procedure ClickBack(Sender:TObject);
    procedure ClickExport(Sender:TObject);
    procedure ClickExportFit(Sender:TObject);
    procedure ClickContinue(Sender:TObject);
    procedure ClickFinishSaved(Sender:TObject);
  public
    constructor Create(AOwner:TComponent);override;
    destructor Destroy;override;
    procedure PageShown;override;
    procedure ShowResult;
    procedure Resize;override;
    function HandleBack:Boolean;override;
  end;
implementation
uses Math,CastleVectors,CastleColors,CastleWindow,CastleURIUtils,CastleApplicationProperties,UiTranslations,
  CastleMessages,
  GameViewMenu,GameUserData,GameRideHistory,WorkoutFile,GameSensorLog,FitFile,
  RideUploadQueue,VeloSiteAPI;

constructor TStartPage.Create(AOwner:TComponent);
var I:Integer;
const Captions:array[0..3]of String=('Just ride','Intervals','Choose a route','Repeat last workout');
      Names:array[0..3]of String=('QuickRide','QuickIntervals','ChooseRoute','RepeatWorkout');
begin
  inherited;FullSize:=True;
  FEyebrow:=TMenuLabel.Create(Self);BindUiText(FEyebrow,'YOUR NEXT RIDE');FEyebrow.Color:=MenuMuted;InsertFront(FEyebrow);
  FTitle:=TMenuLabel.Create(Self);BindUiText(FTitle,'Where will you ride today?');FTitle.CustomFont:=MenuFont(True);InsertFront(FTitle);
  FHint:=TMenuLabel.Create(Self);BindUiText(FHint,'A ride, a workout, a new route. Start with what feels right.');FHint.Color:=MenuMuted;InsertFront(FHint);
  for I:=0 to 3 do begin
    FButtons[I]:=TMenuButton.Create(Self);FButtons[I].Name:=Names[I];FButtons[I].AutoSize:=False;
    FButtons[I].AutoIcon:=False;FButtons[I].Tag:=I;if I in [0,3]then BindUiText(FButtons[I],Captions[I]);
    FButtons[I].OnClick:=@ClickAction;
    if I in [1,2]then begin
      FCards[I]:=TMenuPanel.Create(Self);InsertFront(FCards[I]);
      FCardIcons[I]:=TMenuGlyph.Create(Self);FCardIcons[I].Color:=MenuAccent;
      if I=1 then FCardIcons[I].Kind:=mgTraining else FCardIcons[I].Kind:=mgWorld;
      FCards[I].InsertFront(FCardIcons[I]);
      FCardArrows[I]:=TMenuGlyph.Create(Self);FCardArrows[I].Kind:=mgArrow;FCards[I].InsertFront(FCardArrows[I]);
      FCardTitles[I]:=TMenuLabel.Create(Self);BindUiText(FCardTitles[I],Captions[I]);FCardTitles[I].CustomFont:=MenuFont(True);FCards[I].InsertFront(FCardTitles[I]);
      FCardHints[I]:=TMenuLabel.Create(Self);FCardHints[I].Color:=MenuMuted;
      if I=1 then BindUiText(FCardHints[I],'Ready workouts or your own')else BindUiText(FCardHints[I],'Real roads and dream worlds');
      FCards[I].InsertFront(FCardHints[I]);
      FButtons[I].Caption:='';FButtons[I].FullSize:=True;FButtons[I].CustomColorNormal:=Vector4(0,0,0,0);
      FButtons[I].CustomColorFocused:=Vector4(0.4,0.8,0.9,0.06);FButtons[I].CustomColorPressed:=Vector4(0.4,0.8,0.9,0.12);
      FCards[I].InsertFront(FButtons[I]);
    end else InsertFront(FButtons[I]);
  end;
  FButtons[0].Style:=mbPrimary;
  FButtons[3].Style:=mbGhost;
  FContinue:=TMenuButton.Create(Self);FContinue.Name:='ContinueSavedRide';FContinue.AutoSize:=False;
  BindUiText(FContinue,'Continue saved ride');FContinue.OnClick:=@ClickContinue;InsertFront(FContinue);
  FFinishSaved:=TMenuButton.Create(Self);FFinishSaved.Name:='FinishSavedRide';FFinishSaved.AutoSize:=False;
  BindUiText(FFinishSaved,'Finish saved ride');FFinishSaved.OnClick:=@ClickFinishSaved;InsertFront(FFinishSaved);
  FContinue.Exists:=False;FFinishSaved.Exists:=False;
end;
destructor TStartPage.Destroy;
begin FRecovery.Free;inherited;end;
procedure TStartPage.ClickContinue(Sender:TObject);
begin
  try if FRecovery<>nil then ViewMenu.ResumeActivity(FRecovery);
  except on E:Exception do MessageOK(Application.MainWindow,
    UiText('Continue saved ride')+': '+E.Message);end;
end;
procedure TStartPage.ClickFinishSaved(Sender:TObject);
begin
  try RideHistory.CompleteSaved(FRecovery);UploadQueue.Scan;PageShown;
  except on E:Exception do MessageOK(Application.MainWindow,
    UiText('Could not finish saved ride')+': '+E.Message);end;
end;
procedure TStartPage.PageShown;
begin
  inherited;FreeAndNil(FRecovery);
  if not ViewMenu.SessionUnderneath then FRecovery:=RideHistory.LatestUnfinished;
  FContinue.Exists:=FRecovery<>nil;FFinishSaved.Exists:=FRecovery<>nil;
  FButtons[3].Exists:=UserPreference('last_workout')<>'';Resize;
end;
procedure TStartPage.Resize;
var S,W,Top,TitleY,HintY,ButtonY,CardY,CardW:Single;I:Integer;
begin
  inherited;if FButtons[3]=nil then Exit;S:=Max(0.65,Min(1,UIScale));
  W:=Min(580/S,Max(360/S,(EffectiveWidth-48/S)*0.51));
  W:=Min(W,EffectiveWidth-48/S);Top:=Max(24/S,Min(96/S,EffectiveHeight*0.12));
  FEyebrow.FontSize:=12/S;FEyebrow.Anchor(hpLeft,24/S);FEyebrow.Anchor(vpTop,-Top);
  TitleY:=Top+38/S;
  FTitle.FontSize:=Min(52/S,W*0.115);FTitle.MaxWidth:=W;
  FTitle.Anchor(hpLeft,24/S);FTitle.Anchor(vpTop,-TitleY);
  HintY:=TitleY+FTitle.EffectiveHeight+24/S;
  FHint.FontSize:=16/S;FHint.MaxWidth:=W-8/S;FHint.Anchor(hpLeft,24/S);FHint.Anchor(vpTop,-HintY);
  ButtonY:=HintY+FHint.EffectiveHeight+28/S;
  if(FContinue<>nil)and FContinue.Exists then begin
    FContinue.Width:=(W-12/S)/2;FContinue.Height:=44/S;FContinue.FontSize:=15/S;
    FContinue.Anchor(hpLeft,24/S);FContinue.Anchor(vpTop,-ButtonY);
    FFinishSaved.Width:=FContinue.Width;FFinishSaved.Height:=44/S;FFinishSaved.FontSize:=15/S;
    FFinishSaved.Anchor(hpLeft,24/S+FContinue.Width+12/S);FFinishSaved.Anchor(vpTop,-ButtonY);
    ButtonY:=ButtonY+60/S;
  end;
  FButtons[0].Width:=Min(244/S,W);FButtons[0].Height:=54/S;FButtons[0].FontSize:=18/S;
  FButtons[0].Anchor(hpLeft,24/S);FButtons[0].Anchor(vpTop,-ButtonY);
  CardY:=ButtonY+88/S;CardW:=(W-16/S)/2;
  for I:=1 to 2 do begin
    FCards[I].Width:=CardW;FCards[I].Height:=168/S;
    FCards[I].Anchor(hpLeft,24/S+(I-1)*(CardW+16/S));FCards[I].Anchor(vpTop,-CardY);
    FCardIcons[I].Width:=26/S;FCardIcons[I].Height:=26/S;
    FCardIcons[I].Anchor(hpLeft,18/S);FCardIcons[I].Anchor(vpTop,-20/S);
    FCardArrows[I].Width:=20/S;FCardArrows[I].Height:=20/S;
    FCardArrows[I].Anchor(hpRight,-16/S);FCardArrows[I].Anchor(vpTop,-23/S);
    FCardTitles[I].FontSize:=16/S;FCardTitles[I].MaxWidth:=CardW-32/S;
    FCardTitles[I].Anchor(hpLeft,18/S);FCardTitles[I].Anchor(vpTop,-66/S);
    FCardHints[I].FontSize:=13/S;FCardHints[I].MaxWidth:=CardW-36/S;
    FCardHints[I].Anchor(hpLeft,18/S);FCardHints[I].Anchor(vpTop,-(66/S+FCardTitles[I].EffectiveHeight+12/S));
  end;
  FButtons[3].Width:=W;FButtons[3].Height:=44/S;FButtons[3].FontSize:=14/S;
  FButtons[3].Anchor(hpLeft,24/S);FButtons[3].Anchor(vpTop,-(CardY+190/S));
end;
procedure TStartPage.ClickAction(Sender:TObject);
begin case TComponent(Sender).Tag of
  0:ViewMenu.QuickRide;1:ViewMenu.OpenTab('intervals');2:ViewMenu.OpenTab('routes');3:ViewMenu.RepeatWorkout;
end;end;

constructor THistoryPage.Create(AOwner:TComponent);
var Bg:TCastleRectangleControl;
begin
  inherited;FullSize:=True;Bg:=TCastleRectangleControl.Create(Self);Bg.FullSize:=True;
  Bg.Color:=MenuBackground;InsertBack(Bg);
  FScroll:=TMenuScrollView.Create(Self);FScroll.FullSize:=True;FScroll.Border.AllSides:=16;InsertFront(FScroll);
  FContent:=TCastleUserInterface.Create(Self);FScroll.ScrollArea.InsertFront(FContent);
end;
destructor THistoryPage.Destroy;
begin FItems.Free;FDetails.Free;inherited;end;
procedure THistoryPage.PageShown;
begin inherited;FreeAndNil(FItems);FItems:=RideHistory.List;Build;end;
procedure THistoryPage.ShowResult;
begin FreeAndNil(FDetails);if RideHistory.LastResult<>nil then FDetails:=RideHistory.LastResult.Clone as TJSONObject;Build;end;
procedure THistoryPage.Resize;
begin inherited;if(FContent<>nil)and(Abs(FLastWidth-EffectiveWidth)>1)then Build;end;
procedure THistoryPage.Build;
var S,Y,W:Single;I,J:Integer;Journal,SyncText:String;Queue:TQueueItemArray;O:TJSONObject;B:TMenuButton;L:TCastleLabel;FS:TFormatSettings;
  procedure Text(const Value:String;Size:Single);
  begin L:=TMenuLabel.Create(FOwner);L.Caption:=Value;L.Color:=White;L.FontSize:=Size/S;L.MaxWidth:=W;
    L.Anchor(hpLeft,8);L.Anchor(vpTop,-Y);FContent.InsertFront(L);Y:=Y+Max(38/S,L.EffectiveHeight+16/S);end;
  function Action(const Name,Caption:String;Click:TNotifyEvent):TMenuButton;
  begin Result:=TMenuButton.Create(FOwner);Result.Name:=Name;BindUiText(Result,Caption);Result.FontSize:=17/S;
    Result.Anchor(hpLeft,8);Result.Anchor(vpTop,-Y);Result.OnClick:=Click;FContent.InsertFront(Result);Y:=Y+58/S;end;
begin
  if FScroll.EffectiveWidth<100 then Exit;FLastWidth:=EffectiveWidth;FContent.ClearControls;
  if FOwner<>nil then ApplicationProperties.FreeDelayed(FOwner);FOwner:=TComponent.Create(Self);
  S:=Max(0.65,Min(1,UIScale));W:=FScroll.EffectiveWidth-32/S;Y:=8/S;
  FS:=DefaultFormatSettings;FS.DecimalSeparator:='.';
  if FDetails<>nil then begin
    O:=FDetails;Text(O.Get('title',''),25);Text(O.Get('workout',''),20);
    Text(Format(UiText('%s · %.1f km · %.0f m ascent'),[FormatWorkoutDuration(O.Get('seconds',0.0)),O.Get('distance_m',0.0)/1000,O.Get('gain_m',0.0)]),20);
    if O.Get('has_power',False)then begin
      Text(Format(UiText('Average power: %.0f W'),[O.Get('avg_power',0.0)]),20);
      Text(FormatFloat('0.0',O.Get('work_j',0.0)/1000,FS)+' '+UiText('kJ this ride'),20);
      if O.Get('has_ftp',False)then Text('TSS '+FormatFloat('0.0',O.Get('tss',0.0),FS),20);
    end;
    if O.Get('save_error','')<>'' then Text(UiText('Could not save: ')+O.Get('save_error',''),16)
    else Text(UiText('Saved on this computer'),16);
    if not O.Get('complete',False)then Text(UiText('Recovered unfinished ride'),16);
    Journal:=O.Get('journal','');
    if Journal<>''then begin
      SyncText:=UiText('Sync pending');
      if not VeloSite.IsAuthorized then SyncText:=UiText('Sign in to upload this ride');
      Queue:=UploadQueue.Snapshot;
      for J:=0 to High(Queue)do if SameFileName(Queue[J].CsvPath,Journal)then
        case Queue[J].Status of
          usUploading:SyncText:=UiText('Syncing…');usDone:SyncText:=UiText('Synced');
          usFailedQuota,usFailedClient,usFailedServer:SyncText:=UiText('Sync needs attention');
        end;
      if not FileExists(Journal)and FileExists(ChangeFileExt(Journal,'.fit'))then SyncText:=UiText('Synced');
      Text(SyncText,16);
    end;
    if RideHistory.CanResume(O)then begin
      Action('ContinueActivity','Continue saved ride',@ClickContinue);
      Action('FinishSavedActivity','Finish saved ride',@ClickFinishSaved);
    end;
    Action('RepeatActivity','Repeat',@ClickRepeat);
    if(Journal<>'')and(FileExists(Journal)or FileExists(ChangeFileExt(Journal,'.fit')))then
      Action('ExportActivityFit','Export FIT',@ClickExportFit);
    Action('ExportActivity','Export result',@ClickExport);
    Action('BackToActivities','All rides',@ClickBack);
  end else begin
    Text(UiText('My rides'),28);
    if(FItems=nil)or(FItems.Count=0)then Text(UiText('Your completed rides will appear here'),18)
    else for I:=0 to FItems.Count-1 do begin
      O:=FItems.Objects[I];B:=Action('Activity'+IntToStr(I),O.Get('date','')+'  ·  '+O.Get('title','')+'  ·  '+FormatWorkoutDuration(O.Get('seconds',0.0)),@ClickItem);
      B.Tag:=I;B.AutoSize:=False;B.Width:=W;B.Height:=46/S;B.Caption:=MenuEllipsis(B.Caption,B.Font,W-32/S);
    end;
  end;
  FContent.Width:=W;FContent.Height:=Max(100,Y);FScroll.ScrollArea.Height:=FContent.Height;
end;
procedure THistoryPage.ClickItem(Sender:TObject);
var I:Integer;
begin I:=TComponent(Sender).Tag;if(I<0)or(FItems=nil)or(I>=FItems.Count)then Exit;
  FreeAndNil(FDetails);FDetails:=FItems.Objects[I].Clone as TJSONObject;Build;end;
procedure THistoryPage.ClickBack(Sender:TObject);
begin FreeAndNil(FDetails);Build;end;
function THistoryPage.HandleBack:Boolean;
begin Result:=FDetails<>nil;if Result then ClickBack(nil);end;
procedure THistoryPage.ClickRepeat(Sender:TObject);
begin if FDetails<>nil then ViewMenu.RepeatActivity(FDetails);end;
procedure THistoryPage.ClickContinue(Sender:TObject);
begin
  try if FDetails<>nil then ViewMenu.ResumeActivity(FDetails);
  except on E:Exception do MessageOK(Application.MainWindow,
    UiText('Continue saved ride')+': '+E.Message);end;
end;
procedure THistoryPage.ClickFinishSaved(Sender:TObject);
begin
  try RideHistory.CompleteSaved(FDetails);UploadQueue.Scan;FreeAndNil(FDetails);PageShown;
  except on E:Exception do MessageOK(Application.MainWindow,
    UiText('Could not finish saved ride')+': '+E.Message);end;
end;
procedure THistoryPage.ClickExport(Sender:TObject);
var Url,Text:String;F:TFileStream;
begin
  if FDetails=nil then Exit;Url:='ride-result.json';
  if not Application.MainWindow.FileDialog(UiText('Export result'),Url,False,'JSON|*.json')then Exit;
  Text:=FDetails.FormatJSON;F:=TFileStream.Create(URIToFilenameSafe(Url),fmCreate);
  try if Text<>''then F.WriteBuffer(Text[1],Length(Text));finally F.Free;end;
end;
procedure THistoryPage.ClickExportFit(Sender:TObject);
var Url,Journal,FitPath:String;Records:TSensorSessionRecordArray;Writer:TFitFileWriter;Src,Dst:TFileStream;
begin
  if FDetails=nil then Exit;Journal:=FDetails.Get('journal','');FitPath:=ChangeFileExt(Journal,'.fit');
  Url:='ride.fit';
  if not Application.MainWindow.FileDialog(UiText('Export FIT'),Url,False,'FIT|*.fit')then Exit;
  try
    Url:=URIToFilenameSafe(Url);
    if Url=''then raise Exception.Create(UiText('Choose a local file'));
    if (Journal<>'')and SameFileName(ExpandFileName(Journal),ExpandFileName(Url))then
      raise Exception.Create(UiText('Choose a different file name'));
    { A retained journal is authoritative: an older cached FIT may predate
      pause / interval export. Synced rides may only retain their FIT. }
    if FileExists(Journal)then begin
      Records:=TSensorLog.LoadSession(Journal);
      Writer:=TFitFileWriter.Create;
      try
        if not Writer.SaveToFile(Records,Url)then raise Exception.Create(Writer.ErrorText);
      finally Writer.Free;end;
    end else if FileExists(FitPath)then begin
      if not SameFileName(ExpandFileName(FitPath),ExpandFileName(Url))then begin
        Src:=TFileStream.Create(FitPath,fmOpenRead or fmShareDenyNone);
        try Dst:=TFileStream.Create(Url,fmCreate);try Dst.CopyFrom(Src,0);finally Dst.Free;end;finally Src.Free;end;
      end;
    end else raise Exception.Create(UiText('The ride file is missing'));
    if Sender is TMenuButton then BindUiText(TMenuButton(Sender),'FIT saved');
  except
    on E:Exception do MessageOK(Application.MainWindow,
      UiText('Could not export FIT')+': '+E.Message);
  end;
end;

end.
