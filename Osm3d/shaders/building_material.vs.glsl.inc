{ Generated from building_material.vs.glsl by tools/embed_building_shaders.py. }
  'attribute float materialId;' + #10 +
  'attribute vec2 bldUV;' + #10 +
  'attribute vec3 bldNormal;' + #10 +
  'attribute vec4 bldInfo;' + #10 +
  'uniform mat4 castle_ModelMatrix;' + #10 +
  'uniform vec3 gc_rider_camera;' + #10 +
  'varying vec3 vBldShadowPosition;' + #10 +
  'varying float vBldMatId;' + #10 +
  'varying vec2 vBldUV;' + #10 +
  'varying vec3 vBldNormalOS;' + #10 +
  'varying vec2 vBldMetric;' + #10 +
  'flat varying vec2 vBldSeed;' + #10 +
  '' + #10 +
  'void PLUG_vertex_object_space(const in vec4 vertex_object,' + #10 +
  '                              const in vec3 normal_object)' + #10 +
  '{' + #10 +
  '    vBldMatId = materialId;' + #10 +
  '    vBldUV = bldUV;' + #10 +
  '    vBldNormalOS = bldNormal;' + #10 +
  '    vBldMetric = bldInfo.xy;' + #10 +
  '    vBldSeed = bldInfo.zw;' + #10 +
  '    // Subtract before interpolation; never reconstruct distant geometry by' + #10 +
  '    // undoing the camera rotation in the fragment shader.' + #10 +
  '    vBldShadowPosition = (castle_ModelMatrix * vertex_object).xyz - gc_rider_camera;' + #10 +
  '}' + #10
