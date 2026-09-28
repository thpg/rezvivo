unit Osm3dGeoTileBlock;

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$codepage UTF8}

interface

uses
  SysUtils,
  Osm3dGeoMath,
  Osm3dGeoTileGrid,
  Osm3dStudioSettings        { GEO_BLOCK_SIZE — single source of truth for block size }
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
;

type
  { Identifies one block. (BX,BY) index the block lattice, exactly as
    (TX,TY) index the tile lattice. Zone/North are frozen (0/True) — see
    Osm3dGeoTileGrid; carried here only for record-layout / call-site
    compatibility. }
  TBlockId = record
    Zone:  Byte;
    North: Boolean;
    BX:    Cardinal;
    BY:    Cardinal;

    class function Make(AZone: Byte; ANorth: Boolean;
                        ABX, ABY: Cardinal): TBlockId; static;
    function Equals(const Other: TBlockId): Boolean;
    { Stable key, usable as a dictionary key, e.g. 'B0N/12/45'. }
    function ToString: string;
  end;
  TBlockIdArray = array of TBlockId;

  { Фаза загрузки/генерации блока — для индикатора прогресса тайла. }
  TBlockPhase = (bpWait,        { в очереди, воркер ещё не взял }
                 bpHeightmap,   { качается карта высот (HTTP) }
                 bpOverpass,    { качаются OSM-данные (HTTP) }
                 bpGeom);       { строится геометрия }

{ The block that owns geo-tile T. }
function BlockOf(const T: TGeoTileId;
  ABlockSize: Integer = 0): TBlockId;

{ All BlockSize*BlockSize geo-tiles of block B (row-major). }
function BlockTiles(const B: TBlockId;
  ABlockSize: Integer = 0): TGeoTileIdArray;

{ Geographic bounds of B's tiles, expanded by AHaloMeters on each side.
  AGrid supplies the geo projection (slippy) — it must be the same grid
  instance used elsewhere so the box matches the tiles exactly. }
function BlockHaloBox(const B: TBlockId; AGrid: TGeoTileGrid;
  AHaloMeters: Double;
  ABlockSize: Integer = 0): TLatLonBox;

{ Cached geometry is baked in its block's latitude band. Use the same
  east/west conversion for rendering, road snapping and contact geometry. }
function TileFrameScaleX(const T: TGeoTileId; AGrid: TGeoTileGrid;
  AFrameScaleLat, AManualScaleLat: Double): Double;

implementation

function TileFrameScaleX(const T: TGeoTileId; AGrid: TGeoTileGrid;
  AFrameScaleLat, AManualScaleLat: Double): Double;
var BakeLat: Double;
begin
  if (AManualScaleLat > -90) and (AManualScaleLat < 90) and
     (AManualScaleLat <> 0) then BakeLat := AManualScaleLat
  else BakeLat := WorldScaleLatBand(BlockHaloBox(BlockOf(T), AGrid, 0).Center.Lat);
  Result := Cos(AFrameScaleLat * DEG_TO_RAD) / Cos(BakeLat * DEG_TO_RAD);
end;

const
  HemiSeg: array[Boolean] of string = ('S', 'N');

class function TBlockId.Make(AZone: Byte; ANorth: Boolean;
  ABX, ABY: Cardinal): TBlockId;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1051);{$ENDIF}
  Result.Zone  := AZone;
  Result.North := ANorth;
  Result.BX    := ABX;
  Result.BY    := ABY;
end;

function TBlockId.Equals(const Other: TBlockId): Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(118);{$ENDIF}
  Result := (Zone = Other.Zone) and (North = Other.North) and
            (BX = Other.BX) and (BY = Other.BY);
end;

function TBlockId.ToString: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(119);{$ENDIF}
  Result := Format('B%d%s/%d/%d',
    [Zone, HemiSeg[North], Integer(BX), Integer(BY)]);
end;

function BlockOf(const T: TGeoTileId; ABlockSize: Integer): TBlockId;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(120);{$ENDIF}
  if ABlockSize < 1 then ABlockSize := GEO_BLOCK_SIZE;
  Result.Zone  := T.Zone;
  Result.North := T.North;
  Result.BX    := T.TX div Cardinal(ABlockSize);
  Result.BY    := T.TY div Cardinal(ABlockSize);
end;

function BlockTiles(const B: TBlockId; ABlockSize: Integer): TGeoTileIdArray;
var
  TX0, TY0, IX, IY, N: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(121);{$ENDIF}
  if ABlockSize < 1 then ABlockSize := GEO_BLOCK_SIZE;
  TX0 := Integer(B.BX) * ABlockSize;
  TY0 := Integer(B.BY) * ABlockSize;
  SetLength(Result, ABlockSize * ABlockSize);
  N := 0;
  for IY := 0 to ABlockSize - 1 do
    for IX := 0 to ABlockSize - 1 do
    begin
      Result[N].Zone  := B.Zone;
      Result[N].North := B.North;
      Result[N].TX    := Cardinal(TX0 + IX);
      Result[N].TY    := Cardinal(TY0 + IY);
      Inc(N);
    end;
end;

function BlockHaloBox(const B: TBlockId; AGrid: TGeoTileGrid;
  AHaloMeters: Double; ABlockSize: Integer): TLatLonBox;
var
  TL, BR: TGeoTileId;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(122);{$ENDIF}
  if ABlockSize < 1 then ABlockSize := GEO_BLOCK_SIZE;
  if AGrid = nil then Exit(TLatLonBox.Empty);

  { The block's two opposite corner tiles (Zone/North frozen 0/True). }
  TL := TGeoTileId.Make(0, True,
          B.BX * Cardinal(ABlockSize),
          B.BY * Cardinal(ABlockSize));
  BR := TGeoTileId.Make(0, True,
          B.BX * Cardinal(ABlockSize) + Cardinal(ABlockSize) - 1,
          B.BY * Cardinal(ABlockSize) + Cardinal(ABlockSize) - 1);

  { Union of the two opposite corner-tile boxes = the whole block box: the
    slippy grid is lon-linear and lat-monotonic, so the block's lat/lon
    bounds come straight from its NW and SE corner tiles. TileBox is the
    single source of the slippy inverse — no formula duplicated here. }
  Result := AGrid.TileBox(TL).Union(AGrid.TileBox(BR));

  { Expand by the halo margin (metres -> degrees via the box centre).
    Halo is overscan context, so the metric-vs-mercator difference at the
    margin is irrelevant. }
  if AHaloMeters > 0 then
    Result := Result.ExpandMeters(AHaloMeters);
end;

end.
