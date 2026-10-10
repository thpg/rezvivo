{
  Copyright 2020-2023 Michalis Kamburelis.

  This file is part of "Castle Game Engine".

  "Castle Game Engine" is free software; see the file COPYING.txt,
  included in this distribution, for details about the copyright.

  "Castle Game Engine" is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

  ----------------------------------------------------------------------------
}

{ Game initialization.
  This unit is cross-platform.
  It will be used by the platform-specific program or library file. }
unit GameInitialize;
{$I castleconf.inc}

interface

{ Complete the normal window lifecycle before RTL ExitProc crash fallbacks.
  Safe to call again from unit finalization. }
procedure ShutdownGame;

implementation

uses AppRuntimePaths, AvatarGait, SysUtils,
  CastleWindow, CastleScene, CastleControls, CastleLog,
  CastleFilesUtils, CastleSceneCore, CastleKeysMouse, CastleColors,
  CastleUIControls, CastleApplicationProperties, CastleSoundEngine,
  CastleTransform, CastleRenderOptions, CastleGLShaders, CastleGLVersion,
  OpenSSL, OpenSSLSockets, SSLSockets,
  DebugLog,
  {$ifdef ANDROID}GameAndroidPlatform,{$endif}
  {$ifdef MSWINDOWS}
  { DeviceService owns the ANT dispatch thread. Keep its USB backend loaded
    until this unit has stopped and destroyed that service at shutdown. }
  ANTPlusLibusb0,
  {$endif}
  GameDeviceService, WorkoutLibrary,
  GameViewMenu, GameViewPlay,
  GameViewDevices, GameViewBikeFit,
  GameViewTraining, GameViewWorkoutEditor,
  GameViewProfile, GameViewEvents,
  GameViewMapEditor,
  GameViewLogin,
  RideUploadQueue, VeloSiteAPI, GameOsmAccess,
  GameLocalization, AppSettings, GameGraphicsOptions,
  GameMcpServer,GameClientUpdate,GameCrashReports,GameAudio,GameOfflineReadiness,
  GameStreamingRetirement, GameShaderCache;

var
  Window: TCastleWindow;
  ShutdownStarted: Boolean = False;

{ Пытаемся инициализировать OpenSSL с fallback на разные имена DLL.
  FPC по умолчанию ищет libssl-1_1-x64.dll/libcrypto-1_1-x64.dll. Если
  юзер поставил OpenSSL 3 — это libssl-3-x64.dll. Также бывают сборки с
  ssleay32.dll/libeay32.dll (старый стиль) или просто libssl/libcrypto.
  Перебираем варианты, на первом успешном останавливаемся. Если ни
  один не загрузился — логируем, без падения; HTTPS-вызовы будут
  валиться позже корректно через except. }
procedure TryInitOpenSSL;

  function TryNames(const ASslName, ACryptoName: String): Boolean;
  begin
    DLLSSLName := ASslName;
    DLLUtilName := ACryptoName;
    Result := InitSSLInterface;
  end;

begin
  if InitSSLInterface then
  begin
    Logger.Info('[OpenSSL] OK with default names');
    Exit;
  end;
  if TryNames('libssl-3-x64.dll', 'libcrypto-3-x64.dll') then
  begin
    Logger.Info('[OpenSSL] OK with 3.x names');
    Exit;
  end;
  if TryNames('libssl-1_1-x64.dll', 'libcrypto-1_1-x64.dll') then
  begin
    Logger.Info('[OpenSSL] OK with 1.1 explicit names');
    Exit;
  end;
  if TryNames('libssl.dll', 'libcrypto.dll') then
  begin
    Logger.Info('[OpenSSL] OK with plain names');
    Exit;
  end;
  if TryNames('ssleay32.dll', 'libeay32.dll') then
  begin
    Logger.Info('[OpenSSL] OK with legacy names');
    Exit;
  end;
  Logger.Warning('[OpenSSL] Failed to load any of: libssl-3, libssl-1_1, libssl, ssleay32. ' +
    'HTTPS calls will fail. Install OpenSSL DLLs next to the .exe.');
end;

{ One-time initialization of resources. }
procedure GameFilesDropped(Container:TCastleContainer;const FileNames:array of String);
begin
  if Length(FileNames)>0 then ViewMenu.AcceptFile(FileNames[0]);
end;

procedure ApplicationInitialize;
begin
  {$ifdef ANDROID}InitializeAndroidPlatform;{$endif}
  Settings.InitializeStorage;
  {$ifdef OpenGLES}
  if (GLVersion = nil) or (GLVersion.Major < 3) then
    raise Exception.Create('REZVIVO requires an OpenGL ES 3.0 graphics context');
  {$endif}
  {$ifdef ANDROID}
  EnsureCgeLog;
  StartCrashReports;
  if VeloSite = nil then VeloSite := TVeloSiteAPI.Create;
  {$endif}
  { Capture the active renderer before initializing services and scene shaders. }
  DumpEnvironmentGpu;
  RefreshCrashDiagnostics;
  ConfigureProgramShaderCache;
  { Scene lifecycle tracing opens and flushes a file for every scene. Keep
    the diagnostic available without charging normal streaming for it. }
  SceneLifecycleLogEnabled := GetEnvironmentVariable('REZVIVO_SCENE_LIFECYCLE_LOG') = '1';
  Randomize;

  { ── OpenSSL: пробуем имена и для 1.1, и для 3.x, и более универсальные.
    По умолчанию FPC ищет libssl-1_1-x64.dll и libcrypto-1_1-x64.dll —
    если у юзера установлен OpenSSL 3 (libssl-3-x64.dll) или просто
    переименованные libssl/libcrypto, нужно явно подсказать. fphttpclient
    инициализирует SSL лениво при первом HTTPS-запросе; чтобы он не
    бросил "Could not initialize OpenSSL library", задаём fallback имена. }
  {$ifndef ANDROID}TryInitOpenSSL;{$endif}

  { Adjust container settings for a scalable UI (adjusts to any window size in a smart way). }
  Window.Container.LoadSettings('castle-data:/CastleSettings.xml');

  { ── BLE-сервис создаётся один раз на всё приложение и сразу же
       включает непрерывный фоновый режим: подписывается на
       ApplicationProperties.OnUpdate и стартует скан. С этого момента
       поиск устройств работает на каждом кадре независимо от того,
       какой TCastleView сейчас активен. ── }
  if not Assigned(DeviceService) then
    DeviceService := TGameDeviceService.Create;
  DeviceService.EnableContinuousScan;
  DumpEnvironmentDevices;
  Logger.Info('[Devices] ANT+ stick present: ' +
    BoolToStr(DeviceService.ANTStickPresent, True));

  { ── Библиотека тренировок: один раз сканим data/workouts/* ── }
  if not Assigned(WorkoutLib) then
    WorkoutLib := TWorkoutLibrary.Create;
  WorkoutLib.Scan;

  { The API constructor restored the account-bound profile snapshot from disk.
    No HTTP may run before the menu: the watcher applies any later locale. }
  ApplyEffectiveLanguage;

  { Create views (see https://castle-engine.io/views ). }
  GameSound:=TGameAudio.Create(nil);
  ViewPlay     := TViewPlay.Create(Application);
  ViewMenu     := TViewMenu.Create(Application);
  ViewDevices  := TDevicesPage.Create(Application);
  ViewBikeFit  := TBikeFitPage.Create(Application);
  ViewTraining := TTrainingPage.Create(Application);
  ViewWorkoutEditor := TViewWorkoutEditor.Create(Application);
  ViewProfile  := TProfilePage.Create(Application);
  ViewEvents   := TEventsPage.Create(Application);
  ViewMapEditor := TViewMapEditor.Create(Application);
  ViewLogin    := TViewLogin.Create(Application);

  Window.OnDropFiles:=@GameFilesDropped;
  Window.Container.View := ViewMenu;
  Window.Container.Controls.InsertFront(CreateGameFpsControl(Window));

  { Скан недозагруженных заездов. Если приложение упало с активной
    сессией, CSV остался без маркера .uploaded — фоновая очередь
    подхватит при первом запуске сети. }
  UploadQueue.Scan;

  { ── Локализация: подписаться на смену кэша профиля. Watcher polls
       раз в секунду — если профиль обновится в ходе сессии (например,
       на сайте сменили locale, и юзер перелогинился), UI переключится. }
  InstallProfileWatcher;
  VeloSite.InitializeAsync;
  InitializeClientUpdates(Window.Container,VeloSite.BaseUrl);
  EnableCrashUpload(VeloSite.BaseUrl);

  { ── MCP-сервер (только при --mcp-stdio): регистрирует window, views,
       DeviceService и Settings для удалённого управления. Без флага —
       no-op. Вызываем последним, когда все views уже созданы. ── }
  InitMcpServer;

  //SoundEngine.RepositoryURL := 'castle-data:/audio/index.xml';
  //SoundEngine.LoopingChannel[0].Sound := SoundEngine.SoundFromName('dark_music');
end;

{ CLI: --noaa (-noaa, /noaa) — окно без MSAA. Дублирует CliFlag из
  gameviewplay (та приватная); нужен здесь до создания окна. }
function HasCliFlag(const AName: string): Boolean;
var
  I: Integer;
  S: String;
begin
  Result := False;
  for I := 1 to AppParamCount do
  begin
    S := AppParamStr(I);
    if (Length(S) > 0) and (S[1] in ['-', '/']) then
    begin
      while (Length(S) > 0) and (S[1] in ['-', '/']) do Delete(S, 1, 1);
      if SameText(S, AName) then Exit(True);
    end;
  end;
end;

procedure ShutdownGame;
begin
  if ShutdownStarted then Exit;
  ShutdownStarted:=True;
  ShutdownMcpServer;
  ShutdownClientUpdates;
  if VeloSite <> nil then VeloSite.ShutdownAsync;
  ShutdownOfflineReadiness;
  if Assigned(DeviceService) then FreeAndNil(DeviceService);
  { Views must finish their history and close the sensor journal while the
    journal singleton and upload queue are still alive. ExitProc otherwise
    closes the journal as an interrupted ride before this unit finalizes. }
  ShutdownStreamingRetirement;
  if Window <> nil then Window.Close(False);
  Application.MainWindow := nil;
  Application.DestroyComponents;
  FreeAndNil(GameSound);
  Window := nil;
  if Assigned(WorkoutLib) then FreeAndNil(WorkoutLib);
end;

initialization
  { This initialization section configures:
    - Application.OnInitialize
    - Application.MainWindow
    - determines initial window size

    You should not need to do anything more in this initialization section.
    Most of your actual application initialization (in particular, any file reading)
    should happen inside ApplicationInitialize. }

  ConfigureDriverShaderCache;
  Application.OnInitialize := @ApplicationInitialize;

  Window := TCastleWindow.Create(Application);
  case Settings.GetGraphicsOption(Ord(goAntialiasing)) of
    2: Window.AntiAliasing := aa2SamplesFaster;
    4: Window.AntiAliasing := aa4SamplesFaster;
    8: Window.AntiAliasing := aa8SamplesFaster;
  else Window.AntiAliasing := aaNone;
  end;
  { FPS-бисекция: --noaa отключает MSAA (osm3d и редактор байка работают
    без AA — так замеряем его стоимость на карте). }
  if HasCliFlag('noaa') then
    Window.AntiAliasing := aaNone;
  { ДИАГ: --logshaders — дамп всех компонуемых GLSL-програм в CGE-лог
    (нужен --log, иначе лог никуда не пишется). }
  if HasCliFlag('logshaders') then
    CastleGLShaders.LogShaders := True;
  Application.MainWindow := Window;

  { Optionally, adjust window fullscreen state and size at this point.
    See https://castle-engine.io/window_size . }

  { Handle command-line parameters like --fullscreen and --window.
    By doing this last, you let user to override your fullscreen / mode setup. }
  Window.ParseParameters;

finalization
  ShutdownGame;
end.
