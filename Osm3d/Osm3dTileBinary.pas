unit Osm3dTileBinary;

{$mode objfpc}{$H+}{$codepage UTF8}
{$Q-}{$R-}

{ O3DTBIN1: independently compressed, checksummed typed arrays. No XML/JSON
  inside the file. See cache-tools/TILE_CACHE_FORMAT.md and tile_cache.py. }
interface

uses Classes, SysUtils, Osm3dTileX3D;

type
  ETileBinaryError = class(Exception);
  TTileBinaryLayers = set of (tblMeshes, tblTrees, tblPOIs, tblRoads,
    tblBuildings, tblModels, tblManholes);
  TTileBinary = class
  public
    class procedure SaveFile(const FileName: string; Model: TTileModel); static;
    class function LoadFile(const FileName: string;
      Layers: TTileBinaryLayers = [tblMeshes, tblTrees, tblPOIs, tblRoads,
        tblBuildings, tblModels, tblManholes]): TTileModel; static;
    { Header-only dependency for the route snap cache; includes origin/identity. }
    class function RoadFingerprint(const FileName: string): string; static;
    { Offline audit: validate every compressed chunk without constructing mesh
      arrays. At most one decoded chunk is resident; caller owns metadata. }
    class function ValidateFile(const FileName: string;
      Cancel: TThread = nil): TTileModel; static;
  end;

implementation

uses Math, TypInfo, PasZLib, CastleVectors, Osm3dGeomMesh,
  Osm3dGeoTileGrid, Osm3dGeomPOI, Osm3dSceneMaterials, Osm3dGeoMath,
  Osm3dRoadSurface, Osm3dBuildingObstacleIndex, Osm3dManholeData, Osm3dFacadeLayout;

const
  MAGIC: array[0..7] of AnsiChar = 'O3DTBIN1';
  MAX_CHUNK = 512 * 1024 * 1024;
  MAX_STRING = 1024 * 1024;
  MAX_CHUNKS = 65536;
  REQUIRED_LAYERS: array[0..6] of string = ('META', 'TREE', 'POIS', 'ROAD', 'BULD', 'MODL', 'MHOL');

type
  TThreadAccess=class(TThread);
  THeader = packed record
    Magic: array[0..7] of AnsiChar;
    Version, Endian, Count, Reserved: LongWord;
    Directory: QWord;
  end;
  TEntry = packed record
    Kind: array[0..3] of AnsiChar;
    Flags: LongWord;
    Offset, PackedSize, RawSize: QWord;
    CRC, Reserved: LongWord;
  end;
  TEntries = array of TEntry;
  TBytes = array of Byte;
  TUInts = array of LongWord;
  TStrings = array of string;
  TPN = packed record Position, Normal: TVector3 end;
  TPNArray = array of TPN;
  TUVArray = array of TVector2;
  TTreeWire = packed record
    X, Y, Z, Scale, Rotation, Seed: Single;
    Flags, TypePlusOne: LongWord;
    LatE7, LonE7: LongInt;
  end;
  TTreesWire = array of TTreeWire;
  TPOIWire = packed record
    Kind: LongWord; Position: TVector3; Rotation: Single;
  end;
  TPOIsWire = array of TPOIWire;
  TRoadWire = packed record
    P0, P1: LongWord;
    Width: Single; WayId: Int64; Flags: LongWord;
    ForwardLanes, BackwardLanes: LongInt;
    UVMin, UVMax, UVScale: Single;
    Marked, Asphalt, Condition, BothWays, Custom: LongInt;
    Edge: Single; LaneOffset, LaneCount: LongWord;
  end;
  TRoadsWire = array of TRoadWire;
  TBuildingWire = packed record
    BaseY, MaxY: Single; First, Count: LongWord;
  end;
  TBuildingsWire = array of TBuildingWire;
  TModelWire = packed record
    FileIndex: LongWord;
    Position: TVector3; Rotation: TVector4; Scale: TVector3;
  end;
  TModelsWire = array of TModelWire;
  TManholeWire = packed record
    Position, Normal: TVector3; Rotation: Single; Kind: LongInt;
  end;
  TManholesWire = array of TManholeWire;

  TTileReader = class
    FileStream: TFileStream;
    Entries: TEntries;
    constructor Create(const FileName: string);
    destructor Destroy; override;
    function Chunk(I: Integer): TMemoryStream;
  end;

procedure Require(Condition: Boolean; const Reason: string); inline;
begin
  if not Condition then raise ETileBinaryError.Create('Binary tile: ' + Reason);
end;

procedure CheckPlatform;
var X: LongWord;
begin
  X := 1;
  Require((PByte(@X)^ = 1) and (SizeOf(Single) = 4) and
    (SizeOf(TVector3) = 12) and (SizeOf(TVector2) = 8) and
    (SizeOf(THeader) = 32) and (SizeOf(TEntry) = 40),
    'unsupported host representation (little-endian IEEE754 required)');
end;

procedure WriteU(S: TStream; V: LongWord); inline;
begin S.WriteBuffer(V, 4) end;

function ReadU(S: TStream): LongWord; inline;
begin S.ReadBuffer(Result, 4) end;

procedure WriteString(S: TStream; const V: string);
begin
  Require(Length(V) <= MAX_STRING, 'string too long');
  WriteU(S, Length(V));
  if V <> '' then S.WriteBuffer(V[1], Length(V));
end;

function ReadString(S: TStream): string;
var N: LongWord;
begin
  N := ReadU(S);
  Require((N <= MAX_STRING) and (N <= S.Size-S.Position), 'invalid UTF-8 string length');
  SetLength(Result, N);
  if N <> 0 then S.ReadBuffer(Result[1], N);
end;

procedure WriteArray(S: TStream; P: Pointer; N, Stride: SizeInt);
begin
  Require((N >= 0) and (Int64(N)*Stride <= MAX_CHUNK), 'array too large');
  if N <> 0 then S.WriteBuffer(P^, N*Stride);
end;

procedure ReadArray(S: TStream; P: Pointer; N, Stride: SizeInt);
begin
  Require((N >= 0) and (Int64(N)*Stride <= S.Size-S.Position), 'truncated array');
  if N <> 0 then S.ReadBuffer(P^, N*Stride);
end;

function Count(S: TStream; Stride: Integer): Integer;
var N: LongWord;
begin
  N := ReadU(S);
  Require((N <= MAX_CHUNK div Stride) and
    (Int64(N)*Stride <= S.Size-S.Position), 'invalid array count');
  Result := N;
end;

procedure ExactSize(S: TStream; Expected: Int64);
begin Require(Expected = S.Size-S.Position, 'inconsistent payload size') end;

procedure CheckFloats(P: PSingle; N: SizeInt);
var I: SizeInt; Bits: LongWord;
begin
  for I := 0 to N-1 do
  begin
    Move(P[I], Bits, 4);
    Require((Bits and $7F800000) <> $7F800000, 'non-finite float');
  end;
end;

function KindIs(const E: TEntry; const K: string): Boolean; inline;
begin Result := CompareMem(@E.Kind[0], @K[1], 4) end;

constructor TTileReader.Create(const FileName: string);
var H: THeader; I: Integer; LastEnd, Total: QWord; Seen: TStringList; K: string;
begin
  inherited Create;
  CheckPlatform;
  FileStream := TFileStream.Create(FileName, fmOpenRead or fmShareDenyWrite);
  FileStream.ReadBuffer(H, SizeOf(H));
  Require((H.Magic = MAGIC) and (H.Version = 1) and
    (H.Endian = $01020304) and (H.Directory = 32) and (H.Reserved = 0), 'bad header/version');
  Require((H.Count >= 7) and (H.Count <= MAX_CHUNKS) and
    (32+Int64(H.Count)*40 <= FileStream.Size), 'bad directory length');
  SetLength(Entries, H.Count);
  FileStream.ReadBuffer(Entries[0], Length(Entries)*40);
  LastEnd := FileStream.Position; Total := 0;
  Seen := TStringList.Create;
  try
    for I := 0 to High(Entries) do
      with Entries[I] do
      begin
        Require((Flags <= 1) and (Reserved = 0) and (RawSize >= 4) and
          (RawSize <= MAX_CHUNK) and (PackedSize > 0) and
          (PackedSize <= MAX_CHUNK) and (Offset = LastEnd) and
          (Offset <= QWord(FileStream.Size)) and
          (PackedSize <= QWord(FileStream.Size)-Offset), 'invalid chunk bounds');
        Require((Flags = 1) or (PackedSize = RawSize), 'raw size mismatch');
        SetString(K, PAnsiChar(@Kind[0]), 4);
        if K <> 'MESH' then
        begin
          Require(Seen.IndexOf(K) < 0, 'duplicate layer ' + K);
          Seen.Add(K);
        end;
        Inc(Total, RawSize);
        Require(Total <= QWord(4)*1024*1024*1024, 'tile exceeds size limit');
        LastEnd := Offset+PackedSize;
      end;
    Require(LastEnd = QWord(FileStream.Size), 'trailing or missing bytes');
    for K in REQUIRED_LAYERS do
      Require(Seen.IndexOf(K) >= 0, 'missing layer ' + K);
  finally Seen.Free end;
end;

destructor TTileReader.Destroy;
begin FileStream.Free; inherited end;

function TTileReader.Chunk(I: Integer): TMemoryStream;
var Encoded: TBytes; N: LongWord; Code: Integer;
begin
  Result := TMemoryStream.Create;
  try
    with Entries[I] do
    begin
      Result.Size := RawSize;
      FileStream.Position := Offset;
      if Flags = 0 then FileStream.ReadBuffer(Result.Memory^, RawSize)
      else
      begin
        SetLength(Encoded, PackedSize);
        FileStream.ReadBuffer(Encoded[0], Length(Encoded));
        N := RawSize;
        Code := PasZLib.uncompress(PChar(Result.Memory), N,
          PChar(@Encoded[0]), Length(Encoded));
        Require((Code = Z_OK) and (N = RawSize), 'invalid zlib stream');
      end;
      Require(PasZLib.crc32(0, PChar(Result.Memory), RawSize) = CRC, 'CRC32 mismatch');
    end;
  except Result.Free; raise end;
end;

procedure WriteMeta(S: TStream; M: TTileModel);
begin
  WriteU(S, M.TileId.Zone); WriteU(S, Ord(M.TileId.North));
  WriteU(S, M.TileId.TX); WriteU(S, M.TileId.TY);
  S.WriteBuffer(M.Origin.Lat, 8); S.WriteBuffer(M.Origin.Lon, 8);
  S.WriteBuffer(M.Box.MinLat, 8); S.WriteBuffer(M.Box.MinLon, 8);
  S.WriteBuffer(M.Box.MaxLat, 8); S.WriteBuffer(M.Box.MaxLon, 8);
  WriteString(S, M.GenHash);
end;

procedure ReadMeta(S: TStream; M: TTileModel);
var Zone, North, TX, TY: LongWord; EmptyBox: TLatLonBox;
begin
  Zone := ReadU(S); North := ReadU(S); TX := ReadU(S); TY := ReadU(S);
  Require((Zone <= 60) and (North <= 1), 'invalid tile identity');
  M.TileId := TGeoTileId.Make(Zone, North <> 0, TX, TY);
  S.ReadBuffer(M.Origin.Lat, 8); S.ReadBuffer(M.Origin.Lon, 8);
  S.ReadBuffer(M.Box.MinLat, 8); S.ReadBuffer(M.Box.MinLon, 8);
  S.ReadBuffer(M.Box.MaxLat, 8); S.ReadBuffer(M.Box.MaxLon, 8);
  EmptyBox := TLatLonBox.Empty;
  Require((Abs(M.Origin.Lat) <= 90) and (Abs(M.Origin.Lon) <= 180) and
    (CompareMem(@M.Box, @EmptyBox, SizeOf(EmptyBox)) or
    ((Abs(M.Box.MinLat) <= 90) and (Abs(M.Box.MaxLat) <= 90) and
    (Abs(M.Box.MinLon) <= 180) and (Abs(M.Box.MaxLon) <= 180))), 'invalid geographic bounds');
  M.GenHash := ReadString(S);
end;

procedure WriteMesh(S: TStream; const R: TTileMeshRec);
var V: TMeshVertexArray; Indices: TMeshIndexArray; PN: TPNArray;
  UV: TUVArray; Remap, Table: TUInts; OSM: TInt64Array;
  I, J, P, PC, Mask: Integer; H, B, Flags: LongWord;
  Item: TPN; HasOSM, Pool: Boolean;
begin
  Require(R.Mesh <> nil, 'nil mesh');
  V := R.Mesh.Vertices; Indices := R.Mesh.Indices;
  Require((Length(Indices) mod 3 = 0) and
    ((Length(R.MatIds) = 0) or (Length(R.MatIds) = Length(V))) and
    ((Length(R.WaterScale) = 0) or (Length(R.WaterScale) = Length(V))), 'invalid mesh arrays');
  Pool := (Length(V) > 0) and (Length(R.MatIds) = Length(V));
  SetLength(PN, Length(V)); SetLength(UV, Length(V)); HasOSM := False;
  PC := 0; Mask := 0;
  if Pool then
  begin
    SetLength(Remap, Length(V));
    J := 16; while J < Length(V)*2 do J := J*2;
    SetLength(Table, J); Mask := J-1;
  end;
  for I := 0 to High(V) do
  begin
    Item.Position := V[I].Position; Item.Normal := V[I].Normal;
    UV[I] := V[I].UV; HasOSM := HasOSM or (V[I].OsmId <> 0);
    if Pool then
    begin
      H := 2166136261;
      for J := 0 to 5 do
      begin Move(PSingle(@Item)[J], B, 4); H := (H xor B)*16777619 end;
      P := H and LongWord(Mask);
      while Table[P] <> 0 do
      begin
        if CompareMem(@PN[Table[P]-1], @Item, SizeOf(Item)) then Break;
        P := (P+1) and Mask;
      end;
      if Table[P] = 0 then
      begin PN[PC] := Item; Inc(PC); Table[P] := PC end;
      Remap[I] := Table[P]-1;
    end else begin PN[PC] := Item; Inc(PC) end;
  end;
  Table := nil;
  if HasOSM then
  begin
    SetLength(OSM, Length(V));
    for I := 0 to High(V) do OSM[I] := V[I].OsmId;
  end;
  for I := 0 to High(Indices) do Require(Indices[I] < LongWord(Length(V)), 'mesh index out of range');
  for I := 0 to High(R.BorderIdx) do
    Require((R.BorderIdx[I] >= 0) and (R.BorderIdx[I] < Length(V)), 'border index out of range');
  WriteString(S, R.Name);
  WriteString(S, GetEnumName(TypeInfo(TSceneMaterialKind), Ord(R.Material)));
  Flags := Ord(R.Solid); if Pool then Flags := Flags or 2;
  WriteU(S, Flags); WriteU(S, Length(V)); WriteU(S, PC); WriteU(S, Length(Indices));
  WriteU(S, Length(R.MatIds)); WriteU(S, Length(R.WaterScale));
  WriteU(S, Length(OSM)); WriteU(S, Length(R.BorderIdx));
  WriteArray(S, Pointer(PN), PC, 24);
  if Pool then WriteArray(S, Pointer(Remap), Length(Remap), 4);
  WriteArray(S, Pointer(UV), Length(UV), 8);
  WriteArray(S, Pointer(Indices), Length(Indices), 4);
  WriteArray(S, Pointer(R.MatIds), Length(R.MatIds), 4);
  WriteArray(S, Pointer(R.WaterScale), Length(R.WaterScale), 4);
  WriteArray(S, Pointer(OSM), Length(OSM), 8);
  WriteArray(S, Pointer(R.BorderIdx), Length(R.BorderIdx), 4);
end;

procedure ReadMesh(S: TStream; M: TTileModel);
var Name, Material: string; Flags, VC, PC, IC, MC, WC, OC, BC: LongWord;
  Remap: TUInts; PN: TPNArray; UV: TUVArray; V: TMeshVertexArray;
  Indices: TMeshIndexArray; MatIds, Border: TTileMatIdArray;
  Water: TTileWaterScaleArray; OSM: TInt64Array; Mesh: TMesh;
  I, P, EnumValue: Integer; Expected: Int64;
begin
  Name := ReadString(S); Material := ReadString(S);
  EnumValue := GetEnumValue(TypeInfo(TSceneMaterialKind), Material);
  Require(EnumValue >= 0, 'unknown mesh material ' + Material);
  Flags := ReadU(S); VC := ReadU(S); PC := ReadU(S); IC := ReadU(S);
  MC := ReadU(S); WC := ReadU(S); OC := ReadU(S); BC := ReadU(S);
  Require((Flags <= 3) and (VC <= MAX_CHUNK div SizeOf(TMeshVertex)) and
    (PC <= VC) and (IC mod 3 = 0) and ((MC = 0) or (MC = VC)) and
    ((WC = 0) or (WC = VC)) and ((OC = 0) or (OC = VC)) and
    (((Flags and 2) <> 0) or (PC = VC)), 'invalid mesh counts');
  Expected := Int64(PC)*24+Int64(VC)*8+Int64(IC)*4+Int64(MC)*4+
    Int64(WC)*4+Int64(OC)*8+Int64(BC)*4;
  if Flags and 2 <> 0 then Inc(Expected, Int64(VC)*4);
  ExactSize(S, Expected);
  SetLength(PN, PC); ReadArray(S, Pointer(PN), PC, 24);
  CheckFloats(PSingle(Pointer(PN)), SizeInt(PC)*6);
  if Flags and 2 <> 0 then
  begin SetLength(Remap, VC); ReadArray(S, Pointer(Remap), VC, 4) end;
  SetLength(UV, VC); ReadArray(S, Pointer(UV), VC, 8);
  CheckFloats(PSingle(Pointer(UV)), SizeInt(VC)*2);
  SetLength(Indices, IC); ReadArray(S, Pointer(Indices), IC, 4);
  for I := 0 to High(Indices) do Require(Indices[I] < VC, 'mesh index out of range');
  SetLength(MatIds, MC); ReadArray(S, Pointer(MatIds), MC, 4);
  SetLength(Water, WC); ReadArray(S, Pointer(Water), WC, 4);
  CheckFloats(PSingle(Pointer(Water)), WC);
  SetLength(OSM, OC); ReadArray(S, Pointer(OSM), OC, 8);
  SetLength(Border, BC); ReadArray(S, Pointer(Border), BC, 4);
  for I := 0 to High(Border) do Require(LongWord(Border[I]) < VC, 'border index out of range');
  SetLength(V, VC);
  for I := 0 to High(V) do
  begin
    if Flags and 2 <> 0 then
    begin Require(Remap[I] < PC, 'pool index out of range'); P := Remap[I] end
    else P := I;
    V[I].Position := PN[P].Position; V[I].Normal := PN[P].Normal;
    V[I].UV := UV[I]; if OC <> 0 then V[I].OsmId := OSM[I];
  end;
  Mesh := TMesh.Create(Name);
  try
    Mesh.AdoptGeometry(V, Indices);
    M.AddCompositeMesh(Name, TSceneMaterialKind(EnumValue), Mesh, MatIds, Flags and 1 <> 0);
    Mesh := nil;
    M.SetWaterScale(M.MeshCount-1, Water); M.SetBorderIdx(M.MeshCount-1, Border);
  finally Mesh.Free end;
end;

procedure WriteTrees(S: TStream; M: TTileModel);
var A: TTreesWire; T: TTileTreeRec; I: Integer;
begin
  SetLength(A, M.TreeCount);
  for I := 0 to High(A) do
  begin
    T := M.Trees[I];
    A[I].X := T.X; A[I].Y := T.Y; A[I].Z := T.Z; A[I].Scale := T.Scale;
    A[I].Rotation := T.Rotation; A[I].Seed := T.Seed;
    A[I].Flags := Ord(T.IsShrub); A[I].TypePlusOne := T.Procedural.TypePlusOne;
    A[I].LatE7 := T.Procedural.LatE7; A[I].LonE7 := T.Procedural.LonE7;
  end;
  WriteU(S, Length(A)); WriteArray(S, Pointer(A), Length(A), 40);
end;

procedure ReadTrees(S: TStream; M: TTileModel);
var A: TTreesWire; T: TTileTreeRecArray; N, I: Integer;
begin
  N := Count(S, 40); ExactSize(S, Int64(N)*40);
  SetLength(A, N); ReadArray(S, Pointer(A), N, 40); SetLength(T, N);
  for I := 0 to N-1 do
  begin
    CheckFloats(@A[I].X, 6); Require(A[I].Flags <= 1, 'tree flags');
    T[I].X := A[I].X; T[I].Y := A[I].Y; T[I].Z := A[I].Z;
    T[I].Scale := A[I].Scale; T[I].Rotation := A[I].Rotation; T[I].Seed := A[I].Seed;
    T[I].IsShrub := A[I].Flags <> 0;
    T[I].Procedural.TypePlusOne := A[I].TypePlusOne;
    T[I].Procedural.LatE7 := A[I].LatE7; T[I].Procedural.LonE7 := A[I].LonE7;
  end;
  M.SetTrees(T);
end;

procedure WritePOIs(S: TStream; M: TTileModel);
var A: TPOIsWire; P: TTilePOIRec; K: TPOIKindExt; I: Integer;
begin
  WriteU(S, Ord(High(TPOIKindExt))+1);
  for K := Low(TPOIKindExt) to High(TPOIKindExt) do
    WriteString(S, GetEnumName(TypeInfo(TPOIKindExt), Ord(K)));
  SetLength(A, M.POICount);
  for I := 0 to High(A) do
  begin
    P := M.POIs[I]; A[I].Kind := Ord(P.Kind);
    A[I].Position := P.Position; A[I].Rotation := P.Rotation;
  end;
  WriteU(S, Length(A)); WriteArray(S, Pointer(A), Length(A), 20);
end;

procedure ReadPOIs(S: TStream; M: TTileModel);
var A: TPOIsWire; P: TTilePOIRecArray; Kinds: array of Integer; I, N: Integer;
begin
  N := Count(S, 4); SetLength(Kinds, N);
  for I := 0 to N-1 do Kinds[I] := GetEnumValue(TypeInfo(TPOIKindExt), ReadString(S));
  N := Count(S, 20); ExactSize(S, Int64(N)*20);
  SetLength(A, N); ReadArray(S, Pointer(A), N, 20); SetLength(P, N);
  for I := 0 to N-1 do
  begin
    Require(A[I].Kind < LongWord(Length(Kinds)), 'POI dictionary index');
    Require(Kinds[A[I].Kind] >= 0, 'unknown POI kind');
    CheckFloats(@A[I].Position.X, 4);
    P[I].Kind := TPOIKindExt(Kinds[A[I].Kind]);
    P[I].Position := A[I].Position; P[I].Rotation := A[I].Rotation;
  end;
  M.SetPOIs(P);
end;

procedure WriteRoads(S: TStream; M: TTileModel);
var A: TRoadsWire; Points: TUVArray; Lanes: TTileSingleArray;
  R: TTileRoadSeg; I, J, L: Integer;
begin
  SetLength(A, M.RoadSegCount); SetLength(Points, Length(A)*2); L := 0;
  for I := 0 to High(A) do
  begin
    R := M.RoadSegs[I];
    Require((R.Surface.Layout.Count >= 0) and (R.Surface.Layout.Count <= ROAD_MAX_LANES), 'lane count');
    Inc(L, R.Surface.Layout.Count);
  end;
  SetLength(Lanes, L); L := 0;
  for I := 0 to High(A) do
  begin
    R := M.RoadSegs[I]; A[I].P0 := I*2; A[I].P1 := I*2+1;
    Points[I*2] := Vector2(R.X0, R.Z0); Points[I*2+1] := Vector2(R.X1, R.Z1);
    A[I].Width := R.Width; A[I].WayId := R.WayId; A[I].Flags := Ord(R.IsBridge);
    A[I].ForwardLanes := R.Surface.ForwardLanes; A[I].BackwardLanes := R.Surface.BackwardLanes;
    A[I].UVMin := R.Surface.UVMin; A[I].UVMax := R.Surface.UVMax;
    A[I].UVScale := R.Surface.UVScale; A[I].Marked := R.Surface.Marked;
    A[I].Asphalt := R.Surface.Asphalt; A[I].Condition := R.Surface.Condition;
    A[I].BothWays := R.Surface.Layout.BothWays; A[I].Custom := R.Surface.Layout.Custom;
    A[I].Edge := R.Surface.Layout.Edge; A[I].LaneOffset := L;
    A[I].LaneCount := R.Surface.Layout.Count;
    for J := 0 to R.Surface.Layout.Count-1 do
    begin Lanes[L] := R.Surface.Layout.Widths[J]; Inc(L) end;
  end;
  WriteU(S, Length(A)); WriteU(S, Length(Points)); WriteU(S, Length(Lanes));
  WriteArray(S, Pointer(A), Length(A), 76);
  WriteArray(S, Pointer(Points), Length(Points), 8);
  WriteArray(S, Pointer(Lanes), Length(Lanes), 4);
end;

procedure ReadRoads(S: TStream; M: TTileModel);
var A: TRoadsWire; Points: TUVArray; Lanes: TTileSingleArray;
  R: TTileRoadSegArray; N, NP, NL, I, J: Integer;
begin
  N := Count(S, 76); NP := Count(S, 8); NL := Count(S, 4);
  ExactSize(S, Int64(N)*76+Int64(NP)*8+Int64(NL)*4);
  SetLength(A, N); ReadArray(S, Pointer(A), N, 76);
  SetLength(Points, NP); ReadArray(S, Pointer(Points), NP, 8);
  SetLength(Lanes, NL); ReadArray(S, Pointer(Lanes), NL, 4);
  CheckFloats(PSingle(Pointer(Points)), SizeInt(NP)*2);
  CheckFloats(PSingle(Pointer(Lanes)), NL); SetLength(R, N);
  for I := 0 to N-1 do
  begin
    Require((A[I].P0 < LongWord(NP)) and (A[I].P1 < LongWord(NP)) and
      (A[I].Flags <= 1) and (A[I].LaneCount <= ROAD_MAX_LANES) and
      (A[I].LaneOffset <= LongWord(NL)) and
      (QWord(A[I].LaneOffset)+A[I].LaneCount <= QWord(NL)), 'road array offset');
    CheckFloats(@A[I].Width, 1); CheckFloats(@A[I].UVMin, 3); CheckFloats(@A[I].Edge, 1);
    R[I].X0 := Points[A[I].P0].X; R[I].Z0 := Points[A[I].P0].Y;
    R[I].X1 := Points[A[I].P1].X; R[I].Z1 := Points[A[I].P1].Y;
    R[I].Width := A[I].Width; R[I].WayId := A[I].WayId; R[I].IsBridge := A[I].Flags <> 0;
    R[I].Surface.ForwardLanes := A[I].ForwardLanes; R[I].Surface.BackwardLanes := A[I].BackwardLanes;
    R[I].Surface.UVMin := A[I].UVMin; R[I].Surface.UVMax := A[I].UVMax;
    R[I].Surface.UVScale := A[I].UVScale; R[I].Surface.Marked := A[I].Marked;
    R[I].Surface.Asphalt := A[I].Asphalt; R[I].Surface.Condition := A[I].Condition;
    R[I].Surface.Layout.BothWays := A[I].BothWays; R[I].Surface.Layout.Custom := A[I].Custom;
    R[I].Surface.Layout.Edge := A[I].Edge; R[I].Surface.Layout.Count := A[I].LaneCount;
    for J := 0 to Integer(A[I].LaneCount)-1 do
      R[I].Surface.Layout.Widths[J] := Lanes[A[I].LaneOffset+LongWord(J)];
  end;
  M.SetRoadSegs(R);
end;

function HasRoadWidths(M:TTileModel):Boolean;
var I:Integer;
begin
  for I:=0 to M.RoadSegCount-1 do if M.RoadSegs[I].Surface.WidthStart>0 then Exit(True);
  Result:=False;
end;

procedure WriteRoadWidths(S:TStream; M:TTileModel);
var A:TTileSingleArray;I:Integer;
begin
  SetLength(A,M.RoadSegCount*2);
  for I:=0 to M.RoadSegCount-1 do begin
    A[I*2]:=M.RoadSegs[I].Surface.WidthStart;
    A[I*2+1]:=M.RoadSegs[I].Surface.WidthEnd;
  end;
  WriteU(S,M.RoadSegCount);WriteArray(S,Pointer(A),Length(A),4);
end;

procedure ReadRoadWidths(S:TStream; M:TTileModel);
var A:TTileSingleArray;R:TTileRoadSegArray;N,I:Integer;
begin
  N:=Count(S,8);Require(N=M.RoadSegCount,'RWID count does not match ROAD');
  ExactSize(S,Int64(N)*8);SetLength(A,N*2);ReadArray(S,Pointer(A),N*2,4);
  CheckFloats(PSingle(Pointer(A)),N*2);SetLength(R,N);
  for I:=0 to N-1 do begin
    R[I]:=M.RoadSegs[I];
    Require(((A[I*2]=0) and (A[I*2+1]=0)) or
      ((A[I*2]>=0.5) and (A[I*2]<=60) and (A[I*2+1]>=0.5) and (A[I*2+1]<=60)),
      'road endpoint width out of range');
    Require(Max(A[I*2],A[I*2+1])<=R[I].Width+0.001,'ROAD width is not conservative');
    R[I].Surface.WidthStart:=A[I*2];R[I].Surface.WidthEnd:=A[I*2+1];
  end;
  M.SetRoadSegs(R);
end;

procedure WriteBuildings(S: TStream; M: TTileModel);
var A: TBuildingsWire; P: TUVArray; I, J, N: Integer;
begin
  SetLength(A, Length(M.BuildingObstacles)); N := 0;
  for I := 0 to High(A) do Inc(N, Length(M.BuildingObstacles[I].Footprint));
  SetLength(P, N); N := 0;
  for I := 0 to High(A) do
    with M.BuildingObstacles[I] do
    begin
      A[I].BaseY := BaseY; A[I].MaxY := MaxY;
      A[I].First := N; A[I].Count := Length(Footprint);
      for J := 0 to High(Footprint) do
      begin P[N] := Vector2(Footprint[J].X, Footprint[J].Z); Inc(N) end;
    end;
  WriteU(S, Length(A)); WriteU(S, Length(P));
  WriteArray(S, Pointer(A), Length(A), 16); WriteArray(S, Pointer(P), Length(P), 8);
end;

procedure ReadBuildings(S: TStream; M: TTileModel);
var A: TBuildingsWire; P: TUVArray; N, NP, I, J: Integer;
begin
  N := Count(S, 16); NP := Count(S, 8);
  ExactSize(S, Int64(N)*16+Int64(NP)*8);
  SetLength(A, N); ReadArray(S, Pointer(A), N, 16);
  SetLength(P, NP); ReadArray(S, Pointer(P), NP, 8);
  CheckFloats(PSingle(Pointer(P)), SizeInt(NP)*2);
  SetLength(M.BuildingObstacles, N);
  for I := 0 to N-1 do
  begin
    Require(QWord(A[I].First)+A[I].Count <= QWord(NP), 'building point offset');
    CheckFloats(@A[I].BaseY, 2);
    with M.BuildingObstacles[I] do
    begin
      BaseY := A[I].BaseY; MaxY := A[I].MaxY; SetLength(Footprint, A[I].Count);
      for J := 0 to High(Footprint) do
        Footprint[J] := Vector3(P[A[I].First+LongWord(J)].X, 0, P[A[I].First+LongWord(J)].Y);
    end;
    RebuildObstacleAABB(M.BuildingObstacles[I]);
  end;
end;

procedure WriteModels(S: TStream; M: TTileModel);
var Names: TStringList; A: TModelsWire; I, K: Integer;
begin
  Names := TStringList.Create;
  try
    SetLength(A, Length(M.ModelInstances));
    for I := 0 to High(A) do
      with M.ModelInstances[I] do
      begin
        K := Names.IndexOf(FileName); if K < 0 then K := Names.Add(FileName);
        A[I].FileIndex := K; A[I].Position := Position;
        A[I].Rotation := Rotation; A[I].Scale := Scale;
      end;
    WriteU(S, Names.Count);
    for I := 0 to Names.Count-1 do WriteString(S, Names[I]);
    WriteU(S, Length(A)); WriteArray(S, Pointer(A), Length(A), 44);
  finally Names.Free end;
end;

procedure ReadModels(S: TStream; M: TTileModel);
var Names: TStrings; A: TModelsWire; I, N: Integer;
begin
  N := Count(S, 4); SetLength(Names, N);
  for I := 0 to N-1 do Names[I] := ReadString(S);
  N := Count(S, 44); ExactSize(S, Int64(N)*44);
  SetLength(A, N); ReadArray(S, Pointer(A), N, 44);
  SetLength(M.ModelInstances, N);
  for I := 0 to N-1 do
  begin
    Require(A[I].FileIndex < LongWord(Length(Names)), 'model filename index');
    CheckFloats(@A[I].Position.X, 10);
    M.ModelInstances[I].FileName := Names[A[I].FileIndex];
    M.ModelInstances[I].Position := A[I].Position;
    M.ModelInstances[I].Rotation := A[I].Rotation;
    M.ModelInstances[I].Scale := A[I].Scale;
  end;
end;

procedure WriteManholes(S: TStream; M: TTileModel);
var A: TManholesWire; I: Integer;
begin
  SetLength(A, Length(M.Manholes));
  for I := 0 to High(A) do
  begin
    A[I].Position := M.Manholes[I].Position; A[I].Normal := M.Manholes[I].Normal;
    A[I].Rotation := M.Manholes[I].Rotation; A[I].Kind := M.Manholes[I].Kind;
  end;
  WriteU(S, Length(A)); WriteArray(S, Pointer(A), Length(A), 32);
end;

procedure ReadManholes(S: TStream; M: TTileModel);
var A: TManholesWire; I, N: Integer;
begin
  N := Count(S, 32); ExactSize(S, Int64(N)*32);
  SetLength(A, N); ReadArray(S, Pointer(A), N, 32); SetLength(M.Manholes, N);
  for I := 0 to N-1 do
  begin
    Require((A[I].Kind >= 0) and (A[I].Kind < MANHOLE_COUNT), 'manhole kind');
    CheckFloats(@A[I].Position.X, 7);
    M.Manholes[I].Position := A[I].Position; M.Manholes[I].Normal := A[I].Normal;
    M.Manholes[I].Rotation := A[I].Rotation; M.Manholes[I].Kind := A[I].Kind;
  end;
end;

class procedure TTileBinary.SaveFile(const FileName: string; Model: TTileModel);
var F: TFileStream; S: TMemoryStream; H: THeader; Entries: TEntries;
  Encoded: TBytes; I, E: Integer; N: LongWord;
  procedure Emit(const Kind: string);
  begin
    Require((S.Size >= 4) and (S.Size <= MAX_CHUNK), 'chunk size limit');
    Move(Kind[1], Entries[E].Kind[0], 4);
    Entries[E].Offset := F.Position; Entries[E].RawSize := S.Size;
    Entries[E].CRC := PasZLib.crc32(0, PChar(S.Memory), S.Size);
    N := S.Size+S.Size div 1000+128; SetLength(Encoded, N);
    Require(PasZLib.compress2(PChar(@Encoded[0]), N, PChar(S.Memory), S.Size, 1) = Z_OK,
      'zlib compression failed');
    if N < S.Size then
    begin
      Entries[E].Flags := 1; Entries[E].PackedSize := N;
      F.WriteBuffer(Encoded[0], N);
    end else
    begin
      Entries[E].PackedSize := S.Size; F.WriteBuffer(S.Memory^, S.Size);
    end;
    Encoded := nil; S.Clear; Inc(E);
  end;
begin
  CheckPlatform; Require(Model <> nil, 'nil model');
  FillChar(H, SizeOf(H), 0); H.Magic := MAGIC; H.Version := 1;
  H.Endian := $01020304; H.Count := Model.MeshCount+7; H.Directory := 32;
  if Length(Model.FacadeLayouts)>0 then Inc(H.Count);
  if Length(Model.BuildingTints)>0 then Inc(H.Count);
  if HasRoadWidths(Model) then Inc(H.Count);
  Require(H.Count <= MAX_CHUNKS, 'too many meshes');
  SetLength(Entries, H.Count); E := 0;
  F := TFileStream.Create(FileName, fmCreate);
  try
    S := TMemoryStream.Create;
    try
      F.WriteBuffer(H, SizeOf(H)); F.WriteBuffer(Entries[0], Length(Entries)*40);
      WriteMeta(S, Model); Emit('META');
      for I := 0 to Model.MeshCount-1 do begin WriteMesh(S, Model.Meshes[I]); Emit('MESH') end;
      WriteTrees(S, Model); Emit('TREE'); WritePOIs(S, Model); Emit('POIS');
      WriteRoads(S, Model); Emit('ROAD');
      if HasRoadWidths(Model) then begin WriteRoadWidths(S,Model);Emit('RWID') end;
      WriteBuildings(S, Model); Emit('BULD');
      WriteModels(S, Model); Emit('MODL'); WriteManholes(S, Model); Emit('MHOL');
      if Length(Model.FacadeLayouts)>0 then begin WriteFacadeLayouts(S,Model.FacadeLayouts); Emit('FACA') end;
      if Length(Model.BuildingTints)>0 then begin WriteBuildingTints(S,Model.BuildingTints); Emit('BCOL') end;
      F.Position := H.Directory; F.WriteBuffer(Entries[0], Length(Entries)*40);
    finally S.Free end;
  finally F.Free end;
end;

class function TTileBinary.LoadFile(const FileName: string;
  Layers: TTileBinaryLayers): TTileModel;
var R: TTileReader; S: TMemoryStream; I: Integer; K: string; Wanted: Boolean; WidthChunk:Integer;
begin
  Result := nil; WidthChunk:=-1; R := TTileReader.Create(FileName);
  try
    Result := TTileModel.Create;
    try
      for I := 0 to High(R.Entries) do
      begin
        SetString(K, PAnsiChar(@R.Entries[I].Kind[0]), 4);
        if (K='RWID') and (tblRoads in Layers) then begin
          Require(WidthChunk<0,'duplicate RWID');WidthChunk:=I;Continue;
        end;
        Wanted := (K = 'META') or ((K = 'MESH') and (tblMeshes in Layers)) or
          ((K = 'TREE') and (tblTrees in Layers)) or ((K = 'POIS') and (tblPOIs in Layers)) or
          ((K = 'ROAD') and (tblRoads in Layers)) or ((K = 'BULD') and (tblBuildings in Layers)) or
          ((K = 'MODL') and (tblModels in Layers)) or ((K = 'MHOL') and (tblManholes in Layers)) or
          ((K = 'FACA') and (tblMeshes in Layers)) or ((K='BCOL') and (tblMeshes in Layers));
        if not Wanted then Continue;
        S := R.Chunk(I);
        try
          case K of
            'META': ReadMeta(S, Result); 'MESH': ReadMesh(S, Result);
            'TREE': ReadTrees(S, Result); 'POIS': ReadPOIs(S, Result);
            'ROAD': ReadRoads(S, Result); 'BULD': ReadBuildings(S, Result);
            'MODL': ReadModels(S, Result); 'MHOL': ReadManholes(S, Result);
            'FACA': Result.FacadeLayouts:=ReadFacadeLayouts(S);
            'BCOL': Result.BuildingTints:=ReadBuildingTints(S);
          end;
          ExactSize(S, 0);
        finally S.Free end;
      end;

      if WidthChunk>=0 then begin
        S:=R.Chunk(WidthChunk);
        try ReadRoadWidths(S,Result);ExactSize(S,0) finally S.Free end;
      end;
    except FreeAndNil(Result); raise end;
  finally R.Free end;
end;

class function TTileBinary.ValidateFile(const FileName: string;
  Cancel: TThread): TTileModel;
var R:TTileReader;S:TMemoryStream;I:Integer;
begin
  Result:=nil;R:=TTileReader.Create(FileName);
  try
    Result:=TTileModel.Create;
    try
      for I:=0 to High(R.Entries)do begin
        if(Cancel<>nil)and TThreadAccess(Cancel).Terminated then
          raise EAbort.Create('Tile validation cancelled');
        S:=R.Chunk(I);
        try
          if KindIs(R.Entries[I],'META')then begin ReadMeta(S,Result);ExactSize(S,0)end;
        finally S.Free end;
      end;
    except FreeAndNil(Result);raise end;
  finally R.Free end;
end;

class function TTileBinary.RoadFingerprint(const FileName: string): string;
var R: TTileReader; I: Integer;
begin
  R := TTileReader.Create(FileName);
  try
    Result := 'O3DTBIN1';
    for I := 0 to High(R.Entries) do
      if KindIs(R.Entries[I], 'META') or KindIs(R.Entries[I], 'ROAD') or KindIs(R.Entries[I], 'RWID') then
        Result := Result + ':' + IntToHex(R.Entries[I].CRC, 8) + ':' +
          IntToStr(R.Entries[I].RawSize);
  finally R.Free end;
end;

end.
