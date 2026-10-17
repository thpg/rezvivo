// Hidden-context analytic regression. CPU readback is used only by this test.
#include <windows.h>
#include <GL/gl.h>
#include <array>
#include <vector>
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cmath>
#include <algorithm>
#include <stdexcept>
struct Camera {float p[16],v[16],sun[4],h[4],z[4],range[4];};
struct Zone {float o[4],u[4],v[4],r[4];};
struct Actor {uint32_t firstVertex,vertexCount,firstIndex,indexCount;uint64_t topology;float transform[12];};
static_assert(sizeof(Actor)==72,"actor ABI");
struct Vertex {float x,y,z;uint32_t normal;};
static uint32_t ordered(float x){uint32_t v;memcpy(&v,&x,4);return v&0x80000000u?~v:v^0x80000000u;}
int wmain(int argc,wchar_t** argv){
 if(argc!=4)return 2;
 WNDCLASSW wc{};wc.lpfnWndProc=DefWindowProcW;wc.hInstance=GetModuleHandle(nullptr);wc.lpszClassName=L"RezvivoScreenTest";wc.style=CS_OWNDC;RegisterClassW(&wc);
 HWND window=CreateWindowW(wc.lpszClassName,L"",WS_POPUP,0,0,2,2,nullptr,nullptr,wc.hInstance,nullptr);HDC dc=GetDC(window);
 PIXELFORMATDESCRIPTOR pf{};pf.nSize=sizeof(pf);pf.nVersion=1;pf.dwFlags=PFD_DRAW_TO_WINDOW|PFD_SUPPORT_OPENGL|PFD_DOUBLEBUFFER;pf.iPixelType=PFD_TYPE_RGBA;pf.cColorBits=32;pf.cDepthBits=24;
 SetPixelFormat(dc,ChoosePixelFormat(dc,&pf),&pf);HGLRC rc=wglCreateContext(dc);wglMakeCurrent(dc,rc);
 HMODULE lib=LoadLibraryW(argv[1]);if(!lib)return 3;
#define FN(n,ret,...) auto n=reinterpret_cast<ret(__cdecl*)(__VA_ARGS__)>(GetProcAddress(lib,#n));if(!n)return 4
 FN(rzrt_create,void*,const wchar_t*,uint32_t,uint32_t,uint32_t);FN(rzrt_destroy,void,void*);FN(rzrt_error,const char*);
 FN(rzrt_scene,int,void*,const float*,uint32_t,const void*,uint32_t,uint64_t);FN(rzrt_trace,int,void*,const Zone*,uint64_t);
 FN(rzrt_screen_size,int,void*,const wchar_t*,uint32_t,uint32_t);FN(rzrt_screen_texture,GLuint,void*,int);
 FN(rzrt_screen_reuse_texture,GLuint,void*);FN(rzrt_screen_trace,int,void*,const Camera*,uint64_t);
 FN(rzrt_dynamic_buffer,GLuint,void*,uint32_t);FN(rzrt_dynamic_buffer_indexed,GLuint,void*,uint32_t,uint32_t,uint64_t,GLuint*,uint32_t*);
 FN(rzrt_dynamic_actors,int,void*,const Actor*,uint32_t);FN(rzrt_dynamic_actor_revisions,int,void*,const uint64_t*,uint32_t);
 FN(rzrt_dynamic_stat,uint64_t,void*,uint32_t);FN(rzrt_image_write,int,void*,int);FN(rzrt_alpha,GLuint,void*);
#undef FN
 auto bind=reinterpret_cast<void(APIENTRY*)(GLenum,GLuint)>(wglGetProcAddress("glBindBuffer"));
 auto sub=reinterpret_cast<void(APIENTRY*)(GLenum,intptr_t,intptr_t,const void*)>(wglGetProcAddress("glBufferSubData"));
 auto upload3=reinterpret_cast<void(APIENTRY*)(GLenum,GLint,GLint,GLint,GLint,GLsizei,GLsizei,GLsizei,GLenum,GLenum,const void*)>(wglGetProcAddress("glTexSubImage3D"));
 if(!bind||!sub||!upload3)return 5;
 int result=0;void* context=nullptr;
 try{
  auto check=[&](bool okay){if(!okay)throw std::runtime_error(rzrt_error());};
  std::vector<std::vector<unsigned char>> reference;
  // Compare each independent switch against the complete new path.
  const wchar_t* controls[]={nullptr,L"REZVIVO_RTX_FILTER_SHARED",L"REZVIVO_RTX_HARD_DIRECT",L"REZVIVO_RTX_SKIP_ZERO_STORE",L"REZVIVO_RTX_SOLAR_CONSTANTS",L"REZVIVO_RTX_PASS_RESOURCES",L"REZVIVO_RTX_RETAIN_ATLASES",L"REZVIVO_RTX_DESCRIPTOR_CACHE"};
  for(int variant=0;variant<8;++variant){
   if(controls[variant])SetEnvironmentVariableW(controls[variant],L"0");
   context=rzrt_create(argv[2],128,16,4);check(context!=nullptr);
   const float farWorld[]={100,100,1,101,100,1,100,101,1};
   check(rzrt_scene(context,farWorld,1,nullptr,0,1)>0);
   std::array<Zone,4> zones{};for(auto& z:zones){z.u[0]=2;z.v[1]=2;z.r[2]=1;z.r[3]=10;}
   bool ready=false;for(int i=0;i<2000&&!ready;++i){int status=rzrt_trace(context,zones.data(),1);check(status>=0);ready=status>0;glFlush();Sleep(1);}check(ready);
   Camera camera{};for(int i=0;i<4;++i){camera.p[i*5]=1;camera.v[i*5]=1;}
   camera.p[10]=2;camera.p[14]=2;camera.v[14]=-1;camera.sun[2]=1;camera.z[1]=10;camera.z[2]=8;camera.range[0]=.1f;camera.range[1]=.9f;
   int output=0,errors=0,maxDifference=0;uint64_t sumDifference=0,changed=0;
   for(int pass=0;pass<3;++pass)for(int mode=0;mode<5;++mode){
    const bool soft=pass==1,smooth=pass==2;
    const int width=soft?65:48,height=soft?49:32;
    camera.z[0]=soft?.035f:0;camera.range[2]=1;camera.range[3]=1;
    check(rzrt_screen_size(context,argv[3],width,height)>0);
    std::vector<float> depth(width*height,.5f),reuse(width*height*2);
    for(int y=0;y<height;++y)for(int x=0;x<width;++x){int p=y*width+x;if(smooth&&x<width/2)depth[p]=.625f;reuse[p*2]=-1;reuse[p*2+1]=depth[p];if(y>height-5)depth[p]=1;if(y<3&&x>width/2){reuse[p*2]=.25f;reuse[p*2+1]=depth[p];}}
    std::vector<unsigned char> pixels(width*height);
    const Vertex unique[]={{-1,-1,.25f,0},{0,-1,.25f,0},{0,1,.25f,0},{-1,1,.25f,0}};
    const uint32_t normalIndices[]={0,1,2,0,2,3},alternateIndices[]={0,1,3,1,2,3};
    for(int frame=0;frame<15;++frame){
     // Rewrite the retained alpha atlas only via the explicit ownership API.
     if(frame==8){check(rzrt_image_write(context,0)>0);std::array<unsigned char,256> alpha{};alpha.fill(255);glBindTexture(0x8C1A,rzrt_alpha(context));upload3(0x8C1A,0,0,0,0,16,16,1,GL_RED,GL_UNSIGNED_BYTE,alpha.data());}
     glBindTexture(GL_TEXTURE_2D,rzrt_screen_texture(context,0));glTexSubImage2D(GL_TEXTURE_2D,0,0,0,width,height,GL_DEPTH_COMPONENT,GL_FLOAT,depth.data());
     glBindTexture(GL_TEXTURE_2D,rzrt_screen_reuse_texture(context));glTexSubImage2D(GL_TEXTURE_2D,0,0,0,width,height,0x8227,GL_FLOAT,reuse.data());
     const bool indexed=mode>0,local=mode==2||mode==3;
     uint32_t index=0,dirty=0;uint64_t topology=uint64_t(mode+1)*10+(mode==4&&frame>=7?1:0);
     const uint32_t* ids=mode==4&&frame>=7?alternateIndices:normalIndices;
     GLuint target=indexed?rzrt_dynamic_buffer_indexed(context,2,4,topology,&index,&dirty):rzrt_dynamic_buffer(context,2);check(target!=0);
     uint32_t bounds[]={ordered(-1),ordered(-1),ordered(.25f),0,ordered(0),ordered(1),ordered(.25f),0};
     std::vector<Vertex> vertices;
     if(indexed)vertices.assign(unique,unique+4);else for(uint32_t id:normalIndices)vertices.push_back(unique[id]);
     for(auto& p:vertices){
      p.normal=smooth?9830u:0u; // Nonzero octahedral smooth normal, toward +Z.
      if(local){float x=p.x;p.x=p.y;p.y=-(x+.5f);if(smooth)p.normal=uint32_t(uint16_t(-9830))<<16;}
     }
     bind(0x90D2,target);sub(0x90D2,0,sizeof(bounds),bounds);sub(0x90D2,sizeof(bounds),vertices.size()*sizeof(Vertex),vertices.data());
     if(indexed&&dirty){bind(0x90D2,index);sub(0x90D2,0,6*sizeof(uint32_t),ids);}bind(0x90D2,0);
     if(local){Actor actor{};actor.vertexCount=4;actor.indexCount=6;actor.topology=topology;actor.transform[1]=-1;actor.transform[4]=actor.transform[10]=1;actor.transform[3]=-.5f;
      check(rzrt_dynamic_actors(context,&actor,1)>0);if(mode==3){uint64_t revision=1;check(rzrt_dynamic_actor_revisions(context,&revision,1)>0);}}
     check(rzrt_screen_trace(context,&camera,1)>0);
    }
    glPixelStorei(GL_PACK_ALIGNMENT,1);glBindTexture(GL_TEXTURE_2D,rzrt_screen_texture(context,1));glGetTexImage(GL_TEXTURE_2D,0,GL_RED,GL_UNSIGNED_BYTE,pixels.data());
    for(int y=0;y<height;++y)for(int x=0;x<width;++x){int p=y*width+x;int expected=!smooth&&x<width/2?255:0;if(y<3&&x>width/2)expected=64;if(y>height-5)expected=0;
      if(!soft&&std::abs(int(pixels[p])-expected)>1)++errors;
      if(soft&&y>6&&y<height-7&&(x<width/2-5||x>width/2+5)&&std::abs(int(pixels[p])-expected)>1)++errors;}
    if(variant==0){if(mode>0&&pixels!=reference[pass*5])throw std::runtime_error("indexed/local/rigid changed image");reference.push_back(pixels);}
    else for(size_t p=0;p<pixels.size();++p){int difference=std::abs(int(pixels[p])-int(reference[output][p]));maxDifference=std::max(maxDifference,difference);sumDifference+=difference;if(difference)++changed;}
    ++output;
   }
   const unsigned glError=glGetError();
   printf("variant=%d analytic=%d maxDiff=%d changed=%llu sumDiff=%llu GL=%u builds=%llu refits=%llu rigidSkips=%llu\n",variant,errors,maxDifference,changed,sumDifference,glError,rzrt_dynamic_stat(context,1),rzrt_dynamic_stat(context,2),rzrt_dynamic_stat(context,6));
   // Prepared solar basis can differ by one R8 unit at a floating-point boundary;
   // filter/ownership/descriptor optimizations must be byte-exact.
   if(errors||glError||(variant==4?maxDifference>1:maxDifference!=0))throw std::runtime_error("screen image regression");
   if(!rzrt_dynamic_stat(context,6))throw std::runtime_error("rigid BLAS was not reused");
   rzrt_destroy(context);context=nullptr;if(controls[variant])SetEnvironmentVariableW(controls[variant],nullptr);
  }
 }catch(const std::exception& e){printf("FAIL: %s\n",e.what());result=10;}
 if(context)rzrt_destroy(context);FreeLibrary(lib);wglMakeCurrent(nullptr,nullptr);wglDeleteContext(rc);ReleaseDC(window,dc);DestroyWindow(window);return result;
}
