// Immutable tile BLAS with bounded input batches. A scene retains them until all
// submitted frames retire. Updating tree cards does not rebuild static meshes.
static constexpr uint32_t staticChunkTriangles=65536;
// Vulkan defines a triangle with NaN in a vertex X coordinate as inactive.
// A real "dummy" at 10,000 km inflated the tree-only BLAS and its TLAS bounds.
static const float inactiveTriangle[]={std::numeric_limits<float>::quiet_NaN(),0,0, 0,0,0, 0,0,0};

static void hashBytes(std::array<uint64_t,2>& h,const void* data,size_t size) {
    const auto* p=static_cast<const unsigned char*>(data);
    while(size>=8) {
        uint64_t x;memcpy(&x,p,8);h[0]=(h[0]^x)*1099511628211ull;
        h[1]^=x+0x9e3779b97f4a7c15ull+(h[1]<<6)+(h[1]>>2);
        p+=8;size-=8;
    }
    while(size--) {h[0]=(h[0]^*p)*1099511628211ull;h[1]=(h[1]^*p++)*0x100000001b3ull;}
}

void Context::stageImmutable(Scene& s,Buffer& data,VkCommandBuffer cmd) {
    if(!deviceMaterials || !data.mapped || !data.handle)return;
    // UMA (or a host-visible local heap) needs no copy. On a discrete GPU the
    // permanent material arrays should not be read across PCIe every ray.
    if(memory.memoryTypes[data.memoryType].propertyFlags&VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)return;
    Buffer local=buffer(data.size,(data.usage&~VK_BUFFER_USAGE_TRANSFER_SRC_BIT)|VK_BUFFER_USAGE_TRANSFER_DST_BIT);
    try{s.uploads.push_back(data);}catch(...){destroy(local);throw;}
    VkBufferCopy copy{0,0,data.size};CmdCopyBuffer(cmd,data.handle,local.handle,1,&copy);
    data=local;uploadBytes+=copy.size;
}
void Context::uploadBarrier(VkCommandBuffer cmd) {
    VkMemoryBarrier b{VK_STRUCTURE_TYPE_MEMORY_BARRIER};b.srcAccessMask=VK_ACCESS_TRANSFER_WRITE_BIT;b.dstAccessMask=VK_ACCESS_SHADER_READ_BIT;
    CmdPipelineBarrier(cmd,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,0,1,&b,0,nullptr,0,nullptr);
}

void Context::releaseBuildInputs(Scene& s) {
    if(s.inputsReleased)return;
    VkResult status=GetFenceStatus(device,s.fence);
    if(status==VK_NOT_READY)return;
    CHECK(status);
    destroy(s.vertices);destroy(s.scratch);destroy(s.instances);
    for(auto& upload:s.uploads)destroy(upload);s.uploads.clear();
    if(s.compactBlas||s.compactGround){
        auto replace=[&](VkAccelerationStructureKHR& old,Buffer& memory,VkAccelerationStructureKHR& compact,Buffer& compactMemory){
            if(!compact)return;
            compactionSavedBytes+=memory.size-compactMemory.size;++compactedMeshes;
            DestroyAccelerationStructureKHR(device,old,nullptr);destroy(memory);
            old=compact;memory=compactMemory;compact={};compactMemory={};
        };
        replace(s.blas,s.blasBuffer,s.compactBlas,s.compactBuffer);
        replace(s.groundBlas,s.groundBuffer,s.compactGround,s.compactGroundBuffer);
    }else if(s.compactQuery){
        uint64_t sizes[2]{};const uint32_t count=s.groundBlas?2:1;
        CHECK(GetQueryPoolResults(device,s.compactQuery,0,count,count*sizeof(uint64_t),sizes,sizeof(uint64_t),VK_QUERY_RESULT_64_BIT));
        auto allocate=[&](uint64_t bytes,const Buffer& old,Buffer& memory,VkAccelerationStructureKHR& as){
            if(!bytes||bytes>=old.size)return;
            memory=buffer(bytes,VK_BUFFER_USAGE_ACCELERATION_STRUCTURE_STORAGE_BIT_KHR|VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT);
            VkAccelerationStructureCreateInfoKHR ac{VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_CREATE_INFO_KHR};
            ac.type=VK_ACCELERATION_STRUCTURE_TYPE_BOTTOM_LEVEL_KHR;ac.buffer=memory.handle;ac.size=bytes;
            CHECK(CreateAccelerationStructureKHR(device,&ac,nullptr,&as));
        };
        allocate(sizes[0],s.blasBuffer,s.compactBuffer,s.compactBlas);
        if(s.groundBlas)allocate(sizes[1],s.groundBuffer,s.compactGroundBuffer,s.compactGround);
        DestroyQueryPool(device,s.compactQuery,nullptr);s.compactQuery={};
        if(s.compactBlas||s.compactGround){
            CHECK(ResetCommandBuffer(s.cmd,0));begin(s.cmd);
            VkMemoryBarrier barrier{VK_STRUCTURE_TYPE_MEMORY_BARRIER};barrier.srcAccessMask=VK_ACCESS_ACCELERATION_STRUCTURE_WRITE_BIT_KHR;
            barrier.dstAccessMask=VK_ACCESS_ACCELERATION_STRUCTURE_READ_BIT_KHR;
            CmdPipelineBarrier(s.cmd,VK_PIPELINE_STAGE_ACCELERATION_STRUCTURE_BUILD_BIT_KHR,VK_PIPELINE_STAGE_ACCELERATION_STRUCTURE_BUILD_BIT_KHR,0,1,&barrier,0,nullptr,0,nullptr);
            auto copy=[&](VkAccelerationStructureKHR src,VkAccelerationStructureKHR dst){
                if(!dst)return;
                VkCopyAccelerationStructureInfoKHR info{VK_STRUCTURE_TYPE_COPY_ACCELERATION_STRUCTURE_INFO_KHR};
                info.src=src;info.dst=dst;info.mode=VK_COPY_ACCELERATION_STRUCTURE_MODE_COMPACT_KHR;
                CmdCopyAccelerationStructureKHR(s.cmd,&info);
            };
            copy(s.blas,s.compactBlas);copy(s.groundBlas,s.compactGround);
            CHECK(EndCommandBuffer(s.cmd));s.submitted=false;CHECK(ResetFences(device,1,&s.fence));
            VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};submit.commandBufferCount=1;submit.pCommandBuffers=&s.cmd;
            CHECK(QueueSubmit(queue,1,&submit,s.fence));s.submitted=true;return;
        }
    }
    s.inputsReleased=true;
}

uint64_t Context::sceneBytes(const Scene& s) const {
    uint64_t n=s.vertices.size+s.cards.size+s.surfaces.size+s.surfaceUV.size+s.surfaceRefs.size+
        s.blasBuffer.size+s.groundBuffer.size+s.tlasBuffer.size+s.scratch.size+s.instances.size+
        s.compactBuffer.size+s.compactGroundBuffer.size;
    for(const auto& p:s.parts)n+=sceneBytes(*p);
    for(const auto& upload:s.uploads)n+=upload.size;
    return n;
}

std::shared_ptr<Scene> Context::buildPart(const float* xyz,uint32_t triangles,
        const Card* cards,uint32_t count,const Surface* surfaces) {
    if(triangles>staticChunkTriangles || count>1000000 || (triangles&&!xyz) || (count&&!cards))
        throw std::runtime_error("Invalid RTX chunk size");
    auto s=std::make_shared<Scene>();s->c=this;s->triangles=triangles;s->cardCount=count;
    uint32_t ground=0,textured=0;
    if(surfaces)for(uint32_t i=0;i<triangles;++i){ground+=surfaces[i].normal[3]<0;textured+=surfaces[i].normal[3]>0;}
    const uint32_t opaque=std::max(1u,triangles-ground),total=opaque+count*2+ground;
    s->opaqueCount=opaque;s->groundCount=ground;s->groundOffset=opaque;
    const auto inputUsage=VK_BUFFER_USAGE_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_BIT_KHR|VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT;
    const auto materialUsage=VK_BUFFER_USAGE_STORAGE_BUFFER_BIT|VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT;
    s->vertices=buffer(VkDeviceSize(total)*36,inputUsage,true);
    s->surfaces=buffer(VkDeviceSize(opaque+ground)*sizeof(CompactSurface),materialUsage,true);
    s->surfaceUV=buffer(VkDeviceSize(textured)*sizeof(SurfaceUV),materialUsage,true);
    auto* dst=static_cast<float*>(s->vertices.mapped);
    auto* material=static_cast<CompactSurface*>(s->surfaces.mapped);
    auto* uv=static_cast<SurfaceUV*>(s->surfaceUV.mapped);
    uint32_t oi=0,gi=0,ui=0;
    for(uint32_t i=0;i<triangles;++i){
        const bool isGround=surfaces&&surfaces[i].normal[3]<0;
        const uint32_t at=isGround?gi++:oi++;
        memcpy(dst+size_t(isGround?opaque+count*2+at:at)*9,xyz+size_t(i)*9,36);
        CompactSurface v{};
        if(surfaces){
            memcpy(v.normal,surfaces[i].normal,16);memcpy(v.color,surfaces[i].color,16);
            if(surfaces[i].normal[3]>0){
                memcpy(&uv[ui],surfaces[i].uv0,sizeof(SurfaceUV));
                // UV1.z is unused by the existing interpolation; retain tint
                // exactly while color.w carries the integer UV record index.
                uv[ui].uv1[2]=surfaces[i].color[3];
                memcpy(&v.color[3],&ui,sizeof(ui));++ui;
            }
        }
        material[isGround?opaque+at:at]=v;
    }
    if(!oi){
        memcpy(dst,inactiveTriangle,sizeof(inactiveTriangle));material[0]={};
    }
    dst+=size_t(opaque)*9;
    const int corners[6][2]={{0,0},{1,0},{1,1},{0,0},{1,1},{0,1}};
    for(uint32_t i=0;i<count;++i){
        if(cards[i].origin[3]<0||cards[i].origin[3]>=float(alphaLayers))throw std::runtime_error("Invalid silhouette layer");
        for(auto& corner:corners)for(int a=0;a<3;++a)
            *dst++=cards[i].origin[a]+float(corner[0])*cards[i].u[a]+float(corner[1])*cards[i].v[a];
    }
    s->cards=buffer(VkDeviceSize(count)*sizeof(Card),VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,true);
    if(count)memcpy(s->cards.mapped,cards,size_t(count)*sizeof(Card));
    finishPart(s);return s;
}

void Context::finishPart(const std::shared_ptr<Scene>& s){
    const uint32_t opaque=s->opaqueCount,ground=s->groundCount,count=uint32_t(s->cardCount);
    VkAccelerationStructureGeometryKHR geometries[3]{};
    for(unsigned i=0;i<3;++i){
        auto& g=geometries[i];g.sType=VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_KHR;g.geometryType=VK_GEOMETRY_TYPE_TRIANGLES_KHR;
        g.flags=i!=1?VK_GEOMETRY_OPAQUE_BIT_KHR:VK_GEOMETRY_NO_DUPLICATE_ANY_HIT_INVOCATION_BIT_KHR;
        auto& t=g.geometry.triangles;t.sType=VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_TRIANGLES_DATA_KHR;
        t.vertexFormat=VK_FORMAT_R32G32B32_SFLOAT;t.vertexStride=12;t.indexType=VK_INDEX_TYPE_NONE_KHR;
        t.vertexData.deviceAddress=s->vertices.address+VkDeviceSize(i==2?s->groundOffset+count*2:i==1?opaque:0)*36;
        t.maxVertex=std::max(1u,i==2?ground:i==1?count*2:opaque)*3-1;
    }
    uint32_t counts[]={opaque,count*2,ground};
    VkAccelerationStructureBuildGeometryInfoKHR bi{VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_BUILD_GEOMETRY_INFO_KHR};
    bi.type=VK_ACCELERATION_STRUCTURE_TYPE_BOTTOM_LEVEL_KHR;bi.flags=VK_BUILD_ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT_KHR;
    const bool compact=s->triangles>=65536;
    if(compact)bi.flags|=VK_BUILD_ACCELERATION_STRUCTURE_ALLOW_COMPACTION_BIT_KHR;
    bi.mode=VK_BUILD_ACCELERATION_STRUCTURE_MODE_BUILD_KHR;bi.geometryCount=count?2:1;bi.pGeometries=geometries;
    VkAccelerationStructureBuildSizesInfoKHR bs{VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_BUILD_SIZES_INFO_KHR};
    GetAccelerationStructureBuildSizesKHR(device,VK_ACCELERATION_STRUCTURE_BUILD_TYPE_DEVICE_KHR,&bi,counts,&bs);
    auto create=[&](VkDeviceSize size,Buffer& b,VkAccelerationStructureKHR& as){
        b=buffer(size,VK_BUFFER_USAGE_ACCELERATION_STRUCTURE_STORAGE_BIT_KHR|VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT);
        VkAccelerationStructureCreateInfoKHR ac{VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_CREATE_INFO_KHR};
        ac.type=bi.type;ac.buffer=b.handle;ac.size=size;CHECK(CreateAccelerationStructureKHR(device,&ac,nullptr,&as));
    };
    create(bs.accelerationStructureSize,s->blasBuffer,s->blas);
    auto gb=bi;gb.geometryCount=1;gb.pGeometries=&geometries[2];
    VkAccelerationStructureBuildSizesInfoKHR gs{VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_BUILD_SIZES_INFO_KHR};
    if(ground){GetAccelerationStructureBuildSizesKHR(device,VK_ACCELERATION_STRUCTURE_BUILD_TYPE_DEVICE_KHR,&gb,&ground,&gs);create(gs.accelerationStructureSize,s->groundBuffer,s->groundBlas);}
    s->scratch=buffer(std::max(bs.buildScratchSize,gs.buildScratchSize)+scratchAlignment,VK_BUFFER_USAGE_STORAGE_BUFFER_BIT|VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT);
    const auto scratch=(s->scratch.address+scratchAlignment-1)&~VkDeviceAddress(scratchAlignment-1);
    bi.dstAccelerationStructure=s->blas;bi.scratchData.deviceAddress=scratch;
    gb.dstAccelerationStructure=s->groundBlas;gb.scratchData.deviceAddress=scratch;
    s->cmd=command();s->fence=newFence();begin(s->cmd);
    stageImmutable(*s,s->cards,s->cmd);stageImmutable(*s,s->surfaces,s->cmd);stageImmutable(*s,s->surfaceUV,s->cmd);
    if(!s->uploads.empty())uploadBarrier(s->cmd);
    VkAccelerationStructureBuildRangeInfoKHR ranges[3]{};ranges[0].primitiveCount=opaque;ranges[1].primitiveCount=count*2;ranges[2].primitiveCount=ground;
    const auto* rp=ranges;CmdBuildAccelerationStructuresKHR(s->cmd,1,&bi,&rp);
    VkMemoryBarrier barrier{VK_STRUCTURE_TYPE_MEMORY_BARRIER};barrier.srcAccessMask=VK_ACCESS_ACCELERATION_STRUCTURE_WRITE_BIT_KHR;
    barrier.dstAccessMask=VK_ACCESS_ACCELERATION_STRUCTURE_READ_BIT_KHR|VK_ACCESS_ACCELERATION_STRUCTURE_WRITE_BIT_KHR;
    CmdPipelineBarrier(s->cmd,VK_PIPELINE_STAGE_ACCELERATION_STRUCTURE_BUILD_BIT_KHR,VK_PIPELINE_STAGE_ACCELERATION_STRUCTURE_BUILD_BIT_KHR,0,1,&barrier,0,nullptr,0,nullptr);
    if(ground){rp=&ranges[2];CmdBuildAccelerationStructuresKHR(s->cmd,1,&gb,&rp);}
    if(compact){
        const uint32_t n=ground?2:1;
        VkQueryPoolCreateInfo qi{VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO};qi.queryType=VK_QUERY_TYPE_ACCELERATION_STRUCTURE_COMPACTED_SIZE_KHR;qi.queryCount=n;
        CHECK(CreateQueryPool(device,&qi,nullptr,&s->compactQuery));CmdResetQueryPool(s->cmd,s->compactQuery,0,n);
        CmdPipelineBarrier(s->cmd,VK_PIPELINE_STAGE_ACCELERATION_STRUCTURE_BUILD_BIT_KHR,VK_PIPELINE_STAGE_ACCELERATION_STRUCTURE_BUILD_BIT_KHR,0,1,&barrier,0,nullptr,0,nullptr);
        VkAccelerationStructureKHR handles[]={s->blas,s->groundBlas};
        CmdWriteAccelerationStructuresPropertiesKHR(s->cmd,n,handles,VK_QUERY_TYPE_ACCELERATION_STRUCTURE_COMPACTED_SIZE_KHR,s->compactQuery,0);
    }
    CHECK(EndCommandBuffer(s->cmd));VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};submit.commandBufferCount=1;submit.pCommandBuffers=&s->cmd;
    CHECK(QueueSubmit(queue,1,&submit,s->fence));s->submitted=true;
}

// Stream a whole tile into its final upload/material buffers. Opaque and ground
// ranges retain their input order; there is no whole-tile CPU copy.
// Keeping them in one BLAS each avoids overlapping BLAS for every material.
bool Context::meshReuse(uint64_t identity){
    if(!assembling||uploading)throw std::runtime_error("Invalid RTX early mesh lookup");
    auto it=identityCache.find(identity);if(it==identityCache.end())return false;
    auto part=it->second.lock();if(!part){identityCache.erase(it);return false;}
    assembling->parts.push_back(part);++earlyMeshReuses;return true;
}
void Context::meshBegin(uint32_t capacity,uint32_t uvCapacity,uint32_t groundCapacity,uint64_t identity){
    if(!assembling||uploading)throw std::runtime_error("Invalid RTX mesh begin");
    if(capacity>=UINT32_MAX/3 || uvCapacity>capacity || groundCapacity>capacity)throw std::runtime_error("Invalid RTX mesh capacity");
    auto s=std::make_shared<Scene>();s->c=this;
    const auto input=VK_BUFFER_USAGE_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_BIT_KHR|VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT;
    const auto material=VK_BUFFER_USAGE_STORAGE_BUFFER_BIT|VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT;
    s->vertices=buffer(VkDeviceSize(capacity+1)*36,input,true);
    s->surfaces=buffer(VkDeviceSize(capacity+1)*sizeof(CompactSurface),material,true);
    s->surfaceUV=buffer(VkDeviceSize(uvCapacity)*sizeof(SurfaceUV),material,true);
    s->cards=buffer(16,VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,true);
    s->groundOffset=capacity-groundCapacity+1;
    uploading=s;uploadCapacity=capacity;uploadUVCapacity=uvCapacity;uploadGroundCapacity=groundCapacity;
    uploadUVCount=uploadOpaque=uploadGround=0;
    uploadIdentity=identity;
    uploadHash={1469598103934665603ull,0x9e3779b97f4a7c15ull};
    hashBytes(uploadHash,&capacity,sizeof(capacity));hashBytes(uploadHash,&uvCapacity,sizeof(uvCapacity));
    hashBytes(uploadHash,&groundCapacity,sizeof(groundCapacity));
    for(auto& p:assembling->parts)releaseBuildInputs(*p);
}

void Context::meshAppend(const float* xyz,uint32_t triangles,const Surface* surfaces){
    if(!surfaces||!xyz||uint64_t(uploadOpaque)+uploadGround+triangles>uploadCapacity)
        throw std::runtime_error("RTX mesh exceeded its declared geometry");
    auto& s=*uploading;
    auto* dst=static_cast<float*>(s.vertices.mapped);
    auto* material=static_cast<CompactSurface*>(s.surfaces.mapped);
    auto* uv=static_cast<SurfaceUV*>(s.surfaceUV.mapped);
    hashBytes(uploadHash,xyz,size_t(triangles)*36);hashBytes(uploadHash,surfaces,size_t(triangles)*sizeof(Surface));
    hashBytesCount+=uint64_t(triangles)*(36+sizeof(Surface));
    for(uint32_t i=0;i<triangles;++i){
        const bool ground=surfaces[i].normal[3]<0;
        if(ground?uploadGround>=uploadGroundCapacity:uploadOpaque>=uploadCapacity-uploadGroundCapacity)
            throw std::runtime_error("RTX mesh exceeded its declared surface range");
        const uint32_t at=ground?s.groundOffset+uploadGround++:uploadOpaque++;
        memcpy(dst+size_t(at)*9,xyz+size_t(i)*9,36);
        auto& v=material[at];memcpy(&v,&surfaces[i],sizeof(CompactSurface));
        if(surfaces[i].normal[3]>0){
            if(uploadUVCount>=uploadUVCapacity)throw std::runtime_error("RTX mesh exceeded its declared texture coordinates");
            memcpy(&uv[uploadUVCount],surfaces[i].uv0,sizeof(SurfaceUV));
            uv[uploadUVCount].uv1[2]=surfaces[i].color[3];memcpy(&v.color[3],&uploadUVCount,4);++uploadUVCount;
        }
    }
    peakBuildBytes=std::max(peakBuildBytes,sceneBytes(*assembling)+sceneBytes(s));
}

void Context::meshEnd(){
    if(!uploading)throw std::runtime_error("RTX mesh collection has not started");
    if(!uploadOpaque&&!uploadGround){uploading.reset();return;}
    auto s=meshCache[uploadHash].lock();
    if(s){++meshReuses;uploading.reset();}
    else{
        s=std::move(uploading);s->triangles=uint64_t(uploadOpaque)+uploadGround;
        s->opaqueCount=std::max(1u,uploadOpaque);s->groundCount=uploadGround;
        if(!uploadOpaque){
            memcpy(s->vertices.mapped,inactiveTriangle,sizeof(inactiveTriangle));memset(s->surfaces.mapped,0,sizeof(CompactSurface));
        }
        finishPart(s);meshCache[uploadHash]=s;++meshBuilds;uploadedTriangles+=s->triangles;
    }
    assembling->parts.push_back(s);
    if(uploadIdentity)identityCache[uploadIdentity]=s;
    for(auto& p:assembling->parts)releaseBuildInputs(*p);
    peakBuildBytes=std::max(peakBuildBytes,sceneBytes(*assembling));
}

void Context::sceneBegin(bool reuseStatic){
    poll();if(pending)throw std::runtime_error("A BVH scene is already pending");
    uploading.reset();
    auto s=std::make_shared<Scene>();s->c=this;QueryPerformanceCounter(&s->start);
    if(reuseStatic&&active){
        s->parts.assign(active->parts.begin(),active->parts.begin()+active->staticCount);++staticReuses;
    }
    assembling=std::move(s);
}

void Context::sceneChunk(const float* xyz,uint32_t triangles,const Surface* surfaces){
    if(!assembling)throw std::runtime_error("RTX scene collection has not started");
    if(!triangles)return;
    if(triangles>staticChunkTriangles||!xyz)throw std::runtime_error("Invalid RTX chunk input");
    if(uploading){meshAppend(xyz,triangles,surfaces);return;}
    std::array<uint64_t,2> key={1469598103934665603ull,0x9e3779b97f4a7c15ull};
    hashBytes(key,&triangles,sizeof(triangles));hashBytes(key,xyz,size_t(triangles)*36);
    if(surfaces)hashBytes(key,surfaces,size_t(triangles)*sizeof(Surface));
    hashBytesCount+=uint64_t(triangles)*(36+(surfaces?sizeof(Surface):0));
    auto mesh=meshCache[key].lock();
    if(mesh){++meshReuses;}
    else{mesh=buildPart(xyz,triangles,nullptr,0,surfaces);meshCache[key]=mesh;++meshBuilds;uploadedTriangles+=triangles;}
    assembling->parts.push_back(mesh);
    // Completed upload/scratch storage must not accumulate while the CPU is
    // gathering a large city. No GPU wait in the normal collection path.
    for(auto& p:assembling->parts)releaseBuildInputs(*p);
    peakBuildBytes=std::max(peakBuildBytes,sceneBytes(*assembling));
}

void Context::sceneCommit(const Card* cards,uint32_t count,uint64_t id){
    if(!assembling)throw std::runtime_error("RTX scene collection has not started");
    if(uploading)throw std::runtime_error("RTX mesh collection is incomplete");
    auto s=assembling;s->id=id;s->staticCount=s->parts.size();s->cardCount=count;
    auto trees=buildPart(nullptr,0,cards,count,nullptr);s->parts.push_back(trees);
    pending=s;assembling.reset();++stats.builds;
    for(auto it=meshCache.begin();it!=meshCache.end();)if(it->second.expired())it=meshCache.erase(it);else ++it;
    for(auto it=identityCache.begin();it!=identityCache.end();)if(it->second.expired())it=identityCache.erase(it);else ++it;
}

void Context::buildTop(const std::shared_ptr<Scene>& s){
    // Frame descriptors refer to the tree buffer; the immutable part owns it.
    std::vector<SurfaceReference> refs;
    for(const auto& p:s->parts){
        s->triangles+=p->triangles;s->groundCount+=p->groundCount;s->opaqueCount+=p->opaqueCount;
        for(int ground=0;ground<2;++ground){
            const auto handle=ground?p->groundBlas:p->blas;if(!handle)continue;
            VkAccelerationStructureInstanceKHR inst{};
            inst.transform.matrix[0][0]=inst.transform.matrix[1][1]=inst.transform.matrix[2][2]=1;
            inst.mask=ground?2:1;
            inst.flags=VK_GEOMETRY_INSTANCE_TRIANGLE_FACING_CULL_DISABLE_BIT_KHR|
                (p->cardCount?VK_GEOMETRY_INSTANCE_FORCE_NO_OPAQUE_BIT_KHR:VK_GEOMETRY_INSTANCE_FORCE_OPAQUE_BIT_KHR);
            inst.instanceCustomIndex=static_cast<uint32_t>(refs.size());
            VkAccelerationStructureDeviceAddressInfoKHR ai{VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_DEVICE_ADDRESS_INFO_KHR};ai.accelerationStructure=handle;
            inst.accelerationStructureReference=GetAccelerationStructureDeviceAddressKHR(device,&ai);
            s->rayInstances.push_back(inst);
            refs.push_back({p->surfaces.address,p->surfaceUV.address,ground?p->groundOffset:0,ground?p->groundCount:p->opaqueCount,{0,0}});
        }
    }
    if(refs.size()>65535)throw std::runtime_error("RTX scene has too many mesh chunks");
    const uint32_t n=static_cast<uint32_t>(s->rayInstances.size());
    s->surfaceRefs=buffer(refs.size()*sizeof(SurfaceReference),VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,true);
    memcpy(s->surfaceRefs.mapped,refs.data(),refs.size()*sizeof(SurfaceReference));
    s->instances=buffer(VkDeviceSize(n)*sizeof(VkAccelerationStructureInstanceKHR),VK_BUFFER_USAGE_ACCELERATION_STRUCTURE_BUILD_INPUT_READ_ONLY_BIT_KHR|VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT,true);
    memcpy(s->instances.mapped,s->rayInstances.data(),size_t(s->instances.size));
    VkAccelerationStructureGeometryKHR g{VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_KHR};g.geometryType=VK_GEOMETRY_TYPE_INSTANCES_KHR;
    g.geometry.instances.sType=VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_GEOMETRY_INSTANCES_DATA_KHR;g.geometry.instances.data.deviceAddress=s->instances.address;
    VkAccelerationStructureBuildGeometryInfoKHR bi{VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_BUILD_GEOMETRY_INFO_KHR};
    bi.type=VK_ACCELERATION_STRUCTURE_TYPE_TOP_LEVEL_KHR;bi.mode=VK_BUILD_ACCELERATION_STRUCTURE_MODE_BUILD_KHR;
    bi.flags=VK_BUILD_ACCELERATION_STRUCTURE_PREFER_FAST_TRACE_BIT_KHR;bi.geometryCount=1;bi.pGeometries=&g;
    VkAccelerationStructureBuildSizesInfoKHR sizes{VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_BUILD_SIZES_INFO_KHR};
    GetAccelerationStructureBuildSizesKHR(device,VK_ACCELERATION_STRUCTURE_BUILD_TYPE_DEVICE_KHR,&bi,&n,&sizes);
    s->tlasBuffer=buffer(sizes.accelerationStructureSize,VK_BUFFER_USAGE_ACCELERATION_STRUCTURE_STORAGE_BIT_KHR|VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT);
    VkAccelerationStructureCreateInfoKHR ac{VK_STRUCTURE_TYPE_ACCELERATION_STRUCTURE_CREATE_INFO_KHR};ac.type=bi.type;ac.buffer=s->tlasBuffer.handle;ac.size=sizes.accelerationStructureSize;
    CHECK(CreateAccelerationStructureKHR(device,&ac,nullptr,&s->tlas));
    s->scratch=buffer(sizes.buildScratchSize+scratchAlignment,VK_BUFFER_USAGE_STORAGE_BUFFER_BIT|VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT);
    bi.dstAccelerationStructure=s->tlas;bi.scratchData.deviceAddress=(s->scratch.address+scratchAlignment-1)&~VkDeviceAddress(scratchAlignment-1);
    s->cmd=command();s->fence=newFence();begin(s->cmd);
    stageImmutable(*s,s->surfaceRefs,s->cmd);if(!s->uploads.empty())uploadBarrier(s->cmd);
    VkMemoryBarrier barrier{VK_STRUCTURE_TYPE_MEMORY_BARRIER};barrier.srcAccessMask=VK_ACCESS_ACCELERATION_STRUCTURE_WRITE_BIT_KHR;
    barrier.dstAccessMask=VK_ACCESS_ACCELERATION_STRUCTURE_READ_BIT_KHR;
    CmdPipelineBarrier(s->cmd,VK_PIPELINE_STAGE_ACCELERATION_STRUCTURE_BUILD_BIT_KHR,VK_PIPELINE_STAGE_ACCELERATION_STRUCTURE_BUILD_BIT_KHR,0,1,&barrier,0,nullptr,0,nullptr);
    VkAccelerationStructureBuildRangeInfoKHR range{};range.primitiveCount=n;const auto* rp=&range;
    CmdBuildAccelerationStructuresKHR(s->cmd,1,&bi,&rp);
    CmdPipelineBarrier(s->cmd,VK_PIPELINE_STAGE_ACCELERATION_STRUCTURE_BUILD_BIT_KHR,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,0,1,&barrier,0,nullptr,0,nullptr);
    CHECK(EndCommandBuffer(s->cmd));VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};submit.commandBufferCount=1;submit.pCommandBuffers=&s->cmd;
    CHECK(QueueSubmit(queue,1,&submit,s->fence));s->submitted=true;
}

void Context::build(const float* xyz,uint32_t triangles,const Card* cards,uint32_t count,uint64_t id,const Surface* surfaces){
    if((triangles&&!xyz)||(count&&!cards))throw std::runtime_error("Invalid RTX scene input");
    sceneBegin(false);
    for(uint32_t offset=0;offset<triangles;offset+=staticChunkTriangles)
        sceneChunk(xyz+size_t(offset)*9,std::min(staticChunkTriangles,triangles-offset),surfaces?surfaces+offset:nullptr);
    sceneCommit(cards,count,id);
}

void Context::poll(){
    if(!pending)return;
    if(!pending->submitted){
        bool partsReady=true;
        for(auto& p:pending->parts){releaseBuildInputs(*p);partsReady&=p->inputsReleased;}
        if(!partsReady)return;
        buildTop(pending);
    }
    VkResult status=GetFenceStatus(device,pending->fence);if(status==VK_NOT_READY)return;CHECK(status);
    LARGE_INTEGER now,freq;QueryPerformanceCounter(&now);QueryPerformanceFrequency(&freq);
    stats.buildMs=1000.*double(now.QuadPart-pending->start.QuadPart)/double(freq.QuadPart);
    for(auto& p:pending->parts)releaseBuildInputs(*p);releaseBuildInputs(*pending);
    active=std::move(pending);stats.sceneId=active->id;stats.triangles=active->triangles;stats.cards=active->cardCount;
    stats.bytes=output.size+alpha.size+sceneBytes(*active);
}

API int __cdecl rzrt_scene_begin(Context* c,int reuseStatic){try{if(!c)throw std::runtime_error("No RTX context");c->sceneBegin(reuseStatic!=0);return 1;}catch(const std::exception& e){error=e.what();return 0;}}
API int __cdecl rzrt_mesh_begin(Context* c,uint32_t capacity,uint32_t uv,uint32_t ground){try{if(!c)throw std::runtime_error("No RTX context");c->meshBegin(capacity,uv,ground);return 1;}catch(const std::exception& e){error=e.what();return 0;}}
API int __cdecl rzrt_mesh_begin_identity(Context* c,uint32_t capacity,uint32_t uv,uint32_t ground,uint64_t identity){try{if(!c)throw std::runtime_error("No RTX context");c->meshBegin(capacity,uv,ground,identity);return 1;}catch(const std::exception& e){error=e.what();return 0;}}
API int __cdecl rzrt_mesh_reuse(Context* c,uint64_t identity){try{if(!c)throw std::runtime_error("No RTX context");return c->meshReuse(identity)?1:0;}catch(const std::exception& e){error=e.what();return -1;}}
API int __cdecl rzrt_mesh_end(Context* c){try{if(!c)throw std::runtime_error("No RTX context");c->meshEnd();return 1;}catch(const std::exception& e){error=e.what();return 0;}}
API int __cdecl rzrt_scene_chunk(Context* c,const float* xyz,uint32_t n,const Surface* surfaces){try{if(!c)throw std::runtime_error("No RTX context");c->sceneChunk(xyz,n,surfaces);return 1;}catch(const std::exception& e){error=e.what();return 0;}}
API int __cdecl rzrt_scene_commit(Context* c,const Card* cards,uint32_t n,uint64_t id){try{if(!c)throw std::runtime_error("No RTX context");c->sceneCommit(cards,n,id);return 1;}catch(const std::exception& e){error=e.what();return 0;}}
API uint64_t __cdecl rzrt_cache_stat(Context* c,uint32_t field){
    if(!c)return 0;
    switch(field){
        case 0:return c->active?c->active->staticCount:0;
        case 1:return c->meshBuilds;case 2:return c->meshReuses;case 3:return c->staticReuses;
        case 4:return c->uploadedTriangles;case 5:return c->peakBuildBytes;
        case 6:return c->compactedMeshes;case 7:return c->compactionSavedBytes;
        case 8:return c->earlyMeshReuses;
        default:return 0;
    }
}
