unit GameGraphicsOptions;

{$mode objfpc}{$H+}

interface

uses SysUtils;

type
  TGraphicsOption = (goFrameLimit, goAntialiasing, goShadowSize,
    goShadowFilter, goShadowDistance, goGrass, goTrees, goTextures,
    goVegetationCache, goVegetationAdaptive,goHair,goSoftening,goWorldShadows,goRtxReflections,goRiderComplexity,goWorldComplexity,goVegetationComplexity);
  TGraphicsValues = array[TGraphicsOption] of Integer;
  TGraphicsChangeEvent = procedure(Sender: TObject; Option: TGraphicsOption) of object;

const
  GraphicsKeys: array[TGraphicsOption] of String =
    ('fps_limit', 'msaa', 'shadow_size', 'shadow_filter', 'shadow_distance',
     'grass', 'vegetation_quality', 'textures', 'vegetation_cache', 'vegetation_adaptive','hair_quality','cinematic_softening','world_shadow_backend','rtx_reflections','rider_complexity','world_complexity','vegetation_complexity');
  GraphicsTitles: array[TGraphicsOption] of String =
    ('Frame rate limit', 'Anti-aliasing', 'Shadow map', 'Shadow filtering',
     'Shadow distance', '3D grass', 'Vegetation quality', 'Texture quality:',
     'Vegetation preparation', 'Adapt vegetation to frame rate','Hair quality','Cinematic softness','World shadows','RTX reflections','Rider material complexity','Road material complexity','Vegetation complexity');
  GraphicsHints: array[TGraphicsOption] of String =
    ('VSync follows your monitor. A lower limit reduces GPU load.',
     'MSAA smooths edges. Takes effect after restarting the game.',
     'One map for riders, buildings and vegetation. Higher resolution uses more GPU memory.',
     'Hard edges are faster. Softer edges smooth the shadow outline.',
     'Shorter distance reduces the amount of geometry drawn into shadows.',
     'Turn off grass blades to improve performance. The ground stays grass-covered.',
     'Controls detail distance, transition width, grass density and cache size together. Ultra prioritizes smooth transitions.',
     'Texture changes apply to newly loaded scenes.',
     'Gentle reduces loading spikes. Fast prepares vegetation sooner but uses more frame time.',
     'Reduce background work and distant detail when below the frame limit. Ultra keeps the procedural tree range.',
     'Controls hair detail, lighting and motion update rate. Applies immediately.',
     'Soft lens edges and distant scenery. Keeps the central rider area and interface clear. Applies immediately.',
     'Cached tree silhouettes are faster. RTX requires a ray-tracing GPU; unsupported hardware uses raster shadows.',
     'Reflects buildings, trees and terrain in water and windows. Requires RTX world shadows.',
     'Full keeps all cloth relief and lighting. Lower modes simplify cloth shading without changing body animation.',
     'Full keeps detailed road relief. Lower modes use cached normals and remove parallax. Road layout and markings stay unchanged.',
     'Changes branches, needles, blade geometry and wind at the same distance. LOD distance is controlled separately.');
  GraphicsDefaults: TGraphicsValues = (-1, 0, 2048, 16, 160, 1, 2, 3, 1, 1,2,1,1,0,3,3,3);
  GraphicsDisplayOrder: array[TGraphicsOption] of TGraphicsOption =
    (goFrameLimit,goAntialiasing,goRiderComplexity,goWorldComplexity,goVegetationComplexity,goWorldShadows,goRtxReflections,goShadowSize,goShadowFilter,
     goShadowDistance,goGrass,goTrees,goTextures,
     goVegetationCache,goVegetationAdaptive,goHair,goSoftening);

function GraphicsChoiceCount(Option: TGraphicsOption): Integer;
function GraphicsChoiceValue(Option: TGraphicsOption; Index: Integer): Integer;
function GraphicsChoiceCaption(Option: TGraphicsOption; Index: Integer): String;
function ValidGraphicsValue(Option: TGraphicsOption; Value: Integer): Boolean;

implementation

function GraphicsChoiceCount(Option: TGraphicsOption): Integer;
begin
  case Option of
    goFrameLimit: Result := 7;
    goAntialiasing, goShadowSize, goTextures,goHair,goRiderComplexity,goWorldComplexity,goVegetationComplexity: Result := 4;
    goShadowFilter, goShadowDistance, goVegetationCache,goSoftening,goWorldShadows: Result := 3;
    goTrees: Result := 5;
    goGrass, goVegetationAdaptive,goRtxReflections: Result := 2;
  end;
end;

function GraphicsChoiceValue(Option: TGraphicsOption; Index: Integer): Integer;
const
  Caps: array[0..6] of Integer = (-1, 30, 60, 90, 120, 144, 0);
  AA: array[0..3] of Integer = (0, 2, 4, 8);
  Sizes: array[0..3] of Integer = (0, 1024, 2048, 4096);
  Filters: array[0..2] of Integer = (1, 4, 16);
  Distances: array[0..2] of Integer = (60, 100, 160);
begin
  if (Index < 0) or (Index >= GraphicsChoiceCount(Option)) then
    Exit(GraphicsDefaults[Option]);
  case Option of
    goFrameLimit: Result := Caps[Index];
    goAntialiasing: Result := AA[Index];
    goShadowSize: Result := Sizes[Index];
    goShadowFilter: Result := Filters[Index];
    goShadowDistance: Result := Distances[Index];
    goTrees, goGrass, goTextures, goVegetationCache, goVegetationAdaptive,goHair,goSoftening,goWorldShadows,goRtxReflections,goRiderComplexity,goWorldComplexity,goVegetationComplexity: Result := Index;
  end;
end;

function GraphicsChoiceCaption(Option: TGraphicsOption; Index: Integer): String;
const Textures: array[0..3] of String = ('Low', 'Medium', 'High', 'Ultra');
var V: Integer;
begin
  V := GraphicsChoiceValue(Option, Index);
  case Option of
    goFrameLimit:
      if V < 0 then Result := 'VSync'
      else if V = 0 then Result := 'Unlimited' else Result := IntToStr(V);
    goAntialiasing:
      if V = 0 then Result := 'Off' else Result := 'MSAA ' + IntToStr(V) + 'x';
    goShadowSize:
      if V = 0 then Result := 'Off' else Result := IntToStr(V);
    goShadowFilter:
      case V of 1: Result := 'Hard'; 4: Result := 'Soft'; else Result := 'Softer'; end;
    goShadowDistance: Result := IntToStr(V) + ' m';
    goTrees:
      if V = 0 then Result := 'Simplified' else Result := Textures[V-1];
    goVegetationCache:
      case V of 0:Result:='Gentle';1:Result:='Balanced';else Result:='Fast';end;
    goGrass, goVegetationAdaptive,goRtxReflections:
      if V = 0 then Result := 'Off' else Result := 'On';
    goTextures,goHair: Result := Textures[V];
    goRiderComplexity,goWorldComplexity,goVegetationComplexity:
      case V of 0:Result:='Minimal';1:Result:='Light';2:Result:='Balanced';else Result:='Full';end;
    goSoftening:
      case V of 0:Result:='Off';1:Result:='Subtle';else Result:='Stronger';end;
    goWorldShadows:
      case V of 0:Result:='Raster';1:Result:='Cached trees';else Result:='RTX (experimental)';end;
  end;
end;

function ValidGraphicsValue(Option: TGraphicsOption; Value: Integer): Boolean;
var I: Integer;
begin
  for I := 0 to GraphicsChoiceCount(Option)-1 do
    if GraphicsChoiceValue(Option, I) = Value then Exit(True);
  Result := False;
end;

end.
