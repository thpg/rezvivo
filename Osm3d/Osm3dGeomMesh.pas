unit Osm3dGeomMesh;

{ overflow/range-проверки выключены намеренно: хеши/упаковка битов рассчитывают на заворот }
{$Q-}{$R-}

{$mode objfpc}{$H+}
{$modeswitch advancedrecords}
{$codepage UTF8}

{$WARN 5091 OFF}

interface

uses
  Classes,
  SysUtils,
  CastleVectors
  {$IFDEF IAM_LIVE}, Osm3dIamLive{$ENDIF}
;

type
  TMeshVertex = record
    Position: TVector3;
    Normal:   TVector3;
    UV:       TVector2;
    { OSM id of the source object (way/relation/node); 0 = none (terrain, procedural).
      Rides the vertex record, so it survives AppendMesh / SplitMesh / composite accumulation.
      Builders set TMesh.CurrentOsmId; AddVertex stamps it. }
    OsmId:    Int64;
  end;
  TMeshVertexArray = array of TMeshVertex;
  TMeshIndexArray  = array of Cardinal;

  TMesh = class
  private
    FVertices:    TMeshVertexArray;
    FIndices:     TMeshIndexArray;
    FVertexCount: Integer;
    FIndexCount:  Integer;
    FVertexCap:   Integer;
    FIndexCap:    Integer;
    FName:        string;
    { Stamped onto vertices added without their own OsmId; a builder sets it per OSM object. }
    FCurrentOsmId: Int64;

    function GetVertexCount: Integer; inline;
    function GetTriangleCount: Integer; inline;
    function GetVertices: TMeshVertexArray;
    function GetIndices: TMeshIndexArray;

    procedure GrowVertices;
    procedure GrowIndices;
  public
    constructor Create(const AName: string = '');

    { Pre-allocate; safe to call multiple times. Only grows, never shrinks. }
    procedure ReserveVertices(ACount: Integer);
    procedure ReserveIndices(ACount: Integer);
    { Adopt validated cache arrays without copying or growing them vertex by vertex. }
    procedure AdoptGeometry(const AVertices: TMeshVertexArray;
      const AIndices: TMeshIndexArray);

    { Add a vertex; returns its index. }
    function AddVertex(const APos: TVector3): Integer; overload; inline;
    function AddVertex(const APos, ANormal: TVector3): Integer; overload; inline;
    function AddVertex(const APos, ANormal: TVector3;
                       const AUV: TVector2): Integer; overload; inline;
    function AddVertex(const V: TMeshVertex): Integer; overload; inline;

    procedure AddTriangle(I0, I1, I2: Integer); inline;
    procedure AddQuad(I0, I1, I2, I3: Integer); inline;

    { Overwrite the normal of an already-added vertex
      (used by TTerrainBuilder for two-pass gradient normals). }
    procedure SetVertexNormal(Index: Integer; const N: TVector3); inline;
    procedure SetVertexPosition(Index: Integer; const P: TVector3); inline;
    { Overwrite the UV of an already-added vertex (used by the building
      composite merge to bake planar roof UV before appending). }
    procedure SetVertexUV(Index: Integer; const UV: TVector2); inline;

    { Append Other into Self with re-indexing. Other is not modified or freed. }
    procedure AppendMesh(Other: TMesh);

    { Make each triangle's winding agree with its vertices' stored normals (front face = the
      side builders intended outward), so building shapes can render Solid=True. Swaps the two
      non-pivot indices when the geometric normal opposes the average stored normal. }
    procedure MakeWindingMatchNormals;

    { Smooth (vertex-shared) normals: area-weighted sum across incident
      faces, then normalised. }
    procedure ComputeSmoothNormals;

    procedure Clear;

    { Trims to live count on read; intended for export, not hot loops. }
    property Vertices: TMeshVertexArray read GetVertices;
    property Indices:  TMeshIndexArray  read GetIndices;

    property Name:          string  read FName write FName;
    property VertexCount:   Integer read GetVertexCount;
    property TriangleCount: Integer read GetTriangleCount;

    { OSM id stamped onto subsequently-added vertices; a builder sets it per object, back to 0
      when done. Vertices that already carry a non-zero id keep it. }
    property CurrentOsmId: Int64 read FCurrentOsmId write FCurrentOsmId;
  end;
  TMeshArray = array of TMesh;

function VecLength(const V: TVector3): Single; inline;
function VecNormalize(const V: TVector3): TVector3; inline;
function VecCross(const A, B: TVector3): TVector3; inline;
function VecDot(const A, B: TVector3): Single; inline;
function MakeVertex(const APos: TVector3): TMeshVertex; inline;
function MakeVertex2(const APos, ANormal: TVector3): TMeshVertex; inline;
function MakeUV(U, V: Single): TVector2; inline;

implementation

procedure TMesh.AdoptGeometry(const AVertices: TMeshVertexArray;
  const AIndices: TMeshIndexArray);
begin
  FVertices := AVertices; FVertexCount := Length(AVertices);
  FVertexCap := FVertexCount;
  FIndices := AIndices; FIndexCount := Length(AIndices);
  FIndexCap := FIndexCount;
end;

function VecLength(const V: TVector3): Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1308);{$ENDIF}
  Result := Sqrt(V.X * V.X + V.Y * V.Y + V.Z * V.Z);
end;

function VecNormalize(const V: TVector3): TVector3;
var
  L: Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1309);{$ENDIF}
  L := VecLength(V);
  if L < 1.0e-12 then
  begin
    Result.X := 0;  Result.Y := 1;  Result.Z := 0;
    Exit;
  end;
  Result.X := V.X / L;
  Result.Y := V.Y / L;
  Result.Z := V.Z / L;
end;

function VecCross(const A, B: TVector3): TVector3;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1310);{$ENDIF}
  Result.X := A.Y * B.Z - A.Z * B.Y;
  Result.Y := A.Z * B.X - A.X * B.Z;
  Result.Z := A.X * B.Y - A.Y * B.X;
end;

function VecDot(const A, B: TVector3): Single;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(266);{$ENDIF}
  Result := A.X * B.X + A.Y * B.Y + A.Z * B.Z;
end;

function MakeVertex(const APos: TVector3): TMeshVertex;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(267);{$ENDIF}
  Result.Position := APos;
  Result.Normal.X := 0;  Result.Normal.Y := 1;  Result.Normal.Z := 0;
  Result.UV.X := 0;      Result.UV.Y := 0;
  Result.OsmId := 0;     { AddVertex stamps the mesh's CurrentOsmId }
end;

function MakeVertex2(const APos, ANormal: TVector3): TMeshVertex;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(268);{$ENDIF}
  Result.Position := APos;
  Result.Normal   := ANormal;
  Result.UV.X := 0;  Result.UV.Y := 0;
  Result.OsmId := 0;
end;

function MakeUV(U, V: Single): TVector2;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(269);{$ENDIF}
  Result.X := U;
  Result.Y := V;
end;

constructor TMesh.Create(const AName: string);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1088);{$ENDIF}
  inherited Create;
  FName        := AName;
  FVertexCount := 0;
  FIndexCount  := 0;
  FVertexCap   := 0;
  FIndexCap    := 0;
  FCurrentOsmId := 0;
end;

function TMesh.GetVertexCount: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(270);{$ENDIF}
  Result := FVertexCount;
end;

function TMesh.GetTriangleCount: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(271);{$ENDIF}
  Result := FIndexCount div 3;
end;

function TMesh.GetVertices: TMeshVertexArray;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(272);{$ENDIF}
  { Trim to live count so the caller sees exactly VertexCount elements. }
  if Length(FVertices) <> FVertexCount then
  begin
    SetLength(FVertices, FVertexCount);
    FVertexCap := FVertexCount;
  end;
  Result := FVertices;
end;

function TMesh.GetIndices: TMeshIndexArray;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(273);{$ENDIF}
  if Length(FIndices) <> FIndexCount then
  begin
    SetLength(FIndices, FIndexCount);
    FIndexCap := FIndexCount;
  end;
  Result := FIndices;
end;

procedure TMesh.ReserveVertices(ACount: Integer);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(274);{$ENDIF}
  if ACount > FVertexCap then
  begin
    SetLength(FVertices, ACount);
    FVertexCap := ACount;
  end;
end;

procedure TMesh.ReserveIndices(ACount: Integer);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(275);{$ENDIF}
  if ACount > FIndexCap then
  begin
    SetLength(FIndices, ACount);
    FIndexCap := ACount;
  end;
end;

procedure TMesh.GrowVertices;
var
  NewCap: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(276);{$ENDIF}
  if FVertexCap = 0 then NewCap := 64
  else                    NewCap := FVertexCap * 2;
  SetLength(FVertices, NewCap);
  FVertexCap := NewCap;
end;

procedure TMesh.GrowIndices;
var
  NewCap: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(277);{$ENDIF}
  if FIndexCap = 0 then NewCap := 192    { 64 triangles * 3 }
  else                  NewCap := FIndexCap * 2;
  SetLength(FIndices, NewCap);
  FIndexCap := NewCap;
end;

function TMesh.AddVertex(const APos: TVector3): Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(278);{$ENDIF}
  Result := AddVertex(MakeVertex(APos));
end;

function TMesh.AddVertex(const APos, ANormal: TVector3): Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1311);{$ENDIF}
  Result := AddVertex(MakeVertex2(APos, ANormal));
end;

function TMesh.AddVertex(const APos, ANormal: TVector3;
  const AUV: TVector2): Integer;
var
  V: TMeshVertex;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1312);{$ENDIF}
  V.Position := APos;
  V.Normal   := ANormal;
  V.UV       := AUV;
  V.OsmId    := 0;            { AddVertex stamps the mesh's CurrentOsmId }
  Result := AddVertex(V);
end;

function TMesh.AddVertex(const V: TMeshVertex): Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1313);{$ENDIF}
  if FVertexCount >= FVertexCap then
    GrowVertices;
  Result := FVertexCount;
  FVertices[FVertexCount] := V;
  { Stamp the builder's current OSM id only when the record carries none (a non-zero id means
    the vertex was copied from an already-tagged mesh and must be preserved; ids are always >= 1). }
  if FVertices[FVertexCount].OsmId = 0 then
    FVertices[FVertexCount].OsmId := FCurrentOsmId;
  Inc(FVertexCount);
end;

procedure TMesh.AddTriangle(I0, I1, I2: Integer);
var
  N: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(279);{$ENDIF}
  N := FIndexCount;
  if N + 3 > FIndexCap then
    GrowIndices;
  FIndices[N    ] := Cardinal(I0);
  FIndices[N + 1] := Cardinal(I1);
  FIndices[N + 2] := Cardinal(I2);
  Inc(FIndexCount, 3);
end;

procedure TMesh.AddQuad(I0, I1, I2, I3: Integer);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(280);{$ENDIF}
  AddTriangle(I0, I1, I2);
  AddTriangle(I0, I2, I3);
end;

procedure TMesh.SetVertexNormal(Index: Integer; const N: TVector3);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(281);{$ENDIF}
  FVertices[Index].Normal := N;
end;

procedure TMesh.SetVertexPosition(Index: Integer; const P: TVector3);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(282);{$ENDIF}
  FVertices[Index].Position := P;
end;

procedure TMesh.SetVertexUV(Index: Integer; const UV: TVector2);
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1447);{$ENDIF}
  FVertices[Index].UV := UV;
end;

procedure TMesh.AppendMesh(Other: TMesh);
var
  VOffset, IBase, I: Integer;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(283);{$ENDIF}
  if (Other = nil) or (Other.FVertexCount = 0) then Exit;

  VOffset := FVertexCount;
  ReserveVertices(FVertexCount + Other.FVertexCount);
  Move(Other.FVertices[0], FVertices[VOffset],
       Other.FVertexCount * SizeOf(TMeshVertex));
  Inc(FVertexCount, Other.FVertexCount);

  IBase := FIndexCount;
  ReserveIndices(FIndexCount + Other.FIndexCount);
  { Indices must be shifted by VOffset — cannot use Move directly. }
  for I := 0 to Other.FIndexCount - 1 do
    FIndices[IBase + I] := Other.FIndices[I] + Cardinal(VOffset);
  Inc(FIndexCount, Other.FIndexCount);
end;

{$push}{$Q-}{$R-}
{$pop}

procedure TMesh.ComputeSmoothNormals;
var
  Accum: array of TVector3;
  I, Tri: Integer;
  I0, I1, I2: Cardinal;
  Edge1, Edge2, FaceN: TVector3;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(284);{$ENDIF}
  if FVertexCount = 0 then Exit;
  SetLength(Accum, FVertexCount);

  for I := 0 to FVertexCount - 1 do
  begin
    Accum[I].X := 0;  Accum[I].Y := 0;  Accum[I].Z := 0;
  end;

  Tri := 0;
  while Tri + 3 <= FIndexCount do
  begin
    I0 := FIndices[Tri    ];
    I1 := FIndices[Tri + 1];
    I2 := FIndices[Tri + 2];

    Edge1 := FVertices[I1].Position - FVertices[I0].Position;
    Edge2 := FVertices[I2].Position - FVertices[I0].Position;
    FaceN := VecCross(Edge1, Edge2);
    { Not normalised: area-weighted accumulation. }

    Accum[I0].X := Accum[I0].X + FaceN.X;
    Accum[I0].Y := Accum[I0].Y + FaceN.Y;
    Accum[I0].Z := Accum[I0].Z + FaceN.Z;
    Accum[I1].X := Accum[I1].X + FaceN.X;
    Accum[I1].Y := Accum[I1].Y + FaceN.Y;
    Accum[I1].Z := Accum[I1].Z + FaceN.Z;
    Accum[I2].X := Accum[I2].X + FaceN.X;
    Accum[I2].Y := Accum[I2].Y + FaceN.Y;
    Accum[I2].Z := Accum[I2].Z + FaceN.Z;

    Inc(Tri, 3);
  end;

  for I := 0 to FVertexCount - 1 do
    FVertices[I].Normal := VecNormalize(Accum[I]);
end;

procedure TMesh.MakeWindingMatchNormals;
var
  Tri, Base: Integer;
  I0, I1, I2, Tmp: Cardinal;
  Edge1, Edge2, FaceN, AvgN: TVector3;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(1314);{$ENDIF}
  for Tri := 0 to FIndexCount div 3 - 1 do
  begin
    Base := Tri * 3;
    I0 := FIndices[Base];
    I1 := FIndices[Base + 1];
    I2 := FIndices[Base + 2];

    { Geometric normal from the current (CCW) winding. }
    Edge1.X := FVertices[I1].Position.X - FVertices[I0].Position.X;
    Edge1.Y := FVertices[I1].Position.Y - FVertices[I0].Position.Y;
    Edge1.Z := FVertices[I1].Position.Z - FVertices[I0].Position.Z;
    Edge2.X := FVertices[I2].Position.X - FVertices[I0].Position.X;
    Edge2.Y := FVertices[I2].Position.Y - FVertices[I0].Position.Y;
    Edge2.Z := FVertices[I2].Position.Z - FVertices[I0].Position.Z;
    FaceN := VecCross(Edge1, Edge2);

    { Outward reference = the builder-authored per-vertex normals. }
    AvgN.X := FVertices[I0].Normal.X + FVertices[I1].Normal.X + FVertices[I2].Normal.X;
    AvgN.Y := FVertices[I0].Normal.Y + FVertices[I1].Normal.Y + FVertices[I2].Normal.Y;
    AvgN.Z := FVertices[I0].Normal.Z + FVertices[I1].Normal.Z + FVertices[I2].Normal.Z;

    { If the face points opposite the intended normal, reverse winding by
      swapping the 2nd and 3rd indices (pivot I0 stays — keeps any
      flat-shading provoking-vertex stable). }
    if VecDot(FaceN, AvgN) < 0.0 then
    begin
      Tmp := FIndices[Base + 1];
      FIndices[Base + 1] := FIndices[Base + 2];
      FIndices[Base + 2] := Tmp;
    end;
  end;
end;

procedure TMesh.Clear;
begin
  {$IFDEF IAM_LIVE}IamLiveTrack(287);{$ENDIF}
  SetLength(FVertices, 0);
  SetLength(FIndices,  0);
  FVertexCount := 0;
  FIndexCount  := 0;
  FVertexCap   := 0;
  FIndexCap    := 0;
  FCurrentOsmId := 0;
end;

end.
