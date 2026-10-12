program ReadyTilesTests;
{$mode objfpc}{$H+}{$codepage UTF8}
uses Classes, SysUtils, Windows, fpjson, Osm3dSHA256, Osm3dCache, Osm3dCacheHTTPFetcher,
  Osm3dReadyTiles, Osm3dGeoMath, Osm3dGeoTileGrid, Osm3dTileX3D, Osm3dTileBinary,
  Osm3dGeoTileCache, Osm3dTileStreamer, Osm3dGeoTileBlock;
type
  TFixture = class
    CatalogText: string;
    Payload: TBytes;
    Calls, ObjectCalls, CatalogCalls, GenerateCalls: LongInt;
    Offline, BrokenCatalog, BrokenObject: Boolean;
    Delay: Integer;
    Id: TGeoTileId;
    Partial: Boolean;
    MissingId: TGeoTileId;
    function Get(const URL: string; ConnectMs,ReadMs: Integer; Response:TStream;
      Headers:TStrings; out Status:Integer):Boolean;
    function Generate(const Block:TBlockId; const Box:TLatLonBox;
      const Origin:TLatLon; Cancel:PBoolean):TBlockGenResult;
    function Wanted(const T:TGeoTileId):Boolean;
  end;
procedure Check(B:Boolean;const S:string);
begin if not B then raise Exception.Create(S) end;
function Bytes(const S:AnsiString):TBytes;
begin SetLength(Result,Length(S)); if S<>'' then Move(S[1],Result[0],Length(S)) end;
function TFixture.Get(const URL:string;ConnectMs,ReadMs:Integer;Response:TStream;
  Headers:TStrings;out Status:Integer):Boolean;
var S:AnsiString;
begin
  Result:=True; InterlockedIncrement(Calls);
  if Pos('/catalog?',URL)>0 then
    Check((ConnectMs<=2000) and (ReadMs<=2000),'catalogue checks must be bounded')
  else Check((ConnectMs=5000) and (ReadMs=15000),'payload needs mobile idle timeout');
  if Delay>0 then Sleep(Delay);
  Status:=200;
  if Offline then begin Status:=503; Exit end;
  if Pos('/catalog?',URL)>0 then begin
    InterlockedIncrement(CatalogCalls);
    S:=CatalogText; if BrokenCatalog then S:='{"version":999}';
    Response.WriteBuffer(S[1],Length(S));
  end else begin
    InterlockedIncrement(ObjectCalls);
    if BrokenObject then begin S:='bad tile';Response.WriteBuffer(S[1],Length(S)) end
    else Response.WriteBuffer(Payload[0],Length(Payload));
  end;
end;
function TFixture.Generate(const Block:TBlockId;const Box:TLatLonBox;
  const Origin:TLatLon;Cancel:PBoolean):TBlockGenResult;
var Ids:TGeoTileIdArray; I:Integer;
begin
  InterlockedIncrement(GenerateCalls); Result:=Default(TBlockGenResult);
  if Partial then begin
    Ids:=BlockTiles(Block,2); SetLength(Result.Tiles,Length(Ids));
    for I:=0 to High(Ids) do begin
      Result.Tiles[I]:=TTileModel.Create; Result.Tiles[I].TileId:=Ids[I];
      Result.Tiles[I].Origin:=TLatLon.Make(50.0,37.6);
    end;
    Result.Success:=True; Exit;
  end;
  Result.Error:='ready tiles should skip the generator';
end;
function TFixture.Wanted(const T:TGeoTileId):Boolean;
begin Result:=T.Equals(Id) or (Partial and T.Equals(MissingId)) end;
procedure Prepare(F:TFixture;const Root,Gen:string;OriginLat:Double);
var M:TTileModel; S:TFileStream; Hash:string;
begin
  M:=TTileModel.Create;
  try
    M.TileId:=F.Id; M.GenHash:=Gen; M.Origin:=TLatLon.Make(OriginLat,37.6);
    TTileBinary.SaveFile(Root+'fixture.o3dt',M);
  finally M.Free end;
  S:=TFileStream.Create(Root+'fixture.o3dt',fmOpenRead);
  try SetLength(F.Payload,S.Size); S.ReadBuffer(F.Payload[0],S.Size) finally S.Free end;
  Hash:=SHA256Bytes(F.Payload);
  F.CatalogText:=Format('{"version":1,"format":"O3DTBIN1","generator":"ready-test",'+
    '"zoom":13,"edge_px":256,"tiles":[{"tx":%d,"ty":%d,"gen_hash":"%s",'+
    '"sha256":"%s","bytes":%d}]}',[F.Id.TX,F.Id.TY,Gen,Hash,Length(F.Payload)]);
end;
procedure LocalRecipe(const CacheRoot:string;const Id:TGeoTileId;const Center:TLatLon);
var Doc,Target,Entry:TJSONObject; L:TStringList;
begin
  Target:=TJSONObject.Create(['id','way/1','fingerprint',StringOfChar('a',32),
    'category','building','bbox',TJSONArray.Create([Center.Lon-0.00001,Center.Lat-0.00001,
      Center.Lon+0.00001,Center.Lat+0.00001]),'set_tags',TJSONObject.Create(['height','21'])]);
  Entry:=TJSONObject.Create(['recipe_version',1,'tile',TJSONObject.Create([
    'zoom',13,'edge_px',256,'x',Int64(Id.TX),'y',Int64(Id.TY)]),
    'targets',TJSONArray.Create([Target]),'evidence',TJSONArray.Create]);
  Doc:=TJSONObject.Create(['schema_version',1,'tiles',TJSONObject.Create(['fixture',Entry])]);
  L:=TStringList.Create;
  try
    ForceDirectories(CacheRoot+'-knowledge'); L.Text:=Doc.AsJSON;
    L.SaveToFile(CacheRoot+'-knowledge'+PathDelim+'active-recipes-v1.json');
  finally L.Free; Doc.Free end;
end;
var F:TFixture; Http:THTTPFetcherWithCache; Ready:TReadyTiles; M:TTileModel;
  Cache:TGeoTileCache; Stream:TTileStreamer; Root,Revision:string;
  BeforeCalls:Integer; StartTick,Deadline:QWord; Center:TLatLon; SizeBytes:Int64;
  OfflineWas:string; Fetch:TFetchResult;
begin
  Check(ParamStr(1)<>'','pass isolated output directory');
  Root:=IncludeTrailingPathDelimiter(ParamStr(1)); ForceDirectories(Root);
  Check(SHA256Bytes(nil)='e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855','SHA empty');
  Check(SHA256Bytes(Bytes('abc'))='ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad','SHA abc');
  Check(SHA256Bytes(Bytes(StringOfChar('a',1000000)))='cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0','SHA multi-block');
  F:=TFixture.Create; Http:=THTTPFetcherWithCache.Create(TMemoryCache.Create,True);
  Http.PublicGetTransport:=@F.Get; F.Id:=TGeoTileId.Make(0,True,4951,2550);
  Ready:=nil; Cache:=nil; Stream:=nil;
  try
    Http.Cache.Put('GET https://fixture.invalid/offline-cached',Bytes('cached'));
    OfflineWas:=SysUtils.GetEnvironmentVariable('REZVIVO_OFFLINE');
    SetEnvironmentVariable('REZVIVO_OFFLINE','1');
    try
      Fetch:=Http.GetUrl('https://fixture.invalid/offline-cached');
      Check(Fetch.Success and Fetch.FromCache,'offline guard blocked cached GET');
      Fetch:=Http.GetUrl('https://fixture.invalid/offline-missing');
      Check(not Fetch.Success,'offline cache miss was treated as success');
      Fetch:=Http.PostString('https://fixture.invalid/offline-post','body','text/plain');
      Check((not Fetch.Success) and (F.Calls=0),'offline miss reached network transport');
      Fetch:=Http.GetUrl('https://fixture.invalid/offline-cached');
      Check(Fetch.Success and Fetch.FromCache,'offline failure damaged existing cache');
    finally SetEnvironmentVariable('REZVIVO_OFFLINE',PChar(OfflineWas)) end;
    Prepare(F,Root,'ready-test',55.7);
    { Cancellation joins in the map reaper, then again during destruction.
      POSIX pthread_join must still be called exactly once. }
    Ready:=TReadyTiles.Create(Http,'ready-test',13,256,Root,nil,'https://fixture.invalid/api/ready-tiles/v1',True);
    Ready.Stop;Ready.JoinStopped;Ready.JoinStopped;
    Ready.Free;Ready:=nil;
    Ready:=TReadyTiles.Create(Http,'ready-test',13,256,Root,nil,'https://fixture.invalid/api/ready-tiles/v1',False);
    Ready.RefreshCatalog;
    Check(Ready.Available(F.Id,'ready-test'),'published tile missing');
    Cache:=TGeoTileCache.Create(Root+'audit','ready-test',13,256,55.7);
    Cache.ConfigureReadyTiles(nil);
    Check(ReadyTileAvailable(F.Id),'cache-only readiness audit cleared active map markers');
    Cache.Free;Cache:=nil;
    Check(not Ready.Available(F.Id,'other-generator'),'incompatible generator admitted');
    Check(Ready.Acquire(F.Id,'ready-test',M,Revision),'first download failed'); M.Free;
    BeforeCalls:=F.Calls;
    Check(Ready.Acquire(F.Id,'ready-test',M,Revision),'cached object unavailable'); M.Free;
    Check(F.Calls=BeforeCalls,'immutable object fetched twice');
    Ready.Free; Ready:=nil;
    F.Offline:=True;
    Ready:=TReadyTiles.Create(Http,'ready-test',13,256,Root,nil,'https://fixture.invalid/api/ready-tiles/v1',False);
    Check(Ready.Available(F.Id,'ready-test'),'catalogue not saved in common cache');
    Check(Ready.Acquire(F.Id,'ready-test',M,Revision),'offline cached object unavailable'); M.Free;
    Ready.Free; Ready:=nil;
    F.Offline:=False; F.BrokenCatalog:=True;
    Ready:=TReadyTiles.Create(Http,'ready-test',13,256,Root,nil,'https://fixture.invalid/api/ready-tiles/v1',False);
    Ready.RefreshCatalog;
    Check(Ready.Available(F.Id,'ready-test'),'invalid refresh erased usable catalogue');
    Ready.Free; Ready:=nil; F.BrokenCatalog:=False;
    Prepare(F,Root,'ready-test',55.8); F.BrokenObject:=True;
    Ready:=TReadyTiles.Create(Http,'ready-test',13,256,Root,nil,'https://fixture.invalid/api/ready-tiles/v1',False);
    Ready.RefreshCatalog;
    Check(not Ready.Acquire(F.Id,'ready-test',M,Revision),'corrupt response admitted');
    Check(not Ready.Available(F.Id,'ready-test'),'corrupt object does not fall back to generation');
    Ready.Free; Ready:=nil; F.BrokenObject:=False;

    { The real tile cache and streamer use the same transport/cache, with no
      generator calls when the owner has already published the requested tile. }
    Cache:=TGeoTileCache.Create(Root+'geo','ready-test',13,256,55.7);
    Cache.ConfigureReadyTiles(Http);
    Deadline:=GetTickCount64+5000;
    repeat Sleep(10) until Cache.HasReady(F.Id) or (GetTickCount64>Deadline);
    Check(Cache.HasReady(F.Id),'background catalogue not ready');
    Center:=Cache.Grid.TileCenter(F.Id);
    Stream:=TTileStreamer.Create(Cache,Center,1,0,1,1);
    Stream.WantFilter:=@F.Wanted; Stream.OnGenerateBlock:=@F.Generate;
    Stream.SetPinnedTiles([F.Id]); Deadline:=GetTickCount64+5000;
    repeat
      Stream.Pump(Center,0.01); Stream.WantTile(F.Id,0,True);
      if Stream.TileReadyToShow(F.Id) then Break;
      Sleep(10);
    until GetTickCount64>Deadline;
    Check(Stream.TileReadyToShow(F.Id),'published geometry was not mounted');
    Check(F.GenerateCalls=0,'ready tile invoked generation');
    Stream.Free; Stream:=nil; Cache.Free; Cache:=nil;

    { An unavailable update server cannot delay already cached geometry. }
    F.Offline:=True; F.Delay:=600;
    Cache:=TGeoTileCache.Create(Root+'geo','ready-test',13,256,55.7);
    Cache.ConfigureReadyTiles(Http); StartTick:=GetTickCount64;
    Check(Cache.TryLoad(F.Id,M),'offline local geometry lost'); M.Free;
    Check(GetTickCount64-StartTick<300,'local tile waited for optional network check');
    Cache.Free; Cache:=nil; F.Offline:=False; F.Delay:=0;

    { Owner publishes a new object: check revision and update in background. }
    Prepare(F,Root,'ready-test',55.9);
    Cache:=TGeoTileCache.Create(Root+'geo','ready-test',13,256,55.7);
    Cache.ConfigureReadyTiles(Http);
    Check(Cache.TryLoad(F.Id,M),'old revision missing during update'); M.Free;
    Deadline:=GetTickCount64+5000;
    repeat Sleep(10) until (Cache.ReadyTiles.Status.Updated>0) or (GetTickCount64>Deadline);
    Check(Cache.ReadyTiles.Status.Updated>0,'new owner revision not installed');
    Check(Cache.TryLoad(F.Id,M),'updated model unavailable');
    Check(Abs(M.Origin.Lat-55.9)<0.00001,'old model remains after successful update'); M.Free;
    Cache.Free; Cache:=nil;

    F.Partial:=True; F.MissingId:=TGeoTileId.Make(0,True,F.Id.TX xor 1,F.Id.TY);
    Cache:=TGeoTileCache.Create(Root+'partial','ready-test',13,256,55.7);
    Cache.ConfigureReadyTiles(Http); Deadline:=GetTickCount64+5000;
    repeat Sleep(10) until Cache.HasReady(F.Id) or (GetTickCount64>Deadline);
    Stream:=TTileStreamer.Create(Cache,Center,2,0,1,1);
    Stream.WantFilter:=@F.Wanted; Stream.OnGenerateBlock:=@F.Generate;
    Stream.SetPinnedTiles([F.Id,F.MissingId]); Deadline:=GetTickCount64+5000;
    repeat
      Stream.Pump(Center,0.01); Stream.WantTile(F.Id,0,True); Stream.WantTile(F.MissingId,0,True);
      if Stream.TileReadyToShow(F.Id) and Stream.TileReadyToShow(F.MissingId) then Break;
      Sleep(10);
    until GetTickCount64>Deadline;
    Check(Stream.TileReadyToShow(F.Id) and Stream.TileReadyToShow(F.MissingId),'partial publication stranded neighbour');
    Stream.Free; Stream:=nil;
    Check(Cache.TryLoad(F.Id,M),'owner tile lost after neighbour generation');
    Check(Abs(M.Origin.Lat-55.9)<0.00001,'neighbour generation overwrote owner geometry'); M.Free;
    Cache.Free; Cache:=nil;

    Prepare(F,Root,'ready-test-k'+StringOfChar('b',32),56.2);
    Cache:=TGeoTileCache.Create(Root+'owner','private-route-a',13,256,55.7);
    Cache.ConfigureReadyTiles(Http,'ready-test'); Deadline:=GetTickCount64+5000;
    repeat Sleep(10) until Cache.HasReady(F.Id) or (GetTickCount64>Deadline);
    Check(Cache.HasReady(F.Id),'owner photo tile unavailable without local knowledge');
    Check(Cache.TryLoadReady(F.Id,M),'owner photo payload rejected');
    Check((M.GenHash='ready-test') and (Abs(M.Origin.Lat-56.2)<0.00001),'validated owner payload not retained');M.Free;
    Cache.Free; Cache:=nil; BeforeCalls:=F.Calls;
    Cache:=TGeoTileCache.Create(Root+'owner','different-private-route-b',13,256,55.7);
    Cache.ConfigureReadyTiles(nil,'ready-test');
    Check(Cache.Has(F.Id) and Cache.TryLoad(F.Id,M),'another route cannot reuse canonical owner tile');M.Free;
    Check(Cache.ValidateCached(F.Id,SizeBytes) and (SizeBytes>0),'offline audit misses universal tile');
    Check(F.Calls=BeforeCalls,'offline universal lookup requested network');
    Cache.Free; Cache:=nil;
    LocalRecipe(Root+'local-owner',F.Id,Center);
    Cache:=TGeoTileCache.Create(Root+'local-owner','ready-test',13,256,55.7);
    Check(Cache.Recipes.TileHash(F.Id)<>'','local recipe fixture failed');
    Cache.ConfigureReadyTiles(Http); Sleep(100);
    Check(not Cache.HasReady(F.Id),'owner silently overrides a private local recipe');
    Check(not Cache.TryLoadReady(F.Id,M),'incompatible owner recipe payload installed');
    Writeln('PASS: SHA256, read-only acquisition, common cache, offline reuse, malformed fallback, generation bypass, nonblocking cache, updates, partial coverage, owner photos without local knowledge, cross-route reuse and private recipe priority');
  finally Stream.Free; Cache.Free; Ready.Free; Http.Free; F.Free end;
end.
