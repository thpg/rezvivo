unit Osm3dTravelRoads;
{$mode objfpc}{$H+}
interface
uses Math, CastleVectors, Osm3dTileX3D;
type
  TTravelRoad = record
    A,B:TVector3;
    Width:Single;
    WayId:Int64;
    Bridge:Boolean;
  end;
  TTravelRoads=array of TTravelRoad;
  { Small, immutable road layer retained when the render source model is freed.
    Spatial bins are built once per tile; steering never reads files or OSM. }
  TTravelRoadIndex=class
  private
    FRoads:TTravelRoads;
    FBins:array of array of Integer;
    FSeen:array of Cardinal;
    FStamp:Cardinal;
    FX,FZ,FCell:Single;
    FNX,FNZ:Integer;
  public
    constructor Create(Model:TTileModel;CenterX,CenterZ,ScaleX:Single);
    procedure Nearby(X,Z,Radius:Single;var Roads:TTravelRoads;var Count:Integer);
  end;
function RoadProjection(const P:TVector3;const R:TTravelRoad;out T:Single):TVector3;
function RoadDistanceSq(const A,B:TVector3):Single;
implementation
function RoadDistanceSq(const A,B:TVector3):Single;
begin Result:=Sqr(A.X-B.X)+Sqr(A.Z-B.Z) end;
function RoadProjection(const P:TVector3;const R:TTravelRoad;out T:Single):TVector3;
var D:TVector3;L:Single;
begin
  D:=R.B-R.A;L:=Sqr(D.X)+Sqr(D.Z);
  if L<1e-8 then T:=0 else T:=EnsureRange(((P.X-R.A.X)*D.X+(P.Z-R.A.Z)*D.Z)/L,0,1);
  Result:=R.A+D*T;
end;
constructor TTravelRoadIndex.Create(Model:TTileModel;CenterX,CenterZ,ScaleX:Single);
var I,J,X,Z,X0,X1,Z0,Z1,N,Pass:Integer;R:TTileRoadSeg;MaxX,MaxZ:Single;
  Counts:array of Integer;
begin
  inherited Create;
  if (Model=nil)or(Model.RoadSegCount=0)then Exit;
  SetLength(FRoads,Model.RoadSegCount);N:=0;FX:=1e30;FZ:=1e30;MaxX:=-1e30;MaxZ:=-1e30;
  for I:=0 to Model.RoadSegCount-1 do begin
    R:=Model.RoadSegs[I];if (R.Width<=0)or(Sqr(R.X1-R.X0)+Sqr(R.Z1-R.Z0)<0.01)then Continue;
    FRoads[N].A:=Vector3(CenterX+R.X0*ScaleX,0,CenterZ+R.Z0);
    FRoads[N].B:=Vector3(CenterX+R.X1*ScaleX,0,CenterZ+R.Z1);
    FRoads[N].Width:=R.Width;FRoads[N].WayId:=R.WayId;FRoads[N].Bridge:=R.IsBridge;
    FX:=Min(FX,Min(FRoads[N].A.X,FRoads[N].B.X));FZ:=Min(FZ,Min(FRoads[N].A.Z,FRoads[N].B.Z));
    MaxX:=Max(MaxX,Max(FRoads[N].A.X,FRoads[N].B.X));MaxZ:=Max(MaxZ,Max(FRoads[N].A.Z,FRoads[N].B.Z));Inc(N);
  end;
  SetLength(FRoads,N);SetLength(FSeen,N);if N=0 then Exit;
  FCell:=Max(32,Max(MaxX-FX,MaxZ-FZ)/96);
  FNX:=Floor((MaxX-FX)/FCell)+1;FNZ:=Floor((MaxZ-FZ)/FCell)+1;
  SetLength(FBins,FNX*FNZ);SetLength(Counts,Length(FBins));
  for Pass:=0 to 1 do begin
    for I:=0 to N-1 do begin
      X0:=Floor((Min(FRoads[I].A.X,FRoads[I].B.X)-FX)/FCell);
      X1:=Floor((Max(FRoads[I].A.X,FRoads[I].B.X)-FX)/FCell);
      Z0:=Floor((Min(FRoads[I].A.Z,FRoads[I].B.Z)-FZ)/FCell);
      Z1:=Floor((Max(FRoads[I].A.Z,FRoads[I].B.Z)-FZ)/FCell);
      for Z:=Z0 to Z1 do for X:=X0 to X1 do begin
        J:=Z*FNX+X;if Pass=1 then FBins[J][Counts[J]]:=I;Inc(Counts[J]);
      end;
    end;
    if Pass=0 then for J:=0 to High(FBins)do begin SetLength(FBins[J],Counts[J]);Counts[J]:=0 end;
  end;
end;
procedure TTravelRoadIndex.Nearby(X,Z,Radius:Single;var Roads:TTravelRoads;var Count:Integer);
var IX,IZ,X0,X1,Z0,Z1,I,K:Integer;P,Q:TVector3;T:Single;
begin
  if (FNX=0)or(FNZ=0)or(Radius<=0)then Exit;
  X0:=Floor((X-Radius-FX)/FCell);X1:=Floor((X+Radius-FX)/FCell);
  Z0:=Floor((Z-Radius-FZ)/FCell);Z1:=Floor((Z+Radius-FZ)/FCell);
  if(X1<0)or(Z1<0)or(X0>=FNX)or(Z0>=FNZ)then Exit;
  X0:=Max(0,X0);Z0:=Max(0,Z0);X1:=Min(FNX-1,X1);Z1:=Min(FNZ-1,Z1);
  if FStamp=High(Cardinal)then begin FillChar(FSeen[0],Length(FSeen)*SizeOf(Cardinal),0);FStamp:=0 end;
  Inc(FStamp);P:=Vector3(X,0,Z);
  for IZ:=Z0 to Z1 do for IX:=X0 to X1 do
    for K:=0 to High(FBins[IZ*FNX+IX])do begin
      I:=FBins[IZ*FNX+IX][K];if FSeen[I]=FStamp then Continue;FSeen[I]:=FStamp;
      Q:=RoadProjection(P,FRoads[I],T);if RoadDistanceSq(P,Q)>Sqr(Radius)then Continue;
      if Count=Length(Roads)then SetLength(Roads,Max(64,Count*2));
      Roads[Count]:=FRoads[I];Inc(Count);
    end;
end;
end.
