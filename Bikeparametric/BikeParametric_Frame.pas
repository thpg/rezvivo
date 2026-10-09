{
  Parametric Bike Frame — CPU mesh of all tubes in one IndexedFaceSet.

  Positions/normals are baked at BuildGeometry (ComputeFrameTubes). The
  GPU tube shader (aTubeIdx/T/Phi + uTS/uTE/uTR uniforms, live endpoints
  without rebuild) is stubbed: the TEffectNode was never attached to
  Appearance, so CGE warned every draw that aTube* were unused. Restore
  by hanging the Effect on Shape.Appearance and re-enabling the block in
  BuildGeometry.

  11 tubes: down tube, seat tube, top tube, head tube, BB shell,
  chain stays (L/R), seat stays (L/R), SS bridge, rear axle bridge.

  License: MIT
}
unit BikeParametric_Frame;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, CastleVectors, CastleLog,
  X3DNodes, X3DFields,
  BikeParametric;

type
  TFrameComponent = class(TBikeComponent)
  private
    { Geometry (mm, degrees) }
    FSeatTubeLength: Single;
    FSeatTubeAngle: Single;
    FHeadTubeAngle: Single;
    FHeadTubeLength: Single;
    FChainstayLength: Single;
    FBBDrop: Single;
    FWheelbase: Single;
    FStack: Single;
    FReach: Single;
    FEffectiveTopTubeLength: Single;
    { Tube junctions }
    FTopTubeHTRatio: Single;
    FDownTubeHTRatio: Single;
    FTopTubeSeatRatio: Single;
    FTopTubeSlope: Single;
    { Frame spacing }
    FBBShellWidth: Single;
    FRearDropoutSpacing: Single;
    FFrontDropoutSpacing: Single;
    FSeatStayJctRatio: Single;
    FSeatStayJctHeight: Single;
    { Tube diameters }
    FDownTubeDia: Single;
    FSeatTubeDia: Single;
    FTopTubeDia: Single;
    FHeadTubeDia: Single;
    FChainstayDia: Single;
    FSeatstayDia: Single;
    { Rear suspension travel — belongs to frame triangle }
    FRearTravel: Single;
  public
    constructor Create; override;
    class function ComponentName: string; override;
    procedure ApplyPreset(const APreset: string); override;
    procedure ComputeBones(Skel: TBikeSkeleton); override;
    procedure BuildGeometry(Ctx: TBikeBuildContext); override;
  published
    { Geometry (mm, degrees) }
    property SeatTubeLength: Single read FSeatTubeLength write FSeatTubeLength;
    property SeatTubeAngle: Single read FSeatTubeAngle write FSeatTubeAngle;
    property HeadTubeAngle: Single read FHeadTubeAngle write FHeadTubeAngle;
    property HeadTubeLength: Single read FHeadTubeLength write FHeadTubeLength;
    property ChainstayLength: Single read FChainstayLength write FChainstayLength;
    property BBDrop: Single read FBBDrop write FBBDrop;
    property Wheelbase: Single read FWheelbase write FWheelbase;
    property Stack: Single read FStack write FStack;
    property Reach: Single read FReach write FReach;
    property EffectiveTopTubeLength: Single read FEffectiveTopTubeLength write FEffectiveTopTubeLength;
    { Tube junctions }
    property TopTubeHTRatio: Single read FTopTubeHTRatio write FTopTubeHTRatio;
    property DownTubeHTRatio: Single read FDownTubeHTRatio write FDownTubeHTRatio;
    property TopTubeSeatRatio: Single read FTopTubeSeatRatio write FTopTubeSeatRatio;
    property TopTubeSlope: Single read FTopTubeSlope write FTopTubeSlope;
    { Frame spacing }
    property BBShellWidth: Single read FBBShellWidth write FBBShellWidth;
    property RearDropoutSpacing: Single read FRearDropoutSpacing write FRearDropoutSpacing;
    property FrontDropoutSpacing: Single read FFrontDropoutSpacing write FFrontDropoutSpacing;
    property SeatStayJctRatio: Single read FSeatStayJctRatio write FSeatStayJctRatio;
    property SeatStayJctHeight: Single read FSeatStayJctHeight write FSeatStayJctHeight;
    { Tube diameters }
    property DownTubeDia: Single read FDownTubeDia write FDownTubeDia;
    property SeatTubeDia: Single read FSeatTubeDia write FSeatTubeDia;
    property TopTubeDia: Single read FTopTubeDia write FTopTubeDia;
    property HeadTubeDia: Single read FHeadTubeDia write FHeadTubeDia;
    property ChainstayDia: Single read FChainstayDia write FChainstayDia;
    property SeatstayDia: Single read FSeatstayDia write FSeatstayDia;
    { Rear suspension travel — belongs to frame triangle }
    property RearTravel: Single read FRearTravel write FRearTravel;
  end;

const
  FRAME_TUBE_COUNT = 11;

{ Live frame geometry — call every frame when params may change }
function  IsFrameAnimReady: Boolean;
procedure ResetFrameAnimCache;
procedure ActivateFrameAnim;
{ MM, AWheelRadius, AForkAxleToCrown, AForkRake — МЁРТВЫЕ параметры: тело
  использует только захваченные на билде FF_* (см. комментарий в реализации).
  Сигнатура сохранена для совместимости (вызывает CastleViewFrame). }
procedure FrameAnimateFrame(AFrame: TFrameComponent; MM: Single;
  AWheelRadius, AForkAxleToCrown, AForkRake: Single);

implementation

uses CastleUtils, BikeParametric_Wheel, BikeParametric_Fork, BikeLog;

{ ═══════════════════════════════════════════════════════════════════
  Tube index constants
  ═══════════════════════════════════════════════════════════════════ }

const
  FT_DOWN_TUBE   = 0;
  FT_SEAT_TUBE   = 1;
  FT_TOP_TUBE    = 2;
  FT_HEAD_TUBE   = 3;
  FT_BB_SHELL    = 4;
  FT_CHAINSTAY_L = 5;
  FT_CHAINSTAY_R = 6;
  FT_SEATSTAY_L  = 7;
  FT_SEATSTAY_R  = 8;
  FT_SS_BRIDGE   = 9;
  FT_AXLE_BRIDGE = 10;

  { Road defaults (same values TBikeParams.Create used to set). Single
    source: Create seeds these, ComputeFrameGeom falls back to them on
    invalid input. }
  DEF_SEAT_TUBE_LENGTH      = 540;    { mm }
  DEF_SEAT_TUBE_ANGLE       = 73.5;   { deg }
  DEF_HEAD_TUBE_ANGLE       = 73.0;   { deg }
  DEF_HEAD_TUBE_LENGTH      = 160;    { mm }
  DEF_CHAINSTAY_LENGTH      = 405;    { mm }
  DEF_BB_DROP               = 70;     { mm }
  DEF_WHEELBASE             = 995;    { mm }
  DEF_TOP_TUBE_HT_RATIO     = 0.15;
  DEF_DOWN_TUBE_HT_RATIO    = 0.20;
  DEF_TOP_TUBE_SEAT_RATIO   = 0.97;
  DEF_BB_SHELL_WIDTH        = 68;     { mm }
  DEF_REAR_DROPOUT_SPACING  = 130;    { mm }
  DEF_FRONT_DROPOUT_SPACING = 100;    { mm }
  DEF_SEAT_STAY_JCT_RATIO   = 0.60;
  DEF_DOWN_TUBE_DIA         = 36;     { mm }
  DEF_SEAT_TUBE_DIA         = 32;     { mm }
  DEF_TOP_TUBE_DIA          = 30;     { mm }
  DEF_HEAD_TUBE_DIA         = 44;     { mm }
  DEF_CHAINSTAY_DIA         = 20;     { mm }
  DEF_SEATSTAY_DIA          = 14;     { mm }
  { rear axle sits 0.5 m behind the origin (front = rear + wheelbase) }
  REAR_AXLE_X = -0.5;

type
  TFrameTube = record
    S, E: TVector3;  { start, end in scene space }
    R: Single;       { radius }
  end;
  TFrameTubeArray = array[0..FRAME_TUBE_COUNT-1] of TFrameTube;

{ ═══════════════════════════════════════════════════════════════════
  Cached state for per-frame animation
  ═══════════════════════════════════════════════════════════════════ }

var
  FF_Ready: Boolean = False;
  FF_Captured: Boolean = False;
  FF_UStart: array[0..FRAME_TUBE_COUNT-1] of TSFVec3f;
  FF_UEnd:   array[0..FRAME_TUBE_COUNT-1] of TSFVec3f;
  FF_URad:   array[0..FRAME_TUBE_COUNT-1] of TSFFloat;
  FF_CenterX: Single;
  FF_WheelRadius: Single;
  FF_FAC: Single = DEF_FORK_AXLE_TO_CROWN;   { fork axle-to-crown captured at build }
  FF_FRake: Single = DEF_FORK_RAKE;          { fork rake captured at build }
  FF_MM: Single = 0.001;      { mm->scene scale captured at build }
  FF_LogOnce: Boolean = True;
  FF_TubesSent: Boolean = False;  { OPT dirty-check: трубы посчитаны и отправлены
    для текущих FF_*; входы ComputeFrameTubes (FF_* + параметры AFrame) меняются
    только пересборкой, которая зовёт ResetFrameAnimCache }

function IsFrameAnimReady: Boolean;
begin Result := FF_Ready; end;

procedure ResetFrameAnimCache;
var
  I: Integer;
begin
  FF_Ready := False;
  FF_Captured := False;
  FF_LogOnce := True;
  FF_TubesSent := False;   { первый кадр после Reset обязан считаться и слать }
  { GPU tube effect stubbed — drop stale uniform refs so ActivateFrameAnim
    cannot arm FrameAnimateFrame against a freed Effect. }
  for I := 0 to FRAME_TUBE_COUNT - 1 do begin
    FF_UStart[I] := nil;
    FF_UEnd[I] := nil;
    FF_URad[I] := nil;
  end;
end;

procedure ActivateFrameAnim;
begin
  if FF_UStart[0] <> nil then
    FF_Ready := True;
end;

{ ═══════════════════════════════════════════════════════════════════
  TFrameComponent — lifecycle, presets, JSON
  ═══════════════════════════════════════════════════════════════════ }

constructor TFrameComponent.Create;
begin
  inherited Create;
  FSeatTubeLength         := DEF_SEAT_TUBE_LENGTH;
  FSeatTubeAngle          := DEF_SEAT_TUBE_ANGLE;
  FHeadTubeAngle          := DEF_HEAD_TUBE_ANGLE;
  FHeadTubeLength         := DEF_HEAD_TUBE_LENGTH;
  FChainstayLength        := DEF_CHAINSTAY_LENGTH;
  FBBDrop                 := DEF_BB_DROP;
  FWheelbase              := DEF_WHEELBASE;
  FStack                  := 0;
  FReach                  := 0;
  FEffectiveTopTubeLength := 0;
  FTopTubeHTRatio         := DEF_TOP_TUBE_HT_RATIO;
  FDownTubeHTRatio        := DEF_DOWN_TUBE_HT_RATIO;
  FTopTubeSeatRatio       := DEF_TOP_TUBE_SEAT_RATIO;
  FTopTubeSlope           := 0;
  FBBShellWidth           := DEF_BB_SHELL_WIDTH;
  FRearDropoutSpacing     := DEF_REAR_DROPOUT_SPACING;
  FFrontDropoutSpacing    := DEF_FRONT_DROPOUT_SPACING;
  FSeatStayJctRatio       := DEF_SEAT_STAY_JCT_RATIO;
  FSeatStayJctHeight      := 0;
  FDownTubeDia            := DEF_DOWN_TUBE_DIA;
  FSeatTubeDia            := DEF_SEAT_TUBE_DIA;
  FTopTubeDia             := DEF_TOP_TUBE_DIA;
  FHeadTubeDia            := DEF_HEAD_TUBE_DIA;
  FChainstayDia           := DEF_CHAINSTAY_DIA;
  FSeatstayDia            := DEF_SEATSTAY_DIA;
  FRearTravel             := 0;
end;

class function TFrameComponent.ComponentName: string; begin Result := 'Frame'; end;

procedure TFrameComponent.ApplyPreset(const APreset: string);
begin
  if SameText(APreset, 'gravel') then begin
    ChainstayLength := 425;
    Wheelbase       := 1020;
    HeadTubeAngle   := 71.5;
    SeatTubeAngle   := 73.0;
    BBDrop          := 72;
  end else if SameText(APreset, 'mtb') then begin
    SeatTubeLength      := 450;
    SeatTubeAngle       := 76.0;
    HeadTubeAngle       := 66.0;
    HeadTubeLength      := 110;
    ChainstayLength     := 435;
    BBDrop              := 35;
    Wheelbase           := 1200;
    BBShellWidth        := 73;
    RearDropoutSpacing  := 148;
    FrontDropoutSpacing := 110;
    DownTubeDia         := 44;
    SeatTubeDia         := 34;
    TopTubeDia          := 32;
    HeadTubeDia         := 56;
    ChainstayDia        := 24;
    SeatstayDia         := 16;
  end;
end;

{ ═══════════════════════════════════════════════════════════════════
  Shared frame geometry — validated params + derived junction points,
  computed ONCE for both consumers (GPU tubes and the skeleton)
  ═══════════════════════════════════════════════════════════════════ }

type
  { Validated frame inputs (mm/degrees) + derived junction geometry. }
  TFrameGeom = record
    { validated inputs }
    SeatTubeLength, SeatTubeAngle, HeadTubeAngle, HeadTubeLength: Single;
    ChainstayLength, BBDrop, Wheelbase, BBShellWidth: Single;
    RearDropoutSpacing, TopTubeSeatRatio, TopTubeHTRatio, DownTubeHTRatio: Single;
    SeatStayJctHeight, SeatStayJctRatio: Single;
    { derived }
    AxleY, RearAxleX, BBX, BBY, FrontAxleX: Single;
    SA, HA, STLen, HTLen: Single;
    BBHalfZ, RearHalfZ: Single;
    HTDirX, HTDirY, HTPerpX, HTPerpY: Single;
    HTB, HTT: TVector3;
    SSJctX, SSJctY, SSJctZ, SSBridgeX, SSBridgeY: Single;
  end;

{ Validate the frame params (fallbacks = the DEF_* defaults) and derive the
  shared junction geometry. Does NOT write back to AFrame — ComputeBones
  mirrors the validated values into the component fields itself (plain field
  writes, as the old in-place fallbacks did). Fork params arrive already
  final: callers differ on purpose — ComputeFrameTubes clamps them to the
  road fallback, ComputeBones uses the peer fork's raw values. }
procedure ComputeFrameGeom(AFrame: TFrameComponent; M, AWheelRadius,
  AForkAxleToCrown, AForkRake: Single; out G: TFrameGeom);
var
  SSJctLen, SinHA, BB_Y, FL, FR: Single;
begin
  { ── Validate & copy params ── }
  G.SeatTubeLength := AFrame.SeatTubeLength; if G.SeatTubeLength < 100 then G.SeatTubeLength := DEF_SEAT_TUBE_LENGTH;
  G.SeatTubeAngle := AFrame.SeatTubeAngle; if (G.SeatTubeAngle < 60) or (G.SeatTubeAngle > 90) then G.SeatTubeAngle := DEF_SEAT_TUBE_ANGLE;
  G.HeadTubeAngle := AFrame.HeadTubeAngle; if (G.HeadTubeAngle < 55) or (G.HeadTubeAngle > 80) then G.HeadTubeAngle := DEF_HEAD_TUBE_ANGLE;
  G.ChainstayLength := AFrame.ChainstayLength; if G.ChainstayLength < 200 then G.ChainstayLength := DEF_CHAINSTAY_LENGTH;
  G.BBDrop := AFrame.BBDrop; if G.BBDrop < 0 then G.BBDrop := DEF_BB_DROP;
  G.Wheelbase := AFrame.Wheelbase; if G.Wheelbase < 500 then G.Wheelbase := DEF_WHEELBASE;
  G.BBShellWidth := AFrame.BBShellWidth; if G.BBShellWidth < 50 then G.BBShellWidth := DEF_BB_SHELL_WIDTH;
  G.RearDropoutSpacing := AFrame.RearDropoutSpacing; if G.RearDropoutSpacing < 100 then G.RearDropoutSpacing := DEF_REAR_DROPOUT_SPACING;
  G.TopTubeSeatRatio := AFrame.TopTubeSeatRatio; if G.TopTubeSeatRatio < 0.5 then G.TopTubeSeatRatio := DEF_TOP_TUBE_SEAT_RATIO;
  G.TopTubeHTRatio := AFrame.TopTubeHTRatio; if G.TopTubeHTRatio < 0 then G.TopTubeHTRatio := DEF_TOP_TUBE_HT_RATIO;
  G.DownTubeHTRatio := AFrame.DownTubeHTRatio; if G.DownTubeHTRatio < 0 then G.DownTubeHTRatio := DEF_DOWN_TUBE_HT_RATIO;
  G.SeatStayJctHeight := AFrame.SeatStayJctHeight;
  G.SeatStayJctRatio := AFrame.SeatStayJctRatio;

  G.HeadTubeLength := AFrame.HeadTubeLength;
  if G.HeadTubeLength < 20 then begin
    if AFrame.Stack > 0 then begin
      BB_Y := AWheelRadius - G.BBDrop;
      SinHA := Sin(DegToRad(G.HeadTubeAngle));
      if SinHA > 0.01 then
        G.HeadTubeLength := Max(20, (AFrame.Stack - BB_Y) / SinHA)
      else
        G.HeadTubeLength := 120;
    end else
      G.HeadTubeLength := DEF_HEAD_TUBE_LENGTH;
  end;

  { ── Geometry ── }
  FL := AForkAxleToCrown * M; FR := AForkRake * M;
  G.BBHalfZ := G.BBShellWidth / 2 * M;
  G.RearHalfZ := G.RearDropoutSpacing / 2 * M;
  G.AxleY := AWheelRadius * M;
  G.RearAxleX := REAR_AXLE_X;
  G.BBX := G.RearAxleX + G.ChainstayLength * M;
  G.BBY := G.AxleY - G.BBDrop * M;
  G.FrontAxleX := G.RearAxleX + G.Wheelbase * M;

  G.SA := DegToRad(G.SeatTubeAngle);
  G.STLen := G.SeatTubeLength * M;

  G.HA := DegToRad(G.HeadTubeAngle);
  G.HTLen := G.HeadTubeLength * M;
  G.HTDirX := -Cos(G.HA); G.HTDirY := Sin(G.HA);
  G.HTPerpX := Sin(G.HA); G.HTPerpY := Cos(G.HA);
  G.HTB := Vector3(G.FrontAxleX + FL * G.HTDirX - FR * G.HTPerpX,
                   G.AxleY + FL * G.HTDirY - FR * G.HTPerpY, 0);
  G.HTT := Vector3(G.HTB.X + G.HTDirX * G.HTLen, G.HTB.Y + G.HTDirY * G.HTLen, 0);

  { Seat stay junction }
  if G.SeatStayJctHeight > 0 then
    SSJctLen := G.SeatStayJctHeight * M
  else
    SSJctLen := G.STLen * G.TopTubeSeatRatio - 50 * M;
  if SSJctLen < 50 * M then SSJctLen := 50 * M;
  G.SSJctX := G.BBX - Cos(G.SA) * SSJctLen;
  G.SSJctY := G.BBY + Sin(G.SA) * SSJctLen;
  G.SSJctZ := G.BBHalfZ * 0.7;
  G.SSBridgeX := G.SSJctX + Cos(G.SA) * 0.015;
  G.SSBridgeY := G.SSJctY - Sin(G.SA) * 0.015;
end;

{ ═══════════════════════════════════════════════════════════════════
  Compute tube endpoints from the shared frame geometry
  ═══════════════════════════════════════════════════════════════════ }

procedure ComputeFrameTubes(AFrame: TFrameComponent; M, CenterX: Single;
  AWheelRadius, AForkAxleToCrown, AForkRake: Single;
  out T: TFrameTubeArray);
var
  G: TFrameGeom;

  function O(const V: TVector3): TVector3; inline;
  begin Result := Vector3(V.X - CenterX, V.Y, V.Z); end;

begin
  { fork clamps live ONLY here: ComputeBones historically feeds the peer
    fork's raw (unclamped) values into the same geometry, so the shared
    ComputeFrameGeom takes fork params as final and this side keeps its
    own road fallback }
  if AForkAxleToCrown < 100 then AForkAxleToCrown := DEF_FORK_AXLE_TO_CROWN;
  if AForkRake < 10 then AForkRake := DEF_FORK_RAKE;
  ComputeFrameGeom(AFrame, M, AWheelRadius, AForkAxleToCrown, AForkRake, G);

  { ── Fill tube array ── }
  { Down tube: BB → DT/HT junction }
  T[FT_DOWN_TUBE].S := O(Vector3(G.BBX, G.BBY, 0));
  T[FT_DOWN_TUBE].E := O(Vector3(
    G.HTB.X + G.HTDirX * G.HTLen * G.DownTubeHTRatio,
    G.HTB.Y + G.HTDirY * G.HTLen * G.DownTubeHTRatio, 0));
  T[FT_DOWN_TUBE].R := AFrame.DownTubeDia / 2 * M;

  { Seat tube: BB → top }
  T[FT_SEAT_TUBE].S := O(Vector3(G.BBX, G.BBY, 0));
  T[FT_SEAT_TUBE].E := O(Vector3(G.BBX - Cos(G.SA) * G.STLen, G.BBY + Sin(G.SA) * G.STLen, 0));
  T[FT_SEAT_TUBE].R := AFrame.SeatTubeDia / 2 * M;

  { Top tube: seat jct → HT jct }
  T[FT_TOP_TUBE].S := O(Vector3(
    G.BBX - Cos(G.SA) * G.STLen * G.TopTubeSeatRatio,
    G.BBY + Sin(G.SA) * G.STLen * G.TopTubeSeatRatio, 0));
  T[FT_TOP_TUBE].E := O(Vector3(
    G.HTB.X + G.HTDirX * G.HTLen * (1.0 - G.TopTubeHTRatio),
    G.HTB.Y + G.HTDirY * G.HTLen * (1.0 - G.TopTubeHTRatio), 0));
  T[FT_TOP_TUBE].R := AFrame.TopTubeDia / 2 * M;

  { Head tube }
  T[FT_HEAD_TUBE].S := O(G.HTB);
  T[FT_HEAD_TUBE].E := O(G.HTT);
  T[FT_HEAD_TUBE].R := AFrame.HeadTubeDia / 2 * M;

  { BB shell }
  T[FT_BB_SHELL].S := O(Vector3(G.BBX, G.BBY, G.BBHalfZ));
  T[FT_BB_SHELL].E := O(Vector3(G.BBX, G.BBY, -G.BBHalfZ));
  T[FT_BB_SHELL].R := AFrame.SeatTubeDia / 2 * M * 1.1;

  { Chain stays }
  T[FT_CHAINSTAY_L].S := O(Vector3(G.BBX, G.BBY, G.BBHalfZ));
  T[FT_CHAINSTAY_L].E := O(Vector3(G.RearAxleX, G.AxleY, G.RearHalfZ));
  T[FT_CHAINSTAY_L].R := AFrame.ChainstayDia / 2 * M;
  T[FT_CHAINSTAY_R].S := O(Vector3(G.BBX, G.BBY, -G.BBHalfZ));
  T[FT_CHAINSTAY_R].E := O(Vector3(G.RearAxleX, G.AxleY, -G.RearHalfZ));
  T[FT_CHAINSTAY_R].R := AFrame.ChainstayDia / 2 * M;

  { Seat stays }
  T[FT_SEATSTAY_L].S := O(Vector3(G.RearAxleX, G.AxleY, G.RearHalfZ));
  T[FT_SEATSTAY_L].E := O(Vector3(G.SSJctX, G.SSJctY, G.SSJctZ));
  T[FT_SEATSTAY_L].R := AFrame.SeatstayDia / 2 * M;
  T[FT_SEATSTAY_R].S := O(Vector3(G.RearAxleX, G.AxleY, -G.RearHalfZ));
  T[FT_SEATSTAY_R].E := O(Vector3(G.SSJctX, G.SSJctY, -G.SSJctZ));
  T[FT_SEATSTAY_R].R := AFrame.SeatstayDia / 2 * M;

  { SS bridge }
  T[FT_SS_BRIDGE].S := O(Vector3(G.SSBridgeX, G.SSBridgeY, G.SSJctZ));
  T[FT_SS_BRIDGE].E := O(Vector3(G.SSBridgeX, G.SSBridgeY, -G.SSJctZ));
  T[FT_SS_BRIDGE].R := AFrame.SeatstayDia / 2 * M * 0.7;

  { Rear axle bridge }
  T[FT_AXLE_BRIDGE].S := O(Vector3(G.RearAxleX, G.AxleY, G.RearHalfZ));
  T[FT_AXLE_BRIDGE].E := O(Vector3(G.RearAxleX, G.AxleY, -G.RearHalfZ));
  T[FT_AXLE_BRIDGE].R := 0.005;
end;

{ ═══════════════════════════════════════════════════════════════════
  ComputeBones — unchanged, still needed for other components
  ═══════════════════════════════════════════════════════════════════ }

procedure TFrameComponent.ComputeBones(Skel: TBikeSkeleton);
var M: Single;
    G: TFrameGeom;
    Wh: TWheelComponent; WheelRadiusMm: Single;
    Fk: TForkComponent; LocalForkAxleToCrown, LocalForkRake: Single;
begin
  M := Skel.MM;

  { ── Resolve wheel radius from peer Wheel component (fallback to default) ── }
  Wh := TWheelComponent(FindComponent(TWheelComponent));
  if Wh <> nil then WheelRadiusMm := Wh.WheelRadius
  else WheelRadiusMm := DEF_WHEEL_RADIUS;

  { ── Resolve fork geometry from peer Fork component (fallback to road).
    NB: peer values feed the geometry RAW (no <100/<10 clamp) — that is the
    historical behaviour; ComputeFrameTubes clamps its own fork inputs. ── }
  Fk := TForkComponent(FindComponent(TForkComponent));
  if Fk <> nil then begin
    LocalForkAxleToCrown := Fk.ForkAxleToCrown;
    LocalForkRake        := Fk.ForkRake;
  end else begin
    LocalForkAxleToCrown := DEF_FORK_AXLE_TO_CROWN;
    LocalForkRake        := DEF_FORK_RAKE;
  end;

  { ── Shared validated geometry (same math the GPU tubes use) ── }
  ComputeFrameGeom(Self, M, WheelRadiusMm, LocalForkAxleToCrown, LocalForkRake, G);

  { mirror the validated values back (plain field writes — what the old
    in-place fallbacks did; valid values round-trip unchanged) }
  Self.SeatTubeLength    := G.SeatTubeLength;
  Self.SeatTubeAngle     := G.SeatTubeAngle;
  Self.HeadTubeAngle     := G.HeadTubeAngle;
  Self.HeadTubeLength    := G.HeadTubeLength;
  Self.ChainstayLength   := G.ChainstayLength;
  Self.BBDrop            := G.BBDrop;
  Self.Wheelbase         := G.Wheelbase;
  Self.BBShellWidth      := G.BBShellWidth;
  Self.RearDropoutSpacing := G.RearDropoutSpacing;
  Self.TopTubeSeatRatio  := G.TopTubeSeatRatio;
  Self.TopTubeHTRatio    := G.TopTubeHTRatio;
  Self.DownTubeHTRatio   := G.DownTubeHTRatio;
  { not part of the shared geometry — validated here only }
  if Self.FrontDropoutSpacing < 80 then Self.FrontDropoutSpacing := DEF_FRONT_DROPOUT_SPACING;
  if Self.DownTubeDia  < 10 then Self.DownTubeDia  := DEF_DOWN_TUBE_DIA;
  if Self.SeatTubeDia  < 10 then Self.SeatTubeDia  := DEF_SEAT_TUBE_DIA;
  if Self.TopTubeDia   < 10 then Self.TopTubeDia   := DEF_TOP_TUBE_DIA;
  if Self.HeadTubeDia  < 10 then Self.HeadTubeDia  := DEF_HEAD_TUBE_DIA;
  if Self.ChainstayDia < 5  then Self.ChainstayDia := DEF_CHAINSTAY_DIA;
  if Self.SeatstayDia  < 5  then Self.SeatstayDia  := DEF_SEATSTAY_DIA;

  Skel.AddBone('bb', Vector3(G.BBX, G.BBY, 0));
  Skel.AddBone('rear_axle', Vector3(G.RearAxleX, G.AxleY, 0));
  Skel.AddBone('front_axle', Vector3(G.FrontAxleX, G.AxleY, 0));
  Skel.AddBone('bb_shell_l', Vector3(G.BBX, G.BBY, G.BBHalfZ));
  Skel.AddBone('bb_shell_r', Vector3(G.BBX, G.BBY, -G.BBHalfZ));

  Skel.SeatAngleRad := G.SA;
  Skel.AddBone('seat_tube_top', Vector3(G.BBX-Cos(G.SA)*G.STLen, G.BBY+Sin(G.SA)*G.STLen, 0));
  Skel.AddBone('top_tube_seat_jct', Vector3(
    G.BBX-Cos(G.SA)*G.STLen*G.TopTubeSeatRatio,
    G.BBY+Sin(G.SA)*G.STLen*G.TopTubeSeatRatio, 0));

  Skel.AddBone('seat_stay_jct_l', Vector3(G.SSJctX, G.SSJctY, G.SSJctZ));
  Skel.AddBone('seat_stay_jct_r', Vector3(G.SSJctX, G.SSJctY, -G.SSJctZ));
  Skel.AddBone('ss_bridge_l', Vector3(G.SSBridgeX, G.SSBridgeY, G.SSJctZ));
  Skel.AddBone('ss_bridge_r', Vector3(G.SSBridgeX, G.SSBridgeY, -G.SSJctZ));

  Skel.HeadAngleRad := G.HA;
  Skel.HTDirX := G.HTDirX; Skel.HTDirY := G.HTDirY;
  Skel.AddBone('head_tube_bottom', G.HTB);
  Skel.AddBone('head_tube_top', G.HTT);
  Skel.AddBone('top_tube_ht_jct', Vector3(
    G.HTB.X+G.HTDirX*G.HTLen*(1.0-G.TopTubeHTRatio),
    G.HTB.Y+G.HTDirY*G.HTLen*(1.0-G.TopTubeHTRatio), 0));
  Skel.AddBone('down_tube_ht_jct', Vector3(
    G.HTB.X+G.HTDirX*G.HTLen*G.DownTubeHTRatio,
    G.HTB.Y+G.HTDirY*G.HTLen*G.DownTubeHTRatio, 0));

  Skel.AddBone('cs_bb_l', Vector3(G.BBX, G.BBY, G.BBHalfZ));
  Skel.AddBone('cs_bb_r', Vector3(G.BBX, G.BBY, -G.BBHalfZ));
  Skel.AddBone('cs_rear_l', Vector3(G.RearAxleX, G.AxleY, G.RearHalfZ));
  Skel.AddBone('cs_rear_r', Vector3(G.RearAxleX, G.AxleY, -G.RearHalfZ));
  Skel.AddBone('rear_dropout_l', Vector3(G.RearAxleX, G.AxleY, G.RearHalfZ));
  Skel.AddBone('rear_dropout_r', Vector3(G.RearAxleX, G.AxleY, -G.RearHalfZ));
end;

{ ═══════════════════════════════════════════════════════════════════
  BuildGeometry — CPU mesh of all tubes. GPU tube shader stubbed
  (Effect never on Appearance → aTube* spam every frame).
  ═══════════════════════════════════════════════════════════════════ }

procedure TFrameComponent.BuildGeometry(Ctx: TBikeBuildContext);
var
  M: Single;
  Tubes: TFrameTubeArray;
  Coord: TCoordinateNode;
  IFS: TIndexedFaceSetNode;
  Shape: TShapeNode;
  FrameXf: TTransformNode;
  J, NJ, Slices, VBase, BotCenter, TopCenter, TubeI, RingI, RingCount, RingBase: Integer;
  Theta, CT, ST, TubeLen, T, RadiusSide, RadiusDepth, Bend: Single;
  Dir, Perp1, Perp2, Up, Pos: TVector3;
  Wh: TWheelComponent; LocalWR: Single;
  Fk: TForkComponent; LocalFAC, LocalFR: Single;
  Mountain: Boolean;
begin
  M := Ctx.Skeleton.MM;
  Mountain:=(Builder<>nil)and(TBikeBuilder(Builder).BarType=btFlat);

  Wh := TWheelComponent(FindComponent(TWheelComponent));
  if Wh <> nil then LocalWR := Wh.WheelRadius else LocalWR := DEF_WHEEL_RADIUS;

  Fk := TForkComponent(FindComponent(TForkComponent));
  if Fk <> nil then begin
    LocalFAC := Fk.ForkAxleToCrown;
    LocalFR  := Fk.ForkRake;
  end else begin
    LocalFAC := DEF_FORK_AXLE_TO_CROWN;
    LocalFR  := DEF_FORK_RAKE;
  end;

  { ── Compute initial tube geometry ── }
  ComputeFrameTubes(Self, M, Ctx.CenterX, LocalWR, LocalFAC, LocalFR, Tubes);

  { ── Determine slices from LOD ── }
  case Ctx.DetailLevel of
    0: Slices := 6;
    1: Slices := 10;
    2: Slices := 16;
  else Slices := 24;
  end;

  { ── Build combined mesh ── }
  Coord := TCoordinateNode.Create;
  IFS := TIndexedFaceSetNode.Create;
  IFS.Coord := Coord;
  IFS.Solid := False;
  IFS.CreaseAngle := 1.5;

  for TubeI := 0 to FRAME_TUBE_COUNT - 1 do begin
    VBase := Coord.FdPoint.Count;
    Dir := Tubes[TubeI].E - Tubes[TubeI].S;
    TubeLen := Dir.Length;
    if TubeLen < 0.0001 then begin
      Dir := Vector3(0, 1, 0);
      TubeLen := 0.0001;
    end else
      Dir := Dir / TubeLen;

    Up := Vector3(0, 1, 0);
    if Abs(TVector3.DotProduct(Dir, Up)) > 0.9 then Up := Vector3(1, 0, 0);
    Perp1 := TVector3.CrossProduct(Dir, Up).Normalize;
    Perp2 := TVector3.CrossProduct(Dir, Perp1);

    { Hydroformed MTB tubes keep the fit anchors, with a wider down tube,
      a flatter top tube and a tapered head tube. Other bicycles retain
      their circular sections and original two-ring topology. }
    RingCount:=2;
    if Mountain and (TubeI in [FT_DOWN_TUBE,FT_TOP_TUBE]) then RingCount:=5;
    for RingI:=0 to RingCount-1 do begin
      T:=RingI/(RingCount-1);
      RadiusSide:=Tubes[TubeI].R;RadiusDepth:=RadiusSide;Bend:=0;
      if Mountain then case TubeI of
        FT_DOWN_TUBE: begin
          RadiusSide:=RadiusSide*(1.12+0.20*Sin(Pi*T));
          RadiusDepth:=RadiusDepth*(1.44+0.18*Sin(Pi*T));
          Bend:=0.003*Sin(Pi*T);
        end;
        FT_TOP_TUBE: begin
          RadiusSide:=RadiusSide*(1.10+0.10*T);
          RadiusDepth:=RadiusDepth*(0.88+0.12*T);
          Bend:=-0.002*Sin(Pi*T);
        end;
        FT_HEAD_TUBE: begin
          RadiusSide:=RadiusSide*(1.16-0.20*T);RadiusDepth:=RadiusSide;
        end;
      end;
      for J:=0 to Slices-1 do begin
        Theta:=2*Pi*J/Slices;CT:=Cos(Theta);ST:=Sin(Theta);
        Pos:=Tubes[TubeI].S+(Tubes[TubeI].E-Tubes[TubeI].S)*T+
          Perp1*(CT*RadiusSide)+Perp2*(ST*RadiusDepth+Bend);
        Coord.FdPoint.Items.Add(Pos);
      end;
    end;
    { Cap centers }
    BotCenter := Coord.FdPoint.Count;
    Coord.FdPoint.Items.Add(Tubes[TubeI].S);

    TopCenter := Coord.FdPoint.Count;
    Coord.FdPoint.Items.Add(Tubes[TubeI].E);

    { Body quads }
    for RingI:=0 to RingCount-2 do
    for J := 0 to Slices - 1 do begin
      RingBase:=VBase+RingI*Slices;
      NJ := (J + 1) mod Slices;
      IFS.FdCoordIndex.Items.Add(RingBase + J);
      IFS.FdCoordIndex.Items.Add(RingBase + NJ);
      IFS.FdCoordIndex.Items.Add(RingBase + Slices + NJ);
      IFS.FdCoordIndex.Items.Add(RingBase + Slices + J);
      IFS.FdCoordIndex.Items.Add(-1);
    end;
    { Bottom cap }
    for J := Slices - 1 downto 0 do begin
      NJ := (J + Slices - 1) mod Slices;
      IFS.FdCoordIndex.Items.Add(BotCenter);
      IFS.FdCoordIndex.Items.Add(VBase + J);
      IFS.FdCoordIndex.Items.Add(VBase + NJ);
      IFS.FdCoordIndex.Items.Add(-1);
    end;
    { Top cap }
    for J := 0 to Slices - 1 do begin
      NJ := (J + 1) mod Slices;
      IFS.FdCoordIndex.Items.Add(TopCenter);
      IFS.FdCoordIndex.Items.Add(VBase + (RingCount-1)*Slices + J);
      IFS.FdCoordIndex.Items.Add(VBase + (RingCount-1)*Slices + NJ);
      IFS.FdCoordIndex.Items.Add(-1);
    end;
  end;

  { GPU tube shader stubbed. aTubeIdx/T/Phi used to sit on this IFS, and a
    TEffectNode with PLUG_vertex_object_space was built — but never attached
    to Appearance. CGE then warned every draw:
      Shader attribute "aTubeIdx"/"aTubeT"/"aTubePhi" not found (or not used)
    CPU verts already match ComputeFrameTubes; FrameAnimateFrame had nothing
    to drive. GLSL dump remains at frame_shader.glsl. To restore: put attribs
    back on IFS, Attach Effect to Shape.Appearance (SetEffects). }
  if not FF_Captured then begin
    FF_CenterX := Ctx.CenterX;
    FF_WheelRadius := LocalWR;
    FF_FAC := LocalFAC;
    FF_FRake := LocalFR;
    FF_MM := M;
    FF_Captured := True;
  end;

  { ── Assemble scene graph ── }
  Shape := TShapeNode.Create;
  Shape.Geometry := IFS;
  Shape.Appearance := Ctx.MakeMaterial(Ctx.Colors.Frame, Ctx.Colors.FrameSpec, 0.85);
  FrameXf := TTransformNode.Create;
  FrameXf.X3DName := 'FrameMeshXf';
  FrameXf.AddChildren(Shape);
  Ctx.Add(FrameXf);
end;

{ ═══════════════════════════════════════════════════════════════════
  FrameAnimateFrame — live geometry update via uniforms
  ═══════════════════════════════════════════════════════════════════ }

procedure FrameAnimateFrame(AFrame: TFrameComponent; MM: Single;
  AWheelRadius, AForkAxleToCrown, AForkRake: Single);
var
  Tubes: TFrameTubeArray;
  I: Integer;
begin
  if (not FF_Ready) or (AFrame = nil) then Exit;

  { OPT dirty-check: между билдами входы ComputeFrameTubes неизменны (FF_*
    захвачены на билде, изменение параметров кадра идёт через rebuild →
    ResetFrameAnimCache), поэтому пересчёт ~140 строк тригонометрии + 33 Send
    нужны один раз после Reset, а не каждый кадр. }
  if FF_TubesSent then Exit;

  { Re-derive the frame tubes from the EXACT inputs the build used (captured at build),
    NOT the values passed in. The fork, seatpost and saddle are static geometry built
    from the skeleton with those same build inputs; re-sourcing wheel radius / fork
    axle-to-crown / rake / scale live (raw from components, MM hardcoded) could differ
    from the build and would slide the seat tube + head tube off the static fork/
    seatpost. Using the captured build inputs keeps the animated tubes locked to them.
    (A real frame-param change triggers a rebuild, which re-captures these.) }
  ComputeFrameTubes(AFrame, FF_MM, FF_CenterX, FF_WheelRadius, FF_FAC, FF_FRake, Tubes);

  for I := 0 to FRAME_TUBE_COUNT - 1 do begin
    if FF_UStart[I] <> nil then FF_UStart[I].Send(Tubes[I].S);
    if FF_UEnd[I] <> nil then FF_UEnd[I].Send(Tubes[I].E);
    if FF_URad[I] <> nil then FF_URad[I].Send(Tubes[I].R);
  end;
  FF_TubesSent := True;

  { One-shot dump to the startup_anim log (CGE log is off): the ACTUAL endpoints the
    frame shader receives for the disputed tubes, in O-centred scene metres. Compare
    SEAT_TUBE.E with the skeleton's seat_tube_top and HEAD_TUBE.S with head_tube_bottom
    (logged from the bike side) — if they differ, the frame tubes and the fork/seatpost
    are using different numbers; if they match, the frame is on the skeleton. }
  if FF_LogOnce then begin
    FF_LogOnce := False;
    StartupLog(Format('[FrameAnim] CenterX=%.4f MM=%.5f WR=%.1f FAC=%.1f FRake=%.2f',
      [FF_CenterX, FF_MM, FF_WheelRadius, FF_FAC, FF_FRake]));
    StartupLog(Format('[FrameAnim] DOWN  S=(%.4f,%.4f,%.4f) E=(%.4f,%.4f,%.4f) R=%.4f',
      [Tubes[FT_DOWN_TUBE].S.X, Tubes[FT_DOWN_TUBE].S.Y, Tubes[FT_DOWN_TUBE].S.Z,
       Tubes[FT_DOWN_TUBE].E.X, Tubes[FT_DOWN_TUBE].E.Y, Tubes[FT_DOWN_TUBE].E.Z,
       Tubes[FT_DOWN_TUBE].R]));
    StartupLog(Format('[FrameAnim] SEAT  S=(%.4f,%.4f,%.4f) E=(%.4f,%.4f,%.4f) R=%.4f',
      [Tubes[FT_SEAT_TUBE].S.X, Tubes[FT_SEAT_TUBE].S.Y, Tubes[FT_SEAT_TUBE].S.Z,
       Tubes[FT_SEAT_TUBE].E.X, Tubes[FT_SEAT_TUBE].E.Y, Tubes[FT_SEAT_TUBE].E.Z,
       Tubes[FT_SEAT_TUBE].R]));
    StartupLog(Format('[FrameAnim] TOP   S=(%.4f,%.4f,%.4f) E=(%.4f,%.4f,%.4f) R=%.4f',
      [Tubes[FT_TOP_TUBE].S.X, Tubes[FT_TOP_TUBE].S.Y, Tubes[FT_TOP_TUBE].S.Z,
       Tubes[FT_TOP_TUBE].E.X, Tubes[FT_TOP_TUBE].E.Y, Tubes[FT_TOP_TUBE].E.Z,
       Tubes[FT_TOP_TUBE].R]));
    StartupLog(Format('[FrameAnim] HEAD  S=(%.4f,%.4f,%.4f) E=(%.4f,%.4f,%.4f) R=%.4f',
      [Tubes[FT_HEAD_TUBE].S.X, Tubes[FT_HEAD_TUBE].S.Y, Tubes[FT_HEAD_TUBE].S.Z,
       Tubes[FT_HEAD_TUBE].E.X, Tubes[FT_HEAD_TUBE].E.Y, Tubes[FT_HEAD_TUBE].E.Z,
       Tubes[FT_HEAD_TUBE].R]));
  end;
end;

end.
