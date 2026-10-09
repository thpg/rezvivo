{ MCP-сервер (Model Context Protocol, stdio-транспорт) для rezvivo-osm-bckl.

  Активируется ТОЛЬКО параметром командной строки --mcp-stdio. Без флага
  InitMcpServer ничего не делает и приложение работает как раньше.

  Что экспонируется:
    • объекты: window, все view-синглтоны (view.play, view.menu, ...),
      devices (DeviceService), settings (AppSettings.Settings) — доступ
      ко всем published-свойствам через built-in инструменты
      objects_list / object_describe / property_get / property_set;
    • команды: app.views_list, app.switch_view (имена devices/bikefit/
      events — не вью, а встроенные вкладки меню: команда переключает
      на ViewMenu и открывает вкладку через ViewMenu.OpenTab).

  Маршаллинг MCP-команд в главный поток (McpBridge.McpRunTask)
  требует прокачки TThread.Queue через CheckSynchronize. CGE сам её не
  вызывает, поэтому здесь поднимается СВОЙ обработчик
  ApplicationProperties.OnUpdate (так же, как TGameDeviceService) —
  чтобы MCP не завис от состояния BLE-сканирования. }
unit GameMcpServer;

{$mode objfpc}{$H+}

interface

uses fpjson;

{ Explicit, non-persistent same-user attach. Status is for local UI only;
  endpoint/command are deliberately not exposed as public MCP properties. }
function EnableLocalMcp(out Error:string):Boolean;
procedure DisableLocalMcp;
function LocalMcpStatus:TJSONObject;

{ Инициализация MCP-режима. Без --mcp-stdio в командной строке — no-op.
  Вызывать в конце ApplicationInitialize, когда views уже созданы. }
procedure InitMcpServer;

{ Остановка MCP-сервера и снятие подписок. Вызывать из finalization. }
procedure ShutdownMcpServer;

{ Публикация/снятие объектов play-сессии ('world', 'bike', 'osm',
  'camera') — вызывается из TViewPlay.Start / TViewPlay.Stop.
  No-op, если MCP не активен или соответствующий менеджер ещё/уже nil. }
procedure McpRegisterPlayObjects;
procedure McpUnregisterPlayObjects;

implementation

uses GameTravel,GameGraphicsBenchmarkScene,GameAssistant,GameAssistantMcp,GameAssistantUI,GameAssistantVoice,GameMcpNavigation,
  GameWorkoutPlayer, GameClientUpdate, GameAudio, GamePerformanceProbe, GameScreenFX, GameFarFieldProbe,
  Osm3dBuildingObstacleIndex, Osm3dRoadMaterial, Osm3dRoadCurbs, Osm3dGeoMath, Osm3dStreamingMap, Osm3dImpostorCache,
  Classes, SysUtils, Math, base64,
  CastleWindow, CastleUIControls, CastleControls, CastleApplicationProperties, CastleImages,
  CastleVectors, CastleCameras, CastleGLShaders, CastleGLUtils, CastleLog, CastleRendererInternalShader,
  CastleScene, CastleTransform, X3DNodes, X3DFields, CastleRenderOptions,
  McpRegistry, McpStdio, McpLocalPipe, McpPhotoTools, McpPhotoViewTools, Osm3dStreamingLauncher, CastleViewport,
  AppSettings, GameDeviceService, GameSimCameraTrack, GameMotionTrace, GameCinematicCamera, Osm3dRoadPuddles,
  BikeParametric, RiderPoseCatalog, RiderAttention, GameBikeAvatar, GamePath, GamePhysicsCommon, GamePhysicsBase, Osm3dRiderShadow, Osm3dRenderInstanced, Osm3dStudioSettings,
  Osm3dProceduralVegetation, TreeSeason, TreeRenderer, GrassRenderer,
  GameViewMenu, GameViewPlay,GameViewTrainingOnly,
  GameViewFreeRide,
  GameWorld, GamePhysicalAgent, GameBikeShaderDiagnostics,
  GameViewWorkoutEditor,
  GameViewMapEditor, GameViewLogin,
  GameViewBikeFit;

type
  { Объект-«клей»: TNotifyEventList и OnEndOfStream требуют method
    pointers (of object), поэтому обработчики живут на этом экземпляре. }
  TMcpGlue = class
    { Прокачка CheckSynchronize каждый кадр — иначе McpRunTask
      будет ждать до таймаута. }
    procedure UpdatePump(Sender: TObject);
    procedure BeforePipeDispatch(Sender:TObject);
    { EOF на stdin (MCP-хост закрыл pipe) → завершаем приложение. }
    procedure EndOfStream(Sender: TObject);
  end;

  TViewReg = record
    ShortName: String;   { 'play', 'menu', ... (без префикса 'view.') }
    View: TCastleView;
  end;

var
  McpActive: Boolean = False;
  Server: TMcpStdioServer = nil;
  LocalServer:TMcpLocalPipeServer=nil;
  LocalSeenGeneration,LocalSeenRevision,LocalRevision:QWord;
  LocalWasConnected:Boolean=False;
  LocalError:string='';
  Glue: TMcpGlue = nil;
  ViewRegs: array of TViewReg;
  PerformanceProbe: TGamePerformanceProbe = nil;
  PhotoComparisonMode: Boolean = False;
  PhotoPreviousCameraMode: TPlayCameraMode;

procedure PhotoViewContext(out V:TCastleViewport; out S:TOsm3dStreamingSession);
begin
  if (ViewPlay=nil) or not ViewPlay.SessionAlive or (ViewPlay.Osm=nil) or
    (ViewPlay.Osm.Session=nil) or (Application.MainWindow.Container.View<>ViewPlay) then
    raise Exception.Create('Photo comparison requires an active real-world ride');
  V:=ViewPlay.MainViewport; S:=ViewPlay.Osm.Session;
end;

procedure PhotoViewMode(EnterComparison:Boolean);
begin
  if EnterComparison then begin
    if not PhotoComparisonMode then PhotoPreviousCameraMode:=ViewPlay.CameraMode;
    ViewPlay.SetCameraMode(pcmFree); PhotoComparisonMode:=True;
  end else if PhotoComparisonMode then begin
    ViewPlay.SetCameraMode(PhotoPreviousCameraMode); PhotoComparisonMode:=False;
  end;
end;

function McpModeRequested: Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to ParamCount do
    if ParamStr(I) = '--mcp-stdio' then
      Exit(True);
end;

procedure SyncLocalPeer;
var S:TMcpLocalPipeStatus;
begin
  if LocalServer=nil then Exit;
  S:=LocalServer.Status;
  if S.Revision<>LocalSeenRevision then begin
    LocalSeenRevision:=S.Revision;Inc(LocalRevision);
  end;
  if (S.Generation<>LocalSeenGeneration) or (LocalWasConnected and not S.ClientConnected) then begin
    Assistant.Disconnect;EndAssistantVoiceSession;
  end;
  LocalSeenGeneration:=S.Generation;LocalWasConnected:=S.ClientConnected;
  Assistant.SetTransportAvailable(S.Enabled);
  if S.Error<>'' then LocalError:=S.Error;
end;

procedure TMcpGlue.BeforePipeDispatch(Sender:TObject);
begin
  { The transport checks that the client is still connected first. Update the
    identity generation before any handler can use a previous agent token. }
  SyncLocalPeer;
end;

procedure TMcpGlue.UpdatePump(Sender: TObject);
begin
  SyncAssistantContext;
  SyncLocalPeer;
  if (LocalServer<>nil) and LocalServer.Finished then begin
    FreeAndNil(LocalServer);Inc(LocalRevision);
  end;
  CheckSynchronize;
  UpdateAssistantVoice;
end;

procedure TMcpGlue.EndOfStream(Sender: TObject);
begin
  StopAssistantMcp;
  Application.Terminate;
end;

{ Регистрирует view под именем 'view.<AShortName>' и запоминает в
  ViewRegs для команд app.views_list / app.switch_view.
  nil-view (например, несозданный ViewFreeRide) пропускается. }
procedure RegisterView(const AShortName: String; AView: TCastleView);
var
  N: Integer;
begin
  if AView = nil then Exit;
  RegisterMcpObject('view.' + AShortName, AView);
  N := Length(ViewRegs);
  SetLength(ViewRegs, N + 1);
  ViewRegs[N].ShortName := AShortName;
  ViewRegs[N].View := AView;
end;

function FindViewByName(const AName: String): TCastleView;
var
  I: Integer;
  S: String;
begin
  S := LowerCase(Trim(AName));
  if Pos('view.', S) = 1 then
    Delete(S, 1, Length('view.'));
  for I := 0 to High(ViewRegs) do
    if ViewRegs[I].ShortName = S then
      Exit(ViewRegs[I].View);
  Result := nil;
end;

function ActiveViewName: String;
var
  I: Integer;
  Cur: TCastleView;
begin
  Result := '';
  if (Application.MainWindow = nil) or
     (Application.MainWindow.Container = nil) then
    Exit;
  Cur := Application.MainWindow.Container.PendingFrontView;
  if Cur = nil then Exit;
  for I := 0 to High(ViewRegs) do
    if ViewRegs[I].View = Cur then
      Exit(ViewRegs[I].ShortName);
  Result := Cur.Name;  { активный view не из зарегистрированных }
end;

procedure CmdViewsList(const AParams: TJSONObject; AResult: TJSONObject);
var
  Arr: TJSONArray;
  I: Integer;
begin
  Arr := TJSONArray.Create;
  for I := 0 to High(ViewRegs) do
    Arr.Add(ViewRegs[I].ShortName);
  AResult.Add('views', Arr);
  AResult.Add('active', ActiveViewName);
  AResult.Add('stack_count', Application.MainWindow.Container.CurrentViewStackCount);
  AResult.Add('ride_alive', ViewPlay.SessionAlive);
  AResult.Add('training_only_alive',(ViewTrainingOnly<>nil)and ViewTrainingOnly.SessionAlive);
  AResult.Add('menu_overlay', ViewMenu.Active and ViewMenu.SessionUnderneath);
  if ViewMenu.Active and Assigned(ViewMenu.Background) then
    AResult.Add('menu_background_alpha', ViewMenu.Background.Color.W);
  if ViewPlay.SessionAlive and Assigned(ViewPlay.MenuButton) then
    AResult.Add('menu_button_rect', TJSONArray.Create([
      ViewPlay.MenuButton.RenderRect.Left, ViewPlay.MenuButton.RenderRect.Bottom,
      ViewPlay.MenuButton.RenderRect.Width, ViewPlay.MenuButton.RenderRect.Height]));
end;

procedure EnsureMenuVisible;
var C: TCastleContainer;
begin
  C := Application.MainWindow.Container;
  DismissAssistant(C);
  if ResumeMcpView(C,ViewMenu) then Exit;
  if (C.PendingFrontView = ViewPlay) and ViewPlay.SessionAlive then
    ViewPlay.OpenMenu
  else if(ViewTrainingOnly<>nil)and(C.PendingFrontView=ViewTrainingOnly)and ViewTrainingOnly.SessionAlive then
    ViewTrainingOnly.OpenMenu
  else
    C.View := ViewMenu;
end;

procedure CmdSwitchView(const AParams: TJSONObject; AResult: TJSONObject);
var
  V: TCastleView;
  N: String;
begin
  DismissAssistant(Application.MainWindow.Container);
  N := AParams.Get('view', '');
  V := FindViewByName(N);
  if V <> nil then
  begin
    if V = ViewMenu then
    begin
      EnsureMenuVisible;
      AResult.Add('ok', True);
      AResult.Add('active', ActiveViewName);
      AResult.Add('overlay', ViewMenu.SessionUnderneath);
      Exit;
    end;
    if (V = ViewPlay) and ViewPlay.SessionAlive and
      ResumeMcpView(Application.MainWindow.Container,V) then
    begin
      AResult.Add('ok', True);
      AResult.Add('active', ActiveViewName);
      Exit;
    end;
    if ((V=ViewLogin)or(V=ViewWorkoutEditor))and
      (Application.MainWindow.Container.PendingFrontView=ViewMenu)then begin
      ViewMenu.OpenChildView(V);AResult.Add('ok',True);Exit;
    end;
    Application.MainWindow.Container.View := V;
    AResult.Add('ok', True);
    AResult.Add('active', ActiveViewName);
    Exit;
  end;
  { devices/bikefit/events/training/profile — не полноэкранные вью, а
    встроенные вкладки главного меню: переключаемся на меню (если ещё
    не там) и открываем вкладку. Сначала меню: у вкладок owner
    FreeAtStop меню, поэтому FPageHost/поля страниц валидны только при
    активном ViewMenu. }
  N := LowerCase(Trim(N));
  if Pos('view.', N) = 1 then
    Delete(N, 1, Length('view.'));
  if (N = 'devices') or (N = 'bikefit') or (N = 'events') or
     (N='schedule')or(N='home')or(N='history')or(N='result')or(N='intervals')or(N='rider')or (N = 'training') or (N = 'profile') or (N='settings') or (N='connectors') or (N='route-library') or
     (N='routes') or (N='real-world') or (N='dream') or (N='dream-world') or (N='route-create') then
  begin
    EnsureMenuVisible;
    ViewMenu.OpenTab(N);
    AResult.Add('ok', True);
    AResult.Add('active', ActiveViewName);
    AResult.Add('tab', N);
    Exit;
  end;
  raise Exception.Create('Unknown view "' + N + '" — see app.views_list');
end;

procedure CmdFlatMap(const AParams:TJSONObject;AResult:TJSONObject);
var P:TVector2;Geo:TLatLon;Hit:Boolean;
begin
  EnsureMenuVisible;
  ViewMenu.OpenTab('route-create');
  if AParams.Find('lat')<>nil then ViewMenu.RouteCreator.Map.CenterAt(
    TLatLon.Make(AParams.Get('lat',55.75),AParams.Get('lon',37.62)),AParams.Get('zoom',15));
  if AParams.Get('planet',False)then ViewMenu.RouteCreator.Map.ShowPlanet;
  if AParams.Find('pause_tiles')<>nil then ViewMenu.RouteCreator.Map.PauseTileLoading(AParams.Get('pause_tiles',False));
  if AParams.Find('zoom_delta')<>nil then ViewMenu.RouteCreator.Map.ZoomBy(AParams.Get('zoom_delta',0));
  if AParams.Find('project_lat')<>nil then begin
    P:=ViewMenu.RouteCreator.Map.GeoToScreen(TLatLon.Make(AParams.Get('project_lat',0.0),AParams.Get('project_lon',0.0)));
    AResult.Add('screen',TJSONArray.Create([P.X,P.Y]));
  end;
  if AParams.Find('screen_x')<>nil then begin
    Hit:=ViewMenu.RouteCreator.Map.TryScreenToGeo(Vector2(AParams.Get('screen_x',0.0),AParams.Get('screen_y',0.0)),Geo);
    AResult.Add('hit',Hit);if Hit then AResult.Add('geo',TJSONArray.Create([Geo.Lat,Geo.Lon]));
  end;
  AResult.Add('map',ViewMenu.RouteCreator.Map.MapStats);
  AResult.Add('planner',ViewMenu.RouteCreator.MapDiagnostics);
  AResult.Add('fps_real',Application.MainWindow.Fps.RealFps);
end;

procedure CmdClientVersion(const AParams:TJSONObject; AResult:TJSONObject);
var Info:TJSONObject;I:Integer;
begin
  Info:=ClientVersionInfo;
  try for I:=0 to Info.Count-1 do AResult.Add(Info.Names[I],Info.Items[I].Clone);
  finally Info.Free;end;
end;

procedure CmdUiInspect(const AParams: TJSONObject; AResult: TJSONObject);
var Items: TJSONArray;RootIndex:Integer;
  procedure Walk(const C: TCastleUserInterface; const Path: String);
  var I: Integer; O: TJSONObject; Caption: String;
  begin
    if not C.Exists then Exit;
    Caption := '';
    if C is TCastleButton then Caption := TCastleButton(C).Caption
    else if C is TCastleLabel then Caption := TCastleLabel(C).Caption
    else if C is TCastleCheckbox then Caption:=TCastleCheckbox(C).Caption;
    { This label also contains live dictation, which has not been submitted.
      Treat it like an edit value when exposing UI metadata to an agent. }
    if C.Name = 'AssistantVoiceInputStatus' then Caption := '';
    if (C is TCastleButton)or(C is TCastleCheckbox)or(C is TCastleEdit)or
       (C is TCastleIntegerSlider)or(C is TCastleFloatSlider)or
       ((C is TCastleLabel) and AParams.Get('labels', False)) then
    begin
      O := TJSONObject.Create(['path', Path, 'name', C.Name, 'class', C.ClassName,
        'caption', Caption]);
      O.Add('rect', TJSONArray.Create([C.RenderRect.Left, C.RenderRect.Bottom,
        C.RenderRect.Width, C.RenderRect.Height]));
      if C is TCastleButton then O.Add('enabled', TCastleButton(C).Enabled);
      Items.Add(O);
    end;
    for I := 0 to C.ControlsCount-1 do Walk(C.Controls[I], Path + '/' + IntToStr(I));
  end;
begin
  Items := TJSONArray.Create;
  AResult.Add('controls', Items);
  if Application.MainWindow.Container.CurrentFrontView <> nil then
    Walk(Application.MainWindow.Container.CurrentFrontView, 'view');
  if AParams.Get('global',False)then
    for RootIndex:=0 to Application.MainWindow.Container.Controls.Count-1 do
      if Application.MainWindow.Container.Controls[RootIndex]<>Application.MainWindow.Container.CurrentFrontView then
        Walk(Application.MainWindow.Container.Controls[RootIndex],'overlay/'+IntToStr(RootIndex));
end;

procedure CmdUiEdit(const AParams:TJSONObject;AResult:TJSONObject);
var Found:TCastleEdit;Name:String;
  procedure Walk(C:TCastleUserInterface);
  var I:Integer;
  begin
    if(Found<>nil)or not C.Exists then Exit;
    if(C is TCastleEdit)and(C.Name=Name)then begin Found:=TCastleEdit(C);Exit;end;
    for I:=0 to C.ControlsCount-1 do Walk(C.Controls[I]);
  end;
begin
  Name:=AParams.Get('name','');
  if not((Name='ProfileWeight')or(Name='ProfileFtp')or(Name='WorkoutNameInput')or
    (Name='BikeFitValueInput')or(Name='RouteTitleInput')or(Name='RoomCode')or(Pos('IntervalValue',Name)=1))then
    raise Exception.Create('Only rider, route and workout fields can be edited');
  Found:=nil;Walk(Application.MainWindow.Container.CurrentFrontView);
  if Found=nil then raise Exception.Create('Visible field not found: '+Name);
  Found.Text:=AParams.Get('text','');if Assigned(Found.OnChange)then Found.OnChange(Found);AResult.Add('updated',True);
end;

procedure CmdAudioInspect(const AParams:TJSONObject;AResult:TJSONObject);
begin
  if GameSound<>nil then AResult.Add('audio',GameSound.Diagnostics);
end;

procedure CmdWorkoutInspect(const AParams:TJSONObject;AResult:TJSONObject);
begin
  AResult.Add('state',Ord(WorkoutPlayer.State));AResult.Add('index',WorkoutPlayer.Index);
  AResult.Add('elapsed',WorkoutPlayer.Elapsed);AResult.Add('remaining',WorkoutPlayer.StageRemaining);
  AResult.Add('position',WorkoutPlayer.Position);AResult.Add('stage_time',WorkoutPlayer.StageTime);
  AResult.Add('watts',WorkoutPlayer.TargetWatts);AResult.Add('intensity',WorkoutPlayer.Intensity);
  AResult.Add('reference_watts',WorkoutPlayer.ReferenceWatts);
  AResult.Add('signal_lost',WorkoutPlayer.SignalLost);
  AResult.Add('auto_paused',WorkoutPlayer.AutoPaused);
  AResult.Add('no_pedal_seconds',WorkoutPlayer.NoPedalingTime);
  AResult.Add('auto_pause_delay',WorkoutPlayer.AutoPauseDelay);
  AResult.Add('trainer_control',WorkoutPlayer.NeedsTrainerControl);
  if Assigned(ViewPlay) and Assigned(ViewPlay.WorkoutGates)then
    AResult.Add('gates',ViewPlay.WorkoutGates.Diagnostics);
  if WorkoutPlayer.Plan<>nil then begin
    AResult.Add('name',WorkoutPlayer.Plan.Name);
    AResult.Add('duration',WorkoutPlayer.Plan.TotalDuration);
    AResult.Add('stages',WorkoutPlayer.Plan.Segments.Count);
  end;
end;
procedure CmdOpenFile(const AParams:TJSONObject;AResult:TJSONObject);
begin ViewMenu.AcceptFile(AParams.Get('path',''));AResult.Add('ok',True);end;

procedure CmdMenuInspect(const AParams:TJSONObject;AResult:TJSONObject);
begin
  if Application.MainWindow.Container.CurrentFrontView <> ViewMenu then
    raise Exception.Create('Menu is not active');
  if AParams.Find('route_path') <> nil then
    ViewMenu.OpenCloudRoute(AParams.Get('route_path', ''));
  if (ViewMenu.Globe <> nil) and (AParams.Find('lat') <> nil) then
    ViewMenu.Globe.CenterAt(TLatLon.Make(AParams.Get('lat', 35.0), AParams.Get('lon', 35.0)), AParams.Get('zoom', 4));
  AResult.Add('ride_background', ViewMenu.RideUnderneath);
  if ViewMenu.Globe <> nil then AResult.Add('globe', ViewMenu.Globe.MapStats);
  if ViewMenu.RoutesPage <> nil then AResult.Add('routes', ViewMenu.RoutesPage.Diagnostics);
  if ViewMenu.DreamPage <> nil then AResult.Add('dream', ViewMenu.DreamPage.Diagnostics);
  AResult.Add('fps_real', Application.MainWindow.Fps.RealFps);
end;

procedure CmdDreamInspect(const AParams:TJSONObject;AResult:TJSONObject);
var Y:Single;
begin
  AResult.Add('osm_streaming',ViewPlay.Osm<>nil);
  if ViewPlay.SessionAlive then AResult.Add('coastal_sky',ViewPlay.CoastalSkyActive);
  if AParams.Get('open',False)then begin EnsureMenuVisible;ViewMenu.OpenTab('dream-world');end;
  if AParams.Find('select')<>nil then begin
    if(Application.MainWindow.Container.CurrentFrontView<>ViewMenu)or(ViewMenu.DreamPage=nil)then
      raise Exception.Create('Open Dream World first');
    ViewMenu.DreamPage.SelectWorldIndex(AParams.Get('select',0));
  end;
  if AParams.Find('capture_preview')<>nil then begin
    if(Application.MainWindow.Container.CurrentFrontView<>ViewMenu)or(ViewMenu.DreamPage=nil)then
      raise Exception.Create('Open Dream World first');
    ViewMenu.DreamPage.CapturePreview(AParams.Get('capture_preview',''));
  end;
  if(Application.MainWindow.Container.CurrentFrontView=ViewMenu)and(ViewMenu.DreamPage<>nil)then
    AResult.Add('page',ViewMenu.DreamPage.Diagnostics);
  if ViewPlay.SessionAlive and(ViewPlay.DreamWorld<>nil)then begin
    AResult.Add('ride',ViewPlay.DreamWorld.Diagnostics);
    if ViewPlay.DreamVisual<>nil then AResult.Add('ride_visual',ViewPlay.DreamVisual.Diagnostics);
    if AParams.Find('x')<>nil then begin
      AResult.Add('ground_hit',ViewPlay.DreamWorld.GroundNearYAt(AParams.Get('x',0.0),AParams.Get('z',0.0),AParams.Get('y',9.0),Y));
      AResult.Add('ground_y',Y);
    end;
  end;
  AResult.Add('fps_real',Application.MainWindow.Fps.RealFps);
end;

procedure CmdTravelSelect(const AParams:TJSONObject;AResult:TJSONObject);
var Mode:TTravelMode;
begin
  Mode:=ParseTravel(AParams.Get('mode','bicycle'));
  EnsureMenuVisible;ViewMenu.SelectTravelMode(Mode);
  AResult.Add('mode',TravelIds[Settings.TravelMode]);
end;
procedure CmdExploreStart(const AParams:TJSONObject;AResult:TJSONObject);
var Mode:TTravelMode;
begin
  Mode:=ParseTravel(AParams.Get('mode',TravelIds[Settings.TravelMode]));
  if(AParams.Find('lat')=nil)or(AParams.Find('lon')=nil)then raise Exception.Create('lat and lon required');
  EnsureMenuVisible;ViewMenu.SelectTravelMode(Mode);
  Settings.ExploreBicycle:=True;
  ViewMenu.StartExploration(AParams.Floats['lat'],AParams.Floats['lon']);
  AResult.Add('ok',True);
end;
procedure CmdExploreState(const AParams:TJSONObject;AResult:TJSONObject);
begin
  AResult.Add('travel',ViewPlay.TravelDiagnostics);
  AResult.Add('selection',TJSONObject.Create(['mode',TravelIds[Settings.TravelMode],
    'point_set',Settings.ExploreStartSet,'lat',Settings.ExploreLat,'lon',Settings.ExploreLon]));
end;
procedure CmdExploreInput(const AParams:TJSONObject;AResult:TJSONObject);
begin
  if not ViewPlay.SessionAlive then raise Exception.Create('No active world session');
  ViewPlay.SetExploreInput(AParams.Get('power_axis',0.0),AParams.Get('steer',0.0),
    AParams.Get('walk_axis',0.0),AParams.Get('enabled',True));
  AResult.Add('ok',True);
end;

procedure CmdDreamStart(const AParams:TJSONObject;AResult:TJSONObject);
begin
  if Application.MainWindow.Container.CurrentFrontView<>ViewMenu then raise Exception.Create('Open Dream World first');
  if ViewMenu.DreamPage=nil then raise Exception.Create('Open Dream World first');
  ViewMenu.LaunchDreamRide(nil);AResult.Add('ok',True);
end;

{ ── объекты play-сессии ────────────────────────────────────────────── }

procedure McpRegisterPlayObjects;
  procedure RegisterHudChild(const ObjectName: String;
    const ValueLabel: TCastleUserInterface; const ChildName: String);
  var I: Integer; C: TCastleUserInterface;
  begin
    if (ValueLabel=nil) or (ValueLabel.Parent=nil) then Exit;
    for I:=0 to ValueLabel.Parent.ControlsCount-1 do
    begin
      C:=ValueLabel.Parent.Controls[I];
      if C.Name=ChildName then begin RegisterMcpObject(ObjectName,C); Exit end;
    end;
  end;
begin
  if not McpActive then Exit;
  if not Assigned(ViewPlay) then Exit;
  if Assigned(ViewPlay.World)  then RegisterMcpObject('world', ViewPlay.World);
  if Assigned(ViewPlay.Bike)   then RegisterMcpObject('bike', ViewPlay.Bike);
  if Assigned(ViewPlay.Osm)    then RegisterMcpObject('osm', ViewPlay.Osm);
  if Assigned(ViewPlay.Camera) then RegisterMcpObject('camera', ViewPlay.Camera);
  if Assigned(ViewPlay.CinematicCam) then
    RegisterMcpObject('camera.cinematic', ViewPlay.CinematicCam);
  if Assigned(ViewPlay.MainViewport) and Assigned(ViewPlay.MainViewport.Camera) then
    RegisterMcpObject('camera.scene', ViewPlay.MainViewport.Camera);
  RegisterMcpObject('hud.power',ViewPlay.LabelPower);
  RegisterMcpObject('hud.speed',ViewPlay.LabelSpeed);
  RegisterMcpObject('hud.cadence',ViewPlay.LabelCadence);
  RegisterMcpObject('hud.heart',ViewPlay.LabelHeart);
  RegisterMcpObject('hud.slope',ViewPlay.LabelSlope);
  RegisterMcpObject('hud.correction',ViewPlay.LabelCorr);
  RegisterMcpObject('hud.work',ViewPlay.LabelWork);
  RegisterMcpObject('hud.work_tss',ViewPlay.LabelWorkTSS);
  RegisterHudChild('hud.power_wheel',ViewPlay.LabelPower,'PowerZoneWheel');
  RegisterHudChild('hud.cadence_wheel',ViewPlay.LabelCadence,'CadenceZoneWheel');
  RegisterHudChild('hud.heart_wheel',ViewPlay.LabelHeart,'HeartZoneWheel');
end;

procedure McpUnregisterPlayObjects;
begin
  if not McpActive then Exit;
  ResetPhotoViewRenderTools;
  PhotoComparisonMode:=False;
  ClearFarFieldProbe;
  UnregisterMcpObject('world');
  UnregisterMcpObject('bike');
  UnregisterMcpObject('osm');
  UnregisterMcpObject('camera');
  UnregisterMcpObject('camera.cinematic');
  UnregisterMcpObject('camera.scene');
  UnregisterMcpObject('hud.power');
  UnregisterMcpObject('hud.speed');
  UnregisterMcpObject('hud.cadence');
  UnregisterMcpObject('hud.heart');
  UnregisterMcpObject('hud.slope');
  UnregisterMcpObject('hud.correction');
  UnregisterMcpObject('hud.work');
  UnregisterMcpObject('hud.work_tss');
  UnregisterMcpObject('hud.power_wheel');
  UnregisterMcpObject('hud.cadence_wheel');
  UnregisterMcpObject('hud.heart_wheel');
end;

{ ── ride.* ─────────────────────────────────────────────────────────── }

procedure CmdRideStart(const AParams: TJSONObject; AResult: TJSONObject);
var
  C: TCastleContainer;
begin
  if not Assigned(ViewPlay) then
    raise Exception.Create('ViewPlay not available');
  C := Application.MainWindow.Container;
  DismissAssistant(C);
  if not ResumeMcpView(C,ViewPlay) then C.View:=ViewPlay;
  ViewPlay.StartMoving;
  AResult.Add('ok', True);
  AResult.Add('active', ActiveViewName);
end;

procedure CmdRideStop(const AParams: TJSONObject; AResult: TJSONObject);
begin
  if not Assigned(ViewPlay) then
    raise Exception.Create('ViewPlay not available');
  if ViewPlay.SessionAlive then
    ViewPlay.StopMoving;
  AResult.Add('ok', True);
end;

procedure CmdRideLoadFit(const AParams: TJSONObject; AResult: TJSONObject);
var
  P: String;
  C: TCastleContainer;
begin
  P := Trim(AParams.Get('path', ''));
  if P = '' then
    raise Exception.Create('ride.load_fit: empty "path"');
  if not Assigned(ViewPlay) then
    raise Exception.Create('ViewPlay not available');
  C := Application.MainWindow.Container;

  { Сессия жива (игра активна ИЛИ меню поверх по ESC-паузе): мир/байк/
    ботов НЕ пересоздаём — только новый путь + райдер на старт. Тот же
    путь, что у кнопки «Ехать» при живой сессии. }
  if ViewPlay.SessionAlive then
  begin
    ViewPlay.PrepareRouteTravel;ViewPlay.ResetRideToFit(P);
    if (C.ViewStackCount >= 2) and
       (C.ViewStack[C.ViewStackCount - 1] = ViewMenu) and
       (C.ViewStack[C.ViewStackCount - 2] = ViewPlay) then
      C.PopView;
    AResult.Add('ok', True);
    AResult.Add('fit', P);
    AResult.Add('reset', True);
    AResult.Add('active', ActiveViewName);
    Exit;
  end;

  { Свежий запуск: тот же путь, что у кнопки «Ехать» на странице
    «Маршруты» (TViewMenu.LaunchSelectedRide): FIT в CurrentFitPath, затем
    смена view — Start сам поднимет стриминговую карту по этому маршруту. }
  if C.View = ViewPlay then
    raise Exception.Create(
      'play view already active — switch away first (app.switch_view menu)');
  ViewPlay.PrepareDreamWorld(nil);
  ViewPlay.PrepareRouteTravel;ViewPlay.CurrentFitPath := P;
  C.View := ViewPlay;
  AResult.Add('ok', True);
  AResult.Add('fit', P);
  AResult.Add('active', ActiveViewName);
end;

procedure CmdRideStopFull(const AParams:TJSONObject;AResult:TJSONObject);
var Alive:Boolean;
begin
  Alive:=((ViewPlay<>nil) and ViewPlay.SessionAlive) or
    ((ViewTrainingOnly<>nil) and ViewTrainingOnly.SessionAlive);
  if Alive then begin
    EnsureMenuVisible;
    ViewMenu.FinishRide;
  end;
  AResult.Add('stopped',Alive);AResult.Add('ok',True);
  AResult.Add('active',ActiveViewName);
end;
procedure CmdCameraSetMode(const AParams: TJSONObject; AResult: TJSONObject);
var
  M: String;
  Mode: TPlayCameraMode;
begin
  if not Assigned(ViewPlay) then
    raise Exception.Create('ViewPlay not available');
  if Application.MainWindow.Container.View <> ViewPlay then
    raise Exception.Create('play view is not active — camera mode unavailable');
  M := LowerCase(Trim(AParams.Get('mode', '')));
  if (M = 'cinematic') or (M = 'pcmcinematic') then
    Mode := pcmCinematic
  else if (M = 'thirdperson') or (M = 'third_person') or (M = 'pcmthirdperson') then
    Mode := pcmThirdPerson
  else if (M = 'free') or (M = 'pcmfree') then
    Mode := pcmFree
  else
    raise Exception.Create('Unknown camera mode "' + M +
      '" — use cinematic|thirdperson|free');
  ViewPlay.SetCameraMode(Mode);   { also clears MCP chase override }
  AResult.Add('ok', True);
  AResult.Add('mode', M);
  AResult.Add('chase', False);
end;

{ ── camera.chase — direct rear-view control for FPS A/B ───────────── }

procedure CmdCameraSetView(const AParams: TJSONObject; AResult: TJSONObject);
var Pos, Dir, Up: TVector3;
begin
  if (ViewPlay = nil) or not ViewPlay.SessionAlive then
    raise Exception.Create('Active ride required');
  Pos := Vector3(AParams.Get('x', 0.0), AParams.Get('y', 0.0), AParams.Get('z', 0.0));
  Dir := Vector3(AParams.Get('dx', 0.0), AParams.Get('dy', 0.0), AParams.Get('dz', -1.0));
  if Dir.Length < 0.0001 then raise Exception.Create('Camera direction must be nonzero');
  Dir := Dir.Normalize;
  Up := Vector3(0, 1, 0);
  if Abs(Dir.Y) > 0.999 then Up := Vector3(0, 0, 1);
  ViewPlay.SetCameraMode(pcmFree);
  ViewPlay.MainViewport.Camera.SetView(Pos, Dir, Up);
  AResult.Add('ok', True);
end;

procedure CmdCameraChase(const AParams: TJSONObject; AResult: TJSONObject);
var
  Dist, Height, Side, AimH: Double;
  Active: Boolean;
begin
  if not Assigned(ViewPlay) then
    raise Exception.Create('ViewPlay not available');
  if Application.MainWindow.Container.View <> ViewPlay then
    raise Exception.Create('play view is not active — camera chase unavailable');
  { active defaults True; pass false to release back to ring mode. }
  if AParams.Find('active') <> nil then
    Active := AParams.Get('active', True)
  else
    Active := True;
  Dist := AParams.Get('distance', Double(3.0));
  Height := AParams.Get('height', Double(1.3));
  Side := AParams.Get('side', Double(0.0));
  AimH := AParams.Get('aim_height', Double(0.85));
  ViewPlay.SetChaseCamera(Active, Dist, Height, Side, AimH);
  AResult.Add('ok', True);
  AResult.Add('chase', ViewPlay.ChaseCameraActive);
  AResult.Add('distance', ViewPlay.ChaseCameraDistance);
  AResult.Add('height', ViewPlay.ChaseCameraHeight);
  AResult.Add('walking_follow',ViewPlay.WalkingCameraActive);
  if ViewPlay.WalkingCameraActive then begin
    AResult.Add('walking_overview',ViewPlay.WalkingCam.Overview);
    AResult.Add('walking_still_seconds',ViewPlay.WalkingCam.StillTime);
  end;
end;

procedure CmdCameraGet(const AParams: TJSONObject; AResult: TJSONObject);
var
  ModeStr: String;
begin
  if not Assigned(ViewPlay) then
    raise Exception.Create('ViewPlay not available');
  if Application.MainWindow.Container.View <> ViewPlay then
    raise Exception.Create('play view is not active');
  case ViewPlay.CameraMode of
    pcmCinematic:   ModeStr := 'cinematic';
    pcmThirdPerson: ModeStr := 'thirdperson';
    pcmFree:        ModeStr := 'free';
  else
    ModeStr := 'unknown';
  end;
  AResult.Add('ok', True);
  AResult.Add('mode', ModeStr);
  AResult.Add('chase', ViewPlay.ChaseCameraActive);
  AResult.Add('distance', ViewPlay.ChaseCameraDistance);
  AResult.Add('height', ViewPlay.ChaseCameraHeight);
  AResult.Add('walking_follow',ViewPlay.WalkingCameraActive);
  if ViewPlay.WalkingCameraActive then begin
    AResult.Add('walking_overview',ViewPlay.WalkingCam.Overview);
    AResult.Add('walking_still_seconds',ViewPlay.WalkingCam.StillTime);
  end;
end;

{ ── camera.sample — viewport + avatar only (cinematic dump reverted) ── }

procedure CmdCameraSample(const AParams: TJSONObject; AResult: TJSONObject);
var
  Pos, Dir, Up: TVector3;
  Arr: TJSONArray;
  ModeStr: String;
  Ag: TPhysicalAgent;
  Recorded: TSimCameraFrame;
  Cine:TCameraReplayState;
  Puddle:TRoadPuddleSite;
  R: TJSONObject;
begin
  if not Assigned(ViewPlay) then
    raise Exception.Create('ViewPlay not available');
  if Application.MainWindow.Container.View <> ViewPlay then
    raise Exception.Create('play view is not active');
  if (ViewPlay.MainViewport = nil) or (ViewPlay.MainViewport.Camera = nil) then
    raise Exception.Create('MainViewport.Camera not available');

  ViewPlay.MainViewport.Camera.GetView(Pos, Dir, Up);
  Arr := TJSONArray.Create;
  Arr.Add(Pos.X); Arr.Add(Pos.Y); Arr.Add(Pos.Z);
  AResult.Add('viewport_pos', Arr);
  Arr := TJSONArray.Create;
  Arr.Add(Dir.X); Arr.Add(Dir.Y); Arr.Add(Dir.Z);
  AResult.Add('viewport_dir', Arr);
  AResult.Add('viewport_up',TJSONArray.Create([Up.X,Up.Y,Up.Z]));
  AResult.Add('field_of_view',ViewPlay.MainViewport.Camera.Perspective.FieldOfView);
  if Assigned(DeviceService) then AResult.Add('sim_time_sec',DeviceService.SimPositionSec);
  AResult.Add('camera_replaying',ViewPlay.SimCameraReplaying);
  AResult.Add('camera_time_sec',ViewPlay.SimCameraViewTime);
  if Assigned(ViewPlay.SimHistory) and Assigned(DeviceService) and
    ViewPlay.SimHistory.CameraTrack.Sample(ViewPlay.SimCameraViewTime,Recorded) then begin
    R:=TJSONObject.Create; AResult.Add('recorded_view',R);
    R.Add('position',TJSONArray.Create([Recorded.Position.X,Recorded.Position.Y,Recorded.Position.Z]));
    R.Add('direction',TJSONArray.Create([Recorded.Direction.X,Recorded.Direction.Y,Recorded.Direction.Z]));
    R.Add('up',TJSONArray.Create([Recorded.Up.X,Recorded.Up.Y,Recorded.Up.Z]));
    R.Add('field_of_view',Recorded.FieldOfView);
    R.Add('ring_mode',Recorded.CameraMode);
    R.Add('cinematic_mode',Recorded.CinematicMode);
    R.Add('pending_mode',Recorded.PendingMode);
    R.Add('chase',Recorded.Chase);
  end;

  if Assigned(ViewPlay.AvatarTransform) then
  begin
    Arr := TJSONArray.Create;
    Arr.Add(ViewPlay.AvatarTransform.Translation.X);
    Arr.Add(ViewPlay.AvatarTransform.Translation.Y);
    Arr.Add(ViewPlay.AvatarTransform.Translation.Z);
    AResult.Add('avatar_pos', Arr);
    Arr := TJSONArray.Create;
    Arr.Add(ViewPlay.AvatarTransform.Direction.X);
    Arr.Add(ViewPlay.AvatarTransform.Direction.Y);
    Arr.Add(ViewPlay.AvatarTransform.Direction.Z);
    AResult.Add('avatar_dir', Arr);
    AResult.Add('avatar_up', TJSONArray.Create([ViewPlay.AvatarTransform.Up.X,
      ViewPlay.AvatarTransform.Up.Y, ViewPlay.AvatarTransform.Up.Z]));
  end;

  case ViewPlay.CameraMode of
    pcmCinematic:   ModeStr := 'cinematic';
    pcmThirdPerson: ModeStr := 'thirdperson';
    pcmFree:        ModeStr := 'free';
  else
    ModeStr := 'unknown';
  end;
  AResult.Add('ring_mode', ModeStr);
  AResult.Add('chase', ViewPlay.ChaseCameraActive);
  AResult.Add('walking_follow',ViewPlay.WalkingCameraActive);
  if ViewPlay.WalkingCameraActive then begin
    AResult.Add('walking_overview',ViewPlay.WalkingCam.Overview);
    AResult.Add('walking_still_seconds',ViewPlay.WalkingCam.StillTime);
  end;

  if Assigned(ViewPlay.CinematicCam) then
  begin
    AResult.Add('cinematic_mode', Ord(ViewPlay.CinematicCam.Mode));
    AResult.Add('cinematic_pending', ViewPlay.CinematicCam.PendingMode);
    Cine:=ViewPlay.CinematicCam.CaptureReplay;
    AResult.Add('puddle_active',Cine.Shot.Mode=cmPuddle);
    AResult.Add('puddle_sites',RoadPuddleSiteCount);
    AResult.Add('puddle_reflections',ViewPlay.CinematicCam.PuddleReflections);
    AResult.Add('puddle_cooldown',Cine.PuddleCooldown);
    AResult.Add('puddle_blend_sec',Cine.BlendAge);
    if Cine.Shot.Mode=cmPuddle then
      AResult.Add('puddle_position',TJSONArray.Create([Cine.Shot.Puddle.Position.X,
        Cine.Shot.Puddle.Position.Y,Cine.Shot.Puddle.Position.Z]));
    if Assigned(ViewPlay.AvatarTransform) and FindRoadPuddle(ViewPlay.AvatarTransform.Translation,
      ViewPlay.AvatarTransform.Direction,0,120,8,0,Puddle) then
      AResult.Add('puddle_next',TJSONArray.Create([Puddle.Position.X,Puddle.Position.Y,Puddle.Position.Z]));
  end;

  Ag := nil;
  if Assigned(ViewPlay.World) and (ViewPlay.World.Agents.Count > 0) then
    Ag := TPhysicalAgent(ViewPlay.World.Agents[0]);
  if (Ag <> nil) and Assigned(Ag.State) then
  begin
    AResult.Add('speed_mps', Ag.State.CurrentSpeed);
    AResult.Add('lean_deg', Ag.State.CurrentTurnAngle);
  end;
  AResult.Add('ok', True);
end;

{ ── sim.* — управление FIT-симулятором ─────────────────────────────── }

procedure CmdPathFollowState(const AParams: TJSONObject; AResult: TJSONObject);
var
  Ag: TPhysicalAgent;
  Map: TOsm3dStreamingMap;
  Obs: TBuildingObstacleArray;
  All, Ring: TJSONArray; O: TJSONObject; I,J: Integer;
  BaseY,MaxY: Single;
  TrafficAgent:TPhysicalAgent;
  Passage:TPathNarrowPassage;
  GroundTracking:TGroundTrackingReplay;
  TrafficSnapshot:TLaneReplayState;
  TrafficIndex:Integer;
  LoadGrade,LoadStation,LoadHeight:Single;
  ContactBike:TBikeInstance;BikeIndex:Integer;
  WheelPoint,ContactNormal:TVector3;ContactY,UnusedY:Single;ContactHit,UnusedHit:Boolean;
  procedure Wheel(const Key:string;Front:Boolean);
  begin
    if not ContactBike.WheelSupportPoint(Front,ContactNormal,WheelPoint)then Exit;
    O.Add(Key+'_wheel',TJSONArray.Create([WheelPoint.X,WheelPoint.Y,WheelPoint.Z]));
    ContactHit:=False;
    if (ViewPlay.Osm<>nil)and(ViewPlay.Osm.Session<>nil)then
      ViewPlay.Osm.Session.Map.ProbeGpuGround(WheelPoint.X,WheelPoint.Z,
        TrafficAgent.State.LastGroundY,ContactY,UnusedY,ContactHit,UnusedHit,False)
    else if Assigned(TrafficAgent.State.GroundQuery)then
      ContactHit:=TrafficAgent.State.GroundQuery(WheelPoint.X,WheelPoint.Z,
        TrafficAgent.State.LastGroundY,ContactY);
    O.Add(Key+'_wheel_surface_valid',ContactHit);
    if ContactHit then O.Add(Key+'_wheel_clearance_m',WheelPoint.Y-ContactY);
  end;
  procedure Vec(const Name: String; const V: TVector3);
  var A: TJSONArray;
  begin A:=TJSONArray.Create; A.Add(V.X); A.Add(V.Y); A.Add(V.Z); AResult.Add(Name,A) end;
begin
  if (ViewPlay=nil) or (ViewPlay.World=nil) or (ViewPlay.World.Agents.Count=0) then
    raise Exception.Create('Ride is not active');
  Ag:=TPhysicalAgent(ViewPlay.World.Agents[0]);
  Vec('world_position',Ag.State.WorldPosition);
  Vec('forward',Ag.State.ForwardDir);
  Vec('carrot',Ag.Path.LastCarrotWorld);
  Vec('route_center',Ag.Path.RoadCenterAt(Ag.Path.Position));
  AResult.Add('segment',Ag.Path.Position.Segment); AResult.Add('t',Ag.Path.Position.T);
  AResult.Add('speed',Ag.State.CurrentSpeed); AResult.Add('distance',Ag.State.CumulativeDistance);
  AResult.Add('power',Ag.State.AppliedPowerWatts);
  { One read-only snapshot keeps FIT transport, clock and physics comparable
    without races between separate MCP calls or per-frame file logging. }
  AResult.Add('physics_time_sec',Ag.State.SimulationTime);
  AResult.Add('mass_kg',Ag.State.AvatarMass);
  AResult.Add('cda_m2',Ag.State.DragCoefficient*Ag.State.FrontalArea);
  AResult.Add('crr',Ag.State.RollingResistance);
  if Assigned(DeviceService) and DeviceService.IsSimulationActive then
  begin
    AResult.Add('sim_position_sec',DeviceService.SimPositionSec);
    if DeviceService.ControlDevice<>nil then
    begin
      AResult.Add('sim_record_sec',DeviceService.ControlDevice.LastData.ElapsedTime);
      AResult.Add('sensor_power_w',DeviceService.ControlDevice.LastData.InstantPower);
      AResult.Add('fit_speed_kmh',DeviceService.ControlDevice.LastData.InstantSpeed);
      AResult.Add('sensor_cadence',DeviceService.ControlDevice.LastData.InstantCadence);
      AResult.Add('sensor_hr',DeviceService.ControlDevice.LastData.HeartRate);
    end;
  end;
  AResult.Add('lane_offset',Ag.State.LaneOffset);
  AResult.Add('applied_lane_offset',Ag.Path.LastLaneOffsetM);
  AResult.Add('prepared_building_route',Ag.Path.PreparedBuildingRoute);
  AResult.Add('lane_external',Ag.State.LaneOffsetExternal);
  AResult.Add('road_width',Ag.Path.RoadWidthAt(Ag.Path.Position));
  AResult.Add('steering_speed_limit',Ag.Path.SteeringSpeedLimit);
  AResult.Add('traffic_speed_limit',Ag.State.TrafficSpeedLimit);
  AResult.Add('auto_move',Ag.State.AutoMove);
  if AParams.Get('traffic',False)then begin
    TrafficSnapshot:=ViewPlay.TrafficDiagnosticsSnapshot;
    All:=TJSONArray.Create;AResult.Add('traffic',All);
    for I:=0 to ViewPlay.World.Agents.Count-1 do begin
      TrafficAgent:=TPhysicalAgent(ViewPlay.World.Agents[I]);
      if(TrafficAgent=nil)or(TrafficAgent.State=nil)or(TrafficAgent.Path=nil)then Continue;
      O:=TJSONObject.Create;All.Add(O);O.Add('agent_id',I);O.Add('name',TrafficAgent.Name);
      O.Add('auto_move',TrafficAgent.State.AutoMove);O.Add('speed',TrafficAgent.State.CurrentSpeed);
      O.Add('distance',TrafficAgent.State.CumulativeDistance);
      O.Add('forward',TJSONArray.Create([TrafficAgent.State.ForwardDir.X,
        TrafficAgent.State.ForwardDir.Y,TrafficAgent.State.ForwardDir.Z]));
      O.Add('lane_offset',TrafficAgent.State.LaneOffset);
      O.Add('applied_lane_offset',TrafficAgent.Path.LastLaneOffsetM);
      for TrafficIndex:=0 to High(TrafficSnapshot) do
        if TrafficSnapshot[TrafficIndex].Active and
          (TrafficSnapshot[TrafficIndex].Tag=Pointer(TrafficAgent)) then begin
          O.Add('traffic_pose_valid',TrafficSnapshot[TrafficIndex].PoseValid);
          O.Add('traffic_pose',TJSONArray.Create([
            TrafficSnapshot[TrafficIndex].WorldPosition.X,
            TrafficSnapshot[TrafficIndex].WorldPosition.Y,
            TrafficSnapshot[TrafficIndex].WorldPosition.Z]));
          O.Add('collision_dir',TJSONArray.Create([
            TrafficSnapshot[TrafficIndex].CollisionDir.X,
            TrafficSnapshot[TrafficIndex].CollisionDir.Y,
            TrafficSnapshot[TrafficIndex].CollisionDir.Z]));
          O.Add('lane_dir',TJSONArray.Create([TrafficSnapshot[TrafficIndex].ForwardDir.X,
            TrafficSnapshot[TrafficIndex].ForwardDir.Y,TrafficSnapshot[TrafficIndex].ForwardDir.Z]));
          O.Add('traffic_road_width',TrafficSnapshot[TrafficIndex].RoadWidth);
          O.Add('traffic_actual_offset',TrafficSnapshot[TrafficIndex].ActualOffset);
          O.Add('traffic_lane',TrafficSnapshot[TrafficIndex].Lane);
          O.Add('traffic_smooth_lane',TrafficSnapshot[TrafficIndex].SmoothLane);
          Break;
        end;
      O.Add('power',TrafficAgent.State.AppliedPowerWatts);
      O.Add('ground_pitch_deg',TrafficAgent.State.CurrentGroundPitch);
      O.Add('model_pitch_deg',TrafficAgent.State.CurrentModelPitch);
      O.Add('physics_time_sec',TrafficAgent.State.SimulationTime);
      O.Add('visual_time_sec',Double(TrafficAgent.State.SimulationTime)+TrafficAgent.State.AccumulatedTime);
      O.Add('physics_lod',Ord(TrafficAgent.State.PhysicsLOD));
      if Assigned(TrafficAgent.Actor.Transform) then
        O.Add('visual_position',TJSONArray.Create([TrafficAgent.Actor.Transform.Translation.X,
          TrafficAgent.Actor.Transform.Translation.Y,TrafficAgent.Actor.Transform.Translation.Z]));
      O.Add('front_ground',TJSONArray.Create([TrafficAgent.State.FrontGroundPoint.X,
        TrafficAgent.State.FrontGroundPoint.Y,TrafficAgent.State.FrontGroundPoint.Z]));
      O.Add('rear_ground',TJSONArray.Create([TrafficAgent.State.RearGroundPoint.X,
        TrafficAgent.State.RearGroundPoint.Y,TrafficAgent.State.RearGroundPoint.Z]));
      O.Add('slope_deg',TrafficAgent.State.CurrentSlopeAngle);
      O.Add('fit_load_valid',TrafficAgent.Path.FitLoadAtPosition(
        TrafficAgent.Path.Position,LoadGrade,LoadStation,LoadHeight));
      O.Add('fit_load_grade_pct',LoadGrade);
      O.Add('fit_load_datum_corrected',TrafficAgent.Path.FitLoadDatumCorrected);
      O.Add('fit_load_station_m',LoadStation);
      O.Add('fit_load_height_m',LoadHeight);
      O.Add('front_ground_valid',TrafficAgent.State.FrontGroundPointValid);
      O.Add('rear_ground_valid',TrafficAgent.State.RearGroundPointValid);
      if TrafficAgent.Physics<>nil then begin
        { Read the existing contact plane only; this diagnostic never samples
          the ground or changes the GPU query queue. }
        GroundTracking:=TrafficAgent.Physics.CaptureReplay;
        O.Add('road_grade_pct',GroundTracking.RoadSlopeGrade);
        O.Add('road_grade_valid',GroundTracking.RoadSlopeValid);
        O.Add('road_grade_pending_sec',GroundTracking.RoadSlopeMissSec);
        O.Add('fit_grade_pending_sec',GroundTracking.FitSlopeMissSec);
        O.Add('fit_correction_grade_pct',GroundTracking.SlopeCorrSmooth);
        O.Add('fit_elevation_debt_m',GroundTracking.ElevDebtM);
        O.Add('ground_lease_limited_steps',Int64(TrafficAgent.Physics.GroundLeaseLimitedSteps));
        O.Add('ground_lease_rejected_m',TrafficAgent.Physics.GroundLeaseRejectedMeters);
        O.Add('ground_wait_sec',TrafficAgent.Physics.GroundWaitSeconds);
        O.Add('ground_probe_valid',GroundTracking.SmoothedGroundYValid);
        O.Add('ground_probe_position',TJSONArray.Create([
          GroundTracking.GroundProbePosition.X,GroundTracking.GroundProbePosition.Y,
          GroundTracking.GroundProbePosition.Z]));
        O.Add('ground_probe_distance_m',Sqrt(
          Sqr(TrafficAgent.State.WorldPosition.X-GroundTracking.GroundProbePosition.X)+
          Sqr(TrafficAgent.State.WorldPosition.Z-GroundTracking.GroundProbePosition.Z)));
        if AParams.Get('wheels',False)and(TrafficAgent.State.PhysicsLOD<>plMinimal)then begin
          ContactBike:=nil;
          if I=0 then ContactBike:=ViewPlay.Bike
          else if ViewPlay.LocalBots<>nil then begin
            BikeIndex:=ViewPlay.LocalBots.Agents.IndexOf(TrafficAgent);
            if BikeIndex>=0 then ContactBike:=TBikeInstance(ViewPlay.LocalBots.Bikes[BikeIndex]);
          end;
          if ContactBike<>nil then begin
            O.Add('animation_time_sec',ContactBike.AnimElapsed);
            ContactNormal:=Vector3(-GroundTracking.GroundGradient.X,1,-GroundTracking.GroundGradient.Z);
            Wheel('front',True);Wheel('rear',False);
          end;
        end;
      end;
      O.Add('traffic_speed_limit',TrafficAgent.State.TrafficSpeedLimit);
      O.Add('steering_speed_limit',TrafficAgent.Path.SteeringSpeedLimit);
      O.Add('segment',TrafficAgent.Path.Position.Segment);O.Add('t',TrafficAgent.Path.Position.T);
      O.Add('world_position',TJSONArray.Create([TrafficAgent.State.WorldPosition.X,
        TrafficAgent.State.WorldPosition.Y,TrafficAgent.State.WorldPosition.Z]));
      O.Add('route_center',TJSONArray.Create([TrafficAgent.Path.RoadCenterAt(TrafficAgent.Path.Position).X,
        TrafficAgent.Path.RoadCenterAt(TrafficAgent.Path.Position).Y,TrafficAgent.Path.RoadCenterAt(TrafficAgent.Path.Position).Z]));
      if TrafficAgent.Path.NarrowPassageAt(TrafficAgent.Path.Position,
        Max(60,Sqr(TrafficAgent.State.CurrentSpeed)/4+12),Passage)then begin
        O.Add('passage_key',IntToHex(Passage.Key,16));O.Add('passage_forward',Passage.Forward);
        O.Add('passage_inside',Passage.Inside);O.Add('passage_exclusive',Passage.Exclusive);
        O.Add('passage_entry_m',Passage.EntryDistance);
      end;
    end;
  end;
  if (ViewPlay.Osm<>nil) and (ViewPlay.Osm.Session<>nil) then
  begin
    Map:=ViewPlay.Osm.Session.Map;
    AResult.Add('carrot_inside_building',Map.BuildingQuery(Ag.Path.LastCarrotWorld.X,
      Ag.Path.LastCarrotWorld.Z,BaseY,MaxY));
    if AParams.Get('footprints',False) then
    begin
      Obs:=Map.BuildingFootprintsNear(Ag.State.WorldPosition.X,Ag.State.WorldPosition.Z,
        AParams.Get('radius',40.0));
      All:=TJSONArray.Create; AResult.Add('buildings',All);
      for I:=0 to High(Obs) do
      begin
        O:=TJSONObject.Create; All.Add(O); O.Add('tile',IntToStr(Obs[I].TileKey));
        O.Add('base_y',Obs[I].BaseY); O.Add('max_y',Obs[I].MaxY);
        Ring:=TJSONArray.Create; O.Add('ring',Ring);
        for J:=0 to High(Obs[I].Footprint) do
        begin Ring.Add(Obs[I].Footprint[J].X); Ring.Add(Obs[I].Footprint[J].Z) end;
      end;
    end;
  end;
end;

procedure CmdSimStep(const AParams: TJSONObject; AResult: TJSONObject);
begin
  if not Assigned(DeviceService) then raise Exception.Create('DeviceService not available');
  DeviceService.SimStepFrame;
  AResult.Add('ok',True);
end;

procedure CmdSimPlay(const AParams: TJSONObject; AResult: TJSONObject);
begin
  if not Assigned(DeviceService) then
    raise Exception.Create('DeviceService not available');
  DeviceService.SimSetPaused(False);
  AResult.Add('ok', True);
end;

procedure CmdSimPause(const AParams: TJSONObject; AResult: TJSONObject);
begin
  if not Assigned(DeviceService) then
    raise Exception.Create('DeviceService not available');
  DeviceService.SimSetPaused(True);
  AResult.Add('ok', True);
end;

procedure CmdSimInfo(const AParams: TJSONObject; AResult: TJSONObject);
var
  Paused: Boolean;
  CurSec, TotSec: Integer;
begin
  if not Assigned(DeviceService) then
    raise Exception.Create('DeviceService not available');
  AResult.Add('active', DeviceService.IsSimulationActive);
  AResult.Add('enabled', Settings.GetSimulationEnabled);
  AResult.Add('use_route_fit', Settings.GetSimulationUseRoute);
  AResult.Add('source_fit', Settings.EffectiveSimulationFitPath);
  if DeviceService.ControlDevice <> nil then
  begin
    AResult.Add('control_address', DeviceService.ControlDevice.DeviceInfo.Address);
    AResult.Add('power', DeviceService.ControlDevice.LastData.InstantPower);
  end;
  if DeviceService.SimPlayerInfo(Paused, CurSec, TotSec) then
  begin
    AResult.Add('paused', Paused);
    AResult.Add('cur_sec', CurSec);
    AResult.Add('total_sec', TotSec);
  end
  else
    AResult.Add('paused', True);
  AResult.Add('speed_x', DeviceService.SimGetSpeed);
  AResult.Add('position_sec', DeviceService.SimPositionSec);
  AResult.Add('frame_mode', DeviceService.SimGetSpeed<=1/60+0.000001);
  if Assigned(ViewPlay) and ViewPlay.SessionAlive and
     Assigned(ViewPlay.SimHistory) then begin
    AResult.Add('recorded_sec', ViewPlay.SimHistory.Latest);
    AResult.Add('checkpoints', ViewPlay.SimHistory.Count);
    AResult.Add('history_bytes', ViewPlay.SimHistory.MemoryBytes);
    AResult.Add('camera_frames', ViewPlay.SimHistory.CameraTrack.Count);
    AResult.Add('camera_recorded_sec', ViewPlay.SimHistory.CameraTrack.Latest);
    AResult.Add('camera_bytes', ViewPlay.SimHistory.CameraTrack.MemoryBytes);
    AResult.Add('camera_replaying', ViewPlay.SimCameraReplaying);
  end;
  { FreeAtStop frees the HUD, but its published fields remain non-nil.
    Only an active session owns components safe to inspect. }
  if Assigned(ViewPlay) and ViewPlay.SessionAlive and
     Assigned(ViewPlay.LabelCadence) then
    AResult.Add('cadence_label', ViewPlay.LabelCadence.Caption);
end;

procedure CmdSimSpeed(const AParams: TJSONObject; AResult: TJSONObject);
var
  Mul: Double;
begin
  if not Assigned(DeviceService) then
    raise Exception.Create('DeviceService not available');
  Mul := AParams.Get('mul', 1.0);
  DeviceService.SimSetSpeed(Mul);
  AResult.Add('ok', True);
  AResult.Add('speed_x', DeviceService.SimGetSpeed);
end;

procedure CmdSimSeek(const AParams: TJSONObject; AResult: TJSONObject);
var
  Sec: Double;
  Paused: Boolean;
  CurSec, TotSec: Integer;
begin
  if not Assigned(DeviceService) then
    raise Exception.Create('DeviceService not available');
  Sec := AParams.Get('sec', 0.0);
  if Sec < 0 then Sec := 0;
  DeviceService.SimSeekSec(Sec);
  AResult.Add('ok', True);
  AResult.Add('requested_sec', Sec);
  AResult.Add('seek_sec', DeviceService.SimPositionSec);
  if DeviceService.SimPlayerInfo(Paused, CurSec, TotSec) then
  begin
    AResult.Add('cur_sec', CurSec);
    AResult.Add('total_sec', TotSec);
  end;
end;

{ ── bike.anim_debug ────────────────────────────────────────────────── }

procedure CmdBikeAnimDebug(const AParams: TJSONObject; AResult: TJSONObject);
var
  Anim: TJSONObject;
  Ag: TPhysicalAgent;
  ParentNode: TCastleTransform;
  Parents: TJSONArray;
  Item: TJSONObject;
begin
  if (not Assigned(ViewPlay)) or (ViewPlay.Bike = nil) then
    raise Exception.Create('bike not available (play view not started?)');
  Anim := ViewPlay.Bike.AnimDebugJson;
  if ViewPlay.RiderPoseManager<>nil then begin
    if AParams.Get('look_back',False)then
      ViewPlay.RiderPoseManager.TriggerSpecial('look_back');
    Anim.Add('pose',ViewPlay.RiderPoseManager.CurrentPoseName);
    Anim.Add('look_yaw',ViewPlay.RiderPoseManager.Attention.Frame.Yaw);
    Anim.Add('look_torso_yaw',ViewPlay.RiderPoseManager.Attention.Frame.TorsoYaw);
    Anim.Add('look_events',Integer(ViewPlay.RiderPoseManager.Attention.Events));
  end;
  Anim.Add('motion', ViewPlay.Bike.RiderMotionDebugJson);
  Parents := TJSONArray.Create;
  Anim.Add('parents', Parents);
  ParentNode := ViewPlay.Bike.Group;
  while ParentNode <> nil do
  begin
    Item := TJSONObject.Create; Parents.Add(Item);
    Item.Add('name', ParentNode.Name);
    Item.Add('position', TJSONArray.Create([ParentNode.Translation.X,ParentNode.Translation.Y,ParentNode.Translation.Z]));
    Item.Add('direction', TJSONArray.Create([ParentNode.Direction.X,ParentNode.Direction.Y,ParentNode.Direction.Z]));
    Item.Add('up', TJSONArray.Create([ParentNode.Up.X,ParentNode.Up.Y,ParentNode.Up.Z]));
    Item.Add('scale', TJSONArray.Create([ParentNode.Scale.X,ParentNode.Scale.Y,ParentNode.Scale.Z]));
    ParentNode := ParentNode.Parent;
  end;
  { Body lean (roll) lives on the avatar agent, not on TBikeInstance. }
  Ag := nil;
  if Assigned(ViewPlay.World) and (ViewPlay.World.Agents.Count > 0) then
    Ag := TPhysicalAgent(ViewPlay.World.Agents[0]);
  if (Ag <> nil) and Assigned(Ag.State) then
  begin
    Anim.Add('lean_deg', Ag.State.CurrentTurnAngle);
    Anim.Add('target_lean_deg', Ag.State.TargetTurnAngle);
    Anim.Add('curvature', Ag.State.CurrentCurvature);
    Anim.Add('speed_mps', Ag.State.CurrentSpeed);
    Anim.Add('yaw_rate_rad', Ag.State.CurrentYawRateRad);
    if Ag.Actor<>nil then Anim.Add('rider_owns_lean',Ag.Actor.RiderOwnsLean);
  end;
  AResult.Add('anim', Anim);
end;

{ ── bike.set_gpu_anim ────────────────────────────────────────────────── }

procedure CmdBikeMotionSample(const AParams: TJSONObject; AResult: TJSONObject);
var
  Bike: TBikeInstance;
  BotIndex, PoseIndex: Integer;
  State: TBikePlaybackState;
  Anchor, Facing: TJSONArray;
  Paused: Boolean;
  CurSec, TotalSec: Integer;
  Cadence: Single;
begin
  if (not Assigned(ViewPlay)) or (ViewPlay.Bike = nil) then
    raise Exception.Create('Start a ride before sampling its rider');
  if (not Assigned(DeviceService)) or
     (not DeviceService.SimPlayerInfo(Paused, CurSec, TotalSec)) or not Paused then
    raise Exception.Create('Pause the FIT simulation before sampling its rider');
  BotIndex:=AParams.Get('bot_index',-1);
  Bike:=ViewPlay.Bike;
  if BotIndex>=0 then
  begin
    if (ViewPlay.LocalBots=nil) or (BotIndex>=ViewPlay.LocalBots.Bikes.Count) then
      raise Exception.Create('Bot index outside the current roster');
    Bike:=TBikeInstance(ViewPlay.LocalBots.Bikes[BotIndex]);
    if (Bike=nil) or not Bike.HasTripoRider then
      raise Exception.Create('Bot is not prepared');
    if (AParams.Find('anchor')<>nil) or (AParams.Find('facing')<>nil) then
      raise Exception.Create('Bot motion sampling does not reposition the agent');
  end;
  if AParams.Find('pose_index')<>nil then
  begin
    PoseIndex:=AParams.Get('pose_index',0);
    if (PoseIndex<0) or (PoseIndex>=BuiltinRiderPoseCount) then
      raise Exception.Create('Pose index outside the rider catalogue');
    Bike.ApplyRiderPose(BuiltinRiderPose(PoseIndex),0);
  end;
  { Explicit MCP diagnostic only. Keep the live GPU animation/deformation
    path; a paused simulation already prevents the normal clock advancing. }
  State := Bike.CaptureReplay;
  if AParams.Find('look_yaw')<>nil then begin
    State.Attention.Yaw:=EnsureRange(AParams.Get('look_yaw',0.0),-100.0,100.0);
    State.Attention.Pitch:=0;
    State.Attention.TorsoYaw:=RiderAttentionTorsoYaw(State.Attention.Yaw,
      State.Pose.Grounded);
  end;
  State.Phase := Frac(AParams.Get('phase', Double(State.Phase)));
  State.BreathPhase := Frac(AParams.Get('breath', Double(State.BreathPhase)));
  State.BreathLoad := EnsureRange(AParams.Get('breath_load', Double(State.BreathLoad)),0.0,2.0);
  State.RiderEffort := EnsureRange(AParams.Get('effort', Double(State.RiderEffort)),0.0,3.0);
  State.RiderEffortTarget := State.RiderEffort;
  State.BodyDynamicsInput.PowerW:=State.RiderEffort*220;
  State.BodyDynamicsInput.LateralAccel:=AParams.Get('lateral_accel',0.0);
  State.BodyDynamicsInput.ExternalLeanDeg:=0;
  State.BodyDynamicsSituation:=True;
  if AParams.Find('body_dynamics')<>nil then
    State.BodyDynamicsEnabled:=AParams.Get('body_dynamics',True);
  State.AnimElapsed := AParams.Get('time', Double(State.AnimElapsed));
  State.SteerAngleDeg := 0;
  State.PedalSteerDeg := 0;
  State.PedalLeanDeg := 0;
  Cadence := EnsureRange(AParams.Get('cadence', Double(State.MotionCadence)),0.0,200.0);
  State.MotionCadence := Cadence;
  State.PedalRate := Cadence / 60;
  if Cadence > 0 then State.CrankIntervalCur := 60 / Cadence
  else State.CrankIntervalCur := 9999;
  State.TripoPrevElapsed := State.AnimElapsed;
  State.PhasePrevElapsed := State.AnimElapsed;
  Anchor := AParams.Get('anchor', TJSONArray(nil));
  Facing := AParams.Get('facing', TJSONArray(nil));
  if Assigned(Anchor) and (Anchor.Count <> 3) then
    raise Exception.Create('anchor must contain three coordinates');
  if Assigned(Facing) and (Facing.Count <> 3) then
    raise Exception.Create('facing must contain three coordinates');
  if Assigned(Anchor) then ViewPlay.AvatarTransform.Translation :=
    Vector3(Anchor.Floats[0], Anchor.Floats[1], Anchor.Floats[2]);
  if Assigned(Facing) then
  begin
    ViewPlay.AvatarTransform.SetView(
      Vector3(Facing.Floats[0], Facing.Floats[1], Facing.Floats[2]), Vector3(0,1,0));
    { Physics stores pitch/turn roll on SceneAvatar, below AvatarTransform.
      A reproducible flat-road diagnostic must clear that second transform,
      while AnimateFrame below retains the rider's own pedal-induced roll. }
    if Assigned(ViewPlay.Bike.Group.Parent) then
      ViewPlay.Bike.Group.Parent.Rotation := Vector4(0,1,0,ModelBaseYRotation);
  end;
  Bike.RestoreReplay(State);
  Bike.SampleRiderDynamics;
  if BotIndex>=0 then
  begin
    Bike.RiderScene.RenderOptions.CachedAnimationRevision:=
      Bike.RiderScene.RenderOptions.CachedAnimationRevision+1;
    ViewPlay.LocalBots.InvalidateShadowPose(BotIndex);
  end;
  AResult.Add('sample', Bike.RiderMotionDebugJson);
  AResult.Add('gpu', Bike.GpuAnim);
end;

procedure CmdBikeSetGpuAnim(const AParams: TJSONObject; AResult: TJSONObject);
begin
  if (not Assigned(ViewPlay)) or (ViewPlay.Bike = nil) then
    raise Exception.Create('bike not available (play view not started?)');
  ViewPlay.Bike.GpuAnim := AParams.Get('enabled', True);
  AResult.Add('ok', True);
  AResult.Add('enabled', ViewPlay.Bike.GpuAnim);
end;

{ ── bike.wheels_debug ────────────────────────────────────────────────── }

procedure CmdBikeWheelsDebug(const AParams: TJSONObject; AResult: TJSONObject);
begin
  if (not Assigned(ViewPlay)) or (ViewPlay.Bike = nil) then
    raise Exception.Create('bike not available (play view not started?)');
  AResult.Add('wheels', ViewPlay.Bike.WheelsDebugJson);
  if Assigned(ViewPlay.AvatarTransform) then
    AResult.Add('avatar_translation', Format('%.3f, %.3f, %.3f',
      [ViewPlay.AvatarTransform.Translation.X,
       ViewPlay.AvatarTransform.Translation.Y,
       ViewPlay.AvatarTransform.Translation.Z]));
end;

{ ── bike.set_frustum_culling ─────────────────────────────────────────── }

procedure CmdBikeSetFrustumCulling(const AParams: TJSONObject; AResult: TJSONObject);
var
  V: Boolean;
begin
  if (not Assigned(ViewPlay)) or (ViewPlay.Bike = nil) or
     (ViewPlay.Bike.RiderScene = nil) then
    raise Exception.Create('bike not available (play view not started?)');
  V := AParams.Get('enabled', True);
  ViewPlay.Bike.RiderScene.ShapeFrustumCulling := V;
  ViewPlay.Bike.RiderScene.SceneFrustumCulling := V;
  AResult.Add('ok', True);
  AResult.Add('shape_culling', ViewPlay.Bike.RiderScene.ShapeFrustumCulling);
  AResult.Add('scene_culling', ViewPlay.Bike.RiderScene.SceneFrustumCulling);
end;

{ ── world.agents_debug — позиции/курсоры всех агентов ────────────────── }

procedure CmdMotionTrace(const AParams: TJSONObject; AResult: TJSONObject);
begin
  if AParams.Find('enabled') <> nil then begin
    MotionTrace.Requested := AParams.Get('enabled', True);
    if not MotionTrace.Requested then MotionTrace.Stop;
  end;
  MotionTrace.Flush;
  AResult.Add('enabled', MotionTrace.Requested);
  AResult.Add('active', MotionTrace.Target <> nil);
  AResult.Add('file', MotionTrace.FileName);
  AResult.Add('frames', Int64(MotionTrace.Frames));
  AResult.Add('rider_jumps', MotionTrace.Jumps);
  AResult.Add('stage_jumps', MotionTrace.VisualJumps);
  AResult.Add('max_physics_error_m', MotionTrace.MaxError);
end;

procedure CmdWorldAgentsDebug(const AParams: TJSONObject; AResult: TJSONObject);
var
  I: Integer;
  Ag: TPhysicalAgent;
  Arr: TJSONArray;
  O: TJSONObject;
begin
  if (not Assigned(ViewPlay)) or (ViewPlay.World = nil) then
    raise Exception.Create('world not available (play view not started?)');
  Arr := TJSONArray.Create;
  for I := 0 to ViewPlay.World.Agents.Count - 1 do
  begin
    Ag := TPhysicalAgent(ViewPlay.World.Agents[I]);
    if Ag = nil then Continue;
    O := TJSONObject.Create;
    O.Add('name', Ag.Name);
    if Assigned(Ag.State) then
    begin
      O.Add('pos', Format('%.2f,%.2f,%.2f',
        [Ag.State.WorldPosition.X, Ag.State.WorldPosition.Y,
         Ag.State.WorldPosition.Z]));
      O.Add('speed', Ag.State.CurrentSpeed);
      O.Add('lane_offset', Ag.State.LaneOffset);
      O.Add('lane_managed', Ag.State.LaneOffsetExternal);
      O.Add('traffic_speed_limit', Ag.State.TrafficSpeedLimit);
      O.Add('power', Ag.State.AppliedPowerWatts);
      O.Add('cum_dist', Ag.State.CumulativeDistance);
      O.Add('ground_y', Ag.State.LastGroundY);
      O.Add('physics_pos', TJSONArray.Create([Ag.State.WorldPosition.X,
        Ag.State.WorldPosition.Y, Ag.State.WorldPosition.Z]));
      O.Add('movement_velocity', TJSONArray.Create([Ag.State.MovementVelocity.X,
        Ag.State.MovementVelocity.Y, Ag.State.MovementVelocity.Z]));
      O.Add('accumulated_time', Ag.State.AccumulatedTime);
      if Assigned(Ag.Actor.Transform) then
        O.Add('visual_pos', TJSONArray.Create([Ag.Actor.Transform.Translation.X,
          Ag.Actor.Transform.Translation.Y, Ag.Actor.Transform.Translation.Z]));
      if Assigned(Ag.Path) then
      begin
        O.Add('follow_pos', TJSONArray.Create([
          Ag.Path.RoadCenterAt(Ag.Path.Position).X,
          Ag.Path.RoadCenterAt(Ag.Path.Position).Y,
          Ag.Path.RoadCenterAt(Ag.Path.Position).Z]));
        O.Add('follow_dir', TJSONArray.Create([
          Ag.Path.FollowDirectionXZ(Ag.Path.Position).X,
          Ag.Path.FollowDirectionXZ(Ag.Path.Position).Z]));
      end;
    end;
    if Assigned(Ag.Path) then
    begin
      O.Add('path_seg', Ag.Path.Position.Segment);
      O.Add('path_t', Ag.Path.Position.T);
      O.Add('path_count', Ag.Path.PointCount);
    end;
    Arr.Add(O);
  end;
  AResult.Add('agents', Arr);
end;

{ ── path.seek_m — jump avatar path cursor + world pos by distance ──── }

procedure CmdPathSeekM(const AParams: TJSONObject; AResult: TJSONObject);
var
  DistM: Double;
  Ag: TPhysicalAgent;
  Pos: TPathPosition;
  P: TVector3;
begin
  if not Assigned(ViewPlay) then
    raise Exception.Create('ViewPlay not available');
  if (not Assigned(ViewPlay.World)) or (ViewPlay.World.Agents.Count < 1) then
    raise Exception.Create('avatar not available');
  Ag := TPhysicalAgent(ViewPlay.World.Agents[0]);
  if (Ag = nil) or (Ag.Path = nil) or (Ag.Path.PointCount < 2) then
    raise Exception.Create('avatar path not available');
  DistM := AParams.Get('dist_m', Double(0));
  if DistM < 0 then DistM := 0;
  Pos.Segment := 0;
  Pos.T := 0;
  Ag.Path.AdvanceFollow(Pos, DistM);
  Ag.TeleportToPath(Pos);
  P := Ag.State.WorldPosition;
  AResult.Add('ok', True);
  AResult.Add('dist_m', DistM);
  AResult.Add('path_seg', Pos.Segment);
  AResult.Add('path_t', Pos.T);
  AResult.Add('pos', Format('%.2f,%.2f,%.2f', [P.X, P.Y, P.Z]));
end;

{ ── path.dump — дамп данных притяжения райдера ────────────────────────── }

procedure CmdPathDump(const AParams: TJSONObject; AResult: TJSONObject);
var
  F: String;
begin
  if not Assigned(ViewPlay) then
    raise Exception.Create('ViewPlay not available');
  if not ViewPlay.SessionAlive then
    raise Exception.Create('play session is not alive (no ride started?)');
  F := Trim(AParams.Get('file', ''));
  if F = '' then
    F := ExtractFilePath(ParamStr(0)) + 'path_dump.json';
  ViewPlay.DumpRidePath(F);
  AResult.Add('ok', True);
  AResult.Add('file', F);
end;

{ ── path.fit_spheres — toggle red/green FIT path spheres ─────────────── }

procedure CmdPathFitSpheres(const AParams: TJSONObject; AResult: TJSONObject);
var
  En: Boolean;
begin
  if not Assigned(ViewPlay) then
    raise Exception.Create('ViewPlay not available');
  if not Assigned(ViewPlay.Osm) or (not ViewPlay.Osm.Active) then
    raise Exception.Create('streaming map not active (load FIT ride first)');
  if AParams.Find('enabled') <> nil then
  begin
    En := AParams.Get('enabled', True);
    ViewPlay.Osm.SetFitPointOverlays(En);
  end;
  AResult.Add('ok', True);
  AResult.Add('enabled', ViewPlay.Osm.FitPointOverlaysOn);
  AResult.Add('note',
    'Red=raw FIT, green=snapped road/deck. Same as Path button on FX panel.');
end;

{ ── path.snap_analyze — green spheres vs bridges / approaches ────────── }

procedure CmdPathSnapAnalyze(const AParams: TJSONObject; AResult: TJSONObject);
var
  Js, F: String;
  Refresh: Boolean;
  ClearM: Double;
  Parsed, SumNode: TJSONData;
  SL: TStringList;
begin
  if not Assigned(ViewPlay) then
    raise Exception.Create('ViewPlay not available');
  if not Assigned(ViewPlay.Osm) or (not ViewPlay.Osm.Active) then
    raise Exception.Create('streaming map not active (load FIT ride first)');
  Refresh := AParams.Get('refresh_y', True);
  ClearM := AParams.Get('bridge_clear_m', Double(1.5));
  Js := ViewPlay.Osm.AnalyzeSnapPathJSON(Refresh, ClearM);
  F := Trim(AParams.Get('file', ''));
  if F = '' then
    F := ExtractFilePath(ParamStr(0)) + 'snap_analyze.json';
  SL := TStringList.Create;
  try
    SL.Text := Js;
    SL.SaveToFile(F);
  finally
    SL.Free;
  end;
  AResult.Add('file', F);
  { Return summary only over MCP (full samples stay on disk). }
  Parsed := nil;
  try
    Parsed := GetJSON(Js);
    if Parsed is TJSONObject then
    begin
      AResult.Add('snapped_ready', TJSONObject(Parsed).Get('snapped_ready', False));
      AResult.Add('snapped_count', TJSONObject(Parsed).Get('snapped_count', 0));
      AResult.Add('raw_count', TJSONObject(Parsed).Get('raw_count', 0));
      SumNode := TJSONObject(Parsed).Find('summary');
      if SumNode is TJSONObject then
        AResult.Add('summary', TJSONObject(SumNode).Clone as TJSONData);
      if TJSONObject(Parsed).Find('bridge_segs') <> nil then
        AResult.Add('bridge_segs', TJSONObject(Parsed).Get('bridge_segs', 0));
      if TJSONObject(Parsed).Find('y_tiles_loaded') <> nil then
        AResult.Add('y_tiles_loaded', TJSONObject(Parsed).Get('y_tiles_loaded', 0));
    end;
  except
    AResult.Add('analysis_raw_head', Copy(Js, 1, 4000));
  end;
  FreeAndNil(Parsed);
  AResult.Add('ok', True);
end;

{ ── path.arrays_compare — raw vs snap vs Y channels ──────────────────── }

procedure CmdPathArraysCompare(const AParams: TJSONObject; AResult: TJSONObject);
var
  Js, F: String;
  Refresh: Boolean;
  MaxPts, Step: Integer;
  Parsed, SumNode: TJSONData;
  SL: TStringList;
begin
  if not Assigned(ViewPlay) then
    raise Exception.Create('ViewPlay not available');
  if not Assigned(ViewPlay.Osm) or (not ViewPlay.Osm.Active) then
    raise Exception.Create('streaming map not active');
  Refresh := AParams.Get('refresh_y', True);
  MaxPts := AParams.Get('max_pts', 0);
  Step := AParams.Get('step', 1);
  Js := ViewPlay.Osm.DumpRouteArraysJSON(Refresh, MaxPts, Step);
  F := Trim(AParams.Get('file', ''));
  if F = '' then
    F := ExtractFilePath(ParamStr(0)) + 'route_arrays.json';
  SL := TStringList.Create;
  try
    SL.Text := Js;
    SL.SaveToFile(F);
  finally
    SL.Free;
  end;
  AResult.Add('file', F);
  Parsed := nil;
  try
    Parsed := GetJSON(Js);
    if Parsed is TJSONObject then
    begin
      AResult.Add('n', TJSONObject(Parsed).Get('n', 0));
      AResult.Add('len_snap', TJSONObject(Parsed).Get('len_snap', 0));
      AResult.Add('len_green_y', TJSONObject(Parsed).Get('len_green_y', 0));
      SumNode := TJSONObject(Parsed).Find('summary');
      if SumNode is TJSONObject then
        AResult.Add('summary', TJSONObject(SumNode).Clone as TJSONData);
    end;
  except
    AResult.Add('head', Copy(Js, 1, 2000));
  end;
  FreeAndNil(Parsed);
  AResult.Add('ok', True);
  AResult.Add('note',
    'Full rows on disk. green_y=green spheres, raw_ground_y=red, alt_m=blue, alt_cal=cyan.');
end;

{ ── path.wobble — test periodic lateral carrot sway (lean/steer visible) ─ }

procedure CmdAvatarLeanTest(const AParams: TJSONObject; AResult: TJSONObject);
var
  En: Boolean;
  LeanAmp, SteerAmp, Per: Double;
  DoCfg: Boolean;
begin
  if not Assigned(ViewPlay) then
    raise Exception.Create('ViewPlay not available');
  if Application.MainWindow.Container.View <> ViewPlay then
    raise Exception.Create('play view is not active');
  DoCfg := (AParams.Find('enabled') <> nil)
    or (AParams.Find('lean_amp_deg') <> nil)
    or (AParams.Find('steer_amp_deg') <> nil)
    or (AParams.Find('period_s') <> nil);
  if DoCfg then
  begin
    if AParams.Find('enabled') <> nil then
      En := AParams.Get('enabled', True)
    else
      En := True;
    LeanAmp := AParams.Get('lean_amp_deg', Double(25.0));
    SteerAmp := AParams.Get('steer_amp_deg', Double(30.0));
    Per := AParams.Get('period_s', Double(4.0));
    ViewPlay.SetLeanSteerTest(En, LeanAmp, SteerAmp, Per);
  end;
  AResult.Add('ok', True);
  AResult.Add('enabled', ViewPlay.LeanSteerTestActive);
  AResult.Add('last_lean_deg', ViewPlay.LeanSteerTestLastLeanDeg);
  AResult.Add('last_steer_deg', ViewPlay.LeanSteerTestLastSteerDeg);
  AResult.Add('note',
    'Stationary sine lean L/R + bar steer. No sim.play. Top cam: distance=0.');
end;

procedure CmdPathWobble(const AParams: TJSONObject; AResult: TJSONObject);
var
  En: Boolean;
  Amp, Per: Single;
begin
  Amp := -1;
  Per := -1;
  if AParams.Find('amplitude_m') <> nil then
    Amp := AParams.Get('amplitude_m', 2.0);
  if AParams.Find('period_s') <> nil then
    Per := AParams.Get('period_s', 8.0);
  if AParams.Find('enabled') <> nil then
    En := AParams.Get('enabled', True)
  else
    { No enabled key: enable when amplitude/period given, else report only. }
    En := PathTestWobbleIsEnabled or (Amp > 0) or (Per > 0);
  if (AParams.Find('enabled') <> nil) or (Amp > 0) or (Per > 0) then
    PathTestWobbleConfigure(En, Amp, Per);
  AResult.Add('ok', True);
  AResult.Add('enabled', PathTestWobbleIsEnabled);
  AResult.Add('amplitude_m', PathTestWobbleGetAmplitudeM);
  AResult.Add('period_s', PathTestWobbleGetPeriodS);
  AResult.Add('note',
    'Sine L/R on carrot (meters). Forces yaw → lean + handlebar steer. ' +
    'Applies live to all agents. CLI: --path-wobble / --path-wobble=2.5');
end;

procedure CmdPathBisectFlags(const AParams: TJSONObject; AResult: TJSONObject);
var
  Pull, Full: Boolean;
begin
  Pull := PathRoadPriorityPullEnabled;
  Full := PathFindFullRescanEnabled;
  if AParams.Find('road_priority_pull') <> nil then
    Pull := AParams.Get('road_priority_pull', Pull);
  if AParams.Find('findpath_fullscan') <> nil then
    Full := AParams.Get('findpath_fullscan', Full);
  if (AParams.Find('road_priority_pull') <> nil)
     or (AParams.Find('findpath_fullscan') <> nil) then
    PathBisectConfigure(Pull, Full);
  AResult.Add('ok', True);
  AResult.Add('road_priority_pull', PathRoadPriorityPullEnabled);
  AResult.Add('findpath_fullscan', PathFindFullRescanEnabled);
  AResult.Add('note',
    'road_priority_pull=true → ApplySnappedWidths(…, aspBridge) XZ pull for ' +
    'deck/exit; false (default) → aspCamera widths+centers only (camera-safe). ' +
    'findpath_fullscan: full rescan if seed >50m. Set pull BEFORE ride.load_fit. ' +
    'CLI: --road-pull|--bridge-path / --no-road-pull|--camera-path');
end;

procedure CmdPhysicsGroundLog(const AParams: TJSONObject; AResult: TJSONObject);
var
  Act, F: string;
begin
  Act := LowerCase(Trim(AParams.Get('action', 'status')));
  if Act = 'start' then
  begin
    F := Trim(AParams.Get('path', ''));
    if F = '' then
      F := ExtractFilePath(ParamStr(0)) + 'logs' + PathDelim +
        'wheel_ground_' + FormatDateTime('yyyymmdd_hhnnss', Now) + '.csv';
    ForceDirectories(ExtractFilePath(F));
    PhysicsGroundLogStart(F);
    AResult.Add('ok', True);
    AResult.Add('active', True);
    AResult.Add('path', PhysicsGroundLogPath);
    AResult.Add('note',
      'CSV: front/rear wheel ground samples + source ' +
      '(mesh=direct GroundField triangle Y, NOT ray; hold=query miss; ' +
      'ray=PhysicsRayCast only if GroundQuery nil). Streaming always mesh/hold.');
    Exit;
  end;
  if Act = 'stop' then
  begin
    PhysicsGroundLogStop;
    AResult.Add('ok', True);
    AResult.Add('active', False);
    AResult.Add('path', PhysicsGroundLogPath);
    Exit;
  end;
  AResult.Add('ok', True);
  AResult.Add('active', PhysicsGroundLogActive);
  AResult.Add('path', PhysicsGroundLogPath);
end;

{ ── app.fps_mode ─────────────────────────────────────────────────────── }

procedure CmdGraphicsPreview(const AParams:TJSONObject; AResult:TJSONObject);
var Scene:TGraphicsBenchmarkScene;Samples:TJSONArray;Ms:Double;
begin
  Scene:=ActiveGraphicsBenchmark;
  AResult.Add('active',Scene<>nil);
  if Scene=nil then Exit;
  if AParams.Find('rotate')<>nil then Scene.RotateCamera:=AParams.Get('rotate',True);
  if AParams.Find('animate')<>nil then Scene.AnimateScene:=AParams.Get('animate',True);
  if AParams.Find('view')<>nil then Scene.SetViewIndex(AParams.Get('view',0));
  AResult.Add('scene',Scene.Diagnostics);
  if AParams.Get('drain',False) then begin
    Samples:=TJSONArray.Create;
    while Scene.ReadGpuSample(Ms) do Samples.Add(Ms);
    AResult.Add('samples_ms',Samples);
  end;
end;

procedure CmdAppFpsMode(const AParams: TJSONObject; AResult: TJSONObject);
var
  M: String;
begin
  M := Trim(AParams.Get('mode', ''));
  if M <> '' then
  begin
    if (M <> 'vsync') and (M <> 'max') and (M <> 'low') and (M <> 'settings') then
      raise Exception.Create('mode must be vsync|max|low|settings');
    SetGameFpsModeStr(M);
  end;
  AResult.Add('ok', True);
  AResult.Add('mode', GameFpsModeStr);
  AResult.Add('limit_fps', ApplicationProperties.LimitFPS);
  AResult.Add('msaa_samples', GLFeatures.CurrentMultiSampling);
end;

{ ── perf.set / perf.state ────────────────────────────────────────────── }

procedure CmdRenderStability(const AParams:TJSONObject; AResult:TJSONObject);
begin
  if (ViewPlay=nil) or not ViewPlay.SessionAlive then
    raise Exception.Create('Active ride required');
  (ViewPlay.MainViewport as TOsmImpostorViewport).ProbeStability(AParams,AResult);
end;

procedure CmdGroundLevels(const AParams:TJSONObject; AResult:TJSONObject);
var P:TVector3; RefY,TopY,LowY,Y:Single; Hit:Boolean; Ag:TPhysicalAgent;
begin
  if (ViewPlay=nil) or (ViewPlay.Osm=nil) then raise Exception.Create('Active streamed ride required');
  Ag:=TPhysicalAgent(ViewPlay.World.Agents[0]); P:=Ag.State.WorldPosition;
  P.X:=AParams.Get('x',Double(P.X)); P.Z:=AParams.Get('z',Double(P.Z));
  RefY:=AParams.Get('reference_y',Double(Ag.State.LastGroundY));
  Hit:=ViewPlay.Osm.GroundYAt(P.X,P.Z,TopY) and
    ViewPlay.Osm.GroundNearYAt(P.X,P.Z,-1e20,LowY) and
    ViewPlay.Osm.GroundNearYAt(P.X,P.Z,RefY,Y);
  AResult.Add('hit',Hit); AResult.Add('x',P.X); AResult.Add('z',P.Z);
  AResult.Add('reference_y',RefY); AResult.Add('top_y',TopY);
  AResult.Add('lowest_y',LowY); AResult.Add('selected_y',Y);
  AResult.Add('rider_y',Ag.State.LastGroundY);
  AResult.Add('front_y',Ag.State.FrontGroundPoint.Y);
  AResult.Add('front_valid',Ag.State.FrontGroundPointValid);
end;

procedure CmdPathSurfaceLayers(const AParams:TJSONObject; AResult:TJSONObject);
var Ag:TPhysicalAgent; Pos:TPathPosition; P,Prev:TVector3;
  I:Integer; Dist,TopY,LowY,Y:Single; Rows:TJSONArray; Row:TJSONObject;
begin
  if (ViewPlay=nil) or (ViewPlay.Osm=nil) then raise Exception.Create('Active streamed ride required');
  Ag:=TPhysicalAgent(ViewPlay.World.Agents[0]); Rows:=TJSONArray.Create; AResult.Add('samples',Rows);
  Dist:=0; Prev:=Vector3(0,0,0);
  for I:=0 to Ag.Path.PointCount-1 do
  begin
    Pos.Segment:=I; Pos.T:=0; P:=Ag.Path.RoadCenterAt(Pos);
    if I>0 then Dist:=Dist+(P-Prev).Length; Prev:=P;
    if ViewPlay.Osm.GroundYAt(P.X,P.Z,TopY) and
       ViewPlay.Osm.GroundNearYAt(P.X,P.Z,-1e20,LowY) and (TopY-LowY>2) then
    begin
      ViewPlay.Osm.GroundNearYAt(P.X,P.Z,P.Y,Y);
      Row:=TJSONObject.Create; Rows.Add(Row);
      Row.Add('segment',I); Row.Add('dist_m',Dist);
      Row.Add('x',P.X); Row.Add('z',P.Z); Row.Add('path_y',P.Y);
      Row.Add('top_y',TopY); Row.Add('lowest_y',LowY); Row.Add('selected_y',Y);
    end;
  end;
end;

procedure CmdCurbProbe(const AParams:TJSONObject; AResult:TJSONObject);
var P:TVector3; Y0,Y1:Single; WasEnabled,Hit0,Hit1:Boolean;
begin
  if (ViewPlay=nil) or (ViewPlay.Osm=nil) or (ViewPlay.Osm.Session=nil) or
     (ViewPlay.Osm.Session.Map=nil) then raise Exception.Create('Active streamed ride required');
  P:=ViewPlay.AvatarTransform.Translation;
  if not ViewPlay.Osm.Session.Map.NearestCurbPoint(AParams.Get('x',Double(P.X)),AParams.Get('z',Double(P.Z)),P) then
    raise Exception.Create('No curb within 100 metres');
  WasEnabled:=CurbContactsEnabled;
  try
    CurbContactsEnabled:=False; Hit0:=ViewPlay.Osm.GroundYAt(P.X,P.Z,Y0);
    CurbContactsEnabled:=True; Hit1:=ViewPlay.Osm.GroundYAt(P.X,P.Z,Y1);
  finally CurbContactsEnabled:=WasEnabled end;
  AResult.Add('x',P.X); AResult.Add('z',P.Z); AResult.Add('surface_y',P.Y);
  AResult.Add('ground_y',Y0); AResult.Add('contact_y',Y1);
  AResult.Add('lift_m',Y1-Y0); AResult.Add('hit',Hit0 and Hit1);
end;

procedure CmdGpuGroundSample(const AParams:TJSONObject; AResult:TJSONObject);
var X,Z,R,C,G:Single;CH,GH:Boolean;
begin
  if (ViewPlay=nil)or(ViewPlay.Osm=nil)or(ViewPlay.Osm.Session=nil)or(ViewPlay.Osm.Session.Map=nil) then
    raise Exception.Create('No streaming map');
  X:=AParams.Get('x',0.0);Z:=AParams.Get('z',0.0);R:=AParams.Get('reference_y',1.0e20);
  ViewPlay.Osm.Session.Map.ProbeGpuGround(X,Z,R,C,G,CH,GH);
  AResult.Add('cpu_hit',CH);AResult.Add('gpu_hit',GH);
  AResult.Add('cpu_y',C);AResult.Add('gpu_y',G);
  if CH and GH then AResult.Add('difference_m',G-C);
  AResult.Add('gpu_ground',ViewPlay.Osm.Session.Map.GpuGroundInfo);
end;

procedure CmdPerfRiderModel(const AParams: TJSONObject; AResult: TJSONObject);
var Path: string;
begin
  if AParams.Find('path') <> nil then
  begin
    if Assigned(ViewPlay) and ViewPlay.SessionAlive then
      raise Exception.Create('Stop the ride before changing the benchmark model');
    Path := Trim(AParams.Get('path', ''));
    if Path <> '' then
    begin
      Path := ExpandFileName(Path);
      if not FileExists(Path) then raise Exception.Create('Rider model does not exist');
    end;
    PerformanceRiderModel := Path;
  end;
  AResult.Add('path', PerformanceRiderModel);
end;

procedure CmdFarFieldProbe(const AParams:TJSONObject; AResult:TJSONObject);
begin
  if (ViewPlay=nil) or not ViewPlay.SessionAlive or (ViewPlay.Osm=nil) or
     (ViewPlay.Osm.Session=nil) then raise Exception.Create('Active OSM ride required');
  RunFarFieldProbe(ViewPlay.Osm.Session.Map,
    ViewPlay.MainViewport.Camera.Translation, AParams, AResult);
end;

procedure CmdPerfObjects(const AParams:TJSONObject; AResult:TJSONObject);
var Target:TCastleTransform;Node:TX3DNode;Parts:TStringList;I,N:Integer;
  Path,NodePath:string;Rows:TJSONArray;WithNodes:Boolean;
  procedure ListNode(A:TX3DNode;const TP,NP:string;Depth:Integer);
  var J:Integer;Row:TJSONObject;V:TX3DField;
  begin
    if (A=nil)or(Depth>64)or(Rows.Count>=8192)then Exit;
    Row:=TJSONObject.Create(['transform',TP,'node',NP,'class',A.ClassName,'name',A.X3DName]);
    V:=A.Field('visible',False);if V is TSFBool then Row.Add('visible',TSFBool(V).Value);
    Rows.Add(Row);
    if A is TAbstractGroupingNode then
      for J:=0 to TAbstractGroupingNode(A).FdChildren.Count-1 do
        ListNode(TAbstractGroupingNode(A).FdChildren[J],TP,NP+'/'+IntToStr(J),Depth+1);
  end;
  procedure ListTransform(T:TCastleTransform;const TP:string;Depth:Integer);
  var J:Integer;Row:TJSONObject;
  begin
    if (T=nil)or(Depth>64)or(Rows.Count>=8192)then Exit;
    Row:=TJSONObject.Create(['transform',TP,'class',T.ClassName,'name',T.Name,
      'exists',T.Exists,'visible',T.Visible]);Rows.Add(Row);
    if T is TCastleScene then begin
      if TCastleScene(T).RootNode<>nil then begin
        Row.Add('root',TCastleScene(T).RootNode.X3DName);
        if WithNodes then ListNode(TCastleScene(T).RootNode,TP,'',0);
      end;
    end;
    for J:=0 to T.Count-1 do ListTransform(T[J],TP+'/'+IntToStr(J),Depth+1);
  end;
begin
  if (ViewPlay=nil)or not ViewPlay.SessionAlive then
    raise Exception.Create('Active ride required');
  if (AParams.Find('visible')<>nil)and(AParams.Find('transform')=nil)then
    raise Exception.Create('A current transform path is required');
  Target:=ViewPlay.MainViewport.Items;Path:=AParams.Get('transform','');
  Parts:=TStringList.Create;
  try
    Parts.StrictDelimiter:=True;Parts.Delimiter:='/';Parts.DelimitedText:=Path;
    for I:=0 to Parts.Count-1 do if Parts[I]<>'' then begin
      if not TryStrToInt(Parts[I],N)or(N<0)or(N>=Target.Count)then
        raise Exception.Create('Invalid transform path');
      Target:=Target[N];
    end;
    Node:=nil;NodePath:=AParams.Get('node','');
    if AParams.Find('node')<>nil then begin
      if not(Target is TCastleScene)then raise Exception.Create('Node path requires a scene');
      Node:=TCastleScene(Target).RootNode;
      if Node=nil then raise Exception.Create('Scene has no root');
      Parts.DelimitedText:=NodePath;
      for I:=0 to Parts.Count-1 do if Parts[I]<>'' then begin
        if not(Node is TAbstractGroupingNode)then raise Exception.Create('Node is not a group');
        if not TryStrToInt(Parts[I],N)or(N<0)or(N>=TAbstractGroupingNode(Node).FdChildren.Count)then
          raise Exception.Create('Invalid node path');
        Node:=TAbstractGroupingNode(Node).FdChildren[N];
      end;
    end;
    { Visible, not Exists: keep lights, physics and resource ownership intact.
      Paths are session-local. Nothing is stored or traversed between MCP calls. }
    if AParams.Find('visible')<>nil then begin
      if Node=nil then Target.Visible:=AParams.Get('visible',True)
      else if Node is TAbstractShapeNode then TAbstractShapeNode(Node).Visible:=AParams.Get('visible',True)
      else if Node is TAbstractGroupingNode then TAbstractGroupingNode(Node).Visible:=AParams.Get('visible',True)
      else raise Exception.Create('Only drawable groups/shapes can be hidden');
      if AParams.Get('brief',False) then
      begin
        AResult.Add('transform',Path); AResult.Add('node',NodePath);
        AResult.Add('visible',AParams.Get('visible',True));
        Exit;
      end;
    end;
    Rows:=TJSONArray.Create;AResult.Add('objects',Rows);WithNodes:=AParams.Get('nodes',False);
    if Node<>nil then ListNode(Node,Path,NodePath,0) else ListTransform(Target,Path,0);
    AResult.Add('truncated',Rows.Count>=8192);
  finally Parts.Free end;
end;

procedure CmdPerfSet(const AParams: TJSONObject; AResult: TJSONObject);
var RoadMode: string;
begin
  { Global renderer options are useful before a ride. Session options touch
    FreeAtStop components, so reject them before applying any mutation. }
  if (AParams.Find('anim') <> nil) or
     (AParams.Find('riders') <> nil) or
     (AParams.Find('terrain') <> nil) or
     (AParams.Find('shadows') <> nil) or
     (AParams.Find('world_shadows') <> nil) or
     AParams.Get('discard_shadow_shader', False) or
     (AParams.Find('occlusion') <> nil) or
     (AParams.Find('dynamic_batching') <> nil) then
    if (ViewPlay = nil) or not ViewPlay.SessionAlive then
      raise Exception.Create('Active ride required for session render options');
  if AParams.Find('procedural_trees')<>nil then
    ProceduralVegetationActive:=AParams.Get('procedural_trees',True);
  if AParams.Find('tree_season')<>nil then
    ProceduralVegetationSeason:=WrapTreeSeason(AParams.Get('tree_season',0.25));
  if AParams.Find('vegetation')<>nil then RenderTreesActive:=AParams.Get('vegetation',True);
  if AParams.Find('grass')<>nil then RenderGrassActive:=AParams.Get('grass',True);
  if AParams.Find('grass_blades')<>nil then GrassDrawBlades:=AParams.Get('grass_blades',True);
  if AParams.Find('grass_cards')<>nil then GrassDrawCards:=AParams.Get('grass_cards',True);
  if AParams.Find('grass_carpet')<>nil then GrassDrawCarpet:=AParams.Get('grass_carpet',True);
  if AParams.Find('grass_lod')<>nil then GrassBladeLodActive:=AParams.Get('grass_lod',True);
  if AParams.Find('vegetation_branches')<>nil then
    VegetationBranchesEnabled:=AParams.Get('vegetation_branches',True);
  if AParams.Find('curb_contacts') <> nil then
    CurbContactsEnabled:=AParams.Get('curb_contacts',True);
  if AParams.Find('road_material') <> nil then
  begin
    RoadMode := AParams.Get('road_material', 'cached');
    if RoadMode = 'legacy' then SetRoadMaterialMode(rmmLegacy,False)
    else if RoadMode = 'direct' then SetRoadMaterialMode(rmmDirect,False)
    else if RoadMode = 'cached' then SetRoadMaterialMode(rmmCached,False)
    else raise Exception.Create('road_material: expected legacy, direct or cached');
  end;
  if not Assigned(ViewPlay) then
    raise Exception.Create('ViewPlay not available');
  if AParams.Find('log_shaders') <> nil then
  begin
    LogShaders := AParams.Get('log_shaders', False);
    if LogShaders then InitializeLog;
    AResult.Add('shader_log_path', LogOutput);
    AResult.Add('log_shaders', LogShaders);
  end;
  if AParams.Find('anim') <> nil then
    ViewPlay.SetPerfAnim(AParams.Get('anim', True));
  if AParams.Find('riders') <> nil then
    ViewPlay.SetPerfRiders(AParams.Get('riders', True));
  if AParams.Find('terrain') <> nil then
    ViewPlay.SetPerfTerrain(AParams.Get('terrain', True));
  if AParams.Find('shadows') <> nil then
    ViewPlay.SetPerfShadows(AParams.Get('shadows', True));
  if AParams.Find('world_shadows') <> nil then
    ViewPlay.SetAtlasWorldShadows(AParams.Get('world_shadows', True));
  if AParams.Get('discard_shadow_shader', False) then
  begin
    if ViewPlay.PerfShadows then
      raise Exception.Create('Disable rider shadows before discarding their shader binding');
    ClearGroundRiderShadow;
  end;
  if AParams.Find('occlusion') <> nil then
    ViewPlay.SetOcclusionCulling(AParams.Get('occlusion', True), AParams.Get('persist', False));
  if AParams.Find('dynamic_batching') <> nil then
    ViewPlay.MainViewport.DynamicBatching := AParams.Get('dynamic_batching', False);
  if AParams.Find('tree_pass_batching')<>nil then TreePassBatching:=AParams.Get('tree_pass_batching',True);
  if AParams.Find('grass_base_instance')<>nil then GrassBaseInstance:=AParams.Get('grass_base_instance',True);
  if AParams.Find('shared_uniform_arrays')<>nil then
    UseSharedUniformArrayCache:=AParams.Get('shared_uniform_arrays',True);
  if AParams.Find('shared_effect_revisions')<>nil then
    UseSharedEffectRevisionCache:=AParams.Get('shared_effect_revisions',True);
  if AParams.Find('shared_effect_bindings')<>nil then
    UseSharedEffectBindings:=AParams.Get('shared_effect_bindings',True);
  if AParams.Find('binary_shader_names')<>nil then
    UseBinaryShaderNames:=AParams.Get('binary_shader_names',True);
  if AParams.Find('pose_cache')<>nil then
    UseCachedRiderMeshes:=AParams.Get('pose_cache',True);
  if AParams.Find('delayed_pose')<>nil then
    UseDelayedRiderMeshes:=AParams.Get('delayed_pose',False);
  AResult.Add('ok', True);
  AResult.Add('tree_pass_batching',TreePassBatching);
  AResult.Add('grass_base_instance',GrassBaseInstance);
  AResult.Add('shared_uniform_arrays',UseSharedUniformArrayCache);
  AResult.Add('shared_effect_revisions',UseSharedEffectRevisionCache);
  AResult.Add('shared_effect_bindings',UseSharedEffectBindings);
  AResult.Add('binary_shader_names',UseBinaryShaderNames);
  AResult.Add('pose_cache',UseCachedRiderMeshes);
  AResult.Add('delayed_pose',UseDelayedRiderMeshes);
  AResult.Add('anim', ViewPlay.PerfAnim);
  AResult.Add('riders', ViewPlay.PerfRiders);
  AResult.Add('terrain', ViewPlay.PerfTerrain);
  AResult.Add('shadows', ViewPlay.PerfShadows);
end;

procedure CmdPoiModels(const AParams: TJSONObject; AResult: TJSONObject);
begin
  if (AParams.Find('enabled') <> nil) or (AParams.Find('batched') <> nil) or
    (AParams.Find('traffic_signals') <> nil) then
  begin
    if Assigned(ViewPlay) and ViewPlay.SessionAlive then
      raise Exception.Create('Stop the ride before changing POI assembly');
    { Both legacy POI meshes and model instances are gated by this flag
      when assembling OSM scenes. No change to the baked cache or Dream. }
    RenderPOIActive := AParams.Get('enabled', RenderPOIActive);
    RenderPOIBatchingActive := AParams.Get('batched', RenderPOIBatchingActive);
    RenderTrafficSignalsActive := AParams.Get('traffic_signals', RenderTrafficSignalsActive);
  end;
  AnimateTrafficSignalsActive := AParams.Get('animate_signals', AnimateTrafficSignalsActive);
  AResult.Add('enabled', RenderPOIActive);
  AResult.Add('batched', RenderPOIBatchingActive);
  AResult.Add('traffic_signals', RenderTrafficSignalsActive);
  AResult.Add('animate_signals', AnimateTrafficSignalsActive);
end;

type
  TMcpEffectParts = class(TX3DNodeList)
    Stage: TShaderType;
    procedure Collect(Node: TX3DNode);
  end;

procedure TMcpEffectParts.Collect(Node: TX3DNode);
var I: Integer; Part: TEffectPartNode;
begin
  for I := 0 to TEffectNode(Node).FdParts.Count-1 do
    if TEffectNode(Node).FdParts[I] is TEffectPartNode then
    begin
      Part := TEffectPartNode(TEffectNode(Node).FdParts[I]);
      if Part.ShaderType = Stage then AddIfNotExists(Part);
    end;
end;

procedure CmdRiderRender(const AParams: TJSONObject; AResult: TJSONObject);
var
  S: TCastleScene;
  N: TX3DNode;
  SunWorld: TVector3;
  Stats: TRenderStatistics;
  Part: TEffectPartNode;
  ShaderText: TStringList;
  Parts: TMcpEffectParts;
  EffectName, StageName: String;
  I: Integer;
  Responses, ResponseUpdate: TMFVec4f;
  ResponseValues, ResponseInput: TJSONArray;
  Response: TVector4;
begin
  if (ViewPlay = nil) or (ViewPlay.Bike = nil) or
     (ViewPlay.Bike.TripoRider = nil) then
    raise Exception.Create('Active rider required');
  S := ViewPlay.Bike.TripoRider.Scene;
  N := S.RootNode.FindNode(TEffectNode, 'TripoGpuSkin', [fnNilOnMissing]);
  if (N <> nil) and (N.Field('uMuscleResponse', False) is TMFVec4f) then
  begin
    Responses := TMFVec4f(N.Field('uMuscleResponse'));
    if AParams.Find('muscle_responses') <> nil then
    begin
      ResponseInput := AParams.Arrays['muscle_responses'];
      if ResponseInput.Count <> Responses.Count then
        raise Exception.Create('Expected one response for each rider muscle');
      for I := 0 to ResponseInput.Count-1 do
        if (ResponseInput.Types[I] <> jtArray) or (ResponseInput.Arrays[I].Count <> 4) then
          raise Exception.Create('Muscle response must have four numbers');
      ResponseUpdate := TMFVec4f.Create(nil, False, 'response', []);
      try
        for I := 0 to Responses.Count-1 do
          ResponseUpdate.Items.Add(Vector4(ResponseInput.Arrays[I].Floats[0],
            ResponseInput.Arrays[I].Floats[1], ResponseInput.Arrays[I].Floats[2],
            ResponseInput.Arrays[I].Floats[3]));
        Responses.Send(ResponseUpdate);
      finally ResponseUpdate.Free end;
    end;
    ResponseValues := TJSONArray.Create;
    for I := 0 to Responses.Count-1 do
    begin
      Response := Responses.Items[I];
      ResponseValues.Add(TJSONArray.Create([Response.X,Response.Y,Response.Z,Response.W]));
    end;
    AResult.Add('muscle_responses', ResponseValues);
  end;
  if (AParams.Find('shader_file') <> nil) or
     (AParams.Find('save_shader_file') <> nil) then
  begin
    EffectName := AParams.Get('shader_effect', 'TripoGpuSkin');
    StageName := AParams.Get('shader_stage', 'vertex');
    Parts := TMcpEffectParts.Create(False);
    ShaderText := TStringList.Create;
    try
      if StageName = 'vertex' then Parts.Stage := stVertex
      else if StageName = 'fragment' then Parts.Stage := stFragment
      else raise Exception.Create('shader_stage: expected vertex or fragment');
      S.RootNode.EnumerateNodes(TEffectNode, EffectName, @Parts.Collect, False);
      if Parts.Count = 0 then raise Exception.Create('Rider shader effect/stage not found');
      if AParams.Find('shader_file') <> nil then
      begin
        ShaderText.LoadFromFile(AParams.Get('shader_file', ''));
        for I := 0 to Parts.Count-1 do
        begin
          Part := TEffectPartNode(Parts[I]);
          Part.Scene := S;
          Part.Contents := ShaderText.Text;
        end;
        S.ChangedAll;
      end;
      if AParams.Find('save_shader_file') <> nil then
      begin
        ShaderText.Text := TEffectPartNode(Parts[0]).Contents;
        ShaderText.SaveToFile(AParams.Get('save_shader_file', ''));
      end;
      AResult.Add('shader_parts', Parts.Count);
    finally ShaderText.Free; Parts.Free end;
  end;
  if AParams.Find('lighting') <> nil then
    S.RenderOptions.Lighting := AParams.Get('lighting', True);
  if ViewPlay.Bike.TripoRider.SelfOcclusion<>nil then
  begin
    if AParams.Find('self_occlusion')<>nil then
      ViewPlay.Bike.TripoRider.SelfOcclusion.Strength:=AParams.Get('self_occlusion',0.75);
    AResult.Add('self_occlusion',ViewPlay.Bike.TripoRider.SelfOcclusion.Strength);
    AResult.Add('self_occlusion_pose_samples',Int64(ViewPlay.Bike.TripoRider.SelfOcclusion.PoseSamples));
  end;
  if AParams.Find('textures') <> nil then
    S.RenderOptions.Textures := AParams.Get('textures', True);
  if AParams.Find('scene_lights') <> nil then
    S.RenderOptions.ReceiveSceneLights := AParams.Get('scene_lights', True);
  if AParams.Find('global_lights') <> nil then
    S.RenderOptions.ReceiveGlobalLights := AParams.Get('global_lights', True);
  N := S.RootNode.FindNode(TEnvironmentLightNode, 'RiderEnv', [fnNilOnMissing]);
  if N <> nil then
  begin
    if AParams.Find('environment') <> nil then
      TEnvironmentLightNode(N).FdOn.Send(AParams.Get('environment', True));
    AResult.Add('environment', TEnvironmentLightNode(N).FdOn.Value);
  end;
  N := S.RootNode.FindNode(TEffectNode, 'RiderGroundShade', [fnNilOnMissing]);
  if N <> nil then
  begin
    if AParams.Find('ground_shade') <> nil then
      TEffectNode(N).Enabled := AParams.Get('ground_shade', True);
    AResult.Add('ground_shade', TEffectNode(N).Enabled);
  end;
  AResult.Add('lighting', S.RenderOptions.Lighting);
  AResult.Add('textures', S.RenderOptions.Textures);
  AResult.Add('scene_lights', S.RenderOptions.ReceiveSceneLights);
  AResult.Add('global_lights', S.RenderOptions.ReceiveGlobalLights);
  AResult.Add('lights', ViewPlay.Bike.TripoRider.LightDiag);
  N := S.RootNode.FindNode(TDirectionalLightNode, 'RiderKey', [fnNilOnMissing]);
  if (N <> nil) and S.HasWorldTransform then
  begin
    SunWorld := S.WorldTransform.MultDirection(TDirectionalLightNode(N).Direction).Normalize;
    AResult.Add('sun_direction_world', TJSONArray.Create([SunWorld.X, SunWorld.Y, SunWorld.Z]));
    AResult.Add('sun_direction_error', (SunWorld - ViewPlay.Bike.ShadowSunWorldDir.Normalize).Length);
  end;
  AResult.Add('ground_shade_level', ViewPlay.Bike.TripoRider.GroundShade);
  AResult.Add('triangles', S.TrianglesCount);
  AResult.Add('vertices', S.VerticesCount);
  Stats := ViewPlay.MainViewport.Statistics;
  AResult.Add('draw_calls', Stats.DrawCalls);
  AResult.Add('shapes_rendered', Stats.ShapesRendered);
  AResult.Add('shapes_visible', Stats.ShapesVisible);
  AResult.Add('scenes_rendered', Stats.ScenesRendered);
end;

procedure CmdShadowTestRiders(const AParams: TJSONObject; AResult: TJSONObject);
begin
  if not Assigned(ViewPlay) or not ViewPlay.SessionAlive then
    raise Exception.Create('Start a ride before the shadow test');
  ViewPlay.SetShadowTestRiders(AParams.Get('count', 0), AParams.Get('zones', False));
  AResult.Add('count', AParams.Get('count', 0));
end;

procedure CmdScreenFX(const AParams:TJSONObject;AResult:TJSONObject);
var FX:TScreenFX;
begin
  if not Assigned(ViewPlay) or not ViewPlay.SessionAlive or
     not Assigned(ViewPlay.ScreenFX) then raise Exception.Create('Start a ride first');
  FX:=ViewPlay.ScreenFX;
  if AParams.Find('enabled')<>nil then FX.Enabled:=AParams.Get('enabled',True);
  if AParams.Find('softening')<>nil then FX.SofteningLevel:=AParams.Get('softening',0);
  if AParams.Find('fog')<>nil then FX.FogEnabled:=AParams.Get('fog',False);
  if AParams.Find('bloom')<>nil then FX.BloomEnabled:=AParams.Get('bloom',False);
  if AParams.Find('tone')<>nil then FX.ToneEnabled:=AParams.Get('tone',False);
  if AParams.Find('kuwahara')<>nil then FX.KuwaharaEnabled:=AParams.Get('kuwahara',False);
  if AParams.Find('posterize')<>nil then FX.PosterizeEnabled:=AParams.Get('posterize',False);
  if AParams.Find('hatch')<>nil then FX.HatchEnabled:=AParams.Get('hatch',False);
  AResult.Add('enabled',FX.Enabled);AResult.Add('softening',FX.SofteningLevel);
  AResult.Add('fog',FX.FogEnabled);AResult.Add('bloom',FX.BloomEnabled);
  AResult.Add('tone',FX.ToneEnabled);AResult.Add('kuwahara',FX.KuwaharaEnabled);
  AResult.Add('posterize',FX.PosterizeEnabled);AResult.Add('hatch',FX.HatchEnabled);
  AResult.Add('active_passes',FX.ActivePassCount);
  AResult.Add('depth_near',FX.FogDepthNear);AResult.Add('depth_far',FX.FogDepthFar);
end;

procedure CmdPerfCapture(const AParams:TJSONObject;AResult:TJSONObject);
var Action:string;
begin
  Action:=LowerCase(AParams.Get('action','read'));
  if not (Action='start') and not (Action='read') and not (Action='stop') then
    raise Exception.Create('action must be start, read or stop');
  if Action='start' then begin
    FreeAndNil(PerformanceProbe);
    PerformanceProbe:=TGamePerformanceProbe.Create(nil);
    Application.MainWindow.Controls.InsertFront(PerformanceProbe);
  end else if PerformanceProbe<>nil then
    PerformanceProbe.Snapshot(AResult,AParams.Get('reset',False));
  if Action='stop' then FreeAndNil(PerformanceProbe);
  AResult.Add('active',PerformanceProbe<>nil);
end;

procedure CmdLocalBots(const AParams:TJSONObject;AResult:TJSONObject);
var D:TJSONObject;Name:string;Rows:TJSONArray;I,Mask:Integer;
begin
  if(ViewPlay=nil)or(ViewPlay.LocalBots=nil)then raise Exception.Create('Active ride required');
  if AParams.Find('limit')<>nil then ViewPlay.LocalBots.SetRenderLimit(AParams.Get('limit',3));
  if AParams.Find('render')<>nil then ViewPlay.LocalBots.SetRenderEnabled(AParams.Get('render',True));
  if AParams.Find('probe_animate_paused')<>nil then
    ViewPlay.PerfAnimatePausedBots:=AParams.Get('probe_animate_paused',False);
  if AParams.Find('probe_revision_cache')<>nil then
    ViewPlay.LocalBots.SetPoseCachePolicy(Ord(AParams.Get('probe_revision_cache',True)));
  if AParams.Find('probe_pose_cache_policy')<>nil then
    ViewPlay.LocalBots.SetPoseCachePolicy(AParams.Get('probe_pose_cache_policy',-1));
  if AParams.Find('probe_mask')<>nil then begin
    Mask:=AParams.Get('probe_mask',-1);
    for I:=0 to ViewPlay.LocalBots.Bikes.Count-1 do
      if ViewPlay.LocalBots.Bikes[I]<>nil then
        TBikeInstance(ViewPlay.LocalBots.Bikes[I]).Group.Exists:=(Mask and (1 shl I))<>0;
  end;
  D:=ViewPlay.LocalBots.Diagnostics;
  try while D.Count>0 do begin Name:=D.Names[0];AResult.Add(Name,D.Extract(0)) end;finally D.Free end;
  AResult.Add('probe_animate_paused',ViewPlay.PerfAnimatePausedBots);
  if AParams.Get('shaders',False) then begin
    AResult.Add('avatar_shaders',BikeShaderDiagnostics(ViewPlay.Bike));
    Rows:=TJSONArray.Create;AResult.Add('bot_shaders',Rows);
    for I:=0 to ViewPlay.LocalBots.Bikes.Count-1 do
      Rows.Add(BikeShaderDiagnostics(TBikeInstance(ViewPlay.LocalBots.Bikes[I])));
  end;
end;

procedure CmdPerfState(const AParams: TJSONObject; AResult: TJSONObject);
var
  Stats: TRenderStatistics;
  B: TCacheBatch;
  T: TCacheTile;
  TileCount: Integer;
  Verts, Tris: Int64;
begin
  if not Assigned(ViewPlay) then
    raise Exception.Create('ViewPlay not available');
  AResult.Add('osm_tile_px', GEO_TILE_EDGE_PX);
  AResult.Add('osm_block_size', GEO_BLOCK_SIZE);
  AResult.Add('osm_grid_radius', GlobalLODConfig.StreamGridRadius);
  AResult.Add('osm_mount_worker', GlobalMountInWorker);
  AResult.Add('osm_assemble_worker', GlobalAssembleInWorker);
  AResult.Add('poi_models', RenderPOIActive);
  AResult.Add('poi_batched', RenderPOIBatchingActive);
  AResult.Add('traffic_signals', RenderTrafficSignalsActive);
  AResult.Add('traffic_animation', AnimateTrafficSignalsActive);
  AResult.Add('traffic_switch_changes', TJSONInt64Number.Create(TrafficSignalSwitchChanges));
  AResult.Add('shader_binary_hits', TJSONInt64Number.Create(TGLSLProgram.BinaryCacheHits));
  AResult.Add('shader_binary_misses', TJSONInt64Number.Create(TGLSLProgram.BinaryCacheMisses));
  AResult.Add('shader_binary_stores', TJSONInt64Number.Create(TGLSLProgram.BinaryCacheStores));
  AResult.Add('active', ViewPlay.SessionAlive);
  AResult.Add('room',ViewPlay.RoomDiagnostics);
  { Stop frees the viewport; the published component field may still hold
    its old pointer until the next Start. Diagnostics must not dereference it. }
  if not ViewPlay.SessionAlive then Exit;
  AResult.Add('anim', ViewPlay.PerfAnim);
  AResult.Add('riders', ViewPlay.PerfRiders);
  AResult.Add('terrain', ViewPlay.PerfTerrain);
  AResult.Add('shadows', ViewPlay.PerfShadows);
  AResult.Add('fps_mode', GameFpsModeStr);
  AResult.Add('prep_done', ViewPlay.RoutePrepDone);
  AResult.Add('focus', ViewPlay.TrainingFocusMode);
  { Statistics retain the last rendered 3D frame while its viewport is hidden. }
  AResult.Add('viewport_visible', ViewPlay.MainViewport.Exists);
  AResult.Add('dynamic_batching', ViewPlay.MainViewport.DynamicBatching);
  AResult.Add('occlusion', ViewPlay.MainViewport.OcclusionCulling);
  if Assigned(ViewPlay.Bike) and Assigned(ViewPlay.Bike.RiderScene) then
  begin
    AResult.Add('rider_shape_culling', ViewPlay.Bike.RiderScene.ShapeFrustumCulling);
    AResult.Add('rider_scene_culling', ViewPlay.Bike.RiderScene.SceneFrustumCulling);
    AResult.Add('rider_occlusion_culling', ViewPlay.Bike.RiderScene.SceneOcclusionCulling);
  end;
  Stats := ViewPlay.MainViewport.Statistics;
  AResult.Add('draw_calls', Stats.DrawCalls);
  AResult.Add('shapes_rendered', Stats.ShapesRendered);
  AResult.Add('shapes_visible', Stats.ShapesVisible);
  AResult.Add('scenes_rendered', Stats.ScenesRendered);
  AResult.Add('occlusion_boxes', Stats.BoxesOcclusionQueriedCount);
  AResult.Add('rider_shadow', ViewPlay.RiderShadowInfo);
  AResult.Add('rtx',ViewPlay.RtxShadowInfo(AParams.Get('reflection_diagnostics',False)));
  AResult.Add('world_shadows', ViewPlay.AtlasWorldShadows);
  AResult.Add('road_material', RoadMaterialModeName);
  AResult.Add('curb_contacts',CurbContactsEnabled);
  if Assigned(ViewPlay.Osm) and Assigned(ViewPlay.Osm.Session) and Assigned(ViewPlay.Osm.Session.Map) then
  begin
    AResult.Add('gpu_ground',ViewPlay.Osm.Session.Map.GpuGroundInfo);
    AResult.Add('grass_geometry',ViewPlay.Osm.Session.Map.GrassDiagnostics);
    AResult.Add('osm_pending_tiles', ViewPlay.Osm.Session.Map.PendingTileWork);
    if AParams.Get('geometry', False) then
    begin
      TileCount := 0; Verts := 0; Tris := 0;
      for B in ViewPlay.Osm.Session.Map.RootBlocks do
        for T in B.Tiles do
          if T.Active and (T.Scene <> nil) then
          begin
            Inc(TileCount);
            Inc(Verts, T.Scene.VerticesCount);
            Inc(Tris, T.Scene.TrianglesCount);
          end;
      AResult.Add('osm_active_tiles', TileCount);
      AResult.Add('osm_active_vertices', Verts);
      AResult.Add('osm_active_triangles', Tris);
    end;
  end;
  AResult.Add('road_cache', RoadMaterialDebug);
  AResult.Add('static_ground_shadows', Osm3dStudioSettings.GroundShadowsActive);
  AResult.Add('ground_shade', ViewPlay.GroundShadeDiag);
  AResult.Add('vegetation_shadow_draws', TJSONInt64Number.Create(TInstancedBillboardRenderer.ShadowDrawCalls));
  AResult.Add('vegetation_color_draws', TJSONInt64Number.Create(TInstancedBillboardRenderer.ColorDrawCalls));
  AResult.Add('vegetation_branches',VegetationBranchesEnabled);
  AResult.Add('procedural_trees',ProceduralVegetationActive);
  AResult.Add('tree_season',ProceduralVegetationSeason);
  AResult.Add('vegetation',RenderTreesActive);
  AResult.Add('grass',RenderGrassActive);
  AResult.Add('grass_blades',GrassDrawBlades);
  AResult.Add('grass_cards',GrassDrawCards);
  AResult.Add('grass_carpet',GrassDrawCarpet);
  AResult.Add('grass_lod',GrassBladeLodActive);
  AResult.Add('procedural_vegetation',ProceduralVegetationDiagnostics);
  AResult.Add('branch_instances_submitted',TInstancedBillboardRenderer.BranchInstancesSubmitted);
  AResult.Add('branch_draws',TJSONInt64Number.Create(TInstancedBillboardRenderer.BranchDrawCalls));
  AResult.Add('branch_shadow_draws',TJSONInt64Number.Create(TInstancedBillboardRenderer.BranchShadowDrawCalls));
  AResult.Add('update_ms', ViewPlay.FrameUpdateMs);
  AResult.Add('anim_ms', ViewPlay.FrameAnimMs);
  if Application.MainWindow <> nil then
  begin
    AResult.Add('fps_real', Application.MainWindow.Fps.RealFps);
    AResult.Add('fps_render', Application.MainWindow.Fps.OnlyRenderFps);
  end;
end;

{ ── app.screenshot ───────────────────────────────────────────────────── }

procedure CmdScreenshot(const AParams: TJSONObject; AResult: TJSONObject);
var
  Img: TRGBImage;
  Path: String;
  Ms: TMemoryStream;
  B64: TStringStream;
  Enc: TBase64EncodingStream;
begin
  if (Application.MainWindow = nil) then
    raise Exception.Create('No main window');
  { SaveScreen делает перерисовку перед захватом (back buffer reliable
    только до swap) — вызываем в главном потоке, GL-контекст валиден. }
  Img := Application.MainWindow.SaveScreen;
  try
    Path := Trim(AParams.Get('path', ''));
    if Path <> '' then
      SaveImage(Img, Path);
    if AParams.Get('inline', True) then
    begin
      Ms := TMemoryStream.Create;
      try
        SaveImage(Img, 'image/png', Ms);
        Ms.Position := 0;
        B64 := TStringStream.Create('');
        try
          Enc := TBase64EncodingStream.Create(B64);
          try
            Enc.CopyFrom(Ms, Ms.Size);
          finally
            Enc.Free;  { финализирует base64-поток }
          end;
          { Специальные ключи: McpProtocol превратит их в image content item }
          AResult.Add('_image_base64', B64.DataString);
          AResult.Add('_image_mime', 'image/png');
        finally
          B64.Free;
        end;
      finally
        Ms.Free;
      end;
    end;
    AResult.Add('width', Img.Width);
    AResult.Add('height', Img.Height);
    if Path <> '' then
      AResult.Add('path', Path);
    AResult.Add('ok', True);
  finally
    Img.Free;
  end;
end;

{ ── device.scan_* ──────────────────────────────────────────────────── }

{ ── bikefit.* ──────────────────────────────────────────────────────── }

function EnsureBikeFitPage: TBikeFitPage;
begin
  EnsureMenuVisible;
  ViewMenu.OpenTab('bikefit');
  Result := ViewMenu.BikeFitPage;
  if Result = nil then
    raise Exception.Create('bikefit page not created');
end;

procedure CmdBikeFitStatus(const AParams: TJSONObject; AResult: TJSONObject);
var
  P: TBikeFitPage;
begin
  P := EnsureBikeFitPage;
  P.McpFillStatus(AResult);
  AResult.Add('ok', True);
end;

procedure CmdBikeFitSelect(const AParams: TJSONObject; AResult: TJSONObject);
var
  P: TBikeFitPage;
  Idx: Integer;
begin
  P := EnsureBikeFitPage;
  Idx := AParams.Get('index', 0);
  P.McpSelectRider(Idx);
  P.McpFillStatus(AResult);
  AResult.Add('ok', True);
end;

procedure CmdBikeFitBody(const AParams:TJSONObject;AResult:TJSONObject);
begin EnsureBikeFitPage.McpBody(AParams,AResult) end;

procedure CmdBikeFitCamera(const AParams:TJSONObject;AResult:TJSONObject);
begin EnsureBikeFitPage.McpCamera(AParams,AResult) end;

procedure CmdBikeFitAnimation(const AParams:TJSONObject;AResult:TJSONObject);
begin EnsureBikeFitPage.McpAnimation(AParams,AResult) end;

procedure CmdBikeFitAutoFit(const AParams:TJSONObject;AResult:TJSONObject);
var P:TBikeFitPage;
begin P:=EnsureBikeFitPage;P.McpAutoFit;P.McpFillStatus(AResult) end;

procedure CmdBikeFitNudge(const AParams: TJSONObject; AResult: TJSONObject);
var
  P: TBikeFitPage;
begin
  P := EnsureBikeFitPage;
  P.McpNudge(AParams.Get('param', ''), AParams.Get('steps', 1));
  P.McpFillStatus(AResult);
  AResult.Add('ok', True);
end;

procedure CmdBikeFitSetColor(const AParams: TJSONObject; AResult: TJSONObject);
var
  P: TBikeFitPage;
  R, G, B: Double;
begin
  P := EnsureBikeFitPage;
  R := AParams.Get('r', 0.0);
  G := AParams.Get('g', 0.0);
  B := AParams.Get('b', 0.0);
  { 0..255 как в палитре; on=false — снять покраску слота }
  P.McpSetColor(AParams.Get('slot', ''), Vector3(R / 255, G / 255, B / 255),
    AParams.Get('on', True));
  AResult.Add('ok', True);
end;

procedure CmdBikeFitHair(const AParams:TJSONObject;AResult:TJSONObject);
var P:TBikeFitPage;
begin
  P:=EnsureBikeFitPage;P.McpSetHair(AParams.Get('style','short'));
  P.McpFillStatus(AResult);AResult.Add('ok',True);
end;

procedure CmdBikeFitHead(const AParams:TJSONObject;AResult:TJSONObject);
begin EnsureBikeFitPage.McpHead(AParams,AResult) end;

procedure CmdBikeFitClothing(const AParams:TJSONObject;AResult:TJSONObject);
begin EnsureBikeFitPage.McpClothing(AParams,AResult) end;

procedure CmdBikeFitLighting(const AParams: TJSONObject; AResult: TJSONObject);
var
  P: TBikeFitPage;
begin
  P := EnsureBikeFitPage;
  P.McpLighting(AParams, AResult);
  AResult.Add('ok', True);
end;

procedure CmdDeviceScanStart(const AParams: TJSONObject; AResult: TJSONObject);
begin
  if not Assigned(DeviceService) then
    raise Exception.Create('DeviceService not available');
  DeviceService.StartScan;
  AResult.Add('ok', True);
end;

procedure CmdDeviceScanStop(const AParams: TJSONObject; AResult: TJSONObject);
begin
  if not Assigned(DeviceService) then
    raise Exception.Create('DeviceService not available');
  DeviceService.StopScan;
  AResult.Add('ok', True);
end;

procedure PrepareMcpRegistry;
var PhotoSettings:TStudioSettings;
begin
  if McpActive then Exit;
  Glue:=TMcpGlue.Create;
  ApplicationProperties.OnUpdate.Add(@Glue.UpdatePump);

  RegisterMcpObject('window', Application.MainWindow);
  RegisterView('play', ViewPlay);
  RegisterView('menu', ViewMenu);
  { devices/bikefit/events/training/profile — больше не полноэкранные
    вью, а встроенные вкладки главного меню: app.switch_view по этим
    именам открывает вкладку через ViewMenu.OpenTab (см. CmdSwitchView). }
  RegisterView('freeride', ViewFreeRide);  { может быть nil — пропустится }
  RegisterView('workouteditor', ViewWorkoutEditor);
  RegisterView('mapeditor', ViewMapEditor);
  RegisterView('login', ViewLogin);
  if Assigned(DeviceService) then
    RegisterMcpObject('devices', DeviceService);
  if Assigned(AppSettings.Settings) then
    RegisterMcpObject('settings', AppSettings.Settings);

  PhotoSettings := TStudioSettings.Defaults;
  RegisterPhotoMcpTools(PhotoSettings.CacheRoot, PhotoSettings.HeightmapZoom, GEO_TILE_EDGE_PX,
    PhotoSettings.OverpassTileZoom, PhotoSettings.OverpassTimeoutS);
  RegisterPhotoViewRenderTools(@PhotoViewContext,@PhotoViewMode);
  RegisterAssistantMcpTools;

  RegisterMcpCommand('app.version', 'Client version and update policy.',
    '{"type":"object","properties":{}}', @CmdClientVersion);
  RegisterMcpCommand('app.views_list',
    'List registered views and the currently active view ' +
    '(top of the view stack), overlay state and menu button bounds.',
    '{"type":"object","properties":{}}',
    @CmdViewsList);
  RegisterMcpCommand('app.switch_view',
    'Switch Window.Container.View to a registered view by name ' +
    '(e.g. "menu", "play"). Names "devices", "bikefit", "events", ' +
    '"training", "profile", "settings", "routes", "route-library", "route-create" open the corresponding embedded tab of ' +
    'the menu view instead. During a ride the menu overlays the live scene.',
    '{"type":"object","properties":{"view":{"type":"string"}},"required":["view"]}',
    @CmdSwitchView);

  RegisterMcpCommand('map.inspect',
    'Show the route map; optionally center it. Return asynchronous map tile readiness.',
    '{"type":"object","properties":{"lat":{"type":"number"},"lon":{"type":"number"},"zoom":{"type":"integer"},'+
    '"planet":{"type":"boolean"},"pause_tiles":{"type":"boolean"},"zoom_delta":{"type":"integer"},"project_lat":{"type":"number"},"project_lon":{"type":"number"},'+
    '"screen_x":{"type":"number"},"screen_y":{"type":"number"}}}',
    @CmdFlatMap);
  RegisterMcpCommand('ui.edit','Edit a visible rider, route or workout input without reading its contents.', '{"type":"object","properties":{"name":{"type":"string"},"text":{"type":"string"}},"required":["name","text"]}',@CmdUiEdit);
  RegisterMcpCommand('workout.inspect','Inspect the active workout timeline.','{}',@CmdWorkoutInspect);
  RegisterMcpCommand('audio.inspect','Inspect sound playback and cue counters.','{}',@CmdAudioInspect);
  RegisterMcpCommand('app.open_file','Open a FIT, GPX or ZWO file in the menu.','{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}',@CmdOpenFile);
  RegisterMcpCommand('menu.inspect',
    'Inspect the current menu background and route form. Optionally select a local route file.',
    '{"type":"object","properties":{"route_path":{"type":"string"},"lat":{"type":"number"},"lon":{"type":"number"},"zoom":{"type":"integer"}}}',
    @CmdMenuInspect);
  RegisterMcpCommand('ui.inspect', 'Inspect visible UI button bounds and optionally label bounds; never returns input field values.',
    '{"type":"object","properties":{"labels":{"type":"boolean"}}}', @CmdUiInspect);
  RegisterMcpCommand('dream.inspect','Inspect baked Dream World preview or active ride.',
    '{"type":"object","properties":{"open":{"type":"boolean"},"select":{"type":"integer"},"x":{"type":"number"},"z":{"type":"number"},"y":{"type":"number"}}}',@CmdDreamInspect);
  RegisterMcpCommand('travel.select','Select transport in the menu; walking, bicycle or flight.',
    '{"type":"object","properties":{"mode":{"enum":["walk","bicycle","flight"]}},"required":["mode"]}',@CmdTravelSelect);
  RegisterMcpCommand('explore.start','Explore the world from a geographic point without a FIT route.',
    '{"type":"object","properties":{"mode":{"enum":["walk","bicycle","flight"]},"lat":{"type":"number"},"lon":{"type":"number"}},"required":["lat","lon"]}',@CmdExploreStart);
  RegisterMcpCommand('explore.state','Read transport, manual effort, position, speed and loading state.','',@CmdExploreState);
  RegisterMcpCommand('explore.input','Set held exploration controls. enabled=false releases to the keyboard. Sensor power takes priority.',
    '{"type":"object","properties":{"enabled":{"type":"boolean"},"power_axis":{"type":"number","minimum":-1,"maximum":1},"steer":{"type":"number","minimum":-1,"maximum":1},"walk_axis":{"type":"number","minimum":-1,"maximum":1}}}',@CmdExploreInput);
  RegisterMcpCommand('dream.start','Start the currently loaded Dream World.','',@CmdDreamStart);
  RegisterMcpCommand('ride.start',
    'Switch to the play view (starting it if needed) and start rider ' +
    'movement (AutoMove on).',
    '',
    @CmdRideStart);
  RegisterMcpCommand('ride.stop',
    'Stop rider movement (AutoMove off), including under menu/Assistant overlays. No-op without an active ride.',
    '',
    @CmdRideStop);
  RegisterMcpCommand('ride.load_fit',
    'Load a FIT route and ride it on the streaming map. If the play ' +
    'session is alive (active or covered by the menu), only the ' +
    'route is swapped and the rider is placed at the start — the world, ' +
    'bike and bots are NOT recreated. Otherwise starts the play view ' +
    'fresh (same as the "Ride" button on the Routes page).',
    '{"type":"object","properties":{"path":{"type":"string",' +
    '"description":"filesystem path or URI of the FIT file"}},"required":["path"]}',
    @CmdRideLoadFit);
  RegisterMcpCommand('ride.stop_full',
    'FULL ride teardown (like the "Stop" button in the menu): stops ' +
    'streaming, finalizes FIT recording, frees all play resources. ' +
    'ESC/app.switch_view menu instead overlays the running ride without pausing it.',
    '',
    @CmdRideStopFull);
  RegisterMcpCommand('avatar.lean_test',
    'Stationary lean L/R + bar steer (sine). No FIT sim.play needed — ' +
    'avatar rocks in place. Defaults: lean±25°, bars±30°, period 4s. ' +
    'Pair with camera.chase distance=0 for top-down bar view.',
    '{"type":"object","properties":{' +
    '"enabled":{"type":"boolean"},' +
    '"lean_amp_deg":{"type":"number","description":"body roll amplitude deg"},' +
    '"steer_amp_deg":{"type":"number","description":"handlebar amplitude deg"},' +
    '"period_s":{"type":"number","description":"seconds per full L-R-L cycle"}}}',
    @CmdAvatarLeanTest);
  RegisterMcpCommand('path.wobble',
    'Test periodic left/right carrot sway across road markings (meters). ' +
    'Makes lean + handlebar steer obvious. Live globals for all agents. ' +
    'Defaults: enabled, amplitude_m=2, period_s=8 (full L→R→L cycle). ' +
    'Call with enabled=false to restore micro-wobble only.',
    '{"type":"object","properties":{' +
    '"enabled":{"type":"boolean"},' +
    '"amplitude_m":{"type":"number","description":"meters each side of centre"},' +
    '"period_s":{"type":"number","description":"seconds per full L-R-L cycle"}}}',
    @CmdPathWobble);
  RegisterMcpCommand('path.bisect_flags',
    'Toggle ApplySnappedWidths purpose and FindPath fullscan. ' +
    'road_priority_pull=true → purpose=bridge (XZ pull for deck/exit); ' +
    'false (default) → purpose=camera (widths+centers only). ' +
    'findpath_fullscan: full path rescan if local seed >50m. ' +
    'Set road_priority_pull BEFORE ride.load_fit. Omit params to query.',
    '{"type":"object","properties":{' +
    '"road_priority_pull":{"type":"boolean"},' +
    '"findpath_fullscan":{"type":"boolean"}}}',
    @CmdPathBisectFlags);
  RegisterMcpCommand('physics.ground_log',
    'CSV log of wheel ground height samples: front/rear Y + source ' +
    '(mesh|hold|ray|ray_miss). Streaming maps use mesh (direct tri Y) or hold, ' +
    'never ray. action=start|stop|status; path optional for start.',
    '{"type":"object","properties":{' +
    '"action":{"type":"string","description":"start|stop|status"},' +
    '"path":{"type":"string","description":"CSV path for start"}}}',
    @CmdPhysicsGroundLog);
  RegisterMcpCommand('path.follow_state',
    'Actual physics position, steering target, lane offset, optional world-agent passage progress, existing ground-probe state and live building footprints.',
    '{"type":"object","properties":{"traffic":{"type":"boolean"},"wheels":{"type":"boolean"},"footprints":{"type":"boolean"},"radius":{"type":"number"}}}',
    @CmdPathFollowState);
  RegisterMcpCommand('path.dump',
    'Dump rider attraction data to a JSON file: avatar path world ' +
    'points, road widths, road centers, session origin, snapped point ' +
    'count, start ground Y, rider position/distance, bot path counts. ' +
    'Use to compare first vs relaunched ride.',
    '{"type":"object","properties":{"file":{"type":"string",' +
    '"description":"target JSON file; default <exedir>\\path_dump.json"}}}',
    @CmdPathDump);
  RegisterMcpCommand('path.seek_m',
    'Jump avatar path cursor + world position to distance along path (m). ' +
    'Place camera near a bridge without riding the whole route.',
    '{"type":"object","properties":{"dist_m":{"type":"number"}},"required":["dist_m"]}',
    @CmdPathSeekM);
  RegisterMcpCommand('path.fit_spheres',
    'Enable/disable FIT path debug spheres on the streaming map ' +
    '(red=raw route, green=snapped road/deck). Same as Path on FX panel.',
    '{"type":"object","properties":{' +
    '"enabled":{"type":"boolean","description":"true=show, false=hide; omit to query only"}}}',
    @CmdPathFitSpheres);
  RegisterMcpCommand('path.snap_analyze',
    'Analyze green snapped path vs bridges: missing green Y (vanishing ' +
    'spheres), green under surface (approach dips), bridge-like clearances, ' +
    'near IsBridge centerlines, way flips. Optionally refreshes green Y ' +
    'from resident tiles first. Returns summary + samples JSON.',
    '{"type":"object","properties":{' +
    '"refresh_y":{"type":"boolean","description":"re-sample green Y (default true)"},' +
    '"bridge_clear_m":{"type":"number","description":"green-ground clear for bridge-like (default 1.5)"},' +
    '"file":{"type":"string","description":"optional path to write full JSON"}}}',
    @CmdPathSnapAnalyze);
  RegisterMcpCommand('path.arrays_compare',
    'Dump parallel route arrays for compare: raw FIT vs snapped lat/lon, ' +
    'lateral_m, way_id, green_y (green spheres), raw_ground_y (red), ' +
    'alt_m (blue), alt_cal (cyan). Finds green Y gaps and max raw↔snap ' +
    'lateral drift. Full rows written to file; summary returned.',
    '{"type":"object","properties":{' +
    '"refresh_y":{"type":"boolean","description":"re-sample Y (default true)"},' +
    '"max_pts":{"type":"integer","description":"cap points (0=all)"},' +
    '"step":{"type":"integer","description":"emit every Nth point (default 1; still emits gaps)"},' +
    '"file":{"type":"string","description":"JSON path; default <exedir>\\route_arrays.json"}}}',
    @CmdPathArraysCompare);
  RegisterMcpCommand('motion.trace',
    'Per-frame rider/camera positions at every update stage. enabled toggles recording. Flushes buffered rows for analysis; decode with scripts/motion_trace.py.',
    '{"type":"object","properties":{"enabled":{"type":"boolean"}}}', @CmdMotionTrace);
  RegisterMcpCommand('world.agents_debug',
    'Live state of every physics agent (avatar, bots): name, world ' +
    'position, speed, power, cumulative distance, ground Y, path cursor ' +
    '(segment/t) and path point count.',
    '',
    @CmdWorldAgentsDebug);
  RegisterMcpCommand('camera.set_view',
    'Set a reproducible free-camera view for rendering comparisons.',
    '{"type":"object","properties":{"x":{"type":"number"},"y":{"type":"number"},"z":{"type":"number"},' +
    '"dx":{"type":"number"},"dy":{"type":"number"},"dz":{"type":"number"}},"required":["x","y","z","dx","dy","dz"]}',
    @CmdCameraSetView);
  RegisterMcpCommand('camera.set_mode',
    'Set play camera mode: cinematic | thirdperson | free. ' +
    'Clears MCP camera.chase override. Requires play view active.',
    '{"type":"object","properties":{"mode":{"type":"string",' +
    '"enum":["cinematic","thirdperson","free"]}},"required":["mode"]}',
    @CmdCameraSetMode);
  RegisterMcpCommand('camera.chase',
    'Direct chase camera each frame. Rear (cmMoto): distance>0 behind rider. ' +
    'Top-down over centre (best for bar steer): distance=0, height≈4..6. ' +
    'Defaults: distance=3, height=1.3, side=0, aim_height=0.85. ' +
    'Pass active=false to release. Overrides cinematic/thirdperson/free.',
    '{"type":"object","properties":{' +
    '"distance":{"type":"number","description":"meters behind; 0 = top-down over centre"},' +
    '"height":{"type":"number","description":"meters above rider origin"},' +
    '"side":{"type":"number","description":"meters lateral (+ = right)"},' +
    '"aim_height":{"type":"number","description":"look-at Y on rider (rear mode)"},' +
    '"active":{"type":"boolean","description":"false = release chase"}}}',
    @CmdCameraChase);
  RegisterMcpCommand('camera.get',
    'Current camera ring mode + MCP chase state (distance/height).',
    '',
    @CmdCameraGet);
  RegisterMcpCommand('camera.sample',
    'Viewport camera pos/dir + avatar pos/dir + speed (diagnostics).',
    '',
    @CmdCameraSample);
  RegisterMcpCommand('device.scan_start',
    'Start BLE/ANT+ device scan via DeviceService.',
    '',
    @CmdDeviceScanStart);
  RegisterMcpCommand('device.scan_stop',
    'Stop device scan via DeviceService.',
    '',
    @CmdDeviceScanStop);
  RegisterMcpCommand('sim.step', 'Pause and advance one simulation frame (1/60 s).', '', @CmdSimStep);
  RegisterMcpCommand('sim.play',
    'Resume the FIT simulation playback (SimSetPaused False).',
    '',
    @CmdSimPlay);
  RegisterMcpCommand('sim.pause',
    'Pause the FIT simulation playback (SimSetPaused True).',
    '',
    @CmdSimPause);
  RegisterMcpCommand('sim.info',
    'FIT simulator state: active, paused, cur_sec, total_sec, speed_x, ' +
    'plus the current cadence label from the HUD.',
    '',
    @CmdSimInfo);
  RegisterMcpCommand('sim.speed',
    'Set replay rate 1/60..8. 1/60 holds each simulation frame for one real second; physics, pose and camera share this clock.',
    '{"type":"object","properties":{"mul":{"type":"number","minimum":0.0166666666666667,"maximum":8}},"required":["mul"]}',
    @CmdSimSpeed);
  RegisterMcpCommand('sim.seek',
    'Restore ride position, pose and camera from the recorded timeline. Clamped to available checkpoints; returns actual seek_sec.',
    '{"type":"object","properties":{"sec":{"type":"number"}},"required":["sec"]}',
    @CmdSimSeek);
  RegisterMcpCommand('bike.anim_debug',
    'Crank/wheel animation diagnostics of the avatar bike: every ' +
    'CrankTimer/WheelTimer instance (per LOD), Enabled/Active/' +
    'CycleInterval/ElapsedTimeInCycle, scene playback state.',
    '{"type":"object","properties":{"look_back":{"type":"boolean"}}}',
    @CmdBikeAnimDebug);
  RegisterMcpCommand('bike.motion_sample',
    'Sample the live rider at exact crank, breath and effort values. Requires a paused FIT simulation; preserves GPU animation.',
    '{"type":"object","properties":{"bot_index":{"type":"integer","minimum":-1},"pose_index":{"type":"integer"},"look_yaw":{"type":"number","minimum":-100,"maximum":100},"body_dynamics":{"type":"boolean"},"lateral_accel":{"type":"number"},"phase":{"type":"number"},"breath":{"type":"number"},"breath_load":{"type":"number"},"effort":{"type":"number"},"cadence":{"type":"number"},"time":{"type":"number"},"anchor":{"type":"array","items":{"type":"number"}},"facing":{"type":"array","items":{"type":"number"}}}}',
    @CmdBikeMotionSample);
  RegisterMcpCommand('bike.set_gpu_anim',
    'Switch avatar bike/rider animation between the GPU path (true) and ' +
    'the legacy CPU path (false), live. Mirrors the editor command.',
    '{"type":"object","properties":{"enabled":{"type":"boolean"}},"required":["enabled"]}',
    @CmdBikeSetGpuAnim);
  RegisterMcpCommand('bike.wheels_debug',
    'Diagnostics for the "lost wheels" bug: named spin transforms ' +
    '(rotation/scale/translation, shape counts, bboxes, appearance ' +
    'effects), GPU-spin effect state (uniform values, enabled, scene), ' +
    'scene/container bboxes and transforms, avatar world translation.',
    '',
    @CmdBikeWheelsDebug);
  RegisterMcpCommand('bike.set_frustum_culling',
    'Toggle ShapeFrustumCulling/SceneFrustumCulling on the avatar bike ' +
    'scene — diagnostic for the lost-wheels culling hypothesis.',
    '{"type":"object","properties":{"enabled":{"type":"boolean"}},"required":["enabled"]}',
    @CmdBikeSetFrustumCulling);
  RegisterMcpCommand('graphics.preview','Inspect the common settings/Auto benchmark scene; freeze animation or select a repeatable viewpoint.',
    '{"type":"object","properties":{"drain":{"type":"boolean"},"rotate":{"type":"boolean"},"animate":{"type":"boolean"},"view":{"type":"integer","minimum":0,"maximum":2}}}',@CmdGraphicsPreview);
  RegisterMcpCommand('app.fps_mode',
    'Get/set a temporary FPS override: vsync, max (uncapped), low (30). ' +
    'Use settings to restore the saved graphics limit.',
    '{"type":"object","properties":{"mode":{"type":"string","enum":["vsync","max","low","settings"]}}}',
    @CmdAppFpsMode);
  RegisterMcpCommand('ground.gpu_sample','Compare CPU and asynchronous GPU ground at XZ.',
    '{"type":"object","properties":{"x":{"type":"number"},"z":{"type":"number"},"reference_y":{"type":"number"}}}',@CmdGpuGroundSample);
  RegisterMcpCommand('ground.levels','Compare top and reachable ground surfaces at XZ.',
    '{"type":"object","properties":{"x":{"type":"number"},"z":{"type":"number"},"reference_y":{"type":"number"}}}',@CmdGroundLevels);
  RegisterMcpCommand('path.surface_layers','Find loaded multi-level surfaces along the rider path. Diagnostic only.','',@CmdPathSurfaceLayers);
  RegisterMcpCommand('ground.curb_probe','Compare ground height with and without the nearest rendered curb.',
    '{"type":"object","properties":{"x":{"type":"number"},"z":{"type":"number"}}}',@CmdCurbProbe);
  RegisterMcpCommand('perf.farfield',
    'Reversible OSM distance experiment, no persistence or per-frame work. '+
    'Cuts composite draw indices outside an XZ radius; keeps physics and buffers. '+
    'LOD uses existing CGE tile-center ranges. original restores all changes.',
    '{"type":"object","properties":{"mode":{"type":"string"},"distance_m":{"type":"number"},'+
    '"pbr_m":{"type":"number"},"full_m":{"type":"number"},"cut_trees":{"type":"boolean"}}}',@CmdFarFieldProbe);
  RegisterMcpCommand('perf.objects',
    'List live transform paths and optional X3D group/shape paths. Temporarily set visible for object-isolation measurements. '+
    'Keeps lights and physics; paths must be obtained again after scene changes. Not persisted.',
    '{"type":"object","properties":{"transform":{"type":"string"},"node":{"type":"string"},"nodes":{"type":"boolean"},"visible":{"type":"boolean"},"brief":{"type":"boolean"}}}',@CmdPerfObjects);
  RegisterMcpCommand('perf.set',
    'Toggle frame-cost components for isolated perf measurements: ' +
    'anim (all bike AnimateFrame), riders (Tripo rider meshes), ' +
    'terrain (streamed map / level ground), shadows (all riders), ' +
    'occlusion (hidden-object culling; persist=true saves it), dynamic_batching (merge meshes each frame), log_shaders (diagnostic GLSL log), ' +
    'world_shadows (buildings/trees in the shared atlas; false leaves rider shadows only), ' +
    'road_material (legacy/direct/cached), procedural_trees (new/legacy trees), tree_season (0 spring, .25 summer, .5 autumn, .75 winter), vegetation (all trees), grass (all grass), grass_lod (adapt blade tessellation to projected size), vegetation_branches (legacy vertex detail), curb_contacts (wheel height only), ' +
    'grass_blades/grass_cards/grass_carpet (diagnostic grass layers), ' +
    'binary_shader_names (diagnostic comparison with legacy locale-dependent lookups), ' +
    'discard_shadow_shader (diagnostic: remove the disabled ground-shadow shader). Each key optional.',
    '{"type":"object","properties":{"anim":{"type":"boolean"},' +
    '"riders":{"type":"boolean"},"terrain":{"type":"boolean"},"shadows":{"type":"boolean"},"tree_pass_batching":{"type":"boolean"},"grass_base_instance":{"type":"boolean"},"shared_effect_revisions":{"type":"boolean"},"shared_uniform_arrays":{"type":"boolean"},"shared_effect_bindings":{"type":"boolean"},"binary_shader_names":{"type":"boolean"},"pose_cache":{"type":"boolean"},"delayed_pose":{"type":"boolean"},' +
    '"occlusion":{"type":"boolean"},"persist":{"type":"boolean"},"world_shadows":{"type":"boolean"},"dynamic_batching":{"type":"boolean"},"log_shaders":{"type":"boolean"},' +
    '"vegetation_branches":{"type":"boolean"},"procedural_trees":{"type":"boolean"},"tree_season":{"type":"number","minimum":0,"maximum":1},"vegetation":{"type":"boolean"},"grass":{"type":"boolean"},"grass_lod":{"type":"boolean"},"curb_contacts":{"type":"boolean"},"road_material":{"type":"string","enum":["legacy","direct","cached"]},' +
    '"grass_blades":{"type":"boolean"},"grass_cards":{"type":"boolean"},"grass_carpet":{"type":"boolean"},' +
    '"discard_shadow_shader":{"type":"boolean"}}}',
    @CmdPerfSet);
  RegisterMcpCommand('perf.shadow_test_riders',
    'Create 0..15 independent local bike/rider instances for shadow benchmarks. '
    + 'No relay traffic. count=0 removes them; zones=true spans all atlas zones.',
    '{"type":"object","properties":{"count":{"type":"integer","minimum":0,"maximum":15},"zones":{"type":"boolean"}}}',
    @CmdShadowTestRiders);
  RegisterMcpCommand('bots.local','Local companion roster and visibility/performance diagnostics; session-only render limit.',
    '{"type":"object","properties":{"limit":{"type":"integer","minimum":0,"maximum":3},"render":{"type":"boolean"},"shaders":{"type":"boolean"},"probe_animate_paused":{"type":"boolean"},"probe_mask":{"type":"integer"},"probe_revision_cache":{"type":"boolean"},"probe_pose_cache_policy":{"type":"integer","minimum":-1,"maximum":1}}}',@CmdLocalBots);
  RegisterMcpCommand('perf.state',
    'Current perf toggles + fps mode + route prep done + live FPS ' +
    '(real / only-render). geometry=true also counts resident OSM tiles, vertices and triangles.',
    '{"type":"object","properties":{"geometry":{"type":"boolean"},"reflection_diagnostics":{"type":"boolean"}}}',
    @CmdPerfState);
  RegisterMcpCommand('fx.configure','Inspect or temporarily compare screen effects in the active ride. Does not save settings.',
    '{"type":"object","properties":{"enabled":{"type":"boolean"},"softening":{"type":"integer","minimum":0,"maximum":2},"fog":{"type":"boolean"},"bloom":{"type":"boolean"},"tone":{"type":"boolean"},"kuwahara":{"type":"boolean"},"posterize":{"type":"boolean"},"hatch":{"type":"boolean"}}}',@CmdScreenFX);
  RegisterMcpCommand('perf.render_stability',
    'Bounded consecutive viewport frames for flicker diagnostics. Readback affects timing; not an FPS benchmark.',
    '{"type":"object","properties":{"frames":{"type":"integer"},"x":{"type":"integer"},"y":{"type":"integer"},"width":{"type":"integer"},"height":{"type":"integer"},"raw_path":{"type":"string"},"shadow_depth":{"type":"boolean"}}}',@CmdRenderStability);
  RegisterMcpCommand('perf.capture',
    'Explicit bounded frame-time capture. start/read/stop; read reset=true drains a window. ' +
    'Reports frame median/p95/p99/1% low, raw update, render submission, asynchronous GPU timestamps and VRAM. ' +
    '8192 samples/channel maximum, no per-frame log or GPU wait; overwritten count makes truncation explicit. ' +
    'GPU covers drawing, not swap/pacing; CPU submit may include driver stalls. No overhead while stopped.',
    '{"type":"object","properties":{"action":{"type":"string","enum":["start","read","stop"]},"reset":{"type":"boolean"}}}',
    @CmdPerfCapture);
  RegisterMcpCommand('perf.poi_models',
    'Diagnostic OSM POI switches. Stop the ride before setting enabled, batched or traffic_signals. animate_signals can change during a ride. Not persisted.',
    '{"type":"object","properties":{"enabled":{"type":"boolean"},"batched":{"type":"boolean"},"traffic_signals":{"type":"boolean"},"animate_signals":{"type":"boolean"}}}',
    @CmdPoiModels);
  RegisterMcpCommand('perf.rider_render',
    'Diagnostic rider render stages. Omit fields to inspect. Changes are temporary and affect the active rider only.',
    '{"type":"object","properties":{"lighting":{"type":"boolean"},' +
    '"textures":{"type":"boolean"},"scene_lights":{"type":"boolean"},' +
    '"global_lights":{"type":"boolean"},"environment":{"type":"boolean"},' +
    '"ground_shade":{"type":"boolean"},' +
    '"self_occlusion":{"type":"number","minimum":0,"maximum":1},' +
    '"muscle_responses":{"type":"array","items":{"type":"array","items":{"type":"number"}}},' +
    '"shader_file":{"type":"string"},"save_shader_file":{"type":"string"},' +
    '"shader_effect":{"type":"string"},"shader_stage":{"type":"string","enum":["vertex","fragment"]}}}',
    @CmdRiderRender);
  RegisterMcpCommand('perf.rider_model',
    'Set a local rider model for the next ride benchmark. Stop the ride first. Empty path restores profile selection. Not persisted.',
    '{"type":"object","properties":{"path":{"type":"string"}}}',
    @CmdPerfRiderModel);
  RegisterMcpCommand('app.screenshot',
    'Capture the current window contents. Returns the PNG inline as ' +
    'base64 image content (default) and/or saves it to "path".',
    '{"type":"object","properties":{' +
    '"path":{"type":"string","description":"optional file path/URL to save the PNG"},' +
    '"inline":{"type":"boolean","description":"include PNG base64 in the reply (default true)"}' +
    '}}',
    @CmdScreenshot);
  RegisterMcpCommand('bikefit.body','Read/change shared avatar physical parameters.',
    '{"type":"object"}',@CmdBikeFitBody);
  RegisterMcpCommand('bikefit.auto_fit','Use the same automatic size and fit button as the game UI.',
    '{"type":"object"}',@CmdBikeFitAutoFit);
  RegisterMcpCommand('bikefit.status',
    'Open bike-fit and return fit, camera and live ride sharing status.',
    '{"type":"object","properties":{}}',
    @CmdBikeFitStatus);
  RegisterMcpCommand('bikefit.select_rider',
    'Open bike-fit and select rider: 0=male preset, 1=female preset; one shared model.',
    '{"type":"object","properties":{"index":{"type":"integer"}},"required":["index"]}',
    @CmdBikeFitSelect);
  RegisterMcpCommand('bikefit.nudge',
    'Change a fit param by signed UI steps. param: height|inseam|bulk|' +
    'belly|seat|offset|spacers|stem|cadence|effort (5% FTP per step).',
    '{"type":"object","properties":{' +
    '"param":{"type":"string"},' +
    '"steps":{"type":"integer","description":"signed click count (default 1)"}},' +
    '"required":["param"]}',
    @CmdBikeFitNudge);
  RegisterMcpCommand('bikefit.set_color',
    'Set or clear a color slot of the bike-fit result preview. slot: ' +
    'jersey|shorts|socks|boots|gloves|skin|hair|helmet|frame|rim; r,g,b 0..255; ' +
    'on=false restores stock. Jersey also controls wardrobe tops/outerwear, ' +
    'shorts controls trousers, boots controls footwear, helmet controls hats. ' +
    'Colors update live without rebuilding the wardrobe.',
    '{"type":"object","properties":{' +
    '"slot":{"type":"string"},' +
    '"r":{"type":"number"},"g":{"type":"number"},"b":{"type":"number"},' +
    '"on":{"type":"boolean"}},' +
    '"required":["slot"]}',
    @CmdBikeFitSetColor);
  RegisterMcpCommand('bikefit.set_hair',
    'Select and save rider hairstyle: bald, short, curly, medium, ponytail, braid, long_braid, double_braids, dreadlocks.',
    '{"type":"object","properties":{"style":{"type":"string"}},"required":["style"]}',
    @CmdBikeFitHair);
  RegisterMcpCommand('bikefit.head',
    'Head editor: save headwear/hair/mustache/beard, category 0..3, open, yaw; optional thumbnail PNG of the actual preview.',
    '{"type":"object","properties":{"headwear":{"type":"string"},"hair":{"type":"string"},'+
    '"mustache":{"type":"string"},"beard":{"type":"string"},"category":{"type":"integer"},'+
    '"open":{"type":"boolean"},"yaw":{"type":"number"},"thumbnail":{"type":"string"},'+
    '"manual_face":{"type":"boolean"},"jaw":{"type":"number"},"smile":{"type":"number"},'+
    '"strain":{"type":"number"}}}',@CmdBikeFitHead);
  RegisterMcpCommand('bikefit.clothing',
    'Select the avatar editor clothing for cycling and walking. Empty value restores cycling kit / removes outerwear or hat. Omit fields to inspect.',
    '{"type":"object","properties":{"top":{"enum":["","tshirt","sweatshirt"]},'+
    '"bottom":{"enum":["","trousers","jeans"]},"outer":{"enum":["","jacket","coat","loose_jacket","raincoat"]},'+
    '"feet":{"enum":["","sneakers","boots","loafers"]},"head":{"enum":["","beanie","cap","bucket"]}}}',@CmdBikeFitClothing);
  RegisterMcpCommand('bikefit.camera',
    'Frame the isolated avatar preview for reproducible screenshots. Zoom 0.5..4, yaw in degrees relative to the default view. Does not affect the ride camera.',
    '{"type":"object","properties":{"zoom":{"type":"number"},"yaw":{"type":"number"},"target_y":{"type":"number","minimum":0,"maximum":2.5}}}',@CmdBikeFitCamera);
  RegisterMcpCommand('bikefit.animation',
    'Pause and step the isolated walking avatar preview, including cloth, by exact frames. Nonpersistent; use paused=false to resume.',
    '{"type":"object","properties":{"paused":{"type":"boolean"},"speed":{"type":"number","minimum":0,"maximum":8},"frames":{"type":"integer","minimum":0,"maximum":600},"fps":{"type":"number","minimum":10,"maximum":240},"phase":{"type":"number","minimum":0,"maximum":1}}}',@CmdBikeFitAnimation);
  RegisterMcpCommand('bikefit.lighting',
    'Set/inspect bike-fit page lighting on the fly (omit an argument to keep it): ' +
    'env = rider IBL ambient, key/fill = result viewport directional lights, ' +
    'rkey/rfill = rider scene directional lights. Echoes values + light diag.',
    '{"type":"object","properties":{' +
    '"env":{"type":"number"},"key":{"type":"number"},"fill":{"type":"number"},' +
    '"rkey":{"type":"number"},"rfill":{"type":"number"}}}',
    @CmdBikeFitLighting);

  McpActive:=True;
  if (ViewPlay<>nil) and ViewPlay.SessionAlive then McpRegisterPlayObjects;
end;

procedure InitMcpServer;
begin
  if (Server<>nil) or not McpModeRequested then Exit;
  McpSilenceStdOut;
  PrepareMcpRegistry;
  Server:=TMcpStdioServer.Create('third-person-navigation-bike','0.1.0');
  Server.OnEndOfStream:=@Glue.EndOfStream;
  if not Server.Start then begin
    FreeAndNil(Server);Assistant.SetTransportAvailable(False);Exit;
  end;
  Assistant.SetTransportAvailable(True);
end;

function EnableLocalMcp(out Error:string):Boolean;
begin
  Result:=False;Error:='';
  if McpModeRequested then Error:='mcp_stdio_active'
  {$ifndef MSWINDOWS}else Error:='mcp_platform_unsupported'{$endif};
  if Error<>'' then begin LocalError:=Error;Inc(LocalRevision);Exit end;
  if LocalServer<>nil then begin
    if LocalServer.Status.Enabled then Exit(True);
    if not LocalServer.Finished then begin Error:='mcp_stopping';Exit end;
    FreeAndNil(LocalServer);
  end;
  try
    PrepareMcpRegistry;
    LocalServer:=TMcpLocalPipeServer.Create('third-person-navigation-bike','0.1.0');
    LocalServer.OnBeforeDispatch:=@Glue.BeforePipeDispatch;
    if not LocalServer.Start(Error) then FreeAndNil(LocalServer)
    else begin
      LocalSeenGeneration:=0;LocalSeenRevision:=0;LocalWasConnected:=False;
      Assistant.Disconnect;EndAssistantVoiceSession;
      Assistant.SetTransportAvailable(True);Result:=True;
    end;
  except
    Error:='mcp_pipe_failed';FreeAndNil(LocalServer);
  end;
  LocalError:=Error;Inc(LocalRevision);
end;

procedure DisableLocalMcp;
begin
  if LocalServer=nil then Exit;
  { Revoke dispatch before any queued command can observe torn-down state. }
  LocalServer.RequestStop;
  Assistant.SetTransportAvailable(False);EndAssistantVoiceSession;
  LocalError:='';Inc(LocalRevision);
end;

function LocalMcpStatus:TJSONObject;
var S:TMcpLocalPipeStatus;Supported:Boolean;Endpoint,Command:string;
begin
  Supported:=not McpModeRequested;
  {$ifndef MSWINDOWS}Supported:=False;{$endif}
  S:=Default(TMcpLocalPipeStatus);
  if LocalServer<>nil then S:=LocalServer.Status;
  Endpoint:='';Command:='';
  if S.Enabled then begin
    Endpoint:=S.Endpoint;
    Command:='"'+ExpandFileName(ParamStr(0))+'" --mcp-connect '+Endpoint;
  end;
  Result:=TJSONObject.Create(['supported',Supported,'stdio',McpModeRequested,
    'enabled',S.Enabled,'client_connected',S.ClientConnected,
    'endpoint',Endpoint,'command',Command,'error',LocalError,
    'revision',Int64(LocalRevision)]);
end;
procedure ShutdownMcpServer;
begin
  DisableLocalMcp;
  FreeAndNil(LocalServer);
  if Server<>nil then Server.Session.Cancel;
  StopAssistantMcp;
  ShutdownAssistantVoice;
  if not McpActive then Exit;
  ShutdownPhotoMcpTools;
  ShutdownPhotoViewRenderTools;
  ClearFarFieldProbe;
  FreeAndNil(PerformanceProbe);
  McpActive := False;
  if Glue <> nil then
    ApplicationProperties.OnUpdate.Remove(@Glue.UpdatePump);
  FreeAndNil(Server);
  FreeAndNil(Glue);
  SetLength(ViewRegs, 0);
end;

end.
