{ GameScreenFX — screen-space post-processing, each effect individually
  switchable:

    Pass 1  (fog + bloom H)   — depth-based distance fog; horizontal half of
                                the bloom blur
    Pass 2  (bloom V + tone)  — vertical bloom half; ACES filmic tone map
    Pass 3  (Kuwahara)        — painterly smoothing that keeps edges
                                (oil-paint look); OFF by default, expensive
    Pass 4  (stylize)         — color posterization + procedural hatching in
                                the shadows (comic/hand-drawn look); OFF by
                                default

  Individual switches: FogEnabled, BloomEnabled, ToneEnabled,
  PosterizeEnabled, KuwaharaEnabled, HatchEnabled — plus the master Enabled.
  By default ONLY the fog is on: Enabled is a shared master for all passes,
  so switching the fog on must not silently bring bloom/tone along.
  Effects sharing a pass are gated by uniforms (a uniform branch is free on
  the GPU); a pass whose every effect is off gets its NODE disabled, so it
  costs nothing at all.

  FOG works off the DEPTH buffer, so it covers EVERYTHING that writes depth —
  including the raw-GL instanced vegetation that never receives TCastleFog.
  Keep Viewport.Fog = nil while it is on (double fog otherwise). Sky is
  detected by reconstructed DISTANCE (>= 98% of far), never by a raw-depth
  epsilon — the depth buffer is non-linear and far geometry reads > 0.9999.
  FogClearZone (0 = off) keeps a fully clear sphere around the camera: the
  fog distance is measured from its BOUNDARY, not from the eye, so the
  near scene stays crisp and the falloff still starts from zero there.

  All tunables are shader uniforms exposed as properties — adjustable at
  runtime without shader rebuilds. Vignette and grain intentionally NOT
  included.

  Usage (see gameviewplay):
    FScreenFX := TScreenFX.Create(MainViewport);   // after the viewport exists
    FScreenFX.KuwaharaEnabled := True;             // toggle one effect
    FScreenFX.Enabled := False;                    // master off
    FreeAndNil(FScreenFX);                         // in Stop }
unit GameScreenFX;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils,
  CastleViewport, CastleVectors, X3DNodes, X3DFields, CastleRenderOptions;

type
  TSFFloatArray = array of TSFFloat;

  TScreenFX = class
  private
    FViewport: TCastleViewport;
    FBloomH, FBloomV, FKuwahara, FStylize: TScreenEffectNode;
    { uniform handles (threshold/strength live in both bloom passes) }
    FUniThresholdH, FUniThresholdV: TSFFloat;
    FUniStrengthH, FUniStrengthV: TSFFloat;
    FUniExposure, FUniToneMix: TSFFloat;
    { fog uniforms — live only in bloom pass 1 (the depth-reading pass) }
    FUniFogColor: TSFVec3f;
    FUniFogRange, FUniFogNear, FUniFogFar, FUniFogClear: TSFFloat;
    { stylize uniforms }
    FUniPosterLevels, FUniHatchStrength: TSFFloat;
    FEnabled: Boolean;
    { individual effect switches }
    FFogEnabled, FBloomEnabled, FToneEnabled: Boolean;
    FPosterEnabled, FKuwaharaEnabled, FHatchEnabled: Boolean;
    FBloomThreshold, FBloomStrength, FToneExposure, FToneMix: Single;
    FFogColor: TVector3;
    FFogRange, FFogDepthNear, FFogDepthFar, FFogClearZone: Single;
    FPosterLevels, FHatchStrength: Single;
    function MakeEffect(const FragmentCode: String;
      const UniNames: array of String; const UniValues: array of Single;
      out UniFields: TSFFloatArray;
      const ANeedsDepth: Boolean;
      out ShaderNode: TComposedShaderNode): TScreenEffectNode;
    { Push effective uniform values (a disabled effect sends its "off"
      sentinel) and enable/disable whole passes whose effects are all off. }
    procedure ApplyState;
    procedure SetEnabled(const V: Boolean);
    procedure SetFogEnabled(const V: Boolean);
    procedure SetBloomEnabled(const V: Boolean);
    procedure SetToneEnabled(const V: Boolean);
    procedure SetPosterizeEnabled(const V: Boolean);
    procedure SetKuwaharaEnabled(const V: Boolean);
    procedure SetHatchEnabled(const V: Boolean);
    procedure SetBloomThreshold(const V: Single);
    procedure SetBloomStrength(const V: Single);
    procedure SetToneExposure(const V: Single);
    procedure SetToneMix(const V: Single);
    procedure SetFogColor(const V: TVector3);
    procedure SetFogRange(const V: Single);
    procedure SetFogClearZone(const V: Single);
    procedure SetFogDepthNear(const V: Single);
    procedure SetFogDepthFar(const V: Single);
    procedure SetPosterizeLevels(const V: Single);
    procedure SetHatchStrength(const V: Single);
  public
    constructor Create(AViewport: TCastleViewport);
    destructor Destroy; override;

    { Master switch for all passes (default True). }
    property Enabled: Boolean read FEnabled write SetEnabled;
    { ── individual effect switches ── }
    property FogEnabled: Boolean read FFogEnabled write SetFogEnabled;             { default True }
    property BloomEnabled: Boolean read FBloomEnabled write SetBloomEnabled;       { default False }
    property ToneEnabled: Boolean read FToneEnabled write SetToneEnabled;          { default False }
    property PosterizeEnabled: Boolean read FPosterEnabled write SetPosterizeEnabled; { default False }
    property KuwaharaEnabled: Boolean read FKuwaharaEnabled write SetKuwaharaEnabled; { default False; expensive (~36 taps) }
    property HatchEnabled: Boolean read FHatchEnabled write SetHatchEnabled;       { default False }

    { Brightness where glow starts to pick up (soft smoothstep knee).
      Default 0.62 — LDR frames need a fairly low knee. }
    property BloomThreshold: Single read FBloomThreshold write SetBloomThreshold;
    { Overall glow intensity added to the frame. Default 0.55. }
    property BloomStrength: Single read FBloomStrength write SetBloomStrength;
    { Pre-tonemap exposure. >1 compensates the ACES curve darkening mids on
      an LDR input. Default 1.15. }
    property ToneExposure: Single read FToneExposure write SetToneExposure;
    { Blend between the untouched frame (0) and the tonemapped one (1).
      Default 0.8 — keeps a bit of the original punch. }
    property ToneMix: Single read FToneMix write SetToneMix;

    { ── depth-based fog (covers raw-GL vegetation too) ── }
    { Distance (m) where ~98% of the scene color is gone. Default 900.
      Keep Viewport.Fog = nil while the fog is on! }
    property FogRange: Single read FFogRange write SetFogRange;
    { Радиус чистой зоны вокруг камеры, м: ближе него тумана нет вообще, а
      дальше дальность отсчитывается ОТ ЕГО ГРАНИЦЫ — на границе эффективное
      расстояние 0, ровно как у камеры при FogClearZone=0, поэтому спад
      начинается с нуля и стыка/ступеньки не возникает. FogRange при этом
      меряется от границы, а не от глаза: полное гашение — на
      FogClearZone + FogRange. Default 0 — прежнее поведение (туман от самой
      камеры). }
    property FogClearZone: Single read FFogClearZone write SetFogClearZone;
    { Fog color — match the horizon/sky color, the sky itself is not fogged.
      Default (0.75, 0.80, 0.88), a pale blue-gray. }
    property FogColor: TVector3 read FFogColor write SetFogColor;
    { Camera near/far used to turn depth-buffer values into meters.
      Auto-read from the viewport camera at creation when it has explicit
      values; override if the camera uses auto (0) planes and the fog
      distance looks off. }
    property FogDepthNear: Single read FFogDepthNear write SetFogDepthNear;
    property FogDepthFar: Single read FFogDepthFar write SetFogDepthFar;

    { ── stylization ── }
    { Color quantization steps per channel (comic/poster look). Default 6. }
    property PosterizeLevels: Single read FPosterLevels write SetPosterizeLevels;
    { How dark the procedural pencil strokes in the shadows are, 0..1.
      Default 0.5. }
    property HatchStrength: Single read FHatchStrength write SetHatchStrength;
  end;

implementation

const
  { ── Pass 1: depth fog + horizontal bloom ──
    Fog: reconstruct linear eye distance from the depth buffer ONCE (for the
    center pixel) and mix toward fog_color (exp2 falloff). The glow gathered
    from neighbours is multiplied by the SAME transmittance — a bright object
    deep in the fog then blooms as dimly as it looks; neighbouring taps sit at
    nearly the same distance, so the approximation is invisible and it saves
    8 depth fetches per pixel.
    Sky test is DISTANCE-based (>= 98% of far), not a raw-depth epsilon: the
    depth buffer is non-linear and everything beyond ~1.5 km already reads
    > 0.9999, so an epsilon test wrongly classified far geometry as sky. }
  BloomFragH: String =
    'uniform float bloom_threshold;' + LineEnding +
    'uniform float bloom_strength;' + LineEnding +
    'uniform vec3  fog_color;' + LineEnding +
    'uniform float fog_range;   /* <= 0 disables the fog */' + LineEnding +
    'uniform float fog_clear;   /* clear sphere radius around the eye, m */' + LineEnding +
    'uniform float fog_near;' + LineEnding +
    'uniform float fog_far;' + LineEnding +
    'float fx_lum(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }' + LineEnding +
    'vec3 fx_bright(ivec2 p)' + LineEnding +
    '{' + LineEnding +
    '  vec3 c = screen_get_color(p).rgb;' + LineEnding +
    '  /* soft knee: from threshold up to threshold+0.3; a hard step flickers */' + LineEnding +
    '  return c * smoothstep(bloom_threshold, bloom_threshold + 0.3, fx_lum(c));' + LineEnding +
    '}' + LineEnding +
    'void main (void)' + LineEnding +
    '{' + LineEnding +
    '  ivec2 p = screen_position();' + LineEnding +
    '  vec3 col = screen_get_color(p).rgb;' + LineEnding +
    '  float f = 1.0;  /* fog transmittance of THIS pixel: 1 = clear */' + LineEnding +
    '  if (fog_range > 0.0) {' + LineEnding +
    '    float ndc = screen_get_depth(p) * 2.0 - 1.0;' + LineEnding +
    '    float dist = (2.0 * fog_near * fog_far) / (fog_far + fog_near - ndc * (fog_far - fog_near));' + LineEnding +
    '    if (dist < fog_far * 0.98) {  /* at/near far plane = sky, keep as authored */' + LineEnding +
    '      /* clear zone: measure from its boundary, not from the eye. At the' + LineEnding +
    '         boundary d = 0 — same start as at the camera, so no step. */' + LineEnding +
    '      float d = max(dist - fog_clear, 0.0);' + LineEnding +
    '      float k = d * 2.0 / fog_range;' + LineEnding +
    '      f = exp(-k * k);            /* ~2% scene left at fog_clear+fog_range */' + LineEnding +
    '      col = mix(fog_color, col, f);' + LineEnding +
    '    }' + LineEnding +
    '  }' + LineEnding +
    '  float k0 = 0.227; float k1 = 0.194; float k2 = 0.121; float k3 = 0.054; float k4 = 0.016;' + LineEnding +
    '  vec3 glow = vec3(0.0);' + LineEnding +
    '  if (bloom_strength > 0.0) {  /* uniform branch = free; skips 9 taps when bloom is off */' + LineEnding +
    '    glow  = fx_bright(p) * k0;' + LineEnding +
    '    glow += (fx_bright(p + ivec2( 2, 0)) + fx_bright(p + ivec2(-2, 0))) * k1;' + LineEnding +
    '    glow += (fx_bright(p + ivec2( 4, 0)) + fx_bright(p + ivec2(-4, 0))) * k2;' + LineEnding +
    '    glow += (fx_bright(p + ivec2( 6, 0)) + fx_bright(p + ivec2(-6, 0))) * k3;' + LineEnding +
    '    glow += (fx_bright(p + ivec2( 8, 0)) + fx_bright(p + ivec2(-8, 0))) * k4;' + LineEnding +
    '  }' + LineEnding +
    '  gl_FragColor = vec4(col + glow * f * bloom_strength * 0.5, 1.0);' + LineEnding +
    '}';

  { ── Pass 2: vertical bloom + filmic tone map ──
    Same blur kernel with vertical offsets, then the ACES approximation
    (Narkowicz 2015) blended by tone_mix — merged into one pass to save a
    third full-screen draw. }
  BloomFragV: String =
    'uniform float bloom_threshold;' + LineEnding +
    'uniform float bloom_strength;' + LineEnding +
    'uniform float tone_exposure;' + LineEnding +
    'uniform float tone_mix;' + LineEnding +
    'float fx_lum(vec3 c) { return dot(c, vec3(0.2126, 0.7152, 0.0722)); }' + LineEnding +
    'vec3 fx_bright(ivec2 p)' + LineEnding +
    '{' + LineEnding +
    '  vec3 c = screen_get_color(p).rgb;' + LineEnding +
    '  return c * smoothstep(bloom_threshold, bloom_threshold + 0.3, fx_lum(c));' + LineEnding +
    '}' + LineEnding +
    'vec3 fx_aces(vec3 x)' + LineEnding +
    '{' + LineEnding +
    '  return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0);' + LineEnding +
    '}' + LineEnding +
    'void main (void)' + LineEnding +
    '{' + LineEnding +
    '  ivec2 p = screen_position();' + LineEnding +
    '  vec4 base = screen_get_color(p);' + LineEnding +
    '  float k0 = 0.227; float k1 = 0.194; float k2 = 0.121; float k3 = 0.054; float k4 = 0.016;' + LineEnding +
    '  vec3 glow = vec3(0.0);' + LineEnding +
    '  if (bloom_strength > 0.0) {' + LineEnding +
    '    glow  = fx_bright(p) * k0;' + LineEnding +
    '    glow += (fx_bright(p + ivec2(0,  2)) + fx_bright(p + ivec2(0, -2))) * k1;' + LineEnding +
    '    glow += (fx_bright(p + ivec2(0,  4)) + fx_bright(p + ivec2(0, -4))) * k2;' + LineEnding +
    '    glow += (fx_bright(p + ivec2(0,  6)) + fx_bright(p + ivec2(0, -6))) * k3;' + LineEnding +
    '    glow += (fx_bright(p + ivec2(0,  8)) + fx_bright(p + ivec2(0, -8))) * k4;' + LineEnding +
    '  }' + LineEnding +
    '  vec3 col = base.rgb + glow * bloom_strength * 0.5;' + LineEnding +
    '  if (tone_mix > 0.0) {' + LineEnding +
    '    vec3 mapped = fx_aces(col * tone_exposure);' + LineEnding +
    '    col = mix(col, mapped, tone_mix);' + LineEnding +
    '  }' + LineEnding +
    '  gl_FragColor = vec4(col, 1.0);' + LineEnding +
    '}';

  { ── Pass 3: Kuwahara ── painterly edge-preserving smoothing (oil-paint
    look). Classic 4-window variant, radius 2: for each of the four 3x3
    windows around the pixel compute mean color and luminance variance, keep
    the mean of the calmest window — flat areas get averaged, edges stay
    crisp. 36 taps: expensive, that is why it lives in its OWN pass that is
    fully disabled unless requested. }
  KuwaharaFrag: String =
    'vec4 fx_win(ivec2 p, ivec2 o)' + LineEnding +
    '{' + LineEnding +
    '  vec3 m = vec3(0.0); float m2 = 0.0;' + LineEnding +
    '  for (int i = 0; i < 3; i++)' + LineEnding +
    '    for (int j = 0; j < 3; j++) {' + LineEnding +
    '      vec3 c = screen_get_color(p + o + ivec2(i, j)).rgb;' + LineEnding +
    '      float l = dot(c, vec3(0.2126, 0.7152, 0.0722));' + LineEnding +
    '      m += c; m2 += l * l;' + LineEnding +
    '    }' + LineEnding +
    '  m /= 9.0; m2 /= 9.0;' + LineEnding +
    '  float lm = dot(m, vec3(0.2126, 0.7152, 0.0722));' + LineEnding +
    '  return vec4(m, m2 - lm * lm);   /* rgb = mean, w = variance */' + LineEnding +
    '}' + LineEnding +
    'void main (void)' + LineEnding +
    '{' + LineEnding +
    '  ivec2 p = screen_position();' + LineEnding +
    '  vec4 best = fx_win(p, ivec2(-2, -2));' + LineEnding +
    '  vec4 w;' + LineEnding +
    '  w = fx_win(p, ivec2( 0, -2)); if (w.w < best.w) best = w;' + LineEnding +
    '  w = fx_win(p, ivec2(-2,  0)); if (w.w < best.w) best = w;' + LineEnding +
    '  w = fx_win(p, ivec2( 0,  0)); if (w.w < best.w) best = w;' + LineEnding +
    '  gl_FragColor = vec4(best.rgb, 1.0);' + LineEnding +
    '}';

  { ── Pass 4: stylize ── posterization (color quantization, comic look) and
    procedural hatching: diagonal pencil strokes fade in in the shadows, the
    second, crossing direction in the deep shadows. Both gated by uniforms;
    the pass node itself is disabled when neither is on. }
  StylizeFrag: String =
    'uniform float poster_levels;   /* <= 1 disables */' + LineEnding +
    'uniform float hatch_strength;  /* <= 0 disables */' + LineEnding +
    'void main (void)' + LineEnding +
    '{' + LineEnding +
    '  ivec2 p = screen_position();' + LineEnding +
    '  vec3 col = screen_get_color(p).rgb;' + LineEnding +
    '  if (poster_levels > 1.0)' + LineEnding +
    '    col = floor(col * poster_levels + 0.5) / poster_levels;' + LineEnding +
    '  if (hatch_strength > 0.0) {' + LineEnding +
    '    float lum = dot(col, vec3(0.2126, 0.7152, 0.0722));' + LineEnding +
    '    vec2 pc = vec2(p);' + LineEnding +
    '    /* stroke = dark half of a diagonal stripe pattern, period 7 px */' + LineEnding +
    '    float l1 = step(0.5, fract((pc.x + pc.y) / 7.0));' + LineEnding +
    '    float l2 = step(0.5, fract((pc.x - pc.y) / 7.0));' + LineEnding +
    '    float ink = 1.0;' + LineEnding +
    '    /* strokes fade in from lum 0.55 down to 0.35 (no hard border) */' + LineEnding +
    '    float w1 = (1.0 - smoothstep(0.35, 0.55, lum)) * hatch_strength;' + LineEnding +
    '    ink = min(ink, mix(1.0, l1, w1));' + LineEnding +
    '    float w2 = (1.0 - smoothstep(0.10, 0.30, lum)) * hatch_strength;' + LineEnding +
    '    ink = min(ink, mix(1.0, l2, w2));' + LineEnding +
    '    col *= ink;' + LineEnding +
    '  }' + LineEnding +
    '  gl_FragColor = vec4(col, 1.0);' + LineEnding +
    '}';

function TScreenFX.MakeEffect(const FragmentCode: String;
  const UniNames: array of String; const UniValues: array of Single;
  out UniFields: TSFFloatArray;
  const ANeedsDepth: Boolean;
  out ShaderNode: TComposedShaderNode): TScreenEffectNode;
var
  Part: TShaderPartNode;
  I: Integer;
  F: TSFFloat;
begin
  Part := TShaderPartNode.Create;
  Part.ShaderType := stFragment;
  Part.Contents := FragmentCode;

  ShaderNode := TComposedShaderNode.Create;
  ShaderNode.SetParts([Part]);

  { Custom SFFloat fields on the ComposedShader become GLSL uniforms with the
    same names; keeping the field refs lets us Send() new values at runtime. }
  SetLength(UniFields, Length(UniNames));
  for I := 0 to High(UniNames) do
  begin
    F := TSFFloat.Create(ShaderNode, true, UniNames[I], UniValues[I]);
    ShaderNode.AddCustomField(F);
    UniFields[I] := F;
  end;

  Result := TScreenEffectNode.Create;
  Result.SetShaders([ShaderNode]);
  Result.NeedsDepth := ANeedsDepth;   { enables screen_get_depth() in GLSL }
  Result.Enabled := FEnabled;
end;

constructor TScreenFX.Create(AViewport: TCastleViewport);
var
  U: TSFFloatArray;
  Sh: TComposedShaderNode;
begin
  inherited Create;
  FViewport := AViewport;
  FEnabled := True;
  { individual defaults: ТОЛЬКО туман. Остальное — выключено.
    Причина: Enabled — ОБЩИЙ выключатель пассов, и включение тумана
    (единственный эффект, которым сейчас управляют извне — поле дальности
    в студии и общий с игрой файл, см. Osm3dStudioSettings.LoadFogSettings)
    тянуло за собой блум и тонмаппинг с их дефолтами. Кому нужен блум/тон —
    ставит свой switch явно (в игре это делают FX-кнопки панели).
    ApplyState сам погасит целые пассы, у которых все эффекты off:
    pass 2 (bloom V + tone) при таких дефолтах не стоит НИЧЕГО. }
  FFogEnabled := True;
  FBloomEnabled := False;
  FToneEnabled := False;
  FPosterEnabled := False;
  FKuwaharaEnabled := False;
  FHatchEnabled := False;

  { defaults tuned for an LDR frame — see property comments }
  FBloomThreshold := 0.45;
  FBloomStrength  := 0.55;
  FToneExposure   := 1.15;
  FToneMix        := 0.8;
  FPosterLevels   := 6;
  FHatchStrength  := 0.5;

  { fog defaults; near/far picked up from the camera below when explicit }
  FFogRange     := 900;
  FFogClearZone := 0;      { 0 = туман от самой камеры, как было }
  FFogColor     := Vector3(0.75, 0.80, 0.88);
  FFogDepthNear := 0.1;
  FFogDepthFar  := 5000;
  if Assigned(FViewport) and Assigned(FViewport.Camera) then
  begin
    if FViewport.Camera.ProjectionNear > 0 then
      FFogDepthNear := FViewport.Camera.ProjectionNear;
    if FViewport.Camera.ProjectionFar > 0 then
      FFogDepthFar := FViewport.Camera.ProjectionFar;
  end;

  FBloomH := MakeEffect(BloomFragH,
    ['bloom_threshold', 'bloom_strength', 'fog_range', 'fog_clear',
     'fog_near', 'fog_far'],
    [FBloomThreshold, FBloomStrength, FFogRange, FFogClearZone,
     FFogDepthNear, FFogDepthFar],
    U, true { needs depth for the fog }, Sh);
  FUniThresholdH := U[0];
  FUniStrengthH  := U[1];
  FUniFogRange   := U[2];
  FUniFogClear   := U[3];
  FUniFogNear    := U[4];
  FUniFogFar     := U[5];
  { the one non-float uniform — the fog color }
  FUniFogColor := TSFVec3f.Create(Sh, true, 'fog_color', FFogColor);
  Sh.AddCustomField(FUniFogColor);

  FBloomV := MakeEffect(BloomFragV,
    ['bloom_threshold', 'bloom_strength', 'tone_exposure', 'tone_mix'],
    [FBloomThreshold, FBloomStrength, FToneExposure, FToneMix], U, false, Sh);
  FUniThresholdV := U[0];
  FUniStrengthV  := U[1];
  FUniExposure   := U[2];
  FUniToneMix    := U[3];

  FKuwahara := MakeEffect(KuwaharaFrag, [], [], U, false, Sh);

  FStylize := MakeEffect(StylizeFrag,
    ['poster_levels', 'hatch_strength'],
    [0, 0], U, false, Sh);
  FUniPosterLevels  := U[0];
  FUniHatchStrength := U[1];

  { Chain order: fog+blur, blur+tonemap, then the stylization on the final
    colors — paint first (Kuwahara), quantize and hatch the painted image. }
  if Assigned(FViewport) then
  begin
    FViewport.AddScreenEffect(FBloomH);
    FViewport.AddScreenEffect(FBloomV);
    FViewport.AddScreenEffect(FKuwahara);
    FViewport.AddScreenEffect(FStylize);
  end;

  ApplyState;
end;

destructor TScreenFX.Destroy;
begin
  { RemoveScreenEffect drops the viewport's reference; the nodes are
    refcounted X3D nodes and get freed with that last reference — do NOT
    free them manually here. }
  if Assigned(FViewport) then
  begin
    FViewport.RemoveScreenEffect(FBloomH);
    FViewport.RemoveScreenEffect(FBloomV);
    FViewport.RemoveScreenEffect(FKuwahara);
    FViewport.RemoveScreenEffect(FStylize);
  end;
  FBloomH := nil; FBloomV := nil; FKuwahara := nil; FStylize := nil;
  inherited Destroy;
end;

procedure TScreenFX.ApplyState;

  function Pick(const Cond: Boolean; const OnV, OffV: Single): Single;
  begin
    if Cond then Result := OnV else Result := OffV;
  end;

begin
  { effective uniforms: a disabled effect sends its "off" sentinel, so
    effects sharing a pass switch independently }
  if Assigned(FUniFogRange) then
    FUniFogRange.Send(Pick(FFogEnabled, FFogRange, 0));
  if Assigned(FUniStrengthH) then
    FUniStrengthH.Send(Pick(FBloomEnabled, FBloomStrength, 0));
  if Assigned(FUniStrengthV) then
    FUniStrengthV.Send(Pick(FBloomEnabled, FBloomStrength, 0));
  if Assigned(FUniToneMix) then
    FUniToneMix.Send(Pick(FToneEnabled, FToneMix, 0));
  if Assigned(FUniPosterLevels) then
    FUniPosterLevels.Send(Pick(FPosterEnabled, FPosterLevels, 0));
  if Assigned(FUniHatchStrength) then
    FUniHatchStrength.Send(Pick(FHatchEnabled, FHatchStrength, 0));

  { a pass with every effect off is disabled entirely — costs nothing }
  if Assigned(FBloomH) then
    FBloomH.Enabled := FEnabled and (FFogEnabled or FBloomEnabled);
  if Assigned(FBloomV) then
    FBloomV.Enabled := FEnabled and (FBloomEnabled or FToneEnabled);
  if Assigned(FKuwahara) then
    FKuwahara.Enabled := FEnabled and FKuwaharaEnabled;
  if Assigned(FStylize) then
    FStylize.Enabled := FEnabled and (FPosterEnabled or FHatchEnabled);
end;

procedure TScreenFX.SetEnabled(const V: Boolean);
begin
  if FEnabled = V then Exit;
  FEnabled := V;
  ApplyState;
end;

procedure TScreenFX.SetFogEnabled(const V: Boolean);
begin
  if FFogEnabled = V then Exit;
  FFogEnabled := V;
  ApplyState;
end;

procedure TScreenFX.SetBloomEnabled(const V: Boolean);
begin
  if FBloomEnabled = V then Exit;
  FBloomEnabled := V;
  ApplyState;
end;

procedure TScreenFX.SetToneEnabled(const V: Boolean);
begin
  if FToneEnabled = V then Exit;
  FToneEnabled := V;
  ApplyState;
end;

procedure TScreenFX.SetPosterizeEnabled(const V: Boolean);
begin
  if FPosterEnabled = V then Exit;
  FPosterEnabled := V;
  ApplyState;
end;

procedure TScreenFX.SetKuwaharaEnabled(const V: Boolean);
begin
  if FKuwaharaEnabled = V then Exit;
  FKuwaharaEnabled := V;
  ApplyState;
end;

procedure TScreenFX.SetHatchEnabled(const V: Boolean);
begin
  if FHatchEnabled = V then Exit;
  FHatchEnabled := V;
  ApplyState;
end;

procedure TScreenFX.SetBloomThreshold(const V: Single);
begin
  FBloomThreshold := V;
  if Assigned(FUniThresholdH) then FUniThresholdH.Send(V);
  if Assigned(FUniThresholdV) then FUniThresholdV.Send(V);
end;

procedure TScreenFX.SetBloomStrength(const V: Single);
begin
  FBloomStrength := V;
  ApplyState;   { effective value depends on BloomEnabled }
end;

procedure TScreenFX.SetToneExposure(const V: Single);
begin
  FToneExposure := V;
  if Assigned(FUniExposure) then FUniExposure.Send(V);
end;

procedure TScreenFX.SetToneMix(const V: Single);
begin
  FToneMix := V;
  ApplyState;   { effective value depends on ToneEnabled }
end;

procedure TScreenFX.SetFogColor(const V: TVector3);
begin
  FFogColor := V;
  if Assigned(FUniFogColor) then FUniFogColor.Send(V);
end;

procedure TScreenFX.SetFogRange(const V: Single);
begin
  FFogRange := V;
  ApplyState;   { effective value depends on FogEnabled }
end;

procedure TScreenFX.SetFogClearZone(const V: Single);
begin
  FFogClearZone := V;
  if FFogClearZone < 0 then FFogClearZone := 0;
  { Не через ApplyState: чистая зона не участвует в гейтах вкл/выкл
    (её «off»-значение = 0 совпадает с рабочим), шлём напрямую — как
    fog_color / fog_near / fog_far. }
  if Assigned(FUniFogClear) then FUniFogClear.Send(FFogClearZone);
end;

procedure TScreenFX.SetFogDepthNear(const V: Single);
begin
  FFogDepthNear := V;
  if Assigned(FUniFogNear) then FUniFogNear.Send(V);
end;

procedure TScreenFX.SetFogDepthFar(const V: Single);
begin
  FFogDepthFar := V;
  if Assigned(FUniFogFar) then FUniFogFar.Send(V);
end;

procedure TScreenFX.SetPosterizeLevels(const V: Single);
begin
  FPosterLevels := V;
  ApplyState;
end;

procedure TScreenFX.SetHatchStrength(const V: Single);
begin
  FHatchStrength := V;
  ApplyState;
end;

end.
