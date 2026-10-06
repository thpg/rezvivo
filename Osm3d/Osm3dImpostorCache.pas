unit Osm3dImpostorCache;

{$mode objfpc}{$H+}

{ Optional, viewport-local RGB-D cache. Only WorldRoot is captured. Other
  transforms (riders, bots, UI) always use the ordinary CGE render path.
  Cached depth slabs are reprojected every frame, not pasted onto the screen.
  No world geometry, collision indices, or streaming state is modified. }
interface

uses Classes, SysUtils, Math, fpjson, CastleVectors, CastleViewport,
  CastleTransform, CastleRectangles, CastleGL, CastleInternalShapesRenderer,
  CastleTimeUtils, CastleRenderOptions, Osm3dGpuTimer, GameFrameStatistics, Osm3dRtxShadow, CastleShapes;

type
  TImpostorLayer = record
    Fbo, Color, Depth: GLuint;
    Width, Height: Integer;
    Valid: Boolean;
    Captured: TTimerResult;
    Projection, InverseProjection, View, InverseView: TMatrix4;
    Position, Direction, Up: TVector3;
    Captures: QWord;
  end;

  TOsmImpostorViewport = class(TCastleViewport)
  private
    FEnabled, FFailed, FContextHooked: Boolean;
    FWorld: TCastleTransform;
    FRtx:TRtxShadow;
    FLayers: array[0..3] of TImpostorLayer;
    FCollector, FFiltered: TShapesCollector;
    FRenderer: TShapesRenderer;
    FCaptureCamera: TRenderingCamera;
    FProgram, FVAO: GLuint;
    FUniforms: array[0..6] of GLint;
    FTextureUniforms: array[0..7] of GLint;
    FWidth, FHeight: Integer;
    FBaseProjection: TMatrix4;
    FFrames, FFallbacks: QWord;
    FNear, FMiddle, FFar: Single;
    FPeriods: array[1..3] of Single;
    FResolution: Single;
    FLastError: string;
    FMeasuring, FHaveLast: Boolean;
    FMeasureStart, FMeasureLast: TTimerResult;
    FFrameSamples, FSubmitSamples, FGPUSamples: TFrameSamples;
    FGPUTimer: TAsyncGpuTimer;
    FStageTimers:array[0..4]of TAsyncGpuTimer;
    FStageSamples:array[0..4]of TFrameSamples;
    FResetOcclusionFrames:Integer;
    FWorldRevision: QWord;
    FProbeActive: Boolean;
    FProbeStart: TTimerResult;
    FProbeDuration, FProbeYaw: Single;
    FProbePosition, FProbeVelocity, FProbeDirection, FProbeUp: TVector3;
    FStabilityRemaining:Integer;
    FStabilityRect:TRectangle;
    FStabilitySamples:TJSONArray;
    FStabilityPrevious:array of Byte;
    FStabilityFrames:TMemoryStream;
    FStabilityPath:string;
    FStabilityDepth:Boolean;
    procedure SampleStability;
    procedure SetEnabled(Value: Boolean);
    procedure SetWorld(Value: TCastleTransform);
    procedure ContextClose(Sender: TObject);
    procedure EnsureResources(W,H:Integer);
    procedure CaptureLayer(Index:Integer; const Params:TRenderParams;
      const BaseProjection:TMatrix4);
    procedure Composite(const Current:TRenderingCamera; const AProjection:TMatrix4);
    procedure DrawCachedWorld(const Params:TRenderParams);
    procedure DrawWorld(const Params:TRenderParams);
    function ReflectionShape(const Shape:TShape):Boolean;
    procedure DrawReflectors(const Params:TRenderParams);
  protected
    procedure RenderFromView3D(const Params:TRenderParams); override;
    procedure Notification(AComponent:TComponent;Operation:TOperation); override;
  public
    constructor Create(AOwner:TComponent); override;
    destructor Destroy; override;
    procedure Invalidate;
    procedure WorldRevision(Value:QWord);
    procedure Configure(NearM,MiddleM,FarM,Hz1,Hz2,Hz3,Resolution:Single);
    procedure Snapshot(Dest:TJSONObject);
    procedure Measure(Start:Boolean;Dest:TJSONObject);
    procedure ProbeCamera(const Args,Dest:TJSONObject);
    procedure AdvanceProbeCamera;
    procedure ProbeStability(const Args,Dest:TJSONObject);
    property WorldRoot:TCastleTransform read FWorld write SetWorld;
    property Rtx:TRtxShadow read FRtx write FRtx;
  published
    property ImpostorCache:Boolean read FEnabled write SetEnabled default False;
  end;

implementation

uses CastleRenderContext, CastleApplicationProperties, CastleFrustum, CastleComponentSerialize,
  CastleLog, Osm3dRtxMaterials, Osm3dRiderShadow;

const
  Overscan=1.16;
  LayerScale:array[0..3]of Single=(1.0,1.0,0.8,0.6);
  VS = '#version 330 core'#10+
    'out vec2 uv; void main(){vec2 p=vec2((gl_VertexID<<1)&2,gl_VertexID&2);'+
    'uv=p;gl_Position=vec4(p*2.0-1.0,0.0,1.0);}';
  FS = '#version 330 core'#10+
    'in vec2 uv; out vec4 color;'+
    'uniform sampler2D color0,depth0,color1,depth1,color2,depth2,color3,depth3;'+
    'uniform mat4 invCurrentProjection,currentProjection;'+
    'uniform mat4 cacheProjection[4],invCacheProjection[4],toCache[4],fromCache[4];'+
    'uniform float nearSafeDepth;'+
    'vec3 unproject(vec2 p,float d,int n){vec4 q=invCacheProjection[n]*vec4(p*2.0-1.0,((d-0.1)/0.9)*2.0-1.0,1.0);return q.xyz/q.w;}'+
    'bool layer(sampler2D imageTex,sampler2D depthTex,int n,vec3 ray,inout float best,inout vec4 result){'+
    'vec3 dir=(toCache[n]*vec4(ray,0.0)).xyz;vec3 origin=toCache[n][3].xyz;'+
    'vec4 q=cacheProjection[n]*vec4(dir,0.0);if(q.w<=0.0)return false;vec2 p=q.xy/q.w*0.5+0.5;'+
    'for(int i=0;i<4;i++){float d=texture(depthTex,p).r;float z=unproject(p,d,n).z;'+
    'float t=(z-origin.z)/dir.z;q=cacheProjection[n]*vec4(origin+dir*t,1.0);'+
    'if(q.w<=0.0)return false;p=q.xy/q.w*0.5+0.5;}'+
    'if(any(lessThan(p,vec2(0)))||any(greaterThan(p,vec2(1))))return false;'+
    'float d=texture(depthTex,p).r;if(d>=0.9999999)return false;'+
    'vec4 now=currentProjection*fromCache[n]*vec4(unproject(p,d,n),1.0);'+
    'if(now.w<=0.0)return false;float nd=0.1+0.9*(now.z/now.w*0.5+0.5);'+
    'if(nd<0.1||nd>=best)return false;'+
    'vec2 error=abs(now.xy/now.w*0.5+0.5-uv)*vec2(textureSize(imageTex,0));'+
    'if(max(error.x,error.y)>2.5)return false;'+
    'best=nd;result=texture(imageTex,p);return true;}'+
    'void main(){float best=1.0;vec4 result=vec4(0);float d=texture(depth0,uv).r;'+
    'if(d<0.9999999){vec3 p=unproject(uv,d,0);vec4 q=currentProjection*vec4(p,1.0);'+
    'best=0.1+0.9*(q.z/q.w*0.5+0.5);result=texture(color0,uv);'+
    // Most pixels in the riding view need no reprojection or far texture reads.
    // Keep the overlap seam depth-tested; only skip at a safely closer depth.
    'if(-p.z<nearSafeDepth){color=result;gl_FragDepth=best;return;}}'+
    'vec4 r=invCurrentProjection*vec4(uv*2.0-1.0,0.0,1.0);vec3 ray=r.xyz/r.w;'+
    'layer(color1,depth1,1,ray,best,result);layer(color2,depth2,2,ray,best,result);'+
    'layer(color3,depth3,3,ray,best,result);'+
    'if(best>=1.0)discard;color=result;gl_FragDepth=best;}';

function CompileShader(Kind:GLenum;const Source:AnsiString):GLuint;
var P:PAnsiChar;Ok:GLint;Msg:array[0..4095]of AnsiChar;
begin
  Result:=glCreateShader(Kind);P:=PAnsiChar(Source);
  glShaderSource(Result,1,@P,nil);glCompileShader(Result);
  glGetShaderiv(Result,GL_COMPILE_STATUS,@Ok);
  if Ok=0 then begin
    glGetShaderInfoLog(Result,SizeOf(Msg),nil,@Msg[0]);
    glDeleteShader(Result);raise Exception.Create('Impostor shader: '+string(Msg));
  end;
end;

constructor TOsmImpostorViewport.Create(AOwner:TComponent);
var I:Integer;
begin
  inherited;
  FNear:=240;FMiddle:=900;FFar:=2700;
  FPeriods[1]:=0.1;FPeriods[2]:=1/3;FPeriods[3]:=1;FResolution:=1.5;
  FCollector:=TShapesCollector.Create(True);
  FFiltered:=TShapesCollector.Create(False);
  FRenderer:=TShapesRenderer.Create;
  FRenderer.BlendingSort:=sort3D;FRenderer.OcclusionSort:=sort3D;
  FCaptureCamera:=TRenderingCamera.Create;
  FFrameSamples:=TFrameSamples.Create;FSubmitSamples:=TFrameSamples.Create;
  FGPUSamples:=TFrameSamples.Create;FGPUTimer:=TAsyncGpuTimer.Create;
  for I:=0 to 4 do begin
    FStageTimers[I]:=TAsyncGpuTimer.Create;FStageSamples[I]:=TFrameSamples.Create;
  end;
end;

destructor TOsmImpostorViewport.Destroy;
var I:Integer;
begin
  SetWorld(nil);
  if FContextHooked then ApplicationProperties.OnGLContextCloseObject.Remove(@ContextClose);
  ContextClose(nil);
  FGPUTimer.Free;FGPUSamples.Free;FSubmitSamples.Free;FFrameSamples.Free;
  for I:=0 to 4 do begin FStageTimers[I].Free;FStageSamples[I].Free end;
  FCaptureCamera.Free;FFiltered.Free;FCollector.Free;FRenderer.Free;
  FStabilitySamples.Free;
  FStabilityFrames.Free;
  inherited;
end;

procedure TOsmImpostorViewport.SetWorld(Value:TCastleTransform);
begin
  if FWorld=Value then Exit;
  if FWorld<>nil then FWorld.RemoveFreeNotification(Self);
  FWorld:=Value;
  if FWorld<>nil then FWorld.FreeNotification(Self);
  Invalidate;
end;

procedure TOsmImpostorViewport.Notification(AComponent:TComponent;Operation:TOperation);
begin
  inherited;
  if (Operation=opRemove) and (AComponent=FWorld) then begin FWorld:=nil;Invalidate end;
end;

procedure TOsmImpostorViewport.SetEnabled(Value:Boolean);
begin
  if FEnabled=Value then Exit;
  FEnabled:=Value;FFailed:=False;FLastError:='';Invalidate;
  if not Value then FResetOcclusionFrames:=2;
end;

procedure TOsmImpostorViewport.Invalidate;
var I:Integer;
begin
  for I:=0 to 3 do FLayers[I].Valid:=False;
end;

procedure TOsmImpostorViewport.WorldRevision(Value:QWord);
begin
  if Value=FWorldRevision then Exit;
  FWorldRevision:=Value;
  Invalidate;
end;

procedure TOsmImpostorViewport.Configure(NearM,MiddleM,FarM,Hz1,Hz2,Hz3,Resolution:Single);
begin
  FNear:=EnsureRange(NearM,80,2000);
  FMiddle:=Max(FNear*1.5,EnsureRange(MiddleM,120,6000));
  FFar:=Max(FMiddle*1.5,EnsureRange(FarM,180,20000));
  FPeriods[1]:=1/EnsureRange(Hz1,1,120);
  FPeriods[2]:=Max(FPeriods[1],1/EnsureRange(Hz2,0.5,120));
  FPeriods[3]:=Max(FPeriods[2],1/EnsureRange(Hz3,0.25,120));
  FResolution:=EnsureRange(Resolution,0.5,1.5);Invalidate;FWidth:=0;
end;

procedure TOsmImpostorViewport.ContextClose(Sender:TObject);
var I:Integer;
begin
  { The standalone renderer owns the occlusion-box VBO/program too. Release
    those with its targets, including a context recreation or an off toggle. }
  if FRenderer<>nil then FRenderer.GLContextClose;
  for I:=0 to 3 do with FLayers[I] do begin
    if Fbo<>0 then glDeleteFramebuffers(1,@Fbo);
    if Color<>0 then glDeleteTextures(1,@Color);
    if Depth<>0 then glDeleteTextures(1,@Depth);
    Fbo:=0;Color:=0;Depth:=0;Valid:=False;Width:=0;Height:=0;
  end;
  if FProgram<>0 then glDeleteProgram(FProgram);
  if FVAO<>0 then glDeleteVertexArrays(1,@FVAO);
  FProgram:=0;FVAO:=0;FWidth:=0;FHeight:=0;
end;

procedure TOsmImpostorViewport.EnsureResources(W,H:Integer);
const Names:array[0..6]of PAnsiChar=('invCurrentProjection',
  'cacheProjection[0]','invCacheProjection[0]','toCache[0]','fromCache[0]',
  'currentProjection','nearSafeDepth');
  TextureNames:array[0..7]of PAnsiChar=('color0','depth0','color1','depth1',
    'color2','depth2','color3','depth3');
var I:Integer;Vertex,Fragment:GLuint;Ok:GLint;S:Single;
begin
  if (FWidth=W)and(FHeight=H)and(FProgram<>0)then Exit;
  if not Assigned(glGenFramebuffers)or not Assigned(glGenVertexArrays)then
    raise Exception.Create('OpenGL 3.3 required');
  if not FContextHooked then begin
    ApplicationProperties.OnGLContextCloseObject.Add(@ContextClose);FContextHooked:=True;
  end;
  ContextClose(nil);
  Vertex:=CompileShader(GL_VERTEX_SHADER,VS);
  try
    Fragment:=CompileShader(GL_FRAGMENT_SHADER,FS);
    try
      FProgram:=glCreateProgram();glAttachShader(FProgram,Vertex);glAttachShader(FProgram,Fragment);
      glLinkProgram(FProgram);glGetProgramiv(FProgram,GL_LINK_STATUS,@Ok);
      if Ok=0 then raise Exception.Create('Cannot link impostor reproject shader');
    finally glDeleteShader(Fragment) end;
  finally glDeleteShader(Vertex) end;
  for I:=0 to High(Names)do FUniforms[I]:=glGetUniformLocation(FProgram,Names[I]);
  for I:=0 to High(TextureNames)do
    FTextureUniforms[I]:=glGetUniformLocation(FProgram,TextureNames[I]);
  glGenVertexArrays(1,@FVAO);
  for I:=0 to 3 do with FLayers[I] do begin
    S:=LayerScale[I];if I>0 then S:=S*FResolution;
    Width:=Max(64,Round(W*S));Height:=Max(64,Round(H*S));
    glGenTextures(1,@Color);glBindTexture(GL_TEXTURE_2D,Color);
    glTexImage2D(GL_TEXTURE_2D,0,GL_RGBA8,Width,Height,0,GL_RGBA,GL_UNSIGNED_BYTE,nil);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
    glGenTextures(1,@Depth);glBindTexture(GL_TEXTURE_2D,Depth);
    glTexImage2D(GL_TEXTURE_2D,0,GL_DEPTH_COMPONENT32F,Width,Height,0,GL_DEPTH_COMPONENT,GL_FLOAT,nil);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
    glGenFramebuffers(1,@Fbo);glBindFramebuffer(GL_DRAW_FRAMEBUFFER,Fbo);
    glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,Color,0);
    glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER,GL_DEPTH_ATTACHMENT,GL_TEXTURE_2D,Depth,0);
    if glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER)<>GL_FRAMEBUFFER_COMPLETE then
      raise Exception.Create('Incomplete impostor framebuffer');
  end;
  FWidth:=W;FHeight:=H;
end;

procedure TOsmImpostorViewport.DrawWorld(const Params:TRenderParams);
var SavedCollector,SavedRenderer:TObject;SavedTransform:PTransformation;
    SavedFrustum:PFrustum;SavedVolumes:Boolean;T:TTransformation;Frustum:TFrustum;
    Pass:TRenderOnePassParams;
begin
  SavedCollector:=Params.Collector;SavedRenderer:=Params.RendererToPrepareShapes;
  SavedTransform:=Params.Transformation;SavedFrustum:=Params.Frustum;
  SavedVolumes:=Params.UsingShadowVolumes;
  try
    FCollector.Clear;Params.Collector:=FCollector;Params.RendererToPrepareShapes:=FRenderer.Renderer;
    Params.UsingShadowVolumes:=False;
    T.Init;if FWorld.Parent<>nil then T.MultiplyMatrix(FWorld.Parent.WorldTransform);
    Frustum:=Params.RenderingCamera.Frustum.TransformByInverse(T.Transform);
    Params.Transformation:=@T;Params.Frustum:=@Frustum;
    FWorld.Render(Params);
    Pass.Init;Pass.UsingBlending:=False;
    FFiltered.Clear;FFiltered.AddFiltered(FCollector,[False],[False,True]);
    FRenderer.Render(FFiltered,Params,Pass);
    Pass.UsingBlending:=True;
    FFiltered.Clear;FFiltered.AddFiltered(FCollector,[True],[False,True]);
    FRenderer.Render(FFiltered,Params,Pass);
  finally
    Params.Collector:=SavedCollector;Params.RendererToPrepareShapes:=SavedRenderer;
    Params.Transformation:=SavedTransform;Params.Frustum:=SavedFrustum;
    Params.UsingShadowVolumes:=SavedVolumes;
  end;
end;

function TOsmImpostorViewport.ReflectionShape(const Shape:TShape):Boolean;
begin Result:=IsRtxReflector(Shape);end;
procedure TOsmImpostorViewport.DrawReflectors(const Params:TRenderParams);
begin
  FCollector.ShapeFilter:=@ReflectionShape;
  FRenderer.OcclusionCulling:=False;
  try DrawWorld(Params);finally FCollector.ShapeFilter:=nil;end;
end;

procedure TOsmImpostorViewport.CaptureLayer(Index:Integer;const Params:TRenderParams;
  const BaseProjection:TMatrix4);
var P:TMatrix4;N,F,Scale:Single;SavedCamera:TRenderingCamera;SavedRtxView:TVector4;
begin
  P:=BaseProjection;
  case Index of
    0:begin N:=Max(0.01,BaseProjection.Data[3,2]/(BaseProjection.Data[2,2]-1));F:=FNear*1.05 end;
    1:begin N:=FNear*0.95;F:=FMiddle*1.05 end;
    2:begin N:=FMiddle*0.95;F:=FFar*1.05 end;
    else begin N:=FFar*0.95;F:=1000000 end;
  end;
  P.Data[2,2]:=-(F+N)/(F-N);P.Data[3,2]:=-2*F*N/(F-N);
  if Index>0 then begin P.Data[0,0]:=P.Data[0,0]/Overscan;P.Data[1,1]:=P.Data[1,1]/Overscan end;
  SavedCamera:=Params.RenderingCamera;
  FCaptureCamera.Assign(SavedCamera);FCaptureCamera.Projection:=P;
  { CGE Assign intentionally does not copy Camera/View. Both are required by
    distance-dependent materials, raw vegetation, and cache validity checks. }
  FCaptureCamera.View:=SavedCamera.View;FCaptureCamera.Camera:=SavedCamera.Camera;
  FCaptureCamera.Frustum.Init(P,FCaptureCamera.Matrix);
  Params.RenderingCamera:=FCaptureCamera;
  SavedRtxView:=RtxMaterialViewport;
  if FMeasuring then FStageTimers[Index].BeginSample;
  try
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER,FLayers[Index].Fbo);
    RenderContext.Viewport:=Rectangle(0,0,FLayers[Index].Width,FLayers[Index].Height);
    { Captures use another resolution and overscan, but the same camera eye.
      Sample the reflection of the matching ray, not the same framebuffer pixel. }
    Scale:=1;if Index>0 then Scale:=Overscan;
    SetRtxMaterialViewport(Vector4(FLayers[Index].Width*(1-1/Scale)*0.5,
      FLayers[Index].Height*(1-1/Scale)*0.5,FLayers[Index].Width/Scale,FLayers[Index].Height/Scale));
    RenderContext.ProjectionMatrix:=P;RenderContext.DepthRange:=drFar;
    RenderContext.DepthBufferUpdate:=True;
    glClearColor(0,0,0,0);glClearDepth(1);glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT);
    { CGE stores occlusion queries on shapes. Only the every-frame near view
      may write/use these queries; a far slab must never share that history. }
    FRenderer.OcclusionCulling:=(Index=0)and OcclusionCulling;
    DrawWorld(Params);
    with FLayers[Index]do begin
      Projection:=P;if not P.TryInverse(InverseProjection) then raise Exception.Create('Singular projection');
      View:=FCaptureCamera.Matrix;
      FCaptureCamera.InverseMatrixNeeded;InverseView:=FCaptureCamera.InverseMatrix;
      Position:=FCaptureCamera.View.Translation;Direction:=FCaptureCamera.View.Direction;Up:=FCaptureCamera.View.Up;
      Captured:=Timer;Valid:=True;Inc(Captures);
    end;
  finally
    if FMeasuring then FStageTimers[Index].EndSample;
    Params.RenderingCamera:=SavedCamera;
    SetRtxMaterialViewport(SavedRtxView);
  end;
end;

procedure TOsmImpostorViewport.Composite(const Current:TRenderingCamera;
  const AProjection:TMatrix4);
var InvP:TMatrix4;
    Projections,InverseProjections,ToCache,FromCache:array[0..3]of TMatrix4;
    I:Integer;
begin
  if FMeasuring then FStageTimers[4].BeginSample;
  AProjection.TryInverse(InvP);Current.InverseMatrixNeeded;
  for I:=0 to 3 do begin
    Projections[I]:=FLayers[I].Projection;
    InverseProjections[I]:=FLayers[I].InverseProjection;
    ToCache[I]:=FLayers[I].View*Current.InverseMatrix;
    FromCache[I]:=Current.Matrix*FLayers[I].InverseView;
    glActiveTexture(GL_TEXTURE0+I*2);glBindTexture(GL_TEXTURE_2D,FLayers[I].Color);
    glActiveTexture(GL_TEXTURE0+I*2+1);glBindTexture(GL_TEXTURE_2D,FLayers[I].Depth);
  end;
  for I:=0 to 7 do glUniform1i(FTextureUniforms[I],I);
  glUniformMatrix4fv(FUniforms[0],1,GL_FALSE,@InvP.Data[0,0]);
  glUniformMatrix4fv(FUniforms[1],4,GL_FALSE,@Projections[0].Data[0,0]);
  glUniformMatrix4fv(FUniforms[2],4,GL_FALSE,@InverseProjections[0].Data[0,0]);
  glUniformMatrix4fv(FUniforms[3],4,GL_FALSE,@ToCache[0].Data[0,0]);
  glUniformMatrix4fv(FUniforms[4],4,GL_FALSE,@FromCache[0].Data[0,0]);
  glUniformMatrix4fv(FUniforms[5],1,GL_FALSE,@AProjection.Data[0,0]);
  glUniform1f(FUniforms[6],FNear*0.9);
  glDrawArrays(GL_TRIANGLES,0,3);
  if FMeasuring then FStageTimers[4].EndSample;
end;

procedure TOsmImpostorViewport.DrawCachedWorld(const Params:TRenderParams);
var OldFbo,OldProgram,OldVAO,OldActive,OldFunc:GLint;
    OldTextures:array[0..7]of GLint;
    OldView:TRectangle;OldProjection:TMatrix4;OldRange:TDepthRange;
    OldBlend,OldDepth,OldCull,OldScissor,OldMask:GLboolean;
    I,Best:Integer;W,H:Integer;Age,Score,BestScore:Double;NearM:Single;
    Ready,OldVisible,OldOcclusion:Boolean;Now:TTimerResult;P,D,U:TVector3;
  procedure RestoreRasterState;
  begin
    { World rendering also touches CGE's logical GL state. Restore both the
      cache and actual GL state, otherwise the next ordinary pass may skip a
      necessary glEnable/glDepthMask call after a toggle or a capture. }
    RenderContext.DepthBufferUpdate:=OldMask<>GL_FALSE;
    RenderContext.DepthTest:=OldDepth<>GL_FALSE;
    RenderContext.DepthFunc:=TDepthFunction(OldFunc);
    RenderContext.CullFace:=OldCull<>GL_FALSE;
    glDepthFunc(OldFunc);glDepthMask(OldMask);
    if OldBlend<>GL_FALSE then glEnable(GL_BLEND)else glDisable(GL_BLEND);
    if OldCull<>GL_FALSE then glEnable(GL_CULL_FACE)else glDisable(GL_CULL_FACE);
    if OldDepth<>GL_FALSE then glEnable(GL_DEPTH_TEST)else glDisable(GL_DEPTH_TEST);
    if OldScissor<>GL_FALSE then glEnable(GL_SCISSOR_TEST)else glDisable(GL_SCISSOR_TEST);
  end;
begin
  OldView:=RenderContext.Viewport;OldProjection:=RenderContext.ProjectionMatrix;
  OldRange:=RenderContext.DepthRange;
  W:=OldView.Width;H:=OldView.Height;
  if (W<1)or(H<1)or(Abs(OldProjection.Data[2,3]+1)>0.001)then begin inherited RenderFromView3D(Params);Exit end;
  glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING,@OldFbo);
  glGetIntegerv(GL_CURRENT_PROGRAM,@OldProgram);glGetIntegerv(GL_VERTEX_ARRAY_BINDING,@OldVAO);
  glGetIntegerv(GL_ACTIVE_TEXTURE,@OldActive);glGetIntegerv(GL_DEPTH_FUNC,@OldFunc);
  for I:=0 to 7 do begin
    glActiveTexture(GL_TEXTURE0+I);glGetIntegerv(GL_TEXTURE_BINDING_2D,@OldTextures[I]);
  end;
  glActiveTexture(GL_TEXTURE0);
  OldBlend:=glIsEnabled(GL_BLEND);OldDepth:=glIsEnabled(GL_DEPTH_TEST);OldCull:=glIsEnabled(GL_CULL_FACE);
  OldScissor:=glIsEnabled(GL_SCISSOR_TEST);glGetBooleanv(GL_DEPTH_WRITEMASK,@OldMask);
  try
    EnsureResources(W,H);
    { Only the projection's stable X/Y terms are checked: near/far may follow scene bounds. }
    if (Abs(FBaseProjection.Data[0,0]-OldProjection.Data[0,0])>0.0001)or
       (Abs(FBaseProjection.Data[1,1]-OldProjection.Data[1,1])>0.0001)then Invalidate;
    FBaseProjection:=OldProjection;
    P:=Params.RenderingCamera.View.Translation;D:=Params.RenderingCamera.View.Direction;U:=Params.RenderingCamera.View.Up;
    Now:=Timer;Best:=-1;BestScore:=0;
    for I:=1 to 3 do begin
      case I of 1:NearM:=FNear;2:NearM:=FMiddle;else NearM:=FFar end;
      if FLayers[I].Valid and (((P-FLayers[I].Position).Length>NearM*0.012)or
         (TVector3.DotProduct(D,FLayers[I].Direction)<0.998)or
         (TVector3.DotProduct(U,FLayers[I].Up)<0.998))then FLayers[I].Valid:=False;
      if not FLayers[I].Valid then Score:=1000-I
      else begin Age:=TimerSeconds(Now,FLayers[I].Captured);Score:=Age/FPeriods[I] end;
      if Score>Max(1,BestScore)then begin Best:=I;BestScore:=Score end;
    end;
    glDisable(GL_SCISSOR_TEST);
    { At most one expensive far update per frame, including initial warmup. }
    if Best>=0 then CaptureLayer(Best,Params,OldProjection);
    Ready:=True;for I:=1 to 3 do Ready:=Ready and FLayers[I].Valid;
    if Ready then CaptureLayer(0,Params,OldProjection);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER,OldFbo);
    RenderContext.Viewport:=OldView;RenderContext.ProjectionMatrix:=OldProjection;
    RenderContext.DepthRange:=OldRange;
    if OldScissor<>GL_FALSE then glEnable(GL_SCISSOR_TEST);
    if Ready then begin
      glUseProgram(FProgram);glBindVertexArray(FVAO);
      glDisable(GL_BLEND);glDisable(GL_CULL_FACE);glEnable(GL_DEPTH_TEST);
      glDepthFunc(GL_LEQUAL);glDepthMask(GL_TRUE);
      Composite(Params.RenderingCamera,OldProjection);
      { Restore raw bindings before CGE uses its own state cache. }
      glUseProgram(OldProgram);glBindVertexArray(OldVAO);
      for I:=0 to 7 do begin glActiveTexture(GL_TEXTURE0+I);glBindTexture(GL_TEXTURE_2D,OldTextures[I])end;
      glActiveTexture(OldActive);
      RestoreRasterState;
      OldVisible:=FWorld.Visible;FWorld.Visible:=False;
      try inherited RenderFromView3D(Params);finally FWorld.Visible:=OldVisible end;
    end else begin
      Inc(FFallbacks);
      OldOcclusion:=OcclusionCulling;OcclusionCulling:=False;
      try inherited RenderFromView3D(Params);finally OcclusionCulling:=OldOcclusion end;
    end;
    Inc(FFrames);
  finally
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER,OldFbo);
    RenderContext.Viewport:=OldView;RenderContext.ProjectionMatrix:=OldProjection;RenderContext.DepthRange:=OldRange;
    glUseProgram(OldProgram);glBindVertexArray(OldVAO);
    for I:=0 to 7 do begin glActiveTexture(GL_TEXTURE0+I);glBindTexture(GL_TEXTURE_2D,OldTextures[I])end;
    glActiveTexture(OldActive);
    RestoreRasterState;
  end;
end;

procedure TOsmImpostorViewport.RenderFromView3D(const Params:TRenderParams);
var Started,Finished:TTimerResult;Ns:QWord;Screen,SavedOcclusion:Boolean;I:Integer;
begin
  Screen:=Params.RenderingCamera.Target=rtScreen;
  SavedOcclusion:=OcclusionCulling;
  if Screen and(FResetOcclusionFrames>0)then begin
    { Flush the age of shape queries from the clipped near view when returning
      to the original full renderer. Do not reuse a slab's invisible result. }
    OcclusionCulling:=False;Dec(FResetOcclusionFrames);
  end;
  if Screen and not FEnabled and (FProgram<>0) then ContextClose(nil);
  if FMeasuring and Screen then begin
    while FGPUTimer.ReadSample(Ns)do FGPUSamples.Add(Ns/1000000);
    for I:=0 to 4 do
      while FStageTimers[I].ReadSample(Ns)do FStageSamples[I].Add(Ns/1000000);
    FGPUTimer.BeginSample;Started:=Timer;
  end;
  try
    if Screen then begin
      if (FRtx<>nil) and (FWorld<>nil) then FRtx.RenderReflections(Params,@DrawReflectors)
      else SetRtxMaterialPass(False,0,Vector4(0,0,1,1));
    end;
    if not FEnabled or FFailed or not Screen or (FWorld=nil)or not FWorld.ExistsInRoot then
      inherited
    else try DrawCachedWorld(Params);
    except on E:Exception do begin
      FFailed:=True;FLastError:=E.Message;
      WritelnWarning('World impostor cache',FLastError);
      inherited RenderFromView3D(Params);
    end end;
  finally
    OcclusionCulling:=SavedOcclusion;
    if Screen and (FStabilityRemaining>0) then SampleStability;
    if FMeasuring and Screen then begin
      FGPUTimer.EndSample;Finished:=Timer;
      FSubmitSamples.Add(TimerSeconds(Finished,Started)*1000);
      if FHaveLast then FFrameSamples.Add(TimerSeconds(Finished,FMeasureLast)*1000);
      FMeasureLast:=Finished;FHaveLast:=True;
    end;
  end;
end;

procedure TOsmImpostorViewport.ProbeStability(const Args,Dest:TJSONObject);
var V:TRectangle;W,H:Integer;
begin
  if Args.Find('frames')<>nil then begin
    FStabilityRemaining:=EnsureRange(Args.Get('frames',0),0,120);
    V:=RenderContext.Viewport;
    W:=EnsureRange(Args.Get('width',256),1,Min(512,Integer(V.Width)));
    H:=EnsureRange(Args.Get('height',256),1,Min(512,Integer(V.Height)));
    FStabilityRect:=Rectangle(V.Left+EnsureRange(Args.Get('x',0),0,Integer(V.Width)-W),
      V.Bottom+EnsureRange(Args.Get('y',0),0,Integer(V.Height)-H),W,H);
    FreeAndNil(FStabilitySamples);FStabilitySamples:=TJSONArray.Create;FStabilityPrevious:=nil;
    FreeAndNil(FStabilityFrames);
    FStabilityPath:=Args.Get('raw_path','');
    FStabilityDepth:=Args.Get('shadow_depth',False);
    if (FStabilityRemaining>0) and (FStabilityPath<>'') then FStabilityFrames:=TMemoryStream.Create;
  end;
  Dest.Add('remaining',FStabilityRemaining);
  Dest.Add('width',FStabilityRect.Width);Dest.Add('height',FStabilityRect.Height);
  Dest.Add('raw_path',FStabilityPath);
  if FStabilitySamples<>nil then Dest.Add('samples',FStabilitySamples.Clone);
end;

procedure TOsmImpostorViewport.SampleStability;
var Pixels:array of Byte;I,D,Changed,Alignment:Integer;Total,Delta:Int64;J,R:TJSONObject;P:TVector3;
begin
  { Explicit, bounded diagnostic only. Never enabled during normal rendering
    or FPS measurements. Adjacent final frames catch every-other-frame flicker. }
  SetLength(Pixels,FStabilityRect.Width*FStabilityRect.Height*3);
  glGetIntegerv(GL_PACK_ALIGNMENT,@Alignment);glPixelStorei(GL_PACK_ALIGNMENT,1);
  try glReadPixels(FStabilityRect.Left,FStabilityRect.Bottom,FStabilityRect.Width,
    FStabilityRect.Height,GL_RGB,GL_UNSIGNED_BYTE,Pointer(Pixels));
  finally glPixelStorei(GL_PACK_ALIGNMENT,Alignment);end;
  Total:=0;Delta:=0;Changed:=0;
  for I:=0 to High(Pixels) do begin
    Inc(Total,Pixels[I]);
    if Length(FStabilityPrevious)=Length(Pixels) then begin
      D:=Abs(Integer(Pixels[I])-FStabilityPrevious[I]);Inc(Delta,D);if D>5 then Inc(Changed);
    end;
  end;
  J:=TJSONObject.Create;J.Add('mean',Total/Length(Pixels));
  J.Add('mean_abs_delta',Delta/Length(Pixels));J.Add('changed_fraction',Changed/Length(Pixels));
  J.Add('time_ms',Int64(GetTickCount64));
  P:=Camera.WorldView.Translation;J.Add('position',TJSONArray.Create([P.X,P.Y,P.Z]));
  P:=Camera.WorldDirection;J.Add('direction',TJSONArray.Create([P.X,P.Y,P.Z]));
  P:=Camera.WorldView.Up;J.Add('up',TJSONArray.Create([P.X,P.Y,P.Z]));
  R:=TJSONObject.Create;GroundShadowDiagnosticSnapshot(R);J.Add('shadow',R);
  if FRtx<>nil then begin
    R:=TJSONObject.Create;FRtx.Snapshot(R);
    if FStabilityDepth then FRtx.DiagnosticDepth(R);
    J.Add('rtx',R);
  end;
  if FStabilityFrames<>nil then FStabilityFrames.WriteBuffer(Pixels[0],Length(Pixels));
  FStabilitySamples.Add(J);FStabilityPrevious:=Pixels;Dec(FStabilityRemaining);
  if FStabilityRemaining=0 then begin
    FStabilityPrevious:=nil;
    if FStabilityFrames<>nil then begin
      try FStabilityFrames.SaveToFile(FStabilityPath);
      finally FreeAndNil(FStabilityFrames);end;
    end;
  end;
end;

procedure TOsmImpostorViewport.Snapshot(Dest:TJSONObject);
var I:Integer;Layers:TJSONArray;L:TJSONObject;Bytes:Int64;
begin
  Dest.Add('enabled',FEnabled);Dest.Add('failed',FFailed);Dest.Add('error',FLastError);
  Dest.Add('world_assigned',FWorld<>nil);Dest.Add('frames',Int64(FFrames));
  Dest.Add('fallback_frames',Int64(FFallbacks));Dest.Add('near_m',FNear);
  Dest.Add('middle_m',FMiddle);Dest.Add('far_m',FFar);Dest.Add('resolution',FResolution);
  Dest.Add('hz1',1/FPeriods[1]);Dest.Add('hz2',1/FPeriods[2]);Dest.Add('hz3',1/FPeriods[3]);
  Bytes:=0;Layers:=TJSONArray.Create;Dest.Add('layers',Layers);
  for I:=0 to 3 do begin
    L:=TJSONObject.Create;Layers.Add(L);L.Add('level',I);L.Add('valid',FLayers[I].Valid);
    L.Add('width',FLayers[I].Width);L.Add('height',FLayers[I].Height);
    L.Add('captures',Int64(FLayers[I].Captures));
    if I>0 then L.Add('period_s',FPeriods[I]);
    if FLayers[I].Valid then L.Add('age_s',TimerSeconds(Timer,FLayers[I].Captured));
    Bytes:=Bytes+Int64(FLayers[I].Width)*FLayers[I].Height*8;
  end;
  Dest.Add('texture_bytes',Bytes);
end;

procedure TOsmImpostorViewport.Measure(Start:Boolean;Dest:TJSONObject);
  procedure Add(const Key:string;Samples:TFrameSamples);
  var S:TFrameSummary;O:TJSONObject;
  begin
    S:=Samples.Summary;O:=TJSONObject.Create;Dest.Add(Key,O);
    O.Add('samples',S.Count);O.Add('fps',S.FPS);O.Add('mean_ms',S.MeanMs);
    O.Add('p95_ms',S.P95Ms);O.Add('p99_ms',S.P99Ms);O.Add('max_ms',S.MaxMs);O.Add('low1_fps',S.Low1FPS);
  end;
var Ns:QWord;I:Integer;
begin
  if Start then begin
    FFrameSamples.Clear;FSubmitSamples.Clear;FGPUSamples.Clear;
    for I:=0 to 4 do begin FStageTimers[I].Reset;FStageSamples[I].Clear end;
    FGPUTimer.Reset;FMeasureStart:=Timer;FHaveLast:=False;FMeasuring:=True;
  end else begin
    while FGPUTimer.ReadSample(Ns)do FGPUSamples.Add(Ns/1000000);
    for I:=0 to 4 do
      while FStageTimers[I].ReadSample(Ns)do FStageSamples[I].Add(Ns/1000000);
    FMeasuring:=False;
    Add('frame',FFrameSamples);Add('submit',FSubmitSamples);Add('gpu',FGPUSamples);
    for I:=0 to 3 do Add('capture_gpu_'+IntToStr(I),FStageSamples[I]);
    Add('composite_gpu',FStageSamples[4]);
    Dest.Add('seconds',TimerSeconds(Timer,FMeasureStart));
  end;
end;

procedure TOsmImpostorViewport.ProbeCamera(const Args,Dest:TJSONObject);
  procedure ReadVector(const Key:string;var Value:TVector3);
  var A:TJSONData;I:Integer;
  begin
    A:=Args.Find(Key);if A=nil then Exit;
    if (A.JSONType<>jtArray)or(A.Count<>3)then
      raise Exception.Create(Key+' must have three numbers');
    for I:=0 to 2 do Value.Data[I]:=A.Items[I].AsFloat;
  end;
  procedure AddVector(const Key:string;const Value:TVector3);
  begin Dest.Add(Key,TJSONArray.Create([Value.X,Value.Y,Value.Z]))end;
var P,D,U:TVector3;
begin
  if Camera=nil then raise Exception.Create('No camera');
  if Args.Get('stop',False)then FProbeActive:=False;
  if (Args.Find('position')<>nil)or(Args.Find('direction')<>nil)or
     (Args.Find('duration_s')<>nil)then begin
    FProbeActive:=False;
    Camera.GetWorldView(FProbePosition,FProbeDirection,FProbeUp);
    ReadVector('position',FProbePosition);ReadVector('direction',FProbeDirection);
    ReadVector('up',FProbeUp);
    if (FProbeDirection.Length<0.001)or
       (TVector3.CrossProduct(FProbeDirection,FProbeUp).Length<0.001)then
      raise Exception.Create('Invalid camera direction/up');
    Camera.SetWorldView(FProbePosition,FProbeDirection,FProbeUp);
    Camera.GetWorldView(FProbePosition,FProbeDirection,FProbeUp);
    FProbeVelocity:=TVector3.Zero;ReadVector('velocity',FProbeVelocity);
    FProbeYaw:=DegToRad(Args.Get('yaw_deg_s',0.0));
    FProbeDuration:=EnsureRange(Args.Get('duration_s',0.0),0.0,120.0);
    FProbeStart:=Timer;FProbeActive:=FProbeDuration>0;
  end;
  Camera.GetWorldView(P,D,U);
  AddVector('position',P);AddVector('direction',D);AddVector('up',U);
  Dest.Add('moving',FProbeActive);
end;

procedure TOsmImpostorViewport.AdvanceProbeCamera;
var Elapsed,A,C,S:Single;D,U:TVector3;
  function RotateY(const V:TVector3):TVector3;
  begin Result:=Vector3(C*V.X+S*V.Z,V.Y,-S*V.X+C*V.Z)end;
begin
  if not FProbeActive or(Camera=nil)then Exit;
  Elapsed:=Min(FProbeDuration,TimerSeconds(Timer,FProbeStart));
  A:=FProbeYaw*Elapsed;C:=Cos(A);S:=Sin(A);
  D:=RotateY(FProbeDirection);U:=RotateY(FProbeUp);
  Camera.SetWorldView(FProbePosition+FProbeVelocity*Elapsed,D,U);
  if Elapsed>=FProbeDuration then FProbeActive:=False;
end;

initialization
  RegisterSerializableComponent(TOsmImpostorViewport,'World viewport');
end.
