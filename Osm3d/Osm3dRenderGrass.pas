unit Osm3dRenderGrass;
{$ifdef ANDROID}{$define OpenGLES}{$endif}
{$mode objfpc}{$H+}{$Q-}{$R-}
interface
uses {$IFDEF MSWINDOWS}Windows,{$ENDIF}Classes,SysUtils,Math,SyncObjs,CastleVectors,CastleBoxes,CastleFrustum,
  CastleTransform,CastleRenderContext,{$ifdef OpenGLES}CastleGLES{$else}CastleGL{$endif},Osm3dGeomMesh,GrassModel,GrassRenderer,Osm3dRiderShadow;
type
  { Keep compact surfaces. Generate metre patches only around the camera. }
  TGrassRenderer=class(TCastleTransform)
  private
    FSources,FJobs,FResults:TList;
    FLock:TCriticalSection;
    FEvent:PRTLEvent;
    FWorker:TThread;
    FRenderer:TGrassPatchRenderer;
    FShadowBinding:TGroundShadowGLBinding;
    FBox:TBox3D;
    FNextId:Int64;
    FSun:TVector3;
    FDrawn,FDrawCalls:Integer;
    FCullDistance:Single;
    FError:string;
    FContextHooked:Boolean;
    procedure ContextClose(Sender:TObject);
    procedure AddSource(Mesh:TMesh;const TriMat:array of Integer;CX,CZ:Single);
    procedure RebuildBox;
    procedure Schedule(const Camera:TVector3);
    procedure Drain;
    function PopJob:TObject;
    procedure PushResult(Obj:TObject);
  public
    constructor Create(AOwner:TComponent);override;
    destructor Destroy;override;
    procedure LocalRender(const Params:TRenderParams);override;
    function LocalBoundingBox:TBox3D;override;
    procedure AddTile(Grass:TMesh;const TriMat:array of Integer;ACenterX,ACenterZ:Single);
    procedure EnqueueTile(Grass:TMesh;const TriMat:array of Integer;ACenterX,ACenterZ:Single);
    procedure RemoveTile(ACenterX,ACenterZ:Single);
    procedure ClearTiles;
    class procedure CleanupSharedGL;
    function DiagString:string;
    function OverlapReport:string;
    function MemoryBytesGPU:Int64;
    property SunRayDirection:TVector3 read FSun write FSun;
    property CullDistance:Single read FCullDistance write FCullDistance;
  end;
procedure SetGrassSunDir(const ADir:TVector3);
function GrassMatDensity(MatId:Integer):Single;
implementation
uses Osm3dRtxMaterials,CastleUriUtils,CastleLog,CastleApplicationProperties,Osm3dGroundComposite,Osm3dGlslLib,Osm3dWind,
  Osm3dGpuAccount,Osm3dRenderInstanced,Osm3dStudioSettings,Osm3dVegetationQuality,TreeMath
  {$ifndef OpenGLES},GL,GLExt{$endif}
  {$IFDEF TILE_MEM_PROFILE},Osm3dMemCensus{$ENDIF};
const CELL=GRASS_RENDER_CELL;RADIUS=160;
  GRASS_INDEX_CELL=64;
  GRASS_INDEX_MAX_CELLS=65536;
  GRASS_INDEX_MAX_TRI_CELLS=16;
type
  TGrassTriangle=packed record
    A,B,C:TVector3;Material:Integer;
    UpA,UpB,UpC:Single;
  end;
  TGrassCell=record First,Count,Kind:Integer;Box:TBox3D;end;
  TGrassCells=array of TGrassCell;
  TGrassTriangleIds=array of Integer;
  TGrassSpatialIndex=record
    Ready:Boolean;
    TriangleCount,MinX,MinZ,Width,Height:Integer;
    Step:Single;
    Offsets,TriangleIds,LargeIds:TGrassTriangleIds;
  end;
  TGrassSource=class
    References:LongInt;
    Id:Int64;
    CenterX,CenterZ,LastX,LastZ:Single;
    Pending,Valid:Boolean;
    Box:TBox3D;
    Triangles:array of TGrassTriangle;
    { Built once by the single worker and immutable afterwards. The source's
      job reference also owns this index when a tile is removed by the UI. }
    Spatial:TGrassSpatialIndex;
    Buffer:GLuint;
    PatchCount:Integer;
    CacheRadius:Integer;
    VisitedTriangles:Integer;
    IndexBytes:Int64;
    BufferCapacity:NativeInt;
    Cells:TGrassCells;
    constructor Create;
    procedure Release;
    procedure FreeGPU;
  end;
  TGrassJob=class
    Source:TGrassSource;
    CameraX,CameraZ:Single;
    Radius:Integer;
    destructor Destroy;override;
  end;
  TGrassResult=class
    Id:Int64;
    CameraX,CameraZ:Single;
    Radius:Integer;
    VisitedTriangles:Integer;
    IndexBytes:Int64;
    Patches:TGrassPatches;
    Cells:TGrassCells;
    Error:string;
  end;
  TGrassWorker=class(TThread)
    Owner:TGrassRenderer;
    constructor Create(AOwner:TGrassRenderer);
    procedure Execute;override;
  end;
var SunDirection:TVector3;
procedure SetGrassSunDir(const ADir:TVector3);
begin SunDirection:=ADir;end;
function GrassMatDensity(MatId:Integer):Single;
var I:Integer;
begin
  { Explicit species for authored worlds; ordinary OSM material IDs stay intact. }
  if(MatId>=GROUND_MAT_COUNT)and(MatId<GROUND_MAT_COUNT+GRASS_SPECIES_COUNT)then Exit(1);
  Result:=0;if(MatId<0)or(MatId>=GROUND_MAT_COUNT)then Exit;
  for I:=0 to High(GROUND_MATERIALS[MatId].Grasses) do Result:=Result+GROUND_MATERIALS[MatId].Grasses[I].Frequency;
end;
function PickKind(Mat:Integer;Seed:LongWord):Integer;
var I:Integer;V:Single;
begin
  if(Mat>=GROUND_MAT_COUNT)and(Mat<GROUND_MAT_COUNT+GRASS_SPECIES_COUNT)then Exit(Mat-GROUND_MAT_COUNT);
  Result:=4;V:=GrassMatDensity(Mat);if V<=0 then Exit;
  V:=V*(GrassHash(Seed)and $ffff)/65536;
  for I:=0 to High(GROUND_MATERIALS[Mat].Grasses) do begin
    Result:=GROUND_MATERIALS[Mat].Grasses[I].Kind;V:=V-GROUND_MATERIALS[Mat].Grasses[I].Frequency;if V<0 then Exit;
  end;
end;
procedure Fold(const P:TVector3;var Lo,Hi:TVector3);
begin Lo.X:=Min(Lo.X,P.X);Lo.Y:=Min(Lo.Y,P.Y);Lo.Z:=Min(Lo.Z,P.Z);Hi.X:=Max(Hi.X,P.X);Hi.Y:=Max(Hi.Y,P.Y);Hi.Z:=Max(Hi.Z,P.Z);end;
function DistanceSq(const B:TBox3D;const P:TVector3):Single;
begin Result:=Sqr(Max(0,Max(B.Data[0].X-P.X,P.X-B.Data[1].X)))+Sqr(Max(0,Max(B.Data[0].Z-P.Z,P.Z-B.Data[1].Z)));end;
constructor TGrassSource.Create;
begin inherited Create;References:=1;Box:=TBox3D.Empty;end;
procedure TGrassSource.Release;
begin if InterlockedDecrement(References)=0 then Free;end;
procedure TGrassSource.FreeGPU;
begin if Buffer<>0 then AccDeleteBuffers(1,@Buffer);Buffer:=0;BufferCapacity:=0;PatchCount:=0;Cells:=nil;end;
destructor TGrassJob.Destroy;
begin Source.Release;inherited Destroy;end;
{ Square/triangle SAT also accepts small triangles wholly inside a metre cell. }
function PatchIntersects(const P:TGrassPatch):Boolean;
var A:array[0..2]of TTreeVec3;I,J:Integer;NX,NZ,D0,D1,D2,R:Single;
begin
  A[0]:=Vec(P.AX,0,P.AZ);A[1]:=Vec(P.BX,0,P.BZ);A[2]:=Vec(P.CX,0,P.CZ);Result:=False;
  for I:=0 to 2 do begin
    J:=(I+1)mod 3;NX:=A[J].Z-A[I].Z;NZ:=A[I].X-A[J].X;R:=0.5*(Abs(NX)+Abs(NZ));
    D0:=NX*A[0].X+NZ*A[0].Z;D1:=NX*A[1].X+NZ*A[1].Z;D2:=NX*A[2].X+NZ*A[2].Z;
    if(Min(D0,Min(D1,D2))>R)or(Max(D0,Max(D1,D2))< -R)then Exit;
  end;Result:=True;
end;
function EnsureGrassSpatialIndex(Source:TGrassSource;Worker:TGrassWorker):Boolean;
var Index:TGrassSpatialIndex;Counts,Fills:TGrassTriangleIds;LargeFlags:array of Byte;
    I,X,Z,X0,X1,Z0,Z1,C,Links,TotalLinks,LargeCount,CellCount,N,SmallCount:Integer;
    MaxLinks:Int64;Lo,Hi:TVector3;T:TGrassTriangle;
  procedure Bounds(const Triangle:TGrassTriangle);
  begin
    X0:=Floor(Min(Triangle.A.X,Min(Triangle.B.X,Triangle.C.X))/Index.Step)-Index.MinX;
    X1:=Floor(Max(Triangle.A.X,Max(Triangle.B.X,Triangle.C.X))/Index.Step)-Index.MinX;
    Z0:=Floor(Min(Triangle.A.Z,Min(Triangle.B.Z,Triangle.C.Z))/Index.Step)-Index.MinZ;
    Z1:=Floor(Max(Triangle.A.Z,Max(Triangle.B.Z,Triangle.C.Z))/Index.Step)-Index.MinZ;
  end;
begin
  N:=Length(Source.Triangles);
  if Source.Spatial.Ready and (Source.Spatial.TriangleCount=N) then Exit(True);
  Result:=False;Index:=Default(TGrassSpatialIndex);Index.TriangleCount:=N;
  if N=0 then begin Index.Ready:=True;Source.Spatial:=Index;Exit(True);end;
  Lo:=Vector3(1e30,0,1e30);Hi:=Vector3(-1e30,0,-1e30);
  Index.Step:=GRASS_INDEX_CELL;SmallCount:=0;SetLength(LargeFlags,(N+7) div 8);
  for I:=0 to N-1 do begin
    if (Worker<>nil) and Worker.Terminated then Exit;
    T:=Source.Triangles[I];Bounds(T);
    if Int64(X1-X0+1)*(Z1-Z0+1)>GRASS_INDEX_MAX_TRI_CELLS then begin
      LargeFlags[I shr 3]:=LargeFlags[I shr 3] or (1 shl (I and 7));Continue;
    end;
    Inc(SmallCount);Fold(T.A,Lo,Hi);Fold(T.B,Lo,Hi);Fold(T.C,Lo,Hi);
  end;
  { A sea-sized or very long triangle must neither duplicate its ID into
    thousands of buckets nor enlarge/coarsen the index of ordinary faces. }
  if SmallCount=0 then begin
    SetLength(Index.LargeIds,N);
    for I:=0 to N-1 do begin
      if (Worker<>nil) and Worker.Terminated then Exit;
      Index.LargeIds[I]:=I;
    end;
    Index.Ready:=True;Source.Spatial:=Index;Exit(True);
  end;
  repeat
    Index.MinX:=Floor(Lo.X/Index.Step);Index.MinZ:=Floor(Lo.Z/Index.Step);
    Index.Width:=Floor(Hi.X/Index.Step)-Index.MinX+1;
    Index.Height:=Floor(Hi.Z/Index.Step)-Index.MinZ+1;
    if Int64(Index.Width)*Index.Height<=GRASS_INDEX_MAX_CELLS then Break;
    Index.Step:=Index.Step*2;
  until False;
  CellCount:=Index.Width*Index.Height;
  SetLength(Counts,CellCount);
  { At most four references per triangle on average, capped at 32 MiB for
    links (or one per triangle for exceptionally huge sources). Giant
    triangles live once in LargeIds instead of filling the whole grid. }
  MaxLinks:=Max(Int64(N),Min(Int64(N)*4,Int64(8)*1024*1024));
  TotalLinks:=0;LargeCount:=0;
  for I:=0 to N-1 do begin
    if (Worker<>nil) and Worker.Terminated then Exit;
    Links:=0;
    if (LargeFlags[I shr 3] and (1 shl (I and 7)))=0 then begin
      Bounds(Source.Triangles[I]);Links:=(X1-X0+1)*(Z1-Z0+1);
    end;
    if (Links=0) or (Int64(TotalLinks)+Links>MaxLinks) then begin
      LargeFlags[I shr 3]:=LargeFlags[I shr 3] or (1 shl (I and 7));
      if LargeCount=Length(Index.LargeIds) then SetLength(Index.LargeIds,Min(N,Max(32,LargeCount*2)));
      Index.LargeIds[LargeCount]:=I;Inc(LargeCount);Continue;
    end;
    Inc(TotalLinks,Links);
    for Z:=Z0 to Z1 do for X:=X0 to X1 do Inc(Counts[Z*Index.Width+X]);
  end;
  SetLength(Index.LargeIds,LargeCount);SetLength(Index.Offsets,CellCount+1);
  SetLength(Fills,CellCount);SetLength(Index.TriangleIds,TotalLinks);C:=0;
  for I:=0 to CellCount-1 do begin Index.Offsets[I]:=C;Fills[I]:=C;Inc(C,Counts[I]);end;
  Index.Offsets[CellCount]:=C;
  for I:=0 to N-1 do begin
    if (Worker<>nil) and Worker.Terminated then Exit;
    if (LargeFlags[I shr 3] and (1 shl (I and 7)))<>0 then Continue;
    Bounds(Source.Triangles[I]);
    for Z:=Z0 to Z1 do for X:=X0 to X1 do begin
      C:=Z*Index.Width+X;Index.TriangleIds[Fills[C]]:=I;Inc(Fills[C]);
    end;
  end;
  Index.Ready:=True;Source.Spatial:=Index;Result:=True;
end;

function GrassSpatialCandidates(Source:TGrassSource;QueryMinX,QueryMinZ,QueryMaxX,QueryMaxZ:Integer;
  Worker:TGrassWorker):TGrassTriangleIds;
var Seen:array of Byte;X,Z,X0,X1,Z0,Z1,C,J,N:Integer;
  procedure Add(Id:Integer);
  var Mask:Byte;
  begin
    Mask:=1 shl (Id and 7);
    if (Seen[Id shr 3] and Mask)<>0 then Exit;
    Seen[Id shr 3]:=Seen[Id shr 3] or Mask;
    if N=Length(Result) then SetLength(Result,Max(256,N*2));
    Result[N]:=Id;Inc(N);
  end;
  procedure Sort(L,R:Integer);
  var A,B,P,T:Integer;
  begin
    A:=L;B:=R;P:=Result[(L+R) div 2];
    repeat
      while Result[A]<P do Inc(A);while Result[B]>P do Dec(B);
      if A<=B then begin T:=Result[A];Result[A]:=Result[B];Result[B]:=T;Inc(A);Dec(B);end;
    until A>B;
    if L<B then Sort(L,B);if A<R then Sort(A,R);
  end;
begin
  Result:=nil;N:=0;
  if not EnsureGrassSpatialIndex(Source,Worker) then Exit;
  if Source.Spatial.TriangleCount=0 then Exit;
  SetLength(Seen,(Source.Spatial.TriangleCount+7) div 8);
  with Source.Spatial do begin
    X0:=Max(0,Floor(QueryMinX/Step)-MinX);
    X1:=Min(Width-1,Floor(QueryMaxX/Step)-MinX);
    Z0:=Max(0,Floor(QueryMinZ/Step)-MinZ);
    Z1:=Min(Height-1,Floor(QueryMaxZ/Step)-MinZ);
    for Z:=Z0 to Z1 do for X:=X0 to X1 do begin
      if (Worker<>nil) and Worker.Terminated then Exit;
      C:=Z*Width+X;
      for J:=Offsets[C] to Offsets[C+1]-1 do Add(TriangleIds[J]);
    end;
    for J:=0 to High(LargeIds) do begin
      if (Worker<>nil) and Worker.Terminated then Exit;
      Add(LargeIds[J]);
    end;
  end;
  SetLength(Result,N);
  { Identical triangle order preserves patch order, random roots and depth
    ordering on material seams; querying adjacent buckets never duplicates. }
  if N>1 then Sort(0,N-1);
end;

function BuildPatches(Job:TGrassJob;Worker:TGrassWorker;UseSpatialIndex:Boolean=True):TGrassResult;
var I,Selected,X,Z,X0,X1,Z0,Z1,MinX,MinZ,N,K,C,Dest,Grid,BuildRadius:Integer;
    T:TGrassTriangle;CrossV,Lo,Hi:TVector3;SlopeX,SlopeZ,UpX,UpZ:Single;P:TGrassPatch;
    Raw:TGrassPatches;CellId:array of Integer;
    Counts,Offsets,Fills:array of Integer;
    CandidateIds:TGrassTriangleIds;
begin
  Result:=TGrassResult.Create;Result.Id:=Job.Source.Id;Result.CameraX:=Job.CameraX;Result.CameraZ:=Job.CameraZ;
  try
  BuildRadius:=Job.Radius;if BuildRadius<=0 then BuildRadius:=RADIUS;
  BuildRadius:=EnsureRange(Ceil(BuildRadius/CELL)*CELL,CELL,256);
  Result.Radius:=BuildRadius;Grid:=2*BuildRadius div CELL;
  N:=0;MinX:=Floor(Job.CameraX/CELL)*CELL-BuildRadius;MinZ:=Floor(Job.CameraZ/CELL)*CELL-BuildRadius;
  SetLength(Counts,Grid*Grid*8);SetLength(Offsets,Length(Counts));SetLength(Fills,Length(Counts));
  if UseSpatialIndex then CandidateIds:=GrassSpatialCandidates(Job.Source,
    MinX,MinZ,MinX+Grid*CELL-1,MinZ+Grid*CELL-1,Worker)
  else begin
    SetLength(CandidateIds,Length(Job.Source.Triangles));
    for I:=0 to High(CandidateIds) do CandidateIds[I]:=I;
  end;
  Result.VisitedTriangles:=Length(CandidateIds);
  with Job.Source.Spatial do
    Result.IndexBytes:=Int64(Length(Offsets)+Length(TriangleIds)+Length(LargeIds))*SizeOf(Integer);
  for Selected:=0 to High(CandidateIds)do begin
    I:=CandidateIds[Selected];
    if (Worker<>nil) and Worker.Terminated then Exit;T:=Job.Source.Triangles[I];
    X0:=Max(MinX,Floor(Min(T.A.X,Min(T.B.X,T.C.X))));X1:=Min(MinX+GRID*CELL-1,Floor(Max(T.A.X,Max(T.B.X,T.C.X))));
    Z0:=Max(MinZ,Floor(Min(T.A.Z,Min(T.B.Z,T.C.Z))));Z1:=Min(MinZ+GRID*CELL-1,Floor(Max(T.A.Z,Max(T.B.Z,T.C.Z))));
    if(X0>X1)or(Z0>Z1)then Continue;
    CrossV:=TVector3.CrossProduct(T.B-T.A,T.C-T.A);if Abs(CrossV.Y)<1e-7 then Continue;
    SlopeX:=-CrossV.X/CrossV.Y;SlopeZ:=-CrossV.Z/CrossV.Y;if(Abs(SlopeX)>4)or(Abs(SlopeZ)>4)then Continue;
    if (T.UpA=0)and(T.UpB=0)and(T.UpC=0) then begin
      T.UpA:=Abs(CrossV.Y)/CrossV.Length;T.UpB:=T.UpA;T.UpC:=T.UpA;
    end;
    { Same interpolated normal Y as the ground fragment shader. Reuse three
      spare patch floats, retaining the 64-byte GPU descriptor. }
    if Max(T.UpA,Max(T.UpB,T.UpC))<=0.44 then Continue;
    UpX:=((T.UpC-T.UpA)*(T.B.Z-T.A.Z)-(T.UpB-T.UpA)*(T.C.Z-T.A.Z))/CrossV.Y;
    UpZ:=((T.UpB-T.UpA)*(T.C.X-T.A.X)-(T.UpC-T.UpA)*(T.B.X-T.A.X))/CrossV.Y;
    for Z:=Z0 to Z1 do begin
      if (Worker<>nil) and Worker.Terminated then Exit;
      for X:=X0 to X1 do begin
        if Sqr(X+0.5-Job.CameraX)+Sqr(Z+0.5-Job.CameraZ)>Sqr(BuildRadius-2)then Continue;
        P:=WholeGrassPatch(X,Z,PickKind(T.Material,GrassCellSeed(X,Z)));
        P.Base.Y:=T.A.Y+(P.Base.X-T.A.X)*SlopeX+(P.Base.Z-T.A.Z)*SlopeZ;P.SlopeX:=SlopeX;P.SlopeZ:=SlopeZ;
        P.Reserved:=T.UpA+(P.Base.X-T.A.X)*UpX+(P.Base.Z-T.A.Z)*UpZ;P.Pad0:=UpX;P.Pad1:=UpZ;
        P.AX:=T.A.X-P.Base.X;P.AZ:=T.A.Z-P.Base.Z;P.BX:=T.B.X-P.Base.X;P.BZ:=T.B.Z-P.Base.Z;P.CX:=T.C.X-P.Base.X;P.CZ:=T.C.Z-P.Base.Z;
        if not PatchIntersects(P)then Continue;
        if N=Length(Raw)then begin SetLength(Raw,Max(2048,N*2));SetLength(CellId,Length(Raw));end;
        C:=(((Z-MinZ)div CELL)*GRID+(X-MinX)div CELL)*8+Round(P.Kind);Raw[N]:=P;CellId[N]:=C;Inc(Counts[C]);Inc(N);
      end;
    end;
  end;
  K:=0;SetLength(Result.Cells,GRID*GRID*8);
  for C:=0 to GRID*GRID*8-1 do begin Offsets[C]:=K;Fills[C]:=K;Inc(K,Counts[C]);Result.Cells[C].First:=Offsets[C];Result.Cells[C].Count:=Counts[C];Result.Cells[C].Kind:=C mod 8;Result.Cells[C].Box:=TBox3D.Empty;end;
  SetLength(Result.Patches,N);
  for I:=0 to N-1 do begin C:=CellId[I];Dest:=Fills[C];Inc(Fills[C]);Result.Patches[Dest]:=Raw[I];end;
  for C:=0 to GRID*GRID*8-1 do if Counts[C]>0 then begin
    Lo:=Vector3(1e30,1e30,1e30);Hi:=Vector3(-1e30,-1e30,-1e30);
    for I:=Offsets[C]to Offsets[C]+Counts[C]-1 do begin
      P:=Result.Patches[I];SlopeX:=0.5*(Abs(P.SlopeX)+Abs(P.SlopeZ));
      Fold(Vector3(P.Base.X-1.5,P.Base.Y-SlopeX-0.02,P.Base.Z-1.5),Lo,Hi);
      Fold(Vector3(P.Base.X+1.5,P.Base.Y+SlopeX+1.6,P.Base.Z+1.5),Lo,Hi);
    end;Result.Cells[C].Box:=Box3D(Lo,Hi);
  end;
  N:=0;for C:=0 to High(Result.Cells)do if Result.Cells[C].Count>0 then begin Result.Cells[N]:=Result.Cells[C];Inc(N);end;SetLength(Result.Cells,N);
  except Result.Free;raise;end;
end;
constructor TGrassWorker.Create(AOwner:TGrassRenderer);
begin Owner:=AOwner;FreeOnTerminate:=False;inherited Create(False);end;
procedure TGrassWorker.Execute;
var Job:TGrassJob;Res:TGrassResult;
begin
  while not Terminated do begin
    RTLEventWaitFor(Owner.FEvent);if Terminated then Break;
    repeat
      Job:=TGrassJob(Owner.PopJob);if Job=nil then Break;Res:=nil;
      try
        try Res:=BuildPatches(Job,Self);
        except on E:Exception do begin Res:=TGrassResult.Create;Res.Id:=Job.Source.Id;Res.CameraX:=Job.CameraX;Res.CameraZ:=Job.CameraZ;Res.Error:=E.Message;end;end;
        if Terminated then Res.Free else Owner.PushResult(Res);
      finally Job.Free;end;
    until Terminated;
  end;
end;
constructor TGrassRenderer.Create(AOwner:TComponent);
begin
  inherited Create(AOwner);
  { Visual blades never participate in navigation or contact queries. }
  Collides:=False;Pickable:=False;
  FSources:=TList.Create;FJobs:=TList.Create;FResults:=TList.Create;
  FLock:=SyncObjs.TCriticalSection.Create;FEvent:=RTLEventCreate;FBox:=TBox3D.Empty;FCullDistance:=GRASS_VIEW_END;
  FWorker:=TGrassWorker.Create(Self);
  {$IFDEF TILE_MEM_PROFILE}MemProbeAdd(Self,'grass',mkVRAM,@MemoryBytesGPU);{$ENDIF}
end;
destructor TGrassRenderer.Destroy;
begin
  {$IFDEF TILE_MEM_PROFILE}MemProbeRemove(Self);{$ENDIF}
  if FContextHooked then ApplicationProperties.OnGLContextCloseObject.Remove(@ContextClose);
  if FWorker<>nil then begin
    FWorker.Terminate;RTLEventSetEvent(FEvent);
    {$IFDEF MSWINDOWS}
    { Worker only uses the locked CPU queues; it never synchronizes with the
      UI. A pumping TThread.WaitFor can reenter a half-destroyed Dream/OSM
      scene. Join the native thread before releasing either queue or GL data. }
    if FWorker.Handle<>0 then Windows.WaitForSingleObject(FWorker.Handle,INFINITE);
    {$ELSE}
    FWorker.WaitFor;
    {$ENDIF}
    FreeAndNil(FWorker);
  end;
  ClearTiles;FreeAndNil(FShadowBinding);FreeAndNil(FRenderer);FSources.Free;FJobs.Free;FResults.Free;FLock.Free;RTLEventDestroy(FEvent);inherited Destroy;
end;
procedure TGrassRenderer.ContextClose(Sender:TObject);
var I:Integer;S:TGrassSource;
begin
  for I:=0 to FSources.Count-1 do begin S:=TGrassSource(FSources[I]);S.FreeGPU;S.Valid:=False;end;
  FreeAndNil(FShadowBinding);FreeAndNil(FRenderer);
end;
function TGrassRenderer.PopJob:TObject;
var I,Best:Integer;Near,Distance:Single;Job:TGrassJob;
begin
  Result:=nil;FLock.Acquire;
  try
    Best:=-1;Near:=MaxSingle;
    for I:=0 to FJobs.Count-1 do begin
      Job:=TGrassJob(FJobs[I]);Distance:=DistanceSq(Job.Source.Box,Vector3(Job.CameraX,0,Job.CameraZ));
      if Distance<Near then begin Near:=Distance;Best:=I end;
    end;
    if Best>=0 then begin Result:=TObject(FJobs[Best]);FJobs.Delete(Best) end;
  finally FLock.Release end;
end;
procedure TGrassRenderer.PushResult(Obj:TObject);
begin FLock.Acquire;try FResults.Add(Obj);finally FLock.Release;end;end;
procedure TGrassRenderer.AddSource(Mesh:TMesh;const TriMat:array of Integer;CX,CZ:Single);
var Source:TGrassSource;Verts:TMeshVertexArray;Indices:TMeshIndexArray;I,N,M:Integer;Lo,Hi:TVector3;
  function NormalUp(Index:Integer):Single;
  var V:TVector3;
  begin
    V:=Verts[Index].Normal;
    if V.LengthSqr>0.000001 then Result:=Abs(V.Y)/V.Length else Result:=0;
  end;
begin
  if(Mesh=nil)or(Mesh.TriangleCount=0)then Exit;Source:=TGrassSource.Create;
  try
    Inc(FNextId);Source.Id:=FNextId;Source.CenterX:=CX;Source.CenterZ:=CZ;
    Verts:=Mesh.Vertices;Indices:=Mesh.Indices;SetLength(Source.Triangles,Mesh.TriangleCount);N:=0;
    Lo:=Vector3(1e30,1e30,1e30);Hi:=Vector3(-1e30,-1e30,-1e30);
    for I:=0 to Mesh.TriangleCount-1 do begin
      if I<=High(TriMat)then M:=TriMat[I]else M:=GROUND_MAT_GRASS;if GrassMatDensity(M)<=0 then Continue;
      with Source.Triangles[N]do begin
        A:=Verts[Indices[I*3]].Position;B:=Verts[Indices[I*3+1]].Position;C:=Verts[Indices[I*3+2]].Position;
        UpA:=NormalUp(Indices[I*3]);UpB:=NormalUp(Indices[I*3+1]);UpC:=NormalUp(Indices[I*3+2]);
        Material:=M;Fold(A,Lo,Hi);Fold(B,Lo,Hi);Fold(C,Lo,Hi);
      end;Inc(N);
    end;
    SetLength(Source.Triangles,N);if N=0 then Exit;
    Source.Box:=Box3D(Lo-Vector3(1.5,0.1,1.5),Hi+Vector3(1.5,1.6,1.5));FSources.Add(Source);Source:=nil;RebuildBox;
  finally if Source<>nil then Source.Release;end;
end;
procedure TGrassRenderer.AddTile(Grass:TMesh;const TriMat:array of Integer;ACenterX,ACenterZ:Single);
begin AddSource(Grass,TriMat,ACenterX,ACenterZ);end;
procedure TGrassRenderer.EnqueueTile(Grass:TMesh;const TriMat:array of Integer;ACenterX,ACenterZ:Single);
begin try AddSource(Grass,TriMat,ACenterX,ACenterZ);finally Grass.Free;end;end;
procedure TGrassRenderer.RebuildBox;
var I:Integer;Lo,Hi:TVector3;S:TGrassSource;
begin
  FBox:=TBox3D.Empty;if FSources.Count=0 then Exit;Lo:=Vector3(1e30,1e30,1e30);Hi:=Vector3(-1e30,-1e30,-1e30);
  for I:=0 to FSources.Count-1 do begin S:=TGrassSource(FSources[I]);Fold(S.Box.Data[0],Lo,Hi);Fold(S.Box.Data[1],Lo,Hi);end;FBox:=Box3D(Lo,Hi);
end;
function TGrassRenderer.LocalBoundingBox:TBox3D;
begin Result:=FBox;end;
procedure TGrassRenderer.Schedule(const Camera:TVector3);
var I,TargetRadius:Integer;S:TGrassSource;Job:TGrassJob;
begin
  TargetRadius:=Round(VegetationDetail.GrassCacheRadius);
  { Queued work follows the latest camera. An in-flight worker owns its
    snapshot and is never modified by the render thread. }
  FLock.Acquire;
  try
    for I:=0 to FJobs.Count-1 do begin
      Job:=TGrassJob(FJobs[I]);Job.CameraX:=Camera.X;Job.CameraZ:=Camera.Z;
      Job.Radius:=TargetRadius;
    end;
  finally FLock.Release end;
  for I:=0 to FSources.Count-1 do begin
    S:=TGrassSource(FSources[I]);
    if DistanceSq(S.Box,Camera)>Sqr(TargetRadius+8)then begin if not S.Pending then begin S.FreeGPU;S.Valid:=False;end;Continue;end;
    if S.Pending then Continue;
    if S.Valid and (S.CacheRadius=TargetRadius) and
       (Sqr(S.LastX-Camera.X)+Sqr(S.LastZ-Camera.Z)<Sqr(VegetationDetail.GrassRefreshStep)) then Continue;
    Job:=TGrassJob.Create;Job.Source:=S;InterlockedIncrement(S.References);Job.CameraX:=Camera.X;Job.CameraZ:=Camera.Z;S.Pending:=True;
    Job.Radius:=TargetRadius;
    FLock.Acquire;try FJobs.Add(Job);finally FLock.Release;end;RTLEventSetEvent(FEvent);
  end;
end;
procedure TGrassRenderer.Drain;
var J,Processed,PreviousRadius:Integer;R:TGrassResult;S:TGrassSource;Started:QWord;Bytes:NativeInt;
begin
  Started:=GetTickCount64;Processed:=0;
  { A batch completed by the CPU worker must not become an unbounded burst
    of GL allocations. Leave the rest queued for subsequent frames. }
  while (Processed<VegetationDetail.GrassUploadCount) and
    ((Processed=0) or (GetTickCount64-Started<QWord(VegetationDetail.GrassUploadMS))) do begin
    R:=nil;
    FLock.Acquire;
    try
      if FResults.Count>0 then begin R:=TGrassResult(FResults[0]);FResults.Delete(0);end;
    finally FLock.Release;end;
    if R=nil then Break;
    Inc(Processed);
    try
      for J:=0 to FSources.Count-1 do begin
        S:=TGrassSource(FSources[J]);if S.Id<>R.Id then Continue;S.Pending:=False;
        if R.Error<>'' then begin
          FError:=R.Error;WritelnLog('Grass',R.Error);S.Valid:=True;
          S.LastX:=R.CameraX;S.LastZ:=R.CameraZ;Break;
        end;
        S.Cells:=R.Cells;S.PatchCount:=Length(R.Patches);S.Valid:=True;
        PreviousRadius:=S.CacheRadius;
        S.CacheRadius:=R.Radius;
        S.VisitedTriangles:=R.VisitedTriangles;S.IndexBytes:=R.IndexBytes;
        S.LastX:=R.CameraX;S.LastZ:=R.CameraZ;
        if S.PatchCount=0 then S.FreeGPU else begin
          Bytes:=NativeInt(S.PatchCount)*SizeOf(TGrassPatch);
          if S.Buffer=0 then AccGenBuffers(1,@S.Buffer);
          { Preserve capacity while riding, but return memory when a lower
            quality radius makes the payload at least 25% smaller. }
          if (R.Radius<PreviousRadius) and (Int64(Bytes)*4<Int64(S.BufferCapacity)*3) then
            S.BufferCapacity:=(Bytes+4095) and not NativeInt(4095)
          else S.BufferCapacity:=Max(S.BufferCapacity,(Bytes+4095) and not NativeInt(4095));
          glBindBuffer(GL_ARRAY_BUFFER,S.Buffer);
          { Orphan storage so an older draw can finish without a CPU wait;
            retain the buffer object and capacity instead of delete/gen. }
          glBufferData(GL_ARRAY_BUFFER,S.BufferCapacity,nil,GL_STREAM_DRAW);
          glBufferSubData(GL_ARRAY_BUFFER,0,Bytes,@R.Patches[0]);
          glBindBuffer(GL_ARRAY_BUFFER,0);
        end;
        Break;
      end;
    finally R.Free;end;
  end;
end;
procedure TGrassRenderer.RemoveTile(ACenterX,ACenterZ:Single);
var I:Integer;S:TGrassSource;
begin
  for I:=FSources.Count-1 downto 0 do begin S:=TGrassSource(FSources[I]);if(Abs(S.CenterX-ACenterX)<0.5)and(Abs(S.CenterZ-ACenterZ)<0.5)then begin S.FreeGPU;FSources.Delete(I);S.Release;end;end;RebuildBox;
end;
procedure TGrassRenderer.ClearTiles;
var I:Integer;S:TGrassSource;
begin
  for I:=0 to FSources.Count-1 do begin S:=TGrassSource(FSources[I]);S.FreeGPU;S.Release;end;FSources.Clear;FBox:=TBox3D.Empty;
  FLock.Acquire;try
    for I:=0 to FJobs.Count-1 do TObject(FJobs[I]).Free;FJobs.Clear;
    for I:=0 to FResults.Count-1 do TObject(FResults[I]).Free;FResults.Clear;
  finally FLock.Release;end;
end;
class procedure TGrassRenderer.CleanupSharedGL;
begin { All resources are owned by renderer instances. }end;
function TGrassRenderer.MemoryBytesGPU:Int64;
var I:Integer;
begin Result:=0;for I:=0 to FSources.Count-1 do Inc(Result,Int64(TGrassSource(FSources[I]).BufferCapacity));if FRenderer<>nil then Inc(Result,GRASS_BAKE_SIZE*GRASS_BAKE_SIZE*GRASS_ATLAS_LAYERS*4*4 div 3);end;
function TGrassRenderer.DiagString:string;
var I,N,T,Visited:Integer;Submitted,IndexBytes:Int64;
begin N:=0;T:=0;Visited:=0;IndexBytes:=0;for I:=0 to FSources.Count-1 do begin Inc(N,TGrassSource(FSources[I]).PatchCount);Inc(T,Length(TGrassSource(FSources[I]).Triangles));Inc(Visited,TGrassSource(FSources[I]).VisitedTriangles);Inc(IndexBytes,TGrassSource(FSources[I]).IndexBytes);end;
  Submitted:=0;if (FRenderer<>nil) and (FDrawCalls>0) then Submitted:=FRenderer.Triangles;
  Result:=Format('surfaces=%d triangles=%d patches=%d GPU=%.2f MiB drawn=%d calls=%d submitted_triangles=%d blades-to=%.0fm cache-radius=%.0fm indexed_triangles=%d index=%.2f MiB error=%s',[FSources.Count,T,N,MemoryBytesGPU/1048576,FDrawn,FDrawCalls,Submitted,VegetationDetail.Grass.BladeEnd,VegetationDetail.GrassCacheRadius,Visited,IndexBytes/1048576,FError]);end;
function TGrassRenderer.OverlapReport:string;
begin Result:='grass: global 1m cells, roots clipped to source triangles';end;
procedure TGrassRenderer.LocalRender(const Params:TRenderParams);
type TDrawRun=record
    First,Count,Kind,Signature:Integer;
    Depth,Distance:Single;
  end;
var Camera,Sun,HalfSize,ViewCenter:TVector3;Projection,View,Model,ViewModel:TMatrix4;P,V,M:TTreeMat4;Frustum:TFrustum;
    I,C:Integer;S:TGrassSource;B:TBox3D;D,BladeDistance,NearestDepth:Single;Dir:string;WasCull,WasBlend,WasDepth,OldMask:GLboolean;
    OldProgram,OldVAO,OldBuffer,OldActive,OldTexture,OldShadowTexture,OldDepthFunc:GLint;
    NearRun,FarRun:TDrawRun;
  procedure Flush(var Run:TDrawRun;Distant:Boolean);
  begin
    if Run.Count=0 then Exit;
    FRenderer.Draw(S.Buffer,Run.First,Run.Count,Distant,Run.Kind,Run.Depth,False,Run.Distance);
    Inc(FDrawCalls);Run.Count:=0;
  end;
  procedure Queue(var Run:TDrawRun;Distant:Boolean;Depth,Distance:Single);
  var Signature:Integer;
  begin
    Signature:=FRenderer.DrawSignature(Distant,S.Cells[C].Kind,Depth,Distance);
    if Signature<0 then Exit;
    { Only contiguous instance ranges with identical geometry/LOD may share
      a draw. Keep the fine culling cells and their original roots. }
    if (Run.Count>0) and (Run.Signature=Signature) and
       (Run.First+Run.Count=S.Cells[C].First) then begin
      Inc(Run.Count,S.Cells[C].Count);
      Run.Depth:=Min(Run.Depth,Depth);Run.Distance:=Min(Run.Distance,Distance);
    end else begin
      Flush(Run,Distant);
      Run.First:=S.Cells[C].First;Run.Count:=S.Cells[C].Count;
      Run.Kind:=S.Cells[C].Kind;Run.Signature:=Signature;
      Run.Depth:=Depth;Run.Distance:=Distance;
    end;
  end;
begin
  if RtxReflectionCaptureActive then Exit;
  FDrawn:=0;FDrawCalls:=0;if not CheckVisible or not RenderGrassActive then Exit;
  if Params.RenderingCamera.Target=rtShadowMap then Exit;
  View:=Params.RenderingCamera.Matrix;Camera:=WorldInverseTransform.MultPoint(CameraWorldPosFromView(View));
  Schedule(Camera);if FSources.Count=0 then Exit;
  {$ifndef OpenGLES}if (FRenderer=nil) and not Load_GL_version_3_3_CORE then Exit;{$endif}
  if not FContextHooked then begin ApplicationProperties.OnGLContextCloseObject.Add(@ContextClose);FContextHooked:=True;end;
  glGetIntegerv(GL_CURRENT_PROGRAM,@OldProgram);glGetIntegerv(GL_VERTEX_ARRAY_BINDING,@OldVAO);
  glGetIntegerv(GL_ARRAY_BUFFER_BINDING,@OldBuffer);glGetIntegerv(GL_ACTIVE_TEXTURE,@OldActive);
  glActiveTexture(GL_TEXTURE1);glGetIntegerv(GL_TEXTURE_BINDING_2D,@OldShadowTexture);
  glActiveTexture(GL_TEXTURE0);glGetIntegerv(GL_TEXTURE_BINDING_2D_ARRAY,@OldTexture);
  glGetIntegerv(GL_DEPTH_FUNC,@OldDepthFunc);glGetBooleanv(GL_DEPTH_WRITEMASK,@OldMask);
  WasCull:=glIsEnabled(GL_CULL_FACE);WasBlend:=glIsEnabled(GL_BLEND);WasDepth:=glIsEnabled(GL_DEPTH_TEST);
  try
  if FRenderer=nil then begin
    FRenderer:=TGrassPatchRenderer.Create;
    try Dir:=URIToFilenameSafe('castle-data:/procedural-trees/');FRenderer.Initialize(Dir+'shaders',GroundRiderShadowGLSL);
      FShadowBinding:=TGroundShadowGLBinding.Create(FRenderer.ProgramHandle);FRenderer.LoadProfiles(Dir+'grass-atlases/profiles.json');FRenderer.LoadAtlas(Dir+'grass-atlases');
    except FreeAndNil(FShadowBinding);FreeAndNil(FRenderer);raise;end;
  end;
  Drain;
  FRenderer.LodSettings:=VegetationDetail.Grass;
  FCullDistance:=VegetationDetail.Grass.ViewEnd;
  Projection:=RenderContext.ProjectionMatrix;Model:=WorldTransform;Frustum.Init(Projection*View*Model);
  ViewModel:=View*Model;FRenderer.AdaptiveDetail:=GrassBladeLodActive;
  System.Move(Projection,P,SizeOf(P));System.Move(View,V,SizeOf(V));System.Move(Model,M,SizeOf(M));Sun:=SunDirection;if FSun.Length>0.001 then Sun:=FSun;
  FRenderer.BeginFrame(P,V,M,Vec(Camera.X,Camera.Y,Camera.Z),Vec(Sun.X,Sun.Y,Sun.Z),WindNow,WindCurrentBaseSpeed/3);
  FShadowBinding.Bind(1);glActiveTexture(GL_TEXTURE0);
    for I:=0 to FSources.Count-1 do begin
      S:=TGrassSource(FSources[I]);if S.Buffer=0 then Continue;if not Frustum.Box3DCollisionPossibleSimple(S.Box)then Continue;
      NearRun:=Default(TDrawRun);FarRun:=Default(TDrawRun);
      for C:=0 to High(S.Cells)do begin
        if S.Cells[C].Count=0 then Continue;B:=S.Cells[C].Box;D:=DistanceSq(B,Camera);
        if(D>Sqr(FCullDistance))or not Frustum.Box3DCollisionPossibleSimple(B)then Continue;
        BladeDistance:=D;
        if GrassBladeLodActive then
          BladeDistance:=BladeDistance+Sqr(Max(0,Max(B.Data[0].Y-Camera.Y,Camera.Y-B.Data[1].Y)));
        if BladeDistance<Sqr(FRenderer.BladeDistance(S.Cells[C].Kind))then begin
          { Closest depth of the whole cell, including its height. Conservative
            at oblique views and for cameras inside/above the grass. }
          HalfSize:=(B.Data[1]-B.Data[0])*0.5;ViewCenter:=ViewModel.MultPoint((B.Data[1]+B.Data[0])*0.5);
          NearestDepth:=-ViewCenter.Z-Abs(ViewModel.Data[0,2])*HalfSize.X-
            Abs(ViewModel.Data[1,2])*HalfSize.Y-Abs(ViewModel.Data[2,2])*HalfSize.Z;
          Queue(NearRun,False,NearestDepth,Sqrt(BladeDistance));
        end;
        Queue(FarRun,True,Sqrt(D),Sqrt(BladeDistance));Inc(FDrawn,S.Cells[C].Count);
      end;
      Flush(NearRun,False);Flush(FarRun,True);
    end;
  finally
    if FRenderer<>nil then FRenderer.EndFrame;
    glUseProgram(OldProgram);glBindVertexArray(OldVAO);glBindBuffer(GL_ARRAY_BUFFER,OldBuffer);
    glActiveTexture(GL_TEXTURE1);glBindTexture(GL_TEXTURE_2D,OldShadowTexture);
    glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_2D_ARRAY,OldTexture);glActiveTexture(OldActive);
    glDepthFunc(OldDepthFunc);glDepthMask(OldMask);
    if WasCull<>0 then glEnable(GL_CULL_FACE)else glDisable(GL_CULL_FACE);
    if WasBlend<>0 then glEnable(GL_BLEND)else glDisable(GL_BLEND);
    if WasDepth<>0 then glEnable(GL_DEPTH_TEST)else glDisable(GL_DEPTH_TEST);
  end;
end;
initialization SunDirection:=DEFAULT_SUN_RAY_DIR;
end.
