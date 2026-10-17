Buffer Context::sharedBuffer(VkDeviceSize size,VkBufferUsageFlags usage,GLuint& glBuffer,GLuint& glMemory,HANDLE& exported) {
    Buffer result;
    try {
    VkExternalMemoryBufferCreateInfo external{VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_BUFFER_CREATE_INFO};
    external.handleTypes=VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_WIN32_BIT;
    VkBufferCreateInfo bc{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};bc.pNext=&external;
    bc.size=size;bc.usage=usage|VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
    CHECK(CreateBuffer(device,&bc,nullptr,&result.handle));result.size=bc.size;
    ++resourceGeneration;
    VkMemoryRequirements req;GetBufferMemoryRequirements(device,result.handle,&req);
    VkMemoryDedicatedAllocateInfo dedicated{VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO};dedicated.buffer=result.handle;
    VkExportMemoryWin32HandleInfoKHR win{VK_STRUCTURE_TYPE_EXPORT_MEMORY_WIN32_HANDLE_INFO_KHR};win.dwAccess=GENERIC_ALL;win.pNext=&dedicated;
    VkExportMemoryAllocateInfo exp{VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO};exp.handleTypes=external.handleTypes;exp.pNext=&win;
    VkMemoryAllocateFlagsInfo flags{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_FLAGS_INFO};flags.flags=VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT;flags.pNext=&exp;
    VkMemoryAllocateInfo alloc{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};alloc.pNext=&flags;alloc.allocationSize=req.size;
    alloc.memoryTypeIndex=memoryType(req.memoryTypeBits,VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    CHECK(AllocateMemory(device,&alloc,nullptr,&result.memory));
    result.memoryType=alloc.memoryTypeIndex;result.allocated=alloc.allocationSize;allocatedByType[result.memoryType]+=result.allocated;
    CHECK(BindBufferMemory(device,result.handle,result.memory,0));
    VkBufferDeviceAddressInfo address{VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO};address.buffer=result.handle;
    result.address=GetBufferDeviceAddress(device,&address);
    VkMemoryGetWin32HandleInfoKHR hi{VK_STRUCTURE_TYPE_MEMORY_GET_WIN32_HANDLE_INFO_KHR};hi.memory=result.memory;hi.handleType=VK_EXTERNAL_MEMORY_HANDLE_TYPE_OPAQUE_WIN32_BIT;
    CHECK(GetMemoryWin32HandleKHR(device,&hi,&exported));gl.CreateMemoryObjects(1,&glMemory);
    GLint yes=GL_TRUE;gl.MemoryObjectParameteriv(glMemory,0x9581,&yes);
    gl.ImportMemoryWin32Handle(glMemory,req.size,0x9587,exported);
    GLint old{};glGetIntegerv(0x90D3 /*SHADER_STORAGE_BUFFER_BINDING*/,&old);
    gl.GenBuffers(1,&glBuffer);gl.BindBuffer(0x90D2,glBuffer);gl.BufferStorageMem(0x90D2,intptr_t(bc.size),glMemory,0);gl.BindBuffer(0x90D2,old);
    if(glGetError())throw std::runtime_error("GL/Vulkan posed mesh buffer import failed");
    return result;
    }catch(...){
        if(glBuffer)gl.DeleteBuffers(1,&glBuffer);glBuffer=0;
        if(glMemory)gl.DeleteMemoryObjects(1,&glMemory);glMemory=0;
        if(exported)CloseHandle(exported);exported=nullptr;
        destroy(result);throw;
    }
}
// Posed GL vertex buffers -> shared GPU triangles -> refitted ray-query BLAS.
// Each in-flight frame owns its input and AS. No animated mesh CPU readback.
static VkAccelerationStructureGeometryKHR dynamicGeometry(const DynamicScene& d) {
    VkAccelerationStructureGeometryKHR g{VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_KHR};
    g.geometryType=VK_GEOMETRY_TYPE_TRIANGLES_KHR;g.flags=VK_GEOMETRY_OPAQUE_BIT_KHR;
    auto& t=g.geometry.triangles;t.sType=VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_TRIANGLES_DATA_KHR;
    // XYZ plus one packed smooth normal, also consumed by screen shadows.
    t.vertexFormat=VK_FORMAT_R32G32B32_SFLOAT;t.vertexStride=16;t.indexType=d.indexed?VK_INDEX_TYPE_UINT32:VK_INDEX_TYPE_NONE_KHR;
    if(d.indexed)t.indexData.deviceAddress=d.indices.address;
    // Two vectors before the vertices hold their conservative GPU AABB.
    t.vertexData.deviceAddress=d.vertices.address+32;t.maxVertex=d.vertexCapacity-1;return g;
}
static VkAccelerationStructureGeometryKHR actorGeometry(const DynamicScene& d,const DynamicActorInput& actor) {
    auto g=dynamicGeometry(d);auto& t=g.geometry.triangles;
    t.vertexData.deviceAddress+=VkDeviceSize(actor.firstVertex)*16;
    t.indexData.deviceAddress+=VkDeviceSize(actor.firstIndex)*4;
    t.maxVertex=actor.vertexCount-1;return g;
}
static VkAccelerationStructureBuildGeometryInfoKHR dynamicBuildInfo() {
    VkAccelerationStructureBuildGeometryInfoKHR b{VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_BUILD_GEOMETRY_INFO_KHR};
    b.type=VK_ACCELERATION_STRUCTURE_TYPE_BOTTOM_LEVEL_KHR;
    b.flags=VK_BUILD_ACCELERATION_STRUCTURE_PREFER_FAST_BUILD_BIT_KHR|VK_BUILD_ACCELERATION_STRUCTURE_ALLOW_UPDATE_BIT_KHR;
    b.mode=VK_BUILD_ACCELERATION_STRUCTURE_MODE_BUILD_KHR;b.geometryCount=1;return b;
}
void Context::destroyActor(DynamicActor& actor) {
    if(actor.blas)DestroyAccelerationStructureKHR(device,actor.blas,nullptr);
    destroy(actor.blasBuffer);destroy(actor.scratch);actor={};
}
void Context::destroyDynamic(DynamicScene& d) {
    if(d.glBuffer)gl.DeleteBuffers(1,&d.glBuffer);
    if(d.glMemory)gl.DeleteMemoryObjects(1,&d.glMemory);
    if(d.exported)CloseHandle(d.exported);
    if(d.glIndices)gl.DeleteBuffers(1,&d.glIndices);
    if(d.glIndexMemory)gl.DeleteMemoryObjects(1,&d.glIndexMemory);
    if(d.exportedIndices)CloseHandle(d.exportedIndices);
    if(d.blas)DestroyAccelerationStructureKHR(device,d.blas,nullptr);
    if(d.tlas)DestroyAccelerationStructureKHR(device,d.tlas,nullptr);
    for(auto& actor:d.actors)destroyActor(actor);
    destroy(d.actorRefs);
    destroy(d.vertices);destroy(d.indices);destroy(d.blasBuffer);destroy(d.tlasBuffer);destroy(d.scratch);destroy(d.tlasScratch);destroy(d.instances);d={};
}
GLuint Context::dynamicBuffer(uint32_t triangles,uint32_t vertices,uint64_t topology,GLuint* indexBuffer,uint32_t* indicesDirty) {
    if(triangles>4000000)throw std::runtime_error("Dynamic RTX geometry exceeds its budget");
    const bool indexed=indexBuffer!=nullptr;
    if(!indexed)vertices=triangles*3;
    if((triangles&&!vertices)||vertices>12000000)throw std::runtime_error("Invalid dynamic RTX vertex count");
    if(indexBuffer)*indexBuffer=0;if(indicesDirty)*indicesDirty=0;
    Frame& f=acquireFrame();dynamicPrepared=true;dynamicTriangles=triangles;
    DynamicScene& d=f.dynamic;
    bool reallocated=false;
    if(triangles && (triangles>d.capacity || vertices>d.vertexCapacity || d.indexed!=indexed)) {
        destroyDynamic(d);d.capacity=16384;while(d.capacity<triangles)d.capacity*=2;
        d.vertexCapacity=16384;while(d.vertexCapacity<vertices)d.vertexCapacity*=2;d.indexed=indexed;reallocated=true;
        auto usage=VK_BUFFER_USAGE_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_BIT_KHR|VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT;
        d.vertices=sharedBuffer(32+VkDeviceSize(d.vertexCapacity)*16,usage,d.glBuffer,d.glMemory,d.exported);
        if(indexed)d.indices=sharedBuffer(VkDeviceSize(d.capacity)*12,usage,d.glIndices,d.glIndexMemory,d.exportedIndices);
        auto g=dynamicGeometry(d);auto b=dynamicBuildInfo();b.pGeometries=&g;
        VkAccelerationStructureBuildSizesInfoKHR bs{VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_BUILD_SIZES_INFO_KHR};
        GetAccelerationStructureBuildSizesKHR(device,VK_ACCELERATION_STRUCTURE_BUILD_TYPE_DEVICE_KHR,&b,&d.capacity,&bs);
        auto create=[&](VkAccelerationStructureTypeKHR type,VkDeviceSize size,Buffer& buffer,VkAccelerationStructureKHR& as) {
            buffer=this->buffer(size,VK_BUFFER_USAGE_ACCELERATION_STRUCTURE_STORAGE_BIT_KHR|VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT);
            VkAccelerationStructureCreateInfoKHR ac{VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_CREATE_INFO_KHR};ac.type=type;ac.buffer=buffer.handle;ac.size=size;
            CHECK(CreateAccelerationStructureKHR(device,&ac,nullptr,&as));
        };
        create(b.type,bs.accelerationStructureSize,d.blasBuffer,d.blas);
        d.scratch=buffer(std::max(bs.buildScratchSize,bs.updateScratchSize)+scratchAlignment,VK_BUFFER_USAGE_STORAGE_BUFFER_BIT|VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT);
    }
    d.actorInputs.clear();
    if(triangles)dynamicTopCapacity(d,active?uint32_t(active->rayInstances.size()+1):1);
    if(indexBuffer)*indexBuffer=triangles?d.glIndices:0;
    if(indicesDirty)*indicesDirty=reallocated||d.topology!=topology;
    d.topology=topology;d.vertexCount=vertices;
    d.count=triangles;return triangles?d.glBuffer:0;
}
void Context::dynamicTopCapacity(DynamicScene& d,uint32_t required) {
    if(required>d.instanceCapacity) {
        if(d.tlas)DestroyAccelerationStructureKHR(device,d.tlas,nullptr);
        d.tlas={};destroy(d.tlasBuffer);destroy(d.tlasScratch);destroy(d.instances);
        d.builtInstances=0;d.sceneId=0;
        d.instanceCapacity=8;while(d.instanceCapacity<required)d.instanceCapacity*=2;
        auto usage=VK_BUFFER_USAGE_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_BIT_KHR|VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT;
        d.instances=buffer(VkDeviceSize(d.instanceCapacity)*sizeof(VkAccelerationStructureInstanceKHR),usage,true);
        VkAccelerationStructureGeometryKHR tg{VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_KHR};tg.geometryType=VK_GEOMETRY_TYPE_INSTANCES_KHR;
        tg.geometry.instances.sType=VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_INSTANCES_DATA_KHR;tg.geometry.instances.data.deviceAddress=d.instances.address;
        auto ti=dynamicBuildInfo();ti.type=VK_ACCELERATION_STRUCTURE_TYPE_TOP_LEVEL_KHR;
        ti.flags=VK_BUILD_ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT_KHR|VK_BUILD_ACCELERATION_STRUCTURE_ALLOW_UPDATE_BIT_KHR;ti.pGeometries=&tg;
        VkAccelerationStructureBuildSizesInfoKHR ts{VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_BUILD_SIZES_INFO_KHR};
        GetAccelerationStructureBuildSizesKHR(device,VK_ACCELERATION_STRUCTURE_BUILD_TYPE_DEVICE_KHR,&ti,&d.instanceCapacity,&ts);
        d.tlasBuffer=buffer(ts.accelerationStructureSize,VK_BUFFER_USAGE_ACCELERATION_STRUCTURE_STORAGE_BIT_KHR|VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT);
        VkAccelerationStructureCreateInfoKHR ac{VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_CREATE_INFO_KHR};
        ac.type=ti.type;ac.buffer=d.tlasBuffer.handle;ac.size=ts.accelerationStructureSize;
        CHECK(CreateAccelerationStructureKHR(device,&ac,nullptr,&d.tlas));
        d.tlasScratch=buffer(std::max(ts.buildScratchSize,ts.updateScratchSize)+scratchAlignment,VK_BUFFER_USAGE_STORAGE_BUFFER_BIT|VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT);
    }
}
void Context::dynamicActors(const DynamicActorInput* actors,uint32_t count) {
    if(!dynamicPrepared||count>128||(count&&!actors))throw std::runtime_error("Invalid dynamic actor input");
    auto& d=frames[frameIndex].dynamic;
    if(count&&!d.indexed)throw std::runtime_error("Local RTX actors require indices");
    // Validate the complete partition before modifying frame state. No overlaps,
    // holes or uninitialized transformed vertices may reach the acceleration structure.
    uint32_t firstV=0,firstI=0;
    for(uint32_t i=0;i<count;++i){
        const auto& a=actors[i];
        if(!a.vertexCount||!a.indexCount||a.indexCount%3||a.firstVertex!=firstV||a.firstIndex!=firstI||
            uint64_t(a.firstVertex)+a.vertexCount>d.vertexCount||uint64_t(a.firstIndex)+a.indexCount>uint64_t(d.count)*3)
            throw std::runtime_error("Invalid dynamic actor partition");
        for(auto& row:a.transform.matrix)for(float x:row)if(!std::isfinite(x))throw std::runtime_error("Non-finite dynamic actor transform");
        firstV+=a.vertexCount;firstI+=a.indexCount;
    }
    if(count&&(firstV!=d.vertexCount||firstI!=d.count*3))throw std::runtime_error("Incomplete dynamic actor partition");
    d.actorInputs.clear();if(count)d.actorInputs.assign(actors,actors+count);
    for(size_t i=count;i<d.actors.size();++i)destroyActor(d.actors[i]);
    d.actors.resize(count);
    if(!count)return;
    dynamicTopCapacity(d,uint32_t(active?active->rayInstances.size():0)+count);
    if(d.actorRefs.size<count*16){destroy(d.actorRefs);d.actorRefs=buffer(128*16,VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,true);}
    auto* refs=static_cast<uint32_t*>(d.actorRefs.mapped);
    for(uint32_t i=0;i<count;++i){
        const auto& input=d.actorInputs[i];auto& actor=d.actors[i];uint32_t triangles=input.indexCount/3;
        actor.revision=0;
        refs[i*4]=input.firstVertex;refs[i*4+1]=input.firstIndex;refs[i*4+2]=refs[i*4+3]=0;
        if(triangles<=actor.capacity)continue;
        destroyActor(actor);actor.capacity=1024;while(actor.capacity<triangles)actor.capacity*=2;
        auto g=actorGeometry(d,input);auto b=dynamicBuildInfo();b.pGeometries=&g;
        VkAccelerationStructureBuildSizesInfoKHR bs{VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_BUILD_SIZES_INFO_KHR};
        GetAccelerationStructureBuildSizesKHR(device,VK_ACCELERATION_STRUCTURE_BUILD_TYPE_DEVICE_KHR,&b,&actor.capacity,&bs);
        actor.blasBuffer=buffer(bs.accelerationStructureSize,VK_BUFFER_USAGE_ACCELERATION_STRUCTURE_STORAGE_BIT_KHR|VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT);
        VkAccelerationStructureCreateInfoKHR ac{VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_CREATE_INFO_KHR};
        ac.type=b.type;ac.buffer=actor.blasBuffer.handle;ac.size=bs.accelerationStructureSize;
        CHECK(CreateAccelerationStructureKHR(device,&ac,nullptr,&actor.blas));
        actor.scratch=buffer(std::max(bs.buildScratchSize,bs.updateScratchSize)+scratchAlignment,VK_BUFFER_USAGE_STORAGE_BUFFER_BIT|VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT);
    }
}
void Context::dynamicActorRevisions(const uint64_t* revisions,uint32_t count){
    if(!dynamicPrepared||!revisions||count!=frames[frameIndex].dynamic.actors.size())throw std::runtime_error("Invalid dynamic actor revisions");
    auto& actors=frames[frameIndex].dynamic.actors;
    for(uint32_t i=0;i<count;++i)actors[i].revision=revisions[i];
}
void Context::dynamicBarrier(VkCommandBuffer cmd,DynamicScene& d,bool acquire) {
    if(!d.count)return;
    VkBufferMemoryBarrier b[2]{};const uint32_t count=d.indexed?2:1;
    for(uint32_t i=0;i<count;++i){
        auto& v=b[i];v.sType=VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER;
        v.srcAccessMask=acquire?0:VK_ACCESS_ACCELERATION_STRUCTURE_READ_BIT_KHR|VK_ACCESS_SHADER_READ_BIT;
        v.dstAccessMask=acquire?VK_ACCESS_ACCELERATION_STRUCTURE_READ_BIT_KHR|VK_ACCESS_SHADER_READ_BIT:0;
        v.srcQueueFamilyIndex=acquire?VK_QUEUE_FAMILY_EXTERNAL:family;v.dstQueueFamilyIndex=acquire?family:VK_QUEUE_FAMILY_EXTERNAL;
        v.buffer=i?d.indices.handle:d.vertices.handle;v.size=VK_WHOLE_SIZE;
    }
    auto readers=VK_PIPELINE_STAGE_ACCELERATION_STRUCTURE_BUILD_BIT_KHR|VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT;
    CmdPipelineBarrier(cmd,acquire?VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT:readers,
        acquire?readers:VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT,0,0,nullptr,count,b,0,nullptr);
}
void Context::buildDynamic(Frame& f) {
    DynamicScene& d=f.dynamic;
    if(!d.count){stageStamp(f,1,VK_PIPELINE_STAGE_ACCELERATION_STRUCTURE_BUILD_BIT_KHR);stageStamp(f,2,VK_PIPELINE_STAGE_ACCELERATION_STRUCTURE_BUILD_BIT_KHR);return;}
    dynamicBarrier(f.cmd,d,true);
    const bool local=!d.actorInputs.empty();
    VkAccelerationStructureBuildRangeInfoKHR r{};r.primitiveCount=d.count;
    const VkAccelerationStructureBuildRangeInfoKHR* rp=&r;
    if(local){
        // Independent BLAS builds can overlap; no per-actor barrier or queue submit.
        const size_t count=d.actorInputs.size();
        std::array<VkAccelerationStructureGeometryKHR,128> geometries{};
        std::array<VkAccelerationStructureBuildGeometryInfoKHR,128> builds{};
        std::array<VkAccelerationStructureBuildRangeInfoKHR,128> ranges{};
        std::array<const VkAccelerationStructureBuildRangeInfoKHR*,128> rangePointers{};
        uint32_t buildCount=0;
        for(size_t i=0;i<count;++i){
            auto& a=d.actors[i];const auto& input=d.actorInputs[i];
            const auto triangles=input.indexCount/3;
            if(a.revision&&a.revision==a.builtRevision&&a.builtCount==triangles&&a.builtTopology==input.topology){++dynamicSkips;continue;}
            const auto j=buildCount++;
            geometries[j]=actorGeometry(d,input);auto& b=builds[j];b=dynamicBuildInfo();
            b.pGeometries=&geometries[j];b.dstAccelerationStructure=a.blas;
            b.scratchData.deviceAddress=(a.scratch.address+scratchAlignment-1)&~VkDeviceAddress(scratchAlignment-1);
            if(a.builtCount==triangles&&a.builtTopology==input.topology){b.mode=VK_BUILD_ACCELERATION_STRUCTURE_MODE_UPDATE_KHR;b.srcAccelerationStructure=a.blas;++dynamicRefits;}
            else ++dynamicBuilds;
            ranges[j].primitiveCount=triangles;rangePointers[j]=&ranges[j];a.builtCount=triangles;a.builtTopology=input.topology;a.builtRevision=a.revision;
        }
        if(buildCount)CmdBuildAccelerationStructuresKHR(f.cmd,buildCount,builds.data(),rangePointers.data());
    }else{
        auto g=dynamicGeometry(d);auto b=dynamicBuildInfo();b.pGeometries=&g;b.dstAccelerationStructure=d.blas;
        b.scratchData.deviceAddress=(d.scratch.address+scratchAlignment-1)&~VkDeviceAddress(scratchAlignment-1);
        if(d.count==d.builtCount&&(!d.indexed||d.topology==d.builtTopology)){b.mode=VK_BUILD_ACCELERATION_STRUCTURE_MODE_UPDATE_KHR;b.srcAccelerationStructure=d.blas;++dynamicRefits;}
        else ++dynamicBuilds;
        CmdBuildAccelerationStructuresKHR(f.cmd,1,&b,&rp);d.builtCount=d.count;d.builtTopology=d.topology;
    }
    stageStamp(f,1,VK_PIPELINE_STAGE_ACCELERATION_STRUCTURE_BUILD_BIT_KHR);
    VkMemoryBarrier barrier{VK_STRUCTURE_TYPE_MEMORY_BARRIER};barrier.srcAccessMask=VK_ACCESS_ACCELERATION_STRUCTURE_WRITE_BIT_KHR;
    barrier.dstAccessMask=VK_ACCESS_ACCELERATION_STRUCTURE_READ_BIT_KHR|VK_ACCESS_ACCELERATION_STRUCTURE_WRITE_BIT_KHR;
    CmdPipelineBarrier(f.cmd,VK_PIPELINE_STAGE_ACCELERATION_STRUCTURE_BUILD_BIT_KHR,VK_PIPELINE_STAGE_ACCELERATION_STRUCTURE_BUILD_BIT_KHR,0,1,&barrier,0,nullptr,0,nullptr);
    auto inst=static_cast<VkAccelerationStructureInstanceKHR*>(d.instances.mapped);
    uint32_t n=uint32_t(active->rayInstances.size());
    const uint32_t actorCount=local?uint32_t(d.actorInputs.size()):1;
    const bool refit=d.sceneId==active->id && d.builtInstances==n+actorCount && d.builtLocal==local;
    if(!refit){
        memcpy(inst,active->rayInstances.data(),n*sizeof(*inst));
    }
    for(uint32_t i=0;i<actorCount;++i){
        auto& out=inst[n+i];out={};
        if(local)out.transform=d.actorInputs[i].transform;
        else out.transform.matrix[0][0]=out.transform.matrix[1][1]=out.transform.matrix[2][2]=1;
        out.instanceCustomIndex=i;out.mask=4;out.flags=VK_GEOMETRY_INSTANCE_TRIANGLE_FACING_CULL_DISABLE_BIT_KHR|VK_GEOMETRY_INSTANCE_FORCE_OPAQUE_BIT_KHR;
        VkAccelerationStructureDeviceAddressInfoKHR ai{VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_DEVICE_ADDRESS_INFO_KHR};ai.accelerationStructure=d.blas;
        if(local)ai.accelerationStructure=d.actors[i].blas;
        out.accelerationStructureReference=GetAccelerationStructureDeviceAddressKHR(device,&ai);
    }
    n+=actorCount;
    VkAccelerationStructureGeometryKHR tg{VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_KHR};tg.geometryType=VK_GEOMETRY_TYPE_INSTANCES_KHR;
    tg.geometry.instances.sType=VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_INSTANCES_DATA_KHR;tg.geometry.instances.data.deviceAddress=d.instances.address;
    auto ti=dynamicBuildInfo();ti.type=VK_ACCELERATION_STRUCTURE_TYPE_TOP_LEVEL_KHR;
    ti.flags=VK_BUILD_ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT_KHR|VK_BUILD_ACCELERATION_STRUCTURE_ALLOW_UPDATE_BIT_KHR;
    if(refit){ti.mode=VK_BUILD_ACCELERATION_STRUCTURE_MODE_UPDATE_KHR;ti.srcAccelerationStructure=d.tlas;++dynamicTopRefits;}
    else ++dynamicTopBuilds;
    ti.pGeometries=&tg;ti.dstAccelerationStructure=d.tlas;
    ti.scratchData.deviceAddress=(d.tlasScratch.address+scratchAlignment-1)&~VkDeviceAddress(scratchAlignment-1);r.primitiveCount=n;
    CmdBuildAccelerationStructuresKHR(f.cmd,1,&ti,&rp);barrier.dstAccessMask=VK_ACCESS_ACCELERATION_STRUCTURE_READ_BIT_KHR;
    stageStamp(f,2,VK_PIPELINE_STAGE_ACCELERATION_STRUCTURE_BUILD_BIT_KHR);
    d.sceneId=active->id;d.builtInstances=n;d.builtLocal=local;
    CmdPipelineBarrier(f.cmd,VK_PIPELINE_STAGE_ACCELERATION_STRUCTURE_BUILD_BIT_KHR,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,0,1,&barrier,0,nullptr,0,nullptr);
}
API GLuint __cdecl rzrt_dynamic_buffer(Context* c,uint32_t triangles) {
    try { if(!c)throw std::runtime_error("No RTX context");return c->dynamicBuffer(triangles); }
    catch(const std::exception& e){error=e.what();return 0;}
}
API uint64_t __cdecl rzrt_dynamic_stat(Context* c,uint32_t field) {
    if(!c)return 0;
    if(field==0)return c->dynamicTriangles;if(field==1)return c->dynamicBuilds;if(field==2)return c->dynamicRefits;
    if(field==4)return c->dynamicTopBuilds;if(field==5)return c->dynamicTopRefits;
    if(field==6)return c->dynamicSkips;
    uint64_t bytes=0;for(auto& f:c->frames){auto& d=f.dynamic;bytes+=d.vertices.size+d.indices.size+d.blasBuffer.size+d.tlasBuffer.size+d.scratch.size+d.tlasScratch.size+d.instances.size+d.actorRefs.size;
        for(auto& a:d.actors)bytes+=a.blasBuffer.size+a.scratch.size;}return bytes;
}

API GLuint __cdecl rzrt_dynamic_buffer_indexed(Context* c,uint32_t triangles,uint32_t vertices,uint64_t topology,GLuint* indexBuffer,uint32_t* indicesDirty) {
    try {if(!c||!indexBuffer||!indicesDirty)throw std::runtime_error("Invalid indexed RTX arguments");
        return c->dynamicBuffer(triangles,vertices,topology,indexBuffer,indicesDirty);}
    catch(const std::exception& e){error=e.what();return 0;}
}
API int __cdecl rzrt_dynamic_actors(Context* c,const DynamicActorInput* actors,uint32_t count){
    try{if(!c)throw std::runtime_error("No RTX context");c->dynamicActors(actors,count);return 1;}
    catch(const std::exception& e){error=e.what();return 0;}
}
API int __cdecl rzrt_dynamic_actor_revisions(Context* c,const uint64_t* revisions,uint32_t count){
    try{if(!c)throw std::runtime_error("No RTX context");c->dynamicActorRevisions(revisions,count);return 1;}
    catch(const std::exception& e){error=e.what();return 0;}
}
