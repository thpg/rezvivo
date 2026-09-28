unit GameSimReplay;
{$mode objfpc}{$H+}
interface
uses Classes, SysUtils, Contnrs, CastleVectors, GamePhysicalAgent,
  GameCinematicCamera, GameRiderPoseControl, BikeParametric, GamePhysicsCommon,
  GameSimCameraTrack;
type
  TSimAgentCheckpoint = record
    Agent: TPhysicalAgent; { identity only; never dereferenced after removal }
    NetworkId: Int64;
    PointCount: Integer;
    State: TAgentReplayState;
  end;
  TSimCheckpoint = class
  public
    Seconds: Double;
    Agents: array of TSimAgentCheckpoint;
    Lanes: TLaneReplayState;
    Bike: TBikePlaybackState;
    Pose: TPoseManagerReplay;
    Camera: TCameraReplayState;
    CameraMode: Integer;
    CameraPosition, CameraDirection, CameraUp: TVector3;
    RandomSeed: LongInt;
    HasBike, HasPose, HasCamera: Boolean;
    function Bytes: SizeInt;
  end;
  { Up to ten value checkpoints per second. No meshes, textures, GL handles or
    terrain copies; recording is enabled only during FIT emulation. }
  TSimReplayHistory = class
  private
    FItems: TObjectList;
    FBytes: SizeInt;
    FSpacing: Double;
    FCameraTrack: TSimCameraTrack;
    function GetMemoryBytes: SizeInt;
  public
    CameraEndState: TCameraReplayState;
    CameraEndChase: TVector4;
    CameraEndSeed: LongInt;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    function NeedsSample(Seconds: Double): Boolean;
    procedure Add(Item: TSimCheckpoint);
    function Find(Seconds: Double): TSimCheckpoint;
    function Latest: Double;
    function Count: Integer;
    property MemoryBytes: SizeInt read GetMemoryBytes;
    property CameraTrack: TSimCameraTrack read FCameraTrack;
  end;
implementation
uses Math;
const MaxHistoryBytes = 32*1024*1024; { the other half is the camera track }
function TSimCheckpoint.Bytes: SizeInt;
begin Result:=InstanceSize+Length(Agents)*SizeOf(TSimAgentCheckpoint)+Length(Lanes)*SizeOf(TLaneRider) end;
constructor TSimReplayHistory.Create;
begin
  inherited; FItems:=TObjectList.Create(True); FSpacing:=0.1;
  FCameraTrack:=TSimCameraTrack.Create;
end;
destructor TSimReplayHistory.Destroy;
begin FCameraTrack.Free; FItems.Free; inherited; end;
procedure TSimReplayHistory.Clear;
begin FItems.Clear; FCameraTrack.Clear; FBytes:=0; FSpacing:=0.1 end;
function TSimReplayHistory.GetMemoryBytes: SizeInt;
begin Result:=FBytes+FCameraTrack.MemoryBytes end;
function TSimReplayHistory.Latest: Double;
begin
  Result:=0;
  if FItems.Count>0 then Result:=TSimCheckpoint(FItems.Last).Seconds;
end;
function TSimReplayHistory.Count: Integer;
begin Result:=FItems.Count end;
function TSimReplayHistory.NeedsSample(Seconds: Double): Boolean;
begin Result:=(FItems.Count=0) or (Floor(Seconds/FSpacing)>Floor(Latest/FSpacing)) end;
procedure TSimReplayHistory.Add(Item: TSimCheckpoint);
var I: Integer;
begin
  Inc(FBytes,Item.Bytes); FItems.Add(Item);
  { Long tests with many bots stay bounded. Preserve the starting point and
    the full time span by thinning checkpoints, not by dropping the start. }
  if FBytes>MaxHistoryBytes then begin
    I:=FItems.Count-2;
    while I>0 do begin Dec(FBytes,TSimCheckpoint(FItems[I]).Bytes); FItems.Delete(I); Dec(I,2) end;
    FSpacing:=FSpacing*2;
  end;
end;
function TSimReplayHistory.Find(Seconds: Double): TSimCheckpoint;
var Lo,Hi,Mid: Integer;
begin
  Result:=nil; if FItems.Count=0 then Exit;
  Lo:=0; Hi:=FItems.Count-1;
  while Lo<Hi do begin
    Mid:=(Lo+Hi+1) div 2;
    if TSimCheckpoint(FItems[Mid]).Seconds<=Seconds+0.02 then Lo:=Mid else Hi:=Mid-1;
  end;
  Result:=TSimCheckpoint(FItems[Lo]);
end;
end.
