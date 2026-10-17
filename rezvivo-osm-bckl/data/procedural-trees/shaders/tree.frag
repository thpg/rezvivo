#version 330 core
#if !defined(GL_ES) && defined(GL_ARB_sample_shading)
#extension GL_ARB_sample_shading : enable
#define TREE_SAMPLE_MASK 1
#elif defined(GL_ES) && defined(GL_OES_sample_variables)
#define TREE_SAMPLE_MASK 1 // enabled before precision declarations by TreeShaderSource
#endif
uniform int uKind, uSpecies, uDebug;
uniform float uOpacity, uQuality, uDensity;
uniform int uCoverageSamples;
uniform int uFragmentWorkReuse;
uniform vec3 uBark, uLeaf, uEye;
uniform vec3 uBarkTint;
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
uniform sampler2DArray uLODTexture, uLODNormal, uLeafSprays;
uniform int uLODRelight;
flat in float vLODLayer;
flat in vec2 vLODViewBlend;
flat in float vLODRotation;
in vec3 vWorld, vNormal;
in vec3 vTransitionCoord;
flat in float vTransitionFootprint;
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
flat in vec2 vSprayCrop;
flat in vec4 vFruit;
in vec2 vShadowMask;
out vec4 fragColor;
vec2 foliageDx,foliageDy;
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
// The length of the mean normal records orientation dispersion. Retain it:
// normalizing the average would invent a flat, shiny leaf at large distances.
vec4 lodTexel(sampler2DArray atlas,float layer) {
    float other=vLODViewBlend.x+layer-vLODLayer;
    if(uDepthOnly==1 || vLODViewBlend.y<=0.0)return textureGrad(atlas,vec3(vUV,layer),foliageDx,foliageDy);
    if(vLODViewBlend.y>=1.0)return textureGrad(atlas,vec3(vUV,other),foliageDx,foliageDy);
    return mix(textureGrad(atlas,vec3(vUV,layer),foliageDx,foliageDy),textureGrad(atlas,vec3(vUV,other),foliageDx,foliageDy),vLODViewBlend.y);
}
vec4 rotatedMoment(float layer,float rotation) {
    vec4 texel=textureGrad(uLODNormal,vec3(vUV,layer),foliageDx,foliageDy);
    vec3 moment=2.0*texel.rgb-vec3(texel.a);
    float c=cos(rotation),s=sin(rotation);
    moment.xz=mat2(c,-s,s,c)*moment.xz;
    return vec4(moment,texel.a);
}
// Thin-leaf transmission is strongest with the sun behind the leaf. Share the
// same angular response with the prefiltered normal moments of the far atlas.
// Replaces the old half-vector/pow highlight; no extra texture or render pass.
vec3 foliageLighting(vec3 albedo,vec3 normal,float spread) {
    vec3 sun=normalize(uSunDirection),eye=normalize(uEye-vWorld);
    float projected=dot(normal,sun);
    float front=max(0.0,projected)+.25*spread;
    float back=max(0.0,-projected)+.25*spread;
    float forward=clamp(-dot(eye,sun),0.0,1.0);
    forward*=forward;forward*=forward;
    bool conifer=vSpecies==2 || vSpecies==4 || vSpecies==5 || vSpecies==7 || vSpecies==12;
    float transmission=conifer?.20:.95;
    vec3 lit=albedo*(.33+.06*clamp(normal.y*.5+.5,0.0,1.0)+.61*front+.16*back);
    lit+=albedo*vec3(.82,1.13,.46)*(transmission*back*forward);
    float glint=max(0.0,dot(reflect(-sun,normal),eye));
    glint*=glint;glint*=glint;glint*=glint;glint*=glint;
    return lit+vec3(.038,.044,.025)*glint*(1.0-spread);
}
vec3 relightLOD(vec3 albedo,float layer,bool leaf){
    float other=vLODViewBlend.x+layer-vLODLayer;
    vec4 sampleN;
    if(vLODViewBlend.y<=0.0)sampleN=rotatedMoment(layer,vLODRotation);
    else if(vLODViewBlend.y>=1.0)sampleN=rotatedMoment(other,vLODRotation-1.570796327);
    else sampleN=mix(rotatedMoment(layer,vLODRotation),
        rotatedMoment(other,vLODRotation-1.570796327),vLODViewBlend.y);
    vec3 moment=sampleN.rgb/max(sampleN.a,.0001);
    moment/=max(1.0,length(moment));
    float spread=max(0.0,1.0-min(1.0,length(moment)));
    if(leaf)return foliageLighting(albedo,moment,spread);
    float projected=dot(moment,normalize(uSunDirection));
    float front=max(0.0,projected)+.25*spread;
    float back=max(0.0,-projected)+.25*spread;
    return albedo*(.38+.58*front+(leaf?.22*back:0.0));
}
// Object-space hashed alpha testing (Wyman/McGuire, I3D 2017).
// Interpolate adjacent power-of-two grids and correct the distribution: a
// changing footprint must not reseed the whole crown or change mean opacity.
float coverageHash(vec3 cell,uint seed) {
    uvec3 q=uvec3(ivec3(cell));
    uint h=q.x*1664525u+q.y*1013904223u+q.z*374761393u+seed*668265263u;
    h^=h>>16u;h*=2246822519u;h^=h>>13u;h*=3266489917u;h^=h>>16u;
    return (float(h>>8u)+.5)*(1.0/16777216.0);
}
float surfaceThreshold(vec3 position,float footprint,uint seed) {
    float level=log2(1.0/max(1e-6,1.5*footprint));
    float grid=exp2(floor(level)),blend=fract(level);
    float lo=coverageHash(floor(position*grid),seed);
    float hi=coverageHash(floor(position*(grid*2.0)),seed);
    float value=mix(lo,hi,blend),a=min(blend,1.0-blend);
    float shoulder=2.0*a*(1.0-a);
    if(a<1e-5)return clamp(value,1e-6,1.0);
    if(value<a)value=value*value/shoulder;
    else if(value>1.0-a)value=1.0-(1.0-value)*(1.0-value)/shoulder;
    else value=(value-.5*a)/(1.0-a);
    return clamp(value,1e-6,1.0);
}
// Many independent twig phases already provide stratification under MSAA.
// Keep the spatial two-scale hash for large far cards and single-sample targets.
float leafThreshold(vec3 position,float footprint,uint seed) {
#ifdef TREE_SAMPLE_MASK
    if(uCoverageSamples>1 && uKind!=3)return clamp(vPhase,.000001,.999999);
#endif
    return surfaceThreshold(position,footprint,seed);
}
// Stratified coverage uses the existing MSAA samples, without another pass
// or supersampling. An odd permutation per surface avoids correlated holes
// through overlapping leaves. Single-sample / ES 3.0 targets keep the same
// object-space hashed alpha path.
void foliageCoverage(float coverage,float threshold,uint seed,bool invertMask) {
#ifdef TREE_SAMPLE_MASK
    if(uCoverageSamples>1) {
        uint count=uint(clamp(ceil(clamp(coverage,0.0,1.0)*float(uCoverageSamples)-threshold),0.0,float(uCoverageSamples)));
        if(count==0u){if(invertMask)return;else discard;}
        if(count==uint(uCoverageSamples)){if(invertMask)discard;else return;}
        uint wrap=uint(uCoverageSamples-1);
        seed^=seed>>16u;seed*=2246822519u;seed^=seed>>13u;
        uint first=seed&wrap,stepSize=((seed>>8u)|1u)&wrap;
        uint mask=0u;
        for(uint i=0u;i<count;i++)mask|=1u<<((first+i*stepSize)&wrap);
        if(invertMask)mask=~mask;
        gl_SampleMask[0]&=int(mask);
        uint activeSamples=0xffffffffu>>(32u-uint(uCoverageSamples));
        if((uint(gl_SampleMask[0])&activeSamples)==0u)discard;
        return;
    }
#endif
    if(invertMask ? threshold<coverage : threshold>=coverage)discard;
}
void main() {
#ifdef TREE_SAMPLE_MASK
    for(int word=0;word<gl_SampleMask.length();word++)gl_SampleMask[word]=-1;
#endif
#ifdef LEAF_SPRAY_BAKE
    if(uKind==10) {
        // Bake overlapping, irregular sprigs ONCE. Live grouped foliage reads
        // one texture instead of cutting each sprig at a repeated cell border.
        // Periodic placement closes the large patch without a rectangular seam.
        vec2 patchPosition=vUV*4.0, base=floor(patchPosition);
        float rows=vShoot.x, aspect=vShoot.y, blade=1.08/rows;
        vec2 extent=vec2(1),crop=vec2(1);
        if(rows>1.0) {
            extent=vec2(
                min(1.7,(.025+blade*(.82+max(1.0,aspect)))/aspect+.025),
                min(1.7,1.0-.325/rows+blade*(.584+sqrt(.506+aspect*aspect))+.025));
            crop=extent/1.7;
        }
        float physicalAspect=aspect*extent.x/extent.y;
        vec4 bakedSpray=vec4(0);
        for(int y=-1;y<=1;y++)for(int x=-1;x<=1;x++) {
            vec2 cell=base+vec2(x,y), key=mod(cell,4.0)+float(vSpecies)*vec2(13,37);
            float r=hash(key+vec2(7,3)), r2=hash(key+vec2(41,17));
            vec2 center=cell+.5+(vec2(r,r2)-.5)*.70;
            float angle=(hash(key+vec2(29,53))-.5)*1.8;
            float cs=cos(angle),sn=sin(angle),scale=.94+.16*hash(key+vec2(61,19));
            vec2 q=(patchPosition-center)*vec2(physicalAspect,1);
            q=vec2(cs*q.x+sn*q.y,-sn*q.x+cs*q.y)/vec2(physicalAspect,1)/scale;
            if(any(greaterThan(abs(q),vec2(.5))))continue;
            vec4 sampleSpray=textureLod(uLeafSprays,
                vec3(.5+q*crop,vShoot.z+floor(r2*8.0)),0.0);
            vec2 tilt=sampleSpray.gb/max(sampleSpray.a,.0001)*2.0-1.0;
            tilt=vec2(cs*tilt.x-sn*tilt.y,sn*tilt.x+cs*tilt.y);
            sampleSpray.gb=(tilt*.5+.5)*sampleSpray.a;
            bakedSpray=sampleSpray+bakedSpray*(1.0-sampleSpray.a);
        }
        fragColor=bakedSpray;return;
    }
#endif
    // All texture gradients precede any per-fragment discard. Otherwise LOD
    // crossfades can remove quad neighbours before implicit mip selection.
    foliageDx=dFdx(vUV);foliageDy=dFdy(vUV);
    // A draw-uniform branch keeps derivatives valid across the whole quad.
    // MSAA twig coverage uses its fixed phase, never this spatial footprint;
    // opaque wood/fruit do not call leafThreshold at all.
    bool needsFootprint=uKind==1 || uKind==3 || uKind==5 || uKind==6;
#ifdef TREE_SAMPLE_MASK
    needsFootprint=needsFootprint && (uCoverageSamples<=1 || uKind==3);
#endif
    float footprint=0.0;
    if(uFragmentWorkReuse==0 || needsFootprint)
        footprint=max(length(dFdx(vObject)),length(dFdy(vObject)));
    vec3 transitionPosition=vec3(vTransitionCoord.xy/vTransitionCoord.z,0);
    float transitionFootprint=vTransitionFootprint;
    float transitionThreshold=0.0;
    if(uDepthOnly==0 && ((uQuality>.35 && uQuality<.95) ||
       ((uKind==5 || uKind==6) && uNeedleDetail>0.0 && uNeedleDetail<1.0) ||
       (uDirectBranches==0 && uQuality>3.4 && uQuality<4.0)))
        transitionThreshold=surfaceThreshold(transitionPosition,transitionFootprint,vTreeCode+173u);

    if((uKind==1 || uKind==5 || uKind==6) && vSeasonVisible<=0.0) discard;
    if((uKind==5 || uKind==6) && uNeedleDetail>0.0 && uNeedleDetail<1.0) {
        // Complementary masks: a pixel sees either the real needles or their
        // integrated shoot. Tree-local shadow coordinates do not crawl as the
        // receiver moves; both representations share the original shoot phase.
        float choice=uDepthOnly==1 ? hash(floor(vShadowMask*64.0)+vec2(23,71)+vShoot.w*vec2(197,317)) : transitionThreshold;
        foliageCoverage(uNeedleDetail,choice,vTreeCode+173u,uKind==6);
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
            if(x>edge*.75 || vPhase>=density) discard;
        } else {
        // Fine serrations describe the needle fringe. Integrate them once they
        // become subpixel rather than drawing oversized individual needles.
        float rows=vUV.y*vShoot.z-x*2.3+vPhase*71.0;
        float rowWidth=abs(foliageDx.y*vShoot.z-sign(vUV.x-.5)*foliageDx.x*4.6)+
            abs(foliageDy.y*vShoot.z-sign(vUV.x-.5)*foliageDy.x*4.6);
        float resolved=1.0-smoothstep(.3,1.0,rowWidth);
        float tooth=mix(.5,abs(fract(rows)-.5)*2.0,resolved);
        edge*=.50+.50*tooth;
        float aa=max(.001,2.0*(abs(foliageDx.x)+abs(foliageDy.x)));
        float coverage=(1.0-smoothstep(edge-aa,edge+aa,x))*vShoot.y*vSeasonVisible*vNeedleCoverage;
        foliageCoverage(coverage,leafThreshold(vObject,footprint,uint(vPhase*65535.0)),uint(vPhase*65535.0),false);
        }
    }
    if(uKind==5 && vNeedleCoverage<.9999) {
        // Raster guards enlarge sub-texel needles; compensate their area with
        // a stable per-needle choice in depth maps. Screen-space random holes
        // were reseeded whenever the shadow atlas snapped by one texel.
        float coverageNoise=uDepthOnly==1 ? vPhase :
            leafThreshold(vObject,footprint,uint(vPhase*65535.0));
        foliageCoverage(vNeedleCoverage,coverageNoise,uint(vPhase*65535.0),false);
    }
    if(uKind==2 && uSeasonLeaf<1.0 && hash(floor(vUV*vec2(137,91))+vPhase*317.0)>=uSeasonLeaf) discard;
    // Complementary tree-anchored thresholds keep depth writes and avoid sorting.
    if(uQuality>.35 && uQuality<.95 && uKind!=4) {
        float screen=uDepthOnly==1 ? hash(floor(vShadowMask*16.0)) : transitionThreshold;
        float farMix=smoothstep(.35,.95,uQuality);
        foliageCoverage(farMix,screen,vTreeCode+173u,uKind==3);
    }
    if(uDirectBranches==0 && uQuality>3.4 && uQuality<4.0 && (uKind==1 || uKind==2 || uKind==5)) {
        float detail=smoothstep(3.4,4.0,uQuality);
        float detailNoise=uDepthOnly==1 ? hash(floor(vShadowMask*16.0)+vec2(73,29)) : transitionThreshold;
        foliageCoverage(detail,detailNoise,vTreeCode+173u,uKind==2);
    }
    // Solid wood and needle triangles need only the coverage masks above in
    // a shadow pass. Do not evaluate bark noise, normals or material colours.
    if(uDepthOnly==1 && (uKind==0 || uKind==5 || uKind==6 || uKind==7 || uKind==8)) { fragColor=vec4(1); return; }
    if(uKind==3 && uUseBakedLOD==1) {
        // Premultiplied linear mips retain subpixel foliage density. Object-space
        // coverage keeps depth writes and needs no per-tree alpha sorting.
        vec4 texel=lodTexel(uLODTexture,vLODLayer);
        // Atlas alpha already measures subpixel wood/foliage coverage. Raising
        // it again made conifers much denser than their actual nearby needles.
        float coverage=texel.a;
        vec4 foliage=vec4(0);
        vec4 fruit=vec4(0);
        float fruitCoverage=0.0;
        float woodCoverage=0.0, leafCoverage=0.0;
        if(uLODSeasonParts==1) {
            // First 12 layers: real bare wood; next 12: real foliage only.
            // Recolour foliage before compositing. Bark never receives leaf tint.
            if(uSeasonLeaf>0.0001) foliage=lodTexel(uLODTexture,vLODLayer+12.0);
            woodCoverage=texel.a;
            leafCoverage=foliage.a*uSeasonLeaf;
            coverage=leafCoverage+woodCoverage*(1.0-leafCoverage);
            if(uLODFruitLayer==1 && uFruitAmount>0.0) {
                fruit=lodTexel(uLODTexture,vLODLayer+24.0);
                fruitCoverage=clamp(fruit.a*uFruitAmount,0.0,1.0);
                coverage=fruitCoverage+coverage*(1.0-fruitCoverage);
            }
        } else {
            // Legacy atlas support; newly baked banks use the wood/foliage path.
            coverage*=uSeasonLeaf;
        }
        // Independent instance masks are essential: shared thresholds
        // leave the same holes through every tree in a dense forest.
        vec2 coverageCell=floor(vUV*512.0);
        if(coverage<=.003)discard;
        foliageCoverage(coverage,uDepthOnly==1 ? hash(coverageCell+vec2(197,83)+vPhase*vec2(971,613)) :
            leafThreshold(vObject,footprint,uint(vPhase*65535.0)),uint(vPhase*65535.0),false);
        if(uDepthOnly==1) { fragColor=vec4(1); return; }
        vec3 baked=texel.rgb/max(texel.a,.0001);
        // Explicit gradients were captured before any discard. A transparent
        // component contributes exactly zero, so skip its normal-map samples
        // and lighting; keep the other component and all alpha decisions.
        if(uLODRelight==1 && (uFragmentWorkReuse==0 || uLODSeasonParts==0 || woodCoverage>0.0))
            baked=relightLOD(baked,vLODLayer,false);
        if(uLODSeasonParts==1) {
            vec3 leafRGB=foliage.rgb/max(foliage.a,.0001)*uLeafRatio;
            vec3 fruitRGB=fruit.rgb/max(fruit.a,.0001);
            if(uLODRelight==1){
                if(uFragmentWorkReuse==0 || leafCoverage>0.0)
                    leafRGB=relightLOD(leafRGB,vLODLayer+12.,true);
                if(fruitCoverage>0.)fruitRGB=relightLOD(fruitRGB,vLODLayer+24.,false); }
            baked=((leafRGB*leafCoverage+baked*woodCoverage*(1.0-leafCoverage))*(1.0-fruitCoverage)+
                fruitRGB*fruitCoverage)/max(coverage,.0001);
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
        // Wood is opaque: shadow passes need neither colour nor normal maps.
        if(uDepthOnly==1){fragColor=vec4(1);return;}
        color=uBark;
        if((vSpecies<14 || vSpecies>=19) && vObject.x<.012 && vSpecies!=1 && vSpecies!=13 && vSpecies!=19)color=uBark*.42;
        else if(vSpecies<14 || vSpecies>=19) {
            int family=0;vec2 metres=vec2(1,2);
            if(vSpecies==2 || vSpecies==4 || vSpecies==5 || vSpecies==7 || vSpecies==12){family=1;metres=vec2(2);}
            else if(vSpecies==3){family=2;metres=vec2(1);}
            else if(vSpecies==6 || vSpecies>=8){family=3;metres=vec2(1.8);}
            float circumference=6.2831853*vObject.y;
            // Integer wraps close the seam. Small twigs smoothly lose old bark,
            // so large trunk cracks never get squeezed onto a 2 mm shoot.
            vec2 barkUV=vec2(vUV.x*max(1.0,floor(circumference/metres.x+.5)),vUV.y/metres.y);
            barkUV+=vec2(vPhase,vPhase*.731);
            vec3 scan=texture(uLeafSprays,vec3(barkUV,float(family))).rgb;
            vec3 detail=texture(uLeafSprays,vec3(barkUV,float(family+4))).rgb*2.0-1.0;
            float aged=smoothstep(.012,.095,vObject.x);
            color=mix(uBark*.42,scan*uBarkTint,aged);
            float strength=aged*.85;
            if(vSpecies==1) {
                // White papery bark with narrow horizontal lenticels, not
                // rectangular black camouflage. Mature bases become fissured.
                vec2 markUV=vec2(vUV.x*max(1.0,floor(circumference/.28+.5)),vUV.y*22.0);
                float row=floor(markUV.y);
                float markID=floor(markUV.x+hash(vec2(row,vPhase)));
                float variation=hash(vec2(row+7.0,markID)+vPhase*151.0);
                vec2 q=vec2(fract(markUV.x+hash(vec2(row,vPhase)))-.5,
                    fract(markUV.y)-.25-.5*hash(vec2(row,markID)+vPhase*17.0));
                q.y+=sin(q.x*13.0+row)*.035;
                float halfLength=.04+.30*variation*variation;
                float lenticel=(1.0-smoothstep(halfLength,halfLength+.03,abs(q.x)))*
                    (1.0-smoothstep(.025,.065,abs(q.y)));
                float base=smoothstep(.06,.20,vObject.x)*(1.0-smoothstep(.1,1.7,vUV.y))*(1.0-step(.5,vObject.z));
                vec3 white=uBark*(.73+.55*scan.r);
                white=mix(white,vec3(.09,.085,.075)*uBarkTint,lenticel*.85);
                color=mix(mix(vec3(.13,.085,.05)*uBarkTint,white,smoothstep(.012,.04,vObject.x)),scan*uBarkTint,base*.9);
                strength=mix(.08,.8,base);
            }
            if(vSpecies==13 || vSpecies==19) {
                // Rowan and eucalyptus have much smoother, lighter young bark.
                color=mix(uBark*(.85+scan.r*.6),color,.22*aged);
                strength*=.25;
            }
            vec3 along=normalize(vNeedleAxis-n*dot(vNeedleAxis,n));
            vec3 across=normalize(cross(along,n));
            n=normalize(n*max(.25,detail.z)+across*detail.x*strength+along*detail.y*strength);
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
    } else if(uKind==8) {
        vec2 cell=fract(vUV*vec2(14,9))-.5;
        float areole=1.0-smoothstep(.035,.085,length(cell));
        color*=.85+vPhase*.23;color=mix(color,vec3(.27,.25,.12),areole*.65);
    } else if(uKind==1 && (vShoot.x>1.0 ||
              ((vSpecies==13 || vSpecies==20) && vShoot.w>1.0))) {
        float groupBlend=smoothstep(1.0,2.0,vShoot.w);
        vec4 spray=vec4(0);
        if(groupBlend<1.0) {
            vec2 sprayUV=.5+(fract(vUV)-.5)*vSprayCrop;
            spray=textureGrad(uLeafSprays,vec3(sprayUV,vShoot.z+floor(vPhase*8.0)),
                foliageDx*vSprayCrop,foliageDy*vSprayCrop);
        }
        if(groupBlend>0.0) {
            vec2 patchUV=vUV*.25+fract(vPhase*vec2(17.13,31.71));
            vec4 groupSpray=textureGrad(uLeafSprays,
                vec3(patchUV,80.0+vShoot.z*.125),foliageDx*.25,foliageDy*.25);
            spray=mix(spray,groupSpray,groupBlend);
        }
        float alpha=spray.a*vNeedleCoverage;
        // A group represents neighbouring twigs, not a rectangular fabric of
        // repeated leaves. A soft elliptical boundary keeps its silhouette
        // coherent when a memory-limited card covers more than one sprig.
        vec2 groupUV=(vUV-.5)*2.0/max(1.0,vShoot.w);
        float edge=1.0-smoothstep(.35,1.0,dot(groupUV,groupUV));
        alpha*=mix(1.0,edge,smoothstep(2.0,4.0,vShoot.w));
        if(alpha<=.003)discard;
        if(alpha<.999) {
            vec2 cell=floor(vUV*128.0)+vPhase*vec2(971,613);
            uvec2 pixel=uvec2(ivec2(floor(cell)));
            uint bits=pixel.x*1664525u+pixel.y*1013904223u;
            bits^=bits>>16u;bits*=2246822519u;bits^=bits>>13u;bits*=3266489917u;bits^=bits>>16u;
            float threshold=float(bits>>8u)*(1.0/16777216.0);
            foliageCoverage(alpha,uDepthOnly==1 ? threshold : leafThreshold(vObject,footprint,uint(vPhase*65535.0)),uint(vPhase*65535.0),false);
        }
        if(uDepthOnly==1){fragColor=vec4(1);return;}
        vec2 tilt=spray.gb/max(spray.a,.0001)*2.0-1.0;
        vec3 along=normalize(vNeedleAxis),across=normalize(cross(along,n));
        n=normalize(n*sqrt(max(.05,1.0-dot(tilt,tilt)))+across*tilt.x+along*tilt.y);
        float shade=spray.r/max(spray.a,.0001);
        if(vShoot.x<=1.0)shade*=1.333333333; // compound-leaf bake has 25% highlight headroom
        color=shade<.48 ? uBark*.72 : color*shade;
        if(!gl_FrontFacing) {
            if(vSpecies==3){float gray=dot(color,vec3(.2126,.7152,.0722));color=mix(color,vec3(gray)*1.22,.34);}
            else if(vSpecies==0)color*=vec3(.92,1.04,1.25);
        }
        n=gl_FrontFacing?n:-n;ao=.87;
    } else if(uKind==1 || uKind==9) {
        float bladeCoverage=vNeedleCoverage;
        if(uKind==1 && vShoot.w>1.0) {
            vec2 groupUV=(vUV-.5)*2.0/vShoot.w;
            float edge=1.0-smoothstep(.35,1.0,dot(groupUV,groupUV));
            bladeCoverage*=mix(1.0,edge,smoothstep(2.0,4.0,vShoot.w));
        }
        if(uKind==1 && bladeCoverage<1.0)
            foliageCoverage(bladeCoverage,leafThreshold(vObject,footprint,uint(vPhase*65535.0)),uint(vPhase*65535.0),false);
        vec2 p=(uKind==1?fract(vUV):vUV)*2.0-1.0;
        float leafPhase=vPhase;
        float rows=vShoot.x;
#ifdef LEAF_SPRAY_BAKE
        if(rows>1.0) {
            // Alternate blades on a short twig. Dimensions are in twig-space
            // metres, not screen pixels; no distance-dependent leaf growth.
            vec2 point=vec2(p.x*vShoot.y,p.y)*1.7;
            float stemX=.025*sin(point.y*4.0+vPhase*6.28);
            if(uKind==9 && abs(point.x-stemX)<.006 && abs(point.y)<.98) {
                fragColor=vec4(.33,.5,.5,1);return;
            }
            float side=point.x<0.0 ? -1.0 : 1.0;
            float row=floor((point.y+1.0)*rows);
            float best=1e9;
            for(int neighbor=-1;neighbor<=1;neighbor++) {
                float slot=clamp(row+float(neighbor),0.0,rows*2.0-1.0);
                float r=hash(vec2(slot,side)+vPhase*317.0);
                float r2=hash(vec2(slot+37.0,side*3.0)+vPhase*113.0);
                float y=-1.0+(slot+.5+(r-.5)*.35)/rows;
                float angle=side*(.78+r2*.60);
                vec2 along=vec2(sin(angle),cos(angle));
                vec2 across=vec2(along.y,-along.x);
                float size=(.84+.24*r)/rows;
                vec2 center=vec2(.025*sin(y*4.0+vPhase*6.28),y)+along*size*.82;
                vec2 delta=point-center;
                vec2 blade=vec2(dot(delta,across)/vShoot.y,dot(delta,along))/size;
                float score=dot(blade,blade);
                if(score<best){best=score;p=blade;leafPhase=r;}
            }
            vec3 along=normalize(vNeedleAxis), across=normalize(cross(along,n));
            n=normalize(n+across*((leafPhase-.5)*.75+p.x*.16)+along*(p.y*.10));
        }
#endif
        float edge=1.0-p.y*p.y;
        float vein=1.0-smoothstep(.015,.055,abs(p.x));
        if(vSpecies==0) {
            // Rounded paired lobes on an elongated oak blade.
            edge=pow(max(0.0,edge),.60)*(.70+.25*cos(p.y*15.7+.30));
            if(abs(p.x)>edge || p.y<-.90) discard;
            float lateral=abs(fract((p.y-abs(p.x)*.32)*2.5+.5)-.5);
            vein=max(vein,(1.0-smoothstep(.015,.05,lateral))*.5);
        } else if(vSpecies==1) {
            // Rhombic birch blade: pointed apex and doubly serrated margins.
            float width=p.y>-.30 ? (1.0-p.y)/1.30 : (p.y+1.0)/.70;
            width*=.87+.07*cos(p.y*65.0)+.03*cos(p.y*135.0);
            if(abs(p.x)>width) discard;
            float lateral=abs(fract((p.y-abs(p.x)*.52)*3.5+.5)-.5);
            vein=max(vein,(1.0-smoothstep(.012,.045,lateral))*.4);
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
        if(uKind==9) {
            // Packed linear albedo multiplier and tangent-space normal XY.
            // Alpha remains coverage through ordinary mip filtering.
            float shade=(.80+leafPhase*.16)*(1.0+vein*.08);
            if(rows<=1.0)shade=.75*(.80+leafPhase*.36)*(1.0+vein*.11);
            fragColor=vec4(shade,n.xy*.5+.5,1);return;
        }
        if(uDepthOnly==1) { fragColor=vec4(1); return; }
        color*=.80+leafPhase*.36;
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
    if(uBakeMode==2){fragColor=vec4(color*ao,1);return;}
    if(uBakeMode==3){fragColor=vec4(n*.5+.5,1);return;}
    vec3 sun=normalize(uSunDirection);
    // The pine shoot integrates differently oriented needles, not one shiny
    // camera-facing cylinder. Match their measured normal moment; the far
    // atlas already stores orientation dispersion from the actual needles.
    if(uKind==6 && vSpecies==2)color=foliageLighting(color,n*.45,.55)*ao;
    else if(uKind==1 || uKind==5 || uKind==6)color=foliageLighting(color,n,0.0)*ao;
    else color*=(.38+.58*max(0.0,dot(n,sun)))*ao;
    if(uKind==7 && vFruit.w>=0.0 && vFruit.w!=12.0 && uBakeMode==0) {
        vec3 halfDirection=normalize(sun+normalize(uEye-vWorld));
        color+=vec3(.7,.65,.5)*pow(max(0.0,dot(n,halfDirection)),30.0)*.16;
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
