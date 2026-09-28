unit Osm3dProfiler;

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}{$modeswitch advancedrecords}
{$codepage UTF8}

{ EnableShaderAtomicCounters is a const; when False the associated
  branches are unreachable and T0/T1/Freq stay uninit. Kept intentionally
  for diagnostic builds. }
{$WARN 5057 OFF}

interface

uses
  Classes,
  SysUtils,
  CastleUIControls,
  Windows,
  CastleGL,
  Osm3dGpuAccount,
  Osm3dStudioSettings,
  Osm3dStudioLog,
  CastleScene,
  CastleSceneCore, X3DNodes,
  CastleTransform,
  CastleVectors,
  CastleBoxes,
  CastleFrustum
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
;

const
  { ARB_pipeline_statistics_query tokens — declared locally in case
    CastleGL doesn't export them. GL 4.6 core values. }
  GL_VERTICES_SUBMITTED_ARB          = $82EE;
  GL_PRIMITIVES_SUBMITTED_ARB        = $82EF;
  GL_VERTEX_SHADER_INVOCATIONS_ARB   = $82F0;
  GL_FRAGMENT_SHADER_INVOCATIONS_ARB = $82F4;

  { Atomic-counter slots. Must match `layout(binding=0, offset=N*4)`
    in the shader source. }
  PROF_COUNTER_GROUND     = 0;
  PROF_COUNTER_HOUSES     = 1;
  PROF_COUNTER_SHADOWS    = 2;
  PROF_COUNTER_WATER      = 3;
  PROF_COUNTER_FARTERRAIN = 4;   { not per-tile distance-culled }
  { Vertex-stage counters live in their OWN slots so a category can report
    BOTH fragments (FS slots above) and vertices (VS slots) without the two
    summing into one meaningless number. These read non-zero only if the
    GPU supports vertex-stage atomic counters (GL_MAX_VERTEX_ATOMIC_COUNTERS
    > 0); on GPUs without it they stay 0 — that is itself the diagnostic. }
  PROF_COUNTER_GROUND_VS  = 5;
  PROF_COUNTER_HOUSES_VS  = 6;
  PROF_COUNTER_WATER_VS   = 7;
  PROF_COUNTER_SLOTS      = 8;   { 0..7 all in use now }

type
  TShaderProfiler = class
  strict private
    type
      TSection = record
        Name:   string;
        { Per frame-parity slot, a GROWABLE pool of query objects: one
          pair (VS+FS) per Begin/EndSection bracket opened during that
          frame. The vegetation renderer opens exactly ONE bracket around
          its whole tile loop, so its pool stays at 1. CGE, by contrast,
          calls TProfiledScene.LocalRender once per mounted tile scene
          (and once per render pass), so the 'ground+bld' aggregate is
          bracketed many times a frame; AdvanceFrame SUMS Used[slot] pairs
          into LastVS/FS. Same code path for both — no special case. }
        QVS:    array[0..1] of array of GLuint;
        QFS:    array[0..1] of array of GLuint;
        Submitted: array[0..1] of Boolean;
        Used:   array[0..1] of Integer;   { brackets opened in that slot's frame }
        LastVS, LastFS: Int64;
      end;
  strict private
    FSections:      array of TSection;
    FCount:         Integer;
    FFrameIdx:      Cardinal;
    FActiveSection: Integer;          { -1 = none; nesting not supported }

    { TWO atomic-counter buffers, ping-ponged by frame parity, EACH paired
      with a fence (glFenceSync) so the readback never blocks. The shaders of
      the just-rendered frame wrote one buffer; we drop a fence right after
      its draws and, on a LATER frame, poll that fence with timeout=0 — only
      reading the buffer once the fence reports the GPU is done. If it isn't
      done yet we keep the previous value. This removes the per-frame stall
      that plain glGetBufferSubData caused (it forces the whole command queue
      to drain to the last write, regardless of which buffer is read — which
      is why double-buffering alone didn't help). }
    FAtomicBuf:    array[0..1] of GLuint;
    FAtomicFence:  array[0..1] of GLsync;    { nil = no fence outstanding }
    FAtomicWrite:  Integer;   { which buffer is currently bound for writing }
    FAtomicReady:  Boolean;
    FAtomicLast:   array[0..PROF_COUNTER_SLOTS - 1] of Cardinal;
    FAtomicLabels: array[0..PROF_COUNTER_SLOTS - 1] of string;

    { Microseconds spent in the glGetBufferSubData readback inside
      AdvanceFrame. With the double-buffered (1-frame-lagged) readback this
      should be near-zero; a large value would mean the lag isn't taking
      effect (e.g. driver still serialising) and the readback is stalling. }
    FLastAdvanceMicros: Int64;

    function CurSlot:  Integer; inline;
    function PrevSlot: Integer; inline;
    function FindOrAdd(const AName: string): Integer;
    procedure EnsureAtomicBuffer;
    procedure ContextClose(Sender: TObject);
  public
    constructor Create;
    destructor  Destroy; override;

    { Reads prev-slot results, rotates write slot, reads back & zeros
      atomic counters. Call once per frame between frames (NOT inside a
      Begin/EndSection bracket). Typical hook: TCastleUserInterface.Render
      placed AFTER the viewport. }
    procedure AdvanceFrame;

    { Sections auto-registered on first use. No nesting (silently ignored). }
    procedure BeginSection(const AName: string);
    procedure EndSection;

    { Optional human label for an atomic-counter slot; without it the
      slot is reported as 'slot N'. }
    procedure SetAtomicLabel(Slot: Integer; const ALabel: string);

    property LastAdvanceMicros: Int64 read FLastAdvanceMicros;

    { "trees VS=… FS=…\nground=…\nhouses=…\n…". Newline-separated so a
      long row can't get clipped at the viewport edge. }
    function  FormatStats: string;
  end;

  { Drop-in UI control that calls GlobalShaderProfiler.AdvanceFrame in
    its Render override. Insert AFTER the main viewport in the UI tree. }
  TShaderProfilerTick = class(TCastleUserInterface)
    procedure Render; override;
  end;

var
  GlobalShaderProfiler: TShaderProfiler;
  GpuFrameProfilingEnabled: Boolean = False;

type
  TProfiledScene = class(TCastleScene)
  private
    FTexturePreparedRoot: TX3DRootNode;
    FTexturePreparedAt: QWord;
    FTextureImagesReleased: Boolean;
  public
    { Фоновый монтаж (см. GlobalMountInWorker / TMountWorker в Osm3dStreamingMap).
      Сцена создаётся пустой с Exists=False в основном потоке (CGE инертную
      сцену не трогает), наполняется Scene.Load в отдельном потоке и активируется
      (Exists=True) обратно в main по готовности. MountLoaded ставит фоновый
      поток после успешной загрузки; MountFailed — если Load бросил исключение
      (тогда тайл остаётся скрыт, без падения). }
    MountLoaded: Boolean;
    MountFailed: Boolean;
    MountFinished: LongInt; { publish metadata only after Load/exception cleanup }
    MountAttempts: Integer;
    MountError: String;
    MountRoot: TX3DRootNode; { borrowed from the assembled batch }
    MountErrorHandled, MountActivated: Boolean;
    procedure MountGraph(const Graph: TX3DRootNode);

    class var ThisFrameEntered:     Integer;
    class var ThisFrameDrew:        Integer;
    class var ThisFrameDistCulled:  Integer;
    class var ThisFrameFrustCulled: Integer;
    class var LastFrameEntered:     Integer;
    class var LastFrameDrew:        Integer;
    class var LastFrameDistCulled:  Integer;
    class var LastFrameFrustCulled: Integer;

    { Geometry actually submitted by the DRAWN tiles this frame: sum of CGE
      VerticesCount / TrianglesCount over scenes that passed cull. Separates
      GEOMETRY DUPLICATION (these rise when tiles shrink — shared tile-edge
      verts re-emitted per tile) from DRAW-CALL FRAGMENTATION (these stay
      flat; only 'drew' rises — same geometry split into more draws). }
    class var ThisFrameDrewVerts:   Int64;
    class var ThisFrameDrewTris:    Int64;
    class var LastFrameDrewVerts:   Int64;
    class var LastFrameDrewTris:    Int64;

    procedure LocalRender(const Params: TRenderParams); override;
    procedure GLContextClose; override;
    procedure ReleasePreparedTextureImages;
  end;

  TProfiledSceneTick = class(TCastleUserInterface)
  public
    procedure BeforeRender; override;
    procedure Render; override;
  end;

  { CPU frame profiler: high-resolution (QPC) per-section timing accumulated over a rolling 5-second
    window, emitted as a multi-line log block when the window expires. Wrap work in BeginSection(id,T)
    / try..finally EndSection(id,T); call EndFrame once per frame from a Render hook. Section IDs
    (from RegisterSection) are process-stable — pre-register at init so the hot loop only indexes an
    array, no string lookup. Cost ~30 ns per Begin/End pair, fine even for sub-microsecond chunks. }
  TCpuFrameProfiler = class
  private type
    TSection = record
      Name:        string;
      TotalMicros: Int64;
      Calls:       Int64;
      MaxMicros:   Int64;
    end;
  strict private
    FSections:           array of TSection;
    FSectionCount:       Integer;
    FFrameCount:         Integer;
    FWindowStartCounter: Int64;
    FFreq:               Int64;
    FEnabled:            Boolean;
    FWindowSeconds:      Single;
    FLogSink:            TLogTarget;
    FInitialised:        Boolean;
    { Deferred-emit state. EmitAndReset (called from inside paint) only
      formats and stores the message; FlushPending — called from a
      non-paint context (Update) — does the actual Sink.Write. }
    FPendingMessage:     string;
    FHasPending:         Boolean;
    { Wall-clock frame-period tracking. FLastFrameCounter is the QPC
      value at the previous EndFrame; the delta to the current one is
      the TRUE frame period (render + SwapBuffers + vsync wait +
      everything). Accumulated into FWallTotalMicros / FWallMaxMicros
      so the summary can show how much of each frame is unaccounted
      for by the explicit sections — that gap is SwapBuffers / vsync /
      CGE-internal time. }
    FLastFrameCounter:   Int64;
    FWallTotalMicros:    Int64;
    FWallMaxMicros:      Int64;
    FHaveLastFrame:      Boolean;
    procedure EnsureInit;
    procedure EmitAndReset(WindowMicros: Int64);
  public
    constructor Create;

    { Register a named section and get its stable Id. Safe to call many
      times with the same name — returns the existing Id. }
    function RegisterSection(const AName: string): Integer;

    { Hot path. Start records the QPC start in OutStart; End computes
      the elapsed micros and accumulates. Cheap; no allocations. }
    procedure BeginSection(SectionId: Integer; out OutStart: Int64); inline;
    procedure EndSection(SectionId: Integer; const InStart: Int64); inline;

    { Call once per render frame. Bumps frame counter; if the window
      duration has elapsed, formats summary text into pending buffer
      and resets accumulators. Safe to call from inside paint — does
      NOT touch FLogSink. }
    procedure EndFrame;

    { Drains any pending profiler summary. Returns True and the formatted
      multi-line block in Msg if one is pending (then clears it); False
      otherwise. Call from a non-paint context (e.g. TOsm3dMapTransform
      .Update) and write Msg to the log there. Cheap when nothing pending. }
    function TakePending(out Msg: string): Boolean;

    { Direct one-off write through the log sink — used by ProfilerLog
      for rare lifecycle events. No-op if no sink. }
    procedure LogLifecycle(const Msg: string);

    procedure SetEnabled(V: Boolean);

    property Enabled: Boolean        read FEnabled;
    property WindowSeconds: Single   read FWindowSeconds;
    property FrameCount: Integer     read FFrameCount;
    { Current log sink. Lets a sink owner verify the profiler still
      points at *its* target before clearing it on teardown — avoids
      leaving a dangling FLogSink (use-after-free in ProfilerLog). }
    property LogSink: TLogTarget     read FLogSink;
  end;

function GlobalCpuProfiler: TCpuFrameProfiler;

{ Write a one-off line through the profiler's log sink. For rare
  lifecycle events (texture load, atlas build, shader effect create /
  free) — NOT for per-frame use. No-op if no sink is set. }
procedure ProfilerLog(const Msg: string);

var
  { Section IDs for well-known per-frame measurement points, registered
    in this unit's `initialization`. Other units use these directly
    with GCpuProfiler.BeginSection/EndSection — no string lookup on
    the hot path. }
  CPSection_TileCull:       Integer = -1;  { TProfiledScene.LocalRender cull stage }
  CPSection_TileRender:     Integer = -1;  { TProfiledScene.LocalRender inherited draw }
  CPSection_InstancedTile:  Integer = -1;  { TInstancedBillboardRenderer.LocalRender }
  CPSection_MapUpdate:      Integer = -1;  { TOsm3dMapTransform.Update (whole) }
  CPSection_CameraUniformS: Integer = -1;  { u_camera_pos .Send loop in Update }
  CPSection_QuadCull:       Integer = -1;  { quadtree Exists toggle pass }
  CPSection_InhUpdate:      Integer = -1;  { inherited Update (CGE tree walk) }

type
  { Optional per-frame hook. A subsystem that keeps its own frame
    counters but cannot be referenced from this unit (because it
    depends on this unit) installs a procedure here; TProfiledSceneTick
    .Render calls it once per frame. }
  TFrameBoundaryProc = procedure;

var
  OnFrameBoundary: TFrameBoundaryProc = nil;

  { Published by Osm3dRenderInstanced each frame (via the hook above)
    so EmitAndReset can print them without a circular unit reference.
    InstancedVisited = LocalRender calls; InstancedDrawn = how many
    issued a real glDrawElementsInstanced. }
  ProfInstancedVisited: Integer = 0;
  ProfInstancedDrawn:   Integer = 0;

implementation

uses CastleApplicationProperties, Osm3dGpuTimer;

{ Forward unit-level state used across the file's procedures. Declared
  at the very top of the implementation so TProfiledSceneTick.Render
  and TProfiledScene.LocalRender (which appear before TCpuFrameProfiler
  internals lower down) can resolve the name. }
var
  GCpuProfiler: TCpuFrameProfiler = nil;   { lazy singleton; see GlobalCpuProfiler }

{ k / M / G suffixes; no thousands separator, no decimals below 10k. }
function FormatBigInt(N: Int64): string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(649);{$ENDIF}
  if N < 0 then
    Result := '-' + FormatBigInt(-N)
  else if N < 10000 then
    Result := IntToStr(N)
  else if N < 1000000 then
    Result := Format('%.0fk', [N / 1000.0])
  else if N < 1000000000 then
    Result := Format('%.2fM', [N / 1000000.0])
  else
    Result := Format('%.2fG', [N / 1000000000.0]);
end;

const
  { GL 4.2 core. Declared locally in case CastleGL doesn't expose it. }
  GL_ATOMIC_COUNTER_BUFFER = $92C0;

constructor TShaderProfiler.Create;
var
  I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1223);{$ENDIF}
  inherited;
  ApplicationProperties.OnGLContextCloseObject.Add(@ContextClose);
  FCount         := 0;
  FFrameIdx      := 0;
  FActiveSection := -1;
  FAtomicBuf[0]  := 0;
  FAtomicBuf[1]  := 0;
  FAtomicFence[0] := nil;
  FAtomicFence[1] := nil;
  FAtomicWrite   := 0;
  FAtomicReady   := False;
  FLastAdvanceMicros := 0;
  for I := 0 to PROF_COUNTER_SLOTS - 1 do
  begin
    FAtomicLast[I]   := 0;
    FAtomicLabels[I] := '';
  end;
end;

destructor TShaderProfiler.Destroy;
begin
  ApplicationProperties.OnGLContextCloseObject.Remove(@ContextClose);
  ContextClose(nil);
  inherited;
end;

procedure TShaderProfiler.ContextClose(Sender: TObject);
var
  I, J, K: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1224);{$ENDIF}
  EndSection;
  if FAtomicBuf[0] <> 0 then
  begin
    if Assigned(glDeleteSync) then
    begin
      if FAtomicFence[0] <> nil then glDeleteSync(FAtomicFence[0]);
      if FAtomicFence[1] <> nil then glDeleteSync(FAtomicFence[1]);
    end;
    FAtomicFence[0] := nil;
    FAtomicFence[1] := nil;
    AccDeleteBuffers(2, @FAtomicBuf[0]);
    FAtomicBuf[0] := 0;
    FAtomicBuf[1] := 0;
  end;
  for I := 0 to FCount - 1 do
    for J := 0 to 1 do
    begin
      for K := 0 to High(FSections[I].QVS[J]) do
        if FSections[I].QVS[J][K] <> 0 then
          glDeleteQueries(1, @FSections[I].QVS[J][K]);
      for K := 0 to High(FSections[I].QFS[J]) do
        if FSections[I].QFS[J][K] <> 0 then
          glDeleteQueries(1, @FSections[I].QFS[J][K]);
      FSections[I].QVS[J] := nil;
      FSections[I].QFS[J] := nil;
      FSections[I].Used[J] := 0;
      FSections[I].Submitted[J] := False;
    end;
  FAtomicReady := False; FFrameIdx := 0;
end;

procedure TShaderProfiler.EnsureAtomicBuffer;
const
  ByteSize = PROF_COUNTER_SLOTS * SizeOf(GLuint);
var
  Zeros: array[0..PROF_COUNTER_SLOTS - 1] of GLuint;
  I, B: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(650);{$ENDIF}
  if not EnableShaderAtomicCounters then Exit;
  if FAtomicReady then Exit;
  for I := 0 to PROF_COUNTER_SLOTS - 1 do
    Zeros[I] := 0;
  { Allocate BOTH buffers, zeroed. Which one is bound to binding=0 (the one
    shaders increment) is chosen per-frame in AdvanceFrame; we don't bind
    here. binding=0 is GLOBAL state (not VAO-scoped), so once AdvanceFrame
    binds the frame's buffer it stays bound for every draw that frame. }
  AccGenBuffers(2, @FAtomicBuf[0]);
  for B := 0 to 1 do
  begin
    glBindBuffer(GL_ATOMIC_COUNTER_BUFFER, FAtomicBuf[B]);
    glBufferData(GL_ATOMIC_COUNTER_BUFFER, ByteSize, @Zeros, GL_DYNAMIC_DRAW);
    FAtomicFence[B] := nil;
  end;
  { Bind buffer 0 as the first frame's write target; AdvanceFrame ping-pongs
    from there. binding=0 is GLOBAL state (not VAO-scoped), so it stays bound
    for every draw until AdvanceFrame rebinds it. }
  glBindBufferBase(GL_ATOMIC_COUNTER_BUFFER, 0, FAtomicBuf[0]);
  glBindBuffer(GL_ATOMIC_COUNTER_BUFFER, 0);
  FAtomicWrite := 0;
  FAtomicReady := True;
end;

function TShaderProfiler.CurSlot: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(651);{$ENDIF}
  Result := Integer(FFrameIdx) and 1;
end;

function TShaderProfiler.PrevSlot: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(652);{$ENDIF}
  Result := Integer(FFrameIdx + 1) and 1;
end;

function TShaderProfiler.FindOrAdd(const AName: string): Integer;
var
  I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(653);{$ENDIF}
  for I := 0 to FCount - 1 do
    if FSections[I].Name = AName then Exit(I);
  if FCount >= Length(FSections) then
    SetLength(FSections, FCount + 4);
  FSections[FCount].Name         := AName;
  FSections[FCount].Submitted[0] := False;
  FSections[FCount].Submitted[1] := False;
  FSections[FCount].QVS[0]       := nil;
  FSections[FCount].QVS[1]       := nil;
  FSections[FCount].QFS[0]       := nil;
  FSections[FCount].QFS[1]       := nil;
  FSections[FCount].Used[0]      := 0;
  FSections[FCount].Used[1]      := 0;
  FSections[FCount].LastVS       := 0;
  FSections[FCount].LastFS       := 0;
  Result := FCount;
  Inc(FCount);
end;

procedure TShaderProfiler.AdvanceFrame;
var
  I, Slot, K: Integer;
  V: GLuint64;
  SumVS, SumFS: Int64;
  Zeros: array[0..PROF_COUNTER_SLOTS - 1] of GLuint;
  T0, T1, Freq: Int64;
  WriteBuf, NextWrite: Integer;
  WaitRes: GLenum;
  FenceOk, Ready: Boolean;
  Available: GLuint;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(654);{$ENDIF}
  { Master gate. When shader profiling is off the WHOLE profiler is inert:
    BeginSection/EndSection are no-ops, and here we bail before touching GL,
    so there is zero per-frame cost in production. (Still advance the frame
    index so parity stays monotonic across an enable/disable toggle.) }
  if not EnableShaderAtomicCounters then
  begin
    FLastAdvanceMicros := 0;
    Inc(FFrameIdx);
    Exit;
  end;

  { Pending pools are never reused or read until all their results are
    ready. A slow GPU makes us skip measurements, not stall rendering. }
  for I := 0 to FCount - 1 do
    if FSections[I].Used[CurSlot] > 0 then FSections[I].Submitted[CurSlot] := True;
  for Slot := 0 to 1 do
  for I := 0 to FCount - 1 do
    if FSections[I].Submitted[Slot] then
    begin
      Ready := True;
      for K := 0 to FSections[I].Used[Slot] - 1 do
      begin
        glGetQueryObjectuiv(FSections[I].QVS[Slot][K], GL_QUERY_RESULT_AVAILABLE, @Available);
        if Available = 0 then begin Ready := False; Break end;
        glGetQueryObjectuiv(FSections[I].QFS[Slot][K], GL_QUERY_RESULT_AVAILABLE, @Available);
        if Available = 0 then begin Ready := False; Break end;
      end;
      if not Ready then Continue;
      SumVS := 0; SumFS := 0;
      for K := 0 to FSections[I].Used[Slot] - 1 do
      begin
        glGetQueryObjectui64v(FSections[I].QVS[Slot][K], GL_QUERY_RESULT, @V);
        Inc(SumVS, Int64(V));
        glGetQueryObjectui64v(FSections[I].QFS[Slot][K], GL_QUERY_RESULT, @V);
        Inc(SumFS, Int64(V));
      end;
      FSections[I].LastVS := SumVS; FSections[I].LastFS := SumFS;
      FSections[I].Used[Slot] := 0; FSections[I].Submitted[Slot] := False;
    end;

  { Atomic-counter readback, made NON-BLOCKING with fences.

    Plain glGetBufferSubData is a synchronisation point: the driver drains
    the whole command queue up to the last write of that buffer before
    returning. With vsync off the queue is several frames deep, so even
    reading a 2-frames-old buffer stalled (this is why double-buffering
    alone left a big "sync"). The fix: never read a buffer until a fence
    proves the GPU has passed the point where that buffer was written.

    Per frame:
      WriteBuf  = the buffer the JUST-rendered frame incremented (currently
                  bound). Drop a fence right after its draws.
      NextWrite = the other buffer; it becomes the write target now. Read its
                  prior contents IF its fence has signalled (poll, timeout 0 —
                  never waits): then glGetBufferSubData returns immediately.
                  Either way zero it and bind it as the new write buffer, so
                  both buffers stay in rotation. If the fence hadn't signalled
                  the HUD just misses that sample — no stall either way. }
  {$PUSH}{$WARN 6018 OFF}
  if EnableShaderAtomicCounters then
  begin
    EnsureAtomicBuffer;
    if FAtomicReady then
    begin
      QueryPerformanceCounter(T0);

      { Unconditionally ping-pong the write buffer every frame so both
        buffers stay in rotation (gating the SWAP on the fence could leave
        one buffer never written, hence never read — a deadlock). Only the
        READBACK is fence-gated.

        WriteBuf  = buffer the just-rendered frame incremented (currently
                    bound). Fence it.
        NextWrite = the other buffer; becomes the write target now. Before
                    binding it we want its prior contents (from when it was
                    last the write buffer): read them IF its fence signalled,
                    then zero+bind it. If its fence hasn't signalled we skip
                    the read (keep the last HUD value) but STILL zero+bind it
                    so writing continues — its unread counts are dropped, the
                    HUD just misses that sample. No glGetBufferSubData runs
                    until a fence proves the GPU is done, so no stall. }
      WriteBuf  := FAtomicWrite;
      NextWrite := 1 - WriteBuf;

      if Assigned(glFenceSync) then
      begin
        if FAtomicFence[WriteBuf] <> nil then
          glDeleteSync(FAtomicFence[WriteBuf]);
        FAtomicFence[WriteBuf] :=
          glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
      end;

      { Read NextWrite's prior contents, only if the GPU has finished them. }
      FenceOk := False;
      if (FAtomicFence[NextWrite] <> nil) and Assigned(glClientWaitSync) then
      begin
        begin
          WaitRes := glClientWaitSync(FAtomicFence[NextWrite], 0, 0); { timeout 0 }
          FenceOk := (WaitRes = GL_ALREADY_SIGNALED) or
                     (WaitRes = GL_CONDITION_SATISFIED);
        end;
      end;

      glBindBuffer(GL_ATOMIC_COUNTER_BUFFER, FAtomicBuf[NextWrite]);
      if FenceOk then
      begin
        glGetBufferSubData(GL_ATOMIC_COUNTER_BUFFER, 0,
          PROF_COUNTER_SLOTS * SizeOf(GLuint), @FAtomicLast);
        if Assigned(glDeleteSync) then glDeleteSync(FAtomicFence[NextWrite]);
        FAtomicFence[NextWrite] := nil;
      end;

      { An unfinished previous write must not make the CPU wait while
        zeroing this buffer either. Give it fresh storage in that case. }
      if not FenceOk then
        glBufferData(GL_ATOMIC_COUNTER_BUFFER,
          PROF_COUNTER_SLOTS * SizeOf(GLuint), nil, GL_STREAM_DRAW);
      for I := 0 to PROF_COUNTER_SLOTS - 1 do
        Zeros[I] := 0;
      glBufferSubData(GL_ATOMIC_COUNTER_BUFFER, 0,
        PROF_COUNTER_SLOTS * SizeOf(GLuint), @Zeros);
      glBindBufferBase(GL_ATOMIC_COUNTER_BUFFER, 0, FAtomicBuf[NextWrite]);
      glBindBuffer(GL_ATOMIC_COUNTER_BUFFER, 0);
      FAtomicWrite := NextWrite;

      QueryPerformanceCounter(T1);
      if QueryPerformanceFrequency(Freq) and (Freq > 0) then
        FLastAdvanceMicros := ((T1 - T0) * 1000000) div Freq
      else
        FLastAdvanceMicros := 0;
    end;
  end
  else
    FLastAdvanceMicros := 0;
  {$POP}

  Inc(FFrameIdx);
end;

procedure TShaderProfiler.SetAtomicLabel(Slot: Integer; const ALabel: string);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(655);{$ENDIF}
  if (Slot < 0) or (Slot >= PROF_COUNTER_SLOTS) then Exit;
  FAtomicLabels[Slot] := ALabel;
end;

procedure TShaderProfiler.BeginSection(const AName: string);
var
  Idx, Slot, N: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(657);{$ENDIF}
  { Master gate: profiling off → no-op. Leaving FActiveSection at -1 makes
    the matching EndSection a no-op too, so a begin/end pair can never
    desync even if the flag flips between them. }
  if not EnableShaderAtomicCounters then Exit;
  if FActiveSection >= 0 then Exit;          { nesting not supported }
  Idx  := FindOrAdd(AName);
  Slot := CurSlot;
  if FSections[Idx].Submitted[Slot] then Exit;

  { Take the next free bracket in this frame's pool for the slot, growing
    it by one on demand. Each bracket owns its own VS+FS query so brackets
    that are live across different tile scenes / passes within the frame
    never clobber each other; AdvanceFrame sums them. }
  N := FSections[Idx].Used[Slot];
  if N >= Length(FSections[Idx].QVS[Slot]) then
  begin
    SetLength(FSections[Idx].QVS[Slot], N + 1);
    SetLength(FSections[Idx].QFS[Slot], N + 1);
    FSections[Idx].QVS[Slot][N] := 0;
    FSections[Idx].QFS[Slot][N] := 0;
  end;
  if FSections[Idx].QVS[Slot][N] = 0 then
    glGenQueries(1, @FSections[Idx].QVS[Slot][N]);
  if FSections[Idx].QFS[Slot][N] = 0 then
    glGenQueries(1, @FSections[Idx].QFS[Slot][N]);

  { Two simultaneously active queries of DIFFERENT targets are OK in GL. }
  glBeginQuery(GL_VERTEX_SHADER_INVOCATIONS_ARB,   FSections[Idx].QVS[Slot][N]);
  glBeginQuery(GL_FRAGMENT_SHADER_INVOCATIONS_ARB, FSections[Idx].QFS[Slot][N]);
  FActiveSection := Idx;
end;

procedure TShaderProfiler.EndSection;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(658);{$ENDIF}
  if FActiveSection < 0 then Exit;   { also covers the profiling-off case }
  glEndQuery(GL_FRAGMENT_SHADER_INVOCATIONS_ARB);
  glEndQuery(GL_VERTEX_SHADER_INVOCATIONS_ARB);
  { This bracket is finished — count it so AdvanceFrame sums it next time
    this parity slot is read. CurSlot is stable between Begin and End. }
  Inc(FSections[FActiveSection].Used[CurSlot]);
  FActiveSection := -1;
end;

function TShaderProfiler.FormatStats: string;
var
  I: Integer;
  Lbl: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(659);{$ENDIF}
  Result := '';
  { Profiling off → nothing to report. Keeps the FPS overlay clean and
    makes the disabled state unambiguous (no stale zeros lingering). }
  if not EnableShaderAtomicCounters then Exit;

  for I := 0 to FCount - 1 do
  begin
    if Result <> '' then Result := Result + #10;
    Result := Result + Format('%s VS=%s FS=%s',
      [FSections[I].Name,
       FormatBigInt(FSections[I].LastVS),
       FormatBigInt(FSections[I].LastFS)]);
  end;

  { Atomic counters: only when active — otherwise the permanent zeros
    would mislead rather than inform. The increment site (VS or FS)
    differs per category, so the counter unit is carried in the LABEL
    (set via SetAtomicLabel, e.g. 'houses VS') rather than hardcoded here. }
  {$PUSH}{$WARN 6018 OFF}
  if EnableShaderAtomicCounters then
    for I := 0 to PROF_COUNTER_SLOTS - 1 do
    begin
      Lbl := FAtomicLabels[I];
      if Lbl = '' then Continue;
      if Result <> '' then Result := Result + #10;
      Result := Result + Format('%s=%s',
        [Lbl, FormatBigInt(FAtomicLast[I])]);
    end;
  {$POP}
end;

procedure TShaderProfilerTick.Render;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(660);{$ENDIF}
  inherited;
  if GlobalShaderProfiler <> nil then
    GlobalShaderProfiler.AdvanceFrame;
end;

{ Timestamp pairs bracket the viewport frame. Readiness is polled without
  waiting; the bounded ring drops measurements when the GPU falls behind. }
var
  GFrameTimer: TAsyncGpuTimer = nil;
  GGpuTotalNs: GLuint64 = 0;
  GGpuFrames: Integer = 0;
  GGpuMaxNs: GLuint64 = 0;

procedure GpuFrameTimerTick;
var Ns: QWord;
begin
  if GFrameTimer = nil then Exit;
  GFrameTimer.EndSample;
  while GFrameTimer.ReadSample(Ns) do
  begin
    Inc(GGpuTotalNs, Ns); Inc(GGpuFrames);
    if Ns > GGpuMaxNs then GGpuMaxNs := Ns;
  end;
end;

procedure TProfiledSceneTick.BeforeRender;
begin
  inherited;
  if (GCpuProfiler <> nil) and GCpuProfiler.Enabled and GpuFrameProfilingEnabled then
  begin
    if GFrameTimer = nil then GFrameTimer := TAsyncGpuTimer.Create;
    GFrameTimer.BeginSample;
  end else if GFrameTimer <> nil then GFrameTimer.Reset;
end;

procedure TProfiledScene.GLContextClose;
begin
  FTexturePreparedRoot := nil;
  FTexturePreparedAt := 0;
  FTextureImagesReleased := False;
  inherited;
end;

procedure TProfiledScene.MountGraph(const Graph: TX3DRootNode);
begin
  InterlockedExchange(MountFinished, 0);
  MountLoaded := False; MountFailed := False; MountError := '';
  MountRoot := Graph; Inc(MountAttempts);
  try
    if Graph = nil then raise Exception.Create('Tile scene graph is missing');
    { A failed first mount may have installed part of the root. The batch
      retains it, so detach before retrying without freeing that graph. }
    if RootNode <> nil then Load(nil, False);
    Load(Graph, False);
    MountLoaded := True;
  except
    on E: Exception do
    begin
      MountError := E.ClassName + ': ' + E.Message;
      MountFailed := True;
    end;
  end;
  InterlockedExchange(MountFinished, 1);
end;

procedure TProfiledScene.ReleasePreparedTextureImages;
begin
  { Called by the map on the main thread after assembly/mounting settles.
    Keep a short reuse window for neighbouring tiles. CGE reloads URL images
    if a later context recreation or newly prepared LOD needs them. }
  if FTextureImagesReleased or (FTexturePreparedRoot = nil) or
     (FTexturePreparedRoot <> RootNode) or
     (GetTickCount64 - FTexturePreparedAt < 2000) then Exit;
  FreeResources([frTextureDataInNodes]);
  FTextureImagesReleased := True;
end;

procedure TProfiledScene.LocalRender(const Params: TRenderParams);
{ Two-stage manual cull, replacing CGE's built-in DistanceCulling and
  any implicit frustum culling.
    Stage 1: distance to BoundingBox.Center. CGE's DistanceCulling
      measures to bbox CLOSEST POINT (tall tile bboxes extend close to
      the camera even when their centre is far) — under-rejects; we
      measure to centre to match XZ tile layout.
    Stage 2: frustum test in the scene's local coordinates. CGE's built-in frustum
      culling doesn't fire reliably enough — tile bboxes are taller in Y
      than the camera can see and intersect top/bottom frustum planes
      even when no visible triangles inside.
  Both stages run so we get diagnostic counts of each. }
var
  CamPos, BBCenter: TVector3;
  DistSq, CullSq: Single;
  ShouldRender: Boolean;
  BB: TBox3D;
  RejectReason: Integer;  { 0=none, 1=dist, 2=frustum }
  TCullStart, TInheritStart: Int64;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(661);{$ENDIF}
  Inc(ThisFrameEntered);

  GCpuProfiler.BeginSection(CPSection_TileCull, TCullStart);

  ShouldRender := True;
  RejectReason := 0;

  BB := WorldBoundingBox;
  if BB.IsEmpty then
  begin
    ShouldRender := False;
    RejectReason := 1;
  end;

  if ShouldRender and (DistanceCulling > 0) and (Params.RenderingCamera <> nil) then
  begin
    CamPos := Params.RenderingCamera.View.Translation;
    BBCenter := BB.Center;
    DistSq := Sqr(BBCenter.X - CamPos.X) +
              Sqr(BBCenter.Y - CamPos.Y) +
              Sqr(BBCenter.Z - CamPos.Z);
    CullSq := Sqr(DistanceCulling);
    if DistSq > CullSq then
    begin
      ShouldRender := False;
      RejectReason := 1;
    end;
  end;

  if ShouldRender and (Params.Frustum <> nil) then
  begin
    if Params.Frustum^.Box3DCollisionPossible(LocalBoundingBox) = fcNoCollision then
    begin
      ShouldRender := False;
      RejectReason := 2;
    end;
  end;

  case RejectReason of
    1: Inc(ThisFrameDistCulled);
    2: Inc(ThisFrameFrustCulled);
  end;

  GCpuProfiler.EndSection(CPSection_TileCull, TCullStart);

  if ShouldRender then
  begin
    Inc(ThisFrameDrew);
    { CGE counts are cached per shape — O(active shapes), cheap once/frame. }
    if GCpuProfiler.Enabled then
    begin
      Inc(ThisFrameDrewVerts, Int64(VerticesCount));
      Inc(ThisFrameDrewTris,  Int64(TrianglesCount));
    end;
    GCpuProfiler.BeginSection(CPSection_TileRender, TInheritStart);
    try
      inherited;
      if FTexturePreparedRoot <> RootNode then
      begin
        FTexturePreparedRoot := RootNode;
        FTexturePreparedAt := GetTickCount64;
        FTextureImagesReleased := False;
      end;
    finally
      GCpuProfiler.EndSection(CPSection_TileRender, TInheritStart);
    end;
  end;
end;

procedure TProfiledSceneTick.Render;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(662);{$ENDIF}
  inherited;
  { Whole-frame GPU timer: this tick renders on top, after the viewport's
    tile draws, so closing the query here captures the frame's GPU work. }
  if (GCpuProfiler <> nil) and GCpuProfiler.Enabled and GpuFrameProfilingEnabled then
    GpuFrameTimerTick;
  TProfiledScene.LastFrameEntered     := TProfiledScene.ThisFrameEntered;
  TProfiledScene.LastFrameDrew        := TProfiledScene.ThisFrameDrew;
  TProfiledScene.LastFrameDistCulled  := TProfiledScene.ThisFrameDistCulled;
  TProfiledScene.LastFrameFrustCulled := TProfiledScene.ThisFrameFrustCulled;
  TProfiledScene.LastFrameDrewVerts   := TProfiledScene.ThisFrameDrewVerts;
  TProfiledScene.LastFrameDrewTris    := TProfiledScene.ThisFrameDrewTris;
  TProfiledScene.ThisFrameEntered     := 0;
  TProfiledScene.ThisFrameDrew        := 0;
  TProfiledScene.ThisFrameDistCulled  := 0;
  TProfiledScene.ThisFrameFrustCulled := 0;
  TProfiledScene.ThisFrameDrewVerts   := 0;
  TProfiledScene.ThisFrameDrewTris    := 0;
  { Let any other subsystem publish its per-frame counters too.
    Osm3dRenderInstanced installs a hook here (it can't be referenced
    directly — that unit depends on this one, not vice versa). }
  if Assigned(OnFrameBoundary) then
    OnFrameBoundary();
  { CPU profiler frame boundary. Hosting this here piggy-backs on the
    existing once-per-frame tick — no new TCastleUserInterface needed. }
  if GCpuProfiler <> nil then
    GCpuProfiler.EndFrame;
end;

function GlobalCpuProfiler: TCpuFrameProfiler;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(663);{$ENDIF}
  if GCpuProfiler = nil then
    GCpuProfiler := TCpuFrameProfiler.Create;
  Result := GCpuProfiler;
end;

constructor TCpuFrameProfiler.Create;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1225);{$ENDIF}
  inherited Create;
  FSectionCount  := 0;
  FFrameCount    := 0;
  { Disabled by default. Profiling only makes sense for steady-state
    rendering — during chunk generation the render thread is stalled
    by worker-thread sync (the 0.6 s "frames"), which would pollute
    the statistics and inflate the frame count with non-frames.
    TOsm3dMapTransform enables the profiler once a chunk is applied
    and disables it again when a new generation starts / on teardown. }
  FEnabled       := False;
  FWindowSeconds := 5.0;
  FLogSink       := nil;
  FInitialised   := False;
  FHasPending    := False;
  FPendingMessage := '';
  FLastFrameCounter := 0;
  FWallTotalMicros  := 0;
  FWallMaxMicros    := 0;
  FHaveLastFrame    := False;
  SetLength(FSections, 16);
end;

procedure TCpuFrameProfiler.EnsureInit;
var Now: Int64;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(664);{$ENDIF}
  if FInitialised then Exit;
  if not QueryPerformanceFrequency(FFreq) or (FFreq <= 0) then
  begin
    { Should never happen on Windows; if it does, profiler is dead in the
      water but won't crash — micros stay 0. }
    FEnabled := False;
    Exit;
  end;
  QueryPerformanceCounter(Now);
  FWindowStartCounter := Now;
  FInitialised := True;
end;

function TCpuFrameProfiler.RegisterSection(const AName: string): Integer;
var I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(665);{$ENDIF}
  EnsureInit;
  for I := 0 to FSectionCount - 1 do
    if FSections[I].Name = AName then Exit(I);

  if FSectionCount >= Length(FSections) then
    SetLength(FSections, Length(FSections) * 2);
  FSections[FSectionCount].Name        := AName;
  FSections[FSectionCount].TotalMicros := 0;
  FSections[FSectionCount].Calls       := 0;
  FSections[FSectionCount].MaxMicros   := 0;
  Result := FSectionCount;
  Inc(FSectionCount);
end;

procedure TCpuFrameProfiler.BeginSection(SectionId: Integer;
  out OutStart: Int64);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(666);{$ENDIF}
  if (not FEnabled) or (not FInitialised) then
  begin
    OutStart := 0;
    Exit;
  end;
  QueryPerformanceCounter(OutStart);
end;

procedure TCpuFrameProfiler.EndSection(SectionId: Integer;
  const InStart: Int64);
var
  T1, Elapsed, Micros: Int64;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(667);{$ENDIF}
  if (not FEnabled) or (not FInitialised) or (InStart = 0) then Exit;
  if (SectionId < 0) or (SectionId >= FSectionCount) then Exit;
  QueryPerformanceCounter(T1);
  Elapsed := T1 - InStart;
  if Elapsed < 0 then Exit;
  { (Elapsed * 1_000_000) / Freq — overflow-safe on Int64 for any plausible
    section length: Elapsed < 1e10 ticks (~years) * 1e6 < 1e16, well below
    Int64 max ~9.2e18. }
  Micros := (Elapsed * 1000000) div FFreq;
  Inc(FSections[SectionId].TotalMicros, Micros);
  Inc(FSections[SectionId].Calls);
  if Micros > FSections[SectionId].MaxMicros then
    FSections[SectionId].MaxMicros := Micros;
end;

procedure TCpuFrameProfiler.EndFrame;
var
  Now: Int64;
  WindowElapsed, FrameMicros: Int64;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(668);{$ENDIF}
  if not FEnabled then Exit;
  EnsureInit;
  Inc(FFrameCount);

  QueryPerformanceCounter(Now);

  { True frame period = QPC delta since the previous EndFrame. This
    includes SwapBuffers, vsync wait, LCL message pump, and any CGE
    code not wrapped in an explicit section. Comparing the summed
    section time against this tells us how much is "invisible". }
  if FHaveLastFrame then
  begin
    FrameMicros := ((Now - FLastFrameCounter) * 1000000) div FFreq;
    if FrameMicros > 0 then
    begin
      Inc(FWallTotalMicros, FrameMicros);
      if FrameMicros > FWallMaxMicros then
        FWallMaxMicros := FrameMicros;
    end;
  end;
  FLastFrameCounter := Now;
  FHaveLastFrame := True;

  WindowElapsed := Now - FWindowStartCounter;
  if WindowElapsed >= Int64(Round(FWindowSeconds * FFreq)) then
  begin
    EmitAndReset((WindowElapsed * 1000000) div FFreq);
    QueryPerformanceCounter(FWindowStartCounter);
  end;
end;

procedure TCpuFrameProfiler.EmitAndReset(WindowMicros: Int64);
var
  I:          Integer;
  Avg, Per:   Double;
  WindowMs:   Double;
  FPS:        Double;
  Denom:      Integer;
  Pending:    string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(669);{$ENDIF}
  WindowMs := WindowMicros / 1000.0;
  if FFrameCount > 0 then
    FPS := FFrameCount * 1000.0 / WindowMs
  else
    FPS := 0;

  if FFrameCount > 0 then Denom := FFrameCount else Denom := 1;

  { Build a single multi-line string. ONE Write call to FLogSink means
    one OnLogMessage event, one listview append, one file sync — vs.
    6+ if we wrote per section. The previous per-line approach showed
    up as a visible frame hitch (~50 ms drop, FPS 55→47) every 5 s,
    because the sink does synchronous UI + disk work and we were
    emitting from inside the paint callback. }
  Pending := Format(
    'CpuFrameProfiler %.2f s (%d frames, %.1f FPS):',
    [WindowMs / 1000.0, FFrameCount, FPS]);

  for I := 0 to FSectionCount - 1 do
  begin
    if FSections[I].Calls = 0 then
    begin
      { Still reset MaxMicros for future windows, even if not emitted. }
      FSections[I].TotalMicros := 0;
      FSections[I].MaxMicros   := 0;
      Continue;
    end;
    Avg := FSections[I].TotalMicros / FSections[I].Calls;
    Per := FSections[I].TotalMicros / Denom;
    Pending := Pending + sLineBreak +
      Format('  %-32s total=%7.2f ms  calls=%-9d ' +
             'avg=%7.1f us  max=%7d us  perFrame=%7.1f us  %5.1f/frame',
        [FSections[I].Name,
         FSections[I].TotalMicros / 1000.0,
         FSections[I].Calls,
         Avg, FSections[I].MaxMicros, Per,
         FSections[I].Calls / Denom]);

    { Reset for next window. }
    FSections[I].TotalMicros := 0;
    FSections[I].Calls       := 0;
    FSections[I].MaxMicros   := 0;
  end;

  { Per-frame scene-graph visit counts from the last completed frame.
    'entered' = TProfiledScene.LocalRender calls = how many tile scenes
    CGE actually descended into; 'drew' = how many passed our cull and
    rendered. If 'entered' tracks the TOTAL tile count rather than the
    visible subset, the quadtree Exists pruning is NOT skipping the
    Update/Render walk — that is the "loop over invisible elements". }
  Pending := Pending + sLineBreak +
    Format('  %-32s entered=%-7d drew=%-7d distCulled=%-7d frustCulled=%-7d',
      ['[tile scene visits / frame]',
       TProfiledScene.LastFrameEntered,
       TProfiledScene.LastFrameDrew,
       TProfiledScene.LastFrameDistCulled,
       TProfiledScene.LastFrameFrustCulled]);

  { Geometry submitted by the DRAWN tiles last frame. Compare across
    GEO_TILE_EDGE_PX: verts/tris ~FLAT while 'drew' rises => DRAW-CALL /
    state fragmentation (same geometry, more, smaller draws) — CPU-bound on
    submission, not GPU triangle load. verts/tris RISE with smaller tiles =>
    geometry duplicated (shared tile-edge vertices re-emitted per tile).
    Divide by 'drew' above for the per-tile average. }
  Pending := Pending + sLineBreak +
    Format('  %-32s verts=%-11d tris=%-11d (drew=%d)',
      ['[drawn tile geometry / frame]',
       TProfiledScene.LastFrameDrewVerts,
       TProfiledScene.LastFrameDrewTris,
       TProfiledScene.LastFrameDrew]);

  { Instanced forest/shrub renderer visits. 'visited' = LocalRender
    calls; 'drawn' = real draw calls = glUseProgram state churns. }
  Pending := Pending + sLineBreak +
    Format('  %-32s visited=%-7d drawn=%-7d culled=%-7d',
      ['[instanced renderer / frame]',
       ProfInstancedVisited,
       ProfInstancedDrawn,
       ProfInstancedVisited - ProfInstancedDrawn]);

  FFrameCount := 0;

  { Wall-clock frame period vs. sum of explicit sections. The gap is
    "invisible" time: SwapBuffers, vsync wait, LCL message pump, CGE
    code outside our sections. If this gap is large AND the CPU core
    is pegged at 100%, the vsync wait is a busy-spin (driver doesn't
    block the thread). If the core is NOT pegged, the thread is
    genuinely sleeping in SwapBuffers — normal, healthy vsync. }
  if FHaveLastFrame and (Denom > 0) then
  begin
    Pending := Pending + sLineBreak +
      Format('  %-32s total=%7.2f ms  perFrame=%7.1f us  max=%7d us',
        ['[wall-clock frame period]',
         FWallTotalMicros / 1000.0,
         FWallTotalMicros / Denom,
         FWallMaxMicros]);
    { perFrame wall vs. ~16667 us (60 FPS vsync target) tells the
      story at a glance. }
  end;
  FWallTotalMicros := 0;
  FWallMaxMicros   := 0;

  { Optional timestamp interval around this viewport's render work. It can
    include GPU idle gaps while the CPU submits commands; it is not a measure
    of pure GPU occupancy and does not include the presentation wait. }
  if GGpuFrames > 0 then
  begin
    Pending := Pending + sLineBreak +
      Format('  %-32s total=%7.2f ms  perFrame=%7.1f us  max=%7.1f us  (%d frames)',
        ['[GPU viewport timestamp interval]',
         GGpuTotalNs / 1.0e6,
         (GGpuTotalNs / GGpuFrames) / 1000.0,
         GGpuMaxNs / 1000.0,
         GGpuFrames]);
  end;
  GGpuTotalNs := 0;
  GGpuFrames  := 0;
  GGpuMaxNs   := 0;

  { Hand off the formatted block as a pending message. We CANNOT call
    FLogSink.Write here — EndFrame fires from inside CGE's render
    callback chain (TProfiledSceneTick.Render runs during paint), and
    the log sink chains synchronous UI updates that re-enter the
    Lazarus message pump. That re-entry on the paint thread is the
    actual cause of the visible freeze. The next non-paint caller
    (typically TOsm3dMapTransform.Update on the next CGE world tick)
    flushes via FlushPending below. }
  FPendingMessage := Pending;
  FHasPending := True;
end;

function TCpuFrameProfiler.TakePending(out Msg: string): Boolean;
begin
  Result := FHasPending;
  if Result then
  begin
    Msg := FPendingMessage;
    FPendingMessage := '';
    FHasPending := False;
  end
  else
    Msg := '';
end;

procedure TCpuFrameProfiler.LogLifecycle(const Msg: string);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1618);{$ENDIF}
  if FLogSink <> nil then
    FLogSink.Write(llInfo, Msg);
end;

procedure ProfilerLog(const Msg: string);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1619);{$ENDIF}
  GlobalCpuProfiler.LogLifecycle(Msg);
end;

procedure TCpuFrameProfiler.SetEnabled(V: Boolean);
var I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(672);{$ENDIF}
  if V = FEnabled then Exit;
  FEnabled := V;
  if GFrameTimer <> nil then GFrameTimer.Reset;
  GGpuTotalNs := 0; GGpuFrames := 0; GGpuMaxNs := 0;

  { On either transition, wipe accumulators so a fresh measurement
    window starts clean. Enabling: discard whatever leaked in before
    the profiler was meant to run. Disabling: don't leave a partial
    window to be emitted with stale numbers when re-enabled later. }
  for I := 0 to FSectionCount - 1 do
  begin
    FSections[I].TotalMicros := 0;
    FSections[I].Calls       := 0;
    FSections[I].MaxMicros   := 0;
  end;
  FFrameCount      := 0;
  FWallTotalMicros := 0;
  FWallMaxMicros   := 0;
  FHaveLastFrame   := False;
  FHasPending      := False;
  FPendingMessage  := '';

  if FEnabled and FInitialised then
    QueryPerformanceCounter(FWindowStartCounter);
end;

initialization
  GlobalShaderProfiler := TShaderProfiler.Create;
  TProfiledScene.ThisFrameEntered     := 0;
  TProfiledScene.ThisFrameDrew        := 0;
  TProfiledScene.ThisFrameDistCulled  := 0;
  TProfiledScene.ThisFrameFrustCulled := 0;
  TProfiledScene.LastFrameEntered     := 0;
  TProfiledScene.LastFrameDrew        := 0;
  TProfiledScene.LastFrameDistCulled  := 0;
  TProfiledScene.LastFrameFrustCulled := 0;
  TProfiledScene.ThisFrameDrewVerts   := 0;
  TProfiledScene.ThisFrameDrewTris    := 0;
  TProfiledScene.LastFrameDrewVerts   := 0;
  TProfiledScene.LastFrameDrewTris    := 0;
  { Force creation of the CPU profiler singleton early so BeginSection
    callers don't pay a nil-check + lazy init in the hot loop. Section
    IDs are registered here; consumers grab their ID via the
    CPSection_* unit vars and pass it to Begin/End directly. }
  GlobalCpuProfiler;
  CPSection_TileCull        := GCpuProfiler.RegisterSection('LocalRender (tile cull)');
  CPSection_TileRender      := GCpuProfiler.RegisterSection('LocalRender (tile draw)');
  CPSection_InstancedTile   := GCpuProfiler.RegisterSection('InstancedRender (tile)');
  CPSection_MapUpdate       := GCpuProfiler.RegisterSection('TOsm3dMapTransform.Update');
  CPSection_CameraUniformS  := GCpuProfiler.RegisterSection('u_camera_pos send loop');
  CPSection_QuadCull        := GCpuProfiler.RegisterSection('quadtree cull pass');
  CPSection_InhUpdate       := GCpuProfiler.RegisterSection('inherited Update (CGE walk)');

finalization
  FreeAndNil(GFrameTimer);
  FreeAndNil(GlobalShaderProfiler);
  FreeAndNil(GCpuProfiler);

end.
