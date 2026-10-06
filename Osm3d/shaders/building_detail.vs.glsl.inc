{ Generated from building_detail.vs.glsl by tools/embed_building_shaders.py. }
  'attribute vec4 bldDetailColor;' + #10 +
  'attribute vec3 bldDetailNormal;' + #10 +
  'attribute vec3 bldDetailAnchor;' + #10 +
  'uniform mat4 castle_ModelMatrix;' + #10 +
  'uniform vec3 gc_rider_camera;' + #10 +
  'varying vec3 vBldShadowPosition;' + #10 +
  'uniform float u_bld_detail_near;' + #10 +
  'uniform float u_bld_detail_far;' + #10 +
  '// CGE also declares this in its main shader object.' + #10 +
  '#ifndef GL_ES' + #10 +
  'uniform mat4 castle_ModelViewMatrix;' + #10 +
  '#endif' + #10 +
  'varying vec4 vBldDetailColor;' + #10 +
  'varying vec3 vBldDetailNormal;' + #10 +
  'void PLUG_vertex_object_space_change(inout vec4 vertex_object, inout vec3 normal_object)' + #10 +
  '{' + #10 +
  '    vec3 anchorEye = (castle_ModelViewMatrix*vec4(bldDetailAnchor,1)).xyz;' + #10 +
  '    float weight = 1.0-smoothstep(u_bld_detail_near,u_bld_detail_far,length(anchorEye));' + #10 +
  '    // Anchors lie on the component''s long axis. Cornices keep their length and' + #10 +
  '    // posts keep their height while their cross-section smoothly disappears.' + #10 +
  '    // Distant triangles become collinear: no alpha/discard or per-frame CPU work.' + #10 +
  '    vertex_object.xyz = mix(bldDetailAnchor,vertex_object.xyz,weight);' + #10 +
  '}' + #10 +
  'void PLUG_vertex_object_space(const in vec4 vertex_object, const in vec3 normal_object)' + #10 +
  '{' + #10 +
  '    vBldDetailColor = bldDetailColor;' + #10 +
  '    vBldDetailNormal = bldDetailNormal;' + #10 +
  '    vBldShadowPosition = (castle_ModelMatrix * vertex_object).xyz - gc_rider_camera;' + #10 +
  '}' + #10
