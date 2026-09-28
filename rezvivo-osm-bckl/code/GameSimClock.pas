unit GameSimClock;
{$mode objfpc}{$H+}
interface
const SimFrameSeconds = 1.0 / 60.0;
type
  { The ride owns this clock. FIT, physics and animation consume the same
    delta; no independent wall-clock player can run ahead of the scene. }
  TSimPlaybackClock = class
  private
    FPosition, FDuration: Double;
    FRate: Single;
    FPaused, FPlaying, FStepPending: Boolean;
    FNextFrameTick: QWord;
    FLoop: Cardinal;
    procedure SetRate(Value: Single);
    procedure SetPaused(Value: Boolean);
  public
    constructor Create;
    procedure Start;
    procedure Stop;
    procedure Seek(Seconds: Double);
    procedure Step;
    function Advance(RealSeconds: Single; Tick: QWord): Single;
    function FrameMode: Boolean;
    property Position: Double read FPosition;
    property Duration: Double read FDuration write FDuration;
    property Rate: Single read FRate write SetRate;
    property Paused: Boolean read FPaused write SetPaused;
    property Playing: Boolean read FPlaying;
    property Loop: Cardinal read FLoop;
  end;
implementation
uses Math;
constructor TSimPlaybackClock.Create;
begin inherited; FRate:=1; end;
procedure TSimPlaybackClock.Start;
begin FPlaying:=True; FNextFrameTick:=0; end;
procedure TSimPlaybackClock.Stop;
begin FPlaying:=False; FStepPending:=False; FNextFrameTick:=0; end;
procedure TSimPlaybackClock.SetRate(Value: Single);
begin
  if IsNan(Value) or IsInfinite(Value) then Value:=1;
  FRate:=EnsureRange(Value,Single(SimFrameSeconds),Single(8));
  FNextFrameTick:=0;
end;
procedure TSimPlaybackClock.SetPaused(Value: Boolean);
begin
  if FPaused=Value then Exit;
  FPaused:=Value; FNextFrameTick:=0; FStepPending:=False;
end;
procedure TSimPlaybackClock.Seek(Seconds: Double);
begin
  if IsNan(Seconds) or IsInfinite(Seconds) then Exit;
  FPosition:=EnsureRange(Seconds,0.0,Max(0.0,FDuration-SimFrameSeconds));
  FNextFrameTick:=0; FStepPending:=False;
end;
procedure TSimPlaybackClock.Step;
begin FPaused:=True; FStepPending:=True; end;
function TSimPlaybackClock.FrameMode: Boolean;
begin Result:=FRate<=SimFrameSeconds+0.000001; end;
function TSimPlaybackClock.Advance(RealSeconds: Single; Tick: QWord): Single;
begin
  Result:=0;
  if not FPlaying or (FDuration<=0) then Exit;
  if FStepPending then begin Result:=SimFrameSeconds; FStepPending:=False end
  else if FPaused then Exit
  else if FrameMode then begin
    if FNextFrameTick=0 then begin FNextFrameTick:=Tick+1000; Exit end;
    if Tick<FNextFrameTick then Exit;
    Result:=SimFrameSeconds; FNextFrameTick:=Tick+1000;
  end else begin
    if IsNan(RealSeconds) or IsInfinite(RealSeconds) then Exit;
    { Match the ride's maximum 64 fixed physics steps, including stalls. }
    Result:=EnsureRange(RealSeconds*FRate,Single(0),Single(1));
  end;
  FPosition:=FPosition+Result;
  if FPosition>=FDuration then begin
    FPosition:=FPosition-Floor(FPosition/FDuration)*FDuration; Inc(FLoop);
  end;
end;
end.
