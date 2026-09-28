unit Osm3dGeomRoadJoints;

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$codepage UTF8}
{$WARN 5091 OFF}

interface

uses
  SysUtils,
  Math,
  Osm3dGeomTerrain
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
;

type

  TPolylinePointClass = (
    ppcStraight,      { |angle| < STRAIGHT_RAD; digitising noise, emit as-is }
    ppcSmoothCurve,   { gentle bend  5..25°; shoulders + CR through the node }
    ppcSharpCorner,   { sharp corner 25..135°; inscribed arc fillet (inward) }
    ppcHairpin        { switchback  >= 135°; tighter inscribed arc fillet    }
  );

  TClassifiedPoint = record
    X, Z:       Single;
    AccumLen:   Single;       { accumulated 2D length along original polyline }
    TurnRad:    Single;       { signed turn angle at this point (0 for endpoints) }
    PointClass: TPolylinePointClass;
  end;
  TClassifiedPointArray = array of TClassifiedPoint;

  TPolylineStats = record
    Total:        Integer;        { input point count }
    Straight:     Integer;
    Smooth:       Integer;
    Sharp:        Integer;
    Hairpin:      Integer;
    Subdivided:   Integer;        { intermediate points added by Catmull-Rom }
    ShoulderPts:  Integer;        { collinear shoulder points inserted around bends }
    Filleted:     Integer;        { sharp corners replaced by an inscribed arc }
    JointEdgesIn: Integer;        { = Total (input centerline points after subdivision) }
    JointEdgesOut: Integer;       { TRibbonEdgePoint count emitted; > input when bevel/round }
  end;

const
  { Angle thresholds (radians). Below STRAIGHT the turn is digitising noise and stays linear;
    EVERYTHING above gets smoothed, including a SINGLE bent node. Rationale: OSM mappers add nodes
    only where the road leaves the straight, so a lone 10..60° node mid-way is almost always a
    coarsely traced real curve, and even a mapped 90° corner has a physical fillet radius in
    reality — asphalt never folds like paper. True zero-radius kinks live at way junctions, which
    TIntersectionBuilder handles separately. Two mechanisms by class: GENTLE bends keep centripetal
    Catmull-Rom THROUGH the node (it sits on the real curve); SHARP corners and HAIRPINS are cut
    INWARD with an inscribed tangent arc — for them the node marks the intersection of the two
    straight tangents, the real curve lies inside the wedge, and a through-the-apex spline both
    bulges outward and can fold the inner ribbon edge into an accordion once its local radius
    drops below halfWidth. Better a curve where reality had a corner than the reverse. }
  CLASS_STRAIGHT_RAD = 0.0873;   { ≈   5° }
  CLASS_SMOOTH_RAD   = 0.4363;   { ≈  25° — gentle bend / sharp corner boundary }
  CLASS_HAIRPIN_RAD  = 2.3562;   { ≈ 135° — switchback apex }

  { Joint geometry thresholds. }
  JOINT_STRAIGHT_RAD = 0.0524;   { ≈   3° — single-point mitre with avg perp }
  JOINT_MITRE_LIMIT  = 1.5;      { mitre extension ≤ this × halfWidth        }
  JOINT_ROUND_RAD    = 2.0071;   { ≈ 115° — switch from bevel to round       }
  JOINT_ROUND_STEPS_BASE = 3;
  JOINT_ROUND_STEPS_EXTRA = 5;   { ≥ 160° gets 5 fan slices                  }

  { Catmull-Rom subdivision parameters. }
  CR_DEFAULT_CHORD_ERR_M = 0.30;
  CR_DEFAULT_MIN_SEG_M   = 2.0;
  CR_MAX_SUBDIV_PER_EDGE = 16;
  { If a Catmull-Rom interpolated sample goes "backward" relative to
    the P1→P2 chord direction by more than this fraction of the chord,
    the spline is twisted (loop or cusp) — fall back to linear. }
  CR_BACKWARD_TOLERANCE  = 0.05;
  { Поперечный лимит валидации сплайна: отклонение сэмпла от хорды не
    больше доли её длины (+ абсолютный запас на короткие хорды).
    Гладкая дуга держится куда ближе; дальше — взрыв, откат к хорде. }
  CR_MAX_PERP_FRAC       = 1.0;
  CR_MAX_PERP_SLACK_M    = 5.0;

  { Gentle-bend "shoulders": collinear helper points inserted on LONG edges around a gentle bend
    so the spline's lateral deviation stays confined near the bend instead of bowing a 100+ m
    straight off the mapped line. The route snapper and the road-distance field are built from the
    RAW node-to-node polyline (snap tolerance is 3.5 m past the kerb), so the smoothed centerline
    must hug it. An edge shorter than La + Lb + MIN is left untouched: dense tracing (10..30 m per
    node) already confines the curve there. }
  SHOULDER_GENTLE_M  = 20.0;
  SHOULDER_MIN_LEN_M = 2.0;

  { Inscribed-arc fillet for sharp corners and hairpins. The corner node is REPLACED by a circular
    arc tangent to both adjacent segments — strictly inside the wedge, never outward. Tangent
    length L = R * tan(turn/2), capped at FILLET_EDGE_FRAC of each adjacent edge; the effective
    radius is then re-derived from the capped L. If it falls below FILLET_MIN_RADIUS_FACTOR *
    halfWidth the fillet is skipped (the inner ribbon edge would fold into an accordion) and the
    corner is left to the classic bevel/round joints in BuildRibbonEdges — pre-feature behaviour. }
  FILLET_RADIUS_SHARP_M    = 8.0;    { urban corner design radius             }
  FILLET_RADIUS_HAIRPIN_M  = 6.0;    { switchbacks are tighter                }
  FILLET_MIN_RADIUS_FACTOR = 1.5;    { R >= factor * halfWidth or no fillet   }
  FILLET_MAX_STEP_RAD      = 0.18;   { ≈ 10° of arc per emitted chord         }
  FILLET_EDGE_FRAC         = 0.45;   { max share of an adjacent edge for L    }

{ Classify each point of Center by its signed turn angle. Open-way endpoints are Straight; on a
  CLOSED polyline (P0 = PN-1, e.g. a roundabout) the seam turn is computed across the wrap and
  assigned to both end copies, so the closure smooths like any other bend. Output indexes match
  input. }
procedure ClassifyPolyline(const Center: TRibbonVertexArray;
  out Classified: TClassifiedPointArray);

{ Per-corner geometry preparation, two passes:
  1) SHARP/HAIRPIN nodes are replaced by an inscribed tangent arc cut INWARD (see FILLET_* above);
     corners that cannot host a safe radius keep their position with TurnRad zeroed, so the later
     stages leave them to the bevel/round joint machinery.
  2) GENTLE nodes get collinear "shoulder" points on long adjacent edges (see SHOULDER_* above);
     shoulders double as clean Catmull-Rom boundary controls.
  Stats.Filleted / Stats.ShoulderPts count the work done. }
procedure PrepareCorners(const Pts: TClassifiedPointArray;
  HalfWidth: Single;
  out Expanded: TClassifiedPointArray;
  var Stats: TPolylineStats);

{ Subdivide EVERY edge that touches a bent node (|turn| >= CLASS_STRAIGHT_RAD) via centripetal
  Catmull-Rom. After PrepareCorners only GENTLE bends still carry a turn (sharp corners became
  zero-turn arc points or zero-turn fallbacks), so the spline runs THROUGH gentle nodes — they sit
  on the real curve — and a single bent node rounds both its edges into a C1 curve. Straight-
  straight edges pass through verbatim; AccumLen is recomputed on the output density. Control
  points clamp at open ends and wrap across the seam of closed polylines. }
procedure SubdivideSmoothRuns(const Classified: TClassifiedPointArray;
  out Smoothed: TRibbonVertexArray;
  var Stats: TPolylineStats;
  MaxChordErrorM: Single = CR_DEFAULT_CHORD_ERR_M;
  MinSegmentLenM: Single = CR_DEFAULT_MIN_SEG_M;
  MaxSubdivisionsPerEdge: Integer = CR_MAX_SUBDIV_PER_EDGE);

{ Build TRibbonEdgePointArray with joint geometry: endpoints/mitre = one edge-point; bevel = two
  (shared inner mitre, differing outer perp); round = N+1 fan points on the outer arc. Mitre falls
  back to bevel past MitreLimit*halfWidth, and to round near reversal. All edge-points at one
  centerline position carry the same AccumLen, so lane markings deform but don't break at corners. }
procedure BuildRibbonEdges(const Center: TRibbonVertexArray;
  HalfWidth: Single;
  out Edges: TRibbonEdgePointArray;
  var Stats: TPolylineStats);

{ Full pipeline in one call: classify → fillet sharp corners inward + shoulder gentle bends →
  Catmull-Rom the gentle bends → build edges with joints. Convenience for AppendWayRibbon. }
procedure BuildSmoothRibbonEdges(const Center: TRibbonVertexArray;
  HalfWidth: Single;
  out Edges: TRibbonEdgePointArray;
  out Stats: TPolylineStats;
  MaxChordErrorM: Single = CR_DEFAULT_CHORD_ERR_M;
  const ANoFillet: TBoolArray = nil);

implementation

{ Общий аппендер точки в растущий классифицированный массив (удвоение ёмкости).
  Раньше тело дублировалось во вложенных Push в FilletPass/ShoulderPass. }
procedure PushClassifiedPoint(var AOut: TClassifiedPointArray; var ACount: Integer;
  AX, AZ, AAccumLen, ATurn: Single; AClass: TPolylinePointClass);
begin
  if ACount >= Length(AOut) then
    SetLength(AOut, Length(AOut) * 2);
  AOut[ACount].X := AX;
  AOut[ACount].Z := AZ;
  AOut[ACount].AccumLen := AAccumLen;
  AOut[ACount].TurnRad := ATurn;
  AOut[ACount].PointClass := AClass;
  Inc(ACount);
end;

function SignedTurnAngle(Dx1, Dz1, Dx2, Dz2: Single): Single;
{ Both inputs are unit vectors. Returns signed angle from in to out
  in radians: positive = CCW (left turn), negative = CW (right). }
var
  Dot, CrossZ, AngleAbs: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(294);{$ENDIF}
  Dot := Dx1 * Dx2 + Dz1 * Dz2;
  if Dot >  1.0 then Dot :=  1.0;
  if Dot < -1.0 then Dot := -1.0;
  AngleAbs := ArcCos(Dot);
  CrossZ := Dx1 * Dz2 - Dz1 * Dx2;
  if CrossZ < 0 then
    Result := -AngleAbs
  else
    Result := AngleAbs;
end;

procedure ClassifyPolyline(const Center: TRibbonVertexArray;
  out Classified: TClassifiedPointArray);
var
  N, I: Integer;
  Closed: Boolean;

  { Signed turn at ACur between edges APrev->ACur and ACur->ANext;
    0 when either edge is degenerate. }
  function TurnAt(APrev, ACur, ANext: Integer): Single;
  var
    Dx1, Dz1, Dx2, Dz2, Len1, Len2: Single;
  begin
    Result := 0;
    Dx1 := Center[ACur].X - Center[APrev].X;
    Dz1 := Center[ACur].Z - Center[APrev].Z;
    Len1 := Sqrt(Dx1 * Dx1 + Dz1 * Dz1);
    if Len1 < 1e-6 then Exit;
    Dx2 := Center[ANext].X - Center[ACur].X;
    Dz2 := Center[ANext].Z - Center[ACur].Z;
    Len2 := Sqrt(Dx2 * Dx2 + Dz2 * Dz2);
    if Len2 < 1e-6 then Exit;
    Result := SignedTurnAngle(Dx1 / Len1, Dz1 / Len1, Dx2 / Len2, Dz2 / Len2);
  end;

  procedure ClassByAngle(var P: TClassifiedPoint);
  var
    AbsAngle: Single;
  begin
    AbsAngle := Abs(P.TurnRad);
    if AbsAngle < CLASS_STRAIGHT_RAD then
      P.PointClass := ppcStraight
    else if AbsAngle >= CLASS_HAIRPIN_RAD then
      P.PointClass := ppcHairpin
    else if AbsAngle >= CLASS_SMOOTH_RAD then
      P.PointClass := ppcSharpCorner
    else
      P.PointClass := ppcSmoothCurve;
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(296);{$ENDIF}
  N := Length(Center);
  SetLength(Classified, N);

  for I := 0 to N - 1 do
  begin
    Classified[I].X := Center[I].X;
    Classified[I].Z := Center[I].Z;
    Classified[I].AccumLen := Center[I].AccumLen;
    Classified[I].TurnRad := 0;
    Classified[I].PointClass := ppcStraight;
  end;
  if N < 3 then Exit;

  for I := 1 to N - 2 do
  begin
    Classified[I].TurnRad := TurnAt(I - 1, I, I + 1);
    ClassByAngle(Classified[I]);
  end;

  { Closed polyline (roundabout, closed service loop): the seam vertex P0 = PN-1 turns too. The
    incoming edge is P[N-2] -> P[N-1] (= P0), the outgoing one is P0 -> P1; both copies get the
    turn so the per-edge criterion in SubdivideSmoothRuns fires on both seam edges. }
  Closed := (N >= 4) and
    (Sqr(Center[0].X - Center[N - 1].X) +
     Sqr(Center[0].Z - Center[N - 1].Z) < 1e-8);
  if Closed then
  begin
    Classified[0].TurnRad := TurnAt(N - 2, 0, 1);
    ClassByAngle(Classified[0]);
    Classified[N - 1].TurnRad := Classified[0].TurnRad;
    Classified[N - 1].PointClass := Classified[0].PointClass;
  end;
end;

procedure PrepareCorners(const Pts: TClassifiedPointArray;
  HalfWidth: Single;
  out Expanded: TClassifiedPointArray;
  var Stats: TPolylineStats);
var
  Filleted: TClassifiedPointArray;

  { Pass 1: replace every sharp/hairpin node with an inscribed tangent arc, cut INWARD. The node
    itself is removed; the arc is tangent to both adjacent segments, so it never leaves the wedge
    and never expands the ribbon outward. Directions and edge budgets are taken from the ORIGINAL
    points, so two neighbouring corners cap against the same shared edge (FILLET_EDGE_FRAC each)
    and their arcs can never overlap. Seam corners of a closed polyline are not arc-filleted (the
    arc would have to span the seam); sharp seams fall back with TurnRad zeroed, gentle seams keep
    their turn for the Catmull-Rom wrap in SubdivideSmoothRuns. }
  procedure FilletPass;
  var
    N, J, K, Steps: Integer;
    Out_: TClassifiedPointArray;
    OutCount: Integer;
    D1x, D1z, D2x, D2z, L1, L2: Single;
    Theta, TanHalf, LMax, L, R, RMin: Single;
    Sgn: Single;
    T1x, T1z, N1x, N1z, ArcCx, ArcCz, Phi1, DPhi, Phi: Single;
    ALen, SeamTurn: Single;

    procedure Push(AX, AZ, AAccumLen, ATurn: Single; AClass: TPolylinePointClass);
    begin
      PushClassifiedPoint(Out_, OutCount, AX, AZ, AAccumLen, ATurn, AClass);
    end;

  begin
    N := Length(Pts);
    if N < 3 then
    begin
      Filleted := Copy(Pts, 0, N);
      Exit;
    end;
    SetLength(Out_, N * 4 + 32);
    OutCount := 0;

    SeamTurn := Pts[0].TurnRad;
    if Pts[0].PointClass in [ppcSharpCorner, ppcHairpin] then SeamTurn := 0;
    Push(Pts[0].X, Pts[0].Z, Pts[0].AccumLen, SeamTurn, Pts[0].PointClass);

    for J := 1 to N - 2 do
    begin
      if not (Pts[J].PointClass in [ppcSharpCorner, ppcHairpin]) then
      begin
        Push(Pts[J].X, Pts[J].Z, Pts[J].AccumLen, Pts[J].TurnRad, Pts[J].PointClass);
        Continue;
      end;

      D1x := Pts[J].X - Pts[J - 1].X;
      D1z := Pts[J].Z - Pts[J - 1].Z;
      L1 := Sqrt(D1x * D1x + D1z * D1z);
      D2x := Pts[J + 1].X - Pts[J].X;
      D2z := Pts[J + 1].Z - Pts[J].Z;
      L2 := Sqrt(D2x * D2x + D2z * D2z);
      Theta := Abs(Pts[J].TurnRad);

      { Degenerate edge or near-reversal (tan(Theta/2) blows up): leave the corner to the
        bevel/round joints, but zero the turn so no spline runs through it. }
      if (L1 < 1e-6) or (L2 < 1e-6) or (Theta >= Pi - 0.02) then
      begin
        Push(Pts[J].X, Pts[J].Z, Pts[J].AccumLen, 0, Pts[J].PointClass);
        Continue;
      end;

      D1x := D1x / L1; D1z := D1z / L1;
      D2x := D2x / L2; D2z := D2z / L2;

      if Pts[J].PointClass = ppcHairpin then
        R := FILLET_RADIUS_HAIRPIN_M
      else
        R := FILLET_RADIUS_SHARP_M;
      RMin := HalfWidth * FILLET_MIN_RADIUS_FACTOR;
      if R < RMin then R := RMin;

      TanHalf := Tan(Theta * 0.5);
      L := R * TanHalf;
      LMax := FILLET_EDGE_FRAC * Min(L1, L2);
      if L > LMax then
      begin
        L := LMax;
        R := L / TanHalf;
      end;

      if (R < RMin) or (L < SHOULDER_MIN_LEN_M * 0.5) then
      begin
        { No room for a safe radius — the inner ribbon edge would fold. Keep the corner verbatim
          with TurnRad zeroed: BuildRibbonEdges resolves it with the classic bevel/round joint. }
        Push(Pts[J].X, Pts[J].Z, Pts[J].AccumLen, 0, Pts[J].PointClass);
        Continue;
      end;

      { Arc centre sits at distance R from both segments, reached from the entry tangent point T1
        along the inner normal. SignedTurnAngle is positive for a left (CCW) turn; the Left perp
        of direction (dx,dz) is (-dz,dx) — same convention as BuildRibbonEdges. }
      if Pts[J].TurnRad >= 0 then Sgn := 1.0 else Sgn := -1.0;
      T1x := Pts[J].X - D1x * L;
      T1z := Pts[J].Z - D1z * L;
      N1x := Sgn * (-D1z);
      N1z := Sgn * ( D1x);
      ArcCx := T1x + N1x * R;
      ArcCz := T1z + N1z * R;
      Phi1 := ArcTan2(T1z - ArcCz, T1x - ArcCx);
      DPhi := Sgn * Theta;

      Steps := Round(Theta / FILLET_MAX_STEP_RAD);
      if Steps < 2 then Steps := 2;
      if Steps > 16 then Steps := 16;

      ALen := Pts[J].AccumLen - L;
      for K := 0 to Steps do
      begin
        Phi := Phi1 + DPhi * (K / Steps);
        Push(ArcCx + Cos(Phi) * R, ArcCz + Sin(Phi) * R,
             ALen + R * Theta * (K / Steps), 0, ppcStraight);
      end;
      Inc(Stats.Filleted);
    end;

    SeamTurn := Pts[N - 1].TurnRad;
    if Pts[N - 1].PointClass in [ppcSharpCorner, ppcHairpin] then SeamTurn := 0;
    Push(Pts[N - 1].X, Pts[N - 1].Z, Pts[N - 1].AccumLen, SeamTurn, Pts[N - 1].PointClass);

    SetLength(Out_, OutCount);
    Filleted := Out_;
  end;

  { Pass 2: collinear shoulders around the surviving GENTLE bends (see SHOULDER_* above). The
    shoulders lie exactly on the original segments and are classified Straight, so they double as
    clean Catmull-Rom boundary controls: the spline enters the bend zone tangent to the untouched
    straight. Edges shorter than La + Lb + SHOULDER_MIN_LEN_M pass through unchanged. }
  procedure ShoulderPass;
  var
    N, J: Integer;
    Out_: TClassifiedPointArray;
    OutCount: Integer;
    Ex, Ez, ELen, InvLen, La, Lb: Single;

    function ShoulderLen(const P: TClassifiedPoint): Single;
    begin
      if P.PointClass = ppcSmoothCurve then
        Result := SHOULDER_GENTLE_M
      else
        Result := 0;
    end;

    procedure Push(AX, AZ, AAccumLen, ATurn: Single; AClass: TPolylinePointClass);
    begin
      PushClassifiedPoint(Out_, OutCount, AX, AZ, AAccumLen, ATurn, AClass);
    end;

  begin
    N := Length(Filleted);
    if N < 3 then
    begin
      Expanded := Copy(Filleted, 0, N);
      Exit;
    end;

    { Worst case is N + 2*(N-1) points, so the initial capacity never grows. }
    SetLength(Out_, N * 3 + 8);
    OutCount := 0;
    Push(Filleted[0].X, Filleted[0].Z, Filleted[0].AccumLen,
         Filleted[0].TurnRad, Filleted[0].PointClass);

    for J := 0 to N - 2 do
    begin
      Ex := Filleted[J + 1].X - Filleted[J].X;
      Ez := Filleted[J + 1].Z - Filleted[J].Z;
      ELen := Sqrt(Ex * Ex + Ez * Ez);
      if ELen > 1e-6 then
      begin
        La := ShoulderLen(Filleted[J]);       { shoulder AFTER the bend at J    }
        Lb := ShoulderLen(Filleted[J + 1]);   { shoulder BEFORE the bend at J+1 }
        if (La + Lb > 0) and (La + Lb + SHOULDER_MIN_LEN_M <= ELen) then
        begin
          InvLen := 1.0 / ELen;
          if La > 0 then
          begin
            Push(Filleted[J].X + Ex * InvLen * La, Filleted[J].Z + Ez * InvLen * La,
                 Filleted[J].AccumLen + La, 0, ppcStraight);
            Inc(Stats.ShoulderPts);
          end;
          if Lb > 0 then
          begin
            Push(Filleted[J + 1].X - Ex * InvLen * Lb, Filleted[J + 1].Z - Ez * InvLen * Lb,
                 Filleted[J + 1].AccumLen - Lb, 0, ppcStraight);
            Inc(Stats.ShoulderPts);
          end;
        end;
      end;
      Push(Filleted[J + 1].X, Filleted[J + 1].Z, Filleted[J + 1].AccumLen,
           Filleted[J + 1].TurnRad, Filleted[J + 1].PointClass);
    end;

    SetLength(Out_, OutCount);
    Expanded := Out_;
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(295);{$ENDIF}
  FilletPass;
  ShoulderPass;
end;

procedure CentripetalCatmullRom(
  P0x, P0z, P1x, P1z, P2x, P2z, P3x, P3z, T: Single;
  out OutX, OutZ: Single);
{ Barry-Goldman pyramidal evaluation. α = 0.5 (centripetal) — knot
  spacing = sqrt(chord length), which prevents loops and cusps on
  unevenly spaced controls. T is the spline parameter in [0, 1] on
  the P1→P2 segment. }
var
  T0, T1, T2, T3, U: Single;
  A1x, A1z, A2x, A2z, A3x, A3z: Single;
  B1x, B1z, B2x, B2z: Single;

  function KnotStep(Pax, Paz, Pbx, Pbz, Ta: Single): Single;
  var
    Dx, Dz, D2: Single;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(298);{$ENDIF}
    Dx := Pbx - Pax;
    Dz := Pbz - Paz;
    D2 := Dx * Dx + Dz * Dz;
    if D2 < 1e-12 then
      Result := Ta + 1e-6           { degenerate guard }
    else
      Result := Ta + Power(D2, 0.25);   { α=0.5 → t = sqrt(distance) }
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(297);{$ENDIF}
  T0 := 0;
  T1 := KnotStep(P0x, P0z, P1x, P1z, T0);
  T2 := KnotStep(P1x, P1z, P2x, P2z, T1);
  T3 := KnotStep(P2x, P2z, P3x, P3z, T2);

  U := T1 + T * (T2 - T1);

  { Three lerp's along knot intervals }
  A1x := (T1 - U) / (T1 - T0) * P0x + (U - T0) / (T1 - T0) * P1x;
  A1z := (T1 - U) / (T1 - T0) * P0z + (U - T0) / (T1 - T0) * P1z;
  A2x := (T2 - U) / (T2 - T1) * P1x + (U - T1) / (T2 - T1) * P2x;
  A2z := (T2 - U) / (T2 - T1) * P1z + (U - T1) / (T2 - T1) * P2z;
  A3x := (T3 - U) / (T3 - T2) * P2x + (U - T2) / (T3 - T2) * P3x;
  A3z := (T3 - U) / (T3 - T2) * P2z + (U - T2) / (T3 - T2) * P3z;

  B1x := (T2 - U) / (T2 - T0) * A1x + (U - T0) / (T2 - T0) * A2x;
  B1z := (T2 - U) / (T2 - T0) * A1z + (U - T0) / (T2 - T0) * A2z;
  B2x := (T3 - U) / (T3 - T1) * A2x + (U - T1) / (T3 - T1) * A3x;
  B2z := (T3 - U) / (T3 - T1) * A2z + (U - T1) / (T3 - T1) * A3z;

  OutX := (T2 - U) / (T2 - T1) * B1x + (U - T1) / (T2 - T1) * B2x;
  OutZ := (T2 - U) / (T2 - T1) * B1z + (U - T1) / (T2 - T1) * B2z;
end;

procedure SubdivideSmoothRuns(const Classified: TClassifiedPointArray;
  out Smoothed: TRibbonVertexArray;
  var Stats: TPolylineStats;
  MaxChordErrorM: Single;
  MinSegmentLenM: Single;
  MaxSubdivisionsPerEdge: Integer);
var
  N, I, J: Integer;
  P0x, P0z, P1x, P1z, P2x, P2z, P3x, P3z: Single;
  Px, Pz: Single;
  EdgeLen: Single;
  Steps: Integer;
  T: Single;
  Out_: TRibbonVertexArray;
  OutCount, OutCap: Integer;
  Closed: Boolean;

  procedure AddPoint(X, Z: Single);
  var
    Dx, Dz: Single;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(300);{$ENDIF}
    if OutCount >= OutCap then
    begin
      OutCap := OutCap * 2;
      SetLength(Out_, OutCap);
    end;
    Out_[OutCount].X := X;
    Out_[OutCount].Z := Z;
    if OutCount = 0 then
      Out_[OutCount].AccumLen := 0
    else
    begin
      Dx := X - Out_[OutCount - 1].X;
      Dz := Z - Out_[OutCount - 1].Z;
      Out_[OutCount].AccumLen :=
        Out_[OutCount - 1].AccumLen + Sqrt(Dx * Dx + Dz * Dz);
    end;
    Inc(OutCount);
  end;

  { An edge is splined when either endpoint bends noticeably. A node forced
    to ppcStraight by the NoFillet mask (junction/intersection) keeps its
    raw TurnRad — PointClass must veto the spline here too, otherwise
    Catmull-Rom still smooths the junction the mask was meant to keep
    sharp (hard mitre, matching the neighbouring ribbons). }
  function BendAt(Idx: Integer): Boolean;
  begin
    Result := (Classified[Idx].PointClass <> ppcStraight) and
              (Abs(Classified[Idx].TurnRad) >= CLASS_STRAIGHT_RAD);
  end;

  { Add intermediate samples on edge J->J+1 (endpoints are the caller's).
    Backward-overshoot guard: every sample must advance along the P1->P2 chord; if any goes
    backward (uneven spacing -> twist), abort this edge and fall back to a linear chord. }
  procedure SubdivideEdge(J: Integer);
  var
    LocalK: Integer;
    ChordX, ChordZ, ChordLen2, ChordLen: Single;
    PrevProj, ThisProj, ThisPerp: Single;
    Buf: array[0..32] of record X, Z: Single; end;
    BufCount: Integer;
    K2: Integer;
    BackwardSeen: Boolean;
    TurnSum: Single;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(301);{$ENDIF}
    { Control points clamp at open ends and wrap across the seam of a CLOSED polyline: the seam
      duplicate PN-1 = P0 is skipped, the true neighbours are P[N-2] and P[1]. }
    if Closed and (J = 0) then
    begin
      P0x := Classified[N - 2].X;
      P0z := Classified[N - 2].Z;
    end
    else
    begin
      P0x := Classified[Max(0, J - 1)].X;
      P0z := Classified[Max(0, J - 1)].Z;
    end;
    P1x := Classified[J].X;
    P1z := Classified[J].Z;
    P2x := Classified[J + 1].X;
    P2z := Classified[J + 1].Z;
    if Closed and (J = N - 2) then
    begin
      P3x := Classified[1].X;
      P3z := Classified[1].Z;
    end
    else
    begin
      P3x := Classified[Min(N - 1, J + 2)].X;
      P3z := Classified[Min(N - 1, J + 2)].Z;
    end;

    { Вырожденные контрольные точки: совпавший сосед (дубль узла после
      фаски/обочины) НЕ делит на ноль в KnotStep (там заглушка 1e-6), но
      ВЗРЫВАЕТ оценку сплайна — коэффициенты ~(U-T1)/1e-6 раздувают
      вершину на сотни метров вбок («лоскут через реку»). Стандартное
      лечение — отражение: недостающий контроль достраивается зеркально
      через ближний конец хорды, кривизна остаётся осмысленной. }
    if Sqr(P1x - P0x) + Sqr(P1z - P0z) < 1e-6 then
    begin
      P0x := P1x + (P1x - P2x);
      P0z := P1z + (P1z - P2z);
    end;
    if Sqr(P3x - P2x) + Sqr(P3z - P2z) < 1e-6 then
    begin
      P3x := P2x + (P2x - P1x);
      P3z := P2z + (P2z - P1z);
    end;

    EdgeLen := Sqrt(Sqr(P2x - P1x) + Sqr(P2z - P1z));
    Steps := Max(2, Round(EdgeLen / MinSegmentLenM));
    if Steps > MaxSubdivisionsPerEdge then Steps := MaxSubdivisionsPerEdge;
    if Steps > High(Buf) then Steps := High(Buf);   { fit into local buffer }

    { Adaptive density ladder: the sharper the combined turn at the edge ends, the more samples —
      a hairpin apex must not read as a chain of visible chords. Heuristic only. }
    TurnSum := Abs(Classified[J].TurnRad) + Abs(Classified[J + 1].TurnRad);
    if (TurnSum > 2.2) and (Steps < 8) then
      Steps := 8
    else if (TurnSum > 1.4) and (Steps < 6) then
      Steps := 6
    else if (TurnSum > 0.7) and (Steps < 4) then
      Steps := 4;

    if MaxChordErrorM > 0 then
      { Reserved for true chord-error refinement; current step heuristic
        is good enough for typical OSM density. };

    { Generate samples into a local buffer first, then validate against
      backward-projection before flushing to output. This way we can
      reject the whole subdivision atomically if any sample goes
      backward (loop / cusp indicator). }
    ChordX := P2x - P1x;
    ChordZ := P2z - P1z;
    ChordLen2 := ChordX * ChordX + ChordZ * ChordZ;
    if ChordLen2 < 1e-12 then Exit;   { degenerate, skip }

    BufCount := 0;
    for LocalK := 1 to Steps - 1 do
    begin
      T := LocalK / Steps;
      CentripetalCatmullRom(P0x, P0z, P1x, P1z, P2x, P2z, P3x, P3z, T,
        Px, Pz);
      Buf[BufCount].X := Px;
      Buf[BufCount].Z := Pz;
      Inc(BufCount);
    end;

    { Validate: every consecutive pair (and from P1 to first, from last
      to P2) must have positive chord-projection delta — i.e., monotonic
      advance toward P2. Tolerance allows a tiny backward sliver for
      numerical noise. }
    BackwardSeen := False;
    PrevProj := 0;
    ChordLen := Sqrt(ChordLen2);
    for K2 := 0 to BufCount - 1 do
    begin
      ThisProj := ((Buf[K2].X - P1x) * ChordX + (Buf[K2].Z - P1z) * ChordZ)
                  / ChordLen2;
      if ThisProj < PrevProj - CR_BACKWARD_TOLERANCE then
      begin
        BackwardSeen := True;
        Break;
      end;
      if ThisProj > 1 + CR_BACKWARD_TOLERANCE then
      begin
        BackwardSeen := True;
        Break;
      end;
      { ПОПЕРЕЧНЫЙ лимит: продольная проверка выше пропускает кривую,
        улетевшую вбок на сотни метров (взрыв сплайна двигается вдоль
        хорды монотонно!). Честная гладкая дуга между узлами отклоняется
        от хорды меньше её длины; всё дальше — патология, откат к хорде. }
      ThisPerp := Abs((Buf[K2].X - P1x) * ChordZ - (Buf[K2].Z - P1z) * ChordX)
                  / ChordLen;
      if ThisPerp > ChordLen * CR_MAX_PERP_FRAC + CR_MAX_PERP_SLACK_M then
      begin
        BackwardSeen := True;
        Break;
      end;
      PrevProj := ThisProj;
    end;

    if BackwardSeen then Exit;     { fall back to linear chord }

    for K2 := 0 to BufCount - 1 do
    begin
      AddPoint(Buf[K2].X, Buf[K2].Z);
      Inc(Stats.Subdivided);
    end;
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(299);{$ENDIF}
  N := Length(Classified);
  if N < 2 then
  begin
    SetLength(Smoothed, N);
    for I := 0 to N - 1 do
    begin
      Smoothed[I].X := Classified[I].X;
      Smoothed[I].Z := Classified[I].Z;
      Smoothed[I].AccumLen := Classified[I].AccumLen;
    end;
    Exit;
  end;

  Stats.Total := N;
  Stats.Straight := 0; Stats.Smooth := 0;
  Stats.Sharp := 0;    Stats.Hairpin := 0;
  Stats.Subdivided := 0;
  for I := 0 to N - 1 do
    case Classified[I].PointClass of
      ppcStraight:    Inc(Stats.Straight);
      ppcSmoothCurve: Inc(Stats.Smooth);
      ppcSharpCorner: Inc(Stats.Sharp);
      ppcHairpin:     Inc(Stats.Hairpin);
    end;

  Closed := (N >= 4) and
    (Sqr(Classified[0].X - Classified[N - 1].X) +
     Sqr(Classified[0].Z - Classified[N - 1].Z) < 1e-8);

  OutCap := N * 2 + 16;
  SetLength(Out_, OutCap);
  OutCount := 0;

  { First point — always emit. }
  AddPoint(Classified[0].X, Classified[0].Z);

  { Per-edge criterion: any edge touching a bent node gets the spline, so a SINGLE bent node
    smooths both its edges; two neighbouring bends share their middle edge exactly once; pure
    straight stretches stay linear and cheap. }
  for J := 0 to N - 2 do
  begin
    if BendAt(J) or BendAt(J + 1) then
      SubdivideEdge(J);
    AddPoint(Classified[J + 1].X, Classified[J + 1].Z);
  end;

  SetLength(Out_, OutCount);
  Smoothed := Out_;
end;

procedure BuildRibbonEdges(const Center: TRibbonVertexArray;
  HalfWidth: Single;
  out Edges: TRibbonEdgePointArray;
  var Stats: TPolylineStats);
var
  N, I, K: Integer;
  Out_: TRibbonEdgePointArray;
  OutCount, OutCap: Integer;
  Dx1, Dz1, Dx2, Dz2, Len1, Len2: Single;
  PerpInX, PerpInZ, PerpOutX, PerpOutZ: Single;
  Dot, CrossZ, AngleAbs: Single;
  SumPerpX, SumPerpZ, Denom: Single;
  MitreVx, MitreVz, MitreLen: Single;
  RoundSteps: Integer;
  PhiIn, PhiOut, DeltaPhi, Phi: Single;
  Cx, Cz, ALen: Single;
  RX, RZ, LX, LZ: Single;
  AvgPerpX, AvgPerpZ: Single;

  procedure EmitEdgePoint(ARightX, ARightZ, ALeftX, ALeftZ, AccumLen: Single);
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(303);{$ENDIF}
    if OutCount >= OutCap then
    begin
      OutCap := OutCap * 2;
      SetLength(Out_, OutCap);
    end;
    Out_[OutCount].Right.X := ARightX;
    Out_[OutCount].Right.Z := ARightZ;
    Out_[OutCount].Left.X  := ALeftX;
    Out_[OutCount].Left.Z  := ALeftZ;
    Out_[OutCount].AccumLen := AccumLen;
    Inc(OutCount);
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(302);{$ENDIF}
  N := Length(Center);
  SetLength(Out_, 0);
  OutCount := 0;
  if (N < 2) or (HalfWidth <= 0) then
  begin
    Edges := nil;
    Stats.JointEdgesIn := N;
    Stats.JointEdgesOut := 0;
    Exit;
  end;
  OutCap := N + 8;
  SetLength(Out_, OutCap);

  { Endpoint 0: perpendicular of first edge. }
  Dx1 := Center[1].X - Center[0].X;
  Dz1 := Center[1].Z - Center[0].Z;
  Len1 := Sqrt(Dx1 * Dx1 + Dz1 * Dz1);
  if Len1 < 1e-9 then
  begin
    SetLength(Edges, 0);
    Stats.JointEdgesIn := N;
    Stats.JointEdgesOut := 0;
    Exit;
  end;
  Dx1 := Dx1 / Len1; Dz1 := Dz1 / Len1;
  PerpOutX := -Dz1; PerpOutZ := Dx1;
  Cx := Center[0].X; Cz := Center[0].Z; ALen := Center[0].AccumLen;
  EmitEdgePoint(
    Cx - PerpOutX * HalfWidth, Cz - PerpOutZ * HalfWidth,
    Cx + PerpOutX * HalfWidth, Cz + PerpOutZ * HalfWidth,
    ALen);

  { Interior points. }
  for I := 1 to N - 2 do
  begin
    Dx1 := Center[I].X - Center[I - 1].X;
    Dz1 := Center[I].Z - Center[I - 1].Z;
    Len1 := Sqrt(Dx1 * Dx1 + Dz1 * Dz1);
    Dx2 := Center[I + 1].X - Center[I].X;
    Dz2 := Center[I + 1].Z - Center[I].Z;
    Len2 := Sqrt(Dx2 * Dx2 + Dz2 * Dz2);

    Cx := Center[I].X; Cz := Center[I].Z; ALen := Center[I].AccumLen;

    if (Len1 < 1e-9) or (Len2 < 1e-9) then
    begin
      { Degenerate consecutive points; just emit a single perpendicular. }
      if Len2 > 1e-9 then
      begin
        Dx2 := Dx2 / Len2; Dz2 := Dz2 / Len2;
        PerpOutX := -Dz2; PerpOutZ := Dx2;
      end
      else if Len1 > 1e-9 then
      begin
        Dx1 := Dx1 / Len1; Dz1 := Dz1 / Len1;
        PerpOutX := -Dz1; PerpOutZ := Dx1;
      end
      else
        Continue;
      EmitEdgePoint(
        Cx - PerpOutX * HalfWidth, Cz - PerpOutZ * HalfWidth,
        Cx + PerpOutX * HalfWidth, Cz + PerpOutZ * HalfWidth,
        ALen);
      Continue;
    end;

    Dx1 := Dx1 / Len1; Dz1 := Dz1 / Len1;
    Dx2 := Dx2 / Len2; Dz2 := Dz2 / Len2;
    PerpInX  := -Dz1; PerpInZ  := Dx1;
    PerpOutX := -Dz2; PerpOutZ := Dx2;

    Dot := Dx1 * Dx2 + Dz1 * Dz2;
    if Dot >  1.0 then Dot :=  1.0;
    if Dot < -1.0 then Dot := -1.0;
    CrossZ := Dx1 * Dz2 - Dz1 * Dx2;
    AngleAbs := ArcCos(Dot);

    { Mitre: Q = P + halfW*(perp_in + perp_out)/(1 + d_in.d_out); |Q-P| = halfW/cos(angle/2). }
    SumPerpX := PerpInX + PerpOutX;
    SumPerpZ := PerpInZ + PerpOutZ;
    Denom := 1.0 + Dot;
    if Denom < 1e-6 then
    begin
      { Near-reversal — denominator → 0. Force round join with the
        outer arc explicitly computed below. Mitre length undefined. }
      MitreVx := 0; MitreVz := 0; MitreLen := 1e9;
    end
    else
    begin
      MitreVx := SumPerpX / Denom;
      MitreVz := SumPerpZ / Denom;
      MitreLen := Sqrt(MitreVx * MitreVx + MitreVz * MitreVz) * HalfWidth;
    end;

    { Segment-length safety: at acute angles the mitre extension (MitreLen*sin(angle/2)) can poke
      past the next centerline point ("loop"/"zigzag"); force-bevel when it exceeds 40% of the
      shorter adjacent segment. }
    if (MitreLen > HalfWidth * JOINT_MITRE_LIMIT) or
       (MitreLen * Sin(AngleAbs * 0.5) > 0.4 * Min(Len1, Len2)) then
      MitreLen := HalfWidth * (JOINT_MITRE_LIMIT + 1);   { force fallback below }

    if AngleAbs < JOINT_STRAIGHT_RAD then
    begin
      { Treat as straight. Use averaged perpendicular so endpoints of
        adjacent segments still coincide exactly. }
      AvgPerpX := (PerpInX + PerpOutX) * 0.5;
      AvgPerpZ := (PerpInZ + PerpOutZ) * 0.5;
      EmitEdgePoint(
        Cx - AvgPerpX * HalfWidth, Cz - AvgPerpZ * HalfWidth,
        Cx + AvgPerpX * HalfWidth, Cz + AvgPerpZ * HalfWidth,
        ALen);
    end
    else if (MitreLen <= HalfWidth * JOINT_MITRE_LIMIT) and
            (AngleAbs < JOINT_ROUND_RAD) then
    begin
      { Mitre join. UV continuous on both edges. }
      EmitEdgePoint(
        Cx - MitreVx * HalfWidth, Cz - MitreVz * HalfWidth,
        Cx + MitreVx * HalfWidth, Cz + MitreVz * HalfWidth,
        ALen);
    end
    else if AngleAbs < JOINT_ROUND_RAD then
    begin
      { Bevel join — two edge-points: inner keeps the mitre vertex, outer gets per-segment perp.
        CrossZ>0 (left turn): inner = Left; CrossZ<0 (right turn): inner = Right. }
      if CrossZ > 0 then
      begin
        { Left turn. Inner mitre on the Left side; Right side bevels. }
        EmitEdgePoint(
          Cx - PerpInX  * HalfWidth, Cz - PerpInZ  * HalfWidth,
          Cx + MitreVx  * HalfWidth, Cz + MitreVz  * HalfWidth,
          ALen);
        EmitEdgePoint(
          Cx - PerpOutX * HalfWidth, Cz - PerpOutZ * HalfWidth,
          Cx + MitreVx  * HalfWidth, Cz + MitreVz  * HalfWidth,
          ALen);
      end
      else
      begin
        { Right turn. Inner mitre on the Right; Left side bevels. }
        EmitEdgePoint(
          Cx - MitreVx  * HalfWidth, Cz - MitreVz  * HalfWidth,
          Cx + PerpInX  * HalfWidth, Cz + PerpInZ  * HalfWidth,
          ALen);
        EmitEdgePoint(
          Cx - MitreVx  * HalfWidth, Cz - MitreVz  * HalfWidth,
          Cx + PerpOutX * HalfWidth, Cz + PerpOutZ * HalfWidth,
          ALen);
      end;
    end
    else
    begin
      { Round join: outer arc sampled with slerp on perpendicular
        angle. Inner side shares mitre vertex (may be far from C on
        sharp turns; geometrically correct as long as adjacent
        segments are longer than the mitre extension). }
      if AngleAbs > 2.793 then
        RoundSteps := JOINT_ROUND_STEPS_EXTRA   { ≥ 160° }
      else
        RoundSteps := JOINT_ROUND_STEPS_BASE;

      if CrossZ > 0 then
      begin
        { Left turn — outer = Right side. Right perp = -perp. }
        PhiIn  := ArcTan2(-PerpInZ,  -PerpInX);
        PhiOut := ArcTan2(-PerpOutZ, -PerpOutX);
        DeltaPhi := PhiOut - PhiIn;
        while DeltaPhi >  Pi do DeltaPhi := DeltaPhi - 2 * Pi;
        while DeltaPhi < -Pi do DeltaPhi := DeltaPhi + 2 * Pi;
        for K := 0 to RoundSteps do
        begin
          Phi := PhiIn + (K / RoundSteps) * DeltaPhi;
          RX := Cx + Cos(Phi) * HalfWidth;
          RZ := Cz + Sin(Phi) * HalfWidth;
          { Inner side is the mitre vertex; if mitre is degenerate
            (near-reversal) fall back to centerline. }
          if MitreLen > HalfWidth * 4 then
          begin
            LX := Cx + PerpInX * HalfWidth;
            LZ := Cz + PerpInZ * HalfWidth;
          end
          else
          begin
            LX := Cx + MitreVx * HalfWidth;
            LZ := Cz + MitreVz * HalfWidth;
          end;
          EmitEdgePoint(RX, RZ, LX, LZ, ALen);
        end;
      end
      else
      begin
        { Right turn — outer = Left side. Left perp = +perp. }
        PhiIn  := ArcTan2(PerpInZ,  PerpInX);
        PhiOut := ArcTan2(PerpOutZ, PerpOutX);
        DeltaPhi := PhiOut - PhiIn;
        while DeltaPhi >  Pi do DeltaPhi := DeltaPhi - 2 * Pi;
        while DeltaPhi < -Pi do DeltaPhi := DeltaPhi + 2 * Pi;
        for K := 0 to RoundSteps do
        begin
          Phi := PhiIn + (K / RoundSteps) * DeltaPhi;
          LX := Cx + Cos(Phi) * HalfWidth;
          LZ := Cz + Sin(Phi) * HalfWidth;
          if MitreLen > HalfWidth * 4 then
          begin
            RX := Cx - PerpInX * HalfWidth;
            RZ := Cz - PerpInZ * HalfWidth;
          end
          else
          begin
            RX := Cx - MitreVx * HalfWidth;
            RZ := Cz - MitreVz * HalfWidth;
          end;
          EmitEdgePoint(RX, RZ, LX, LZ, ALen);
        end;
      end;
    end;
  end;

  { Endpoint N-1: perpendicular of last edge. }
  Dx1 := Center[N - 1].X - Center[N - 2].X;
  Dz1 := Center[N - 1].Z - Center[N - 2].Z;
  Len1 := Sqrt(Dx1 * Dx1 + Dz1 * Dz1);
  if Len1 >= 1e-9 then
  begin
    Dx1 := Dx1 / Len1; Dz1 := Dz1 / Len1;
    PerpInX := -Dz1; PerpInZ := Dx1;
    Cx := Center[N - 1].X; Cz := Center[N - 1].Z; ALen := Center[N - 1].AccumLen;
    EmitEdgePoint(
      Cx - PerpInX * HalfWidth, Cz - PerpInZ * HalfWidth,
      Cx + PerpInX * HalfWidth, Cz + PerpInZ * HalfWidth,
      ALen);
  end;

  SetLength(Out_, OutCount);
  Edges := Out_;
  Stats.JointEdgesIn := N;
  Stats.JointEdgesOut := OutCount;
end;

procedure BuildSmoothRibbonEdges(const Center: TRibbonVertexArray;
  HalfWidth: Single;
  out Edges: TRibbonEdgePointArray;
  out Stats: TPolylineStats;
  MaxChordErrorM: Single;
  const ANoFillet: TBoolArray);
var
  Classified: TClassifiedPointArray;
  Shouldered: TClassifiedPointArray;
  Smoothed: TRibbonVertexArray;
  NFi: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(304);{$ENDIF}

  FillChar(Stats, SizeOf(Stats), 0);

  ClassifyPolyline(Center, Classified);
  { Узлы-развязки (пересечения, Т-контакты) НЕ скругляются: дуга/сглаживание
    тянет центрлайн внутрь угла и разъезжается с лентами других дорог в том
    же узле. ppcStraight = «emit as-is» — жёсткая митра по бисектрисе. }
  if ANoFillet <> nil then
    for NFi := 0 to High(Classified) do
      if (NFi <= High(ANoFillet)) and ANoFillet[NFi] then
        Classified[NFi].PointClass := ppcStraight;
  PrepareCorners(Classified, HalfWidth, Shouldered, Stats);
  SubdivideSmoothRuns(Shouldered, Smoothed, Stats, MaxChordErrorM);
  { Smoothed.AccumLen is fresh per the new sample density. }
  BuildRibbonEdges(Smoothed, HalfWidth, Edges, Stats);
end;

end.
