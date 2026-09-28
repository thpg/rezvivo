unit Osm3dGroundSurfaceQuery;
{$mode objfpc}{$H+}{$Q-}{$R-}
interface
uses CastleVectors, Osm3dGroundComposite, Generics.Collections;
type
  TSurfaceHit = record
    Position, Normal, TangentU: TVector3;
    UV: TVector2;
    MaterialId: Integer;
    Owner: Int64;
  end;
  { Generation-only compact grid: offsets and indices, no geometry copies
    or per-cell objects. Appended triangles stay absent until IncludeAppended;
    that indexes only the new range, retaining the original compact grid. }
  TGroundSurfaceQuery = class
  private
    type
      TGridLevel = record
        Cells: specialize TDictionary<Int64,Integer>;
        Offsets, Triangles: array of Integer;
        Count: Integer;
        Cell: Single;
      end;
      TGridLevels = array of TGridLevel;
  private
    FGround: TGroundCompositeMesh;
    FBatches: array of TGridLevels;
    FIndexedTriangles: Integer;
    procedure AppendIndex(const Stage: string);
    class procedure FreeLevels(var Levels: TGridLevels); static;
    function TriangleCells(T: Integer; out X0,Z0,X1,Z1: Integer): Integer;
    procedure SampleTriangle(T: Integer; X,Z: Single; Tangent: Boolean;
      var BestTriangle: Integer; var Hit: TSurfaceHit);
  public
    constructor Create(Ground:TGroundCompositeMesh);
    destructor Destroy; override;
    procedure IncludeAppended;
    function Sample(X,Z:Single; out Hit:TSurfaceHit;
      Tangent:Boolean=False):Boolean;
    function IndexBytes:Int64;
  end;
implementation
uses Math, SysUtils, Osm3dGenerationProgress;
const MAX_TRIANGLE_CELLS=64;
function CellKey(X,Z:Integer):Int64;inline;
begin Result:=Int64((QWord(LongWord(X)) shl 32)or LongWord(Z)) end;
function TGroundSurfaceQuery.TriangleCells(T:Integer;out X0,Z0,X1,Z1:Integer):Integer;
var A,B,C:TVector3; MinX,MaxX,MinZ,MaxZ,CellSize:Single;
begin
  A:=FGround.PositionOf(FGround.Indices[T*3]);
  B:=FGround.PositionOf(FGround.Indices[T*3+1]);
  C:=FGround.PositionOf(FGround.Indices[T*3+2]);
  MinX:=Min(A.X,Min(B.X,C.X));MinZ:=Min(A.Z,Min(B.Z,C.Z));
  MaxX:=Max(A.X,Max(B.X,C.X));MaxZ:=Max(A.Z,Max(B.Z,C.Z));
  Result:=0;CellSize:=4;
  repeat
    X0:=Floor(MinX/CellSize);Z0:=Floor(MinZ/CellSize);
    X1:=Floor(MaxX/CellSize);Z1:=Floor(MaxZ/CellSize);
    if Int64(X1-X0+1)*(Z1-Z0+1)<=MAX_TRIANGLE_CELLS then Break;
    Inc(Result);CellSize:=CellSize*2;
  until False;
end;
constructor TGroundSurfaceQuery.Create(Ground:TGroundCompositeMesh);
begin
  inherited Create;FGround:=Ground;
  AppendIndex('Surface index');
end;
class procedure TGroundSurfaceQuery.FreeLevels(var Levels:TGridLevels);
var L:Integer;
begin
  for L:=0 to High(Levels) do Levels[L].Cells.Free;
  Levels:=nil;
end;
procedure TGroundSurfaceQuery.IncludeAppended;
begin
  AppendIndex('Surface additions');
end;
procedure TGroundSurfaceQuery.AppendIndex(const Stage:string);
var I,X,Z,X0,X1,Z0,Z1,C,First,Count,L,J:Integer; Total,WorkTotal:Int64;
  Cursor:array of array of Integer; Key:Int64; Levels:TGridLevels;
begin
  if FGround=nil then Exit;
  First:=FIndexedTriangles;Count:=FGround.TriangleCount-First;
  if Count<0 then raise EInvalidOp.Create('Surface query requires append-only geometry');
  if Count=0 then Exit;
  CheckGenerationCancelled;
  WorkTotal:=Int64(Count)*2;
  GenerationProgress(Stage,0,WorkTotal);
  Levels:=nil;
  try
  { Sparse cells keep the fine 4 m resolution even when a block contains
    distant geometry. Large triangles alone use coarser levels; no global
    list, geometry copies, or one TList object per cell. }
  for I:=First to First+Count-1 do begin
    L:=TriangleCells(I,X0,Z0,X1,Z1);
    if L>=Length(Levels) then begin
      J:=Length(Levels);SetLength(Levels,L+1);
      while J<=L do begin Levels[J].Cell:=4*IntPower(2,J);Inc(J) end;
    end;
    if Levels[L].Cells=nil then Levels[L].Cells:=specialize TDictionary<Int64,Integer>.Create;
    for Z:=Z0 to Z1 do for X:=X0 to X1 do begin
      Key:=CellKey(X,Z);
      if not Levels[L].Cells.TryGetValue(Key,C) then begin
        C:=Levels[L].Count;Inc(Levels[L].Count);
        Levels[L].Cells.Add(Key,C);
        if C+1>=Length(Levels[L].Offsets) then
          SetLength(Levels[L].Offsets,Max(64,Length(Levels[L].Offsets)*2));
      end;
      Inc(Levels[L].Offsets[C+1]);
    end;
    if ((I-First) and 8191)=0 then begin
      CheckGenerationCancelled;GenerationProgress(Stage,I-First,WorkTotal);
    end;
  end;
  SetLength(Cursor,Length(Levels));
  for L:=0 to High(Levels) do begin
    if Levels[L].Cells=nil then Continue;
    SetLength(Levels[L].Offsets,Levels[L].Count+1);
    Total:=0;
    for I:=1 to High(Levels[L].Offsets) do begin
      Inc(Total,Levels[L].Offsets[I]);
      if Total>High(Integer) then raise ERangeError.Create('Surface index exceeds integer range');
      Levels[L].Offsets[I]:=Total;
    end;
    SetLength(Levels[L].Triangles,Total);
    Cursor[L]:=Copy(Levels[L].Offsets,0,Length(Levels[L].Offsets)-1);
  end;
  for I:=First to First+Count-1 do begin
    L:=TriangleCells(I,X0,Z0,X1,Z1);
    for Z:=Z0 to Z1 do for X:=X0 to X1 do begin
      C:=Levels[L].Cells[CellKey(X,Z)];
      Levels[L].Triangles[Cursor[L][C]]:=I;Inc(Cursor[L][C]);
    end;
    if ((I-First) and 8191)=0 then begin
      CheckGenerationCancelled;GenerationProgress(Stage,Int64(Count)+I-First,WorkTotal);
    end;
  end;
  CheckGenerationCancelled;
  GenerationProgress(Stage,WorkTotal,WorkTotal);
  SetLength(FBatches,Length(FBatches)+1);
  FBatches[High(FBatches)]:=Levels;Levels:=nil;
  FIndexedTriangles:=First+Count;
  finally FreeLevels(Levels) end;
end;
destructor TGroundSurfaceQuery.Destroy;
var B:Integer;
begin
  for B:=0 to High(FBatches) do FreeLevels(FBatches[B]);
  inherited;
end;
function TGroundSurfaceQuery.IndexBytes:Int64;
var B,L:Integer;
begin
  Result:=0;
  for B:=0 to High(FBatches) do for L:=0 to High(FBatches[B]) do
    Inc(Result,(Int64(Length(FBatches[B][L].Offsets))+Length(FBatches[B][L].Triangles))*4
      +Int64(FBatches[B][L].Count)*40); { includes estimated dictionary slots }
end;
procedure TGroundSurfaceQuery.SampleTriangle(T:Integer;X,Z:Single;
  Tangent:Boolean;var BestTriangle:Integer;var Hit:TSurfaceHit);
var I0,I1,I2:Integer;A,B,C:TVector3;D,U,V,W,Y:Single;UA,UB,UC:TVector2;
begin
  I0:=FGround.Indices[T*3];I1:=FGround.Indices[T*3+1];I2:=FGround.Indices[T*3+2];
  A:=FGround.PositionOf(I0);B:=FGround.PositionOf(I1);C:=FGround.PositionOf(I2);
  D:=(B.Z-C.Z)*(A.X-C.X)+(C.X-B.X)*(A.Z-C.Z);
  if Abs(D)<1e-8 then Exit;
  U:=((B.Z-C.Z)*(X-C.X)+(C.X-B.X)*(Z-C.Z))/D;
  V:=((C.Z-A.Z)*(X-C.X)+(A.X-C.X)*(Z-C.Z))/D;W:=1-U-V;
  if Min(U,Min(V,W))< -0.00001 then Exit;
  Y:=A.Y*U+B.Y*V+C.Y*W;
  if (Y<Hit.Position.Y)or((Y=Hit.Position.Y)and(T<BestTriangle)) then Exit;
  Hit.Position.Y:=Y;Hit.MaterialId:=FGround.MatIdOf(I0);Hit.Owner:=FGround.OsmIdOf(I0);
  UA:=FGround.UVOf(I0);UB:=FGround.UVOf(I1);UC:=FGround.UVOf(I2);
  Hit.UV:=UA*U+UB*V+UC*W;
  Hit.Normal:=TVector3.CrossProduct(B-A,C-A).Normalize;
  if Hit.Normal.Y<0 then Hit.Normal:=-Hit.Normal;
  if Tangent then begin
    Hit.TangentU:=Vector3(0,0,0);UB:=UB-UA;UC:=UC-UA;D:=UB.X*UC.Y-UB.Y*UC.X;
    if Abs(D)>1e-8 then Hit.TangentU:=((B-A)*UC.Y-(C-A)*UB.Y)*(1/D);
  end;
  BestTriangle:=T;
end;
function TGroundSurfaceQuery.Sample(X,Z:Single;out Hit:TSurfaceHit;Tangent:Boolean):Boolean;
var CX,CZ,C,I,B,L,BestTriangle:Integer;
begin
  Result:=False;Hit:=Default(TSurfaceHit);Hit.Position:=Vector3(X,-1e20,Z);
  BestTriangle:=-1;
  for B:=0 to High(FBatches) do for L:=0 to High(FBatches[B]) do begin
    if Length(FBatches[B][L].Triangles)=0 then Continue;
    CX:=Floor(X/FBatches[B][L].Cell);CZ:=Floor(Z/FBatches[B][L].Cell);
    if not FBatches[B][L].Cells.TryGetValue(CellKey(CX,CZ),C) then Continue;
    for I:=FBatches[B][L].Offsets[C] to FBatches[B][L].Offsets[C+1]-1 do
      SampleTriangle(FBatches[B][L].Triangles[I],X,Z,Tangent,BestTriangle,Hit);
  end;
  { Equal-height ties use the original triangle index, independent of level. }
  Result:=BestTriangle>=0;
end;
end.
