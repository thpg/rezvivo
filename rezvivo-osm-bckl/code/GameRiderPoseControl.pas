unit GameRiderPoseControl;

{ ═══════════════════════════════════════════════════════════════════════════════
  Automatic in-game rider-pose manager.

  Watches the live riding situation (speed, power, cadence, road grade and the
  rider's FTP) each frame and smoothly blends the bike's glTF rider into a pose
  chosen from RiderPoseCatalog shared by the game and editors. Poses flagged
  Special (event poses such as drinking) are skipped by the automatic selector;
  they are played on demand via TriggerSpecial instead.

  Highest matching priority wins; equal-priority variants may alternate after
  a dwell. Cadence excludes standing while coasting. The default is a genuine
  fallback, and event poses are never picked automatically. Motion intensity
  is fed continuously, independently of the much slower posture selection.

  The manager OWNS its TRiderPoseList but NOT the TBikeInstance it drives.
  ═══════════════════════════════════════════════════════════════════════════════ }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, RiderTripo, BikeParametric;

type
  { Live inputs, sampled once per frame by the caller. }
  TRiderSituation = record
    SpeedKmh:   Single;   { ground speed, km/h }
    PowerW:     Single;   { current power, W }
    CadenceRpm: Single;   { current cadence, rpm (0 = coasting) }
    GradePct:   Single;   { road grade, % (+ = climbing) }
    FtpW:       Single;   { rider FTP, W (<= 0 -> FallbackFtp is used) }
    LateralAccel: Single; { cornering load, m/s² (|v²/r|); large -> a sharp turn }
  end;

  TPoseManagerReplay = record
    CurIdx: Integer;
    DwellTimer: Single;
    StopTimer: Single;
    SpecialActive: Boolean;
    SpecialTimer: Single;
  end;

  TRiderPoseManager = class
  private
    FBike:           TBikeInstance;   { driven, NOT owned }
    FPoses:          TRiderPoseList;  { owned }
    FFallbackFtp:    Single;
    FTransitionSec:  Single;
    FRerollSec:      Single;          { re-draw a (possibly new) pose this often, for variety }
    FMinDwellSec:    Single;          { minimum time in a pose before any switch }
    FSharpTurnAccel: Single;          { |lateral accel| at/above which a turn pose is used, m/s² }

    FCurIdx:     Integer;   { pose currently applied, -1 = none yet }
    FDwellTimer: Single;    { time since the current pose was applied }
    FStopTimer: Single;

    FSpecialActive: Boolean;
    FSpecialTimer:  Single;  { remaining special hold; <= 0 while active = until ClearSpecial }

    function EffFtp(const S: TRiderSituation): Single;
    function IntensityOf(const S: TRiderSituation): Single;
    function Matches(const P: TRiderPose; Intensity: Single; const S: TRiderSituation): Boolean;
    function PickWeightedIndex(const S: TRiderSituation; SharpTurn: Boolean): Integer;
    function CurrentStillEligible(const S: TRiderSituation; SharpTurn: Boolean): Boolean;
    procedure ApplyIndex(Idx: Integer; Duration: Single = -1);
    function StoppedIndex: Integer;
  public
    function CaptureReplay: TPoseManagerReplay;
    procedure RestoreReplay(const Saved: TPoseManagerReplay);
  public
    constructor Create(ABike: TBikeInstance);
    destructor Destroy; override;

    procedure SetPoses(ASource: TRiderPoseList);           { copy poses in from an existing list }
    { Байкфит: один kneeFlare/ankleFlex поверх всех поз каталога. }
    procedure OverlayKneeAnkle(KneeFlare, AnkleFlex: Single);

    { Call every frame with the freshly sampled situation. }
    procedure Update(Dt: Single; const S: TRiderSituation);

    { Play a Special (event) pose by name, e.g. 'Вода'. HoldSec > 0 auto-returns to
      auto selection after the hold; HoldSec <= 0 holds until ClearSpecial. }
    function TriggerSpecial(const AName: string; HoldSec: Single = 0): Boolean;
    procedure ClearSpecial;

    function CurrentPoseName: string;
    function PoseCount: Integer;

    { diagnostics — safe to call any time }
    function DumpPoses: string;
    function DebugLine(const S: TRiderSituation): string;

    property Poses:          TRiderPoseList read FPoses;
    property FallbackFtp:    Single read FFallbackFtp    write FFallbackFtp;
    property TransitionSec:  Single read FTransitionSec  write FTransitionSec;
    property RerollSec:      Single read FRerollSec      write FRerollSec;
    property MinDwellSec:    Single read FMinDwellSec    write FMinDwellSec;
    property SharpTurnAccel: Single read FSharpTurnAccel  write FSharpTurnAccel;
  end;

implementation

uses
  Math, RiderPoseCatalog;

function TRiderPoseManager.CaptureReplay: TPoseManagerReplay;
begin
  Result.CurIdx:=FCurIdx;
  Result.DwellTimer:=FDwellTimer;
  Result.StopTimer:=FStopTimer;
  Result.SpecialActive:=FSpecialActive;
  Result.SpecialTimer:=FSpecialTimer;
end;

procedure TRiderPoseManager.RestoreReplay(const Saved: TPoseManagerReplay);
begin
  FCurIdx:=Saved.CurIdx;
  FDwellTimer:=Saved.DwellTimer;
  FStopTimer:=Saved.StopTimer;
  FSpecialActive:=Saved.SpecialActive;
  FSpecialTimer:=Saved.SpecialTimer;
end;

constructor TRiderPoseManager.Create(ABike: TBikeInstance);
begin
  inherited Create;
  FBike := ABike;
  FPoses := TRiderPoseList.Create;
  LoadBuiltinRiderPoses(FPoses);
  FFallbackFtp    := 200;
  FTransitionSec  := 1.2;
  FRerollSec      := 18.0;
  FMinDwellSec    := 4.0;
  FSharpTurnAccel := 2.5;   { ~14° lean; above this the rider uses a cornering pose }
  FCurIdx     := -1;
  FDwellTimer := 0;
  FSpecialActive := False;
  FSpecialTimer  := 0;
  FStopTimer := 0;
  { The waiting rider starts with support, even while the simulation is paused. }
  ApplyIndex(StoppedIndex, 0);
end;

destructor TRiderPoseManager.Destroy;
begin
  FPoses.Free;
  inherited Destroy;
end;

function TRiderPoseManager.EffFtp(const S: TRiderSituation): Single;
begin
  if S.FtpW > 1 then Result := S.FtpW
  else                Result := FFallbackFtp;
  if Result < 1 then Result := 1;          { never divide by zero }
end;

function TRiderPoseManager.IntensityOf(const S: TRiderSituation): Single;
begin
  Result := S.PowerW / EffFtp(S);
  if Result < 0 then Result := 0;
end;

function TRiderPoseManager.Matches(const P: TRiderPose; Intensity: Single;
  const S: TRiderSituation): Boolean;
begin
  Result :=
    (not P.Special) and
    ((not P.Grounded) or ((Abs(S.SpeedKmh) < 0.5) and
      (S.CadenceRpm < 4) and (S.PowerW < 10))) and
    ((P.Motion.Standing < 0.5) or (S.CadenceRpm >= 35)) and
    (S.SpeedKmh >= P.SelSpeedMin)     and (S.SpeedKmh <= P.SelSpeedMax)     and
    (Intensity  >= P.SelIntensityMin) and (Intensity  <= P.SelIntensityMax) and
    (S.GradePct >= P.SelGradeMin)     and (S.GradePct <= P.SelGradeMax);
end;

{ Only the highest matching priority participates in the draw. Equal-priority
  variants may alternate; a single match is returned directly. }
function TRiderPoseManager.PickWeightedIndex(const S: TRiderSituation; SharpTurn: Boolean): Integer;
var
  i, n, wsum, w, r, acc, attempt, bestPriority: Integer;
  inten: Single;
  idxs, wts: array of Integer;
  polOk: Boolean;
begin
  Result := -1;
  inten := IntensityOf(S);
  SetLength(idxs, FPoses.Count);
  SetLength(wts,  FPoses.Count);
  n := 0; wsum := 0;
  { Two attempts: attempt 0 keeps poses of the WANTED kind — cornering poses in a
    sharp turn, straight-line poses otherwise. If none of the wanted kind match,
    attempt 1 falls back to the opposite kind so the rider always has a pose. }
  for attempt := 0 to 1 do
  begin
    n := 0; wsum := 0; bestPriority := -1;
    for i := 0 to FPoses.Count - 1 do
    begin
      if not Matches(FPoses[i], inten, S) then Continue;
      polOk := (FPoses[i].TurnSuitable = SharpTurn);
      if attempt = 1 then polOk := not polOk;        { fallback: opposite kind }
      if not polOk then Continue;
      w := Max(0, FPoses[i].SelPriority);
      if w < bestPriority then Continue;
      if w > bestPriority then
      begin n := 0; wsum := 0; bestPriority := w; end;
      idxs[n] := i; wts[n] := w; Inc(wsum, w); Inc(n);
    end;
    if n > 0 then Break;
  end;
  if n = 0 then Exit;                          { nothing matches }
  if n = 1 then begin Result := idxs[0]; Exit; end;
  if wsum <= 0 then                            { all zero-weight -> uniform }
  begin
    Result := idxs[Random(n)];
    Exit;
  end;
  r := Random(wsum);                           { 0 .. wsum-1 }
  acc := 0;
  for i := 0 to n - 1 do
  begin
    Inc(acc, wts[i]);
    if r < acc then begin Result := idxs[i]; Exit; end;
  end;
  Result := idxs[n - 1];                       { numerical safety net }
end;

{ Is the currently-applied pose still an appropriate choice? False when it left
  its window, or when the turn/straight state now wants the other kind of pose
  (and such a pose is actually available). Drives the "must switch" re-draw. }
function TRiderPoseManager.CurrentStillEligible(const S: TRiderSituation; SharpTurn: Boolean): Boolean;
var
  i: Integer;
  inten: Single;
  anyWanted: Boolean;
begin
  Result := False;
  if (FCurIdx < 0) or (FCurIdx >= FPoses.Count) then Exit;
  inten := IntensityOf(S);
  if not Matches(FPoses[FCurIdx], inten, S) then Exit;      { out of its window }
  anyWanted := False;
  for i := 0 to FPoses.Count - 1 do
    if Matches(FPoses[i], inten, S) and (FPoses[i].TurnSuitable = SharpTurn) then
    begin
      anyWanted := True;
      if FPoses[i].SelPriority > FPoses[FCurIdx].SelPriority then Exit;
    end;
  if not anyWanted then
    Result := True                                         { no wanted-kind pose -> current is fine }
  else
    Result := (FPoses[FCurIdx].TurnSuitable = SharpTurn);   { current must be the wanted kind }
end;

function TRiderPoseManager.StoppedIndex: Integer;
var I: Integer;
begin
  Result := -1;
  for I := 0 to FPoses.Count - 1 do
    if FPoses[I].Grounded and not FPoses[I].Special then
      if (Result < 0) or (FPoses[I].SelPriority > FPoses[Result].SelPriority) then Result := I;
end;

procedure TRiderPoseManager.ApplyIndex(Idx: Integer; Duration: Single);
begin
  if (Idx < 0) or (Idx >= FPoses.Count) then Exit;
  if Duration < 0 then Duration := FTransitionSec;
  FBike.ApplyRiderPose(FPoses[Idx], Duration);
  FCurIdx     := Idx;
  FDwellTimer := 0;
end;

procedure TRiderPoseManager.Update(Dt: Single; const S: TRiderSituation);
var
  curOk, sharpTurn, Grounded, WantsStop, WantsStart: Boolean;
  pick: Integer;
begin
  if not Assigned(FBike) then Exit;
  FBike.SetRiderEffort(IntensityOf(S));
  Grounded := (FCurIdx >= 0) and (FCurIdx < FPoses.Count) and FPoses[FCurIdx].Grounded;
  WantsStop := (Abs(S.SpeedKmh) < 0.5) and (S.CadenceRpm < 4) and (S.PowerW < 10);
  WantsStart := (Abs(S.SpeedKmh) > 1.2) or (S.CadenceRpm >= 5) or (S.PowerW >= 12);
  if WantsStop then FStopTimer := FStopTimer + Max(0.0, Dt)
  else FStopTimer := 0;

  { Starting cannot wait for the four-second posture dwell. The bike holds
    the crank through this blend, then accelerates once both feet contact. }
  if Grounded and WantsStart then
  begin
    ClearSpecial;
    pick := PickWeightedIndex(S, False);
    if pick >= 0 then ApplyIndex(pick, 1.05);
    Exit;
  end;

  { Support takes precedence over a drinking/stretching event and its dwell. }
  if (FStopTimer >= 0.25) and not Grounded then
  begin
    pick := StoppedIndex;
    if pick >= 0 then
    begin
      ClearSpecial;
      ApplyIndex(pick, 0.9);
    end;
    Exit;
  end;

  { hold a special (event) pose until its timer runs out or it is cleared }
  if FSpecialActive then
  begin
    if FSpecialTimer > 0 then
    begin
      FSpecialTimer := FSpecialTimer - Dt;
      if FSpecialTimer <= 0 then ClearSpecial;   { -> auto selection resumes below, next frame }
    end;
    if FSpecialActive then Exit;                 { still holding -> no auto selection }
  end;

  if FPoses.Count = 0 then Exit;
  { Never switch between planted feet at random while waiting. }
  if Grounded then Exit;
  FDwellTimer := FDwellTimer + Dt;
  sharpTurn := Abs(S.LateralAccel) >= FSharpTurnAccel;

  { first pose / just left a special -> draw immediately }
  if FCurIdx < 0 then
  begin
    pick := PickWeightedIndex(S, sharpTurn);
    if pick >= 0 then ApplyIndex(pick);
    Exit;
  end;

  { hold the current pose at least MinDwellSec — kills flicker at window/turn edges }
  if FDwellTimer < FMinDwellSec then Exit;

  { re-draw when the current pose is no longer appropriate (left its window, or the
    turn/straight state now wants the other kind), or every RerollSec for variety }
  curOk := CurrentStillEligible(S, sharpTurn);
  if (not curOk) or (FDwellTimer >= FRerollSec) then
  begin
    pick := PickWeightedIndex(S, sharpTurn);
    if pick >= 0 then
    begin
      if pick <> FCurIdx then
        ApplyIndex(pick)          { switch + blend + reset dwell }
      else
        FDwellTimer := 0;         { same pose drawn again -> just restart the hold }
    end;
    { pick < 0 (nothing matches) -> keep the current pose }
  end;
end;

function TRiderPoseManager.TriggerSpecial(const AName: string; HoldSec: Single): Boolean;
var
  i: Integer;
begin
  Result := False;
  i := FPoses.IndexByName(AName);
  if i < 0 then Exit;
  FBike.ApplyRiderPose(FPoses[i], FTransitionSec);   { event override — plays even though Special }
  FSpecialActive := True;
  FSpecialTimer  := HoldSec;    { <= 0 -> hold until ClearSpecial }
  FCurIdx := i;                 { retain support metadata during the event }
  Result := True;
end;

procedure TRiderPoseManager.ClearSpecial;
begin
  FSpecialActive := False;
  FSpecialTimer  := 0;
  FCurIdx     := -1;           { draw the right auto pose on the next Update }
  FDwellTimer := 0;
end;

function TRiderPoseManager.CurrentPoseName: string;
begin
  if (FCurIdx >= 0) and (FCurIdx < FPoses.Count) then
    Result := FPoses[FCurIdx].Name
  else
    Result := '';
end;

function TRiderPoseManager.PoseCount: Integer;
begin
  Result := FPoses.Count;
end;

function TRiderPoseManager.DumpPoses: string;
var
  i: Integer;
  P: TRiderPose;
  tag: string;
begin
  Result := Format('%d pose(s):', [FPoses.Count]);
  for i := 0 to FPoses.Count - 1 do
  begin
    P := FPoses[i];
    if P.Special then tag := 'EVENT' else tag := 'auto';
    if P.TurnSuitable then tag := tag + '/turn';
    Result := Result + LineEnding +
      Format('  [%d] "%s" %s pr=%d  spd %.0f..%.0f  int %.2f..%.2f  grd %.0f..%.0f',
        [i, P.Name, tag, P.SelPriority,
         P.SelSpeedMin, P.SelSpeedMax, P.SelIntensityMin, P.SelIntensityMax,
         P.SelGradeMin, P.SelGradeMax]);
  end;
end;

function TRiderPoseManager.DebugLine(const S: TRiderSituation): string;
var
  i, nMatch, wsum: Integer;
  inten: Single;
  ts: string;
begin
  inten  := IntensityOf(S);
  nMatch := 0; wsum := 0;
  for i := 0 to FPoses.Count - 1 do
    if Matches(FPoses[i], inten, S) then
    begin
      Inc(nMatch);
      if FPoses[i].SelPriority > 0 then Inc(wsum, FPoses[i].SelPriority);
    end;
  if Abs(S.LateralAccel) >= FSharpTurnAccel then ts := 'TURN' else ts := 'straight';
  Result := Format('[PoseMgr] v=%.1f km/h  P=%.0f W  I=%.2f  g=%.1f%%  latA=%.1f (%s)  cur "%s"  (%d/%d match, wsum=%d)',
    [S.SpeedKmh, S.PowerW, inten, S.GradePct, S.LateralAccel, ts, CurrentPoseName, nMatch, FPoses.Count, wsum]);
end;

procedure TRiderPoseManager.SetPoses(ASource: TRiderPoseList);
var
  i: Integer;
  PreviousName: string;
begin
  PreviousName := CurrentPoseName;
  FPoses.Clear;
  FCurIdx := -1;
  if ASource = nil then Exit;
  for i := 0 to ASource.Count - 1 do
    FPoses.Add(ASource[i]);
  FCurIdx := FPoses.IndexByName(PreviousName);
end;

procedure TRiderPoseManager.OverlayKneeAnkle(KneeFlare, AnkleFlex: Single);
var
  i: Integer;
  P: TRiderPose;
begin
  for i := 0 to FPoses.Count - 1 do
  begin
    P := FPoses[i];
    P.KneeFlare := KneeFlare;
    P.AnkleFlex := AnkleFlex;
    FPoses[i] := P;
  end;
end;

end.
