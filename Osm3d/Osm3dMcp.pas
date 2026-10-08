unit Osm3dMcp;

{ MCP-интеграция osm3d_studio_gui (Model Context Protocol, stdio).
  Активируется ТОЛЬКО флагом --mcp-stdio; без него Osm3dMcpInit — no-op.

  Регистрирует в McpRegistry:
    объекты:  settings — TOsm3dMcpFacade (published-прокси над живым
                         TStudioSettings главной формы; record сам по себе
                         RTTI недоступен),
              mainform — TStudioMainForm,
              map      — TOsm3dMcpMapFacade (прокси к сессии стриминга;
                         TOsm3dStreamingMap пересоздаётся в StartStreaming,
                         поэтому регистрируется фасад, а не сама карта);
    команды:  osm.load_route, osm.start_streaming, osm.set_map_mode,
              osm.screenshot, osm.reset_tiles, osm.search_place.

  Сеттеры фасада ТОЛЬКО пишут в настройки — перезапуск сессии и применение
  глобалов рендера происходит при следующем osm.start_streaming. UI-методы
  применения настроек из сеттеров не вызываются.

  Маршаллинг в главный поток — на стороне McpProtocol/McpBridge
  (McpRunTask через TThread.Queue); LCL крутит CheckSynchronize
  в idle, дополнительной прокачки очереди не требуется. }

{$mode objfpc}{$H+}
{$codepage UTF8}

interface

uses
  SysUtils, Classes, fpjson,
  Osm3dGeoMath, Osm3dStudioSettings, Osm3dStudioMainForm,
  Osm3dGeoTileGrid, Osm3dTileStreamer;

type
  { Published-фасад над TStudioSettings. Держит указатель на живой record
    (поле TStudioMainForm.FSettings — адрес стабилен, экземпляр не
    пересоздаётся), поэтому геттеры/сеттеры всегда читают/пишут актуальные
    значения. Record-поля (LOD: TLODConfig, Wind: TWindConfig) RTTI
    недоступны и намеренно не экспонируются. }
  TOsm3dMcpFacade = class(TPersistent)
  private
    FSettingsPtr: PStudioSettings;
    function  GetBboxPaddingMeters: Single;
    procedure SetBboxPaddingMeters(AValue: Single);
    function  GetHeightmapZoom: Integer;
    procedure SetHeightmapZoom(AValue: Integer);
    function  GetTerrainGridStepMeters: Single;
    procedure SetTerrainGridStepMeters(AValue: Single);
    function  GetTerrainSubdiv: Integer;
    procedure SetTerrainSubdiv(AValue: Integer);
    function  GetBlurHeightmapSigmaPx: Single;
    procedure SetBlurHeightmapSigmaPx(AValue: Single);
    function  GetTraceWidthMeters: Single;
    procedure SetTraceWidthMeters(AValue: Single);
    function  GetOverpassEndpoint: String;
    procedure SetOverpassEndpoint(AValue: String);
    function  GetOverpassEndpoints: String;
    procedure SetOverpassEndpoints(AValue: String);
    function  GetOverpassTileZoom: Integer;
    procedure SetOverpassTileZoom(AValue: Integer);
    function  GetOverpassTimeoutS: Integer;
    procedure SetOverpassTimeoutS(AValue: Integer);
    function  GetOverpassParallel: Boolean;
    procedure SetOverpassParallel(AValue: Boolean);
    function  GetTerrariumUrlTemplate: String;
    procedure SetTerrariumUrlTemplate(AValue: String);
    function  GetNetworkTimeoutS: Integer;
    procedure SetNetworkTimeoutS(AValue: Integer);
    function  GetCacheRoot: String;
    procedure SetCacheRoot(AValue: String);
    function  GetMemoryCacheBytes: Int64;
    procedure SetMemoryCacheBytes(AValue: Int64);
    function  GetGenerateBuildings: Boolean;
    procedure SetGenerateBuildings(AValue: Boolean);
    function  GetGenerateFences: Boolean;
    procedure SetGenerateFences(AValue: Boolean);
    function  GetGenerateRoads: Boolean;
    procedure SetGenerateRoads(AValue: Boolean);
    function  GetGenerateTrees: Boolean;
    procedure SetGenerateTrees(AValue: Boolean);
    function  GetGenerateLanduse: Boolean;
    procedure SetGenerateLanduse(AValue: Boolean);
    function  GetGenerateWaterways: Boolean;
    procedure SetGenerateWaterways(AValue: Boolean);
    function  GetGeneratePOI: Boolean;
    procedure SetGeneratePOI(AValue: Boolean);
    function  GetGenerateLabels: Boolean;
    procedure SetGenerateLabels(AValue: Boolean);
    function  GetGeneratePlates: Boolean;
    procedure SetGeneratePlates(AValue: Boolean);
    function  GetGenerateRouteOnly: Boolean;
    procedure SetGenerateRouteOnly(AValue: Boolean);
    function  GetRouteOnlyRadiusM: Single;
    procedure SetRouteOnlyRadiusM(AValue: Single);
    function  GetRenderBuildings: Boolean;
    procedure SetRenderBuildings(AValue: Boolean);
    function  GetRenderFences: Boolean;
    procedure SetRenderFences(AValue: Boolean);
    function  GetRenderRoads: Boolean;
    procedure SetRenderRoads(AValue: Boolean);
    function  GetRenderTrees: Boolean;
    procedure SetRenderTrees(AValue: Boolean);
    function GetProceduralTrees:Boolean;
    procedure SetProceduralTrees(AValue:Boolean);
    function  GetRenderGrass: Boolean;
    procedure SetRenderGrass(AValue: Boolean);
    function  GetRenderLanduse: Boolean;
    procedure SetRenderLanduse(AValue: Boolean);
    function  GetRenderWaterways: Boolean;
    procedure SetRenderWaterways(AValue: Boolean);
    function  GetRenderPOI: Boolean;
    procedure SetRenderPOI(AValue: Boolean);
    function  GetRenderLabels: Boolean;
    procedure SetRenderLabels(AValue: Boolean);
    function  GetRenderPlates: Boolean;
    procedure SetRenderPlates(AValue: Boolean);
    function  GetUseGroundComposition: Boolean;
    procedure SetUseGroundComposition(AValue: Boolean);
    function  GetUseGroundCompositionShader: Boolean;
    procedure SetUseGroundCompositionShader(AValue: Boolean);
    function  GetUseGroundCompositionMaterialIdAttribute: Boolean;
    procedure SetUseGroundCompositionMaterialIdAttribute(AValue: Boolean);
    function  GetGroundAtlasGridCols: Integer;
    procedure SetGroundAtlasGridCols(AValue: Integer);
    function  GetGroundAtlasGridRows: Integer;
    procedure SetGroundAtlasGridRows(AValue: Integer);
    function  GetGroundAtlasTilePixels: Integer;
    procedure SetGroundAtlasTilePixels(AValue: Integer);
    function  GetGenerateFarTerrain: Boolean;
    procedure SetGenerateFarTerrain(AValue: Boolean);
    function  GetFarTerrainExpansionMeters: Single;
    procedure SetFarTerrainExpansionMeters(AValue: Single);
    function  GetFarTerrainZoom: Integer;
    procedure SetFarTerrainZoom(AValue: Integer);
    function  GetFarTerrainGridStepM: Single;
    procedure SetFarTerrainGridStepM(AValue: Single);
    function  GetShowFitPoints: Boolean;
    procedure SetShowFitPoints(AValue: Boolean);
    function  GetShowFitPointsSnapped: Boolean;
    procedure SetShowFitPointsSnapped(AValue: Boolean);
    function  GetBuildingShadows: Boolean;
    procedure SetBuildingShadows(AValue: Boolean);
    function  GetGenerateGroundShadows: Boolean;
    procedure SetGenerateGroundShadows(AValue: Boolean);
    function  GetWaterShaders: Boolean;
    procedure SetWaterShaders(AValue: Boolean);
    function  GetWaterWaveSize: Single;
    procedure SetWaterWaveSize(AValue: Single);
    function  GetWaterLevelLift: Single;
    procedure SetWaterLevelLift(AValue: Single);
    function  GetBuildingTextures: Boolean;
    procedure SetBuildingTextures(AValue: Boolean);
    function  GetBuildingPBR: Boolean;
    procedure SetBuildingPBR(AValue: Boolean);
    function  GetFogDistanceM: Single;
    procedure SetFogDistanceM(AValue: Single);
    function  GetFogClearZoneM: Single;
    procedure SetFogClearZoneM(AValue: Single);
    function  GetFitHeightCorrection: Boolean;
    procedure SetFitHeightCorrection(AValue: Boolean);
    function  GetWorldScaleLatDeg: Double;
    procedure SetWorldScaleLatDeg(AValue: Double);
  public
    constructor Create(ASettingsPtr: PStudioSettings);
    { EOF stdin (MCP-хост закрыл пайп) — завершаем приложение. Вызывается
      в главном потоке (TThread.Queue из McpStdio). }
    procedure HandleEndOfStream(Sender: TObject);
  published
    property BboxPaddingMeters: Single read GetBboxPaddingMeters write SetBboxPaddingMeters;
    property HeightmapZoom: Integer read GetHeightmapZoom write SetHeightmapZoom;
    property TerrainGridStepMeters: Single read GetTerrainGridStepMeters write SetTerrainGridStepMeters;
    property TerrainSubdiv: Integer read GetTerrainSubdiv write SetTerrainSubdiv;
    property BlurHeightmapSigmaPx: Single read GetBlurHeightmapSigmaPx write SetBlurHeightmapSigmaPx;
    property TraceWidthMeters: Single read GetTraceWidthMeters write SetTraceWidthMeters;
    property OverpassEndpoint: String read GetOverpassEndpoint write SetOverpassEndpoint;
    property OverpassEndpoints: String read GetOverpassEndpoints write SetOverpassEndpoints;
    property OverpassTileZoom: Integer read GetOverpassTileZoom write SetOverpassTileZoom;
    property OverpassTimeoutS: Integer read GetOverpassTimeoutS write SetOverpassTimeoutS;
    property OverpassParallel: Boolean read GetOverpassParallel write SetOverpassParallel;
    property TerrariumUrlTemplate: String read GetTerrariumUrlTemplate write SetTerrariumUrlTemplate;
    property NetworkTimeoutS: Integer read GetNetworkTimeoutS write SetNetworkTimeoutS;
    property CacheRoot: String read GetCacheRoot write SetCacheRoot;
    property MemoryCacheBytes: Int64 read GetMemoryCacheBytes write SetMemoryCacheBytes;
    property GenerateBuildings: Boolean read GetGenerateBuildings write SetGenerateBuildings;
    property GenerateFences: Boolean read GetGenerateFences write SetGenerateFences;
    property GenerateRoads: Boolean read GetGenerateRoads write SetGenerateRoads;
    property GenerateTrees: Boolean read GetGenerateTrees write SetGenerateTrees;
    property GenerateLanduse: Boolean read GetGenerateLanduse write SetGenerateLanduse;
    property GenerateWaterways: Boolean read GetGenerateWaterways write SetGenerateWaterways;
    property GeneratePOI: Boolean read GetGeneratePOI write SetGeneratePOI;
    property GenerateLabels: Boolean read GetGenerateLabels write SetGenerateLabels;
    property GeneratePlates: Boolean read GetGeneratePlates write SetGeneratePlates;
    property GenerateRouteOnly: Boolean read GetGenerateRouteOnly write SetGenerateRouteOnly;
    property RouteOnlyRadiusM: Single read GetRouteOnlyRadiusM write SetRouteOnlyRadiusM;
    property RenderBuildings: Boolean read GetRenderBuildings write SetRenderBuildings;
    property RenderFences: Boolean read GetRenderFences write SetRenderFences;
    property RenderRoads: Boolean read GetRenderRoads write SetRenderRoads;
    property RenderTrees: Boolean read GetRenderTrees write SetRenderTrees;
    property ProceduralTrees:Boolean read GetProceduralTrees write SetProceduralTrees;
    property RenderGrass: Boolean read GetRenderGrass write SetRenderGrass;
    property RenderLanduse: Boolean read GetRenderLanduse write SetRenderLanduse;
    property RenderWaterways: Boolean read GetRenderWaterways write SetRenderWaterways;
    property RenderPOI: Boolean read GetRenderPOI write SetRenderPOI;
    property RenderLabels: Boolean read GetRenderLabels write SetRenderLabels;
    property RenderPlates: Boolean read GetRenderPlates write SetRenderPlates;
    property UseGroundComposition: Boolean read GetUseGroundComposition write SetUseGroundComposition;
    property UseGroundCompositionShader: Boolean read GetUseGroundCompositionShader write SetUseGroundCompositionShader;
    property UseGroundCompositionMaterialIdAttribute: Boolean read GetUseGroundCompositionMaterialIdAttribute write SetUseGroundCompositionMaterialIdAttribute;
    property GroundAtlasGridCols: Integer read GetGroundAtlasGridCols write SetGroundAtlasGridCols;
    property GroundAtlasGridRows: Integer read GetGroundAtlasGridRows write SetGroundAtlasGridRows;
    property GroundAtlasTilePixels: Integer read GetGroundAtlasTilePixels write SetGroundAtlasTilePixels;
    property GenerateFarTerrain: Boolean read GetGenerateFarTerrain write SetGenerateFarTerrain;
    property FarTerrainExpansionMeters: Single read GetFarTerrainExpansionMeters write SetFarTerrainExpansionMeters;
    property FarTerrainZoom: Integer read GetFarTerrainZoom write SetFarTerrainZoom;
    property FarTerrainGridStepM: Single read GetFarTerrainGridStepM write SetFarTerrainGridStepM;
    property ShowFitPoints: Boolean read GetShowFitPoints write SetShowFitPoints;
    property ShowFitPointsSnapped: Boolean read GetShowFitPointsSnapped write SetShowFitPointsSnapped;
    property BuildingShadows: Boolean read GetBuildingShadows write SetBuildingShadows;
    property GenerateGroundShadows: Boolean read GetGenerateGroundShadows write SetGenerateGroundShadows;
    property WaterShaders: Boolean read GetWaterShaders write SetWaterShaders;
    property WaterWaveSize: Single read GetWaterWaveSize write SetWaterWaveSize;
    property WaterLevelLift: Single read GetWaterLevelLift write SetWaterLevelLift;
    property BuildingTextures: Boolean read GetBuildingTextures write SetBuildingTextures;
    property BuildingPBR: Boolean read GetBuildingPBR write SetBuildingPBR;
    property FogDistanceM: Single read GetFogDistanceM write SetFogDistanceM;
    property FogClearZoneM: Single read GetFogClearZoneM write SetFogClearZoneM;
    property FitHeightCorrection: Boolean read GetFitHeightCorrection write SetFitHeightCorrection;
    property WorldScaleLatDeg: Double read GetWorldScaleLatDeg write SetWorldScaleLatDeg;
  end;

  { Прокси к ЖИВОЙ сессии стриминга (TOsm3dStreamingSession / её карта).
    Сессия пересоздаётся при каждом StartStreaming, поэтому для RTTI
    регистрируется этот фасад — он каждый раз обращается к текущему
    экземпляру через главную форму. }
  TOsm3dMcpMapFacade = class(TPersistent)
  private
    FForm: TStudioMainForm;
    FReviewTile:TGeoTileId;
    FReviewFilter:TTileWantFilter;
    function ReviewWantTile(const Id:TGeoTileId):Boolean;
    function  GetSessionActive: Boolean;
    function  GetRenderInfo: string;
    function GetFpsMode:TFpsLimitMode;
    procedure SetFpsMode(Value:TFpsLimitMode);
    function GetWorldShadows:Boolean;
    procedure SetWorldShadows(Value:Boolean);
    function  GetOriginLat: Double;
    function  GetOriginLon: Double;
    function  GetRoutePoints: Integer;
    function  GetFlatMode: Boolean;
    procedure SetFlatMode(AValue: Boolean);
    function  GetMapExists: Boolean;
    procedure SetMapExists(AValue: Boolean);
  public
    constructor Create(AForm: TStudioMainForm);
    procedure RestrictReviewTo(const Origin:TLatLon);
  published
    { Есть ли активная сессия стриминга. }
    property SessionActive: Boolean read GetSessionActive;
    property RenderInfo: string read GetRenderInfo;
    property FpsMode:TFpsLimitMode read GetFpsMode write SetFpsMode;
    property WorldShadows:Boolean read GetWorldShadows write SetWorldShadows;
    { Origin текущей сессии (0,0 — сессии нет). }
    property OriginLat: Double read GetOriginLat;
    property OriginLon: Double read GetOriginLon;
    { Число точек загруженного маршрута (0 — маршрута нет). }
    property RoutePoints: Integer read GetRoutePoints;
    { True = плоская карта, False = 3D (запись = SetMapMode). }
    property FlatMode: Boolean read GetFlatMode write SetFlatMode;
    { Видимость 3D-карты сессии (Exists). Запись без сессии — ошибка. }
    property MapExists: Boolean read GetMapExists write SetMapExists;
  end;

{ True, если в командной строке есть --mcp-stdio. Проверка независимая
  (по ParamStr), не вмешивается в TStudioMainForm.ParseCommandLine. }
function Osm3dMcpRequested: Boolean;

{ Регистрация объектов/команд и запуск stdio-сервера. Без --mcp-stdio —
  no-op. Вызывать после создания главной формы. }
procedure Osm3dMcpInit(AForm: TStudioMainForm);

{ Остановка сервера и освобождение фасадов. Без активного MCP — no-op. }
procedure Osm3dMcpShutdown;

implementation

uses
  Math, Forms, McpCommon, McpRegistry, McpStdio, McpPhotoTools, McpPhotoViewTools, Osm3dStreamingLauncher, CastleViewport, Osm3dGeocode, Osm3dImpostorCache,
  Osm3dProceduralVegetation, TreeRenderer, GrassRenderer, RenderComplexity;

var
  GForm:      TStudioMainForm;
  GFacade:    TOsm3dMcpFacade;
  GMapFacade: TOsm3dMcpMapFacade;
  GServer:    TMcpStdioServer;

procedure PhotoViewContext(out V:TCastleViewport; out S:TOsm3dStreamingSession);
begin
  if (GForm=nil) or (GForm.StreamSession=nil) or GForm.IsFlatMode then
    raise Exception.Create('Photo comparison requires an active real 3D map');
  V:=GForm.McpViewport; S:=GForm.StreamSession;
end;

procedure PhotoViewMode(EnterComparison:Boolean);
var P,R:TJSONObject;
begin
  if not EnterComparison then Exit;
  GForm.ClosePhotoComparison;
  P:=TJSONObject.Create(['stop',True]); R:=TJSONObject.Create;
  try (GForm.McpViewport as TOsmImpostorViewport).ProbeCamera(P,R) finally P.Free; R.Free end;
end;

function Osm3dMcpRequested: Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 1 to ParamCount do
    if LowerCase(ParamStr(I)) = '--mcp-stdio' then
      Exit(True);
end;

{ ── TOsm3dMcpFacade ──────────────────────────────────────────────────── }

constructor TOsm3dMcpFacade.Create(ASettingsPtr: PStudioSettings);
begin
  inherited Create;
  if ASettingsPtr = nil then
    raise EMcpError.Create('TOsm3dMcpFacade.Create: settings pointer is nil');
  FSettingsPtr := ASettingsPtr;
end;

procedure TOsm3dMcpFacade.HandleEndOfStream(Sender: TObject);
begin
  Application.Terminate;
end;

function TOsm3dMcpFacade.GetBboxPaddingMeters: Single;
begin
  Result := FSettingsPtr^.BboxPaddingMeters;
end;

procedure TOsm3dMcpFacade.SetBboxPaddingMeters(AValue: Single);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.BboxPaddingMeters := AValue;
end;

function TOsm3dMcpFacade.GetHeightmapZoom: Integer;
begin
  Result := FSettingsPtr^.HeightmapZoom;
end;

procedure TOsm3dMcpFacade.SetHeightmapZoom(AValue: Integer);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.HeightmapZoom := AValue;
end;

function TOsm3dMcpFacade.GetTerrainGridStepMeters: Single;
begin
  Result := FSettingsPtr^.TerrainGridStepMeters;
end;

procedure TOsm3dMcpFacade.SetTerrainGridStepMeters(AValue: Single);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.TerrainGridStepMeters := AValue;
end;

function TOsm3dMcpFacade.GetTerrainSubdiv: Integer;
begin
  Result := FSettingsPtr^.TerrainSubdiv;
end;

procedure TOsm3dMcpFacade.SetTerrainSubdiv(AValue: Integer);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.TerrainSubdiv := AValue;
end;

function TOsm3dMcpFacade.GetBlurHeightmapSigmaPx: Single;
begin
  Result := FSettingsPtr^.BlurHeightmapSigmaPx;
end;

procedure TOsm3dMcpFacade.SetBlurHeightmapSigmaPx(AValue: Single);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.BlurHeightmapSigmaPx := AValue;
end;

function TOsm3dMcpFacade.GetTraceWidthMeters: Single;
begin
  Result := FSettingsPtr^.TraceWidthMeters;
end;

procedure TOsm3dMcpFacade.SetTraceWidthMeters(AValue: Single);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.TraceWidthMeters := AValue;
end;

function TOsm3dMcpFacade.GetOverpassEndpoint: String;
begin
  Result := FSettingsPtr^.OverpassEndpoint;
end;

procedure TOsm3dMcpFacade.SetOverpassEndpoint(AValue: String);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.OverpassEndpoint := AValue;
end;

function TOsm3dMcpFacade.GetOverpassEndpoints: String;
begin
  Result := FSettingsPtr^.OverpassEndpoints;
end;

procedure TOsm3dMcpFacade.SetOverpassEndpoints(AValue: String);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.OverpassEndpoints := AValue;
end;

function TOsm3dMcpFacade.GetOverpassTileZoom: Integer;
begin
  Result := FSettingsPtr^.OverpassTileZoom;
end;

procedure TOsm3dMcpFacade.SetOverpassTileZoom(AValue: Integer);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.OverpassTileZoom := AValue;
end;

function TOsm3dMcpFacade.GetOverpassTimeoutS: Integer;
begin
  Result := FSettingsPtr^.OverpassTimeoutS;
end;

procedure TOsm3dMcpFacade.SetOverpassTimeoutS(AValue: Integer);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.OverpassTimeoutS := AValue;
end;

function TOsm3dMcpFacade.GetOverpassParallel: Boolean;
begin
  Result := FSettingsPtr^.OverpassParallel;
end;

procedure TOsm3dMcpFacade.SetOverpassParallel(AValue: Boolean);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.OverpassParallel := AValue;
end;

function TOsm3dMcpFacade.GetTerrariumUrlTemplate: String;
begin
  Result := FSettingsPtr^.TerrariumUrlTemplate;
end;

procedure TOsm3dMcpFacade.SetTerrariumUrlTemplate(AValue: String);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.TerrariumUrlTemplate := AValue;
end;

function TOsm3dMcpFacade.GetNetworkTimeoutS: Integer;
begin
  Result := FSettingsPtr^.NetworkTimeoutS;
end;

procedure TOsm3dMcpFacade.SetNetworkTimeoutS(AValue: Integer);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.NetworkTimeoutS := AValue;
end;

function TOsm3dMcpFacade.GetCacheRoot: String;
begin
  Result := FSettingsPtr^.CacheRoot;
end;

procedure TOsm3dMcpFacade.SetCacheRoot(AValue: String);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.CacheRoot := AValue;
end;

function TOsm3dMcpFacade.GetMemoryCacheBytes: Int64;
begin
  Result := FSettingsPtr^.MemoryCacheBytes;
end;

procedure TOsm3dMcpFacade.SetMemoryCacheBytes(AValue: Int64);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.MemoryCacheBytes := AValue;
end;

function TOsm3dMcpFacade.GetGenerateBuildings: Boolean;
begin
  Result := FSettingsPtr^.GenerateBuildings;
end;

procedure TOsm3dMcpFacade.SetGenerateBuildings(AValue: Boolean);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.GenerateBuildings := AValue;
end;

function TOsm3dMcpFacade.GetGenerateFences: Boolean;
begin
  Result := FSettingsPtr^.GenerateFences;
end;

procedure TOsm3dMcpFacade.SetGenerateFences(AValue: Boolean);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.GenerateFences := AValue;
end;

function TOsm3dMcpFacade.GetGenerateRoads: Boolean;
begin
  Result := FSettingsPtr^.GenerateRoads;
end;

procedure TOsm3dMcpFacade.SetGenerateRoads(AValue: Boolean);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.GenerateRoads := AValue;
end;

function TOsm3dMcpFacade.GetGenerateTrees: Boolean;
begin
  Result := FSettingsPtr^.GenerateTrees;
end;

procedure TOsm3dMcpFacade.SetGenerateTrees(AValue: Boolean);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.GenerateTrees := AValue;
end;

function TOsm3dMcpFacade.GetGenerateLanduse: Boolean;
begin
  Result := FSettingsPtr^.GenerateLanduse;
end;

procedure TOsm3dMcpFacade.SetGenerateLanduse(AValue: Boolean);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.GenerateLanduse := AValue;
end;

function TOsm3dMcpFacade.GetGenerateWaterways: Boolean;
begin
  Result := FSettingsPtr^.GenerateWaterways;
end;

procedure TOsm3dMcpFacade.SetGenerateWaterways(AValue: Boolean);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.GenerateWaterways := AValue;
end;

function TOsm3dMcpFacade.GetGeneratePOI: Boolean;
begin
  Result := FSettingsPtr^.GeneratePOI;
end;

procedure TOsm3dMcpFacade.SetGeneratePOI(AValue: Boolean);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.GeneratePOI := AValue;
end;

function TOsm3dMcpFacade.GetGenerateLabels: Boolean;
begin
  Result := FSettingsPtr^.GenerateLabels;
end;

procedure TOsm3dMcpFacade.SetGenerateLabels(AValue: Boolean);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.GenerateLabels := AValue;
end;

function TOsm3dMcpFacade.GetGeneratePlates: Boolean;
begin
  Result := FSettingsPtr^.GeneratePlates;
end;

procedure TOsm3dMcpFacade.SetGeneratePlates(AValue: Boolean);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.GeneratePlates := AValue;
end;

function TOsm3dMcpFacade.GetGenerateRouteOnly: Boolean;
begin
  Result := FSettingsPtr^.GenerateRouteOnly;
end;

procedure TOsm3dMcpFacade.SetGenerateRouteOnly(AValue: Boolean);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.GenerateRouteOnly := AValue;
end;

function TOsm3dMcpFacade.GetRouteOnlyRadiusM: Single;
begin
  Result := FSettingsPtr^.RouteOnlyRadiusM;
end;

procedure TOsm3dMcpFacade.SetRouteOnlyRadiusM(AValue: Single);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.RouteOnlyRadiusM := AValue;
end;

function TOsm3dMcpFacade.GetRenderBuildings: Boolean;
begin
  Result := FSettingsPtr^.RenderBuildings;
end;

procedure TOsm3dMcpFacade.SetRenderBuildings(AValue: Boolean);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.RenderBuildings := AValue;
end;

function TOsm3dMcpFacade.GetRenderFences: Boolean;
begin
  Result := FSettingsPtr^.RenderFences;
end;

procedure TOsm3dMcpFacade.SetRenderFences(AValue: Boolean);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.RenderFences := AValue;
end;

function TOsm3dMcpFacade.GetRenderRoads: Boolean;
begin
  Result := FSettingsPtr^.RenderRoads;
end;

procedure TOsm3dMcpFacade.SetRenderRoads(AValue: Boolean);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.RenderRoads := AValue;
end;

function TOsm3dMcpFacade.GetRenderTrees: Boolean;
begin
  Result := FSettingsPtr^.RenderTrees;
end;

procedure TOsm3dMcpFacade.SetRenderTrees(AValue: Boolean);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.RenderTrees := AValue;
end;

function TOsm3dMcpFacade.GetRenderGrass: Boolean;
begin
  Result := FSettingsPtr^.RenderGrass;
end;

procedure TOsm3dMcpFacade.SetRenderGrass(AValue: Boolean);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.RenderGrass := AValue;
end;

function TOsm3dMcpFacade.GetRenderLanduse: Boolean;
begin
  Result := FSettingsPtr^.RenderLanduse;
end;

procedure TOsm3dMcpFacade.SetRenderLanduse(AValue: Boolean);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.RenderLanduse := AValue;
end;

function TOsm3dMcpFacade.GetRenderWaterways: Boolean;
begin
  Result := FSettingsPtr^.RenderWaterways;
end;

procedure TOsm3dMcpFacade.SetRenderWaterways(AValue: Boolean);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.RenderWaterways := AValue;
end;

function TOsm3dMcpFacade.GetRenderPOI: Boolean;
begin
  Result := FSettingsPtr^.RenderPOI;
end;

procedure TOsm3dMcpFacade.SetRenderPOI(AValue: Boolean);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.RenderPOI := AValue;
end;

function TOsm3dMcpFacade.GetRenderLabels: Boolean;
begin
  Result := FSettingsPtr^.RenderLabels;
end;

procedure TOsm3dMcpFacade.SetRenderLabels(AValue: Boolean);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.RenderLabels := AValue;
end;

function TOsm3dMcpFacade.GetRenderPlates: Boolean;
begin
  Result := FSettingsPtr^.RenderPlates;
end;

procedure TOsm3dMcpFacade.SetRenderPlates(AValue: Boolean);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.RenderPlates := AValue;
end;

function TOsm3dMcpFacade.GetUseGroundComposition: Boolean;
begin
  Result := FSettingsPtr^.UseGroundComposition;
end;

procedure TOsm3dMcpFacade.SetUseGroundComposition(AValue: Boolean);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.UseGroundComposition := AValue;
end;

function TOsm3dMcpFacade.GetUseGroundCompositionShader: Boolean;
begin
  Result := FSettingsPtr^.UseGroundCompositionShader;
end;

procedure TOsm3dMcpFacade.SetUseGroundCompositionShader(AValue: Boolean);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.UseGroundCompositionShader := AValue;
end;

function TOsm3dMcpFacade.GetUseGroundCompositionMaterialIdAttribute: Boolean;
begin
  Result := FSettingsPtr^.UseGroundCompositionMaterialIdAttribute;
end;

procedure TOsm3dMcpFacade.SetUseGroundCompositionMaterialIdAttribute(AValue: Boolean);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.UseGroundCompositionMaterialIdAttribute := AValue;
end;

function TOsm3dMcpFacade.GetGroundAtlasGridCols: Integer;
begin
  Result := FSettingsPtr^.GroundAtlasGridCols;
end;

procedure TOsm3dMcpFacade.SetGroundAtlasGridCols(AValue: Integer);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.GroundAtlasGridCols := AValue;
end;

function TOsm3dMcpFacade.GetGroundAtlasGridRows: Integer;
begin
  Result := FSettingsPtr^.GroundAtlasGridRows;
end;

procedure TOsm3dMcpFacade.SetGroundAtlasGridRows(AValue: Integer);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.GroundAtlasGridRows := AValue;
end;

function TOsm3dMcpFacade.GetGroundAtlasTilePixels: Integer;
begin
  Result := FSettingsPtr^.GroundAtlasTilePixels;
end;

procedure TOsm3dMcpFacade.SetGroundAtlasTilePixels(AValue: Integer);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.GroundAtlasTilePixels := AValue;
end;

function TOsm3dMcpFacade.GetGenerateFarTerrain: Boolean;
begin
  Result := FSettingsPtr^.GenerateFarTerrain;
end;

procedure TOsm3dMcpFacade.SetGenerateFarTerrain(AValue: Boolean);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.GenerateFarTerrain := AValue;
end;

function TOsm3dMcpFacade.GetFarTerrainExpansionMeters: Single;
begin
  Result := FSettingsPtr^.FarTerrainExpansionMeters;
end;

procedure TOsm3dMcpFacade.SetFarTerrainExpansionMeters(AValue: Single);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.FarTerrainExpansionMeters := AValue;
end;

function TOsm3dMcpFacade.GetFarTerrainZoom: Integer;
begin
  Result := FSettingsPtr^.FarTerrainZoom;
end;

procedure TOsm3dMcpFacade.SetFarTerrainZoom(AValue: Integer);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.FarTerrainZoom := AValue;
end;

function TOsm3dMcpFacade.GetFarTerrainGridStepM: Single;
begin
  Result := FSettingsPtr^.FarTerrainGridStepM;
end;

procedure TOsm3dMcpFacade.SetFarTerrainGridStepM(AValue: Single);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.FarTerrainGridStepM := AValue;
end;

function TOsm3dMcpFacade.GetShowFitPoints: Boolean;
begin
  Result := FSettingsPtr^.ShowFitPoints;
end;

procedure TOsm3dMcpFacade.SetShowFitPoints(AValue: Boolean);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.ShowFitPoints := AValue;
end;

function TOsm3dMcpFacade.GetShowFitPointsSnapped: Boolean;
begin
  Result := FSettingsPtr^.ShowFitPointsSnapped;
end;

procedure TOsm3dMcpFacade.SetShowFitPointsSnapped(AValue: Boolean);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.ShowFitPointsSnapped := AValue;
end;

function TOsm3dMcpFacade.GetBuildingShadows: Boolean;
begin
  Result := FSettingsPtr^.BuildingShadows;
end;

procedure TOsm3dMcpFacade.SetBuildingShadows(AValue: Boolean);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.BuildingShadows := AValue;
end;

function TOsm3dMcpFacade.GetGenerateGroundShadows: Boolean;
begin
  Result := FSettingsPtr^.GenerateGroundShadows;
end;

procedure TOsm3dMcpFacade.SetGenerateGroundShadows(AValue: Boolean);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.GenerateGroundShadows := AValue;
end;

function TOsm3dMcpFacade.GetWaterShaders: Boolean;
begin
  Result := FSettingsPtr^.WaterShaders;
end;

procedure TOsm3dMcpFacade.SetWaterShaders(AValue: Boolean);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.WaterShaders := AValue;
end;

function TOsm3dMcpFacade.GetWaterWaveSize: Single;
begin
  Result := FSettingsPtr^.WaterWaveSize;
end;

procedure TOsm3dMcpFacade.SetWaterWaveSize(AValue: Single);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.WaterWaveSize := AValue;
end;

function TOsm3dMcpFacade.GetWaterLevelLift: Single;
begin
  Result := FSettingsPtr^.WaterLevelLift;
end;

procedure TOsm3dMcpFacade.SetWaterLevelLift(AValue: Single);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.WaterLevelLift := AValue;
end;

function TOsm3dMcpFacade.GetBuildingTextures: Boolean;
begin
  Result := FSettingsPtr^.BuildingTextures;
end;

procedure TOsm3dMcpFacade.SetBuildingTextures(AValue: Boolean);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.BuildingTextures := AValue;
end;

function TOsm3dMcpFacade.GetBuildingPBR: Boolean;
begin
  Result := FSettingsPtr^.BuildingPBR;
end;

procedure TOsm3dMcpFacade.SetBuildingPBR(AValue: Boolean);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.BuildingPBR := AValue;
end;

function TOsm3dMcpFacade.GetFogDistanceM: Single;
begin
  Result := FSettingsPtr^.FogDistanceM;
end;

procedure TOsm3dMcpFacade.SetFogDistanceM(AValue: Single);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.FogDistanceM := AValue;
end;

function TOsm3dMcpFacade.GetFogClearZoneM: Single;
begin
  Result := FSettingsPtr^.FogClearZoneM;
end;

procedure TOsm3dMcpFacade.SetFogClearZoneM(AValue: Single);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.FogClearZoneM := AValue;
end;

function TOsm3dMcpFacade.GetFitHeightCorrection: Boolean;
begin
  Result := FSettingsPtr^.FitHeightCorrection;
end;

procedure TOsm3dMcpFacade.SetFitHeightCorrection(AValue: Boolean);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.FitHeightCorrection := AValue;
end;

function TOsm3dMcpFacade.GetWorldScaleLatDeg: Double;
begin
  Result := FSettingsPtr^.WorldScaleLatDeg;
end;

procedure TOsm3dMcpFacade.SetWorldScaleLatDeg(AValue: Double);
begin
  { Только запись в настройки. Применение (ApplyStudioSettingsToGlobals,
    пересоздание сессии) — при следующем osm.start_streaming. }
  FSettingsPtr^.WorldScaleLatDeg := AValue;
end;

{ ── TOsm3dMcpMapFacade ───────────────────────────────────────────────── }

constructor TOsm3dMcpMapFacade.Create(AForm: TStudioMainForm);
begin
  inherited Create;
  if AForm = nil then
    raise EMcpError.Create('TOsm3dMcpMapFacade.Create: form is nil');
  FForm := AForm;
end;

function TOsm3dMcpMapFacade.GetRenderInfo: string;
begin
  Result := FForm.RenderInfo;
end;

function TOsm3dMcpMapFacade.GetFpsMode:TFpsLimitMode;
begin Result:=FForm.GetFpsMode end;
procedure TOsm3dMcpMapFacade.SetFpsMode(Value:TFpsLimitMode);
begin FForm.SetFpsMode(Value) end;
function TOsm3dMcpMapFacade.GetWorldShadows:Boolean;
begin Result:=FForm.WorldShadowsEnabled end;
procedure TOsm3dMcpMapFacade.SetWorldShadows(Value:Boolean);
begin FForm.WorldShadowsEnabled:=Value end;

function TOsm3dMcpFacade.GetProceduralTrees:Boolean;
begin Result:=ProceduralVegetationActive;end;
procedure TOsm3dMcpFacade.SetProceduralTrees(AValue:Boolean);
begin StudioMainForm.SetProceduralTrees(AValue);end;

function TOsm3dMcpMapFacade.GetSessionActive: Boolean;
begin
  Result := FForm.StreamSession <> nil;
end;

function TOsm3dMcpMapFacade.GetOriginLat: Double;
begin
  Result := FForm.StreamOrigin.Lat;
end;

function TOsm3dMcpMapFacade.GetOriginLon: Double;
begin
  Result := FForm.StreamOrigin.Lon;
end;

function TOsm3dMcpMapFacade.GetRoutePoints: Integer;
begin
  Result := FForm.RoutePointCount;
end;

function TOsm3dMcpMapFacade.GetFlatMode: Boolean;
begin
  Result := FForm.IsFlatMode;
end;

procedure TOsm3dMcpMapFacade.SetFlatMode(AValue: Boolean);
begin
  FForm.McpSetMapMode(AValue);
end;

function TOsm3dMcpMapFacade.GetMapExists: Boolean;
begin
  Result := (FForm.StreamSession <> nil) and FForm.StreamSession.Map.Exists;
end;

procedure TOsm3dMcpMapFacade.SetMapExists(AValue: Boolean);
begin
  if FForm.StreamSession = nil then
    raise EMcpError.Create('map.MapExists: нет активной сессии стриминга');
  FForm.StreamSession.Map.Exists := AValue;
end;

{ ── Команды ──────────────────────────────────────────────────────────── }

function ReqStr(const AParams: TJSONObject; const AName: String): String;
begin
  if AParams.Find(AName) = nil then
    raise EMcpError.CreateFmt('missing required argument "%s"', [AName]);
  Result := AParams.Strings[AName];
end;

procedure CmdPhotoComparison(const AParams: TJSONObject; AResult: TJSONObject);
var R:TJSONObject;I:Integer;
begin
  R:=GForm.PhotoComparisonCommand(AParams);
  try for I:=0 to R.Count-1 do AResult.Add(R.Names[I],R.Items[I].Clone) finally R.Free end;
end;

procedure CmdLoadRoute(const AParams: TJSONObject; AResult: TJSONObject);
begin
  GForm.McpLoadRoute(ReqStr(AParams, 'path'));
  AResult.Add('ok', True);
  AResult.Add('points', GForm.RoutePointCount);
end;

function TOsm3dMcpMapFacade.ReviewWantTile(const Id:TGeoTileId):Boolean;
begin
  Result:=Id.Equals(FReviewTile);
  if Result and Assigned(FReviewFilter) then Result:=FReviewFilter(Id);
end;

procedure TOsm3dMcpMapFacade.RestrictReviewTo(const Origin:TLatLon);
var Grid:TGeoTileGrid;
begin
  Grid:=TGeoTileGrid.Create(FForm.SettingsPtr^.HeightmapZoom,GEO_TILE_EDGE_PX);
  try FReviewTile:=Grid.TileAt(Origin) finally Grid.Free end;
  if (FForm.StreamSession=nil) or (FForm.StreamSession.Map=nil) then
    raise EMcpError.Create('Single-tile review requires an active map');
  FReviewFilter:=FForm.StreamSession.Map.Streamer.WantFilter;
  FForm.StreamSession.Map.Streamer.WantFilter:=@ReviewWantTile;
end;

procedure CmdStartStreaming(const AParams: TJSONObject; AResult: TJSONObject);
var
  LL: TLatLon;
  HasLat, HasLon, UseOrigin: Boolean;
begin
  HasLat := AParams.Find('lat') <> nil;
  HasLon := AParams.Find('lon') <> nil;
  if HasLat <> HasLon then
    raise EMcpError.Create('lat и lon надо задавать вместе (или не задавать вовсе)');
  UseOrigin := HasLat;
  if AParams.Get('single_tile',False) and not UseOrigin then
    raise EMcpError.Create('single_tile requires lat and lon');
  if UseOrigin then
    LL := TLatLon.Make(AParams.Floats['lat'], AParams.Floats['lon']);
  GForm.McpStartStreaming(LL, UseOrigin);
  if AParams.Get('single_tile',False) then begin
    GMapFacade.RestrictReviewTo(LL);
    AResult.Add('single_tile',GMapFacade.FReviewTile.ToString);
  end;
  AResult.Add('ok', True);
end;

procedure CmdSetMapMode(const AParams: TJSONObject; AResult: TJSONObject);
var
  M: String;
begin
  M := LowerCase(ReqStr(AParams, 'mode'));
  if M = 'flat' then
    GForm.McpSetMapMode(True)
  else if M = '3d' then
    GForm.McpSetMapMode(False)
  else
    raise EMcpError.Create('mode must be "flat" or "3d"');
  AResult.Add('ok', True);
  AResult.Add('flat', GForm.IsFlatMode);
end;

procedure CmdScreenshot(const AParams: TJSONObject; AResult: TJSONObject);
var
  P: String;
begin
  P := ReqStr(AParams, 'path');
  GForm.McpScreenshot(P);
  AResult.Add('ok', True);
  AResult.Add('path', P);
end;

procedure CmdResetTiles(const AParams: TJSONObject; AResult: TJSONObject);
begin
  GForm.McpResetTiles;
  AResult.Add('ok', True);
end;

procedure CmdSearchPlace(const AParams: TJSONObject; AResult: TJSONObject);
var
  Q: TGeoQuery;
  Hits: TGeoHitArray;
  Arr: TJSONArray;
  H: TJSONObject;
  I: Integer;
begin
  { ВНИМАНИЕ: GeocodeSearch — синхронный HTTP-запрос, главный поток
    заблокирован на время ответа Nominatim (для MCP-управления допустимо). }
  Q := TGeoQuery.Make(ReqStr(AParams, 'query'));
  if not GeocodeSearch(Q, Hits) then
    raise EMcpError.Create('geocoding failed or no hits: ' + Q.Text);
  Arr := TJSONArray.Create;
  for I := 0 to High(Hits) do
  begin
    H := TJSONObject.Create;
    H.Add('name', Hits[I].DisplayName);
    H.Add('lat', Hits[I].Location.Lat);
    H.Add('lon', Hits[I].Location.Lon);
    Arr.Add(H);
  end;
  AResult.Add('hits', Arr);
  { Центрируем плоскую карту на первом (наиболее релевантном) совпадении. }
  GForm.McpJumpToPlace(Hits[0].Location);
  AResult.Add('ok', True);
end;

{ ── Init / Shutdown ──────────────────────────────────────────────────── }

procedure CmdStability(const AParams:TJSONObject;AResult:TJSONObject);
begin
  (GForm.McpViewport as TOsmImpostorViewport).ProbeStability(AParams,AResult);
end;

procedure CmdRtx(const AParams:TJSONObject;AResult:TJSONObject);
begin
  if AParams.Find('cached_raster')<>nil then begin
    if AParams.Get('cached_raster',False) then GForm.SetRtxCachedRaster(True)
    else GForm.SetWorldRtxShadows(True);
  end else if AParams.Get('enabled',False) then GForm.SetWorldRtxShadows(True);
  if (AParams.Find('enabled')<>nil) and not AParams.Get('enabled',False) then GForm.SetWorldRtxShadows(False);
  if AParams.Find('reflections')<>nil then GForm.SetRtxReflections(AParams.Get('reflections',False));
  if AParams.Get('diagnostics',False) then GForm.DebugRtxReflections;
  GForm.RtxSnapshot(AResult);
end;

procedure CmdImpostor(const AParams:TJSONObject;AResult:TJSONObject);
var V:TOsmImpostorViewport;Current:TJSONObject;
begin
  V:=GForm.McpViewport as TOsmImpostorViewport;
  if AParams.Find('enabled')<>nil then GForm.SetWorldImpostorCache(AParams.Get('enabled',False));
  if (AParams.Find('near_m')<>nil)or(AParams.Find('middle_m')<>nil)or
     (AParams.Find('far_m')<>nil)or(AParams.Find('hz1')<>nil)or
     (AParams.Find('hz2')<>nil)or(AParams.Find('hz3')<>nil)or
     (AParams.Find('resolution')<>nil)then begin
    Current:=TJSONObject.Create;
    try
      V.Snapshot(Current);
      V.Configure(AParams.Get('near_m',Current.Floats['near_m']),
        AParams.Get('middle_m',Current.Floats['middle_m']),
        AParams.Get('far_m',Current.Floats['far_m']),
        AParams.Get('hz1',Current.Floats['hz1']),AParams.Get('hz2',Current.Floats['hz2']),
        AParams.Get('hz3',Current.Floats['hz3']),AParams.Get('resolution',Current.Floats['resolution']));
    finally Current.Free end;
  end;
  if AParams.Get('invalidate',False)then V.Invalidate;
  V.Snapshot(AResult);
  if GForm.StreamSession<>nil then
    AResult.Add('pending_tiles',GForm.StreamSession.Map.PendingTileWork)
  else AResult.Add('pending_tiles',-1);
end;

procedure CmdRenderCapture(const AParams:TJSONObject;AResult:TJSONObject);
begin
  (GForm.McpViewport as TOsmImpostorViewport).Measure(AParams.Get('start',False),AResult);
  { Snapshot of the last rendered world frame, not a material/mesh estimate. }
  AResult.Add('last_frame_draw_calls',(GForm.McpViewport as TCastleViewport).Statistics.DrawCalls);
  AResult.Add('last_frame_shapes',(GForm.McpViewport as TCastleViewport).Statistics.ShapesRendered);
  AResult.Add('last_frame_scenes',(GForm.McpViewport as TCastleViewport).Statistics.ScenesRendered);
end;

procedure CmdFpsMode(const AParams:TJSONObject;AResult:TJSONObject);
begin
  GForm.SetFpsMode(flmVsyncOffMax);
  AResult.Add('mode','unlimited');
end;

procedure CmdProbeCamera(const AParams:TJSONObject;AResult:TJSONObject);
begin
  (GForm.McpViewport as TOsmImpostorViewport).ProbeCamera(AParams,AResult);
end;

procedure CmdRenderFlags(const AParams:TJSONObject;AResult:TJSONObject);
begin
  { Live diagnostic switches, unlike the generation settings facade above.
    Keep all resident geometry and caches so A/B measures the same scene.
    These flags are process-local and are never saved to the user's settings. }
  if AParams.Find('world_complexity')<>nil then SetRenderComplexity(rdWorld,AParams.Get('world_complexity',3));
  if AParams.Find('trees')<>nil then RenderTreesActive:=AParams.Get('trees',True);
  if AParams.Find('grass')<>nil then RenderGrassActive:=AParams.Get('grass',True);
  if AParams.Find('grass_blades')<>nil then GrassDrawBlades:=AParams.Get('grass_blades',True);
  if AParams.Find('grass_cards')<>nil then GrassDrawCards:=AParams.Get('grass_cards',True);
  if AParams.Find('grass_carpet')<>nil then GrassDrawCarpet:=AParams.Get('grass_carpet',True);
  if AParams.Find('shadows')<>nil then GForm.WorldShadowsEnabled:=AParams.Get('shadows',True);
  AResult.Add('world_complexity',GetRenderComplexity(rdWorld));
  AResult.Add('trees',RenderTreesActive);
  AResult.Add('grass',RenderGrassActive);
  AResult.Add('grass_blades',GrassDrawBlades);
  AResult.Add('grass_cards',GrassDrawCards);
  AResult.Add('grass_carpet',GrassDrawCarpet);
  AResult.Add('shadows',GForm.WorldShadowsEnabled);
  AResult.Add('procedural_trees',ProceduralVegetationActive);
  AResult.Add('tree_diagnostics',ProceduralVegetationDiagnostics);
  if GForm.StreamSession<>nil then
    AResult.Add('grass_diagnostics',GForm.StreamSession.Map.GrassDiagnostics);
  AResult.Add('render',GForm.RenderInfo);
end;

procedure Osm3dMcpInit(AForm: TStudioMainForm);
begin
  if not Osm3dMcpRequested then Exit;
  if AForm = nil then
    raise EMcpError.Create('Osm3dMcpInit: form is nil');
  GForm := AForm;

  { Страховка: .lpr глушит stdout ещё до Application.Initialize; повторный
    вызов безвреден. }
  McpSilenceStdOut;

  GFacade := TOsm3dMcpFacade.Create(AForm.SettingsPtr);
  RegisterPhotoMcpTools(AForm.SettingsPtr^.CacheRoot, AForm.SettingsPtr^.HeightmapZoom, GEO_TILE_EDGE_PX,
    AForm.SettingsPtr^.OverpassTileZoom, AForm.SettingsPtr^.OverpassTimeoutS);
  RegisterPhotoViewRenderTools(@PhotoViewContext,@PhotoViewMode,AForm.PhotoRenderer);
  RegisterMcpCommand('osm.photo_compare','Studio photo/3D comparison UI with a horizontal source gallery. Uses the current tile knowledge and existing HTTP cache.',
    '{"type":"object","properties":{"action":{"type":"string","enum":["show","close","select","reset","save","status","capture_controls"]},"index":{"type":"integer"},"path":{"type":"string"}}}',@CmdPhotoComparison);
  GMapFacade := TOsm3dMcpMapFacade.Create(AForm);
  RegisterMcpObject('settings', GFacade);
  RegisterMcpObject('mainform', AForm);
  RegisterMcpObject('viewport', AForm.McpViewport);
  RegisterMcpObject('map', GMapFacade);

  RegisterMcpCommand('osm.impostor','World-only multilevel RGB-D cache. Disabled uses the original renderer.',
    '{"type":"object","properties":{"enabled":{"type":"boolean"},"near_m":{"type":"number"},"middle_m":{"type":"number"},"far_m":{"type":"number"},"hz1":{"type":"number"},"hz2":{"type":"number"},"hz3":{"type":"number"},"resolution":{"type":"number"},"invalidate":{"type":"boolean"}}}',@CmdImpostor);
  RegisterMcpCommand('osm.rtx','Optional hardware world shadow atlas with cached tree projections. Raster fallback is retained.',
    '{"type":"object","properties":{"enabled":{"type":"boolean"},"cached_raster":{"type":"boolean"},"reflections":{"type":"boolean"},"diagnostics":{"type":"boolean"}}}',@CmdRtx);
  RegisterMcpCommand('osm.render_capture','Start/stop viewport CPU/GPU and frame timing samples.',
    '{"type":"object","properties":{"start":{"type":"boolean"}}}',@CmdRenderCapture);
  RegisterMcpCommand('osm.render_stability','Bounded consecutive-frame RGB comparison of a static ROI. Readback affects timing; never use for FPS benchmarks.',
    '{"type":"object","properties":{"frames":{"type":"integer"},"x":{"type":"integer"},"y":{"type":"integer"},"width":{"type":"integer"},"height":{"type":"integer"}}}',@CmdStability);
  RegisterMcpCommand('osm.fps_max','Disable VSync and the FPS cap for a benchmark.',
    '{"type":"object","properties":{}}',@CmdFpsMode);
  RegisterMcpCommand('osm.camera_probe','Atomic camera pose and repeatable timed motion for render comparisons.',
    '{"type":"object","properties":{"position":{"type":"array"},"direction":{"type":"array"},"up":{"type":"array"},"velocity":{"type":"array"},"duration_s":{"type":"number"},"yaw_deg_s":{"type":"number"},"stop":{"type":"boolean"}}}',@CmdProbeCamera);
  RegisterMcpCommand('osm.render_flags','Live process-local render switches for same-scene cost measurements; no tile regeneration.',
    '{"type":"object","properties":{"world_complexity":{"type":"integer","minimum":0,"maximum":3},"trees":{"type":"boolean"},"grass":{"type":"boolean"},"grass_blades":{"type":"boolean"},"grass_cards":{"type":"boolean"},"grass_carpet":{"type":"boolean"},"shadows":{"type":"boolean"}}}',@CmdRenderFlags);

  RegisterMcpCommand('osm.load_route',
    'Загрузить маршрут из FIT/GPX/CSV файла (аналог File→Open route).',
    '{"type":"object","properties":{' +
    '"path":{"type":"string","description":"путь к .fit/.gpx/.csv файлу маршрута"}},' +
    '"required":["path"]}',
    @CmdLoadRoute);
  RegisterMcpCommand('osm.start_streaming',
    'Запустить/перезапустить 3D-стриминг тайлов. Без lat/lon — origin = ' +
    'первая точка загруженного маршрута. Применяет текущие настройки (settings).',
    '{"type":"object","properties":{' +
    '"single_tile":{"type":"boolean","description":"Review only the tile at lat/lon in this Studio session; does not alter tile geometry or saved settings."},' +
    '"lat":{"type":"number","description":"широта origin (только вместе с lon)"},' +
    '"lon":{"type":"number","description":"долгота origin (только вместе с lat)"}}}',
    @CmdStartStreaming);
  RegisterMcpCommand('osm.set_map_mode',
    'Переключить режим карты: "flat" (плоская OSM-карта) или "3d".',
    '{"type":"object","properties":{' +
    '"mode":{"type":"string","enum":["flat","3d"],"description":"flat | 3d"}},' +
    '"required":["mode"]}',
    @CmdSetMapMode);
  RegisterMcpCommand('osm.screenshot',
    'Сохранить кадр GL-вьюпорта в PNG (читается framebuffer — окно может ' +
    'быть свёрнуто или перекрыто).',
    '{"type":"object","properties":{' +
    '"path":{"type":"string","description":"куда сохранить PNG"}},' +
    '"required":["path"]}',
    @CmdScreenshot);
  RegisterMcpCommand('osm.reset_tiles',
    'Очистить дисковый кэш сгенерированных тайлов (папка o3dt; http-кэш не трогается).',
    '{"type":"object","properties":{}}',
    @CmdResetTiles);
  RegisterMcpCommand('osm.search_place',
    'Поиск места по имени (Nominatim): центрирует плоскую карту на первом ' +
    'совпадении и возвращает все хиты.',
    '{"type":"object","properties":{' +
    '"query":{"type":"string","description":"строка поиска, напр. \"Волчанск\""}},' +
    '"required":["query"]}',
    @CmdSearchPlace);

  GServer := TMcpStdioServer.Create('osm3d-studio', '1.0.0');
  GServer.OnEndOfStream := @GFacade.HandleEndOfStream;
  if not GServer.Start then
  begin
    { Нет std-пайпов (приложение запущено не MCP-хостом) — живём без
      транспорта; объекты/команды остаются зарегистрированными. }
    FreeAndNil(GServer);
  end;
end;

procedure Osm3dMcpShutdown;
begin
  FreeAndNil(GServer);
  ShutdownPhotoMcpTools;
  ShutdownPhotoViewRenderTools;
  UnregisterMcpObject('viewport');
  FreeAndNil(GMapFacade);
  FreeAndNil(GFacade);
  GForm := nil;
end;

end.
