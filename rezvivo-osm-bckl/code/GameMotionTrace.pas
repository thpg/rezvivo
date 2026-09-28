unit GameMotionTrace;

{$mode objfpc}{$H+}

interface

uses Classes, SysUtils, CastleVectors;

type
  TMotionStage = (mtBegin, mtInherited, mtBeforePhysics, mtRestore,
    mtPhysics, mtExtrapolate, mtGround, mtRelay, mtCamera, mtEnd,
    mtRenderBegin, mtRenderReady);

const
  MotionMetaCount = 60;
  MotionColumnCount = MotionMetaCount + (Ord(High(TMotionStage)) + 1) * 9;
  meInitialize = 1;
  meTeleport = 2;
  meSeek = 4;
  meNetwork = 8;
  meStop = 16;
  meConstraint = 32;
  meDiscardTime = 64;

type
  TMotionRow = packed array[0..MotionColumnCount-1] of Double;

  { One local rider, all update stages, every displayed ride frame. Packed
    numeric rows avoid per-frame formatting/allocation and logger locks.
    The first two lines describe the little-endian double columns. }
  TMotionTrace = class
  private
    FStream: TFileStream;
    FTarget: Pointer;
    FFileName: String;
    FBuffer: array[0..127] of TMotionRow;
    FBuffered: Integer;
    FLastFlush, FFrames: QWord;
    FPendingEvents: Cardinal;
    FInFrame: Boolean;
    FLastRow: TMotionRow;
    FHaveLast: Boolean;
    FJumps, FVisualJumps: Integer;
    FMaxError: Double;
    procedure Fail;
  public
    Row: TMotionRow;
    Requested: Boolean;
    constructor Create;
    destructor Destroy; override;
    procedure Start(Subject: Pointer);
    procedure Stop;
    procedure Flush;
    procedure BeginFrame(RealDt: Single);
    procedure Stage(Subject: Pointer; S: TMotionStage;
      const Physics, Visual, Camera: TVector3);
    procedure Event(Subject: Pointer; Bits: Cardinal);
    procedure Step(Subject: Pointer; const Travel: TVector3);
    procedure EndFrame;
    property Target: Pointer read FTarget;
    property FileName: String read FFileName;
    property Frames: QWord read FFrames;
    property Jumps: Integer read FJumps;
    property VisualJumps: Integer read FVisualJumps;
    property MaxError: Double read FMaxError;
  end;

var MotionTrace: TMotionTrace;

implementation

uses Math, DebugLog;

const
  StageNames: array[TMotionStage] of String = ('begin', 'inherited',
    'before_physics', 'restore', 'physics', 'extrapolate', 'ground',
    'relay', 'camera', 'end', 'render_begin', 'render_ready');
  VectorNames: array[0..8] of String = ('physics_x','physics_y','physics_z',
    'visual_x','visual_y','visual_z','camera_x','camera_y','camera_z');
  MetaNames = 'frame,tick_ms,real_dt,sim_dt,playback_sec,physics_sec,' +
    'segment,path_t,speed,road_width,lane,applied_lane,wobble,distance,' +
    'accum,yaw,pitch,roll,authority,physics_mode,camera_mode,shot_serial,' +
    'camera_replay,steps,events,travel_x,travel_y,travel_z,' +
    'forward_x,forward_y,forward_z,velocity_x,velocity_y,velocity_z,' +
    'carrot_x,carrot_y,carrot_z,route_x,route_y,route_z,' +
    'camera_dir_x,camera_dir_y,camera_dir_z,camera_up_x,camera_up_y,camera_up_z,' +
    'fov,stages,scene_origin_x,scene_origin_y,scene_origin_z,' +
    'rider_origin_x,rider_origin_y,rider_origin_z,' +
    'actor_dir_x,actor_dir_y,actor_dir_z,actor_up_x,actor_up_y,actor_up_z';

constructor TMotionTrace.Create;
var I: Integer;
begin
  inherited;
  { Diagnostic capture is opt-in; ordinary rides must not write frame data. }
  Requested := GetEnvironmentVariable('REZVIVO_MOTION_TRACE') = '1';
  for I := 1 to ParamCount do
    if ParamStr(I) = '--no-motion-trace' then Requested := False;
end;

destructor TMotionTrace.Destroy;
begin
  Stop;
  inherited;
end;

procedure TMotionTrace.Fail;
begin
  FreeAndNil(FStream);
  FTarget := nil;
  FInFrame := False;
  FBuffered := 0;
  Requested := False; { A full disk must not stop the ride or retry each frame. }
end;

procedure TMotionTrace.Start(Subject: Pointer);
var Header, Base: String; S: TMotionStage; I, N: Integer;
begin
  Stop;
  if not Requested or (Subject = nil) then Exit;
  Base := ChangeFileExt(GetLogFileName, '') + '-motion';
  FFileName := Base + '.bin';
  N := 0;
  while FileExists(FFileName) do begin
    Inc(N); FFileName := Base + '-' + IntToStr(N) + '.bin';
  end;
  try
    FStream := TFileStream.Create(FFileName, fmCreate or fmShareDenyNone);
    Header := 'REZVIVO_MOTION_V1' + #10 + MetaNames;
    for S := Low(S) to High(S) do
      for I := 0 to 8 do Header := Header + ',' + StageNames[S] + '_' + VectorNames[I];
    Header := Header + #10;
    FStream.WriteBuffer(Header[1], Length(Header));
    FTarget := Subject;
    FFrames := 0; FJumps := 0; FVisualJumps := 0; FMaxError := 0;
    FHaveLast := False; FPendingEvents := 0;
    FLastFlush := GetTickCount64;
    Logger.Info('[MotionTrace] Per-frame rider/camera stages: ' + FFileName);
  except
    on E: Exception do begin Fail; Logger.Warning('[MotionTrace] ' + E.Message) end;
  end;
end;

procedure TMotionTrace.Flush;
begin
  if (FStream = nil) or (FBuffered = 0) then Exit;
  try
    FStream.WriteBuffer(FBuffer[0], FBuffered * SizeOf(TMotionRow));
    FBuffered := 0;
    FLastFlush := GetTickCount64;
  except
    on E: Exception do begin Fail; Logger.Warning('[MotionTrace] ' + E.Message) end;
  end;
end;

procedure TMotionTrace.Stop;
begin
  if FInFrame then EndFrame;
  Flush;
  FreeAndNil(FStream);
  FTarget := nil; FInFrame := False; FHaveLast := False;
end;

procedure TMotionTrace.BeginFrame(RealDt: Single);
begin
  if FTarget = nil then Exit;
  { Some hidden/menu frames update without drawing. Keep those rows too. }
  if FInFrame then EndFrame;
  FillChar(Row, SizeOf(Row), 0);
  Row[0] := FFrames;
  Row[1] := GetTickCount64;
  Row[2] := RealDt;
  Row[24] := FPendingEvents;
  FPendingEvents := 0;
  FInFrame := True;
end;

procedure TMotionTrace.Stage(Subject: Pointer; S: TMotionStage;
  const Physics, Visual, Camera: TVector3);
var I: Integer;
begin
  if (FTarget = nil) or (Subject <> FTarget) or not FInFrame then Exit;
  I := MotionMetaCount + Ord(S) * 9;
  Row[I] := Physics.X; Row[I+1] := Physics.Y; Row[I+2] := Physics.Z;
  Row[I+3] := Visual.X; Row[I+4] := Visual.Y; Row[I+5] := Visual.Z;
  Row[I+6] := Camera.X; Row[I+7] := Camera.Y; Row[I+8] := Camera.Z;
  Row[47] := Cardinal(Round(Row[47])) or (Cardinal(1) shl Ord(S));
end;

procedure TMotionTrace.Event(Subject: Pointer; Bits: Cardinal);
begin
  if (FTarget = nil) or (Subject <> FTarget) then Exit;
  if FInFrame then Row[24] := Cardinal(Round(Row[24])) or Bits
  else FPendingEvents := FPendingEvents or Bits;
end;

procedure TMotionTrace.Step(Subject: Pointer; const Travel: TVector3);
begin
  if (FTarget = nil) or (Subject <> FTarget) or not FInFrame then Exit;
  Row[23] := Row[23] + 1;
  Row[25] := Row[25] + Travel.X;
  Row[26] := Row[26] + Travel.Y;
  Row[27] := Row[27] + Travel.Z;
end;

procedure TMotionTrace.EndFrame;
var E: Integer; DX, DZ, Err: Double;
  procedure CheckStageShift(A, B: TMotionStage; Camera: Boolean = False);
  var IA, IB: Integer; Mask: Cardinal; D: Double;
  begin
    Mask := (Cardinal(1) shl Ord(A)) or (Cardinal(1) shl Ord(B));
    if (Cardinal(Round(Row[47])) and Mask) <> Mask then Exit;
    IA := MotionMetaCount + Ord(A)*9+3;
    IB := MotionMetaCount + Ord(B)*9+3;
    if Camera then begin Inc(IA,3); Inc(IB,3) end;
    D := Sqrt(Sqr(Row[IA]-Row[IB]) + Sqr(Row[IA+2]-Row[IB+2]));
    if D <= 0.15 then Exit;
    Inc(FVisualJumps);
    if (FVisualJumps <= 20) or (FVisualJumps mod 100 = 0) then
      Logger.Warning(Format('[MotionTrace] stage shift frame=%d sim=%.3f from=%s to=%s camera=%d xz=%.3f',
        [FFrames, Row[4], StageNames[A], StageNames[B], Ord(Camera), D]));
  end;
begin
  if (FTarget = nil) or not FInFrame then Exit;
  { MCP screenshots can request rendering in the middle of Update. Wait
    for a complete state, rather than publishing an unfinished frame. }
  if (Cardinal(Round(Row[47])) and (Cardinal(1) shl Ord(mtEnd))) = 0 then Exit;
  FInFrame := False;
  E := MotionMetaCount + Ord(mtEnd) * 9;
  { Exact kinematic travel, summed across substeps, separates a correction
    from an ordinary large movement at 8x or after a long frame. Explicit
    seek/start/teleport events stay in the file, not the jump count. }
  if FHaveLast and ((Round(Row[24]) and (meInitialize or meTeleport or meSeek or meStop)) = 0)
    and (Round(Row[19]) = 0) then begin
    DX := Row[E] - FLastRow[E] - Row[25];
    DZ := Row[E+2] - FLastRow[E+2] - Row[27];
    Err := Sqrt(DX*DX + DZ*DZ);
    FMaxError := Max(FMaxError, Err);
    if Err > 0.15 then begin
      Inc(FJumps);
      if (FJumps <= 20) or (FJumps mod 100 = 0) then
        Logger.Warning(Format('[MotionTrace] rider jump frame=%d sim=%.3f dx=%.3f dz=%.3f seg=%d dt=%.5f events=%d authority=%d',
          [FFrames, Row[4], DX, DZ, Round(Row[6]), Row[3], Round(Row[24]), Round(Row[18])]));
    end;
  end;
  if (Round(Row[24]) and (meInitialize or meTeleport or meSeek or meStop)) = 0 then begin
    CheckStageShift(mtBegin, mtInherited);
    CheckStageShift(mtExtrapolate, mtGround);
    CheckStageShift(mtGround, mtEnd);
    CheckStageShift(mtEnd, mtRenderBegin);
    CheckStageShift(mtRenderBegin, mtRenderReady);
    CheckStageShift(mtEnd, mtRenderBegin, True);
    CheckStageShift(mtRenderBegin, mtRenderReady, True);
  end;
  FLastRow := Row; FHaveLast := True;
  FBuffer[FBuffered] := Row;
  Inc(FBuffered); Inc(FFrames);
  if (FBuffered = Length(FBuffer)) or (GetTickCount64 - FLastFlush >= 1000) then Flush;
end;

initialization
  MotionTrace := TMotionTrace.Create;
finalization
  FreeAndNil(MotionTrace);
end.
