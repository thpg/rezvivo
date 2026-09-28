unit BikeParametric_Fork;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, CastleUtils, CastleVectors, X3DNodes,
  BikeParametric;

type
  TForkComponent = class(TBikeComponent)
  private
    FForkAxleToCrown: Single;
    FForkRake:        Single;
    FForkBladeDia:    Single;
    FForkTipDia:      Single;
    FForkTravel:      Single;
    FHeadsetSpacer:   Single;
    FStemLength:      Single;
    FStemAngle:       Single;
    FStemDia:         Single;
  public
    constructor Create; override;
    class function ComponentName: string; override;
    procedure ApplyPreset(const APreset: string); override;
    procedure ComputeBones(Skel: TBikeSkeleton); override;
    procedure BuildGeometry(Ctx: TBikeBuildContext); override;
  published
    { Fork / steerer }
    property ForkAxleToCrown: Single read FForkAxleToCrown write FForkAxleToCrown;
    property ForkRake:        Single read FForkRake        write FForkRake;
    property ForkBladeDia:    Single read FForkBladeDia    write FForkBladeDia;
    property ForkTipDia:      Single read FForkTipDia      write FForkTipDia;
    property ForkTravel:      Single read FForkTravel      write FForkTravel;
    { Stem / headset }
    property HeadsetSpacer:   Single read FHeadsetSpacer   write FHeadsetSpacer;
    property StemLength:      Single read FStemLength      write FStemLength;
    property StemAngle:       Single read FStemAngle       write FStemAngle;
    property StemDia:         Single read FStemDia         write FStemDia;
  end;

const
  { Road defaults. Single source: Create seeds these, ComputeBones falls
    back to them on invalid input, and the frame's peer-component fallbacks
    read them cross-unit. }
  DEF_FORK_AXLE_TO_CROWN = 370;   { mm }
  DEF_FORK_RAKE          = 45;    { mm }
  DEF_FORK_BLADE_DIA     = 20;    { mm }
  DEF_FORK_TIP_DIA       = 14;    { mm }
  DEF_HEADSET_SPACER     = 20;    { mm }
  DEF_STEM_LENGTH        = 100;   { mm }
  DEF_STEM_DIA           = 24;    { mm }

implementation

uses BikeParametric_Frame;

constructor TForkComponent.Create;
begin
  inherited Create;
  FForkAxleToCrown := DEF_FORK_AXLE_TO_CROWN;
  FForkRake        := DEF_FORK_RAKE;
  FForkBladeDia    := DEF_FORK_BLADE_DIA;
  FForkTipDia      := DEF_FORK_TIP_DIA;
  FForkTravel      := 0;
  FHeadsetSpacer   := DEF_HEADSET_SPACER;
  FStemLength      := DEF_STEM_LENGTH;
  FStemAngle       := 7;
  FStemDia         := DEF_STEM_DIA;
end;

class function TForkComponent.ComponentName: string; begin Result := 'Fork'; end;

procedure TForkComponent.ApplyPreset(const APreset: string);
begin
  if SameText(APreset, 'gravel') then begin
    FForkRake   := 50;
    FStemLength := 90;
    FStemAngle  := 6;
  end else if SameText(APreset, 'mtb') then begin
    FForkAxleToCrown := 530;
    FForkRake        := 44;
    FForkTravel      := 120;
    FHeadsetSpacer   := 15;
    FStemLength      := 50;
    FStemAngle       := 0;
    FForkBladeDia    := 36;
    FForkTipDia      := 20;
    FStemDia         := 28;
  end;
end;

procedure TForkComponent.ComputeBones(Skel: TBikeSkeleton);
var
  M, FrontHalfZ: Single;
  HTB, HTT, StemBase, StemEnd: TVector3;
  Fr: TFrameComponent;
begin
  M := Skel.MM;

  { ForkAxleToCrown default must NOT depend on the bar (the frame reads this value
    for the head-tube position, and frame/fork geometry must stay independent of the
    saddle/handlebar). Use a fixed fork-length fallback; a longer suspension fork is
    selected by the Fork's own preset (ApplyPreset 'mtb') or an explicit value, never
    inferred from the bar type. }
  if ForkAxleToCrown < 100 then ForkAxleToCrown := DEF_FORK_AXLE_TO_CROWN;
  if ForkRake      < 10 then ForkRake      := DEF_FORK_RAKE;
  if ForkBladeDia  < 5  then ForkBladeDia  := DEF_FORK_BLADE_DIA;
  if ForkTipDia    < 5  then ForkTipDia    := DEF_FORK_TIP_DIA;
  if HeadsetSpacer < 0  then HeadsetSpacer := DEF_HEADSET_SPACER;
  if StemLength    < 10 then StemLength    := DEF_STEM_LENGTH;
  if StemDia       < 10 then StemDia       := DEF_STEM_DIA;

  { FrontDropoutSpacing owned by TFrameComponent — peer lookup with fallback 100. }
  Fr := TFrameComponent(FindComponent(TFrameComponent));
  if Fr <> nil then FrontHalfZ := Fr.FrontDropoutSpacing/2*M
  else FrontHalfZ := 100/2*M;

  HTB := Skel['head_tube_bottom'];
  { crown dropped well below the head-tube bottom (was -0.01) so the raised arch apex
    still clears the frame's head tube instead of poking up into it. }
  Skel.AddBone('fork_crown_l', Vector3(HTB.X, HTB.Y-0.035, FrontHalfZ*0.5));
  Skel.AddBone('fork_crown_r', Vector3(HTB.X, HTB.Y-0.035, -FrontHalfZ*0.5));
  Skel.AddBone('front_dropout_l', Vector3(Skel['front_axle'].X, Skel['front_axle'].Y, FrontHalfZ));
  Skel.AddBone('front_dropout_r', Vector3(Skel['front_axle'].X, Skel['front_axle'].Y, -FrontHalfZ));

  HTT := Skel['head_tube_top'];
  StemBase := Vector3(HTT.X+Skel.HTDirX*HeadsetSpacer*M, HTT.Y+Skel.HTDirY*HeadsetSpacer*M, 0);
  Skel.AddBone('stem_base', StemBase);
  StemEnd := Vector3(StemBase.X+Cos(DegToRad(StemAngle))*StemLength*M,
    StemBase.Y+Sin(DegToRad(StemAngle))*StemLength*M, 0);
  Skel.AddBone('stem_end', StemEnd);
end;

{ Elliptical (flattened) tapered tube from PA to PB. Two semi-axes per end:
  Lat = lateral (world-Z) half-width (the thin side), Dep = sagittal half-width
  (the fore-aft "depth" you see from the side, the wide side). World-space verts. }
function MakeForkBlade(Ctx: TBikeBuildContext; const PA, PB: TVector3;
  LatA, DepA, LatB, DepB: Single; const Color, Spec: TVector3;
  Shininess: Single): TTransformNode;
var
  axis, e1, e2: TVector3;
  L, Theta, ct, st: Single;
  Slices, I, NI, BaseB, CenA, CenB: Integer;
  IFS: TIndexedFaceSetNode; Coord: TCoordinateNode; Shape: TShapeNode;
begin
  axis := PB - PA; L := axis.Length;
  if L < 1e-6 then begin Result := TTransformNode.Create; Exit; end;
  axis := axis.Normalize;
  e1 := Vector3(0, 0, 1) - axis * axis.Z;                 { lateral (Z) perp to axis }
  if e1.Length < 1e-4 then e1 := Vector3(1, 0, 0) - axis * axis.X;
  e1 := e1.Normalize;
  e2 := TVector3.CrossProduct(axis, e1).Normalize;        { sagittal depth axis }

  Slices := Ctx.LOD_TorusSeg;
  if Slices < 8 then Slices := 8;
  Coord := TCoordinateNode.Create;
  for I := 0 to Slices - 1 do                             { ring A (PA) }
  begin
    Theta := 2 * Pi * I / Slices; ct := Cos(Theta); st := Sin(Theta);
    Coord.FdPoint.Items.Add(PA + e1 * (LatA * ct) + e2 * (DepA * st));
  end;
  for I := 0 to Slices - 1 do                             { ring B (PB) }
  begin
    Theta := 2 * Pi * I / Slices; ct := Cos(Theta); st := Sin(Theta);
    Coord.FdPoint.Items.Add(PB + e1 * (LatB * ct) + e2 * (DepB * st));
  end;
  BaseB := Slices;
  CenA := 2 * Slices; CenB := 2 * Slices + 1;
  Coord.FdPoint.Items.Add(PA);
  Coord.FdPoint.Items.Add(PB);

  IFS := TIndexedFaceSetNode.Create;
  IFS.Coord := Coord; IFS.Solid := false; IFS.CreaseAngle := 1.5;
  for I := 0 to Slices - 1 do
  begin
    NI := (I + 1) mod Slices;
    IFS.FdCoordIndex.Items.Add(I); IFS.FdCoordIndex.Items.Add(NI);
    IFS.FdCoordIndex.Items.Add(BaseB + NI); IFS.FdCoordIndex.Items.Add(BaseB + I);
    IFS.FdCoordIndex.Items.Add(-1);
  end;
  for I := Slices - 1 downto 0 do                          { cap A }
  begin
    NI := (I + Slices - 1) mod Slices;
    IFS.FdCoordIndex.Items.Add(CenA); IFS.FdCoordIndex.Items.Add(I);
    IFS.FdCoordIndex.Items.Add(NI); IFS.FdCoordIndex.Items.Add(-1);
  end;
  for I := 0 to Slices - 1 do                              { cap B }
  begin
    NI := (I + 1) mod Slices;
    IFS.FdCoordIndex.Items.Add(CenB); IFS.FdCoordIndex.Items.Add(BaseB + I);
    IFS.FdCoordIndex.Items.Add(BaseB + NI); IFS.FdCoordIndex.Items.Add(-1);
  end;

  if Ctx.AccumActive then
  begin
    { батч: перо вилки в аккумулятор (координаты object-space, crease 1.5) }
    Ctx.EmitBatched(IFS, Coord, Color, Spec, Shininess, 1.5,
      TMatrix4.Identity);
    Exit(nil);
  end;

  Shape := TShapeNode.Create;
  Shape.Geometry := IFS;
  Shape.Appearance := Ctx.MakeMaterial(Color, Spec, Shininess);
  Result := TTransformNode.Create;
  Result.AddChildren(Shape);
end;

{ Half-torus crown arch from A to B (a "half donut") with an ELLIPTICAL (flattened)
  tube: RBn = half-width along the out-of-plane axis (fore-aft, the wide side),
  RRad = half-width in the arch plane (the thin side). The open ends sit on A and B
  so the matching elliptical blades flow into it. Bulges toward BulgeTarget. }
function MakeForkArch(Ctx: TBikeBuildContext; const A, B, BulgeTarget: TVector3;
  RRad, RBn: Single; const Color, Spec: TVector3; Shininess: Single): TTransformNode;
var
  Cm, u, n, bn, bulge, radial, cl, vtx: TVector3;
  L, R, Alpha, Beta, ca, sa, cb, sb: Single;
  ArcSeg, TubeSeg, I, J, NI, NJ, AK, BK, CK, DK: Integer;
  IFS: TIndexedFaceSetNode; Coord: TCoordinateNode; Shape: TShapeNode;
begin
  Cm := (A + B) * 0.5;
  u  := B - A; L := u.Length;
  if (L < 1e-6) or (RRad <= 0) or (RBn <= 0) then begin Result := TTransformNode.Create; Exit; end;
  u := u.Normalize; R := L * 0.5;

  bulge := BulgeTarget - Cm;
  bulge := bulge - u * TVector3.DotProduct(bulge, u);     { drop the part along the chord }
  if bulge.Length < 1e-6 then
  begin
    bulge := Vector3(0, 1, 0);                            { fallback: world up }
    bulge := bulge - u * TVector3.DotProduct(bulge, u);
    if bulge.Length < 1e-6 then bulge := TVector3.CrossProduct(u, Vector3(1, 0, 0));
  end;
  n  := bulge.Normalize;
  bn := TVector3.CrossProduct(u, n).Normalize;            { out of the arch plane (fore-aft) }

  ArcSeg  := Max(8, Ctx.LOD_TorusSeg div 2);
  TubeSeg := Max(6, Ctx.LOD_TorusTubeSeg);
  Coord := TCoordinateNode.Create;
  for I := 0 to ArcSeg do
  begin
    Alpha := Pi * I / ArcSeg;
    ca := Cos(Alpha); sa := Sin(Alpha);
    radial := u * ca + n * sa;
    cl := Cm + radial * R;
    for J := 0 to TubeSeg - 1 do
    begin
      Beta := 2 * Pi * J / TubeSeg; cb := Cos(Beta); sb := Sin(Beta);
      vtx := cl + radial * (RRad * cb) + bn * (RBn * sb);
      Coord.FdPoint.Items.Add(vtx);
    end;
  end;

  IFS := TIndexedFaceSetNode.Create;
  IFS.Coord := Coord; IFS.Solid := false; IFS.CreaseAngle := 1.5;
  for I := 0 to ArcSeg - 1 do
  begin
    NI := I + 1;
    for J := 0 to TubeSeg - 1 do
    begin
      NJ := (J + 1) mod TubeSeg;
      AK := I  * TubeSeg + J;  BK := I  * TubeSeg + NJ;
      CK := NI * TubeSeg + NJ; DK := NI * TubeSeg + J;
      IFS.FdCoordIndex.Items.Add(AK); IFS.FdCoordIndex.Items.Add(BK);
      IFS.FdCoordIndex.Items.Add(CK); IFS.FdCoordIndex.Items.Add(DK);
      IFS.FdCoordIndex.Items.Add(-1);
    end;
  end;

  if Ctx.AccumActive then
  begin
    { батч: арка кроны в аккумулятор (координаты object-space, crease 1.5) }
    Ctx.EmitBatched(IFS, Coord, Color, Spec, Shininess, 1.5,
      TMatrix4.Identity);
    Exit(nil);
  end;

  Shape := TShapeNode.Create;
  Shape.Geometry := IFS;
  Shape.Appearance := Ctx.MakeMaterial(Color, Spec, Shininess);
  Result := TTransformNode.Create;
  Result.AddChildren(Shape);
end;

procedure TForkComponent.BuildGeometry(Ctx: TBikeBuildContext);
var
  S: TBikeSkeleton; M: Single; Side: string; BulgeTgt, Cr, Dr: TVector3;
  WideTop, WideBot, LatTop, LatBot: Single;
begin
  S := Ctx.Skeleton; M := S.MM;
  { Flattened (elliptical) profile, wider seen from the side (sagittal/fore-aft):
    5 cm at the crown tapering to 3 cm at the dropout. The lateral (thin) axis stays
    the round blade diameter (ForkBladeDia at crown -> ForkTipDia at dropout). }
  WideTop := 0.05 / 2;   WideBot := 0.03 / 2;          { sagittal half-widths (wide) }
  LatTop  := ForkBladeDia / 2 * M;
  LatBot  := ForkTipDia   / 2 * M;

  { steerer (head_tube_bottom -> head_tube_top) intentionally NOT drawn: it sits inside
    the frame's head tube and is only ever visible when the frame is mis-placed. }
  { crown = flattened half-torus arch joining the blade tops; wide fore-aft (RBn) and
    thin in-plane (RRad), matching the blades at the crown. Frame colour.
    батч: арка + оба пера в ОДИН меш по материалу рамы (crease 1.5).
    Parent = SteerRoot when steer enabled (turns with bars/front wheel). }
  Ctx.BeginAccum(Ctx.SteerRoot);
  if S.HasBone('head_tube_bottom') then BulgeTgt := Ctx.O(S['head_tube_bottom'])
  else BulgeTgt := Ctx.O(S['fork_crown_r']) + Vector3(0, 0.1, 0);
  Ctx.Add(MakeForkArch(Ctx, Ctx.O(S['fork_crown_r']), Ctx.O(S['fork_crown_l']),
    BulgeTgt, LatTop, WideTop, Ctx.Colors.Frame, Ctx.Colors.FrameSpec, 0.85));

  for Side in ['l','r'] do
  begin
    Cr := Ctx.O(S['fork_crown_'+Side]);
    Dr := Ctx.O(S['front_dropout_'+Side]);
    Ctx.Add(MakeForkBlade(Ctx, Cr, Dr, LatTop, WideTop, LatBot, WideBot,
      Ctx.Colors.Frame, Ctx.Colors.FrameSpec, 0.85));
  end;
  Ctx.EndAccum;
end;

end.
