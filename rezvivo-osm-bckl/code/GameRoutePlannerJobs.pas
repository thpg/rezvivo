unit GameRoutePlannerJobs;
{$mode objfpc}{$H+}{$codepage UTF8}
interface
uses Classes, SysUtils, SyncObjs, Osm3dGeoMath, Osm3dCacheHTTPFetcher,
  GameRoutePlanner;
type
  TPlannerTask = class(TThread)
  private
    FLock:TCriticalSection;
    FDone,FDetached,FLoad, FLoop:Boolean;
    FFetcher:THTTPFetcherWithCache;
    FGraph,FResultGraph:TPlannerGraph;
    FBox:TLatLonBox;
    FStops:TPlannerPoints;
    FEndpoints,FProgress:string;
    procedure LoadRoads;
    procedure SetProgress(const S:string);
  protected
    procedure Execute;override;
  public
    Revision:Integer;
    ErrorText:string;
    Points:TPlannerPoints;
    constructor CreateLoad(const Box:TLatLonBox; const CacheRoot,Endpoints:string);
    constructor CreateRoute(Graph:TPlannerGraph; const Stops:TPlannerPoints; Loop:Boolean; ARevision:Integer);
    destructor Destroy;override;
    function Done:Boolean;
    function Progress:string;
    function TakeGraph:TPlannerGraph;
  end;
procedure DetachPlannerTask(var Task:TPlannerTask);
implementation
uses UiTranslations, Math, fpjson, jsonparser, Osm3dCache, Osm3dOsmData, Osm3dOsmOverpass;
constructor TPlannerTask.CreateLoad(const Box:TLatLonBox; const CacheRoot,Endpoints:string);
begin
  inherited Create(True); FLock:=TCriticalSection.Create; FLoad:=True; FBox:=Box;
  FEndpoints:=Endpoints; FFetcher:=THTTPFetcherWithCache.Create(TFileSystemCache.Create(CacheRoot),True);
  { This fetcher counts attempts, including the first one. }
  FFetcher.MaxRetries:=1; FFetcher.TimeoutMs:=12000;
end;
constructor TPlannerTask.CreateRoute(Graph:TPlannerGraph; const Stops:TPlannerPoints; Loop:Boolean; ARevision:Integer);
begin
  inherited Create(True); FLock:=TCriticalSection.Create; FGraph:=Graph; FGraph.AddRef;
  FStops:=Copy(Stops); FLoop:=Loop; Revision:=ARevision;
end;
destructor TPlannerTask.Destroy;
begin
  { Only completed tasks are freed by UI. Detached tasks free themselves after
    Execute; no Synchronize, UI callback, or network wait is involved. }
  inherited;
  if FGraph<>nil then FGraph.Release; if FResultGraph<>nil then FResultGraph.Release;
  FFetcher.Free; FLock.Free;
end;
procedure DetachPlannerTask(var Task:TPlannerTask);
var Complete:Boolean; T:TPlannerTask;
begin
  T:=Task; Task:=nil; if T=nil then Exit;
  T.FLock.Enter;
  try
    T.Terminate; if T.FFetcher<>nil then T.FFetcher.AbortAllRequests;
    Complete:=T.FDone; if not Complete then T.FDetached:=True;
  finally T.FLock.Leave; end;
  if Complete then T.Free;
end;
function TPlannerTask.Done:Boolean;
begin FLock.Enter; try Result:=FDone; finally FLock.Leave; end; end;
function TPlannerTask.Progress:string;
begin FLock.Enter; try Result:=FProgress; finally FLock.Leave; end; end;
procedure TPlannerTask.SetProgress(const S:string);
begin FLock.Enter; try FProgress:=S; finally FLock.Leave; end; end;
function TPlannerTask.TakeGraph:TPlannerGraph;
begin Result:=FResultGraph; FResultGraph:=nil; end;
procedure TPlannerTask.Execute;
begin
  try
    if not Terminated then
      if FLoad then LoadRoads
      else FGraph.Route(FStops,FLoop,Points,ErrorText,Self);
  except on E:Exception do ErrorText:=E.Message; end;
  FLock.Enter;
  try FDone:=True; if FDetached then FreeOnTerminate:=True;
  finally FLock.Leave; end;
end;
procedure TPlannerTask.LoadRoads;
const ZOOM=13;
var Tiles:TTileXYArray; First,Last:TTileXY; TileBox,LoadedBox:TLatLonBox;
    I,J:Integer; Query,FullQuery,Err,Used,Key:string; Bytes:TBytes; Elapsed:Int64;
    Data:TOSMDataset; Endpoints:TStringList; OK:Boolean;RoadFlags:TOverpassQueryFlags;
  function ValidJSON(const B:TBytes):Boolean;
  var S:RawByteString; D:TJSONData;
  begin
    Result:=False; if Length(B)=0 then Exit; SetLength(S,Length(B)); Move(B[0],S[1],Length(B));
    D:=nil;
    try
      D:=GetJSON(S);
      Result:=(D is TJSONObject) and (TJSONObject(D).Find('elements') is TJSONArray) and
        (TJSONObject(D).Get('remark','')='');
      if not Result then begin
        Err:=UiText('The server returned incomplete OSM data');
        if D is TJSONObject then Err:=Err+': '+TJSONObject(D).Get('remark',TJSONObject(D).Get('error',''));
      end;
    except on E:Exception do begin Result:=False;Err:=UiText('Invalid OSM response: ')+E.Message;end;end;
    D.Free;
  end;
begin
  if FBox.IsEmpty or (FBox.Width>180) then raise Exception.Create(UiText('Select a map area closer to the route'));
  First:=TTileMath.LatLonToTile(TLatLon.Make(FBox.MaxLat,FBox.MinLon),ZOOM);
  Last:=TTileMath.LatLonToTile(TLatLon.Make(FBox.MinLat,FBox.MaxLon),ZOOM);
  if Int64(Abs(Last.X-First.X)+1)*(Abs(Last.Y-First.Y)+1)>256 then
    raise Exception.Create(UiText('The area is too large. Zoom in to load roads'));
  Tiles:=TTileMath.TilesCoveringBox(FBox,ZOOM); LoadedBox:=TLatLonBox.Empty;
  Data:=TOSMDataset.Create; Endpoints:=TStringList.Create;
  RoadFlags:=Default(TOverpassQueryFlags);RoadFlags.IncludeHighways:=True;
  try
    Endpoints.Delimiter:=';'; Endpoints.StrictDelimiter:=True;
    Endpoints.DelimitedText:=FEndpoints;
    if Endpoints.Count=0 then Endpoints.DelimitedText:=OVERPASS_ENDPOINTS_DEFAULT;
    for I:=0 to High(Tiles) do begin
      if Terminated then Exit;
      SetProgress(Format(UiText('Loading roads: %d / %d'),[I+1,Length(Tiles)]));
      TileBox:=TTileMath.TileToLatLonBox(Tiles[I]);
      LoadedBox:=LoadedBox.Union(TileBox);
      { Reuse the game's full OSM cache where present; uncached regions only
        request roads and their nodes, without buildings, terrain or trees. }
      FullQuery:=TOverpassQueryExt.BuildCombinedFull(TileBox,DefaultFlagsForFullScene,OVERPASS_TIMEOUT_DEFAULT);
      OK:=FFetcher.Cache.Get(OverpassCacheKey(FullQuery),Bytes) and ValidJSON(Bytes);
      Query:=TOverpassQueryExt.BuildCombinedFull(TileBox,RoadFlags,25);
      Key:=OverpassCacheKey(Query);
      if not OK then begin
        OK:=FFetcher.Cache.Get(Key,Bytes) and ValidJSON(Bytes);
        if not OK then begin
          Err:='';
          for J:=0 to Endpoints.Count-1 do begin
            if Terminated then Exit;
            Used:=Trim(Endpoints[J]); if Used='' then Continue;
            OK:=OverpassFetchOnEndpoint(FFetcher,Used,Query,Bytes,Elapsed,Err) and ValidJSON(Bytes);
            if OK then Break;
            FFetcher.Cache.Delete(Key);
          end;
        end;
      end;
      if not OK then raise Exception.Create(UiText('Could not load roads: ')+Err);
      TOSMJsonReader.ParseBytes(Bytes,Data);
    end;
    if Terminated then Exit;
    SetProgress(UiText('Preparing the road network…'));
    FResultGraph:=TPlannerGraph.Create(Data,LoadedBox,Self);
  finally Endpoints.Free; Data.Free; end;
end;
end.
