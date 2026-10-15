unit Osm3dMapOverview;
{$mode objfpc}{$H+}
interface
uses SysUtils,Osm3dGeoMath;
function MapOverviewQuery(const Tile:TTileXY):string;
function MapSourceZoom(DisplayZoom:Integer):Integer;
implementation
uses Math,Osm3dOsmOverpass;
function MapSourceZoom(DisplayZoom:Integer):Integer;
begin
  if DisplayZoom>=12 then Result:=OVERPASS_TILE_ZOOM_DEFAULT
  else Result:=EnsureRange(DisplayZoom,0,11);
end;
function MapOverviewQuery(const Tile:TTileXY):string;
var B:TLatLonBox;Places,Roads:string;Fmt:TFormatSettings;
begin
  B:=TTileMath.TileToLatLonBox(Tile);Fmt:=DefaultFormatSettings;Fmt.DecimalSeparator:='.';
  Places:='country|continent';Roads:='';
  if Tile.Zoom>=5 then Places:=Places+'|city';
  if Tile.Zoom>=8 then Places:=Places+'|town';
  if Tile.Zoom>=10 then Places:=Places+'|village';
  if Tile.Zoom>=7 then Roads:='motorway|trunk';
  if Tile.Zoom>=9 then Roads:=Roads+'|primary|secondary';
  if Tile.Zoom>=11 then Roads:=Roads+'|tertiary';
  Result:=Format('[bbox:%.7f,%.7f,%.7f,%.7f][out:json][timeout:25];(',
    [B.MinLat,B.MinLon,B.MaxLat,B.MaxLon],Fmt)+
    'node["place"~"^('+Places+')$"];';
  if Roads<>''then Result:=Result+'way["highway"~"^('+Roads+')(_link)?$"];';
  if Tile.Zoom>=10 then Result:=Result+
    'way["natural"~"^(water|wood|scrub|sand|beach|grassland)$"];'+
    'way["landuse"~"^(forest|reservoir|farmland|meadow|residential|industrial)$"];'+
    'relation["type"="multipolygon"]["natural"~"^(water|wood)$"];'+
    'relation["type"="multipolygon"]["landuse"~"^(forest|reservoir)$"];'+
    'way["waterway"="river"];';
  Result:=Result+');(._;>;);out body;';
end;
end.
