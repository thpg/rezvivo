// Optional Vulkan 1.2 ray-query bridge. GPL-3.0-or-later, like REZVIVO.
// No CUDA, SDK runtime, Vulkan import library, or per-frame CPU image readback.
#define VK_NO_PROTOTYPES
#define VK_USE_PLATFORM_WIN32_KHR
#include <windows.h>
#include <GL/gl.h>
#include <vulkan/vulkan.h>
#include <algorithm>
#include <array>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

#define API extern "C" __declspec(dllexport)
#define CHECK(x) do { VkResult checkedVkResult=(x); if(checkedVkResult!=VK_SUCCESS) throw std::runtime_error(std::string(#x)+": "+std::to_string(checkedVkResult)); } while(0)
static thread_local std::string error;
struct Card { float origin[4], u[4], v[4], spare[4]; };
struct Zone { float origin[4], du[4], dv[4], ray[4]; };
struct Surface { float normal[4],color[4],uv0[4],uv1[4],uv2[4]; };
struct ReflectionCamera { float invProjection[16],invView[16],sun[4],horizon[4],zenith[4],depthRange[4]; };
struct Stats {
    uint64_t sceneId, triangles, cards, bytes, frames, builds;
    double traceMs, buildMs;
};
static_assert(sizeof(Card)==64 && sizeof(Zone)==64 && sizeof(Stats)==64,"C ABI layout");

// Khronos EXT_memory_object/EXT_semaphore entry points, absent from Windows GL.h.
struct GLInterop {
    void (APIENTRY *CreateMemoryObjects)(GLsizei,GLuint*);
    void (APIENTRY *DeleteMemoryObjects)(GLsizei,const GLuint*);
    void (APIENTRY *MemoryObjectParameteriv)(GLuint,GLenum,const GLint*);
    void (APIENTRY *ImportMemoryWin32Handle)(GLuint,uint64_t,GLenum,void*);
    void (APIENTRY *TexStorageMem2D)(GLenum,GLsizei,GLenum,GLsizei,GLsizei,GLuint,uint64_t);
    void (APIENTRY *TexStorageMem3D)(GLenum,GLsizei,GLenum,GLsizei,GLsizei,GLsizei,GLuint,uint64_t);
    void (APIENTRY *GenSemaphores)(GLsizei,GLuint*);
    void (APIENTRY *DeleteSemaphores)(GLsizei,const GLuint*);
    void (APIENTRY *ImportSemaphoreWin32Handle)(GLuint,GLenum,void*);
    void (APIENTRY *WaitSemaphore)(GLuint,GLuint,const GLuint*,GLuint,const GLuint*,const GLenum*);
    void (APIENTRY *SignalSemaphore)(GLuint,GLuint,const GLuint*,GLuint,const GLuint*,const GLenum*);
    void (APIENTRY *GetUnsignedBytei_v)(GLenum,GLuint,GLubyte*);
    template<class T> static void load(T& out,const char* name) {
        PROC p=wglGetProcAddress(name);
        if(!p || p==reinterpret_cast<PROC>(1) || p==reinterpret_cast<PROC>(-1))
            throw std::runtime_error(std::string("Missing OpenGL function: ")+name);
        out=reinterpret_cast<T>(p);
    }
    void init() {
        load(CreateMemoryObjects,"glCreateMemoryObjectsEXT"); load(DeleteMemoryObjects,"glDeleteMemoryObjectsEXT");
        load(MemoryObjectParameteriv,"glMemoryObjectParameterivEXT"); load(ImportMemoryWin32Handle,"glImportMemoryWin32HandleEXT");
        load(TexStorageMem2D,"glTexStorageMem2DEXT"); load(TexStorageMem3D,"glTexStorageMem3DEXT");
        load(GenSemaphores,"glGenSemaphoresEXT"); load(DeleteSemaphores,"glDeleteSemaphoresEXT");
        load(ImportSemaphoreWin32Handle,"glImportSemaphoreWin32HandleEXT"); load(WaitSemaphore,"glWaitSemaphoreEXT");
        load(SignalSemaphore,"glSignalSemaphoreEXT"); load(GetUnsignedBytei_v,"glGetUnsignedBytei_vEXT");
    }
};

#define INSTANCE_FUNCS(X) \
 X(DestroyInstance) X(EnumeratePhysicalDevices) X(GetPhysicalDeviceProperties2) \
 X(GetPhysicalDeviceFeatures2) X(GetPhysicalDeviceMemoryProperties) X(GetPhysicalDeviceQueueFamilyProperties) \
 X(EnumerateDeviceExtensionProperties) X(CreateDevice) X(GetDeviceProcAddr)
#define DEVICE_FUNCS(X) \
 X(DestroyDevice) X(GetDeviceQueue) X(DeviceWaitIdle) X(CreateBuffer) X(DestroyBuffer) \
 X(GetBufferMemoryRequirements) X(AllocateMemory) X(FreeMemory) X(BindBufferMemory) X(MapMemory) X(UnmapMemory) \
 X(GetBufferDeviceAddress) X(CreateImage) X(DestroyImage) X(GetImageMemoryRequirements) X(BindImageMemory) \
 X(CreateImageView) X(DestroyImageView) X(GetMemoryWin32HandleKHR) X(CreateSampler) X(DestroySampler) \
 X(CreateSemaphore) X(DestroySemaphore) X(GetSemaphoreWin32HandleKHR) X(CreateFence) X(DestroyFence) \
 X(GetFenceStatus) X(ResetFences) X(WaitForFences) X(CreateCommandPool) X(DestroyCommandPool) \
 X(AllocateCommandBuffers) X(FreeCommandBuffers) X(ResetCommandBuffer) X(BeginCommandBuffer) X(EndCommandBuffer) \
 X(QueueSubmit) X(CmdPipelineBarrier) X(CreateShaderModule) X(DestroyShaderModule) \
 X(CreateDescriptorSetLayout) X(DestroyDescriptorSetLayout) X(CreatePipelineLayout) X(DestroyPipelineLayout) \
 X(CreateComputePipelines) X(DestroyPipeline) X(CreateDescriptorPool) X(DestroyDescriptorPool) \
 X(AllocateDescriptorSets) X(UpdateDescriptorSets) X(CmdBindPipeline) X(CmdBindDescriptorSets) X(CmdDispatch) \
 X(CreateAccelerationStructureKHR) X(DestroyAccelerationStructureKHR) X(GetAccelerationStructureBuildSizesKHR) \
 X(GetAccelerationStructureDeviceAddressKHR) X(CmdBuildAccelerationStructuresKHR) \
 X(CreateQueryPool) X(DestroyQueryPool) X(CmdResetQueryPool) X(CmdWriteTimestamp) X(GetQueryPoolResults)

struct Buffer { VkBuffer handle{}; VkDeviceMemory memory{}; void* mapped{}; VkDeviceSize size{}; VkDeviceAddress address{}; };
struct Image { VkImage handle{}; VkImageView view{}; VkDeviceMemory memory{}; GLuint texture{},glMemory{}; uint32_t layers{}; VkDeviceSize size{}; HANDLE exported{}; };
struct Context;
struct Scene {
    Context* c{}; VkAccelerationStructureKHR blas{},groundBlas{},tlas{};
    Buffer vertices,cards,surfaces,blasBuffer,groundBuffer,tlasBuffer,scratch,instances;
    VkCommandBuffer cmd{}; VkFence fence{};
    uint64_t id{},triangles{},cardCount{}; uint32_t opaqueCount{},groundCount{}; LARGE_INTEGER start{};
    ~Scene();
};
struct Frame { VkCommandBuffer cmd{}; VkFence fence{}; VkDescriptorSet set{}; Buffer views; std::shared_ptr<Scene> scene; bool submitted{},reflection{}; };
struct Context {
    HMODULE loader{}; VkInstance instance{}; VkPhysicalDevice gpu{}; VkDevice device{}; VkQueue queue{}; uint32_t family{};
    VkPhysicalDeviceMemoryProperties memory{}; VkPhysicalDeviceProperties props{}; uint32_t scratchAlignment{256};
    PFN_vkGetInstanceProcAddr GetInstanceProcAddr{};
#define DECL(n) PFN_vk##n n{};
    INSTANCE_FUNCS(DECL) DEVICE_FUNCS(DECL)
#undef DECL
    GLInterop gl{}; Image output,alpha; VkSemaphore ready{},done{}; GLuint glReady{},glDone{}; HANDLE readyHandle{},doneHandle{};
    VkCommandPool pool{}; VkDescriptorSetLayout setLayout{}; VkPipelineLayout pipeLayout{}; VkPipeline pipeline{};
    VkDescriptorPool descPool{}; VkSampler sampler{}; VkQueryPool queries{};
    std::array<Frame,6> frames{}; unsigned frameIndex{}; uint32_t side{},alphaSide{},alphaLayers{};
    std::shared_ptr<Scene> active,pending; Stats stats{}; std::string name;
    Image reflectionNormal,reflectionDepth,reflectionOutput,reflectionAtlas;
    VkPipeline reflectionPipeline{}; uint32_t reflectionWidth{},reflectionHeight{};
    double reflectionMs{}; uint64_t reflectionFrames{},busyFrames{};
    ~Context();
    void init(const wchar_t* shader,uint32_t size,uint32_t aSide,uint32_t aLayers);
    Frame& acquireFrame() {
        for(unsigned n=0;n<frames.size();++n) {
            unsigned i=(frameIndex+n)%unsigned(frames.size());
            VkResult r=GetFenceStatus(device,frames[i].fence);
            if(r==VK_SUCCESS) { frameIndex=i; return frames[i]; }
            if(r!=VK_NOT_READY) CHECK(r);
        }
        // Backpressure must not remove shadows/reflections from a rendered
        // frame. Flush the GL semaphore waits before waiting for an old slot.
        ++busyFrames;glFlush();
        CHECK(WaitForFences(device,1,&frames[frameIndex].fence,VK_TRUE,UINT64_MAX));
        return frames[frameIndex];
    }
    uint32_t memoryType(uint32_t bits,VkMemoryPropertyFlags flags) {
        for(uint32_t i=0;i<memory.memoryTypeCount;++i)
            if((bits&(1u<<i)) && (memory.memoryTypes[i].propertyFlags&flags)==flags) return i;
        throw std::runtime_error("No compatible Vulkan memory type");
    }
    Buffer buffer(VkDeviceSize size,VkBufferUsageFlags usage,bool host=false) {
        Buffer b; b.size=std::max<VkDeviceSize>(size,16);
        VkBufferCreateInfo info{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO}; info.size=b.size; info.usage=usage;
        CHECK(CreateBuffer(device,&info,nullptr,&b.handle));
        VkMemoryRequirements req; GetBufferMemoryRequirements(device,b.handle,&req);
        VkMemoryAllocateFlagsInfo flags{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_FLAGS_INFO};
        flags.flags=(usage&VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT)?VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT:0;
        VkMemoryAllocateInfo alloc{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO}; alloc.pNext=&flags; alloc.allocationSize=req.size;
        alloc.memoryTypeIndex=memoryType(req.memoryTypeBits,host ? VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT : VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        try {
            CHECK(AllocateMemory(device,&alloc,nullptr,&b.memory)); CHECK(BindBufferMemory(device,b.handle,b.memory,0));
            if(host) CHECK(MapMemory(device,b.memory,0,b.size,0,&b.mapped));
            if(flags.flags) { VkBufferDeviceAddressInfo ai{VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO}; ai.buffer=b.handle; b.address=GetBufferDeviceAddress(device,&ai); }
        } catch(...) { destroy(b); throw; }
        return b;
    }
    void destroy(Buffer& b) {
        if(b.mapped) UnmapMemory(device,b.memory);
        if(b.handle) DestroyBuffer(device,b.handle,nullptr);
        if(b.memory) FreeMemory(device,b.memory,nullptr); b={};
    }
    void destroy(Image& i) {
        if(i.texture) glDeleteTextures(1,&i.texture);
        if(i.glMemory) gl.DeleteMemoryObjects(1,&i.glMemory);
        if(i.exported) CloseHandle(i.exported);
        if(i.view) DestroyImageView(device,i.view,nullptr);
        if(i.handle) DestroyImage(device,i.handle,nullptr);
        if(i.memory) FreeMemory(device,i.memory,nullptr); i={};
    }
    void image(Image& out,uint32_t size,uint32_t layers,VkFormat format,VkImageUsageFlags usage,uint32_t height=0);
    void semaphore(VkSemaphore& vk,GLuint& ogl,HANDLE& exported);
    VkCommandBuffer command() {
        VkCommandBufferAllocateInfo i{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO}; i.commandPool=pool; i.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY; i.commandBufferCount=1;
        VkCommandBuffer r; CHECK(AllocateCommandBuffers(device,&i,&r)); return r;
    }
    VkFence newFence(bool signaled=false) {
        VkFenceCreateInfo i{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO}; i.flags=signaled?VK_FENCE_CREATE_SIGNALED_BIT:0;
        VkFence r; CHECK(CreateFence(device,&i,nullptr,&r)); return r;
    }
    void begin(VkCommandBuffer cmd) {
        VkCommandBufferBeginInfo i{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO}; i.flags=VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT; CHECK(BeginCommandBuffer(cmd,&i));
    }
    void barriers(VkCommandBuffer cmd,bool acquire,bool initial=false,bool reflectionsOnly=false) {
        VkImageMemoryBarrier b[6]{}; Image* images[6]={&output,&alpha,&reflectionNormal,&reflectionDepth,&reflectionOutput,&reflectionAtlas};
        int begin=reflectionsOnly?2:0,end=reflectionWidth?6:2;
        for(int k=begin;k<end;++k) {
            b[k].sType=VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
            b[k].srcAccessMask=initial||acquire?0:VK_ACCESS_SHADER_READ_BIT|VK_ACCESS_SHADER_WRITE_BIT;
            b[k].dstAccessMask=acquire?VK_ACCESS_SHADER_READ_BIT|VK_ACCESS_SHADER_WRITE_BIT:0;
            b[k].oldLayout=initial?VK_IMAGE_LAYOUT_UNDEFINED:VK_IMAGE_LAYOUT_GENERAL; b[k].newLayout=VK_IMAGE_LAYOUT_GENERAL;
            b[k].srcQueueFamilyIndex=acquire?VK_QUEUE_FAMILY_EXTERNAL:family; b[k].dstQueueFamilyIndex=acquire?family:VK_QUEUE_FAMILY_EXTERNAL;
            b[k].image=images[k]->handle; b[k].subresourceRange={VkImageAspectFlags(k==3?VK_IMAGE_ASPECT_DEPTH_BIT:VK_IMAGE_ASPECT_COLOR_BIT),0,1,0,images[k]->layers};
        }
        CmdPipelineBarrier(cmd,acquire||initial?VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT:VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            acquire?VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT:VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,0,0,nullptr,0,nullptr,end-begin,b+begin);
    }
    void poll();
    void build(const float* xyz,uint32_t triangles,const Card* cards,uint32_t count,uint64_t id,const Surface* surfaces=nullptr);
    bool trace(const Zone* zones,uint64_t expectedScene);
    void reflectionSize(const wchar_t* shader,uint32_t width,uint32_t height);
    bool reflect(const ReflectionCamera* camera,uint64_t expectedScene);
    void handoff(VkCommandBuffer cmd,VkFence fence);
};

void Context::image(Image& out,uint32_t size,uint32_t layers,VkFormat format,VkImageUsageFlags usage,uint32_t height) {
    if(!height) height=size;
    out.layers=layers;
    VkExternalMemoryImageCreateInfo ext{VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO}; ext.handleTypes=VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_WIN32_BIT;
    VkImageCreateInfo i{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO}; i.pNext=&ext; i.imageType=VK_IMAGE_TYPE_2D; i.format=format;
    i.extent={size,height,1}; i.mipLevels=1; i.arrayLayers=layers; i.samples=VK_SAMPLE_COUNT_1_BIT; i.tiling=VK_IMAGE_TILING_OPTIMAL; i.usage=usage;
    CHECK(CreateImage(device,&i,nullptr,&out.handle));
    VkMemoryRequirements req; GetImageMemoryRequirements(device,out.handle,&req); out.size=req.size;
    VkExportMemoryWin32HandleInfoKHR win{VK_STRUCTURE_TYPE_EXPORT_MEMORY_WIN32_HANDLE_INFO_KHR}; win.dwAccess=GENERIC_ALL;
    VkExportMemoryAllocateInfo exp{VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO}; exp.handleTypes=ext.handleTypes; exp.pNext=&win;
    VkMemoryDedicatedAllocateInfo dedicated{VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO}; dedicated.pNext=&exp; dedicated.image=out.handle;
    VkMemoryAllocateInfo a{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO}; a.pNext=&dedicated; a.allocationSize=req.size; a.memoryTypeIndex=memoryType(req.memoryTypeBits,VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    CHECK(AllocateMemory(device,&a,nullptr,&out.memory)); CHECK(BindImageMemory(device,out.handle,out.memory,0));
    VkImageViewCreateInfo v{VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO}; v.image=out.handle; v.viewType=layers==1?VK_IMAGE_VIEW_TYPE_2D:VK_IMAGE_VIEW_TYPE_2D_ARRAY;
    v.format=format; v.subresourceRange={VkImageAspectFlags(format==VK_FORMAT_D32_SFLOAT?VK_IMAGE_ASPECT_DEPTH_BIT:VK_IMAGE_ASPECT_COLOR_BIT),0,1,0,layers}; CHECK(CreateImageView(device,&v,nullptr,&out.view));
    VkMemoryGetWin32HandleInfoKHR h{VK_STRUCTURE_TYPE_MEMORY_GET_WIN32_HANDLE_INFO_KHR}; h.memory=out.memory; h.handleType=VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_WIN32_BIT;
    CHECK(GetMemoryWin32HandleKHR(device,&h,&out.exported));
    gl.CreateMemoryObjects(1,&out.glMemory); GLint yes=GL_TRUE; gl.MemoryObjectParameteriv(out.glMemory,0x9581 /*DEDICATED_MEMORY_OBJECT_EXT*/,&yes);
    // Keep the NT handle for the lifetime of its imported GL object. In
    // particular, do not race deferred driver work by closing it immediately.
    gl.ImportMemoryWin32Handle(out.glMemory,req.size,0x9587 /*HANDLE_TYPE_OPAQUE_WIN32_EXT*/,out.exported);
    GLenum imported=glGetError(); if(imported) throw std::runtime_error("Memory import GL error "+std::to_string(imported));
    GLenum target=layers==1?GL_TEXTURE_2D:0x8C1A; GLint old=0;
    glGetIntegerv(layers==1?GL_TEXTURE_BINDING_2D:0x8C1D,&old);
    glGenTextures(1,&out.texture); glBindTexture(target,out.texture);
    GLenum glFormat=format==VK_FORMAT_D32_SFLOAT?0x8CAC:format==VK_FORMAT_R16G16B16A16_SFLOAT?0x881A:format==VK_FORMAT_R8G8B8A8_UNORM?0x8058:0x822E;
    if(layers==1) gl.TexStorageMem2D(target,1,glFormat,size,height,out.glMemory,0);
    else gl.TexStorageMem3D(target,1,0x8229 /*R8*/,size,size,layers,out.glMemory,0);
    glTexParameteri(target,GL_TEXTURE_MIN_FILTER,GL_NEAREST); glTexParameteri(target,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
    glTexParameteri(target,GL_TEXTURE_WRAP_S,0x812F); glTexParameteri(target,GL_TEXTURE_WRAP_T,0x812F);
    GLenum e=glGetError(); glBindTexture(target,old);
    if(e) throw std::runtime_error("OpenGL/Vulkan shared image error "+std::to_string(e)+" format="+std::to_string(format)+" bytes="+std::to_string(req.size));
}
void Context::semaphore(VkSemaphore& vk,GLuint& ogl,HANDLE& exported) {
    VkExportSemaphoreWin32HandleInfoKHR win{VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_WIN32_HANDLE_INFO_KHR}; win.dwAccess=GENERIC_ALL;
    VkExportSemaphoreCreateInfo exp{VK_STRUCTURE_TYPE_EXPORT_SEMAPHORE_CREATE_INFO}; exp.handleTypes=VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_WIN32_BIT; exp.pNext=&win;
    VkSemaphoreCreateInfo i{VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO}; i.pNext=&exp; CHECK(CreateSemaphore(device,&i,nullptr,&vk));
    VkSemaphoreGetWin32HandleInfoKHR h{VK_STRUCTURE_TYPE_SEMAPHORE_GET_WIN32_HANDLE_INFO_KHR}; h.semaphore=vk; h.handleType=VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_OPAQUE_WIN32_BIT;
    CHECK(GetSemaphoreWin32HandleKHR(device,&h,&exported)); gl.GenSemaphores(1,&ogl);
    gl.ImportSemaphoreWin32Handle(ogl,0x9587,exported);
    if(glGetError()) throw std::runtime_error("OpenGL/Vulkan semaphore import failed");
}
void Context::init(const wchar_t* shader,uint32_t size,uint32_t aSide,uint32_t aLayers) {
    if(!wglGetCurrentContext()) throw std::runtime_error("RTX requires the current Studio OpenGL context");
    side=size; alphaSide=aSide; alphaLayers=aLayers; gl.init();
    uint8_t uuid[VK_UUID_SIZE]{}; gl.GetUnsignedBytei_v(0x9597 /*DEVICE_UUID_EXT*/,0,uuid);
    if(glGetError()) throw std::runtime_error("Cannot match the OpenGL device UUID");
    loader=LoadLibraryW(L"vulkan-1.dll"); if(!loader) throw std::runtime_error("Vulkan loader is not installed");
    GetInstanceProcAddr=reinterpret_cast<PFN_vkGetInstanceProcAddr>(GetProcAddress(loader,"vkGetInstanceProcAddr"));
    if(!GetInstanceProcAddr) throw std::runtime_error("Invalid Vulkan loader");
    auto create=reinterpret_cast<PFN_vkCreateInstance>(GetInstanceProcAddr(nullptr,"vkCreateInstance"));
    VkApplicationInfo ai{VK_STRUCTURE_TYPE_APPLICATION_INFO}; ai.pApplicationName="REZVIVO Studio RTX"; ai.apiVersion=VK_API_VERSION_1_2;
    VkInstanceCreateInfo ic{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO}; ic.pApplicationInfo=&ai; CHECK(create(&ic,nullptr,&instance));
#define LOAD_I(n) n=reinterpret_cast<PFN_vk##n>(GetInstanceProcAddr(instance,"vk" #n)); if(!n) throw std::runtime_error("Missing vk" #n);
    INSTANCE_FUNCS(LOAD_I)
#undef LOAD_I
    uint32_t count=0; CHECK(EnumeratePhysicalDevices(instance,&count,nullptr)); std::vector<VkPhysicalDevice> devices(count); CHECK(EnumeratePhysicalDevices(instance,&count,devices.data()));
    for(auto d:devices) {
        VkPhysicalDeviceIDProperties id{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ID_PROPERTIES};
        VkPhysicalDeviceProperties2 p{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2}; p.pNext=&id; GetPhysicalDeviceProperties2(d,&p);
        if(!memcmp(uuid,id.deviceUUID,VK_UUID_SIZE)) { gpu=d; props=p.properties; name=props.deviceName; break; }
    }
    if(!gpu) throw std::runtime_error("No Vulkan device matching the OpenGL GPU");
    const char* wanted[]={VK_KHR_ACCELERATION_STRUCTURE_EXTENSION_NAME,VK_KHR_RAY_QUERY_EXTENSION_NAME,VK_KHR_DEFERRED_HOST_OPERATIONS_EXTENSION_NAME,VK_KHR_EXTERNAL_MEMORY_WIN32_EXTENSION_NAME,VK_KHR_EXTERNAL_SEMAPHORE_WIN32_EXTENSION_NAME};
    CHECK(EnumerateDeviceExtensionProperties(gpu,nullptr,&count,nullptr)); std::vector<VkExtensionProperties> extensions(count); CHECK(EnumerateDeviceExtensionProperties(gpu,nullptr,&count,extensions.data()));
    for(auto w:wanted) if(std::none_of(extensions.begin(),extensions.end(),[&](const auto& e){return !strcmp(e.extensionName,w);})) throw std::runtime_error(std::string("GPU lacks ")+w);
    VkPhysicalDeviceRayQueryFeaturesKHR rq{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_RAY_QUERY_FEATURES_KHR};
    VkPhysicalDeviceAccelerationStructureFeaturesKHR as{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ACCELERATION_STRUCTURE_FEATURES_KHR}; as.pNext=&rq;
    VkPhysicalDeviceVulkan12Features f12{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES}; f12.pNext=&as;
    VkPhysicalDeviceFeatures2 f2{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2}; f2.pNext=&f12; GetPhysicalDeviceFeatures2(gpu,&f2);
    if(!rq.rayQuery || !as.accelerationStructure || !f12.bufferDeviceAddress) throw std::runtime_error("Hardware ray queries are unavailable");
    // Enable only features used by this bridge.
    f12={VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES}; f12.pNext=&as; f12.bufferDeviceAddress=VK_TRUE;
    as={VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ACCELERATION_STRUCTURE_FEATURES_KHR}; as.pNext=&rq; as.accelerationStructure=VK_TRUE;
    rq={VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_RAY_QUERY_FEATURES_KHR}; rq.rayQuery=VK_TRUE;
    GetPhysicalDeviceQueueFamilyProperties(gpu,&count,nullptr); std::vector<VkQueueFamilyProperties> queues(count); GetPhysicalDeviceQueueFamilyProperties(gpu,&count,queues.data());
    bool found=false;
    for(uint32_t j=0;j<count;++j) if((queues[j].queueFlags&VK_QUEUE_COMPUTE_BIT) && queues[j].timestampValidBits) { family=j; found=true; break; }
    if(!found) throw std::runtime_error("No timestamped compute queue");
    float priority=1; VkDeviceQueueCreateInfo qc{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO}; qc.queueFamilyIndex=family; qc.queueCount=1; qc.pQueuePriorities=&priority;
    VkDeviceCreateInfo dc{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO}; dc.pNext=&f12; dc.queueCreateInfoCount=1; dc.pQueueCreateInfos=&qc; dc.enabledExtensionCount=static_cast<uint32_t>(std::size(wanted)); dc.ppEnabledExtensionNames=wanted;
    CHECK(CreateDevice(gpu,&dc,nullptr,&device));
#define LOAD_D(n) n=reinterpret_cast<PFN_vk##n>(GetDeviceProcAddr(device,"vk" #n)); if(!n) throw std::runtime_error("Missing vk" #n);
    DEVICE_FUNCS(LOAD_D)
#undef LOAD_D
    GetDeviceQueue(device,family,0,&queue); GetPhysicalDeviceMemoryProperties(gpu,&memory);
    VkPhysicalDeviceAccelerationStructurePropertiesKHR asp{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ACCELERATION_STRUCTURE_PROPERTIES_KHR}; VkPhysicalDeviceProperties2 p{VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2}; p.pNext=&asp; GetPhysicalDeviceProperties2(gpu,&p); scratchAlignment=asp.minAccelerationStructureScratchOffsetAlignment;
    VkCommandPoolCreateInfo pc{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO}; pc.flags=VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT; pc.queueFamilyIndex=family; CHECK(CreateCommandPool(device,&pc,nullptr,&pool));
    image(output,side,1,VK_FORMAT_R32_SFLOAT,VK_IMAGE_USAGE_STORAGE_BIT|VK_IMAGE_USAGE_SAMPLED_BIT);
    image(alpha,alphaSide,alphaLayers,VK_FORMAT_R8_UNORM,VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT|VK_IMAGE_USAGE_SAMPLED_BIT);
    semaphore(ready,glReady,readyHandle); semaphore(done,glDone,doneHandle);
    // Initial release makes both shared allocations available to OpenGL.
    VkCommandBuffer first=command(); begin(first); barriers(first,false,true); CHECK(EndCommandBuffer(first));
    VkFence initial=newFence(); VkSubmitInfo si{VK_STRUCTURE_TYPE_SUBMIT_INFO}; si.commandBufferCount=1; si.pCommandBuffers=&first; si.signalSemaphoreCount=1; si.pSignalSemaphores=&done;
    CHECK(QueueSubmit(queue,1,&si,initial));
    GLuint images[]={output.texture,alpha.texture}; GLenum layouts[]={0x958D /*LAYOUT_GENERAL_EXT*/,0x958D};
    gl.WaitSemaphore(glDone,0,nullptr,2,images,layouts); glFlush();
    CHECK(WaitForFences(device,1,&initial,VK_TRUE,UINT64_MAX)); DestroyFence(device,initial,nullptr); FreeCommandBuffers(device,pool,1,&first);
    VkSamplerCreateInfo sc{VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO}; sc.magFilter=VK_FILTER_NEAREST; sc.minFilter=VK_FILTER_NEAREST; sc.mipmapMode=VK_SAMPLER_MIPMAP_MODE_NEAREST; sc.addressModeU=sc.addressModeV=sc.addressModeW=VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    CHECK(CreateSampler(device,&sc,nullptr,&sampler));
    std::array<VkDescriptorSetLayoutBinding,10> bindings{};
    VkDescriptorType types[]={VK_DESCRIPTOR_TYPE_ACCELERATION_STRUCTURE_KHR,VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER};
    for(unsigned j=0;j<bindings.size();++j) { bindings[j].binding=j; bindings[j].descriptorType=types[j]; bindings[j].descriptorCount=1; bindings[j].stageFlags=VK_SHADER_STAGE_COMPUTE_BIT; }
    VkDescriptorSetLayoutCreateInfo lc{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO}; lc.bindingCount=uint32_t(bindings.size()); lc.pBindings=bindings.data(); CHECK(CreateDescriptorSetLayout(device,&lc,nullptr,&setLayout));
    VkPipelineLayoutCreateInfo plc{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO}; plc.setLayoutCount=1; plc.pSetLayouts=&setLayout; CHECK(CreatePipelineLayout(device,&plc,nullptr,&pipeLayout));
    std::ifstream stream(shader,std::ios::binary|std::ios::ate); if(!stream) throw std::runtime_error("Missing RTX SPIR-V shader");
    size_t bytes=static_cast<size_t>(stream.tellg()); if(!bytes || bytes%4) throw std::runtime_error("Invalid RTX SPIR-V");
    std::vector<uint32_t> code(bytes/4); stream.seekg(0); stream.read(reinterpret_cast<char*>(code.data()),bytes); if(!stream) throw std::runtime_error("Cannot read RTX SPIR-V");
    VkShaderModuleCreateInfo sm{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO}; sm.codeSize=bytes; sm.pCode=code.data(); VkShaderModule module{}; CHECK(CreateShaderModule(device,&sm,nullptr,&module));
    VkComputePipelineCreateInfo cp{VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO}; cp.layout=pipeLayout; cp.stage={VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO}; cp.stage.stage=VK_SHADER_STAGE_COMPUTE_BIT; cp.stage.module=module; cp.stage.pName="main";
    VkResult result=CreateComputePipelines(device,VK_NULL_HANDLE,1,&cp,nullptr,&pipeline); DestroyShaderModule(device,module,nullptr); CHECK(result);
    uint32_t slots=uint32_t(frames.size());
    VkDescriptorPoolSize sizes[]={{types[0],slots},{types[1],slots*2},{types[2],slots*4},{types[3],slots*3}};
    VkDescriptorPoolCreateInfo dp{VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO}; dp.maxSets=slots; dp.poolSizeCount=4; dp.pPoolSizes=sizes; CHECK(CreateDescriptorPool(device,&dp,nullptr,&descPool));
    VkQueryPoolCreateInfo qp{VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO}; qp.queryType=VK_QUERY_TYPE_TIMESTAMP; qp.queryCount=slots*2; CHECK(CreateQueryPool(device,&qp,nullptr,&queries));
    for(auto& f:frames) {
        f.cmd=command(); f.fence=newFence(true); f.views=buffer(4*sizeof(Zone),VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,true);
        VkDescriptorSetAllocateInfo da{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO}; da.descriptorPool=descPool; da.descriptorSetCount=1; da.pSetLayouts=&setLayout; CHECK(AllocateDescriptorSets(device,&da,&f.set));
    }
}

void Context::build(const float* xyz,uint32_t triangles,const Card* cards,uint32_t count,uint64_t id,const Surface* surfaces) {
    poll(); if(pending) throw std::runtime_error("A BVH build is already pending");
    if(triangles>10000000 || count>1000000 || (triangles && !xyz) || (count && !cards)) throw std::runtime_error("Invalid shadow scene size");
    auto s=std::make_shared<Scene>(); s->c=this; s->id=id; s->triangles=triangles; s->cardCount=count; QueryPerformanceCounter(&s->start);
    // Keep opaque geometry separate: ray traversal never runs alpha tests on walls.
    uint32_t groundCount=0;
    if(surfaces) for(uint32_t i=0;i<triangles;++i) if(surfaces[i].normal[3]<0) ++groundCount;
    uint32_t opaqueCount=std::max(1u,triangles-groundCount), total=opaqueCount+count*2+groundCount;
    s->opaqueCount=opaqueCount;s->groundCount=groundCount;
    auto vertexUsage=VK_BUFFER_USAGE_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_BIT_KHR|VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT;
    s->vertices=buffer(VkDeviceSize(total)*9*sizeof(float),vertexUsage,true);
    float* dst=static_cast<float*>(s->vertices.mapped);
    uint32_t oi=0,gi=opaqueCount+count*2;
    for(uint32_t i=0;i<triangles;++i) {
        uint32_t at=surfaces&&surfaces[i].normal[3]<0?gi++:oi++;
        memcpy(dst+size_t(at)*9,xyz+size_t(i)*9,9*sizeof(float));
    }
    if(!oi) { const float dummy[]={1e7f,1e7f,1e7f,1e7f+2,1e7f,1e7f,1e7f,1e7f+2,1e7f}; memcpy(dst,dummy,sizeof(dummy)); }
    dst+=size_t(opaqueCount)*9;
    const int corners[6][2]={{0,0},{1,0},{1,1},{0,0},{1,1},{0,1}};
    for(uint32_t i=0;i<count;++i) {
        if(cards[i].origin[3]<0 || cards[i].origin[3]>=float(alphaLayers)) throw std::runtime_error("Invalid silhouette layer");
        for(auto& c:corners) for(int a=0;a<3;++a) *dst++=cards[i].origin[a]+float(c[0])*cards[i].u[a]+float(c[1])*cards[i].v[a];
    }
    s->cards=buffer(VkDeviceSize(count)*sizeof(Card),VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,true); if(count) memcpy(s->cards.mapped,cards,size_t(count)*sizeof(Card));
    s->surfaces=buffer(VkDeviceSize(opaqueCount+groundCount)*sizeof(Surface),VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,true);
    memset(s->surfaces.mapped,0,size_t(s->surfaces.size));oi=0;gi=opaqueCount;
    if(surfaces) for(uint32_t i=0;i<triangles;++i)
        static_cast<Surface*>(s->surfaces.mapped)[surfaces[i].normal[3]<0?gi++:oi++]=surfaces[i];
    VkAccelerationStructureGeometryKHR geometries[3]{};
    for(unsigned i=0;i<3;++i) {
        auto& g=geometries[i]; g.sType=VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_KHR; g.geometryType=VK_GEOMETRY_TYPE_TRIANGLES_KHR;
        g.flags=i!=1?VK_GEOMETRY_OPAQUE_BIT_KHR:VK_GEOMETRY_NO_DUPLICATE_ANY_HIT_INVOCATION_BIT_KHR;
        auto& t=g.geometry.triangles; t.sType=VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_TRIANGLES_DATA_KHR;
        t.vertexFormat=VK_FORMAT_R32G32B32_SFLOAT; t.vertexStride=3*sizeof(float); t.indexType=VK_INDEX_TYPE_NONE_KHR;
        t.vertexData.deviceAddress=s->vertices.address+VkDeviceSize(i==2?opaqueCount+count*2:i==1?opaqueCount:0)*9*sizeof(float);
        t.maxVertex=std::max(1u,i==2?groundCount:i==1?count*2:opaqueCount)*3-1;
    }
    uint32_t counts[]={opaqueCount,count*2,groundCount};
    VkAccelerationStructureBuildGeometryInfoKHR bi{VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_BUILD_GEOMETRY_INFO_KHR}; bi.type=VK_ACCELERATION_STRUCTURE_TYPE_BOTTOM_LEVEL_KHR; bi.flags=VK_BUILD_ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT_KHR; bi.mode=VK_BUILD_ACCELERATION_STRUCTURE_MODE_BUILD_KHR; bi.geometryCount=count?2:1; bi.pGeometries=geometries;
    VkAccelerationStructureBuildSizesInfoKHR bs{VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_BUILD_SIZES_INFO_KHR}; GetAccelerationStructureBuildSizesKHR(device,VK_ACCELERATION_STRUCTURE_BUILD_TYPE_DEVICE_KHR,&bi,counts,&bs);
    auto createAS=[&](VkAccelerationStructureTypeKHR type,VkDeviceSize size,Buffer& buf,VkAccelerationStructureKHR& as) {
        buf=buffer(size,VK_BUFFER_USAGE_ACCELERATION_STRUCTURE_STORAGE_BIT_KHR|VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT);
        VkAccelerationStructureCreateInfoKHR ac{VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_CREATE_INFO_KHR}; ac.type=type; ac.buffer=buf.handle; ac.size=size; CHECK(CreateAccelerationStructureKHR(device,&ac,nullptr,&as));
    };
    createAS(bi.type,bs.accelerationStructureSize,s->blasBuffer,s->blas);
    VkAccelerationStructureBuildGeometryInfoKHR gb=bi;gb.geometryCount=1;gb.pGeometries=&geometries[2];
    VkAccelerationStructureBuildSizesInfoKHR gs{VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_BUILD_SIZES_INFO_KHR};
    if(groundCount){
        GetAccelerationStructureBuildSizesKHR(device,VK_ACCELERATION_STRUCTURE_BUILD_TYPE_DEVICE_KHR,&gb,&groundCount,&gs);
        createAS(gb.type,gs.accelerationStructureSize,s->groundBuffer,s->groundBlas);
    }
    VkAccelerationStructureDeviceAddressInfoKHR addr{VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_DEVICE_ADDRESS_INFO_KHR}; addr.accelerationStructure=s->blas;
    VkAccelerationStructureInstanceKHR inst[2]{}; inst[0].transform.matrix[0][0]=inst[0].transform.matrix[1][1]=inst[0].transform.matrix[2][2]=1; inst[0].mask=1; inst[0].flags=VK_GEOMETRY_INSTANCE_TRIANGLE_FACING_CULL_DISABLE_BIT_KHR; inst[0].accelerationStructureReference=GetAccelerationStructureDeviceAddressKHR(device,&addr);
    if(groundCount){inst[1]=inst[0];inst[1].mask=2;inst[1].instanceCustomIndex=opaqueCount;addr.accelerationStructure=s->groundBlas;inst[1].accelerationStructureReference=GetAccelerationStructureDeviceAddressKHR(device,&addr);}
    uint32_t instanceCount=groundCount?2:1;
    s->instances=buffer(sizeof(inst[0])*instanceCount,vertexUsage,true); memcpy(s->instances.mapped,inst,sizeof(inst[0])*instanceCount);
    VkAccelerationStructureGeometryKHR tg{VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_KHR}; tg.geometryType=VK_GEOMETRY_TYPE_INSTANCES_KHR; tg.geometry.instances.sType=VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_INSTANCES_DATA_KHR; tg.geometry.instances.data.deviceAddress=s->instances.address;
    VkAccelerationStructureBuildGeometryInfoKHR ti{VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_BUILD_GEOMETRY_INFO_KHR}; ti.type=VK_ACCELERATION_STRUCTURE_TYPE_TOP_LEVEL_KHR; ti.flags=bi.flags; ti.mode=bi.mode; ti.geometryCount=1; ti.pGeometries=&tg;
    VkAccelerationStructureBuildSizesInfoKHR ts{VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_BUILD_SIZES_INFO_KHR}; GetAccelerationStructureBuildSizesKHR(device,VK_ACCELERATION_STRUCTURE_BUILD_TYPE_DEVICE_KHR,&ti,&instanceCount,&ts);
    createAS(ti.type,ts.accelerationStructureSize,s->tlasBuffer,s->tlas);
    s->scratch=buffer(std::max({bs.buildScratchSize,ts.buildScratchSize,gs.buildScratchSize})+scratchAlignment,VK_BUFFER_USAGE_STORAGE_BUFFER_BIT|VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT);
    VkDeviceAddress scratch=(s->scratch.address+scratchAlignment-1)&~VkDeviceAddress(scratchAlignment-1);
    bi.dstAccelerationStructure=s->blas; bi.scratchData.deviceAddress=scratch; ti.dstAccelerationStructure=s->tlas; ti.scratchData.deviceAddress=scratch;
    gb.dstAccelerationStructure=s->groundBlas;gb.scratchData.deviceAddress=scratch;
    s->cmd=command(); s->fence=newFence(); begin(s->cmd);
    VkAccelerationStructureBuildRangeInfoKHR ranges[3]{}; ranges[0].primitiveCount=opaqueCount; ranges[1].primitiveCount=count*2;ranges[2].primitiveCount=groundCount;
    const VkAccelerationStructureBuildRangeInfoKHR* rp=ranges; CmdBuildAccelerationStructuresKHR(s->cmd,1,&bi,&rp);
    VkMemoryBarrier barrier{VK_STRUCTURE_TYPE_MEMORY_BARRIER}; barrier.srcAccessMask=VK_ACCESS_ACCELERATION_STRUCTURE_WRITE_BIT_KHR; barrier.dstAccessMask=VK_ACCESS_ACCELERATION_STRUCTURE_READ_BIT_KHR|VK_ACCESS_ACCELERATION_STRUCTURE_WRITE_BIT_KHR;
    CmdPipelineBarrier(s->cmd,VK_PIPELINE_STAGE_ACCELERATION_STRUCTURE_BUILD_BIT_KHR,VK_PIPELINE_STAGE_ACCELERATION_STRUCTURE_BUILD_BIT_KHR,0,1,&barrier,0,nullptr,0,nullptr);
    if(groundCount){rp=&ranges[2];CmdBuildAccelerationStructuresKHR(s->cmd,1,&gb,&rp);
        CmdPipelineBarrier(s->cmd,VK_PIPELINE_STAGE_ACCELERATION_STRUCTURE_BUILD_BIT_KHR,VK_PIPELINE_STAGE_ACCELERATION_STRUCTURE_BUILD_BIT_KHR,0,1,&barrier,0,nullptr,0,nullptr);}
    VkAccelerationStructureBuildRangeInfoKHR tr{}; tr.primitiveCount=instanceCount; rp=&tr; CmdBuildAccelerationStructuresKHR(s->cmd,1,&ti,&rp);
    barrier.dstAccessMask=VK_ACCESS_ACCELERATION_STRUCTURE_READ_BIT_KHR; CmdPipelineBarrier(s->cmd,VK_PIPELINE_STAGE_ACCELERATION_STRUCTURE_BUILD_BIT_KHR,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,0,1,&barrier,0,nullptr,0,nullptr);
    CHECK(EndCommandBuffer(s->cmd)); VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO}; submit.commandBufferCount=1; submit.pCommandBuffers=&s->cmd; CHECK(QueueSubmit(queue,1,&submit,s->fence)); pending=s; ++stats.builds;
}
void Context::poll() {
    if(!pending) return; VkResult r=GetFenceStatus(device,pending->fence); if(r==VK_NOT_READY) return; CHECK(r);
    LARGE_INTEGER now,freq; QueryPerformanceCounter(&now); QueryPerformanceFrequency(&freq);
    stats.buildMs=1000.0*double(now.QuadPart-pending->start.QuadPart)/double(freq.QuadPart);
    // CPU and scratch copies are not part of the resident cache.
    destroy(pending->vertices); destroy(pending->instances); destroy(pending->scratch);
    active=std::move(pending); stats.sceneId=active->id; stats.triangles=active->triangles; stats.cards=active->cardCount;
    stats.bytes=output.size+alpha.size+active->cards.size+active->surfaces.size+active->blasBuffer.size+active->groundBuffer.size+active->tlasBuffer.size;
}
bool Context::trace(const Zone* zones,uint64_t expectedScene) {
    // Scene selection is committed by stats/Prepare, never halfway through a
    // frame after the caller has already rebased its light/camera matrices.
    if(pending && pending->id==expectedScene) poll();
    if(!active || active->id!=expectedScene) return false;
    Frame& f=acquireFrame();
    if(f.submitted) {
        uint64_t stamps[2]{}; VkResult q=GetQueryPoolResults(device,queries,frameIndex*2,2,sizeof(stamps),stamps,sizeof(uint64_t),VK_QUERY_RESULT_64_BIT);
        if(q==VK_SUCCESS) { double ms=double(stamps[1]-stamps[0])*props.limits.timestampPeriod/1e6; if(f.reflection) reflectionMs=ms; else stats.traceMs=ms; }
        else if(q!=VK_NOT_READY) CHECK(q);
    }
    f.scene=active; memcpy(f.views.mapped,zones,4*sizeof(Zone));
    VkWriteDescriptorSetAccelerationStructureKHR as{VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET_ACCELERATION_STRUCTURE_KHR}; as.accelerationStructureCount=1; as.pAccelerationStructures=&active->tlas;
    VkDescriptorImageInfo oi{VK_NULL_HANDLE,output.view,VK_IMAGE_LAYOUT_GENERAL},ai{sampler,alpha.view,VK_IMAGE_LAYOUT_GENERAL};
    VkDescriptorBufferInfo cb{active->cards.handle,0,active->cards.size},vb{f.views.handle,0,4*sizeof(Zone)};
    VkDescriptorType types[]={VK_DESCRIPTOR_TYPE_ACCELERATION_STRUCTURE_KHR,VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,VK_DESCRIPTOR_TYPE_STORAGE_BUFFER};
    VkWriteDescriptorSet writes[5]{}; for(unsigned j=0;j<5;++j) { auto& w=writes[j]; w.sType=VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET; w.dstSet=f.set; w.dstBinding=j; w.descriptorCount=1; w.descriptorType=types[j]; }
    writes[0].pNext=&as; writes[1].pImageInfo=&oi; writes[2].pImageInfo=&ai; writes[3].pBufferInfo=&cb; writes[4].pBufferInfo=&vb;
    UpdateDescriptorSets(device,5,writes,0,nullptr); CHECK(ResetCommandBuffer(f.cmd,0)); begin(f.cmd);
    barriers(f.cmd,true); CmdResetQueryPool(f.cmd,queries,frameIndex*2,2); CmdWriteTimestamp(f.cmd,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,queries,frameIndex*2);
    CmdBindPipeline(f.cmd,VK_PIPELINE_BIND_POINT_COMPUTE,pipeline); CmdBindDescriptorSets(f.cmd,VK_PIPELINE_BIND_POINT_COMPUTE,pipeLayout,0,1,&f.set,0,nullptr); CmdDispatch(f.cmd,(side+7)/8,(side+7)/8,1);
    CmdWriteTimestamp(f.cmd,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,queries,frameIndex*2+1); barriers(f.cmd,false); CHECK(EndCommandBuffer(f.cmd));
    CHECK(ResetFences(device,1,&f.fence));
    handoff(f.cmd,f.fence);
    f.submitted=true;f.reflection=false; frameIndex=(frameIndex+1)%unsigned(frames.size()); ++stats.frames; return true;
}
void Context::handoff(VkCommandBuffer cmd,VkFence fence) {
    GLuint images[]={output.texture,alpha.texture,reflectionNormal.texture,reflectionDepth.texture,reflectionOutput.texture,reflectionAtlas.texture};
    GLenum layouts[]={0x958D,0x958D,0x958D,0x958D,0x958D,0x958D}; GLuint count=reflectionWidth?6:2;
    gl.SignalSemaphore(glReady,0,nullptr,count,images,layouts); glFlush();
    VkPipelineStageFlags wait=VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT;
    VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO}; submit.waitSemaphoreCount=1; submit.pWaitSemaphores=&ready; submit.pWaitDstStageMask=&wait; submit.commandBufferCount=1; submit.pCommandBuffers=&cmd; submit.signalSemaphoreCount=1; submit.pSignalSemaphores=&done;
    CHECK(QueueSubmit(queue,1,&submit,fence));
    gl.WaitSemaphore(glDone,0,nullptr,count,images,layouts);
}
Scene::~Scene() {
    if(!c || !c->device) return;
    if(blas) c->DestroyAccelerationStructureKHR(c->device,blas,nullptr);
    if(groundBlas) c->DestroyAccelerationStructureKHR(c->device,groundBlas,nullptr);
    if(tlas) c->DestroyAccelerationStructureKHR(c->device,tlas,nullptr);
    c->destroy(vertices); c->destroy(cards);c->destroy(surfaces); c->destroy(blasBuffer);c->destroy(groundBuffer); c->destroy(tlasBuffer); c->destroy(scratch); c->destroy(instances);
    if(fence) c->DestroyFence(c->device,fence,nullptr); if(cmd) c->FreeCommandBuffers(c->device,c->pool,1,&cmd);
}
Context::~Context() {
    // Lifecycle only. Rendering uses GPU semaphores and polls, never glFinish.
    if(device && DeviceWaitIdle) { glFinish(); DeviceWaitIdle(device); }
    pending.reset(); active.reset();
    for(auto& f:frames) { f.scene.reset(); if(device && DestroyBuffer) destroy(f.views); if(f.fence) DestroyFence(device,f.fence,nullptr); }
    if(device && DestroyImage) { destroy(output); destroy(alpha);destroy(reflectionNormal);destroy(reflectionDepth);destroy(reflectionOutput);destroy(reflectionAtlas); }
    if(glReady) gl.DeleteSemaphores(1,&glReady); if(glDone) gl.DeleteSemaphores(1,&glDone);
    if(readyHandle) CloseHandle(readyHandle); if(doneHandle) CloseHandle(doneHandle);
    if(ready) DestroySemaphore(device,ready,nullptr); if(done) DestroySemaphore(device,done,nullptr);
    if(queries) DestroyQueryPool(device,queries,nullptr); if(sampler) DestroySampler(device,sampler,nullptr);
    if(descPool) DestroyDescriptorPool(device,descPool,nullptr); if(pipeline) DestroyPipeline(device,pipeline,nullptr);
    if(reflectionPipeline) DestroyPipeline(device,reflectionPipeline,nullptr);
    if(pipeLayout) DestroyPipelineLayout(device,pipeLayout,nullptr); if(setLayout) DestroyDescriptorSetLayout(device,setLayout,nullptr);
    if(pool) DestroyCommandPool(device,pool,nullptr);
    if(device && DestroyDevice) DestroyDevice(device,nullptr); if(instance && DestroyInstance) DestroyInstance(instance,nullptr);
    if(loader) FreeLibrary(loader);
}
#include "reflections.inc"
API uint32_t __cdecl rzrt_version() { return 4; }
API uint32_t __cdecl rzrt_ground_triangles(Context* c) { return c&&c->active?c->active->groundCount:0; }
API uint64_t __cdecl rzrt_frame_waits(Context* c) { return c?c->busyFrames:0; }
API const char* __cdecl rzrt_error() { return error.c_str(); }
API void* __cdecl rzrt_create(const wchar_t* shader,uint32_t side,uint32_t alphaSide,uint32_t layers) {
    try { error.clear(); auto c=std::make_unique<Context>(); c->init(shader,side,alphaSide,layers); return c.release(); }
    catch(const std::exception& e) { error=e.what(); return nullptr; }
}
API void __cdecl rzrt_destroy(Context* c) { delete c; }
API const char* __cdecl rzrt_device(Context* c) { return c?c->name.c_str():""; }
API GLuint __cdecl rzrt_output(Context* c) { return c?c->output.texture:0; }
API GLuint __cdecl rzrt_alpha(Context* c) { return c?c->alpha.texture:0; }
API int __cdecl rzrt_scene(Context* c,const float* xyz,uint32_t triangles,const Card* cards,uint32_t count,uint64_t id) {
    try { if(!c) throw std::runtime_error("No RTX context"); c->build(xyz,triangles,cards,count,id); return 1; }
    catch(const std::exception& e) { error=e.what(); return 0; }
}
API int __cdecl rzrt_scene_materials(Context* c,const float* xyz,uint32_t triangles,const Card* cards,uint32_t count,uint64_t id,const Surface* surfaces) {
    try { if(!c) throw std::runtime_error("No RTX context");c->build(xyz,triangles,cards,count,id,surfaces);return 1; }
    catch(const std::exception& e) { error=e.what();return 0; }
}
API int __cdecl rzrt_trace(Context* c,const Zone* zones,uint64_t expectedScene) {
    try { if(!c || !zones) throw std::runtime_error("No RTX context/views"); return c->trace(zones,expectedScene)?1:0; }
    catch(const std::exception& e) { error=e.what(); return -1; }
}
API int __cdecl rzrt_stats(Context* c,Stats* s) {
    try { if(!c || !s) throw std::runtime_error("No RTX context/stats"); c->poll(); *s=c->stats;
        s->bytes+=c->reflectionNormal.size+c->reflectionDepth.size+c->reflectionOutput.size+c->reflectionAtlas.size;return 1; }
    catch(const std::exception& e) { error=e.what(); return 0; }
}
