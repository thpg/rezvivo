{ Original full-canvas layers. No independently generated or resized boughs. }
{$I Osm3dVegetationLayerPivots.inc}
const
  BRANCH_VERTEX_GLSL =
    'layout(location=7) in vec4 branchPatch;' + #10 +
    'layout(location=8) in vec4 branchShape;' + #10 +
    'uniform int branchDetailPass, branchesEnabled;' + #10 +
    'uniform vec2 branchLodDistances;' + #10 +
    'flat out float vBranchFade;' + #10 +
    'flat out int vBranchPart;' + #10 +
    'flat out float vWindResponse;' + #10 +
    'bool branchPassVisible(vec3 origin) {' + #10 +
    '  float d=length(origin-cameraWorldPos);' + #10 +
    '  vBranchFade=branchesEnabled!=0 ? 1.0-smoothstep(branchLodDistances.x,branchLodDistances.y,d) : 0.0;' + #10 +
    '  vBranchPart=int(branchShape.x+0.5);' + #10 +
    '  bool visible=branchDetailPass!=0 ? vBranchFade>0.0 : vBranchFade<1.0;' + #10 +
    '  vWindResponse=visible ? windBend(origin.xz) : 0.0;' + #10 +
    '  return visible;' + #10 +
    '}' + #10 +
    'void turnBranch(inout vec3 p,inout vec3 n,vec2 pivot) {' + #10 +
    '  if(branchDetailPass==0) return;' + #10 +
    '  float a=vBranchFade*branchPatch.w*sin(branchPatch.z+instanceRotation*3.7);' + #10 +
    '  if(abs(a)<0.00001) return;' + #10 +
    '  mat2 r=mat2(cos(a),-sin(a),sin(a),cos(a));' + #10 +
    '  p.xz=pivot+r*(p.xz-pivot); n.xz=r*n.xz;' + #10 +
    '}' + #10;

  TREE_BRANCH_PIVOT_GLSL =
    '    vec2 pivot=branchPatch.xy;' + #10 +
    '    if(branchDetailPass!=0) pivot+=(treeLayerPivots[clamp(vTextureId,0,4)*8+vBranchPart]-.5)*branchShape.yz;' + #10;

  BRANCH_VERTEX_TAIL =
    '    turnBranch(p,n,pivot);' + #10 +
    '    p.xz=R*p.xz; n.xz=R*n.xz;' + #10 +
    '    vNormalWorld=normalize((modelMatrix*vec4(n,0.0)).xyz);' + #10 +
    '    gl_Position=projectionMatrix*viewMatrix*modelMatrix*vec4(p*instanceScale+instancePosition,1.0);' + #10 +
    '}' + #10;

  BRANCH_FRAGMENT_GLSL =
    'uniform int branchDetailPass;' + #10 +
    'uniform sampler2DArray tBranches;' + #10 +
    'flat in float vBranchFade;' + #10 +
    'flat in int vBranchPart;' + #10 +
    'flat in float vWindResponse;' + #10 +
    'bool branchPixelVisible() {' + #10 +
    '  if(vBranchFade<=0.0) return branchDetailPass==0;' + #10 +
    '  if(vBranchFade>=1.0) return branchDetailPass!=0;' + #10 +
    '  const int b[16]=int[16](0,8,2,10,12,4,14,6,3,11,1,9,15,7,13,5);' + #10 +
    '  ivec2 p=ivec2(gl_FragCoord.xy)&ivec2(3);' + #10 +
    '  bool nearPixel=(float(b[p.x+p.y*4])+.5)/16.0<vBranchFade;' + #10 +
    '  return (branchDetailPass!=0)==nearPixel;' + #10 +
    '}' + #10 +
    'bool branchLayerVisible(vec2 uv,int species) {' + #10 +
    '  return branchDetailPass==0 || int(texture(tBranches,vec3(uv,float(species))).r*255.0+.5)==vBranchPart;' + #10 +
    '}' + #10;
