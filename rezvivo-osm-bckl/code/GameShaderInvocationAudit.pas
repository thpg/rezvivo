unit GameShaderInvocationAudit;
{$mode objfpc}{$H+}
{$ifdef ANDROID}{$define OpenGLES}{$endif}

{ Explicit, sampled diagnostic. Queries partition the existing command stream;
  they neither hide objects nor change shader code, draw order or GL state.
  The query overhead makes this unsuitable for measuring FPS. }
interface
uses fpjson, Classes, {$ifdef OpenGLES}CastleGLES{$else}CastleGL{$endif};
const ShaderAuditCounters = 5;
type
  TShaderAuditValues = array[0..ShaderAuditCounters-1] of QWord;
  TShaderAuditRow = record
    Values:TShaderAuditValues;
    Draws,Dispatches:QWord;
  end;
  TShaderAuditProgram = record
    Id:GLuint;
    SelectorLocation,SelectorValue:GLint;
    SelectorFloat:Boolean;
    SelectorName,Source,Uniforms:string;
  end;
  TShaderAuditBucket = record
    ProgramIndex,Selector:Integer;
    Sum:TShaderAuditRow;
  end;
  TShaderAuditFrame = record
    Rows:array[0..511]of TShaderAuditRow;
    Pending:Integer;
    Closed,Bad,Collected:Boolean;
  end;
  TShaderAuditQuery = record
    Ids:array[0..ShaderAuditCounters-1]of GLuint;
    Frame,Bucket:Integer;
  end;
  TShaderInvocationAudit = class
  private
    FPrograms:array of TShaderAuditProgram;
    FBuckets:array of TShaderAuditBucket;
    FFrames:array[0..63]of TShaderAuditFrame;
    FQueries:array[0..8191]of TShaderAuditQuery;
    FHead,FTail,FPending,FOpen,FCurrentProgram,FCurrentBucket:Integer;
    FFrame,FStarted,FComplete,FLimit,FStride,FSeen,FSkipped:Integer;
    FInstalled,FActive,FChecked,FSupported:Boolean;
    FReason:string;
    procedure ContextClose(Sender:TObject);
    procedure Install;
    procedure Uninstall;
    function ProgramIndex(Id:GLuint):Integer;
    function BucketIndex(P:Integer):Integer;
    procedure SwitchScope;
    procedure EndScope;
    procedure Collect;
    procedure FinishFrame(Index:Integer);
    procedure UseProgram(Id:GLuint);
    procedure Uniform1i(Location,Value:GLint);
    procedure Uniform1f(Location:GLint;Value:Single);
    procedure GrassMode(Mode:Integer);
    procedure DrawCall;
    procedure DispatchCall;
  public
    constructor Create(FrameLimit:Integer=48;Stride:Integer=8);
    destructor Destroy;override;
    procedure BeginFrame;
    procedure EndFrame;
    procedure Snapshot(Dest:TJSONObject);
  end;

implementation
uses SysUtils,Math,CastleApplicationProperties
  {$ifndef OpenGLES},GL,GLExt,GrassRenderer{$endif};
const
  Targets:array[0..ShaderAuditCounters-1]of Cardinal=($82EE,$82EF,$82F0,$82F4,$82F5);
  Names:array[0..ShaderAuditCounters-1]of string=(
    'vertices_submitted','primitives_submitted','vertex_shader_invocations',
    'fragment_shader_invocations','compute_shader_invocations');
{$ifndef OpenGLES}
type TExtUseProgram=procedure(Id:Cardinal);{$ifdef Windows}stdcall{$else}cdecl{$endif};
var
  Audit:TShaderInvocationAudit;
  OldUse:CastleGL.TglUseProgram;
  OldExtUse:TExtUseProgram;
  OldUniform,OldExtUniform:CastleGL.TglUniform1i;
  OldFloat,OldExtFloat:CastleGL.TglUniform1f;
  OldArrays,OldGLArrays:CastleGL.TglDrawArrays;
  OldElements,OldGLElements:CastleGL.TglDrawElements;
  OldMultiElements:CastleGL.TglMultiDrawElements;
  OldArrayInstances,OldExtArrayInstances:CastleGL.TglDrawArraysInstanced;
  OldElementInstances,OldExtElementInstances:CastleGL.TglDrawElementsInstanced;
  OldRange:CastleGL.TglDrawRangeElements;
  OldBase:CastleGL.TglDrawElementsBaseVertex;
  OldArrayBase:CastleGL.TglDrawArraysInstancedBaseInstance;
  OldElementBase:CastleGL.TglDrawElementsInstancedBaseInstance;
  OldDispatch:CastleGL.TglDispatchCompute;

procedure HookUse(Id:CastleGL.GLhandle);{$ifdef Windows}stdcall{$else}cdecl{$endif};
begin if Audit<>nil then Audit.UseProgram(Id);OldUse(Id) end;
procedure HookExtUse(Id:Cardinal);{$ifdef Windows}stdcall{$else}cdecl{$endif};
begin if Audit<>nil then Audit.UseProgram(Id);OldExtUse(Id) end;
procedure HookUniform(Location,Value:CastleGL.GLint);{$ifdef Windows}stdcall{$else}cdecl{$endif};
begin if Audit<>nil then Audit.Uniform1i(Location,Value);OldUniform(Location,Value) end;
procedure HookFloat(Location:CastleGL.GLint;Value:CastleGL.GLfloat);{$ifdef Windows}stdcall{$else}cdecl{$endif};
begin if Audit<>nil then Audit.Uniform1f(Location,Value);OldFloat(Location,Value) end;
procedure HookArrays(Mode:CastleGL.GLenum;First:CastleGL.GLint;Count:CastleGL.GLsizei);{$ifdef Windows}stdcall{$else}cdecl{$endif};
begin if Audit<>nil then Audit.DrawCall;OldArrays(Mode,First,Count) end;
procedure HookElements(Mode:CastleGL.GLenum;Count:CastleGL.GLsizei;Kind:CastleGL.GLenum;const Indices:CastleGL.PGLvoid);{$ifdef Windows}stdcall{$else}cdecl{$endif};
begin if Audit<>nil then Audit.DrawCall;OldElements(Mode,Count,Kind,Indices) end;
procedure HookMultiElements(Mode:CastleGL.GLenum;const Counts:CastleGL.PGLsizei;Kind:CastleGL.GLenum;const Indices:CastleGL.PGLvoid;DrawCount:CastleGL.GLsizei);{$ifdef Windows}stdcall{$else}cdecl{$endif};
var I:Integer;
begin
  { Count logical draws, as for the equivalent DrawElements sequence. }
  if Audit<>nil then for I:=1 to DrawCount do Audit.DrawCall;
  OldMultiElements(Mode,Counts,Kind,Indices,DrawCount);
end;
procedure HookArrayInstances(Mode:CastleGL.GLenum;First:CastleGL.GLint;Count,Instances:CastleGL.GLsizei);{$ifdef Windows}stdcall{$else}cdecl{$endif};
begin if Audit<>nil then Audit.DrawCall;OldArrayInstances(Mode,First,Count,Instances) end;
procedure HookElementInstances(Mode:CastleGL.GLenum;Count:CastleGL.GLsizei;Kind:CastleGL.GLenum;const Indices:CastleGL.PGLvoid;Instances:CastleGL.GLsizei);{$ifdef Windows}stdcall{$else}cdecl{$endif};
begin if Audit<>nil then Audit.DrawCall;OldElementInstances(Mode,Count,Kind,Indices,Instances) end;
procedure HookRange(Mode:CastleGL.GLenum;First,Last:CastleGL.GLuint;Count:CastleGL.GLsizei;Kind:CastleGL.GLenum;const Indices:CastleGL.PGLvoid);{$ifdef Windows}stdcall{$else}cdecl{$endif};
begin if Audit<>nil then Audit.DrawCall;OldRange(Mode,First,Last,Count,Kind,Indices) end;
procedure HookBase(Mode:CastleGL.GLenum;Count:CastleGL.GLsizei;Kind:CastleGL.GLenum;const Indices:CastleGL.PGLvoid;Base:CastleGL.GLint);{$ifdef Windows}stdcall{$else}cdecl{$endif};
begin if Audit<>nil then Audit.DrawCall;OldBase(Mode,Count,Kind,Indices,Base) end;
procedure HookArrayBase(Mode:CastleGL.GLenum;First:CastleGL.GLint;Count,Instances:CastleGL.GLsizei;Base:CastleGL.GLuint);{$ifdef Windows}stdcall{$else}cdecl{$endif};
begin if Audit<>nil then Audit.DrawCall;OldArrayBase(Mode,First,Count,Instances,Base) end;
procedure HookElementBase(Mode:CastleGL.GLenum;Count:CastleGL.GLsizei;Kind:CastleGL.GLenum;const Indices:CastleGL.PGLvoid;Instances:CastleGL.GLsizei;Base:CastleGL.GLuint);{$ifdef Windows}stdcall{$else}cdecl{$endif};
begin if Audit<>nil then Audit.DrawCall;OldElementBase(Mode,Count,Kind,Indices,Instances,Base) end;
procedure HookDispatch(X,Y,Z:CastleGL.GLuint);{$ifdef Windows}stdcall{$else}cdecl{$endif};
begin if Audit<>nil then Audit.DispatchCall;OldDispatch(X,Y,Z) end;
procedure RawGrassDraw;
begin if Audit<>nil then Audit.DrawCall end;
procedure GrassDrawMode(Mode:Integer);
begin if Audit<>nil then Audit.GrassMode(Mode) end;
{$endif}

constructor TShaderInvocationAudit.Create(FrameLimit,Stride:Integer);
begin
  inherited Create;FOpen:=-1;FCurrentProgram:=-1;FCurrentBucket:=-1;FFrame:=-1;
  FLimit:=EnsureRange(FrameLimit,1,Length(FFrames));FStride:=Max(1,Stride);
  ApplicationProperties.OnGLContextCloseObject.Add(@ContextClose);
end;
destructor TShaderInvocationAudit.Destroy;
begin
  ApplicationProperties.OnGLContextCloseObject.Remove(@ContextClose);
  ContextClose(nil);inherited;
end;
procedure TShaderInvocationAudit.ContextClose(Sender:TObject);
{$ifndef OpenGLES}var I,J:Integer;{$endif}
begin
  EndFrame;Uninstall;
  {$ifndef OpenGLES}
  for I:=0 to High(FQueries)do for J:=0 to ShaderAuditCounters-1 do
    if FQueries[I].Ids[J]<>0 then CastleGL.glDeleteQueries(1,@FQueries[I].Ids[J]);
  {$endif}
  FillChar(FQueries,SizeOf(FQueries),0);FHead:=0;FTail:=0;FPending:=0;
  FSupported:=False;FChecked:=True;FReason:='GL context closed; start a new capture';
end;
procedure TShaderInvocationAudit.Install;
begin
  {$ifndef OpenGLES}
  if FInstalled then Exit;
  if Audit<>nil then raise Exception.Create('Shader audit already active');
  OldUse:=CastleGL.glUseProgram;OldExtUse:=GLExt.glUseProgram;
  OldUniform:=CastleGL.glUniform1i;OldExtUniform:=CastleGL.TglUniform1i(GLExt.glUniform1i);
  OldFloat:=CastleGL.glUniform1f;OldExtFloat:=CastleGL.TglUniform1f(GLExt.glUniform1f);
  OldArrays:=CastleGL.glDrawArrays;OldGLArrays:=CastleGL.TglDrawArrays(GL.glDrawArrays);
  OldElements:=CastleGL.glDrawElements;OldGLElements:=CastleGL.TglDrawElements(GL.glDrawElements);
  OldMultiElements:=CastleGL.glMultiDrawElements;
  OldArrayInstances:=CastleGL.glDrawArraysInstanced;OldExtArrayInstances:=CastleGL.TglDrawArraysInstanced(GLExt.glDrawArraysInstanced);
  OldElementInstances:=CastleGL.glDrawElementsInstanced;OldExtElementInstances:=CastleGL.TglDrawElementsInstanced(GLExt.glDrawElementsInstanced);
  OldRange:=CastleGL.glDrawRangeElements;OldBase:=CastleGL.glDrawElementsBaseVertex;
  OldArrayBase:=CastleGL.glDrawArraysInstancedBaseInstance;OldElementBase:=CastleGL.glDrawElementsInstancedBaseInstance;
  OldDispatch:=CastleGL.glDispatchCompute;
  Audit:=Self;
  CastleGL.glUseProgram:=@HookUse;GLExt.glUseProgram:=@HookExtUse;
  CastleGL.glUniform1i:=@HookUniform;GLExt.glUniform1i:=@HookUniform;
  CastleGL.glUniform1f:=@HookFloat;GLExt.glUniform1f:=@HookFloat;
  CastleGL.glDrawArrays:=@HookArrays;GL.glDrawArrays:=@HookArrays;
  CastleGL.glDrawElements:=@HookElements;GL.glDrawElements:=@HookElements;
  if Assigned(OldMultiElements)then CastleGL.glMultiDrawElements:=@HookMultiElements;
  CastleGL.glDrawArraysInstanced:=@HookArrayInstances;GLExt.glDrawArraysInstanced:=@HookArrayInstances;
  CastleGL.glDrawElementsInstanced:=@HookElementInstances;GLExt.glDrawElementsInstanced:=@HookElementInstances;
  if Assigned(OldRange)then CastleGL.glDrawRangeElements:=@HookRange;
  if Assigned(OldBase)then CastleGL.glDrawElementsBaseVertex:=@HookBase;
  if Assigned(OldArrayBase)then CastleGL.glDrawArraysInstancedBaseInstance:=@HookArrayBase;
  if Assigned(OldElementBase)then CastleGL.glDrawElementsInstancedBaseInstance:=@HookElementBase;
  if Assigned(OldDispatch)then CastleGL.glDispatchCompute:=@HookDispatch;
  GrassDiagnosticRawDraw:=@RawGrassDraw;
  GrassDiagnosticDrawMode:=@GrassDrawMode;
  FInstalled:=True;
  {$endif}
end;
procedure TShaderInvocationAudit.Uninstall;
begin
  {$ifndef OpenGLES}
  if not FInstalled then Exit;
  CastleGL.glUseProgram:=OldUse;GLExt.glUseProgram:=OldExtUse;
  CastleGL.glUniform1i:=OldUniform;GLExt.glUniform1i:=OldExtUniform;
  CastleGL.glUniform1f:=OldFloat;GLExt.glUniform1f:=OldExtFloat;
  CastleGL.glDrawArrays:=OldArrays;GL.glDrawArrays:=OldGLArrays;
  CastleGL.glDrawElements:=OldElements;GL.glDrawElements:=OldGLElements;
  CastleGL.glMultiDrawElements:=OldMultiElements;
  CastleGL.glDrawArraysInstanced:=OldArrayInstances;GLExt.glDrawArraysInstanced:=OldExtArrayInstances;
  CastleGL.glDrawElementsInstanced:=OldElementInstances;GLExt.glDrawElementsInstanced:=OldExtElementInstances;
  CastleGL.glDrawRangeElements:=OldRange;CastleGL.glDrawElementsBaseVertex:=OldBase;
  CastleGL.glDrawArraysInstancedBaseInstance:=OldArrayBase;CastleGL.glDrawElementsInstancedBaseInstance:=OldElementBase;
  CastleGL.glDispatchCompute:=OldDispatch;GrassDiagnosticRawDraw:=nil;GrassDiagnosticDrawMode:=nil;
  Audit:=nil;FInstalled:=False;
  {$endif}
end;
function TShaderInvocationAudit.ProgramIndex(Id:GLuint):Integer;
{$ifndef OpenGLES}
var I,N,L,Size,Stage:Integer;Count,Actual:CastleGL.GLsizei;Kind:CastleGL.GLenum;FloatValue:Single;
  Shaders:array[0..31]of CastleGL.GLuint;S:AnsiString;
{$endif}
begin
  for Result:=0 to High(FPrograms)do if FPrograms[Result].Id=Id then Exit;
  Result:=Length(FPrograms);SetLength(FPrograms,Result+1);
  FPrograms[Result].Id:=Id;FPrograms[Result].SelectorLocation:=-1;
  if Id=0 then Exit;
  {$ifndef OpenGLES}
  with FPrograms[Result]do begin
    CastleGL.glGetProgramiv(Id,GL_ACTIVE_UNIFORMS,@N);
    CastleGL.glGetProgramiv(Id,GL_ACTIVE_UNIFORM_MAX_LENGTH,@L);
    for I:=0 to N-1 do begin
      SetLength(S,Max(1,L));CastleGL.glGetActiveUniform(Id,I,Length(S),Actual,Size,Kind,PAnsiChar(S));
      SetLength(S,Actual);Uniforms:=Uniforms+string(S)+#10;
    end;
    if Pos('uKind'+#10,Uniforms)>0 then SelectorName:='uKind'
    else if Pos('uMode'+#10,Uniforms)>0 then SelectorName:='uMode'
    else if Pos('rz_capture'+#10,Uniforms)>0 then begin SelectorName:='rz_capture';SelectorFloat:=True end;
    if SelectorName<>''then begin
      SelectorLocation:=CastleGL.glGetUniformLocation(Id,PAnsiChar(SelectorName));
      if SelectorFloat then begin
        CastleGL.glGetUniformfv(Id,SelectorLocation,@FloatValue);SelectorValue:=Ord(FloatValue>0.5);
      end else CastleGL.glGetUniformiv(Id,SelectorLocation,@SelectorValue);
    end;
    CastleGL.glGetAttachedShaders(Id,Length(Shaders),Count,@Shaders[0]);
    for I:=0 to Count-1 do begin
      CastleGL.glGetShaderiv(Shaders[I],GL_SHADER_SOURCE_LENGTH,@L);
      CastleGL.glGetShaderiv(Shaders[I],GL_SHADER_TYPE,@Stage);
      SetLength(S,Max(1,L));CastleGL.glGetShaderSource(Shaders[I],Length(S),Actual,PAnsiChar(S));
      SetLength(S,Actual);Source:=Source+#10+'// stage '+IntToStr(Stage)+#10+string(S);
    end;
  end;
  {$endif}
end;
function TShaderInvocationAudit.BucketIndex(P:Integer):Integer;
begin
  for Result:=0 to High(FBuckets)do
    if(FBuckets[Result].ProgramIndex=P)and(FBuckets[Result].Selector=FPrograms[P].SelectorValue)then Exit;
  Result:=Length(FBuckets);
  if Result>=Length(FFrames[0].Rows)then begin Inc(FSkipped);FFrames[FFrame].Bad:=True;Exit(-1) end;
  SetLength(FBuckets,Result+1);FBuckets[Result].ProgramIndex:=P;
  FBuckets[Result].Selector:=FPrograms[P].SelectorValue;
end;
procedure TShaderInvocationAudit.EndScope;
{$ifndef OpenGLES}var J:Integer;{$endif}
begin
  if FOpen<0 then Exit;
  {$ifndef OpenGLES}
  for J:=ShaderAuditCounters-1 downto 0 do CastleGL.glEndQuery(Targets[J]);
  {$endif}
  Inc(FFrames[FFrame].Pending);Inc(FPending);FTail:=(FTail+1)mod Length(FQueries);FOpen:=-1;
end;
procedure TShaderInvocationAudit.SwitchScope;
{$ifndef OpenGLES}var J,B:Integer;{$endif}
begin
  {$ifndef OpenGLES}
  if not FActive then Exit;
  B:=BucketIndex(FCurrentProgram);
  if(B=FCurrentBucket)and(FOpen>=0)then Exit;
  EndScope;FCurrentBucket:=B;
  if B<0 then Exit;
  if FPending>=Length(FQueries)then begin Inc(FSkipped);FFrames[FFrame].Bad:=True;Exit end;
  FOpen:=FTail;FQueries[FOpen].Frame:=FFrame;FQueries[FOpen].Bucket:=B;
  for J:=0 to ShaderAuditCounters-1 do begin
    if FQueries[FOpen].Ids[J]=0 then CastleGL.glGenQueries(1,@FQueries[FOpen].Ids[J]);
    CastleGL.glBeginQuery(Targets[J],FQueries[FOpen].Ids[J]);
  end;
  {$endif}
end;
procedure TShaderInvocationAudit.UseProgram(Id:GLuint);
begin
  if not FActive then Exit;
  if(FCurrentProgram>=0)and(FPrograms[FCurrentProgram].Id=Id)then Exit;
  FCurrentProgram:=ProgramIndex(Id);SwitchScope;
end;
procedure TShaderInvocationAudit.Uniform1i(Location,Value:GLint);
begin
  if not FActive or(FCurrentProgram<0)then Exit;
  with FPrograms[FCurrentProgram]do
    if(Location>=0)and(Location=SelectorLocation)and(Value<>SelectorValue)then begin
      SelectorValue:=Value;SwitchScope;
    end;
end;
procedure TShaderInvocationAudit.Uniform1f(Location:GLint;Value:Single);
begin
  if not FActive or(FCurrentProgram<0)then Exit;
  with FPrograms[FCurrentProgram]do
    if SelectorFloat and(Location=SelectorLocation)and(SelectorValue<>Ord(Value>0.5))then begin
      SelectorValue:=Ord(Value>0.5);SwitchScope;
    end;
end;
procedure TShaderInvocationAudit.GrassMode(Mode:Integer);
begin
  if not FActive or(FCurrentProgram<0)then Exit;
  { The grass shader shares uMode=1 for cards+carpet and carpet-only draws.
    A diagnostic tag distinguishes the existing draw paths, without changing
    any uniform or draw command. 100..104 are not actual shader values. }
  FPrograms[FCurrentProgram].SelectorValue:=100+Mode;SwitchScope;
end;
procedure TShaderInvocationAudit.DrawCall;
begin
  if FActive and(FCurrentBucket>=0)then Inc(FFrames[FFrame].Rows[FCurrentBucket].Draws);
end;
procedure TShaderInvocationAudit.DispatchCall;
begin
  if FActive and(FCurrentBucket>=0)then Inc(FFrames[FFrame].Rows[FCurrentBucket].Dispatches);
end;
procedure TShaderInvocationAudit.FinishFrame(Index:Integer);
var B,J:Integer;
begin
  with FFrames[Index]do begin
    if not Closed or(Pending<>0)or Collected then Exit;
    Collected:=True;if Bad then Exit;
    for B:=0 to High(FBuckets)do begin
      Inc(FBuckets[B].Sum.Draws,Rows[B].Draws);Inc(FBuckets[B].Sum.Dispatches,Rows[B].Dispatches);
      for J:=0 to ShaderAuditCounters-1 do Inc(FBuckets[B].Sum.Values[J],Rows[B].Values[J]);
    end;
  end;
  Inc(FComplete);
end;
procedure TShaderInvocationAudit.Collect;
{$ifndef OpenGLES}var J,F,B:Integer;Ready:CastleGL.GLuint;V:CastleGL.GLuint64;{$endif}
begin
  {$ifndef OpenGLES}
  while FPending>0 do begin
    CastleGL.glGetQueryObjectuiv(FQueries[FHead].Ids[0],GL_QUERY_RESULT_AVAILABLE,@Ready);
    if Ready=0 then Break;
    { Each target must be ready; do not let query reads synchronize the GPU. }
    for J:=1 to ShaderAuditCounters-1 do begin
      CastleGL.glGetQueryObjectuiv(FQueries[FHead].Ids[J],GL_QUERY_RESULT_AVAILABLE,@Ready);
      if Ready=0 then Break;
    end;
    if Ready=0 then Break;
    F:=FQueries[FHead].Frame;B:=FQueries[FHead].Bucket;
    for J:=0 to ShaderAuditCounters-1 do begin
      CastleGL.glGetQueryObjectui64v(FQueries[FHead].Ids[J],GL_QUERY_RESULT,@V);
      Inc(FFrames[F].Rows[B].Values[J],V);
    end;
    Dec(FFrames[F].Pending);Dec(FPending);FHead:=(FHead+1)mod Length(FQueries);FinishFrame(F);
  end;
  {$endif}
end;
procedure TShaderInvocationAudit.BeginFrame;
{$ifndef OpenGLES}var I,Bits,Active,Id:Integer;FloatValue:Single;{$endif}
begin
  if FActive then Exit;
  if not FChecked then begin
    FChecked:=True;FReason:='Desktop ARB_pipeline_statistics_query required';
    {$ifndef OpenGLES}
    FSupported:=CastleGL.GL_ARB_pipeline_statistics_query and Assigned(CastleGL.glGetQueryObjectui64v);
    if FSupported then for I:=0 to ShaderAuditCounters-1 do begin
      CastleGL.glGetQueryiv(Targets[I],GL_QUERY_COUNTER_BITS,@Bits);if Bits=0 then FSupported:=False;
    end;
    if FSupported then begin Install;FReason:='' end;
    {$endif}
  end;
  if not FSupported then Exit;
  Collect;Inc(FSeen);
  if(FStarted>=FLimit)or((FSeen-1)mod FStride<>0)then Exit;
  {$ifndef OpenGLES}
  for I:=0 to ShaderAuditCounters-1 do begin
    CastleGL.glGetQueryiv(Targets[I],GL_CURRENT_QUERY,@Active);
    if Active<>0 then begin Inc(FSkipped);Exit end;
  end;
  FFrame:=FStarted;Inc(FStarted);FActive:=True;FCurrentBucket:=-1;
  CastleGL.glGetIntegerv(GL_CURRENT_PROGRAM,@Id);FCurrentProgram:=ProgramIndex(Id);
  { Selector uniforms may have changed on unsampled frames. }
  for I:=0 to High(FPrograms)do with FPrograms[I]do
    if SelectorLocation>=0 then begin
      if SelectorFloat then begin
        CastleGL.glGetUniformfv(Id,SelectorLocation,@FloatValue);SelectorValue:=Ord(FloatValue>0.5);
      end else CastleGL.glGetUniformiv(Id,SelectorLocation,@SelectorValue);
    end;
  SwitchScope;
  {$endif}
end;
procedure TShaderInvocationAudit.EndFrame;
begin
  if not FActive then Exit;
  EndScope;FActive:=False;FFrames[FFrame].Closed:=True;FinishFrame(FFrame);
end;
procedure TShaderInvocationAudit.Snapshot(Dest:TJSONObject);
var B,J:Integer;Rows,Programs:TJSONArray;O,V:TJSONObject;Total:TShaderAuditRow;
begin
  Collect;
  Dest.Add('supported',FSupported);Dest.Add('reason',FReason);
  Dest.Add('sample_stride',FStride);Dest.Add('frames_seen',FSeen);
  Dest.Add('frames_started',FStarted);Dest.Add('frames_complete',FComplete);
  Dest.Add('frame_limit',FLimit);Dest.Add('pending_scopes',FPending);Dest.Add('skipped',FSkipped);
  Dest.Add('scope','Exclusive GL program + selector scopes; all passes, no visibility changes; excludes Vulkan compute');
  Dest.Add('timing_warning','Diagnostic overhead: do not use this capture FPS');
  Rows:=TJSONArray.Create;Dest.Add('rows',Rows);Total:=Default(TShaderAuditRow);
  for B:=0 to High(FBuckets)do begin
    O:=TJSONObject.Create;Rows.Add(O);
    with FBuckets[B]do begin
      O.Add('program',Int64(FPrograms[ProgramIndex].Id));
      if(FPrograms[ProgramIndex].SelectorName='uMode')and(Selector>=100)then begin
        O.Add('selector_name','grass_draw_mode');O.Add('selector_value',Selector-100);
      end else begin O.Add('selector_name',FPrograms[ProgramIndex].SelectorName);O.Add('selector_value',Selector) end;
      V:=TJSONObject.Create;O.Add('total',V);
      V.Add('draw_calls',Int64(Sum.Draws));V.Add('dispatch_calls',Int64(Sum.Dispatches));
      Inc(Total.Draws,Sum.Draws);Inc(Total.Dispatches,Sum.Dispatches);
      for J:=0 to ShaderAuditCounters-1 do begin V.Add(Names[J],Int64(Sum.Values[J]));Inc(Total.Values[J],Sum.Values[J]) end;
    end;
  end;
  V:=TJSONObject.Create;Dest.Add('total',V);
  V.Add('draw_calls',Int64(Total.Draws));V.Add('dispatch_calls',Int64(Total.Dispatches));
  for J:=0 to ShaderAuditCounters-1 do V.Add(Names[J],Int64(Total.Values[J]));
  Programs:=TJSONArray.Create;Dest.Add('programs',Programs);
  for B:=0 to High(FPrograms)do begin
    O:=TJSONObject.Create;Programs.Add(O);O.Add('id',Int64(FPrograms[B].Id));
    O.Add('uniforms',FPrograms[B].Uniforms);O.Add('source',FPrograms[B].Source);
  end;
end;
end.
