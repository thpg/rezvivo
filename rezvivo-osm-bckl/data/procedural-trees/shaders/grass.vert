#version 330 core
layout(location=0) in vec4 aBase;
layout(location=1) in vec4 aSurface;
layout(location=2) in vec4 aAB;
layout(location=3) in vec4 aC;
uniform mat4 uProjection,uView,uModel;
uniform vec3 uCamera,uSun;
uniform vec4 uProfile[8];
uniform vec4 uGrowth[8]; // broad leaves, rosettes, seed heads, dry blades
uniform vec2 uWeeds[8]; // sparse plants per patch, maximum stalk height
uniform float uVariation[8];
uniform vec3 uColors[8];
uniform vec3 uBladeViewGain[32];
uniform float uTime,uWind,uDistanceOverride;
uniform vec4 uLodDistances; // blades start/end, visibility fade/end
uniform vec2 uTopDistances;
uniform vec2 uDensityDistances;
uniform int uMode,uBake,uGrid,uSlice;
uniform int uGeometryDetail;
out vec3 vColor;
out vec2 vBlade;
flat out int vForm;
out vec3 vBladeGain;
flat out float vPopulation;
out vec2 vSurfaceXZ;
out float vSlopeUp;
flat out vec2 vBladeRange;
flat out vec2 vWeedRange;
out vec2 vUV;
flat out int vKind;
flat out int vSlice;
flat out vec4 vAB;
flat out vec2 vC;
flat out float vTopBlend;
flat out vec2 vWeedCard;
out vec2 vRoot;
out vec3 vShadowRelative;
uint hash(uint n){n^=n>>16u;n*=0x7feb352du;n^=n>>15u;n*=0x846ca68bu;return n^(n>>16u);}
float edge(vec2 a,vec2 b,vec2 p){vec2 d=b-a;return d.x*(p.y-a.y)-d.y*(p.x-a.x);}
bool inside(vec2 p){vec3 e=vec3(edge(aAB.xy,aAB.zw,p),edge(aAB.zw,aC.xy,p),edge(aC.xy,aAB.xy,p));return all(greaterThanEqual(e,vec3(0)))||all(lessThanEqual(e,vec3(0)));}
const int tri[15]=int[15](0,1,2,1,3,2,2,3,4,3,5,4,4,5,6);
const vec2 quad[6]=vec2[6](vec2(0,0),vec2(1,0),vec2(0,1),vec2(1,0),vec2(1,1),vec2(0,1));
void main(){
  vKind=int(aBase.w+0.5);vec4 profile=uProfile[vKind];
  float d=uDistanceOverride>=0.0?uDistanceOverride:distance(aBase.xyz,uCamera);
  // A following camera already sees the verge several metres ahead of it.
  // Keep actual silhouettes ahead of a camera several metres above the rider.
  int firstHead=uGrid*uGrid*7;
  bool weedGeometry=uMode==0 && gl_VertexID>=firstHead && gl_VertexID<firstHead+60 && uWeeds[vKind].x>0.0;
  float detailHeight=weedGeometry?max(profile.x,uWeeds[vKind].y):profile.x;
  float heightScale=mix(0.8,1.0,clamp((detailHeight-0.09)/0.53,0.0,1.0));
  float bladeEnd=uLodDistances.y*heightScale;
  vBladeRange=uLodDistances.xy*heightScale;
  float weedHeight=uWeeds[vKind].x>0.0?max(profile.x,uWeeds[vKind].y):profile.x;
  vWeedRange=uLodDistances.xy*mix(0.8,1.0,clamp((weedHeight-0.09)/0.53,0.0,1.0));
  float variation=uVariation[vKind];
  float community=uBake==0?clamp((aBase.w-float(vKind))*2.5,0.0,1.0):0.5;
  profile.x*=mix(1.0,mix(0.76,1.03,community),variation);
  vSlice=0;vAB=aAB;vC=aC.xy;vUV=vec2(0);vRoot=vec2(0);vColor=vec3(0);vTopBlend=0.0;
  vBlade=vec2(1,0);vForm=0;vBladeGain=vec3(1);vPopulation=1.0;vSurfaceXZ=vec2(0);vSlopeUp=1.0;
  vWeedCard=vec2(2,1);
  // The fragment transition uses its actual position; retain boundary cells.
  if(uBake==0 && ((uMode==0 && d>bladeEnd+2.0) || d>uLodDistances.w+2.0)) {gl_Position=vec4(2,2,2,1);return;}
  vec3 p,normal;vec3 albedo=uColors[vKind];
  if(uMode!=0){
    int card=gl_VertexID/6;
    // Bound horizontal card spread, slope rise and the full plant height.
    // A whole card inside the live-blade range has zero fragment coverage.
    float cardReach=1.7*(1.0+length(aSurface.xy))+max(profile.x,uWeeds[vKind].y)*1.12+0.01;
    if(uBake==0 && card<4 && d+cardReach<vBladeRange.x){gl_Position=vec4(2,2,2,1);return;}
    uint cardBits=hash(uint(aSurface.z)+uint(card)*0x9e3779b9u);
    vSlice=card==4?3:int(cardBits%3u);vec2 uv=quad[gl_VertexID%6];vUV=uv;
    vec3 groundNormal=normalize(vec3(-aSurface.x,1.0,-aSurface.y));
    float elevation=dot(normalize(uCamera-aBase.xyz+vec3(0,0.0001,0)),groundNormal);
    // The ground carpet fills gaps continuously. Cards only supply volume;
    // do not punch complementary holes in the carpet below sparse cards.
    vTopBlend=max(smoothstep(0.20,0.45,elevation),smoothstep(uTopDistances.x,uTopDistances.y,d));
    if(vSlice!=3 && vTopBlend>0.999){gl_Position=vec4(2,2,2,1);return;}
    if(vSlice==3){
      // A continuous four-metre overhead bake. Work in patch-local coordinates
      // so UVs and the road cutout remain stable far from the scene origin.
      vec2 off=uv-0.5;
      vec2 tileUV=(mod(aBase.xz-0.5,4.0)+uv)/4.0;
      vUV=vec2(tileUV.x,1.0-tileUV.y);
      // A ground decal: species height must never lift this square into a
      // terrace. Use the exact source plane, including both slope axes.
      p=aBase.xyz+vec3(off.x,dot(aSurface.xy,off),off.y);
      vRoot=off;normal=groundNormal;
    }else{
    vec2 toward=normalize(uCamera.xz-aBase.xz+vec2(0.0001));vec2 right=vec2(toward.y,-toward.x);
    // Four independently scattered tufts replace camera-aligned metre rows.
    // Their seeds and roots stay attached to the ground while the camera moves.
    vec2 jitter=vec2((cardBits>>8u)&255u,(cardBits>>16u)&255u)/255.0;
    vec2 center=(vec2(card%2,card/2)+mix(vec2(0.12),vec2(0.88),jitter))*0.5-0.5;
    float angle=(float((cardBits>>24u)&255u)/255.0-0.5)*1.2;
    right=right*cos(angle)+toward*sin(angle);
    vec2 off=center+right*((uv.x-0.5)*1.8);
    float canopyHeight=uWeeds[vKind].x>0.0?max(profile.x,uWeeds[vKind].y):profile.x;
    // The side atlas contains a representative of each rare herb. Keep the
    // ordinary low carpet on every card but only retain its upper herbs at
    // their actual density (four cards sampling three source slices).
    float weedCardChoice=float(hash(cardBits^0xa3c59ac3u)&65535u)/65535.0;
    vWeedCard=vec2(profile.x/canopyHeight,weedCardChoice<uWeeds[vKind].x*0.75?1.0:0.0);
    // Most cards contain only the short carpet. The fragment shader used to
    // reject this entire blank upper rectangle; trim it before rasterizing.
    if(vWeedCard.y<0.5){uv.y*=min(1.0,vWeedCard.x);vUV=uv;}
    p=aBase.xyz+vec3(off.x,dot(aSurface.xy,off)+uv.y*canopyHeight*1.12-0.002,off.y);
    vRoot=off;normal=vec3(toward.x,0.5,toward.y);
    }
  } else {
    // Normalize canopy shading by view angle. Different amounts of dark
    // stems are visible from above and from the road; every LOD must retain
    // the same average brightness. Gains are measured only when baking.
    if(uBake!=2 && (uBake!=1 || aSurface.w<=0.0)){
      vec3 groundNormal=normalize(vec3(-aSurface.x,1,-aSurface.y));
      float e=dot(normalize(uCamera-aBase.xyz+vec3(0,0.0001,0)),groundNormal);
      int band=e<0.25?0:(e<0.5?1:2);
      float lo=band==0?0.125:(band==1?0.25:0.5);
      float hi=band==0?0.25:(band==1?0.5:0.98);
      vBladeGain=mix(uBladeViewGain[vKind*4+band],uBladeViewGain[vKind*4+band+1],clamp((e-lo)/(hi-lo),0.0,1.0));
    }
    int headStart=uGrid*uGrid*7;bool head=gl_VertexID>=headStart;
    int row=head?(gl_VertexID-headStart)/30:(gl_VertexID/7)/uGrid;
    // Reuse two existing flower slots for whole plants. Their descriptors,
    // density and silhouettes stay identical in the live and baked paths.
    // These sparse plants survive thinning of the ordinary fine grass.
    if(head && row<2 && uWeeds[vKind].x>0.0){
      uint weedBits=hash(uint(aSurface.z)^uint(row)*0x85ebca6bu^0xb4f03e77u);
      vec4 wr=vec4(weedBits&255u,(weedBits>>8u)&255u,(weedBits>>16u)&255u,weedBits>>24u)/255.0;
      vec2 root=(wr.xy-0.5)*0.76;
      float abundance=uWeeds[vKind].x*mix(0.25,1.65,smoothstep(0.2,0.8,community));
      if(uBake==1 && uSlice>=0)abundance=1.01;
      if(wr.w>=abundance || !inside(root) || (uBake==1 && aSurface.w>1.0) ||
         (uSlice>=0 && int(floor((root.y+0.5)*3.0))!=uSlice)){
        gl_Position=vec4(2,2,2,1);return;
      }
      float h=uWeeds[vKind].y*mix(0.72,1.0,wr.z);
      int slot=(gl_VertexID-headStart)%30;int section=slot/6;
      vec2 uv=quad[slot%6];float yaw=wr.z*6.2831853;
      float phase=dot(mod(aBase.xz,256.0),vec2(0.17180585,0.12271846))+uTime*0.75;
      vec2 wind=vec2(1,0.35)*sin(phase+wr.y)*h*uWind*0.018;
      vec2 off;float y;
      if(row==1 && section<2){
        // Crossed stems with a small spiny flower head, trimmed in fragment.
        float a=yaw+float(section)*1.5707963;
        vec2 side=vec2(cos(a),sin(a));
        off=side*((uv.x-0.5)*h*0.10)+wind*uv.y*uv.y;
        y=h*uv.y;vBlade=vec2(uv.y,uv.x*2.0-1.0);vForm=6;
        normal=vec3(-side.y,0.5,side.x);albedo*=vec3(0.86,0.98,1.15);
      }else{
        bool burdock=row==0;
        float a=yaw+float(section)*2.399963;
        vec2 along=vec2(cos(a),sin(a)),side=vec2(-along.y,along.x);
        // The quadrilateral folds slightly across its diagonal. Burdock
        // carries broad drooping leaves; thistle leaves climb the stalk.
        float length=h*(burdock?0.45:0.30)*mix(0.8,1.1,fract(wr.x+float(section)*0.37));
        float halfWidth=length*(burdock?0.39:0.24);
        float t=uv.y,s=uv.x*2.0-1.0;
        off=along*(length*t)+side*(halfWidth*s)+wind*(burdock?0.3:0.65);
        y=burdock?h*(0.13+0.16*t-0.10*abs(s)):h*(0.22+float(section-2)*0.18+0.08*t-0.08*abs(s));
        vBlade=vec2(t,s);vForm=burdock?4:5;normal=vec3(-along.x,1.5,-along.y);
        albedo*=burdock?vec3(0.72,0.93,1.26):vec3(0.90,0.96,1.24);
      }
      vRoot=root+off;p=aBase.xyz+vec3(vRoot.x,dot(aSurface.xy,vRoot)+y-0.002,vRoot.y);
    }else{
    // One candidate per row, scattered across the patch. Using column zero
    // for every flower created metre-spaced stripes even in the live blades.
    int flowerColumn=int(hash(uint(aSurface.z)^uint(row)*0x85ebca6bu^0xc2b2ae35u)%uint(uGrid));
    int blade=head?row*uGrid+flowerColumn:gl_VertexID/7;
    int part=head?1+((gl_VertexID-headStart)%30)/15:0;int vertex=head?(gl_VertexID-headStart)%15:0;
    // One stable subset becomes the middle canopy. Its roots, tip and wind
    // never change; removed blades fade before the CPU skips their indices.
    float thinning=uBake==0?smoothstep(uDensityDistances.x,uDensityDistances.y,d):0.0;
    if(part==0 && (hash(uint(blade)^0x68bc21ebu)&3u)!=0u){
      vPopulation=1.0-thinning;
      if(vPopulation<=0.0){gl_Position=vec4(2,2,2,1);return;}
    }
    uint bits=hash(uint(aSurface.z)+uint(blade)*0x9e3779b9u);
    vec4 rnd=vec4(bits&255u,(bits>>8u)&255u,(bits>>16u)&255u,bits>>24u)/255.0;
    vec2 root=(vec2(blade%uGrid,blade/uGrid)+mix(vec2(0.12),vec2(0.88),rnd.xy))/float(uGrid)-0.5;
    // Related leaves grow in small plants rather than unrelated random strips.
    // A group's identity remains identical in all geometry detail levels.
    ivec2 group=ivec2(blade%uGrid,blade/uGrid)/3;
    uint groupBits=hash(uint(aSurface.z)^uint(group.x+group.y*uGrid)*0x85ebca6bu);
    float plantChoice=float(groupBits&65535u)/65535.0;
    vec4 growth=uGrowth[vKind];
    vec2 fractions=growth.xy*mix(0.72,1.28,community);
    fractions/=max(1.0,(fractions.x+fractions.y)/0.92);
    int form=plantChoice<fractions.x?1:(plantChoice<fractions.x+fractions.y?2:0);
    if(form==1 && vKind==1 && ((groupBits>>20u)&3u)!=0u)form=3;
    vec2 plantRoot=(vec2(group)*3.0+vec2(1.5))/float(uGrid)-0.5;
    plantRoot+=(vec2((groupBits>>16u)&255u,groupBits>>24u)/255.0-0.5)/float(uGrid);
    root=mix(root,plantRoot,(form==0?0.28:0.78)*variation);
    if(rnd.w>profile.z || !inside(root) || (uSlice>=0 && int(floor((root.y+0.5)*3.0))!=uSlice)){gl_Position=vec4(2,2,2,1);return;}
    // Extra canopy layers add leaves, not another full population of flowers.
    bool candidate=blade%uGrid==flowerColumn && (uBake==0 || aSurface.w<=1.0);
    bool flower=candidate && rnd.z<profile.w*float(uGrid);
    float headChoice=float(hash(bits^0xb5297a4du)&65535u)/65535.0;
    bool seedHead=candidate && !flower && headChoice<growth.z*mix(0.65,1.35,community);
    if(part>0 && !flower && !seedHead){gl_Position=vec4(2,2,2,1);return;}
    if(flower || seedHead)form=0;
    float yaw=rnd.z*6.2831853;
    if(form!=0)yaw=float((blade%uGrid)%3+((blade/uGrid)%3)*3)*2.399963+float(groupBits&255u)*0.02464;
    vec2 bend=vec2(cos(yaw),sin(yaw));vec2 side=vec2(-bend.y,bend.x);
    float h=profile.x*mix(mix(0.72,0.42,variation),1.0,rnd.y);
    if(form==1)h*=0.66;else if(form==2)h*=0.38;else if(form==3)h*=0.80;
    // Broad gusts and quiet leaf motion. World phase is bounded for long rides.
    float phase=dot(mod(aBase.xz,256.0),vec2(0.17180585,0.12271846))+uTime*0.75;
    vec2 wind=vec2(1,0.35)*(sin(phase)+0.22*sin(phase*2.0+root.y))*h*uWind*0.055;
    float spread=form==0?mix(0.16,0.55,rnd.w):(form==2?1.25:0.72);
    vec2 lean=bend*h*spread+wind;
    p=aBase.xyz+vec3(root.x,dot(aSurface.xy,root)-0.002,root.y);
    float t,s;
    if(part==0){int j=gl_VertexID%7;t=j==6?1.0:float(j/2)/3.0;s=j==6?0.0:float(j%2)*2.0-1.0;
      // The coarse leaf triangle needs a broad lower pair, not the narrow
      // petiole. Its omitted root is already covered by the ground carpet.
      if(form!=0 && uGeometryDetail==2 && j!=6)t=0.20;
      float outline=1.0-t;
      if(form!=0)outline=(0.10+1.35*sin(t*3.14159265))*(1.0-0.30*t);
      if(form!=0 && uGeometryDetail==2 && j!=6)outline=max(outline,1.20);
      float leafWidth=form==0?1.0:(form==2?2.8:(form==3?3.5:3.0));
      float width=profile.y*((flower || seedHead)?0.16:leafWidth)*mix(0.7,1.15,rnd.w)*outline*mix(1.0,2.0,thinning);
      float forward=form==0?t*t:t;
      vec2 off=side*s*width+lean*forward;
      float rise=form==0?t-0.08*t*t:(form==2?sin(t*1.7):t-0.34*t*t);
      p+=vec3(off.x,h*rise+dot(aSurface.xy,off),off.y);
      normal=vec3(bend.x,form==0?0.5+t:1.4,bend.y);vBlade=vec2(t,s);vForm=form;
      albedo*=mix(0.78,1.16,rnd.x);
      // Dry stems occur inside green tufts; herbs carry cooler, broader leaves.
      float dry=smoothstep(1.0-growth.w-0.12,1.0-growth.w+0.12,headChoice);
      if(form==0)albedo=mix(albedo,albedo*vec3(1.55,0.97,1.32),dry);
      else albedo*=form==2?vec3(0.80,1.00,1.26):vec3(0.86,0.97,1.14);
    }else{
      int hv=(gl_VertexID-headStart)%30;
      int petal=hv/6;int corner=hv%6;
      const int diamond[6]=int[6](0,1,2,0,2,3);
      int point=diamond[corner];
      if(seedHead){
        float level=h*float(petal)*0.035;
        float halfWidth=profile.x*(vKind==5?0.034:0.022);
        vec2 sideOffset=side*(point==1?-halfWidth:(point==3?halfWidth:0.0));
        float y=h*0.77+level+(point==2?h*0.075:0.0);
        p+=vec3(lean.x+sideOffset.x,y+dot(aSurface.xy,lean+sideOffset),lean.y+sideOffset.y);
        normal=vec3(bend.x,0.6,bend.y);albedo=uColors[vKind]*vec3(1.55,1.04,1.60);
      }else{
        float a=float(petal)*6.2831853/5.0+yaw;
        float r=profile.x*mix(0.060,0.090,rnd.x);
        vec2 along=vec2(cos(a),sin(a)),across=vec2(-along.y,along.x);
        vec2 petalOffset=point==0?vec2(0):(point==2?along*r:along*r*0.55+across*r*(point==1?-0.34:0.34));
        p+=vec3(lean.x+petalOffset.x,h*0.92+dot(aSurface.xy,lean+petalOffset)+(point==2?r*0.18:0.0),lean.y+petalOffset.y);
        normal=vec3(0,1,0);
        float palette=float((groupBits>>8u)&255u)/255.0;
        albedo=vKind==7?vec3(0.48,0.10,0.23):vec3(0.12,0.19,0.52);
        if(palette<0.28)albedo=vec3(0.53,0.52,0.40);
        else if(palette<0.45)albedo=vec3(0.53,0.36,0.055);
        if(point==0)albedo=vec3(0.38,0.22,0.025);
      }
    }
    vRoot=root;vUV=vec2(0);
    }
  }
  vSurfaceXZ=mod(aBase.xz,256.0)+vRoot;
  // Live descriptors interpolate the source mesh normals. The editor and
  // atlas baker retain their flat default (Reserved=0 or a bake layer).
  if(uBake==0) vSlopeUp=aSurface.w==0.0 && aC.z==0.0 && aC.w==0.0
      ? inversesqrt(1.0+dot(aSurface.xy,aSurface.xy))
      : aSurface.w+dot(aC.zw,vRoot);
  // Evaluate root shading after interpolation. Computing it at vertices made
  // the 1/3/5-triangle levels have different mean brightness.
  float sun=0.68;
  if(uBake==0 && uMode==0) sun=mix(sun,abs(dot(normalize(mat3(uModel)*normal),normalize(-uSun))),0.25*(1.0-smoothstep(1.0,3.0,d)));
  vec3 light=(vec3(0.55,0.64,0.50)+vec3(1,0.96,0.9)*(2.55*sun))*0.55;
  vec3 lit=albedo*light;vColor=pow(lit/(lit+vec3(1)),vec3(1.0/2.2));
  // Use the real surface position, before the decal's depth-only bias.
  // Relative shadow matrices retain precision far from the map origin.
  vShadowRelative=mat3(uModel)*(p-uCamera);
  vec4 eyePosition=uView*uModel*vec4(p,1);
  gl_Position=uProjection*eyePosition;
  if(uMode!=0 && vSlice==3){
    // Bias only depth by one centimetre in view space. Screen XY stays on
    // the terrain (no silhouette/parallax); a fixed NDC bias would grow
    // quadratically with distance and let grass leak through other objects.
    // Projecting the biased point also works with orthographic editor views.
    vec4 decalDepth=uProjection*(eyePosition+vec4(0,0,0.01,0));
    gl_Position.z=decalDepth.z/decalDepth.w*gl_Position.w;
  }
}
