unit GameStreamingRetirement;
{$mode objfpc}{$H+}
interface
uses Osm3dStreamingLauncher;
{ Caller detaches the map from viewports first. Takes ownership and nils it. }
procedure RetireStreamingSession(var Session:TOsm3dStreamingSession);
{ Before Castle components / OSM units shut down. }
procedure ShutdownStreamingRetirement;
implementation
uses Classes,SysUtils,CastleApplicationProperties,CastleLog;
type
  TRetirementTask=class(TThread)
  public
    Session:TOsm3dStreamingSession;
    constructor Create(A:TOsm3dStreamingSession);
    procedure Execute;override;
  end;
  TRetirementQueue=class
  private
    FTasks:TList;
    procedure Tick(Sender:TObject);
  public
    constructor Create;
    destructor Destroy;override;
    procedure Add(A:TOsm3dStreamingSession);
  end;
var Queue:TRetirementQueue;ShuttingDown:Boolean;
constructor TRetirementTask.Create(A:TOsm3dStreamingSession);
begin inherited Create(True);Session:=A;Start end;
procedure TRetirementTask.Execute;
begin
  { Only waits and writes ready CPU tile records. All scene/texture
    destruction stays in Tick on the main thread with its GL context. }
  try Session.Map.JoinBackgroundStop;
  except on E:Exception do
    WritelnLog('StreamingRetirement','Background shutdown: '+E.Message);
  end;
end;
constructor TRetirementQueue.Create;
begin
  inherited;FTasks:=TList.Create;
  ApplicationProperties.OnUpdate.Add(@Tick);
end;
procedure TRetirementQueue.Add(A:TOsm3dStreamingSession);
begin
  A.Map.RequestBackgroundStop;
  FTasks.Add(TRetirementTask.Create(A));
end;
procedure TRetirementQueue.Tick(Sender:TObject);
var I:Integer;Task:TRetirementTask;Session:TOsm3dStreamingSession;
begin
  for I:=FTasks.Count-1 downto 0 do begin
    Task:=TRetirementTask(FTasks[I]);
    if not Task.Finished then Continue;
    FTasks.Delete(I);Session:=Task.Session;Task.Free;
    Session.Free;
    Break; { bound main-thread scene destruction to one retired session/frame }
  end;
end;
destructor TRetirementQueue.Destroy;
var I:Integer;Task:TRetirementTask;
begin
  ApplicationProperties.OnUpdate.Remove(@Tick);
  for I:=0 to FTasks.Count-1 do begin
    Task:=TRetirementTask(FTasks[I]);Task.WaitFor;Task.Session.Free;Task.Free;
  end;
  FTasks.Free;inherited;
end;
procedure RetireStreamingSession(var Session:TOsm3dStreamingSession);
begin
  if Session=nil then Exit;
  if ShuttingDown then begin FreeAndNil(Session);Exit end;
  if Queue=nil then Queue:=TRetirementQueue.Create;
  Queue.Add(Session);Session:=nil;
end;
procedure ShutdownStreamingRetirement;
begin ShuttingDown:=True;FreeAndNil(Queue) end;
finalization
  ShutdownStreamingRetirement;
end.
