unit Osm3dStudioController;

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$codepage UTF8}

interface

uses
  Classes,
  SysUtils,
  Osm3dGeoMath,
  Osm3dCacheHTTPFetcher,
  Osm3dHeightmap,
  Osm3dOsmData,
  Osm3dOsmOverpass,
  Osm3dChunk,
  Osm3dMapUtils,
  Osm3dStudioSettings,
  Osm3dStudioLog,
  Osm3dCache,
  Osm3dStudioUtils
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
;

type
  TGenerationStage = (
    gsIdle,
    gsBboxAndOrigin,
    gsHeightmapFetch,
    gsHeightmapStitch,
    gsOsmFetch,
    gsOsmParse,
    gsAssemble,
    gsDone,
    gsCanceled,
    gsError
  );

  TGenerationProgress = record
    Stage:      TGenerationStage;
    StageIndex: Integer;
    StageTotal: Integer;
    Message:    string;

    SubIndex:   Integer;
    SubTotal:   Integer;
  end;

  TGenerationProgressEvent = procedure(const Progress: TGenerationProgress)
    of object;

  TGenerationPipeline = class(TLogOwner)
  private
    FRoute:       TRouteLatLonArray;
    FSettings:    TStudioSettings;
    FHttpFetcher: THTTPFetcherWithCache;

    FCanceledFlag: PBoolean;
    FOnProgress:   TGenerationProgressEvent;
    FOnOsmTile:    TOverpassTileEvent;
    FOnAttempt:    TOverpassAttemptEvent;

    procedure Report(Stage: TGenerationStage; const Msg: string;
      StageIndex: Integer; SubIndex: Integer = 0; SubTotal: Integer = 0);
    function  IsCanceled: Boolean;

    procedure HandleOsmTileEvent(Sender: TObject; const Tile: TTileXY;
      TileIndex, TileTotal: Integer; Success: Boolean;
      BytesGot: Integer; ElapsedMs: Int64;
      const UsedEndpoint, ErrorMsg: string;
      var Cancel: Boolean);

    procedure HandleOsmAttemptEvent(Sender: TObject;
      WorkerIdx: Integer; const Endpoint: string;
      const Tile: TTileXY; TileIndex, TileTotal: Integer;
      Success: Boolean; BytesGot: Integer; ElapsedMs: Int64;
      const ErrorMsg: string);
  public
    constructor Create(const ARoute: TRouteLatLonArray;
      const ASettings: TStudioSettings; ALog: TLogTarget;
      AHttpFetcher: THTTPFetcherWithCache);

    procedure SetCancelFlag(AFlag: PBoolean);

    function Run: TOsm3dChunkData;

    property OnProgress: TGenerationProgressEvent read FOnProgress write FOnProgress;
    property OnOsmTileProgress: TOverpassTileEvent
      read FOnOsmTile write FOnOsmTile;

    property OnOsmAttempt: TOverpassAttemptEvent
      read FOnAttempt write FOnAttempt;
  end;

  TGenerationJob = class(TThread)
  private
    FRoute:       TRouteLatLonArray;
    FSettings:    TStudioSettings;
    FLog:         TLogTarget;
    FHttpFetcher: THTTPFetcherWithCache;
    FCancelFlag:  Boolean;
    FResult:      TOsm3dChunkData;
    FOnProgress:  TGenerationProgressEvent;
    FOnOsmTile:   TOverpassTileEvent;
    FOnAttempt:   TOverpassAttemptEvent;
    FFinalStage:  TGenerationStage;
  protected
    procedure Execute; override;
  public
    constructor Create(const ARoute: TRouteLatLonArray;
      const ASettings: TStudioSettings; ALog: TLogTarget;
      AHttpFetcher: THTTPFetcherWithCache);

    procedure Cancel;

    property OnProgress: TGenerationProgressEvent
      read FOnProgress write FOnProgress;
    property OnOsmTileProgress: TOverpassTileEvent
      read FOnOsmTile write FOnOsmTile;
    property OnOsmAttempt: TOverpassAttemptEvent
      read FOnAttempt write FOnAttempt;
    property FinalStage: TGenerationStage read FFinalStage;
  end;

const
  STAGE_NAMES: array[TGenerationStage] of string = (
    'Idle',
    'BboxAndOrigin',
    'HeightmapFetch',
    'HeightmapStitch',
    'OsmFetch',
    'OsmParse',
    'Assemble',
    'Done',
    'Canceled',
    'Error'
  );

  STAGE_TOTAL = 7;

type
  TStudioState = (
    ssIdle,
    ssRouteLoaded,
    ssGenerating,
    ssReady,
    ssError
  );

  TStudioStateEvent = procedure(NewState: TStudioState) of object;

  TStudioController = class
  private
    FSettings: TStudioSettings;
    FLog:      TLogTarget;

    FState:    TStudioState;
    FRoute:    TRouteLatLonArray;
    FRouteStartUTC: TDateTime;   { UTC of first GPS point; 0 = unknown }
    FChunk:    TOsm3dChunkData;
    FJob:      TGenerationJob;

    FMemCache:  TMemoryCache;
    FDiskCache: TFileSystemCache;
    FCache:     TCompositeCache;
    FHttp:      THTTPFetcherWithCache;

    FOnStateChanged:    TStudioStateEvent;
    FOnProgress:        TGenerationProgressEvent;

    FOnNetworkRequest:  TNetworkRequestEvent;
    FOnNetworkProgress: TNetworkProgressEvent;
    FOnNetworkSuccess:  TNetworkSuccessEvent;
    FOnCacheHit:        TCacheHitEvent;
    FOnNetworkError:    TFetchErrorEvent;
    FOnOsmTile:         TOverpassTileEvent;
    FOnOsmAttempt:      TOverpassAttemptEvent;

    procedure InitNetworking;
    procedure FreeNetworking;

    procedure HandleNetworkRequest(Sender: TObject;
      const URL, Method: string; BodySize: Integer);
    procedure HandleNetworkProgress(Sender: TObject;
      const URL, Method: string;
      Received, Total: Int64; ElapsedMs: Int64);
    procedure HandleNetworkSuccess(Sender: TObject;
      const URL, Method: string; StatusCode: Integer;
      ResponseSize: Int64; ElapsedMs: Int64);
    procedure HandleCacheHit(Sender: TObject;
      const URL: string; SizeBytes: Int64);
    procedure HandleNetworkError(Sender: TObject;
      const URL, ErrorMsg: string; Attempt: Integer;
      PartialSize: Int64; ElapsedMs: Int64);
  public
    constructor Create(const ASettings: TStudioSettings; ALog: TLogTarget);
    destructor Destroy; override;

    property State:         TStudioState      read FState;
    property Settings:      TStudioSettings   read FSettings;
    property Route:         TRouteLatLonArray read FRoute;
    property RouteStartUTC: TDateTime         read FRouteStartUTC;
    property Chunk:         TOsm3dChunkData   read FChunk;

    property OnStateChanged: TStudioStateEvent
             read FOnStateChanged    write FOnStateChanged;
    property OnProgress:     TGenerationProgressEvent
             read FOnProgress        write FOnProgress;

    property OnNetworkRequest:  TNetworkRequestEvent
             read FOnNetworkRequest  write FOnNetworkRequest;
    property OnNetworkProgress: TNetworkProgressEvent
             read FOnNetworkProgress write FOnNetworkProgress;
    property OnNetworkSuccess:  TNetworkSuccessEvent
             read FOnNetworkSuccess  write FOnNetworkSuccess;
    property OnCacheHit:        TCacheHitEvent
             read FOnCacheHit        write FOnCacheHit;
    property OnNetworkError:    TFetchErrorEvent
             read FOnNetworkError    write FOnNetworkError;
    property OnOsmTileProgress: TOverpassTileEvent
             read FOnOsmTile         write FOnOsmTile;

    property OnOsmAttempt: TOverpassAttemptEvent
             read FOnOsmAttempt      write FOnOsmAttempt;
  end;

implementation

constructor TGenerationPipeline.Create(const ARoute: TRouteLatLonArray;
  const ASettings: TStudioSettings; ALog: TLogTarget;
  AHttpFetcher: THTTPFetcherWithCache);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1267);{$ENDIF}
  inherited Create;
  FRoute       := ARoute;
  FSettings    := ASettings;
  FLog         := ALog;
  FHttpFetcher := AHttpFetcher;
  FCanceledFlag := nil;
end;

procedure TGenerationPipeline.SetCancelFlag(AFlag: PBoolean);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1334);{$ENDIF}
  FCanceledFlag := AFlag;
end;

function TGenerationPipeline.IsCanceled: Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1335);{$ENDIF}
  Result := (FCanceledFlag <> nil) and FCanceledFlag^;
end;

procedure TGenerationPipeline.Report(Stage: TGenerationStage;
  const Msg: string; StageIndex: Integer;
  SubIndex: Integer = 0; SubTotal: Integer = 0);
var
  P: TGenerationProgress;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(842);{$ENDIF}
  if not Assigned(FOnProgress) then Exit;
  P.Stage      := Stage;
  P.StageIndex := StageIndex;
  P.StageTotal := STAGE_TOTAL;
  P.Message    := Msg;
  P.SubIndex   := SubIndex;
  P.SubTotal   := SubTotal;
  FOnProgress(P);
end;

procedure TGenerationPipeline.HandleOsmTileEvent(Sender: TObject;
  const Tile: TTileXY; TileIndex, TileTotal: Integer; Success: Boolean;
  BytesGot: Integer; ElapsedMs: Int64;
  const UsedEndpoint, ErrorMsg: string;
  var Cancel: Boolean);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(843);{$ENDIF}
  Report(gsOsmFetch,
    Format('OSM tile %d/%d', [TileIndex, TileTotal]),
    4, TileIndex, TileTotal);

  if Assigned(FOnOsmTile) then
    FOnOsmTile(Sender, Tile, TileIndex, TileTotal, Success,
               BytesGot, ElapsedMs, UsedEndpoint, ErrorMsg, Cancel);

  if IsCanceled then Cancel := True;
end;

procedure TGenerationPipeline.HandleOsmAttemptEvent(Sender: TObject;
  WorkerIdx: Integer; const Endpoint: string;
  const Tile: TTileXY; TileIndex, TileTotal: Integer;
  Success: Boolean; BytesGot: Integer; ElapsedMs: Int64;
  const ErrorMsg: string);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(844);{$ENDIF}
  if Assigned(FOnAttempt) then
    FOnAttempt(Sender, WorkerIdx, Endpoint,
               Tile, TileIndex, TileTotal,
               Success, BytesGot, ElapsedMs, ErrorMsg);
end;

function TGenerationPipeline.Run: TOsm3dChunkData;
var
  Bbox:     TLatLonBox;
  Origin:   TLatLon;

  Tiles:    TTileXYArray;
  TileHms:  array of THeightmap;
  Stitched: THeightmap;
  TilesX, TilesY: Integer;

  FarTiles:    TTileXYArray;
  FarTileHms:  array of THeightmap;
  FarStitched: THeightmap;
  FarTilesX, FarTilesY: Integer;
  FarBbox:     TLatLonBox;

  TerrFetcher: TTerrariumFetcher;
  Overpass:    TOverpassClient;
  ParallelRunner: TParallelOverpassRunner;

  Dataset:  TOSMDataset;
  OsmTilesOk: Integer;

  I: Integer;
  T0, T1: TDateTime;
  TileCount: Integer;

  procedure Cleanup;
  var J: Integer;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1336);{$ENDIF}
    for J := 0 to High(TileHms) do
      if TileHms[J] <> nil then
        TileHms[J].Free;
    SetLength(TileHms, 0);
    for J := 0 to High(FarTileHms) do
      if FarTileHms[J] <> nil then
        FarTileHms[J].Free;
    SetLength(FarTileHms, 0);
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1337);{$ENDIF}
  Result := nil;
  if Length(FRoute) < 2 then
  begin
    LogError('Route has fewer than 2 points — nothing to generate');
    Report(gsError, 'route too short', 0);
    Exit;
  end;
  if FHttpFetcher = nil then
  begin
    LogError('HTTP fetcher not provided');
    Report(gsError, 'no fetcher', 0);
    Exit;
  end;

  TerrFetcher := nil;
  Overpass    := nil;
  ParallelRunner := nil;
  Dataset     := nil;
  Stitched    := nil;
  FarStitched := nil;
  SetLength(TileHms, 0);
  SetLength(FarTileHms, 0);

  try
    LogInfo('=== stage 1: bbox + origin ===');
    T0 := Now;
    Report(gsBboxAndOrigin, 'computing bbox and origin', 1);

    Bbox   := TRouteSrc.BboxFromPoints(FRoute);
    Bbox   := TRouteSrc.PadBboxMeters(Bbox, FSettings.BboxPaddingMeters);
    Origin := TRouteSrc.OriginCentroid(FRoute);

    LogInfo(Format('BBox: lat %.5f..%.5f, lon %.5f..%.5f (%d points, %.2f km)',
      [Bbox.MinLat, Bbox.MaxLat, Bbox.MinLon, Bbox.MaxLon,
       Length(FRoute), TRouteSrc.TotalLengthMeters(FRoute) / 1000]));
    LogInfo(Format('Origin: %.5f, %.5f', [Origin.Lat, Origin.Lon]));

    if IsCanceled then begin Report(gsCanceled, 'cancelled', 1); Exit; end;

    LogInfo('=== stage 2: heightmap fetch ===');
    Tiles := TTileMath.TilesCoveringBox(Bbox, FSettings.HeightmapZoom);
    if Length(Tiles) = 0 then
    begin
      LogError('No tiles cover this bbox — bbox empty?');
      Report(gsError, 'no tiles', 2);
      Exit;
    end;
    LogInfo(Format('Tiles to fetch: %d at zoom %d',
      [Length(Tiles), FSettings.HeightmapZoom]));

    Report(gsHeightmapFetch, 'fetching heightmap tiles', 2, 0, Length(Tiles));
    TerrFetcher := TTerrariumFetcher.Create(
      FHttpFetcher, FSettings.TerrariumUrlTemplate);

    SetLength(TileHms, Length(Tiles));
    TileCount := 0;
    for I := 0 to High(Tiles) do
    begin
      if IsCanceled then
      begin
        Cleanup;
        Report(gsCanceled, 'cancelled', 2);
        Exit;
      end;
      TileHms[I] := TerrFetcher.FetchTile(Tiles[I]);
      if TileHms[I] = nil then
      begin
        LogError(Format('Failed to fetch tile (%d, %d, %d)',
          [Tiles[I].X, Tiles[I].Y, Tiles[I].Zoom]));
        Cleanup;
        Report(gsError, 'tile fetch failure', 2);
        Exit;
      end;
      Inc(TileCount);
      Report(gsHeightmapFetch,
        Format('heightmap tile %d/%d', [TileCount, Length(Tiles)]),
        2, TileCount, Length(Tiles));
      LogDebug(Format('  tile (%d, %d) decoded: %dx%d, %d..%d m',
        [Tiles[I].X, Tiles[I].Y,
         TileHms[I].Width, TileHms[I].Height,
         Round(TileHms[I].MinHeight), Round(TileHms[I].MaxHeight)]));
    end;
    LogInfo(Format('  fetched %d tiles', [TileCount]));

    LogInfo('=== stage 3: heightmap stitch ===');
    Report(gsHeightmapStitch, 'stitching heightmap', 3);

    TilesX := Tiles[High(Tiles)].X - Tiles[0].X + 1;
    TilesY := Tiles[High(Tiles)].Y - Tiles[0].Y + 1;
    LogDebug(Format('  stitch grid: %dx%d', [TilesX, TilesY]));
    Stitched := THeightmapStitcher.Stitch(TileHms, TilesX, TilesY);
    LogInfo(Format('  stitched: %dx%d (%d MB)',
      [Stitched.Width, Stitched.Height, Stitched.DataBytes div (1024*1024)]));
    LogInfo(Format('  elevation range: %d..%d m',
      [Round(Stitched.MinHeight), Round(Stitched.MaxHeight)]));

    Cleanup;

    if IsCanceled then
    begin
      Stitched.Free; Stitched := nil;
      Report(gsCanceled, 'cancelled', 3);
      Exit;
    end;

    { Stage 3.5: optional far-terrain heightmap }
    if FSettings.GenerateFarTerrain then
    begin
      LogInfo('=== stage 3.5: far terrain heightmap fetch ===');
      FarBbox := Bbox.ExpandMeters(FSettings.FarTerrainExpansionMeters);
      FarTiles := TTileMath.TilesCoveringBox(FarBbox,
        FSettings.FarTerrainZoom);
      LogInfo(Format('Far tiles to fetch: %d at zoom %d (expansion ±%.0f m)',
        [Length(FarTiles), FSettings.FarTerrainZoom,
         FSettings.FarTerrainExpansionMeters]));

      if Length(FarTiles) > 0 then
      begin
        Report(gsHeightmapFetch, 'fetching far heightmap tiles',
          3, 0, Length(FarTiles));
        if TerrFetcher = nil then
          TerrFetcher := TTerrariumFetcher.Create(
            FHttpFetcher, FSettings.TerrariumUrlTemplate);

        SetLength(FarTileHms, Length(FarTiles));
        TileCount := 0;
        for I := 0 to High(FarTiles) do
        begin
          if IsCanceled then
          begin
            Cleanup;
            Stitched.Free; Stitched := nil;
            Report(gsCanceled, 'cancelled', 3);
            Exit;
          end;
          FarTileHms[I] := TerrFetcher.FetchTile(FarTiles[I]);
          if FarTileHms[I] = nil then
          begin
            LogError(Format('Failed to fetch FAR tile (%d,%d,%d) — skipping far terrain',
              [FarTiles[I].X, FarTiles[I].Y, FarTiles[I].Zoom]));
            Cleanup;
            Break;
          end;
          Inc(TileCount);
          Report(gsHeightmapFetch,
            Format('far tile %d/%d', [TileCount, Length(FarTiles)]),
            3, TileCount, Length(FarTiles));
        end;

        if TileCount = Length(FarTiles) then
        begin
          FarTilesX := FarTiles[High(FarTiles)].X - FarTiles[0].X + 1;
          FarTilesY := FarTiles[High(FarTiles)].Y - FarTiles[0].Y + 1;
          try
            FarStitched := THeightmapStitcher.Stitch(FarTileHms,
              FarTilesX, FarTilesY);
            LogInfo(Format('  far stitched: %dx%d (%d MB), elev %d..%d m',
              [FarStitched.Width, FarStitched.Height,
               FarStitched.DataBytes div (1024*1024),
               Round(FarStitched.MinHeight), Round(FarStitched.MaxHeight)]));
          except
            on E: Exception do
            begin
              LogError('Far heightmap stitch failed: ' + E.Message);
              FarStitched := nil;
            end;
          end;
          Cleanup;
        end;
      end;
    end;

    LogInfo('=== stage 4: OSM fetch ===');
    Report(gsOsmFetch, 'fetching OSM data', 4);
    Overpass := TOverpassClient.Create(FHttpFetcher, FSettings.OverpassEndpoints);
    Overpass.Log := FLog;
    if FSettings.OverpassEndpoints = '' then
    begin
      Overpass.Endpoints.Clear;
      Overpass.Endpoints.Add(FSettings.OverpassEndpoint);
    end;
    Overpass.TileZoom := FSettings.OverpassTileZoom;
    Overpass.TimeoutS := FSettings.OverpassTimeoutS;
    Overpass.OnTileProgress := @HandleOsmTileEvent;
    Dataset := TOSMDataset.Create;

    if FSettings.GenerateTrees and (not FSettings.GenerateLanduse) then
    begin
      LogInfo('NOTE: forcing landuse=True because trees=True ' +
              '(tree pipeline needs landuse=forest polygons)');
      FSettings.GenerateLanduse := True;
    end;

    LogInfo(Format('OSM endpoints: %d, tile zoom: %d, server-timeout: %ds',
      [Overpass.Endpoints.Count, Overpass.TileZoom, Overpass.TimeoutS]));
    LogInfo(Format('  features: buildings=%s roads=%s trees=%s landuse=%s waterways=%s',
      [BoolToStr(FSettings.GenerateBuildings, True),
       BoolToStr(FSettings.GenerateRoads,     True),
       BoolToStr(FSettings.GenerateTrees,     True),
       BoolToStr(FSettings.GenerateLanduse,   True),
       BoolToStr(FSettings.GenerateWaterways, True)]));

    LogInfo('OSM: starting tile fetch...');
    if FSettings.OverpassParallel and (Overpass.Endpoints.Count > 1) then
    begin
      LogInfo(Format('OSM: PARALLEL mode, %d workers', [Overpass.Endpoints.Count]));
      ParallelRunner := TParallelOverpassRunner.Create(FHttpFetcher, Overpass, FLog);
      ParallelRunner.OnTileProgress := @HandleOsmTileEvent;
      ParallelRunner.OnAttempt      := @HandleOsmAttemptEvent;
      OsmTilesOk := ParallelRunner.FetchAllTilesParallelInto(Bbox, Dataset,
        FSettings.GenerateBuildings,
        FSettings.GenerateRoads,
        FSettings.GenerateTrees,
        FSettings.GenerateLanduse,
        FSettings.GenerateWaterways);
    end
    else
    begin
      if FSettings.OverpassParallel then
        LogInfo('OSM: parallel disabled (only 1 endpoint), using sequential')
      else
        LogInfo('OSM: SEQUENTIAL mode (OverpassParallel=false)');
      OsmTilesOk := Overpass.FetchAllTilesInto(Bbox, Dataset,
        FSettings.GenerateBuildings,
        FSettings.GenerateRoads,
        FSettings.GenerateTrees,
        FSettings.GenerateLanduse,
        FSettings.GenerateWaterways);
    end;
    LogInfo(Format('OSM: tile fetch returned, %d tiles ok', [OsmTilesOk]));

    if IsCanceled then
    begin
      Stitched.Free; Stitched := nil;
      Dataset.Free;  Dataset  := nil;
      Report(gsCanceled, 'cancelled', 4);
      Exit;
    end;

    LogInfo('=== stage 5: OSM parse done ===');
    Report(gsOsmParse, 'OSM data ready', 5);
    LogInfo(Format('OSM dataset: %s', [Dataset.StatsString]));

    LogInfo('=== stage 6: assemble chunk ===');
    Report(gsAssemble, 'assembling chunk', 6);
    Result := TOsm3dChunkData.Create;
    Result.Origin := Origin;
    Result.Box    := Bbox;
    Result.SetHeightmap(Stitched);  Stitched := nil;
    Result.SetFarHeightmap(FarStitched); FarStitched := nil;
    Result.SetDataset(Dataset);     Dataset  := nil;

    T1 := Now;
    LogInfo(Format('Pipeline done in %.2f s', [(T1 - T0) * 86400]));
    Report(gsDone, 'done', 7);
    LogInfo('=== stage 7: gsDone reported to UI');

  finally
    TerrFetcher.Free;
    if ParallelRunner <> nil then
      ParallelRunner.Free;
    Overpass.Free;
    Cleanup;
    if Stitched    <> nil then Stitched.Free;
    if FarStitched <> nil then FarStitched.Free;
    if Dataset     <> nil then Dataset.Free;
  end;
end;

constructor TGenerationJob.Create(const ARoute: TRouteLatLonArray;
  const ASettings: TStudioSettings; ALog: TLogTarget;
  AHttpFetcher: THTTPFetcherWithCache);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1268);{$ENDIF}
  inherited Create(True);
  FreeOnTerminate := False;
  FRoute       := ARoute;
  FSettings    := ASettings;
  FLog         := ALog;
  FHttpFetcher := AHttpFetcher;
  FCancelFlag  := False;
  FResult      := nil;
  FFinalStage  := gsIdle;
end;

procedure TGenerationJob.Execute;
var
  Pipeline: TGenerationPipeline;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1338);{$ENDIF}
  if FLog <> nil then
    FLog.Write(llInfo, 'Job thread: starting pipeline...');
  Pipeline := TGenerationPipeline.Create(
    FRoute, FSettings, FLog, FHttpFetcher);
  try
    Pipeline.OnProgress        := FOnProgress;
    Pipeline.OnOsmTileProgress := FOnOsmTile;
    Pipeline.OnOsmAttempt      := FOnAttempt;
    Pipeline.SetCancelFlag(@FCancelFlag);
    FResult := Pipeline.Run;
    if FResult <> nil then
      FFinalStage := gsDone
    else if FCancelFlag then
      FFinalStage := gsCanceled
    else
      FFinalStage := gsError;
  finally
    Pipeline.Free;
  end;
end;

procedure TGenerationJob.Cancel;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(848);{$ENDIF}
  FCancelFlag := True;
end;

constructor TStudioController.Create(const ASettings: TStudioSettings;
  ALog: TLogTarget);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1269);{$ENDIF}
  inherited Create;
  FSettings := ASettings;
  FLog      := ALog;
  FState    := ssIdle;
  InitNetworking;
end;

destructor TStudioController.Destroy;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1270);{$ENDIF}
  if FJob <> nil then
  begin
    FJob.Cancel;
    FJob.WaitFor;
    FJob.Free;
  end;
  FreeAndNil(FChunk);
  FreeNetworking;
  inherited;
end;

procedure TStudioController.InitNetworking;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(850);{$ENDIF}
  FMemCache  := TMemoryCache.Create(FSettings.MemoryCacheBytes);
  FDiskCache := TFileSystemCache.Create(FSettings.CacheRoot);
  FCache := TCompositeCache.Create([FMemCache, FDiskCache]);
  FHttp := THTTPFetcherWithCache.Create(FCache, True);

  FHttp.OnNetworkRequest  := @HandleNetworkRequest;
  FHttp.OnNetworkProgress := @HandleNetworkProgress;
  FHttp.OnNetworkSuccess  := @HandleNetworkSuccess;
  FHttp.OnCacheHit        := @HandleCacheHit;
  FHttp.OnError           := @HandleNetworkError;
end;

procedure TStudioController.FreeNetworking;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(851);{$ENDIF}
  FreeAndNil(FHttp);
  FCache := nil;
  FMemCache := nil;
  FDiskCache := nil;
end;

procedure TStudioController.HandleNetworkRequest(Sender: TObject;
  const URL, Method: string; BodySize: Integer);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(852);{$ENDIF}
  if Assigned(FOnNetworkRequest) then
  begin
    FOnNetworkRequest(Sender, URL, Method, BodySize);
    Exit;
  end;
  if FLog = nil then Exit;
  if Method = 'GET' then
    FLog.Write(llDebug, Format('HTTP → GET %s', [ShortenURL(URL)]))
  else
    FLog.Write(llDebug, Format('HTTP → %s %s (body %s)',
      [Method, ShortenURL(URL), FormatBytes(BodySize)]));
end;

procedure TStudioController.HandleNetworkProgress(Sender: TObject;
  const URL, Method: string;
  Received, Total: Int64; ElapsedMs: Int64);
var
  Tail: string;
  KbPerSec: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(853);{$ENDIF}
  if Assigned(FOnNetworkProgress) then
  begin
    FOnNetworkProgress(Sender, URL, Method, Received, Total, ElapsedMs);
    Exit;
  end;
  if FLog = nil then Exit;
  if ElapsedMs > 0 then
    KbPerSec := (Received / 1024.0) / (ElapsedMs / 1000.0)
  else
    KbPerSec := 0;

  if Total > 0 then
    Tail := Format('   …%s / %s (%.0f%%, %.0f KB/s, %d ms)',
      [FormatBytes(Received), FormatBytes(Total),
       (Received / Total) * 100.0, KbPerSec, ElapsedMs])
  else
    Tail := Format('   …%s received (%.0f KB/s, %d ms)',
      [FormatBytes(Received), KbPerSec, ElapsedMs]);

  FLog.Write(llInfo, Tail);
end;

procedure TStudioController.HandleNetworkSuccess(Sender: TObject;
  const URL, Method: string; StatusCode: Integer;
  ResponseSize: Int64; ElapsedMs: Int64);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(854);{$ENDIF}
  if Assigned(FOnNetworkSuccess) then
  begin
    FOnNetworkSuccess(Sender, URL, Method, StatusCode, ResponseSize, ElapsedMs);
    Exit;
  end;
  if FLog = nil then Exit;
  FLog.Write(llInfo, Format('HTTP ← %d %s %s (%s, %d ms)',
    [StatusCode, Method, ShortenURL(URL),
     FormatBytes(ResponseSize), ElapsedMs]));
end;

procedure TStudioController.HandleCacheHit(Sender: TObject;
  const URL: string; SizeBytes: Int64);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(855);{$ENDIF}
  if Assigned(FOnCacheHit) then
  begin
    FOnCacheHit(Sender, URL, SizeBytes);
    Exit;
  end;
  if FLog = nil then Exit;
  FLog.Write(llDebug, Format('cache hit %s (%s)',
    [ShortenURL(URL), FormatBytes(SizeBytes)]));
end;

procedure TStudioController.HandleNetworkError(Sender: TObject;
  const URL, ErrorMsg: string; Attempt: Integer;
  PartialSize: Int64; ElapsedMs: Int64);
var
  Tail: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(856);{$ENDIF}
  if Assigned(FOnNetworkError) then
  begin
    FOnNetworkError(Sender, URL, ErrorMsg, Attempt, PartialSize, ElapsedMs);
    Exit;
  end;
  if FLog = nil then Exit;
  if PartialSize > 0 then
    Tail := Format(' (received %s in %d ms before error)',
      [FormatBytes(PartialSize), ElapsedMs])
  else if ElapsedMs > 0 then
    Tail := Format(' (failed after %d ms)', [ElapsedMs])
  else
    Tail := '';
  FLog.Write(llWarn, Format('HTTP ✗ %s (attempt %d): %s%s',
    [ShortenURL(URL), Attempt, ErrorMsg, Tail]));
end;

end.
