varying vec4 vBldDetailColor;
varying vec3 vBldDetailNormal;
varying vec3 vBldShadowPosition;
uniform vec3 gc_SunDirToward;
vec3 direction_world_to_eye_space(vec3 d);
vec3 direction_eye_to_world_space(vec3 d);
vec4 position_eye_to_world_space(vec4 p);
vec3 bldDetailView;
void PLUG_fragment_eye_space(const vec4 vertex_eye, inout vec3 normal_eye)
{
    bldDetailView = normalize(direction_eye_to_world_space(-vertex_eye.xyz));
#ifndef BLD_NATIVE_LIGHTING
    gc_riderPosition = position_eye_to_world_space(vertex_eye).xyz;
    gc_riderRelativePosition = vBldShadowPosition +
                              normalize(vBldDetailNormal)*0.025;
#endif
    normal_eye = normalize(direction_world_to_eye_space(vBldDetailNormal));
}
void PLUG_main_texture_apply(inout vec4 fragment_color, const in vec3 normal)
{
    vec3 albedo = gc_SRGBtoLINEAR(vBldDetailColor.rgb);
#ifdef BLD_NATIVE_LIGHTING
    fragment_color.rgb *= albedo;
#else
    vec3 N=normalize(vBldDetailNormal), L=normalize(gc_SunDirToward), V=bldDetailView;
    vec3 H=normalize(L+V);
    float nl=max(dot(N,L),0.0), nv=max(dot(N,V),0.001);
    float alpha=vBldDetailColor.a*vBldDetailColor.a;
    vec3 F=specularReflection(vec3(0.04),vec3(1),max(dot(V,H),0.0));
    vec3 specular=F*visibilityOcclusion(alpha,nl,nv)*microfacetDistribution(alpha,max(dot(N,H),0.0));
    vec3 hemi=mix(vec3(0.31,0.29,0.25),vec3(0.49,0.55,0.63),N.y*0.5+0.5);
    vec3 linearColor=((vec3(1)-F)*albedo/3.141592653589793+specular)*nl*vec3(1.0,0.97,0.92)*8.0;
    linearColor *= 1.0-clamp(gc_sampleRiderShadow(),0.0,1.0);
    linearColor=(linearColor+albedo*hemi)*2.0;
    fragment_color.rgb=gc_LINEARtoSRGB(linearColor/(linearColor+vec3(1)));
#endif
    fragment_color.a=1.0;
}
