program OverpassRegionCompletenessTests;
{$mode objfpc}{$H+}

uses SysUtils, Classes, Osm3dCache, Osm3dCacheHTTPFetcher,
  Osm3dGeoMath, Osm3dOsmData, Osm3dOsmOverpass;

type
  TProgress = class
    Client: TOverpassClient;
    StopAfterFirst, CancelFirst: Boolean;
    Calls: Integer;
    procedure Tile(Sender: TObject; const Id: TTileXY;
      TileIndex, TileTotal: Integer; Success: Boolean;
      BytesGot: Integer; ElapsedMs: Int64;
      const Endpoint, ErrorMsg: string; var Cancel: Boolean);
  end;

procedure Check(Value: Boolean; const Msg: string);
begin
  if not Value then raise Exception.Create(Msg);
end;

procedure TProgress.Tile(Sender: TObject; const Id: TTileXY;
  TileIndex, TileTotal: Integer; Success: Boolean;
  BytesGot: Integer; ElapsedMs: Int64;
  const Endpoint, ErrorMsg: string; var Cancel: Boolean);
begin
  Inc(Calls);
  if StopAfterFirst and (Calls = 1) then Client.Endpoints.Clear;
  if CancelFirst and (Calls = 1) then Cancel := True;
end;

procedure Run(const EmptySource, FailFirst, FailSecond, CancelFirst: Boolean);
var
  Cache: TMemoryCache;
  Fetcher: THTTPFetcherWithCache;
  Client: TOverpassClient;
  Progress: TProgress;
  Region: TLatLonBox;
  Tiles: TTileXYArray;
  Ds: TOSMDataset;
  I: Integer;
  Query, Body: string;
  Bytes: TBytes;
  Failed, Cancelled: Boolean;
begin
  Cache := TMemoryCache.Create;
  Fetcher := THTTPFetcherWithCache.Create(Cache, True);
  Client := TOverpassClient.Create(Fetcher, 'http://127.0.0.1:1/api/interpreter');
  Progress := TProgress.Create;
  try
    Client.TileZoom := 3;
    Region := TLatLonBox.Make(1, -1, 2, 1); { two adjacent source tiles }
    Tiles := TTileMath.TilesCoveringBox(Region, Client.TileZoom);
    Check(Length(Tiles) = 2, 'fixture must cover two source tiles');
    for I := 0 to High(Tiles) do
    begin
      Query := TOverpassQueryExt.BuildCombinedFull(TTileMath.TileToLatLonBox(Tiles[I]),
        DefaultFlagsForFullScene, Client.TimeoutS);
      if EmptySource then Body := '{"version":0.6,"elements":[]}'
      else Body := Format('{"version":0.6,"elements":[{"type":"node","id":%d,"lat":1.5,"lon":0}]}', [I + 1]);
      SetLength(Bytes, Length(Body));
      Move(Body[1], Bytes[0], Length(Body));
      Cache.Put(OverpassCacheKey(Query), Bytes, TCacheMetadata.Make('application/json'));
    end;
    Progress.Client := Client;
    Progress.StopAfterFirst := FailSecond;
    Progress.CancelFirst := CancelFirst;
    Client.OnTileProgress := @Progress.Tile;
    if FailFirst then Client.Endpoints.Clear;
    Ds := nil; Failed := False; Cancelled := False;
    try
      Ds := Client.GetRegion(Region);
    except
      on E: EAbort do Cancelled := True;
      on E: EOSMError do
      begin
        Failed := True;
        Check(Pos('OSM tile 3/', E.Message) > 0, 'failure must identify the source tile');
      end;
    end;
    try
      Check(Failed = (FailFirst or FailSecond), 'failed source returned a partial/empty region');
      Check(Cancelled = CancelFirst, 'cancellation was swallowed');
      if Failed or Cancelled then Check(Ds = nil, 'incomplete dataset escaped')
      else if EmptySource then Check(Ds.Nodes.Count = 0, 'valid empty region was rejected')
      else Check(Ds.Nodes.Count = 2, 'complete source was not merged');
    finally Ds.Free end;

    { Same client, same tile IDs: failure/cancellation must not cache empty data
      or leave the loading marker set (which would hang on the second request). }
    Progress.StopAfterFirst := False;
    Progress.CancelFirst := False;
    Client.Endpoints.Clear;
    Client.Endpoints.Add('http://127.0.0.1:1/api/interpreter');
    Ds := Client.GetRegion(Region);
    try
      if EmptySource then Check(Ds.Nodes.Count = 0, 'empty retry')
      else Check(Ds.Nodes.Count = 2, 'retry did not recover the complete region');
    finally Ds.Free end;
  finally
    Client.Free;
    Progress.Free;
    Fetcher.Free;
  end;
end;

begin
  Run(False, False, False, False);
  Run(True, False, False, False);
  Run(False, True, False, False);
  Run(False, False, True, False);
  Run(False, False, False, True);
  Writeln('PASS: complete, valid empty, total failure, partial failure, cancellation, retry');
end.
