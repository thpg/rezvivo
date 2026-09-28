unit GameMath;

{ ════════════════════════════════════════════════════════════════════════
  GameMath — pure-math helpers shared across the project.

  Purpose:
    Single canonical home for all stateless mathematical operations used
    by bike geometry, rider skeleton, physics, paths, multiplayer relay,
    GPS conversion and JSON serialization. No classes, no module-level
    state, no game-engine objects.

  Dependency rule:
    This unit sits at the BOTTOM of the project's dependency graph.
    Allowed imports: Math, CastleVectors, fpjson — nothing higher.
    No GameXxx, no Castle* runtime types. Anything that needs scenes,
    transforms, trainers or paths goes elsewhere.

  Adding new functions here is fine if they are:
    • pure (output depends only on inputs);
    • used by 2+ different modules;
    • free of game-engine types other than CastleVectors / fpjson.
  Otherwise — add them to the module that owns the relevant domain.

  License: MIT
  ════════════════════════════════════════════════════════════════════════ }

{$mode objfpc}{$H+}

interface

uses
  Math, CastleVectors, fpjson;

{ ── Quaternion arithmetic ─────────────────────────────────────────────── }

{ Convert axis-angle (xyz=axis, w=angle in radians) to a unit quaternion
  (xyz=imaginary, w=real). }
function AA2Q(const AA: TVector4): TVector4;

{ Convert a unit quaternion (xyz=imaginary, w=real) to axis-angle
  representation (xyz=axis, w=angle in radians). }
function Q2AA(const Q: TVector4): TVector4;

{ Hamilton product of two quaternions (Result = A * B). }
function QMul(const A, B: TVector4): TVector4;

{ Quaternion conjugate. For unit quaternions this is also the inverse. }
function QConj(const Q: TVector4): TVector4;

{ Quaternion inverse (general case; falls back to identity if |Q|≈0). }
function QInv(const Q: TVector4): TVector4;

{ ── Rotation helpers (axis-angle representation, TVector4) ────────────── }

{ Axis-angle rotation that takes vector FromV to vector ToV.
  Both inputs SHOULD be unit length (this function does not normalize them).
  Special cases:
    parallel (Dot ≈ +1)  → identity rotation
    antiparallel (Dot ≈ -1) → 180° rotation around an arbitrary perpendicular axis. }
function RotBetween(const FromV, ToV: TVector3): TVector4;

{ Rotate vector V by axis-angle AA (Rodrigues formula). }
function RotVec(const V: TVector3; const AA: TVector4): TVector3;

{ Axis-angle rotation that maps +Y to Dir.
  Equivalent to RotBetween(Vector3(0,1,0), Dir) but cheaper (skips a Dot). }
function DirToRot(const Dir: TVector3): TVector4;

{ Unit vector from A to B; if |B-A| ≈ 0 returns +Y as a stable fallback. }
function SafeDir(const A, B: TVector3): TVector3;

{ Convert scene-space position to model-local space (used during rider posing). }
function ToModelSpace(const ScenePos, ModelOffset: TVector3;
                      const CenterX, InvScale: Single): TVector3;

{ ── XZ-plane helpers (treats Y as height; useful for ground-plane math) ─ }

{ Project V onto the XZ plane and normalize.
  If the projection is degenerate (length < eps) returns +Z (0,0,1). }
function NormalizeXZ(const V: TVector3): TVector3;

{ Euclidean distance between A and B in the XZ plane (Y ignored). }
function DistanceXZ(const A, B: TVector3): Single;

{ Linear interpolate two directions on the XZ plane and renormalize.
  Falls back to NormalizeXZ(B) if the lerped vector is degenerate. }
function LerpDirXZ(const A, B: TVector3; const T: Single): TVector3;

{ Signed angle from A to B in the XZ plane, in radians, range (-Pi, Pi]. }
function SignedAngleXZ(const A, B: TVector3): Single;

{ ── Modular arithmetic on a circular track ────────────────────────────── }

{ Wrap D into [0, TotalLength). If TotalLength <= 0 returns D unchanged. }
function WrapDistance(const D, TotalLength: Single): Single;

{ ── Interpolation primitives ──────────────────────────────────────────── }

{ Linearly remap Val from [SrcLo, SrcHi] to [DstLo, DstHi] and clamp. }
function MapRange(const Val, SrcLo, SrcHi, DstLo, DstHi: Single): Single;

{ Smoothstep: 0 below Edge0, 1 above Edge1, smooth Hermite blend in between. }
function SmoothStep(const Edge0, Edge1, X: Single): Single;

{ ── 2-bone IK (knee/elbow) ────────────────────────────────────────────── }

{ Compute mid-joint position given Root, Target endpoints and segment lengths.
  PlaneHint disambiguates the bend plane (e.g. knee forward, elbow back).
  Result lies on the plane spanned by (Target-Root) and PlaneHint, at
  distance UpperLen from Root, with mid-to-target distance LowerLen. }
function SolveJoint(const Root, Target: TVector3;
                    const UpperLen, LowerLen: Single;
                    const PlaneHint: TVector3): TVector3;

{ ── Geographic conversions (equirectangular near origin) ──────────────── }

{ Project (LatDeg, LonDeg) to local (East, North) metres using a tangent-plane
  approximation centered at (OriginLatDeg, OriginLonDeg).
  Result.X = East metres, Result.Y = North metres. }
function GpsToLocalEastNorth(const LatDeg, LonDeg, OriginLatDeg,
                             OriginLonDeg: Double): TVector2;

{ Inverse projection: local (East, North) metres → GPS degrees. }
procedure LocalEastNorthToGps(const EastM, NorthM, OriginLatDeg,
                              OriginLonDeg: Double;
                              out LatDeg, LonDeg: Double);

{ Solar position (NOAA approximation, no atmospheric refraction) at the
  given UTC moment and geographic point. AzimuthDeg is measured from NORTH,
  clockwise toward east (0=N, 90=E, 180=S); ElevationDeg above the horizon
  (negative = sun below horizon). Accurate to a fraction of a degree —
  the same class of algorithm the Osm3d streaming map derives its
  shadow-mask sun from (both take route start UTC + route geo). }
procedure SolarAzimuthElevation(const AUTC: TDateTime;
  const LatDeg, LonDeg: Double; out AzimuthDeg, ElevationDeg: Double);

{ ── JSON helpers (one-liners used by serializers across the project) ──── }

{ Convert TVector3 to a [x,y,z] JSON array (caller owns the result). }
function Vec3ToJSON(const V: TVector3): TJSONArray;

{ Read TVector3 from a [x,y,z] JSON array. Returns (0,0,0) if AArr is nil
  or has fewer than 3 elements. Does NOT free AArr. }
function JSONToVec3(const AArr: TJSONArray): TVector3;

implementation

const
  EARTH_RADIUS_M = 6371000.0;

{ ── Quaternion arithmetic ─────────────────────────────────────────────── }

function AA2Q(const AA: TVector4): TVector4;
var H, S, L: Single; Ax: TVector3;
begin
  if Abs(AA.W) < 0.0001 then Exit(Vector4(0, 0, 0, 1));
  Ax := Vector3(AA.X, AA.Y, AA.Z); L := Ax.Length;
  if L < 0.0001 then Exit(Vector4(0, 0, 0, 1));
  Ax := Ax * (1.0 / L); H := AA.W * 0.5; S := Sin(H);
  Result := Vector4(Ax.X * S, Ax.Y * S, Ax.Z * S, Cos(H));
end;

function Q2AA(const Q: TVector4): TVector4;
var Ax: TVector3; L, Angle, W: Single;
begin
  W := Q.W; Ax := Vector3(Q.X, Q.Y, Q.Z);
  if W < 0 then begin W := -W; Ax := -Ax; end;
  L := Ax.Length;
  if L < 0.0001 then Exit(Vector4(0, 0, 1, 0));
  Ax := Ax * (1.0 / L);
  Angle := 2.0 * ArcCos(EnsureRange(W, -1.0, 1.0));
  Result := Vector4(Ax.X, Ax.Y, Ax.Z, Angle);
end;

function QMul(const A, B: TVector4): TVector4;
begin
  Result := Vector4(
    A.W * B.X + A.X * B.W + A.Y * B.Z - A.Z * B.Y,
    A.W * B.Y - A.X * B.Z + A.Y * B.W + A.Z * B.X,
    A.W * B.Z + A.X * B.Y - A.Y * B.X + A.Z * B.W,
    A.W * B.W - A.X * B.X - A.Y * B.Y - A.Z * B.Z);
end;

function QConj(const Q: TVector4): TVector4;
begin
  Result := Vector4(-Q.X, -Q.Y, -Q.Z, Q.W);
end;

function QInv(const Q: TVector4): TVector4;
var L2: Single;
begin
  L2 := Q.X * Q.X + Q.Y * Q.Y + Q.Z * Q.Z + Q.W * Q.W;
  if L2 < 1e-12 then Exit(Vector4(0, 0, 0, 1));
  L2 := 1.0 / L2;
  Result := Vector4(-Q.X * L2, -Q.Y * L2, -Q.Z * L2, Q.W * L2);
end;

{ ── Rotation helpers ──────────────────────────────────────────────────── }

function RotBetween(const FromV, ToV: TVector3): TVector4;
var Axis: TVector3; Dot, Angle, L: Single;
begin
  Dot := TVector3.DotProduct(FromV, ToV);
  if Dot > 0.9999 then Exit(Vector4(0, 0, 1, 0));
  if Dot < -0.9999 then
  begin
    Axis := TVector3.CrossProduct(Vector3(1, 0, 0), FromV);
    if Axis.Length < 0.001 then
      Axis := TVector3.CrossProduct(Vector3(0, 1, 0), FromV);
    Axis := Axis.Normalize;
    Exit(Vector4(Axis.X, Axis.Y, Axis.Z, Pi));
  end;
  Axis := TVector3.CrossProduct(FromV, ToV);
  L := Axis.Length;
  if L < 0.0001 then Exit(Vector4(0, 0, 1, 0));
  Axis := Axis * (1.0 / L);
  Angle := ArcCos(EnsureRange(Dot, -1.0, 1.0));
  Result := Vector4(Axis.X, Axis.Y, Axis.Z, Angle);
end;

function RotVec(const V: TVector3; const AA: TVector4): TVector3;
var Axis: TVector3; C, S, Dot, L: Single;
begin
  if Abs(AA.W) < 0.0001 then Exit(V);
  Axis := Vector3(AA.X, AA.Y, AA.Z); L := Axis.Length;
  if L < 0.0001 then Exit(V);
  Axis := Axis * (1.0 / L);
  C := Cos(AA.W); S := Sin(AA.W);
  Dot := TVector3.DotProduct(Axis, V);
  Result := V * C + TVector3.CrossProduct(Axis, V) * S + Axis * Dot * (1.0 - C);
end;

function DirToRot(const Dir: TVector3): TVector4;
var Ax: TVector3; Dot, Ang: Single;
begin
  Dot := TVector3.DotProduct(Vector3(0, 1, 0), Dir);
  if Abs(Dot - 1.0) < 1e-6 then Exit(Vector4(1, 0, 0, 0));
  if Abs(Dot + 1.0) < 1e-6 then Exit(Vector4(1, 0, 0, Pi));
  Ax  := TVector3.CrossProduct(Vector3(0, 1, 0), Dir).Normalize;
  Ang := ArcCos(EnsureRange(Dot, -1, 1));
  Result := Vector4(Ax.X, Ax.Y, Ax.Z, Ang);
end;

function SafeDir(const A, B: TVector3): TVector3;
var D: TVector3; L: Single;
begin
  D := B - A; L := D.Length;
  if L > 0.0001 then Result := D * (1.0 / L)
  else Result := Vector3(0, 1, 0);
end;

function ToModelSpace(const ScenePos, ModelOffset: TVector3;
                      const CenterX, InvScale: Single): TVector3;
begin
  Result := Vector3(
    (ScenePos.X - CenterX - ModelOffset.X) * InvScale,
    (ScenePos.Y - ModelOffset.Y) * InvScale,
    (ScenePos.Z - ModelOffset.Z) * InvScale);
end;

{ ── XZ-plane helpers ──────────────────────────────────────────────────── }

function NormalizeXZ(const V: TVector3): TVector3;
begin
  Result := Vector3(V.X, 0, V.Z);
  if Result.Length > 0.001 then
    Result := Result.Normalize
  else
    Result := Vector3(0, 0, 1);
end;

function DistanceXZ(const A, B: TVector3): Single;
begin
  Result := Sqrt(Sqr(A.X - B.X) + Sqr(A.Z - B.Z));
end;

function LerpDirXZ(const A, B: TVector3; const T: Single): TVector3;
begin
  Result := Vector3(A.X + (B.X - A.X) * T, 0, A.Z + (B.Z - A.Z) * T);
  if Result.Length > 0.001 then
    Result := Result.Normalize
  else
    Result := NormalizeXZ(B);
end;

function SignedAngleXZ(const A, B: TVector3): Single;
var
  AN, BN: TVector3;
  CrossY, DotV: Single;
begin
  AN := A; BN := B;
  AN.Y := 0; BN.Y := 0;
  if AN.Length > 0.001 then AN := AN.Normalize;
  if BN.Length > 0.001 then BN := BN.Normalize;
  CrossY := AN.X * BN.Z - AN.Z * BN.X;
  DotV   := AN.X * BN.X + AN.Z * BN.Z;
  Result := ArcTan2(CrossY, DotV);
end;

{ ── Modular arithmetic ────────────────────────────────────────────────── }

function WrapDistance(const D, TotalLength: Single): Single;
var
  Remainder, Step: Double;
begin
  if IsNan(D) or IsInfinite(D) then Exit(0);
  Result := D;
  if IsNan(TotalLength) or IsInfinite(TotalLength) then Exit;
  if TotalLength <= 0 then Exit;
  if (D >= 0) and (D < TotalLength) then Exit;

  { Binary reduction is bounded by the Single exponent range. Repeated
    subtraction can stop making progress on large distances. FPC 3.2.2
    FMod uses a-b*Int(a/b), which loses the remainder for large quotients. }
  Remainder := Abs(Double(D));
  Step := TotalLength;
  while Step <= Remainder * 0.5 do Step := Step * 2;
  while Step >= TotalLength do
  begin
    if Remainder >= Step then Remainder := Remainder - Step;
    Step := Step * 0.5;
  end;
  if (D < 0) and (Remainder > 0) then Remainder := TotalLength - Remainder;
  Result := Remainder;
  { Conversion to Single can round a negative-distance remainder up to L. }
  if Result >= TotalLength then Result := 0;
end;

{ ── Interpolation primitives ──────────────────────────────────────────── }

function MapRange(const Val, SrcLo, SrcHi, DstLo, DstHi: Single): Single;
begin
  if SrcHi - SrcLo < 1e-6 then Exit(DstLo);
  Result := DstLo + (Val - SrcLo) / (SrcHi - SrcLo) * (DstHi - DstLo);
  Result := EnsureRange(Result, Min(DstLo, DstHi), Max(DstLo, DstHi));
end;

function SmoothStep(const Edge0, Edge1, X: Single): Single;
var T: Single;
begin
  T := EnsureRange((X - Edge0) / (Edge1 - Edge0 + 1e-8), 0.0, 1.0);
  Result := T * T * (3.0 - 2.0 * T);
end;

{ ── 2-bone IK ─────────────────────────────────────────────────────────── }

function SolveJoint(const Root, Target: TVector3;
                    const UpperLen, LowerLen: Single;
                    const PlaneHint: TVector3): TVector3;
var D, CosA, SinA: Single; ToTarget, Cross, Perp: TVector3;
begin
  D := (Target - Root).Length;
  if D < 0.001 then Exit(Root);
  D := EnsureRange(D, Abs(UpperLen - LowerLen) + 0.001,
                      UpperLen + LowerLen - 0.001);
  ToTarget := SafeDir(Root, Target);
  CosA := (UpperLen * UpperLen + D * D - LowerLen * LowerLen) /
          (2.0 * UpperLen * D);
  CosA := EnsureRange(CosA, -1.0, 1.0);
  SinA := Sqrt(1.0 - CosA * CosA);
  Cross := TVector3.CrossProduct(ToTarget, PlaneHint);
  if Cross.Length < 0.001 then
    Cross := TVector3.CrossProduct(ToTarget, Vector3(0, 0, 1));
  Cross := Cross.Normalize;
  Perp  := TVector3.CrossProduct(Cross, ToTarget).Normalize;
  Result := Root + ToTarget * (UpperLen * CosA) + Perp * (UpperLen * SinA);
end;

{ ── Geographic conversions ────────────────────────────────────────────── }

function GpsToLocalEastNorth(const LatDeg, LonDeg, OriginLatDeg,
                             OriginLonDeg: Double): TVector2;
var
  OriginLatRad, DeltaLatRad, DeltaLonRad: Double;
begin
  OriginLatRad := DegToRad(OriginLatDeg);
  DeltaLatRad  := DegToRad(LatDeg - OriginLatDeg);
  DeltaLonRad  := DegToRad(LonDeg - OriginLonDeg);
  Result.X := DeltaLonRad * Cos(OriginLatRad) * EARTH_RADIUS_M;
  Result.Y := DeltaLatRad * EARTH_RADIUS_M;
end;

procedure LocalEastNorthToGps(const EastM, NorthM, OriginLatDeg,
                              OriginLonDeg: Double;
                              out LatDeg, LonDeg: Double);
var
  OriginLatRad, DeltaLatRad, DeltaLonRad: Double;
begin
  OriginLatRad := DegToRad(OriginLatDeg);
  DeltaLatRad  := NorthM / EARTH_RADIUS_M;
  DeltaLonRad  := EastM / (Cos(OriginLatRad) * EARTH_RADIUS_M);
  LatDeg := OriginLatDeg + RadToDeg(DeltaLatRad);
  LonDeg := OriginLonDeg + RadToDeg(DeltaLonRad);
end;

procedure SolarAzimuthElevation(const AUTC: TDateTime;
  const LatDeg, LonDeg: Double; out AzimuthDeg, ElevationDeg: Double);
var
  JD, T, L0, M, E, C, TrueLong, Omega, Lambda, Eps0, Eps, Decl: Double;
  Y, EoT, MinutesUTC, TST, HA: Double;
  LatR, DeclR, HAR, CosZen, Zen, SinZen, AzA: Double;
begin
  { Julian day: TDateTime epoch 1899-12-30 00:00 = JD 2415018.5 }
  JD := 2415018.5 + AUTC;
  T := (JD - 2451545.0) / 36525.0;                 { Julian centuries from J2000 }

  L0 := 280.46646 + T * (36000.76983 + 0.0003032 * T);      { mean longitude }
  L0 := L0 - Floor(L0 / 360.0) * 360.0;
  M := 357.52911 + T * (35999.05029 - 0.0001537 * T);       { mean anomaly }
  E := 0.016708634 - T * (0.000042037 + 0.0000001267 * T);  { eccentricity }
  C := Sin(DegToRad(M))     * (1.914602 - T * (0.004817 + 0.000014 * T))
     + Sin(DegToRad(2 * M)) * (0.019993 - 0.000101 * T)
     + Sin(DegToRad(3 * M)) * 0.000289;                     { equation of center }
  TrueLong := L0 + C;
  Omega := 125.04 - 1934.136 * T;
  Lambda := TrueLong - 0.00569 - 0.00478 * Sin(DegToRad(Omega)); { apparent long. }
  Eps0 := 23.0 + (26.0 + (21.448
        - T * (46.815 + T * (0.00059 - T * 0.001813))) / 60.0) / 60.0;
  Eps := Eps0 + 0.00256 * Cos(DegToRad(Omega));             { corrected obliquity }
  Decl := RadToDeg(ArcSin(Sin(DegToRad(Eps)) * Sin(DegToRad(Lambda))));

  { equation of time, minutes }
  Y := Sqr(Tan(DegToRad(Eps / 2.0)));
  EoT := 4.0 * RadToDeg(
      Y * Sin(2.0 * DegToRad(L0))
    - 2.0 * E * Sin(DegToRad(M))
    + 4.0 * E * Y * Sin(DegToRad(M)) * Cos(2.0 * DegToRad(L0))
    - 0.5 * Y * Y * Sin(4.0 * DegToRad(L0))
    - 1.25 * E * E * Sin(2.0 * DegToRad(M)));

  { true solar time (minutes) and hour angle. Longitude EAST-positive. }
  MinutesUTC := Frac(AUTC) * 1440.0;
  TST := MinutesUTC + EoT + 4.0 * LonDeg;
  TST := TST - Floor(TST / 1440.0) * 1440.0;
  HA := TST / 4.0 - 180.0;

  LatR := DegToRad(LatDeg);
  DeclR := DegToRad(Decl);
  HAR := DegToRad(HA);
  CosZen := Sin(LatR) * Sin(DeclR) + Cos(LatR) * Cos(DeclR) * Cos(HAR);
  if CosZen > 1.0 then CosZen := 1.0 else if CosZen < -1.0 then CosZen := -1.0;
  Zen := ArcCos(CosZen);
  ElevationDeg := 90.0 - RadToDeg(Zen);

  SinZen := Sin(Zen);
  if Abs(SinZen) < 1e-9 then
    AzimuthDeg := 0.0                              { sun at zenith — azimuth moot }
  else
  begin
    AzA := (Sin(LatR) * CosZen - Sin(DeclR)) / (Cos(LatR) * SinZen);
    if AzA > 1.0 then AzA := 1.0 else if AzA < -1.0 then AzA := -1.0;
    AzA := RadToDeg(ArcCos(AzA));
    if HA > 0.0 then
      AzimuthDeg := AzA + 180.0
    else
      AzimuthDeg := 540.0 - AzA;
    AzimuthDeg := AzimuthDeg - Floor(AzimuthDeg / 360.0) * 360.0;
  end;
end;

{ ── JSON helpers ──────────────────────────────────────────────────────── }

function Vec3ToJSON(const V: TVector3): TJSONArray;
begin
  Result := TJSONArray.Create;
  Result.Add(TJSONFloatNumber.Create(V.X));
  Result.Add(TJSONFloatNumber.Create(V.Y));
  Result.Add(TJSONFloatNumber.Create(V.Z));
end;

function JSONToVec3(const AArr: TJSONArray): TVector3;
begin
  Result := Vector3(0, 0, 0);
  if (AArr = nil) or (AArr.Count < 3) then Exit;
  Result.X := AArr.Floats[0];
  Result.Y := AArr.Floats[1];
  Result.Z := AArr.Floats[2];
end;

end.
