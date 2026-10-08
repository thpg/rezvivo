unit Osm3dPolygonClipXZ;
{$mode objfpc}{$H+}
{ Shared convex half-plane clipping used by roofs and ground openings.
  Coordinates are (X,Z). Callers triangulate non-convex subjects first. }
interface
uses SysUtils, Math, CastleVectors;
const POLYGON_CLIP_EPS = 0.00001;
type
  TXZClipPolygon = array of TVector2;
  TXZClipPolygons = array of TXZClipPolygon;
function XZCross(const A,B:TVector2):Double; inline;
function XZPolygonArea(const P:TXZClipPolygon):Double;
procedure XZAppendPolygon(var A:TXZClipPolygons;const P:TXZClipPolygon;
  MaxPieces:Integer=8192);
function XZClipHalfPlane(const P:TXZClipPolygon;X,Z,C:Double):TXZClipPolygon;
function XZOverlapBounds(const A,B:TXZClipPolygon):Boolean;
{ Cutter must be convex, counterclockwise. Output pieces never overlap. }
procedure XZSubtractConvex(const P,Cutter:TXZClipPolygon;
  var OutPolys:TXZClipPolygons;MaxPieces:Integer=8192);
implementation
function XZCross(const A,B:TVector2):Double;
begin Result:=A.X*B.Y-A.Y*B.X end;
function XZPolygonArea(const P:TXZClipPolygon):Double;
var I:Integer;
begin Result:=0;for I:=0 to High(P) do Result:=Result+XZCross(P[I],P[(I+1) mod Length(P)]);Result:=Result*0.5 end;
procedure XZAppendPolygon(var A:TXZClipPolygons;const P:TXZClipPolygon;
  MaxPieces:Integer);
var N:Integer;
begin
  if (Length(P)<3) or (Abs(XZPolygonArea(P))<POLYGON_CLIP_EPS) then Exit;
  N:=Length(A);if N>=MaxPieces then raise EConvertError.Create('polygon clipping budget exceeded');
  SetLength(A,N+1);A[N]:=P;
end;
function XZClipHalfPlane(const P:TXZClipPolygon;X,Z,C:Double):TXZClipPolygon;
var I,N:Integer;A,B,V:TVector2;DA,DB,T:Double;
  procedure Add(const V:TVector2);
  begin
    if (N>0) and ((Result[N-1]-V).Length<POLYGON_CLIP_EPS) then Exit;
    Result[N]:=V;Inc(N);
  end;
begin
  Result:=nil;if Length(P)<3 then Exit;SetLength(Result,Length(P)+2);N:=0;
  A:=P[High(P)];DA:=X*A.X+Z*A.Y+C;
  for I:=0 to High(P) do begin
    B:=P[I];DB:=X*B.X+Z*B.Y+C;
    if (DA>=0)<>(DB>=0) then begin T:=DA/(DA-DB);V:=A+(B-A)*T;Add(V) end;
    if DB>=0 then Add(B);A:=B;DA:=DB;
  end;
  if (N>1) and ((Result[0]-Result[N-1]).Length<POLYGON_CLIP_EPS) then Dec(N);
  SetLength(Result,N);
end;
function XZOverlapBounds(const A,B:TXZClipPolygon):Boolean;
var I:Integer;AMin,AMax,BMin,BMax:TVector2;
begin
  if (Length(A)<3) or (Length(B)<3) then Exit(False);
  AMin:=A[0];AMax:=A[0];BMin:=B[0];BMax:=B[0];
  for I:=1 to High(A) do begin AMin.X:=Min(AMin.X,A[I].X);AMin.Y:=Min(AMin.Y,A[I].Y);AMax.X:=Max(AMax.X,A[I].X);AMax.Y:=Max(AMax.Y,A[I].Y) end;
  for I:=1 to High(B) do begin BMin.X:=Min(BMin.X,B[I].X);BMin.Y:=Min(BMin.Y,B[I].Y);BMax.X:=Max(BMax.X,B[I].X);BMax.Y:=Max(BMax.Y,B[I].Y) end;
  Result:=(AMax.X>BMin.X+POLYGON_CLIP_EPS) and (BMax.X>AMin.X+POLYGON_CLIP_EPS) and
    (AMax.Y>BMin.Y+POLYGON_CLIP_EPS) and (BMax.Y>AMin.Y+POLYGON_CLIP_EPS);
end;
procedure XZSubtractConvex(const P,Cutter:TXZClipPolygon;
  var OutPolys:TXZClipPolygons;MaxPieces:Integer);
var I:Integer;Inside,Outside:TXZClipPolygon;D:TVector2;X,Z,C:Double;
begin
  if not XZOverlapBounds(P,Cutter) then begin XZAppendPolygon(OutPolys,P,MaxPieces);Exit end;
  Inside:=P;
  for I:=0 to High(Cutter) do begin
    D:=Cutter[(I+1) mod Length(Cutter)]-Cutter[I];X:=-D.Y;Z:=D.X;C:=D.Y*Cutter[I].X-D.X*Cutter[I].Y;
    Outside:=XZClipHalfPlane(Inside,-X,-Z,-C);XZAppendPolygon(OutPolys,Outside,MaxPieces);
    Inside:=XZClipHalfPlane(Inside,X,Z,C);if Length(Inside)<3 then Exit;
  end;
end;
end.
