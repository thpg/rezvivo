unit GameTrafficCollision;
{$mode objfpc}{$H+}

interface

{ The union of the two existing directional bicycle ellipses is a symmetric
  pair shape. Translation and rotation MUST use the same union: checking only
  the other bicycle's frame lets movement enter a state a yaw guard rejects. }
function TrafficSweepLimit(DX,DZ,MX,MZ,AX,AZ,BX,BZ,Travel:Double):Double;

{ Pure, bounded query. Angles are radians in the XZ plane. The returned angle
  is an unwrapped prefix of the shortest requested turn. Nodes is diagnostic
  work for isolated CPU tests, not a frame log or persistent cache. }
function TrafficYawLimit(DX,DZ,PreviousYaw,ProposedYaw,PeerYaw:Double;
  out Nodes:Integer):Double;

{ Exposed for the CPU geometric invariants and actual-class integration tests. }
procedure TrafficPairClearance(DX,DZ,Yaw,PeerYaw:Double;out Direct,Reverse:Double);

implementation

uses Math;

const
  HalfLength:Double=1.1;
  HalfWidth:Double=0.45;
  ContactSkin:Double=0.002;
  ClearanceEpsilon:Double=1e-9;
  MaximumArcNodes=96;

procedure PairRadii(C,S:Double;out LongRadius,SideRadius:Double);inline;
begin
  LongRadius:=HalfLength+HalfLength*Abs(C)+HalfWidth*Abs(S);
  SideRadius:=HalfWidth+HalfWidth*Abs(C)+HalfLength*Abs(S);
end;

procedure NormalizeDirection(var X,Z:Double);inline;
var L:Double;
begin
  L:=Sqrt(X*X+Z*Z);
  if L>1e-12 then begin X:=X/L;Z:=Z/L end
  else begin X:=0;Z:=1 end;
end;

function TrafficSweepLimit(DX,DZ,MX,MZ,AX,AZ,BX,BZ,Travel:Double):Double;
var LongRadius,SideRadius,FX,FZ,PX,PZ,VX,VZ,A,B,C,D,T:Double;Frame:Integer;
begin
  Result:=1;
  if Travel<=1e-6 then Exit;
  NormalizeDirection(AX,AZ);NormalizeDirection(BX,BZ);
  PairRadii(AX*BX+AZ*BZ,AX*BZ-AZ*BX,LongRadius,SideRadius);
  for Frame:=0 to 1 do begin
    if Frame=0 then begin FX:=BX;FZ:=BZ end
    else begin FX:=AX;FZ:=AZ end;
    PX:=(-DX*FZ+DZ*FX)/SideRadius;PZ:=(DX*FX+DZ*FZ)/LongRadius;
    VX:=(-MX*FZ+MZ*FX)/SideRadius;VZ:=(MX*FX+MZ*FZ)/LongRadius;
    A:=VX*VX+VZ*VZ;B:=PX*VX+PZ*VZ;C:=PX*PX+PZ*PZ-1;
    if(A<1e-12)or(B>=0)then Continue; { separating motion remains allowed }
    if C<=0 then Exit(0);
    D:=B*B-A*C;
    if D<0 then Continue;
    T:=(-B-Sqrt(D))/A;
    if(T>=0)and(T<Result)then begin
      Result:=T-ContactSkin/Travel;
      if Result<0 then Result:=0;
    end;
  end;
end;

procedure TrafficPairClearance(DX,DZ,Yaw,PeerYaw:Double;out Direct,Reverse:Double);
var S,C,LongRadius,SideRadius,FS,FC:Double;
begin
  SinCos(Yaw-PeerYaw,S,C);PairRadii(C,S,LongRadius,SideRadius);
  SinCos(PeerYaw,FS,FC);
  Direct:=Sqr((-DX*FS+DZ*FC)/SideRadius)+Sqr((DX*FC+DZ*FS)/LongRadius)-1;
  SinCos(Yaw,FS,FC);
  Reverse:=Sqr((-DX*FS+DZ*FC)/SideRadius)+Sqr((DX*FC+DZ*FS)/LongRadius)-1;
end;

function MaxAbsSupport(C,S,Lo,Hi:Double):Double;
var Phase,V:Double;K:Integer;
begin
  Result:=Max(C*Abs(Cos(Lo))+S*Abs(Sin(Lo)),C*Abs(Cos(Hi))+S*Abs(Sin(Hi)));
  Phase:=ArcTan2(S,C);
  { Maxima of C*abs(cos)+S*abs(sin), including arcs across quadrant borders. }
  for K:=0 to 1 do begin
    if K=0 then V:=Phase else V:=-Phase;
    if Ceil((Lo-V)/Pi)<=Floor((Hi-V)/Pi)then Exit(Sqrt(C*C+S*S));
  end;
end;

function MinAbsProjection(C,S,Lo,Hi:Double):Double;
var LowValue,HighValue,V,Phase,Amplitude:Double;First,Last,K:Int64;
begin
  LowValue:=C*Cos(Lo)+S*Sin(Lo);HighValue:=C*Cos(Hi)+S*Sin(Hi);
  if LowValue>HighValue then begin V:=LowValue;LowValue:=HighValue;HighValue:=V end;
  Phase:=ArcTan2(S,C);First:=Ceil((Lo-Phase)/Pi);Last:=Floor((Hi-Phase)/Pi);
  if First<=Last then begin
    Amplitude:=Sqrt(C*C+S*S);
    for K:=First to Last do begin
      if Odd(K)then V:=-Amplitude else V:=Amplitude;
      LowValue:=Min(LowValue,V);HighValue:=Max(HighValue,V);
    end;
  end;
  if(LowValue<=0)and(HighValue>=0)then Result:=0
  else Result:=Min(Abs(LowValue),Abs(HighValue));
end;

function TrafficYawLimit(DX,DZ,PreviousYaw,ProposedYaw,PeerYaw:Double;
  out Nodes:Integer):Double;
var Change,FloorDirect,FloorReverse,PeerS,PeerC,SideProjection,LongProjection,
    Fraction,AcceptedChange:Double;

  function SafePrefix(A,B:Double;Depth:Integer):Double;
  var Lo,Hi,V,LongRadius,SideRadius,X,Z,Direct,Reverse,Middle,Reached:Double;
  begin
    if Nodes>=MaximumArcNodes then Exit(A);
    Inc(Nodes);
    Lo:=PreviousYaw+Change*A;Hi:=PreviousYaw+Change*B;
    if Lo>Hi then begin V:=Lo;Lo:=Hi;Hi:=V end;
    LongRadius:=HalfLength+MaxAbsSupport(HalfLength,HalfWidth,Lo-PeerYaw,Hi-PeerYaw);
    SideRadius:=HalfWidth+MaxAbsSupport(HalfWidth,HalfLength,Lo-PeerYaw,Hi-PeerYaw);
    Direct:=Sqr(SideProjection/SideRadius)+Sqr(LongProjection/LongRadius)-1;
    X:=MinAbsProjection(DZ,-DX,Lo,Hi);Z:=MinAbsProjection(DX,DZ,Lo,Hi);
    Reverse:=Sqr(X/SideRadius)+Sqr(Z/LongRadius)-1;
    if(Direct>=FloorDirect-ClearanceEpsilon)and
      (Reverse>=FloorReverse-ClearanceEpsilon)then Exit(B);
    if(Depth>=22)or(Hi-Lo<1e-8)then Exit(A);
    Middle:=(A+B)*0.5;Reached:=SafePrefix(A,Middle,Depth+1);
    if Reached<>Middle then Exit(Reached);
    Result:=SafePrefix(Middle,B,Depth+1);
  end;

begin
  Nodes:=0;
  Change:=ProposedYaw-PreviousYaw;
  while Change>Pi do Change:=Change-2*Pi;
  while Change< -Pi do Change:=Change+2*Pi;
  Result:=PreviousYaw+Change;
  if(Abs(Change)<1e-10)or(DX*DX+DZ*DZ>9)then Exit;
  TrafficPairClearance(DX,DZ,PreviousYaw,PeerYaw,FloorDirect,FloorReverse);
  { A restored old overlap can rotate only without making either existing
    directional overlap deeper. This is not an arbitrary depenetration solver. }
  if FloorDirect>0 then FloorDirect:=0;
  if FloorReverse>0 then FloorReverse:=0;
  SinCos(PeerYaw,PeerS,PeerC);
  SideProjection:=-DX*PeerS+DZ*PeerC;LongProjection:=DX*PeerC+DZ*PeerS;
  Fraction:=SafePrefix(0,1,0);
  AcceptedChange:=Change*Fraction;
  if Fraction<1 then begin
    { The same 2mm contact skin as translation also absorbs Single yaw/vector
      roundoff at the boundary. Backoff stays inside the certified prefix. }
    Fraction:=Abs(AcceptedChange)-ContactSkin/Sqrt(Sqr(HalfLength)+Sqr(HalfWidth));
    if Fraction<0 then Fraction:=0;
    AcceptedChange:=Sign(AcceptedChange)*Fraction;
  end;
  Result:=PreviousYaw+AcceptedChange;
end;

end.
