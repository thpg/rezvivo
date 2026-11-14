unit NeuralRigidMath;
{$mode objfpc}{$H+}{$INLINE ON}
interface
uses Math, NeuralAnatomyMath;
type
 TQuat=record X,Y,Z,W:Double end;
 TRigid=record Q:TQuat; T:TVec3; D:TQuat end;
 TInfluence=record IDs:array[0..3]of Integer; W:array[0..3]of Double end;
 TRigTransforms=array of TRigid;
function QIdentity:TQuat;
function QInverse(const A:TQuat):TQuat;inline;
function QMul(const A,B:TQuat):TQuat;inline;
function QAxis(const Axis:TVec3;const Angle:Double):TQuat;
function QBetween(const A,B:TVec3):TQuat;
function QAverage(const A,B:TQuat):TQuat;
function QRotate(const Q:TQuat;const P:TVec3):TVec3;inline;
function RIdentity:TRigid;
function RCompose(const A,B:TRigid):TRigid;
function RPoint(const R:TRigid;const P:TVec3):TVec3;inline;
function RPivot(const P:TVec3;const Q:TQuat):TRigid;
procedure CompleteRigid(var R:TRigid);inline;
function BlendRigid(const W:TInfluence;const Transforms:TRigTransforms):TRigid;
function SafeUnit(const P:TVec3):TVec3;
function SegmentDistance(const P,A,B:TVec3):Double;
function PerformanceTimeMS:Double;
implementation
uses SysUtils;
function PerformanceTimeMS:Double;
begin Result:=GetTickCount64 end;
function QIdentity:TQuat;
begin Result.X:=0;Result.Y:=0;Result.Z:=0;Result.W:=1 end;
function QInverse(const A:TQuat):TQuat;inline;
begin Result.X:=-A.X;Result.Y:=-A.Y;Result.Z:=-A.Z;Result.W:=A.W end;
function QMul(const A,B:TQuat):TQuat;inline;
begin
 Result.X:=A.W*B.X+A.X*B.W+A.Y*B.Z-A.Z*B.Y;
 Result.Y:=A.W*B.Y-A.X*B.Z+A.Y*B.W+A.Z*B.X;
 Result.Z:=A.W*B.Z+A.X*B.Y-A.Y*B.X+A.Z*B.W;
 Result.W:=A.W*B.W-A.X*B.X-A.Y*B.Y-A.Z*B.Z;
end;
function QAxis(const Axis:TVec3;const Angle:Double):TQuat;
var U:TVec3;S:Double;
begin U:=SafeUnit(Axis);S:=Sin(Angle/2);Result.X:=U.X*S;Result.Y:=U.Y*S;Result.Z:=U.Z*S;Result.W:=Cos(Angle/2)end;
function QBetween(const A,B:TVec3):TQuat;
var U,W,C:TVec3;D,N:Double;
begin U:=SafeUnit(A);W:=SafeUnit(B);D:=Dot(U,W);
 if D< -0.999999 then begin C:=Cross(U,V(1,0,0));if Norm(C)<0.01 then C:=Cross(U,V(0,1,0));Exit(QAxis(C,Pi))end;
 C:=Cross(U,W);N:=Sqrt(Dot(C,C)+Sqr(1+D));Result.X:=C.X/N;Result.Y:=C.Y/N;Result.Z:=C.Z/N;Result.W:=(1+D)/N;
end;
function QAverage(const A,B:TQuat):TQuat;
var F,N:Double;
begin F:=1;if A.X*B.X+A.Y*B.Y+A.Z*B.Z+A.W*B.W<0 then F:=-1;Result.X:=A.X+F*B.X;Result.Y:=A.Y+F*B.Y;Result.Z:=A.Z+F*B.Z;Result.W:=A.W+F*B.W;N:=Sqrt(Sqr(Result.X)+Sqr(Result.Y)+Sqr(Result.Z)+Sqr(Result.W));Result.X/=N;Result.Y/=N;Result.Z/=N;Result.W/=N end;
function QRotate(const Q:TQuat;const P:TVec3):TVec3;inline;
var X,Y,Z:Double;
begin X:=2*(Q.Y*P.Z-Q.Z*P.Y);Y:=2*(Q.Z*P.X-Q.X*P.Z);Z:=2*(Q.X*P.Y-Q.Y*P.X);
 Result.X:=P.X+Q.W*X+Q.Y*Z-Q.Z*Y;Result.Y:=P.Y+Q.W*Y+Q.Z*X-Q.X*Z;Result.Z:=P.Z+Q.W*Z+Q.X*Y-Q.Y*X end;
procedure CompleteRigid(var R:TRigid);inline;
var T:TQuat;
begin T.X:=R.T.X;T.Y:=R.T.Y;T.Z:=R.T.Z;T.W:=0;R.D:=QMul(T,R.Q);R.D.X*=0.5;R.D.Y*=0.5;R.D.Z*=0.5;R.D.W*=0.5 end;
function RIdentity:TRigid;
begin Result.Q:=QIdentity;Result.T:=V(0,0,0);Result.D:=Default(TQuat)end;
function RCompose(const A,B:TRigid):TRigid;
begin Result.Q:=QMul(A.Q,B.Q);Result.T:=Add(QRotate(A.Q,B.T),A.T);CompleteRigid(Result)end;
function RPoint(const R:TRigid;const P:TVec3):TVec3;inline;
begin Result:=Add(QRotate(R.Q,P),R.T)end;
function RPivot(const P:TVec3;const Q:TQuat):TRigid;
begin Result.Q:=Q;Result.T:=Sub(P,QRotate(Q,P));CompleteRigid(Result)end;
function BlendRigid(const W:TInfluence;const Transforms:TRigTransforms):TRigid;
var I:Integer;Q,D,Sum,Dual,T,Base,Conj:TQuat;F,N:Double;
begin
 Sum:=Default(TQuat);Dual:=Sum;Base:=Transforms[W.IDs[0]].Q;
 for I:=0 to 3 do if W.W[I]>0 then begin
  Q:=Transforms[W.IDs[I]].Q;D:=Transforms[W.IDs[I]].D;F:=W.W[I];if Q.X*Base.X+Q.Y*Base.Y+Q.Z*Base.Z+Q.W*Base.W<0 then F:=-F;
  Sum.X+=F*Q.X;Sum.Y+=F*Q.Y;Sum.Z+=F*Q.Z;Sum.W+=F*Q.W;
  Dual.X+=F*D.X;Dual.Y+=F*D.Y;Dual.Z+=F*D.Z;Dual.W+=F*D.W;
 end;
 N:=Sqrt(Sqr(Sum.X)+Sqr(Sum.Y)+Sqr(Sum.Z)+Sqr(Sum.W));
 Require(N>1e-12,'Invalid dual quaternion skin weights');
 Sum.X/=N;Sum.Y/=N;Sum.Z/=N;Sum.W/=N;
 Conj.X:=-Sum.X;Conj.Y:=-Sum.Y;Conj.Z:=-Sum.Z;Conj.W:=Sum.W;
 T:=QMul(Dual,Conj);Result.Q:=Sum;Result.T:=V(2*T.X/N,2*T.Y/N,2*T.Z/N);Result.D:=Dual;
end;
function SafeUnit(const P:TVec3):TVec3;
var L:Double;
begin L:=Norm(P);if L<1e-15 then Result:=V(0,1,0)else Result:=Scale(P,1/L)end;
function SegmentDistance(const P,A,B:TVec3):Double;
var D:TVec3;T,L:Double;
begin D:=Sub(B,A);L:=Dot(D,D);T:=0;if L>1e-15 then T:=EnsureRange(Dot(Sub(P,A),D)/L,0.0,1.0);Result:=Norm(Sub(P,Add(A,Scale(D,T))))end;
end.
