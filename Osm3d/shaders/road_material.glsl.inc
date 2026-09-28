{ Shared GLSL source for cached and direct procedural road materials. }
'// Meter-space road material. No lighting, time, camera or cache-page seed.' + #10 +
'float rp_hash(vec2 p) {' + #10 +
'    vec3 q = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));' + #10 +
'    q += dot(q, q.yzx + 33.33);' + #10 +
'    return fract((q.x + q.y) * q.z);' + #10 +
'}' + #10 +
'float rp_noise(vec2 p) {' + #10 +
'    vec2 i = floor(p), f = fract(p);' + #10 +
'    f = f*f*(3.0-2.0*f);' + #10 +
'    return mix(mix(rp_hash(i), rp_hash(i+vec2(1,0)), f.x),' + #10 +
'               mix(rp_hash(i+vec2(0,1)), rp_hash(i+vec2(1,1)), f.x), f.y);' + #10 +
'}' + #10 +
'// The same value noise plus its analytical gradient. One set of four hashes' + #10 +
'// drives color, roughness and micro-height normals, without derivative taps.' + #10 +
'vec3 rp_noiseGradient(vec2 p) {' + #10 +
'    vec2 i=floor(p), f=fract(p);' + #10 +
'    vec2 u=f*f*(3.0-2.0*f), du=6.0*f*(1.0-f);' + #10 +
'    float a=rp_hash(i), b=rp_hash(i+vec2(1,0));' + #10 +
'    float c=rp_hash(i+vec2(0,1)), d=rp_hash(i+vec2(1,1));' + #10 +
'    return vec3(mix(mix(a,b,u.x),mix(c,d,u.x),u.y),' + #10 +
'                mix(b-a,d-c,u.y)*du.x, mix(c-a,d-b,u.x)*du.y);' + #10 +
'}' + #10 +
'// Artistic aggregate profiles by the existing road material class (24..29).' + #10 +
'// Components: cell size (m), albedo contrast, height range (m), roughness.' + #10 +
'// 0 is generic asphalt/old attributes; retain the residential default.' + #10 +
'vec4 rp_grainProfile(float kind) {' + #10 +
'    // Slightly oversized aggregate stays legible from the riding camera.' + #10 +
'    // Relief remains millimetric: compacted asphalt, not loose gravel.' + #10 +
'    if (kind<0.5) return vec4(0.026,0.145,0.00115,0.76);' + #10 +
'    if (kind<1.5) return vec4(0.042,0.170,0.00210,0.80); // major' + #10 +
'    if (kind<2.5) return vec4(0.034,0.155,0.00160,0.78); // secondary' + #10 +
'    if (kind<3.5) return vec4(0.026,0.145,0.00115,0.76); // residential' + #10 +
'    if (kind<4.5) return vec4(0.038,0.190,0.00250,0.84); // service' + #10 +
'    if (kind<5.5) return vec4(0.014,0.105,0.00045,0.75); // sidewalk' + #10 +
'    return vec4(0.018,0.115,0.00065,0.74);              // cycleway' + #10 +
'}' + #10 +
'// Integer cell keys avoid diagonal correlations and loss of hash precision' + #10 +
'// on long roads. Evaluate only local cell offsets when shaping the stones.' + #10 +
'vec3 rp_stoneKey(ivec2 cell,uint seed) {' + #10 +
'    uint h=uint(cell.x)*0x9e3779b9u ^ uint(cell.y)*0x85ebca6bu ^ seed;' + #10 +
'    h^=h>>16u; h*=0x7feb352du; h^=h>>15u; h*=0x846ca68bu; h^=h>>16u;' + #10 +
'    return vec3(float(h&1023u),float((h>>10u)&1023u),float((h>>20u)&1023u))/1023.0;' + #10 +
'}' + #10 +
'vec3 rp_gritGradient(vec2 p,uint seed) {' + #10 +
'    ivec2 c=ivec2(floor(p)); vec2 f=fract(p);' + #10 +
'    vec2 u=f*f*(3.0-2.0*f),du=6.0*f*(1.0-f);' + #10 +
'    float a=rp_stoneKey(c,seed).z,b=rp_stoneKey(c+ivec2(1,0),seed).z;' + #10 +
'    float e=rp_stoneKey(c+ivec2(0,1),seed).z,d=rp_stoneKey(c+ivec2(1,1),seed).z;' + #10 +
'    return vec3(mix(mix(a,b,u.x),mix(e,d,u.x),u.y),' + #10 +
'        mix(b-a,d-e,u.y)*du.x,mix(e-a,d-b,u.x)*du.y);' + #10 +
'}' + #10 +
'// Height, analytic gradient and albedo variation of compacted aggregate.' + #10 +
'// Jittered angular cells form individual stones, with bevels into bitumen.' + #10 +
'vec4 rp_aggregate(vec2 p,uint seed,float footprint,vec3 grit,out vec3 stoneTint) {' + #10 +
'    ivec2 cell=ivec2(floor(p)),stoneCell=cell;' + #10 +
'    vec2 f=fract(p),v1=vec2(0),v2=vec2(0);' + #10 +
'    float d1=1e10,d2=1e10; vec3 key=vec3(0.5);' + #10 +
'    for(int y=-1;y<=1;y++) for(int x=-1;x<=1;x++) {' + #10 +
'        vec3 k=rp_stoneKey(cell+ivec2(x,y),seed);' + #10 +
'        vec2 v=vec2(x,y)+0.05+0.90*k.xy-f;' + #10 +
'        // Weighted cells let large chips claim more space between fines.' + #10 +
'        float d=dot(v,v)-0.28*(k.z-0.5);' + #10 +
'        if(d<d1){d2=d1;v2=v1;d1=d;v1=v;key=k;stoneCell=cell+ivec2(x,y);}' + #10 +
'        else if(d<d2){d2=d;v2=v;}' + #10 +
'    }' + #10 +
'    float separation=max(length(v2-v1),0.0001);' + #10 +
'    float edge=max(0.0,(d2-d1)/(2.0*separation));' + #10 +
'    vec2 dg=(v1-v2)/separation;' + #10 +
'    // Stones do not tile the whole surface like paving blocks. Break up' + #10 +
'    // the polygon corners with differently sized, slightly rounded grains.' + #10 +
'    vec3 mineral=rp_stoneKey(stoneCell,seed^0xb5297a4du);' + #10 +
'    vec2 stretch=vec2(0.78)+mineral.xy*0.70;' + #10 +
'    float radial=max(length(v1*stretch),0.0001);' + #10 +
'    float radius=mix(0.26,0.76,sqrt(key.z));' + #10 +
'    float rim=radius-radial;' + #10 +
'    if(rim<edge){edge=rim;dg=v1*stretch*stretch/radial;}' + #10 +
'    edge+=(grit.x-0.5)*0.12; dg+=grit.yz*(0.12/0.35);' + #10 +
'    float width=max(0.17,footprint*0.80);' + #10 +
'    float t=clamp((edge-0.012)/width,0.0,1.0),bevel=t*t*(3.0-2.0*t);' + #10 +
'    vec2 tilt=(key.xy-0.5)*0.28;' + #10 +
'    float face=0.60+0.35*mineral.y-dot(v1,tilt);' + #10 +
'    vec2 gradient=face*(6.0*t*(1.0-t)/width)*dg+bevel*tilt;' + #10 +
'    float color=mix(-0.36,0.27+(mineral.y-0.5)*0.95,bevel)+0.025;' + #10 +
'    // Sparse warm granite, cool grey and pale mineral faces. Tint belongs' + #10 +
'    // to each stone, never to the bitumen or to screen-space noise.' + #10 +
'    stoneTint=vec3(0);' + #10 +
'    if(mineral.z<0.19) stoneTint=vec3(0.036,0.004,-0.023);' + #10 +
'    else if(mineral.z<0.37) stoneTint=vec3(-0.020,0.002,0.027);' + #10 +
'    else if(mineral.z>0.91) stoneTint=vec3(0.033,0.026,0.013);' + #10 +
'    stoneTint*=bevel*(0.65+0.35*mineral.x);' + #10 +
'    return vec4(bevel*face,gradient,color);' + #10 +
'}' + #10 +
'float rp_segment(vec2 p, vec2 a, vec2 b) {' + #10 +
'    vec2 v=b-a;' + #10 +
'    return length(p-a-v*clamp(dot(p-a,v)/max(dot(v,v),0.0001),0.0,1.0));' + #10 +
'}' + #10 +
'float rp_cover(float distance, float radius, float footprint) {' + #10 +
'    float a=max(footprint,0.002);' + #10 +
'    // Preserve the average coverage of subpixel cracks instead of flickering.' + #10 +
'    return clamp((radius+a-abs(distance))/(2.0*a),0.0,1.0)' + #10 +
'         * min(1.0, 2.0*radius/a);' + #10 +
'}' + #10 +
'float rp_smoothCover(float distance, float radius, float footprint) {' + #10 +
'    float a=max(footprint,0.002);' + #10 +
'    float t=clamp((radius+a-abs(distance))/(2.0*a),0.0,1.0);' + #10 +
'    return t*t*(3.0-2.0*t)*min(1.0,2.0*radius/a);' + #10 +
'}' + #10 +
'// Rounded cavity, not a flat bottom with two near-vertical cutout walls.' + #10 +
'// The quartic bowl has a continuous slope at both its centre and its rim.' + #10 +
'// Exact metric gradients avoid the 2x2-pixel stripes of screen derivatives.' + #10 +
'vec3 rp_cavityGradient(float distance, float radius, float footprint,' + #10 +
'                       vec2 distanceGradient, vec2 radiusGradient) {' + #10 +
'    float aa=max(footprint,0.001), r=radius+aa;' + #10 +
'    float t=clamp(abs(distance)/r,0.0,1.0), bowl=1.0-t*t;' + #10 +
'    float attenuation=radius/r;' + #10 +
'    vec2 dt=sign(distance)*distanceGradient/r-abs(distance)*radiusGradient/(r*r);' + #10 +
'    vec2 gradient=-4.0*t*bowl*attenuation*dt+bowl*bowl*aa/(r*r)*radiusGradient;' + #10 +
'    return vec3(bowl*bowl*attenuation,gradient);' + #10 +
'}' + #10 +
'// A fracture has irregular angular changes, not a pair of straight strokes.' + #10 +
'// Nodes and widths depend only on the feature key, never on a cache page.' + #10 +
'vec2 rp_fracturePoint(float i, float len, vec2 key) {' + #10 +
'    float t=i*0.1;' + #10 +
'    float jitter=(i>0.0 && i<10.0) ? (rp_hash(key+vec2(i,3.7))-0.5)*len*0.09 : 0.0;' + #10 +
'    float bend=(rp_hash(key+43.1)-0.5)*0.5*(4.0*t*(1.0-t));' + #10 +
'    return vec2((2.0*t-1.0)*len+jitter,' + #10 +
'                bend+(rp_hash(key+vec2(i,17.8))-0.5)*0.24);' + #10 +
'}' + #10 +
'void rp_fractureSegment(vec2 p, vec2 a, vec2 b, float wa, float wb, float footprint,' + #10 +
'                        inout vec3 core, inout vec3 shoulder) {' + #10 +
'    vec2 v=b-a;' + #10 +
'    float length2=max(dot(v,v),0.000001);' + #10 +
'    float t=clamp(dot(p-a,v)/length2,0.0,1.0);' + #10 +
'    vec2 delta=p-a-v*t;' + #10 +
'    float dist=length(delta), width=mix(wa,wb,t);' + #10 +
'    vec2 dg=delta/max(dist,0.000001);' + #10 +
'    vec2 wg=(t>0.0 && t<1.0) ? (wb-wa)*v/length2 : vec2(0);' + #10 +
'    vec3 c=rp_cavityGradient(dist,width,footprint,dg,wg);' + #10 +
'    vec3 s=rp_cavityGradient(dist,width*1.65,footprint,dg,wg*1.65);' + #10 +
'    if (c.x>core.x) core=c;' + #10 +
'    if (s.x>shoulder.x) shoulder=s;' + #10 +
'}' + #10 +
'vec2 rp_fracture(vec2 q, float len, float radius, vec2 key, float footprint,' + #10 +
'                 out vec4 gradient) {' + #10 +
'    gradient=vec4(0);' + #10 +
'    if (abs(q.x)>len+0.5+footprint || abs(q.y)>1.6+footprint) return vec2(0);' + #10 +
'    // Small-scale edge irregularity follows the same field for every branch,' + #10 +
'    // so their joins remain connected. Fade it once below a pixel.' + #10 +
'    float warpScale=0.026*(1.0-smoothstep(0.02,0.08,footprint));' + #10 +
'    vec3 warp=rp_noiseGradient(q*vec2(18,11)+key);' + #10 +
'    q.y+=(warp.x-0.5)*warpScale;' + #10 +
'    vec2 warpGradient=warp.yz*vec2(18,11)*warpScale;' + #10 +
'    vec3 core=vec3(0), shoulder=vec3(0);' + #10 +
'    vec2 a=rp_fracturePoint(0.0,len,key);' + #10 +
'    float wa=0.0007;' + #10 +
'    for (int i=1;i<=10;++i) {' + #10 +
'        float t=float(i)*0.1;' + #10 +
'        vec2 b=rp_fracturePoint(float(i),len,key);' + #10 +
'        float wb=0.0007+radius*(4.0*t*(1.0-t))*(0.75+0.5*rp_hash(key+vec2(float(i),61.4)));' + #10 +
'        rp_fractureSegment(q,a,b,wa,wb,footprint,core,shoulder);' + #10 +
'        a=b; wa=wb;' + #10 +
'    }' + #10 +
'    for (int branch=0;branch<2;++branch) {' + #10 +
'        if (branch==1 && rp_hash(key+77.3)<0.45) break;' + #10 +
'        float k=float(branch), h=rp_hash(key+vec2(k,83.2));' + #10 +
'        vec2 start=rp_fracturePoint(3.0+4.0*k,len,key);' + #10 +
'        vec2 dir=normalize(vec2((0.25+0.55*h)*(1.0-2.0*k),1.0-2.0*step(0.5,h)));' + #10 +
'        vec2 side=vec2(-dir.y,dir.x);' + #10 +
'        float branchLen=0.4+0.65*rp_hash(key+vec2(k,91.7));' + #10 +
'        a=start; wa=radius*0.45;' + #10 +
'        for (int i=1;i<=3;++i) {' + #10 +
'            float t=float(i)/3.0;' + #10 +
'            vec2 b=start+dir*(branchLen*t)+side*(rp_hash(key+vec2(float(i),k+104.2))-0.5)*0.14;' + #10 +
'            float wb=0.0005+radius*0.45*(1.0-t);' + #10 +
'            rp_fractureSegment(q,a,b,wa,wb,footprint,core,shoulder);' + #10 +
'            a=b; wa=wb;' + #10 +
'        }' + #10 +
'    }' + #10 +
'    // Chain rule through the small irregular edge warp.' + #10 +
'    gradient=vec4(core.yz+core.z*warpGradient,' + #10 +
'                  shoulder.yz+shoulder.z*warpGradient);' + #10 +
'    return vec2(core.x,shoulder.x);' + #10 +
'}' + #10 +
'// Exact lane bounds are shared with paint, including unequal OSM lane widths.' + #10 +
'uniform sampler2D rp_layout;' + #10 +
'vec4 rp_laneMeta(int profile, float lanes) {' + #10 +
'    vec4 meta=vec4(max(1.0,lanes),0,0,0);' + #10 +
'    if (profile>0) {' + #10 +
'        vec4 data=texelFetch(rp_layout,ivec2(0,profile),0);' + #10 +
'        if (data.x>0.5) meta=data;' + #10 +
'    }' + #10 +
'    return meta;' + #10 +
'}' + #10 +
'vec4 rp_laneInterval(float across, float roadWidth, int profile, vec4 meta) {' + #10 +
'  int count=max(1,int(meta.x+0.5));' + #10 +
'  float lateral=across+roadWidth*0.5;' + #10 +
'  float width=max(0.01,(roadWidth-2.0*meta.y)/float(count));' + #10 +
'  int idx=int(clamp(floor((lateral-meta.y)/width),0.0,float(count-1)));' + #10 +
'  float a=meta.y+float(idx)*width, b=a+width;' + #10 +
'  if(meta.w>0.5 && profile>0) {' + #10 +
'    // Upper bound on at most 32 lanes: five probes, including very wide roads.' + #10 +
'    int lo=0, hi=count-1;' + #10 +
'    for(int step=0;step<5;++step) {' + #10 +
'      if(lo>=hi) break;' + #10 +
'      int mid=(lo+hi+1)/2;' + #10 +
'      vec4 bounds=texelFetch(rp_layout,ivec2(1+mid/4,profile),0);' + #10 +
'      if(lateral>=bounds[mid%4]) lo=mid; else hi=mid-1;' + #10 +
'    }' + #10 +
'    idx=lo;' + #10 +
'    vec4 bounds=texelFetch(rp_layout,ivec2(1+idx/4,profile),0);' + #10 +
'    a=bounds[idx%4];' + #10 +
'    int next=idx+1;' + #10 +
'    if((next%4)==0) bounds=texelFetch(rp_layout,ivec2(1+next/4,profile),0);' + #10 +
'    b=bounds[next%4];' + #10 +
'  }' + #10 +
'    return vec4(a,b,float(idx),float(count));' + #10 +
'}' + #10 +
'// road = width / profile handle / motor-vehicle lane count (zero for areas' + #10 +
'// and paths). Decide once per feature, never mask a fracture per fragment.' + #10 +
'vec3 rp_crackDistribution(vec2 center, vec2 key, vec3 road) {' + #10 +
'    float angle=(rp_hash(key+8.3)-0.5)*3.14159265;' + #10 +
'    float probability=0.41/0.73;' + #10 +
'    if (road.z>0.5) {' + #10 +
'        vec4 lane=rp_laneInterval(center.y,road.x,int(road.y),rp_laneMeta(int(road.y),road.z));' + #10 +
'        float t=(center.y+road.x*0.5-lane.x)/max(lane.y-lane.x,0.01);' + #10 +
'        float central=1.0-smoothstep(0.05,0.5,abs(t-0.5));' + #10 +
'        probability=0.18+0.72*central;' + #10 +
'        // Most main fractures run along the lane, with some diagonal and' + #10 +
'        // transverse ones left. Branches retain their angular broken shape.' + #10 +
'        if (rp_hash(key+127.9)<0.80) angle*=0.22;' + #10 +
'    }' + #10 +
'    return vec3(cos(angle),sin(angle),probability);' + #10 +
'}' + #10 +
'float rp_motorLanes(vec4 style) {' + #10 +
'    return floor(mod(style.z,16.0)*0.5)<4.5 ? style.x+style.y : 0.0;' + #10 +
'}' + #10 +
'// Broad, faint rubber accumulation with independently varying wheel tracks.' + #10 +
'// No physical rut displacement: this is dirt and slight surface polishing.' + #10 +
'float rp_tireDirt(vec2 p, float width, vec4 style, vec2 footprint, vec4 lane) {' + #10 +
'    if (rp_motorLanes(style)<0.5) return 0.0;' + #10 +
'    float laneWidth=max(lane.y-lane.x,0.01);' + #10 +
'    float lateral=p.y+width*0.5;' + #10 +
'    float halfTrack=min(0.78,laneWidth*0.22);' + #10 +
'    float center=(lane.x+lane.y)*0.5;' + #10 +
'    vec2 salt=vec2(mod(style.w,251.0),floor(style.w/251.0));' + #10 +
'    float drift=(rp_noise(vec2(p.x*0.08,center)+salt)-0.5)*0.10;' + #10 +
'    float d=abs(abs(lateral-center-drift)-halfTrack);' + #10 +
'    float spread=max(0.12,min(0.24,laneWidth*0.07));' + #10 +
'    float wheels=exp(-pow(d/spread,2.0));' + #10 +
'    float density=rp_noise(p*vec2(0.19,1.7)+salt+163.4);' + #10 +
'    float streak=(rp_noise(p*vec2(0.8,24.0)+salt+191.7)-0.5)*' + #10 +
'        (1.0-smoothstep(0.02,0.08,footprint.y));' + #10 +
'    float fade=1.0-smoothstep(spread*0.5,spread*3.0,footprint.y);' + #10 +
'    return wheels*(0.025+0.045*density+0.012*streak)*fade;' + #10 +
'}' + #10 +
'// Patch probability, fracture density multiplier, width and relief strength.' + #10 +
'// Zero preserves the old untagged cache; 1..5 are explicit condition levels.' + #10 +
'vec4 rp_damageProfile(float condition) {' + #10 +
'    if (condition<0.5) return vec4(0.27,1.0,1.0,1.0);' + #10 +
'    if (condition<1.5) return vec4(0.0,0.008,0.40,0.25);' + #10 +
'    if (condition<2.5) return vec4(0.045,0.25,0.65,0.50);' + #10 +
'    if (condition<3.5) return vec4(0.16,0.70,0.85,0.85);' + #10 +
'    if (condition<4.5) return vec4(0.30,1.30,1.15,1.20);' + #10 +
'    return vec4(0.42,1.90,1.40,1.80);' + #10 +
'}' + #10 +
'// Returns sRGB albedo/roughness and a height in meters / cavity / repair mask.' + #10 +
'void rp_surfaceGradient(vec2 p, float seed, float footprint, vec3 road, float condition,' + #10 +
'                        out vec4 colorRough, out vec3 relief, out vec2 heightGradient) {' + #10 +
'    vec4 damage=rp_damageProfile(condition);' + #10 +
'    vec2 salt=vec2(mod(seed,251.0),floor(seed/251.0));' + #10 +
'    uint materialSeed=uint(seed)^0x436bf8adu;' + #10 +
'    vec3 ageNoise=rp_gritGradient(p*0.027,materialSeed);' + #10 +
'    vec3 mottleNoise=rp_gritGradient(p*0.24,materialSeed^0x91e10da5u);' + #10 +
'    float age=ageNoise.x, mottling=mottleNoise.x;' + #10 +
'    // Different mixes and weathering form broad continuous regions, while' + #10 +
'    // fine dust and binder stains follow smaller irregular patches. These' + #10 +
'    // fields are baked into existing pages; neither page nor tile is a seed.' + #10 +
'    // Integer hashes keep the same distribution on roads far from the start.' + #10 +
'    float batch=rp_gritGradient(p*vec2(0.042,0.090)+' + #10 +
'        vec2(mottling*0.8,age*0.6),materialSeed^0xd1b54a35u).x;' + #10 +
'    float wear=condition<0.5 ? 0.45 : clamp((condition-1.0)*0.25,0.0,1.0);' + #10 +
'    float binder=smoothstep(0.49,0.82,batch);' + #10 +
'    float weathered=smoothstep(0.42,0.78,age)*(1.0-0.65*binder);' + #10 +
'    float stain=smoothstep(0.60,0.79,mottling+0.20*(batch-0.5))*(0.24+0.76*wear);' + #10 +
'    float dust=smoothstep(0.61,0.84,1.0-mottling+0.12*(age-0.5))*weathered*(0.15+0.85*wear);' + #10 +
'    float tone=0.265+0.038*age+0.022*(mottling-0.5)' + #10 +
'        +0.042*weathered-0.029*binder-0.045*stain+0.016*dust;' + #10 +
'    float height=0.0007*(mottling-0.5), cavity=0.0, repair=0.0;' + #10 +
'    heightGradient=0.0007*0.24*mottleNoise.yz;' + #10 +
'    float rough=0.865+0.042*weathered-0.070*binder-0.042*stain+0.030*dust;' + #10 +
'    // One bounded, jittered feature per 6-meter cell. Inspect neighbours so' + #10 +
'    // features continue through cell/page boundaries; no repeated tile motif.' + #10 +
'    vec2 cell=floor(p/6.0);' + #10 +
'    for (int y=-1; y<=1; ++y) for (int x=-1; x<=1; ++x) {' + #10 +
'        vec2 c=cell+vec2(float(x),float(y));' + #10 +
'        float h=rp_hash(c+salt), h2=rp_hash(c+salt+19.7);' + #10 +
'        vec2 center=(c+0.2+0.6*vec2(h2,rp_hash(c+salt+71.1)))*6.0;' + #10 +
'        // Fractures may start anywhere in a cell, including its boundaries:' + #10 +
'        // a restricted jitter would leave a clean strip around the road axis.' + #10 +
'        if (h>=damage.x) center=(c+vec2(h2,rp_hash(c+salt+71.1)))*6.0;' + #10 +
'        vec2 q=p-center;' + #10 +
'        // Sparse patches, with their size and orientation fixed in meters.' + #10 +
'        if (h < damage.x) {' + #10 +
'            float angle=(h2-0.5)*0.55;' + #10 +
'            float sn=sin(angle), cs=cos(angle);' + #10 +
'            vec2 r=mat2(cs,-sn,sn,cs)*q;' + #10 +
'            vec2 halfSize=vec2(0.35+1.5*h2,0.3+1.15*rp_hash(c+salt+5.2));' + #10 +
'            vec2 box=abs(r)-halfSize;' + #10 +
'            float edge=max(box.x,box.y);' + #10 +
'            vec2 eg=box.x>box.y ? vec2(sign(r.x),0) : vec2(0,sign(r.y));' + #10 +
'            float sx=sin(r.x*8.0+h*60.0), sy=sin(r.y*7.0+h2*20.0);' + #10 +
'            edge+=0.055*sx*sy;' + #10 +
'            eg+=0.055*vec2(8.0*cos(r.x*8.0+h*60.0)*sy,7.0*sx*cos(r.y*7.0+h2*20.0));' + #10 +
'            eg=vec2(cs*eg.x-sn*eg.y,sn*eg.x+cs*eg.y);' + #10 +
'            float t=clamp((edge+footprint)/(2.0*footprint+0.015),0.0,1.0);' + #10 +
'            float cover=1.0-t*t*(3.0-2.0*t);' + #10 +
'            float seam=rp_smoothCover(edge,0.026,footprint);' + #10 +
'            float bevel=0.025+footprint;' + #10 +
'            float ht=clamp((edge+bevel)/(2.0*bevel),0.0,1.0);' + #10 +
'            float raised=1.0-ht*ht*(3.0-2.0*ht);' + #10 +
'            vec2 raisedGradient=-6.0*ht*(1.0-ht)/(2.0*bevel)*eg;' + #10 +
'            vec3 joint=rp_cavityGradient(edge,0.045,footprint,eg,vec2(0));' + #10 +
'            float patchTone=0.206+0.052*h2+0.016*(mottling-0.5);' + #10 +
'            tone=mix(tone,patchTone,cover);' + #10 +
'            tone-=seam*0.033;' + #10 +
'            // Denser repair asphalt has a broader sheen, varied per patch.' + #10 +
'            rough=mix(rough,0.72+0.04*h2,cover);' + #10 +
'            height+=(raised*(0.010+0.006*h2)-joint.x*0.0035)*damage.w;' + #10 +
'            heightGradient+=(raisedGradient*(0.010+0.006*h2)-joint.yz*0.0035)*damage.w;' + #10 +
'            cavity=max(cavity,joint.x*0.30);' + #10 +
'            // Alternate old repaired/repainted and newer unpainted repairs.' + #10 +
'            repair=max(repair,cover*step(0.11,h));' + #10 +
'        } else {' + #10 +
'            // Reject distant cells before looking up lane bounds. The main' + #10 +
'            // line and its branches fit inside this metric radius.' + #10 +
'            if (max(abs(q.x),abs(q.y))>3.1+footprint) continue;' + #10 +
'            vec3 distribution=rp_crackDistribution(center,c+salt,road);' + #10 +
'            if ((h-damage.x)/(1.0-damage.x)>=distribution.z*damage.y) continue;' + #10 +
'            vec2 dir=distribution.xy;' + #10 +
'            vec2 side=vec2(-dir.y,dir.x);' + #10 +
'            float len=0.6+1.45*rp_hash(c+salt+3.1);' + #10 +
'            vec4 crackGradient;' + #10 +
'            vec2 crack=rp_fracture(vec2(dot(q,dir),dot(q,side)),len,(0.009+0.020*h2)*damage.z,c+salt,footprint,crackGradient);' + #10 +
'            tone-=crack.x*0.13+crack.y*0.025;' + #10 +
'            height-=(crack.x*(0.012+0.010*age)+crack.y*0.003)*damage.w;' + #10 +
'            vec2 slope=crackGradient.xy*(0.012+0.010*age)+crackGradient.zw*0.003;' + #10 +
'            heightGradient-=(dir*slope.x+side*slope.y+crack.x*0.010*0.027*ageNoise.yz)*damage.w;' + #10 +
'            cavity=max(cavity,crack.x*0.65+crack.y*0.10);' + #10 +
'        }' + #10 +
'    }' + #10 +
'    vec3 tint=vec3(1.015,1.0,0.985)+weathered*vec3(0.014,0.006,-0.008);' + #10 +
'    colorRough=vec4(vec3(clamp(tone,0.12,0.5))*tint+dust*vec3(0.021,0.014,0.005),rough);' + #10 +
'    relief=vec3(height,cavity,repair);' + #10 +
'}' + #10 +
'// Poured road concrete: cement paste, slab joints and occasional fractures.' + #10 +
'// The page, direct fallback and close detail share these metric features.' + #10 +
'void rp_concreteGradient(vec2 p, float seed, float footprint, vec3 road, float condition,' + #10 +
'                         out vec4 colorRough, out vec3 relief, out vec2 heightGradient) {' + #10 +
'    uint keySeed=uint(seed)^0x53a9b4d1u;' + #10 +
'    vec3 roadKey=rp_stoneKey(ivec2(0),keySeed);' + #10 +
'    float pitch=4.1+1.1*roadKey.x, phase=roadKey.y*pitch;' + #10 +
'    float panels=max(1.0,floor(road.x/3.5+0.5)), panelWidth=road.x/panels;' + #10 +
'    vec2 grid=vec2((p.x+phase)/pitch,(p.y+road.x*0.5)/panelWidth);' + #10 +
'    ivec2 slab=ivec2(floor(grid));' + #10 +
'    vec3 key=rp_stoneKey(slab,keySeed);' + #10 +
'    vec3 mottle=rp_gritGradient(p*0.21,keySeed^0x713e85a9u);' + #10 +
'    vec3 stain=rp_gritGradient(p*vec2(0.62,0.39),keySeed^0x9b4750d3u);' + #10 +
'    float wear=condition<0.5 ? 0.35 : clamp((condition-1.0)*0.25,0.0,1.0);' + #10 +
'    // Small casting differences follow real slabs, not virtual-texture pages.' + #10 +
'    float slabTone=(key.y-0.5)*0.025*(1.0-smoothstep(0.15,0.8,footprint));' + #10 +
'    float tone=0.45+0.045*mottle.x+0.025*(stain.x-0.5)+slabTone;' + #10 +
'    float height=0.0012*(mottle.x-0.5);' + #10 +
'    heightGradient=0.0012*0.21*mottle.yz;' + #10 +
'    float along=fract(grid.x)*pitch;' + #10 +
'    if(along>pitch*0.5) along-=pitch;' + #10 +
'    vec3 joint=rp_cavityGradient(along,0.008,footprint,vec2(1,0),vec2(0));' + #10 +
'    float jointCover=rp_smoothCover(along,0.008,footprint);' + #10 +
'    float halo=rp_smoothCover(along,0.035,footprint);' + #10 +
'    // A longitudinal pour joint stays inside the road and scales with width.' + #10 +
'    if(panels>1.5) {' + #10 +
'        float boundary=clamp(floor(grid.y+0.5),1.0,panels-1.0);' + #10 +
'        float across=p.y+road.x*0.5-boundary*panelWidth;' + #10 +
'        vec3 crossJoint=rp_cavityGradient(across,0.007,footprint,vec2(0,1),vec2(0));' + #10 +
'        if(crossJoint.x>joint.x) joint=crossJoint;' + #10 +
'        jointCover=max(jointCover,rp_smoothCover(across,0.007,footprint));' + #10 +
'        halo=max(halo,rp_smoothCover(across,0.030,footprint));' + #10 +
'    }' + #10 +
'    tone-=0.17*jointCover+(0.016+0.020*wear)*halo;' + #10 +
'    height-=0.005*joint.x; heightGradient-=0.005*joint.yz;' + #10 +
'    float cavity=joint.x*0.38;' + #10 +
'    float chance=condition<0.5 ? 0.075 : max(0.0,condition-1.0)*0.05;' + #10 +
'    if(key.z<chance) {' + #10 +
'        vec2 center=vec2((float(slab.x)+0.5)*pitch-phase,' + #10 +
'                         (float(slab.y)+0.5)*panelWidth-road.x*0.5);' + #10 +
'        vec2 q=p-center, dir=normalize(vec2((key.x-0.5)*0.7,1.0));' + #10 +
'        vec2 side=vec2(-dir.y,dir.x); vec4 slope;' + #10 +
'        vec2 crack=rp_fracture(vec2(dot(q,dir),dot(q,side)),' + #10 +
'            min(1.45,min(panelWidth,pitch)*0.29),0.002+0.004*wear,' + #10 +
'            key.xy*123.0,footprint,slope);' + #10 +
'        float depth=0.003+0.005*wear;' + #10 +
'        tone-=0.18*crack.x+0.015*crack.y; height-=depth*crack.x;' + #10 +
'        heightGradient-=depth*(dir*slope.x+side*slope.y);' + #10 +
'        cavity=max(cavity,crack.x*0.5);' + #10 +
'    }' + #10 +
'    colorRough=vec4(vec3(clamp(tone,0.18,0.62))*vec3(1.015,1.005,0.977),' + #10 +
'        0.89+0.035*stain.x+0.015*wear);' + #10 +
'    relief=vec3(height,cavity,0);' + #10 +
'}' + #10 +
'void rp_roadGradient(vec2 p, float seed, float footprint, vec3 road,' + #10 +
'                     float condition, float concrete,' + #10 +
'                     out vec4 colorRough, out vec3 relief, out vec2 gradient) {' + #10 +
'    if(concrete>0.5) rp_concreteGradient(p,seed,footprint,road,condition,colorRough,relief,gradient);' + #10 +
'    else rp_surfaceGradient(p,seed,footprint,road,condition,colorRough,relief,gradient);' + #10 +
'}' + #10 +
'void rp_surface(vec2 p, float seed, float footprint, vec3 road, float condition,' + #10 +
'                out vec4 colorRough, out vec3 relief) {' + #10 +
'    vec2 gradient;' + #10 +
'    rp_surfaceGradient(p,seed,footprint,road,condition,colorRough,relief,gradient);' + #10 +
'}' + #10 +
'// Normal in the original road UV frame: X across road, Y along road.' + #10 +
'vec2 rp_gradientNormal(vec2 gradient) {' + #10 +
'    return normalize(vec3(-gradient.yx,1.0)).xy;' + #10 +
'}' + #10 +
'// Exact average of a repeated dash over the longitudinal pixel footprint.' + #10 +
'float rp_dashIntegral(float s, float period, float dash) {' + #10 +
'    return floor(s/period)*dash+min(mod(s,period),dash);' + #10 +
'}' + #10 +
'float rp_dash(float s, float footprint) {' + #10 +
'    float a=max(footprint,0.005);' + #10 +
'    return clamp((rp_dashIntegral(s+a,9.0,3.0)-rp_dashIntegral(s-a,9.0,3.0))/(2.0*a),0.0,1.0);' + #10 +
'}' + #10 +
'// A 26 cm concrete kerb: top, rounded inner bevel, mortar joints and a' + #10 +
'// narrow contact groove. Carrier UV: x along edge, y toward the carriageway.' + #10 +
'// Analytical filtering keeps the centimetre details stable at a distance.' + #10 +
'void rp_curb(vec2 p, vec2 footprint, out vec4 colorRough, out vec4 normalData) {' + #10 +
'    float aa=max(footprint.y,0.001);' + #10 +
'    float block=floor(p.x);' + #10 +
'    float joint=rp_cover(min(fract(p.x),1.0-fract(p.x)),0.018,max(footprint.x,0.001));' + #10 +
'    float variation=rp_hash(vec2(block,17.0));' + #10 +
'    // Unfold the cross-section for isotropic concrete detail on the tall' + #10 +
'    // faces: 4 mm in plan covers 12-15 cm vertically after displacement.' + #10 +
'    float faceScale=1.0, surfaceT;' + #10 +
'    if (p.y<0.004) { faceScale=37.5; surfaceT=p.y*faceScale; }' + #10 +
'    else if (p.y<0.19) surfaceT=0.15+p.y-0.004;' + #10 +
'    else if (p.y<0.22) { faceScale=1.414214; surfaceT=0.336+(p.y-0.19)*faceScale; }' + #10 +
'    else if (p.y<0.224) { faceScale=30.0; surfaceT=0.378426+(p.y-0.22)*faceScale; }' + #10 +
'    else surfaceT=0.498426+p.y-0.224;' + #10 +
'    float grain=(rp_noise(vec2(p.x,surfaceT)*92.0)-0.5)*' + #10 +
'        (1.0-smoothstep(0.004,0.02,max(footprint.x,footprint.y*faceScale)));' + #10 +
'    float bevel=smoothstep(0.19-aa,0.22+aa,p.y);' + #10 +
'    float groove=smoothstep(0.235-aa,0.25+aa,p.y);' + #10 +
'    vec3 concrete=vec3(0.56,0.555,0.535)+(variation-0.5)*0.11+grain*0.05;' + #10 +
'    // Wider dark joints and a recessed inner face strengthen the apparent height.' + #10 +
'    concrete*=1.0-0.58*joint;' + #10 +
'    concrete*=1.0-0.16*bevel;' + #10 +
'    colorRough=vec4(mix(concrete,vec3(0.15,0.145,0.135),groove),0.90);' + #10 +
'    // The raised carrier provides the true face normal. Keep micro-normal' + #10 +
'    // neutral instead of applying the former fake bevel a second time.' + #10 +
'    normalData=vec4(0.5,0.5,1.0-0.38*groove-0.40*joint,0.0);' + #10 +
'}' + #10 +
'void rp_finish(vec2 p, float width, vec4 style, vec2 footprint, vec4 lane,' + #10 +
'               inout vec4 colorRough, inout vec4 normalData) {' + #10 +
'    float seed=style.w;' + #10 +
'    vec2 salt=vec2(mod(seed,251.0),floor(seed/251.0));' + #10 +
'    // Millimeter detail is evaluated at its own metric scale and filtered out' + #10 +
'    // smoothly once smaller than a pixel, independently of the page mip.' + #10 +
'    // style.z packs marking + 2*grain class + 16*condition + 128*concrete.' + #10 +
'    // including the direct fallback, so pages never acquire a different grain.' + #10 +
'    bool concrete=style.z>=128.0;' + #10 +
'    vec4 aggregate=concrete ? vec4(0.016,0.062,0.00042,0.91)' + #10 +
'        : rp_grainProfile(floor(mod(style.z,16.0)*0.5));' + #10 +
'    if(!concrete) {' + #10 +
'        // The cached roughness also describes aggregate exposure: fresh' + #10 +
'        // binder/repairs fill the gaps, weathered stretches expose the chips.' + #10 +
'        // Keep stone coordinates fixed, varying relief and contrast only.' + #10 +
'        float exposed=clamp((colorRough.a-0.75)/0.17,0.0,1.0);' + #10 +
'        aggregate.y*=mix(0.78,1.13,exposed);' + #10 +
'        aggregate.z*=mix(0.70,1.12,exposed);' + #10 +
'    }' + #10 +
'    float marked=mod(style.z,2.0);' + #10 +
'    float grainFade=1.0-smoothstep(0.45,2.0,' + #10 +
'        max(footprint.x,footprint.y)/aggregate.x);' + #10 +
'    if(!concrete) colorRough.a=clamp(colorRough.a+(aggregate.w-0.88),0.55,0.99);' + #10 +
'    if (grainFade>0.001) {' + #10 +
'        float fineFade=1.0-smoothstep(0.35,1.4,' + #10 +
'            max(footprint.x,footprint.y)/(aggregate.x*0.35));' + #10 +
'        vec3 grit=vec3(0.5,0,0);' + #10 +
'        if (fineFade>0.001) {' + #10 +
'            grit=rp_gritGradient(p/(aggregate.x*0.35),uint(seed)^0x68bc21ebu);' + #10 +
'            grit=mix(vec3(0.5,0,0),grit,fineFade);' + #10 +
'        }' + #10 +
'        vec3 stoneTint;' + #10 +
'        vec4 grain=rp_aggregate(p/aggregate.x,uint(seed),' + #10 +
'            max(footprint.x,footprint.y)/aggregate.x,grit,stoneTint);' + #10 +
'        // The smaller aggregate also breaks up the faces of larger stones.' + #10 +
'        vec2 slope=grain.yz*0.80+grit.yz*(0.65/0.35);' + #10 +
'        colorRough.rgb+=((grain.w*0.95+(grit.x-0.5)*0.40)*aggregate.y+stoneTint*(concrete ? 0.3 : 1.0))*grainFade;' + #10 +
'        colorRough.a=clamp(colorRough.a+(0.5-grain.x)*0.10*grainFade,0.55,0.99);' + #10 +
'        // Texture tangent X is across the road, Y along; p is along/across.' + #10 +
'        vec2 microSlope=-slope.yx*(aggregate.z/aggregate.x);' + #10 +
'        normalData.xy=clamp(normalData.xy+microSlope*0.5*grainFade,vec2(0.001),vec2(0.999));' + #10 +
'        if(concrete) {' + #10 +
'            // Sparse pinholes in the cement paste, with analytic bowl normals.' + #10 +
'            float t=clamp((grit.x-0.64)/0.27,0.0,1.0), pore=t*t*(3.0-2.0*t);' + #10 +
'            vec2 poreSlope=grit.zy*(6.0*t*(1.0-t)/0.27)*(0.00055/(aggregate.x*0.35));' + #10 +
'            colorRough.rgb-=pore*0.085*grainFade;' + #10 +
'            normalData.xy=clamp(normalData.xy+poreSlope*0.5*grainFade,vec2(0.001),vec2(0.999));' + #10 +
'            normalData.z*=1.0-pore*0.12*grainFade;' + #10 +
'        }' + #10 +
'    }' + #10 +
'    float lateral=p.y+width*0.5;' + #10 +
'    float dirt=rp_tireDirt(p,width,style,footprint,lane);' + #10 +
'    colorRough.rgb*=1.0-dirt;' + #10 +
'    // Wheel polishing follows the existing irregular tyre accumulation.' + #10 +
'    colorRough.a=clamp(colorRough.a-dirt*1.6,0.55,0.99);' + #10 +
'    if (marked>0.5 && width>=3.0) {' + #10 +
'        float pattern=rp_dash(p.x+mod(seed,9.0),footprint.x);' + #10 +
'        float left=rp_cover(lateral-lane.x,0.06,footprint.y)*(lane.z>1.5 ? 1.0 : pattern);' + #10 +
'        float right=rp_cover(lateral-lane.y,0.06,footprint.y)*(lane.w>1.5 ? 1.0 : pattern);' + #10 +
'        float line=max(left,right);' + #10 +
'        float wear=0.90+0.10*rp_noise(p*3.5+salt);' + #10 +
'        line *= wear*(1.0-normalData.w);' + #10 +
'        colorRough.rgb=mix(colorRough.rgb,vec3(0.78,0.775,0.735),line);' + #10 +
'        colorRough.a=mix(colorRough.a,0.72,line);' + #10 +
'        normalData.xy=mix(normalData.xy,vec2(0.5),line*0.55);' + #10 +
'    }' + #10 +
'}' + #10 +
'' + #10 +
'// Fragment-only edging for footway ribbons. All dimensions are meters.' + #10 +
'// Returns coverage, transverse normal slope and contact occlusion.' + #10 +
'vec3 rp_sidewalkCurb(float along, float edge, vec2 footprint, out vec3 concrete) {' + #10 +
'    float aa=max(footprint.y,0.001);' + #10 +
'    float band=1.0-smoothstep(0.10-aa,0.10+aa,edge);' + #10 +
'    float joint=rp_cover(min(fract(along),1.0-fract(along)),0.006,max(footprint.x,0.001));' + #10 +
'    float bevel=1.0-smoothstep(0.012-aa,0.025+aa,edge);' + #10 +
'    float inner=smoothstep(0.072-aa,0.09+aa,edge);' + #10 +
'    float detail=1.0-smoothstep(0.025,0.15,aa);' + #10 +
'    concrete=vec3(0.58,0.575,0.555)*(1.0-0.32*joint-0.12*inner);' + #10 +
'    float slope=(-0.9*bevel+0.35*inner)*detail;' + #10 +
'    return vec3(band,slope,1.0-0.22*joint-0.20*inner);' + #10 +
'}' + #10
