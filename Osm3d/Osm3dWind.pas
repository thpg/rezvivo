unit Osm3dWind;

{ Scene-wide wind — the SINGLE source of truth shared by grass and trees.

  Design:
  - One config record (TWindConfig) holds the tunables; GlobalWind is what the
    rendering units read (same pattern as GlobalLODConfig). The settings/UI
    assigns GlobalWind once at startup and whenever it changes.
  - The actual wind FIELD lives in GLSL (WIND_GLSL): windSpeedAt(xz) returns the
    local wind SPEED in m/s (mean + travelling gusts), and windBend(xz) turns that
    into a dimensionless plant-deflection response via a drag/Vogel law. Both the
    grass vertex shader and the tree fragment shader include this *same* string and
    call it with their world XZ,
    so a gust rolls through grass and trees together.
  - Time comes from an absolute monotonic clock (GetTickCount64). No per-frame
    tick, no Update, no frame-token: every renderer reads the same WindNow, so
    there is nothing to keep in sync and nothing to double-advance.

  "Speed" here is an abstract strength, not m/s — each renderer multiplies it
  by its own gain to get a visual amount (grass bend / tree canopy lean). }

{$mode objfpc}{$H+}{$modeswitch advancedrecords}

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

interface

uses
  CastleVectors, CastleGL;

type
  { Tunable wind settings. Assign GlobalWind from the settings/UI. }
  TWindConfig = record
    Direction:          TVector2;   { horizontal wind direction (xz), normalised on use }
    BaseSpeedMin:       Single;     { mean wind speed range, m/s (wanders over time) }
    BaseSpeedMax:       Single;
    BaseChangeInterval: Single;     { seconds — how fast the mean wind wanders }
    GustSpeedMin:       Single;     { gust speed amplitude added to the mean, m/s }
    GustSpeedMax:       Single;
    GustFrequency:      Single;     { DEPRECATED — gusts now advect at the mean wind (Taylor); unused }
    RepeatLength:       Single;     { gust spatial scale (eddy size), metres }
    class function Defaults: TWindConfig; static;
  end;

  { Cached uniform locations for WIND_GLSL in one linked program. -1 = absent
    (shader does not include WIND_GLSL — e.g. shrubs), then the setter skips it. }
  TWindUniforms = record
    Dir, Time, Base, GustMin, GustMax, GustSpeed, Repeat_: GLint;
  end;

var
  { Rendering units read wind from here. Initialised to Defaults below so direct
    reads never see uninitialised data before the app assigns settings. }
  GlobalWind: TWindConfig;

{ Seconds since the unit started (absolute monotonic clock). The shaders'
  uWindTime. Cheap; safe to call many times per frame from many renderers. }
{ Negative time returns to the normal real-time clock. Main thread only. }
procedure WindSetPlaybackTime(Seconds: Single);
function WindNow: Single;

{ Current base wind speed — base range remapped by a slow value-noise over time
  (period ~ BaseChangeInterval). This is the "main wind speed that changes". }
function WindCurrentBaseSpeed: Single;
{ Same coarse travelling gust field as WIND_GLSL, for CPU guide physics. }
function WindVelocityAt(const WorldPosition:TVector3):TVector3;

{ Look up / clear / push the WIND_GLSL uniforms for a program. WindSetUniforms
  reads GlobalWind + WindNow and pushes everything (each location guarded). }
function  WindCacheUniforms(AProgram: GLuint): TWindUniforms;
function  WindZeroUniforms: TWindUniforms;
procedure WindSetUniforms(const U: TWindUniforms);

const
  { GLSL both the grass and tree shaders concatenate verbatim. Declares the wind
    uniforms, windSpeedAt() (m/s) and windBend() (deflection response). The HOST
    shader must therefore NOT separately
    declare uWindDir / uWindTime / etc. uWindDir is a vec2 (horizontal).
    NB: a *true* constant (no ': AnsiString') so it is a constant expression and
    can be concatenated inside the shaders' own typed-constant initialisers —
    a typed constant cannot, FPC rejects it as "Illegal expression". }
  WIND_GLSL =
    'uniform vec2  uWindDir;'#10 +        // normalised horizontal
    'uniform float uWindTime;'#10 +       // seconds
    'uniform float uWindBase;'#10 +       // current base speed (time-varied on CPU)
    'uniform float uWindGustMin;'#10 +
    'uniform float uWindGustMax;'#10 +
    'uniform float uWindGustSpeed;'#10 +  // gust-wave travel speed (m/s)
    'uniform float uWindRepeat;'#10 +     // spatial repeat length (m)
    'float w_hash21(vec2 p){'#10 +
    '    p = fract(p * vec2(123.34, 345.45));'#10 +
    '    p += dot(p, p + 34.345);'#10 +
    '    return fract(p.x * p.y);'#10 +
    '}'#10 +
    '// Local wind SPEED in m/s = mean wind + a coarse, repeating gust grid that'#10 +
    '// advects along the wind direction (Taylor frozen turbulence).'#10 +
    'float windSpeedAt(vec2 xz){'#10 +
    '    const float CELLS = 4.0;                       // coarse: CELLSxCELLS / repeat'#10 +
    '    float cell = max(uWindRepeat / CELLS, 0.001);'#10 +
    '    vec2  q  = xz - uWindDir * (uWindGustSpeed * uWindTime);'#10 +
    '    vec2  g  = q / cell;'#10 +
    '    vec2  gi = floor(g);'#10 +
    '    vec2  gf = g - gi;'#10 +
    '    // wrap corner indices mod CELLS so the field tiles every uWindRepeat'#10 +
    '    float ha = w_hash21(mod(gi + vec2(0.0,0.0), CELLS));'#10 +
    '    float hb = w_hash21(mod(gi + vec2(1.0,0.0), CELLS));'#10 +
    '    float hc = w_hash21(mod(gi + vec2(0.0,1.0), CELLS));'#10 +
    '    float hd = w_hash21(mod(gi + vec2(1.0,1.0), CELLS));'#10 +
    '    vec2  u  = gf*gf*(3.0 - 2.0*gf);'#10 +
    '    float n  = mix(mix(ha,hb,u.x), mix(hc,hd,u.x), u.y);'#10 +
    '    return uWindBase + mix(uWindGustMin, uWindGustMax, n);'#10 +   // m/s
    '}'#10 +
    '// --- physical bend response ---------------------------------------------'#10 +
    '// Drag force ~ U^2 (dynamic pressure q = 0.5*rho*U^2); flexible plants'#10 +
    '// reconfigure (Vogel), so the bending load grows as U^(2+beta), beta~-0.7,'#10 +
    '// i.e. ~U^1.3. Tip deflection (linear-elastic cantilever) tracks that load'#10 +
    '// and saturates at high wind. windResp() = dimensionless deflection vs the'#10 +
    '// reference speed; each renderer multiplies it by its own metres-at-ref.'#10 +
    'const float WIND_U_REF    = 10.0;   // reference wind speed (m/s)'#10 +
    'const float WIND_VOGEL_P  = 1.3;    // drag/deflection exponent = 2 + Vogel beta'#10 +
    'const float WIND_RESP_MAX = 2.5;    // saturation cap on the response'#10 +
    'float windResp(float U){'#10 +
    '    return clamp(pow(max(U,0.0)/WIND_U_REF, WIND_VOGEL_P), 0.0, WIND_RESP_MAX);'#10 +
    '}'#10 +
    '// Dimensionless bend response at a world point (sample speed, apply the law).'#10 +
    'float windBend(vec2 xz){ return windResp(windSpeedAt(xz)); }'#10;

implementation

uses
  SysUtils, Math;

var
  FPlaybackTime: Single = -1;
  FStartTick: QWord;
  FStarted:   Boolean = False;

class function TWindConfig.Defaults: TWindConfig;
begin
  Result.Direction          := Vector2(1.0, 0.0);
  Result.BaseSpeedMin       := 1.5;    { light breeze, m/s }
  Result.BaseSpeedMax       := 3.0;    { gentle breeze, m/s }
  Result.BaseChangeInterval := 15.0;
  Result.GustSpeedMin       := 0.0;
  Result.GustSpeedMax       := 4.0;    { gusts add up to +4 m/s }
  Result.GustFrequency      := 0.0;    { unused (Taylor advection) }
  Result.RepeatLength       := 120.0;  { gust eddy scale, metres }
end;

procedure WindSetPlaybackTime(Seconds: Single);
begin FPlaybackTime:=Seconds end;

function WindNow: Single;
begin
  if FPlaybackTime>=0 then Exit(FPlaybackTime);
  if not FStarted then
  begin
    FStartTick := GetTickCount64;
    FStarted   := True;
  end;
  Result := (GetTickCount64 - FStartTick) / 1000.0;
end;

{ 1D integer hash -> [0,1). }
function Hash1(N: Integer): Single;
var H: Cardinal;
begin
  H := Cardinal(N) * 2654435761;     { Knuth multiplicative }
  H := H xor (H shr 13);
  H := H * 1274126177;
  Result := (H and $00FFFFFF) / $01000000;
end;

{ 1D smooth value noise in [0,1] (hash lattice + smoothstep). }
function VNoise1(X: Single): Single;
var I: Integer; F, A, B, U: Single;
begin
  I := Floor(X);
  F := X - I;
  A := Hash1(I);
  B := Hash1(I + 1);
  U := F * F * (3.0 - 2.0 * F);
  Result := A + (B - A) * U;
end;

function WindCurrentBaseSpeed: Single;
var Cfg: TWindConfig; N: Single;
begin
  Cfg := GlobalWind;
  if Cfg.BaseChangeInterval < 0.01 then
    N := 0.5
  else
    N := VNoise1(WindNow / Cfg.BaseChangeInterval);
  Result := Cfg.BaseSpeedMin + N * (Cfg.BaseSpeedMax - Cfg.BaseSpeedMin);
end;

function WindVelocityAt(const WorldPosition:TVector3):TVector3;
var D:TVector2; Base,Cell,X,Z,IX,IZ,U,V,A,B,C,E,N,Speed:Single;
  function Corner(X,Z:Single):Single;
  var DotValue:Single;
  begin
    X:=X-Floor(X/4)*4; Z:=Z-Floor(Z/4)*4;
    X:=X*123.34; X:=X-Floor(X);
    Z:=Z*345.45; Z:=Z-Floor(Z);
    DotValue:=X*(X+34.345)+Z*(Z+34.345);
    X:=X+DotValue; Z:=Z+DotValue;
    Result:=X*Z; Result:=Result-Floor(Result);
  end;
begin
  D:=GlobalWind.Direction;
  if D.Length>1e-5 then D:=D.Normalize else D:=Vector2(1,0);
  Base:=WindCurrentBaseSpeed;Cell:=Max(GlobalWind.RepeatLength/4,0.001);
  X:=(WorldPosition.X-D.X*Base*WindNow)/Cell;
  Z:=(WorldPosition.Z-D.Y*Base*WindNow)/Cell;
  IX:=Floor(X);IZ:=Floor(Z);U:=X-IX;V:=Z-IZ;
  U:=U*U*(3-2*U);V:=V*V*(3-2*V);
  A:=Corner(IX,IZ);B:=Corner(IX+1,IZ);
  C:=Corner(IX,IZ+1);E:=Corner(IX+1,IZ+1);
  N:=(A+(B-A)*U)*(1-V)+(C+(E-C)*U)*V;
  Speed:=Base+GlobalWind.GustSpeedMin+
    (GlobalWind.GustSpeedMax-GlobalWind.GustSpeedMin)*N;
  Result:=Vector3(D.X*Speed,0,D.Y*Speed);
end;

function WindCacheUniforms(AProgram: GLuint): TWindUniforms;
begin
  Result.Dir       := glGetUniformLocation(AProgram, 'uWindDir');
  Result.Time      := glGetUniformLocation(AProgram, 'uWindTime');
  Result.Base      := glGetUniformLocation(AProgram, 'uWindBase');
  Result.GustMin   := glGetUniformLocation(AProgram, 'uWindGustMin');
  Result.GustMax   := glGetUniformLocation(AProgram, 'uWindGustMax');
  Result.GustSpeed := glGetUniformLocation(AProgram, 'uWindGustSpeed');
  Result.Repeat_   := glGetUniformLocation(AProgram, 'uWindRepeat');
end;

function WindZeroUniforms: TWindUniforms;
begin
  Result.Dir := -1; Result.Time := -1; Result.Base := -1;
  Result.GustMin := -1; Result.GustMax := -1; Result.GustSpeed := -1;
  Result.Repeat_ := -1;
end;

procedure WindSetUniforms(const U: TWindUniforms);
var
  Cfg:  TWindConfig;
  D:    TVector2;
  Base, GustSpeed, TimeNow: Single;
begin
  Cfg := GlobalWind;

  D := Cfg.Direction;
  if D.Length > 1e-5 then D := D.Normalize
  else D := Vector2(1.0, 0.0);

  Base    := WindCurrentBaseSpeed;
  TimeNow := WindNow;
  { Taylor frozen turbulence: the gust pattern is carried downwind at the mean
    wind speed, so the field scrolls at the current base speed (m/s). }
  GustSpeed := Base;

  if U.Dir       >= 0 then glUniform2fv(U.Dir, 1, @D);
  if U.Time      >= 0 then glUniform1f(U.Time, TimeNow);
  if U.Base      >= 0 then glUniform1f(U.Base, Base);
  if U.GustMin   >= 0 then glUniform1f(U.GustMin, Cfg.GustSpeedMin);
  if U.GustMax   >= 0 then glUniform1f(U.GustMax, Cfg.GustSpeedMax);
  if U.GustSpeed >= 0 then glUniform1f(U.GustSpeed, GustSpeed);
  if U.Repeat_   >= 0 then glUniform1f(U.Repeat_, Cfg.RepeatLength);
end;

initialization
  GlobalWind := TWindConfig.Defaults;

end.
