unit Osm3dWaterShader;

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$codepage UTF8}

interface

uses Osm3dStaticGeometry,
  Classes, SysUtils, Math, CastleVectors, Osm3dGeomMesh,
  CastleRenderOptions,
  X3DNodes, X3DFields,
  Osm3dTileX3D,
  Osm3dCompositeShader           { TCompositeShader — базовый «шейдер композита» }
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
;

type
  { Анимированная вода как «шейдер композита» (Osm3dCompositeShader).
    Регистрируется в GROUND_MATERIALS[GROUND_MAT_WATER].ShaderClass.
    Open Sea style: wave-packet swell + FBM micro-surface + spectral tint +
    sun glint. Параметры: WaterWaveSize / WaterSeaState / WaterLevelLift. }
  TWaterCompositeShader = class(TCompositeShader)
  protected
    function BuildEffect: TEffectNode; override;
  public
    function MeshLift: Single; override;
  end;

{ Per-frame / teardown / диагностика — тонкие обёртки над общим
  диспетчером Osm3dCompositeShader. Сохранены, потому что их зовёт
  Osm3dStreamingMap; теперь они покрывают ВСЕ «шейдеры композита», а не
  только воду (новые шейдеры тикаются автоматически). }
procedure AttachWaterScale(Shape: TShapeNode; const Rec: TTileMeshRec; VertexCount: Integer; OriginX, OriginZ, Kx: Double);
procedure WaterShaderTick(SecondsElapsed: Single);
procedure ClearWaterShaderRegistry;
function WaterShaderFieldCount: Integer;
function WaterShaderClock: Single;

implementation

uses
  Osm3dStudioSettings            { WaterWaveSizeActive / WaterLevelLiftActive }
;

{
 GLSL SOURCES — embedded, no external files.
 }

{ Reference: Open Sea / Realtime Ocean, supplied as a visual reference.
  https://qdtipu6rd2myk.ok.kimi.link/.
  Reference lighting, gradient FBM, Fresnel/glitter/foam. Infinite crossing
  swells replaced by compact wave packets to avoid a lattice from above.
  Water remains in the terrain composite: normals animate, mesh stays draped.
  Source-body scale is baked once; global world XZ keeps phases across tiles.
  Demo plane-edge fog/bloom are replaced by the scene's existing rendering. }
const
  WATER_NOISE_GLSL: AnsiString =
    '// Open Sea reference: three-octave gradient FBM.' + #10 +
    'vec2 waterHash(vec2 p) {' + #10 +
    '  p=mod(p,256.0);' + #10 +
    '  vec3 h=fract(vec3(p.xyx)*vec3(0.1031,0.1030,0.0973));' + #10 +
    '  h+=dot(h,h.yzx+33.33);' + #10 +
    '  float a=6.28318530718*fract((h.x+h.y)*h.z);' + #10 +
    '  return vec2(cos(a),sin(a));' + #10 +
    '}' + #10 +
    'float waterNoise(vec2 p) {' + #10 +
    '  vec2 i=floor(p), f=fract(p);' + #10 +
    '  // Quintic fade has zero first/second derivatives at both cell edges.' + #10 +
    '  vec2 u=f*f*f*(f*(f*6.0-15.0)+10.0);' + #10 +
    '  float a=dot(waterHash(i),f);' + #10 +
    '  float b=dot(waterHash(i+vec2(1,0)),f-vec2(1,0));' + #10 +
    '  float c=dot(waterHash(i+vec2(0,1)),f-vec2(0,1));' + #10 +
    '  float d=dot(waterHash(i+vec2(1,1)),f-vec2(1,1));' + #10 +
    '  return mix(mix(a,b,u.x),mix(c,d,u.x),u.y);' + #10 +
    '}' + #10 +
    'float waterFbm(vec2 p,float footprint) {' + #10 +
    '  vec3 fade=1.0-smoothstep(vec3(0.2),vec3(0.7),footprint*vec3(1.0,2.236068,3.605551));' + #10 +
    '  return fade.x*waterNoise(p)+0.5*fade.y*waterNoise(mat2(2,1,-1,2)*p+vec2(17.3,9.1))+' + #10 +
    '    0.25*fade.z*waterNoise(mat2(3,2,-2,3)*p+vec2(42.7,28.6));' + #10 +
    '}' + #10;

  WATER_VERTEX_GLSL: AnsiString =
    'varying float water_mat_id;' + #10 +
    'varying vec2 water_data;' + #10 +
    'flat varying float water_scale;' + #10 +
    'attribute float materialId;' + #10 +
    'attribute float waterScale;' + #10 +
    'void PLUG_vertex_object_space(const in vec4 vertex_object,inout vec3 normal_object) {' + #10 +
    '  water_mat_id=materialId;' + #10 +
    '  water_data=vertex_object.xz; water_scale=waterScale;' + #10 +
    '}' + #10;

  WATER_FRAGMENT_GLSL: AnsiString =
    'varying float water_mat_id;' + #10 +
    'varying vec2 water_data;' + #10 +
    'flat varying float water_scale;' + #10 +
    'uniform vec2 waterOriginHi, waterOriginLo;' + #10 +
    'uniform float time;' + #10 +
    'uniform float wave_size;' + #10 +
    'uniform float sea_state;' + #10 +
    'uniform vec3 gc_SunDirToward;' + #10 +
    'vec4 position_eye_to_world_space(vec4 position_eye);' + #10 +
    'float waterFbm(vec2 p,float footprint);' + #10 +
    'vec3 gWaterToCamera;' + #10 +
    '// Compensated product: keep fractional phase even millions of metres away.' + #10 +
    'float waterProductError(float a,float b,float product) {' + #10 +
    '  float ac=4097.0*a, bc=4097.0*b;' + #10 +
    '  float ah=ac-(ac-a), bh=bc-(bc-b);' + #10 +
    '  float al=a-ah, bl=b-bh;' + #10 +
    '  return ((ah*bh-product)+ah*bl+al*bh)+al*bl;' + #10 +
    '}' + #10 +
    'float waterCoordinate(float local,float hi,float lo,float frequency,float period) {' + #10 +
    '  float product=hi*frequency;' + #10 +
    '  float error=waterProductError(hi,frequency,product);' + #10 +
    '  return mod(mod(product,period)+mod(error+lo*frequency,period)+mod(local*frequency,period),period);' + #10 +
    '}' + #10 +
    'vec2 waterCoordinates(vec2 local,float frequency) {' + #10 +
    '  return vec2(waterCoordinate(local.x,waterOriginHi.x,waterOriginLo.x,frequency,256.0),' + #10 +
    '              waterCoordinate(local.y,waterOriginHi.y,waterOriginLo.y,frequency,256.0));' + #10 +
    '}' + #10 +
    '' + #10 +
    '// Compact wave packets: no pair of infinite wave fronts can form a lattice.' + #10 +
    '// Jittered overlapping supports have zero height and slope at their boundary.' + #10 +
    'vec4 waterPacketHash(vec2 p) {' + #10 +
    '  p=mod(p,256.0);' + #10 +
    '  vec4 h=fract(p.xyxy*vec4(.1031,.1030,.0973,.1099));' + #10 +
    '  h+=dot(h,h.wzxy+33.33);' + #10 +
    '  return fract((h.xxyz+h.yzzw)*h.zywx);' + #10 +
    '}' + #10 +
    'vec3 waterPackets(vec2 p,float t,float footprint) {' + #10 +
    '  vec2 cell=floor(p),f=fract(p)-.5;' + #10 +
    '  vec3 result=vec3(0);' + #10 +
    '  for(int y=-1;y<=1;y++) for(int x=-1;x<=1;x++) {' + #10 +
    '    vec2 offset=vec2(float(x),float(y));' + #10 +
    '    vec4 random=waterPacketHash(cell+offset);' + #10 +
    '    vec2 r=f-offset-(random.xy-.5)*.6;' + #10 +
    '    float support=max(0.0,1.0-dot(r,r)/1.44);' + #10 +
    '    vec2 direction=normalize(vec2(.8,.6)+(random.w-.5)*vec2(-.6,.8)*.85);' + #10 +
    '    float frequency=mix(1.65,2.85,random.z);' + #10 +
    '    vec2 k=6.28318530718*frequency*direction;' + #10 +
    '    float phase=dot(k,r)+random.w*6.28318530718-t*sqrt(frequency)*.63;' + #10 +
    '    float fade=1.0-smoothstep(.025,.10,footprint*frequency);' + #10 +
    '    float s=sin(phase),c=cos(phase),e=support*support*support;' + #10 +
    '    vec2 de=(-6.0/1.44)*r*support*support;' + #10 +
    '    result+=fade*vec3(e*s,de*s+e*c*k);' + #10 +
    '  }' + #10 +
    '  return result;' + #10 +
    '}' + #10 +
    'vec3 waterSwell(vec2 p,float t,float scale,float pixelMetres) {' + #10 +
    '  float frequency=1.0/(75.0*scale);' + #10 +
    '  vec3 a=waterPackets(waterCoordinates(p,frequency),t,pixelMetres*frequency);' + #10 +
    '  // Integer rotation preserves the compensated 256-cell phase across tiles.' + #10 +
    '  mat2 rotation=mat2(2,1,-1,2);' + #10 +
    '  float frequencyB=1.0/(23.0*2.236067978*scale);' + #10 +
    '  vec3 b=waterPackets(rotation*waterCoordinates(p,frequencyB)+vec2(31.7,19.3),t*1.43,pixelMetres*frequencyB*2.236067978);' + #10 +
    '  vec2 bGradient=vec2(dot(rotation[0],b.yz),dot(rotation[1],b.yz));' + #10 +
    '  return vec3((a.x*.95+b.x*.29)*scale,' + #10 +
    '    a.yz*(.95*scale*frequency)+bGradient*(.29*scale*frequencyB));' + #10 +
    '}' + #10 +
    'void PLUG_fragment_eye_space(const vec4 vertex_eye,inout vec3 normal_eye) {' + #10 +
    '  gWaterToCamera=position_eye_to_world_space(vec4(-vertex_eye.xyz,0.0)).xyz;' + #10 +
    '}' + #10 +
    '' + #10 +
    'void PLUG_fragment_modify(inout vec4 fragment_color) {' + #10 +
    '  if (abs(water_mat_id-20.0)>=0.5) return;' + #10 +
    '  // Old imported tiles without the optional stream get calm small-water waves.' + #10 +
    '  float scale=water_scale>0.0 ? clamp(water_scale,0.005,1.0) : 0.01;' + #10 +
    '  vec2 xz=water_data.xy;' + #10 +
    '  vec2 p=xz;' + #10 +
    '  float t=time/sqrt(scale);' + #10 +
    '  float pixelMetres=max(length(dFdx(gWaterToCamera.xz)),length(dFdy(gWaterToCamera.xz)));' + #10 +
    '  float sea=0.25+1.5*clamp(sea_state,0.0,1.0);' + #10 +
    '  // Retain broad waves at twice the previous pixel footprint. Apply the' + #10 +
    '  // same LOD scale to packet filtering; capillary ripples keep their own AA.' + #10 +
    '  float swellPixelMetres=pixelMetres/2.0;' + #10 +
    '  float broadFade=1.0-smoothstep(0.3,1.5,swellPixelMetres/scale);' + #10 +
    '  float crest=0.0; vec3 n0=vec3(0,1,0);' + #10 +
    '  if (broadFade>0.001) {' + #10 +
    '    vec3 swell=waterSwell(p,t,scale,swellPixelMetres)*sea;' + #10 +
    '    crest=swell.x*broadFade;' + #10 +
    '    n0=normalize(mix(n0,normalize(vec3(-swell.y,1.0,-swell.z)),broadFade));' + #10 +
    '  }' + #10 +
    '  // Capillary ripples shrink more slowly than swell; default sea is exactly 1x.' + #10 +
    '  float microFrequency=max(wave_size,0.05)/(0.55*max(sqrt(scale),0.12));' + #10 +
    '  float mt=time;' + #10 +
    '  float footprint=max(length(dFdx(gWaterToCamera.xz)),length(dFdy(gWaterToCamera.xz)))*microFrequency;' + #10 +
    '  float microFade=1.0-smoothstep(0.08,0.5,footprint);' + #10 +
    '  vec3 detail=vec3(0);' + #10 +
    '  float glitterNoise=0.5;' + #10 +
    '  if (microFade>0.001) {' + #10 +
    '    vec2 a=waterCoordinates(xz,0.85*microFrequency)+vec2(mt*0.55,mt*0.32);' + #10 +
    '    vec2 b=waterCoordinates(xz,2.1*microFrequency)+vec2(-mt*0.4,mt*0.5);' + #10 +
    '    float fb=waterFbm(b,footprint*2.1);' + #10 +
    '    float h=waterFbm(a,footprint*0.85)+0.45*fb;' + #10 +
    '    float hx=waterFbm(a+vec2(0.085,0),footprint*0.85)+0.45*waterFbm(b+vec2(0.21,0),footprint*2.1);' + #10 +
    '    float hz=waterFbm(a+vec2(0,0.085),footprint*0.85)+0.45*waterFbm(b+vec2(0,0.21),footprint*2.1);' + #10 +
    '    detail=vec3(h-hx,0,h-hz)*1.5*(sea*0.6+0.4)*microFade;' + #10 +
    '    glitterNoise=fb*0.5+0.5;' + #10 +
    '  }' + #10 +
    '  vec3 N=normalize(n0+detail);' + #10 +
    '  vec3 V=normalize(gWaterToCamera);' + #10 +
    '  vec3 L=normalize(gc_SunDirToward);' + #10 +
    '  float daylight=smoothstep(0.0,0.42,asin(clamp(L.y,-1.0,1.0)));' + #10 +
    '  float sunVisible=smoothstep(-0.03,0.02,L.y);' + #10 +
    '  vec3 deep=mix(vec3(0.02,0.045,0.075),vec3(0.015,0.09,0.11),daylight);' + #10 +
    '  vec3 shallow=mix(vec3(0.09,0.15,0.2),vec3(0.06,0.32,0.36),daylight);' + #10 +
    '  vec3 horizon=mix(vec3(0.85,0.36,0.16),vec3(0.52,0.68,0.82),daylight);' + #10 +
    '  vec3 zenith=mix(vec3(0.03,0.05,0.16),vec3(0.07,0.2,0.42),daylight);' + #10 +
    '  vec3 sun=mix(vec3(1,0.42,0.14),vec3(1,0.93,0.8),daylight)*mix(2.6,1.6,daylight)*sunVisible;' + #10 +
    '  // Crest transmission belongs to a grazing view through the wave.' + #10 +
    '  // From above, it must not paint a high-contrast checkerboard on deep sea.' + #10 +
    '  float transmission=1.0-smoothstep(0.2,0.85,max(V.y,0.0));' + #10 +
    '  vec3 body=mix(deep,shallow,clamp(crest*0.35*mix(0.12,1.0,transmission)+0.45,0.0,1.0));' + #10 +
    '  body+=mix(shallow,sun,0.5)*pow(max(dot(V,L),0.0),3.0)*max(crest,0.0)*0.18*sunVisible*transmission;' + #10 +
    '  vec3 R=reflect(-V,N); R.y=max(R.y,0.04); R=normalize(R);' + #10 +
    '  vec3 sky=mix(horizon,zenith,pow(max(R.y,0.0),0.42));' + #10 +
    '  float sr=max(dot(R,L),0.0);' + #10 +
    '  sky+=sun*(pow(sr,10.0)*0.18+smoothstep(0.9994,0.9998,sr)*30.0);' + #10 +
    '  float fresnel=0.02+0.98*pow(1.0-clamp(dot(N,V),0.0,1.0),5.0);' + #10 +
    '  vec3 color=mix(body,sky,fresnel);' + #10 +
    '  vec3 H=normalize(L+V);' + #10 +
    '  float nh=max(dot(N,H),0.0);' + #10 +
    '  color+=sun*(pow(nh,500.0)*mix(0.4,3.4,glitterNoise)*microFade+pow(nh,48.0)*0.12);' + #10 +
    '  if (crest>1.0) {' + #10 +
    '    float foamNoise=waterFbm(waterCoordinates(xz,1.1*microFrequency)+vec2(mt*0.22,mt*0.14),footprint*1.1)*0.5+0.5;' + #10 +
    '    float foam=smoothstep(0.5,0.95,foamNoise)*smoothstep(1.0,2.0,crest);' + #10 +
    '    color=mix(color,vec3(0.82,0.88,0.9),clamp(foam*0.85,0.0,1.0));' + #10 +
    '  }' + #10 +
    '  // The game''s atmospheric fog runs after this plug; no demo-plane edge fade.' + #10 +
    '  fragment_color=vec4(color,1.0);' + #10 +
    '}' + #10;

{
 TWaterCompositeShader — реализация «шейдера композита» для воды.
 Состояние (эффекты отдельных сцен, поля time, общие часы) и весь lifecycle
 (ApplyToShape/Tick/Clear/Instance) живут в базовом TCompositeShader;
 здесь — только построение GLSL-эффекта и вертикальный подъём.
 }

function TWaterCompositeShader.BuildEffect: TEffectNode;
var
  PartNoise, PartVertex, PartFrag: TEffectPartNode;
  TimeField: TSFFloat;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1828);{$ENDIF}
  Result := TEffectNode.Create;
  Result.Language := slGLSL;
  { даёт position_eye_to_world_space() — как в шейдере окон домов }
  Result.SetShaderLibraries(['castle-shader:/EyeWorldSpace.glsl']);
  { ApplyToShape attaches this effect to one scene-owned appearance. }

  PartNoise := TEffectPartNode.Create;
  PartNoise.ShaderType := stFragment;
  PartNoise.Contents   := WATER_NOISE_GLSL;

  PartVertex := TEffectPartNode.Create;
  PartVertex.ShaderType := stVertex;
  PartVertex.Contents   := WATER_VERTEX_GLSL;

  PartFrag := TEffectPartNode.Create;
  PartFrag.ShaderType := stFragment;
  PartFrag.Contents   := WATER_FRAGMENT_GLSL;

  Result.SetParts([PartNoise, PartVertex, PartFrag]);

  { 'time' — общие часы анимации; отдаём базовому классу для Tick. }
  TimeField := TSFFloat.Create(Result, True, 'time', 0.0);
  Result.AddCustomField(TimeField);
  SetTimeField(TimeField);

  { 'wave_size' — FBM micro spatial frequency (меньше = крупнее рябь). }
  Result.AddCustomField(TSFFloat.Create(Result, True, 'wave_size',
    WaterWaveSizeActive));
  { 'sea_state' — Open Sea intensity 0..1 (0.45 ≈ demo "Sea State 45"). }
  Result.AddCustomField(TSFFloat.Create(Result, True, 'sea_state',
    WaterSeaStateActive));
  { Ветер: windSpeedAt() / uWind* — из composite FS, не дублируем. }
end;

function TWaterCompositeShader.MeshLift: Single;
begin
  Result := WaterLevelLiftActive;
end;

{ ----- обёртки над общим диспетчером (см. интерфейс) ----- }

procedure AttachWaterScale(Shape: TShapeNode; const Rec: TTileMeshRec; VertexCount: Integer; OriginX, OriginZ, Kx: Double);
var
  Values: array of Single;
  A: TFloatVertexAttributeNode;
  I: Integer;
  HasWater: Boolean;
  Geo: TIndexedFaceSetNode;
  E: TEffectNode;
  Part: TEffectPartNode;
  Hi, Lo: TVector2;
begin
  if (Shape = nil) or not (Shape.Geometry is TIndexedFaceSetNode) then Exit;
  Geo := Shape.Geometry as TIndexedFaceSetNode;
  HasWater := False;
  for I := 0 to High(Rec.MatIds) do
    if Rec.MatIds[I] = 20 then begin HasWater := True; Break end;
  if not HasWater then Exit;
  SetLength(Values,VertexCount);
  for I := 0 to Min(High(Rec.MatIds),VertexCount-1) do
    if Rec.MatIds[I] = 20 then
    begin
      if (I < Length(Rec.WaterScale)) and (Rec.WaterScale[I] <> 0) then
        Values[I] := Abs(Rec.WaterScale[I])
      else Values[I] := 0.01;
    end;
  A := TFloatVertexAttributeNode.Create;
  A.NameField := 'waterScale'; A.NumComponents := 1;
  AssignStaticField(A.FdValue, Values); Geo.FdAttrib.Add(A);
  Hi := Vector2(OriginX,OriginZ);
  Lo := Vector2(OriginX-Double(Hi.X),OriginZ-Double(Hi.Y));
  E := TEffectNode.Create; E.Language := slGLSL;
  Part := TEffectPartNode.Create; Part.ShaderType := stFragment;
  Part.Contents := '// Per-tile compensated water phase origin'; E.SetParts([Part]);
  E.AddCustomField(TSFVec2f.Create(E,True,'waterOriginHi',Hi));
  E.AddCustomField(TSFVec2f.Create(E,True,'waterOriginLo',Lo));
  (Shape.Appearance as TAppearanceNode).FdEffects.Add(E);
end;

procedure WaterShaderTick(SecondsElapsed: Single);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1016);{$ENDIF}
  CompositeShaderTickAll(SecondsElapsed);
end;

procedure ClearWaterShaderRegistry;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1017);{$ENDIF}
  CompositeShaderClearAll;
end;

function WaterShaderFieldCount: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1829);{$ENDIF}
  Result := CompositeShaderLiveCount;
end;

function WaterShaderClock: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1830);{$ENDIF}
  Result := CompositeShaderMaxClock;
end;

end.
