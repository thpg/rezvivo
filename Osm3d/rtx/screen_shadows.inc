// Camera-space visibility. Images are shared on the GPU with OpenGL; the
// depth capture uses the actual posed geometry, not a camera-space proxy.
void Context::screenSize(const wchar_t* shader,uint32_t width,uint32_t height) {
    if(width==screenWidth && height==screenHeight)return;
    if(width>props.limits.maxImageDimension2D || height>props.limits.maxImageDimension2D)
        throw std::runtime_error("Invalid screen shadow size");
    if(width && !screenSupported)throw std::runtime_error("R8 storage images unavailable");
    glFinish();CHECK(DeviceWaitIdle(device)); // allocation/lifecycle only
    destroy(screenDepth);destroy(screenOutput);destroy(screenSamples);destroy(screenReuse);screenWidth=screenHeight=0;
    if(!width || !height)return;
    image(screenDepth,width,1,VK_FORMAT_D32_SFLOAT,VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT|VK_IMAGE_USAGE_SAMPLED_BIT,height);
    image(screenOutput,width,1,VK_FORMAT_R8_UNORM,VK_IMAGE_USAGE_STORAGE_BIT|VK_IMAGE_USAGE_SAMPLED_BIT,height);
    image(screenSamples,width,1,VK_FORMAT_R16G16_SFLOAT,VK_IMAGE_USAGE_STORAGE_BIT|VK_IMAGE_USAGE_SAMPLED_BIT,height,false);
    image(screenReuse,width,1,VK_FORMAT_R32G32_SFLOAT,VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT|VK_IMAGE_USAGE_SAMPLED_BIT,height);
    screenWidth=width;screenHeight=height;
    VkCommandBuffer cmd=command();begin(cmd);barriers(cmd,false,true,ScreenAllocation);CHECK(EndCommandBuffer(cmd));
    VkFence fence=newFence();VkSubmitInfo si{VK_STRUCTURE_TYPE_SUBMIT_INFO};
    si.commandBufferCount=1;si.pCommandBuffers=&cmd;si.signalSemaphoreCount=1;si.pSignalSemaphores=&done;
    CHECK(QueueSubmit(queue,1,&si,fence));
    GLuint images[]={screenDepth.texture,screenOutput.texture,screenReuse.texture};GLenum layouts[]={0x958D,0x958D,0x958D};
    gl.WaitSemaphore(glDone,0,nullptr,3,images,layouts);glFlush();
    CHECK(WaitForFences(device,1,&fence,VK_TRUE,UINT64_MAX));DestroyFence(device,fence,nullptr);FreeCommandBuffers(device,pool,1,&cmd);
    if(screenPipeline && screenFilterPipeline && screenHardPipeline)return;
    auto load=[&](const wchar_t* path,VkPipeline& target,bool hard=false) {
    if(target)return;
    std::ifstream stream(path,std::ios::binary|std::ios::ate);
    if(!stream)throw std::runtime_error("Missing screen shadow SPIR-V");
    size_t bytes=static_cast<size_t>(stream.tellg());
    if(!bytes || bytes%4)throw std::runtime_error("Invalid screen shadow SPIR-V");
    std::vector<uint32_t> code(bytes/4);stream.seekg(0);stream.read(reinterpret_cast<char*>(code.data()),bytes);
    VkShaderModuleCreateInfo sm{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};sm.codeSize=bytes;sm.pCode=code.data();
    VkShaderModule module{};CHECK(CreateShaderModule(device,&sm,nullptr,&module));
    VkComputePipelineCreateInfo cp{VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO};cp.layout=pipeLayout;
    cp.stage={VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO};cp.stage.stage=VK_SHADER_STAGE_COMPUTE_BIT;
    cp.stage.module=module;cp.stage.pName="main";
    const VkBool32 values[]={sharedFilter?VK_TRUE:VK_FALSE,hard?VK_TRUE:VK_FALSE,removeInitialStore?VK_TRUE:VK_FALSE,solarConstants?VK_TRUE:VK_FALSE};
    const VkSpecializationMapEntry entries[]={{0,0,4},{1,4,4},{2,8,4},{3,12,4}};
    VkSpecializationInfo spec{4,entries,sizeof(values),values};cp.stage.pSpecializationInfo=&spec;
    VkResult r=CreateComputePipelines(device,VK_NULL_HANDLE,1,&cp,nullptr,&target);
    DestroyShaderModule(device,module,nullptr);CHECK(r);
    };
    load(shader,screenPipeline);
    load(shader,screenHardPipeline,true);
    std::wstring filterPath(shader);auto slash=filterPath.find_last_of(L"/\\");
    filterPath=(slash==std::wstring::npos?L"":filterPath.substr(0,slash+1))+L"screen_shadow_filter.spv";
    load(filterPath.c_str(),screenFilterPipeline);
}
void Context::prepareSolar(Frame& f,const ReflectionCamera& camera){
    const std::array<float,5> key={camera.sun[0],camera.sun[1],camera.sun[2],camera.zenith[0],camera.zenith[2]};
    if(!solarReady||key!=solarKey){
        solarKey=key;solarReady=true;
        float light[3]={key[0],key[1],key[2]};
        const float length=std::sqrt(light[0]*light[0]+light[1]*light[1]+light[2]*light[2]);
        for(auto& x:light)x/=std::max(length,1e-20f);
        float up[3]={0,1,0};if(std::abs(light[1])>=.95f){up[0]=1;up[1]=0;}
        auto cross=[](const float* a,const float* b,float* c){c[0]=a[1]*b[2]-a[2]*b[1];c[1]=a[2]*b[0]-a[0]*b[2];c[2]=a[0]*b[1]-a[1]*b[0];};
        cross(light,up,solarData.solarU);
        const auto* u=solarData.solarU;const float ul=std::sqrt(u[0]*u[0]+u[1]*u[1]+u[2]*u[2]);
        for(int i=0;i<3;++i)solarData.solarU[i]/=std::max(ul,1e-20f);
        cross(light,solarData.solarU,solarData.solarV);
        int count=key[3]>0?std::clamp(int(key[4]),2,8):1;
        for(int i=0;i<8;++i){
            float angle=float(i)*2.39996322973f;
            float radius=key[3]*std::sqrt((float(i)+.5f)/float(count));
            solarData.disk[i][0]=radius*std::cos(angle);solarData.disk[i][1]=radius*std::sin(angle);
        }
    }
    auto& out=*static_cast<ScreenCamera*>(f.views.mapped);out.camera=camera;
    memcpy(out.solarU,solarData.solarU,sizeof(ScreenCamera)-sizeof(ReflectionCamera));
}
bool Context::screenTrace(const ReflectionCamera* camera,uint64_t expectedScene) {
    if(!active || active->id!=expectedScene || !screenPipeline || !screenFilterPipeline)return false;
    const bool hard=directHardShadow&&camera->zenith[0]<=0;
    Frame& f=dynamicPrepared?frames[frameIndex]:acquireFrame();
    if(!dynamicPrepared)f.dynamic.count=0;
    dynamicPrepared=false;
    readTiming(f);
    f.scene=active;prepareSolar(f,*camera);
    // No posed geometry in Studio: bind a valid inert buffer and skip its query.
    static_cast<ReflectionCamera*>(f.views.mapped)->zenith[3]=f.dynamic.count?(!f.dynamic.actorInputs.empty()?3.f:(f.dynamic.indexed?2.f:1.f)):0.f;
    VkWriteDescriptorSetAccelerationStructureKHR as{VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET_ACCELERATION_STRUCTURE_KHR};
    as.accelerationStructureCount=1;as.pAccelerationStructures=f.dynamic.count?&f.dynamic.tlas:&active->tlas;
    VkDescriptorImageInfo ai{screenAlphaSampler,alpha.view,VK_IMAGE_LAYOUT_GENERAL},di{sampler,screenDepth.view,VK_IMAGE_LAYOUT_GENERAL},oi{VK_NULL_HANDLE,screenOutput.view,VK_IMAGE_LAYOUT_GENERAL};
    VkDescriptorImageInfo raw{VK_NULL_HANDLE,screenSamples.view,VK_IMAGE_LAYOUT_GENERAL},samples{sampler,screenSamples.view,VK_IMAGE_LAYOUT_GENERAL};
    VkDescriptorImageInfo reuse{sampler,screenReuse.view,VK_IMAGE_LAYOUT_GENERAL};
    VkDescriptorBufferInfo cb{active->parts.back()->cards.handle,0,active->parts.back()->cards.size},vb{f.views.handle,0,sizeof(ScreenCamera)};
    VkDescriptorBufferInfo posed{f.dynamic.count?f.dynamic.vertices.handle:active->parts.back()->cards.handle,0,
        f.dynamic.count?f.dynamic.vertices.size:active->parts.back()->cards.size};
    const auto& indexBuffer=f.dynamic.count&&f.dynamic.indexed?f.dynamic.indices:active->parts.back()->cards;
    VkDescriptorBufferInfo indices{indexBuffer.handle,0,indexBuffer.size};
    const auto& actorBuffer=f.dynamic.count&&!f.dynamic.actorInputs.empty()?f.dynamic.actorRefs:active->parts.back()->cards;
    VkDescriptorBufferInfo actors{actorBuffer.handle,0,actorBuffer.size};
    VkWriteDescriptorSet w[12]{};uint32_t slots[]={0,2,3,4,6,7,1,9,8,10,11,12};
    VkDescriptorType types[]={VK_DESCRIPTOR_TYPE_ACCELERATION_STRUCTURE_KHR,VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,VK_DESCRIPTOR_TYPE_STORAGE_BUFFER};
    for(int i=0;i<12;++i){w[i].sType=VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;w[i].dstSet=f.set;w[i].dstBinding=slots[i];w[i].descriptorCount=1;w[i].descriptorType=types[i];}
    w[0].pNext=&as;w[1].pImageInfo=&ai;w[2].pBufferInfo=&cb;w[3].pBufferInfo=&vb;w[4].pImageInfo=&di;w[5].pImageInfo=&oi;
    w[6].pImageInfo=&raw;w[7].pImageInfo=&samples;w[8].pBufferInfo=&posed;
    w[9].pImageInfo=&reuse;
    w[10].pBufferInfo=&indices;
    w[11].pBufferInfo=&actors;
    updateDescriptors(f,w,12);CHECK(ResetCommandBuffer(f.cmd,0));begin(f.cmd);barriers(f.cmd,true,false,passMask(ScreenImages));
    CmdResetQueryPool(f.cmd,queries,frameIndex*2,2);CmdWriteTimestamp(f.cmd,VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,queries,frameIndex*2);
    if(stageQueries)CmdResetQueryPool(f.cmd,stageQueries,frameIndex*5,5);
    stageStamp(f,0,VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT);
    buildDynamic(f);
    CmdBindPipeline(f.cmd,VK_PIPELINE_BIND_POINT_COMPUTE,hard?screenHardPipeline:screenPipeline);
    CmdBindDescriptorSets(f.cmd,VK_PIPELINE_BIND_POINT_COMPUTE,pipeLayout,0,1,&f.set,0,nullptr);
    CmdDispatch(f.cmd,(screenWidth+7)/8,(screenHeight+7)/8,1);
    stageStamp(f,3);
    if(!hard){
        VkMemoryBarrier filterBarrier{VK_STRUCTURE_TYPE_MEMORY_BARRIER};filterBarrier.srcAccessMask=VK_ACCESS_SHADER_WRITE_BIT;filterBarrier.dstAccessMask=VK_ACCESS_SHADER_READ_BIT;
        CmdPipelineBarrier(f.cmd,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,0,1,&filterBarrier,0,nullptr,0,nullptr);
        CmdBindPipeline(f.cmd,VK_PIPELINE_BIND_POINT_COMPUTE,screenFilterPipeline);
        CmdDispatch(f.cmd,(screenWidth+7)/8,(screenHeight+7)/8,1);
    }
    stageStamp(f,4);
    CmdWriteTimestamp(f.cmd,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,queries,frameIndex*2+1);
    dynamicBarrier(f.cmd,f.dynamic,false);
    barriers(f.cmd,false,false,passMask(ScreenImages));CHECK(EndCommandBuffer(f.cmd));CHECK(ResetFences(device,1,&f.fence));handoff(f.cmd,f.fence,f.dynamic.count?f.dynamic.glBuffer:0,passMask(ScreenImages),f.dynamic.count&&f.dynamic.indexed?f.dynamic.glIndices:0);
    f.submitted=true;f.screen=true;f.reflection=false;frameIndex=(frameIndex+1)%unsigned(frames.size());++screenFrames;
    return true;
}
API int __cdecl rzrt_screen_size(Context* c,const wchar_t* shader,uint32_t w,uint32_t h){try{if(!c)throw std::runtime_error("No RTX context");c->screenSize(shader,w,h);return 1;}catch(const std::exception& e){error=e.what();return 0;}}
API GLuint __cdecl rzrt_screen_texture(Context* c,int index){return c?(index==0?c->screenDepth.texture:c->screenOutput.texture):0;}
API GLuint __cdecl rzrt_screen_reuse_texture(Context* c){return c?c->screenReuse.texture:0;}
API int __cdecl rzrt_screen_trace(Context* c,const ReflectionCamera* camera,uint64_t scene){try{if(!c||!camera)throw std::runtime_error("No RTX screen camera");return c->screenTrace(camera,scene)?1:0;}catch(const std::exception& e){error=e.what();return -1;}}
API double __cdecl rzrt_screen_ms(Context* c){return c?c->screenMs:0;}
API uint64_t __cdecl rzrt_screen_bytes(Context* c){return c?c->screenDepth.size+c->screenOutput.size+c->screenSamples.size+c->screenReuse.size:0;}
