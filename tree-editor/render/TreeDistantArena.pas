unit TreeDistantArena;
{$mode objfpc}{$H+}
{$ifdef ANDROID}{$define OpenGLES}{$endif}
interface
uses SysUtils,Math,Generics.Collections,TreeMath,TreeModel,TreeGPUData,{$ifdef OpenGLES}CastleGLES{$else}GL,GLExt{$endif};
type
  ETreeArenaUpload=class(Exception);
  TTreeCellIDs=array of Int64;
  TTreeArenaRange=record ID:Int64;Version:QWord;Origin:TTreeWorldPosition;First,Count:Integer;end;
  TTreeArenaCommand=packed record Vertices,Instances,First,Base:LongWord;end;
  TTreeArena=class
  private
    FBuffer,FVAO,FCommands:GLuint;
    FCapacity,FUsed:Integer;
    FRanges:array of TTreeArenaRange;
    FSlots:specialize TDictionary<Int64,Integer>;
    FFree:array of record First,Count:Integer;Fence:GLsync;Failed:Boolean;end;
    FDraws:array of TTreeArenaCommand;
    FDrawCount,FVisibleCount:Integer;
    FMulti:Pointer;
    FBase:Pointer;
    function Allocate(Count:Integer):Integer;
    procedure Retire(First,Count:Integer);
    procedure BindOffset(First:Integer);
  public
    UploadBytes,Reuses,Allocations,Retirements:QWord;
    constructor Create;
    destructor Destroy;override;
    procedure Ensure(ID:Int64;Version:QWord;const Origin:TTreeWorldPosition;const Items:TTreeGPUItems);
    procedure Remove(ID:Int64);
    procedure Select(const IDs:TTreeCellIDs;Count:Integer);
    function Draw(Vertices:Integer):Integer;
    function MemoryBytes:Int64;
    property VisibleCount:Integer read FVisibleCount;
  end;
var TreeArenaDiagnosticRawDraw:procedure;
implementation
uses VegetationRenderOptions;
const
  TREE_DRAW_INDIRECT_BUFFER=$8F3F;
  TREE_DRAW_INDIRECT_BUFFER_BINDING=$8F43;
type
  TMultiDraw=procedure(Mode:GLenum;Indirect:Pointer;Count,Stride:GLsizei);{$ifdef Windows}stdcall{$else}cdecl{$endif};
  TBaseDraw=procedure(Mode:GLenum;First:GLint;Count,Instances:GLsizei;Base:GLuint);{$ifdef Windows}stdcall{$else}cdecl{$endif};
procedure CheckArenaGL(const Operation:string);
var Code:GLenum;
begin
  Code:=glGetError();
  if Code<>GL_NO_ERROR then raise ETreeArenaUpload.CreateFmt('Tree arena %s failed (GL $%x)',[Operation,Code]);
end;
procedure ClearArenaErrors;
var I:Integer;
begin
  for I:=0 to 15 do if glGetError()=GL_NO_ERROR then Exit;
  raise ETreeArenaUpload.Create('Tree arena GL error state did not clear');
end;
constructor TTreeArena.Create;
var Major,Minor:GLint;
begin
  inherited;FSlots:=specialize TDictionary<Int64,Integer>.Create;
  ClearArenaErrors;
  glGenVertexArrays(1,@FVAO);glGenBuffers(1,@FBuffer);glGenBuffers(1,@FCommands);
  CheckArenaGL('resource creation');
  if(FVAO=0)or(FBuffer=0)or(FCommands=0)then raise ETreeArenaUpload.Create('Tree arena resource name is zero');
  {$ifdef MSWINDOWS}{$ifndef OpenGLES}
  glGetIntegerv(GL_MAJOR_VERSION,@Major);glGetIntegerv(GL_MINOR_VERSION,@Minor);
  if(Major>4)or((Major=4)and(Minor>=2))then FBase:=wglGetProcAddress('glDrawArraysInstancedBaseInstance');
  if(Major>4)or((Major=4)and(Minor>=3))then FMulti:=wglGetProcAddress('glMultiDrawArraysIndirect');
  if(PtrUInt(FBase)<4)or(PtrInt(FBase)=-1)then FBase:=nil;
  if(PtrUInt(FMulti)<4)or(PtrInt(FMulti)=-1)then FMulti:=nil;
  {$endif}{$endif}
end;
destructor TTreeArena.Destroy;
var I:Integer;
begin
  for I:=0 to High(FFree)do if FFree[I].Fence<>nil then glDeleteSync(FFree[I].Fence);
  if FBuffer<>0 then glDeleteBuffers(1,@FBuffer);
  if FCommands<>0 then glDeleteBuffers(1,@FCommands);
  if FVAO<>0 then glDeleteVertexArrays(1,@FVAO);
  FSlots.Free;
  inherited;
end;
procedure TTreeArena.Retire(First,Count:Integer);
var N,I:Integer;
begin
  if Count<=0 then Exit;
  N:=-1;for I:=0 to High(FFree)do if(FFree[I].Count=0)and(FFree[I].Fence=nil)then begin N:=I;Break end;
  if N<0 then begin N:=Length(FFree);SetLength(FFree,N+1)end;
  FFree[N].First:=First;FFree[N].Count:=Count;
  FFree[N].Fence:=glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE,0);
  FFree[N].Failed:=FFree[N].Fence=nil;Inc(Retirements);
end;
function TTreeArena.Allocate(Count:Integer):Integer;
var I,N,Live,Cursor:Integer;Status:GLenum;NewBuffer:GLuint;OldRead,OldWrite:GLint;
begin
  if Count<=0 then Exit(0);
  for I:=0 to High(FFree)do begin
    if not FFree[I].Failed and(FFree[I].Fence<>nil)then begin
      Status:=glClientWaitSync(FFree[I].Fence,0,0);
      if Status=GL_WAIT_FAILED then FFree[I].Failed:=True;
      if(Status=GL_ALREADY_SIGNALED)or(Status=GL_CONDITION_SATISFIED)then begin
        glDeleteSync(FFree[I].Fence);FFree[I].Fence:=nil;
      end;
    end;
    if not FFree[I].Failed and(FFree[I].Fence=nil)and(FFree[I].Count>=Count)then begin
      Result:=FFree[I].First;Inc(FFree[I].First,Count);Dec(FFree[I].Count,Count);Exit;
    end;
  end;
  if FUsed+Count>FCapacity then begin
    { Compact only on allocation pressure. Fragmented/tile-retired holes must
      not make capacity grow forever during a long ride. Ordered GPU copies
      preserve all unchanged descriptors; no CPU repacking or fence wait. }
    Live:=0;for I:=0 to High(FRanges)do Inc(Live,FRanges[I].Count);
    N:=Max(1024,(Live+Count)*2);NewBuffer:=0;
    glGetIntegerv(GL_COPY_READ_BUFFER,@OldRead);glGetIntegerv(GL_COPY_WRITE_BUFFER,@OldWrite);
    CheckArenaGL('copy binding query');
    try
      glGenBuffers(1,@NewBuffer);CheckArenaGL('buffer creation');
      if NewBuffer=0 then raise ETreeArenaUpload.Create('Tree arena buffer name is zero');
      glBindBuffer(GL_COPY_WRITE_BUFFER,NewBuffer);glBufferData(GL_COPY_WRITE_BUFFER,Int64(N)*64,nil,GL_DYNAMIC_DRAW);
      CheckArenaGL('storage allocation');
      Cursor:=0;
      if FCapacity>0 then begin
        glBindBuffer(GL_COPY_READ_BUFFER,FBuffer);
        for I:=0 to High(FRanges)do if FRanges[I].Count>0 then begin
          glCopyBufferSubData(GL_COPY_READ_BUFFER,GL_COPY_WRITE_BUFFER,Int64(FRanges[I].First)*64,Int64(Cursor)*64,Int64(FRanges[I].Count)*64);
          CheckArenaGL('range copy');Inc(Cursor,FRanges[I].Count);
        end;
      end;
      { The old storage and offsets remain authoritative until EVERY copy has
        been accepted. An allocation/copy failure leaves all old cells valid. }
      Cursor:=0;
      for I:=0 to High(FRanges)do if FRanges[I].Count>0 then begin
        FRanges[I].First:=Cursor;Inc(Cursor,FRanges[I].Count);
      end;
      if OldRead=GLint(FBuffer)then OldRead:=NewBuffer;if OldWrite=GLint(FBuffer)then OldWrite:=NewBuffer;
      glDeleteBuffers(1,@FBuffer);FBuffer:=NewBuffer;NewBuffer:=0;FCapacity:=N;FUsed:=Cursor;Inc(Allocations);
      for I:=0 to High(FFree)do if FFree[I].Fence<>nil then glDeleteSync(FFree[I].Fence);
      FFree:=nil;
    finally
      if NewBuffer<>0 then glDeleteBuffers(1,@NewBuffer);
      glBindBuffer(GL_COPY_READ_BUFFER,OldRead);glBindBuffer(GL_COPY_WRITE_BUFFER,OldWrite);
    end;
  end;
  Result:=FUsed;Inc(FUsed,Count);
end;
procedure TTreeArena.Ensure(ID:Int64;Version:QWord;const Origin:TTreeWorldPosition;const Items:TTreeGPUItems);
var I,Slot,N,NewFirst:Integer;PackedItems:TTreeGPUItems;
begin
  if ID<=0 then raise EArgumentException.Create('Tree cell identity must be positive');
  if not FSlots.TryGetValue(ID,Slot)then Slot:=-1;
  if Slot>=0 then begin
    if(Version=FRanges[Slot].Version)and(FRanges[Slot].Count=Length(Items))and
      CompareMem(@Origin,@FRanges[Slot].Origin,SizeOf(Origin))then begin Inc(Reuses);Inc(VegetationArenaHits);Exit end;
  end;
  N:=Length(Items);
  PackedItems:=Copy(Items);
  for I:=0 to N-1 do begin
    { c.x is the stable shadow partition. c.yzw are otherwise unused for
      billboards; keep the exactly representable 128-m cell origin separate. }
    PackedItems[I][9]:=Origin.X;PackedItems[I][10]:=Origin.Y;PackedItems[I][11]:=Origin.Z;
  end;
  ClearArenaErrors;NewFirst:=-1;
  try
    { Keep the previous range live during compaction/upload. Its current
      offset may change during compaction; retire it only after success. }
    NewFirst:=Allocate(N);
    if N>0 then begin
      glBindBuffer(GL_ARRAY_BUFFER,FBuffer);
      glBufferSubData(GL_ARRAY_BUFFER,Int64(NewFirst)*64,Int64(N)*64,@PackedItems[0]);
      CheckArenaGL('descriptor upload');
    end;
    if Slot<0 then begin
      for I:=0 to High(FRanges)do if FRanges[I].ID=0 then begin Slot:=I;Break end;
      if Slot<0 then begin Slot:=Length(FRanges);SetLength(FRanges,Slot+1)end;
      FSlots.Add(ID,Slot);
    end else Retire(FRanges[Slot].First,FRanges[Slot].Count);
    FRanges[Slot].First:=NewFirst;FRanges[Slot].Count:=N;
    FRanges[Slot].ID:=ID;FRanges[Slot].Version:=Version;FRanges[Slot].Origin:=Origin;
    NewFirst:=-1;Inc(UploadBytes,Int64(N)*64);
  except
    if NewFirst>=0 then Retire(NewFirst,N);
    raise;
  end;
end;
procedure TTreeArena.Remove(ID:Int64);
var I:Integer;
begin
  if FSlots.TryGetValue(ID,I)then begin
    Retire(FRanges[I].First,FRanges[I].Count);FRanges[I].ID:=0;FRanges[I].Count:=0;FSlots.Remove(ID);
  end;
end;
procedure TTreeArena.Select(const IDs:TTreeCellIDs;Count:Integer);
var I,J:Integer;
begin
  if Length(FDraws)<Count then SetLength(FDraws,Max(Count,Length(FDraws)*2));
  FDrawCount:=0;FVisibleCount:=0;
  for I:=0 to Count-1 do if FSlots.TryGetValue(IDs[I],J)and(FRanges[J].Count>0)then begin
    with FDraws[FDrawCount]do begin Vertices:=6;Instances:=FRanges[J].Count;First:=0;Base:=FRanges[J].First end;
    Inc(FDrawCount);Inc(FVisibleCount,FRanges[J].Count);
  end;
end;
procedure TTreeArena.BindOffset(First:Integer);
var I:Integer;
begin
  glBindVertexArray(FVAO);glBindBuffer(GL_ARRAY_BUFFER,FBuffer);
  for I:=0 to 3 do begin
    glEnableVertexAttribArray(I);glVertexAttribDivisor(I,1);
    glVertexAttribPointer(I,4,GL_FLOAT,GL_FALSE,64,Pointer(PtrUInt(First)*64+I*16));
  end;
  glEnableVertexAttribArray(4);glVertexAttribDivisor(4,1);
  glVertexAttribIPointer(4,1,GL_UNSIGNED_INT,64,Pointer(PtrUInt(First)*64+52));
end;
function TTreeArena.Draw(Vertices:Integer):Integer;
var I:Integer;OldIndirect:GLint;
begin
  Result:=0;if FDrawCount=0 then Exit;
  BindOffset(0);
  {$ifndef OpenGLES}
  if FMulti<>nil then begin
    for I:=0 to FDrawCount-1 do FDraws[I].Vertices:=Vertices;
    glGetIntegerv(TREE_DRAW_INDIRECT_BUFFER_BINDING,@OldIndirect);
    glBindBuffer(TREE_DRAW_INDIRECT_BUFFER,FCommands);
    glBufferData(TREE_DRAW_INDIRECT_BUFFER,Int64(FDrawCount)*SizeOf(TTreeArenaCommand),@FDraws[0],GL_STREAM_DRAW);
    if glGetError()=GL_NO_ERROR then begin
      if Assigned(TreeArenaDiagnosticRawDraw)then TreeArenaDiagnosticRawDraw;
      TMultiDraw(FMulti)(GL_TRIANGLES,nil,FDrawCount,0);
      glBindBuffer(TREE_DRAW_INDIRECT_BUFFER,OldIndirect);Exit(1);
    end;
    { A failed command allocation has issued no draw. Use exactly the same
      ranges directly, and keep this path disabled for the current arena. }
    glBindBuffer(TREE_DRAW_INDIRECT_BUFFER,OldIndirect);FMulti:=nil;
  end;
  {$endif}
  for I:=0 to FDrawCount-1 do begin
    if FBase<>nil then begin
      if Assigned(TreeArenaDiagnosticRawDraw)then TreeArenaDiagnosticRawDraw;
      TBaseDraw(FBase)(GL_TRIANGLES,0,Vertices,FDraws[I].Instances,FDraws[I].Base)
    end
    else begin BindOffset(FDraws[I].Base);glDrawArraysInstanced(GL_TRIANGLES,0,Vertices,FDraws[I].Instances)end;
    Inc(Result);
  end;
end;
function TTreeArena.MemoryBytes:Int64;
begin Result:=Int64(FCapacity)*64+Int64(FDrawCount)*SizeOf(TTreeArenaCommand);end;
end.
