unit Osm3dRoadDistField;

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$codepage UTF8}

{$WARN 5091 OFF}

interface

uses
  Classes,
  SysUtils,
  Math,
  CastleImages,
  CastleVectors,
  CastleRenderOptions,
  X3DNodes,
  Osm3dGeoMath,
  Osm3dOsmData,
  Osm3dGeomRoads
  {$IFDEF TEX_SIZE_PROFILE}, Osm3dTexProfile{$ENDIF}
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
;          { TRoadBuilder.ParseRoadParams + TRoadParams }

const
  { Distance from the road EDGE at which the sandy mix fades to 0.
    Streets-gl visual: ~3-6 m. }
  ROAD_HALO_RADIUS_M_DEFAULT     = 6.0;

  { World metres per texel. 2 m → ~512² per 1 km chunk. }
  ROAD_FIELD_M_PER_TEXEL_DEFAULT = 2.0;

  { Caps memory and stays inside low-end GL_MAX_TEXTURE_SIZE. }
  ROAD_FIELD_MAX_DIM             = 2048;

  { Padding around supplied bbox so edge-touching halos don't clip
    (HaloRadius + 2 m safety). }
  ROAD_FIELD_PADDING_M           = 8.0;

type
  TDFRoadSegment = record
    X0, Z0:   Single;
    DX, DZ:   Single;
    LenSq:    Single;
    LenInv:   Single;
    HalfW:    Single;
    HalfWSq:  Single;
    { AABB inflated by HalfW + HaloRadius. }
    BBoxMinX, BBoxMaxX: Single;
    BBoxMinZ, BBoxMaxZ: Single;
  end;
  TDFRoadSegmentArray = array of TDFRoadSegment;

  PDFRoadSegment = ^TDFRoadSegment;

  TRoadDistField = class
  private
    FSegs:        TDFRoadSegmentArray;
    FSegCount:    Integer;

    FOriginX, FOriginZ: Single;       { world XZ of texel (0,0) }
    FSizeX,   FSizeZ:   Single;
    FWidth,   FHeight:  Integer;
    FHaloRadiusM:  Single;
    FMPerTexel:    Single;

    FImage:    TGrayscaleImage;       { built by Build, consumed by CreateTextureNode }
    FTexture:  TPixelTextureNode;     { non-nil after CreateTextureNode; owns the image }

    procedure GrowSegs;
    procedure RasterisePass(LogProc: TLogProc);
    procedure BlurPass(LogProc: TLogProc);
  public
    constructor Create(HaloRadiusM: Single = ROAD_HALO_RADIUS_M_DEFAULT;
                       MPerTexel:    Single = ROAD_FIELD_M_PER_TEXEL_DEFAULT);
    destructor Destroy; override;

    { Bbox in local-projection XZ metres. Texture enlarged by
      ROAD_FIELD_PADDING_M on each side; resolution clamped to MAX_DIM. }
    procedure SetWorldBounds(MinX, MinZ, MaxX, MaxZ: Single);

    { HalfWidth = TRoadParams.Width * 0.5. }
    procedure AddSegment(X0, Z0, X1, Z1, HalfWidth: Single);

    { Iterate dataset, classify each way, project, AddSegment for each
      segment. Mirrors Osm3dGeomRoadMask.BuildFromDataset but without
      tree-clearance pad — halo runs to the actual ribbon edge. }
    procedure AddFromDataset(Dataset: TOSMDataset;
                             Projection: TLocalProjection);

    { Rasterise + blur. Requires SetWorldBounds + ≥1 AddSegment.
      Idempotent — re-rasterises from FSegs each call. }
    procedure Build(LogProc: TLogProc = nil);

    { Transfers FImage ownership to the returned node. Call once per
      Build; image lifetime is then the X3D scene's. }
    function CreateTextureNode: TPixelTextureNode;

    property OriginX: Single  read FOriginX;
    property OriginZ: Single  read FOriginZ;
    property SizeX:   Single  read FSizeX;
    property SizeZ:   Single  read FSizeZ;
    property Width:   Integer read FWidth;
    property Height:  Integer read FHeight;
    property HaloRadiusM: Single read FHaloRadiusM;
    property MPerTexel:   Single read FMPerTexel;
    property SegmentCount: Integer read FSegCount;
  end;

implementation

constructor TRoadDistField.Create(HaloRadiusM, MPerTexel: Single);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1237);{$ENDIF}
  inherited Create;
  FHaloRadiusM := Max(0.1, HaloRadiusM);
  FMPerTexel   := Max(0.1, MPerTexel);
  SetLength(FSegs, 256);
  FSegCount := 0;
  FImage    := nil;
  FTexture  := nil;
  FWidth    := 0;
  FHeight   := 0;
end;

destructor TRoadDistField.Destroy;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1238);{$ENDIF}
  { If image was built but CreateTextureNode never called, free it.
    FTexture is owned by the X3D scene after handover. }
  if FImage <> nil then
  begin
    FImage.Free;
    FImage := nil;
  end;
  SetLength(FSegs, 0);
  inherited Destroy;
end;

procedure TRoadDistField.GrowSegs;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(723);{$ENDIF}
  SetLength(FSegs, Length(FSegs) * 2);
end;

procedure TRoadDistField.SetWorldBounds(MinX, MinZ, MaxX, MaxZ: Single);
var
  Span: Single;
  Dim:  Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(724);{$ENDIF}
  MinX := MinX - ROAD_FIELD_PADDING_M;
  MinZ := MinZ - ROAD_FIELD_PADDING_M;
  MaxX := MaxX + ROAD_FIELD_PADDING_M;
  MaxZ := MaxZ + ROAD_FIELD_PADDING_M;

  FOriginX := MinX;
  FOriginZ := MinZ;
  FSizeX   := Max(1.0, MaxX - MinX);
  FSizeZ   := Max(1.0, MaxZ - MinZ);

  { Pick dim from MPerTexel; on huge chunks grow MPerTexel so dim stays
    bounded. Post-blur is low-frequency so fatter texels are forgiving. }
  Span := Max(FSizeX, FSizeZ);
  Dim  := Ceil(Span / FMPerTexel);
  if Dim > ROAD_FIELD_MAX_DIM then
  begin
    Dim := ROAD_FIELD_MAX_DIM;
    FMPerTexel := Span / Dim;
  end;
  if Dim < 16 then Dim := 16;

  FWidth  := Ceil(FSizeX / FMPerTexel);
  FHeight := Ceil(FSizeZ / FMPerTexel);
  if FWidth  > ROAD_FIELD_MAX_DIM then FWidth  := ROAD_FIELD_MAX_DIM;
  if FHeight > ROAD_FIELD_MAX_DIM then FHeight := ROAD_FIELD_MAX_DIM;
  if FWidth  < 16 then FWidth  := 16;
  if FHeight < 16 then FHeight := 16;
end;

procedure TRoadDistField.AddSegment(X0, Z0, X1, Z1, HalfWidth: Single);
var
  S: TDFRoadSegment;
  Len, HaloPad: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(725);{$ENDIF}
  S.X0    := X0;  S.Z0    := Z0;
  S.DX    := X1 - X0;
  S.DZ    := Z1 - Z0;
  S.LenSq := S.DX * S.DX + S.DZ * S.DZ;
  if S.LenSq < 0.01 then Exit;
  Len := Sqrt(S.LenSq);
  S.LenInv  := 1.0 / Len;
  S.HalfW   := Max(0.5, HalfWidth);
  S.HalfWSq := S.HalfW * S.HalfW;

  HaloPad := S.HalfW + FHaloRadiusM;
  S.BBoxMinX := Min(X0, X1) - HaloPad;
  S.BBoxMaxX := Max(X0, X1) + HaloPad;
  S.BBoxMinZ := Min(Z0, Z1) - HaloPad;
  S.BBoxMaxZ := Max(Z0, Z1) + HaloPad;

  if FSegCount >= Length(FSegs) then GrowSegs;
  FSegs[FSegCount] := S;
  Inc(FSegCount);
end;

procedure TRoadDistField.AddFromDataset(Dataset: TOSMDataset;
  Projection: TLocalProjection);
var
  Way: TOSMWay;
  Params: TRoadParams;
  HalfW: Single;
  I: Integer;
  NA, NB: TOSMNode;
  PA, PB: TVector3;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(726);{$ENDIF}
  if (Dataset = nil) or (Projection = nil) then Exit;
  for Way in Dataset.Ways.Values do
  begin
    if Way = nil then Continue;
    Params := TRoadBuilder.ParseRoadParams(Way.Tags);
    if Params.Kind = rkNone then Continue;
    { No sandy halo under a bridge — the deck floats above the ground, so a
      sandy line painted on the terrain there would show through the gap. }
    if OsmWayIsBridge(Way.Tags) then Continue;
    { …и под туннелем: полотно в трубе под землёй, песчаное гало на поверхности
      над ним бессмысленно. }
    if OsmWayIsTunnel(Way.Tags) then Continue;
    { Halo only for paved roadways. Unpaved dirt/sand already fade into
      terrain via widthScale=1.7 + alpha edge; railway has ballast feel;
      foot/cycleways are too narrow. }
    if not (Params.Kind in [rkMajor, rkSecondary, rkMinor, rkService]) then
      Continue;
    if not (Params.Material in [pmAsphalt, pmConcrete, pmCobblestone, pmWood]) then
      Continue;
    HalfW := Params.Width * 0.5;
    for I := 0 to Length(Way.NodeRefs) - 2 do
    begin
      NA := Dataset.FindNode(Way.NodeRefs[I]);
      NB := Dataset.FindNode(Way.NodeRefs[I + 1]);
      if (NA = nil) or (NB = nil) then Continue;
      PA := Projection.Project(NA.Position, 0);
      PB := Projection.Project(NB.Position, 0);
      AddSegment(PA.X, PA.Z, PB.X, PB.Z, HalfW);
    end;
  end;
end;

procedure TRoadDistField.RasterisePass(LogProc: TLogProc);
{ Coarse spatial grid for segment lookup. Without it the inner loop
  scans every segment for every pixel — 4889 segs × 2048 × 1971 = 19.7 G
  AABB tests, 43 s wall time. Binning into a ~64-cell grid drops this
  ~1000×. }
var
  X, Y: Integer;
  WorldX, WorldZ: Single;
  I, K, GIdx: Integer;
  S: PDFRoadSegment;
  t, Cx, Cz, DSq, D, BeyondEdge, Factor, BestFactor: Single;
  Row: PByte;
  TexelM: Single;
  GridCols, GridRows: Integer;
  GridCellSizeX, GridCellSizeZ: Single;
  GridStarts:    array of Integer;     { length cols*rows + 1, prefix-sum }
  GridIndices:   array of Integer;
  GridCellCount: array of Integer;     { temp: count per cell }
  Cell0X, Cell1X, Cell0Z, Cell1Z, CellX, CellZ, CellIdx: Integer;
  TotalGridEntries: Integer;
  WritePos: Integer;
  PixCellX, PixCellZ, PixCellIdx, RangeBeg, RangeEnd: Integer;

  { Диапазон ячеек сетки, перекрываемых bbox сегмента (с клампом к сетке).
    False — сегмент целиком вне сетки. Общий код для Pass A и Pass C. }
  function SegCellRange(ASeg: PDFRoadSegment;
    out C0X, C1X, C0Z, C1Z: Integer): Boolean;
  begin
    C0X := Trunc((ASeg^.BBoxMinX - FOriginX) / GridCellSizeX);
    C1X := Trunc((ASeg^.BBoxMaxX - FOriginX) / GridCellSizeX);
    C0Z := Trunc((ASeg^.BBoxMinZ - FOriginZ) / GridCellSizeZ);
    C1Z := Trunc((ASeg^.BBoxMaxZ - FOriginZ) / GridCellSizeZ);
    if C0X < 0 then C0X := 0;
    if C1X >= GridCols then C1X := GridCols - 1;
    if C0Z < 0 then C0Z := 0;
    if C1Z >= GridRows then C1Z := GridRows - 1;
    Result := not ((C1X < 0) or (C0X >= GridCols)
                or (C1Z < 0) or (C0Z >= GridRows));
  end;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(727);{$ENDIF}
  if FImage = nil then
    FImage := TGrayscaleImage.Create(FWidth, FHeight);
  FImage.Clear(Vector4Byte(0, 0, 0, 0));

  TexelM := FMPerTexel;

  { SetLength below initialises these; explicit nil silences FPC 5091. }
  GridStarts    := nil;
  GridIndices   := nil;
  GridCellCount := nil;

  { Aim for ~50-100 m per cell (1-3 cells per typical segment).
    Capped at 128² to keep memory tiny. }
  GridCols := Max(1, Round(FSizeX / 64.0));
  if GridCols > 128 then GridCols := 128;
  GridRows := Max(1, Round(FSizeZ / 64.0));
  if GridRows > 128 then GridRows := 128;
  GridCellSizeX := FSizeX / GridCols;
  GridCellSizeZ := FSizeZ / GridRows;

  { Pass A: count entries per cell. }
  SetLength(GridCellCount, GridCols * GridRows);
  for I := 0 to High(GridCellCount) do GridCellCount[I] := 0;
  for I := 0 to FSegCount - 1 do
  begin
    S := @FSegs[I];
    if not SegCellRange(S, Cell0X, Cell1X, Cell0Z, Cell1Z) then Continue;
    for CellZ := Cell0Z to Cell1Z do
      for CellX := Cell0X to Cell1X do
        Inc(GridCellCount[CellZ * GridCols + CellX]);
  end;

  { Pass B: prefix-sum into GridStarts; pre-alloc GridIndices. }
  SetLength(GridStarts, GridCols * GridRows + 1);
  GridStarts[0] := 0;
  TotalGridEntries := 0;
  for I := 0 to GridCols * GridRows - 1 do
  begin
    Inc(TotalGridEntries, GridCellCount[I]);
    GridStarts[I + 1] := TotalGridEntries;
  end;
  SetLength(GridIndices, TotalGridEntries);

  { Pass C: scatter indices using GridCellCount as a decrementing write cursor. }
  for I := 0 to High(GridCellCount) do GridCellCount[I] := 0;
  for I := 0 to FSegCount - 1 do
  begin
    S := @FSegs[I];
    if not SegCellRange(S, Cell0X, Cell1X, Cell0Z, Cell1Z) then Continue;
    for CellZ := Cell0Z to Cell1Z do
      for CellX := Cell0X to Cell1X do
      begin
        CellIdx := CellZ * GridCols + CellX;
        WritePos := GridStarts[CellIdx] + GridCellCount[CellIdx];
        GridIndices[WritePos] := I;
        Inc(GridCellCount[CellIdx]);
      end;
  end;

  { Main rasterise loop — consults only the pixel's grid cell. }
  for Y := 0 to FHeight - 1 do
  begin
    Row := PByte(FImage.PixelPtr(0, Y));
    WorldZ := FOriginZ + (Y + 0.5) * TexelM;
    PixCellZ := Trunc((WorldZ - FOriginZ) / GridCellSizeZ);
    if PixCellZ < 0 then PixCellZ := 0
    else if PixCellZ >= GridRows then PixCellZ := GridRows - 1;

    for X := 0 to FWidth - 1 do
    begin
      WorldX := FOriginX + (X + 0.5) * TexelM;
      PixCellX := Trunc((WorldX - FOriginX) / GridCellSizeX);
      if PixCellX < 0 then PixCellX := 0
      else if PixCellX >= GridCols then PixCellX := GridCols - 1;
      PixCellIdx := PixCellZ * GridCols + PixCellX;
      RangeBeg := GridStarts[PixCellIdx];
      RangeEnd := GridStarts[PixCellIdx + 1];

      BestFactor := 0.0;
      for K := RangeBeg to RangeEnd - 1 do
      begin
        GIdx := GridIndices[K];
        S := @FSegs[GIdx];

        { AABB reject still needed: a 64 m cell can hold a segment in
          one corner while the pixel sits in the opposite corner. }
        if (WorldX < S^.BBoxMinX) or (WorldX > S^.BBoxMaxX) or
           (WorldZ < S^.BBoxMinZ) or (WorldZ > S^.BBoxMaxZ) then
          Continue;

        { Project pixel onto segment, clamp t to [0,1]. }
        t := ((WorldX - S^.X0) * S^.DX + (WorldZ - S^.Z0) * S^.DZ) / S^.LenSq;
        if t < 0.0 then t := 0.0
        else if t > 1.0 then t := 1.0;
        Cx := S^.X0 + t * S^.DX;
        Cz := S^.Z0 + t * S^.DZ;
        DSq := (WorldX - Cx) * (WorldX - Cx) + (WorldZ - Cz) * (WorldZ - Cz);

        { Mask = 1 inside footprint, linear ramp over HaloRadius outside. }
        if DSq <= S^.HalfWSq then
          Factor := 1.0
        else
        begin
          D := Sqrt(DSq);
          BeyondEdge := D - S^.HalfW;
          if BeyondEdge >= FHaloRadiusM then
            Continue
          else
            Factor := 1.0 - BeyondEdge / FHaloRadiusM;
        end;

        if Factor > BestFactor then
          BestFactor := Factor;

        if BestFactor >= 1.0 then Break;     { peak — early-exit }
      end;

      if BestFactor <= 0 then
        PByte(Row)[X] := 0
      else if BestFactor >= 1 then
        PByte(Row)[X] := 255
      else
        PByte(Row)[X] := Byte(Round(BestFactor * 255.0));
    end;
  end;

  if Assigned(LogProc) then
    LogProc(Format(
      '  RoadDistField: rasterised %d×%d at %.2f m/texel, %d segments, ' +
      'halo=%.1f m, grid=%d×%d (%d index entries)',
      [FWidth, FHeight, FMPerTexel, FSegCount, FHaloRadiusM,
       GridCols, GridRows, TotalGridEntries]));
end;

procedure TRoadDistField.BlurPass(LogProc: TLogProc);
{ Separable 5-tap Gaussian, σ ≈ 1.4 texel. Coefficients sum to 1:
    [0.06, 0.24, 0.40, 0.24, 0.06]
  Streets-gl uses 9-tap blur9; we trade a slightly thinner halo for
  ~2× speed, indistinguishable at typical zooms.

  Both passes are split into a clamped-edge region (the first / last
  two rows or columns, where a tap would fall off the image) and a
  clamp-free interior. The interior is the overwhelming majority of
  texels, and there the four per-tap bounds tests are gone entirely. }
const
  K0: Single = 0.06;
  K1: Single = 0.24;
  K2: Single = 0.40;
var
  W, H, W2, X, Y, Y0, Y1, Y3, Y4, Idx: Integer;
  Tmp: array of Byte;
  Src, Dst, Base: PByte;

  function Clamp(AV: Single): Byte; inline;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(1623);{$ENDIF}
    if AV <= 0 then Result := 0
    else if AV >= 255 then Result := 255
    else Result := Byte(Round(AV));
  end;

  { Clamped horizontal tap — used only for the 2 edge columns. }
  function SampleX(Row: PByte; AW, Xc: Integer): Single;
  var X0, X1, X3, X4: Integer;
  begin
    {$IFDEF IAM_LIVE}IamLiveTrack(729);{$ENDIF}
    X0 := Xc - 2; if X0 < 0  then X0 := 0;
    X1 := Xc - 1; if X1 < 0  then X1 := 0;
    X3 := Xc + 1; if X3 >= AW then X3 := AW - 1;
    X4 := Xc + 2; if X4 >= AW then X4 := AW - 1;
    Result :=  Row[X0] * K0 + Row[X1] * K1 + Row[Xc] * K2
             + Row[X3] * K1 + Row[X4] * K0;
  end;

begin
  {$IFDEF IAM_LIVE}IamLiveTrack(728);{$ENDIF}
  if FImage = nil then Exit;
  W := FWidth;  H := FHeight;
  if (W = 0) or (H = 0) then Exit;
  W2 := W + W;

  { Horizontal pass — write into tmp row, then copy back. }
  if W >= H then SetLength(Tmp, W) else SetLength(Tmp, H);
  for Y := 0 to H - 1 do
  begin
    Src := PByte(FImage.PixelPtr(0, Y));
    if W <= 4 then
    begin
      for X := 0 to W - 1 do
        Tmp[X] := Clamp(SampleX(Src, W, X));
    end
    else
    begin
      Tmp[0] := Clamp(SampleX(Src, W, 0));
      Tmp[1] := Clamp(SampleX(Src, W, 1));
      { Interior: every tap is in range, no clamping. }
      for X := 2 to W - 3 do
        Tmp[X] := Clamp( Src[X-2] * K0 + Src[X-1] * K1 + Src[X] * K2
                       + Src[X+1] * K1 + Src[X+2] * K0 );
      Tmp[W-2] := Clamp(SampleX(Src, W, W - 2));
      Tmp[W-1] := Clamp(SampleX(Src, W, W - 1));
    end;
    Dst := PByte(FImage.PixelPtr(0, Y));
    Move(Tmp[0], Dst^, W);
  end;

  { Vertical pass — walk each column over RawPixels. Rows are W
 bytes apart, so a vertical tap is +/- W on the index. }
  Base := PByte(FImage.RawPixels);
  for X := 0 to W - 1 do
  begin
    if H <= 4 then
    begin
      for Y := 0 to H - 1 do
      begin
        Y0 := Y - 2; if Y0 < 0  then Y0 := 0;
        Y1 := Y - 1; if Y1 < 0  then Y1 := 0;
        Y3 := Y + 1; if Y3 >= H then Y3 := H - 1;
        Y4 := Y + 2; if Y4 >= H then Y4 := H - 1;
        Tmp[Y] := Clamp( Base[Y0 * W + X] * K0
                       + Base[Y1 * W + X] * K1
                       + Base[Y  * W + X] * K2
                       + Base[Y3 * W + X] * K1
                       + Base[Y4 * W + X] * K0 );
      end;
    end
    else
    begin
      { Edge rows 0 and 1 — clamped. }
      for Y := 0 to 1 do
      begin
        Y0 := Y - 2; if Y0 < 0 then Y0 := 0;
        Y1 := Y - 1; if Y1 < 0 then Y1 := 0;
        Tmp[Y] := Clamp( Base[Y0 * W + X] * K0
                       + Base[Y1 * W + X] * K1
                       + Base[Y  * W + X] * K2
                       + Base[(Y+1) * W + X] * K1
                       + Base[(Y+2) * W + X] * K0 );
      end;
      { Interior rows 2..H-3 — no clamp; Idx walks +W per step. }
      Idx := 2 * W + X;
      for Y := 2 to H - 3 do
      begin
        Tmp[Y] := Clamp( Base[Idx - W2] * K0
                       + Base[Idx - W ] * K1
                       + Base[Idx     ] * K2
                       + Base[Idx + W ] * K1
                       + Base[Idx + W2] * K0 );
        Inc(Idx, W);
      end;
      { Edge rows H-2 and H-1 — clamped. }
      for Y := H - 2 to H - 1 do
      begin
        Y3 := Y + 1; if Y3 >= H then Y3 := H - 1;
        Y4 := Y + 2; if Y4 >= H then Y4 := H - 1;
        Tmp[Y] := Clamp( Base[(Y-2) * W + X] * K0
                       + Base[(Y-1) * W + X] * K1
                       + Base[Y     * W + X] * K2
                       + Base[Y3    * W + X] * K1
                       + Base[Y4    * W + X] * K0 );
      end;
    end;
    { Write the blurred column back. }
    for Y := 0 to H - 1 do
      Base[Y * W + X] := Tmp[Y];
  end;

  if Assigned(LogProc) then
    LogProc('  RoadDistField: Gaussian blurred 5-tap separable');
end;

procedure TRoadDistField.Build(LogProc: TLogProc);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(731);{$ENDIF}
  if (FWidth = 0) or (FHeight = 0) then
    raise EInvalidOperation.Create(
      'TRoadDistField.Build: SetWorldBounds must be called first');

  RasterisePass(LogProc);
  BlurPass(LogProc);
end;

function TRoadDistField.CreateTextureNode: TPixelTextureNode;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(732);{$ENDIF}
  if FImage = nil then
    raise EInvalidOperation.Create(
      'TRoadDistField.CreateTextureNode: Build must be called first');
  if FTexture <> nil then
    raise EInvalidOperation.Create(
      'TRoadDistField.CreateTextureNode: already created');

  FTexture := TPixelTextureNode.Create;
  { TSFImage.Value := image transfers image ownership to the SF field;
    must null FImage to avoid a double-free in our destructor. }
  FTexture.FdImage.Value := FImage;
  {$IFDEF TEX_SIZE_PROFILE}ProfileTexNode(FTexture, 'distf');{$ENDIF}
  FImage := nil;

  { Linear filter hides per-texel quantisation. RepeatS/T=False — raster
    covers exactly the chunk; coords outside [0,1] would tile garbage. }
  FTexture.RepeatS := False;
  FTexture.RepeatT := False;

  Result := FTexture;
end;

end.
