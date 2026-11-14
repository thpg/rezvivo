unit NeuralSuitAsset;
{$mode objfpc}{$H+}
{$ifdef ANDROID}{$define OpenGLES}{$endif}
interface
uses Classes,SysUtils,Math,NeuralAnatomyMath,NeuralRigidMath,RiderBodyParameters;
const NeuralInputs=4025;NeuralHidden=128;NeuralBones=206;NeuralMuscles=365;
type
 TNeuralFloats=array of Single;
 TNeuralInts=array of Integer;
 TNeuralFace=array[0..2]of Integer;
 TNeuralFaces=array of TNeuralFace;
 TNeuralUV=record U,V:Double end;
 TNeuralPart=record Slots:TNeuralInts;Faces:TNeuralFaces;UV:array of TNeuralUV end;
 TNeuralBone=record Name:string;Parent:Integer end;
 TNeuralMuscle=record Action,Side:Integer;OriginWeight,InsertionWeight:TInfluence end;
 TNeuralBodyTarget=record Body:TRiderBodyParameters;Scale:Double;Data:TNeuralFloats end;
 TNeuralSuitAsset=class
 private
  FMean,FScale,FOutputMean,FW1,FW2,FB1,FB2:TNeuralFloats;
  FPrograms:array[0..1]of LongWord;FBuffers:array[0..7]of LongWord;
  procedure ContextClose(Sender:TObject);
  procedure PrepareGPU;
 public
  Signature:string;VertexCount:Integer;Users:Integer;
  Bones:array of TNeuralBone;Muscles:array of TNeuralMuscle;
  Weights:array of TInfluence;Samples:array[0..63]of Integer;
  Parts:array[0..2]of TNeuralPart;Targets:array of TNeuralBodyTarget;
  LastMS:Double;Calls:QWord;
  class procedure RequireGPU;
  constructor Create(const Directory:string);
  destructor Destroy;override;
  procedure BodyShape(const Body:TRiderBodyParameters;out Rest,Pivots,Tips,Axes,Origins,Insertions:TVecArray;out BodyScale:Double);
  procedure Predict(const X:TNeuralFloats;out Y:TNeuralFloats);
  procedure PredictCPU(const X:TNeuralFloats;out Y:TNeuralFloats);
  function CheckReference(const FileName:string):Double;
 end;
implementation
uses CastleApplicationProperties,CastleTimeUtils,CastleRenderContext,
 {$ifdef OpenGLES}CastleGLES{$else}CastleGL{$endif};
class procedure TNeuralSuitAsset.RequireGPU;
{$ifndef OpenGLES}var Major,Minor:Integer;{$endif}
begin
 {$ifdef OpenGLES}raise Exception.Create('OpenGL 4.3 compute required');{$else}
 Require((RenderContext<>nil)and Assigned(glDispatchCompute)and Assigned(glGetBufferSubData)and
  Assigned(glGetIntegeri_v)and Assigned(glBindBufferBase)and Assigned(glMemoryBarrier),'OpenGL 4.3 compute unavailable');
 glGetIntegerv(GL_MAJOR_VERSION,@Major);glGetIntegerv(GL_MINOR_VERSION,@Minor);
 Require((Major>4)or((Major=4)and(Minor>=3)),'OpenGL 4.3 compute required');
 {$endif}
end;
constructor TNeuralSuitAsset.Create(const Directory:string);
var S:TFileStream;Magic:QWord;I,J,K,N,H,O:Integer;Expected:Int64;Stored:string;
 function Int:Integer;begin S.ReadBuffer(Result,4)end;
 function Count(const Limit:Integer):Integer;
 begin Result:=Int;Require((Result>=0)and(Result<=Limit),'Invalid neural asset count')end;
 function Str:string;
 var L:Integer;begin L:=Count(4096);SetLength(Result,L);if L>0 then S.ReadBuffer(Result[1],L)end;
 procedure Floats(var A:TNeuralFloats;const L:Integer);
 var K:Integer;
 begin SetLength(A,L);if L>0 then S.ReadBuffer(A[0],Int64(L)*4);for K:=0 to L-1 do Require(Finite(A[K]),'Nonfinite neural data')end;
begin
 inherited Create;ApplicationProperties.OnGLContextCloseObject.Add(@ContextClose);
 S:=TFileStream.Create(IncludeTrailingPathDelimiter(Directory)+'suit.mesh',fmOpenRead or fmShareDenyWrite);
 try
  S.ReadBuffer(Magic,8);Require(Magic=$3154495553565A52,'Unsupported neural surface version');Signature:=Str;
  VertexCount:=Count(100000);Require((VertexCount=17696)or(VertexCount=73422),'Unsupported neural surface density');
  Require(Int=NeuralBones,'Neural bone count');Require(Int=NeuralMuscles,'Neural muscle count');
  SetLength(Bones,NeuralBones);for I:=0 to High(Bones)do begin Bones[I].Name:=Str;Bones[I].Parent:=Int;Require((Bones[I].Parent>=-1)and(Bones[I].Parent<NeuralBones),'Neural parent')end;
  SetLength(Muscles,NeuralMuscles);for I:=0 to High(Muscles)do begin
   Muscles[I].Action:=Int;Muscles[I].Side:=Int;Require(Muscles[I].Side in[0,1],'Neural muscle side');
   S.ReadBuffer(Muscles[I].OriginWeight,SizeOf(TInfluence));S.ReadBuffer(Muscles[I].InsertionWeight,SizeOf(TInfluence));
  end;
  SetLength(Weights,VertexCount);S.ReadBuffer(Weights[0],VertexCount*SizeOf(TInfluence));
  for I:=0 to High(Weights)do for J:=0 to 3 do Require((Weights[I].IDs[J]>=0)and(Weights[I].IDs[J]<NeuralBones)and Finite(Weights[I].W[J]),'Neural vertex weights');
  S.ReadBuffer(Samples,SizeOf(Samples));for I:=0 to 63 do Require((Samples[I]>=0)and(Samples[I]<VertexCount),'Neural history sample');
  for K:=0 to 2 do with Parts[K]do begin
   N:=Count(2*VertexCount);SetLength(Slots,N);if N>0 then S.ReadBuffer(Slots[0],N*4);
   for I:=0 to N-1 do Require((Slots[I]>=0)and(Slots[I]<VertexCount),'Neural surface slot');
   N:=Count(3*VertexCount);SetLength(Faces,N);if N>0 then S.ReadBuffer(Faces[0],N*SizeOf(TNeuralFace));
   for I:=0 to N-1 do for J:=0 to 2 do Require((Faces[I,J]>=0)and(Faces[I,J]<Length(Slots)),'Neural surface face');
   N:=Count(2*VertexCount);Require((N=0)or(N=Length(Slots)),'Neural UV count');SetLength(UV,N);if N>0 then S.ReadBuffer(UV[0],N*SizeOf(TNeuralUV));
  end;
  Require(Int=24,'Neural body targets');SetLength(Targets,24);N:=3*VertexCount+9*NeuralBones+6*NeuralMuscles;
  for I:=0 to 23 do begin S.ReadBuffer(Targets[I].Body,SizeOf(TRiderBodyParameters));S.ReadBuffer(Targets[I].Scale,8);Floats(Targets[I].Data,N)end;
  Require(S.Position=S.Size,'Neural surface trailing bytes');
 finally S.Free end;
 S:=TFileStream.Create(IncludeTrailingPathDelimiter(Directory)+'suit.nn',fmOpenRead or fmShareDenyWrite);
 try
  S.ReadBuffer(Magic,8);Require(Magic=$314E4E48544F4C43,'Unsupported neural weights');
  N:=Int;H:=Int;O:=Int;Require((N=NeuralInputs)and(H=NeuralHidden)and(O=VertexCount*3),'Neural weights density mismatch');Stored:=Str;Require(Stored=Signature,'Neural weights/surface signature mismatch');
  Expected:=S.Position+Int64(2*N+2*O+N*H+H+O*H)*4;Require(Expected=S.Size,'Incomplete neural weights');
  Floats(FMean,N);Floats(FScale,N);Floats(FOutputMean,O);Floats(FW1,N*H);Floats(FB1,H);Floats(FW2,O*H);Floats(FB2,O);
 finally S.Free end;
end;
destructor TNeuralSuitAsset.Destroy;
begin ApplicationProperties.OnGLContextCloseObject.Remove(@ContextClose);ContextClose(nil);inherited end;
procedure TNeuralSuitAsset.ContextClose(Sender:TObject);
var I:Integer;
begin
 {$ifndef OpenGLES}
 if Assigned(glDeleteBuffers)then for I:=0 to 7 do if FBuffers[I]<>0 then glDeleteBuffers(1,@FBuffers[I]);
 if Assigned(glDeleteProgram)then for I:=0 to 1 do if FPrograms[I]<>0 then glDeleteProgram(FPrograms[I]);
 {$endif}
 FillChar(FBuffers,SizeOf(FBuffers),0);FillChar(FPrograms,SizeOf(FPrograms),0);
end;
procedure TNeuralSuitAsset.BodyShape(const Body:TRiderBodyParameters;out Rest,Pivots,Tips,Axes,Origins,Insertions:TVecArray;out BodyScale:Double);
var P:TRiderBodyParameters;V:array[0..11]of Single absolute P;
 A,B:array[0..11]of Single;Data:TNeuralFloats;S,D,I,At:Integer;W,C:Double;
 function Vec:TVec3;begin Result:=NeuralAnatomyMath.V(Data[At],Data[At+1],Data[At+2]);Inc(At,3)end;
begin
 P:=NormalizeRiderBody(Body);P.InseamCm:=RiderBodyInseamCm(P);P.ArmLengthCm:=RiderBodyArmCm(P);
 SetLength(Data,Length(Targets[0].Data));BodyScale:=0;
 for S:=0 to 1 do begin W:=1-P.Sex;if S=1 then W:=P.Sex;if W=0 then Continue;
  Move(Targets[S*12].Body,A,SizeOf(A));BodyScale+=W*Targets[S*12].Scale;
  for I:=0 to High(Data)do Data[I]+=W*Targets[S*12].Data[I];
  for D:=1 to 11 do begin Move(Targets[S*12+D].Body,B,SizeOf(B));C:=W*(V[D]-A[D])/(B[D]-A[D]);if Abs(C)<1e-9 then Continue;
   BodyScale+=C*(Targets[S*12+D].Scale-Targets[S*12].Scale);
   for I:=0 to High(Data)do Data[I]+=C*(Targets[S*12+D].Data[I]-Targets[S*12].Data[I]);
  end;
 end;
 At:=0;SetLength(Rest,VertexCount);for I:=0 to High(Rest)do Rest[I]:=Vec;
 SetLength(Pivots,NeuralBones);SetLength(Tips,NeuralBones);SetLength(Axes,NeuralBones);
 for I:=0 to NeuralBones-1 do begin Pivots[I]:=Vec;Tips[I]:=Vec;Axes[I]:=SafeUnit(Vec)end;
 SetLength(Origins,NeuralMuscles);SetLength(Insertions,NeuralMuscles);for I:=0 to NeuralMuscles-1 do begin Origins[I]:=Vec;Insertions[I]:=Vec end;
end;
procedure TNeuralSuitAsset.PrepareGPU;
{$ifndef OpenGLES}
var I,N,OK:Integer;Shader:GLuint;Code,Log:AnsiString;Ptr:PAnsiChar;
 procedure Buffer(const Index:Integer;const A:TNeuralFloats;const Count:Integer);
 begin glBindBuffer(GL_SHADER_STORAGE_BUFFER,FBuffers[Index]);if Length(A)>0 then glBufferData(GL_SHADER_STORAGE_BUFFER,Int64(Count)*4,@A[0],GL_STATIC_DRAW)else glBufferData(GL_SHADER_STORAGE_BUFFER,Int64(Count)*4,nil,GL_DYNAMIC_COPY)end;
{$endif}
begin
 {$ifdef OpenGLES}raise Exception.Create('OpenGL 4.3 compute required');{$else}
 if FPrograms[1]<>0 then Exit;
 RequireGPU;
 try
  for I:=0 to 1 do begin
   Code:='#version 430'+#10+'layout(local_size_x=64) in;'+#10;
   if I=0 then Code+=
    'layout(std430,binding=0) readonly buffer A {float w[];};layout(std430,binding=2) readonly buffer B {float x[];};'+
    'layout(std430,binding=3) writeonly buffer C {float h[];};layout(std430,binding=5) readonly buffer D {float b[];};'+
    'void main(){uint i=gl_GlobalInvocationID.x;if(i>=128u)return;float s=b[i];for(uint j=0u;j<4025u;j++)s+=w[j*128u+i]*x[j];h[i]=tanh(s);}'
   else Code+=
    'layout(std430,binding=1) readonly buffer A {float w[];};layout(std430,binding=3) readonly buffer B {float h[];};'+
    'layout(std430,binding=4) writeonly buffer C {float y[];};layout(std430,binding=6) readonly buffer D {float b[];};layout(std430,binding=7) readonly buffer E {float m[];};'+
    'void main(){uint i=gl_GlobalInvocationID.x;const uint n='+IntToStr(VertexCount*3)+'u;if(i>=n)return;float s=b[i];for(uint j=0u;j<128u;j++)s+=w[j*n+i]*h[j];y[i]=s*0.02+m[i];}';
   Shader:=glCreateShader(GL_COMPUTE_SHADER);Ptr:=PAnsiChar(Code);glShaderSource(Shader,1,@Ptr,nil);glCompileShader(Shader);
   glGetShaderiv(Shader,GL_COMPILE_STATUS,@OK);if OK=0 then begin SetLength(Log,8192);glGetShaderInfoLog(Shader,Length(Log),@N,PAnsiChar(Log));glDeleteShader(Shader);raise Exception.Create('Neural compute: '+Copy(Log,1,N))end;
   FPrograms[I]:=glCreateProgram();glAttachShader(FPrograms[I],Shader);glLinkProgram(FPrograms[I]);glDeleteShader(Shader);glGetProgramiv(FPrograms[I],GL_LINK_STATUS,@OK);Require(OK<>0,'Neural compute link failed');
  end;
  glGenBuffers(8,@FBuffers[0]);Buffer(0,FW1,Length(FW1));Buffer(1,FW2,Length(FW2));Buffer(2,nil,NeuralInputs);Buffer(3,nil,NeuralHidden);Buffer(4,nil,VertexCount*3);Buffer(5,FB1,Length(FB1));Buffer(6,FB2,Length(FB2));Buffer(7,FOutputMean,Length(FOutputMean));
  Require(glGetError()=GL_NO_ERROR,'Neural GPU allocation failed');
 except ContextClose(nil);raise end;
 {$endif}
end;
procedure TNeuralSuitAsset.Predict(const X:TNeuralFloats;out Y:TNeuralFloats);
{$ifndef OpenGLES}var A:TNeuralFloats;I,OldProgram,OldBuffer:Integer;OldSlots:array[0..7]of Integer;T:TTimerResult;{$endif}
begin
 {$ifdef OpenGLES}raise Exception.Create('OpenGL 4.3 compute required');{$else}
 Require(Length(X)=NeuralInputs,'Neural input length');RequireGPU;
 T:=Timer;glGetIntegerv(GL_CURRENT_PROGRAM,@OldProgram);glGetIntegerv(GL_SHADER_STORAGE_BUFFER_BINDING,@OldBuffer);
 for I:=0 to 7 do glGetIntegeri_v(GL_SHADER_STORAGE_BUFFER_BINDING,I,@OldSlots[I]);
 try
  PrepareGPU;SetLength(A,NeuralInputs);for I:=0 to High(A)do A[I]:=EnsureRange((X[I]-FMean[I])*FScale[I],-8.0,8.0);
  glBindBuffer(GL_SHADER_STORAGE_BUFFER,FBuffers[2]);glBufferSubData(GL_SHADER_STORAGE_BUFFER,0,NeuralInputs*4,@A[0]);
  for I:=0 to 7 do glBindBufferBase(GL_SHADER_STORAGE_BUFFER,I,FBuffers[I]);
  glUseProgram(FPrograms[0]);glDispatchCompute(2,1,1);glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT);
  glUseProgram(FPrograms[1]);glDispatchCompute((VertexCount*3+63)div 64,1,1);glMemoryBarrier(GL_BUFFER_UPDATE_BARRIER_BIT);
  SetLength(Y,VertexCount*3);glBindBuffer(GL_SHADER_STORAGE_BUFFER,FBuffers[4]);glGetBufferSubData(GL_SHADER_STORAGE_BUFFER,0,Length(Y)*4,@Y[0]);
  Require(glGetError()=GL_NO_ERROR,'Neural GPU inference failed');for I:=0 to High(Y)do Require(Finite(Y[I]),'Nonfinite neural output');Inc(Calls);
 finally
  glUseProgram(OldProgram);for I:=0 to 7 do glBindBufferBase(GL_SHADER_STORAGE_BUFFER,I,OldSlots[I]);glBindBuffer(GL_SHADER_STORAGE_BUFFER,OldBuffer);
  LastMS:=TimerSeconds(Timer,T)*1000;
 end;
 {$endif}
end;
procedure TNeuralSuitAsset.PredictCPU(const X:TNeuralFloats;out Y:TNeuralFloats);
var A,H:TNeuralFloats;I,J,N:Integer;Sum:Single;
begin
 Require(Length(X)=NeuralInputs,'Neural reference input');SetLength(A,NeuralInputs);SetLength(H,NeuralHidden);
 for I:=0 to High(A)do A[I]:=EnsureRange((X[I]-FMean[I])*FScale[I],-8.0,8.0);
 for I:=0 to High(H)do begin Sum:=FB1[I];for J:=0 to High(A)do Sum+=FW1[J*NeuralHidden+I]*A[J];H[I]:=Tanh(Sum)end;
 N:=VertexCount*3;Y:=Copy(FB2);for J:=0 to NeuralHidden-1 do for I:=0 to N-1 do Y[I]+=FW2[J*N+I]*H[J];
 for I:=0 to N-1 do Y[I]:=Y[I]*0.02+FOutputMean[I];
end;
function TNeuralSuitAsset.CheckReference(const FileName:string):Double;
var S:TFileStream;X,Y,Expected:TNeuralFloats;N,I:Integer;
begin
 S:=TFileStream.Create(FileName,fmOpenRead or fmShareDenyWrite);
 try S.ReadBuffer(N,4);Require(N=NeuralInputs,'Reference input');SetLength(X,N);S.ReadBuffer(X[0],N*4);
  S.ReadBuffer(N,4);Require(N=VertexCount*3,'Reference output');SetLength(Expected,N);S.ReadBuffer(Expected[0],N*4);
 finally S.Free end;
 Predict(X,Y);Result:=0;for I:=0 to High(Y)do Result:=Max(Result,Abs(Y[I]-Expected[I]));Require(Result<0.00002,'Neural compute differs from trained CUDA model');
end;
end.
