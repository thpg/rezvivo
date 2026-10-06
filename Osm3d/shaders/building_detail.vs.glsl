attribute vec4 bldDetailColor;
attribute vec3 bldDetailNormal;
attribute vec3 bldDetailAnchor;
uniform mat4 castle_ModelMatrix;
uniform vec3 gc_rider_camera;
varying vec3 vBldShadowPosition;
uniform float u_bld_detail_near;
uniform float u_bld_detail_far;
// CGE also declares this in its main shader object.
#ifndef GL_ES
uniform mat4 castle_ModelViewMatrix;
#endif
varying vec4 vBldDetailColor;
varying vec3 vBldDetailNormal;
void PLUG_vertex_object_space_change(inout vec4 vertex_object, inout vec3 normal_object)
{
    vec3 anchorEye = (castle_ModelViewMatrix*vec4(bldDetailAnchor,1)).xyz;
    float weight = 1.0-smoothstep(u_bld_detail_near,u_bld_detail_far,length(anchorEye));
    // Anchors lie on the component's long axis. Cornices keep their length and
    // posts keep their height while their cross-section smoothly disappears.
    // Distant triangles become collinear: no alpha/discard or per-frame CPU work.
    vertex_object.xyz = mix(bldDetailAnchor,vertex_object.xyz,weight);
}
void PLUG_vertex_object_space(const in vec4 vertex_object, const in vec3 normal_object)
{
    vBldDetailColor = bldDetailColor;
    vBldDetailNormal = bldDetailNormal;
    vBldShadowPosition = (castle_ModelMatrix * vertex_object).xyz - gc_rider_camera;
}
