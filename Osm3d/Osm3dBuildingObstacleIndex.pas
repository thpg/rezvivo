unit Osm3dBuildingObstacleIndex;

{ ═══════════════════════════════════════════════════════════════════════════
  BUILDING_OBSTACLE (runtime spatial index)

  Purpose: prevent cinematic camera / rider from going through buildings
  WITHOUT mesh colliders or per-frame full polygon scans (FPS-safe).

  Data source: TBuildingShadowCaster footprints (foundation polygons) already
  built with buildings (Osm3dGeomBuildings). KeepGroundUnder casters (courtyards,
  building=roof) are skipped — same policy as BuildHoleNodeMask.

  Structure:
    • flat array of obstacles (footprint XZ ring + BaseY/MaxY + AABB)
    • uniform grid (cell size CELL_M) mapping cell → list of obstacle indices
    • query O(1) cell lookup + O(k) PointInPolygonXZ, k usually 0..3

  Lifecycle (see callers marked BUILDING_OBSTACLE):
    1) SplitInputToTiles  — store obstacles on TTileModel (serialised to cache)
    2) Mount/Activate tile — AddTile into session world index
    3) Unmount tile       — RemoveTile
    4) Game camera/rider  — TryQuery / TryPushOut / ResolveCamera

  Mark every integration site with:  // BUILDING_OBSTACLE
  ═══════════════════════════════════════════════════════════════════════════ }

{$mode objfpc}{$H+}
{$codepage UTF8}

interface

uses
  Classes, SysUtils, Math,
  Generics.Collections,
  CastleVectors, Osm3dDetourTypes,
  Osm3dGeomBuildings,   { TBuildingShadowCaster / TBuildingShadowCasters }
  Osm3dGeoMath;         { PointInPolygonXZ }

const
  { BUILDING_OBSTACLE: grid cell size in world metres. }
  BUILDING_OBSTACLE_CELL_M = 16.0;
  { Push margin outside footprint (m) so rider/camera don't stick to wall. }
  BUILDING_OBSTACLE_MARGIN_M = 0.35;
  { Shared by route endpoint placement and every detour graph edge. }
  BUILDING_ROUTE_CLEARANCE_M = 0.20;
  { Soft lift above MaxY when camera is deep inside building volume. }
  BUILDING_OBSTACLE_LIFT_MARGIN_M = 0.6;

type
  TIntegerDynArray = array of Integer;

  { Compact obstacle used at runtime (and stored on TTileModel).
    Footprint XZ is tile-local on disk / on TTileModel; world-space after
    offset at mount (see OffsetObstaclesXZ). }
  TBuildingObstacle = record
    Footprint: array of TVector3;  { CCW XZ, Y unused }
    BaseY:     Single;
    MaxY:      Single;
    MinX, MaxX, MinZ, MaxZ: Single;  { AABB for cheap reject }
    TileKey:   Int64;              { owning tile (for RemoveTile) }
  end;
  TBuildingObstacleArray = array of TBuildingObstacle;

  { Session-wide index: all loaded tiles' buildings. }
  TBuildingObstacleIndex = class
  private
    FObs: array of TBuildingObstacle;
    FCount: Integer;
    { Grid: sparse dictionary cellKey -> dynamic array of obstacle indices. }
    FCells: specialize TDictionary<Int64, TIntegerDynArray>;
    FOriginX, FOriginZ: Single;  { world origin for cell quantisation (0,0 ok) }
    procedure ClearCells;
    procedure InsertIntoGrid(AIdx: Integer);
    function CellKey(CX, CZ: Integer): Int64; inline;
    procedure WorldToCell(WX, WZ: Single; out CX, CZ: Integer); inline;
    function FindObstacleAt(WX, WZ: Single; out ObsIdx: Integer;
      Clearance: Single = 0): Boolean;
  public
    constructor Create;
    destructor Destroy; override;

    procedure Clear;

    { Add all casters for one tile. Skips KeepGroundUnder / bad footprints.
      TileKey identifies the tile for later RemoveTile. }
    procedure AddFromCasters(const Casters: TBuildingShadowCasters;
      ATileKey: Int64);

    { Add pre-built obstacles (e.g. from TTileModel after load + world offset). }
    procedure AddObstacles(const Arr: TBuildingObstacleArray; ATileKey: Int64);

    { Remove every obstacle registered under ATileKey. }
    procedure RemoveTile(ATileKey: Int64);

    { True if (WX,WZ) is inside a solid building footprint.
      BaseY/MaxY = foundation top / roof apex. }
    function TryQuery(WX, WZ: Single;
      out ABaseY, AMaxY: Single): Boolean;

    { If point is inside a building, push XZ to nearest edge + margin.
      Clearance > 0 also moves exterior points too close to a wall.
      Returns True if a push was applied (X,Z updated). Y untouched. }
    function TryPushOutXZ(var WX, WZ: Single;
      out ABaseY, AMaxY: Single; Clearance: Single = 0): Boolean;

    { Bounded local visibility graph for the route preparation worker.
      Never called by the riding loop. }
    function FindDetour(const Start, Target: TVector3;
      out Points: TDetourPoints): TDetourResult;
    function SnapshotNear(WX, WZ, Radius: Single): TBuildingObstacleArray;

    { Camera: if inside building XZ, push out; if cam Y is below MaxY+margin
      and still near footprint, soft-lift Y. Returns True if cam was moved. }
    function ResolveCamera(var Cam: TVector3): Boolean;

    property Count: Integer read FCount;
  end;

{ BUILDING_OBSTACLE: convert casters → obstacle array (for TTileModel storage).
  Coordinates stay in the same frame as the caster footprints (chunk-local
  before RebaseTileToConventional; tile-local after). }
function CastersToObstacles(const Casters: TBuildingShadowCasters): TBuildingObstacleArray;

{ BUILDING_OBSTACLE: copy obstacles and shift XZ by (OX,OZ) — tile-local → world. }
function OffsetObstaclesXZ(const Arr: TBuildingObstacleArray;
  OX, OZ: Single; ScaleX: Double = 1): TBuildingObstacleArray;

{ BUILDING_OBSTACLE: recompute AABB after footprint mutation. }
procedure RebuildObstacleAABB(var O: TBuildingObstacle);

{ BUILDING_OBSTACLE: stable tile key (same scheme as SplitInputToTiles TileKey64). }
function BuildingObstacleTileKey(Zone: Byte; North: Boolean;
  TX, TY: Integer): Int64;

implementation

function BuildingObstacleTileKey(Zone: Byte; North: Boolean;
  TX, TY: Integer): Int64;
begin
  Result := (Int64(Zone) shl 56)
         or (Int64(Ord(North)) shl 55)
         or (Int64(TX and $FFFFFF) shl 24)
         or  Int64(TY and $FFFFFF);
end;

procedure RebuildObstacleAABB(var O: TBuildingObstacle);
var
  J: Integer;
begin
  { BUILDING_OBSTACLE }
  O.MinX :=  1e30; O.MaxX := -1e30;
  O.MinZ :=  1e30; O.MaxZ := -1e30;
  for J := 0 to High(O.Footprint) do
  begin
    if O.Footprint[J].X < O.MinX then O.MinX := O.Footprint[J].X;
    if O.Footprint[J].X > O.MaxX then O.MaxX := O.Footprint[J].X;
    if O.Footprint[J].Z < O.MinZ then O.MinZ := O.Footprint[J].Z;
    if O.Footprint[J].Z > O.MaxZ then O.MaxZ := O.Footprint[J].Z;
  end;
end;

function CastersToObstacles(const Casters: TBuildingShadowCasters): TBuildingObstacleArray;
var
  I, J, N, OutN: Integer;
  O: TBuildingObstacle;
begin
  { BUILDING_OBSTACLE }
  SetLength(Result, Length(Casters));
  OutN := 0;
  for I := 0 to High(Casters) do
  begin
    if Casters[I].KeepGroundUnder then Continue;
    N := Length(Casters[I].Footprint);
    if N < 3 then Continue;
    O := Default(TBuildingObstacle);
    SetLength(O.Footprint, N);
    for J := 0 to N - 1 do
    begin
      O.Footprint[J] := Casters[I].Footprint[J];
      O.Footprint[J].Y := 0;
    end;
    RebuildObstacleAABB(O);
    O.BaseY := Casters[I].BaseY;
    O.MaxY  := Casters[I].MaxY;
    if O.MaxY < O.BaseY + 1.0 then
      O.MaxY := O.BaseY + 3.0;   { fallback envelope }
    O.TileKey := 0;
    Result[OutN] := O;
    Inc(OutN);
  end;
  SetLength(Result, OutN);
end;

function OffsetObstaclesXZ(const Arr: TBuildingObstacleArray;
  OX, OZ: Single; ScaleX: Double): TBuildingObstacleArray;
var
  I, J: Integer;
begin
  { BUILDING_OBSTACLE }
  SetLength(Result, Length(Arr));
  for I := 0 to High(Arr) do
  begin
    Result[I] := Arr[I];
    SetLength(Result[I].Footprint, Length(Arr[I].Footprint));
    for J := 0 to High(Arr[I].Footprint) do
    begin
      Result[I].Footprint[J].X := Arr[I].Footprint[J].X * ScaleX + OX;
      Result[I].Footprint[J].Y := 0;
      Result[I].Footprint[J].Z := Arr[I].Footprint[J].Z + OZ;
    end;
    Result[I].MinX := Arr[I].MinX * ScaleX + OX;
    Result[I].MaxX := Arr[I].MaxX * ScaleX + OX;
    Result[I].MinZ := Arr[I].MinZ + OZ;
    Result[I].MaxZ := Arr[I].MaxZ + OZ;
  end;
end;

constructor TBuildingObstacleIndex.Create;
begin
  inherited Create;
  FCells := specialize TDictionary<Int64, TIntegerDynArray>.Create;
  FCount := 0;
  FOriginX := 0;
  FOriginZ := 0;
end;

destructor TBuildingObstacleIndex.Destroy;
begin
  Clear;
  FreeAndNil(FCells);
  inherited;
end;

procedure TBuildingObstacleIndex.ClearCells;
begin
  FCells.Clear;
end;

procedure TBuildingObstacleIndex.Clear;
begin
  { BUILDING_OBSTACLE }
  SetLength(FObs, 0);
  FCount := 0;
  ClearCells;
end;

function TBuildingObstacleIndex.CellKey(CX, CZ: Integer): Int64;
begin
  Result := (Int64(CX) shl 32) xor (Int64(CZ) and $FFFFFFFF);
end;

procedure TBuildingObstacleIndex.WorldToCell(WX, WZ: Single; out CX, CZ: Integer);
begin
  CX := Floor((WX - FOriginX) / BUILDING_OBSTACLE_CELL_M);
  CZ := Floor((WZ - FOriginZ) / BUILDING_OBSTACLE_CELL_M);
end;

procedure TBuildingObstacleIndex.InsertIntoGrid(AIdx: Integer);
var
  CX0, CZ0, CX1, CZ1, CX, CZ, K: Integer;
  Key: Int64;
  Arr: TIntegerDynArray;
begin
  with FObs[AIdx] do
  begin
    WorldToCell(MinX, MinZ, CX0, CZ0);
    WorldToCell(MaxX, MaxZ, CX1, CZ1);
  end;
  for CZ := CZ0 to CZ1 do
    for CX := CX0 to CX1 do
    begin
      Key := CellKey(CX, CZ);
      if FCells.TryGetValue(Key, Arr) then
      begin
        K := Length(Arr);
        SetLength(Arr, K + 1);
        Arr[K] := AIdx;
        FCells.AddOrSetValue(Key, Arr);
      end
      else
      begin
        SetLength(Arr, 1);
        Arr[0] := AIdx;
        FCells.Add(Key, Arr);
      end;
    end;
end;

procedure TBuildingObstacleIndex.AddObstacles(const Arr: TBuildingObstacleArray;
  ATileKey: Int64);
var
  I, Base: Integer;
begin
  { BUILDING_OBSTACLE }
  if Length(Arr) = 0 then Exit;
  Base := FCount;
  FCount := FCount + Length(Arr);
  SetLength(FObs, FCount);
  for I := 0 to High(Arr) do
  begin
    FObs[Base + I] := Arr[I];
    FObs[Base + I].TileKey := ATileKey;
    InsertIntoGrid(Base + I);
  end;
end;

procedure TBuildingObstacleIndex.AddFromCasters(
  const Casters: TBuildingShadowCasters; ATileKey: Int64);
begin
  { BUILDING_OBSTACLE }
  AddObstacles(CastersToObstacles(Casters), ATileKey);
end;

procedure TBuildingObstacleIndex.RemoveTile(ATileKey: Int64);
var
  I, NewN: Integer;
  NewObs: array of TBuildingObstacle;
begin
  { BUILDING_OBSTACLE: compact array and rebuild grid (rare: tile unload). }
  if FCount = 0 then Exit;
  SetLength(NewObs, FCount);
  NewN := 0;
  for I := 0 to FCount - 1 do
    if FObs[I].TileKey <> ATileKey then
    begin
      NewObs[NewN] := FObs[I];
      Inc(NewN);
    end;
  if NewN = FCount then Exit;   { nothing removed }
  SetLength(NewObs, NewN);
  ClearCells;
  FObs := NewObs;
  FCount := NewN;
  for I := 0 to FCount - 1 do
    InsertIntoGrid(I);
end;

function PointEdgeDist2(const V, E0, E1: TVector3): Single;
var T, DX, DZ, Len2: Single;
begin
  DX:=E1.X-E0.X; DZ:=E1.Z-E0.Z; Len2:=Sqr(DX)+Sqr(DZ);
  if Len2<1e-8 then Exit(Sqr(V.X-E0.X)+Sqr(V.Z-E0.Z));
  T:=EnsureRange(((V.X-E0.X)*DX+(V.Z-E0.Z)*DZ)/Len2,0.0,1.0);
  Result:=Sqr(V.X-E0.X-T*DX)+Sqr(V.Z-E0.Z-T*DZ);
end;

function TBuildingObstacleIndex.FindObstacleAt(WX, WZ: Single;
  out ObsIdx: Integer; Clearance: Single): Boolean;
var
  CX, CZ, X0, X1, Z0, Z1, I, J, Idx: Integer;
  Arr: TIntegerDynArray;
  P: TVector3;
  Blocked: Boolean;
begin
  Result := False;
  ObsIdx := -1;
  if FCount = 0 then Exit;
  { The nearest wall may belong to the neighbouring spatial cell. }
  WorldToCell(WX-Clearance, WZ-Clearance, X0, Z0);
  WorldToCell(WX+Clearance, WZ+Clearance, X1, Z1);
  P := Vector3(WX, 0, WZ);
  for CZ:=Z0 to Z1 do for CX:=X0 to X1 do
  if FCells.TryGetValue(CellKey(CX,CZ), Arr) then
  for I := 0 to High(Arr) do
  begin
    Idx := Arr[I];
    if (Idx < 0) or (Idx >= FCount) then Continue;
    with FObs[Idx] do
    begin
      if (WX < MinX-Clearance) or (WX > MaxX+Clearance) or
         (WZ < MinZ-Clearance) or (WZ > MaxZ+Clearance) then
        Continue;
      Blocked:=PointInPolygonXZ(P, Footprint);
      if (not Blocked) and (Clearance>0) then
        for J:=0 to High(Footprint) do
          if PointEdgeDist2(P,Footprint[J],Footprint[(J+1) mod Length(Footprint)])<Sqr(Clearance) then
          begin Blocked:=True; Break end;
      if Blocked then
      begin
        ObsIdx := Idx;
        Exit(True);
      end;
    end;
  end;
end;

function TBuildingObstacleIndex.TryQuery(WX, WZ: Single;
  out ABaseY, AMaxY: Single): Boolean;
var
  Idx: Integer;
begin
  { BUILDING_OBSTACLE }
  Result := FindObstacleAt(WX, WZ, Idx);
  if Result then
  begin
    ABaseY := FObs[Idx].BaseY;
    AMaxY  := FObs[Idx].MaxY;
  end
  else
  begin
    ABaseY := 0;
    AMaxY  := 0;
  end;
end;

function ClosestEdgePush(const PX, PZ: Single;
  const Poly: array of TVector3; Margin: Single;
  out OutX, OutZ: Single): Boolean;
var
  N, I, J: Integer;
  Ax, Az, Bx, Bz, ABx, ABz, APx, APz, Len2, T, Qx, Qz, Dx, Dz, Dist, Best: Single;
  Nx, Nz, NLen: Single;
  Inside: Boolean;
  Area: Double;
begin
  { BUILDING_OBSTACLE: nearest point on polygon edges + outward push. }
  Result := False;
  N := Length(Poly);
  if N < 3 then Exit;
  Inside:=PointInPolygonXZ(Vector3(PX,0,PZ),Poly);
  Area:=0;
  for I:=0 to N-1 do
  begin
    J:=(I+1) mod N;
    Area:=Area+(Double(Poly[I].X)-Poly[0].X)*(Double(Poly[J].Z)-Poly[0].Z)
      -(Double(Poly[J].X)-Poly[0].X)*(Double(Poly[I].Z)-Poly[0].Z);
  end;
  Best := 1e30;
  OutX := PX;
  OutZ := PZ;
  for I := 0 to N - 1 do
  begin
    J := (I + 1) mod N;
    Ax := Poly[I].X; Az := Poly[I].Z;
    Bx := Poly[J].X; Bz := Poly[J].Z;
    ABx := Bx - Ax; ABz := Bz - Az;
    Len2 := ABx * ABx + ABz * ABz;
    if Len2 < 1e-8 then Continue;
    APx := PX - Ax; APz := PZ - Az;
    T := (APx * ABx + APz * ABz) / Len2;
    if T < 0 then T := 0 else if T > 1 then T := 1;
    Qx := Ax + T * ABx;
    Qz := Az + T * ABz;
    Dx := PX - Qx;
    Dz := PZ - Qz;
    Dist := Sqrt(Dx * Dx + Dz * Dz);
    if Dist < Best then
    begin
      Best := Dist;
      { Outward normal, including points exactly on a wall, for either winding. }
      Nx := ABz;
      Nz := -ABx;
      if Area<0 then begin Nx:=-Nx; Nz:=-Nz end;
      NLen := Sqrt(Nx * Nx + Nz * Nz);
      if NLen > 1e-6 then
      begin
        Nx := Nx / NLen;
        Nz := Nz / NLen;
      end
      else
      begin
        Nx := 0;
        Nz := 0;
      end;
      { If almost on edge, use normal; else push from closest point outward }
      if Dist < 1e-4 then
      begin
        OutX := Qx + Nx * Margin;
        OutZ := Qz + Nz * Margin;
      end
      else
      begin
        { Interior points cross the wall; exterior points stay on their side. }
        if Inside then begin Dx:=-Dx; Dz:=-Dz end;
        OutX := Qx + (Dx / Dist) * Margin;
        OutZ := Qz + (Dz / Dist) * Margin;
      end;
      Result := True;
    end;
  end;
end;

function TBuildingObstacleIndex.TryPushOutXZ(var WX, WZ: Single;
  out ABaseY, AMaxY: Single; Clearance: Single): Boolean;
var
  Idx: Integer;
  NX, NZ: Single;
  Guard: Integer;
begin
  { BUILDING_OBSTACLE: up to 3 pushes if nested/overlapping footprints. }
  Result := False;
  ABaseY := 0;
  AMaxY := 0;
  for Guard := 0 to 2 do
  begin
    if not FindObstacleAt(WX, WZ, Idx, Clearance) then Break;
    ABaseY := FObs[Idx].BaseY;
    AMaxY  := FObs[Idx].MaxY;
    if ClosestEdgePush(WX, WZ, FObs[Idx].Footprint,
         Max(BUILDING_OBSTACLE_MARGIN_M,Clearance+0.05), NX, NZ) then
    begin
      WX := NX;
      WZ := NZ;
      Result := True;
    end
    else
      Break;
  end;
end;


function TBuildingObstacleIndex.SnapshotNear(WX, WZ, Radius: Single): TBuildingObstacleArray;
var I,N: Integer;
begin
  Result:=nil; N:=0;
  Radius:=EnsureRange(Radius,1.0,200.0);
  for I:=0 to FCount-1 do
    with FObs[I] do
      if (MaxX>=WX-Radius) and (MinX<=WX+Radius) and
         (MaxZ>=WZ-Radius) and (MinZ<=WZ+Radius) then
      begin
        SetLength(Result,N+1); Result[N]:=FObs[I]; Inc(N);
      end;
end;

function TBuildingObstacleIndex.FindDetour(const Start, Target: TVector3;
  out Points: TDetourPoints): TDetourResult;
const
  MaxNodes = 1024;
  MaxObstacles = 256;
  Clearance = BUILDING_ROUTE_CLEARANCE_M;
  CornerMargin = 1.5;
var
  Ids: array[0..MaxObstacles-1] of Integer;
  Nodes: array[0..MaxNodes-1] of TVector3;
  Dist: array[0..MaxNodes-1] of Single;
  Prev: array[0..MaxNodes-1] of Integer;
  Done: array[0..MaxNodes-1] of Boolean;
  NC, OC, X0, X1, Z0, Z1, X, Z, I, J, K, Idx, Best, P, PointCount: Integer;
  Cell: TIntegerDynArray;
  Seen: Boolean;
  A, B, C, N1, N2, Q: TVector3;
  Area: Double;
  L, DotN, D, BestD: Single;

  function Cross2(const U, V, W: TVector3): Double;
  begin
    Result := (Double(V.X)-U.X)*(Double(W.Z)-U.Z)
      -(Double(V.Z)-U.Z)*(Double(W.X)-U.X);
  end;

  function ClearLine(const U, V: TVector3): Boolean;
  var O, E, F: Integer; E0,E1: TVector3; C0,C1,C2,C3: Double;
  begin
    Result:=False;
    for O:=0 to OC-1 do
    with FObs[Ids[O]] do
    begin
      if (Min(U.X,V.X)>MaxX+Clearance) or (Max(U.X,V.X)<MinX-Clearance)
        or (Min(U.Z,V.Z)>MaxZ+Clearance) or (Max(U.Z,V.Z)<MinZ-Clearance) then Continue;
      if PointInPolygonXZ(U,Footprint) or PointInPolygonXZ(V,Footprint) then Exit;
      for E:=0 to High(Footprint) do
      begin
        F:=(E+1) mod Length(Footprint); E0:=Footprint[E]; E1:=Footprint[F];
        C0:=Cross2(U,V,E0); C1:=Cross2(U,V,E1);
        C2:=Cross2(E0,E1,U); C3:=Cross2(E0,E1,V);
        if (C0*C1<0) and (C2*C3<0) then Exit;
        if Min(Min(PointEdgeDist2(U,E0,E1),PointEdgeDist2(V,E0,E1)),
          Min(PointEdgeDist2(E0,U,V),PointEdgeDist2(E1,U,V)))<Sqr(Clearance) then Exit;
      end;
    end;
    Result:=True;
  end;

begin
  Points:=nil;
  Result:=drUnavailable;
  if Sqr(Target.X-Start.X)+Sqr(Target.Z-Start.Z)>Sqr(160.0) then Exit;
  OC:=0;
  WorldToCell(Min(Start.X,Target.X)-12,Min(Start.Z,Target.Z)-12,X0,Z0);
  WorldToCell(Max(Start.X,Target.X)+12,Max(Start.Z,Target.Z)+12,X1,Z1);
  for Z:=Z0 to Z1 do for X:=X0 to X1 do
    if FCells.TryGetValue(CellKey(X,Z),Cell) then
      for I:=0 to High(Cell) do
      begin
        Idx:=Cell[I]; Seen:=False;
        for J:=0 to OC-1 do if Ids[J]=Idx then begin Seen:=True; Break end;
        if Seen then Continue;
        if OC=MaxObstacles then Exit;
        Ids[OC]:=Idx; Inc(OC);
      end;
  if ClearLine(Start,Target) then Exit(drClear);
  { The destination needs the same wall clearance as every graph edge.
    A point just outside a footprint can still be unreachable; let route
    preparation skip it, exactly like a point inside the building. }
  if not ClearLine(Target,Target) then Exit(drTargetBlocked);
  Nodes[0]:=Start; Nodes[1]:=Target; NC:=2;
  for I:=0 to OC-1 do
  with FObs[Ids[I]] do
  begin
    Area:=0;
    for J:=0 to High(Footprint) do
    begin
      K:=(J+1) mod Length(Footprint);
      Area:=Area+(Double(Footprint[J].X)-Footprint[0].X)*(Double(Footprint[K].Z)-Footprint[0].Z)
        -(Double(Footprint[K].X)-Footprint[0].X)*(Double(Footprint[J].Z)-Footprint[0].Z);
    end;
    for J:=0 to High(Footprint) do
    begin
      A:=Footprint[(J+Length(Footprint)-1) mod Length(Footprint)];
      B:=Footprint[J]; C:=Footprint[(J+1) mod Length(Footprint)];
      N1:=Vector3(B.Z-A.Z,0,A.X-B.X); L:=N1.Length;
      if L<0.001 then Continue; N1:=N1/L;
      N2:=Vector3(C.Z-B.Z,0,B.X-C.X); L:=N2.Length;
      if L<0.001 then Continue; N2:=N2/L;
      if Area<0 then begin N1:=-N1; N2:=-N2 end;
      Q:=N1+N2; DotN:=Q.X*N1.X+Q.Z*N1.Z;
      if DotN<0.15 then Continue;
      Q:=B+Q*(CornerMargin/DotN); Q.Y:=Start.Y;
      if not ClearLine(Q,Q) then Continue;
      if NC=MaxNodes then Exit;
      Nodes[NC]:=Q; Inc(NC);
    end;
  end;
  for I:=0 to NC-1 do begin Dist[I]:=1e30; Prev[I]:=-1; Done[I]:=False end;
  Dist[0]:=0;
  for K:=0 to NC-1 do
  begin
    Best:=-1; BestD:=1e30;
    for I:=0 to NC-1 do if (not Done[I]) and (Dist[I]<BestD) then
      begin Best:=I; BestD:=Dist[I] end;
    if Best<0 then Exit;
    if Best=1 then Break;
    Done[Best]:=True;
    for I:=1 to NC-1 do if not Done[I] then
    begin
      D:=BestD+Sqrt(Sqr(Nodes[I].X-Nodes[Best].X)+Sqr(Nodes[I].Z-Nodes[Best].Z));
      if (D<Dist[I]) and ClearLine(Nodes[Best],Nodes[I]) then
        begin Dist[I]:=D; Prev[I]:=Best end;
    end;
  end;
  if Prev[1]<0 then Exit;
  PointCount:=0; P:=1;
  while P<>0 do begin Inc(PointCount); P:=Prev[P]; if P<0 then Exit end;
  SetLength(Points,PointCount); P:=1;
  for I:=PointCount-1 downto 0 do begin Points[I]:=Nodes[P]; P:=Prev[P] end;
  Result:=drFound;
end;

function TBuildingObstacleIndex.ResolveCamera(var Cam: TVector3): Boolean;
var
  X, Z, BaseY, MaxY: Single;
  Pushed: Boolean;
begin
  { BUILDING_OBSTACLE: camera push-out + soft roof lift. }
  Result := False;
  X := Cam.X;
  Z := Cam.Z;
  Pushed := TryPushOutXZ(X, Z, BaseY, MaxY);
  if Pushed then
  begin
    Cam.X := X;
    Cam.Z := Z;
    Result := True;
  end;
  { If still over a building (push failed / deep inside) or after push still
    under roof height when near previous footprint — lift above MaxY. }
  if TryQuery(Cam.X, Cam.Z, BaseY, MaxY) then
  begin
    if Cam.Y < MaxY + BUILDING_OBSTACLE_LIFT_MARGIN_M then
    begin
      Cam.Y := MaxY + BUILDING_OBSTACLE_LIFT_MARGIN_M;
      Result := True;
    end;
  end
  else if Pushed and (Cam.Y < MaxY + BUILDING_OBSTACLE_LIFT_MARGIN_M) then
  begin
    { Just exited footprint but camera was below roof — soft lift once. }
    if Cam.Y < MaxY then
    begin
      Cam.Y := MaxY + BUILDING_OBSTACLE_LIFT_MARGIN_M * 0.5;
      Result := True;
    end;
  end;
end;

end.
