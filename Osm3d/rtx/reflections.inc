// World-space, single-bounce reflections. The rasterized receiver buffer
// carries the actual glass/wave normal; visibility is hardware ray queried.
void Context::reflectionSize(const wchar_t* shader,uint32_t width,uint32_t height) {
    if(width==reflectionWidth && height==reflectionHeight) return;
    if(!width || !height || width>4096 || height>4096) throw std::runtime_error("Invalid reflection size");
    // Resize only. Never wait for the GPU in the ordinary reflection loop.
    glFinish(); CHECK(DeviceWaitIdle(device));
    destroy(reflectionNormal);destroy(reflectionDepth);destroy(reflectionOutput);destroy(reflectionAtlas);reflectionWidth=0;
    image(reflectionNormal,width,1,VK_FORMAT_R16G16B16A16_SFLOAT,VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT|VK_IMAGE_USAGE_SAMPLED_BIT,height);
    image(reflectionDepth,width,1,VK_FORMAT_D32_SFLOAT,VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT|VK_IMAGE_USAGE_SAMPLED_BIT,height);
    image(reflectionOutput,width,1,VK_FORMAT_R16G16B16A16_SFLOAT,VK_IMAGE_USAGE_STORAGE_BIT|VK_IMAGE_USAGE_SAMPLED_BIT,height);
    GLint oldTexture=0;glGetIntegerv(GL_TEXTURE_BINDING_2D,&oldTexture);
    glBindTexture(GL_TEXTURE_2D,reflectionOutput.texture);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
    glBindTexture(GL_TEXTURE_2D,oldTexture);
    image(reflectionAtlas,1024,1,VK_FORMAT_R8G8B8A8_UNORM,VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT|VK_IMAGE_USAGE_SAMPLED_BIT);
    reflectionWidth=width;reflectionHeight=height;
    VkCommandBuffer cmd=command();begin(cmd);barriers(cmd,false,true,true);CHECK(EndCommandBuffer(cmd));
    VkFence fence=newFence();VkSubmitInfo si{VK_STRUCTURE_TYPE_SUBMIT_INFO};si.commandBufferCount=1;si.pCommandBuffers=&cmd;si.signalSemaphoreCount=1;si.pSignalSemaphores=&done;
    CHECK(QueueSubmit(queue,1,&si,fence));
    GLuint images[]={reflectionNormal.texture,reflectionDepth.texture,reflectionOutput.texture,reflectionAtlas.texture};GLenum layouts[]={0x958D,0x958D,0x958D,0x958D};
    gl.WaitSemaphore(glDone,0,nullptr,4,images,layouts);glFlush();
    CHECK(WaitForFences(device,1,&fence,VK_TRUE,UINT64_MAX));DestroyFence(device,fence,nullptr);FreeCommandBuffers(device,pool,1,&cmd);
    if(reflectionPipeline) return;
    std::ifstream f(shader,std::ios::binary|std::ios::ate);if(!f)throw std::runtime_error("Missing reflection SPIR-V");
    size_t length=static_cast<size_t>(f.tellg());if(!length||length%4)throw std::runtime_error("Invalid reflection SPIR-V");
    std::vector<uint32_t> code(length/4);f.seekg(0);f.read(reinterpret_cast<char*>(code.data()),length);
    VkShaderModuleCreateInfo sm{VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO};sm.codeSize=length;sm.pCode=code.data();VkShaderModule module{};CHECK(CreateShaderModule(device,&sm,nullptr,&module));
    VkComputePipelineCreateInfo cp{VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO};cp.layout=pipeLayout;cp.stage={VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO};cp.stage.stage=VK_SHADER_STAGE_COMPUTE_BIT;cp.stage.module=module;cp.stage.pName="main";
    VkResult r=CreateComputePipelines(device,VK_NULL_HANDLE,1,&cp,nullptr,&reflectionPipeline);DestroyShaderModule(device,module,nullptr);CHECK(r);
}
bool Context::reflect(const ReflectionCamera* camera,uint64_t expectedScene) {
    if(!active || active->id!=expectedScene || !reflectionPipeline) return false;
    Frame& f=acquireFrame();VkResult r;
    if(f.submitted){uint64_t stamps[2]{};r=GetQueryPoolResults(device,queries,frameIndex*2,2,sizeof(stamps),stamps,sizeof(uint64_t),VK_QUERY_RESULT_64_BIT);
        if(r==VK_SUCCESS){double ms=double(stamps[1]-stamps[0])*props.limits.timestampPeriod/1e6;if(f.reflection)reflectionMs=ms;else stats.traceMs=ms;}else if(r!=VK_NOT_READY)CHECK(r);}
    f.scene=active;memcpy(f.views.mapped,camera,sizeof(*camera));
    static_cast<ReflectionCamera*>(f.views.mapped)->depthRange[2]=float(active->opaqueCount);
    VkWriteDescriptorSetAccelerationStructureKHR as{VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET_ACCELERATION_STRUCTURE_KHR};as.accelerationStructureCount=1;as.pAccelerationStructures=&active->tlas;
    VkDescriptorImageInfo ai{sampler,alpha.view,VK_IMAGE_LAYOUT_GENERAL},ni{sampler,reflectionNormal.view,VK_IMAGE_LAYOUT_GENERAL},di{sampler,reflectionDepth.view,VK_IMAGE_LAYOUT_GENERAL},oi{VK_NULL_HANDLE,reflectionOutput.view,VK_IMAGE_LAYOUT_GENERAL},atlas{sampler,reflectionAtlas.view,VK_IMAGE_LAYOUT_GENERAL};
    VkDescriptorBufferInfo cb{active->cards.handle,0,active->cards.size},vb{f.views.handle,0,sizeof(*camera)},sb{active->surfaces.handle,0,active->surfaces.size};
    VkWriteDescriptorSet writes[9]{};uint32_t slots[]={0,2,3,4,5,6,7,8,9};VkDescriptorType types[]={VK_DESCRIPTOR_TYPE_ACCELERATION_STRUCTURE_KHR,VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,VK_DESCRIPTOR_TYPE_STORAGE_BUFFER,VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER};
    for(int i=0;i<9;++i){auto& w=writes[i];w.sType=VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;w.dstSet=f.set;w.dstBinding=slots[i];w.descriptorCount=1;w.descriptorType=types[i];}
    writes[0].pNext=&as;writes[1].pImageInfo=&ai;writes[2].pBufferInfo=&cb;writes[3].pBufferInfo=&vb;writes[4].pImageInfo=&ni;writes[5].pImageInfo=&di;writes[6].pImageInfo=&oi;writes[7].pBufferInfo=&sb;
    writes[8].pImageInfo=&atlas;
    UpdateDescriptorSets(device,9,writes,0,nullptr);CHECK(ResetCommandBuffer(f.cmd,0));begin(f.cmd);barriers(f.cmd,true);
    CmdResetQueryPool(f.cmd,queries,frameIndex*2,2);CmdWriteTimestamp(f.cmd,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,queries,frameIndex*2);
    CmdBindPipeline(f.cmd,VK_PIPELINE_BIND_POINT_COMPUTE,reflectionPipeline);CmdBindDescriptorSets(f.cmd,VK_PIPELINE_BIND_POINT_COMPUTE,pipeLayout,0,1,&f.set,0,nullptr);CmdDispatch(f.cmd,(reflectionWidth+7)/8,(reflectionHeight+7)/8,1);
    CmdWriteTimestamp(f.cmd,VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,queries,frameIndex*2+1);barriers(f.cmd,false);CHECK(EndCommandBuffer(f.cmd));CHECK(ResetFences(device,1,&f.fence));handoff(f.cmd,f.fence);
    f.submitted=true;f.reflection=true;frameIndex=(frameIndex+1)%unsigned(frames.size());++reflectionFrames;return true;
}
API int __cdecl rzrt_reflection_size(Context* c,const wchar_t* shader,uint32_t w,uint32_t h){try{if(!c)throw std::runtime_error("No RTX context");c->reflectionSize(shader,w,h);return 1;}catch(const std::exception& e){error=e.what();return 0;}}
API GLuint __cdecl rzrt_reflection_texture(Context* c,int index){if(!c)return 0;return index==0?c->reflectionNormal.texture:index==1?c->reflectionDepth.texture:index==3?c->reflectionAtlas.texture:c->reflectionOutput.texture;}
API int __cdecl rzrt_reflect(Context* c,const ReflectionCamera* camera,uint64_t scene){try{if(!c||!camera)throw std::runtime_error("No RTX reflection camera");return c->reflect(camera,scene)?1:0;}catch(const std::exception& e){error=e.what();return -1;}}
API double __cdecl rzrt_reflection_ms(Context* c){return c?c->reflectionMs:0;}
