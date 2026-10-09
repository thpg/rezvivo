#version 330 core
layout(location=0) in vec4 a;
layout(location=1) in vec4 b;
layout(location=2) in vec4 c;
layout(location=3) in vec4 d;
layout(location=4) in uint aTreeCode;
uniform mat4 uProjection, uView, uModel;
uniform int uKind, uSlices, uSegments, uNeedlePairs, uNeedlesPerFascicle;
uniform int uNeedleVertices=9;
uniform int uComplexity;
uniform float uQuality, uTime, uWind, uViewportHeight;
uniform float uSeasonLeaf;
uniform float uFruitAmount=1.0;
uniform int uFruitMembers=1;
// Optional host thinning; old hosts keep physical foliage size.
uniform float uLeafScale=1.0, uNeedleScale=1.0;
uniform float uNeedleDetail=1.0;
uniform vec4 uProfile; // height, trunk radius, crown spread, crown start
uniform vec3 uEye;
uniform vec3 uSunDirection;
uniform vec3 uBillboardRight;
uniform int uBakeMode, uUseBakedLOD, uDirectBranches, uDepthOnly;
uniform vec3 uLODFrames[3];
flat out float vLODLayer;
out vec3 vWorld, vNormal;
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
void main() {
    vec3 p=vec3(0), n=vec3(0,1,0);
    vPhase=d.x; vTreeCode=aTreeCode; vSpecies=int(aTreeCode & 255u); vMaturity=d.z;
    vIrregularity=d.w;
    vSeasonVisible=1.0; vNeedleCoverage=1.0;
    vShoot=vec4(0,0,0,d.x);
    vFruit=vec4(0);
    vProfile=uProfile; vNeedleAxis=vec3(0,1,0);
    vUV=vec2(corners[gl_VertexID%6]); vLODLayer=0.0;
    if (uKind==0) {
        int cell=gl_VertexID/6;
        float s=float(cell%uSlices+corners[gl_VertexID%6].x)/float(uSlices);
        float t=float(cell/uSlices+corners[gl_VertexID%6].y)/float(uSegments);
        float start=.2+max(c.w-1.0,0.0)*.8;
        float growth=(c.w<.5 || uDirectBranches==1) ? 1.0 : smoothstep(start,start+.8,uQuality);
        t*=growth;
        vec3 tangent=normalize(mix(b.xyz-a.xyz,c.xyz-b.xyz,t));
        vec3 side=normalize(cross(tangent,abs(tangent.y)>.95 ? vec3(1,0,0):vec3(0,1,0)));
        if(vSpecies==17) {
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
        if(c.w<.5 && vSpecies<14) radius*=1.0+.48*exp(-t*18.0);
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
        if(c.w<.5 && t==0.0 && vSpecies<14) p.y=0.0;
        vUV=vec2(s,t*length(c.xyz-a.xyz));
    } else if (uKind==1) {
        // Stable birth/drop order per leaf; time never enters the mask.
        if(uSeasonLeaf<.99999) vSeasonVisible=smoothstep(random1(d.x*417.0),random1(d.x*417.0)+.08,uSeasonLeaf*1.08);
        if(vSeasonVisible<=0.0) { gl_Position=vec4(2,2,2,1); return; }
        vec3 axis=normalize(b.xyz);
        vec3 side=normalize(cross(axis,abs(axis.y)>.95 ? vec3(1,0,0):vec3(0,1,0)));
        vec2 uv=vUV*2.0-1.0;
        p=a.xyz+(axis*uv.y*a.w+side*uv.x*a.w*b.w)*sqrt(vSeasonVisible)*uLeafScale;
        if(uComplexity>=3)p.y+=sin(uTime*3.0+d.x*37.0)*uWind*.045*uv.y;
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
        p=a.xyz+right*(vUV.x-.5)*width+vec3(0,vUV.y*b.x*1.32,0);
        if(uUseBakedLOD==1) {
            int age=vMaturity<.55 ? 0 : vMaturity<1.8 ? 1 : 2;
            vec3 frame=uLODFrames[age];
            p=a.xyz+right*(vUV.x-.5)*b.x*frame.x+vec3(0,mix(frame.y,frame.z,vUV.y)*b.x,0);
            vec3 toEye=uDepthOnly==1 ? uSunDirection : uEye-(uModel*vec4(a.xyz,1)).xyz;
            float azimuth=atan(toEye.x,toEye.z)/(2.0*PI);
            // Seed selects a stable quarter turn; each age has four actual views.
            int view=int(floor(fract(azimuth+d.x)*4.0+.5))%4;
            vLODLayer=float(age*4+view);
        }
        n=vec3(right.z,.35,-right.x);
        vProfile=b;
    } else if (uKind==6) {
        // A foliated shoot, built from the SAME quadratic twig as close needles.
        // Two bent strip segments share six vertices through the grid indices.
        float t=float(gl_VertexID/6+corners[gl_VertexID%6].y)/2.0;
        float across=float(corners[gl_VertexID%6].x)*2.0-1.0;
        vec3 center=curve(a.xyz,b.xyz,c.xyz,t);
        vec3 tangent=normalize(mix(b.xyz-a.xyz,c.xyz-b.xyz,t));
        vec3 eyeLocal=transpose(mat3(uModel))*(uEye-uModel[3].xyz);
        vec3 facing=uDepthOnly==1 ? normalize(transpose(mat3(uModel))*uSunDirection) : normalize(eyeLocal-center);
        vec3 widthAxis=cross(tangent,facing);
        if(dot(widthAxis,widthAxis)<.0001)
            widthAxis=cross(abs(facing.y)>.95 ? vec3(1,0,0) : vec3(0,1,0),facing);
        widthAxis=normalize(widthAxis);
        vec3 along=normalize(cross(facing,widthAxis));
        float shootLength=.5*(length(b.xyz-a.xyz)+length(c.xyz-b.xyz)+length(c.xyz-a.xyz));
        float radius=max(b.w*.92,a.w);
        float viewDepth=max(.05,-(uView*uModel*vec4(center,1)).z);
        bool orthographic=abs(uProjection[3][3]-1.0)<.001;
        float pixelWorld=2.0*(orthographic ? 1.0 : viewDepth)/(uProjection[1][1]*uViewportHeight);
        float rasterRadius=max(radius,min(pixelWorld*.6,radius*2.5));
        // Projected round caps keep the shoot visible even when looking along
        // its axis; the centreline and all attachment points stay in 3D.
        p=center+along*((t*2.0-1.0)*radius)+widthAxis*(across*rasterRadius);
        n=facing;vNeedleAxis=normalize(mat3(uModel)*along);
        float opticalDepth=float(uNeedlePairs*uNeedlesPerFascicle)*c.w*.32/max(shootLength,b.w);
        vShoot.xyz=vec3((shootLength+2.0*radius)/radius,
            1.0-exp(-3.0*opticalDepth),clamp(shootLength/max(c.w*2.0,.004),6.0,256.0));
        vSeasonVisible=uSeasonLeaf;vNeedleCoverage=radius/rasterRadius;
        vUV=vec2(across*.5+.5,t);
    } else if (uKind==5) {
        int needle=gl_VertexID/uNeedleVertices;
        int fascicle=needle/uNeedlesPerFascicle;
        float member=float(needle%uNeedlesPerFascicle);
        float id=float(fascicle)+d.x*173.0;
        if(uSeasonLeaf<.99999) vSeasonVisible=smoothstep(random1(id+member*19.0),random1(id+member*19.0)+.08,uSeasonLeaf*1.08);
        if(vSeasonVisible<=0.0) { gl_Position=vec4(2,2,2,1); return; }
        // A low-discrepancy prefix covers the whole shoot. Its positions do not
        // depend on the draw count: approaching adds needles without moving old ones.
        float t=.02+.96*fract(float(fascicle)*.61803398875+random1(d.x*173.0+2.0));
        vec3 tangent=normalize(mix(b.xyz-a.xyz,c.xyz-b.xyz,t));
        vec3 side=normalize(cross(tangent,abs(tangent.y)>.95?vec3(1,0,0):vec3(0,1,0)));
        vec3 up=cross(tangent,side);
        // Keep azimuth independent of the longitudinal low-discrepancy order.
        // Golden-angle azimuth is the complement of .61803398875: pairing the
        // two locks every needle to one turn of a helix and leaves bare strips.
        float angle=random1(id+11.0)*2.0*PI;
        if(vSpecies==7 || vSpecies==12) angle+=member*2.0*PI/float(uNeedlesPerFascicle);
        vec3 radial=side*cos(angle)+up*sin(angle);
        // Pines share a sheath in pairs; spruce is solitary; juniper has
        // three needles around each whorl. No CPU needle geometry is stored.
        vec3 base=curve(a.xyz,b.xyz,c.xyz,t)+radial*a.w*mix(1.0,.18,t);
        float spread=angle;
        if(uNeedlesPerFascicle==2) spread+=(member*2.0-1.0)*(.09+.13*random1(id+3.0));
        float forward=vSpecies==5 ? .20 : .45;
        vec3 direction=normalize(tangent*(forward+.30*random1(id+4.0))+
            side*cos(spread)*.90+up*sin(spread)*.90);
        // Thinning must not turn individual needles into metre-long ribbons.
        // Bound geometric compensation; represent the remaining density in
        // sample coverage below. Full-detail needles keep their physical size.
        float lodScale=min(sqrt(uNeedleScale),1.5);
        float physicalLength=b.w*(.80+.35*random1(id+member*7.0))*sqrt(vSeasonVisible)*lodScale;
        float viewDepth=max(.05,-(uView*uModel*vec4(base,1.0)).z);
        bool orthographic=abs(uProjection[3][3]-1.0)<.001;
        float pixelWorld=2.0*(orthographic ? 1.0 : viewDepth)/(uProjection[1][1]*uViewportHeight);
        // The pixel guard is bounded too, otherwise it multiplies LOD growth.
        // Keep the offline bake footprint unchanged for existing far atlases.
        float length=max(physicalLength,min(pixelWorld*1.5,physicalLength*(uBakeMode==1 ? 4.0 : 1.25)));
        vec3 tip=base+direction*length;
        vec3 bend=base+direction*length*.52+tangent*length*(vSpecies==5?.04:.16);
        vec2 shape=uNeedleVertices==3 ? shortNeedleVertices[gl_VertexID%3] : needleVertices[gl_VertexID%9];
        vec3 axis=normalize(mix(bend-base,tip-bend,shape.y));
        // Rotate the thin ribbon around its axis toward the camera, retaining
        // the actual 3D centerline and physical width at every viewing angle.
        vec3 eyeLocal=transpose(mat3(uModel))*(uEye-uModel[3].xyz);
        // A shadow sees cylindrical needles from the sun, independently of
        // rider/cinematic camera movement. The colour pass keeps its view facing.
        vec3 facing=uDepthOnly==1 ? normalize(transpose(mat3(uModel))*uSunDirection) : normalize(eyeLocal-base);
        vec3 widthAxis=cross(axis,facing);
        if(dot(widthAxis,widthAxis)<.00001) widthAxis=cross(axis,side);
        widthAxis=normalize(widthAxis);
        float physicalWidth=c.w*.5*lodScale*(uNeedleVertices==3 ? 1.29 : 1.0);
        float width=max(physicalWidth,min(pixelWorld*.6,length*.45));
        // Restore the area lost to thinning through coverage, not unbounded
        // geometry. Subtract the bounded size compensation already applied.
        // Raster guards still account for their projected area in both passes.
        float densityCoverage=uNeedleScale/(lodScale*lodScale);
        vNeedleCoverage=clamp(densityCoverage*(physicalWidth/width)*(physicalLength/length),0.0,1.0);
        width*=1.0-.48*shape.y;
        p=curve(base,bend,tip,shape.y)+widthAxis*shape.x*width;
        if(uComplexity>=3)p+=radial*sin(uTime*4.1+d.x*23.0+float(fascicle)) * uWind*.004*shape.y;
        if(uDepthOnly==0) {
            n=normalize(cross(widthAxis,axis));
            vNeedleAxis=normalize(mat3(uModel)*axis);
        }
        vUV=vec2(shape.x*.5+.5,shape.y);
        vPhase=random1(id+member*13.0);
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
        vec3 relative=mat3(uModel)*(p-(uKind==3 ? a.xyz : vec3(0)));
        vec3 sun=normalize(uSunDirection);
        vec3 right=cross(sun,abs(sun.y)>.95 ? vec3(1,0,0) : vec3(0,1,0));
        right=normalize(right);
        vShadowMask=vec2(dot(relative,right),dot(relative,cross(sun,right)));
    }
    if((uKind<3 || uKind==5 || uKind==6 || uKind==7) && vSpecies!=17 && vSpecies!=18) p=wind(p,d.x);
    vec4 world=uModel*vec4(p,1.0);
    vWorld=world.xyz;
    vNormal=uDepthOnly==0 ? normalize(mat3(uModel)*n) : vec3(0,1,0);
    vObject=p;
    gl_Position=uProjection*uView*world;
}
