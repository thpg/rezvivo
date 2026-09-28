unit Osm3dSoundscape;
{$mode objfpc}{$H+}
interface
uses CastleVectors,Osm3dTileX3D;
type
  TEnvironmentSound=(esCity,esForest,esSea,esHighway,esWind);
  TEnvironmentMix=array[TEnvironmentSound]of Single;
  { A small, transient grid built from baked tiles. No OSM parsing, HTTP,
    geometry retention or ray queries are needed during playback. }
  TSoundscapeField=class
  private
    FMinX,FMinZ,FStep:Single;
    FNX,FNZ:Integer;
    FCells:array of record City,Forest,Sea,Highway,Land:Byte;SeaY:Single;end;
    procedure Deposit(X,Z:Single;Kind:TEnvironmentSound;Amount:Integer;Y:Single=0);
    procedure Triangle(const A,B,C:TVector3;Kind:TEnvironmentSound);
  public
    constructor Create(Model:TTileModel;ScaleX:Single;Civilization,Marine:Boolean);
    function Sample(X,Y,Z:Single):TEnvironmentMix;
  end;
procedure MergeEnvironment(var Dest:TEnvironmentMix;const Source:TEnvironmentMix);
implementation
uses Math,Osm3dGeomMesh,Osm3dSceneMaterials,Osm3dGroundComposite;

procedure MergeEnvironment(var Dest:TEnvironmentMix;const Source:TEnvironmentMix);
var K:TEnvironmentSound;
begin for K:=Low(K)to High(K)do Dest[K]:=Max(Dest[K],Source[K]);end;

procedure TSoundscapeField.Deposit(X,Z:Single;Kind:TEnvironmentSound;Amount:Integer;Y:Single);
var CX,CZ,I:Integer;
begin
  CX:=Floor((X-FMinX)/FStep);CZ:=Floor((Z-FMinZ)/FStep);
  if(CX<0)or(CX>=FNX)or(CZ<0)or(CZ>=FNZ)then Exit;
  I:=CZ*FNX+CX;
  case Kind of
    esCity:FCells[I].City:=Max(FCells[I].City,Amount);
    esForest:FCells[I].Forest:=Min(255,FCells[I].Forest+Amount);
    esSea:begin FCells[I].Sea:=255;FCells[I].SeaY:=Y;end;
    esHighway:FCells[I].Highway:=255;
    esWind:FCells[I].Land:=1;
  end;
end;

procedure TSoundscapeField.Triangle(const A,B,C:TVector3;Kind:TEnvironmentSound);
var X0,X1,Z0,Z1,X,Z:Integer;PX,PZ,D,U,V:Single;
begin
  D:=(B.Z-C.Z)*(A.X-C.X)+(C.X-B.X)*(A.Z-C.Z);
  if Abs(D)<0.01 then Exit;
  X0:=Max(0,Floor((Min(A.X,Min(B.X,C.X))-FMinX)/FStep));
  X1:=Min(FNX-1,Floor((Max(A.X,Max(B.X,C.X))-FMinX)/FStep));
  Z0:=Max(0,Floor((Min(A.Z,Min(B.Z,C.Z))-FMinZ)/FStep));
  Z1:=Min(FNZ-1,Floor((Max(A.Z,Max(B.Z,C.Z))-FMinZ)/FStep));
  Deposit((A.X+B.X+C.X)/3,(A.Z+B.Z+C.Z)/3,Kind,255,(A.Y+B.Y+C.Y)/3);
  for Z:=Z0 to Z1 do for X:=X0 to X1 do begin
    PX:=FMinX+(X+0.5)*FStep;PZ:=FMinZ+(Z+0.5)*FStep;
    U:=((B.Z-C.Z)*(PX-C.X)+(C.X-B.X)*(PZ-C.Z))/D;
    V:=((C.Z-A.Z)*(PX-C.X)+(A.X-C.X)*(PZ-C.Z))/D;
    if(U>=0)and(V>=0)and(U+V<=1)then Deposit(PX,PZ,Kind,255,U*A.Y+V*B.Y+(1-U-V)*C.Y);
  end;
end;

constructor TSoundscapeField.Create(Model:TTileModel;ScaleX:Single;Civilization,Marine:Boolean);
var I,J,M,Mat:Integer;R:TTileMeshRec;V:TMeshVertexArray;Idx:TMeshIndexArray;
    P,A,B,C:TVector3;MaxX,MaxZ:Single;K:TEnvironmentSound;Valid:Boolean;Tree:TTileTreeRec;
begin
  inherited Create;
  FMinX:=1e30;FMinZ:=1e30;MaxX:=-1e30;MaxZ:=-1e30;
  { Do not size a Dream island grid to its enormous surrounding sea quad. }
  for I:=0 to Model.MeshCount-1 do begin
    R:=Model.Meshes[I];if(R.Mesh=nil)or(R.Material=smkWater)then Continue;
    V:=R.Mesh.Vertices;
    for J:=0 to High(V)do begin
      P:=V[J].Position;P.X:=P.X*ScaleX;
      FMinX:=Min(FMinX,P.X);FMinZ:=Min(FMinZ,P.Z);MaxX:=Max(MaxX,P.X);MaxZ:=Max(MaxZ,P.Z);
    end;
  end;
  if MaxX<FMinX then begin FMinX:=-256;FMinZ:=-256;MaxX:=256;MaxZ:=256;end;
  FMinX:=FMinX-96;FMinZ:=FMinZ-96;MaxX:=MaxX+96;MaxZ:=MaxZ+96;
  FStep:=Max(32,Max(MaxX-FMinX,MaxZ-FMinZ)/128);
  FNX:=Min(129,Ceil((MaxX-FMinX)/FStep));FNZ:=Min(129,Ceil((MaxZ-FMinZ)/FStep));
  SetLength(FCells,FNX*FNZ);
  for I:=0 to Model.TreeCount-1 do begin
    Tree:=Model.Trees[I];if not Tree.IsShrub then Deposit(Tree.X*ScaleX,Tree.Z,esForest,32);
  end;
  for I:=0 to Model.MeshCount-1 do begin
    R:=Model.Meshes[I];if R.Mesh=nil then Continue;
    V:=R.Mesh.Vertices;Idx:=R.Mesh.Indices;
    for J:=0 to Length(Idx)div 3-1 do begin
      M:=Idx[J*3];Mat:=-1;if M<Length(R.MatIds)then Mat:=R.MatIds[M];
      Valid:=True;
      if(Mat=GROUND_MAT_FOREST_FLOOR)or(R.Material=smkForest)then K:=esForest
      else if((Mat=GROUND_MAT_WATER)or(R.Material=smkWater))and
        (Marine or((M<Length(R.WaterScale))and(R.WaterScale[M]=-1)))then K:=esSea
      else if Civilization and((Mat in[GROUND_MAT_ROAD_MAJOR,GROUND_MAT_ROAD_SECOND])or
        (R.Material in[smkRoadMajor,smkRoadSecondary]))then K:=esHighway
      else if Civilization and(R.Material in[smkBuildingWall0..smkBuildingRoof])then K:=esCity
      else if Marine and(R.Material in[smkTerrain,smkGrass])then K:=esWind
      else begin Valid:=False;K:=esWind;end;
      if not Valid then Continue;
      A:=V[M].Position;B:=V[Idx[J*3+1]].Position;C:=V[Idx[J*3+2]].Position;
      A.X:=A.X*ScaleX;B.X:=B.X*ScaleX;C.X:=C.X*ScaleX;
      Triangle(A,B,C,K);
    end;
  end;
  { Dream ocean quads extend underneath the island. Only their uncovered
    cells emit surf; otherwise the middle of a large island sounds coastal. }
  if Marine then for I:=0 to High(FCells)do
    if FCells[I].Land<>0 then FCells[I].Sea:=0;
end;

function TSoundscapeField.Sample(X,Y,Z:Single):TEnvironmentMix;
var CX,CZ,I,J,N,Radius:Integer;D,W,F:Single;
begin
  Result:=Default(TEnvironmentMix);
  CX:=Floor((X-FMinX)/FStep);CZ:=Floor((Z-FMinZ)/FStep);Radius:=Ceil(100/FStep);
  for J:=Max(0,CZ-Radius)to Min(FNZ-1,CZ+Radius)do
    for I:=Max(0,CX-Radius)to Min(FNX-1,CX+Radius)do begin
      D:=Sqrt(Sqr(FMinX+(I+0.5)*FStep-X)+Sqr(FMinZ+(J+0.5)*FStep-Z));
      W:=EnsureRange(1-Max(0,D-FStep*0.6)/85,0.0,1.0);if W<=0 then Continue;
      N:=J*FNX+I;
      Result[esForest]:=Max(Result[esForest],FCells[N].Forest/255*W);
      Result[esCity]:=Max(Result[esCity],FCells[N].City/255*W);
      Result[esHighway]:=Max(Result[esHighway],FCells[N].Highway/255*W);
      F:=EnsureRange(1-Abs(Y-FCells[N].SeaY)/110,0.0,1.0);
      Result[esSea]:=Max(Result[esSea],FCells[N].Sea/255*W*F);
    end;
end;
end.
