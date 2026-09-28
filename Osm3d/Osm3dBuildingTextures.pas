unit Osm3dBuildingTextures;

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$codepage UTF8}

interface

uses
  Classes, SysUtils
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
;

const
  BUILDING_TEX_ROOT  = 'data/Osm3d/resources/textures/';
  FACADE_TEX_DIR     = BUILDING_TEX_ROOT + 'buildings/facades/';
  ROOF_TEX_DIR       = BUILDING_TEX_ROOT + 'buildings/roofs/';

{ Facade material name for a wall palette; files are '<name>_window_<channel>.png'.
  0..5 OSM materials; 6..9 plaster (tinted via BUILDING_WALL_BASE). }
function WallMaterialName(Palette: Integer): string;

{ Roof material name for a roof palette (0..5); files are '<name>_<channel>.png'. }
function RoofMaterialName(Palette: Integer): string;

{ Window glow-map filename for a wall palette; pairs with that window material. }
function WallGlowFile(Palette: Integer): string;

implementation

const
  { Facade wall material per palette index; 0 and 5 are fallbacks (no semantic material). }
  WALL_MATERIAL: array[0..5] of string = (
    'plaster',   { 0 generic fallback }
    'wood',      { 1 wood }
    'plaster',   { 2 plaster / concrete }
    'block',     { 3 cement block / glass }
    'brick',     { 4 brick }
    'block'      { 5 generic fallback }
  );

  { Roof material per palette index. }
  ROOF_MATERIAL: array[0..5] of string = (
    'tiles',
    'metal',
    'concrete',
    'tar',
    'eternit',
    'thatch'
  );

  { Per-material window glow map (marks glass panes). MUST match the diffuse's pane
    layout, so it cannot be one shared file. Indexed like WALL_MATERIAL. }
  WALL_GLOW: array[0..5] of string = (
    'window1_glow.png',   { 0 plaster }
    'window0_glow.png',   { 1 wood }
    'window1_glow.png',   { 2 plaster }
    'window1_glow.png',   { 3 block }
    'window0_glow.png',   { 4 brick }
    'window1_glow.png'    { 5 block }
  );

function WallMaterialName(Palette: Integer): string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(9);{$ENDIF}
  if Palette > 5 then Palette := 0;   { hash tints: plaster + colour }
  if (Palette < 0) or (Palette > 5) then Palette := 0;
  Result := WALL_MATERIAL[Palette];
end;

function RoofMaterialName(Palette: Integer): string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(10);{$ENDIF}
  if (Palette < 0) or (Palette > 5) then Palette := 0;
  Result := ROOF_MATERIAL[Palette];
end;

function WallGlowFile(Palette: Integer): string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(11);{$ENDIF}
  if Palette > 5 then Palette := 0;
  if (Palette < 0) or (Palette > 5) then Palette := 0;
  Result := WALL_GLOW[Palette];
end;

end.
