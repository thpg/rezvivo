// Standalone hidden-context correctness check; readback is test-only.
#include <windows.h>
#include <GL/gl.h>
#include <array>
#include <vector>
#include <cstdio>
#include <stdexcept>
#include <cstdint>
#include <cmath>
struct Card { float o[4],u[4],v[4],s[4]; };
struct Zone { float o[4],u[4],v[4],r[4]; };
struct Surface {float normal[4],color[4],uv[12];};
static void APIENTRY debug(GLenum,GLenum,GLuint,GLenum,GLsizei,const char* s,const void*) { printf("GL: %s\n",s); }
int wmain(int argc,wchar_t** argv) {
    if(argc!=3) return 2;
    WNDCLASSW wc{}; wc.lpfnWndProc=DefWindowProcW; wc.hInstance=GetModuleHandle(nullptr); wc.lpszClassName=L"RezvivoRtSmoke"; wc.style=CS_OWNDC;
    RegisterClassW(&wc); HWND hwnd=CreateWindowW(wc.lpszClassName,L"",WS_POPUP,0,0,2,2,nullptr,nullptr,wc.hInstance,nullptr);
    HDC dc=GetDC(hwnd); PIXELFORMATDESCRIPTOR pf{}; pf.nSize=sizeof(pf); pf.nVersion=1; pf.dwFlags=PFD_DRAW_TO_WINDOW|PFD_SUPPORT_OPENGL|PFD_DOUBLEBUFFER; pf.iPixelType=PFD_TYPE_RGBA; pf.cColorBits=32; pf.cDepthBits=24;
    SetPixelFormat(dc,ChoosePixelFormat(dc,&pf),&pf); HGLRC rc=wglCreateContext(dc); wglMakeCurrent(dc,rc);
    auto callback=reinterpret_cast<void(APIENTRY*)(decltype(&debug),const void*)>(wglGetProcAddress("glDebugMessageCallback"));
    if(callback && GetEnvironmentVariableW(L"REZVIVO_GL_DEBUG",nullptr,0)) { glEnable(0x92E0); glEnable(0x8242); callback(debug,nullptr); }
    HMODULE dll=LoadLibraryW(argv[1]); if(!dll) return 3;
#define FN(n,ret,...) auto n=reinterpret_cast<ret(__cdecl*)(__VA_ARGS__)>(GetProcAddress(dll,#n)); if(!n) return 4
    FN(rzrt_create,void*,const wchar_t*,uint32_t,uint32_t,uint32_t); FN(rzrt_error,const char*);
    FN(rzrt_destroy,void,void*); FN(rzrt_alpha,GLuint,void*); FN(rzrt_output,GLuint,void*);
    FN(rzrt_scene,int,void*,const float*,uint32_t,const Card*,uint32_t,uint64_t); FN(rzrt_trace,int,void*,const Zone*,uint64_t); FN(rzrt_device,const char*,void*);
    FN(rzrt_scene_begin,int,void*,int);FN(rzrt_scene_chunk,int,void*,const float*,uint32_t,const void*);
    FN(rzrt_scene_commit,int,void*,const Card*,uint32_t,uint64_t);FN(rzrt_cache_stat,uint64_t,void*,uint32_t);
    FN(rzrt_mesh_begin_identity,int,void*,uint32_t,uint32_t,uint32_t,uint64_t);
    FN(rzrt_mesh_end,int,void*);FN(rzrt_mesh_reuse,int,void*,uint64_t);FN(rzrt_diagnostic,uint64_t,void*,uint32_t);
#undef FN
    int result=0;
    for(int cycle=0;cycle<3;++cycle) {
        void* c=rzrt_create(argv[2],128,16,4); if(!c) { printf("create: %s\n",rzrt_error()); result=5; break; }
        printf("cycle %d: %s\n",cycle,rzrt_device(c));
        auto upload=reinterpret_cast<void(APIENTRY*)(GLenum,GLint,GLint,GLint,GLint,GLsizei,GLsizei,GLsizei,GLenum,GLenum,const void*)>(wglGetProcAddress("glTexSubImage3D"));
        std::array<unsigned char,256> alpha{}; for(int y=0;y<16;++y) for(int x=0;x<16;++x) alpha[y*16+x]=x<8?255:0;
        glBindTexture(0x8C1A,rzrt_alpha(c)); upload(0x8C1A,0,0,0,0,16,16,1,GL_RED,GL_UNSIGNED_BYTE,alpha.data()); glBindTexture(0x8C1A,0);
        // Atlas mode includes opaque surfaces only. Tree cards are rendered
        // by its separate forest cache (Screen mode traces their alpha).
        const float vertices[]={0,0,3, 8,0,3, 8,16,3, 0,0,3, 8,16,3, 0,16,3};
        Card card{}; card.o[0]=8; card.o[2]=5; card.u[0]=8; card.v[1]=16;
        if(!rzrt_scene(c,vertices,2,&card,1,cycle+1)) { printf("scene: %s\n",rzrt_error()); result=6; rzrt_destroy(c); break; }
        std::array<Zone,4> zones{}; for(auto& z:zones) { z.u[0]=16; z.v[1]=16; z.r[2]=1; z.r[3]=10; }
        int frames=0;
        for(int j=0;j<1000 && frames<12;++j) { int r=rzrt_trace(c,zones.data(),cycle+1); if(r<0) { printf("trace: %s\n",rzrt_error()); result=7; break; } if(r) ++frames; glFlush(); Sleep(1); }
        if(rzrt_trace(c,zones.data(),999)!=0) { puts("Scene/origin revision guard failed"); result=10; }
        if(frames<12) result=8;
        std::vector<float> pixels(128*128); glBindTexture(GL_TEXTURE_2D,rzrt_output(c)); glGetTexImage(GL_TEXTURE_2D,0,GL_RED,GL_FLOAT,pixels.data());
        int bad=0; float min=1,max=0;
        for(int y=0;y<128;++y) for(int x=0;x<128;++x) {
            int q=x%64; float expected=q<32?.3f:1.f, got=pixels[y*128+x];
            if(std::abs(expected-got)>.0002f) ++bad; if(got<min) min=got; if(got>max) max=got;
        }
        printf("frames=%d mismatch=%d/16384 depth=[%.4f,%.4f] GL=%u\n",frames,bad,min,max,glGetError());
        if(bad) result=9;
        // Partition/reuse must preserve exact depth, retain a usable old scene
        // during the build, and not rebuild static BLAS on tree-only refreshes.
        auto ready=[&](uint64_t id){
            for(int i=0;i<2000;++i){int r=rzrt_trace(c,zones.data(),id);if(r<0)return false;if(r==1)return true;glFlush();Sleep(1);}return false;
        };
        uint64_t id=100;
        for(int repeat=0;repeat<4&&!result;++repeat){
            if(!rzrt_scene_begin(c,0)||!rzrt_scene_chunk(c,vertices,1,nullptr)||
               !rzrt_scene_chunk(c,vertices+9,1,nullptr)||!rzrt_scene_commit(c,&card,1,id)||!ready(id++)){result=11;break;}
            glBindTexture(GL_TEXTURE_2D,rzrt_output(c));glGetTexImage(GL_TEXTURE_2D,0,GL_RED,GL_FLOAT,pixels.data());
            for(int y=0;y<128;++y)for(int x=0;x<128;++x)
                if(std::abs(pixels[y*128+x]-(x%64<32?.3f:1.f))>.0002f)result=12;
        }
        const uint64_t builds=rzrt_cache_stat(c,1),hits=rzrt_cache_stat(c,2);
        if(builds!=3||hits!=6)result=13;
        for(int repeat=0;repeat<32&&!result;++repeat){
            card.o[2]=4.f+.01f*repeat;
            if(!rzrt_scene_begin(c,1)||!rzrt_scene_commit(c,&card,1,id)){result=14;break;}
            if(rzrt_trace(c,zones.data(),id-1)!=1||!ready(id++))result=15;
        }
        if(rzrt_cache_stat(c,1)!=builds||rzrt_cache_stat(c,3)!=32)result=16;
        // Cancel a not-yet-published mesh build; its buffers cannot be freed
        // while Vulkan still uses them.
        std::array<float,18> moved{};std::copy(vertices,vertices+18,moved.begin());moved[0]=.5f;
        if(!rzrt_scene_begin(c,0)||!rzrt_scene_chunk(c,moved.data(),2,nullptr)||
           !rzrt_scene_begin(c,1)||!rzrt_scene_commit(c,&card,1,id)||!ready(id))result=17;
        ++id;
        Surface surfaces[2]{};for(auto& s:surfaces)s.normal[2]=-1;
        if(!rzrt_scene_begin(c,0)||!rzrt_mesh_begin_identity(c,2,0,0,42)||
           !rzrt_scene_chunk(c,vertices,2,surfaces)||!rzrt_mesh_end(c)||
           !rzrt_scene_commit(c,&card,1,id)||!ready(id++))result=18;
        const auto hashes=rzrt_diagnostic(c,2),early=rzrt_cache_stat(c,8);
        if(!rzrt_scene_begin(c,0)||rzrt_mesh_reuse(c,404)!=0||rzrt_mesh_reuse(c,42)!=1||
           !rzrt_scene_commit(c,&card,1,id)||!ready(id++))result=19;
        if(rzrt_diagnostic(c,2)!=hashes||rzrt_cache_stat(c,8)!=early+1)result=20;
        printf("chunks=%llu builds=%llu hits=%llu tree-only=%llu status=%d\n",rzrt_cache_stat(c,0),rzrt_cache_stat(c,1),rzrt_cache_stat(c,2),rzrt_cache_stat(c,3),result);
        if(result)printf("error: %s\n",rzrt_error());
        rzrt_destroy(c);
        if(result) break;
    }
    FreeLibrary(dll); wglMakeCurrent(nullptr,nullptr); wglDeleteContext(rc); ReleaseDC(hwnd,dc); DestroyWindow(hwnd);
    return result;
}
