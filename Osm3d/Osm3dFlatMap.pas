unit Osm3dFlatMap;
{$mode objfpc}{$H+}{$codepage UTF8}{$Q-}{$R-}

{ Shared CPU map renderer. Called by workers only; never touches OpenGL.
  Overview is immutable server imagery. Details reuse the game's raw OSM
  cache and are rasterised locally. DEM shading is optional, never a flat-map
  prerequisite. All coordinates remain tile-local doubles. }
interface
uses Classes, SysUtils, SyncObjs, CastleImages, Osm3dCacheHTTPFetcher;
type
  TFlatMapWorkerStats=record
    Limit,Active,Peak,Sources,LoadingSources,PinnedSources,OsmRequests,OsmRequestsPeak:Integer;
    Builds,SourceLoads,SourceWaits:QWord;
  end;
  TFlatMapTask=class(TThread)
  private
    FHttp:THTTPFetcherWithCache;FLock:TCriticalSection;
    FImage:TCastleImage;FDone,FDetail,FRequestedDetail,FCachedOnly,FCancelled,FImagePartial,FFinalTaken:Boolean;FZ,FX,FY:Integer;
    procedure Publish(Img:TCastleImage;Partial:Boolean=False);
  protected
    procedure Execute;override;
  public
    constructor Create(Z,X,Y:Integer;const CacheRoot:string;Detail:Boolean=False;CachedOnly:Boolean=False);
    destructor Destroy;override;
    procedure Cancel;
    function Done:Boolean;
    function TakeImage:TCastleImage;overload;
    function TakeImage(out Partial:Boolean):TCastleImage;overload;
    property Detailed:Boolean read FDetail;
    property CachedOnly:Boolean read FCachedOnly;
    property RequestedDetail:Boolean read FRequestedDetail;
    property Cancelled:Boolean read FCancelled;
    property FinalTaken:Boolean read FFinalTaken;
  end;
const
  FLAT_MAP_URL = 'rezvivo-map://{z}/{x}/{y}';
  FLAT_MAP_DETAIL_ZOOM = 11;
  FLAT_MAP_STREET_ZOOM = 13;
  FLAT_MAP_WORLD_ZOOM = 10;
  FLAT_MAP_TERRAIN_ZOOM = 7;
  FLAT_MAP_VERSION = 'flat-ne1-osm-dem-6';
  FLAT_MAP_COARSE_VERSION = 'flat-full-osm-coarse-1';
function FlatMapTile(Http: THTTPFetcherWithCache; Z,X,Y: Integer;
  Detailed: Boolean; Cancel: TThread = nil): TCastleImage;
function FlatMapTileInfo(Http:THTTPFetcherWithCache;Z,X,Y:Integer;
  Detailed,CachedOnly:Boolean;out ActualDetail:Boolean;Cancel:TThread=nil):TCastleImage;
function FlatMapCancelled(Http: THTTPFetcherWithCache; Cancel: TThread): Boolean;
function FlatMapShade(Dx,Dy: Double): Double;
procedure FlatMapApplyTerrain(Base,Terrain:TCastleImage);
function FlatMapWorkerLimit:Integer;
function FlatMapWorkerStats:TFlatMapWorkerStats;

implementation
uses Math, Types, Generics.Collections, FPImage, FPReadPNG, FPWritePNG,
  Osm3dCache, Osm3dGeoMath, Osm3dOsmData, Osm3dOsmOverpass,
  Osm3dOsmDirectory, Osm3dGeomUtils, Osm3dHeightmap, Osm3dCoastline,
  Osm3dOsmTagUtils, CastleVectors, fpjson, jsonparser
  {$ifdef MSWINDOWS}, Windows{$endif};
const SIDE=512;
type
  TThreadAccess=class(TThread);
  TPixelPoint=record X,Y:Double;end;
  TPixelRing=array of TPixelPoint;
  TPixelRings=array of TPixelRing;
  TSource=class
    Key:string; Data:TOSMDataset; Used:QWord;
    Users:Integer; Loading,LoadCancelled:Boolean; RetryAt:QWord;
    Ready:TEvent;
    constructor Create;
    destructor Destroy;override;
  end;
  TRaster=class
    Pixels:array of LongWord; Z,TX,TY:Integer; Data:TOSMDataset;
    ClipX0,ClipY0,ClipX1,ClipY1:Integer;
    LabelUsed:array[0..31,0..31]of Boolean;
    constructor Create(AZ,AX,AY:Integer);
    function Point(const P:TLatLon):TPixelPoint;
    procedure Fill(const Rings:TPixelRings; Color:LongWord);
    procedure Line(A,B:TPixelPoint; Width:Double; Color:LongWord);
    function WayRing(W:TOSMWay):TPixelRing;
    procedure Features(D:TOSMDataset; Pass:Integer; Cancel:TThread);
    procedure Labels(D:TOSMDataset);
    function Image:TCastleImage;
  end;
var Sources:Classes.TList;SourceLock:SyncObjs.TCriticalSection;
    WorkerLimit,ActiveBuilds,PeakBuilds:Integer;
    BuildCount,SourceLoadCount,SourceWaitCount:QWord;

constructor TSource.Create;
begin inherited;Ready:=TEvent.Create(nil,True,False,'');end;

destructor TSource.Destroy;
begin Data.Free;Ready.Free;inherited;end;

function FlatMapWorkerLimit:Integer;
begin Result:=WorkerLimit;end;

function FlatMapWorkerStats:TFlatMapWorkerStats;
var I:Integer;E:TSource;Requests:TOsmRequestStats;
begin
  Result:=Default(TFlatMapWorkerStats);
  SourceLock.Enter;
  try
    Result.Limit:=WorkerLimit;Result.Active:=ActiveBuilds;Result.Peak:=PeakBuilds;
    Result.Builds:=BuildCount;Result.SourceLoads:=SourceLoadCount;Result.SourceWaits:=SourceWaitCount;
    Result.Sources:=Sources.Count;
    for I:=0 to Sources.Count-1 do begin E:=TSource(Sources[I]);
      if E.Loading then Inc(Result.LoadingSources);
      if E.Users>0 then Inc(Result.PinnedSources);
    end;
  finally SourceLock.Leave;end;
  Requests:=OsmRequestStats;Result.OsmRequests:=Requests.Active;Result.OsmRequestsPeak:=Requests.Peak;
end;

function BeginBuild(Http:THTTPFetcherWithCache;Cancel:TThread):Boolean;
begin
  Result:=False;
  while not FlatMapCancelled(Http,Cancel)do begin
    SourceLock.Enter;
    try
      if ActiveBuilds<WorkerLimit then begin
        Inc(ActiveBuilds);Inc(BuildCount);PeakBuilds:=Math.Max(PeakBuilds,ActiveBuilds);Exit(True);
      end;
    finally SourceLock.Leave;end;
    Sleep(10);
  end;
end;

procedure EndBuild;
begin SourceLock.Enter;try Dec(ActiveBuilds);finally SourceLock.Leave;end;end;

constructor TFlatMapTask.Create(Z,X,Y:Integer;const CacheRoot:string;Detail,CachedOnly:Boolean);
begin
  inherited Create(True);FreeOnTerminate:=False;FZ:=Z;FX:=X;FY:=Y;FRequestedDetail:=Detail;FCachedOnly:=CachedOnly;
  FLock:=SyncObjs.TCriticalSection.Create;FHttp:=THTTPFetcherWithCache.Create(TFileSystemCache.Create(CacheRoot),True);
  FHttp.TimeoutMs:=5000;FHttp.MaxRetries:=1;
end;
destructor TFlatMapTask.Destroy;
begin Cancel;WaitFor;FImage.Free;FHttp.Free;FLock.Free;inherited;end;
procedure TFlatMapTask.Cancel;
begin if FCancelled then Exit;FCancelled:=True;Terminate;FHttp.AbortAllRequests;end;
function TFlatMapTask.Done:Boolean;
begin FLock.Enter;try Result:=FDone;finally FLock.Leave;end;end;
function TFlatMapTask.TakeImage:TCastleImage;
var Partial:Boolean;
begin Result:=TakeImage(Partial);end;
function TFlatMapTask.TakeImage(out Partial:Boolean):TCastleImage;
begin
  FLock.Enter;try Result:=FImage;Partial:=FImagePartial;FImage:=nil;
    if(Result<>nil)and not Partial then FFinalTaken:=True;
  finally FLock.Leave;end;
end;
procedure TFlatMapTask.Publish(Img:TCastleImage;Partial:Boolean);
begin
  if Img=nil then Exit;
  if Terminated then begin Img.Free;Exit;end;
  FLock.Enter;try FImage.Free;FImage:=Img;FImagePartial:=Partial;finally FLock.Leave;end;
end;
procedure TFlatMapTask.Execute;
var Img:TCastleImage;
begin
  try
    try
      Img:=FlatMapTileInfo(FHttp,FZ,FX,FY,FRequestedDetail,FCachedOnly,FDetail,Self);
      Publish(Img,FRequestedDetail and not FDetail);
    except { Keep the last valid overview if an optional detail source fails. } end;
  finally FLock.Enter;try FDone:=True;finally FLock.Leave;end;end;
end;

function FlatMapCancelled(Http:THTTPFetcherWithCache;Cancel:TThread):Boolean;
begin Result:=(Http=nil) or Http.Aborted or ((Cancel<>nil) and TThreadAccess(Cancel).Terminated);end;

function Decode(const Bytes:TBytes):TFPMemoryImage;
var S:TMemoryStream; R:TFPReaderPNG;
begin
  Result:=nil;if (Length(Bytes)<24)or(Length(Bytes)>8*1024*1024)then Exit;
  if (Bytes[0]<>137)or(Bytes[1]<>80)or(Bytes[2]<>78)or(Bytes[3]<>71)then Exit;
  { Check dimensions before invoking the decoder, including cache contents. }
  if (Bytes[16]<>0)or(Bytes[17]<>0)or(Bytes[18]<>1)or(Bytes[19]<>0)or
     (Bytes[20]<>0)or(Bytes[21]<>0)or(Bytes[22]<>1)or(Bytes[23]<>0)then Exit;
  S:=TMemoryStream.Create;R:=TFPReaderPNG.Create;
  try
    S.WriteBuffer(Bytes[0],Length(Bytes));S.Position:=0;Result:=TFPMemoryImage.Create(0,0);
    try Result.LoadFromStream(S,R);except FreeAndNil(Result);end;
  finally R.Free;S.Free;end;
end;

function CastleFromFP(Src:TFPMemoryImage):TCastleImage;
var X,Y:Integer;C:TFPColor;P:PVector3Byte;
begin
  Result:=TRGBImage.Create(256,256);
  for Y:=0 to 255 do for X:=0 to 255 do begin
    C:=Src.Colors[X,Y];P:=PVector3Byte(Result.PixelPtr(X,255-Y));
    P^.X:=C.Red shr 8;P^.Y:=C.Green shr 8;P^.Z:=C.Blue shr 8;
  end;
end;

function ReadImage(Http:THTTPFetcherWithCache;const Key:string):TCastleImage;
var B:TBytes;Img:TFPMemoryImage;
begin
  Result:=nil;if not Http.Cache.Get(Key,B)then Exit;Img:=Decode(B);
  if Img=nil then begin Http.Cache.Delete(Key);Exit;end;
  try Result:=CastleFromFP(Img);finally Img.Free;end;
end;

procedure SaveImage(Http:THTTPFetcherWithCache;const Key:string;Img:TCastleImage);
var F:TFPMemoryImage;W:TFPWriterPNG;S:TMemoryStream;B:TBytes;X,Y:Integer;P:PVector3Byte;C:TFPColor;
begin
  F:=TFPMemoryImage.Create(256,256);W:=TFPWriterPNG.Create;S:=TMemoryStream.Create;
  try
    for Y:=0 to 255 do for X:=0 to 255 do begin
      P:=PVector3Byte(Img.PixelPtr(X,255-Y));C.Red:=P^.X*257;C.Green:=P^.Y*257;C.Blue:=P^.Z*257;C.Alpha:=65535;F.Colors[X,Y]:=C;
    end;
    W.UseAlpha:=False;W.WordSized:=False;F.SaveToStream(S,W);SetLength(B,S.Size);
    if S.Size>0 then Move(S.Memory^,B[0],S.Size);
    Http.Cache.Put(Key,B,TCacheMetadata.Make('image/png'));
  finally S.Free;W.Free;F.Free;end;
end;

{ Only the overview's exact neutral land fill is replaced. Vector water,
  roads, borders and text keep their original colours and pixel positions. }
procedure FlatMapApplyTerrain(Base,Terrain:TCastleImage);
var X,Y:Integer;P,Q:PVector3Byte;
begin
  if(Base=nil)or(Terrain=nil)then Exit;
  for Y:=0 to 255 do for X:=0 to 255 do begin
    P:=PVector3Byte(Base.PixelPtr(X,Y));
    if(P^.X=$ED)and(P^.Y=$EC)and(P^.Z=$E2)then begin
      Q:=PVector3Byte(Terrain.PixelPtr(X,Y));P^:=Q^;
    end;
  end;
end;

function TerrainTile(Http:THTTPFetcherWithCache;Z,X,Y:Integer;Cancel:TThread):TCastleImage;
var SZ,D,I,PX,PY,X0,Y0,X1,Y1:Integer;URL:string;R:TFetchResult;
  Img:TFPMemoryImage;A,B,C,E:TFPColor;P:PVector3Byte;U,V,FX,FY:Double;
  function Blend(C0,C1,C2,C3:Word):Byte;
  begin Result:=EnsureRange(Round(((C0*(1-FX)+C1*FX)*(1-FY)+(C2*(1-FX)+C3*FX)*FY)/257),0,255);end;
begin
  Result:=nil;Img:=nil;SZ:=Math.Min(Z,FLAT_MAP_TERRAIN_ZOOM);D:=1 shl(Z-SZ);
  for I:=0 to 1 do begin
    if FlatMapCancelled(Http,Cancel)then Exit;
    if I=0 then URL:='https://rezvivo.com'else URL:='https://rezvivo.ru';
    URL:=URL+'/map/terrain-ne-v1/'+IntToStr(SZ)+'/'+IntToStr(X div D)+'/'+IntToStr(Y div D)+'.png';
    R:=Http.GetUrl(URL,1500,1);if R.Success then Img:=Decode(R.Data);
    if Img<>nil then Break;if R.Success then Http.InvalidateGetUrl(URL);
  end;
  if Img=nil then Exit;
  try
    Result:=TRGBImage.Create(256,256);
    for PY:=0 to 255 do begin
      V:=EnsureRange(((Y mod D)*256+PY+0.5)/D-0.5,0.0,255.0);
      Y0:=Floor(V);Y1:=Math.Min(Y0+1,255);FY:=V-Y0;
      for PX:=0 to 255 do begin
        U:=EnsureRange(((X mod D)*256+PX+0.5)/D-0.5,0.0,255.0);
        X0:=Floor(U);X1:=Math.Min(X0+1,255);FX:=U-X0;
        A:=Img.Colors[X0,Y0];B:=Img.Colors[X1,Y0];C:=Img.Colors[X0,Y1];E:=Img.Colors[X1,Y1];
        P:=PVector3Byte(Result.PixelPtr(PX,255-PY));
        P^.X:=Blend(A.Red,B.Red,C.Red,E.Red);P^.Y:=Blend(A.Green,B.Green,C.Green,E.Green);
        P^.Z:=Blend(A.Blue,B.Blue,C.Blue,E.Blue);
      end;
    end;
  finally Img.Free;end;
end;

function World(Http:THTTPFetcherWithCache;Z,X,Y:Integer;Cancel:TThread;LandOnly:Boolean=False):TCastleImage;
var SZ,D,I,PX,PY:Integer;URL:string;R:TFetchResult;Img:TFPMemoryImage;C:TFPColor;P:PVector3Byte;
  Terrain:TCastleImage;HasLand:Boolean;
begin
  Result:=nil;SZ:=Math.Min(Z,FLAT_MAP_WORLD_ZOOM);D:=1 shl(Z-SZ);Img:=nil;
  for I:=0 to 1 do begin
    if FlatMapCancelled(Http,Cancel)then Exit;
    if I=0 then URL:='https://rezvivo.com' else URL:='https://rezvivo.ru';
    if LandOnly then URL:=URL+'/map/land-ne-v1/'else URL:=URL+'/map/world-ne-v1/';
    URL:=URL+IntToStr(SZ)+'/'+IntToStr(X div D)+'/'+IntToStr(Y div D)+'.png';
    R:=Http.GetUrl(URL,1500,1);
    if R.Success then Img:=Decode(R.Data);
    if Img<>nil then Break;
    if R.Success then Http.InvalidateGetUrl(URL);
  end;
  if Img=nil then Exit;
  try
    Result:=TRGBImage.Create(256,256);HasLand:=False;
    for PY:=0 to 255 do for PX:=0 to 255 do begin
      C:=Img.Colors[((X mod D)*256+PX) div D,((Y mod D)*256+PY) div D];
      P:=PVector3Byte(Result.PixelPtr(PX,255-PY));P^.X:=C.Red shr 8;P^.Y:=C.Green shr 8;P^.Z:=C.Blue shr 8;
      if(P^.X=$ED)and(P^.Y=$EC)and(P^.Z=$E2)then HasLand:=True;
    end;
  finally Img.Free;end;
  if not LandOnly and HasLand and not FlatMapCancelled(Http,Cancel)then begin
    { An optional terrain download must not discard the valid overview. }
    try Terrain:=TerrainTile(Http,Z,X,Y,Cancel);except Exit;end;
    try FlatMapApplyTerrain(Result,Terrain);finally Terrain.Free;end;
  end;
end;

function ValidOsm(const B:TBytes):Boolean;
var S:TBytesStream;J:TJSONData;
begin
  Result:=False;J:=nil;if Length(B)>32*1024*1024 then Exit;
  S:=TBytesStream.Create(B);
  try
    try J:=GetJSON(S);
      Result:=(J is TJSONObject)and(TJSONObject(J).Find('elements')is TJSONArray)and
        (TJSONObject(J).Get('remark','')='')and(TJSONObject(J).Get('error','')='');
    except Result:=False;end;
  finally J.Free;S.Free;end;
end;

function LoadSource(Http:THTTPFetcherWithCache;const Tile:TTileXY;Cancel:TThread;CoastOnly:Boolean):TOSMDataset;
var Q,Err:string;B:TBytes;
    Elapsed:Int64;OK:Boolean;Box:TLatLonBox;
begin
  Result:=nil;if FlatMapCancelled(Http,Cancel)then Exit;
  if CoastOnly then begin
    Box:=TTileMath.TileToLatLonBox(Tile).ExpandMeters(1000);
    Q:=Format('[bbox:%.7f,%.7f,%.7f,%.7f][out:json][timeout:25];way["natural"="coastline"];(._;>;);out body;',
      [Box.MinLat,Box.MinLon,Box.MaxLat,Box.MaxLon],InvariantFmt);
  end else begin
  Q:=TOverpassQueryExt.BuildCombinedFull(TTileMath.TileToLatLonBox(Tile),DefaultFlagsForFullScene,OVERPASS_TIMEOUT_DEFAULT);
  { Identical full-scene query, tile and timeout to 3D. Rendering selects
    features locally; the shared raw cache keeps buildings, trees and POIs. }
  end;
  OK:=Http.Cache.Get(OverpassCacheKey(Q),B);
  if OK and not ValidOsm(B)then begin Http.Cache.Delete(OverpassCacheKey(Q));OK:=False;end;
  if not OK then OK:=OverpassFetchOnEndpoint(Http,'auto',Q,B,Elapsed,Err);
  if not OK or FlatMapCancelled(Http,Cancel)then Exit;
  Result:=TOSMDataset.Create;
  try TOSMJsonReader.ParseBytes(B,Result);
  except FreeAndNil(Result);Http.Cache.Delete(OverpassCacheKey(Q));end;
end;

function Source(Http:THTTPFetcherWithCache;const Tile:TTileXY;Cancel:TThread;
  Pins:Classes.TList;CoastOnly:Boolean=False):TOSMDataset;
var Key:string;I:Integer;E,Found:TSource;Owner:Boolean;D:TOSMDataset;
begin
  { Each renderer pins its immutable datasets. Only the first requester
    fetches/parses a source; neighbouring children wait on that entry alone. }
  Result:=nil;if FlatMapCancelled(Http,Cancel)then Exit;
  Key:=Tile.ToString;if CoastOnly then Key:='coast:'+Key;
  Found:=nil;Owner:=False;
  SourceLock.Enter;
  try
    for I:=0 to Sources.Count-1 do begin E:=TSource(Sources[I]);
      if E.Key=Key then begin Found:=E;Break;end;
    end;
    if Found=nil then begin Found:=TSource.Create;Found.Key:=Key;Sources.Add(Found);end;
    E:=Found;Pins.Add(E);Inc(E.Users);E.Used:=GetTickCount64;
    if not E.Loading and(E.Data=nil)and(E.Used>=E.RetryAt)then begin
      E.Loading:=True;E.Ready.ResetEvent;Owner:=True;Inc(SourceLoadCount);
    end else if E.Loading then Inc(SourceWaitCount);
  finally SourceLock.Leave;end;
  repeat
    if Owner then begin
      D:=nil;
      try
        try D:=LoadSource(Http,Tile,Cancel,CoastOnly);except FreeAndNil(D);end;
      finally
        { Signal on success, failure AND cancellation; waiters must never
          depend on the lifetime or HTTP cancellation of the original task. }
        SourceLock.Enter;
        try
          E.Data:=D;E.Loading:=False;E.LoadCancelled:=FlatMapCancelled(Http,Cancel);
          if(D=nil)and not E.LoadCancelled then E.RetryAt:=GetTickCount64+2000 else E.RetryAt:=0;
          E.Ready.SetEvent;
        finally SourceLock.Leave;end;
      end;
      Owner:=False;
    end;
    if FlatMapCancelled(Http,Cancel)then Exit;
    SourceLock.Enter;
    try
      if not E.Loading then begin
        if E.Data<>nil then Exit(E.Data);
        if not E.LoadCancelled then Exit;
        { A live waiter takes over a cancelled producer using its own HTTP. }
        E.Loading:=True;E.LoadCancelled:=False;E.Ready.ResetEvent;
        Owner:=True;Inc(SourceLoadCount);
      end;
    finally SourceLock.Leave;end;
    if not Owner then E.Ready.WaitFor(20);
  until False;
end;

procedure ReleaseSources(Pins:Classes.TList);
var I,Total,Oldest:Integer;E:TSource;Retired:Classes.TList;
begin
  Retired:=Classes.TList.Create;
  try
    SourceLock.Enter;
    try
      if Pins<>nil then for I:=0 to Pins.Count-1 do begin
        E:=TSource(Pins[I]);Dec(E.Users);E.Used:=GetTickCount64;
      end;
      repeat
        Total:=0;Oldest:=-1;
        for I:=0 to Sources.Count-1 do begin E:=TSource(Sources[I]);
          if E.Data<>nil then Inc(Total,E.Data.Nodes.Count);
          if(E.Users=0)and not E.Loading and
            ((Oldest<0)or(E.Used<TSource(Sources[Oldest]).Used))then Oldest:=I;
        end;
        if((Sources.Count<=8)and(Total<=120000))or(Oldest<0)then Break;
        Retired.Add(Sources[Oldest]);Sources.Delete(Oldest);
      until False;
    finally SourceLock.Leave;end;
    { Large datasets can take time to destroy. Never hold the shared lock. }
    for I:=0 to Retired.Count-1 do TObject(Retired[I]).Free;
  finally Retired.Free;Pins.Free;end;
end;

constructor TRaster.Create(AZ,AX,AY:Integer);
var I:Integer;
begin Z:=AZ;TX:=AX;TY:=AY;ClipX1:=SIDE-1;ClipY1:=SIDE-1;
  SetLength(Pixels,SIDE*SIDE);for I:=0 to High(Pixels)do Pixels[I]:=$EDECE2;end;

function TRaster.Point(const P:TLatLon):TPixelPoint;
var A,L:Double;
begin
  A:=EnsureRange(P.Lat,-85.05112878,85.05112878)*Pi/180;
  L:=(P.Lon+180)/360*(1 shl Z)-TX;
  if L>(1 shl Z)/2 then L:=L-(1 shl Z);
  if L<-(1 shl Z)/2 then L:=L+(1 shl Z);
  Result.X:=L*SIDE;Result.Y:=((1-Ln(Tan(A)+1/Cos(A))/Pi)/2*(1 shl Z)-TY)*SIDE;
end;

function TRaster.WayRing(W:TOSMWay):TPixelRing;
var I:Integer;N:TOSMNode;
begin
  Result:=nil;SetLength(Result,Length(W.NodeRefs));
  for I:=0 to High(Result)do begin
    N:=Data.FindNode(W.NodeRefs[I]);
    if N=nil then begin Result:=nil;Exit;end;Result[I]:=Point(N.Position);
  end;
end;

procedure TRaster.Fill(const Rings:TPixelRings;Color:LongWord);
var Cross:array of Double;R,I,J,Y,K,N,X,A,B:Integer;U,V:TPixelPoint;T:Double;
    LoY,HiY:Double;
begin
  N:=0;LoY:=SIDE;HiY:=0;
  for R:=0 to High(Rings)do begin Inc(N,Length(Rings[R]));for I:=0 to High(Rings[R])do begin
    LoY:=Math.Min(LoY,Rings[R][I].Y);HiY:=Math.Max(HiY,Rings[R][I].Y);end;end;
  if (N<3)or(HiY<0)or(LoY>=SIDE)then Exit;SetLength(Cross,N);
  for Y:=Math.Max(ClipY0,Floor(LoY))to Math.Min(ClipY1,Ceil(HiY))do begin
    N:=0;
    for R:=0 to High(Rings)do begin J:=High(Rings[R]);
      for I:=0 to High(Rings[R])do begin U:=Rings[R][J];V:=Rings[R][I];J:=I;
        if (U.Y>Y+0.5)<>(V.Y>Y+0.5)then begin
          T:=U.X+(Y+0.5-U.Y)*(V.X-U.X)/(V.Y-U.Y);K:=N;
          while(K>0)and(Cross[K-1]>T)do begin Cross[K]:=Cross[K-1];Dec(K);end;
          Cross[K]:=T;Inc(N);
        end;
      end;
    end;
    K:=0;while K+1<N do begin A:=Math.Max(ClipX0,Ceil(Cross[K]-0.5));B:=Math.Min(ClipX1,Floor(Cross[K+1]-0.5));
      for X:=A to B do Pixels[Y*SIDE+X]:=Color;Inc(K,2);end;
  end;
end;

procedure TRaster.Line(A,B:TPixelPoint;Width:Double;Color:LongWord);
var X,Y,L,R,T,D:Integer;DX,DY,Len,V,Dist,Radius:Double;
begin
  Radius:=Width/2;L:=Floor(Math.Max(ClipX0,Math.Min(A.X,B.X)-Radius));R:=Ceil(Math.Min(ClipX1,Math.Max(A.X,B.X)+Radius));
  T:=Floor(Math.Max(ClipY0,Math.Min(A.Y,B.Y)-Radius));D:=Ceil(Math.Min(ClipY1,Math.Max(A.Y,B.Y)+Radius));
  if(L>R)or(T>D)then Exit;DX:=B.X-A.X;DY:=B.Y-A.Y;Len:=DX*DX+DY*DY;
  for Y:=T to D do for X:=L to R do begin
    if Len<1E-12 then V:=0 else V:=EnsureRange(((X+0.5-A.X)*DX+(Y+0.5-A.Y)*DY)/Len,0.0,1.0);
    Dist:=Sqr(X+0.5-A.X-V*DX)+Sqr(Y+0.5-A.Y-V*DY);
    if Dist<=Radius*Radius then Pixels[Y*SIDE+X]:=Color;
  end;
end;

function AreaStyle(T:TOSMTags;out Color:LongWord;out Pass:Integer):Boolean;
var N,L:string;
begin
  Result:=True;Pass:=0;N:=T.GetLower('natural');L:=T.GetLower('landuse');
  if T.HasKey('building')or T.HasKey('building:part')then begin Color:=$CEC5BA;Pass:=2;end
  else if(N='water')or(L='reservoir')or(T.GetLower('waterway')='riverbank')then begin Color:=$B4D2DD;Pass:=1;end
  else if(N='wood')or(N='scrub')or(L='forest')then Color:=$BDD1B1
  else if(L='grass')or(L='meadow')or(N='grassland')or(T.GetLower('leisure')='park')or(T.GetLower('leisure')='garden')then Color:=$D3DFC0
  else if(L='farmland')or(L='orchard')then Color:=$E3DFC2
  else if(L='residential')then Color:=$E3E0D8
  else if(L='industrial')or(L='commercial')then Color:=$DDD8D8
  else if(N='sand')or(N='beach')then Color:=$F0E4BF
  else Result:=False;
end;

function MainRoad(const Kind:string):Boolean;
begin
  Result:=(Kind='motorway')or(Kind='motorway_link')or(Kind='trunk')or(Kind='trunk_link')or
    (Kind='primary')or(Kind='primary_link')or(Kind='secondary')or(Kind='secondary_link')or
    (Kind='tertiary')or(Kind='tertiary_link')or(Kind='unclassified');
end;

function PlaceRank(const Kind:string):Integer;
begin
  if Kind='city' then Result:=0 else if Kind='town' then Result:=1 else
  if Kind='village' then Result:=2 else if Kind='hamlet' then Result:=3 else Result:=4;
end;

procedure TRaster.Features(D:TOSMDataset;Pass:Integer;Cancel:TThread);
var W:TOSMWay;Rel:TOSMRelation;Rings:TPixelRings;R:TPixelRing;Color:LongWord;
    P,I,J,K:Integer;OuterWays,InnerWays:TOSMWayArray;OC,IC:Integer;
    Chains:TInt64ArrayArray;N:TOSMNode;Kind:string;Width:Double;
    Members:specialize TDictionary<Int64,Boolean>;
  procedure AddChains(const Ways:TOSMWayArray;Count:Integer);
  var C:TInt64ArrayArray;A,B,L:Integer;Valid:Boolean;
  begin
    C:=StitchWaysIntoRingChains(Slice(Ways,Count));
    for A:=0 to High(C)do begin
      SetLength(R,Length(C[A]));Valid:=True;
      for B:=0 to High(R)do begin N:=D.FindNode(C[A][B]);if N=nil then begin Valid:=False;Break;end;R[B]:=Point(N.Position);end;
      if Valid then begin L:=Length(Rings);SetLength(Rings,L+1);Rings[L]:=Copy(R);end;
    end;
  end;
begin
  Data:=D;
  if(Z<FLAT_MAP_STREET_ZOOM)and(Pass=2)then Exit;
  if Pass<=2 then begin
    Members:=specialize TDictionary<Int64,Boolean>.Create;
    try
    for Rel in D.Relations.Values do if AreaStyle(Rel.Tags,Color,P)and(P=Pass)then
      for I:=0 to High(Rel.Members)do if Rel.Members[I].Kind=omkWay then Members.AddOrSetValue(Rel.Members[I].Ref,True);
    for W in D.Ways.Values do begin
      if (Cancel<>nil)and TThreadAccess(Cancel).Terminated then Exit;
      if Members.ContainsKey(W.Id)then Continue;
      if W.IsClosed and AreaStyle(W.Tags,Color,P)and(P=Pass)then begin
        SetLength(Rings,1);Rings[0]:=WayRing(W);Fill(Rings,Color);
      end;
    end;
    for Rel in D.Relations.Values do begin
      if (Cancel<>nil)and TThreadAccess(Cancel).Terminated then Exit;
      if AreaStyle(Rel.Tags,Color,P)and(P=Pass)then begin
        Rings:=nil;OuterWays:=nil;InnerWays:=nil;OC:=0;IC:=0;
        SplitRelationByRole(Rel,D,OuterWays,InnerWays,OC,IC);
        AddChains(OuterWays,OC);AddChains(InnerWays,IC);Fill(Rings,Color);
      end;
    end;
    finally Members.Free;end;
    Exit;
  end;
  for W in D.Ways.Values do begin
    if (Cancel<>nil)and TThreadAccess(Cancel).Terminated then Exit;
    Kind:=W.Tags.GetLower('highway');Width:=0;Color:=$FFFFFF;
    if Kind<>'' then begin
      if(Z<FLAT_MAP_STREET_ZOOM)and not MainRoad(Kind)then Continue;
      if(Pos('motorway',Kind)>0)or(Pos('trunk',Kind)>0)then begin Width:=8;Color:=$EBCB94;end
      else if(Pos('primary',Kind)>0)or(Pos('secondary',Kind)>0)then begin Width:=7;Color:=$F5DEA5;end
      else if(Kind='footway')or(Kind='path')or(Kind='cycleway')or(Kind='steps')then begin Width:=2;Color:=$BDAD99;end
      else Width:=5;
      Width:=Width*Power(1.2,Z-14);
    end else if W.Tags.HasKey('waterway')then begin
      if(Z<FLAT_MAP_STREET_ZOOM)and(W.Tags.GetLower('waterway')<>'river')and(W.Tags.GetLower('waterway')<>'canal')then Continue;
      Width:=2.5;Color:=$94BDC9;end
    else if W.Tags.HasKey('railway')and(Z>=FLAT_MAP_STREET_ZOOM)then begin Width:=2;Color:=$979390;end;
    if Width=0 then Continue;
    R:=WayRing(W);
    if Pass=3 then begin if Kind='' then Continue;Width:=Width+2;Color:=$C3BEB3;end;
    if W.Tags.GetLower('tunnel')='yes' then Color:=$BDBBB5;
    for I:=1 to High(R)do Line(R[I-1],R[I],Width,Color);
  end;
end;

procedure TRaster.Labels(D:TOSMDataset);
{$ifdef MSWINDOWS}
var DC:HDC;Bmp,OldBmp:HGDIOBJ;Info:BITMAPINFO;Bits:Pointer;Font,OldFont:HGDIOBJ;
    W:TOSMWay;Node:TOSMNode;P:TPixelPoint;Text:UnicodeString;Size:TSize;X,Y,I,J:Integer;
    R:TPixelRing;Name:string;Rank:Integer;
  procedure LabelAt(const S:string;const A:TPixelPoint);
  var K,L,X0,X1,Y0,Y1:Integer;
  begin
    if(S='')or(Length(S)>100)then Exit;Text:=UTF8Decode(S);
    GetTextExtentPoint32W(DC,PWideChar(Text),Length(Text),Size);
    X:=Round(A.X-Size.cx/2);Y:=Round(A.Y-Size.cy/2);
    { Own only labels fully inside a tile: no truncated words at seams. }
    if(X<5)or(Y<5)or(X+Size.cx>SIDE-5)or(Y+Size.cy>SIDE-5)then Exit;
    X0:=X div 16;X1:=(X+Size.cx)div 16;Y0:=Y div 16;Y1:=(Y+Size.cy)div 16;
    for K:=Y0 to Y1 do for L:=X0 to X1 do if LabelUsed[K,L]then Exit;
    for K:=Y0 to Y1 do for L:=X0 to X1 do LabelUsed[K,L]:=True;
    SetTextColor(DC,$00F4F4F0);
    TextOutW(DC,X-2,Y,PWideChar(Text),Length(Text));TextOutW(DC,X+2,Y,PWideChar(Text),Length(Text));
    TextOutW(DC,X,Y-2,PWideChar(Text),Length(Text));TextOutW(DC,X,Y+2,PWideChar(Text),Length(Text));
    SetTextColor(DC,$00504A45);TextOutW(DC,X,Y,PWideChar(Text),Length(Text));
  end;
{$endif}
begin
  {$ifdef MSWINDOWS}
  FillChar(Info,SizeOf(Info),0);
  Info.bmiHeader.biSize:=SizeOf(BITMAPINFOHEADER);Info.bmiHeader.biWidth:=SIDE;
  Info.bmiHeader.biHeight:=-SIDE;Info.bmiHeader.biPlanes:=1;Info.bmiHeader.biBitCount:=32;Info.bmiHeader.biCompression:=BI_RGB;
  DC:=CreateCompatibleDC(0);if DC=0 then Exit;
  Bmp:=CreateDIBSection(DC,Info,DIB_RGB_COLORS,Bits,0,0);
  if Bmp=0 then begin DeleteDC(DC);Exit;end;
  OldBmp:=SelectObject(DC,Bmp);Font:=CreateFontW(-22,0,0,0,FW_NORMAL,0,0,0,DEFAULT_CHARSET,
    OUT_DEFAULT_PRECIS,CLIP_DEFAULT_PRECIS,ANTIALIASED_QUALITY,DEFAULT_PITCH,'Segoe UI');OldFont:=SelectObject(DC,Font);
  try
    Move(Pixels[0],Bits^,Length(Pixels)*4);SetBkMode(DC,TRANSPARENT);
    if Z<FLAT_MAP_STREET_ZOOM then begin
      for Rank:=0 to Math.Min(3,Z-9)do for Node in D.Nodes.Values do
        if PlaceRank(Node.Tags.GetLower('place'))=Rank then LabelAt(Node.Tags.Get('name'),Point(Node.Position));
    end else for Node in D.Nodes.Values do if Node.Tags.HasKey('place')then LabelAt(Node.Tags.Get('name'),Point(Node.Position));
    Data:=D;
    if Z>=FLAT_MAP_STREET_ZOOM then for W in D.Ways.Values do if W.Tags.HasKey('highway')then begin
      Name:=W.Tags.Get('name');if Name='' then Continue;R:=WayRing(W);if Length(R)<2 then Continue;
      I:=Length(R)div 2;P.X:=(R[I-1].X+R[I].X)/2;P.Y:=(R[I-1].Y+R[I].Y)/2;LabelAt(Name,P);
    end;
    GdiFlush;Move(Bits^,Pixels[0],Length(Pixels)*4);
  finally SelectObject(DC,OldFont);DeleteObject(Font);SelectObject(DC,OldBmp);DeleteObject(Bmp);DeleteDC(DC);end;
  {$endif}
end;

function TRaster.Image:TCastleImage;
var X,Y,I,J,R,G,B:Integer;C:LongWord;P:PVector3Byte;
begin
  Result:=TRGBImage.Create(256,256);
  for Y:=0 to 255 do for X:=0 to 255 do begin
    R:=0;G:=0;B:=0;
    for J:=0 to 1 do for I:=0 to 1 do begin C:=Pixels[(Y*2+J)*SIDE+X*2+I];Inc(R,(C shr 16)and 255);Inc(G,(C shr 8)and 255);Inc(B,C and 255);end;
    P:=PVector3Byte(Result.PixelPtr(X,255-Y));P^.X:=R div 4;P^.Y:=G div 4;P^.Z:=B div 4;
  end;
end;

function FlatMapShade(Dx,Dy:Double):Double;
begin
  { NW light, y increases south. Gentle hillshade plus slope darkening.
    Flat terrain has exactly unit gain, no seams from absolute elevation. }
  Result:=EnsureRange(0.72+0.28*(1-0.7*Dx+0.7*Dy)/Sqrt(1+Dx*Dx+Dy*Dy),0.62,1.07);
end;

function RefineSea(Http:THTTPFetcherWithCache;Raster:TRaster;Cancel:TThread;Pins:Classes.TList):Boolean;
var D,C:TOSMDataset;W,V:TOSMWay;N:TOSMNode;I:Integer;Box:TLatLonBox;
begin
  Result:=False;
  D:=Source(Http,TTileXY.Make(Raster.TX shr(Raster.Z-12),Raster.TY shr(Raster.Z-12),12),Cancel,Pins,True);
  if D=nil then Exit;
  { The shared OSM cache stays immutable. Reuse the 3D coastline topology
    builder on a small private copy; it also handles islands and open coasts. }
  C:=TOSMDataset.Create;
  try
    for W in D.Ways.Values do if W.Tags.GetLower('natural')='coastline' then begin
      V:=TOSMWay.Create(W.Id);V.Tags.Add('natural','coastline');V.NodeRefs:=Copy(W.NodeRefs);C.AddWay(V);
      for I:=0 to High(W.NodeRefs)do if C.FindNode(W.NodeRefs[I])=nil then begin
        N:=D.FindNode(W.NodeRefs[I]);if N<>nil then C.AddNode(TOSMNode.Create(N.Id,N.Position));
      end;
    end;
    if FlatMapCancelled(Http,Cancel)then Exit;
    if C.Ways.Count=0 then Exit(True); { verified open ocean: coarse mask is sufficient }
    Box:=TTileMath.TileToLatLonBox(TTileXY.Make(Raster.TX,Raster.TY,Raster.Z));
    if AddSeaSurfaces(C,Box,Box.Center,Box.Center.Lat)<0 then Exit;
    for I:=0 to High(Raster.Pixels)do Raster.Pixels[I]:=$EDECE2;
    Raster.Features(C,1,Cancel);Result:=True;
  finally C.Free;end;
end;

function FlatMapTile(Http:THTTPFetcherWithCache;Z,X,Y:Integer;
  Detailed:Boolean;Cancel:TThread):TCastleImage;
var ActualDetail:Boolean;
begin Result:=FlatMapTileInfo(Http,Z,X,Y,Detailed,False,ActualDetail,Cancel);end;

function CoarseTile(Http:THTTPFetcherWithCache;Z,X,Y:Integer;Cancel:TThread;
  out Complete,HasDEM:Boolean):TCastleImage;
var Raster,Snapshot:TRaster;Base,Mask:TCastleImage;Places,D:TOSMDataset;N,V:TOSMNode;
  TF:TTerrariumFetcher;HM:THeightmap;Box:TLatLonBox;Posi:TLatLon;T:TTileXY;Pins:Classes.TList;
  P,Cell,I,J,K,A,B,Pass,Index,Best,Success:Integer;LastPublish:QWord;Distance,BestDistance:Double;
  Done,Visited:array of Boolean;Gain,Row:array of Single;CV:TVector4;C:LongWord;HPX,HPY:Single;Mpp:Double;
  function CurrentImage:TCastleImage;
  var U,V,L:Integer;Color:LongWord;G:Double;
  begin
    Snapshot:=TRaster.Create(Z,X,Y);
    try
      Snapshot.Pixels:=Copy(Raster.Pixels);
      if HasDEM then for V:=0 to SIDE-1 do for U:=0 to SIDE-1 do
        if Done[(V div Cell)*P+U div Cell]then begin
          L:=V*SIDE+U;Color:=Snapshot.Pixels[L];if Color=$B4D2DD then Continue;G:=Gain[L];
          Snapshot.Pixels[L]:=(Math.Min(255,Round(((Color shr 16)and 255)*G))shl 16)or
            (Math.Min(255,Round(((Color shr 8)and 255)*G))shl 8)or Math.Min(255,Round((Color and 255)*G));
        end;
      Snapshot.Labels(Places);Result:=Snapshot.Image;
    finally Snapshot.Free;end;
  end;
begin
  { At z11/12 the view covers many full z14 source tiles. Render each source
    in its own pixel rectangle and publish progress; never retain dozens of
    complete datasets or wait for the entire low-zoom tile before displaying it. }
  Result:=nil;Complete:=True;HasDEM:=False;Success:=0;LastPublish:=0;
  P:=1 shl(OVERPASS_TILE_ZOOM_DEFAULT-Z);Cell:=SIDE div P;SetLength(Done,P*P);SetLength(Visited,P*P);
  Raster:=TRaster.Create(Z,X,Y);Places:=TOSMDataset.Create;Base:=nil;Mask:=nil;TF:=nil;HM:=nil;
  try
    Base:=World(Http,Z,X,Y,Cancel);Mask:=World(Http,Z,X,Y,Cancel,True);
    if FlatMapCancelled(Http,Cancel)then Exit;
    if Base<>nil then for J:=0 to SIDE-1 do for I:=0 to SIDE-1 do begin
      CV:=Base.Colors[I div 2,255-J div 2,0];
      Raster.Pixels[J*SIDE+I]:=(Round(CV.X*255)shl 16)or(Round(CV.Y*255)shl 8)or Round(CV.Z*255);
    end;
    Box:=TTileMath.TileToLatLonBox(TTileXY.Make(X,Y,Z));
    Box:=Box.ExpandMeters(6*40075016.686*Cos(Box.Center.Lat*Pi/180)/(256*(1 shl Z))+1);
    TF:=TTerrariumFetcher.Create(Http,'',12);HM:=TF.GetRegionCachedOnly(Box,Z);
    if HM=nil then HM:=TF.GetRegion(Box,Z);HasDEM:=HM<>nil;
    if HasDEM then begin
      HM.BlurGaussian(1.0);SetLength(Row,(SIDE+2)*(SIDE+2));SetLength(Gain,SIDE*SIDE);
      for J:=-1 to SIDE do begin
        if FlatMapCancelled(Http,Cancel)then Exit;
        Posi.Lat:=ArcTan(Sinh(Pi*(1-2*(Y+(J+0.5)/SIDE)/(1 shl Z))))*180/Pi;
        for I:=-1 to SIDE do begin
          Posi.Lon:=(X+(I+0.5)/SIDE)/(1 shl Z)*360-180;
          THeightmapSampler.LatLonToPixel(HM,Posi,HPX,HPY);
          Row[(J+1)*(SIDE+2)+I+1]:=THeightmapSampler.CubicSamplePx(HM,HPX,HPY);
        end;
      end;
      for J:=0 to SIDE-1 do begin
        Mpp:=40075016.686*Cos(ArcTan(Sinh(Pi*(1-2*(Y+(J+0.5)/SIDE)/(1 shl Z)))))/(SIDE*(1 shl Z));
        for I:=0 to SIDE-1 do begin K:=(J+1)*(SIDE+2)+I+1;
          Gain[J*SIDE+I]:=FlatMapShade((Row[K+1]-Row[K-1])/(2*Mpp),(Row[K+SIDE+2]-Row[K-SIDE-2])/(2*Mpp));
        end;
      end;
    end;
    for Index:=0 to P*P-1 do begin
      if FlatMapCancelled(Http,Cancel)then Exit;
      { Centre first within each low-zoom tile. Failed entries count as visited. }
      Best:=-1;BestDistance:=1E30;
      for K:=0 to P*P-1 do if not Visited[K]then begin
        Distance:=Sqr(K mod P+0.5-P/2)+Sqr(K div P+0.5-P/2);
        if Distance<BestDistance then begin Best:=K;BestDistance:=Distance;end;
      end;
      if Best<0 then Break;I:=Best mod P;J:=Best div P;Visited[Best]:=True;
      Pins:=Classes.TList.Create;
      try
        T:=TTileXY.Make(X*P+I,Y*P+J,OVERPASS_TILE_ZOOM_DEFAULT);D:=Source(Http,T,Cancel,Pins);
        if FlatMapCancelled(Http,Cancel)then Exit;
        if D=nil then begin Complete:=False;Continue;end;
        Raster.ClipX0:=I*Cell;Raster.ClipY0:=J*Cell;Raster.ClipX1:=(I+1)*Cell-1;Raster.ClipY1:=(J+1)*Cell-1;
        for B:=Raster.ClipY0 to Raster.ClipY1 do for A:=Raster.ClipX0 to Raster.ClipX1 do begin
          C:=$EDECE2;if Mask<>nil then begin CV:=Mask.Colors[A div 2,255-B div 2,0];if CV.X<0.5 then C:=$B4D2DD;end;
          Raster.Pixels[B*SIDE+A]:=C;
        end;
        for Pass:=0 to 4 do Raster.Features(D,Pass,Cancel);
        for N in D.Nodes.Values do if(PlaceRank(N.Tags.GetLower('place'))<4)and(Places.FindNode(N.Id)=nil)then begin
          V:=TOSMNode.Create(N.Id,N.Position);V.Tags.Add('place',N.Tags.Get('place'));V.Tags.Add('name',N.Tags.Get('name'));Places.AddNode(V);
        end;
        Inc(Success);Done[Best]:=True;
      finally ReleaseSources(Pins);end;
      if(Cancel is TFlatMapTask)and not FlatMapCancelled(Http,Cancel)and
        ((LastPublish=0)or(GetTickCount64-LastPublish>=500))then begin
        TFlatMapTask(Cancel).Publish(CurrentImage,True);LastPublish:=GetTickCount64;
      end;
    end;
    Complete:=Complete and(Mask<>nil);
    if(Success>0)and not FlatMapCancelled(Http,Cancel)then Result:=CurrentImage;
  finally HM.Free;TF.Free;Mask.Free;Base.Free;Places.Free;Raster.Free;end;
end;

function FlatMapTileInfo(Http:THTTPFetcherWithCache;Z,X,Y:Integer;
  Detailed,CachedOnly:Boolean;out ActualDetail:Boolean;Cancel:TThread):TCastleImage;
var Key:string;Raster:TRaster;D:TOSMDataset;I,J,K,P,SZ,DX,DY:Integer;T:TTileXY;
    TF:TTerrariumFetcher;HM:THeightmap;Box:TLatLonBox;Posi:TLatLon;
    Mpp,HX,HY,Shade:Double;C:LongWord;AllOK,HasDEM,NearCoast:Boolean;Base:TCastleImage;W:TOSMWay;
    SourcesHere:array of TOSMDataset;Row:array of Single;CV:TVector4;HPX,HPY:Single;
    Pins:Classes.TList;
begin
  ActualDetail:=False;Result:=nil;if(Z<0)or(Z>19)or(X<0)or(Y<0)or(X>=1 shl Z)or(Y>=1 shl Z)or FlatMapCancelled(Http,Cancel)then Exit;
  Key:=FLAT_MAP_VERSION+':'+IntToStr(Z)+'/'+IntToStr(X)+'/'+IntToStr(Y);
  if(Z>=FLAT_MAP_DETAIL_ZOOM)and(Z<FLAT_MAP_STREET_ZOOM)then Key:=FLAT_MAP_COARSE_VERSION+':'+IntToStr(Z)+'/'+IntToStr(X)+'/'+IntToStr(Y);
  if Z>=FLAT_MAP_DETAIL_ZOOM then begin
    Result:=ReadImage(Http,Key+':dem');if Result<>nil then begin ActualDetail:=True;Exit;end;
    if not Detailed or(Z<FLAT_MAP_STREET_ZOOM)then begin Result:=ReadImage(Http,Key+':plain');if Result<>nil then begin ActualDetail:=True;Exit;end;end;
  end;
  if CachedOnly then Exit;
  if not Detailed or(Z<FLAT_MAP_DETAIL_ZOOM)then Exit(World(Http,Z,X,Y,Cancel));
  { One bounded CPU budget shared by all globe widgets. Fetching, rasterising,
    DEM shading and PNG encoding run without holding the source-cache lock. }
  if not BeginBuild(Http,Cancel)then Exit;
  Raster:=nil;HM:=nil;TF:=nil;Base:=nil;Pins:=nil;
  try
    Pins:=Classes.TList.Create;
    if FlatMapCancelled(Http,Cancel)then Exit;
    Result:=ReadImage(Http,Key+':dem');if Result<>nil then begin ActualDetail:=True;Exit;end;
    if Z<FLAT_MAP_STREET_ZOOM then begin
      Result:=CoarseTile(Http,Z,X,Y,Cancel,AllOK,HasDEM);ActualDetail:=(Result<>nil)and AllOK;
      if ActualDetail then try
        if HasDEM then SaveImage(Http,Key+':dem',Result)else SaveImage(Http,Key+':plain',Result);
      except end;
      Exit;
    end;
    Raster:=TRaster.Create(Z,X,Y);AllOK:=True;SZ:=Math.Max(14,Z);P:=1 shl(SZ-Z);
    SetLength(SourcesHere,P*P);K:=0;
    for J:=0 to P-1 do for I:=0 to P-1 do begin
      T:=TTileXY.Make((X*P+I)shr(SZ-14),(Y*P+J)shr(SZ-14),14);
      D:=Source(Http,T,Cancel,Pins);SourcesHere[K]:=D;Inc(K);if D=nil then AllOK:=False;
    end;
    if FlatMapCancelled(Http,Cancel)then Exit;
    if not AllOK then Exit;
    { Ground colour mask: overview supplies ocean coverage even when no OSM
      coastline node lies in the detailed tile. Labels/roads are not enlarged. }
    Base:=World(Http,Z,X,Y,Cancel,True);NearCoast:=False;
    if Base<>nil then for J:=0 to SIDE-1 do for I:=0 to SIDE-1 do begin
      CV:=Base.Colors[I div 2,255-J div 2,0];
      if CV.X<0.5 then begin Raster.Pixels[J*SIDE+I]:=$B4D2DD;NearCoast:=True;end;
    end;
    if not NearCoast then for K:=0 to High(SourcesHere)do
      for W in SourcesHere[K].Ways.Values do if W.Tags.GetLower('natural')='coastline' then begin NearCoast:=True;Break;end;
    if NearCoast then AllOK:=RefineSea(Http,Raster,Cancel,Pins);
    for P:=0 to 2 do for K:=0 to High(SourcesHere)do Raster.Features(SourcesHere[K],P,Cancel);
    if FlatMapCancelled(Http,Cancel)then Exit;
    T:=TTileXY.Make(X,Y,Z);Box:=TTileMath.TileToLatLonBox(T);
    { Gaussian radius 3 + cubic support 2 + gradient border need neighbours
      beyond the tile. GetRegion itself does not add any padding. }
    Box:=Box.ExpandMeters(6*40075016.686*Cos(Box.Center.Lat*Pi/180)/
      (256*(1 shl Math.Min(Z,13)))+1);
    TF:=TTerrariumFetcher.Create(Http,'',12);
    HM:=TF.GetRegionCachedOnly(Box,Math.Min(Z,13));
    if HM=nil then HM:=TF.GetRegion(Box,Math.Min(Z,13));
    HasDEM:=HM<>nil;
    if HM<>nil then begin
      HM.BlurGaussian(1.0);
      { Samples include a border on all sides, avoiding clamped gradients at seams. }
      SetLength(Row,(SIDE+2)*(SIDE+2));
      for J:=-1 to SIDE do begin
        if FlatMapCancelled(Http,Cancel)then Exit;
        Posi.Lat:=ArcTan(Sinh(Pi*(1-2*(Y+(J+0.5)/SIDE)/(1 shl Z))))*180/Pi;
        for I:=-1 to SIDE do begin
          Posi.Lon:=(X+(I+0.5)/SIDE)/(1 shl Z)*360-180;
          THeightmapSampler.LatLonToPixel(HM,Posi,HPX,HPY);
          Row[(J+1)*(SIDE+2)+I+1]:=THeightmapSampler.CubicSamplePx(HM,HPX,HPY);
        end;
      end;
      for J:=0 to SIDE-1 do begin
        if FlatMapCancelled(Http,Cancel)then Exit;
        Posi.Lat:=ArcTan(Sinh(Pi*(1-2*(Y+(J+0.5)/SIDE)/(1 shl Z))));
        Mpp:=40075016.686*Cos(Posi.Lat)/(SIDE*(1 shl Z));
        for I:=0 to SIDE-1 do begin
          C:=Raster.Pixels[J*SIDE+I];if C=$B4D2DD then Continue;
          K:=(J+1)*(SIDE+2)+I+1;
          HX:=(Row[K+1]-Row[K-1])/(2*Mpp);HY:=(Row[K+SIDE+2]-Row[K-SIDE-2])/(2*Mpp);Shade:=FlatMapShade(HX,HY);
          Raster.Pixels[J*SIDE+I]:=(Math.Min(255,Round(((C shr 16)and 255)*Shade))shl 16)or
            (Math.Min(255,Round(((C shr 8)and 255)*Shade))shl 8)or Math.Min(255,Round((C and 255)*Shade));
        end;
      end;
    end;
    if FlatMapCancelled(Http,Cancel)then Exit;
    for P:=3 to 4 do for K:=0 to High(SourcesHere)do Raster.Features(SourcesHere[K],P,Cancel);
    for K:=0 to High(SourcesHere)do begin
      if FlatMapCancelled(Http,Cancel)then Exit;Raster.Labels(SourcesHere[K]);
    end;
    if FlatMapCancelled(Http,Cancel)then Exit;
    Result:=Raster.Image;ActualDetail:=True;
    if(Base<>nil)and AllOK then begin
      { A read-only/full cache must not discard an otherwise valid map. }
      try
        if HasDEM then SaveImage(Http,Key+':dem',Result)else SaveImage(Http,Key+':plain',Result);
      except end;
    end;
  finally
    try Base.Free;HM.Free;TF.Free;Raster.Free;ReleaseSources(Pins);
    finally EndBuild;end;
  end;
end;

initialization
  Sources:=Classes.TList.Create;
  SourceLock:=SyncObjs.TCriticalSection.Create;
  WorkerLimit:=Math.Min(4,Math.Max(1,TThread.ProcessorCount-1));
  { Diagnostic A/B override may reduce the budget, never exceed it. }
  WorkerLimit:=EnsureRange(StrToIntDef(SysUtils.GetEnvironmentVariable('REZVIVO_FLAT_MAP_WORKERS'),WorkerLimit),1,WorkerLimit);
finalization
  while Sources.Count>0 do begin TObject(Sources[Sources.Count-1]).Free;Sources.Delete(Sources.Count-1);end;
  Sources.Free;
  SourceLock.Free;
end.
