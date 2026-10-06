unit Osm3dProceduralVegetation;
{$mode objfpc}{$H+}
interface
uses Classes, SysUtils, Generics.Collections, CastleTransform, CastleVectors,
  CastleBoxes, CastleFrustum, Osm3dTileX3D, Osm3dGeoMath,
  TreeModel, TreeMath, TreeRuntime, TreeRenderer, TreeFoliageLOD,
  CastleGLUtils, Osm3dVegetationBudget, Osm3dRtxShadow;
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
    Quality, Wanted, BuiltQuality, Distance, Weight: Single;
    InRange, Enabled, Compact: Boolean;
    TargetBytes, BuiltBudget, DataBytes, GPUBytes: Int64;
    RetryAt, SettingsAt, LeafFraction, NeedleDetail: Single;
    BranchSides, BranchSegments: Integer;
    destructor Destroy; override;
  end;
  { A single bounded CPU job. Owns its snapshot, never a live cell/GL object. }
  TProceduralJob = class(TThread)
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
    Data: TTreeData;
    procedure Execute; override;
    function ReadyToCollect: Boolean;
    destructor Destroy; override;
  end;
  TOsmProceduralVegetation = class(TCastleTransform)
  private
    FCells: specialize TObjectList<TProceduralCell>;
    FDetails: specialize TObjectList<TProceduralDetail>;
    FBatches: array[0..5] of TProceduralFarBatch;
    FBatchUse: QWord;
    FShared: TTreeRenderer;
    FProfiles: array[TTreeSpecies] of TTreeParams;
    FJob: TProceduralJob;
    FBounds: TBox3D;
    FShaderDir, FAtlasDir, FError: string;
    FSerial: Integer;
    FHooked, FInactive: Boolean;
    FViewer, FLocalViewer, FViewerRight, FSunRayDirection: TVector3;
    FPlanTime, FSeconds, FDelta: Single;
    FGenerationCount, FUploadCount, FDiscardedJobs: QWord;
    FSelectionHash: LongWord;
    FMemory: TGLMemoryInfo;
    FCacheBudget, FDetailBytes, FFreeVram: Int64;
    FMemoryTime, FUploadTime, FTargetFPS: Single;
    FLastRenderTick: QWord;
    FLastColorFrame: Int64;
    FLastColorCamera: TCastleCamera;
    FQualityRevision: Cardinal;
    FLoad: TTreeLoadControl;
    FDrawCalls, FTriangles, FFarTrees, FAtlasCount, FCrownProxies, FFoliageShoots: Integer;
    FShadowDraws: QWord;
    FSeason: Single;
    procedure ContextClose(Sender: TObject);
    procedure PollJob;
    procedure Plan(const Camera: TVector3);
    procedure RefreshMemoryBudget;
    procedure QueueDetail;
    procedure UploadCell(Cell: TProceduralCell);
    procedure ReleaseDetail(Index: Integer);
    procedure RebuildBounds;
    function FarBatch(const Cells:TProceduralCells;const Origin:TTreeWorldPosition):TProceduralFarBatch;
    function CellInRange(Cell: TProceduralCell; const Camera: TVector3): Boolean;
    function FindCell(ID: Integer): TProceduralCell;
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
  end;
function ProceduralVegetationDiagnostics: string;
function ProceduralTreeQuality(const Distance: Single): Single;
implementation
uses {$IFDEF MSWINDOWS}Windows,{$ENDIF} Math, CastleGL, CastleRenderContext, CastleRenderOptions,
  CastleApplicationProperties, CastleUriUtils, Osm3dProceduralTreeData,
  Osm3dStudioSettings, Osm3dRenderInstanced, Osm3dWind, TreeSeason, TreeLOD, CastleLog,
  Osm3dVegetationQuality, CastleTimeUtils, Osm3dRtxMaterials;
const
  CELL_METERS = 128;
var LastRenderer: TOsmProceduralVegetation;

function TOsmProceduralVegetation.CollectRtxTrees(Cache:TRtxShadow;var CellIndex,EntryIndex:Integer):Boolean;
var C:TProceduralCell;E:TProceduralEntry;R:TTreeRenderer;S:TTreeSpecies;M:TMatrix4;P:TVector3;
begin
  Result:=False;if FShared=nil then Exit;
  if FError<>'' then raise Exception.Create('Tree projection cache: '+FError);
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
          if FJob=nil then begin
            FJob:=TProceduralJob.Create(True);FJob.AtlasJob:=True;
            FJob.Profile:=FProfiles[S];FJob.AtlasDirectory:=FAtlasDir;FJob.Start;
          end;
          Exit;
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
begin
  Result:=TreeDistanceQuality(Distance,VegetationDetail.TreeFadeStart*TreeDistanceScale,
    ProceduralTreeDistance);
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
procedure TProceduralJob.Execute;
var Tree:TProceduralTree;
begin
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
      finally Tree.Free;end;
    end;
  except on E: Exception do begin
    Error:=E.Message;
    WriteLnLog('ProceduralTrees',Error);
  end;end;
  InterlockedExchange(FinishedFlag,1);
end;
function TProceduralJob.ReadyToCollect: Boolean;
begin
  Result:=InterlockedCompareExchange(FinishedFlag,0,0)<>0;
  {$IFDEF MSWINDOWS}
  { Execute publishes its data before the OS thread has actually exited.
    Never wait for that remaining tail from inside a render pass. }
  if Result then Result:=WaitForSingleObject(Handle,0)=WAIT_OBJECT_0;
  {$ENDIF}
end;

destructor TProceduralJob.Destroy;
begin
  Terminate;
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
  inherited;
end;

constructor TOsmProceduralVegetation.Create(AOwner: TComponent);
var S: TTreeSpecies;
begin
  inherited;
  FLastColorFrame:=-1;
  FCells:=specialize TObjectList<TProceduralCell>.Create(True);
  FDetails:=specialize TObjectList<TProceduralDetail>.Create(True);
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
  ContextClose(nil);FCells.Free;FDetails.Free;
  inherited;
end;
procedure TOsmProceduralVegetation.ContextClose(Sender: TObject);
var C: TProceduralCell; I: Integer;
begin
  for I:=FDetails.Count-1 downto 0 do ReleaseDetail(I);
  for C in FCells do begin
    C.Dirty:=True;
  end;
  for I:=Low(FBatches) to High(FBatches) do FreeAndNil(FBatches[I]);
  if FShared<>nil then begin FShared.Release;FreeAndNil(FShared);end;
  FAtlasCount:=0;FError:='';
  FreeAndNil(FMemory);FMemoryTime:=0;FLastRenderTick:=0;
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
var I,J: Integer;C: TProceduralCell;
begin
  for I:=FCells.Count-1 downto 0 do begin
    C:=FCells[I];if (C.TileX<>TileX) or (C.TileZ<>TileZ) then Continue;
    for J:=FDetails.Count-1 downto 0 do if FDetails[J].Cell=C then ReleaseDetail(J);
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
  else if GL_ATI_meminfo then
    FFreeVram:=Int64(FMemory.VboFreeMemory)*1024;
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

procedure TOsmProceduralVegetation.Plan(const Camera: TVector3);
type TCandidate=record Cell:TProceduralCell;Entry:Integer;Distance:Single;end;
var Candidates:array of TCandidate;
    N,I,K,ActiveCount:Integer;C:TProceduralCell;D:TProceduralDetail;
    Dist,Preload,TotalWeight,Weight:Single;
  function CacheWeight(Distance:Single):Single;
  begin
    if Distance>=ProceduralTreeDistance then Result:=0.35
    else Result:=1+3*Sqr(1-Distance/Max(1,ProceduralTreeDistance));
  end;
  procedure Sort(L,R:Integer);
  var A,B:Integer;Pivot:Single;Temp:TCandidate;
  begin
    A:=L;B:=R;Pivot:=Candidates[(L+R) div 2].Distance;
    repeat
      while Candidates[A].Distance<Pivot do Inc(A);
      while Candidates[B].Distance>Pivot do Dec(B);
      if A<=B then begin Temp:=Candidates[A];Candidates[A]:=Candidates[B];Candidates[B]:=Temp;Inc(A);Dec(B);end;
    until A>B;
    if L<B then Sort(L,B);if A<R then Sort(A,R);
  end;
begin
  for D in FDetails do begin D.Wanted:=0;D.InRange:=False;D.Enabled:=False;end;
  N:=0;TotalWeight:=0;Preload:=TreePreloadDistance;
  for C in FCells do begin
    { Membership depends on position only; frustum culling is for drawing. }
    if (Abs(Camera.X-C.Origin.X)>Preload*1.12+CELL_METERS) or
       (Abs(Camera.Z-C.Origin.Z)>Preload*1.12+CELL_METERS) then Continue;
    for I:=0 to C.Count-1 do begin
      Dist:=(WorldPos(C.Entries[I].Position)-Camera).Length;
      D:=C.Entries[I].Detail;
      { Build before an atlas enters the visible transition. A small exit
        margin reuses completed buffers when the camera turns or oscillates. }
      if (Dist>Preload) and ((D=nil) or (D.Renderer=nil) or (Dist>Preload*1.12)) then Continue;
      if N=Length(Candidates) then SetLength(Candidates,Max(128,N*2));
      Candidates[N].Cell:=C;Candidates[N].Entry:=I;Candidates[N].Distance:=Dist;Inc(N);
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
    D.InRange:=True;D.Distance:=Dist;D.Weight:=Weight;
    { 10% headroom for replacing buffers and fading trees leaving the circle. }
    D.TargetBytes:=Max(Int64(1024),Min(Int64(2)*1024*1024,
      Trunc(FCacheBudget*0.9*D.Weight/Max(1,TotalWeight))));
    D.TargetBytes:=(D.TargetBytes div 64)*64;
    D.Enabled:=(K<ActiveCount) or (Dist<=25);
    if D.Enabled then D.Wanted:=ProceduralTreeQuality(Dist);
  end;
  FPlanTime:=FSeconds+FLoad.PlanInterval;
end;
procedure TOsmProceduralVegetation.QueueDetail;
var D,Best:TProceduralDetail;Score,BestScore:Single;E:TProceduralEntry;
    NeedsBuild,Reclaim,MemoryPressure:Boolean;
begin
  if (FJob<>nil) or (FSeconds<FUploadTime) then Exit;
  Best:=nil;BestScore:=MaxSingle;MemoryPressure:=FDetailBytes>FCacheBudget*0.90;
  for D in FDetails do if D.InRange and (D.RetryAt<=FSeconds) then begin
    { The camera constantly redistributes target shares. Do not regenerate
      completed trees merely because their share shrank a little: keep the
      old geometry until real cache pressure needs that space. }
    Reclaim:=MemoryPressure and (D.GPUBytes>D.TargetBytes*1.25);
    NeedsBuild:=(D.Enabled and ((D.Renderer=nil) or
      (D.Compact and (D.BuiltBudget<D.TargetBytes*0.7)))) or
      Reclaim;
    if not NeedsBuild then Continue;
    Score:=D.Distance;
    if Reclaim then Score:=-10000-D.Distance; { reclaim distant detail first }
    if Score<BestScore then begin Best:=D;BestScore:=Score;end;
  end;
  if Best=nil then Exit;
  E:=Best.Cell.Entries[Best.Entry];
  FJob:=TProceduralJob.Create(True);FJob.FreeOnTerminate:=False;
  FJob.CellID:=Best.Cell.ID;FJob.Entry:=Best.Entry;FJob.Instance:=E.Instance;
  FJob.Profile:=FProfiles[E.Instance.Species];
  FJob.MaxBytes:=Best.TargetBytes;
  { Generate the complete hierarchy once. Quality only fades between the
    distant quad and actual branches/leaves, with no crown-proxy stage. }
  FJob.Quality:=4;
  FJob.Start;
end;
procedure TOsmProceduralVegetation.PollJob;
var C:TProceduralCell;D:TProceduralDetail;E:TProceduralEntry;Data:TTreeData;
    Bytes,NewBytes:Int64;P:array[0..0]of TTreeWorldPosition;
    Instances:array[0..0]of TreeModel.TTreeInstance;
begin
  if (FJob=nil) or not FJob.ReadyToCollect or
     (FSeconds<FUploadTime) then Exit;
  try
    if FJob.Cancelled then begin Inc(FDiscardedJobs);Exit;end;
    if FJob.Error<>'' then begin FError:=FJob.Error;Exit;end;
    if FJob.AtlasJob then begin
      FShared.UploadLODAtlas(FJob.Atlas);Inc(FAtlasCount);Inc(FUploadCount);
      FUploadTime:=FSeconds+FLoad.UploadInterval;Exit;
    end;
    C:=FindCell(FJob.CellID);
    if (C=nil) or (FJob.Entry>=C.Count) then begin Inc(FDiscardedJobs);Exit;end;
    D:=C.Entries[FJob.Entry].Detail;
    if (D=nil) or not D.InRange then begin Inc(FDiscardedJobs);Exit;end;
    Data:=FJob.Data;Inc(FGenerationCount);
    Bytes:=Int64(Length(Data.Branches))*SizeOf(TTreeBranch)+Int64(Length(Data.Leaves))*SizeOf(TTreeLeaf)+
      Int64(Length(Data.NeedleShoots))*SizeOf(TTreeNeedleShoot)+Int64(Length(Data.Crowns))*SizeOf(TTreeCrown)+
      Int64(Length(Data.Fruits))*SizeOf(TTreeFruit);
    NewBytes:=Int64(Length(Data.Branches)+Length(Data.Leaves)+Length(Data.NeedleShoots)+Length(Data.Crowns)+Length(Data.Fruits))*64+64;
    if (FJob.MaxBytes>D.TargetBytes*1.5) and (NewBytes>D.TargetBytes*1.5) then begin
      { A smaller preset was selected while this snapshot was being built.
        Never upload an obsolete oversized result and immediately rebuild it. }
      Inc(FDiscardedJobs);Exit;
    end;
    if (FDetailBytes-D.GPUBytes+NewBytes>FCacheBudget) and (NewBytes>=D.GPUBytes) then begin
      { A memory-pressure change arrived during generation. Keep any old
        geometry; let the queue compact other trees before retrying this one. }
      D.RetryAt:=FSeconds+0.5;Inc(FDiscardedJobs);Exit;
    end;
    E:=C.Entries[D.Entry];
    if D.Renderer=nil then begin
      D.Renderer:=TTreeRenderer.Create;D.Renderer.Initialize(FShaderDir,FShared);
      Instances[0]:=E.Instance;P[0]:=E.Position;
      D.Renderer.UploadDistantTreesAt(Instances,P,FProfiles[E.Instance.Species],E.Position);
    end;
    D.Renderer.UploadTree(Data);Inc(FUploadCount);D.DataBytes:=Bytes;D.BuiltQuality:=FJob.Quality;
    Inc(FDetailBytes,NewBytes-D.GPUBytes);D.GPUBytes:=NewBytes;
    D.BuiltBudget:=FJob.MaxBytes;D.Compact:=FJob.Compact;
    D.RetryAt:=FSeconds+0.1+0.9*Min(1,D.Distance/ProceduralTreeDistance);
    FUploadTime:=FSeconds+FLoad.UploadInterval;
    { Keep pathological conifers within a per-tree triangle budget. CPU data
      dies with the job; no hierarchy remains for distant or resident details. }
  finally FreeAndNil(FJob);end;
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
    if Changed then begin Cell.FarItems[S]:=PackedItems;Inc(Cell.FarVersion[S]);end;
    Cell.FarCount[S]:=N;
  end;
  Cell.Dirty:=False;Cell.Uploaded:=True;
end;

function TOsmProceduralVegetation.FarBatch(const Cells:TProceduralCells;
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
    Match:=(Length(B.CellIDs)=Length(Cells)) and
      (B.Origin.X=Origin.X) and (B.Origin.Y=Origin.Y) and (B.Origin.Z=Origin.Z);
    if Match then for J:=0 to High(Cells) do
      if B.CellIDs[J]<>Cells[J].ID then begin Match:=False;Break;end;
    if Match then begin Slot:=I;SameCells:=True;Break;end;
  end;
  if FBatches[Slot]=nil then FBatches[Slot]:=TProceduralFarBatch.Create;
  B:=FBatches[Slot];B.LastUse:=FBatchUse;B.Origin:=Origin;
  for S:=Low(S) to High(S) do begin
    Changed:=not SameCells;Rebuild:=not SameCells;N:=0;
    for I:=0 to High(Cells) do begin
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
      for C in Cells do begin CopyCell(C,First);Inc(First,C.FarCount[S]);end;
      B.Renderer[S].UploadDistantItems(PackedItems);Inc(FUploadCount);
    end else begin
      First:=0;
      for I:=0 to High(Cells) do begin
        C:=Cells[I];K:=C.FarCount[S];
        if (K>0) and (B.CellVersions[I][S]<>C.FarVersion[S]) then begin
          SetLength(PackedItems,K);CopyCell(C,0);
          B.Renderer[S].UpdateDistantItems(First,PackedItems);Inc(FUploadCount);
        end;
        Inc(First,K);
      end;
    end;
  end;
  SetLength(B.CellIDs,Length(Cells));SetLength(B.CellVersions,Length(Cells));SetLength(B.CellCounts,Length(Cells));
  for I:=0 to High(Cells) do begin
    B.CellIDs[I]:=Cells[I].ID;B.CellVersions[I]:=Cells[I].FarVersion;B.CellCounts[I]:=Cells[I].FarCount;
  end;
  Result:=B;
end;

procedure TOsmProceduralVegetation.LocalRender(const Params:TRenderParams);
var Projection,View,Model:TTreeMat4;M,V:TMatrix4;Frustum:TFrustum;
    Camera,LocalCamera,Sun,Right:TVector3;Eye:TTreeVec3;Env:TTreeRenderEnvironment;
    Depth,FreshColor:Boolean;C:TProceduralCell;D:TProceduralDetail;S:TTreeSpecies;I,UploadBudget:Integer;
    Instance:TreeModel.TTreeInstance;
    Target,OldQ,DetailDistance,LeafDistance,AdaptiveDetail:Single;
    Stats:TTreeRenderStats;Tick:QWord;OldLevel:Integer;
    OldProgram,OldVAO,OldBuffer,OldActive,OldTexture,OldDepthFunc:GLint;OldRange:TDepthRange;
    OldPolygon:array[0..1]of GLint;Viewport:array[0..3]of GLint;
    WasDepth,WasBlend,WasCull,OldDepthMask:GLBoolean;
    VisibleCells:TProceduralCells;VisibleCount:Integer;Batch:TProceduralFarBatch;BatchOrigin:TTreeWorldPosition;
begin
  if RtxReflectionCaptureActive then Exit;
  if not ProceduralVegetationActive then begin
    if not FInactive then begin
      FInactive:=True;
      { Switching to the legacy atlas renderer must release the procedural
        VRAM cache. Do this once, not on every colour/shadow draw. An active
        CPU job owns only a snapshot; discard it without waiting in the UI. }
      if FJob<>nil then FJob.Cancelled:=True;
      ContextClose(nil);
      for C in FCells do begin
        for S:=Low(S) to High(S) do begin
          C.FarItems[S]:=nil;C.FarCount[S]:=0;Inc(C.FarVersion[S]);
        end;
        C.Uploaded:=False;
      end;
      FPlanTime:=0;FUploadTime:=0;FLoad:=Default(TTreeLoadControl);
    end;
    if (FJob<>nil) and FJob.ReadyToCollect then
      FreeAndNil(FJob);
    Exit;
  end;
  FInactive:=False;
  if not RenderTreesActive or (FCells.Count=0) then Exit;
  Depth:=Params.RenderingCamera.Target=rtShadowMap;
  FreshColor:=not Depth and ((FLastColorFrame<>TFramesPerSecond.RenderFrameId)or
    (FLastColorCamera<>Params.RenderingCamera.Camera));
  V:=Params.RenderingCamera.Matrix;
  Camera:=CameraWorldPosFromView(V);
  if Depth then begin
    if not VegetationShadowViewer(Camera) then Camera:=FViewer;
  end else begin FViewer:=Camera;FViewerRight:=Vector3(V.Data[0,0],0,V.Data[2,0]);end;
  LocalCamera:=WorldInverseTransform.MultPoint(Camera);
  if not Depth then FLocalViewer:=LocalCamera;
  Frustum.Init(RenderContext.ProjectionMatrix*V*WorldTransform);
  if not FHooked then begin ApplicationProperties.OnGLContextCloseObject.Add(@ContextClose);FHooked:=True;end;
  glGetIntegerv(GL_CURRENT_PROGRAM,@OldProgram);glGetIntegerv(GL_VERTEX_ARRAY_BINDING,@OldVAO);
  glGetIntegerv(GL_ARRAY_BUFFER_BINDING,@OldBuffer);glGetIntegerv(GL_ACTIVE_TEXTURE,@OldActive);
  glActiveTexture(GL_TEXTURE0);glGetIntegerv(GL_TEXTURE_BINDING_2D_ARRAY,@OldTexture);
  glGetIntegerv(GL_DEPTH_FUNC,@OldDepthFunc);glGetBooleanv(GL_DEPTH_WRITEMASK,@OldDepthMask);
  glGetIntegerv(GL_POLYGON_MODE,@OldPolygon[0]);glGetIntegerv(GL_VIEWPORT,@Viewport[0]);
  WasDepth:=glIsEnabled(GL_DEPTH_TEST);WasBlend:=glIsEnabled(GL_BLEND);WasCull:=glIsEnabled(GL_CULL_FACE);
  OldRange:=RenderContext.DepthRange;
  try
    if Depth then RenderContext.DepthRange:=drFull;
    if FShared=nil then begin
      if Depth then Exit;
      FShared:=TTreeRenderer.Create;FShared.Initialize(FShaderDir);
    end;
    if not Depth then begin
      LastRenderer:=Self;FDrawCalls:=0;FTriangles:=0;FFarTrees:=0;FCrownProxies:=0;FFoliageShoots:=0;
    end;
    if FreshColor then begin
      { Several world-cache slabs use the same camera in one frame. Measure
        actual frame time and advance adaptation/LOD once, not once per slab. }
      FLastColorFrame:=TFramesPerSecond.RenderFrameId;
      FLastColorCamera:=Params.RenderingCamera.Camera;
      { Cache work follows the viewing camera even when the ride's physics
        time scale is zero or replay is slowed down. Advance once in the
        colour pass; shadow cascades must not advance it again. }
      Tick:=GetTickCount64;
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
      if FSeconds>=FPlanTime then Plan(LocalCamera);
      UploadBudget:=2;
      for I:=FDetails.Count-1 downto 0 do begin
        D:=FDetails[I];OldQ:=D.Quality;
        { Planning and generation may run slowly under load; the actual LOD
          blend follows today's camera every colour frame, never a stale
          0.25..1 s plan distance. This also serves off-screen cached trees. }
        D.Distance:=(WorldPos(D.Cell.Entries[D.Entry].Position)-LocalCamera).Length;
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
    Env.DirectBranches:=True;
    Env.ViewportHeight:=Max(1,Viewport[3]);
    if Depth then begin Env.BranchSides:=4;Env.BranchSegments:=2;end
    else begin Env.BranchSides:=5;Env.BranchSegments:=3;end;
    Env.SunDirection:=TreeMath.Vec(Sun.X,Sun.Y,Sun.Z);
    Env.BillboardRight:=TreeMath.Vec(Right.X,Right.Y,Right.Z);
    Env.OutputGamma:=1/2.2; { game postprocessing supplies distance fog }
    Projection:=ToTreeMatrix(RenderContext.ProjectionMatrix);View:=ToTreeMatrix(V);
    Eye:=TreeMath.Vec(Camera.X,Camera.Y,Camera.Z);
    UploadBudget:=2;VisibleCount:=0;SetLength(VisibleCells,FCells.Count);
    for C in FCells do begin
      if not CellInRange(C,LocalCamera) or not Frustum.Box3DCollisionPossibleSimple(C.Bounds) then Continue;
      if not Depth then begin
        for I:=0 to C.Count-1 do begin
          S:=C.Entries[I].Instance.Species;
          if not FShared.HasSeasonLOD(FProfiles[S]) and (FJob=nil) and (FError='') then begin
            FJob:=TProceduralJob.Create(True);FJob.AtlasJob:=True;FJob.Profile:=FProfiles[S];
            FJob.AtlasDirectory:=FAtlasDir;FJob.Start;Break;
          end;
        end;
        if C.Dirty and (UploadBudget>0) then begin UploadCell(C);Dec(UploadBudget);end;
      end;
      VisibleCells[VisibleCount]:=C;Inc(VisibleCount);
    end;
    SetLength(VisibleCells,VisibleCount);
    BatchOrigin:=Default(TTreeWorldPosition);
    BatchOrigin.X:=Floor(LocalCamera.X/CELL_METERS)*CELL_METERS;
    BatchOrigin.Z:=Floor(LocalCamera.Z/CELL_METERS)*CELL_METERS;
    Batch:=FarBatch(VisibleCells,BatchOrigin);
    M:=WorldTransform*TranslationMatrix(WorldPos(BatchOrigin));Model:=ToTreeMatrix(M);
    for S:=Low(S) to High(S) do if (Batch.Renderer[S]<>nil) and (Batch.Count[S]>0) then begin
        Batch.Renderer[S].Environment:=Env;
        Instance:=Default(TreeModel.TTreeInstance);Instance.TypeCode:=PackTreeType(S);
        Batch.Renderer[S].Render(Instance,FProfiles[S],Projection,View,Model,Eye,
          0,WindNow,WindCurrentBaseSpeed*0.12,False,False,True,False,True,False);
        Stats:=Batch.Renderer[S].Stats;
        if Depth then Inc(FShadowDraws,Stats.DrawCalls) else begin
          Inc(FDrawCalls,Stats.DrawCalls);Inc(FTriangles,Stats.Triangles);Inc(FFarTrees,Stats.FarTrees);
        end;
    end;
    for C in VisibleCells do begin
      for I:=0 to C.Count-1 do begin
        D:=C.Entries[I].Detail;if (D=nil) or (D.Renderer=nil) or (D.Quality<=0) then Continue;
        if not Frustum.Box3DCollisionPossibleSimple(C.Entries[I].Bounds) then Continue;
        S:=C.Entries[I].Instance.Species;
        M:=WorldTransform*TranslationMatrix(WorldPos(C.Entries[I].Position));Model:=ToTreeMatrix(M);
        { Broadleaf blades are unthinned within 12 m; needles recover their
          full density within 6 m. Shadows use the same viewer distance.
          The branch hierarchy stays complete. }
        DetailDistance:=D.Distance;
        if (FSeconds>=D.SettingsAt) or (DetailDistance<25) then begin
          DetailDistance:=(WorldPos(C.Entries[I].Position)-LocalCamera).Length;
          LeafDistance:=12*VegetationDetail.TreeDetailScale;
          D.LeafFraction:=Max(VegetationDetail.TreeMinLeafFraction,
            Sqr(LeafDistance/Max(LeafDistance,DetailDistance)));
          D.NeedleDetail:=NearNeedleDetail(DetailDistance/Max(0.1,VegetationDetail.TreeDetailScale));
          if DetailDistance<8 then begin D.BranchSides:=7;D.BranchSegments:=4;end
          else if DetailDistance<25 then begin D.BranchSides:=5;D.BranchSegments:=3;end
          else begin D.BranchSides:=3;D.BranchSegments:=2;end;
          if DetailDistance<60 then D.SettingsAt:=FSeconds+0.15*(1+FLoad.Level)
          else D.SettingsAt:=FSeconds+0.3*(1+FLoad.Level);
        end;
        Env.LeafFraction:=D.LeafFraction;
        Env.NeedleDetail:=D.NeedleDetail;
        if DetailDistance>25 then begin
          AdaptiveDetail:=FLoad.DetailFraction;
          if VegetationDetail.TreeStableRange then AdaptiveDetail:=Max(0.75,AdaptiveDetail);
          Env.LeafFraction:=Env.LeafFraction*AdaptiveDetail;
        end;
        if not Depth then begin
          Env.BranchSides:=D.BranchSides;Env.BranchSegments:=D.BranchSegments;
        end;
        D.Renderer.Environment:=Env;
        D.Renderer.Render(C.Entries[I].Instance,FProfiles[S],Projection,View,Model,Eye,
          D.Quality,WindNow,WindCurrentBaseSpeed*0.12,False,False,True,False,False,False);
        Stats:=D.Renderer.Stats;
        if Depth then Inc(FShadowDraws,Stats.DrawCalls) else begin
          Inc(FDrawCalls,Stats.DrawCalls);Inc(FTriangles,Stats.Triangles);Inc(FCrownProxies,Stats.Proxies);
          Inc(FFoliageShoots,Stats.Shoots);
        end;
      end;
    end;
    if not Depth and (FError='') then QueueDetail;
  finally
    RenderContext.DepthRange:=OldRange;
    glUseProgram(OldProgram);glBindVertexArray(OldVAO);glBindBuffer(GL_ARRAY_BUFFER,OldBuffer);
    glActiveTexture(GL_TEXTURE0);glBindTexture(GL_TEXTURE_2D_ARRAY,OldTexture);glActiveTexture(OldActive);
    glPolygonMode(GL_FRONT_AND_BACK,OldPolygon[0]);glDepthFunc(OldDepthFunc);glDepthMask(OldDepthMask);
    if WasDepth=GL_TRUE then glEnable(GL_DEPTH_TEST) else glDisable(GL_DEPTH_TEST);
    if WasBlend=GL_TRUE then glEnable(GL_BLEND) else glDisable(GL_BLEND);
    if WasCull=GL_TRUE then glEnable(GL_CULL_FACE) else glDisable(GL_CULL_FACE);
  end;
end;
function TOsmProceduralVegetation.Diagnostics:string;
var C:TProceduralCell;D:TProceduralDetail;N,I,Ready,Active,Waiting,CompactCount:Integer;GPU:Int64;S:TTreeSpecies;
begin
  N:=0;for C in FCells do Inc(N,C.Count);GPU:=Int64(FAtlasCount)*8*1024*1024;
  for I:=Low(FBatches) to High(FBatches) do if FBatches[I]<>nil then
    for S:=Low(S) to High(S) do Inc(GPU,Int64(FBatches[I].Count[S])*64);
  Ready:=0;Active:=0;Waiting:=0;CompactCount:=0;
  for D in FDetails do begin
    Inc(GPU,D.GPUBytes);
    if D.InRange then begin
      if D.Renderer<>nil then Inc(Ready);
      if D.Wanted>0.35 then begin Inc(Active);if D.Renderer=nil then Inc(Waiting);end;
      if D.Compact then Inc(CompactCount);
    end;
  end;
  Result:=Format('cells=%d instances=%d near=%d far=%d draws=%d triangles=%d atlases=%d crown_proxies=%d '+
    'generated=%d uploads=%d pending=%d discarded=%d gpu_bytes~=%d season=%.4f shadow_draws=%d '+
    'near_radius_m=%.0f fade_start_m=%.0f preload_m=%.0f near_set=%.8x ready=%d active_near=%d waiting=%d compact=%d '+
    'cache_bytes=%d cache_budget=%d free_vram=%d adapt_level=%d target_fps=%.1f measured_fps=%.1f '+
    'plan_ms=%.0f upload_ms=%.0f foliage_shoots=%d tag_errors=%d error=%s',
    [FCells.Count,N,FDetails.Count,FFarTrees,FDrawCalls,FTriangles,FAtlasCount,FCrownProxies,
     FGenerationCount,FUploadCount,Ord(FJob<>nil),FDiscardedJobs,GPU,FSeason,FShadowDraws,
     ProceduralTreeDistance,VegetationDetail.TreeFadeStart*TreeDistanceScale,TreePreloadDistance,
     FSelectionHash,Ready,Active,Waiting,CompactCount,
     FDetailBytes,FCacheBudget,FFreeVram,FLoad.Level,FTargetFPS,FLoad.MeasuredFPS,
     FLoad.PlanInterval*1000,FLoad.UploadInterval*1000,FFoliageShoots,TreeClassificationErrors,FError]);
end;
function ProceduralVegetationDiagnostics:string;
begin if LastRenderer=nil then Result:='inactive' else Result:=LastRenderer.Diagnostics;end;
end.
