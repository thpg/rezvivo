unit Osm3dProceduralVegetation;
{$ifdef ANDROID}{$define OpenGLES}{$endif}
{$mode objfpc}{$H+}
interface
uses Classes, SysUtils, Generics.Collections, CastleTransform, CastleVectors,
  CastleBoxes, CastleFrustum, Osm3dTileX3D, Osm3dGeoMath,
  TreeModel, TreeMath, TreeRuntime, TreeRenderer, TreeFoliageLOD, TreeDistantArena,
  CastleGLUtils, Osm3dVegetationBudget, Osm3dRtxShadow, Osm3dMotionPrefetch;
type
  TSpeciesVersions = array[TTreeSpecies] of QWord;
  TSpeciesCounts = array[TTreeSpecies] of Integer;
  TProceduralCell = class;
  TProceduralDetail = class;
  TProceduralEntry = record
    Instance: TreeModel.TTreeInstance;
    Position: TTreeWorldPosition;
    Radius, Height: Single;
    Bounds: TBox3D;
    Detail: TProceduralDetail;
    ShadowBucket: Cardinal;
  end;
  TProceduralEntries = array of TProceduralEntry;
  TProceduralCell = class
    ID: Integer;
    TileX, TileZ: Single;
    Origin: TTreeWorldPosition;
    Shrub: Boolean;
    Bounds: TBox3D;
    Entries: TProceduralEntries;
    Count: Integer;
    FarItems: array[TTreeSpecies] of TTreeGPUItems;
    FarCount: TSpeciesCounts;
    FarVersion: TSpeciesVersions;
    Dirty, Uploaded: Boolean;
  end;
  TProceduralCells = array of TProceduralCell;
  TProceduralDrawEntry=record Cell:TProceduralCell;Entry,Order,Bin:Integer;end;
  TProceduralFarBatch = class
    LastUse: QWord;
    Origin: TTreeWorldPosition;
    CellIDs: array of Integer;
    CellVersions: array of TSpeciesVersions;
    CellCounts: array of TSpeciesCounts;
    Renderer: array[TTreeSpecies] of TTreeRenderer;
    Count: array[TTreeSpecies] of Integer;
    destructor Destroy; override;
  end;
  TProceduralDetail = class
    Cell: TProceduralCell;
    Entry: Integer;
    Renderer: TTreeRenderer;
    Quality, Wanted, BuiltQuality, Distance, Priority, Weight: Single;
    InRange, Enabled, Compact: Boolean;
    TargetBytes, BuiltBudget, DataBytes, GPUBytes: Int64;
    RetryAt, SettingsAt, LeafFraction, NeedleDetail: Single;
    BranchSides, BranchSegments: Integer;
    destructor Destroy; override;
  end;
  { Owns an immutable CPU snapshot, never a live cell/GL object. }
  TProceduralJob = class(TThread)
  private
    FWorkEvent:PRTLEvent;
    procedure Build;
  public
    Reusable:Boolean;
    FinishedFlag: LongInt;
    CellID, Entry: Integer;
    Quality: Single;
    MaxBytes: Int64;
    Compact: Boolean;
    Instance: TreeModel.TTreeInstance;
    Profile: TTreeParams;
    AtlasDirectory, Error: string;
    AtlasJob, Cancelled: Boolean;
    Atlas: TPreparedTreeLOD;
    Prepared: TPreparedTreeGPU;
    BuildMS: Double;
    constructor Create(CreateSuspended:Boolean);
    procedure Dispatch;
    procedure Execute; override;
    function ReadyToCollect: Boolean;
    destructor Destroy; override;
  end;
  TOsmProceduralVegetation = class(TCastleTransform)
  private
    FCells: specialize TObjectList<TProceduralCell>;
    FVisibleCells, FDrawCells: TProceduralCells;
    FDrawEntries:array of TProceduralDrawEntry;
    FDetails: specialize TObjectList<TProceduralDetail>;
    FBatches: array[0..5] of TProceduralFarBatch;
    FArenas:array[TTreeSpecies]of TTreeRenderer;
    FArenaUnavailable:array[TTreeSpecies]of Boolean;
    FArenaFailures:QWord;
    FArenaLastError:string;
    FArenaIDs:TTreeCellIDs;
    FBatchUse: QWord;
    FShared: TTreeRenderer;
    FProfiles: array[TTreeSpecies] of TTreeParams;
    FJob: TProceduralJob;
    FAtlasUploadingSpecies:TTreeSpecies;
    FAtlasRetryAt:TSpeciesVersions;
    FAtlasAttempts:TSpeciesCounts;
    FAtlasFailureCount:QWord;
    FAtlasLastError:string;
    FDetailJobs: specialize TObjectList<TProceduralJob>;
    FIdleJobs: specialize TObjectList<TProceduralJob>;
    FWorkerLimit:Integer;
    FBuildMS, FDetailUploadMS, FDetailUploadMaxMS, FPlanMS, FQueueMS: Double;
    FBounds: TBox3D;
    FShaderDir, FAtlasDir, FError: string;
    FSerial: Integer;
    FHooked, FInactive: Boolean;
    FViewer, FLocalViewer, FViewerRight, FSunRayDirection: TVector3;
    FMainViewFrustum:TFrustum;
    FMotion: TMotionPrefetch;
    FPrefetchOffset: TVector3;
    FPlanTime, FSeconds, FDelta, FAtlasPlanTime: Single;
    FGenerationCount, FUploadCount, FDiscardedJobs, FShadowMembershipVersion: QWord;
    FSelectionHash: LongWord;
    FMemory: TGLMemoryInfo;
    FCacheBudget, FDetailBytes, FFreeVram: Int64;
    FMemoryTime, FUploadTime, FTargetFPS: Single;
    FLastRenderTick: QWord;
    FLastColorFrame: Int64;
    FLastAtlasUploadFrame:Int64;
    FLastColorCamera: TCastleCamera;
    FQualityRevision: Cardinal;
    FLoad: TTreeLoadControl;
    FDrawCalls, FTriangles, FFarTrees, FAtlasCount, FCrownProxies, FFoliageShoots: Integer;
    FShadowDraws: QWord;
    FSeason: Single;
    procedure ContextClose(Sender: TObject);
    procedure PollJob;
    function AtlasRetryReady(S:TTreeSpecies):Boolean;
    procedure AtlasFailed(S:TTreeSpecies;const MessageText:string);
    procedure PollDetails;
    function DetailPending(CellID, Entry: Integer): Boolean;
    procedure CancelDetails;
    procedure RecycleDetailJob(Index:Integer);
    procedure Plan(const Camera: TVector3;const Frustum:TFrustum);
    procedure RefreshMemoryBudget;
    procedure QueueDetail;
    procedure QueueAtlasAhead;
    procedure UploadCell(Cell: TProceduralCell);
    procedure ReleaseDetail(Index: Integer);
    procedure RebuildBounds;
    function FarBatch(const Cells:TProceduralCells;CellCount:Integer;
      const Origin:TTreeWorldPosition):TProceduralFarBatch;
    function CellInRange(Cell: TProceduralCell; const Camera: TVector3): Boolean;
    function FindCell(ID: Integer): TProceduralCell;
    function GetShadowCacheRevision:QWord;
    function GetShadowAtlasRevision:QWord;
  protected
    procedure LocalRender(const Params: TRenderParams); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure AddTile(const Trees: TTileTreeRecArray; TileX, TileZ: Single;
      Projection: TLocalProjection);
    procedure RemoveTile(TileX, TileZ: Single);
    function LocalBoundingBox: TBox3D; override;
    function Diagnostics: string;
    function CollectRtxTrees(Cache:TRtxShadow;var CellIndex,EntryIndex:Integer):Boolean;
    property SunRayDirection: TVector3 read FSunRayDirection write FSunRayDirection;
    property ShadowGeneration:QWord read FGenerationCount;
    property ShadowCacheRevision:QWord read GetShadowCacheRevision;
    property ShadowAtlasRevision:QWord read GetShadowAtlasRevision;
  end;
function ProceduralVegetationDiagnostics: string;
function ProceduralTreeQuality(const Distance: Single): Single;
implementation
uses {$IFDEF MSWINDOWS}Windows,{$ENDIF} Math, {$ifdef OpenGLES}CastleGLES{$else}CastleGL{$endif}, CastleRenderContext, CastleRenderOptions,
  CastleApplicationProperties, CastleUriUtils, Osm3dProceduralTreeData,
  Osm3dStudioSettings, Osm3dRenderInstanced, Osm3dWind, TreeSeason, TreeLOD, CastleLog,
  Osm3dVegetationQuality, CastleTimeUtils, Osm3dRtxMaterials, TreeGPUData, Osm3dShadowSchedule,VegetationRenderOptions;
const
  CELL_METERS = 128;
var LastRenderer: TOsmProceduralVegetation;

function TOsmProceduralVegetation.GetShadowAtlasRevision:QWord;
begin
  Result:=(QWord(FAtlasCount) shl 16) xor (QWord(FSerial) shl 32) xor
    QWord(Round(FSeason*12)) xor QWord(Ord(RenderTreesActive));
end;

function TOsmProceduralVegetation.GetShadowCacheRevision:QWord;
begin
  Result:=GetShadowAtlasRevision xor FShadowMembershipVersion xor
    (FGenerationCount shl 24) xor (QWord(Ord(ProceduralVegetationActive)) shl 8);
end;

function TOsmProceduralVegetation.CollectRtxTrees(Cache:TRtxShadow;var CellIndex,EntryIndex:Integer):Boolean;
var C:TProceduralCell;E:TProceduralEntry;R:TTreeRenderer;S:TTreeSpecies;M:TMatrix4;P:TVector3;I:Integer;
begin
  { An uninitialised colour renderer or missing species must not hold up
    buildings, ground and ready trees. Atlas uploads change the revision and
    schedule a replacement snapshot while the current one stays visible. }
  if FShared=nil then begin
    for I:=CellIndex to FCells.Count-1 do Cache.DeferTrees(FCells[I].Count);
    Exit(True);
  end;
  Result:=False;
  M:=WorldTransform;
  while (CellIndex<FCells.Count) and Cache.TimeAvailable do begin
    C:=FCells[CellIndex];
    if Cache.Intersects(C.Bounds.Transform(M)) then begin
      while (EntryIndex<C.Count) and Cache.TimeAvailable do begin
        E:=C.Entries[EntryIndex];
        if not Cache.Intersects(E.Bounds.Transform(M)) then begin Inc(EntryIndex);Continue;end;
        S:=E.Instance.Species;
        if not FShared.HasSeasonLOD(FProfiles[S]) then begin
          { An off-screen caster still needs its mask. The colour renderer's
            visibility-driven queue alone cannot prepare all shadow casters. }
          if (FJob=nil) and not FShared.AtlasPending and (FError='') and AtlasRetryReady(S) then begin
            FJob:=TProceduralJob.Create(True);FJob.AtlasJob:=True;
            FJob.Profile:=FProfiles[S];FJob.AtlasDirectory:=FAtlasDir;FJob.Start;
          end;
          Cache.DeferTrees(1);Inc(EntryIndex);Continue;
        end;
        R:=nil;if E.Detail<>nil then R:=E.Detail.Renderer;
        P:=M.MultPoint(Vector3(E.Position.X,E.Position.Y,E.Position.Z));
        if not Cache.AddTree(E.Instance,FProfiles[S],P,R,FShared,FSeason) then Exit;
        Inc(EntryIndex);
      end;
      if EntryIndex<C.Count then Exit;
    end;
    Inc(CellIndex);EntryIndex:=0;
  end;
  Result:=CellIndex>=FCells.Count;
end;

function TreeDistanceScale: Single;
begin
  { The studio's existing numeric override still scales the whole band. }
  Result:=ProceduralTreeDistance/Max(1,VegetationDetail.TreeDistance);
end;
function TreePreloadDistance: Single;
begin Result:=VegetationDetail.TreePreloadDistance*TreeDistanceScale;end;
function ProceduralTreeQuality(const Distance: Single): Single;
var Limit:Single;
begin
  Limit:=VegetationMovingTreeDistance(ProceduralTreeDistance);
  Result:=TreeDistanceQuality(Distance,
    VegetationDetail.TreeFadeStart*TreeDistanceScale*Limit/Max(1,ProceduralTreeDistance),Limit);
end;

function ToTreeMatrix(const M: TMatrix4): TTreeMat4;
var C,R: Integer;
begin
  for C:=0 to 3 do for R:=0 to 3 do Result[C*4+R]:=M.Data[C,R];
end;
function WorldPos(const P: TTreeWorldPosition): TVector3;
begin Result:=Vector3(P.X,P.Y,P.Z); end;
function TreePos(const P: TVector3): TTreeWorldPosition;
begin Result.X:=P.X;Result.Y:=P.Y;Result.Z:=P.Z; end;

destructor TProceduralFarBatch.Destroy;
var S: TTreeSpecies;
begin
  for S:=Low(S) to High(S) do if Renderer[S]<>nil then begin Renderer[S].Release;Renderer[S].Free;end;
  inherited;
end;
destructor TProceduralDetail.Destroy;
begin if Renderer<>nil then begin Renderer.Release;Renderer.Free;end;inherited;end;
constructor TProceduralJob.Create(CreateSuspended:Boolean);
begin
  inherited Create(True);
  FWorkEvent:=RTLEventCreate;
  if not CreateSuspended then Start;
end;
procedure TProceduralJob.Dispatch;
begin
  Cancelled:=False;Error:='';BuildMS:=0;
  InterlockedExchange(FinishedFlag,0);
  if Suspended then Start else RTLEventSetEvent(FWorkEvent);
end;
procedure TProceduralJob.Execute;
begin
  repeat
    if Terminated then Exit;
    Build;
    if not Reusable then Exit;
    RTLEventWaitFor(FWorkEvent);
  until Terminated;
end;
procedure TProceduralJob.Build;
var Tree:TProceduralTree; Data:TTreeData; Started:TTimerResult;
begin
  Started:=Timer;
  try
    if AtlasJob then begin
      Atlas:=TTreeRenderer.PrepareLODAtlas(AtlasDirectory,Profile);
      if (Length(Atlas.Pixels)=0) or not Atlas.Seasonal then
        raise Exception.Create('Missing matching seasonal tree atlas: '+
          IncludeTrailingPathDelimiter(AtlasDirectory)+SpeciesName(Profile.Species)+
          ' key='+LODProfileKey(Profile));
    end else begin
      Tree:=TProceduralTree.Create;
      try
        Tree.Configure(Instance,Profile);Tree.EnsureDetail(4);
        Data:=Tree.Data;
        Compact:=Int64(Length(Data.Branches)+Length(Data.Leaves)+Length(Data.NeedleShoots)+Length(Data.Fruits))*64+64>MaxBytes;
        PrepareGameTreeDetail(Data,MaxBytes-64);
        Prepared:=PrepareTreeGPU(Data);
      finally Tree.Free;end;
      Data:=Default(TTreeData);
    end;
  except on E: Exception do begin
    Error:=E.Message;
    WriteLnLog('ProceduralTrees',Error);
  end;end;
  BuildMS:=TimerSeconds(Timer,Started)*1000;
  InterlockedExchange(FinishedFlag,1);
end;
function TProceduralJob.ReadyToCollect: Boolean;
begin
  Result:=InterlockedCompareExchange(FinishedFlag,0,0)<>0;
  {$IFDEF MSWINDOWS}
  { Execute publishes its data before the OS thread has actually exited.
    Never wait for that remaining tail from inside a render pass. }
  if Result and not Reusable then Result:=WaitForSingleObject(Handle,0)=WAIT_OBJECT_0;
  {$ENDIF}
end;

destructor TProceduralJob.Destroy;
begin
  Terminate;
  RTLEventSetEvent(FWorkEvent);
  if Suspended then Start;
  {$IFDEF MSWINDOWS}
  { This worker owns only CPU snapshots and never calls Synchronize.
    TThread.WaitFor pumps window messages and synchronization callbacks on
    the main thread: a close event could destroy FShared halfway through
    PollJob / LocalRender. Join without dispatching any UI callbacks. }
  if Handle<>0 then WaitForSingleObject(Handle,INFINITE);
  {$ELSE}
  WaitFor;
  {$ENDIF}
  RTLEventDestroy(FWorkEvent);
  inherited;
end;

constructor TOsmProceduralVegetation.Create(AOwner: TComponent);
var S: TTreeSpecies;
begin
  inherited;
  FLastColorFrame:=-1;
  FLastAtlasUploadFrame:=-1;
  FCells:=specialize TObjectList<TProceduralCell>.Create(True);
  FDetails:=specialize TObjectList<TProceduralDetail>.Create(True);
  FDetailJobs:=specialize TObjectList<TProceduralJob>.Create(True);
  FIdleJobs:=specialize TObjectList<TProceduralJob>.Create(True);
  FWorkerLimit:=Min(4,Max(1,TThread.ProcessorCount div 2));
  FBounds:=TBox3D.Empty;FViewerRight:=Vector3(1,0,0);
  FSeason:=ProceduralVegetationSeason;
  FCacheBudget:=128*1024*1024;FFreeVram:=-1;
  FShaderDir:=URIToFilenameSafe('castle-data:/procedural-trees/shaders/');
  FAtlasDir:=URIToFilenameSafe('castle-data:/procedural-trees/lod-atlases/');
  for S:=Low(S) to High(S) do FProfiles[S]:=DefaultTreeParams(S);
  Collides:=False;CastShadows:=True;
end;
destructor TOsmProceduralVegetation.Destroy;
begin
  if LastRenderer=Self then LastRenderer:=nil;
  if FHooked then ApplicationProperties.OnGLContextCloseObject.Remove(@ContextClose);
  FreeAndNil(FJob);
  FreeAndNil(FDetailJobs);
  FreeAndNil(FIdleJobs);
  ContextClose(nil);FCells.Free;FDetails.Free;
  inherited;
end;
procedure TOsmProceduralVegetation.ContextClose(Sender: TObject);
var C: TProceduralCell; I: Integer;S:TTreeSpecies;
begin
  CancelDetails;
  for I:=FDetails.Count-1 downto 0 do ReleaseDetail(I);
  for C in FCells do begin
    C.Dirty:=True;
  end;
  for I:=Low(FBatches) to High(FBatches) do FreeAndNil(FBatches[I]);
  for S:=Low(S)to High(S)do begin
    if FArenas[S]<>nil then begin FArenas[S].Release;FreeAndNil(FArenas[S]);end;
    FArenaUnavailable[S]:=False;
  end;
  FArenaFailures:=0;FArenaLastError:='';
  if FShared<>nil then begin FShared.Release;FreeAndNil(FShared);end;
  FAtlasCount:=0;FError:='';
  FAtlasRetryAt:=Default(TSpeciesVersions);FAtlasAttempts:=Default(TSpeciesCounts);
  FAtlasLastError:='';FAtlasFailureCount:=0;
  FreeAndNil(FMemory);FMemoryTime:=0;FLastRenderTick:=0;
  FLastAtlasUploadFrame:=-1;
end;
procedure TOsmProceduralVegetation.ReleaseDetail(Index: Integer);
var D: TProceduralDetail;
begin
  D:=FDetails[Index];D.Cell.Entries[D.Entry].Detail:=nil;if D.Quality>0 then D.Cell.Dirty:=True;
  Dec(FDetailBytes,D.GPUBytes);
  FDetails.Delete(Index);
end;
procedure TOsmProceduralVegetation.RebuildBounds;
var C: TProceduralCell;
begin FBounds:=TBox3D.Empty;for C in FCells do FBounds:=FBounds+C.Bounds;end;
function TOsmProceduralVegetation.LocalBoundingBox: TBox3D;
begin Result:=FBounds;end;
function TOsmProceduralVegetation.FindCell(ID: Integer): TProceduralCell;
var C: TProceduralCell;
begin for C in FCells do if C.ID=ID then Exit(C);Result:=nil;end;
procedure TOsmProceduralVegetation.AddTile(const Trees: TTileTreeRecArray;
  TileX,TileZ: Single; Projection: TLocalProjection);
var Map: specialize TDictionary<string,TProceduralCell>; C: TProceduralCell;
    I,J,CX,CZ: Integer; K: string; A: TTreeParams; B: TBox3D; P: TVector3;
begin
  RemoveTile(TileX,TileZ);Map:=specialize TDictionary<string,TProceduralCell>.Create;
  try
    for I:=0 to High(Trees) do begin
      CX:=Floor(Trees[I].X/CELL_METERS);CZ:=Floor(Trees[I].Z/CELL_METERS);
      K:=IntToStr(CX)+':'+IntToStr(CZ)+':'+IntToStr(Ord(Trees[I].IsShrub));
      if not Map.TryGetValue(K,C) then begin
        C:=TProceduralCell.Create;Inc(FSerial);C.ID:=FSerial;
        C.TileX:=TileX;C.TileZ:=TileZ;C.Shrub:=Trees[I].IsShrub;
        C.Origin.X:=(CX+0.5)*CELL_METERS;C.Origin.Z:=(CZ+0.5)*CELL_METERS;
        C.Bounds:=TBox3D.Empty;C.Dirty:=True;Map.Add(K,C);FCells.Add(C);
      end;
      J:=C.Count;if J=Length(C.Entries) then SetLength(C.Entries,Max(16,J*2));
      C.Entries[J].Instance:=ProceduralTreeInstance(Trees[I],Projection);
      C.Entries[J].Position.X:=Trees[I].X;C.Entries[J].Position.Y:=Trees[I].Y;C.Entries[J].Position.Z:=Trees[I].Z;
      A:=ResolveTreeParams(C.Entries[J].Instance,FProfiles[C.Entries[J].Instance.Species]);
      C.Entries[J].ShadowBucket:=TreeModel.Hash32(A.Seed) and 3;
      C.Entries[J].Height:=A.Height;
      C.Entries[J].Radius:=Max(A.Height,A.Height*A.CrownSpread)*1.5;
      P:=WorldPos(C.Entries[J].Position);
      B.Data[0]:=P-Vector3(C.Entries[J].Radius,2,C.Entries[J].Radius);
      B.Data[1]:=P+Vector3(C.Entries[J].Radius,A.Height*1.6+2,C.Entries[J].Radius);
      C.Entries[J].Bounds:=B;C.Bounds:=C.Bounds+B;Inc(C.Count);
    end;
    for C in Map.Values do SetLength(C.Entries,C.Count);
  finally Map.Free;end;
  RebuildBounds;FPlanTime:=0;
end;
procedure TOsmProceduralVegetation.RemoveTile(TileX,TileZ: Single);
var I,J: Integer;C: TProceduralCell;S:TTreeSpecies;
begin
  for I:=FCells.Count-1 downto 0 do begin
    C:=FCells[I];if (C.TileX<>TileX) or (C.TileZ<>TileZ) then Continue;
    for J:=FDetails.Count-1 downto 0 do if FDetails[J].Cell=C then ReleaseDetail(J);
    for S:=Low(S)to High(S)do if FArenas[S]<>nil then FArenas[S].RemoveDistantCell(C.ID);
    FCells.Delete(I);
  end;
  RebuildBounds;
end;
function TOsmProceduralVegetation.CellInRange(Cell: TProceduralCell; const Camera: TVector3): Boolean;
var FarM: Single;
begin
  if Cell.Shrub then FarM:=GlobalLODConfig.ShrubsFarMeters else FarM:=GlobalLODConfig.TreesFarMeters;
  Result:=(FarM<=0) or (Sqr(Camera.X-Cell.Origin.X)+Sqr(Camera.Z-Cell.Origin.Z)<=Sqr(FarM));
end;
procedure TOsmProceduralVegetation.RefreshMemoryBudget;
var NewBudget,Total:Int64;
begin
  if FSeconds<FMemoryTime then Exit;
  if FMemory=nil then FMemory:=TGLMemoryInfo.Create else FMemory.Refresh;
  Total:=Int64(FMemory.DedicatedVideoMemory)*1024;
  FFreeVram:=-1;
  if FMemory.TotalAvailableMemory>0 then
    FFreeVram:=Int64(FMemory.CurrentAvailableVideoMemory)*1024
  {$ifndef OpenGLES}else if GL_ATI_meminfo then
    FFreeVram:=Int64(FMemory.VboFreeMemory)*1024{$endif};
  NewBudget:=Min(TreeCacheBudget(FDetailBytes,FFreeVram,Total),
    Int64(VegetationDetail.TreeCacheMiB)*1024*1024);
  if NewBudget<>FCacheBudget then begin FCacheBudget:=NewBudget;FPlanTime:=0;end;
  FTargetFPS:=VegetationFrameTarget;
  if FTargetFPS<0 then begin
    FTargetFPS:=60;
    {$IFDEF MSWINDOWS}
    Total:=GetDeviceCaps(wglGetCurrentDC(),VREFRESH);
    if Total>=10 then FTargetFPS:=Total;
    {$ENDIF}
  end;
  FMemoryTime:=FSeconds+2;
end;

procedure TOsmProceduralVegetation.Plan(const Camera: TVector3;const Frustum:TFrustum);
type TCandidate=record Cell:TProceduralCell;Entry:Integer;Distance,Priority:Single;end;
var Candidates:array of TCandidate;
    N,I,K,ActiveCount:Integer;C:TProceduralCell;D:TProceduralDetail;
    Dist,CacheDistance,Preload,TotalWeight,Weight:Single;
    Predicted,TreePosition:TVector3;Started:TTimerResult;
  function CacheWeight(Distance:Single):Single;
  begin
    if Distance>=ProceduralTreeDistance then Result:=0.35
    else Result:=1+3*Sqr(1-Distance/Max(1,ProceduralTreeDistance));
  end;
  procedure Sort(L,R:Integer);
  var A,B:Integer;Pivot:Single;Temp:TCandidate;
  begin
    A:=L;B:=R;Pivot:=Candidates[(L+R) div 2].Priority;
    repeat
      while Candidates[A].Priority<Pivot do Inc(A);
      while Candidates[B].Priority>Pivot do Dec(B);
      if A<=B then begin Temp:=Candidates[A];Candidates[A]:=Candidates[B];Candidates[B]:=Temp;Inc(A);Dec(B);end;
    until A>B;
    if L<B then Sort(L,B);if A<R then Sort(A,R);
  end;
begin
  Started:=Timer;
  for D in FDetails do begin D.Wanted:=0;D.InRange:=False;D.Enabled:=False;end;
  N:=0;TotalWeight:=0;Preload:=TreePreloadDistance;
  FPrefetchOffset:=FMotion.CacheOffset(Preload,ProceduralTreeDistance,16,2.5);
  Predicted:=Camera+FPrefetchOffset;
  for C in FCells do begin
    { Membership depends on position only; frustum culling is for drawing. }
    if (Abs(Predicted.X-C.Origin.X)>Preload*1.12+CELL_METERS) or
       (Abs(Predicted.Z-C.Origin.Z)>Preload*1.12+CELL_METERS) then Continue;
    for I:=0 to C.Count-1 do begin
      TreePosition:=WorldPos(C.Entries[I].Position);
      Dist:=(TreePosition-Camera).Length;CacheDistance:=(TreePosition-Predicted).Length;
      D:=C.Entries[I].Detail;
      { Build before an atlas enters the visible transition. A small exit
        margin reuses completed buffers when the camera turns or oscillates. }
      if (CacheDistance>Preload) and ((D=nil) or (D.Renderer=nil) or (CacheDistance>Preload*1.12)) then Continue;
      if N=Length(Candidates) then SetLength(Candidates,Max(128,N*2));
      Candidates[N].Cell:=C;Candidates[N].Entry:=I;Candidates[N].Distance:=Dist;
      Candidates[N].Priority:=PrefetchPriority(TreePosition,Camera,Predicted,ProceduralTreeDistance);
      { Keep a complete circle resident, but finish the current view first.
        Dense Ultra forests contain thousands of hidden trees; they must not
        hold up visible crowns. The nearest 25 m always prepare in all directions. }
      if (Dist>25) and not Frustum.Box3DCollisionPossibleSimple(C.Entries[I].Bounds) then
        Candidates[N].Priority:=25+(Candidates[N].Priority-25)*3;
      Inc(N);
      TotalWeight:=TotalWeight+CacheWeight(Dist);
    end;
  end;
  if N>1 then Sort(0,N-1);
  ActiveCount:=Ceil(N*FLoad.ActiveFraction);
  if VegetationDetail.TreeStableRange then ActiveCount:=N;
  FSelectionHash:=0;
  for K:=0 to N-1 do begin
    C:=Candidates[K].Cell;I:=Candidates[K].Entry;Dist:=Candidates[K].Distance;
    FSelectionHash:=((FSelectionHash shl 5) or (FSelectionHash shr 27)) xor
      LongWord(C.ID) xor (LongWord(I) shl 16);
    D:=C.Entries[I].Detail;
    if D=nil then begin
      D:=TProceduralDetail.Create;D.Cell:=C;D.Entry:=I;C.Entries[I].Detail:=D;FDetails.Add(D);
    end;
    Weight:=CacheWeight(Dist);
    D.InRange:=True;D.Distance:=Dist;D.Priority:=Candidates[K].Priority;D.Weight:=Weight;
    { 10% headroom for replacing buffers and fading trees leaving the circle. }
    D.TargetBytes:=Max(Int64(1024),Min(Int64(2)*1024*1024,
      Trunc(FCacheBudget*0.9*D.Weight/Max(1,TotalWeight))));
    D.TargetBytes:=(D.TargetBytes div 64)*64;
    D.Enabled:=(K<ActiveCount) or (Dist<=25);
    if D.Enabled then D.Wanted:=ProceduralTreeQuality(Dist);
  end;
  FPlanTime:=FSeconds+FLoad.PlanInterval;
  FPlanMS:=FPlanMS+TimerSeconds(Timer,Started)*1000;
end;
procedure TOsmProceduralVegetation.QueueAtlasAhead;
var C:TProceduralCell;I:Integer;Predicted:TVector3;S:TTreeSpecies;Radius:Single;
begin
  if (FJob<>nil) or FShared.AtlasPending or (FError<>'') or (FMotion.Speed<0.15) or
    (FSeconds<FAtlasPlanTime) or (FSeconds<FUploadTime) then Exit;
  FAtlasPlanTime:=FSeconds+Max(0.5,FLoad.PlanInterval);
  Radius:=TreePreloadDistance+FMotion.Speed*Min(4.0,FShared.AtlasUploadLatency);
  Predicted:=FLocalViewer+FMotion.CacheOffset(Radius,ProceduralTreeDistance,16,2.5);
  { Visible missing atlases have already taken the single worker. Prime
    upcoming species with the same worker/upload budget, also in baked mode. }
  for C in FCells do begin
    if (Abs(C.Origin.X-Predicted.X)>Radius+CELL_METERS) or
      (Abs(C.Origin.Z-Predicted.Z)>Radius+CELL_METERS) then Continue;
    for I:=0 to C.Count-1 do begin
      if (WorldPos(C.Entries[I].Position)-Predicted).Length>Radius then Continue;
      S:=C.Entries[I].Instance.Species;
      if FShared.HasSeasonLOD(FProfiles[S]) or not AtlasRetryReady(S) then Continue;
      FJob:=TProceduralJob.Create(True);FJob.AtlasJob:=True;FJob.Profile:=FProfiles[S];
      FJob.AtlasDirectory:=FAtlasDir;FJob.Start;Exit;
    end;
  end;
end;
function TOsmProceduralVegetation.DetailPending(CellID,Entry:Integer):Boolean;
var Job:TProceduralJob;I:Integer;
begin
  { Called for thousands of candidates: do not allocate an enumerator for
    this tiny inner loop. }
  for I:=0 to FDetailJobs.Count-1 do begin
    Job:=FDetailJobs[I];
    if (Job.CellID=CellID) and (Job.Entry=Entry) then Exit(True);
  end;
  Result:=False;
end;

procedure TOsmProceduralVegetation.CancelDetails;
var Job:TProceduralJob;
begin
  if FDetailJobs=nil then Exit;
  for Job in FDetailJobs do Job.Cancelled:=True;
end;

procedure TOsmProceduralVegetation.RecycleDetailJob(Index:Integer);
var Job:TProceduralJob;
begin
  { FinishedFlag publishes the snapshot; the reusable worker now only waits
    on its event. Retain the OS thread, release all per-tree CPU buffers. }
  Job:=FDetailJobs.Extract(FDetailJobs[Index]);
  Job.Prepared:=Default(TPreparedTreeGPU);Job.Error:='';
  FIdleJobs.Add(Job);
end;

procedure TOsmProceduralVegetation.QueueDetail;
var D,Best:TProceduralDetail;Score:Single;E:TProceduralEntry;
    BestItems:array[0..3]of TProceduralDetail;BestScores:array[0..3]of Single;
    NeedsBuild,Reclaim,MemoryPressure:Boolean; Job:TProceduralJob;
    Running,Slots,I,J:Integer;Started:TTimerResult;
begin
  if not ProceduralVegetationActive then Exit;
  Started:=Timer;
  try
  { At most four low-priority CPU producers; leave cores for streaming/physics.
    Eight snapshots, each <= 2 MiB, bound completed work independently of FPS.
    Never gate CPU work on the GPU upload clock. }
  Running:=0;
  for Job in FDetailJobs do if not Job.ReadyToCollect then Inc(Running);
  Slots:=Min(FWorkerLimit-Running,8-FDetailJobs.Count);
  if Slots<=0 then Exit;
  for I:=0 to Slots-1 do begin BestItems[I]:=nil;BestScores[I]:=MaxSingle;end;
  MemoryPressure:=FDetailBytes>FCacheBudget*0.90;
    { Select one small batch in one traversal. Ultra has thousands of resident
      candidates; rescanning them for each free worker wastes the frame budget. }
    for D in FDetails do if D.InRange and (D.RetryAt<=FSeconds) then begin
      Reclaim:=MemoryPressure and (D.GPUBytes>D.TargetBytes*1.25);
      { Adaptation limits drawing, not preparation ahead. Otherwise a loaded
        GPU disables speculative jobs precisely when the ride needs them,
        and restoring the frame rate starts another cold-cache transition. }
      NeedsBuild:=(D.Renderer=nil) or (D.Enabled and
        D.Compact and (D.BuiltBudget<D.TargetBytes*0.7)) or Reclaim;
      if not NeedsBuild then Continue;
      if DetailPending(D.Cell.ID,D.Entry) then Continue;
      Score:=D.Priority;
      { Finish missing trees before improving an already resident tree.
        Only an actual memory shortage may take precedence. }
      if D.Renderer<>nil then Score:=Score+10000;
      if Reclaim then Score:=-10000-D.Distance;
      if Score<BestScores[Slots-1] then begin
        J:=Slots-1;
        while (J>0) and (Score<BestScores[J-1]) do begin
          BestScores[J]:=BestScores[J-1];BestItems[J]:=BestItems[J-1];Dec(J);
        end;
        BestScores[J]:=Score;BestItems[J]:=D;
      end;
    end;
  for I:=0 to Slots-1 do begin
    Best:=BestItems[I];
    if Best=nil then Exit;
    E:=Best.Cell.Entries[Best.Entry];
    if not FShared.HasSeasonLOD(FProfiles[E.Instance.Species]) then begin
      if (FJob=nil)and not FShared.AtlasPending and AtlasRetryReady(E.Instance.Species) then begin
        FJob:=TProceduralJob.Create(True);FJob.AtlasJob:=True;
        FJob.Profile:=FProfiles[E.Instance.Species];FJob.AtlasDirectory:=FAtlasDir;
        FJob.Priority:=tpLower;FJob.Start;
      end;
      { Other species may already have their atlas, so do not block them. }
      Best.RetryAt:=FSeconds+0.15;Continue;
    end;
    if FIdleJobs.Count>0 then Job:=FIdleJobs.Extract(FIdleJobs[FIdleJobs.Count-1])
    else begin Job:=TProceduralJob.Create(True);Job.Reusable:=True;Job.Priority:=tpLower;end;
    Job.CellID:=Best.Cell.ID;Job.Entry:=Best.Entry;Job.Instance:=E.Instance;
    Job.Profile:=FProfiles[E.Instance.Species];Job.MaxBytes:=Best.TargetBytes;
    Job.Quality:=4;
    FDetailJobs.Add(Job);Job.Dispatch;
  end;
  finally FQueueMS:=FQueueMS+TimerSeconds(Timer,Started)*1000;end;
end;

function TOsmProceduralVegetation.AtlasRetryReady(S:TTreeSpecies):Boolean;
begin
  Result:=(FAtlasRetryAt[S]=0)or(GetTickCount64>=FAtlasRetryAt[S]);
end;
procedure TOsmProceduralVegetation.AtlasFailed(S:TTreeSpecies;const MessageText:string);
var DelayMS:QWord;
begin
  Inc(FAtlasFailureCount);FAtlasAttempts[S]:=Min(7,FAtlasAttempts[S]+1);
  DelayMS:=Min(30000,500 shl(FAtlasAttempts[S]-1));
  FAtlasRetryAt[S]:=GetTickCount64+DelayMS;
  FAtlasLastError:=SpeciesName(S)+': '+MessageText;
  { Back off only this species. Other complete atlases and species continue;
    context recreation clears the backoff. No permanent global FError latch. }
  WriteLnLog('Vegetation atlas',FAtlasLastError+'; retry in '+IntToStr(DelayMS)+' ms');
end;
procedure TOsmProceduralVegetation.PollJob;
var S:TTreeSpecies;
begin
  if FLastAtlasUploadFrame=TFramesPerSecond.RenderFrameId then Exit;
  FLastAtlasUploadFrame:=TFramesPerSecond.RenderFrameId;
  if FShared.AtlasPending then begin
    try
      if FShared.StepLODAtlas(1024*1024,Max(0.25,Min(1.5,FLoad.UploadBudgetMS*0.5)))then begin
        Inc(FAtlasCount);Inc(FUploadCount);
        FAtlasAttempts[FAtlasUploadingSpecies]:=0;FAtlasRetryAt[FAtlasUploadingSpecies]:=0;
      end;
    except on E:Exception do begin
      FShared.CancelLODAtlas;AtlasFailed(FAtlasUploadingSpecies,E.Message);
    end;end;
    Exit;
  end;
  if (FJob=nil) or not FJob.ReadyToCollect or (FSeconds<FUploadTime) then Exit;
  try
    if FJob.Cancelled then begin Inc(FDiscardedJobs);Exit;end;
    S:=FJob.Profile.Species;
    if FJob.Error<>'' then begin AtlasFailed(S,FJob.Error);Exit;end;
    try
      if VegetationAtlasBudget then begin
        FAtlasUploadingSpecies:=S;FShared.BeginLODAtlas(FJob.Atlas);
      end else begin
        FShared.UploadLODAtlas(FJob.Atlas);Inc(FAtlasCount);Inc(FUploadCount);
        FUploadTime:=FSeconds+FLoad.UploadInterval;FAtlasAttempts[S]:=0;FAtlasRetryAt[S]:=0;
      end;
    except on E:Exception do begin FShared.CancelLODAtlas;AtlasFailed(S,E.Message);end;end;
  finally FreeAndNil(FJob);end;
end;

procedure TOsmProceduralVegetation.PollDetails;
var C:TProceduralCell;D:TProceduralDetail;E:TProceduralEntry;Job:TProceduralJob;
    NewBytes,UploadedBytes:Int64;P:array[0..0]of TTreeWorldPosition;
    Instances:array[0..0]of TreeModel.TTreeInstance;
    I,Admitted:Integer;Started,ItemStarted:TTimerResult;Elapsed,Budget:Double;
begin
  Started:=Timer;Admitted:=0;UploadedBytes:=0;Budget:=FLoad.UploadBudgetMS;
  I:=0;
  while I<FDetailJobs.Count do begin
    Job:=FDetailJobs[I];
    if not Job.ReadyToCollect then begin Inc(I);Continue;end;
    C:=FindCell(Job.CellID);D:=nil;
    if (C<>nil) and (Job.Entry<C.Count) then D:=C.Entries[Job.Entry].Detail;
    if Job.Cancelled or not ProceduralVegetationActive or (D=nil) or not D.InRange then begin
      Inc(FDiscardedJobs);RecycleDetailJob(I);Continue;
    end;
    if Job.Error<>'' then begin FError:=Job.Error;RecycleDetailJob(I);Continue;end;
    if FSeconds<FUploadTime then Exit;
    NewBytes:=Job.Prepared.UploadBytes+64;
    if (Admitted>0) and ((Admitted>=8) or (UploadedBytes+NewBytes>2*1024*1024) or
      (TimerSeconds(Timer,Started)*1000>=Budget)) then Exit;
    if (Job.MaxBytes>D.TargetBytes*1.5) and (NewBytes>D.TargetBytes*1.5) then begin
      Inc(FDiscardedJobs);RecycleDetailJob(I);Continue;
    end;
    if (FDetailBytes-D.GPUBytes+NewBytes>FCacheBudget) and (NewBytes>=D.GPUBytes) then begin
      D.RetryAt:=FSeconds+0.5;Inc(FDiscardedJobs);RecycleDetailJob(I);Continue;
    end;
    ItemStarted:=Timer;
    E:=C.Entries[D.Entry];
    if D.Renderer=nil then begin
      D.Renderer:=TTreeRenderer.Create;D.Renderer.Initialize(FShaderDir,FShared);
      Instances[0]:=E.Instance;P[0]:=E.Position;
      D.Renderer.UploadDistantTreesAt(Instances,P,FProfiles[E.Instance.Species],E.Position);
    end;
    D.Renderer.UploadPreparedTree(Job.Prepared);
    Inc(FUploadCount);Inc(FGenerationCount);FBuildMS:=FBuildMS+Job.BuildMS;
    D.DataBytes:=Job.Prepared.UploadBytes;D.BuiltQuality:=Job.Quality;
    Inc(FDetailBytes,NewBytes-D.GPUBytes);D.GPUBytes:=NewBytes;
    D.BuiltBudget:=Job.MaxBytes;D.Compact:=Job.Compact;
    D.RetryAt:=FSeconds+0.1+0.9*Min(1,D.Distance/ProceduralTreeDistance);
    RecycleDetailJob(I);
    Elapsed:=TimerSeconds(Timer,ItemStarted)*1000;
    FDetailUploadMS:=FDetailUploadMS+Elapsed;
    FDetailUploadMaxMS:=Max(FDetailUploadMaxMS,Elapsed);
    Inc(Admitted);Inc(UploadedBytes,NewBytes);
    { A slow driver allocation cannot be pre-empted. Repay that exceptional
      cost over subsequent frames while the bounded CPU queue keeps working. }
    if Elapsed>Budget*2 then begin
      FUploadTime:=FSeconds+Min(0.1,(Elapsed/Budget-1)*Max(0.001,FDelta));Exit;
    end;
  end;
end;
procedure TOsmProceduralVegetation.UploadCell(Cell:TProceduralCell);
type TInstances=array of TreeModel.TTreeInstance;TPositions=array of TTreeWorldPosition;
var S:TTreeSpecies;I,N:Integer;Instances:TInstances;Positions:TPositions;PackedItems:TTreeGPUItems;Changed:Boolean;
begin
  for S:=Low(S) to High(S) do begin
    N:=0;
    for I:=0 to Cell.Count-1 do if (Cell.Entries[I].Instance.Species=S) and
      ((Cell.Entries[I].Detail=nil) or (Cell.Entries[I].Detail.Renderer=nil) or
       (Cell.Entries[I].Detail.Quality<=0)) then Inc(N);
    SetLength(Instances,N);SetLength(Positions,N);N:=0;
    for I:=0 to Cell.Count-1 do if (Cell.Entries[I].Instance.Species=S) and
      ((Cell.Entries[I].Detail=nil) or (Cell.Entries[I].Detail.Renderer=nil) or
       (Cell.Entries[I].Detail.Quality<=0)) then begin
      Instances[N]:=Cell.Entries[I].Instance;Positions[N]:=Cell.Entries[I].Position;Inc(N);
    end;
    PackedItems:=TTreeRenderer.PackDistantTreesAt(Instances,Positions,FProfiles[S],Cell.Origin);
    Changed:=Length(PackedItems)<>Length(Cell.FarItems[S]);
    if not Changed and (N>0) then
      Changed:=not CompareMem(@PackedItems[0],@Cell.FarItems[S][0],N*SizeOf(TTreeGPUItem));
    if Changed then begin Cell.FarItems[S]:=PackedItems;Inc(Cell.FarVersion[S]);Inc(FShadowMembershipVersion);end;
    Cell.FarCount[S]:=N;
  end;
  Cell.Dirty:=False;Cell.Uploaded:=True;
end;

function TOsmProceduralVegetation.FarBatch(const Cells:TProceduralCells;CellCount:Integer;
  const Origin:TTreeWorldPosition):TProceduralFarBatch;
var B:TProceduralFarBatch;C:TProceduralCell;I,J,K,N,Slot,First:Integer;S:TTreeSpecies;
    Match,SameCells,Changed,Rebuild:Boolean;Oldest:QWord;
    PackedItems:TTreeGPUItems;Offset:TTreeWorldPosition;
  procedure CopyCell(const Cell:TProceduralCell;Dest:Integer);
  var V,Count:Integer;
  begin
    Count:=Cell.FarCount[S];if Count=0 then Exit;
    System.Move(Cell.FarItems[S][0],PackedItems[Dest],Count*SizeOf(TTreeGPUItem));
    Offset.X:=Cell.Origin.X-Origin.X;Offset.Y:=Cell.Origin.Y-Origin.Y;Offset.Z:=Cell.Origin.Z-Origin.Z;
    for V:=Dest to Dest+Count-1 do begin
      PackedItems[V][0]:=PackedItems[V][0]+Offset.X;
      PackedItems[V][1]:=PackedItems[V][1]+Offset.Y;
      PackedItems[V][2]:=PackedItems[V][2]+Offset.Z;
    end;
  end;
begin
  Inc(FBatchUse);Slot:=0;Oldest:=High(QWord);SameCells:=False;
  for I:=Low(FBatches) to High(FBatches) do begin
    B:=FBatches[I];
    if B=nil then begin Slot:=I;Oldest:=0;Continue;end;
    if B.LastUse<Oldest then begin Slot:=I;Oldest:=B.LastUse;end;
    Match:=(Length(B.CellIDs)=CellCount) and
      (B.Origin.X=Origin.X) and (B.Origin.Y=Origin.Y) and (B.Origin.Z=Origin.Z);
    if Match then for J:=0 to CellCount-1 do
      if B.CellIDs[J]<>Cells[J].ID then begin Match:=False;Break;end;
    if Match then begin Slot:=I;SameCells:=True;Break;end;
  end;
  if FBatches[Slot]=nil then FBatches[Slot]:=TProceduralFarBatch.Create;
  B:=FBatches[Slot];B.LastUse:=FBatchUse;B.Origin:=Origin;
  for S:=Low(S) to High(S) do begin
    Changed:=not SameCells;Rebuild:=not SameCells;N:=0;
    for I:=0 to CellCount-1 do begin
      C:=Cells[I];Inc(N,C.FarCount[S]);
      if SameCells then begin
        if B.CellVersions[I][S]<>C.FarVersion[S] then Changed:=True;
        if B.CellCounts[I][S]<>C.FarCount[S] then Rebuild:=True;
      end;
    end;
    if not Changed then Continue;
    B.Count[S]:=N;
    if N=0 then Continue;
    if B.Renderer[S]=nil then begin
      B.Renderer[S]:=TTreeRenderer.Create;B.Renderer[S].Initialize(FShaderDir,FShared);
      Rebuild:=True;
    end;
    if Rebuild then begin
      SetLength(PackedItems,N);First:=0;
      for I:=0 to CellCount-1 do begin C:=Cells[I];CopyCell(C,First);Inc(First,C.FarCount[S]);end;
      B.Renderer[S].UploadDistantItems(PackedItems);Inc(FUploadCount);
    end else begin
      First:=0;
      for I:=0 to CellCount-1 do begin
        C:=Cells[I];K:=C.FarCount[S];
        if (K>0) and (B.CellVersions[I][S]<>C.FarVersion[S]) then begin
          SetLength(PackedItems,K);CopyCell(C,0);
          B.Renderer[S].UpdateDistantItems(First,PackedItems);Inc(FUploadCount);
        end;
        Inc(First,K);
      end;
    end;
  end;
  SetLength(B.CellIDs,CellCount);SetLength(B.CellVersions,CellCount);SetLength(B.CellCounts,CellCount);
  for I:=0 to CellCount-1 do begin
    B.CellIDs[I]:=Cells[I].ID;B.CellVersions[I]:=Cells[I].FarVersion;B.CellCounts[I]:=Cells[I].FarCount;
  end;
  Result:=B;
end;

procedure TOsmProceduralVegetation.LocalRender(const Params:TRenderParams);
var Projection,View,Model:TTreeMat4;M,V:TMatrix4;Frustum:TFrustum;
    Camera,LocalCamera,Sun,Right:TVector3;Eye:TTreeVec3;Env:TTreeRenderEnvironment;
    Depth,FreshColor:Boolean;C:TProceduralCell;D:TProceduralDetail;S:TTreeSpecies;I,CellIndex,UploadBudget:Integer;
    Instance:TreeModel.TTreeInstance;
    Target,OldQ,DetailDistance,LeafDistance,AdaptiveDetail:Single;
    Stats:TTreeRenderStats;Tick:QWord;OldLevel:Integer;
    OldProgram,OldVAO,OldBuffer,OldActive,OldTexture,OldNormalTexture,OldDepthFunc:GLint;OldRange:TDepthRange;
    OldPolygon:array[0..1]of GLint;Viewport:array[0..3]of GLint;
    WasDepth,WasBlend,WasCull,OldDepthMask:GLBoolean;
    VisibleCount,EntryCount,DrawIndex:Integer;Batch:TProceduralFarBatch;BatchOrigin:TTreeWorldPosition;
  function CellKey(Cell:TProceduralCell):Int64;
  var P:TVector3;Bin:Integer;
  begin
    P:=(Cell.Bounds.Data[0]+Cell.Bounds.Data[1])*0.5;
    Bin:=Floor(Max(0,(P-LocalCamera).Length-64)/64);
    Result:=Int64(Bin)*$100000000+Cardinal(Cell.ID);
  end;
  procedure SortCells(L,R:Integer);
  var A,B:Integer;Pivot:Int64;Swap:TProceduralCell;
  begin
    A:=L;B:=R;Pivot:=CellKey(FDrawCells[(L+R)div 2]);
    repeat
      while CellKey(FDrawCells[A])<Pivot do Inc(A);
      while CellKey(FDrawCells[B])>Pivot do Dec(B);
      if A<=B then begin Swap:=FDrawCells[A];FDrawCells[A]:=FDrawCells[B];FDrawCells[B]:=Swap;Inc(A);Dec(B) end;
    until A>B;
    if L<B then SortCells(L,B);if A<R then SortCells(A,R);
  end;
  procedure SortEntries(L,R:Integer);
  var A,B:Integer;Pivot: Int64;Swap:TProceduralDrawEntry;
    function Key(Index:Integer):Int64;
    begin Result:=Int64(FDrawEntries[Index].Bin)*$100000000+Cardinal(FDrawEntries[Index].Order);end;
  begin
    A:=L;B:=R;Pivot:=Key((L+R)div 2);
    repeat
      while Key(A)<Pivot do Inc(A);while Key(B)>Pivot do Dec(B);
      if A<=B then begin Swap:=FDrawEntries[A];FDrawEntries[A]:=FDrawEntries[B];FDrawEntries[B]:=Swap;Inc(A);Dec(B)end;
    until A>B;
    if L<B then SortEntries(L,B);if A<R then SortEntries(A,R);
  end;
  procedure RenderFar;
  var S:TTreeSpecies;J:Integer;R:TTreeRenderer;Cell:TProceduralCell;UseArena:Boolean;
  begin
    M:=WorldTransform*TranslationMatrix(WorldPos(BatchOrigin));Model:=ToTreeMatrix(M);
    if VegetationStableFarBuffers then begin
      if Length(FArenaIDs)<VisibleCount then SetLength(FArenaIDs,Length(FVisibleCells));
      for J:=0 to VisibleCount-1 do FArenaIDs[J]:=FDrawCells[J].ID;
    end;
    for S:=Low(S) to High(S) do begin
        UseArena:=VegetationStableFarBuffers and not FArenaUnavailable[S];
        if UseArena then try
          for J:=0 to VisibleCount-1 do begin
            Cell:=FDrawCells[J];
            if(Length(Cell.FarItems[S])=0)and(FArenas[S]=nil)then Continue;
            if FArenas[S]=nil then begin FArenas[S]:=TTreeRenderer.Create;FArenas[S].Initialize(FShaderDir,FShared);end;
            FArenas[S].EnsureDistantCell(Cell.ID,Cell.FarVersion[S],Cell.Origin,Cell.FarItems[S]);
          end;
          R:=FArenas[S];if R=nil then Continue;
          R.SelectDistantCells(FArenaIDs,VisibleCount,BatchOrigin);
        except on E:Exception do begin
          { A failed optional arena must never hide the species or publish
            invalid offsets. The original per-species batch keeps the same
            cells, descriptors, atlas and LOD. Retry after context recreation. }
          FArenaUnavailable[S]:=True;UseArena:=False;Inc(FArenaFailures);
          FArenaLastError:=SpeciesName(S)+': '+E.Message;
          if FArenas[S]<>nil then begin FArenas[S].Release;FreeAndNil(FArenas[S]);end;
          WriteLnLog('Vegetation arena',FArenaLastError+'; using legacy batches for this context');
        end;end;
        if not UseArena then begin
          if Batch=nil then Batch:=FarBatch(FVisibleCells,VisibleCount,BatchOrigin);
          R:=Batch.Renderer[S];if(R=nil)or(Batch.Count[S]=0)then Continue;
        end;
        R.Environment:=Env;
        Instance:=Default(TreeModel.TTreeInstance);Instance.TypeCode:=PackTreeType(S);
        R.Render(Instance,FProfiles[S],Projection,View,Model,Eye,
          0,VegetationWindNow,VegetationWindBaseSpeed*0.12,False,False,True,False,True,False);
        Stats:=R.Stats;
        if Depth then Inc(FShadowDraws,Stats.DrawCalls) else begin
          Inc(FDrawCalls,Stats.DrawCalls);Inc(FTriangles,Stats.Triangles);Inc(FFarTrees,Stats.FarTrees);
        end;
    end;
  end;
begin
  if RtxReflectionCaptureActive then Exit;
  if not ProceduralVegetationActive then begin
    if not FInactive then begin
      FInactive:=True;
      { Both modes use the same generated billboard atlases. Release only
        detailed geometry; keep atlas jobs, textures and far instances alive.
        Restore billboard membership before even the first shadow pass. }
      CancelDetails;
      for I:=FDetails.Count-1 downto 0 do ReleaseDetail(I);
      FPlanTime:=0;FUploadTime:=0;FLoad:=Default(TTreeLoadControl);
    end;
  end else if FInactive then begin FInactive:=False;FPlanTime:=0;end;
  if not RenderTreesActive or (FCells.Count=0) then Exit;
  Depth:=Params.RenderingCamera.Target=rtShadowMap;
  FreshColor:=not Depth and ((FLastColorFrame<>TFramesPerSecond.RenderFrameId)or
    (FLastColorCamera<>Params.RenderingCamera.Camera));
  V:=Params.RenderingCamera.Matrix;
  Camera:=CameraWorldPosFromView(V);
  if Depth then begin
    if not VegetationShadowViewer(Camera) then Camera:=FViewer;
  end else begin
    WindObserveCamera(Camera,PtrUInt(Params.RenderingCamera.Camera));
    FViewer:=Camera;FViewerRight:=Vector3(V.Data[0,0],0,V.Data[2,0]);
  end;
  LocalCamera:=WorldInverseTransform.MultPoint(Camera);
  if not Depth then FLocalViewer:=LocalCamera;
  Frustum.Init(RenderContext.ProjectionMatrix*V*WorldTransform);
  if not FHooked then begin ApplicationProperties.OnGLContextCloseObject.Add(@ContextClose);FHooked:=True;end;
  glGetIntegerv(GL_CURRENT_PROGRAM,@OldProgram);glGetIntegerv(GL_VERTEX_ARRAY_BINDING,@OldVAO);
  glGetIntegerv(GL_ARRAY_BUFFER_BINDING,@OldBuffer);glGetIntegerv(GL_ACTIVE_TEXTURE,@OldActive);
  glActiveTexture(GL_TEXTURE0);glGetIntegerv(GL_TEXTURE_BINDING_2D_ARRAY,@OldTexture);
  glActiveTexture(GL_TEXTURE1);glGetIntegerv(GL_TEXTURE_BINDING_2D_ARRAY,@OldNormalTexture);glActiveTexture(GL_TEXTURE0);
  glGetIntegerv(GL_DEPTH_FUNC,@OldDepthFunc);glGetBooleanv(GL_DEPTH_WRITEMASK,@OldDepthMask);
  {$ifndef OpenGLES}glGetIntegerv(GL_POLYGON_MODE,@OldPolygon[0]);{$endif}
  glGetIntegerv(GL_VIEWPORT,@Viewport[0]);
  WasDepth:=glIsEnabled(GL_DEPTH_TEST);WasBlend:=glIsEnabled(GL_BLEND);WasCull:=glIsEnabled(GL_CULL_FACE);
  OldRange:=RenderContext.DepthRange;
  try
    if Depth then RenderContext.DepthRange:=drFull;
    if FShared=nil then begin
      if Depth then Exit;
      FShared:=TTreeRenderer.Create;FShared.Initialize(FShaderDir);
    end;
    if FInactive then
      for C in FCells do if C.Dirty and C.Uploaded then UploadCell(C);
    if not Depth then begin
      LastRenderer:=Self;FDrawCalls:=0;FTriangles:=0;FFarTrees:=0;FCrownProxies:=0;FFoliageShoots:=0;
    end;
    if FreshColor then begin
      FMainViewFrustum:=Frustum;
      { Several world-cache slabs use the same camera in one frame. Measure
        actual frame time and advance adaptation/LOD once, not once per slab. }
      FLastColorFrame:=TFramesPerSecond.RenderFrameId;
      FLastColorCamera:=Params.RenderingCamera.Camera;
      { Cache work follows the viewing camera even when the ride's physics
        time scale is zero or replay is slowed down. Advance once in the
        colour pass; shadow cascades must not advance it again. }
      Tick:=GetTickCount64;
      if FMotion.Observe(LocalCamera,
        WorldInverseTransform.MultDirection(Vector3(-V.Data[0,2],-V.Data[1,2],-V.Data[2,2])),
        Tick,PtrUInt(Params.RenderingCamera.Camera)) then begin
        FPlanTime:=0;FAtlasPlanTime:=0;FPrefetchOffset:=TVector3.Zero;
        CancelDetails;
      end;
      if FLastRenderTick=0 then FDelta:=1/60
      else FDelta:=Min((Tick-FLastRenderTick)*0.001,0.1);
      FSeconds:=FSeconds+FDelta;
      if FQualityRevision<>VegetationQualityRevision then begin
        FQualityRevision:=VegetationQualityRevision;
        FPlanTime:=0;FMemoryTime:=0;
        for D in FDetails do D.SettingsAt:=0;
      end;
      RefreshMemoryBudget;
      if VegetationFrameTarget>=0 then FTargetFPS:=VegetationFrameTarget;
      OldLevel:=FLoad.Level;
      if FLastRenderTick<>0 then begin
        if VegetationDetail.Adaptive then FLoad.Observe((Tick-FLastRenderTick)*0.001,FTargetFPS)
        else FLoad.Observe((Tick-FLastRenderTick)*0.001,0);
      end;
      FLastRenderTick:=Tick;
      if OldLevel<>FLoad.Level then FPlanTime:=0;
      PollJob;
      FSeason:=AdvanceTreeSeason(FSeason,ProceduralVegetationSeason,FDelta*0.12);
      FShared.Season:=FSeason;
      if ProceduralVegetationActive and (FSeconds>=FPlanTime) then Plan(LocalCamera,Frustum);
      PollDetails;
      UploadBudget:=2;
      for I:=FDetails.Count-1 downto 0 do begin
        D:=FDetails[I];OldQ:=D.Quality;
        { Planning and generation may run slowly under load; the actual LOD
          blend follows today's camera every colour frame, never a stale
          0.25..1 s plan distance. This also serves off-screen cached trees. }
        D.Distance:=(WorldPos(D.Cell.Entries[D.Entry].Position)-LocalCamera).Length;
        { Evaluate visual density once from the viewer for every render pass.
          Background cache scheduling must not quantize a moving canopy at
          0.15..0.6 second intervals. Smooth adaptive budget changes as well. }
        LeafDistance:=D.Distance/Max(0.1,VegetationDetail.TreeDetailScale);
        Target:=NearLeafFraction(TreeTypeSpecies(D.Cell.Entries[D.Entry].Instance.TypeCode),
          LeafDistance,VegetationDetail.TreeMinLeafFraction);
        if D.Distance>25 then begin
          AdaptiveDetail:=FLoad.DetailFraction;
          if VegetationDetail.TreeStableRange then AdaptiveDetail:=Max(0.75,AdaptiveDetail);
          Target:=Target*AdaptiveDetail;
        end;
        Target:=Max(0.25,Min(1,Target));
        if D.LeafFraction<=0 then D.LeafFraction:=Target
        else if D.LeafFraction<Target then D.LeafFraction:=Min(Target,D.LeafFraction+FDelta*0.6)
        else D.LeafFraction:=Max(Target,D.LeafFraction-FDelta*0.6);
        D.NeedleDetail:=NearNeedleDetail(LeafDistance);
        if D.InRange and D.Enabled then D.Wanted:=ProceduralTreeQuality(D.Distance)
        else D.Wanted:=0;
        Target:=Min(D.Wanted,D.BuiltQuality);
        if D.Renderer=nil then Target:=0;
        D.Quality:=AdvanceTreeQuality(D.Quality,Target,FDelta,VegetationDetail.TreeFadeSeconds);
        if (OldQ=0)<>(D.Quality=0) then begin
          { Admit at most two changed resident cells per frame. Defer the
            membership change itself, so there is neither a hole nor a
            duplicate billboard while waiting for the upload budget. }
          if D.Cell.Uploaded and not D.Cell.Dirty then
            if UploadBudget>0 then Dec(UploadBudget) else D.Quality:=OldQ;
          if (OldQ=0)<>(D.Quality=0) then D.Cell.Dirty:=True;
        end;
        { FPS control changes drawing, not cache membership: restoring quality
          must reuse buffers instead of starting the generation queue again. }
        if not D.InRange and (D.Quality=0) then ReleaseDetail(I);
      end;
      { Keep shadow and colour membership identical, including casters outside
        the viewer frustum. Never upload an unseen cell for the first time. }
      for C in FCells do if C.Dirty and C.Uploaded then UploadCell(C);
    end;
    Sun:=FSunRayDirection;if Sun.Length<0.001 then Sun:=InstancedSunRayDirection;
    Sun:=-Sun;if Sun.Length<0.001 then Sun:=Vector3(-0.5,0.85,0.45);
    Right:=FViewerRight;if Right.Length<0.001 then Right:=Vector3(1,0,0);
    Right:=WorldInverseTransform.MultDirection(Right);
    Env:=Default(TTreeRenderEnvironment);Env.Enabled:=True;Env.DepthOnly:=Depth;
    if Depth then begin
      Env.ShadowPartitions:=ShadowCapturePartitions;
      Env.ShadowPartition:=ShadowCapturePartition;
    end;
    Env.DirectBranches:=True;
    Env.ViewportHeight:=Max(1,Viewport[3]);
    if Depth then begin Env.BranchSides:=4;Env.BranchSegments:=2;end
    else begin Env.BranchSides:=5;Env.BranchSegments:=3;end;
    Env.SunDirection:=TreeMath.Vec(Sun.X,Sun.Y,Sun.Z);
    Env.BillboardRight:=TreeMath.Vec(Right.X,Right.Y,Right.Z);
    Env.OutputGamma:=1/2.2;
    Projection:=ToTreeMatrix(RenderContext.ProjectionMatrix);View:=ToTreeMatrix(V);
    Eye:=TreeMath.Vec(Camera.X,Camera.Y,Camera.Z);
    UploadBudget:=2;VisibleCount:=0;
    if Length(FVisibleCells)<FCells.Count then
      SetLength(FVisibleCells,Max(FCells.Count,Length(FVisibleCells)*2));
    for C in FCells do begin
      if not CellInRange(C,LocalCamera) or not Frustum.Box3DCollisionPossibleSimple(C.Bounds) then Continue;
      if not Depth then begin
        for I:=0 to C.Count-1 do begin
          S:=C.Entries[I].Instance.Species;
          if not FShared.HasSeasonLOD(FProfiles[S]) and (FJob=nil) and not FShared.AtlasPending and (FError='') and AtlasRetryReady(S) then begin
            FJob:=TProceduralJob.Create(True);FJob.AtlasJob:=True;FJob.Profile:=FProfiles[S];
            FJob.AtlasDirectory:=FAtlasDir;FJob.Start;Break;
          end;
        end;
        if C.Dirty and (UploadBudget>0) then begin UploadCell(C);Dec(UploadBudget);end;
      end;
      FVisibleCells[VisibleCount]:=C;Inc(VisibleCount);
    end;
    BatchOrigin:=Default(TTreeWorldPosition);
    BatchOrigin.X:=Floor(LocalCamera.X/CELL_METERS)*CELL_METERS;
    BatchOrigin.Z:=Floor(LocalCamera.Z/CELL_METERS)*CELL_METERS;
    Batch:=nil;
    if not VegetationStableFarBuffers then Batch:=FarBatch(FVisibleCells,VisibleCount,BatchOrigin);
    FShared.BeginBatch(Projection,View,Eye,Env,VegetationWindNow);
    M:=WorldTransform*TranslationMatrix(WorldPos(BatchOrigin));Model:=ToTreeMatrix(M);
    if Length(FDrawCells)<VisibleCount then SetLength(FDrawCells,Length(FVisibleCells));
    for I:=0 to VisibleCount-1 do FDrawCells[I]:=FVisibleCells[I];
    if VegetationDepthOrder and (VisibleCount>1) then SortCells(0,VisibleCount-1);
    if not VegetationDepthOrder then RenderFar;
    EntryCount:=0;
    for CellIndex:=0 to VisibleCount-1 do begin
      C:=FDrawCells[CellIndex];
      for I:=0 to C.Count-1 do begin
        D:=C.Entries[I].Detail;if (D=nil) or (D.Renderer=nil) or (D.Quality<=0) then Continue;
        if Depth and (ShadowCapturePartitions>1) and
          (Integer(C.Entries[I].ShadowBucket and Cardinal(ShadowCapturePartitions-1))<>ShadowCapturePartition) then Continue;
        if not Frustum.Box3DCollisionPossibleSimple(C.Entries[I].Bounds) then Continue;
        if EntryCount=Length(FDrawEntries)then SetLength(FDrawEntries,Max(64,EntryCount*2));
        with FDrawEntries[EntryCount]do begin Cell:=C;Entry:=I;Order:=EntryCount;Bin:=Floor(Max(0,(WorldPos(C.Entries[I].Position)-LocalCamera).Length-C.Entries[I].Radius)/16)end;
        Inc(EntryCount);
      end;
    end;
    if VegetationDepthOrder and(EntryCount>1)then SortEntries(0,EntryCount-1);
    for DrawIndex:=0 to EntryCount-1 do begin
        C:=FDrawEntries[DrawIndex].Cell;I:=FDrawEntries[DrawIndex].Entry;D:=C.Entries[I].Detail;
        S:=C.Entries[I].Instance.Species;
        M:=WorldTransform*TranslationMatrix(WorldPos(C.Entries[I].Position));Model:=ToTreeMatrix(M);
        { Visual detail follows the viewer in colour and shadow passes alike.
          Ordinary rides retain stable leaf groups; close inspection adds
          planes/needles without rebuilding the branch hierarchy. }
        DetailDistance:=D.Distance;
        if (FSeconds>=D.SettingsAt) or (DetailDistance<25) then begin
          if DetailDistance<8 then begin D.BranchSides:=7;D.BranchSegments:=4;end
          else if DetailDistance<25 then begin D.BranchSides:=5;D.BranchSegments:=3;end
          else begin D.BranchSides:=3;D.BranchSegments:=2;end;
          if DetailDistance<60 then D.SettingsAt:=FSeconds+0.15*(1+FLoad.Level)
          else D.SettingsAt:=FSeconds+0.3*(1+FLoad.Level);
        end;
        Env.LeafFraction:=D.LeafFraction;
        Env.NeedleDetail:=D.NeedleDetail;
        if not Depth then begin
          Env.BranchSides:=D.BranchSides;Env.BranchSegments:=D.BranchSegments;
        end;
        D.Renderer.Environment:=Env;
        D.Renderer.Render(C.Entries[I].Instance,FProfiles[S],Projection,View,Model,Eye,
          D.Quality,VegetationWindNow,VegetationWindBaseSpeed*0.12,False,False,True,False,False,False);
        Stats:=D.Renderer.Stats;
        if Depth then Inc(FShadowDraws,Stats.DrawCalls) else begin
          Inc(FDrawCalls,Stats.DrawCalls);Inc(FTriangles,Stats.Triangles);Inc(FCrownProxies,Stats.Proxies);
          Inc(FFoliageShoots,Stats.Shoots);
        end;
    end;
    if VegetationDepthOrder then RenderFar;
    if not Depth and (FError='') then QueueDetail;
    if FreshColor then QueueAtlasAhead;
  finally
    if FShared<>nil then FShared.EndBatch;
    RenderContext.DepthRange:=OldRange;
    glUseProgram(OldProgram);glBindVertexArray(OldVAO);glBindBuffer(GL_ARRAY_BUFFER,OldBuffer);
    glActiveTexture(GL_TEXTURE1);glBindTexture(GL_TEXTURE_2D_ARRAY,OldNormalTexture);
    glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_2D_ARRAY,OldTexture);glActiveTexture(OldActive);
    {$ifndef OpenGLES}glPolygonMode(GL_FRONT_AND_BACK,OldPolygon[0]);{$endif}
    glDepthFunc(OldDepthFunc);glDepthMask(OldDepthMask);
    if WasDepth=GL_TRUE then glEnable(GL_DEPTH_TEST) else glDisable(GL_DEPTH_TEST);
    if WasBlend=GL_TRUE then glEnable(GL_BLEND) else glDisable(GL_BLEND);
    if WasCull=GL_TRUE then glEnable(GL_CULL_FACE) else glDisable(GL_CULL_FACE);
  end;
end;
function TOsmProceduralVegetation.Diagnostics:string;
var C:TProceduralCell;D:TProceduralDetail;N,I,Ready,Active,Waiting,CompactCount,Queued,MissingClose,MissingVisible,AtlasPendingCount:Integer;GPU,AtlasPendingMemory:Int64;ArenaUploads:QWord;AtlasLatency:Single;S:TTreeSpecies;Job:TProceduralJob;
begin
  N:=0;for C in FCells do Inc(N,C.Count);GPU:=0;
  if FShared<>nil then GPU:=FShared.LODTextureBytes;
  for I:=Low(FBatches) to High(FBatches) do if FBatches[I]<>nil then
    for S:=Low(S) to High(S) do Inc(GPU,Int64(FBatches[I].Count[S])*64);
  ArenaUploads:=0;
  for S:=Low(S)to High(S)do if FArenas[S]<>nil then begin
    Inc(GPU,FArenas[S].DistantArenaBytes);Inc(ArenaUploads,FArenas[S].DistantArenaUploadBytes);
  end;
  AtlasPendingCount:=0;AtlasPendingMemory:=0;AtlasLatency:=0;
  if FShared<>nil then begin
    AtlasPendingCount:=Ord(FShared.AtlasPending);AtlasPendingMemory:=FShared.AtlasPendingBytes;
    AtlasLatency:=FShared.AtlasUploadLatency;
  end;
  Ready:=0;Active:=0;Waiting:=0;CompactCount:=0;Queued:=0;MissingClose:=0;MissingVisible:=0;
  for Job in FDetailJobs do if Job.ReadyToCollect then Inc(Queued);
  for D in FDetails do begin
    Inc(GPU,D.GPUBytes);
    if D.InRange then begin
      if D.Renderer<>nil then Inc(Ready);
      if D.Wanted>0.35 then begin Inc(Active);if D.Renderer=nil then Inc(Waiting);end;
      if D.Compact then Inc(CompactCount);
      if (D.Distance<25) and (D.Renderer=nil) then Inc(MissingClose);
      if (D.Wanted>0.35) and (D.Renderer=nil) and
        FMainViewFrustum.Box3DCollisionPossibleSimple(D.Cell.Entries[D.Entry].Bounds) then Inc(MissingVisible);
    end;
  end;
  Result:=Format('cells=%d instances=%d near=%d far=%d draws=%d triangles=%d atlases=%d crown_proxies=%d '+
    'generated=%d uploads=%d pending=%d discarded=%d gpu_bytes~=%d season=%.4f shadow_draws=%d '+
    'near_radius_m=%.0f fade_start_m=%.0f preload_m=%.0f near_set=%.8x ready=%d active_near=%d waiting=%d compact=%d '+
    'cache_bytes=%d cache_budget=%d free_vram=%d adapt_level=%d target_fps=%.1f measured_fps=%.1f '+
    'plan_ms=%.0f upload_ms=%.0f foliage_shoots=%d tag_errors=%d texture_only=%d prefetch_m=%.1f motion_mps=%.1f ready_queue=%d waiting_close=%d build_ms=%.2f detail_upload_ms=%.2f detail_upload_max_ms=%.2f upload_budget_ms=%.2f planning_ms=%.2f queue_submit_ms=%.2f waiting_visible=%d error=%s',
    [FCells.Count,N,FDetails.Count,FFarTrees,FDrawCalls,FTriangles,FAtlasCount,FCrownProxies,
     FGenerationCount,FUploadCount,Ord(FJob<>nil)+FDetailJobs.Count,FDiscardedJobs,GPU,FSeason,FShadowDraws,
     ProceduralTreeDistance,VegetationDetail.TreeFadeStart*TreeDistanceScale,TreePreloadDistance,
     FSelectionHash,Ready,Active,Waiting,CompactCount,
     FDetailBytes,FCacheBudget,FFreeVram,FLoad.Level,FTargetFPS,FLoad.MeasuredFPS,
     FLoad.PlanInterval*1000,FLoad.UploadInterval*1000,FFoliageShoots,TreeClassificationErrors,Ord(not ProceduralVegetationActive),FPrefetchOffset.Length,FMotion.Speed,Queued,MissingClose,FBuildMS,FDetailUploadMS,FDetailUploadMaxMS,FLoad.UploadBudgetMS,FPlanMS,FQueueMS,MissingVisible,FError]);
  Result:=Result+Format(' arena_upload_bytes=%d arena_hits=%d atlas_pending=%d atlas_pending_bytes=%d atlas_upload_bytes=%d atlas_published=%d atlas_latency_ms=%.2f season_builds=%d season_hits=%d',
    [ArenaUploads,VegetationArenaHits,AtlasPendingCount,AtlasPendingMemory,VegetationAtlasUploadBytes,VegetationAtlasPublished,AtlasLatency*1000,VegetationTreeSeasonBuilds,VegetationTreeSeasonHits]);
  Result:=Result+Format(' atlas_failures=%d atlas_last_error=%s',[FAtlasFailureCount,FAtlasLastError]);
  Result:=Result+Format(' arena_failures=%d arena_last_error=%s',[FArenaFailures,FArenaLastError]);
end;
function ProceduralVegetationDiagnostics:string;
begin if LastRenderer=nil then Result:='inactive' else Result:=LastRenderer.Diagnostics;end;
end.
