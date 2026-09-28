unit Osm3dCurbSimplify;

{$mode objfpc}{$H+}

interface

uses CastleVectors;

const
  { Nominal length of a regular block, not a hard minimum mesh span.
    Actual blocks can be shorter at corners, ends and profile breaks. }
  CURB_BLOCK_LENGTH = 1.0;
  CURB_MAX_SPAN = 16.0;
  CURB_HORIZONTAL_ERROR = 0.01;
  CURB_VERTICAL_ERROR = 0.005;

type
  TCurbPathPoint = record
    Position, Outer, OuterNext: TVector3;
    Vertex: Integer;
    Station: Double;
  end;
  TCurbPath = array of TCurbPathPoint;
  TCurbPathIndices = array of Integer;

{ Simplify both edges of the strip, not only its centreline. Remove redundant
  subdivisions inside a block while preserving actual shorter blocks at
  corners, height breaks and disconnected ends. A span shorter than the
  nominal block length is not by itself an error. }
function SimplifyCurbPath(const Points: TCurbPath): TCurbPathIndices;

implementation

uses Math;

function SimplifyCurbPath(const Points: TCurbPath): TCurbPathIndices;
type TRange = record A,B: Integer end;
var Keep: array of Boolean; Stack: array of TRange;
  Top, A,B,I,J,N,Split,Prev,Next:Integer; Error, Worst:Double;

  function SpanError(L,R:Integer; out WorstPoint:Integer; MaxLength:Double=CURB_MAX_SPAN):Double;
  var K,Lo,Hi,Mid:Integer; DX,DZ,Len2,T,LastT,EX,EY,EZ,E:Double; P,Q,OP,OQ: TVector3;
  begin
    Result:=0;WorstPoint:=(L+R) div 2;
    if R<=L+1 then Exit;
    if Points[R].Station-Points[L].Station>MaxLength then
    begin
      { Split by metres, not vertex count: tessellation density is uneven. }
      T:=(Points[R].Station+Points[L].Station)*0.5;Lo:=L+1;Hi:=R-1;
      while Lo<Hi do
      begin Mid:=(Lo+Hi) div 2;if Points[Mid].Station<T then Lo:=Mid+1 else Hi:=Mid end;
      WorstPoint:=Lo;Result:=2;Exit
    end;
    P:=Points[L].Position;Q:=Points[R].Position;
    OP:=Points[L].OuterNext;OQ:=Points[R].Outer;
    DX:=Double(Q.X)-P.X;DZ:=Double(Q.Z)-P.Z;Len2:=DX*DX+DZ*DZ;
    if Len2<0.0001 then begin Result:=2;Exit end;
    LastT:=0;
    for K:=L+1 to R-1 do
    begin
      T:=((Double(Points[K].Position.X)-P.X)*DX+
          (Double(Points[K].Position.Z)-P.Z)*DZ)/Len2;
      if (T<LastT) or (T>1) then begin Result:=1e20;WorstPoint:=K;Exit end;
      LastT:=T;
      EX:=Points[K].Position.X-(P.X+T*DX);
      EZ:=Points[K].Position.Z-(P.Z+T*DZ);
      EY:=Points[K].Position.Y-(P.Y+T*(Double(Q.Y)-P.Y));
      E:=Max((EX*EX+EZ*EZ)/Sqr(CURB_HORIZONTAL_ERROR),Sqr(EY/CURB_VERTICAL_ERROR));
      EX:=Points[K].Outer.X-(OP.X+T*(Double(OQ.X)-OP.X));
      EZ:=Points[K].Outer.Z-(OP.Z+T*(Double(OQ.Z)-OP.Z));
      EY:=Points[K].Outer.Y-(OP.Y+T*(Double(OQ.Y)-OP.Y));
      E:=Max(E,Max((EX*EX+EZ*EZ)/Sqr(CURB_HORIZONTAL_ERROR),Sqr(EY/CURB_VERTICAL_ERROR)));
      EX:=Points[K].OuterNext.X-(OP.X+T*(Double(OQ.X)-OP.X));
      EZ:=Points[K].OuterNext.Z-(OP.Z+T*(Double(OQ.Z)-OP.Z));
      EY:=Points[K].OuterNext.Y-(OP.Y+T*(Double(OQ.Y)-OP.Y));
      E:=Max(E,Max((EX*EX+EZ*EZ)/Sqr(CURB_HORIZONTAL_ERROR),Sqr(EY/CURB_VERTICAL_ERROR)));
      if E>Result then begin Result:=E;WorstPoint:=K end;
    end;
  end;

  procedure Push(L,R:Integer);
  begin Inc(Top);Stack[Top].A:=L;Stack[Top].B:=R end;

begin
  Result:=nil;N:=Length(Points);if N=0 then Exit;
  SetLength(Keep,N);Keep[0]:=True;Keep[N-1]:=True;
  SetLength(Stack,N);Top:=-1;Push(0,N-1);
  while Top>=0 do
  begin
    A:=Stack[Top].A;B:=Stack[Top].B;Dec(Top);
    if B<=A+1 then Continue;
    Worst:=SpanError(A,B,Split);
    if Worst<=1 then Continue;
    Keep[Split]:=True;Push(Split,B);Push(A,Split);
  end;
  { RDP splits can leave a short remainder. Remove either adjacent split when
    the combined strip still meets the same geometric bound. Never bridge an
    entrance or move a sharp corner just to satisfy the nominal block length. }
  Prev:=0;
  for I:=1 to N-2 do if Keep[I] then
  begin
    Next:=I+1;while (Next<N-1) and not Keep[Next] do Inc(Next);
    if (Points[I].Station-Points[Prev].Station<CURB_BLOCK_LENGTH) or
       (Points[Next].Station-Points[I].Station<CURB_BLOCK_LENGTH) then
    begin
      Error:=SpanError(Prev,Next,Split,CURB_MAX_SPAN+CURB_BLOCK_LENGTH);
      if Error<=1 then begin Keep[I]:=False;Continue end;
    end;
    Prev:=I;
  end;
  SetLength(Result,N);J:=0;
  for I:=0 to N-1 do if Keep[I] then begin Result[J]:=I;Inc(J)end;
  SetLength(Result,J);
end;

end.
