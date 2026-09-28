unit Osm3dAccessoryAtlas;

{ Accessory sprite atlas — small animated decorations packed one sprite per
  256px cell. The first accessory is the traffic-light head: its five states
  (red / yellow / green / off / undefined) live as cells, and a per-tile
  switch selects a mesh with the current cell's UVs. Diffuse
  channel only, NO gutter — each cell fills its whole 256px, so it maps 1:1 onto
  the box's [0,1] UV mapped into the selected sprite's cell.

  Built + cached exactly like the ground/building/fence atlases
  (TCompositeAtlasBase), so it rides the same on-disk PNG + file:// URL texture
  path (TryLoadFromCache / BuildImage / SaveToCache / CreateTextureNodeUrl). }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, CastleVectors, Osm3dCompositeAtlas;

type
  { Cell index = sprite. Order is fixed so the blink logic can index it directly. }
  TAccessorySprite = (
    asTrafficRed,
    asTrafficYellow,
    asTrafficGreen,
    asTrafficOff,
    asTrafficUndefined
  );

const
  ACCESSORY_CELL_PX      = 256;
  ACCESSORY_SPRITE_COUNT = Ord(High(TAccessorySprite)) + 1;   { 5 }
  { Sprite PNGs live in the same models tree as the tree/grass textures. }
  ACCESSORY_TEX_DIR      = 'castle-data:/Osm3d/resources/models/traffic_light/';
  { Traffic-light phase durations (s): a full cycle is green -> yellow -> red. }
  ACCESSORY_TL_GREEN_S  = 5.0;
  ACCESSORY_TL_YELLOW_S = 1.5;
  ACCESSORY_TL_RED_S    = 5.0;

type
  TAccessoryAtlas = class(TCompositeAtlasBase)
  protected
    function LogPrefix: string; override;
    function CacheFileName(Ch: TAtlasChannel): string; override;
    function MaterialCount: Integer; override;
    function MaterialInfo(MatId: Integer): TAtlasMaterialInfo; override;
    function CellGutter: Integer; override;   { 0 — a sprite fills its whole cell }
    function BuildSignature: string; override;
  public
    constructor Create; reintroduce;

    { U extent of sprite Index's cell: [CellUMin, CellUMax] x [0,1]. The
      traffic-light box bakes these straight into its mesh UVs (one shape per
      state), so no TextureTransform is involved. Class functions — the caller
      only needs the sprite index. }
    class function CellUMin(Index: Integer): Single;
    class function CellUMax(Index: Integer): Single;
  end;

{ Single-row 256px grid, one cell per sprite. }
function DefaultAccessoryAtlasLayout: TAtlasLayout;

implementation

uses CastleUriUtils;

function DefaultAccessoryAtlasLayout: TAtlasLayout;
begin
  Result.GridCols   := ACCESSORY_SPRITE_COUNT;
  Result.GridRows   := 1;
  Result.TilePixels := ACCESSORY_CELL_PX;
end;

constructor TAccessoryAtlas.Create;
begin
  inherited Create(DefaultAccessoryAtlasLayout, [acDiffuse]);
end;

function TAccessoryAtlas.LogPrefix: string;
begin
  Result := 'accessory-atlas';
end;

function TAccessoryAtlas.CacheFileName(Ch: TAtlasChannel): string;
begin
  { diffuse-only atlas — a single cached PNG }
  Result := 'accessory_diffuse.png';
end;

function TAccessoryAtlas.MaterialCount: Integer;
begin
  Result := ACCESSORY_SPRITE_COUNT;
end;

function TAccessoryAtlas.CellGutter: Integer;
begin
  Result := 0;
end;

function TAccessoryAtlas.MaterialInfo(MatId: Integer): TAtlasMaterialInfo;
const
  { index order MUST match TAccessorySprite }
  FILES: array[0 .. ACCESSORY_SPRITE_COUNT - 1] of string =
    ('red.png', 'yellow.png', 'green.png', 'off.png', 'undefined.png');
begin
  if (MatId < 0) or (MatId >= ACCESSORY_SPRITE_COUNT) then
    MatId := Ord(asTrafficOff);
  Result.Name          := ChangeFileExt(FILES[MatId], '');
  { Resolve against the application's data directory, independent of its CWD. }
  Result.DiffusePath   := URIToFilenameSafe(ACCESSORY_TEX_DIR + FILES[MatId]);
  Result.NormalPath    := '';
  Result.MaskPath      := '';
  Result.FallbackColor := Vector3(0, 0, 0);   { black cell if the PNG is missing }
  Result.Roughness     := 1.0;
end;

function TAccessoryAtlas.BuildSignature: string;
var
  I: Integer;
begin
  Result := inherited BuildSignature;
  { Missing sprites used to leave a valid, all-black atlas in the shared cache.
    Invalidate it when a source is installed, removed or updated. This affects
    only the small accessory atlas, not the ground/building atlases. }
  for I := 0 to ACCESSORY_SPRITE_COUNT - 1 do
    Result := Result + ';source=' + IntToStr(FileAge(MaterialInfo(I).DiffusePath));
end;

class function TAccessoryAtlas.CellUMin(Index: Integer): Single;
begin
  if (Index < 0) or (Index >= ACCESSORY_SPRITE_COUNT) then
    Index := Ord(asTrafficOff);
  Result := Index / ACCESSORY_SPRITE_COUNT;
end;

class function TAccessoryAtlas.CellUMax(Index: Integer): Single;
begin
  if (Index < 0) or (Index >= ACCESSORY_SPRITE_COUNT) then
    Index := Ord(asTrafficOff);
  Result := (Index + 1) / ACCESSORY_SPRITE_COUNT;
end;

end.
