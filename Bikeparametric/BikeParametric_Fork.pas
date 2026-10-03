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

uses BikeParametric_Frame, BikeParametric_Wheel;

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
  M, FrontHalfZ, CrownHalfZ, TireHalfWidth, BladeRadius: Single;
  HTB, HTT, StemBase, StemEnd, CrownCenter, SteerUp: TVector3;
  Fr: TFrameComponent;
  Wh: TWheelComponent;
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
  { Locate the crown in the steering frame, not along world Y. TireWidth is
    the tire's half-width in the wheel generator. Leave room for both the
    tire and the blade wall instead of squeezing the crown to half hub width. }
  Wh := TWheelComponent(FindComponent(TWheelComponent));
  if (Wh <> nil) and (Wh.TireWidth >= 5) then TireHalfWidth := Wh.TireWidth * M
  else TireHalfWidth := DEF_TIRE_WIDTH * M;
  BladeRadius := ForkBladeDia * 0.5 * M;
  CrownHalfZ := Max(FrontHalfZ * 0.5, TireHalfWidth + BladeRadius + 5 * M);
  SteerUp := Vector3(Skel.HTDirX, Skel.HTDirY, 0).Normalize;
  CrownCenter := HTB - SteerUp * (CrownHalfZ + BladeRadius + 6 * M);
  Skel.AddBone('fork_crown_l', CrownCenter + Vector3(0, 0, CrownHalfZ));
  Skel.AddBone('fork_crown_r', CrownCenter - Vector3(0, 0, CrownHalfZ));
  Skel.AddBone('front_dropout_l', Vector3(Skel['front_axle'].X, Skel['front_axle'].Y, FrontHalfZ));
  Skel.AddBone('front_dropout_r', Vector3(Skel['front_axle'].X, Skel['front_axle'].Y, -FrontHalfZ));

  HTT := Skel['head_tube_top'];
  StemBase := Vector3(HTT.X+Skel.HTDirX*HeadsetSpacer*M, HTT.Y+Skel.HTDirY*HeadsetSpacer*M, 0);
  Skel.AddBone('stem_base', StemBase);
  StemEnd := Vector3(StemBase.X+Cos(DegToRad(StemAngle))*StemLength*M,
    StemBase.Y+Sin(DegToRad(StemAngle))*StemLength*M, 0);
  Skel.AddBone('stem_end', StemEnd);
end;

{ One continuous surface from the positive-Z dropout, around the crown,
  to the other dropout. A hole in the crown's upper surface is lofted into
  the crown race. Shared vertices keep the shoulders smooth at every LOD;
  there are no blade end caps or overlapping shells at the crown. }
function MakeForkBody(Ctx: TBikeBuildContext;
  const CrownPos, CrownNeg, DropPos, DropNeg, HeadBase, Up: TVector3;
  LatTop, DepTop, LatTip, DepTip, HeadRadius: Single): TTransformNode;
var
  Coord: TCoordinateNode;
  IFS: TIndexedFaceSetNode;
  Shape: TShapeNode;
  Lateral, ForwardAxis, Center, Radial, P, V: TVector3;
  Span, Alpha, Angle: Single;
  LegSeg, ArcSeg, TubeSeg, RingCount, I, J, K, NI, NJ: Integer;
  HoleLo, HoleHi, Quarter, BoundaryCount, NeckStart, Cap: Integer;
  Boundary: array of Integer;
  Remap: array of Integer;
  PackedPoints: array of TVector3;
  UsedCount, OldIndex: Integer;

  procedure Face(A, B, C: Integer; D: Integer = -1);
  begin
    IFS.FdCoordIndex.Items.Add(A);
    IFS.FdCoordIndex.Items.Add(B);
    IFS.FdCoordIndex.Items.Add(C);
    if D >= 0 then IFS.FdCoordIndex.Items.Add(D);
    IFS.FdCoordIndex.Items.Add(-1);
  end;

  procedure Ring(const C, N, DepthAxis: TVector3; Lat, Dep: Single);
  var Ndx: Integer; A: Single;
  begin
    for Ndx := 0 to TubeSeg - 1 do
    begin
      A := 2 * Pi * Ndx / TubeSeg;
      Coord.FdPoint.Items.Add(C + N * (Lat * Cos(A)) +
        DepthAxis * (Dep * Sin(A)));
    end;
  end;

  procedure BladeRing(const Drop, Crown: TVector3; T, Side: Single);
  var C1, C2, C, Tangent, N, DepthAxis: TVector3; U, WidthT: Single;
  begin
    U := 1 - T;
    C1 := Drop + (Crown - Drop) * 0.4;
    C2 := Crown - Up * ((Crown - Drop).Length * 0.22);
    C := Drop * (U*U*U) + C1 * (3*U*U*T) +
      C2 * (3*U*T*T) + Crown * (T*T*T);
    Tangent := ((C1 - Drop) * (3*U*U) + (C2 - C1) * (6*U*T) +
      (Crown - C2) * (3*T*T)).Normalize * Side;
    N := Lateral * Side;
    N := (N - Tangent * TVector3.DotProduct(N, Tangent)).Normalize;
    DepthAxis := TVector3.CrossProduct(Tangent, N).Normalize;
    { Zero taper derivative at the crown matches the arch's section. }
    WidthT := T * (2 - T);
    Ring(C, N, DepthAxis, LatTip + (LatTop - LatTip) * WidthT,
      DepTip + (DepTop - DepTip) * WidthT);
  end;

  procedure BoundaryVertex(RingIndex, TubeIndex: Integer);
  begin
    Boundary[BoundaryCount] := RingIndex * TubeSeg + TubeIndex;
    Inc(BoundaryCount);
  end;

begin
  Lateral := Vector3(0, 0, 1);
  ForwardAxis := TVector3.CrossProduct(Up, Lateral).Normalize;
  Center := (CrownPos + CrownNeg) * 0.5;
  Span := (CrownPos - CrownNeg).Length * 0.5;
  LegSeg := Max(3, Ctx.LOD_TorusSeg div 8);
  ArcSeg := Max(8, ((Ctx.LOD_TorusSeg div 2 + 3) div 4) * 4);
  TubeSeg := Max(8, ((Ctx.LOD_TorusTubeSeg + 3) div 4) * 4);
  Quarter := TubeSeg div 4;
  HoleLo := LegSeg + ArcSeg div 4;
  HoleHi := LegSeg + ArcSeg * 3 div 4;

  Coord := TCoordinateNode.Create;
  IFS := TIndexedFaceSetNode.Create;
  IFS.Coord := Coord;
  IFS.Solid := True;
  IFS.CreaseAngle := 1.5;
  for I := 0 to LegSeg do
    BladeRing(DropPos, CrownPos, I / LegSeg, 1);
  for I := 1 to ArcSeg do
  begin
    Alpha := Pi * I / ArcSeg;
    Radial := Lateral * Cos(Alpha) + Up * Sin(Alpha);
    Ring(Center + Radial * Span, Radial, ForwardAxis, LatTop, DepTop);
  end;
  for I := 1 to LegSeg do
    BladeRing(DropNeg, CrownNeg, 1 - I / LegSeg, -1);

  RingCount := LegSeg * 2 + ArcSeg + 1;
  for I := 0 to RingCount - 2 do
    for J := 0 to TubeSeg - 1 do
    begin
      if (I >= HoleLo) and (I < HoleHi) and
         ((J < Quarter) or (J >= Quarter * 3)) then Continue;
      NI := I + 1; NJ := (J + 1) mod TubeSeg;
      Face(I * TubeSeg + J, I * TubeSeg + NJ,
        NI * TubeSeg + NJ, NI * TubeSeg + J);
    end;

  { Trace the crown opening once, without repeated corner vertices. }
  SetLength(Boundary, 2 * (HoleHi - HoleLo) + TubeSeg);
  BoundaryCount := 0;
  for I := HoleLo to HoleHi - 1 do BoundaryVertex(I, Quarter * 3);
  for J := Quarter * 3 to Quarter * 5 - 1 do BoundaryVertex(HoleHi, J mod TubeSeg);
  for I := HoleHi downto HoleLo + 1 do BoundaryVertex(I, Quarter);
  for J := Quarter downto -Quarter + 1 do BoundaryVertex(HoleLo, (J + TubeSeg) mod TubeSeg);

  { The upper rim sits just inside the head tube. The stem and front axle
    keep their original positions; the crown rotates with the fork. }
  NeckStart := Coord.FdPoint.Items.Count;
  P := HeadBase + Up * (1.5 * Ctx.Skeleton.MM);
  for K := 0 to BoundaryCount - 1 do
  begin
    V := Coord.FdPoint.Items[Boundary[K]] - HeadBase;
    Angle := ArcTan2(TVector3.DotProduct(V, ForwardAxis), V.Z);
    Coord.FdPoint.Items.Add(P + Lateral * (HeadRadius * Cos(Angle)) +
      ForwardAxis * (HeadRadius * Sin(Angle)));
  end;
  for K := 0 to BoundaryCount - 1 do
  begin
    NI := (K + 1) mod BoundaryCount;
    Face(Boundary[K], NeckStart + K, NeckStart + NI, Boundary[NI]);
  end;
  Cap := Coord.FdPoint.Items.Count;
  Coord.FdPoint.Items.Add(P);
  for K := 0 to BoundaryCount - 1 do
    Face(Cap, NeckStart + (K + 1) mod BoundaryCount, NeckStart + K);

  Cap := Coord.FdPoint.Items.Count;
  Coord.FdPoint.Items.Add(DropPos);
  for J := 0 to TubeSeg - 1 do
    Face(Cap, (J + 1) mod TubeSeg, J);
  Cap := Coord.FdPoint.Items.Count;
  Coord.FdPoint.Items.Add(DropNeg);
  I := (RingCount - 1) * TubeSeg;
  for J := 0 to TubeSeg - 1 do
    Face(Cap, I + J, I + (J + 1) mod TubeSeg);

  { Discard the unused points inside the opening before uploading the mesh. }
  SetLength(Remap, Coord.FdPoint.Items.Count);
  SetLength(PackedPoints, Length(Remap));
  for I := 0 to High(Remap) do Remap[I] := -1;
  UsedCount := 0;
  for I := 0 to IFS.FdCoordIndex.Items.Count - 1 do
  begin
    OldIndex := IFS.FdCoordIndex.Items[I];
    if OldIndex < 0 then Continue;
    if Remap[OldIndex] < 0 then
    begin
      Remap[OldIndex] := UsedCount;
      PackedPoints[UsedCount] := Coord.FdPoint.Items[OldIndex];
      Inc(UsedCount);
    end;
    IFS.FdCoordIndex.Items[I] := Remap[OldIndex];
  end;
  Coord.FdPoint.Items.Clear;
  for I := 0 to UsedCount - 1 do Coord.FdPoint.Items.Add(PackedPoints[I]);

  if Ctx.AccumActive then
  begin
    Ctx.EmitBatched(IFS, Coord, Ctx.Colors.Frame, Ctx.Colors.FrameSpec,
      0.85, 1.5, TMatrix4.Identity);
    Exit(nil);
  end;
  Shape := TShapeNode.Create;
  Shape.Geometry := IFS;
  Shape.Appearance := Ctx.MakeMaterial(Ctx.Colors.Frame, Ctx.Colors.FrameSpec, 0.85);
  Result := TTransformNode.Create;
  Result.AddChildren(Shape);
end;

procedure TForkComponent.BuildGeometry(Ctx: TBikeBuildContext);
var
  S: TBikeSkeleton;
  Fr: TFrameComponent;
  M, HeadRadius: Single;
  Up: TVector3;
begin
  S := Ctx.Skeleton; M := S.MM;
  Up := Vector3(S.HTDirX, S.HTDirY, 0).Normalize;
  Fr := TFrameComponent(FindComponent(TFrameComponent));
  if Fr <> nil then HeadRadius := Max(10, Fr.HeadTubeDia) * 0.5 * M
  else HeadRadius := 22 * M;
  HeadRadius := Max(4 * M, HeadRadius - M);
  Ctx.BeginAccum(Ctx.SteerRoot);
  Ctx.Add(MakeForkBody(Ctx, Ctx.O(S['fork_crown_l']), Ctx.O(S['fork_crown_r']),
    Ctx.O(S['front_dropout_l']), Ctx.O(S['front_dropout_r']),
    Ctx.O(S['head_tube_bottom']), Up,
    ForkBladeDia * 0.5 * M, 25 * M, ForkTipDia * 0.5 * M, 15 * M, HeadRadius));
  Ctx.EndAccum;
end;

end.
