unit BikeMeshDetail;

{$mode objfpc}{$H+}

interface

uses CastleVectors, BikeParametric;

{ Build-time geometry only. Both helpers emit into the caller's material batch. }
procedure BikeDetailTube(Ctx: TBikeBuildContext;
  const Points: array of TVector3; const Radii: array of TVector2;
  const SideAxis, Color, Spec: TVector3; Shine: Single; Slices: Integer = 0);
procedure BikeDetailBox(Ctx: TBikeBuildContext;
  const Center, AxisX, AxisY, AxisZ, Size, Color, Spec: TVector3;
  Shine: Single; Taper: Single = 1);
function BikeBezier(const A, B, C, D: TVector3; T: Single): TVector3;

implementation

uses Math, X3DNodes;

procedure BikeDetailTube(Ctx: TBikeBuildContext;
  const Points: array of TVector3; const Radii: array of TVector2;
  const SideAxis, Color, Spec: TVector3; Shine: Single; Slices: Integer);
var Coord: TCoordinateNode; Mesh: TIndexedFaceSetNode;
  I, J, NextJ, B, E: Integer; T, U, V: TVector3; R: TVector2; A: Single;
  procedure Index(N: Integer);
  begin Mesh.FdCoordIndex.Items.Add(N) end;
begin
  if (Length(Points)<2) or (Length(Radii)=0) then Exit;
  if Slices=0 then Slices:=Min(12,Ctx.LOD_CylSlices);
  Slices:=Max(4,Slices);
  Coord:=TCoordinateNode.Create; Mesh:=TIndexedFaceSetNode.Create;
  Mesh.Coord:=Coord; Mesh.Solid:=True; Mesh.CreaseAngle:=1.1;
  for I:=0 to High(Points) do begin
    if I=0 then T:=Points[1]-Points[0]
    else if I=High(Points) then T:=Points[I]-Points[I-1]
    else T:=Points[I+1]-Points[I-1];
    if T.LengthSqr<1e-12 then T:=Vector3(0,1,0) else T:=T.Normalize;
    U:=SideAxis-T*TVector3.DotProduct(SideAxis,T);
    if U.LengthSqr<0.001 then begin
      U:=Vector3(0,1,0); if Abs(T.Y)>0.9 then U:=Vector3(1,0,0);
      U:=U-T*TVector3.DotProduct(U,T);
    end;
    U:=U.Normalize; V:=TVector3.CrossProduct(T,U);
    R:=Radii[Min(I,High(Radii))];
    for J:=0 to Slices-1 do begin
      A:=2*Pi*J/Slices;
      Coord.FdPoint.Items.Add(Points[I]+U*(Cos(A)*R.X)+V*(Sin(A)*R.Y));
    end;
  end;
  for I:=0 to High(Points)-1 do
    for J:=0 to Slices-1 do begin
      NextJ:=(J+1) mod Slices; B:=I*Slices; E:=(I+1)*Slices;
      Index(B+J);Index(B+NextJ);Index(E+NextJ);Index(E+J);Index(-1);
    end;
  B:=Coord.FdPoint.Items.Count;Coord.FdPoint.Items.Add(Points[0]);
  E:=Coord.FdPoint.Items.Count;Coord.FdPoint.Items.Add(Points[High(Points)]);
  for J:=0 to Slices-1 do begin
    NextJ:=(J+1) mod Slices;
    Index(B);Index(NextJ);Index(J);Index(-1);
    Index(E);Index(High(Points)*Slices+J);Index(High(Points)*Slices+NextJ);Index(-1);
  end;
  Ctx.EmitBatched(Mesh,Coord,Color,Spec,Shine,1.1,TMatrix4.Identity);
end;

procedure BikeDetailBox(Ctx: TBikeBuildContext;
  const Center, AxisX, AxisY, AxisZ, Size, Color, Spec: TVector3;
  Shine: Single; Taper: Single);
const X: array[0..3]of Single=(-1,1,1,-1);
      Y: array[0..3]of Single=(-1,-1,1,1);
var Coord:TCoordinateNode;Mesh:TIndexedFaceSetNode;I,J,K:Integer;Scale:Single;
  procedure Face(A,B,C,D:Integer);
  begin
    Mesh.FdCoordIndex.Items.Add(A);Mesh.FdCoordIndex.Items.Add(B);
    Mesh.FdCoordIndex.Items.Add(C);Mesh.FdCoordIndex.Items.Add(D);
    Mesh.FdCoordIndex.Items.Add(-1);
  end;
begin
  Coord:=TCoordinateNode.Create;Mesh:=TIndexedFaceSetNode.Create;
  Mesh.Coord:=Coord;Mesh.Solid:=True;Mesh.CreaseAngle:=0.35;
  for K:=0 to 1 do begin
    if K=0 then Scale:=1 else Scale:=Taper;
    for I:=0 to 3 do Coord.FdPoint.Items.Add(Center+
      AxisX*(X[I]*Size.X*Scale*0.5)+AxisY*(Y[I]*Size.Y*Scale*0.5)+
      AxisZ*((2*K-1)*Size.Z*0.5));
  end;
  Face(3,2,1,0);Face(4,5,6,7);
  for I:=0 to 3 do begin J:=(I+1)mod 4;Face(I,J,J+4,I+4) end;
  Ctx.EmitBatched(Mesh,Coord,Color,Spec,Shine,0.35,TMatrix4.Identity);
end;

function BikeBezier(const A, B, C, D: TVector3; T: Single): TVector3;
var U:Single;
begin
  U:=1-T;
  Result:=A*(U*U*U)+B*(3*U*U*T)+C*(3*U*T*T)+D*(T*T*T);
end;

end.
