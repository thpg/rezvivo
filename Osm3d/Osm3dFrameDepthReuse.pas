unit Osm3dFrameDepthReuse;
{$ifdef ANDROID}{$define OpenGLES}{$endif}
{$mode objfpc}{$H+}
interface
uses CastleRectangles, {$ifdef OpenGLES}CastleGLES, RenderGLES{$else}CastleGL{$endif};
type
  { Single-frame transfer, NOT an image cache. Color/MSAA coverage stay in the
    original framebuffer. Resolve into the source depth format, then copy
    depth in a shader: GL forbids direct D24/S8 -> RTX D32F depth blits. }
  TOsmFrameDepthReuse=class
  private
    FSource:GLint;
    FRect:TRectangle;
    FFormat:GLint;
    FFbo,FTexture,FProgram,FVao:GLuint;
    FWidth,FHeight:Integer;
    function CreateTarget(const InternalFormat:GLint):Boolean;
  public
    Copies,Fallbacks:QWord;
    destructor Destroy;override;
    procedure ContextClose;
    function Prepare:Boolean;
    function CopyToCurrent:Boolean;
  end;
implementation
uses SysUtils, CastleRenderContext, Osm3dRawGLScope;
{$ifndef OpenGLES}
function Shader(Kind:GLenum;const Source:AnsiString):GLuint;
var P:PAnsiChar;Ok:GLint;
begin
  Result:=glCreateShader(Kind);P:=PAnsiChar(Source);glShaderSource(Result,1,@P,nil);
  glCompileShader(Result);glGetShaderiv(Result,GL_COMPILE_STATUS,@Ok);
  if Ok=0 then begin glDeleteShader(Result);raise Exception.Create('Depth transfer shader failed') end;
end;
{$endif}
destructor TOsmFrameDepthReuse.Destroy;
begin ContextClose;inherited end;
procedure TOsmFrameDepthReuse.ContextClose;
begin
  {$ifndef OpenGLES}
  if FFbo<>0 then glDeleteFramebuffers(1,@FFbo);
  if FTexture<>0 then glDeleteTextures(1,@FTexture);
  if FProgram<>0 then glDeleteProgram(FProgram);
  if FVao<>0 then glDeleteVertexArrays(1,@FVao);
  {$endif}
  FFbo:=0;FTexture:=0;FProgram:=0;FVao:=0;FFormat:=0;FWidth:=0;FHeight:=0;FSource:=0;
end;
function TOsmFrameDepthReuse.CreateTarget(const InternalFormat:GLint):Boolean;
{$ifndef OpenGLES}
var S:TOsmRawGLScope;Format,DataType,Attachment:GLenum;V,F:GLuint;Ok:GLint;
{$endif}
begin
  Result:=False;
  {$ifndef OpenGLES}
  S.Capture(1);
  try
    if FFbo<>0 then glDeleteFramebuffers(1,@FFbo);
    if FTexture<>0 then glDeleteTextures(1,@FTexture);
    FFbo:=0;FTexture:=0;
    Format:=GL_DEPTH_COMPONENT;DataType:=GL_FLOAT;Attachment:=GL_DEPTH_ATTACHMENT;
    if InternalFormat=GL_DEPTH24_STENCIL8 then begin
      Format:=GL_DEPTH_STENCIL;DataType:=GL_UNSIGNED_INT_24_8;Attachment:=GL_DEPTH_STENCIL_ATTACHMENT;
    end else if InternalFormat=GL_DEPTH32F_STENCIL8 then begin
      Format:=GL_DEPTH_STENCIL;DataType:=GL_FLOAT_32_UNSIGNED_INT_24_8_REV;Attachment:=GL_DEPTH_STENCIL_ATTACHMENT;
    end;
    glGenTextures(1,@FTexture);glBindTexture(GL_TEXTURE_2D,FTexture);
    glTexImage2D(GL_TEXTURE_2D,0,InternalFormat,FRect.Width,FRect.Height,0,Format,DataType,nil);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_COMPARE_MODE,GL_NONE);
    glGenFramebuffers(1,@FFbo);glBindFramebuffer(GL_FRAMEBUFFER,FFbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER,Attachment,GL_TEXTURE_2D,FTexture,0);
    glDrawBuffer(GL_NONE);glReadBuffer(GL_NONE);
    if glCheckFramebufferStatus(GL_FRAMEBUFFER)<>GL_FRAMEBUFFER_COMPLETE then Exit;
    if FProgram=0 then begin
      V:=Shader(GL_VERTEX_SHADER,'#version 330 core'#10+
        'void main(){vec2 p=vec2((gl_VertexID<<1)&2,gl_VertexID&2);gl_Position=vec4(p*2.-1.,0,1);}');
      try
        F:=Shader(GL_FRAGMENT_SHADER,'#version 330 core'#10+
          'uniform sampler2D sourceDepth;void main(){gl_FragDepth=texelFetch(sourceDepth,ivec2(gl_FragCoord.xy),0).r;}');
        try
          FProgram:=glCreateProgram();glAttachShader(FProgram,V);glAttachShader(FProgram,F);
          glLinkProgram(FProgram);glGetProgramiv(FProgram,GL_LINK_STATUS,@Ok);
          if Ok=0 then raise Exception.Create('Depth transfer link failed');
          glUseProgram(FProgram);glUniform1i(glGetUniformLocation(FProgram,'sourceDepth'),0);
          glGenVertexArrays(1,@FVao);
        finally glDeleteShader(F) end;
      finally glDeleteShader(V) end;
    end;
    FWidth:=FRect.Width;FHeight:=FRect.Height;FFormat:=InternalFormat;Result:=True;
  finally S.Restore end;
  {$endif}
end;
function TOsmFrameDepthReuse.Prepare:Boolean;
{$ifndef OpenGLES}
var Kind,Name,StencilKind,StencilName,Bits,Component,Format:GLint;
{$endif}
begin
  Result:=False;
  {$ifndef OpenGLES}
  FRect:=RenderContext.Viewport;glGetIntegerv(GL_DRAW_FRAMEBUFFER_BINDING,@FSource);
  { Default window depth has implementation-defined packed format. Keep the
    original renderer there instead of issuing a possibly invalid blit. }
  if (FSource=0) or (FRect.Width=0) or (FRect.Height=0) then begin Inc(Fallbacks);Exit end;
  glGetFramebufferAttachmentParameteriv(GL_DRAW_FRAMEBUFFER,GL_DEPTH_ATTACHMENT,GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE,@Kind);
  if Kind=GL_NONE then begin Inc(Fallbacks);Exit end;
  glGetFramebufferAttachmentParameteriv(GL_DRAW_FRAMEBUFFER,GL_DEPTH_ATTACHMENT,GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME,@Name);
  glGetFramebufferAttachmentParameteriv(GL_DRAW_FRAMEBUFFER,GL_DEPTH_ATTACHMENT,GL_FRAMEBUFFER_ATTACHMENT_DEPTH_SIZE,@Bits);
  glGetFramebufferAttachmentParameteriv(GL_DRAW_FRAMEBUFFER,GL_DEPTH_ATTACHMENT,GL_FRAMEBUFFER_ATTACHMENT_COMPONENT_TYPE,@Component);
  glGetFramebufferAttachmentParameteriv(GL_DRAW_FRAMEBUFFER,GL_STENCIL_ATTACHMENT,GL_FRAMEBUFFER_ATTACHMENT_OBJECT_TYPE,@StencilKind);
  StencilName:=-1;
  if StencilKind<>GL_NONE then
    glGetFramebufferAttachmentParameteriv(GL_DRAW_FRAMEBUFFER,GL_STENCIL_ATTACHMENT,GL_FRAMEBUFFER_ATTACHMENT_OBJECT_NAME,@StencilName);
  Format:=0;
  if (Name=StencilName) and (Kind=StencilKind) then begin
    if (Bits=24) and (Component=GL_UNSIGNED_NORMALIZED) then Format:=GL_DEPTH24_STENCIL8;
    if (Bits=32) and (Component=GL_FLOAT) then Format:=GL_DEPTH32F_STENCIL8;
  end else begin
    if Component=GL_UNSIGNED_NORMALIZED then
      case Bits of 16:Format:=GL_DEPTH_COMPONENT16;24:Format:=GL_DEPTH_COMPONENT24;32:Format:=GL_DEPTH_COMPONENT32 end
    else if (Bits=32) and (Component=GL_FLOAT) then Format:=GL_DEPTH_COMPONENT32F;
  end;
  if Format=0 then begin Inc(Fallbacks);Exit end;
  Result:=(FFormat=Format) and (FWidth=FRect.Width) and (FHeight=FRect.Height) and (FFbo<>0);
  if not Result then Result:=CreateTarget(Format);
  if not Result then Inc(Fallbacks);
  {$endif}
end;
function TOsmFrameDepthReuse.CopyToCurrent:Boolean;
{$ifndef OpenGLES}
var S:TOsmRawGLScope;
{$endif}
begin
  Result:=False;
  {$ifndef OpenGLES}
  if (FFbo=0) or (FSource=0) or (FProgram=0) or
     (RenderContext.Viewport.Width<>FWidth) or (RenderContext.Viewport.Height<>FHeight) then Exit;
  S.Capture(1);
  try
    glDisable(GL_SCISSOR_TEST);glBindFramebuffer(GL_READ_FRAMEBUFFER,FSource);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER,FFbo);
    glBlitFramebuffer(FRect.Left,FRect.Bottom,FRect.Left+FWidth,FRect.Bottom+FHeight,
      0,0,FWidth,FHeight,GL_DEPTH_BUFFER_BIT,GL_NEAREST);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER,S.DrawFbo);
    glUseProgram(FProgram);glBindVertexArray(FVao);glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_2D,FTexture);
    glDisable(GL_BLEND);glDisable(GL_CULL_FACE);glEnable(GL_DEPTH_TEST);glDepthFunc(GL_ALWAYS);glDepthMask(GL_TRUE);
    glColorMask(GL_FALSE,GL_FALSE,GL_FALSE,GL_FALSE);glDrawArrays(GL_TRIANGLES,0,3);
    Inc(Copies);Result:=True;
  finally S.Restore end;
  {$endif}
end;
end.
