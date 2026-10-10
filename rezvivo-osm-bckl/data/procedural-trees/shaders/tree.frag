#version 330 core
uniform int uKind, uSpecies, uDebug;
uniform float uOpacity, uQuality, uDensity;
uniform vec3 uBark, uLeaf, uEye;
uniform vec3 uSunDirection, uFogColor;
uniform float uFogDensity, uOutputGamma;
uniform int uDepthOnly, uDirectBranches;
uniform vec4 uProfile;
uniform int uBakeMode, uUseBakedLOD;
uniform int uLODSeasonParts;
uniform int uLODFruitLayer;
uniform float uFruitAmount;
uniform int uFruitMembers;
uniform float uSeasonLeaf;
uniform float uNeedleDetail;
uniform vec3 uLeafRatio;
uniform sampler2DArray uLODTexture;
flat in float vLODLayer;
in vec3 vWorld, vNormal;
in vec3 vObject;
in vec3 vNeedleAxis;
in vec2 vUV;
flat in vec4 vProfile;
flat in float vPhase;
flat in int vSpecies;
flat in uint vTreeCode;
flat in float vMaturity;
flat in float vIrregularity;
flat in float vSeasonVisible;
flat in float vNeedleCoverage;
flat in vec4 vShoot;
flat in vec4 vFruit;
in vec2 vShadowMask;
out vec4 fragColor;
float hash(vec2 p) { return fract(sin(dot(p,vec2(127.1,311.7)))*43758.5453); }
float noise(vec2 p) {
    vec2 i=floor(p), f=fract(p); f=f*f*(3.0-2.0*f);
    return mix(mix(hash(i),hash(i+vec2(1,0)),f.x),mix(hash(i+vec2(0,1)),hash(i+1.0),f.x),f.y);
}
bool mapleBlade(vec2 p) {
    // Half of a palmate blade. Straight edges meet at acute lobe tips;
    // sinus cuts separate the five lobes instead of a rounded star mask.
    const vec2 edge[11]=vec2[11](vec2(0,1),vec2(.24,.61),vec2(.28,.36),
        vec2(.76,.56),vec2(.63,.13),vec2(.97,-.04),vec2(.43,-.20),
        vec2(.56,-.53),vec2(.22,-.43),vec2(.055,-.64),vec2(0,-.90));
    p.x=abs(p.x)*(1.0+.018*sin(p.y*79.0));
    bool inside=false;
    for(int i=0,j=10;i<11;j=i++) {
        if((edge[i].y>p.y)!=(edge[j].y>p.y)) {
            float crossing=(edge[j].x-edge[i].x)*(p.y-edge[i].y)/(edge[j].y-edge[i].y)+edge[i].x;
            if(p.x<crossing) inside=!inside;
        }
    }
    return inside;
}
void main() {
    if((uKind==1 || uKind==5 || uKind==6) && vSeasonVisible<=0.0) discard;
    if((uKind==5 || uKind==6) && uNeedleDetail>0.0 && uNeedleDetail<1.0) {
        // Complementary masks: a pixel sees either the real needles or their
        // integrated shoot. Tree-local shadow coordinates do not crawl as the
        // receiver moves; both representations share the original shoot phase.
        float choice=hash((uDepthOnly==1 ? floor(vShadowMask*64.0) : floor(gl_FragCoord.xy))+
            vec2(23,71)+vShoot.w*vec2(197,317));
        if(uKind==5 ? choice>=uNeedleDetail : choice<uNeedleDetail) discard;
    }
    if(uKind==6) {
        float x=abs(vUV.x*2.0-1.0);
        float cap=clamp(min(vUV.y,1.0-vUV.y)*vShoot.x,0.0,1.0);
        float edge=sqrt(cap*(2.0-cap));
        if(uDepthOnly==1) {
            // Integrate the needle fringe into a smooth shoot silhouette.
            // One stable threshold per shoot preserves mean foliage coverage
            // without tiny UV noise cells flashing as the shadow raster moves.
            float density=vShoot.y*vSeasonVisible*vNeedleCoverage;
            if(x>edge*.92 || vPhase>=density) discard;
        } else {
        // Fine serrations describe the needle fringe. Integrate them once they
        // become subpixel rather than drawing oversized individual needles.
        float rows=vUV.y*vShoot.z-x*2.3+vPhase*71.0;
        float resolved=1.0-smoothstep(.3,1.0,fwidth(rows));
        float tooth=mix(.5,abs(fract(rows)-.5)*2.0,resolved);
        edge*=.84+.16*tooth;
        float aa=max(.001,fwidth(x));
        float coverage=(1.0-smoothstep(edge-aa,edge+aa,x))*vShoot.y*vSeasonVisible*vNeedleCoverage;
        vec2 coverageCell=floor(gl_FragCoord.xy);
        if(hash(coverageCell+vec2(79,151)+vPhase*vec2(971,613))>=coverage) discard;
        }
    }
    if(uKind==5 && vNeedleCoverage<.9999) {
        // Raster guards enlarge sub-texel needles; compensate their area with
        // a stable per-needle choice in depth maps. Screen-space random holes
        // were reseeded whenever the shadow atlas snapped by one texel.
        float coverageNoise=uDepthOnly==1 ? vPhase :
            hash(floor(gl_FragCoord.xy)+vec2(197,83)+vPhase*vec2(971,613));
        if(coverageNoise>=vNeedleCoverage) discard;
    }
    if(uKind==2 && uSeasonLeaf<1.0 && hash(floor(vUV*vec2(137,91))+vPhase*317.0)>=uSeasonLeaf) discard;
    // Complementary screen-door thresholds keep depth writes and avoid sorting.
    if(uQuality>.35 && uQuality<.95 && uKind!=4) {
        float screen=hash(uDepthOnly==1 ? floor(vShadowMask*16.0) : floor(gl_FragCoord.xy));
        float farMix=smoothstep(.35,.95,uQuality);
        if(uKind==3) { if(screen<farMix) discard; }
        else { if(screen>=farMix) discard; }
    }
    if(uDirectBranches==0 && uQuality>3.4 && uQuality<4.0 && (uKind==1 || uKind==2 || uKind==5)) {
        float detail=smoothstep(3.4,4.0,uQuality);
        float detailNoise=hash((uDepthOnly==1 ? floor(vShadowMask*16.0) : floor(gl_FragCoord.xy))+vec2(73,29));
        if((uKind==1 || uKind==5) && detailNoise>=detail) discard;
        if(uKind==2 && detailNoise<detail) discard;
    }
    // Solid wood and needle triangles need only the coverage masks above in
    // a shadow pass. Do not evaluate bark noise, normals or material colours.
    if(uDepthOnly==1 && (uKind==0 || uKind==5 || uKind==6 || uKind==7 || uKind==8)) { fragColor=vec4(1); return; }
    if(uKind==3 && uUseBakedLOD==1) {
        // Stored and mip-filtered in premultiplied linear space. Coverage uses
        // depth-writing screen door, so 10,000 trees need no alpha sorting.
        vec4 texel=texture(uLODTexture,vec3(vUV,vLODLayer));
        // The mean alpha is the frequency of foliage at this location across
        // different specimens. Reconstruct a crown from that density field:
        // suppress rare outliers and retain opaque interiors. The saved atlas
        // remains the exact arithmetic mean, without this display remapping.
        float coverage=smoothstep(.04,.44,texel.a);
        vec4 foliage=vec4(0);
        vec4 fruit=vec4(0);
        float fruitCoverage=0.0;
        float woodCoverage=0.0, leafCoverage=0.0;
        if(uLODSeasonParts==1) {
            // First 12 layers: real bare wood; next 12: real foliage only.
            // Recolour foliage before compositing. Bark never receives leaf tint.
            if(uSeasonLeaf>0.0001) foliage=texture(uLODTexture,vec3(vUV,vLODLayer+12.0));
            woodCoverage=smoothstep(.008,.22,texel.a);
            leafCoverage=smoothstep(.04,.44,foliage.a)*uSeasonLeaf;
            coverage=leafCoverage+woodCoverage*(1.0-leafCoverage);
            if(uLODFruitLayer==1 && uFruitAmount>0.0) {
                fruit=texture(uLODTexture,vec3(vUV,vLODLayer+24.0));
                fruitCoverage=clamp(fruit.a*uFruitAmount,0.0,1.0);
                coverage=fruitCoverage+coverage*(1.0-fruitCoverage);
            }
        } else {
            // Legacy atlas support; newly baked banks use the wood/foliage path.
            coverage*=uSeasonLeaf;
        }
        // Independent instance masks are essential: shared screen thresholds
        // leave the same holes through every tree in a dense forest.
        vec2 coverageCell=uDepthOnly==1 ? floor(vUV*512.0) : floor(gl_FragCoord.xy);
        if(coverage<=max(.003,hash(coverageCell+vec2(197,83)+vPhase*vec2(971,613)))) discard;
        if(uDepthOnly==1) { fragColor=vec4(1); return; }
        vec3 baked=texel.rgb/max(texel.a,.0001);
        if(uLODSeasonParts==1) {
            vec3 leafRGB=foliage.rgb/max(foliage.a,.0001)*uLeafRatio;
            baked=((leafRGB*leafCoverage+baked*woodCoverage*(1.0-leafCoverage))*(1.0-fruitCoverage)+
                fruit.rgb/max(fruit.a,.0001)*fruitCoverage)/max(coverage,.0001);
        } else baked*=uLeafRatio;
        float variant=float((vTreeCode>>20u)&255u)/255.0;
        baked*=mix(vec3(1),vec3(.90+variant*.19,1.0,.90+variant*.16),step(.001,variant));
        if(uDebug==1) baked=vec3(.25,.55,1);
        if(uFogDensity!=0.0) {
            float fog=1.0-exp(-length(vWorld-uEye)*uFogDensity);
            baked=mix(baked,uFogColor,fog);
        }
        fragColor=vec4(pow(max(baked,vec3(0)),vec3(uOutputGamma)),1); return;
    }
    float variant=float((vTreeCode >> 20u) & 255u)/255.0;
    vec3 color=uLeaf*mix(vec3(1),vec3(.90+variant*.19,1.0,.90+variant*.16),step(.001,variant));
    vec3 n=normalize(vNormal);
    float ao=1.0;
    if(uKind==0) {
        float ridges=noise(vec2(vUV.x*52.0,vUV.y*3.0));
        color=uBark*(.67+.45*ridges);
        if(vSpecies==0) {
            float furrow=pow(noise(vec2(vUV.x*37.0+noise(vec2(vUV.y*.8,9.0))*2.0,vUV.y*.8)),2.0);
            color*=mix(.88, .49+furrow*1.20, clamp(vMaturity,0.0,1.0));
        }
        if(vSpecies==8) color=uBark*(.78+.27*noise(vec2(vUV.x*90.0,vUV.y*1.8)));
        if(vSpecies==1) {
            float mark=step(.68,noise(vec2(vUV.x*11.0,floor(vUV.y*18.0))));
            color=mix(color,vec3(.12,.14,.13),mark*.88);
        }
        if(vSpecies==14) {
            float node=1.0-smoothstep(.025,.07,abs(fract(vUV.y*2.7)-.5));
            color=uBark*(.88+.12*noise(vec2(vUV.x*24.0,vUV.y*.5)));
            color=mix(color,color*1.35,node);
        }
        if(vSpecies==15 || vSpecies==16) {
            float ring=abs(fract(vUV.y*5.0+sin(vUV.x*25.13)*.10)-.5);
            color=uBark*(.67+.38*smoothstep(.015,.10,ring));
        }
        if(vSpecies==17) {
            float rib=.5+.5*cos(vUV.x*12.0*3.14159265);
            color=uBark*(.72+.35*rib);
            vec2 dots=fract(vec2(vUV.x*12.0,vUV.y*9.0))-.5;
            float spot=1.0-smoothstep(.06,.13,length(dots));
            color=mix(color,vec3(.25,.27,.16),spot*.7);
        }
        if(vSpecies==19) color=uBark*(.78+.32*noise(vec2(vUV.x*5.0,vUV.y*.7)));
    } else if(uKind==8) {
        vec2 cell=fract(vUV*vec2(14,9))-.5;
        float areole=1.0-smoothstep(.035,.085,length(cell));
        color*=.85+vPhase*.23;color=mix(color,vec3(.27,.25,.12),areole*.65);
    } else if(uKind==1) {
        vec2 p=vUV*2.0-1.0;
        float edge=1.0-p.y*p.y;
        float vein=1.0-smoothstep(.015,.055,abs(p.x));
        if(vSpecies==0) {
            // Rounded paired lobes on an elongated oak blade.
            edge=pow(max(0.0,edge),.60)*(.70+.25*cos(p.y*15.7+.30));
            if(abs(p.x)>edge || p.y<-.90) discard;
            float lateral=abs(fract((p.y-abs(p.x)*.32)*2.5+.5)-.5);
            vein=max(vein,(1.0-smoothstep(.015,.05,lateral))*.5);
        } else if(vSpecies==8) {
            // Five palmate pointed lobes, with deep sinuses and radial veins.
            if(!mapleBlade(p)) discard;
            vec2 q=vec2(abs(p.x),p.y+.55);
            float ray=min(q.x,min(abs(q.x*.68-q.y*.73),abs(q.x*.96-q.y*.28)));
            vein=1.0-smoothstep(.012,.035,ray);
        } else if(vSpecies==14 || vSpecies==15 || vSpecies==16 || vSpecies==19) {
            if(abs(p.x)>pow(max(0.0,edge),.65)) discard;
        } else if(vSpecies==13 || vSpecies==20) {
            // Six paired leaflets and a terminal leaflet on one fine rachis.
            float row=floor((p.y+.88)/.27);
            float centerY=-.75+row*.27;
            vec2 q=vec2((abs(p.x)-.49)/.46,(p.y-centerY-abs(p.x)*.12)/.10);
            float width=max(0.0,1.0-q.x*q.x);
            // Pointed leaflets with fine teeth, rather than a row of ovals.
            float teeth=1.0-.10*abs(sin(q.x*47.0));
            bool leaflet=row>=0.0 && row<6.0 && abs(q.x)<1.0 && abs(q.y)<width*teeth;
            vec2 tip=vec2(p.x/.16,(p.y-.82)/.18);
            bool terminal=abs(tip.y)<1.0 && abs(tip.x)<max(0.0,1.0-tip.y*tip.y);
            bool rachis=abs(p.x)<.025 && p.y>-.96 && p.y<.93;
            if(!leaflet && !terminal && !rachis) discard;
            vein=max(vein,(1.0-smoothstep(.018,.06,abs(q.y)))*.45);
        } else if(abs(p.x)>edge*(.84+.08*cos(p.y*22.0))) discard;
        if(uDepthOnly==1) { fragColor=vec4(1); return; }
        color*=.74+vPhase*.49;
        color=mix(color,color*1.22,vein*.5);
        if(!gl_FrontFacing) {
            // White willow has a pale, silky underside; oak is cooler below.
            if(vSpecies==3) {
                float gray=dot(color,vec3(.2126,.7152,.0722));
                color=mix(color,vec3(gray)*1.65,.58);
            } else if(vSpecies==0) color*=vec3(.92,1.04,1.25);
        }
        n=gl_FrontFacing?n:-n;
        ao=.87;
    } else if(uKind==2) {
        if(uDensity<.001) discard;
        vec2 pattern=vec2(vObject.x*8.0+vObject.z*3.7,vObject.y*11.0-vObject.z*6.3);
        float fleck=noise(pattern);
        if(fleck<.19) discard;
        if(uDepthOnly==1) { fragColor=vec4(1); return; }
        color*=.50+.65*fleck+vPhase*.14;
        n=normalize(n+vec3(noise(pattern+7.0)-.5,fleck-.5,noise(pattern+31.0)-.5)*.9);
        ao=.87;
    } else if(uKind==3) {
        vec2 p=vec2((vUV.x-.5)*2.0,vUV.y);
        float crown=0.0;
        float start=vProfile.w/1.32;
        float mid=(start+.80)*.5;
        vec2 cp=vec2(p.x/.86,(p.y-mid)/max(.14,(.89-start)*.55));
        float angle=atan(cp.y,cp.x);
        float edge=1.0+.095*sin(angle*7.0+vPhase*31.0)+.055*sin(angle*13.0);
        crown=edge-length(cp);
        if(vSpecies==0) {
            cp=vec2((p.x-.09*sin(vPhase*17.0))/.93,(p.y-(start+.69)*.5)/max(.18,(.81-start)*.55));
            angle=atan(cp.y,cp.x);
            crown=1.0+.13*sin(angle*5.0+vPhase*31.0)+.045*sin(angle*11.0)-length(cp);
        }
        if(vSpecies==8) {
            cp=vec2(p.x/.75,(p.y-mid)/max(.18,(.94-start)*.55));
            crown=1.0+.055*sin(atan(cp.y,cp.x)*9.0+vPhase*31.0)-length(cp);
        }
        if(vSpecies==2 || vSpecies==5 || vSpecies==12) {
            float width=max(0.0,(.92-p.y)*1.22);
            width*=vSpecies==2 ? .83+.17*cos(p.y*65.0+vPhase*3.0) : .94+.06*cos(p.y*65.0+vPhase*3.0);
            float axis=0.0;
            if(vSpecies==5 || vSpecies==12) {
                float side=sign(p.x);
                float layers=noise(vec2(p.y*27.0+vPhase*15.0,side*7.0+vPhase*19.0));
                width*=1.0+(layers-.5)*.65*vIrregularity;
                width*=1.0+side*.20*vIrregularity*sin(vPhase*23.0);
                axis=.065*vIrregularity*p.y*p.y*sin(vPhase*31.0);
            }
            crown=min(min(p.y-start,.93-p.y),width-abs(p.x-axis));
        }
        if(vSpecies==4 || vSpecies==6 || vSpecies==7) {
            // Low rounded canopies, with separate lobes and foliage near soil.
            float center=vSpecies==4 ? .47 : vSpecies==6 ? .39 : .26;
            float rise=vSpecies==4 ? .44 : vSpecies==6 ? .37 : .245;
            cp=vec2(p.x/.92,(p.y-center)/rise);
            angle=atan(cp.y,cp.x);
            crown=1.0+.085*sin(angle*7.0+vPhase*31.0)+.035*sin(angle*15.0)-length(cp);
        }
        if(vSpecies==3) crown+=.045*sin(p.x*24.0+vPhase*6.28);
        float barkWidth=2.0*vProfile.y/(vProfile.x*vProfile.z*1.18)*(1.0-p.y*.8);
        bool trunk=abs(p.x-.012*sin(p.y*7.0+vPhase*9.0))<barkWidth && p.y<.79;
        if(vSpecies==4) trunk=abs(p.x-.27*sin(p.y*3.7)*sin(vPhase*6.28))<barkWidth && p.y<.79;
        if(vSpecies==6 || vSpecies==7) {
            float stems=min(abs(p.x-p.y*.85),min(abs(p.x+p.y*.7),abs(p.x-p.y*.12)));
            trunk=stems<barkWidth*.42 && p.y<.33;
        }
        bool foliage=crown>0.0 && uDensity>.001 && hash(floor(vUV*vec2(139,107))+vPhase*173.0)<uSeasonLeaf;
        // Analytic fallback keeps a simple woody skeleton when leaves drop.
        float branch=1.0;
        for(int i=0;i<6;i++) {
            float y=.20+float(i)*.087;
            float side=mod(float(i),2.0)*2.0-1.0;
            vec2 from=vec2(0,y), to=vec2(side*(.22+.20*noise(vec2(vPhase,float(i)))),y+.18);
            vec2 segment=to-from;
            float t=clamp(dot(p-from,segment)/dot(segment,segment),0.0,1.0);
            branch=min(branch,length(p-from-segment*t));
        }
        bool wood=trunk || branch<max(.002,barkWidth*.27);
        if(!foliage && !wood) discard;
        if(foliage) {
            float fleck=noise(vUV*vec2(45,60)+vPhase*27.0);
            color*=.62+.48*fleck;
            n=normalize(vec3(cp.x*.65,.5,max(.2,1.0-dot(cp,cp))));
        } else color=uBark;
    } else if(uKind==7) {
        color=vFruit.rgb;
        if(vFruit.w==12.0) {
            // Overlapping, staggered cone scales; suppress subpixel pattern.
            vec2 scaleUV=vec2(vUV.x*9.0,vUV.y*11.0);
            scaleUV.x+=mod(floor(scaleUV.y),2.0)*.5;
            vec2 q=fract(scaleUV)-.5;
            float rim=abs(q.x)+abs(q.y)*.65;
            float detail=1.0-smoothstep(.25,1.0,max(fwidth(scaleUV.x),fwidth(scaleUV.y)));
            color*=mix(.87,.63+.48*(1.0-smoothstep(.15,.60,rim)),detail);
        } else if(vFruit.w>=0.0) {
            if(uFruitMembers==1 && (vFruit.w==6.0 || vFruit.w==7.0 || vFruit.w==13.0 || vFruit.w==14.0)) {
                vec2 berryUV=vUV*vec2(7,5);
                berryUV.x+=mod(floor(berryUV.y),2.0)*.5;
                float resolved=1.0-smoothstep(.3,1.5,max(fwidth(berryUV.x),fwidth(berryUV.y)));
                vec2 q=fract(berryUV)-.5;
                color*=mix(.88,.55+.45*sqrt(max(0.0,1.0-dot(q,q)*4.0)),resolved);
            }
            float blush=.88+.12*cos(vUV.x*6.28+vPhase*17.0);
            color*=blush;
            // Small dried calyx at the pole, rather than featureless marbles.
            float calyx=smoothstep(.945,.982,vUV.y);
            color=mix(color,vec3(.08,.037,.012),calyx*.8);
        }
    } else if(uKind==6) {
        float across=vUV.x*2.0-1.0;
        vec3 side=normalize(cross(vNeedleAxis,n));
        n=normalize(n*sqrt(max(.08,1.0-across*across))+side*across*.7);
        color*=(.69+.30*vPhase)*(.88+.12*abs(across));
        ao=.86;
    } else if(uKind==5) {
        float across=vUV.x*2.0-1.0;
        vec3 side=normalize(cross(vNeedleAxis,n));
        n=normalize(n*sqrt(max(.03,1.0-across*across))+side*across*.65);
        color*=(.66+.36*vPhase)*mix(.72,1.30,vUV.y);
        color=mix(vec3(.19,.13,.055),color,smoothstep(0.0,.08,vUV.y));
        ao=.86;
    } else {
        float radius=length(vWorld.xz);
        float grid=max(1.0-smoothstep(.0,fwidth(vWorld.x)*1.5,abs(fract(vWorld.x+.5)-.5)),
                       1.0-smoothstep(.0,fwidth(vWorld.z)*1.5,abs(fract(vWorld.z+.5)-.5)));
        float fade=1.0-smoothstep(8.0,65.0,radius);
        color=mix(vec3(.105,.14,.125),vec3(.19,.23,.205),grid*fade*.40);
        float shadow=exp(-dot(vWorld.xz/vec2(4.0,3.0),vWorld.xz/vec2(4.0,3.0)));
        color*=1.0-.38*shadow;
        fragColor=vec4(pow(color,vec3(1.0/2.2)),1); return;
    }
    if(uDepthOnly==1) { fragColor=vec4(1); return; }
    vec3 sun=normalize(uSunDirection);
    float light=.38+.58*max(0.0,dot(n,sun));
    if(uKind==1 || uKind==5 || uKind==6) light+=.22*max(0.0,dot(-n,sun));
    color*=light*ao;
    if(uKind==7 && vFruit.w>=0.0 && vFruit.w!=12.0 && uBakeMode==0) {
        vec3 halfDirection=normalize(sun+normalize(uEye-vWorld));
        color+=vec3(.7,.65,.5)*pow(max(0.0,dot(n,halfDirection)),30.0)*.16;
    }
    if(uKind==5 && uBakeMode==0) {
        vec3 halfDirection=normalize(sun+normalize(uEye-vWorld));
        color+=vec3(.30,.34,.19)*pow(max(0.0,dot(n,halfDirection)),36.0)*.22;
    }
    // Baking retains diffuse lighting, but excludes fog, wind and highlights.
    // The transparent FBO contains linear premultiplied RGB/coverage.
    if(uBakeMode==1) { fragColor=vec4(color,1); return; }
    if(uDebug==1) {
        color=uKind==3?vec3(.25,.55,1):uKind==2?vec3(.9,.55,.12):(uKind==1 || uKind==5 || uKind==6)?vec3(.3,.95,.6):vec3(.8,.5,.9);
    }
    if(uFogDensity!=0.0) {
        float fog=1.0-exp(-length(vWorld-uEye)*uFogDensity);
        color=mix(color,uFogColor,fog);
    }
    fragColor=vec4(pow(max(color,vec3(0)),vec3(uOutputGamma)),1.0);
}
