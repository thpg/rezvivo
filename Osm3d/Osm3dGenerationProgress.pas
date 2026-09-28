unit Osm3dGenerationProgress;
{$mode objfpc}{$H+}
interface
uses SysUtils, Osm3dWorkerPool;
type
  TGenerationProgressEvent = procedure(const Stage: string;
    Completed, Total: Int64) of object;
  TGenerationProgressContext = record
    Notify: TGenerationProgressEvent;
    Cancel: PBoolean;
  end;
{ Per-worker scope, restored in finally. Pool tasks explicitly inherit Notify. }
threadvar GenerationProgressContext: TGenerationProgressContext;
procedure GenerationProgress(const Stage: string; Completed, Total: Int64);
procedure CheckGenerationCancelled;
procedure GenerationParallelFor(const Stage: string; Count: Integer;
  Proc: TPoolRangeProc; Ctx: Pointer; MinPerThread: Integer = 8192);
implementation
type
  TProgressRange = record
    Stage: string;
    Count, Done: Integer;
    Proc: TPoolRangeProc;
    Ctx: Pointer;
    Context: TGenerationProgressContext;
    Lock: TRTLCriticalSection;
  end;
  PProgressRange = ^TProgressRange;

procedure ProgressRange(Ctx: Pointer; A, B: Integer);
var R: PProgressRange; Previous: TGenerationProgressContext;
begin
  R := PProgressRange(Ctx);
  Previous := GenerationProgressContext;
  { The outer range reports completion. Nested jobs cannot overwrite its stage. }
  GenerationProgressContext.Notify := nil;
  GenerationProgressContext.Cancel := R^.Context.Cancel;
  try
    R^.Proc(R^.Ctx, A, B);
    EnterCriticalSection(R^.Lock);
    try
      Inc(R^.Done, B - A);
      if Assigned(R^.Context.Notify) then
        R^.Context.Notify(R^.Stage, R^.Done, R^.Count);
    finally LeaveCriticalSection(R^.Lock) end;
  finally GenerationProgressContext := Previous end;
end;

procedure GenerationParallelFor(const Stage: string; Count: Integer;
  Proc: TPoolRangeProc; Ctx: Pointer; MinPerThread: Integer);
var R: TProgressRange;
begin
  GenerationProgress(Stage, 0, Count);
  R.Stage := Stage; R.Count := Count; R.Done := 0;
  R.Proc := Proc; R.Ctx := Ctx; R.Context := GenerationProgressContext;
  InitCriticalSection(R.Lock);
  try
    ParallelForPool(Count, @ProgressRange, @R, MinPerThread);
  finally DoneCriticalSection(R.Lock) end;
end;

procedure CheckGenerationCancelled;
begin
  if (GenerationProgressContext.Cancel <> nil) and GenerationProgressContext.Cancel^ then
    raise EAbort.Create('Map generation cancelled');
end;
procedure GenerationProgress(const Stage: string; Completed, Total: Int64);
begin
  { Reporting is not an exception boundary: several legacy geometry phases
    still own temporary meshes. Cancel explicitly only where ownership can
    unwind safely (network fetches, surface queries, object placement). }
  if Assigned(GenerationProgressContext.Notify) then
    GenerationProgressContext.Notify(Stage, Completed, Total);
end;
end.
