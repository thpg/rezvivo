unit Osm3dRawGLScope;
{$ifdef ANDROID}{$define OpenGLES}{$endif}
{$mode objfpc}{$H+}{$modeswitch advancedrecords}
interface
uses CastleVectors, CastleRectangles, CastleRenderOptions, CastleGLShaders,
  CastleGLUtils,
  {$ifdef OpenGLES}CastleGLES, RenderGLES{$else}CastleGL{$endif};
type
  { One owner for nested raw-GL passes. Keep CGE logical state and actual GL
    state coherent; texture units are explicitly declared by the caller. }
  TOsmRawGLScope = record
    DrawFbo,ReadFbo,ProgramId,Vao,Active,DepthFunction:GLint;
    Textures:array[0..15]of GLint;
    ColorMask:array[0..3]of GLboolean;
    BlendState:array[0..5]of GLint;
    Blend,Depth,Cull,Scissor,DepthMask:GLboolean;
    ActualViewport,ScissorBox:array[0..3]of GLint;
    CachedProgram:TGLSLProgram;
    CachedVao:TVertexArrayObject;
    View:TRectangle;
    Projection:TMatrix4;
    Range:TDepthRange;
    TextureCount:Integer;
    procedure Capture(Count:Integer);
    procedure Restore;
  end;
implementation
uses CastleRenderContext;
{$ifndef OpenGLES}
const GL_CONSTANT_COLOR = GL_CONSTANT_COLOR_ARB;
{$endif}

function SourceFactor(Value:GLint):TBlendingSourceFactor;
begin
  case Value of
    GL_SRC_ALPHA:Result:=bsSrcAlpha;
    GL_ONE_MINUS_SRC_ALPHA:Result:=bsOneMinusSrcAlpha;
    GL_ZERO:Result:=bsZero;GL_ONE:Result:=bsOne;
    GL_DST_COLOR:Result:=bsDstColor;GL_SRC_COLOR:Result:=bsSrcColor;
    GL_DST_ALPHA:Result:=bsDstAlpha;
    GL_ONE_MINUS_DST_COLOR:Result:=bsOneMinusDstColor;
    GL_ONE_MINUS_SRC_COLOR:Result:=bsOneMinusSrcColor;
    GL_ONE_MINUS_DST_ALPHA:Result:=bsOneMinusDstAlpha;
    GL_SRC_ALPHA_SATURATE:Result:=bsSrcAlphaSaturate;
    GL_CONSTANT_COLOR:Result:=bsConstantColor;
    GL_ONE_MINUS_CONSTANT_COLOR:Result:=bsOneMinusConstantColor;
    GL_CONSTANT_ALPHA:Result:=bsConstantAlpha;
    GL_ONE_MINUS_CONSTANT_ALPHA:Result:=bsOneMinusConstantAlpha;
  else
    { These scopes surround CGE passes; dual-source blending is not used. }
    Assert(False,'Raw GL scope: unsupported source blend factor');
    Result:=bsOne;
  end;
end;

function DestinationFactor(Value:GLint):TBlendingDestinationFactor;
begin
  case Value of
    GL_SRC_ALPHA:Result:=bdSrcAlpha;
    GL_ONE_MINUS_SRC_ALPHA:Result:=bdOneMinusSrcAlpha;
    GL_ZERO:Result:=bdZero;GL_ONE:Result:=bdOne;
    GL_DST_COLOR:Result:=bdDstColor;GL_SRC_COLOR:Result:=bdSrcColor;
    GL_DST_ALPHA:Result:=bdDstAlpha;
    GL_ONE_MINUS_DST_COLOR:Result:=bdOneMinusDstColor;
    GL_ONE_MINUS_SRC_COLOR:Result:=bdOneMinusSrcColor;
    GL_ONE_MINUS_DST_ALPHA:Result:=bdOneMinusDstAlpha;
    GL_CONSTANT_COLOR:Result:=bdConstantColor;
    GL_ONE_MINUS_CONSTANT_COLOR:Result:=bdOneMinusConstantColor;
    GL_CONSTANT_ALPHA:Result:=bdConstantAlpha;
    GL_ONE_MINUS_CONSTANT_ALPHA:Result:=bdOneMinusConstantAlpha;
  else
    Assert(False,'Raw GL scope: unsupported destination blend factor');
    Result:=bdZero;
  end;
end;
procedure TOsmRawGLScope.Capture(Count:Integer);
var I:Integer;
begin
  TextureCount:=Count;
  Assert((Count>=0) and (Count<=Length(Textures)));
  View:=RenderContext.Viewport;Projection:=RenderContext.ProjectionMatrix;Range:=RenderContext.DepthRange;
  CachedProgram:=RenderContext.CurrentProgram;CachedVao:=RenderContext.CurrentVao;
  glGetIntegerv(GL_VIEWPORT,@ActualViewport[0]);glGetIntegerv(GL_SCISSOR_BOX,@ScissorBox[0]);
  glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING,@DrawFbo);glGetIntegerv(GL_READ_FRAMEBUFFER_BINDING,@ReadFbo);
  glGetIntegerv(GL_CURRENT_PROGRAM,@ProgramId);glGetIntegerv(GL_VERTEX_ARRAY_BINDING,@Vao);
  glGetIntegerv(GL_ACTIVE_TEXTURE,@Active);glGetIntegerv(GL_DEPTH_FUNC,@DepthFunction);
  glGetIntegerv(GL_BLEND_SRC_RGB,@BlendState[0]);glGetIntegerv(GL_BLEND_DST_RGB,@BlendState[1]);
  glGetIntegerv(GL_BLEND_SRC_ALPHA,@BlendState[2]);glGetIntegerv(GL_BLEND_DST_ALPHA,@BlendState[3]);
  glGetIntegerv(GL_BLEND_EQUATION_RGB,@BlendState[4]);glGetIntegerv(GL_BLEND_EQUATION_ALPHA,@BlendState[5]);
  Blend:=glIsEnabled(GL_BLEND);Depth:=glIsEnabled(GL_DEPTH_TEST);Cull:=glIsEnabled(GL_CULL_FACE);
  Scissor:=glIsEnabled(GL_SCISSOR_TEST);glGetBooleanv(GL_DEPTH_WRITEMASK,@DepthMask);
  glGetBooleanv(GL_COLOR_WRITEMASK,@ColorMask[0]);
  for I:=0 to Count-1 do begin
    glActiveTexture(GL_TEXTURE0+I);glGetIntegerv(GL_TEXTURE_BINDING_2D,@Textures[I]);
  end;
  glActiveTexture(GL_TEXTURE0);
end;
procedure TOsmRawGLScope.Restore;
var I:Integer;Channels:TColorChannels;
begin
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER,DrawFbo);glBindFramebuffer(GL_READ_FRAMEBUFFER,ReadFbo);
  RenderContext.Viewport:=View;RenderContext.ProjectionMatrix:=Projection;RenderContext.DepthRange:=Range;
  RenderContext.DepthBufferUpdate:=DepthMask<>GL_FALSE;RenderContext.DepthTest:=Depth<>GL_FALSE;
  RenderContext.DepthFunc:=TDepthFunction(DepthFunction);RenderContext.CullFace:=Cull<>GL_FALSE;
  { Nested scene draws changed CGE's cache as well as OpenGL. Restore both,
    otherwise the next draw can incorrectly skip binding a program or VAO.
    Raw parents may have a different actual binding, restored just below. }
  RenderContext.CurrentProgram:=CachedProgram;RenderContext.CurrentVao:=CachedVao;
  Channels:=[];
  for I:=0 to 3 do if ColorMask[I]<>GL_FALSE then Include(Channels,I);
  RenderContext.ColorChannels:=Channels;
  RenderContext.BlendingEnable(SourceFactor(BlendState[0]),DestinationFactor(BlendState[1]));
  if Blend=GL_FALSE then RenderContext.BlendingDisable;
  glUseProgram(ProgramId);glBindVertexArray(Vao);
  glViewport(ActualViewport[0],ActualViewport[1],ActualViewport[2],ActualViewport[3]);
  glScissor(ScissorBox[0],ScissorBox[1],ScissorBox[2],ScissorBox[3]);
  for I:=0 to TextureCount-1 do begin glActiveTexture(GL_TEXTURE0+I);glBindTexture(GL_TEXTURE_2D,Textures[I]) end;
  glActiveTexture(Active);glDepthFunc(DepthFunction);glDepthMask(DepthMask);
  glBlendFuncSeparate(BlendState[0],BlendState[1],BlendState[2],BlendState[3]);
  glBlendEquationSeparate(BlendState[4],BlendState[5]);
  if Blend<>GL_FALSE then glEnable(GL_BLEND)else glDisable(GL_BLEND);
  if Cull<>GL_FALSE then glEnable(GL_CULL_FACE)else glDisable(GL_CULL_FACE);
  if Depth<>GL_FALSE then glEnable(GL_DEPTH_TEST)else glDisable(GL_DEPTH_TEST);
  if Scissor<>GL_FALSE then glEnable(GL_SCISSOR_TEST)else glDisable(GL_SCISSOR_TEST);
  glColorMask(ColorMask[0],ColorMask[1],ColorMask[2],ColorMask[3]);
end;
end.
