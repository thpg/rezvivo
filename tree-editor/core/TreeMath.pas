unit TreeMath;
{$mode objfpc}{$H+}
interface
type
  TTreeVec3 = packed record X, Y, Z: Single; end;
  TTreeMat4 = array[0..15] of Single; { column-major, OpenGL convention }
function Vec(X, Y, Z: Single): TTreeVec3;
function Add(const A, B: TTreeVec3): TTreeVec3;
function Sub(const A, B: TTreeVec3): TTreeVec3;
function Scale(const A: TTreeVec3; S: Single): TTreeVec3;
function Dot(const A, B: TTreeVec3): Single;
function Cross(const A, B: TTreeVec3): TTreeVec3;
function Magnitude(const A: TTreeVec3): Single;
function Normalize(const A: TTreeVec3): TTreeVec3;
function Mix(const A, B: TTreeVec3; T: Single): TTreeVec3;
function Clamp(X, Lo, Hi: Single): Single;
{ Match the viewer's gamma 2.2 output. Material RGB is stored in linear space;
  color dialogs and palette swatches use display RGB. }
function ColorToLinear(const DisplayRGB: TTreeVec3): TTreeVec3;
function ColorToDisplay(const LinearRGB: TTreeVec3): TTreeVec3;
function Curve(const A, C, B: TTreeVec3; T: Single): TTreeVec3;
function Tangent(const A, C, B: TTreeVec3; T: Single): TTreeVec3;
function Perspective(FovY, Aspect, NearZ, FarZ: Single): TTreeMat4;
function Orthographic(Left,Right,Bottom,Top,NearZ,FarZ: Single): TTreeMat4;
function LookAt(const Eye, Target: TTreeVec3): TTreeMat4;
function Identity: TTreeMat4;
implementation
uses Math;
function Vec(X, Y, Z: Single): TTreeVec3;
begin Result.X := X; Result.Y := Y; Result.Z := Z; end;
function Add(const A, B: TTreeVec3): TTreeVec3;
begin Result := Vec(A.X+B.X, A.Y+B.Y, A.Z+B.Z); end;
function Sub(const A, B: TTreeVec3): TTreeVec3;
begin Result := Vec(A.X-B.X, A.Y-B.Y, A.Z-B.Z); end;
function Scale(const A: TTreeVec3; S: Single): TTreeVec3;
begin Result := Vec(A.X*S, A.Y*S, A.Z*S); end;
function Dot(const A, B: TTreeVec3): Single;
begin Result := A.X*B.X + A.Y*B.Y + A.Z*B.Z; end;
function Cross(const A, B: TTreeVec3): TTreeVec3;
begin Result := Vec(A.Y*B.Z-A.Z*B.Y, A.Z*B.X-A.X*B.Z, A.X*B.Y-A.Y*B.X); end;
function Magnitude(const A: TTreeVec3): Single;
begin Result := Sqrt(Dot(A,A)); end;
function Normalize(const A: TTreeVec3): TTreeVec3;
var L: Single;
begin L := Magnitude(A); if L < 1e-8 then Result := Vec(0,1,0) else Result := Scale(A,1/L); end;
function Mix(const A, B: TTreeVec3; T: Single): TTreeVec3;
begin Result := Add(Scale(A,1-T), Scale(B,T)); end;
function Clamp(X, Lo, Hi: Single): Single;
begin Result := Max(Lo, Min(Hi, X)); end;
function ColorToLinear(const DisplayRGB: TTreeVec3): TTreeVec3;
begin Result:=Vec(Power(Clamp(DisplayRGB.X,0,1),2.2),Power(Clamp(DisplayRGB.Y,0,1),2.2),Power(Clamp(DisplayRGB.Z,0,1),2.2)); end;
function ColorToDisplay(const LinearRGB: TTreeVec3): TTreeVec3;
begin Result:=Vec(Power(Clamp(LinearRGB.X,0,1),1/2.2),Power(Clamp(LinearRGB.Y,0,1),1/2.2),Power(Clamp(LinearRGB.Z,0,1),1/2.2)); end;
function Curve(const A, C, B: TTreeVec3; T: Single): TTreeVec3;
begin Result := Add(Add(Scale(A,Sqr(1-T)),Scale(C,2*T*(1-T))),Scale(B,T*T)); end;
function Tangent(const A, C, B: TTreeVec3; T: Single): TTreeVec3;
begin Result := Normalize(Mix(Sub(C,A),Sub(B,C),T)); end;
function Identity: TTreeMat4;
begin FillChar(Result,SizeOf(Result),0); Result[0]:=1; Result[5]:=1; Result[10]:=1; Result[15]:=1; end;
function Perspective(FovY, Aspect, NearZ, FarZ: Single): TTreeMat4;
var F: Single;
begin
  FillChar(Result,SizeOf(Result),0); F:=1/Tan(FovY*0.5);
  Result[0]:=F/Aspect; Result[5]:=F; Result[10]:=(FarZ+NearZ)/(NearZ-FarZ);
  Result[11]:=-1; Result[14]:=2*FarZ*NearZ/(NearZ-FarZ);
end;
function Orthographic(Left,Right,Bottom,Top,NearZ,FarZ: Single): TTreeMat4;
begin
  Result:=Identity;
  Result[0]:=2/(Right-Left); Result[5]:=2/(Top-Bottom); Result[10]:=-2/(FarZ-NearZ);
  Result[12]:=-(Right+Left)/(Right-Left); Result[13]:=-(Top+Bottom)/(Top-Bottom);
  Result[14]:=-(FarZ+NearZ)/(FarZ-NearZ);
end;
function LookAt(const Eye, Target: TTreeVec3): TTreeMat4;
var F,S,U: TTreeVec3;
begin
  F:=Normalize(Sub(Target,Eye)); S:=Normalize(Cross(F,Vec(0,1,0))); U:=Cross(S,F);
  Result:=Identity;
  Result[0]:=S.X; Result[4]:=S.Y; Result[8]:=S.Z;
  Result[1]:=U.X; Result[5]:=U.Y; Result[9]:=U.Z;
  Result[2]:=-F.X; Result[6]:=-F.Y; Result[10]:=-F.Z;
  Result[12]:=-Dot(S,Eye); Result[13]:=-Dot(U,Eye); Result[14]:=Dot(F,Eye);
end;
end.
