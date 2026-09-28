unit GameSimCameraTrack;
{$mode objfpc}{$H+}
interface
uses CastleVectors;
type
  { Only the displayed view, not scene objects. Each sample is 53 bytes. }
  TSimCameraFrame = packed record
    Seconds: Double;
    Position, Direction, Up: TVector3;
    FieldOfView: Single;
    CameraMode: Byte;
    CinematicMode, PendingMode: ShortInt;
    Chase, CutBefore: Boolean;
  end;
  PSimCameraFrame = ^TSimCameraFrame;
  TSimCameraBlock = array[0..1023] of TSimCameraFrame;
  PSimCameraBlock = ^TSimCameraBlock;
  TSimCameraTrack = class
  private
    FBlocks: array of PSimCameraBlock;
    FCount: Integer;
    function FramePtr(Index: Integer): PSimCameraFrame;
    procedure Compact;
  public
    destructor Destroy; override;
    procedure Clear;
    function Append(const Frame: TSimCameraFrame): Boolean;
    function Sample(Seconds: Double; out Frame: TSimCameraFrame): Boolean;
    function Last: TSimCameraFrame;
    function Latest: Double;
    function MemoryBytes: SizeInt;
    property Count: Integer read FCount;
  end;
implementation
uses Math;
const
  FramesPerBlock = 1024;
  CameraBudget = 32*1024*1024;

destructor TSimCameraTrack.Destroy;
begin Clear; inherited end;

procedure TSimCameraTrack.Clear;
var I: Integer;
begin
  for I:=0 to High(FBlocks) do Dispose(FBlocks[I]);
  FBlocks:=nil; FCount:=0;
end;

function TSimCameraTrack.FramePtr(Index: Integer): PSimCameraFrame;
begin Result:=@FBlocks[Index div FramesPerBlock]^[Index mod FramesPerBlock] end;

function TSimCameraTrack.Last: TSimCameraFrame;
begin
  Result:=Default(TSimCameraFrame);
  if FCount>0 then Result:=FramePtr(FCount-1)^;
end;

function TSimCameraTrack.Latest: Double;
begin
  Result:=0;
  if FCount>0 then Result:=FramePtr(FCount-1)^.Seconds;
end;

function TSimCameraTrack.MemoryBytes: SizeInt;
begin Result:=Length(FBlocks)*(SizeOf(TSimCameraBlock)+SizeOf(Pointer)) end;

procedure TSimCameraTrack.Compact;
var I,N,BlocksNeeded: Integer;
begin
  { Linear compaction, preserving both sides of every cut. Long rides may
    interpolate wider intervals of continuous motion, but never lose a shot.
    The budget is soft if a pathological recording consists entirely of cuts. }
  N:=0;
  for I:=0 to FCount-1 do
    if (I=0) or (I=FCount-1) or FramePtr(I)^.CutBefore or
      FramePtr(Min(I+1,FCount-1))^.CutBefore or ((I and 1)=0) then begin
      FramePtr(N)^:=FramePtr(I)^; Inc(N);
    end;
  FCount:=N;
  BlocksNeeded:=(N+FramesPerBlock-1) div FramesPerBlock;
  for I:=BlocksNeeded to High(FBlocks) do Dispose(FBlocks[I]);
  SetLength(FBlocks,BlocksNeeded);
end;

function TSimCameraTrack.Append(const Frame: TSimCameraFrame): Boolean;
var Value,Previous: TSimCameraFrame; N: Integer;
begin
  Result:=False;
  if IsNan(Frame.Seconds) or IsInfinite(Frame.Seconds) then Exit;
  Value:=Frame;
  if FCount>0 then begin
    Previous:=Last;
    { Rewinding never replaces the future recording. }
    if Frame.Seconds<Previous.Seconds-0.0000001 then Exit;
    Value.CutBefore:=Value.CutBefore or (Frame.CameraMode<>Previous.CameraMode) or
      (Frame.CinematicMode<>Previous.CinematicMode) or (Frame.Chase<>Previous.Chase);
    if Abs(Frame.Seconds-Previous.Seconds)<0.0000001 then begin
      Value.CutBefore:=Value.CutBefore or Previous.CutBefore;
      FramePtr(FCount-1)^:=Value;
      Exit(True);
    end;
  end else Value.CutBefore:=True;
  if (FCount mod FramesPerBlock)=0 then begin
    if MemoryBytes>=CameraBudget then Compact;
    if (FCount mod FramesPerBlock)=0 then begin
      N:=Length(FBlocks); SetLength(FBlocks,N+1); New(FBlocks[N]);
    end;
  end;
  FramePtr(FCount)^:=Value; Inc(FCount); Result:=True;
end;

function TSimCameraTrack.Sample(Seconds: Double; out Frame: TSimCameraFrame): Boolean;
var Lo,Hi,Mid: Integer; A,B: TSimCameraFrame; T: Single; Right: TVector3;
begin
  Result:=False; Frame:=Default(TSimCameraFrame);
  if (FCount=0) or IsNan(Seconds) or IsInfinite(Seconds) or
    (Seconds<FramePtr(0)^.Seconds-0.0000001) or (Seconds>Latest+0.0000001) then Exit;
  Lo:=0; Hi:=FCount-1;
  while Lo<Hi do begin
    Mid:=(Lo+Hi+1) div 2;
    if FramePtr(Mid)^.Seconds<=Seconds+0.0000001 then Lo:=Mid else Hi:=Mid-1;
  end;
  A:=FramePtr(Lo)^; Frame:=A; Result:=True;
  if Lo=FCount-1 then Exit;
  B:=FramePtr(Lo+1)^;
  { A cut belongs to the first displayed frame of the new shot. Holding the
    preceding shot avoids flying through the world when replaying slowly. }
  if B.CutBefore or (Seconds<=A.Seconds) then Exit;
  T:=(Seconds-A.Seconds)/(B.Seconds-A.Seconds);
  Frame.Seconds:=Seconds;
  Frame.Position:=A.Position+(B.Position-A.Position)*T;
  Frame.Direction:=A.Direction+(B.Direction-A.Direction)*T;
  Frame.Up:=A.Up+(B.Up-A.Up)*T;
  if Frame.Direction.LengthSqr>0.000001 then Frame.Direction:=Frame.Direction.Normalize
  else Frame.Direction:=A.Direction;
  Right:=TVector3.CrossProduct(Frame.Direction,Frame.Up);
  if Right.LengthSqr>0.000001 then Frame.Up:=TVector3.CrossProduct(Right.Normalize,Frame.Direction).Normalize
  else Frame.Up:=A.Up;
  Frame.FieldOfView:=A.FieldOfView+(B.FieldOfView-A.FieldOfView)*T;
end;
end.
