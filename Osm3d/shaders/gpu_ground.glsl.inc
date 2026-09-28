'#version 430 core' + #10 +
'layout(local_size_x=8,local_size_y=8) in;' + #10 +
'layout(std430,binding=0) readonly buffer Coordinates {float positions[];};' + #10 +
'layout(std430,binding=1) readonly buffer Indices {uint indices[];};' + #10 +
'layout(std430,binding=2) readonly buffer Bins {uint bins[];};' + #10 +
'struct Hit {float top;float bottom;uint topId;uint bottomId;};' + #10 +
'layout(std430,binding=3) buffer Results {Hit heights[];};' + #10 +
'uniform vec4 uPatch,uBounds;' + #10 +
'uniform uint uStride,uFirstCurb,uTriangleBase,uBinCount;' + #10 +
'uniform int uInit,uCurbs;' + #10 +
'vec3 point(uint i){uint p=i*uStride;return vec3(positions[p],positions[p+1u],positions[p+2u]);}' + #10 +
'void main(){' + #10 +
'  uvec2 pixel=gl_GlobalInvocationID.xy;uint outId=pixel.y*256u+pixel.x;' + #10 +
'  vec2 q=uPatch.xy+(vec2(pixel)+vec2(0.5))*uPatch.z;' + #10 +
'  ivec2 cell=ivec2(floor((q-uBounds.xy)*uBounds.zw));' + #10 +
'  Hit result=uInit!=0?Hit(-1e30,1e30,0xffffffffu,0xffffffffu):heights[outId];' + #10 +
'  if(all(greaterThanEqual(cell,ivec2(0)))&&all(lessThan(cell,ivec2(int(uBinCount))))){' + #10 +
'    uint header=(uint(cell.y)*uBinCount+uint(cell.x))*2u;uint start=bins[header],count=bins[header+1u];' + #10 +
'    for(uint k=0u;k<count;++k){uint t=bins[start+k];' + #10 +
'      bool curb=t>=uFirstCurb;if(curb&&uCurbs==0)continue;' + #10 +
'      vec3 a=point(indices[t*3u]),b=point(indices[t*3u+1u]),c=point(indices[t*3u+2u]);' + #10 +
'      float det=(b.z-c.z)*(a.x-c.x)+(c.x-b.x)*(a.z-c.z);if(abs(det)<1e-9)continue;' + #10 +
'      float w0=((b.z-c.z)*(q.x-c.x)+(c.x-b.x)*(q.y-c.z))/det;' + #10 +
'      float w1=((c.z-a.z)*(q.x-c.x)+(a.x-c.x)*(q.y-c.z))/det;float w2=1.0-w0-w1;' + #10 +
'      float tolerance=curb?0.00001:0.001;if(min(w0,min(w1,w2)) < -tolerance)continue;' + #10 +
'      float y=a.y*w0+b.y*w1+c.y*w2;' + #10 +
'      if(y<result.bottom){result.bottom=y;result.bottomId=uTriangleBase+t;}' + #10 +
'      if(y<=uPatch.w+0.75&&y>result.top){result.top=y;result.topId=uTriangleBase+t;}' + #10 +
'    }' + #10 +
'  }heights[outId]=result;' + #10 +
'}' + #10
