{
  RiderBuildThread — deferred (async) model build queue.

  Processes queued build jobs one per idle tick, yielding to the UI between
  each so the window stays responsive while bike copies are built. Each job
  is a TBuildJob subclass; set Requeue := True inside Execute to put the job
  back at the front of the queue (two-phase jobs).

  License: MIT
}
unit RiderBuildThread;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils;

type
  { ═══════════════════════════════════════════════════════════════════
    TBuildJob — abstract build task, subclass in your form.

    Set Requeue := True in Execute to put the job back at queue front
    instead of freeing it (useful for async two-phase jobs).
    ═══════════════════════════════════════════════════════════════════ }
  TBuildJob = class
  public
    BuildMs: QWord;                      { filled by queue after Execute }
    Requeue: Boolean;                    { set True in Execute to re-enqueue }
    function Execute: Boolean; virtual; abstract;
    destructor Destroy; override;
  end;

  TBuildQueueNotify = procedure(Sender: TObject) of object;

  { ═══════════════════════════════════════════════════════════════════
    TModelBuildQueue — deferred build pipeline.

    Enqueue jobs → queue processes ONE per idle tick (frame).

    Usage:
      Q.Clear;
      Q.Enqueue(TCopyBuildJob.Create(...));
      Q.Enqueue(TCopyBuildJob.Create(...));
      Q.Run;   // queue handles everything from here
    ═══════════════════════════════════════════════════════════════════ }
  TModelBuildQueue = class
  private
    FJobs: TList;                         { TBuildJob items }
    FProcessing: Boolean;                 { re-entrancy guard }
    FJobTimes: TList;                     { QWord pointers — per-job ms }
    FOnAllDone: TBuildQueueNotify;
    procedure ProcessOneJob;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Enqueue(AJob: TBuildJob);       { takes ownership }
    procedure Clear;                          { cancel pending jobs }
    procedure Run;                            { process all jobs, yielding between each }
    function Busy: Boolean;
    function TimingInfo: string;
    property OnAllDone: TBuildQueueNotify read FOnAllDone write FOnAllDone;
  end;

implementation

uses
  BikeParametric,   { BuildYield }
  DebugLog;         { Logger }

{ ═══════════════════════════════════════════════════════════════════
  TBuildJob
  ═══════════════════════════════════════════════════════════════════ }

destructor TBuildJob.Destroy;
begin
  inherited;
end;

{ ═══════════════════════════════════════════════════════════════════
  TModelBuildQueue
  ═══════════════════════════════════════════════════════════════════ }

constructor TModelBuildQueue.Create;
begin
  inherited;
  FJobs := TList.Create;
  FJobTimes := TList.Create;
  FProcessing := False;
  FOnAllDone := nil;
end;

destructor TModelBuildQueue.Destroy;
begin
  Clear;
  FJobTimes.Free;
  FJobs.Free;
  inherited;
end;

procedure TModelBuildQueue.Clear;
var I: Integer;
begin
  { Free pending jobs }
  for I := 0 to FJobs.Count - 1 do
    TBuildJob(FJobs[I]).Free;
  FJobs.Clear;

  { Clear job times }
  for I := 0 to FJobTimes.Count - 1 do
    Dispose(PQWord(FJobTimes[I]));
  FJobTimes.Clear;
end;

procedure TModelBuildQueue.Enqueue(AJob: TBuildJob);
begin
  FJobs.Add(AJob);
end;

procedure TModelBuildQueue.Run;
begin
  if FProcessing then Exit;
  FProcessing := True;
  try
    while FJobs.Count > 0 do
    begin
      ProcessOneJob;

      { Yield: let UI render, process input }
      BuildYield;

      { If a job asked to be requeued, don't spin at 100% CPU }
      if (FJobs.Count > 0) and TBuildJob(FJobs[0]).Requeue then
        Sleep(5);
    end;

    if Assigned(FOnAllDone) then
      FOnAllDone(Self);
  finally
    FProcessing := False;
  end;
end;

function TModelBuildQueue.Busy: Boolean;
begin
  Result := FJobs.Count > 0;
end;

procedure TModelBuildQueue.ProcessOneJob;
var
  Job: TBuildJob;
  T0: QWord;
  P: PQWord;
begin
  if FJobs.Count = 0 then Exit;
  Job := TBuildJob(FJobs[0]);
  FJobs.Delete(0);

  Job.Requeue := False;
  T0 := GetTickCount64;
  try
    Job.Execute;
  except
    on E: Exception do begin
      Logger.Info('[BuildQueue] Job failed: ' + E.Message);
      Job.Requeue := False;
    end;
  end;
  Job.BuildMs := Job.BuildMs + (GetTickCount64 - T0);

  if Job.Requeue then
    { Put back at front — will be checked again next tick }
    FJobs.Insert(0, Job)
  else begin
    New(P);
    P^ := Job.BuildMs;
    FJobTimes.Add(P);
    Job.Free;
  end;
end;

function TModelBuildQueue.TimingInfo: string;
var I: Integer;
begin
  Result := '';
  if FJobTimes.Count > 0 then begin
    Result := Result + 'Jobs[';
    for I := 0 to FJobTimes.Count - 1 do begin
      if I > 0 then Result := Result + ' ';
      Result := Result + Format('%d', [PQWord(FJobTimes[I])^]);
    end;
    Result := Result + ']ms';
  end;
end;

end.
