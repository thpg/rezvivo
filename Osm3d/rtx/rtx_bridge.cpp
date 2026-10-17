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
#include <map>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>
#include <cstdlib>
#include <cmath>

#define API extern "C" __declspec(dllexport)
#define CHECK(x) do { VkResult checkedVkResult=(x); if(checkedVkResult!=VK_SUCCESS) throw std::runtime_error(std::string(#x)+": "+std::to_string(checkedVkResult)); } while(0)
static thread_local std::string error;
// Internal ablation switches. Captured once per context, never read per pixel/frame.
static bool renderOption(const char* name,bool fallback=true) {
    char value[16]{};const auto n=GetEnvironmentVariableA(name,value,sizeof(value));
    return n && n<sizeof(value)?strcmp(value,"0")!=0:fallback;
}
enum ImageMask : uint32_t {
    AtlasImages=3, ReflectionImages=2|4|8|16|32,
    ScreenImages=2|64|128|512, AllImages=1023,
    ReflectionAllocation=4|8|16|32, ScreenAllocation=64|128|256|512, ReadOnlyImages=2|32
};
struct Card { float origin[4], u[4], v[4], spare[4]; };
struct Zone { float origin[4], du[4], dv[4], ray[4]; };
struct Surface { float normal[4],color[4],uv0[4],uv1[4],uv2[4]; };
struct CompactSurface { float normal[4],color[4]; };
struct SurfaceUV { float uv0[4],uv1[4],uv2[4]; };
struct SurfaceReference { uint64_t surface,uv; uint32_t offset,count,pad[2]; };
static_assert(sizeof(CompactSurface)==32 && sizeof(SurfaceReference)==32,"Reflection chunk layout");
struct ReflectionCamera { float invProjection[16],invView[16],sun[4],horizon[4],zenith[4],depthRange[4]; };
struct ScreenCamera {ReflectionCamera camera;float solarU[4],solarV[4],disk[8][4];};
static_assert(sizeof(ScreenCamera)==352,"Screen constants layout");
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
    void (APIENTRY *GenBuffers)(GLsizei,GLuint*);
    void (APIENTRY *DeleteBuffers)(GLsizei,const GLuint*);
    void (APIENTRY *BindBuffer)(GLenum,GLuint);
    void (APIENTRY *BufferStorageMem)(GLenum,intptr_t,GLuint,uint64_t);
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
        load(GenBuffers,"glGenBuffers");load(DeleteBuffers,"glDeleteBuffers");
        load(BindBuffer,"glBindBuffer");load(BufferStorageMem,"glBufferStorageMemEXT");
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
 X(QueueSubmit) X(CmdPipelineBarrier) X(CmdCopyBuffer) X(CreateShaderModule) X(DestroyShaderModule) \
 X(CreateDescriptorSetLayout) X(DestroyDescriptorSetLayout) X(CreatePipelineLayout) X(DestroyPipelineLayout) \
 X(CreateComputePipelines) X(DestroyPipeline) X(CreateDescriptorPool) X(DestroyDescriptorPool) \
 X(AllocateDescriptorSets) X(UpdateDescriptorSets) X(CmdBindPipeline) X(CmdBindDescriptorSets) X(CmdDispatch) \
 X(CreateAccelerationStructureKHR) X(DestroyAccelerationStructureKHR) X(GetAccelerationStructureBuildSizesKHR) \
 X(GetAccelerationStructureDeviceAddressKHR) X(CmdBuildAccelerationStructuresKHR) \
 X(CmdWriteAccelerationStructuresPropertiesKHR) X(CmdCopyAccelerationStructureKHR) \
 X(CreateQueryPool) X(DestroyQueryPool) X(CmdResetQueryPool) X(CmdWriteTimestamp) X(GetQueryPoolResults)

struct Buffer { VkBuffer handle{}; VkDeviceMemory memory{}; void* mapped{}; VkDeviceSize size{}; VkDeviceAddress address{}; uint32_t memoryType{}; VkDeviceSize allocated{}; VkBufferUsageFlags usage{}; };
struct Image { VkImage handle{}; VkImageView view{}; VkDeviceMemory memory{}; GLuint texture{},glMemory{}; uint32_t layers{},memoryType{}; VkDeviceSize size{}; HANDLE exported{}; };
struct Context;
// Public ABI: Pascal packed record, Vulkan row-major affine transform.
struct DynamicActorInput {
    uint32_t firstVertex,vertexCount,firstIndex,indexCount;
    uint64_t topology;
    VkTransformMatrixKHR transform;
};
static_assert(sizeof(DynamicActorInput)==72,"Dynamic actor ABI");
struct DynamicActor {
    Buffer blasBuffer,scratch;
    VkAccelerationStructureKHR blas{};
    uint32_t capacity{},builtCount{};
    uint64_t builtTopology{},revision{},builtRevision{};
};
struct DynamicScene {
    Buffer vertices,indices,blasBuffer,tlasBuffer,scratch,tlasScratch,instances,actorRefs;
    VkAccelerationStructureKHR blas{},tlas{};
    GLuint glBuffer{},glMemory{};HANDLE exported{};
    GLuint glIndices{},glIndexMemory{};HANDLE exportedIndices{};
    uint32_t capacity{},count{},builtCount{},instanceCapacity{};
    uint32_t vertexCapacity{},vertexCount{};bool indexed{};
    uint64_t topology{},builtTopology{};
    uint32_t builtInstances{};uint64_t sceneId{};
    std::vector<DynamicActorInput> actorInputs;
    std::vector<DynamicActor> actors;
    bool builtLocal{};
};
struct Scene {
    Context* c{}; VkAccelerationStructureKHR blas{},groundBlas{},tlas{};
    Buffer vertices,cards,surfaces,surfaceUV,surfaceRefs,blasBuffer,groundBuffer,tlasBuffer,scratch,instances;
    std::vector<Buffer> uploads;
    Buffer compactBuffer,compactGroundBuffer;
    VkAccelerationStructureKHR compactBlas{},compactGround{};VkQueryPool compactQuery{};
    VkCommandBuffer cmd{}; VkFence fence{};
    uint64_t id{},triangles{},cardCount{}; uint32_t opaqueCount{},groundCount{},groundOffset{}; LARGE_INTEGER start{};
    std::vector<std::shared_ptr<Scene>> parts;
    std::vector<VkAccelerationStructureInstanceKHR> rayInstances;
    size_t staticCount{};
    bool inputsReleased{},submitted{};
    ~Scene();
};
struct Frame {
    VkCommandBuffer cmd{}; VkFence fence{}; VkDescriptorSet set{}; Buffer views; DynamicScene dynamic;
    std::shared_ptr<Scene> scene; bool submitted{},reflection{},screen{};
    std::array<std::array<uint64_t,5>,13> descriptorKeys{};uint32_t descriptorValid{};uint64_t descriptorGeneration{};
};
struct Context {
    bool diagnostic{renderOption("REZVIVO_RENDER_DIAGNOSTICS",false)};
    bool passResources{renderOption("REZVIVO_RTX_PASS_RESOURCES")};
    bool retainReadOnly{renderOption("REZVIVO_RTX_RETAIN_ATLASES")};uint32_t retainedImages{};
    bool deviceMaterials{renderOption("REZVIVO_RTX_DEVICE_MATERIALS")};
    bool descriptorCache{renderOption("REZVIVO_RTX_DESCRIPTOR_CACHE")};
    bool flushAfterSignal{renderOption("REZVIVO_RTX_EXTRA_FLUSH",false)};
    bool sharedFilter{renderOption("REZVIVO_RTX_FILTER_SHARED")};
    bool directHardShadow{renderOption("REZVIVO_RTX_HARD_DIRECT")};
    bool removeInitialStore{renderOption("REZVIVO_RTX_SKIP_ZERO_STORE")};
    bool solarConstants{renderOption("REZVIVO_RTX_SOLAR_CONSTANTS")};
    std::array<float,5> solarKey{};bool solarReady{};ScreenCamera solarData{};
    HMODULE loader{}; VkInstance instance{}; VkPhysicalDevice gpu{}; VkDevice device{}; VkQueue queue{}; uint32_t family{};
    VkPhysicalDeviceMemoryProperties memory{}; VkPhysicalDeviceProperties props{}; uint32_t scratchAlignment{256};
    PFN_vkGetInstanceProcAddr GetInstanceProcAddr{};
#define DECL(n) PFN_vk##n n{};
    INSTANCE_FUNCS(DECL) DEVICE_FUNCS(DECL)
#undef DECL
    GLInterop gl{}; Image output,alpha; VkSemaphore ready{},done{}; GLuint glReady{},glDone{}; HANDLE readyHandle{},doneHandle{};
    VkCommandPool pool{}; VkDescriptorSetLayout setLayout{}; VkPipelineLayout pipeLayout{}; VkPipeline pipeline{};
    VkDescriptorPool descPool{}; VkSampler sampler{},screenAlphaSampler{}; VkQueryPool queries{};
    VkQueryPool stageQueries{};std::array<double,4> stageMs{};
    std::array<uint64_t,VK_MAX_MEMORY_TYPES> allocatedByType{};
    uint64_t uploadBytes{},hashBytesCount{},descriptorWrites{},descriptorSkipped{},handoffImages{};
    uint64_t resourceGeneration{1};
    double handoffSubmitMs{};
    std::array<Frame,6> frames{}; unsigned frameIndex{}; uint32_t side{},alphaSide{},alphaLayers{};
    std::shared_ptr<Scene> active,pending,assembling,uploading; Stats stats{}; std::string name;
    uint32_t uploadCapacity{},uploadGroundCapacity{},uploadUVCapacity{},uploadUVCount{},uploadOpaque{},uploadGround{};
    std::array<uint64_t,2> uploadHash{};
    std::map<std::array<uint64_t,2>,std::weak_ptr<Scene>> meshCache;
    std::map<uint64_t,std::weak_ptr<Scene>> identityCache;uint64_t uploadIdentity{},earlyMeshReuses{};
    uint64_t meshBuilds{},meshReuses{},staticReuses{},uploadedTriangles{},peakBuildBytes{};
    uint64_t compactedMeshes{},compactionSavedBytes{};
    Image reflectionNormal,reflectionDepth,reflectionOutput,reflectionAtlas;
    VkPipeline reflectionPipeline{}; uint32_t reflectionWidth{},reflectionHeight{};
    double reflectionMs{}; uint64_t reflectionFrames{},busyFrames{};
    Image screenDepth,screenOutput,screenSamples,screenReuse;VkPipeline screenPipeline{},screenFilterPipeline{},screenHardPipeline{};
    uint32_t screenWidth{},screenHeight{};double screenMs{};uint64_t screenFrames{};
    bool screenSupported{};
    bool dynamicPrepared{};
    uint32_t dynamicTriangles{};uint64_t dynamicBuilds{},dynamicRefits{};
    uint64_t dynamicTopBuilds{},dynamicTopRefits{},dynamicSkips{};
    GLuint dynamicBuffer(uint32_t triangles,uint32_t vertices=0,uint64_t topology=0,GLuint* indexBuffer=nullptr,uint32_t* indicesDirty=nullptr);
    void dynamicActors(const DynamicActorInput* actors,uint32_t count);
    void dynamicActorRevisions(const uint64_t* revisions,uint32_t count);
    void dynamicTopCapacity(DynamicScene& d,uint32_t required);
    void destroyActor(DynamicActor& actor);
    Buffer sharedBuffer(VkDeviceSize size,VkBufferUsageFlags usage,GLuint& glBuffer,GLuint& glMemory,HANDLE& exported);
    void destroyDynamic(DynamicScene& d);
    void buildDynamic(Frame& f);
    void readTiming(Frame& f);
    void updateDescriptors(Frame& f,const VkWriteDescriptorSet* writes,uint32_t count);
    void prepareSolar(Frame& f,const ReflectionCamera& camera);
    void stageStamp(Frame& f,uint32_t stage,VkPipelineStageFlagBits at=VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT) {
        if(stageQueries)CmdWriteTimestamp(f.cmd,at,stageQueries,frameIndex*5+stage);
    }
    uint32_t passMask(uint32_t mask) const {return passResources?mask:AllImages;}
    void stageImmutable(Scene& s,Buffer& data,VkCommandBuffer cmd);
    void uploadBarrier(VkCommandBuffer cmd);
    void beginImageWrite(uint32_t mask);
    void dynamicBarrier(VkCommandBuffer cmd,DynamicScene& d,bool acquire);
    void screenSize(const wchar_t* shader,uint32_t width,uint32_t height);
    bool screenTrace(const ReflectionCamera* camera,uint64_t expectedScene);
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
    uint32_t hostMemoryType(uint32_t bits,VkDeviceSize size) {
        const auto flags=VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT|VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
        // Large staging/build inputs must not fill a small CPU-visible VRAM
        // aperture. Camera/actor records are tiny; integrated/UMA memory is
        // intentionally kept direct. Immutable arrays migrate after staging.
        if(deviceMaterials&&size>65536&&props.deviceType==VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU)
            for(uint32_t i=0;i<memory.memoryTypeCount;++i)
                if((bits&(1u<<i))&&(memory.memoryTypes[i].propertyFlags&flags)==flags&&
                   !(memory.memoryTypes[i].propertyFlags&VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT))return i;
        return memoryType(bits,flags);
    }
    Buffer buffer(VkDeviceSize size,VkBufferUsageFlags usage,bool host=false) {
        Buffer b; b.size=std::max<VkDeviceSize>(size,16);
        b.usage=usage|(host?VK_BUFFER_USAGE_TRANSFER_SRC_BIT:0);
        VkBufferCreateInfo info{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO}; info.size=b.size; info.usage=b.usage;
        CHECK(CreateBuffer(device,&info,nullptr,&b.handle));
        ++resourceGeneration;
        VkMemoryRequirements req; GetBufferMemoryRequirements(device,b.handle,&req);
        VkMemoryAllocateFlagsInfo flags{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_FLAGS_INFO};
        flags.flags=(usage&VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT)?VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT:0;
        VkMemoryAllocateInfo alloc{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO}; alloc.pNext=&flags; alloc.allocationSize=req.size;
        alloc.memoryTypeIndex=host?hostMemoryType(req.memoryTypeBits,b.size):memoryType(req.memoryTypeBits,VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
        try {
            CHECK(AllocateMemory(device,&alloc,nullptr,&b.memory));
            b.memoryType=alloc.memoryTypeIndex;b.allocated=alloc.allocationSize;allocatedByType[b.memoryType]+=b.allocated;
            CHECK(BindBufferMemory(device,b.handle,b.memory,0));
            if(host) CHECK(MapMemory(device,b.memory,0,b.size,0,&b.mapped));
            if(flags.flags) { VkBufferDeviceAddressInfo ai{VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO}; ai.buffer=b.handle; b.address=GetBufferDeviceAddress(device,&ai); }
        } catch(...) { destroy(b); throw; }
        return b;
    }
    void destroy(Buffer& b) {
        if(b.mapped) UnmapMemory(device,b.memory);
        if(b.handle) {DestroyBuffer(device,b.handle,nullptr);++resourceGeneration;}
        if(b.memory) {allocatedByType[b.memoryType]-=b.allocated;FreeMemory(device,b.memory,nullptr);} b={};
    }
    void destroy(Image& i) {
        if(i.texture) glDeleteTextures(1,&i.texture);
        if(i.glMemory) gl.DeleteMemoryObjects(1,&i.glMemory);
        if(i.exported) CloseHandle(i.exported);
        if(i.view) {DestroyImageView(device,i.view,nullptr);++resourceGeneration;}
        if(i.handle) DestroyImage(device,i.handle,nullptr);
        if(i.memory){allocatedByType[i.memoryType]-=i.size;FreeMemory(device,i.memory,nullptr);} i={};
    }
    void image(Image& out,uint32_t size,uint32_t layers,VkFormat format,VkImageUsageFlags usage,uint32_t height=0,bool shared=true);
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
    void barriers(VkCommandBuffer cmd,bool acquire,bool initial=false,uint32_t mask=AllImages) {
        Image* images[]={&output,&alpha,&reflectionNormal,&reflectionDepth,&reflectionOutput,&reflectionAtlas,&screenDepth,&screenOutput,&screenSamples,&screenReuse};
        VkImageMemoryBarrier b[10]{};uint32_t count=0;
        for(int k=0;k<10;++k) {
            if(!images[k]->handle || !(mask&(1u<<k)))continue;
            const bool shared=images[k]->texture!=0;
            if(!initial && !shared)continue;
            if(!initial && ((acquire&&(retainedImages&(1u<<k)))||
               (!acquire&&retainReadOnly&&(ReadOnlyImages&(1u<<k)))))continue;
            auto& v=b[count++];v.sType=VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
            v.srcAccessMask=initial||acquire?0:VK_ACCESS_SHADER_READ_BIT|VK_ACCESS_SHADER_WRITE_BIT;
            v.dstAccessMask=acquire?VK_ACCESS_SHADER_READ_BIT|VK_ACCESS_SHADER_WRITE_BIT:0;
            v.oldLayout=initial?VK_IMAGE_LAYOUT_UNDEFINED:VK_IMAGE_LAYOUT_GENERAL;v.newLayout=VK_IMAGE_LAYOUT_GENERAL;
            v.srcQueueFamilyIndex=shared?(acquire?VK_QUEUE_FAMILY_EXTERNAL:family):VK_QUEUE_FAMILY_IGNORED;
            v.dstQueueFamilyIndex=shared?(acquire?family:VK_QUEUE_FAMILY_EXTERNAL):VK_QUEUE_FAMILY_IGNORED;
            if(initial&&!shared)v.dstAccessMask=VK_ACCESS_SHADER_READ_BIT|VK_ACCESS_SHADER_WRITE_BIT;
            v.image=images[k]->handle;v.subresourceRange={VkImageAspectFlags(k==3||k==6?VK_IMAGE_ASPECT_DEPTH_BIT:VK_IMAGE_ASPECT_COLOR_BIT),0,1,0,images[k]->layers};
        }
        CmdPipelineBarrier(cmd,acquire||initial?VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT:VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            acquire||initial?VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT:VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,0,0,nullptr,0,nullptr,count,b);
    }
    void poll();
    void sceneBegin(bool reuseStatic);
    void meshBegin(uint32_t capacity,uint32_t uvCapacity,uint32_t groundCapacity,uint64_t identity=0);
    bool meshReuse(uint64_t identity);
    void meshAppend(const float* xyz,uint32_t triangles,const Surface* surfaces);
    void meshEnd();
    void finishPart(const std::shared_ptr<Scene>& s);
    void sceneChunk(const float* xyz,uint32_t triangles,const Surface* surfaces);
    void sceneCommit(const Card* cards,uint32_t count,uint64_t id);
    void buildTop(const std::shared_ptr<Scene>& s);
    std::shared_ptr<Scene> buildPart(const float* xyz,uint32_t triangles,const Card* cards,uint32_t count,const Surface* surfaces);
    void releaseBuildInputs(Scene& s);
    uint64_t sceneBytes(const Scene& s) const;
    void build(const float* xyz,uint32_t triangles,const Card* cards,uint32_t count,uint64_t id,const Surface* surfaces=nullptr);
    bool trace(const Zone* zones,uint64_t expectedScene);
    void reflectionSize(const wchar_t* shader,uint32_t width,uint32_t height);
    bool reflect(const ReflectionCamera* camera,uint64_t expectedScene);
    void handoff(VkCommandBuffer cmd,VkFence fence,GLuint buffer=0,uint32_t mask=AllImages,GLuint indices=0);
};

void Context::image(Image& out,uint32_t size,uint32_t layers,VkFormat format,VkImageUsageFlags usage,uint32_t height,bool shared) {
    if(!height) height=size;
    out.layers=layers;
    VkExternalMemoryImageCreateInfo ext{VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO}; ext.handleTypes=VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_WIN32_BIT;
    VkImageCreateInfo i{VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO}; i.pNext=shared?&ext:nullptr; i.imageType=VK_IMAGE_TYPE_2D; i.format=format;
    i.extent={size,height,1}; i.mipLevels=1; i.arrayLayers=layers; i.samples=VK_SAMPLE_COUNT_1_BIT; i.tiling=VK_IMAGE_TILING_OPTIMAL; i.usage=usage;
    CHECK(CreateImage(device,&i,nullptr,&out.handle));
    VkMemoryRequirements req; GetImageMemoryRequirements(device,out.handle,&req); out.size=req.size;
    VkExportMemoryWin32HandleInfoKHR win{VK_STRUCTURE_TYPE_EXPORT_MEMORY_WIN32_HANDLE_INFO_KHR}; win.dwAccess=GENERIC_ALL;
    VkExportMemoryAllocateInfo exp{VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO}; exp.handleTypes=ext.handleTypes; exp.pNext=&win;
    VkMemoryDedicatedAllocateInfo dedicated{VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO}; dedicated.pNext=shared?&exp:nullptr; dedicated.image=out.handle;
    VkMemoryAllocateInfo a{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO}; a.pNext=&dedicated; a.allocationSize=req.size; a.memoryTypeIndex=memoryType(req.memoryTypeBits,VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    CHECK(AllocateMemory(device,&a,nullptr,&out.memory));out.memoryType=a.memoryTypeIndex;allocatedByType[out.memoryType]+=out.size;
    CHECK(BindImageMemory(device,out.handle,out.memory,0));
    VkImageViewCreateInfo v{VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO}; v.image=out.handle; v.viewType=layers==1?VK_IMAGE_VIEW_TYPE_2D:VK_IMAGE_VIEW_TYPE_2D_ARRAY;
    v.format=format; v.subresourceRange={VkImageAspectFlags(format==VK_FORMAT_D32_SFLOAT?VK_IMAGE_ASPECT_DEPTH_BIT:VK_IMAGE_ASPECT_COLOR_BIT),0,1,0,layers}; CHECK(CreateImageView(device,&v,nullptr,&out.view));
    ++resourceGeneration;
    if(!shared)return;
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
    GLenum glFormat=format==VK_FORMAT_R8_UNORM?0x8229:format==VK_FORMAT_D32_SFLOAT?0x8CAC:format==VK_FORMAT_R16G16_SFLOAT?0x822F:format==VK_FORMAT_R32G32_SFLOAT?0x8230:format==VK_FORMAT_R16G16B16A16_SFLOAT?0x881A:format==VK_FORMAT_R8G8B8A8_UNORM?0x8058:0x822E;
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
    screenSupported=f2.features.shaderStorageImageExtendedFormats!=0;
    VkPhysicalDeviceFeatures features{};features.shaderStorageImageExtendedFormats=screenSupported;
    // Enable only features used by this bridge.
    f12={VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES}; f12.pNext=&as; f12.bufferDeviceAddress=VK_TRUE;
    as={VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ACCELERATION_STRUCTURE_FEATURES_KHR}; as.pNext=&rq; as.accelerationStructure=VK_TRUE;
    rq={VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_RAY_QUERY_FEATURES_KHR}; rq.rayQuery=VK_TRUE;
    GetPhysicalDeviceQueueFamilyProperties(gpu,&count,nullptr); std::vector<VkQueueFamilyProperties> queues(count); GetPhysicalDeviceQueueFamilyProperties(gpu,&count,queues.data());
    bool found=false;
    for(uint32_t j=0;j<count;++j) if((queues[j].queueFlags&VK_QUEUE_COMPUTE_BIT) && queues[j].timestampValidBits) { family=j; found=true; break; }
    if(!found) throw std::runtime_error("No timestamped compute queue");
    float priority=1; VkDeviceQueueCreateInfo qc{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO}; qc.queueFamilyIndex=family; qc.queueCount=1; qc.pQueuePriorities=&priority;
    VkDeviceCreateInfo dc{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO}; dc.pNext=&f12; dc.pEnabledFeatures=&features; dc.queueCreateInfoCount=1; dc.pQueueCreateInfos=&qc; dc.enabledExtensionCount=static_cast<uint32_t>(std::size(wanted)); dc.ppEnabledExtensionNames=wanted;
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
    sc.magFilter=VK_FILTER_LINEAR;sc.minFilter=VK_FILTER_LINEAR;
    CHECK(CreateSampler(device,&sc,nullptr,&screenAlphaSampler));
    std::array<VkDescriptorSetLayoutBinding,13> bindings{};
    VkDescriptorType types[]={VK_DESCRIPTOR_TYPE_ACCELERATION_STRUCTURE_KHR,VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,
        VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,VK_DESCRIPTOR_TYPE_STORAGE_BUFFER};
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
    VkDescriptorPoolSize sizes[]={{types[0],slots},{types[1],slots*2},{types[2],slots*5},{types[3],slots*5}};
    VkDescriptorPoolCreateInfo dp{VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO}; dp.maxSets=slots; dp.poolSizeCount=4; dp.pPoolSizes=sizes; CHECK(CreateDescriptorPool(device,&dp,nullptr,&descPool));
    VkQueryPoolCreateInfo qp{VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO}; qp.queryType=VK_QUERY_TYPE_TIMESTAMP; qp.queryCount=slots*2; CHECK(CreateQueryPool(device,&qp,nullptr,&queries));
    if(diagnostic){qp.queryCount=slots*5;CHECK(CreateQueryPool(device,&qp,nullptr,&stageQueries));}
    for(auto& f:frames) {
        f.cmd=command(); f.fence=newFence(true); f.views=buffer(std::max(4*sizeof(Zone),sizeof(ScreenCamera)),VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,true);
        VkDescriptorSetAllocateInfo da{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO}; da.descriptorPool=descPool; da.descriptorSetCount=1; da.pSetLayouts=&setLayout; CHECK(AllocateDescriptorSets(device,&da,&f.set));
    }
}

#include "static_scene.inc"
template<class T> static uint64_t handleBits(T handle) {uint64_t bits{};static_assert(sizeof(handle)<=sizeof(bits),"Handle width");memcpy(&bits,&handle,sizeof(handle));return bits;}
void Context::updateDescriptors(Frame& f,const VkWriteDescriptorSet* writes,uint32_t count) {
    if(f.descriptorGeneration!=resourceGeneration){f.descriptorValid=0;f.descriptorGeneration=resourceGeneration;}
    VkWriteDescriptorSet changed[13]{};uint32_t n=0;
    if(count>13)throw std::runtime_error("Too many RTX descriptor writes");
    for(uint32_t i=0;i<count;++i){
        const auto& w=writes[i];std::array<uint64_t,5> key{};key[0]=w.descriptorType;
        if(w.dstBinding>=f.descriptorKeys.size()||w.descriptorCount!=1)
            throw std::runtime_error("Invalid RTX descriptor binding");
        if(w.pImageInfo){const auto& v=*w.pImageInfo;key[1]=handleBits(v.sampler);key[2]=handleBits(v.imageView);key[3]=v.imageLayout;}
        else if(w.pBufferInfo){const auto& v=*w.pBufferInfo;key[1]=handleBits(v.buffer);key[2]=v.offset;key[3]=v.range;}
        else if(w.descriptorType==VK_DESCRIPTOR_TYPE_ACCELERATION_STRUCTURE_KHR){
            const auto* v=static_cast<const VkWriteDescriptorSetAccelerationStructureKHR*>(w.pNext);key[1]=handleBits(*v->pAccelerationStructures);}
        else throw std::runtime_error("Unexpected RTX descriptor type");
        const auto bit=1u<<w.dstBinding;
        if(!descriptorCache||!(f.descriptorValid&bit)||f.descriptorKeys[w.dstBinding]!=key){
            changed[n++]=w;f.descriptorKeys[w.dstBinding]=key;f.descriptorValid|=bit;
        }else ++descriptorSkipped;
    }
    if(n)UpdateDescriptorSets(device,n,changed,0,nullptr);descriptorWrites+=n;
}
void Context::readTiming(Frame& f) {
    if(!f.submitted)return;
    uint64_t stamps[2]{};
    VkResult q=GetQueryPoolResults(device,queries,frameIndex*2,2,sizeof(stamps),stamps,sizeof(uint64_t),VK_QUERY_RESULT_64_BIT);
    if(q==VK_SUCCESS){
        const double ms=double(stamps[1]-stamps[0])*props.limits.timestampPeriod/1e6;
        if(f.screen)screenMs=ms;else if(f.reflection)reflectionMs=ms;else stats.traceMs=ms;
    }else if(q!=VK_NOT_READY)CHECK(q);
    if(stageQueries&&f.screen){
        uint64_t stages[5]{};
        q=GetQueryPoolResults(device,stageQueries,frameIndex*5,5,sizeof(stages),stages,sizeof(uint64_t),VK_QUERY_RESULT_64_BIT);
        if(q==VK_SUCCESS)for(unsigned n=0;n<4;++n)stageMs[n]=double(stages[n+1]-stages[n])*props.limits.timestampPeriod/1e6;
        else if(q!=VK_NOT_READY)CHECK(q);
    }
}
bool Context::trace(const Zone* zones,uint64_t expectedScene) {
    // Scene selection is committed by stats/Prepare, never halfway through a
    // frame after the caller has already rebased its light/camera matrices.
    if(pending && pending->id==expectedScene) poll();
    if(!active || active->id!=expectedScene) return false;
    Frame& f=acquireFrame();
    readTiming(f);
    f.scene=active; memcpy(f.views.mapped,zones,4*sizeof(Zone));
    VkWriteDescriptorSetAccelerationStructureKHR as{VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET_ACCELERATION_STRUCTURE_KHR}; as.accelerationStructureCount=1; as.pAccelerationStructures=&active->tlas;
    VkDescriptorImageInfo oi{VK_NULL_HANDLE,output.view,VK_IMAGE_LAYOUT_GENERAL},ai{sampler,alpha.view,VK_IMAGE_LAYOUT_GENERAL};
    VkDescriptorBufferInfo cb{active->parts.back()->cards.handle,0,active->parts.back()->cards.size},vb{f.views.handle,0,4*sizeof(Zone)};
    VkDescriptorType types[]={VK_DESCRIPTOR_TYPE_ACCELERATION_STRUCTURE_KHR,VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,VK_DESCRIPTOR_TYPE_STORAGE_BUFFER};
    VkWriteDescriptorSet writes[5]{}; for(unsigned j=0;j<5;++j) { auto& w=writes[j]; w.sType=VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET; w.dstSet=f.set; w.dstBinding=j; w.descriptorCount=1; w.descriptorType=types[j]; }
    writes[0].pNext=&as; writes[1].pImageInfo=&oi; writes[2].pImageInfo=&ai; writes[3].pBufferInfo=&cb; writes[4].pBufferInfo=&vb;
    updateDescriptors(f,writes,5); CHECK(ResetCommandBuffer(f.cmd,0)); begin(f.cmd);
    barriers(f.cmd,true,false,passMask(AtlasImages)); CmdResetQueryPool(f.cmd,queries,frameIndex*2,2); CmdWriteTimestamp(f.cmd,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,queries,frameIndex*2);
    CmdBindPipeline(f.cmd,VK_PIPELINE_BIND_POINT_COMPUTE,pipeline); CmdBindDescriptorSets(f.cmd,VK_PIPELINE_BIND_POINT_COMPUTE,pipeLayout,0,1,&f.set,0,nullptr); CmdDispatch(f.cmd,(side+7)/8,(side+7)/8,1);
    CmdWriteTimestamp(f.cmd,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,queries,frameIndex*2+1); barriers(f.cmd,false,false,passMask(AtlasImages)); CHECK(EndCommandBuffer(f.cmd));
    CHECK(ResetFences(device,1,&f.fence));
    handoff(f.cmd,f.fence,0,passMask(AtlasImages));
    f.submitted=true;f.reflection=false;f.screen=false; frameIndex=(frameIndex+1)%unsigned(frames.size()); ++stats.frames; return true;
}
void Context::handoff(VkCommandBuffer cmd,VkFence fence,GLuint buffer,uint32_t mask,GLuint indices) {
    LARGE_INTEGER started{};if(diagnostic)QueryPerformanceCounter(&started);
    GLuint textures[]={output.texture,alpha.texture,reflectionNormal.texture,reflectionDepth.texture,reflectionOutput.texture,reflectionAtlas.texture,screenDepth.texture,screenOutput.texture,screenSamples.texture,screenReuse.texture};
    GLuint images[10]{},returned[10]{},count=0,returnCount=0;GLenum layouts[10]{},returnLayouts[10]{};
    for(unsigned k=0;k<10;++k)if(textures[k]&&(mask&(1u<<k))){
        if(!(retainedImages&(1u<<k))){images[count]=textures[k];layouts[count++]=0x958D;}
        if(!retainReadOnly||!(ReadOnlyImages&(1u<<k))){returned[returnCount]=textures[k];returnLayouts[returnCount++]=0x958D;}
    }
    GLuint buffers[]={buffer,indices};const GLuint bufferCount=buffer?(indices?2u:1u):0u;
    gl.SignalSemaphore(glReady,bufferCount,buffers,count,images,layouts);
    // EXT_external_objects 4.2.4: SignalSemaphoreEXT already flushes the stream.
    if(flushAfterSignal)glFlush();
    VkPipelineStageFlags wait=VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
    VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO}; submit.waitSemaphoreCount=1; submit.pWaitSemaphores=&ready; submit.pWaitDstStageMask=&wait; submit.commandBufferCount=1; submit.pCommandBuffers=&cmd; submit.signalSemaphoreCount=1; submit.pSignalSemaphores=&done;
    CHECK(QueueSubmit(queue,1,&submit,fence));
    gl.WaitSemaphore(glDone,bufferCount,buffers,returnCount,returned,returnLayouts);
    if(retainReadOnly)retainedImages|=mask&ReadOnlyImages;
    handoffImages+=count+returnCount;
    if(diagnostic){LARGE_INTEGER end{},freq{};QueryPerformanceCounter(&end);QueryPerformanceFrequency(&freq);
        handoffSubmitMs=1000.*double(end.QuadPart-started.QuadPart)/double(freq.QuadPart);}
}
void Context::beginImageWrite(uint32_t mask){
    mask&=retainedImages&ReadOnlyImages;if(!mask)return;
    Frame& f=acquireFrame();readTiming(f);f.submitted=false;f.scene.reset();
    CHECK(ResetCommandBuffer(f.cmd,0));begin(f.cmd);
    Image* images[]={&alpha,&reflectionAtlas};const uint32_t bits[]={2,32};
    VkImageMemoryBarrier b[2]{};GLuint textures[2]{};GLenum layouts[2]{};uint32_t count=0;
    for(unsigned i=0;i<2;++i)if(mask&bits[i]){
        auto& v=b[count];v.sType=VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        v.srcAccessMask=VK_ACCESS_SHADER_READ_BIT;v.oldLayout=v.newLayout=VK_IMAGE_LAYOUT_GENERAL;
        v.srcQueueFamilyIndex=family;v.dstQueueFamilyIndex=VK_QUEUE_FAMILY_EXTERNAL;
        v.image=images[i]->handle;v.subresourceRange={VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,images[i]->layers};
        textures[count]=images[i]->texture;layouts[count++]=0x958D;
    }
    CmdPipelineBarrier(f.cmd,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,0,0,nullptr,0,nullptr,count,b);
    CHECK(EndCommandBuffer(f.cmd));CHECK(ResetFences(device,1,&f.fence));
    // Flush the previously queued GL wait on the shared binary `done`
    // semaphore before signaling it again. A Vulkan fence alone does not prove
    // that GL has consumed that signal. The ready wait establishes that order
    // without a CPU wait or transferring unrelated images back to Vulkan.
    gl.SignalSemaphore(glReady,0,nullptr,0,nullptr,nullptr);
    VkPipelineStageFlags wait=VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
    VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
    submit.waitSemaphoreCount=1;submit.pWaitSemaphores=&ready;submit.pWaitDstStageMask=&wait;
    submit.commandBufferCount=1;submit.pCommandBuffers=&f.cmd;
    submit.signalSemaphoreCount=1;submit.pSignalSemaphores=&done;CHECK(QueueSubmit(queue,1,&submit,f.fence));
    gl.WaitSemaphore(glDone,0,nullptr,count,textures,layouts);
    retainedImages&=~mask;frameIndex=(frameIndex+1)%unsigned(frames.size());
}
Scene::~Scene() {
    if(!c || !c->device) return;
    // A cancelled collection may still have a BLAS build in flight. Published
    // scenes are also retained by every frame that references them.
    if(submitted && fence) c->WaitForFences(c->device,1,&fence,VK_TRUE,UINT64_MAX);
    if(blas) c->DestroyAccelerationStructureKHR(c->device,blas,nullptr);
    if(groundBlas) c->DestroyAccelerationStructureKHR(c->device,groundBlas,nullptr);
    if(tlas) c->DestroyAccelerationStructureKHR(c->device,tlas,nullptr);
    if(compactBlas)c->DestroyAccelerationStructureKHR(c->device,compactBlas,nullptr);
    if(compactGround)c->DestroyAccelerationStructureKHR(c->device,compactGround,nullptr);
    if(compactQuery)c->DestroyQueryPool(c->device,compactQuery,nullptr);
    c->destroy(compactBuffer);c->destroy(compactGroundBuffer);
    c->destroy(vertices); c->destroy(cards);c->destroy(surfaces);c->destroy(surfaceUV);c->destroy(surfaceRefs);
    for(auto& upload:uploads)c->destroy(upload);
    c->destroy(blasBuffer);c->destroy(groundBuffer); c->destroy(tlasBuffer); c->destroy(scratch); c->destroy(instances);
    if(fence) c->DestroyFence(c->device,fence,nullptr); if(cmd) c->FreeCommandBuffers(c->device,c->pool,1,&cmd);
}
Context::~Context() {
    // Lifecycle only. Rendering uses GPU semaphores and polls, never glFinish.
    if(device && DeviceWaitIdle) { glFinish(); DeviceWaitIdle(device); }
    uploading.reset();assembling.reset();pending.reset(); active.reset();meshCache.clear();
    for(auto& f:frames) { f.scene.reset(); if(device && DestroyBuffer) {destroyDynamic(f.dynamic);destroy(f.views);} if(f.fence) DestroyFence(device,f.fence,nullptr); }
    if(device && DestroyImage) { destroy(output); destroy(alpha);destroy(reflectionNormal);destroy(reflectionDepth);destroy(reflectionOutput);destroy(reflectionAtlas);destroy(screenDepth);destroy(screenOutput);destroy(screenSamples);destroy(screenReuse); }
    if(glReady) gl.DeleteSemaphores(1,&glReady); if(glDone) gl.DeleteSemaphores(1,&glDone);
    if(readyHandle) CloseHandle(readyHandle); if(doneHandle) CloseHandle(doneHandle);
    if(ready) DestroySemaphore(device,ready,nullptr); if(done) DestroySemaphore(device,done,nullptr);
    if(queries) DestroyQueryPool(device,queries,nullptr); if(sampler) DestroySampler(device,sampler,nullptr);
    if(stageQueries)DestroyQueryPool(device,stageQueries,nullptr);
    if(screenAlphaSampler) DestroySampler(device,screenAlphaSampler,nullptr);
    if(descPool) DestroyDescriptorPool(device,descPool,nullptr); if(pipeline) DestroyPipeline(device,pipeline,nullptr);
    if(reflectionPipeline) DestroyPipeline(device,reflectionPipeline,nullptr);
    if(screenPipeline) DestroyPipeline(device,screenPipeline,nullptr);
    if(screenFilterPipeline) DestroyPipeline(device,screenFilterPipeline,nullptr);
    if(screenHardPipeline)DestroyPipeline(device,screenHardPipeline,nullptr);
    if(pipeLayout) DestroyPipelineLayout(device,pipeLayout,nullptr); if(setLayout) DestroyDescriptorSetLayout(device,setLayout,nullptr);
    if(pool) DestroyCommandPool(device,pool,nullptr);
    if(device && DestroyDevice) DestroyDevice(device,nullptr); if(instance && DestroyInstance) DestroyInstance(instance,nullptr);
    if(loader) FreeLibrary(loader);
}
#include "reflections.inc"
#include "dynamic_scene.inc"
#include "screen_shadows.inc"
API uint32_t __cdecl rzrt_version() { return 11; }
API uint32_t __cdecl rzrt_ground_triangles(Context* c) { return c&&c->active?c->active->groundCount:0; }
API uint64_t __cdecl rzrt_frame_waits(Context* c) { return c?c->busyFrames:0; }
API int __cdecl rzrt_image_write(Context* c,uint32_t image){try{if(!c||image>1)throw std::runtime_error("Invalid RTX image write");c->beginImageWrite(image==0?2:32);return 1;}catch(const std::exception& e){error=e.what();return 0;}}
API double __cdecl rzrt_stage_ms(Context* c,uint32_t stage) {return !c?0:stage<4?c->stageMs[stage]:stage==4?c->handoffSubmitMs:0;}
API uint64_t __cdecl rzrt_diagnostic(Context* c,uint32_t field) {
    if(!c)return 0;
    if(field==0)return c->diagnostic;if(field==1)return c->uploadBytes;if(field==2)return c->hashBytesCount;
    if(field==3)return c->descriptorWrites;if(field==4)return c->descriptorSkipped;if(field==5)return c->handoffImages;
    if(field>=32&&field<32+VK_MAX_MEMORY_TYPES)return c->allocatedByType[field-32];
    if(field>=64&&field<64+c->memory.memoryTypeCount)return c->memory.memoryTypes[field-64].propertyFlags;
    if(field>=96&&field<96+c->memory.memoryTypeCount)return c->memory.memoryTypes[field-96].heapIndex;
    if(field==6)return c->memory.memoryTypeCount;return 0;
}
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
        s->bytes+=c->reflectionNormal.size+c->reflectionDepth.size+c->reflectionOutput.size+c->reflectionAtlas.size+c->screenDepth.size+c->screenOutput.size+c->screenSamples.size+c->screenReuse.size;return 1; }
    catch(const std::exception& e) { error=e.what(); return 0; }
}
