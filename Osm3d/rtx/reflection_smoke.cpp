// Deterministic, hidden OpenGL/Vulkan reflection and interop regression.
#include <windows.h>
#include <GL/gl.h>
#include <array>
#include <vector>
#include <cstdio>
#include <cstdint>
#include <cmath>
#include <algorithm>
struct Surface {float n[4],c[4],uv[12];};
struct Camera {float p[16],v[16],sun[4],h[4],z[4],range[4];};
struct Zone {float o[4],u[4],v[4],r[4];};
int wmain(int argc,wchar_t** argv){
 if(argc!=4)return 2;
 WNDCLASSW wc{};wc.lpfnWndProc=DefWindowProcW;wc.hInstance=GetModuleHandle(nullptr);wc.lpszClassName=L"RezvivoReflectionTest";wc.style=CS_OWNDC;RegisterClassW(&wc);
 HWND window=CreateWindowW(wc.lpszClassName,L"",WS_POPUP,0,0,2,2,nullptr,nullptr,wc.hInstance,nullptr);HDC dc=GetDC(window);
 PIXELFORMATDESCRIPTOR pf{};pf.nSize=sizeof(pf);pf.nVersion=1;pf.dwFlags=PFD_DRAW_TO_WINDOW|PFD_SUPPORT_OPENGL|PFD_DOUBLEBUFFER;pf.iPixelType=PFD_TYPE_RGBA;pf.cColorBits=32;pf.cDepthBits=24;
 SetPixelFormat(dc,ChoosePixelFormat(dc,&pf),&pf);HGLRC rc=wglCreateContext(dc);wglMakeCurrent(dc,rc);
 HMODULE lib=LoadLibraryW(argv[1]);if(!lib)return 3;
#define FN(n,ret,...) auto n=reinterpret_cast<ret(__cdecl*)(__VA_ARGS__)>(GetProcAddress(lib,#n));if(!n)return 4
 FN(rzrt_create,void*,const wchar_t*,uint32_t,uint32_t,uint32_t);FN(rzrt_destroy,void,void*);FN(rzrt_error,const char*);
 FN(rzrt_scene_materials,int,void*,const float*,uint32_t,const void*,uint32_t,uint64_t,const Surface*);
 FN(rzrt_scene_begin,int,void*,int);FN(rzrt_mesh_begin,int,void*,uint32_t,uint32_t,uint32_t);FN(rzrt_mesh_end,int,void*);
 FN(rzrt_scene_chunk,int,void*,const float*,uint32_t,const Surface*);FN(rzrt_scene_commit,int,void*,const void*,uint32_t,uint64_t);
 FN(rzrt_cache_stat,uint64_t,void*,uint32_t);
 FN(rzrt_trace,int,void*,const Zone*,uint64_t);
 FN(rzrt_output,GLuint,void*);FN(rzrt_ground_triangles,uint32_t,void*);
 FN(rzrt_frame_waits,uint64_t,void*);
 FN(rzrt_reflection_size,int,void*,const wchar_t*,uint32_t,uint32_t);FN(rzrt_reflection_texture,GLuint,void*,int);FN(rzrt_reflect,int,void*,const Camera*,uint64_t);
#undef FN
 int exitCode=0;
 for(int cycle=0;cycle<3;++cycle){
  void* c=rzrt_create(argv[2],128,16,4);if(!c){puts(rzrt_error());exitCode=5;break;}
  const float xyz[]={-10,-10,2,10,-10,2,10,10,2,-10,-10,2,10,10,2,-10,10,2};
  Surface material[2]{};for(auto& s:material){s.n[2]=-1;s.c[0]=.7f;s.c[1]=.1f;s.c[2]=.1f;}
  auto uploadScene=[&](uint64_t id){
   if(cycle==0)return rzrt_scene_materials(c,xyz,2,nullptr,0,id,material)!=0;
   if(cycle==2){
    // Exercise asynchronous BLAS compaction, without changing visible pixels.
    const uint32_t n=131074;
    std::vector<float> vertices(size_t(n)*9);std::copy(xyz,xyz+18,vertices.begin());
    std::vector<Surface> surfaces(n,material[0]);
    for(uint32_t i=2;i<n;++i){
     float x=100.f+float(i%512)*.05f,y=100.f+float(i/512)*.05f;
     float triangle[]={x,y,2,x+.03f,y,2,x,y+.03f,2};std::copy(triangle,triangle+9,vertices.begin()+size_t(i)*9);
    }
    if(!rzrt_scene_begin(c,0)||!rzrt_mesh_begin(c,n+6,0,material[0].n[3]<0?n:0))return false;
    for(uint32_t i=0;i<n;i+=65536)
     if(!rzrt_scene_chunk(c,vertices.data()+size_t(i)*9,std::min(65536u,n-i),surfaces.data()+i))return false;
    return rzrt_mesh_end(c)&&rzrt_scene_commit(c,nullptr,0,id);
   }
   // Capacity is deliberately larger than the actual mesh. Ground occupies
   // the tail; its reflection material offset must not assume opaqueCount.
   return rzrt_scene_begin(c,0)&&rzrt_mesh_begin(c,4,0,material[0].n[3]<0?2:0)&&
    rzrt_scene_chunk(c,xyz,1,material)&&rzrt_scene_chunk(c,xyz+9,1,material+1)&&
    rzrt_mesh_end(c)&&rzrt_scene_commit(c,nullptr,0,id);
  };
  if(!uploadScene(1)){puts(rzrt_error());exitCode=6;}
  std::array<Zone,4> zones{};for(auto& z:zones){z.o[0]=-10;z.o[1]=-10;z.u[0]=20;z.v[1]=20;z.r[2]=1;z.r[3]=10;}
  for(int tries=0;tries<1000;++tries){if(rzrt_trace(c,zones.data(),1)>0)break;glFlush();Sleep(1);}
  Camera camera{};for(int i=0;i<4;++i){camera.p[i*5]=1;camera.v[i*5]=1;}camera.sun[2]=-1;camera.range[0]=.1f;camera.range[1]=.9f;
  int mismatches=0,frames=0;
  for(int frame=0;frame<12&&!exitCode;++frame){
   int width=frame<6?16:32,height=16;
   if(!rzrt_reflection_size(c,argv[3],width,height)){puts(rzrt_error());exitCode=7;break;}
   std::vector<float> normal(width*height*4),depth(width*height,.325f),result(width*height*4);
   for(int y=0;y<height;++y)for(int x=0;x<width;++x){int i=(y*width+x)*4;normal[i]=.5f;normal[i+1]=.5f;normal[i+2]=1;normal[i+3]=x<width/2?1.f:0.f;}
   glBindTexture(GL_TEXTURE_2D,rzrt_reflection_texture(c,0));glTexSubImage2D(GL_TEXTURE_2D,0,0,0,width,height,GL_RGBA,GL_FLOAT,normal.data());
   glBindTexture(GL_TEXTURE_2D,rzrt_reflection_texture(c,1));glTexSubImage2D(GL_TEXTURE_2D,0,0,0,width,height,GL_DEPTH_COMPONENT,GL_FLOAT,depth.data());
   int r=0;for(int tries=0;tries<1000&&r==0;++tries){r=rzrt_reflect(c,&camera,1);glFlush();if(r==0)Sleep(1);}
   if(r<1){puts(rzrt_error());exitCode=8;break;}
   glBindTexture(GL_TEXTURE_2D,rzrt_reflection_texture(c,2));glGetTexImage(GL_TEXTURE_2D,0,GL_RGBA,GL_FLOAT,result.data());
   for(int y=0;y<height;++y)for(int x=0;x<width;++x){int i=(y*width+x)*4;bool hit=x<width/2;
    if(std::abs(result[i+3]-(hit?1.f:0.f))>.001f || (hit && result[i]<result[i+1]*2.f))++mismatches;}
   if(rzrt_reflect(c,&camera,999)!=0){exitCode=9;break;}
   rzrt_trace(c,zones.data(),1);++frames;
  }
  // A reflection-only surface must appear in reflections and NEVER in shadow
  // depth. Alternate many jobs without a readback/finish between every job.
  for(auto& s:material){s.n[3]=-1;s.c[0]=.05f;s.c[1]=.6f;}
  if(!uploadScene(2))exitCode=11;
  int ready=0;for(int n=0;n<1000&&!ready;++n){ready=rzrt_trace(c,zones.data(),2);glFlush();if(!ready)Sleep(1);}
  if(ready!=1||rzrt_ground_triangles(c)!=(cycle==2?131074u:2u))exitCode=12;
  for(int n=0;n<180&&!exitCode;++n){
    camera.v[12]=.01f*std::sin(n*.1f);
    if(rzrt_trace(c,zones.data(),2)!=1||rzrt_reflect(c,&camera,2)!=1)exitCode=13;
  }
  std::vector<float> reflection(32*16*4),shadow(128*128);
  glBindTexture(GL_TEXTURE_2D,rzrt_reflection_texture(c,2));glGetTexImage(GL_TEXTURE_2D,0,GL_RGBA,GL_FLOAT,reflection.data());
  glBindTexture(GL_TEXTURE_2D,rzrt_output(c));glGetTexImage(GL_TEXTURE_2D,0,GL_RED,GL_FLOAT,shadow.data());
  if(reflection[1]<reflection[0]*2||reflection[3]<.99f)++mismatches;
  for(float d:shadow)if(std::abs(d-1.f)>.00001f)++mismatches;
  unsigned glError=glGetError();printf("cycle=%d frames=%d stress=180 mismatch=%d GL=%u waits=%llu (resize, scene replacement, ground, no-readback stress)\n",cycle,frames,mismatches,glError,rzrt_frame_waits(c));
  printf("compacted=%llu saved=%llu bytes\n",rzrt_cache_stat(c,6),rzrt_cache_stat(c,7));
  if(mismatches||glError)exitCode=10;rzrt_destroy(c);if(exitCode)break;
 }
 FreeLibrary(lib);wglMakeCurrent(nullptr,nullptr);wglDeleteContext(rc);ReleaseDC(window,dc);DestroyWindow(window);return exitCode;
}
