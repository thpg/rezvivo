unit Osm3dRtxDynamic;
{$mode objfpc}{$H+}
interface
uses CastleVectors, CastleTransform, X3DNodes;
type
  { ABI descriptor: Vulkan row-major 3x4, exactly 72 bytes. Indices are local
    to this actor; vertices/indices retain their aggregate buffer ranges. }
  TRtxDynamicActor=packed record
    FirstVertex,VertexCount,FirstIndex,IndexCount:Cardinal;
    Topology:QWord;
    Transform:array[0..11]of Single;
  end;
  { Borrowed render buffers, refreshed after the camera depth pass. }
  TRtxDynamicMesh=record
    Coordinates,Indices,Stride,Count,VertexCount:Cardinal;
    TopologyId,GeometryId:QWord;
    Actor:Integer;
    Transform,WorldTransform:TMatrix4;
    RigidRoot:TX3DNode;
    RigidTransform,RigidWorld:TMatrix4;
  end;
  TRtxDynamicMeshes=class
  private
    FMeshes:array of TRtxDynamicMesh;
    FPreviousMeshes,FOrderedMeshes:array of TRtxDynamicMesh;
    FCount,FTriangles,FVertices,FPosed,FSkipped,FFiltered:Integer;
    FPreviousCount:Integer;
    FTopologyChanged:Boolean;
    FTopologyVersion:QWord;
    FActors:array of TRtxDynamicActor;
    FRigidRoots:array of TX3DNode;
    FActorRevisions:array of QWord;
    FActorCount,FCurrentActor:Integer;
    FActorInverse:TMatrix4;
    FActorPosition:TVector3;
    FCollectLocalActors,FPreviousLocalActors:Boolean;
    FCollectRigidActors,FPreviousRigidActors:Boolean;
    FProgram,FIndexProgram:Cardinal;
    UModel,UBoundsModel,UNormalMatrix,UStride,UCount,UOffset,UVertices,UIndexed,UReceiverBounds:Integer;
    ICount,IOffset,IVertexOffset,IVertices,IIndexed:Integer;
    FOrigin:TVector3;
    procedure CollectNode(const Node:TCastleTransform;const Params:TRenderParams);
    function GetIndexedEnabled:Boolean;
    function GetLocalActorsEnabled:Boolean;
    function GetRigidActorCount:Integer;
    function GetActorsPointer:Pointer;
    function GetActorRevisionsPointer:Pointer;
    procedure UploadCore(const Destination,IndexDestination:Cardinal;const IndicesDirty:Boolean);
  public
    destructor Destroy;override;
    procedure Collect(const Casters:TCastleTransformList;const Origin:TVector3;const Params:TRenderParams);
    procedure Upload(const Destination:Cardinal);
    procedure UploadIndexed(const Destination,IndexDestination:Cardinal;const IndicesDirty:Boolean);
    property Triangles:Integer read FTriangles;
    property VertexCount:Integer read FVertices;
    property TopologyVersion:QWord read FTopologyVersion;
    property IndexedEnabled:Boolean read GetIndexedEnabled;
    property ActorCount:Integer read FActorCount;
    property ActorsPointer:Pointer read GetActorsPointer;
    property ActorRevisionsPointer:Pointer read GetActorRevisionsPointer;
    property LocalActorsEnabled:Boolean read GetLocalActorsEnabled;
    property RigidActorCount:Integer read GetRigidActorCount;
    property Posed:Integer read FPosed;
    property Skipped:Integer read FSkipped;
    property Filtered:Integer read FFiltered;
  end;
implementation
uses SysUtils,Math,CastleGL,CastleScene,CastleShapes,CastleInternalRenderer,
  CastleInternalGeometryArrays,CastleRenderContext,Osm3dRtxScreenState,Osm3dRtxRigidGroups;
const
  GATHER='#version 430'#10+
    'layout(local_size_x=128) in;'#10+
    'layout(std430,binding=0) readonly buffer Vertex {float v[];};'#10+
    'layout(std430,binding=1) readonly buffer Index {uint ix[];};'#10+
    'layout(std430,binding=2) buffer Output {uvec4 result[];};'#10+
    'uniform mat4 model,boundsModel,normalMatrix;uniform uint stride,count,offset,vertices;uniform int indexed;'#10+
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
    'result[2u+offset+i]=uvec4(floatBitsToUint(p),normalCode);if(receiverBounds)orderedP=ordered((boundsModel*vec4(v[j],v[j+1u],v[j+2u],1.)).xyz);}'#10+
    'if(!receiverBounds)return;'#10+
    'boundsLo[l]=i<count?orderedP:uvec3(0xffffffffu);boundsHi[l]=i<count?orderedP:uvec3(0);barrier();'#10+
    'for(uint step=64u;step>0u;step>>=1u){if(l<step){boundsLo[l]=min(boundsLo[l],boundsLo[l+step]);'#10+
    'boundsHi[l]=max(boundsHi[l],boundsHi[l+step]);}barrier();}'#10+
    'if(l==0u){atomicMin(result[0].x,boundsLo[0].x);atomicMin(result[0].y,boundsLo[0].y);atomicMin(result[0].z,boundsLo[0].z);'#10+
    'atomicMax(result[1].x,boundsHi[0].x);atomicMax(result[1].y,boundsHi[0].y);atomicMax(result[1].z,boundsHi[0].z);}}'#10;
  GATHER_INDICES='#version 430'#10+
    'layout(local_size_x=128) in;'#10+
    'layout(std430,binding=1) readonly buffer Index {uint ix[];};'#10+
    'layout(std430,binding=3) writeonly buffer OutputIndex {uint resultIndex[];};'#10+
    'uniform uint count,offset,vertexOffset,vertices;uniform int indexed;'#10+
    'void main(){uint i=gl_GlobalInvocationID.x;if(i>=count)return;'#10+
    'uint j=indexed!=0?ix[i]:i;resultIndex[offset+i]=vertexOffset+min(j,vertices-1u);}'#10;
var LastDynamicTopologyVersion:QWord=0;

function TRtxDynamicMeshes.GetIndexedEnabled:Boolean;
begin
  Result:=GetEnvironmentVariable('REZVIVO_RTX_DYNAMIC_INDEXED')<>'0';
end;
function TRtxDynamicMeshes.GetLocalActorsEnabled:Boolean;
begin Result:=FCollectLocalActors end;
function TRtxDynamicMeshes.GetRigidActorCount:Integer;
var I:Integer;
begin
  { Diagnostic only: revisions already distinguish deforming and rigid groups.
    A bounded scan here adds no work to ordinary collect/upload frames. }
  Result:=0;
  if not FCollectLocalActors then Exit;
  for I:=0 to FActorCount-1 do
    if FActorRevisions[I]<>0 then Inc(Result);
end;
function TRtxDynamicMeshes.GetActorsPointer:Pointer;
begin if FActorCount>0 then Result:=@FActors[0] else Result:=nil end;
function TRtxDynamicMeshes.GetActorRevisionsPointer:Pointer;
begin if FActorCount>0 then Result:=@FActorRevisions[0] else Result:=nil end;

procedure TRtxDynamicMeshes.CollectNode(const Node:TCastleTransform;const Params:TRenderParams);
var Scene:TCastleScene;Shapes:TShapeList;Shape:TX3DRendererShape;HasPose:Boolean;
  I,J,K,L:Integer;Mesh:TRtxDynamicMesh;M,Local,GroupMatrix:TMatrix4;V,W:Double;
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
      Mesh.TopologyId:=Shape.DeformedQueryTopology;
      Mesh.GeometryId:=Shape.DeformedQueryGeometry;
      Mesh.Stride:=Mesh.Stride div SizeOf(Single);if HasPose then Inc(FPosed);
      Mesh.Count:=(Mesh.Count div 3)*3;if Mesh.Count=0 then Continue;
      M:=Scene.WorldTransform;Local:=Shape.State.Transform;Mesh.Transform:=M*Local;
      for J:=0 to 2 do begin
        V:=Double(M.Data[3,J])-FOrigin.Data[J];
        for K:=0 to 2 do V:=V+Double(M.Data[K,J])*Local.Data[3,K];
        Mesh.Transform.Data[3,J]:=V;
      end;
      Mesh.WorldTransform:=Mesh.Transform;Mesh.Actor:=FCurrentActor;
      if FCollectRigidActors and not HasPose and
        RigidBikeGroup(Shape.Node,Scene.RootNode,Mesh.RigidRoot,Mesh.RigidTransform,GroupMatrix)then begin
        Mesh.RigidWorld:=M*GroupMatrix;
        for J:=0 to 2 do begin
          V:=Double(M.Data[3,J])-FOrigin.Data[J];
          for K:=0 to 2 do V:=V+Double(M.Data[K,J])*GroupMatrix.Data[3,K];
          Mesh.RigidWorld.Data[3,J]:=V;
        end;
      end;
      if FCollectLocalActors then begin
        Mesh.Transform:=FActorInverse*M*Local;
        { Preserve centimetre detail even when an actor is far from the map
          origin: subtract translations in double before inverse rotation. }
        for J:=0 to 2 do begin
          V:=0;
          for K:=0 to 2 do begin
            W:=Double(M.Data[3,K])-FActorPosition.Data[K];
            for L:=0 to 2 do W:=W+Double(M.Data[L,K])*Local.Data[3,L];
            V:=V+Double(FActorInverse.Data[K,J])*W;
          end;
          Mesh.Transform.Data[3,J]:=V;
        end;
      end;
      if FCount=Length(FMeshes) then SetLength(FMeshes,Max(64,FCount*2));
      FMeshes[FCount]:=Mesh;Inc(FCount);Inc(FTriangles,Mesh.Count div 3);Inc(FVertices,Mesh.VertexCount);
    end;
    finally Params.Transformation:=SavedTransform;end;
  end;
  for I:=0 to Node.Count-1 do CollectNode(Node[I],Params);
end;
procedure TRtxDynamicMeshes.Collect(const Casters:TCastleTransformList;const Origin:TVector3;const Params:TRenderParams);
var I,J,K,Q,N,G,PreviousActors,FirstMesh,FirstVertex,FirstIndex,GroupFirst,RootCount:Integer;
  Actor:TRtxDynamicActor;M:TMatrix4;
  Temporary:array of TRtxDynamicMesh;Changed,GeometryChanged:Boolean;
  procedure PublishGroup(const First,Last:Integer;const Rigid:Boolean);
  var A,B:Integer;
  begin
    Actor:=Default(TRtxDynamicActor);Actor.FirstVertex:=FirstVertex;Actor.FirstIndex:=FirstIndex;
    Changed:=False;GeometryChanged:=False;
    for A:=First to Last do begin
      FMeshes[A].Actor:=FActorCount;
      if Rigid then FMeshes[A].Transform:=FMeshes[A].RigidTransform;
      Inc(Actor.VertexCount,FMeshes[A].VertexCount);Inc(Actor.IndexCount,FMeshes[A].Count);
      if(A>=FPreviousCount)or(FMeshes[A].TopologyId<>FPreviousMeshes[A].TopologyId)or
        (FMeshes[A].VertexCount<>FPreviousMeshes[A].VertexCount)or
        (FMeshes[A].Count<>FPreviousMeshes[A].Count)or
        ((FMeshes[A].Indices=0)<>(FPreviousMeshes[A].Indices=0))then Changed:=True;
      if(A>=FPreviousCount)or(FMeshes[A].GeometryId<>FPreviousMeshes[A].GeometryId)or
        not CompareMem(@FMeshes[A].Transform,@FPreviousMeshes[A].Transform,SizeOf(TMatrix4))then GeometryChanged:=True;
    end;
    if FActorCount=Length(FActors)then begin
      SetLength(FActors,Max(8,FActorCount*2));SetLength(FActorRevisions,Length(FActors));
    end;
    Changed:=Changed or(FActorCount>=PreviousActors)or
      (Actor.FirstVertex<>FActors[FActorCount].FirstVertex)or(Actor.FirstIndex<>FActors[FActorCount].FirstIndex)or
      (Actor.VertexCount<>FActors[FActorCount].VertexCount)or(Actor.IndexCount<>FActors[FActorCount].IndexCount);
    if Changed then begin
      Inc(LastDynamicTopologyVersion);Actor.Topology:=LastDynamicTopologyVersion;FTopologyChanged:=True;
    end else Actor.Topology:=FActors[FActorCount].Topology;
    if Rigid then begin
      M:=FMeshes[First].RigidWorld;
      if Changed or GeometryChanged or(FActorRevisions[FActorCount]=0)then begin
        Inc(LastDynamicTopologyVersion);FActorRevisions[FActorCount]:=LastDynamicTopologyVersion;
      end;
    end else FActorRevisions[FActorCount]:=0;
    for A:=0 to 2 do for B:=0 to 3 do Actor.Transform[A*4+B]:=M.Data[B,A];
    FActors[FActorCount]:=Actor;Inc(FActorCount);
    Inc(FirstVertex,Actor.VertexCount);Inc(FirstIndex,Actor.IndexCount);
  end;
begin
  PreviousActors:=FActorCount;FActorCount:=0;
  FPreviousCount:=FCount;FCount:=0;FTriangles:=0;FVertices:=0;FPosed:=0;FSkipped:=0;FFiltered:=0;FOrigin:=Origin;
  { Swap reusable arrays: compare after stable grouping, never compare a newly
    collected order with last frame's already-grouped order. }
  Temporary:=FPreviousMeshes;FPreviousMeshes:=FMeshes;FMeshes:=Temporary;
  FCollectLocalActors:=GetIndexedEnabled and((GetEnvironmentVariable('REZVIVO_RTX_LOCAL_ACTORS')='1')or
    (GetEnvironmentVariable('REZVIVO_RTX_RIGID_ACTORS')='1'));
  FCollectRigidActors:=FCollectLocalActors and(GetEnvironmentVariable('REZVIVO_RTX_RIGID_ACTORS')='1');
  FTopologyChanged:=False;
  if Casters<>nil then for I:=0 to Casters.Count-1 do begin
    if(Casters[I]=nil)or not Casters[I].ExistsInRoot or not Casters[I].Visible then Continue;
    FirstVertex:=FVertices;FirstIndex:=FTriangles*3;FirstMesh:=FCount;
    FCurrentActor:=FActorCount;
    if FCollectLocalActors then begin
      FActorInverse:=Casters[I].WorldInverseTransform;M:=Casters[I].WorldTransform;
      FActorPosition:=Vector3(M.Data[3,0],M.Data[3,1],M.Data[3,2]);
    end;
    CollectNode(Casters[I],Params);if FCount=FirstMesh then Continue;
    M:=Casters[I].WorldTransform;
    for J:=0 to 2 do M.Data[3,J]:=Double(M.Data[3,J])-FOrigin.Data[J];
    if not FCollectRigidActors then PublishGroup(FirstMesh,FCount-1,False)
    else begin
      { A small fixed set of articulation groups, not one BLAS per bike part.
        Stable first-occurrence order also preserves triangle order within each
        group. Source topology IDs protect reused node addresses. }
      RootCount:=0;
      for J:=FirstMesh to FCount-1 do begin
        G:=-1;for K:=0 to RootCount-1 do if FRigidRoots[K]=FMeshes[J].RigidRoot then begin G:=K;Break end;
        if G<0 then begin G:=RootCount;Inc(RootCount);
          if RootCount>Length(FRigidRoots)then SetLength(FRigidRoots,Max(8,RootCount*2));
          FRigidRoots[G]:=FMeshes[J].RigidRoot end;
      end;
      if Length(FOrderedMeshes)<FCount-FirstMesh then SetLength(FOrderedMeshes,FCount-FirstMesh);
      Q:=0;
      for G:=0 to RootCount-1 do for J:=FirstMesh to FCount-1 do if FMeshes[J].RigidRoot=FRigidRoots[G]then begin
        FOrderedMeshes[Q]:=FMeshes[J];Inc(Q);
      end;
      Move(FOrderedMeshes[0],FMeshes[FirstMesh],Q*SizeOf(TRtxDynamicMesh));
      GroupFirst:=FirstMesh;
      for G:=0 to RootCount-1 do begin
        N:=GroupFirst;while(N<FCount)and(FMeshes[N].RigidRoot=FRigidRoots[G])do Inc(N);
        M:=Casters[I].WorldTransform;
        for J:=0 to 2 do M.Data[3,J]:=Double(M.Data[3,J])-FOrigin.Data[J];
        PublishGroup(GroupFirst,N-1,FRigidRoots[G]<>nil);GroupFirst:=N;
      end;
    end;
  end;
  { Native actor metadata is deliberately bounded. An unusually large scene
    keeps every triangle through the indexed world path instead of failing
    the entire shadow pass or silently dropping actors. }
  if FCollectLocalActors and(FActorCount>128)then begin
    FCollectLocalActors:=False;
    for I:=0 to FCount-1 do FMeshes[I].Transform:=FMeshes[I].WorldTransform;
  end;
  FTopologyChanged:=FTopologyChanged or(FPreviousLocalActors<>FCollectLocalActors)or
    (FPreviousRigidActors<>FCollectRigidActors);
  FPreviousLocalActors:=FCollectLocalActors;FPreviousRigidActors:=FCollectRigidActors;
  if FTopologyChanged or(FCount<>FPreviousCount)or(FTopologyVersion=0)then begin
    Inc(LastDynamicTopologyVersion);FTopologyVersion:=LastDynamicTopologyVersion;
  end;
end;
procedure TRtxDynamicMeshes.Upload(const Destination:Cardinal);
begin UploadCore(Destination,0,False);end;

procedure TRtxDynamicMeshes.UploadIndexed(const Destination,IndexDestination:Cardinal;const IndicesDirty:Boolean);
begin
  { A world-only Studio frame has no actors and deliberately receives no
    shared vertex/index buffers from the bridge. This is a valid empty gather. }
  if FTriangles=0 then Exit;
  if IndexDestination=0 then raise Exception.Create('RTX indexed gather needs an index buffer');
  UploadCore(Destination,IndexDestination,IndicesDirty);
end;

procedure TRtxDynamicMeshes.UploadCore(const Destination,IndexDestination:Cardinal;const IndicesDirty:Boolean);
var Shader:Cardinal;OK,L,OldProgram,OldBuffer:GLint;Source:PChar;Log:string;
  Bindings:array[0..3] of GLint;Starts,Sizes:array[0..3] of GLint64;
  I:Integer;Offset,IndexOffset,DispatchCount:Cardinal;M:TRtxDynamicMesh;NormalMatrix,PreviousTransform:TMatrix4;
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
      UBoundsModel:=glGetUniformLocation(FProgram,'boundsModel');
      UStride:=glGetUniformLocation(FProgram,'stride');UCount:=glGetUniformLocation(FProgram,'count');
      UOffset:=glGetUniformLocation(FProgram,'offset');UVertices:=glGetUniformLocation(FProgram,'vertices');
      UIndexed:=glGetUniformLocation(FProgram,'indexed');UReceiverBounds:=glGetUniformLocation(FProgram,'receiverBounds');
    finally glDeleteShader(Shader);end;
  end;
  if (IndexDestination<>0) and IndicesDirty and (FIndexProgram=0) then begin
    Shader:=glCreateShader(GL_COMPUTE_SHADER);Source:=PChar(GATHER_INDICES);
    try
      glShaderSource(Shader,1,@Source,nil);glCompileShader(Shader);glGetShaderiv(Shader,GL_COMPILE_STATUS,@OK);
      if OK=0 then begin
        glGetShaderiv(Shader,GL_INFO_LOG_LENGTH,@L);SetLength(Log,Max(1,L));glGetShaderInfoLog(Shader,L,nil,PChar(Log));raise Exception.Create(Log);
      end;
      FIndexProgram:=glCreateProgram();glAttachShader(FIndexProgram,Shader);glLinkProgram(FIndexProgram);glGetProgramiv(FIndexProgram,GL_LINK_STATUS,@OK);
      if OK=0 then begin glDeleteProgram(FIndexProgram);FIndexProgram:=0;raise Exception.Create('RTX dynamic index gather link failed');end;
      ICount:=glGetUniformLocation(FIndexProgram,'count');IOffset:=glGetUniformLocation(FIndexProgram,'offset');
      IVertexOffset:=glGetUniformLocation(FIndexProgram,'vertexOffset');IVertices:=glGetUniformLocation(FIndexProgram,'vertices');
      IIndexed:=glGetUniformLocation(FIndexProgram,'indexed');
    finally glDeleteShader(Shader);end;
  end;
  glGetIntegerv(GL_CURRENT_PROGRAM,@OldProgram);glGetIntegerv(GL_SHADER_STORAGE_BUFFER_BINDING,@OldBuffer);
  for I:=0 to 3 do begin
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
      if RtxScreenReceiverBounds then glUniformMatrix4fv(UBoundsModel,1,GL_FALSE,@M.WorldTransform.Data[0,0]);
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
      if IndexDestination<>0 then DispatchCount:=M.VertexCount else DispatchCount:=M.Count;
      glUniform1ui(UStride,M.Stride);glUniform1ui(UCount,DispatchCount);
      glUniform1ui(UOffset,Offset);glUniform1ui(UVertices,M.VertexCount);
      glUniform1i(UIndexed,Ord((IndexDestination=0) and (M.Indices<>0)));
      glDispatchCompute((DispatchCount+127) div 128,1,1);Inc(Offset,DispatchCount);
    end;
    if (IndexDestination<>0) and IndicesDirty then begin
      { Immutable indices are rebuilt once for each flight slot/topology, never
        read back or resubmitted because a pose, camera or origin moved. }
      glUseProgram(FIndexProgram);glBindBufferBase(GL_SHADER_STORAGE_BUFFER,3,IndexDestination);
      Offset:=0;IndexOffset:=0;
      for I:=0 to FCount-1 do begin
        M:=FMeshes[I];
        if M.Indices<>0 then glBindBufferBase(GL_SHADER_STORAGE_BUFFER,1,M.Indices)
        else glBindBufferBase(GL_SHADER_STORAGE_BUFFER,1,M.Coordinates);
        glUniform1ui(ICount,M.Count);glUniform1ui(IOffset,IndexOffset);
        if FCollectLocalActors then glUniform1ui(IVertexOffset,Offset-FActors[M.Actor].FirstVertex)
        else glUniform1ui(IVertexOffset,Offset);
        glUniform1ui(IVertices,M.VertexCount);
        glUniform1i(IIndexed,Ord(M.Indices<>0));
        glDispatchCompute((M.Count+127) div 128,1,1);
        Inc(Offset,M.VertexCount);Inc(IndexOffset,M.Count);
      end;
    end;
    glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT);
  finally
    for I:=0 to 3 do
      if (Bindings[I]<>0) and (Sizes[I]>0) then glBindBufferRange(GL_SHADER_STORAGE_BUFFER,I,Bindings[I],Starts[I],Sizes[I])
      else glBindBufferBase(GL_SHADER_STORAGE_BUFFER,I,Bindings[I]);
    glBindBuffer(GL_SHADER_STORAGE_BUFFER,OldBuffer);glUseProgram(OldProgram);
  end;
end;
destructor TRtxDynamicMeshes.Destroy;
begin
  if FProgram<>0 then glDeleteProgram(FProgram);
  if FIndexProgram<>0 then glDeleteProgram(FIndexProgram);
  inherited;
end;
end.
