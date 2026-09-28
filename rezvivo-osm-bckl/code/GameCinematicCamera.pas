{ GameCinematicCamera — broadcast-style cycling race camera system.

  Modes (like real TV coverage):
    cmMoto       — motorcycle following shot, behind+above, looking ahead on path (MAIN)
    cmHelicopter — high wide shot, shows road ahead and group
    cmRoadside   — static camera at a point ahead, riders zoom past
    cmReverse    — motorcycle ahead looking back at riders
    cmLowTrack   — low angle from roadside, dramatic close-up
    cmOrbit      — STATIONARY-RIDER scenario: short slow orbit segment around
                   the standing rider. Never picked while moving.
    cmStandShot  — STATIONARY-RIDER scenario: static camera at a random angle
                   watching the standing rider (no motion — the restful shot).

  Rules:
    - ALWAYS returns to cmMoto after any other view
    - cmMoto runs 15-25s, other views 4-8s
    - STATIONARY rider (feed TargetSpeed each frame): all broadcast modes
      assume motion (spline look-ahead, placement ahead on the path), so when
      the rider stands still for a moment the manager switches to the
      stationary scenario — mostly STATIC shots from varying angles, with an
      occasional SHORT orbit segment mixed in (constant rotation is dizzying)
      — until the rider moves again, then cuts back to cmMoto.
    - Prepare the new shot's terrain before displaying it. Pending surface
      data never falls back to scene props; physics rays are only for legacy
      maps without a surface provider.
    - Damp terrain-relative height, with solid ground clearance and without
      adding delay to the rider's forward motion.
    - When riders are nearby, frames the group }
unit GameCinematicCamera;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math,
  CastleVectors, CastleTransform, CastleViewport, CastleCameras, CastleLog,
  GamePath, DebugLog;

type
  TCameraMode = (cmMoto, cmHelicopter, cmRoadside, cmReverse, cmLowTrack,
    cmOrbit, cmStandShot);

  { Optional terrain-height provider. Filled AY with the world Y of the
    terrain mesh at (X, Z); returns True on success, False when the query
    falls outside the data (e.g. off the loaded streaming tiles).

    Structurally identical to gamephysicscommon.TGroundQueryFunc, so the
    very same method pointer the physics uses (@FOsmStreaming.GroundNearYAt)
    can be assigned to GroundQuery directly — without coupling this unit
    to the physics units. }
  TCameraGroundQuery = function(WorldX, WorldZ, ReferenceY: Single;
    out AY: Single): Boolean of object;

  TCameraGroundSample = record
    Valid: Boolean;
    X, Z, Y: Single;
  end;

  TCameraShotState = record
    Mode: TCameraMode;
    CameraGround, LookGround, FrameGround: TCameraGroundSample;
    RoadsideAnchor, StandAnchor: TVector3;
    OrbitAngle, OrbitDir, OrbitRadius, StandHeight: Single;
  end;

  TCameraReplayState = record
    ShotSerial: Cardinal;
    Shot: TCameraShotState;
    PendingShot: TCameraShotState;
    Pending: Boolean;
    PendingAge: Single;
    LastTargetPosition: TVector3;
    HaveTargetPosition: Boolean;
    HeightReady: Boolean;
    HeightOffset: Single;
    FrameDT: Single;
    ModeTimer: Single;
    CamPos: TVector3;
    CamDir: TVector3;
    CamUp: TVector3;
    Enabled: Boolean;
    AutoSwitch: Boolean;
    TargetSpeed: Single;
    TargetPitchDeg: Single;
    StillTime: Single;
    Stationary: Boolean;
    PathPos: TPathPosition;
  end;

  {$M+}
  TCinematicCamera = class
  private
    FViewport: TCastleViewport;
    FTarget: TCastleTransform;
    FPath: TGamePath;
    FPathPos: TPathPosition;

    FShot, FPendingShot: TCameraShotState;
    FShotSerial: Cardinal;
    FPending, FPreparingShot, FProbeReady: Boolean;
    FPendingAge: Single;
    FLastTargetPosition: TVector3;
    FHaveTargetPosition, FTraceCamera: Boolean;
    FHeightReady: Boolean;
    FHeightOffset, FFrameDT: Single;
    FModeTimer: Single;

    FCamPos, FCamDir, FCamUp: TVector3;

    FNearby: array of TVector3;
    FNearbyCount: Integer;
    FEnabled, FAutoSwitch: Boolean;

    { ── stationary-rider scenario ── }
    FTargetSpeed: Single;   { m/s, fed by the owner each frame (0 if never fed) }
    FTargetPitchDeg: Single; { visual bike pitch, not the corrected trainer slope }
    FStillTime: Single;     { how long the speed has been below the enter threshold }
    FStationary: Boolean;   { scenario active — stationary shots until motion resumes }

    { Optional ground-height source (Osm3d streaming map). When assigned,
      It is authoritative, including pending/missing data. Scene physics
      is only used on legacy maps without a surface provider. }
    FGroundQuery: TCameraGroundQuery;

    { DIAG: throttle + last logged look-at yaw for cam target logs }
    FCamTargetLogNext: QWord;
    FLastLoggedLookYaw: Single;
    FLastLoggedMode: TCameraMode;

    procedure ResetTracking;
    procedure SetEnabled(const Value: Boolean);
    procedure TryPendingShot;
    function GetMode: TCameraMode;
    function GetPendingMode: Integer;
    procedure SetGroundQuery(const Value: TCameraGroundQuery);
    procedure SyncPathPosition;
    function ModeDuration(M: TCameraMode): Single;
    function ModeName(M: TCameraMode): string;
    procedure LogCamTargets(const M: TCameraMode; const TPos, CamP, LookAt,
      RouteLook: TVector3; const LookSrc: string; const HasRoute: Boolean);
    function PickCutaway: TCameraMode;
    { Ground Y under (X,Z): Osm3d height manager first (collider-less
      streaming tiles), then a scene raycast (default map). False if neither
      resolves. Used both to clamp the camera and to pin look-at heights to
      the actual surface (spline Y is unreliable on streamed maps). }
    function GroundYAt(const X, Z: Single; out GY: Single): Boolean;
    { Seam-robust ground: GroundYAt can miss exactly on a tile boundary even
      where terrain is rendered. Samples a small cross around (X,Z) and takes
      the highest hit so a seam at the point doesn't drop the caller back to
      the rider's plane. }
    function GroundYRobust(const X, Z: Single; out GY: Single): Boolean;
    { GPU ground queries are asynchronous: False can mean pending. Keep the
      last nearby result for each consumer; the look-ahead point and the
      camera floor can be tens of metres apart and must not share a sample. }
    function GroundYRemembered(const X, Z: Single; const Robust: Boolean;
      var Sample: TCameraGroundSample; out GY: Single): Boolean;
    procedure ComputeMode(M: TCameraMode; out P, D, U: TVector3);
    procedure FrameShot(var P, D: TVector3);
    procedure SmoothHeight(var P: TVector3);
    procedure AdjustForGroup(var P, D: TVector3);
    procedure KeepRiderInFrame(var P, D: TVector3);
    procedure ClampAboveGround(var P: TVector3; const Framing: Boolean = False);
    procedure PlaceRoadsideCamera;
    { flatten a unit direction so its down-pitch never exceeds asin(MaxDownSin) }
    procedure ClampDownPitch(var D: TVector3; const MaxDownSin: Single);
    { Stationary-rider scenario: pick the next shot (mostly static stand-shots,
      an occasional short orbit) and place the static stand-shot camera. }
    function PickStationary: TCameraMode;
    procedure PlaceStandShot;
  public
    function CaptureReplay: TCameraReplayState;
    procedure RestoreReplay(const Saved: TCameraReplayState);
    procedure ShowRecordedView(const Position,Direction,Up:TVector3;
      CurrentMode,APendingMode:Integer);
    property ShotSerial: Cardinal read FShotSerial;
  public
    constructor Create;
    procedure Setup(AViewport: TCastleViewport; ATarget: TCastleTransform; APath: TGamePath);
    { New ride: discard the previous shot and place the camera immediately,
      without advancing simulation time (also works while paused). }
    procedure ResetAtTarget;
    procedure Update(const DT: Single);

    procedure ClearNearby;
    procedure AddNearby(const APos: TVector3);
    procedure NextMode;
    procedure ForceMode(M: TCameraMode);

    { Lift an EXTERNAL camera position above the terrain under it — for the
      manual third-person navigation camera, which orbits the avatar with no
      terrain awareness and on a slope ends up INSIDE the hillside. Same
      machinery as the cinematic modes: seam-robust ground cross, canopy
      sanity cap, temporal hold over transient query failures. }
    procedure ClampCameraAboveGround(var P: TVector3);

    { Assign @FOsmStreaming.GroundNearYAt here for streaming OSM maps. Safe to
      assign even before the map activates: that method self-guards on its
      Active flag and returns False until ready. Keep the recent ground
      sample while pending; nil enables the legacy physics-ray fallback. }
    property GroundQuery: TCameraGroundQuery read FGroundQuery write SetGroundQuery;
  published
    property Enabled: Boolean read FEnabled write SetEnabled;
    property AutoSwitch: Boolean read FAutoSwitch write FAutoSwitch;
    { Запись идёт через ForceMode — тот же путь, что и ручное
      переключение, со сбросом таймера режима. }
    property Mode: TCameraMode read GetMode write ForceMode;
    property PendingMode: Integer read GetPendingMode;
    { Rider speed in m/s — feed every frame (from the agent's CurrentSpeed).
      Drives the stationary-rider scenario: below ~0.3 m/s for ~1.5 s the
      camera switches to the cmOrbit showcase; above ~0.8 m/s it cuts back to
      cmMoto. Never fed (stays 0) on a moving rider = scenario simply engages,
      so owners that want broadcast-only behaviour should feed real speed. }
    property TargetSpeed: Single read FTargetSpeed write FTargetSpeed;
    property TargetPitchDeg: Single read FTargetPitchDeg write FTargetPitchDeg;
  end;
  {$M-}

implementation

uses CastleProjection;

const
  { Moto — the main REAR VIEW: close behind and low, the whole rider+bike
    fills a good part of the frame and fits with margin (at 3 m the model's
    ~1.5 m occupies ~40% of a 60-deg vertical FOV, centered) }
  MotoBehind = 3.0;        { was 5.0 — closer = larger rider }
  MotoAbove = 1.3;         { was 2.5 — near eye level, less "drone" look }
  MotoAimHeight = 0.85;    { aim at the model's vertical CENTER, so wheels
                             and head are framed symmetrically }
  MotoLookAhead = 50.0;

  { Helicopter — high wide }
  HeliAbove = 24.0;      { m above the rider }
  HeliBehind = 26.0;     { m behind — far enough that the down-pitch stays shallow }
  HeliSide = 10.0;       { m to the side — diagonal framing, road reads as a line }
  HeliLookAhead = 80.0;
  { Helicopter must stay a WIDE shot: never pitch down steeper than ~32 deg.
    horizontal distance to the look point >= height difference * this. }
  HeliMinFlatPerHeight = 1.6;

  { Roadside — fixed point on the side of road }
  RoadsideDist = 5.0;
  RoadsideAbove = 1.4;
  RoadsidePlaceAhead = 30.0;  { place camera 30m ahead of rider }

  { Reverse — motorcycle ahead looking back }
  ReverseAhead = 10.0;
  ReverseAbove = 2.0;

  { Low tracking — low angle from roadside. Height is measured from the
    GROUND under the camera (see cmLowTrack), via the seam-robust sampler, so
    this is true clearance above the local surface. The earlier sink was a
    tile-seam miss dropping the cam to the rider plane, not the margin —
    fixed in GroundYRobust — so this can stay genuinely low. }
  LowTrackSide = 4.0;
  LowTrackAbove = 0.6;

  MinCameraY = 0.3;      { last-resort min height above the rider's ground plane }
  GroundClearance = 0.5; { min height above the terrain actually under the camera;
                           lower it (~0.35) if low-angle shots feel too high —
                           the MinCameraY backstop still prevents burial. }
  { Helicopter must ALWAYS stay a wide shot: max down-pitch ~32 deg
    (sin 32). Applied as the FINAL clamp in Update — after AdjustForGroup,
    which re-aims at the group center and from 24 m up used to dive the
    view into the ground whenever bots were nearby. }
  HeliMaxDownSin = 0.53;
  { ── ground-floor robustness (see ClampAboveGround / GroundYRobust) ── }
  GroundHoldRadius  = 15.0;   { m — query FAILED (streaming tile): hold the last
                                known floor instead of dropping to the rider plane,
                                which on a slope sits INSIDE the hillside }
  MaxGroundAboveRider = 30.0; { m — a "ground" sample this far above the rider is a
                                canopy/roof raycast hit, not terrain: ignore it }

  { ── stationary-rider scenario (cmOrbit + cmStandShot) ── }
  StillEnterSpeed = 0.3;   { m/s — below this the rider counts as standing }
  StillEnterDelay = 1.5;   { s — must stay below for this long (ignores a track-stand wobble) }
  StillExitSpeed  = 0.8;   { m/s — above this the rider is moving again (hysteresis) }
  OrbitRadiusBase = 4.5;   { m — base distance from the rider }
  OrbitRadiusJitter = 1.2; { m — per-cycle random radius variation }
  OrbitHeight     = 1.6;   { m — camera height above the ground UNDER the camera }
  OrbitDegPerSec  = 9.0;   { deg/s — a short segment sweeps only ~60-80 deg }
  OrbitBreathAmp  = 0.7;   { m — slow in/out radius breathing along the arc }
  OrbitChance     = 30;    { % of stationary cycles that are an orbit segment;
                             the rest are static stand-shots — constant
                             rotation is dizzying, so statics dominate }
  StandDistMin    = 3.5;   { m — static stand-shot distance range }
  StandDistMax    = 6.5;
  StandHeightMin  = 1.2;   { m — above the ground UNDER the camera }
  StandHeightMax  = 2.2;

  { Steepest the camera may ever look DOWN, as -sin(pitch). Guards against a
    high side-terrain reading (road cut into a slope, or a tile-seam height
    spike) lifting a close cam — mainly cmLowTrack — far above the rider: the
    look direction then goes near-vertical, the fixed (0,1,0) up vector
    degenerates, and the frame shows only ground with the rider gone. Capping
    the pitch keeps the horizon in view and the up vector valid. ~58 deg. }
  MaxLookDownSin = 0.85;

function TCinematicCamera.CaptureReplay: TCameraReplayState;
begin
  Result.ShotSerial:=FShotSerial;
  Result.Shot:=FShot;
  Result.PendingShot:=FPendingShot;
  Result.Pending:=FPending;
  Result.PendingAge:=FPendingAge;
  Result.LastTargetPosition:=FLastTargetPosition;
  Result.HaveTargetPosition:=FHaveTargetPosition;
  Result.HeightReady:=FHeightReady;
  Result.HeightOffset:=FHeightOffset;
  Result.FrameDT:=FFrameDT;
  Result.ModeTimer:=FModeTimer;
  Result.CamPos:=FCamPos;
  Result.CamDir:=FCamDir;
  Result.CamUp:=FCamUp;
  Result.Enabled:=FEnabled;
  Result.AutoSwitch:=FAutoSwitch;
  Result.TargetSpeed:=FTargetSpeed;
  Result.TargetPitchDeg:=FTargetPitchDeg;
  Result.StillTime:=FStillTime;
  Result.Stationary:=FStationary;
  Result.PathPos:=FPathPos;
end;

procedure TCinematicCamera.RestoreReplay(const Saved: TCameraReplayState);
begin
  FShotSerial:=Saved.ShotSerial;
  FShot:=Saved.Shot;
  FPendingShot:=Saved.PendingShot;
  FPending:=Saved.Pending;
  FPendingAge:=Saved.PendingAge;
  FLastTargetPosition:=Saved.LastTargetPosition;
  FHaveTargetPosition:=Saved.HaveTargetPosition;
  FHeightReady:=Saved.HeightReady;
  FHeightOffset:=Saved.HeightOffset;
  FFrameDT:=Saved.FrameDT;
  FModeTimer:=Saved.ModeTimer;
  FCamPos:=Saved.CamPos;
  FCamDir:=Saved.CamDir;
  FCamUp:=Saved.CamUp;
  FEnabled:=Saved.Enabled;
  FAutoSwitch:=Saved.AutoSwitch;
  FTargetSpeed:=Saved.TargetSpeed;
  FTargetPitchDeg:=Saved.TargetPitchDeg;
  FStillTime:=Saved.StillTime;
  FStationary:=Saved.Stationary;
  FPathPos:=Saved.PathPos;
  if (FViewport<>nil) and (FViewport.Camera<>nil) then FViewport.Camera.SetView(FCamPos,FCamDir,FCamUp);
end;

procedure TCinematicCamera.ShowRecordedView(const Position,Direction,Up:TVector3;
  CurrentMode,APendingMode:Integer);
begin
  FCamPos:=Position; FCamDir:=Direction; FCamUp:=Up;
  if (CurrentMode>=Ord(Low(TCameraMode))) and (CurrentMode<=Ord(High(TCameraMode))) then
    FShot.Mode:=TCameraMode(CurrentMode);
  FPending:=(APendingMode>=Ord(Low(TCameraMode))) and (APendingMode<=Ord(High(TCameraMode)));
  if FPending then FPendingShot.Mode:=TCameraMode(APendingMode);
  if (FViewport<>nil) and (FViewport.Camera<>nil) then
    FViewport.Camera.SetView(Position,Direction,Up);
end;

constructor TCinematicCamera.Create;
begin
  inherited;
  FShot.Mode := cmMoto;
  FModeTimer := 20;
  FCamUp := Vector3(0, 1, 0);
  FCamDir := Vector3(0, 0, 1);
  FEnabled := False;
  FAutoSwitch := True;
  FGroundQuery := nil;
  FTargetSpeed := 0;
  FStillTime := 0;
  FStationary := False;
  FShot.OrbitAngle := 0;
  FShot.OrbitDir := 1;
  FShot.OrbitRadius := OrbitRadiusBase;
  FCamTargetLogNext := 0;
  FLastLoggedLookYaw := 0;
  FLastLoggedMode := cmMoto;
  FTraceCamera := GetEnvironmentVariable('REZVIVO_CAMERA_TRACE') = '1';
end;

function TCinematicCamera.ModeName(M: TCameraMode): string;
begin
  case M of
    cmMoto:       Result := 'moto';
    cmHelicopter: Result := 'heli';
    cmRoadside:   Result := 'roadside';
    cmReverse:    Result := 'reverse';
    cmLowTrack:   Result := 'lowtrack';
    cmOrbit:      Result := 'orbit';
    cmStandShot:  Result := 'standshot';
  else
    Result := '?';
  end;
end;

procedure TCinematicCamera.LogCamTargets(const M: TCameraMode;
  const TPos, CamP, LookAt, RouteLook: TVector3; const LookSrc: string;
  const HasRoute: Boolean);
var
  NowTick: QWord;
  LookYaw, DYaw: Single;
  DX, DZ, Dist: Single;
  Force: Boolean;
begin
  if FPreparingShot or not FTraceCamera or not Assigned(Logger) then Exit;

  DX := LookAt.X - CamP.X;
  DZ := LookAt.Z - CamP.Z;
  LookYaw := RadToDeg(ArcTan2(DX, DZ));
  DYaw := LookYaw - FLastLoggedLookYaw;
  while DYaw > 180 do DYaw := DYaw - 360;
  while DYaw < -180 do DYaw := DYaw + 360;

  NowTick := GetTickCount64;
  Force := (M <> FLastLoggedMode) or (Abs(DYaw) >= 12.0);
  if (not Force) and (NowTick < FCamTargetLogNext) then Exit;
  FCamTargetLogNext := NowTick + 250; { 4 Hz steady; jumps/mode change always }
  FLastLoggedLookYaw := LookYaw;
  FLastLoggedMode := M;

  Dist := Sqrt(DX * DX + (LookAt.Y - CamP.Y) * (LookAt.Y - CamP.Y) + DZ * DZ);
  if HasRoute then
    Logger.Info(Format(
      '[CineCam] mode=%s spd=%.2f still=%.2f stat=%d | rider=(%.1f,%.1f,%.1f) '
      + 'cam=(%.1f,%.1f,%.1f) | lookSrc=%s look=(%.1f,%.1f,%.1f) yaw=%.1f dYaw=%.1f dist=%.1f '
      + '| routeLook=(%.1f,%.1f,%.1f) pathSeg=%d pathT=%.3f',
      [ModeName(M), FTargetSpeed, FStillTime, Ord(FStationary),
       TPos.X, TPos.Y, TPos.Z,
       CamP.X, CamP.Y, CamP.Z,
       LookSrc, LookAt.X, LookAt.Y, LookAt.Z, LookYaw, DYaw, Dist,
       RouteLook.X, RouteLook.Y, RouteLook.Z,
       FPathPos.Segment, FPathPos.T]))
  else
    Logger.Info(Format(
      '[CineCam] mode=%s spd=%.2f still=%.2f stat=%d | rider=(%.1f,%.1f,%.1f) '
      + 'cam=(%.1f,%.1f,%.1f) | lookSrc=%s look=(%.1f,%.1f,%.1f) yaw=%.1f dYaw=%.1f dist=%.1f',
      [ModeName(M), FTargetSpeed, FStillTime, Ord(FStationary),
       TPos.X, TPos.Y, TPos.Z,
       CamP.X, CamP.Y, CamP.Z,
       LookSrc, LookAt.X, LookAt.Y, LookAt.Z, LookYaw, DYaw, Dist]));
end;

procedure TCinematicCamera.Setup(AViewport: TCastleViewport;
  ATarget: TCastleTransform; APath: TGamePath);
begin
  FViewport := AViewport;
  FTarget := ATarget;
  FPath := APath;
  ResetTracking;
  FShot.CameraGround.Valid := False;
  FShot.LookGround.Valid := False;   { new world/target — forget both samples }
  if Assigned(FTarget) then
    FCamPos := FTarget.Translation + Vector3(0, MotoAbove, -MotoBehind);
end;

procedure TCinematicCamera.ResetAtTarget;
begin
  ClearNearby;
  ResetTracking;
  Update(0);
end;

procedure TCinematicCamera.ResetTracking;
begin
  Inc(FShotSerial);
  FShot.Mode := cmMoto;
  FShot.CameraGround.Valid := False;
  FShot.LookGround.Valid := False;
  FShot.FrameGround.Valid := False;
  FHeightReady := False;
  FPending := False;
  FStillTime := 0;
  FStationary := False;
  FHaveTargetPosition := False;
  FHeightReady := False;
  FModeTimer := ModeDuration(cmMoto);
end;

procedure TCinematicCamera.SetEnabled(const Value: Boolean);
begin
  if FEnabled = Value then Exit;
  FEnabled := Value;
  if Value then ResetTracking else FPending := False;
end;

function TCinematicCamera.GetMode: TCameraMode;
begin Result := FShot.Mode end;

function TCinematicCamera.GetPendingMode: Integer;
begin
  if FPending then Result := Ord(FPendingShot.Mode) else Result := -1;
end;

procedure TCinematicCamera.SyncPathPosition;
begin
  if Assigned(FPath) and Assigned(FTarget) and (FPath.PointCount>=2) then
    // Same geometry and current branch as the rider. Project continuously in
    // metres; never quantize a long GPX segment or change the physics cursor.
    FPathPos:=FPath.ProjectFollow(FTarget.Translation,FPath.Position,2.0);
end;

procedure TCinematicCamera.SetGroundQuery(const Value: TCameraGroundQuery);
begin
  FGroundQuery := Value;
  FPending := False;
  FShot.CameraGround.Valid := False;
  FShot.LookGround.Valid := False; { A replacement route may have a different floor. }
  FShot.FrameGround.Valid := False;
  FHeightReady := False;
end;

function TCinematicCamera.ModeDuration(M: TCameraMode): Single;
begin
  case M of
    cmMoto:       Result := 15 + Random * 10;  { 15-25s — main view, longest }
    cmHelicopter: Result := 5 + Random * 3;    { 5-8s }
    cmRoadside:   Result := 4 + Random * 3;    { 4-7s }
    cmReverse:    Result := 4 + Random * 3;    { 4-7s }
    cmLowTrack:   Result := 3 + Random * 2;    { 3-5s, shortest }
    cmOrbit:      Result := 6 + Random * 3;    { 6-9s — a SHORT arc, not a full circle }
    cmStandShot:  Result := 6 + Random * 4;    { 6-10s — restful static view }
    else Result := 15;
  end;
end;

function TCinematicCamera.PickCutaway: TCameraMode;
var R: Integer;
begin
  { Pick a non-moto view. cmOrbit / cmStandShot are deliberately NOT here —
    they belong to the stationary-rider scenario only, meaningless alongside
    a moving target. }
  R := Random(100);
  if R < 30 then Result := cmHelicopter
  else if R < 55 then Result := cmRoadside
  else if R < 80 then Result := cmReverse
  else Result := cmLowTrack;
end;

function TCinematicCamera.GroundYAt(const X, Z: Single; out GY: Single): Boolean;
var
  RayResult: TRayCastResult;
  OriginY: Single;
begin
  Result := False;

  { 1) Osm3d height manager — direct query against the terrain mesh.
       Streaming tiles have no colliders, so a raycast would miss there.
       Returns False when (X,Z) is outside the loaded data. }
  if Assigned(FGroundQuery) then
  begin
    if Assigned(FTarget) then OriginY:=FTarget.Translation.Y else OriginY:=0;
    Result := FGroundQuery(X, Z, OriginY, GY);
    if Result then Result := not IsNan(GY) and not IsInfinite(GY);
    { False also means GPU readback pending. The dedicated surface provider
      is authoritative: never substitute a rider, prop or another collider. }
    Exit;
  end;

  { 2) Default ElevationGrid map (has collision) — scene raycast straight
       down. Origin is well above the rider so terrain that climbs ahead of
       the rider (the look-ahead point may be on a hill) is still bracketed. }
  if Assigned(FViewport) and Assigned(FTarget) then
  begin
    OriginY := FTarget.Translation.Y + 60;
    RayResult := FViewport.Items.PhysicsRayCast(
      Vector3(X, OriginY, Z), Vector3(0, -1, 0), 200);
    if RayResult.Hit then
    begin
      GY := OriginY - RayResult.Distance;
      Result := True;
    end;
  end;
end;

function TCinematicCamera.GroundYRobust(const X, Z: Single; out GY: Single): Boolean;
const
  R = 1.5;   { cross radius — wider than a tile seam, narrower than a tile }
var
  SampleY, Best: Single;
  Any: Boolean;

  procedure TrySample(const SX, SZ: Single);
  begin
    if GroundYAt(SX, SZ, SampleY) then
    begin
      { canopy/roof sanity: a raycast that hit a tree crown or a building far
        above the rider is NOT terrain — taking it as the floor catapults the
        camera up. Plausible slope-side terrain stays well under this cap. }
      if Assigned(FTarget) and
         (SampleY > FTarget.Translation.Y + MaxGroundAboveRider) then Exit;
      if (not Any) or (SampleY > Best) then Best := SampleY;
      Any := True;
    end;
  end;

begin
  Any := False;
  Best := 0;
  TrySample(X, Z);          { the point itself }
  TrySample(X + R, Z);      { neighbours rescue a seam right under the point }
  TrySample(X - R, Z);
  TrySample(X, Z + R);
  TrySample(X, Z - R);
  GY := Best;
  Result := Any;
end;

procedure TCinematicCamera.ClampCameraAboveGround(var P: TVector3);
begin
  ClampAboveGround(P);
end;

function TCinematicCamera.GroundYRemembered(const X, Z: Single;
  const Robust: Boolean; var Sample: TCameraGroundSample;
  out GY: Single): Boolean;
var
  DistSq: Single;
begin
  DistSq := Sqr(X - Sample.X) + Sqr(Z - Sample.Z);
  { Prefer the surface directly under the point. With asynchronous queries,
    taking max() of five probes every frame selects a different subset while
    patches are pending. On a slope that changes the floor by metres even
    though the camera hardly moved. Neighbour probes only bootstrap a shot
    when neither an exact hit nor a recent nearby floor is available. }
  Result := GroundYAt(X, Z, GY);
  if Robust and Result and Assigned(FTarget) and
     (GY > FTarget.Translation.Y + MaxGroundAboveRider) then Result := False;
  if FPreparingShot and Assigned(FGroundQuery) and not Result then
    FProbeReady := False;
  if not Result and Sample.Valid and (DistSq < Sqr(GroundHoldRadius)) then
  begin
    GY := Sample.Y;
    Exit(True);
  end;
  { Async terrain misses need time, not four more requests at other points.
    Neighbour rays are only a legacy-map seam fallback. }
  if not Result and Robust and not Assigned(FGroundQuery) then
    Result := GroundYRobust(X, Z, GY);
  if Result then
  begin
    Sample.Valid := True;
    Sample.X := X; Sample.Z := Z; Sample.Y := GY;
  end;
end;

procedure TCinematicCamera.ClampAboveGround(var P: TVector3; const Framing: Boolean);
var
  GY, MinY: Single;
  Found: Boolean;
begin
  if Framing then
    Found := GroundYRemembered(P.X, P.Z, True, FShot.FrameGround, GY)
  else
    Found := GroundYRemembered(P.X, P.Z, True, FShot.CameraGround, GY);
  if Found then
  begin
    MinY := GY + GroundClearance;
    if P.Y < MinY then P.Y := MinY;
    Exit;
  end;

  { Backstop — never drop below the rider's own ground plane (covers the
    case where neither the provider nor the raycast resolved). }
  if Assigned(FTarget) then
  begin
    MinY := FTarget.Translation.Y + MinCameraY;
    if P.Y < MinY then P.Y := MinY;
  end;
end;

procedure TCinematicCamera.PlaceRoadsideCamera;
var
  AheadDist, RoadsideSide: Single;
  LP: TPathPosition;
  AheadPos, AheadDir, SideVec: TVector3;
begin
  if not Assigned(FTarget) then Exit;

  { Place camera 30m ahead of current position on path }
  AheadDist := RoadsidePlaceAhead;
  if Assigned(FPath) and (FPath.PointCount >= 2) then
  begin
    LP := FPathPos;
    FPath.AdvanceFollow(LP, AheadDist);
    AheadPos := FPath.RoadCenterAt(LP);
    AheadDir := FPath.FollowDirectionXZ(LP);
  end else begin
    AheadDir := FTarget.Direction;
    AheadDir.Y := 0;
    if AheadDir.Length < 0.001 then AheadDir := Vector3(0, 0, 1)
    else AheadDir := AheadDir.Normalize;
    AheadPos := FTarget.Translation + AheadDir * AheadDist;
  end;

  { Pick random side }
  if Random(2) = 0 then RoadsideSide := 1.0 else RoadsideSide := -1.0;

  SideVec := TVector3.CrossProduct(AheadDir, Vector3(0, 1, 0));
  if SideVec.Length > 0.001 then SideVec := SideVec.Normalize
  else SideVec := Vector3(1, 0, 0);

  FShot.RoadsideAnchor := AheadPos
    + SideVec * (RoadsideDist * RoadsideSide)
    + Vector3(0, RoadsideAbove, 0);

  { The candidate is not displayed until its own terrain query is ready. }
end;

function TCinematicCamera.PickStationary: TCameraMode;
begin
  { Mostly restful static shots; an occasional short orbit arc for life.
    Two orbit segments in a row are avoided — after an orbit always cut to
    a static, so the frame never rotates for long. }
  if (FShot.Mode <> cmOrbit) and (Random(100) < OrbitChance) then
    Result := cmOrbit
  else
    Result := cmStandShot;
end;

procedure TCinematicCamera.PlaceStandShot;
var
  Ang, Dist, H: Single;
begin
  if not Assigned(FTarget) then Exit;
  { Random angle / distance / height around the standing rider. Height is
    anchored to the ground UNDER the camera (seam-robust), so a rider stopped
    on a slope gets a valid shot from the uphill side too. Placed ONCE on
    entry — the camera then holds perfectly still (the restful shot). }
  Ang  := Random * 2 * Pi;
  Dist := StandDistMin + Random * (StandDistMax - StandDistMin);
  H    := StandHeightMin + Random * (StandHeightMax - StandHeightMin);
  FShot.StandAnchor := FTarget.Translation
    + Vector3(Cos(Ang) * Dist, 0, Sin(Ang) * Dist);
  FShot.StandHeight := H;
  FShot.StandAnchor.Y := FTarget.Translation.Y + H;
end;

{ ── Camera computations ── }

procedure TCinematicCamera.ComputeMode(M: TCameraMode; out P, D, U: TVector3);
var
  TPos, Fwd, Side, LookAt, RouteLook: TVector3;
  LP: TPathPosition;
  GY: Single;
  HDir: TVector3;
  HLen: Single;
  LookSrc: string;
  HasRoute: Boolean;
begin
  U := Vector3(0, 1, 0);
  TPos := FTarget.Translation;
  Fwd := FTarget.Direction;
  Fwd.Y := 0;
  if Fwd.Length > 0.001 then Fwd := Fwd.Normalize else Fwd := Vector3(0, 0, 1);
  Side := TVector3.CrossProduct(Fwd, Vector3(0, 1, 0));
  if Side.Length > 0.001 then Side := Side.Normalize else Side := Vector3(1, 0, 0);
  LookSrc := 'none';
  HasRoute := False;
  RouteLook := TPos;
  LookAt := TPos + Vector3(0, 1.2, 0);

  case M of
    cmMoto:
    begin
      { Motorcycle following — behind + above, looking ahead on the rider route }
      P := TPos - Fwd * MotoBehind + Vector3(0, MotoAbove, 0);
      if Assigned(FPath) and (FPath.PointCount >= 2) then
      begin
        LP := FPathPos;
        FPath.AdvanceFollow(LP, MotoLookAhead);
        LookAt := FPath.RoadCenterAt(LP);
        { Route Y is unreliable on streamed maps (the route's elevation does
          not match the terrain mesh the rider actually rides on), which made
          this point sit BELOW the surface so the cam looked into the ground.
          Pin the look-ahead height to the real ground under that XZ. }
        if GroundYRemembered(LookAt.X, LookAt.Z, False, FShot.LookGround, GY) then
          LookAt.Y := GY + 1.5
        else
          LookAt.Y := TPos.Y + 1.5;
        RouteLook := LookAt;
        HasRoute := True;
        { 60% rider / 40% road ahead: the rider is the SUBJECT of the rear
          view (whole model centered in frame), the ahead-point only steers
          the framing into upcoming turns }
        LookAt := LookAt * 0.4 + (TPos + Vector3(0, MotoAimHeight, 0)) * 0.6;
        LookSrc := 'moto:0.4*route+0.6*rider';
      end
      else
      begin
        LookAt := TPos + Fwd * 20 + Vector3(0, MotoAimHeight, 0);
        LookSrc := 'moto:fwd20(no-path)';
      end;
    end;

    cmHelicopter:
    begin
      { High wide shot — shows road layout and group. Placed far back + to
        the side + high; the height also respects the terrain under the
        CAMERA (a hill behind the rider must not eat the altitude). }
      P := TPos - Fwd * HeliBehind + Side * HeliSide + Vector3(0, HeliAbove, 0);
      if GroundYRemembered(P.X, P.Z, True, FShot.CameraGround, GY) and
         (P.Y < GY + HeliAbove * 0.7) then
        P.Y := GY + HeliAbove * 0.7;
      if Assigned(FPath) and (FPath.PointCount >= 2) then
      begin
        LP := FPathPos;
        FPath.AdvanceFollow(LP, HeliLookAhead);
        LookAt := FPath.RoadCenterAt(LP);
        if GroundYRemembered(LookAt.X, LookAt.Z, False, FShot.LookGround, GY) then
          LookAt.Y := GY + 1.0
        else
          LookAt.Y := TPos.Y + 1.0;
        RouteLook := LookAt;
        HasRoute := True;
        { 70% road ahead, 30% rider — a helicopter frames the ROUTE; the old
          50/50 pulled the aim onto the rider 12 m away and the cam stared
          almost straight down: the frame was all ground, which read as
          "flying half a meter above the terrain" }
        LookAt := LookAt * 0.7 + (TPos + Vector3(0, 1, 0)) * 0.3;
        LookSrc := 'heli:0.7*route+0.3*rider';
      end
      else
      begin
        LookAt := TPos + Fwd * 40 + Vector3(0, 1, 0);
        LookSrc := 'heli:fwd40(no-path)';
      end;
      { WIDE-shot guarantee: if the look point ended up too close horizontally
        (a short route look-ahead, sharp switchback), push it away along the
        same bearing until the down-pitch is <= ~32 deg — the horizon stays in
        frame no matter what the path data does. }
      HDir := LookAt - P; HDir.Y := 0;
      HLen := HDir.Length;
      if HLen < (P.Y - LookAt.Y) * HeliMinFlatPerHeight then
      begin
        if HLen > 0.001 then HDir := HDir * (1.0 / HLen) else HDir := Fwd;
        LookAt := Vector3(P.X, LookAt.Y, P.Z)
          + HDir * ((P.Y - LookAt.Y) * HeliMinFlatPerHeight);
        LookSrc := LookSrc + '+wideClamp';
      end;
    end;

    cmRoadside:
    begin
      { Static camera — placed once, watches riders pass }
      if FPreparingShot and GroundYRemembered(FShot.RoadsideAnchor.X,
        FShot.RoadsideAnchor.Z, True, FShot.CameraGround, GY) then
        FShot.RoadsideAnchor.Y := GY + RoadsideAbove;
      P := FShot.RoadsideAnchor;
      LookAt := TPos + Vector3(0, 1.0, 0);
      LookSrc := 'roadside:rider';
    end;

    cmReverse:
    begin
      { Motorcycle ahead — looking back at approaching rider }
      P := TPos + Fwd * ReverseAhead + Vector3(0, ReverseAbove, 0);
      LookAt := TPos + Vector3(0, 1.2, 0);
      LookSrc := 'reverse:rider';
    end;

    cmLowTrack:
    begin
      { Low angle from the roadside — dramatic, close. Anchor the height to
        the GROUND under the camera's own XZ (seam-robust), not the rider's
        Y: where the road is cut into a slope the side terrain sits above the
        rider, so a rider-relative low cam ended up inside the hillside. }
      P := TPos + Side * LowTrackSide;
      if GroundYRemembered(P.X, P.Z, True, FShot.CameraGround, GY) then
        P.Y := GY + LowTrackAbove
      else
        P.Y := TPos.Y + LowTrackAbove;
      LookAt := TPos + Vector3(0, 1.0, 0);
      LookSrc := 'lowtrack:rider';
    end;

    cmOrbit:
    begin
      { STATIONARY-RIDER scenario — a SHORT slow arc around the standing
        rider (6-9 s at ~9 deg/s ≈ a 60-80 deg sweep, then a cut to a static
        shot — continuous rotation is dizzying). FShot.OrbitAngle is advanced in
        Update (it has the DT); here we only place the camera on that
        azimuth. Radius breathes gently along the arc. Height is anchored to
        the ground UNDER the camera (seam-robust) like cmLowTrack, so
        arcing around a rider stopped on a slope never buries the cam in the
        hillside on the uphill part. }
      GY := FShot.OrbitRadius + OrbitBreathAmp * Sin(FShot.OrbitAngle * 0.5);  { GY reused as radius }
      P := TPos + Vector3(Cos(FShot.OrbitAngle) * GY, 0, Sin(FShot.OrbitAngle) * GY);
      if GroundYRemembered(P.X, P.Z, True, FShot.CameraGround, GY) then
        P.Y := GY + OrbitHeight
      else
        P.Y := TPos.Y + OrbitHeight;
      LookAt := TPos + Vector3(0, 1.2, 0);   { rider's chest }
      LookSrc := 'orbit:rider';
    end;

    cmStandShot:
    begin
      { STATIONARY-RIDER scenario — perfectly still camera at a random angle,
        placed once on entry (PlaceStandShot). The restful default shot the
        scenario keeps returning to between short orbit arcs. }
      if FPreparingShot and GroundYRemembered(FShot.StandAnchor.X,
        FShot.StandAnchor.Z, True, FShot.CameraGround, GY) then
        FShot.StandAnchor.Y := GY + FShot.StandHeight;
      P := FShot.StandAnchor;
      LookAt := TPos + Vector3(0, 1.2, 0);   { rider's chest }
      LookSrc := 'standshot:rider';
    end;
  end;

  { Clamp the camera above ground FIRST, then aim. If we aimed before
    clamping, a clamp that lifts P (e.g. on a descent, where the ground
    behind the rider sits higher than the rider) would leave the look
    direction pointing at the camera's OLD position — which reads as the
    moto cam staring straight into the ground. }
  ClampAboveGround(P);
  if not FPreparingShot then SmoothHeight(P);
  D := LookAt - P;
  if D.Length > 0.001 then D := D.Normalize
  else D := Fwd;

  { per-mode down-pitch limit — see ClampDownPitch; re-applied once more in
    Update AFTER AdjustForGroup, because the group re-aim runs last }
  ClampDownPitch(D, MaxLookDownSin);

  { DIAG: targets found for this frame (throttled inside). }
  LogCamTargets(M, TPos, P, LookAt, RouteLook, LookSrc, HasRoute);
end;

{ Never look more steeply down than MaxDownSin. If the aim is steeper — e.g.
  a close side cam lifted high by a terrain height spike, or the GROUP
  re-aim from a high helicopter — flatten the pitch to the limit keeping the
  horizontal heading, so the (0,1,0) up vector stays well-defined and the
  frame keeps the horizon instead of showing bare ground. D must be a unit
  vector; a near-vertical D keeps its (tiny) horizontal heading. }
procedure TCinematicCamera.ClampDownPitch(var D: TVector3; const MaxDownSin: Single);
var
  HDir: TVector3;
  HLen: Single;
begin
  if D.Y >= -MaxDownSin then Exit;
  HLen := Sqrt(1.0 - MaxDownSin * MaxDownSin);        { horizontal part of a unit dir }
  HDir := Vector3(D.X, 0, D.Z);
  if HDir.Length > 0.001 then HDir := HDir.Normalize
  else HDir := Vector3(1, 0, 0);                       { aim ~straight down: any heading }
  D := HDir * HLen + Vector3(0, -MaxDownSin, 0);       { unit length, pitch = asin(MaxDownSin) }
end;

{ ── Nearby riders ── }

procedure TCinematicCamera.ClearNearby;
begin FNearbyCount := 0; end;

procedure TCinematicCamera.AddNearby(const APos: TVector3);
begin
  if FNearbyCount >= Length(FNearby) then SetLength(FNearby, FNearbyCount + 8);
  FNearby[FNearbyCount] := APos;
  Inc(FNearbyCount);
end;

procedure TCinematicCamera.AdjustForGroup(var P, D: TVector3);
var
  I: Integer;
  Center, CamRight, ToR: TVector3;
  MaxSide, SD, Pull, TotalWeight, Weight: Single;

  function RiderWeight(const Pos: TVector3): Single;
  begin
    Result := EnsureRange((30.0 - (Pos - FTarget.Translation).Length) / 10.0, 0.0, 1.0);
  end;
begin
  if FNearbyCount = 0 then Exit;
  Center := FTarget.Translation;
  TotalWeight := 1;
  for I := 0 to FNearbyCount - 1 do
  begin
    Weight := RiderWeight(FNearby[I]);
    Center := Center + FNearby[I] * Weight;
    TotalWeight := TotalWeight + Weight;
  end;
  { A rider crossing the 30 m collection boundary must not shift the frame. }
  if TotalWeight <= 1.0001 then Exit;
  Center := Center * (1.0 / TotalWeight);

  CamRight := TVector3.CrossProduct(D, Vector3(0, 1, 0));
  if CamRight.Length > 0.001 then CamRight := CamRight.Normalize;

  MaxSide := 0;
  for I := 0 to FNearbyCount - 1 do
  begin
    ToR := FNearby[I] - Center;
    SD := Abs(TVector3.DotProduct(ToR, CamRight)) * RiderWeight(FNearby[I]);
    if SD > MaxSide then MaxSide := SD;
  end;

  { Pull camera back to fit group }
  if MaxSide > 3 then
  begin
    Pull := (MaxSide - 3) * 0.8;
    P := P - D * Pull;
    ClampAboveGround(P, True);
  end;

  { Re-aim at group center }
  ToR := (Center + Vector3(0, 1.2, 0)) - P;
  if ToR.Length > 0.001 then
  begin
    Weight := Min(1.0, TotalWeight - 1.0);
    D := D * (1 - Weight) + ToR.Normalize * Weight;
    if D.Length > 0.001 then D := D.Normalize;
  end;
end;

{ ── Mode switching ── }

procedure TCinematicCamera.KeepRiderInFrame(var P, D: TVector3);
var
  Corners: array[0..7] of TVector3;
  Center, Fwd, Side, BodyUp, Aim, Right, Up, V, Offset, Candidate: TVector3;
  Fov: TVector2;
  TanX, TanY, Distance, Required, Depth, Lo, Hi, Blend, Pitch: Single;
  I, Pass: Integer;

  procedure Basis(const Direction: TVector3);
  begin
    Right:=TVector3.CrossProduct(Direction,Vector3(0,1,0));
    if Right.Length<0.001 then Right:=Side else Right:=Right.Normalize;
    Up:=TVector3.CrossProduct(Right,Direction).Normalize;
  end;

  function Fits(const Direction: TVector3): Boolean;
  var K: Integer; ToCorner: TVector3; Z: Single;
  begin
    Basis(Direction);
    for K:=0 to High(Corners) do
    begin
      ToCorner:=Corners[K]-P;
      Z:=TVector3.DotProduct(ToCorner,Direction);
      if (Z<0.1) or (Abs(TVector3.DotProduct(ToCorner,Right))>Z*TanX) or
        (Abs(TVector3.DotProduct(ToCorner,Up))>Z*TanY) then Exit(False);
    end;
    Result:=True;
  end;

begin
  if (FTarget=nil) or (FViewport=nil) or (FViewport.Camera=nil) then Exit;
  if FViewport.Camera.ProjectionType<>ptPerspective then Exit;
  { A stable envelope, in metres, for the bike and rider through a pedal
    cycle. Do not read rest-pose skin bounds or bounds of the shadow rig. }
  Fwd:=FTarget.Direction; Fwd.Y:=0;
  if Fwd.Length<0.001 then Fwd:=Vector3(0,0,1) else Fwd:=Fwd.Normalize;
  Side:=TVector3.CrossProduct(Fwd,Vector3(0,1,0));
  Pitch:=DegToRad(FTargetPitchDeg);
  BodyUp:=Vector3(0,Cos(Pitch),0)-Fwd*Sin(Pitch);
  Fwd:=Fwd*Cos(Pitch)+Vector3(0,Sin(Pitch),0);
  Center:=FTarget.Translation+BodyUp*0.95;
  for I:=0 to High(Corners) do
    Corners[I]:=Center+Fwd*(1.15*(2*(I and 1)-1))+
      Side*(0.5*(2*((I shr 1) and 1)-1))+
      BodyUp*(1.1*(2*((I shr 2) and 1)-1));
  Fov:=FViewport.Camera.Perspective.EffectiveFieldOfView;
  if Fov.X<=0 then Fov.X:=FViewport.Camera.Perspective.FieldOfView;
  if Fov.Y<=0 then Fov.Y:=FViewport.Camera.Perspective.FieldOfView;
  TanX:=Tan(Fov.X*0.5)*0.85; TanY:=Tan(Fov.Y*0.5)*0.85;
  if Fits(D) then Exit;

  { Only retreat when even a centered shot cannot contain the envelope.
    Recheck after terrain clearance raises the camera on a hillside. }
  for Pass:=0 to 3 do
  begin
    Aim:=Center-P; Distance:=Aim.Length;
    if Distance<0.01 then Aim:=-Fwd else Aim:=Aim/Distance;
    if Fits(Aim) then Break;
    Basis(Aim); Required:=Distance;
    for I:=0 to High(Corners) do
    begin
      Offset:=Corners[I]-Center; Depth:=TVector3.DotProduct(Offset,Aim);
      Required:=Max(Required,Max(Abs(TVector3.DotProduct(Offset,Right))/TanX,
        Abs(TVector3.DotProduct(Offset,Up))/TanY)-Depth);
    end;
    P:=Center-Aim*(Required+0.1);
    ClampAboveGround(P, True);
  end;
  Aim:=Center-P;
  if Aim.Length<0.001 then Exit;
  Aim:=Aim.Normalize;
  if Fits(D) then Exit;

  { Keep as much route/group look-ahead as the frame allows. A bounded
    search changes direction continuously as the slope increases, instead
    of switching abruptly between road aim and rider aim. No mesh queries. }
  Lo:=0; Hi:=1;
  for I:=1 to 10 do
  begin
    Blend:=(Lo+Hi)*0.5;
    V:=D*(1-Blend)+Aim*Blend;
    if V.Length<0.001 then begin Lo:=Blend; Continue end;
    Candidate:=V.Normalize;
    if Fits(Candidate) then Hi:=Blend else Lo:=Blend;
  end;
  D:=(D*(1-Hi)+Aim*Hi).Normalize;
end;

procedure TCinematicCamera.NextMode;
begin
  { Standing rider: manual cycling picks the next stationary shot (mostly a
    fresh static angle, sometimes a short orbit arc) — the broadcast cutaways
    assume motion. }
  if FStationary then
    ForceMode(PickStationary)
  else if FShot.Mode = cmMoto then
    ForceMode(PickCutaway)
  else
    ForceMode(cmMoto);
end;

procedure TCinematicCamera.ForceMode(M: TCameraMode);
var
  Active: TCameraShotState;
  P: TVector3;
begin
  if not Assigned(FTarget) or not Assigned(FViewport) then Exit;
  SyncPathPosition;
  Active := FShot;
  try
    FShot := Default(TCameraShotState);
    FShot.Mode := M;
    if M = cmRoadside then PlaceRoadsideCamera;
    if M = cmStandShot then PlaceStandShot;
    if M = cmOrbit then
    begin
      if Random(2) = 0 then FShot.OrbitDir := 1 else FShot.OrbitDir := -1;
      FShot.OrbitRadius := OrbitRadiusBase + (Random - 0.5) * 2 * OrbitRadiusJitter;
      P := FCamPos - FTarget.Translation;
      if Sqrt(Sqr(P.X) + Sqr(P.Z)) > 0.5 then
        FShot.OrbitAngle := ArcTan2(P.Z, P.X)
      else FShot.OrbitAngle := Random * 2 * Pi;
    end;
    FPendingShot := FShot;
  finally FShot := Active end;
  FPending := True;
  FPendingAge := 0;
  TryPendingShot;
end;

procedure TCinematicCamera.TryPendingShot;
var
  Active: TCameraShotState;
  P, D, U: TVector3;
begin
  if not FPending then Exit;
  Active := FShot;
  FShot := FPendingShot;
  FPreparingShot := True;
  FProbeReady := True;
  try
    ComputeMode(FShot.Mode, P, D, U);
    FrameShot(P, D);
    FPendingShot := FShot;
  finally
    FShot := Active;
    FPreparingShot := False;
  end;
  if FProbeReady then
  begin
    Inc(FShotSerial);
    FShot := FPendingShot;
    FPending := False;
    FHeightReady := False;
    FModeTimer := ModeDuration(FShot.Mode);
    FCamPos := P; FCamDir := D; FCamUp := U;
    if Assigned(Logger) then
      Logger.Info('[CineCam] cut=' + ModeName(FShot.Mode) + ' terrain=ready');
  end else if FPendingAge >= 2.0 then
  begin
    { Unloaded terrain or a missing surface: retain a valid shot, retry a
      different cut later. Never stall the game or snap to a guessed floor. }
    FPending := False;
    FModeTimer := 5;
  end;
end;

procedure TCinematicCamera.SmoothHeight(var P: TVector3);
var Offset, Alpha: Single;
begin
  { Static shots hold their anchor. Moving shots follow the rider without
    motion lag; only the terrain-relative correction is damped. This absorbs
    short GPU holds followed by a fresh slope sample. }
  if FShot.Mode in [cmRoadside, cmStandShot] then Exit;
  Offset := P.Y - FTarget.Translation.Y;
  if FHeightReady then
  begin
    Alpha := 1 - Exp(-8 * FFrameDT);
    P.Y := FTarget.Translation.Y + FHeightOffset + (Offset-FHeightOffset)*Alpha;
    { A rising surface remains solid; smoothing may never bury the camera. }
    ClampAboveGround(P);
  end;
  FHeightOffset := P.Y - FTarget.Translation.Y;
  FHeightReady := True;
end;

procedure TCinematicCamera.FrameShot(var P, D: TVector3);
begin
  AdjustForGroup(P, D);
  if FShot.Mode = cmHelicopter then ClampDownPitch(D, HeliMaxDownSin)
  else ClampDownPitch(D, MaxLookDownSin);
  KeepRiderInFrame(P, D);
end;

{ ── Main update ── }

procedure TCinematicCamera.Update(const DT: Single);
var
  TP, TD, TU: TVector3;
begin
  if not FEnabled then Exit;
  if not Assigned(FViewport) or not Assigned(FTarget) or (FViewport.Camera = nil) then Exit;
  if IsNan(DT) or IsInfinite(DT) or (DT < 0) then Exit;
  FFrameDT := DT;

  { Scene preparation/teleport may move the rider onto a completely different
    level. A static anchor or a floor from before that move is no longer valid. }
  if FHaveTargetPosition and
    ((FTarget.Translation - FLastTargetPosition).Length > Max(20.0, Abs(FTargetSpeed) * DT * 3 + 3)) then
    ResetTracking;
  FLastTargetPosition := FTarget.Translation;
  FHaveTargetPosition := True;

  { ── stationary-rider scenario: detect stop/start with hysteresis ──
    Enter after the speed stays below StillEnterSpeed for StillEnterDelay
    (a track-stand wobble or a brief zero between frames does not trigger);
    exit immediately once the rider is clearly moving again. }
  if FAutoSwitch then
  begin
    if FTargetSpeed < StillEnterSpeed then
      FStillTime := FStillTime + DT
    else
      FStillTime := 0;

    if (not FStationary) and (FStillTime >= StillEnterDelay) then
    begin
      FStationary := True;
      ForceMode(cmStandShot);        { enter on the restful STATIC shot }
    end
    else if FStationary and (FTargetSpeed > StillExitSpeed) then
    begin
      FStationary := False;
      FStillTime := 0;
      ForceMode(cmMoto);             { rolling again — back to the main follow }
    end;
  end;

  { advance the orbit while it runs (ComputeMode has no DT) }
  if FShot.Mode = cmOrbit then
    FShot.OrbitAngle := FShot.OrbitAngle + DegToRad(OrbitDegPerSec) * FShot.OrbitDir * DT;

  SyncPathPosition;

  { Auto-switch: Moto → cutaway → Moto → ... While the rider stands, the
    scenario alternates its own shots: mostly static angles, an occasional
    SHORT orbit arc, never two orbits in a row — no prolonged rotation. }
  if FAutoSwitch and not FPending then
  begin
    FModeTimer := FModeTimer - DT;
    if FModeTimer <= 0 then
    begin
      if FStationary then
        ForceMode(PickStationary)
      else if FShot.Mode = cmMoto then
        ForceMode(PickCutaway)   { moto expired → pick a cutaway }
      else
        ForceMode(cmMoto);       { cutaway expired → always back to moto }
    end;
  end;

  if FPending then
  begin
    FPendingAge := FPendingAge + DT;
    TryPendingShot;
  end;

  { Compute camera for current mode }
  ComputeMode(FShot.Mode, TP, TD, TU);
  FrameShot(TP, TD);

  { Rigid follow — instant, like broadcast }
  FCamPos := TP;
  FCamDir := TD;
  FCamUp := Vector3(0, 1, 0);

  FViewport.Camera.SetView(FCamPos, FCamDir, FCamUp);
end;

end.
