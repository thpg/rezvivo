attribute float materialId;
attribute vec2 bldUV;
attribute vec3 bldNormal;
attribute vec4 bldInfo;
uniform mat4 castle_ModelMatrix;
uniform vec3 gc_rider_camera;
varying vec3 vBldShadowPosition;
varying float vBldMatId;
varying vec2 vBldUV;
varying vec3 vBldNormalOS;
varying vec2 vBldMetric;
flat varying vec2 vBldSeed;

void PLUG_vertex_object_space(const in vec4 vertex_object,
                              const in vec3 normal_object)
{
    vBldMatId = materialId;
    vBldUV = bldUV;
    vBldNormalOS = bldNormal;
    vBldMetric = bldInfo.xy;
    vBldSeed = bldInfo.zw;
    // Subtract before interpolation; never reconstruct distant geometry by
    // undoing the camera rotation in the fragment shader.
    vBldShadowPosition = (castle_ModelMatrix * vertex_object).xyz - gc_rider_camera;
}
