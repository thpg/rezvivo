unit Osm3dImpostorCache;
{$ifdef ANDROID}{$define OpenGLES}{$endif}

{$mode objfpc}{$H+}

{ Optional, viewport-local RGB-D cache. Only WorldRoot is captured. Other
  transforms (riders, bots, UI) always use the ordinary CGE render path.
  Cached depth slabs are reprojected every frame, not pasted onto the screen.
  No world geometry, collision indices, or streaming state is modified. }
interface

uses Classes, SysUtils, Math, fpjson, CastleVectors, CastleViewport, CastleFrustum,
  CastleTransform, CastleRectangles, {$ifdef OpenGLES}CastleGLES, RenderGLES{$else}CastleGL{$endif}, CastleInternalShapesRenderer,
  CastleTimeUtils, CastleRenderOptions, Osm3dGpuTimer, GameFrameStatistics, Osm3dRtxShadow, CastleShapes;

type
  TImpostorLayer = record
    Fbo, Color, Depth: GLuint;
    Shadow:GLuint;
    Width, Height: Integer;
    Valid: Boolean;
    ShadowValid:Boolean;
    Captured: TTimerResult;
    Projection, InverseProjection, View, InverseView: TMatrix4;
    Position, Direction, Up: TVector3;
    Captures: QWord;
    TranslationInvalidations, RotationInvalidations, PeriodCaptures: QWord;
  end;

  TOsmImpostorViewport = class(TCastleViewport)
  private
    FEnabled, FFailed, FContextHooked: Boolean;
    FWorld: TCastleTransform;
    FRtx:TRtxShadow;
    FLayers: array[0..4] of TImpostorLayer;
    FCollector, FFiltered, FDeferredBlending: TShapesCollector;
    FRenderer: TShapesRenderer;
    FCaptureCamera: TRenderingCamera;
    FProgram, FVAO: GLuint;
    FUniforms: array[0..9] of GLint;
    FTextureUniforms: array[0..13] of GLint;
    FShadowProgram,FShadowFbo:GLuint;
    FRtxCache:Boolean;
    FShadowRevision:QWord;
    FShadowCapture:Integer;
    FShadowBakes:QWord;
    FWidth, FHeight: Integer;
    FNearSamples:Integer;
    FNearFbo,FNearColor,FNearDepth:GLuint;
    FBaseProjection: TMatrix4;
    FFrames, FFallbacks: QWord;
    FFrameCacheUsed: Boolean;
    FScreenRiders:TCastleTransformList;
    FDepthReuseFrames: QWord;
    FLightingMode: Integer;
    FNear, FMiddle, FFar: Single;
    FDetail: Single;
    FDetailLayer: Boolean;
    FPeriods: array[1..4] of Single;
    FResolution: Single;
    FOverscanX, FOverscanY: Single;
    FLastError: string;
    FMeasuring, FHaveLast: Boolean;
    FMeasureStart, FMeasureLast: TTimerResult;
    FFrameSamples, FSubmitSamples, FGPUSamples: TFrameSamples;
    FGPUTimer: TAsyncGpuTimer;
    FStageTimers:array[0..5]of TAsyncGpuTimer;
    FStageSamples:array[0..5]of TFrameSamples;
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
    function FirstCachedLayer:Integer;
    function LiveDistance:Single;
    procedure SampleStability;
    procedure SetEnabled(Value: Boolean);
    procedure SetWorld(Value: TCastleTransform);
    procedure ContextClose(Sender: TObject);
    procedure EnsureResources(W,H:Integer);
    procedure CaptureLayer(Index:Integer; const Params:TRenderParams;
      const BaseProjection:TMatrix4);
    procedure Composite(const Current:TRenderingCamera; const AProjection:TMatrix4;ReusePass:Boolean);
    procedure BakeShadow(const Params:TRenderParams);
    procedure LayerRange(Index:Integer;const P:TMatrix4;out N,F:Single);
    procedure DrawCachedWorld(const Params:TRenderParams;UpdateLayers:Boolean=True);
    procedure DrawWorld(const Params:TRenderParams);
    procedure DrawTransforms(const Params:TRenderParams;One:TCastleTransform;
      Many:TCastleTransformList=nil);
    function ReflectionShape(const Shape:TShape):Boolean;
    procedure DrawReflectors(const Params:TRenderParams);
    procedure DrawScreenDepth(const Params:TRenderParams);
    procedure DrawScreenRiders(const Params:TRenderParams);
  protected
    procedure RenderFromView3D(const Params:TRenderParams); override;
    procedure Notification(AComponent:TComponent;Operation:TOperation); override;
  public
    constructor Create(AOwner:TComponent); override;
    destructor Destroy; override;
    procedure Invalidate;
    { Current camera after Update/resize, without changing OpenGL state. }
    function TryCurrentFrustum(out Value:TFrustum):Boolean;
    procedure WorldRevision(Value:QWord);
    procedure Configure(NearM,MiddleM,FarM,Hz1,Hz2,Hz3,Resolution:Single);
    procedure ConfigureOptions(const Args:TJSONObject);
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

uses CastleRenderContext, CastleApplicationProperties, CastleProjection, CastleComponentSerialize,
  CastleLog, CastleRendererInternalShader, Osm3dRtxMaterials, Osm3dRiderShadow, Osm3dRtxScreenState,
  CastleGLUtils, RiderScreenLighting;

const
  BaseOverscan=1.16;
  LayerScale:array[0..4]of Single=(1.0,1.0,1.0,0.8,0.6);
  VS = '#version 330 core'#10+
    'out vec2 uv; void main(){vec2 p=vec2((gl_VertexID<<1)&2,gl_VertexID&2);'+
    'uv=p;gl_Position=vec4(p*2.0-1.0,0.0,1.0);}';
  FS = '#version 330 core'#10+
    'in vec2 uv; out vec4 color;'+
    'uniform sampler2D color0,depth0,color1,depth1,color2,depth2,color3,depth3,color4,depth4;'+
    'uniform sampler2D shadow1,shadow2,shadow3,shadow4;uniform bool reusePass;uniform ivec4 shadowValid;'+
    'uniform mat4 invCurrentProjection,currentProjection;'+
    'uniform mat4 cacheProjection[5],invCacheProjection[5],toCache[5],fromCache[5];'+
    'uniform float nearSafeDepth;uniform bool detailLayer;'+
    'vec3 unproject(vec2 p,float d,int n){vec4 q=invCacheProjection[n]*vec4(p*2.0-1.0,((d-0.1)/0.9)*2.0-1.0,1.0);return q.xyz/q.w;}'+
    { Nearest depth is correct only at the stored texel centre. Reusing it at
      a subpixel UV makes flat roads into steps; RTX then self-shadows them.
      Fit a local depth plane, choosing the closer neighbour on each axis so
      silhouettes are not blended with the background. Intersect the current
      ray with that plane: both colour and RTX receive the same surface. }
    'vec3 surfacePoint(sampler2D tex,vec2 p,float d,int n,vec3 origin,vec3 dir){'+
    'ivec2 sz=textureSize(tex,0),i=ivec2(p*vec2(sz));'+
    'if(any(lessThan(i,ivec2(1)))||any(greaterThanEqual(i,sz-1)))return unproject(p,d,n);'+
    'vec2 centre=(vec2(i)+.5)/vec2(sz);'+
    'float l=d-texelFetch(tex,i-ivec2(1,0),0).r,r=texelFetch(tex,i+ivec2(1,0),0).r-d;'+
    'float b=d-texelFetch(tex,i-ivec2(0,1),0).r,t=texelFetch(tex,i+ivec2(0,1),0).r-d;'+
    'vec2 g=vec2(abs(l)<abs(r)?l:r,abs(b)<abs(t)?b:t)*vec2(sz)/.9;'+
    'float z=(d-.1)*2.0/.9-1.0;vec4 plane=vec4(-g,1.0,-z+dot(g,centre*2.0-1.0));'+
    'vec4 o=cacheProjection[n]*vec4(origin,1),v=cacheProjection[n]*vec4(dir,0);'+
    'float den=dot(plane,v);if(abs(den)>1e-8){float hit=-dot(plane,o)/den;'+
    'vec3 point=origin+dir*hit;vec4 q=cacheProjection[n]*vec4(point,1);'+
    'vec2 delta=abs((q.xy/q.w*.5+.5-p)*vec2(sz));'+
    'if(hit>0.0&&q.w>0.0&&max(delta.x,delta.y)<1.25)return point;}'+
    'return unproject(p,d,n);}'+
    'bool layer(sampler2D imageTex,sampler2D depthTex,sampler2D shadowTex,int n,vec3 ray,inout float best,inout vec4 result){'+
    'vec3 dir=(toCache[n]*vec4(ray,0.0)).xyz;vec3 origin=toCache[n][3].xyz;'+
    'vec4 q=cacheProjection[n]*vec4(dir,0.0);if(q.w<=0.0)return false;vec2 p=q.xy/q.w*0.5+0.5;'+
    'for(int i=0;i<4;i++){float d=texture(depthTex,p).r;float z=unproject(p,d,n).z;'+
    'float t=(z-origin.z)/dir.z;q=cacheProjection[n]*vec4(origin+dir*t,1.0);'+
    'if(q.w<=0.0)return false;p=q.xy/q.w*0.5+0.5;}'+
    'if(any(lessThan(p,vec2(0)))||any(greaterThan(p,vec2(1))))return false;'+
    'float d=texture(depthTex,p).r;if(d>=0.9999999)return false;'+
    'vec4 now=currentProjection*fromCache[n]*vec4(unproject(p,d,n),1.0);'+
    'if(now.w<=0.0)return false;float nd=0.1+0.9*(now.z/now.w*0.5+0.5);'+
    'if(nd<0.1)return false;'+
    'vec2 error=abs(now.xy/now.w*0.5+0.5-uv)*vec2(textureSize(imageTex,0));'+
    'if(max(error.x,error.y)>2.5)return false;'+
    'now=currentProjection*fromCache[n]*vec4(surfacePoint(depthTex,p,d,n,origin,dir),1.0);'+
    'if(now.w<=0.0)return false;nd=.1+.9*(now.z/now.w*.5+.5);if(nd<.1||nd>=best)return false;'+
    'best=nd;if(reusePass){vec2 s=vec2(0);if(shadowValid[n-1]!=0)s=texture(shadowTex,p).rg;'+
    'result=vec4(s.g>.999?s.r:-1.,nd,0,1);}else result=texture(imageTex,p);return true;}'+
    'void main(){float best=1.0;vec4 result=vec4(0);float nearDepth=1.0;vec4 nearColor=vec4(0);float d=texture(depth0,uv).r;'+
    'if(d<0.9999999){vec3 p=unproject(uv,d,0);vec4 q=currentProjection*vec4(p,1.0);'+
    'nearDepth=0.1+0.9*(q.z/q.w*0.5+0.5);nearColor=texture(color0,uv);'+
    // Most pixels in the riding view need no reprojection or far texture reads.
    // Keep the overlap seam depth-tested; only skip at a safely closer depth.
    'if(-p.z<nearSafeDepth&&nearColor.a>.999){color=reusePass?vec4(-1,nearDepth,0,1):nearColor;gl_FragDepth=nearDepth;return;}}'+
    'vec4 r=invCurrentProjection*vec4(uv*2.0-1.0,0.0,1.0);vec3 ray=r.xyz/r.w;'+
    'if(detailLayer)layer(color1,depth1,shadow1,1,ray,best,result);layer(color2,depth2,shadow2,2,ray,best,result);'+
    'layer(color3,depth3,shadow3,3,ray,best,result);layer(color4,depth4,shadow4,4,ray,best,result);'+
    'if(nearDepth<=best&&nearDepth<1.0){result=reusePass?vec4(-1,nearDepth,0,1):nearColor+result*(1.0-nearColor.a);best=nearDepth;}'+
    'if(best>=1.0)discard;color=result;gl_FragDepth=best;}';
  ShadowFS = '#version 330 core'#10+
    'in vec2 uv;out vec2 saved;uniform sampler2D layerDepth,screenDepth,screenShadow,screenReuse;'+
    'uniform mat4 toScreen;uniform vec2 overscan;'+
    'void main(){saved=vec2(0);float d=texture(layerDepth,uv).r;if(d>=.9999999)return;'+
    'vec2 p=(uv-.5)*overscan+.5;vec2 sz=vec2(textureSize(screenDepth,0));'+
    'if(any(lessThan(p,vec2(0)))||any(greaterThan(p,vec2(1))))return;'+
    'vec4 q=toScreen*vec4(uv*2.-1.,(d-.1)*2./.9-1.,1.);'+
    'float expected=.1+.9*(q.z/q.w*.5+.5);'+
    // Slab and screen share the same eye. Permit subpixel slope, but never
    // copy coverage from live actors or across a large depth discontinuity.
    'vec2 scale=vec2(textureSize(layerDepth,0))/sz;'+
    'float tolerance=min(2e-6,abs(dFdx(expected))*scale.x+abs(dFdy(expected))*scale.y+1.2e-7);'+
    'vec2 t=p*sz-.5,f=fract(t);ivec2 base=ivec2(floor(t));float sum=0.,weights=0.;'+
    'for(int y=0;y<2;y++)for(int x=0;x<2;x++){ivec2 i=clamp(base+ivec2(x,y),ivec2(0),ivec2(sz)-1);'+
    'float z=texelFetch(screenDepth,i,0).r,worldZ=texelFetch(screenReuse,i,0).g;'+
    'if(z>=1.||z!=worldZ||abs(z-expected)>tolerance)continue;'+
    'float w=(x==0?1.-f.x:f.x)*(y==0?1.-f.y:f.y);'+
    'sum+=texelFetch(screenShadow,i,0).r*w;weights+=w;}'+
    'if(weights>.01)saved=vec2(sum/weights,1);}';

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
  FDetail:=50;FDetailLayer:=True;
  FPeriods[1]:=1/20;FPeriods[2]:=0.1;FPeriods[3]:=1/3;FPeriods[4]:=1;FResolution:=1.5;
  FOverscanX:=BaseOverscan;FOverscanY:=BaseOverscan;
  FLightingMode:=-1;
  FRtxCache:=True;FShadowCapture:=-1;
  FCollector:=TShapesCollector.Create(True);
  FDeferredBlending:=TShapesCollector.Create(True);
  FScreenRiders:=TCastleTransformList.Create(False);
  FFiltered:=TShapesCollector.Create(False);
  FRenderer:=TShapesRenderer.Create;
  FRenderer.BlendingSort:=sort3D;FRenderer.OcclusionSort:=sort3D;
  FCaptureCamera:=TRenderingCamera.Create;
  FFrameSamples:=TFrameSamples.Create;FSubmitSamples:=TFrameSamples.Create;
  FGPUSamples:=TFrameSamples.Create;FGPUTimer:=TAsyncGpuTimer.Create;
  for I:=0 to High(FStageTimers) do begin
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
  for I:=0 to High(FStageTimers) do begin FStageTimers[I].Free;FStageSamples[I].Free end;
  FCaptureCamera.Free;FFiltered.Free;FCollector.Free;FRenderer.Free;
  FDeferredBlending.Free;
  FScreenRiders.Free;
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
  FFrameCacheUsed:=False;
  for I:=0 to High(FLayers) do begin FLayers[I].Valid:=False;FLayers[I].ShadowValid:=False end;
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
  FDetail:=Min(FDetail,FNear/1.5);
  FPeriods[2]:=1/EnsureRange(Hz1,1,120);
  FPeriods[1]:=Min(FPeriods[1],FPeriods[2]);
  FPeriods[3]:=Max(FPeriods[2],1/EnsureRange(Hz2,0.5,120));
  FPeriods[4]:=Max(FPeriods[3],1/EnsureRange(Hz3,0.25,120));
  FResolution:=EnsureRange(Resolution,0.5,1.5);Invalidate;FWidth:=0;
end;

function TOsmImpostorViewport.FirstCachedLayer:Integer;
begin if FDetailLayer then Result:=1 else Result:=2 end;

function TOsmImpostorViewport.LiveDistance:Single;
begin if FDetailLayer then Result:=FDetail else Result:=FNear end;

procedure TOsmImpostorViewport.ConfigureOptions(const Args:TJSONObject);
begin
  if (Args.Find('near_m')<>nil)or(Args.Find('middle_m')<>nil)or
     (Args.Find('far_m')<>nil)or(Args.Find('hz1')<>nil)or
     (Args.Find('hz2')<>nil)or(Args.Find('hz3')<>nil)or
     (Args.Find('resolution')<>nil)or(Args.Find('detail_layer')<>nil)or
     (Args.Find('detail_m')<>nil)or(Args.Find('detail_hz')<>nil)or
     (Args.Find('overscan_x')<>nil)or(Args.Find('overscan_y')<>nil)then begin
    Configure(Args.Get('near_m',FNear),Args.Get('middle_m',FMiddle),
      Args.Get('far_m',FFar),Args.Get('hz1',1/FPeriods[2]),
      Args.Get('hz2',1/FPeriods[3]),Args.Get('hz3',1/FPeriods[4]),
      Args.Get('resolution',FResolution));
    FDetailLayer:=Args.Get('detail_layer',FDetailLayer);
    FDetail:=EnsureRange(Args.Get('detail_m',FDetail),20,FNear/1.5);
    FPeriods[1]:=Min(FPeriods[2],1/EnsureRange(Args.Get('detail_hz',1/FPeriods[1]),1,120));
    FOverscanX:=EnsureRange(Args.Get('overscan_x',FOverscanX),1,1.75);
    FOverscanY:=EnsureRange(Args.Get('overscan_y',FOverscanY),1,1.5);
  end;
  if Args.Get('invalidate',False)then Invalidate;
  if Args.Find('rtx_cache')<>nil then begin
    if FRtxCache<>Args.Get('rtx_cache',True) then Invalidate;
    FRtxCache:=Args.Get('rtx_cache',True);
  end;
end;

procedure TOsmImpostorViewport.ContextClose(Sender:TObject);
var I:Integer;
begin
  { The standalone renderer owns the occlusion-box VBO/program too. Release
    those with its targets, including a context recreation or an off toggle. }
  if FRenderer<>nil then FRenderer.GLContextClose;
  if FNearFbo<>0 then glDeleteFramebuffers(1,@FNearFbo);
  if FNearColor<>0 then glDeleteRenderbuffers(1,@FNearColor);
  if FNearDepth<>0 then glDeleteRenderbuffers(1,@FNearDepth);
  FNearFbo:=0;FNearColor:=0;FNearDepth:=0;FNearSamples:=0;
  for I:=0 to High(FLayers) do with FLayers[I] do begin
    if Fbo<>0 then glDeleteFramebuffers(1,@Fbo);
    if Color<>0 then glDeleteTextures(1,@Color);
    if Depth<>0 then glDeleteTextures(1,@Depth);
    if Shadow<>0 then glDeleteTextures(1,@Shadow);
    Fbo:=0;Color:=0;Depth:=0;Shadow:=0;ShadowValid:=False;Valid:=False;Width:=0;Height:=0;
  end;
  if FProgram<>0 then glDeleteProgram(FProgram);
  if FVAO<>0 then glDeleteVertexArrays(1,@FVAO);
  if FShadowProgram<>0 then glDeleteProgram(FShadowProgram);
  if FShadowFbo<>0 then glDeleteFramebuffers(1,@FShadowFbo);
  FShadowProgram:=0;FShadowFbo:=0;
  FProgram:=0;FVAO:=0;FWidth:=0;FHeight:=0;
end;

procedure TOsmImpostorViewport.EnsureResources(W,H:Integer);
const Names:array[0..9]of PAnsiChar=('invCurrentProjection',
  'cacheProjection[0]','invCacheProjection[0]','toCache[0]','fromCache[0]',
  'currentProjection','nearSafeDepth','detailLayer','reusePass','shadowValid');
  TextureNames:array[0..13]of PAnsiChar=('color0','depth0','color1','depth1',
    'color2','depth2','color3','depth3','color4','depth4','shadow1','shadow2','shadow3','shadow4');
var I,Samples:Integer;Vertex,Fragment:GLuint;Ok,OldRenderbuffer,MaxSamples:GLint;S:Single;
begin
  Samples:=Max(1,GLFeatures.CurrentMultiSampling);
  glGetIntegerv(GL_MAX_SAMPLES,@MaxSamples);Samples:=Min(Samples,Max(1,MaxSamples));
  if (FWidth=W)and(FHeight=H)and(FProgram<>0)and(FNearSamples=Samples)then Exit;
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
  for I:=0 to High(FLayers) do with FLayers[I] do begin
    if (I=1)and not FDetailLayer then Continue;
    S:=LayerScale[I];if I>0 then S:=S*FResolution;
    Width:=Max(64,Round(W*S));Height:=Max(64,Round(H*S));
    { Keep the same pixel density in the visible frame when adding side margins. }
    if I>0 then begin
      Width:=Max(64,Round(W*S*FOverscanX/BaseOverscan));
      Height:=Max(64,Round(H*S*FOverscanY/BaseOverscan));
    end;
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
  FNearSamples:=Samples;
  if Samples>1 then begin
    { The near layer is redrawn every frame at native resolution. Preserve
      the user's MSAA instead of silently turning it off for all scenery. }
    glGetIntegerv(GL_RENDERBUFFER_BINDING,@OldRenderbuffer);
    try
      glGenFramebuffers(1,@FNearFbo);glBindFramebuffer(GL_DRAW_FRAMEBUFFER,FNearFbo);
      glGenRenderbuffers(1,@FNearColor);glBindRenderbuffer(GL_RENDERBUFFER,FNearColor);
      glRenderbufferStorageMultisample(GL_RENDERBUFFER,Samples,GL_RGBA8,W,H);
      glFramebufferRenderbuffer(GL_DRAW_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_RENDERBUFFER,FNearColor);
      glGenRenderbuffers(1,@FNearDepth);glBindRenderbuffer(GL_RENDERBUFFER,FNearDepth);
      glRenderbufferStorageMultisample(GL_RENDERBUFFER,Samples,GL_DEPTH_COMPONENT32F,W,H);
      glFramebufferRenderbuffer(GL_DRAW_FRAMEBUFFER,GL_DEPTH_ATTACHMENT,GL_RENDERBUFFER,FNearDepth);
      if glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER)<>GL_FRAMEBUFFER_COMPLETE then
        raise Exception.Create('Incomplete multisampled near framebuffer');
    finally glBindRenderbuffer(GL_RENDERBUFFER,OldRenderbuffer) end;
  end;
  FWidth:=W;FHeight:=H;
end;

procedure TOsmImpostorViewport.DrawWorld(const Params:TRenderParams);
begin DrawTransforms(Params,FWorld) end;

procedure TOsmImpostorViewport.DrawTransforms(const Params:TRenderParams;
  One:TCastleTransform;Many:TCastleTransformList);
var SavedCollector,SavedRenderer:TObject;SavedTransform:PTransformation;
    SavedFrustum:PFrustum;SavedVolumes:Boolean;T:TTransformation;Frustum:TFrustum;
    Pass:TRenderOnePassParams;I,Count:Integer;Node:TCastleTransform;
begin
  SavedCollector:=Params.Collector;SavedRenderer:=Params.RendererToPrepareShapes;
  SavedTransform:=Params.Transformation;SavedFrustum:=Params.Frustum;
  SavedVolumes:=Params.UsingShadowVolumes;
  try
    FCollector.Clear;Params.Collector:=FCollector;Params.RendererToPrepareShapes:=FRenderer.Renderer;
    Params.UsingShadowVolumes:=False;
    Count:=1;if Many<>nil then Count:=Many.Count;
    for I:=0 to Count-1 do begin
      Node:=One;if Many<>nil then Node:=Many[I];
      if (Node=nil) or not Node.ExistsInRoot or not Node.HasWorldTransform then Continue;
      T.Init;if Node.Parent<>nil then T.MultiplyMatrix(Node.Parent.WorldTransform);
      Frustum:=Params.RenderingCamera.Frustum.TransformByInverse(T.Transform);
      Params.Transformation:=@T;Params.Frustum:=@Frustum;
      Node.Render(Params);
    end;
    Pass.Init;Pass.UsingBlending:=False;
    FFiltered.Clear;FFiltered.AddFiltered(FCollector,[False],[False,True]);
    FRenderer.Render(FFiltered,Params,Pass);
    Pass.UsingBlending:=True;
    FFiltered.Clear;FFiltered.AddFiltered(FCollector,[True],[False,True]);
    { The live actor pass also draws translucent gates / markers in front of
      riders. Their original collected transforms survive the RTX depth pass;
      no second scene traversal or double alpha blend is needed. }
    if Many=FScreenRiders then FFiltered.AddFiltered(FDeferredBlending,[True],[False,True]);
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

function TOsmImpostorViewport.TryCurrentFrustum(out Value:TFrustum):Boolean;
var P:TProjection;Rect:TRectangle;
begin
  Value:=Default(TFrustum);Rect:=RenderRect.Round;
  Result:=(Camera<>nil)and(Rect.Width>0)and(Rect.Height>0);
  if not Result then Exit;
  P:=CalculateProjection;
  {$ifdef FPC}{$warnings off}
  if Assigned(OnProjection)then OnProjection(P);
  {$warnings on}{$endif}
  P.PerspectiveAnglesRad.Y:=P.PerspectiveAnglesRad.Y*InternalDistortFieldOfViewY;
  Value.Init(P.Matrix(InternalDistortViewAspect*Rect.Width/Rect.Height),Camera.Matrix);
end;

procedure TOsmImpostorViewport.LayerRange(Index:Integer;const P:TMatrix4;out N,F:Single);
begin
  case Index of
    0:begin N:=Max(0.01,P.Data[3,2]/(P.Data[2,2]-1));F:=LiveDistance*1.05 end;
    1:begin N:=FDetail*0.95;F:=FNear*1.05 end;
    2:begin N:=FNear*0.95;F:=FMiddle*1.05 end;
    3:begin N:=FMiddle*0.95;F:=FFar*1.05 end;
    else begin N:=FFar*0.95;F:=1000000 end;
  end;
end;

procedure TOsmImpostorViewport.CaptureLayer(Index:Integer;const Params:TRenderParams;
  const BaseProjection:TMatrix4);
var P:TMatrix4;N,F,ScaleX,ScaleY:Single;SavedCamera:TRenderingCamera;SavedRtxView:TVector4;
begin
  P:=BaseProjection;LayerRange(Index,P,N,F);
  FLayers[Index].ShadowValid:=False;
  P.Data[2,2]:=-(F+N)/(F-N);P.Data[3,2]:=-2*F*N/(F-N);
  if Index>0 then begin P.Data[0,0]:=P.Data[0,0]/FOverscanX;P.Data[1,1]:=P.Data[1,1]/FOverscanY end;
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
    if (Index=0) and (FNearFbo<>0) then glBindFramebuffer(GL_DRAW_FRAMEBUFFER,FNearFbo)
    else glBindFramebuffer(GL_DRAW_FRAMEBUFFER,FLayers[Index].Fbo);
    RenderContext.Viewport:=Rectangle(0,0,FLayers[Index].Width,FLayers[Index].Height);
    { Captures use another resolution and overscan, but the same camera eye.
      Sample the reflection of the matching ray, not the same framebuffer pixel. }
    ScaleX:=1;ScaleY:=1;
    if Index>0 then begin ScaleX:=FOverscanX;ScaleY:=FOverscanY end;
    SetRtxMaterialViewport(Vector4(FLayers[Index].Width*(1-1/ScaleX)*0.5,
      FLayers[Index].Height*(1-1/ScaleY)*0.5,FLayers[Index].Width/ScaleX,FLayers[Index].Height/ScaleY));
    RenderContext.ProjectionMatrix:=P;RenderContext.DepthRange:=drFar;
    RenderContext.DepthBufferUpdate:=True;
    glClearColor(0,0,0,0);glClearDepth(1);glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT);
    { CGE stores occlusion queries on shapes. Only the every-frame near view
      may write/use these queries; a far slab must never share that history. }
    FRenderer.OcclusionCulling:=(Index=0)and OcclusionCulling;
    DrawWorld(Params);
    if (Index=0) and (FNearFbo<>0) then begin
      glBindFramebuffer(GL_READ_FRAMEBUFFER,FNearFbo);
      glBindFramebuffer(GL_DRAW_FRAMEBUFFER,FLayers[0].Fbo);
      glBlitFramebuffer(0,0,FWidth,FHeight,0,0,FWidth,FHeight,
        GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT,GL_NEAREST);
    end;
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
  const AProjection:TMatrix4;ReusePass:Boolean);
var InvP:TMatrix4;
    Projections,InverseProjections,ToCache,FromCache:array[0..4]of TMatrix4;
    I:Integer;
begin
  if FMeasuring then FStageTimers[High(FStageTimers)].BeginSample;
  AProjection.TryInverse(InvP);Current.InverseMatrixNeeded;
  for I:=0 to High(FLayers) do begin
    Projections[I]:=FLayers[I].Projection;
    InverseProjections[I]:=FLayers[I].InverseProjection;
    ToCache[I]:=FLayers[I].View*Current.InverseMatrix;
    FromCache[I]:=Current.Matrix*FLayers[I].InverseView;
    glActiveTexture(GL_TEXTURE0+I*2);glBindTexture(GL_TEXTURE_2D,FLayers[I].Color);
    glActiveTexture(GL_TEXTURE0+I*2+1);glBindTexture(GL_TEXTURE_2D,FLayers[I].Depth);
  end;
  for I:=1 to High(FLayers) do begin
    glActiveTexture(GL_TEXTURE0+9+I);glBindTexture(GL_TEXTURE_2D,FLayers[I].Shadow);
  end;
  for I:=0 to High(FTextureUniforms) do glUniform1i(FTextureUniforms[I],I);
  glUniformMatrix4fv(FUniforms[0],1,GL_FALSE,@InvP.Data[0,0]);
  glUniformMatrix4fv(FUniforms[1],Length(FLayers),GL_FALSE,@Projections[0].Data[0,0]);
  glUniformMatrix4fv(FUniforms[2],Length(FLayers),GL_FALSE,@InverseProjections[0].Data[0,0]);
  glUniformMatrix4fv(FUniforms[3],Length(FLayers),GL_FALSE,@ToCache[0].Data[0,0]);
  glUniformMatrix4fv(FUniforms[4],Length(FLayers),GL_FALSE,@FromCache[0].Data[0,0]);
  glUniformMatrix4fv(FUniforms[5],1,GL_FALSE,@AProjection.Data[0,0]);
  glUniform1f(FUniforms[6],LiveDistance*0.9);
  glUniform1i(FUniforms[7],Ord(FDetailLayer));
  glUniform1i(FUniforms[8],Ord(ReusePass));
  glUniform4i(FUniforms[9],Ord(FLayers[1].ShadowValid),Ord(FLayers[2].ShadowValid),
    Ord(FLayers[3].ShadowValid),Ord(FLayers[4].ShadowValid));
  glDrawArrays(GL_TRIANGLES,0,3);
  if FMeasuring then FStageTimers[High(FStageTimers)].EndSample;
end;

procedure TOsmImpostorViewport.BakeShadow(const Params:TRenderParams);
var OldFbo,OldProgram,OldVAO,OldActive,Ok:GLint;
  OldView:array[0..3]of GLint;OldTextures:array[0..3]of GLint;
  OldColor:array[0..3]of GLboolean;OldDepth,OldCull,OldBlend,OldScissor:GLboolean;
  Vertex,Fragment:GLuint;I:Integer;ToScreen:TMatrix4;
begin
  if not FRtxCache or not FFrameCacheUsed or (FShadowCapture<1)or(FRtx=nil)or
    not FRtx.ScreenReuseActive or (RtxScreenTexture=0) then Exit;
  glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING,@OldFbo);
  glGetIntegerv(GL_CURRENT_PROGRAM,@OldProgram);glGetIntegerv(GL_VERTEX_ARRAY_BINDING,@OldVAO);
  glGetIntegerv(GL_ACTIVE_TEXTURE,@OldActive);glGetIntegerv(GL_VIEWPORT,@OldView[0]);
  glGetBooleanv(GL_COLOR_WRITEMASK,@OldColor[0]);
  OldDepth:=glIsEnabled(GL_DEPTH_TEST);OldCull:=glIsEnabled(GL_CULL_FACE);
  OldBlend:=glIsEnabled(GL_BLEND);OldScissor:=glIsEnabled(GL_SCISSOR_TEST);
  for I:=0 to 3 do begin glActiveTexture(GL_TEXTURE0+I);glGetIntegerv(GL_TEXTURE_BINDING_2D,@OldTextures[I])end;
  try
    if FShadowProgram=0 then begin
      Vertex:=CompileShader(GL_VERTEX_SHADER,VS);
      try
        Fragment:=CompileShader(GL_FRAGMENT_SHADER,ShadowFS);
        try
          FShadowProgram:=glCreateProgram();glAttachShader(FShadowProgram,Vertex);glAttachShader(FShadowProgram,Fragment);
          glLinkProgram(FShadowProgram);glGetProgramiv(FShadowProgram,GL_LINK_STATUS,@Ok);
          if Ok=0 then raise Exception.Create('Cannot link cached RTX visibility shader');
        finally glDeleteShader(Fragment)end;
      finally glDeleteShader(Vertex)end;
    end;
    with FLayers[FShadowCapture] do begin
      if Shadow=0 then begin
        glGenTextures(1,@Shadow);glBindTexture(GL_TEXTURE_2D,Shadow);
        glTexImage2D(GL_TEXTURE_2D,0,GL_RG16F,Width,Height,0,GL_RG,GL_FLOAT,nil);
        glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
        glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);
        glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
      end;
      if FShadowFbo=0 then glGenFramebuffers(1,@FShadowFbo);
      glBindFramebuffer(GL_DRAW_FRAMEBUFFER,FShadowFbo);
      glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER,GL_COLOR_ATTACHMENT0,GL_TEXTURE_2D,Shadow,0);
      if glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER)<>GL_FRAMEBUFFER_COMPLETE then
        raise Exception.Create('Incomplete cached RTX visibility framebuffer');
      glViewport(0,0,Width,Height);
      glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_2D,Depth);
      ToScreen:=Params.RenderingCamera.Projection*InverseProjection;
    end;
    glActiveTexture(GL_TEXTURE1);glBindTexture(GL_TEXTURE_2D,FRtx.ScreenImage(0));
    glActiveTexture(GL_TEXTURE2);glBindTexture(GL_TEXTURE_2D,RtxScreenTexture);
    glActiveTexture(GL_TEXTURE3);glBindTexture(GL_TEXTURE_2D,FRtx.ScreenImage(2));
    glUseProgram(FShadowProgram);glBindVertexArray(FVAO);
    glUniform1i(glGetUniformLocation(FShadowProgram,'layerDepth'),0);
    glUniform1i(glGetUniformLocation(FShadowProgram,'screenDepth'),1);
    glUniform1i(glGetUniformLocation(FShadowProgram,'screenShadow'),2);
    glUniform1i(glGetUniformLocation(FShadowProgram,'screenReuse'),3);
    glUniform2f(glGetUniformLocation(FShadowProgram,'overscan'),FOverscanX,FOverscanY);
    glUniformMatrix4fv(glGetUniformLocation(FShadowProgram,'toScreen'),1,GL_FALSE,@ToScreen.Data[0,0]);
    glDisable(GL_DEPTH_TEST);glDisable(GL_CULL_FACE);glDisable(GL_BLEND);glDisable(GL_SCISSOR_TEST);
    glColorMask(GL_TRUE,GL_TRUE,GL_TRUE,GL_TRUE);glDrawArrays(GL_TRIANGLES,0,3);
    FLayers[FShadowCapture].ShadowValid:=True;Inc(FShadowBakes);
  finally
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER,OldFbo);glViewport(OldView[0],OldView[1],OldView[2],OldView[3]);
    glUseProgram(OldProgram);glBindVertexArray(OldVAO);
    for I:=0 to 3 do begin glActiveTexture(GL_TEXTURE0+I);glBindTexture(GL_TEXTURE_2D,OldTextures[I])end;
    glActiveTexture(OldActive);glColorMask(OldColor[0],OldColor[1],OldColor[2],OldColor[3]);
    if OldDepth<>GL_FALSE then glEnable(GL_DEPTH_TEST);
    if OldCull<>GL_FALSE then glEnable(GL_CULL_FACE);
    if OldBlend<>GL_FALSE then glEnable(GL_BLEND);
    if OldScissor<>GL_FALSE then glEnable(GL_SCISSOR_TEST);
  end;
end;

procedure TOsmImpostorViewport.DrawCachedWorld(const Params:TRenderParams;UpdateLayers:Boolean);
var OldFbo,OldReadFbo,OldProgram,OldVAO,OldActive,OldFunc:GLint;
    OldTextures:array[0..13]of GLint;
    OldColor:array[0..3]of GLboolean;
    OldBlendState:array[0..5]of GLint;
    OldView:TRectangle;OldProjection:TMatrix4;OldRange:TDepthRange;
    OldBlend,OldDepth,OldCull,OldScissor,OldMask:GLboolean;
    I,Best:Integer;W,H:Integer;Age,Score,BestScore:Double;NearM,FarM:Single;
    Ready,OldVisible,OldOcclusion,ReusePass:Boolean;Now:TTimerResult;P,D,U:TVector3;
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
    glBlendFuncSeparate(OldBlendState[0],OldBlendState[1],OldBlendState[2],OldBlendState[3]);
    glBlendEquationSeparate(OldBlendState[4],OldBlendState[5]);
    if OldBlend<>GL_FALSE then glEnable(GL_BLEND)else glDisable(GL_BLEND);
    if OldCull<>GL_FALSE then glEnable(GL_CULL_FACE)else glDisable(GL_CULL_FACE);
    if OldDepth<>GL_FALSE then glEnable(GL_DEPTH_TEST)else glDisable(GL_DEPTH_TEST);
    if OldScissor<>GL_FALSE then glEnable(GL_SCISSOR_TEST)else glDisable(GL_SCISSOR_TEST);
    glColorMask(OldColor[0],OldColor[1],OldColor[2],OldColor[3]);
  end;
begin
  OldView:=RenderContext.Viewport;OldProjection:=RenderContext.ProjectionMatrix;
  OldRange:=RenderContext.DepthRange;
  W:=OldView.Width;H:=OldView.Height;
  if (W<1)or(H<1)or(Abs(OldProjection.Data[2,3]+1)>0.001)then begin
    if UpdateLayers and(FRtx<>nil)then FRtx.RenderReflections(Params,@DrawReflectors);
    inherited RenderFromView3D(Params);Exit
  end;
  glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING,@OldFbo);
  glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING,@OldReadFbo);
  glGetIntegerv(GL_CURRENT_PROGRAM,@OldProgram);glGetIntegerv(GL_VERTEX_ARRAY_BINDING,@OldVAO);
  glGetIntegerv(GL_ACTIVE_TEXTURE,@OldActive);glGetIntegerv(GL_DEPTH_FUNC,@OldFunc);
  glGetIntegerv(GL_BLEND_SRC_RGB,@OldBlendState[0]);glGetIntegerv(GL_BLEND_DST_RGB,@OldBlendState[1]);
  glGetIntegerv(GL_BLEND_SRC_ALPHA,@OldBlendState[2]);glGetIntegerv(GL_BLEND_DST_ALPHA,@OldBlendState[3]);
  glGetIntegerv(GL_BLEND_EQUATION_RGB,@OldBlendState[4]);glGetIntegerv(GL_BLEND_EQUATION_ALPHA,@OldBlendState[5]);
  for I:=0 to High(OldTextures) do begin
    glActiveTexture(GL_TEXTURE0+I);glGetIntegerv(GL_TEXTURE_BINDING_2D,@OldTextures[I]);
  end;
  glActiveTexture(GL_TEXTURE0);
  OldBlend:=glIsEnabled(GL_BLEND);OldDepth:=glIsEnabled(GL_DEPTH_TEST);OldCull:=glIsEnabled(GL_CULL_FACE);
  OldScissor:=glIsEnabled(GL_SCISSOR_TEST);glGetBooleanv(GL_DEPTH_WRITEMASK,@OldMask);
  glGetBooleanv(GL_COLOR_WRITEMASK,@OldColor[0]);
  ReusePass:=not UpdateLayers and FRtxCache and (FRtx<>nil) and FRtx.ScreenReady;
  try
    if UpdateLayers then begin
    EnsureResources(W,H);
    { Only the projection's stable X/Y terms are checked: near/far may follow scene bounds. }
    if (Abs(FBaseProjection.Data[0,0]-OldProjection.Data[0,0])>0.0001)or
       (Abs(FBaseProjection.Data[1,1]-OldProjection.Data[1,1])>0.0001)then Invalidate;
    FBaseProjection:=OldProjection;
    P:=Params.RenderingCamera.View.Translation;D:=Params.RenderingCamera.View.Direction;U:=Params.RenderingCamera.View.Up;
    Now:=Timer;Best:=-1;BestScore:=0;
    for I:=FirstCachedLayer to High(FLayers) do begin
      case I of 1:NearM:=FDetail;2:NearM:=FNear;3:NearM:=FMiddle;else NearM:=FFar end;
      if FLayers[I].Valid then begin
        if (P-FLayers[I].Position).Length>NearM*0.012 then begin
          FLayers[I].Valid:=False;Inc(FLayers[I].TranslationInvalidations);
        end else if (TVector3.DotProduct(D,FLayers[I].Direction)<0.998)or
          (TVector3.DotProduct(U,FLayers[I].Up)<0.998)then begin
          FLayers[I].Valid:=False;Inc(FLayers[I].RotationInvalidations);
        end;
      end;
      if not FLayers[I].Valid then Score:=1000-I
      else begin Age:=TimerSeconds(Now,FLayers[I].Captured);Score:=Age/FPeriods[I] end;
      if Score>Max(1,BestScore)then begin Best:=I;BestScore:=Score end;
    end;
    { Reflections are already in cached colour. Trace the live range and the
      selected update only. During warmup/fallback the full world is live. }
    Ready:=True;for I:=FirstCachedLayer to High(FLayers) do
      if (I<>Best)and not FLayers[I].Valid then Ready:=False;
    if FRtx<>nil then begin
      FRtx.ReflectionRanges:=TVector3.Zero;
      if FRtxCache and Ready then begin
        NearM:=1000001;FarM:=0;
        if Best>=0 then LayerRange(Best,OldProjection,NearM,FarM);
        FRtx.ReflectionRanges:=Vector3(LiveDistance*1.05,NearM,FarM);
      end;
      glBindFramebuffer(GL_DRAW_FRAMEBUFFER,OldFbo);
      FRtx.RenderReflections(Params,@DrawReflectors);
    end;
    glDisable(GL_SCISSOR_TEST);
    { At most one expensive far update per frame, including initial warmup. }
    if Best>=0 then begin
      if FLayers[Best].Valid then Inc(FLayers[Best].PeriodCaptures);
      CaptureLayer(Best,Params,OldProjection);
    end;
    Ready:=True;for I:=FirstCachedLayer to High(FLayers) do Ready:=Ready and FLayers[I].Valid;
    if Ready then begin CaptureLayer(0,Params,OldProjection);FShadowCapture:=Best end;
    end else begin
      { The RTX receiver pass must use the exact world depth displayed this
        frame. Reproject the existing layers without capturing them twice. }
      Ready:=FFrameCacheUsed;
      glDisable(GL_SCISSOR_TEST);
    end;
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER,OldFbo);
    RenderContext.Viewport:=OldView;RenderContext.ProjectionMatrix:=OldProjection;
    RenderContext.DepthRange:=OldRange;
    if OldScissor<>GL_FALSE then glEnable(GL_SCISSOR_TEST);
    if Ready then begin
      if UpdateLayers then FFrameCacheUsed:=True else Inc(FDepthReuseFrames);
      glUseProgram(FProgram);glBindVertexArray(FVAO);
      { Resolved MSAA edges contain premultiplied coverage. Composite them
        over the live sky instead of introducing a black outline. }
      glEnable(GL_BLEND);glBlendEquationSeparate(GL_FUNC_ADD,GL_FUNC_ADD);
      glBlendFuncSeparate(GL_ONE,GL_ONE_MINUS_SRC_ALPHA,GL_ONE,GL_ONE_MINUS_SRC_ALPHA);
      if ReusePass then begin
        glDisable(GL_BLEND);glColorMask(GL_TRUE,GL_TRUE,GL_TRUE,GL_TRUE);
        FRtx.ScreenReuseActive:=True;
      end;
      glDisable(GL_CULL_FACE);glEnable(GL_DEPTH_TEST);
      glDepthFunc(GL_LEQUAL);glDepthMask(GL_TRUE);
      Composite(Params.RenderingCamera,OldProjection,ReusePass);
      { Restore raw bindings before CGE uses its own state cache. }
      glUseProgram(OldProgram);glBindVertexArray(OldVAO);
      for I:=0 to High(OldTextures) do begin glActiveTexture(GL_TEXTURE0+I);glBindTexture(GL_TEXTURE_2D,OldTextures[I])end;
      glActiveTexture(OldActive);
      RestoreRasterState;
      OldVisible:=FWorld.Visible;FWorld.Visible:=False;
      try inherited RenderFromView3D(Params);finally FWorld.Visible:=OldVisible end;
    end else begin
      if UpdateLayers then Inc(FFallbacks);
      OldOcclusion:=OcclusionCulling;OcclusionCulling:=False;
      try inherited RenderFromView3D(Params);finally OcclusionCulling:=OldOcclusion end;
    end;
    if UpdateLayers then Inc(FFrames);
  finally
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER,OldFbo);
    glBindFramebuffer(GL_READ_FRAMEBUFFER,OldReadFbo);
    RenderContext.Viewport:=OldView;RenderContext.ProjectionMatrix:=OldProjection;RenderContext.DepthRange:=OldRange;
    glUseProgram(OldProgram);glBindVertexArray(OldVAO);
    for I:=0 to High(OldTextures) do begin glActiveTexture(GL_TEXTURE0+I);glBindTexture(GL_TEXTURE_2D,OldTextures[I])end;
    glActiveTexture(OldActive);
    RestoreRasterState;
  end;
end;

procedure TOsmImpostorViewport.DrawScreenDepth(const Params:TRenderParams);
var SavedOcclusion:Boolean;I:Integer;
begin
  if (FRtx<>nil)and(FShadowRevision<>FRtx.ScreenRevision)then begin
    FShadowRevision:=FRtx.ScreenRevision;
    for I:=1 to High(FLayers)do FLayers[I].ShadowValid:=False;
  end;
  { Never let the extra depth pass age/reuse visibility queries. }
  SavedOcclusion:=OcclusionCulling;OcclusionCulling:=False;
  SyncScreenShadowReceivers;
  try
    if FFrameCacheUsed then DrawCachedWorld(Params,False)
    else inherited RenderFromView3D(Params);
  finally OcclusionCulling:=SavedOcclusion;end;
end;

procedure TOsmImpostorViewport.DrawScreenRiders(const Params:TRenderParams);
begin
  if FScreenRiders.Count=0 then Exit;
  SetRiderScreenSun(RtxScreenTexture,RtxScreenView,FRtx.ScreenStrength);
  try
    FRenderer.OcclusionCulling:=OcclusionCulling;
    DrawTransforms(Params,nil,FScreenRiders);
  finally
    SetRiderScreenSun(0,Vector4(0,0,1,1),0);
  end;
end;

procedure TOsmImpostorViewport.RenderFromView3D(const Params:TRenderParams);
var Started,Finished:TTimerResult;Ns:QWord;Screen,SavedOcclusion,DeferredShadow:Boolean;I,LightingMode:Integer;
  SavedExclusive,SavedCache,SavedRequired,CachePath:Boolean;
  MainCollector,SavedDeferred:TShapesCollector;
begin
  SavedExclusive:=RtxScreenExclusive;SavedCache:=UseCachedRiderMeshes;
  SavedRequired:=RequireDeformedMeshBuffers;
  Screen:=Params.RenderingCamera.Target=rtScreen;
  CachePath:=FEnabled and not FFailed and Screen and(FWorld<>nil)and FWorld.ExistsInRoot;
  DeferredShadow:=False;
  SavedOcclusion:=OcclusionCulling;
  if Screen and(FResetOcclusionFrames>0)then begin
    { Flush the age of shape queries from the clipped near view when returning
      to the original full renderer. Do not reuse a slab's invisible result. }
    OcclusionCulling:=False;Dec(FResetOcclusionFrames);
  end;
  if Screen and not FEnabled and (FProgram<>0) then ContextClose(nil);
  if FMeasuring and Screen then begin
    while FGPUTimer.ReadSample(Ns)do FGPUSamples.Add(Ns/1000000);
    for I:=0 to High(FStageTimers) do
      while FStageTimers[I].ReadSample(Ns)do FStageSamples[I].Add(Ns/1000000);
    FGPUTimer.BeginSample;Started:=Timer;
  end;
  try
    if Screen then begin
      FFrameCacheUsed:=False;
      FScreenRiders.Clear;
      FDeferredBlending.Clear;
      FShadowCapture:=-1;
      RtxScreenExclusive:=(FRtx<>nil) and FRtx.ScreenShadows;
      if RtxScreenExclusive then begin UseCachedRiderMeshes:=True;RequireDeformedMeshBuffers:=True;end;
      ClearRtxScreenShadow;SyncScreenShadowReceivers;
      if FRtx<>nil then FRtx.ReflectionRanges:=TVector3.Zero;
      if not CachePath then begin
        if (FRtx<>nil) and (FWorld<>nil) then FRtx.RenderReflections(Params,@DrawReflectors)
        else SetRtxMaterialPass(False,0,Vector4(0,0,1,1));
      end;
      LightingMode:=Ord(RtxScreenExclusive) or (Ord((FRtx<>nil)and FRtx.ReflectionsReady) shl 1);
      if LightingMode<>FLightingMode then begin Invalidate;FLightingMode:=LightingMode end;
      { Screen shadows are composited once, after the colour image. With a
        world cache, first prepare that image and its reprojected depth, then
        trace from that same depth. Riders remain live in both passes. }
      DeferredShadow:=RtxScreenExclusive and CachePath;
      if (FRtx<>nil) and not DeferredShadow then FRtx.RenderScreenShadows(Params,@DrawScreenDepth);
      SyncScreenShadowReceivers;
      if RtxScreenExclusive and RiderScreenLightingEnabled and FRtx.ScreenReady then
        CollectRiderScreenReceivers(FRtx.DynamicCasters,FScreenRiders);
    end;
    { Draw each rider's colour exactly once, after world composition. The
      depth / RTX pass still sees them normally, with the same cached posed
      vertices. This prevents a second, display-space darkening of material
      lighting and works with both the full world and its RGB-D cache. }
    if Screen then for I:=0 to FScreenRiders.Count-1 do FScreenRiders[I].Visible:=False;
    MainCollector:=TShapesCollector(Params.Collector);SavedDeferred:=MainCollector.DeferredBlending;
    if Screen and(FScreenRiders.Count>0)then MainCollector.DeferredBlending:=FDeferredBlending;
    try
    if not CachePath then
      inherited
    else try DrawCachedWorld(Params);
    except on E:Exception do begin
      FFrameCacheUsed:=False;
      FFailed:=True;FLastError:=E.Message;
      WritelnWarning('World impostor cache',FLastError);
      if FRtx<>nil then begin
        FRtx.ReflectionRanges:=TVector3.Zero;FRtx.RenderReflections(Params,@DrawReflectors);
      end;
      inherited RenderFromView3D(Params);
    end end;
    finally
      MainCollector.DeferredBlending:=SavedDeferred;
      if Screen then for I:=0 to FScreenRiders.Count-1 do FScreenRiders[I].Visible:=True;
    end;
    if DeferredShadow then begin
      FRtx.RenderScreenShadows(Params,@DrawScreenDepth);
      try BakeShadow(Params);
      except on E:Exception do begin
        FRtxCache:=False;WritelnWarning('World RTX cache',E.Message);
      end end;
    end;
    if Screen and RtxScreenExclusive then FRtx.CompositeScreenShadows;
    if Screen then DrawScreenRiders(Params);
  finally
    RtxScreenExclusive:=SavedExclusive;UseCachedRiderMeshes:=SavedCache;
    RequireDeformedMeshBuffers:=SavedRequired;
    if Screen then begin ClearRtxScreenShadow;SyncScreenShadowReceivers;end;
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
var I:Integer;Layers:TJSONArray;L:TJSONObject;Bytes,ShadowBytes:Int64;
begin
  Dest.Add('enabled',FEnabled);Dest.Add('failed',FFailed);Dest.Add('error',FLastError);
  Dest.Add('world_assigned',FWorld<>nil);Dest.Add('frames',Int64(FFrames));
  Dest.Add('world_is_viewport_root',FWorld=Items);
  Dest.Add('used_this_frame',FFrameCacheUsed);
  Dest.Add('rtx_depth_reuse_frames',Int64(FDepthReuseFrames));
  Dest.Add('rtx_screen', (FRtx<>nil) and FRtx.ScreenShadows);
  Dest.Add('screen_material_riders',FScreenRiders.Count);
  Dest.Add('rtx_cache',FRtxCache);Dest.Add('rtx_shadow_bakes',Int64(FShadowBakes));
  Dest.Add('near_msaa',FNearSamples);
  Dest.Add('detail_layer',FDetailLayer);Dest.Add('detail_m',FDetail);Dest.Add('live_m',LiveDistance);
  Dest.Add('detail_hz',1/FPeriods[1]);
  Dest.Add('overscan_x',FOverscanX);Dest.Add('overscan_y',FOverscanY);
  Dest.Add('fallback_frames',Int64(FFallbacks));Dest.Add('near_m',FNear);
  Dest.Add('middle_m',FMiddle);Dest.Add('far_m',FFar);Dest.Add('resolution',FResolution);
  Dest.Add('hz1',1/FPeriods[2]);Dest.Add('hz2',1/FPeriods[3]);Dest.Add('hz3',1/FPeriods[4]);
  Bytes:=0;ShadowBytes:=0;Layers:=TJSONArray.Create;Dest.Add('layers',Layers);
  for I:=0 to High(FLayers) do begin
    if (I=1)and not FDetailLayer then Continue;
    L:=TJSONObject.Create;Layers.Add(L);L.Add('level',I);L.Add('valid',FLayers[I].Valid);
    L.Add('shadow_valid',FLayers[I].ShadowValid);
    if FLayers[I].Shadow<>0 then ShadowBytes:=ShadowBytes+Int64(FLayers[I].Width)*FLayers[I].Height*4;
    L.Add('width',FLayers[I].Width);L.Add('height',FLayers[I].Height);
    L.Add('captures',Int64(FLayers[I].Captures));
    L.Add('translation_invalidations',Int64(FLayers[I].TranslationInvalidations));
    L.Add('rotation_invalidations',Int64(FLayers[I].RotationInvalidations));
    L.Add('period_captures',Int64(FLayers[I].PeriodCaptures));
    if I>0 then L.Add('period_s',FPeriods[I]);
    if FLayers[I].Valid then L.Add('age_s',TimerSeconds(Timer,FLayers[I].Captured));
    Bytes:=Bytes+Int64(FLayers[I].Width)*FLayers[I].Height*8;
  end;
  Dest.Add('texture_bytes',Bytes);
  Dest.Add('rtx_shadow_texture_bytes',ShadowBytes);
  if FNearFbo<>0 then Dest.Add('near_msaa_bytes',Int64(FWidth)*FHeight*8*FNearSamples)
  else Dest.Add('near_msaa_bytes',0);
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
    for I:=0 to High(FStageTimers) do begin FStageTimers[I].Reset;FStageSamples[I].Clear end;
    FGPUTimer.Reset;FMeasureStart:=Timer;FHaveLast:=False;FMeasuring:=True;
  end else begin
    while FGPUTimer.ReadSample(Ns)do FGPUSamples.Add(Ns/1000000);
    for I:=0 to High(FStageTimers) do
      while FStageTimers[I].ReadSample(Ns)do FStageSamples[I].Add(Ns/1000000);
    FMeasuring:=False;
    Add('frame',FFrameSamples);Add('submit',FSubmitSamples);Add('gpu',FGPUSamples);
    for I:=0 to High(FLayers) do Add('capture_gpu_'+IntToStr(I),FStageSamples[I]);
    Add('composite_gpu',FStageSamples[High(FStageSamples)]);
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
