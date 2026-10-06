// Bedrock in metres: a continuous 3D field, including vertical cliff faces.
// Every field has a 4096 m period. Tile origins can be reduced BEFORE adding
// interpolated local coordinates without breaking a seam far from the start.
float gcRockHash(ivec3 cell, uint mask) {
    uvec3 p=uvec3(cell)&uvec3(mask);
    uint n=p.x*0x9e3779b9u ^ p.y*0x85ebca6bu ^ p.z*0xc2b2ae35u;
    n^=n>>16u; n*=0x7feb352du; n^=n>>15u; n*=0x846ca68bu; n^=n>>16u;
    return float(n&65535u)/65535.0;
}
// Value and analytic gradient. No screen derivatives inside a material branch.
vec4 gcRockNoise(vec3 p,uint mask) {
    ivec3 c=ivec3(floor(p)); vec3 f=fract(p);
    vec3 u=f*f*(3.0-2.0*f), du=6.0*f*(1.0-f);
    float a=gcRockHash(c,mask), b=gcRockHash(c+ivec3(1,0,0),mask);
    float e=gcRockHash(c+ivec3(0,1,0),mask), d=gcRockHash(c+ivec3(1,1,0),mask);
    float g=gcRockHash(c+ivec3(0,0,1),mask), h=gcRockHash(c+ivec3(1,0,1),mask);
    float i=gcRockHash(c+ivec3(0,1,1),mask), j=gcRockHash(c+ivec3(1,1,1),mask);
    float z0=mix(mix(a,b,u.x),mix(e,d,u.x),u.y);
    float z1=mix(mix(g,h,u.x),mix(i,j,u.x),u.y);
    return vec4(mix(z0,z1,u.z),
        mix(mix(b-a,d-e,u.y),mix(h-g,j-i,u.y),u.z)*du.x,
        mix(mix(e-a,d-b,u.x),mix(i-g,j-h,u.x),u.z)*du.y,
        (z1-z0)*du.z);
}
// Fractured slabs: nearest-site cells produce angular faces and irregular
// joints. There is no rectangular brick grid or repeating horizontal stripe.
vec4 gcRockSlabs(vec2 p,float footprint) {
    ivec2 cell=ivec2(floor(p)); vec2 f=fract(p),v1=vec2(0),v2=vec2(0);
    float d1=1e10,d2=1e10,tone=0.5;
    for(int y=-1;y<=1;y++) for(int x=-1;x<=1;x++) {
        ivec2 c=cell+ivec2(x,y);
        float a=gcRockHash(ivec3(c,17),511u),b=gcRockHash(ivec3(c,53),511u);
        vec2 v=vec2(x,y)+0.12+0.76*vec2(a,b)-f; float d=dot(v,v);
        if(d<d1){d2=d1;v2=v1;d1=d;v1=v;tone=a;}
        else if(d<d2){d2=d;v2=v;}
    }
    float separation=max(length(v2-v1),0.0001);
    float edge=max(0.0,(d2-d1)/(2.0*separation));
    vec2 edgeGradient=(v1-v2)/separation;
    float width=max(0.12,footprint*0.6);
    float t=clamp((edge-0.012)/width,0.0,1.0);
    float bevel=t*t*(3.0-2.0*t),height=mix(0.16,0.30,tone);
    vec2 gradient=edgeGradient*(height*6.0*t*(1.0-t)/width);
    return vec4(height*bevel,gradient,mix(0.12,0.65+0.35*tone,bevel));
}
vec4 gcRockHeight(vec3 p,vec3 N,float footprint,out vec3 tones) {
    vec3 weights=pow(abs(N),vec3(6.0)); weights/=max(dot(weights,vec3(1)),0.0001);
    vec4 relief=vec4(0); float faceTone=0.0;
    if(weights.x>0.001){
        vec4 s=gcRockSlabs(vec2(p.z*0.125,p.y*0.25+p.z*0.125),footprint*0.25);
        relief+=weights.x*vec4(s.x,0.0,s.z*0.25,(s.y+s.z)*0.125);faceTone+=weights.x*s.w;
    }
    if(weights.y>0.001){
        vec4 s=gcRockSlabs(p.xz*0.125,footprint*0.125);
        relief+=weights.y*vec4(s.x,s.y*0.125,0.0,s.z*0.125);faceTone+=weights.y*s.w;
    }
    if(weights.z>0.001){
        vec4 s=gcRockSlabs(vec2(p.x*0.125,p.y*0.25-p.x*0.125),footprint*0.25);
        relief+=weights.z*vec4(s.x,(s.y-s.z)*0.125,s.z*0.25,0.0);faceTone+=weights.z*s.w;
    }
    vec4 mass=gcRockNoise(p*0.25,1023u); mass.yzw*=0.25;
    relief+=0.42*mass;
    float medium=1.0-smoothstep(0.4,2.0,footprint);
    relief=mix(vec4(0.22,0,0,0),relief,medium);
    float fine=1.0-smoothstep(0.025,0.12,footprint);
    float grain=0.5;
    if(fine>0.001) {
        vec4 n=gcRockNoise(p*8.0,32767u); n.yzw*=8.0;
        relief+=0.014*fine*n; grain=mix(0.5,n.x,fine);
    }
    tones=vec3(mass.x,mix(0.66,faceTone,medium),grain);
    return relief;
}
void gcRockTextureTap(vec3 p,vec3 dx,vec3 dy,vec3 T,vec3 B,float weight,
                      inout vec3 color,inout vec3 gradient,inout vec2 roughAO) {
    vec2 uv=vec2(dot(p,T),dot(p,B))*0.125;
    vec2 span=1.0/vec2(u_ground_grid_cols,u_ground_grid_rows);
    vec2 cell=vec2(float(10-(10/u_ground_grid_cols)*u_ground_grid_cols),float(10/u_ground_grid_cols))*span;
    float interior=1.0-2.0*u_ground_cell_inset;
    vec2 gx=vec2(dot(dx,T),dot(dx,B))*0.125*span*interior;
    vec2 gy=vec2(dot(dy,T),dot(dy,B))*0.125*span*interior;
    vec2 atlas=cell+(u_ground_cell_inset+fract(uv)*interior)*span;
    color+=weight*textureGrad(u_ground_atlas,atlas,gx,gy).rgb;
    vec3 n=textureGrad(u_ground_normal_atlas,atlas,gx,gy).xyz*2.0-1.0;
    gradient+=weight*(T*n.x+B*n.y)/max(n.z,0.35);
    vec4 m=textureGrad(u_ground_mask_atlas,atlas,gx,gy);
    roughAO+=weight*m.rb;
}
void gcRockMaterial(vec3 p,vec3 N,vec3 V,float footprint,float distanceToEye,vec3 dx,vec3 dy,
                    out vec3 albedo,out vec3 normal,out vec2 roughAO) {
    vec3 tones; vec4 h=gcRockHeight(p,N,footprint,tones);
    float viewDot=max(dot(N,V),0.0);
    float parallax=(1.0-smoothstep(14.0,55.0,distanceToEye))
                  *smoothstep(0.12,0.4,viewDot);
    if(parallax>0.001) {
        // Raised shelves have parallax, not a painted-on grey noise pattern.
        // Bound the ray offset; contact geometry and silhouettes stay intact.
        vec3 tangent=V-N*dot(N,V);
        p+=tangent*clamp((h.x-0.16)/max(viewDot,0.3),-0.25,0.25)*parallax;
        h=gcRockHeight(p,N,footprint,tones);
    }
    vec3 gradient=h.yzw-N*dot(N,h.yzw);
    vec3 texColor=vec3(0),texGradient=vec3(0);vec2 texSurface=vec2(0);
    vec3 weights=pow(abs(N),vec3(6));weights/=max(dot(weights,vec3(1)),0.0001);
    if(weights.x>0.001)gcRockTextureTap(p,dx,dy,vec3(0,0,-sign(N.x)),vec3(0,1,0),weights.x,texColor,texGradient,texSurface);
    if(weights.y>0.001)gcRockTextureTap(p,dx,dy,vec3(1,0,0),vec3(0,0,-sign(N.y)),weights.y,texColor,texGradient,texSurface);
    if(weights.z>0.001)gcRockTextureTap(p,dx,dy,vec3(sign(N.z),0,0),vec3(0,1,0),weights.z,texColor,texGradient,texSurface);
    texGradient-=N*dot(N,texGradient);
    normal=normalize(N-gradient*0.65+texGradient*1.1);
    float crevice=(1.0-smoothstep(0.08,0.30,tones.y));
    float stone=mix(0.90,1.12,tones.x)*(0.96+0.08*tones.z);
    albedo=texColor*stone*1.35*(1.0-0.08*crevice);
    roughAO=vec2(clamp(texSurface.x,0.78,0.98),texSurface.y*(1.0-0.12*crevice));
}
