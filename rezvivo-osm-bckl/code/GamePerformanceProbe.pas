unit GamePerformanceProbe;

{$mode objfpc}{$H+}

interface

uses Classes, fpjson, CastleUIControls, CastleTimeUtils, CastleGLUtils,
  Osm3dGpuTimer, GameFrameStatistics;

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
    FMemory: TGLMemoryInfo;
    FWall, FCPU, FSubmit, FGPU: TFrameSamples;
    FLast, FBegin: TTimerResult;
    FHaveLast, FReset: Boolean;
    FStarted, FMemoryTick: QWord;
    FFreeKiB, FTotalKiB: Int64;
    procedure ReadMemory;
  public
    constructor Create(AOwner:TComponent);override;
    destructor Destroy;override;
    procedure BeforeRender;override;
    procedure Render;override;
    procedure Snapshot(Dest:TJSONObject; Reset:Boolean);
  end;

implementation

uses SysUtils, Math, CastleGL, GameViewPlay;

constructor TGamePerformanceProbe.Create(AOwner:TComponent);
begin
  inherited;
  Name:='PerformanceProbe';
  FTimer:=TAsyncGpuTimer.Create;
  FWall:=TFrameSamples.Create;FCPU:=TFrameSamples.Create;
  FSubmit:=TFrameSamples.Create;FGPU:=TFrameSamples.Create;
  FFreeKiB:=-1;FTotalKiB:=-1;FReset:=True;
end;

destructor TGamePerformanceProbe.Destroy;
begin
  FTimer.Free;FMemory.Free;
  FWall.Free;FCPU.Free;FSubmit.Free;FGPU.Free;
  inherited;
end;

procedure TGamePerformanceProbe.ReadMemory;
begin
  if GetTickCount64-FMemoryTick<1000 then Exit;
  FMemoryTick:=GetTickCount64;
  if FMemory=nil then FMemory:=TGLMemoryInfo.Create else FMemory.Refresh;
  if FMemory.TotalAvailableMemory>0 then begin
    FTotalKiB:=FMemory.DedicatedVideoMemory;
    FFreeKiB:=FMemory.CurrentAvailableVideoMemory;
  end else if GL_ATI_meminfo then
    FFreeKiB:=Min(FMemory.TextureFreeMemory,FMemory.VboFreeMemory);
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
end;

procedure TGamePerformanceProbe.Render;
var Now:TTimerResult;
begin
  inherited;
  FTimer.EndSample;Now:=Timer;
  FSubmit.Add(TimerSeconds(Now,FBegin)*1000);
  if FHaveLast then FWall.Add(TimerSeconds(Now,FLast)*1000);
  FLast:=Now;FHaveLast:=True;
  if (ViewPlay<>nil) and ViewPlay.SessionAlive then
    FCPU.Add(ViewPlay.FrameLastUpdateMs);
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
begin
  Dest.Add('window_ms',Int64(GetTickCount64-FStarted));
  Dest.Add('capacity',FrameSampleCapacity);
  AddSummary(Dest,'frame',FWall);AddSummary(Dest,'update',FCPU);
  AddSummary(Dest,'render_submit',FSubmit);AddSummary(Dest,'gpu',FGPU);
  Dest.Add('vram_free_kib',FFreeKiB);Dest.Add('vram_total_kib',FTotalKiB);
  Dest.Add('width',Container.PixelsWidth);Dest.Add('height',Container.PixelsHeight);
  if Reset then begin
    { A reporting boundary must not discard the previous frame end or pending
      GPU queries. In particular, the first slow frame after each boundary
      still belongs to the new wall-time sample window. }
    FWall.Clear;FCPU.Clear;FSubmit.Clear;FGPU.Clear;
    FStarted:=GetTickCount64;
  end;
end;

end.
