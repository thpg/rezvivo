{ AvatarGlbIO — load / save GLB and low-level glTF node helpers. }
unit AvatarGlbIO;

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, Math, fpjson, jsonparser, GltfCore;

type
  TVec3 = record
    X, Y, Z: Double;
  end;

  { Column-major 4x4, glTF convention. }
  TMat4 = array[0..15] of Double;

function V3(X, Y, Z: Double): TVec3; inline;
function V3Add(const A, B: TVec3): TVec3; inline;
function V3Sub(const A, B: TVec3): TVec3; inline;
function V3Scale(const A: TVec3; S: Double): TVec3; inline;
function V3Len(const A: TVec3): Double; inline;

function M4InvertAffine(const M: TMat4; out Inv: TMat4): Boolean;
function M4Mul(const A, B: TMat4): TMat4;
function M4MulPoint(const M: TMat4; const P: TVec3): TVec3;
procedure EulerDegToQuat(Rx, Ry, Rz: Double; out X, Y, Z, W: Double);
procedure QuatToEulerDeg(X, Y, Z, W: Double; out Rx, Ry, Rz: Double);
function IsAccessoryName(const Nm: string): Boolean;

type
  { In-memory GLB document. Owns JSON root + BIN payload. }
  TGlbDoc = class
  private
    FRoot: TJSONObject;
    FBin: TBytes;
    FPath: string;
    FParent: array of Integer;
    FIsBodyJoint: array of Boolean;
    FMainSkin: Integer;
    FMainArm: Integer;
    FHierarchyValid: Boolean;
    function Nodes: TJSONArray;
    function Skins: TJSONArray;
    function Scenes: TJSONArray;
    function EnsureArr(const Name: string): TJSONArray;
    function CloneImageFrom(Src: TGlbDoc; SrcImgI: Integer): Integer;
    function CloneTextureFrom(Src: TGlbDoc; SrcTexI: Integer): Integer;
    procedure TouchBufferLength;
    procedure InvalidateHierarchy;
    procedure RebuildHierarchy;
    function ComputeMainSkinIndex: Integer;
    function ComputeMainArmature: Integer;
  public
    function CloneAccessorFrom(Src: TGlbDoc; SrcAccI: Integer): Integer;
    function CloneMaterialFrom(Src: TGlbDoc; SrcMatI: Integer): Integer;
    constructor Create;
    destructor Destroy; override;
    function LoadFromFile(const APath: string): Boolean;
    procedure SaveToFile(const APath: string);

    function NodeCount: Integer;
    function NodeObj(I: Integer): TJSONObject;
    function FindNode(const AName: string): Integer;
    function NodeName(I: Integer): string;
    function NodeTranslation(I: Integer): TVec3;
    function NodeScale(I: Integer): TVec3;
    function NodeRotation(I: Integer; out X, Y, Z, W: Double): Boolean;
    function ContactExists(const AName: string): Boolean;
    procedure SetNodeTranslation(I: Integer; const T: TVec3);
    procedure SetNodeScale(I: Integer; const S: TVec3);
    procedure SetNodeRotation(I: Integer; X, Y, Z, W: Double);
    procedure SetNodeFromWorld(Node: Integer; const World: TMat4);
    function NodeLocalEulerDeg(I: Integer; out Rx, Ry, Rz: Double): Boolean;
    function NodeLocalMatrix(I: Integer): TMat4;
    function NodeWorldMatrix(I: Integer): TMat4;
    function NodeWorldPos(I: Integer): TVec3;
    function ParentOf(I: Integer): Integer;
    function ChildCount(ANode: Integer): Integer;
    function GetChild(ANode, I: Integer): Integer;
    { Keep rest-mesh: IBM' = inv(newWorld) * oldWorld * oldIBM for this joint
      in every non-accessory skin that lists it. Height stays in Armature scale. }
    procedure RewriteJointIBM(Node: Integer; const OldWorld: TMat4);
    function MainArmature: Integer;
    function IsUnder(Node, Root: Integer): Boolean;
    function FindJoint(const AName: string): Integer;
    function IsBodyJoint(I: Integer): Boolean;
    function MainSkinIndex: Integer;
    function MeshExtentY: Double;
    { Rebuild inverseBindMatrices from current node worlds. Required after
      changing armature scale/yaw or bind translations — otherwise
      jointWorld*IBM != I and the mesh flattens in bikeeditor. }
    procedure RecomputeSkinIBM(SkinI: Integer);
    procedure RecomputeBodyIBMs;

    { Create 1-joint contact armature at world position. Returns root node index. }
    function AddContactArmature(const AName: string; const WorldPos: TVec3): Integer;
    { Append an unskinned mesh from another GLB as node AName at WorldPos. }
    function ImportUnskinnedMesh(Src: TGlbDoc; const AName: string;
      const WorldPos: TVec3): Integer;
    function EnsureHelmetAnchor(const WorldPos: TVec3): Integer;

    { Deep copy of JSON + BIN for undo. Caller owns ARoot. }
    procedure CaptureState(out ARoot: TJSONObject; out ABin: TBytes);
    { Restore from a snapshot (cloned; snapshot stays valid). }
    procedure RestoreState(ARoot: TJSONObject; const ABin: TBytes);

    { 4-byte aligned append. Returns byte offset of the copied payload. }
    function AppendBytes(const P; Len: Integer): Integer;
    procedure WriteF32(Ofs: Integer; V: Single);
    procedure WriteBytes(Ofs: Integer; const P; Len: Integer);
    function FindMainPrimitive(out MeshO, Prim: TJSONObject;
      out SkinI: Integer; out NodeI: Integer): Boolean;
    procedure RefreshHierarchy;
    function ImageBuffer(ImgI: Integer; out Mime: string;
      out Data: TBytes): Boolean;

    property Root: TJSONObject read FRoot;
    property Bin: TBytes read FBin;
    property Path: string read FPath;
  end;

implementation

uses RiderCorrectiveData, RiderEquipment;

function V3(X, Y, Z: Double): TVec3;
begin
  Result.X := X; Result.Y := Y; Result.Z := Z;
end;

function V3Add(const A, B: TVec3): TVec3;
begin
  Result.X := A.X + B.X; Result.Y := A.Y + B.Y; Result.Z := A.Z + B.Z;
end;

function V3Sub(const A, B: TVec3): TVec3;
begin
  Result.X := A.X - B.X; Result.Y := A.Y - B.Y; Result.Z := A.Z - B.Z;
end;

function V3Scale(const A: TVec3; S: Double): TVec3;
begin
  Result.X := A.X * S; Result.Y := A.Y * S; Result.Z := A.Z * S;
end;

function V3Len(const A: TVec3): Double;
begin
  Result := Sqrt(A.X * A.X + A.Y * A.Y + A.Z * A.Z);
end;

function NameHasPrefix(const Nm, Prefix: string): Boolean;
var
  L: Integer;
begin
  L := Length(Prefix);
  Result := (L > 0) and (Length(Nm) >= L) and
    SameText(Copy(Nm, 1, L), Prefix);
end;

function IsAccessoryName(const Nm: string): Boolean;
begin
  Result := SameText(Nm, 'Helmet')
    or SameText(Nm, 'JerseyHem')
    or SameText(Nm, 'BottomContact')
    or SameText(Nm, 'Bone')
    or NameHasPrefix(Nm, 'ArmContact')
    or NameHasPrefix(Nm, 'BoatClipse');
end;

function M4Ident: TMat4;
var
  I: Integer;
begin
  for I := 0 to 15 do
    Result[I] := 0;
  Result[0] := 1;
  Result[5] := 1;
  Result[10] := 1;
  Result[15] := 1;
end;

function M4Mul(const A, B: TMat4): TMat4;
var
  C, R: Integer;
begin
  for C := 0 to 3 do
    for R := 0 to 3 do
      Result[C * 4 + R] :=
        A[0 * 4 + R] * B[C * 4 + 0] +
        A[1 * 4 + R] * B[C * 4 + 1] +
        A[2 * 4 + R] * B[C * 4 + 2] +
        A[3 * 4 + R] * B[C * 4 + 3];
end;

function M4MulPoint(const M: TMat4; const P: TVec3): TVec3;
begin
  Result.X := M[0] * P.X + M[4] * P.Y + M[8]  * P.Z + M[12];
  Result.Y := M[1] * P.X + M[5] * P.Y + M[9]  * P.Z + M[13];
  Result.Z := M[2] * P.X + M[6] * P.Y + M[10] * P.Z + M[14];
end;

procedure QuatMulD(AX, AY, AZ, AW, BX, BY, BZ, BW: Double;
  out X, Y, Z, W: Double);
begin
  X := AW * BX + AX * BW + AY * BZ - AZ * BY;
  Y := AW * BY - AX * BZ + AY * BW + AZ * BX;
  Z := AW * BZ + AX * BY - AY * BX + AZ * BW;
  W := AW * BW - AX * BX - AY * BY - AZ * BZ;
end;

procedure EulerDegToQuat(Rx, Ry, Rz: Double; out X, Y, Z, W: Double);
var
  Hx, Hy, Hz, Sx, Cx, Sy, Cy, Sz, Cz, Tx, Ty, Tz, Tw: Double;
begin
  Hx := Rx * Pi / 360.0;
  Hy := Ry * Pi / 360.0;
  Hz := Rz * Pi / 360.0;
  Sx := Sin(Hx); Cx := Cos(Hx);
  Sy := Sin(Hy); Cy := Cos(Hy);
  Sz := Sin(Hz); Cz := Cos(Hz);
  QuatMulD(Sx, 0, 0, Cx, 0, Sy, 0, Cy, Tx, Ty, Tz, Tw);
  QuatMulD(Tx, Ty, Tz, Tw, 0, 0, Sz, Cz, X, Y, Z, W);
end;

procedure QuatToEulerDeg(X, Y, Z, W: Double; out Rx, Ry, Rz: Double);
var
  SinP, N: Double;
begin
  N := Sqrt(X * X + Y * Y + Z * Z + W * W);
  if N > 1e-12 then
  begin
    X := X / N; Y := Y / N; Z := Z / N; W := W / N;
  end;
  SinP := 2.0 * (W * Y - Z * X);
  if SinP > 1 then SinP := 1;
  if SinP < -1 then SinP := -1;
  Ry := ArcSin(SinP);
  Rx := ArcTan2(2.0 * (W * X + Y * Z), 1.0 - 2.0 * (X * X + Y * Y));
  Rz := ArcTan2(2.0 * (W * Z + X * Y), 1.0 - 2.0 * (Y * Y + Z * Z));
  Rx := Rx * 180.0 / Pi;
  Ry := Ry * 180.0 / Pi;
  Rz := Rz * 180.0 / Pi;
end;

procedure M4ToQuat(const M: TMat4; out X, Y, Z, W: Double);
var
  C0, C1, C2, L0, L1, L2, Tr, S: Double;
  R: TMat4;
begin
  L0 := Sqrt(M[0] * M[0] + M[1] * M[1] + M[2] * M[2]);
  L1 := Sqrt(M[4] * M[4] + M[5] * M[5] + M[6] * M[6]);
  L2 := Sqrt(M[8] * M[8] + M[9] * M[9] + M[10] * M[10]);
  if L0 < 1e-12 then L0 := 1;
  if L1 < 1e-12 then L1 := 1;
  if L2 < 1e-12 then L2 := 1;
  C0 := M[0] / L0; C1 := M[1] / L0; C2 := M[2] / L0;
  R := M4Ident;
  R[0] := C0; R[1] := C1; R[2] := C2;
  R[4] := M[4] / L1; R[5] := M[5] / L1; R[6] := M[6] / L1;
  R[8] := M[8] / L2; R[9] := M[9] / L2; R[10] := M[10] / L2;
  Tr := R[0] + R[5] + R[10];
  if Tr > 0 then
  begin
    S := Sqrt(Tr + 1.0) * 2.0;
    W := 0.25 * S; X := (R[6] - R[9]) / S; Y := (R[8] - R[2]) / S; Z := (R[1] - R[4]) / S;
  end
  else if (R[0] > R[5]) and (R[0] > R[10]) then
  begin
    S := Sqrt(1.0 + R[0] - R[5] - R[10]) * 2.0;
    W := (R[6] - R[9]) / S; X := 0.25 * S; Y := (R[4] + R[1]) / S; Z := (R[8] + R[2]) / S;
  end
  else if R[5] > R[10] then
  begin
    S := Sqrt(1.0 + R[5] - R[0] - R[10]) * 2.0;
    W := (R[8] - R[2]) / S; X := (R[4] + R[1]) / S; Y := 0.25 * S; Z := (R[9] + R[6]) / S;
  end
  else
  begin
    S := Sqrt(1.0 + R[10] - R[0] - R[5]) * 2.0;
    W := (R[1] - R[4]) / S; X := (R[8] + R[2]) / S; Y := (R[9] + R[6]) / S; Z := 0.25 * S;
  end;
  S := Sqrt(X * X + Y * Y + Z * Z + W * W);
  if S > 1e-12 then
  begin
    X := X / S; Y := Y / S; Z := Z / S; W := W / S;
  end
  else
  begin
    X := 0; Y := 0; Z := 0; W := 1;
  end;
end;

function M4InvertAffine(const M: TMat4; out Inv: TMat4): Boolean;
var
  A11, A12, A13, A21, A22, A23, A31, A32, A33, Det: Double;
  B11, B12, B13, B21, B22, B23, B31, B32, B33: Double;
  Tx, Ty, Tz: Double;
begin
  A11 := M[0]; A12 := M[4]; A13 := M[8];
  A21 := M[1]; A22 := M[5]; A23 := M[9];
  A31 := M[2]; A32 := M[6]; A33 := M[10];
  Det := A11 * (A22 * A33 - A23 * A32)
       - A12 * (A21 * A33 - A23 * A31)
       + A13 * (A21 * A32 - A22 * A31);
  Result := Abs(Det) > 1e-12;
  if not Result then
  begin
    Inv := M4Ident;
    Exit;
  end;
  Det := 1.0 / Det;
  B11 :=  (A22 * A33 - A23 * A32) * Det;
  B12 :=  (A13 * A32 - A12 * A33) * Det;
  B13 :=  (A12 * A23 - A13 * A22) * Det;
  B21 :=  (A23 * A31 - A21 * A33) * Det;
  B22 :=  (A11 * A33 - A13 * A31) * Det;
  B23 :=  (A13 * A21 - A11 * A23) * Det;
  B31 :=  (A21 * A32 - A22 * A31) * Det;
  B32 :=  (A12 * A31 - A11 * A32) * Det;
  B33 :=  (A11 * A22 - A12 * A21) * Det;
  Inv := M4Ident;
  Inv[0] := B11; Inv[4] := B12; Inv[8]  := B13;
  Inv[1] := B21; Inv[5] := B22; Inv[9]  := B23;
  Inv[2] := B31; Inv[6] := B32; Inv[10] := B33;
  Tx := M[12]; Ty := M[13]; Tz := M[14];
  Inv[12] := -(B11 * Tx + B12 * Ty + B13 * Tz);
  Inv[13] := -(B21 * Tx + B22 * Ty + B23 * Tz);
  Inv[14] := -(B31 * Tx + B32 * Ty + B33 * Tz);
end;

function QuatMat(QX, QY, QZ, QW: Double): TMat4;
var
  XX, YY, ZZ, XY, XZ, YZ, WX, WY, WZ: Double;
begin
  Result := M4Ident;
  XX := QX * QX; YY := QY * QY; ZZ := QZ * QZ;
  XY := QX * QY; XZ := QX * QZ; YZ := QY * QZ;
  WX := QW * QX; WY := QW * QY; WZ := QW * QZ;
  Result[0] := 1 - 2 * (YY + ZZ);
  Result[1] := 2 * (XY + WZ);
  Result[2] := 2 * (XZ - WY);
  Result[4] := 2 * (XY - WZ);
  Result[5] := 1 - 2 * (XX + ZZ);
  Result[6] := 2 * (YZ + WX);
  Result[8] := 2 * (XZ + WY);
  Result[9] := 2 * (YZ - WX);
  Result[10] := 1 - 2 * (XX + YY);
end;

function TransMat(const T: TVec3): TMat4;
begin
  Result := M4Ident;
  Result[12] := T.X;
  Result[13] := T.Y;
  Result[14] := T.Z;
end;

function ScaleMat(const S: TVec3): TMat4;
begin
  Result := M4Ident;
  Result[0] := S.X;
  Result[5] := S.Y;
  Result[10] := S.Z;
end;

procedure WriteU32(var B: TBytes; Ofs: Integer; V: LongWord);
begin
  B[Ofs]     := Byte(V);
  B[Ofs + 1] := Byte(V shr 8);
  B[Ofs + 2] := Byte(V shr 16);
  B[Ofs + 3] := Byte(V shr 24);
end;

function VecArr(const T: TVec3): TJSONArray;
begin
  Result := TJSONArray.Create;
  Result.Add(T.X);
  Result.Add(T.Y);
  Result.Add(T.Z);
end;

function ReadF32(const B: TBytes; Ofs: Integer): Single;
begin
  Result := 0;
  if (Ofs < 0) or (Ofs + 4 > Length(B)) then Exit;
  Move(B[Ofs], Result, 4);
end;

constructor TGlbDoc.Create;
begin
  inherited Create;
  FMainSkin := -1;
  FMainArm := -1;
  FHierarchyValid := False;
end;

destructor TGlbDoc.Destroy;
begin
  FreeAndNil(FRoot);
  inherited;
end;

procedure TGlbDoc.CaptureState(out ARoot: TJSONObject; out ABin: TBytes);
begin
  ARoot := nil;
  SetLength(ABin, 0);
  if FRoot <> nil then
    ARoot := TJSONObject(FRoot.Clone);
  if Length(FBin) > 0 then
  begin
    SetLength(ABin, Length(FBin));
    Move(FBin[0], ABin[0], Length(FBin));
  end;
end;

procedure TGlbDoc.RestoreState(ARoot: TJSONObject; const ABin: TBytes);
begin
  FreeAndNil(FRoot);
  if ARoot <> nil then
    FRoot := TJSONObject(ARoot.Clone)
  else
    FRoot := TJSONObject.Create;
  if Length(ABin) > 0 then
  begin
    SetLength(FBin, Length(ABin));
    Move(ABin[0], FBin[0], Length(ABin));
  end
  else
    SetLength(FBin, 0);
  RebuildHierarchy;
end;

function TGlbDoc.EnsureArr(const Name: string): TJSONArray;
begin
  Result := ArrOf(FRoot, Name);
  if Result = nil then
  begin
    Result := TJSONArray.Create;
    FRoot.Add(Name, Result);
  end;
end;

function TGlbDoc.Nodes: TJSONArray;
begin
  Result := ArrOf(FRoot, 'nodes');
end;

function TGlbDoc.Skins: TJSONArray;
begin
  Result := ArrOf(FRoot, 'skins');
end;

function TGlbDoc.Scenes: TJSONArray;
begin
  Result := ArrOf(FRoot, 'scenes');
end;

function TGlbDoc.LoadFromFile(const APath: string): Boolean;
var
  Raw: TBytes;
  Js: string;
  BinOfs, BinLen: Integer;
  D: TJSONData;
begin
  Result := False;
  FreeAndNil(FRoot);
  SetLength(FBin, 0);
  InvalidateHierarchy;
  FPath := APath;
  Raw := LoadFileBytes(APath);
  if Length(Raw) = 0 then Exit;
  if not ExtractGltfJson(Raw, Js, BinOfs, BinLen) then Exit;
  D := GetJSON(Js);
  if not (D is TJSONObject) then
  begin
    D.Free;
    Exit;
  end;
  FRoot := TJSONObject(D);
  if BinLen > 0 then
  begin
    SetLength(FBin, BinLen);
    Move(Raw[BinOfs], FBin[0], BinLen);
  end;
  try
    RebuildHierarchy;
  except
    on E: EReadError do
    begin
      FreeAndNil(FRoot);
      SetLength(FBin, 0);
      InvalidateHierarchy;
      Exit;
    end;
  end;
  { Keep pose data in the document and its undo snapshots. Save As and the
    temporary preview then remain self-contained, with no filename coupling. }
  EmbedRiderCorrectiveData(FRoot, FBin, APath);
  NormalizeEquipmentPaths(FRoot, APath);
  Result := True;
end;

procedure TGlbDoc.SaveToFile(const APath: string);
var
  JsonUtf8: RawByteString;
  JsonB, OutB: TBytes;
  JsonPad, BinPad, Total, P, I: Integer;
begin
  if FRoot = nil then
    raise Exception.Create('TGlbDoc.SaveToFile: empty document');
  JsonUtf8 := UTF8Encode(FRoot.AsJSON);
  SetLength(JsonB, Length(JsonUtf8));
  if Length(JsonB) > 0 then
    Move(JsonUtf8[1], JsonB[0], Length(JsonB));
  JsonPad := (4 - (Length(JsonB) mod 4)) mod 4;
  BinPad := (4 - (Length(FBin) mod 4)) mod 4;
  Total := 12 + 8 + Length(JsonB) + JsonPad + 8 + Length(FBin) + BinPad;
  SetLength(OutB, Total);
  FillChar(OutB[0], Total, 0);
  WriteU32(OutB, 0, GLB_MAGIC);
  WriteU32(OutB, 4, 2);
  WriteU32(OutB, 8, Total);
  P := 12;
  WriteU32(OutB, P, Length(JsonB) + JsonPad);
  WriteU32(OutB, P + 4, GLB_CHUNK_JSON);
  if Length(JsonB) > 0 then
    Move(JsonB[0], OutB[P + 8], Length(JsonB));
  for I := 0 to JsonPad - 1 do
    OutB[P + 8 + Length(JsonB) + I] := 32; { JSON pad = spaces }
  Inc(P, 8 + Length(JsonB) + JsonPad);
  WriteU32(OutB, P, Length(FBin) + BinPad);
  WriteU32(OutB, P + 4, GLB_CHUNK_BIN);
  if Length(FBin) > 0 then
    Move(FBin[0], OutB[P + 8], Length(FBin));
  with TFileStream.Create(APath, fmCreate) do
  try
    WriteBuffer(OutB[0], Length(OutB));
  finally
    Free;
  end;
  FPath := APath;
end;

function TGlbDoc.NodeCount: Integer;
begin
  Result := CountOf(Nodes);
end;

function TGlbDoc.NodeObj(I: Integer): TJSONObject;
begin
  Result := ObjAt(Nodes, I);
end;

function TGlbDoc.FindNode(const AName: string): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to NodeCount - 1 do
    if SameText(NodeName(I), AName) then
      Exit(I);
end;

function TGlbDoc.NodeName(I: Integer): string;
begin
  Result := StrOf(NodeObj(I), 'name', '');
end;

function TGlbDoc.NodeTranslation(I: Integer): TVec3;
var
  A: TJSONArray;
  M: TMat4;
  K: Integer;
begin
  Result := V3(0, 0, 0);
  A := ArrOf(NodeObj(I), 'translation');
  if A <> nil then
  begin
    Result.X := ArrFloat(A, 0, 0);
    Result.Y := ArrFloat(A, 1, 0);
    Result.Z := ArrFloat(A, 2, 0);
    Exit;
  end;
  A := ArrOf(NodeObj(I), 'matrix');
  if A = nil then Exit;
  for K := 0 to 15 do
    M[K] := ArrFloat(A, K, M4Ident[K]);
  Result.X := M[12];
  Result.Y := M[13];
  Result.Z := M[14];
end;

function TGlbDoc.NodeScale(I: Integer): TVec3;
var
  A: TJSONArray;
  M: TMat4;
  K: Integer;
begin
  Result := V3(1, 1, 1);
  A := ArrOf(NodeObj(I), 'scale');
  if A <> nil then
  begin
    Result.X := ArrFloat(A, 0, 1);
    Result.Y := ArrFloat(A, 1, 1);
    Result.Z := ArrFloat(A, 2, 1);
    Exit;
  end;
  A := ArrOf(NodeObj(I), 'matrix');
  if A = nil then Exit;
  for K := 0 to 15 do
    M[K] := ArrFloat(A, K, M4Ident[K]);
  Result.X := Sqrt(M[0]*M[0] + M[1]*M[1] + M[2]*M[2]);
  Result.Y := Sqrt(M[4]*M[4] + M[5]*M[5] + M[6]*M[6]);
  Result.Z := Sqrt(M[8]*M[8] + M[9]*M[9] + M[10]*M[10]);
end;

function TGlbDoc.NodeRotation(I: Integer; out X, Y, Z, W: Double): Boolean;
var
  A: TJSONArray;
begin
  X := 0; Y := 0; Z := 0; W := 1;
  A := ArrOf(NodeObj(I), 'rotation');
  Result := A <> nil;
  if not Result then Exit;
  X := ArrFloat(A, 0, 0);
  Y := ArrFloat(A, 1, 0);
  Z := ArrFloat(A, 2, 0);
  W := ArrFloat(A, 3, 1);
end;

procedure SetArr3(A: TJSONArray; X, Y, Z: Double);
begin
  if A = nil then Exit;
  if A.Count >= 3 then
  begin
    A.Floats[0] := X;
    A.Floats[1] := Y;
    A.Floats[2] := Z;
  end
  else
  begin
    while A.Count > 0 do
      A.Delete(A.Count - 1);
    A.Add(X);
    A.Add(Y);
    A.Add(Z);
  end;
end;

procedure SetArr4(A: TJSONArray; X, Y, Z, W: Double);
begin
  if A = nil then Exit;
  if A.Count >= 4 then
  begin
    A.Floats[0] := X;
    A.Floats[1] := Y;
    A.Floats[2] := Z;
    A.Floats[3] := W;
  end
  else
  begin
    while A.Count > 0 do
      A.Delete(A.Count - 1);
    A.Add(X);
    A.Add(Y);
    A.Add(Z);
    A.Add(W);
  end;
end;

function TGlbDoc.ContactExists(const AName: string): Boolean;
var
  I: Integer;
  Nm, Low, Pref: string;
begin
  Result := FindNode(AName) >= 0;
  if Result then Exit;
  Low := LowerCase(AName);
  Pref := Low + '.';
  for I := 0 to NodeCount - 1 do
  begin
    Nm := LowerCase(NodeName(I));
    if (Nm = Low) or (Pos(Pref, Nm) = 1) then
      Exit(True);
    if Nm = 'bone_' + Low then
      Exit(True);
  end;
end;

procedure TGlbDoc.SetNodeTranslation(I: Integer; const T: TVec3);
var
  O: TJSONObject;
  A: TJSONArray;
  M: TMat4;
  K: Integer;
begin
  O := NodeObj(I);
  if O = nil then Exit;
  A := ArrOf(O, 'matrix');
  if A <> nil then
  begin
    for K := 0 to 15 do
      M[K] := ArrFloat(A, K, M4Ident[K]);
    M[12] := T.X; M[13] := T.Y; M[14] := T.Z;
    O.Delete('matrix');
    A := TJSONArray.Create;
    for K := 0 to 15 do
      A.Add(M[K]);
    O.Add('matrix', A);
    Exit;
  end;
  A := ArrOf(O, 'translation');
  if A <> nil then
  begin
    SetArr3(A, T.X, T.Y, T.Z);
    Exit;
  end;
  O.Add('translation', VecArr(T));
end;

procedure TGlbDoc.SetNodeScale(I: Integer; const S: TVec3);
var
  O: TJSONObject;
  A: TJSONArray;
begin
  O := NodeObj(I);
  if O = nil then Exit;
  A := ArrOf(O, 'scale');
  if A <> nil then
  begin
    SetArr3(A, S.X, S.Y, S.Z);
    Exit;
  end;
  O.Add('scale', VecArr(S));
end;

procedure TGlbDoc.SetNodeRotation(I: Integer; X, Y, Z, W: Double);
var
  O: TJSONObject;
  A: TJSONArray;
  T, Sc: TVec3;
  N: Double;
begin
  O := NodeObj(I);
  if O = nil then Exit;
  N := Sqrt(X * X + Y * Y + Z * Z + W * W);
  if N > 1e-12 then
  begin
    X := X / N; Y := Y / N; Z := Z / N; W := W / N;
  end
  else
  begin
    X := 0; Y := 0; Z := 0; W := 1;
  end;
  A := ArrOf(O, 'matrix');
  if A <> nil then
  begin
    T := NodeTranslation(I);
    Sc := NodeScale(I);
    O.Delete('matrix');
    O.Add('translation', VecArr(T));
    O.Add('scale', VecArr(Sc));
  end;
  A := ArrOf(O, 'rotation');
  if A <> nil then
  begin
    SetArr4(A, X, Y, Z, W);
    Exit;
  end;
  A := TJSONArray.Create;
  A.Add(X);
  A.Add(Y);
  A.Add(Z);
  A.Add(W);
  O.Add('rotation', A);
end;

procedure TGlbDoc.SetNodeFromWorld(Node: Integer; const World: TMat4);
var
  P: Integer;
  Inv, Loc: TMat4;
  T, Sc: TVec3;
  L0, L1, L2, QX, QY, QZ, QW: Double;
begin
  if Node < 0 then Exit;
  P := ParentOf(Node);
  if P < 0 then
    Loc := World
  else if M4InvertAffine(NodeWorldMatrix(P), Inv) then
    Loc := M4Mul(Inv, World)
  else
    Loc := World;
  T := V3(Loc[12], Loc[13], Loc[14]);
  L0 := Sqrt(Loc[0] * Loc[0] + Loc[1] * Loc[1] + Loc[2] * Loc[2]);
  L1 := Sqrt(Loc[4] * Loc[4] + Loc[5] * Loc[5] + Loc[6] * Loc[6]);
  L2 := Sqrt(Loc[8] * Loc[8] + Loc[9] * Loc[9] + Loc[10] * Loc[10]);
  if L0 < 1e-12 then L0 := 1;
  if L1 < 1e-12 then L1 := 1;
  if L2 < 1e-12 then L2 := 1;
  Sc := V3(L0, L1, L2);
  M4ToQuat(Loc, QX, QY, QZ, QW);
  SetNodeTranslation(Node, T);
  SetNodeRotation(Node, QX, QY, QZ, QW);
  SetNodeScale(Node, Sc);
end;

function TGlbDoc.NodeLocalEulerDeg(I: Integer; out Rx, Ry, Rz: Double): Boolean;
var
  QX, QY, QZ, QW: Double;
begin
  Rx := 0; Ry := 0; Rz := 0;
  Result := False;
  if I < 0 then Exit;
  if NodeRotation(I, QX, QY, QZ, QW) then
  begin
    QuatToEulerDeg(QX, QY, QZ, QW, Rx, Ry, Rz);
    Result := True;
    Exit;
  end;
  M4ToQuat(NodeLocalMatrix(I), QX, QY, QZ, QW);
  QuatToEulerDeg(QX, QY, QZ, QW, Rx, Ry, Rz);
  Result := True;
end;

function TGlbDoc.NodeLocalMatrix(I: Integer): TMat4;
var
  O: TJSONObject;
  A: TJSONArray;
  K: Integer;
  QX, QY, QZ, QW: Double;
  T, S: TVec3;
begin
  Result := M4Ident;
  O := NodeObj(I);
  if O = nil then Exit;
  A := ArrOf(O, 'matrix');
  if A <> nil then
  begin
    for K := 0 to 15 do
      Result[K] := ArrFloat(A, K, M4Ident[K]);
    Exit;
  end;
  T := NodeTranslation(I);
  S := NodeScale(I);
  if NodeRotation(I, QX, QY, QZ, QW) then
    Result := M4Mul(TransMat(T), M4Mul(QuatMat(QX, QY, QZ, QW), ScaleMat(S)))
  else
    Result := M4Mul(TransMat(T), ScaleMat(S));
end;

procedure TGlbDoc.InvalidateHierarchy;
begin
  FHierarchyValid := False;
  FMainSkin := -1;
  FMainArm := -1;
end;

procedure TGlbDoc.RebuildHierarchy;
var
  I, N, C, K, S: Integer;
  Ch, Js: TJSONArray;
  Skin: TJSONObject;
  State: array of Byte;
begin
  FHierarchyValid := False;
  N := NodeCount;
  SetLength(FParent, N);
  SetLength(FIsBodyJoint, N);
  for I := 0 to N - 1 do
  begin
    FParent[I] := -1;
    FIsBodyJoint[I] := False;
  end;
  for I := 0 to N - 1 do
  begin
    Ch := ArrOf(NodeObj(I), 'children');
    for K := 0 to CountOf(Ch) - 1 do
    begin
      C := ArrInt(Ch, K, -1);
      if (C < 0) or (C >= N) then
        raise EReadError.Create('Node child index outside node array');
      if FParent[C] <> -1 then
        raise EReadError.Create('Node has multiple parent references');
      FParent[C] := I;
    end;
  end;
  { Validate every parent chain once, before consumers walk it. }
  SetLength(State, N);
  for I := 0 to N - 1 do
  begin
    C := I;
    while (C >= 0) and (State[C] = 0) do
    begin
      State[C] := 1;
      C := FParent[C];
    end;
    if (C >= 0) and (State[C] = 1) then
      raise EReadError.Create('Cycle in node hierarchy');
    C := I;
    while (C >= 0) and (State[C] = 1) do
    begin
      State[C] := 2;
      C := FParent[C];
    end;
  end;
  FMainSkin := ComputeMainSkinIndex;
  FMainArm := ComputeMainArmature;
  if FMainSkin >= 0 then
  begin
    Js := ArrOf(ObjAt(Skins, FMainSkin), 'joints');
    for K := 0 to CountOf(Js) - 1 do
    begin
      C := ArrInt(Js, K, -1);
      if (C < 0) or (C >= N) then Continue;
      if IsAccessoryName(NodeName(C)) then Continue;
      if NameHasPrefix(NodeName(C), 'Armature') then Continue;
      FIsBodyJoint[C] := True;
    end;
  end
  else
    for S := 0 to CountOf(Skins) - 1 do
    begin
      Skin := ObjAt(Skins, S);
      if Skin = nil then Continue;
      if IsAccessoryName(StrOf(Skin, 'name', '')) then Continue;
      Js := ArrOf(Skin, 'joints');
      for K := 0 to CountOf(Js) - 1 do
      begin
        C := ArrInt(Js, K, -1);
        if (C < 0) or (C >= N) then Continue;
        if IsAccessoryName(NodeName(C)) then Continue;
        if NameHasPrefix(NodeName(C), 'Armature') then Continue;
        FIsBodyJoint[C] := True;
      end;
    end;
  FHierarchyValid := True;
end;

function TGlbDoc.NodeWorldMatrix(I: Integer): TMat4;
var
  N: Integer;
begin
  Result := M4Ident;
  if (I < 0) or (I >= NodeCount) then Exit;
  if not FHierarchyValid then
    RebuildHierarchy;
  N := I;
  while N >= 0 do
  begin
    Result := M4Mul(NodeLocalMatrix(N), Result);
    N := FParent[N];
  end;
end;

function TGlbDoc.ParentOf(I: Integer): Integer;
begin
  Result := -1;
  if not FHierarchyValid then
    RebuildHierarchy;
  if (I >= 0) and (I < Length(FParent)) then
    Result := FParent[I];
end;

function TGlbDoc.ChildCount(ANode: Integer): Integer;
begin
  Result := CountOf(ArrOf(NodeObj(ANode), 'children'));
end;

function TGlbDoc.GetChild(ANode, I: Integer): Integer;
begin
  Result := ArrInt(ArrOf(NodeObj(ANode), 'children'), I, -1);
end;

procedure TGlbDoc.RewriteJointIBM(Node: Integer; const OldWorld: TMat4);
var
  S, J, K, AccI, Off, Need, Joint: Integer;
  Skin, Acc, Bv: TJSONObject;
  Js: TJSONArray;
  OldIBM, NewWorld, InvNew, Rest, NewIBM: TMat4;
  F: array[0..15] of Single;
begin
  if Node < 0 then Exit;
  NewWorld := NodeWorldMatrix(Node);
  if not M4InvertAffine(NewWorld, InvNew) then Exit;
  for S := 0 to CountOf(Skins) - 1 do
  begin
    Skin := ObjAt(Skins, S);
    if Skin = nil then Continue;
    if IsAccessoryName(StrOf(Skin, 'name', '')) then Continue;
    Js := ArrOf(Skin, 'joints');
    Joint := -1;
    for J := 0 to CountOf(Js) - 1 do
      if ArrInt(Js, J, -1) = Node then
      begin
        Joint := J;
        Break;
      end;
    if Joint < 0 then Continue;
    AccI := IntOf(Skin, 'inverseBindMatrices', -1);
    Acc := ObjAt(ArrOf(FRoot, 'accessors'), AccI);
    if Acc = nil then Continue;
    Bv := ObjAt(ArrOf(FRoot, 'bufferViews'), IntOf(Acc, 'bufferView', -1));
    if Bv = nil then Continue;
    Off := IntOf(Bv, 'byteOffset', 0) + IntOf(Acc, 'byteOffset', 0) + Joint * 64;
    Need := Off + 64;
    if Need > Length(FBin) then Continue;
    Move(FBin[Off], F[0], 64);
    for K := 0 to 15 do
      OldIBM[K] := F[K];
    Rest := M4Mul(OldWorld, OldIBM);
    NewIBM := M4Mul(InvNew, Rest);
    for K := 0 to 15 do
      F[K] := Single(NewIBM[K]);
    Move(F[0], FBin[Off], 64);
  end;
end;

function TGlbDoc.NodeWorldPos(I: Integer): TVec3;
var
  M: TMat4;
begin
  M := NodeWorldMatrix(I);
  Result := V3(M[12], M[13], M[14]);
end;

function TGlbDoc.ComputeMainSkinIndex: Integer;
var
  I, MeshI, SkinI, AccI, Cnt, Best: Integer;
  NodeO, MeshO, Prim: TJSONObject;
begin
  { glTF "skeleton" is optional (fema has none). Pick the skin of the
    largest non-accessory skinned mesh — that is the body. }
  Best := -1;
  Result := -1;
  for I := 0 to NodeCount - 1 do
  begin
    NodeO := NodeObj(I);
    if IsAccessoryName(NodeName(I)) then Continue;
    MeshI := IntOf(NodeO, 'mesh', -1);
    SkinI := IntOf(NodeO, 'skin', -1);
    if (MeshI < 0) or (SkinI < 0) then Continue;
    MeshO := ObjAt(ArrOf(FRoot, 'meshes'), MeshI);
    Prim := ObjAt(ArrOf(MeshO, 'primitives'), 0);
    AccI := IntOf(ObjOf(Prim, 'attributes'), 'POSITION', -1);
    Cnt := IntOf(ObjAt(ArrOf(FRoot, 'accessors'), AccI), 'count', 0);
    if Cnt > Best then
    begin
      Best := Cnt;
      Result := SkinI;
    end;
  end;
end;

function TGlbDoc.MainSkinIndex: Integer;
begin
  if not FHierarchyValid then
    RebuildHierarchy;
  Result := FMainSkin;
end;

function TGlbDoc.ComputeMainArmature: Integer;
var
  I, Skel, Cnt, Best, N: Integer;
  Skin: TJSONObject;
  Nm: string;

  function CachedParent(Idx: Integer): Integer;
  begin
    if (Idx >= 0) and (Idx < Length(FParent)) then
      Result := FParent[Idx]
    else
      Result := -1;
  end;

begin
  Result := -1;
  if FMainSkin >= 0 then
  begin
    Skin := ObjAt(Skins, FMainSkin);
    Skel := IntOf(Skin, 'skeleton', -1);
    if Skel < 0 then
      Skel := ArrInt(ArrOf(Skin, 'joints'), 0, -1);
    Result := Skel;
    I := Result;
    while I >= 0 do
    begin
      if NameHasPrefix(NodeName(I), 'Armature') then
        Exit(I);
      I := CachedParent(I);
    end;
    I := Result;
    while CachedParent(I) >= 0 do
      I := CachedParent(I);
    Result := I;
    Exit;
  end;
  Result := FindNode('Armature');
  if Result >= 0 then Exit;
  Best := -1;
  Result := -1;
  N := NodeCount;
  for I := 0 to N - 1 do
  begin
    Nm := NodeName(I);
    if IsAccessoryName(Nm) then Continue;
    Cnt := CountOf(ArrOf(NodeObj(I), 'children'));
    if Cnt > Best then
    begin
      Best := Cnt;
      Result := I;
    end;
  end;
end;

function TGlbDoc.MainArmature: Integer;
begin
  if not FHierarchyValid then
    RebuildHierarchy;
  Result := FMainArm;
end;

function TGlbDoc.IsUnder(Node, Root: Integer): Boolean;
var
  N: Integer;
begin
  Result := False;
  if Root < 0 then Exit;
  N := Node;
  while N >= 0 do
  begin
    if N = Root then Exit(True);
    N := ParentOf(N);
  end;
end;



function TGlbDoc.FindJoint(const AName: string): Integer;
var
  I, Arm: Integer;
begin
  Result := -1;
  Arm := MainArmature;
  if Arm >= 0 then
    for I := 0 to NodeCount - 1 do
      if SameText(NodeName(I), AName) and IsUnder(I, Arm) then
        Exit(I);
  Result := FindNode(AName);
end;

function TGlbDoc.IsBodyJoint(I: Integer): Boolean;
begin
  Result := False;
  if not FHierarchyValid then
    RebuildHierarchy;
  if (I >= 0) and (I < Length(FIsBodyJoint)) then
    Result := FIsBodyJoint[I];
end;

function TGlbDoc.MeshExtentY: Double;
var
  I, MeshI, SkinI, AccI, BvI, Cnt, Comp, Stride, Off, K: Integer;
  Best, ByteOff: Integer;
  NodeO, MeshO, Prim, Acc, Bv: TJSONObject;
  Typ: string;
  Y, YMin, YMax: Double;
  Have: Boolean;
begin
  Result := 1.0;
  Best := -1;
  AccI := -1;
  for I := 0 to NodeCount - 1 do
  begin
    NodeO := NodeObj(I);
    MeshI := IntOf(NodeO, 'mesh', -1);
    SkinI := IntOf(NodeO, 'skin', -1);
    if (MeshI < 0) or (SkinI < 0) then Continue;
    if IsAccessoryName(NodeName(I)) then Continue;
    MeshO := ObjAt(ArrOf(FRoot, 'meshes'), MeshI);
    Prim := ObjAt(ArrOf(MeshO, 'primitives'), 0);
    K := IntOf(ObjOf(Prim, 'attributes'), 'POSITION', -1);
    Cnt := IntOf(ObjAt(ArrOf(FRoot, 'accessors'), K), 'count', 0);
    if Cnt > Best then
    begin
      Best := Cnt;
      AccI := K;
    end;
  end;
  if AccI < 0 then Exit;
  Acc := ObjAt(ArrOf(FRoot, 'accessors'), AccI);
  { glTF accessors usually ship min/max — skip the vertex walk. }
  if (ArrOf(Acc, 'min') <> nil) and (ArrOf(Acc, 'max') <> nil) then
  begin
    Result := ArrFloat(ArrOf(Acc, 'max'), 1, 0) - ArrFloat(ArrOf(Acc, 'min'), 1, 0);
    if Result < 1e-6 then Result := 1.0;
    Exit;
  end;
  BvI := IntOf(Acc, 'bufferView', -1);
  Bv := ObjAt(ArrOf(FRoot, 'bufferViews'), BvI);
  if Bv = nil then Exit;
  Cnt := IntOf(Acc, 'count', 0);
  Comp := IntOf(Acc, 'componentType', 5126);
  if Comp <> 5126 then Exit;
  Typ := StrOf(Acc, 'type', 'VEC3');
  if Typ <> 'VEC3' then Exit;
  Off := IntOf(Bv, 'byteOffset', 0) + IntOf(Acc, 'byteOffset', 0);
  Stride := IntOf(Bv, 'byteStride', 12);
  if Stride < 12 then Stride := 12;
  Have := False;
  YMin := 0;
  YMax := 0;
  for K := 0 to Cnt - 1 do
  begin
    ByteOff := Off + K * Stride + 4; { Y }
    Y := ReadF32(FBin, ByteOff);
    if not Have then
    begin
      YMin := Y; YMax := Y; Have := True;
    end
    else
    begin
      if Y < YMin then YMin := Y;
      if Y > YMax then YMax := Y;
    end;
  end;
  if Have then
    Result := YMax - YMin;
end;

procedure TGlbDoc.RecomputeSkinIBM(SkinI: Integer);
var
  Skin, Acc, Bv: TJSONObject;
  Js: TJSONArray;
  AccI, J, K, Off, Need, Joint: Integer;
  Inv: TMat4;
  F: array[0..15] of Single;
begin
  Skin := ObjAt(Skins, SkinI);
  if Skin = nil then Exit;
  Js := ArrOf(Skin, 'joints');
  if CountOf(Js) <= 0 then Exit;
  AccI := IntOf(Skin, 'inverseBindMatrices', -1);
  Acc := ObjAt(ArrOf(FRoot, 'accessors'), AccI);
  if Acc = nil then Exit;
  Bv := ObjAt(ArrOf(FRoot, 'bufferViews'), IntOf(Acc, 'bufferView', -1));
  if Bv = nil then Exit;
  Off := IntOf(Bv, 'byteOffset', 0) + IntOf(Acc, 'byteOffset', 0);
  Need := CountOf(Js) * 64;
  if Off + Need > Length(FBin) then
  begin
    SetLength(FBin, Off + Need);
    if Bv.Find('byteLength') <> nil then Bv.Delete('byteLength');
    Bv.Add('byteLength', Need);
    TouchBufferLength;
  end;
  for J := 0 to CountOf(Js) - 1 do
  begin
    Joint := ArrInt(Js, J, -1);
    if not M4InvertAffine(NodeWorldMatrix(Joint), Inv) then
      Inv := M4Ident;
    for K := 0 to 15 do
      F[K] := Single(Inv[K]);
    Move(F[0], FBin[Off + J * 64], 64);
  end;
end;

procedure TGlbDoc.RecomputeBodyIBMs;
var
  S: Integer;
  Skin: TJSONObject;
begin
  for S := 0 to CountOf(Skins) - 1 do
  begin
    Skin := ObjAt(Skins, S);
    if Skin = nil then Continue;
    if IsAccessoryName(StrOf(Skin, 'name', '')) then Continue;
    if CountOf(ArrOf(Skin, 'joints')) < 2 then Continue;
    RecomputeSkinIBM(S);
  end;
end;

procedure AddChild(Parent: TJSONObject; ChildIdx: Integer);
var
  Ch: TJSONArray;
begin
  Ch := ArrOf(Parent, 'children');
  if Ch = nil then
  begin
    Ch := TJSONArray.Create;
    Parent.Add('children', Ch);
  end;
  Ch.Add(ChildIdx);
end;

function TGlbDoc.AppendBytes(const P; Len: Integer): Integer;
var
  Ofs, N: Integer;
begin
  Ofs := Length(FBin);
  Ofs := (Ofs + 3) and not 3;
  N := Len;
  if N < 0 then N := 0;
  SetLength(FBin, Ofs + N);
  if N > 0 then
    Move(P, FBin[Ofs], N);
  TouchBufferLength;
  Result := Ofs;
end;

procedure TGlbDoc.WriteF32(Ofs: Integer; V: Single);
begin
  if (Ofs < 0) or (Ofs + 4 > Length(FBin)) then Exit;
  Move(V, FBin[Ofs], 4);
end;

procedure TGlbDoc.WriteBytes(Ofs: Integer; const P; Len: Integer);
begin
  if (Len <= 0) or (Ofs < 0) or (Ofs + Len > Length(FBin)) then Exit;
  Move(P, FBin[Ofs], Len);
end;

function TGlbDoc.FindMainPrimitive(out MeshO, Prim: TJSONObject;
  out SkinI: Integer; out NodeI: Integer): Boolean;
var
  I, J, MeshI, AccI, Cnt, Best, BestSkin, BestNode, JerseyI: Integer;
  NodeO, MeshCur, PrimFirst, P, Attr, Ex: TJSONObject;
  Prims, Names: TJSONArray;
  Nm: string;
begin
  Result := False;
  MeshO := nil;
  Prim := nil;
  SkinI := -1;
  NodeI := -1;
  Best := -1;
  BestSkin := -1;
  BestNode := -1;
  for I := 0 to NodeCount - 1 do
  begin
    NodeO := NodeObj(I);
    MeshI := IntOf(NodeO, 'mesh', -1);
    if (MeshI < 0) or (IntOf(NodeO, 'skin', -1) < 0) then Continue;
    if IsAccessoryName(NodeName(I)) then Continue;
    MeshCur := ObjAt(ArrOf(FRoot, 'meshes'), MeshI);
    Prims := ArrOf(MeshCur, 'primitives');
    if Prims = nil then Continue;
    Cnt := 0;
    PrimFirst := nil;
    for J := 0 to Prims.Count - 1 do
    begin
      P := ObjAt(Prims, J);
      Attr := ObjOf(P, 'attributes');
      if (Attr = nil) or (Attr.Find('JOINTS_0') = nil) then Continue;
      if PrimFirst = nil then
        PrimFirst := P;
      AccI := IntOf(Attr, 'POSITION', -1);
      if AccI >= 0 then
        Cnt := Cnt + IntOf(ObjAt(ArrOf(FRoot, 'accessors'), AccI), 'count', 0);
    end;
    if (Cnt > Best) and (PrimFirst <> nil) then
    begin
      Best := Cnt;
      MeshO := MeshCur;
      Prim := PrimFirst;
      BestSkin := IntOf(NodeO, 'skin', -1);
      BestNode := I;
    end;
  end;
  { After Split prim[0] is Boots. Jersey is the hem target. }
  if MeshO <> nil then
  begin
    Ex := ObjOf(FRoot, 'extras');
    Names := ArrOf(Ex, 'avatarPartNames');
    Prims := ArrOf(MeshO, 'primitives');
    if (Names <> nil) and (Prims <> nil) then
    begin
      JerseyI := -1;
      for J := 0 to Names.Count - 1 do
      begin
        Nm := '';
        if Names.Items[J] <> nil then
          Nm := Names.Items[J].AsString;
        if SameText(Nm, 'Jersey') then
        begin
          JerseyI := J;
          Break;
        end;
      end;
      if (JerseyI >= 0) and (JerseyI < Prims.Count) then
        Prim := ObjAt(Prims, JerseyI);
    end;
  end;
  SkinI := BestSkin;
  NodeI := BestNode;
  Result := (Prim <> nil) and (Best > 0);
end;

procedure TGlbDoc.RefreshHierarchy;
begin
  InvalidateHierarchy;
  RebuildHierarchy;
end;

function TGlbDoc.ImageBuffer(ImgI: Integer; out Mime: string;
  out Data: TBytes): Boolean;
var
  Im, Bv: TJSONObject;
  Off, Len: Integer;
begin
  Result := False;
  Mime := '';
  SetLength(Data, 0);
  Im := ObjAt(ArrOf(FRoot, 'images'), ImgI);
  if Im = nil then Exit;
  Mime := StrOf(Im, 'mimeType', 'image/png');
  Bv := ObjAt(ArrOf(FRoot, 'bufferViews'), IntOf(Im, 'bufferView', -1));
  if Bv = nil then Exit;
  Off := IntOf(Bv, 'byteOffset', 0);
  Len := IntOf(Bv, 'byteLength', 0);
  if (Off < 0) or (Len <= 0) or (Off + Len > Length(FBin)) then Exit;
  SetLength(Data, Len);
  Move(FBin[Off], Data[0], Len);
  Result := True;
end;

procedure TGlbDoc.TouchBufferLength;
var
  Buf: TJSONObject;
  BufA: TJSONArray;
begin
  BufA := EnsureArr('buffers');
  if BufA.Count = 0 then
  begin
    Buf := TJSONObject.Create;
    Buf.Add('byteLength', Length(FBin));
    BufA.Add(Buf);
  end
  else
  begin
    Buf := ObjAt(BufA, 0);
    if Buf.Find('byteLength') <> nil then Buf.Delete('byteLength');
    Buf.Add('byteLength', Length(FBin));
  end;
end;

function TGlbDoc.AddContactArmature(const AName: string; const WorldPos: TVec3): Integer;
var
  RootN, BoneN: TJSONObject;
  Skin: TJSONObject;
  Joints: TJSONArray;
  Scene0: TJSONObject;
  NodesA, SkinsA, AccA, BvA: TJSONArray;
  Acc, Bv: TJSONObject;
  IBM: array[0..15] of Single;
  AccI, BvI, Bin0: Integer;
  ScN: TJSONArray;
begin
  if ContactExists(AName) then
    Exit(FindNode(AName));

  NodesA := EnsureArr('nodes');
  Result := NodesA.Count;

  RootN := TJSONObject.Create;
  RootN.Add('name', AName);
  RootN.Add('translation', VecArr(WorldPos));
  NodesA.Add(RootN);

  BoneN := TJSONObject.Create;
  BoneN.Add('name', 'Bone_' + AName);
  NodesA.Add(BoneN);
  AddChild(RootN, Result + 1);

  FillChar(IBM, SizeOf(IBM), 0);
  IBM[0] := 1; IBM[5] := 1; IBM[10] := 1; IBM[15] := 1;
  Bin0 := Length(FBin);
  SetLength(FBin, Bin0 + 64);
  Move(IBM[0], FBin[Bin0], 64);

  AccA := EnsureArr('accessors');
  BvA := EnsureArr('bufferViews');
  TouchBufferLength;

  BvI := BvA.Count;
  Bv := TJSONObject.Create;
  Bv.Add('buffer', 0);
  Bv.Add('byteOffset', Bin0);
  Bv.Add('byteLength', 64);
  BvA.Add(Bv);

  AccI := AccA.Count;
  Acc := TJSONObject.Create;
  Acc.Add('bufferView', BvI);
  Acc.Add('componentType', 5126);
  Acc.Add('count', 1);
  Acc.Add('type', 'MAT4');
  AccA.Add(Acc);

  SkinsA := EnsureArr('skins');
  Skin := TJSONObject.Create;
  Skin.Add('name', AName);
  Skin.Add('skeleton', Result);
  Joints := TJSONArray.Create;
  Joints.Add(Result + 1);
  Skin.Add('joints', Joints);
  Skin.Add('inverseBindMatrices', AccI);
  SkinsA.Add(Skin);

  if CountOf(Scenes) = 0 then
  begin
    Scene0 := TJSONObject.Create;
    ScN := TJSONArray.Create;
    Scene0.Add('nodes', ScN);
    EnsureArr('scenes').Add(Scene0);
    if FRoot.Find('scene') = nil then
      FRoot.Add('scene', 0);
  end;
  Scene0 := ObjAt(Scenes, 0);
  if Scene0 = nil then Exit;
  ScN := ArrOf(Scene0, 'nodes');
  if ScN = nil then
  begin
    ScN := TJSONArray.Create;
    Scene0.Add('nodes', ScN);
  end;
  ScN.Add(Result);
  RebuildHierarchy;
end;

function TGlbDoc.CloneAccessorFrom(Src: TGlbDoc; SrcAccI: Integer): Integer;
var
  SA, SB, NewA, NewV: TJSONObject;
  Off, Len, DestOff, NewBv: Integer;
  SrcAcc, SrcBv: TJSONArray;
begin
  Result := -1;
  if Src = nil then Exit;
  SrcAcc := ArrOf(Src.Root, 'accessors');
  SrcBv := ArrOf(Src.Root, 'bufferViews');
  SA := ObjAt(SrcAcc, SrcAccI);
  if SA = nil then Exit;
  SB := ObjAt(SrcBv, IntOf(SA, 'bufferView', -1));
  if SB = nil then Exit;
  Off := IntOf(SB, 'byteOffset', 0) + IntOf(SA, 'byteOffset', 0);
  Len := IntOf(SB, 'byteLength', 0);
  if IntOf(SA, 'byteOffset', 0) > 0 then
  begin
    { copy the whole view; accessor keeps its own byteOffset }
    Off := IntOf(SB, 'byteOffset', 0);
    Len := IntOf(SB, 'byteLength', 0);
  end;
  if (Off < 0) or (Off + Len > Length(Src.FBin)) then Exit;
  DestOff := (Length(FBin) + 3) and not 3;
  SetLength(FBin, DestOff + Len);
  if Len > 0 then
    Move(Src.FBin[Off], FBin[DestOff], Len);
  NewV := TJSONObject.Create;
  NewV.Add('buffer', 0);
  NewV.Add('byteOffset', DestOff);
  NewV.Add('byteLength', Len);
  if HasKey(SB, 'byteStride') then
    NewV.Add('byteStride', IntOf(SB, 'byteStride', 0));
  if HasKey(SB, 'target') then
    NewV.Add('target', IntOf(SB, 'target', 34962));
  NewBv := EnsureArr('bufferViews').Count;
  EnsureArr('bufferViews').Add(NewV);

  NewA := TJSONObject.Create;
  NewA.Add('bufferView', NewBv);
  NewA.Add('componentType', IntOf(SA, 'componentType', 5126));
  NewA.Add('count', IntOf(SA, 'count', 0));
  NewA.Add('type', StrOf(SA, 'type', 'VEC3'));
  if HasKey(SA, 'byteOffset') then
    NewA.Add('byteOffset', IntOf(SA, 'byteOffset', 0));
  if HasKey(SA, 'normalized') then
    NewA.Add('normalized', SA.Find('normalized').AsBoolean);
  Result := EnsureArr('accessors').Count;
  EnsureArr('accessors').Add(NewA);
  TouchBufferLength;
end;

function TGlbDoc.CloneImageFrom(Src: TGlbDoc; SrcImgI: Integer): Integer;
var
  SI, SB, NewI, NewV: TJSONObject;
  SrcImgs, SrcBv: TJSONArray;
  Off, Len, DestOff, NewBv: Integer;
  ImagePath, Mime: string;
  ImageData: TBytes;
begin
  Result := -1;
  SrcImgs := ArrOf(Src.Root, 'images');
  SrcBv := ArrOf(Src.Root, 'bufferViews');
  SI := ObjAt(SrcImgs, SrcImgI);
  if SI = nil then Exit;
  NewI := TJSONObject.Create;
  if HasKey(SI, 'mimeType') then
    NewI.Add('mimeType', StrOf(SI, 'mimeType', 'image/png'));
  if HasKey(SI, 'name') then
    NewI.Add('name', StrOf(SI, 'name', ''));
  if HasKey(SI, 'uri') then
  begin
    ImagePath := StrOf(SI, 'uri', '');
    if Pos('data:', ImagePath) = 1 then NewI.Add('uri', ImagePath)
    else begin
      ImagePath := ExpandFileName(ExtractFilePath(Src.Path) + ImagePath);
      if not FileExists(ImagePath) then begin NewI.Free;raise EReadError.Create('Clothing texture not found: '+ImagePath) end;
      ImageData := LoadFileBytes(ImagePath);
      if Length(ImageData)=0 then begin NewI.Free;raise EReadError.Create('Empty clothing texture') end;
      DestOff := AppendBytes(ImageData[0],Length(ImageData));
      NewV := TJSONObject.Create(['buffer',0,'byteOffset',DestOff,'byteLength',Length(ImageData)]);
      NewBv := EnsureArr('bufferViews').Count;EnsureArr('bufferViews').Add(NewV);
      NewI.Add('bufferView',NewBv);
      Mime := 'image/png';
      if SameText(ExtractFileExt(ImagePath),'.jpg') or SameText(ExtractFileExt(ImagePath),'.jpeg') then Mime:='image/jpeg';
      NewI.Delete('mimeType');NewI.Add('mimeType',Mime);
    end;
  end
  else
  begin
    SB := ObjAt(SrcBv, IntOf(SI, 'bufferView', -1));
    if SB = nil then
    begin
      NewI.Free;
      Exit;
    end;
    Off := IntOf(SB, 'byteOffset', 0);
    Len := IntOf(SB, 'byteLength', 0);
    if (Off < 0) or (Off + Len > Length(Src.FBin)) then
    begin
      NewI.Free;
      Exit;
    end;
    DestOff := (Length(FBin) + 3) and not 3;
    SetLength(FBin, DestOff + Len);
    if Len > 0 then
      Move(Src.FBin[Off], FBin[DestOff], Len);
    NewV := TJSONObject.Create;
    NewV.Add('buffer', 0);
    NewV.Add('byteOffset', DestOff);
    NewV.Add('byteLength', Len);
    NewBv := EnsureArr('bufferViews').Count;
    EnsureArr('bufferViews').Add(NewV);
    NewI.Add('bufferView', NewBv);
    TouchBufferLength;
  end;
  Result := EnsureArr('images').Count;
  EnsureArr('images').Add(NewI);
end;

function TGlbDoc.CloneTextureFrom(Src: TGlbDoc; SrcTexI: Integer): Integer;
var
  ST, NewT, NewS: TJSONObject;
  SrcTex, SrcSamp: TJSONArray;
  ImgI, SampI: Integer;
begin
  Result := -1;
  SrcTex := ArrOf(Src.Root, 'textures');
  ST := ObjAt(SrcTex, SrcTexI);
  if ST = nil then Exit;
  NewT := TJSONObject.Create;
  ImgI := IntOf(ST, 'source', -1);
  if ImgI >= 0 then
    NewT.Add('source', CloneImageFrom(Src, ImgI));
  SampI := IntOf(ST, 'sampler', -1);
  SrcSamp := ArrOf(Src.Root, 'samplers');
  if (SampI >= 0) and (ObjAt(SrcSamp, SampI) <> nil) then
  begin
    NewS := TJSONObject(ObjAt(SrcSamp, SampI).Clone);
    NewT.Add('sampler', EnsureArr('samplers').Count);
    EnsureArr('samplers').Add(NewS);
  end;
  Result := EnsureArr('textures').Count;
  EnsureArr('textures').Add(NewT);
end;

function TGlbDoc.CloneMaterialFrom(Src: TGlbDoc; SrcMatI: Integer): Integer;
var
  SM, NewM, Pbr: TJSONObject;
  SrcMats: TJSONArray;

  procedure RemapTex(Parent: TJSONObject; const Key: string);
  var
    T: TJSONObject;
    TI: Integer;
  begin
    T := ObjOf(Parent, Key);
    if T = nil then Exit;
    TI := IntOf(T, 'index', -1);
    if TI < 0 then Exit;
    if T.Find('index') <> nil then T.Delete('index');
    T.Add('index', CloneTextureFrom(Src, TI));
  end;

begin
  Result := -1;
  SrcMats := ArrOf(Src.Root, 'materials');
  SM := ObjAt(SrcMats, SrcMatI);
  if SM = nil then Exit;
  NewM := TJSONObject(SM.Clone);
  Pbr := ObjOf(NewM, 'pbrMetallicRoughness');
  if Pbr <> nil then
  begin
    RemapTex(Pbr, 'baseColorTexture');
    RemapTex(Pbr, 'metallicRoughnessTexture');
  end;
  RemapTex(NewM, 'normalTexture');
  RemapTex(NewM, 'occlusionTexture');
  RemapTex(NewM, 'emissiveTexture');
  Result := EnsureArr('materials').Count;
  EnsureArr('materials').Add(NewM);
end;

function TGlbDoc.EnsureHelmetAnchor(const WorldPos: TVec3): Integer;
var N, Scene: TJSONObject; A: TJSONArray;
begin
  Result := FindNode('Helmet');
  if Result >= 0 then Exit;
  N := TJSONObject.Create;
  N.Add('name', 'Helmet');
  N.Add('translation', TJSONArray.Create([WorldPos.X, WorldPos.Y, WorldPos.Z]));
  Result := EnsureArr('nodes').Count; EnsureArr('nodes').Add(N);
  Scene := ObjAt(Scenes, IntOf(FRoot, 'scene', 0));
  if Scene = nil then raise EReadError.Create('Avatar has no scene');
  A := ArrOf(Scene, 'nodes');
  if A = nil then begin A := TJSONArray.Create; Scene.Add('nodes', A) end;
  A.Add(Result); InvalidateHierarchy;
end;

function TGlbDoc.ImportUnskinnedMesh(Src: TGlbDoc; const AName: string;
  const WorldPos: TVec3): Integer;
var
  SrcMeshes: TJSONArray;
  MeshI, NodeI, AccI, NewAcc, MeshIdx, BestMesh, BestVerts, Cnt: Integer;
  MeshO, Prim, Attr, NewMesh, NewPrim, NewAttr, NewNode: TJSONObject;
  Scene0: TJSONObject;
  ScN: TJSONArray;
  MatI: Integer;
begin
  Result := FindNode(AName);
  if Result >= 0 then
  begin
    SetNodeTranslation(Result, WorldPos);
    Exit;
  end;
  if Src = nil then Exit(-1);

  SrcMeshes := ArrOf(Src.Root, 'meshes');
  BestMesh := -1;
  BestVerts := -1;
  NodeI := Src.FindNode('Helmet');
  if NodeI >= 0 then
    MeshIdx := IntOf(Src.NodeObj(NodeI), 'mesh', -1)
  else
    MeshIdx := -1;
  if MeshIdx < 0 then
  begin
    for MeshI := 0 to CountOf(SrcMeshes) - 1 do
    begin
      MeshO := ObjAt(SrcMeshes, MeshI);
      Cnt := 0;
      Prim := ObjAt(ArrOf(MeshO, 'primitives'), 0);
      if Prim <> nil then
      begin
        AccI := IntOf(ObjOf(Prim, 'attributes'), 'POSITION', -1);
        if AccI >= 0 then
          Cnt := IntOf(ObjAt(ArrOf(Src.Root, 'accessors'), AccI), 'count', 0);
      end;
      if Cnt > BestVerts then
      begin
        BestVerts := Cnt;
        BestMesh := MeshI;
      end;
    end;
    MeshIdx := BestMesh;
  end;
  if MeshIdx < 0 then Exit(-1);

  MeshO := ObjAt(SrcMeshes, MeshIdx);
  NewMesh := TJSONObject.Create;
  NewMesh.Add('name', AName);
  NewMesh.Add('primitives', TJSONArray.Create);
  Prim := ObjAt(ArrOf(MeshO, 'primitives'), 0);
  NewPrim := TJSONObject.Create;
  NewAttr := TJSONObject.Create;
  NewPrim.Add('attributes', NewAttr);
  TJSONArray(NewMesh.Find('primitives')).Add(NewPrim);

  Attr := ObjOf(Prim, 'attributes');
  if Attr <> nil then
  begin
    if HasKey(Attr, 'POSITION') then
    begin
      NewAcc := CloneAccessorFrom(Src, IntOf(Attr, 'POSITION', -1));
      if NewAcc >= 0 then NewAttr.Add('POSITION', NewAcc);
    end;
    if HasKey(Attr, 'NORMAL') then
    begin
      NewAcc := CloneAccessorFrom(Src, IntOf(Attr, 'NORMAL', -1));
      if NewAcc >= 0 then NewAttr.Add('NORMAL', NewAcc);
    end;
    if HasKey(Attr, 'TEXCOORD_0') then
    begin
      NewAcc := CloneAccessorFrom(Src, IntOf(Attr, 'TEXCOORD_0', -1));
      if NewAcc >= 0 then NewAttr.Add('TEXCOORD_0', NewAcc);
    end;
  end;
  if HasKey(Prim, 'indices') then
  begin
    NewAcc := CloneAccessorFrom(Src, IntOf(Prim, 'indices', -1));
    if NewAcc >= 0 then NewPrim.Add('indices', NewAcc);
  end;
  MatI := IntOf(Prim, 'material', -1);
  if MatI >= 0 then
  begin
    NewAcc := CloneMaterialFrom(Src, MatI);
    if NewAcc >= 0 then NewPrim.Add('material', NewAcc);
  end;

  MeshI := EnsureArr('meshes').Count;
  EnsureArr('meshes').Add(NewMesh);

  NewNode := TJSONObject.Create;
  NewNode.Add('name', AName);
  NewNode.Add('mesh', MeshI);
  NewNode.Add('translation', VecArr(WorldPos));
  Result := EnsureArr('nodes').Count;
  EnsureArr('nodes').Add(NewNode);

  Scene0 := ObjAt(Scenes, 0);
  if Scene0 <> nil then
  begin
    ScN := ArrOf(Scene0, 'nodes');
    if ScN = nil then
    begin
      ScN := TJSONArray.Create;
      Scene0.Add('nodes', ScN);
    end;
    ScN.Add(Result);
  end;
  RebuildHierarchy;
end;

end.
