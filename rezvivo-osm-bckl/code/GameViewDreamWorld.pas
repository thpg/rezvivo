unit GameViewDreamWorld;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses GameMenuTheme, Classes,SysUtils,fpjson,CastleUIControls,CastleControls,CastleViewport,
  CastleScene,CastleVectors,CastleKeysMouse,GameMenuTile,Osm3dDreamWorld,
  GameDreamWorldScene,Osm3dRiderShadow,GameRideCarousel,GameRideMenuHeader,GameOfflineReadiness;
type
  TDreamPreview=class(TCastleViewport)
  private
    FScene:TCastleScene;
    FVisual:TDreamWorldVisual;
    FWorld:TDreamWorld;
    FShadow:TRiderShadowAtlas;
    FYaw,FPitch,FDistance:Single;
    FMaxShadow,FMaxRender,FMaxPrepare:QWord;
    FDrag:Boolean;
    FLast:TVector2;
    procedure PlaceCamera;
  public
    constructor Create(AOwner:TComponent);override;
    destructor Destroy;override;
    procedure SetWorld(World:TDreamWorld;Visual:TDreamWorldVisual=nil);
    procedure Render;override;
    procedure Update(const SecondsPassed:Single;var HandleInput:Boolean);override;
    function Press(const Event:TInputPressRelease):Boolean;override;
    function Release(const Event:TInputPressRelease):Boolean;override;
    function Motion(const Event:TInputMotion):Boolean;override;
  end;
  TDreamWorldPage=class(TMenuEmbeddedPage)
  private
    FFiles:TStringList;
    FOfflineTask:TOfflineReadinessTask;
    FOffline:TOfflineReadiness;
    FOfflineShown:Boolean;
    function WorldReady:Boolean;
  private
    FTask:TDreamVisualTask;
    FTaskIndex:Integer;
    FPreparedVisual:TDreamWorldVisual;
    FWorld:TDreamWorld;
    FPreview:TDreamPreview;
    FTitle,FInfo,FDescription,FStatus:TCastleLabel;
    FHeader:TRideMenuHeader;
    FSearch:TCastleEdit;
    FLoading:TCastleRectangleControl;
    FLoadingLabel:TCastleLabel;
    FCancel,FReload:TCastleButton;
    procedure ClickCancel(Sender:TObject);
    procedure ClickReload(Sender:TObject);
  private
    procedure FilterChanged(Sender:TObject);
  private
    FStart:TCastleButton;
    FCarousel:TRideCarousel;
    FSelected:Integer;
    FLoadCancelled:Boolean;
    FLastUpdate,FMaxGap:QWord;
    function WorldIndex(const Id:String):Integer;
    procedure SelectWorld(Sender:TObject);
    procedure BeginLoad;
    procedure StartTask;
    procedure ClickStart(Sender:TObject);
    procedure Layout;
  public
    AutoStart:Boolean;
    OnStartRide:TNotifyEvent;
    procedure SelectWorldId(const Id:String);
    constructor Create(AOwner:TComponent);override;
    destructor Destroy;override;
    procedure Resize;override;
    procedure PageShown;override;
    procedure PageHidden;override;
    procedure Update(const SecondsPassed:Single;var HandleInput:Boolean);override;
    function TakeWorld:TDreamWorld;
    function TakeVisual:TDreamWorldVisual;
    procedure SelectWorldIndex(Index:Integer;RememberSelection:Boolean=True);
    procedure CapturePreview(const FileName:string);
    function Diagnostics:TJSONObject;
    function SelectedManifest:string;
  end;
implementation
uses UiTranslations, Math,jsonparser,CastleCameras,CastleTransform,CastleColors,CastleURIUtils,CastleRectangles,CastleImages,Osm3dRoadMaterial,GameViewMenu,GameViewPlay,GameUserData;
constructor TDreamPreview.Create(AOwner:TComponent);
begin
  inherited;AutoCamera:=False;Items.UseHeadlight:=hlOff;
  Camera:=TCastleCamera.Create(Self);Items.Add(Camera);
  Camera.Perspective.FieldOfView:=Pi/4;
  Camera.ProjectionNear:=1;
  BackgroundColor:=Vector4(0.54,0.70,0.81,1);
  FScene:=TCastleScene.Create(Self);Items.Add(FScene);FShadow:=TRiderShadowAtlas.Create;
end;
destructor TDreamPreview.Destroy;
begin FShadow.Free;SetWorld(nil);inherited;end;
procedure TDreamPreview.SetWorld(World:TDreamWorld;Visual:TDreamWorldVisual);
var P:TVector3;
begin
  if FVisual<>nil then FVisual.Detach;FVisual:=Visual;FWorld:=World;FDrag:=False;
  Background:=nil;
  FMaxShadow:=0;FMaxRender:=0;FMaxPrepare:=0;
  if World=nil then Exit;
  Background:=FVisual.CoastalSky;
  FVisual.AttachTo(FScene,True);P:=World.PreviewPosition-World.PreviewTarget;
  FDistance:=P.Length;FYaw:=ArcTan2(P.Z,P.X);FPitch:=ArcSin(P.Y/FDistance);PlaceCamera;
end;
procedure TDreamPreview.PlaceCamera;
var P,T:TVector3;
begin
  if FWorld=nil then Exit;T:=FWorld.PreviewTarget;
  P:=T+Vector3(Cos(FYaw)*Cos(FPitch),Sin(FPitch),Sin(FYaw)*Cos(FPitch))*FDistance;
  Camera.SetWorldView(P,T-P,Vector3(0,1,0));
end;
procedure TDreamPreview.Render;
var Tick:QWord;
begin
  Tick:=GetTickCount64;
  if FWorld<>nil then begin
    FVisual.PrepareGL(Self);Background:=FVisual.CoastalSky;FMaxPrepare:=Max(FMaxPrepare,GetTickCount64-Tick);Tick:=GetTickCount64;FShadow.Casters.Clear;
    RoadMaterialRender(Camera.WorldTranslation);
    FShadow.WorldShadows:=True;FShadow.WorldCasters.Clear;FVisual.AppendShadowCasters(FShadow.WorldCasters);
    FShadow.Render(Self,FWorld.PreviewTarget,-FWorld.Sun,0.85);
    FMaxShadow:=Max(FMaxShadow,GetTickCount64-Tick);
  end;
  Tick:=GetTickCount64;inherited;FMaxRender:=Max(FMaxRender,GetTickCount64-Tick);
  if FVisual<>nil then FVisual.RecordRender(GetTickCount64-Tick);
end;
procedure TDreamPreview.Update(const SecondsPassed:Single;var HandleInput:Boolean);
begin inherited;if FVisual<>nil then FVisual.Update(SecondsPassed);end;
function TDreamPreview.Press(const Event:TInputPressRelease):Boolean;
var R:TFloatRectangle;
begin
  Result:=inherited;if FWorld=nil then Exit;
  R:=RenderRect;
  if(Event.Position.X<R.Left)or(Event.Position.X>R.Right)or
    (Event.Position.Y<R.Bottom)or(Event.Position.Y>R.Top)then Exit;
  if Event.IsMouseButton(buttonLeft)then begin FDrag:=True;FLast:=Event.Position;Exit(True);end;
  if Event.IsMouseWheel(mwUp)then begin FDistance:=Max(90,FDistance/1.18);PlaceCamera;Exit(True);end;
  if Event.IsMouseWheel(mwDown)then begin FDistance:=Min(1700,FDistance*1.18);PlaceCamera;Exit(True);end;
end;
function TDreamPreview.Release(const Event:TInputPressRelease):Boolean;
begin Result:=inherited;if Event.IsMouseButton(buttonLeft)then begin FDrag:=False;Result:=True;end;end;
function TDreamPreview.Motion(const Event:TInputMotion):Boolean;
begin
  Result:=inherited;if not FDrag then Exit;
  FYaw:=FYaw-(Event.Position.X-FLast.X)*0.006;
  FPitch:=EnsureRange(FPitch-(Event.Position.Y-FLast.Y)*0.004,0.08,1.42);
  FLast:=Event.Position;PlaceCamera;Result:=True;
end;
constructor TDreamWorldPage.Create(AOwner:TComponent);
var Bg:TCastleRectangleControl;I:Integer;J:TJSONData;F:TFileStream;WorldTitle,Thumb,Info:string;Route:TJSONData;
begin
  inherited;FullSize:=True;FSelected:=0;
  Bg:=TCastleRectangleControl.Create(Self);Bg.FullSize:=True;Bg.Color:=MenuBackground;InsertBack(Bg);
  FPreview:=TDreamPreview.Create(Self);FPreview.FullSize:=True;FPreview.Border.Left:=12;
  FPreview.Border.Top:=340;FPreview.Border.Bottom:=65;FPreview.Border.Right:=12;InsertFront(FPreview);
  FTitle:=TMenuLabel.Create(Self);BindUiText(FTitle, 'Dream World');FTitle.FontSize:=30;FTitle.Color:=White;
  FTitle.Anchor(hpLeft,20);FTitle.Anchor(vpTop,-20);InsertFront(FTitle);
  FInfo:=TMenuLabel.Create(Self);FInfo.FontSize:=22;FInfo.Color:=White;FInfo.Anchor(hpLeft,16);FInfo.Anchor(vpTop,-266);InsertFront(FInfo);
  FDescription:=TMenuLabel.Create(Self);FDescription.FontSize:=16;FDescription.Color:=Vector4(0.78,0.85,0.9,1);
  FDescription.Anchor(hpLeft,16);FDescription.Anchor(vpTop,-302);InsertFront(FDescription);
  FStatus:=TMenuLabel.Create(Self);FStatus.FontSize:=15;FStatus.Color:=White;FStatus.Anchor(hpLeft,16);FStatus.Anchor(vpBottom,22);InsertFront(FStatus);
  FTitle.Exists:=False;FInfo.Exists:=False;
  FHeader:=TRideMenuHeader.Create(Self);FHeader.Anchor(vpTop);InsertFront(FHeader);
  FHeader.SetSelection(UiText('Choose a world'),UiText('Click a card to select a ride'),False);
  FStart:=FHeader.StartButton;FStart.OnClick:=@ClickStart;
  FSearch:=TMenuEdit.Create(Self);FSearch.Name:='DreamWorldSearch';
  FSearch.Text:='';BindUiText(FSearch,'Search worlds','Placeholder');FSearch.OnChange:=@FilterChanged;InsertFront(FSearch);
  FLoading:=TCastleRectangleControl.Create(Self);FLoading.FullSize:=True;
  FLoading.Color:=Vector4(0.055,0.078,0.105,1);FPreview.InsertFront(FLoading);
  FLoadingLabel:=TMenuLabel.Create(Self);FLoadingLabel.Color:=White;
  FLoadingLabel.FontSize:=18;FLoadingLabel.Anchor(hpMiddle);FLoadingLabel.Anchor(vpMiddle);
  FLoading.InsertFront(FLoadingLabel);
  FCancel:=TMenuButton.Create(Self);FCancel.Name:='CancelWorldPreparation';BindUiText(FCancel,'Cancel preparation');
  FCancel.Anchor(hpRight,-16);FCancel.Anchor(vpBottom,16);FCancel.OnClick:=@ClickCancel;InsertFront(FCancel);
  FReload:=TMenuButton.Create(Self);FReload.Name:='RetryWorldPreparation';BindUiText(FReload,'Retry');
  FReload.Anchor(hpRight,-16);FReload.Anchor(vpBottom,68);FReload.OnClick:=@ClickReload;FReload.Exists:=False;InsertFront(FReload);
  FCarousel:=TRideCarousel.Create(Self);FCarousel.Name:='DreamCarousel';
  FCarousel.Anchor(hpLeft);FCarousel.Anchor(vpTop,-54);FCarousel.OnChange:=@SelectWorld;InsertFront(FCarousel);
  FFiles:=DreamWorldFiles(URIToFilenameSafe('castle-data:/dream-worlds/'));
  for I:=0 to FFiles.Count-1 do begin
    WorldTitle:=ExtractFileName(ExcludeTrailingPathDelimiter(ExtractFileDir(FFiles[I])));J:=nil;Info:='';
    try
      F:=TFileStream.Create(FFiles[I],fmOpenRead or fmShareDenyWrite);
      try J:=GetJSON(F);if J is TJSONObject then begin
        WorldTitle:=TJSONObject(J).Get('title',WorldTitle);Route:=TJSONObject(J).Find('route');
        if Route is TJSONObject then Info:=Format(UiText('Loop %.1f km'),[TJSONObject(Route).Get('length_m',0.0)/1000]);
      end;finally F.Free;end;
    except end;J.Free;
    Thumb:=IncludeTrailingPathDelimiter(ExtractFileDir(FFiles[I]))+'preview.png';
    if not FileExists(Thumb)then Thumb:='';
    FCarousel.AddItem(WorldTitle,Info,Thumb);
  end;
  FSelected:=WorldIndex(UserPreference('last_world',DefaultDreamWorldId));
  FCarousel.Select(FSelected);
  if FFiles.Count=0 then BindUiText(FStatus, 'No worlds in data/dream-worlds yet.');
  Layout;
end;

procedure TDreamWorldPage.Layout;
var WheelWidth,RightLeft,Scale:Single;
begin
  if(FCarousel=nil)or(EffectiveWidth<=0)then Exit;
  Scale:=Min(1,Max(0.65,UIScale));
  WheelWidth:=Min(EffectiveWidth*0.32,350/Scale);RightLeft:=WheelWidth+24;
  FSearch.Width:=WheelWidth-8;FSearch.Height:=34/Scale;FSearch.FontSize:=15/Scale;
  FSearch.Anchor(hpLeft,8);FSearch.Anchor(vpTop,-94/Scale);
  FCarousel.Width:=WheelWidth;FCarousel.Height:=Max(120,EffectiveHeight-140/Scale-16);
  FCarousel.Anchor(hpLeft,8);FCarousel.Anchor(vpTop,-140/Scale);
  FInfo.MaxWidth:=Max(120,EffectiveWidth-RightLeft-16);
  FDescription.Anchor(hpLeft,RightLeft);FDescription.Anchor(vpTop,-98/Scale);
  FDescription.FontSize:=15/Scale;
  FDescription.MaxWidth:=FInfo.MaxWidth;
  FPreview.Border.Left:=RightLeft;FPreview.Border.Top:=Max(140/Scale,108/Scale+FDescription.EffectiveHeight);
  FPreview.Border.Bottom:=52/Scale;
  FStatus.Anchor(hpLeft,RightLeft);FStatus.Anchor(vpBottom,10/Scale);
  FStatus.FontSize:=13/Scale;FStatus.MaxWidth:=Max(100,EffectiveWidth-RightLeft-16);
  FLoadingLabel.FontSize:=18/Scale;FLoadingLabel.MaxWidth:=Max(100,EffectiveWidth-RightLeft-64);
end;

procedure TDreamWorldPage.FilterChanged(Sender:TObject);
begin FCarousel.SetFilter(FSearch.Text);end;

procedure TDreamWorldPage.Resize;
begin inherited;Layout;end;
destructor TDreamWorldPage.Destroy;
begin
  if FOfflineTask<>nil then begin FOfflineTask.Abandon;FOfflineTask:=nil end;
  FTask.Free;FPreview.SetWorld(nil);FPreparedVisual.Free;FWorld.Free;FFiles.Free;inherited;
end;
procedure TDreamWorldPage.BeginLoad;
begin
  if FOfflineTask<>nil then begin FOfflineTask.Abandon;FOfflineTask:=nil end;
  FOffline:=Default(TOfflineReadiness);
  FOfflineShown:=False;
  if FTask<>nil then FTask.Terminate;
  FPreview.SetWorld(nil);FreeAndNil(FPreparedVisual);FreeAndNil(FWorld);FStart.Enabled:=False;
  FLoadCancelled:=False;FMaxGap:=0;FLastUpdate:=GetTickCount64;
  if(FSelected<0)or(FSelected>=FFiles.Count)then Exit;
  FOfflineTask:=TOfflineReadinessTask.CreateDream(FFiles[FSelected]);
  FHeader.SetSelection(FCarousel.ItemTitle(FSelected),FCarousel.ItemInfo(FSelected),False);
  FHeader.SetRideState(ViewMenu.RideUnderneath,False);
  FLoading.Exists:=True;FReload.Exists:=False;BindUiText(FLoadingLabel,'Loading world…');
  BindUiText(FStatus, 'Loading world…');FInfo.Caption:='';FDescription.Caption:='';
  if FTask=nil then StartTask;
end;
procedure TDreamWorldPage.StartTask;
begin
  { At most one worker. Obsolete jobs are cancelled and reaped after Done;
    changing selection never WaitFor's on the UI thread. }
  FTaskIndex:=FSelected;FTask:=TDreamVisualTask.Create(FFiles[FTaskIndex]);FTask.Start;
end;
procedure TDreamWorldPage.SelectWorld(Sender:TObject);
begin SelectWorldIndex(FCarousel.Selected);end;
procedure TDreamWorldPage.SelectWorldIndex(Index:Integer;RememberSelection:Boolean);
begin
  if(Index<0)or(Index>=FFiles.Count)then raise Exception.Create('Invalid Dream World index');
  if RememberSelection then
    RememberRideMap(rmkDream,ExtractFileName(ExtractFileDir(FFiles[Index])));
  if(Index=FSelected)and((FWorld<>nil)or(FTask<>nil))then Exit;
  FSelected:=Index;
  FCarousel.Select(Index);
  BeginLoad;
end;
function TDreamWorldPage.WorldIndex(const Id:String):Integer;
var I:Integer;
begin
  Result:=-1;
  for I:=0 to FFiles.Count-1 do
    if SameText(ExtractFileName(ExtractFileDir(FFiles[I])),Id)then Exit(I);
  for I:=0 to FFiles.Count-1 do
    if SameText(ExtractFileName(ExtractFileDir(FFiles[I])),DefaultDreamWorldId)then Exit(I);
  if FFiles.Count>0 then Result:=0;
end;
procedure TDreamWorldPage.SelectWorldId(const Id:String);
var I:Integer;
begin
  I:=WorldIndex(Id);if I>=0 then SelectWorldIndex(I);
end;
procedure TDreamWorldPage.PageShown;
var I:Integer;
begin
  inherited;FLastUpdate:=GetTickCount64;
  { Restoring this tab must not replace the last map chosen in Real World. }
  I:=WorldIndex(UserPreference('last_world',DefaultDreamWorldId));
  if(I>=0)and(I<>FSelected)then SelectWorldIndex(I,False);
  FHeader.SetRideState(ViewMenu.RideUnderneath,(FWorld<>nil)and
    (ViewPlay.DreamWorld<>nil)and(FWorld.Id=ViewPlay.DreamWorld.Id));
  if FLoadCancelled or((FWorld=nil)and(FTask=nil))then BeginLoad;
  if(FWorld<>nil)and not FOffline.Done and(FOfflineTask=nil)then
    FOfflineTask:=TOfflineReadinessTask.CreateDream(FFiles[FSelected]);
end;
procedure TDreamWorldPage.PageHidden;
begin
  if FOfflineTask<>nil then begin FOfflineTask.Abandon;FOfflineTask:=nil end;
  inherited;AutoStart:=False;FCarousel.CancelGesture;if FTask<>nil then begin FLoadCancelled:=True;FTask.Terminate;end;
end;
procedure TDreamWorldPage.Update(const SecondsPassed:Single;var HandleInput:Boolean);
begin
  inherited;
  if FOfflineTask<>nil then begin
    FOffline:=FOfflineTask.Snapshot;
    if FOffline.Done then FreeAndNil(FOfflineTask);
  end;
  if FLastUpdate<>0 then FMaxGap:=Max(FMaxGap,GetTickCount64-FLastUpdate);
  FLastUpdate:=GetTickCount64;
  if(FTask<>nil)and FTask.Done then begin
    if (FTaskIndex<>FSelected) or FLoadCancelled or FTask.Cancelled then begin
      FreeAndNil(FTask);
      if not FLoadCancelled then StartTask;
      Exit;
    end;
    FWorld:=FTask.Take;
    if FWorld<>nil then begin
      FPreparedVisual:=FTask.TakeVisual;
      FPreview.SetWorld(FWorld,FPreparedVisual);FInfo.Caption:=FWorld.Title+UiText('  ·  Lap ')+FormatFloat('0',FWorld.LengthM)+UiText(' m');
      FDescription.Caption:=FWorld.Description;
      Layout;
      BindUiText(FStatus, 'Preparing the view…');
    end else begin FStatus.Caption:=UiText('Could not load world: ')+FTask.Error;FReload.Exists:=True;end;
    FreeAndNil(FTask);
  end;
  if WorldReady and not FStart.Enabled then begin
    FHeader.SetSelection(FWorld.Title,Format(UiText('Loop %.1f km'),[FWorld.LengthM/1000]),True);
    FHeader.SetRideState(ViewMenu.RideUnderneath,(ViewPlay.DreamWorld<>nil)and
      (FWorld.Id=ViewPlay.DreamWorld.Id));
    FLoading.Exists:=False;BindUiText(FStatus, 'Rotate: left mouse button  ·  Zoom: mouse wheel');
  end;
  if FLoading.Exists then FLoadingLabel.Caption:=FStatus.Caption;
  if WorldReady and FOffline.Done and not FOfflineShown then begin
    FStatus.Caption:=FOffline.Caption;FOfflineShown:=True;
  end;
  FCancel.Exists:=AutoStart;
  if AutoStart and WorldReady then begin AutoStart:=False;ClickStart(nil);end;
end;
function TDreamWorldPage.WorldReady:Boolean;
begin Result:=(FWorld<>nil)and(FPreparedVisual<>nil)and FPreparedVisual.Ready;end;
procedure TDreamWorldPage.ClickStart(Sender:TObject);
begin if WorldReady and Assigned(OnStartRide)then OnStartRide(Self);end;
function TDreamWorldPage.TakeWorld:TDreamWorld;
begin
  if not WorldReady then raise Exception.Create('Dream World is not ready');
  FPreview.SetWorld(nil);Result:=FWorld;FWorld:=nil;FStart.Enabled:=False;
end;
function TDreamWorldPage.TakeVisual:TDreamWorldVisual;
begin Result:=FPreparedVisual;FPreparedVisual:=nil;end;
function TDreamWorldPage.Diagnostics:TJSONObject;
var A:TJSONArray;I:Integer;
begin
  Result:=TJSONObject.Create(['worlds',FFiles.Count,'selected',FSelected,'loading',(FTask<>nil)or((FWorld<>nil)and not WorldReady),'ready',WorldReady]);
  A:=TJSONArray.Create;for I:=0 to FFiles.Count-1 do
    A.Add(ExtractFileName(ExcludeTrailingPathDelimiter(ExtractFileDir(FFiles[I]))));
  Result.Add('max_frame_gap_ms',FMaxGap);
  Result.Add('max_render_ms',FPreview.FMaxRender);Result.Add('max_shadow_ms',FPreview.FMaxShadow);Result.Add('max_prepare_ms',FPreview.FMaxPrepare);
  Result.Add('status',FStatus.Caption);
  Result.Add('offline_ready',FOffline.Ready);
  Result.Add('offline_missing',FOffline.Missing);
  Result.Add('catalog',A);
  Result.Add('carousel',FCarousel.Diagnostics);
  Result.Add('preview_rect',TJSONArray.Create([FPreview.RenderRect.Left,FPreview.RenderRect.Bottom,FPreview.RenderRect.Width,FPreview.RenderRect.Height]));
  if FWorld<>nil then Result.Add('world',FWorld.Diagnostics);
  if FPreview.FVisual<>nil then Result.Add('visual',FPreview.FVisual.Diagnostics);
  Result.Add('shadow',FPreview.FShadow.DebugInfo);
  Result.Add('coastal_sky',FPreview.Background<>nil);
end;
procedure TDreamWorldPage.CapturePreview(const FileName:string);
var Img:TRGBImage;
begin
  if not WorldReady or not Exists then raise Exception.Create('Dream preview is not ready');
  Img:=Container.SaveScreen(FPreview.RenderRect);
  try
    Img.Resize(512,Max(1,Round(Img.Height*512/Img.Width)));
    SaveImage(Img,FilenameToURISafe(FileName));
  finally Img.Free;end;
  FCarousel.SetImage(FSelected,FileName);
end;
procedure TDreamWorldPage.ClickCancel(Sender:TObject);
begin ViewMenu.OpenTab('home');end;
procedure TDreamWorldPage.ClickReload(Sender:TObject);
begin if FTask=nil then BeginLoad;end;

function TDreamWorldPage.SelectedManifest:string;
begin
  Result:='';if(FSelected>=0)and(FSelected<FFiles.Count)then Result:=FFiles[FSelected];
end;
end.
