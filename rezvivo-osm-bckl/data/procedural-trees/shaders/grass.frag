#version 330 core
uniform sampler2DArray uAtlas;
uniform int uMode,uBake;
uniform int uCheapRejects;
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
// Independent tests, shared by the baseline and reordered paths. Derivatives
// are captured in main before either call; no implicit texture derivative is
// allowed here, including when this rejects only part of a fragment quad.
void rejectGrassCoverage(float lod,float visibility,float noise){
  if(uBake==0 && uMode!=2){
    if(uMode==0){if(noise>=(1.0-lod)*visibility*vPopulation)discard;}
    // The horizontal canopy is a decal over terrain, not a silhouette.
    // Screen-door fading against sand/soil exposes a regular moving grid.
    else if(vSlice==3){if(visibility<=0.0)discard;}
    else{if(1.0-noise>lod*visibility)discard;}
  }
  if(uMode!=0 || vForm>=4){
    vec3 e=vec3(edge(vAB.xy,vAB.zw,vRoot),edge(vAB.zw,vC,vRoot),edge(vC,vAB.xy,vRoot));
    if(!(all(greaterThanEqual(e,vec3(0)))||all(lessThanEqual(e,vec3(0)))))discard;
  }
  if(uMode!=0){
    float angleNoise=fract(52.9829189*fract(dot(floor(gl_FragCoord.xy)+vec2(37,113),vec2(0.00583715,0.06711056))));
    if(vSlice!=3 && angleNoise<vTopBlend)discard;
    if(vSlice!=3 && vUV.y>vWeedCard.x && vWeedCard.y<0.5)discard;
  }
}
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
  if(uCheapRejects!=0)rejectGrassCoverage(lod,visibility,noise);
  if(uBake==0) {
    float rock=gcSlopeRockMask(vSurfaceXZ,vSlopeUp);
    // The terrain already contains the overhead grass/rock blend. A second
    // opaque carpet here would paint green over the exposed bedrock.
    if(uMode!=0 && vSlice==3 && rock>0.001)discard;
    if(noise<rock)discard;
  }
  if(uCheapRejects==0)rejectGrassCoverage(lod,visibility,noise);
  vec3 referenceLight=(vec3(0.55,0.64,0.50)+vec3(1,0.96,0.9)*(2.55*0.68))*0.55;
  vec4 c=vec4(vColor,1);
  if(uMode!=0){
    c=textureGrad(uAtlas,vec3(vUV,float(vKind*4+vSlice)),uvDx,uvDy);
    c.rgb/=max(c.a,0.00001);
    if(uMode==2)c.rgb=mix(vColor*0.70,c.rgb,c.a);
    // A tall herb enlarges the atlas frame, but must not stretch the root
    // fade over the entire short grass below it.
    if(vSlice!=3)c.a*=smoothstep(0.025,min(0.75,max(0.075,vWeedCard.x*0.75)),vUV.y);
  }else{
    if(vForm>=4){
      float t=vBlade.x,s=abs(vBlade.y);
      if(vForm==4){
        // A broad heart-shaped burdock leaf, with a narrow petiole at its root.
        float outline=pow(max(0.0,sin(3.14159265*pow(t,0.70))),0.68);
        if(s>max(0.025,outline))discard;
      }else if(vForm==5){
        float lobes=mix(0.42,1.0,abs(sin(t*18.849556)));
        if(s>max(0.035,sin(t*3.14159265)*lobes))discard;
      }else if(vForm==6){
        float head=max(0.0,1.0-abs(t-0.965)/0.033);
        if(s>max(0.055,sqrt(head)*0.72))discard;
      }else if(vForm==7){
        if(s>0.045)discard;
      }else if(vForm==8){
        float branch=clamp((t-0.72)*3.3,0.0,0.92);
        if(s>0.035 && (t<0.72 || abs(s-branch)>0.055))discard;
      }else if(vForm==9 || vForm==10 || vForm==16){
        float start=vForm==9?0.54:0.46;
        float head=clamp((t-start)/(1.0-start),0.0,1.0);
        float width=vForm==16?0.45:0.80;
        float outline=width*sin(head*3.14159265)*mix(0.5,1.0,abs(sin(t*103.0)));
        if(s>max(0.045,outline))discard;
      }else if(vForm==11){
        // Open seed panicle, with air between its slender side branches.
        float reach=max(0.015,(1.0-t)*1.8);
        float branch=fract((t-0.54)*20.0);
        if(s>0.020 && (t<0.54 || s>reach || abs(branch-s/reach)>0.085))discard;
      }else if(vForm==14){
        float r=length(vBlade),a=atan(vBlade.y,vBlade.x);
        if(r>0.85+0.14*cos(a*15.0))discard;
      }else if(vForm==15){
        float r=length(vBlade),a=atan(vBlade.y,vBlade.x);
        if(r>0.86+0.10*cos(a*7.0))discard;
        vec2 floret=fract(vBlade*4.0)-0.5;
        if(dot(floret,floret)>0.23 && r>0.3)discard;
      }else{
        float outline=sin(t*3.14159265);
        if(vForm==12)outline*=mix(0.72,1.0,abs(sin(t*34.56)));
        else if(vForm==17)outline=sqrt(max(0.0,outline));
        else if(vForm==18)outline*=mix(0.18,1.0,abs(sin(t*31.42)));
        else if(vForm==19)outline*=0.88+0.12*sin(t*37.7);
        if(s>max(0.025,outline))discard;
      }
    }
    if(vForm==3){
      // A frond silhouette with paired leaflets, retaining a central rachis.
      float leaflet=abs(fract(vBlade.x*7.0)-0.5)*2.0;
      if(abs(vBlade.y)>mix(0.20,1.0,smoothstep(0.08,0.62,leaflet)))discard;
    }
    float rootShade=mix(0.48,1.0,smoothstep(0.0,0.6,vBlade.x));
    if(vForm!=0)rootShade=mix(0.72,1.0,smoothstep(0.0,0.45,vBlade.x));
    if(vForm==14 || vForm==15)rootShade=1.0;
    c.rgb=vColor*(1.0-0.045*abs(vBlade.y))*rootShade*vBladeGain;
    if(vForm==4 || vForm==5 || vForm==12 || vForm==13 || vForm>=17){
      float vein=1.0-smoothstep(0.018,0.05,abs(vBlade.y));
      c.rgb*=1.0+0.10*vein;
    }else if(vForm==6 && vBlade.x>0.962){
      float florets=0.90+0.10*sin(vBlade.y*31.0+vBlade.x*537.0);
      c.rgb=mix(c.rgb,vec3(0.48,0.17,0.35)*florets,smoothstep(0.962,0.980,vBlade.x));
    }else if(vForm==9 && vBlade.x>0.56){
      float floret=0.85+0.15*sin(vBlade.x*103.0+vBlade.y*13.0);
      c.rgb=mix(c.rgb,vec3(0.61,0.23,0.43)*floret,smoothstep(0.56,0.65,vBlade.x));
    }else if(vForm==10 && vBlade.x>0.48){
      c.rgb=mix(c.rgb,vec3(0.35,0.24,0.13),smoothstep(0.48,0.65,vBlade.x));
    }else if(vForm==14){
      float disk=1.0-smoothstep(0.23,0.30,length(vBlade));
      c.rgb*=mix(vec3(1),vec3(0.94,0.70,0.12),disk);
    }else if(vForm==15){
      vec2 floret=fract(vBlade*4.0)-0.5;
      c.rgb*=0.89+0.11*smoothstep(0.06,0.20,dot(floret,floret));
    }else if(vForm==16 && vBlade.x>0.50){
      float flower=step(0.25,sin(vBlade.x*103.0+vBlade.y*11.0));
      c.rgb=mix(c.rgb,vec3(0.74,0.61,0.15),flower*smoothstep(0.50,0.65,vBlade.x));
    }
    if(uBake==1){
      vec3 linear=pow(c.rgb,vec3(2.2));
      fragColor=vec4(linear/(referenceLight*max(vec3(0.001),vec3(1)-linear)),1);return;
    }
  }
  // Keep the same carpet under live blades and cards. Otherwise their gaps
  // expose the independently lit terrain and make the nearby LOD brighter.
  if(uMode==1 && vSlice!=3){
    // Mip alpha is coverage. A fixed cutoff erases short blades from above
    // once several texels fall into a screen pixel; preserve their coverage.
    float alphaNoise=fract(52.9829189*fract(dot(floor(gl_FragCoord.xy)+vec2(79,23),vec2(0.06711056,0.00583715))));
    if(alphaNoise>=c.a)discard;
  }
  if(uBake==0 || uBake==3){
    c.rgb*=gcGrassSurface(vSurfaceXZ,footprint);
  }
  fragColor=vec4(c.rgb,1);
#ifdef GRASS_SHADOW
  if(uBake==0){
    gc_riderRelativePosition=vShadowRelative;
    PLUG_fragment_modify(fragColor);
  }
#endif
  // Side cards still use opaque coverage and depth. Only the ground decal
  // blends its visibility continuously; no extra draw or texture read.
  if(uBake==0 && uMode==1 && vSlice==3)fragColor.a=clamp(visibility*c.a,0.0,1.0);
}
