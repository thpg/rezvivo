unit Osm3dGlslLib;

{$mode objfpc}{$H+}
{$codepage UTF8}

interface

uses
  CastleVectors;

const
  GLSL_PBR_HELPERS =
    'vec3 gc_SRGBtoLINEAR(vec3 s) { return pow(s, vec3(2.2)); }' + #10 +
    'vec3 gc_LINEARtoSRGB(vec3 l) { return pow(l, vec3(1.0/2.2)); }' + #10 +
    '' + #10 +
    'vec3 specularReflection(vec3 F0, vec3 F90, float VdotH) {' + #10 +
    '    return F0 + (F90 - F0) * pow(clamp(1.0 - VdotH, 0.0, 1.0), 5.0);' + #10 +
    '}' + #10 +
    'float visibilityOcclusion(float aR, float NdotL, float NdotV) {' + #10 +
    '    float a2 = aR * aR;' + #10 +
    '    float GV = NdotL * sqrt(NdotV*NdotV*(1.0-a2)+a2);' + #10 +
    '    float GL = NdotV * sqrt(NdotL*NdotL*(1.0-a2)+a2);' + #10 +
    '    float G  = GV + GL;' + #10 +
    '    if (G > 0.0) return 0.5 / G;' + #10 +
    '    return 0.0;' + #10 +
    '}' + #10 +
    'float microfacetDistribution(float aR, float NdotH) {' + #10 +
    '    float a2 = aR * aR;' + #10 +
    '    float f = (NdotH * a2 - NdotH) * NdotH + 1.0;' + #10 +
    '    return a2 / (PI * f * f);' + #10 +
    '}' + #10;

  GLSL_COTANGENT_FRAME =
    '    vec3 nrmTS = nrmSample * 2.0 - 1.0;' + #10 +
    '    vec3 T, B;' + #10 +
    '    float det = du1.x*du2.y - du1.y*du2.x;' + #10 +
    '    if (abs(det) > 1e-6) {' + #10 +
    '        float invDet = 1.0/det;' + #10 +
    '        T = (dp1*du2.y - dp2*du1.y)*invDet;' + #10 +
    '        B = (dp2*du1.x - dp1*du2.x)*invDet;' + #10 +
    '    } else {' + #10 +
    '        T = dp1 - dot(dp1,N)*N;' + #10 +
    '        B = cross(N,T);' + #10 +
    '    }' + #10 +
    '    T = normalize(T - dot(T,N)*N);' + #10 +
    '    B = normalize(cross(N,T));' + #10 +
    '    vec3 worldN = normalize(mat3(T,B,N) * nrmTS);' + #10;

  GLSL_COOK_TORRANCE_SUN =
    '    vec3  F0           = mix(vec3(0.04), albedoLin, metallic);' + #10 +
    '    vec3  diffuseColor = albedoLin * (vec3(1.0) - F0) * (1.0 - metallic);' + #10 +
    '    float alphaRough   = perceptualRoughness * perceptualRoughness;' + #10 +
    '    float reflMax      = max(max(F0.r, F0.g), F0.b);' + #10 +
    '    vec3  F90          = vec3(clamp(reflMax * 50.0, 0.0, 1.0));' + #10 +
    '    vec3  L = normalize(gc_SunDirToward);' + #10 +
    '    vec3  H = normalize(L + V);' + #10 +
    '    float NdotL = clamp(dot(worldN, L), 0.0, 1.0);' + #10 +
    '    float NdotV = clamp(dot(worldN, V), 0.0, 1.0);' + #10 +
    '    float NdotH = clamp(dot(worldN, H), 0.0, 1.0);' + #10 +
    '    float VdotH = clamp(dot(V,      H), 0.0, 1.0);' + #10 +
    '    vec3 directLight = vec3(0.0);' + #10 +
    '    if (NdotL > 0.0) {' + #10 +
    '        vec3  Fr  = specularReflection(F0, F90, VdotH);' + #10 +
    '        float Vis = visibilityOcclusion(alphaRough, NdotL, NdotV);' + #10 +
    '        float D   = microfacetDistribution(alphaRough, NdotH);' + #10 +
    '        directLight = NdotL * ((vec3(1.0) - Fr) * diffuseColor / PI' + #10 +
    '                    + Fr * Vis * D) * SUN_COLOR * SUN_INTENSITY;' + #10 +
    '    }' + #10 +
    '    vec3 colorLin = directLight + diffuseColor * AMBIENT_FACTOR;' + #10;

  GLSL_INSTANCE_VERTEX_TAIL =
    '    vec3 modelNormal = (modelMatrix * vec4(normal, 0.0)).xyz;' + LineEnding +
    '    modelNormal.xz = R * modelNormal.xz;' + LineEnding +
    '    vNormalWorld = normalize(modelNormal);' + LineEnding +
    LineEnding +
    '    vec3 p = position;' + LineEnding +
    '    p.xz = R * p.xz;' + LineEnding +
    '    p *= instanceScale;' + LineEnding +
    '    p += instancePosition;' + LineEnding +
    LineEnding +
    '    gl_Position = projectionMatrix * viewMatrix * modelMatrix * vec4(p, 1.0);' + LineEnding +
    '}' + LineEnding;

  { LOD far-cull uniforms — общий блок для building/fence composite-шейдеров. }
  GLSL_LOD_UNIFORMS =
    '/* LOD — far cull only (near is handled CPU-side per tile). */' + #10 +
    'uniform float u_lod_far_base;' + #10 +
    'uniform float u_lod_height_ref;' + #10 +
    'uniform float u_lod_ground_ref_y;' + #10;

  { Солнце/ambient константы — общий блок для building/fence composite-шейдеров.
    ВНИМАНИЕ: ground и instanced (grass) шейдеры используют СВОИ значения
    (ground: AMBIENT_FACTOR → uniform; instanced: LineEnding вместо #10) и
    сюда сознательно не сведены, чтобы не менять байты их шейдеров. }
  GLSL_SUN_CONSTS =
    'const vec3  SUN_COLOR      = vec3(1.000, 0.970, 0.920);' + #10 +
    'const float SUN_INTENSITY  = 8.0;' + #10 +
    'const float AMBIENT_FACTOR = 0.45;' + #10;

  { Единое дефолтное солнце сцены — единственный источник fallback-значения.
    Реальное направление приходит из FIT через TOsm3dStreamingMap.SetSunDirection
    (дефолт там же — StreamingMap инициализирует FSunDir из DEFAULT_SUN_RAY_DIR).
    RayDir = направление РАСПРОСТРАНЕНИЯ света (Y < 0, как
    TDirectionalLightNode.Direction), Toward = направление НА солнце
    (= -RayDir, как gc_SunDirToward в composite-шейдерах). }
  DEFAULT_SUN_RAY_DIR: TVector3 = (X: -0.4; Y: -0.82; Z: -0.4);
  DEFAULT_SUN_TOWARD:  TVector3 = (X:  0.4; Y:  0.82; Z:  0.4);

  { Паскаль-зеркала констант яркости из GLSL_SUN_CONSTS выше и BLD_EXPOSURE
    в BUILDING_COMPOSITE_FS (Osm3dBuildingComposite) — для CPU-кода,
    повторяющего shading-пайплайн (BoxUnlitColor в Osm3dSceneAssembler).
    Держать равными GLSL-строкам; значения реально доезжают до шейдера
    (проверено: building FS использует GLSL_SUN_CONSTS + BLD_EXPOSURE=2.0).
    AMBIENT 0.18 из u_ground_ambient — ДРУГОЙ шейдер (ground), сюда не относится. }
  SUN_INTENSITY_VALUE  = 8.0;
  AMBIENT_FACTOR_VALUE = 0.45;
  BLD_EXPOSURE_VALUE   = 2.0;

implementation

end.
