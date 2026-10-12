unit Osm3dReadyTiles;
{$mode objfpc}{$H+}{$codepage UTF8}
{ Public, read-only distribution. Catalogue refresh and updates run separately
  from cached tile loads; unavailable service never invalidates local geometry. }
interface
uses Classes, SysUtils, SyncObjs, Generics.Collections, Osm3dCacheHTTPFetcher,
  Osm3dGeoTileGrid, Osm3dTileX3D;
type
  TReadyTileEntry = record
    Id: TGeoTileId;
    GenHash, SHA256: string;
    SizeBytes: Int64;
  end;
  TReadyTileEntries = array of TReadyTileEntry;
  TReadyTilesStatus = record
    Available, Downloaded, Updated: Integer;
    Checking, Offline: Boolean;
  end;
  TReadyTileInstall = procedure(const Id: TGeoTileId; Model: TTileModel;
    const Revision: string) of object;
  TReadyTileCompatibility = function(const Id: TGeoTileId; const GenHash: string): Boolean of object;
  TReadyTileRequest = record
    Id: TGeoTileId;
    GenHash, Revision: string;
  end;
  TReadyTiles = class;
  TReadyTilesWorker = class(TThread)
  private FOwner: TReadyTiles;
  protected procedure Execute; override;
  public constructor Create(AOwner: TReadyTiles);
  end;
  TReadyTiles = class
  private
    FHttp, FObjectHttp: THTTPFetcherWithCache;
    FBase, FGenerator, FTempDir, FCatalogURL: string;
    FZoom, FEdge: Integer;
    FLock, FRefreshLock, FAcquireLock: TCriticalSection;
    FEntries: specialize TDictionary<Int64,TReadyTileEntry>;
    FFailed: specialize TDictionary<Int64,QWord>;
    FRequests: specialize TDictionary<Int64,TReadyTileRequest>;
    FLastRefresh: QWord;
    FWorker: TReadyTilesWorker;
    FJoined: Boolean;
    FWake: TEvent;
    FStop: Boolean;
    FNetworkEnabled: Boolean;
    FNetworkFailedAt: QWord;
    FStatus: TReadyTilesStatus;
    FInstall: TReadyTileInstall;
    FCompatible: TReadyTileCompatibility;
    function ParseCatalog(const Bytes: TBytes; out Entries: TReadyTileEntries): Boolean;
    procedure SetCatalog(const Entries: TReadyTileEntries);
    function Find(const Id: TGeoTileId; const GenHash: string; out Entry: TReadyTileEntry): Boolean;
    procedure Work;
  public
    constructor Create(Source: THTTPFetcherWithCache; const Generator: string;
      Zoom, Edge: Integer; const TempDir: string; Install: TReadyTileInstall;
      const BaseURL: string = ''; StartWorker: Boolean = True;
      Compatible: TReadyTileCompatibility = nil);
    destructor Destroy; override;
    procedure Stop;
    procedure JoinStopped;
    procedure RefreshCatalog;
    function Available(const Id: TGeoTileId; const GenHash: string): Boolean;
    { Only missing tiles call this from an IO/gen worker. Never a UI call. }
    function Acquire(const Id: TGeoTileId; const GenHash: string;
      out Model: TTileModel; out Revision: string): Boolean;
    { Cached geometry returns immediately after this cheap queue operation. }
    procedure CheckLater(const Id: TGeoTileId; const GenHash, Revision: string);
    function Status: TReadyTilesStatus;
    function Catalog: TReadyTileEntries;
  end;
function ReadyTilesStatus: TReadyTilesStatus;
function ReadyTilesCatalog: TReadyTileEntries;
function ReadyTileAvailable(const Id: TGeoTileId): Boolean;
implementation
uses fpjson, jsonparser, Osm3dTileBinary, Osm3dSHA256, Osm3dCache;
const MaxTileBytes = 128 * 1024 * 1024;
  RefreshMs = 5 * 60 * 1000;
var GlobalLock: TCriticalSection; GlobalStatus: TReadyTilesStatus;
  GlobalEntries: specialize TDictionary<Int64,TReadyTileEntry>;

function ReadyTilesStatus: TReadyTilesStatus;
begin GlobalLock.Enter; try Result:=GlobalStatus finally GlobalLock.Leave end end;
function ReadyTileAvailable(const Id: TGeoTileId): Boolean;
begin GlobalLock.Enter; try Result:=GlobalEntries.ContainsKey(Id.ToKey) finally GlobalLock.Leave end end;
function ReadyTilesCatalog: TReadyTileEntries;
var E:TReadyTileEntry; I:Integer;
begin
  GlobalLock.Enter;
  try
    SetLength(Result,GlobalEntries.Count); I:=0;
    for E in GlobalEntries.Values do begin Result[I]:=E; Inc(I) end;
  finally GlobalLock.Leave end;
end;
function SafeToken(const S: string; MinLen, MaxLen: Integer; HexOnly: Boolean): Boolean;
var C: Char;
begin
  Result:=(Length(S)>=MinLen) and (Length(S)<=MaxLen); if not Result then Exit;
  for C in S do
    if HexOnly then begin if not(C in ['0'..'9','a'..'f']) then Exit(False) end
    else if not(C in ['0'..'9','a'..'z','A'..'Z','-','_']) then Exit(False);
end;
constructor TReadyTilesWorker.Create(AOwner: TReadyTiles);
begin inherited Create(True); FreeOnTerminate:=False; FOwner:=AOwner; Start end;
procedure TReadyTilesWorker.Execute;
begin FOwner.Work end;

constructor TReadyTiles.Create(Source: THTTPFetcherWithCache; const Generator: string;
  Zoom, Edge: Integer; const TempDir: string; Install: TReadyTileInstall;
  const BaseURL: string; StartWorker: Boolean; Compatible: TReadyTileCompatibility);
var R: TFetchResult; Entries: TReadyTileEntries;
begin
  inherited Create;
  FLock:=TCriticalSection.Create; FRefreshLock:=TCriticalSection.Create;
  FAcquireLock:=TCriticalSection.Create;
  FEntries:=specialize TDictionary<Int64,TReadyTileEntry>.Create;
  FFailed:=specialize TDictionary<Int64,QWord>.Create;
  FRequests:=specialize TDictionary<Int64,TReadyTileRequest>.Create;
  FWake:=TEvent.Create(nil,False,False,'');
  FGenerator:=Generator; FZoom:=Zoom; FEdge:=Edge; FInstall:=Install; FCompatible:=Compatible;
  FTempDir:=IncludeTrailingPathDelimiter(TempDir);
  FBase:=BaseURL;
  if FBase='' then FBase:=Trim(GetEnvironmentVariable('REZVIVO_READY_TILES_URL'));
  if FBase='' then FBase:='https://rezvivo.com/api/ready-tiles/v1';
  while (Length(FBase)>0) and (FBase[Length(FBase)]='/') do Delete(FBase,Length(FBase),1);
  if (Source=nil) or not SafeToken(Generator,1,128,False) or
    (GetEnvironmentVariable('REZVIVO_READY_TILES')='0') then Exit;
  { A cache-only readiness audit must not clear the active map's markers. }
  GlobalLock.Enter;
  try GlobalEntries.Clear; GlobalStatus:=Default(TReadyTilesStatus) finally GlobalLock.Leave end;
  FNetworkEnabled:=GetEnvironmentVariable('REZVIVO_OFFLINE')<>'1';
  FHttp:=THTTPFetcherWithCache.Create(Source.Cache,False);
  FHttp.PublicGetTransport:=Source.PublicGetTransport;
  FHttp.TimeoutMs:=2000; FHttp.MaxRetries:=1;
  FHttp.MaxResponseBytes:=MaxTileBytes;
  { Catalogue checks stay short; a large tile may pause on mobile data.
    Separate fetchers keep concurrent timeout settings immutable. }
  FObjectHttp:=THTTPFetcherWithCache.Create(Source.Cache,False);
  FObjectHttp.PublicGetTransport:=Source.PublicGetTransport;
  FObjectHttp.TimeoutMs:=15000; FObjectHttp.MaxRetries:=1;
  FObjectHttp.MaxResponseBytes:=MaxTileBytes;
  FCatalogURL:=FBase+'/catalog?generator='+Generator+'&zoom='+IntToStr(Zoom)+'&edge_px='+IntToStr(Edge);
  R:=FHttp.GetUrlCachedOnly(FCatalogURL);
  if R.Success and ParseCatalog(R.Data,Entries) then SetCatalog(Entries);
  if StartWorker then FWorker:=TReadyTilesWorker.Create(Self);
end;
procedure TReadyTiles.Stop;
begin
  FStop:=True; if FHttp<>nil then FHttp.AbortAllRequests;
  if FObjectHttp<>nil then FObjectHttp.AbortAllRequests;
  if FWake<>nil then FWake.SetEvent;
end;
procedure TReadyTiles.JoinStopped;
begin
  { FPC's Unix WaitFor calls pthread_join even after an earlier WaitFor.
    The map's background reaper and destructor share this one-shot join. }
  if (FWorker=nil) or FJoined then Exit;
  FWorker.WaitFor;
  FJoined:=True;
end;
destructor TReadyTiles.Destroy;
begin
  Stop; JoinStopped; FreeAndNil(FWorker);
  FObjectHttp.Free; FHttp.Free; FWake.Free; FRequests.Free; FFailed.Free; FEntries.Free;
  FAcquireLock.Free; FRefreshLock.Free; FLock.Free; inherited;
end;
function TReadyTiles.ParseCatalog(const Bytes: TBytes; out Entries: TReadyTileEntries): Boolean;
var D: TJSONData; O,E: TJSONObject; A: TJSONArray; S: string; I: Integer;
  X,Y: Int64; Limit: QWord; Keys: TStringList;
begin
  Result:=False; Entries:=nil; D:=nil; Keys:=TStringList.Create;
  Keys.Sorted:=True; Keys.Duplicates:=dupError;
  try
    try
      if (Length(Bytes)=0) or (Length(Bytes)>16*1024*1024) then Exit;
      SetString(S,PAnsiChar(@Bytes[0]),Length(Bytes)); D:=GetJSON(S);
      if not(D is TJSONObject) then Exit; O:=TJSONObject(D);
      if (O.Get('version',0)<>1) or (O.Get('format','')<>'O3DTBIN1') or
        (O.Get('generator','')<>FGenerator) or (O.Get('zoom',-1)<>FZoom) or
        (O.Get('edge_px',0)<>FEdge) then Exit;
      A:=O.Arrays['tiles']; if A.Count>100000 then Exit;
      Limit:=(QWord(256) shl FZoom) div FEdge;
      SetLength(Entries,A.Count);
      for I:=0 to A.Count-1 do begin
        E:=A.Objects[I]; X:=E.Get('tx',Int64(-1)); Y:=E.Get('ty',Int64(-1));
        if (X<0) or (Y<0) or (QWord(X)>=Limit) or (QWord(Y)>=Limit) then Exit;
        Entries[I].Id:=TGeoTileId.Make(0,True,X,Y);
        Entries[I].GenHash:=E.Get('gen_hash','');
        Entries[I].SHA256:=E.Get('sha256',''); Entries[I].SizeBytes:=E.Get('bytes',Int64(0));
        if not SafeToken(Entries[I].GenHash,1,192,False) or
          not SafeToken(Entries[I].SHA256,64,64,True) or
          (Entries[I].SizeBytes<32) or (Entries[I].SizeBytes>MaxTileBytes) then Exit;
        Keys.Add(IntToStr(Entries[I].Id.ToKey));
      end;
      Result:=True;
    except Result:=False end;
  finally D.Free; Keys.Free end;
end;
procedure TReadyTiles.SetCatalog(const Entries: TReadyTileEntries);
var E: TReadyTileEntry;
begin
  FLock.Enter;
  try
    FEntries.Clear;
    for E in Entries do
      if not Assigned(FCompatible) or FCompatible(E.Id,E.GenHash) then
        FEntries.AddOrSetValue(E.Id.ToKey,E);
    FStatus.Available:=FEntries.Count;
    GlobalLock.Enter;
    try
      GlobalEntries.Clear;
      for E in FEntries.Values do GlobalEntries.AddOrSetValue(E.Id.ToKey,E);
      GlobalStatus:=FStatus;
    finally GlobalLock.Leave end;
  finally FLock.Leave end;
end;
procedure TReadyTiles.RefreshCatalog;
var R: TFetchResult; Entries: TReadyTileEntries; Current: QWord;
begin
  if (FHttp=nil) or FStop or not FNetworkEnabled then Exit;
  FRefreshLock.Enter;
  try
    Current:=GetTickCount64;
    if (FLastRefresh<>0) and (Current-FLastRefresh<RefreshMs) then Exit;
    FLastRefresh:=Current;
    FLock.Enter; try FStatus.Checking:=True finally FLock.Leave end;
    try
      { Bypass only this catalogue key, retaining the last valid cached copy
        if HTTP or validation fails. Objects are immutable and never bypass. }
      R:=FHttp.GetUrlWithKey(FCatalogURL,'ready-catalog-fetch:'+FCatalogURL,'',2000,1,True);
      if R.Success and ParseCatalog(R.Data,Entries) then begin
        SetCatalog(Entries);
        if FHttp.Cache<>nil then FHttp.Cache.Put('GET '+FCatalogURL,R.Data,
          TCacheMetadata.Make('application/json'));
        FLock.Enter; try FStatus.Offline:=False finally FLock.Leave end;
      end else begin
        FLock.Enter; try FStatus.Offline:=True finally FLock.Leave end;
      end;
    except
      FLock.Enter; try FStatus.Offline:=True finally FLock.Leave end;
    end;
    FLock.Enter; try FStatus.Checking:=False finally FLock.Leave end;
  finally FRefreshLock.Leave end;
end;
function TReadyTiles.Find(const Id: TGeoTileId; const GenHash: string; out Entry: TReadyTileEntry): Boolean;
var FailedAt: QWord;
begin
  Result:=False; if (FHttp=nil) or FStop then Exit;
  FLock.Enter;
  try
    if FFailed.TryGetValue(Id.ToKey,FailedAt) and (GetTickCount64-FailedAt<RefreshMs) then Exit;
    Result:=FEntries.TryGetValue(Id.ToKey,Entry) and
      ((Entry.GenHash=GenHash) or (Assigned(FCompatible) and FCompatible(Id,Entry.GenHash)));
  finally FLock.Leave end;
end;
function TReadyTiles.Available(const Id: TGeoTileId; const GenHash: string): Boolean;
var E: TReadyTileEntry;
begin Result:=Find(Id,GenHash,E) end;
function TReadyTiles.Acquire(const Id: TGeoTileId; const GenHash: string;
  out Model: TTileModel; out Revision: string): Boolean;
var E: TReadyTileEntry; R: TFetchResult; URL,Temp: string; F: TFileStream; G: TGUID;
begin
  Result:=False; Model:=nil; Revision:=''; if (FHttp=nil) or FStop then Exit;
  { A cached catalogue/object is enough: never join a network refresh before
    using it. Missing catalogue entries may make one bounded worker request. }
  if not Find(Id,GenHash,E) then begin
    RefreshCatalog;
    if not Find(Id,GenHash,E) then Exit;
  end;
  FAcquireLock.Enter;
  try
    Temp:='';
    try
      if FStop then Exit;
      URL:=FBase+'/objects/'+E.SHA256+'.o3dt';
      R:=FObjectHttp.GetUrlCachedOnly(URL);
      if not R.Success then begin
        if not FNetworkEnabled or ((FNetworkFailedAt<>0) and
          (GetTickCount64-FNetworkFailedAt<RefreshMs)) then
          raise Exception.Create('Ready tile network deferred');
        R:=FObjectHttp.GetUrl(URL,5000,1);
        if not R.Success then begin
          FNetworkFailedAt:=GetTickCount64;
          raise Exception.Create('Ready tile unavailable');
        end;
      end;
      if (Length(R.Data)<>E.SizeBytes) or (SHA256Bytes(R.Data)<>E.SHA256) then begin
        FObjectHttp.InvalidateGetUrl(URL); raise Exception.Create('Ready tile checksum mismatch');
      end;
      if not ForceDirectories(FTempDir) then raise Exception.Create('Tile cache is read-only');
      CreateGUID(G); Temp:=FTempDir+GUIDToString(G)+'.download';
      F:=TFileStream.Create(Temp,fmCreate);
      try F.WriteBuffer(R.Data[0],Length(R.Data)) finally F.Free end;
      Model:=TTileBinary.LoadFile(Temp);
      if not Model.TileId.Equals(Id) or (Model.GenHash<>E.GenHash) then
        raise Exception.Create('Ready tile identity incompatible');
      if Length(Model.ModelInstances)>0 then
        raise Exception.Create('Ready tile requires unpublished model dependencies');
      Revision:=E.SHA256; Result:=True;
      FLock.Enter; try Inc(FStatus.Downloaded) finally FLock.Leave end;
    except
      on Err:Exception do begin
        FreeAndNil(Model);
        FLock.Enter; try FFailed.AddOrSetValue(Id.ToKey,GetTickCount64) finally FLock.Leave end;
        GlobalLock.Enter; try GlobalEntries.Remove(Id.ToKey) finally GlobalLock.Leave end;
      end;
    end;
    if Temp<>'' then DeleteFile(Temp);
  finally FAcquireLock.Leave end;
end;
procedure TReadyTiles.CheckLater(const Id: TGeoTileId; const GenHash, Revision: string);
var R: TReadyTileRequest;
begin
  if (FHttp=nil) or FStop then Exit;
  R.Id:=Id; R.GenHash:=GenHash; R.Revision:=Revision;
  FLock.Enter;
  try if FRequests.Count<4096 then FRequests.AddOrSetValue(Id.ToKey,R)
  finally FLock.Leave end;
  FWake.SetEvent;
end;
function TReadyTiles.Status: TReadyTilesStatus;
begin FLock.Enter; try Result:=FStatus finally FLock.Leave end end;
function TReadyTiles.Catalog: TReadyTileEntries;
var E: TReadyTileEntry; I: Integer;
begin
  FLock.Enter;
  try
    SetLength(Result,FEntries.Count); I:=0;
    for E in FEntries.Values do begin Result[I]:=E; Inc(I) end;
  finally FLock.Leave end;
end;
procedure TReadyTiles.Work;
var Requests: array of TReadyTileRequest; R: TReadyTileRequest; E: TReadyTileEntry;
  I: Integer; Model: TTileModel; Revision: string; S: TReadyTilesStatus;
begin
  while not FStop do begin
    try
      RefreshCatalog;
      FLock.Enter;
      try
        SetLength(Requests,FRequests.Count); I:=0;
        for R in FRequests.Values do begin Requests[I]:=R; Inc(I) end;
        FRequests.Clear;
      finally FLock.Leave end;
      for R in Requests do begin
        if FStop then Break;
        if Find(R.Id,R.GenHash,E) and (E.SHA256<>R.Revision) and Assigned(FInstall) and
          Acquire(R.Id,R.GenHash,Model,Revision) then
        try
          if not FStop then begin
            FInstall(R.Id,Model,Revision);
            if R.Revision<>'' then begin FLock.Enter;
              try Inc(FStatus.Updated) finally FLock.Leave end end;
          end;
        finally Model.Free end;
      end;
    except { Optional maintenance must not terminate the application. } end;
    S:=Status; GlobalLock.Enter; try GlobalStatus:=S finally GlobalLock.Leave end;
    if not FStop then FWake.WaitFor(1000);
  end;
end;
initialization
  GlobalLock:=TCriticalSection.Create;
  GlobalEntries:=specialize TDictionary<Int64,TReadyTileEntry>.Create;
finalization GlobalEntries.Free; GlobalLock.Free;
end.
