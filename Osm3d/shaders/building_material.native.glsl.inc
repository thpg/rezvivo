{ Generated from building_material.native.glsl by tools/embed_building_shaders.py. }
  'void PLUG_material_metallic_roughness(inout float metallic, inout float perceptualRoughness)' + #10 +
  '{' + #10 +
  '    metallic = bldMetallic;' + #10 +
  '    perceptualRoughness = bldRoughness;' + #10 +
  '}' + #10 +
  'void PLUG_material_emissive(inout vec3 emissive)' + #10 +
  '{' + #10 +
  '    emissive += bldEnvironment;' + #10 +
  '}' + #10 +
  'void PLUG_light_scale(inout float scale, const in vec3 normal_eye, const in vec3 light_dir)' + #10 +
  '{' + #10 +
  '    // Only attenuate the ambient fill. Leave the sun and its native shadow alone.' + #10 +
  '    vec3 L = normalize(direction_eye_to_world_space(light_dir));' + #10 +
  '    float isSun = smoothstep(0.985,0.998,dot(L,normalize(gc_SunDirToward)));' + #10 +
  '    scale *= mix(bldCavity,1.0,isSun);' + #10 +
  '}' + #10
