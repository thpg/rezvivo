layout(std430,set=0,binding=4) readonly buffer Camera {
    mat4 invProjection;mat4 invView;vec4 sun;vec4 focus;vec4 options;vec4 depthRange;
    vec4 solarU;vec4 solarV;vec4 solarDisk[8];
};
layout(set=0,binding=6) uniform sampler2D cameraDepth;
layout(set=0,binding=10) uniform sampler2D cachedVisibility;
#ifndef SHADOW_DEPTH_FETCH
#define SHADOW_DEPTH_FETCH(p,size) texelFetch(cameraDepth,clamp(p,ivec2(0),size-1),0).r
#endif

bool reuseVisibility(ivec2 p,float depth,out float coverage) {
    if(depthRange.w<.5)return false;
    vec2 cached=texelFetch(cachedVisibility,p,0).rg;
    coverage=cached.r;
    // The world composite writes identical D32F and R32F depth. Live actors
    // only overwrite depth: an actor in front must never inherit world shade.
    return coverage>=0. && cached.g==depth;
}

vec4 eyeHomogeneous(ivec2 p,ivec2 size) {
    p=clamp(p,ivec2(0),size-1);
    float z=SHADOW_DEPTH_FETCH(p,size);
    // The CPU folds drFar into the inverse in double precision. z-1 avoids
    // cancelling the far-depth mantissa during reconstruction.
    vec2 xy=(vec2(p)+.5)/vec2(size)*2.-1.;
    return fma(invProjection[2],vec4(z-1.),
        fma(invProjection[0],vec4(xy.x),
        fma(invProjection[1],vec4(xy.y),invProjection[3])));
}
vec3 eyePoint(ivec2 p,ivec2 size) {
    vec4 eye=eyeHomogeneous(p,size);return eye.xyz/eye.w;
}
vec3 receiverNormal(ivec2 p,ivec2 size,vec3 eye) {
    // Reconstruct from the same surface on either side of a silhouette.
    vec3 a=eye-eyePoint(p-ivec2(1,0),size),b=eyePoint(p+ivec2(1,0),size)-eye;
    vec3 dx=abs(a.z)<abs(b.z)?a:b;
    a=eye-eyePoint(p-ivec2(0,1),size);b=eyePoint(p+ivec2(0,1),size)-eye;
    vec3 dy=abs(a.z)<abs(b.z)?a:b;
    vec3 n=cross(dx,dy);
    return normalize(dot(n,n)<1e-12?-eye:n);
}
float pixelWorldSize(vec3 eye,ivec2 size) {
    return max(1e-5,2.*abs(eye.z*invProjection[1][1])/float(size.y));
}
