unit TreeNeedleMesh;
{$mode objfpc}{$H+}
{$ifdef ANDROID}{$define OpenGLES}{$endif}
interface
uses SysUtils, Classes, {$ifdef OpenGLES}CastleGLES{$else}GL,GLExt{$endif};
type
  { Owns only an optional program. Shoot descriptors stay in the existing VBO.
    Uniforms are mirrored from CPU uploads, never read back from the driver. }
  TTreeNeedleMesh = class
  private
    FProgram:GLuint;
    FDrawPointer:Pointer;
    FMap:array of Integer;
    FUniforms:array of record
      Location:GLint;
      Kind:GLenum;
      Count:Integer;
      Dirty,Valid:Boolean;
      Data:array[0..15]of Single;
    end;
    FFirst,FCull:GLint;
    FLastFirst,FLastCull:Integer;
    FNeedlesPerGroup:Integer;
    FMaxDrawGroups:GLuint;
    function Compile(Kind:GLenum;const Source:string):GLuint;
  public
    constructor Create(SourceProgram:GLuint;const VertexSource,FragmentSource:string);
    destructor Destroy;override;
    procedure Remember(Location:GLint;Count:Integer;Data:Pointer);
    function Draw(Buffer:GLuint;First,Count,NeedlesPerShoot:Integer;SourceProgram:GLuint):Integer;
  end;
function NeedleMeshVertexSource(const Source:string):string;
function NeedleMeshFragmentSource(const Source:string):string;
function NeedleMeshSupported(out Reason:string):Boolean;
var
  { 0 ordinary vertex path, 1 mesh, 2 mesh plus conservative shoot frustum test.
    Optional experiment; unsupported contexts always keep the ordinary path. }
  TreeNeedleMeshMode:Integer=0;
  TreeNeedleMeshStatus:string='disabled';
  TreeNeedleMeshDraws,TreeNeedleMeshGroups:QWord;
implementation
uses Math,TreeShaderSource{$ifdef MSWINDOWS},Windows{$endif};
const
  MeshShaderNV=$9559;
  StorageBuffer=$90D2;
  StorageBinding=$90D3;
  StorageStart=$90D4;
  StorageSize=$90D5;
  StorageSlot=7;
type
  TDrawMesh=procedure(First,Count:GLuint);{$ifdef MSWINDOWS}stdcall{$else}cdecl{$endif};

function ReplaceRequired(const Source,OldText,NewText:string):string;
begin
  if Pos(OldText,Source)=0 then
    raise Exception.Create('Needle mesh source contract changed: '+OldText);
  Result:=StringReplace(Source,OldText,NewText,[]);
end;

function NeedleMeshSupported(out Reason:string):Boolean;
{$ifndef OpenGLES}var I,N:GLint;{$endif}
begin
  Result:=False;Reason:='GL_NV_mesh_shader unavailable';
  {$ifdef MSWINDOWS}{$ifndef OpenGLES}
  if not Assigned(glGetStringi) then Exit;
  glGetIntegerv(GL_NUM_EXTENSIONS,@N);
  for I:=0 to N-1 do
    if string(PChar(glGetStringi(GL_EXTENSIONS,I)))='GL_NV_mesh_shader' then begin
      Result:=wglGetProcAddress('glDrawMeshTasksNV')<>nil;
      if Result then Reason:='GL_NV_mesh_shader';Exit;
    end;
  {$endif}{$endif}
end;

function NeedleMeshFragmentSource(const Source:string):string;
begin
  Result:=ReplaceRequired(RenderShaderSource(Source,False),'#version 330 core','#version 450 core');
  Result:=ReplaceRequired(Result,'uniform int uKind, uSpecies, uDebug;',
    'const int uKind=5; uniform int uSpecies, uDebug;');
end;

function MeshGroupSize:Integer;
begin Result:=EnsureRange(StrToIntDef(SysUtils.GetEnvironmentVariable('REZVIVO_TREE_MESH_GROUP'),8),8,32) end;

function NeedleMeshVertexSource(const Source:string):string;
var Lines,Names,Parts:TStringList;I,J,K,P:Integer;
  S,Prefix,Body,Name,Kind,Qualifier,ExportCode,Declarations,GroupSize:string;
begin
  Lines:=TStringList.Create;Names:=TStringList.Create;Parts:=TStringList.Create;
  try
    S:=RenderShaderSource(Source,False);
    P:=Pos('void main()',S);if P=0 then raise Exception.Create('Tree vertex entry missing');
    Prefix:=Copy(S,1,P-1);Body:=Copy(S,P,MaxInt);
    Lines.Text:=Prefix;Prefix:='';Declarations:='';ExportCode:='';
    for I:=0 to Lines.Count-1 do begin
      S:=Trim(Lines[I]);
      if Pos('#version ',S)=1 then begin
        Prefix+='#version 450 core'+#10+'#extension GL_NV_mesh_shader : require'+#10;Continue;
      end;
      if Pos('layout(location=',S)=1 then begin
        J:=Pos(' in ',S);if J=0 then raise Exception.Create('Unknown tree attribute');
        Prefix+=Copy(S,J+4,MaxInt)+#10;Continue;
      end;
      Qualifier:='';
      if Pos('flat out ',S)=1 then begin Qualifier:='flat ';Delete(S,1,5) end;
      if Pos('out ',S)=1 then begin
        Delete(S,1,4);J:=Pos(' ',S);Kind:=Copy(S,1,J-1);Delete(S,1,J);
        S:=StringReplace(S,';','',[]);Parts.StrictDelimiter:=True;Parts.Delimiter:=',';Parts.DelimitedText:=S;
        for K:=0 to Parts.Count-1 do begin
          Name:=Trim(Parts[K]);Names.Add(Name);
          Prefix+=Kind+' local_'+Name+';'+#10;
          Declarations+=Qualifier+'out '+Kind+' '+Name+'[];'+#10;
          ExportCode+='    '+Name+'[outputVertex]=local_'+Name+';'+#10;
        end;
      end else Prefix+=Lines[I]+#10;
    end;
    { Varying names are distinct complete identifiers in the canonical source. }
    for I:=0 to Names.Count-1 do Body:=StringReplace(Body,Names[I],'local_'+Names[I],[rfReplaceAll]);
    { Shared helper uses vSpecies and the regular source declares it above. }
    Prefix:=ReplaceRequired(Prefix,'return prepareTreeNeedleImpl(needle, vSpecies);',
      'return prepareTreeNeedleImpl(needle, local_vSpecies);');
    Prefix:=ReplaceRequired(Prefix,'uniform int uKind,','const int uKind=5; uniform int');
    Body:=StringReplace(Body,'void main()','void evaluateTreeVertex(int vertexID,int instanceID)',[]);
    Body:=StringReplace(Body,'gl_VertexID','vertexID',[rfReplaceAll]);
    Body:=StringReplace(Body,'gl_InstanceID','instanceID',[rfReplaceAll]);
    Body:=StringReplace(Body,'gl_Position','localPosition',[rfReplaceAll]);
    S:='TreeNeedleShape needleShape=prepareTreeNeedle(needle);';
    if Pos(S,Body)=0 then raise Exception.Create('Shared needle preparation missing');
    Body:=StringReplace(Body,S,'TreeNeedleShape needleShape=meshPrepared[meshLocalNeedle];',[]);
    Result:=Prefix+#10+
      'layout(local_size_x=32) in;'+#10+
      'layout(triangles,max_vertices=80,max_primitives=48) out;'+#10+
      Declarations+
      'layout(std430,binding=7) readonly buffer Shoots { vec4 descriptors[]; };'+#10+
      'uniform int uMeshFirst,uMeshCull;'+#10+
      'shared TreeNeedleShape meshPrepared[16];'+#10+
      'shared uint meshVisible; int meshLocalNeedle; vec4 localPosition;'+#10+
      Body+#10+
      'bool visibleShoot() {'+#10+
      '  float len=abs(b.w)*1.15*1.5*(uBakeMode>0?4.0:1.25);'+#10+
      '  float padding=abs(a.w)+2.0*len+abs(c.w)+abs(uWind)*0.005+0.001;'+#10+
      '  vec3 lo=min(a.xyz,min(b.xyz,c.xyz))-vec3(padding);'+#10+
      '  vec3 hi=max(a.xyz,max(b.xyz,c.xyz))+vec3(padding);'+#10+
      '  float sway=abs(uWind)*0.35*pow(max(0.0,hi.y)/max(0.1,uProfile.x),2.0);'+#10+
      '  lo.xz-=sway; hi.xz+=sway;'+#10+
      '  vec3 center=(lo+hi)*0.5,extent=(hi-lo)*0.5;'+#10+
      '  mat4 rows=transpose(uProjection*uView*uModel);'+#10+
      '  for(int axis=0;axis<3;++axis) for(int signIndex=0;signIndex<2;++signIndex) {'+#10+
      '    vec4 plane=rows[3]+rows[axis]*(signIndex==0?1.0:-1.0);'+#10+
      '    if(dot(plane.xyz,center)+plane.w+dot(abs(plane.xyz),extent)<0.0)return false;'+#10+
      '  } return true;'+#10+'}'+#10+
      'void main() {'+#10+
      '  int lane=int(gl_LocalInvocationID.x);'+#10+
      '  int perShoot=uNeedlePairs*uNeedlesPerFascicle;'+#10+
      '  int chunks=(perShoot+15)/16;'+#10+
      '  int shoot=int(gl_WorkGroupID.x)/chunks;'+#10+
      '  int firstNeedle=(int(gl_WorkGroupID.x)%chunks)*16;'+#10+
      '  int count=min(16,perShoot-firstNeedle);'+#10+
      '  int item=(uMeshFirst+shoot)*4;'+#10+
      '  a=descriptors[item]; b=descriptors[item+1]; c=descriptors[item+2]; d=descriptors[item+3];'+#10+
      '  aTreeCode=floatBitsToUint(d.y); local_vSpecies=int(aTreeCode & 255u);'+#10+
      '  if(lane==0)meshVisible=uint(uMeshCull==0 || visibleShoot());'+#10+
      '  barrier();'+#10+
      '  if(meshVisible==0u){if(lane==0)gl_PrimitiveCountNV=0u;return;}'+#10+
      '  if(lane<count)meshPrepared[lane]=prepareTreeNeedle(firstNeedle+lane);'+#10+
      '  barrier();'+#10+
      '  int vertices=uNeedleVertices==9?5:3; int triangles=uNeedleVertices==9?3:1;'+#10+
      '  const int corners[5]=int[5](0,1,2,5,8);'+#10+
      '  const uint indices[9]=uint[9](0u,1u,2u,2u,1u,3u,2u,3u,4u);'+#10+
      '  for(int outputVertex=lane;outputVertex<count*vertices;outputVertex+=32){'+#10+
      '    meshLocalNeedle=outputVertex/vertices; int corner=outputVertex%vertices;'+#10+
      '    int vertexID=(firstNeedle+meshLocalNeedle)*uNeedleVertices+(vertices==5?corners[corner]:corner);'+#10+
      '    evaluateTreeVertex(vertexID,shoot);'+#10+
      '    gl_MeshVerticesNV[outputVertex].gl_Position=localPosition;'+#10+ExportCode+
      '  }'+#10+
      '  for(int primitive=lane;primitive<count*triangles;primitive+=32){'+#10+
      '    uint base=uint((primitive/triangles)*vertices); int tri=primitive%triangles;'+#10+
      '    for(int k=0;k<3;++k)gl_PrimitiveIndicesNV[primitive*3+k]=base+(triangles==1?uint(k):indices[tri*3+k]);'+#10+
      '  }'+#10+
      '  if(lane==0)gl_PrimitiveCountNV=uint(count*triangles);'+#10+'}'+#10;
    GroupSize:=IntToStr(MeshGroupSize);
    Result:=StringReplace(Result,'max_vertices=80,max_primitives=48',
      'max_vertices='+IntToStr(MeshGroupSize*5)+',max_primitives='+IntToStr(MeshGroupSize*3),[]);
    Result:=StringReplace(Result,'meshPrepared[16]','meshPrepared['+GroupSize+']',[]);
    Result:=StringReplace(Result,'(perShoot+15)/16','(perShoot+'+IntToStr(MeshGroupSize-1)+')/'+GroupSize,[]);
    Result:=StringReplace(Result,'*16;','*'+GroupSize+';',[]);
    Result:=StringReplace(Result,'min(16,perShoot-firstNeedle)','min('+GroupSize+',perShoot-firstNeedle)',[]);
  finally Parts.Free;Names.Free;Lines.Free end;
end;

function TTreeNeedleMesh.Compile(Kind:GLenum;const Source:string):GLuint;
var P:PChar;OK,N:GLint;Log:string;
begin
  Result:=glCreateShader(Kind);P:=PChar(Source);glShaderSource(Result,1,@P,nil);glCompileShader(Result);
  glGetShaderiv(Result,GL_COMPILE_STATUS,@OK);
  if OK=0 then begin
    glGetShaderiv(Result,GL_INFO_LOG_LENGTH,@N);SetLength(Log,Max(1,N));
    glGetShaderInfoLog(Result,N,nil,PChar(Log));glDeleteShader(Result);
    raise Exception.Create('Needle mesh compile: '+Log);
  end;
end;
constructor TTreeNeedleMesh.Create(SourceProgram:GLuint;const VertexSource,FragmentSource:string);
var VS,FS:GLuint;OK,N,I,J,OldLength,Size,Len,SourceLocation:GLint;Kind:GLenum;
  Name:array[0..255]of Char;Log,Reason:string;
begin
  inherited Create;VS:=0;FS:=0;FNeedlesPerGroup:=MeshGroupSize;
  if not NeedleMeshSupported(Reason) then raise Exception.Create(Reason);
  {$ifdef MSWINDOWS}{$ifndef OpenGLES}FDrawPointer:=wglGetProcAddress('glDrawMeshTasksNV');{$endif}{$endif}
  try
    VS:=Compile(MeshShaderNV,NeedleMeshVertexSource(VertexSource));
    FS:=Compile(GL_FRAGMENT_SHADER,NeedleMeshFragmentSource(FragmentSource));
    FProgram:=glCreateProgram();glAttachShader(FProgram,VS);glAttachShader(FProgram,FS);glLinkProgram(FProgram);
    glGetProgramiv(FProgram,GL_LINK_STATUS,@OK);
    if OK=0 then begin
      glGetProgramiv(FProgram,GL_INFO_LOG_LENGTH,@N);SetLength(Log,Max(1,N));
      glGetProgramInfoLog(FProgram,N,nil,PChar(Log));raise Exception.Create('Needle mesh link: '+Log);
    end;
    glGetProgramiv(FProgram,GL_ACTIVE_UNIFORMS,@N);SetLength(FUniforms,N);
    for I:=0 to N-1 do begin
      glGetActiveUniform(FProgram,I,SizeOf(Name),@Len,@Size,@Kind,@Name[0]);
      SourceLocation:=glGetUniformLocation(SourceProgram,@Name[0]);
      FUniforms[I].Location:=glGetUniformLocation(FProgram,@Name[0]);FUniforms[I].Kind:=Kind;
      { Validate at initialization, so an incompatible future shader keeps the
        ordinary path instead of raising halfway through a frame. }
      case Kind of
        GL_INT,GL_BOOL,GL_SAMPLER_2D_ARRAY,GL_FLOAT,GL_FLOAT_VEC2,GL_FLOAT_VEC3,
        GL_FLOAT_VEC4,GL_FLOAT_MAT4:;
        else raise Exception.CreateFmt('Unsupported needle uniform %s ($%x)',[PChar(@Name[0]),Kind]);
      end;
      if Size<>1 then raise Exception.CreateFmt('Unsupported needle uniform array %s',[PChar(@Name[0])]);
      if SourceLocation>=0 then begin
        if SourceLocation>=Length(FMap) then begin
          OldLength:=Length(FMap);SetLength(FMap,SourceLocation+1);
          for J:=OldLength to High(FMap) do FMap[J]:=-1;
        end;
        FMap[SourceLocation]:=I;
      end;
    end;
    FFirst:=glGetUniformLocation(FProgram,'uMeshFirst');
    FCull:=glGetUniformLocation(FProgram,'uMeshCull');FLastFirst:=-1;FLastCull:=-1;
    glGetIntegerv($953D,@N); { GL_MAX_DRAW_MESH_TASKS_COUNT_NV }
    FMaxDrawGroups:=Max(1,N);
    TreeNeedleMeshStatus:='ready GL_NV_mesh_shader';
  finally if VS<>0 then glDeleteShader(VS);if FS<>0 then glDeleteShader(FS) end;
end;
destructor TTreeNeedleMesh.Destroy;
begin if FProgram<>0 then glDeleteProgram(FProgram);inherited Destroy end;
procedure TTreeNeedleMesh.Remember(Location:GLint;Count:Integer;Data:Pointer);
var I:Integer;
begin
  if(Location<0)or(Location>=Length(FMap))then Exit;I:=FMap[Location];if I<0 then Exit;
  Assert((Count>0)and(Count<=16));
  if not FUniforms[I].Valid or not CompareMem(@FUniforms[I].Data[0],Data,Count*SizeOf(Single))then begin
    Move(Data^,Self.FUniforms[I].Data[0],Count*SizeOf(Single));
    FUniforms[I].Count:=Count;FUniforms[I].Valid:=True;FUniforms[I].Dirty:=True;
  end;
end;
function TTreeNeedleMesh.Draw(Buffer:GLuint;First,Count,NeedlesPerShoot:Integer;SourceProgram:GLuint):Integer;
var I,OldStorage,OldGeneric:GLint;OldStart,OldSize:GLint64;
  Groups,FirstGroup,DrawCount:GLuint;
begin
  Result:=0;
  {$ifndef OpenGLES}
  if (Count<=0) or (NeedlesPerShoot<=0) then Exit;
  Groups:=GLuint(Count)*GLuint((NeedlesPerShoot+FNeedlesPerGroup-1)div FNeedlesPerGroup);if Groups=0 then Exit;
  glGetIntegeri_v(StorageBinding,StorageSlot,@OldStorage);
  glGetIntegerv(StorageBinding,@OldGeneric);
  OldStart:=0;OldSize:=0;
  if OldStorage<>0 then begin
    glGetInteger64i_v(StorageStart,StorageSlot,@OldStart);
    glGetInteger64i_v(StorageSize,StorageSlot,@OldSize);
  end;
  glBindBufferBase(StorageBuffer,StorageSlot,Buffer);glUseProgram(FProgram);
  try
    for I:=0 to High(FUniforms) do with FUniforms[I] do if Dirty then begin
      case Kind of
        GL_INT,GL_BOOL,GL_SAMPLER_2D_ARRAY:glUniform1iv(Location,1,PGLint(@Data[0]));
        GL_FLOAT:glUniform1fv(Location,1,@Data[0]);
        GL_FLOAT_VEC2:glUniform2fv(Location,1,@Data[0]);
        GL_FLOAT_VEC3:glUniform3fv(Location,1,@Data[0]);
        GL_FLOAT_VEC4:glUniform4fv(Location,1,@Data[0]);
        GL_FLOAT_MAT4:glUniformMatrix4fv(Location,1,GL_FALSE,@Data[0]);
        else raise Exception.CreateFmt('Unsupported needle uniform $%x',[Kind]);
      end;Dirty:=False;
    end;
    if First<>FLastFirst then begin glUniform1i(FFirst,First);FLastFirst:=First end;
    if Ord(TreeNeedleMeshMode=2)<>FLastCull then begin
      FLastCull:=Ord(TreeNeedleMeshMode=2);glUniform1i(FCull,FLastCull);
    end;
    FirstGroup:=0;
    while FirstGroup<Groups do begin
      DrawCount:=Min(FMaxDrawGroups,Groups-FirstGroup);
      TDrawMesh(FDrawPointer)(FirstGroup,DrawCount);Inc(TreeNeedleMeshDraws);Inc(FirstGroup,DrawCount);
      Inc(Result);
    end;
    Inc(TreeNeedleMeshGroups,Groups);
  finally
    glUseProgram(SourceProgram);
    if (OldStorage<>0) and (OldSize>0) then
      glBindBufferRange(StorageBuffer,StorageSlot,OldStorage,OldStart,OldSize)
    else glBindBufferBase(StorageBuffer,StorageSlot,OldStorage);
    glBindBuffer(StorageBuffer,OldGeneric);
  end;
  {$endif}
end;
initialization
  TreeNeedleMeshMode:=EnsureRange(StrToIntDef(SysUtils.GetEnvironmentVariable('REZVIVO_TREE_MESH'),0),0,2);
end.
