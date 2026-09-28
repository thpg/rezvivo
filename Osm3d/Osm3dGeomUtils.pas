unit Osm3dGeomUtils;

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$codepage UTF8}
{$WARN 5091 OFF}    { FPC false-positives on managed types zeroed by runtime }
{$WARN 5093 OFF}

interface

uses
  Classes,
  SysUtils,
  Math,
  CastleVectors,
  Osm3dGeoMath,
  Osm3dOsmData,
  X3DNodes
  {$IFDEF TEX_SIZE_PROFILE}, Osm3dTexProfile{$ENDIF}
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
;

type
  TOMBBPoint = TXZ;
  TOMBBPointArray = TXZArray;

  { 4 OMBB corners. Semantics:
      [0] = TL  (BestMinX, BestMaxZ) in the rotated system
      [1] = BL  (BestMinX, BestMinZ)  ← origin
      [2] = BR  (BestMaxX, BestMinZ)  ← BL + rotVec0 (along one OMBB axis)
      [3] = TR  (BestMaxX, BestMaxZ)  ← BL + rotVec0 + rotVec1
    Matches the order from streets-gl OMBB.js. }
  TOMBBCorners = array[0..3] of TOMBBPoint;

  TOMBB = class
  public
    class function ConvexHull(const Pts: TOMBBPointArray): TOMBBPointArray;
    class function ComputeFromHull(const Hull: TOMBBPointArray): TOMBBCorners;
    class function Compute(const Pts: TOMBBPointArray): TOMBBCorners;
  end;

type
  TIntArray    = array of Integer;
  TDoubleArray = array of Double;

  TEarcutTriangulator = class
  public

    class function Triangulate(const Data: array of Double;
      const HoleIndices: array of Integer; Dim: Integer): TIntArray; overload;
    class function Triangulate(const Data: array of Double;
      Dim: Integer = 2): TIntArray; overload;

  end;

{ Triangulation (simple ear-clipping in TVector3) }

type
  TIndexArray = array of Integer;

  TPolygonTriangulator = class
  public
    { Triangulates a simple polygon in the XZ plane.
      Polygon — N≥3 vertices in any winding order (CW or CCW).
      Returns an array of length 3*(N-2): triangle index triplets.
      Empty array on error (degenerate polygon). }
    class function TriangulateXZ(const Polygon: array of TVector3): TIndexArray;

    { True if P is strictly inside triangle (A, B, C) in the XZ plane
      (boundary not included). }
    class function PointInTriangleXZ(const A, B, C, P: TVector3): Boolean;

    { True if point P is inside or on the boundary of an arbitrary
      simple polygon. Algorithm: ray-casting along +X. O(N). }
    class function PointInPolygonXZ(const P: TVector3;
      const Polygon: array of TVector3): Boolean;
  end;

type
  TInt64Array          = array of Int64;
  TInt64ArrayArray     = array of TInt64Array;
  TPolygonRingArray    = array of TPolygonRing;
  TMultipolygonArray   = array of TPolygonMultipolygon;
  TOSMWayArray         = array of TOSMWay;

function ExtractNodeRefs(Way: TOSMWay): TInt64Array;

procedure ReverseRefs(var Refs: TInt64Array);

function BuildRingFromNodeChain(const Chain: TInt64Array;
  Dataset: TOSMDataset; Projection: TLocalProjection): TPolygonRing;

function RingFromWay(Way: TOSMWay; Dataset: TOSMDataset;
  Projection: TLocalProjection): TPolygonRing;

function StitchWaysIntoRings(const Ways: array of TOSMWay;
  Dataset: TOSMDataset; Projection: TLocalProjection): TPolygonRingArray;

{ Same endpoint-matching walk as StitchWaysIntoRings, but returns the raw
  CLOSED node-ref chains (Chain[0] = Chain[High], length >= 4) instead of
  projected rings — one per outer/independent ring. Lets a caller synthesise
  a closed TOSMWay from each ring and reuse a way-based builder (e.g. the
  building extruder, which is footprint/node-ref driven). Chains that never
  close, or resolve to < 3 distinct nodes, are dropped. No projection and no
  Dataset needed — pure node-ref topology. }
function StitchWaysIntoRingChains(
  const Ways: array of TOSMWay): TInt64ArrayArray;

procedure SplitRelationByRole(Rel: TOSMRelation; Dataset: TOSMDataset;
  var OuterWays, InnerWays: TOSMWayArray;
  out OuterCount, InnerCount: Integer);

{ One owner index per inner ring; -1 when its outer is absent. Shared by
  surface/vegetation geometry and building courtyards. }
function AssignInnerRingsToOuters(const OuterRings,
  InnerRings: TPolygonRingArray): TIntArray;

function BuildMultipolygonsFromRelation(Rel: TOSMRelation;
  Dataset: TOSMDataset; Projection: TLocalProjection): TMultipolygonArray;

function BuildMultipolygonFromWay(Way: TOSMWay; Dataset: TOSMDataset;
  Projection: TLocalProjection): TPolygonMultipolygon;

procedure MultipolygonBBox(const MP: TPolygonMultipolygon;
  out MinX, MaxX, MinZ, MaxZ: Single);

{ Splits a multipolygon into a grid of TileSizeM × TileSizeM squares.
  Each non-empty clipped piece is a separate result element.
  Returns a single-element array containing the original MP when its
  bbox is ≤ TileSizeM in both axes. }
function SplitMultipolygonIntoTiles(const MP: TPolygonMultipolygon;
  TileSizeM: Double = 100.0): TMultipolygonArray;

type
  TSurfaceUVOrientation = (suoAlong, suoAcross);

  { Affine UV transform XZ → UV (before dividing by UVScale).
    Applied as:
      d = (V - origin)
      r = R(angle) * d           ← rotation
      r.x *= scaleX; r.y *= scaleY  ← optional stretch
      uv.x = r.x;  uv.y = (FlipY ? -r.y : r.y)
      uv /= UVScale  ← done by the clipper

    If Active=False, the clipper falls back to default planar UV
    (V.X * InvUV, V.Z * InvUV). }
  TUVTransform = record
    Active:       Boolean;
    OriginX:      Double;
    OriginZ:      Double;
    CosA:         Double;
    SinA:         Double;
    ScaleX:       Double;     { 1 if no stretch }
    ScaleY:       Double;
    FlipY:        Boolean;
  end;

function NoUVTransform: TUVTransform;

function BuildOrientedUVTransform(
  const MP: TPolygonMultipolygon;
  Orientation: TSurfaceUVOrientation;
  Stretch: Boolean): TUVTransform;

procedure ApplyUVTransform(const Tx: TUVTransform; X, Z: Double;
  out U, V: Double); inline;

{ Surface texture descriptors (legacy per-surface path) }

type
  TSurfaceKindIndex = Integer;

  TSurfaceDescriptor = record
    Name:        string;
    TexturePath: string;       { '' = no texture, use colour only }
    NormalPath:  string;       { '' = no normal map }
    UVScale:     Single;       { metres per repeat; <=0 = no UV }

    IsOriented:  Boolean;      { rotate UV along the polygon major axis }
    Stretch:     Boolean;      { normalise UV to OMBB side lengths }
    Orientation: TSurfaceUVOrientation;
  end;

  TSurfaceTextures = class
  public
    class function GetDescriptor(KindIdx: TSurfaceKindIndex): TSurfaceDescriptor;

    class function CreateImageTexture(const TexturePath: string;
      RepeatST: Boolean = True): TImageTextureNode;

    class function CreateForKind(KindIdx: TSurfaceKindIndex): TImageTextureNode;
    class function CreateNormalForKind(KindIdx: TSurfaceKindIndex): TImageTextureNode;
  end;

const
  SURFACE_KIND_COUNT = 25;

  SURF_DIR = SURFACES_TEX_DIR;   { alias used by SURFACE_DESCRIPTORS below }

  SURFACE_DESCRIPTORS: array[0..SURFACE_KIND_COUNT - 1] of TSurfaceDescriptor = (
    (Name:'none';            TexturePath:'';
     NormalPath:''; UVScale: 0;
     IsOriented:False; Stretch:False; Orientation:suoAlong),

    (Name:'forest';          TexturePath:'';
     NormalPath:''; UVScale: 0;
     IsOriented:False; Stretch:False; Orientation:suoAlong),

    (Name:'grass';           TexturePath:SURF_DIR+'grass_diffuse.png';
     NormalPath:SURF_DIR+'grass_normal.png'; UVScale: 25;
     IsOriented:False; Stretch:False; Orientation:suoAlong),

    (Name:'water';           TexturePath:'';
     NormalPath:''; UVScale: 0;
     IsOriented:False; Stretch:False; Orientation:suoAlong),

    (Name:'sand';            TexturePath:SURF_DIR+'sand_diffuse.png';
     NormalPath:SURF_DIR+'sand_normal.png'; UVScale: 12;
     IsOriented:False; Stretch:False; Orientation:suoAlong),

    (Name:'parking';         TexturePath:'';
     NormalPath:''; UVScale: 20;
     IsOriented:False; Stretch:False; Orientation:suoAlong),

    (Name:'construction';    TexturePath:SURF_DIR+'soil_diffuse.png';
     NormalPath:SURF_DIR+'soil_normal.png'; UVScale: 25;
     IsOriented:False; Stretch:False; Orientation:suoAlong),

    { Farmland: isOriented (strips), no stretch (texture tiles). }
    (Name:'farmland0';       TexturePath:SURF_DIR+'farmland0_diffuse.png';
     NormalPath:SURF_DIR+'farmland0_normal.png'; UVScale: 50;
     IsOriented:True; Stretch:False; Orientation:suoAlong),
    (Name:'farmland1';       TexturePath:SURF_DIR+'farmland1_diffuse.png';
     NormalPath:SURF_DIR+'farmland1_normal.png'; UVScale: 50;
     IsOriented:True; Stretch:False; Orientation:suoAlong),
    (Name:'farmland2';       TexturePath:SURF_DIR+'farmland2_diffuse.png';
     NormalPath:SURF_DIR+'farmland2_normal.png'; UVScale: 50;
     IsOriented:True; Stretch:False; Orientation:suoAlong),

    (Name:'industrial';      TexturePath:'';
     NormalPath:''; UVScale: 0;
     IsOriented:False; Stretch:False; Orientation:suoAlong),
    (Name:'cemetery';        TexturePath:'';
     NormalPath:''; UVScale: 0;
     IsOriented:False; Stretch:False; Orientation:suoAlong),

    (Name:'scrub';           TexturePath:SURF_DIR+'forest_floor_diffuse.png';
     NormalPath:SURF_DIR+'forest_floor_normal.png'; UVScale: 15;
     IsOriented:False; Stretch:False; Orientation:suoAlong),

    (Name:'manicured_grass'; TexturePath:SURF_DIR+'manicured_grass_diffuse.png';
     NormalPath:''; UVScale: 20;
     IsOriented:False; Stretch:False; Orientation:suoAlong),

    (Name:'garden';          TexturePath:SURF_DIR+'garden_diffuse.png';
     NormalPath:SURF_DIR+'garden_normal.png'; UVScale: 15;
     IsOriented:False; Stretch:False; Orientation:suoAlong),

    (Name:'rock';            TexturePath:SURF_DIR+'rock_diffuse.png';
     NormalPath:SURF_DIR+'rock_normal.png'; UVScale: 32;
     IsOriented:False; Stretch:False; Orientation:suoAlong),

    (Name:'gravel';          TexturePath:SURF_DIR+'gravel_diffuse.png';
     NormalPath:SURF_DIR+'gravel_normal.png'; UVScale: 8;
     IsOriented:False; Stretch:False; Orientation:suoAlong),

    (Name:'pavement_area';   TexturePath:SURF_DIR+'pavement_diffuse.png';
     NormalPath:SURF_DIR+'pavement_normal.png'; UVScale: 10;
     IsOriented:False; Stretch:False; Orientation:suoAlong),

    (Name:'asphalt_area';    TexturePath:'';
     NormalPath:''; UVScale: 20;
     IsOriented:False; Stretch:False; Orientation:suoAlong),

    (Name:'cobblestone';     TexturePath:SURF_DIR+'cobblestone_diffuse.png';
     NormalPath:SURF_DIR+'cobblestone_normal.png'; UVScale: 6;
     IsOriented:False; Stretch:False; Orientation:suoAlong),

    { Pitch generic: isOriented (aligned) but no stretch. }
    (Name:'pitch_generic';   TexturePath:SURF_DIR+'pitch_generic_diffuse.png';
     NormalPath:SURF_DIR+'pitch_generic_normal.png'; UVScale: 30;
     IsOriented:True; Stretch:False; Orientation:suoAlong),

    { Football/basket/tennis: the pitch texture with markings must
      cover exactly 1 tile per polygon. UVScale=1 (no tiling),
      Stretch=True. football_pitch has no normal map upstream
      (common_normal is used there — skip for now, not critical). }
    (Name:'pitch_football';  TexturePath:SURF_DIR+'football_pitch_diffuse.png';
     NormalPath:''; UVScale: 1;
     IsOriented:True; Stretch:True; Orientation:suoAlong),
    (Name:'pitch_basketball';TexturePath:SURF_DIR+'basketball_pitch_diffuse.png';
     NormalPath:SURF_DIR+'basketball_pitch_normal.png'; UVScale: 1;
     IsOriented:True; Stretch:True; Orientation:suoAlong),
    (Name:'pitch_tennis';    TexturePath:SURF_DIR+'tennis_pitch_diffuse.png';
     NormalPath:SURF_DIR+'tennis_pitch_normal.png'; UVScale: 1;
     IsOriented:True; Stretch:True; Orientation:suoAlong),

    (Name:'helipad';         TexturePath:SURF_DIR+'helipad_diffuse.png';
     NormalPath:''; UVScale: 1;
     IsOriented:True; Stretch:True; Orientation:suoAlong)
  );

implementation

function CmpLex(const P, Q: TOMBBPoint): Integer; inline;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1495);{$ENDIF}
  if P.X < Q.X then Exit(-1);
  if P.X > Q.X then Exit(1);
  if P.Z < Q.Z then Exit(-1);
  if P.Z > Q.Z then Exit(1);
  Result := 0;
end;

procedure QSortLex(var A: TOMBBPointArray; L, R: Integer);
var
  I, J: Integer;
  Pivot, Tmp: TOMBBPoint;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1496);{$ENDIF}
  if L >= R then Exit;
  Pivot := A[(L + R) div 2];
  I := L; J := R;
  repeat
    while CmpLex(A[I], Pivot) < 0 do Inc(I);
    while CmpLex(A[J], Pivot) > 0 do Dec(J);
    if I <= J then
    begin
      Tmp := A[I]; A[I] := A[J]; A[J] := Tmp;
      Inc(I); Dec(J);
    end;
  until I > J;
  QSortLex(A, L, J);
  QSortLex(A, I, R);
end;

{ Cross-product (A-O)×(B-O). >0 = CCW turn, <0 = CW, =0 = collinear. }
function Cross(const O, A, B: TOMBBPoint): Double; inline;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1497);{$ENDIF}
  Result := XZCross(A, B, O);
end;

class function TOMBB.ConvexHull(const Pts: TOMBBPointArray): TOMBBPointArray;
var
  N, K, T, I: Integer;
  Sorted: TOMBBPointArray;
  Hull: TOMBBPointArray;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1141);{$ENDIF}
  N := Length(Pts);
  if N <= 1 then
  begin
    SetLength(Result, N);
    if N = 1 then Result[0] := Pts[0];
    Exit;
  end;

  SetLength(Sorted, N);
  for I := 0 to N - 1 do Sorted[I] := Pts[I];
  QSortLex(Sorted, 0, N - 1);

  SetLength(Hull, 2 * N);
  K := 0;

  { Lower hull. }
  for I := 0 to N - 1 do
  begin
    while (K >= 2) and (Cross(Hull[K - 2], Hull[K - 1], Sorted[I]) <= 0) do
      Dec(K);
    Hull[K] := Sorted[I];
    Inc(K);
  end;

  { Upper hull. T = lower bound for K — the lower hull must be preserved. }
  T := K + 1;
  for I := N - 2 downto 0 do
  begin
    while (K >= T) and (Cross(Hull[K - 2], Hull[K - 1], Sorted[I]) <= 0) do
      Dec(K);
    Hull[K] := Sorted[I];
    Inc(K);
  end;
  Dec(K);     { last point coincides with the first }

  SetLength(Hull, K);
  Result := Hull;
end;

class function TOMBB.ComputeFromHull(const Hull: TOMBBPointArray): TOMBBCorners;
var
  N, I, INext, J: Integer;
  EdgeDx, EdgeDy, EdgeLen: Double;
  CosA, SinA: Double;
  RX, RY: Double;
  MinX, MaxX, MinY, MaxY: Double;
  Area, BestArea: Double;
  BestCosA, BestSinA: Double;
  BestMinX, BestMaxX, BestMinY, BestMaxY: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1142);{$ENDIF}
  N := Length(Hull);

  if N = 0 then
  begin
    Result[0] := XZ(0, 0);
    Result[1] := XZ(0, 0);
    Result[2] := XZ(0, 0);
    Result[3] := XZ(0, 0);
    Exit;
  end;

  if N < 3 then
  begin
    MinX := Hull[0].X; MaxX := MinX;
    MinY := Hull[0].Z; MaxY := MinY;
    for I := 1 to N - 1 do
    begin
      if Hull[I].X < MinX then MinX := Hull[I].X
      else if Hull[I].X > MaxX then MaxX := Hull[I].X;
      if Hull[I].Z < MinY then MinY := Hull[I].Z
      else if Hull[I].Z > MaxY then MaxY := Hull[I].Z;
    end;
    Result[0] := XZ(MinX, MaxY);
    Result[1] := XZ(MinX, MinY);
    Result[2] := XZ(MaxX, MinY);
    Result[3] := XZ(MaxX, MaxY);
    Exit;
  end;

  BestArea := Infinity;
  BestCosA := 1; BestSinA := 0;
  BestMinX := 0; BestMaxX := 0; BestMinY := 0; BestMaxY := 0;

  for I := 0 to N - 1 do
  begin
    INext := (I + 1) mod N;
    EdgeDx := Hull[INext].X - Hull[I].X;
    EdgeDy := Hull[INext].Z - Hull[I].Z;
    EdgeLen := Sqrt(EdgeDx * EdgeDx + EdgeDy * EdgeDy);
    if EdgeLen < 1e-12 then Continue;

    { Rotation angle A such that the edge → X axis.
      cos(A) = EdgeDx/Len, sin(A) = -EdgeDy/Len  (rotation by -edgeAngle).
      R(A): x' = x*cos(A) - y*sin(A); y' = x*sin(A) + y*cos(A). }
    CosA :=  EdgeDx / EdgeLen;
    SinA := -EdgeDy / EdgeLen;

    RX := Hull[0].X * CosA - Hull[0].Z * SinA;
    RY := Hull[0].X * SinA + Hull[0].Z * CosA;
    MinX := RX; MaxX := RX;
    MinY := RY; MaxY := RY;
    for J := 1 to N - 1 do
    begin
      RX := Hull[J].X * CosA - Hull[J].Z * SinA;
      RY := Hull[J].X * SinA + Hull[J].Z * CosA;
      if RX < MinX then MinX := RX
      else if RX > MaxX then MaxX := RX;
      if RY < MinY then MinY := RY
      else if RY > MaxY then MaxY := RY;
    end;

    Area := (MaxX - MinX) * (MaxY - MinY);
    if Area < BestArea then
    begin
      BestArea := Area;
      BestCosA := CosA;
      BestSinA := SinA;
      BestMinX := MinX; BestMaxX := MaxX;
      BestMinY := MinY; BestMaxY := MaxY;
    end;
  end;

  { Inverse-rotate AABB corners back to original coordinates.
    Inverse(R(A)) = R(-A) = transpose(R(A)):
      X = RX*cosA + RY*sinA
      Y = -RX*sinA + RY*cosA
    (R(A)*R(-A) = I). }
  Result[0] := XZ(
    BestMinX * BestCosA + BestMaxY * BestSinA,
   -BestMinX * BestSinA + BestMaxY * BestCosA);
  Result[1] := XZ(
    BestMinX * BestCosA + BestMinY * BestSinA,
   -BestMinX * BestSinA + BestMinY * BestCosA);
  Result[2] := XZ(
    BestMaxX * BestCosA + BestMinY * BestSinA,
   -BestMaxX * BestSinA + BestMinY * BestCosA);
  Result[3] := XZ(
    BestMaxX * BestCosA + BestMaxY * BestSinA,
   -BestMaxX * BestSinA + BestMaxY * BestCosA);
end;

class function TOMBB.Compute(const Pts: TOMBBPointArray): TOMBBCorners;
var
  Hull: TOMBBPointArray;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1143);{$ENDIF}
  Hull := ConvexHull(Pts);
  Result := ComputeFromHull(Hull);
end;

type

  TEarcutNode = class
    I:           Integer;
    X, Y:        Double;
    Prev, Next:  TEarcutNode;
    Z:           LongWord;
    PrevZ, NextZ: TEarcutNode;
    Steiner:     Boolean;
  end;

  TEarcutNodePool = class
  private
    FNodes: TList;
  public
    constructor Create;
    destructor Destroy; override;
    function NewNode(AI: Integer; AX, AY: Double): TEarcutNode;
  end;

constructor TEarcutNodePool.Create;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1144);{$ENDIF}
  inherited;
  FNodes := TList.Create;
end;

destructor TEarcutNodePool.Destroy;
var
  I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1145);{$ENDIF}
  if FNodes <> nil then
  begin
    for I := 0 to FNodes.Count - 1 do
      TEarcutNode(FNodes[I]).Free;
    FNodes.Free;
  end;
  inherited;
end;

function TEarcutNodePool.NewNode(AI: Integer; AX, AY: Double): TEarcutNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(367);{$ENDIF}
  Result := TEarcutNode.Create;
  Result.I := AI;
  Result.X := AX;
  Result.Y := AY;
  Result.Prev := nil;
  Result.Next := nil;
  Result.Z := 0;
  Result.PrevZ := nil;
  Result.NextZ := nil;
  Result.Steiner := False;
  FNodes.Add(Result);
end;

function Area(P, Q, R: TEarcutNode): Double; inline;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(368);{$ENDIF}
  Result := (Q.Y - P.Y) * (R.X - Q.X) - (Q.X - P.X) * (R.Y - Q.Y);
end;

function Equals(P1, P2: TEarcutNode): Boolean; inline;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(369);{$ENDIF}
  Result := (P1.X = P2.X) and (P1.Y = P2.Y);
end;

function Sign(Num: Double): Integer; inline;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(370);{$ENDIF}
  if Num > 0 then Result := 1
  else if Num < 0 then Result := -1
  else Result := 0;
end;

function OnSegment(P, Q, R: TEarcutNode): Boolean; inline;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(371);{$ENDIF}
  Result := (Q.X <= Math.Max(P.X, R.X)) and (Q.X >= Math.Min(P.X, R.X)) and
            (Q.Y <= Math.Max(P.Y, R.Y)) and (Q.Y >= Math.Min(P.Y, R.Y));
end;

function Intersects(P1, Q1, P2, Q2: TEarcutNode): Boolean;
var
  O1, O2, O3, O4: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(372);{$ENDIF}
  O1 := Sign(Area(P1, Q1, P2));
  O2 := Sign(Area(P1, Q1, Q2));
  O3 := Sign(Area(P2, Q2, P1));
  O4 := Sign(Area(P2, Q2, Q1));

  if (O1 <> O2) and (O3 <> O4) then Exit(True);

  if (O1 = 0) and OnSegment(P1, P2, Q1) then Exit(True);
  if (O2 = 0) and OnSegment(P1, Q2, Q1) then Exit(True);
  if (O3 = 0) and OnSegment(P2, P1, Q2) then Exit(True);
  if (O4 = 0) and OnSegment(P2, Q1, Q2) then Exit(True);

  Result := False;
end;

function PointInTriangle(AX, AY, BX, BY, CX, CY, PX, PY: Double): Boolean; inline;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(373);{$ENDIF}
  Result := ((CX - PX) * (AY - PY) >= (AX - PX) * (CY - PY)) and
            ((AX - PX) * (BY - PY) >= (BX - PX) * (AY - PY)) and
            ((BX - PX) * (CY - PY) >= (CX - PX) * (BY - PY));
end;

function PointInTriangleExceptFirst(AX, AY, BX, BY, CX, CY, PX, PY: Double): Boolean; inline;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(374);{$ENDIF}
  Result := (not ((AX = PX) and (AY = PY))) and
            PointInTriangle(AX, AY, BX, BY, CX, CY, PX, PY);
end;

function LocallyInside(A, B: TEarcutNode): Boolean; inline;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(375);{$ENDIF}
  if Area(A.Prev, A, A.Next) < 0 then
    Result := (Area(A, B, A.Next) >= 0) and (Area(A, A.Prev, B) >= 0)
  else
    Result := (Area(A, B, A.Prev) < 0) or (Area(A, A.Next, B) < 0);
end;

function MiddleInside(A, B: TEarcutNode): Boolean;
var
  P:        TEarcutNode;
  Inside:   Boolean;
  PX, PY:   Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(376);{$ENDIF}
  P := A;
  Inside := False;
  PX := (A.X + B.X) / 2;
  PY := (A.Y + B.Y) / 2;
  repeat
    if ((P.Y > PY) <> (P.Next.Y > PY)) and (P.Next.Y <> P.Y) and
       (PX < (P.Next.X - P.X) * (PY - P.Y) / (P.Next.Y - P.Y) + P.X) then
      Inside := not Inside;
    P := P.Next;
  until P = A;
  Result := Inside;
end;

function SectorContainsSector(M, P: TEarcutNode): Boolean; inline;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(377);{$ENDIF}
  Result := (Area(M.Prev, M, P.Prev) < 0) and (Area(P.Next, M, M.Next) < 0);
end;

function IntersectsPolygon(A, B: TEarcutNode): Boolean;
var
  P: TEarcutNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(378);{$ENDIF}
  P := A;
  repeat
    if (P.I <> A.I) and (P.Next.I <> A.I) and
       (P.I <> B.I) and (P.Next.I <> B.I) and
       Intersects(P, P.Next, A, B) then
      Exit(True);
    P := P.Next;
  until P = A;
  Result := False;
end;

function IsValidDiagonal(A, B: TEarcutNode): Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(379);{$ENDIF}
  Result := (A.Next.I <> B.I) and (A.Prev.I <> B.I) and
            (not IntersectsPolygon(A, B)) and
            (
              (LocallyInside(A, B) and LocallyInside(B, A) and MiddleInside(A, B) and
               ((Area(A.Prev, A, B.Prev) <> 0) or (Area(A, B.Prev, B) <> 0))
              )
              or
              (Equals(A, B) and (Area(A.Prev, A, A.Next) > 0) and (Area(B.Prev, B, B.Next) > 0))
            );
end;

function InsertNode(Pool: TEarcutNodePool; Idx: Integer; X, Y: Double;
  Last: TEarcutNode): TEarcutNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(380);{$ENDIF}
  Result := Pool.NewNode(Idx, X, Y);
  if Last = nil then
  begin
    Result.Prev := Result;
    Result.Next := Result;
  end
  else
  begin
    Result.Next := Last.Next;
    Result.Prev := Last;
    Last.Next.Prev := Result;
    Last.Next := Result;
  end;
end;

procedure RemoveNode(P: TEarcutNode);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(381);{$ENDIF}
  P.Next.Prev := P.Prev;
  P.Prev.Next := P.Next;

  if P.PrevZ <> nil then P.PrevZ.NextZ := P.NextZ;
  if P.NextZ <> nil then P.NextZ.PrevZ := P.PrevZ;
end;

function SplitPolygon(Pool: TEarcutNodePool; A, B: TEarcutNode): TEarcutNode;
var
  A2, B2, AN, BP: TEarcutNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(382);{$ENDIF}
  A2 := Pool.NewNode(A.I, A.X, A.Y);
  B2 := Pool.NewNode(B.I, B.X, B.Y);
  AN := A.Next;
  BP := B.Prev;

  A.Next := B;
  B.Prev := A;

  A2.Next := AN;
  AN.Prev := A2;

  B2.Next := A2;
  A2.Prev := B2;

  BP.Next := B2;
  B2.Prev := BP;

  Result := B2;
end;

function FilterPoints(Start, EndN: TEarcutNode): TEarcutNode;
var
  P:       TEarcutNode;
  Again:   Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(383);{$ENDIF}
  if Start = nil then Exit(nil);
  if EndN = nil then EndN := Start;

  P := Start;
  repeat
    Again := False;

    if (not P.Steiner) and
       (Equals(P, P.Next) or (Area(P.Prev, P, P.Next) = 0)) then
    begin
      RemoveNode(P);
      P := P.Prev;
      EndN := P;
      if P = P.Next then Break;
      Again := True;
    end
    else
      P := P.Next;
  until (not Again) and (P = EndN);

  Result := EndN;
end;

function SignedArea(const Data: array of Double; Start, EndIdx, Dim: Integer): Double;
var
  I, J: Integer;
  Sum:  Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(384);{$ENDIF}
  Sum := 0;
  J := EndIdx - Dim;
  I := Start;
  while I < EndIdx do
  begin
    Sum := Sum + (Data[J] - Data[I]) * (Data[I + 1] + Data[J + 1]);
    J := I;
    Inc(I, Dim);
  end;
  Result := Sum;
end;

function LinkedList(Pool: TEarcutNodePool;
  const Data: array of Double; Start, EndIdx, Dim: Integer;
  Clockwise: Boolean): TEarcutNode;
var
  I:    Integer;
  Last: TEarcutNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(385);{$ENDIF}
  Last := nil;

  if Clockwise = (SignedArea(Data, Start, EndIdx, Dim) > 0) then
  begin
    I := Start;
    while I < EndIdx do
    begin
      Last := InsertNode(Pool, I div Dim, Data[I], Data[I + 1], Last);
      Inc(I, Dim);
    end;
  end
  else
  begin
    I := EndIdx - Dim;
    while I >= Start do
    begin
      Last := InsertNode(Pool, I div Dim, Data[I], Data[I + 1], Last);
      Dec(I, Dim);
    end;
  end;

  if (Last <> nil) and Equals(Last, Last.Next) then
  begin
    RemoveNode(Last);
    Last := Last.Next;
  end;

  Result := Last;
end;

function ZOrder(X, Y, MinX, MinY, InvSize: Double): LongWord; inline;
var
  IX, IY: LongWord;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(386);{$ENDIF}

  IX := LongWord(Trunc((X - MinX) * InvSize));
  IY := LongWord(Trunc((Y - MinY) * InvSize));

  IX := (IX or (IX shl 8)) and $00FF00FF;
  IX := (IX or (IX shl 4)) and $0F0F0F0F;
  IX := (IX or (IX shl 2)) and $33333333;
  IX := (IX or (IX shl 1)) and $55555555;

  IY := (IY or (IY shl 8)) and $00FF00FF;
  IY := (IY or (IY shl 4)) and $0F0F0F0F;
  IY := (IY or (IY shl 2)) and $33333333;
  IY := (IY or (IY shl 1)) and $55555555;

  Result := IX or (IY shl 1);
end;

function SortLinked(List: TEarcutNode): TEarcutNode;
var
  NumMerges, InSize, I, PSize, QSize: Integer;
  P, Q, E, Tail: TEarcutNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(387);{$ENDIF}
  InSize := 1;
  repeat
    P := List;
    List := nil;
    Tail := nil;
    NumMerges := 0;

    while P <> nil do
    begin
      Inc(NumMerges);
      Q := P;
      PSize := 0;
      for I := 0 to InSize - 1 do
      begin
        Inc(PSize);
        Q := Q.NextZ;
        if Q = nil then Break;
      end;
      QSize := InSize;

      while (PSize > 0) or ((QSize > 0) and (Q <> nil)) do
      begin
        if (PSize <> 0) and ((QSize = 0) or (Q = nil) or (P.Z <= Q.Z)) then
        begin
          E := P;
          P := P.NextZ;
          Dec(PSize);
        end
        else
        begin
          E := Q;
          Q := Q.NextZ;
          Dec(QSize);
        end;

        if Tail <> nil then Tail.NextZ := E
        else List := E;

        E.PrevZ := Tail;
        Tail := E;
      end;

      P := Q;
    end;

    if Tail <> nil then Tail.NextZ := nil;
    InSize := InSize * 2;

  until NumMerges <= 1;

  Result := List;
end;

procedure IndexCurve(Start: TEarcutNode; MinX, MinY, InvSize: Double);
var
  P: TEarcutNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(388);{$ENDIF}
  P := Start;
  repeat
    if P.Z = 0 then
      P.Z := ZOrder(P.X, P.Y, MinX, MinY, InvSize);
    P.PrevZ := P.Prev;
    P.NextZ := P.Next;
    P := P.Next;
  until P = Start;

  P.PrevZ.NextZ := nil;
  P.PrevZ := nil;

  SortLinked(P);
end;

{ A/B/C ear corner + triangle bbox. False (caller should skip) when the
  corner is reflex, so the convexity test stays ahead of the bbox math. }
function EarSetup(Ear: TEarcutNode;
  out A, B, C: TEarcutNode;
  out AX, AY, BX, BY, CX, CY: Double;
  out X0, Y0, X1, Y1: Double): Boolean; inline;
begin
  A := Ear.Prev;
  B := Ear;
  C := Ear.Next;
  if Area(A, B, C) >= 0 then Exit(False);
  AX := A.X; AY := A.Y;
  BX := B.X; BY := B.Y;
  CX := C.X; CY := C.Y;
  X0 := Math.Min(Math.Min(AX, BX), CX);
  Y0 := Math.Min(Math.Min(AY, BY), CY);
  X1 := Math.Max(Math.Max(AX, BX), CX);
  Y1 := Math.Max(Math.Max(AY, BY), CY);
  Result := True;
end;

function IsEar(Ear: TEarcutNode): Boolean;
var
  A, B, C, P: TEarcutNode;
  AX, AY, BX, BY, CX, CY: Double;
  X0, Y0, X1, Y1: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(389);{$ENDIF}
  if not EarSetup(Ear, A, B, C, AX, AY, BX, BY, CX, CY, X0, Y0, X1, Y1) then
    Exit(False);

  P := C.Next;
  while P <> A do
  begin
    if (P.X >= X0) and (P.X <= X1) and (P.Y >= Y0) and (P.Y <= Y1) and
       PointInTriangleExceptFirst(AX, AY, BX, BY, CX, CY, P.X, P.Y) and
       (Area(P.Prev, P, P.Next) >= 0) then
      Exit(False);
    P := P.Next;
  end;

  Result := True;
end;

function IsEarHashed(Ear: TEarcutNode; MinX, MinY, InvSize: Double): Boolean;
var
  A, B, C, P, N: TEarcutNode;
  AX, AY, BX, BY, CX, CY: Double;
  X0, Y0, X1, Y1: Double;
  MinZ, MaxZ: LongWord;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(390);{$ENDIF}
  if not EarSetup(Ear, A, B, C, AX, AY, BX, BY, CX, CY, X0, Y0, X1, Y1) then
    Exit(False);

  MinZ := ZOrder(X0, Y0, MinX, MinY, InvSize);
  MaxZ := ZOrder(X1, Y1, MinX, MinY, InvSize);

  P := Ear.PrevZ;
  N := Ear.NextZ;

  while (P <> nil) and (P.Z >= MinZ) and (N <> nil) and (N.Z <= MaxZ) do
  begin
    if (P.X >= X0) and (P.X <= X1) and (P.Y >= Y0) and (P.Y <= Y1) and
       (P <> A) and (P <> C) and
       PointInTriangleExceptFirst(AX, AY, BX, BY, CX, CY, P.X, P.Y) and
       (Area(P.Prev, P, P.Next) >= 0) then
      Exit(False);
    P := P.PrevZ;

    if (N.X >= X0) and (N.X <= X1) and (N.Y >= Y0) and (N.Y <= Y1) and
       (N <> A) and (N <> C) and
       PointInTriangleExceptFirst(AX, AY, BX, BY, CX, CY, N.X, N.Y) and
       (Area(N.Prev, N, N.Next) >= 0) then
      Exit(False);
    N := N.NextZ;
  end;

  while (P <> nil) and (P.Z >= MinZ) do
  begin
    if (P.X >= X0) and (P.X <= X1) and (P.Y >= Y0) and (P.Y <= Y1) and
       (P <> A) and (P <> C) and
       PointInTriangleExceptFirst(AX, AY, BX, BY, CX, CY, P.X, P.Y) and
       (Area(P.Prev, P, P.Next) >= 0) then
      Exit(False);
    P := P.PrevZ;
  end;

  while (N <> nil) and (N.Z <= MaxZ) do
  begin
    if (N.X >= X0) and (N.X <= X1) and (N.Y >= Y0) and (N.Y <= Y1) and
       (N <> A) and (N <> C) and
       PointInTriangleExceptFirst(AX, AY, BX, BY, CX, CY, N.X, N.Y) and
       (Area(N.Prev, N, N.Next) >= 0) then
      Exit(False);
    N := N.NextZ;
  end;

  Result := True;
end;

function GetLeftmost(Start: TEarcutNode): TEarcutNode;
var
  P, Leftmost: TEarcutNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(391);{$ENDIF}
  P := Start;
  Leftmost := Start;
  repeat
    if (P.X < Leftmost.X) or ((P.X = Leftmost.X) and (P.Y < Leftmost.Y)) then
      Leftmost := P;
    P := P.Next;
  until P = Start;
  Result := Leftmost;
end;

function FindHoleBridge(Hole, OuterNode: TEarcutNode): TEarcutNode;
var
  P, M, Stop: TEarcutNode;
  HX, HY, QX, X, MX, MY, TanV, TanMin: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(392);{$ENDIF}
  P := OuterNode;
  HX := Hole.X;
  HY := Hole.Y;
  QX := -MaxDouble;
  M := nil;

  if Equals(Hole, P) then Exit(P);
  repeat
    if Equals(Hole, P.Next) then Exit(P.Next)
    else if (HY <= P.Y) and (HY >= P.Next.Y) and (P.Next.Y <> P.Y) then
    begin
      X := P.X + (HY - P.Y) * (P.Next.X - P.X) / (P.Next.Y - P.Y);
      if (X <= HX) and (X > QX) then
      begin
        QX := X;
        if P.X < P.Next.X then M := P else M := P.Next;
        if X = HX then Exit(M);
      end;
    end;
    P := P.Next;
  until P = OuterNode;

  if M = nil then Exit(nil);

  Stop := M;
  MX := M.X;
  MY := M.Y;
  TanMin := MaxDouble;

  P := M;

  repeat
    if (HX >= P.X) and (P.X >= MX) and (HX <> P.X) and
       PointInTriangle(
         IfThen(HY < MY, HX, QX), HY,
         MX, MY,
         IfThen(HY < MY, QX, HX), HY,
         P.X, P.Y) then
    begin
      TanV := Abs(HY - P.Y) / (HX - P.X);

      if LocallyInside(P, Hole) and
         ((TanV < TanMin) or
          ((TanV = TanMin) and ((P.X > M.X) or
                                ((P.X = M.X) and SectorContainsSector(M, P))))) then
      begin
        M := P;
        TanMin := TanV;
      end;
    end;

    P := P.Next;
  until P = Stop;

  Result := M;
end;

function EliminateHole(Hole, OuterNode: TEarcutNode;
  Pool: TEarcutNodePool): TEarcutNode;
var
  Bridge, BridgeReverse: TEarcutNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(393);{$ENDIF}
  Bridge := FindHoleBridge(Hole, OuterNode);
  if Bridge = nil then Exit(OuterNode);

  BridgeReverse := SplitPolygon(Pool, Bridge, Hole);

  FilterPoints(BridgeReverse, BridgeReverse.Next);
  Result := FilterPoints(Bridge, Bridge.Next);
end;

function CompareXYSlope(A, B: TEarcutNode): Double;
var
  R, ASlope, BSlope: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(394);{$ENDIF}
  R := A.X - B.X;
  if R = 0 then
  begin
    R := A.Y - B.Y;
    if R = 0 then
    begin
      ASlope := (A.Next.Y - A.Y) / (A.Next.X - A.X);
      BSlope := (B.Next.Y - B.Y) / (B.Next.X - B.X);
      R := ASlope - BSlope;
    end;
  end;
  Result := R;
end;

function EliminateHoles(Pool: TEarcutNodePool;
  const Data: array of Double; const HoleIndices: array of Integer;
  OuterNode: TEarcutNode; Dim: Integer): TEarcutNode;
var
  Queue: array of TEarcutNode;
  I, Start, EndIdx, J, QueueCount: Integer;
  List: TEarcutNode;
  Tmp: TEarcutNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(395);{$ENDIF}
  SetLength(Queue, Length(HoleIndices));
  QueueCount := 0;

  for I := 0 to High(HoleIndices) do
  begin
    Start := HoleIndices[I] * Dim;
    if I < High(HoleIndices) then
      EndIdx := HoleIndices[I + 1] * Dim
    else
      EndIdx := Length(Data);

    if Start = EndIdx then Continue; { empty optional inner ring }
    List := LinkedList(Pool, Data, Start, EndIdx, Dim, False);
    if List = nil then Continue;
    if List = List.Next then List.Steiner := True;
    Queue[QueueCount] := GetLeftmost(List);
    Inc(QueueCount);
  end;

  for I := 1 to QueueCount - 1 do
  begin
    J := I;
    while (J > 0) and (CompareXYSlope(Queue[J - 1], Queue[J]) > 0) do
    begin
      Tmp := Queue[J - 1];
      Queue[J - 1] := Queue[J];
      Queue[J] := Tmp;
      Dec(J);
    end;
  end;

  for I := 0 to QueueCount - 1 do
    OuterNode := EliminateHole(Queue[I], OuterNode, Pool);

  Result := OuterNode;
end;

function CureLocalIntersections(Start: TEarcutNode;
  var Triangles: TIntArray; var TrCount: Integer): TEarcutNode;
var
  P, A, B: TEarcutNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(396);{$ENDIF}
  P := Start;
  repeat
    A := P.Prev;
    B := P.Next.Next;

    if (not Equals(A, B)) and Intersects(A, P, P.Next, B) and
       LocallyInside(A, B) and LocallyInside(B, A) then
    begin
      if TrCount + 3 > Length(Triangles) then
        SetLength(Triangles, (TrCount + 3) * 2);
      Triangles[TrCount]     := A.I;
      Triangles[TrCount + 1] := P.I;
      Triangles[TrCount + 2] := B.I;
      Inc(TrCount, 3);

      RemoveNode(P);
      RemoveNode(P.Next);

      P := B;
      Start := B;
    end;
    P := P.Next;
  until P = Start;

  Result := FilterPoints(P, nil);
end;

procedure EarcutLinked(Pool: TEarcutNodePool; Ear: TEarcutNode;
  var Triangles: TIntArray; var TrCount: Integer;
  Dim: Integer; MinX, MinY, InvSize: Double; Pass: Integer); forward;

procedure SplitEarcut(Pool: TEarcutNodePool; Start: TEarcutNode;
  var Triangles: TIntArray; var TrCount: Integer;
  Dim: Integer; MinX, MinY, InvSize: Double);
var
  A, B, C: TEarcutNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(398);{$ENDIF}
  A := Start;
  repeat
    B := A.Next.Next;
    while B <> A.Prev do
    begin
      if (A.I <> B.I) and IsValidDiagonal(A, B) then
      begin
        C := SplitPolygon(Pool, A, B);

        A := FilterPoints(A, A.Next);
        C := FilterPoints(C, C.Next);

        EarcutLinked(Pool, A, Triangles, TrCount, Dim, MinX, MinY, InvSize, 0);
        EarcutLinked(Pool, C, Triangles, TrCount, Dim, MinX, MinY, InvSize, 0);
        Exit;
      end;
      B := B.Next;
    end;
    A := A.Next;
  until A = Start;
end;

procedure EarcutLinked(Pool: TEarcutNodePool; Ear: TEarcutNode;
  var Triangles: TIntArray; var TrCount: Integer;
  Dim: Integer; MinX, MinY, InvSize: Double; Pass: Integer);
var
  Stop, Prev, Next: TEarcutNode;
  CanHash: Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(397);{$ENDIF}
  if Ear = nil then Exit;

  CanHash := InvSize <> 0;

  if (Pass = 0) and CanHash then
    IndexCurve(Ear, MinX, MinY, InvSize);

  Stop := Ear;

  while Ear.Prev <> Ear.Next do
  begin
    Prev := Ear.Prev;
    Next := Ear.Next;

    if (CanHash and IsEarHashed(Ear, MinX, MinY, InvSize))
       or ((not CanHash) and IsEar(Ear)) then
    begin

      if TrCount + 3 > Length(Triangles) then
        SetLength(Triangles, (TrCount + 3) * 2);
      Triangles[TrCount]     := Prev.I;
      Triangles[TrCount + 1] := Ear.I;
      Triangles[TrCount + 2] := Next.I;
      Inc(TrCount, 3);

      RemoveNode(Ear);

      Ear := Next.Next;
      Stop := Next.Next;

      Continue;
    end;

    Ear := Next;

    if Ear = Stop then
    begin
      case Pass of
        0:
          EarcutLinked(Pool, FilterPoints(Ear, nil), Triangles, TrCount,
            Dim, MinX, MinY, InvSize, 1);
        1:
          begin
            Ear := CureLocalIntersections(FilterPoints(Ear, nil),
              Triangles, TrCount);
            EarcutLinked(Pool, Ear, Triangles, TrCount,
              Dim, MinX, MinY, InvSize, 2);
          end;
        2:
          SplitEarcut(Pool, Ear, Triangles, TrCount,
            Dim, MinX, MinY, InvSize);
      end;
      Break;
    end;
  end;
end;

class function TEarcutTriangulator.Triangulate(const Data: array of Double;
  const HoleIndices: array of Integer; Dim: Integer): TIntArray;
var
  Pool: TEarcutNodePool;
  HasHoles: Boolean;
  OuterLen, I, PointCount, PreviousHole: Integer;
  OuterNode: TEarcutNode;
  MinX, MinY, MaxX, MaxY, X, Y, InvSize: Double;
  TrCount: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1146);{$ENDIF}
  Result := nil;
  TrCount := 0;

  { Validate the flat layout before LinkedList walks it. A zero stride never
    advances that loop; invalid hole offsets used to read outside Data.
    Repeated offsets are legal empty holes and are skipped above. }
  if Dim < 2 then Exit;
  if Length(Data) mod Dim <> 0 then Exit;
  PointCount := Length(Data) div Dim;
  if PointCount < 3 then Exit;
  PreviousHole := 3;
  for I := 0 to High(HoleIndices) do
  begin
    if (HoleIndices[I] < PreviousHole) or (HoleIndices[I] > PointCount) then Exit;
    PreviousHole := HoleIndices[I];
  end;
  for I := 0 to PointCount - 1 do
    if IsNan(Data[I * Dim]) or IsInfinite(Data[I * Dim]) or
       IsNan(Data[I * Dim + 1]) or IsInfinite(Data[I * Dim + 1]) then Exit;

  HasHoles := Length(HoleIndices) > 0;
  if HasHoles then
    OuterLen := HoleIndices[0] * Dim
  else
    OuterLen := Length(Data);

  Pool := TEarcutNodePool.Create;
  try
    OuterNode := LinkedList(Pool, Data, 0, OuterLen, Dim, True);
    if (OuterNode = nil) or (OuterNode.Next = OuterNode.Prev) then Exit;

    MinX := 0; MinY := 0; InvSize := 0;

    if HasHoles then
      OuterNode := EliminateHoles(Pool, Data, HoleIndices, OuterNode, Dim);

    if Length(Data) > 80 * Dim then
    begin
      MinX := Data[0];
      MinY := Data[1];
      MaxX := MinX;
      MaxY := MinY;

      I := Dim;
      while I < OuterLen do
      begin
        X := Data[I];
        Y := Data[I + 1];
        if X < MinX then MinX := X;
        if Y < MinY then MinY := Y;
        if X > MaxX then MaxX := X;
        if Y > MaxY then MaxY := Y;
        Inc(I, Dim);
      end;

      InvSize := Math.Max(MaxX - MinX, MaxY - MinY);
      if InvSize <> 0 then InvSize := 32767 / InvSize else InvSize := 0;
    end;

    if Length(Data) >= 6 then
      SetLength(Result, ((Length(Data) div Dim) - 2) * 3 + 12);

    EarcutLinked(Pool, OuterNode, Result, TrCount,
      Dim, MinX, MinY, InvSize, 0);

    SetLength(Result, TrCount);
  finally
    Pool.Free;
  end;
end;

class function TEarcutTriangulator.Triangulate(const Data: array of Double;
  Dim: Integer): TIntArray;
var
  Empty: array[0..0] of Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1147);{$ENDIF}

  Empty[0] := 0;
  Result := Triangulate(Data, Slice(Empty, 0), Dim);
end;

class function TPolygonTriangulator.PointInTriangleXZ(const A, B, C, P: TVector3): Boolean;
var
  Sign1, Sign2, Sign3: Single;
  HasNeg, HasPos: Boolean;
  function CrossSign(const X1, X2, X3: TVector3): Single;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(399);{$ENDIF}
    Result := (X1.X - X3.X) * (X2.Z - X3.Z) - (X2.X - X3.X) * (X1.Z - X3.Z);
  end;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1148);{$ENDIF}
  Sign1 := CrossSign(P, A, B);
  Sign2 := CrossSign(P, B, C);
  Sign3 := CrossSign(P, C, A);
  HasNeg := (Sign1 < 0) or (Sign2 < 0) or (Sign3 < 0);
  HasPos := (Sign1 > 0) or (Sign2 > 0) or (Sign3 > 0);
  Result := not (HasNeg and HasPos);
end;

class function TPolygonTriangulator.PointInPolygonXZ(const P: TVector3;
  const Polygon: array of TVector3): Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1149);{$ENDIF}
  Result := Osm3dGeoMath.PointInPolygonXZ(P, Polygon);  { Osm3dGeoMath }
end;

class function TPolygonTriangulator.TriangulateXZ(
  const Polygon: array of TVector3): TIndexArray;
var
  N: Integer;
  PrevNode, NextNode: TIntArray;  { двусвязный список живых вершин по индексам }
  IsCCW: Boolean;
  Remaining, Head: Integer;
  I, K: Integer;
  PI, NI: Integer;
  Cur, LastChecked: Integer;
  TriCount: Integer;

  { Is vertex ACI an ear of the current (linked-list) polygon? }
  function IsEar(ACI: Integer): Boolean;
  var
    API, ANI: Integer;
    A, B, C: TVector3;
    CrossY: Single;
    IK: Integer;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1317);{$ENDIF}
    API := PrevNode[ACI];
    ANI := NextNode[ACI];
    A := Polygon[API];
    B := Polygon[ACI];
    C := Polygon[ANI];

    { Convexity: for a CCW polygon, an ear has a convex vertex
      (triangle signed area > 0). Reversed for CW. After the
      rewinding step below the polygon is always CCW. }
    CrossY := (B.X - A.X) * (C.Z - A.Z) - (B.Z - A.Z) * (C.X - A.X);
    if CrossY <= 0 then Exit(False);    { reflex / collinear — not an ear }

    { No other vertex must lie strictly inside (A, B, C). }
    IK := Head;
    repeat
      if (IK <> API) and (IK <> ACI) and (IK <> ANI) then
        if PointInTriangleXZ(A, B, C, Polygon[IK]) then Exit(False);
      IK := NextNode[IK];
    until IK = Head;
    Result := True;
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1150);{$ENDIF}
  Result := nil;
  N := Length(Polygon);
  if N < 3 then Exit;

  { If the polygon is CW, process it in reverse order. }
  IsCCW := PolygonSignedAreaXZ(Polygon) > 0;

  { Циклический двусвязный список вершин в порядке обхода (CCW);
    «удаление» уха = перелинковка, физических сдвигов массива нет. }
  SetLength(PrevNode, N);
  SetLength(NextNode, N);
  if IsCCW then
    for I := 0 to N - 1 do
    begin
      PrevNode[I] := (I - 1 + N) mod N;
      NextNode[I] := (I + 1) mod N;
    end
  else
    for I := 0 to N - 1 do
    begin
      PrevNode[I] := (I + 1) mod N;
      NextNode[I] := (I - 1 + N) mod N;
    end;
  { голова списка = элементу с индексом 0 в старой версии: для CW
    обход начинался с вершины N-1 }
  if IsCCW then Head := 0 else Head := N - 1;
  Remaining := N;

  TriCount := N - 2;
  SetLength(Result, TriCount * 3);
  K := 0;     { write index into Result }

  Cur := Head;
  LastChecked := PrevNode[Head];   { полный круг без уха = деградация }
  while Remaining > 3 do
  begin
    if IsEar(Cur) then
    begin
      PI := PrevNode[Cur];
      NI := NextNode[Cur];

      Result[K    ] := PI;
      Result[K + 1] := Cur;
      Result[K + 2] := NI;
      Inc(K, 3);

      { выкинуть Cur из списка }
      NextNode[PI] := NI;
      PrevNode[NI] := PI;
      if Head = Cur then Head := NI;
      Dec(Remaining);

      { как в исходном алгоритме: после среза поиск с головы списка —
        последовательность ушей (и результат на деградациях) совпадает
        со старой версией точно }
      Cur := Head;
      LastChecked := PrevNode[Head];
    end
    else
    begin
      if Cur = LastChecked then
      begin
        { Polygon is degenerate (self-intersection, duplicates, etc.) —
          return what was produced so far. Caller decides how to handle it. }
        SetLength(Result, K);
        Exit;
      end;
      Cur := NextNode[Cur];
    end;
  end;

  { Last triangle from the remaining 3 vertices. }
  if Remaining = 3 then
  begin
    Result[K    ] := Head;
    Result[K + 1] := NextNode[Head];
    Result[K + 2] := NextNode[NextNode[Head]];
    Inc(K, 3);
  end;

  SetLength(Result, K);
end;

function ExtractNodeRefs(Way: TOSMWay): TInt64Array;
var I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(400);{$ENDIF}
  if Way = nil then begin Result := nil; Exit; end;
  SetLength(Result, Length(Way.NodeRefs));
  for I := 0 to High(Way.NodeRefs) do
    Result[I] := Way.NodeRefs[I];
end;

procedure ReverseRefs(var Refs: TInt64Array);
var
  I, N: Integer;
  Tmp: Int64;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(401);{$ENDIF}
  N := Length(Refs);
  for I := 0 to (N div 2) - 1 do
  begin
    Tmp := Refs[I];
    Refs[I] := Refs[N - 1 - I];
    Refs[N - 1 - I] := Tmp;
  end;
end;

function BuildRingFromNodeChain(const Chain: TInt64Array;
  Dataset: TOSMDataset; Projection: TLocalProjection): TPolygonRing;
var
  N, I: Integer;
  Node: TOSMNode;
  V: TVector3;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(402);{$ENDIF}
  Result := nil;
  N := Length(Chain);
  { Drop a closing-duplicate node if present — rings are stored open. }
  if (N >= 2) and (Chain[0] = Chain[N - 1]) then
    Dec(N);
  if N < 3 then Exit;

  SetLength(Result, N);
  for I := 0 to N - 1 do
  begin
    Node := Dataset.FindNode(Chain[I]);
    if Node = nil then begin Result := nil; Exit; end;
    V := Projection.Project(Node.Position, 0);
    Result[I].X := V.X;
    Result[I].Z := V.Z;
  end;
end;

function RingFromWay(Way: TOSMWay; Dataset: TOSMDataset;
  Projection: TLocalProjection): TPolygonRing;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(403);{$ENDIF}
  if (Way = nil) or (not Way.IsClosed) then Exit(nil);
  Result := BuildRingFromNodeChain(ExtractNodeRefs(Way), Dataset, Projection);
end;

function StitchWaysIntoRings(const Ways: array of TOSMWay;
  Dataset: TOSMDataset; Projection: TLocalProjection): TPolygonRingArray;
var
  Chains:    TInt64ArrayArray;
  I:         Integer;
  Ring:      TPolygonRing;
  RingCount: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(404);{$ENDIF}
  { Тонкая обёртка над StitchWaysIntoRingChains: тот же обход графа концов,
    только сырые node-цепочки превращаются в кольца через BuildRingFromNodeChain.
    Раньше весь алгоритм сшивки дублировался здесь целиком. }
  Result := nil;
  RingCount := 0;
  Chains := StitchWaysIntoRingChains(Ways);
  for I := 0 to High(Chains) do
  begin
    Ring := BuildRingFromNodeChain(Chains[I], Dataset, Projection);
    if Length(Ring) >= 3 then
    begin
      if RingCount >= Length(Result) then
        SetLength(Result, RingCount * 2 + 4);
      Result[RingCount] := Ring;
      Inc(RingCount);
    end;
  end;
  SetLength(Result, RingCount);
end;

function StitchWaysIntoRingChains(
  const Ways: array of TOSMWay): TInt64ArrayArray;
var
  Used:  array of Boolean;
  I, J, K:   Integer;
  Chain: TInt64Array;
  ChainLen:  Integer;
  StartNode, CurEnd: Int64;
  Found:     Boolean;
  Refs:      TInt64Array;
  RefsCount: Integer;
  ChainCount: Integer;
begin
  Result := nil;
  ChainCount := 0;
  if Length(Ways) = 0 then Exit;

  SetLength(Used, Length(Ways));

  for I := 0 to High(Ways) do
  begin
    if Used[I] then Continue;
    if Ways[I] = nil then Continue;
    if Length(Ways[I].NodeRefs) < 2 then Continue;

    Refs := ExtractNodeRefs(Ways[I]);
    SetLength(Chain, Length(Refs) * 4);
    ChainLen := 0;
    for J := 0 to High(Refs) do
    begin
      Chain[ChainLen] := Refs[J];
      Inc(ChainLen);
    end;
    Used[I] := True;
    StartNode := Chain[0];
    CurEnd := Chain[ChainLen - 1];

    { Already-closed single way (Chain[0] = Chain[last]) — emit as-is. }
    if StartNode = CurEnd then
    begin
      if ChainLen >= 4 then
      begin
        if ChainCount >= Length(Result) then
          SetLength(Result, ChainCount * 2 + 4);
        Result[ChainCount] := Copy(Chain, 0, ChainLen);
        Inc(ChainCount);
      end;
      Continue;
    end;

    { Open way — walk the endpoint graph, appending matching ways
      (forward or reversed) until the chain closes back on StartNode. }
    repeat
      Found := False;
      for J := 0 to High(Ways) do
      begin
        if Used[J] then Continue;
        if Ways[J] = nil then Continue;
        if Length(Ways[J].NodeRefs) < 2 then Continue;

        Refs := ExtractNodeRefs(Ways[J]);
        RefsCount := Length(Refs);

        if Refs[0] = CurEnd then
        begin
          if ChainLen + RefsCount - 1 > Length(Chain) then
            SetLength(Chain, (ChainLen + RefsCount) * 2);
          for K := 1 to RefsCount - 1 do
          begin
            Chain[ChainLen] := Refs[K];
            Inc(ChainLen);
          end;
          CurEnd := Refs[RefsCount - 1];
          Used[J] := True;
          Found := True;
          Break;
        end
        else if Refs[RefsCount - 1] = CurEnd then
        begin
          ReverseRefs(Refs);
          if ChainLen + RefsCount - 1 > Length(Chain) then
            SetLength(Chain, (ChainLen + RefsCount) * 2);
          for K := 1 to RefsCount - 1 do
          begin
            Chain[ChainLen] := Refs[K];
            Inc(ChainLen);
          end;
          CurEnd := Refs[RefsCount - 1];
          Used[J] := True;
          Found := True;
          Break;
        end;
      end;

      if (ChainLen >= 4) and (Chain[ChainLen - 1] = StartNode) then Break;
    until not Found;

    if (ChainLen >= 4) and (Chain[ChainLen - 1] = StartNode) then
    begin
      if ChainCount >= Length(Result) then
        SetLength(Result, ChainCount * 2 + 4);
      Result[ChainCount] := Copy(Chain, 0, ChainLen);
      Inc(ChainCount);
    end;
  end;

  SetLength(Result, ChainCount);
end;

procedure SplitRelationByRole(Rel: TOSMRelation; Dataset: TOSMDataset;
  var OuterWays, InnerWays: TOSMWayArray;
  out OuterCount, InnerCount: Integer);
var
  I: Integer;
  Member: TOSMRelationMember;
  Way: TOSMWay;
  Role: string;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(405);{$ENDIF}
  OuterCount := 0;
  InnerCount := 0;
  if Rel = nil then Exit;

  for I := 0 to Rel.MemberCount - 1 do
  begin
    Member := Rel.Members[I];
    if Member.Kind <> omkWay then Continue;

    Way := Dataset.FindWay(Member.Ref);
    if Way = nil then Continue;
    if Length(Way.NodeRefs) < 2 then Continue;

    Role := LowerCase(Member.Role);
    if (Role = 'outer') or (Role = '') then
    begin
      { динамический рост: прежний фиксированный лимит (256) молча ТЕРЯЛ
        члены крупных релейшенов }
      if OuterCount >= Length(OuterWays) then
        SetLength(OuterWays, OuterCount * 2 + 16);
      OuterWays[OuterCount] := Way;
      Inc(OuterCount);
    end
    else if Role = 'inner' then
    begin
      if InnerCount >= Length(InnerWays) then
        SetLength(InnerWays, InnerCount * 2 + 16);
      InnerWays[InnerCount] := Way;
      Inc(InnerCount);
    end;
  end;
end;

function AssignInnerRingsToOuters(const OuterRings,
  InnerRings: TPolygonRingArray): TIntArray;
type
  TRingBounds = record
    MinX, MaxX, MinZ, MaxZ, Area: Double;
  end;
var
  I, J, Owner: Integer;
  OuterBounds: array of TRingBounds;
  InnerBounds: TRingBounds;
  BestArea: Double;

  function RingBounds(const Ring: TPolygonRing): TRingBounds;
  var P, Prev: Integer;
  begin
    Result.MinX := Ring[0].X; Result.MaxX := Ring[0].X;
    Result.MinZ := Ring[0].Z; Result.MaxZ := Ring[0].Z;
    Result.Area := 0;
    Prev := High(Ring);
    for P := 0 to High(Ring) do
    begin
      Result.MinX := Min(Result.MinX, Ring[P].X);
      Result.MaxX := Max(Result.MaxX, Ring[P].X);
      Result.MinZ := Min(Result.MinZ, Ring[P].Z);
      Result.MaxZ := Max(Result.MaxZ, Ring[P].Z);
      Result.Area := Result.Area +
        (Ring[Prev].X - Ring[0].X) * (Ring[P].Z - Ring[0].Z) -
        (Ring[P].X - Ring[0].X) * (Ring[Prev].Z - Ring[0].Z);
      Prev := P;
    end;
    Result.Area := Abs(Result.Area) * 0.5;
  end;

  function ContainsInner(const Outer, Inner: TPolygonRing): Boolean;
  var P, Q, Prev: Integer; DX, DZ, PX, PZ: Double; OnEdge: Boolean;
  begin
    { Valid OSM rings do not cross. Classify a vertex off the boundary;
      a touching first vertex alone cannot decide which outer owns a hole. }
    for P := 0 to High(Inner) do
    begin
      OnEdge := False;
      Prev := High(Outer);
      for Q := 0 to High(Outer) do
      begin
        DX := Outer[Q].X - Outer[Prev].X;
        DZ := Outer[Q].Z - Outer[Prev].Z;
        PX := Inner[P].X - Outer[Prev].X;
        PZ := Inner[P].Z - Outer[Prev].Z;
        if (PX * DZ = PZ * DX) and
           (Inner[P].X >= Min(Outer[Prev].X, Outer[Q].X)) and
           (Inner[P].X <= Max(Outer[Prev].X, Outer[Q].X)) and
           (Inner[P].Z >= Min(Outer[Prev].Z, Outer[Q].Z)) and
           (Inner[P].Z <= Max(Outer[Prev].Z, Outer[Q].Z)) then
        begin OnEdge := True; Break; end;
        Prev := Q;
      end;
      if not OnEdge then Exit(PointInRingXZ(Inner[P].X, Inner[P].Z, Outer));
    end;
    Result := False; { coincident/degenerate rings do not define a hole }
  end;
begin
  SetLength(Result, Length(InnerRings));
  for J := 0 to High(Result) do Result[J] := -1;
  if (Length(InnerRings) = 0) or (Length(OuterRings) = 0) then Exit;
  SetLength(OuterBounds, Length(OuterRings));
  for I := 0 to High(OuterRings) do
    if Length(OuterRings[I]) >= 3 then
      OuterBounds[I] := RingBounds(OuterRings[I]);
  { Each hole belongs to one containing outer, not every outer in the
    relation. Foreign holes make earcut connect disjoint forests many km
    apart and can turn a tiny scatter polygon into millions of cells.
    The smallest containing outer also handles an island with its own hole. }
  for J := 0 to High(InnerRings) do
  begin
    if Length(InnerRings[J]) < 3 then Continue;
    InnerBounds := RingBounds(InnerRings[J]);
    Owner := -1;
    BestArea := MaxDouble;
    for I := 0 to High(OuterRings) do
      if (OuterBounds[I].Area > InnerBounds.Area) and
         (OuterBounds[I].Area < BestArea) and
         (InnerBounds.MinX >= OuterBounds[I].MinX) and
         (InnerBounds.MaxX <= OuterBounds[I].MaxX) and
         (InnerBounds.MinZ >= OuterBounds[I].MinZ) and
         (InnerBounds.MaxZ <= OuterBounds[I].MaxZ) and
         ContainsInner(OuterRings[I], InnerRings[J]) then
      begin
        Owner := I;
        BestArea := OuterBounds[I].Area;
      end;
    Result[J] := Owner;
  end;
end;

function BuildMultipolygonsFromRelation(Rel: TOSMRelation;
  Dataset: TOSMDataset; Projection: TLocalProjection): TMultipolygonArray;
const
  INITIAL_RING_CAP = 256;
var
  OuterWays, InnerWays: TOSMWayArray;
  OuterCount, InnerCount, K, I, J, N, Owner: Integer;
  OuterSlice, InnerSlice: TOSMWayArray;
  OuterRings, InnerRings: TPolygonRingArray;
  Owners: TIntArray;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(406);{$ENDIF}
  Result := nil;
  if (Rel = nil) or (Dataset = nil) or (Projection = nil) then Exit;
  SetLength(OuterWays, INITIAL_RING_CAP);
  SetLength(InnerWays, INITIAL_RING_CAP);
  SplitRelationByRole(Rel, Dataset, OuterWays, InnerWays,
    OuterCount, InnerCount);
  if OuterCount = 0 then Exit;
  SetLength(OuterSlice, OuterCount);
  for K := 0 to OuterCount - 1 do OuterSlice[K] := OuterWays[K];
  SetLength(InnerSlice, InnerCount);
  for K := 0 to InnerCount - 1 do InnerSlice[K] := InnerWays[K];
  OuterRings := StitchWaysIntoRings(OuterSlice, Dataset, Projection);
  InnerRings := StitchWaysIntoRings(InnerSlice, Dataset, Projection);
  Owners := AssignInnerRingsToOuters(OuterRings, InnerRings);
  SetLength(Result, Length(OuterRings));
  for I := 0 to High(OuterRings) do Result[I].Outer := OuterRings[I];
  for J := 0 to High(InnerRings) do
  begin
    Owner := Owners[J];
    if Owner < 0 then Continue;
    N := Length(Result[Owner].Inners);
    SetLength(Result[Owner].Inners, N + 1);
    Result[Owner].Inners[N] := InnerRings[J];
  end;
end;

function BuildMultipolygonFromWay(Way: TOSMWay; Dataset: TOSMDataset;
  Projection: TLocalProjection): TPolygonMultipolygon;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(407);{$ENDIF}
  Result.Outer := RingFromWay(Way, Dataset, Projection);
  SetLength(Result.Inners, 0);
end;

procedure MultipolygonBBox(const MP: TPolygonMultipolygon;
  out MinX, MaxX, MinZ, MaxZ: Single);
var
  I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(409);{$ENDIF}
  MinX := 0; MaxX := 0; MinZ := 0; MaxZ := 0;
  if Length(MP.Outer) = 0 then Exit;

  MinX := MP.Outer[0].X;  MaxX := MinX;
  MinZ := MP.Outer[0].Z;  MaxZ := MinZ;
  for I := 1 to High(MP.Outer) do
  begin
    if MP.Outer[I].X < MinX then MinX := MP.Outer[I].X;
    if MP.Outer[I].X > MaxX then MaxX := MP.Outer[I].X;
    if MP.Outer[I].Z < MinZ then MinZ := MP.Outer[I].Z;
    if MP.Outer[I].Z > MaxZ then MaxZ := MP.Outer[I].Z;
  end;
end;

function IsInsideEdge(const P, EA, EB: TScatterPoint): Boolean; inline;
{ Cross product: point P is "inside" relative to oriented edge EA→EB.
  For a CCW rect, IsInside = True means the point is to the left of the edge, i.e. inside. }
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(410);{$ENDIF}
  Result := (EB.X - EA.X) * (P.Z - EA.Z) - (EB.Z - EA.Z) * (P.X - EA.X) >= 0.0;
end;

function LineIntersection(const A, B, EA, EB: TScatterPoint): TScatterPoint;
{ Parametric intersection of line A→B (parameter t∈[0..1] on the segment)
  with line EA→EB.
    P(t) = A + t·(B-A)
    Substituting into the general line equation EA→EB and applying Cramer's rule:
      t = ((EB.Z-EA.Z)·(A.X-EA.X) - (EB.X-EA.X)·(A.Z-EA.Z))
        / ((EB.X-EA.X)·(B.Z-A.Z) - (EB.Z-EA.Z)·(B.X-A.X))
  If denom ≈ 0 — lines are parallel, intersection is undefined,
  return A (guards against division by zero). }
var
  denom, t: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(411);{$ENDIF}
  denom := (EB.X - EA.X) * (B.Z - A.Z) - (EB.Z - EA.Z) * (B.X - A.X);
  if Abs(denom) < 1E-12 then
  begin
    Result := A;
    Exit;
  end;
  t := ((EB.Z - EA.Z) * (A.X - EA.X) - (EB.X - EA.X) * (A.Z - EA.Z)) / denom;
  Result.X := A.X + t * (B.X - A.X);
  Result.Z := A.Z + t * (B.Z - A.Z);
end;

function ClipRingByEdge(const Ring: TPolygonRing;
  const EA, EB: TScatterPoint): TPolygonRing;
{ One Sutherland-Hodgman pass: clip ring against one edge.
  Algorithm:
    For each edge (Prev, Cur):
      Cur inside: if Prev outside — emit intersect; emit Cur.
      Cur outside: if Prev inside — emit intersect.
  Closure: the first point is treated as Prev for the last. }
var
  N, I, OutCount: Integer;
  Prev, Cur: TScatterPoint;
  PrevIn, CurIn: Boolean;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(412);{$ENDIF}
  Result := nil;
  N := Length(Ring);
  if N < 3 then Exit;

  SetLength(Result, N * 2);   { worst case 2N (each point may emit + intersect) }
  OutCount := 0;

  Prev := Ring[N - 1];
  PrevIn := IsInsideEdge(Prev, EA, EB);
  for I := 0 to N - 1 do
  begin
    Cur := Ring[I];
    CurIn := IsInsideEdge(Cur, EA, EB);
    if CurIn then
    begin
      if not PrevIn then
      begin
        Result[OutCount] := LineIntersection(Prev, Cur, EA, EB);
        Inc(OutCount);
      end;
      Result[OutCount] := Cur;
      Inc(OutCount);
    end
    else if PrevIn then
    begin
      Result[OutCount] := LineIntersection(Prev, Cur, EA, EB);
      Inc(OutCount);
    end;
    Prev := Cur;
    PrevIn := CurIn;
  end;

  SetLength(Result, OutCount);
end;

function ClipRingToRect(const Ring: TPolygonRing;
  MinX, MinZ, MaxX, MaxZ: Double): TPolygonRing;
{ Sutherland-Hodgman clipping of a ring to an axis-aligned rectangle.
  Rectangle is CCW-oriented:
    (MinX, MinZ) → (MaxX, MinZ) → (MaxX, MaxZ) → (MinX, MaxZ).
  One pass per edge, results accumulated. }
var
  EA, EB: TScatterPoint;
  EpsX, EpsZ: Double;
  I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(413);{$ENDIF}
  Result := Ring;
  if Length(Result) < 3 then Exit;

  { 1. Bottom edge (MinX,MinZ) → (MaxX,MinZ): inside = Z >= MinZ }
  EA.X := MinX; EA.Z := MinZ;
  EB.X := MaxX; EB.Z := MinZ;
  Result := ClipRingByEdge(Result, EA, EB);
  if Length(Result) < 3 then begin SetLength(Result, 0); Exit; end;

  { 2. Right edge (MaxX,MinZ) → (MaxX,MaxZ): inside = X <= MaxX }
  EA.X := MaxX; EA.Z := MinZ;
  EB.X := MaxX; EB.Z := MaxZ;
  Result := ClipRingByEdge(Result, EA, EB);
  if Length(Result) < 3 then begin SetLength(Result, 0); Exit; end;

  { 3. Top edge (MaxX,MaxZ) → (MinX,MaxZ): inside = Z <= MaxZ }
  EA.X := MaxX; EA.Z := MaxZ;
  EB.X := MinX; EB.Z := MaxZ;
  Result := ClipRingByEdge(Result, EA, EB);
  if Length(Result) < 3 then begin SetLength(Result, 0); Exit; end;

  { 4. Left edge (MinX,MaxZ) → (MinX,MinZ): inside = X >= MinX }
  EA.X := MinX; EA.Z := MaxZ;
  EB.X := MinX; EB.Z := MinZ;
  Result := ClipRingByEdge(Result, EA, EB);
  if Length(Result) < 3 then begin SetLength(Result, 0); Exit; end;

  { Safety: verify all points are actually inside the bbox with a reasonable
    epsilon. If not, the math went wrong somewhere (LineIntersection returned
    a poorly defined point due to denom≈0) — discard the ring. }
  EpsX := (MaxX - MinX) * 0.01;   if EpsX < 1.0 then EpsX := 1.0;
  EpsZ := (MaxZ - MinZ) * 0.01;   if EpsZ < 1.0 then EpsZ := 1.0;
  for I := 0 to High(Result) do
    if (Result[I].X < MinX - EpsX) or (Result[I].X > MaxX + EpsX) or
       (Result[I].Z < MinZ - EpsZ) or (Result[I].Z > MaxZ + EpsZ) then
    begin
      SetLength(Result, 0);
      Exit;
    end;
end;

function SplitMultipolygonIntoTiles(const MP: TPolygonMultipolygon;
  TileSizeM: Double): TMultipolygonArray;
var
  MinX, MaxX, MinZ, MaxZ: Single;
  W, H: Double;
  Tx, Tz, Cx, Cz, I: Integer;
  TileX0, TileX1, TileZ0, TileZ1: Double;
  ClippedOuter, ClippedInner: TPolygonRing;
  Sub: TPolygonMultipolygon;
  OutCount: Integer;
  InnersCount: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(414);{$ENDIF}
  Result := nil;
  if Length(MP.Outer) < 3 then Exit;
  if TileSizeM < 1.0 then TileSizeM := 100.0;

  MultipolygonBBox(MP, MinX, MaxX, MinZ, MaxZ);
  if (MaxX <= MinX) or (MaxZ <= MinZ) then Exit;

  W := MaxX - MinX;
  H := MaxZ - MinZ;

  { If the MP is already smaller than one tile in both axes — return as-is. }
  if (W <= TileSizeM) and (H <= TileSizeM) then
  begin
    SetLength(Result, 1);
    Result[0] := MP;
    Exit;
  end;

  Tx := Trunc(W / TileSizeM) + 1;
  Tz := Trunc(H / TileSizeM) + 1;

  { Guard against giant MPs (>10000 tiles): the MP extends far beyond the generation bbox (usually
    a relation boundary tens of km out). Skip the split and return empty; the caller handles "no
    scatter possible". }
  if Int64(Tx) * Int64(Tz) > 10000 then Exit;

  SetLength(Result, Tx * Tz);   { worst case }
  OutCount := 0;

  for Cx := 0 to Tx - 1 do
    for Cz := 0 to Tz - 1 do
    begin
      TileX0 := MinX + Cx * TileSizeM;
      TileX1 := MinX + (Cx + 1) * TileSizeM;
      if TileX1 > MaxX then TileX1 := MaxX;
      TileZ0 := MinZ + Cz * TileSizeM;
      TileZ1 := MinZ + (Cz + 1) * TileSizeM;
      if TileZ1 > MaxZ then TileZ1 := MaxZ;

      ClippedOuter := ClipRingToRect(MP.Outer, TileX0, TileZ0, TileX1, TileZ1);
      if Length(ClippedOuter) < 3 then Continue;

      Sub.Outer := ClippedOuter;
      { Pre-alloc inners upper bound = original inner count; track real count, compact at the end. }
      SetLength(Sub.Inners, Length(MP.Inners));
      InnersCount := 0;

      for I := 0 to High(MP.Inners) do
      begin
        ClippedInner := ClipRingToRect(MP.Inners[I], TileX0, TileZ0, TileX1, TileZ1);
        if Length(ClippedInner) >= 3 then
        begin
          Sub.Inners[InnersCount] := ClippedInner;
          Inc(InnersCount);
        end;
      end;
      SetLength(Sub.Inners, InnersCount);

      Result[OutCount] := Sub;
      Inc(OutCount);
    end;

  SetLength(Result, OutCount);
end;

function NoUVTransform: TUVTransform;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(415);{$ENDIF}
  Result.Active  := False;
  Result.OriginX := 0;
  Result.OriginZ := 0;
  Result.CosA    := 1;
  Result.SinA    := 0;
  Result.ScaleX  := 1;
  Result.ScaleY  := 1;
  Result.FlipY   := False;
end;

procedure ApplyUVTransform(const Tx: TUVTransform; X, Z: Double;
  out U, V: Double);
var
  DX, DZ, RX, RZ: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(416);{$ENDIF}
  if not Tx.Active then
  begin
    U := X;
    V := Z;
    Exit;
  end;
  DX := X - Tx.OriginX;
  DZ := Z - Tx.OriginZ;
  RX := DX * Tx.CosA - DZ * Tx.SinA;
  RZ := DX * Tx.SinA + DZ * Tx.CosA;
  RX := RX * Tx.ScaleX;
  RZ := RZ * Tx.ScaleY;
  U := RX;
  if Tx.FlipY then
    V := -RZ
  else
    V := RZ;
end;

function BuildOrientedUVTransform(
  const MP: TPolygonMultipolygon;
  Orientation: TSurfaceUVOrientation;
  Stretch: Boolean): TUVTransform;
var
  Pts: TOMBBPointArray;
  I, J, K, NTotal: Integer;
  Corners: TOMBBCorners;
  RotVec0X, RotVec0Y: Double;
  RotVec1X, RotVec1Y: Double;
  Len0, Len1: Double;
  NeedsFlip: Boolean;
  Angle: Double;
  TmpX, TmpY, TmpL: Double;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(417);{$ENDIF}
  Result := NoUVTransform;

  { Collect all multipolygon points (outer + inners) for the convex hull —
    inners are included so the OMBB covers the entire footprint
    (matching streets-gl getOMBBInput). }
  NTotal := Length(MP.Outer);
  for I := 0 to High(MP.Inners) do
    Inc(NTotal, Length(MP.Inners[I]));

  if NTotal < 3 then Exit;       { degenerate, has no orientation }

  SetLength(Pts, NTotal);
  K := 0;
  for I := 0 to High(MP.Outer) do
  begin
    Pts[K].X := MP.Outer[I].X;
    Pts[K].Z := MP.Outer[I].Z;
    Inc(K);
  end;
  for J := 0 to High(MP.Inners) do
    for I := 0 to High(MP.Inners[J]) do
    begin
      Pts[K].X := MP.Inners[J][I].X;
      Pts[K].Z := MP.Inners[J][I].Z;
      Inc(K);
    end;

  Corners := TOMBB.Compute(Pts);

  RotVec0X := Corners[2].X - Corners[1].X;
  RotVec0Y := Corners[2].Z - Corners[1].Z;
  RotVec1X := Corners[0].X - Corners[1].X;
  RotVec1Y := Corners[0].Z - Corners[1].Z;
  Len0 := Sqrt(RotVec0X * RotVec0X + RotVec0Y * RotVec0Y);
  Len1 := Sqrt(RotVec1X * RotVec1X + RotVec1Y * RotVec1Y);

  if (Len0 < 1e-9) or (Len1 < 1e-9) then Exit;

  case Orientation of
    suoAlong:  NeedsFlip := Len0 > Len1;
    suoAcross: NeedsFlip := Len0 < Len1;
  else
    NeedsFlip := False;
  end;

  if NeedsFlip then
  begin
    TmpX := RotVec0X; TmpY := RotVec0Y; TmpL := Len0;
    RotVec0X := RotVec1X; RotVec0Y := RotVec1Y; Len0 := Len1;
    RotVec1X := TmpX; RotVec1Y := TmpY; Len1 := TmpL;
  end;

  { angle = -atan2(rotVec0.y, rotVec0.x) кладёт rotVec0 на ось X. }
  Angle := -ArcTan2(RotVec0Y, RotVec0X);

  Result.Active  := True;
  Result.OriginX := Corners[1].X;
  Result.OriginZ := Corners[1].Z;
  Result.CosA    := Cos(Angle);
  Result.SinA    := Sin(Angle);
  if Stretch then
  begin
    Result.ScaleX := 1.0 / Len0;
    Result.ScaleY := 1.0 / Len1;
  end
  else
  begin
    Result.ScaleX := 1.0;
    Result.ScaleY := 1.0;
  end;
  Result.FlipY := True;
end;

class function TSurfaceTextures.GetDescriptor(KindIdx: TSurfaceKindIndex): TSurfaceDescriptor;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1151);{$ENDIF}
  if (KindIdx < 0) or (KindIdx >= SURFACE_KIND_COUNT) then
  begin
    Result.Name := 'invalid';
    Result.TexturePath := '';
    Result.NormalPath := '';
    Result.UVScale := 0;
    Result.IsOriented := False;
    Result.Stretch := False;
    Result.Orientation := suoAlong;
    Exit;
  end;
  Result := SURFACE_DESCRIPTORS[KindIdx];
end;

class function TSurfaceTextures.CreateImageTexture(const TexturePath: string;
  RepeatST: Boolean): TImageTextureNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1152);{$ENDIF}
  Result := nil;
  if TexturePath = '' then Exit;
  if not FileExists(TexturePath) then Exit;

  Result := TImageTextureNode.Create;
  Result.FdUrl.Send([TexturePath]);
  {$IFDEF TEX_SIZE_PROFILE}ProfileTexNode(Result, 'surf');{$ENDIF}
  Result.RepeatS := RepeatST;
  Result.RepeatT := RepeatST;
end;

class function TSurfaceTextures.CreateForKind(KindIdx: TSurfaceKindIndex): TImageTextureNode;
var Desc: TSurfaceDescriptor;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1153);{$ENDIF}
  Desc := GetDescriptor(KindIdx);
  { isOriented + Stretch (football/basket/tennis/helipad) → clamp; small
    UV overruns at polygon edges would otherwise produce visible seams.
    Everything else repeats. }
  Result := CreateImageTexture(Desc.TexturePath,
    not (Desc.IsOriented and Desc.Stretch));
end;

class function TSurfaceTextures.CreateNormalForKind(KindIdx: TSurfaceKindIndex): TImageTextureNode;
var Desc: TSurfaceDescriptor;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1154);{$ENDIF}
  Desc := GetDescriptor(KindIdx);
  Result := CreateImageTexture(Desc.NormalPath,
    not (Desc.IsOriented and Desc.Stretch));
end;

initialization

{ Осознанно глобально, на весь процесс: численный тракт геометрии (карв,
  нодинг, drape, проекции) исторически рассчитан на замаскированные
  FPU-исключения — деление на нуль/переполнение в промежуточных Single дают
  Inf/NaN, которые отсекаются позже по смыслу, а не через EInvalidOp/
  EZeroDivide. Снятие маски или перенос её в точечные save/set/restore
  меняет численное поведение ВСЕГО тракта (любое вычисление могло
  полагаться на неё), поэтому этап 2 её НЕ трогает: «зонтик» над
  конкретным вычислением выделить нельзя, не перепроверив весь юнит и его
  вызывающих. Побочный эффект (маска применяется ко всем потокам процесса,
  т.к. 8087 CW — per-thread, но ставится здесь один раз на старте в main и
  наследуется воркерами) зафиксирован как принятое поведение движка. }
Math.SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide,
    exOverflow, exUnderflow, exPrecision]);

end.
