unit Osm3dGeoTileGrid;

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$codepage UTF8}

interface

uses
  Classes,
  SysUtils,
  Math,
  Osm3dGeoMath,              { TLatLon(Box), DEG/RAD, EARTH_RADIUS_M, WEB_MERCATOR_MAX_LAT }
  Osm3dStudioSettings        { GEO_TILE_EDGE_PX — single source of truth for the tile edge }
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
;

const
  { Tile edge — GEO_TILE_EDGE_PX (heightmap pixels at HeightmapZoom) — lives
    in Osm3dStudioSettings, the single edit point for world scale. The
    WGS-84 / UTM constants below are kept for the legacy helpers. }

  { One slippy tile is 256 px; the full slippy grid is SLIPPY_TILE_PIXELS *
    2^zoom px wide. }
  SLIPPY_TILE_PIXELS = 256;

  { WGS-84 ellipsoid + UTM constants — legacy (UTMForward/UTMInverse only). }
  WGS84_A            = 6378137.0;
  WGS84_F            = 1.0 / 298.257223563;
  UTM_K0             = 0.9996;
  UTM_FALSE_EASTING  = 500000.0;
  UTM_FALSE_NORTHING = 10000000.0;     { added on the southern hemisphere }

type
  { One ground tile. (TX,TY) index the slippy EdgePx-pixel lattice at the
    grid's zoom. Zone/North are frozen (Zone=0, North=True) — see unit
    header; kept for call-site / record-layout compatibility only. }
  TGeoTileId = record
    Zone:  Byte;        { frozen 0 — no UTM zones in the slippy grid }
    North: Boolean;     { frozen True }
    TX:    Cardinal;    { global pixel X div EdgePx }
    TY:    Cardinal;    { global pixel Y div EdgePx }

    class function Make(AZone: Byte; ANorth: Boolean;
                        ATX, ATY: Cardinal): TGeoTileId; static;
    function Equals(const Other: TGeoTileId): Boolean;
    { Stable human-readable form, e.g. 'Z0N/12345/6789'. }
    function ToString: string;
    { Bijective numeric key for hot-path dictionaries/sets: TY in the high
      dword, TX in the low. Zone/North are frozen (see above), so they do
      not participate — two ids with equal (TX,TY) are the same tile. }
    function ToKey: Int64;
  end;
  TGeoTileIdArray = array of TGeoTileId;

{ Legacy UTM transverse-Mercator (Snyder series) — kept for the streamer
 and block generator until their call sites move to slippy. }

function ZoneOfLon(Lon: Double): Byte; inline;

type
  { Slippy-pixel tile grid. One instance is shared by the cache. }
  TGeoTileGrid = class
  private
    FZoom:      Integer;     { slippy zoom = HeightmapZoom }
    FEdgePx:    Integer;     { heightmap pixels per tile edge }
    FInvEdgePx: Double;      { 1/FEdgePx, calculated in Double precision }
    FWorldPx:   Double;      { SLIPPY_TILE_PIXELS * 2^Zoom }
    FRefLatDeg: Double;      { reference latitude for the nominal EdgeMeters }

    function GetEdgeMeters: Double;
  public
    { AHeightmapZoom MUST match the zoom the heightmap tiles are fetched at
      (TStudioSettings.HeightmapZoom) — that is what makes tile edges land
      on heightmap pixel lines. ARefLatDeg sets the latitude at which the
      reported (nominal) EdgeMeters is evaluated; 0 = equator. }
    constructor Create(AHeightmapZoom: Integer;
                       AEdgePx: Integer = 0;
                       ARefLatDeg: Double = 0.0);

    { No-op. The slippy grid has no UTM zones — one continuous global
      coordinate — so there is nothing to pin. Retained so existing callers
      (BeginGeoTiling / SplitInputToTiles / streaming map) compile unchanged. }

    { lat/lon -> the tile that contains the point. }
    function TileAt(const P: TLatLon): TGeoTileId;
    { Fractional global slippy pixel of P at this grid's zoom — the exact
      intermediate TileAt floors (same Web-Mercator lat clamp and [0,WorldPx)
      clamp), so Floor(PixelOf/EdgePx) == TileAt.TX/TY. Lets callers (the
      streamer keyhole) work at sub-tile precision without UTM. }
    procedure PixelOf(const P: TLatLon; out APX, APY: Double);

    { Exact geographic bounds of a tile. The slippy grid is lon-linear and
      lat-monotonic, so the box is axis-aligned in lat/lon and the bounds
      come straight from the two opposite pixel corners. }
    function TileBox(const T: TGeoTileId): TLatLonBox;
    function TileCenter(const T: TGeoTileId): TLatLon;

    { Every tile whose cell intersects Box. Axis-aligned in slippy space, so
      this is a plain rectangular sweep of the corner tiles (no half-edge
      sampling, no zone crossings). }
    function TilesCovering(const Box: TLatLonBox): TGeoTileIdArray;

    { (TX,TY) -> Z-order code (32 bits per axis spread into 64). }
    class function Morton(TX, TY: Cardinal): QWord;
    { Base-4 quadkey of Morton(TX,TY). Keeps the legacy 24 digits for
      24-bit indices; larger indices use 32 digits without truncation. }
    class function QuadKey(const T: TGeoTileId): string;

    { Representative metric tile edge at the reference latitude — for the
      streamer's radius->tiles estimate and the block halo. The TRUE metric
      edge varies with latitude (Web-Mercator); this is a single
      representative value, not an exact per-tile size. }
    property EdgeMeters: Double read GetEdgeMeters;
    function EdgeMetersAt(LatDeg: Double): Double;

    property Zoom:    Integer read FZoom;
    property EdgePx:  Integer read FEdgePx;
    property WorldPx: Double  read FWorldPx;
  end;

implementation

class function TGeoTileId.Make(AZone: Byte; ANorth: Boolean;
  ATX, ATY: Cardinal): TGeoTileId;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1054);{$ENDIF}
  { Zone/North are frozen by the grid; Make stores whatever is passed so
    existing call sites compile unchanged. Pass 0/True for grid-consistent
    IDs. }
  Result.Zone  := AZone;
  Result.North := ANorth;
  Result.TX    := ATX;
  Result.TY    := ATY;
end;

function TGeoTileId.Equals(const Other: TGeoTileId): Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(138);{$ENDIF}
  Result := (Zone = Other.Zone) and (North = Other.North) and
            (TX = Other.TX) and (TY = Other.TY);
end;

function TGeoTileId.ToString: string;
const HemiCh: array[Boolean] of Char = ('S', 'N');
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(139);{$ENDIF}
  Result := Format('Z%d%s/%d/%d',
    [Zone, HemiCh[North], Integer(TX), Integer(TY)]);
end;

function TGeoTileId.ToKey: Int64;
begin
  Result := (Int64(TY) shl 32) or Int64(TX);
end;

function ZoneOfLon(Lon: Double): Byte; inline;
var Z: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(141);{$ENDIF}
  Z := Floor((Lon + 180.0) / 6.0) + 1;
  if Z < 1  then Z := 1;
  if Z > 60 then Z := 60;
  Result := Z;
end;

const
  { Derived WGS-84 / UTM quantities — constant expressions folded by the
    compiler. }
  UTM_E2  = WGS84_F * (2.0 - WGS84_F);            { first eccentricity^2 }
  UTM_EP2 = UTM_E2 / (1.0 - UTM_E2);              { second eccentricity^2 }

  { Meridional-arc series coefficients M0..M3 (Snyder eq. 3-21). }
  UTM_M0 = 1.0 - UTM_E2/4.0 - 3.0*UTM_E2*UTM_E2/64.0
               - 5.0*UTM_E2*UTM_E2*UTM_E2/256.0;
  UTM_M1 = 3.0*UTM_E2/8.0 + 3.0*UTM_E2*UTM_E2/32.0
               + 45.0*UTM_E2*UTM_E2*UTM_E2/1024.0;
  UTM_M2 = 15.0*UTM_E2*UTM_E2/256.0 + 45.0*UTM_E2*UTM_E2*UTM_E2/1024.0;
  UTM_M3 = 35.0*UTM_E2*UTM_E2*UTM_E2/3072.0;

constructor TGeoTileGrid.Create(AHeightmapZoom: Integer;
  AEdgePx: Integer; ARefLatDeg: Double);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1055);{$ENDIF}
  inherited Create;
  if AHeightmapZoom < 0  then AHeightmapZoom := 0;
  if AHeightmapZoom > 22 then AHeightmapZoom := 22;
  if AEdgePx < 1 then AEdgePx := GEO_TILE_EDGE_PX;
  FZoom      := AHeightmapZoom;
  FEdgePx    := AEdgePx;
  FInvEdgePx := Double(1.0) / AEdgePx;
  FWorldPx   := SLIPPY_TILE_PIXELS * IntPower(2.0, AHeightmapZoom);
  FRefLatDeg := ARefLatDeg;
end;

procedure TGeoTileGrid.PixelOf(const P: TLatLon; out APX, APY: Double);
var
  Lat, LatRad, MaxPixel: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1411);{$ENDIF}
  Lat := P.Lat;
  if Lat >  WEB_MERCATOR_MAX_LAT then Lat :=  WEB_MERCATOR_MAX_LAT;
  if Lat < -WEB_MERCATOR_MAX_LAT then Lat := -WEB_MERCATOR_MAX_LAT;
  LatRad := Lat * DEG_TO_RAD;

  { Global slippy pixel of P — identical formula to TTileMath.LatLonToTile
    and TerrainGridOf's GPX0/GPY0, so the tile grid and the terrain lattice
    are phased to the same pixel grid. }
  APX := (P.Lon + 180.0) / 360.0 * FWorldPx;
  APY := (1.0 - Ln(Tan(LatRad) + 1.0 / Cos(LatRad)) / Pi) / 2.0 * FWorldPx;

  if APX < 0.0       then APX := 0.0;
  if APY < 0.0       then APY := 0.0;
  { WorldPx is a power of two. Its preceding Double keeps the eastern
    and southern boundaries inside the last cell, including exact +180. }
  MaxPixel := FWorldPx - FWorldPx / 9007199254740992.0;
  if APX > MaxPixel then APX := MaxPixel;
  if APY > MaxPixel then APY := MaxPixel;
end;

function TGeoTileGrid.TileAt(const P: TLatLon): TGeoTileId;
var
  GPX, GPY: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(144);{$ENDIF}
  PixelOf(P, GPX, GPY);
  Result.Zone  := 0;
  Result.North := True;
  Result.TX := Cardinal(Floor(GPX * FInvEdgePx));
  Result.TY := Cardinal(Floor(GPY * FInvEdgePx));
end;

function TGeoTileGrid.TileBox(const T: TGeoTileId): TLatLonBox;
var
  PX0, PX1, PY0, PY1: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(145);{$ENDIF}
  PX0 := T.TX * Double(FEdgePx);  PX1 := PX0 + FEdgePx;
  PY0 := T.TY * Double(FEdgePx);  PY1 := PY0 + FEdgePx;   { PY grows southward }
  Result.MinLon :=  PX0 / FWorldPx * 360.0 - 180.0;
  Result.MaxLon :=  PX1 / FWorldPx * 360.0 - 180.0;
  Result.MaxLat := ArcTan(Sinh(Pi * (1.0 - 2.0 * PY0 / FWorldPx))) * RAD_TO_DEG;
  Result.MinLat := ArcTan(Sinh(Pi * (1.0 - 2.0 * PY1 / FWorldPx))) * RAD_TO_DEG;
end;

function TGeoTileGrid.TileCenter(const T: TGeoTileId): TLatLon;
var
  GPX, GPY: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(146);{$ENDIF}
  GPX := (T.TX + 0.5) * FEdgePx;
  GPY := (T.TY + 0.5) * FEdgePx;
  Result.Lon := GPX / FWorldPx * 360.0 - 180.0;
  Result.Lat := ArcTan(Sinh(Pi * (1.0 - 2.0 * GPY / FWorldPx))) * RAD_TO_DEG;
end;

function TGeoTileGrid.TilesCovering(const Box: TLatLonBox): TGeoTileIdArray;
var
  TL, BR: TGeoTileId;
  X, Y, Idx: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(148);{$ENDIF}
  Result := nil;
  if Box.IsEmpty then Exit;

  { Top-left = (MaxLat, MinLon); bottom-right = (MinLat, MaxLon). }
  TL := TileAt(TLatLon.Make(Box.MaxLat, Box.MinLon));
  BR := TileAt(TLatLon.Make(Box.MinLat, Box.MaxLon));
  if (BR.TX < TL.TX) or (BR.TY < TL.TY) then Exit;   { defensive }

  SetLength(Result, (BR.TY - TL.TY + 1) * (BR.TX - TL.TX + 1));
  Idx := 0;
  for Y := Integer(TL.TY) to Integer(BR.TY) do
    for X := Integer(TL.TX) to Integer(BR.TX) do
    begin
      Result[Idx].Zone  := 0;
      Result[Idx].North := True;
      Result[Idx].TX    := Cardinal(X);
      Result[Idx].TY    := Cardinal(Y);
      Inc(Idx);
    end;
end;

class function TGeoTileGrid.Morton(TX, TY: Cardinal): QWord;

  { Spread all 32 input bits into the even positions of a 64-bit result. }
  function Part1By1(n: QWord): QWord;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(149);{$ENDIF}
    n := n and $00000000FFFFFFFF;
    n := (n or (n shl 16)) and $0000FFFF0000FFFF;
    n := (n or (n shl 8))  and $00FF00FF00FF00FF;
    n := (n or (n shl 4))  and $0F0F0F0F0F0F0F0F;
    n := (n or (n shl 2))  and $3333333333333333;
    n := (n or (n shl 1))  and $5555555555555555;
    Result := n;
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1056);{$ENDIF}
  Result := Part1By1(TX) or (Part1By1(TY) shl 1);
end;

class function TGeoTileGrid.QuadKey(const T: TGeoTileId): string;
var
  M: QWord;
  I, D, Digits: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1057);{$ENDIF}
  Result := '';
  M := Morton(T.TX, T.TY);
  Digits := 24;
  if (T.TX > $FFFFFF) or (T.TY > $FFFFFF) then Digits := 32;
  SetLength(Result, DIGITS);
  for I := 0 to DIGITS - 1 do
  begin
    D := (M shr ((DIGITS - 1 - I) * 2)) and 3;
    Result[I + 1] := Chr(Ord('0') + D);
  end;
end;

function TGeoTileGrid.EdgeMetersAt(LatDeg: Double): Double;
var
  c: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1412);{$ENDIF}
  c := Cos(LatDeg * DEG_TO_RAD);
  if c < 0.01 then c := 0.01;
  { Web-Mercator ground resolution: metres-per-pixel = cos(lat) * earth
    circumference / WorldPx; tile edge = EdgePx * that. NB: окружность тут
    2π·EARTH_RADIUS_M (средний радиус), а в Osm3dSlippyMap — экваториальная
    (2π·6378137); расхождение ~0.11 % на метрике ребра тайла — осознанное,
    тайловые ИНДЕКСЫ отсюда не вычисляются. }
  Result := FEdgePx * c * (2.0 * Pi * EARTH_RADIUS_M) / FWorldPx;
end;

function TGeoTileGrid.GetEdgeMeters: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1413);{$ENDIF}
  Result := EdgeMetersAt(FRefLatDeg);
end;

end.
