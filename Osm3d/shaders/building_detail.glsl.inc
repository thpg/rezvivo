{ Generated from building_detail.glsl by tools/embed_building_shaders.py. }
  'varying vec4 vBldDetailColor;' + #10 +
  'varying vec3 vBldDetailNormal;' + #10 +
  'varying vec3 vBldShadowPosition;' + #10 +
  'uniform vec3 gc_SunDirToward;' + #10 +
  'vec3 direction_world_to_eye_space(vec3 d);' + #10 +
  'vec3 direction_eye_to_world_space(vec3 d);' + #10 +
  'vec4 position_eye_to_world_space(vec4 p);' + #10 +
  'vec3 bldDetailView;' + #10 +
  'void PLUG_fragment_eye_space(const vec4 vertex_eye, inout vec3 normal_eye)' + #10 +
  '{' + #10 +
  '    bldDetailView = normalize(direction_eye_to_world_space(-vertex_eye.xyz));' + #10 +
  '#ifndef BLD_NATIVE_LIGHTING' + #10 +
  '    gc_riderPosition = position_eye_to_world_space(vertex_eye).xyz;' + #10 +
  '    gc_riderRelativePosition = vBldShadowPosition +' + #10 +
  '                              normalize(vBldDetailNormal)*0.025;' + #10 +
  '#endif' + #10 +
  '    normal_eye = normalize(direction_world_to_eye_space(vBldDetailNormal));' + #10 +
  '}' + #10 +
  'void PLUG_main_texture_apply(inout vec4 fragment_color, const in vec3 normal)' + #10 +
  '{' + #10 +
  '    vec3 albedo = gc_SRGBtoLINEAR(vBldDetailColor.rgb);' + #10 +
  '#ifdef BLD_NATIVE_LIGHTING' + #10 +
  '    fragment_color.rgb *= albedo;' + #10 +
  '#else' + #10 +
  '    vec3 N=normalize(vBldDetailNormal), L=normalize(gc_SunDirToward), V=bldDetailView;' + #10 +
  '    vec3 H=normalize(L+V);' + #10 +
  '    float nl=max(dot(N,L),0.0), nv=max(dot(N,V),0.001);' + #10 +
  '    float alpha=vBldDetailColor.a*vBldDetailColor.a;' + #10 +
  '    vec3 F=specularReflection(vec3(0.04),vec3(1),max(dot(V,H),0.0));' + #10 +
  '    vec3 specular=F*visibilityOcclusion(alpha,nl,nv)*microfacetDistribution(alpha,max(dot(N,H),0.0));' + #10 +
  '    vec3 hemi=mix(vec3(0.31,0.29,0.25),vec3(0.49,0.55,0.63),N.y*0.5+0.5);' + #10 +
  '    vec3 linearColor=((vec3(1)-F)*albedo/3.141592653589793+specular)*nl*vec3(1.0,0.97,0.92)*8.0;' + #10 +
  '    linearColor *= 1.0-clamp(gc_sampleRiderShadow(),0.0,1.0);' + #10 +
  '    linearColor=(linearColor+albedo*hemi)*2.0;' + #10 +
  '    fragment_color.rgb=gc_LINEARtoSRGB(linearColor/(linearColor+vec3(1)));' + #10 +
  '#endif' + #10 +
  '    fragment_color.a=1.0;' + #10 +
  '}' + #10
