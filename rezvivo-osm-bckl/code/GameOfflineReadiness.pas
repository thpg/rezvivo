unit GameOfflineReadiness;
{$mode objfpc}{$H+}{$codepage UTF8}{$modeswitch advancedrecords}
interface
uses Classes, SysUtils, SyncObjs, Osm3dStudioSettings, Osm3dMapUtils,
  Osm3dCacheHTTPFetcher;
type
  TOfflineReadiness = record
    Done, Dream, Preparing: Boolean;
    Tiles, ReadyTiles, Osm, ReadyOsm, Heights, ReadyHeights: Integer;
    LocalBytes: Int64;
    ErrorText, FirstMissing: string;
    function Ready: Boolean;
    function Missing: Integer;
    function Caption: string;
  end;
  { Pure disk audit, one snapshot per route selection / preparation completion.
    Never constructs a streaming session, requests HTTP or generates geometry. }
  TOfflineReadinessTask = class(TThread)
  private
    FLock: TCriticalSection;
    FResult: TOfflineReadiness;
    FSettings: TStudioSettings;
    FRoute: TRouteLatLonArray;
    FFitName, FManifest: string;
    FPrepareSources:Boolean;
    FRegistered:Boolean;
    FHttp, FOsmHttp:THTTPFetcherWithCache;
    procedure CheckCancelled;
    procedure CheckRoute;
    procedure CheckDream;
    procedure Publish(const Value: TOfflineReadiness);
    procedure RequestCancel;
  protected
    procedure Execute; override;
  public
    constructor CreateRoute(const Settings: TStudioSettings;
      const Route: TRouteLatLonArray; const FitName: string;
      PrepareSources:Boolean=False);
    constructor CreateDream(const Manifest: string);
    destructor Destroy; override;
    function Snapshot: TOfflineReadiness;
    { Relinquish ownership without waiting for disk I/O on the UI thread. }
    procedure Abandon;
  end;
procedure ShutdownOfflineReadiness;
implementation
uses Math, fpjson, jsonparser, XMLReader, XMLTextReader, XMLUtils,
  UiTranslations, Osm3dGeoMath, Osm3dGeoTileGrid, Osm3dGeoTileCache,
  Osm3dRouteCoverage, Osm3dStreamingLauncher, Osm3dTileBinary, Osm3dTileX3D,
  Osm3dCache, Osm3dOsmOverpass, Osm3dOsmDirectory,
  Osm3dHeightmap, Osm3dOsmData;

var ActiveTasks:TList;TasksLock:TCriticalSection;TasksIdle:TEvent;
procedure RegisterTask(Task:TOfflineReadinessTask);
begin
  TasksLock.Enter;
  try ActiveTasks.Add(Task);Task.FRegistered:=True;TasksIdle.ResetEvent;finally TasksLock.Leave end;
end;
procedure UnregisterTask(Task:TOfflineReadinessTask);
begin
  if not Task.FRegistered then Exit;
  TasksLock.Enter;
  try
    ActiveTasks.Remove(Task);
    Task.FRegistered:=False;
    if ActiveTasks.Count=0 then TasksIdle.SetEvent;
  finally TasksLock.Leave end;
end;
procedure ShutdownOfflineReadiness;
var I:Integer;
begin
  TasksLock.Enter;
  try for I:=0 to ActiveTasks.Count-1 do TOfflineReadinessTask(ActiveTasks[I]).RequestCancel;
  finally TasksLock.Leave end;
  { No queued UI callbacks or Synchronize; workers only release disk/network
    resources. Join while the OSM/cache/SSL units still exist. }
  TasksIdle.WaitFor(INFINITE);
  { UnregisterTask signals inside the lock. Finish its final Leave before
    finalization can release the lock object. }
  TasksLock.Enter;TasksLock.Leave;
end;

function TOfflineReadiness.Missing: Integer;
begin Result:=(Tiles-ReadyTiles)+(Osm-ReadyOsm)+(Heights-ReadyHeights) end;
function TOfflineReadiness.Ready: Boolean;
begin Result:=Done and(ErrorText='')and(Tiles>0)and(Missing=0) end;
function TOfflineReadiness.Caption: string;
var S:string;
begin
  if ErrorText<>''then Exit(UiText('Offline check failed: ')+ErrorText);
  if not Done then
    if Preparing then S:=UiText('Preparing offline route data...')
    else S:=UiText('Checking local route data...')
  else if Ready then
    if Dream then S:=UiText('Dream world available offline')
    else S:=UiText('Route corridor available offline')
  else S:=UiText('Route is not fully prepared offline');
  if Dream then S:=S+Format(UiText(' — files %d/%d'),[ReadyTiles,Tiles])
  else S:=S+Format(UiText(' — 3D %d/%d, OSM %d/%d, heights %d/%d'),
    [ReadyTiles,Tiles,ReadyOsm,Osm,ReadyHeights,Heights]);
  S:=S+Format(UiText('; local data %.1f MiB'),[LocalBytes/(1024.0*1024.0)]);
  if Done and not Ready then S:=S+LineEnding+UiText('Download size is unknown until the server responds.');
  Result:=S;
end;
constructor TOfflineReadinessTask.CreateRoute(const Settings:TStudioSettings;
  const Route:TRouteLatLonArray;const FitName:string;PrepareSources:Boolean);
begin
  inherited Create(True);FLock:=TCriticalSection.Create;
  FSettings:=Settings;FRoute:=Copy(Route);FFitName:=ExtractFileName(FitName);
  FPrepareSources:=PrepareSources;RegisterTask(Self);Start;
end;
constructor TOfflineReadinessTask.CreateDream(const Manifest:string);
begin
  inherited Create(True);FLock:=TCriticalSection.Create;
  FManifest:=ExpandFileName(Manifest);FResult.Dream:=True;RegisterTask(Self);Start;
end;
destructor TOfflineReadinessTask.Destroy;
begin UnregisterTask(Self);FLock.Free;inherited end;
procedure TOfflineReadinessTask.CheckCancelled;
begin if Terminated then raise EAbort.Create('Offline check cancelled') end;
procedure TOfflineReadinessTask.Publish(const Value:TOfflineReadiness);
begin FLock.Enter;try FResult:=Value;finally FLock.Leave end end;
function TOfflineReadinessTask.Snapshot:TOfflineReadiness;
begin FLock.Enter;try Result:=FResult;finally FLock.Leave end end;
procedure TOfflineReadinessTask.Abandon;
var Completed:Boolean;
begin
  FLock.Enter;
  try
    RequestCancel;Completed:=FResult.Done;
    if not Completed then FreeOnTerminate:=True;
  finally FLock.Leave end;
  if Completed then Free;
end;
procedure TOfflineReadinessTask.RequestCancel;
begin
  FLock.Enter;
  try
    Terminate;
    if FHttp<>nil then FHttp.AbortAllRequests;
    if FOsmHttp<>nil then FOsmHttp.AbortAllRequests;
  finally FLock.Leave end;
end;
procedure TOfflineReadinessTask.Execute;
begin
  try
    if FManifest<>''then CheckDream else CheckRoute;
  except
    on E:Exception do begin
      FLock.Enter;try FResult.ErrorText:=E.Message;finally FLock.Leave end;
    end;
  end;
  FLock.Enter;try FResult.Done:=True;finally FLock.Leave end;
  UnregisterTask(Self);
end;

function FileBytes(const Path:string):Int64;
var F:TFileStream;
begin
  Result:=0;
  try F:=TFileStream.Create(Path,fmOpenRead or fmShareDenyNone);
    try Result:=F.Size;finally F.Free end;
  except end;
end;

procedure TOfflineReadinessTask.CheckRoute;
var C:TGeoTileCache;D:TFileSystemCache;H:THTTPFetcherWithCache;Dem:TTerrariumFetcher;
    OsmHttp:THTTPFetcherWithCache;Overpass:TOverpassClient;Dataset:TOSMDataset;
    Tiles:TGeoTileIdArray;OsmTiles,HeightTiles:TStringList;A:TTileXYArray;
    T:TTileXY;B:TLatLonBox;P:TLatLon;I,J:Integer;Path,Other,Key,Hash,Query:string;
    Model:TTileModel;Data:TBytes;Meta:TCacheMetadata;Json:TJSONData;
    Height:Single;HeightMap:THeightmap;S:TOfflineReadiness;Good:Boolean;Candidates:TStringArray;
  procedure AddSlippy(List:TStringList;Zoom:Integer;const Box:TLatLonBox);
  var K:Integer;Id:string;
  begin
    A:=TTileMath.TilesCoveringBox(Box,Zoom);
    for K:=0 to High(A)do begin
      Id:=IntToStr(A[K].X)+'/'+IntToStr(A[K].Y);List.Add(Id);
    end;
  end;
  function Slippy(const Id:string;Zoom:Integer):TTileXY;
  var Slash:Integer;
  begin Slash:=Pos('/',Id);Result:=TTileXY.Make(StrToInt(Copy(Id,1,Slash-1)),StrToInt(Copy(Id,Slash+1,MaxInt)),Zoom) end;
begin
  if Length(FRoute)<2 then raise Exception.Create('No route points');
  S:=Default(TOfflineReadiness);
  S.Preparing:=FPrepareSources;
  Hash:=ComputeGenHash(FSettings,GEO_TILE_EDGE_M,'',FSettings.GenerateRouteOnly,FFitName,FSettings.RouteOnlyRadiusM);
  C:=TGeoTileCache.Create(TOsm3dStreamingSession.EffectiveCacheRoot(FSettings),Hash,FSettings.HeightmapZoom,0,FRoute[0].Lat);
  D:=nil;H:=nil;Dem:=nil;OsmTiles:=nil;HeightTiles:=nil;Overpass:=nil;OsmHttp:=nil;
  try
    D:=TFileSystemCache.Create(TOsm3dStreamingSession.EffectiveCacheRoot(FSettings));
    H:=THTTPFetcherWithCache.Create(D,False);
    OsmHttp:=THTTPFetcherWithCache.Create(D,False);
    FLock.Enter;
    try
      FHttp:=H;FOsmHttp:=OsmHttp;
      if Terminated then begin H.AbortAllRequests;OsmHttp.AbortAllRequests end;
    finally FLock.Leave end;
    if FPrepareSources then begin
      Overpass:=TOverpassClient.Create(OsmHttp,FSettings.OverpassEndpoints,1);
      Overpass.TimeoutS:=FSettings.OverpassTimeoutS;
      Overpass.TileZoom:=FSettings.OverpassTileZoom;
    end;
    Dem:=TTerrariumFetcher.Create(H,FSettings.TerrariumUrlTemplate,4);
    OsmTiles:=TStringList.Create;OsmTiles.Sorted:=True;OsmTiles.Duplicates:=dupIgnore;
    HeightTiles:=TStringList.Create;HeightTiles.Sorted:=True;HeightTiles.Duplicates:=dupIgnore;
    Tiles:=RouteCoverageTiles(C.Grid,FRoute,ROUTE_SNAP_MARGIN_M,Self);
    S.Tiles:=Length(Tiles);Publish(S);
    for I:=0 to High(Tiles)do begin
      CheckCancelled;
      B:=C.Grid.TileBox(Tiles[I]);
      AddSlippy(OsmTiles,FSettings.OverpassTileZoom,B);
      AddSlippy(HeightTiles,FSettings.HeightmapZoom,B.ExpandMeters(2));
      Path:=C.PathFor(Tiles[I]);
      if SameText(ExtractFileExt(Path),'.o3dt')then Other:=ChangeFileExt(Path,'.x3d')
      else Other:=ChangeFileExt(Path,'.o3dt');
      Good:=False;
      for J:=0 to 1 do begin
        if J=1 then Path:=Other;
        if not FileExists(Path)then Continue;
        Model:=nil;
        try
          if SameText(ExtractFileExt(Path),'.o3dt')then Model:=TTileBinary.ValidateFile(Path,Self)
          else Model:=TTileX3D.LoadFile(Path);
          Good:=(Model.GenHash=Hash)and Model.TileId.Equals(Tiles[I]);
        except
          on E:EAbort do raise;
          on E:Exception do Good:=False;
        end;
        Model.Free;
        if Good then begin Inc(S.ReadyTiles);Inc(S.LocalBytes,FileBytes(Path));Break end;
      end;
      if not Good and(S.FirstMissing='')then S.FirstMissing:=C.PathFor(Tiles[I]);
      Publish(S);
    end;
    S.Osm:=OsmTiles.Count;S.Heights:=HeightTiles.Count;Publish(S);
    for I:=0 to OsmTiles.Count-1 do begin
      CheckCancelled;T:=Slippy(OsmTiles[I],FSettings.OverpassTileZoom);
      Query:=TOverpassQueryExt.BuildCombinedFull(TTileMath.TileToLatLonBox(T),DefaultFlagsForFullScene,FSettings.OverpassTimeoutS);
      Key:=OverpassCacheKey(Query);Good:=False;
      if D.Get(Key,Data,Meta)and(Length(Data)>0)then begin
        Json:=nil;
        try
          SetString(Query,PAnsiChar(@Data[0]),Length(Data));Json:=GetJSON(Query);
          Good:=(Json is TJSONObject)and(TJSONObject(Json).Find('elements')is TJSONArray)
            and(TJSONObject(Json).Find('remark')=nil);
        except Good:=False end;
        Json.Free;
      end;
      if not Good and FPrepareSources then begin
        D.Delete(Key);CheckCancelled;
        Dataset:=TOSMDataset.Create;
        try Good:=Overpass.FetchTileInto(T,Dataset);finally Dataset.Free end;
        CheckCancelled;
        if Good then Good:=D.Get(Key,Data,Meta);
      end;
      if Good then begin Inc(S.ReadyOsm);Inc(S.LocalBytes,Length(Data))end
      else if S.FirstMissing=''then S.FirstMissing:='OSM '+OsmTiles[I];
      Data:=nil;Publish(S);
    end;
    for I:=0 to HeightTiles.Count-1 do begin
      CheckCancelled;T:=Slippy(HeightTiles[I],FSettings.HeightmapZoom);
      B:=TTileMath.TileToLatLonBox(T);P:=TLatLon.Make((B.MinLat+B.MaxLat)*0.5,(B.MinLon+B.MaxLon)*0.5);
      { Uses the same preferred provider and PNG decoder as generation, with
        AllowRefresh=False and cache-only access. No HTTP even on a miss. }
      HeightMap:=Dem.GetRegionCachedOnly(TLatLonBox.Empty.Include(P).ExpandMeters(1),FSettings.HeightmapZoom);
      Good:=HeightMap<>nil;HeightMap.Free;
      if not Good and FPrepareSources then begin
        CheckCancelled;Good:=Dem.TryHeightAtZoom(P,FSettings.HeightmapZoom,Height);CheckCancelled;
        { A network fallback may be usable now but unavailable through the
          preferred provider on a later offline start. Advertise only what the
          same cache-only path above can actually reopen. }
        if Good then begin
          HeightMap:=Dem.GetRegionCachedOnly(TLatLonBox.Empty.Include(P).ExpandMeters(1),FSettings.HeightmapZoom);
          Good:=HeightMap<>nil;HeightMap.Free;
        end;
      end;
      if Good then begin
        Inc(S.ReadyHeights);
        if(FSettings.TerrariumUrlTemplate='')or SameText(FSettings.TerrariumUrlTemplate,OSM_DIRECTORY_MODE)then
          Candidates:=HeightServerCandidates(B.MinLat,B.MinLon,B.MaxLat,B.MaxLon,False)
        else begin SetLength(Candidates,1);Candidates[0]:=FSettings.TerrariumUrlTemplate end;
        if(Length(Candidates)>0)and D.GetMetadata('GET '+TTileMath.FormatTileUrl(Candidates[0],T),Meta)then
          Inc(S.LocalBytes,Meta.SizeBytes);
      end
      else if S.FirstMissing=''then S.FirstMissing:='DEM '+HeightTiles[I];
      Publish(S);
    end;
  finally
    FLock.Enter;try FHttp:=nil;FOsmHttp:=nil;finally FLock.Leave end;
    Overpass.Free;OsmHttp.Free;Dem.Free;H.Free;D.Free;OsmTiles.Free;HeightTiles.Free;C.Free;
  end;
end;

procedure TOfflineReadinessTask.CheckDream;
var Root,Path,Rel,Ext:string;Json:TJSONData;Manifest:TJSONObject;Files:TStringList;
    F:TFileStream;R:TXMLTextReader;XmlOptions:TXMLReaderSettings;A:TJSONArray;I,J,N:Integer;S:TOfflineReadiness;
    Header:array[0..4]of LongWord;Text:RawByteString;Chunk:TJSONData;Obj:TJSONObject;
  procedure AddResource(const Base,Name:string);
  var Full:string;
  begin
    if Copy(Name,1,5)='data:'then Exit;
    if(Name='')or(Pos(':',Name)>0)or(Name[1]in['/','\'])then raise Exception.Create('Invalid world resource path');
    Full:=ExpandFileName(Base+Name);
    if not SameText(Copy(Full,1,Length(Root)),Root)then raise Exception.Create('World resource leaves its directory');
    if Files.IndexOf(Full)<0 then Files.Add(Full);
  end;
  procedure AddUrls(const Base,Value:string);
  var L:TStringList;K:Integer;
  begin
    L:=TStringList.Create;
    try L.Delimiter:=' ';L.StrictDelimiter:=True;L.DelimitedText:=Value;
      for K:=0 to L.Count-1 do if L[K]<>''then AddResource(Base,L[K]);
    finally L.Free end;
  end;
begin
  S:=Default(TOfflineReadiness);S.Dream:=True;
  Root:=IncludeTrailingPathDelimiter(ExtractFilePath(FManifest));
  Json:=nil;Files:=TStringList.Create;
  try
    F:=TFileStream.Create(FManifest,fmOpenRead or fmShareDenyWrite);
    try
      if F.Size>4*1024*1024 then raise Exception.Create('World manifest is too large');
      Json:=GetJSON(F);S.LocalBytes:=F.Size;
    finally F.Free end;
    if not(Json is TJSONObject)then raise Exception.Create('Invalid world manifest');
    Manifest:=TJSONObject(Json);
    if(Manifest.Get('format','')<>'rezvivo-dream-world')or(Manifest.Get('version',0)<>1)or
      (Manifest.Get('coordinates','')<>'local-metres-y-up')then raise Exception.Create('Unsupported Dream world');
    A:=Manifest.Get('tiles',TJSONArray(nil));
    if(A=nil)or(A.Count=0)then raise Exception.Create('World has no tiles');
    for I:=0 to A.Count-1 do begin
      if not(A[I]is TJSONObject)then raise Exception.Create('Invalid world tile');
      AddResource(Root,TJSONObject(A[I]).Get('file',''));
    end;
    A:=Manifest.Get('resources',TJSONArray(nil));
    if A<>nil then for I:=0 to A.Count-1 do AddResource(Root,A[I].AsString);
    I:=0;
    while I<Files.Count do begin
      CheckCancelled;Path:=Files[I];Inc(I);S.Tiles:=Files.Count;
      N:=FileBytes(Path);
      if N<=0 then begin if S.FirstMissing=''then S.FirstMissing:=Path;Publish(S);Continue end;
      Ext:=LowerCase(ExtractFileExt(Path));
      F:=TFileStream.Create(Path,fmOpenRead or fmShareDenyWrite);
      try
        if Ext='.x3d'then begin
          XmlOptions:=TXMLReaderSettings.Create;
          XmlOptions.DisallowDoctype:=True;
          XmlOptions.IgnoreComments:=True;
          R:=nil;
          try
            R:=TXMLTextReader.Create(F,'',XmlOptions);
            while R.Read do begin
              CheckCancelled;
              if R.NodeType=ntElement then
                if R.Name='O3DModel'then AddResource(ExtractFilePath(Path),UTF8Encode(R.GetAttribute('file')))
                else if(R.Name='ImageTexture')or(R.Name='Inline')then AddUrls(ExtractFilePath(Path),UTF8Encode(R.GetAttribute('url')));
            end;
          finally R.Free;XmlOptions.Free end;
        end else if Ext='.glb'then begin
          F.ReadBuffer(Header,SizeOf(Header));
          if(Header[0]<>$46546C67)or(Header[1]<>2)or(Header[2]<>F.Size)or
            (Header[4]<>$4E4F534A)or(Header[3]>32*1024*1024)or(Header[3]>F.Size-20)then
            raise Exception.Create('Invalid GLB resource: '+ExtractFileName(Path));
          SetLength(Text,Header[3]);if Length(Text)>0 then F.ReadBuffer(Text[1],Length(Text));
          Chunk:=GetJSON(Text);
          try
            if not(Chunk is TJSONObject)then raise Exception.Create('Invalid GLB JSON');
            Obj:=TJSONObject(Chunk);
            for J:=0 to 1 do begin
              if J=0 then A:=Obj.Get('buffers',TJSONArray(nil))else A:=Obj.Get('images',TJSONArray(nil));
              if A<>nil then for N:=0 to A.Count-1 do begin
                Rel:=TJSONObject(A[N]).Get('uri','');
                if Rel<>''then AddResource(ExtractFilePath(Path),Rel);
              end;
            end;
          finally Chunk.Free end;
        end;
        Inc(S.LocalBytes,F.Size);Inc(S.ReadyTiles);
      finally F.Free end;
      S.Tiles:=Files.Count;Publish(S);
    end;
  finally Files.Free;Json.Free end;
end;
initialization
  TasksLock:=TCriticalSection.Create;
  TasksIdle:=TEvent.Create(nil,True,True,'');
  ActiveTasks:=TList.Create;
finalization
  ShutdownOfflineReadiness;
  ActiveTasks.Free;TasksIdle.Free;TasksLock.Free;
end.
