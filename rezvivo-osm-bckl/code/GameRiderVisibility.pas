unit GameRiderVisibility;

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}

interface

uses CastleVectors, CastleFrustum;

const
  RIDER_VISIBILITY_MIN_RADIUS = 3.0;
  RIDER_VISIBILITY_SHADOW_RAY = 1000000.0;
  { Slightly above tan(0.7 degrees). Pass the active renderer's value when known. }
  RIDER_VISIBILITY_SHADOW_CONE = 0.012218;

var
  { Runtime MCP A/B switch; not a persisted user graphics preference. }
  RiderVisibilityEnabled: Boolean = True;

type
  TRiderVisibilityPlane = record
    X, Y, Z, W, ShadowSlope: Double;
  end;

  { Prepare once from the CURRENT camera, then reuse for every rider. This
    never inspects individual skinned shapes: their rest bounds can exclude
    animated legs. Position is the rider/bicycle world origin, height in metres.

    ShadowDirection points AWAY FROM the sun, along the cast shadow, unlike
    the receiver-to-sun direction used by an RTX visibility ray. The shadow
    envelope is the body sphere swept along that direction, expanding by
    distance * ConeTangent. It is deliberately larger than the actual shadow.

    Invalid camera, bounds or active shadow parameters fail open. This only
    decides whether the WHOLE actor can be skipped, never changes animation,
    individual shape culling, scene membership or shadow-caster registration. }
  TRiderVisibilityContext = record
  private
    FPlanes: array[0..5] of TRiderVisibilityPlane;
    FPlaneCount: Integer;
    FCameraValid, FShadowsActive, FShadowValid: Boolean;
    FShadowRayLength: Double;
    function BodySphereVisible(const X, Y, Z, Radius: Double): Boolean;
    function ShadowSphereVisible(const X, Y, Z, Radius: Double): Boolean;
  public
    function BodyVisible(const WorldPosition: TVector3;
      const HeightMetres: Single): Boolean;
    { False if shadows are disabled; otherwise includes the t=0 body volume. }
    function ShadowVisible(const WorldPosition: TVector3;
      const HeightMetres: Single): Boolean;
    function Visible(const WorldPosition: TVector3;
      const HeightMetres: Single): Boolean;
    property CameraValid: Boolean read FCameraValid;
    property ShadowsActive: Boolean read FShadowsActive;
    property ShadowValid: Boolean read FShadowValid;
  end;

function PrepareRiderVisibility(const Frustum: TFrustum;
  const CameraValid, ShadowsActive: Boolean;
  const ShadowDirection: TVector3;
  const MaxShadowDistance: Single = RIDER_VISIBILITY_SHADOW_RAY;
  const ConeTangent: Single = RIDER_VISIBILITY_SHADOW_CONE): TRiderVisibilityContext;

implementation

uses Math;

function Finite(const V: Double): Boolean; inline;
begin
  Result := not IsNan(V) and not IsInfinite(V);
end;

function BodySphere(const Position: TVector3; const Height: Single;
  out X, Y, Z, Radius: Double): Boolean;
begin
  Result := Finite(Position.X) and Finite(Position.Y) and Finite(Position.Z)
    and Finite(Height) and (Height > 0);
  if not Result then Exit;
  X := Position.X;
  Y := Double(Position.Y) + 1.0;
  Z := Position.Z;
  { Standard and short riders retain a 3 m envelope for the complete bicycle,
    standing pedalling, lean, dismount and outstretched arms. Tall/custom
    riders grow the envelope instead of clamping to the nominal model. }
  Radius := Max(RIDER_VISIBILITY_MIN_RADIUS, Double(Height) * 1.5);
end;

function PlaneSupport(const P: TRiderVisibilityPlane;
  const X, Y, Z, Radius: Double): Double; inline;
var A, B, C: Double;
begin
  A := P.X * X; B := P.Y * Y; C := P.Z * Z;
  { CGE planes/world coordinates originate as Single. Keep a small world-space
    margin and account for cancellation at large world origins in Double. }
  Result := A + B + C + P.W + Radius + 0.02 +
    0.000001 * (Abs(A) + Abs(B) + Abs(C) + Abs(P.W));
end;

function PrepareRiderVisibility(const Frustum: TFrustum;
  const CameraValid, ShadowsActive: Boolean;
  const ShadowDirection: TVector3;
  const MaxShadowDistance, ConeTangent: Single): TRiderVisibilityContext;
var FP: TFrustumPlane; P: TVector4; I: Integer;
  LengthSqr, InvLength, DX, DY, DZ: Double;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.FShadowsActive := ShadowsActive;
  if not CameraValid then Exit;
  for FP := Low(FP) to High(FP) do
  begin
    if (FP = fpFar) and Frustum.FarInfinity then Continue;
    P := Frustum.Planes[FP];
    if not (Finite(P.X) and Finite(P.Y) and Finite(P.Z) and Finite(P.W)) then Exit;
    LengthSqr := Double(P.X)*P.X + Double(P.Y)*P.Y + Double(P.Z)*P.Z;
    if LengthSqr < 1.0e-30 then Exit;
    InvLength := 1.0 / Sqrt(LengthSqr);
    I := Result.FPlaneCount;
    Result.FPlanes[I].X := P.X * InvLength;
    Result.FPlanes[I].Y := P.Y * InvLength;
    Result.FPlanes[I].Z := P.Z * InvLength;
    Result.FPlanes[I].W := P.W * InvLength;
    Inc(Result.FPlaneCount);
  end;
  Result.FCameraValid := True;
  Result.FShadowValid := not ShadowsActive;
  if not ShadowsActive then Exit;
  if not (Finite(ShadowDirection.X) and Finite(ShadowDirection.Y) and
    Finite(ShadowDirection.Z) and Finite(MaxShadowDistance) and
    Finite(ConeTangent)) then Exit;
  if (MaxShadowDistance < 0) or (ConeTangent < 0) then Exit;
  LengthSqr := Double(ShadowDirection.X)*ShadowDirection.X +
    Double(ShadowDirection.Y)*ShadowDirection.Y + Double(ShadowDirection.Z)*ShadowDirection.Z;
  if LengthSqr < 1.0e-20 then Exit;
  InvLength := 1.0 / Sqrt(LengthSqr);
  DX := ShadowDirection.X * InvLength;
  DY := ShadowDirection.Y * InvLength;
  DZ := ShadowDirection.Z * InvLength;
  Result.FShadowRayLength := MaxShadowDistance;
  for I := 0 to Result.FPlaneCount - 1 do
    with Result.FPlanes[I] do
      { Expanding spheres also bound the transverse penumbra disks. The tiny
        extra slope covers Single direction/plane errors along long rays. }
      ShadowSlope := X*DX + Y*DY + Z*DZ + ConeTangent + 0.000001;
  Result.FShadowValid := True;
end;

function TRiderVisibilityContext.BodySphereVisible(
  const X, Y, Z, Radius: Double): Boolean;
var I: Integer;
begin
  if not FCameraValid then Exit(True);
  for I := 0 to FPlaneCount - 1 do
    if PlaneSupport(FPlanes[I], X, Y, Z, Radius) < 0 then Exit(False);
  Result := True;
end;

function TRiderVisibilityContext.ShadowSphereVisible(
  const X, Y, Z, Radius: Double): Boolean;
var I: Integer; FirstT, LastT, A, B: Double;
begin
  if not FShadowsActive then Exit(False);
  if not FCameraValid or not FShadowValid then Exit(True);
  FirstT := 0;
  LastT := FShadowRayLength;
  for I := 0 to FPlaneCount - 1 do
  begin
    { RTX offsets the receiver by normal/depth bias; include this too. }
    A := PlaneSupport(FPlanes[I], X, Y, Z, Radius + 0.25);
    B := FPlanes[I].ShadowSlope;
    { Every point inside the frustum must satisfy ALL plane inequalities at
      the SAME sweep distance. Intersect their necessary intervals rather
      than testing the huge 1,000 km cone endpoint separately for each plane. }
    if B > 0 then
    begin
      if A < 0 then FirstT := Max(FirstT, -A / B);
    end else if B < 0 then
    begin
      if A < 0 then Exit(False);
      LastT := Min(LastT, A / (-B));
    end else if A < 0 then Exit(False);
    if FirstT > LastT then Exit(False);
  end;
  Result := True;
end;

function TRiderVisibilityContext.BodyVisible(const WorldPosition: TVector3;
  const HeightMetres: Single): Boolean;
var X, Y, Z, R: Double;
begin
  if not RiderVisibilityEnabled then Exit(True);
  if not BodySphere(WorldPosition, HeightMetres, X, Y, Z, R) then Exit(True);
  Result := BodySphereVisible(X, Y, Z, R);
end;

function TRiderVisibilityContext.ShadowVisible(const WorldPosition: TVector3;
  const HeightMetres: Single): Boolean;
var X, Y, Z, R: Double;
begin
  if not FShadowsActive then Exit(False);
  if not RiderVisibilityEnabled then Exit(True);
  if not BodySphere(WorldPosition, HeightMetres, X, Y, Z, R) then Exit(True);
  Result := ShadowSphereVisible(X, Y, Z, R);
end;

function TRiderVisibilityContext.Visible(const WorldPosition: TVector3;
  const HeightMetres: Single): Boolean;
var X, Y, Z, R: Double;
begin
  if not RiderVisibilityEnabled then Exit(True);
  if not BodySphere(WorldPosition, HeightMetres, X, Y, Z, R) then Exit(True);
  Result := BodySphereVisible(X, Y, Z, R) or ShadowSphereVisible(X, Y, Z, R);
end;

end.
