#version 330 core
uniform sampler2DArray uAtlas;
uniform int uMode,uBake;
uniform float uDistanceOverride;
uniform vec4 uLodDistances;
in vec3 vColor;
in vec2 vBlade;
flat in int vForm;
in vec3 vBladeGain;
flat in float vPopulation;
in vec2 vSurfaceXZ;
in float vSlopeUp;
flat in vec2 vBladeRange;
flat in vec2 vWeedRange;
in vec2 vUV;
flat in int vKind;
flat in int vSlice;
flat in vec4 vAB;
flat in vec2 vC;
flat in float vTopBlend;
flat in vec2 vWeedCard;
in vec2 vRoot;
in vec3 vShadowRelative;
/*__GRASS_SHADOW_LIBRARY__*/
/*__GRASS_SURFACE_LIBRARY__*/
out vec4 fragColor;
float edge(vec2 a,vec2 b,vec2 p){vec2 d=b-a;return d.x*(p.y-a.y)-d.y*(p.x-a.x);}
void main(){
  // Take derivatives before any stochastic discard; implicit derivatives
  // after divergent coverage tests can choose inconsistent texture mips.
  vec2 uvDx=dFdx(vUV),uvDy=dFdy(vUV);
  float footprint=max(length(dFdx(vSurfaceXZ)),length(dFdy(vSurfaceXZ)));
  float d=uDistanceOverride>=0.0?uDistanceOverride:length(vShadowRelative);
  float lod=smoothstep(vBladeRange.x,vBladeRange.y,d);
  // The low part of a card replaces the short carpet at its own distance.
  // Its sparse upper stems replace the tall weed geometry farther away.
  if(uMode!=0 && vSlice!=3 && vUV.y>vWeedCard.x)
    lod=smoothstep(vWeedRange.x,vWeedRange.y,d);
  float visibility=1.0-smoothstep(uLodDistances.z,uLodDistances.w,d);
  float noise=fract(52.9829189*fract(dot(floor(gl_FragCoord.xy),vec2(0.06711056,0.00583715))));
  if(uBake==0) {
    float rock=gcSlopeRockMask(vSurfaceXZ,vSlopeUp);
    // The terrain already contains the overhead grass/rock blend. A second
    // opaque carpet here would paint green over the exposed bedrock.
    if(uMode!=0 && vSlice==3 && rock>0.001)discard;
    if(noise<rock)discard;
  }
  if(uBake==0 && uMode!=2){
    if(uMode==0){if(noise>=(1.0-lod)*visibility*vPopulation)discard;}
    else if(vSlice==3){if(noise>=visibility)discard;}
    else{if(1.0-noise>lod*visibility)discard;}
  }
  vec3 referenceLight=(vec3(0.55,0.64,0.50)+vec3(1,0.96,0.9)*(2.55*0.68))*0.55;
  vec4 c=vec4(vColor,1);
  if(uMode!=0){
    vec3 e=vec3(edge(vAB.xy,vAB.zw,vRoot),edge(vAB.zw,vC,vRoot),edge(vC,vAB.xy,vRoot));
    if(!(all(greaterThanEqual(e,vec3(0)))||all(lessThanEqual(e,vec3(0)))))discard;
    // The carpet remains below the tufts. Only the added volume fades away.
    float angleNoise=fract(52.9829189*fract(dot(floor(gl_FragCoord.xy)+vec2(37,113),vec2(0.00583715,0.06711056))));
    if(vSlice!=3 && angleNoise<vTopBlend)discard;
    if(vSlice!=3 && vUV.y>vWeedCard.x && vWeedCard.y<0.5)discard;
    c=textureGrad(uAtlas,vec3(vUV,float(vKind*4+vSlice)),uvDx,uvDy);
    c.rgb/=max(c.a,0.00001);
    if(uMode==2)c.rgb=mix(vColor*0.70,c.rgb,c.a);
    // A tall herb enlarges the atlas frame, but must not stretch the root
    // fade over the entire short grass below it.
    if(vSlice!=3)c.a*=smoothstep(0.025,min(0.75,max(0.075,vWeedCard.x*0.75)),vUV.y);
  }else{
    if(vForm>=4){
      vec3 edges=vec3(edge(vAB.xy,vAB.zw,vRoot),edge(vAB.zw,vC,vRoot),edge(vC,vAB.xy,vRoot));
      if(!(all(greaterThanEqual(edges,vec3(0)))||all(lessThanEqual(edges,vec3(0)))))discard;
      float t=vBlade.x,s=abs(vBlade.y);
      if(vForm==4){
        // A broad heart-shaped burdock leaf, with a narrow petiole at its root.
        float outline=pow(max(0.0,sin(3.14159265*pow(t,0.70))),0.68);
        if(s>max(0.025,outline))discard;
      }else if(vForm==5){
        float lobes=mix(0.42,1.0,abs(sin(t*18.849556)));
        if(s>max(0.035,sin(t*3.14159265)*lobes))discard;
      }else{
        float head=max(0.0,1.0-abs(t-0.965)/0.033);
        if(s>max(0.055,sqrt(head)*0.72))discard;
      }
    }
    if(vForm==3){
      // A frond silhouette with paired leaflets, retaining a central rachis.
      float leaflet=abs(fract(vBlade.x*7.0)-0.5)*2.0;
      if(abs(vBlade.y)>mix(0.20,1.0,smoothstep(0.08,0.62,leaflet)))discard;
    }
    float rootShade=mix(0.48,1.0,smoothstep(0.0,0.6,vBlade.x));
    if(vForm!=0)rootShade=mix(0.72,1.0,smoothstep(0.0,0.45,vBlade.x));
    c.rgb=vColor*(1.0-0.045*abs(vBlade.y))*rootShade*vBladeGain;
    if(vForm==4 || vForm==5){
      float vein=1.0-smoothstep(0.018,0.05,abs(vBlade.y));
      c.rgb*=1.0+0.10*vein;
    }else if(vForm==6 && vBlade.x>0.962){
      float florets=0.90+0.10*sin(vBlade.y*31.0+vBlade.x*537.0);
      c.rgb=mix(c.rgb,vec3(0.48,0.17,0.35)*florets,smoothstep(0.962,0.980,vBlade.x));
    }
    if(uBake==1){
      vec3 linear=pow(c.rgb,vec3(2.2));
      fragColor=vec4(linear/(referenceLight*max(vec3(0.001),vec3(1)-linear)),1);return;
    }
  }
  // Keep the same carpet under live blades and cards. Otherwise their gaps
  // expose the independently lit terrain and make the nearby LOD brighter.
  if(uMode==1){
    // Mip alpha is coverage. A fixed cutoff erases short blades from above
    // once several texels fall into a screen pixel; preserve their coverage.
    float alphaNoise=fract(52.9829189*fract(dot(floor(gl_FragCoord.xy)+vec2(79,23),vec2(0.06711056,0.00583715))));
    if(alphaNoise>=c.a)discard;
  }
  if(uBake==0 || uBake==3)c.rgb*=gcGrassSurface(vSurfaceXZ,footprint);
  fragColor=vec4(c.rgb,1);
#ifdef GRASS_SHADOW
  if(uBake==0){
    gc_riderRelativePosition=vShadowRelative;
    PLUG_fragment_modify(fragColor);
  }
#endif
}
