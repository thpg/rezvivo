unit Osm3dRtxDynamic;
{$mode objfpc}{$H+}
interface
uses CastleVectors, CastleTransform;
type
  { Borrowed render buffers, refreshed after the camera depth pass. }
  TRtxDynamicMesh=record
    Coordinates,Indices,Stride,Count,VertexCount:Cardinal;
    Transform:TMatrix4;
  end;
  TRtxDynamicMeshes=class
  private
    FMeshes:array of TRtxDynamicMesh;
    FCount,FTriangles,FPosed,FSkipped,FFiltered:Integer;
    FProgram:Cardinal;
    UModel,UNormalMatrix,UStride,UCount,UOffset,UVertices,UIndexed,UReceiverBounds:Integer;
    FOrigin:TVector3;
    procedure CollectNode(const Node:TCastleTransform;const Params:TRenderParams);
  public
    destructor Destroy;override;
    procedure Collect(const Casters:TCastleTransformList;const Origin:TVector3;const Params:TRenderParams);
    procedure Upload(const Destination:Cardinal);
    property Triangles:Integer read FTriangles;
    property Posed:Integer read FPosed;
    property Skipped:Integer read FSkipped;
    property Filtered:Integer read FFiltered;
  end;
implementation
uses SysUtils,Math,CastleGL,CastleScene,CastleShapes,CastleInternalRenderer,
  CastleInternalGeometryArrays,CastleRenderContext,Osm3dRtxScreenState;
const
  GATHER='#version 430'#10+
    'layout(local_size_x=128) in;'#10+
    'layout(std430,binding=0) readonly buffer Vertex {float v[];};'#10+
    'layout(std430,binding=1) readonly buffer Index {uint ix[];};'#10+
    'layout(std430,binding=2) buffer Output {uvec4 result[];};'#10+
    'uniform mat4 model,normalMatrix;uniform uint stride,count,offset,vertices;uniform int indexed;'#10+
    'uniform bool receiverBounds;shared uvec3 boundsLo[128],boundsHi[128];'#10+
    'uvec3 ordered(vec3 p){uvec3 b=floatBitsToUint(p);return b^((uvec3(0)-(b>>31u))|uvec3(0x80000000u));}'#10+
    'vec2 octNormal(vec3 n){n/=abs(n.x)+abs(n.y)+abs(n.z);'#10+
    'return n.z>=0.?n.xy:(1.-abs(n.yx))*mix(vec2(-1),vec2(1),greaterThanEqual(n.xy,vec2(0)));}'#10+
    'void main(){uint i=gl_GlobalInvocationID.x,l=gl_LocalInvocationID.x;uvec3 orderedP=uvec3(0);'#10+
    'if(i<count){'#10+
    'uint j=indexed!=0?ix[i]:i;j=min(j,vertices-1u)*stride;'#10+
    'vec3 p=(model*vec4(v[j],v[j+1u],v[j+2u],1.)).xyz;uint normalCode=0u;'#10+
    'if(stride>=6u){vec3 n=mat3(normalMatrix)*vec3(v[j+3u],v[j+4u],v[j+5u]);'#10+
    'if(dot(n,n)>1e-12)normalCode=max(1u,packSnorm2x16(octNormal(normalize(n))));}'#10+
    'result[2u+offset+i]=uvec4(floatBitsToUint(p),normalCode);if(receiverBounds)orderedP=ordered(p);}'#10+
    'if(!receiverBounds)return;'#10+
    'boundsLo[l]=i<count?orderedP:uvec3(0xffffffffu);boundsHi[l]=i<count?orderedP:uvec3(0);barrier();'#10+
    'for(uint step=64u;step>0u;step>>=1u){if(l<step){boundsLo[l]=min(boundsLo[l],boundsLo[l+step]);'#10+
    'boundsHi[l]=max(boundsHi[l],boundsHi[l+step]);}barrier();}'#10+
    'if(l==0u){atomicMin(result[0].x,boundsLo[0].x);atomicMin(result[0].y,boundsLo[0].y);atomicMin(result[0].z,boundsLo[0].z);'#10+
    'atomicMax(result[1].x,boundsHi[0].x);atomicMax(result[1].y,boundsHi[0].y);atomicMax(result[1].z,boundsHi[0].z);}}'#10;
procedure TRtxDynamicMeshes.CollectNode(const Node:TCastleTransform;const Params:TRenderParams);
var Scene:TCastleScene;Shapes:TShapeList;Shape:TX3DRendererShape;HasPose:Boolean;
  I,J,K:Integer;Mesh:TRtxDynamicMesh;M,Local:TMatrix4;V:Double;
  SavedTransform:PTransformation;SceneTransform:TTransformation;
begin
  if (Node=nil) or not Node.ExistsInRoot or not Node.Visible or not Node.CastShadows then Exit;
  if Node is TCastleScene then begin
    Scene:=TCastleScene(Node);Shapes:=Scene.Shapes.TraverseList(True,True,False);
    SavedTransform:=Params.Transformation;
    SceneTransform:=IdentityTransformation;
    SceneTransform.Transform:=Scene.WorldTransform;
    SceneTransform.InverseTransform:=Scene.WorldInverseTransform;
    Params.Transformation:=@SceneTransform;
    try
    for I:=0 to Shapes.Count-1 do begin
      if not (Shapes[I] is TX3DRendererShape) then Continue;
      Shape:=TX3DRendererShape(Shapes[I]);Mesh:=Default(TRtxDynamicMesh);
      if not Shape.ShadowCaster then Continue;
      { TraverseList filters graph nodes, but not Shape.Visible or the scene's
        render filter. Inactive clothing and previously drawn LOD buffers must
        never become invisible occluders. Use the colour/depth pass selection. }
      if ((Shape.Node<>nil) and not Shape.Node.Visible) or
         (Assigned(Scene.OnRenderShapeFilter) and not Scene.OnRenderShapeFilter(Shape.Node,Params)) then
      begin Inc(FFiltered);Continue;end;
      if not Shape.DeformedQueryBuffers(Mesh.Coordinates,Mesh.Indices,Mesh.Stride,Mesh.VertexCount,Mesh.Count,HasPose) then begin Inc(FSkipped);Continue;end;
      Mesh.Stride:=Mesh.Stride div SizeOf(Single);if HasPose then Inc(FPosed);
      Mesh.Count:=(Mesh.Count div 3)*3;if Mesh.Count=0 then Continue;
      M:=Scene.WorldTransform;Local:=Shape.State.Transform;Mesh.Transform:=M*Local;
      for J:=0 to 2 do begin
        V:=Double(M.Data[3,J])-FOrigin.Data[J];
        for K:=0 to 2 do V:=V+Double(M.Data[K,J])*Local.Data[3,K];
        Mesh.Transform.Data[3,J]:=V;
      end;
      if FCount=Length(FMeshes) then SetLength(FMeshes,Max(64,FCount*2));
      FMeshes[FCount]:=Mesh;Inc(FCount);Inc(FTriangles,Mesh.Count div 3);
    end;
    finally Params.Transformation:=SavedTransform;end;
  end;
  for I:=0 to Node.Count-1 do CollectNode(Node[I],Params);
end;
procedure TRtxDynamicMeshes.Collect(const Casters:TCastleTransformList;const Origin:TVector3;const Params:TRenderParams);
var I:Integer;
begin
  FCount:=0;FTriangles:=0;FPosed:=0;FSkipped:=0;FFiltered:=0;FOrigin:=Origin;
  if Casters<>nil then for I:=0 to Casters.Count-1 do CollectNode(Casters[I],Params);
end;
procedure TRtxDynamicMeshes.Upload(const Destination:Cardinal);
var Shader:Cardinal;OK,L,OldProgram,OldBuffer:GLint;Source:PChar;Log:string;
  Bindings:array[0..2] of GLint;Starts,Sizes:array[0..2] of GLint64;
  I:Integer;Offset:Cardinal;M:TRtxDynamicMesh;NormalMatrix,PreviousTransform:TMatrix4;
  HaveTransform:Boolean;
  BoundsHeader:array[0..7]of Cardinal;
begin
  if FTriangles=0 then Exit;
  if FProgram=0 then begin
    Shader:=glCreateShader(GL_COMPUTE_SHADER);Source:=PChar(GATHER);
    try
      glShaderSource(Shader,1,@Source,nil);glCompileShader(Shader);glGetShaderiv(Shader,GL_COMPILE_STATUS,@OK);
      if OK=0 then begin
        glGetShaderiv(Shader,GL_INFO_LOG_LENGTH,@L);SetLength(Log,Max(1,L));glGetShaderInfoLog(Shader,L,nil,PChar(Log));raise Exception.Create(Log);
      end;
      FProgram:=glCreateProgram();glAttachShader(FProgram,Shader);glLinkProgram(FProgram);glGetProgramiv(FProgram,GL_LINK_STATUS,@OK);
      if OK=0 then begin glDeleteProgram(FProgram);FProgram:=0;raise Exception.Create('RTX dynamic gather link failed');end;
      { Locations belong to the linked program, not to a mesh or frame. }
      UModel:=glGetUniformLocation(FProgram,'model');UNormalMatrix:=glGetUniformLocation(FProgram,'normalMatrix');
      UStride:=glGetUniformLocation(FProgram,'stride');UCount:=glGetUniformLocation(FProgram,'count');
      UOffset:=glGetUniformLocation(FProgram,'offset');UVertices:=glGetUniformLocation(FProgram,'vertices');
      UIndexed:=glGetUniformLocation(FProgram,'indexed');UReceiverBounds:=glGetUniformLocation(FProgram,'receiverBounds');
    finally glDeleteShader(Shader);end;
  end;
  glGetIntegerv(GL_CURRENT_PROGRAM,@OldProgram);glGetIntegerv(GL_SHADER_STORAGE_BUFFER_BINDING,@OldBuffer);
  for I:=0 to 2 do begin
    glGetIntegeri_v(GL_SHADER_STORAGE_BUFFER_BINDING,I,@Bindings[I]);
    glGetInteger64i_v(GL_SHADER_STORAGE_BUFFER_START,I,@Starts[I]);glGetInteger64i_v(GL_SHADER_STORAGE_BUFFER_SIZE,I,@Sizes[I]);
  end;
  try
    glMemoryBarrier(GL_TRANSFORM_FEEDBACK_BARRIER_BIT or GL_SHADER_STORAGE_BARRIER_BIT);
    glUseProgram(FProgram);glBindBufferBase(GL_SHADER_STORAGE_BUFFER,2,Destination);Offset:=0;
    if RtxScreenReceiverBounds then begin
      { No readback: the first two vectors are a shared, ordered-float AABB.
        Reduce within each workgroup before issuing only six global atomics. }
      for I:=0 to 3 do BoundsHeader[I]:=High(Cardinal);
      for I:=4 to 7 do BoundsHeader[I]:=0;
      glBufferSubData(GL_SHADER_STORAGE_BUFFER,0,SizeOf(BoundsHeader),@BoundsHeader[0]);
    end;
    glUniform1i(UReceiverBounds,Ord(RtxScreenReceiverBounds));
    HaveTransform:=False;PreviousTransform:=TMatrix4.Identity;
    for I:=0 to FCount-1 do begin
      M:=FMeshes[I];glBindBufferBase(GL_SHADER_STORAGE_BUFFER,0,M.Coordinates);
      if M.Indices<>0 then glBindBufferBase(GL_SHADER_STORAGE_BUFFER,1,M.Indices)
      else glBindBufferBase(GL_SHADER_STORAGE_BUFFER,1,M.Coordinates);
      { Body parts often share exactly the same model matrix. Retain its
        inverse and the uniforms within this upload only; no frame or driver
        state assumptions, and no approximate matrix comparison. }
      if not HaveTransform or not CompareMem(@M.Transform,@PreviousTransform,SizeOf(TMatrix4)) then begin
        glUniformMatrix4fv(UModel,1,GL_FALSE,@M.Transform.Data[0,0]);
        if not M.Transform.TryInverse(NormalMatrix) then NormalMatrix:=TMatrix4.Identity;
        NormalMatrix:=NormalMatrix.Transpose;
        glUniformMatrix4fv(UNormalMatrix,1,GL_FALSE,@NormalMatrix.Data[0,0]);
        PreviousTransform:=M.Transform;HaveTransform:=True;
      end;
      glUniform1ui(UStride,M.Stride);glUniform1ui(UCount,M.Count);
      glUniform1ui(UOffset,Offset);glUniform1ui(UVertices,M.VertexCount);
      glUniform1i(UIndexed,Ord(M.Indices<>0));glDispatchCompute((M.Count+127) div 128,1,1);Inc(Offset,M.Count);
    end;
    glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT);
  finally
    for I:=0 to 2 do
      if (Bindings[I]<>0) and (Sizes[I]>0) then glBindBufferRange(GL_SHADER_STORAGE_BUFFER,I,Bindings[I],Starts[I],Sizes[I])
      else glBindBufferBase(GL_SHADER_STORAGE_BUFFER,I,Bindings[I]);
    glBindBuffer(GL_SHADER_STORAGE_BUFFER,OldBuffer);glUseProgram(OldProgram);
  end;
end;
destructor TRtxDynamicMeshes.Destroy;
begin if FProgram<>0 then glDeleteProgram(FProgram);inherited;end;
end.
