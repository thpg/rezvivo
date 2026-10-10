unit GameGraphicsOptions;

{$I castleconf.inc}

interface

uses SysUtils, Osm3dRenderProfile;

type
  TGraphicsOption = (goFrameLimit, goAntialiasing, goShadowSize,
    goShadowFilter, goShadowDistance, goGrass, goTrees, goTextures,
    goVegetationCache, goVegetationAdaptive,goHair,goSoftening,goWorldShadows,goRtxReflections,goRiderComplexity,goWorldComplexity,goVegetationComplexity,goRenderer);
  TGraphicsPreset = (gpEconomy, gpLight, gpBalanced, gpHigh);
  TGraphicsValues = array[TGraphicsOption] of Integer;
  TGraphicsChangeEvent = procedure(Sender: TObject; Option: TGraphicsOption) of object;

const
  GraphicsKeys: array[TGraphicsOption] of String =
    ('fps_limit', 'msaa', 'shadow_size', 'shadow_filter', 'shadow_distance',
     'grass', 'vegetation_quality', 'textures', 'vegetation_cache', 'vegetation_adaptive','hair_quality','cinematic_softening','world_shadow_backend','rtx_reflections','rider_complexity','world_complexity','vegetation_complexity','renderer');
  GraphicsTitles: array[TGraphicsOption] of String =
    ('Frame rate limit', 'Anti-aliasing', 'Shadow map', 'Shadow filtering',
     'Shadow distance', '3D grass', 'Vegetation quality', 'Texture quality:',
     'Vegetation preparation', 'Adapt vegetation to frame rate','Hair quality','Cinematic softness','World shadows','RTX reflections','Rider material complexity','Road material complexity','Vegetation complexity','Renderer');
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
     'Changes branches, needles, blade geometry and wind at the same distance. LOD distance is controlled separately.',
     'Universal keeps GPU animation and procedural shaders with lighter materials, vegetation and shadows. Takes effect after restarting the game.');
  GraphicsPresetTitles: array[TGraphicsPreset] of String =
    ('Battery saver', 'Lightweight', 'Balanced', 'High');
  GraphicsPresetHints: array[TGraphicsPreset] of String =
    ('Baked trees and ground cover, simple materials, no dynamic shadows or effects.',
     'Baked vegetation, small hard shadows and light materials.',
     'Procedural vegetation, soft shadows and detailed materials.',
     'Dense vegetation, detailed materials and longer soft shadows.');
  GraphicsDefaults: TGraphicsValues = {$ifdef OpenGLES}(30,0,0,1,60,0,0,1,0,1,0,0,0,0,0,0,0,1){$else} (-1, 0, 2048, 16, 160, 1, 2, 3, 1, 1,2,1,1,0,3,3,3,0){$endif};
  GraphicsDisplayOrder: array[TGraphicsOption] of TGraphicsOption =
    (goRenderer,goFrameLimit,goAntialiasing,goRiderComplexity,goWorldComplexity,goVegetationComplexity,goWorldShadows,goRtxReflections,goShadowSize,goShadowFilter,
     goShadowDistance,goGrass,goTrees,goTextures,
     goVegetationCache,goVegetationAdaptive,goHair,goSoftening);

function GraphicsPresetValues(Preset: TGraphicsPreset; const Original: TGraphicsValues): TGraphicsValues;
function MatchingGraphicsPreset(const Values: TGraphicsValues): Integer;

function GraphicsChoiceCount(Option: TGraphicsOption): Integer;
function GraphicsChoiceValue(Option: TGraphicsOption; Index: Integer): Integer;
function GraphicsChoiceCaption(Option: TGraphicsOption; Index: Integer): String;
function ValidGraphicsValue(Option: TGraphicsOption; Value: Integer): Boolean;
function EffectiveGraphicsValue(Option: TGraphicsOption; Value: Integer): Integer;

implementation

uses Math;

function GraphicsPresetValues(Preset: TGraphicsPreset; const Original: TGraphicsValues): TGraphicsValues;
const
  ShadowSizes: array[TGraphicsPreset] of Integer = (0,512,2048,2048);
  Filters: array[TGraphicsPreset] of Integer = (1,1,4,16);
  Distances: array[TGraphicsPreset] of Integer = (60,60,100,160);
  Trees: array[TGraphicsPreset] of Integer = (0,0,2,3);
  Textures: array[TGraphicsPreset] of Integer = (1,1,2,3);
var O: TGraphicsOption;
begin
  Result:=Original; { Preserve frame pacing, MSAA and renderer selection. }
  Result[goShadowSize]:=ShadowSizes[Preset];Result[goShadowFilter]:=Filters[Preset];
  Result[goShadowDistance]:=Distances[Preset];Result[goTrees]:=Trees[Preset];
  Result[goGrass]:=Ord(Preset>=gpBalanced);Result[goTextures]:=Textures[Preset];
  Result[goVegetationCache]:=Ord(Preset>=gpBalanced);Result[goVegetationAdaptive]:=1;
  Result[goHair]:=Ord(Preset);Result[goRiderComplexity]:=Ord(Preset);
  Result[goWorldComplexity]:=Ord(Preset);Result[goVegetationComplexity]:=Ord(Preset);
  Result[goWorldShadows]:=Ord(Preset>=gpBalanced);Result[goRtxReflections]:=0;
  Result[goSoftening]:=0;
  for O:=Low(O) to High(O) do Result[O]:=EffectiveGraphicsValue(O,Result[O]);
end;

function MatchingGraphicsPreset(const Values: TGraphicsValues): Integer;
var P: TGraphicsPreset; O: TGraphicsOption; V: TGraphicsValues; Same: Boolean;
begin
  for P:=Low(P) to High(P) do begin
    V:=GraphicsPresetValues(P,Values);Same:=True;
    for O:=Low(O) to High(O) do if V[O]<>Values[O] then Same:=False;
    if Same then Exit(Ord(P));
  end;
  Result:=-1;
end;

function EffectiveGraphicsValue(Option: TGraphicsOption; Value: Integer): Integer;
begin
  Result := Value;
  if not UniversalRenderer then Exit;
  case Option of
    goWorldShadows, goRtxReflections, goSoftening: Result := 0;
    { CGE's EGL backend currently does not request multisample surfaces.
      Do not offer a setting that cannot affect the active Android renderer. }
    goAntialiasing: Result := {$ifdef OpenGLES}0{$else}Min(Value, 4){$endif};
    goShadowSize: Result := Min(Value, 1024);
    goShadowFilter: Result := Min(Value, 4);
    goShadowDistance: Result := Min(Value, 60);
    goTrees: Result := Min(Value, 1);
    goTextures, goRiderComplexity, goWorldComplexity,
    goVegetationComplexity, goHair: Result := Min(Value, 1);
  end;
end;

function GraphicsChoiceCount(Option: TGraphicsOption): Integer;
begin
  case Option of
    goFrameLimit: Result := 7;
    goShadowSize: Result := 5;
    goAntialiasing, goTextures,goHair,goRiderComplexity,goWorldComplexity,goVegetationComplexity: Result := 4;
    goShadowFilter, goShadowDistance, goVegetationCache,goSoftening,goWorldShadows: Result := 3;
    goTrees: Result := 5;
    goGrass, goVegetationAdaptive,goRtxReflections: Result := 2;
    goRenderer: if FullRendererSupported then Result := 2 else Result := 1;
  end;
end;

function GraphicsChoiceValue(Option: TGraphicsOption; Index: Integer): Integer;
const
  Caps: array[0..6] of Integer = (-1, 30, 60, 90, 120, 144, 0);
  AA: array[0..3] of Integer = (0, 2, 4, 8);
  Sizes: array[0..4] of Integer = (0, 512, 1024, 2048, 4096);
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
    goRenderer: if FullRendererSupported then Result := Index else Result := 1;
    goTrees, goGrass, goTextures, goVegetationCache, goVegetationAdaptive,goHair,goSoftening,goWorldShadows,goRtxReflections,goRiderComplexity,goWorldComplexity,goVegetationComplexity: Result := Index;
  end;
end;

function GraphicsChoiceCaption(Option: TGraphicsOption; Index: Integer): String;
const Textures: array[0..3] of String = ('Low', 'Medium', 'High', 'Ultra');
var V: Integer;
begin
  V := GraphicsChoiceValue(Option, Index);
  case Option of
    goRenderer: if V = 0 then Result := 'Full' else Result := 'Universal';
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
