unit RiderHandGrip;

{$mode objfpc}{$H+}

interface

uses Classes, Math, CastleVectors, TripoRig;

type
  { Bike space, independent of the rider's bind axes. Weight=0 is a free hand. }
  TRiderGripFrame = record
    Forward, Palm: TVector3;
    Weight: Single;
  end;

function RiderGripFrame(Grip, Side: Integer): TRiderGripFrame;
function BlendGripFrame(const A, B: TRiderGripFrame; T: Single): TRiderGripFrame;
function TransformGripFrame(const F: TRiderGripFrame; const M: TMatrix4): TRiderGripFrame;
procedure RiderHandAxes(Rig: TTripoRig; Side: Integer; out Forward, Palm: TTripoVec3);
function RiderGripOrientation(const Natural: TTripoVec4; const Forearm,
  LocalForward, LocalPalm: TTripoVec3; const Frame: TRiderGripFrame;
  Pronation, Level: Single; Side: Integer): TTripoVec4;
function RiderGripTarget(const LocalForward,LocalPalm:TTripoVec3;
  const Frame:TRiderGripFrame):TTripoVec4;
function RiderGripPoseOrientation(const Natural,Target:TTripoVec4;
  const Forearm,LocalForward:TTripoVec3;Weight,Pronation,Level:Single;Side:Integer):TTripoVec4;
procedure AppendRiderGripGlsl(S: TStrings);

implementation

function RiderGripFrame(Grip, Side: Integer): TRiderGripFrame;
var Sign: Single;
begin
  Sign := 1 - 2 * Side;
  Result.Forward := Vector3(1, 0.10, 0);
  Result.Palm := Vector3(0, -0.55, -Sign);
  Result.Weight := Ord(Grip > 0);
  case Grip of
    2: Result.Palm := Vector3(0, -0.85, -Sign * 0.55); { shoulder of the bar }
    3, 4: begin { hooks, below the brake lever }
      Result.Forward := Vector3(1, -0.15, 0);
      Result.Palm := Vector3(0, -0.18, -Sign);
    end;
    5, 6: begin { tops: palms down, fingers wrap underneath }
      Result.Forward := Vector3(1, -0.12, 0);
      Result.Palm := Vector3(0, -1, 0);
    end;
  end;
  Result.Forward := Result.Forward.Normalize;
  Result.Palm := Result.Palm.Normalize;
end;

function BlendGripFrame(const A, B: TRiderGripFrame; T: Single): TRiderGripFrame;
begin
  T := EnsureRange(T, 0.0, 1.0);
  Result.Forward := (A.Forward * (1-T) + B.Forward * T).Normalize;
  Result.Palm := (A.Palm * (1-T) + B.Palm * T).Normalize;
  Result.Weight := A.Weight * (1-T) + B.Weight * T;
end;

function TransformGripFrame(const F: TRiderGripFrame; const M: TMatrix4): TRiderGripFrame;
begin
  Result := F;
  Result.Forward := M.MultDirection(F.Forward).Normalize;
  Result.Palm := M.MultDirection(F.Palm).Normalize;
end;

procedure RiderHandAxes(Rig: TTripoRig; Side: Integer; out Forward, Palm: TTripoVec3);
var H, I, L: Integer; Prefix: string; F, R: TTripoVec3; Q: TTripoVec4;
begin
  Forward := V3(0, 1, 0); Palm := V3(0, 0, 1);
  if Side=0 then Prefix:='R_' else Prefix:='L_';
  H:=Rig.JointIndexByName(Prefix+'Hand');
  I:=Rig.JointIndexByName(Prefix+'Index1');
  L:=Rig.JointIndexByName(Prefix+'Little1');
  if (H<0) or (I<0) or (L<0) then Exit;
  F:=V3Sub(V3Scale(V3Add(Rig.JointBindPos(I),Rig.JointBindPos(L)),0.5),Rig.JointBindPos(H));
  R:=V3Sub(Rig.JointBindPos(I),Rig.JointBindPos(L));
  Q:=QuatConj(Mat4ToQuat(Rig.BindWorld[H]));
  Forward:=V3Norm(QuatRotateV3(Q,F));
  Palm:=V3Norm(QuatRotateV3(Q,V3Scale(V3Cross(F,R),2*Side-1)));
end;

function QBlend(const A,B:TTripoVec4; T:Single):TTripoVec4;
var U:Single;
begin
  if A.X*B.X+A.Y*B.Y+A.Z*B.Z+A.W*B.W<0 then U:=-T else U:=T;
  Result.X:=A.X*(1-T)+B.X*U;Result.Y:=A.Y*(1-T)+B.Y*U;
  Result.Z:=A.Z*(1-T)+B.Z*U;Result.W:=A.W*(1-T)+B.W*U;
  Result:=QuatNormalize(Result);
end;

function RiderGripTarget(const LocalForward,LocalPalm:TTripoVec3;
  const Frame:TRiderGripFrame):TTripoVec4;
var D,P,N:TTripoVec3; A:Single;
begin
  D:=V3Norm(V3(Frame.Forward.X,Frame.Forward.Y,Frame.Forward.Z));
  Result:=QuatFromTo(LocalForward,D);
  P:=QuatRotateV3(Result,LocalPalm);P:=V3Norm(V3Sub(P,V3Scale(D,V3Dot(P,D))));
  N:=V3(Frame.Palm.X,Frame.Palm.Y,Frame.Palm.Z);N:=V3Sub(N,V3Scale(D,V3Dot(N,D)));
  if V3Len(N)>1e-5 then begin
    N:=V3Norm(N);A:=ArcTan2(V3Dot(D,V3Cross(P,N)),V3Dot(P,N));
    Result:=QuatNormalize(QuatMul(QuatFromAxisAngle(D.X,D.Y,D.Z,A),Result));
  end;
end;

function RiderGripPoseOrientation(const Natural,Target:TTripoVec4;
  const Forearm,LocalForward:TTripoVec3;Weight,Pronation,Level:Single;Side:Integer):TTripoVec4;
var F,D,Axis:TTripoVec3;Angle,Roll:Single;Q:TTripoVec4;
begin
  F:=V3Norm(Forearm);
  { Positive means anatomical pronation on BOTH sides. }
  Roll:=DegToRad(EnsureRange(Pronation,-80.0,80.0))*(2*Side-1);
  D:=QuatRotateV3(Target,LocalForward);
  Angle:=ArcCos(EnsureRange(V3Dot(D,F),-1.0,1.0));
  Axis:=V3Cross(D,F);
  if V3Len(Axis)<1e-5 then Axis:=V3Cross(D,V3(0,1,0));
  if V3Len(Axis)<1e-5 then Axis:=V3Cross(D,V3(1,0,0));
  Axis:=V3Norm(Axis);
  Angle:=Angle-Min(Angle*EnsureRange(Level,0.0,1.0),DegToRad(25));
  Q:=QuatMul(QuatFromAxisAngle(Axis.X,Axis.Y,Axis.Z,Angle),Target);
  Q:=QBlend(Natural,Q,EnsureRange(Weight,0.0,1.0));
  Result:=QuatNormalize(QuatMul(QuatFromAxisAngle(F.X,F.Y,F.Z,Roll),Q));
end;

function RiderGripOrientation(const Natural:TTripoVec4;const Forearm,
  LocalForward,LocalPalm:TTripoVec3;const Frame:TRiderGripFrame;
  Pronation,Level:Single;Side:Integer):TTripoVec4;
begin
  Result:=RiderGripPoseOrientation(Natural,RiderGripTarget(LocalForward,LocalPalm,Frame),
    Forearm,LocalForward,Frame.Weight,Pronation,Level,Side);
end;

procedure AppendRiderGripGlsl(S:TStrings);
begin
  { Contact orientation is a pair of cheap CPU quaternions, independent of IK.
    The wrist limit and all limb solving stay in the vertex shader. Avoid
    reconstructing the same grip frame in every IK iteration and influence. }
  S.Add('vec4 gskGripOrientation(vec4 natural, vec4 target, vec3 f, vec3 localF, float weight, float pron, float side, float level) {');
  S.Add('  vec3 d=gskQRot(target,localF); float a=acos(clamp(dot(d,f),-1.0,1.0)); vec3 axis=cross(d,f);');
  S.Add('  vec3 fallback=cross(d,mix(vec3(0,1,0),vec3(1,0,0),step(0.9,abs(d.y))));');
  S.Add('  axis=normalize(mix(axis,fallback,step(dot(axis,axis),1e-10)));');
  S.Add('  a-=min(a*clamp(level,0.0,1.0),0.436332313); vec4 q=qmul(gskQAA(axis,a),target);');
  S.Add('  q*=mix(1.0,-1.0,step(dot(natural,q),-1e-8)); q=normalize(mix(natural,q,clamp(weight,0.0,1.0)));');
  S.Add('  return qmul(gskQAA(f,radians(clamp(pron,-80.0,80.0))*side),q);');
  S.Add('}');
end;

end.
