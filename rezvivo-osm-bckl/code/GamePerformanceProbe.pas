unit GamePerformanceProbe;
{$ifdef ANDROID}{$define OpenGLES}{$endif}

{$mode objfpc}{$H+}

interface

uses Classes, fpjson, CastleUIControls, CastleTimeUtils, CastleGLUtils,
  Osm3dGpuTimer, Osm3dGpuPipelineStats, GameFrameStatistics, GameShaderInvocationAudit;

type
  { Explicit MCP measurement only. No file IO, waits or GPU readbacks that
    wait for completion. BeforeRender precedes all drawing; this topmost
    control's Render closes the query after the world's and HUD's rendering.
    GPU timestamps measure elapsed time, including possible GPU idle time
    while the CPU prepares rendering. Results are assigned to the window in
    which their asynchronous read completes, not necessarily their draw window. }
  TGamePerformanceProbe = class(TCastleUserInterface)
  private
    FTimer: TAsyncGpuTimer;
    FPipeline:TAsyncPipelineStats;
    FShaders:TShaderInvocationAudit;
    FMemory: TGLMemoryInfo;
    FWall, FCPU, FCore, FSubmit, FGPU: TFrameSamples;
    FLast, FBegin: TTimerResult;
    FHaveLast, FReset: Boolean;
    FStarted, FMemoryTick: QWord;
    FFreeKiB, FTotalKiB: Int64;
    FStartCaptures,FStartCacheDraws:QWord;
    procedure ReadMemory;
  public
    constructor Create(AOwner:TComponent);override;
    destructor Destroy;override;
    procedure BeforeRender;override;
    procedure Render;override;
    procedure Snapshot(Dest:TJSONObject; Reset:Boolean);
    procedure EnablePipelineCounters;
    procedure EnableShaderCounters(Frames,Stride:Integer);
  end;

implementation

uses SysUtils, Math, {$ifdef OpenGLES}CastleGLES{$else}CastleGL{$endif}, GameViewPlay, RiderRuntimeAudit, CastleRendererInternalShader;

constructor TGamePerformanceProbe.Create(AOwner:TComponent);
begin
  inherited;
  Name:='PerformanceProbe';
  FTimer:=TAsyncGpuTimer.Create;
  FWall:=TFrameSamples.Create;FCPU:=TFrameSamples.Create;
  FCore:=TFrameSamples.Create;
  FSubmit:=TFrameSamples.Create;FGPU:=TFrameSamples.Create;
  FFreeKiB:=-1;FTotalKiB:=-1;FReset:=True;
  ResetRiderRuntimeAudit;RiderRuntimeAuditActive:=True;
  ProfileSharedEffects:=True;
  SharedEffectCalls:=0;SharedEffectFields:=0;SharedEffectUploads:=0;
  SharedDeformationSkips:=0;
  SharedEffectSeconds:=0;DynamicUniformSeconds:=0;
  RenderShapeSeconds:=0;MeshBeginSeconds:=0;MeshAttributesSeconds:=0;
  MeshPoseSeconds:=0;MeshDrawSeconds:=0;MeshEndSeconds:=0;
  MeshShaderSeconds:=0;MeshTextureSeconds:=0;
  NativeSkinUniformSeconds:=0;LightUniformSeconds:=0;OtherUniformSeconds:=0;
  SharedUploadSeconds:=0;
  FStartCaptures:=CachedMeshCaptures;FStartCacheDraws:=CachedMeshDraws;
end;

destructor TGamePerformanceProbe.Destroy;
begin
  RiderRuntimeAuditActive:=False;
  ProfileSharedEffects:=False;
  FShaders.Free;FPipeline.Free;FTimer.Free;FMemory.Free;
  FWall.Free;FCPU.Free;FCore.Free;FSubmit.Free;FGPU.Free;
  inherited;
end;

procedure TGamePerformanceProbe.EnablePipelineCounters;
begin
  if FShaders<>nil then raise Exception.Create('Choose pipeline or shader counters, not both');
  if FPipeline=nil then FPipeline:=TAsyncPipelineStats.Create;
end;

procedure TGamePerformanceProbe.EnableShaderCounters(Frames,Stride:Integer);
begin
  if FPipeline<>nil then raise Exception.Create('Choose pipeline or shader counters, not both');
  if FShaders=nil then FShaders:=TShaderInvocationAudit.Create(Frames,Stride);
end;

procedure TGamePerformanceProbe.ReadMemory;
begin
  if GetTickCount64-FMemoryTick<1000 then Exit;
  FMemoryTick:=GetTickCount64;
  if FMemory=nil then FMemory:=TGLMemoryInfo.Create else FMemory.Refresh;
  if FMemory.TotalAvailableMemory>0 then begin
    FTotalKiB:=FMemory.DedicatedVideoMemory;
    FFreeKiB:=FMemory.CurrentAvailableVideoMemory;
  end {$ifndef OpenGLES}else if GL_ATI_meminfo then
    FFreeKiB:=Min(FMemory.TextureFreeMemory,FMemory.VboFreeMemory){$endif};
end;

procedure TGamePerformanceProbe.BeforeRender;
var Ns:QWord;
begin
  inherited;
  if FReset then begin
    FTimer.Reset;FHaveLast:=False;FReset:=False;FStarted:=GetTickCount64;
  end;
  while FTimer.ReadSample(Ns) do FGPU.Add(Ns/1000000.0);
  ReadMemory;
  FBegin:=Timer;FTimer.BeginSample;
  if FPipeline<>nil then FPipeline.BeginFrame;
  if FShaders<>nil then FShaders.BeginFrame;
end;

procedure TGamePerformanceProbe.Render;
var Now:TTimerResult;
begin
  inherited;
  if FShaders<>nil then FShaders.EndFrame;
  if FPipeline<>nil then FPipeline.EndFrame;
  FTimer.EndSample;Now:=Timer;
  FSubmit.Add(TimerSeconds(Now,FBegin)*1000);
  if FHaveLast then FWall.Add(TimerSeconds(Now,FLast)*1000);
  FLast:=Now;FHaveLast:=True;
  if (ViewPlay<>nil) and ViewPlay.SessionAlive then
  begin
    FCPU.Add(ViewPlay.FrameLastUpdateMs);
    FCore.Add(ViewPlay.FrameLastCoreUpdateMs);
  end;
end;

procedure AddSummary(Dest:TJSONObject;const Key:string;S:TFrameSamples);
var V:TFrameSummary;O:TJSONObject;
begin
  V:=S.Summary;O:=TJSONObject.Create;Dest.Add(Key,O);
  O.Add('samples',V.Count);O.Add('seen',Int64(V.Seen));
  O.Add('overwritten',Int64(V.Seen-QWord(V.Count)));
  O.Add('rejected',Int64(V.Rejected));
  if V.Count=0 then Exit;
  O.Add('mean_ms',V.MeanMs);O.Add('median_ms',V.MedianMs);
  O.Add('p95_ms',V.P95Ms);O.Add('p99_ms',V.P99Ms);O.Add('max_ms',V.MaxMs);
  O.Add('fps',V.FPS);O.Add('low_1_percent_fps',V.Low1FPS);
end;

procedure TGamePerformanceProbe.Snapshot(Dest:TJSONObject;Reset:Boolean);
var Work,Pipeline:TJSONObject;
begin
  if FShaders<>nil then begin
    Pipeline:=TJSONObject.Create;Dest.Add('shaders',Pipeline);FShaders.Snapshot(Pipeline);
  end;
  if FPipeline<>nil then begin
    Pipeline:=TJSONObject.Create;Dest.Add('pipeline',Pipeline);
    FPipeline.Snapshot(Pipeline,Reset);
  end;
  Work:=TJSONObject.Create;Dest.Add('runtime_work',Work);
  SnapshotRiderRuntimeAudit(Work,Reset);
  Work.Add('shared_effect_calls',Int64(SharedEffectCalls));
  Work.Add('shared_effect_fields',Int64(SharedEffectFields));
  Work.Add('shared_effect_uploads',Int64(SharedEffectUploads));
  Work.Add('deformation_effects_skipped',Int64(SharedDeformationSkips));
  Work.Add('shared_effect_ms',SharedEffectSeconds*1000);
  Work.Add('dynamic_uniform_ms',DynamicUniformSeconds*1000);
  Work.Add('render_shape_ms',RenderShapeSeconds*1000);
  Work.Add('mesh_begin_ms',MeshBeginSeconds*1000);
  Work.Add('mesh_attributes_ms',MeshAttributesSeconds*1000);
  Work.Add('mesh_pose_ms',MeshPoseSeconds*1000);
  Work.Add('mesh_draw_ms',MeshDrawSeconds*1000);
  Work.Add('mesh_end_ms',MeshEndSeconds*1000);
  Work.Add('mesh_shader_ms',MeshShaderSeconds*1000);
  Work.Add('mesh_texture_ms',MeshTextureSeconds*1000);
  Work.Add('native_skin_uniform_ms',NativeSkinUniformSeconds*1000);
  Work.Add('light_uniform_ms',LightUniformSeconds*1000);
  Work.Add('other_uniform_ms',OtherUniformSeconds*1000);
  Work.Add('shared_upload_ms',SharedUploadSeconds*1000);
  if Reset then begin
    SharedEffectCalls:=0;SharedEffectFields:=0;SharedEffectUploads:=0;
    SharedDeformationSkips:=0;
    SharedEffectSeconds:=0;DynamicUniformSeconds:=0;
    RenderShapeSeconds:=0;MeshBeginSeconds:=0;MeshAttributesSeconds:=0;
    MeshPoseSeconds:=0;MeshDrawSeconds:=0;MeshEndSeconds:=0;
    MeshShaderSeconds:=0;MeshTextureSeconds:=0;
    NativeSkinUniformSeconds:=0;LightUniformSeconds:=0;OtherUniformSeconds:=0;
    SharedUploadSeconds:=0;
  end;
  Work.Add('cached_pose_captures',Int64(CachedMeshCaptures-FStartCaptures));
  Work.Add('cached_pose_draws',Int64(CachedMeshDraws-FStartCacheDraws));
  if Reset then begin FStartCaptures:=CachedMeshCaptures;FStartCacheDraws:=CachedMeshDraws end;
  Dest.Add('window_ms',Int64(GetTickCount64-FStarted));
  Dest.Add('capacity',FrameSampleCapacity);
  AddSummary(Dest,'frame',FWall);AddSummary(Dest,'update',FCPU);
  AddSummary(Dest,'update_core',FCore);
  AddSummary(Dest,'render_submit',FSubmit);AddSummary(Dest,'gpu',FGPU);
  Dest.Add('vram_free_kib',FFreeKiB);Dest.Add('vram_total_kib',FTotalKiB);
  Dest.Add('width',Container.PixelsWidth);Dest.Add('height',Container.PixelsHeight);
  if Reset then begin
    { A reporting boundary must not discard the previous frame end or pending
      GPU queries. In particular, the first slow frame after each boundary
      still belongs to the new wall-time sample window. }
    FWall.Clear;FCPU.Clear;FCore.Clear;FSubmit.Clear;FGPU.Clear;
    FStarted:=GetTickCount64;
  end;
end;

end.
