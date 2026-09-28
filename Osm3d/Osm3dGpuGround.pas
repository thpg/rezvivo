unit Osm3dGpuGround;

{$mode objfpc}{$H+}{$Q-}{$R-}

interface

uses Classes, SysUtils, Math, CastleVectors, CastleScene, CastleShapes,
  CastleGL, X3DNodes, Generics.Collections, Osm3dGpuTimer;

type
  TGpuGroundMode = (ggCpu, ggCompare, ggGpu);
  TGroundUInts = array of Cardinal;
  TGroundFloats = array of Single;
  TGroundResult = record
    Height,Lowest:Single;
    Triangle,LowTriangle:Cardinal;
  end;
  TGpuGroundPart = class
  public
    Geometry: TIndexedFaceSetNode; { borrowed, owned by the assembled tile }
    Shape: TShape;                { resolved on the render thread }
    Bins: TGroundUInts;           { CSR headers then triangle IDs; upload once }
    MinX, MinZ, InvX, InvZ: Single;
    VertexCount, TriangleCount, FirstCurb: Cardinal;
    BinCount: Integer;
    Buffer: GLuint;
    BufferBytes: Int64;
    FirstBufferMissFrame: QWord;
    procedure Build(const Geo:TIndexedFaceSetNode; CurbStart:Cardinal);
    function SampleTriangle(T:Cardinal;LX,LZ:Single;out Y:Single):Boolean;
    procedure CloseGpu;
    destructor Destroy; override;
  end;
  TGpuGroundTile = class
  private
    PrepareFrame:QWord;
    PrepareResult:Boolean;
  public
    Parts: specialize TObjectList<TGpuGroundPart>;
    Scene: TCastleScene; { borrowed }
    SceneReady:Boolean;
    constructor Create;
    destructor Destroy; override;
    procedure Add(const Geo:TIndexedFaceSetNode; CurbStart:Cardinal);
    procedure CloseGpu;
  end;
  TGpuGroundPatch = class
  public
    Tile: TGpuGroundTile;
    X,Z,ReferenceY:Single;
    Curbs,Ready,Pending:Boolean;
    Used,ReadyFrame:QWord;
    Heights:TGroundFloats;
    Triangles:TGroundUInts;
  end;
  TGpuGroundJob = record
    Buffer:GLuint;
    Timer:TGpuTimestampPair;
    Fence:GLsync;
    Patch:TGpuGroundPatch;
  end;
  TOsmGpuGround = class
  private
    FTiles:specialize TList<TGpuGroundTile>;
    FPatches:specialize TObjectList<TGpuGroundPatch>;
    FJobs:array[0..2]of TGpuGroundJob;
    FReadback:array of TGroundResult;
    FProgram:GLuint;
    FUniforms:array[0..7]of GLint;
    FError,FStage:string;
    FClock,FFrame,FHits,FMisses,FSubmitted,FCompleted,FCompared,FRenderCalls:QWord;
    FErrorMax,FErrorSum,FRenderMs:Double;
    FGpuMs,FGpuMaxMs,FRenderTotalMs,FRenderMaxMs:Double;
    FOver2cm:QWord;
    FPreparedShapes:QWord;
    FPrepareMs,FPrepareMaxMs:Double;
    FEdges,FEdgeMisses:QWord;
    procedure ContextClose(Sender:TObject);
    procedure EnsureProgram;
    function PrepareTile(Tile:TGpuGroundTile;var PrepareBudget:Integer):Boolean;
    function SampleFallback(Tile:TGpuGroundTile; LX,LZ,ReferenceY:Single;
      Curbs:Boolean; out Y:Single):Boolean;
    function ResolveEdge(P:TGpuGroundPatch;X,Z:Integer;
      LX,LZ,ReferenceY:Single;out Y:Single):Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure AddTile(Tile:TGpuGroundTile; Scene:TCastleScene);
    procedure RemoveTile(Tile:TGpuGroundTile);
    function Sample(Tile:TGpuGroundTile; LX,LZ,ReferenceY:Single;
      Curbs:Boolean; out Y:Single):Boolean;
    procedure Compare(const CpuY,GpuY:Single);
    procedure Render;
    function Info:string;
  end;

var GpuGroundMode:TGpuGroundMode=ggGpu;
function GpuGroundModeName:string;

implementation

uses CastleApplicationProperties, CastleInternalRenderer, CastleLog, CastleTimeUtils,
  CastleRenderContext, CastleGLShaders;

const
  MaxBinN=512;
  PatchN=256;
  PatchSize=4.0;
  PatchStep=PatchSize/PatchN;
  MaxPatches=32;
  NoHeight=1.0e30;

procedure TGpuGroundPart.Build(const Geo:TIndexedFaceSetNode; CurbStart:Cardinal);
var Coord:TCoordinateNode; Counts,Cursor:TGroundUInts;
    I,J,K,X,Z,X0,X1,Z0,Z1,Count:Integer; A,B,C:TVector3;
    MaxX,MaxZ:Single;
  procedure Bounds(T:Integer);
  begin
    A:=Coord.FdPoint.Items[Geo.FdCoordIndex.Items[T*4]];
    B:=Coord.FdPoint.Items[Geo.FdCoordIndex.Items[T*4+1]];
    C:=Coord.FdPoint.Items[Geo.FdCoordIndex.Items[T*4+2]];
    X0:=EnsureRange(Floor((Min(A.X,Min(B.X,C.X))-MinX)*InvX),0,BinCount-1);
    X1:=EnsureRange(Floor((Max(A.X,Max(B.X,C.X))-MinX)*InvX),0,BinCount-1);
    Z0:=EnsureRange(Floor((Min(A.Z,Min(B.Z,C.Z))-MinZ)*InvZ),0,BinCount-1);
    Z1:=EnsureRange(Floor((Max(A.Z,Max(B.Z,C.Z))-MinZ)*InvZ),0,BinCount-1);
  end;
begin
  Geometry:=Geo; FirstCurb:=CurbStart;
  if not(Geo.Coord is TCoordinateNode) then raise Exception.Create('GPU ground: coordinate type');
  Coord:=TCoordinateNode(Geo.Coord);VertexCount:=Coord.FdPoint.Count;
  if (VertexCount=0)or(Geo.FdCoordIndex.Count mod 4<>0) then raise Exception.Create('GPU ground: triangle layout');
  TriangleCount:=Geo.FdCoordIndex.Count div 4;
  { Bin size affects only candidate selection, never contact precision.
    Small mesh parts no longer allocate 2 MiB of empty headers each. }
  BinCount:=32;
  while (BinCount<MaxBinN) and (Int64(BinCount)*BinCount<Int64(TriangleCount)*2) do
    BinCount:=BinCount*2;
  A:=Coord.FdPoint.Items[0];MinX:=A.X;MaxX:=A.X;MinZ:=A.Z;MaxZ:=A.Z;
  for I:=1 to VertexCount-1 do begin
    A:=Coord.FdPoint.Items[I];MinX:=Min(MinX,A.X);MaxX:=Max(MaxX,A.X);
    MinZ:=Min(MinZ,A.Z);MaxZ:=Max(MaxZ,A.Z);
  end;
  InvX:=BinCount/Max(0.01,MaxX-MinX);InvZ:=BinCount/Max(0.01,MaxZ-MinZ);
  SetLength(Counts,BinCount*BinCount);
  for I:=0 to TriangleCount-1 do begin
    if Geo.FdCoordIndex.Items[I*4+3]<>-1 then raise Exception.Create('GPU ground: non-triangle');
    for J:=0 to 2 do if (Geo.FdCoordIndex.Items[I*4+J]<0) or
      (Cardinal(Geo.FdCoordIndex.Items[I*4+J])>=VertexCount) then raise Exception.Create('GPU ground: invalid index');
    Bounds(I);
    for Z:=Z0 to Z1 do for X:=X0 to X1 do Inc(Counts[Z*BinCount+X]);
  end;
  Count:=BinCount*BinCount*2;
  for I:=0 to High(Counts) do Inc(Count,Counts[I]);
  SetLength(Bins,Count);SetLength(Cursor,Length(Counts));K:=BinCount*BinCount*2;
  for I:=0 to High(Counts) do begin
    Bins[I*2]:=K;Bins[I*2+1]:=Counts[I];Cursor[I]:=K;Inc(K,Counts[I]);
  end;
  for I:=0 to TriangleCount-1 do begin
    Bounds(I);
    for Z:=Z0 to Z1 do for X:=X0 to X1 do begin
      K:=Z*BinCount+X;Bins[Cursor[K]]:=I;Inc(Cursor[K]);
    end;
  end;
  BufferBytes:=Int64(Length(Bins))*4;
end;

function TGpuGroundPart.SampleTriangle(T:Cardinal;LX,LZ:Single;out Y:Single):Boolean;
var Coord:TCoordinateNode;A,B,C:TVector3;D,W0,W1,W2,Tol:Single;
begin
  Result:=False;Y:=0;
  if T>=TriangleCount then Exit;
  Coord:=TCoordinateNode(Geometry.Coord);
  A:=Coord.FdPoint.Items[Geometry.FdCoordIndex.Items[T*4]];
  B:=Coord.FdPoint.Items[Geometry.FdCoordIndex.Items[T*4+1]];
  C:=Coord.FdPoint.Items[Geometry.FdCoordIndex.Items[T*4+2]];
  D:=(B.Z-C.Z)*(A.X-C.X)+(C.X-B.X)*(A.Z-C.Z);
  if Abs(D)<1e-9 then Exit;
  W0:=((B.Z-C.Z)*(LX-C.X)+(C.X-B.X)*(LZ-C.Z))/D;
  W1:=((C.Z-A.Z)*(LX-C.X)+(A.X-C.X)*(LZ-C.Z))/D;W2:=1-W0-W1;
  if T>=FirstCurb then Tol:=0.00001 else Tol:=0.001;
  if Min(W0,Min(W1,W2))< -Tol then Exit;
  Y:=A.Y*W0+B.Y*W1+C.Y*W2;Result:=True;
end;

procedure TGpuGroundPart.CloseGpu;
begin
  if Buffer<>0 then glDeleteBuffers(1,@Buffer);
  Buffer:=0;Shape:=nil;FirstBufferMissFrame:=0;
end;
destructor TGpuGroundPart.Destroy;
begin CloseGpu;inherited end;
constructor TGpuGroundTile.Create;
begin inherited;Parts:=specialize TObjectList<TGpuGroundPart>.Create(True) end;
destructor TGpuGroundTile.Destroy;
begin Parts.Free;inherited end;
procedure TGpuGroundTile.Add(const Geo:TIndexedFaceSetNode; CurbStart:Cardinal);
var P:TGpuGroundPart;
begin
  P:=TGpuGroundPart.Create;
  try P.Build(Geo,CurbStart);Parts.Add(P) except P.Free;raise end;
end;
procedure TGpuGroundTile.CloseGpu;
var P:TGpuGroundPart;
begin PrepareFrame:=0;PrepareResult:=False;for P in Parts do P.CloseGpu end;

constructor TOsmGpuGround.Create;
begin
  inherited;FTiles:=specialize TList<TGpuGroundTile>.Create;
  FPatches:=specialize TObjectList<TGpuGroundPatch>.Create(True);
  ApplicationProperties.OnGLContextCloseObject.Add(@ContextClose);
end;
destructor TOsmGpuGround.Destroy;
begin
  ApplicationProperties.OnGLContextCloseObject.Remove(@ContextClose);
  ContextClose(nil);FPatches.Free;FTiles.Free;inherited;
end;
procedure TOsmGpuGround.ContextClose(Sender:TObject);
var I:Integer;T:TGpuGroundTile;
begin
  for I:=0 to High(FJobs) do begin
    if FJobs[I].Fence<>nil then glDeleteSync(FJobs[I].Fence);
    if FJobs[I].Buffer<>0 then glDeleteBuffers(1,@FJobs[I].Buffer);
    GpuTimestampFree(FJobs[I].Timer);
    FillChar(FJobs[I],SizeOf(FJobs[I]),0);
  end;
  for T in FTiles do T.CloseGpu;
  FPatches.Clear;FReadback:=nil;
  if FProgram<>0 then glDeleteProgram(FProgram);FProgram:=0;FError:='';
end;
procedure TOsmGpuGround.AddTile(Tile:TGpuGroundTile; Scene:TCastleScene);
begin Tile.Scene:=Scene;FTiles.Add(Tile) end;
procedure TOsmGpuGround.RemoveTile(Tile:TGpuGroundTile);
var I,J:Integer;
begin
  for I:=FPatches.Count-1 downto 0 do if FPatches[I].Tile=Tile then begin
    for J:=0 to High(FJobs) do if FJobs[J].Patch=FPatches[I] then begin
      { GL retains queued resource references until the dispatch has finished. }
      if FJobs[J].Fence<>nil then glDeleteSync(FJobs[J].Fence);
      if FJobs[J].Buffer<>0 then glDeleteBuffers(1,@FJobs[J].Buffer);
      GpuTimestampFree(FJobs[J].Timer);
      FillChar(FJobs[J],SizeOf(FJobs[J]),0);
    end;
    FPatches.Delete(I);
  end;
  FTiles.Remove(Tile);
end;

function TOsmGpuGround.SampleFallback(Tile:TGpuGroundTile; LX,LZ,ReferenceY:Single;
  Curbs:Boolean; out Y:Single):Boolean;
var P:TGpuGroundPart;X,Z,H,K,T:Integer;V,Lowest,Highest:Single;
begin
  { A failed/unsupported GPU must not remove wheel contact. Read the existing
    scene coordinates, reconstructing just the spatial index when necessary. }
  Y:=0;Lowest:=NoHeight;Highest:=-NoHeight;
  for P in Tile.Parts do begin
    if Length(P.Bins)=0 then P.Build(P.Geometry,P.FirstCurb);
    X:=Floor((LX-P.MinX)*P.InvX);Z:=Floor((LZ-P.MinZ)*P.InvZ);
    if(X<0)or(Z<0)or(X>=P.BinCount)or(Z>=P.BinCount)then Continue;
    H:=(Z*P.BinCount+X)*2;
    for K:=0 to Integer(P.Bins[H+1])-1 do begin
      T:=P.Bins[P.Bins[H]+K];
      if(Cardinal(T)>=P.FirstCurb)and not Curbs then Continue;
      if not P.SampleTriangle(T,LX,LZ,V)then Continue;
      Lowest:=Min(Lowest,V);
      if V<=ReferenceY+0.75 then Highest:=Max(Highest,V);
    end;
  end;
  Result:=Lowest<1e19;
  if Result then if Highest> -1e19 then Y:=Highest else Y:=Lowest;
end;

function TOsmGpuGround.ResolveEdge(P:TGpuGroundPatch;X,Z:Integer;
  LX,LZ,ReferenceY:Single;out Y:Single):Boolean;
var Seen:array[0..24]of Cardinal;N,I,XX,ZZ:Integer;Id,T:Cardinal;
    Part:TGpuGroundPart;V,Lowest,Highest:Single;Duplicate:Boolean;
begin
  Inc(FEdges);N:=0;FillChar(Seen,SizeOf(Seen),0);Lowest:=NoHeight;Highest:=-NoHeight;Y:=0;
  { GPU already found the surfaces. Only check their exact edge containment;
    coordinates are borrowed from the rendered scene, never copied. }
  for ZZ:=Max(0,Z-2)to Min(PatchN-1,Z+2)do
    for XX:=Max(0,X-2)to Min(PatchN-1,X+2)do begin
      Id:=P.Triangles[ZZ*PatchN+XX];if Id=High(Cardinal)then Continue;
      Duplicate:=False;
      for I:=0 to N-1 do if Seen[I]=Id then begin Duplicate:=True;Break end;
      if Duplicate then Continue;Seen[N]:=Id;Inc(N);T:=Id;
      for Part in P.Tile.Parts do begin
        if T<Part.TriangleCount then begin
          if Part.SampleTriangle(T,LX,LZ,V)then begin
            Lowest:=Min(Lowest,V);
            if V<=ReferenceY+0.75 then Highest:=Max(Highest,V);
          end;
          Break;
        end;
        Dec(T,Part.TriangleCount);
      end;
    end;
  Result:=Lowest<1e19;
  if Result then begin
    if Highest> -1e19 then Y:=Highest else Y:=Lowest;
  end else Inc(FEdgeMisses);
end;

function TOsmGpuGround.Sample(Tile:TGpuGroundTile; LX,LZ,ReferenceY:Single;
  Curbs:Boolean; out Y:Single):Boolean;
var P,Best:TGpuGroundPatch; I,X,Z,Old:Integer; DX,DZ,V00,V10,V01,V11:Single;
begin
  Result:=False;Y:=0;Inc(FClock);Best:=nil;
  if (Tile=nil)or(Tile.Parts.Count=0) then Exit;
  if FError<>'' then Exit(SampleFallback(Tile,LX,LZ,ReferenceY,Curbs,Y));
  for P in FPatches do
    if (P.Tile=Tile)and(P.Curbs=Curbs)and
       ((Abs(P.ReferenceY-ReferenceY)<0.25)or((P.ReferenceY>1e19)and(ReferenceY>1e19)))and
       (LX>=P.X+0.25)and(LX<P.X+PatchSize-0.25)and
       (LZ>=P.Z+0.25)and(LZ<P.Z+PatchSize-0.25) then begin Best:=P;Break end;
  if Best=nil then begin
    if FPatches.Count>=MaxPatches then begin
      Old:=-1;
      { Keep queued requests until they have a result. Startup can probe 80
        route points in one Update; evicting unsent requests starves them all. }
      for I:=0 to FPatches.Count-1 do
        if FPatches[I].Ready and(FPatches[I].ReadyFrame<FFrame)then
        if (Old<0)or(FPatches[I].Used<FPatches[Old].Used) then Old:=I;
      if Old<0 then begin Inc(FMisses);Exit end;
      FPatches.Delete(Old);
    end;
    Best:=TGpuGroundPatch.Create;Best.Tile:=Tile;Best.ReferenceY:=ReferenceY;Best.Curbs:=Curbs;
    Best.X:=Floor(LX/2)*2-1;Best.Z:=Floor(LZ/2)*2-1;FPatches.Add(Best);
  end;
  Best.Used:=FClock;
  if not Best.Ready then begin Inc(FMisses);Exit end;
  DX:=(LX-Best.X)/PatchStep-0.5;DZ:=(LZ-Best.Z)/PatchStep-0.5;
  X:=EnsureRange(Floor(DX),0,PatchN-2);Z:=EnsureRange(Floor(DZ),0,PatchN-2);
  DX:=EnsureRange(DX-X,0.0,1.0);DZ:=EnsureRange(DZ-Z,0.0,1.0);
  V00:=Best.Heights[Z*PatchN+X];V10:=Best.Heights[Z*PatchN+X+1];
  V01:=Best.Heights[(Z+1)*PatchN+X];V11:=Best.Heights[(Z+1)*PatchN+X+1];
  { Interpolate smooth pavement; never smear a 15cm curb into a ramp. }
  if Max(Max(V00,V10),Max(V01,V11))-Min(Min(V00,V10),Min(V01,V11))<0.04 then
    Y:=(V00*(1-DX)+V10*DX)*(1-DZ)+(V01*(1-DX)+V11*DX)*DZ
  else if not ResolveEdge(Best,X,Z,LX,LZ,ReferenceY,Y)then begin
    { A nearby pixel is not proof of contact across a sharp edge or a hole. }
    Inc(FMisses);Exit;
  end;
  Result:=Abs(Y)<1e19;
  if Result then Inc(FHits) else Inc(FMisses);
end;
procedure TOsmGpuGround.Compare(const CpuY,GpuY:Single);
var D:Double;
begin
  D:=Abs(CpuY-GpuY);Inc(FCompared);FErrorSum:=FErrorSum+D;FErrorMax:=Max(FErrorMax,D);
  if D>0.02 then Inc(FOver2cm);
end;

procedure TOsmGpuGround.EnsureProgram;
const Names:array[0..7]of PChar=('uPatch','uCurbs','uBounds','uStride',
    'uFirstCurb','uTriangleBase','uInit','uBinCount');
var S:GLuint;P:PChar;Source:AnsiString;Ok,L,I:GLint;Msg:AnsiString;
begin
  if FProgram<>0 then Exit;
  if not Assigned(glDispatchCompute) or not Assigned(glFenceSync) then
    raise Exception.Create('OpenGL compute/sync unavailable');
  Source:={$I shaders/gpu_ground.glsl.inc};
  S:=glCreateShader(GL_COMPUTE_SHADER);
  try
    P:=PChar(Source);glShaderSource(S,1,@P,nil);glCompileShader(S);glGetShaderiv(S,GL_COMPILE_STATUS,@Ok);
    if Ok=0 then begin
      glGetShaderiv(S,GL_INFO_LOG_LENGTH,@L);SetLength(Msg,Max(1,L));glGetShaderInfoLog(S,L,nil,PChar(Msg));
      raise Exception.Create('GPU ground compile: '+Msg);
    end;
    FProgram:=glCreateProgram();glAttachShader(FProgram,S);glLinkProgram(FProgram);
    glGetProgramiv(FProgram,GL_LINK_STATUS,@Ok);
    if Ok=0 then begin
      glGetProgramiv(FProgram,GL_INFO_LOG_LENGTH,@L);SetLength(Msg,Max(1,L));glGetProgramInfoLog(FProgram,L,nil,PChar(Msg));
      glDeleteProgram(FProgram);FProgram:=0;raise Exception.Create('GPU ground link: '+Msg);
    end;
    for I:=0 to High(FUniforms)do FUniforms[I]:=glGetUniformLocation(FProgram,Names[I]);
  finally glDeleteShader(S) end;
end;

function TOsmGpuGround.PrepareTile(Tile:TGpuGroundTile;var PrepareBudget:Integer):Boolean;
var P:TGpuGroundPart;Sh:TShape;VB,IB:GLuint;Stride,VC,IC:Cardinal;
    Started:TTimerResult;Ms:Double;AllReady:Boolean;
begin
  FStage:='prepare scene';
  if Tile.PrepareFrame=FFrame then Exit(Tile.PrepareResult);
  Tile.PrepareFrame:=FFrame;Tile.PrepareResult:=False;
  Result:=False;if not Tile.SceneReady or(Tile.Scene=nil)or(Tile.Scene.Shapes=nil) then Exit;
  AllReady:=True;
  for P in Tile.Parts do begin
    FStage:='find shape';
    { Scene mount/ChangedAll may replace TShape without replacing its X3D node.
      Resolve the borrowed renderer object anew before each dispatch. }
    P.Shape:=nil;
    for Sh in Tile.Scene.Shapes.TraverseList(False,False) do
      if Sh.Geometry=P.Geometry then begin P.Shape:=Sh;Break end;
    FStage:='shape buffers';
    if not(P.Shape is TX3DRendererShape) then begin AllReady:=False;Continue end;
    if not TX3DRendererShape(P.Shape).SurfaceQueryBuffers(VB,IB,Stride,VC,IC) then begin
      { The normal world render follows this query pass. Give it two frames to
        prepare visible surfaces, avoiding two array builds in their first frame.
        Focus or culled surfaces still receive bounded demand preparation. }
      if P.FirstBufferMissFrame=0 then P.FirstBufferMissFrame:=FFrame;
      if (FFrame-P.FirstBufferMissFrame<2)or(PrepareBudget=0) then begin
        AllReady:=False;Continue;
      end;
      { Focus does not draw the world. Prepare only requested surface parts,
        in the scene's existing cache, at most one cold shape per frame. }
      Dec(PrepareBudget);Started:=Timer;
      if not TX3DRendererShape(P.Shape).PrepareSurfaceQueryBuffers(Tile.Scene.RenderOptions) then
        raise Exception.Create('GPU ground: unsupported surface buffer layout');
      Ms:=Started.ElapsedTime*1000;Inc(FPreparedShapes);
      FPrepareMs:=FPrepareMs+Ms;FPrepareMaxMs:=Max(FPrepareMaxMs,Ms);
      if Ms>100 then WritelnLog('GPU ground','Surface VBO preparation %.1f ms: %s',[Ms,P.Shape.NiceName]);
      if not TX3DRendererShape(P.Shape).SurfaceQueryBuffers(VB,IB,Stride,VC,IC) then Exit;
    end;
    P.FirstBufferMissFrame:=0;
    if(VC<>P.VertexCount)or(IC<>P.TriangleCount*3) then
      raise Exception.Create('GPU ground: renderer changed topology');
    if P.Buffer=0 then begin
      FStage:='upload bins';
      { After context loss the X3D geometry still exists; reconstruct only CSR. }
      if Length(P.Bins)=0 then P.Build(P.Geometry,P.FirstCurb);
      glGenBuffers(1,@P.Buffer);glBindBuffer(GL_SHADER_STORAGE_BUFFER,P.Buffer);
      glBufferData(GL_SHADER_STORAGE_BUFFER,P.BufferBytes,@P.Bins[0],GL_STATIC_DRAW);
      P.Bins:=nil;
    end;
  end;
  Result:=AllReady and(Tile.Parts.Count>0);
  Tile.PrepareResult:=Result;
end;

procedure TOsmGpuGround.Render;
var I,J,K,Slot,Init,PrepareBudget:Integer;P:TGpuGroundPatch;Part:TGpuGroundPart;
    Status:GLenum;OldProgram:TGLSLProgram;HasWork:Boolean;
    VB,IB:GLuint;Stride,VC,IC,TriangleBase:Cardinal;GpuNs:QWord;T0:TTimerResult;
begin
  Inc(FFrame);
  FRenderMs:=0;
  if(FError<>'')or(FPatches.Count=0)then Exit;
  HasWork:=False;
  for P in FPatches do if not P.Ready then begin HasWork:=True;Break end;
  if not HasWork then Exit;
  if not Assigned(glDispatchCompute)or not Assigned(glFenceSync) then begin
    FError:='OpenGL 4.3 compute required';Exit;
  end;
  T0:=Timer;
  { Called before scene rendering. All custom renderers restore the CGE
    program; reading its CPU cache avoids a driver-thread round trip.
    SSBO slots 0..3 are exclusively owned by this pass in REZVIVO/CGE. }
  OldProgram:=RenderContext.CurrentProgram;
  try
    try
      FStage:='program';EnsureProgram;PrepareBudget:=1;
      for I:=0 to High(FJobs) do if FJobs[I].Fence<>nil then begin
        Status:=glClientWaitSync(FJobs[I].Fence,0,0); { never wait on GPU }
        if(Status=GL_ALREADY_SIGNALED)or(Status=GL_CONDITION_SATISFIED)then begin
          P:=FJobs[I].Patch;SetLength(FReadback,PatchN*PatchN);
          glBindBuffer(GL_SHADER_STORAGE_BUFFER,FJobs[I].Buffer);
          glGetBufferSubData(GL_SHADER_STORAGE_BUFFER,0,Length(FReadback)*SizeOf(TGroundResult),@FReadback[0]);
          SetLength(P.Heights,PatchN*PatchN);
          SetLength(P.Triangles,PatchN*PatchN);
          for K:=0 to High(P.Heights) do
            if FReadback[K].Height> -1e19 then begin
              P.Heights[K]:=FReadback[K].Height;P.Triangles[K]:=FReadback[K].Triangle;
            end else begin
              P.Heights[K]:=FReadback[K].Lowest;P.Triangles[K]:=FReadback[K].LowTriangle;
            end;
          P.Ready:=True;P.ReadyFrame:=FFrame;P.Pending:=False;Inc(FCompleted);
          if GpuTimestampRead(FJobs[I].Timer,GpuNs) then
          begin FGpuMs:=FGpuMs+GpuNs/1e6;FGpuMaxMs:=Max(FGpuMaxMs,GpuNs/1e6) end;
          glDeleteSync(FJobs[I].Fence);FJobs[I].Fence:=nil;FJobs[I].Patch:=nil;
        end else if Status=GL_WAIT_FAILED then raise Exception.Create('GPU ground fence failed');
      end;
      { At most two patches per frame; static terrain caches survive movement. }
      for J:=0 to 1 do begin
        Slot:=-1;for I:=0 to High(FJobs)do if FJobs[I].Fence=nil then begin Slot:=I;Break end;
        if Slot<0 then Break;
        P:=nil;
        for I:=0 to FPatches.Count-1 do
          if not FPatches[I].Ready and not FPatches[I].Pending and
             ((P=nil)or(FPatches[I].Used<P.Used)) then
            { One tile awaiting VBO preparation must not block other tiles. }
            if PrepareTile(FPatches[I].Tile,PrepareBudget)then P:=FPatches[I];
        if P=nil then Break;
        if FJobs[Slot].Buffer=0 then begin
          glGenBuffers(1,@FJobs[Slot].Buffer);glBindBuffer(GL_SHADER_STORAGE_BUFFER,FJobs[Slot].Buffer);
          glBufferData(GL_SHADER_STORAGE_BUFFER,PatchN*PatchN*SizeOf(TGroundResult),nil,GL_STREAM_READ);
        end;
        FStage:='dispatch uniforms';
        glUseProgram(FProgram);glBindBufferBase(GL_SHADER_STORAGE_BUFFER,3,FJobs[Slot].Buffer);
        glUniform4f(FUniforms[0],P.X,P.Z,PatchStep,P.ReferenceY);
        glUniform1i(FUniforms[1],Ord(P.Curbs));Init:=1;TriangleBase:=0;
        GpuTimestampBegin(FJobs[Slot].Timer);
        try
        for Part in P.Tile.Parts do begin
          if not TX3DRendererShape(Part.Shape).SurfaceQueryBuffers(VB,IB,Stride,VC,IC) then
            raise Exception.Create('GPU ground: buffers invalidated during dispatch');
          glBindBufferBase(GL_SHADER_STORAGE_BUFFER,0,VB);
          glBindBufferBase(GL_SHADER_STORAGE_BUFFER,1,IB);
          glBindBufferBase(GL_SHADER_STORAGE_BUFFER,2,Part.Buffer);
          glUniform4f(FUniforms[2],Part.MinX,Part.MinZ,Part.InvX,Part.InvZ);
          glUniform1ui(FUniforms[7],Part.BinCount);
          glUniform1ui(FUniforms[3],Stride div 4);glUniform1ui(FUniforms[4],Part.FirstCurb);
          glUniform1ui(FUniforms[5],TriangleBase);Inc(TriangleBase,Part.TriangleCount);
          glUniform1i(FUniforms[6],Init);glDispatchCompute(PatchN div 8,PatchN div 8,1);
          glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT);Init:=0;
        end;
        finally GpuTimestampEnd(FJobs[Slot].Timer) end;
        glMemoryBarrier(GL_BUFFER_UPDATE_BARRIER_BIT);
        FJobs[Slot].Fence:=glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE,0);FJobs[Slot].Patch:=P;
        if FJobs[Slot].Fence=nil then raise Exception.Create('GPU ground fence allocation failed');
        P.Pending:=True;Inc(FSubmitted);
      end;
    except on E:Exception do begin
      FError:=FStage+': '+E.Message+' at 0x'+HexStr(PtrUInt(ExceptAddr),16);
      WritelnWarning('GPU ground',FError);
    end end;
  finally
    InternalSetCurrentProgram(OldProgram);
    for I:=0 to 3 do glBindBufferBase(GL_SHADER_STORAGE_BUFFER,I,0);
    glBindBuffer(GL_SHADER_STORAGE_BUFFER,0);
    FRenderMs:=T0.ElapsedTime*1000;Inc(FRenderCalls);
    FRenderTotalMs:=FRenderTotalMs+FRenderMs;FRenderMaxMs:=Max(FRenderMaxMs,FRenderMs);
  end;
end;
function TOsmGpuGround.Info:string;
var T:TGpuGroundTile;P:TGpuGroundPart;C:TGpuGroundPatch;Cpu,Gpu:Int64;
begin
  Cpu:=Length(FReadback)*SizeOf(TGroundResult);Gpu:=0;
  for T in FTiles do for P in T.Parts do begin
    Inc(Cpu,Int64(Length(P.Bins))*4);if P.Buffer<>0 then Inc(Gpu,P.BufferBytes);
  end;
  for C in FPatches do Inc(Cpu,(Length(C.Heights)+Length(C.Triangles))*4);
  Result:=Format('mode=%s tiles=%d patches=%d hits=%d misses=%d submitted=%d completed=%d cpu_bytes=%d gpu_index_bytes=%d compared=%d mean_error_m=%.6f max_error_m=%.6f over_2cm=%d edges=%d edge_misses=%d render_ms=%.3f render_mean_ms=%.3f render_max_ms=%.3f gpu_mean_ms=%.3f gpu_max_ms=%.3f prepared_shapes=%d prepare_total_ms=%.3f prepare_max_ms=%.3f error=%s',
    [GpuGroundModeName,FTiles.Count,FPatches.Count,FHits,FMisses,FSubmitted,FCompleted,Cpu,Gpu,FCompared,
    FErrorSum/Max(1,FCompared),FErrorMax,FOver2cm,FEdges,FEdgeMisses,FRenderMs,FRenderTotalMs/Max(1,FRenderCalls),FRenderMaxMs,FGpuMs/Max(1,FCompleted),FGpuMaxMs,FPreparedShapes,FPrepareMs,FPrepareMaxMs,FError]);
end;
function GpuGroundModeName:string;
const Names:array[TGpuGroundMode]of string=('cpu','compare','gpu');
begin Result:=Names[GpuGroundMode] end;
procedure ReadMode;
var I:Integer;S:string;
begin
  S:=LowerCase(GetEnvironmentVariable('REZVIVO_GPU_GROUND'));
  for I:=1 to ParamCount do begin
    if ParamStr(I)='--gpu-ground' then S:='gpu';
    if ParamStr(I)='--gpu-ground-compare' then S:='compare';
    if ParamStr(I)='--cpu-ground' then S:='cpu';
  end;
  if(S='gpu')or(S='1')then GpuGroundMode:=ggGpu
  else if S='compare' then GpuGroundMode:=ggCompare
  else if S='cpu' then GpuGroundMode:=ggCpu;
end;
initialization ReadMode;
end.
