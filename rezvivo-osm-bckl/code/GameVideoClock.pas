unit GameVideoClock;
{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
interface

const VideoFramesPerSecond = 30;
      VideoFrameSeconds = 1.0 / VideoFramesPerSecond;

type
  { Exactly one simulation step per saved frame. Rendering and disk I/O may take
    arbitrarily long. Extra updates wait; extra renders cannot duplicate frames. }
  TOfflineVideoClock = record
    Active, Pending: Boolean;
    Frames: Int64;
    procedure Start;
    procedure Stop;
    function BeginFrame: Single;
    procedure FrameSaved;
    function Seconds: Double;
  end;

var OfflineVideoClock: TOfflineVideoClock;

implementation

procedure TOfflineVideoClock.Start;
begin Active:=True; Pending:=False; Frames:=0 end;
procedure TOfflineVideoClock.Stop;
begin Active:=False; Pending:=False end;
function TOfflineVideoClock.BeginFrame: Single;
begin
  Result:=0;
  if not Active or Pending then Exit;
  Pending:=True;
  Result:=VideoFrameSeconds;
end;
procedure TOfflineVideoClock.FrameSaved;
begin
  if not Active or not Pending then Exit;
  Inc(Frames); Pending:=False;
end;
function TOfflineVideoClock.Seconds: Double;
begin Result:=(Frames+Ord(Pending))/VideoFramesPerSecond end;
end.
