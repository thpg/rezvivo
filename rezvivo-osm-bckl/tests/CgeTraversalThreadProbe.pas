program CgeTraversalThreadProbe;
{$mode objfpc}{$H+}
uses Classes, SysUtils, SyncObjs, X3DNodes;

type
  TProbe = class;
  TWorker = class(TThread)
    Probe: TProbe;
    procedure Execute; override;
  end;
  TProbe = class
    MainRoot, WorkerRoot: TX3DRootNode;
    BeginWorker, WorkerInside, ReleaseWorker, WorkerDone: TEvent;
    WorkerStack: TX3DGraphTraverseStateStack;
    Failed: Boolean;
    function MainVisit(Node: TX3DNode; Stack: TX3DGraphTraverseStateStack;
      Parent: PTraversingInfo; var VisitChildren: Boolean): Pointer;
    function WorkerVisit(Node: TX3DNode; Stack: TX3DGraphTraverseStateStack;
      Parent: PTraversingInfo; var VisitChildren: Boolean): Pointer;
  end;

function TProbe.WorkerVisit(Node: TX3DNode; Stack: TX3DGraphTraverseStateStack;
  Parent: PTraversingInfo; var VisitChildren: Boolean): Pointer;
begin
  WorkerStack := Stack;
  WorkerInside.SetEvent;
  if ReleaseWorker.WaitFor(5000) <> wrSignaled then
    raise Exception.Create('Main traversal did not release worker');
  Result := nil;
end;

function TProbe.MainVisit(Node: TX3DNode; Stack: TX3DGraphTraverseStateStack;
  Parent: PTraversingInfo; var VisitChildren: Boolean): Pointer;
var SavedTop: TX3DGraphTraverseState;
begin
  SavedTop := Stack.Top;
  BeginWorker.SetEvent;
  try
    if WorkerInside.WaitFor(5000) <> wrSignaled then
      raise Exception.Create('Worker traversal did not enter');
    { Keep both traversals active: independent graphs must not share mutable
      traversal state. This fails deterministically with TraverseSingleStack. }
    Failed := Failed or (Stack = WorkerStack) or (Stack.Top <> SavedTop);
  finally
    ReleaseWorker.SetEvent;
  end;
  if WorkerDone.WaitFor(5000) <> wrSignaled then
    raise Exception.Create('Worker traversal did not finish');
  Failed := Failed or (Stack.Top <> SavedTop);
  Result := nil;
end;

procedure TWorker.Execute;
var I: Integer;
begin
  for I := 1 to 100 do
  begin
    if Probe.BeginWorker.WaitFor(5000) <> wrSignaled then
      raise Exception.Create('Main traversal did not start');
    Probe.WorkerRoot.Traverse(TX3DRootNode, @Probe.WorkerVisit);
    Probe.WorkerDone.SetEvent;
  end;
end;

var P: TProbe; W: TWorker; I: Integer;
begin
  P := TProbe.Create;
  P.MainRoot := TX3DRootNode.Create;
  P.WorkerRoot := TX3DRootNode.Create;
  P.BeginWorker := TEvent.Create(nil, False, False, '');
  P.WorkerInside := TEvent.Create(nil, False, False, '');
  P.ReleaseWorker := TEvent.Create(nil, False, False, '');
  P.WorkerDone := TEvent.Create(nil, False, False, '');
  W := TWorker.Create(True);
  W.Probe := P;
  W.Start;
  for I := 1 to 100 do P.MainRoot.Traverse(TX3DRootNode, @P.MainVisit);
  W.WaitFor;
  if W.FatalException <> nil then raise Exception.Create('Worker exception');
  W.Free;
  P.MainRoot.Free; P.WorkerRoot.Free;
  P.BeginWorker.Free; P.WorkerInside.Free;
  P.ReleaseWorker.Free; P.WorkerDone.Free;
  if P.Failed then begin
    Writeln('FAIL: concurrent detached graphs shared a traversal stack');
    P.Free;
    Halt(1);
  end;
  P.Free;
  Writeln('PASS: 100 overlapping traversals have independent state');
end.
