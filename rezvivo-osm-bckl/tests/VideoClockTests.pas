program VideoClockTests;
{$mode objfpc}{$H+}
uses SysUtils, Math, GameVideoClock, GameSimClock;
var C:TOfflineVideoClock; Sim:TSimPlaybackClock; I:Integer;
    Dt:Single; Sum:Double; Tick:QWord;
procedure Check(B:Boolean; const S:String);
begin if not B then raise Exception.Create(S) end;
begin
  C:=Default(TOfflineVideoClock); C.Start;
  Sim:=TSimPlaybackClock.Create;
  try
    Sim.Duration:=3600; Sim.Start; Sum:=0; Tick:=0;
    for I:=1 to 900 do begin
      { Alternating fast render, 2-second stalls and duplicate updates. }
      if I mod 3=0 then Inc(Tick,2000) else Inc(Tick,2);
      Dt:=C.BeginFrame; Sum:=Sum+Dt;
      Check(Abs(Dt-1/30)<1e-7,'fixed frame delta');
      Sim.Advance(Dt,Tick,True);
      Check(C.BeginFrame=0,'no advance before saving the pending frame');
      C.FrameSaved; C.FrameSaved;
      Check(C.Frames=I,'duplicate renders cannot add frames');
    end;
    Check(Abs(C.Seconds-30)<1e-9,'video length uses completed frames');
    Check(Abs(Sum-30)<0.00001,'scene virtual time is independent of wall time');
    Check(Abs(Sim.Position-30)<0.00001,'FIT has the same virtual time');
    Sim.Rate:=SimFrameSeconds;
    for I:=1 to 1800 do Sim.Advance(1/30,0,True);
    Check(Abs(Sim.Position-31)<0.00001,'slow motion is independent of wall-time frame hold');
    Sim.Paused:=True; Check(Sim.Advance(1/30,0,True)=0,'paused FIT stays paused');
    C.Stop; Check(C.BeginFrame=0,'stop clears pending step');
    C.Start; Check((C.Frames=0)and(C.Seconds=0),'second recording has a new timeline');
    Writeln('Video clock tests passed: stalls, duplicate updates/renders, FIT, slow motion, pause, restart.');
  finally Sim.Free end;
end.
