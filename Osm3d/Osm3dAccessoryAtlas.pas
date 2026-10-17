unit Osm3dAccessoryAtlas;

{ Accessory sprite atlas — small animated decorations packed one sprite per
  256px cell. The first accessory is the traffic-light head: its five states
  (red / yellow / green / off / undefined) live as cells. One immutable head
  mesh selects the current cell through a per-tile shader uniform. Diffuse
  channel only, NO gutter — each cell fills its whole 256px, so it maps 1:1 onto
  the box's [0,1] UV mapped into the selected sprite's cell.

  Built + cached exactly like the ground/building/fence atlases
  (TCompositeAtlasBase), so it rides the same on-disk PNG + file:// URL texture
  path (TryLoadFromCache / BuildImage / SaveToCache / CreateTextureNodeUrl). }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, CastleVectors, X3DNodes, X3DFields, Osm3dCompositeAtlas;

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

  { The immutable source UVs are the old green phase: perpendicular faces
    use red [0,.2], primary faces green [.4,.6]. Select their exact atlas
    endpoints in the vertex stage, before perspective interpolation. No
    arithmetic offset/fragment branch changes the old filtering or mips.
    The dedicated attribute avoids depending on CGE's sampler texture unit.
    This mesh has one standard UV channel (mapping 0). CGE initializes its
    castle_TexCoord0 before the appearance vertex_eye_space hook. Override
    that varying, keeping CGE's original emissive texture/color pipeline.
    The fragment texture_coord_shift hook does NOT affect surface textures. }
  TRAFFIC_SIGNAL_UV_VS =
    'attribute vec2 signalBaseUV;' + #10 +
    'uniform vec4 signalCells;' + #10 +
    '#ifndef GL_ES' + #10 +
    'varying vec4 castle_TexCoord0;' + #10 +
    '#endif' + #10 +
    'void PLUG_vertex_eye_space(const vec4 vertex_eye, const vec3 normal_eye) {' + #10 +
    '  float u;' + #10 +
    '  if (signalBaseUV.x > 0.3)' + #10 +
    '    u = signalBaseUV.x > 0.5 ? signalCells.w : signalCells.z;' + #10 +
    '  else u = signalBaseUV.x > 0.1 ? signalCells.y : signalCells.x;' + #10 +
    '  castle_TexCoord0 = vec4(u, signalBaseUV.y, 0.0, 1.0);' + #10 +
    '}';

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

    { U extent of sprite Index's cell: [CellUMin, CellUMax] x [0,1]. The same
      endpoints feed the immutable green-phase UVs and the phase uniform.
      No TextureTransform or geometry update is involved. }
    class function CellUMin(Index: Integer): Single;
    class function CellUMax(Index: Integer): Single;
  end;

{ Single-row 256px grid, one cell per sprite. }
function DefaultAccessoryAtlasLayout: TAtlasLayout;

{ Uniform order: perpendicular min/max, primary min/max. }
function TrafficSignalCells(Phase: Integer): TVector4;
function AdvanceTrafficSignalCycle(var Phase: Integer; var Elapsed: Single;
  SecondsPassed: Single): Boolean;
{ Borrowed Phase field belongs to the appearance effect. Call while assembling
  a head mesh with the green-phase UVs, before Scene.Load. Full and Universal
  renderers, including GLES, use CGE's same texture-coordinate hook. }
procedure AttachTrafficSignalUV(Geometry: TIndexedFaceSetNode;
  Appearance: TAppearanceNode; out Phase: TSFVec4f);

implementation

uses CastleUriUtils, CastleRenderOptions, Osm3dStaticGeometry;

function TrafficSignalCells(Phase: Integer): TVector4;
const
  Primary: array[0..2] of TAccessorySprite =
    (asTrafficGreen, asTrafficYellow, asTrafficRed);
  Perpendicular: array[0..2] of TAccessorySprite =
    (asTrafficRed, asTrafficRed, asTrafficGreen);
begin
  if (Phase < 0) or (Phase > 2) then Phase := 0;
  Result := Vector4(
    TAccessoryAtlas.CellUMin(Ord(Perpendicular[Phase])),
    TAccessoryAtlas.CellUMax(Ord(Perpendicular[Phase])),
    TAccessoryAtlas.CellUMin(Ord(Primary[Phase])),
    TAccessoryAtlas.CellUMax(Ord(Primary[Phase])));
end;

function AdvanceTrafficSignalCycle(var Phase: Integer; var Elapsed: Single;
  SecondsPassed: Single): Boolean;
var Duration: Single;
begin
  case Phase of
    0: Duration := ACCESSORY_TL_GREEN_S;
    1: Duration := ACCESSORY_TL_YELLOW_S;
  else Duration := ACCESSORY_TL_RED_S;
  end;
  Elapsed := Elapsed + SecondsPassed;
  Result := Elapsed >= Duration;
  if Result then
  begin
    Elapsed := 0;
    Phase := (Phase + 1) mod 3;
  end;
end;

procedure AttachTrafficSignalUV(Geometry: TIndexedFaceSetNode;
  Appearance: TAppearanceNode; out Phase: TSFVec4f);
var
  Effect: TEffectNode;
  VertexPart: TEffectPartNode;
  Attribute: TFloatVertexAttributeNode;
  UV: TTextureCoordinateNode;
  Values: array of Single;
  I: Integer;
begin
  Phase := nil;
  if (Geometry = nil) or (Appearance = nil) or
     not (Geometry.TexCoord is TTextureCoordinateNode) then Exit;
  UV := TTextureCoordinateNode(Geometry.TexCoord);
  SetLength(Values, UV.FdPoint.Count * 2);
  for I := 0 to UV.FdPoint.Count - 1 do
  begin
    Values[I*2] := UV.FdPoint.Items[I].X;
    Values[I*2+1] := UV.FdPoint.Items[I].Y;
  end;
  Attribute := TFloatVertexAttributeNode.Create;
  Attribute.NameField := 'signalBaseUV';
  Attribute.NumComponents := 2;
  AssignStaticField(Attribute.FdValue, Values);
  Geometry.FdAttrib.Add(Attribute);

  Effect := TEffectNode.Create;
  Effect.Language := slGLSL;
  Effect.UniformMissing := umIgnore; { depth-only programs need no sprite UV }
  Effect.InternalSharedCodeKey := 'osm-traffic-signal-uv-v1';
  Phase := TSFVec4f.Create(Effect, True, 'signalCells', TrafficSignalCells(0));
  Effect.AddCustomField(Phase); { chNone: appearance animation, no new geometry }
  VertexPart := TEffectPartNode.Create;
  VertexPart.ShaderType := stVertex;
  VertexPart.Contents := TRAFFIC_SIGNAL_UV_VS;
  Effect.SetParts([VertexPart]);
  Appearance.FdEffects.Add(Effect);
end;

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
