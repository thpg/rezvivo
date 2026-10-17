unit VegetationAtlasUpload;
{$mode objfpc}{$H+}
{$ifdef ANDROID}{$define OpenGLES}{$endif}
interface
uses SysUtils,Math,VegetationAtlas,{$ifdef OpenGLES}CastleGLES{$else}GL,GLExt{$endif};
const ATLAS_UPLOAD_CHUNK=256*1024;ATLAS_UPLOAD_SLOTS=3;
type
  EAtlasUpload=class(Exception);
  TAtlasUpload=class
  private
    FLevels:array[0..1]of TAtlasLevels;
    FTexture:array[0..1]of GLuint;
    FSlots:array[0..ATLAS_UPLOAD_SLOTS-1]of record Buffer:GLuint;Fence:GLsync;Failed:Boolean;end;
    FPart,FLevel,FLayer,FRow:Integer;
    FComplete:GLsync;
    FSubmitted,FReady,FFailed:Boolean;
    FStart:QWord;
    procedure AllocateTextures;
  public
    UploadBytes,Stalls:QWord;
    constructor Create(const Color,Normal:TAtlasLevels);
    destructor Destroy;override;
    function Step(ByteBudget:Integer;TimeBudgetMS:Double):Boolean;
    procedure Take(out Color,Normal:GLuint);
    function PendingBytes:Int64;
    function ElapsedSeconds:Single;
    property Ready:Boolean read FReady;
  end;
implementation
uses VegetationRenderOptions;
procedure ClearAtlasErrors;
var I:Integer;
begin
  { Only at the start of an upload operation, never on idle render frames.
    A lost/broken context must not trap the render thread in a drain loop. }
  for I:=0 to 15 do if glGetError()=GL_NO_ERROR then Exit;
  raise EAtlasUpload.Create('Atlas upload: GL error state did not clear');
end;
procedure CheckAtlasGL(const Operation:string);
var ErrorCode:GLenum;
begin
  ErrorCode:=glGetError();
  if ErrorCode<>GL_NO_ERROR then
    raise EAtlasUpload.CreateFmt('Atlas %s failed (GL $%x)',[Operation,ErrorCode]);
end;
procedure ValidateAtlasLevels(const Levels:TAtlasLevels);
var I,S,N:Integer;Bytes:Int64;
begin
  if Length(Levels)=0 then Exit;
  S:=Levels[0].Size;N:=Levels[0].Layers;
  if(S<1)or((S and(S-1))<>0)or(N<1)then
    raise EArgumentException.Create('Invalid atlas dimensions');
  for I:=0 to High(Levels)do begin
    Bytes:=Int64(S)*S*N*4;
    if(Levels[I].Size<>S)or(Levels[I].Layers<>N)or(Bytes>High(Integer))or
      (Length(Levels[I].Pixels)<>Bytes)then
      raise EArgumentException.Create('Invalid atlas mip pixels');
    if(S=1)and(I<>High(Levels))then raise EArgumentException.Create('Excess atlas mip levels');
    if(I=High(Levels))and(S<>1)then raise EArgumentException.Create('Incomplete atlas mip chain');
    S:=Max(1,S div 2);
  end;
end;
constructor TAtlasUpload.Create(const Color,Normal:TAtlasLevels);
var I:Integer;
begin
  inherited Create;if Length(Color)=0 then raise EArgumentException.Create('Empty atlas upload');
  ValidateAtlasLevels(Color);ValidateAtlasLevels(Normal);
  if(Length(Normal)>0)and(Normal[0].Layers<>Color[0].Layers)then
    raise EArgumentException.Create('Mismatched atlas normal layers');
  FLevels[0]:=Color;FLevels[1]:=Normal;FStart:=GetTickCount64;
  ClearAtlasErrors;
  for I:=0 to High(FSlots)do begin
    glGenBuffers(1,@FSlots[I].Buffer);CheckAtlasGL('staging buffer creation');
    if FSlots[I].Buffer=0 then raise EAtlasUpload.Create('Atlas staging buffer name is zero');
  end;
  AllocateTextures;
end;
procedure TAtlasUpload.AllocateTextures;
var Part,L:Integer;Old,OldPBO:GLint;
begin
  glGetIntegerv(GL_TEXTURE_BINDING_2D_ARRAY,@Old);
  glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING,@OldPBO);CheckAtlasGL('allocation state query');
  try
    glBindBuffer(GL_PIXEL_UNPACK_BUFFER,0);CheckAtlasGL('allocation unpack binding');
    for Part:=0 to 1 do if Length(FLevels[Part])>0 then begin
      glGenTextures(1,@FTexture[Part]);CheckAtlasGL('texture creation');
      if FTexture[Part]=0 then raise EAtlasUpload.Create('Atlas texture name is zero');
      glBindTexture(GL_TEXTURE_2D_ARRAY,FTexture[Part]);CheckAtlasGL('texture binding');
      for L:=0 to High(FLevels[Part])do with FLevels[Part][L]do begin
        glTexImage3D(GL_TEXTURE_2D_ARRAY,L,GL_RGBA8,Size,Size,Layers,0,GL_RGBA,GL_UNSIGNED_BYTE,nil);
        CheckAtlasGL('mip allocation');
      end;
      glTexParameteri(GL_TEXTURE_2D_ARRAY,GL_TEXTURE_MIN_FILTER,GL_LINEAR_MIPMAP_LINEAR);
      glTexParameteri(GL_TEXTURE_2D_ARRAY,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
      glTexParameteri(GL_TEXTURE_2D_ARRAY,GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);glTexParameteri(GL_TEXTURE_2D_ARRAY,GL_TEXTURE_WRAP_T,GL_CLAMP_TO_EDGE);
      CheckAtlasGL('texture parameters');
    end;
  finally glBindTexture(GL_TEXTURE_2D_ARRAY,Old);glBindBuffer(GL_PIXEL_UNPACK_BUFFER,OldPBO)end;
end;
destructor TAtlasUpload.Destroy;
var I:Integer;
begin
  if FComplete<>nil then glDeleteSync(FComplete);
  for I:=0 to High(FSlots)do begin
    if FSlots[I].Fence<>nil then glDeleteSync(FSlots[I].Fence);
    if FSlots[I].Buffer<>0 then glDeleteBuffers(1,@FSlots[I].Buffer);
  end;
  for I:=0 to 1 do if FTexture[I]<>0 then glDeleteTextures(1,@FTexture[I]);
  inherited;
end;
function TAtlasUpload.Step(ByteBudget:Integer;TimeBudgetMS:Double):Boolean;
const State:array[0..4]of GLenum=(GL_UNPACK_ROW_LENGTH,GL_UNPACK_IMAGE_HEIGHT,GL_UNPACK_SKIP_PIXELS,GL_UNPACK_SKIP_ROWS,GL_UNPACK_SKIP_IMAGES);
var Slot,I,Size,Rows,Bytes,Offset,OldTexture,OldPBO,OldAlignment:Integer;Status:GLenum;Started:QWord;
    OldState:array[0..4]of GLint;
begin
  if FFailed then raise EAtlasUpload.Create('Atlas upload already failed');
  Result:=FReady;if FReady then Exit;
  try
  ClearAtlasErrors;
  if FSubmitted then begin
    Status:=glClientWaitSync(FComplete,0,0);
    if Status=GL_WAIT_FAILED then begin CheckAtlasGL('completion fence wait');raise EAtlasUpload.Create('Atlas completion fence wait failed');end;
    if(Status=GL_ALREADY_SIGNALED)or(Status=GL_CONDITION_SATISFIED)then begin FReady:=True;Result:=True end;
    Exit;
  end;
  Started:=GetTickCount64;glGetIntegerv(GL_TEXTURE_BINDING_2D_ARRAY,@OldTexture);
  glGetIntegerv(GL_PIXEL_UNPACK_BUFFER_BINDING,@OldPBO);glGetIntegerv(GL_UNPACK_ALIGNMENT,@OldAlignment);
  for I:=0 to High(State)do glGetIntegerv(State[I],@OldState[I]);
  CheckAtlasGL('upload state query');
  try
    for I:=0 to High(State)do glPixelStorei(State[I],0);
    glPixelStorei(GL_UNPACK_ALIGNMENT,1);
    CheckAtlasGL('upload pixel store');
    while(ByteBudget>0)and(GetTickCount64-Started<Max(1,Ceil(TimeBudgetMS)))do begin
      Slot:=-1;
      for I:=0 to High(FSlots)do begin
        if FSlots[I].Failed then Continue;
        if FSlots[I].Fence<>nil then begin
          Status:=glClientWaitSync(FSlots[I].Fence,0,0);
          if Status=GL_WAIT_FAILED then begin CheckAtlasGL('staging fence wait');raise EAtlasUpload.Create('Atlas staging fence wait failed');end;
          if(Status=GL_ALREADY_SIGNALED)or(Status=GL_CONDITION_SATISFIED)then begin glDeleteSync(FSlots[I].Fence);FSlots[I].Fence:=nil end;
        end;
        if FSlots[I].Fence=nil then begin Slot:=I;Break end;
      end;
      if Slot<0 then begin Inc(Stalls);Break end;
      Size:=FLevels[FPart][FLevel].Size;
      Rows:=Min(Size-FRow,Min(ATLAS_UPLOAD_CHUNK,ByteBudget)div(Size*4));if Rows<1 then Break;
      Bytes:=Rows*Size*4;Offset:=((FLayer*Size+FRow)*Size)*4;
      glBindBuffer(GL_PIXEL_UNPACK_BUFFER,FSlots[Slot].Buffer);
      CheckAtlasGL('staging buffer binding');
      { Orphan only an idle ring slot. Bounded staging, no readback/map wait. }
      glBufferData(GL_PIXEL_UNPACK_BUFFER,Bytes,@FLevels[FPart][FLevel].Pixels[Offset],GL_STREAM_DRAW);
      CheckAtlasGL('staging allocation');
      glBindTexture(GL_TEXTURE_2D_ARRAY,FTexture[FPart]);
      CheckAtlasGL('upload texture binding');
      glTexSubImage3D(GL_TEXTURE_2D_ARRAY,FLevel,0,FRow,FLayer,Size,Rows,1,GL_RGBA,GL_UNSIGNED_BYTE,nil);
      CheckAtlasGL('mip transfer');
      Inc(VegetationAtlasUploadBytes,Bytes);
      FSlots[Slot].Fence:=glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE,0);
      CheckAtlasGL('staging fence creation');
      FSlots[Slot].Failed:=FSlots[Slot].Fence=nil;
      if FSlots[Slot].Failed then raise EAtlasUpload.Create('Atlas upload fence creation failed');
      Inc(UploadBytes,Bytes);Dec(ByteBudget,Bytes);Inc(FRow,Rows);
      if FRow=Size then begin FRow:=0;Inc(FLayer);end;
      if FLayer=FLevels[FPart][FLevel].Layers then begin FLayer:=0;Inc(FLevel);end;
      if FLevel=Length(FLevels[FPart])then begin FLevel:=0;Inc(FPart);end;
      if(FPart=1)and(Length(FLevels[1])=0)then Inc(FPart);
      if FPart=2 then begin
        FSubmitted:=True;FComplete:=glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE,0);
        CheckAtlasGL('completion fence creation');
        if FComplete=nil then raise EAtlasUpload.Create('Atlas completion fence creation failed');
        Break;
      end;
    end;
  finally
    glBindBuffer(GL_PIXEL_UNPACK_BUFFER,OldPBO);glPixelStorei(GL_UNPACK_ALIGNMENT,OldAlignment);
    for I:=0 to High(State)do glPixelStorei(State[I],OldState[I]);
    glBindTexture(GL_TEXTURE_2D_ARRAY,OldTexture);
  end;
  except FFailed:=True;raise;end;
end;
procedure TAtlasUpload.Take(out Color,Normal:GLuint);
begin
  if FFailed or not FReady then raise EInvalidOp.Create('Incomplete atlas publication');
  Color:=FTexture[0];Normal:=FTexture[1];FTexture[0]:=0;FTexture[1]:=0;
end;
function TAtlasUpload.PendingBytes:Int64;
begin Result:=AtlasLevelBytes(FLevels[0])+AtlasLevelBytes(FLevels[1])+ATLAS_UPLOAD_CHUNK*ATLAS_UPLOAD_SLOTS;end;
function TAtlasUpload.ElapsedSeconds:Single;
begin Result:=(GetTickCount64-FStart)*0.001;end;
end.
