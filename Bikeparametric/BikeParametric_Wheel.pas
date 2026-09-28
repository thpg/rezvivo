unit BikeParametric_Wheel;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Math, CastleUtils, CastleVectors, X3DNodes,
  BikeParametric;

type
  TWheelComponent = class(TBikeComponent)
  private
    FWheelRadius: Single;     { mm, outer radius (axle to ground contact) }
    FTireWidth: Single;       { mm, tire cross-section half-width (= torus MinorR) }
    FFrontRimHeight: Single;  { mm, rim depth (extends inward from tire bead) }
    FRearRimHeight: Single;   { mm, rim depth (extends inward from tire bead) }
    FSpokeCount: Integer;
    FHubWidth: Single;
  public
    constructor Create; override;
    class function ComponentName: string; override;
    procedure ApplyPreset(const APreset: string); override;
    procedure ComputeBones(Skel: TBikeSkeleton); override;
    procedure BuildGeometry(Ctx: TBikeBuildContext); override;
  published
    property WheelRadius: Single read FWheelRadius write FWheelRadius;
    property TireWidth: Single read FTireWidth write FTireWidth;
    property FrontRimHeight: Single read FFrontRimHeight write FFrontRimHeight;
    property RearRimHeight: Single read FRearRimHeight write FRearRimHeight;
    property SpokeCount: Integer read FSpokeCount write FSpokeCount;
    property HubWidth: Single read FHubWidth write FHubWidth;
  end;

const
  { Road defaults — 700c with 28mm tire. Single source: Create seeds these,
    ComputeBones falls back to them on invalid input, and peer components
    (frame geometry, shadow/wheel-speed fallbacks) read them cross-unit. }
  DEF_WHEEL_RADIUS     = 339;   { mm, 700c }
  DEF_TIRE_WIDTH       = 14;    { mm }
  DEF_RIM_HEIGHT       = 30;    { mm }
  DEF_SPOKE_COUNT      = 16;
  DEF_HUB_WIDTH        = 60;    { mm }

implementation

{ Geometry notes:
    WheelRadius = outer radius of the tire (axle to ground contact), in mm.
    TireWidth   = tire cross-section half-width (torus MinorR), in mm.
    Torus MajorR = WheelRadius - TireWidth, so the outer edge of the
    torus reaches exactly WheelRadius and the bottom touches the ground.

    Rim = aero profile: flat outer wall (tire bead) + half-torus inner.
    Axial half-width = 80% of TireWidth so rim never pokes out past tire. }

constructor TWheelComponent.Create;
begin
  inherited Create;
  FWheelRadius    := DEF_WHEEL_RADIUS;
  FTireWidth      := DEF_TIRE_WIDTH;
  FFrontRimHeight := DEF_RIM_HEIGHT;
  FRearRimHeight  := DEF_RIM_HEIGHT;
  FSpokeCount     := DEF_SPOKE_COUNT;
  FHubWidth       := DEF_HUB_WIDTH;
end;

class function TWheelComponent.ComponentName: string; begin Result := 'Wheels'; end;

procedure TWheelComponent.ApplyPreset(const APreset: string);
begin
  if SameText(APreset, 'gravel') then begin
    WheelRadius := 349;
    TireWidth   := 20;
  end else if SameText(APreset, 'mtb') then begin
    WheelRadius := 368;
    TireWidth   := 29;
    SpokeCount  := 16;
    HubWidth    := 60;
  end;
  { 'road' (or anything else) → use defaults from Create. }
end;

procedure TWheelComponent.ComputeBones(Skel: TBikeSkeleton);
begin
  if WheelRadius    < 200 then WheelRadius    := DEF_WHEEL_RADIUS;
  if TireWidth      < 5   then TireWidth      := DEF_TIRE_WIDTH;
  if FrontRimHeight < 5   then FrontRimHeight := DEF_RIM_HEIGHT;
  if RearRimHeight  < 5   then RearRimHeight  := DEF_RIM_HEIGHT;
  if SpokeCount     < 4   then SpokeCount     := DEF_SPOKE_COUNT;
  if HubWidth       < 20  then HubWidth       := DEF_HUB_WIDTH;
end;

{ Build an aero rim ring with a half-torus inner profile. }
function MakeRimRing(Ctx: TBikeBuildContext; const Center: TVector3;
  OuterR, InnerR, HalfW: Single; Seg: Integer;
  const Color, Spec: TVector3; Shininess: Single): TTransformNode;
var
  InnerSeg: Integer;
  PPR: Integer;
  IFS: TIndexedFaceSetNode;
  Coord: TCoordinateNode;
  Shape: TShapeNode;
  I, J, NI, AK, BK, AK1, BK1: Integer;
  Theta, CT, ST, Phi, R, Z, RimH: Single;
begin
  case Ctx.DetailLevel of
    0: InnerSeg := 3;
    1: InnerSeg := 5;
    2: InnerSeg := 6;
  else InnerSeg := 8;
  end;
  RimH := OuterR - InnerR;
  PPR := InnerSeg + 1;
  Coord := TCoordinateNode.Create;

  for I := 0 to Seg - 1 do
  begin
    Theta := 2 * Pi * I / Seg;
    CT := Cos(Theta); ST := Sin(Theta);
    R := OuterR; Z := HalfW;
    Coord.FdPoint.Items.Add(Vector3(R * CT, R * ST, Z));
    for J := 1 to InnerSeg do
    begin
      Phi := Pi * J / InnerSeg;
      R := OuterR - RimH * Sin(Phi);
      Z := HalfW * Cos(Phi);
      Coord.FdPoint.Items.Add(Vector3(R * CT, R * ST, Z));
    end;
  end;

  IFS := TIndexedFaceSetNode.Create;
  IFS.Coord := Coord; IFS.Solid := false; IFS.CreaseAngle := 1.2;
  for I := 0 to Seg - 1 do
  begin
    NI := (I + 1) mod Seg;
    AK  := I  * PPR;      BK  := NI * PPR;
    AK1 := I  * PPR + 1;  BK1 := NI * PPR + 1;
    IFS.FdCoordIndex.Items.Add(AK); IFS.FdCoordIndex.Items.Add(AK1);
    IFS.FdCoordIndex.Items.Add(BK1); IFS.FdCoordIndex.Items.Add(BK); IFS.FdCoordIndex.Items.Add(-1);

    { strips down the dished inner profile. NOTE: starts at J=1 (not J=2) — the
      J1->J2 strip was previously skipped, leaving an open wedge on the +Z bead side
      only, so the rim looked one-sided as the height grew. J=1 closes it symmetrically. }
    for J := 1 to InnerSeg - 1 do
    begin
      AK  := I  * PPR + J;      BK  := NI * PPR + J;
      AK1 := I  * PPR + J + 1;  BK1 := NI * PPR + J + 1;
      IFS.FdCoordIndex.Items.Add(AK); IFS.FdCoordIndex.Items.Add(AK1);
      IFS.FdCoordIndex.Items.Add(BK1); IFS.FdCoordIndex.Items.Add(BK); IFS.FdCoordIndex.Items.Add(-1);
    end;

    AK  := I  * PPR + InnerSeg;  BK  := NI * PPR + InnerSeg;
    AK1 := I  * PPR + 0;         BK1 := NI * PPR + 0;
    IFS.FdCoordIndex.Items.Add(AK); IFS.FdCoordIndex.Items.Add(AK1);
    IFS.FdCoordIndex.Items.Add(BK1); IFS.FdCoordIndex.Items.Add(BK); IFS.FdCoordIndex.Items.Add(-1);
  end;

  if Ctx.AccumActive then
  begin
    { батч: обод уходит в аккумулятор (crease 1.2), Shape-нода не создаётся;
      EmitBatched забирает IFS+Coord на переработку }
    Ctx.EmitBatched(IFS, Coord, Color, Spec, Shininess, 1.2,
      TranslationMatrix(Center));
    Exit(nil);
  end;

  Shape := TShapeNode.Create;
  Shape.Geometry := IFS;
  Shape.Appearance := Ctx.MakeMaterial(Color, Spec, Shininess);

  Result := TTransformNode.Create;
  Result.Translation := Center;
  Result.AddChildren(Shape);
end;

procedure TWheelComponent.BuildGeometry(Ctx: TBikeBuildContext);
var
  S: TBikeSkeleton; M, WR, TW, RimR: Single;
  RimH, RimInnerR, RimHalfW, SpokeEndR: Single;
  AxleName, DefName: string; Pos, HP1, HP2, SP1, SP2: TVector3;
  WheelTrans, RotTrans: TTransformNode;
  A, I, LocalSpokeCount: Integer; OX, OY, ZO: Single;
begin
  S := Ctx.Skeleton; M := S.MM;
  WR := WheelRadius * M;
  TW := TireWidth * M;
  RimR := WR - TW;

  for I := 0 to 1 do
  begin
    if I = 0 then begin
      AxleName := 'rear_axle'; DefName := 'RearWheelRot';
      RimH := RearRimHeight * M;
    end else begin
      AxleName := 'front_axle'; DefName := 'FrontWheelRot';
      RimH := FrontRimHeight * M;
    end;

    RimH := Min(RimH, RimR - 0.040);
    RimInnerR := RimR - RimH;
    RimHalfW := TW * 0.80;
    SpokeEndR := RimInnerR + 0.003;

    Pos := Ctx.O(S[AxleName]);
    WheelTrans := TTransformNode.Create;
    WheelTrans.Translation := Pos;
    RotTrans := TTransformNode.Create;
    RotTrans.X3DName := DefName;

    { батч: вся геометрия колеса (обод/покрышка/втулка/спицы) — в несколько
      мешей по материалам вместо десятков Shape-нод; RotTrans (цель роута
      WheelTimer) остаётся нетронутым }
    Ctx.BeginAccum(RotTrans);

    Ctx.AddTo(RotTrans, Ctx.MakeTorus(TVector3.Zero, RimR, TW,
      Ctx.Colors.Tire, Ctx.Colors.TireSpec, 0.15));

    Ctx.AddTo(RotTrans, MakeRimRing(Ctx, TVector3.Zero,
      RimR, RimInnerR, RimHalfW, Ctx.LOD_RimSeg,
      Ctx.Colors.Rim, Ctx.Colors.RimSpec, 0.6));

    HP1 := Vector3(0, 0, -HubWidth / 2 * M);
    HP2 := Vector3(0, 0,  HubWidth / 2 * M);
    Ctx.AddTo(RotTrans, Ctx.MakeCylinder(HP1, HP2, 0.02,
      Ctx.Colors.Chrome, Ctx.Colors.ChromeSpec, 1.0));

    LocalSpokeCount := Max(4, SpokeCount div Ctx.LOD_SpokeDivisor);
    for A := 0 to LocalSpokeCount - 1 do
    begin
      OX := Cos(2 * Pi * A / LocalSpokeCount) * SpokeEndR;
      OY := Sin(2 * Pi * A / LocalSpokeCount) * SpokeEndR;
      if (A mod 2) = 0 then ZO := 0.015 else ZO := -0.015;
      SP1 := Vector3(0, 0, ZO * 0.3);
      SP2 := Vector3(OX, OY, ZO);
      Ctx.AddTo(RotTrans, Ctx.MakeQuad(SP1, SP2, 0.0008,
        Ctx.Colors.Spoke, Ctx.Colors.ChromeSpec, 0.9));
    end;

    Ctx.EndAccum;

    WheelTrans.AddChildren(RotTrans);
    { Front wheel turns with steerer; rear stays on frame Root.
      AddSteered = Add when BikeDebugDisableSteer. }
    if I = 0 then
      Ctx.Add(WheelTrans)
    else
      Ctx.AddSteered(WheelTrans);
  end;
end;

end.
