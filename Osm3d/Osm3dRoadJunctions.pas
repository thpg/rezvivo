unit Osm3dRoadJunctions;

{$mode objfpc}{$H+}{$Q-}{$R-}

{ Geometry only. A junction is one footprint in the ground carve, not
  overlapping ribbons. Inputs are outward arms at one shared OSM node. }
interface
uses CastleVectors, Osm3dGeoMath;

type
  TJunctionArm = record
    Direction: TVector2;
    HalfWidth, Available: Single;
    MinCut: Single; { coverage of narrower branches crossing this pavement }
  end;
  TJunctionArms = array of TJunctionArm;
  TJunctionOutline = array of TScatterPoint;

{ Arms must be sorted counter-clockwise. The returned polygon is star-shaped
  about Center. Short arms constrain both shoulders, preventing a patch from
  reaching past the available straight run. No terrain heights are changed here. }
function RoundedJunction(const Center:TVector2; const Arms:TJunctionArms;
  RoundCorners:Boolean):TJunctionOutline;

implementation
uses Math;

function Cross(const A,B:TVector2):Single; inline;
begin Result:=A.X*B.Y-A.Y*B.X end;

function RoundedJunction(const Center:TVector2; const Arms:TJunctionArms;
  RoundCorners:Boolean):TJunctionOutline;
type TCorner=record P,A,B:TVector2; Rounded:Boolean end;
var Corners:array of TCorner; Cuts:array of Single;
  I,J,K,N,Count,Steps:Integer; D,E,P,Q,Delta,V:TVector2;
  Det,T,S,R,L0,L1,U,Angle:Single;
  procedure Push(const V:TVector2);
  var Q:TVector2;
  begin
    { Use the same 1/64 m contour as the ground carve. Two evaluations of
      a tangent point can differ by a float ULP; keeping both would create
      a backwards sliver in the source UV fan. }
    Q:=Vector2(Round(V.X*64.0)/64.0,Round(V.Y*64.0)/64.0);
    if (Count>0) and (Result[Count-1].X=Q.X) and (Result[Count-1].Z=Q.Y) then Exit;
    if Count=Length(Result) then SetLength(Result,Max(32,Count*2));
    Result[Count].X:=Q.X;Result[Count].Z:=Q.Y;Inc(Count);
  end;
begin
  Result:=nil;N:=Length(Arms);if N<2 then Exit;
  SetLength(Corners,N);SetLength(Cuts,N);Count:=0;
  for I:=0 to N-1 do Cuts[I]:=Min(Arms[I].Available*0.9,Max(Arms[I].MinCut,Max(1.0,Arms[I].HalfWidth)));
  for I:=0 to N-1 do begin
    J:=(I+1) mod N;D:=Arms[I].Direction;E:=Arms[J].Direction;
    P:=Center+Vector2(-D.Y,D.X)*Arms[I].HalfWidth;
    Q:=Center-Vector2(-E.Y,E.X)*Arms[J].HalfWidth;
    Det:=Cross(D,E);
    { The concave corner exists only in a gap below 180 degrees. A larger
      gap is the outside of a bend, already covered by the road ribbon. }
    if Det<=0.035 then Continue;
    Delta:=Q-P;T:=Cross(Delta,E)/Det;S:=Cross(Delta,D)/Det;
    if (T<0) or (S<0) then Continue;
    L0:=Arms[I].Available*0.9;L1:=Arms[J].Available*0.9;
    if (T>L0) or (S>L1) then Continue;
    R:=0;
    if RoundCorners then begin
      { R is a desired shoulder radius, not a distance along the arm.
        Acute Y junctions need longer tangents; otherwise their curvature
        collapses to a few centimetres despite a sensible metre-scale radius. }
      Angle:=ArcCos(EnsureRange(D.X*E.X+D.Y*E.Y,-1,1));
      R:=Min(4.0,Max(0.60,Min(Arms[I].HalfWidth,Arms[J].HalfWidth)*0.8));
      R:=R/Max(0.02,Tan(Angle*0.5));
    end;
    R:=Min(R,Min(L0-T,L1-S));
    Corners[I].P:=P+D*T;Corners[I].A:=Corners[I].P+D*R;
    Corners[I].B:=Corners[I].P+E*R;Corners[I].Rounded:=True;
    Cuts[I]:=Max(Cuts[I],T+R);Cuts[J]:=Max(Cuts[J],S+R);
  end;
  for I:=0 to N-1 do begin
    D:=Arms[I].Direction;
    Push(Center+D*Cuts[I]-Vector2(-D.Y,D.X)*Arms[I].HalfWidth);
    Push(Center+D*Cuts[I]+Vector2(-D.Y,D.X)*Arms[I].HalfWidth);
    if Corners[I].Rounded then begin
      Push(Corners[I].A);
      J:=(I+1) mod N;
      Angle:=ArcCos(EnsureRange(D.X*Arms[J].Direction.X+D.Y*Arms[J].Direction.Y,-1,1));
      Steps:=Max(3,Ceil(Angle/0.20));
      for K:=1 to Steps do begin
        U:=K/Steps;
        V:=Corners[I].A*Sqr(1-U)+Corners[I].P*(2*U*(1-U))+Corners[I].B*Sqr(U);
        Push(V);
      end;
    end;
  end;
  if (Count>1) and (Result[0].X=Result[Count-1].X) and
    (Result[0].Z=Result[Count-1].Z) then Dec(Count);
  SetLength(Result,Count);
end;
end.
