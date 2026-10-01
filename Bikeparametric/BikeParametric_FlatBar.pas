unit BikeParametric_FlatBar;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, CastleUtils, CastleVectors, X3DNodes,
  BikeParametric, BikeParametric_Fork, BikeGfxUtil;

type
  TFlatBarComponent = class(TBikeComponent)
  private
    FFlatBarWidth: Single;
    FFlatBarRise:  Single;
    FFlatBarSweep: Single;
    FGripColor:    Integer;   { packed $RRGGBB; -1 = inherit Ctx.Colors.Tape }
  public
    constructor Create; override;
    class function ComponentName: string; override;
    procedure ApplyPreset(const APreset: string); override;
    procedure ComputeBones(Skel: TBikeSkeleton); override;
    procedure BuildGeometry(Ctx: TBikeBuildContext); override;
  published
    property FlatBarWidth: Single  read FFlatBarWidth write FFlatBarWidth;  { mm, grip C-C }
    property FlatBarRise:  Single  read FFlatBarRise  write FFlatBarRise;   { mm, rise from clamp to grip }
    property FlatBarSweep: Single  read FFlatBarSweep write FFlatBarSweep;  { degrees, backsweep }
    { Grip colour as packed $RRGGBB (0..255 per channel).
      -1 (default) = use the global palette tape colour (Ctx.Colors.Tape). }
    property GripColor:    Integer read FGripColor    write FGripColor;
  end;

implementation

const
  { defaults — единый источник для Create и fallback'ов ComputeBones }
  DEF_FLAT_BAR_WIDTH = 760;   { mm, grip C-C }
  DEF_FLAT_BAR_RISE  = 15;    { mm }
  DEF_FLAT_BAR_SWEEP = 8;     { degrees }
  { bare (unwrapped) bar + end-plug plastic }
  BARE_BAR_COL: TVector3 = (X: 0.02; Y: 0.02; Z: 0.022);
  BARE_BAR_SPEC: TVector3 = (X: 0.16; Y: 0.16; Z: 0.17);

{ PackRGB now lives in the shared BikeGfxUtil unit. }

constructor TFlatBarComponent.Create;
begin
  inherited Create;
  FFlatBarWidth := DEF_FLAT_BAR_WIDTH;
  FFlatBarRise  := DEF_FLAT_BAR_RISE;
  FFlatBarSweep := DEF_FLAT_BAR_SWEEP;
  FGripColor    := -1;   { inherit the global tape/grip colour by default }
end;

class function TFlatBarComponent.ComponentName: string; begin Result := 'FlatBar'; end;

procedure TFlatBarComponent.ApplyPreset(const APreset: string);
begin
  if SameText(APreset, 'mtb') then begin
    FFlatBarWidth := 780;
    FFlatBarRise  := 20;
  end;
end;

procedure TFlatBarComponent.ComputeBones(Skel: TBikeSkeleton);
var M, FBW, FBR, FBSweepRad, BarEndX, BarEndY, BZ: Single;
    StemEnd: TVector3; Signs: array[0..1] of Single;
    Names: array[0..1] of string; I: Integer;
begin
  M := Skel.MM;

  if FlatBarWidth < 400 then FlatBarWidth := DEF_FLAT_BAR_WIDTH;
  if FlatBarSweep < 0   then FlatBarSweep := DEF_FLAT_BAR_SWEEP;

  StemEnd := Skel['stem_end'];
  Signs[0] := -1; Signs[1] := 1; Names[0] := 'l'; Names[1] := 'r';
  FBW := FlatBarWidth * M / 2; FBR := FlatBarRise * M;
  FBSweepRad := DegToRad(FlatBarSweep);
  BarEndX := StemEnd.X - Sin(FBSweepRad) * FBW * 0.15; BarEndY := StemEnd.Y + FBR;
  Skel.AddBone('bar_left',  Vector3(BarEndX, BarEndY, -FBW));
  Skel.AddBone('bar_right', Vector3(BarEndX, BarEndY,  FBW));
  for I := 0 to 1 do begin
    BZ := Signs[I] * FBW;
    Skel.AddBone('grip_inner_' + Names[I], Vector3(StemEnd.X, StemEnd.Y + FBR * 0.3, Signs[I] * FBW * 0.6));
    Skel.AddBone('grip_'       + Names[I], Vector3(BarEndX, BarEndY, BZ));
    { Palm on the middle of the rubber grip, clear of the end cap. All road
      grip slots fall back to this contact when a flat bar is fitted. }
    Skel.AddBone('place_' + Names[I] + '_1',
      (Vector3(BarEndX,BarEndY,BZ)+Skel['grip_inner_'+Names[I]])*0.5+Vector3(0,0.014,0));
    Skel.AddBone('brake_lever_'     + Names[I], Vector3(BarEndX + 0.015, BarEndY - 0.005, BZ));
    Skel.AddBone('brake_lever_end_' + Names[I], Vector3(BarEndX + 0.045, BarEndY - 0.035, BZ));
  end;
end;

procedure TFlatBarComponent.BuildGeometry(Ctx: TBikeBuildContext);
var S: TBikeSkeleton; Side: string;
    BarEnd, GripInner, BrLev, BrLevEnd: TVector3; DL: Integer;
    Fk: TForkComponent; LocalStemDia: Single;
    GripCol, GripSpec: TVector3;
begin
  S := Ctx.Skeleton; DL := Ctx.DetailLevel;

  { resolve colours }
  if FGripColor < 0 then GripCol := Ctx.Colors.Tape else GripCol := PackRGB(FGripColor);
  GripSpec := Vector3(0.15, 0.15, 0.18);

  Fk := TForkComponent(FindComponent(TForkComponent));
  if Fk <> nil then LocalStemDia := Fk.StemDia else LocalStemDia := 24;

  { батч: весь плоский руль — несколько мешей по материалам вместо ~10 Shape-нод.
    Parent = SteerRoot when steer enabled. }
  Ctx.BeginAccum(Ctx.SteerRoot);

  { head-tube extension + stem (metal) }
  Ctx.Add(Ctx.MakeCylinder(Ctx.O(S['head_tube_top']), Ctx.O(S['stem_base']), 0.014, Ctx.Colors.Chrome, Ctx.Colors.ChromeSpec, 1.0));
  Ctx.Add(Ctx.MakeCylinder(Ctx.O(S['stem_base']), Ctx.O(S['stem_end']), LocalStemDia / 2 * S.MM, Ctx.Colors.Chrome, Ctx.Colors.ChromeSpec, 1.0));
  if DL >= 2 then
    Ctx.Add(Ctx.MakeSphere(Ctx.O(S['stem_end']), 0.018, Ctx.Colors.Dark, Vector3(0.3, 0.3, 0.35), 0.7));

  { the bar tube itself is bare (black) -- only the grips carry colour }
  Ctx.Add(Ctx.MakeCylinder(Ctx.O(S['bar_left']), Ctx.O(S['bar_right']), 0.012, BARE_BAR_COL, BARE_BAR_SPEC, 0.4));

  for Side in ['l', 'r'] do begin
    if Side = 'l' then BarEnd := Ctx.O(S['bar_left']) else BarEnd := Ctx.O(S['bar_right']);
    GripInner := Ctx.O(S['grip_inner_' + Side]);

    { grip sleeve (coloured) }
    Ctx.Add(Ctx.MakeCylinder(GripInner, BarEnd, 0.014, GripCol, GripSpec, 0.4));

    if DL >= 1 then begin
      BrLev    := Ctx.O(S['brake_lever_'     + Side]);
      BrLevEnd := Ctx.O(S['brake_lever_end_' + Side]);
      Ctx.Add(Ctx.MakeSphere(BrLev, 0.010, Ctx.Colors.Dark, Vector3(0.2, 0.2, 0.25), 0.6));
      Ctx.Add(Ctx.MakeCylinder(BrLev, BrLevEnd, 0.004, Ctx.Colors.Chrome, Ctx.Colors.ChromeSpec, 1.0));
    end;

    { bar-end plug (black) }
    if DL >= 2 then
      Ctx.Add(Ctx.MakeSphere(BarEnd, 0.012, BARE_BAR_COL, Vector3(0.18, 0.18, 0.2), 0.4));
  end;
  Ctx.EndAccum;
end;

end.
