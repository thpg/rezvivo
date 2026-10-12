unit RenderGLES;
{$mode objfpc}{$H+}
interface
uses CastleGLES;
{ Desktop convenience operations implemented with GLES 3 core functions. }
procedure glDrawBuffer(Mode: GLenum); inline;
procedure glClearDepth(Value: Double); inline;
procedure glGetBufferSubData(Target: GLenum; Offset: GLintptr;
  Size: GLsizeiptr; Data: Pointer);
implementation
uses SysUtils;
procedure glDrawBuffer(Mode: GLenum);
begin glDrawBuffers(1, @Mode) end;
procedure glClearDepth(Value: Double);
begin glClearDepthf(Value) end;
procedure glGetBufferSubData(Target: GLenum; Offset: GLintptr;
  Size: GLsizeiptr; Data: Pointer);
var P: Pointer;
begin
  if Size = 0 then Exit;
  P := glMapBufferRange(Target, Offset, Size, GL_MAP_READ_BIT);
  if P = nil then raise Exception.Create('GPU buffer readback failed');
  try Move(P^, Data^, Size); finally glUnmapBuffer(Target) end;
end;
end.
