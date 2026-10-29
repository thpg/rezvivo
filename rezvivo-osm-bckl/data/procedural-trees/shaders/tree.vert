#version 330 core
layout(location=0) in vec4 a;
layout(location=1) in vec4 b;
layout(location=2) in vec4 c;
layout(location=3) in vec4 d;
layout(location=4) in uint aTreeCode;
layout(location=5) in vec4 aBranchFrame; // fixed local binormal, effective length
uniform mat4 uProjection, uView, uModel;
uniform int uKind, uSlices, uSegments, uNeedlePairs, uNeedlesPerFascicle;
uniform int uNeedleVertices;
uniform int uComplexity;
uniform int uPreparedFrames;
uniform int uDistantArena;
uniform vec3 uDistantOrigin;
uniform int uCardEnvelope;
uniform vec2 uEnvelopePoints[8],uEnvelopeViewport;
/*__VEGETATION_CARD_ENVELOPE__*/
uniform float uQuality, uTime, uWind, uViewportHeight;
uniform float uSeasonLeaf;
uniform float uFruitAmount;
uniform int uFruitMembers;
// Optional host thinning; old hosts keep physical foliage size.
uniform float uNeedleScale;
uniform vec4 uLeafBudget; // continuous prefix count, fade width, compact shoot extent
uniform vec4 uLeafSpray; // rows, aspect, shared layer base, grouping extent
uniform int uSpecies;
uniform float uNeedleDetail;
uniform vec4 uProfile; // height, trunk radius, crown spread, crown start
uniform vec3 uEye;
uniform vec3 uSunDirection;
uniform vec3 uBillboardRight;
uniform int uBakeMode, uUseBakedLOD, uDirectBranches, uDepthOnly;
uniform int uShadowPartitions, uShadowPartition;
uniform vec3 uLODFrames[3];
flat out float vLODLayer;
flat out vec2 vLODViewBlend;
flat out float vLODRotation;
out vec3 vWorld, vNormal;
out vec3 vTransitionCoord;
flat out float vTransitionFootprint;
out vec3 vObject;
out vec3 vNeedleAxis;
out vec2 vShadowMask;
out vec2 vUV;
flat out vec4 vProfile;
flat out float vPhase;
flat out int vSpecies;
flat out uint vTreeCode;
flat out float vMaturity;
flat out float vIrregularity;
flat out float vSeasonVisible;
flat out float vNeedleCoverage;
flat out vec4 vShoot;
flat out vec2 vSprayCrop;
flat out vec4 vFruit;
const float PI = 3.14159265359;
const ivec2 corners[6] = ivec2[6](ivec2(0,0),ivec2(1,0),ivec2(1,1),ivec2(0,0),ivec2(1,1),ivec2(0,1));
// Two-segment tapered ribbon: three actual triangles per needle, no leaf mask.
const vec2 needleVertices[9] = vec2[9](vec2(-1,0),vec2(1,0),vec2(-1,.55),
    vec2(-1,.55),vec2(1,0),vec2(1,.55),vec2(-1,.55),vec2(1,.55),vec2(0,1));
const vec2 shortNeedleVertices[3] = vec2[3](vec2(-1,0),vec2(1,0),vec2(0,1));
float random1(float x) { return fract(sin(x*127.1+311.7)*43758.5453); }
vec3 curve(vec3 p, vec3 ctrl, vec3 tip, float t) {
    return p*(1.0-t)*(1.0-t)+2.0*ctrl*t*(1.0-t)+tip*t*t;
}
vec3 wind(vec3 p, float phase) {
    if(uComplexity==0)return p;
    if(uComplexity==1)return p+vec3(sin(uTime*1.25+p.y*.31),0,0)*uWind*pow(max(0.0,p.y/max(.1,uProfile.x)),2.0)*.22;
    float weight = pow(max(p.y,0.0)/max(uProfile.x,1.0),2.0);
    return p + vec3(sin(uTime*1.25+p.y*.31)+.35*sin(uTime*2.1+p.y*.63+p.x*.11+p.z*.13),
                   0.0, .5*cos(uTime*.93+p.y*.4))*uWind*weight*.22;
}
// One preparation per physical needle in the mesh path, the same equations
// in the ordinary vertex path. No second foliage shape or animation model.
struct TreeNeedleShape {
    vec3 base,tip,bend,side,radial,facing;
    float season,lodScale,physicalLength,pixelWorld,length,width,coverage,flutter,phase;
};
TreeNeedleShape prepareTreeNeedleImpl(int needle,int species) {
    TreeNeedleShape r;
    r.season=1.0;
        int fascicle=needle/uNeedlesPerFascicle;
        float member=float(needle%uNeedlesPerFascicle);
        float id=float(fascicle)+d.x*173.0;
        if(uSeasonLeaf<.99999) r.season=smoothstep(random1(id+member*19.0),random1(id+member*19.0)+.08,uSeasonLeaf*1.08);
        if(r.season<=0.0) return r;
        // A low-discrepancy prefix covers the whole shoot. Its positions do not
        // depend on the draw count: approaching adds needles without moving old ones.
        float t=.02+.96*fract(float(fascicle)*.61803398875+random1(d.x*173.0+2.0));
        vec3 tangent=normalize(mix(b.xyz-a.xyz,c.xyz-b.xyz,t));
        r.side=normalize(cross(tangent,abs(tangent.y)>.95?vec3(1,0,0):vec3(0,1,0)));
        vec3 up=cross(tangent,r.side);
        // Keep azimuth independent of the longitudinal low-discrepancy order.
        // Golden-angle azimuth is the complement of .61803398875: pairing the
        // two locks every needle to one turn of a helix and leaves bare strips.
        float angle=random1(id+11.0)*2.0*PI;
        if(species==7 || species==12) angle+=member*2.0*PI/float(uNeedlesPerFascicle);
        r.radial=r.side*cos(angle)+up*sin(angle);
        // Pines share a sheath in pairs; spruce is solitary; juniper has
        // three needles around each whorl. No CPU needle geometry is stored.
        r.base=curve(a.xyz,b.xyz,c.xyz,t)+r.radial*a.w*mix(1.0,.18,t);
        float spread=angle;
        if(uNeedlesPerFascicle==2) spread+=(member*2.0-1.0)*(.09+.13*random1(id+3.0));
        float forward=species==5 ? .20 : .45;
        vec3 direction=normalize(tangent*(forward+.30*random1(id+4.0))+
            r.side*cos(spread)*.90+up*sin(spread)*.90);
        // Thinning must not turn individual needles into metre-long ribbons.
        // Bound geometric compensation; represent the remaining density in
        // sample coverage below. Full-detail needles keep their physical size.
        r.lodScale=min(sqrt(uNeedleScale),1.5);
        r.physicalLength=b.w*(.80+.35*random1(id+member*7.0))*sqrt(r.season)*r.lodScale;
        float viewDepth=max(.05,-(uView*uModel*vec4(r.base,1.0)).z);
        bool orthographic=abs(uProjection[3][3]-1.0)<.001;
        r.pixelWorld=2.0*(orthographic ? 1.0 : viewDepth)/(uProjection[1][1]*uViewportHeight);
        // The pixel guard is bounded too, otherwise it multiplies LOD growth.
        // Keep the offline bake footprint unchanged for existing far atlases.
        r.length=max(r.physicalLength,min(r.pixelWorld*1.5,r.physicalLength*(uBakeMode>0 ? 4.0 : 1.25)));
        r.tip=r.base+direction*r.length;
        r.bend=r.base+direction*r.length*.52+tangent*r.length*(species==5?.04:.16);

    vec3 eyeLocal=transpose(mat3(uModel))*(uEye-uModel[3].xyz);
    r.facing=uDepthOnly==1 ? normalize(transpose(mat3(uModel))*uSunDirection) : normalize(eyeLocal-r.base);
    float physicalWidth=c.w*.5*r.lodScale*(uNeedleVertices==3 ? 1.29 : 1.0);
    r.width=max(physicalWidth,min(r.pixelWorld*.6,r.length*.45));
    float densityCoverage=uNeedleScale/(r.lodScale*r.lodScale);
    r.coverage=clamp(densityCoverage*(physicalWidth/r.width)*(r.physicalLength/r.length),0.0,1.0);
    r.flutter=uComplexity>=3 ? sin(uTime*4.1+d.x*23.0+float(fascicle))*uWind*.004 : 0.0;
    r.phase=random1(id+member*13.0);
    return r;
}
TreeNeedleShape prepareTreeNeedle(int needle) {
    return prepareTreeNeedleImpl(needle, vSpecies);
}

void main() {
    vec3 p=vec3(0), n=vec3(0,1,0);
    vec3 farRoot=a.xyz;
    if(uKind==3 && uDistantArena!=0)farRoot+=c.yzw-uDistantOrigin;
    vPhase=d.x; vTreeCode=aTreeCode; vSpecies=int(aTreeCode & 255u); vMaturity=d.z;
    vIrregularity=d.w;
    vSeasonVisible=1.0; vNeedleCoverage=1.0;
    vShoot=vec4(0,0,0,d.x);
    vSprayCrop=vec2(1);
    vFruit=vec4(0);
    vTransitionCoord=vec3(0,0,1);vTransitionFootprint=1.0;
    vProfile=uProfile; vNeedleAxis=vec3(0,1,0);vObject=vec3(0);
    vUV=vec2(corners[gl_VertexID%6]); vLODLayer=0.0;vLODRotation=0.0;vLODViewBlend=vec2(0);
    // Detailed trees are skipped on the CPU. Far instances share a buffer;
    // reject their four cheap vertices using the SAME stable per-tree bucket.
    if(uDepthOnly==1 && uKind==3 && uShadowPartitions>1 &&
       (int(c.x)&(uShadowPartitions-1))!=uShadowPartition) {
        vWorld=vec3(0);vNormal=vec3(0,1,0);vShadowMask=vec2(0);
        gl_Position=vec4(2,2,2,1);return;
    }
    if(uKind==9 || uKind==10) {
        vPhase=uTime;vSpecies=uSpecies;vShoot=uLeafSpray;
        vNormal=vec3(0,0,1);vNeedleAxis=vec3(0,1,0);
        vWorld=vec3(0);vShadowMask=vec2(0);vObject=vec3(0);
        gl_Position=vec4(vUV*2.0-1.0,0,1);return;
    }
    if (uKind==0) {
        int cell=gl_VertexID/6;
        float s=float(cell%uSlices+corners[gl_VertexID%6].x)/float(uSlices);
        float t=float(cell/uSlices+corners[gl_VertexID%6].y)/float(uSegments);
        float start=.2+max(c.w-1.0,0.0)*.8;
        float growth=(c.w<.5 || uDirectBranches==1) ? 1.0 : smoothstep(start,start+.8,uQuality);
        // More rings at the root/collar without adding rings to fine shoots.
        if(c.w<1.5 && vSpecies!=17 && vSpecies!=18 && uSegments>=8)t=t*t;
        t*=growth;
        vec3 first=b.xyz-a.xyz,last=c.xyz-b.xyz;
        vec3 velocity=2.0*mix(first,last,t);
        vec3 tangent=normalize(velocity);
        // A quadratic curve is planar: its fixed binormal is a rotation-
        // minimizing tube frame. Never switch reference axes along a branch.
        vec3 side;
        if(uPreparedFrames==1) side=aBranchFrame.xyz;
        else {
            vec3 plane=cross(first,last);
            if(dot(plane,plane)<1e-8*max(dot(first,first)*dot(last,last),1e-8))
                plane=cross(normalize(first),abs(normalize(first).y)>.95 ? vec3(1,0,0):vec3(0,1,0));
            side=normalize(plane);
        }
        if(vSpecies==17 && uPreparedFrames==0) {
            // A fixed normal to the elbow's plane keeps the tube frame from
            // flipping as a thick cactus arm becomes vertical.
            vec3 radialArm=vec3(c.x-a.x,0,c.z-a.z);
            if(dot(radialArm,radialArm)<.00001) radialArm=vec3(a.x,0,a.z);
            side=dot(radialArm,radialArm)>.00001 ? normalize(cross(radialArm,vec3(0,1,0))) : vec3(0,0,1);
        }
        vec3 up=cross(tangent,side);
        n=side*cos(s*2.0*PI)+up*sin(s*2.0*PI);
        vec3 radial=n;
        float radius=mix(a.w,b.w,t);
        float branchLength=uPreparedFrames==1 ? aBranchFrame.w : length(c.xyz-a.xyz);
        bool structural=(c.w<.5 || a.w>.025) && (vSpecies<14 || vSpecies>=19);
        if(structural) {
            if(uPreparedFrames==0)branchLength=.5*(length(first)+length(last)+branchLength);
            float theta=s*2.0*PI, drdt=b.w-a.w, drda=0.0;
            float flare,rate;
            if(c.w<.5) {
                rate=branchLength*3.5/max(.12,min(1.2,a.w*4.0));
                float decay=exp(-t*rate);
                flare=(.44+.20*cos(theta*5.0+d.x*6.28))*decay;
                drda=radius*(-sin(theta*5.0+d.x*6.28))*decay;
            } else {
                rate=branchLength/max(.025,a.w*2.2);
                flare=.26*exp(-t*rate);
            }
            drdt=drdt*(1.0+flare)-radius*flare*rate;
            radius*=1.0+flare;
            if(c.w>.5 && d.w>0.0) {
                float x=clamp(t*branchLength/max(.002,d.w*.72),0.0,1.0);
                float collar=x*x*(3.0-2.0*x);
                drdt=drdt*collar+radius*6.0*x*(1.0-x)*branchLength/max(.002,d.w*.72);
                radius*=collar;
            }
            vec3 around=-side*sin(theta)+up*cos(theta);
            if(uDepthOnly==0)n=normalize(radial-tangent*drdt/max(.001,length(velocity))-around*drda/max(.001,radius));
        }
        if(vSpecies==17) {
            // Closed round ends on succulent columns; no conical tree tips.
            if(b.w==0.0) {
                float cap=min(.20,a.w/max(.01,length(c.xyz-a.xyz)));
                float phi=clamp((t-.70)/.30,0.0,1.0)*PI*.5;
                t=t<.70 ? t/.70*(1.0-cap) : 1.0-cap+cap*sin(phi);
                radius=a.w*(1.0-.12*t)*cos(phi);
                n=normalize(radial*cos(phi)+tangent*sin(phi));
            }
            radius*=.94+.06*cos(s*12.0*PI);
        }
        if(vSpecies==14) radius*=1.0+.07*pow(max(0.0,cos(t*length(c.xyz-a.xyz)*17.0)),16.0);
        p=curve(a.xyz,b.xyz,c.xyz,t)+radial*radius*growth;
        if(uDepthOnly==0 && c.w>.5 && d.w>0.0 && structural) {
            vec2 oct=vec2(floor(d.z/256.0),mod(d.z,256.0))/255.0*2.0-1.0;
            vec3 parent=vec3(oct,1.0-abs(oct.x)-abs(oct.y));
            if(parent.z<0.0)parent.xy=(1.0-abs(parent.yx))*sign(parent.xy);
            parent=normalize(parent);
            vec3 delta=p-a.xyz;
            vec3 parentRadial=delta-parent*dot(delta,parent);
            float r=length(parentRadial);
            if(r>.0001)n=normalize(mix(parentRadial/r,n,smoothstep(d.w*.93,d.w*1.35,r)));
            vMaturity=1.0;
        }
        if(c.w<.5 && t==0.0 && vSpecies<14) p.y=0.0;
        vUV=vec2(s,t*branchLength);
        vNeedleAxis=normalize(mat3(uModel)*tangent);
        // Reuse the procedural-pattern varying; wood needs radii/order instead.
        vObject=vec3(radius,a.w,c.w);
    } else if (uKind==1) {
        // Stable birth/drop order per leaf; time never enters the mask.
        if(uSeasonLeaf<.99999) vSeasonVisible=smoothstep(random1(d.x*417.0),random1(d.x*417.0)+.08,uSeasonLeaf*1.08);
        if(vSeasonVisible<=0.0) { gl_Position=vec4(2,2,2,1); return; }
        vec3 axis,side;
        if(uPreparedFrames==1) {
            axis=b.xyz*c.w;side=c.xyz;
        } else {
            axis=normalize(b.xyz);
            side=normalize(cross(axis,abs(axis.y)>.95 ? vec3(1,0,0):vec3(0,1,0)));
        // Preserve the generated leaf inclination. A small, stable spread
        // breaks parallel grouped sheets; a full random turn made horizontal
        // foliage stand vertically and changed the crown's projected density.
        // Untouched close-up sprigs keep their exact original axes.
            float roll=(d.x-.5)*.70*smoothstep(1.0,2.0,uLeafBudget.z);
            side=side*cos(roll)+cross(axis,side)*sin(roll);
        }
        vShoot=uLeafSpray;
        // Stable nested prefix: a narrow band of twigs fades instead of
        // dropping a complete card each time the rounded draw count changes.
        if(uLeafBudget.y>0.0)
            vNeedleCoverage=clamp((uLeafBudget.x-float(gl_InstanceID)-.5)/uLeafBudget.y+.5,0.0,1.0);
        // Keep a unique coverage phase per twig. Only the texture layer is
        // quantized; sharing eight alpha masks opened holes through the crown.
        vNeedleAxis=normalize(mat3(uModel)*axis);
        vec2 uv=vUV*2.0-1.0;
        vec2 extent=vec2(1.0);
        if(uLeafSpray.x>1.0) {
            // Crop only the empty sprite border, never magnify its blades.
            // A six-row birch spray needs much less width than an oak spray.
            float rows=uLeafSpray.x, aspect=uLeafSpray.y;
            float blade=1.08/rows;
            extent.x=min(1.7,(.025+blade*(.82+max(1.0,aspect)))/aspect+.025);
            extent.y=min(1.7,1.0-.325/rows+blade*(.584+sqrt(.506+aspect*aspect))+.025);
            vSprayCrop=extent/1.7;
        }
        vUV=.5+.5*uv*uLeafSpray.w;
        p=a.xyz+(axis*uv.y*a.w*extent.y+side*uv.x*a.w*b.w*extent.x)*sqrt(vSeasonVisible)*uLeafSpray.w;
        vObject=p;
        if(uComplexity>=3)p.y+=sin(uTime*3.0+d.x*37.0)*uWind*min(.025,a.w*.15)*uv.y;
        n=normalize(cross(side,axis));
    } else if (uKind==8) {
        // Opuntia cladodes: thick closed pads, using the existing leaf buffer.
        vec3 axis=normalize(b.xyz);
        vec3 side=normalize(cross(axis,abs(axis.y)>.95?vec3(1,0,0):vec3(0,1,0)));
        vec3 up=cross(axis,side);
        side=side*cos(d.x*6.2831853)+up*sin(d.x*6.2831853);
        up=cross(axis,side);
        int cell=gl_VertexID/6;
        float s=float(cell%uSlices+corners[gl_VertexID%6].x)/float(uSlices);
        float t=float(cell/uSlices+corners[gl_VertexID%6].y)/float(uSegments);
        float phi=t*PI,theta=s*2.0*PI;
        vec3 q=vec3(sin(phi)*cos(theta),cos(phi),sin(phi)*sin(theta));
        vec3 scale=vec3(a.w*b.w,a.w,a.w*.14);
        p=a.xyz+side*q.x*scale.x+axis*q.y*scale.y+up*q.z*scale.z;
        n=normalize(side*q.x/scale.x+axis*q.y/scale.y+up*q.z/scale.z);
        vUV=vec2(s,t);
    } else if (uKind==2) {
        int cell=gl_VertexID/6;
        float s=float(cell%uSlices+corners[gl_VertexID%6].x)/float(uSlices);
        float t=float(cell/uSlices+corners[gl_VertexID%6].y)/float(uSegments);
        float phi=t*PI, theta=s*PI*2.0;
        n=vec3(sin(phi)*cos(theta),cos(phi),sin(phi)*sin(theta));
        p=a.xyz+n*b.xyz;
        n=normalize(n/b.xyz); vUV=vec2(s,t);
    } else if (uKind==7) {
        // Fruit is a real closed surface. One descriptor also expands a berry
        // cluster; no CPU sphere meshes, no camera-facing fruit cards.
        vec3 axis=normalize(b.xyz);
        vec3 side=normalize(cross(axis,abs(axis.y)>.95?vec3(1,0,0):vec3(0,1,0)));
        vec3 up=cross(axis,side);
        int bodyVertices=uSlices*uSegments*6;
        int itemVertices=bodyVertices+(uFruitMembers>1?12:0);
        int member=gl_VertexID/itemVertices;
        bool cluster=c.w==6.0 || c.w==7.0 || c.w==13.0 || c.w==14.0;
        vFruit=c;
        float growth=sqrt(clamp(uFruitAmount,0.0,1.0));
        if(gl_VertexID>=itemVertices*uFruitMembers) {
            // Peduncle touches the same quadratic branch point used on CPU.
            int id=gl_VertexID-itemVertices*uFruitMembers;
            float s=float(id/6+corners[id%6].x)*.25;
            float t=float(corners[id%6].y);
            n=side*cos(s*2.0*PI)+up*sin(s*2.0*PI);
            float extent=b.w+(cluster?a.w*(c.w==13.0?3.0:7.0):0.0);
            p=a.xyz+axis*mix(0.0,extent+.018,t)+n*min(.0014,a.w*.13);
            vFruit=vec4(.11,.065,.018,-1);
            vUV=vec2(s,t);
        } else {
            int id=gl_VertexID%itemVertices;
            vec3 center=a.xyz;
            if(uFruitMembers>1) {
                float q=(float(member)+.5)/float(uFruitMembers);
                float az=float(member)*2.39996323+d.x*6.28;
                float clusterRadius=a.w*(uFruitMembers>12?4.6:2.0);
                // Filled, slightly domed corymb. A sphere shell left a hollow
                // ring of berries, instead of the dense rowan bunch.
                center+=((side*cos(az)+up*sin(az))*sqrt(q)-axis*sqrt(1.0-q)*.45)*clusterRadius*growth;
                if(c.w==7.0) center=a.xyz+axis*((q-.5)*a.w*14.0)+(side*cos(az)+up*sin(az))*a.w*1.4;
                vFruit.rgb*=.85+.25*random1(float(member)+d.x*37.0);
            }
            if(id>=bodyVertices) {
                int stem=id-bodyVertices;
                vec3 from=a.xyz+axis*a.w*(c.w==13.0?1.0:3.0);
                vec3 to=center+axis*b.w*.8;
                vec3 along=normalize(to-from);
                vec3 widthAxis=normalize(cross(along,abs(along.y)>.95?vec3(1,0,0):vec3(0,1,0)));
                if(stem>=6) widthAxis=cross(along,widthAxis);
                vec2 uv=vec2(corners[stem%6]);
                p=mix(from,to,uv.y)+widthAxis*(uv.x-.5)*a.w*.16;
                n=normalize(cross(widthAxis,along));vUV=uv;
                vFruit=vec4(.13,.065,.018,-1);
            } else {
            int cell=id/6;
            float s=float(cell%uSlices+corners[id%6].x)/float(uSlices);
            float t=float(cell/uSlices+corners[id%6].y)/float(uSegments);
            float phi=t*PI,theta=s*PI*2.0;
            float y=cos(phi),r=sin(phi),shape=1.0;
            float radius=a.w,halfLength=b.w;
            if(cluster && uFruitMembers==1) {
                radius*=c.w==13.0?4.9:2.8;
                halfLength*=c.w==7.0?8.0:(c.w==13.0?3.0:2.0);
                center-=axis*a.w;
                shape*=1.0+.065*sin(theta*7.0+phi*5.0);
            }
            if(c.w==1.0) shape=.83-.29*y; // pear: narrow neck, round lower half
            if(c.w==12.0) shape=(.84-.22*y)*(1.0+.055*cos(theta*9.0+t*PI*18.0));
            vec3 radial=side*cos(theta)+up*sin(theta);
            p=center+(radial*(r*radius*shape)+axis*(y*halfLength))*growth;
            n=normalize(radial*r/max(.001,radius*shape)+axis*y/max(.001,halfLength));
            vUV=vec2(s,t);
            }
        }
    } else if (uKind==3) {
        // One camera-facing quad per distant tree. No branch/leaf data needed.
        vec3 right=normalize(uBillboardRight);
        if(uDepthOnly==1) {
            vec3 sunLocal=transpose(mat3(uModel))*uSunDirection;
            right=vec3(sunLocal.z,0,-sunLocal.x);
            right=dot(right,right)>.00001 ? normalize(right) : vec3(1,0,0);
        }
        float width=b.x*b.z*1.18;
        p=farRoot+right*(vUV.x-.5)*width+vec3(0,vUV.y*b.x*1.32,0);
        if(uUseBakedLOD==1) {
            int age=vMaturity<.55 ? 0 : vMaturity<1.8 ? 1 : 2;
            vec3 frame=uLODFrames[age];
            if(uCardEnvelope!=0){
                vec3 origin=farRoot-right*.5*b.x*frame.x+vec3(0,frame.y*b.x,0);
                mat4 clip=uProjection*uView*uModel;
                bool tight=envelopeFootprint(clip*vec4(origin,1),clip*vec4(right*b.x*frame.x,0),
                    clip*vec4(0,(frame.z-frame.y)*b.x,0,0),uEnvelopeViewport,256.0);
                vUV=tight?uEnvelopePoints[envelopeIndex(gl_VertexID)]:fullEnvelopeUV(gl_VertexID);
            }
            p=farRoot+right*(vUV.x-.5)*b.x*frame.x+vec3(0,mix(frame.y,frame.z,vUV.y)*b.x,0);
            vec3 toEye=uDepthOnly==1 ? uSunDirection : uEye-(uModel*vec4(farRoot,1)).xyz;
            float azimuth=atan(toEye.x,toEye.z)/(2.0*PI);
            // Seed selects a stable quarter turn; each age has four actual views.
            float viewPhase=fract(azimuth+d.x)*4.0;
            int view=int(floor(viewPhase));
            vLODLayer=float(age*4+view);
            // Blend only around a view boundary. Most angles need one sample.
            vLODViewBlend=vec2(float(age*4+(view+1)%4),smoothstep(.30,.70,fract(viewPhase)));
            if(uDepthOnly==1) {
                vLODLayer=float(age*4+int(floor(viewPhase+.5))%4);
                vLODViewBlend=vec2(vLODLayer,0);
            }
            vLODRotation=azimuth*(2.0*PI)-float(view)*(.5*PI);
        }
        n=vec3(right.z,.35,-right.x);
        vProfile=b;
    } else if (uKind==6) {
        // A foliated shoot, built from the SAME quadratic twig as close needles.
        // Two bent strip segments share six vertices through the grid indices.
        float t=float(gl_VertexID/6+corners[gl_VertexID%6].y)/2.0;
        float across=float(corners[gl_VertexID%6].x)*2.0-1.0;
        vec3 center=curve(a.xyz,b.xyz,c.xyz,t);
        float groupExtent=max(1.0,uLeafBudget.z);
        vec3 groupCenter=curve(a.xyz,b.xyz,c.xyz,.5);
        center=groupCenter+(center-groupCenter)*groupExtent;
        vec3 tangent=normalize(mix(b.xyz-a.xyz,c.xyz-b.xyz,t));
        vec3 eyeLocal=transpose(mat3(uModel))*(uEye-uModel[3].xyz);
        vec3 facing=uDepthOnly==1 ? normalize(transpose(mat3(uModel))*uSunDirection) : normalize(eyeLocal-center);
        vec3 widthAxis=cross(tangent,facing);
        if(dot(widthAxis,widthAxis)<.0001)
            widthAxis=cross(abs(facing.y)>.95 ? vec3(1,0,0) : vec3(0,1,0),facing);
        widthAxis=normalize(widthAxis);
        vec3 along=normalize(cross(facing,widthAxis));
        float shootLength=.5*(length(b.xyz-a.xyz)+length(c.xyz-b.xyz)+length(c.xyz-a.xyz));
        float radius=max(b.w*.92,a.w)*groupExtent;
        float viewDepth=max(.05,-(uView*uModel*vec4(center,1)).z);
        bool orthographic=abs(uProjection[3][3]-1.0)<.001;
        float pixelWorld=2.0*(orthographic ? 1.0 : viewDepth)/(uProjection[1][1]*uViewportHeight);
        float rasterRadius=max(radius,min(pixelWorld*.6,radius*2.5));
        // Projected round caps keep the shoot visible even when looking along
        // its axis; the centreline and all attachment points stay in 3D.
        p=center+along*((t*2.0-1.0)*radius)+widthAxis*(across*rasterRadius);
        n=facing;vNeedleAxis=normalize(mat3(uModel)*along);
        float opticalDepth=float(uNeedlePairs*uNeedlesPerFascicle)*c.w*.32/max(shootLength,b.w);
        // Pine fascicles overlap inside a compact descriptor. Expanding its
        // rectangle cannot preserve that overlap: compensate its integrated
        // optical depth, rather than making retained needles oversized.
        if(vSpecies==2)opticalDepth*=.68*inversesqrt(groupExtent);
        vShoot.xyz=vec3((shootLength*groupExtent+2.0*radius)/radius,
            1.0-exp(-1.0*opticalDepth),clamp(shootLength*groupExtent/max(c.w*2.0,.004),6.0,256.0));
        vSeasonVisible=uSeasonLeaf;vNeedleCoverage=radius/rasterRadius;
        vUV=vec2(across*.5+.5,t);
    } else if (uKind==5) {
        int needle=gl_VertexID/uNeedleVertices;
        TreeNeedleShape needleShape=prepareTreeNeedle(needle);
        vSeasonVisible=needleShape.season;
        if(vSeasonVisible<=0.0) { gl_Position=vec4(2,2,2,1); return; }
        vec2 shape=uNeedleVertices==3 ? shortNeedleVertices[gl_VertexID%3] : needleVertices[gl_VertexID%9];
        vec3 axis=normalize(mix(needleShape.bend-needleShape.base,needleShape.tip-needleShape.bend,shape.y));
        vec3 widthAxis=cross(axis,needleShape.facing);
        if(dot(widthAxis,widthAxis)<.00001) widthAxis=cross(axis,needleShape.side);
        widthAxis=normalize(widthAxis);
        vNeedleCoverage=needleShape.coverage;
        float width=needleShape.width*(1.0-.48*shape.y);
        p=curve(needleShape.base,needleShape.bend,needleShape.tip,shape.y)+widthAxis*shape.x*width;
        vObject=p;
        if(uComplexity>=3)p+=needleShape.radial*needleShape.flutter*shape.y;
        if(uDepthOnly==0) {
            n=normalize(cross(widthAxis,axis));
            vNeedleAxis=normalize(mat3(uModel)*axis);
        }
        vUV=vec2(shape.x*.5+.5,shape.y);
        vPhase=needleShape.phase;
    } else {
        p=vec3((vUV.x-.5)*2000.0,-.035,(vUV.y-.5)*2000.0);
        vPhase=0.0; vSpecies=0;
    }
    vShadowMask=vec2(0);
    if(uDepthOnly==1 && ((uQuality>.35 && uQuality<.95) ||
        ((uKind==5 || uKind==6) && uNeedleDetail>0.0 && uNeedleDetail<1.0) ||
        (uDirectBranches==0 && uQuality>3.4 && uQuality<4.0))) {
        // Tree-local coordinates keep shadow transition masks attached to the
        // caster across atlas scrolling, origin rebasing and wind. Project along
        // sunlight so the far card and detailed tree share a coverage pattern.
        vec3 relative=mat3(uModel)*(p-(uKind==3 ? farRoot : vec3(0)));
        vec3 sun=normalize(uSunDirection);
        vec3 right=cross(sun,abs(sun.y)>.95 ? vec3(1,0,0) : vec3(0,1,0));
        right=normalize(right);
        vShadowMask=vec2(dot(relative,right),dot(relative,cross(sun,right)));
    }
    // Coverage belongs to the undeformed surface, never to the screen.
    if(uKind!=0 && uKind!=1 && uKind!=5)vObject=p;
    if(uKind==3)vObject=vec3((vUV.x-.5)*b.x,vUV.y*b.x,0);
    if((uKind<3 || uKind==5 || uKind==6 || uKind==7) && vSpecies!=17 && vSpecies!=18) p=wind(p,d.x);
    vec4 world=uModel*vec4(p,1.0);
    if((uQuality>.35 && uQuality<.95) ||
       ((uKind==5 || uKind==6) && uNeedleDetail>0.0 && uNeedleDetail<1.0) ||
       (uDirectBranches==0 && uQuality>3.4 && uQuality<4.0)) {
        // One projected metre-space plane through the tree root. Both LODs
        // meet at the same ray/plane coordinate, keeping their masks exactly
        // complementary. Unlike FragCoord the origin moves WITH the tree.
        vec3 root=(uView*uModel*vec4(uKind==3 ? farRoot : vec3(0),1)).xyz;
        vec3 point=(uView*world).xyz;
        vTransitionFootprint=2.0*(abs(uProjection[3][3]-1.0)<.001 ? 1.0 : abs(root.z))/(uProjection[1][1]*uViewportHeight);
        vTransitionCoord=abs(uProjection[3][3]-1.0)<.001 ? vec3(point.xy-root.xy,1) :
            vec3(point.xy*root.z-root.xy*point.z,point.z);
    }
    vWorld=world.xyz;
    vNormal=uDepthOnly==0 ? normalize(mat3(uModel)*n) : vec3(0,1,0);
    gl_Position=uProjection*uView*world;
}
