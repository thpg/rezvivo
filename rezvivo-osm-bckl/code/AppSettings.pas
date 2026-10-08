{ AppSettings — глобальный singleton для пользовательских настроек.

  Storage: JSON-файл в ApplicationConfig('settings.json'), что соответствует
  Castle Engine конвенции (`%AppData%\<app>\settings.json` на Windows,
  `~/.config/<app>/settings.json` на Linux).

  Настройки автоматически:
    • Загружаются при создании singleton'а в initialization-секции.
    • Сохраняются при изменении через временный файл и замену основного.
      BeginUpdate/EndUpdate объединяют связанные изменения в одну запись.

  Сейчас хранит только enabled/disabled per-adapter. Структура расширяемая:
  при добавлении новых полей JSON разрастается, старые ключи остаются
  совместимыми. Если файл отсутствует или повреждён — используются
  дефолты (все adapter'ы enabled).

  Threading: операции защищены критической секцией. JSON read/write
  выполняются под lock'ом, чтобы concurrent UI-toggle не побил файл. }
unit AppSettings;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, syncobjs, GameGraphicsOptions, GameAudioOptions, GameTravel;

type
  {$M+}
  TAppSettings = class
  private
    FFileName: string;
    FLock: TCriticalSection;
    FUpdateDepth: Integer;
    FSavePending: Boolean;
    FGraphics: TGraphicsValues;
    FGraphicsPreviewActive: Boolean;
    FGraphicsPreviewValues: TGraphicsValues;
    FGraphicsPreviewProceduralTrees: Boolean;
    FAudio: TAudioValues;
    FAudioRevision: Cardinal;
    FGraphicsRevision: Cardinal;
    FOnGraphicsChanged: TGraphicsChangeEvent;
    { Map: composite_key (e.g. "BLE:Bluetooth") → "0"/"1" }
    FAdapters: TStringList;
    { Simulation uses the selected route by default. An optional independent
      FIT is retained when simulation is disabled or route mode is selected. }
    FWheelCircumferenceMm: Integer;
    FTrainerGradeSensitivity: Integer;
    FSimulationFitPath: string;
    FSimulationEnabled: Boolean;
    FSimulationUseRoute: Boolean;
    FSelectedRoutePath: string;
    FTravelMode: TTravelMode;
    FExploreBicycle, FExploreStartSet: Boolean;
    FExploreLat, FExploreLon: Double;
    FOnSimulationChanged: TNotifyEvent;
    { Выбранная пользователем карта из библиотеки в главном меню.
      Хранится URL (`castle-data:/maps/<dir>/map.json`) либо '' для
      дефолтной карты. Восстанавливается при старте, чтобы юзер не
      переключал карту каждый раз. }
    FSelectedMapUrl: string;
    FOcclusionCulling: Boolean;
    FTrainingFocusOnTop: Boolean;
    FProceduralTrees: Boolean;
    FTreeSeason: Single;
    { Локально выбранный язык интерфейса игры. Пустая строка означает
      «не выбрано» — в этом случае GameLocalization берёт язык из профиля
      VeloSite (если игрок залогинен), иначе использует дефолтный 'en'.
      Установка непустого значения в этом поле полностью перекрывает
      серверный профиль и НИКОГДА не пишется на сайт — выбор языка в
      игре локален по дизайну. Формат: BCP-47 ('en', 'ru', 'ja', 'zh-Hans'). }
    FLanguage: string;
    { Пол райдера: 'male' / 'female'. Определяет, какой glb грузить
      в байкфите и в заезде (MEN.glb / FEM.glb). Локально, как язык. }
    FGender: string;
    { Байкфит: выбранный bike JSON (URL castle-data:/… или fs-путь) и
      путь к glb райдера (data/avatars/MEN.glb или FEM.glb). Пусто = дефолты игры. }
    FSelectedBikeJson: string;
    FSelectedBikeSize: string;
    FSelectedRiderGlb: string;
    FFitParamsValid: Boolean;
    FFitSeatpostExt: Single;
    FFitSaddleOffset: Single;
    FFitHeadsetSpacer: Single;
    FFitStemLength: Single;
    FFitHelmetPitch: Single;
    FFitHeightCm: Single;
    FFitInseamCm: Single;
    FFitBulk: Single;
    FFitBelly: Single;
    FFitKneeFlare: Single;
    FFitAnkleFlex: Single;
    { Байкфит: цвета одежды/кожи/волос райдера и рамы/ободьев байка.
      Формат: 9 hex-значений RRGGBB через запятую в порядке
      jersey,shorts,socks,boots,gloves,skin,hair,frame,rim;
      пустой элемент = слот выключен (стоковый цвет). }
    FBikeFitColors: string;
    procedure ApplyGraphicsGlobals;
    function GetGraphicsPreviewActive: Boolean;
    procedure NormalizeGenderAndRider;
    procedure LoadFromFile;
    procedure SaveToFile;
  public
    constructor Create;
    destructor Destroy; override;

    { Pair on the same thread, with EndUpdate in a finally block. The lock
      spans the whole batch. Nested batches save only at the outermost end. }
    procedure BeginUpdate;
    function EndUpdate: Boolean;

    function GetGraphicsOption(Index: Integer): Integer;
    function GetAudioOption(Index: Integer): Integer;
    procedure SetAudioOption(Index, Value: Integer);
    property AudioRevision: Cardinal read FAudioRevision;
    procedure SetGraphicsOption(Index, Value: Integer);
    { A preview may span frames. It only snapshots graphics; other settings
      keep saving normally with the pre-preview graphics values. Call End
      with False when cancelling or leaving the temporary tuning flow. }
    procedure BeginGraphicsPreview;
    procedure EndGraphicsPreview(Commit: Boolean);
    property GraphicsPreviewActive: Boolean read GetGraphicsPreviewActive;
    property GraphicsRevision: Cardinal read FGraphicsRevision;
    property OnGraphicsChanged: TGraphicsChangeEvent read FOnGraphicsChanged write FOnGraphicsChanged;

    { Adapter is identified by composite key "<transport>:<adapter_key>".
      Если ключа нет в settings — возвращаем True (adapter включен по
      умолчанию, чтобы новый стик не оказался отключён). }
    function GetWheelCircumferenceMm: Integer;
    procedure SetWheelCircumferenceMm(Value: Integer);
    function GetTrainerGradeSensitivity: Integer;
    procedure SetTrainerGradeSensitivity(Value: Integer);
    function GetAdapterEnabled(const AKey: string): Boolean;
    procedure SetAdapterEnabled(const AKey: string; AEnabled: Boolean);

    { Симуляция входных сигналов из FIT-файла. Меняет источник данных
      сенсоров: при Enabled=True реальные BLE/ANT+ устройства не
      подключаются к игре, вместо них используется sim-провайдер. }
    function GetSimulationFitPath: string;
    procedure SetSimulationFitPath(const APath: string);
    function GetSimulationEnabled: Boolean;
    procedure SetSimulationEnabled(AEnabled: Boolean);
    function GetSimulationUseRoute: Boolean;
    procedure SetSimulationUseRoute(AValue: Boolean);
    procedure SetTravelMode(Value: TTravelMode);
    procedure SetExploreBicycle(Value: Boolean);
    procedure SetExploreStart(Lat, Lon: Double);
    function GetSelectedRoutePath: string;
    procedure SetSelectedRoutePath(const APath: string);
    function EffectiveSimulationFitPath: string;
    property OnSimulationChanged: TNotifyEvent read FOnSimulationChanged write FOnSimulationChanged;

    { Hidden-object culling, enabled by default; saved locally. }
    function GetOcclusionCulling: Boolean;
    function GetTrainingFocusOnTop: Boolean;
    procedure SetTrainingFocusOnTop(AEnabled: Boolean);
    procedure SetOcclusionCulling(AEnabled: Boolean);
    function GetProceduralTrees: Boolean;
    procedure SetProceduralTrees(AEnabled: Boolean);
    function GetTreeSeason: Single;
    procedure SetTreeSeason(AValue: Single);

    { Выбранная карта в библиотеке главного меню. URL вида
      'castle-data:/maps/<dir>/map.json' или '' для дефолтной. }
    function GetSelectedMapUrl: string;
    procedure SetSelectedMapUrl(const AUrl: string);

    { Язык игрового UI, выбранный явно в настройках игры. Пустая строка
      («не выбрано») — значит «использовать язык профиля VeloSite, либо
      дефолт». Любое непустое значение перекрывает профиль. ВАЖНО: этот
      выбор хранится только локально, на сайт VeloSite он не отправляется. }
    function GetLanguage: string;
    procedure SetLanguage(const ALang: string);

    { Пол ('male' / 'female'). Сеттер сразу пишет ui.gender и подставляет
      castle-data:/avatars/MEN.glb или FEM.glb в SelectedRiderGlb. }
    function GetGender: string;
    procedure SetGender(const AGender: string);

    function GetSelectedBikeJson: string;
    procedure SetSelectedBikeJson(const APath: string);
    function GetSelectedBikeSize: string;
    procedure SetSelectedBikeSize(const ASize: string);
    function GetSelectedRiderGlb: string;
    procedure SetSelectedRiderGlb(const APath: string);

    function GetFitParamsValid: Boolean;
    function GetFitSeatpostExt: Single;
    function GetFitSaddleOffset: Single;
    function GetFitHeadsetSpacer: Single;
    function GetFitStemLength: Single;
    function GetFitHelmetPitch: Single;
    function GetFitHeightCm: Single;
    function GetFitInseamCm: Single;
    function GetFitBulk: Single;
    function GetFitBelly: Single;
    function GetFitKneeFlare: Single;
    function GetFitAnkleFlex: Single;
    { Цвета байкфита (одежда/кожа/волосы/рама/ободы) — см. формат у поля. }
    function GetBikeFitColors: string;
    procedure SetBikeFitColors(const AValue: string);
    procedure SetFitAdjustments(SeatExt, SaddleOffset, Spacers, StemLen: Single;
      HelmetPitchDeg: Single = 0);
    procedure SetRiderShape(HeightCm, InseamCm, Bulk, Belly: Single;
      KneeFlare: Single = 0; AnkleFlex: Single = 0);
    { Цвета байкфита: 9 hex RRGGBB через запятую
      (jersey,shorts,socks,boots,gloves,skin,hair,frame,rim), пусто = сток. }
    property BikeFitColors: string read GetBikeFitColors write SetBikeFitColors;
  published
    property AudioMaster: Integer index Ord(aoMaster) read GetAudioOption write SetAudioOption;
    property AudioAmbience: Integer index Ord(aoAmbience) read GetAudioOption write SetAudioOption;
    property AudioEffects: Integer index Ord(aoEffects) read GetAudioOption write SetAudioOption;
    property AudioWorkout: Integer index Ord(aoWorkout) read GetAudioOption write SetAudioOption;
    property AudioMenu: Integer index Ord(aoMenu) read GetAudioOption write SetAudioOption;
    property GraphicsFpsLimit: Integer index Ord(goFrameLimit) read GetGraphicsOption write SetGraphicsOption;
    property GraphicsMSAA: Integer index Ord(goAntialiasing) read GetGraphicsOption write SetGraphicsOption;
    property GraphicsShadowSize: Integer index Ord(goShadowSize) read GetGraphicsOption write SetGraphicsOption;
    property GraphicsShadowFilter: Integer index Ord(goShadowFilter) read GetGraphicsOption write SetGraphicsOption;
    property GraphicsShadowDistance: Integer index Ord(goShadowDistance) read GetGraphicsOption write SetGraphicsOption;
    property GraphicsGrass: Integer index Ord(goGrass) read GetGraphicsOption write SetGraphicsOption;
    property GraphicsTrees: Integer index Ord(goTrees) read GetGraphicsOption write SetGraphicsOption;
    property GraphicsVegetation: Integer index Ord(goTrees) read GetGraphicsOption write SetGraphicsOption;
    property GraphicsVegetationCache: Integer index Ord(goVegetationCache) read GetGraphicsOption write SetGraphicsOption;
    property GraphicsVegetationAdaptive: Integer index Ord(goVegetationAdaptive) read GetGraphicsOption write SetGraphicsOption;
    property GraphicsTextures: Integer index Ord(goTextures) read GetGraphicsOption write SetGraphicsOption;
    property GraphicsHair: Integer index Ord(goHair) read GetGraphicsOption write SetGraphicsOption;
    property GraphicsSoftening: Integer index Ord(goSoftening) read GetGraphicsOption write SetGraphicsOption;
    property GraphicsWorldShadows: Integer index Ord(goWorldShadows) read GetGraphicsOption write SetGraphicsOption;
    property GraphicsRtxReflections: Integer index Ord(goRtxReflections) read GetGraphicsOption write SetGraphicsOption;
    { Доступ через RTTI (MCP property_get/property_set). Запись идёт через
      существующие сеттеры — они же сохраняют settings.json на диск, так
      что RTTI-set не обходит персистентность. }
    property SimulationFitPath: string
      read GetSimulationFitPath write SetSimulationFitPath;
    property TrainerGradeSensitivity: Integer
      read GetTrainerGradeSensitivity write SetTrainerGradeSensitivity;
    property SimulationEnabled: Boolean
      read GetSimulationEnabled write SetSimulationEnabled;
    property SimulationUseRoute: Boolean read GetSimulationUseRoute write SetSimulationUseRoute;
    property TravelMode: TTravelMode read FTravelMode write SetTravelMode;
    property ExploreBicycle: Boolean read FExploreBicycle write SetExploreBicycle;
    property ExploreStartSet: Boolean read FExploreStartSet;
    property ExploreLat: Double read FExploreLat;
    property ExploreLon: Double read FExploreLon;
    property SelectedRoutePath: string read GetSelectedRoutePath write SetSelectedRoutePath;
    property SelectedMapUrl: string
      read GetSelectedMapUrl write SetSelectedMapUrl;
    property Language: string read GetLanguage write SetLanguage;
    property Gender: string read GetGender write SetGender;
    property SelectedBikeJson: string
      read GetSelectedBikeJson write SetSelectedBikeJson;
    property SelectedBikeSize: string
      read GetSelectedBikeSize write SetSelectedBikeSize;
    property SelectedRiderGlb: string
      read GetSelectedRiderGlb write SetSelectedRiderGlb;
    property FitParamsValid: Boolean read GetFitParamsValid;
    property FitSeatpostExt: Single read GetFitSeatpostExt;
    property FitSaddleOffset: Single read GetFitSaddleOffset;
    property FitHeadsetSpacer: Single read GetFitHeadsetSpacer;
    property FitStemLength: Single read GetFitStemLength;
    property FitHelmetPitch: Single read GetFitHelmetPitch;
    property FitHeightCm: Single read GetFitHeightCm;
    property FitInseamCm: Single read GetFitInseamCm;
    property FitBulk: Single read GetFitBulk;
    property FitBelly: Single read GetFitBelly;
    property FitKneeFlare: Single read GetFitKneeFlare;
    property FitAnkleFlex: Single read GetFitAnkleFlex;
  end;
  {$M-}

var
  Settings: TAppSettings;

{ URL райдера по полу: female → FEM.glb, иначе MEN.glb. }
function RiderGlbUrlForGender(const AGender: string): string;
{ Абсолютный fs-путь для LoadGlb / TTripoRig (castle-data:/ → файл). }
function ResolveRiderGlbPath(const AUrlOrPath: string): string;

implementation

uses
  fpjson, jsonparser, CastleFilesUtils, CastleURIUtils,
  DebugLog, Osm3dStudioSettings, TreeSeason, PBRTextureUnit, Osm3dVegetationQuality,RiderHair, GameUserData;

const
  SETTINGS_FILE = 'settings.json';
  RiderUrlMale   = 'castle-data:/avatars/RIDER.glb';
  RiderUrlFemale = 'castle-data:/avatars/RIDER.glb';

{$IFDEF MSWINDOWS}
function SettingsMoveFile(OldName, NewName: PWideChar; Flags: LongWord): LongBool;
  stdcall; external 'kernel32' name 'MoveFileExW';
{$ENDIF}

function RiderGlbUrlForGender(const AGender: string): string;
begin
  if SameText(Trim(AGender), 'female') then
    Result := RiderUrlFemale
  else
    Result := RiderUrlMale;
end;

function ResolveRiderGlbPath(const AUrlOrPath: string): string;
var
  DataRoot, Name, SlashPath, Candidate: string;
begin
  { Встроенная общая модель лежит в data/avatars/. URIToFilenameSafe('castle-data:/avatars/X.glb')
    на Windows иногда даёт путь, которого FileExists не видит; рабочий способ
    тот же, что был у ScanRiders: корень castle-data:/ + 'avatars\' + файл. }
  Result := Trim(AUrlOrPath);
  DataRoot := URIToFilenameSafe('castle-data:/');
  if DataRoot <> '' then
    DataRoot := IncludeTrailingPathDelimiter(DataRoot);

  SlashPath := StringReplace(Result, '/', PathDelim, [rfReplaceAll]);
  Name := ExtractFileName(SlashPath);
  if (Name='') or SameText(Name,'MEN.glb') or SameText(Name,'FEM.glb') then
    Name := 'RIDER.glb';

  if DataRoot <> '' then
  begin
    Candidate := DataRoot + 'avatars' + PathDelim + Name;
    if FileExists(Candidate) then
      Exit(Candidate);
  end;

  if (Result <> '') and FileExists(Result) then
    Exit(Result);
  if (SlashPath <> '') and FileExists(SlashPath) then
    Exit(SlashPath);

  if DataRoot <> '' then
    Result := DataRoot + 'avatars' + PathDelim + Name
  else if SameText(Name, 'FEM.glb') then
    Result := RiderUrlFemale
  else
    Result := RiderUrlMale;
end;

function CanonicalGender(const AGender: string): string;
var
  G: string;
begin
  G := LowerCase(Trim(AGender));
  if G = 'female' then
    Result := 'female'
  else
    Result := 'male';
end;

{ ═══════════════════════════════════════════════════════════════════
  TAppSettings
  ═══════════════════════════════════════════════════════════════════ }

constructor TAppSettings.Create;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FAdapters := TStringList.Create;
  FAdapters.CaseSensitive := True;
  FWheelCircumferenceMm := 2105;
  FSimulationFitPath := '';
  FTrainerGradeSensitivity := 100;
  FTravelMode:=travelBicycle;FExploreLat:=55.75;FExploreLon:=37.62;
  FSimulationEnabled := False;
  FSimulationUseRoute := True;
  FSelectedMapUrl := '';
  FGraphics := GraphicsDefaults;
  FAudio := AudioDefaults;
  FOcclusionCulling := True;
  FTrainingFocusOnTop := True;
  FProceduralTrees := True; FTreeSeason := 0.25;
  FLanguage := '';
  FGender := 'male';
  FSelectedBikeJson := '';
  FSelectedBikeSize := '';
  FSelectedRiderGlb := '';
  FFitParamsValid := False;
  FFitSeatpostExt := 0;
  FFitSaddleOffset := 0;
  FFitHeadsetSpacer := 0;
  FFitStemLength := 0;
  FFitHelmetPitch := 0;
  FFitHeightCm := 0;
  FFitInseamCm := 0;
  FFitBulk := 0;
  FFitBelly := 0;
  FFitKneeFlare := 0;
  FFitAnkleFlex := 0;
  FBikeFitColors := '';
  // НЕ ставим Sorted := True. С Sorted=True FPC бросает EListError при
  // FAdapters.Values[Name] := Value, потому что внутренний Put(Index, S)
  // на sorted list запрещён. У нас всего ~единицы адаптеров, lookup
  // всё равно будет O(N) — sorting не нужен.

  FFileName := URIToFilenameSafe(ApplicationConfig(SETTINGS_FILE));
  if(GetEnvironmentVariable('REZVIVO_TEST_AUTH_FILE')<>'')and(GetEnvironmentVariable('REZVIVO_TEST_SETTINGS_FILE')<>'')then
    FFileName:=UTF8Encode(UnicodeString(GetEnvironmentVariable('REZVIVO_TEST_SETTINGS_FILE')));
  Logger.Info('[Settings] File: ' + FFileName);
  LoadFromFile;
  ApplyGraphicsGlobals;
  ProceduralVegetationSeason := FTreeSeason;
end;

destructor TAppSettings.Destroy;
begin
  if FSavePending and (FUpdateDepth = 0) then
    try
      SaveToFile;
    except
      on E: Exception do
        Logger.Warning('[Settings] Final save failed: ' + E.Message);
    end;
  FreeAndNil(FAdapters);
  FreeAndNil(FLock);
  inherited;
end;

procedure TAppSettings.BeginUpdate;
begin
  FLock.Enter;
  Inc(FUpdateDepth);
end;

function TAppSettings.EndUpdate: Boolean;
begin
  if FUpdateDepth <= 0 then
    raise EInvalidOperation.Create('Settings.EndUpdate without BeginUpdate');
  try
    Dec(FUpdateDepth);
    Result := True;
    if (FUpdateDepth = 0) and FSavePending then
      try
        SaveToFile;
      except
        on E: Exception do
        begin
          Result := False;
          Logger.Warning('[Settings] Save failed: ' + E.Message);
        end;
      end;
  finally
    FLock.Leave;
  end;
end;

procedure TAppSettings.LoadFromFile;
var
  S: TStringList;
  Root, AdaptersObj, DevObj, UiObj: TJSONData;
  AdaptersJson: TJSONObject;
  I: Integer;
  Name: string;
  GraphicsObj: TJSONData;
  Option: TGraphicsOption;
  AudioOption: TAudioOption;
  V: Integer;
begin
  if not FileExists(FFileName) then
  begin
    Logger.Info('[Settings] No file yet — using defaults');
    NormalizeGenderAndRider;
    Exit;
  end;

  S := TStringList.Create;
  try
    try
      S.LoadFromFile(FFileName);
      Root := GetJSON(S.Text);
      try
        if not (Root is TJSONObject) then Exit;
        FWheelCircumferenceMm:=EnsureRange(TJSONObject(Root).Get('wheel_circumference_mm',2105),500,4000);
        FTrainerGradeSensitivity:=EnsureRange(TJSONObject(Root).Get('trainer_grade_sensitivity',100),0,100);
        AdaptersObj := TJSONObject(Root).Find('adapters');
        if (AdaptersObj <> nil) and (AdaptersObj is TJSONObject) then
        begin
          AdaptersJson := TJSONObject(AdaptersObj);
          for I := 0 to AdaptersJson.Count - 1 do
          begin
            Name := AdaptersJson.Names[I];
            if AdaptersJson.Booleans[Name] then
              FAdapters.Values[Name] := '1'
            else
              FAdapters.Values[Name] := '0';
          end;
          Logger.Info(Format('[Settings] Loaded %d adapter entries',
            [AdaptersJson.Count]));
        end;

        DevObj := TJSONObject(Root).Find('dev');
        if (DevObj <> nil) and (DevObj is TJSONObject) then
        begin
          FSimulationFitPath := TJSONObject(DevObj).Get('sim_fit_path', '');
          FSimulationEnabled := TJSONObject(DevObj).Get('sim_enabled', False);
          Logger.Info(Format('[Settings] Loaded dev: sim_fit=%s, sim_enabled=%s',
            [FSimulationFitPath, BoolToStr(FSimulationEnabled, True)]));
        end;

        DevObj := TJSONObject(Root).Find('simulation');
        if (DevObj <> nil) and (DevObj is TJSONObject) then
        begin
          FSimulationFitPath := TJSONObject(DevObj).Get('fit_path', FSimulationFitPath);
          FSimulationEnabled := TJSONObject(DevObj).Get('enabled', FSimulationEnabled);
          FSimulationUseRoute := TJSONObject(DevObj).Get('use_route_fit', True);
        end;

        UiObj := TJSONObject(Root).Find('ui');
        if (UiObj <> nil) and (UiObj is TJSONObject) then
        begin
          FSelectedMapUrl := TJSONObject(UiObj).Get('selected_map_url', '');
          FSelectedRoutePath := TJSONObject(UiObj).Get('selected_route_path', '');
          try FTravelMode:=ParseTravel(TJSONObject(UiObj).Get('travel_mode','bicycle'));
          except FTravelMode:=travelBicycle end;
          FExploreBicycle:=TJSONObject(UiObj).Get('explore_bicycle',False);
          FExploreStartSet:=TJSONObject(UiObj).Get('explore_start_set',False);
          FExploreLat:=TJSONObject(UiObj).Get('explore_lat',55.75);
          FExploreLon:=TJSONObject(UiObj).Get('explore_lon',37.62);
          FExploreStartSet:=FExploreStartSet and not IsNan(FExploreLat) and not IsNan(FExploreLon) and
            (Abs(FExploreLat)<=85) and (Abs(FExploreLon)<=180);
          FOcclusionCulling := TJSONObject(UiObj).Get('occlusion_culling', True);
          FTrainingFocusOnTop := TJSONObject(UiObj).Get('training_focus_on_top', True);
          FProceduralTrees := TJSONObject(UiObj).Get('procedural_trees', True);
          if not FProceduralTrees then FGraphics[goTrees] := 0;
          FTreeSeason := WrapTreeSeason(TJSONObject(UiObj).Get('tree_season', 0.25));
          FLanguage       := TJSONObject(UiObj).Get('language', '');
          FGender         := TJSONObject(UiObj).Get('gender', '');
          FSelectedBikeJson := TJSONObject(UiObj).Get('selected_bike_json', '');
          FSelectedBikeSize := TJSONObject(UiObj).Get('selected_bike_size', '');
          FSelectedRiderGlb := TJSONObject(UiObj).Get('selected_rider_glb', '');
          FBikeFitColors := TJSONObject(UiObj).Get('bikefit_colors', '');
          FFitParamsValid := TJSONObject(UiObj).Get('fit_params', False);
          FFitSeatpostExt := TJSONObject(UiObj).Get('fit_seatpost_mm', 0.0);
          FFitSaddleOffset := TJSONObject(UiObj).Get('fit_saddle_offset_mm', 0.0);
          FFitHeadsetSpacer := TJSONObject(UiObj).Get('fit_spacers_mm', 0.0);
          FFitStemLength := TJSONObject(UiObj).Get('fit_stem_mm', 0.0);
          FFitHelmetPitch := TJSONObject(UiObj).Get('fit_helmet_pitch_deg', 0.0);
          FFitHeightCm := TJSONObject(UiObj).Get('fit_height_cm', 0.0);
          FFitInseamCm := TJSONObject(UiObj).Get('fit_inseam_cm', 0.0);
          FFitBulk := TJSONObject(UiObj).Get('fit_bulk', 0.0);
          FFitBelly := TJSONObject(UiObj).Get('fit_belly', 0.0);
          FFitKneeFlare := TJSONObject(UiObj).Get('fit_knee_flare', 0.0);
          FFitAnkleFlex := TJSONObject(UiObj).Get('fit_ankle_flex', 0.0);
          Logger.Info('[Settings] Loaded ui.selected_map_url=' + FSelectedMapUrl);
          Logger.Info('[Settings] Loaded ui.language=' + FLanguage);
          Logger.Info('[Settings] Loaded ui.gender=' + FGender);
          Logger.Info('[Settings] Loaded ui.bike=' + FSelectedBikeJson);
          Logger.Info('[Settings] Loaded ui.bike_size=' + FSelectedBikeSize);
          Logger.Info('[Settings] Loaded ui.rider=' + FSelectedRiderGlb);
        end;
        GraphicsObj := TJSONObject(Root).Find('graphics');
        if GraphicsObj is TJSONObject then begin
          if (TJSONObject(GraphicsObj).Find('vegetation_quality')=nil) and
             (TJSONObject(GraphicsObj).Find('tree_distance')<>nil) then
            FGraphics[goTrees]:=LegacyTreeQuality(TJSONObject(GraphicsObj).Get('tree_distance',100));
          for Option := Low(TGraphicsOption) to High(TGraphicsOption) do
          begin
            V := TJSONObject(GraphicsObj).Get(GraphicsKeys[Option], FGraphics[Option]);
            if ValidGraphicsValue(Option, V) then FGraphics[Option] := V;
          end;
        end;
        GraphicsObj := TJSONObject(Root).Find('audio');
        if GraphicsObj is TJSONObject then
          for AudioOption := Low(TAudioOption) to High(TAudioOption) do begin
            V := TJSONObject(GraphicsObj).Get(AudioKeys[AudioOption], FAudio[AudioOption]);
            if (V>=0) and (V<=100) then FAudio[AudioOption] := V;
          end;
      finally
        Root.Free;
      end;
    except
      on E: Exception do
        Logger.Warning('[Settings] Load failed: ' + E.Message + ' — using defaults');
    end;
  finally
    S.Free;
  end;
  NormalizeGenderAndRider;
end;

procedure TAppSettings.NormalizeGenderAndRider;
var
  Fn: string;
begin
  { Старые settings без ui.gender: угадываем по имени glb, иначе male. }
  if (FGender <> 'male') and (FGender <> 'female') then
  begin
    Fn := UpperCase(ExtractFileName(StringReplace(FSelectedRiderGlb, '/', '\', [rfReplaceAll])));
    if Pos('FEM.GLB', Fn) > 0 then
      FGender := 'female'
    else
      FGender := 'male';
  end
  else
    FGender := CanonicalGender(FGender);
  FSelectedRiderGlb := RiderGlbUrlForGender(FGender);
end;

procedure TAppSettings.SaveToFile;
var
  Root, AdaptersJson, DevJson, UiJson, GraphicsJson: TJSONObject;
  Option: TGraphicsOption;
  AudioOption: TAudioOption;
  I: Integer;
  Name: string;
  S: TStringList;
  Dir, TempName: string;
  TempID: TGUID;
  Stream: TFileStream;
begin
  FSavePending := True;
  if FUpdateDepth > 0 then Exit;
  Root := TJSONObject.Create;
  try
    AdaptersJson := TJSONObject.Create;
    Root.Add('adapters', AdaptersJson);
    Root.Add('wheel_circumference_mm',FWheelCircumferenceMm);
    Root.Add('trainer_grade_sensitivity',FTrainerGradeSensitivity);

    for I := 0 to FAdapters.Count - 1 do
    begin
      Name := FAdapters.Names[I];
      if Name = '' then Continue;
      AdaptersJson.Add(Name, FAdapters.ValueFromIndex[I] = '1');
    end;

    DevJson := TJSONObject.Create;
    Root.Add('simulation', DevJson);
    DevJson.Add('fit_path', FSimulationFitPath);
    DevJson.Add('enabled', FSimulationEnabled);
    DevJson.Add('use_route_fit', FSimulationUseRoute);

    UiJson := TJSONObject.Create;
    Root.Add('ui', UiJson);
    GraphicsJson := TJSONObject.Create;
    Root.Add('graphics', GraphicsJson);
    for Option := Low(TGraphicsOption) to High(TGraphicsOption) do
      if FGraphicsPreviewActive then
        GraphicsJson.Add(GraphicsKeys[Option], FGraphicsPreviewValues[Option])
      else
        GraphicsJson.Add(GraphicsKeys[Option], FGraphics[Option]);
    GraphicsJson := TJSONObject.Create;
    Root.Add('audio', GraphicsJson);
    for AudioOption := Low(TAudioOption) to High(TAudioOption) do
      GraphicsJson.Add(AudioKeys[AudioOption], FAudio[AudioOption]);
    UiJson.Add('selected_map_url', FSelectedMapUrl);
    UiJson.Add('selected_route_path', FSelectedRoutePath);
    UiJson.Add('travel_mode',TravelIds[FTravelMode]);
    UiJson.Add('explore_bicycle',FExploreBicycle);
    UiJson.Add('explore_start_set',FExploreStartSet);
    UiJson.Add('explore_lat',FExploreLat);UiJson.Add('explore_lon',FExploreLon);
    UiJson.Add('occlusion_culling', FOcclusionCulling);
    UiJson.Add('training_focus_on_top', FTrainingFocusOnTop);
    if FGraphicsPreviewActive then
      UiJson.Add('procedural_trees', FGraphicsPreviewProceduralTrees)
    else
      UiJson.Add('procedural_trees', FProceduralTrees);
    UiJson.Add('tree_season', FTreeSeason);
    UiJson.Add('language', FLanguage);
    UiJson.Add('gender', FGender);
    UiJson.Add('selected_bike_json', FSelectedBikeJson);
    UiJson.Add('selected_bike_size', FSelectedBikeSize);
    UiJson.Add('selected_rider_glb', FSelectedRiderGlb);
    UiJson.Add('bikefit_colors', FBikeFitColors);
    UiJson.Add('fit_params', FFitParamsValid);
    UiJson.Add('fit_seatpost_mm', FFitSeatpostExt);
    UiJson.Add('fit_saddle_offset_mm', FFitSaddleOffset);
    UiJson.Add('fit_spacers_mm', FFitHeadsetSpacer);
    UiJson.Add('fit_stem_mm', FFitStemLength);
    UiJson.Add('fit_helmet_pitch_deg', FFitHelmetPitch);
    UiJson.Add('fit_height_cm', FFitHeightCm);
    UiJson.Add('fit_inseam_cm', FFitInseamCm);
    UiJson.Add('fit_bulk', FFitBulk);
    UiJson.Add('fit_belly', FFitBelly);
    UiJson.Add('fit_knee_flare', FFitKneeFlare);
    UiJson.Add('fit_ankle_flex', FFitAnkleFlex);

    S := TStringList.Create;
    try
      S.Text := Root.FormatJSON;
      Dir := ExtractFilePath(FFileName);
      if (Dir <> '') and (not DirectoryExists(Dir)) and
         (not ForceDirectories(Dir)) then
        raise EWriteError.Create('Cannot create settings directory');
      if CreateGUID(TempID) <> 0 then
        raise EWriteError.Create('Cannot create settings temporary name');
      TempName := FFileName + '.' + GUIDToString(TempID) + '.tmp';
      try
        Stream := TFileStream.Create(TempName, fmCreate);
        try
          S.SaveToStream(Stream);
          if not FileFlush(Stream.Handle) then
            raise EWriteError.Create('Cannot flush settings file');
        finally
          Stream.Free;
        end;
        {$IFDEF MSWINDOWS}
        if not SettingsMoveFile(PWideChar(UTF8Decode(TempName)),
          PWideChar(UTF8Decode(FFileName)), $1 or $8) then
        {$ELSE}
        if not RenameFile(TempName, FFileName) then
        {$ENDIF}
          raise EWriteError.CreateFmt('Cannot replace settings file (%d: %s)',
            [GetLastOSError,SysErrorMessage(GetLastOSError)]);
  FSavePending := False;
      finally
        if FileExists(TempName) then SysUtils.DeleteFile(TempName);
      end;
    finally
      S.Free;
    end;
  finally
    Root.Free;
  end;
end;

function TAppSettings.GetWheelCircumferenceMm: Integer;
begin
  FLock.Enter;
  try Result:=FWheelCircumferenceMm finally FLock.Leave end;
end;

procedure TAppSettings.SetWheelCircumferenceMm(Value: Integer);
begin
  Value:=EnsureRange(Value,500,4000);
  FLock.Enter;
  try
    if Value=FWheelCircumferenceMm then Exit;
    FWheelCircumferenceMm:=Value; SaveToFile;
  finally FLock.Leave end;
end;

function TAppSettings.GetTrainerGradeSensitivity: Integer;
begin
  FLock.Enter;
  try Result:=FTrainerGradeSensitivity finally FLock.Leave end;
end;

procedure TAppSettings.SetTrainerGradeSensitivity(Value: Integer);
begin
  Value:=EnsureRange(Value,0,100);
  FLock.Enter;
  try
    if Value=FTrainerGradeSensitivity then Exit;
    FTrainerGradeSensitivity:=Value;SaveToFile;
  finally FLock.Leave end;
end;

function TAppSettings.GetAdapterEnabled(const AKey: string): Boolean;
var
  V: string;
begin
  FLock.Enter;
  try
    V := FAdapters.Values[AKey];
    // Default: True, если ключа нет (новый, ранее не виденный adapter).
    Result := (V = '') or (V = '1');
  finally
    FLock.Leave;
  end;
end;

procedure TAppSettings.SetAdapterEnabled(const AKey: string; AEnabled: Boolean);
var
  Old: string;
  Changed: Boolean;
begin
  FLock.Enter;
  try
    Old := FAdapters.Values[AKey];
    if AEnabled then
      FAdapters.Values[AKey] := '1'
    else
      FAdapters.Values[AKey] := '0';

    Changed := Old <> FAdapters.Values[AKey];
    if Changed then
    begin
      Logger.Info(Format('[Settings] Adapter "%s" enabled=%s',
        [AKey, BoolToStr(AEnabled, True)]));
      try
        SaveToFile;
      except
        on E: Exception do
          Logger.Warning('[Settings] Save failed: ' + E.Message);
      end;
    end;
  finally
    FLock.Leave;
  end;
end;

function TAppSettings.GetSimulationFitPath: string;
begin
  FLock.Enter;
  try
    Result := FSimulationFitPath;
  finally
    FLock.Leave;
  end;
end;

procedure TAppSettings.SetSimulationFitPath(const APath: string);
var
  Changed: Boolean;
begin
  FLock.Enter;
  try
    Changed := FSimulationFitPath <> APath;
    FSimulationFitPath := APath;
    if Changed then
    begin
      Logger.Info('[Settings] Sim FIT path: ' + APath);
      try
        SaveToFile;
      except
        on E: Exception do
          Logger.Warning('[Settings] Save failed: ' + E.Message);
      end;
    end;
  finally
    FLock.Leave;
  end;
  if Changed and Assigned(FOnSimulationChanged) then FOnSimulationChanged(Self);
end;

function TAppSettings.GetSimulationEnabled: Boolean;
begin
  FLock.Enter;
  try
    Result := FSimulationEnabled;
  finally
    FLock.Leave;
  end;
end;

procedure TAppSettings.SetSimulationEnabled(AEnabled: Boolean);
var
  Changed: Boolean;
begin
  FLock.Enter;
  try
    Changed := FSimulationEnabled <> AEnabled;
    FSimulationEnabled := AEnabled;
    if Changed then
    begin
      Logger.Info(Format('[Settings] Simulation enabled=%s',
        [BoolToStr(AEnabled, True)]));
      try
        SaveToFile;
      except
        on E: Exception do
          Logger.Warning('[Settings] Save failed: ' + E.Message);
      end;
    end;
  finally
    FLock.Leave;
  end;
  if Changed and Assigned(FOnSimulationChanged) then FOnSimulationChanged(Self);
end;

function TAppSettings.GetSimulationUseRoute: Boolean;
begin
  FLock.Enter;
  try Result := FSimulationUseRoute; finally FLock.Leave end;
end;

procedure TAppSettings.SetSimulationUseRoute(AValue: Boolean);
begin
  FLock.Enter;
  try
    if FSimulationUseRoute = AValue then Exit;
    FSimulationUseRoute := AValue;
    SaveToFile;
  finally FLock.Leave end;
  if Assigned(FOnSimulationChanged) then FOnSimulationChanged(Self);
end;

procedure TAppSettings.SetTravelMode(Value: TTravelMode);
begin
  if not TravelAvailable(Value) then Exit;
  FLock.Enter;
  try if FTravelMode=Value then Exit;FTravelMode:=Value;SaveToFile finally FLock.Leave end;
end;
procedure TAppSettings.SetExploreBicycle(Value: Boolean);
begin
  FLock.Enter;
  try if FExploreBicycle=Value then Exit;FExploreBicycle:=Value;SaveToFile finally FLock.Leave end;
end;
procedure TAppSettings.SetExploreStart(Lat, Lon: Double);
begin
  if IsNan(Lat) or IsInfinite(Lat) or IsNan(Lon) or IsInfinite(Lon) or
    (Abs(Lat)>85) or (Abs(Lon)>180) then raise EArgumentException.Create('Invalid starting point');
  FLock.Enter;
  try
    if FExploreStartSet and (FExploreLat=Lat) and (FExploreLon=Lon) then Exit;
    FExploreLat:=Lat;FExploreLon:=Lon;FExploreStartSet:=True;SaveToFile;
  finally FLock.Leave end;
end;

function TAppSettings.GetSelectedRoutePath: string;
begin
  FLock.Enter;
  try Result := FSelectedRoutePath; finally FLock.Leave end;
end;

procedure TAppSettings.SetSelectedRoutePath(const APath: string);
var Path: string;
begin
  Path := URIToFilenameSafe(APath);
  if Path = '' then Path := APath;
  FLock.Enter;
  try
    if FSelectedRoutePath = Path then Exit;
    FSelectedRoutePath := Path;
    SaveToFile;
  finally FLock.Leave end;
  if Assigned(FOnSimulationChanged) then FOnSimulationChanged(Self);
end;

function TAppSettings.EffectiveSimulationFitPath: string;
begin
  FLock.Enter;
  try
    if FSimulationUseRoute then Result := FSelectedRoutePath
    else Result := FSimulationFitPath;
  finally FLock.Leave end;
  if not SameText(ExtractFileExt(Result), '.fit') then Result := '';
end;

function TAppSettings.GetOcclusionCulling: Boolean;
begin
  FLock.Enter;
  try
    Result := FOcclusionCulling;
  finally
    FLock.Leave;
  end;
end;

procedure TAppSettings.ApplyGraphicsGlobals;
begin
  RiderHairQuality:=FGraphics[goHair];
  GlobalTextureQuality := TTextureQuality(FGraphics[goTextures]);
  RenderGrassActive := FGraphics[goGrass] <> 0;
  FProceduralTrees := FGraphics[goTrees] <> 0;
  ProceduralVegetationActive := FProceduralTrees;
  SetVegetationQuality(FGraphics[goTrees],FGraphics[goVegetationCache],FGraphics[goVegetationAdaptive]<>0);
  ProceduralTreeDistance:=VegetationDetail.TreeDistance;
end;

function TAppSettings.GetAudioOption(Index: Integer): Integer;
begin
  if (Index<Ord(Low(TAudioOption))) or (Index>Ord(High(TAudioOption))) then
    raise ERangeError.Create('Unknown audio option');
  FLock.Enter;
  try Result:=FAudio[TAudioOption(Index)];finally FLock.Leave end;
end;

procedure TAppSettings.SetAudioOption(Index, Value: Integer);
begin
  if (Index<Ord(Low(TAudioOption))) or (Index>Ord(High(TAudioOption))) or
    (Value<0) or (Value>100) then raise ERangeError.Create('Invalid audio option');
  FLock.Enter;
  try
    if FAudio[TAudioOption(Index)]=Value then Exit;
    FAudio[TAudioOption(Index)]:=Value;Inc(FAudioRevision);SaveToFile;
  finally FLock.Leave end;
end;

function TAppSettings.GetGraphicsOption(Index: Integer): Integer;
begin
  FLock.Enter;
  try Result := FGraphics[TGraphicsOption(Index)]; finally FLock.Leave end;
end;

function TAppSettings.GetGraphicsPreviewActive: Boolean;
begin
  FLock.Enter;
  try Result:=FGraphicsPreviewActive;finally FLock.Leave end;
end;

procedure TAppSettings.BeginGraphicsPreview;
begin
  FLock.Enter;
  try
    if FGraphicsPreviewActive then
      raise EInvalidOperation.Create('Graphics preview already active');
    FGraphicsPreviewValues:=FGraphics;
    FGraphicsPreviewProceduralTrees:=FProceduralTrees;
    FGraphicsPreviewActive:=True;
  finally FLock.Leave end;
end;

procedure TAppSettings.EndGraphicsPreview(Commit: Boolean);
var
  Option:TGraphicsOption;
  Changed:set of TGraphicsOption;
begin
  Changed:=[];
  FLock.Enter;
  try
    if not FGraphicsPreviewActive then
      raise EInvalidOperation.Create('Graphics preview is not active');
    if Commit then begin
      FGraphicsPreviewActive:=False;
      try SaveToFile;
      except
        { A failed commit can still be retried or cancelled. An unrelated
          settings save must not persist this uncommitted trial afterward. }
        FGraphicsPreviewActive:=True;
        raise;
      end;
    end else begin
      for Option:=Low(TGraphicsOption)to High(TGraphicsOption)do
        if FGraphics[Option]<>FGraphicsPreviewValues[Option]then Include(Changed,Option);
      if FProceduralTrees<>FGraphicsPreviewProceduralTrees then Include(Changed,goTrees);
      FGraphics:=FGraphicsPreviewValues;
      FGraphicsPreviewActive:=False;
      ApplyGraphicsGlobals;
      FProceduralTrees:=FGraphicsPreviewProceduralTrees;
      ProceduralVegetationActive:=FProceduralTrees;
      Inc(FGraphicsRevision);
    end;
  finally FLock.Leave end;
  { A restored frame limit or shadow configuration needs the same immediate
    application as a user choice. Render callbacks never run under FLock. }
  for Option:=Low(TGraphicsOption)to High(TGraphicsOption)do
    if (Option in Changed)and Assigned(FOnGraphicsChanged)then
      FOnGraphicsChanged(Self,Option);
end;

procedure TAppSettings.SetGraphicsOption(Index, Value: Integer);
var Option: TGraphicsOption;
begin
  if (Index < Ord(Low(TGraphicsOption))) or (Index > Ord(High(TGraphicsOption))) then
    raise ERangeError.Create('Unknown graphics option');
  Option := TGraphicsOption(Index);
  if not ValidGraphicsValue(Option, Value) then
    raise ERangeError.CreateFmt('Invalid graphics value: %s=%d', [GraphicsKeys[Option], Value]);
  FLock.Enter;
  try
    FGraphics[Option] := Value;
    case Option of
      goHair:RiderHairQuality:=Value;
      goTextures: GlobalTextureQuality := TTextureQuality(Value);
      goGrass: RenderGrassActive := Value <> 0;
      goTrees, goVegetationCache, goVegetationAdaptive: begin
        FProceduralTrees := FGraphics[goTrees] <> 0;
        ProceduralVegetationActive := FProceduralTrees;
        SetVegetationQuality(FGraphics[goTrees],FGraphics[goVegetationCache],FGraphics[goVegetationAdaptive]<>0);
        ProceduralTreeDistance:=VegetationDetail.TreeDistance;
      end;
    end;
    Inc(FGraphicsRevision);
    if not FGraphicsPreviewActive then SaveToFile;
  finally FLock.Leave end;
  { Reapply even an already selected choice: this also cancels a temporary
    debug override. Render callbacks must never run under the file lock. }
  if Assigned(FOnGraphicsChanged) then FOnGraphicsChanged(Self, Option);
end;

function TAppSettings.GetProceduralTrees: Boolean;
begin FLock.Enter;try Result:=FProceduralTrees;finally FLock.Leave;end;end;
function TAppSettings.GetTrainingFocusOnTop: Boolean;
begin FLock.Enter;try Result:=FTrainingFocusOnTop;finally FLock.Leave;end;end;
procedure TAppSettings.SetTrainingFocusOnTop(AEnabled: Boolean);
begin
  FLock.Enter;
  try
    if FTrainingFocusOnTop=AEnabled then Exit;
    FTrainingFocusOnTop:=AEnabled; SaveToFile;
  finally FLock.Leave; end;
end;
function TAppSettings.GetTreeSeason: Single;
begin FLock.Enter;try Result:=FTreeSeason;finally FLock.Leave;end;end;
procedure TAppSettings.SetProceduralTrees(AEnabled: Boolean);
begin
  if not AEnabled then SetGraphicsOption(Ord(goTrees), 0)
  else if GetGraphicsOption(Ord(goTrees)) = 0 then
    SetGraphicsOption(Ord(goTrees), GraphicsDefaults[goTrees])
  else ProceduralVegetationActive := True;
end;
procedure TAppSettings.SetTreeSeason(AValue: Single);
begin
  FLock.Enter;
  try
    AValue:=WrapTreeSeason(AValue);ProceduralVegetationSeason:=AValue;
    if FTreeSeason=AValue then Exit;
    FTreeSeason:=AValue;SaveToFile;
  finally FLock.Leave;end;
end;

procedure TAppSettings.SetOcclusionCulling(AEnabled: Boolean);
begin
  FLock.Enter;
  try
    if FOcclusionCulling = AEnabled then Exit;
    FOcclusionCulling := AEnabled;
    try
      SaveToFile;
    except
      on E: Exception do
        Logger.Warning('[Settings] Save failed: ' + E.Message);
    end;
  finally
    FLock.Leave;
  end;
end;

function TAppSettings.GetSelectedMapUrl: string;
begin
  FLock.Enter;
  try
    Result := FSelectedMapUrl;
  finally
    FLock.Leave;
  end;
end;

procedure TAppSettings.SetSelectedMapUrl(const AUrl: string);
var
  Changed: Boolean;
begin
  FLock.Enter;
  try
    Changed := FSelectedMapUrl <> AUrl;
    FSelectedMapUrl := AUrl;
    if Changed then
    begin
      Logger.Info('[Settings] SelectedMapUrl=' + AUrl);
      try
        SaveToFile;
      except
        on E: Exception do
          Logger.Warning('[Settings] Save failed: ' + E.Message);
      end;
    end;
  finally
    FLock.Leave;
  end;
end;

function TAppSettings.GetLanguage: string;
begin
  FLock.Enter;
  try
    Result := FLanguage;
  finally
    FLock.Leave;
  end;
end;

function TAppSettings.GetGender: string;
begin
  FLock.Enter;
  try
    Result := FGender;
  finally
    FLock.Leave;
  end;
end;

procedure TAppSettings.SetGender(const AGender: string);
var
  G, Rider: string;
  Changed: Boolean;
begin
  G := CanonicalGender(AGender);
  Rider := RiderGlbUrlForGender(G);
  FLock.Enter;
  try
    Changed := (FGender <> G) or (FSelectedRiderGlb <> Rider);
    if FGender<>G then SelectAvatarBodySex(Ord(G='female'));
    FGender := G;
    FSelectedRiderGlb := Rider;
    if Changed then
    begin
      Logger.Info('[Settings] Gender=' + G + ' rider=' + Rider);
      try
        SaveToFile;
      except
        on E: Exception do
          Logger.Warning('[Settings] Save failed: ' + E.Message);
      end;
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TAppSettings.SetLanguage(const ALang: string);
var
  Changed: Boolean;
begin
  FLock.Enter;
  try
    Changed := FLanguage <> ALang;
    FLanguage := ALang;
    if Changed then
    begin
      if ALang = '' then
        Logger.Info('[Settings] Language cleared (auto from profile)')
      else
        Logger.Info('[Settings] Language=' + ALang);
      try
        SaveToFile;
      except
        on E: Exception do
          Logger.Warning('[Settings] Save failed: ' + E.Message);
      end;
    end;
  finally
    FLock.Leave;
  end;
end;

function TAppSettings.GetSelectedBikeJson: string;
begin
  FLock.Enter;
  try
    Result := FSelectedBikeJson;
  finally
    FLock.Leave;
  end;
end;

procedure TAppSettings.SetSelectedBikeJson(const APath: string);
var
  Changed: Boolean;
begin
  FLock.Enter;
  try
    Changed := FSelectedBikeJson <> APath;
    FSelectedBikeJson := APath;
    if Changed then
    begin
      Logger.Info('[Settings] SelectedBikeJson=' + APath);
      try
        SaveToFile;
      except
        on E: Exception do
          Logger.Warning('[Settings] Save failed: ' + E.Message);
      end;
    end;
  finally
    FLock.Leave;
  end;
end;

function TAppSettings.GetSelectedBikeSize: string;
begin
  FLock.Enter;
  try
    Result := FSelectedBikeSize;
  finally
    FLock.Leave;
  end;
end;

function TAppSettings.GetBikeFitColors: string;
begin
  FLock.Enter;
  try
    Result := FBikeFitColors;
  finally
    FLock.Leave;
  end;
end;

procedure TAppSettings.SetBikeFitColors(const AValue: string);
begin
  FLock.Enter;
  try
    if FBikeFitColors = AValue then Exit;
    FBikeFitColors := AValue;
    try
      SaveToFile;
    except
      on E: Exception do
        Logger.Warning('[Settings] Save failed: ' + E.Message);
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TAppSettings.SetSelectedBikeSize(const ASize: string);
var
  Changed: Boolean;
begin
  FLock.Enter;
  try
    Changed := FSelectedBikeSize <> ASize;
    FSelectedBikeSize := ASize;
    if Changed then
    begin
      Logger.Info('[Settings] SelectedBikeSize=' + ASize);
      try
        SaveToFile;
      except
        on E: Exception do
          Logger.Warning('[Settings] Save failed: ' + E.Message);
      end;
    end;
  finally
    FLock.Leave;
  end;
end;

function TAppSettings.GetSelectedRiderGlb: string;
begin
  FLock.Enter;
  try
    Result := FSelectedRiderGlb;
  finally
    FLock.Leave;
  end;
end;

procedure TAppSettings.SetSelectedRiderGlb(const APath: string);
var
  Changed: Boolean;
begin
  FLock.Enter;
  try
    Changed := FSelectedRiderGlb <> APath;
    FSelectedRiderGlb := APath;
    if Changed then
    begin
      Logger.Info('[Settings] SelectedRiderGlb=' + APath);
      try
        SaveToFile;
      except
        on E: Exception do
          Logger.Warning('[Settings] Save failed: ' + E.Message);
      end;
    end;
  finally
    FLock.Leave;
  end;
end;

function TAppSettings.GetFitParamsValid: Boolean;
begin
  FLock.Enter;
  try
    Result := FFitParamsValid;
  finally
    FLock.Leave;
  end;
end;

function TAppSettings.GetFitSeatpostExt: Single;
begin
  FLock.Enter;
  try
    Result := FFitSeatpostExt;
  finally
    FLock.Leave;
  end;
end;

function TAppSettings.GetFitSaddleOffset: Single;
begin
  FLock.Enter;
  try
    Result := FFitSaddleOffset;
  finally
    FLock.Leave;
  end;
end;

function TAppSettings.GetFitHeadsetSpacer: Single;
begin
  FLock.Enter;
  try
    Result := FFitHeadsetSpacer;
  finally
    FLock.Leave;
  end;
end;

function TAppSettings.GetFitStemLength: Single;
begin
  FLock.Enter;
  try
    Result := FFitStemLength;
  finally
    FLock.Leave;
  end;
end;

function TAppSettings.GetFitHelmetPitch: Single;
begin
  FLock.Enter;
  try
    Result := FFitHelmetPitch;
  finally
    FLock.Leave;
  end;
end;

function TAppSettings.GetFitHeightCm: Single;
begin
  FLock.Enter;
  try
    Result := FFitHeightCm;
  finally
    FLock.Leave;
  end;
end;

function TAppSettings.GetFitInseamCm: Single;
begin
  FLock.Enter;
  try
    Result := FFitInseamCm;
  finally
    FLock.Leave;
  end;
end;

function TAppSettings.GetFitBulk: Single;
begin
  FLock.Enter;
  try
    Result := FFitBulk;
  finally
    FLock.Leave;
  end;
end;

function TAppSettings.GetFitBelly: Single;
begin
  FLock.Enter;
  try
    Result := FFitBelly;
  finally
    FLock.Leave;
  end;
end;

function TAppSettings.GetFitKneeFlare: Single;
begin
  FLock.Enter;
  try
    Result := FFitKneeFlare;
  finally
    FLock.Leave;
  end;
end;

function TAppSettings.GetFitAnkleFlex: Single;
begin
  FLock.Enter;
  try
    Result := FFitAnkleFlex;
  finally
    FLock.Leave;
  end;
end;

procedure TAppSettings.SetFitAdjustments(SeatExt, SaddleOffset, Spacers, StemLen: Single;
  HelmetPitchDeg: Single);
begin
  FLock.Enter;
  try
    FFitParamsValid := True;
    FFitSeatpostExt := SeatExt;
    FFitSaddleOffset := SaddleOffset;
    FFitHeadsetSpacer := Spacers;
    FFitStemLength := StemLen;
    FFitHelmetPitch := HelmetPitchDeg;
    try
      SaveToFile;
    except
      on E: Exception do
        Logger.Warning('[Settings] Save failed: ' + E.Message);
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TAppSettings.SetRiderShape(HeightCm, InseamCm, Bulk, Belly: Single;
  KneeFlare, AnkleFlex: Single);
begin
  FLock.Enter;
  try
    FFitParamsValid := True;
    FFitHeightCm := HeightCm;
    FFitInseamCm := InseamCm;
    FFitBulk := Bulk;
    FFitBelly := Belly;
    FFitKneeFlare := KneeFlare;
    FFitAnkleFlex := AnkleFlex;
    try
      SaveToFile;
    except
      on E: Exception do
        Logger.Warning('[Settings] Save failed: ' + E.Message);
    end;
  finally
    FLock.Leave;
  end;
end;

initialization
  Settings := TAppSettings.Create;

finalization
  FreeAndNil(Settings);

end.
